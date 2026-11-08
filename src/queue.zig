//! Flo Queue Operations
//!
//! Message queue operations: enqueue, dequeue, ack, nack, DLQ management.

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

    /// Enqueue a message to a queue.
    /// Returns the message sequence number.
    pub fn enqueue(
        self: *Queue,
        queue_name: []const u8,
        payload: []const u8,
        options: types.EnqueueOptions,
    ) FloError!u64 {
        const ns = self.client.getNamespace(options.namespace);

        var opts_buf: [64]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);

        try builder.addU8(.priority, options.priority);

        var response = try self.client.sendRequest(
            .queue_enqueue,
            ns,
            queue_name,
            payload,
            builder.getOptions(),
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }

        // Parse response to get sequence number
        if (response.data.len >= 8) {
            return std.mem.readInt(u64, response.data[0..8], .little);
        }

        return 0;
    }

    /// Dequeue messages from a queue.
    /// **Caller owns the returned `DequeueResult` and must call `result.deinit()`.**
    pub fn dequeue(
        self: *Queue,
        queue_name: []const u8,
        count: u32,
        options: types.DequeueOptions,
    ) FloError!types.DequeueResult {
        const ns = self.client.getNamespace(options.namespace);

        var opts_buf: [48]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);

        try builder.addU32(.count, count);

        if (options.block_ms) |block| {
            try builder.addU32(.block_ms, block);
        }

        var response = try self.client.sendRequest(
            .queue_dequeue,
            ns,
            queue_name,
            "",
            builder.getOptions(),
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }

        return wire.parseDequeueResponse(self.client.allocator, response.data);
    }

    /// Acknowledge messages. Dequeue already acknowledges each message it
    /// hands out (queues are at-most-once), so this has no effect on one.
    pub fn ack(
        self: *Queue,
        queue_name: []const u8,
        seqs: []const u64,
        options: types.AckOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var value_buf: [4096]u8 = undefined;
        const value = try wire.serializeSeqs(&value_buf, seqs);

        var response = try self.client.sendRequest(
            .queue_complete,
            ns,
            queue_name,
            value,
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }
    }

    /// Negative acknowledge messages. Dequeue already acknowledged them, so
    /// this has no effect on a dequeued message and does not retry it.
    pub fn nack(
        self: *Queue,
        queue_name: []const u8,
        seqs: []const u64,
        options: types.NackOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var value_buf: [4096]u8 = undefined;
        const value = try wire.serializeSeqs(&value_buf, seqs);

        var response = try self.client.sendRequest(
            .queue_fail,
            ns,
            queue_name,
            value,
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }
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

    /// Requeue messages from DLQ back to main queue. The server refuses this
    /// as not implemented.
    pub fn dlqRequeue(
        self: *Queue,
        queue_name: []const u8,
        seqs: []const u64,
        options: types.DlqRequeueOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var value_buf: [4096]u8 = undefined;
        const value = try wire.serializeSeqs(&value_buf, seqs);

        var response = try self.client.sendRequest(
            .queue_dlq_requeue,
            ns,
            queue_name,
            value,
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }
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
