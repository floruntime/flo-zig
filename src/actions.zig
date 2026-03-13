//! Flo Actions - Low-Level Action/Worker Protocol
//!
//! This module provides low-level operations for actions and workers:
//! - Action registration, invocation, status checking, and deletion
//! - Worker registration, heartbeat, drain, deregistration
//! - Task awaiting, completion, failure, and touch (lease extension)
//!
//! For a higher-level API, see `Worker` in worker.zig.

const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");
const Client = @import("client.zig").Client;

const FloError = types.FloError;
const StatusCode = types.StatusCode;

/// Low-level actions and worker operations.
/// For a higher-level API, see `Worker` in worker.zig.
pub const Actions = struct {
    client: *Client,

    const Self = @This();

    pub fn init(client: *Client) Actions {
        return .{ .client = client };
    }

    // =========================================================================
    // Action Operations
    // =========================================================================

    /// Register an action (task type) that workers can process.
    /// Wire format: [action_type:u8][timeout_ms:u32][max_retries:u32]
    ///              [has_desc:u8][desc_len:u16]?[desc]?
    ///              [has_wasm_module:u8]...[has_wasm_entrypoint:u8]...[has_wasm_memory_limit:u8]...
    ///              [has_trigger_stream:u8][has_trigger_group:u8]
    pub fn registerAction(
        self: *Self,
        action_name: []const u8,
        action_type: types.ActionType,
        options: types.ActionRegisterOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var value_buf: [4096]u8 = undefined;
        var offset: usize = 0;

        // Action type
        value_buf[offset] = @intFromEnum(action_type);
        offset += 1;

        // Timeout (default 30000)
        const timeout_ms: u32 = if (options.timeout_ms) |t| @intCast(@min(t, std.math.maxInt(u32))) else 30000;
        std.mem.writeInt(u32, value_buf[offset..][0..4], timeout_ms, .little);
        offset += 4;

        // Max retries (default 3)
        const max_retries: u32 = if (options.max_retries) |r| @as(u32, r) else 3;
        std.mem.writeInt(u32, value_buf[offset..][0..4], max_retries, .little);
        offset += 4;

        // Description (optional)
        if (options.description) |desc| {
            value_buf[offset] = 1; // has_desc
            offset += 1;
            std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(desc.len), .little);
            offset += 2;
            if (desc.len > 0) {
                @memcpy(value_buf[offset..][0..desc.len], desc);
                offset += desc.len;
            }
        } else {
            value_buf[offset] = 0; // no desc
            offset += 1;
        }

        // WASM module (optional)
        if (options.wasm_module) |wasm| {
            value_buf[offset] = 1;
            offset += 1;
            std.mem.writeInt(u32, value_buf[offset..][0..4], @intCast(wasm.len), .little);
            offset += 4;
            @memcpy(value_buf[offset..][0..wasm.len], wasm);
            offset += wasm.len;
        } else {
            value_buf[offset] = 0;
            offset += 1;
        }

        // WASM entrypoint (optional)
        if (options.wasm_entrypoint) |ep| {
            value_buf[offset] = 1;
            offset += 1;
            std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(ep.len), .little);
            offset += 2;
            @memcpy(value_buf[offset..][0..ep.len], ep);
            offset += ep.len;
        } else {
            value_buf[offset] = 0;
            offset += 1;
        }

        // WASM memory limit (optional)
        if (options.memory_limit_mb) |limit| {
            value_buf[offset] = 1;
            offset += 1;
            std.mem.writeInt(u32, value_buf[offset..][0..4], limit, .little);
            offset += 4;
        } else {
            value_buf[offset] = 0;
            offset += 1;
        }

        // Trigger stream / group (not yet supported)
        value_buf[offset] = 0; // has_trigger_stream
        offset += 1;
        value_buf[offset] = 0; // has_trigger_group
        offset += 1;

        var response = try self.client.sendRequest(
            .action_register,
            ns,
            action_name,
            value_buf[0..offset],
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
    }

    /// Invoke an action (create a task for workers to process).
    /// Returns an ActionInvokeResult with run_id and optional output (for WASM actions).
    /// **Caller owns the returned `ActionInvokeResult` and must call `result.deinit()`.**
    pub fn invoke(
        self: *Self,
        action_name: []const u8,
        input: []const u8,
        options: types.ActionInvokeOptions,
    ) FloError!types.ActionInvokeResult {
        const ns = self.client.getNamespace(options.namespace);

        // Build value: [priority:u8][delay_ms:i64][has_caller:u8]
        //              [has_idempotency_key:u8][key_len:u16]?[key]?[input...]
        var value_buf: [8192]u8 = undefined;
        var offset: usize = 0;

        // Priority (default 10)
        const priority: u8 = options.priority orelse 10;
        value_buf[offset] = priority;
        offset += 1;

        // Delay (default 0)
        const delay_ms: u64 = options.delay_ms orelse 0;
        std.mem.writeInt(u64, value_buf[offset..][0..8], delay_ms, .little);
        offset += 8;

        // Caller ID (none)
        value_buf[offset] = 0;
        offset += 1;

        // Idempotency key (optional)
        if (options.idempotency_key) |key| {
            value_buf[offset] = 1;
            offset += 1;
            std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(key.len), .little);
            offset += 2;
            @memcpy(value_buf[offset..][0..key.len], key);
            offset += key.len;
        } else {
            value_buf[offset] = 0;
            offset += 1;
        }

        // Input
        @memcpy(value_buf[offset..][0..input.len], input);
        offset += input.len;

        var response = try self.client.sendRequest(
            .action_invoke,
            ns,
            action_name,
            value_buf[0..offset],
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }

        return parseActionInvokeResult(self.client.allocator, response.data);
    }

    /// Get the status of an action run.
    /// **Caller owns the returned `ActionRunStatus` and must call `result.deinit()`.**
    pub fn getStatus(
        self: *Self,
        run_id: []const u8,
        options: types.ActionStatusOptions,
    ) FloError!types.ActionRunStatus {
        const ns = self.client.getNamespace(options.namespace);

        var response = try self.client.sendRequest(
            .action_status,
            ns,
            run_id,
            "",
            "",
        );
        defer response.deinit();

        if (response.status == .not_found) {
            return FloError.NotFound;
        }

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }

        return parseActionRunStatus(self.client.allocator, response.data);
    }

    /// Delete an action.
    pub fn deleteAction(
        self: *Self,
        action_name: []const u8,
        options: types.ActionStatusOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var response = try self.client.sendRequest(
            .action_delete,
            ns,
            action_name,
            "",
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
    }

    // =========================================================================
    // Worker Registry Operations
    // =========================================================================

    /// Register a worker in the worker registry.
    /// Wire format: [type:u8][max_concurrency:u32][process_count:u16]
    ///              ([name_len:u16][name][kind:u8])*
    ///              [has_metadata:u8][metadata_len:u16][metadata]?
    ///              [has_machine_id:u8][machine_id_len:u16][machine_id]?
    pub fn register(
        self: *Self,
        worker_id: []const u8,
        task_types: ?[]const []const u8,
        options: types.WorkerRegisterOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        // Build process list from explicit processes or legacy task_types
        const processes = options.processes;
        const has_explicit_processes = processes != null and processes.?.len > 0;
        const has_legacy_types = task_types != null and task_types.?.len > 0;

        var value_buf: [2048]u8 = undefined;
        var offset: usize = 0;

        // Worker type
        value_buf[offset] = @intFromEnum(options.worker_type);
        offset += 1;

        // Max concurrency
        std.mem.writeInt(u32, value_buf[offset..][0..4], options.max_concurrency, .little);
        offset += 4;

        // Process list
        if (has_explicit_processes) {
            const procs = processes.?;
            std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(procs.len), .little);
            offset += 2;
            for (procs) |p| {
                std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(p.name.len), .little);
                offset += 2;
                @memcpy(value_buf[offset..][0..p.name.len], p.name);
                offset += p.name.len;
                value_buf[offset] = @intFromEnum(p.kind);
                offset += 1;
            }
        } else if (has_legacy_types) {
            const tt = task_types.?;
            std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(tt.len), .little);
            offset += 2;
            for (tt) |name| {
                std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(name.len), .little);
                offset += 2;
                @memcpy(value_buf[offset..][0..name.len], name);
                offset += name.len;
                value_buf[offset] = @intFromEnum(types.ProcessKind.action);
                offset += 1;
            }
        } else {
            std.mem.writeInt(u16, value_buf[offset..][0..2], 0, .little);
            offset += 2;
        }

        // Metadata
        if (options.metadata) |meta| {
            value_buf[offset] = 1;
            offset += 1;
            std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(meta.len), .little);
            offset += 2;
            @memcpy(value_buf[offset..][0..meta.len], meta);
            offset += meta.len;
        } else {
            value_buf[offset] = 0;
            offset += 1;
        }

        // Machine ID
        if (options.machine_id) |mid| {
            value_buf[offset] = 1;
            offset += 1;
            std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(mid.len), .little);
            offset += 2;
            @memcpy(value_buf[offset..][0..mid.len], mid);
            offset += mid.len;
        } else {
            value_buf[offset] = 0;
            offset += 1;
        }

        var response = try self.client.sendRequest(
            .worker_register,
            ns,
            worker_id,
            value_buf[0..offset],
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
    }

    /// Send a heartbeat to the worker registry.
    /// Returns the worker's current status (e.g. draining).
    pub fn heartbeat(
        self: *Self,
        worker_id: []const u8,
        current_load: u32,
        options: types.WorkerHeartbeatOptions,
    ) FloError!types.WorkerStatus {
        const ns = self.client.getNamespace(options.namespace);

        var value_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &value_buf, current_load, .little);

        var response = try self.client.sendRequest(
            .worker_heartbeat,
            ns,
            worker_id,
            &value_buf,
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }

        // Server responds with [status:u8]
        if (response.data.len >= 1) {
            return @enumFromInt(response.data[0]);
        }
        return .active;
    }

    /// Deregister a worker from the registry.
    pub fn deregister(
        self: *Self,
        worker_id: []const u8,
        options: types.WorkerDeregisterOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var response = try self.client.sendRequest(
            .worker_deregister,
            ns,
            worker_id,
            "",
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
    }

    /// Drain a worker — no new tasks will be assigned.
    pub fn drain(
        self: *Self,
        worker_id: []const u8,
        options: types.WorkerDrainOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var response = try self.client.sendRequest(
            .worker_drain,
            ns,
            worker_id,
            "",
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
    }

    // =========================================================================
    // Task Operations (action_await, action_complete, action_fail, action_touch)
    // =========================================================================

    /// Await a task to process.
    /// **Caller owns the returned `TaskAssignment` and must call `result.deinit()`.**
    pub fn awaitTask(
        self: *Self,
        worker_id: []const u8,
        task_types: []const []const u8,
        options: types.WorkerAwaitOptions,
    ) FloError!?types.TaskAssignment {
        const ns = self.client.getNamespace(options.namespace);

        var opts_buf: [32]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);

        if (options.timeout_ms) |t| {
            try builder.addU64(.timeout_ms, t);
        }
        if (options.block_ms) |b| {
            try builder.addU32(.block_ms, b);
        }

        // Wire format: [count:u32][task_type_len:u16][task_type]...
        var value_buf: [1024]u8 = undefined;
        var offset: usize = 0;

        std.mem.writeInt(u32, value_buf[offset..][0..4], @intCast(task_types.len), .little);
        offset += 4;

        for (task_types) |tt| {
            std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(tt.len), .little);
            offset += 2;
            @memcpy(value_buf[offset..][0..tt.len], tt);
            offset += tt.len;
        }

        var response = try self.client.sendRequest(
            .action_await,
            ns,
            worker_id,
            value_buf[0..offset],
            builder.getOptions(),
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }

        if (response.data.len == 0) {
            return null;
        }

        return parseTaskAssignment(self.client.allocator, response.data);
    }

    /// Complete a task successfully with output.
    pub fn complete(
        self: *Self,
        worker_id: []const u8,
        task_id: []const u8,
        result_data: []const u8,
        options: types.WorkerCompleteOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        // Wire format: [task_id_len:u16][task_id][result...]
        var value_buf: [8192]u8 = undefined;
        var offset: usize = 0;

        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(task_id.len), .little);
        offset += 2;
        @memcpy(value_buf[offset..][0..task_id.len], task_id);
        offset += task_id.len;
        @memcpy(value_buf[offset..][0..result_data.len], result_data);
        offset += result_data.len;

        var response = try self.client.sendRequest(
            .action_complete,
            ns,
            worker_id,
            value_buf[0..offset],
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
    }

    /// Fail a task with an error message.
    pub fn fail(
        self: *Self,
        worker_id: []const u8,
        task_id: []const u8,
        error_message: []const u8,
        options: types.WorkerFailOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var opts_buf: [8]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);

        if (options.retry) {
            try builder.addU8(.retry, 1);
        }

        // Wire format: [task_id_len:u16][task_id][error_message...]
        var value_buf: [4096]u8 = undefined;
        var offset: usize = 0;

        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(task_id.len), .little);
        offset += 2;
        @memcpy(value_buf[offset..][0..task_id.len], task_id);
        offset += task_id.len;
        @memcpy(value_buf[offset..][0..error_message.len], error_message);
        offset += error_message.len;

        var response = try self.client.sendRequest(
            .action_fail,
            ns,
            worker_id,
            value_buf[0..offset],
            builder.getOptions(),
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
    }

    /// Extend the lease on a task (keep it from timing out).
    pub fn touch(
        self: *Self,
        worker_id: []const u8,
        task_id: []const u8,
        options: types.WorkerTouchOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        // Wire format: [task_id_len:u16][task_id][extend_ms:u32]
        const extend_ms: u32 = options.extend_ms orelse 30000;

        var value_buf: [512]u8 = undefined;
        var offset: usize = 0;

        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(task_id.len), .little);
        offset += 2;
        @memcpy(value_buf[offset..][0..task_id.len], task_id);
        offset += task_id.len;
        std.mem.writeInt(u32, value_buf[offset..][0..4], extend_ms, .little);
        offset += 4;

        var response = try self.client.sendRequest(
            .action_touch,
            ns,
            worker_id,
            value_buf[0..offset],
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
    }
};

// =============================================================================
// Response Parsers
// =============================================================================

/// Parse action invoke result
/// Wire format: [run_id_len:u16][run_id][has_output:u8][output_len:u32]?[output]?
fn parseActionInvokeResult(allocator: std.mem.Allocator, data: []const u8) FloError!types.ActionInvokeResult {
    if (data.len < 3) {
        // Fallback: treat entire data as run_id (backwards compat)
        const run_id = allocator.dupe(u8, data) catch return FloError.OutOfMemory;
        return types.ActionInvokeResult{ .run_id = run_id, .allocator = allocator };
    }

    var pos: usize = 0;

    // Read run_id (length-prefixed u16)
    const run_id_len = std.mem.readInt(u16, data[pos..][0..2], .little);
    pos += 2;

    // Sanity check
    if (run_id_len > data.len - pos or run_id_len > 256 or run_id_len == 0) {
        const run_id = allocator.dupe(u8, data) catch return FloError.OutOfMemory;
        return types.ActionInvokeResult{ .run_id = run_id, .allocator = allocator };
    }

    const run_id = allocator.dupe(u8, data[pos..][0..run_id_len]) catch return FloError.OutOfMemory;
    errdefer allocator.free(run_id);
    pos += run_id_len;

    // Read optional output
    var output: ?[]const u8 = null;
    if (pos < data.len and data[pos] == 1) {
        pos += 1;
        if (pos + 4 <= data.len) {
            const output_len = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;
            if (pos + output_len <= data.len) {
                output = allocator.dupe(u8, data[pos..][0..output_len]) catch return FloError.OutOfMemory;
            }
        }
    }

    return types.ActionInvokeResult{ .run_id = run_id, .output = output, .allocator = allocator };
}

/// Parse task assignment from wire format
/// Wire format: [task_id_len:u16][task_id][task_type_len:u16][task_type]
///              [created_at:i64][attempt:u32][payload...]
fn parseTaskAssignment(allocator: std.mem.Allocator, data: []const u8) FloError!?types.TaskAssignment {
    if (data.len < 2) {
        return null;
    }

    var pos: usize = 0;

    // task_id
    if (pos + 2 > data.len) return FloError.IncompleteResponse;
    const task_id_len = std.mem.readInt(u16, data[pos..][0..2], .little);
    pos += 2;
    if (pos + task_id_len > data.len) return FloError.IncompleteResponse;
    const task_id = allocator.dupe(u8, data[pos..][0..task_id_len]) catch return FloError.OutOfMemory;
    errdefer allocator.free(task_id);
    pos += task_id_len;

    // task_type
    if (pos + 2 > data.len) return FloError.IncompleteResponse;
    const task_type_len = std.mem.readInt(u16, data[pos..][0..2], .little);
    pos += 2;
    if (pos + task_type_len > data.len) return FloError.IncompleteResponse;
    const task_type = allocator.dupe(u8, data[pos..][0..task_type_len]) catch return FloError.OutOfMemory;
    errdefer allocator.free(task_type);
    pos += task_type_len;

    // created_at
    if (pos + 8 > data.len) return FloError.IncompleteResponse;
    const created_at = std.mem.readInt(i64, data[pos..][0..8], .little);
    pos += 8;

    // attempt
    if (pos + 4 > data.len) return FloError.IncompleteResponse;
    const attempt = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;

    // payload (rest of data)
    var payload: []const u8 = "";
    if (pos < data.len) {
        payload = allocator.dupe(u8, data[pos..]) catch return FloError.OutOfMemory;
    }

    return types.TaskAssignment{
        .task_id = task_id,
        .task_type = task_type,
        .payload = payload,
        .created_at = created_at,
        .attempt = attempt,
        .allocator = allocator,
    };
}

/// Parse action run status from wire format
/// Wire format: [run_id_len:u16][run_id][status:u8][created_at:i64]
///              [has_started_at:u8][started_at:i64]?[has_completed_at:u8][completed_at:i64]?
///              [has_output:u8][output_len:u32]?[output]?
///              [has_error:u8][error_len:u32]?[error]?[retry_count:u32]
fn parseActionRunStatus(allocator: std.mem.Allocator, data: []const u8) FloError!types.ActionRunStatus {
    if (data.len < 14) {
        return FloError.IncompleteResponse;
    }

    var pos: usize = 0;

    // Read run_id
    if (pos + 2 > data.len) return FloError.IncompleteResponse;
    const run_id_len = std.mem.readInt(u16, data[pos..][0..2], .little);
    pos += 2;
    if (pos + run_id_len > data.len) return FloError.IncompleteResponse;
    const run_id = allocator.dupe(u8, data[pos..][0..run_id_len]) catch return FloError.OutOfMemory;
    errdefer allocator.free(run_id);
    pos += run_id_len;

    // Status
    if (pos + 1 > data.len) return FloError.IncompleteResponse;
    const status: types.RunStatus = @enumFromInt(data[pos]);
    pos += 1;

    // Created at
    if (pos + 8 > data.len) return FloError.IncompleteResponse;
    const created_at = std.mem.readInt(i64, data[pos..][0..8], .little);
    pos += 8;

    // Started at (optional)
    var started_at: ?i64 = null;
    if (pos + 1 > data.len) return FloError.IncompleteResponse;
    if (data[pos] == 1) {
        pos += 1;
        if (pos + 8 > data.len) return FloError.IncompleteResponse;
        started_at = std.mem.readInt(i64, data[pos..][0..8], .little);
        pos += 8;
    } else {
        pos += 1;
    }

    // Completed at (optional)
    var completed_at: ?i64 = null;
    if (pos + 1 > data.len) return FloError.IncompleteResponse;
    if (data[pos] == 1) {
        pos += 1;
        if (pos + 8 > data.len) return FloError.IncompleteResponse;
        completed_at = std.mem.readInt(i64, data[pos..][0..8], .little);
        pos += 8;
    } else {
        pos += 1;
    }

    // Output (optional)
    var output: ?[]const u8 = null;
    if (pos + 1 > data.len) return FloError.IncompleteResponse;
    if (data[pos] == 1) {
        pos += 1;
        if (pos + 4 > data.len) return FloError.IncompleteResponse;
        const output_len = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        if (pos + output_len > data.len) return FloError.IncompleteResponse;
        output = allocator.dupe(u8, data[pos..][0..output_len]) catch return FloError.OutOfMemory;
        pos += output_len;
    } else {
        pos += 1;
    }
    errdefer if (output) |o| allocator.free(o);

    // Error message (optional)
    var error_message: ?[]const u8 = null;
    if (pos + 1 > data.len) return FloError.IncompleteResponse;
    if (data[pos] == 1) {
        pos += 1;
        if (pos + 4 > data.len) return FloError.IncompleteResponse;
        const error_len = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        if (pos + error_len > data.len) return FloError.IncompleteResponse;
        error_message = allocator.dupe(u8, data[pos..][0..error_len]) catch return FloError.OutOfMemory;
        pos += error_len;
    } else {
        pos += 1;
    }
    errdefer if (error_message) |e| allocator.free(e);

    // Retry count
    if (pos + 4 > data.len) return FloError.IncompleteResponse;
    const retry_count = std.mem.readInt(u32, data[pos..][0..4], .little);

    return types.ActionRunStatus{
        .run_id = run_id,
        .status = status,
        .created_at = created_at,
        .started_at = started_at,
        .completed_at = completed_at,
        .output = output,
        .error_message = error_message,
        .retry_count = retry_count,
        .allocator = allocator,
    };
}

/// Map status code to FloError
fn mapStatusToError(status: StatusCode) FloError {
    return switch (status) {
        .not_found => FloError.NotFound,
        .bad_request => FloError.BadRequest,
        .conflict => FloError.Conflict,
        .unauthorized => FloError.Unauthorized,
        .overloaded => FloError.Overloaded,
        else => FloError.ServerError,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "Actions init" {
    const allocator = std.testing.allocator;
    var client = @import("client.zig").Client.init(allocator, "localhost:9000", .{});
    defer client.deinit();

    const actions = Actions.init(&client);
    _ = actions;
}
