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
const Client = @import("client.zig").Client;
const Actions = @import("actions.zig").Actions;

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
    /// Action timeout in milliseconds (default: 5 minutes)
    action_timeout_ms: u64 = 300_000,
    /// Block timeout for awaiting tasks in milliseconds
    block_ms: u32 = 30_000,
    /// Heartbeat interval in milliseconds (default: 30s)
    heartbeat_interval_ms: u64 = 30_000,
    /// Optional metadata for this worker
    metadata: ?[]const u8 = null,
    /// Optional machine ID
    machine_id: ?[]const u8 = null,
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
    allocator: Allocator,
    actions: *Actions,
    worker_id: []const u8,

    /// Get the raw input payload.
    pub fn input(self: *const ActionContext) []const u8 {
        return self.payload;
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
            self.task_id,
            .{ .namespace = self.namespace, .extend_ms = extend_ms },
        );
    }
};

/// Action handler function type.
/// Returns the result bytes on success, or an error.
pub const ActionHandler = *const fn (*ActionContext) anyerror![]const u8;

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
    actions: Actions,
    worker_id: []const u8,
    handlers: std.StringHashMap(ActionHandler),
    action_names: std.ArrayListUnmanaged([]const u8),
    running: bool = false,
    draining: bool = false,
    active_tasks: u32 = 0,
    last_heartbeat_ns: i128 = 0,

    const Self = @This();

    /// Initialize a new ActionWorker.
    pub fn init(allocator: Allocator, config: WorkerConfig) !Self {
        var client = Client.init(allocator, config.endpoint, .{
            .namespace = config.namespace,
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
            .actions = Actions.init(&client),
            .worker_id = worker_id,
            .handlers = std.StringHashMap(ActionHandler).init(allocator),
            .action_names = .{},
        };
    }

    /// Deinitialize the worker and free resources.
    /// Deregisters from the server if connected.
    pub fn deinit(self: *Self) void {
        // Best-effort deregister
        self.actions.deregister(self.worker_id, .{
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

    /// Register an action handler.
    pub fn registerAction(self: *Self, action_name: []const u8, handler: ActionHandler) !void {
        if (self.handlers.contains(action_name)) {
            return error.ActionAlreadyRegistered;
        }

        // Register action with the server
        try self.actions.registerAction(action_name, .user, .{
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

        // Build process list for registration
        var processes: [64]types.ProcessEntry = undefined;
        const count = @min(self.action_names.items.len, 64);
        for (self.action_names.items[0..count], 0..) |name, i| {
            processes[i] = .{ .name = name, .kind = .action };
        }

        // Register worker with the server
        try self.actions.register(
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

        self.running = true;
        self.last_heartbeat_ns = std.time.nanoTimestamp();

        // Main polling loop
        while (self.running) {
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
                std.log.err("[flo-worker] Await error: {}, retrying...", .{err});
                std.Thread.sleep(1 * std.time.ns_per_s);
            };
        }

        std.log.info("[flo-worker] Worker stopped", .{});
    }

    /// Stop the worker immediately.
    pub fn stop(self: *Self) void {
        std.log.info("[flo-worker] Stopping worker...", .{});
        self.running = false;
    }

    /// Initiate graceful drain — finish current tasks but accept no new ones.
    pub fn drain(self: *Self) void {
        std.log.info("[flo-worker] Draining worker...", .{});
        self.draining = true;

        // Notify server
        self.actions.drain(self.worker_id, .{
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

        const status = self.actions.heartbeat(
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
        const task_opt = try self.actions.awaitTask(
            self.worker_id,
            self.action_names.items,
            .{
                .namespace = self.config.namespace,
                .block_ms = self.config.block_ms,
            },
        );

        if (task_opt) |task| {
            var task_mut = task;
            defer task_mut.deinit();
            self.active_tasks += 1;
            defer self.active_tasks -= 1;
            self.executeTask(&task_mut);
        }
    }

    /// Execute a task with error handling.
    fn executeTask(self: *Self, task: *TaskAssignment) void {
        std.log.info("[flo-worker] Executing action: {s} (task={s}, attempt={d})", .{
            task.task_type,
            task.task_id,
            task.attempt,
        });

        // Get handler
        const handler = self.handlers.get(task.task_type) orelse {
            std.log.err("[flo-worker] No handler for action: {s}", .{task.task_type});
            self.actions.fail(
                self.worker_id,
                task.task_id,
                "No handler registered",
                .{ .namespace = self.config.namespace },
            ) catch {};
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
            .allocator = self.allocator,
            .actions = &self.actions,
            .worker_id = self.worker_id,
        };

        // Execute handler
        if (handler(&ctx)) |result| {
            defer self.allocator.free(result);

            // Success - complete the task
            self.actions.complete(
                self.worker_id,
                task.task_id,
                result,
                .{ .namespace = self.config.namespace },
            ) catch |err| {
                std.log.err("[flo-worker] Failed to report completion: {}", .{err});
            };

            std.log.info("[flo-worker] Action completed: {s}", .{task.task_type});
        } else |err| {
            // Failure
            var error_buf: [256]u8 = undefined;
            const error_msg = std.fmt.bufPrint(&error_buf, "{}", .{err}) catch "Unknown error";

            std.log.err("[flo-worker] Action failed: {s} - {s}", .{ task.task_type, error_msg });

            self.actions.fail(
                self.worker_id,
                task.task_id,
                error_msg,
                .{
                    .namespace = self.config.namespace,
                    .retry = true,
                },
            ) catch |fail_err| {
                std.log.err("[flo-worker] Failed to report failure: {}", .{fail_err});
            };
        }
    }
};

/// Backwards-compatible alias.
pub const Worker = ActionWorker;

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
    try std.testing.expectEqual(@as(u64, 300_000), config.action_timeout_ms);
    try std.testing.expectEqual(@as(u32, 30_000), config.block_ms);
    try std.testing.expectEqual(@as(u64, 30_000), config.heartbeat_interval_ms);
}

test "generateWorkerId" {
    const allocator = std.testing.allocator;
    const id = try generateWorkerId(allocator);
    defer allocator.free(id);

    try std.testing.expect(id.len > 0);
}
