//! Flo Queue Operations
//!
//! Message queue operations: enqueue, dequeue, complete, fail, touch, DLQ
//! management. A dequeue leases its messages until they are completed:
//! delivery is at least once.

const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");
const Client = @import("client.zig").Client;
const Reader = @import("kv.zig").Reader;

const Allocator = std.mem.Allocator;
const FloError = types.FloError;

/// Queue operations interface
pub const Queue = struct {
    client: *Client,

    pub fn init(client: *Client) Queue {
        return .{ .client = client };
    }

    /// Enqueue a message to a queue; returns its seq. A queue holds at most
    /// its cap of messages and bytes, and a shard's queues their cap of
    /// bytes: past one, the enqueue is refused overloaded without running,
    /// which the client retries like any such refusal before returning
    /// `FloError.Overloaded` (`client.lastError()` names the cap).
    pub fn enqueue(
        self: *Queue,
        queue_name: []const u8,
        payload: []const u8,
        options: types.EnqueueOptions,
    ) FloError!u64 {
        if (options.delay_ms > types.MAX_FAIL_DELAY_MS) return FloError.BadRequest;
        var opts_buf: [16]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);
        try builder.addU8(.priority, options.priority);
        if (options.delay_ms > 0) try builder.addU64(.delay_ms, options.delay_ms);

        var response = try self.client.sendRequest(.queue_enqueue, self.client.getNamespace(options.namespace), queue_name, payload, builder.getOptions());
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        if (response.data.len != 8) return FloError.IncompleteResponse;
        return std.mem.readInt(u64, response.data[0..8], .little);
    }

    /// Take up to `count` (1 to 100) of the queue's next ready messages,
    /// leased to `options.consumer` until a complete, a fail or the lease
    /// running out, when they are ready again: delivery is at least once,
    /// so complete each message within its lease (or touch it), or dequeue
    /// with `ack`. None ready within `block_ms` is an empty result.
    /// **Caller owns the returned `DequeueResult` and must call `result.deinit()`.**
    pub fn dequeue(
        self: *Queue,
        queue_name: []const u8,
        count: u32,
        options: types.DequeueOptions,
    ) FloError!types.DequeueResult {
        if (count < 1 or count > types.MAX_QUEUE_BATCH) return FloError.BadRequest;
        if (options.consumer.len > types.MAX_QUEUE_CONSUMER) return FloError.ValueTooLarge;
        if (options.lease_ms) |l| if (l < types.MIN_QUEUE_LEASE_MS or l > types.MAX_QUEUE_LEASE_MS) return FloError.BadRequest;
        try types.checkBlockMs(options.block_ms);
        var buf: [MAX_DEQUEUE_BODY]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        writeConsumer(&w, options.consumer);
        w.writeByte(1) catch unreachable;
        w.writeInt(u32, count, .little) catch unreachable;
        if (options.lease_ms) |l| {
            w.writeByte(1) catch unreachable;
            w.writeInt(u64, l, .little) catch unreachable;
        } else w.writeByte(0) catch unreachable;
        w.writeByte(1) catch unreachable;
        w.writeInt(u64, options.block_ms, .little) catch unreachable;
        w.writeAll(&.{ 1, @intFromBool(options.ack) }) catch unreachable;

        var response = try self.client.sendRequest(.queue_dequeue, self.client.getNamespace(options.namespace), queue_name, w.buffered(), "");
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        return decodeDequeueAnswer(self.client.allocator, response.data);
    }

    /// Complete dequeued messages, naming their dequeue's lease: they leave
    /// the queue. Each message is applied or refused on its own; a message
    /// refused `gone` was completed already, so it's done too.
    /// **Caller owns the returned `QueueReport` and must call `report.deinit()`.**
    pub fn complete(
        self: *Queue,
        queue_name: []const u8,
        lease: types.QueueLease,
        messages: []const types.Message,
        options: types.QueueReportOptions,
    ) FloError!types.QueueReport {
        const body = try self.reportBody(options.consumer, lease, messages, 0);
        defer self.client.allocator.free(body.buf);
        return self.report(.queue_complete, queue_name, options.namespace, body.w.buffered());
    }

    /// Fail dequeued messages: ready again after `options.delay_ms`, or dead
    /// once their attempts are spent (or at once with `options.dead`).
    /// **Caller owns the returned `QueueReport` and must call `report.deinit()`.**
    pub fn fail(
        self: *Queue,
        queue_name: []const u8,
        lease: types.QueueLease,
        messages: []const types.Message,
        options: types.QueueFailOptions,
    ) FloError!types.QueueReport {
        if (options.delay_ms > types.MAX_FAIL_DELAY_MS) return FloError.BadRequest;
        if (options.error_message.len > types.MAX_QUEUE_ERROR) return FloError.ValueTooLarge;
        var body = try self.reportBody(options.consumer, lease, messages, 9 + 2 + 3 + options.error_message.len);
        defer self.client.allocator.free(body.buf);
        const w = &body.w;
        w.writeByte(1) catch unreachable;
        w.writeInt(u64, options.delay_ms, .little) catch unreachable;
        w.writeAll(&.{ 1, @intFromBool(options.dead), 1 }) catch unreachable;
        w.writeInt(u16, @intCast(options.error_message.len), .little) catch unreachable;
        w.writeAll(options.error_message) catch unreachable;
        return self.report(.queue_fail, queue_name, options.namespace, w.buffered());
    }

    /// Keep dequeued messages: with half their lease or less left it runs a
    /// full lease from now, up to 12 h from their dequeue; with more left,
    /// nothing changes. The report's `expires_at_ms` is the lease's end.
    /// **Caller owns the returned `QueueReport` and must call `report.deinit()`.**
    pub fn touch(
        self: *Queue,
        queue_name: []const u8,
        lease: types.QueueLease,
        messages: []const types.Message,
        options: types.QueueReportOptions,
    ) FloError!types.QueueReport {
        const body = try self.reportBody(options.consumer, lease, messages, 0);
        defer self.client.allocator.free(body.buf);
        return self.report(.queue_touch, queue_name, options.namespace, body.w.buffered());
    }

    const Body = struct { buf: []u8, w: std.Io.Writer };

    /// A report's opening fields: consumer, term, index, then each
    /// message's seq and deliveries. `extra` bytes are left for the rest.
    fn reportBody(self: *Queue, consumer: []const u8, lease: types.QueueLease, messages: []const types.Message, extra: usize) FloError!Body {
        if (consumer.len > types.MAX_QUEUE_CONSUMER) return FloError.ValueTooLarge;
        if (messages.len < 1 or messages.len > types.MAX_QUEUE_BATCH) return FloError.BadRequest;
        const buf = try self.client.allocator.alloc(u8, 3 + consumer.len + 16 + 1 + messages.len * 12 + extra);
        var body: Body = .{ .buf = buf, .w = .fixed(buf) };
        writeConsumer(&body.w, consumer);
        body.w.writeInt(u64, lease.term, .little) catch unreachable;
        body.w.writeInt(u64, lease.index, .little) catch unreachable;
        body.w.writeByte(@intCast(messages.len)) catch unreachable;
        for (messages) |m| {
            body.w.writeInt(u64, m.seq, .little) catch unreachable;
            body.w.writeInt(u32, m.deliveries, .little) catch unreachable;
        }
        return body;
    }

    fn report(self: *Queue, op: types.OpCode, queue_name: []const u8, namespace: ?[]const u8, body: []const u8) FloError!types.QueueReport {
        var response = try self.client.sendRequest(op, self.client.getNamespace(namespace), queue_name, body, "");
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        return decodeReportAnswer(self.client.allocator, response.data, op == .queue_touch);
    }

    /// Remove every message of the queue: ready, leased and dead. Returns
    /// how many.
    pub fn purge(self: *Queue, queue_name: []const u8, options: types.PurgeOptions) FloError!u32 {
        var response = try self.client.sendRequest(.queue_purge, self.client.getNamespace(options.namespace), queue_name, "", "");
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        if (response.data.len != 4) return FloError.IncompleteResponse;
        return std.mem.readInt(u32, response.data[0..4], .little);
    }

    /// A page of the queue's dead letters, oldest first: at most
    /// `options.limit`, after the one whose seq is `options.after`. Pass the
    /// page's `last_seq` as `after` while `has_more` is set.
    /// **Caller owns the returned `DlqPage` and must call `page.deinit()`.**
    pub fn dlqList(
        self: *Queue,
        queue_name: []const u8,
        options: types.DlqListOptions,
    ) FloError!types.DlqPage {
        if (options.limit < 1 or options.limit > types.MAX_DLQ_PAGE) return FloError.BadRequest;
        const ns = self.client.getNamespace(options.namespace);

        // [limit:u32][after_seq:u64]?, in the value.
        var value_buf: [12]u8 = undefined;
        std.mem.writeInt(u32, value_buf[0..4], options.limit, .little);
        if (options.after) |a| std.mem.writeInt(u64, value_buf[4..12], a, .little);
        const value = value_buf[0..if (options.after != null) 12 else 4];

        var response = try self.client.sendRequest(
            .queue_dlq_list,
            ns,
            queue_name,
            value,
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }

        return decodeDlqPage(self.client.allocator, response.data);
    }

    /// The queue's next ready messages, 1 to 100 of them, in the order a
    /// dequeue takes them, without taking them. Each shows up to 4 KiB of
    /// its payload.
    /// **Caller owns the returned `PeekResult` and must call `result.deinit()`.**
    pub fn peek(
        self: *Queue,
        queue_name: []const u8,
        limit: u32,
        options: types.PeekOptions,
    ) FloError!types.PeekResult {
        if (limit < 1 or limit > types.MAX_PEEK) return FloError.BadRequest;
        // A table op: the body is limit, sent present.
        var body: [5]u8 = undefined;
        body[0] = 1;
        std.mem.writeInt(u32, body[1..5], limit, .little);
        var response = try self.client.sendRequest(.queue_peek, self.client.getNamespace(options.namespace), queue_name, &body, "");
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        return decodePeekAnswer(self.client.allocator, response.data);
    }
};

/// The most a dequeue body takes.
const MAX_DEQUEUE_BODY = 3 + types.MAX_QUEUE_CONSUMER + 5 + 9 + 9 + 2;

/// The consumer field: defaulted, so sent present, u16-length-prefixed.
fn writeConsumer(w: *std.Io.Writer, consumer: []const u8) void {
    w.writeByte(1) catch unreachable;
    w.writeInt(u16, @intCast(consumer.len), .little) catch unreachable;
    w.writeAll(consumer) catch unreachable;
}

/// The block_ms of a dequeue body, for the client's read timeout; 0 if the
/// body can't be read.
pub fn dequeueBodyBlockMs(body: []const u8) u64 {
    var r: Reader = .{ .data = body };
    if (!(r.boolean() catch return 0)) return 0;
    _ = r.lenBytes(u16) catch return 0;
    _ = r.opt(u32) catch return 0;
    _ = r.opt(u64) catch return 0;
    return (r.opt(u64) catch return 0) orelse 0;
}

/// The longest message payload.
const max_payload = 65_536;
/// A dequeued message's smallest encoding: an empty payload.
const min_message = 8 + 4 + 4 + 8 + 4;

/// queue.dequeue's answer: messages (u8 count), each {seq, priority,
/// deliveries, enqueued_at_ms, payload}, then term, index, expires_at_ms.
fn decodeDequeueAnswer(allocator: Allocator, data: []const u8) FloError!types.DequeueResult {
    var r: Reader = .{ .data = data };
    const n = try r.int(u8);
    if (n > types.MAX_QUEUE_BATCH or n > r.remaining() / min_message) return FloError.IncompleteResponse;
    const messages = try allocator.alloc(types.Message, n);
    var got: usize = 0;
    errdefer {
        for (messages[0..got]) |m| allocator.free(m.payload);
        allocator.free(messages);
    }
    while (got < n) : (got += 1) {
        const seq = try r.int(u64);
        const priority = try r.int(u32);
        const deliveries = try r.int(u32);
        const enqueued_at_ms = try r.int(i64);
        const payload = try r.lenBytes(u32);
        if (payload.len > max_payload) return FloError.IncompleteResponse;
        messages[got] = .{ .seq = seq, .priority = priority, .deliveries = deliveries, .enqueued_at_ms = enqueued_at_ms, .payload = try allocator.dupe(u8, payload) };
    }
    const term = try r.int(u64);
    const index = try r.int(u64);
    const expires_at_ms = try r.int(i64);
    try r.end();
    return .{ .messages = messages, .lease = .{ .term = term, .index = index }, .expires_at_ms = expires_at_ms, .allocator = allocator };
}

/// A refusal's smallest encoding: an empty reason.
const min_refusal = 8 + 1 + 1;

/// A complete's, fail's or touch's answer: [expires_at_ms] (touch only),
/// applied, then refused (u8 count), each {seq, why, reason}.
fn decodeReportAnswer(allocator: Allocator, data: []const u8, touch: bool) FloError!types.QueueReport {
    var r: Reader = .{ .data = data };
    const expires_at_ms: i64 = if (touch) try r.int(i64) else 0;
    const applied = try r.int(u32);
    const n = try r.int(u8);
    if (n > types.MAX_QUEUE_BATCH or n > r.remaining() / min_refusal) return FloError.IncompleteResponse;
    const refused = try allocator.alloc(types.QueueRefusal, n);
    var got: usize = 0;
    errdefer {
        for (refused[0..got]) |f| allocator.free(f.reason);
        allocator.free(refused);
    }
    while (got < n) : (got += 1) {
        const seq = try r.int(u64);
        const why: types.QueueRefusalWhy = @enumFromInt(try r.int(u8));
        const reason = try r.lenBytes(u8);
        refused[got] = .{ .seq = seq, .why = why, .reason = try allocator.dupe(u8, reason) };
    }
    try r.end();
    return .{ .applied = applied, .refused = refused, .expires_at_ms = expires_at_ms, .allocator = allocator };
}

/// The most of a payload a peek or DLQ page shows.
const max_shown_payload = 4096;

/// A dead letter's smallest encoding: an empty payload.
const min_dead_letter = 8 + 4 + 4 + 8 + 4 + 1 + 8;

/// queue_dlq_list's answer:
///   [count:u32]([seq:u64][size:u32][len:u32][payload][enqueued_at_ms:i64]
///   [attempts:u32][priority:u8][moved_at_ms:i64])*
///   [total:u64][has_more:u8][last_seq:u64]
fn decodeDlqPage(allocator: Allocator, data: []const u8) FloError!types.DlqPage {
    var r: Reader = .{ .data = data };
    const n = try r.int(u32);
    // A count the data can't hold is refused before it sizes an allocation.
    if (n > types.MAX_DLQ_PAGE or n > r.remaining() / min_dead_letter) return FloError.IncompleteResponse;
    const letters = try allocator.alloc(types.DeadLetter, n);
    var got: usize = 0;
    errdefer {
        for (letters[0..got]) |l| allocator.free(l.payload);
        allocator.free(letters);
    }
    while (got < n) : (got += 1) {
        const seq = try r.int(u64);
        const size = try r.int(u32);
        const payload = try r.lenBytes(u32);
        if (payload.len > max_shown_payload or payload.len > size) return FloError.IncompleteResponse;
        const enqueued_at_ms = try r.int(i64);
        const attempts = try r.int(u32);
        const priority = try r.int(u8);
        const moved_at_ms = try r.int(i64);
        letters[got] = .{
            .seq = seq,
            .size = size,
            .payload = try allocator.dupe(u8, payload),
            .enqueued_at_ms = enqueued_at_ms,
            .attempts = attempts,
            .priority = priority,
            .moved_at_ms = moved_at_ms,
        };
    }
    const total = try r.int(u64);
    const has_more = try r.boolean();
    const last_seq = try r.int(u64);
    try r.end();
    return .{ .letters = letters, .total = total, .has_more = has_more, .last_seq = last_seq, .allocator = allocator };
}

/// A peeked message's smallest encoding: an empty payload.
const min_peeked = 8 + 4 + 4 + 8 + 4 + 2;

/// queue.peek's answer: messages (u8 count), each {seq, priority, attempts,
/// enqueued_at_ms, size, payload}, then more.
fn decodePeekAnswer(allocator: Allocator, data: []const u8) FloError!types.PeekResult {
    var r: Reader = .{ .data = data };
    const n = try r.int(u8);
    if (n > types.MAX_PEEK or n > r.remaining() / min_peeked) return FloError.IncompleteResponse;
    const messages = try allocator.alloc(types.PeekedMessage, n);
    var got: usize = 0;
    errdefer {
        for (messages[0..got]) |m| allocator.free(m.payload);
        allocator.free(messages);
    }
    while (got < n) : (got += 1) {
        const seq = try r.int(u64);
        const priority = try r.int(u32);
        const attempts = try r.int(u32);
        const enqueued_at_ms = try r.int(i64);
        const size = try r.int(u32);
        const payload = try r.lenBytes(u16);
        if (payload.len > max_shown_payload) return FloError.IncompleteResponse;
        messages[got] = .{
            .seq = seq,
            .priority = priority,
            .attempts = attempts,
            .enqueued_at_ms = enqueued_at_ms,
            .size = size,
            .payload = try allocator.dupe(u8, payload),
        };
    }
    const more = try r.boolean();
    try r.end();
    return .{ .messages = messages, .more = more, .allocator = allocator };
}

const test_server = @import("test_server.zig");
const le = std.mem.toBytes;

/// Two dead letters, the first cut to 2 bytes of 5, then 9 in all and more.
const test_dlq_page = le(@as(u32, 2)) ++
    le(@as(u64, 7)) ++ le(@as(u32, 5)) ++ le(@as(u32, 2)) ++ "ab" ++ le(@as(i64, 100)) ++ le(@as(u32, 3)) ++ "\x04" ++ le(@as(i64, 200)) ++
    le(@as(u64, 8)) ++ le(@as(u32, 0)) ++ le(@as(u32, 0)) ++ le(@as(i64, 101)) ++ le(@as(u32, 1)) ++ "\x00" ++ le(@as(i64, 201)) ++
    le(@as(u64, 9)) ++ "\x01" ++ le(@as(u64, 8));

/// An empty last page.
const test_dlq_empty = le(@as(u32, 0)) ++ le(@as(u64, 9)) ++ "\x00" ++ le(@as(u64, 0));

test "dlqList sends its limit and after in the value and reads the page and its trailer" {
    const a = std.testing.allocator;
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{ .{ .status = 0, .body = test_dlq_page }, .{ .status = 0, .body = test_dlq_empty } };
    try srv.start();
    defer srv.deinit();
    var client = Client.init(a, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var queue = Queue.init(&client);

    var page = try queue.dlqList("jobs", .{ .limit = 2 });
    defer page.deinit();
    try std.testing.expectEqualSlices(u8, &le(@as(u32, 2)), srv.lastValue());
    try std.testing.expectEqual(@as(usize, 2), page.letters.len);
    const first = page.letters[0];
    try std.testing.expectEqual(@as(u64, 7), first.seq);
    try std.testing.expectEqual(@as(u32, 5), first.size);
    try std.testing.expectEqualStrings("ab", first.payload);
    try std.testing.expectEqual(@as(u32, 3), first.attempts);
    try std.testing.expectEqual(@as(u8, 4), first.priority);
    try std.testing.expectEqual(@as(i64, 200), first.moved_at_ms);
    try std.testing.expectEqual(@as(u64, 9), page.total);
    try std.testing.expect(page.has_more);
    try std.testing.expectEqual(@as(u64, 8), page.last_seq);

    var next = try queue.dlqList("jobs", .{ .after = page.last_seq });
    defer next.deinit();
    try std.testing.expectEqualSlices(u8, &(le(@as(u32, 100)) ++ le(@as(u64, 8))), srv.lastValue());
    try std.testing.expectEqual(@as(usize, 0), next.letters.len);
    try std.testing.expect(!next.has_more);

    try std.testing.expectError(FloError.BadRequest, queue.dlqList("jobs", .{ .limit = 0 }));
    try std.testing.expectError(FloError.BadRequest, queue.dlqList("jobs", .{ .limit = 101 }));
}

fn decodeDlqAndFree(a: Allocator, data: []const u8) !void {
    var page = try decodeDlqPage(a, data);
    page.deinit();
}

test "a DLQ page cut anywhere, overlong or short of memory is refused and leaks nothing" {
    const a = std.testing.allocator;
    const data: []const u8 = test_dlq_page;
    for (0..data.len) |n| try std.testing.expectError(FloError.IncompleteResponse, decodeDlqAndFree(a, data[0..n]));
    try std.testing.expectError(FloError.IncompleteResponse, decodeDlqAndFree(a, test_dlq_page ++ "\x00"));
    try std.testing.checkAllAllocationFailures(a, decodeDlqAndFree, .{data});
}

/// Two ready messages, the second cut to 1 byte of 3, and more.
const test_peek_answer = "\x02" ++
    le(@as(u64, 4)) ++ le(@as(u32, 0)) ++ le(@as(u32, 0)) ++ le(@as(i64, 50)) ++ le(@as(u32, 2)) ++ "\x02\x00hi" ++
    le(@as(u64, 5)) ++ le(@as(u32, 7)) ++ le(@as(u32, 1)) ++ le(@as(i64, 51)) ++ le(@as(u32, 3)) ++ "\x01\x00x" ++ "\x01";

test "peek sends its limit as the body and reads the messages and more" {
    const a = std.testing.allocator;
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{.{ .status = 0, .body = test_peek_answer }};
    try srv.start();
    defer srv.deinit();
    var client = Client.init(a, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var queue = Queue.init(&client);

    var got = try queue.peek("jobs", 2, .{});
    defer got.deinit();
    try std.testing.expectEqual(@as(u16, 0x180), srv.last_op);
    try std.testing.expectEqualStrings("jobs", srv.lastKey());
    try std.testing.expectEqualSlices(u8, "\x01" ++ le(@as(u32, 2)), srv.lastBody());
    try std.testing.expectEqual(@as(usize, 2), got.messages.len);
    try std.testing.expectEqualStrings("hi", got.messages[0].payload);
    try std.testing.expectEqual(@as(u32, 7), got.messages[1].priority);
    try std.testing.expectEqual(@as(u32, 1), got.messages[1].attempts);
    try std.testing.expectEqual(@as(u32, 3), got.messages[1].size);
    try std.testing.expect(got.more);

    try std.testing.expectError(FloError.BadRequest, queue.peek("jobs", 0, .{}));
    try std.testing.expectError(FloError.BadRequest, queue.peek("jobs", 101, .{}));
}

fn decodePeekAndFree(a: Allocator, data: []const u8) !void {
    var got = try decodePeekAnswer(a, data);
    got.deinit();
}

test "a peek answer cut anywhere, overlong or short of memory is refused and leaks nothing" {
    const a = std.testing.allocator;
    const data: []const u8 = test_peek_answer;
    for (0..data.len) |n| try std.testing.expectError(FloError.IncompleteResponse, decodePeekAndFree(a, data[0..n]));
    try std.testing.expectError(FloError.IncompleteResponse, decodePeekAndFree(a, test_peek_answer ++ "\x00"));
    try std.testing.checkAllAllocationFailures(a, decodePeekAndFree, .{data});
}

/// A dequeue's answer: message 7 (priority 2, delivery 1, "hi") and 9
/// (delivery 2, empty), leased at term 3, index 40, until 5000.
const test_dequeue_answer = "\x02" ++
    le(@as(u64, 7)) ++ le(@as(u32, 2)) ++ le(@as(u32, 1)) ++ le(@as(i64, 100)) ++ le(@as(u32, 2)) ++ "hi" ++
    le(@as(u64, 9)) ++ le(@as(u32, 0)) ++ le(@as(u32, 2)) ++ le(@as(i64, 101)) ++ le(@as(u32, 0)) ++
    le(@as(u64, 3)) ++ le(@as(u64, 40)) ++ le(@as(i64, 5000));

/// A report's answer: 1 applied, message 9 refused delivered_again.
const test_report_answer = le(@as(u32, 1)) ++ "\x01" ++ le(@as(u64, 9)) ++ "\x01" ++ "\x05redo!";

const test_touch_answer = le(@as(i64, 8000)) ++ test_report_answer;

const Fake = struct {
    srv: test_server.OkServer,
    client: Client = undefined,

    fn start(f: *Fake, replies: []const test_server.Reply) !void {
        f.srv = try test_server.OkServer.listen();
        f.srv.replies = replies;
        try f.srv.start();
        f.client = Client.init(std.testing.allocator, f.srv.endpoint, .{ .retry = .{ .initial_backoff_ms = 1, .max_backoff_ms = 1 } });
        try f.client.connect();
    }

    fn stop(f: *Fake) void {
        f.client.deinit();
        f.srv.deinit();
    }
};

test "dequeue sends consumer, count, lease, block_ms and ack as its body and reads the messages and their lease" {
    var f: Fake = .{ .srv = undefined };
    try f.start(&.{ .{ .status = 0, .body = test_dequeue_answer }, .{ .status = 0, .body = "\x00" ++ le(@as(u64, 0)) ++ le(@as(u64, 0)) ++ le(@as(i64, 0)) } });
    defer f.stop();
    var queue = Queue.init(&f.client);

    var got = try queue.dequeue("jobs", 2, .{ .consumer = "c1", .lease_ms = 60_000, .block_ms = 500, .ack = true });
    defer got.deinit();
    try std.testing.expectEqual(@as(u16, 0x181), f.srv.last_op);
    try std.testing.expectEqualStrings("jobs", f.srv.lastKey());
    try std.testing.expectEqualSlices(u8, "\x01\x02\x00c1" ++ "\x01" ++ le(@as(u32, 2)) ++ "\x01" ++ le(@as(u64, 60_000)) ++ "\x01" ++ le(@as(u64, 500)) ++ "\x01\x01", f.srv.lastBody());
    try std.testing.expectEqual(@as(u64, 500), dequeueBodyBlockMs(f.srv.lastBody()));
    try std.testing.expectEqual(@as(usize, 2), got.messages.len);
    try std.testing.expectEqual(@as(u64, 7), got.messages[0].seq);
    try std.testing.expectEqual(@as(u32, 2), got.messages[0].priority);
    try std.testing.expectEqualStrings("hi", got.messages[0].payload);
    try std.testing.expectEqual(@as(u32, 2), got.messages[1].deliveries);
    try std.testing.expectEqual(types.QueueLease{ .term = 3, .index = 40 }, got.lease);
    try std.testing.expectEqual(@as(i64, 5000), got.expires_at_ms);

    // The defaults: no consumer, no lease (the server's), no wait, leased.
    var none = try queue.dequeue("jobs", 1, .{});
    defer none.deinit();
    try std.testing.expectEqualSlices(u8, "\x01\x00\x00" ++ "\x01" ++ le(@as(u32, 1)) ++ "\x00" ++ "\x01" ++ le(@as(u64, 0)) ++ "\x01\x00", f.srv.lastBody());
    try std.testing.expectEqual(@as(usize, 0), none.messages.len);
}

test "dequeue refuses a count, lease, consumer or wait the server would, before sending" {
    var client = Client.init(std.testing.allocator, "localhost:1", .{});
    defer client.deinit();
    var queue = Queue.init(&client);
    try std.testing.expectError(FloError.BadRequest, queue.dequeue("q", 0, .{}));
    try std.testing.expectError(FloError.BadRequest, queue.dequeue("q", 101, .{}));
    try std.testing.expectError(FloError.BadRequest, queue.dequeue("q", 1, .{ .lease_ms = 4999 }));
    try std.testing.expectError(FloError.BadRequest, queue.dequeue("q", 1, .{ .lease_ms = types.MAX_QUEUE_LEASE_MS + 1 }));
    try std.testing.expectError(FloError.ValueTooLarge, queue.dequeue("q", 1, .{ .consumer = "c" ** (types.MAX_QUEUE_CONSUMER + 1) }));
    try std.testing.expectError(FloError.BlockTooLong, queue.dequeue("q", 1, .{ .block_ms = types.MAX_BLOCK_MS + 1 }));
}

test "complete, fail and touch name the lease and each message's delivery, and read what was refused" {
    var f: Fake = .{ .srv = undefined };
    try f.start(&.{ .{ .status = 0, .body = test_report_answer }, .{ .status = 0, .body = test_report_answer }, .{ .status = 0, .body = test_touch_answer } });
    defer f.stop();
    var queue = Queue.init(&f.client);
    var got = try decodeDequeueAnswer(std.testing.allocator, test_dequeue_answer);
    defer got.deinit();
    const opening = "\x01\x02\x00c1" ++ le(@as(u64, 3)) ++ le(@as(u64, 40)) ++ "\x02" ++ le(@as(u64, 7)) ++ le(@as(u32, 1)) ++ le(@as(u64, 9)) ++ le(@as(u32, 2));

    var done = try queue.complete("jobs", got.lease, got.messages, .{ .consumer = "c1" });
    defer done.deinit();
    try std.testing.expectEqual(@as(u16, 0x182), f.srv.last_op);
    try std.testing.expectEqualStrings("jobs", f.srv.lastKey());
    try std.testing.expectEqualSlices(u8, opening, f.srv.lastBody());
    try std.testing.expectEqual(@as(u32, 1), done.applied);
    try std.testing.expectEqual(@as(usize, 1), done.refused.len);
    try std.testing.expectEqual(@as(u64, 9), done.refused[0].seq);
    try std.testing.expectEqual(types.QueueRefusalWhy.delivered_again, done.refused[0].why);
    try std.testing.expectEqualStrings("redo!", done.refused[0].reason);

    var failed = try queue.fail("jobs", got.lease, got.messages, .{ .consumer = "c1", .delay_ms = 250, .dead = true, .error_message = "boom" });
    defer failed.deinit();
    try std.testing.expectEqual(@as(u16, 0x183), f.srv.last_op);
    try std.testing.expectEqualSlices(u8, opening ++ "\x01" ++ le(@as(u64, 250)) ++ "\x01\x01" ++ "\x01\x04\x00boom", f.srv.lastBody());

    var kept = try queue.touch("jobs", got.lease, got.messages, .{ .consumer = "c1" });
    defer kept.deinit();
    try std.testing.expectEqual(@as(u16, 0x184), f.srv.last_op);
    try std.testing.expectEqualSlices(u8, opening, f.srv.lastBody());
    try std.testing.expectEqual(@as(i64, 8000), kept.expires_at_ms);
    try std.testing.expectEqual(@as(u32, 1), kept.applied);
}

test "a refusal code this SDK predates is kept as its number" {
    var r = try decodeReportAnswer(std.testing.allocator, le(@as(u32, 0)) ++ "\x01" ++ le(@as(u64, 1)) ++ "\x2a" ++ "\x00", false);
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 42), @intFromEnum(r.refused[0].why));
}

fn decodeDequeueAndFree(a: Allocator, data: []const u8) !void {
    var r = try decodeDequeueAnswer(a, data);
    r.deinit();
}

fn decodeReportAndFree(a: Allocator, data: []const u8) !void {
    var r = try decodeReportAnswer(a, data, true);
    r.deinit();
}

test "dequeue and report answers cut anywhere, overlong or short of memory are refused and leak nothing" {
    const a = std.testing.allocator;
    const dq: []const u8 = test_dequeue_answer;
    const rp: []const u8 = test_touch_answer;
    for (0..dq.len) |n| try std.testing.expectError(FloError.IncompleteResponse, decodeDequeueAndFree(a, dq[0..n]));
    for (0..rp.len) |n| try std.testing.expectError(FloError.IncompleteResponse, decodeReportAndFree(a, rp[0..n]));
    try std.testing.expectError(FloError.IncompleteResponse, decodeDequeueAndFree(a, test_dequeue_answer ++ "\x00"));
    try std.testing.expectError(FloError.IncompleteResponse, decodeReportAndFree(a, test_touch_answer ++ "\x00"));
    try std.testing.checkAllAllocationFailures(a, decodeDequeueAndFree, .{dq});
    try std.testing.checkAllAllocationFailures(a, decodeReportAndFree, .{rp});
}

test "reports refuse no messages, more than 100, or an error the server would, before sending" {
    var client = Client.init(std.testing.allocator, "localhost:1", .{});
    defer client.deinit();
    var queue = Queue.init(&client);
    const lease: types.QueueLease = .{ .term = 1, .index = 1 };
    var many: [101]types.Message = undefined;
    for (&many) |*m| m.* = .{ .seq = 1, .priority = 0, .deliveries = 1, .enqueued_at_ms = 0, .payload = "" };
    try std.testing.expectError(FloError.BadRequest, queue.complete("q", lease, &.{}, .{}));
    try std.testing.expectError(FloError.BadRequest, queue.touch("q", lease, &many, .{}));
    try std.testing.expectError(FloError.ValueTooLarge, queue.fail("q", lease, many[0..1], .{ .error_message = "e" ** 1025 }));
    try std.testing.expectError(FloError.BadRequest, queue.fail("q", lease, many[0..1], .{ .delay_ms = types.MAX_FAIL_DELAY_MS + 1 }));
}

test "enqueue sends delay_ms when it's set, and a full queue is overloaded, retried, then returned" {
    // overloaded, unclassified, ran no: past the queue's cap.
    const full: test_server.Reply = .{ .status = 10, .body = "\x0c\x00\x00overloaded: queue 'jobs' is full: it holds 2 messages (at most 2)" };
    var f: Fake = .{ .srv = undefined };
    try f.start(&.{ .{ .status = 0, .body = &le(@as(u64, 5)) }, full, full, full, full });
    defer f.stop();
    var queue = Queue.init(&f.client);
    try std.testing.expectEqual(@as(u64, 5), try queue.enqueue("jobs", "x", .{ .priority = 3, .delay_ms = 1500 }));
    // [priority: tag, 1, value][delay_ms: tag, 8, u64]
    try std.testing.expectEqualSlices(u8, "\x10\x01\x03" ++ "\x11\x08" ++ le(@as(u64, 1500)), f.srv.lastOptions());

    try std.testing.expectError(FloError.Overloaded, queue.enqueue("jobs", "x", .{}));
    try std.testing.expectEqual(@as(u32, 5), f.srv.requests.load(.acquire));
    try std.testing.expect(std.mem.startsWith(u8, f.client.lastError().?.message, "overloaded: queue 'jobs' is full"));
}

test "purge answers how many messages it removed" {
    var f: Fake = .{ .srv = undefined };
    try f.start(&.{.{ .status = 0, .body = &le(@as(u32, 12)) }});
    defer f.stop();
    var queue = Queue.init(&f.client);
    try std.testing.expectEqual(@as(u32, 12), try queue.purge("jobs", .{}));
    try std.testing.expectEqual(@as(u16, 0x17F), f.srv.last_op);
    try std.testing.expectEqualStrings("jobs", f.srv.lastKey());
}
