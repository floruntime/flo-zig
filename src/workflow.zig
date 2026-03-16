//! Flo Workflow Operations
//!
//! Workflow operations: create, start, signal, cancel, status, history,
//! list runs, list definitions, disable, enable, sync.
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
//! var workflow = flo.Workflow.init(&client);
//!
//! // Create workflow from YAML
//! try workflow.create("my-workflow", yaml_bytes, .{});
//!
//! // Start a run
//! const run_id = try workflow.start("my-workflow", input_json, .{});
//! defer allocator.free(run_id);
//!
//! // Get status
//! const status = try workflow.status(run_id, .{});
//! defer allocator.free(status);
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

const status_names = [_][]const u8{
    "pending", "running", "waiting", "completed", "failed", "cancelled", "timed_out",
};

fn parseWorkflowStatus(allocator: Allocator, data: []const u8) !types.WorkflowStatusResult {
    var pos: usize = 0;

    // Read run_id
    if (pos + 2 > data.len) return error.UnexpectedEndOfData;
    const run_id_len = std.mem.readInt(u16, data[pos..][0..2], .little);
    pos += 2;
    if (pos + run_id_len > data.len) return error.UnexpectedEndOfData;
    const parsed_run_id = try allocator.dupe(u8, data[pos .. pos + run_id_len]);
    errdefer allocator.free(parsed_run_id);
    pos += run_id_len;

    // Read workflow
    if (pos + 2 > data.len) return error.UnexpectedEndOfData;
    const workflow_len = std.mem.readInt(u16, data[pos..][0..2], .little);
    pos += 2;
    if (pos + workflow_len > data.len) return error.UnexpectedEndOfData;
    const workflow = try allocator.dupe(u8, data[pos .. pos + workflow_len]);
    errdefer allocator.free(workflow);
    pos += workflow_len;

    // Read version
    if (pos + 2 > data.len) return error.UnexpectedEndOfData;
    const version_len = std.mem.readInt(u16, data[pos..][0..2], .little);
    pos += 2;
    if (pos + version_len > data.len) return error.UnexpectedEndOfData;
    const version = try allocator.dupe(u8, data[pos .. pos + version_len]);
    errdefer allocator.free(version);
    pos += version_len;

    // Read status byte
    if (pos >= data.len) return error.UnexpectedEndOfData;
    const status_byte = data[pos];
    pos += 1;
    const status_str = if (status_byte < status_names.len) status_names[status_byte] else "unknown";
    const status_owned = try allocator.dupe(u8, status_str);
    errdefer allocator.free(status_owned);

    // Read current_step
    if (pos + 2 > data.len) return error.UnexpectedEndOfData;
    const step_len = std.mem.readInt(u16, data[pos..][0..2], .little);
    pos += 2;
    if (pos + step_len > data.len) return error.UnexpectedEndOfData;
    const current_step = try allocator.dupe(u8, data[pos .. pos + step_len]);
    errdefer allocator.free(current_step);
    pos += step_len;

    // Read input (u32 length)
    if (pos + 4 > data.len) return error.UnexpectedEndOfData;
    const input_len = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;
    if (pos + input_len > data.len) return error.UnexpectedEndOfData;
    const input = try allocator.dupe(u8, data[pos .. pos + input_len]);
    errdefer allocator.free(input);
    pos += input_len;

    // Read created_at (i64)
    if (pos + 8 > data.len) return error.UnexpectedEndOfData;
    const created_at = std.mem.readInt(i64, data[pos..][0..8], .little);
    pos += 8;

    var result = types.WorkflowStatusResult{
        .run_id = parsed_run_id,
        .workflow = workflow,
        .version = version,
        .status = status_owned,
        .current_step = current_step,
        .input = input,
        .created_at = created_at,
    };

    // Optional: started_at
    if (pos < data.len and data[pos] == 1) {
        pos += 1;
        if (pos + 8 > data.len) return error.UnexpectedEndOfData;
        result.started_at = std.mem.readInt(i64, data[pos..][0..8], .little);
        pos += 8;
    } else if (pos < data.len) {
        pos += 1;
    }

    // Optional: completed_at
    if (pos < data.len and data[pos] == 1) {
        pos += 1;
        if (pos + 8 > data.len) return error.UnexpectedEndOfData;
        result.completed_at = std.mem.readInt(i64, data[pos..][0..8], .little);
        pos += 8;
    } else if (pos < data.len) {
        pos += 1;
    }

    // Optional: wait_signal
    if (pos < data.len and data[pos] == 1) {
        pos += 1;
        if (pos + 2 > data.len) return error.UnexpectedEndOfData;
        const ws_len = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;
        if (pos + ws_len > data.len) return error.UnexpectedEndOfData;
        result.wait_signal = try allocator.dupe(u8, data[pos .. pos + ws_len]);
    }

    return result;
}

/// Workflow operations for the Flo client.
pub const Workflow = struct {
    client: *Client,

    const Self = @This();

    pub fn init(client: *Client) Workflow {
        return .{ .client = client };
    }

    // =========================================================================
    // Core Operations
    // =========================================================================

    /// Create (or replace) a workflow from a YAML definition.
    pub fn create(
        self: *Self,
        name: []const u8,
        yaml: []const u8,
        options: types.WorkflowCreateOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var response = try self.client.sendRequest(
            .workflow_create,
            ns,
            name,
            yaml,
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
    }

    /// Get the YAML definition of a workflow. Returns null if not found.
    /// Caller owns the returned slice.
    pub fn getDefinition(
        self: *Self,
        allocator: Allocator,
        name: []const u8,
        options: types.WorkflowGetDefinitionOptions,
    ) FloError!?[]u8 {
        const ns = self.client.getNamespace(options.namespace);

        const value = options.version orelse "";

        var response = try self.client.sendRequest(
            .workflow_get_definition,
            ns,
            name,
            value,
            "",
        );
        defer response.deinit();

        if (response.status == .not_found) {
            return null;
        }

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }

        return allocator.dupe(u8, response.data) catch return FloError.OutOfMemory;
    }

    /// Start a workflow run. Returns the run ID (caller owns the slice).
    pub fn start(
        self: *Self,
        allocator: Allocator,
        name: []const u8,
        input_data: ?[]const u8,
        options: types.WorkflowStartOptions,
    ) FloError![]u8 {
        const ns = self.client.getNamespace(options.namespace);
        const input = input_data orelse "";

        // Wire format: [ver_len:u16][ver]?[has_idem:u8][idem_len:u16]?[idem]?
        //              [has_rid:u8][rid_len:u16]?[rid]?[input...]
        var value_buf: [8192]u8 = undefined;
        var offset: usize = 0;

        // Version prefix
        if (options.version) |ver| {
            std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(ver.len), .little);
            offset += 2;
            @memcpy(value_buf[offset..][0..ver.len], ver);
            offset += ver.len;
        } else {
            std.mem.writeInt(u16, value_buf[offset..][0..2], 0, .little);
            offset += 2;
        }

        // Idempotency key
        if (options.idempotency_key) |idem| {
            value_buf[offset] = 1;
            offset += 1;
            std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(idem.len), .little);
            offset += 2;
            @memcpy(value_buf[offset..][0..idem.len], idem);
            offset += idem.len;
        } else {
            value_buf[offset] = 0;
            offset += 1;
        }

        // Explicit run ID
        if (options.run_id) |rid| {
            value_buf[offset] = 1;
            offset += 1;
            std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(rid.len), .little);
            offset += 2;
            @memcpy(value_buf[offset..][0..rid.len], rid);
            offset += rid.len;
        } else {
            value_buf[offset] = 0;
            offset += 1;
        }

        // Input payload
        @memcpy(value_buf[offset..][0..input.len], input);
        offset += input.len;

        var response = try self.client.sendRequest(
            .workflow_start,
            ns,
            name,
            value_buf[0..offset],
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }

        return allocator.dupe(u8, response.data) catch return FloError.OutOfMemory;
    }

    /// Get the status of a workflow run. Returns parsed status result (caller owns, call deinit).
    pub fn status(
        self: *Self,
        allocator: Allocator,
        run_id: []const u8,
        options: types.WorkflowStatusOptions,
    ) FloError!types.WorkflowStatusResult {
        const ns = self.client.getNamespace(options.namespace);

        var response = try self.client.sendRequest(
            .workflow_status,
            ns,
            run_id,
            "",
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }

        return parseWorkflowStatus(allocator, response.data) catch return FloError.UnexpectedResponse;
    }

    /// Send a signal to a running workflow.
    pub fn signal(
        self: *Self,
        run_id: []const u8,
        signal_name: []const u8,
        data: ?[]const u8,
        options: types.WorkflowSignalOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);
        const payload = data orelse "";

        // Value format: [signal_name_len:u16][signal_name][data...]
        var value_buf: [4096]u8 = undefined;
        var offset: usize = 0;

        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(signal_name.len), .little);
        offset += 2;
        @memcpy(value_buf[offset..][0..signal_name.len], signal_name);
        offset += signal_name.len;
        @memcpy(value_buf[offset..][0..payload.len], payload);
        offset += payload.len;

        var response = try self.client.sendRequest(
            .workflow_signal,
            ns,
            run_id,
            value_buf[0..offset],
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
    }

    /// Cancel a running workflow.
    pub fn cancel(
        self: *Self,
        run_id: []const u8,
        reason: ?[]const u8,
        options: types.WorkflowCancelOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var response = try self.client.sendRequest(
            .workflow_cancel,
            ns,
            run_id,
            reason orelse "",
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
    }

    /// Get the execution history of a workflow run.
    /// Returns raw response bytes (caller owns).
    pub fn history(
        self: *Self,
        allocator: Allocator,
        run_id: []const u8,
        options: types.WorkflowHistoryOptions,
    ) FloError![]u8 {
        const ns = self.client.getNamespace(options.namespace);

        var value_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &value_buf, options.limit, .little);

        var response = try self.client.sendRequest(
            .workflow_history,
            ns,
            run_id,
            &value_buf,
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }

        return allocator.dupe(u8, response.data) catch return FloError.OutOfMemory;
    }

    /// List workflow runs. Returns raw response bytes (caller owns).
    pub fn listRuns(
        self: *Self,
        allocator: Allocator,
        options: types.WorkflowListRunsOptions,
    ) FloError![]u8 {
        const ns = self.client.getNamespace(options.namespace);
        const key = options.workflow_name orelse "";

        // Value: [limit:u32][status_len:u16][status]?
        var value_buf: [512]u8 = undefined;
        var offset: usize = 0;

        std.mem.writeInt(u32, value_buf[offset..][0..4], options.limit, .little);
        offset += 4;

        if (options.status_filter) |sf| {
            std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(sf.len), .little);
            offset += 2;
            @memcpy(value_buf[offset..][0..sf.len], sf);
            offset += sf.len;
        } else {
            std.mem.writeInt(u16, value_buf[offset..][0..2], 0, .little);
            offset += 2;
        }

        var response = try self.client.sendRequest(
            .workflow_list_runs,
            ns,
            key,
            value_buf[0..offset],
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }

        return allocator.dupe(u8, response.data) catch return FloError.OutOfMemory;
    }

    /// List workflow definitions. Returns raw response bytes (caller owns).
    pub fn listDefinitions(
        self: *Self,
        allocator: Allocator,
        options: types.WorkflowListDefinitionsOptions,
    ) FloError![]u8 {
        const ns = self.client.getNamespace(options.namespace);

        var value_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &value_buf, options.limit, .little);

        var response = try self.client.sendRequest(
            .workflow_list_definitions,
            ns,
            "",
            &value_buf,
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }

        return allocator.dupe(u8, response.data) catch return FloError.OutOfMemory;
    }

    /// Disable a workflow definition (prevents new runs).
    pub fn disable(
        self: *Self,
        name: []const u8,
        options: types.WorkflowDisableOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var response = try self.client.sendRequest(
            .workflow_disable,
            ns,
            name,
            "",
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
    }

    /// Re-enable a disabled workflow definition.
    pub fn enable(
        self: *Self,
        name: []const u8,
        options: types.WorkflowEnableOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var response = try self.client.sendRequest(
            .workflow_enable,
            ns,
            name,
            "",
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
    }
};
