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

    // Leased, not consumed: complete them within the lease, or they're
    // delivered again (see Queue Operations).
    if (result.messages.len > 0) {
        var done = try queue.complete("tasks", result.lease, result.messages, .{});
        done.deinit();
    }
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

// Get value (returns null if not found); expires_at_ms is when its TTL
// runs out, in Unix milliseconds, or null when it has none
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

// Scan key names with a prefix ("" for all); limit is 1-1024, default 1024.
// Pass each page's cursor back for the next; it is null on the last page.
var cursor_buf: [64]u8 = undefined;
var cursor: ?[]const u8 = null;
while (true) {
    var page = try kv.scan("prefix:", .{ .limit = 100, .cursor = cursor });
    defer page.deinit();
    for (page.keys) |name| std.debug.print("{s}\n", .{name});
    const next = page.cursor orelse break;
    if (page.keys.len == 0) break; // an empty page ends the loop too
    @memcpy(cursor_buf[0..next.len], next);
    cursor = cursor_buf[0..next.len];
}

// Version history, newest first, a page at a time (limit 1-65, default 10);
// each entry has version, at_ms (write time), deleted (a delete wrote it;
// value is empty) and value. A missing key has no versions. While `more` is
// set, ask again with before_version set to the page's last version.
var before: ?u64 = null;
while (true) {
    var history = try kv.history("key", .{ .limit = 10, .before_version = before });
    defer history.deinit();
    if (history.versions.len == 0) break;
    for (history.versions) |v| std.debug.print("v{d} at {d}\n", .{ v.version, v.at_ms });
    if (!history.more) break;
    before = history.versions[history.versions.len - 1].version;
}

// Many keys at once (1-256, each at most 4096 bytes): one entry per key, in
// order, with `found`
var many = try kv.mget(&.{ "a", "b", "c" }, .{});
defer many.deinit();
// Keys all written with one routing key: give it, and all are looked up on
// its shard (without it, each key is looked up on its own shard)
var routed = try kv.mget(&.{ "order:1", "order:2" }, .{ .routing_key = "customer:42" });
defer routed.deinit();

// Counters: returns the new value and version
const counter = try kv.incr("hits", .{ .delta = 5 });

// TTL: set it on an existing key, or clear it with 0
try kv.expire("session", 30_000, .{});
try kv.expire("session", 0, .{});
// Renew a lease only if you still hold its version
try kv.expire("lease", 30_000, .{ .cas_version = 7 });

const present = (try kv.exists("key", .{})).exists;

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

A condition, `cas_version` or `incr` inside a transaction is decided at commit,
not at the op: a commit that one of them refuses returns `error.Conflict` (or
`error.BadRequest` for an incr that can't apply) and applies nothing. Outside a
transaction a refused condition or `cas_version` still costs a commit, since
it's decided in log order as the write applies. A transaction holds at most 64
ops and 256 KiB by default; both are operator settings.

### Queue Operations

```zig
var queue = flo.Queue.init(&client);

// Enqueue message (uses client's default namespace)
const seq = try queue.enqueue("queue-name", "payload", .{
    .priority = 5, // Lower is dequeued first (0 = default, taken before 5)
});

// Enqueue to different namespace
const seq = try queue.enqueue("queue-name", "payload", .{ .namespace = "other-ns" });

// Ready after a delay, at most a day
_ = try queue.enqueue("queue-name", "later", .{ .delay_ms = 60_000 });

// Dequeue up to 10 messages, waiting up to 5 s for one. They are leased to
// the consumer, not consumed: delivery is at least once. Complete each within
// its lease (30 s unless `lease_ms` says otherwise, 5 s to 12 h) or touch it;
// one whose lease runs out is ready again, with `deliveries` one higher.
var result = try queue.dequeue("queue-name", 10, .{ .consumer = "c1", .block_ms = 5000 });
defer result.deinit();

// Reports name the dequeue's lease, the messages (seq and deliveries) and the
// same consumer. Each message is applied or refused on its own, inside an ok
// answer; for a complete, a message refused `.gone` was completed already.
var done = try queue.complete("queue-name", result.lease, result.messages, .{ .consumer = "c1" });
defer done.deinit();
for (done.refused) |r| std.debug.print("{d}: {s} ({s})\n", .{ r.seq, @tagName(r.why), r.reason });

// Fail them back: ready again after delay_ms, or dead once their attempts are
// spent (`.dead = true` now). Touch keeps the lease; it renews with half of it
// or less left, up to 12 h from the dequeue.
var failed = try queue.fail("queue-name", result.lease, result.messages, .{ .consumer = "c1", .delay_ms = 1000 });
defer failed.deinit();

// At most once instead: completed as they're taken
var taken = try queue.dequeue("queue-name", 10, .{ .ack = true });
defer taken.deinit();

// Remove every message, ready, leased and dead; returns how many
const removed = try queue.purge("queue-name", .{});

// A queue holds at most its cap of messages and bytes (server settings). Past
// one, an enqueue is refused `overloaded` without running; the client retries
// it like any such refusal (about 350 ms), then returns error.Overloaded, and
// `client.lastError()` names the cap.

// The next ready messages, 1 to 100, in dequeue order, without taking them;
// each shows up to 4 KiB of its payload (`size` is its whole length)
var next = try queue.peek("queue-name", 20, .{});
defer next.deinit();

// Dead messages wait in the DLQ until the queue is purged. dlqList pages it
// oldest first, up to 100 at a time: pass the page's last_seq as `after`
// while has_more is set.
var dlq = try queue.dlqList("queue-name", .{ .limit = 50 });
defer dlq.deinit();
std.debug.print("{d} dead letters\n", .{dlq.total});
```

### Stream Operations

```zig
var stream = flo.Stream.init(&client);

// Append record to stream
const result = try stream.append("events", "payload data", .{});

// With headers, stored with the record and read back as key/value pairs
_ = try stream.append("events", "payload data", .{ .headers = &.{.{ .key = "source", .value = "web" }} });
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

// Delete a stream; a stream that still holds records needs force
try stream.delete("events", .{ .force = true });
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

// The stream's groups, and a group's members, as the leader sees them
var groups = try stream.groupList("events", .{});
defer groups.deinit();
var members = try stream.groupMembers("events", "my-group", .{});
defer members.deinit();
```

### Action Operations

Actions are task types that workers process. `Actions` is the low-level API; for a
handler-based worker that registers, awaits, and heartbeats for you, see `ActionWorker`.

`ActionWorker.registerAction(name, handler, options)` registers the action with exactly
`options` (`.{}`: the server's 300 s lease, and 3 attempts). Registering replaces an
action's settings, so workers that register one action with different options leave it
with whichever registered last. The timeout is the lease a worker holds each run for: the
server takes 5000 to 43200000 ms, and 0 (the default here) for its default, 300000.
Whatever the touches, a worker holds a run at most 12 h from its delivery. A run whose
handler goes past its lease without touching it is taken back and run again;
`.auto_touch = true` in `WorkerConfig` touches each run every sixth of its lease, counted
from when it arrived, from a thread on its own connection while the handler runs; that
thread allocates, so the worker's allocator must then be thread-safe. It's off by
default; without it, call `ctx.touch()` from long handlers, at least every half lease.
An action's `owner` is at most 256 bytes.

A handler that returns an error fails the run with retry: it runs again while attempts
are left (return `error.NonRetryable` to fail it for good). `stop()` stops taking work:
running handlers are not interrupted, and finish and send their results before `start`
returns. `drain()` does the same and also tells the server.

`WorkerConfig.concurrency` is how many tasks an `ActionWorker` runs at once. The default,
1, runs them one after another on the polling loop. Above 1, each runs on a thread and a
connection of its own, so handlers must be safe to run concurrently and the worker's
allocator must be thread-safe (a GPA, `c_allocator` or `page_allocator`, not an arena).
`start` and `deinit` wait for running handlers to return, however long they take.

```zig
var actions = flo.Actions.init(&client);

// Register an action (task type)
try actions.registerAction("send-email", .user, .{
    .owner = "notifications",
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
std.debug.print("Status: {s}, attempt {d}\n", .{ @tagName(status.status), status.attempt });
if (status.output) |out| std.debug.print("Output: {s}\n", .{out});
// The outcome a completed run's worker named; null for success
if (status.outcome) |o| std.debug.print("Outcome: {s}\n", .{o});

// An action's definition, its runs by status and how long completed ones took
var info = try actions.info("send-email", .{});
defer info.deinit();
std.debug.print("{d} ready, lease {d} ms\n", .{ info.ready, info.timeout_ms });
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
    // Await task (blocks until task available or timeout). A retry with the
    // same request_key gets the task the first try got.
    var task = (try actions.awaitTask("worker-1", &[_][]const u8{"send-email"}, .{
        .block_ms = 30000, // Wait up to 30s (0 = don't wait, max 300000)
    })) orelse continue;
    defer task.deinit();

    std.debug.print("Got run {s}, delivery {d}\n", .{ task.run_id, task.deliveries });

    // Process the task...
    const result = processTask(task.payload);

    // Each report echoes the task's delivery. One for a delivery that has
    // moved on (its lease ran out, it was delivered again) is
    // error.StaleReport; a resend of one that already applied is ok.
    if (result.success) {
        try actions.complete("worker-1", task.delivery(), result.output, .{});
    } else {
        // Ready again after delay_ms while attempts are left; .abandoned
        // hands it back without counting a failure
        try actions.fail("worker-1", task.delivery(), result.error_msg, .{ .delay_ms = 1000 });
    }
}
```

#### Keeping a Task's Lease

```zig
// With half the lease or less left, a touch renews it for a full lease;
// with more left it changes nothing. Touch at least every half lease; a run
// is still held at most 12 h from its delivery.
const expires_at_ms = try actions.touch("worker-1", task.delivery(), .{});
```

#### Inspecting Workers

```zig
// A page of the namespace's workers, in id order; `action` lists only the
// workers that run it
var page = try actions.listWorkers(.{});
defer page.deinit();
var senders = try actions.listWorkers(.{ .action = "send-email" });
defer senders.deinit();

// One worker: its row (machine_id included), the metadata it registered
// with as raw bytes, and its processes, each with a kind and run counts.
// error.NotFound if the server doesn't know it.
var info = try actions.workerInfo("worker-1", .{});
defer info.deinit();
for (info.processes) |p| std.debug.print("{s} {s} ran {d}\n", .{ p.name, @tagName(p.kind), p.run_count });
```

The server judges a registration's limits; a refusal comes back as
`error.BadRequest`, with `client.lastError()` giving its reason and message: more
than 1024 processes is `out_of_range`; a process name over 4096 bytes, processes too
long to list together, or a machine id over 255 bytes is `field_too_long`.

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

// List workflow definitions, a page at a time. A page can be short while
// more remain: stop on has_more, not on the page's size.
var defs_cursor: ?[]u8 = null;
defer if (defs_cursor) |c| allocator.free(c);
while (true) {
    var defs = try workflow.listDefinitions(allocator, .{ .limit = 50, .cursor = defs_cursor });
    defer defs.deinit();
    for (defs.definitions) |def| std.debug.print("{s} v{s}\n", .{ def.name, def.version });
    if (!defs.has_more) break;
    if (defs_cursor) |c| allocator.free(c);
    defs_cursor = try allocator.dupe(u8, defs.cursor.?);
}

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
// Why a failed job failed, or why this node holds a running one
if (status.reason) |reason| std.debug.print("{s}\n", .{reason});

// A stopped, cancelled or failed job keeps its slot until it is removed
try processing.remove(job_id, .{});

// List all processing jobs, a page at a time. A page can be short while
// more remain: stop on has_more, not on the page's size.
var jobs_cursor: ?[]u8 = null;
defer if (jobs_cursor) |c| allocator.free(c);
while (true) {
    var jobs = try processing.list(allocator, .{ .limit = 50, .cursor = jobs_cursor });
    defer jobs.deinit();
    for (jobs.jobs) |entry| std.debug.print("{s}: {s}\n", .{ entry.name, entry.status });
    if (!jobs.has_more) break;
    if (jobs_cursor) |c| allocator.free(c);
    jobs_cursor = try allocator.dupe(u8, jobs.cursor.?);
}

// Gracefully stop a job
try processing.stop(job_id, .{});

// Force-cancel a job
try processing.cancel(job_id, .{});

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
- `Unavailable` - No leader yet, records still being read from disk, or the shard isn't taking writes or is offline, and the client's retries ran out (an offline shard needs an operator)
- `InternalError` - Internal server error (not retryable: the write may have committed)
- `OutcomePending` - The write committed but hasn't applied, because its shard halted (never retried)
- `StaleNotFound` - `get` or `jsonGet` on a halted shard: the key is missing as of the halt, which isn't the same as missing
- `StaleReport` - An action complete, fail or touch for a delivery that has moved on (never resent)
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

The client never retries two refusals from a halted shard. `unavailable` with
reason `shard_halted` didn't run, but the shard takes no writes until an operator
repairs it, so a retry can't succeed. `outcome_pending` (`error.OutcomePending`,
reason `shard_halted`, ran unknown) is a write that committed and hasn't applied:
sending it again would write it twice, or halt the shard again. The message says
whether it applies when the shard resumes.

The workers are different: their registration, group join and polls are theirs
to retry. On `shard_halted` they wait, from 100 ms up to 30 s, logging a warning
with the server's message each time, and carry on by themselves once the shard is
repaired; a stop or drain ends the wait. A worker started during a halt comes up
once it's over. They wait only on a refusal that didn't run: a registration
answered `outcome_pending` ends `start()` with `error.OutcomePending`, since
resending it could halt the shard again, and a complete, fail or ack refused
either way is not sent again.

A halted shard still answers reads, from its state just before the entry it
halted at, and so does a node whose log reads are blocked, from its state as last
applied. Such a read succeeds with `stale` set on its result (`GetResult`,
`MGetEntry`, `ScanResult`, `HistoryResult`, `ExistsResult`): it is not an error,
but it doesn't hold anything written since. A key missing from such an answer
may exist since, so `get` and `jsonGet` return `error.StaleNotFound` rather than
null. Only the KV reads carry the flag for now: other reads (streams,
queues, actions, workers) drop it.

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
this way instead of stopping, and a group read refused `unavailable` without
running (its records are still being read from disk, say) is read again with
the same group and consumer: it claimed nothing. `WorkerConfig` and `StreamWorkerConfig` take a `retry` field
for the connection each worker opens.

A worker whose complete, fail, ack or nack is lost with its connection (or
times out) reconnects and sends the same result again, up to three sends in
all; a resent complete or fail that already applied answers ok, and a refusal
is not resent. Delivery is at-least-once: a handler may see a
task or record again, so make handlers safe to repeat.

```zig
// Up to 8 tries, waiting at most 2 s between them
var client = flo.Client.init(allocator, "localhost:9000", .{
    .retry = .{ .max_attempts = 8, .initial_backoff_ms = 100, .max_backoff_ms = 2000 },
});

// No retries
var client = flo.Client.init(allocator, "localhost:9000", .{ .retry = .{ .max_attempts = 1 } });
```

`StreamWorkerConfig.concurrency` (default 1) is how many records of a batch a stream
worker handles at once (at most `batch_size`). Above 1, each runs on a thread with a
connection of its own for its ack or nack, so a batch's records are handled out of order,
and handlers and the worker's allocator must be thread-safe. The next read waits for the
whole batch. `drain()` and `stop()` are safe to call from any thread.

A worker polls and tells the server of its own `drain()` on one connection, so the
drain goes out once the held poll returns, up to `block_ms`. A drain sent from
elsewhere (the CLI, another client) answers an action worker's held poll at once; a
stream worker's held read isn't woken, and it sees the drain at its next heartbeat.

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
