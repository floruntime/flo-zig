//! Flo SDK Basic Example
//!
//! Demonstrates basic KV and Queue operations.
//!
//! Run with: zig build run
//! Or with custom endpoint: zig build run -- localhost:9001

const std = @import("std");
const flo = @import("flo");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse endpoint from args or use default
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const endpoint = if (args.len > 1) args[1] else "localhost:9000";

    std.debug.print("Connecting to {s}...\n", .{endpoint});

    // Create and connect client with default namespace
    var client = flo.Client.init(allocator, endpoint, .{ .namespace = "demo" });
    defer client.deinit();

    client.connect() catch |err| {
        std.debug.print("Failed to connect: {}\n", .{err});
        return;
    };

    std.debug.print("Connected! (default namespace: 'demo')\n\n", .{});

    // =============================================================================
    // KV Operations
    // =============================================================================
    std.debug.print("=== KV Operations ===\n", .{});

    var kv = flo.KV.init(&client);

    // Put a value (uses default namespace "demo")
    kv.put("greeting", "Hello, Flo!", .{}) catch |err| {
        std.debug.print("PUT failed: {}\n", .{err});
        return;
    };
    std.debug.print("PUT greeting = 'Hello, Flo!' (namespace: demo)\n", .{});

    // Get the value back
    if (kv.get("greeting", .{}) catch null) |value| {
        defer allocator.free(value);
        std.debug.print("GET greeting = '{s}'\n", .{value});
    } else {
        std.debug.print("GET greeting = (not found)\n", .{});
    }

    // Put with TTL
    kv.put("temp", "expires soon", .{ .ttl_seconds = 60 }) catch |err| {
        std.debug.print("PUT with TTL failed: {}\n", .{err});
        return;
    };
    std.debug.print("PUT temp = 'expires soon' (TTL: 60s)\n", .{});

    // Put to a different namespace (override default)
    kv.put("config-key", "config-value", .{ .namespace = "config" }) catch |err| {
        std.debug.print("PUT to config namespace failed: {}\n", .{err});
        return;
    };
    std.debug.print("PUT config-key = 'config-value' (namespace: config)\n", .{});

    // Scan keys
    std.debug.print("\nScanning keys in 'demo' namespace...\n", .{});
    var scan_result = kv.scan("", .{ .limit = 10 }) catch |err| {
        std.debug.print("SCAN failed: {}\n", .{err});
        return;
    };
    defer scan_result.deinit();

    for (scan_result.entries) |entry| {
        if (entry.value) |v| {
            std.debug.print("  {s} = '{s}'\n", .{ entry.key, v });
        } else {
            std.debug.print("  {s}\n", .{entry.key});
        }
    }

    // Delete the key
    kv.delete("greeting", .{}) catch |err| {
        std.debug.print("DELETE failed: {}\n", .{err});
        return;
    };
    std.debug.print("\nDELETE greeting\n", .{});

    // =============================================================================
    // Queue Operations
    // =============================================================================
    std.debug.print("\n=== Queue Operations ===\n", .{});

    var queue = flo.Queue.init(&client);

    // Enqueue some messages (uses default namespace "demo")
    const seq1 = queue.enqueue("tasks", "Task 1: Process data", .{ .priority = 5 }) catch |err| {
        std.debug.print("ENQUEUE failed: {}\n", .{err});
        return;
    };
    std.debug.print("ENQUEUE tasks seq={d} (namespace: demo)\n", .{seq1});

    const seq2 = queue.enqueue("tasks", "Task 2: Send notification", .{ .priority = 10 }) catch |err| {
        std.debug.print("ENQUEUE failed: {}\n", .{err});
        return;
    };
    std.debug.print("ENQUEUE tasks seq={d}\n", .{seq2});

    // Dequeue messages
    std.debug.print("\nDequeuing up to 10 messages...\n", .{});
    var dequeue_result = queue.dequeue("tasks", 10, .{}) catch |err| {
        std.debug.print("DEQUEUE failed: {}\n", .{err});
        return;
    };
    defer dequeue_result.deinit();

    var seqs_to_ack = std.ArrayListUnmanaged(u64){};
    defer seqs_to_ack.deinit(allocator);

    for (dequeue_result.messages) |msg| {
        std.debug.print("  Message seq={d}: '{s}'\n", .{ msg.seq, msg.payload });
        seqs_to_ack.append(allocator, msg.seq) catch return;
    }

    // Acknowledge messages
    if (seqs_to_ack.items.len > 0) {
        queue.ack("tasks", seqs_to_ack.items, .{}) catch |err| {
            std.debug.print("ACK failed: {}\n", .{err});
            return;
        };
        std.debug.print("\nACK {d} message(s)\n", .{seqs_to_ack.items.len});
    }

    std.debug.print("\nDone!\n", .{});
}
