//! Live tests against a real flo server: FLO_ENDPOINT names it (CI starts
//! the commit pinned in .github/flo-ref.env), and FLO_BINARY the binary,
//! for the version check. Without FLO_ENDPOINT they skip, except under
//! CI=1, where a missing server is a failure, not a skip.
//! FLO_FAST_EXPIRY_ENDPOINT names a second server, configured to remove a
//! worker silent for a second, for the re-registration test; it skips (or
//! fails under CI=1) the same way. FLO_OPS_JSON names the pinned flo's
//! ops.json, for the status and reason check, which skips (or fails) the
//! same way too.

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

    /// Creates the namespace with a write: a read in one never created is
    /// no_namespace, not not_found.
    fn createNamespace(self: *Live) !void {
        var kv = flo.KV.init(&self.client);
        _ = try kv.put("namespace-exists", "x", .{});
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
    // "... (protocol 3, table 0xc751512225a42d04; ..."
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

test "live: a key set with a TTL reads back with its expiry" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    var kv = flo.KV.init(&live.client);
    const ttl: i64 = 60_000;
    const before = std.time.milliTimestamp();
    _ = try kv.put("ttl", "v", .{ .ttl_ms = @intCast(ttl) });
    const after = std.time.milliTimestamp();
    var got = (try kv.get("ttl", .{})).?;
    defer got.deinit(testing.allocator);
    const expires = got.expires_at_ms orelse return error.NoExpiry;
    try testing.expect(expires >= before + ttl and expires <= after + ttl);

    _ = try kv.put("plain", "v", .{});
    var plain = (try kv.get("plain", .{})).?;
    defer plain.deinit(testing.allocator);
    try testing.expectEqual(@as(?i64, null), plain.expires_at_ms);
}

test "live: a key's history marks the version a delete wrote" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    var kv = flo.KV.init(&live.client);
    _ = try kv.put("k", "one", .{});
    try testing.expect(try kv.delete("k", .{}));
    _ = try kv.put("k", "two", .{});
    var history = try kv.history("k", .{});
    defer history.deinit();
    const versions = history.versions;
    try testing.expect(!history.more and !history.stale);
    try testing.expectEqual(@as(usize, 3), versions.len);
    try testing.expect(!versions[0].deleted);
    try testing.expectEqualStrings("two", versions[0].value);
    try testing.expect(versions[1].deleted);
    try testing.expect(!versions[2].deleted);
    try testing.expectEqualStrings("one", versions[2].value);
}

test "live: worker info shows a worker's row, metadata and processes" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    var actions = flo.Actions.init(&live.client);
    try actions.register("info-w", null, .{
        .max_concurrency = 4,
        .processes = &.{ .{ .name = "send" }, .{ .name = "events/g", .kind = .stream_consumer } },
        .metadata = "\x00raw\xff",
        .machine_id = "info-host",
    });
    var info = try actions.workerInfo("info-w", .{});
    defer info.deinit();
    try testing.expectEqualStrings("info-w", info.worker.id);
    try testing.expectEqual(flo.WorkerType.action, info.worker.worker_type);
    try testing.expectEqual(@as(u32, 4), info.worker.max_concurrency);
    try testing.expectEqualStrings("info-host", info.worker.machine_id.?);
    try testing.expectEqualStrings("\x00raw\xff", info.metadata.?);
    try testing.expectEqual(@as(usize, 2), info.processes.len);
    try testing.expectEqualStrings("send", info.processes[0].name);
    try testing.expectEqual(flo.ProcessKind.action, info.processes[0].kind);
    try testing.expectEqualStrings("events/g", info.processes[1].name);
    try testing.expectEqual(flo.ProcessKind.stream_consumer, info.processes[1].kind);
    try testing.expectEqual(@as(u64, 0), info.processes[1].run_count);
}

test "live: worker info for a worker the server doesn't know is not found" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    try live.createNamespace();
    var actions = flo.Actions.init(&live.client);
    try testing.expectError(flo.FloError.NotFound, actions.workerInfo("no-such-worker", .{}));
    const last = live.client.lastError().?;
    try testing.expectEqual(@as(u8, 2), last.code);
    try testing.expectEqual(flo.Reason.not_found, last.reason);
}

test "live: the server refuses a registration of more than 1024 processes" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    var actions = flo.Actions.init(&live.client);
    var processes: [1025]flo.ProcessEntry = undefined;
    var names: [1025][8]u8 = undefined;
    for (&processes, &names, 0..) |*p, *n, i| p.* = .{ .name = std.fmt.bufPrint(n, "p{d}", .{i}) catch unreachable };
    try testing.expectError(flo.FloError.BadRequest, actions.register("many-w", null, .{ .processes = &processes }));
    const last = live.client.lastError().?;
    try testing.expectEqual(@as(u8, 3), last.code);
    try testing.expectEqual(flo.Reason.out_of_range, last.reason);
    try testing.expectEqual(flo.Ran.no, last.ran);
    try testing.expectEqualStrings("more than 1024 processes", last.message);
}

test "live: the server refuses a process name or machine id past its limit as too long" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    var actions = flo.Actions.init(&live.client);
    const long_name = [_]u8{'n'} ** 4097;
    try testing.expectError(flo.FloError.BadRequest, actions.register("long-name-w", null, .{ .processes = &.{.{ .name = &long_name }} }));
    var last = live.client.lastError().?;
    try testing.expectEqual(@as(u8, 3), last.code);
    try testing.expectEqual(flo.Reason.field_too_long, last.reason);
    try testing.expectEqual(flo.Ran.no, last.ran);
    try testing.expectEqualStrings("process name longer than 4096 bytes", last.message);

    const long_host = [_]u8{'h'} ** 256;
    try testing.expectError(flo.FloError.BadRequest, actions.register("long-host-w", &.{"job"}, .{ .machine_id = &long_host }));
    last = live.client.lastError().?;
    try testing.expectEqual(@as(u8, 3), last.code);
    try testing.expectEqual(flo.Reason.field_too_long, last.reason);
    try testing.expectEqual(flo.Ran.no, last.ran);
    try testing.expectEqualStrings("machine id longer than 255 bytes", last.message);
}

test "live: kv.history pages a key's versions, newest first, each once" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    var kv = flo.KV.init(&live.client);
    var written: [5]u64 = undefined;
    for (&written, 0..) |*v, i| {
        var buf: [4]u8 = undefined;
        v.* = (try kv.put("paged", std.fmt.bufPrint(&buf, "v{d}", .{i}) catch unreachable, .{})).version;
    }

    var seen: [5]u64 = undefined;
    var n: usize = 0;
    var pages: usize = 0;
    var before: ?u64 = null;
    while (true) {
        var page = try kv.history("paged", .{ .limit = 2, .before_version = before });
        defer page.deinit();
        pages += 1;
        // A page can come back empty; stop rather than ask from nothing.
        if (page.versions.len == 0) break;
        for (page.versions) |v| {
            try testing.expect(n < seen.len);
            seen[n] = v.version;
            n += 1;
        }
        if (!page.more) break;
        before = page.versions[page.versions.len - 1].version;
    }
    try testing.expectEqual(@as(usize, 3), pages);
    try testing.expectEqual(@as(usize, 5), n);
    for (seen, 0..) |v, i| try testing.expectEqual(written[written.len - 1 - i], v);

    var past = try kv.history("paged", .{ .before_version = written[0] });
    defer past.deinit();
    try testing.expectEqual(@as(usize, 0), past.versions.len);
    try testing.expect(!past.more);
}

test "live: worker.list with an action lists only the workers that run it" {
    const ep = try endpoint();
    var ns_buf: [32]u8 = undefined;
    const namespace = freshNamespace(&ns_buf);
    var client = flo.Client.init(testing.allocator, ep, .{ .namespace = namespace, .timeout_ms = 10_000 });
    defer client.deinit();
    try client.connect();
    var actions = flo.Actions.init(&client);
    try actions.register("fw-1", &.{"send"}, .{});
    try actions.register("fw-2", &.{"bill"}, .{});
    try actions.register("fw-3", &.{ "bill", "send" }, .{});

    var send = try actions.listWorkers(.{ .action = "send" });
    defer send.deinit();
    try testing.expectEqual(@as(usize, 2), send.workers.len);
    try testing.expectEqualStrings("fw-1", send.workers[0].id);
    try testing.expectEqualStrings("fw-3", send.workers[1].id);
    var all = try actions.listWorkers(.{});
    defer all.deinit();
    try testing.expectEqual(@as(usize, 3), all.workers.len);
}

/// The `{code, name}` list `field` names in ops.json, as it holds it.
fn expectSameNames(comptime E: type, ops: std.json.Value, field: []const u8) !void {
    const list = (ops.object.get(field) orelse return error.NoSuchList).array.items;
    const fields = @typeInfo(E).@"enum".fields;
    try testing.expectEqual(list.len, fields.len);
    next: for (list) |entry| {
        const code = entry.object.get("code").?.integer;
        const name = entry.object.get("name").?.string;
        inline for (fields) |f| {
            if (f.value == code) {
                if (std.mem.eql(u8, f.name, name)) continue :next;
                break;
            }
        }
        std.debug.print("{s}: the server's {s} {d} is {s}; this SDK has no such value\n", .{ @typeName(E), field, code, name });
        return error.Drift;
    }
}

test "status codes and refusal reasons are the server's" {
    // FLO_OPS_JSON is flo's `zig build gen` output for the pinned commit.
    const path = env("FLO_OPS_JSON") orelse {
        if (env("CI") != null) return error.NoOpsJsonInCI;
        return error.SkipZigTest;
    };
    const text = try std.fs.cwd().readFileAlloc(testing.allocator, path, 16 * 1024 * 1024);
    defer testing.allocator.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try expectSameNames(flo.StatusCode, parsed.value, "statuses");
    try expectSameNames(flo.Reason, parsed.value, "reasons");
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
    try live.createNamespace();
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

/// Names collected across a list's pages, each with how often it came back.
const Seen = struct {
    counts: std.StringHashMap(u32),

    fn init() Seen {
        return .{ .counts = std.StringHashMap(u32).init(testing.allocator) };
    }

    fn deinit(self: *Seen) void {
        var it = self.counts.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        self.counts.deinit();
    }

    fn add(self: *Seen, name: []const u8) !void {
        if (self.counts.getPtr(name)) |c| {
            c.* += 1;
            return;
        }
        try self.counts.put(try testing.allocator.dupe(u8, name), 1);
    }

    /// Exactly `prefix` 00..`n`-1, each once, and nothing else.
    fn expectExactly(self: *const Seen, comptime prefix: []const u8, n: usize) !void {
        var it = self.counts.iterator();
        while (it.next()) |e| if (e.value_ptr.* != 1 or !std.mem.startsWith(u8, e.key_ptr.*, prefix)) {
            std.debug.print("{s} came back {d} times\n", .{ e.key_ptr.*, e.value_ptr.* });
            return error.WrongNames;
        };
        for (0..n) |i| {
            var buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&buf, prefix ++ "{d:0>2}", .{i}) catch unreachable;
            if (!self.counts.contains(name)) {
                std.debug.print("{s} never came back\n", .{name});
                return error.WrongNames;
            }
        }
        try testing.expectEqual(n, self.counts.count());
    }
};

/// Holds the cursor a page returned past that page's deinit.
const Cursor = struct {
    buf: ?[]u8 = null,

    fn set(self: *Cursor, next: []const u8) !void {
        self.deinit();
        self.buf = try testing.allocator.dupe(u8, next);
    }

    fn get(self: *const Cursor) ?[]const u8 {
        return self.buf;
    }

    fn deinit(self: *Cursor) void {
        if (self.buf) |b| testing.allocator.free(b);
        self.buf = null;
    }
};

const PAGE = 3;

fn nameOf(buf: []u8, comptime prefix: []const u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "{d:0>2}", .{i}) catch unreachable;
}

// On a server of many shards a page holds names from a few at a time, so a
// page can be short with more to come: each pager below stops on the
// cursor or has_more alone.
test "live: kv.scan pages every key back exactly once" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    var kv = flo.KV.init(&live.client);
    const n = 40;
    for (0..n) |i| {
        var buf: [16]u8 = undefined;
        _ = try kv.put(nameOf(&buf, "scan-", i), "x", .{});
    }

    var seen = Seen.init();
    defer seen.deinit();
    var cursor: Cursor = .{};
    defer cursor.deinit();
    var pages: usize = 0;
    while (true) {
        pages += 1;
        try testing.expect(pages <= 2 * n); // the cursor moves on
        var page = try kv.scan("", .{ .limit = PAGE, .cursor = cursor.get() });
        defer page.deinit();
        try testing.expect(page.keys.len <= PAGE);
        for (page.keys) |k| try seen.add(k);
        try cursor.set(page.cursor orelse break);
    }
    try testing.expect(pages >= n / PAGE);
    try seen.expectExactly("scan-", n);
}

test "live: listActions pages every action back exactly once" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    var actions = flo.Actions.init(&live.client);
    const n = 30;
    for (0..n) |i| {
        var buf: [16]u8 = undefined;
        try actions.registerAction(nameOf(&buf, "act-", i), .user, .{});
    }

    var seen = Seen.init();
    defer seen.deinit();
    var cursor: Cursor = .{};
    defer cursor.deinit();
    var pages: usize = 0;
    while (true) {
        pages += 1;
        try testing.expect(pages <= 2 * n);
        var page = try actions.listActions(.{ .limit = PAGE, .cursor = cursor.get() });
        defer page.deinit();
        try testing.expect(page.names.len <= PAGE);
        for (page.names) |name| try seen.add(name);
        if (!page.has_more) break;
        try cursor.set(page.cursor orelse return error.MoreWithoutCursor);
    }
    try testing.expect(pages >= n / PAGE);
    try seen.expectExactly("act-", n);
}

test "live: workflow listDefinitions pages every definition back exactly once" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    var workflow = flo.Workflow.init(&live.client);
    const n = 30;
    for (0..n) |i| {
        var name_buf: [16]u8 = undefined;
        const name = nameOf(&name_buf, "wf-", i);
        var yaml_buf: [256]u8 = undefined;
        const yaml = try std.fmt.bufPrint(&yaml_buf,
            \\kind: Workflow
            \\name: {s}
            \\version: 1.0.0
            \\start:
            \\  run: "@actions/zig-runs-unserved"
            \\  transitions:
            \\    success: flo.Completed
            \\    failure: flo.Failed
            \\
        , .{name});
        try workflow.create(name, yaml, .{});
    }

    var seen = Seen.init();
    defer seen.deinit();
    var cursor: Cursor = .{};
    defer cursor.deinit();
    var pages: usize = 0;
    while (true) {
        pages += 1;
        try testing.expect(pages <= 2 * n);
        var page = try workflow.listDefinitions(testing.allocator, .{ .limit = PAGE, .cursor = cursor.get() });
        defer page.deinit();
        try testing.expect(page.definitions.len <= PAGE);
        for (page.definitions) |e| try seen.add(e.name);
        if (!page.has_more) break;
        try cursor.set(page.cursor orelse return error.MoreWithoutCursor);
    }
    try testing.expect(pages >= n / PAGE);
    try seen.expectExactly("wf-", n);
}

test "live: processing list pages every job back exactly once" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    var processing = flo.Processing.init(&live.client);
    // A kv sink: outside the default namespace, a many-shard server refuses
    // a stream or queue sink that isn't on the job's shard.
    const n = 20;
    for (0..n) |i| {
        var name_buf: [16]u8 = undefined;
        const name = nameOf(&name_buf, "job-", i);
        var yaml_buf: [256]u8 = undefined;
        const yaml = try std.fmt.bufPrint(&yaml_buf,
            \\kind: Processing
            \\name: {s}
            \\sources:
            \\  - stream:
            \\      name: {s}-in
            \\sinks:
            \\  - kv:
            \\      key_prefix: {s}-out
            \\
        , .{ name, name, name });
        const job_id = processing.submit(testing.allocator, yaml, .{}) catch |err| {
            if (live.client.lastError()) |last| std.debug.print("submit: {s}\n", .{last.message});
            return err;
        };
        testing.allocator.free(job_id);
    }

    var seen = Seen.init();
    defer seen.deinit();
    var cursor: Cursor = .{};
    defer cursor.deinit();
    var pages: usize = 0;
    while (true) {
        pages += 1;
        try testing.expect(pages <= 2 * n);
        var page = try processing.list(testing.allocator, .{ .limit = PAGE, .cursor = cursor.get() });
        defer page.deinit();
        try testing.expect(page.jobs.len <= PAGE);
        for (page.jobs) |e| try seen.add(e.name);
        if (!page.has_more) break;
        try cursor.set(page.cursor orelse return error.MoreWithoutCursor);
    }
    try testing.expect(pages >= n / PAGE);
    try seen.expectExactly("job-", n);
}

/// Creates a workflow whose runs wait for a signal no test sends, so they
/// stay open for signals and cancels. (A run of an action no one registered
/// can fail at once, when the action would be on the run's own shard.)
fn createWaitingWorkflow(workflow: *flo.Workflow, name: []const u8) !void {
    var yaml_buf: [512]u8 = undefined;
    const yaml = try std.fmt.bufPrint(&yaml_buf,
        \\kind: Workflow
        \\name: {s}
        \\version: 1.0.0
        \\terminals:
        \\  Approved:
        \\    status: completed
        \\  Rejected:
        \\    status: failed
        \\start:
        \\  wait_for_signal:
        \\    type: never-sent
        \\    timeout_ms: 600000
        \\  transitions:
        \\    success: Approved
        \\    timeout: Rejected
        \\
    , .{name});
    try workflow.create(name, yaml, .{});
}

/// A run listRuns returned, owned.
const ListedRun = struct { run_id: []u8, workflow: []u8, created_at: i64 };

/// Every run listRuns pages back for `workflow_name` (null for all), in
/// the order the pages gave them; checks each page's limit and the order.
fn listAllRuns(workflow: *flo.Workflow, workflow_name: ?[]const u8, out: *std.ArrayList(ListedRun)) !void {
    var cursor: Cursor = .{};
    defer cursor.deinit();
    var pages: usize = 0;
    while (true) {
        pages += 1;
        try testing.expect(pages <= 100);
        var page = try workflow.listRuns(testing.allocator, .{ .workflow_name = workflow_name, .limit = PAGE, .cursor = cursor.get() });
        defer page.deinit();
        try testing.expect(page.runs.len <= PAGE);
        for (page.runs) |r| {
            const run_id = try testing.allocator.dupe(u8, r.run_id);
            errdefer testing.allocator.free(run_id);
            const name = try testing.allocator.dupe(u8, r.workflow);
            errdefer testing.allocator.free(name);
            try out.append(testing.allocator, .{ .run_id = run_id, .workflow = name, .created_at = r.created_at });
        }
        if (!page.has_more) break;
        try cursor.set(page.cursor orelse return error.MoreWithoutCursor);
    }
    // Newest first, then by id: strictly, so no run came back twice.
    for (out.items[0..out.items.len -| 1], out.items[@min(1, out.items.len)..]) |a, b| {
        const ordered = a.created_at > b.created_at or (a.created_at == b.created_at and std.mem.lessThan(u8, a.run_id, b.run_id));
        if (!ordered) {
            std.debug.print("{s}@{d} came before {s}@{d}\n", .{ a.run_id, a.created_at, b.run_id, b.created_at });
            return error.OutOfOrder;
        }
    }
}

fn freeRuns(runs: *std.ArrayList(ListedRun)) void {
    for (runs.items) |r| {
        testing.allocator.free(r.run_id);
        testing.allocator.free(r.workflow);
    }
    runs.deinit(testing.allocator);
}

test "live: workflow listRuns pages every run back exactly once, newest first" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    var workflow = flo.Workflow.init(&live.client);
    const names = [_][]const u8{ "runs-a", "runs-b", "runs-c", "runs-d" };
    const per = 4;
    var started: [names.len * per][]u8 = undefined;
    var n: usize = 0;
    defer for (started[0..n]) |id| testing.allocator.free(id);
    for (names) |name| try createWaitingWorkflow(&workflow, name);
    for (0..per) |_| for (names) |name| {
        started[n] = try workflow.start(testing.allocator, name, "{}", .{});
        n += 1;
    };

    // Every workflow's runs.
    var all: std.ArrayList(ListedRun) = .empty;
    defer freeRuns(&all);
    try listAllRuns(&workflow, null, &all);
    try testing.expectEqual(started.len, all.items.len);
    for (started, 0..) |id, i| {
        const listed = for (all.items) |r| {
            if (std.mem.eql(u8, r.run_id, id)) break r;
        } else {
            std.debug.print("run {s} never came back\n", .{id});
            return error.MissingRun;
        };
        try testing.expectEqualStrings(names[i % names.len], listed.workflow);
    }

    // One workflow's runs: exactly the ones it started.
    var one: std.ArrayList(ListedRun) = .empty;
    defer freeRuns(&one);
    try listAllRuns(&workflow, "runs-b", &one);
    try testing.expectEqual(@as(usize, per), one.items.len);
    for (one.items) |r| try testing.expectEqualStrings("runs-b", r.workflow);
    for (started, 0..) |id, i| if (i % names.len == 1) {
        for (one.items) |r| {
            if (std.mem.eql(u8, r.run_id, id)) break;
        } else return error.MissingRun;
    };
}

test "live: a run started with a client-chosen id is found by that id, and a later start of the id on another workflow is refused" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    var workflow = flo.Workflow.init(&live.client);
    const others = [_][]const u8{ "chosen-b", "chosen-c", "chosen-d", "chosen-e", "chosen-f", "chosen-g" };
    try createWaitingWorkflow(&workflow, "chosen-a");
    for (others) |name| try createWaitingWorkflow(&workflow, name);

    var uuid_buf: [36]u8 = undefined;
    var raw: [16]u8 = undefined;
    std.crypto.random.bytes(&raw);
    const uuid = std.fmt.bufPrint(&uuid_buf, "{x}-{x}-{x}-{x}-{x}", .{ raw[0..4], raw[4..6], raw[6..8], raw[8..10], raw[10..16] }) catch unreachable;

    for ([_][]const u8{ "order-123", "run-1", uuid }) |id| {
        const got = try workflow.start(testing.allocator, "chosen-a", "{}", .{ .run_id = id });
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(id, got);

        const st = try workflow.status(testing.allocator, id, .{});
        defer st.deinit(testing.allocator);
        try testing.expectEqualStrings(id, st.run_id);
        try testing.expectEqualStrings("chosen-a", st.workflow);

        const hist = try workflow.history(testing.allocator, id, .{});
        testing.allocator.free(hist);

        try workflow.signal(id, "nudge", "{}", .{});

        // The id is this run's on any workflow, whichever shard holds it.
        for (others) |name| {
            try testing.expectError(flo.FloError.Conflict, workflow.start(testing.allocator, name, "{}", .{ .run_id = id }));
        }

        try workflow.cancel(id, "done", .{});
        const after = try workflow.status(testing.allocator, id, .{});
        defer after.deinit(testing.allocator);
        try testing.expectEqualStrings("cancelled", after.status);
        try testing.expectEqualStrings("chosen-a", after.workflow);
    }
}

test "live: stream info of a stream that doesn't exist is not found" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    var stream = flo.Stream.init(&live.client);
    // The namespace exists, the stream doesn't.
    _ = try stream.append("present", "x", .{});
    try testing.expectError(flo.FloError.NotFound, stream.info("absent", .{}));
    const info = try stream.info("present", .{});
    try testing.expectEqual(@as(u64, 1), info.count);
}

test "live: a read in a namespace never created is no_namespace" {
    var live: Live = .{ .client = undefined };
    try live.init();
    defer live.deinit();
    var kv = flo.KV.init(&live.client);
    try testing.expectError(flo.FloError.NoNamespace, kv.get("k", .{}));
    try testing.expectError(flo.FloError.NoNamespace, kv.scan("", .{}));
    // A write creates it; the read then finds no key.
    _ = try kv.put("other", "x", .{});
    try testing.expect((try kv.get("k", .{})) == null);
}
