//! Flo SDK Types
//!
//! Core types, constants, and error definitions for the Flo client SDK.

const std = @import("std");

/// Protocol magic number: "FLO\0" (0x004F4C46 in little-endian)
pub const MAGIC: u32 = 0x004F4C46;

/// Protocol version
pub const VERSION: u8 = 0x01;

/// Size limits (for client-side validation)
pub const MAX_NAMESPACE_SIZE: usize = 255;
pub const MAX_KEY_SIZE: usize = 64 * 1024; // 64 KB
pub const MAX_VALUE_SIZE: usize = 16 * 1024 * 1024; // 16 MB practical limit
/// Longest blocking wait (block_ms / wait_ms) the server accepts: 5 minutes.
/// The server refuses anything longer with bad_request.
pub const MAX_BLOCK_MS: u32 = 300_000;
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
    const slice_ms: u64 = 10;
    var left = ms;
    while (left > 0 and @atomicLoad(bool, running, .monotonic)) {
        const step: u64 = @min(left, slice_ms);
        std.Thread.sleep(step * std.time.ns_per_ms);
        left -= step;
    }
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
    namespace_config_set = 0x014,
    namespace_config_get = 0x015,

    // ── Cluster (0x030 – 0x04F) ──
    cluster_status = 0x030,
    cluster_members = 0x031,
    cluster_join = 0x032,
    cluster_leave = 0x033,
    cluster_transfer_leader = 0x034,
    cluster_add_node = 0x035,
    cluster_remove_node = 0x036,

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
    kv_begin_txn = 0x110,
    kv_commit_txn = 0x111,
    kv_rollback_txn = 0x112,
    // KV extended (TTL lifecycle, exists)
    kv_touch = 0x113,
    kv_persist = 0x114,
    kv_exists = 0x115,

    // ── Streams (0x130 – 0x14F) ──
    stream_append = 0x130,
    stream_read = 0x131,
    stream_trim = 0x132,
    stream_info = 0x133,
    stream_list = 0x13B,
    stream_create = 0x13D,
    stream_alter = 0x13F,

    // ── Stream Consumer Groups (0x150 – 0x16F) ──
    stream_group_create = 0x150,
    stream_group_join = 0x151,
    stream_group_leave = 0x152,
    stream_group_read = 0x153,
    stream_group_ack = 0x154,
    stream_group_claim = 0x155,
    stream_group_pending = 0x156,
    stream_group_configure_sweeper = 0x157,
    stream_group_nack = 0x159,
    stream_group_touch = 0x15A,
    stream_group_info = 0x15B,
    stream_group_delete = 0x15C,

    // ── Queues (0x170 – 0x19F) ──
    queue_enqueue = 0x170,
    queue_dequeue = 0x171,
    queue_complete = 0x172,
    queue_fail = 0x174,
    queue_dlq_list = 0x176,
    queue_dlq_delete = 0x177,
    queue_dlq_requeue = 0x178,
    queue_stats = 0x17B,
    queue_peek = 0x17C,
    queue_purge = 0x17F,
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
    action_await = 0x306,
    action_complete = 0x307,
    action_fail = 0x308,
    action_touch = 0x309,

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
    processing_savepoint = 0x365,
    processing_restore = 0x366,
    processing_rescale = 0x367,

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
            _ => "Unknown error",
        };
    }
};

/// Option tags for TLV-encoded operation parameters
pub const OptionTag = enum(u8) {
    // KV Options (0x01 - 0x0F)
    ttl_ms = 0x01, // u64: KV time-to-live in milliseconds (0 = no expiration)
    cas_version = 0x02, // u64: Expected version for compare-and-swap
    if_not_exists = 0x03, // void: Only set if key doesn't exist (NX)
    if_exists = 0x04, // void: Only set if key exists (XX)
    limit = 0x05, // u32: Maximum number of results for scan/list operations
    routing_key = 0x08, // string: Explicit routing key for shard co-location
    txn_id = 0x09, // u64: Transaction ID for per-shard transactions

    // Queue Options (0x10 - 0x1F)
    priority = 0x10, // u8: Message priority (0-255, lower is dequeued first)
    count = 0x15, // u32: Number of messages to dequeue
    block_ms = 0x17, // u32: Blocking wait for data (0=don't wait, max 300000)
    wait_ms = 0x18, // u32: Watch timeout - wait for NEXT version change (0=don't wait, max 300000)

    // Stream Options (0x20 - 0x2F) - StreamID-native ONLY
    // 0x20 reserved
    stream_start = 0x21, // [16]u8: Start StreamID for reads (inclusive)
    stream_end = 0x22, // [16]u8: End StreamID for reads (inclusive)
    stream_tail = 0x23, // void: Flag indicating tail read (start from end of stream)
    partition = 0x24, // u32: Explicit partition index
    partition_key = 0x25, // string: Key for partition routing
    max_age_seconds = 0x26, // u64: Maximum age in seconds for retention
    dry_run = 0x28, // void: Flag to preview what would be deleted without deleting

    // Consumer Group Options (0x30 - 0x3F)
    ack_timeout_ms = 0x30, // u32: Time before unacked message auto-redelivers
    max_deliver = 0x31, // u8: Max delivery attempts before DLQ (default: 10, 0=unlimited)

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
    UnsupportedVersion,
    InvalidChecksum,
    InvalidReservedField,
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
    BadRequest,
    Conflict,
    Unauthorized,
    Overloaded,
    RateLimited,
    InternalError,
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

/// KV entry from scan results
pub const KVEntry = struct {
    key: []const u8,
    value: ?[]const u8,

    pub fn deinit(self: *KVEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        if (self.value) |v| {
            allocator.free(v);
        }
    }
};

/// Result of a KV scan operation
pub const ScanResult = struct {
    entries: []KVEntry,
    cursor: ?[]const u8, // null if no more pages
    has_more: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ScanResult) void {
        for (self.entries) |*entry| {
            entry.deinit(self.allocator);
        }
        self.allocator.free(self.entries);
        if (self.cursor) |c| {
            self.allocator.free(c);
        }
    }
};

/// KV version entry from history
pub const VersionEntry = struct {
    version: u64,
    timestamp: i64,
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

/// Result of a successful KV transaction begin.
///
/// `txn_id` is the server-assigned transaction handle. `pinned_hash` is the
/// partition hash this transaction is bound to — every key written or read
/// inside the transaction must hash to the same partition.
pub const KVBeginResult = struct {
    txn_id: u64,
    pinned_hash: u64,
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

/// Queue message
pub const Message = struct {
    seq: u64,
    payload: []const u8,
    enqueued_at_ms: i64 = 0,
    delivery_count: u32 = 0,
    priority: u8 = 0,

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
    }
};

/// Result of a queue dequeue operation
pub const DequeueResult = struct {
    messages: []Message,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DequeueResult) void {
        for (self.messages) |*msg| {
            msg.deinit(self.allocator);
        }
        self.allocator.free(self.messages);
    }
};

// =============================================================================
// Option Types
// =============================================================================

/// Options for KV get operations
pub const GetOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Block waiting for key to appear, in ms (null or 0 = don't wait, max 300000)
    block_ms: ?u32 = null,
};

/// Options for KV put operations
pub const PutOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Expire the key after this many milliseconds (0 = no expiration)
    ttl_ms: ?u64 = null,
    cas_version: ?u64 = null,
    if_not_exists: bool = false,
    if_exists: bool = false,
};

/// Options for KV delete operations
pub const DeleteOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// CAS guard — when set, the delete only succeeds if the current key
    /// version equals `if_match`. Returns `FloError.Conflict` otherwise.
    /// Use this for race-free "only the owner deletes" patterns.
    if_match: ?u64 = null,
};

/// Options for KV scan operations
pub const ScanOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    cursor: ?[]const u8 = null,
    limit: ?u32 = null,
};

/// Options for KV history operations
pub const HistoryOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    limit: ?u32 = null,
};

/// Options for KV incr operations
pub const KVIncrOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Defaults to +1 when null. Negative values decrement.
    delta: ?i64 = null,
};

/// Options for KV touch / persist operations
pub const KVTouchOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// CAS guard — when set, the touch/persist only succeeds if the current
    /// key version equals `if_match`. Use this for race-free lease renewal.
    if_match: ?u64 = null,
};

/// Options for KV exists operations
pub const KVExistsOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// Options for KV JSON.* operations
pub const KVJsonOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// Options for KV mget operations
pub const KVMGetOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// Options for queue enqueue operations
pub const EnqueueOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Lower is dequeued first; equal priorities go in enqueue order.
    priority: u8 = 0,
};

/// Options for queue dequeue operations
pub const DequeueOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Block waiting for messages, in ms (null or 0 = don't wait, max 300000)
    block_ms: ?u32 = null,
};

/// Options for queue ack operations
pub const AckOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// Options for queue nack operations
pub const NackOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// Options for DLQ list operations
pub const DlqListOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// Options for DLQ requeue operations
pub const DlqRequeueOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// Options for queue peek operations
pub const PeekOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
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

/// Storage tier for stream records
pub const StorageTier = enum(u8) {
    hot = 0,
    pending = 1,
    warm = 2,
    cold = 3,
};

/// A single stream record
pub const StreamRecord = struct {
    id: StreamID = .{},
    tier: StorageTier = .hot,
    stream: []const u8 = "",
    payload: []const u8,
    headers: ?[]const u8 = null,

    pub fn deinit(self: *StreamRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        if (self.stream.len > 0) allocator.free(self.stream);
        if (self.headers) |h| allocator.free(h);
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

/// Stream info/metadata
pub const StreamInfo = struct {
    first_seq: u64,
    last_seq: u64,
    count: u64,
    bytes: u64,
    partition_count: u32 = 1,
};

/// Options for stream append operations
pub const StreamAppendOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Headers to attach to the record (key=value pairs separated by newlines)
    headers: ?[]const u8 = null,
};

/// Options for stream read operations
pub const StreamReadOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Start StreamID for reads (inclusive)
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

/// Options for consumer group join
pub const StreamGroupJoinOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// Options for consumer group read
pub const StreamGroupReadOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Maximum number of records to read
    count: ?u32 = null,
    /// Block waiting for new records, in ms (null or 0 = don't wait, max 300000)
    block_ms: ?u32 = null,
};

/// Options for consumer group ack
pub const StreamGroupAckOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Consumer ID (required for correct ack matching)
    consumer: []const u8 = "",
};

/// Options for consumer group nack
pub const StreamGroupNackOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Consumer ID (required for correct nack matching)
    consumer: []const u8 = "",
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

/// Task assignment from worker_await
pub const TaskAssignment = struct {
    task_id: []const u8,
    task_type: []const u8,
    payload: []const u8,
    created_at: i64,
    attempt: u32,
    caller_run_id: ?[]const u8 = null,
    caller_workflow_name: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TaskAssignment) void {
        self.allocator.free(self.task_id);
        self.allocator.free(self.task_type);
        self.allocator.free(self.payload);
        if (self.caller_run_id) |v| self.allocator.free(v);
        if (self.caller_workflow_name) |v| self.allocator.free(v);
    }
};

/// Action run status result
pub const ActionRunStatus = struct {
    run_id: []const u8,
    status: RunStatus,
    created_at: i64,
    started_at: ?i64,
    completed_at: ?i64,
    output: ?[]const u8,
    error_message: ?[]const u8,
    retry_count: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ActionRunStatus) void {
        self.allocator.free(self.run_id);
        if (self.output) |o| self.allocator.free(o);
        if (self.error_message) |e| self.allocator.free(e);
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
pub const ActionRegisterOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Action description
    description: ?[]const u8 = null,
    /// Timeout for action execution (ms)
    timeout_ms: ?u64 = null,
    /// Maximum retries on failure
    max_retries: ?u8 = null,
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

/// Options for worker await task
pub const WorkerAwaitOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Block waiting for task (null = 30000, 0 = don't wait, max 300000)
    block_ms: ?u32 = null,
};

/// Options for worker complete task
pub const WorkerCompleteOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Named outcome for workflow routing (default: "success")
    outcome: []const u8 = "success",
};

/// Options for worker fail task
pub const WorkerFailOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Whether to retry the task
    retry: bool = false,
};

/// Options for worker touch (extend lease)
pub const WorkerTouchOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// Lease extension time in ms
    extend_ms: ?u32 = null,
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
    workflow_name: ?[]const u8 = null,
    status_filter: ?[]const u8 = null,
    limit: u32 = 100,
};

pub const WorkflowListDefinitionsOptions = struct {
    namespace: ?[]const u8 = null,
    limit: u32 = 100,
    cursor: ?[]const u8 = null,
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

pub const ProcessingSavepointOptions = struct {
    namespace: ?[]const u8 = null,
};

pub const ProcessingRestoreOptions = struct {
    namespace: ?[]const u8 = null,
};

pub const ProcessingRescaleOptions = struct {
    namespace: ?[]const u8 = null,
};

pub const ProcessingSyncOptions = struct {
    namespace: ?[]const u8 = null,
};

/// Result of a processing status query.
pub const ProcessingStatusResult = struct {
    job_id: []const u8,
    name: []const u8,
    status: []const u8,
    parallelism: u32,
    batch_size: u32,
    records_processed: u64,
    created_at: i64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ProcessingStatusResult) void {
        self.allocator.free(self.job_id);
        self.allocator.free(self.name);
        self.allocator.free(self.status);
    }
};

/// Entry in a processing job list.
pub const ProcessingListEntry = struct {
    name: []const u8,
    job_id: []const u8,
    status: []const u8,
    parallelism: u32,
    created_at: i64,

    pub fn deinit(self: *ProcessingListEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.job_id);
        allocator.free(self.status);
    }
};

/// Result of a processing list operation.
pub const ProcessingListResult = struct {
    entries: []ProcessingListEntry,
    has_more: bool,
    /// Pass as `ProcessingListOptions.cursor` for the next page; null on the last page.
    cursor: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ProcessingListResult) void {
        for (self.entries) |*entry| {
            entry.deinit(self.allocator);
        }
        self.allocator.free(self.entries);
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
