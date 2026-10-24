//! Flo KV Operations
//!
//! Key-value store operations: get, put, delete, scan, history, mget,
//! counters, TTLs, JSON paths and per-shard transactions.

const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");
const Client = @import("client.zig").Client;

const Allocator = std.mem.Allocator;
const FloError = types.FloError;

/// KV operations interface
pub const KV = struct {
    client: *Client,

    pub fn init(client: *Client) KV {
        return .{ .client = client };
    }

    /// Get a value by key. Returns the value and version, or null if the
    /// key does not exist, also when a wait (`wait_ms`) ends without it.
    /// **Caller owns the returned `GetResult` and must call `result.deinit(allocator)`.**
    pub fn get(self: *KV, key: []const u8, options: types.GetOptions) FloError!?types.GetResult {
        return kvGet(self.client, self.client.getNamespace(options.namespace), key, options, null);
    }

    /// Put a key-value pair and return the new version.
    ///
    /// The returned `version` may be passed to `PutOptions.cas_version` on the
    /// next write to enforce optimistic concurrency. A `cas_version` that
    /// isn't the key's, or a `condition` that doesn't hold, returns
    /// `FloError.Conflict`; `client.lastError()` says which.
    pub fn put(
        self: *KV,
        key: []const u8,
        value: []const u8,
        options: types.PutOptions,
    ) FloError!types.PutResult {
        return kvSet(self.client, self.client.getNamespace(options.namespace), key, value, options, null);
    }

    /// Delete a key and return whether it existed; deleting a missing key
    /// isn't an error. A `cas_version` that isn't the key's returns
    /// `FloError.Conflict`.
    pub fn delete(self: *KV, key: []const u8, options: types.DeleteOptions) FloError!bool {
        const ns = self.client.getNamespace(options.namespace);
        const existed = try kvDelete(self.client, ns, key, options.cas_version, options.routing_key, null);
        return existed orelse FloError.UnexpectedResponse;
    }

    /// Look up many keys. Keys may live on different shards; the result
    /// holds one entry per requested key, in order, and `found`
    /// distinguishes a missing key from an empty value. The server answers
    /// as many keys as fit one answer, and this asks again from where it
    /// stopped until every key is answered.
    ///
    /// Takes 1 to 256 keys of at most 4096 bytes. **Caller owns the returned `MGetResult` and must
    /// call `result.deinit()`.**
    pub fn mget(
        self: *KV,
        keys: []const []const u8,
        options: types.KVMGetOptions,
    ) FloError!types.MGetResult {
        if (keys.len == 0 or keys.len > types.MAX_MGET) return FloError.BadRequest;
        for (keys) |k| if (k.len > types.MAX_MGET_KEY) return FloError.KeyTooLarge;
        try checkRoutingKey(options.routing_key);
        const ns = self.client.getNamespace(options.namespace);
        const allocator = self.client.allocator;

        const entries = try allocator.alloc(types.MGetEntry, keys.len);
        var filled: usize = 0;
        errdefer {
            for (entries[0..filled]) |e| {
                allocator.free(e.key);
                allocator.free(e.value);
            }
            allocator.free(entries);
        }

        while (filled < keys.len) {
            const end = mgetChunkEnd(keys, filled);
            const chunk = keys[filled..end];
            const buf = try allocator.alloc(u8, mgetBodySize(chunk));
            defer allocator.free(buf);
            const body = encodeMgetBody(buf, chunk, options.routing_key);
            var response = try call(self.client, .kv_mget, ns, "", body);
            defer response.deinit();

            const page = entries[filled..end];
            const answered = try decodeMgetAnswer(response.data, page);
            // The decoded values borrow the response.
            for (page[0..answered], chunk[0..answered]) |*e, k| {
                const value = try allocator.dupe(u8, e.value);
                errdefer allocator.free(value);
                e.key = try allocator.dupe(u8, k);
                e.value = value;
                filled += 1;
            }
        }
        return .{ .entries = entries, .allocator = allocator };
    }

    /// List the names of keys starting with `prefix` ("" for all), one page
    /// at a time: pass the returned `cursor` back for the next page; it is
    /// null on the last.
    /// **Caller owns the returned `ScanResult` and must call `result.deinit()`.**
    pub fn scan(
        self: *KV,
        prefix: []const u8,
        options: types.ScanOptions,
    ) FloError!types.ScanResult {
        var buf: [MAX_SCAN_BODY]u8 = undefined;
        const body = try encodeScanBody(&buf, options.limit, options.cursor orelse "");
        var response = try call(self.client, .kv_scan, self.client.getNamespace(options.namespace), prefix, body);
        defer response.deinit();
        return decodeScanAnswer(self.client.allocator, response.data);
    }

    /// Get a key's versions, newest first; a missing key has none.
    /// **Caller owns the returned slice and must free each entry with `entry.deinit(allocator)`,
    /// then free the slice itself with `allocator.free(entries)`.**
    pub fn history(
        self: *KV,
        key: []const u8,
        options: types.HistoryOptions,
    ) FloError![]types.VersionEntry {
        var buf: [MAX_HISTORY_BODY]u8 = undefined;
        const body = try encodeHistoryBody(&buf, options.limit, options.routing_key);
        var response = try self.client.sendRequest(.kv_history, self.client.getNamespace(options.namespace), key, body, "");
        defer response.deinit();
        // A missing key has no versions.
        if (response.status == .not_found and self.client.last_error_reason == .not_found) return self.client.allocator.alloc(types.VersionEntry, 0);
        if (response.status != .ok) return response.status.toError();
        return decodeHistoryAnswer(self.client.allocator, response.data);
    }

    // ─── Counters, TTLs, exists, JSON paths ─────

    /// Atomically add `delta` (default +1) to the i64 counter at `key` and
    /// return its new value and version.
    ///
    /// The first incr on a missing key creates it at the delta value. A key
    /// holding a non-counter value is refused (`client.lastError()` says
    /// `wrong_type`).
    pub fn incr(self: *KV, key: []const u8, options: types.KVIncrOptions) FloError!types.IncrResult {
        const ns = self.client.getNamespace(options.namespace);
        const a = try kvIncr(self.client, ns, key, options.delta, options.routing_key, null);
        return .{
            .value = a.value orelse return FloError.UnexpectedResponse,
            .version = a.version orelse return FloError.UnexpectedResponse,
        };
    }

    /// Set the TTL on an existing key, in milliseconds; `ttl_ms = 0` clears
    /// it. With `cas_version`, only that version of the key is touched,
    /// which makes lease renewal race-free.
    pub fn expire(
        self: *KV,
        key: []const u8,
        ttl_ms: u64,
        options: types.KVExpireOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);
        return kvExpire(self.client, ns, key, ttl_ms, options.cas_version, options.routing_key, null);
    }

    /// Returns true if `key` is present without transferring its value.
    pub fn exists(self: *KV, key: []const u8, options: types.KVExistsOptions) FloError!bool {
        const ns = self.client.getNamespace(options.namespace);
        return (try kvExists(self.client, ns, key, options.routing_key, null)).exists;
    }

    /// Extract the value at `path` ("" or "$" for the whole document) from
    /// the JSON document at `key`.
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
        var buf: [MAX_JSON_PATH_BODY]u8 = undefined;
        const body = try encodeJsonPathBody(&buf, path, options.routing_key);
        var response = try self.client.sendRequest(.kv_json_get, self.client.getNamespace(options.namespace), key, body, "");
        defer response.deinit();
        if (response.status == .not_found and self.client.last_error_reason == .not_found) return null;
        if (response.status != .ok) return response.status.toError();
        return try decodeJsonGetAnswer(self.client.allocator, response.data);
    }

    /// Set the JSON value at `path` ("" or "$" for the whole document)
    /// inside the document at `key`, and return the document's new version.
    ///
    /// Path `"$"` replaces the whole document (and creates the key if
    /// missing). Sub-paths require the key to already exist.
    pub fn jsonSet(
        self: *KV,
        key: []const u8,
        path: []const u8,
        document: []const u8,
        options: types.KVJsonOptions,
    ) FloError!types.PutResult {
        const allocator = self.client.allocator;
        const buf = try allocator.alloc(u8, jsonSetBodySize(document));
        defer allocator.free(buf);
        const body = try encodeJsonSetBody(buf, path, document, options.routing_key);
        var response = try call(self.client, .kv_json_set, self.client.getNamespace(options.namespace), key, body);
        defer response.deinit();
        return .{ .version = try decodeJsonSetAnswer(response.data) };
    }

    /// Remove the value at `path` ("" or "$" for the whole document) from
    /// the JSON document at `key`. Returns the document's new version, or
    /// null when the path was `"$"`, which deleted the key.
    pub fn jsonDel(
        self: *KV,
        key: []const u8,
        path: []const u8,
        options: types.KVJsonOptions,
    ) FloError!?types.PutResult {
        var buf: [MAX_JSON_PATH_BODY]u8 = undefined;
        const body = try encodeJsonPathBody(&buf, path, options.routing_key);
        var response = try call(self.client, .kv_json_del, self.client.getNamespace(options.namespace), key, body);
        defer response.deinit();
        const version = try decodeJsonDelAnswer(response.data) orelse return null;
        return .{ .version = version };
    }

    /// Open a per-shard KV transaction pinned to `routing_key`'s partition.
    ///
    /// Every op inside the transaction is routed by `routing_key`, so every
    /// key it touches lives on that partition.
    ///
    /// **Caller must call `txn.commit()` or `txn.rollback()`, then
    /// `txn.deinit()` to release the routing key copy.**
    pub fn begin(
        self: *KV,
        routing_key: []const u8,
        options: types.KVBeginOptions,
    ) FloError!Transaction {
        if (routing_key.len == 0) return FloError.BadRequest;
        if (routing_key.len > MAX_ROUTING_KEY) return FloError.KeyTooLarge;
        const ns = self.client.getNamespace(options.namespace);

        // The routing key is the envelope key; the body is empty.
        var response = try call(self.client, .kv_txn_begin, ns, routing_key, "");
        defer response.deinit();
        const a = try decodeTxnBeginAnswer(response.data);

        const allocator = self.client.allocator;
        const rk_owned = try allocator.dupe(u8, routing_key);
        errdefer allocator.free(rk_owned);
        const ns_owned = try allocator.dupe(u8, ns);

        return Transaction{
            .client = self.client,
            .namespace = ns_owned,
            .routing_key = rk_owned,
            .id = a.txn,
            .pinned_hash = a.pinned,
            .done = false,
        };
    }
};

/// Per-shard KV transaction handle.
///
/// Operations are buffered on the server's pinned shard until `commit()` or
/// `rollback()` is called. Each op is routed by the transaction's routing
/// key. Writes inside a transaction have no version or result until commit.
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

    fn checkAlive(self: *const Transaction) FloError!void {
        if (self.done) return FloError.TxnFinished;
    }

    /// Buffer a put inside the transaction; it has no version until commit (0).
    pub fn put(
        self: *Transaction,
        key: []const u8,
        value: []const u8,
        options: types.PutOptions,
    ) FloError!types.PutResult {
        try self.checkAlive();
        var opts = options;
        opts.routing_key = self.routing_key;
        return kvSet(self.client, self.namespace, key, value, opts, self.id);
    }

    /// Read a key inside the transaction (sees buffered writes).
    /// **Caller owns the returned `GetResult` and must call `result.deinit(allocator)`.**
    pub fn get(self: *Transaction, key: []const u8) FloError!?types.GetResult {
        try self.checkAlive();
        return kvGet(self.client, self.namespace, key, .{ .routing_key = self.routing_key }, self.id);
    }

    /// Buffer a delete inside the transaction.
    pub fn delete(self: *Transaction, key: []const u8, options: types.KVTxnWriteOptions) FloError!void {
        try self.checkAlive();
        _ = try kvDelete(self.client, self.namespace, key, options.cas_version, self.routing_key, self.id);
    }

    /// Buffer an atomic counter increment inside the transaction; its value
    /// is known only after commit.
    pub fn incr(self: *Transaction, key: []const u8, delta: i64) FloError!void {
        try self.checkAlive();
        _ = try kvIncr(self.client, self.namespace, key, delta, self.routing_key, self.id);
    }

    /// Buffer a TTL change inside the transaction, in milliseconds;
    /// `ttl_ms = 0` clears the TTL.
    pub fn expire(self: *Transaction, key: []const u8, ttl_ms: u64, options: types.KVTxnWriteOptions) FloError!void {
        try self.checkAlive();
        return kvExpire(self.client, self.namespace, key, ttl_ms, options.cas_version, self.routing_key, self.id);
    }

    /// Check key existence inside the transaction (sees buffered writes).
    pub fn exists(self: *Transaction, key: []const u8) FloError!bool {
        try self.checkAlive();
        return (try kvExists(self.client, self.namespace, key, self.routing_key, self.id)).exists;
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
        // The id names the transaction's shard: the key is empty.
        var response = try call(self.client, .kv_txn_commit, self.namespace, "", &txnBody(self.id));
        defer response.deinit();
        return decodeCommitAnswer(response.data);
    }

    /// Discard the buffered operations. Idempotent: calling rollback after
    /// commit (or vice versa) is a no-op.
    pub fn rollback(self: *Transaction) FloError!void {
        if (self.done) return;
        self.done = true;
        var response = try call(self.client, .kv_txn_rollback, self.namespace, "", &txnBody(self.id));
        defer response.deinit();
        return decodeEmptyAnswer(response.data);
    }
};

// Every KV op is a table op: the request is [namespace][key][body], the
// body coded by the op's schema, field by field in order, and an ok answer
// is the op's response fields in order. An optional field is a presence
// byte then its value; a field with a default is sent present. A byte
// string or list has a length prefix as wide as its bound needs.

/// The longest routing key; its length prefix is a u16.
const MAX_ROUTING_KEY = 4096;
/// The longest scan cursor; its length prefix is a u8.
const MAX_CURSOR = 64;

/// Send a table op; a refusal surfaces as its error.
fn call(client: *Client, op: types.OpCode, namespace: []const u8, key: []const u8, body: []const u8) FloError!wire.RawResponse {
    var response = try client.sendRequest(op, namespace, key, body, "");
    if (response.status != .ok) {
        const err = response.status.toError();
        response.deinit();
        return err;
    }
    return response;
}

const BodyWriter = struct {
    buf: []u8,
    pos: usize = 0,

    fn put(w: *BodyWriter, bytes: []const u8) void {
        @memcpy(w.buf[w.pos..][0..bytes.len], bytes);
        w.pos += bytes.len;
    }
    fn int(w: *BodyWriter, comptime T: type, v: T) void {
        std.mem.writeInt(T, w.buf[w.pos..][0..@sizeOf(T)], v, .little);
        w.pos += @sizeOf(T);
    }
    /// A length-prefixed byte string; the caller has checked it fits `Len`.
    fn lenBytes(w: *BodyWriter, comptime Len: type, bytes: []const u8) void {
        w.int(Len, @intCast(bytes.len));
        w.put(bytes);
    }
    fn optU64(w: *BodyWriter, v: ?u64) void {
        if (v) |x| {
            w.put(&.{1});
            w.int(u64, x);
        } else w.put(&.{0});
    }
    /// An empty routing key is none, as in the other SDKs.
    fn routingKey(w: *BodyWriter, k: ?[]const u8) void {
        const key = k orelse return w.put(&.{0});
        if (key.len == 0) return w.put(&.{0});
        w.put(&.{1});
        w.lenBytes(u16, key);
    }
    fn written(w: *const BodyWriter) []const u8 {
        return w.buf[0..w.pos];
    }
};

fn checkRoutingKey(k: ?[]const u8) FloError!void {
    if ((k orelse "").len > MAX_ROUTING_KEY) return FloError.KeyTooLarge;
}

/// The most an optional routing key field takes.
const ROUTING_KEY_FIELD = 3 + MAX_ROUTING_KEY;

/// The most a kv.get body can take: wait_ms, wait_for, routing_key, txn.
const MAX_GET_BODY = 9 + 2 + ROUTING_KEY_FIELD + 9;

/// kv.get's request: wait_ms, wait_for, routing_key, txn.
fn encodeGetBody(buf: *[MAX_GET_BODY]u8, options: types.GetOptions, txn: ?u64) FloError![]const u8 {
    if (options.wait_ms > types.MAX_WAIT_MS) return FloError.BlockTooLong;
    try checkRoutingKey(options.routing_key);
    var w: BodyWriter = .{ .buf = buf };
    w.put(&.{1});
    w.int(u64, options.wait_ms);
    w.put(&.{ 1, @intFromEnum(options.wait_for) });
    w.routingKey(options.routing_key);
    w.optU64(txn);
    return w.written();
}

/// The size of kv.set's body for `value`, at most.
fn setBodySize(value: []const u8) usize {
    return 4 + value.len + 9 + 2 + 9 + ROUTING_KEY_FIELD + 9;
}

/// kv.set's request: value, ttl_ms, condition, cas_version, routing_key, txn.
fn encodeSetBody(buf: []u8, value: []const u8, options: types.PutOptions, txn: ?u64) FloError![]const u8 {
    if (value.len > types.MAX_KV_VALUE_SIZE) return FloError.ValueTooLarge;
    try checkRoutingKey(options.routing_key);
    var w: BodyWriter = .{ .buf = buf };
    w.lenBytes(u32, value);
    w.optU64(if (options.ttl_ms) |t| if (t > 0) t else null else null);
    w.put(&.{ 1, @intFromEnum(options.condition) });
    w.optU64(options.cas_version);
    w.routingKey(options.routing_key);
    w.optU64(txn);
    return w.written();
}

const MAX_DELETE_BODY = 9 + ROUTING_KEY_FIELD + 9;

/// kv.delete's request: cas_version, routing_key, txn.
fn encodeDeleteBody(buf: *[MAX_DELETE_BODY]u8, cas_version: ?u64, routing_key: ?[]const u8, txn: ?u64) FloError![]const u8 {
    try checkRoutingKey(routing_key);
    var w: BodyWriter = .{ .buf = buf };
    w.optU64(cas_version);
    w.routingKey(routing_key);
    w.optU64(txn);
    return w.written();
}

const MAX_SCAN_BODY = 5 + 1 + MAX_CURSOR;

/// kv.scan's request: limit, cursor ("" for the first page).
fn encodeScanBody(buf: *[MAX_SCAN_BODY]u8, limit: u32, cursor: []const u8) FloError![]const u8 {
    if (limit < 1 or limit > types.MAX_SCAN) return FloError.BadRequest;
    if (cursor.len > MAX_CURSOR) return FloError.BadRequest;
    var w: BodyWriter = .{ .buf = buf };
    w.put(&.{1});
    w.int(u32, limit);
    w.lenBytes(u8, cursor);
    return w.written();
}

const MAX_HISTORY_BODY = 5 + ROUTING_KEY_FIELD;

/// kv.history's request: limit, routing_key.
fn encodeHistoryBody(buf: *[MAX_HISTORY_BODY]u8, limit: u32, routing_key: ?[]const u8) FloError![]const u8 {
    if (limit < 1 or limit > types.MAX_HISTORY) return FloError.BadRequest;
    try checkRoutingKey(routing_key);
    var w: BodyWriter = .{ .buf = buf };
    w.put(&.{1});
    w.int(u32, limit);
    w.routingKey(routing_key);
    return w.written();
}

/// The size of kv.mget's body for `keys`, at most.
fn mgetBodySize(keys: []const []const u8) usize {
    var n: usize = 2 + ROUTING_KEY_FIELD;
    for (keys) |k| n += 2 + k.len;
    return n;
}

/// kv.mget's request: keys, routing_key. The caller has checked their
/// count and lengths.
fn encodeMgetBody(buf: []u8, keys: []const []const u8, routing_key: ?[]const u8) []const u8 {
    var w: BodyWriter = .{ .buf = buf };
    w.int(u16, @intCast(keys.len));
    for (keys) |k| w.lenBytes(u16, k);
    w.routingKey(routing_key);
    return w.written();
}

/// The longest kv.mget body the server takes.
const MAX_MGET_BODY = 257_949;
/// The most one kv.mget's key elements (each length and bytes) may total:
/// the body less the key count and the longest routing key.
const MAX_MGET_KEYS = MAX_MGET_BODY - 2 - ROUTING_KEY_FIELD;

/// Where the mget request that starts at `keys[start]` ends: as many keys as
/// fit one body. Keys are at most 4096 bytes, so at least one always does.
fn mgetChunkEnd(keys: []const []const u8, start: usize) usize {
    var size: usize = 0;
    var end = start;
    while (end < keys.len) : (end += 1) {
        size += 2 + keys[end].len;
        if (size > MAX_MGET_KEYS) break;
    }
    return end;
}

const MAX_INCR_BODY = 9 + ROUTING_KEY_FIELD + 9;

/// kv.incr's request: delta, routing_key, txn.
fn encodeIncrBody(buf: *[MAX_INCR_BODY]u8, delta: i64, routing_key: ?[]const u8, txn: ?u64) FloError![]const u8 {
    try checkRoutingKey(routing_key);
    var w: BodyWriter = .{ .buf = buf };
    w.put(&.{1});
    w.int(i64, delta);
    w.routingKey(routing_key);
    w.optU64(txn);
    return w.written();
}

const MAX_EXPIRE_BODY = 8 + 9 + ROUTING_KEY_FIELD + 9;

/// kv.expire's request: ttl_ms (required; 0 clears), cas_version, routing_key, txn.
fn encodeExpireBody(buf: *[MAX_EXPIRE_BODY]u8, ttl_ms: u64, cas_version: ?u64, routing_key: ?[]const u8, txn: ?u64) FloError![]const u8 {
    if (ttl_ms > types.MAX_TTL_MS) return FloError.BadRequest;
    try checkRoutingKey(routing_key);
    var w: BodyWriter = .{ .buf = buf };
    w.int(u64, ttl_ms);
    w.optU64(cas_version);
    w.routingKey(routing_key);
    w.optU64(txn);
    return w.written();
}

const MAX_EXISTS_BODY = ROUTING_KEY_FIELD + 9;

/// kv.exists's request: routing_key, txn.
fn encodeExistsBody(buf: *[MAX_EXISTS_BODY]u8, routing_key: ?[]const u8, txn: ?u64) FloError![]const u8 {
    try checkRoutingKey(routing_key);
    var w: BodyWriter = .{ .buf = buf };
    w.routingKey(routing_key);
    w.optU64(txn);
    return w.written();
}

/// A JSON path field: "" means the whole document, "$".
fn jsonPath(path: []const u8) FloError![]const u8 {
    if (path.len > types.MAX_JSON_PATH) return FloError.BadRequest;
    if (!std.unicode.utf8ValidateSlice(path)) return FloError.BadRequest;
    return if (path.len == 0) "$" else path;
}

const MAX_JSON_PATH_BODY = 3 + types.MAX_JSON_PATH + ROUTING_KEY_FIELD;

/// kv.json_get's and kv.json_del's request: path, routing_key.
fn encodeJsonPathBody(buf: *[MAX_JSON_PATH_BODY]u8, path: []const u8, routing_key: ?[]const u8) FloError![]const u8 {
    const p = try jsonPath(path);
    try checkRoutingKey(routing_key);
    var w: BodyWriter = .{ .buf = buf };
    w.put(&.{1});
    w.lenBytes(u16, p);
    w.routingKey(routing_key);
    return w.written();
}

/// The size of kv.json_set's body for `document`, at most.
fn jsonSetBodySize(document: []const u8) usize {
    return 3 + types.MAX_JSON_PATH + 4 + document.len + ROUTING_KEY_FIELD;
}

/// kv.json_set's request: path, document, routing_key.
fn encodeJsonSetBody(buf: []u8, path: []const u8, document: []const u8, routing_key: ?[]const u8) FloError![]const u8 {
    const p = try jsonPath(path);
    if (document.len > types.MAX_JSON_DOCUMENT_SIZE) return FloError.ValueTooLarge;
    try checkRoutingKey(routing_key);
    var w: BodyWriter = .{ .buf = buf };
    w.put(&.{1});
    w.lenBytes(u16, p);
    w.lenBytes(u32, document);
    w.routingKey(routing_key);
    return w.written();
}

/// kv.txn_commit's and kv.txn_rollback's request: txn.
fn txnBody(txn: u64) [8]u8 {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, txn, .little);
    return buf;
}

/// kv.get, inside transaction `txn` when given.
fn kvGet(client: *Client, namespace: []const u8, key: []const u8, options: types.GetOptions, txn: ?u64) FloError!?types.GetResult {
    var buf: [MAX_GET_BODY]u8 = undefined;
    const body = try encodeGetBody(&buf, options, txn);
    var response = try client.sendRequest(.kv_get, namespace, key, body, "");
    defer response.deinit();
    // Absent; any other not-found (no such transaction) is an error.
    if (response.status == .not_found and client.last_error_reason == .not_found) return null;
    if (response.status != .ok) return response.status.toError();
    return try decodeGetAnswer(client.allocator, response.data);
}

/// kv.set, inside transaction `txn` when given.
fn kvSet(client: *Client, namespace: []const u8, key: []const u8, value: []const u8, options: types.PutOptions, txn: ?u64) FloError!types.PutResult {
    const buf = try client.allocator.alloc(u8, setBodySize(value));
    defer client.allocator.free(buf);
    const body = try encodeSetBody(buf, value, options, txn);
    var response = try call(client, .kv_put, namespace, key, body);
    defer response.deinit();
    return try decodeSetAnswer(response.data);
}

/// kv.delete: whether the key existed, unknown (null) inside a transaction.
fn kvDelete(client: *Client, namespace: []const u8, key: []const u8, cas_version: ?u64, routing_key: ?[]const u8, txn: ?u64) FloError!?bool {
    var buf: [MAX_DELETE_BODY]u8 = undefined;
    const body = try encodeDeleteBody(&buf, cas_version, routing_key, txn);
    var response = try call(client, .kv_delete, namespace, key, body);
    defer response.deinit();
    return decodeDeleteAnswer(response.data);
}

fn kvIncr(client: *Client, namespace: []const u8, key: []const u8, delta: i64, routing_key: ?[]const u8, txn: ?u64) FloError!IncrAnswer {
    var buf: [MAX_INCR_BODY]u8 = undefined;
    const body = try encodeIncrBody(&buf, delta, routing_key, txn);
    var response = try call(client, .kv_incr, namespace, key, body);
    defer response.deinit();
    return decodeIncrAnswer(response.data);
}

fn kvExpire(client: *Client, namespace: []const u8, key: []const u8, ttl_ms: u64, cas_version: ?u64, routing_key: ?[]const u8, txn: ?u64) FloError!void {
    var buf: [MAX_EXPIRE_BODY]u8 = undefined;
    const body = try encodeExpireBody(&buf, ttl_ms, cas_version, routing_key, txn);
    var response = try call(client, .kv_expire, namespace, key, body);
    defer response.deinit();
    return decodeEmptyAnswer(response.data);
}

fn kvExists(client: *Client, namespace: []const u8, key: []const u8, routing_key: ?[]const u8, txn: ?u64) FloError!ExistsAnswer {
    var buf: [MAX_EXISTS_BODY]u8 = undefined;
    const body = try encodeExistsBody(&buf, routing_key, txn);
    var response = try call(client, .kv_exists, namespace, key, body);
    defer response.deinit();
    return decodeExistsAnswer(response.data);
}

/// Reads an answer field by field. A length that runs past the end is an
/// incomplete answer, and so are bytes left over (see `end`).
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn take(r: *Reader, n: usize) FloError![]const u8 {
        if (r.data.len - r.pos < n) return FloError.IncompleteResponse;
        defer r.pos += n;
        return r.data[r.pos..][0..n];
    }
    pub fn int(r: *Reader, comptime T: type) FloError!T {
        return std.mem.readInt(T, (try r.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
    /// A bool, or an optional field's presence byte: 0 or 1, nothing else.
    pub fn boolean(r: *Reader) FloError!bool {
        return switch ((try r.take(1))[0]) {
            0 => false,
            1 => true,
            else => FloError.IncompleteResponse,
        };
    }
    pub fn opt(r: *Reader, comptime T: type) FloError!?T {
        return if (try r.boolean()) try r.int(T) else null;
    }
    pub fn lenBytes(r: *Reader, comptime Len: type) FloError![]const u8 {
        return r.take(try r.int(Len));
    }
    pub fn remaining(r: *const Reader) usize {
        return r.data.len - r.pos;
    }
    pub fn end(r: *const Reader) FloError!void {
        if (r.pos != r.data.len) return FloError.IncompleteResponse;
    }
};

/// kv.get's answer: version, value, expires_at_ms.
fn decodeGetAnswer(allocator: Allocator, data: []const u8) FloError!types.GetResult {
    var r: Reader = .{ .data = data };
    const version = try r.int(u64);
    const value = try r.lenBytes(u32);
    const expires_at_ms = try r.opt(i64);
    try r.end();
    return .{ .version = version, .value = try allocator.dupe(u8, value), .expires_at_ms = expires_at_ms };
}

/// kv.json_get's answer: version, document.
fn decodeJsonGetAnswer(allocator: Allocator, data: []const u8) FloError!types.GetResult {
    var r: Reader = .{ .data = data };
    const version = try r.int(u64);
    const document = try r.lenBytes(u32);
    try r.end();
    return .{ .version = version, .value = try allocator.dupe(u8, document) };
}

/// kv.set's answer: its version, absent (0) inside a transaction.
fn decodeSetAnswer(data: []const u8) FloError!types.PutResult {
    var r: Reader = .{ .data = data };
    const version = try r.opt(u64);
    try r.end();
    return .{ .version = version orelse 0 };
}

/// An answer with no fields.
fn decodeEmptyAnswer(data: []const u8) FloError!void {
    if (data.len != 0) return FloError.IncompleteResponse;
}

/// kv.delete's answer: existed, null inside a transaction.
fn decodeDeleteAnswer(data: []const u8) FloError!?bool {
    var r: Reader = .{ .data = data };
    const existed: ?bool = if (try r.boolean()) try r.boolean() else null;
    try r.end();
    return existed;
}

/// kv.scan's answer: names, then the next page's cursor (null on the last).
fn decodeScanAnswer(allocator: Allocator, data: []const u8) FloError!types.ScanResult {
    var r: Reader = .{ .data = data };
    const n = try r.int(u16);
    // Each name is at least its length: a count the data can't hold is
    // refused before it sizes an allocation.
    if (n > r.remaining() / 2) return FloError.IncompleteResponse;
    const keys = try allocator.alloc([]const u8, n);
    var got: usize = 0;
    errdefer {
        for (keys[0..got]) |k| allocator.free(k);
        allocator.free(keys);
    }
    while (got < n) : (got += 1) keys[got] = try allocator.dupe(u8, try r.lenBytes(u16));
    const cursor: ?[]const u8 = if (try r.boolean()) try r.lenBytes(u8) else null;
    try r.end();
    return .{
        .keys = keys,
        .cursor = if (cursor) |c| try allocator.dupe(u8, c) else null,
        .allocator = allocator,
    };
}

/// kv.history's answer: versions, each {version, at_ms, deleted, value}, newest first.
fn decodeHistoryAnswer(allocator: Allocator, data: []const u8) FloError![]types.VersionEntry {
    var r: Reader = .{ .data = data };
    const n = try r.int(u8);
    if (n > r.remaining() / (8 + 8 + 1 + 4)) return FloError.IncompleteResponse;
    const entries = try allocator.alloc(types.VersionEntry, n);
    var got: usize = 0;
    errdefer {
        for (entries[0..got]) |*e| e.deinit(allocator);
        allocator.free(entries);
    }
    while (got < n) : (got += 1) {
        const version = try r.int(u64);
        const at_ms = try r.int(i64);
        const deleted = try r.boolean();
        const value = try r.lenBytes(u32);
        entries[got] = .{ .version = version, .at_ms = at_ms, .deleted = deleted, .value = try allocator.dupe(u8, value) };
    }
    try r.end();
    return entries;
}

/// kv.mget's answer: entries for the first keys, then `next`, the index of
/// the first key not answered (null when all were). Decodes into `out`, one
/// slot per requested key, with values borrowed from `data` and keys left
/// for the caller, and returns how many keys were answered.
fn decodeMgetAnswer(data: []const u8, out: []types.MGetEntry) FloError!usize {
    var r: Reader = .{ .data = data };
    const n = try r.int(u16);
    if (n > out.len) return FloError.UnexpectedResponse;
    for (out[0..n]) |*e| {
        const found = try r.boolean();
        const version = try r.int(u64);
        const value = try r.lenBytes(u32);
        e.* = .{ .key = "", .found = found, .version = version, .value = value };
    }
    const next = try r.opt(u16);
    try r.end();
    // The answered keys are the first ones, at least one, so asking again
    // from `next` makes progress.
    if (n == 0 or n != (next orelse out.len)) return FloError.UnexpectedResponse;
    return n;
}

/// kv.incr's answer; both null inside a transaction.
const IncrAnswer = struct { version: ?u64, value: ?i64 };

fn decodeIncrAnswer(data: []const u8) FloError!IncrAnswer {
    var r: Reader = .{ .data = data };
    const version = try r.opt(u64);
    const value = try r.opt(i64);
    try r.end();
    return .{ .version = version, .value = value };
}

/// kv.exists's answer; version is 0 when absent or a buffered write.
const ExistsAnswer = struct { exists: bool, version: u64 };

fn decodeExistsAnswer(data: []const u8) FloError!ExistsAnswer {
    var r: Reader = .{ .data = data };
    const exists = try r.boolean();
    const version = try r.int(u64);
    try r.end();
    return .{ .exists = exists, .version = version };
}

/// kv.json_set's answer: the document's version.
fn decodeJsonSetAnswer(data: []const u8) FloError!u64 {
    var r: Reader = .{ .data = data };
    const version = try r.int(u64);
    try r.end();
    return version;
}

/// kv.json_del's answer: the document's version, null when the key went.
fn decodeJsonDelAnswer(data: []const u8) FloError!?u64 {
    var r: Reader = .{ .data = data };
    const version = try r.opt(u64);
    try r.end();
    return version;
}

const TxnBeginAnswer = struct { txn: u64, pinned: u64 };

fn decodeTxnBeginAnswer(data: []const u8) FloError!TxnBeginAnswer {
    var r: Reader = .{ .data = data };
    const txn = try r.int(u64);
    const pinned = try r.int(u64);
    try r.end();
    return .{ .txn = txn, .pinned = pinned };
}

fn decodeCommitAnswer(data: []const u8) FloError!types.KVCommitResult {
    var r: Reader = .{ .data = data };
    const commit_index = try r.int(u64);
    const op_count = try r.int(u16);
    try r.end();
    return .{ .commit_index = commit_index, .op_count = op_count };
}

const testing = std.testing;
const test_server = @import("test_server.zig");

fn expectHex(comptime want: []const u8, got: []const u8) !void {
    var buf: [want.len / 2]u8 = undefined;
    try testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&buf, want), got);
}

inline fn hex(comptime s: []const u8) *const [s.len / 2]u8 {
    comptime {
        var buf: [s.len / 2]u8 = undefined;
        _ = std.fmt.hexToBytes(&buf, s) catch unreachable;
        const out = buf;
        return &out;
    }
}

test "kv.set's body carries every field in order" {
    var buf: [setBodySize("v")]u8 = undefined;
    const body = try encodeSetBody(&buf, "v", .{ .ttl_ms = 1500, .condition = .if_absent, .cas_version = 7, .routing_key = "rk" }, 9);
    var want: [43]u8 = undefined;
    var w: BodyWriter = .{ .buf = &want };
    w.int(u32, 1);
    w.put("v");
    w.optU64(1500);
    w.put(&.{ 1, 1 });
    w.optU64(7);
    w.put(&.{ 1, 2, 0, 'r', 'k' });
    w.optU64(9);
    try testing.expectEqualSlices(u8, w.written(), body);

    // A TTL of 0 is none, and the defaults go present.
    const plain = try encodeSetBody(&buf, "", .{ .ttl_ms = 0 }, null);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 1, 0, 0, 0, 0 }, plain);
    try testing.expectError(FloError.ValueTooLarge, encodeSetBody(&buf, &[_]u8{0} ** (types.MAX_KV_VALUE_SIZE + 1), .{}, null));
}

test "kv.get's body carries its wait, routing key and txn, and the read deadline covers the wait" {
    var buf: [MAX_GET_BODY]u8 = undefined;
    const body = try encodeGetBody(&buf, .{ .wait_ms = 5000, .wait_for = .change, .routing_key = "rk" }, null);
    var want: [32]u8 = undefined;
    var w: BodyWriter = .{ .buf = &want };
    w.put(&.{1});
    w.int(u64, 5000);
    w.put(&.{ 1, 1, 1, 2, 0, 'r', 'k', 0 });
    try testing.expectEqualSlices(u8, w.written(), body);
    try testing.expectError(FloError.BlockTooLong, encodeGetBody(&buf, .{ .wait_ms = types.MAX_WAIT_MS + 1 }, null));
    // An empty routing key is sent absent.
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0 }, try encodeGetBody(&buf, .{ .routing_key = "" }, null));
}

test "the other KV ops' requests match the server's schemas byte for byte" {
    var del: [MAX_DELETE_BODY]u8 = undefined;
    try expectHex("010700000000000000010200726b00", try encodeDeleteBody(&del, 7, "rk", null));
    var scan: [MAX_SCAN_BODY]u8 = undefined;
    try expectHex("0102000000026331", try encodeScanBody(&scan, 2, "c1"));
    var hist: [MAX_HISTORY_BODY]u8 = undefined;
    try expectHex("010200000000", try encodeHistoryBody(&hist, 2, null));
    try expectHex("0102000000010200726b", try encodeHistoryBody(&hist, 2, "rk"));
    const keys = [_][]const u8{ "a", "b" };
    var mget: [mgetBodySize(&keys)]u8 = undefined;
    try expectHex("020001006101006200", encodeMgetBody(&mget, &keys, null));
    try expectHex("0200010061010062010200726b", encodeMgetBody(&mget, &keys, "rk"));
    var incr: [MAX_INCR_BODY]u8 = undefined;
    try expectHex("01fbffffffffffffff00010900000000000000", try encodeIncrBody(&incr, -5, null, 9));
    var expire: [MAX_EXPIRE_BODY]u8 = undefined;
    try expectHex("60ea000000000000000000", try encodeExpireBody(&expire, 60000, null, null, null));
    var exists: [MAX_EXISTS_BODY]u8 = undefined;
    try expectHex("0000", try encodeExistsBody(&exists, null, null));
    var path: [MAX_JSON_PATH_BODY]u8 = undefined;
    try expectHex("010300242e6100", try encodeJsonPathBody(&path, "$.a", null));
    try expectHex("010300242e6200", try encodeJsonPathBody(&path, "$.b", null));
    var json_set: [jsonSetBodySize("{}")]u8 = undefined;
    try expectHex("01010024020000007b7d010200726b", try encodeJsonSetBody(&json_set, "$", "{}", "rk"));
    // "" is the whole document.
    try expectHex("01010024020000007b7d010200726b", try encodeJsonSetBody(&json_set, "", "{}", "rk"));
    try expectHex("0100000000000000", &txnBody(1));
}

test "the other KV ops' answers decode as the server's schemas write them" {
    const a = testing.allocator;
    try testing.expectEqual(@as(?bool, true), try decodeDeleteAnswer(hex("0101")));
    try testing.expectEqual(@as(?bool, null), try decodeDeleteAnswer(hex("00")));

    var page = try decodeScanAnswer(a, hex("02000100610200626201026332"));
    defer page.deinit();
    try testing.expectEqual(@as(usize, 2), page.keys.len);
    try testing.expectEqualStrings("a", page.keys[0]);
    try testing.expectEqualStrings("bb", page.keys[1]);
    try testing.expectEqualStrings("c2", page.cursor.?);
    var last = try decodeScanAnswer(a, hex("000000"));
    defer last.deinit();
    try testing.expectEqual(@as(usize, 0), last.keys.len);
    try testing.expect(last.cursor == null);

    const versions = try decodeHistoryAnswer(a, hex("010300000000000000e80300000000000000020000007633"));
    defer {
        for (versions) |*v| v.deinit(a);
        a.free(versions);
    }
    try testing.expectEqual(@as(usize, 1), versions.len);
    try testing.expectEqual(@as(u64, 3), versions[0].version);
    try testing.expectEqual(@as(i64, 1000), versions[0].at_ms);
    try testing.expect(!versions[0].deleted);
    try testing.expectEqualStrings("v3", versions[0].value);

    var out: [2]types.MGetEntry = undefined;
    try testing.expectEqual(@as(usize, 2), try decodeMgetAnswer(hex("0200010200000000000000010000007800000000000000000000000000010200"), &out));
    try testing.expect(out[0].found);
    try testing.expectEqual(@as(u64, 2), out[0].version);
    try testing.expectEqualStrings("x", out[0].value);
    try testing.expect(!out[1].found);
    try testing.expectEqualStrings("", out[1].value);

    const incr = try decodeIncrAnswer(hex("010400000000000000012a00000000000000"));
    try testing.expectEqual(@as(?u64, 4), incr.version);
    try testing.expectEqual(@as(?i64, 42), incr.value);
    const buffered = try decodeIncrAnswer(hex("0000"));
    try testing.expect(buffered.version == null and buffered.value == null);

    try decodeEmptyAnswer("");
    const exists = try decodeExistsAnswer(hex("010500000000000000"));
    try testing.expect(exists.exists);
    try testing.expectEqual(@as(u64, 5), exists.version);

    var doc = try decodeJsonGetAnswer(a, hex("0300000000000000020000007b7d"));
    defer doc.deinit(a);
    try testing.expectEqual(@as(u64, 3), doc.version);
    try testing.expectEqualStrings("{}", doc.value);
    try testing.expectEqual(@as(u64, 3), try decodeJsonSetAnswer(hex("0300000000000000")));
    try testing.expectEqual(@as(?u64, null), try decodeJsonDelAnswer(hex("00")));

    const begun = try decodeTxnBeginAnswer(hex("01000000000000000200000000000000"));
    try testing.expectEqual(@as(u64, 1), begun.txn);
    try testing.expectEqual(@as(u64, 2), begun.pinned);
    const committed = try decodeCommitAnswer(hex("0a000000000000000200"));
    try testing.expectEqual(@as(u64, 10), committed.commit_index);
    try testing.expectEqual(@as(u16, 2), committed.op_count);
}

/// Every decoder, run on `data` and its result freed: for the test that an
/// answer with a byte missing or a byte over is refused.
fn decodeAny(which: usize, data: []const u8) FloError!void {
    const a = testing.allocator;
    switch (which) {
        0 => _ = try decodeDeleteAnswer(data),
        1 => {
            var r = try decodeScanAnswer(a, data);
            r.deinit();
        },
        2 => {
            const v = try decodeHistoryAnswer(a, data);
            for (v) |*e| e.deinit(a);
            a.free(v);
        },
        3 => {
            var out: [2]types.MGetEntry = undefined;
            _ = try decodeMgetAnswer(data, &out);
        },
        4 => _ = try decodeIncrAnswer(data),
        5 => _ = try decodeExistsAnswer(data),
        6 => {
            var r = try decodeJsonGetAnswer(a, data);
            r.deinit(a);
        },
        7 => _ = try decodeJsonSetAnswer(data),
        8 => _ = try decodeJsonDelAnswer(data),
        9 => _ = try decodeTxnBeginAnswer(data),
        10 => _ = try decodeCommitAnswer(data),
        11 => _ = try decodeSetAnswer(data),
        12, 13 => {
            var r = try decodeGetAnswer(a, data);
            r.deinit(a);
        },
        else => unreachable,
    }
}

test "kv.get's answer carries the key's expiry when it has a TTL" {
    const a = testing.allocator;
    var plain = try decodeGetAnswer(a, hex("0300000000000000010000007600"));
    defer plain.deinit(a);
    try testing.expectEqual(@as(u64, 3), plain.version);
    try testing.expectEqualStrings("v", plain.value);
    try testing.expectEqual(@as(?i64, null), plain.expires_at_ms);

    var ttl = try decodeGetAnswer(a, hex("030000000000000001000000760100ca9a3b00000000"));
    defer ttl.deinit(a);
    try testing.expectEqual(@as(?i64, 1_000_000_000), ttl.expires_at_ms);

    // Cut inside the i64.
    try testing.expectError(FloError.IncompleteResponse, decodeGetAnswer(a, hex("030000000000000001000000760100ca9a")));
}

test "kv.history marks a delete's version" {
    const a = testing.allocator;
    // v3 "c", v2 deleted, v1 "a".
    const versions = try decodeHistoryAnswer(a, hex("03" ++
        "0300000000000000" ++ "0300000000000000" ++ "00" ++ "01000000" ++ "63" ++
        "0200000000000000" ++ "0200000000000000" ++ "01" ++ "00000000" ++
        "0100000000000000" ++ "0100000000000000" ++ "00" ++ "01000000" ++ "61"));
    defer {
        for (versions) |*v| v.deinit(a);
        a.free(versions);
    }
    try testing.expectEqual(@as(usize, 3), versions.len);
    try testing.expect(!versions[0].deleted);
    try testing.expectEqualStrings("c", versions[0].value);
    try testing.expect(versions[1].deleted);
    try testing.expectEqual(@as(u64, 2), versions[1].version);
    try testing.expectEqualStrings("", versions[1].value);
    try testing.expect(!versions[2].deleted);
    try testing.expectEqualStrings("a", versions[2].value);
}

test "answers decode whole or not at all" {
    const answers = [_][]const u8{
        hex("0101"),
        hex("02000100610200626201026332"),
        hex("010300000000000000e80300000000000000020000007633"),
        hex("0200010200000000000000010000007800000000000000000000000000010200"),
        hex("010400000000000000012a00000000000000"),
        hex("010500000000000000"),
        hex("0300000000000000020000007b7d"),
        hex("0300000000000000"),
        hex("010300000000000000"),
        hex("01000000000000000200000000000000"),
        hex("0a000000000000000200"),
        hex("010900000000000000"),
        hex("0300000000000000010000007600"),
        hex("030000000000000001000000760100ca9a3b00000000"),
    };
    for (answers, 0..) |data, which| {
        try decodeAny(which, data);
        try testing.expectError(FloError.IncompleteResponse, decodeAny(which, data[0 .. data.len - 1]));
        var over: [128]u8 = undefined;
        @memcpy(over[0..data.len], data);
        over[data.len] = 0;
        try testing.expectError(FloError.IncompleteResponse, decodeAny(which, over[0 .. data.len + 1]));
    }
    try testing.expectError(FloError.IncompleteResponse, decodeEmptyAnswer(&.{0}));
    // A bool or presence byte is 0 or 1.
    try testing.expectError(FloError.IncompleteResponse, decodeDeleteAnswer(&.{ 1, 2 }));
    try testing.expectError(FloError.IncompleteResponse, decodeSetAnswer(&.{2}));
    // kv.get's expires_at_ms presence byte, and a history entry's deleted.
    try testing.expectError(FloError.IncompleteResponse, decodeAny(12, hex("0300000000000000010000007602")));
    try testing.expectError(FloError.IncompleteResponse, decodeAny(2, hex("010300000000000000e80300000000000002020000007633")));
    // A scan count its data can't hold is refused before it allocates.
    try testing.expectError(FloError.IncompleteResponse, decodeScanAnswer(testing.allocator, &.{ 0xff, 0xff, 0 }));
}

test "mget refuses an answer that doesn't make progress or overruns the keys asked" {
    var out: [2]types.MGetEntry = undefined;
    // No entries, next 0.
    try testing.expectError(FloError.UnexpectedResponse, decodeMgetAnswer(hex("0000010000"), &out));
    // One entry, no next: the second key went unanswered.
    try testing.expectError(FloError.UnexpectedResponse, decodeMgetAnswer(hex("01000000000000000000000000000000"), &out));
    // Two entries for one key.
    var one: [1]types.MGetEntry = undefined;
    try testing.expectError(FloError.UnexpectedResponse, decodeMgetAnswer(hex("0200010200000000000000010000007800000000000000000000000000010200"), &one));
}

test "mget asks again from next until every key is answered" {
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{
        // a found at version 2 = "x"; next 1.
        .{ .status = 0, .body = hex("01000102000000000000000100000078010100") },
        // b missing; no next.
        .{ .status = 0, .body = hex("01000000000000000000000000000000") },
    };
    try srv.start();
    defer srv.deinit();

    var client = Client.init(testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var kv = KV.init(&client);

    var result = try kv.mget(&.{ "a", "b" }, .{ .routing_key = "rk" });
    defer result.deinit();
    try testing.expectEqual(@as(u32, 2), srv.requests.load(.acquire));
    try testing.expectEqual(@as(u16, @intFromEnum(types.OpCode.kv_mget)), srv.last_op);
    try testing.expectEqualStrings("", srv.lastKey());
    // The second request asks for the keys from next on, by the same routing key.
    try expectHex("0100010062010200726b", srv.lastBody());

    try testing.expectEqual(@as(usize, 2), result.entries.len);
    try testing.expectEqualStrings("a", result.entries[0].key);
    try testing.expect(result.entries[0].found);
    try testing.expectEqual(@as(u64, 2), result.entries[0].version);
    try testing.expectEqualStrings("x", result.entries[0].value);
    try testing.expectEqualStrings("b", result.entries[1].key);
    try testing.expect(!result.entries[1].found);
}

test "an mget too big for one body is split across bodies that each fit" {
    var keys: [200][]const u8 = undefined;
    const key = "k" ** types.MAX_MGET_KEY;
    for (&keys) |*k| k.* = key;
    const end = mgetChunkEnd(&keys, 0);
    try testing.expect(end > 0 and end < keys.len);
    // The keys total at most 253848 bytes, leaving room for the count and the
    // longest routing key; one key more would overrun.
    try testing.expectEqual(253_848, MAX_MGET_KEYS);
    try testing.expectEqual(@as(usize, MAX_MGET_KEYS / (2 + types.MAX_MGET_KEY)), end);
    var body_buf: [MAX_MGET_BODY]u8 = undefined;
    const rk = "r" ** MAX_ROUTING_KEY;
    try testing.expect(encodeMgetBody(&body_buf, keys[0..end], rk).len <= MAX_MGET_BODY);
    try testing.expect(mgetBodySize(keys[0 .. end + 1]) > MAX_MGET_BODY);
    // Small keys split exactly at the bound.
    var small: [256][]const u8 = undefined;
    const small_key = "s" ** 1000;
    for (&small) |*k| k.* = small_key;
    try testing.expectEqual(@as(usize, MAX_MGET_KEYS / 1002), mgetChunkEnd(&small, 0));
    // A full body still fits the request frame.
    try testing.expect(wire.requestSize(.kv_mget, "default", "", &[_]u8{0} ** MAX_MGET_BODY, "") <= Client.max_request_size);
    // The next chunk starts where this one ended.
    try testing.expectEqual(2 * end, mgetChunkEnd(&keys, end));
}

test "delete says whether the key existed; a missing key is no error" {
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{
        .{ .status = 0, .body = hex("0100") },
        .{ .status = 0, .body = hex("0101") },
    };
    try srv.start();
    defer srv.deinit();

    var client = Client.init(testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var kv = KV.init(&client);

    try testing.expect(!try kv.delete("gone", .{}));
    try testing.expectEqualStrings("gone", srv.lastKey());
    try expectHex("000000", srv.lastBody());
    try testing.expect(try kv.delete("here", .{ .cas_version = 7, .routing_key = "rk" }));
    try expectHex("010700000000000000010200726b00", srv.lastBody());
}

test "transaction ops carry the txn and its routing key; commit and rollback carry only the txn" {
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{
        .{ .status = 0, .body = hex("01000000000000000200000000000000") }, // begin
        .{ .status = 0, .body = hex("00") }, // delete
        .{ .status = 0, .body = hex("0000") }, // incr
        .{ .status = 0, .body = "" }, // expire
        .{ .status = 0, .body = hex("000000000000000000") }, // exists
        .{ .status = 0, .body = hex("0a000000000000000200") }, // commit
        .{ .status = 0, .body = hex("03000000000000000000000000000000") }, // begin
        .{ .status = 0, .body = "" }, // rollback
    };
    try srv.start();
    defer srv.deinit();

    var client = Client.init(testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var kv = KV.init(&client);
    const op = struct {
        fn of(o: types.OpCode) u16 {
            return @intFromEnum(o);
        }
    }.of;

    var txn = try kv.begin("rk", .{});
    defer txn.deinit();
    try testing.expectEqual(op(.kv_txn_begin), srv.last_op);
    try testing.expectEqualStrings("rk", srv.lastKey());
    try testing.expectEqualStrings("", srv.lastBody());
    try testing.expectEqual(@as(u64, 1), txn.id);
    try testing.expectEqual(@as(u64, 2), txn.pinned_hash);

    try txn.delete("k", .{ .cas_version = 7 });
    try testing.expectEqual(op(.kv_delete), srv.last_op);
    try testing.expectEqualStrings("k", srv.lastKey());
    try expectHex("010700000000000000010200726b010100000000000000", srv.lastBody());

    try txn.incr("n", -5);
    try testing.expectEqual(op(.kv_incr), srv.last_op);
    try expectHex("01fbffffffffffffff010200726b010100000000000000", srv.lastBody());

    try txn.expire("k", 60000, .{});
    try testing.expectEqual(op(.kv_expire), srv.last_op);
    try expectHex("60ea00000000000000010200726b010100000000000000", srv.lastBody());

    try testing.expect(!try txn.exists("k"));
    try testing.expectEqual(op(.kv_exists), srv.last_op);
    try expectHex("010200726b010100000000000000", srv.lastBody());

    const committed = try txn.commit();
    try testing.expectEqual(op(.kv_txn_commit), srv.last_op);
    try testing.expectEqualStrings("", srv.lastKey());
    try expectHex("0100000000000000", srv.lastBody());
    try testing.expectEqual(@as(u64, 10), committed.commit_index);
    try testing.expectEqual(@as(u16, 2), committed.op_count);
    try testing.expectError(FloError.TxnFinished, txn.delete("k", .{}));
    try txn.rollback(); // a no-op after commit

    var other = try kv.begin("rk", .{});
    defer other.deinit();
    try other.rollback();
    try testing.expectEqual(op(.kv_txn_rollback), srv.last_op);
    try testing.expectEqualStrings("", srv.lastKey());
    try expectHex("0300000000000000", srv.lastBody());
    try testing.expectEqual(@as(u32, 8), srv.requests.load(.acquire));
}

test "requests out of bounds are refused before a round trip" {
    var srv = try test_server.OkServer.listen();
    try srv.start();
    defer srv.deinit();

    var client = Client.init(testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var kv = KV.init(&client);

    try testing.expectError(FloError.BadRequest, kv.scan("", .{ .limit = 0 }));
    try testing.expectError(FloError.BadRequest, kv.scan("", .{ .limit = types.MAX_SCAN + 1 }));
    try testing.expectError(FloError.BadRequest, kv.scan("", .{ .cursor = "c" ** (MAX_CURSOR + 1) }));
    try testing.expectError(FloError.BadRequest, kv.history("k", .{ .limit = 0 }));
    try testing.expectError(FloError.BadRequest, kv.history("k", .{ .limit = types.MAX_HISTORY + 1 }));
    try testing.expectError(FloError.BadRequest, kv.mget(&.{}, .{}));
    const many = [_][]const u8{"k"} ** (types.MAX_MGET + 1);
    try testing.expectError(FloError.BadRequest, kv.mget(&many, .{}));
    try testing.expectError(FloError.BadRequest, kv.expire("k", types.MAX_TTL_MS + 1, .{}));
    try testing.expectError(FloError.BadRequest, kv.jsonGet("k", "$" ** (types.MAX_JSON_PATH + 1), .{}));
    try testing.expectError(FloError.BadRequest, kv.jsonDel("k", "\xff", .{}));
    const rk = "r" ** (MAX_ROUTING_KEY + 1);
    try testing.expectError(FloError.KeyTooLarge, kv.exists("k", .{ .routing_key = rk }));
    try testing.expectError(FloError.KeyTooLarge, kv.incr("k", .{ .routing_key = rk }));
    try testing.expectError(FloError.KeyTooLarge, kv.delete("k", .{ .routing_key = rk }));
    try testing.expectError(FloError.KeyTooLarge, kv.begin(rk, .{}));
    try testing.expectError(FloError.BadRequest, kv.begin("", .{}));
    const doc = try testing.allocator.alloc(u8, types.MAX_JSON_DOCUMENT_SIZE + 1);
    defer testing.allocator.free(doc);
    try testing.expectError(FloError.ValueTooLarge, kv.jsonSet("k", "$", doc, .{}));
    const long_key = "k" ** (types.MAX_MGET_KEY + 1);
    try testing.expectError(FloError.KeyTooLarge, kv.mget(&.{long_key}, .{}));
    try testing.expectError(FloError.KeyTooLarge, kv.mget(&.{"k"}, .{ .routing_key = rk }));
    try testing.expectError(FloError.KeyTooLarge, kv.history("k", .{ .routing_key = rk }));
    try testing.expectEqual(@as(u32, 0), srv.requests.load(.acquire));
    try testing.expect(client.isConnected());
}

test "scan sends its limit and cursor and returns names and the next cursor" {
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{
        .{ .status = 0, .body = hex("02000100610200626201026332") },
        .{ .status = 0, .body = hex("000000") },
    };
    try srv.start();
    defer srv.deinit();

    var client = Client.init(testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var kv = KV.init(&client);

    var result = try kv.scan("p", .{ .limit = 7, .cursor = "abc" });
    defer result.deinit();
    try testing.expectEqualStrings("p", srv.lastKey());
    try expectHex("010700000003616263", srv.lastBody());
    try testing.expectEqual(@as(usize, 2), result.keys.len);
    try testing.expectEqualStrings("bb", result.keys[1]);
    try testing.expectEqualStrings("c2", result.cursor.?);

    // First page: an empty cursor, and the default limit, the server's.
    var first = try kv.scan("p", .{});
    defer first.deinit();
    try expectHex("010004000000", srv.lastBody());
    try testing.expect(first.cursor == null);
}

test "incr, expire, exists and the JSON ops answer through their schemas" {
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{
        .{ .status = 0, .body = hex("010400000000000000012a00000000000000") }, // incr
        .{ .status = 0, .body = "" }, // expire
        .{ .status = 0, .body = hex("010500000000000000") }, // exists
        .{ .status = 0, .body = hex("0300000000000000020000007b7d") }, // json_get
        // json_get: missing key; then no such transaction, an error.
        .{ .status = 2, .body = "\x0d\x00\x00missing" },
        .{ .status = 2, .body = "\x11\x00\x00no txn" },
        .{ .status = 0, .body = hex("0300000000000000") }, // json_set
        .{ .status = 0, .body = hex("00") }, // json_del "$"
        .{ .status = 0, .body = hex("010400000000000000") }, // json_del "$.b"
    };
    try srv.start();
    defer srv.deinit();

    var client = Client.init(testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var kv = KV.init(&client);

    const n = try kv.incr("n", .{});
    try testing.expectEqual(@as(i64, 42), n.value);
    try testing.expectEqual(@as(u64, 4), n.version);
    try expectHex("0101000000000000000000", srv.lastBody());

    try kv.expire("k", 0, .{ .cas_version = 3 });
    try expectHex("00000000000000000103000000000000000000", srv.lastBody());

    try testing.expect(try kv.exists("k", .{}));

    var doc = (try kv.jsonGet("k", "", .{})).?;
    defer doc.deinit(testing.allocator);
    try testing.expectEqualStrings("{}", doc.value);
    try expectHex("0101002400", srv.lastBody());
    try testing.expect(try kv.jsonGet("k", "$", .{}) == null);
    try testing.expectError(FloError.NotFound, kv.jsonGet("k", "$", .{}));
    try testing.expectEqual(types.Reason.no_such_transaction, client.lastError().?.reason);

    try testing.expectEqual(@as(u64, 3), (try kv.jsonSet("k", "$", "{}", .{})).version);
    try testing.expect(try kv.jsonDel("k", "$", .{}) == null);
    try testing.expectEqual(@as(u64, 4), (try kv.jsonDel("k", "$.b", .{})).?.version);
}

test "status 12 and an unknown status each surface with their message, and the next reply is read whole" {
    // A kv.get answer: [version:u64][value_len:u32][value][expires_at_ms: none].
    const ok_body = [_]u8{ 7, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 'v', 0 };
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{
        // Refusal bodies: [reason:u16][ran:u8][message].
        .{ .status = 12, .body = "\x0c\x00\x00shard offline" },
        .{ .status = 0, .body = &ok_body },
        .{ .status = 200, .body = "\x0a\x00\x01from the future" },
        .{ .status = 0, .body = &ok_body },
    };
    try srv.start();
    defer srv.deinit();

    // Not retried, so the second call reads the next reply.
    var client = Client.init(std.testing.allocator, srv.endpoint, .{ .retry = .{ .max_attempts = 1 } });
    defer client.deinit();
    try client.connect();
    var kv = KV.init(&client);

    try std.testing.expectError(FloError.Unavailable, kv.get("k", .{}));
    try std.testing.expectEqual(@as(u8, 12), client.lastError().?.code);
    try std.testing.expectEqualStrings("shard offline", client.lastError().?.message);
    try std.testing.expectEqual(types.Reason.unclassified, client.lastError().?.reason);
    try std.testing.expectEqual(types.Ran.no, client.lastError().?.ran);

    var first = (try kv.get("k", .{})).?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 7), first.version);
    try std.testing.expectEqualStrings("v", first.value);
    try std.testing.expect(client.lastError() == null);

    try std.testing.expectError(FloError.ServerError, kv.get("k", .{}));
    try std.testing.expectEqual(@as(u8, 200), client.lastError().?.code);
    try std.testing.expectEqualStrings("from the future", client.lastError().?.message);
    try std.testing.expectEqual(types.Reason.committed_not_applied, client.lastError().?.reason);
    try std.testing.expectEqual(types.Ran.yes, client.lastError().?.ran);

    var second = (try kv.get("k", .{})).?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("v", second.value);
}

test "a refusal whose body isn't [reason][ran][message] is refused, not guessed at" {
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{
        .{ .status = 3, .body = "\x01\x00" },
        .{ .status = 3, .body = "\xff\xff\x00x" },
        .{ .status = 3, .body = "\x01\x00\x09x" },
        // Reason 257: read as a byte it would pass as unknown_op.
        .{ .status = 3, .body = "\x01\x01\x00x" },
    };
    try srv.start();
    defer srv.deinit();

    var client = Client.init(std.testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var kv = KV.init(&client);
    for (0..4) |_| {
        try std.testing.expectError(FloError.IncompleteResponse, kv.get("k", .{}));
        try std.testing.expect(client.lastError() == null);
    }
}

test "values up to the server's bounds go out in one frame; a frame over it is refused unsent" {
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{
        .{ .status = 0, .body = hex("010900000000000000") }, // put
        .{ .status = 0, .body = hex("0300000000000000") }, // json_set
    };
    try srv.start();
    defer srv.deinit();

    var client = Client.init(testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var kv = KV.init(&client);

    const value = try testing.allocator.alloc(u8, 200 * 1024);
    defer testing.allocator.free(value);
    @memset(value, 'v');
    try testing.expectEqual(@as(u64, 9), (try kv.put("k", value, .{})).version);
    try testing.expectEqualSlices(u8, value, srv.lastBody()[4..][0..value.len]);
    try testing.expectEqual(@as(u64, 3), (try kv.jsonSet("k", "$", value, .{})).version);
    try testing.expectEqualSlices(u8, value, srv.lastBody()[8..][0..value.len]);

    const over = try testing.allocator.alloc(u8, Client.max_request_size);
    defer testing.allocator.free(over);
    try testing.expectError(FloError.PayloadTooLarge, client.sendRequest(.kv_put, "default", "k", over, ""));
    try testing.expectEqual(@as(u32, 2), srv.requests.load(.acquire));
    try testing.expect(client.isConnected());
}

test "history of a missing key is empty" {
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{
        .{ .status = 0, .body = hex("00") },
        .{ .status = 2, .body = "\x0d\x00\x00missing" },
    };
    try srv.start();
    defer srv.deinit();

    var client = Client.init(testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var kv = KV.init(&client);

    for (0..2) |_| {
        const versions = try kv.history("gone", .{ .routing_key = "rk" });
        defer testing.allocator.free(versions);
        try testing.expectEqual(@as(usize, 0), versions.len);
    }
    try expectHex("010a000000010200726b", srv.lastBody());
}
