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

    /// A page of the namespace's registered action names. Pass the page's
    /// cursor to get the next; it is null on the last page.
    /// **Caller owns the returned page and must call `page.deinit()`.**
    pub fn listActions(self: *Self, options: types.ActionListOptions) FloError!types.ActionListPage {
        const value = try wire.encodeListValue(self.client.allocator, options.limit, options.cursor orelse "");
        defer self.client.allocator.free(value);
        var response = try self.client.sendRequest(.action_list, self.client.getNamespace(options.namespace), options.prefix, value, "");
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        return decodeActionListAnswer(self.client.allocator, response.data);
    }

    /// A page of the namespace's workers, in id order: those after
    /// `options.cursor`, at most `options.limit`. Pass the page's cursor to
    /// get the next; it is null on the last page.
    /// **Caller owns the returned page and must call `page.deinit()`.**
    pub fn listWorkers(self: *Self, options: types.WorkerListOptions) FloError!types.WorkerListPage {
        var buf: [MAX_WORKER_LIST_BODY]u8 = undefined;
        const body = try encodeWorkerListBody(&buf, options.limit, options.cursor orelse "", options.action orelse "");
        var response = try self.client.sendRequest(.worker_list, self.client.getNamespace(options.namespace), "", body, "");
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        return decodeWorkerListAnswer(self.client.allocator, response.data);
    }

    /// One worker's record: its row as listWorkers shows it, the metadata it
    /// registered with, and its processes with their counts. A worker the
    /// server doesn't know is `FloError.NotFound`.
    /// **Caller owns the returned record and must call `record.deinit()`.**
    pub fn workerInfo(self: *Self, worker_id: []const u8, options: types.WorkerInfoOptions) FloError!types.WorkerDetails {
        var response = try self.client.sendRequest(.worker_info, self.client.getNamespace(options.namespace), worker_id, "", "");
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        return decodeWorkerInfoAnswer(self.client.allocator, response.data);
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

        const value = try encodeRegisterValue(self.client.allocator, task_types, options);
        defer self.client.allocator.free(value);

        var response = try self.client.sendRequest(
            .worker_register,
            ns,
            worker_id,
            value,
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

/// The longest machine id a worker.list row carries.
const max_machine_id = 255;

const MAX_WORKER_LIST_BODY = 1 + 4 + 2 + max_worker_id + 2 + max_worker_id;

/// worker.list's request: limit (present), cursor ("" for the first page),
/// action ("" for every worker).
fn encodeWorkerListBody(buf: *[MAX_WORKER_LIST_BODY]u8, limit: u32, cursor: []const u8, action: []const u8) FloError![]const u8 {
    if (limit < 1 or limit > types.MAX_WORKER_LIST) return FloError.BadRequest;
    if (cursor.len > max_worker_id or action.len > max_worker_id) return FloError.BadRequest;
    var w: std.Io.Writer = .fixed(buf);
    w.writeByte(1) catch unreachable;
    w.writeInt(u32, limit, .little) catch unreachable;
    for ([_][]const u8{ cursor, action }) |field| {
        w.writeInt(u16, @intCast(field.len), .little) catch unreachable;
        w.writeAll(field) catch unreachable;
    }
    return w.buffered();
}

/// worker.register's value. The server refuses what it won't keep (too many
/// processes, a name too long); only a length its u16 prefix can't carry is
/// refused here.
fn encodeRegisterValue(allocator: std.mem.Allocator, task_types: ?[]const []const u8, options: types.WorkerRegisterOptions) FloError![]u8 {
    const explicit = options.processes orelse &.{};
    const legacy = task_types orelse &.{};
    const count = if (explicit.len > 0) explicit.len else legacy.len;
    if (count > std.math.maxInt(u16)) return FloError.ValueTooLarge;
    var size: usize = 1 + 4 + 2 + 1 + 1;
    for (0..count) |i| {
        const name = if (explicit.len > 0) explicit[i].name else legacy[i];
        if (name.len > std.math.maxInt(u16)) return FloError.ValueTooLarge;
        size += 2 + name.len + 1;
    }
    for ([_]?[]const u8{ options.metadata, options.machine_id }) |field| if (field) |f| {
        if (f.len > std.math.maxInt(u16)) return FloError.ValueTooLarge;
        size += 2 + f.len;
    };

    const buf = try allocator.alloc(u8, size);
    var w: std.Io.Writer = .fixed(buf);
    w.writeByte(@intFromEnum(options.worker_type)) catch unreachable;
    w.writeInt(u32, options.max_concurrency, .little) catch unreachable;
    w.writeInt(u16, @intCast(count), .little) catch unreachable;
    for (0..count) |i| {
        const name = if (explicit.len > 0) explicit[i].name else legacy[i];
        const kind: types.ProcessKind = if (explicit.len > 0) explicit[i].kind else .action;
        w.writeInt(u16, @intCast(name.len), .little) catch unreachable;
        w.writeAll(name) catch unreachable;
        w.writeByte(@intFromEnum(kind)) catch unreachable;
    }
    for ([_]?[]const u8{ options.metadata, options.machine_id }) |field| {
        if (field) |f| {
            w.writeByte(1) catch unreachable;
            w.writeInt(u16, @intCast(f.len), .little) catch unreachable;
            w.writeAll(f) catch unreachable;
        } else w.writeByte(0) catch unreachable;
    }
    std.debug.assert(w.end == size);
    return buf;
}

/// A worker row, as worker.list and worker.info answer it: {id,
/// worker_type, status, current_load, max_concurrency, tasks_completed,
/// tasks_failed, registered_at_ms, last_heartbeat_ms, machine_id?}. The
/// caller frees its id and machine_id.
fn decodeWorkerRow(allocator: std.mem.Allocator, r: *Reader) FloError!types.WorkerInfo {
    const id = try r.lenBytes(u16);
    if (id.len > max_worker_id) return FloError.IncompleteResponse;
    const worker_type = std.meta.intToEnum(types.WorkerType, try r.int(u8)) catch return FloError.IncompleteResponse;
    const status = std.meta.intToEnum(types.WorkerStatus, try r.int(u8)) catch return FloError.IncompleteResponse;
    const current_load = try r.int(u32);
    const max_concurrency = try r.int(u32);
    const tasks_completed = try r.int(u64);
    const tasks_failed = try r.int(u64);
    const registered_at_ms = try r.int(i64);
    const last_heartbeat_ms = try r.int(i64);
    const machine_id = if (try r.boolean()) try r.lenBytes(u8) else null;
    const id_copy = try allocator.dupe(u8, id);
    errdefer allocator.free(id_copy);
    return .{
        .id = id_copy,
        .worker_type = worker_type,
        .status = status,
        .current_load = current_load,
        .max_concurrency = max_concurrency,
        .tasks_completed = tasks_completed,
        .tasks_failed = tasks_failed,
        .registered_at_ms = registered_at_ms,
        .last_heartbeat_ms = last_heartbeat_ms,
        .machine_id = if (machine_id) |m| try allocator.dupe(u8, m) else null,
    };
}

/// action.list's answer: names (u32 count), each with a value the server
/// leaves empty, then the list trailer.
///   [count:u32]([name_len:u16][name][value_len:u32][value])*
///   [has_more:u8][cursor_len:u16][cursor]
fn decodeActionListAnswer(allocator: std.mem.Allocator, data: []const u8) FloError!types.ActionListPage {
    var r: Reader = .{ .data = data };
    const n = try r.int(u32);
    // Each entry is at least its two lengths: a count the data can't hold is
    // refused before it sizes an allocation.
    if (n > r.remaining() / 6) return FloError.IncompleteResponse;
    const names = try allocator.alloc([]const u8, n);
    var got: usize = 0;
    errdefer {
        for (names[0..got]) |name| allocator.free(name);
        allocator.free(names);
    }
    while (got < n) : (got += 1) {
        const name = try r.lenBytes(u16);
        _ = try r.lenBytes(u32);
        names[got] = try allocator.dupe(u8, name);
    }
    const trailer = try wire.parseListTrailer(data, r.pos);
    return .{
        .names = names,
        .has_more = trailer.has_more,
        .cursor = if (trailer.cursor) |c| try allocator.dupe(u8, c) else null,
        .allocator = allocator,
    };
}

/// A worker row's smallest encoding: an empty id, no machine id.
const min_worker_row = 2 + 1 + 1 + 4 + 4 + 8 + 8 + 8 + 8 + 1;

/// worker.list's answer: rows (u16 count), then cursor?.
fn decodeWorkerListAnswer(allocator: std.mem.Allocator, data: []const u8) FloError!types.WorkerListPage {
    var r: Reader = .{ .data = data };
    const n = try r.int(u16);
    // A count the data can't hold is refused before it sizes an allocation.
    if (n > types.MAX_WORKER_LIST or n > r.remaining() / min_worker_row) return FloError.IncompleteResponse;
    const workers = try allocator.alloc(types.WorkerInfo, n);
    var got: usize = 0;
    errdefer {
        for (workers[0..got]) |w| {
            allocator.free(w.id);
            if (w.machine_id) |m| allocator.free(m);
        }
        allocator.free(workers);
    }
    while (got < n) : (got += 1) workers[got] = try decodeWorkerRow(allocator, &r);
    const cursor = if (try r.boolean()) try r.lenBytes(u16) else null;
    if (cursor) |c| if (c.len > max_worker_id) return FloError.IncompleteResponse;
    try r.end();
    return .{
        .workers = workers,
        .cursor = if (cursor) |c| try allocator.dupe(u8, c) else null,
        .allocator = allocator,
    };
}

/// The most processes a worker.info answer lists.
const max_processes = 1024;

/// A process row's smallest encoding: an empty name.
const min_process_row = 2 + 1 + 8 + 8 + 8;

/// worker.info's answer: the worker's row, metadata? (u16 length), then
/// processes (u16 count), each {name, kind, run_count, fail_count,
/// last_run_at_ms}.
fn decodeWorkerInfoAnswer(allocator: std.mem.Allocator, data: []const u8) FloError!types.WorkerDetails {
    var r: Reader = .{ .data = data };
    const worker = try decodeWorkerRow(allocator, &r);
    errdefer {
        allocator.free(worker.id);
        if (worker.machine_id) |m| allocator.free(m);
    }
    const metadata_in = if (try r.boolean()) try r.lenBytes(u16) else null;
    const n = try r.int(u16);
    if (n > max_processes or n > r.remaining() / min_process_row) return FloError.IncompleteResponse;
    const metadata = if (metadata_in) |m| try allocator.dupe(u8, m) else null;
    errdefer if (metadata) |m| allocator.free(m);
    const processes = try allocator.alloc(types.WorkerProcess, n);
    var got: usize = 0;
    errdefer {
        for (processes[0..got]) |p| allocator.free(p.name);
        allocator.free(processes);
    }
    while (got < n) : (got += 1) {
        const name = try r.lenBytes(u16);
        if (name.len > max_worker_id) return FloError.IncompleteResponse;
        const kind = std.meta.intToEnum(types.ProcessKind, try r.int(u8)) catch return FloError.IncompleteResponse;
        const run_count = try r.int(u64);
        const fail_count = try r.int(u64);
        const last_run_at_ms = try r.int(i64);
        processes[got] = .{
            .name = try allocator.dupe(u8, name),
            .kind = kind,
            .run_count = run_count,
            .fail_count = fail_count,
            .last_run_at_ms = last_run_at_ms,
        };
    }
    try r.end();
    return .{ .worker = worker, .metadata = metadata, .processes = processes, .allocator = allocator };
}

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

const test_server = @import("test_server.zig");

/// A worker.list row as the server encodes it.
fn testWorkerRow(out: *std.ArrayList(u8), a: std.mem.Allocator, id: []const u8, status: u8, machine_id: ?[]const u8) !void {
    var n: [8]u8 = undefined;
    std.mem.writeInt(u16, n[0..2], @intCast(id.len), .little);
    try out.appendSlice(a, n[0..2]);
    try out.appendSlice(a, id);
    try out.appendSlice(a, &.{ 1, status }); // stream, status
    std.mem.writeInt(u32, n[0..4], 2, .little); // current_load
    try out.appendSlice(a, n[0..4]);
    std.mem.writeInt(u32, n[0..4], 8, .little); // max_concurrency
    try out.appendSlice(a, n[0..4]);
    for ([_]u64{ 5, 1, 1000, 2000 }) |v| { // completed, failed, registered, heartbeat
        std.mem.writeInt(u64, &n, v, .little);
        try out.appendSlice(a, &n);
    }
    if (machine_id) |m| {
        try out.appendSlice(a, &.{ 1, @intCast(m.len) });
        try out.appendSlice(a, m);
    } else try out.append(a, 0);
}

test "listActions sends its limit and cursor and returns the names, has_more and the next cursor" {
    const a = std.testing.allocator;
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{
        // Two names, then has_more and a 3-byte cursor.
        .{ .status = 0, .body = &.{ 2, 0, 0, 0, 1, 0, 'a', 0, 0, 0, 0, 2, 0, 'b', 'c', 0, 0, 0, 0, 1, 3, 0, 1, 0, 9 } },
        // The last page: nothing more, no cursor.
        .{ .status = 0, .body = &.{ 1, 0, 0, 0, 1, 0, 'd', 0, 0, 0, 0, 0, 0, 0 } },
    };
    try srv.start();
    defer srv.deinit();
    var client = @import("client.zig").Client.init(a, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var actions = Actions.init(&client);

    // The first page: the limit, and no cursor.
    var page = try actions.listActions(.{ .limit = 2 });
    defer page.deinit();
    try std.testing.expectEqual(@as(u16, @intFromEnum(types.OpCode.action_list)), srv.last_op);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0 }, srv.lastValue());
    try std.testing.expectEqual(@as(usize, 2), page.names.len);
    try std.testing.expectEqualStrings("a", page.names[0]);
    try std.testing.expectEqualStrings("bc", page.names[1]);
    try std.testing.expect(page.has_more);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 9 }, page.cursor.?);

    // The next: the cursor follows the limit (0, the server's default).
    var last = try actions.listActions(.{ .cursor = page.cursor });
    defer last.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 1, 0, 9 }, srv.lastValue());
    try std.testing.expectEqualStrings("", srv.lastKey());
    try std.testing.expectEqual(@as(usize, 1), last.names.len);
    try std.testing.expectEqualStrings("d", last.names[0]);
    try std.testing.expect(!last.has_more);
    try std.testing.expect(last.cursor == null);
}

test "listActions sends its prefix as the key, and only the limit and cursor as the value" {
    const a = std.testing.allocator;
    var srv = try test_server.OkServer.listen();
    srv.body = &.{ 0, 0, 0, 0, 0, 0, 0 };
    try srv.start();
    defer srv.deinit();
    var client = @import("client.zig").Client.init(a, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var actions = Actions.init(&client);

    var page = try actions.listActions(.{ .prefix = "send-", .limit = 5, .cursor = "c" });
    defer page.deinit();
    try std.testing.expectEqualStrings("send-", srv.lastKey());
    try std.testing.expectEqualSlices(u8, &.{ 5, 0, 0, 0, 'c' }, srv.lastValue());
    try std.testing.expectEqual(@as(usize, 0), page.names.len);
}

test "an action.list answer cut short or short of memory is refused and leaks nothing" {
    const data = [_]u8{ 2, 0, 0, 0, 1, 0, 'a', 0, 0, 0, 0, 2, 0, 'b', 'c', 0, 0, 0, 0, 1, 3, 0, 1, 0, 9 };
    for (0..data.len) |cut| {
        try std.testing.expectError(FloError.IncompleteResponse, decodeActionListAnswer(std.testing.allocator, data[0..cut]));
    }
    // A count the data can't hold.
    try std.testing.expectError(FloError.IncompleteResponse, decodeActionListAnswer(std.testing.allocator, &.{ 0xff, 0xff, 0, 0, 0, 0, 0 }));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: std.mem.Allocator, d: []const u8) !void {
            var page = try decodeActionListAnswer(a, d);
            page.deinit();
        }
    }.run, .{@as([]const u8, &data)});
}

test "listWorkers sends its limit and cursor and returns the rows and the next cursor" {
    const a = std.testing.allocator;
    var answer: std.ArrayList(u8) = .empty;
    defer answer.deinit(a);
    try answer.appendSlice(a, &.{ 2, 0 });
    try testWorkerRow(&answer, a, "w1", 0, "host-a");
    try testWorkerRow(&answer, a, "w2", 2, null);
    try answer.appendSlice(a, &.{ 1, 2, 0, 'w', '2' }); // cursor "w2"

    var srv = try test_server.OkServer.listen();
    srv.replies = &.{ .{ .status = 0, .body = answer.items }, .{ .status = 0, .body = &.{ 0, 0, 0 } } };
    try srv.start();
    defer srv.deinit();
    var client = @import("client.zig").Client.init(a, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var actions = Actions.init(&client);

    var page = try actions.listWorkers(.{ .limit = 2, .cursor = "w0" });
    defer page.deinit();
    // [present][limit:u32][cursor_len:u16][cursor]
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 0, 0, 0, 2, 0, 'w', '0', 0, 0 }, srv.lastBody());
    try std.testing.expectEqual(@as(usize, 2), page.workers.len);
    const w1 = page.workers[0];
    try std.testing.expectEqualStrings("w1", w1.id);
    try std.testing.expectEqual(types.WorkerType.stream, w1.worker_type);
    try std.testing.expectEqual(types.WorkerStatus.active, w1.status);
    try std.testing.expectEqual(@as(u32, 2), w1.current_load);
    try std.testing.expectEqual(@as(u32, 8), w1.max_concurrency);
    try std.testing.expectEqual(@as(u64, 5), w1.tasks_completed);
    try std.testing.expectEqual(@as(u64, 1), w1.tasks_failed);
    try std.testing.expectEqual(@as(i64, 1000), w1.registered_at_ms);
    try std.testing.expectEqual(@as(i64, 2000), w1.last_heartbeat_ms);
    try std.testing.expectEqualStrings("host-a", w1.machine_id.?);
    try std.testing.expectEqual(types.WorkerStatus.draining, page.workers[1].status);
    try std.testing.expect(page.workers[1].machine_id == null);
    try std.testing.expectEqualStrings("w2", page.cursor.?);

    // The first page: an empty cursor and the default limit, the server's;
    // only workers running "send".
    var last = try actions.listWorkers(.{ .action = "send" });
    defer last.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 4, 0, 0, 0, 0, 4, 0, 's', 'e', 'n', 'd' }, srv.lastBody());
    try std.testing.expectEqual(@as(usize, 0), last.workers.len);
    try std.testing.expect(last.cursor == null);
}

test "listWorkers refuses a limit out of range before sending, and an answer it can't read whole" {
    const a = std.testing.allocator;
    var client = @import("client.zig").Client.init(a, "localhost:1", .{});
    defer client.deinit();
    var actions = Actions.init(&client);
    try std.testing.expectError(FloError.BadRequest, actions.listWorkers(.{ .limit = 0 }));
    try std.testing.expectError(FloError.BadRequest, actions.listWorkers(.{ .limit = types.MAX_WORKER_LIST + 1 }));

    // One row, then no cursor: read whole as it stands.
    var ok: std.ArrayList(u8) = .empty;
    defer ok.deinit(a);
    try ok.appendSlice(a, &.{ 1, 0 });
    try testWorkerRow(&ok, a, "w", 0, null);
    try ok.append(a, 0);
    var page = try decodeWorkerListAnswer(a, ok.items);
    page.deinit();

    const status_at = 2 + 2 + 1 + 1; // count, id length, id, worker_type
    const unknown_status = try a.dupe(u8, ok.items);
    defer a.free(unknown_status);
    unknown_status[status_at] = 9;
    const trailing = try std.mem.concat(a, u8, &.{ ok.items, &.{7} });
    defer a.free(trailing);
    const cut = ok.items[0 .. ok.items.len - 3];
    const too_many = [_]u8{ 0xff, 0xff, 0 };
    for ([_][]const u8{ unknown_status, trailing, cut, &too_many }) |data| {
        try std.testing.expectError(FloError.IncompleteResponse, decodeWorkerListAnswer(a, data));
    }
}

fn decodeWorkerListAndFree(allocator: std.mem.Allocator, data: []const u8) !void {
    var page = try decodeWorkerListAnswer(allocator, data);
    page.deinit();
}

test "a worker.list answer frees what it allocated when an allocation fails" {
    const a = std.testing.allocator;
    var answer: std.ArrayList(u8) = .empty;
    defer answer.deinit(a);
    try answer.appendSlice(a, &.{ 2, 0 });
    try testWorkerRow(&answer, a, "w1", 0, "host-a");
    try testWorkerRow(&answer, a, "w2", 1, null);
    try answer.appendSlice(a, &.{ 1, 2, 0, 'w', '2' }); // cursor "w2"
    try std.testing.checkAllAllocationFailures(a, decodeWorkerListAndFree, .{@as([]const u8, answer.items)});
}

fn testProcessRow(out: *std.ArrayList(u8), a: std.mem.Allocator, name: []const u8, kind: u8, runs: u64) !void {
    var n: [8]u8 = undefined;
    std.mem.writeInt(u16, n[0..2], @intCast(name.len), .little);
    try out.appendSlice(a, n[0..2]);
    try out.appendSlice(a, name);
    try out.append(a, kind);
    for ([_]u64{ runs, 1, 3000 }) |v| { // run_count, fail_count, last_run_at_ms
        std.mem.writeInt(u64, &n, v, .little);
        try out.appendSlice(a, &n);
    }
}

/// worker.info's answer for "w1": metadata `{"a":1}`, an action and a
/// stream consumer.
fn testWorkerInfoAnswer(a: std.mem.Allocator) !std.ArrayList(u8) {
    var answer: std.ArrayList(u8) = .empty;
    errdefer answer.deinit(a);
    try testWorkerRow(&answer, a, "w1", 0, "host-a");
    try answer.appendSlice(a, &.{ 1, 7, 0 });
    try answer.appendSlice(a, "{\"a\":1}");
    try answer.appendSlice(a, &.{ 2, 0 });
    try testProcessRow(&answer, a, "send", 0, 9);
    try testProcessRow(&answer, a, "events/g", 1, 4);
    return answer;
}

test "workerInfo sends the worker id and returns its row, metadata and processes" {
    const a = std.testing.allocator;
    var answer = try testWorkerInfoAnswer(a);
    defer answer.deinit(a);
    var bare: std.ArrayList(u8) = .empty;
    defer bare.deinit(a);
    try testWorkerRow(&bare, a, "w2", 1, null);
    try bare.appendSlice(a, &.{ 0, 0, 0 }); // no metadata, no processes

    var srv = try test_server.OkServer.listen();
    srv.replies = &.{ .{ .status = 0, .body = answer.items }, .{ .status = 0, .body = bare.items } };
    try srv.start();
    defer srv.deinit();
    var client = @import("client.zig").Client.init(a, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var actions = Actions.init(&client);

    var info = try actions.workerInfo("w1", .{});
    defer info.deinit();
    try std.testing.expectEqualStrings("w1", srv.lastKey());
    try std.testing.expectEqualStrings("", srv.lastBody());
    try std.testing.expectEqualStrings("w1", info.worker.id);
    try std.testing.expectEqual(types.WorkerStatus.active, info.worker.status);
    try std.testing.expectEqualStrings("host-a", info.worker.machine_id.?);
    try std.testing.expectEqualStrings("{\"a\":1}", info.metadata.?);
    try std.testing.expectEqual(@as(usize, 2), info.processes.len);
    try std.testing.expectEqualStrings("send", info.processes[0].name);
    try std.testing.expectEqual(types.ProcessKind.action, info.processes[0].kind);
    try std.testing.expectEqual(@as(u64, 9), info.processes[0].run_count);
    try std.testing.expectEqual(@as(u64, 1), info.processes[0].fail_count);
    try std.testing.expectEqual(@as(i64, 3000), info.processes[0].last_run_at_ms);
    try std.testing.expectEqualStrings("events/g", info.processes[1].name);
    try std.testing.expectEqual(types.ProcessKind.stream_consumer, info.processes[1].kind);

    var empty = try actions.workerInfo("w2", .{});
    defer empty.deinit();
    try std.testing.expectEqualStrings("w2", empty.worker.id);
    try std.testing.expect(empty.worker.machine_id == null);
    try std.testing.expect(empty.metadata == null);
    try std.testing.expectEqual(@as(usize, 0), empty.processes.len);
}

fn decodeWorkerInfoAndFree(allocator: std.mem.Allocator, data: []const u8) !void {
    var info = try decodeWorkerInfoAnswer(allocator, data);
    info.deinit();
}

test "a worker.info answer cut short, overlong, with an unknown kind or short of memory is refused and leaks nothing" {
    const a = std.testing.allocator;
    var answer = try testWorkerInfoAnswer(a);
    defer answer.deinit(a);
    for (0..answer.items.len) |n| try std.testing.expectError(FloError.IncompleteResponse, decodeWorkerInfoAndFree(a, answer.items[0..n]));
    try answer.append(a, 0);
    try std.testing.expectError(FloError.IncompleteResponse, decodeWorkerInfoAndFree(a, answer.items));
    _ = answer.pop();

    // The second process's kind byte.
    const kind_at = answer.items.len - (8 + 8 + 8) - 1;
    try std.testing.expectEqual(@as(u8, 1), answer.items[kind_at]);
    answer.items[kind_at] = 2;
    try std.testing.expectError(FloError.IncompleteResponse, decodeWorkerInfoAndFree(a, answer.items));
    answer.items[kind_at] = 1;

    try std.testing.checkAllAllocationFailures(a, decodeWorkerInfoAndFree, .{@as([]const u8, answer.items)});
}

test "a registration carries every process, metadata and machine id; the server judges the limits" {
    const a = std.testing.allocator;
    const value = try encodeRegisterValue(a, null, .{
        .worker_type = .stream,
        .max_concurrency = 3,
        .processes = &.{ .{ .name = "s/g", .kind = .stream_consumer }, .{ .name = "x" } },
        .metadata = "m",
        .machine_id = "h",
    });
    defer a.free(value);
    try std.testing.expectEqualSlices(u8, "\x01\x03\x00\x00\x00\x02\x00" ++ "\x03\x00s/g\x01" ++ "\x01\x00x\x00" ++ "\x01\x01\x00m" ++ "\x01\x01\x00h", value);

    // More than the server keeps still goes out: 1025 action names.
    var names: [1025][]const u8 = undefined;
    for (&names) |*n| n.* = "a";
    const many = try encodeRegisterValue(a, &names, .{});
    defer a.free(many);
    try std.testing.expectEqual(@as(u16, 1025), std.mem.readInt(u16, many[5..7], .little));
    try std.testing.expectEqual(@as(usize, 7 + 1025 * 4 + 2), many.len);
}
