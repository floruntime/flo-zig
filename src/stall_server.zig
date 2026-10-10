//! A loopback server for worker tests. It answers every request with an empty
//! OK, except that it never answers the first `poll_op` (it waits for the
//! client to hang up instead), answers the next one with `body`, and refuses
//! a `poll_op` on a connection that has not sent `join_op`. It serves two
//! connections, then stops.

const std = @import("std");
const types = @import("types.zig");

pub const StallServer = struct {
    server: std.net.Server,
    join_op: types.OpCode,
    poll_op: types.OpCode,
    done_op: types.OpCode,
    body: []const u8,
    thread: std.Thread = undefined,
    connections: std.atomic.Value(u32) = .init(0),
    /// Requests with `done_op` received.
    done: std.atomic.Value(u32) = .init(0),
    endpoint_buf: [32]u8 = undefined,
    endpoint: []const u8 = "",

    /// Listen on an ephemeral port. Call `start` once the value is at its
    /// final address.
    pub fn listen(join_op: types.OpCode, poll_op: types.OpCode, done_op: types.OpCode, body: []const u8) !StallServer {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        return .{
            .server = try addr.listen(.{}),
            .join_op = join_op,
            .poll_op = poll_op,
            .done_op = done_op,
            .body = body,
        };
    }

    pub fn start(self: *StallServer) !void {
        self.endpoint = try std.fmt.bufPrint(&self.endpoint_buf, "127.0.0.1:{d}", .{self.server.listen_address.getPort()});
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    /// Wait for the client to hang up the second connection, then stop
    /// listening.
    pub fn deinit(self: *StallServer) void {
        // A failed test may leave serve waiting for its second connection.
        if (self.connections.load(.monotonic) < 2) {
            if (std.net.tcpConnectToAddress(self.server.listen_address)) |s| s.close() else |_| {}
        }
        self.thread.join();
        self.server.deinit();
    }

    /// Wait up to `ms` for `done_op` to arrive `n` times.
    pub fn waitDone(self: *StallServer, n: u32, ms: u64) bool {
        var waited: u64 = 0;
        while (self.done.load(.monotonic) < n) : (waited += 10) {
            if (waited >= ms) return false;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        return true;
    }

    fn serve(self: *StallServer) void {
        var polls: u32 = 0;
        while (self.connections.load(.monotonic) < 2) {
            const conn = self.server.accept() catch return;
            defer conn.stream.close();
            _ = self.connections.fetchAdd(1, .monotonic);
            var joined = false;
            while (true) {
                var req: [32]u8 = undefined;
                readAll(conn.stream, &req) catch break;
                const payload_length = std.mem.readInt(u32, req[4..8], .little);
                const request_id = std.mem.readInt(u64, req[8..16], .little);
                const op: types.OpCode = @enumFromInt(std.mem.readInt(u16, req[20..22], .little));
                var left: usize = payload_length;
                var buf: [1024]u8 = undefined;
                while (left > 0) {
                    const n = @min(buf.len, left);
                    readAll(conn.stream, buf[0..n]) catch return;
                    left -= n;
                }

                var data: []const u8 = "";
                var status = types.StatusCode.ok;
                if (op == self.join_op) joined = true;
                if (op == self.poll_op and !joined) {
                    status = .bad_request;
                } else if (op == self.poll_op) {
                    polls += 1;
                    if (polls == 1) {
                        // Stay silent until the client gives up and hangs up.
                        while ((conn.stream.read(&buf) catch 0) > 0) {}
                        break;
                    }
                    if (polls == 2) data = self.body else std.Thread.sleep(20 * std.time.ns_per_ms);
                }
                if (op == self.done_op) _ = self.done.fetchAdd(1, .monotonic);
                reply(conn.stream, request_id, status, data) catch break;
            }
        }
    }

    fn reply(stream: std.net.Stream, request_id: u64, status: types.StatusCode, data: []const u8) !void {
        var h = [_]u8{0} ** 32;
        std.mem.writeInt(u32, h[0..4], types.MAGIC, .little);
        std.mem.writeInt(u32, h[4..8], @intCast(data.len), .little);
        std.mem.writeInt(u64, h[8..16], request_id, .little);
        h[20] = types.VERSION;
        h[21] = @intFromEnum(status);
        var crc = std.hash.Crc32.init();
        crc.update(h[0..16]);
        crc.update(h[20..32]);
        crc.update(data);
        std.mem.writeInt(u32, h[16..20], crc.final(), .little);
        try stream.writeAll(&h);
        try stream.writeAll(data);
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
