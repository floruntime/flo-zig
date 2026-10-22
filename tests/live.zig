//! Live tests against a real flo server: FLO_ENDPOINT names it (CI starts
//! the commit pinned in .github/flo-ref.env), and FLO_BINARY the binary,
//! for the version check. Without FLO_ENDPOINT they skip, except under
//! CI=1, where a missing server is a failure, not a skip.
//! FLO_FAST_EXPIRY_ENDPOINT names a second server, configured to remove a
//! worker silent for a second, for the re-registration test; it skips (or
//! fails under CI=1) the same way.

const std = @import("std");
const flo = @import("flo");

const testing = std.testing;

fn env(name: []const u8) ?[]const u8 {
    return std.posix.getenv(name);
}

/// The endpoint, or a skip (a failure in CI) when none is set.
fn endpoint() ![]const u8 {
    if (env("FLO_ENDPOINT")) |e| return e;
    if (env("CI") != null) return error.NoServerInCI;
    return error.SkipZigTest;
}

/// A namespace of its own, so tests on one server don't see each other's data.
fn freshNamespace(buf: []u8) []const u8 {
    var bytes: [4]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return std.fmt.bufPrint(buf, "live-{x}", .{std.mem.readInt(u32, &bytes, .little)}) catch unreachable;
}

const Live = struct {
    client: flo.Client,
    ns_buf: [32]u8 = undefined,
    namespace: []const u8 = "",

    fn init(self: *Live) !void {
        self.namespace = freshNamespace(&self.ns_buf);
        self.client = flo.Client.init(testing.allocator, try endpoint(), .{ .namespace = self.namespace, .timeout_ms = 10_000 });
        try self.client.connect();
    }

    fn deinit(self: *Live) void {
        self.client.deinit();
    }
};

test "live: the server speaks this SDK's protocol and table" {
    _ = try endpoint();
    const binary = env("FLO_BINARY") orelse {
        if (env("CI") != null) return error.NoBinaryInCI;
        return error.SkipZigTest;
    };
    var home_buf: [64]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, "/tmp/flo-zig-live-home-{d}", .{std.time.milliTimestamp()});
    try std.fs.cwd().makePath(home);
    defer std.fs.cwd().deleteTree(home) catch {};
    var env_map = try std.process.getEnvMap(testing.allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home);
    const run = try std.process.Child.run(.{ .allocator = testing.allocator, .argv = &.{ binary, "version", "--verbose" }, .env_map = &env_map });
    defer testing.allocator.free(run.stdout);
    defer testing.allocator.free(run.stderr);
    // "... (protocol 2, table 0x2fba7dd9ae941830; ..."
    const p = std.mem.indexOf(u8, run.stdout, "protocol ") orelse return error.NoProtocol;
    const t = std.mem.indexOf(u8, run.stdout, "table 0x") orelse return error.NoTable;
    const proto_end = std.mem.indexOfScalarPos(u8, run.stdout, p, ',') orelse return error.NoProtocol;
    try testing.expectEqual(flo.VERSION, try std.fmt.parseInt(u8, run.stdout[p + "protocol ".len .. proto_end], 10));
    const hash_start = t + "table 0x".len;
    const hash_end = std.mem.indexOfAnyPos(u8, run.stdout, hash_start, ";) \n") orelse return error.NoTable;
    try testing.expectEqual(flo.TABLE_HASH, try std.fmt.parseInt(u64, run.stdout[hash_start..hash_end], 16));
}

test "live: puts, gets and mgets keys" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    var kv = flo.KV.init(&live.client);
    _ = try kv.put("a", "1", .{});
    _ = try kv.put("b", "2", .{});
    var a = (try kv.get("a", .{})).?;
    defer a.deinit(testing.allocator);
    var b = (try kv.get("b", .{})).?;
    defer b.deinit(testing.allocator);
    try testing.expectEqualStrings("1", a.value);
    var got = try kv.mget(&.{ "a", "missing", "b" }, .{});
    defer got.deinit();
    try testing.expectEqual(@as(usize, 3), got.entries.len);
    try testing.expectEqualStrings("a", got.entries[0].key);
    try testing.expect(got.entries[0].found);
    try testing.expectEqualStrings("1", got.entries[0].value);
    try testing.expectEqual(a.version, got.entries[0].version);
    try testing.expectEqualStrings("missing", got.entries[1].key);
    try testing.expect(!got.entries[1].found);
    try testing.expectEqualStrings("", got.entries[1].value);
    try testing.expectEqual(@as(u64, 0), got.entries[1].version);
    try testing.expectEqualStrings("b", got.entries[2].key);
    try testing.expect(got.entries[2].found);
    try testing.expectEqualStrings("2", got.entries[2].value);
    try testing.expectEqual(b.version, got.entries[2].version);
}

test "live: appends to a stream and reads it back in order, with headers" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    var stream = flo.Stream.init(&live.client);
    const ids = [_]flo.StreamID{
        (try stream.append("events", "one", .{})).id,
        (try stream.append("events", "two", .{ .headers = &.{.{ .key = "source", .value = "live" }} })).id,
        (try stream.append("events", "three", .{})).id,
    };
    var res = try stream.read("events", .{});
    defer res.deinit();
    try testing.expectEqual(@as(usize, 3), res.records.len);
    try testing.expectEqualStrings("one", res.records[0].payload);
    try testing.expectEqualStrings("two", res.records[1].payload);
    try testing.expectEqualStrings("three", res.records[2].payload);
    try testing.expectEqual(@as(usize, 1), res.records[1].headers.len);
    try testing.expectEqualStrings("source", res.records[1].headers[0].key);
    try testing.expectEqualStrings("live", res.records[1].headers[0].value);
    try testing.expectEqual(@as(usize, 0), res.records[0].headers.len);
    try testing.expectEqual(@as(usize, 0), res.records[2].headers.len);
    // Read back in append order, each with the id its append answered.
    for (res.records, ids) |r, id| try testing.expectEqual(id, r.id);
}

test "live: enqueues, dequeues and acks a message" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    var queue = flo.Queue.init(&live.client);
    const seq = try queue.enqueue("jobs", "job-1", .{});
    var res = try queue.dequeue("jobs", 1, .{});
    defer res.deinit();
    try testing.expectEqual(@as(usize, 1), res.messages.len);
    try testing.expectEqualStrings("job-1", res.messages[0].payload);
    try testing.expectEqual(seq, res.messages[0].seq);
    try queue.ack("jobs", &.{res.messages[0].seq}, .{});
    var again = try queue.peek("jobs", 10, .{});
    defer again.deinit();
    try testing.expectEqual(@as(usize, 0), again.messages.len);
}

test "live: the status of a run id the server never minted is not found" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    var actions = flo.Actions.init(&live.client);
    try testing.expectError(flo.FloError.NotFound, actions.getStatus("act-0-0", .{}));
}

const Echo = struct {
    var input: [64]u8 = undefined;
    var input_len: usize = 0;

    fn handle(ctx: *flo.ActionContext) anyerror!flo.ActionHandlerResult {
        input_len = @min(ctx.payload.len, input.len);
        @memcpy(input[0..input_len], ctx.payload[0..input_len]);
        return .{ .bytes = try ctx.allocator.dupe(u8, "ok") };
    }
};

fn runWorker(worker: *flo.ActionWorker) void {
    worker.start() catch |err| std.log.err("live worker: {}", .{err});
}

test "live: a worker runs an invoked action, and the run's status then carries its output" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    var worker = try flo.ActionWorker.init(std.heap.page_allocator, .{ .endpoint = try endpoint(), .namespace = live.namespace, .block_ms = 1000 });
    defer worker.deinit();
    try worker.registerAction("echo", Echo.handle, .{});
    const thread = try std.Thread.spawn(.{}, runWorker, .{&worker});
    defer thread.join();
    defer worker.stop();
    std.Thread.sleep(200 * std.time.ns_per_ms);

    var actions = flo.Actions.init(&live.client);
    const invoked_at = std.time.milliTimestamp();
    var invoked = try actions.invoke("echo", "hi", .{});
    defer invoked.deinit();
    const deadline = std.time.milliTimestamp() + 15_000;
    while (true) {
        var st = try actions.getStatus(invoked.run_id, .{});
        defer st.deinit();
        if (st.status == .completed) {
            try testing.expectEqualStrings("ok", st.output.?);
            try testing.expectEqual(@as(u32, 1), st.attempt);
            try testing.expectEqualStrings(worker.worker_id, st.worker_id.?);
            // On this machine's clock, between the invoke and now.
            const completed = st.completed_at.?;
            try testing.expect(completed >= invoked_at - 1000 and completed <= std.time.milliTimestamp() + 1000);
            try testing.expect(st.started_at.? <= completed);
            break;
        }
        if (std.time.milliTimestamp() > deadline) return error.RunNeverCompleted;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    try testing.expectEqualStrings("hi", Echo.input[0..Echo.input_len]);
}

const Slow = struct {
    var runs = std.atomic.Value(u32).init(0);

    fn handle(ctx: *flo.ActionContext) anyerror!flo.ActionHandlerResult {
        _ = runs.fetchAdd(1, .monotonic);
        std.Thread.sleep(2500 * std.time.ns_per_ms);
        return .{ .bytes = try ctx.allocator.dupe(u8, "ok") };
    }
};

// A handler past its action's 1 s timeout runs once when its worker
// touches it: without auto_touch the server would take the run back and a
// second worker would run it again. (Two workers, because one runs its
// tasks one at a time and couldn't take the run back while busy with it.)
test "live: auto_touch keeps a long handler from running twice" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    var workers: [2]flo.ActionWorker = undefined;
    for (&workers) |*w| {
        w.* = try flo.ActionWorker.init(std.heap.page_allocator, .{ .endpoint = try endpoint(), .namespace = live.namespace, .block_ms = 500, .auto_touch = true });
        try w.registerAction("slow", Slow.handle, .{ .timeout_ms = 1000 });
    }
    defer for (&workers) |*w| w.deinit();
    var threads: [2]std.Thread = undefined;
    for (&workers, &threads) |*w, *t| t.* = try std.Thread.spawn(.{}, runWorker, .{w});
    defer for (threads) |t| t.join();
    defer for (&workers) |*w| w.stop();
    std.Thread.sleep(200 * std.time.ns_per_ms);

    var actions = flo.Actions.init(&live.client);
    var invoked = try actions.invoke("slow", "", .{});
    defer invoked.deinit();
    const deadline = std.time.milliTimestamp() + 15_000;
    while (true) {
        var st = try actions.getStatus(invoked.run_id, .{});
        defer st.deinit();
        if (st.status == .completed) break;
        if (std.time.milliTimestamp() > deadline) return error.RunNeverCompleted;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    // A re-run would have started by now.
    std.Thread.sleep(1500 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u32, 1), Slow.runs.load(.monotonic));
}

fn fastExpiryEndpoint() ![]const u8 {
    if (env("FLO_FAST_EXPIRY_ENDPOINT")) |e| return e;
    if (env("CI") != null) return error.NoFastExpiryServerInCI;
    return error.SkipZigTest;
}

/// What the re-registration test checks of a worker.list row.
const ListedWorker = struct {
    worker_type: u8,
    max_concurrency: u32,
    registered_at_ms: i64,
    machine_id_buf: [255]u8 = undefined,
    machine_id_len: ?usize = null,

    fn machineId(self: *const ListedWorker) ?[]const u8 {
        return if (self.machine_id_len) |n| self.machine_id_buf[0..n] else null;
    }
};

/// Worker `id` as worker.list shows it, or null, paging to the last page.
fn listedWorker(client: *flo.Client, id: []const u8) !?ListedWorker {
    var actions = flo.Actions.init(client);
    var cursor_buf: [4096]u8 = undefined;
    var cursor: ?[]const u8 = null;
    while (true) {
        var page = try actions.listWorkers(.{ .cursor = cursor });
        defer page.deinit();
        for (page.workers) |w| {
            if (!std.mem.eql(u8, w.id, id)) continue;
            var row: ListedWorker = .{
                .worker_type = @intFromEnum(w.worker_type),
                .max_concurrency = w.max_concurrency,
                .registered_at_ms = w.registered_at_ms,
            };
            if (w.machine_id) |m| {
                @memcpy(row.machine_id_buf[0..m.len], m);
                row.machine_id_len = m.len;
            }
            return row;
        }
        const next = page.cursor orelse return null;
        @memcpy(cursor_buf[0..next.len], next);
        cursor = cursor_buf[0..next.len];
    }
}

test "live: worker.list pages a namespace's workers in id order" {
    const ep = try endpoint();
    var ns_buf: [32]u8 = undefined;
    const namespace = freshNamespace(&ns_buf);
    var client = flo.Client.init(testing.allocator, ep, .{ .namespace = namespace, .timeout_ms = 10_000 });
    defer client.deinit();
    try client.connect();
    var actions = flo.Actions.init(&client);
    const ids = [_][]const u8{ "lw-1", "lw-2", "lw-3", "lw-4", "lw-5" };
    for (ids) |id| try actions.register(id, &.{"job"}, .{ .max_concurrency = 3, .machine_id = "page-host" });

    var seen: usize = 0;
    var pages: usize = 0;
    var cursor_buf: [4096]u8 = undefined;
    var cursor: ?[]const u8 = null;
    while (true) : (pages += 1) {
        try testing.expect(pages < ids.len); // each page moves the cursor on
        var page = try actions.listWorkers(.{ .limit = 2, .cursor = cursor });
        defer page.deinit();
        try testing.expect(page.workers.len <= 2);
        for (page.workers) |w| {
            try testing.expectEqualStrings(ids[seen], w.id);
            try testing.expectEqual(flo.WorkerType.action, w.worker_type);
            try testing.expectEqual(@as(u32, 3), w.max_concurrency);
            try testing.expectEqualStrings("page-host", w.machine_id.?);
            seen += 1;
        }
        const next = page.cursor orelse break;
        if (cursor) |c| try testing.expect(std.mem.order(u8, next, c) == .gt);
        @memcpy(cursor_buf[0..next.len], next);
        cursor = cursor_buf[0..next.len];
    }
    try testing.expectEqual(ids.len, seen);
    try testing.expectEqual(@as(usize, 2), pages); // pages 0, 1 and 2
}

// The server removes a worker silent past its removal time; the worker's
// next heartbeat is answered not found, and it registers again, as it first
// did, and carries on.
test "live: a worker the server removed registers again on its next heartbeat, and still runs actions" {
    const ep = try fastExpiryEndpoint();
    var ns_buf: [32]u8 = undefined;
    const namespace = freshNamespace(&ns_buf);
    var client = flo.Client.init(testing.allocator, ep, .{ .namespace = namespace, .timeout_ms = 10_000 });
    defer client.deinit();
    try client.connect();

    // Heartbeats 4 s apart; the server removes it after 1 s of silence.
    var worker = try flo.ActionWorker.init(std.heap.page_allocator, .{
        .endpoint = ep,
        .namespace = namespace,
        .block_ms = 500,
        .concurrency = 2,
        .heartbeat_interval_ms = 4_000,
        .machine_id = "live-host",
    });
    defer worker.deinit();
    try worker.registerAction("echo", Echo.handle, .{});
    const thread = try std.Thread.spawn(.{}, runWorker, .{&worker});
    defer thread.join();
    defer worker.stop();

    var first: ?ListedWorker = null;
    var removed = false;
    var again: ?ListedWorker = null;
    const deadline = std.time.milliTimestamp() + 15_000;
    while (again == null) {
        if (std.time.milliTimestamp() > deadline) return error.NeverRegisteredAgain;
        const row = try listedWorker(&client, worker.worker_id);
        if (row) |r| {
            if (first == null) first = r else if (removed) again = r;
        } else if (first != null) removed = true;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    const a = first.?;
    const b = again.?;
    try testing.expect(b.registered_at_ms > a.registered_at_ms);
    try testing.expectEqual(@as(u8, 0), b.worker_type); // action
    try testing.expectEqual(@as(u32, 2), b.max_concurrency);
    try testing.expectEqualStrings("live-host", b.machineId().?);
    try testing.expectEqual(a.worker_type, b.worker_type);
    try testing.expectEqual(a.max_concurrency, b.max_concurrency);
    try testing.expectEqualStrings(a.machineId().?, b.machineId().?);

    var actions = flo.Actions.init(&client);
    var invoked = try actions.invoke("echo", "again", .{});
    defer invoked.deinit();
    const run_deadline = std.time.milliTimestamp() + 15_000;
    while (true) {
        var st = try actions.getStatus(invoked.run_id, .{});
        defer st.deinit();
        if (st.status == .completed) {
            try testing.expectEqualStrings("ok", st.output.?);
            try testing.expectEqualStrings(worker.worker_id, st.worker_id.?);
            break;
        }
        if (std.time.milliTimestamp() > run_deadline) return error.RunNeverCompleted;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
}
