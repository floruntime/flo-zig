//! Flo High-Level Action Worker API
//!
//! Provides an easy-to-use ActionWorker for executing actions.
//! Includes heartbeat, drain support, and graceful shutdown.
//!
//! ## Example
//!
//! ```zig
//! const flo = @import("flo");
//!
//! fn processOrder(ctx: *flo.ActionContext) ![]const u8 {
//!     const input = try ctx.json(OrderRequest);
//!     defer input.deinit();
//!
//!     // Process order...
//!     // For long tasks, extend the lease
//!     try ctx.touch(30000);
//!
//!     return ctx.toBytes(OrderResult{ .status = "completed" });
//! }
//!
//! pub fn main() !void {
//!     var worker = try flo.ActionWorker.init(allocator, .{
//!         .endpoint = "localhost:3000",
//!         .namespace = "myapp",
//!     });
//!     defer worker.deinit();
//!
//!     try worker.registerAction("process-order", processOrder);
//!     try worker.start();
//! }
//! ```

const std = @import("std");
const types = @import("types.zig");
const client_mod = @import("client.zig");
const Client = client_mod.Client;
const Actions = @import("actions.zig").Actions;
const retry_mod = @import("retry.zig");

const FloError = types.FloError;
const TaskAssignment = types.TaskAssignment;
const Allocator = std.mem.Allocator;

/// Configuration for the ActionWorker.
pub const WorkerConfig = struct {
    /// Server endpoint (e.g., "localhost:3000")
    endpoint: []const u8,
    /// Namespace for operations
    namespace: []const u8 = "default",
    /// Unique worker ID (auto-generated if null)
    worker_id: ?[]const u8 = null,
    /// Maximum concurrent actions
    concurrency: u32 = 10,
    /// Long-poll wait per await in ms. 0 means DEFAULT_WORKER_BLOCK_MS; over
    /// MAX_BLOCK_MS, ActionWorker.init returns error.BlockTooLong.
    block_ms: u32 = types.DEFAULT_WORKER_BLOCK_MS,
    /// Heartbeat interval in milliseconds (default: 30s)
    heartbeat_interval_ms: u64 = 30_000,
    /// Optional metadata for this worker
    metadata: ?[]const u8 = null,
    /// Optional machine ID
    machine_id: ?[]const u8 = null,
    /// How its connection retries refused-but-not-run requests.
    retry: retry_mod.RetryPolicy = .{},
};

/// Context passed to action handlers.
///
/// Provides access to task information and helper methods for
/// parsing input and formatting output.
pub const ActionContext = struct {
    task_id: []const u8,
    action_name: []const u8,
    payload: []const u8,
    attempt: u32,
    created_at: i64,
    namespace: []const u8,
    caller_run_id: ?[]const u8 = null,
    caller_workflow_name: ?[]const u8 = null,
    allocator: Allocator,
    actions: *Actions,
    worker_id: []const u8,

    /// Get the raw input payload.
    pub fn input(self: *const ActionContext) []const u8 {
        return self.payload;
    }

    /// Returns true if this action was invoked by a workflow.
    pub fn isCalledByWorkflow(self: *const ActionContext) bool {
        return self.caller_run_id != null;
    }

    /// Parse the input payload as JSON into the given type.
    /// Caller must call deinit() on the returned value if it contains allocated memory.
    pub fn json(self: *const ActionContext, comptime T: type) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, self.allocator, self.payload, .{});
    }

    /// Serialize a value to JSON bytes.
    /// Caller owns the returned slice and must free it.
    pub fn toBytes(self: *const ActionContext, value: anytype) ![]u8 {
        var list: std.ArrayList(u8) = .{};
        errdefer list.deinit(self.allocator);
        try list.writer(self.allocator).print("{any}", .{std.json.fmt(value, .{})});
        return list.toOwnedSlice(self.allocator);
    }

    /// Extend the lease on this task.
    /// Use this for long-running tasks to prevent timeout.
    pub fn touch(self: *ActionContext, extend_ms: u32) !void {
        try self.actions.touch(
            self.worker_id,
            self.action_name,
            self.task_id,
            .{ .namespace = self.namespace, .extend_ms = extend_ms },
        );
    }

    /// Create an ActionResult with a named outcome.
    /// The value is serialized to JSON bytes. Caller owns the returned data.
    pub fn result(self: *ActionContext, outcome: []const u8, value: anytype) !types.ActionResult {
        const data = try self.toBytes(value);
        return types.ActionResult{
            .outcome = outcome,
            .data = data,
            .owned = true,
        };
    }
};

/// Error set for non-retryable action failures.
/// When a handler returns `error.NonRetryable`, the task is failed with retry=false.
pub const NonRetryableError = error{NonRetryable};

/// Result type for action handlers.
pub const ActionHandlerResult = union(enum) {
    /// Raw result bytes (outcome defaults to "success")
    bytes: []const u8,
    /// Result with named outcome for workflow routing
    result: types.ActionResult,
};

/// Action handler function type.
/// Returns bytes or ActionResult on success, or an error.
/// Return error.NonRetryable to fail without retry.
pub const ActionHandler = *const fn (*ActionContext) anyerror!ActionHandlerResult;

/// High-level worker for executing actions.
/// Includes automatic heartbeat, drain support, and graceful deregistration.
///
/// Example usage:
/// ```zig
/// var worker = try ActionWorker.init(allocator, .{
///     .endpoint = "localhost:3000",
///     .namespace = "myapp",
/// });
/// defer worker.deinit();
///
/// try worker.registerAction("my-action", myHandler);
/// try worker.start();
/// ```
pub const ActionWorker = struct {
    allocator: Allocator,
    config: WorkerConfig,
    client: Client,
    worker_id: []const u8,
    handlers: std.StringHashMap(ActionHandler),
    action_names: std.ArrayListUnmanaged([]const u8),
    running: bool = false,
    backoff: types.EmptyPollBackoff = .{},
    draining: bool = false,
    active_tasks: u32 = 0,
    last_heartbeat_ns: i128 = 0,

    const Self = @This();

    /// Initialize a new ActionWorker.
    pub fn init(allocator: Allocator, config_in: WorkerConfig) !Self {
        var config = config_in;
        config.block_ms = try types.workerBlockMs(config.block_ms);

        var client = Client.init(allocator, config.endpoint, .{
            .namespace = config.namespace,
            .retry = config.retry,
        });
        errdefer client.deinit();

        try client.connect();

        // Generate worker ID if not provided
        const worker_id = if (config.worker_id) |id|
            try allocator.dupe(u8, id)
        else
            try generateWorkerId(allocator);

        return Self{
            .allocator = allocator,
            .config = config,
            .client = client,
            .worker_id = worker_id,
            .handlers = std.StringHashMap(ActionHandler).init(allocator),
            .action_names = .{},
        };
    }

    /// Deinitialize the worker and free resources.
    /// Deregisters from the server if connected.
    pub fn deinit(self: *Self) void {
        // Best-effort deregister
        var actions = self.api();
        actions.deregister(self.worker_id, .{
            .namespace = self.config.namespace,
        }) catch {};

        for (self.action_names.items) |name| {
            self.allocator.free(name);
        }
        self.action_names.deinit(self.allocator);
        self.handlers.deinit();
        self.allocator.free(self.worker_id);
        self.client.deinit();
    }

    /// Request API over this worker's connection. Built per use rather than
    /// stored: the worker is returned by value, so a pointer to its client
    /// taken in init would point at init's stack frame.
    fn api(self: *Self) Actions {
        return Actions.init(&self.client);
    }

    /// Register an action handler.
    pub fn registerAction(self: *Self, action_name: []const u8, handler: ActionHandler) !void {
        if (self.handlers.contains(action_name)) {
            return error.ActionAlreadyRegistered;
        }

        // Register action with the server
        var actions = self.api();
        try actions.registerAction(action_name, .user, .{
            .namespace = self.config.namespace,
        });

        // Store handler
        const name_owned = try self.allocator.dupe(u8, action_name);
        errdefer self.allocator.free(name_owned);

        try self.handlers.put(name_owned, handler);
        try self.action_names.append(self.allocator, name_owned);

        std.log.info("[flo-worker] Registered action: {s}", .{action_name});
    }

    /// Start the worker and begin processing actions.
    /// This function blocks until stop() is called or drain completes.
    pub fn start(self: *Self) !void {
        if (self.handlers.count() == 0) {
            return error.NoActionsRegistered;
        }

        std.log.info("[flo-worker] Starting (id={s}, namespace={s}, concurrency={d})", .{
            self.worker_id,
            self.config.namespace,
            self.config.concurrency,
        });

        try self.registerWorker();

        self.running = true;
        self.last_heartbeat_ns = std.time.nanoTimestamp();
        var failed = retry_mod.workerBackoff();

        // Main polling loop
        while (self.running) {
            if (!self.client.isConnected()) {
                self.reconnect() catch |err| {
                    std.log.err("[flo-worker] Reconnect failed: {}, retrying...", .{err});
                    types.pauseWhileRunning(&self.running, 1_000);
                    continue;
                };
            }

            // Send heartbeat if interval has elapsed
            self.maybeHeartbeat();

            // If draining and no active tasks, we're done
            if (self.draining and self.active_tasks == 0) {
                std.log.info("[flo-worker] Drain complete, shutting down", .{});
                self.running = false;
                break;
            }

            // Don't accept new tasks while draining
            if (self.draining) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            }

            self.pollAndExecute() catch |err| {
                if (client_mod.isConnectionError(err)) {
                    std.log.warn("[flo-worker] Connection lost: {}, reconnecting...", .{err});
                    self.client.disconnect();
                } else {
                    const ms = failed.next(self.client.prng.random());
                    std.log.err("[flo-worker] Await error: {}, retrying in {d}ms...", .{ err, ms });
                    types.pauseWhileRunning(&self.running, ms);
                }
                continue;
            };
            failed.reset();
        }

        std.log.info("[flo-worker] Worker stopped", .{});
    }

    /// Open a fresh connection and register on it again. Gives up once the
    /// worker is stopped.
    fn reconnect(self: *Self) !void {
        try self.client.reconnectWhile(&self.running);
        errdefer self.client.disconnect();
        try self.registerWorker();
    }

    /// Reconnect to resend a lost result. A stopping worker still tries,
    /// for about stopping_reconnect_ms, so a result produced as it stops
    /// isn't lost to a brief drop, yet stop isn't held up for long.
    fn reconnectForResult(self: *Self) !void {
        if (@atomicLoad(bool, &self.running, .monotonic)) {
            if (self.reconnect()) return else |err| {
                if (@atomicLoad(bool, &self.running, .monotonic)) return err;
            }
        }
        try self.client.reconnectFor(stopping_reconnect_ms);
        errdefer self.client.disconnect();
        try self.registerWorker();
    }

    fn registerWorker(self: *Self) !void {
        // Build process list for registration
        var processes: [64]types.ProcessEntry = undefined;
        const count = @min(self.action_names.items.len, 64);
        for (self.action_names.items[0..count], 0..) |name, i| {
            processes[i] = .{ .name = name, .kind = .action };
        }

        // Register worker with the server
        var actions = self.api();
        try actions.register(
            self.worker_id,
            self.action_names.items,
            .{
                .namespace = self.config.namespace,
                .worker_type = .action,
                .max_concurrency = self.config.concurrency,
                .processes = processes[0..count],
                .metadata = self.config.metadata,
                .machine_id = self.config.machine_id,
            },
        );
    }

    /// Stop the worker immediately.
    pub fn stop(self: *Self) void {
        std.log.info("[flo-worker] Stopping worker...", .{});
        @atomicStore(bool, &self.running, false, .monotonic);
    }

    /// Initiate graceful drain — finish current tasks but accept no new ones.
    pub fn drain(self: *Self) void {
        std.log.info("[flo-worker] Draining worker...", .{});
        self.draining = true;

        // Notify server
        var actions = self.api();
        actions.drain(self.worker_id, .{
            .namespace = self.config.namespace,
        }) catch |err| {
            std.log.err("[flo-worker] Failed to notify server of drain: {}", .{err});
        };
    }

    /// Send heartbeat if the interval has elapsed.
    fn maybeHeartbeat(self: *Self) void {
        const now = std.time.nanoTimestamp();
        const elapsed_ns = now - self.last_heartbeat_ns;
        const interval_ns: i128 = @as(i128, self.config.heartbeat_interval_ms) * std.time.ns_per_ms;

        if (elapsed_ns < interval_ns) return;

        self.last_heartbeat_ns = now;

        var actions = self.api();
        const status = actions.heartbeat(
            self.worker_id,
            self.active_tasks,
            .{ .namespace = self.config.namespace },
        ) catch |err| {
            std.log.err("[flo-worker] Heartbeat failed: {}", .{err});
            return;
        };

        // Server may tell us to drain
        if (status == .draining and !self.draining) {
            std.log.info("[flo-worker] Server requested drain", .{});
            self.draining = true;
        }
    }

    /// Poll for a task and execute it.
    fn pollAndExecute(self: *Self) !void {
        // Await task from server
        var actions = self.api();
        const polled = try std.time.Instant.now();
        const task_opt = try actions.awaitTask(
            self.worker_id,
            self.action_names.items,
            .{
                .namespace = self.config.namespace,
                .block_ms = self.config.block_ms,
            },
        );

        // No `try`: an error here would leak a task already handed to us.
        const elapsed = if (std.time.Instant.now()) |now| now.since(polled) else |_| 0;
        const pause_ms = self.backoff.afterPoll(task_opt == null, elapsed, self.config.block_ms);
        var task = task_opt orelse {
            types.pauseWhileRunning(&self.running, pause_ms);
            return;
        };
        defer task.deinit();
        self.active_tasks += 1;
        defer self.active_tasks -= 1;
        self.executeTask(&task);
    }

    /// Execute a task with error handling.
    fn executeTask(self: *Self, task: *TaskAssignment) void {
        std.log.info("[flo-worker] Executing action: {s} (task={s}, attempt={d})", .{
            task.task_type,
            task.task_id,
            task.attempt,
        });

        var actions = self.api();

        // Get handler
        const handler = self.handlers.get(task.task_type) orelse {
            std.log.err("[flo-worker] No handler for action: {s}", .{task.task_type});
            _ = self.report(task, .{ .fail = .{ .message = "No handler registered" } });
            return;
        };

        // Create action context
        var ctx = ActionContext{
            .task_id = task.task_id,
            .action_name = task.task_type,
            .payload = task.payload,
            .attempt = task.attempt,
            .created_at = task.created_at,
            .namespace = self.config.namespace,
            .caller_run_id = task.caller_run_id,
            .caller_workflow_name = task.caller_workflow_name,
            .allocator = self.allocator,
            .actions = &actions,
            .worker_id = self.worker_id,
        };

        // The handler's outcome alone decides complete or fail: a complete
        // that can't be delivered is never turned into a fail.
        if (handler(&ctx)) |handler_result| {
            const sent = switch (handler_result) {
                .bytes => |data| blk: {
                    defer self.allocator.free(data);
                    break :blk self.report(task, .{ .complete = .{ .data = data } });
                },
                .result => |ar| blk: {
                    defer if (ar.owned) self.allocator.free(ar.data);
                    break :blk self.report(task, .{ .complete = .{ .data = ar.data, .outcome = ar.outcome } });
                },
            };
            if (sent) std.log.info("[flo-worker] Action completed: {s} (task={s})", .{ task.task_type, task.task_id });
        } else |err| {
            // Failure — check if non-retryable
            var error_buf: [256]u8 = undefined;
            const error_msg = std.fmt.bufPrint(&error_buf, "{}", .{err}) catch "Unknown error";

            std.log.err("[flo-worker] Action failed: {s} - {s}", .{ task.task_type, error_msg });
            _ = self.report(task, .{ .fail = .{ .message = error_msg, .retry = err != error.NonRetryable } });
        }
    }

    /// A task's result, as the handler decided it.
    const Report = union(enum) {
        complete: struct { data: []const u8, outcome: []const u8 = "success" },
        fail: struct { message: []const u8, retry: bool = false },
    };

    /// Deliver a task's result. A send lost to a dropped connection or a
    /// timeout is sent again, unchanged, on a fresh connection, up to
    /// max_result_sends in all; the server may then see it twice, which it
    /// must treat as one. A refusal is not sent again: the server answered.
    /// Returns whether the server accepted it; otherwise the drop is logged
    /// and the task is left to its lease, so it may run again.
    fn report(self: *Self, task: *const TaskAssignment, rep: Report) bool {
        const kind = @tagName(rep);
        var actions = self.api();
        var sends: u32 = 0;
        while (true) {
            sends += 1;
            const result = switch (rep) {
                .complete => |c| actions.complete(self.worker_id, task.task_type, task.task_id, c.data, .{
                    .namespace = self.config.namespace,
                    .outcome = c.outcome,
                }),
                .fail => |f| actions.fail(self.worker_id, task.task_type, task.task_id, f.message, .{
                    .namespace = self.config.namespace,
                    .retry = f.retry,
                }),
            };
            const err = if (result) return true else |e| e;
            if (!client_mod.isConnectionError(err)) {
                types.logDropped("[flo-worker] {s} for task {s} refused: {}; dropped", .{ kind, task.task_id, err });
                return false;
            }
            if (sends >= max_result_sends) {
                types.logDropped("[flo-worker] {s} for task {s} not delivered after {d} sends: {}; dropped", .{ kind, task.task_id, sends, err });
                return false;
            }
            self.client.disconnect();
            self.reconnectForResult() catch |rerr| {
                if (!@atomicLoad(bool, &self.running, .monotonic)) {
                    types.logDropped("[flo-worker] {s} for task {s} not delivered: worker stopping and reconnect failed: {}; dropped", .{ kind, task.task_id, rerr });
                } else {
                    types.logDropped("[flo-worker] {s} for task {s} not delivered: reconnect failed: {}; dropped", .{ kind, task.task_id, rerr });
                }
                return false;
            };
            std.log.warn("[flo-worker] {s} for task {s} lost: {}; resending", .{ kind, task.task_id, err });
        }
    }
};

/// How long a stopping worker keeps trying to reconnect to resend a result.
const stopping_reconnect_ms = 2_000;

/// Sends of one result, the first included, before it is dropped.
const max_result_sends = 3;

/// Generate a random worker ID.
fn generateWorkerId(allocator: Allocator) ![]u8 {
    var id_buf: [8]u8 = undefined;
    std.crypto.random.bytes(&id_buf);

    // Format as hex with hostname prefix
    var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = std.posix.gethostname(&hostname_buf) catch "unknown";

    // Format ID as hex manually
    const hex_chars = "0123456789abcdef";
    var hex_buf: [16]u8 = undefined;
    for (id_buf, 0..) |byte, i| {
        hex_buf[i * 2] = hex_chars[byte >> 4];
        hex_buf[i * 2 + 1] = hex_chars[byte & 0x0f];
    }

    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ hostname, &hex_buf });
}

// =============================================================================
// Tests
// =============================================================================

test "WorkerConfig defaults" {
    const config = WorkerConfig{
        .endpoint = "localhost:3000",
    };
    try std.testing.expectEqual(@as(u32, 10), config.concurrency);
    try std.testing.expectEqual(@as(u32, 30_000), config.block_ms);
    try std.testing.expectEqual(@as(u64, 30_000), config.heartbeat_interval_ms);
}

test "generateWorkerId" {
    const allocator = std.testing.allocator;
    const id = try generateWorkerId(allocator);
    defer allocator.free(id);

    try std.testing.expect(id.len > 0);
}

test "ActionWorker.init refuses block_ms over MAX_BLOCK_MS before connecting" {
    try std.testing.expectError(error.BlockTooLong, ActionWorker.init(std.testing.allocator, .{
        .endpoint = "localhost:1",
        .block_ms = types.MAX_BLOCK_MS + 1,
    }));
}

test "ActionWorker.init turns block_ms 0 into 30000" {
    // A worker that polls with block_ms 0 would spin against the server.
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();
    var endpoint_buf: [32]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buf, "127.0.0.1:{d}", .{server.listen_address.getPort()});

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = endpoint, .block_ms = 0 });
    // Not deinit: it sends a deregister the listener never answers.
    defer {
        w.handlers.deinit();
        w.action_names.deinit(std.testing.allocator);
        std.testing.allocator.free(w.worker_id);
        w.client.deinit();
    }
    try std.testing.expectEqual(@as(u32, 30000), w.config.block_ms);
}

test "ActionWorker gives its connection the retry policy it is configured with" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();
    var endpoint_buf: [32]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buf, "127.0.0.1:{d}", .{server.listen_address.getPort()});

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = endpoint, .retry = .{ .max_attempts = 7, .initial_backoff_ms = 30, .max_backoff_ms = 9 } });
    // Not deinit: it sends a deregister the listener never answers.
    defer {
        w.handlers.deinit();
        w.action_names.deinit(std.testing.allocator);
        std.testing.allocator.free(w.worker_id);
        w.client.deinit();
    }
    try std.testing.expectEqual(retry_mod.RetryPolicy{ .max_attempts = 7, .initial_backoff_ms = 30, .max_backoff_ms = 30 }, w.client.retry);
}

fn runWorker(w: *ActionWorker) void {
    w.start() catch |err| std.debug.panic("worker start: {}", .{err});
}

test "ActionWorker reconnects after an await times out and runs the next task" {
    const handler = struct {
        fn handle(ctx: *ActionContext) anyerror!ActionHandlerResult {
            return .{ .bytes = try ctx.allocator.dupe(u8, "done") };
        }
    }.handle;
    // [task_id_len:u16]["t1"][task_type_len:u16]["job"][created_at:i64][attempt:u32][has_caller:u8]
    const task = "\x02\x00t1\x03\x00job" ++ "\x00" ** 8 ++ "\x01\x00\x00\x00" ++ "\x00";
    var srv = try @import("stall_server.zig").StallServer.listen(.worker_register, .action_await, .action_complete, task);
    try srv.start();
    defer srv.deinit();

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 100 });
    defer w.deinit();
    w.client.timeout_ms = 200;
    try w.registerAction("job", handler);

    const thread = try std.Thread.spawn(.{}, runWorker, .{&w});
    const done = srv.waitDone(1, 10_000);
    w.stop();
    thread.join();

    try std.testing.expect(done);
    try std.testing.expectEqual(@as(u32, 2), srv.connections.load(.monotonic));
}

test "ActionWorker sends requests on its own connection after init returns" {
    var srv = try @import("test_server.zig").OkServer.listen();
    try srv.start();
    defer srv.deinit();

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint });
    defer w.deinit();
    @import("test_server.zig").clobberStack();

    const noop = struct {
        fn handle(_: *ActionContext) anyerror!ActionHandlerResult {
            return .{ .bytes = "" };
        }
    }.handle;
    try w.registerAction("noop", noop);
    try std.testing.expectEqual(@as(u32, 1), srv.requests.load(.monotonic));
}

test "ActionWorker paces awaits that come back empty at once" {
    var srv = try @import("test_server.zig").OkServer.listen();
    try srv.start();
    defer srv.deinit();

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 30_000 });
    defer w.deinit();
    w.running = true;

    // Re-polled at once, then paused 50, 100 and 200 ms.
    var timer = try std.time.Timer.start();
    for (0..4) |_| try w.pollAndExecute();
    try std.testing.expectEqual(@as(u32, 4), w.backoff.early_empties);
    try std.testing.expect(timer.read() >= 340 * std.time.ns_per_ms);
}

const ScriptServer = @import("test_server.zig").ScriptServer;

// [task_id_len:u16]["t1"][task_type_len:u16]["job"][created_at:i64][attempt:u32][has_caller:u8]
const test_task = "\x02\x00t1\x03\x00job" ++ "\x00" ** 8 ++ "\x01\x00\x00\x00" ++ "\x00";

const test_handlers = struct {
    fn ok(ctx: *ActionContext) anyerror!ActionHandlerResult {
        return .{ .bytes = try ctx.allocator.dupe(u8, "done") };
    }
};

/// Init a worker on `srv` with action "job", then poll once: the await gets
/// `test_task` and the handler runs.
fn pollOnce(srv: *ScriptServer, w: *ActionWorker, timeout_ms: u32) !void {
    w.* = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 100 });
    w.client.timeout_ms = timeout_ms;
    try w.registerAction("job", test_handlers.ok);
    w.running = true;
    try w.pollAndExecute();
}

test "ActionWorker resends a complete lost with its connection, unchanged, and never fails the task" {
    var srv = try ScriptServer.listen();
    srv.rules = &.{
        .{ .op = .action_await, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = test_task } } },
        .{ .op = .action_complete, .nth = 0, .action = .drop },
    };
    try srv.start();
    defer srv.deinit();

    var w: ActionWorker = undefined;
    try pollOnce(&srv, &w, 5_000);
    defer w.deinit();

    try std.testing.expectEqual(@as(u32, 2), srv.countOf(.action_complete));
    try std.testing.expectEqual(@as(u32, 0), srv.countOf(.action_fail));
    // Registered again on the new connection before the resend.
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.worker_register));
    try std.testing.expectEqual(@as(u32, 2), srv.connections.load(.monotonic));
    const first = srv.requestOf(.action_complete, 0);
    const second = srv.requestOf(.action_complete, 1);
    try std.testing.expect(!std.mem.eql(u8, first[8..16], second[8..16]));
    try std.testing.expect(@import("test_server.zig").sameApartFromId(first, second));
}

test "ActionWorker resends a complete that timed out and never fails the task" {
    var srv = try ScriptServer.listen();
    srv.rules = &.{
        .{ .op = .action_await, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = test_task } } },
        .{ .op = .action_complete, .nth = 0, .action = .stall },
    };
    try srv.start();
    defer srv.deinit();

    var w: ActionWorker = undefined;
    try pollOnce(&srv, &w, 200);
    defer w.deinit();

    try std.testing.expectEqual(@as(u32, 2), srv.countOf(.action_complete));
    try std.testing.expectEqual(@as(u32, 0), srv.countOf(.action_fail));
}

test "ActionWorker does not resend a complete the server refused" {
    var srv = try ScriptServer.listen();
    srv.rules = &.{
        .{ .op = .action_await, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = test_task } } },
        .{ .op = .action_complete, .action = .{ .reply = .{ .status = @intFromEnum(types.StatusCode.conflict), .body = "\x09\x00\x01gone" } } },
    };
    try srv.start();
    defer srv.deinit();

    var w: ActionWorker = undefined;
    try pollOnce(&srv, &w, 5_000);
    defer w.deinit();

    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.action_complete));
    try std.testing.expectEqual(@as(u32, 0), srv.countOf(.action_fail));
    try std.testing.expectEqual(@as(u32, 1), srv.connections.load(.monotonic));
}

test "ActionWorker sends a result at most three times, then drops it" {
    var srv = try ScriptServer.listen();
    srv.rules = &.{
        .{ .op = .action_await, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = test_task } } },
        .{ .op = .action_complete, .action = .drop },
    };
    try srv.start();
    defer srv.deinit();

    var w: ActionWorker = undefined;
    try pollOnce(&srv, &w, 5_000);
    defer w.deinit();

    try std.testing.expectEqual(@as(u32, 3), srv.countOf(.action_complete));
    try std.testing.expectEqual(@as(u32, 0), srv.countOf(.action_fail));
}

/// Init a worker on `srv`, take `test_task`, stop the worker, then run the
/// task, so its result is reported while stopping.
fn executeWhileStopping(srv: *ScriptServer, w: *ActionWorker) !void {
    w.* = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 100 });
    try w.registerAction("job", test_handlers.ok);
    w.running = true;
    var actions = w.api();
    var task = (try actions.awaitTask(w.worker_id, w.action_names.items, .{ .block_ms = 100 })).?;
    defer task.deinit();
    w.stop();
    w.executeTask(&task);
}

test "ActionWorker still resends a lost result while stopping" {
    var srv = try ScriptServer.listen();
    srv.rules = &.{
        .{ .op = .action_await, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = test_task } } },
        .{ .op = .action_complete, .nth = 0, .action = .drop },
    };
    try srv.start();
    defer srv.deinit();

    var w: ActionWorker = undefined;
    try executeWhileStopping(&srv, &w);
    defer w.deinit();

    try std.testing.expectEqual(@as(u32, 2), srv.countOf(.action_complete));
    try std.testing.expectEqual(@as(u32, 2), srv.connections.load(.monotonic));
}

test "ActionWorker drops a lost result after about 2 s of reconnecting while stopping" {
    var srv = try ScriptServer.listen();
    srv.rules = &.{
        .{ .op = .action_await, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = test_task } } },
        .{ .op = .action_complete, .nth = 0, .action = .close },
    };
    try srv.start();
    defer srv.deinit();

    var timer = try std.time.Timer.start();
    var w: ActionWorker = undefined;
    try executeWhileStopping(&srv, &w);
    defer w.deinit();
    const elapsed_ms = timer.read() / std.time.ns_per_ms;

    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.action_complete));
    try std.testing.expect(!w.client.isConnected());
    try std.testing.expect(elapsed_ms >= 1_900 and elapsed_ms < 4_000);
}
