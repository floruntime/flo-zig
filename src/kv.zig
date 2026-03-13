//! Flo KV Operations
//!
//! Key-value store operations: get, put, delete, scan, history.

const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");
const Client = @import("client.zig").Client;

const Allocator = std.mem.Allocator;
const FloError = types.FloError;
const StatusCode = types.StatusCode;

/// KV operations interface
pub const KV = struct {
    client: *Client,

    pub fn init(client: *Client) KV {
        return .{ .client = client };
    }

    /// Get a value by key.
    /// Returns the value if found, null if key does not exist.
    /// Use `block_ms` for long-polling (wait for key to appear).
    /// **Caller owns the returned memory and must free it with `allocator.free()`.**
    pub fn get(self: *KV, key: []const u8, options: types.GetOptions) FloError!?[]const u8 {
        const ns = self.client.getNamespace(options.namespace);

        // Build options if block_ms is set
        var opts_buf: [16]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);

        if (options.block_ms) |block| {
            try builder.addU32(.block_ms, block);
        }

        var response = try self.client.sendRequest(.kv_get, ns, key, "", builder.getOptions());
        defer response.deinit();

        if (response.status == .not_found) {
            return null;
        }

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }

        // Copy data since response will be freed
        // Note: status == .ok with empty data means key exists with empty value
        return try self.client.allocator.dupe(u8, response.data);
    }

    /// Put a key-value pair
    pub fn put(
        self: *KV,
        key: []const u8,
        value: []const u8,
        options: types.PutOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var opts_buf: [64]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);

        if (options.ttl_seconds) |ttl| {
            try builder.addU64(.ttl_seconds, ttl);
        }
        if (options.cas_version) |version| {
            try builder.addU64(.cas_version, version);
        }
        if (options.if_not_exists) {
            try builder.addFlag(.if_not_exists);
        }
        if (options.if_exists) {
            try builder.addFlag(.if_exists);
        }

        var response = try self.client.sendRequest(
            .kv_put,
            ns,
            key,
            value,
            builder.getOptions(),
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
    }

    /// Delete a key
    pub fn delete(self: *KV, key: []const u8, options: types.DeleteOptions) FloError!void {
        const ns = self.client.getNamespace(options.namespace);
        var response = try self.client.sendRequest(.kv_delete, ns, key, "", "");
        defer response.deinit();

        if (response.status != .ok and response.status != .not_found) {
            return mapStatusToError(response.status);
        }
    }

    /// Scan keys with a prefix.
    /// **Caller owns the returned `ScanResult` and must call `result.deinit()`.**
    pub fn scan(
        self: *KV,
        prefix: []const u8,
        options: types.ScanOptions,
    ) FloError!types.ScanResult {
        const ns = self.client.getNamespace(options.namespace);

        var opts_buf: [64]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);

        if (options.limit) |limit| {
            try builder.addU32(.limit, limit);
        }
        if (options.keys_only) {
            try builder.addU8(.keys_only, 1);
        }

        var response = try self.client.sendRequest(
            .kv_scan,
            ns,
            prefix,
            options.cursor orelse "",
            builder.getOptions(),
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }

        return wire.parseScanResponse(self.client.allocator, response.data);
    }

    /// Get version history for a key.
    /// **Caller owns the returned slice and must free each entry with `entry.deinit(allocator)`,
    /// then free the slice itself with `allocator.free(entries)`.**
    pub fn history(
        self: *KV,
        key: []const u8,
        options: types.HistoryOptions,
    ) FloError![]types.VersionEntry {
        const ns = self.client.getNamespace(options.namespace);

        var opts_buf: [16]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);

        if (options.limit) |limit| {
            try builder.addU32(.limit, limit);
        }

        var response = try self.client.sendRequest(
            .kv_history,
            ns,
            key,
            "",
            builder.getOptions(),
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }

        // Parse history response
        // Format: [count:u32][entries: [version:u64][timestamp:i64][value_len:u32][value]...]
        return parseHistoryResponse(self.client.allocator, response.data);
    }
};

/// Parse history response data
fn parseHistoryResponse(allocator: Allocator, data: []const u8) FloError![]types.VersionEntry {
    if (data.len < 4) return FloError.IncompleteResponse;

    var offset: usize = 0;
    const count = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;

    var entries = allocator.alloc(types.VersionEntry, count) catch return FloError.ServerError;
    errdefer {
        for (entries) |*e| {
            e.deinit(allocator);
        }
        allocator.free(entries);
    }

    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (data.len < offset + 20) return FloError.IncompleteResponse;

        const version = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;

        const timestamp = std.mem.readInt(i64, data[offset..][0..8], .little);
        offset += 8;

        const value_len = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;

        if (data.len < offset + value_len) return FloError.IncompleteResponse;
        const value = allocator.dupe(u8, data[offset..][0..value_len]) catch return FloError.ServerError;
        offset += value_len;

        entries[i] = .{
            .version = version,
            .timestamp = timestamp,
            .value = value,
        };
    }

    return entries;
}

/// Map StatusCode to FloError
fn mapStatusToError(status: StatusCode) FloError {
    return switch (status) {
        .ok => unreachable,
        .not_found => FloError.NotFound,
        .bad_request => FloError.BadRequest,
        .conflict => FloError.Conflict,
        .unauthorized => FloError.Unauthorized,
        .overloaded => FloError.Overloaded,
        else => FloError.ServerError,
    };
}
