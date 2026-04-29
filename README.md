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

    // Acknowledge processed messages
    var seqs = [_]u64{ result.messages[0].seq };
    try queue.ack("tasks", &seqs, .{});
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

// Get with long-polling (block waiting for key to appear)
const value = try kv.get("key", .{ .block_ms = 5000 });

// Put value (uses client's default namespace)
try kv.put("key", "value", .{});

// Put with options
try kv.put("key", "value", .{
    .ttl_seconds = 3600,        // Expire after 1 hour
    .cas_version = 5,           // Compare-and-swap
    .if_not_exists = true,      // Only set if key doesn't exist
});

// Put to different namespace (override default)
try kv.put("key", "value", .{ .namespace = "other-ns" });

// Delete key
try kv.delete("key", .{});

// Scan keys with prefix
var result = try kv.scan("prefix:", .{
    .limit = 100,
    .keys_only = true,
});
defer result.deinit();

// Get version history
const versions = try kv.history("key", .{ .limit = 10 });
```

### Queue Operations

```zig
var queue = flo.Queue.init(&client);

// Enqueue message (uses client's default namespace)
const seq = try queue.enqueue("queue-name", "payload", .{
    .priority = 5,              // Higher = more urgent
    .delay_ms = 1000,           // Delay before visible
    .dedup_key = "unique-id",   // Deduplication key
});

// Enqueue to different namespace
const seq = try queue.enqueue("queue-name", "payload", .{ .namespace = "other-ns" });

// Dequeue messages (uses server default 30s visibility timeout)
var result = try queue.dequeue("queue-name", 10, .{});
defer result.deinit();

// Dequeue with custom options
var result = try queue.dequeue("queue-name", 10, .{
    .visibility_timeout_ms = 60000,  // Custom visibility timeout
    .block_ms = 5000,                // Block waiting for messages (long polling)
});
defer result.deinit();

// Acknowledge messages
try queue.ack("queue-name", &seqs, .{});

// Negative acknowledge (return to queue or DLQ)
try queue.nack("queue-name", &seqs, .{ .to_dlq = false });

// List DLQ messages
var dlq = try queue.dlqList("queue-name", .{ .limit = 100 });
defer dlq.deinit();

// Requeue from DLQ
try queue.dlqRequeue("queue-name", &seqs, .{});
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
try stream.trim("events", .{ .max_len = 1000 });
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

### Worker/Action Operations

Actions are task types that workers process. Workers are long-running processes that await and process tasks.

```zig
var worker = flo.Worker.init(&client);

// Register an action (task type)
try worker.registerAction("send-email", .user, .{
    .description = "Send email notifications",
    .timeout_ms = 30000,
    .max_retries = 3,
});

// Invoke an action (create a task)
const run_id = try worker.invoke("send-email", "{\"to\": \"user@example.com\"}", .{
    .priority = 5,
});
defer allocator.free(run_id);

// Check task status
var status = try worker.getStatus(run_id, .{});
defer status.deinit();
std.debug.print("Status: {}\n", .{status.status});
```

#### Processing Tasks (Worker Pattern)

```zig
var worker = flo.Worker.init(&client);

// Register as a worker for specific task types
try worker.register("worker-1", &[_][]const u8{ "send-email", "process-order" }, .{});

// Main worker loop
while (true) {
    // Await task (blocks until task available or timeout)
    if (try worker.awaitTask("worker-1", &[_][]const u8{ "send-email" }, .{
        .timeout_ms = 30000,  // Task lease duration
        .block_ms = 0,        // Block forever until task arrives
    })) |*task| {
        defer task.deinit();

        std.debug.print("Got task: {s}\n", .{task.task_id});

        // Process the task...
        const result = processTask(task.payload);

        if (result.success) {
            // Complete successfully
            try worker.complete("worker-1", task.task_id, result.output, .{});
        } else {
            // Fail with retry
            try worker.fail("worker-1", task.task_id, result.error_msg, .{ .retry = true });
        }
    }
}
```

#### Extending Task Lease

```zig
// For long-running tasks, extend the lease to prevent timeout
try worker.touch("worker-1", task.task_id, .{ .extend_ms = 30000 });
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
- `Overloaded` - Server overloaded
- `RateLimited` - Request rate limit exceeded
- `InternalError` - Internal server error
- `UnexpectedResponse` - Unexpected response format
- `ServerError` - Generic server error

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

MIT
