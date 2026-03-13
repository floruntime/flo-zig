//! Stream Worker Example
//!
//! Demonstrates consuming records from a Flo stream via consumer groups.
//!
//! Usage:
//!   # First create a stream and produce some data:
//!   flo stream create events
//!   flo stream append events '{"type":"login","user":"alice"}'
//!   flo stream append events '{"type":"logout","user":"bob"}'
//!
//!   # Then run this example:
//!   zig build run-stream-worker
//!

const std = @import("std");
const flo = @import("flo");

fn processRecord(ctx: *flo.StreamContext) anyerror!void {
    const payload = ctx.payload();
    const id = ctx.streamID();

    std.debug.print("Record {d}/{d}: {s}\n", .{
        id.timestamp_ms,
        id.sequence,
        payload,
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sw = try flo.StreamWorker.init(allocator, .{
        .endpoint = "localhost:3000",
        .stream = "events",
        .group = "example-group",
    }, processRecord);
    defer sw.deinit();

    std.debug.print("Starting stream worker (Ctrl+C to stop)...\n", .{});
    try sw.start();
}
