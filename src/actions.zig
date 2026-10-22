//! Flo Actions - Low-Level Action/Worker Protocol
//!
//! This module provides low-level operations for actions and workers:
//! - Action registration, invocation, status checking, and deletion
//! - Worker registration, heartbeat, drain, deregistration
//! - Task awaiting, completion, failure, and touch (lease extension)
//!
//! For a higher-level API, see `ActionWorker` in worker.zig.

const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");
const Client = @import("client.zig").Client;
const Reader = @import("kv.zig").Reader;

const FloError = types.FloError;

/// Low-level actions and worker operations.
/// For a higher-level API, see `ActionWorker` in worker.zig.
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
    pub fn registerAction(
        self: *Self,
        action_name: []const u8,
        action_type: types.ActionType,
        options: types.ActionRegisterOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        // [action_type:u8][timeout_ms:u32][max_retries:u32][owner_len:u16][owner]
        var value_buf: [11 + 1024]u8 = undefined;
        if (options.owner.len > value_buf.len - 11) return FloError.ValueTooLarge;
        value_buf[0] = @intFromEnum(action_type);
        std.mem.writeInt(u32, value_buf[1..5], options.timeout_ms, .little);
        std.mem.writeInt(u32, value_buf[5..9], options.max_retries, .little);
        std.mem.writeInt(u16, value_buf[9..11], @intCast(options.owner.len), .little);
        @memcpy(value_buf[11..][0..options.owner.len], options.owner);
        const offset = 11 + options.owner.len;

        var response = try self.client.sendRequest(
            .action_register,
            ns,
            action_name,
            value_buf[0..offset],
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }
    }

    /// Invoke an action (create a task for workers to process).
    /// Returns an ActionInvokeResult with run_id.
    /// **Caller owns the returned `ActionInvokeResult` and must call `result.deinit()`.**
    pub fn invoke(
        self: *Self,
        action_name: []const u8,
        input: []const u8,
        options: types.ActionInvokeOptions,
    ) FloError!types.ActionInvokeResult {
        const ns = self.client.getNamespace(options.namespace);

        var value_buf: [8192]u8 = undefined;
        const value = try encodeInvokeValue(&value_buf, options.labels, input);

        var response = try self.client.sendRequest(
            .action_invoke,
            ns,
            action_name,
            value,
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
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
            return response.status.toError();
        }

        return parseActionRunStatus(self.client.allocator, run_id, response.data);
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
            return response.status.toError();
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
            return response.status.toError();
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
            return response.status.toError();
        }

        // Server responds with [status:u8]
        if (response.data.len >= 1) {
            return std.meta.intToEnum(types.WorkerStatus, response.data[0]) catch FloError.IncompleteResponse;
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
            return response.status.toError();
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
            return response.status.toError();
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

        var opts_buf: [16]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);

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
            return response.status.toError();
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
        action_name: []const u8,
        task_id: []const u8,
        result_data: []const u8,
        options: types.WorkerCompleteOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        // Wire format: [action_name_len:u16][action_name][task_id_len:u16][task_id][outcome_len:u16][outcome][result_len:u16][result]
        var value_buf: [8192]u8 = undefined;
        var offset: usize = 0;

        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(action_name.len), .little);
        offset += 2;
        @memcpy(value_buf[offset..][0..action_name.len], action_name);
        offset += action_name.len;

        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(task_id.len), .little);
        offset += 2;
        @memcpy(value_buf[offset..][0..task_id.len], task_id);
        offset += task_id.len;

        const outcome = options.outcome;
        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(outcome.len), .little);
        offset += 2;
        @memcpy(value_buf[offset..][0..outcome.len], outcome);
        offset += outcome.len;

        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(result_data.len), .little);
        offset += 2;
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
            return response.status.toError();
        }
    }

    /// Fail a task with an error message.
    pub fn fail(
        self: *Self,
        worker_id: []const u8,
        action_name: []const u8,
        task_id: []const u8,
        error_message: []const u8,
        options: types.WorkerFailOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        // Wire format: [action_name_len:u16][action_name][task_id_len:u16][task_id][retry:u8][error_message...]
        var value_buf: [4096]u8 = undefined;
        var offset: usize = 0;

        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(action_name.len), .little);
        offset += 2;
        @memcpy(value_buf[offset..][0..action_name.len], action_name);
        offset += action_name.len;

        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(task_id.len), .little);
        offset += 2;
        @memcpy(value_buf[offset..][0..task_id.len], task_id);
        offset += task_id.len;

        value_buf[offset] = if (options.retry) 1 else 0;
        offset += 1;

        @memcpy(value_buf[offset..][0..error_message.len], error_message);
        offset += error_message.len;

        var response = try self.client.sendRequest(
            .action_fail,
            ns,
            worker_id,
            value_buf[0..offset],
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }
    }

    /// Extend the lease on a task (keep it from timing out).
    pub fn touch(
        self: *Self,
        worker_id: []const u8,
        action_name: []const u8,
        task_id: []const u8,
        options: types.WorkerTouchOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        // Wire format: [action_name_len:u16][action_name][task_id_len:u16][task_id][extend_ms:u32]
        const extend_ms: u32 = options.extend_ms orelse 30000;

        var value_buf: [512]u8 = undefined;
        var offset: usize = 0;

        std.mem.writeInt(u16, value_buf[offset..][0..2], @intCast(action_name.len), .little);
        offset += 2;
        @memcpy(value_buf[offset..][0..action_name.len], action_name);
        offset += action_name.len;

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
            return response.status.toError();
        }
    }
};

// =============================================================================
// Response Parsers
// =============================================================================

/// Encode an action_invoke request value:
///
///   [has_labels:u8]([labels_len:u16 LE][labels])?[input...]
///
/// has_labels is 0 (the input follows directly) or 1. labels is a JSON object
/// naming the labels a worker must have to receive the run. Returns the
/// encoded slice of `buf`, or ValueTooLarge if it does not fit.
pub fn encodeInvokeValue(buf: []u8, labels: ?[]const u8, input: []const u8) FloError![]const u8 {
    var offset: usize = 0;
    if (labels) |l| {
        if (l.len > std.math.maxInt(u16)) return FloError.ValueTooLarge;
        if (3 + l.len + input.len > buf.len) return FloError.ValueTooLarge;
        buf[0] = 1;
        std.mem.writeInt(u16, buf[1..3], @intCast(l.len), .little);
        @memcpy(buf[3..][0..l.len], l);
        offset = 3 + l.len;
    } else {
        if (1 + input.len > buf.len) return FloError.ValueTooLarge;
        buf[0] = 0;
        offset = 1;
    }
    @memcpy(buf[offset..][0..input.len], input);
    return buf[0 .. offset + input.len];
}

/// Parse action invoke result
/// Wire format: [run_id_len:u16][run_id][has_output:u8]. has_output is always
/// 0, so nothing after the run id is read.
fn parseActionInvokeResult(allocator: std.mem.Allocator, data: []const u8) FloError!types.ActionInvokeResult {
    if (data.len < 2) return FloError.UnexpectedResponse;
    const run_id_len = std.mem.readInt(u16, data[0..2], .little);
    if (run_id_len == 0 or run_id_len > data.len - 2) return FloError.UnexpectedResponse;

    const run_id = allocator.dupe(u8, data[2..][0..run_id_len]) catch return FloError.OutOfMemory;
    return types.ActionInvokeResult{ .run_id = run_id, .allocator = allocator };
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

    // caller block: [has_caller:u8][run_id_len:u16][run_id][wf_name_len:u16][wf_name]
    var caller_run_id: ?[]const u8 = null;
    errdefer if (caller_run_id) |c| allocator.free(c);
    var caller_workflow_name: ?[]const u8 = null;
    errdefer if (caller_workflow_name) |c| allocator.free(c);

    if (pos + 1 <= data.len) {
        const has_caller = data[pos];
        pos += 1;
        if (has_caller == 1) {
            // caller_run_id
            if (pos + 2 > data.len) return FloError.IncompleteResponse;
            const crid_len = std.mem.readInt(u16, data[pos..][0..2], .little);
            pos += 2;
            if (pos + crid_len > data.len) return FloError.IncompleteResponse;
            if (crid_len > 0) {
                caller_run_id = allocator.dupe(u8, data[pos..][0..crid_len]) catch return FloError.OutOfMemory;
            }
            pos += crid_len;

            // caller_workflow_name
            if (pos + 2 > data.len) return FloError.IncompleteResponse;
            const cwn_len = std.mem.readInt(u16, data[pos..][0..2], .little);
            pos += 2;
            if (pos + cwn_len > data.len) return FloError.IncompleteResponse;
            if (cwn_len > 0) {
                caller_workflow_name = allocator.dupe(u8, data[pos..][0..cwn_len]) catch return FloError.OutOfMemory;
            }
            pos += cwn_len;
        }
    }

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
        .caller_run_id = caller_run_id,
        .caller_workflow_name = caller_workflow_name,
        .allocator = allocator,
    };
}

/// The longest worker id an answer carries: the server's key bound.
const max_worker_id = 4096;

/// action.status's answer: [status:u8][created_at:i64][started_at:?i64]
/// [completed_at:?i64][attempt:u32][output:?(u16 len, bytes)]
/// [error_message:?(u16 len, bytes)][worker_id:?(u16 len, bytes)], each
/// optional behind a presence byte.
fn parseActionRunStatus(allocator: std.mem.Allocator, run_id: []const u8, data: []const u8) FloError!types.ActionRunStatus {
    var r: Reader = .{ .data = data };
    const status = std.meta.intToEnum(types.RunStatus, try r.int(u8)) catch return FloError.IncompleteResponse;
    const created_at = try r.int(i64);
    const started_at = try r.opt(i64);
    const completed_at = try r.opt(i64);
    const attempt = try r.int(u32);
    const output = if (try r.boolean()) try r.lenBytes(u16) else null;
    const error_message = if (try r.boolean()) try r.lenBytes(u16) else null;
    const worker_id = if (try r.boolean()) try r.lenBytes(u16) else null;
    if (worker_id) |w| if (w.len > max_worker_id) return FloError.IncompleteResponse;
    try r.end();

    const run_id_copy = allocator.dupe(u8, run_id) catch return FloError.OutOfMemory;
    errdefer allocator.free(run_id_copy);
    const output_copy = if (output) |o| allocator.dupe(u8, o) catch return FloError.OutOfMemory else null;
    errdefer if (output_copy) |o| allocator.free(o);
    const error_copy = if (error_message) |e| allocator.dupe(u8, e) catch return FloError.OutOfMemory else null;
    errdefer if (error_copy) |e| allocator.free(e);
    const worker_copy = if (worker_id) |w| allocator.dupe(u8, w) catch return FloError.OutOfMemory else null;
    return .{
        .run_id = run_id_copy,
        .status = status,
        .created_at = created_at,
        .started_at = started_at,
        .completed_at = completed_at,
        .attempt = attempt,
        .output = output_copy,
        .error_message = error_copy,
        .worker_id = worker_copy,
        .allocator = allocator,
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

test "encodeInvokeValue without labels writes 0 then the input" {
    var buf: [16]u8 = undefined;
    const value = try encodeInvokeValue(&buf, null, "x");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 'x' }, value);
}

test "encodeInvokeValue with labels writes 1, the u16 LE length, the labels, then the input" {
    var buf: [32]u8 = undefined;
    const value = try encodeInvokeValue(&buf, "{\"gpu\":true}", "x");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 12, 0 } ++ "{\"gpu\":true}" ++ "x", value);
}

test "encodeInvokeValue refuses a value that does not fit the buffer" {
    var buf: [8]u8 = undefined;
    try std.testing.expectError(FloError.ValueTooLarge, encodeInvokeValue(&buf, null, "12345678"));
    try std.testing.expectError(FloError.ValueTooLarge, encodeInvokeValue(&buf, "{}", "1234"));
}

/// A task assignment with a caller block and a payload.
fn testTaskAssignment(a: std.mem.Allocator, list: *std.ArrayList(u8)) !void {
    for ([_][]const u8{ "task-1", "charge" }) |s| {
        try list.appendSlice(a, &std.mem.toBytes(@as(u16, @intCast(s.len))));
        try list.appendSlice(a, s);
    }
    try list.appendSlice(a, &std.mem.toBytes(@as(i64, 1000)));
    try list.appendSlice(a, &std.mem.toBytes(@as(u32, 1)));
    try list.append(a, 1);
    for ([_][]const u8{ "run-1", "checkout" }) |s| {
        try list.appendSlice(a, &std.mem.toBytes(@as(u16, @intCast(s.len))));
        try list.appendSlice(a, s);
    }
    try list.appendSlice(a, "payload");
}

fn parseTaskAndFree(a: std.mem.Allocator, data: []const u8) !void {
    if (try parseTaskAssignment(a, data)) |t| {
        var task = t;
        task.deinit();
    }
}

test "a task assignment cut anywhere or short of memory leaks nothing" {
    const a = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(a);
    try testTaskAssignment(a, &list);
    // The caller block and payload are optional, so some cuts still parse.
    for (0..list.items.len + 1) |n| parseTaskAndFree(a, list.items[0..n]) catch |err| try std.testing.expectEqual(FloError.IncompleteResponse, err);
    try std.testing.checkAllAllocationFailures(a, parseTaskAndFree, .{list.items});
}

/// A completed run's status answer: started, completed, attempt 2, output "ok", no error,
/// run by worker "w1".
/// Little-endian, as on the wire.
const completed_status_answer = "\x02" ++ // completed
    "\x64\x00\x00\x00\x00\x00\x00\x00" ++ // created_at 100
    "\x01\x6e\x00\x00\x00\x00\x00\x00\x00" ++ // started_at 110
    "\x01\x78\x00\x00\x00\x00\x00\x00\x00" ++ // completed_at 120
    "\x02\x00\x00\x00" ++ // attempt 2
    "\x01\x02\x00ok" ++ // output "ok"
    "\x00" ++ // no error
    "\x01\x02\x00w1"; // worker "w1"

test "a completed run's status carries its times, attempt and output" {
    var st = try parseActionRunStatus(std.testing.allocator, "run-1", completed_status_answer);
    defer st.deinit();
    try std.testing.expectEqualStrings("run-1", st.run_id);
    try std.testing.expectEqual(types.RunStatus.completed, st.status);
    try std.testing.expectEqual(@as(i64, 100), st.created_at);
    try std.testing.expectEqual(@as(?i64, 110), st.started_at);
    try std.testing.expectEqual(@as(?i64, 120), st.completed_at);
    try std.testing.expectEqual(@as(u32, 2), st.attempt);
    try std.testing.expectEqualStrings("ok", st.output.?);
    try std.testing.expectEqual(@as(?[]const u8, null), st.error_message);
    try std.testing.expectEqualStrings("w1", st.worker_id.?);
}

test "a pending run's status names no worker" {
    const answer = "\x00" ++ // pending
        "\x64\x00\x00\x00\x00\x00\x00\x00" ++ // created_at 100
        "\x00\x00" ++ // not started, not completed
        "\x00\x00\x00\x00" ++ // attempt 0
        "\x00\x00" ++ // no output, no error
        "\x00"; // no worker
    var st = try parseActionRunStatus(std.testing.allocator, "run-1", answer);
    defer st.deinit();
    try std.testing.expectEqual(types.RunStatus.pending, st.status);
    try std.testing.expectEqual(@as(?[]const u8, null), st.worker_id);
}

test "a status answer with a worker id over the server's bound is refused" {
    const answer = "\x00" ++ "\x64\x00\x00\x00\x00\x00\x00\x00" ++ "\x00\x00" ++ "\x00\x00\x00\x00" ++ "\x00\x00" ++
        "\x01\x01\x10" ++ "w" ** 4097;
    try std.testing.expectError(FloError.IncompleteResponse, parseActionRunStatus(std.testing.allocator, "run-1", answer));
}

test "a failed run's status carries its error and no output" {
    const answer = "\x03" ++ // failed
        "\x64\x00\x00\x00\x00\x00\x00\x00" ++ // created_at 100
        "\x00\x00" ++ // not started, not completed
        "\x03\x00\x00\x00" ++ // attempt 3
        "\x00" ++ // no output
        "\x01\x04\x00boom" ++ // error "boom"
        "\x01\x02\x00w1"; // last held by "w1"
    var st = try parseActionRunStatus(std.testing.allocator, "run-1", answer);
    defer st.deinit();
    try std.testing.expectEqual(types.RunStatus.failed, st.status);
    try std.testing.expectEqual(@as(?i64, null), st.started_at);
    try std.testing.expectEqual(@as(?[]const u8, null), st.output);
    try std.testing.expectEqualStrings("boom", st.error_message.?);
    try std.testing.expectEqualStrings("w1", st.worker_id.?);
}

fn parseStatusAndFree(a: std.mem.Allocator, data: []const u8) !void {
    var st = try parseActionRunStatus(a, "run-1", data);
    st.deinit();
}

test "a status answer cut anywhere, overlong, or short of memory leaks nothing" {
    const a = std.testing.allocator;
    for (0..completed_status_answer.len) |n| try std.testing.expectError(FloError.IncompleteResponse, parseStatusAndFree(a, completed_status_answer[0..n]));
    try std.testing.expectError(FloError.IncompleteResponse, parseStatusAndFree(a, completed_status_answer ++ "\x00"));
    try std.testing.checkAllAllocationFailures(a, parseStatusAndFree, .{@as([]const u8, completed_status_answer)});
}

test "a run status byte this client doesn't know refuses the answer" {
    var answer = completed_status_answer.*;
    answer[0] = 200;
    try std.testing.expectError(FloError.IncompleteResponse, parseActionRunStatus(std.testing.allocator, "run-1", &answer));
}
