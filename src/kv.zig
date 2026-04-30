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
    /// Returns the value+version if found, null if key does not exist.
    /// Use `block_ms` for long-polling (wait for key to appear).
    /// **Caller owns the returned `GetResult` and must call `result.deinit(allocator)`.**
    pub fn get(self: *KV, key: []const u8, options: types.GetOptions) FloError!?types.GetResult {
        const ns = self.client.getNamespace(options.namespace);

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

        // Wire body: [version:u64 LE][value bytes]
        if (response.data.len < 8) {
            const empty = self.client.allocator.dupe(u8, "") catch return FloError.ServerError;
            return types.GetResult{ .value = empty, .version = 0 };
        }
        const version = std.mem.readInt(u64, response.data[0..8], .little);
        const value = self.client.allocator.dupe(u8, response.data[8..]) catch return FloError.ServerError;
        return types.GetResult{ .value = value, .version = version };
    }

    /// Put a key-value pair and return the new version.
    ///
    /// The returned `version` may be passed to `PutOptions.cas_version` on the
    /// next write to enforce optimistic concurrency.
    pub fn put(
        self: *KV,
        key: []const u8,
        value: []const u8,
        options: types.PutOptions,
    ) FloError!types.PutResult {
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

        if (response.data.len < 8) {
            return types.PutResult{ .version = 0 };
        }
        return types.PutResult{ .version = std.mem.readInt(u64, response.data[0..8], .little) };
    }

    /// Delete a key. Succeeds for both OK and NOT_FOUND unless `if_match`
    /// is set, in which case a missing key surfaces `FloError.Conflict`.
    pub fn delete(self: *KV, key: []const u8, options: types.DeleteOptions) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var opts_buf: [16]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);
        if (options.if_match) |v| try builder.addU64(.cas_version, v);

        var response = try self.client.sendRequest(.kv_delete, ns, key, "", builder.getOptions());
        defer response.deinit();

        const allow_not_found = options.if_match == null;
        if (response.status != .ok and !(allow_not_found and response.status == .not_found)) {
            return mapStatusToError(response.status);
        }
    }

    /// Look up many keys in a single round trip. Keys may live on different
    /// shards — the server gathers results in parallel and returns one entry
    /// per requested key in the same order. The `found` flag distinguishes
    /// missing keys from keys whose value is empty.
    ///
    /// Limited to 256 keys per call. **Caller owns the returned `MGetResult`
    /// and must call `result.deinit()`.**
    pub fn mget(
        self: *KV,
        keys: []const []const u8,
        options: types.KVMGetOptions,
    ) FloError!types.MGetResult {
        if (keys.len > 256) return FloError.BadRequest;
        const ns = self.client.getNamespace(options.namespace);
        const allocator = self.client.allocator;

        // Pack request: [count:u16 LE]([key_len:u16 LE][key])*
        var size: usize = 2;
        for (keys) |k| {
            if (k.len > 0xFFFF) return FloError.BadRequest;
            size += 2 + k.len;
        }
        const req_value = try allocator.alloc(u8, size);
        defer allocator.free(req_value);

        std.mem.writeInt(u16, req_value[0..2], @intCast(keys.len), .little);
        var off: usize = 2;
        for (keys) |k| {
            std.mem.writeInt(u16, req_value[off..][0..2], @intCast(k.len), .little);
            off += 2;
            @memcpy(req_value[off..][0..k.len], k);
            off += k.len;
        }

        var response = try self.client.sendRequest(.kv_mget, ns, "", req_value, "");
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }

        // Response: [count:u32 LE]([status:u8][key_len:u16][key][version:u64][value_len:u32][value])*
        const data = response.data;
        if (data.len < 4) {
            return types.MGetResult{
                .entries = try allocator.alloc(types.MGetEntry, 0),
                .allocator = allocator,
            };
        }
        const count = std.mem.readInt(u32, data[0..4], .little);
        var entries = try allocator.alloc(types.MGetEntry, count);
        var filled: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < filled) : (i += 1) {
                allocator.free(entries[i].key);
                allocator.free(entries[i].value);
            }
            allocator.free(entries);
        }

        var p: usize = 4;
        while (filled < count) : (filled += 1) {
            if (p + 1 + 2 > data.len) return FloError.IncompleteResponse;
            const status_byte = data[p];
            p += 1;
            const klen = std.mem.readInt(u16, data[p..][0..2], .little);
            p += 2;
            if (p + klen + 8 + 4 > data.len) return FloError.IncompleteResponse;
            const key_copy = try allocator.dupe(u8, data[p .. p + klen]);
            errdefer allocator.free(key_copy);
            p += klen;
            const version = std.mem.readInt(u64, data[p..][0..8], .little);
            p += 8;
            const vlen = std.mem.readInt(u32, data[p..][0..4], .little);
            p += 4;
            if (p + vlen > data.len) {
                allocator.free(key_copy);
                return FloError.IncompleteResponse;
            }
            const value_copy = try allocator.dupe(u8, data[p .. p + vlen]);
            p += vlen;
            entries[filled] = .{
                .key = key_copy,
                .value = value_copy,
                .version = version,
                .found = status_byte == 0,
            };
        }

        return types.MGetResult{ .entries = entries, .allocator = allocator };
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

        if (options.keys_only) {
            try builder.addU8(.keys_only, 1);
        }

        // Value: [limit:u32][cursor...]
        const cursor = options.cursor orelse &[_]u8{};
        const limit: u32 = options.limit orelse 0; // 0 = server default
        var value_buf: [4 + 64]u8 = undefined;
        std.mem.writeInt(u32, value_buf[0..4], limit, .little);
        if (cursor.len > 0) {
            const copy_len = @min(cursor.len, value_buf.len - 4);
            @memcpy(value_buf[4 .. 4 + copy_len], cursor[0..copy_len]);
        }
        const value_len = 4 + @min(cursor.len, value_buf.len - 4);

        var response = try self.client.sendRequest(
            .kv_scan,
            ns,
            prefix,
            value_buf[0..value_len],
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

    // ─── Extended ops: counters, TTL lifecycle, exists, JSON paths ─────

    /// Atomically add `delta` (default +1) to the i64 counter at `key`.
    ///
    /// The first incr on a missing key creates it at the delta value. Returns
    /// `FloError.Conflict` if the key already holds a non-counter value.
    /// Returns the new counter value.
    pub fn incr(self: *KV, key: []const u8, options: types.KVIncrOptions) FloError!i64 {
        const ns = self.client.getNamespace(options.namespace);

        var value_buf: [8]u8 = undefined;
        var value: []const u8 = "";
        if (options.delta) |delta| {
            std.mem.writeInt(i64, &value_buf, delta, .little);
            value = value_buf[0..8];
        }

        var response = try self.client.sendRequest(.kv_incr, ns, key, value, "");
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
        // Wire body: [version:u64][counter:i64 LE]
        if (response.data.len < 16) return FloError.IncompleteResponse;
        return std.mem.readInt(i64, response.data[8..16], .little);
    }

    /// Update the TTL on an existing key. `ttl_seconds = 0` clears the TTL.
    ///
    /// When `options.if_match` is set, the touch only succeeds if the current
    /// key version equals it — enabling race-free lease renewal.
    pub fn touch(
        self: *KV,
        key: []const u8,
        ttl_seconds: u64,
        options: types.KVTouchOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);
        var value_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &value_buf, ttl_seconds, .little);
        var opts_buf: [16]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);
        if (options.if_match) |v| try builder.addU64(.cas_version, v);
        var response = try self.client.sendRequest(.kv_touch, ns, key, value_buf[0..8], builder.getOptions());
        defer response.deinit();
        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
    }

    /// Clear the TTL on an existing key, making it permanent.
    ///
    /// When `options.if_match` is set, the persist only succeeds if the
    /// current key version equals it.
    pub fn persist(self: *KV, key: []const u8, options: types.KVTouchOptions) FloError!void {
        const ns = self.client.getNamespace(options.namespace);
        var opts_buf: [16]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);
        if (options.if_match) |v| try builder.addU64(.cas_version, v);
        var response = try self.client.sendRequest(.kv_persist, ns, key, "", builder.getOptions());
        defer response.deinit();
        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
    }

    /// Returns true if `key` is present without transferring its value.
    pub fn exists(self: *KV, key: []const u8, options: types.KVExistsOptions) FloError!bool {
        const ns = self.client.getNamespace(options.namespace);
        var response = try self.client.sendRequest(.kv_exists, ns, key, "", "");
        defer response.deinit();
        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
        // Wire body: [version:u64][1 byte 0/1]
        return response.data.len >= 9 and response.data[8] == 1;
    }

    /// Extract the value at `path` from the JSON document at `key`.
    ///
    /// Returns a `GetResult` carrying the extracted JSON bytes and the
    /// document's current version, or `null` if the key or path is missing.
    /// **Caller owns `result.value` and must call `result.deinit(allocator)`.**
    pub fn jsonGet(
        self: *KV,
        key: []const u8,
        path: []const u8,
        options: types.KVJsonOptions,
    ) FloError!?types.GetResult {
        const ns = self.client.getNamespace(options.namespace);
        var response = try self.client.sendRequest(.kv_json_get, ns, key, path, "");
        defer response.deinit();
        if (response.status == .not_found) return null;
        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
        if (response.data.len < 8) return null;
        const version = std.mem.readInt(u64, response.data[0..8], .little);
        const value = self.client.allocator.dupe(u8, response.data[8..]) catch return FloError.ServerError;
        return types.GetResult{ .value = value, .version = version };
    }

    /// Set the JSON value at `path` inside the document at `key`.
    ///
    /// Path `"$"` replaces the whole document (and creates the key if missing).
    /// Sub-paths require the key to already exist. Returns a `PutResult` with
    /// the new document version.
    pub fn jsonSet(
        self: *KV,
        key: []const u8,
        path: []const u8,
        json_value: []const u8,
        options: types.KVJsonOptions,
    ) FloError!types.PutResult {
        const ns = self.client.getNamespace(options.namespace);
        const path_bytes = if (path.len == 0) "$" else path;
        if (path_bytes.len > 0xFFFF) return FloError.BadRequest;
        const value = self.client.allocator.alloc(u8, 2 + path_bytes.len + json_value.len) catch return FloError.ServerError;
        defer self.client.allocator.free(value);
        std.mem.writeInt(u16, value[0..2], @intCast(path_bytes.len), .little);
        @memcpy(value[2 .. 2 + path_bytes.len], path_bytes);
        @memcpy(value[2 + path_bytes.len ..], json_value);
        var response = try self.client.sendRequest(.kv_json_set, ns, key, value, "");
        defer response.deinit();
        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
        const version = if (response.data.len >= 8)
            std.mem.readInt(u64, response.data[0..8], .little)
        else
            0;
        return types.PutResult{ .version = version };
    }

    /// Remove the value at `path` from the JSON document at `key`.
    ///
    /// Sub-paths return a `PutResult` with the new document version. For
    /// `"$"` (whole document delete) the version is `0` since the key is gone.
    pub fn jsonDel(
        self: *KV,
        key: []const u8,
        path: []const u8,
        options: types.KVJsonOptions,
    ) FloError!types.PutResult {
        const ns = self.client.getNamespace(options.namespace);
        const path_bytes = if (path.len == 0) "$" else path;
        var response = try self.client.sendRequest(.kv_json_del, ns, key, path_bytes, "");
        defer response.deinit();
        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
        const version = if (response.data.len >= 8)
            std.mem.readInt(u64, response.data[0..8], .little)
        else
            0;
        return types.PutResult{ .version = version };
    }

    /// Open a per-shard KV transaction pinned to `routing_key`'s partition.
    ///
    /// Every key written or read inside the transaction must hash to the
    /// same partition; otherwise the server returns a "kv_txn_cross_shard"
    /// error.
    ///
    /// **Caller must call `txn.commit()` or `txn.rollback()`, then
    /// `txn.deinit()` to release the routing key copy.**
    pub fn begin(
        self: *KV,
        routing_key: []const u8,
        options: types.DeleteOptions,
    ) FloError!Transaction {
        const ns = self.client.getNamespace(options.namespace);

        var opts_buf: [64]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);
        if (routing_key.len > 0) {
            try builder.addBytes(.routing_key, routing_key);
        }

        var response = try self.client.sendRequest(
            .kv_begin_txn,
            ns,
            routing_key,
            "",
            builder.getOptions(),
        );
        defer response.deinit();

        if (response.status != .ok) {
            return mapStatusToError(response.status);
        }
        // Wire body: [variant:u8=0][txn_id:u64 LE][pinned_hash:u64 LE]
        if (response.data.len < 17) return FloError.IncompleteResponse;
        const txn_id = std.mem.readInt(u64, response.data[1..9], .little);
        const pinned_hash = std.mem.readInt(u64, response.data[9..17], .little);

        const rk_owned = self.client.allocator.dupe(u8, routing_key) catch return FloError.ServerError;
        const ns_owned = self.client.allocator.dupe(u8, ns) catch {
            self.client.allocator.free(rk_owned);
            return FloError.ServerError;
        };

        return Transaction{
            .client = self.client,
            .namespace = ns_owned,
            .routing_key = rk_owned,
            .id = txn_id,
            .pinned_hash = pinned_hash,
            .done = false,
        };
    }
};

/// Per-shard KV transaction handle.
///
/// Operations are buffered on the server's pinned shard until `commit()` or
/// `rollback()` is called. Server-enforced caps:
///   - 256 ops per transaction
///   - 1 MiB total payload across buffered writes
///
/// The following operations are NOT supported inside a transaction and
/// return `FloError.TxnUnsupportedOp` without a server round-trip:
/// `scan`, `mget`, `jsonGet`, `jsonSet`, `jsonDel`, `history`.
pub const Transaction = struct {
    client: *Client,
    namespace: []const u8,
    routing_key: []const u8,
    /// Server-assigned transaction id.
    id: u64,
    /// Partition hash this transaction is bound to.
    pinned_hash: u64,
    done: bool,

    /// Release the owned routing key + namespace copies. Must be called after
    /// `commit()` or `rollback()`.
    pub fn deinit(self: *Transaction) void {
        self.client.allocator.free(self.routing_key);
        self.client.allocator.free(self.namespace);
    }

    fn buildOptions(self: *Transaction, buf: []u8) FloError![]const u8 {
        var builder = wire.OptionsBuilder.init(buf);
        if (self.routing_key.len > 0) {
            try builder.addBytes(.routing_key, self.routing_key);
        }
        try builder.addU64(.txn_id, self.id);
        return builder.getOptions();
    }

    fn checkAlive(self: *const Transaction) FloError!void {
        if (self.done) return FloError.TxnFinished;
    }

    /// Buffer a put inside the transaction.
    pub fn put(
        self: *Transaction,
        key: []const u8,
        value: []const u8,
        options: types.PutOptions,
    ) FloError!types.PutResult {
        try self.checkAlive();

        var opts_buf: [128]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);
        if (self.routing_key.len > 0) {
            try builder.addBytes(.routing_key, self.routing_key);
        }
        try builder.addU64(.txn_id, self.id);
        if (options.ttl_seconds) |ttl| try builder.addU64(.ttl_seconds, ttl);
        if (options.cas_version) |v| try builder.addU64(.cas_version, v);
        if (options.if_not_exists) try builder.addFlag(.if_not_exists);
        if (options.if_exists) try builder.addFlag(.if_exists);

        var response = try self.client.sendRequest(
            .kv_put,
            self.namespace,
            key,
            value,
            builder.getOptions(),
        );
        defer response.deinit();

        if (response.status != .ok) return mapStatusToError(response.status);
        const version = if (response.data.len >= 8)
            std.mem.readInt(u64, response.data[0..8], .little)
        else
            0;
        return types.PutResult{ .version = version };
    }

    /// Read a key inside the transaction (sees buffered writes).
    /// **Caller owns the returned `GetResult` and must call `result.deinit(allocator)`.**
    pub fn get(self: *Transaction, key: []const u8) FloError!?types.GetResult {
        try self.checkAlive();

        var opts_buf: [64]u8 = undefined;
        const opts = try self.buildOptions(&opts_buf);

        var response = try self.client.sendRequest(.kv_get, self.namespace, key, "", opts);
        defer response.deinit();

        if (response.status == .not_found) return null;
        if (response.status != .ok) return mapStatusToError(response.status);

        if (response.data.len < 8) {
            const empty = self.client.allocator.dupe(u8, "") catch return FloError.ServerError;
            return types.GetResult{ .value = empty, .version = 0 };
        }
        const version = std.mem.readInt(u64, response.data[0..8], .little);
        const value = self.client.allocator.dupe(u8, response.data[8..]) catch return FloError.ServerError;
        return types.GetResult{ .value = value, .version = version };
    }

    /// Buffer a delete inside the transaction.
    pub fn delete(self: *Transaction, key: []const u8) FloError!void {
        try self.checkAlive();
        var opts_buf: [64]u8 = undefined;
        const opts = try self.buildOptions(&opts_buf);
        var response = try self.client.sendRequest(.kv_delete, self.namespace, key, "", opts);
        defer response.deinit();
        if (response.status != .ok and response.status != .not_found) {
            return mapStatusToError(response.status);
        }
    }

    /// Buffer an atomic counter increment inside the transaction.
    pub fn incr(self: *Transaction, key: []const u8, delta: i64) FloError!i64 {
        try self.checkAlive();
        var opts_buf: [64]u8 = undefined;
        const opts = try self.buildOptions(&opts_buf);
        var value_buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &value_buf, delta, .little);
        var response = try self.client.sendRequest(.kv_incr, self.namespace, key, value_buf[0..8], opts);
        defer response.deinit();
        if (response.status != .ok) return mapStatusToError(response.status);
        if (response.data.len < 8) return 0;
        return std.mem.readInt(i64, response.data[0..8], .little);
    }

    /// Update the TTL on an existing key inside the transaction.
    pub fn touch(self: *Transaction, key: []const u8, ttl_seconds: u64) FloError!void {
        try self.checkAlive();
        var opts_buf: [64]u8 = undefined;
        const opts = try self.buildOptions(&opts_buf);
        var value_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &value_buf, ttl_seconds, .little);
        var response = try self.client.sendRequest(.kv_touch, self.namespace, key, value_buf[0..8], opts);
        defer response.deinit();
        if (response.status != .ok) return mapStatusToError(response.status);
    }

    /// Remove the TTL on a key inside the transaction.
    pub fn persist(self: *Transaction, key: []const u8) FloError!void {
        try self.checkAlive();
        var opts_buf: [64]u8 = undefined;
        const opts = try self.buildOptions(&opts_buf);
        var response = try self.client.sendRequest(.kv_persist, self.namespace, key, "", opts);
        defer response.deinit();
        if (response.status != .ok) return mapStatusToError(response.status);
    }

    /// Check key existence inside the transaction.
    pub fn exists(self: *Transaction, key: []const u8) FloError!bool {
        try self.checkAlive();
        var opts_buf: [64]u8 = undefined;
        const opts = try self.buildOptions(&opts_buf);
        var response = try self.client.sendRequest(.kv_exists, self.namespace, key, "", opts);
        defer response.deinit();
        if (response.status != .ok) return mapStatusToError(response.status);
        // Wire body: [version:u64 LE][1 byte 0/1]
        if (response.data.len < 9) return false;
        return response.data[8] == 1;
    }

    // ── Disallowed inside a transaction ───────────────────────────────

    pub fn scan(_: *Transaction) FloError!void {
        return FloError.TxnUnsupportedOp;
    }
    pub fn mget(_: *Transaction) FloError!void {
        return FloError.TxnUnsupportedOp;
    }
    pub fn jsonGet(_: *Transaction) FloError!void {
        return FloError.TxnUnsupportedOp;
    }
    pub fn jsonSet(_: *Transaction) FloError!void {
        return FloError.TxnUnsupportedOp;
    }
    pub fn jsonDel(_: *Transaction) FloError!void {
        return FloError.TxnUnsupportedOp;
    }
    pub fn history(_: *Transaction) FloError!void {
        return FloError.TxnUnsupportedOp;
    }

    // ── Lifecycle ─────────────────────────────────────────────────────

    /// Atomically apply all buffered operations. After commit returns, the
    /// transaction is closed; further operations return `FloError.TxnFinished`.
    pub fn commit(self: *Transaction) FloError!types.KVCommitResult {
        try self.checkAlive();
        self.done = true;

        var opts_buf: [64]u8 = undefined;
        const opts = try self.buildOptions(&opts_buf);
        var response = try self.client.sendRequest(
            .kv_commit_txn,
            self.namespace,
            self.routing_key,
            "",
            opts,
        );
        defer response.deinit();

        if (response.status != .ok) return mapStatusToError(response.status);
        // Wire body: [variant:u8=1][commit_index:u64 LE][op_count:u16 LE]
        if (response.data.len < 11) return FloError.IncompleteResponse;
        return types.KVCommitResult{
            .commit_index = std.mem.readInt(u64, response.data[1..9], .little),
            .op_count = std.mem.readInt(u16, response.data[9..11], .little),
        };
    }

    /// Discard the buffered operations. Idempotent: calling rollback after
    /// commit (or vice versa) is a no-op.
    pub fn rollback(self: *Transaction) FloError!void {
        if (self.done) return;
        self.done = true;

        var opts_buf: [64]u8 = undefined;
        const opts = try self.buildOptions(&opts_buf);
        var response = try self.client.sendRequest(
            .kv_rollback_txn,
            self.namespace,
            self.routing_key,
            "",
            opts,
        );
        defer response.deinit();
        if (response.status != .ok) return mapStatusToError(response.status);
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
