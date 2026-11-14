//! Flo SDK Types
//!
//! Core types, constants, and error definitions for the Flo client SDK.

const std = @import("std");

/// Protocol magic number: "FLO\0" (0x004F4C46 in little-endian)
pub const MAGIC: u32 = 0x004F4C46;

/// Protocol version
pub const VERSION: u8 = 0x03;

/// The hash of the op table this SDK was built for, written into every
/// request header. A server built from another table refuses the request,
/// and its answers carry its own hash, which this SDK refuses. Bump it in
/// the same commit as FLO_REF in .github/flo-ref.env, so the live tests run
/// against a server built with it.
pub const TABLE_HASH: u64 = 0xc1f93eb0ed86a281;

/// Why the server refused a request. Mirrors the server's list. A reason
/// this SDK predates still decodes, as its number (`_`), with the status
/// and message beside it: the status says whether to retry.
pub const Reason = enum(u16) {
    unknown_op = 1,
    malformed = 2,
    field_too_long = 3,
    out_of_range = 4,
    leader_unknown = 5,
    shard_busy = 6,
    table_mismatch = 7,
    unknown_flag = 8,
    internal = 9,
    committed_not_applied = 10,
    answer_lost = 11,
    /// A refusal from an op family the server hasn't classified yet.
    unclassified = 12,
    /// What the request names doesn't exist.
    not_found = 13,
    /// The key is in a prefix the server keeps for itself.
    reserved_key = 14,
    /// The write's cas_version isn't the key's version.
    cas_mismatch = 15,
    /// The write's condition didn't hold.
    condition_failed = 16,
    /// No open transaction has this id here.
    no_such_transaction = 17,
    /// This key routes elsewhere than the key the transaction was begun
    /// with: give every key in a transaction the same `{tag}`.
    keys_not_colocated = 18,
    /// The transaction holds as many ops or bytes as it may.
    txn_too_large = 19,
    /// The shard holds as many waiting reads as it may.
    too_many_waiters = 20,
    /// Two fields given together that don't go together.
    conflicting_fields = 21,
    /// The shard stopped taking writes until the node restarts.
    writes_stopped = 22,
    /// Too many writes wait for commit.
    too_many_proposals = 23,
    /// The key's value isn't the kind the op needs (a counter, a JSON document).
    wrong_type = 24,
    /// The shard holds as many open transactions as it may.
    too_many_transactions = 25,
    /// An action complete, fail or touch for a delivery that has moved on:
    /// its lease ran out, it was delivered again, another worker holds it,
    /// or it finished another way. It was dropped. A resend of a report
    /// that already applied answers ok, not this.
    stale_report = 26,
    /// An action await from a worker that missed its heartbeats: heartbeat,
    /// or register again, before taking work.
    worker_unhealthy = 27,
    /// An action await from a worker the server is draining: it takes no
    /// more work.
    worker_draining = 28,
    /// The shard halted at an entry every replica fails the same way: it
    /// takes no writes until an operator repairs it. With unavailable it
    /// didn't run; with outcome_pending it committed. Never retried by the
    /// client.
    shard_halted = 29,
    /// The op is served only on the node's admin socket.
    admin_only = 30,
    /// A processing remove of a job still running: stop or cancel it first.
    job_running = 31,
    /// Status limit: the node's memory budget is spent.
    memory_budget = 32,
    /// Status limit: the shard holds as many actions as it registers.
    too_many_actions = 33,
    /// Status limit: the node holds as many workflow definitions as it keeps.
    too_many_workflow_definitions = 34,
    /// Status limit: the node holds as many workflow runs as it keeps.
    too_many_workflow_runs = 35,
    /// Status overloaded: the queue holds as many messages or bytes as its
    /// caps allow, or the shard's queues and groups together do. It drains
    /// as messages are acked, so the client retries it.
    queue_full = 36,
    /// Status overloaded: a group read took nothing new because the group's
    /// consumers hold too many records unacked (or it holds dead ones).
    /// Reading again won't help until they ack or nack: `FloError.GroupHeldFull`,
    /// never retried.
    group_held_full = 37,

    _,
};

/// Whether a refused request took effect: retry logic reads this, not the
/// message.
pub const Ran = enum(u8) {
    no = 0,
    /// It took effect; don't resend it.
    yes = 1,
    /// It may still take effect; check before resending.
    unknown = 2,
};

/// Size limits (for client-side validation)
pub const MAX_NAMESPACE_SIZE: usize = 255;
pub const MAX_KEY_SIZE: usize = 64 * 1024; // 64 KB
pub const MAX_VALUE_SIZE: usize = 16 * 1024 * 1024; // 16 MB practical limit
/// Longest blocking wait (block_ms / wait_ms) the server accepts: 5 minutes.
/// The server refuses anything longer with bad_request.
pub const MAX_BLOCK_MS: u32 = 300_000;
/// Longest a KV get may wait (wait_ms).
pub const MAX_WAIT_MS: u64 = 300_000;
/// Longest value a KV put takes.
pub const MAX_KV_VALUE_SIZE: usize = 257_916;
/// The longest JSON document kv.json_set takes.
pub const MAX_JSON_DOCUMENT_SIZE: usize = 256_918;
/// The longest JSON path.
pub const MAX_JSON_PATH: usize = 1024;
/// The most names one kv.scan page holds.
pub const MAX_SCAN: u32 = 1024;
/// The most versions kv.history returns.
pub const MAX_HISTORY: u32 = 65;
/// The most keys one kv.mget takes.
pub const MAX_MGET: usize = 256;
/// The longest key a kv.mget names.
pub const MAX_MGET_KEY: usize = 4096;
/// The longest TTL: milliseconds whose nanoseconds fit a u64.
pub const MAX_TTL_MS: u64 = 18_446_744_073_709;

/// What a KV get with wait_ms waits for.
pub const WaitFor = enum(u8) {
    /// The key to exist; one that exists answers at once.
    exists = 0,
    /// The key's next version.
    change = 1,
};

/// When a KV put may write.
pub const Condition = enum(u8) {
    always = 0,
    if_absent = 1,
    if_present = 2,
};
/// Long-poll wait a worker uses when its config says 0. A worker always
/// long-polls, since 0 (don't wait) would spin its poll loop against the server.
pub const DEFAULT_WORKER_BLOCK_MS: u32 = 30_000;

/// Refuse a blocking wait the server would refuse, before the round trip.
pub fn checkBlockMs(block_ms: u32) FloError!void {
    if (block_ms > MAX_BLOCK_MS) return FloError.BlockTooLong;
}

pub fn workerBlockMs(block_ms: u32) FloError!u32 {
    if (block_ms == 0) return DEFAULT_WORKER_BLOCK_MS;
    try checkBlockMs(block_ms);
    return block_ms;
}

/// Paces polls that come back empty early. The server answers a blocking
/// read early and empty both when it has no room to park it and, for a group
/// read, when an append wakes it as a cue to re-read. Only timing tells them
/// apart. So an empty counts as early under min(EARLY_EMPTY_MS, block_ms/2),
/// the first early empty is re-polled at once, and back-to-back ones pause
/// 50 ms doubling to 1 s.
pub const EmptyPollBackoff = struct {
    early_empties: u32 = 0,

    pub const EARLY_EMPTY_MS: u64 = 250;
    pub const MIN_PAUSE_MS: u64 = 50;
    pub const MAX_PAUSE_MS: u64 = 1_000;

    /// Record a poll that took `elapsed_ns` with `block_ms` and returned
    /// work or not; returns how long to pause before the next poll.
    pub fn afterPoll(self: *EmptyPollBackoff, empty: bool, elapsed_ns: u64, block_ms: u32) u64 {
        const early_ms: u64 = @min(EARLY_EMPTY_MS, @as(u64, block_ms) / 2);
        if (!empty or elapsed_ns >= early_ms * std.time.ns_per_ms) {
            self.early_empties = 0;
            return 0;
        }
        self.early_empties +|= 1;
        if (self.early_empties == 1) return 0;
        const shift: u6 = @intCast(@min(self.early_empties - 2, 5));
        return @min(MIN_PAUSE_MS << shift, MAX_PAUSE_MS);
    }
};

/// Sleep for `ms`, in short slices, returning early once `running` is false.
pub fn pauseWhileRunning(running: *const bool, ms: u64) void {
    pauseUnlessHalted(running, null, ms);
}

/// Whether a worker loop goes on: `running` is set and `halt`, if given, isn't.
/// A drain halts a worker's reconnects and backoffs without stopping it.
pub fn goingOn(running: *const bool, halt: ?*const bool) bool {
    if (!@atomicLoad(bool, running, .monotonic)) return false;
    return if (halt) |h| !@atomicLoad(bool, h, .monotonic) else true;
}

/// `pauseWhileRunning`, also returning early once `halt`, if given, is set.
pub fn pauseUnlessHalted(running: *const bool, halt: ?*const bool, ms: u64) void {
    const slice_ms: u64 = 10;
    var left = ms;
    while (left > 0 and goingOn(running, halt)) {
        const step: u64 = @min(left, slice_ms);
        std.Thread.sleep(step * std.time.ns_per_ms);
        left -= step;
    }
}

/// A loop backing off from limit refusals logs each distinct reason once,
/// not once per tick, even when reasons alternate. `clear` after a call
/// that succeeds, so a limit hit again later is logged again.
pub const LimitNotice = struct {
    /// The reasons logged since the last clear.
    seen: [8]Reason = undefined,
    seen_len: usize = 0,

    /// Log the limit refusal `client.lastError()` holds, unless its reason
    /// was logged already.
    pub fn note(self: *LimitNotice, client: anytype, comptime what: []const u8) void {
        const last = client.lastError() orelse return;
        if (self.logged(last.reason)) return;
        if (self.seen_len < self.seen.len) {
            self.seen[self.seen_len] = last.reason;
            self.seen_len += 1;
        }
        std.log.warn(what ++ " refused at a limit ({s}): {s}; backing off, not retrying it until it passes", .{ std.enums.tagName(Reason, last.reason) orelse "unknown", last.message });
    }

    pub fn logged(self: *const LimitNotice, reason: Reason) bool {
        return std.mem.indexOfScalar(Reason, self.seen[0..self.seen_len], reason) != null;
    }

    pub fn clear(self: *LimitNotice) void {
        self.seen_len = 0;
    }
};

/// Log a worker error: a result given up on, or a handler that failed. It
/// is an error, but logged as a warning under test: the test runner fails
/// any test that logs an error, and the worker tests provoke these on
/// purpose.
pub fn logWorkerError(comptime format: []const u8, args: anytype) void {
    if (@import("builtin").is_test) std.log.warn(format, args) else std.log.err(format, args);
}

/// Operation codes
///
/// Three-layer layout: Infra(0x000-0x0FF), Data(0x100-0x2FF), Compute(0x300-0x3FF)
pub const OpCode = enum(u16) {
    // ── System (0x000 – 0x00F) ──
    ping = 0x000,

    // ── Namespace (0x010 – 0x02F) ──
    namespace_create = 0x010,
    namespace_delete = 0x011,
    namespace_list = 0x012,
    namespace_info = 0x013,
    /// Sent shard to shard, never by a client.
    namespace_ensure = 0x016,

    // ── Cluster (0x030 – 0x04F) ──
    cluster_status = 0x030,
    cluster_members = 0x031,
    cluster_promote = 0x032,
    cluster_remove = 0x033,
    /// Served only on a node's admin socket.
    cluster_repair_skip = 0x034,

    // ── KV + Transactions + Snapshots (0x100 – 0x12F) ──
    kv_put = 0x100,
    kv_get = 0x101,
    kv_mget = 0x102,
    kv_delete = 0x103,
    kv_scan = 0x104,
    kv_history = 0x105,
    // KV extended (atomic counters, JSON ops)
    kv_incr = 0x10B,
    kv_json_get = 0x10C,
    kv_json_set = 0x10D,
    kv_json_del = 0x10E,
    // KV per-shard transactions
    kv_txn_begin = 0x110,
    kv_txn_commit = 0x111,
    kv_txn_rollback = 0x112,
    // KV extended (TTL, exists)
    kv_expire = 0x113,
    kv_exists = 0x115,

    // ── Streams (0x130 – 0x14F) ──
    stream_append = 0x130,
    stream_read = 0x131,
    stream_trim = 0x132,
    stream_info = 0x133,
    stream_list = 0x13B,
    stream_create = 0x13D,
    stream_alter = 0x13F,
    stream_delete = 0x140,

    // ── Stream Consumer Groups (0x150 – 0x16F) ──
    stream_group_create = 0x150,
    stream_group_read = 0x153,
    stream_group_ack = 0x154,
    stream_group_pending = 0x156,
    stream_group_nack = 0x159,
    stream_group_touch = 0x15A,
    stream_group_info = 0x15B,
    stream_group_delete = 0x15C,
    stream_group_list = 0x15D,
    stream_group_members = 0x15E,

    // ── Queues (0x170 – 0x19F) ──
    queue_enqueue = 0x170,
    queue_dlq_list = 0x176,
    queue_stats = 0x17B,
    queue_purge = 0x17F,
    queue_peek = 0x180,
    queue_dequeue = 0x181,
    queue_complete = 0x182,
    queue_fail = 0x183,
    queue_touch = 0x184,
    queue_list = 0x198,

    // ── Time-Series (0x1A0 – 0x1BF) ──
    ts_write = 0x1A0,
    ts_read = 0x1A1,
    ts_query = 0x1A2,
    ts_floql = 0x1A3,
    ts_list = 0x1A4,
    ts_delete = 0x1A5,
    ts_retention = 0x1A6,

    // ── Actions (0x300 – 0x31F) ──
    action_register = 0x300,
    action_invoke = 0x301,
    action_status = 0x302,
    action_list = 0x303,
    action_list_runs = 0x304,
    action_delete = 0x305,
    action_await = 0x30A,
    action_complete = 0x30B,
    action_fail = 0x30C,
    action_touch = 0x30D,
    action_info = 0x30F,

    // ── Workers (0x320 – 0x33F) ──
    worker_register = 0x320,
    worker_heartbeat = 0x321,
    worker_deregister = 0x322,
    worker_list = 0x323,
    worker_info = 0x324,
    worker_drain = 0x325,

    // ── Workflows (0x340 – 0x35F) ──
    workflow_create = 0x340,
    workflow_start = 0x341,
    workflow_signal = 0x342,
    workflow_cancel = 0x343,
    workflow_status = 0x344,
    workflow_history = 0x345,
    workflow_list_runs = 0x346,
    workflow_get_definition = 0x347,
    workflow_disable = 0x348,
    workflow_enable = 0x349,
    workflow_list_definitions = 0x34A,

    // ── Processing (0x360 – 0x37F) ──
    processing_submit = 0x360,
    processing_stop = 0x361,
    processing_cancel = 0x362,
    processing_status = 0x363,
    processing_list = 0x364,
    processing_remove = 0x365,

    _,
};

/// Status codes for responses
pub const StatusCode = enum(u8) {
    ok = 0,
    error_generic = 1,
    not_found = 2,
    bad_request = 3,
    cross_core_transaction = 4,
    no_active_transaction = 5,
    group_locked = 6,
    unauthorized = 7,
    conflict = 8,
    internal_error = 9,
    overloaded = 10,
    rate_limited = 11, // Request rate limit exceeded (WebSocket)
    unavailable = 12,
    /// The write committed but hasn't applied: its shard halted at it or
    /// before it. The message says whether it applies when the shard
    /// resumes. Never retried: resending would write it twice.
    outcome_pending = 13,
    /// The namespace the request names doesn't exist; not_found is a
    /// missing key. Reads, lists and scans in a namespace never created
    /// answer this; a write creates the namespace.
    no_namespace = 14,
    /// The node or shard is at a limit on what it holds; the reason names
    /// which. The limits are built into the server, not settings: retrying
    /// won't clear it until something is deleted (the memory budget: or the
    /// node is given more memory). It never ran.
    limit = 15,

    // The server may send codes this SDK predates; `_` keeps them a value
    // rather than illegal behaviour, and toError maps them to ServerError.
    _,

    /// Get human-readable error message
    pub fn message(self: StatusCode) []const u8 {
        return switch (self) {
            .ok => "OK",
            .error_generic => "Generic error",
            .not_found => "Not found",
            .bad_request => "Bad request",
            .cross_core_transaction => "Cross-core transaction not supported",
            .no_active_transaction => "No active transaction",
            .group_locked => "Consumer group is locked",
            .unauthorized => "Unauthorized",
            .conflict => "Conflict",
            .internal_error => "Internal server error",
            .overloaded => "Server overloaded",
            .rate_limited => "Request rate limit exceeded",
            .unavailable => "Unavailable: no leader or the shard isn't taking writes; retry",
            .outcome_pending => "Committed, not applied: its shard halted; don't resend it unchanged",
            .no_namespace => "No such namespace",
            .limit => "At a limit: delete something first",
            // No buffer to format the code into; Client.lastError has it.
            _ => "Unknown status",
        };
    }

    /// The error a non-ok status surfaces as. The server's message is in the
    /// response body; Client.lastError keeps it.
    pub fn toError(self: StatusCode) FloError {
        return switch (self) {
            .ok => FloError.UnexpectedResponse,
            .not_found => FloError.NotFound,
            .bad_request => FloError.BadRequest,
            .conflict => FloError.Conflict,
            .unauthorized => FloError.Unauthorized,
            .overloaded => FloError.Overloaded,
            .rate_limited => FloError.RateLimited,
            .internal_error => FloError.InternalError,
            .unavailable => FloError.Unavailable,
            .outcome_pending => FloError.OutcomePending,
            .no_namespace => FloError.NoNamespace,
            .limit => FloError.Limit,
            else => FloError.ServerError,
        };
    }
};

/// Option tags for TLV-encoded operation parameters
pub const OptionTag = enum(u8) {
    limit = 0x05, // u32: Maximum number of results for list operations

    // Queue Options (0x10 - 0x1F)
    priority = 0x10, // u8: Message priority (0-255, lower is dequeued first)
    delay_ms = 0x11, // u64: How long before an enqueued message is ready (at most a day)
    count = 0x15, // u32: Number of records to read
    block_ms = 0x17, // u32: Blocking wait for data (0=don't wait, max 300000)

    // Stream Options (0x20 - 0x2F) - StreamID-native ONLY
    // 0x20 reserved
    stream_start = 0x21, // [16]u8: Read records after this StreamID (exclusive)
    stream_end = 0x22, // [16]u8: End StreamID for reads (inclusive)
    stream_tail = 0x23, // void: Flag indicating tail read (start from end of stream)
    partition = 0x24, // u32: Explicit partition index
    partition_key = 0x25, // string: Key for partition routing
    max_age_seconds = 0x26, // u64: Maximum age in seconds for retention
    dry_run = 0x28, // void: Flag to preview what would be deleted without deleting
    force = 0x2C, // void: Flag to delete a stream that still holds records

    // Consumer Group Options (0x30 - 0x3F)
    ack_timeout_ms = 0x30, // u32: A group's lease: a record not acked this long is redelivered (5 s to 12 h)
    max_deliver = 0x31, // u8: A group's attempts: a record is dead once nacked or expired this many times (1 to 255)
    dead = 0x32, // void: A nack's records are dead now
    abandon = 0x34, // void: A nack hands its records back unstarted: ready at once, no failure counted

    // Time-Series Options (0x60 - 0x6F)
    ts_from_ms = 0x60, // i64: Start of time range (inclusive, unix ms)
    ts_to_ms = 0x61, // i64: End of time range (inclusive, 0 = now)
    ts_window_ms = 0x62, // i64: Aggregation window size (ms)
    ts_aggregation = 0x63, // string: Aggregation function name (avg, sum, count, min, max)
    ts_field = 0x64, // string: Field name filter (empty = "value")
    ts_tags = 0x65, // string: Comma-separated tag filters "key=val,key2=val2"
    ts_timestamp = 0x67, // i64: Explicit timestamp for write (0 = server-assigned)
    ts_raw_ttl = 0x68, // string: Raw data TTL (e.g., "7d")
    ts_downsample = 0x69, // string: refused by the server; downsampling isn't supported

    _,
};

// =============================================================================
// Error Types
// =============================================================================

/// Errors that can occur during Flo operations
pub const FloError = error{
    // Connection errors
    NotConnected,
    ConnectionFailed,
    InvalidEndpoint,
    UnexpectedEof,
    /// No bytes moved within the client's timeout (see ClientOptions.timeout_ms).
    Timeout,

    // Protocol errors
    InvalidMagic,
    /// The server was built from another protocol version or op table;
    /// `Client.foreign_server` says which. Upgrade the SDK and the server
    /// together.
    TableMismatch,
    InvalidChecksum,
    PayloadTooLarge,
    BufferTooSmall,
    IncompleteRequest,
    IncompleteResponse,
    IncompletePayload,

    // Validation errors
    NamespaceTooLarge,
    KeyTooLarge,
    ValueTooLarge,
    OptionsBufferTooSmall,
    OptionValueTooLarge,
    /// block_ms / wait_ms over MAX_BLOCK_MS
    BlockTooLong,

    // Server errors
    ServerError,
    NotFound,
    /// The namespace the request names doesn't exist (status no_namespace),
    /// as against a missing key (NotFound). Reads, lists and scans in a
    /// namespace never created return it; a write creates the namespace.
    NoNamespace,
    BadRequest,
    Conflict,
    Unauthorized,
    /// Retryable: the server shed load.
    Overloaded,
    RateLimited,
    /// Not retryable: the write may have committed without being applied,
    /// so resending can apply it twice.
    InternalError,
    /// Retryable: the request reached no leader, its records are still being
    /// read from disk, or the shard stopped taking writes or is offline. An offline shard stays so until an operator
    /// acts; Client.lastError has the server's reason. With reason
    /// shard_halted it isn't retried: the shard waits on a repair.
    Unavailable,
    /// The write committed but hasn't applied, because its shard halted
    /// (status outcome_pending). Never retried: resending would write it
    /// twice. Client.lastError has the reason, ran and message.
    OutcomePending,
    /// A stale read (see `GetResult.stale`) found no such key; it may exist
    /// since. Not the same as absent.
    StaleNotFound,
    /// An action complete, fail or touch for a delivery that has moved on
    /// (status conflict, reason stale_report); Client.lastError's message
    /// says how. Not resent: it would be refused again.
    StaleReport,
    /// The node or shard is at a limit on what it holds (status limit);
    /// the reason (`Client.lastError`) names which: memory_budget,
    /// too_many_actions (counted per shard), too_many_workflow_definitions
    /// or too_many_workflow_runs, and its message says more. The limits are
    /// built into the server, not settings: retrying won't clear it until
    /// something is deleted (or, for the memory budget, the node is given
    /// more memory), so it is never retried. Not permanent. It never ran.
    Limit,
    /// A group read took nothing new: the group's consumers hold too many
    /// records they haven't acked, or it holds dead ones (status
    /// overloaded, reason group_held_full). Reading again won't help until
    /// they ack or nack, so it is never retried; back off, as for `Limit`.
    GroupHeldFull,
    UnexpectedResponse,

    // Transaction errors
    TxnUnsupportedOp,
    TxnFinished,

    // Memory errors
    OutOfMemory,
};

// =============================================================================
// Result Types
// =============================================================================

/// One page of a KV scan: the key names, without values, and the cursor
/// for the next page (null on the last). Free with `deinit`.
pub const ScanResult = struct {
    keys: [][]const u8,
    cursor: ?[]const u8,
    allocator: std.mem.Allocator,
    /// A stale read (see `GetResult.stale`).
    stale: bool = false,

    pub fn deinit(self: *ScanResult) void {
        for (self.keys) |k| self.allocator.free(k);
        self.allocator.free(self.keys);
        if (self.cursor) |c| self.allocator.free(c);
    }
};

/// One page of a key's versions, newest first. Free with `deinit`.
pub const HistoryResult = struct {
    versions: []VersionEntry,
    /// Older kept versions follow: ask again with `before_version` set to
    /// the last version here.
    more: bool,
    /// A stale read (see `GetResult.stale`); a missing key is
    /// missing as of the halt.
    stale: bool = false,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HistoryResult) void {
        for (self.versions) |*v| v.deinit(self.allocator);
        self.allocator.free(self.versions);
    }
};

/// Whether a key exists, from `KV.exists`.
pub const ExistsResult = struct {
    exists: bool,
    /// A stale read (see `GetResult.stale`).
    stale: bool = false,
};

/// KV version entry from history
pub const VersionEntry = struct {
    version: u64,
    /// When the version was written, in Unix milliseconds.
    at_ms: i64,
    /// Whether this version is a delete; its value is empty.
    deleted: bool,
    value: []const u8,

    pub fn deinit(self: *VersionEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }
};

/// Result of a successful KV put.
///
/// `version` is the new version assigned by the server, suitable for CAS on
/// the next write via `PutOptions.cas_version`.
pub const PutResult = struct {
    version: u64,
};

/// Result of a KV incr: the counter's new value and the key's new version.
pub const IncrResult = struct {
    value: i64,
    version: u64,
};

/// Result of a successful KV transaction commit.
///
/// `commit_index` is the Raft log index of the committed batch and
/// `op_count` is the number of buffered operations applied atomically.
pub const KVCommitResult = struct {
    commit_index: u64,
    op_count: u16,
};

/// Result of a KV get that found a key.
///
/// `KV.get` returns `null` when the key is missing; callers must check before
/// dereferencing. Caller owns `value` and must free it with `allocator.free`.
pub const GetResult = struct {
    value: []const u8,
    version: u64,
    /// When the key's TTL runs out, in Unix milliseconds; null when it has
    /// none. Always null from `KV.jsonGet`.
    expires_at_ms: ?i64 = null,
    /// A stale read: from a halted shard, its state just before the entry it
    /// halted at, or from a node whose log reads are blocked, its state as
    /// last applied. Either way it lacks what was written since. The read
    /// succeeded; it is not an error.
    stale: bool = false,

    pub fn deinit(self: *GetResult, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }
};

/// One entry in a `KV.mget` response. `found = false` indicates the key did
/// not exist; in that case `value` is empty and `version` is 0. Memory for
/// `key` and `value` is owned by the parent `MGetResult`.
pub const MGetEntry = struct {
    key: []const u8,
    value: []const u8,
    version: u64,
    found: bool,
    /// A stale read (see `GetResult.stale`); a missing key is
    /// missing as of the halt.
    stale: bool = false,
};

/// Result of a `KV.mget` call. Owns the backing memory for all entries; free
/// with `deinit`.
pub const MGetResult = struct {
    entries: []MGetEntry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MGetResult) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        self.allocator.free(self.entries);
    }
};

/// A dequeued message, leased to its consumer until a complete, a fail or
/// the lease running out.
pub const Message = struct {
    seq: u64,
    /// Lower is taken first.
    priority: u32,
    /// The message's deliveries, this one included. A report names it back.
    deliveries: u32,
    enqueued_at_ms: i64,
    payload: []const u8,
};

/// The delivery a dequeue made: a complete, fail or touch names it back.
pub const QueueLease = struct {
    term: u64,
    index: u64,
};

/// One dequeue's messages and their lease. Free with `deinit`.
pub const DequeueResult = struct {
    messages: []Message,
    lease: QueueLease,
    /// When the lease runs out without a touch, in Unix milliseconds.
    expires_at_ms: i64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DequeueResult) void {
        for (self.messages) |m| self.allocator.free(m.payload);
        self.allocator.free(self.messages);
    }
};

/// Why a complete, fail or touch left a message as it was.
pub const QueueRefusalWhy = enum(u8) {
    /// Completed already, or not in this queue. For a complete, it's done.
    gone = 0,
    /// Delivered again since this delivery.
    delivered_again = 1,
    /// Another consumer holds it.
    other_holder = 2,
    /// Its lease ran out; it is ready again.
    expired = 3,
    /// Failed back since.
    released = 4,
    /// Nobody holds it.
    not_held = 5,
    _,
};

/// A message a report left as it was.
pub const QueueRefusal = struct {
    seq: u64,
    why: QueueRefusalWhy,
    reason: []const u8,
};

/// What a complete, fail or touch did: how many messages it applied to,
/// and those it didn't, each with why. Free with `deinit`.
pub const QueueReport = struct {
    applied: u32,
    refused: []QueueRefusal,
    /// For a touch: when the lease runs out without another, in Unix
    /// milliseconds. 0 for a complete or fail.
    expires_at_ms: i64 = 0,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *QueueReport) void {
        for (self.refused) |r| self.allocator.free(r.reason);
        self.allocator.free(self.refused);
    }
};

// =============================================================================
// Option Types
// =============================================================================

/// Options for KV get operations
pub const GetOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Wait up to this long for what `wait_for` names (0 = don't wait, max 300000)
    wait_ms: u64 = 0,
    /// The key to exist (the default), or its next version
    wait_for: WaitFor = .exists,
};

/// Options for KV put operations
pub const PutOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Expire the key after this many milliseconds (0 = no expiration)
    ttl_ms: ?u64 = null,
    /// When the write may happen
    condition: Condition = .always,
    /// The key's version the write requires; 0 means it doesn't exist
    cas_version: ?u64 = null,
};

/// Options for KV delete operations
pub const DeleteOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// The key's version the delete requires; another version returns
    /// `FloError.Conflict`. Use this for race-free "only the owner deletes".
    cas_version: ?u64 = null,
};

/// Options for KV scan operations
pub const ScanOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// The cursor the previous page returned; null for the first page.
    cursor: ?[]const u8 = null,
    /// Names per page, 1 to 1024.
    limit: u32 = MAX_SCAN,
};

/// Options for KV history operations
pub const HistoryOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Versions to return, newest first, 1 to 65.
    limit: u32 = 10,
    /// Only versions older than this one; null to start from the newest.
    before_version: ?u64 = null,
};

/// Options for KV incr operations
pub const KVIncrOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Negative values decrement.
    delta: i64 = 1,
};

/// Options for KV expire operations
pub const KVExpireOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// The key's version the expire requires; use this for race-free lease
    /// renewal.
    cas_version: ?u64 = null,
};

/// Options for KV exists operations
pub const KVExistsOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// Options for KV JSON operations
pub const KVJsonOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// Options for KV mget operations
pub const KVMGetOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// Options for a delete or expire inside a KV transaction
pub const KVTxnWriteOptions = struct {
    /// The key's version the write requires; another version fails the
    /// commit with `FloError.Conflict`.
    cas_version: ?u64 = null,
};

/// Options for KV transaction begin
pub const KVBeginOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// Options for queue enqueue operations
pub const EnqueueOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Lower is dequeued first; equal priorities go in the order they
    /// became ready.
    priority: u8 = 0,
    /// How long before the message is ready, at most a day.
    delay_ms: u64 = 0,
};

/// The most messages one dequeue takes, and one report names.
pub const MAX_QUEUE_BATCH: usize = 100;
/// The longest queue consumer name.
pub const MAX_QUEUE_CONSUMER: usize = 4082;
/// The shortest and longest lease a dequeue may ask for.
pub const MIN_QUEUE_LEASE_MS: u64 = 5_000;
pub const MAX_QUEUE_LEASE_MS: u64 = 43_200_000;
/// The longest error a queue fail carries.
pub const MAX_QUEUE_ERROR: usize = 1024;

/// Options for queue dequeue operations
pub const DequeueOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Who holds the messages; reports must name the same consumer.
    consumer: []const u8 = "",
    /// How long the messages are held without a touch, 5000 to 43200000
    /// ms; null for the server's 30000.
    lease_ms: ?u64 = null,
    /// Block waiting for messages, in ms (0 = don't wait, max 300000)
    block_ms: u32 = 0,
    /// Complete them as they're taken, a one-shot consume; if the leader
    /// fails in between, they come back once their lease runs out. The
    /// answer comes once the complete applies. Off, they are leased.
    ack: bool = false,
};

/// Options for queue complete and touch
pub const QueueReportOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// The consumer the messages were dequeued as.
    consumer: []const u8 = "",
};

/// Options for queue fail
pub const QueueFailOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// The consumer the messages were dequeued as.
    consumer: []const u8 = "",
    /// How long before they are ready again, at most a day.
    delay_ms: u64 = 0,
    /// Move them to the DLQ now, attempts left or not.
    dead: bool = false,
    /// Why they failed, at most 1024 bytes.
    error_message: []const u8 = "",
};

/// Options for queue purge
pub const PurgeOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// The most dead letters one DLQ list page holds.
pub const MAX_DLQ_PAGE: u32 = 100;

/// Options for DLQ list operations
pub const DlqListOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Dead letters per page, 1 to 100.
    limit: u32 = MAX_DLQ_PAGE,
    /// The previous page's `last_seq`; null for the first page.
    after: ?u64 = null,
};

/// A message moved to a queue's dead letter queue.
pub const DeadLetter = struct {
    seq: u64,
    /// The payload's whole length; `payload` holds at most 4 KiB of it.
    size: u32,
    payload: []const u8,
    enqueued_at_ms: i64,
    /// Times it was delivered.
    deliveries: u32,
    priority: u8,
    /// When it was moved to the DLQ, in Unix milliseconds.
    moved_at_ms: i64,
};

/// One page of a queue's dead letters, oldest first. Free with `deinit`.
pub const DlqPage = struct {
    letters: []DeadLetter,
    /// Dead letters the queue holds in all.
    total: u64,
    /// More follow: ask again with `after` set to `last_seq`.
    has_more: bool,
    /// The seq of the page's last dead letter.
    last_seq: u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DlqPage) void {
        for (self.letters) |l| self.allocator.free(l.payload);
        self.allocator.free(self.letters);
    }
};

/// The most messages one queue peek shows.
pub const MAX_PEEK: u32 = 100;

/// Options for queue peek operations
pub const PeekOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// A ready message as a peek shows it, without taking it.
pub const PeekedMessage = struct {
    seq: u64,
    priority: u32,
    /// Times it was delivered.
    deliveries: u32,
    enqueued_at_ms: i64,
    /// The payload's whole length; `payload` holds at most 4 KiB of it.
    size: u32,
    payload: []const u8,
};

/// A queue's next ready messages, in the order a dequeue takes them. Free
/// with `deinit`.
pub const PeekResult = struct {
    messages: []PeekedMessage,
    /// More may follow: the limit, the answer's room or a run of taken
    /// messages stopped it.
    more: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PeekResult) void {
        for (self.messages) |m| self.allocator.free(m.payload);
        self.allocator.free(self.messages);
    }
};

// =============================================================================
// Stream Types
// =============================================================================

/// StreamID represents a unique position in a stream (timestamp_ms + sequence).
/// The StreamID format is: [timestamp_ms: u64 BE][sequence: u64 BE] = 16 bytes total.
pub const StreamID = struct {
    timestamp_ms: u64 = 0,
    sequence: u64 = 0,

    /// Serialize the StreamID to 16 bytes (big-endian for lexicographic sorting).
    pub fn toBytes(self: StreamID) [16]u8 {
        var buf: [16]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], self.timestamp_ms, .big);
        std.mem.writeInt(u64, buf[8..16], self.sequence, .big);
        return buf;
    }

    /// Parse a StreamID from 16 bytes (big-endian).
    pub fn fromBytes(data: *const [16]u8) StreamID {
        return .{
            .timestamp_ms = std.mem.readInt(u64, data[0..8], .big),
            .sequence = std.mem.readInt(u64, data[8..16], .big),
        };
    }

    /// Create a StreamID with just a sequence number.
    /// Used for backwards compatibility with offset-based reads.
    pub fn fromSequence(seq: u64) StreamID {
        return .{ .timestamp_ms = 0, .sequence = seq };
    }
};

/// Where a stream record was read from, as the server's op table has it. A
/// tier this SDK predates is kept as its number (`_`), not refused.
pub const StorageTier = enum(u8) {
    /// The hot ring of recent appends.
    hot = 0,
    /// The warm store of payload copies.
    warm = 1,
    /// The durable log: a sealed segment, or the segment writer's buffer.
    disk = 2,
    _,
};

/// A single stream record
pub const StreamRecord = struct {
    id: StreamID = .{},
    tier: StorageTier = .hot,
    stream: []const u8 = "",
    payload: []const u8,
    headers: []const Header = &.{},
    /// From a group read: the record's deliveries, this one included. An
    /// ack, nack or touch names it back. 0 from a plain read.
    deliveries: u32 = 0,

    pub fn deinit(self: *StreamRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        if (self.stream.len > 0) allocator.free(self.stream);
        for (self.headers) |h| {
            allocator.free(h.key);
            allocator.free(h.value);
        }
        allocator.free(self.headers);
    }
};

/// Result of a stream read operation
pub const StreamReadResult = struct {
    records: []StreamRecord,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *StreamReadResult) void {
        for (self.records) |*r| {
            r.deinit(self.allocator);
        }
        self.allocator.free(self.records);
    }
};

/// Result of a stream append operation
pub const StreamAppendResult = struct {
    id: StreamID,
};

/// Stream info/metadata. On an empty stream the ids are zero.
pub const StreamInfo = struct {
    first_id: StreamID,
    last_id: StreamID,
    count: u64,
    bytes: u64,
    partition_count: u32 = 1,
};

/// A header stored with a stream record.
pub const Header = struct {
    key: []const u8,
    value: []const u8,
};

/// Options for stream append operations
pub const StreamAppendOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Headers stored with the record, at most 65,535, each key and value
    /// at most 65,535 bytes.
    headers: []const Header = &.{},
};

/// Options for stream read operations
pub const StreamReadOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Read records after this StreamID (exclusive)
    start: ?StreamID = null,
    /// End StreamID for reads (inclusive)
    end: ?StreamID = null,
    /// Start from end of stream (tail mode, mutually exclusive with start)
    tail: bool = false,
    /// Explicit partition index
    partition: ?u32 = null,
    /// Maximum number of records to read
    count: ?u32 = null,
    /// Block waiting for new records, in ms (null or 0 = don't wait, max 300000)
    block_ms: ?u32 = null,
};

/// Options for stream trim operations
pub const StreamTrimOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Remove records up to and including this id
    before: ?StreamID = null,
    /// Keep only the newest N records (> 0)
    max_len: ?u64 = null,
    /// Remove records older than this, in seconds (> 0)
    max_age_seconds: ?u64 = null,
    /// Report what would be removed, removing nothing
    dry_run: bool = false,
};

/// What a trim removed, or with `dry_run` would remove.
pub const StreamTrimResult = struct {
    /// Records removed
    removed: u64,
    /// Sequence of the first record left; meaningful only when records remain
    first_seq: u64,
};

/// Options for stream info operations
pub const StreamInfoOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// Options for stream delete operations
pub const StreamDeleteOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Delete the stream even if it still holds records
    force: bool = false,
};

/// The longest consumer group name.
pub const MAX_GROUP_NAME: usize = 256;
/// The longest consumer name a group read or report takes.
pub const MAX_GROUP_CONSUMER: usize = 4096;
/// The most records one group read leases, and one report names.
pub const MAX_GROUP_BATCH: u32 = 100;
/// A group's lease (ack timeout) bounds: 5 s to 12 h.
pub const MIN_GROUP_LEASE_MS: u32 = 5_000;
pub const MAX_GROUP_LEASE_MS: u32 = 43_200_000;

/// Options for consumer group create
pub const StreamGroupCreateOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// The group's lease, 5000 to 43200000 ms: a record not acked or
    /// touched this long after its read is ready again. Null for the
    /// server's 30000.
    ack_timeout_ms: ?u32 = null,
    /// The group's attempts, 1 to 255: a record nacked or expired this many
    /// times is dead. Null for the server's 5.
    max_deliver: ?u8 = null,
};

/// Options for consumer group delete and info
pub const StreamGroupOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// Options for consumer group read
pub const StreamGroupReadOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Most records to lease, 1 to 100; null for 100.
    count: ?u32 = null,
    /// Block waiting for records, in ms (null or 0 = don't wait, max 300000)
    block_ms: ?u32 = null,
};

/// Options for consumer group ack and touch
pub const StreamGroupReportOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// The consumer the records were read as.
    consumer: []const u8 = "",
};

/// Options for consumer group nack
pub const StreamGroupNackOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// The consumer the records were read as.
    consumer: []const u8 = "",
    /// How long before they are ready again, at most a day.
    delay_ms: u64 = 0,
    /// Dead now, attempts left or not.
    dead: bool = false,
    /// Why they failed, at most `MAX_NACK_ERROR` bytes.
    error_message: []const u8 = "",
    /// Hand them back unstarted: ready at once, the delivery counted but
    /// no failure, so an abandoned record never dead-letters. Only for
    /// records the worker never started (it is stopping); a record that
    /// failed is nacked without it, or a poison record cycles forever.
    /// Takes no `delay_ms`, `dead` or `error_message`.
    abandon: bool = false,
};

/// The longest error a group nack carries.
pub const MAX_NACK_ERROR: usize = 1024;

/// The delivery a group read made: an ack, nack or touch names it back.
pub const GroupLease = struct {
    term: u64,
    index: u64,
};

/// One group read's records and their lease. Free with `deinit`.
pub const GroupReadResult = struct {
    records: []StreamRecord,
    lease: GroupLease,
    /// When the lease runs out without a touch, in Unix milliseconds; 0
    /// when the read leased nothing.
    expires_at_ms: i64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GroupReadResult) void {
        for (self.records) |*r| r.deinit(self.allocator);
        self.allocator.free(self.records);
    }
};

/// Why an ack, nack or touch left a record as it was.
pub const GroupRefusalWhy = enum(u8) {
    /// Not in the group: acked already, or never read. For an ack, it's done.
    gone = 0,
    /// Read again since this delivery.
    delivered_again = 1,
    /// Another consumer holds it.
    other_holder = 2,
    /// Its lease ran out; it is ready again, or dead.
    expired = 3,
    /// Nacked since; it is ready again, or dead.
    released = 4,
    /// Nobody holds it.
    not_held = 5,
    _,
};

/// A record a report left as it was.
pub const GroupRefusal = struct {
    id: StreamID,
    why: GroupRefusalWhy,
};

/// What an ack, nack or touch did: how many records it applied to, and
/// those it didn't, each with why. A report for a delivery that has moved
/// on is answered this way, applying nothing, not as an error. Free with
/// `deinit`.
pub const GroupReport = struct {
    applied: u32,
    refused: []GroupRefusal,
    /// For a touch: when the lease runs out without another, in Unix
    /// milliseconds. 0 for an ack or nack.
    expires_at_ms: i64 = 0,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GroupReport) void {
        self.allocator.free(self.refused);
    }
};

/// A consumer group's records by state.
pub const StreamGroupInfo = struct {
    /// Ready and leased.
    pending: u64,
    /// Consumers holding records now.
    holders: u32,
    created_at_ms: i64,
    ready: u64,
    leased: u64,
    dead: u64,
    /// Records at or below a trim, not yet cleaned out of the group.
    trimmed_pending: u64,
};

/// Options for listing a stream's consumer groups or a group's members
pub const StreamGroupListOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// A consumer group as the stream's group list shows it.
pub const StreamGroupSummary = struct {
    name: []const u8,
    /// Consumers holding its records now.
    members: u32,
    /// Records ready or leased.
    pending: u64,
    created_at_ms: i64,
    ack_timeout_ms: u32,
    max_deliver: u8,
    /// The last stream record it read: its timestamp, 0 if none.
    last_delivered_ms: u64,
    last_delivered_seq: u64,
};

/// A stream's consumer groups. Free with `deinit`.
pub const StreamGroupList = struct {
    groups: []StreamGroupSummary,
    /// The stream has more groups than the answer holds.
    more: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *StreamGroupList) void {
        for (self.groups) |g| self.allocator.free(g.name);
        self.allocator.free(self.groups);
    }
};

/// The server reports every member active.
pub const StreamGroupMemberState = enum(u8) {
    active = 0,
    leaving = 1,
};

/// A consumer holding a group's records.
pub const StreamGroupMember = struct {
    id: []const u8,
    state: StreamGroupMemberState,
    /// Records it holds.
    pending: u32,
    /// When it took the oldest it holds.
    joined_at_ms: i64,
    /// When it last took one.
    last_active_ms: ?i64,
};

/// A consumer group's members. Free with `deinit`.
pub const StreamGroupMembers = struct {
    members: []StreamGroupMember,
    /// The group has more members than the answer holds.
    more: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *StreamGroupMembers) void {
        for (self.members) |m| self.allocator.free(m.id);
        self.allocator.free(self.members);
    }
};

// =============================================================================
// Action/Worker Types
// =============================================================================

/// Action type
pub const ActionType = enum(u8) {
    /// User-defined action (external worker processes tasks)
    user = 0,
};

/// Run status for action invocations
pub const RunStatus = enum(u8) {
    pending = 0,
    running = 1,
    completed = 2,
    failed = 3,
    cancelled = 4,
    timed_out = 5,
};

/// The delivery a report names: a complete, fail or touch echoes every
/// field of the task it reports on, and is refused as stale (reason
/// stale_report) once the run has moved on to another delivery.
pub const Delivery = struct {
    run_id: []const u8,
    action: []const u8,
    /// The run's deliveries, this one included.
    deliveries: u32,
    /// The term and log index the delivery was made at.
    term: u64,
    index: u64,
};

/// A task from action.await: one delivery of a run, held by the worker
/// that awaited it for `lease_ms` without a touch.
pub const TaskAssignment = struct {
    run_id: []const u8,
    namespace: []const u8,
    deliveries: u32,
    term: u64,
    index: u64,
    action: []const u8,
    /// When the run was invoked, in Unix milliseconds.
    created_at: i64,
    /// The run's failures so far, plus one. An abandoned delivery counts no
    /// failure, so the next one has the same attempt.
    attempt: u32,
    lease_ms: u64,
    caller_run_id: ?[]const u8 = null,
    caller_workflow_name: ?[]const u8 = null,
    payload: []const u8,
    allocator: std.mem.Allocator,

    pub fn delivery(self: *const TaskAssignment) Delivery {
        return .{ .run_id = self.run_id, .action = self.action, .deliveries = self.deliveries, .term = self.term, .index = self.index };
    }

    pub fn deinit(self: *TaskAssignment) void {
        self.allocator.free(self.run_id);
        self.allocator.free(self.namespace);
        self.allocator.free(self.action);
        self.allocator.free(self.payload);
        if (self.caller_run_id) |v| self.allocator.free(v);
        if (self.caller_workflow_name) |v| self.allocator.free(v);
    }
};

/// An action run's status. Times are ms since the epoch; `attempt` counts
/// from 1 once a worker has taken the run. `output` is a completed run's
/// result, and `error_message` the last failure's message. `worker_id` is
/// the worker holding the run, or last holding it; null until one takes it.
/// Only the leader knows a take at once: another node may answer null, or
/// an earlier worker, until the run's next update reaches it. `outcome` is
/// the outcome a completed run's worker named; null for success.
pub const ActionRunStatus = struct {
    run_id: []const u8,
    status: RunStatus,
    created_at: i64,
    started_at: ?i64,
    completed_at: ?i64,
    attempt: u32,
    output: ?[]const u8,
    error_message: ?[]const u8,
    worker_id: ?[]const u8,
    outcome: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ActionRunStatus) void {
        self.allocator.free(self.run_id);
        if (self.output) |o| self.allocator.free(o);
        if (self.error_message) |e| self.allocator.free(e);
        if (self.worker_id) |w| self.allocator.free(w);
        if (self.outcome) |o| self.allocator.free(o);
    }
};

/// An action's definition, its runs by status and how long completed runs
/// took, from action.info. The counts other than `ready`, and the latency,
/// are null when `too_many_runs` is set. Free with `deinit`.
pub const ActionInfo = struct {
    owner: []const u8,
    /// Counts registrations.
    version: u32,
    /// The lease a worker holds a run for.
    timeout_ms: u64,
    max_attempts: u32,
    created_at_ms: i64,
    /// Runs waiting for a worker, counted up to 100,000.
    ready: u64,
    /// More runs wait than were counted.
    ready_capped: bool,
    /// The action's shard holds more than 10,000 of the namespace's runs.
    too_many_runs: bool,
    running: ?u64,
    completed: ?u64,
    failed: ?u64,
    timed_out: ?u64,
    latency_count: ?u64,
    latency_avg_ms: ?u64,
    latency_p50_ms: ?u64,
    latency_p95_ms: ?u64,
    latency_max_ms: ?u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ActionInfo) void {
        self.allocator.free(self.owner);
    }
};

/// Result of an action invocation
pub const ActionInvokeResult = struct {
    run_id: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ActionInvokeResult) void {
        self.allocator.free(self.run_id);
    }
};

/// Options for action registration
/// Registering an action replaces its settings: the last registration wins.
pub const ActionRegisterOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// The lease: how long a run may go without its worker completing,
    /// failing or touching it before it's taken back. The server takes 5000
    /// to 43200000 ms; 0, the default, is its default of 300000.
    timeout_ms: u32 = 0,
    /// Attempts in all, counting the first.
    max_retries: u32 = 3,
    /// Who owns the action, at most 256 bytes; more is refused with
    /// ValueTooLarge before sending.
    owner: []const u8 = "",
};

/// Options for action invocation
pub const ActionInvokeOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Labels a worker must have to receive the run, as a JSON object string
    /// such as `{"gpu":true}`. A worker gets the run only if the JSON object
    /// it registered as metadata contains every key with the same value.
    labels: ?[]const u8 = null,
};

/// Options for action status query
pub const ActionStatusOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

pub const ActionListOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Only names starting with this; "" for all.
    prefix: []const u8 = "",
    /// The cursor the previous page returned; null for the first page.
    cursor: ?[]const u8 = null,
    /// Names per page; 0 is the server's default.
    limit: u32 = 0,
};

/// A registered action as action.list shows it.
pub const ActionListEntry = struct {
    name: []const u8,
    /// Counts registrations.
    version: u32,
    owner: []const u8,
    /// The lease a worker holds a run for.
    timeout_ms: u64,
    max_attempts: u32,
    created_at_ms: i64,
};

/// A page of a namespace's registered actions.
pub const ActionListPage = struct {
    actions: []ActionListEntry,
    has_more: bool,
    /// Pass as `ActionListOptions.cursor` for the next page; null on the
    /// last page.
    cursor: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ActionListPage) void {
        for (self.actions) |a| {
            self.allocator.free(a.name);
            self.allocator.free(a.owner);
        }
        self.allocator.free(self.actions);
        if (self.cursor) |c| self.allocator.free(c);
    }
};

/// Worker type
pub const WorkerType = enum(u8) {
    /// Processes action tasks
    action = 0,
    /// Processes stream records
    stream = 1,
};

/// Worker health status
pub const WorkerStatus = enum(u8) {
    /// Actively processing
    active = 0,
    /// Connected, no current tasks
    idle = 1,
    /// Finishing current tasks, accepting no new ones
    draining = 2,
    /// Missed heartbeats
    unhealthy = 3,
};

/// Identifies what a registered process does
pub const ProcessKind = enum(u8) {
    /// Handles an action
    action = 0,
    /// Consumes a stream
    stream_consumer = 1,
};

/// Describes a single process to register on a worker
pub const ProcessEntry = struct {
    name: []const u8,
    kind: ProcessKind = .action,
};

/// Options for worker registration
/// The most workers one worker.list page holds.
pub const MAX_WORKER_LIST: u32 = 1024;

/// One worker as worker.list shows it.
pub const WorkerInfo = struct {
    id: []const u8,
    worker_type: WorkerType,
    status: WorkerStatus,
    current_load: u32,
    max_concurrency: u32,
    tasks_completed: u64,
    tasks_failed: u64,
    registered_at_ms: i64,
    last_heartbeat_ms: i64,
    machine_id: ?[]const u8,
};

/// A page of a namespace's workers, in id order.
pub const WorkerListPage = struct {
    workers: []WorkerInfo,
    /// The last id on the page, to ask for the next one with; null on the
    /// last page.
    cursor: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WorkerListPage) void {
        for (self.workers) |w| {
            self.allocator.free(w.id);
            if (w.machine_id) |m| self.allocator.free(m);
        }
        self.allocator.free(self.workers);
        if (self.cursor) |c| self.allocator.free(c);
    }
};

/// A process on a worker, as registered, with its counts.
pub const WorkerProcess = struct {
    name: []const u8,
    kind: ProcessKind,
    run_count: u64,
    fail_count: u64,
    /// When it last ran, in Unix milliseconds.
    last_run_at_ms: i64,
};

/// One worker's record, from worker.info: its row as worker.list shows it,
/// the metadata it registered with, as given, and its processes. Free with
/// `deinit`.
pub const WorkerDetails = struct {
    worker: WorkerInfo,
    metadata: ?[]const u8,
    processes: []WorkerProcess,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WorkerDetails) void {
        self.allocator.free(self.worker.id);
        if (self.worker.machine_id) |m| self.allocator.free(m);
        if (self.metadata) |m| self.allocator.free(m);
        for (self.processes) |p| self.allocator.free(p.name);
        self.allocator.free(self.processes);
    }
};

pub const WorkerInfoOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

pub const WorkerListOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// The cursor the previous page returned; null for the first page.
    cursor: ?[]const u8 = null,
    /// Workers per page, 1 to 1024.
    limit: u32 = MAX_WORKER_LIST,
    /// Only workers that run this action; null for every worker.
    action: ?[]const u8 = null,
};

pub const WorkerRegisterOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Worker type (action or stream)
    worker_type: WorkerType = .action,
    /// Maximum concurrent tasks (default 10)
    max_concurrency: u32 = 10,
    /// Actions/streams this worker handles
    processes: ?[]const ProcessEntry = null,
    /// Optional JSON metadata
    metadata: ?[]const u8 = null,
    /// Optional machine/host identifier
    machine_id: ?[]const u8 = null,
};

/// Options for worker heartbeat
pub const WorkerHeartbeatOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// Options for worker deregistration
pub const WorkerDeregisterOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// Options for draining a worker
pub const WorkerDrainOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// The most actions one await names.
pub const MAX_AWAIT_ACTIONS: usize = 64;
/// The longest action name a task or report carries.
pub const MAX_ACTION_NAME: usize = 256;
/// The longest await request key.
pub const MAX_REQUEST_KEY: usize = 64;
/// The longest result a complete carries, and error a fail carries.
pub const MAX_REPORT_TEXT: usize = 65_535;
/// The longest delay a fail may ask for: a day.
pub const MAX_FAIL_DELAY_MS: u64 = 86_400_000;

/// Options for worker await task
pub const WorkerAwaitOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Block waiting for task (0 = don't wait, max 300000)
    block_ms: u32 = DEFAULT_WORKER_BLOCK_MS,
    /// Retrying with the same key gets the task the first try got, so an
    /// await whose answer was lost can be sent again without leaving a run
    /// held by no one. At most 64 bytes.
    request_key: ?[]const u8 = null,
};

/// Options for worker complete task
pub const WorkerCompleteOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Named outcome for workflow routing; "" is success.
    outcome: []const u8 = "",
};

/// Options for worker fail task
pub const WorkerFailOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Run it again while attempts are left; false fails the run now.
    retry: bool = true,
    /// Hand it back untried: no failure is counted, so the next delivery
    /// has the same attempt.
    abandoned: bool = false,
    /// How long before it is ready again, at most a day.
    delay_ms: u64 = 0,
};

/// Options for worker touch (keep a task's lease)
pub const WorkerTouchOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

// =============================================================================
// Action Result
// =============================================================================

/// Result of an action handler with optional named outcome.
/// Return this from an action handler to route workflows by outcome.
pub const ActionResult = struct {
    /// Named outcome for workflow routing (e.g. "approved", "rejected")
    outcome: []const u8,
    /// Result data bytes
    data: []const u8,
    /// Whether `data` was allocated and should be freed
    owned: bool = false,
};

// =============================================================================
// Workflow Types
// =============================================================================

pub const WorkflowCreateOptions = struct {
    namespace: ?[]const u8 = null,
};

pub const WorkflowGetDefinitionOptions = struct {
    namespace: ?[]const u8 = null,
    version: ?[]const u8 = null,
};

pub const WorkflowStartOptions = struct {
    namespace: ?[]const u8 = null,
    idempotency_key: ?[]const u8 = null,
    run_id: ?[]const u8 = null,
    version: ?[]const u8 = null,
};

pub const WorkflowStatusOptions = struct {
    namespace: ?[]const u8 = null,
};

pub const WorkflowStatusResult = struct {
    run_id: []const u8,
    workflow: []const u8,
    version: []const u8,
    status: []const u8,
    current_step: []const u8,
    input: []const u8,
    created_at: i64,
    started_at: ?i64 = null,
    completed_at: ?i64 = null,
    wait_signal: ?[]const u8 = null,

    /// Free all allocated fields.
    pub fn deinit(self: *const WorkflowStatusResult, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        allocator.free(self.workflow);
        allocator.free(self.version);
        allocator.free(self.status);
        allocator.free(self.current_step);
        allocator.free(self.input);
        if (self.wait_signal) |ws| allocator.free(ws);
    }
};

pub const WorkflowSignalOptions = struct {
    namespace: ?[]const u8 = null,
};

pub const WorkflowCancelOptions = struct {
    namespace: ?[]const u8 = null,
};

pub const WorkflowHistoryOptions = struct {
    namespace: ?[]const u8 = null,
    limit: u32 = 100,
};

pub const WorkflowListRunsOptions = struct {
    namespace: ?[]const u8 = null,
    /// One workflow's runs; null for every workflow's.
    workflow_name: ?[]const u8 = null,
    /// Only runs in this status ("running", "completed", ...); null for any.
    status: ?[]const u8 = null,
    /// Case-insensitive text a run must match; null for no search.
    search: ?[]const u8 = null,
    /// The previous page's cursor; null for the first page.
    cursor: ?[]const u8 = null,
    /// 0 asks for the server's default (100); it holds a page to 1024.
    limit: u32 = 100,
};

pub const WorkflowRunEntry = struct {
    run_id: []const u8,
    workflow: []const u8,
    status: []const u8,
    created_at: i64,

    pub fn deinit(self: *WorkflowRunEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        allocator.free(self.workflow);
        allocator.free(self.status);
    }
};

/// One page of workflow runs, newest first. A page can hold fewer than
/// `limit` runs while `has_more` is set: keep asking until it is clear.
pub const WorkflowListRunsResult = struct {
    runs: []WorkflowRunEntry,
    has_more: bool,
    /// Pass as `WorkflowListRunsOptions.cursor` for the next page; null on the last page.
    cursor: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WorkflowListRunsResult) void {
        for (self.runs) |*entry| entry.deinit(self.allocator);
        self.allocator.free(self.runs);
        if (self.cursor) |c| self.allocator.free(c);
    }
};

pub const WorkflowListDefinitionsOptions = struct {
    namespace: ?[]const u8 = null,
    limit: u32 = 100,
    cursor: ?[]const u8 = null,
};

pub const WorkflowDefinitionEntry = struct {
    name: []const u8,
    version: []const u8,
    created_at: i64,
    /// Whether new runs may start; false once disabled.
    enabled: bool,

    pub fn deinit(self: *WorkflowDefinitionEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
    }
};

/// One page of workflow definitions. A page can hold fewer than `limit`
/// definitions while `has_more` is set: keep asking until it is clear.
pub const WorkflowListDefinitionsResult = struct {
    definitions: []WorkflowDefinitionEntry,
    has_more: bool,
    /// Pass as `WorkflowListDefinitionsOptions.cursor` for the next page; null on the last page.
    cursor: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WorkflowListDefinitionsResult) void {
        for (self.definitions) |*entry| entry.deinit(self.allocator);
        self.allocator.free(self.definitions);
        if (self.cursor) |c| self.allocator.free(c);
    }
};

pub const WorkflowDisableOptions = struct {
    namespace: ?[]const u8 = null,
};

pub const WorkflowEnableOptions = struct {
    namespace: ?[]const u8 = null,
};

pub const WorkflowSyncOptions = struct {
    namespace: ?[]const u8 = null,
};

// =============================================================================
// Processing Types
// =============================================================================

pub const ProcessingSubmitOptions = struct {
    namespace: ?[]const u8 = null,
};

pub const ProcessingStatusOptions = struct {
    namespace: ?[]const u8 = null,
};

pub const ProcessingListOptions = struct {
    namespace: ?[]const u8 = null,
    limit: u32 = 100,
    cursor: ?[]const u8 = null,
};

pub const ProcessingStopOptions = struct {
    namespace: ?[]const u8 = null,
};

pub const ProcessingCancelOptions = struct {
    namespace: ?[]const u8 = null,
};

pub const ProcessingRemoveOptions = struct {
    namespace: ?[]const u8 = null,
};

pub const ProcessingSyncOptions = struct {
    namespace: ?[]const u8 = null,
};

/// Result of a processing status query. The runtime fields are the
/// answering node's own: none of it is replicated, so it starts again with
/// the node or a new leader.
pub const ProcessingStatusResult = struct {
    job_id: []const u8,
    name: []const u8,
    status: []const u8,
    batch_size: u32,
    records_processed: u64,
    created_at: i64,
    /// Why a failed job failed, or for a running job this node holds,
    /// "held here: " and why; null otherwise.
    reason: ?[]const u8,
    /// Whether this node runs any of the job's pipelines.
    running: bool,
    records_in: u64,
    records_out: u64,
    watermark_ms: i64,
    tick_avg_us: u64,
    tick_max_us: u64,
    /// Since the earliest of this node's pipelines started.
    uptime_ms: u64,
    /// The definition as submitted.
    yaml: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ProcessingStatusResult) void {
        self.allocator.free(self.job_id);
        self.allocator.free(self.name);
        self.allocator.free(self.status);
        if (self.reason) |r| self.allocator.free(r);
        self.allocator.free(self.yaml);
    }
};

/// Entry in a processing job list.
pub const ProcessingListEntry = struct {
    name: []const u8,
    job_id: []const u8,
    status: []const u8,
    created_at: i64,
    batch_size: u32,
    records_processed: u64,

    pub fn deinit(self: *ProcessingListEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.job_id);
        allocator.free(self.status);
    }
};

/// One page of processing jobs. A page can hold fewer than `limit` jobs
/// while `has_more` is set: keep asking until it is clear.
pub const ProcessingListResult = struct {
    jobs: []ProcessingListEntry,
    has_more: bool,
    /// Pass as `ProcessingListOptions.cursor` for the next page; null on the last page.
    cursor: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ProcessingListResult) void {
        for (self.jobs) |*entry| {
            entry.deinit(self.allocator);
        }
        self.allocator.free(self.jobs);
        if (self.cursor) |c| self.allocator.free(c);
    }
};

/// Result of a processing sync operation.
pub const ProcessingSyncResult = struct {
    name: []const u8,
    job_id: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ProcessingSyncResult) void {
        self.allocator.free(self.name);
        self.allocator.free(self.job_id);
    }
};

const Poll = struct { empty: bool, ms: u64 };

fn expectPauses(b: *EmptyPollBackoff, polls: []const Poll, want: []const u64) !void {
    for (polls, want) |p, w| {
        try std.testing.expectEqual(w, b.afterPoll(p.empty, p.ms * std.time.ns_per_ms, 30_000));
    }
}

test "EmptyPollBackoff: a full server's instant empties back off from 50 ms to 1 s" {
    var b: EmptyPollBackoff = .{};
    const instant: Poll = .{ .empty = true, .ms = 1 };
    try expectPauses(&b, &.{ instant, instant, instant, instant, instant, instant, instant, instant }, &.{ 0, 50, 100, 200, 400, 800, 1000, 1000 });
    // Work resets it.
    try expectPauses(&b, &.{ .{ .empty = false, .ms = 1 }, instant, instant }, &.{ 0, 0, 50 });
}

test "EmptyPollBackoff: a group-read wake is re-read at once" {
    var b: EmptyPollBackoff = .{};
    // Parked, woken empty by an append after 20 ms, re-read finds the record.
    const wake: Poll = .{ .empty = true, .ms = 20 };
    const record: Poll = .{ .empty = false, .ms = 1 };
    try expectPauses(&b, &.{ wake, record, wake, record, wake, record }, &.{ 0, 0, 0, 0, 0, 0 });
}

test "EmptyPollBackoff: a re-read loser woken after 300 ms never pauses" {
    var b: EmptyPollBackoff = .{};
    const lost: Poll = .{ .empty = true, .ms = 300 };
    try expectPauses(&b, &.{ lost, lost, lost, lost, lost }, &.{ 0, 0, 0, 0, 0 });
    // A non-early empty also ends a run of early ones.
    try expectPauses(&b, &.{ .{ .empty = true, .ms = 1 }, .{ .empty = true, .ms = 1 }, lost, .{ .empty = true, .ms = 1 } }, &.{ 0, 50, 0, 0 });
}

test "EmptyPollBackoff: early means under half of a short block_ms" {
    var b: EmptyPollBackoff = .{};
    _ = b.afterPoll(true, 1 * std.time.ns_per_ms, 100);
    try std.testing.expectEqual(@as(u64, 0), b.afterPoll(true, 60 * std.time.ns_per_ms, 100));
    try std.testing.expectEqual(@as(u32, 0), b.early_empties);
}

test "pauseWhileRunning returns soon after running goes false" {
    var running = true;
    const stopper = try std.Thread.spawn(.{}, struct {
        fn run(r: *bool) void {
            std.Thread.sleep(30 * std.time.ns_per_ms);
            @atomicStore(bool, r, false, .monotonic);
        }
    }.run, .{&running});
    var timer = try std.time.Timer.start();
    pauseWhileRunning(&running, 1_000);
    stopper.join();
    try std.testing.expect(timer.read() < 300 * std.time.ns_per_ms);
}

test "workerBlockMs: 0 means the default, over MAX_BLOCK_MS is refused" {
    try std.testing.expectEqual(@as(u32, 30000), try workerBlockMs(0));
    try std.testing.expectEqual(@as(u32, 1000), try workerBlockMs(1000));
    try std.testing.expectEqual(MAX_BLOCK_MS, try workerBlockMs(MAX_BLOCK_MS));
    try std.testing.expectError(FloError.BlockTooLong, workerBlockMs(MAX_BLOCK_MS + 1));
}

test "a missing namespace is its own error, not a missing key" {
    try std.testing.expectEqual(FloError.NoNamespace, StatusCode.no_namespace.toError());
    try std.testing.expectEqual(FloError.NotFound, StatusCode.not_found.toError());
    try std.testing.expectEqual(StatusCode.no_namespace, @as(StatusCode, @enumFromInt(14)));
    try std.testing.expectEqual(Reason.admin_only, @as(Reason, @enumFromInt(30)));
}

test "the op codes match the server's: namespace settings retired, ensure and repair skip known" {
    try std.testing.expect(!@hasField(OpCode, "namespace_config_set"));
    try std.testing.expect(!@hasField(OpCode, "namespace_config_get"));
    try std.testing.expectEqual(@as(u16, 0x016), @intFromEnum(OpCode.namespace_ensure));
    try std.testing.expectEqual(@as(u16, 0x032), @intFromEnum(OpCode.cluster_promote));
    try std.testing.expectEqual(@as(u16, 0x033), @intFromEnum(OpCode.cluster_remove));
    try std.testing.expectEqual(@as(u16, 0x034), @intFromEnum(OpCode.cluster_repair_skip));
    // A retired code is no longer a name: the old action reports and peek.
    for ([_]u16{ 0x014, 0x306, 0x307, 0x308, 0x309, 0x17C }) |code| {
        try std.testing.expect(std.enums.tagName(OpCode, @enumFromInt(code)) == null);
    }
    try std.testing.expectEqual(@as(u16, 0x30A), @intFromEnum(OpCode.action_await));
    try std.testing.expectEqual(@as(u16, 0x30D), @intFromEnum(OpCode.action_touch));
    try std.testing.expectEqual(@as(u16, 0x180), @intFromEnum(OpCode.queue_peek));
}

test "limit is its own terminal error, its reasons decode by name, and the txn reason is keys_not_colocated" {
    try std.testing.expectEqual(FloError.Limit, StatusCode.limit.toError());
    try std.testing.expectEqual(StatusCode.limit, @as(StatusCode, @enumFromInt(15)));
    for ([_]struct { u16, Reason }{
        .{ 18, .keys_not_colocated },
        .{ 32, .memory_budget },
        .{ 33, .too_many_actions },
        .{ 34, .too_many_workflow_definitions },
        .{ 35, .too_many_workflow_runs },
    }) |c| try std.testing.expectEqual(c[1], std.enums.fromInt(Reason, c[0]).?);
    // One this SDK predates is kept as its number.
    const next: Reason = @enumFromInt(38);
    try std.testing.expectEqual(@as(u16, 38), @intFromEnum(next));
    try std.testing.expect(std.enums.tagName(Reason, next) == null);
    try std.testing.expectEqual(Reason.queue_full, @as(Reason, @enumFromInt(36)));
    try std.testing.expectEqual(Reason.group_held_full, @as(Reason, @enumFromInt(37)));
    try std.testing.expect(!@hasField(Reason, "wrong_routing_key"));
    // The removed group ops are gone from the SDK.
    for ([_]u16{ 0x151, 0x152, 0x155, 0x157 }) |code| {
        try std.testing.expect(std.enums.tagName(OpCode, @enumFromInt(code)) == null);
    }
}

test "unavailable is retryable, internal_error is not, unknown codes are a server error" {
    try std.testing.expectEqual(FloError.Unavailable, StatusCode.unavailable.toError());
    try std.testing.expectEqual(FloError.Overloaded, StatusCode.overloaded.toError());
    // internal_error can mean committed-but-not-applied: resending may apply twice.
    try std.testing.expectEqual(FloError.InternalError, StatusCode.internal_error.toError());
    const unknown: StatusCode = @enumFromInt(200);
    try std.testing.expectEqual(FloError.ServerError, unknown.toError());
    try std.testing.expectEqualStrings("Unknown status", unknown.message());
}
