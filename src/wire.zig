//! Flo Wire Protocol
//!
//! Binary serialization/deserialization for the Flo protocol.
//! Header: 32 bytes, little-endian, CRC32C validated.

const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const OpCode = types.OpCode;
const StatusCode = types.StatusCode;
const OptionTag = types.OptionTag;
const FloError = types.FloError;

// =============================================================================
// Headers
// =============================================================================

/// Request header (32 bytes)
pub const RequestHeader = extern struct {
    magic: u32,
    payload_length: u32,
    request_id: u64,
    crc32c: u32,
    op_code: u16,
    version: u8,
    flags: u8,
    table_hash: u64,

    pub fn validate(self: RequestHeader) FloError!void {
        if (self.magic != types.MAGIC) {
            return FloError.InvalidMagic;
        }
        if (self.version != types.VERSION or self.table_hash != types.TABLE_HASH) {
            return FloError.TableMismatch;
        }
        if (self.payload_length > 100 * 1024 * 1024) {
            return FloError.PayloadTooLarge;
        }
    }

    /// CRC32C (Castagnoli) of the header, without its crc32c field, then the payload.
    pub fn computeCRC32C(self: RequestHeader, payload: []const u8) u32 {
        var hasher = std.hash.crc.Crc32Iscsi.init();
        const header_bytes = std.mem.asBytes(&self);
        hasher.update(header_bytes[0..16]);
        hasher.update(header_bytes[20..32]);
        hasher.update(payload);
        return hasher.final();
    }
};

/// Response header (32 bytes)
pub const ResponseHeader = extern struct {
    magic: u32,
    data_len: u32,
    request_id: u64,
    crc32c: u32,
    version: u8,
    status: u8,
    flags: u8,
    _pad: u8,
    table_hash: u64,

    pub fn validate(self: ResponseHeader) FloError!void {
        if (self.magic != types.MAGIC) {
            return FloError.InvalidMagic;
        }
        if (self.version != types.VERSION or self.table_hash != types.TABLE_HASH) {
            return FloError.TableMismatch;
        }
    }

    /// CRC32C of the header, without its crc32c field, then the data.
    pub fn computeCRC32C(self: ResponseHeader, data: []const u8) u32 {
        var hasher = std.hash.crc.Crc32Iscsi.init();
        const header_bytes = std.mem.asBytes(&self);
        hasher.update(header_bytes[0..16]);
        hasher.update(header_bytes[20..32]);
        hasher.update(data);
        return hasher.final();
    }

    pub fn getStatus(self: ResponseHeader) StatusCode {
        return @enumFromInt(self.status);
    }
};

comptime {
    if (@sizeOf(RequestHeader) != 32) {
        @compileError("RequestHeader must be exactly 32 bytes");
    }
    if (@sizeOf(ResponseHeader) != 32) {
        @compileError("ResponseHeader must be exactly 32 bytes");
    }
}

// =============================================================================
// TLV Options
// =============================================================================

/// A single TLV option
pub const Option = struct {
    tag: OptionTag,
    data: []const u8,

    pub fn asU8(self: Option) ?u8 {
        if (self.data.len != 1) return null;
        return self.data[0];
    }

    pub fn asU32(self: Option) ?u32 {
        if (self.data.len != 4) return null;
        return std.mem.readInt(u32, self.data[0..4], .little);
    }

    pub fn asU64(self: Option) ?u64 {
        if (self.data.len != 8) return null;
        return std.mem.readInt(u64, self.data[0..8], .little);
    }

    pub fn asString(self: Option) []const u8 {
        return self.data;
    }

    pub fn isFlag(self: Option) bool {
        return self.data.len == 0;
    }
};

/// Helper for building TLV options into a buffer
pub const OptionsBuilder = struct {
    buffer: []u8,
    offset: usize = 0,

    pub fn init(buffer: []u8) OptionsBuilder {
        return .{ .buffer = buffer };
    }

    pub fn addU8(self: *OptionsBuilder, tag: OptionTag, value: u8) FloError!void {
        try self.ensureCapacity(3);
        self.buffer[self.offset] = @intFromEnum(tag);
        self.buffer[self.offset + 1] = 1;
        self.buffer[self.offset + 2] = value;
        self.offset += 3;
    }

    pub fn addU32(self: *OptionsBuilder, tag: OptionTag, value: u32) FloError!void {
        if (tag == .block_ms) try types.checkBlockMs(value);
        try self.ensureCapacity(6);
        self.buffer[self.offset] = @intFromEnum(tag);
        self.buffer[self.offset + 1] = 4;
        std.mem.writeInt(u32, self.buffer[self.offset + 2 ..][0..4], value, .little);
        self.offset += 6;
    }

    pub fn addU64(self: *OptionsBuilder, tag: OptionTag, value: u64) FloError!void {
        try self.ensureCapacity(10);
        self.buffer[self.offset] = @intFromEnum(tag);
        self.buffer[self.offset + 1] = 8;
        std.mem.writeInt(u64, self.buffer[self.offset + 2 ..][0..8], value, .little);
        self.offset += 10;
    }

    pub fn addBytes(self: *OptionsBuilder, tag: OptionTag, value: []const u8) FloError!void {
        if (value.len > 255) return FloError.OptionValueTooLarge;
        try self.ensureCapacity(2 + value.len);
        self.buffer[self.offset] = @intFromEnum(tag);
        self.buffer[self.offset + 1] = @intCast(value.len);
        @memcpy(self.buffer[self.offset + 2 ..][0..value.len], value);
        self.offset += 2 + value.len;
    }

    pub fn addFlag(self: *OptionsBuilder, tag: OptionTag) FloError!void {
        try self.ensureCapacity(2);
        self.buffer[self.offset] = @intFromEnum(tag);
        self.buffer[self.offset + 1] = 0;
        self.offset += 2;
    }

    pub fn getOptions(self: *const OptionsBuilder) []const u8 {
        return self.buffer[0..self.offset];
    }

    fn ensureCapacity(self: *OptionsBuilder, needed: usize) FloError!void {
        if (self.offset + needed > self.buffer.len) {
            return FloError.OptionsBufferTooSmall;
        }
    }
};

/// Iterator for parsing TLV options
pub const OptionsIterator = struct {
    data: []const u8,
    offset: usize = 0,

    pub fn init(data: []const u8) OptionsIterator {
        return .{ .data = data };
    }

    pub fn next(self: *OptionsIterator) ?Option {
        if (self.offset + 2 > self.data.len) return null;

        const tag: OptionTag = @enumFromInt(self.data[self.offset]);
        const len = self.data[self.offset + 1];

        if (self.offset + 2 + len > self.data.len) return null;

        const option = Option{
            .tag = tag,
            .data = self.data[self.offset + 2 ..][0..len],
        };

        self.offset += 2 + len;
        return option;
    }

    pub fn find(self: *OptionsIterator, tag: OptionTag) ?Option {
        self.offset = 0;
        while (self.next()) |opt| {
            if (opt.tag == tag) return opt;
        }
        return null;
    }
};

// =============================================================================
// Request Serialization
// =============================================================================

/// Whether `op`'s request carries a schema-coded body rather than a value
/// and options: the ops in the server's ops.json.
pub fn isTableOp(op: OpCode) bool {
    return switch (op) {
        .namespace_create, .namespace_delete, .namespace_list, .namespace_info => true,
        .kv_put, .kv_get, .kv_mget, .kv_delete, .kv_scan, .kv_history, .kv_incr, .kv_json_get, .kv_json_set, .kv_json_del, .kv_txn_begin, .kv_txn_commit, .kv_txn_rollback, .kv_expire, .kv_exists => true,
        .stream_group_list, .stream_group_members, .queue_peek, .queue_dequeue, .queue_complete, .queue_fail, .queue_touch => true,
        .action_status, .action_await, .action_complete, .action_fail, .action_touch, .action_info => true,
        .worker_list, .worker_info, .processing_remove => true,
        else => false,
    };
}

/// The size of a request's frame, header included.
pub fn requestSize(op_code: OpCode, namespace: []const u8, key: []const u8, value: []const u8, options: []const u8) usize {
    const envelope = @sizeOf(RequestHeader) + 2 + namespace.len + 2 + key.len + value.len;
    // A table op's payload is [namespace][key][body]: no value length, no options.
    return envelope + if (isTableOp(op_code)) 0 else 4 + 2 + options.len;
}

/// Serialize a request into a buffer
/// Returns the slice of the buffer containing the serialized request
pub fn serializeRequest(
    buffer: []u8,
    request_id: u64,
    op_code: OpCode,
    namespace: []const u8,
    key: []const u8,
    value: []const u8,
    options: []const u8,
) FloError![]const u8 {
    const header_size = @sizeOf(RequestHeader);

    // Validate sizes
    if (namespace.len > types.MAX_NAMESPACE_SIZE) return FloError.NamespaceTooLarge;
    if (key.len > types.MAX_KEY_SIZE) return FloError.KeyTooLarge;
    if (value.len > types.MAX_VALUE_SIZE) return FloError.ValueTooLarge;

    // A table op's payload is [namespace][key][body]: its body, coded by the
    // op's schema, is `value`, and it takes no options.
    const table = isTableOp(op_code);
    if (table and options.len > 0) return FloError.IncompleteRequest;

    const total_size = requestSize(op_code, namespace, key, value, options);
    const payload_size = total_size - header_size;

    if (buffer.len < total_size) {
        return FloError.BufferTooSmall;
    }

    // Build payload
    var payload_offset: usize = 0;
    var payload_buffer = buffer[header_size..total_size];

    // Namespace
    std.mem.writeInt(u16, payload_buffer[payload_offset..][0..2], @intCast(namespace.len), .little);
    payload_offset += 2;
    @memcpy(payload_buffer[payload_offset..][0..namespace.len], namespace);
    payload_offset += namespace.len;

    // Key
    std.mem.writeInt(u16, payload_buffer[payload_offset..][0..2], @intCast(key.len), .little);
    payload_offset += 2;
    @memcpy(payload_buffer[payload_offset..][0..key.len], key);
    payload_offset += key.len;

    if (table) {
        @memcpy(payload_buffer[payload_offset..][0..value.len], value);
        payload_offset += value.len;
    } else {
        // Value
        std.mem.writeInt(u32, payload_buffer[payload_offset..][0..4], @intCast(value.len), .little);
        payload_offset += 4;
        if (value.len > 0) {
            @memcpy(payload_buffer[payload_offset..][0..value.len], value);
            payload_offset += value.len;
        }

        // Options
        std.mem.writeInt(u16, payload_buffer[payload_offset..][0..2], @intCast(options.len), .little);
        payload_offset += 2;
        if (options.len > 0) {
            @memcpy(payload_buffer[payload_offset..][0..options.len], options);
            payload_offset += options.len;
        }
    }

    // Build header
    var header = RequestHeader{
        .magic = types.MAGIC,
        .payload_length = @intCast(payload_size),
        .request_id = request_id,
        .crc32c = 0,
        .op_code = @intFromEnum(op_code),
        .version = types.VERSION,
        .flags = 0,
        .table_hash = types.TABLE_HASH,
    };

    header.crc32c = header.computeCRC32C(payload_buffer[0..payload_offset]);

    // Write header
    @memcpy(buffer[0..header_size], std.mem.asBytes(&header));

    return buffer[0..total_size];
}

// =============================================================================
// Response Parsing
// =============================================================================

/// Raw response from server
/// Response flag: the answer reads state that lacks what was written since:
/// a halted shard's, or a node's whose log reads are blocked.
pub const RESPONSE_STALE: u8 = 0x01;

pub const RawResponse = struct {
    status: StatusCode,
    /// The answer carries RESPONSE_STALE: a successful read (or not-found)
    /// from a halted shard or a read-blocked node.
    stale: bool = false,
    data: []const u8,
    allocator: Allocator,

    pub fn deinit(self: *RawResponse) void {
        if (self.data.len > 0) {
            self.allocator.free(@constCast(self.data));
        }
    }

    pub fn isOk(self: RawResponse) bool {
        return self.status == .ok;
    }

    pub fn isNotFound(self: RawResponse) bool {
        return self.status == .not_found;
    }
};

/// Encode the request value every list/scan op reads: [limit:u32][cursor].
/// limit 0 asks for the server default; cursor is the opaque bytes the
/// previous page returned (empty for the first page). Caller frees.
pub fn encodeListValue(allocator: Allocator, limit: u32, cursor: []const u8) FloError![]u8 {
    const buf = try allocator.alloc(u8, 4 + cursor.len);
    std.mem.writeInt(u32, buf[0..4], limit, .little);
    @memcpy(buf[4..], cursor);
    return buf;
}

/// The trailer every list/scan answer ends with: [has_more:u8][cursor_len:u16][cursor].
pub const ListTrailer = struct {
    has_more: bool,
    /// Borrowed from the response data; null when there is no next page.
    cursor: ?[]const u8,
};

/// The trailer ends the answer: bytes after it are refused, as is a cursor
/// that contradicts has_more. A next page with no cursor can't be asked for,
/// and a cursor on the last page means the answer is misread.
pub fn parseListTrailer(data: []const u8, offset: usize) FloError!ListTrailer {
    if (data.len < offset + 3) return FloError.IncompleteResponse;
    const has_more = data[offset] != 0;
    const cursor_len = std.mem.readInt(u16, data[offset + 1 ..][0..2], .little);
    const start = offset + 3;
    if (data.len < start + cursor_len) return FloError.IncompleteResponse;
    if (data.len != start + cursor_len) return FloError.UnexpectedResponse;
    if (has_more != (cursor_len > 0)) return FloError.UnexpectedResponse;
    return .{
        .has_more = has_more,
        .cursor = if (cursor_len > 0) data[start..][0..cursor_len] else null,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "OptionsBuilder and Iterator roundtrip" {
    var buffer: [64]u8 = undefined;
    var builder = OptionsBuilder.init(&buffer);

    try builder.addU64(.max_age_seconds, 3_600_000);
    try builder.addU8(.priority, 5);
    try builder.addBytes(.partition_key, "abc123");

    const options = builder.getOptions();

    var iter = OptionsIterator.init(options);

    const age_opt = iter.next().?;
    try std.testing.expectEqual(OptionTag.max_age_seconds, age_opt.tag);
    try std.testing.expectEqual(@as(u64, 3_600_000), age_opt.asU64().?);

    const priority_opt = iter.next().?;
    try std.testing.expectEqual(OptionTag.priority, priority_opt.tag);
    try std.testing.expectEqual(@as(u8, 5), priority_opt.asU8().?);

    const pkey_opt = iter.next().?;
    try std.testing.expectEqual(OptionTag.partition_key, pkey_opt.tag);
    try std.testing.expectEqualStrings("abc123", pkey_opt.asString());

    try std.testing.expect(iter.next() == null);
}

test "a frame's checksum is CRC32C over the header without its crc32c field, then the body" {
    // The frame flo checks its own checksum against.
    const frame = "\x46\x4c\x4f\x00\x05\x00\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00" ++
        "\x00\x00\x00\x00" ++ "\x01\x01\x03\x00\x08\x07\x06\x05\x04\x03\x02\x01";
    const header = @as(*align(1) const RequestHeader, @ptrCast(frame)).*;
    try std.testing.expectEqual(@as(u32, 0xa2996e56), header.computeCRC32C("hello"));
    const answer = @as(*align(1) const ResponseHeader, @ptrCast(frame)).*;
    try std.testing.expectEqual(@as(u32, 0xa2996e56), answer.computeCRC32C("hello"));
    try std.testing.expectEqual(@as(u32, 0xe3069283), std.hash.crc.Crc32Iscsi.hash("123456789"));
}

test "serializeRequest basic" {
    var buffer: [256]u8 = undefined;

    const serialized = try serializeRequest(
        &buffer,
        42,
        .kv_get,
        "test",
        "mykey",
        "",
        "",
    );

    try std.testing.expect(serialized.len > 32);

    // Verify header
    const header = @as(*align(1) const RequestHeader, @ptrCast(serialized.ptr)).*;
    try std.testing.expectEqual(types.MAGIC, header.magic);
    try std.testing.expectEqual(types.VERSION, header.version);
    try std.testing.expectEqual(@as(u64, 0xc1f93eb0ed86a281), header.table_hash);
    try std.testing.expectEqual(@as(u64, 42), header.request_id);
}

test "a table op's frame is the envelope and its body: no value length, no options" {
    var buffer: [128]u8 = undefined;
    // worker.list: {limit: 1024, cursor: ""}.
    const body = "\x01\x00\x04\x00\x00\x00\x00";
    const frame = try serializeRequest(&buffer, 1, .worker_list, "ns", "", body, "");
    try std.testing.expectEqualSlices(u8, "\x02\x00ns" ++ "\x00\x00" ++ body, frame[32..]);
    try std.testing.expectError(FloError.IncompleteRequest, serializeRequest(&buffer, 1, .worker_list, "ns", "", body, "x"));
}

test "OptionsBuilder refuses a blocking wait over 300000 ms" {
    var buffer: [64]u8 = undefined;
    var builder = OptionsBuilder.init(&buffer);

    try builder.addU32(.block_ms, 0);
    try builder.addU32(.block_ms, types.MAX_BLOCK_MS);
    try std.testing.expectError(FloError.BlockTooLong, builder.addU32(.block_ms, types.MAX_BLOCK_MS + 1));
    // Other u32 options are not blocking waits.
    try builder.addU32(.count, types.MAX_BLOCK_MS + 1);
}

test "parseListTrailer reads has_more and the cursor that ends the answer" {
    const page = try parseListTrailer(&.{ 9, 1, 2, 0, 'c', '1' }, 1);
    try std.testing.expect(page.has_more);
    try std.testing.expectEqualStrings("c1", page.cursor.?);
    const last = try parseListTrailer(&.{ 0, 0, 0 }, 0);
    try std.testing.expect(!last.has_more);
    try std.testing.expect(last.cursor == null);
}

test "parseListTrailer refuses bytes after the cursor" {
    try std.testing.expectError(FloError.UnexpectedResponse, parseListTrailer(&.{ 1, 1, 0, 'c', 'x' }, 0));
    try std.testing.expectError(FloError.UnexpectedResponse, parseListTrailer(&.{ 0, 0, 0, 0 }, 0));
}

test "parseListTrailer refuses a cursor that contradicts has_more" {
    // has_more=0 with a cursor.
    try std.testing.expectError(FloError.UnexpectedResponse, parseListTrailer(&.{ 0, 1, 0, 'c' }, 0));
    // has_more=1 with no cursor.
    try std.testing.expectError(FloError.UnexpectedResponse, parseListTrailer(&.{ 1, 0, 0 }, 0));
}
