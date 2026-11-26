//! A page of a run's history, a workflow's (`workflow.history`) or an
//! action's (`action.history`): both are table ops with the same request
//! and answer, routed by the run id in the key.

const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");
const Client = @import("client.zig").Client;
const Reader = @import("kv.zig").Reader;

const FloError = types.FloError;
const Allocator = std.mem.Allocator;

/// The most events one page holds.
pub const MAX_PAGE: u16 = 1000;
/// The longest event type and detail an event carries.
pub const MAX_EVENT_FIELD: u32 = 65_536;
/// The longest extra an event carries.
pub const MAX_EXTRA: u16 = 256;
/// The most events a read may ask for.
pub const MAX_LIMIT: u32 = MAX_PAGE;
/// How long the server may hold a read while the run's history catches up,
/// so the client's deadline allows for it.
pub const HOLD_MS: u64 = 5_000;

/// The request: limit, cursor, newest_first, each a presence byte then its
/// value; an absent one is the server's default.
pub const MAX_BODY = 5 + 9 + 2;

pub fn encodeBody(buf: *[MAX_BODY]u8, options: types.RunHistoryOptions) []const u8 {
    var pos: usize = 0;
    if (options.limit) |limit| {
        buf[0] = 1;
        std.mem.writeInt(u32, buf[1..5], limit, .little);
        pos = 5;
    } else {
        buf[0] = 0;
        pos = 1;
    }
    if (options.cursor) |cursor| {
        buf[pos] = 1;
        std.mem.writeInt(u64, buf[pos + 1 ..][0..8], cursor, .little);
        pos += 9;
    } else {
        buf[pos] = 0;
        pos += 1;
    }
    if (options.newest_first) |newest| {
        buf[pos] = 1;
        buf[pos + 1] = @intFromBool(newest);
        pos += 2;
    } else {
        buf[pos] = 0;
        pos += 1;
    }
    return buf[0..pos];
}

/// Ask for a page of `run_id`'s history with `op`, either history op.
pub fn read(client: *Client, allocator: Allocator, op: types.OpCode, run_id: []const u8, options: types.RunHistoryOptions) FloError!types.RunHistoryPage {
    if (options.limit) |limit| if (limit < 1 or limit > MAX_LIMIT) return FloError.BadRequest;
    var buf: [MAX_BODY]u8 = undefined;
    const body = encodeBody(&buf, options);
    var response = try client.sendRequest(op, client.getNamespace(options.namespace), run_id, body, "");
    defer response.deinit();
    if (response.status != .ok) return response.status.toError();
    return decodePage(allocator, response.data);
}

/// An event's smallest encoding: three empty fields and its timestamp.
const min_event = 4 + 4 + 2 + 8;

/// The answer: events (u16 count), each [event_type:u32 len][detail:u32 len]
/// [extra:u16 len][timestamp_ms:i64]; then has_more, then cursor?. A
/// cursor that contradicts has_more, or bytes past it, are refused.
pub fn decodePage(allocator: Allocator, data: []const u8) FloError!types.RunHistoryPage {
    var r: Reader = .{ .data = data };
    const n = try r.int(u16);
    // A count the data can't hold is refused before it sizes an allocation.
    if (n > MAX_PAGE or n > r.remaining() / min_event) return FloError.IncompleteResponse;
    const events = try allocator.alloc(types.RunHistoryEvent, n);
    var got: usize = 0;
    errdefer {
        for (events[0..got]) |e| {
            allocator.free(e.event_type);
            allocator.free(e.detail);
            allocator.free(e.extra);
        }
        allocator.free(events);
    }
    while (got < n) : (got += 1) {
        const event_type = try r.lenBytes(u32);
        const detail = try r.lenBytes(u32);
        const extra = try r.lenBytes(u16);
        const timestamp_ms = try r.int(i64);
        if (event_type.len > MAX_EVENT_FIELD or detail.len > MAX_EVENT_FIELD or extra.len > MAX_EXTRA) return FloError.IncompleteResponse;
        const type_copy = try allocator.dupe(u8, event_type);
        errdefer allocator.free(type_copy);
        const detail_copy = try allocator.dupe(u8, detail);
        errdefer allocator.free(detail_copy);
        events[got] = .{
            .event_type = type_copy,
            .detail = detail_copy,
            .extra = try allocator.dupe(u8, extra),
            .timestamp_ms = timestamp_ms,
        };
    }
    const has_more = try r.boolean();
    const cursor = try r.opt(u64);
    try r.end();
    // A next page with no cursor can't be asked for.
    if (has_more != (cursor != null)) return FloError.UnexpectedResponse;
    return .{ .events = events, .has_more = has_more, .cursor = cursor, .allocator = allocator };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const le = std.mem.toBytes;

/// Two events: "action_invoked" with detail "in" at 5; "action_settled"
/// with detail "out", extra "approved", at -1; has_more, cursor 7.
const two_events = "\x02\x00" ++
    le(@as(u32, 14)) ++ "action_invoked" ++ le(@as(u32, 2)) ++ "in" ++ "\x00\x00" ++ le(@as(i64, 5)) ++
    le(@as(u32, 14)) ++ "action_settled" ++ le(@as(u32, 3)) ++ "out" ++ "\x08\x00approved" ++ le(@as(i64, -1)) ++
    "\x01" ++ "\x01" ++ le(@as(u64, 7));

test "a history page decodes per the server's layout" {
    var page = try decodePage(testing.allocator, two_events);
    defer page.deinit();
    try testing.expectEqual(@as(usize, 2), page.events.len);
    try testing.expectEqualStrings("action_invoked", page.events[0].event_type);
    try testing.expectEqualStrings("in", page.events[0].detail);
    try testing.expectEqualStrings("", page.events[0].extra);
    try testing.expectEqual(@as(i64, 5), page.events[0].timestamp_ms);
    try testing.expectEqualStrings("action_settled", page.events[1].event_type);
    try testing.expectEqualStrings("out", page.events[1].detail);
    try testing.expectEqualStrings("approved", page.events[1].extra);
    try testing.expectEqual(@as(i64, -1), page.events[1].timestamp_ms);
    try testing.expect(page.has_more);
    try testing.expectEqual(@as(?u64, 7), page.cursor);
}

test "an empty last page has no events and no cursor" {
    var page = try decodePage(testing.allocator, "\x00\x00" ++ "\x00" ++ "\x00");
    defer page.deinit();
    try testing.expectEqual(@as(usize, 0), page.events.len);
    try testing.expect(!page.has_more);
    try testing.expectEqual(@as(?u64, null), page.cursor);
}

test "an event's detail is u32-length: one past 64 KiB decodes whole" {
    const a = testing.allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(a);
    try data.appendSlice(a, "\x01\x00" ++ le(@as(u32, 15)) ++ "workflow_output");
    try data.appendSlice(a, &le(MAX_EVENT_FIELD));
    try data.appendNTimes(a, 'd', MAX_EVENT_FIELD);
    try data.appendSlice(a, "\x00\x00" ++ le(@as(i64, 9)) ++ "\x00\x00");
    var page = try decodePage(a, data.items);
    defer page.deinit();
    try testing.expectEqual(@as(usize, MAX_EVENT_FIELD), page.events[0].detail.len);
    try testing.expectEqualStrings("workflow_output", page.events[0].event_type);
    // One byte more than the server's bound is refused.
    std.mem.writeInt(u32, data.items[2 + 4 + 15 ..][0..4], MAX_EVENT_FIELD + 1, .little);
    try data.insert(a, 2 + 4 + 15 + 4, 'd');
    try testing.expectError(FloError.IncompleteResponse, decodePage(a, data.items));
}

test "a history page whose cursor contradicts has_more, or with bytes past it, is refused" {
    const a = testing.allocator;
    try testing.expectError(FloError.UnexpectedResponse, decodePage(a, "\x00\x00" ++ "\x00" ++ "\x01" ++ le(@as(u64, 1))));
    try testing.expectError(FloError.UnexpectedResponse, decodePage(a, "\x00\x00" ++ "\x01" ++ "\x00"));
    try testing.expectError(FloError.IncompleteResponse, decodePage(a, two_events ++ "x"));
    // An extra past its bound.
    const long_extra = "\x01\x00" ++ le(@as(u32, 1)) ++ "e" ++ le(@as(u32, 0)) ++ "\x01\x01" ++ "x" ** 257 ++ le(@as(i64, 0)) ++ "\x00\x00";
    try testing.expectError(FloError.IncompleteResponse, decodePage(a, long_extra));
}

fn decodeAndFree(a: Allocator, data: []const u8) !void {
    var page = try decodePage(a, data);
    page.deinit();
}

test "a history answer cut anywhere, overcounted, or short of memory leaks nothing" {
    const a = testing.allocator;
    for (0..two_events.len) |n| try testing.expect(std.meta.isError(decodeAndFree(a, two_events[0..n])));
    // A count far past what the data holds is refused before it allocates.
    try testing.expectError(FloError.IncompleteResponse, decodeAndFree(a, "\xff\xff" ++ two_events[2..]));
    try testing.checkAllAllocationFailures(a, decodeAndFree, .{@as([]const u8, two_events)});
}

test "the request sends each field given, and an absent byte for each left to the server" {
    var buf: [MAX_BODY]u8 = undefined;
    try testing.expectEqualSlices(u8, "\x00\x00\x00", encodeBody(&buf, .{}));
    try testing.expectEqualSlices(u8, "\x01" ++ le(@as(u32, 0)) ++ "\x00\x00", encodeBody(&buf, .{ .limit = 0 }));
    try testing.expectEqualSlices(
        u8,
        "\x01" ++ le(@as(u32, 1000)) ++ "\x01" ++ le(@as(u64, 42)) ++ "\x01\x01",
        encodeBody(&buf, .{ .limit = 1000, .cursor = 42, .newest_first = true }),
    );
    try testing.expectEqualSlices(u8, "\x00\x00\x01\x00", encodeBody(&buf, .{ .newest_first = false }));
}

test "a limit outside 1 to 1000 is refused before anything is sent" {
    var client = Client.init(testing.allocator, "127.0.0.1:1", .{});
    defer client.deinit();
    for ([_]u32{ 0, MAX_LIMIT + 1 }) |limit| {
        try testing.expectError(FloError.BadRequest, read(&client, testing.allocator, .workflow_history, "r", .{ .limit = limit }));
    }
}

test "both history ops are table ops" {
    try testing.expect(wire.isTableOp(.workflow_history));
    try testing.expect(wire.isTableOp(.action_history));
    try testing.expectEqual(@as(u16, 0x345), @intFromEnum(types.OpCode.workflow_history));
    try testing.expectEqual(@as(u16, 0x310), @intFromEnum(types.OpCode.action_history));
}

test "Workflow.history and Actions.history send the run id as the key and the body framed as a table op" {
    const a = testing.allocator;
    var srv = try @import("test_server.zig").OkServer.listen();
    srv.replies = &.{
        .{ .status = 0, .body = two_events },
        .{ .status = 0, .body = "\x00\x00\x00\x00" },
    };
    try srv.start();
    defer srv.deinit();
    var client = Client.init(a, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();

    var workflow = @import("workflow.zig").Workflow.init(&client);
    var page = try workflow.history(a, "wf-1", .{ .limit = 2 });
    defer page.deinit();
    try testing.expectEqual(@as(u16, 0x345), srv.last_op);
    try testing.expectEqualStrings("wf-1", srv.lastKey());
    try testing.expectEqualSlices(u8, "\x01\x02\x00\x00\x00\x00\x00", srv.lastBody());
    try testing.expectEqual(@as(usize, 2), page.events.len);

    var actions = @import("actions.zig").Actions.init(&client);
    var last = try actions.history("act-1", .{ .cursor = page.cursor, .newest_first = true });
    defer last.deinit();
    try testing.expectEqual(@as(u16, 0x310), srv.last_op);
    try testing.expectEqualStrings("act-1", srv.lastKey());
    try testing.expectEqualSlices(u8, "\x00\x01" ++ le(@as(u64, 7)) ++ "\x01\x01", srv.lastBody());
    try testing.expectEqual(@as(usize, 0), last.events.len);
    try testing.expect(!last.has_more);
}
