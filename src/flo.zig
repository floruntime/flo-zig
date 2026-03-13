//! Flo SDK for Zig
//!
//! A client library for the Flo distributed platform.
//!
//! ## Quick Start
//!
//! ```zig
//! const flo = @import("flo");
//!
//! pub fn main() !void {
//!     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//!     defer _ = gpa.deinit();
//!     const allocator = gpa.allocator();
//!
//!     // Create and connect client with default namespace
//!     var client = flo.Client.init(allocator, "localhost:9000", .{ .namespace = "myapp" });
//!     defer client.deinit();
//!     try client.connect();
//!
//!     // KV operations (uses default namespace)
//!     var kv = flo.KV.init(&client);
//!     try kv.put("key", "value", .{});
//!     const value = try kv.get("key", .{});
//!     defer if (value) |v| allocator.free(v);
//!
//!     // Queue operations
//!     var queue = flo.Queue.init(&client);
//!     _ = try queue.enqueue("tasks", "payload", .{});
//!     var result = try queue.dequeue("tasks", 10, .{});
//!     defer result.deinit();
//! }
//! ```

const std = @import("std");

// Re-export core types
pub const types = @import("types.zig");
pub const wire = @import("wire.zig");

// Re-export main components
pub const Client = @import("client.zig").Client;
pub const KV = @import("kv.zig").KV;
pub const Queue = @import("queue.zig").Queue;
pub const Stream = @import("stream.zig").Stream;

// Low-level Actions API
pub const Actions = @import("actions.zig").Actions;

// High-level Worker API
const worker_mod = @import("worker.zig");
pub const ActionWorker = worker_mod.ActionWorker;
pub const Worker = worker_mod.Worker; // backwards-compatible alias
pub const WorkerConfig = worker_mod.WorkerConfig;
pub const ActionContext = worker_mod.ActionContext;
pub const ActionHandler = worker_mod.ActionHandler;

// High-level Stream Worker API
const stream_worker_mod = @import("stream_worker.zig");
pub const StreamWorker = stream_worker_mod.StreamWorker;
pub const StreamWorkerConfig = stream_worker_mod.StreamWorkerConfig;
pub const StreamContext = stream_worker_mod.StreamContext;
pub const StreamRecordHandler = stream_worker_mod.StreamRecordHandler;

// Re-export commonly used types
pub const FloError = types.FloError;
pub const StatusCode = types.StatusCode;
pub const OpCode = types.OpCode;

// Result types
pub const ScanResult = types.ScanResult;
pub const KVEntry = types.KVEntry;
pub const Message = types.Message;
pub const DequeueResult = types.DequeueResult;
pub const VersionEntry = types.VersionEntry;
pub const StreamRecord = types.StreamRecord;
pub const StreamReadResult = types.StreamReadResult;
pub const StreamAppendResult = types.StreamAppendResult;
pub const StreamInfo = types.StreamInfo;
pub const StorageTier = types.StorageTier;
pub const TaskAssignment = types.TaskAssignment;
pub const ActionRunStatus = types.ActionRunStatus;
pub const ActionInvokeResult = types.ActionInvokeResult;
pub const ActionType = types.ActionType;
pub const RunStatus = types.RunStatus;
pub const WorkerType = types.WorkerType;
pub const WorkerStatus = types.WorkerStatus;
pub const ProcessKind = types.ProcessKind;
pub const ProcessEntry = types.ProcessEntry;

// Option types - KV
pub const PutOptions = types.PutOptions;
pub const ScanOptions = types.ScanOptions;
pub const HistoryOptions = types.HistoryOptions;

// Option types - Queue
pub const EnqueueOptions = types.EnqueueOptions;
pub const DequeueOptions = types.DequeueOptions;
pub const NackOptions = types.NackOptions;
pub const DlqListOptions = types.DlqListOptions;

// Option types - Stream
pub const StreamID = types.StreamID;
pub const StreamAppendOptions = types.StreamAppendOptions;
pub const StreamReadOptions = types.StreamReadOptions;
pub const StreamTrimOptions = types.StreamTrimOptions;
pub const StreamInfoOptions = types.StreamInfoOptions;
pub const StreamGroupJoinOptions = types.StreamGroupJoinOptions;
pub const StreamGroupReadOptions = types.StreamGroupReadOptions;
pub const StreamGroupAckOptions = types.StreamGroupAckOptions;
pub const StreamGroupNackOptions = types.StreamGroupNackOptions;

// Option types - Worker/Action
pub const ActionRegisterOptions = types.ActionRegisterOptions;
pub const ActionInvokeOptions = types.ActionInvokeOptions;
pub const ActionStatusOptions = types.ActionStatusOptions;
pub const WorkerRegisterOptions = types.WorkerRegisterOptions;
pub const WorkerAwaitOptions = types.WorkerAwaitOptions;
pub const WorkerCompleteOptions = types.WorkerCompleteOptions;
pub const WorkerFailOptions = types.WorkerFailOptions;
pub const WorkerTouchOptions = types.WorkerTouchOptions;
pub const WorkerHeartbeatOptions = types.WorkerHeartbeatOptions;
pub const WorkerDeregisterOptions = types.WorkerDeregisterOptions;
pub const WorkerDrainOptions = types.WorkerDrainOptions;

// Protocol constants
pub const MAGIC = types.MAGIC;
pub const VERSION = types.VERSION;

// =============================================================================
// Convenience Functions
// =============================================================================

/// Client configuration options
pub const ClientOptions = @import("client.zig").ClientOptions;

/// Create a new connected client
pub fn connect(allocator: std.mem.Allocator, endpoint: []const u8, options: ClientOptions) FloError!Client {
    var client = Client.init(allocator, endpoint, options);
    errdefer client.deinit();
    try client.connect();
    return client;
}

// =============================================================================
// Tests
// =============================================================================

test {
    // Run all tests from submodules
    std.testing.refAllDecls(@This());
    _ = @import("types.zig");
    _ = @import("wire.zig");
    _ = @import("client.zig");
    _ = @import("kv.zig");
    _ = @import("queue.zig");
    _ = @import("stream.zig");
    _ = @import("actions.zig");
    _ = @import("worker.zig");
    _ = @import("stream_worker.zig");
}
