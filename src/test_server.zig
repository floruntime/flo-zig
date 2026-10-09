//! A loopback server for tests that answers every request with an empty OK.

const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");

pub const OkServer = struct {
    server: std.net.Server,
    thread: std.Thread = undefined,
    requests: std.atomic.Value(u32) = .init(0),
    endpoint_buf: [32]u8 = undefined,
    endpoint: []const u8 = "",

    /// Listen on an ephemeral port. Call `start` once the value is at its
    /// final address.
    pub fn listen() !OkServer {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        return .{ .server = try addr.listen(.{}) };
    }

    pub fn start(self: *OkServer) !void {
        self.endpoint = try std.fmt.bufPrint(&self.endpoint_buf, "127.0.0.1:{d}", .{self.server.listen_address.getPort()});
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    /// Wait for the one client to hang up, then stop listening.
    pub fn deinit(self: *OkServer) void {
        self.thread.join();
        self.server.deinit();
    }

    fn serve(self: *OkServer) void {
        const conn = self.server.accept() catch return;
        defer conn.stream.close();
        while (true) {
            var header: wire.RequestHeader = undefined;
            readAll(conn.stream, std.mem.asBytes(&header)) catch return;
            var skipped: usize = 0;
            var buf: [1024]u8 = undefined;
            while (skipped < header.payload_length) {
                const n = @min(buf.len, header.payload_length - skipped);
                readAll(conn.stream, buf[0..n]) catch return;
                skipped += n;
            }
            _ = self.requests.fetchAdd(1, .monotonic);
            var resp = std.mem.zeroes(wire.ResponseHeader);
            resp.magic = types.MAGIC;
            resp.version = types.VERSION;
            resp.request_id = header.request_id;
            resp.status = @intFromEnum(types.StatusCode.ok);
            resp.crc32 = resp.computeCRC32("");
            conn.stream.writeAll(std.mem.asBytes(&resp)) catch return;
        }
    }

    fn readAll(stream: std.net.Stream, buf: []u8) !void {
        var got: usize = 0;
        while (got < buf.len) {
            const n = try stream.read(buf[got..]);
            if (n == 0) return error.EndOfStream;
            got += n;
        }
    }
};

/// Overwrite the stack below the caller, as later calls would, so a pointer
/// into a returned function's frame no longer reads as what it held.
pub noinline fn clobberStack() void {
    var buf: [64 * 1024]u8 = undefined;
    @memset(&buf, 0xAA);
    std.mem.doNotOptimizeAway(&buf);
}
