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
        var value_buf: [11 + types.MAX_ACTION_NAME]u8 = undefined;
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

    /// Wait up to `options.block_ms` for a run of one of `action_names`, the
    /// first tried first, and take it; null if none was ready in time.
    /// **Caller owns the returned `TaskAssignment` and must call `result.deinit()`.**
    pub fn awaitTask(
        self: *Self,
        worker_id: []const u8,
        action_names: []const []const u8,
        options: types.WorkerAwaitOptions,
    ) FloError!?types.TaskAssignment {
        var buf: [MAX_AWAIT_BODY]u8 = undefined;
        const body = try encodeAwaitBody(&buf, action_names, options.block_ms, options.request_key);
        var response = try self.client.sendRequest(.action_await, self.client.getNamespace(options.namespace), worker_id, body, "");
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        return decodeAwaitAnswer(self.client.allocator, response.data);
    }

    /// Complete a task: its run is done, with `result_data`. A resend of a
    /// complete that already applied answers ok; one for a delivery that
    /// has moved on is `FloError.StaleReport`.
    pub fn complete(
        self: *Self,
        worker_id: []const u8,
        delivery: types.Delivery,
        result_data: []const u8,
        options: types.WorkerCompleteOptions,
    ) FloError!void {
        if (options.outcome.len > types.MAX_ACTION_NAME or result_data.len > types.MAX_REPORT_TEXT) return FloError.ValueTooLarge;
        const body = try self.client.allocator.alloc(u8, deliveryFieldsSize(worker_id, delivery) + 3 + options.outcome.len + 3 + result_data.len);
        defer self.client.allocator.free(body);
        var w: std.Io.Writer = .fixed(body);
        try writeDeliveryFields(&w, worker_id, delivery);
        writeDefaultedBytes(&w, options.outcome);
        writeDefaultedBytes(&w, result_data);
        try self.report(.action_complete, delivery.run_id, options.namespace, w.buffered());
    }

    /// Fail a task: its run is ready again after `options.delay_ms`, unless
    /// its attempts are spent or `options.retry` is false. A resend of a
    /// fail that already applied answers ok; one for a delivery that has
    /// moved on is `FloError.StaleReport`.
    pub fn fail(
        self: *Self,
        worker_id: []const u8,
        delivery: types.Delivery,
        error_message: []const u8,
        options: types.WorkerFailOptions,
    ) FloError!void {
        if (error_message.len > types.MAX_REPORT_TEXT) return FloError.ValueTooLarge;
        if (options.delay_ms > types.MAX_FAIL_DELAY_MS) return FloError.BadRequest;
        const body = try self.client.allocator.alloc(u8, deliveryFieldsSize(worker_id, delivery) + 2 + 2 + 9 + 3 + error_message.len);
        defer self.client.allocator.free(body);
        var w: std.Io.Writer = .fixed(body);
        try writeDeliveryFields(&w, worker_id, delivery);
        w.writeAll(&.{ 1, @intFromBool(options.retry), 1, @intFromBool(options.abandoned), 1 }) catch unreachable;
        w.writeInt(u64, options.delay_ms, .little) catch unreachable;
        writeDefaultedBytes(&w, error_message);
        try self.report(.action_fail, delivery.run_id, options.namespace, w.buffered());
    }

    /// Keep a task: with half its lease or less left, the lease runs a full
    /// lease from now; with more left, nothing changes. Touch at least
    /// every half lease. Whatever the touches, a run is held at most 12 h
    /// from its delivery, then taken back. Returns when the lease runs out
    /// without another touch, in Unix milliseconds. A touch
    /// for a delivery that has moved on is `FloError.StaleReport`.
    pub fn touch(
        self: *Self,
        worker_id: []const u8,
        delivery: types.Delivery,
        options: types.WorkerTouchOptions,
    ) FloError!i64 {
        var buf: [MAX_DELIVERY_FIELDS]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try writeDeliveryFields(&w, worker_id, delivery);
        var response = try self.client.sendRequest(.action_touch, self.client.getNamespace(options.namespace), delivery.run_id, w.buffered(), "");
        defer response.deinit();
        if (response.status != .ok) return reportError(self.client, response.status);
        var r: Reader = .{ .data = response.data };
        const expires_at_ms = try r.int(i64);
        try r.end();
        return expires_at_ms;
    }

    /// Send a complete or fail, keyed by its run.
    fn report(self: *Self, op: types.OpCode, run_id: []const u8, namespace: ?[]const u8, body: []const u8) FloError!void {
        var response = try self.client.sendRequest(op, self.client.getNamespace(namespace), run_id, body, "");
        defer response.deinit();
        if (response.status != .ok) return reportError(self.client, response.status);
        if (response.data.len != 0) return FloError.IncompleteResponse;
    }

    /// An action's definition, its runs by status and how long completed
    /// runs took. An action not registered is `FloError.NotFound`.
    /// **Caller owns the returned `ActionInfo` and must call `info.deinit()`.**
    pub fn info(self: *Self, action_name: []const u8, options: types.ActionStatusOptions) FloError!types.ActionInfo {
        var response = try self.client.sendRequest(.action_info, self.client.getNamespace(options.namespace), action_name, "", "");
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        return decodeActionInfo(self.client.allocator, response.data);
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

// The task ops are table ops: the request is [namespace][key][body], the
// body coded by the op's schema in field order. An optional field is a
// presence byte then its value; a field with a default is sent present. A
// byte string or list has a length prefix as wide as its bound needs.

/// The most an await body takes: the actions, block_ms, request_key.
const MAX_AWAIT_BODY = 1 + types.MAX_AWAIT_ACTIONS * (2 + types.MAX_ACTION_NAME) + 9 + 2 + types.MAX_REQUEST_KEY;

/// action.await's request: actions, block_ms, request_key.
fn encodeAwaitBody(buf: *[MAX_AWAIT_BODY]u8, action_names: []const []const u8, block_ms: u32, request_key: ?[]const u8) FloError![]const u8 {
    if (action_names.len > types.MAX_AWAIT_ACTIONS) return FloError.BadRequest;
    for (action_names) |name| if (name.len > types.MAX_ACTION_NAME) return FloError.ValueTooLarge;
    if ((request_key orelse "").len > types.MAX_REQUEST_KEY) return FloError.ValueTooLarge;
    try types.checkBlockMs(block_ms);
    var w: std.Io.Writer = .fixed(buf);
    w.writeByte(@intCast(action_names.len)) catch unreachable;
    for (action_names) |name| {
        w.writeInt(u16, @intCast(name.len), .little) catch unreachable;
        w.writeAll(name) catch unreachable;
    }
    w.writeByte(1) catch unreachable;
    w.writeInt(u64, block_ms, .little) catch unreachable;
    if (request_key) |k| {
        w.writeAll(&.{ 1, @intCast(k.len) }) catch unreachable;
        w.writeAll(k) catch unreachable;
    } else w.writeByte(0) catch unreachable;
    return w.buffered();
}

/// The block_ms of an await body `encodeAwaitBody` wrote, for the client's
/// read timeout; 0 if the body can't be read.
pub fn awaitBodyBlockMs(body: []const u8) u64 {
    var r: Reader = .{ .data = body };
    const n = r.int(u8) catch return 0;
    for (0..n) |_| _ = r.lenBytes(u16) catch return 0;
    return (r.opt(u64) catch return 0) orelse 0;
}

/// The most the delivery fields of a report take.
const MAX_DELIVERY_FIELDS = 2 + types.MAX_ACTION_NAME + 2 + max_worker_id + 4 + 8 + 8;

fn deliveryFieldsSize(worker_id: []const u8, delivery: types.Delivery) usize {
    return 2 + delivery.action.len + 2 + worker_id.len + 4 + 8 + 8;
}

/// The fields every report opens with: action, worker, deliveries, term,
/// index.
fn writeDeliveryFields(w: *std.Io.Writer, worker_id: []const u8, delivery: types.Delivery) FloError!void {
    if (delivery.action.len > types.MAX_ACTION_NAME or worker_id.len > max_worker_id) return FloError.ValueTooLarge;
    w.writeInt(u16, @intCast(delivery.action.len), .little) catch unreachable;
    w.writeAll(delivery.action) catch unreachable;
    w.writeInt(u16, @intCast(worker_id.len), .little) catch unreachable;
    w.writeAll(worker_id) catch unreachable;
    w.writeInt(u32, delivery.deliveries, .little) catch unreachable;
    w.writeInt(u64, delivery.term, .little) catch unreachable;
    w.writeInt(u64, delivery.index, .little) catch unreachable;
}

/// A defaulted byte string of at most 65535 bytes, sent present.
fn writeDefaultedBytes(w: *std.Io.Writer, bytes: []const u8) void {
    w.writeByte(1) catch unreachable;
    w.writeInt(u16, @intCast(bytes.len), .little) catch unreachable;
    w.writeAll(bytes) catch unreachable;
}

/// A report's refusal as its error: a stale one is its own.
fn reportError(client: *const Client, status: types.StatusCode) FloError {
    if (status == .conflict) if (client.lastError()) |last| if (last.reason == .stale_report) return FloError.StaleReport;
    return status.toError();
}

/// The longest run id and caller names a task carries.
const max_run_id = 4096;
/// The longest namespace a task names.
const max_namespace = 63;
/// The longest input a task carries.
const max_input = 65_536;

/// action.await's answer: task?, which is {run, namespace, deliveries,
/// term, index, action, created_at_ms, attempt, lease_ms, caller_run?,
/// caller_workflow?, input}.
fn decodeAwaitAnswer(allocator: std.mem.Allocator, data: []const u8) FloError!?types.TaskAssignment {
    var r: Reader = .{ .data = data };
    if (!try r.boolean()) {
        try r.end();
        return null;
    }
    const run_id = try r.lenBytes(u16);
    const namespace = try r.lenBytes(u8);
    const deliveries = try r.int(u32);
    const term = try r.int(u64);
    const index = try r.int(u64);
    const action = try r.lenBytes(u16);
    const created_at = try r.int(i64);
    const attempt = try r.int(u32);
    const lease_ms = try r.int(u64);
    const caller_run = if (try r.boolean()) try r.lenBytes(u16) else null;
    const caller_workflow = if (try r.boolean()) try r.lenBytes(u16) else null;
    const input = try r.lenBytes(u32);
    try r.end();
    if (run_id.len > max_run_id or namespace.len > max_namespace or action.len > types.MAX_ACTION_NAME or input.len > max_input) return FloError.IncompleteResponse;
    for ([_]?[]const u8{ caller_run, caller_workflow }) |c| if ((c orelse "").len > max_run_id) return FloError.IncompleteResponse;

    const run_copy = try allocator.dupe(u8, run_id);
    errdefer allocator.free(run_copy);
    const ns_copy = try allocator.dupe(u8, namespace);
    errdefer allocator.free(ns_copy);
    const action_copy = try allocator.dupe(u8, action);
    errdefer allocator.free(action_copy);
    const caller_run_copy = if (caller_run) |c| try allocator.dupe(u8, c) else null;
    errdefer if (caller_run_copy) |c| allocator.free(c);
    const caller_workflow_copy = if (caller_workflow) |c| try allocator.dupe(u8, c) else null;
    errdefer if (caller_workflow_copy) |c| allocator.free(c);
    return .{
        .run_id = run_copy,
        .namespace = ns_copy,
        .deliveries = deliveries,
        .term = term,
        .index = index,
        .action = action_copy,
        .created_at = created_at,
        .attempt = attempt,
        .lease_ms = lease_ms,
        .caller_run_id = caller_run_copy,
        .caller_workflow_name = caller_workflow_copy,
        .payload = try allocator.dupe(u8, input),
        .allocator = allocator,
    };
}

/// action.info's answer: owner, version, timeout_ms, max_attempts,
/// created_at_ms, ready, ready_capped, too_many_runs, then running,
/// completed, failed, timed_out and the latency count, mean, median, p95
/// and max, each optional.
fn decodeActionInfo(allocator: std.mem.Allocator, data: []const u8) FloError!types.ActionInfo {
    var r: Reader = .{ .data = data };
    const owner = try r.lenBytes(u16);
    if (owner.len > types.MAX_ACTION_NAME) return FloError.IncompleteResponse;
    var out: types.ActionInfo = .{
        .owner = "",
        .version = try r.int(u32),
        .timeout_ms = try r.int(u64),
        .max_attempts = try r.int(u32),
        .created_at_ms = try r.int(i64),
        .ready = try r.int(u64),
        .ready_capped = try r.boolean(),
        .too_many_runs = try r.boolean(),
        .running = try r.opt(u64),
        .completed = try r.opt(u64),
        .failed = try r.opt(u64),
        .timed_out = try r.opt(u64),
        .latency_count = try r.opt(u64),
        .latency_avg_ms = try r.opt(u64),
        .latency_p50_ms = try r.opt(u64),
        .latency_p95_ms = try r.opt(u64),
        .latency_max_ms = try r.opt(u64),
        .allocator = allocator,
    };
    try r.end();
    out.owner = try allocator.dupe(u8, owner);
    return out;
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

/// action.list's answer: actions (u32 count), each a name and a value,
/// then the list trailer.
///   [count:u32]([name_len:u16][name][value_len:u32][version:u32]
///   [owner_len:u16][owner][timeout_ms:u64][max_attempts:u32][created_at_ms:i64])*
///   [has_more:u8][cursor_len:u16][cursor]
fn decodeActionListAnswer(allocator: std.mem.Allocator, data: []const u8) FloError!types.ActionListPage {
    var r: Reader = .{ .data = data };
    const n = try r.int(u32);
    // Each entry is at least its name's length and its value: a count the
    // data can't hold is refused before it sizes an allocation.
    if (n > r.remaining() / min_action_entry) return FloError.IncompleteResponse;
    const entries = try allocator.alloc(types.ActionListEntry, n);
    var got: usize = 0;
    errdefer {
        for (entries[0..got]) |e| {
            allocator.free(e.name);
            allocator.free(e.owner);
        }
        allocator.free(entries);
    }
    while (got < n) : (got += 1) {
        const name = try r.lenBytes(u16);
        var v: Reader = .{ .data = try r.lenBytes(u32) };
        const version = try v.int(u32);
        const owner = try v.lenBytes(u16);
        const timeout_ms = try v.int(u64);
        const max_attempts = try v.int(u32);
        const created_at_ms = try v.int(i64);
        try v.end();
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        entries[got] = .{
            .name = name_copy,
            .version = version,
            .owner = try allocator.dupe(u8, owner),
            .timeout_ms = timeout_ms,
            .max_attempts = max_attempts,
            .created_at_ms = created_at_ms,
        };
    }
    const trailer = try wire.parseListTrailer(data, r.pos);
    return .{
        .actions = entries,
        .has_more = trailer.has_more,
        .cursor = if (trailer.cursor) |c| try allocator.dupe(u8, c) else null,
        .allocator = allocator,
    };
}

/// An action.list entry's smallest encoding: an empty name and owner.
const min_action_entry = 2 + 4 + 4 + 2 + 8 + 4 + 8;

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
/// [error_message:?(u16 len, bytes)][worker_id:?(u16 len, bytes)]
/// [outcome:?(u16 len, bytes)], each optional behind a presence byte.
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
    const outcome = if (try r.boolean()) try r.lenBytes(u16) else null;
    if (outcome) |o| if (o.len > types.MAX_ACTION_NAME) return FloError.IncompleteResponse;
    try r.end();

    const run_id_copy = allocator.dupe(u8, run_id) catch return FloError.OutOfMemory;
    errdefer allocator.free(run_id_copy);
    const output_copy = if (output) |o| allocator.dupe(u8, o) catch return FloError.OutOfMemory else null;
    errdefer if (output_copy) |o| allocator.free(o);
    const error_copy = if (error_message) |e| allocator.dupe(u8, e) catch return FloError.OutOfMemory else null;
    errdefer if (error_copy) |e| allocator.free(e);
    const worker_copy = if (worker_id) |w| allocator.dupe(u8, w) catch return FloError.OutOfMemory else null;
    errdefer if (worker_copy) |w| allocator.free(w);
    const outcome_copy = if (outcome) |o| try allocator.dupe(u8, o) else null;
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
        .outcome = outcome_copy,
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

const le = std.mem.toBytes;

/// action.await's answer as the server writes it: run "r1" in "ns",
/// delivery 2 at term 3, index 40, of "charge", attempt 2 with a 5 s lease,
/// invoked by run "wr" of "checkout", input "ping".
const test_await_answer = "\x01" ++ "\x02\x00r1" ++ "\x02ns" ++ le(@as(u32, 2)) ++ le(@as(u64, 3)) ++ le(@as(u64, 40)) ++
    "\x06\x00charge" ++ le(@as(i64, 1000)) ++ le(@as(u32, 2)) ++ le(@as(u64, 5000)) ++
    "\x01\x02\x00wr" ++ "\x01\x08\x00checkout" ++ "\x04\x00\x00\x00ping";

test "an await answer carries the delivery a report echoes, and none is null" {
    var task = (try decodeAwaitAnswer(std.testing.allocator, test_await_answer)).?;
    defer task.deinit();
    try std.testing.expectEqualStrings("r1", task.run_id);
    try std.testing.expectEqualStrings("ns", task.namespace);
    try std.testing.expectEqual(@as(u32, 2), task.deliveries);
    try std.testing.expectEqual(@as(u64, 3), task.term);
    try std.testing.expectEqual(@as(u64, 40), task.index);
    try std.testing.expectEqualStrings("charge", task.action);
    try std.testing.expectEqual(@as(i64, 1000), task.created_at);
    try std.testing.expectEqual(@as(u32, 2), task.attempt);
    try std.testing.expectEqual(@as(u64, 5000), task.lease_ms);
    try std.testing.expectEqualStrings("wr", task.caller_run_id.?);
    try std.testing.expectEqualStrings("checkout", task.caller_workflow_name.?);
    try std.testing.expectEqualStrings("ping", task.payload);
    const d = task.delivery();
    try std.testing.expectEqualStrings("r1", d.run_id);
    try std.testing.expectEqualStrings("charge", d.action);
    try std.testing.expectEqual(@as(u32, 2), d.deliveries);

    try std.testing.expect(try decodeAwaitAnswer(std.testing.allocator, "\x00") == null);
    try std.testing.expectError(FloError.IncompleteResponse, decodeAwaitAnswer(std.testing.allocator, "\x00\x00"));
}

fn decodeAwaitAndFree(a: std.mem.Allocator, data: []const u8) !void {
    if (try decodeAwaitAnswer(a, data)) |t| {
        var task = t;
        task.deinit();
    }
}

test "an await answer cut anywhere, overlong or short of memory is refused and leaks nothing" {
    const a = std.testing.allocator;
    const data: []const u8 = test_await_answer;
    for (0..data.len) |n| try std.testing.expectError(FloError.IncompleteResponse, decodeAwaitAndFree(a, data[0..n]));
    try std.testing.expectError(FloError.IncompleteResponse, decodeAwaitAndFree(a, test_await_answer ++ "\x00"));
    try std.testing.checkAllAllocationFailures(a, decodeAwaitAndFree, .{data});
}

/// A loopback server answering each request with the next of `replies`,
/// and a client on it.
const Fake = struct {
    srv: test_server.OkServer,
    client: Client = undefined,

    fn start(f: *Fake, replies: []const test_server.Reply) !void {
        f.srv = try test_server.OkServer.listen();
        f.srv.replies = replies;
        try f.srv.start();
        f.client = Client.init(std.testing.allocator, f.srv.endpoint, .{ .retry = .{ .initial_backoff_ms = 1, .max_backoff_ms = 1 } });
        try f.client.connect();
    }

    fn stop(f: *Fake) void {
        f.client.deinit();
        f.srv.deinit();
    }
};

const test_delivery: types.Delivery = .{ .run_id = "r1", .action = "echo", .deliveries = 2, .term = 3, .index = 40 };

/// The fields every report opens with, for `test_delivery` from "w1".
const test_delivery_fields = "\x04\x00echo" ++ "\x02\x00w1" ++ le(@as(u32, 2)) ++ le(@as(u64, 3)) ++ le(@as(u64, 40));

test "awaitTask sends the actions, block_ms and request key as its body, keyed by the worker" {
    var f: Fake = .{ .srv = undefined };
    try f.start(&.{ .{ .status = 0, .body = test_await_answer }, .{ .status = 0, .body = "\x00" } });
    defer f.stop();
    var actions = Actions.init(&f.client);

    var task = (try actions.awaitTask("w1", &.{ "charge", "refund" }, .{ .block_ms = 500, .request_key = "rk-1" })).?;
    defer task.deinit();
    try std.testing.expectEqual(@as(u16, 0x30A), f.srv.last_op);
    try std.testing.expectEqualStrings("w1", f.srv.lastKey());
    try std.testing.expectEqualSlices(u8, "\x02" ++ "\x06\x00charge" ++ "\x06\x00refund" ++ "\x01" ++ le(@as(u64, 500)) ++ "\x01\x04rk-1", f.srv.lastBody());
    try std.testing.expectEqual(@as(u64, 500), awaitBodyBlockMs(f.srv.lastBody()));

    // No key: none, and the server's default wait.
    try std.testing.expect(try actions.awaitTask("w1", &.{"charge"}, .{}) == null);
    try std.testing.expectEqualSlices(u8, "\x01" ++ "\x06\x00charge" ++ "\x01" ++ le(@as(u64, 30_000)) ++ "\x00", f.srv.lastBody());
}

test "awaitTask refuses what the server would, before sending" {
    var client = Client.init(std.testing.allocator, "localhost:1", .{});
    defer client.deinit();
    var actions = Actions.init(&client);
    var names: [65][]const u8 = undefined;
    for (&names) |*n| n.* = "a";
    try std.testing.expectError(FloError.BadRequest, actions.awaitTask("w", &names, .{}));
    try std.testing.expectError(FloError.ValueTooLarge, actions.awaitTask("w", &.{"n" ** 257}, .{}));
    try std.testing.expectError(FloError.ValueTooLarge, actions.awaitTask("w", &.{"a"}, .{ .request_key = "k" ** 65 }));
    try std.testing.expectError(FloError.BlockTooLong, actions.awaitTask("w", &.{"a"}, .{ .block_ms = types.MAX_BLOCK_MS + 1 }));
}

/// A touch's answer: expires_at_ms 9000.
const test_expiry = le(@as(i64, 9000));

test "complete, fail and touch echo the delivery, keyed by its run" {
    var f: Fake = .{ .srv = undefined };
    try f.start(&.{ .{ .status = 0 }, .{ .status = 0 }, .{ .status = 0 }, .{ .status = 0, .body = &test_expiry } });
    defer f.stop();
    var actions = Actions.init(&f.client);

    try actions.complete("w1", test_delivery, "pong", .{});
    try std.testing.expectEqual(@as(u16, 0x30B), f.srv.last_op);
    try std.testing.expectEqualStrings("r1", f.srv.lastKey());
    // The outcome "" is success.
    try std.testing.expectEqualSlices(u8, test_delivery_fields ++ "\x01\x00\x00" ++ "\x01\x04\x00pong", f.srv.lastBody());

    try actions.complete("w1", test_delivery, "", .{ .outcome = "approved" });
    try std.testing.expectEqualSlices(u8, test_delivery_fields ++ "\x01\x08\x00approved" ++ "\x01\x00\x00", f.srv.lastBody());

    try actions.fail("w1", test_delivery, "boom", .{ .abandoned = true, .delay_ms = 250 });
    try std.testing.expectEqual(@as(u16, 0x30C), f.srv.last_op);
    try std.testing.expectEqualStrings("r1", f.srv.lastKey());
    // retry (true), abandoned, delay_ms, error.
    try std.testing.expectEqualSlices(u8, test_delivery_fields ++ "\x01\x01" ++ "\x01\x01" ++ "\x01" ++ le(@as(u64, 250)) ++ "\x01\x04\x00boom", f.srv.lastBody());

    // No extend length: the server keeps the lease the action has.
    try std.testing.expectEqual(@as(i64, 9000), try actions.touch("w1", test_delivery, .{}));
    try std.testing.expectEqual(@as(u16, 0x30D), f.srv.last_op);
    try std.testing.expectEqualStrings("r1", f.srv.lastKey());
    try std.testing.expectEqualSlices(u8, test_delivery_fields, f.srv.lastBody());
}

test "a stale report is its own error, and any other conflict isn't" {
    // conflict, [reason:u16][ran:u8][message]
    const stale: test_server.Reply = .{ .status = 8, .body = "\x1a\x00\x00stale report: the run was completed with another result" };
    const other: test_server.Reply = .{ .status = 8, .body = "\x0c\x00\x00conflict" };
    var f: Fake = .{ .srv = undefined };
    try f.start(&.{ stale, stale, stale, other });
    defer f.stop();
    var actions = Actions.init(&f.client);
    try std.testing.expectError(FloError.StaleReport, actions.complete("w1", test_delivery, "other", .{}));
    try std.testing.expectEqualStrings("stale report: the run was completed with another result", f.client.lastError().?.message);
    try std.testing.expectError(FloError.StaleReport, actions.fail("w1", test_delivery, "", .{}));
    try std.testing.expectError(FloError.StaleReport, actions.touch("w1", test_delivery, .{}));
    try std.testing.expectError(FloError.Conflict, actions.complete("w1", test_delivery, "", .{}));
    // None was sent again.
    try std.testing.expectEqual(@as(u32, 4), f.srv.requests.load(.acquire));
}

test "a report refused while the leader isn't ready is sent again, not surfaced" {
    // unavailable, reason leader_unknown, ran no.
    const not_ready: test_server.Reply = .{ .status = 12, .body = "\x05\x00\x00unavailable: this node's leadership isn't settled yet; retry" };
    var f: Fake = .{ .srv = undefined };
    try f.start(&.{ not_ready, not_ready, .{ .status = 0 } });
    defer f.stop();
    var actions = Actions.init(&f.client);
    try actions.complete("w1", test_delivery, "pong", .{});
    try std.testing.expectEqual(@as(u32, 3), f.srv.requests.load(.acquire));
    // Each try a new request.
    try std.testing.expect(f.srv.ids[0] != f.srv.ids[1] and f.srv.ids[1] != f.srv.ids[2]);
}

test "complete and fail refuse a result, error or delay the server would" {
    var client = Client.init(std.testing.allocator, "localhost:1", .{});
    defer client.deinit();
    var actions = Actions.init(&client);
    const long = "x" ** (types.MAX_REPORT_TEXT + 1);
    try std.testing.expectError(FloError.ValueTooLarge, actions.complete("w1", test_delivery, long, .{}));
    try std.testing.expectError(FloError.ValueTooLarge, actions.complete("w1", test_delivery, "", .{ .outcome = "o" ** 257 }));
    try std.testing.expectError(FloError.ValueTooLarge, actions.fail("w1", test_delivery, long, .{}));
    try std.testing.expectError(FloError.BadRequest, actions.fail("w1", test_delivery, "", .{ .delay_ms = types.MAX_FAIL_DELAY_MS + 1 }));
}

/// action.info's answer: owner "ops", version 2, a 5 s lease, 3 attempts,
/// 4 ready, counted; 1 running, 7 completed, none failed or timed out, and
/// 7 measured, 10/9/20/30 ms.
const test_info_answer = "\x03\x00ops" ++ le(@as(u32, 2)) ++ le(@as(u64, 5000)) ++ le(@as(u32, 3)) ++ le(@as(i64, 1000)) ++ le(@as(u64, 4)) ++ "\x00\x00" ++
    "\x01" ++ le(@as(u64, 1)) ++ "\x01" ++ le(@as(u64, 7)) ++ "\x01" ++ le(@as(u64, 0)) ++ "\x01" ++ le(@as(u64, 0)) ++
    "\x01" ++ le(@as(u64, 7)) ++ "\x01" ++ le(@as(u64, 10)) ++ "\x01" ++ le(@as(u64, 9)) ++ "\x01" ++ le(@as(u64, 20)) ++ "\x01" ++ le(@as(u64, 30));

test "action info reads the definition, the counts and the latency, keyed by the action" {
    var f: Fake = .{ .srv = undefined };
    // Too many runs to count: everything but ready is none.
    const sampled = "\x00\x00" ++ le(@as(u32, 1)) ++ le(@as(u64, 300_000)) ++ le(@as(u32, 3)) ++ le(@as(i64, 5)) ++ le(@as(u64, 100_000)) ++ "\x01\x01" ++ "\x00" ** 9;
    try f.start(&.{ .{ .status = 0, .body = test_info_answer }, .{ .status = 0, .body = sampled } });
    defer f.stop();
    var actions = Actions.init(&f.client);
    var info = try actions.info("echo", .{});
    defer info.deinit();
    try std.testing.expectEqual(@as(u16, 0x30F), f.srv.last_op);
    try std.testing.expectEqualStrings("echo", f.srv.lastKey());
    try std.testing.expectEqualStrings("", f.srv.lastBody());
    try std.testing.expectEqualStrings("ops", info.owner);
    try std.testing.expectEqual(@as(u32, 2), info.version);
    try std.testing.expectEqual(@as(u64, 5000), info.timeout_ms);
    try std.testing.expectEqual(@as(u64, 4), info.ready);
    try std.testing.expect(!info.ready_capped and !info.too_many_runs);
    try std.testing.expectEqual(@as(?u64, 7), info.completed);
    try std.testing.expectEqual(@as(?u64, 0), info.failed);
    try std.testing.expectEqual(@as(?u64, 9), info.latency_p50_ms);
    try std.testing.expectEqual(@as(?u64, 30), info.latency_max_ms);

    var big = try actions.info("echo", .{});
    defer big.deinit();
    try std.testing.expect(big.ready_capped and big.too_many_runs);
    try std.testing.expectEqual(@as(?u64, null), big.running);
    try std.testing.expectEqual(@as(?u64, null), big.latency_count);
}

test "an action info answer cut anywhere or overlong is refused" {
    const data: []const u8 = test_info_answer;
    for (0..data.len) |n| try std.testing.expectError(FloError.IncompleteResponse, decodeActionInfo(std.testing.allocator, data[0..n]));
    try std.testing.expectError(FloError.IncompleteResponse, decodeActionInfo(std.testing.allocator, test_info_answer ++ "\x00"));
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
    "\x01\x02\x00w1" ++ // worker "w1"
    "\x01\x08\x00approved"; // outcome "approved"

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
    try std.testing.expectEqualStrings("approved", st.outcome.?);
}

test "a pending run's status names no worker" {
    const answer = "\x00" ++ // pending
        "\x64\x00\x00\x00\x00\x00\x00\x00" ++ // created_at 100
        "\x00\x00" ++ // not started, not completed
        "\x00\x00\x00\x00" ++ // attempt 0
        "\x00\x00" ++ // no output, no error
        "\x00" ++ // no worker
        "\x00"; // no outcome
    var st = try parseActionRunStatus(std.testing.allocator, "run-1", answer);
    defer st.deinit();
    try std.testing.expectEqual(types.RunStatus.pending, st.status);
    try std.testing.expectEqual(@as(?[]const u8, null), st.worker_id);
    try std.testing.expectEqual(@as(?[]const u8, null), st.outcome);
}

test "a status answer with a worker id over the server's bound is refused" {
    const answer = "\x00" ++ "\x64\x00\x00\x00\x00\x00\x00\x00" ++ "\x00\x00" ++ "\x00\x00\x00\x00" ++ "\x00\x00" ++
        "\x01\x01\x10" ++ "w" ** 4097 ++ "\x00";
    try std.testing.expectError(FloError.IncompleteResponse, parseActionRunStatus(std.testing.allocator, "run-1", answer));
}

test "a failed run's status carries its error and no output" {
    const answer = "\x03" ++ // failed
        "\x64\x00\x00\x00\x00\x00\x00\x00" ++ // created_at 100
        "\x00\x00" ++ // not started, not completed
        "\x03\x00\x00\x00" ++ // attempt 3
        "\x00" ++ // no output
        "\x01\x04\x00boom" ++ // error "boom"
        "\x01\x02\x00w1" ++ // last held by "w1"
        "\x00"; // no outcome
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

/// An action.list entry as the server writes it: version 2, a 30 s lease,
/// 3 attempts, created at 1000.
fn testListEntry(comptime name: []const u8, comptime owner: []const u8) []const u8 {
    return le(@as(u16, name.len)) ++ name ++ le(@as(u32, 4 + 2 + owner.len + 8 + 4 + 8)) ++
        le(@as(u32, 2)) ++ le(@as(u16, owner.len)) ++ owner ++ le(@as(u64, 30_000)) ++ le(@as(u32, 3)) ++ le(@as(i64, 1000));
}

/// The last page: one action, nothing more, no cursor.
const test_action_last = "\x01\x00\x00\x00" ++ testListEntry("d", "") ++ "\x00\x00\x00";

/// Two actions, then has_more and a 3-byte cursor.
const test_action_page = "\x02\x00\x00\x00" ++ testListEntry("a", "") ++ testListEntry("bc", "ops") ++ "\x01\x03\x00\x01\x00\x09";

test "listActions sends its limit and cursor and returns each action's definition, has_more and the next cursor" {
    const a = std.testing.allocator;
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{
        .{ .status = 0, .body = test_action_page },
        // The last page: nothing more, no cursor.
        .{ .status = 0, .body = test_action_last },
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
    try std.testing.expectEqual(@as(usize, 2), page.actions.len);
    try std.testing.expectEqualStrings("a", page.actions[0].name);
    const bc = page.actions[1];
    try std.testing.expectEqualStrings("bc", bc.name);
    try std.testing.expectEqualStrings("ops", bc.owner);
    try std.testing.expectEqual(@as(u32, 2), bc.version);
    try std.testing.expectEqual(@as(u64, 30_000), bc.timeout_ms);
    try std.testing.expectEqual(@as(u32, 3), bc.max_attempts);
    try std.testing.expectEqual(@as(i64, 1000), bc.created_at_ms);
    try std.testing.expect(page.has_more);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 9 }, page.cursor.?);

    // The next: the cursor follows the limit (0, the server's default).
    var last = try actions.listActions(.{ .cursor = page.cursor });
    defer last.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 1, 0, 9 }, srv.lastValue());
    try std.testing.expectEqualStrings("", srv.lastKey());
    try std.testing.expectEqual(@as(usize, 1), last.actions.len);
    try std.testing.expectEqualStrings("d", last.actions[0].name);
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
    try std.testing.expectEqual(@as(usize, 0), page.actions.len);
}

test "an action.list answer cut short, with an entry value of another length, or short of memory is refused and leaks nothing" {
    const data: []const u8 = test_action_page;
    for (0..data.len) |cut| {
        try std.testing.expectError(FloError.IncompleteResponse, decodeActionListAnswer(std.testing.allocator, data[0..cut]));
    }
    // A count the data can't hold.
    try std.testing.expectError(FloError.IncompleteResponse, decodeActionListAnswer(std.testing.allocator, &.{ 0xff, 0xff, 0, 0, 0, 0, 0 }));
    // The first entry's value one byte longer than its fields.
    var long = test_action_page.*;
    long[4 + 2 + 1] += 1;
    try std.testing.expectError(FloError.IncompleteResponse, decodeActionListAnswer(std.testing.allocator, &long));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: std.mem.Allocator, d: []const u8) !void {
            var page = try decodeActionListAnswer(a, d);
            page.deinit();
        }
    }.run, .{data});
}

test "an action.list answer whose cursor contradicts has_more is refused" {
    const a = std.testing.allocator;
    // No actions; has_more=0 with a cursor, then has_more=1 without one.
    try std.testing.expectError(FloError.UnexpectedResponse, decodeActionListAnswer(a, &.{ 0, 0, 0, 0, 0, 1, 0, 'c' }));
    try std.testing.expectError(FloError.UnexpectedResponse, decodeActionListAnswer(a, &.{ 0, 0, 0, 0, 1, 0, 0 }));
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
