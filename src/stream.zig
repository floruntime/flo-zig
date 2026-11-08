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

        // Start StreamID for reads (inclusive)
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

    /// Join a consumer group.
    pub fn groupJoin(
        self: *Stream,
        stream_name: []const u8,
        group: []const u8,
        consumer: []const u8,
        options: types.StreamGroupJoinOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        // Encode group and consumer in value field: [group_len:u16][group][consumer_len:u16][consumer]
        var value_buf: [512]u8 = undefined;
        var offset: usize = 0;

        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(group.len), .little);
        offset += 2;
        @memcpy(value_buf[offset..][0..group.len], group);
        offset += group.len;

        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(consumer.len), .little);
        offset += 2;
        @memcpy(value_buf[offset..][0..consumer.len], consumer);
        offset += consumer.len;

        var response = try self.client.sendRequest(
            .stream_group_join,
            ns,
            stream_name,
            value_buf[0..offset],
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }
    }

    /// Read from a consumer group.
    /// **Caller owns the returned `StreamReadResult` and must call `result.deinit()`.**
    pub fn groupRead(
        self: *Stream,
        stream_name: []const u8,
        group: []const u8,
        consumer: []const u8,
        options: types.StreamGroupReadOptions,
    ) FloError!types.StreamReadResult {
        const ns = self.client.getNamespace(options.namespace);

        // Encode group and consumer in value field
        var value_buf: [512]u8 = undefined;
        var offset: usize = 0;

        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(group.len), .little);
        offset += 2;
        @memcpy(value_buf[offset..][0..group.len], group);
        offset += group.len;

        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(consumer.len), .little);
        offset += 2;
        @memcpy(value_buf[offset..][0..consumer.len], consumer);
        offset += consumer.len;

        var opts_buf: [32]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);

        if (options.count) |c| {
            try builder.addU32(.count, c);
        }

        if (options.block_ms) |block| {
            try builder.addU32(.block_ms, block);
        }

        var response = try self.client.sendRequest(
            .stream_group_read,
            ns,
            stream_name,
            value_buf[0..offset],
            builder.getOptions(),
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }

        return parseStreamReadResponse(self.client.allocator, response.data);
    }

    /// Acknowledge records in a consumer group.
    pub fn groupAck(
        self: *Stream,
        stream_name: []const u8,
        group: []const u8,
        ids: []const types.StreamID,
        options: types.StreamGroupAckOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        // Encode group, consumer and ids in value field:
        // [group_len:u16][group][consumer_len:u16][consumer][count:u32][timestamp_ms:u64][sequence:u64]*
        var value_buf: [4096]u8 = undefined;
        var offset: usize = 0;

        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(group.len), .little);
        offset += 2;
        @memcpy(value_buf[offset..][0..group.len], group);
        offset += group.len;

        const consumer = options.consumer;
        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(consumer.len), .little);
        offset += 2;
        if (consumer.len > 0) {
            @memcpy(value_buf[offset..][0..consumer.len], consumer);
            offset += consumer.len;
        }

        std.mem.writeInt(u32, value_buf[offset..][0..4], @intCast(ids.len), .little);
        offset += 4;

        for (ids) |id| {
            std.mem.writeInt(u64, value_buf[offset..][0..8], id.timestamp_ms, .little);
            offset += 8;
            std.mem.writeInt(u64, value_buf[offset..][0..8], id.sequence, .little);
            offset += 8;
        }

        var response = try self.client.sendRequest(
            .stream_group_ack,
            ns,
            stream_name,
            value_buf[0..offset],
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }
    }

    /// Leave a consumer group.
    pub fn groupLeave(
        self: *Stream,
        stream_name: []const u8,
        group: []const u8,
        consumer: []const u8,
        options: types.StreamGroupJoinOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        // Same encoding as GroupJoin
        var value_buf: [512]u8 = undefined;
        var offset: usize = 0;

        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(group.len), .little);
        offset += 2;
        @memcpy(value_buf[offset..][0..group.len], group);
        offset += group.len;

        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(consumer.len), .little);
        offset += 2;
        @memcpy(value_buf[offset..][0..consumer.len], consumer);
        offset += consumer.len;

        var response = try self.client.sendRequest(
            .stream_group_leave,
            ns,
            stream_name,
            value_buf[0..offset],
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }
    }

    /// Negatively acknowledge records in a consumer group.
    /// The server makes the records available for redelivery.
    pub fn groupNack(
        self: *Stream,
        stream_name: []const u8,
        group: []const u8,
        ids: []const types.StreamID,
        options: types.StreamGroupNackOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        // Encode group, consumer and ids in value field:
        // [group_len:u16][group][consumer_len:u16][consumer][count:u32][timestamp_ms:u64][sequence:u64]*
        var value_buf: [4096]u8 = undefined;
        var offset: usize = 0;

        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(group.len), .little);
        offset += 2;
        @memcpy(value_buf[offset..][0..group.len], group);
        offset += group.len;

        const consumer = options.consumer;
        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(consumer.len), .little);
        offset += 2;
        if (consumer.len > 0) {
            @memcpy(value_buf[offset..][0..consumer.len], consumer);
            offset += consumer.len;
        }

        std.mem.writeInt(u32, value_buf[offset..][0..4], @intCast(ids.len), .little);
        offset += 4;

        for (ids) |id| {
            std.mem.writeInt(u64, value_buf[offset..][0..8], id.timestamp_ms, .little);
            offset += 8;
            std.mem.writeInt(u64, value_buf[offset..][0..8], id.sequence, .little);
            offset += 8;
        }

        var response = try self.client.sendRequest(
            .stream_group_nack,
            ns,
            stream_name,
            value_buf[0..offset],
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }
    }

    /// The stream's consumer groups: members, pending entries, settings and
    /// the last record delivered. Answered by the leader.
    /// **Caller owns the returned list and must call `list.deinit()`.**
    pub fn groupList(self: *Stream, stream_name: []const u8, options: types.StreamGroupListOptions) FloError!types.StreamGroupList {
        var response = try self.client.sendRequest(.stream_group_list, self.client.getNamespace(options.namespace), stream_name, "", "");
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        return decodeGroupList(self.client.allocator, response.data);
    }

    /// A consumer group's members: each one's state, pending entries, and
    /// when it joined and was last delivered to. Answered by the leader; a
    /// group the stream doesn't have is `FloError.NotFound`.
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

/// Parse stream read response
/// Wire format: [count:u32]([sequence:u64][timestamp_ms:i64][tier:u8][partition:u32][key_present:u8][payload_len:u32][payload][header_count:u32])*
fn parseStreamReadResponse(allocator: std.mem.Allocator, data: []const u8) FloError!types.StreamReadResult {
    if (data.len < 4) {
        return types.StreamReadResult{
            .records = &[_]types.StreamRecord{},
            .allocator = allocator,
        };
    }

    var pos: usize = 0;
    const count = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;

    // Each record: [seq:u64][ts:i64][tier:u8][partition:u32][key_present:u8]
    //              [payload_len:u32][payload][header_count:u32]
    // A count the data can't hold is refused before it sizes an allocation.
    const min_record = 8 + 8 + 1 + 4 + 1 + 4 + 4;
    if (count > (data.len - pos) / min_record) return FloError.IncompleteResponse;

    const records = allocator.alloc(types.StreamRecord, count) catch return FloError.OutOfMemory;
    // Only records[0..i] are filled; an answer cut short frees those alone.
    var i: u32 = 0;
    errdefer {
        for (records[0..i]) |*r| r.deinit(allocator);
        allocator.free(records);
    }

    while (i < count) : (i += 1) {
        // Read sequence
        if (pos + 8 > data.len) return FloError.IncompleteResponse;
        const sequence = std.mem.readInt(u64, data[pos..][0..8], .little);
        pos += 8;

        // Read timestamp_ms
        if (pos + 8 > data.len) return FloError.IncompleteResponse;
        const timestamp_ms = std.mem.readInt(u64, data[pos..][0..8], .little);
        pos += 8;

        // Read tier
        if (pos + 1 > data.len) return FloError.IncompleteResponse;
        const tier_byte = data[pos];
        pos += 1;
        const tier = std.meta.intToEnum(types.StorageTier, tier_byte) catch return FloError.IncompleteResponse;

        // Skip partition
        if (pos + 4 > data.len) return FloError.IncompleteResponse;
        pos += 4;

        // Read key_present
        if (pos + 1 > data.len) return FloError.IncompleteResponse;
        const key_present = data[pos];
        pos += 1;

        // Read key (stream name) if present
        var stream_name: []const u8 = "";
        if (key_present != 0) {
            if (pos + 4 > data.len) return FloError.IncompleteResponse;
            const key_len = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;
            if (pos + key_len > data.len) return FloError.IncompleteResponse;
            stream_name = allocator.dupe(u8, data[pos..][0..key_len]) catch return FloError.OutOfMemory;
            pos += key_len;
        }
        errdefer if (stream_name.len > 0) allocator.free(stream_name);

        // Read payload
        if (pos + 4 > data.len) return FloError.IncompleteResponse;
        const payload_len = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        if (pos + payload_len > data.len) return FloError.IncompleteResponse;
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

        records[i] = .{
            .id = .{
                .timestamp_ms = timestamp_ms,
                .sequence = sequence,
            },
            .tier = tier,
            .stream = stream_name,
            .payload = payload,
            .headers = headers,
        };
    }

    return types.StreamReadResult{
        .records = records,
        .allocator = allocator,
    };
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

test "a record's tier byte reads as the server sends it: 0 hot, 1 warm, anything else refused" {
    // [count=1][seq][ts][tier][partition][key_present=0][payload_len=0][header_count=0]
    var buf = [_]u8{0} ** (4 + 8 + 8 + 1 + 4 + 1 + 4 + 4);
    std.mem.writeInt(u32, buf[0..4], 1, .little);
    for ([_]struct { u8, types.StorageTier }{ .{ 0, .hot }, .{ 1, .warm } }) |c| {
        buf[20] = c[0];
        var result = try parseStreamReadResponse(std.testing.allocator, &buf);
        defer result.deinit();
        try std.testing.expectEqual(c[1], result.records[0].tier);
    }
    buf[20] = 2;
    try std.testing.expectError(FloError.IncompleteResponse, parseStreamReadResponse(std.testing.allocator, &buf));
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
