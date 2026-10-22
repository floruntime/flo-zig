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
//!     try worker.registerAction("process-order", processOrder, .{});
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
    /// How many tasks run at once. 1, the default, runs each on the polling
    /// loop, one after another. Above 1, each runs on a thread and a
    /// connection of its own, so handlers run concurrently and must be safe
    /// to, and init's allocator must be thread-safe (a GPA, c_allocator or
    /// page_allocator; not an arena or a fixed buffer).
    concurrency: u32 = 1,
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
    /// Touch each run every third of its action's timeout while the handler
    /// runs, from a thread on a connection of its own. Off by default: a
    /// handler that runs past the timeout without calling ctx.touch is
    /// taken back and run again. That thread allocates, so with auto_touch
    /// on the allocator given to init must be thread-safe (a GPA,
    /// c_allocator or page_allocator; not an arena or a fixed buffer). The
    /// outcome waits for a touch in flight, so a slow touch can hold it for
    /// up to the touch connection's timeout, times its retries.
    auto_touch: bool = false,
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
/// try worker.registerAction("my-action", myHandler, .{});
/// try worker.start();
/// ```
pub const ActionWorker = struct {
    allocator: Allocator,
    config: WorkerConfig,
    client: Client,
    worker_id: []const u8,
    handlers: std.StringHashMap(ActionHandler),
    action_names: std.ArrayListUnmanaged([]const u8),
    /// Both written from other threads (stop, drain); always accessed
    /// atomically.
    running: bool = false,
    backoff: types.EmptyPollBackoff = .{},
    draining: bool = false,
    /// Whether the server has been told of the drain, and when to try
    /// telling it again; the poll loop's alone.
    drain_sent: bool = false,
    drain_retry_ns: i128 = 0,
    active_tasks: u32 = 0,
    last_heartbeat_ns: i128 = 0,
    /// Each action's registered timeout_ms, keyed by its owned name.
    timeouts: std.StringHashMap(u32),
    /// auto_touch's connection for tasks run inline (concurrency 1), opened
    /// on first use; a slot has its own.
    touch_client: ?Client = null,
    /// With concurrency above 1, one slot per task that may run at once,
    /// allocated on the first poll (the worker has its final address by
    /// then). `pool_mutex` guards each slot's `busy` and `busy_count`;
    /// `pool_free` signals a slot coming free.
    slots: []Slot = &.{},
    pool_mutex: std.Thread.Mutex = .{},
    pool_free: std.Thread.Condition = .{},
    busy_count: u32 = 0,

    const Self = @This();

    /// One task running on a thread of its own, on its own connection: the
    /// poll connection is busy awaiting the next task, and a Client serves
    /// one request at a time. The handler's ctx.actions and the task's
    /// result use it; the connection outlives the task, for the next one.
    const Slot = struct {
        worker: *Self,
        client: ?Client = null,
        /// auto_touch's connection for this slot's tasks, opened on first
        /// use: a stalled touch then delays only its own task.
        touch_client: ?Client = null,
        task: TaskAssignment = undefined,
        thread: ?std.Thread = null,
        busy: bool = false,

        fn run(slot: *Slot) void {
            const w = slot.worker;
            w.executeTask(&slot.task, w.slotClient(slot), false, &slot.touch_client);
            slot.task.deinit();
            w.pool_mutex.lock();
            defer w.pool_mutex.unlock();
            slot.busy = false;
            w.busy_count -= 1;
            w.pool_free.signal();
        }
    };

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
            .timeouts = std.StringHashMap(u32).init(allocator),
        };
    }

    /// Deinitialize the worker and free resources.
    /// Deregisters from the server if connected. Waits, without a limit, for
    /// running handlers to return: a handler that never returns blocks it.
    pub fn deinit(self: *Self) void {
        // Best-effort deregister
        var actions = self.api();
        actions.deregister(self.worker_id, .{
            .namespace = self.config.namespace,
        }) catch {};

        self.releaseSlots();
        for (self.action_names.items) |name| {
            self.allocator.free(name);
        }
        self.action_names.deinit(self.allocator);
        self.handlers.deinit();
        self.timeouts.deinit();
        if (self.touch_client) |*c| c.deinit();
        self.allocator.free(self.worker_id);
        self.client.deinit();
    }

    /// Request API over this worker's connection. Built per use rather than
    /// stored: the worker is returned by value, so a pointer to its client
    /// taken in init would point at init's stack frame.
    fn api(self: *Self) Actions {
        return Actions.init(&self.client);
    }

    /// Register an action handler, and the action with the server with
    /// exactly `options` (`.{}`: the server's defaults, a 30 s timeout and 3
    /// attempts). Registering replaces the action's settings, so workers
    /// that register one action with different options leave it with
    /// whichever registered last. `options.namespace` is ignored: the action
    /// goes in the worker's.
    pub fn registerAction(self: *Self, action_name: []const u8, handler: ActionHandler, options: types.ActionRegisterOptions) !void {
        if (self.handlers.contains(action_name)) {
            return error.ActionAlreadyRegistered;
        }

        var reg = options;
        reg.namespace = self.config.namespace;
        var actions = self.api();
        try actions.registerAction(action_name, .user, reg);

        // Store handler
        const name_owned = try self.allocator.dupe(u8, action_name);
        errdefer self.allocator.free(name_owned);

        try self.handlers.put(name_owned, handler);
        errdefer _ = self.handlers.remove(name_owned);
        try self.timeouts.put(name_owned, options.timeout_ms);
        errdefer _ = self.timeouts.remove(name_owned);
        try self.action_names.append(self.allocator, name_owned);

        std.log.info("[flo-worker] Registered action: {s}", .{action_name});
    }

    /// Start the worker and begin processing actions.
    /// This function blocks until stop() is called or drain completes, then
    /// waits, without a limit, for running handlers to return and send their
    /// results: a handler that never returns blocks it.
    pub fn start(self: *Self) !void {
        if (self.handlers.count() == 0) {
            return error.NoActionsRegistered;
        }

        std.log.info("[flo-worker] Starting (id={s}, namespace={s}, concurrency={d})", .{
            self.worker_id,
            self.config.namespace,
            self.config.concurrency,
        });

        // Set before registering, so a stop() during it is kept. A drain is
        // cleared when the run ends, not here, so a drain() before or during
        // startup still ends it; a later start begins a fresh one.
        @atomicStore(bool, &self.running, true, .monotonic);
        errdefer @atomicStore(bool, &self.running, false, .monotonic);
        defer {
            @atomicStore(bool, &self.draining, false, .monotonic);
            self.drain_sent = false;
        }
        self.drain_retry_ns = 0;
        try self.registerWorker();
        self.last_heartbeat_ns = std.time.nanoTimestamp();
        var failed = retry_mod.workerBackoff();

        // Main polling loop
        while (@atomicLoad(bool, &self.running, .monotonic)) {
            // A drain is checked before the connection: it never needs the
            // server, so a worker that can't reach it still stops.
            if (@atomicLoad(bool, &self.draining, .monotonic)) {
                if (self.activeTasks() == 0) {
                    // One try at telling the server, if it can be reached.
                    if (!self.drain_sent and self.client.isConnected()) {
                        var actions = self.api();
                        if (actions.drain(self.worker_id, .{ .namespace = self.config.namespace })) {
                            self.drain_sent = true;
                        } else |err| std.log.warn("[flo-worker] Failed to notify server of drain: {}", .{err});
                    }
                    std.log.info("[flo-worker] Drain complete, shutting down", .{});
                    @atomicStore(bool, &self.running, false, .monotonic);
                    break;
                }
                // Tasks still run: keep the server told, and heartbeating.
                self.drainStep();
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            }

            if (!self.client.isConnected()) {
                self.reconnect() catch |err| {
                    std.log.warn("[flo-worker] Reconnect failed: {}, retrying...", .{err});
                    types.pauseUnlessHalted(&self.running, &self.draining, 1_000);
                    continue;
                };
            }

            // Send heartbeat if interval has elapsed
            self.maybeHeartbeat();

            self.pollAndExecute() catch |err| {
                if (client_mod.isConnectionError(err)) {
                    std.log.warn("[flo-worker] Connection lost: {}, reconnecting...", .{err});
                    self.client.disconnect();
                } else switch (self.awaitRefused(err)) {
                    .draining => {},
                    .unhealthy => types.pauseUnlessHalted(&self.running, &self.draining, failed.next(self.client.prng.random())),
                    .other => {
                        const ms = failed.next(self.client.prng.random());
                        std.log.err("[flo-worker] Await error: {}, retrying in {d}ms...", .{ err, ms });
                        types.pauseUnlessHalted(&self.running, &self.draining, ms);
                    },
                }
                continue;
            };
            failed.reset();
        }

        // Tasks still running finish and send their results.
        self.waitIdle();
        std.log.info("[flo-worker] Worker stopped", .{});
    }

    /// Open a fresh connection and register on it again. Gives up once the
    /// worker is stopped or draining: a drain finishes without the server.
    fn reconnect(self: *Self) !void {
        try self.client.reconnectWhile(&self.running, &self.draining);
        errdefer self.client.disconnect();
        try self.registerWorker();
    }

    /// Reconnect to resend a lost result. A stopping worker still tries,
    /// for about stopping_reconnect_ms, so a result produced as it stops
    /// isn't lost to a brief drop, yet stop isn't held up for long.
    /// `register`: `conn` is the poll connection, so the worker registers
    /// again on the fresh one; a slot's connection only carries results.
    fn reconnectForResult(self: *Self, conn: *Client, register: bool) !void {
        if (@atomicLoad(bool, &self.running, .monotonic)) {
            if (conn.reconnectWhile(&self.running, null)) {
                errdefer conn.disconnect();
                if (register) try self.registerWorker();
                return;
            } else |err| {
                if (@atomicLoad(bool, &self.running, .monotonic)) return err;
            }
        }
        try conn.reconnectFor(stopping_reconnect_ms);
        errdefer conn.disconnect();
        if (register) try self.registerWorker();
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

    /// Initiate graceful drain: finish current tasks but accept no new ones.
    /// Safe from any thread: it only sets a flag, and the poll loop tells
    /// the server on its own connection, then stops once the running tasks
    /// have reported. The loop sees the flag between polls, so that can take
    /// up to block_ms, and a task handed out meanwhile is still run.
    pub fn drain(self: *Self) void {
        std.log.info("[flo-worker] Draining worker...", .{});
        @atomicStore(bool, &self.draining, true, .monotonic);
    }

    /// While draining with tasks still running: tell the server of the drain
    /// if it hasn't heard (a failed notice is tried again, at most once a
    /// second), and keep heartbeating. A lost connection is tried once a
    /// second too, each connect bounded by the client's timeout_ms: the drain
    /// finishes without it. The fresh connection registers again, which
    /// marks the worker active, so the notice is sent again.
    fn drainStep(self: *Self) void {
        const now = std.time.nanoTimestamp();
        if (!self.client.isConnected()) {
            if (now < self.drain_retry_ns) return;
            self.drain_retry_ns = now + std.time.ns_per_s;
            self.client.connect() catch return;
            self.registerWorker() catch |err| {
                std.log.warn("[flo-worker] Failed to register again while draining: {}", .{err});
                self.client.disconnect();
                return;
            };
            self.drain_sent = false;
            self.drain_retry_ns = 0;
        }
        if (!self.drain_sent and now >= self.drain_retry_ns) {
            var actions = self.api();
            if (actions.drain(self.worker_id, .{ .namespace = self.config.namespace })) {
                self.drain_sent = true;
            } else |err| {
                std.log.warn("[flo-worker] Failed to notify server of drain: {}; trying again", .{err});
                self.drain_retry_ns = now + std.time.ns_per_s;
                if (client_mod.isConnectionError(err)) self.client.disconnect();
                return;
            }
        }
        self.maybeHeartbeat();
    }

    /// Send heartbeat if the interval has elapsed.
    fn maybeHeartbeat(self: *Self) void {
        const now = std.time.nanoTimestamp();
        const elapsed_ns = now - self.last_heartbeat_ns;
        const interval_ns: i128 = @as(i128, self.config.heartbeat_interval_ms) * std.time.ns_per_ms;

        if (elapsed_ns < interval_ns) return;

        self.heartbeat();
    }

    /// Heartbeat now. A worker the server removed for its silence is
    /// answered not found, and registers again: unregistered, it would go on
    /// taking work the registry doesn't know it holds. The registration marks
    /// it active, so a drain is told again.
    fn heartbeat(self: *Self) void {
        self.last_heartbeat_ns = std.time.nanoTimestamp();
        var actions = self.api();
        const status = actions.heartbeat(
            self.worker_id,
            self.activeTasks(),
            .{ .namespace = self.config.namespace },
        ) catch |err| {
            if (err != FloError.NotFound) {
                std.log.err("[flo-worker] Heartbeat failed: {}", .{err});
                return;
            }
            std.log.warn("[flo-worker] The server no longer knows this worker; registering again", .{});
            self.registerWorker() catch |rerr| {
                std.log.warn("[flo-worker] Failed to register again: {}", .{rerr});
                if (client_mod.isConnectionError(rerr)) self.client.disconnect();
                return;
            };
            if (@atomicLoad(bool, &self.draining, .monotonic)) {
                self.drain_sent = false;
                self.drain_retry_ns = 0;
            }
            return;
        };

        // Server may tell us to drain; it knows already, so nothing is sent.
        if (status == .draining) self.serverDrained();
    }

    /// The server is draining this worker: take no more work, as for drain().
    fn serverDrained(self: *Self) void {
        if (@atomicLoad(bool, &self.draining, .monotonic)) return;
        std.log.info("[flo-worker] Server requested drain", .{});
        self.drain_sent = true;
        @atomicStore(bool, &self.draining, true, .monotonic);
    }

    /// An await refused because the server sees this worker as unhealthy or
    /// draining. Unhealthy: heartbeat at once (registering again if it was
    /// removed), and the caller backs off before polling again. Draining:
    /// stop taking work. Matched on the reason, never the message.
    fn awaitRefused(self: *Self, err: anyerror) enum { unhealthy, draining, other } {
        if (err != FloError.BadRequest) return .other;
        const last = self.client.lastError() orelse return .other;
        switch (last.reason) {
            .worker_unhealthy => {
                std.log.warn("[flo-worker] Await refused: the server missed this worker's heartbeats; heartbeating", .{});
                self.heartbeat();
                return .unhealthy;
            },
            .worker_draining => {
                self.serverDrained();
                return .draining;
            },
            else => return .other,
        }
    }

    /// Tasks running now.
    fn activeTasks(self: *Self) u32 {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();
        return self.active_tasks + self.busy_count;
    }

    /// Poll for a task and run it: inline with concurrency 1, else on a
    /// free slot's thread. With every slot busy it waits a little for one
    /// and returns, so the loop still heartbeats and sees stop and drain.
    fn pollAndExecute(self: *Self) !void {
        var slot: ?*Slot = null;
        if (self.config.concurrency > 1) {
            try self.ensureSlots();
            slot = self.freeSlot() orelse {
                self.pool_mutex.lock();
                defer self.pool_mutex.unlock();
                if (self.busy_count == self.slots.len) self.pool_free.timedWait(&self.pool_mutex, 100 * std.time.ns_per_ms) catch {};
                return;
            };
        }

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
        if (slot) |s_| {
            // Its last task's thread has finished; reap it before reuse.
            if (s_.thread) |t| t.join();
            s_.thread = null;
            s_.task = task;
            self.pool_mutex.lock();
            s_.busy = true;
            self.busy_count += 1;
            self.pool_mutex.unlock();
            s_.thread = std.Thread.spawn(.{}, Slot.run, .{s_}) catch |err| {
                std.log.warn("[flo-worker] Can't start a thread for task {s}: {}; running it here", .{ task.task_id, err });
                s_.run();
                return;
            };
            return;
        }
        defer task.deinit();
        self.pool_mutex.lock();
        self.active_tasks += 1;
        self.pool_mutex.unlock();
        defer {
            self.pool_mutex.lock();
            self.active_tasks -= 1;
            self.pool_mutex.unlock();
        }
        self.executeTask(&task, &self.client, true, &self.touch_client);
    }

    fn ensureSlots(self: *Self) !void {
        if (self.slots.len > 0) return;
        const slots = try self.allocator.alloc(Slot, self.config.concurrency);
        for (slots) |*slot| slot.* = .{ .worker = self };
        self.slots = slots;
    }

    /// A slot no task holds, or null.
    fn freeSlot(self: *Self) ?*Slot {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();
        for (self.slots) |*slot| if (!slot.busy) return slot;
        return null;
    }

    /// `slot`'s connection, opened on first use and after a drop. A connect
    /// that fails leaves it closed: the handler still runs, and the result's
    /// send reconnects.
    fn slotClient(self: *Self, slot: *Slot) *Client {
        if (slot.client == null) slot.client = Client.init(self.allocator, self.config.endpoint, .{
            .namespace = self.config.namespace,
            .retry = self.config.retry,
            .timeout_ms = self.client.timeout_ms,
        });
        const client = &slot.client.?;
        if (!client.isConnected()) client.connect() catch |err| {
            std.log.warn("[flo-worker] Task connection: can't connect: {}", .{err});
        };
        return client;
    }

    /// Wait for every running task to finish and report.
    fn waitIdle(self: *Self) void {
        self.pool_mutex.lock();
        while (self.busy_count > 0) self.pool_free.wait(&self.pool_mutex);
        self.pool_mutex.unlock();
        for (self.slots) |*slot| if (slot.thread) |t| {
            t.join();
            slot.thread = null;
        };
    }

    fn releaseSlots(self: *Self) void {
        self.waitIdle();
        for (self.slots) |*slot| {
            if (slot.client) |*c| c.deinit();
            if (slot.touch_client) |*c| c.deinit();
        }
        if (self.slots.len > 0) self.allocator.free(self.slots);
        self.slots = &.{};
    }

    /// Execute a task with error handling.
    /// Run `task` and send its result on `conn`: the poll connection
    /// (`register`: register again on a fresh one) or a slot's. auto_touch
    /// touches it on `touch_conn`.
    fn executeTask(self: *Self, task: *TaskAssignment, conn: *Client, register: bool, touch_conn: *?Client) void {
        std.log.info("[flo-worker] Executing action: {s} (task={s}, attempt={d})", .{
            task.task_type,
            task.task_id,
            task.attempt,
        });

        var actions = Actions.init(conn);

        // Get handler
        const handler = self.handlers.get(task.task_type) orelse {
            std.log.err("[flo-worker] No handler for action: {s}", .{task.task_type});
            _ = self.report(conn, register, task, .{ .fail = .{ .message = "No handler registered" } });
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

        var toucher: Toucher = undefined;
        const touching = self.startTouching(&toucher, task, touch_conn);
        // The handler's outcome alone decides complete or fail: a complete
        // that can't be delivered is never turned into a fail.
        const outcome = handler(&ctx);
        // A touch in flight finishes before the outcome is sent.
        if (touching) |thread| {
            toucher.stop.set();
            thread.join();
        }
        if (outcome) |handler_result| {
            const sent = switch (handler_result) {
                .bytes => |data| blk: {
                    defer self.allocator.free(data);
                    break :blk self.report(conn, register, task, .{ .complete = .{ .data = data } });
                },
                .result => |ar| blk: {
                    defer if (ar.owned) self.allocator.free(ar.data);
                    break :blk self.report(conn, register, task, .{ .complete = .{ .data = ar.data, .outcome = ar.outcome } });
                },
            };
            if (sent) std.log.info("[flo-worker] Action completed: {s} (task={s})", .{ task.task_type, task.task_id });
        } else |err| {
            // Failure — check if non-retryable
            var error_buf: [256]u8 = undefined;
            const error_msg = std.fmt.bufPrint(&error_buf, "{}", .{err}) catch "Unknown error";

            std.log.err("[flo-worker] Action failed: {s} - {s}", .{ task.task_type, error_msg });
            _ = self.report(conn, register, task, .{ .fail = .{ .message = error_msg, .retry = err != error.NonRetryable } });
        }
    }

    /// auto_touch never touches more often, whatever the timeout.
    const min_touch_interval_ms: u32 = 100;
    /// The longest lease a touch may ask for; the server refuses more.
    const max_touch_extend_ms: u32 = 3_600_000;

    /// How often to touch a run of an action with `timeout_ms`, and the
    /// lease each touch asks for: the timeout, at most an hour, touched every
    /// third of that (at least min_touch_interval_ms apart) so two can fail
    /// in a row.
    fn touchPace(timeout_ms: u32) struct { interval_ms: u32, extend_ms: u32 } {
        const extend_ms = @min(timeout_ms, max_touch_extend_ms);
        return .{ .interval_ms = @max(extend_ms / 3, min_touch_interval_ms), .extend_ms = extend_ms };
    }

    /// One task's touching thread and the event that stops it.
    const Toucher = struct {
        worker: *Self,
        task: *const TaskAssignment,
        client: *?Client,
        interval_ns: u64,
        extend_ms: u32,
        stop: std.Thread.ResetEvent = .{},

        fn run(t: *Toucher) void {
            while (true) {
                t.stop.timedWait(t.interval_ns) catch {
                    if (t.worker.touchOnce(t.client, t.task, t.extend_ms)) continue;
                    return;
                };
                return; // stopped
            }
        }
    };

    /// Start touching `task` on a thread, when auto_touch is on and its
    /// action times out; null otherwise, or when the thread can't start.
    fn startTouching(self: *Self, toucher: *Toucher, task: *const TaskAssignment, touch_conn: *?Client) ?std.Thread {
        if (!self.config.auto_touch) return null;
        const timeout_ms = self.timeouts.get(task.task_type) orelse return null;
        if (timeout_ms == 0) return null;
        const pace = touchPace(timeout_ms);
        toucher.* = .{ .worker = self, .task = task, .client = touch_conn, .interval_ns = @as(u64, pace.interval_ms) * std.time.ns_per_ms, .extend_ms = pace.extend_ms };
        return std.Thread.spawn(.{}, Toucher.run, .{toucher}) catch |err| {
            std.log.err("[flo-worker] Can't start touching task {s}: {}", .{ task.task_id, err });
            return null;
        };
    }

    /// Touch `task` once on the touch connection; false when touching should
    /// stop. Each touch asks for this worker's timeout (at most an hour), so
    /// the lease covers it even if another worker's registration shortened
    /// the action's. Conflict, not found or bad request means the run moved
    /// on; any other refusal, or a lost touch, is tried again next interval.
    fn touchOnce(self: *Self, touch_conn: *?Client, task: *const TaskAssignment, extend_ms: u32) bool {
        if (touch_conn.* == null) {
            touch_conn.* = Client.init(self.allocator, self.config.endpoint, .{
                .namespace = self.config.namespace,
                .retry = self.config.retry,
            });
        }
        const client = &touch_conn.*.?;
        if (!client.isConnected()) client.connect() catch |err| {
            std.log.warn("[flo-worker] Touch for task {s}: can't connect: {}", .{ task.task_id, err });
            return true;
        };
        var actions = Actions.init(client);
        actions.touch(self.worker_id, task.task_type, task.task_id, .{
            .namespace = self.config.namespace,
            .extend_ms = extend_ms,
        }) catch |err| switch (err) {
            FloError.Conflict, FloError.NotFound, FloError.BadRequest => {
                std.log.warn("[flo-worker] Touch for task {s} was refused, stopping: {}", .{ task.task_id, err });
                return false;
            },
            else => {
                std.log.warn("[flo-worker] Touch for task {s} failed: {}; trying again", .{ task.task_id, err });
                if (client_mod.isConnectionError(err)) client.disconnect();
            },
        };
        return true;
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
    fn report(self: *Self, conn: *Client, register: bool, task: *const TaskAssignment, rep: Report) bool {
        const kind = @tagName(rep);
        var actions = Actions.init(conn);
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
            conn.disconnect();
            self.reconnectForResult(conn, register) catch |rerr| {
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
    try std.testing.expectEqual(@as(u32, 1), config.concurrency);
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

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 100, .concurrency = 1 });
    defer w.deinit();
    w.client.timeout_ms = 200;
    try w.registerAction("job", handler, .{});

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
    try w.registerAction("noop", noop, .{});
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
    w.* = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 100, .concurrency = 1 });
    w.client.timeout_ms = timeout_ms;
    try w.registerAction("job", test_handlers.ok, .{});
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
    w.* = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 100, .concurrency = 1 });
    try w.registerAction("job", test_handlers.ok, .{});
    w.running = true;
    var actions = w.api();
    var task = (try actions.awaitTask(w.worker_id, w.action_names.items, .{ .block_ms = 100 })).?;
    defer task.deinit();
    w.stop();
    w.executeTask(&task, &w.client, true, &w.touch_client);
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

const touch_test = struct {
    fn sleeps(comptime ms: u64) ActionHandler {
        return struct {
            fn run(ctx: *ActionContext) anyerror!ActionHandlerResult {
                std.Thread.sleep(ms * std.time.ns_per_ms);
                return .{ .bytes = try ctx.allocator.dupe(u8, "done") };
            }
        }.run;
    }

    /// A worker with retrying off (so each touch the server sees is one the
    /// worker sent) and action "job" registered with `timeout_ms`, polled
    /// once: the await gets `test_task` and `handler` runs.
    fn run(srv: *ScriptServer, w: *ActionWorker, auto_touch: bool, timeout_ms: u32, handler: ActionHandler) !void {
        w.* = try ActionWorker.init(std.testing.allocator, .{
            .endpoint = srv.endpoint,
            .block_ms = 100,
            .concurrency = 1,
            .auto_touch = auto_touch,
            .retry = .{ .max_attempts = 1 },
        });
        // A failing poll still hangs up, so the test fails instead of hanging.
        errdefer w.deinit();
        try w.registerAction("job", handler, .{ .timeout_ms = timeout_ms });
        w.running = true;
        try w.pollAndExecute();
    }

    /// Where the first request with `op` sits in the server's log.
    fn indexOf(srv: *ScriptServer, op: types.OpCode) ?usize {
        srv.mutex.lock();
        defer srv.mutex.unlock();
        for (srv.log[0..srv.count], 0..) |r, i| if (r.op == op) return i;
        return null;
    }
};

test "ActionWorker registers an action with exactly the options it was given, in its own namespace" {
    var srv = try ScriptServer.listen();
    try srv.start();
    defer srv.deinit();
    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .namespace = "mine" });
    defer w.deinit();
    try w.registerAction("job", test_handlers.ok, .{ .namespace = "elsewhere", .timeout_ms = 600_000, .max_retries = 5, .owner = "payments" });
    // [type][timeout_ms][max_retries][owner_len][owner], as the server parses it.
    const want = "\x00" ++ "\xc0\x27\x09\x00" ++ "\x05\x00\x00\x00" ++ "\x08\x00" ++ "payments";
    const req = srv.requestOf(.action_register, 0);
    try std.testing.expect(std.mem.indexOf(u8, req, want) != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "elsewhere") == null);
    try std.testing.expectEqual(@as(?u32, 600_000), w.timeouts.get("job"));
}

test "ActionWorker refuses an action owner too long to register" {
    var srv = try ScriptServer.listen();
    try srv.start();
    defer srv.deinit();
    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint });
    defer w.deinit();
    const long = "o" ** 1025;
    try std.testing.expectError(FloError.ValueTooLarge, w.registerAction("job", test_handlers.ok, .{ .owner = long }));
    try std.testing.expectEqual(@as(u32, 0), srv.countOf(.action_register));
}

test "ActionWorker's touch pace is a third of the lease it asks for, which is at most an hour" {
    for ([_][3]u32{
        .{ 300, 100, 300 },
        .{ 30_000, 10_000, 30_000 },
        .{ 60, 100, 60 },
        .{ 4 * 3_600_000, 1_200_000, 3_600_000 },
    }) |c| {
        const pace = ActionWorker.touchPace(c[0]);
        try std.testing.expectEqual(c[1], pace.interval_ms);
        try std.testing.expectEqual(c[2], pace.extend_ms);
    }
}

test "ActionWorker with auto_touch touches a running task on its own connection, and stops before the complete" {
    var srv = try ScriptServer.listen();
    srv.concurrent = true;
    srv.rules = &.{.{ .op = .action_await, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = test_task } } }};
    try srv.start();
    defer srv.deinit();
    var w: ActionWorker = undefined;
    // A 300 ms timeout touches every 100 ms: a 450 ms handler gets about four.
    try touch_test.run(&srv, &w, true, 300, touch_test.sleeps(450));
    defer w.deinit();
    std.Thread.sleep(250 * std.time.ns_per_ms);
    const touches = srv.countOf(.action_touch);
    try std.testing.expect(touches >= 2 and touches <= 5);
    try std.testing.expectEqual(@as(u32, 2), srv.connections.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.action_complete));
    // Every touch came before the complete, and asked for 300 ms after "t1".
    var last_touch: usize = 0;
    srv.mutex.lock();
    for (srv.log[0..srv.count], 0..) |r, i| {
        if (r.op != .action_touch) continue;
        last_touch = i;
        try std.testing.expect(std.mem.indexOf(u8, r.bytes[0..r.len], "t1" ++ "\x2c\x01\x00\x00") != null);
    }
    srv.mutex.unlock();
    try std.testing.expect(last_touch < touch_test.indexOf(&srv, .action_complete).?);
}

test "ActionWorker touches nothing without auto_touch, or when the action never times out" {
    inline for (.{ .{ false, 300 }, .{ true, 0 } }) |c| {
        var srv = try ScriptServer.listen();
        srv.concurrent = true;
        srv.rules = &.{.{ .op = .action_await, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = test_task } } }};
        try srv.start();
        defer srv.deinit();
        var w: ActionWorker = undefined;
        try touch_test.run(&srv, &w, c[0], c[1], touch_test.sleeps(350));
        defer w.deinit();
        try std.testing.expectEqual(@as(u32, 0), srv.countOf(.action_touch));
    }
}

test "ActionWorker stops touching on a refusal that means the run moved on, and carries on after others" {
    // [reason:u16][ran:u8][message]
    const refusal = "\x0c\x00\x00" ++ "no";
    inline for (.{
        .{ types.StatusCode.conflict, true },
        .{ types.StatusCode.not_found, true },
        .{ types.StatusCode.bad_request, true },
        .{ types.StatusCode.overloaded, false },
    }) |c| {
        var srv = try ScriptServer.listen();
        srv.concurrent = true;
        srv.rules = &.{
            .{ .op = .action_await, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = test_task } } },
            .{ .op = .action_touch, .action = .{ .reply = .{ .status = @intFromEnum(c[0]), .body = refusal } } },
        };
        try srv.start();
        defer srv.deinit();
        var w: ActionWorker = undefined;
        try touch_test.run(&srv, &w, true, 300, touch_test.sleeps(450));
        defer w.deinit();
        if (c[1]) {
            try std.testing.expectEqual(@as(u32, 1), srv.countOf(.action_touch));
        } else {
            try std.testing.expect(srv.countOf(.action_touch) >= 2);
        }
    }
}

test "ActionWorker lets a touch in flight finish before it sends the complete" {
    var srv = try ScriptServer.listen();
    srv.concurrent = true;
    // The touch at 100 ms is answered at 250 ms; the handler ends at 150 ms.
    srv.rules = &.{
        .{ .op = .action_await, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = test_task } } },
        .{ .op = .action_touch, .action = .{ .reply = .{ .status = 0, .delay_ms = 150 } } },
    };
    try srv.start();
    defer srv.deinit();
    var w: ActionWorker = undefined;
    var timer = try std.time.Timer.start();
    try touch_test.run(&srv, &w, true, 300, touch_test.sleeps(150));
    defer w.deinit();
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.action_touch));
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.action_complete));
    // The complete waited for the touch's answer.
    try std.testing.expect(timer.read() >= 240 * std.time.ns_per_ms);
}

const second_task = "\x02\x00t2\x03\x00job" ++ "\x00" ** 8 ++ "\x01\x00\x00\x00" ++ "\x00";

const concurrency_test = struct {
    var in_flight = std.atomic.Value(u32).init(0);
    var most = std.atomic.Value(u32).init(0);

    /// Waits up to 2 s for another handler to be running too.
    fn meets(ctx: *ActionContext) anyerror!ActionHandlerResult {
        const now = in_flight.fetchAdd(1, .acq_rel) + 1;
        _ = most.fetchMax(now, .acq_rel);
        var waited: u32 = 0;
        while (in_flight.load(.acquire) < 2 and waited < 2000) : (waited += 10) std.Thread.sleep(10 * std.time.ns_per_ms);
        _ = most.fetchMax(in_flight.load(.acquire), .acq_rel);
        std.Thread.sleep(50 * std.time.ns_per_ms);
        _ = in_flight.fetchSub(1, .acq_rel);
        return .{ .bytes = try ctx.allocator.dupe(u8, "done") };
    }

    /// `meets`, then runs long enough for auto_touch to touch it.
    fn meetsLong(ctx: *ActionContext) anyerror!ActionHandlerResult {
        const result = try meets(ctx);
        std.Thread.sleep(300 * std.time.ns_per_ms);
        return result;
    }

    fn waitFor(srv: *ScriptServer, op: types.OpCode, n: u32, ms: u32) bool {
        var waited: u32 = 0;
        while (srv.countOf(op) < n) : (waited += 10) {
            if (waited >= ms) return false;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        return true;
    }
};

test "ActionWorker runs up to `concurrency` tasks at once, each sending its result on its own connection" {
    var srv = try ScriptServer.listen();
    srv.concurrent = true;
    srv.rules = &.{
        .{ .op = .action_await, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = test_task } } },
        .{ .op = .action_await, .nth = 1, .action = .{ .reply = .{ .status = 0, .body = second_task } } },
    };
    try srv.start();
    defer srv.deinit();
    concurrency_test.in_flight.store(0, .release);
    concurrency_test.most.store(0, .release);

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 100, .concurrency = 2 });
    defer w.deinit();
    try w.registerAction("job", concurrency_test.meets, .{});
    const thread = try std.Thread.spawn(.{}, runWorker, .{&w});
    const done = concurrency_test.waitFor(&srv, .action_complete, 2, 5_000);
    w.stop();
    thread.join();

    try std.testing.expect(done);
    // Both handlers were running at once: one at a time, each would have
    // waited out its 2 s alone.
    try std.testing.expectEqual(@as(u32, 2), concurrency_test.most.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), srv.countOf(.action_fail));
    // The poll connection, and one per task that ran.
    try std.testing.expectEqual(@as(u32, 3), srv.connections.load(.monotonic));
}

test "ActionWorker stopped while a task runs still sends that task's result before start returns" {
    var srv = try ScriptServer.listen();
    srv.concurrent = true;
    srv.rules = &.{.{ .op = .action_await, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = test_task } } }};
    try srv.start();
    defer srv.deinit();

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 100, .concurrency = 4 });
    defer w.deinit();
    try w.registerAction("job", touch_test.sleeps(300), .{});
    const thread = try std.Thread.spawn(.{}, runWorker, .{&w});
    // The handler is running once the task is out.
    try std.testing.expect(concurrency_test.waitFor(&srv, .action_await, 2, 5_000));
    w.stop();
    thread.join();
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.action_complete));
}

test "ActionWorker gives each concurrent task's auto_touch a connection of its own" {
    var srv = try ScriptServer.listen();
    srv.concurrent = true;
    srv.rules = &.{
        .{ .op = .action_await, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = test_task } } },
        .{ .op = .action_await, .nth = 1, .action = .{ .reply = .{ .status = 0, .body = second_task } } },
    };
    try srv.start();
    defer srv.deinit();
    concurrency_test.in_flight.store(0, .release);
    concurrency_test.most.store(0, .release);

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 100, .concurrency = 2, .auto_touch = true });
    defer w.deinit();
    // A 300 ms timeout touches every 100 ms, while the two handlers wait
    // for each other.
    try w.registerAction("job", concurrency_test.meetsLong, .{ .timeout_ms = 300 });
    const thread = try std.Thread.spawn(.{}, runWorker, .{&w});
    const done = concurrency_test.waitFor(&srv, .action_complete, 2, 5_000);
    w.stop();
    thread.join();

    try std.testing.expect(done);
    try std.testing.expectEqual(@as(u32, 2), concurrency_test.most.load(.acquire));
    // The poll connection, and per task one for its result and one for its
    // touches: a stalled touch holds up only its own task.
    try std.testing.expectEqual(@as(u32, 5), srv.connections.load(.monotonic));
}

test "ActionWorker drain from another thread only sets the flag, and the poll loop tells the server, then start returns" {
    var srv = try ScriptServer.listen();
    // The await is answered after 500 ms, so the poll loop is inside it when
    // drain is called.
    srv.rules = &.{.{ .op = .action_await, .action = .{ .reply = .{ .status = 0, .delay_ms = 500 } } }};
    try srv.start();
    defer srv.deinit();

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 1000 });
    defer w.deinit();
    try w.registerAction("job", test_handlers.ok, .{});
    const thread = try std.Thread.spawn(.{}, runWorker, .{&w});
    std.Thread.sleep(150 * std.time.ns_per_ms);
    w.drain();
    // drain() sent nothing itself: sending from this thread would share
    // the poll connection with the await in flight.
    try std.testing.expectEqual(@as(u32, 0), srv.countOf(.worker_drain));
    thread.join();
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.worker_drain));
    try std.testing.expectEqual(@as(u32, 1), srv.connections.load(.monotonic));
}

test "ActionWorker tells the server of a drain once, though tasks still run while it waits for them" {
    var srv = try ScriptServer.listen();
    srv.concurrent = true;
    srv.rules = &.{.{ .op = .action_await, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = test_task } } }};
    try srv.start();
    defer srv.deinit();

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 100, .concurrency = 2 });
    defer w.deinit();
    // The loop goes round many times while this runs, still draining.
    try w.registerAction("job", touch_test.sleeps(400), .{});
    const thread = try std.Thread.spawn(.{}, runWorker, .{&w});
    var waited: u32 = 0;
    while (srv.countOf(.action_await) < 1 and waited < 5000) : (waited += 10) std.Thread.sleep(10 * std.time.ns_per_ms);
    std.Thread.sleep(50 * std.time.ns_per_ms);
    w.drain();
    thread.join();
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.worker_drain));
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.action_complete));
}

const drain_test = struct {
    var returned = std.atomic.Value(bool).init(false);

    fn run(w: *ActionWorker) void {
        w.start() catch {};
        returned.store(true, .release);
    }

    /// Whether start returned within `ms`; stops the worker if not, so a
    /// failing test ends instead of hanging.
    fn returnedWithin(w: *ActionWorker, ms: u32) bool {
        var waited: u32 = 0;
        while (!returned.load(.acquire) and waited < ms) : (waited += 10) std.Thread.sleep(10 * std.time.ns_per_ms);
        const ok = returned.load(.acquire);
        if (!ok) w.stop();
        return ok;
    }
};

test "ActionWorker finishes a drain while it can't reach the server" {
    var srv = try ScriptServer.listen();
    srv.rules = &.{
        // The first await loses the connection, and every reconnect's
        // registration is cut off too.
        .{ .op = .action_await, .action = .drop },
        .{ .op = .worker_register, .nth = 1, .action = .drop },
        .{ .op = .worker_register, .nth = 2, .action = .drop },
        .{ .op = .worker_register, .nth = 3, .action = .drop },
        .{ .op = .worker_register, .nth = 4, .action = .drop },
    };
    try srv.start();
    defer srv.deinit();

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 100, .retry = .{ .max_attempts = 1 } });
    defer w.deinit();
    try w.registerAction("job", test_handlers.ok, .{});
    drain_test.returned.store(false, .release);
    const thread = try std.Thread.spawn(.{}, drain_test.run, .{&w});
    defer thread.join();
    // Reconnecting by now, and failing.
    std.Thread.sleep(300 * std.time.ns_per_ms);
    w.drain();
    try std.testing.expect(drain_test.returnedWithin(&w, 3_000));
}

test "ActionWorker tells the server of a drain again when the first notice fails" {
    var srv = try ScriptServer.listen();
    srv.concurrent = true;
    srv.rules = &.{
        .{ .op = .action_await, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = test_task } } },
        // [reason:u16][ran:u8][message]: refused, not run.
        .{ .op = .worker_drain, .nth = 0, .action = .{ .reply = .{ .status = @intFromEnum(types.StatusCode.overloaded), .body = "\x0c\x00\x00busy" } } },
    };
    try srv.start();
    defer srv.deinit();

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 100, .concurrency = 2, .retry = .{ .max_attempts = 1 } });
    defer w.deinit();
    // Runs long enough for a second notice a second after the first.
    try w.registerAction("job", touch_test.sleeps(1_600), .{});
    const thread = try std.Thread.spawn(.{}, runWorker, .{&w});
    var waited: u32 = 0;
    while (srv.countOf(.action_await) < 1 and waited < 5000) : (waited += 10) std.Thread.sleep(10 * std.time.ns_per_ms);
    std.Thread.sleep(50 * std.time.ns_per_ms);
    w.drain();
    thread.join();
    try std.testing.expectEqual(@as(u32, 2), srv.countOf(.worker_drain));
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.action_complete));
}

test "ActionWorker finishes a drain while the server refuses connections" {
    var srv = try ScriptServer.listen();
    // The first await hangs up and stops the listener: every reconnect is
    // refused, and the worker backs off between them.
    srv.rules = &.{.{ .op = .action_await, .action = .close }};
    try srv.start();
    defer srv.deinit();

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 100, .retry = .{ .max_attempts = 1 } });
    defer w.deinit();
    try w.registerAction("job", test_handlers.ok, .{});
    drain_test.returned.store(false, .release);
    const thread = try std.Thread.spawn(.{}, drain_test.run, .{&w});
    defer thread.join();
    // Inside the reconnect's first 1 s wait by now.
    std.Thread.sleep(300 * std.time.ns_per_ms);
    w.drain();
    try std.testing.expect(drain_test.returnedWithin(&w, 500));
}

test "ActionWorker drained before start returns without polling" {
    var srv = try ScriptServer.listen();
    try srv.start();
    defer srv.deinit();

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 100 });
    defer w.deinit();
    try w.registerAction("job", test_handlers.ok, .{});
    w.drain();
    drain_test.returned.store(false, .release);
    const thread = try std.Thread.spawn(.{}, drain_test.run, .{&w});
    defer thread.join();
    try std.testing.expect(drain_test.returnedWithin(&w, 2_000));
    try std.testing.expectEqual(@as(u32, 0), srv.countOf(.action_await));
}

test "ActionWorker registers again on the connection its drain reopens, then tells the server again" {
    var srv = try ScriptServer.listen();
    srv.concurrent = true;
    srv.rules = &.{
        .{ .op = .action_await, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = test_task } } },
        // The first notice loses the poll connection.
        .{ .op = .worker_drain, .nth = 0, .action = .drop },
    };
    try srv.start();
    defer srv.deinit();

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 100, .concurrency = 2, .retry = .{ .max_attempts = 1 } });
    defer w.deinit();
    // Runs long enough for the reconnect a second after the lost notice.
    try w.registerAction("job", touch_test.sleeps(1_600), .{});
    const thread = try std.Thread.spawn(.{}, runWorker, .{&w});
    var waited: u32 = 0;
    while (srv.countOf(.action_await) < 1 and waited < 5000) : (waited += 10) std.Thread.sleep(10 * std.time.ns_per_ms);
    std.Thread.sleep(50 * std.time.ns_per_ms);
    w.drain();
    thread.join();
    try std.testing.expectEqual(@as(u32, 2), srv.countOf(.worker_register));
    try std.testing.expectEqual(@as(u32, 2), srv.countOf(.worker_drain));
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.action_complete));
}

test "ActionWorker started again after a drain polls again" {
    var srv = try ScriptServer.listen();
    try srv.start();
    defer srv.deinit();

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 100 });
    defer w.deinit();
    try w.registerAction("job", test_handlers.ok, .{});
    const first = try std.Thread.spawn(.{}, runWorker, .{&w});
    std.Thread.sleep(100 * std.time.ns_per_ms);
    w.drain();
    first.join();

    drain_test.returned.store(false, .release);
    const awaits = srv.countOf(.action_await);
    const second = try std.Thread.spawn(.{}, drain_test.run, .{&w});
    std.Thread.sleep(300 * std.time.ns_per_ms);
    // Still running, and polling: not ended by the last run's drain.
    try std.testing.expect(!drain_test.returned.load(.acquire));
    try std.testing.expect(srv.countOf(.action_await) > awaits);
    w.stop();
    second.join();
}

/// A refusal's body: [reason:u16][ran:u8][message].
const not_found_refusal = "\x0c\x00\x00worker not found";
const unhealthy_refusal = "\x1b\x00\x00worker missed its heartbeats; send one, or register again";
const draining_refusal = "\x1c\x00\x00worker is draining";

test "ActionWorker registers again, with the same options, when its heartbeat finds it removed" {
    const value_of = @import("test_server.zig").valueOf;
    var srv = try ScriptServer.listen();
    srv.rules = &.{.{ .op = .worker_heartbeat, .nth = 0, .action = .{ .reply = .{ .status = @intFromEnum(types.StatusCode.not_found), .body = not_found_refusal } } }};
    try srv.start();
    defer srv.deinit();

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .concurrency = 3, .metadata = "{\"gpu\":true}", .machine_id = "host-1" });
    defer w.deinit();
    try w.registerAction("job", test_handlers.ok, .{});
    try w.registerWorker();
    w.heartbeat();

    try std.testing.expectEqual(@as(u32, 2), srv.countOf(.worker_register));
    const first = value_of(srv.requestOf(.worker_register, 0));
    try std.testing.expect(std.mem.indexOf(u8, first, "host-1") != null);
    try std.testing.expectEqualSlices(u8, first, value_of(srv.requestOf(.worker_register, 1)));
    // A heartbeat that finds it known registers nothing.
    w.heartbeat();
    try std.testing.expectEqual(@as(u32, 2), srv.countOf(.worker_register));
}

test "ActionWorker removed while draining tells the server of the drain again after registering" {
    var srv = try ScriptServer.listen();
    srv.rules = &.{.{ .op = .worker_heartbeat, .nth = 0, .action = .{ .reply = .{ .status = @intFromEnum(types.StatusCode.not_found), .body = not_found_refusal } } }};
    try srv.start();
    defer srv.deinit();

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .heartbeat_interval_ms = 0 });
    defer w.deinit();
    try w.registerAction("job", test_handlers.ok, .{});
    try w.registerWorker();
    // Draining, and the server told: the step only heartbeats.
    w.draining = true;
    w.drain_sent = true;
    w.drainStep();
    try std.testing.expectEqual(@as(u32, 2), srv.countOf(.worker_register));
    try std.testing.expectEqual(@as(u32, 0), srv.countOf(.worker_drain));
    w.drainStep();
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.worker_drain));
}

test "ActionWorker heartbeats at once when an await is refused as unhealthy, and backs off before polling again" {
    var srv = try ScriptServer.listen();
    srv.rules = &.{.{ .op = .action_await, .action = .{ .reply = .{ .status = @intFromEnum(types.StatusCode.bad_request), .body = unhealthy_refusal } } }};
    try srv.start();
    defer srv.deinit();

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 100 });
    defer w.deinit();
    try w.registerAction("job", test_handlers.ok, .{});
    const thread = try std.Thread.spawn(.{}, runWorker, .{&w});
    std.Thread.sleep(600 * std.time.ns_per_ms);
    w.stop();
    thread.join();

    const awaits = srv.countOf(.action_await);
    // Each refusal is answered with a heartbeat, though the interval (30 s)
    // is far off.
    try std.testing.expect(awaits >= 1);
    try std.testing.expectEqual(awaits, srv.countOf(.worker_heartbeat));
    // Backing off from 100 ms: a handful of polls, not a hot loop.
    try std.testing.expect(awaits <= 12);
}

test "ActionWorker stops taking work when an await is refused as draining" {
    var srv = try ScriptServer.listen();
    srv.rules = &.{.{ .op = .action_await, .action = .{ .reply = .{ .status = @intFromEnum(types.StatusCode.bad_request), .body = draining_refusal } } }};
    try srv.start();
    defer srv.deinit();

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 100 });
    defer w.deinit();
    try w.registerAction("job", test_handlers.ok, .{});
    drain_test.returned.store(false, .release);
    const thread = try std.Thread.spawn(.{}, drain_test.run, .{&w});
    defer thread.join();
    try std.testing.expect(drain_test.returnedWithin(&w, 2_000));
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.action_await));
    // The server drained it, so it isn't told.
    try std.testing.expectEqual(@as(u32, 0), srv.countOf(.worker_drain));
}

test "ActionWorker heartbeats the handlers running, not a slot waiting on a poll" {
    const value_of = @import("test_server.zig").valueOf;
    var srv = try ScriptServer.listen();
    srv.concurrent = true;
    srv.rules = &.{
        .{ .op = .action_await, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = test_task } } },
        .{ .op = .action_await, .action = .{ .reply = .{ .status = 0, .delay_ms = 30 } } },
    };
    try srv.start();
    defer srv.deinit();

    var w = try ActionWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .block_ms = 100, .concurrency = 2, .heartbeat_interval_ms = 1 });
    defer w.deinit();
    try w.registerAction("job", touch_test.sleeps(300), .{});
    const thread = try std.Thread.spawn(.{}, runWorker, .{&w});
    std.Thread.sleep(200 * std.time.ns_per_ms);
    w.stop();
    thread.join();

    // One handler ran throughout while the other slot polled: every
    // heartbeat while it ran reports 1, never 2.
    const heartbeats = srv.countOf(.worker_heartbeat);
    try std.testing.expect(heartbeats >= 1);
    var ones: u32 = 0;
    for (0..heartbeats) |i| {
        const load = std.mem.readInt(u32, value_of(srv.requestOf(.worker_heartbeat, @intCast(i)))[0..4], .little);
        try std.testing.expect(load <= 1);
        ones += @intFromBool(load == 1);
    }
    try std.testing.expect(ones >= 1);
}
