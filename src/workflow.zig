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
const wire = @import("wire.zig");
const Client = @import("client.zig").Client;

const FloError = types.FloError;
const Allocator = std.mem.Allocator;

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
            return response.status.toError();
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
            return response.status.toError();
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
            return response.status.toError();
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
            return response.status.toError();
        }

        return parseWorkflowStatus(allocator, response.data) catch |err| answerError(err);
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
            return response.status.toError();
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
            return response.status.toError();
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
            return response.status.toError();
        }

        return allocator.dupe(u8, response.data) catch return FloError.OutOfMemory;
    }

    /// List one page of workflow runs, newest first: one workflow's, or
    /// every workflow's when `options.workflow_name` is null. Pass the
    /// page's cursor to get the next; stop when `has_more` is clear, not on
    /// a short page. Caller owns the result; call deinit() when done.
    pub fn listRuns(
        self: *Self,
        allocator: Allocator,
        options: types.WorkflowListRunsOptions,
    ) FloError!types.WorkflowListRunsResult {
        const ns = self.client.getNamespace(options.namespace);
        const key = options.workflow_name orelse "";

        const value = try encodeListRunsValue(self.client.allocator, options);
        defer self.client.allocator.free(value);

        var response = try self.client.sendRequest(
            .workflow_list_runs,
            ns,
            key,
            value,
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }

        return parseRunList(allocator, response.data) catch |err| answerError(err);
    }

    /// `[limit:u32][status_len:u16][status][cursor_len:u16][cursor][search_len:u16][search]`,
    /// every field sent, an absent one as length 0.
    fn encodeListRunsValue(allocator: Allocator, options: types.WorkflowListRunsOptions) FloError![]u8 {
        const fields = [_][]const u8{ options.status orelse "", options.cursor orelse "", options.search orelse "" };
        var len: usize = 4;
        for (fields) |f| {
            if (f.len > std.math.maxInt(u16)) return FloError.ValueTooLarge;
            len += 2 + f.len;
        }
        const value = allocator.alloc(u8, len) catch return FloError.OutOfMemory;
        std.mem.writeInt(u32, value[0..4], options.limit, .little);
        var pos: usize = 4;
        for (fields) |f| {
            std.mem.writeInt(u16, value[pos..][0..2], @intCast(f.len), .little);
            pos += 2;
            @memcpy(value[pos..][0..f.len], f);
            pos += f.len;
        }
        return value;
    }

    /// List one page of workflow definitions, from `options.cursor`. Pass the
    /// page's cursor to get the next; stop when `has_more` is clear, not on a
    /// short page.
    /// Caller owns the result; call deinit() when done.
    pub fn listDefinitions(
        self: *Self,
        allocator: Allocator,
        options: types.WorkflowListDefinitionsOptions,
    ) FloError!types.WorkflowListDefinitionsResult {
        const ns = self.client.getNamespace(options.namespace);

        const value = try wire.encodeListValue(self.client.allocator, options.limit, options.cursor orelse "");
        defer self.client.allocator.free(value);

        var response = try self.client.sendRequest(
            .workflow_list_definitions,
            ns,
            "",
            value,
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }

        return parseDefinitionList(allocator, response.data) catch |err| answerError(err);
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
            return response.status.toError();
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
            return response.status.toError();
        }
    }

    // =========================================================================
    // Declarative Sync
    // =========================================================================

    /// Result of a workflow sync operation.
    pub const SyncResult = struct {
        name: []const u8,
        version: []const u8,
        description: []const u8,
        action: []const u8, // "created", "updated", or "unchanged"
        allocator: Allocator,

        pub fn deinit(self: *SyncResult) void {
            self.allocator.free(self.name);
            self.allocator.free(self.version);
            self.allocator.free(self.description);
            // action is a static string, not allocated
        }
    };

    /// Sync a workflow from raw YAML bytes. Performs version-aware comparison:
    /// - If the workflow doesn't exist, creates it (action = "created")
    /// - If the version differs, updates it (action = "updated")
    /// - If the version matches, does nothing (action = "unchanged")
    ///
    /// Caller owns the result; call deinit() when done.
    pub fn syncBytes(
        self: *Self,
        allocator: Allocator,
        yaml: []const u8,
        options: types.WorkflowSyncOptions,
    ) FloError!SyncResult {
        const name = extractYamlField(yaml, "name") orelse return FloError.BadRequest;
        const version = extractYamlField(yaml, "version") orelse "1";
        const description = extractYamlField(yaml, "description") orelse "";

        // Check if workflow already exists with this version
        const existing = self.getDefinition(allocator, name, .{
            .namespace = options.namespace,
        }) catch |err| switch (err) {
            FloError.NotFound => null,
            else => return err,
        };

        var action: []const u8 = "created";

        if (existing) |existing_yaml| {
            defer allocator.free(existing_yaml);
            // Check if version matches
            const existing_version = extractYamlField(existing_yaml, "version") orelse "1";
            if (std.mem.eql(u8, version, existing_version)) {
                // Version unchanged
                const name_owned = allocator.dupe(u8, name) catch return FloError.OutOfMemory;
                errdefer allocator.free(name_owned);
                const version_owned = allocator.dupe(u8, version) catch return FloError.OutOfMemory;
                errdefer allocator.free(version_owned);
                const desc_owned = allocator.dupe(u8, description) catch return FloError.OutOfMemory;
                return .{
                    .name = name_owned,
                    .version = version_owned,
                    .description = desc_owned,
                    .action = "unchanged",
                    .allocator = allocator,
                };
            }
            action = "updated";
        }

        // Create/update the workflow
        try self.create(name, yaml, .{ .namespace = options.namespace });

        const name_owned = allocator.dupe(u8, name) catch return FloError.OutOfMemory;
        errdefer allocator.free(name_owned);
        const version_owned = allocator.dupe(u8, version) catch return FloError.OutOfMemory;
        errdefer allocator.free(version_owned);
        const desc_owned = allocator.dupe(u8, description) catch return FloError.OutOfMemory;

        return .{
            .name = name_owned,
            .version = version_owned,
            .description = desc_owned,
            .action = action,
            .allocator = allocator,
        };
    }
};

/// Extract a field value from YAML content (simple line-based extraction).
fn extractYamlField(data: []const u8, field: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (start < data.len) {
        // Find end of line
        var end = start;
        while (end < data.len and data[end] != '\n') : (end += 1) {}

        const line = data[start..end];
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        // Check if line starts with "field:"
        if (trimmed.len > field.len and
            std.mem.eql(u8, trimmed[0..field.len], field) and
            trimmed[field.len] == ':')
        {
            const after_colon = trimmed[field.len + 1 ..];
            const value = std.mem.trim(u8, after_colon, " \t\r\"'");
            if (value.len > 0) return value;
        }

        start = if (end < data.len) end + 1 else end;
    }
    return null;
}

/// workflow.list_definitions' answer:
///   [count:u32]([name_len:u16][name][version_len:u16][version][created_at:i64])*
///   [has_more:u8][cursor_len:u16][cursor]
fn parseDefinitionList(allocator: Allocator, data: []const u8) !types.WorkflowListDefinitionsResult {
    if (data.len < 4) return error.UnexpectedEndOfData;
    const count = std.mem.readInt(u32, data[0..4], .little);
    var pos: usize = 4;
    // Each entry is at least its two lengths and created_at: a count the data
    // can't hold is refused before it sizes an allocation.
    if (count > (data.len - pos) / (2 + 2 + 8)) return error.UnexpectedEndOfData;

    const entries = try allocator.alloc(types.WorkflowDefinitionEntry, count);
    var i: u32 = 0;
    errdefer {
        for (entries[0..i]) |*e| e.deinit(allocator);
        allocator.free(entries);
    }

    while (i < count) : (i += 1) {
        const name = try lenBytes(data, &pos);
        const version = try lenBytes(data, &pos);
        if (pos + 8 > data.len) return error.UnexpectedEndOfData;
        const created_at = std.mem.readInt(i64, data[pos..][0..8], .little);
        pos += 8;

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        entries[i] = .{
            .name = name_copy,
            .version = try allocator.dupe(u8, version),
            .created_at = created_at,
        };
    }

    const trailer = try wire.parseListTrailer(data, pos);
    return .{
        .definitions = entries,
        .has_more = trailer.has_more,
        .cursor = if (trailer.cursor) |c| try allocator.dupe(u8, c) else null,
        .allocator = allocator,
    };
}

/// workflow.list_runs' answer:
///   [count:u32]([run_id_len:u16][run_id][workflow_len:u16][workflow][status_len:u16][status][created_at:i64])*
///   [has_more:u8][cursor_len:u16][cursor]
fn parseRunList(allocator: Allocator, data: []const u8) !types.WorkflowListRunsResult {
    if (data.len < 4) return error.UnexpectedEndOfData;
    const count = std.mem.readInt(u32, data[0..4], .little);
    var pos: usize = 4;
    // Each entry is at least its three lengths and created_at: a count the
    // data can't hold is refused before it sizes an allocation.
    if (count > (data.len - pos) / (2 + 2 + 2 + 8)) return error.UnexpectedEndOfData;

    const runs = try allocator.alloc(types.WorkflowRunEntry, count);
    var i: u32 = 0;
    errdefer {
        for (runs[0..i]) |*r| r.deinit(allocator);
        allocator.free(runs);
    }

    while (i < count) : (i += 1) {
        const run_id = try lenBytes(data, &pos);
        const workflow = try lenBytes(data, &pos);
        const run_status = try lenBytes(data, &pos);
        if (pos + 8 > data.len) return error.UnexpectedEndOfData;
        const created_at = std.mem.readInt(i64, data[pos..][0..8], .little);
        pos += 8;

        const run_id_copy = try allocator.dupe(u8, run_id);
        errdefer allocator.free(run_id_copy);
        const workflow_copy = try allocator.dupe(u8, workflow);
        errdefer allocator.free(workflow_copy);
        runs[i] = .{
            .run_id = run_id_copy,
            .workflow = workflow_copy,
            .status = try allocator.dupe(u8, run_status),
            .created_at = created_at,
        };
    }

    const trailer = try wire.parseListTrailer(data, pos);
    return .{
        .runs = runs,
        .has_more = trailer.has_more,
        .cursor = if (trailer.cursor) |c| try allocator.dupe(u8, c) else null,
        .allocator = allocator,
    };
}

/// A u16-length-prefixed field, borrowed from `data`.
fn lenBytes(data: []const u8, pos: *usize) ![]const u8 {
    if (pos.* + 2 > data.len) return error.UnexpectedEndOfData;
    const len = std.mem.readInt(u16, data[pos.*..][0..2], .little);
    pos.* += 2;
    if (pos.* + len > data.len) return error.UnexpectedEndOfData;
    defer pos.* += len;
    return data[pos.*..][0..len];
}

/// A parse failure: out of memory stays itself, anything else is an answer
/// this client can't read.
fn answerError(err: anyerror) FloError {
    return if (err == error.OutOfMemory) FloError.OutOfMemory else FloError.UnexpectedResponse;
}

test "status short of memory says so, not that the answer is bad" {
    // run_id "r", workflow "", version "", status pending, step "", input "", created_at 0.
    const answer = "\x01\x00r" ++ "\x00\x00" ++ "\x00\x00" ++ "\x00" ++ "\x00\x00" ++
        "\x00\x00\x00\x00" ++ "\x00\x00\x00\x00\x00\x00\x00\x00";
    var srv = try @import("test_server.zig").OkServer.listen();
    srv.body = answer;
    try srv.start();
    defer srv.deinit();

    var client = Client.init(std.testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var workflow = Workflow.init(&client);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(FloError.OutOfMemory, workflow.status(failing.allocator(), "r", .{}));
}

// Two definitions: "a" v"1" at 5, "bc" v"" at -1; has_more=1, cursor "\x01\x00z".
const definitions_page = "\x02\x00\x00\x00" ++
    "\x01\x00a" ++ "\x01\x001" ++ "\x05\x00\x00\x00\x00\x00\x00\x00" ++
    "\x02\x00bc" ++ "\x00\x00" ++ "\xff\xff\xff\xff\xff\xff\xff\xff" ++
    "\x01" ++ "\x03\x00" ++ "\x01\x00z";

test "a definitions page decodes per the server's layout" {
    var page = try parseDefinitionList(std.testing.allocator, definitions_page);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 2), page.definitions.len);
    try std.testing.expectEqualStrings("a", page.definitions[0].name);
    try std.testing.expectEqualStrings("1", page.definitions[0].version);
    try std.testing.expectEqual(@as(i64, 5), page.definitions[0].created_at);
    try std.testing.expectEqualStrings("bc", page.definitions[1].name);
    try std.testing.expectEqualStrings("", page.definitions[1].version);
    try std.testing.expectEqual(@as(i64, -1), page.definitions[1].created_at);
    try std.testing.expect(page.has_more);
    try std.testing.expectEqualSlices(u8, "\x01\x00z", page.cursor.?);
}

test "a definitions page whose cursor contradicts has_more is refused" {
    const a = std.testing.allocator;
    // No definitions; has_more=0 with a cursor, then has_more=1 without one.
    try std.testing.expectError(error.UnexpectedResponse, parseDefinitionList(a, "\x00\x00\x00\x00" ++ "\x00" ++ "\x01\x00c"));
    try std.testing.expectError(error.UnexpectedResponse, parseDefinitionList(a, "\x00\x00\x00\x00" ++ "\x01" ++ "\x00\x00"));
}

fn parseDefinitionsAndFree(a: Allocator, data: []const u8) !void {
    var page = try parseDefinitionList(a, data);
    page.deinit();
}

test "a definitions answer cut anywhere, overcounted, or short of memory leaks nothing" {
    const a = std.testing.allocator;
    for (0..definitions_page.len) |n| try std.testing.expect(std.meta.isError(parseDefinitionsAndFree(a, definitions_page[0..n])));
    // A count far past what the data holds is refused before it allocates.
    try std.testing.expectError(error.UnexpectedEndOfData, parseDefinitionsAndFree(a, "\xff\xff\xff\xff" ++ definitions_page[4..]));
    try std.testing.checkAllAllocationFailures(a, parseDefinitionsAndFree, .{@as([]const u8, definitions_page)});
}

test "listDefinitions pages on past a short page until has_more is clear, sending each page's cursor" {
    const a = std.testing.allocator;
    var srv = try @import("test_server.zig").OkServer.listen();
    srv.replies = &.{
        // Two definitions, fewer than the limit, yet has_more=1.
        .{ .status = 0, .body = definitions_page },
        // The last page: one definition, nothing more.
        .{ .status = 0, .body = "\x01\x00\x00\x00" ++ "\x01\x00d" ++ "\x01\x002" ++ "\x09\x00\x00\x00\x00\x00\x00\x00" ++ "\x00\x00\x00" },
    };
    try srv.start();
    defer srv.deinit();
    var client = Client.init(a, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var workflow = Workflow.init(&client);

    var page = try workflow.listDefinitions(a, .{ .limit = 10 });
    defer page.deinit();
    try std.testing.expectEqual(@as(u16, @intFromEnum(types.OpCode.workflow_list_definitions)), srv.last_op);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 0 }, srv.lastValue());
    try std.testing.expectEqual(@as(usize, 2), page.definitions.len);
    try std.testing.expect(page.has_more);

    var last = try workflow.listDefinitions(a, .{ .limit = 10, .cursor = page.cursor });
    defer last.deinit();
    try std.testing.expectEqualSlices(u8, "\x0a\x00\x00\x00\x01\x00z", srv.lastValue());
    try std.testing.expectEqual(@as(usize, 1), last.definitions.len);
    try std.testing.expectEqualStrings("d", last.definitions[0].name);
    try std.testing.expectEqualStrings("2", last.definitions[0].version);
    try std.testing.expectEqual(@as(i64, 9), last.definitions[0].created_at);
    try std.testing.expect(!last.has_more);
    try std.testing.expect(last.cursor == null);
}

// Two runs: "r2" of "wf" running at 9, "r1" of "b" completed at -1;
// has_more=1, cursor "\x09\x00\x00\x00\x00\x00\x00\x00r1".
const runs_page = "\x02\x00\x00\x00" ++
    "\x02\x00r2" ++ "\x02\x00wf" ++ "\x07\x00running" ++ "\x09\x00\x00\x00\x00\x00\x00\x00" ++
    "\x02\x00r1" ++ "\x01\x00b" ++ "\x09\x00completed" ++ "\xff\xff\xff\xff\xff\xff\xff\xff" ++
    "\x01" ++ "\x0a\x00" ++ "\x09\x00\x00\x00\x00\x00\x00\x00r1";

test "a runs page decodes per the server's layout" {
    var page = try parseRunList(std.testing.allocator, runs_page);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 2), page.runs.len);
    try std.testing.expectEqualStrings("r2", page.runs[0].run_id);
    try std.testing.expectEqualStrings("wf", page.runs[0].workflow);
    try std.testing.expectEqualStrings("running", page.runs[0].status);
    try std.testing.expectEqual(@as(i64, 9), page.runs[0].created_at);
    try std.testing.expectEqualStrings("r1", page.runs[1].run_id);
    try std.testing.expectEqualStrings("b", page.runs[1].workflow);
    try std.testing.expectEqualStrings("completed", page.runs[1].status);
    try std.testing.expectEqual(@as(i64, -1), page.runs[1].created_at);
    try std.testing.expect(page.has_more);
    try std.testing.expectEqualSlices(u8, "\x09\x00\x00\x00\x00\x00\x00\x00r1", page.cursor.?);
}

test "a runs page whose cursor contradicts has_more, or with bytes past it, is refused" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedResponse, parseRunList(a, "\x00\x00\x00\x00" ++ "\x00" ++ "\x01\x00c"));
    try std.testing.expectError(error.UnexpectedResponse, parseRunList(a, "\x00\x00\x00\x00" ++ "\x01" ++ "\x00\x00"));
    try std.testing.expectError(error.UnexpectedResponse, parseRunList(a, runs_page ++ "x"));
}

fn parseRunsAndFree(a: Allocator, data: []const u8) !void {
    var page = try parseRunList(a, data);
    page.deinit();
}

test "a runs answer cut anywhere, overcounted, or short of memory leaks nothing" {
    const a = std.testing.allocator;
    for (0..runs_page.len) |n| try std.testing.expect(std.meta.isError(parseRunsAndFree(a, runs_page[0..n])));
    // A count far past what the data holds is refused before it allocates.
    try std.testing.expectError(error.UnexpectedEndOfData, parseRunsAndFree(a, "\xff\xff\xff\xff" ++ runs_page[4..]));
    try std.testing.checkAllAllocationFailures(a, parseRunsAndFree, .{@as([]const u8, runs_page)});
}

test "listRuns sends every field, empty ones as length 0, and pages on past a short page" {
    const a = std.testing.allocator;
    var srv = try @import("test_server.zig").OkServer.listen();
    srv.replies = &.{
        .{ .status = 0, .body = runs_page },
        .{ .status = 0, .body = "\x00\x00\x00\x00" ++ "\x00\x00\x00" },
    };
    try srv.start();
    defer srv.deinit();
    var client = Client.init(a, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var workflow = Workflow.init(&client);

    var page = try workflow.listRuns(a, .{ .limit = 10 });
    defer page.deinit();
    try std.testing.expectEqual(@as(u16, @intFromEnum(types.OpCode.workflow_list_runs)), srv.last_op);
    try std.testing.expectEqualStrings("", srv.lastKey());
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, srv.lastValue());
    try std.testing.expect(page.has_more);

    var last = try workflow.listRuns(a, .{ .workflow_name = "wf", .status = "running", .search = "Ord", .cursor = page.cursor, .limit = 10 });
    defer last.deinit();
    try std.testing.expectEqualStrings("wf", srv.lastKey());
    try std.testing.expectEqualSlices(u8, "\x0a\x00\x00\x00" ++ "\x07\x00running" ++ "\x0a\x00\x09\x00\x00\x00\x00\x00\x00\x00r1" ++ "\x03\x00Ord", srv.lastValue());
    try std.testing.expectEqual(@as(usize, 0), last.runs.len);
    try std.testing.expect(!last.has_more);
    try std.testing.expect(last.cursor == null);
}
