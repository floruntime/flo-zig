//! Flo Wire Protocol
//!
//! Binary serialization/deserialization for the Flo protocol.
//! Header: 24 bytes, little-endian, CRC32 validated.

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

/// Request header (24 bytes)
pub const RequestHeader = extern struct {
    magic: u32,
    payload_length: u32,
    request_id: u64,
    crc32: u32,
    version: u8,
    op_code: u8,
    flags: u8,
    reserved: u8,

    pub fn validate(self: RequestHeader) FloError!void {
        if (self.magic != types.MAGIC) {
            return FloError.InvalidMagic;
        }
        if (self.version != types.VERSION) {
            return FloError.UnsupportedVersion;
        }
        if (self.reserved != 0) {
            return FloError.InvalidReservedField;
        }
        if (self.payload_length > 100 * 1024 * 1024) {
            return FloError.PayloadTooLarge;
        }
    }

    /// Compute CRC32 for header (excluding crc32 field) + payload
    pub fn computeCRC32(self: RequestHeader, payload: []const u8) u32 {
        var hasher = std.hash.Crc32.init();
        const header_bytes = std.mem.asBytes(&self);
        hasher.update(header_bytes[0..16]);
        hasher.update(header_bytes[20..24]);
        hasher.update(payload);
        return hasher.final();
    }
};

/// Response header (24 bytes)
pub const ResponseHeader = extern struct {
    magic: u32,
    data_len: u32,
    request_id: u64,
    crc32: u32,
    version: u8,
    status: u8,
    flags: u8,
    reserved: u8,

    pub fn validate(self: ResponseHeader) FloError!void {
        if (self.magic != types.MAGIC) {
            return FloError.InvalidMagic;
        }
        if (self.version != types.VERSION) {
            return FloError.UnsupportedVersion;
        }
    }

    pub fn computeCRC32(self: ResponseHeader, data: []const u8) u32 {
        var hasher = std.hash.Crc32.init();
        const header_bytes = std.mem.asBytes(&self);
        hasher.update(header_bytes[0..16]);
        hasher.update(header_bytes[20..24]);
        hasher.update(data);
        return hasher.final();
    }

    pub fn getStatus(self: ResponseHeader) StatusCode {
        return @enumFromInt(self.status);
    }
};

comptime {
    if (@sizeOf(RequestHeader) != 24) {
        @compileError("RequestHeader must be exactly 24 bytes");
    }
    if (@sizeOf(ResponseHeader) != 24) {
        @compileError("ResponseHeader must be exactly 24 bytes");
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

    // Calculate payload size
    const payload_size = 2 + namespace.len + 2 + key.len + 4 + value.len + 2 + options.len;
    const total_size = header_size + payload_size;

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

    // Build header
    var header = RequestHeader{
        .magic = types.MAGIC,
        .payload_length = @intCast(payload_size),
        .request_id = request_id,
        .crc32 = 0,
        .version = types.VERSION,
        .op_code = @intFromEnum(op_code),
        .flags = 0,
        .reserved = 0,
    };

    // Compute CRC32
    header.crc32 = header.computeCRC32(payload_buffer[0..payload_offset]);

    // Write header
    @memcpy(buffer[0..header_size], std.mem.asBytes(&header));

    return buffer[0..total_size];
}

// =============================================================================
// Response Parsing
// =============================================================================

/// Raw response from server
pub const RawResponse = struct {
    status: StatusCode,
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

/// Parse a scan response
/// Format: [has_more:u8][cursor_len:u32][cursor:bytes][count:u32][entries...]
/// Entry format: [key_len:u16][key][value_len:u32][value]
pub fn parseScanResponse(allocator: Allocator, data: []const u8) !types.ScanResult {
    if (data.len < 9) return FloError.IncompleteResponse;

    var offset: usize = 0;

    // has_more
    const has_more = data[offset] != 0;
    offset += 1;

    // cursor
    const cursor_len = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;

    if (data.len < offset + cursor_len) return FloError.IncompleteResponse;
    const cursor_data = if (cursor_len > 0) data[offset..][0..cursor_len] else null;
    offset += cursor_len;

    // count
    if (data.len < offset + 4) return FloError.IncompleteResponse;
    const count = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;

    // Allocate entries
    var entries = try allocator.alloc(types.KVEntry, count);
    errdefer {
        for (entries) |*e| {
            e.deinit(allocator);
        }
        allocator.free(entries);
    }

    // Parse entries
    var i: usize = 0;
    while (i < count) : (i += 1) {
        // Key
        if (data.len < offset + 2) return FloError.IncompleteResponse;
        const key_len = std.mem.readInt(u16, data[offset..][0..2], .little);
        offset += 2;

        if (data.len < offset + key_len) return FloError.IncompleteResponse;
        const key = try allocator.dupe(u8, data[offset..][0..key_len]);
        offset += key_len;

        // Value
        if (data.len < offset + 4) return FloError.IncompleteResponse;
        const value_len = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;

        const value = if (value_len > 0) blk: {
            if (data.len < offset + value_len) return FloError.IncompleteResponse;
            const v = try allocator.dupe(u8, data[offset..][0..value_len]);
            offset += value_len;
            break :blk v;
        } else null;

        entries[i] = .{ .key = key, .value = value };
    }

    // Copy cursor if present
    const cursor = if (cursor_data) |c| try allocator.dupe(u8, c) else null;

    return types.ScanResult{
        .entries = entries,
        .cursor = cursor,
        .has_more = has_more,
        .allocator = allocator,
    };
}

/// Parse a dequeue response
/// Format: [count:u32][messages...]
/// Message format: [seq:u64][payload_len:u32][payload]
pub fn parseDequeueResponse(allocator: Allocator, data: []const u8) !types.DequeueResult {
    if (data.len < 4) return FloError.IncompleteResponse;

    var offset: usize = 0;

    const count = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;

    var messages = try allocator.alloc(types.Message, count);
    errdefer {
        for (messages) |*m| {
            m.deinit(allocator);
        }
        allocator.free(messages);
    }

    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (data.len < offset + 12) return FloError.IncompleteResponse;

        const seq = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;

        const payload_len = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;

        if (data.len < offset + payload_len) return FloError.IncompleteResponse;
        const payload = try allocator.dupe(u8, data[offset..][0..payload_len]);
        offset += payload_len;

        messages[i] = .{ .seq = seq, .payload = payload };
    }

    return types.DequeueResult{
        .messages = messages,
        .allocator = allocator,
    };
}

/// Serialize sequence numbers for ack/nack
/// Format: [count:u32][seq:u64]*
pub fn serializeSeqs(buffer: []u8, seqs: []const u64) FloError![]const u8 {
    const needed = 4 + seqs.len * 8;
    if (buffer.len < needed) return FloError.BufferTooSmall;

    var offset: usize = 0;
    std.mem.writeInt(u32, buffer[offset..][0..4], @intCast(seqs.len), .little);
    offset += 4;

    for (seqs) |seq| {
        std.mem.writeInt(u64, buffer[offset..][0..8], seq, .little);
        offset += 8;
    }

    return buffer[0..offset];
}

// =============================================================================
// Tests
// =============================================================================

test "OptionsBuilder and Iterator roundtrip" {
    var buffer: [64]u8 = undefined;
    var builder = OptionsBuilder.init(&buffer);

    try builder.addU64(.ttl_seconds, 3600);
    try builder.addU8(.priority, 5);
    try builder.addBytes(.dedup_key, "abc123");

    const options = builder.getOptions();

    var iter = OptionsIterator.init(options);

    const ttl_opt = iter.next().?;
    try std.testing.expectEqual(OptionTag.ttl_seconds, ttl_opt.tag);
    try std.testing.expectEqual(@as(u64, 3600), ttl_opt.asU64().?);

    const priority_opt = iter.next().?;
    try std.testing.expectEqual(OptionTag.priority, priority_opt.tag);
    try std.testing.expectEqual(@as(u8, 5), priority_opt.asU8().?);

    const dedup_opt = iter.next().?;
    try std.testing.expectEqual(OptionTag.dedup_key, dedup_opt.tag);
    try std.testing.expectEqualStrings("abc123", dedup_opt.asString());

    try std.testing.expect(iter.next() == null);
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

    try std.testing.expect(serialized.len > 24);

    // Verify header
    const header = @as(*align(1) const RequestHeader, @ptrCast(serialized.ptr)).*;
    try std.testing.expectEqual(types.MAGIC, header.magic);
    try std.testing.expectEqual(types.VERSION, header.version);
    try std.testing.expectEqual(@as(u64, 42), header.request_id);
}

test "serializeSeqs" {
    var buffer: [64]u8 = undefined;
    const seqs = [_]u64{ 1, 2, 3 };

    const serialized = try serializeSeqs(&buffer, &seqs);

    try std.testing.expectEqual(@as(usize, 28), serialized.len);

    const count = std.mem.readInt(u32, serialized[0..4], .little);
    try std.testing.expectEqual(@as(u32, 3), count);
}
