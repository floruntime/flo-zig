//! Flo High-Level Stream Worker API
//!
//! Provides a StreamWorker for consuming stream records via consumer groups.
//! Includes auto-ack/nack, worker registry integration, heartbeat, and graceful shutdown.
//!
//! ## Example
//!
//! ```zig
//! const flo = @import("flo");
//!
//! fn processRecord(ctx: *flo.StreamContext) anyerror!void {
//!     const payload = ctx.payload();
//!     // Process the record...
//!     std.debug.print("Got: {s}\n", .{payload});
//! }
//!
//! pub fn main() !void {
//!     var sw = try flo.StreamWorker.init(allocator, .{
//!         .endpoint = "localhost:3000",
//!         .namespace = "myapp",
//!         .stream = "events",
//!         .group = "my-group",
//!     }, processRecord);
//!     defer sw.deinit();
//!
//!     try sw.start();
//! }
//! ```

const std = @import("std");
const types = @import("types.zig");
const client_mod = @import("client.zig");
const Client = client_mod.Client;
const Stream = @import("stream.zig").Stream;
const Actions = @import("actions.zig").Actions;
const retry_mod = @import("retry.zig");

const FloError = types.FloError;
const StreamRecord = types.StreamRecord;
const StreamID = types.StreamID;
const Allocator = std.mem.Allocator;

/// Configuration for the StreamWorker.
pub const StreamWorkerConfig = struct {
    /// Server endpoint (e.g., "localhost:3000")
    endpoint: []const u8,
    /// Namespace for operations
    namespace: []const u8 = "default",
    /// Stream to consume from (use this for single-stream, or `streams` for multi-stream)
    stream: []const u8 = "",
    /// Multiple streams to consume from (alternative to `stream`)
    streams: ?[]const []const u8 = null,
    /// Consumer group name
    group: []const u8 = "default",
    /// Consumer name within the group (defaults to worker_id)
    consumer: ?[]const u8 = null,
    /// Unique worker ID (auto-generated if null)
    worker_id: ?[]const u8 = null,
    /// How many records of a batch are handled at once. 1, the default,
    /// handles them in order on the polling loop. Above 1, each runs on a
    /// thread with a connection of its own for its ack or nack, so a batch's
    /// records are handled out of order, handlers must be safe to run
    /// concurrently, and init's allocator must be thread-safe (a GPA,
    /// c_allocator or page_allocator; not an arena). The next read waits
    /// for the whole batch, so at most min(concurrency, batch_size) run at
    /// once.
    concurrency: u32 = 1,
    /// Number of messages to read per poll (default: 10)
    batch_size: u32 = 10,
    /// Long-poll wait per read in ms. 0 means DEFAULT_WORKER_BLOCK_MS; over
    /// MAX_BLOCK_MS, StreamWorker.init returns error.BlockTooLong.
    block_ms: u32 = types.DEFAULT_WORKER_BLOCK_MS,
    /// Heartbeat interval in milliseconds (default: 30s)
    heartbeat_interval_ms: u64 = 30_000,
    /// Optional metadata for this worker
    metadata: ?[]const u8 = null,
    /// Optional machine ID
    machine_id: ?[]const u8 = null,
    /// How its connection retries refused-but-not-run requests.
    retry: retry_mod.RetryPolicy = .{},

    /// Get the list of streams to consume from.
    pub fn getStreams(self: *const StreamWorkerConfig) []const []const u8 {
        if (self.streams) |s| return s;
        if (self.stream.len > 0) return @as(*const [1][]const u8, &self.stream);
        return &.{};
    }
};

/// Context passed to stream record handlers.
pub const StreamContext = struct {
    record: StreamRecord,
    namespace: []const u8,
    stream_name: []const u8,
    group: []const u8,
    consumer: []const u8,
    allocator: Allocator,

    /// Get the raw record payload.
    pub fn payload(self: *const StreamContext) []const u8 {
        return self.record.payload;
    }

    /// Get the record's StreamID.
    pub fn streamID(self: *const StreamContext) StreamID {
        return self.record.id;
    }

    /// Get the record's headers.
    pub fn headers(self: *const StreamContext) []const types.Header {
        return self.record.headers;
    }

    /// Parse the payload as JSON into the given type.
    /// Caller must call deinit() on the returned value.
    pub fn json(self: *const StreamContext, comptime T: type) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, self.allocator, self.record.payload, .{});
    }
};

/// Stream record handler function type.
/// Return error to nack the record, or void for auto-ack.
pub const StreamRecordHandler = *const fn (*StreamContext) anyerror!void;

/// High-level stream worker for consuming records via consumer groups.
/// Includes auto-ack/nack, worker registry, heartbeat, and graceful shutdown.
pub const StreamWorker = struct {
    allocator: Allocator,
    config: StreamWorkerConfig,
    client: Client,
    handler: StreamRecordHandler,
    worker_id: []const u8,
    consumer_name: []const u8,
    /// Written from other threads (stop, drain); always accessed atomically.
    running: bool = false,
    backoff: types.EmptyPollBackoff = .{},
    draining: bool = false,
    /// Whether the server has been told of the drain; the poll loop's alone.
    drain_sent: bool = false,
    last_heartbeat_ns: i128 = 0,
    messages_processed: std.atomic.Value(u64) = .init(0),
    messages_failed: std.atomic.Value(u64) = .init(0),
    /// With concurrency above 1, one slot per record handled at once,
    /// allocated on the first batch. `pool_mutex` guards `busy` and
    /// `busy_count`; `pool_free` signals a slot coming free.
    slots: []Slot = &.{},
    pool_mutex: std.Thread.Mutex = .{},
    pool_free: std.Thread.Condition = .{},
    busy_count: u32 = 0,

    const Self = @This();

    /// One record handled on a thread of its own, its ack or nack sent on
    /// the slot's connection: the poll connection belongs to the poll loop.
    /// The connection outlives the record, for the next one.
    const Slot = struct {
        worker: *Self,
        client: ?Client = null,
        record: StreamRecord = undefined,
        stream_name: []const u8 = "",
        thread: ?std.Thread = null,
        busy: bool = false,

        fn run(slot: *Slot) void {
            const w = slot.worker;
            w.processRecord(w.slotClient(slot), false, slot.stream_name, slot.record);
            w.pool_mutex.lock();
            defer w.pool_mutex.unlock();
            slot.busy = false;
            w.busy_count -= 1;
            w.pool_free.broadcast();
        }
    };

    /// Initialize a new StreamWorker.
    pub fn init(allocator: Allocator, config_in: StreamWorkerConfig, handler: StreamRecordHandler) !Self {
        var config = config_in;
        config.block_ms = try types.workerBlockMs(config.block_ms);

        var client = Client.init(allocator, config.endpoint, .{
            .namespace = config.namespace,
            .retry = config.retry,
        });
        errdefer client.deinit();

        try client.connect();

        const worker_id = if (config.worker_id) |id|
            try allocator.dupe(u8, id)
        else
            try generateWorkerId(allocator);

        const consumer_name = if (config.consumer) |c|
            try allocator.dupe(u8, c)
        else
            try allocator.dupe(u8, worker_id);

        return Self{
            .allocator = allocator,
            .config = config,
            .client = client,
            .handler = handler,
            .worker_id = worker_id,
            .consumer_name = consumer_name,
        };
    }

    // Request APIs over this worker's connection. Built per use, not stored:
    // see ActionWorker.api.
    fn streamApi(self: *Self) Stream {
        return Stream.init(&self.client);
    }

    fn actionsApi(self: *Self) Actions {
        return Actions.init(&self.client);
    }

    /// Deinitialize the stream worker and free resources.
    pub fn deinit(self: *Self) void {
        // Best-effort leave group and deregister for all streams
        var stream = self.streamApi();
        var actions = self.actionsApi();
        const stream_list = self.config.getStreams();
        for (stream_list) |stream_name| {
            stream.groupLeave(
                stream_name,
                self.config.group,
                self.consumer_name,
                .{ .namespace = self.config.namespace },
            ) catch {};
        }

        actions.deregister(self.worker_id, .{
            .namespace = self.config.namespace,
        }) catch {};

        self.releaseSlots();
        self.allocator.free(self.consumer_name);
        self.allocator.free(self.worker_id);
        self.client.deinit();
    }

    /// Start consuming stream records.
    /// This function blocks until stop() is called or drain completes.
    pub fn start(self: *Self) !void {
        const stream_list = self.config.getStreams();

        std.log.info("[flo-stream-worker] Starting (id={s}, streams={d}, group={s}, consumer={s})", .{
            self.worker_id,
            stream_list.len,
            self.config.group,
            self.consumer_name,
        });

        // Set before the join, so stop() ends a join that is backing off. A
        // drain is cleared when the run ends, not here, so a drain() before
        // or during startup still ends it; a later start begins a fresh one.
        @atomicStore(bool, &self.running, true, .monotonic);
        errdefer @atomicStore(bool, &self.running, false, .monotonic);
        defer {
            @atomicStore(bool, &self.draining, false, .monotonic);
            self.drain_sent = false;
        }
        try self.joinGroups();
        if (!@atomicLoad(bool, &self.running, .monotonic)) return;

        self.registerWorker() catch |err| {
            std.log.warn("[flo-stream-worker] Failed to register in worker registry: {}", .{err});
        };

        self.last_heartbeat_ns = std.time.nanoTimestamp();

        var stream_idx: usize = 0;
        var failed = retry_mod.workerBackoff();

        // Main polling loop
        while (@atomicLoad(bool, &self.running, .monotonic)) {
            // A batch is finished before the loop comes back here, so a
            // drain is done at once. It's checked before the connection: it
            // never needs the server, so a worker that can't reach it still
            // stops. The server gets one try at hearing of it.
            if (@atomicLoad(bool, &self.draining, .monotonic)) {
                if (!self.drain_sent and self.client.isConnected()) {
                    var actions_api = self.actionsApi();
                    if (actions_api.drain(self.worker_id, .{ .namespace = self.config.namespace })) {
                        self.drain_sent = true;
                    } else |err| std.log.warn("[flo-stream-worker] Failed to notify server of drain: {}", .{err});
                }
                std.log.info("[flo-stream-worker] Drain complete, shutting down", .{});
                @atomicStore(bool, &self.running, false, .monotonic);
                break;
            }

            if (!self.client.isConnected()) {
                self.reconnect() catch |err| {
                    std.log.warn("[flo-stream-worker] Reconnect failed: {}, retrying...", .{err});
                    types.pauseUnlessHalted(&self.running, &self.draining, 1_000);
                    continue;
                };
            }

            // Send heartbeat if interval has elapsed
            self.maybeHeartbeat();

            if (self.pollAndProcess(stream_list[stream_idx])) {
                failed.reset();
            } else |err| {
                if (client_mod.isConnectionError(err)) {
                    std.log.warn("[flo-stream-worker] Connection lost: {}, reconnecting...", .{err});
                    self.client.disconnect();
                } else {
                    const ms = failed.next(self.client.prng.random());
                    std.log.err("[flo-stream-worker] GroupRead error: {}, retrying in {d}ms...", .{ err, ms });
                    types.pauseUnlessHalted(&self.running, &self.draining, ms);
                }
            }

            // Round-robin across streams
            stream_idx = (stream_idx + 1) % stream_list.len;
        }

        std.log.info("[flo-stream-worker] Worker stopped (processed={d}, failed={d})", .{
            self.messages_processed.load(.monotonic),
            self.messages_failed.load(.monotonic),
        });
    }

    /// Open a fresh connection and join the groups on it again. Gives up
    /// once the worker is stopped or draining: a drain finishes without the
    /// server.
    fn reconnect(self: *Self) !void {
        try self.client.reconnectWhile(&self.running, &self.draining);
        errdefer self.client.disconnect();
        try self.joinGroups();
    }

    /// Reconnect to resend a lost result. A stopping worker still tries,
    /// for about stopping_reconnect_ms, so a result produced as it stops
    /// isn't lost to a brief drop, yet stop isn't held up for long.
    /// `rejoin`: `conn` is the poll connection, so the groups are joined
    /// again on the fresh one; a slot's connection only carries results.
    fn reconnectForResult(self: *Self, conn: *Client, rejoin: bool) !void {
        if (@atomicLoad(bool, &self.running, .monotonic)) {
            if (conn.reconnectWhile(&self.running, null)) {
                errdefer conn.disconnect();
                if (rejoin) try self.joinGroups();
                return;
            } else |err| {
                if (@atomicLoad(bool, &self.running, .monotonic)) return err;
            }
        }
        try conn.reconnectFor(stopping_reconnect_ms);
        errdefer conn.disconnect();
        if (rejoin) try self.joinGroups();
    }

    /// Join the group on every stream. A join the server refused without
    /// running it (overloaded or unavailable, past the client's own retries)
    /// is tried again with the worker backoff until it succeeds or the
    /// worker stops or drains; any other error is returned.
    fn joinGroups(self: *Self) !void {
        var stream = self.streamApi();
        for (self.config.getStreams()) |stream_name| {
            var failed = retry_mod.workerBackoff();
            while (true) {
                stream.groupJoin(
                    stream_name,
                    self.config.group,
                    self.consumer_name,
                    .{ .namespace = self.config.namespace },
                ) catch |err| {
                    if (!self.client.refusedUnrun(err)) return err;
                    const ms = failed.next(self.client.prng.random());
                    std.log.warn("[flo-stream-worker] [{s}] Group join refused: {}, retrying in {d}ms...", .{ stream_name, err, ms });
                    types.pauseUnlessHalted(&self.running, &self.draining, ms);
                    if (!types.goingOn(&self.running, &self.draining)) return;
                    continue;
                };
                break;
            }
        }
    }

    /// Register in the worker registry, each stream's group as a process.
    fn registerWorker(self: *Self) !void {
        const stream_list = self.config.getStreams();
        var process_names = try self.allocator.alloc([]u8, stream_list.len);
        // Only the names allocated so far: allocPrint can fail partway.
        var named: usize = 0;
        defer {
            for (process_names[0..named]) |name| self.allocator.free(name);
            self.allocator.free(process_names);
        }

        var process_entries = try self.allocator.alloc(types.ProcessEntry, stream_list.len);
        defer self.allocator.free(process_entries);

        for (stream_list, 0..) |stream_name, i| {
            process_names[i] = try std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ stream_name, self.config.group },
            );
            named += 1;
            process_entries[i] = .{
                .name = process_names[i],
                .kind = .stream_consumer,
            };
        }

        var actions = self.actionsApi();
        try actions.register(
            self.worker_id,
            null,
            .{
                .namespace = self.config.namespace,
                .worker_type = .stream,
                .max_concurrency = self.config.concurrency,
                .processes = process_entries,
                .metadata = self.config.metadata,
                .machine_id = self.config.machine_id,
            },
        );
    }

    /// Stop the worker immediately.
    pub fn stop(self: *Self) void {
        std.log.info("[flo-stream-worker] Stopping...", .{});
        @atomicStore(bool, &self.running, false, .monotonic);
    }

    /// Initiate graceful drain. Safe from any thread: it only sets a flag,
    /// and the poll loop tells the server on its own connection, then stops
    /// once the batch in hand is handled. The loop sees the flag between
    /// polls, so that can take up to block_ms plus the time to finish the
    /// current batch, and a batch read meanwhile is still handled. It
    /// finishes whether or not the server can be reached. The server
    /// doesn't wake a held group read on a drain, so a drain sent from
    /// elsewhere is seen at the next heartbeat, once the read returns.
    pub fn drain(self: *Self) void {
        std.log.info("[flo-stream-worker] Draining...", .{});
        @atomicStore(bool, &self.draining, true, .monotonic);
    }

    /// Send heartbeat if the interval has elapsed.
    fn maybeHeartbeat(self: *Self) void {
        const now = std.time.nanoTimestamp();
        const elapsed_ns = now - self.last_heartbeat_ns;
        const interval_ns: i128 = @as(i128, self.config.heartbeat_interval_ms) * std.time.ns_per_ms;

        if (elapsed_ns < interval_ns) return;

        self.last_heartbeat_ns = now;

        var actions = self.actionsApi();
        const status = actions.heartbeat(
            self.worker_id,
            self.activeTasks(),
            .{ .namespace = self.config.namespace },
        ) catch |err| {
            if (err != FloError.NotFound) {
                std.log.err("[flo-stream-worker] Heartbeat failed: {}", .{err});
                return;
            }
            // Removed for its silence: register again, so the registry knows
            // it. The registration marks it active, so a drain is told again.
            std.log.warn("[flo-stream-worker] The server no longer knows this worker; registering again", .{});
            self.registerWorker() catch |rerr| {
                std.log.warn("[flo-stream-worker] Failed to register again: {}", .{rerr});
                if (client_mod.isConnectionError(rerr)) self.client.disconnect();
                return;
            };
            if (@atomicLoad(bool, &self.draining, .monotonic)) self.drain_sent = false;
            return;
        };

        // The server knows already, so nothing is sent back.
        if (status == .draining and !@atomicLoad(bool, &self.draining, .monotonic)) {
            std.log.info("[flo-stream-worker] Server requested drain", .{});
            self.drain_sent = true;
            @atomicStore(bool, &self.draining, true, .monotonic);
        }
    }

    /// Poll for records and process them.
    fn pollAndProcess(self: *Self, stream_name: []const u8) !void {
        var stream = self.streamApi();
        const polled = try std.time.Instant.now();
        var result = try stream.groupRead(
            stream_name,
            self.config.group,
            self.consumer_name,
            .{
                .namespace = self.config.namespace,
                .count = self.config.batch_size,
                .block_ms = self.config.block_ms,
            },
        );
        defer result.deinit();

        const elapsed = (try std.time.Instant.now()).since(polled);
        const pause_ms = self.backoff.afterPoll(result.records.len == 0, elapsed, self.config.block_ms);
        if (result.records.len == 0) {
            types.pauseWhileRunning(&self.running, pause_ms);
            return;
        }

        // A result resent on a new connection doesn't end the batch: the
        // pending list is keyed by consumer name, not connection, so the
        // rest is still this consumer's to ack, and group reads never serve
        // pending records again.
        if (self.config.concurrency <= 1) {
            for (result.records) |record| {
                self.pool_mutex.lock();
                self.busy_count += 1;
                self.pool_mutex.unlock();
                defer {
                    self.pool_mutex.lock();
                    self.busy_count -= 1;
                    self.pool_mutex.unlock();
                }
                self.processRecord(&self.client, true, stream_name, record);
            }
            return;
        }
        try self.ensureSlots();
        for (result.records) |record| {
            const slot = self.waitFreeSlot();
            if (slot.thread) |t| t.join();
            slot.thread = null;
            slot.record = record;
            slot.stream_name = stream_name;
            self.pool_mutex.lock();
            slot.busy = true;
            self.busy_count += 1;
            self.pool_mutex.unlock();
            slot.thread = std.Thread.spawn(.{}, Slot.run, .{slot}) catch |err| {
                std.log.warn("[flo-stream-worker] Can't start a thread for record {}: {}; handling it here", .{ record.id, err });
                slot.run();
                continue;
            };
        }
        // The records belong to `result`, freed on return.
        self.waitIdle();
    }

    /// Records being handled now.
    fn activeTasks(self: *Self) u32 {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();
        return self.busy_count;
    }

    fn ensureSlots(self: *Self) !void {
        if (self.slots.len > 0) return;
        // A batch never holds more than batch_size records.
        const slots = try self.allocator.alloc(Slot, @max(1, @min(self.config.concurrency, self.config.batch_size)));
        for (slots) |*slot| slot.* = .{ .worker = self };
        self.slots = slots;
    }

    /// A free slot, waiting for one; heartbeats go out while it waits.
    fn waitFreeSlot(self: *Self) *Slot {
        while (true) {
            {
                self.pool_mutex.lock();
                defer self.pool_mutex.unlock();
                for (self.slots) |*slot| if (!slot.busy) return slot;
                self.pool_free.timedWait(&self.pool_mutex, 100 * std.time.ns_per_ms) catch {};
            }
            self.maybeHeartbeat();
        }
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
            std.log.warn("[flo-stream-worker] Record connection: can't connect: {}", .{err});
        };
        return client;
    }

    /// Wait for every record being handled to finish and report.
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
        for (self.slots) |*slot| if (slot.client) |*c| c.deinit();
        if (self.slots.len > 0) self.allocator.free(self.slots);
        self.slots = &.{};
    }

    /// Process a single record with auto-ack/nack, sent on `conn`: the poll
    /// connection (`rejoin`: join the groups again on a fresh one) or a
    /// slot's.
    fn processRecord(self: *Self, conn: *Client, rejoin: bool, stream_name: []const u8, record: StreamRecord) void {
        var ctx = StreamContext{
            .record = record,
            .namespace = self.config.namespace,
            .stream_name = stream_name,
            .group = self.config.group,
            .consumer = self.consumer_name,
            .allocator = self.allocator,
        };

        // The handler's outcome alone decides ack or nack: an ack that can't
        // be delivered is never turned into a nack.
        if (self.handler(&ctx)) {
            _ = self.messages_processed.fetchAdd(1, .monotonic);
            self.report(conn, rejoin, stream_name, record.id, .ack);
        } else |err| {
            _ = self.messages_failed.fetchAdd(1, .monotonic);
            std.log.err("[flo-stream-worker] Record {} failed: {}", .{ record.id, err });
            self.report(conn, rejoin, stream_name, record.id, .nack);
        }
    }

    /// Deliver a record's ack or nack. A send lost to a dropped connection or
    /// a timeout is sent again, unchanged, on a fresh connection that has
    /// rejoined the groups, up to max_result_sends in all. A refusal is not
    /// sent again: the server answered. An undelivered result is logged; the
    /// record stays in this consumer's pending list.
    fn report(self: *Self, conn: *Client, rejoin: bool, stream_name: []const u8, id: StreamID, kind: enum { ack, nack }) void {
        var stream = Stream.init(conn);
        const ids = [_]StreamID{id};
        var sends: u32 = 0;
        while (true) {
            sends += 1;
            const result = switch (kind) {
                .ack => stream.groupAck(stream_name, self.config.group, &ids, .{ .namespace = self.config.namespace }),
                .nack => stream.groupNack(stream_name, self.config.group, &ids, .{ .namespace = self.config.namespace }),
            };
            const err = if (result) return else |e| e;
            if (!client_mod.isConnectionError(err)) {
                types.logDropped("[flo-stream-worker] {s} of record {} refused: {}; dropped", .{ @tagName(kind), id, err });
                return;
            }
            if (sends >= max_result_sends) {
                types.logDropped("[flo-stream-worker] {s} of record {} not delivered after {d} sends: {}; dropped", .{ @tagName(kind), id, sends, err });
                return;
            }
            conn.disconnect();
            self.reconnectForResult(conn, rejoin) catch |rerr| {
                if (!@atomicLoad(bool, &self.running, .monotonic)) {
                    types.logDropped("[flo-stream-worker] {s} of record {} not delivered: worker stopping and reconnect failed: {}; dropped", .{ @tagName(kind), id, rerr });
                } else {
                    types.logDropped("[flo-stream-worker] {s} of record {} not delivered: reconnect failed: {}; dropped", .{ @tagName(kind), id, rerr });
                }
                return;
            };
            std.log.warn("[flo-stream-worker] {s} of record {} lost: {}; resending", .{ @tagName(kind), id, err });
        }
    }
};

/// How long a stopping worker keeps trying to reconnect to resend a result.
const stopping_reconnect_ms = 2_000;

/// Sends of one ack or nack, the first included, before it is dropped.
const max_result_sends = 3;

/// Generate a random worker ID.
fn generateWorkerId(allocator: Allocator) ![]u8 {
    var id_buf: [8]u8 = undefined;
    std.crypto.random.bytes(&id_buf);

    var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = std.posix.gethostname(&hostname_buf) catch "unknown";

    const hex_chars = "0123456789abcdef";
    var hex_buf: [16]u8 = undefined;
    for (id_buf, 0..) |byte, i| {
        hex_buf[i * 2] = hex_chars[byte >> 4];
        hex_buf[i * 2 + 1] = hex_chars[byte & 0x0f];
    }

    return std.fmt.allocPrint(allocator, "sw-{s}-{s}", .{ hostname, &hex_buf });
}

// =============================================================================
// Tests
// =============================================================================

test "StreamWorkerConfig defaults" {
    const config = StreamWorkerConfig{
        .endpoint = "localhost:3000",
        .stream = "events",
    };
    try std.testing.expectEqual(@as(u32, 1), config.concurrency);
    try std.testing.expectEqual(@as(u32, 10), config.batch_size);
    try std.testing.expectEqual(@as(u32, 30_000), config.block_ms);
    try std.testing.expectEqual(@as(u64, 30_000), config.heartbeat_interval_ms);
    try std.testing.expectEqualStrings("default", config.group);

    // getStreams returns single-stream list
    const streams = config.getStreams();
    try std.testing.expectEqual(@as(usize, 1), streams.len);
    try std.testing.expectEqualStrings("events", streams[0]);
}

test "StreamWorkerConfig multi-stream" {
    const stream_list = [_][]const u8{ "events", "orders", "logs" };
    const config = StreamWorkerConfig{
        .endpoint = "localhost:3000",
        .streams = &stream_list,
    };
    const streams = config.getStreams();
    try std.testing.expectEqual(@as(usize, 3), streams.len);
    try std.testing.expectEqualStrings("events", streams[0]);
    try std.testing.expectEqualStrings("orders", streams[1]);
    try std.testing.expectEqualStrings("logs", streams[2]);
}

test "generateStreamWorkerId" {
    const allocator = std.testing.allocator;
    const id = try generateWorkerId(allocator);
    defer allocator.free(id);

    try std.testing.expect(id.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, id, "sw-"));
}

test "StreamWorker.init refuses block_ms over MAX_BLOCK_MS before connecting" {
    const handler = struct {
        fn handle(_: *StreamContext) anyerror!void {}
    }.handle;
    try std.testing.expectError(error.BlockTooLong, StreamWorker.init(std.testing.allocator, .{
        .endpoint = "localhost:1",
        .stream = "events",
        .block_ms = types.MAX_BLOCK_MS + 1,
    }, handler));
}

test "StreamWorker.init turns block_ms 0 into 30000" {
    // A worker that polls with block_ms 0 would spin against the server.
    const handler = struct {
        fn handle(_: *StreamContext) anyerror!void {}
    }.handle;
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();
    var endpoint_buf: [32]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buf, "127.0.0.1:{d}", .{server.listen_address.getPort()});

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = endpoint, .stream = "events", .block_ms = 0 }, handler);
    // Not deinit: it sends requests the listener never answers.
    defer {
        std.testing.allocator.free(w.consumer_name);
        std.testing.allocator.free(w.worker_id);
        w.client.deinit();
    }
    try std.testing.expectEqual(@as(u32, 30000), w.config.block_ms);
}

fn runWorker(w: *StreamWorker) void {
    w.start() catch |err| std.debug.panic("stream worker start: {}", .{err});
}

test "StreamWorker reconnects after a group read times out and acks the next record" {
    const handler = struct {
        fn handle(_: *StreamContext) anyerror!void {}
    }.handle;
    // [count:u32] then one record: [seq:u64][ts:u64][tier:u8][partition:u32]
    // [key_present:u8][payload_len:u32]["hi"][header_count:u32]
    const records = "\x01\x00\x00\x00" ++ "\x07" ++ "\x00" ** 7 ++ "\x00" ** 8 ++ "\x00" ++
        "\x00" ** 4 ++ "\x00" ++ "\x02\x00\x00\x00hi" ++ "\x00" ** 4;
    var srv = try @import("stall_server.zig").StallServer.listen(.stream_group_join, .stream_group_read, .stream_group_ack, records);
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 100 }, handler);
    defer w.deinit();
    w.client.timeout_ms = 200;

    const thread = try std.Thread.spawn(.{}, runWorker, .{&w});
    const done = srv.waitDone(1, 10_000);
    w.stop();
    thread.join();

    try std.testing.expect(done);
    try std.testing.expectEqual(@as(u32, 2), srv.connections.load(.monotonic));
}

test "StreamWorker sends requests on its own connection after init returns" {
    const handler = struct {
        fn handle(_: *StreamContext) anyerror!void {}
    }.handle;
    var srv = try @import("test_server.zig").OkServer.listen();
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events" }, handler);
    defer w.deinit();
    @import("test_server.zig").clobberStack();

    // The first heartbeat is due at once.
    w.maybeHeartbeat();
    try std.testing.expectEqual(@as(u32, 1), srv.requests.load(.monotonic));
}

test "StreamWorker retries a group join the server refused without running" {
    const handler = struct {
        fn handle(_: *StreamContext) anyerror!void {}
    }.handle;
    const refused: @import("test_server.zig").Reply = .{ .status = 10, .body = "\x0c\x00\x00busy" };
    var srv = try @import("test_server.zig").OkServer.listen();
    srv.replies = &.{ refused, refused, refused };
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .retry = .{ .max_attempts = 1 } }, handler);
    defer w.deinit();
    w.running = true;

    try w.joinGroups();
    try std.testing.expectEqual(@as(u32, 4), srv.requests.load(.acquire));
    try std.testing.expectEqual(@as(u16, @intFromEnum(types.OpCode.stream_group_join)), srv.last_op);
}

test "StreamWorker gives its connection the retry policy it is configured with" {
    const handler = struct {
        fn handle(_: *StreamContext) anyerror!void {}
    }.handle;
    var srv = try @import("test_server.zig").OkServer.listen();
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .retry = .{ .max_attempts = 7, .initial_backoff_ms = 30, .max_backoff_ms = 9 } }, handler);
    defer w.deinit();
    try std.testing.expectEqual(retry_mod.RetryPolicy{ .max_attempts = 7, .initial_backoff_ms = 30, .max_backoff_ms = 30 }, w.client.retry);
}

test "StreamWorker gives up a group join on any other refusal" {
    const handler = struct {
        fn handle(_: *StreamContext) anyerror!void {}
    }.handle;
    var srv = try @import("test_server.zig").OkServer.listen();
    srv.replies = &.{.{ .status = 10, .body = "\x0c\x00\x02busy" }};
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events" }, handler);
    defer w.deinit();
    w.running = true;

    try std.testing.expectError(FloError.Overloaded, w.joinGroups());
    try std.testing.expectEqual(@as(u32, 1), srv.requests.load(.acquire));
}

test "StreamWorker paces group reads that come back empty at once" {
    const handler = struct {
        fn handle(_: *StreamContext) anyerror!void {}
    }.handle;
    var srv = try @import("test_server.zig").OkServer.listen();
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 30_000 }, handler);
    defer w.deinit();
    w.running = true;

    // Re-read at once, then paused 50, 100 and 200 ms.
    var timer = try std.time.Timer.start();
    for (0..4) |_| try w.pollAndProcess("events");
    try std.testing.expectEqual(@as(u32, 4), w.backoff.early_empties);
    try std.testing.expect(timer.read() >= 340 * std.time.ns_per_ms);
}

test "StreamWorker resends an ack lost with its connection, never nacks it, and acks the rest of the batch on the new one" {
    const counting = struct {
        var handled: u32 = 0;
        fn handle(_: *StreamContext) anyerror!void {
            handled += 1;
        }
    };
    // [count:u32] then per record: [seq:u64][ts:u64][tier:u8][partition:u32]
    // [key_present:u8][payload_len:u32]["hi"][header_count:u32]
    const record = "\x00" ** 8 ++ "\x00" ++ "\x00" ** 4 ++ "\x00" ++ "\x02\x00\x00\x00hi" ++ "\x00" ** 4;
    const records = "\x02\x00\x00\x00" ++ "\x07" ++ "\x00" ** 7 ++ record ++ "\x08" ++ "\x00" ** 7 ++ record;
    const ScriptServer = @import("test_server.zig").ScriptServer;
    var srv = try ScriptServer.listen();
    srv.rules = &.{
        .{ .op = .stream_group_read, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = records } } },
        .{ .op = .stream_group_ack, .nth = 0, .action = .drop },
    };
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 100 }, counting.handle);
    defer w.deinit();
    w.running = true;
    try w.pollAndProcess("events");

    try std.testing.expectEqual(@as(u32, 2), counting.handled);
    try std.testing.expectEqual(@as(u32, 3), srv.countOf(.stream_group_ack));
    try std.testing.expectEqual(@as(u32, 0), srv.countOf(.stream_group_nack));
    try std.testing.expectEqual(@as(u32, 2), srv.connections.load(.monotonic));
    // The group is joined again on the new connection before the resend.
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.stream_group_join));
    const sameApartFromId = @import("test_server.zig").sameApartFromId;
    try std.testing.expect(sameApartFromId(srv.requestOf(.stream_group_ack, 0), srv.requestOf(.stream_group_ack, 1)));
    // The third ack is the second record's.
    try std.testing.expect(!sameApartFromId(srv.requestOf(.stream_group_ack, 1), srv.requestOf(.stream_group_ack, 2)));
}

test "StreamWorker does not resend an ack the server refused, and runs the rest of the batch" {
    const counting = struct {
        var handled: u32 = 0;
        fn handle(_: *StreamContext) anyerror!void {
            handled += 1;
        }
    };
    const record = "\x00" ** 8 ++ "\x00" ++ "\x00" ** 4 ++ "\x00" ++ "\x02\x00\x00\x00hi" ++ "\x00" ** 4;
    const records = "\x02\x00\x00\x00" ++ "\x07" ++ "\x00" ** 7 ++ record ++ "\x08" ++ "\x00" ** 7 ++ record;
    const ScriptServer = @import("test_server.zig").ScriptServer;
    var srv = try ScriptServer.listen();
    srv.rules = &.{
        .{ .op = .stream_group_read, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = records } } },
        .{ .op = .stream_group_ack, .nth = 0, .action = .{ .reply = .{ .status = @intFromEnum(types.StatusCode.conflict), .body = "\x09\x00\x01gone" } } },
    };
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 100 }, counting.handle);
    defer w.deinit();
    w.running = true;
    try w.pollAndProcess("events");

    try std.testing.expectEqual(@as(u32, 2), counting.handled);
    try std.testing.expectEqual(@as(u32, 2), srv.countOf(.stream_group_ack));
    try std.testing.expectEqual(@as(u32, 0), srv.countOf(.stream_group_nack));
    try std.testing.expectEqual(@as(u32, 1), srv.connections.load(.monotonic));
}

test "a stream context hands its record's headers back as pairs" {
    const headers = [_]types.Header{.{ .key = "source", .value = "web" }};
    var ctx: StreamContext = undefined;
    ctx.record = .{ .payload = "", .headers = &headers };
    try std.testing.expectEqualStrings("web", ctx.headers()[0].value);
}

const concurrency_test = struct {
    // [ts:i64][tier:u8][partition:u32][key_present:u8][payload_len:u32][payload][header_count:u32]
    const record = "\x00" ** 8 ++ "\x00" ++ "\x00" ** 4 ++ "\x00" ++ "\x02\x00\x00\x00hi" ++ "\x00" ** 4;
    // Two records, sequences 7 and 8.
    const records = "\x02\x00\x00\x00" ++ "\x07" ++ "\x00" ** 7 ++ record ++ "\x08" ++ "\x00" ** 7 ++ record;

    var in_flight = std.atomic.Value(u32).init(0);
    var most = std.atomic.Value(u32).init(0);

    /// Waits up to 2 s for another handler to be running too.
    fn meets(_: *StreamContext) anyerror!void {
        const now = in_flight.fetchAdd(1, .acq_rel) + 1;
        _ = most.fetchMax(now, .acq_rel);
        var waited: u32 = 0;
        while (in_flight.load(.acquire) < 2 and waited < 2000) : (waited += 10) std.Thread.sleep(10 * std.time.ns_per_ms);
        _ = most.fetchMax(in_flight.load(.acquire), .acq_rel);
        std.Thread.sleep(50 * std.time.ns_per_ms);
        _ = in_flight.fetchSub(1, .acq_rel);
    }

    fn waitFor(srv: anytype, op: types.OpCode, n: u32, ms: u32) bool {
        var waited: u32 = 0;
        while (srv.countOf(op) < n) : (waited += 10) {
            if (waited >= ms) return false;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        return true;
    }
};

test "StreamWorker handles up to `concurrency` records of a batch at once, each acked on its own connection" {
    const ScriptServer = @import("test_server.zig").ScriptServer;
    var srv = try ScriptServer.listen();
    srv.concurrent = true;
    srv.rules = &.{.{ .op = .stream_group_read, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = concurrency_test.records } } }};
    try srv.start();
    defer srv.deinit();
    concurrency_test.in_flight.store(0, .release);
    concurrency_test.most.store(0, .release);

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 100, .concurrency = 2 }, concurrency_test.meets);
    defer w.deinit();
    const thread = try std.Thread.spawn(.{}, runWorker, .{&w});
    const done = concurrency_test.waitFor(&srv, .stream_group_ack, 2, 5_000);
    w.stop();
    thread.join();

    try std.testing.expect(done);
    // Both at once: one at a time, each would have waited out its 2 s alone.
    try std.testing.expectEqual(@as(u32, 2), concurrency_test.most.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), srv.countOf(.stream_group_nack));
    // The poll connection, and one per record handled at once.
    try std.testing.expectEqual(@as(u32, 3), srv.connections.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2), w.messages_processed.load(.monotonic));
}

test "StreamWorker drain from another thread only sets the flag, and the poll loop tells the server, then start returns" {
    const handler = struct {
        fn handle(_: *StreamContext) anyerror!void {}
    }.handle;
    const ScriptServer = @import("test_server.zig").ScriptServer;
    var srv = try ScriptServer.listen();
    // The read is answered after 500 ms, so the poll loop is inside it when
    // drain is called.
    srv.rules = &.{.{ .op = .stream_group_read, .action = .{ .reply = .{ .status = 0, .delay_ms = 500 } } }};
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 1000 }, handler);
    defer w.deinit();
    const thread = try std.Thread.spawn(.{}, runWorker, .{&w});
    std.Thread.sleep(150 * std.time.ns_per_ms);
    w.drain();
    // drain() sent nothing itself: sending from this thread would share
    // the poll connection with the read in flight.
    try std.testing.expectEqual(@as(u32, 0), srv.countOf(.worker_drain));
    thread.join();
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.worker_drain));
    try std.testing.expectEqual(@as(u32, 1), srv.connections.load(.monotonic));
}

const batch_test = struct {
    // One record, sequence 7, payload "hi".
    const one = "\x01\x00\x00\x00" ++ "\x07" ++ "\x00" ** 7 ++ concurrency_test.record;
    var seen = std.atomic.Value(bool).init(false);

    /// Holds its record past the next poll's time, then checks the payload
    /// is still its own.
    fn holds(ctx: *StreamContext) anyerror!void {
        std.Thread.sleep(300 * std.time.ns_per_ms);
        if (std.mem.eql(u8, ctx.payload(), "hi")) seen.store(true, .release);
    }
};

test "StreamWorker reads no next batch until every record of this one is handled" {
    const ScriptServer = @import("test_server.zig").ScriptServer;
    var srv = try ScriptServer.listen();
    srv.concurrent = true;
    srv.rules = &.{.{ .op = .stream_group_read, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = batch_test.one } } }};
    try srv.start();
    defer srv.deinit();
    batch_test.seen.store(false, .release);

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 100, .concurrency = 2 }, batch_test.holds);
    defer w.deinit();
    const thread = try std.Thread.spawn(.{}, runWorker, .{&w});
    std.Thread.sleep(200 * std.time.ns_per_ms);
    // The handler is still running: its batch's records are alive, and no
    // second read has gone out.
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.stream_group_read));
    try std.testing.expect(concurrency_test.waitFor(&srv, .stream_group_ack, 1, 5_000));
    w.stop();
    thread.join();
    try std.testing.expect(batch_test.seen.load(.acquire));
}

const drain_gap_test = struct {
    var returned = std.atomic.Value(bool).init(false);

    fn run(w: *StreamWorker) void {
        w.start() catch {};
        returned.store(true, .release);
    }

    fn returnedWithin(w: *StreamWorker, ms: u32) bool {
        var waited: u32 = 0;
        while (!returned.load(.acquire) and waited < ms) : (waited += 10) std.Thread.sleep(10 * std.time.ns_per_ms);
        const ok = returned.load(.acquire);
        if (!ok) w.stop();
        return ok;
    }

    fn handle(_: *StreamContext) anyerror!void {}
};

test "StreamWorker finishes a drain while it can't reach the server" {
    const ScriptServer = @import("test_server.zig").ScriptServer;
    var srv = try ScriptServer.listen();
    srv.rules = &.{
        // The first read loses the connection, and every reconnect's join is
        // cut off too.
        .{ .op = .stream_group_read, .action = .drop },
        .{ .op = .stream_group_join, .nth = 1, .action = .drop },
        .{ .op = .stream_group_join, .nth = 2, .action = .drop },
        .{ .op = .stream_group_join, .nth = 3, .action = .drop },
        .{ .op = .stream_group_join, .nth = 4, .action = .drop },
    };
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 100, .retry = .{ .max_attempts = 1 } }, drain_gap_test.handle);
    defer w.deinit();
    drain_gap_test.returned.store(false, .release);
    const thread = try std.Thread.spawn(.{}, drain_gap_test.run, .{&w});
    defer thread.join();
    std.Thread.sleep(300 * std.time.ns_per_ms);
    w.drain();
    try std.testing.expect(drain_gap_test.returnedWithin(&w, 3_000));
}

test "StreamWorker finishes a drain while the server refuses connections" {
    const ScriptServer = @import("test_server.zig").ScriptServer;
    var srv = try ScriptServer.listen();
    // The first read hangs up and stops the listener: every reconnect is
    // refused, and the worker backs off between them.
    srv.rules = &.{.{ .op = .stream_group_read, .action = .close }};
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 100, .retry = .{ .max_attempts = 1 } }, drain_gap_test.handle);
    defer w.deinit();
    drain_gap_test.returned.store(false, .release);
    const thread = try std.Thread.spawn(.{}, drain_gap_test.run, .{&w});
    defer thread.join();
    // Inside the reconnect's first 1 s wait by now.
    std.Thread.sleep(300 * std.time.ns_per_ms);
    w.drain();
    try std.testing.expect(drain_gap_test.returnedWithin(&w, 500));
}

test "StreamWorker finishes a drain while its group join is backing off" {
    const ScriptServer = @import("test_server.zig").ScriptServer;
    var srv = try ScriptServer.listen();
    // [reason:u16][ran:u8][message]: refused, not run, so it is retried.
    srv.rules = &.{.{ .op = .stream_group_join, .action = .{ .reply = .{ .status = @intFromEnum(types.StatusCode.overloaded), .body = "\x0c\x00\x00busy" } } }};
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 100, .retry = .{ .max_attempts = 1 } }, drain_gap_test.handle);
    defer w.deinit();
    drain_gap_test.returned.store(false, .release);
    const thread = try std.Thread.spawn(.{}, drain_gap_test.run, .{&w});
    defer thread.join();
    var waited: u32 = 0;
    while (srv.countOf(.stream_group_join) < 2 and waited < 5000) : (waited += 10) std.Thread.sleep(10 * std.time.ns_per_ms);
    w.drain();
    try std.testing.expect(drain_gap_test.returnedWithin(&w, 500));
    try std.testing.expectEqual(@as(u32, 0), srv.countOf(.stream_group_read));
}

test "StreamWorker drained before start returns without reading" {
    const ScriptServer = @import("test_server.zig").ScriptServer;
    var srv = try ScriptServer.listen();
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 100 }, drain_gap_test.handle);
    defer w.deinit();
    w.drain();
    drain_gap_test.returned.store(false, .release);
    const thread = try std.Thread.spawn(.{}, drain_gap_test.run, .{&w});
    defer thread.join();
    try std.testing.expect(drain_gap_test.returnedWithin(&w, 2_000));
    try std.testing.expectEqual(@as(u32, 0), srv.countOf(.stream_group_read));
}

test "StreamWorker started again after a drain reads again" {
    const ScriptServer = @import("test_server.zig").ScriptServer;
    var srv = try ScriptServer.listen();
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 100 }, drain_gap_test.handle);
    defer w.deinit();
    const first = try std.Thread.spawn(.{}, runWorker, .{&w});
    std.Thread.sleep(100 * std.time.ns_per_ms);
    w.drain();
    first.join();

    drain_gap_test.returned.store(false, .release);
    const reads = srv.countOf(.stream_group_read);
    const second = try std.Thread.spawn(.{}, drain_gap_test.run, .{&w});
    std.Thread.sleep(300 * std.time.ns_per_ms);
    try std.testing.expect(!drain_gap_test.returned.load(.acquire));
    try std.testing.expect(srv.countOf(.stream_group_read) > reads);
    w.stop();
    second.join();
}

test "StreamWorker registers again, with the same options, when its heartbeat finds it removed" {
    const test_server = @import("test_server.zig");
    var srv = try test_server.ScriptServer.listen();
    // [reason:u16][ran:u8][message]
    srv.rules = &.{.{ .op = .worker_heartbeat, .nth = 0, .action = .{ .reply = .{ .status = @intFromEnum(types.StatusCode.not_found), .body = "\x0c\x00\x00worker not found" } } }};
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .concurrency = 2, .heartbeat_interval_ms = 0, .metadata = "{}", .machine_id = "host-1" }, drain_gap_test.handle);
    defer w.deinit();
    try w.registerWorker();
    // Draining, and the server told; registering again marks it active.
    w.draining = true;
    w.drain_sent = true;
    w.maybeHeartbeat();

    try std.testing.expectEqual(@as(u32, 2), srv.countOf(.worker_register));
    const first = test_server.valueOf(srv.requestOf(.worker_register, 0));
    try std.testing.expect(std.mem.indexOf(u8, first, "events/default") != null);
    try std.testing.expectEqualSlices(u8, first, test_server.valueOf(srv.requestOf(.worker_register, 1)));
    try std.testing.expect(!w.drain_sent);
}
