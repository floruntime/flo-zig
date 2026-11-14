//! Flo Stream Operations
//!
//! Append-only log streams with consumer groups.

const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");
const Client = @import("client.zig").Client;

const FloError = types.FloError;

/// Stream operations
pub const Stream = struct {
    client: *Client,

    const Self = @This();

    pub fn init(client: *Client) Stream {
        return .{ .client = client };
    }

    /// Append a record to a stream.
    /// Returns the append result with sequence numbers.
    pub fn append(
        self: *Stream,
        stream_name: []const u8,
        payload: []const u8,
        options: types.StreamAppendOptions,
    ) FloError!types.StreamAppendResult {
        const ns = self.client.getNamespace(options.namespace);
        const value = try encodeAppendValue(self.client.allocator, payload, options.headers);
        defer self.client.allocator.free(value);

        var response = try self.client.sendRequest(
            .stream_append,
            ns,
            stream_name,
            value,
            "", // options
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }

        // Parse response: [sequence:u64][timestamp_ms:i64]
        if (response.data.len < 16) {
            return FloError.IncompleteResponse;
        }

        return types.StreamAppendResult{
            .id = .{
                .sequence = std.mem.readInt(u64, response.data[0..8], .little),
                .timestamp_ms = std.mem.readInt(u64, response.data[8..16], .little),
            },
        };
    }

    /// An append's value: the record as a batch of one, the form the server
    /// reads: [count:u32][len:u32][payload][hdr_count:u16]
    /// ([key_len:u16][key][val_len:u16][val])*.
    pub fn encodeAppendValue(allocator: std.mem.Allocator, payload: []const u8, headers: []const types.Header) FloError![]u8 {
        if (headers.len > std.math.maxInt(u16)) return FloError.ValueTooLarge;
        if (payload.len > std.math.maxInt(u32)) return FloError.ValueTooLarge;
        var size: usize = 4 + 4 + payload.len + 2;
        for (headers) |h| {
            if (h.key.len > std.math.maxInt(u16) or h.value.len > std.math.maxInt(u16)) return FloError.ValueTooLarge;
            size += 2 + h.key.len + 2 + h.value.len;
        }
        const buf = allocator.alloc(u8, size) catch return FloError.OutOfMemory;
        var pos: usize = 0;
        std.mem.writeInt(u32, buf[pos..][0..4], 1, .little);
        pos += 4;
        std.mem.writeInt(u32, buf[pos..][0..4], @intCast(payload.len), .little);
        pos += 4;
        @memcpy(buf[pos..][0..payload.len], payload);
        pos += payload.len;
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(headers.len), .little);
        pos += 2;
        for (headers) |h| {
            for ([_][]const u8{ h.key, h.value }) |part| {
                std.mem.writeInt(u16, buf[pos..][0..2], @intCast(part.len), .little);
                pos += 2;
                @memcpy(buf[pos..][0..part.len], part);
                pos += part.len;
            }
        }
        std.debug.assert(pos == size);
        return buf;
    }

    /// Read records from a stream.
    /// **Caller owns the returned `StreamReadResult` and must call `result.deinit()`.**
    pub fn read(
        self: *Stream,
        stream_name: []const u8,
        options: types.StreamReadOptions,
    ) FloError!types.StreamReadResult {
        const ns = self.client.getNamespace(options.namespace);

        var opts_buf: [64]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);

        // Read records after this StreamID (exclusive)
        if (options.start) |start| {
            const bytes = start.toBytes();
            try builder.addBytes(.stream_start, &bytes);
        }

        // End StreamID for reads (inclusive)
        if (options.end) |end| {
            const bytes = end.toBytes();
            try builder.addBytes(.stream_end, &bytes);
        }

        // Tail mode (start from end of stream)
        if (options.tail) {
            try builder.addFlag(.stream_tail);
        }

        // Explicit partition index
        if (options.partition) |p| {
            try builder.addU32(.partition, p);
        }

        // Count limit
        if (options.count) |c| {
            try builder.addU32(.count, c);
        }

        // Block mode (long polling)
        if (options.block_ms) |block| {
            try builder.addU32(.block_ms, block);
        }

        var response = try self.client.sendRequest(
            .stream_read,
            ns,
            stream_name,
            "",
            builder.getOptions(),
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }

        return parseStreamReadResponse(self.client.allocator, response.data);
    }

    /// Get stream information (metadata). A stream that doesn't exist is
    /// FloError.NotFound, never an empty stream.
    pub fn info(
        self: *Stream,
        stream_name: []const u8,
        options: types.StreamInfoOptions,
    ) FloError!types.StreamInfo {
        const ns = self.client.getNamespace(options.namespace);

        var response = try self.client.sendRequest(
            .stream_info,
            ns,
            stream_name,
            "",
            "",
        );
        defer response.deinit();

        if (response.status == .not_found) {
            return FloError.NotFound;
        }

        if (response.status != .ok) {
            return response.status.toError();
        }

        // Parse response: [first_ts:u64][first_seq:u64][last_ts:u64][last_seq:u64][count:u64][bytes:u64][partition_count:u32][retention_age_s:u64][retention_count:u64][retention_bytes:u64]; the retention fields are not read yet
        if (response.data.len < 52) {
            return FloError.IncompleteResponse;
        }

        return types.StreamInfo{
            .first_id = .{
                .timestamp_ms = std.mem.readInt(u64, response.data[0..8], .little),
                .sequence = std.mem.readInt(u64, response.data[8..16], .little),
            },
            .last_id = .{
                .timestamp_ms = std.mem.readInt(u64, response.data[16..24], .little),
                .sequence = std.mem.readInt(u64, response.data[24..32], .little),
            },
            .count = std.mem.readInt(u64, response.data[32..40], .little),
            .bytes = std.mem.readInt(u64, response.data[40..48], .little),
            .partition_count = std.mem.readInt(u32, response.data[48..52], .little),
        };
    }

    /// Remove a stream's oldest records by exactly one bound: `before`,
    /// `max_len` or `max_age_seconds`. With `dry_run` nothing is removed and
    /// the result says what would be. Trim cuts whole append batches, so
    /// `max_len` may keep a few more records than asked.
    pub fn trim(
        self: *Stream,
        stream_name: []const u8,
        options: types.StreamTrimOptions,
    ) FloError!types.StreamTrimResult {
        const ns = self.client.getNamespace(options.namespace);

        var opts_buf: [64]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);

        if (options.before) |before| {
            const bytes = before.toBytes();
            try builder.addBytes(.stream_start, &bytes);
        }

        if (options.max_len) |max| {
            try builder.addU64(.limit, max);
        }

        if (options.max_age_seconds) |age| {
            try builder.addU64(.max_age_seconds, age);
        }

        if (options.dry_run) {
            try builder.addFlag(.dry_run);
        }

        var response = try self.client.sendRequest(
            .stream_trim,
            ns,
            stream_name,
            "",
            builder.getOptions(),
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }
        if (response.data.len != 16) return FloError.IncompleteResponse;
        return .{
            .removed = std.mem.readInt(u64, response.data[0..8], .little),
            .first_seq = std.mem.readInt(u64, response.data[8..16], .little),
        };
    }

    /// Delete a stream's records and metadata. Deleting a missing stream
    /// succeeds. A stream that still holds records is refused with
    /// `FloError.Conflict` unless `force` is set.
    pub fn delete(
        self: *Stream,
        stream_name: []const u8,
        options: types.StreamDeleteOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var opts_buf: [2]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);
        if (options.force) {
            try builder.addFlag(.force);
        }

        var response = try self.client.sendRequest(
            .stream_delete,
            ns,
            stream_name,
            "",
            builder.getOptions(),
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }
    }

    // =========================================================================
    // Consumer Group Operations
    // =========================================================================
    //
    // A group read leases records to its consumer until an ack, a nack or
    // the group's lease (ack timeout) running out, when they are ready for
    // the next read: delivery is at least once. Ack, nack and touch name the
    // read's lease and each record's deliveries, so a report for a delivery
    // that has moved on applies nothing.

    /// Create a consumer group on a stream, with its lease and attempts;
    /// returns whether it made one. Creating it again with the same
    /// settings returns false; with others it is `FloError.Conflict`, as
    /// a group's settings are fixed when it is made.
    /// A group a read names that doesn't exist is created then, at the
    /// server's defaults: a 30 s lease and 5 attempts.
    pub fn groupCreate(
        self: *Stream,
        stream_name: []const u8,
        group: []const u8,
        options: types.StreamGroupCreateOptions,
    ) FloError!bool {
        var buf: [2 + types.MAX_GROUP_NAME]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try writeName(&w, group, types.MAX_GROUP_NAME);
        var opts_buf: [16]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);
        if (options.ack_timeout_ms) |ms| {
            if (ms < types.MIN_GROUP_LEASE_MS or ms > types.MAX_GROUP_LEASE_MS) return FloError.BadRequest;
            try builder.addU32(.ack_timeout_ms, ms);
        }
        if (options.max_deliver) |n| {
            if (n == 0) return FloError.BadRequest;
            try builder.addU8(.max_deliver, n);
        }
        var response = try self.client.sendRequest(.stream_group_create, self.client.getNamespace(options.namespace), stream_name, w.buffered(), builder.getOptions());
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        if (response.data.len != 1) return FloError.IncompleteResponse;
        return response.data[0] != 0;
    }

    /// Delete a consumer group and every record it holds; returns how many
    /// records it dropped.
    pub fn groupDelete(
        self: *Stream,
        stream_name: []const u8,
        group: []const u8,
        options: types.StreamGroupOptions,
    ) FloError!u64 {
        var buf: [2 + types.MAX_GROUP_NAME]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try writeName(&w, group, types.MAX_GROUP_NAME);
        var response = try self.client.sendRequest(.stream_group_delete, self.client.getNamespace(options.namespace), stream_name, w.buffered(), "");
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        if (response.data.len != 8) return FloError.IncompleteResponse;
        return std.mem.readInt(u64, response.data[0..8], .little);
    }

    /// A consumer group's records by state. A group the stream doesn't have
    /// is `FloError.NotFound`.
    pub fn groupInfo(
        self: *Stream,
        stream_name: []const u8,
        group: []const u8,
        options: types.StreamGroupOptions,
    ) FloError!types.StreamGroupInfo {
        var buf: [2 + types.MAX_GROUP_NAME]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try writeName(&w, group, types.MAX_GROUP_NAME);
        var response = try self.client.sendRequest(.stream_group_info, self.client.getNamespace(options.namespace), stream_name, w.buffered(), "");
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        var r: Reader = .{ .data = response.data };
        const got: types.StreamGroupInfo = .{
            .pending = try r.int(u64),
            .holders = try r.int(u32),
            .created_at_ms = @intCast(try r.int(u64) / std.time.ns_per_ms),
            .ready = try r.int(u64),
            .leased = try r.int(u64),
            .dead = try r.int(u64),
            .trimmed_pending = try r.int(u64),
        };
        try r.end();
        return got;
    }

    /// Lease up to `options.count` (1 to 100; null for 100) of the group's
    /// records to `consumer`: those ready again (a lease ran out, or a nack)
    /// first, then the stream's past the group's last. Ack each within the
    /// lease, or touch it: one left past `result.expires_at_ms` is ready
    /// again for the next read, and one nacked or expired as many times as
    /// the group's attempts is dead. None within `block_ms` is an empty
    /// result. A group at its caps (leased, ready and dead records
    /// together), or a shard whose queues and groups are at theirs, takes
    /// nothing new: `FloError.GroupHeldFull`, not retried, as reading again
    /// won't help (see the error for what clears it).
    /// **Caller owns the returned `GroupReadResult` and must call `result.deinit()`.**
    pub fn groupRead(
        self: *Stream,
        stream_name: []const u8,
        group: []const u8,
        consumer: []const u8,
        options: types.StreamGroupReadOptions,
    ) FloError!types.GroupReadResult {
        var buf: [4 + types.MAX_GROUP_NAME + types.MAX_GROUP_CONSUMER]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try writeName(&w, group, types.MAX_GROUP_NAME);
        try writeName(&w, consumer, types.MAX_GROUP_CONSUMER);

        var opts_buf: [32]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);
        if (options.count) |c| {
            if (c < 1 or c > types.MAX_GROUP_BATCH) return FloError.BadRequest;
            try builder.addU32(.count, c);
        }
        if (options.block_ms) |block| try builder.addU32(.block_ms, block);

        var response = try self.client.sendRequest(.stream_group_read, self.client.getNamespace(options.namespace), stream_name, w.buffered(), builder.getOptions());
        defer response.deinit();
        if (response.status != .ok) {
            if (response.status == .overloaded) if (self.client.lastError()) |last| if (last.reason == .group_held_full) return FloError.GroupHeldFull;
            return response.status.toError();
        }
        return parseGroupReadResponse(self.client.allocator, response.data);
    }

    /// Ack records a group read leased: they are done. Each record is
    /// applied or refused on its own; one refused `gone` was acked already.
    /// A report to a group that isn't there (never made, or deleted) is
    /// `FloError.NotFound` as a whole, not each record gone.
    /// **Caller owns the returned `GroupReport` and must call `report.deinit()`.**
    pub fn groupAck(
        self: *Stream,
        stream_name: []const u8,
        group: []const u8,
        lease: types.GroupLease,
        records: []const types.StreamRecord,
        options: types.StreamGroupReportOptions,
    ) FloError!types.GroupReport {
        return self.groupReport(.stream_group_ack, stream_name, group, lease, records, options.consumer, options.namespace, "", null);
    }

    /// Nack records a group read leased: ready again after
    /// `options.delay_ms`, or dead once the group's attempts are spent (or
    /// at once with `options.dead`). `options.error_message` (at most
    /// `MAX_NACK_ERROR` bytes) is kept with them.
    ///
    /// `options.abandon` hands them back unstarted instead: ready at once,
    /// the delivery counted but no failure, so they never dead-letter. Use
    /// it only for records never started (a worker stopping); nack a
    /// failure without it, or a poison record cycles forever. The server
    /// refuses it with `delay_ms`, `dead` or an error; so does this, before
    /// sending.
    /// **Caller owns the returned `GroupReport` and must call `report.deinit()`.**
    pub fn groupNack(
        self: *Stream,
        stream_name: []const u8,
        group: []const u8,
        lease: types.GroupLease,
        records: []const types.StreamRecord,
        options: types.StreamGroupNackOptions,
    ) FloError!types.GroupReport {
        if (options.delay_ms > types.MAX_FAIL_DELAY_MS) return FloError.BadRequest;
        if (options.error_message.len > types.MAX_NACK_ERROR) return FloError.ValueTooLarge;
        if (options.abandon and (options.dead or options.delay_ms > 0 or options.error_message.len > 0)) return FloError.BadRequest;
        var opts_buf: [16]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);
        if (options.delay_ms > 0) try builder.addU64(.delay_ms, options.delay_ms);
        if (options.dead) try builder.addFlag(.dead);
        if (options.abandon) try builder.addFlag(.abandon);
        return self.groupReport(.stream_group_nack, stream_name, group, lease, records, options.consumer, options.namespace, builder.getOptions(), options.error_message);
    }

    /// Keep records a group read leased: with half their lease or less
    /// left it runs a full lease from now, up to 12 h from their read; with
    /// more left, nothing changes. The report's `expires_at_ms` is the
    /// lease's end.
    /// **Caller owns the returned `GroupReport` and must call `report.deinit()`.**
    pub fn groupTouch(
        self: *Stream,
        stream_name: []const u8,
        group: []const u8,
        lease: types.GroupLease,
        records: []const types.StreamRecord,
        options: types.StreamGroupReportOptions,
    ) FloError!types.GroupReport {
        return self.groupReport(.stream_group_touch, stream_name, group, lease, records, options.consumer, options.namespace, "", null);
    }

    fn groupReport(
        self: *Stream,
        op: types.OpCode,
        stream_name: []const u8,
        group: []const u8,
        lease: types.GroupLease,
        records: []const types.StreamRecord,
        consumer: []const u8,
        namespace: ?[]const u8,
        options: []const u8,
        /// A nack's error, `[error_len:u16][error]` after the records.
        nack_error: ?[]const u8,
    ) FloError!types.GroupReport {
        if (records.len < 1 or records.len > types.MAX_GROUP_BATCH) return FloError.BadRequest;
        var buf: [4 + types.MAX_GROUP_NAME + types.MAX_GROUP_CONSUMER + 20 + types.MAX_GROUP_BATCH * 20 + 2 + types.MAX_NACK_ERROR]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try writeName(&w, group, types.MAX_GROUP_NAME);
        try writeName(&w, consumer, types.MAX_GROUP_CONSUMER);
        w.writeInt(u64, lease.term, .little) catch unreachable;
        w.writeInt(u64, lease.index, .little) catch unreachable;
        w.writeInt(u32, @intCast(records.len), .little) catch unreachable;
        for (records) |rec| {
            w.writeInt(u64, rec.id.timestamp_ms, .little) catch unreachable;
            w.writeInt(u64, rec.id.sequence, .little) catch unreachable;
            w.writeInt(u32, rec.deliveries, .little) catch unreachable;
        }
        if (nack_error) |text| {
            w.writeInt(u16, @intCast(text.len), .little) catch unreachable;
            w.writeAll(text) catch unreachable;
        }
        var response = try self.client.sendRequest(op, self.client.getNamespace(namespace), stream_name, w.buffered(), options);
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        return decodeGroupReport(self.client.allocator, response.data, op == .stream_group_touch);
    }

    /// The stream's consumer groups: how many consumers hold records, the
    /// records ready or leased, settings and the last record delivered.
    /// **Caller owns the returned list and must call `list.deinit()`.**
    pub fn groupList(self: *Stream, stream_name: []const u8, options: types.StreamGroupListOptions) FloError!types.StreamGroupList {
        var response = try self.client.sendRequest(.stream_group_list, self.client.getNamespace(options.namespace), stream_name, "", "");
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        return decodeGroupList(self.client.allocator, response.data);
    }

    /// A consumer group's members: the consumers holding its records, each
    /// with how many, since when, and when it last took one. A group the
    /// stream doesn't have is `FloError.NotFound`.
    /// **Caller owns the returned list and must call `list.deinit()`.**
    pub fn groupMembers(self: *Stream, stream_name: []const u8, group: []const u8, options: types.StreamGroupListOptions) FloError!types.StreamGroupMembers {
        if (group.len > max_group_name) return FloError.ValueTooLarge;
        // A table op: the body is the group, u16-length-prefixed.
        var body: [2 + max_group_name]u8 = undefined;
        std.mem.writeInt(u16, body[0..2], @intCast(group.len), .little);
        @memcpy(body[2..][0..group.len], group);
        var response = try self.client.sendRequest(.stream_group_members, self.client.getNamespace(options.namespace), stream_name, body[0 .. 2 + group.len], "");
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        return decodeGroupMembers(self.client.allocator, response.data);
    }
};

/// A u16-length-prefixed name of at most `max` bytes.
fn writeName(w: *std.Io.Writer, name: []const u8, max: usize) FloError!void {
    if (name.len > max) return FloError.ValueTooLarge;
    w.writeInt(u16, @intCast(name.len), .little) catch return FloError.BufferTooSmall;
    w.writeAll(name) catch return FloError.BufferTooSmall;
}

/// A group read that leased nothing, as the server answers it.
pub const empty_group_read = [_]u8{0} ** 28;

/// A record's smallest encoding: no key, payload or headers.
const min_record = 8 + 8 + 1 + 4 + 1 + 4 + 4;

/// Parse stream read response
/// Wire format: [count:u32]([sequence:u64][timestamp_ms:i64][tier:u8][partition:u32][key_present:u8][payload_len:u32][payload][header_count:u32])*
fn parseStreamReadResponse(allocator: std.mem.Allocator, data: []const u8) FloError!types.StreamReadResult {
    if (data.len < 4) {
        return types.StreamReadResult{
            .records = &[_]types.StreamRecord{},
            .allocator = allocator,
        };
    }
    var pos: usize = 4;
    const records = try parseRecords(allocator, data, &pos, std.mem.readInt(u32, data[0..4], .little), false);
    return .{ .records = records, .allocator = allocator };
}

/// A group read's answer: [term:u64][index:u64][expires_at_ms:i64][count:u32]
/// then each record as a stream read gives it, followed by its
/// [deliveries:u32]. A read that leased nothing is all zeros.
fn parseGroupReadResponse(allocator: std.mem.Allocator, data: []const u8) FloError!types.GroupReadResult {
    if (data.len < 28) return FloError.IncompleteResponse;
    var pos: usize = 28;
    const records = try parseRecords(allocator, data, &pos, std.mem.readInt(u32, data[24..28], .little), true);
    errdefer {
        for (records) |*r| r.deinit(allocator);
        allocator.free(records);
    }
    if (pos != data.len) return FloError.IncompleteResponse;
    return .{
        .records = records,
        .lease = .{ .term = std.mem.readInt(u64, data[0..8], .little), .index = std.mem.readInt(u64, data[8..16], .little) },
        .expires_at_ms = std.mem.readInt(i64, data[16..24], .little),
        .allocator = allocator,
    };
}

/// `count` records from `data` at `pos.*`, each followed by its deliveries
/// when `group`.
fn parseRecords(allocator: std.mem.Allocator, data: []const u8, pos_ptr: *usize, count: u32, comptime group: bool) FloError![]types.StreamRecord {
    var pos = pos_ptr.*;
    defer pos_ptr.* = pos;
    // A count the data can't hold is refused before it sizes an allocation.
    const each = min_record + if (group) 4 else 0;
    if (count > (data.len - pos) / each) return FloError.IncompleteResponse;
    if (group and count > types.MAX_GROUP_BATCH) return FloError.IncompleteResponse;

    const records = allocator.alloc(types.StreamRecord, count) catch return FloError.OutOfMemory;
    // Only records[0..i] are filled; an answer cut short frees those alone.
    var i: u32 = 0;
    errdefer {
        for (records[0..i]) |*r| r.deinit(allocator);
        allocator.free(records);
    }

    while (i < count) : (i += 1) {
        if (pos + 8 + 8 + 1 + 4 + 1 > data.len) return FloError.IncompleteResponse;
        const sequence = std.mem.readInt(u64, data[pos..][0..8], .little);
        const timestamp_ms = std.mem.readInt(u64, data[pos + 8 ..][0..8], .little);
        const tier: types.StorageTier = @enumFromInt(data[pos + 16]);
        // The partition is skipped.
        const key_present = data[pos + 21];
        pos += 22;

        // Read key (stream name) if present
        var stream_name: []const u8 = "";
        if (key_present != 0) {
            if (pos + 4 > data.len) return FloError.IncompleteResponse;
            const key_len = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;
            if (key_len > data.len - pos) return FloError.IncompleteResponse;
            stream_name = allocator.dupe(u8, data[pos..][0..key_len]) catch return FloError.OutOfMemory;
            pos += key_len;
        }
        errdefer if (stream_name.len > 0) allocator.free(stream_name);

        // Read payload
        if (pos + 4 > data.len) return FloError.IncompleteResponse;
        const payload_len = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        if (payload_len > data.len - pos) return FloError.IncompleteResponse;
        const payload = allocator.dupe(u8, data[pos..][0..payload_len]) catch return FloError.OutOfMemory;
        errdefer allocator.free(payload);
        pos += payload_len;

        // Read headers: [header_count:u32]([key_len:u32][key][val_len:u32][val])*
        if (pos + 4 > data.len) return FloError.IncompleteResponse;
        const header_count = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        // Each header takes at least its two lengths, so a count the answer
        // can't hold is refused before it sizes an allocation.
        if (header_count > (data.len - pos) / 8) return FloError.IncompleteResponse;
        const headers = allocator.alloc(types.Header, header_count) catch return FloError.OutOfMemory;
        var filled: usize = 0;
        errdefer {
            for (headers[0..filled]) |h| {
                allocator.free(h.key);
                allocator.free(h.value);
            }
            allocator.free(headers);
        }
        while (filled < header_count) : (filled += 1) {
            var parts: [2][]const u8 = undefined;
            for (&parts) |*part| {
                if (pos + 4 > data.len) return FloError.IncompleteResponse;
                const len = std.mem.readInt(u32, data[pos..][0..4], .little);
                pos += 4;
                if (len > data.len - pos) return FloError.IncompleteResponse;
                part.* = data[pos..][0..len];
                pos += len;
            }
            const key = allocator.dupe(u8, parts[0]) catch return FloError.OutOfMemory;
            const value = allocator.dupe(u8, parts[1]) catch {
                allocator.free(key);
                return FloError.OutOfMemory;
            };
            headers[filled] = .{ .key = key, .value = value };
        }

        var deliveries: u32 = 0;
        if (group) {
            if (pos + 4 > data.len) return FloError.IncompleteResponse;
            deliveries = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;
        }

        records[i] = .{
            .id = .{
                .timestamp_ms = timestamp_ms,
                .sequence = sequence,
            },
            .tier = tier,
            .stream = stream_name,
            .payload = payload,
            .headers = headers,
            .deliveries = deliveries,
        };
    }
    return records;
}

/// An ack's, nack's or touch's answer: [expires_at_ms:i64] (touch only),
/// [applied:u32][refused:u32] then each refused {ms:u64, seq:u64, why:u8}.
fn decodeGroupReport(allocator: std.mem.Allocator, data: []const u8, touch: bool) FloError!types.GroupReport {
    var r: Reader = .{ .data = data };
    const expires_at_ms: i64 = if (touch) try r.int(i64) else 0;
    const applied = try r.int(u32);
    const n = try r.int(u32);
    if (n > types.MAX_GROUP_BATCH or n > r.remaining() / 17) return FloError.IncompleteResponse;
    const refused = try allocator.alloc(types.GroupRefusal, n);
    errdefer allocator.free(refused);
    for (refused) |*f| {
        const ms = try r.int(u64);
        const seq = try r.int(u64);
        // A why this SDK predates is kept as its number.
        f.* = .{ .id = .{ .timestamp_ms = ms, .sequence = seq }, .why = @enumFromInt(try r.int(u8)) };
    }
    try r.end();
    return .{ .applied = applied, .refused = refused, .expires_at_ms = expires_at_ms, .allocator = allocator };
}

// =============================================================================
// Tests
// =============================================================================

test "Stream init" {
    const allocator = std.testing.allocator;
    var client = @import("client.zig").Client.init(allocator, "localhost:9000", .{});
    defer client.deinit();

    const stream = Stream.init(&client);
    _ = stream;
}

test "a record's tier byte reads as the server sends it: 0 hot, 1 warm, 2 disk, and one this SDK predates as its number" {
    // [count=1][seq][ts][tier][partition][key_present=0][payload_len=0][header_count=0]
    var buf = [_]u8{0} ** (4 + 8 + 8 + 1 + 4 + 1 + 4 + 4);
    std.mem.writeInt(u32, buf[0..4], 1, .little);
    for ([_]struct { u8, types.StorageTier }{ .{ 0, .hot }, .{ 1, .warm }, .{ 2, .disk }, .{ 9, @enumFromInt(9) } }) |c| {
        buf[20] = c[0];
        var result = try parseStreamReadResponse(std.testing.allocator, &buf);
        defer result.deinit();
        try std.testing.expectEqual(c[1], result.records[0].tier);
    }
}

/// A read answer of `n` records, each with a stream name, payload and one header.
fn testReadAnswer(a: std.mem.Allocator, list: *std.ArrayList(u8), n: u32) !void {
    try list.appendSlice(a, &std.mem.toBytes(n));
    for (0..n) |_| {
        try list.appendSlice(a, &([_]u8{0} ** 16)); // seq, ts
        try list.append(a, 0); // tier
        try list.appendSlice(a, &([_]u8{0} ** 4)); // partition
        try list.append(a, 1); // key_present
        try list.appendSlice(a, &std.mem.toBytes(@as(u32, 1)));
        try list.append(a, 's');
        try list.appendSlice(a, &std.mem.toBytes(@as(u32, 2)));
        try list.appendSlice(a, "hi");
        try list.appendSlice(a, &std.mem.toBytes(@as(u32, 1)));
        try list.appendSlice(a, &std.mem.toBytes(@as(u32, 1)));
        try list.append(a, 'k');
        try list.appendSlice(a, &std.mem.toBytes(@as(u32, 1)));
        try list.append(a, 'v');
    }
}

test "a read answer cut anywhere is refused without leaking or freeing what it never filled" {
    const a = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(a);
    try testReadAnswer(a, &list, 2);
    var whole = try parseStreamReadResponse(a, list.items);
    whole.deinit();
    for (4..list.items.len) |n| {
        try std.testing.expectError(FloError.IncompleteResponse, parseStreamReadResponse(a, list.items[0..n]));
    }
}

fn parseAndFree(a: std.mem.Allocator, data: []const u8) !void {
    var result = try parseStreamReadResponse(a, data);
    result.deinit();
}

test "a read answer that runs out of memory partway frees what it filled" {
    const a = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(a);
    try testReadAnswer(a, &list, 3);
    try std.testing.checkAllAllocationFailures(a, parseAndFree, .{list.items});
}

test "a read answer whose count the data can't hold is refused before allocating" {
    var buf = [_]u8{0} ** (4 + 30);
    std.mem.writeInt(u32, buf[0..4], 0xffff_ffff, .little);
    try std.testing.expectError(FloError.IncompleteResponse, parseStreamReadResponse(std.testing.allocator, &buf));
}

test "an append sends its record as a batch of one, headers included" {
    const value = try Stream.encodeAppendValue(std.testing.allocator, "hi", &.{.{ .key = "k", .value = "vv" }});
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0, 0, 0, 2, 0, 0, 0, 'h', 'i', 1, 0, 1, 0, 'k', 2, 0, 'v', 'v' }, value);
    const bare = try Stream.encodeAppendValue(std.testing.allocator, "x", &.{});
    defer std.testing.allocator.free(bare);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0, 0, 0, 1, 0, 0, 0, 'x', 0, 0 }, bare);
}

/// A read answer of one record, payload "p", headers source=web and a="".
fn testHeaderAnswer(a: std.mem.Allocator, list: *std.ArrayList(u8)) !void {
    try list.appendSlice(a, &std.mem.toBytes(@as(u32, 1)));
    try list.appendSlice(a, &std.mem.toBytes(@as(u64, 5)));
    try list.appendSlice(a, &std.mem.toBytes(@as(i64, 1000)));
    try list.append(a, 0); // tier
    try list.appendSlice(a, &std.mem.toBytes(@as(u32, 0))); // partition
    try list.append(a, 0); // no key
    try list.appendSlice(a, &std.mem.toBytes(@as(u32, 1)));
    try list.append(a, 'p');
    try list.appendSlice(a, &std.mem.toBytes(@as(u32, 2)));
    for ([_][]const u8{ "source", "web", "a", "" }) |part| {
        try list.appendSlice(a, &std.mem.toBytes(@as(u32, @intCast(part.len))));
        try list.appendSlice(a, part);
    }
}

fn parseHeadersAndFree(a: std.mem.Allocator, data: []const u8) !void {
    var res = try parseStreamReadResponse(a, data);
    res.deinit();
}

test "a read's headers decode into pairs, and a cut answer or no memory leaks nothing" {
    const a = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(a);
    try testHeaderAnswer(a, &list);
    var res = try parseStreamReadResponse(a, list.items);
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 2), res.records[0].headers.len);
    try std.testing.expectEqualStrings("source", res.records[0].headers[0].key);
    try std.testing.expectEqualStrings("web", res.records[0].headers[0].value);
    try std.testing.expectEqualStrings("", res.records[0].headers[1].value);
    for (4..list.items.len) |n| try std.testing.expectError(FloError.IncompleteResponse, parseHeadersAndFree(a, list.items[0..n]));
    try std.testing.checkAllAllocationFailures(a, parseHeadersAndFree, .{@as([]const u8, list.items)});
}

test "an append refuses a header past what its u16 lengths hold" {
    const a = std.testing.allocator;
    const long = try a.alloc(u8, std.math.maxInt(u16) + 1);
    defer a.free(long);
    @memset(long, 'x');
    try std.testing.expectError(FloError.ValueTooLarge, Stream.encodeAppendValue(a, "p", &.{.{ .key = "k", .value = long }}));
    try std.testing.expectError(FloError.ValueTooLarge, Stream.encodeAppendValue(a, "p", &.{.{ .key = long, .value = "v" }}));
    // The longest that fit are sent.
    const value = try Stream.encodeAppendValue(a, "p", &.{.{ .key = "k", .value = long[0..std.math.maxInt(u16)] }});
    defer a.free(value);
    try std.testing.expectEqual(@as(usize, 4 + 4 + 1 + 2 + 2 + 1 + 2 + std.math.maxInt(u16)), value.len);
}

test "delete sends the stream as the key, with the force flag only when asked; a non-empty stream is a conflict" {
    const test_server = @import("test_server.zig");
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{
        .{ .status = 0 },
        .{ .status = 0 },
        .{ .status = @intFromEnum(types.StatusCode.conflict), .body = "\x0c\x00\x00stream is not empty; pass --force to delete" },
    };
    try srv.start();
    defer srv.deinit();

    var client = Client.init(std.testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var stream = Stream.init(&client);

    // Body after the key: [value_len:u32=0][options_len:u16][options].
    try stream.delete("events", .{});
    try std.testing.expectEqual(@as(u16, 0x140), srv.last_op);
    try std.testing.expectEqualStrings("events", srv.lastKey());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0 }, srv.lastBody());

    try stream.delete("events", .{ .force = true });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 2, 0, 0x2C, 0 }, srv.lastBody());

    try std.testing.expectError(FloError.Conflict, stream.delete("events", .{}));
}

test "info of a stream the server doesn't know is not found, not an empty stream" {
    const test_server = @import("test_server.zig");
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{.{ .status = @intFromEnum(types.StatusCode.not_found), .body = "\x10\x00\x00stream not found" }};
    try srv.start();
    defer srv.deinit();

    var client = Client.init(std.testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var stream = Stream.init(&client);

    try std.testing.expectError(FloError.NotFound, stream.info("nope", .{}));
    try std.testing.expectEqual(@as(u16, @intFromEnum(types.OpCode.stream_info)), srv.last_op);
    try std.testing.expectEqualStrings("nope", srv.lastKey());
}

const Reader = @import("kv.zig").Reader;

/// The longest group name or member id.
const max_group_name = 4096;
/// The most groups one answer lists, and members.
const max_groups = 256;
const max_members = 1024;

/// A group's smallest encoding: an empty name.
const min_group = 2 + 4 + 8 + 8 + 4 + 1 + 8 + 8;

/// stream.group.list's answer: groups (u16 count), each {name, members,
/// pending, created_at_ms, ack_timeout_ms, max_deliver, last_delivered_ms,
/// last_delivered_seq}, then more.
fn decodeGroupList(allocator: std.mem.Allocator, data: []const u8) FloError!types.StreamGroupList {
    var r: Reader = .{ .data = data };
    const n = try r.int(u16);
    if (n > max_groups or n > r.remaining() / min_group) return FloError.IncompleteResponse;
    const groups = try allocator.alloc(types.StreamGroupSummary, n);
    var got: usize = 0;
    errdefer {
        for (groups[0..got]) |g| allocator.free(g.name);
        allocator.free(groups);
    }
    while (got < n) : (got += 1) {
        const name = try r.lenBytes(u16);
        if (name.len > max_group_name) return FloError.IncompleteResponse;
        const members = try r.int(u32);
        const pending = try r.int(u64);
        const created_at_ms = try r.int(i64);
        const ack_timeout_ms = try r.int(u32);
        const max_deliver = try r.int(u8);
        const last_delivered_ms = try r.int(u64);
        const last_delivered_seq = try r.int(u64);
        groups[got] = .{
            .name = try allocator.dupe(u8, name),
            .members = members,
            .pending = pending,
            .created_at_ms = created_at_ms,
            .ack_timeout_ms = ack_timeout_ms,
            .max_deliver = max_deliver,
            .last_delivered_ms = last_delivered_ms,
            .last_delivered_seq = last_delivered_seq,
        };
    }
    const more = try r.boolean();
    try r.end();
    return .{ .groups = groups, .more = more, .allocator = allocator };
}

/// A member's smallest encoding: an empty id, never delivered to.
const min_member = 2 + 1 + 4 + 8 + 1;

/// stream.group.members' answer: members (u16 count), each {id, state,
/// pending, joined_at_ms, last_active_ms?}, then more.
fn decodeGroupMembers(allocator: std.mem.Allocator, data: []const u8) FloError!types.StreamGroupMembers {
    var r: Reader = .{ .data = data };
    const n = try r.int(u16);
    if (n > max_members or n > r.remaining() / min_member) return FloError.IncompleteResponse;
    const members = try allocator.alloc(types.StreamGroupMember, n);
    var got: usize = 0;
    errdefer {
        for (members[0..got]) |m| allocator.free(m.id);
        allocator.free(members);
    }
    while (got < n) : (got += 1) {
        const id = try r.lenBytes(u16);
        if (id.len > max_group_name) return FloError.IncompleteResponse;
        const state = std.meta.intToEnum(types.StreamGroupMemberState, try r.int(u8)) catch return FloError.IncompleteResponse;
        const pending = try r.int(u32);
        const joined_at_ms = try r.int(i64);
        const last_active_ms = try r.opt(i64);
        members[got] = .{ .id = try allocator.dupe(u8, id), .state = state, .pending = pending, .joined_at_ms = joined_at_ms, .last_active_ms = last_active_ms };
    }
    const more = try r.boolean();
    try r.end();
    return .{ .members = members, .more = more, .allocator = allocator };
}

const le = std.mem.toBytes;

/// Group "g": 2 members, 5 pending, created at 10, 30 s ack timeout, 4
/// deliveries, last delivered at 20 as seq 9; no more.
const test_group_list = le(@as(u16, 1)) ++ le(@as(u16, 1)) ++ "g" ++ le(@as(u32, 2)) ++ le(@as(u64, 5)) ++ le(@as(i64, 10)) ++
    le(@as(u32, 30_000)) ++ "\x04" ++ le(@as(u64, 20)) ++ le(@as(u64, 9)) ++ "\x00";

/// Member "c1", leaving, 3 pending, joined at 7, last delivered to at 8;
/// member "c2", active, never delivered to; more.
const test_group_members = le(@as(u16, 2)) ++
    le(@as(u16, 2)) ++ "c1" ++ "\x01" ++ le(@as(u32, 3)) ++ le(@as(i64, 7)) ++ "\x01" ++ le(@as(i64, 8)) ++
    le(@as(u16, 2)) ++ "c2" ++ "\x00" ++ le(@as(u32, 0)) ++ le(@as(i64, 7)) ++ "\x00" ++ "\x01";

test "groupList and groupMembers are keyed by the stream and read every field" {
    const test_server = @import("test_server.zig");
    const a = std.testing.allocator;
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{ .{ .status = 0, .body = test_group_list }, .{ .status = 0, .body = test_group_members } };
    try srv.start();
    defer srv.deinit();
    var client = Client.init(a, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var stream = Stream.init(&client);

    var groups = try stream.groupList("events", .{});
    defer groups.deinit();
    try std.testing.expectEqual(@as(u16, 0x15D), srv.last_op);
    try std.testing.expectEqualStrings("events", srv.lastKey());
    try std.testing.expectEqualStrings("", srv.lastBody());
    try std.testing.expectEqual(@as(usize, 1), groups.groups.len);
    const g = groups.groups[0];
    try std.testing.expectEqualStrings("g", g.name);
    try std.testing.expectEqual(@as(u32, 2), g.members);
    try std.testing.expectEqual(@as(u64, 5), g.pending);
    try std.testing.expectEqual(@as(u32, 30_000), g.ack_timeout_ms);
    try std.testing.expectEqual(@as(u8, 4), g.max_deliver);
    try std.testing.expectEqual(@as(u64, 9), g.last_delivered_seq);
    try std.testing.expect(!groups.more);

    var members = try stream.groupMembers("events", "g", .{});
    defer members.deinit();
    try std.testing.expectEqual(@as(u16, 0x15E), srv.last_op);
    try std.testing.expectEqualSlices(u8, "\x01\x00g", srv.lastBody());
    try std.testing.expectEqual(@as(usize, 2), members.members.len);
    try std.testing.expectEqualStrings("c1", members.members[0].id);
    try std.testing.expectEqual(types.StreamGroupMemberState.leaving, members.members[0].state);
    try std.testing.expectEqual(@as(u32, 3), members.members[0].pending);
    try std.testing.expectEqual(@as(?i64, 8), members.members[0].last_active_ms);
    try std.testing.expectEqual(@as(?i64, null), members.members[1].last_active_ms);
    try std.testing.expect(members.more);
}

test "group list and member answers cut anywhere, overlong or short of memory are refused and leak nothing" {
    const a = std.testing.allocator;
    const Run = struct {
        fn list(al: std.mem.Allocator, d: []const u8) !void {
            var l = try decodeGroupList(al, d);
            l.deinit();
        }
        fn members(al: std.mem.Allocator, d: []const u8) !void {
            var m = try decodeGroupMembers(al, d);
            m.deinit();
        }
    };
    const list: []const u8 = test_group_list;
    const members: []const u8 = test_group_members;
    for (0..list.len) |n| try std.testing.expectError(FloError.IncompleteResponse, Run.list(a, list[0..n]));
    for (0..members.len) |n| try std.testing.expectError(FloError.IncompleteResponse, Run.members(a, members[0..n]));
    try std.testing.expectError(FloError.IncompleteResponse, Run.list(a, test_group_list ++ "\x00"));
    try std.testing.expectError(FloError.IncompleteResponse, Run.members(a, test_group_members ++ "\x00"));
    // A member state this client doesn't know.
    var unknown = test_group_members.*;
    unknown[2 + 2 + 2] = 2;
    try std.testing.expectError(FloError.IncompleteResponse, Run.members(a, &unknown));
    try std.testing.checkAllAllocationFailures(a, Run.list, .{list});
    try std.testing.checkAllAllocationFailures(a, Run.members, .{members});
}

/// A group read leasing seq 7 ("hi", header k=v, 2 deliveries) under lease
/// (3, 9), expiring at 5000.
const test_group_read = le(@as(u64, 3)) ++ le(@as(u64, 9)) ++ le(@as(i64, 5000)) ++ le(@as(u32, 1)) ++
    le(@as(u64, 7)) ++ le(@as(u64, 100)) ++ "\x00" ++ le(@as(u32, 0)) ++ "\x00" ++ le(@as(u32, 2)) ++ "hi" ++
    le(@as(u32, 1)) ++ le(@as(u32, 1)) ++ "k" ++ le(@as(u32, 1)) ++ "v" ++ le(@as(u32, 2));

test "a group read sends group and consumer, and reads each record's deliveries and the read's lease" {
    const test_server = @import("test_server.zig");
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{ .{ .status = 0, .body = test_group_read }, .{ .status = 0, .body = &empty_group_read } };
    try srv.start();
    defer srv.deinit();
    var client = Client.init(std.testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var stream = Stream.init(&client);

    var got = try stream.groupRead("events", "g", "c1", .{ .count = 5, .block_ms = 100 });
    defer got.deinit();
    try std.testing.expectEqual(@as(u16, 0x153), srv.last_op);
    try std.testing.expectEqualStrings("events", srv.lastKey());
    try std.testing.expectEqualSlices(u8, "\x01\x00g\x02\x00c1", srv.lastValue());
    try std.testing.expectEqualSlices(u8, "\x15\x04\x05\x00\x00\x00\x17\x04\x64\x00\x00\x00", srv.lastOptions());
    try std.testing.expectEqual(types.GroupLease{ .term = 3, .index = 9 }, got.lease);
    try std.testing.expectEqual(@as(i64, 5000), got.expires_at_ms);
    try std.testing.expectEqual(@as(usize, 1), got.records.len);
    try std.testing.expectEqual(types.StreamID{ .timestamp_ms = 100, .sequence = 7 }, got.records[0].id);
    try std.testing.expectEqual(@as(u32, 2), got.records[0].deliveries);
    try std.testing.expectEqualStrings("hi", got.records[0].payload);
    try std.testing.expectEqualStrings("v", got.records[0].headers[0].value);

    // Nothing leased: all zeros.
    var none = try stream.groupRead("events", "g", "c1", .{});
    defer none.deinit();
    try std.testing.expectEqual(@as(usize, 0), none.records.len);
    try std.testing.expectEqualSlices(u8, "", srv.lastOptions());

    // Out of bounds, refused before a round trip.
    try std.testing.expectError(FloError.BadRequest, stream.groupRead("events", "g", "c1", .{ .count = 0 }));
    try std.testing.expectError(FloError.BadRequest, stream.groupRead("events", "g", "c1", .{ .count = types.MAX_GROUP_BATCH + 1 }));
    try std.testing.expectError(FloError.ValueTooLarge, stream.groupRead("events", "g" ** (types.MAX_GROUP_NAME + 1), "c1", .{}));
    try std.testing.expectEqual(@as(u32, 2), srv.requests.load(.acquire));
}

fn parseGroupAndFree(a: std.mem.Allocator, data: []const u8) !void {
    var res = try parseGroupReadResponse(a, data);
    res.deinit();
}

test "a group read answer cut anywhere, overlong, or short of memory is refused and leaks nothing" {
    const a = std.testing.allocator;
    const whole: []const u8 = test_group_read;
    for (0..whole.len) |n| try std.testing.expectError(FloError.IncompleteResponse, parseGroupAndFree(a, whole[0..n]));
    try std.testing.expectError(FloError.IncompleteResponse, parseGroupAndFree(a, test_group_read ++ "\x00"));
    try std.testing.checkAllAllocationFailures(a, parseGroupAndFree, .{whole});
}

test "ack, nack and touch name the read's lease and each record's deliveries, and a stale report applies nothing without an error" {
    const test_server = @import("test_server.zig");
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{
        // Applied 1, refused none.
        .{ .status = 0, .body = &(le(@as(u32, 1)) ++ le(@as(u32, 0))) },
        // A stale report: applied 0, (100, 7) delivered again.
        .{ .status = 0, .body = &(le(@as(u32, 0)) ++ le(@as(u32, 1)) ++ le(@as(u64, 100)) ++ le(@as(u64, 7)) ++ [_]u8{1}) },
        // A touch: expiry, then applied 1, refused none.
        .{ .status = 0, .body = &(le(@as(i64, 9000)) ++ le(@as(u32, 1)) ++ le(@as(u32, 0))) },
        // A why this SDK predates is kept.
        .{ .status = 0, .body = &(le(@as(u32, 0)) ++ le(@as(u32, 1)) ++ le(@as(u64, 100)) ++ le(@as(u64, 7)) ++ [_]u8{9}) },
    };
    try srv.start();
    defer srv.deinit();
    var client = Client.init(std.testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var stream = Stream.init(&client);

    const lease: types.GroupLease = .{ .term = 3, .index = 9 };
    const recs = [_]types.StreamRecord{.{ .id = .{ .timestamp_ms = 100, .sequence = 7 }, .payload = "", .deliveries = 2 }};
    const named = "\x01\x00g\x02\x00c1" ++ le(@as(u64, 3)) ++ le(@as(u64, 9)) ++ le(@as(u32, 1)) ++ le(@as(u64, 100)) ++ le(@as(u64, 7)) ++ le(@as(u32, 2));

    var acked = try stream.groupAck("events", "g", lease, &recs, .{ .consumer = "c1" });
    defer acked.deinit();
    try std.testing.expectEqual(@as(u16, 0x154), srv.last_op);
    try std.testing.expectEqualSlices(u8, named, srv.lastValue());
    try std.testing.expectEqual(@as(u32, 1), acked.applied);

    var stale = try stream.groupNack("events", "g", lease, &recs, .{ .consumer = "c1", .delay_ms = 1000, .dead = true, .error_message = "bad" });
    defer stale.deinit();
    try std.testing.expectEqual(@as(u16, 0x159), srv.last_op);
    // The error follows the records in the body; delay_ms (0x11, u64) and
    // dead (0x32) are options.
    try std.testing.expectEqualSlices(u8, named ++ "\x03\x00bad", srv.lastValue());
    try std.testing.expectEqualSlices(u8, "\x11\x08" ++ le(@as(u64, 1000)) ++ "\x32\x00", srv.lastOptions());
    try std.testing.expectEqual(@as(u32, 0), stale.applied);
    try std.testing.expectEqual(types.GroupRefusalWhy.delivered_again, stale.refused[0].why);
    try std.testing.expectEqual(types.StreamID{ .timestamp_ms = 100, .sequence = 7 }, stale.refused[0].id);

    var touched = try stream.groupTouch("events", "g", lease, &recs, .{ .consumer = "c1" });
    defer touched.deinit();
    try std.testing.expectEqual(@as(u16, 0x15A), srv.last_op);
    try std.testing.expectEqual(@as(i64, 9000), touched.expires_at_ms);
    try std.testing.expectEqual(@as(u32, 1), touched.applied);

    var unknown = try stream.groupAck("events", "g", lease, &recs, .{ .consumer = "c1" });
    defer unknown.deinit();
    try std.testing.expectEqual(@as(u8, 9), @intFromEnum(unknown.refused[0].why));

    try std.testing.expectError(FloError.BadRequest, stream.groupAck("events", "g", lease, &.{}, .{}));
    try std.testing.expectError(FloError.BadRequest, stream.groupNack("events", "g", lease, &recs, .{ .delay_ms = types.MAX_FAIL_DELAY_MS + 1 }));
    try std.testing.expectEqual(@as(u32, 4), srv.requests.load(.acquire));
}

test "a nack carries an error of up to 1024 bytes in its body, 0 for none; a longer one is refused unsent" {
    const test_server = @import("test_server.zig");
    var srv = try test_server.OkServer.listen();
    const applied = le(@as(u32, 1)) ++ le(@as(u32, 0));
    srv.replies = &.{ .{ .status = 0, .body = &applied }, .{ .status = 0, .body = &applied } };
    try srv.start();
    defer srv.deinit();
    var client = Client.init(std.testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var stream = Stream.init(&client);

    const lease: types.GroupLease = .{ .term = 3, .index = 9 };
    const recs = [_]types.StreamRecord{.{ .id = .{ .timestamp_ms = 100, .sequence = 7 }, .payload = "", .deliveries = 2 }};
    const named = "\x01\x00g\x02\x00c1" ++ le(@as(u64, 3)) ++ le(@as(u64, 9)) ++ le(@as(u32, 1)) ++ le(@as(u64, 100)) ++ le(@as(u64, 7)) ++ le(@as(u32, 2));

    const longest = "e" ** types.MAX_NACK_ERROR;
    var full = try stream.groupNack("events", "g", lease, &recs, .{ .consumer = "c1", .error_message = longest });
    defer full.deinit();
    try std.testing.expectEqualSlices(u8, named ++ le(@as(u16, types.MAX_NACK_ERROR)) ++ longest, srv.lastValue());
    try std.testing.expectEqualSlices(u8, "", srv.lastOptions());

    var none = try stream.groupNack("events", "g", lease, &recs, .{ .consumer = "c1" });
    defer none.deinit();
    try std.testing.expectEqualSlices(u8, named ++ "\x00\x00", srv.lastValue());

    try std.testing.expectError(FloError.ValueTooLarge, stream.groupNack("events", "g", lease, &recs, .{ .error_message = longest ++ "e" }));
    try std.testing.expectEqual(@as(u32, 2), srv.requests.load(.acquire));
}

test "an abandon is the abandon flag alone, and refused unsent with a delay, dead or an error" {
    const test_server = @import("test_server.zig");
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{.{ .status = 0, .body = &(le(@as(u32, 1)) ++ le(@as(u32, 0))) }};
    try srv.start();
    defer srv.deinit();
    var client = Client.init(std.testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var stream = Stream.init(&client);

    const lease: types.GroupLease = .{ .term = 3, .index = 9 };
    const recs = [_]types.StreamRecord{.{ .id = .{ .timestamp_ms = 100, .sequence = 7 }, .payload = "", .deliveries = 2 }};
    const named = "\x01\x00g\x02\x00c1" ++ le(@as(u64, 3)) ++ le(@as(u64, 9)) ++ le(@as(u32, 1)) ++ le(@as(u64, 100)) ++ le(@as(u64, 7)) ++ le(@as(u32, 2));
    var back = try stream.groupNack("events", "g", lease, &recs, .{ .consumer = "c1", .abandon = true });
    defer back.deinit();
    try std.testing.expectEqual(@as(u16, 0x159), srv.last_op);
    // abandon (0x34), void; the body ends with an empty error.
    try std.testing.expectEqualSlices(u8, "\x34\x00", srv.lastOptions());
    try std.testing.expectEqualSlices(u8, named ++ "\x00\x00", srv.lastValue());

    try std.testing.expectError(FloError.BadRequest, stream.groupNack("events", "g", lease, &recs, .{ .abandon = true, .dead = true }));
    try std.testing.expectError(FloError.BadRequest, stream.groupNack("events", "g", lease, &recs, .{ .abandon = true, .delay_ms = 1 }));
    try std.testing.expectError(FloError.BadRequest, stream.groupNack("events", "g", lease, &recs, .{ .abandon = true, .error_message = "x" }));
    try std.testing.expectEqual(@as(u32, 1), srv.requests.load(.acquire));
}

test "a report to a group that isn't there is NotFound as a whole" {
    const test_server = @import("test_server.zig");
    var srv = try test_server.OkServer.listen();
    // not_found, reason not_found (13), ran no.
    const missing: test_server.Reply = .{ .status = @intFromEnum(types.StatusCode.not_found), .body = "\x0d\x00\x00not found: no such consumer group" };
    srv.replies = &.{ missing, missing, missing };
    try srv.start();
    defer srv.deinit();
    var client = Client.init(std.testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var stream = Stream.init(&client);

    const lease: types.GroupLease = .{ .term = 3, .index = 9 };
    const recs = [_]types.StreamRecord{.{ .id = .{ .timestamp_ms = 100, .sequence = 7 }, .payload = "", .deliveries = 1 }};
    try std.testing.expectError(FloError.NotFound, stream.groupAck("events", "gone", lease, &recs, .{}));
    try std.testing.expectError(FloError.NotFound, stream.groupNack("events", "gone", lease, &recs, .{}));
    try std.testing.expectError(FloError.NotFound, stream.groupTouch("events", "gone", lease, &recs, .{}));
    try std.testing.expectEqual(types.Reason.not_found, client.lastError().?.reason);
}

test "a group read at its held cap is GroupHeldFull, sent once and not retried" {
    const test_server = @import("test_server.zig");
    var srv = try test_server.OkServer.listen();
    // overloaded, reason group_held_full (37), ran no.
    srv.replies = &.{.{ .status = @intFromEnum(types.StatusCode.overloaded), .body = "\x25\x00\x00overloaded: group 'g' on stream 'events' is full" }};
    try srv.start();
    defer srv.deinit();
    var client = Client.init(std.testing.allocator, srv.endpoint, .{ .retry = .{ .max_attempts = 4, .initial_backoff_ms = 1, .max_backoff_ms = 2 } });
    defer client.deinit();
    try client.connect();
    var stream = Stream.init(&client);

    try std.testing.expectError(FloError.GroupHeldFull, stream.groupRead("events", "g", "c1", .{}));
    try std.testing.expectEqual(@as(u32, 1), srv.requests.load(.acquire));
    try std.testing.expectEqual(types.Reason.group_held_full, client.lastError().?.reason);
    try std.testing.expect(!client.refusedUnrun(FloError.Overloaded));
}

test "a group report answer cut anywhere or overlong is refused" {
    const a = std.testing.allocator;
    const body = le(@as(i64, 1)) ++ le(@as(u32, 0)) ++ le(@as(u32, 1)) ++ le(@as(u64, 100)) ++ le(@as(u64, 7)) ++ "\x01";
    for (0..body.len) |n| try std.testing.expectError(FloError.IncompleteResponse, decodeGroupReport(a, body[0..n], true));
    try std.testing.expectError(FloError.IncompleteResponse, decodeGroupReport(a, body ++ "\x00", true));
    var r = try decodeGroupReport(a, body, true);
    r.deinit();
}

test "group create sends its lease and attempts, delete and info read their answers, and a removed group op has no API" {
    const test_server = @import("test_server.zig");
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{
        .{ .status = 0, .body = "\x01" },
        .{ .status = 0, .body = &le(@as(u64, 4)) },
        .{ .status = 0, .body = &(le(@as(u64, 3)) ++ le(@as(u32, 1)) ++ le(@as(u64, 7_000_000)) ++ le(@as(u64, 1)) ++ le(@as(u64, 2)) ++ le(@as(u64, 5)) ++ le(@as(u64, 0))) },
        .{ .status = @intFromEnum(types.StatusCode.not_found), .body = "\x0c\x00\x00not found: no such consumer group" },
    };
    try srv.start();
    defer srv.deinit();
    var client = Client.init(std.testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var stream = Stream.init(&client);

    try std.testing.expect(try stream.groupCreate("events", "g", .{ .ack_timeout_ms = 5000, .max_deliver = 2 }));
    try std.testing.expectEqual(@as(u16, 0x150), srv.last_op);
    try std.testing.expectEqualSlices(u8, "\x01\x00g", srv.lastValue());
    try std.testing.expectEqualSlices(u8, "\x30\x04" ++ le(@as(u32, 5000)) ++ "\x31\x01\x02", srv.lastOptions());

    try std.testing.expectEqual(@as(u64, 4), try stream.groupDelete("events", "g", .{}));
    try std.testing.expectEqual(@as(u16, 0x15C), srv.last_op);

    const info = try stream.groupInfo("events", "g", .{});
    try std.testing.expectEqual(@as(u16, 0x15B), srv.last_op);
    try std.testing.expectEqual(types.StreamGroupInfo{ .pending = 3, .holders = 1, .created_at_ms = 7, .ready = 1, .leased = 2, .dead = 5, .trimmed_pending = 0 }, info);
    try std.testing.expectError(FloError.NotFound, stream.groupInfo("events", "nope", .{}));

    try std.testing.expectError(FloError.BadRequest, stream.groupCreate("events", "g", .{ .ack_timeout_ms = types.MIN_GROUP_LEASE_MS - 1 }));
    try std.testing.expectError(FloError.BadRequest, stream.groupCreate("events", "g", .{ .ack_timeout_ms = types.MAX_GROUP_LEASE_MS + 1 }));
    try std.testing.expectError(FloError.BadRequest, stream.groupCreate("events", "g", .{ .max_deliver = 0 }));
    try std.testing.expectEqual(@as(u32, 4), srv.requests.load(.acquire));

    inline for (.{ "groupJoin", "groupLeave", "groupClaim", "groupConfigureSweeper" }) |name| try std.testing.expect(!@hasDecl(Stream, name));
}
