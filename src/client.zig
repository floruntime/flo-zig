//! Flo Client
//!
//! TCP connection management and request/response handling.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const wire = @import("wire.zig");
const retry = @import("retry.zig");

const Allocator = std.mem.Allocator;
const FloError = types.FloError;
const OpCode = types.OpCode;
const StatusCode = types.StatusCode;

/// Client configuration options
pub const ClientOptions = struct {
    /// Default namespace for operations (can be overridden per-operation)
    namespace: []const u8 = "default",
    /// The longest a request may go without the socket accepting or
    /// delivering any bytes, in milliseconds, plus its block_ms / wait_ms for
    /// blocking requests (an action await without block_ms counts as 30 s).
    /// It bounds silence, not the whole request. On expiry the call returns
    /// error.Timeout and the client disconnects. It bounds a connect too.
    /// 0 = no timeout. Not applied on Windows.
    timeout_ms: u32 = 5_000,
    /// Enable debug logging
    debug: bool = false,
    /// How a request the server refused without running it is sent again.
    /// `.{ .max_attempts = 1 }` turns retrying off.
    retry: retry.RetryPolicy = .{},
};

/// Flo client for communicating with the server
pub const Client = struct {
    allocator: Allocator,
    endpoint: []const u8,
    namespace: []const u8,
    stream: ?std.net.Stream = null,
    request_id: u64 = 1,
    timeout_ms: u32 = 5_000,
    debug: bool = false,
    last_error_code: u8 = 0,
    last_error_reason: types.Reason = .unclassified,
    last_error_ran: types.Ran = .no,
    last_error_len: usize = 0,
    last_error_buf: [512]u8 = undefined,
    foreign_server: ?ForeignServer = null,
    retry: retry.RetryPolicy = .{},
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),

    const Self = @This();

    /// A server built from another protocol version or op table, as its
    /// answer's header named it (`FloError.TableMismatch`).
    pub const ForeignServer = struct {
        version: u8,
        table_hash: u64,

        /// What to tell a person: both builds, and what to do.
        pub fn format(self: ForeignServer, w: *std.Io.Writer) std.Io.Writer.Error!void {
            if (self.version != types.VERSION) {
                try w.print("server protocol {d}, client protocol {d}: upgrade the client", .{ self.version, types.VERSION });
            } else {
                try w.print("server table 0x{x:0>16}, client table 0x{x:0>16}: upgrade the client", .{ self.table_hash, types.TABLE_HASH });
            }
        }
    };

    /// The last non-ok response: its numeric status, which names codes this
    /// SDK doesn't know, and the server's message from the body.
    pub const LastError = struct {
        code: u8,
        reason: types.Reason,
        /// Whether the request took effect.
        ran: types.Ran,
        message: []const u8,
    };

    /// Initialize a new client (does not connect)
    pub fn init(allocator: Allocator, endpoint: []const u8, options: ClientOptions) Self {
        return .{
            .allocator = allocator,
            .endpoint = endpoint,
            .namespace = options.namespace,
            .timeout_ms = options.timeout_ms,
            .debug = options.debug,
            .retry = options.retry.normalized(),
            .prng = retry.seededPrng(),
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.disconnect();
    }

    /// Connect to the Flo server
    pub fn connect(self: *Self) FloError!void {
        if (self.stream != null) return; // Already connected

        // Parse endpoint
        var host: []const u8 = undefined;
        var port_str: []const u8 = undefined;

        if (self.endpoint.len > 0 and self.endpoint[0] == '[') {
            // IPv6 bracketed form: [::1]:port
            const close_idx = std.mem.indexOf(u8, self.endpoint, "]") orelse return FloError.InvalidEndpoint;
            host = self.endpoint[1..close_idx];
            if (close_idx + 1 >= self.endpoint.len or self.endpoint[close_idx + 1] != ':') {
                return FloError.InvalidEndpoint;
            }
            port_str = self.endpoint[close_idx + 2 ..];
        } else {
            // Standard form: host:port
            const colon_idx = std.mem.indexOf(u8, self.endpoint, ":") orelse return FloError.InvalidEndpoint;
            host = self.endpoint[0..colon_idx];
            port_str = self.endpoint[colon_idx + 1 ..];
        }

        const port = std.fmt.parseInt(u16, port_str, 10) catch return FloError.InvalidEndpoint;

        // Resolve address
        const address = resolveAddress(host, port) catch return FloError.ConnectionFailed;

        self.stream = connectTo(address, self.timeout_ms) catch return FloError.ConnectionFailed;
    }

    /// Disconnect from the server
    pub fn disconnect(self: *Self) void {
        if (self.stream) |s| {
            s.close();
            self.stream = null;
        }
    }

    /// Forcibly close the TCP connection (unblocks any blocking operations).
    pub fn interrupt(self: *Self) void {
        self.disconnect();
    }

    /// Reconnect with exponential backoff.
    /// Retries up to ~5 minutes with delays: 1s, 2s, 4s, 8s, 16s, 30s (cap).
    pub fn reconnect(self: *Self) FloError!void {
        const always = true;
        return self.reconnectLoop(&always, null, 5 * 60 * 1_000);
    }

    /// `reconnect`, giving up with `FloError.ConnectionFailed` once
    /// `running` turns false or `halt`, if given, turns true; a wait between
    /// tries ends within about 10 ms.
    pub fn reconnectWhile(self: *Self, running: *const bool, halt: ?*const bool) FloError!void {
        return self.reconnectLoop(running, halt, 5 * 60 * 1_000);
    }

    /// `reconnect`, giving up with `FloError.ConnectionFailed` after about
    /// `max_total_ms`.
    pub fn reconnectFor(self: *Self, max_total_ms: u64) FloError!void {
        const always = true;
        return self.reconnectLoop(&always, null, max_total_ms);
    }

    fn reconnectLoop(self: *Self, running: *const bool, halt: ?*const bool, max_total_ms: u64) FloError!void {
        self.disconnect();

        const max_delay_ms: u64 = 30_000;
        var delay_ms: u64 = 1_000;
        var total_ms: u64 = 0;

        while (total_ms < max_total_ms and types.goingOn(running, halt)) {
            self.connect() catch {
                const wait_ms = @min(delay_ms, max_total_ms - total_ms);
                if (self.debug) {
                    std.log.info("[flo] Reconnect failed, retrying in {d}ms...", .{wait_ms});
                }
                types.pauseUnlessHalted(running, halt, wait_ms);
                total_ms += wait_ms;
                delay_ms = @min(delay_ms * 2, max_delay_ms);
                continue;
            };
            if (self.debug) {
                std.log.info("[flo] Reconnected successfully", .{});
            }
            return;
        }

        return FloError.ConnectionFailed;
    }

    /// Check if connected
    pub fn isConnected(self: *const Self) bool {
        return self.stream != null;
    }

    /// The largest request frame (header included) the server takes; a
    /// bigger one is refused with `FloError.PayloadTooLarge` before any byte
    /// goes out.
    pub const max_request_size = 256 * 1024;

    /// Send a request and receive response (low-level). A request the server
    /// refuses without running it is sent again, as `retry` allows; after
    /// the last try its refusal is returned like any other.
    pub fn sendRequest(
        self: *Self,
        op_code: OpCode,
        namespace: []const u8,
        key: []const u8,
        value: []const u8,
        options: []const u8,
    ) FloError!wire.RawResponse {
        var wait = retry.Backoff.init(self.retry.initial_backoff_ms, self.retry.max_backoff_ms);
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            var resp = try self.sendOnce(op_code, namespace, key, value, options);
            // last_error_ran is set only when the refusal's body decoded.
            if (attempt >= self.retry.max_attempts or self.last_error_code != @intFromEnum(resp.status) or
                !retry.isRefusedUnrun(resp.status, self.last_error_ran)) return resp;
            resp.deinit();
            const ms = wait.next(self.prng.random());
            if (self.debug) std.log.info("[flo] status {d}, not run: retrying in {d}ms", .{ self.last_error_code, ms });
            std.Thread.sleep(retry.nsFromMs(ms));
        }
    }

    /// Whether err is a refusal of the last request that the server says it
    /// didn't run, of a kind worth trying again later.
    pub fn refusedUnrun(self: *const Self, err: anyerror) bool {
        if (err != FloError.Overloaded and err != FloError.Unavailable) return false;
        const last = self.lastError() orelse return false;
        return retry.isRefusedUnrun(@enumFromInt(last.code), last.ran);
    }

    /// Send a request once, under a new request id, and receive its response.
    fn sendOnce(
        self: *Self,
        op_code: OpCode,
        namespace: []const u8,
        key: []const u8,
        value: []const u8,
        options: []const u8,
    ) FloError!wire.RawResponse {
        const stream = self.stream orelse return FloError.NotConnected;
        self.last_error_code = 0;

        // Serialize request: small ones on the stack, the rest on the heap.
        const size = wire.requestSize(op_code, namespace, key, value, options);
        if (size > max_request_size) return FloError.PayloadTooLarge;
        var stack_buf: [8192]u8 = undefined;
        const heap_buf: ?[]u8 = if (size > stack_buf.len) try self.allocator.alloc(u8, size) else null;
        defer if (heap_buf) |b| self.allocator.free(b);
        const serialized = try wire.serializeRequest(
            heap_buf orelse &stack_buf,
            self.request_id,
            op_code,
            namespace,
            key,
            value,
            options,
        );
        self.request_id += 1;

        const timeout_ms: u64 = if (self.timeout_ms == 0) 0 else @as(u64, self.timeout_ms) + blockingWaitMs(op_code, value, options);
        setSocketTimeout(stream.handle, timeout_ms) catch {
            self.disconnect();
            return FloError.ConnectionFailed;
        };

        // Send
        stream.writeAll(serialized) catch |err| return self.sendFailed(err);

        // Read response header
        var header_buf: [@sizeOf(wire.ResponseHeader)]u8 = undefined;
        readExact(stream, &header_buf) catch |err| return self.readFailed(err);

        const response_header = @as(*align(1) const wire.ResponseHeader, @ptrCast(&header_buf)).*;
        response_header.validate() catch |err| {
            // Another build's body can't be read: the connection is dropped
            // with it unread.
            if (err == FloError.TableMismatch) self.foreign_server = .{ .version = response_header.version, .table_hash = response_header.table_hash };
            self.disconnect();
            return err;
        };

        // Read response data
        const data: []u8 = if (response_header.data_len > 0) blk: {
            const buf = self.allocator.alloc(u8, response_header.data_len) catch {
                self.disconnect();
                return FloError.ServerError;
            };
            errdefer self.allocator.free(buf);
            readExact(stream, buf) catch |err| return self.readFailed(err);
            break :blk buf;
        } else &[_]u8{};

        if (response_header.computeCRC32C(data) != response_header.crc32c) {
            // The header's own fields may be the damaged part, data_len
            // among them, so what follows on the stream can't be trusted.
            if (data.len > 0) self.allocator.free(data);
            self.disconnect();
            return FloError.InvalidChecksum;
        }

        if (response_header.status != 0) {
            // A refusal's body: [reason:u16][ran:u8][message].
            const reason = if (data.len >= 3) std.enums.fromInt(types.Reason, std.mem.readInt(u16, data[0..2], .little)) else null;
            const ran = if (data.len >= 3) std.enums.fromInt(types.Ran, data[2]) else null;
            if (reason == null or ran == null) {
                // last_error_code was cleared when this request began, so
                // lastError names no earlier refusal.
                if (data.len > 0) self.allocator.free(data);
                return FloError.IncompleteResponse;
            }
            self.last_error_code = response_header.status;
            self.last_error_reason = reason.?;
            self.last_error_ran = ran.?;
            const message = data[3..];
            self.last_error_len = @min(message.len, self.last_error_buf.len);
            @memcpy(self.last_error_buf[0..self.last_error_len], message[0..self.last_error_len]);
        }

        return wire.RawResponse{
            .status = response_header.getStatus(),
            .data = data,
            .allocator = self.allocator,
        };
    }

    fn sendFailed(self: *Self, err: anyerror) FloError {
        // Part of the frame may be on the wire; the next request would be
        // read as its remainder.
        self.disconnect();
        return if (err == error.WouldBlock) FloError.Timeout else FloError.ConnectionFailed;
    }

    fn readFailed(self: *Self, err: anyerror) FloError {
        // Whatever is still unread (or still to arrive) would be read as the
        // start of the next request's reply.
        self.disconnect();
        return if (err == error.WouldBlock) FloError.Timeout else FloError.UnexpectedEof;
    }

    /// What the server said about the last request, if it wasn't ok. Zig
    /// errors carry no payload, so the reason lives here. The message is
    /// truncated to 512 bytes and valid until the next request. A call that
    /// turns a refusal into a value still leaves it here: kv.get returning
    /// null for a missing key leaves code 2 (not_found).
    pub fn lastError(self: *const Self) ?LastError {
        if (self.last_error_code == 0) return null;
        return .{ .code = self.last_error_code, .reason = self.last_error_reason, .ran = self.last_error_ran, .message = self.last_error_buf[0..self.last_error_len] };
    }

    /// Get the next request ID
    pub fn nextRequestId(self: *Self) u64 {
        const id = self.request_id;
        self.request_id += 1;
        return id;
    }

    /// Get effective namespace (override or default)
    pub fn getNamespace(self: *const Self, override: ?[]const u8) []const u8 {
        return override orelse self.namespace;
    }
};

/// Read exactly n bytes from stream
fn readExact(stream: std.net.Stream, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const bytes_read = try stream.read(buf[total..]);
        if (bytes_read == 0) return error.UnexpectedEof;
        total += bytes_read;
    }
}

/// Whether err leaves the connection unusable, so the caller has to
/// reconnect before its next request.
pub fn isConnectionError(err: anyerror) bool {
    return err == FloError.Timeout or err == FloError.NotConnected or
        err == FloError.UnexpectedEof or err == FloError.ConnectionFailed;
}

/// How long the server may hold a request on purpose: the longest block_ms /
/// wait_ms in its options, or for an action await without block_ms the
/// server's 30 s default; 0 if none.
fn blockingWaitMs(op_code: OpCode, value: []const u8, options: []const u8) u64 {
    // kv.get's body opens with wait_ms: [present:u8][u64].
    if (op_code == .kv_get) return if (value.len >= 9 and value[0] == 1) std.mem.readInt(u64, value[1..9], .little) else 0;
    var longest: u64 = 0;
    var has_block_ms = false;
    var it = wire.OptionsIterator.init(options);
    while (it.next()) |opt| {
        if (opt.tag != .block_ms) continue;
        has_block_ms = true;
        longest = @max(longest, opt.asU32() orelse 0);
    }
    if (op_code == .action_await and !has_block_ms) return types.DEFAULT_WORKER_BLOCK_MS;
    return longest;
}

/// Connect to `address`, giving up after `ms` (0: the OS's own timeout, also
/// on Windows). A host that drops packets would otherwise hold the caller
/// for the OS connect timeout, a minute or more.
fn connectTo(address: std.net.Address, ms: u32) !std.net.Stream {
    if (ms == 0 or builtin.os.tag == .windows) return std.net.tcpConnectToAddress(address);
    const posix = std.posix;
    const fd = try posix.socket(address.any.family, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    errdefer posix.close(fd);
    posix.connect(fd, &address.any, address.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock => {
            var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
            if (try posix.poll(&fds, @intCast(@min(ms, std.math.maxInt(i32)))) == 0) return error.ConnectionTimedOut;
            try posix.getsockoptError(fd);
        },
        else => return err,
    };
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(fd, posix.F.SETFL, flags & ~@as(usize, 1 << @bitOffsetOf(posix.O, "NONBLOCK")));
    return .{ .handle = fd };
}

/// Set the socket's send and receive timeouts; 0 means none.
fn setSocketTimeout(handle: std.posix.socket_t, ms: u64) !void {
    const posix = std.posix;
    // Zig's Windows sockets read through ReadFile, where a receive timeout
    // isn't reported as error.WouldBlock, so it couldn't become error.Timeout.
    if (builtin.os.tag == .windows) return;
    const tv = posix.timeval{
        .sec = @intCast(ms / std.time.ms_per_s),
        .usec = @intCast((ms % std.time.ms_per_s) * std.time.us_per_ms),
    };
    // Not posix.setsockopt: it treats EINVAL as unreachable, and macOS
    // returns EINVAL for a socket the peer has reset.
    for ([_]u32{ posix.SO.RCVTIMEO, posix.SO.SNDTIMEO }) |opt| {
        const rc = posix.system.setsockopt(handle, posix.SOL.SOCKET, opt, std.mem.asBytes(&tv), @sizeOf(posix.timeval));
        if (posix.errno(rc) != .SUCCESS) return error.SetSockOptFailed;
    }
}

/// Resolve hostname or IP to address
fn resolveAddress(host: []const u8, port: u16) !std.net.Address {
    // Try parsing as IP first
    return std.net.Address.parseIp(host, port) catch {
        // Fall back to DNS resolution
        var addr_list = try std.net.getAddressList(std.heap.page_allocator, host, port);
        defer addr_list.deinit();

        if (addr_list.addrs.len == 0) return error.HostLacksNetworkAddresses;

        // Prefer IPv4
        for (addr_list.addrs) |addr| {
            if (addr.any.family == std.posix.AF.INET) {
                return addr;
            }
        }

        return addr_list.addrs[0];
    };
}

// =============================================================================
// Tests
// =============================================================================

test "Client init" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, "localhost:9000", .{});
    defer client.deinit();

    try std.testing.expect(!client.isConnected());
    try std.testing.expectEqualStrings("default", client.namespace);
}

test "Client init with namespace" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, "localhost:9000", .{ .namespace = "myapp" });
    defer client.deinit();

    try std.testing.expectEqualStrings("myapp", client.namespace);
    try std.testing.expectEqualStrings("myapp", client.getNamespace(null));
    try std.testing.expectEqualStrings("override", client.getNamespace("override"));
}

test "resolveAddress IPv4" {
    const addr = try resolveAddress("127.0.0.1", 9000);
    try std.testing.expectEqual(std.posix.AF.INET, addr.any.family);
}

test "resolveAddress IPv6" {
    const addr = try resolveAddress("::1", 9000);
    try std.testing.expectEqual(std.posix.AF.INET6, addr.any.family);
}

/// A listener that never accepts: connects succeed, requests go unanswered.
/// If the client never gives up, closing the listener after a few seconds
/// resets the connection, so the call fails with something other than
/// error.Timeout instead of hanging the test run.
const SilentServer = struct {
    server: std.net.Server,
    done: std.Thread.ResetEvent = .{},
    watchdog: std.Thread = undefined,
    endpoint_buf: [32]u8 = undefined,
    endpoint: []const u8 = "",
    closed: bool = false,

    fn start(self: *SilentServer) !void {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        self.server = try addr.listen(.{});
        self.endpoint = try std.fmt.bufPrint(&self.endpoint_buf, "127.0.0.1:{d}", .{self.server.listen_address.getPort()});
        self.watchdog = try std.Thread.spawn(.{}, watch, .{self});
    }

    fn watch(self: *SilentServer) void {
        self.done.timedWait(5 * std.time.ns_per_s) catch {
            self.server.deinit();
            self.closed = true;
        };
    }

    fn stop(self: *SilentServer) void {
        self.done.set();
        self.watchdog.join();
        if (!self.closed) self.server.deinit();
    }
};

test "a request to a server that never answers fails with Timeout after timeout_ms" {
    var srv: SilentServer = .{ .server = undefined };
    try srv.start();
    defer srv.stop();

    var client = Client.init(std.testing.allocator, srv.endpoint, .{ .timeout_ms = 200 });
    defer client.deinit();
    try client.connect();

    var timer = try std.time.Timer.start();
    try std.testing.expectError(FloError.Timeout, client.sendRequest(.kv_get, "default", "k", "", ""));
    try std.testing.expect(timer.read() >= 150 * std.time.ns_per_ms);
    try std.testing.expect(!client.isConnected());
}

test "a blocking request waits timeout_ms plus its block_ms" {
    var srv: SilentServer = .{ .server = undefined };
    try srv.start();
    defer srv.stop();

    var client = Client.init(std.testing.allocator, srv.endpoint, .{ .timeout_ms = 100 });
    defer client.deinit();
    try client.connect();

    var opts_buf: [8]u8 = undefined;
    var opts = wire.OptionsBuilder.init(&opts_buf);
    try opts.addU32(.block_ms, 600);

    var timer = try std.time.Timer.start();
    try std.testing.expectError(FloError.Timeout, client.sendRequest(.queue_dequeue, "default", "k", "", opts.getOptions()));
    try std.testing.expect(timer.read() >= 650 * std.time.ns_per_ms);
}

test "an action await without block_ms is given the server's 30 s on top of timeout_ms" {
    try std.testing.expectEqual(@as(u64, 30_000), blockingWaitMs(.action_await, "", ""));

    var opts_buf: [8]u8 = undefined;
    var opts = wire.OptionsBuilder.init(&opts_buf);
    try opts.addU32(.block_ms, 0);
    try std.testing.expectEqual(@as(u64, 0), blockingWaitMs(.action_await, "", opts.getOptions()));
    try std.testing.expectEqual(@as(u64, 0), blockingWaitMs(.kv_get, "", ""));
    // kv.get's wait is its body's first field.
    var body: [9]u8 = undefined;
    body[0] = 1;
    std.mem.writeInt(u64, body[1..9], 5000, .little);
    try std.testing.expectEqual(@as(u64, 5000), blockingWaitMs(.kv_get, &body, ""));
}

test "an answer from another op table is refused unread, naming both tables" {
    // Answers the first request with an ok header from another table and a
    // body that would read as a value, then waits for the client to hang up.
    const Foreign = struct {
        server: std.net.Server,

        fn serve(self: *@This()) void {
            const conn = self.server.accept() catch return;
            defer conn.stream.close();
            var req: wire.RequestHeader = undefined;
            _ = conn.stream.readAtLeast(std.mem.asBytes(&req), @sizeOf(wire.RequestHeader)) catch return;
            const body = "\x07\x00\x00\x00\x00\x00\x00\x00v";
            var resp = std.mem.zeroes(wire.ResponseHeader);
            resp.magic = types.MAGIC;
            resp.version = types.VERSION;
            resp.table_hash = types.TABLE_HASH +% 1;
            resp.request_id = req.request_id;
            resp.data_len = body.len;
            resp.crc32c = resp.computeCRC32C(body);
            conn.stream.writeAll(std.mem.asBytes(&resp)) catch return;
            conn.stream.writeAll(body) catch return;
            var rest: [64]u8 = undefined;
            _ = conn.stream.read(&rest) catch {};
        }
    };
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var srv: Foreign = .{ .server = try addr.listen(.{}) };
    defer srv.server.deinit();
    const thread = try std.Thread.spawn(.{}, Foreign.serve, .{&srv});
    defer thread.join();

    var endpoint_buf: [32]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buf, "127.0.0.1:{d}", .{srv.server.listen_address.getPort()});
    var client = Client.init(std.testing.allocator, endpoint, .{ .timeout_ms = 1000 });
    defer client.deinit();
    try client.connect();

    try std.testing.expectError(FloError.TableMismatch, client.sendRequest(.kv_get, "default", "k", "", ""));
    try std.testing.expect(!client.isConnected());
    const foreign = client.foreign_server.?;
    try std.testing.expectEqual(types.TABLE_HASH +% 1, foreign.table_hash);
    var msg_buf: [128]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "{f}", .{foreign});
    var want_buf: [128]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "server table 0x{x:0>16}, client table 0x{x:0>16}: upgrade the client", .{ types.TABLE_HASH +% 1, types.TABLE_HASH });
    try std.testing.expectEqualStrings(want, msg);
}

test "a response body that stalls partway fails with Timeout" {
    // Answers the first request with a header for 100 bytes of data, sends
    // 3 of them, then goes quiet until the test is done.
    const Stalling = struct {
        server: std.net.Server,
        done: std.Thread.ResetEvent = .{},

        fn serve(self: *@This()) void {
            const conn = self.server.accept() catch return;
            defer conn.stream.close();
            var req: wire.RequestHeader = undefined;
            _ = conn.stream.readAtLeast(std.mem.asBytes(&req), @sizeOf(wire.RequestHeader)) catch return;
            var resp = std.mem.zeroes(wire.ResponseHeader);
            resp.magic = types.MAGIC;
            resp.version = types.VERSION;
            resp.table_hash = types.TABLE_HASH;
            resp.request_id = req.request_id;
            resp.data_len = 100;
            conn.stream.writeAll(std.mem.asBytes(&resp)) catch return;
            conn.stream.writeAll("abc") catch return;
            self.done.timedWait(5 * std.time.ns_per_s) catch {};
        }
    };
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var srv: Stalling = .{ .server = try addr.listen(.{}) };
    defer srv.server.deinit();
    const thread = try std.Thread.spawn(.{}, Stalling.serve, .{&srv});
    defer thread.join();
    defer srv.done.set();

    var endpoint_buf: [32]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buf, "127.0.0.1:{d}", .{srv.server.listen_address.getPort()});
    var client = Client.init(std.testing.allocator, endpoint, .{ .timeout_ms = 200 });
    defer client.deinit();
    try client.connect();

    try std.testing.expectError(FloError.Timeout, client.sendRequest(.kv_get, "default", "k", "", ""));
    try std.testing.expect(!client.isConnected());
}

/// Accepts one connection and never reads from it. Closes it when `release`
/// is set or after hold_ms, with zero linger if `reset` so the peer sees a
/// reset, then sets `closed`.
const HoldServer = struct {
    server: std.net.Server,
    hold_ms: u64 = 5_000,
    reset: bool = false,
    release: std.Thread.ResetEvent = .{},
    closed: std.Thread.ResetEvent = .{},
    thread: std.Thread = undefined,
    endpoint_buf: [32]u8 = undefined,
    endpoint: []const u8 = "",

    fn listen() !HoldServer {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        return .{ .server = try addr.listen(.{}) };
    }

    fn start(self: *HoldServer) !void {
        self.endpoint = try std.fmt.bufPrint(&self.endpoint_buf, "127.0.0.1:{d}", .{self.server.listen_address.getPort()});
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    fn serve(self: *HoldServer) void {
        const conn = self.server.accept() catch return;
        self.release.timedWait(self.hold_ms * std.time.ns_per_ms) catch {};
        if (self.reset) {
            const linger = extern struct { onoff: c_int, linger: c_int }{ .onoff = 1, .linger = 0 };
            std.posix.setsockopt(conn.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&linger)) catch {};
        }
        conn.stream.close();
        self.closed.set();
    }

    fn stop(self: *HoldServer) void {
        self.release.set();
        self.thread.join();
        self.server.deinit();
    }
};

test "isConnectionError: the errors after which a connection can't be reused" {
    for ([_]FloError{ FloError.Timeout, FloError.NotConnected, FloError.UnexpectedEof, FloError.ConnectionFailed }) |err| {
        try std.testing.expect(isConnectionError(err));
    }
    for ([_]FloError{ FloError.NotFound, FloError.BadRequest, FloError.ServerError }) |err| {
        try std.testing.expect(!isConnectionError(err));
    }
}

test "a request on a connection the server reset fails with ConnectionFailed and disconnects" {
    var srv = try HoldServer.listen();
    srv.reset = true;
    try srv.start();
    defer srv.stop();

    var client = Client.init(std.testing.allocator, srv.endpoint, .{ .timeout_ms = 1_000 });
    defer client.deinit();
    try client.connect();
    srv.release.set();
    srv.closed.wait();
    std.Thread.sleep(50 * std.time.ns_per_ms);

    try std.testing.expectError(FloError.ConnectionFailed, client.sendRequest(.kv_get, "default", "k", "", ""));
    try std.testing.expect(!client.isConnected());
}

test "a failed send disconnects; a send that would block is a Timeout" {
    var srv = try HoldServer.listen();
    try srv.start();
    defer srv.stop();

    var client = Client.init(std.testing.allocator, srv.endpoint, .{});
    defer client.deinit();

    try client.connect();
    try std.testing.expectEqual(FloError.ConnectionFailed, client.sendFailed(error.BrokenPipe));
    try std.testing.expect(!client.isConnected());

    try client.connect();
    try std.testing.expectEqual(FloError.Timeout, client.sendFailed(error.WouldBlock));
    try std.testing.expect(!client.isConnected());
}

test "a connection the server closes is dropped" {
    var srv = try HoldServer.listen();
    try srv.start();
    defer srv.stop();

    var client = Client.init(std.testing.allocator, srv.endpoint, .{ .timeout_ms = 1_000 });
    defer client.deinit();
    try client.connect();
    srv.release.set();
    srv.closed.wait();

    if (client.sendRequest(.kv_get, "default", "k", "", "")) |resp| {
        var r = resp;
        r.deinit();
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expect(err == FloError.UnexpectedEof or err == FloError.ConnectionFailed);
    }
    try std.testing.expect(!client.isConnected());
}

test "timeout_ms 0 never times out, even with a block_ms" {
    var srv = try HoldServer.listen();
    srv.hold_ms = 600;
    try srv.start();
    defer srv.stop();

    var client = Client.init(std.testing.allocator, srv.endpoint, .{ .timeout_ms = 0 });
    defer client.deinit();
    try client.connect();

    var opts_buf: [8]u8 = undefined;
    var opts = wire.OptionsBuilder.init(&opts_buf);
    try opts.addU32(.block_ms, 100);

    // The call ends only when the server hangs up.
    var timer = try std.time.Timer.start();
    try std.testing.expectError(FloError.UnexpectedEof, client.sendRequest(.queue_dequeue, "default", "k", "", opts.getOptions()));
    try std.testing.expect(timer.read() >= 500 * std.time.ns_per_ms);
}

test "two requests on one connection each read their whole response" {
    var srv = try @import("test_server.zig").OkServer.listen();
    try srv.start();
    defer srv.deinit();

    var client = Client.init(std.testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();

    for (0..2) |_| {
        var resp = try client.sendRequest(.kv_get, "default", "k", "", "");
        defer resp.deinit();
        try std.testing.expectEqual(StatusCode.ok, resp.status);
        try std.testing.expectEqual(@as(usize, 0), resp.data.len);
    }
    try std.testing.expectEqual(@as(u32, 2), srv.requests.load(.monotonic));
}

const fast_retry: retry.RetryPolicy = .{ .max_attempts = 4, .initial_backoff_ms = 1, .max_backoff_ms = 2 };

/// Sends one kv.get to a started server; returns the response's status, or
/// the error.
fn getThrough(srv: *@import("test_server.zig").OkServer, policy: retry.RetryPolicy) !StatusCode {
    var client = Client.init(std.testing.allocator, srv.endpoint, .{ .retry = policy });
    defer client.deinit();
    try client.connect();
    var resp = try client.sendRequest(.kv_get, "default", "k", "", "");
    defer resp.deinit();
    if (resp.status != .ok) {
        const last = client.lastError().?;
        try std.testing.expectEqual(@intFromEnum(resp.status), last.code);
        try std.testing.expectEqualStrings("busy", last.message);
    }
    return resp.status;
}

test "a refusal the server didn't run is sent again as a new request" {
    for ([_]u8{ 10, 12 }) |status| {
        var srv = try @import("test_server.zig").OkServer.listen();
        srv.replies = &.{.{ .status = status, .body = "\x0c\x00\x00busy" }};
        try srv.start();
        defer srv.deinit();
        try std.testing.expectEqual(StatusCode.ok, try getThrough(&srv, fast_retry));
        try std.testing.expectEqual(@as(u32, 2), srv.requests.load(.acquire));
        try std.testing.expect(srv.ids[0] != srv.ids[1]);
    }
}

test "only refusals that didn't run are retried" {
    const Case = struct { reply: @import("test_server.zig").Reply, want: anyerror!StatusCode };
    const cases = [_]Case{
        .{ .reply = .{ .status = 10, .body = "\x0c\x00\x02busy" }, .want = .overloaded }, // may have run
        .{ .reply = .{ .status = 12, .body = "\x0c\x00\x01busy" }, .want = .unavailable }, // ran
        .{ .reply = .{ .status = 8, .body = "\x0c\x00\x00busy" }, .want = .conflict },
        .{ .reply = .{ .status = 10, .body = "\x0c\x00" }, .want = FloError.IncompleteResponse }, // no ran byte
    };
    for (cases) |c| {
        var srv = try @import("test_server.zig").OkServer.listen();
        srv.replies = &.{ c.reply, c.reply, c.reply, c.reply };
        try srv.start();
        defer srv.deinit();
        const got = getThrough(&srv, fast_retry);
        if (c.want) |want| {
            try std.testing.expectEqual(want, try got);
        } else |err| try std.testing.expectError(err, got);
        try std.testing.expectEqual(@as(u32, 1), srv.requests.load(.acquire));
    }
}

test "retries stop at max_attempts and return the last refusal" {
    for ([_]u32{ 4, 1 }) |attempts| {
        var srv = try @import("test_server.zig").OkServer.listen();
        const refused: @import("test_server.zig").Reply = .{ .status = 10, .body = "\x0c\x00\x00busy" };
        srv.replies = &.{ refused, refused, refused, refused, refused };
        try srv.start();
        defer srv.deinit();
        var policy = fast_retry;
        policy.max_attempts = attempts;
        const status = try getThrough(&srv, policy);
        try std.testing.expectEqual(FloError.Overloaded, status.toError());
        try std.testing.expectEqual(attempts, srv.requests.load(.acquire));
    }
}

test "a client's retry policy is normalised: max below initial becomes initial" {
    var client = Client.init(std.testing.allocator, "localhost:9000", .{ .retry = .{ .initial_backoff_ms = 200, .max_backoff_ms = 5 } });
    defer client.deinit();
    try std.testing.expectEqual(@as(u64, 200), client.retry.max_backoff_ms);
}

test "an answer whose checksum doesn't match is refused" {
    var srv = try @import("test_server.zig").OkServer.listen();
    srv.replies = &.{.{ .status = 0, .body = "\x07\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00v\x00", .flip_body_byte = true }};
    try srv.start();
    defer srv.deinit();
    var client = Client.init(std.testing.allocator, srv.endpoint, .{ .retry = .{ .max_attempts = 1 } });
    defer client.deinit();
    try client.connect();
    try std.testing.expectError(FloError.InvalidChecksum, client.sendRequest(.kv_get, "default", "k", "", ""));
    try std.testing.expect(!client.isConnected());
}
