# flo-zig

Zig SDK for the Flo distributed platform.

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .flo = .{
        .url = "https://github.com/floruntime/flo-zig/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const flo = b.dependency("flo", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("flo", flo.module("flo"));
```

## Quick Start

```zig
const std = @import("std");
const flo = @import("flo");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Connect to Flo server with default namespace
    var client = flo.Client.init(allocator, "localhost:9000", .{ .namespace = "myapp" });
    defer client.deinit();
    try client.connect();

    // KV operations (uses default namespace "myapp")
    var kv = flo.KV.init(&client);

    try kv.put("key", "value", .{});

    if (try kv.get("key", .{})) |value| {
        defer allocator.free(value);
        std.debug.print("Got: {s}\n", .{value});
    }

    // Override namespace for specific operation
    try kv.put("other-key", "other-value", .{ .namespace = "other-ns" });

    // Queue operations
    var queue = flo.Queue.init(&client);

    const seq = try queue.enqueue("tasks", "payload", .{ .priority = 5 });
    std.debug.print("Enqueued message seq={d}\n", .{seq});

    var result = try queue.dequeue("tasks", 10, .{});
    defer result.deinit();

    for (result.messages) |msg| {
        std.debug.print("Message: {s}\n", .{msg.payload});
    }

    // No ack needed: dequeue already acknowledged these messages (see Queue Operations).
}
```

## API Reference

### Client

```zig
// Create client with default namespace
var client = flo.Client.init(allocator, "localhost:9000", .{ .namespace = "myapp" });
defer client.deinit();

// Or use "default" namespace
var client = flo.Client.init(allocator, "localhost:9000", .{});

// With timeout and debug logging
var client = flo.Client.init(allocator, "localhost:9000", .{
    .namespace = "myapp",
    .timeout_ms = 10_000,  // 10 second timeout
    .debug = true,
    // Retries of refused, not-run requests (these are the defaults)
    .retry = .{ .max_attempts = 4, .initial_backoff_ms = 50, .max_backoff_ms = 1000 },
});

// Connect to server
try client.connect();

// Check connection status
if (client.isConnected()) { ... }

// Reconnect with exponential backoff (retries up to 5 minutes)
try client.reconnect();

// Forcibly close connection (unblocks blocking operations)
client.interrupt();

// Disconnect
client.disconnect();
```

### KV Operations

```zig
var kv = flo.KV.init(&client);

// Get value (returns null if not found)
const value = try kv.get("key", .{});

// Wait up to 5 seconds for the key to exist (answers at once if it does)
const value = try kv.get("key", .{ .wait_ms = 5000 });

// Wait up to 5 seconds for the key's next version
const value = try kv.get("key", .{ .wait_ms = 5000, .wait_for = .change });

// Put value (uses client's default namespace)
try kv.put("key", "value", .{});

// Put with options
try kv.put("key", "value", .{
    .ttl_ms = 3_600_000,        // Expire after 1 hour
    .cas_version = 5,           // Compare-and-swap
    .condition = .if_absent,    // Only set if key doesn't exist (or .if_present)
});

// Put to different namespace (override default)
try kv.put("key", "value", .{ .namespace = "other-ns" });

// Delete key: returns whether it existed (a missing key is not an error)
const existed = try kv.delete("key", .{});
// Delete only if the key is still at version 5
_ = try kv.delete("key", .{ .cas_version = 5 });

// Scan key names with a prefix ("" for all); limit is 1-1024, default 1024
var page = try kv.scan("prefix:", .{ .limit = 100 });
defer page.deinit();
for (page.keys) |name| std.debug.print("{s}\n", .{name});

// Next page: pass back the cursor; it is null on the last page
if (page.cursor) |cursor| {
    var next = try kv.scan("prefix:", .{ .limit = 100, .cursor = cursor });
    defer next.deinit();
}

// Version history, newest first (limit 1-65, default 10); each entry has
// version, at_ms (write time) and value. A missing key has no versions.
const versions = try kv.history("key", .{ .limit = 10 });
defer {
    for (versions) |*v| v.deinit(allocator);
    allocator.free(versions);
}

// Many keys at once (1-256, each at most 4096 bytes): one entry per key, in
// order, with `found`
var many = try kv.mget(&.{ "a", "b", "c" }, .{});
defer many.deinit();

// Counters: returns the new value and version
const counter = try kv.incr("hits", .{ .delta = 5 });

// TTL: set it on an existing key, or clear it with 0
try kv.expire("session", 30_000, .{});
try kv.expire("session", 0, .{});
// Renew a lease only if you still hold its version
try kv.expire("lease", 30_000, .{ .cas_version = 7 });

const present = try kv.exists("key", .{});

// JSON documents; path "" or "$" is the whole document
_ = try kv.jsonSet("user:1", "$", "{\"name\":\"ada\"}", .{});
if (try kv.jsonGet("user:1", "$.name", .{})) |found| {
    var doc = found;
    defer doc.deinit(allocator);
}
// Returns the new version, or null when "$" deleted the key
_ = try kv.jsonDel("user:1", "$.name", .{});
```

Ops that take a `routing_key` option route by it in place of the key, so
keys that share one live on the same shard.

A request frame is at most 256 KiB (`Client.max_request_size`), enough for
the largest value (253817 bytes) or JSON document the server takes; a bigger
frame returns `error.PayloadTooLarge` without sending anything. `mget`
splits its keys across as many requests as it needs.

#### Transactions

A transaction is pinned to one routing key's shard. Inside it, `put`,
`get`, `delete`, `incr`, `expire` and `exists` are routed by that key and
buffered until commit; `scan`, `mget`, `history` and the JSON ops are
refused with `error.TxnUnsupportedOp`.

```zig
var txn = try kv.begin("account:42", .{});
defer txn.deinit();
errdefer txn.rollback() catch {};

_ = try txn.put("account:42:balance", "100", .{});
try txn.incr("account:42:ops", 1);
try txn.expire("account:42:lock", 0, .{});
try txn.delete("account:42:hold", .{ .cas_version = 3 });

const committed = try txn.commit(); // commit_index, op_count
```

### Queue Operations

```zig
var queue = flo.Queue.init(&client);

// Enqueue message (uses client's default namespace)
const seq = try queue.enqueue("queue-name", "payload", .{
    .priority = 5, // Lower is dequeued first (0 = default, taken before 5)
});

// Enqueue to different namespace
const seq = try queue.enqueue("queue-name", "payload", .{ .namespace = "other-ns" });

// Dequeue messages. Queues are at-most-once today: dequeue acknowledges each
// message as it hands it out, so a message is not redelivered if the consumer
// fails, and ack/nack have no effect on it.
var result = try queue.dequeue("queue-name", 10, .{});
defer result.deinit();

// Block waiting for messages (long polling)
var result = try queue.dequeue("queue-name", 10, .{ .block_ms = 5000 });
defer result.deinit();

// ack / nack exist on the wire but have no effect on a dequeued message,
// since dequeue already acknowledged it. Don't rely on them for retries.
try queue.ack("queue-name", &seqs, .{});
try queue.nack("queue-name", &seqs, .{});

// The DLQ isn't reached in normal use, because dequeued messages are never
// failed back. dlqList returns a count summary; dlqRequeue is refused by the
// server as not implemented.
var dlq = try queue.dlqList("queue-name", .{});
defer dlq.deinit();
```

### Stream Operations

```zig
var stream = flo.Stream.init(&client);

// Append record to stream
const result = try stream.append("events", "payload data", .{});
std.debug.print("Appended at seq={d}\n", .{result.first_offset});

// Read from beginning
var records = try stream.read("events", .{});
defer records.deinit();

for (records.records) |rec| {
    std.debug.print("seq={d}: {s}\n", .{ rec.seq, rec.payload });
}

// Read from specific offset
var records = try stream.read("events", .{
    .start_mode = .offset,
    .offset = 100,
    .count = 50,
});
defer records.deinit();

// Read from tail (latest)
var records = try stream.read("events", .{
    .start_mode = .tail,
    .count = 10,
});
defer records.deinit();

// Long polling (block waiting for new records)
var records = try stream.read("events", .{
    .start_mode = .tail,
    .block_ms = 5000,  // Wait up to 5 seconds
});
defer records.deinit();

// Get stream info
const info = try stream.info("events", .{});
std.debug.print("Stream has {d} records\n", .{info.count});

// Trim stream
const trimmed = try stream.trim("events", .{ .max_len = 1000 });
_ = trimmed.removed;
```

### Stream Consumer Groups

```zig
var stream = flo.Stream.init(&client);

// Join a consumer group
try stream.groupJoin("events", "my-group", "worker-1", .{});

// Read from consumer group (auto-tracks offset per consumer)
var records = try stream.groupRead("events", "my-group", "worker-1", .{
    .count = 10,
    .block_ms = 5000,
});
defer records.deinit();

// Process records...
for (records.records) |rec| {
    // Process rec.payload
}

// Acknowledge processed records
var seqs: [10]u64 = undefined;
for (records.records, 0..) |rec, i| {
    seqs[i] = rec.seq;
}
try stream.groupAck("events", "my-group", seqs[0..records.records.len], .{});
```

### Action Operations

Actions are task types that workers process. `Actions` is the low-level API; for a
handler-based worker that registers, awaits, and heartbeats for you, see `ActionWorker`.

```zig
var actions = flo.Actions.init(&client);

// Register an action (task type)
try actions.registerAction("send-email", .user, .{
    .description = "Send email notifications",
    .timeout_ms = 30000,
    .max_retries = 3,
});

// Invoke an action (create a task)
var invoked = try actions.invoke("send-email", "{\"to\": \"user@example.com\"}", .{});
defer invoked.deinit();

// Only workers whose registered labels include every key/value get this run
var gpu_run = try actions.invoke("render", "{}", .{ .labels = "{\"gpu\":true}" });
defer gpu_run.deinit();

// Check task status
var status = try actions.getStatus(invoked.run_id, .{});
defer status.deinit();
std.debug.print("Status: {s}\n", .{@tagName(status.status)});
```

Invoke has no priority, delay or idempotency key; see
[flo#181](https://github.com/floruntime/flo/issues/181).

#### Processing Tasks (Worker Pattern)

```zig
var actions = flo.Actions.init(&client);

// Register as a worker for specific task types
try actions.register("worker-1", &[_][]const u8{ "send-email", "process-order" }, .{});

// Main worker loop
while (true) {
    // Await task (blocks until task available or timeout)
    var task = (try actions.awaitTask("worker-1", &[_][]const u8{"send-email"}, .{
        .block_ms = 30000, // Wait up to 30s (0 = don't wait, max 300000)
    })) orelse continue;
    defer task.deinit();

    std.debug.print("Got task: {s}\n", .{task.task_id});

    // Process the task...
    const result = processTask(task.payload);

    if (result.success) {
        // Complete successfully
        try actions.complete("worker-1", task.task_type, task.task_id, result.output, .{});
    } else {
        // Fail with retry
        try actions.fail("worker-1", task.task_type, task.task_id, result.error_msg, .{ .retry = true });
    }
}
```

#### Extending Task Lease

```zig
// For long-running tasks, extend the lease to prevent timeout
try actions.touch("worker-1", task.task_type, task.task_id, .{ .extend_ms = 30000 });
```

### Workflow Operations

```zig
var workflow = flo.Workflow.init(&client);

// Create workflow from YAML
try workflow.create("my-workflow", yaml_bytes, .{});

// Start a workflow run
const run_id = try workflow.start(allocator, "my-workflow", input_json, .{});
defer allocator.free(run_id);

// Get run status
var status = try workflow.status(allocator, run_id, .{});
defer status.deinit(allocator);

// Send a signal to a running workflow
try workflow.signal(run_id, "approval", "{\"approved\": true}", .{});

// Cancel a running workflow
try workflow.cancel(run_id, "no longer needed", .{});

// Disable/enable workflow definitions
try workflow.disable("my-workflow", .{});
try workflow.enable("my-workflow", .{});

// Declarative sync (version-aware create/update)
var result = try workflow.syncBytes(allocator, yaml_bytes, .{});
defer result.deinit();
std.debug.print("Workflow {s}: {s}\n", .{ result.name, result.action });
```

### Processing (Stream Processing)

```zig
var processing = flo.Processing.init(&client);

// Submit a processing job from YAML
const job_id = try processing.submit(allocator, yaml_bytes, .{});
defer allocator.free(job_id);

// Get job status
var status = try processing.status(allocator, job_id, .{});
defer status.deinit();
std.debug.print("Job {s}: {s} (processed {d} records)\n", .{
    status.name, status.status, status.records_processed,
});

// List all processing jobs
var jobs = try processing.list(allocator, .{ .limit = 50 });
defer jobs.deinit();
for (jobs.entries) |entry| {
    std.debug.print("{s}: {s}\n", .{ entry.name, entry.status });
}

// Gracefully stop a job
try processing.stop(job_id, .{});

// Force-cancel a job
try processing.cancel(job_id, .{});

// Create a savepoint
const sp_id = try processing.savepoint(allocator, job_id, .{});
defer allocator.free(sp_id);

// Restore from savepoint
try processing.restore(job_id, sp_id, .{});

// Change parallelism
try processing.rescale(job_id, 8, .{});

// Declarative sync (submit from YAML bytes)
var result = try processing.syncBytes(allocator, yaml_bytes, .{});
defer result.deinit();
std.debug.print("Job {s} submitted as {s}\n", .{ result.name, result.job_id });
```

## Error Handling

All operations return `flo.FloError` which includes:

- `NotConnected` - Client not connected
- `ConnectionFailed` - TCP connection failed
- `NotFound` - Key/queue/stream not found
- `BadRequest` - Invalid request
- `Conflict` - CAS conflict
- `Unauthorized` - Authentication required
- `Overloaded` - Server overloaded, and the client's retries ran out
- `RateLimited` - Request rate limit exceeded
- `Unavailable` - No leader, or the shard isn't taking writes or is offline, and the client's retries ran out (an offline shard needs an operator)
- `InternalError` - Internal server error (not retryable: the write may have committed)
- `UnexpectedResponse` - Unexpected response format
- `ServerError` - Generic server error, including status codes this SDK doesn't know

Zig errors carry no payload: after a failed call, `client.lastError()` gives the
numeric status and the server's message.

### Retries

When the server refuses a request as `overloaded` or `unavailable` and says it
didn't run it (`client.lastError().?.ran == .no`), the client sends it again
itself, as a new request with a new request id, after a jittered wait. Because
the server never ran it, this is safe for writes too. Any other refusal, or one
that may have run, comes straight back.

| `RetryPolicy` field | Default | |
|---|---|---|
| `max_attempts` | 4 | Tries in all, the first included; 1 turns retrying off |
| `initial_backoff_ms` | 50 | Ceiling of the first wait; it doubles each retry |
| `max_backoff_ms` | 1000 | Largest ceiling (raised to `initial_backoff_ms` if below it) |

Each wait is uniform between 0 and its ceiling, so with the defaults a refused
request is given back after at most about 350 ms of waiting, as
`error.Overloaded` or `error.Unavailable` with `lastError()` describing the last
refusal. The request goes again on the same connection; the server routes it
afresh.

The action and stream workers wait the same way between failed polls, from
100 ms up to 5 s, starting again from 100 ms after a poll that succeeds; `stop()`
ends a wait within about 10 ms. A stream worker retries a group join refused
this way instead of stopping.

```zig
// Up to 8 tries, waiting at most 2 s between them
var client = flo.Client.init(allocator, "localhost:9000", .{
    .retry = .{ .max_attempts = 8, .initial_backoff_ms = 100, .max_backoff_ms = 2000 },
});

// No retries
var client = flo.Client.init(allocator, "localhost:9000", .{ .retry = .{ .max_attempts = 1 } });
```

## Building

```bash
# Run tests
zig build test

# Run example
zig build run

# Run example with custom endpoint
zig build run -- localhost:9001
```

## License

Apache-2.0 - see [LICENSE](LICENSE) for details.
