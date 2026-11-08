//! Flo Processing Operations
//!
//! Stream processing job management: submit, status, list, stop, cancel, remove.
//!
//! ## Example
//!
//! ```zig
//! const flo = @import("flo");
//!
//! var client = flo.Client.init(allocator, "localhost:9000", .{});
//! try client.connect();
//! defer client.deinit();
//!
//! var processing = flo.Processing.init(&client);
//!
//! // Submit a processing job from YAML
//! const job_id = try processing.submit(allocator, yaml_bytes, .{});
//! defer allocator.free(job_id);
//!
//! // Get status
//! var status = try processing.status(allocator, job_id, .{});
//! defer status.deinit();
//! ```

const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");
const Client = @import("client.zig").Client;
const Reader = @import("kv.zig").Reader;

const FloError = types.FloError;
const Allocator = std.mem.Allocator;

const processing_status_names = [_][]const u8{
    "running", "stopped", "cancelled", "failed", "completed",
};

/// Processing operations for the Flo client.
pub const Processing = struct {
    client: *Client,

    const Self = @This();

    pub fn init(client: *Client) Processing {
        return .{ .client = client };
    }

    // =========================================================================
    // Core Operations
    // =========================================================================

    /// Submit a processing job from a YAML definition.
    /// Returns the server-assigned job ID (caller owns the slice).
    pub fn submit(
        self: *Self,
        allocator: Allocator,
        yaml: []const u8,
        options: types.ProcessingSubmitOptions,
    ) FloError![]u8 {
        const ns = self.client.getNamespace(options.namespace);

        var response = try self.client.sendRequest(
            .processing_submit,
            ns,
            "",
            yaml,
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }

        return allocator.dupe(u8, response.data) catch return FloError.OutOfMemory;
    }

    /// Get the status of a processing job.
    /// Caller owns the result; call deinit() when done.
    pub fn status(
        self: *Self,
        allocator: Allocator,
        job_id: []const u8,
        options: types.ProcessingStatusOptions,
    ) FloError!types.ProcessingStatusResult {
        const ns = self.client.getNamespace(options.namespace);

        var response = try self.client.sendRequest(
            .processing_status,
            ns,
            job_id,
            "",
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }

        return parseProcessingStatus(allocator, response.data) catch |err| answerError(err);
    }

    /// List one page of processing jobs, from `options.cursor`. Pass the
    /// page's cursor to get the next; stop when `has_more` is clear, not on a
    /// short page.
    /// Caller owns the result; call deinit() when done.
    pub fn list(
        self: *Self,
        allocator: Allocator,
        options: types.ProcessingListOptions,
    ) FloError!types.ProcessingListResult {
        const ns = self.client.getNamespace(options.namespace);

        const value = try wire.encodeListValue(self.client.allocator, options.limit, options.cursor orelse "");
        defer self.client.allocator.free(value);

        var response = try self.client.sendRequest(
            .processing_list,
            ns,
            "",
            value,
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }

        return parseProcessingList(allocator, response.data) catch |err| answerError(err);
    }

    /// Gracefully stop a processing job.
    pub fn stop(
        self: *Self,
        job_id: []const u8,
        options: types.ProcessingStopOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var response = try self.client.sendRequest(
            .processing_stop,
            ns,
            job_id,
            "",
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }
    }

    /// Remove a stopped, cancelled or failed job, freeing its slot. A
    /// running job is refused (reason job_running): stop or cancel it first.
    pub fn remove(
        self: *Self,
        job_id: []const u8,
        options: types.ProcessingRemoveOptions,
    ) FloError!void {
        // A table op with no request fields and an empty answer.
        var response = try self.client.sendRequest(.processing_remove, self.client.getNamespace(options.namespace), job_id, "", "");
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        if (response.data.len != 0) return FloError.IncompleteResponse;
    }

    /// Force-cancel a processing job.
    pub fn cancel(
        self: *Self,
        job_id: []const u8,
        options: types.ProcessingCancelOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var response = try self.client.sendRequest(
            .processing_cancel,
            ns,
            job_id,
            "",
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }
    }

    // =========================================================================
    // Declarative Sync
    // =========================================================================

    /// Sync a processing job from raw YAML bytes.
    /// Each sync submits a new job instance and returns the server-assigned job ID.
    /// Caller owns the result; call deinit() when done.
    pub fn syncBytes(
        self: *Self,
        allocator: Allocator,
        yaml: []const u8,
        options: types.ProcessingSyncOptions,
    ) FloError!types.ProcessingSyncResult {
        const name = extractYamlName(yaml) orelse return FloError.BadRequest;

        const job_id = try self.submit(allocator, yaml, .{ .namespace = options.namespace });
        errdefer allocator.free(job_id);

        const name_owned = allocator.dupe(u8, name) catch return FloError.OutOfMemory;

        return .{
            .name = name_owned,
            .job_id = job_id,
            .allocator = allocator,
        };
    }
};

// =============================================================================
// Wire Format Parsers
// =============================================================================

/// processing.status' answer:
///   [job_id_len:u16][job_id][name_len:u16][name][status:u8]
///   [batch_size:u32][records_processed:u64][created_at:i64]
///   [reason_len:u16][reason]
///   [running:u8][records_in:u64][records_out:u64][watermark_ms:i64]
///   [tick_avg_us:u64][tick_max_us:u64][uptime_ms:u64]
///   [yaml_len:u32][yaml]
fn parseProcessingStatus(allocator: Allocator, data: []const u8) !types.ProcessingStatusResult {
    var r: Reader = .{ .data = data };
    const job_id = try r.lenBytes(u16);
    const name = try r.lenBytes(u16);
    const status_byte = try r.int(u8);
    if (status_byte >= processing_status_names.len) return error.UnknownJobStatus;
    const batch_size = try r.int(u32);
    const records_processed = try r.int(u64);
    const created_at = try r.int(i64);
    const reason = try r.lenBytes(u16);
    const running = try r.boolean();
    const records_in = try r.int(u64);
    const records_out = try r.int(u64);
    const watermark_ms = try r.int(i64);
    const tick_avg_us = try r.int(u64);
    const tick_max_us = try r.int(u64);
    const uptime_ms = try r.int(u64);
    const yaml = try r.lenBytes(u32);
    try r.end();

    const job_id_copy = try allocator.dupe(u8, job_id);
    errdefer allocator.free(job_id_copy);
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);
    const status_copy = try allocator.dupe(u8, processing_status_names[status_byte]);
    errdefer allocator.free(status_copy);
    const reason_copy = if (reason.len == 0) null else try allocator.dupe(u8, reason);
    errdefer if (reason_copy) |c| allocator.free(c);
    return .{
        .job_id = job_id_copy,
        .name = name_copy,
        .status = status_copy,
        .batch_size = batch_size,
        .records_processed = records_processed,
        .created_at = created_at,
        .reason = reason_copy,
        .running = running,
        .records_in = records_in,
        .records_out = records_out,
        .watermark_ms = watermark_ms,
        .tick_avg_us = tick_avg_us,
        .tick_max_us = tick_max_us,
        .uptime_ms = uptime_ms,
        .yaml = try allocator.dupe(u8, yaml),
        .allocator = allocator,
    };
}

/// A list entry's smallest encoding: empty strings.
const min_list_entry = 2 + 2 + 2 + 8 + 4 + 8;

/// processing.list's answer:
///   [count:u32]([name_len:u16][name][job_id_len:u16][job_id]
///   [status_len:u16][status][created_at:i64][batch_size:u32][records_processed:u64])*
///   [has_more:u8][cursor_len:u16][cursor]
fn parseProcessingList(allocator: Allocator, data: []const u8) !types.ProcessingListResult {
    var r: Reader = .{ .data = data };
    const count = try r.int(u32);
    // A count the data can't hold is refused before it sizes an allocation.
    if (count > r.remaining() / min_list_entry) return FloError.IncompleteResponse;

    var entries = try allocator.alloc(types.ProcessingListEntry, count);
    var i: u32 = 0;
    errdefer {
        for (entries[0..i]) |*e| e.deinit(allocator);
        allocator.free(entries);
    }
    while (i < count) : (i += 1) {
        const name = try r.lenBytes(u16);
        const job_id = try r.lenBytes(u16);
        const status = try r.lenBytes(u16);
        const created_at = try r.int(i64);
        const batch_size = try r.int(u32);
        const records_processed = try r.int(u64);
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const job_id_copy = try allocator.dupe(u8, job_id);
        errdefer allocator.free(job_id_copy);
        entries[i] = .{
            .name = name_copy,
            .job_id = job_id_copy,
            .status = try allocator.dupe(u8, status),
            .created_at = created_at,
            .batch_size = batch_size,
            .records_processed = records_processed,
        };
    }

    const trailer = try wire.parseListTrailer(data, r.pos);
    return .{
        .jobs = entries,
        .has_more = trailer.has_more,
        .cursor = if (trailer.cursor) |c| try allocator.dupe(u8, c) else null,
        .allocator = allocator,
    };
}

/// Extract the "name:" field from YAML content (simple line-based extraction).
fn extractYamlName(data: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (start < data.len) {
        // Find end of line
        var end = start;
        while (end < data.len and data[end] != '\n') : (end += 1) {}

        const line = data[start..end];

        // Look for "name:" at start of line (possibly with leading spaces)
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "name:")) {
            const after_colon = trimmed[5..];
            const value = std.mem.trim(u8, after_colon, " \t\r\"'");
            if (value.len > 0) return value;
        }

        start = if (end < data.len) end + 1 else end;
    }
    return null;
}

/// A parse failure: out of memory stays itself, anything else is an answer
/// this client can't read.
fn answerError(err: anyerror) FloError {
    return if (err == error.OutOfMemory) FloError.OutOfMemory else FloError.UnexpectedResponse;
}

// =============================================================================
// Tests
// =============================================================================

test "extractYamlName" {
    try std.testing.expectEqualStrings("my-job", extractYamlName("name: my-job\ntype: stream").?);
    try std.testing.expectEqualStrings("quoted", extractYamlName("name: \"quoted\"\n").?);
    try std.testing.expectEqualStrings("test", extractYamlName("  name: test").?);
    try std.testing.expect(extractYamlName("type: stream\nversion: 1") == null);
}

test "list sends [limit][cursor] in the value and returns the next cursor" {
    // No jobs, then has_more=1 and a 2-byte cursor.
    const body = [_]u8{ 0, 0, 0, 0, 1, 2, 0, 'c', '2' };
    var srv = try @import("test_server.zig").OkServer.listen();
    srv.body = &body;
    try srv.start();
    defer srv.deinit();

    var client = Client.init(std.testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var processing = Processing.init(&client);

    var result = try processing.list(std.testing.allocator, .{ .limit = 5, .cursor = "c1" });
    defer result.deinit();

    try std.testing.expectEqualSlices(u8, &[_]u8{ 5, 0, 0, 0, 'c', '1' }, srv.lastValue());
    try std.testing.expectEqual(@as(usize, 0), result.jobs.len);
    try std.testing.expect(result.has_more);
    try std.testing.expectEqualStrings("c2", result.cursor.?);
}

const le = std.mem.toBytes;

/// A list entry: name "p", job_id "j1", status "running", created_at 7,
/// batch_size 50, records 1234.
const test_list_entry = "\x01\x00p" ++ "\x02\x00j1" ++ "\x07\x00running" ++ le(@as(i64, 7)) ++ le(@as(u32, 50)) ++ le(@as(u64, 1234));

test "list pages on past a short page until has_more is clear, sending each page's cursor" {
    const a = std.testing.allocator;
    var srv = try @import("test_server.zig").OkServer.listen();
    srv.replies = &.{
        // One job, fewer than the limit, yet has_more=1 and the cursor "c9".
        .{ .status = 0, .body = "\x01\x00\x00\x00" ++ test_list_entry ++ "\x01\x02\x00c9" },
        // The last page: no jobs, nothing more.
        .{ .status = 0, .body = &.{ 0, 0, 0, 0, 0, 0, 0 } },
    };
    try srv.start();
    defer srv.deinit();
    var client = Client.init(a, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var processing = Processing.init(&client);

    var page = try processing.list(a, .{ .limit = 5 });
    defer page.deinit();
    try std.testing.expectEqual(@as(u16, @intFromEnum(types.OpCode.processing_list)), srv.last_op);
    try std.testing.expectEqualSlices(u8, &.{ 5, 0, 0, 0 }, srv.lastValue());
    try std.testing.expectEqual(@as(usize, 1), page.jobs.len);
    try std.testing.expect(page.has_more);
    try std.testing.expectEqualStrings("c9", page.cursor.?);

    var last = try processing.list(a, .{ .limit = 5, .cursor = page.cursor });
    defer last.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 5, 0, 0, 0, 'c', '9' }, srv.lastValue());
    try std.testing.expectEqual(@as(usize, 0), last.jobs.len);
    try std.testing.expect(!last.has_more);
    try std.testing.expect(last.cursor == null);
}

/// The runtime and definition every status answer ends with: running, 10
/// in, 8 out, watermark 5, ticks 3 and 9 us, up 60 ms; yaml "y: 1".
const test_status_tail = "\x01" ++ le(@as(u64, 10)) ++ le(@as(u64, 8)) ++ le(@as(i64, 5)) ++ le(@as(u64, 3)) ++ le(@as(u64, 9)) ++ le(@as(u64, 60)) ++ le(@as(u32, 4)) ++ "y: 1";

test "status and list answers decode per the server's layouts" {
    const a = std.testing.allocator;
    // job_id "j1", name "p", status 1 (stopped), batch_size 50, records 1234, created_at 99, no reason
    const status_body = "\x02\x00j1\x01\x00p\x01" ++ le(@as(u32, 50)) ++ le(@as(u64, 1234)) ++ le(@as(i64, 99)) ++ "\x00\x00" ++ test_status_tail;
    var st = try parseProcessingStatus(a, status_body);
    defer st.deinit();
    try std.testing.expectEqualStrings("j1", st.job_id);
    try std.testing.expectEqualStrings("p", st.name);
    try std.testing.expectEqualStrings("stopped", st.status);
    try std.testing.expectEqual(@as(u32, 50), st.batch_size);
    try std.testing.expectEqual(@as(u64, 1234), st.records_processed);
    try std.testing.expectEqual(@as(i64, 99), st.created_at);
    try std.testing.expectEqual(@as(?[]const u8, null), st.reason);
    try std.testing.expect(st.running);
    try std.testing.expectEqual(@as(u64, 10), st.records_in);
    try std.testing.expectEqual(@as(u64, 8), st.records_out);
    try std.testing.expectEqual(@as(i64, 5), st.watermark_ms);
    try std.testing.expectEqual(@as(u64, 3), st.tick_avg_us);
    try std.testing.expectEqual(@as(u64, 9), st.tick_max_us);
    try std.testing.expectEqual(@as(u64, 60), st.uptime_ms);
    try std.testing.expectEqualStrings("y: 1", st.yaml);

    const list_body = "\x01\x00\x00\x00" ++ test_list_entry ++ "\x00\x00\x00";
    var list = try parseProcessingList(a, list_body);
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 1), list.jobs.len);
    try std.testing.expectEqualStrings("p", list.jobs[0].name);
    try std.testing.expectEqualStrings("j1", list.jobs[0].job_id);
    try std.testing.expectEqualStrings("running", list.jobs[0].status);
    try std.testing.expectEqual(@as(i64, 7), list.jobs[0].created_at);
    try std.testing.expectEqual(@as(u32, 50), list.jobs[0].batch_size);
    try std.testing.expectEqual(@as(u64, 1234), list.jobs[0].records_processed);
    try std.testing.expect(!list.has_more);
    for (0..list_body.len) |n| try std.testing.expectError(FloError.IncompleteResponse, parseProcessingList(a, list_body[0..n]));
}

test "a jobs page whose cursor contradicts has_more is refused" {
    const a = std.testing.allocator;
    // No jobs; has_more=0 with a cursor, then has_more=1 without one.
    try std.testing.expectError(error.UnexpectedResponse, parseProcessingList(a, &.{ 0, 0, 0, 0, 0, 1, 0, 'c' }));
    try std.testing.expectError(error.UnexpectedResponse, parseProcessingList(a, &.{ 0, 0, 0, 0, 1, 0, 0 }));
}

// job_id "j1", name "p", status 3 (failed), batch_size 50, records 1234, created_at 99, reason "boom"
const failed_status_answer = "\x02\x00j1\x01\x00p\x03" ++ "\x32\x00\x00\x00" ++
    "\xd2\x04\x00\x00\x00\x00\x00\x00" ++ "\x63\x00\x00\x00\x00\x00\x00\x00" ++ "\x04\x00boom" ++ test_status_tail;

test "a failed job's status carries its reason" {
    var st = try parseProcessingStatus(std.testing.allocator, failed_status_answer);
    defer st.deinit();
    try std.testing.expectEqualStrings("failed", st.status);
    try std.testing.expectEqual(@as(u64, 1234), st.records_processed);
    try std.testing.expectEqualStrings("boom", st.reason.?);
}

fn parseStatusAndFree(a: Allocator, data: []const u8) !void {
    var st = try parseProcessingStatus(a, data);
    st.deinit();
}

test "a status answer cut anywhere, overlong, or short of memory leaks nothing" {
    const a = std.testing.allocator;
    // Every prefix, including one whose reason length runs past the end.
    for (0..failed_status_answer.len) |n| try std.testing.expectError(FloError.IncompleteResponse, parseStatusAndFree(a, failed_status_answer[0..n]));
    try std.testing.expectError(FloError.IncompleteResponse, parseStatusAndFree(a, failed_status_answer ++ "\x00"));
    try std.testing.checkAllAllocationFailures(a, parseStatusAndFree, .{@as([]const u8, failed_status_answer)});
}

test "a job status byte this client doesn't know refuses the answer" {
    var answer = failed_status_answer.*;
    answer[7] = 5;
    try std.testing.expectError(error.UnknownJobStatus, parseStatusAndFree(std.testing.allocator, &answer));
}

test "remove sends the job id as the key and no body" {
    var srv = try @import("test_server.zig").OkServer.listen();
    try srv.start();
    defer srv.deinit();
    var client = Client.init(std.testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var processing = Processing.init(&client);
    try processing.remove("j1", .{});
    try std.testing.expectEqual(@as(u16, 0x365), srv.last_op);
    try std.testing.expectEqualStrings("j1", srv.lastKey());
    try std.testing.expectEqualStrings("", srv.lastBody());
}

test "status and list short of memory say so, not that the answer is bad" {
    const list_body = "\x01\x00\x00\x00" ++ test_list_entry ++ "\x00\x00\x00";
    var srv = try @import("test_server.zig").OkServer.listen();
    srv.replies = &.{
        .{ .status = 0, .body = failed_status_answer },
        .{ .status = 0, .body = list_body },
    };
    try srv.start();
    defer srv.deinit();

    var client = Client.init(std.testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var processing = Processing.init(&client);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(FloError.OutOfMemory, processing.status(failing.allocator(), "j1", .{}));
    try std.testing.expectError(FloError.OutOfMemory, processing.list(failing.allocator(), .{}));
}
