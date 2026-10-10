//! A loopback server for tests that answers every request with OK and `body`,
//! and keeps the last request's payload for the test to inspect.

const std = @import("std");
const types = @import("types.zig");

pub const OkServer = struct {
    server: std.net.Server,
    thread: std.Thread = undefined,
    requests: std.atomic.Value(u32) = .init(0),
    endpoint_buf: [32]u8 = undefined,
    endpoint: []const u8 = "",
    /// Data sent back with every OK.
    body: []const u8 = "",
    last_payload_buf: [1024]u8 = undefined,
    last_payload_len: usize = 0,

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

    // Headers are encoded and decoded at the server's byte offsets rather
    // than through the SDK's wire structs, so a wrong field layout in those
    // structs fails here instead of agreeing with itself.
    fn serve(self: *OkServer) void {
        const conn = self.server.accept() catch return;
        defer conn.stream.close();
        while (true) {
            var req: [32]u8 = undefined;
            readAll(conn.stream, &req) catch return;
            const magic = std.mem.readInt(u32, req[0..4], .little);
            const payload_length = std.mem.readInt(u32, req[4..8], .little);
            const request_id = std.mem.readInt(u64, req[8..16], .little);
            const crc32 = std.mem.readInt(u32, req[16..20], .little);
            const version = req[22];
            if (magic != types.MAGIC or version != types.VERSION) return;

            var crc = std.hash.Crc32.init();
            crc.update(req[0..16]);
            crc.update(req[20..32]);
            if (payload_length > self.last_payload_buf.len) return;
            const payload = self.last_payload_buf[0..payload_length];
            readAll(conn.stream, payload) catch return;
            crc.update(payload);
            if (crc.final() != crc32) return;
            self.last_payload_len = payload_length;
            _ = self.requests.fetchAdd(1, .release);

            var resp = [_]u8{0} ** 32;
            std.mem.writeInt(u32, resp[0..4], types.MAGIC, .little);
            std.mem.writeInt(u32, resp[4..8], @intCast(self.body.len), .little); // data_len
            std.mem.writeInt(u64, resp[8..16], request_id, .little);
            resp[20] = types.VERSION;
            resp[21] = @intFromEnum(types.StatusCode.ok);
            var resp_crc = std.hash.Crc32.init();
            resp_crc.update(resp[0..16]);
            resp_crc.update(resp[20..32]);
            std.mem.writeInt(u32, resp[16..20], resp_crc.final(), .little);
            conn.stream.writeAll(&resp) catch return;
            conn.stream.writeAll(self.body) catch return;
        }
    }

    /// The value field of the last request, read at the server's payload
    /// offsets: [ns_len:u16][ns][key_len:u16][key][value_len:u32][value]...
    pub fn lastValue(self: *OkServer) []const u8 {
        _ = self.requests.load(.acquire);
        const p = self.last_payload_buf[0..self.last_payload_len];
        var off: usize = 0;
        off += 2 + std.mem.readInt(u16, p[off..][0..2], .little);
        off += 2 + std.mem.readInt(u16, p[off..][0..2], .little);
        const value_len = std.mem.readInt(u32, p[off..][0..4], .little);
        off += 4;
        return p[off..][0..value_len];
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
