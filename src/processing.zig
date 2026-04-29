//! Flo Processing Operations
//!
//! Stream processing job management: submit, status, list, stop, cancel,
//! savepoint, restore, rescale.
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
const Client = @import("client.zig").Client;

const FloError = types.FloError;
const Allocator = std.mem.Allocator;

fn mapStatusToError(status: types.StatusCode) FloError {
    return switch (status) {
        .not_found => FloError.NotFound,
        .bad_request => FloError.BadRequest,
        .conflict => FloError.Conflict,
        .unauthorized => FloError.Unauthorized,
        .overloaded => FloError.Overloaded,
        .rate_limited => FloError.RateLimited,
        .internal_error => FloError.InternalError,
        else => FloError.UnexpectedResponse,
    };
}

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
            return mapStatusToError(response.status);
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
            return mapStatusToError(response.status);
        }

        return parseProcessingStatus(allocator, response.data) catch return FloError.UnexpectedResponse;
    }

    /// List processing jobs.
    /// Caller owns the result; call deinit() when done.
    pub fn list(
        self: *Self,
        allocator: Allocator,
        options: types.ProcessingListOptions,
    ) FloError!types.ProcessingListResult {
        const ns = self.client.getNamespace(options.namespace);

        // Wire format: [limit:u32][cursor...]
        const cursor = options.cursor orelse &[_]u8{};
        var value_buf: [4 + 64]u8 = undefined;
        std.mem.writeInt(u32, value_buf[0..4], options.limit, .little);
        if (cursor.len > 0) {
            const copy_len = @min(cursor.len, value_buf.len - 4);
            @memcpy(value_buf[4 .. 4 + copy_len], cursor[0..copy_len]);
        }
        const value_len = 4 + @min(cursor.len, value_buf.len - 4);

        var response = try self.client.sendRequest(
            .processing_list,
            ns,
            "",
            value_buf[0..value_len],
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }

        return parseProcessingList(allocator, response.data) catch return FloError.UnexpectedResponse;
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
            return mapStatusToError(response.status);
        }
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
            return mapStatusToError(response.status);
        }
    }

    /// Trigger a savepoint for a processing job.
    /// Returns the savepoint ID (caller owns the slice).
    pub fn savepoint(
        self: *Self,
        allocator: Allocator,
        job_id: []const u8,
        options: types.ProcessingSavepointOptions,
    ) FloError![]u8 {
        const ns = self.client.getNamespace(options.namespace);

        var response = try self.client.sendRequest(
            .processing_savepoint,
            ns,
            job_id,
            "",
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }

        return allocator.dupe(u8, response.data) catch return FloError.OutOfMemory;
    }

    /// Restore a processing job from a savepoint.
    pub fn restore(
        self: *Self,
        job_id: []const u8,
        savepoint_id: []const u8,
        options: types.ProcessingRestoreOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var response = try self.client.sendRequest(
            .processing_restore,
            ns,
            job_id,
            savepoint_id,
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
    }

    /// Change the parallelism of a processing job.
    pub fn rescale(
        self: *Self,
        job_id: []const u8,
        parallelism: u32,
        options: types.ProcessingRescaleOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var value_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &value_buf, parallelism, .little);

        var response = try self.client.sendRequest(
            .processing_rescale,
            ns,
            job_id,
            &value_buf,
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
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

/// Parse the binary wire format for processing job status.
///
/// Wire format: [job_id_len:u16][job_id][name_len:u16][name][status:u8]
///              [parallelism:u32][batch_size:u32][records_processed:u64][created_at:i64]
fn parseProcessingStatus(allocator: Allocator, data: []const u8) !types.ProcessingStatusResult {
    var pos: usize = 0;

    // Read job_id
    if (pos + 2 > data.len) return error.UnexpectedEndOfData;
    const job_id_len = std.mem.readInt(u16, data[pos..][0..2], .little);
    pos += 2;
    if (pos + job_id_len > data.len) return error.UnexpectedEndOfData;
    const job_id = try allocator.dupe(u8, data[pos .. pos + job_id_len]);
    errdefer allocator.free(job_id);
    pos += job_id_len;

    // Read name
    if (pos + 2 > data.len) return error.UnexpectedEndOfData;
    const name_len = std.mem.readInt(u16, data[pos..][0..2], .little);
    pos += 2;
    if (pos + name_len > data.len) return error.UnexpectedEndOfData;
    const name = try allocator.dupe(u8, data[pos .. pos + name_len]);
    errdefer allocator.free(name);
    pos += name_len;

    // Read status byte
    if (pos >= data.len) return error.UnexpectedEndOfData;
    const status_byte = data[pos];
    pos += 1;
    const status_str = if (status_byte < processing_status_names.len)
        processing_status_names[status_byte]
    else
        "unknown";
    const status_owned = try allocator.dupe(u8, status_str);
    errdefer allocator.free(status_owned);

    // Read parallelism (u32)
    if (pos + 4 > data.len) return error.UnexpectedEndOfData;
    const parallelism = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;

    // Read batch_size (u32)
    if (pos + 4 > data.len) return error.UnexpectedEndOfData;
    const batch_size = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;

    // Read records_processed (u64)
    if (pos + 8 > data.len) return error.UnexpectedEndOfData;
    const records_processed = std.mem.readInt(u64, data[pos..][0..8], .little);
    pos += 8;

    // Read created_at (i64)
    if (pos + 8 > data.len) return error.UnexpectedEndOfData;
    const created_at = std.mem.readInt(i64, data[pos..][0..8], .little);

    return .{
        .job_id = job_id,
        .name = name,
        .status = status_owned,
        .parallelism = parallelism,
        .batch_size = batch_size,
        .records_processed = records_processed,
        .created_at = created_at,
        .allocator = allocator,
    };
}

/// Parse the binary wire format for processing job list.
///
/// Wire format: [count:u32]([name_len:u16][name][job_id_len:u16][job_id]
///              [status_len:u16][status][parallelism:u32][created_at:i64])*
fn parseProcessingList(allocator: Allocator, data: []const u8) !types.ProcessingListResult {
    if (data.len < 4) return error.UnexpectedEndOfData;

    var pos: usize = 0;
    const count = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;

    var entries = try allocator.alloc(types.ProcessingListEntry, count);
    errdefer {
        for (entries[0..count]) |*e| {
            e.deinit(allocator);
        }
        allocator.free(entries);
    }

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // Read name
        if (pos + 2 > data.len) return error.UnexpectedEndOfData;
        const name_len = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;
        if (pos + name_len > data.len) return error.UnexpectedEndOfData;
        const name = try allocator.dupe(u8, data[pos .. pos + name_len]);
        errdefer allocator.free(name);
        pos += name_len;

        // Read job_id
        if (pos + 2 > data.len) return error.UnexpectedEndOfData;
        const jid_len = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;
        if (pos + jid_len > data.len) return error.UnexpectedEndOfData;
        const job_id = try allocator.dupe(u8, data[pos .. pos + jid_len]);
        errdefer allocator.free(job_id);
        pos += jid_len;

        // Read status
        if (pos + 2 > data.len) return error.UnexpectedEndOfData;
        const status_len = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;
        if (pos + status_len > data.len) return error.UnexpectedEndOfData;
        const status_str = try allocator.dupe(u8, data[pos .. pos + status_len]);
        errdefer allocator.free(status_str);
        pos += status_len;

        // Read parallelism (u32)
        if (pos + 4 > data.len) return error.UnexpectedEndOfData;
        const parallelism = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        // Read created_at (i64)
        if (pos + 8 > data.len) return error.UnexpectedEndOfData;
        const created_at = std.mem.readInt(i64, data[pos..][0..8], .little);
        pos += 8;

        entries[i] = .{
            .name = name,
            .job_id = job_id,
            .status = status_str,
            .parallelism = parallelism,
            .created_at = created_at,
        };
    }

    return .{
        .entries = entries,
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

// =============================================================================
// Tests
// =============================================================================

test "extractYamlName" {
    try std.testing.expectEqualStrings("my-job", extractYamlName("name: my-job\ntype: stream").?);
    try std.testing.expectEqualStrings("quoted", extractYamlName("name: \"quoted\"\n").?);
    try std.testing.expectEqualStrings("test", extractYamlName("  name: test").?);
    try std.testing.expect(extractYamlName("type: stream\nversion: 1") == null);
}
