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
const GroupLease = types.GroupLease;
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
    /// Consumer group name. The first read of a group that doesn't exist
    /// creates it at the server's defaults (a 30 s lease, 5 attempts); create
    /// it first with `Stream.groupCreate` for others.
    group: []const u8 = "default",
    /// Consumer name within the group (defaults to worker_id). Acks and
    /// nacks name it: a record is held by the consumer that read it.
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
    /// Records to lease per read, 1 to 100 (default: 10). The group's lease
    /// runs for the whole batch from its read: with concurrency 1 they are
    /// handled in turn, so keep a batch's handling within it, or touch.
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
    /// Touch each record every sixth of its lease (at least 100 ms apart,
    /// counted from when its batch arrived) while the handler runs, from a
    /// thread on a connection of its own; a record is still held at most
    /// 12 h from its read. The lease is read off the batch's expiry against
    /// this host's clock. Off by default: a handler that runs past the lease
    /// without calling ctx.touch has its record read again, by this
    /// consumer or another. That thread allocates, so with auto_touch on
    /// the allocator given to init must be thread-safe.
    auto_touch: bool = false,

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
    /// The read that leased the record: an ack, nack or touch names it.
    lease: GroupLease = .{ .term = 0, .index = 0 },
    allocator: Allocator,
    /// The connection the record's ack or nack goes on.
    client: ?*Client = null,

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

    /// The record's deliveries, this one included: above 1, a lease ran
    /// out or a nack sent it round again.
    pub fn deliveries(self: *const StreamContext) u32 {
        return self.record.deliveries;
    }

    /// Keep the record: with half its lease or less left it runs a full
    /// lease from now, up to 12 h from its read. Returns when the lease runs
    /// out, in Unix milliseconds; `FloError.StaleReport` if the record has
    /// moved on (its lease ran out and it was read again, say).
    pub fn touch(self: *StreamContext) FloError!i64 {
        const client = self.client orelse return FloError.NotConnected;
        var stream = Stream.init(client);
        var report = try stream.groupTouch(self.stream_name, self.group, self.lease, &.{self.record}, .{ .namespace = self.namespace, .consumer = self.consumer });
        defer report.deinit();
        if (report.applied == 0) return FloError.StaleReport;
        return report.expires_at_ms;
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
    /// auto_touch's connection for records handled inline (concurrency 1).
    touch_client: ?Client = null,
    /// The limit refusal last logged, so a run of them logs once.
    limit_notice: types.LimitNotice = .{},
    /// With concurrency above 1, one slot per record handled at once,
    /// allocated on the first batch. `pool_mutex` guards `busy` and
    /// `busy_count`; `pool_free` signals a slot coming free.
    slots: []Slot = &.{},
    pool_mutex: std.Thread.Mutex = .{},
    pool_free: std.Thread.Condition = .{},
    busy_count: u32 = 0,

    const Self = @This();

    /// A record as a group read leased it: the read's lease, and when the
    /// batch arrived.
    const Leased = struct {
        stream_name: []const u8,
        lease: GroupLease,
        lease_ms: u64,
        arrived: std.time.Instant,
        record: StreamRecord,
    };

    /// One record handled on a thread of its own, its ack or nack sent on
    /// the slot's connection: the poll connection belongs to the poll loop.
    /// The connection outlives the record, for the next one.
    const Slot = struct {
        worker: *Self,
        client: ?Client = null,
        touch_client: ?Client = null,
        item: Leased = undefined,
        thread: ?std.Thread = null,
        busy: bool = false,

        fn run(slot: *Slot) void {
            const w = slot.worker;
            w.processRecord(w.slotClient(slot), &slot.item, &slot.touch_client);
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
        if (config.batch_size < 1 or config.batch_size > types.MAX_GROUP_BATCH) return FloError.BadRequest;

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

    /// Deinitialize the stream worker and free resources. Records this
    /// consumer still holds are read again once their lease runs out.
    pub fn deinit(self: *Self) void {
        var actions = self.actionsApi();
        actions.deregister(self.worker_id, .{
            .namespace = self.config.namespace,
        }) catch {};

        self.releaseSlots();
        if (self.touch_client) |*c| c.deinit();
        self.allocator.free(self.consumer_name);
        self.allocator.free(self.worker_id);
        self.client.deinit();
    }

    /// Start consuming stream records.
    /// This function blocks until stop() is called or drain completes.
    /// A registration refused at a limit returns `error.Limit`, with the
    /// reason and message in `client.lastError()`: start fails with the
    /// limit error; a limit hit while running is logged and backed off.
    pub fn start(self: *Self) !void {
        const stream_list = self.config.getStreams();

        std.log.info("[flo-stream-worker] Starting (id={s}, streams={d}, group={s}, consumer={s})", .{
            self.worker_id,
            stream_list.len,
            self.config.group,
            self.consumer_name,
        });

        // A drain is cleared when the run ends, not here, so a drain() before
        // or during startup still ends it; a later start begins a fresh one.
        @atomicStore(bool, &self.running, true, .monotonic);
        errdefer @atomicStore(bool, &self.running, false, .monotonic);
        defer {
            @atomicStore(bool, &self.draining, false, .monotonic);
            self.drain_sent = false;
        }

        // A halted shard holds the start until it's repaired, or a stop or
        // drain ends the wait. A registration that committed but hasn't
        // applied ends the start, so it isn't resent, and so does one at a
        // limit, which waiting won't clear; any other failure only warns.
        var halted = retry_mod.haltedBackoff();
        while (types.goingOn(&self.running, &self.draining)) {
            self.registerWorker() catch |err| {
                if (self.client.waitIfHalted(err, &halted, &self.running, &self.draining, "[flo-stream-worker]", "worker registration")) continue;
                if (err == FloError.OutcomePending or err == FloError.Limit) return err;
                std.log.warn("[flo-stream-worker] Failed to register in worker registry: {}", .{err});
            };
            break;
        }
        halted.reset();

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
                self.client.reconnectWhile(&self.running, &self.draining) catch |err| {
                    std.log.warn("[flo-stream-worker] Reconnect failed: {}, retrying...", .{err});
                    types.pauseUnlessHalted(&self.running, &self.draining, 1_000);
                    continue;
                };
            }

            // Send heartbeat if interval has elapsed
            self.maybeHeartbeat();

            if (self.pollAndProcess(stream_list[stream_idx])) {
                failed.reset();
                halted.reset();
                self.limit_notice.clear();
            } else |err| {
                if (client_mod.isConnectionError(err)) {
                    std.log.warn("[flo-stream-worker] Connection lost: {}, reconnecting...", .{err});
                    self.client.disconnect();
                } else if (!self.client.waitIfHalted(err, &halted, &self.running, &self.draining, "[flo-stream-worker]", "group read")) {
                    const ms = failed.next(self.client.prng.random());
                    // Refused without running (records still being read
                    // from disk, no leader yet): the read leased nothing,
                    // so the same group and consumer read again.
                    if (err == FloError.Limit) {
                        self.limit_notice.note(&self.client, "[flo-stream-worker] group read");
                    } else if (self.client.refusedUnrun(err)) {
                        std.log.warn("[flo-stream-worker] GroupRead refused, not run: {s}; retrying in {d}ms", .{ self.client.lastError().?.message, ms });
                    } else std.log.err("[flo-stream-worker] GroupRead error: {}, retrying in {d}ms...", .{ err, ms });
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

    /// Reconnect to resend a lost result. A stopping worker still tries,
    /// for about stopping_reconnect_ms, so a result produced as it stops
    /// isn't lost to a brief drop, yet stop isn't held up for long.
    fn reconnectForResult(self: *Self, conn: *Client) !void {
        if (@atomicLoad(bool, &self.running, .monotonic)) {
            if (conn.reconnectWhile(&self.running, null)) return else |err| {
                if (@atomicLoad(bool, &self.running, .monotonic)) return err;
            }
        }
        try conn.reconnectFor(stopping_reconnect_ms);
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
            // Only worker.register is sent again: the server keeps workers in
            // memory, so it can't halt a shard or answer outcome_pending.
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

        const arrived = try std.time.Instant.now();
        const pause_ms = self.backoff.afterPoll(result.records.len == 0, arrived.since(polled), self.config.block_ms);
        if (result.records.len == 0) {
            types.pauseWhileRunning(&self.running, pause_ms);
            return;
        }
        const lease_ms = leaseMsOf(result.expires_at_ms, std.time.milliTimestamp());

        // A result resent on a new connection still names the read's lease:
        // a lease is the consumer's, not the connection's.
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
                var item: Leased = .{ .stream_name = stream_name, .lease = result.lease, .lease_ms = lease_ms, .arrived = arrived, .record = record };
                self.processRecord(&self.client, &item, &self.touch_client);
            }
            return;
        }
        try self.ensureSlots();
        for (result.records) |record| {
            const slot = self.waitFreeSlot();
            if (slot.thread) |t| t.join();
            slot.thread = null;
            slot.item = .{ .stream_name = stream_name, .lease = result.lease, .lease_ms = lease_ms, .arrived = arrived, .record = record };
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
        for (self.slots) |*slot| {
            if (slot.client) |*c| c.deinit();
            if (slot.touch_client) |*c| c.deinit();
        }
        if (self.slots.len > 0) self.allocator.free(self.slots);
        self.slots = &.{};
    }

    /// Process a single record with auto-ack/nack, sent on `conn`: the poll
    /// connection or a slot's. auto_touch touches it on `touch_conn`.
    fn processRecord(self: *Self, conn: *Client, item: *const Leased, touch_conn: *?Client) void {
        var ctx = StreamContext{
            .record = item.record,
            .namespace = self.config.namespace,
            .stream_name = item.stream_name,
            .group = self.config.group,
            .consumer = self.consumer_name,
            .lease = item.lease,
            .allocator = self.allocator,
            .client = conn,
        };

        var toucher: Toucher = undefined;
        const touching = self.startTouching(&toucher, item, touch_conn);
        // The handler's outcome alone decides ack or nack: an ack that can't
        // be delivered is never turned into a nack.
        const outcome = self.handler(&ctx);
        // A touch in flight finishes before the outcome is sent.
        if (touching) |thread| {
            toucher.stop.set();
            thread.join();
        }
        if (outcome) {
            _ = self.messages_processed.fetchAdd(1, .monotonic);
            self.report(conn, item, .ack);
        } else |err| {
            _ = self.messages_failed.fetchAdd(1, .monotonic);
            std.log.err("[flo-stream-worker] Record {} failed: {}", .{ item.record.id, err });
            self.report(conn, item, .nack);
        }
    }

    /// auto_touch never touches more often, whatever the lease.
    const min_touch_interval_ms: u64 = 100;

    /// How often to touch a record held for `lease_ms`: every sixth of it,
    /// at least min_touch_interval_ms apart. A touch renews the lease only
    /// once half of it or less is left, so the touch at half the lease
    /// renews it, and if that one fails two more come before it runs out.
    fn touchInterval(lease_ms: u64) u64 {
        return @max(lease_ms / 6, min_touch_interval_ms);
    }

    /// The lease a batch was read under, from its expiry and this host's
    /// clock when it arrived, held to the server's bounds: a clock ahead
    /// of the server's only makes the touches come sooner.
    fn leaseMsOf(expires_at_ms: i64, now_ms: i64) u64 {
        const left = std.math.clamp(expires_at_ms -| now_ms, types.MIN_GROUP_LEASE_MS, types.MAX_GROUP_LEASE_MS);
        return @intCast(left);
    }

    /// One record's touching thread and the event that stops it. Touches
    /// fall due every interval from when its batch arrived, not from when
    /// the last one returned, so a slow touch doesn't push the rest later.
    const Toucher = struct {
        worker: *Self,
        item: *const Leased,
        client: *?Client,
        interval_ns: u64,
        stop: std.Thread.ResetEvent = .{},

        fn run(t: *Toucher) void {
            var due: u64 = t.interval_ns;
            while (!t.stop.isSet()) {
                const since = t.sinceArrival(due);
                if (since < due) {
                    t.stop.timedWait(due - since) catch {};
                    continue;
                }
                if (!t.worker.touchOnce(t.client, t.item)) return;
                // The next due time after the touch: those missed while it
                // ran are skipped.
                due = (t.sinceArrival(due) / t.interval_ns + 1) *| t.interval_ns;
            }
        }

        fn sinceArrival(t: *const Toucher, fallback: u64) u64 {
            return if (std.time.Instant.now()) |now| now.since(t.item.arrived) else |_| fallback;
        }
    };

    /// Start touching `item` on a thread, when auto_touch is on; null
    /// otherwise, or when the thread can't start.
    fn startTouching(self: *Self, toucher: *Toucher, item: *const Leased, touch_conn: *?Client) ?std.Thread {
        if (!self.config.auto_touch) return null;
        toucher.* = .{ .worker = self, .item = item, .client = touch_conn, .interval_ns = touchInterval(item.lease_ms) *| std.time.ns_per_ms };
        return std.Thread.spawn(.{}, Toucher.run, .{toucher}) catch |err| {
            std.log.err("[flo-stream-worker] Can't start touching record {}: {}", .{ item.record.id, err });
            return null;
        };
    }

    /// Touch `item` once on the touch connection; false when touching
    /// should stop: the record moved on, or the server refused the touch. A
    /// lost touch is tried again next interval.
    fn touchOnce(self: *Self, touch_conn: *?Client, item: *const Leased) bool {
        if (touch_conn.* == null) {
            touch_conn.* = Client.init(self.allocator, self.config.endpoint, .{
                .namespace = self.config.namespace,
                .retry = self.config.retry,
            });
        }
        const client = &touch_conn.*.?;
        if (!client.isConnected()) client.connect() catch |err| {
            std.log.warn("[flo-stream-worker] Touch for record {}: can't connect: {}", .{ item.record.id, err });
            return true;
        };
        var stream = Stream.init(client);
        var touched = stream.groupTouch(item.stream_name, self.config.group, item.lease, &.{item.record}, .{ .namespace = self.config.namespace, .consumer = self.consumer_name }) catch |err| {
            if (client_mod.isConnectionError(err)) {
                std.log.warn("[flo-stream-worker] Touch for record {} failed: {}; trying again", .{ item.record.id, err });
                client.disconnect();
                return true;
            }
            std.log.warn("[flo-stream-worker] Touch for record {} was refused, stopping: {}", .{ item.record.id, err });
            return false;
        };
        defer touched.deinit();
        if (touched.refused.len > 0) {
            std.log.warn("[flo-stream-worker] Touch for record {} applied nothing ({s}), stopping", .{ item.record.id, std.enums.tagName(types.GroupRefusalWhy, touched.refused[0].why) orelse "unknown" });
            return false;
        }
        return true;
    }

    /// Deliver a record's ack or nack. A send lost to a dropped connection or
    /// a timeout is sent again, unchanged, on a fresh connection, up to
    /// max_result_sends in all; a resent ack that already applied is
    /// answered `gone`. A refusal is not sent again: the server answered.
    /// An undelivered result is logged; the record is read again once its
    /// lease runs out.
    fn report(self: *Self, conn: *Client, item: *const Leased, kind: enum { ack, nack }) void {
        var stream = Stream.init(conn);
        const id = item.record.id;
        var sends: u32 = 0;
        while (true) {
            sends += 1;
            const result = switch (kind) {
                .ack => stream.groupAck(item.stream_name, self.config.group, item.lease, &.{item.record}, .{ .namespace = self.config.namespace, .consumer = self.consumer_name }),
                .nack => stream.groupNack(item.stream_name, self.config.group, item.lease, &.{item.record}, .{ .namespace = self.config.namespace, .consumer = self.consumer_name }),
            };
            if (result) |answer| {
                var got = answer;
                defer got.deinit();
                // A resend finds its first already applied: gone is done.
                if (got.refused.len > 0 and !(sends > 1 and got.refused[0].why == .gone)) {
                    types.logWorkerError("[flo-stream-worker] {s} of record {} applied nothing: {s}; the record moved on", .{ @tagName(kind), id, std.enums.tagName(types.GroupRefusalWhy, got.refused[0].why) orelse "unknown" });
                }
                return;
            } else |err| {
                if (!client_mod.isConnectionError(err)) {
                    types.logWorkerError("[flo-stream-worker] {s} of record {} refused: {}; dropped", .{ @tagName(kind), id, err });
                    return;
                }
                if (sends >= max_result_sends) {
                    types.logWorkerError("[flo-stream-worker] {s} of record {} not delivered after {d} sends: {}; dropped", .{ @tagName(kind), id, sends, err });
                    return;
                }
                conn.disconnect();
                self.reconnectForResult(conn) catch |rerr| {
                    if (!@atomicLoad(bool, &self.running, .monotonic)) {
                        types.logWorkerError("[flo-stream-worker] {s} of record {} not delivered: worker stopping and reconnect failed: {}; dropped", .{ @tagName(kind), id, rerr });
                    } else {
                        types.logWorkerError("[flo-stream-worker] {s} of record {} not delivered: reconnect failed: {}; dropped", .{ @tagName(kind), id, rerr });
                    }
                    return;
                };
                std.log.warn("[flo-stream-worker] {s} of record {} lost: {}; resending", .{ @tagName(kind), id, err });
            }
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

/// Group read answers for the tests.
const group_test = struct {
    const le = std.mem.toBytes;
    /// The read's lease: term 3, index 9.
    const term: u64 = 3;
    const index: u64 = 9;

    /// A read leasing records with these sequences, each payload "hi" and
    /// first delivered, with an expiry far ahead.
    fn answer(comptime seqs: []const u64) []const u8 {
        comptime {
            var out: []const u8 = &(le(term) ++ le(index) ++ le(@as(i64, std.math.maxInt(i64))) ++ le(@as(u32, seqs.len)));
            for (seqs) |seq| out = out ++ le(seq) ++ "\x00" ** 8 ++ "\x00" ++ "\x00" ** 4 ++ "\x00" ++ "\x02\x00\x00\x00hi" ++ "\x00" ** 4 ++ le(@as(u32, 1));
            const final = out[0..out.len].*;
            return &final;
        }
    }

    /// Whether a report names the read's lease and the one record `seq`,
    /// first delivered: its value ends term, index, count, id, deliveries.
    fn reportNames(req: []const u8, seq: u64) bool {
        const v = @import("test_server.zig").valueOf(req);
        var want: [8 + 8 + 4 + 8 + 8 + 4]u8 = undefined;
        @memcpy(want[0..8], &le(term));
        @memcpy(want[8..16], &le(index));
        @memcpy(want[16..20], &le(@as(u32, 1)));
        @memcpy(want[20..28], &le(@as(u64, 0)));
        @memcpy(want[28..36], &le(seq));
        @memcpy(want[36..40], &le(@as(u32, 1)));
        return std.mem.endsWith(u8, v, &want);
    }
};

fn runWorker(w: *StreamWorker) void {
    w.start() catch |err| std.debug.panic("stream worker start: {}", .{err});
}

test "StreamWorker reconnects after a group read times out and acks the next record" {
    const handler = struct {
        fn handle(_: *StreamContext) anyerror!void {}
    }.handle;
    // Groups have no join: any connection reads.
    var srv = try @import("stall_server.zig").StallServer.listen(.stream_group_read, .stream_group_read, .stream_group_ack, comptime group_test.answer(&.{7}));
    srv.empty_poll = &@import("stream.zig").empty_group_read;
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

test "StreamWorker paces group reads that come back empty at once" {
    const handler = struct {
        fn handle(_: *StreamContext) anyerror!void {}
    }.handle;
    var srv = try @import("test_server.zig").OkServer.listen();
    try srv.start();
    defer srv.deinit();

    srv.body = &@import("stream.zig").empty_group_read;
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
    const ScriptServer = @import("test_server.zig").ScriptServer;
    var srv = try ScriptServer.listen();
    srv.rules = &.{
        .{ .op = .stream_group_read, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = comptime group_test.answer(&.{ 7, 8 }) } } },
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
    const ScriptServer = @import("test_server.zig").ScriptServer;
    var srv = try ScriptServer.listen();
    srv.rules = &.{
        .{ .op = .stream_group_read, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = comptime group_test.answer(&.{ 7, 8 }) } } },
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
    // Two records, sequences 7 and 8.
    const records = group_test.answer(&.{ 7, 8 });

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
    const one = group_test.answer(&.{7});
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
    // Every read loses the connection.
    srv.rules = &.{.{ .op = .stream_group_read, .action = .drop }};
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

test "StreamWorker finishes a drain while its group read is backing off" {
    const ScriptServer = @import("test_server.zig").ScriptServer;
    var srv = try ScriptServer.listen();
    // [reason:u16][ran:u8][message]: refused, not run, so it is retried.
    srv.rules = &.{.{ .op = .stream_group_read, .action = .{ .reply = .{ .status = @intFromEnum(types.StatusCode.overloaded), .body = "\x0c\x00\x00busy" } } }};
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 100, .retry = .{ .max_attempts = 1 } }, drain_gap_test.handle);
    defer w.deinit();
    drain_gap_test.returned.store(false, .release);
    const thread = try std.Thread.spawn(.{}, drain_gap_test.run, .{&w});
    defer thread.join();
    var waited: u32 = 0;
    while (srv.countOf(.stream_group_read) < 2 and waited < 5000) : (waited += 10) std.Thread.sleep(10 * std.time.ns_per_ms);
    w.drain();
    try std.testing.expect(drain_gap_test.returnedWithin(&w, 500));
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

test "StreamWorker waits out a halted shard at its registration and reads, then carries on" {
    const handler = struct {
        fn handle(_: *StreamContext) anyerror!void {}
    }.handle;
    const ScriptServer = @import("test_server.zig").ScriptServer;
    // unavailable, reason shard_halted, ran no.
    const halted: @import("test_server.zig").Reply = .{ .status = 12, .body = "\x1d\x00\x00shard 0 halted at index 8; an operator must repair it" };
    var srv = try ScriptServer.listen();
    srv.rules = &.{
        .{ .op = .worker_register, .nth = 0, .action = .{ .reply = halted } },
        .{ .op = .worker_register, .nth = 1, .action = .{ .reply = halted } },
        .{ .op = .stream_group_read, .nth = 0, .action = .{ .reply = halted } },
        .{ .op = .stream_group_read, .nth = 1, .action = .{ .reply = halted } },
        .{ .op = .stream_group_read, .nth = 2, .action = .{ .reply = halted } },
    };
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 100 }, handler);
    defer w.deinit();
    const thread = try std.Thread.spawn(.{}, runWorker, .{&w});
    var waited: u32 = 0;
    while (srv.countOf(.stream_group_read) < 5 and waited < 8000) : (waited += 10) std.Thread.sleep(10 * std.time.ns_per_ms);
    w.stop();
    thread.join();

    try std.testing.expectEqual(@as(u32, 3), srv.countOf(.worker_register));
    try std.testing.expect(srv.countOf(.stream_group_read) >= 5);
}

test "StreamWorker reads again when a group read is refused unavailable without running, logging no error" {
    const counting = struct {
        var handled = std.atomic.Value(u32).init(0);
        fn handle(_: *StreamContext) anyerror!void {
            _ = handled.fetchAdd(1, .monotonic);
        }
    };
    const records = comptime group_test.answer(&.{7});
    const ScriptServer = @import("test_server.zig").ScriptServer;
    // unavailable, reason unclassified, ran no: the records are being read from disk.
    const cold: @import("test_server.zig").Reply = .{ .status = 12, .body = "\x0c\x00\x00unavailable: too many reads are waiting on this shard's disk; retry" };
    var srv = try ScriptServer.listen();
    srv.rules = &.{
        .{ .op = .stream_group_read, .nth = 0, .action = .{ .reply = cold } },
        .{ .op = .stream_group_read, .nth = 1, .action = .{ .reply = cold } },
        .{ .op = .stream_group_read, .nth = 2, .action = .{ .reply = .{ .status = 0, .body = records } } },
    };
    try srv.start();
    defer srv.deinit();

    counting.handled.store(0, .monotonic);
    // One try per read, so the worker sees each refusal itself.
    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 100, .retry = .{ .max_attempts = 1 } }, counting.handle);
    defer w.deinit();
    const thread = try std.Thread.spawn(.{}, runWorker, .{&w});
    var waited: u32 = 0;
    while (srv.countOf(.stream_group_ack) < 1 and waited < 5000) : (waited += 10) std.Thread.sleep(10 * std.time.ns_per_ms);
    w.stop();
    thread.join();

    try std.testing.expectEqual(@as(u32, 1), counting.handled.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.stream_group_ack));
    // The same group and consumer each time.
    const first = srv.requestOf(.stream_group_read, 0);
    const third = srv.requestOf(.stream_group_read, 2);
    try std.testing.expectEqualSlices(u8, first[32..], third[32..]);
}

const halted_start_test = struct {
    var returned = std.atomic.Value(bool).init(false);
    var result: anyerror!void = {};

    fn run(w: *StreamWorker) void {
        result = w.start();
        returned.store(true, .release);
    }

    fn begin(w: *StreamWorker) !std.Thread {
        returned.store(false, .release);
        result = {};
        return std.Thread.spawn(.{}, run, .{w});
    }

    /// Whether start returned within `ms`; stops the worker if not, so a
    /// failing test ends instead of hanging.
    fn returnedWithin(w: *StreamWorker, ms: u32) bool {
        var waited: u32 = 0;
        while (!returned.load(.acquire) and waited < ms) : (waited += 5) std.Thread.sleep(5 * std.time.ns_per_ms);
        const ok = returned.load(.acquire);
        if (!ok) w.stop();
        return ok;
    }

    fn handle(_: *StreamContext) anyerror!void {}
};

/// unavailable, reason shard_halted, ran no.
const halted_refusal: @import("test_server.zig").Reply = .{ .status = 12, .body = "\x1d\x00\x00shard 0 halted at index 8; an operator must repair it" };

test "StreamWorker whose registration is outcome_pending returns it after one try" {
    const ScriptServer = @import("test_server.zig").ScriptServer;
    var srv = try ScriptServer.listen();
    srv.rules = &.{.{ .op = .worker_register, .action = .{ .reply = .{ .status = 13, .body = "\x1d\x00\x02shard 0 halted at this entry; a repair skips it" } } }};
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 100 }, halted_start_test.handle);
    defer w.deinit();
    const thread = try halted_start_test.begin(&w);
    const prompt = halted_start_test.returnedWithin(&w, 1000);
    thread.join();
    try std.testing.expect(prompt);
    try std.testing.expectError(FloError.OutcomePending, halted_start_test.result);
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.worker_register));
    try std.testing.expectEqual(@as(u32, 0), srv.countOf(.stream_group_read));
    try std.testing.expectEqualStrings("shard 0 halted at this entry; a repair skips it", w.client.lastError().?.message);
}

test "StreamWorker stopped or drained while a halted shard holds its registration returns at once, reading nothing" {
    const ScriptServer = @import("test_server.zig").ScriptServer;
    for ([_]bool{ false, true }) |drain| {
        var srv = try ScriptServer.listen();
        srv.rules = &.{.{ .op = .worker_register, .action = .{ .reply = halted_refusal } }};
        try srv.start();
        defer srv.deinit();

        var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 100 }, halted_start_test.handle);
        defer w.deinit();
        // Seeded, so the wait the stop cuts short is a long one.
        w.client.prng = std.Random.DefaultPrng.init(7);
        const thread = try halted_start_test.begin(&w);
        var waited: u32 = 0;
        while (srv.countOf(.worker_register) < 5 and waited < 8000) : (waited += 5) std.Thread.sleep(5 * std.time.ns_per_ms);
        if (drain) w.drain() else w.stop();
        const prompt = halted_start_test.returnedWithin(&w, 100);
        thread.join();
        try std.testing.expect(prompt);
        try halted_start_test.result;
        try std.testing.expectEqual(@as(u32, 5), srv.countOf(.worker_register));
        try std.testing.expectEqual(@as(u32, 0), srv.countOf(.stream_group_read));
    }
}

test "StreamWorker never resends an ack a halted shard refused" {
    const records = comptime group_test.answer(&.{7});
    const ScriptServer = @import("test_server.zig").ScriptServer;
    const pending: @import("test_server.zig").Reply = .{ .status = 13, .body = "\x1d\x00\x02committed; applies when the shard resumes" };
    for ([_]@import("test_server.zig").Reply{ halted_refusal, pending }) |refusal| {
        var srv = try ScriptServer.listen();
        const rules = [_]ScriptServer.Rule{
            .{ .op = .stream_group_read, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = records } } },
            .{ .op = .stream_group_ack, .action = .{ .reply = refusal } },
        };
        srv.rules = &rules;
        try srv.start();
        defer srv.deinit();

        var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 100 }, halted_start_test.handle);
        defer w.deinit();
        w.running = true;
        try w.pollAndProcess("events");
        try std.testing.expectEqual(@as(u32, 1), srv.countOf(.stream_group_ack));
        try std.testing.expectEqual(@as(u32, 0), srv.countOf(.stream_group_nack));
        try std.testing.expectEqual(@as(u32, 1), srv.connections.load(.monotonic));
    }
}

test "StreamWorker acks each record naming the read's lease, the record and its deliveries, as its consumer" {
    const ScriptServer = @import("test_server.zig").ScriptServer;
    var srv = try ScriptServer.listen();
    srv.rules = &.{.{ .op = .stream_group_read, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = comptime group_test.answer(&.{ 7, 8 }) } } }};
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .consumer = "c1", .block_ms = 100 }, drain_gap_test.handle);
    defer w.deinit();
    w.running = true;
    try w.pollAndProcess("events");
    try std.testing.expectEqual(@as(u32, 2), srv.countOf(.stream_group_ack));
    for ([_]u64{ 7, 8 }, 0..) |seq, i| {
        const v = @import("test_server.zig").valueOf(srv.requestOf(.stream_group_ack, @intCast(i)));
        try std.testing.expect(std.mem.startsWith(u8, v, "\x07\x00default\x02\x00c1"));
        try std.testing.expect(group_test.reportNames(srv.requestOf(.stream_group_ack, @intCast(i)), seq));
    }
}

test "StreamWorker backs off a group read refused at a limit, logging it once, and the client never retries it" {
    const ScriptServer = @import("test_server.zig").ScriptServer;
    // limit, reason too_many_actions, ran no.
    const limit: @import("test_server.zig").Reply = .{ .status = 15, .body = "\x21\x00\x00limit: this node holds 10000 actions" };
    var srv = try ScriptServer.listen();
    srv.rules = &.{.{ .op = .stream_group_read, .action = .{ .reply = limit } }};
    try srv.start();
    defer srv.deinit();

    // The default retry policy, which retries what didn't run when it may
    // pass: a limit won't.
    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 100 }, drain_gap_test.handle);
    defer w.deinit();
    w.running = true;
    try std.testing.expectError(FloError.Limit, w.pollAndProcess("events"));
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.stream_group_read));
    try std.testing.expectEqual(types.Reason.too_many_actions, w.client.lastError().?.reason);

    const thread = try std.Thread.spawn(.{}, runWorker, .{&w});
    std.Thread.sleep(700 * std.time.ns_per_ms);
    w.stop();
    thread.join();
    // Backing off from 100 ms, doubling: a handful of reads, not a spin.
    const reads = srv.countOf(.stream_group_read);
    try std.testing.expect(reads >= 2 and reads <= 8);
    try std.testing.expectEqual(@as(?types.Reason, .too_many_actions), w.limit_notice.last);
}

test "a limit notice logs a reason once until cleared, and a new reason at once" {
    const Fake = struct {
        reason: types.Reason,
        pub fn lastError(f: *const @This()) ?Client.LastError {
            return .{ .code = 15, .reason = f.reason, .ran = .no, .message = "limit" };
        }
    };
    var n: types.LimitNotice = .{};
    var f: Fake = .{ .reason = .too_many_actions };
    n.note(&f, "test");
    try std.testing.expectEqual(@as(?types.Reason, .too_many_actions), n.last);
    f.reason = .memory_budget;
    n.note(&f, "test");
    try std.testing.expectEqual(@as(?types.Reason, .memory_budget), n.last);
    n.clear();
    try std.testing.expectEqual(@as(?types.Reason, null), n.last);
}

test "StreamWorker touch intervals: a sixth of the lease, at least 100 ms; the lease read off the expiry within the server's bounds" {
    try std.testing.expectEqual(@as(u64, 5_000), StreamWorker.touchInterval(30_000));
    try std.testing.expectEqual(@as(u64, 100), StreamWorker.touchInterval(300));
    try std.testing.expectEqual(@as(u64, 30_000), StreamWorker.leaseMsOf(1_030_000, 1_000_000));
    // A clock ahead of the server's, or one far behind, is held to 5 s to 12 h.
    try std.testing.expectEqual(@as(u64, 5_000), StreamWorker.leaseMsOf(1_000_000, 2_000_000));
    try std.testing.expectEqual(@as(u64, 43_200_000), StreamWorker.leaseMsOf(std.math.maxInt(i64), 0));
    try std.testing.expectEqual(@as(u64, 5_000), StreamWorker.leaseMsOf(0, std.math.maxInt(i64)));
}

test "StreamWorker with auto_touch touches a record on its own connection while the handler runs, then acks it" {
    const slow = struct {
        fn handle(_: *StreamContext) anyerror!void {
            std.Thread.sleep(1_100 * std.time.ns_per_ms);
        }
    };
    // Leased for 5 s from now.
    var answer = comptime group_test.answer(&.{7})[0..].*;
    std.mem.writeInt(i64, answer[16..24], std.time.milliTimestamp() + 5_000, .little);
    const ScriptServer = @import("test_server.zig").ScriptServer;
    var srv = try ScriptServer.listen();
    srv.concurrent = true;
    srv.rules = &.{
        .{ .op = .stream_group_read, .nth = 0, .action = .{ .reply = .{ .status = 0, .body = &answer } } },
        // [expires_at_ms:i64][applied:u32][refused:u32]
        .{ .op = .stream_group_touch, .action = .{ .reply = .{ .status = 0, .body = "\x00" ** 8 ++ "\x01\x00\x00\x00" ++ "\x00" ** 4 } } },
    };
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 100, .auto_touch = true }, slow.handle);
    defer w.deinit();
    w.running = true;
    try w.pollAndProcess("events");
    // A 5 s lease: touched every 833 ms from the read's arrival.
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.stream_group_touch));
    try std.testing.expect(group_test.reportNames(srv.requestOf(.stream_group_touch, 0), 7));
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.stream_group_ack));
    try std.testing.expectEqual(@as(u32, 2), srv.connections.load(.monotonic));
}

test "StreamWorker start fails with the limit error after one registration, reading nothing" {
    const ScriptServer = @import("test_server.zig").ScriptServer;
    var srv = try ScriptServer.listen();
    // limit, reason too_many_actions, ran no.
    srv.rules = &.{.{ .op = .worker_register, .action = .{ .reply = .{ .status = 15, .body = "\x21\x00\x00limit: this node holds 10000 actions" } } }};
    try srv.start();
    defer srv.deinit();

    var w = try StreamWorker.init(std.testing.allocator, .{ .endpoint = srv.endpoint, .stream = "events", .block_ms = 100 }, halted_start_test.handle);
    defer w.deinit();
    const thread = try halted_start_test.begin(&w);
    const prompt = halted_start_test.returnedWithin(&w, 1000);
    thread.join();
    try std.testing.expect(prompt);
    try std.testing.expectError(FloError.Limit, halted_start_test.result);
    try std.testing.expectEqual(@as(u32, 1), srv.countOf(.worker_register));
    try std.testing.expectEqual(@as(u32, 0), srv.countOf(.stream_group_read));
    try std.testing.expectEqual(types.Reason.too_many_actions, w.client.lastError().?.reason);
    try std.testing.expectEqualStrings("limit: this node holds 10000 actions", w.client.lastError().?.message);
}
