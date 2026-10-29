//! A loopback server for tests that answers every request with OK and `body`
//! (or with `replies`, in order), and keeps the last request's payload for
//! the test to inspect.

const std = @import("std");
const types = @import("types.zig");

pub const Reply = struct {
    status: u8,
    body: []const u8 = "",
    /// How long ScriptServer waits before answering.
    delay_ms: u32 = 0,
    /// OkServer sends the body with its first byte flipped, under the
    /// checksum of the body as given.
    flip_body_byte: bool = false,
    /// The answer header's flags byte.
    flags: u8 = 0,
};

pub const OkServer = struct {
    server: std.net.Server,
    thread: std.Thread = undefined,
    requests: std.atomic.Value(u32) = .init(0),
    endpoint_buf: [32]u8 = undefined,
    endpoint: []const u8 = "",
    /// Data sent back with every OK.
    body: []const u8 = "",
    /// Replies for the first requests, in order; later ones get OK and `body`.
    replies: []const Reply = &.{},
    last_payload_buf: [256 * 1024]u8 = undefined,
    last_payload_len: usize = 0,
    last_op: u16 = 0,
    /// The request ids of the first requests, in order.
    ids: [16]u64 = undefined,

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
            const crc32c = std.mem.readInt(u32, req[16..20], .little);
            const version = req[22];
            if (magic != types.MAGIC or version != types.VERSION) return;

            var crc = std.hash.crc.Crc32Iscsi.init();
            crc.update(req[0..16]);
            crc.update(req[20..32]);
            if (payload_length > self.last_payload_buf.len) return;
            const payload = self.last_payload_buf[0..payload_length];
            readAll(conn.stream, payload) catch return;
            crc.update(payload);
            if (crc.final() != crc32c) return;
            self.last_payload_len = payload_length;
            self.last_op = std.mem.readInt(u16, req[20..22], .little);
            const n = self.requests.load(.monotonic);
            if (n < self.ids.len) self.ids[n] = request_id;
            _ = self.requests.fetchAdd(1, .release);
            const reply: Reply = if (n < self.replies.len) self.replies[n] else .{ .status = 0, .body = self.body };

            var resp = [_]u8{0} ** 32;
            std.mem.writeInt(u32, resp[0..4], types.MAGIC, .little);
            std.mem.writeInt(u32, resp[4..8], @intCast(reply.body.len), .little); // data_len
            std.mem.writeInt(u64, resp[8..16], request_id, .little);
            resp[20] = types.VERSION;
            std.mem.writeInt(u64, resp[24..32], types.TABLE_HASH, .little);
            resp[21] = reply.status;
            resp[22] = reply.flags;
            var resp_crc = std.hash.crc.Crc32Iscsi.init();
            resp_crc.update(resp[0..16]);
            resp_crc.update(resp[20..32]);
            resp_crc.update(reply.body);
            std.mem.writeInt(u32, resp[16..20], resp_crc.final(), .little);
            conn.stream.writeAll(&resp) catch return;
            if (reply.flip_body_byte and reply.body.len > 0) {
                const first = [1]u8{reply.body[0] ^ 0x01};
                conn.stream.writeAll(&first) catch return;
                conn.stream.writeAll(reply.body[1..]) catch return;
                continue;
            }
            conn.stream.writeAll(reply.body) catch return;
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

    /// The key of the last request: [ns_len:u16][ns][key_len:u16][key]...
    pub fn lastKey(self: *OkServer) []const u8 {
        _ = self.requests.load(.acquire);
        const p = self.last_payload_buf[0..self.last_payload_len];
        const off = 2 + std.mem.readInt(u16, p[0..2], .little);
        const key_len = std.mem.readInt(u16, p[off..][0..2], .little);
        return p[off + 2 ..][0..key_len];
    }

    /// The body of the last request, which must be a table op's:
    /// everything after its key.
    pub fn lastBody(self: *OkServer) []const u8 {
        const key = self.lastKey();
        const p = self.last_payload_buf[0..self.last_payload_len];
        const off = @intFromPtr(key.ptr) - @intFromPtr(p.ptr) + key.len;
        return p[off..];
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

/// A loopback server for worker tests that serves one connection after
/// another and answers each request as the first matching `Rule` says
/// (empty OK by default). It keeps every request's op and raw bytes, header
/// included.
pub const ScriptServer = struct {
    pub const Action = union(enum) {
        reply: Reply,
        /// Hang up without answering.
        drop,
        /// Never answer; wait for the client to hang up.
        stall,
        /// Hang up without answering and stop listening, so reconnects are
        /// refused. Not for `concurrent` servers: it would deinit the
        /// listener from a connection thread while serve may be accepting.
        close,
    };

    pub const Rule = struct {
        op: types.OpCode,
        /// Which request with `op` (0 = the first) this rule answers; null
        /// for all of them.
        nth: ?u32 = null,
        action: Action,
    };

    pub const Request = struct {
        op: types.OpCode,
        len: usize,
        bytes: [1024]u8,
    };

    server: std.net.Server,
    thread: std.Thread = undefined,
    rules: []const Rule = &.{},
    endpoint_buf: [32]u8 = undefined,
    endpoint: []const u8 = "",
    stopping: std.atomic.Value(bool) = .init(false),
    closed: bool = false,
    connections: std.atomic.Value(u32) = .init(0),
    mutex: std.Thread.Mutex = .{},
    log: [96]Request = undefined,
    count: usize = 0,
    /// Serve each connection on a thread of its own, so a client may hold
    /// several at once; by default they're served one after another.
    concurrent: bool = false,
    conn_threads: [8]std.Thread = undefined,
    conn_thread_count: usize = 0,
    /// Requests seen per op, across connections, under `mutex`.
    seen: std.EnumArray(types.OpCode, u32) = .initFill(0),

    pub fn listen() !ScriptServer {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        return .{ .server = try addr.listen(.{}) };
    }

    pub fn start(self: *ScriptServer) !void {
        self.endpoint = try std.fmt.bufPrint(&self.endpoint_buf, "127.0.0.1:{d}", .{self.server.listen_address.getPort()});
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    /// Wait for the client to hang up its connection, then stop listening.
    pub fn deinit(self: *ScriptServer) void {
        self.stopping.store(true, .release);
        if (std.net.tcpConnectToAddress(self.server.listen_address)) |s| s.close() else |_| {}
        self.thread.join();
        for (self.conn_threads[0..self.conn_thread_count]) |t| t.join();
        if (!self.closed) self.server.deinit();
    }

    /// How many requests with `op` arrived.
    pub fn countOf(self: *ScriptServer, op: types.OpCode) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: u32 = 0;
        for (self.log[0..self.count]) |r| n += @intFromBool(r.op == op);
        return n;
    }

    /// The `nth` request with `op` (0 = the first), header included.
    pub fn requestOf(self: *ScriptServer, op: types.OpCode, nth: u32) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: u32 = 0;
        for (self.log[0..self.count]) |*r| {
            if (r.op != op) continue;
            if (n == nth) return r.bytes[0..r.len];
            n += 1;
        }
        return "";
    }

    fn serve(self: *ScriptServer) void {
        while (true) {
            const conn = self.server.accept() catch return;
            if (self.stopping.load(.acquire)) {
                conn.stream.close();
                return;
            }
            _ = self.connections.fetchAdd(1, .monotonic);
            if (self.concurrent and self.conn_thread_count < self.conn_threads.len) {
                if (std.Thread.spawn(.{}, handle, .{ self, conn })) |t| {
                    self.conn_threads[self.conn_thread_count] = t;
                    self.conn_thread_count += 1;
                    continue;
                } else |_| {}
            }
            self.handle(conn);
            if (self.closed) return;
        }
    }

    /// Serve one connection until it ends.
    fn handle(self: *ScriptServer, conn: std.net.Server.Connection) void {
        defer conn.stream.close();
        {
            while (true) {
                var req: Request = undefined;
                OkServer.readAll(conn.stream, req.bytes[0..32]) catch break;
                const payload_length = std.mem.readInt(u32, req.bytes[4..8], .little);
                const request_id = std.mem.readInt(u64, req.bytes[8..16], .little);
                req.op = @enumFromInt(std.mem.readInt(u16, req.bytes[20..22], .little));
                if (32 + payload_length > req.bytes.len) return;
                OkServer.readAll(conn.stream, req.bytes[32..][0..payload_length]) catch break;
                req.len = 32 + payload_length;

                const nth = blk: {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    const n = self.seen.get(req.op);
                    self.seen.set(req.op, n + 1);
                    break :blk n;
                };
                var action: Action = .{ .reply = .{ .status = 0 } };
                for (self.rules) |rule| {
                    if (rule.op == req.op and (rule.nth == null or rule.nth.? == nth)) {
                        action = rule.action;
                        break;
                    }
                }
                {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    if (self.count < self.log.len) {
                        self.log[self.count] = req;
                        self.count += 1;
                    }
                }
                switch (action) {
                    .drop => break,
                    .close => {
                        self.server.deinit();
                        self.closed = true;
                        return;
                    },
                    .stall => {
                        var buf: [256]u8 = undefined;
                        while ((conn.stream.read(&buf) catch 0) > 0) {}
                        break;
                    },
                    .reply => |r| {
                        if (r.delay_ms > 0) std.Thread.sleep(@as(u64, r.delay_ms) * std.time.ns_per_ms);
                        reply(conn.stream, request_id, r) catch break;
                    },
                }
            }
        }
    }

    fn reply(stream: std.net.Stream, request_id: u64, r: Reply) !void {
        var h = [_]u8{0} ** 32;
        std.mem.writeInt(u32, h[0..4], types.MAGIC, .little);
        std.mem.writeInt(u32, h[4..8], @intCast(r.body.len), .little);
        std.mem.writeInt(u64, h[8..16], request_id, .little);
        h[20] = types.VERSION;
        h[21] = r.status;
        h[22] = r.flags;
        std.mem.writeInt(u64, h[24..32], types.TABLE_HASH, .little);
        var crc = std.hash.crc.Crc32Iscsi.init();
        crc.update(h[0..16]);
        crc.update(h[20..32]);
        crc.update(r.body);
        std.mem.writeInt(u32, h[16..20], crc.final(), .little);
        try stream.writeAll(&h);
        try stream.writeAll(r.body);
    }
};

/// The value field of a request logged by ScriptServer, header included:
/// [header:32][ns_len:u16][ns][key_len:u16][key][value_len:u32][value]...
pub fn valueOf(req: []const u8) []const u8 {
    var off: usize = 32;
    off += 2 + std.mem.readInt(u16, req[off..][0..2], .little);
    off += 2 + std.mem.readInt(u16, req[off..][0..2], .little);
    const len = std.mem.readInt(u32, req[off..][0..4], .little);
    return req[off + 4 ..][0..len];
}

/// Whether two requests are the same apart from their request id and the
/// header CRC32C that covers it.
pub fn sameApartFromId(a: []const u8, b: []const u8) bool {
    if (a.len != b.len or a.len < 32) return false;
    return std.mem.eql(u8, a[0..8], b[0..8]) and std.mem.eql(u8, a[20..], b[20..]);
}

/// Overwrite the stack below the caller, as later calls would, so a pointer
/// into a returned function's frame no longer reads as what it held.
pub noinline fn clobberStack() void {
    var buf: [64 * 1024]u8 = undefined;
    @memset(&buf, 0xAA);
    std.mem.doNotOptimizeAway(&buf);
}
