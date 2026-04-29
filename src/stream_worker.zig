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
const Client = @import("client.zig").Client;
const Stream = @import("stream.zig").Stream;
const Actions = @import("actions.zig").Actions;

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
    /// Maximum concurrent message handlers (default: 10)
    concurrency: u32 = 10,
    /// Number of messages to read per poll (default: 10)
    batch_size: u32 = 10,
    /// Block timeout for reading in milliseconds (default: 30000)
    block_ms: u32 = 30_000,
    /// Heartbeat interval in milliseconds (default: 30s)
    heartbeat_interval_ms: u64 = 30_000,
    /// Optional metadata for this worker
    metadata: ?[]const u8 = null,
    /// Optional machine ID
    machine_id: ?[]const u8 = null,

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
    pub fn headers(self: *const StreamContext) ?std.StringHashMap([]const u8) {
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
    stream: Stream,
    actions: Actions,
    handler: StreamRecordHandler,
    worker_id: []const u8,
    consumer_name: []const u8,
    running: bool = false,
    draining: bool = false,
    active_tasks: u32 = 0,
    last_heartbeat_ns: i128 = 0,
    messages_processed: u64 = 0,
    messages_failed: u64 = 0,

    const Self = @This();

    /// Initialize a new StreamWorker.
    pub fn init(allocator: Allocator, config: StreamWorkerConfig, handler: StreamRecordHandler) !Self {
        var client = Client.init(allocator, config.endpoint, .{
            .namespace = config.namespace,
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
            .stream = Stream.init(&client),
            .actions = Actions.init(&client),
            .handler = handler,
            .worker_id = worker_id,
            .consumer_name = consumer_name,
        };
    }

    /// Deinitialize the stream worker and free resources.
    pub fn deinit(self: *Self) void {
        // Best-effort leave group and deregister for all streams
        const stream_list = self.config.getStreams();
        for (stream_list) |stream_name| {
            self.stream.groupLeave(
                stream_name,
                self.config.group,
                self.consumer_name,
                .{ .namespace = self.config.namespace },
            ) catch {};
        }

        self.actions.deregister(self.worker_id, .{
            .namespace = self.config.namespace,
        }) catch {};

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

        // Join consumer group for each stream
        for (stream_list) |stream_name| {
            try self.stream.groupJoin(
                stream_name,
                self.config.group,
                self.consumer_name,
                .{ .namespace = self.config.namespace },
            );
        }

        // Register in worker registry with all streams as processes
        var process_names = try self.allocator.alloc([]u8, stream_list.len);
        defer {
            for (process_names) |name| self.allocator.free(name);
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
            process_entries[i] = .{
                .name = process_names[i],
                .kind = .stream_consumer,
            };
        }

        self.actions.register(
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
        ) catch |err| {
            std.log.warn("[flo-stream-worker] Failed to register in worker registry: {}", .{err});
        };

        self.running = true;
        self.last_heartbeat_ns = std.time.nanoTimestamp();

        var stream_idx: usize = 0;

        // Main polling loop
        while (self.running) {
            // Send heartbeat if interval has elapsed
            self.maybeHeartbeat();

            // If draining and no active tasks, we're done
            if (self.draining and self.active_tasks == 0) {
                std.log.info("[flo-stream-worker] Drain complete, shutting down", .{});
                self.running = false;
                break;
            }

            // Don't accept new records while draining
            if (self.draining) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            }

            self.pollAndProcess(stream_list[stream_idx]) catch |err| {
                std.log.err("[flo-stream-worker] GroupRead error: {}, retrying...", .{err});
                std.Thread.sleep(1 * std.time.ns_per_s);
            };

            // Round-robin across streams
            stream_idx = (stream_idx + 1) % stream_list.len;
        }

        std.log.info("[flo-stream-worker] Worker stopped (processed={d}, failed={d})", .{
            self.messages_processed,
            self.messages_failed,
        });
    }

    /// Stop the worker immediately.
    pub fn stop(self: *Self) void {
        std.log.info("[flo-stream-worker] Stopping...", .{});
        self.running = false;
    }

    /// Initiate graceful drain.
    pub fn drain(self: *Self) void {
        std.log.info("[flo-stream-worker] Draining...", .{});
        self.draining = true;

        self.actions.drain(self.worker_id, .{
            .namespace = self.config.namespace,
        }) catch |err| {
            std.log.err("[flo-stream-worker] Failed to notify server of drain: {}", .{err});
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
            std.log.err("[flo-stream-worker] Heartbeat failed: {}", .{err});
            return;
        };

        if (status == .draining and !self.draining) {
            std.log.info("[flo-stream-worker] Server requested drain", .{});
            self.draining = true;
        }
    }

    /// Poll for records and process them.
    fn pollAndProcess(self: *Self, stream_name: []const u8) !void {
        var result = try self.stream.groupRead(
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

        if (result.records.len == 0) {
            return;
        }

        for (result.records) |record| {
            self.active_tasks += 1;
            defer self.active_tasks -= 1;
            self.processRecord(stream_name, record);
        }
    }

    /// Process a single record with auto-ack/nack.
    fn processRecord(self: *Self, stream_name: []const u8, record: StreamRecord) void {
        var ctx = StreamContext{
            .record = record,
            .namespace = self.config.namespace,
            .stream_name = stream_name,
            .group = self.config.group,
            .consumer = self.consumer_name,
            .allocator = self.allocator,
        };

        if (self.handler(&ctx)) {
            // Success - auto-ack
            self.messages_processed += 1;
            var ids = [_]StreamID{record.id};
            self.stream.groupAck(
                stream_name,
                self.config.group,
                &ids,
                .{ .namespace = self.config.namespace },
            ) catch |err| {
                std.log.err("[flo-stream-worker] Failed to ack record {}: {}", .{ record.id, err });
            };
        } else |err| {
            // Failure - nack
            self.messages_failed += 1;
            std.log.err("[flo-stream-worker] Record {} failed: {}", .{ record.id, err });
            var ids = [_]StreamID{record.id};
            self.stream.groupNack(
                stream_name,
                self.config.group,
                &ids,
                .{ .namespace = self.config.namespace },
            ) catch |nack_err| {
                std.log.err("[flo-stream-worker] Failed to nack record {}: {}", .{ record.id, nack_err });
            };
        }
    }
};

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
    try std.testing.expectEqual(@as(u32, 10), config.concurrency);
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
