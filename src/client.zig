//! Flo Client
//!
//! TCP connection management and request/response handling.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const wire = @import("wire.zig");

const Allocator = std.mem.Allocator;
const FloError = types.FloError;
const OpCode = types.OpCode;
const StatusCode = types.StatusCode;

/// Client configuration options
pub const ClientOptions = struct {
    /// Default namespace for operations (can be overridden per-operation)
    namespace: []const u8 = "default",
    /// How long a request may wait on the socket, in milliseconds, plus its
    /// block_ms / wait_ms for blocking requests. On expiry the call returns
    /// error.Timeout and the client disconnects. 0 = no timeout.
    timeout_ms: u32 = 5_000,
    /// Enable debug logging
    debug: bool = false,
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

    const Self = @This();

    /// Initialize a new client (does not connect)
    pub fn init(allocator: Allocator, endpoint: []const u8, options: ClientOptions) Self {
        return .{
            .allocator = allocator,
            .endpoint = endpoint,
            .namespace = options.namespace,
            .timeout_ms = options.timeout_ms,
            .debug = options.debug,
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

        // Connect
        self.stream = std.net.tcpConnectToAddress(address) catch return FloError.ConnectionFailed;
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
        self.disconnect();

        const max_delay_ms: u64 = 30_000;
        const max_total_ms: u64 = 5 * 60 * 1_000;
        var delay_ms: u64 = 1_000;
        var total_ms: u64 = 0;

        while (total_ms < max_total_ms) {
            self.connect() catch {
                if (self.debug) {
                    std.log.info("[flo] Reconnect failed, retrying in {d}ms...", .{delay_ms});
                }
                std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                total_ms += delay_ms;
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

    /// Send a request and receive response (low-level)
    pub fn sendRequest(
        self: *Self,
        op_code: OpCode,
        namespace: []const u8,
        key: []const u8,
        value: []const u8,
        options: []const u8,
    ) FloError!wire.RawResponse {
        const stream = self.stream orelse return FloError.NotConnected;

        // Serialize request
        var send_buf: [8192]u8 = undefined;
        const serialized = try wire.serializeRequest(
            &send_buf,
            self.request_id,
            op_code,
            namespace,
            key,
            value,
            options,
        );
        self.request_id += 1;

        const timeout_ms: u64 = if (self.timeout_ms == 0) 0 else @as(u64, self.timeout_ms) + blockingWaitMs(options);
        setSocketTimeout(stream.handle, timeout_ms) catch return FloError.ConnectionFailed;

        // Send
        stream.writeAll(serialized) catch return FloError.ConnectionFailed;

        // Read response header
        var header_buf: [24]u8 = undefined;
        readExact(stream, &header_buf) catch |err| return self.readFailed(err);

        const response_header = @as(*align(1) const wire.ResponseHeader, @ptrCast(&header_buf)).*;
        try response_header.validate();

        // Read response data
        const data: []u8 = if (response_header.data_len > 0) blk: {
            const buf = self.allocator.alloc(u8, response_header.data_len) catch return FloError.ServerError;
            errdefer self.allocator.free(buf);
            readExact(stream, buf) catch |err| {
                self.allocator.free(buf);
                return self.readFailed(err);
            };
            break :blk buf;
        } else &[_]u8{};

        return wire.RawResponse{
            .status = response_header.getStatus(),
            .data = data,
            .allocator = self.allocator,
        };
    }

    fn readFailed(self: *Self, err: anyerror) FloError {
        if (err != error.WouldBlock) return FloError.UnexpectedEof;
        // The response may still arrive and would be read as the answer to
        // the next request.
        self.disconnect();
        return FloError.Timeout;
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

/// The longest block_ms / wait_ms in a request's options, 0 if none.
fn blockingWaitMs(options: []const u8) u64 {
    var longest: u64 = 0;
    var it = wire.OptionsIterator.init(options);
    while (it.next()) |opt| {
        if (opt.tag != .block_ms and opt.tag != .wait_ms) continue;
        longest = @max(longest, opt.asU32() orelse 0);
    }
    return longest;
}

/// Set the socket's send and receive timeouts; 0 means none.
fn setSocketTimeout(handle: std.posix.socket_t, ms: u64) !void {
    const posix = std.posix;
    if (builtin.os.tag == .windows) {
        const v: u32 = @intCast(@min(ms, std.math.maxInt(u32)));
        try posix.setsockopt(handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&v));
        try posix.setsockopt(handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&v));
    } else {
        const tv = posix.timeval{
            .sec = @intCast(ms / std.time.ms_per_s),
            .usec = @intCast((ms % std.time.ms_per_s) * std.time.us_per_ms),
        };
        try posix.setsockopt(handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
        try posix.setsockopt(handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv));
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
    try std.testing.expectError(FloError.Timeout, client.sendRequest(.kv_get, "default", "k", "", opts.getOptions()));
    try std.testing.expect(timer.read() >= 650 * std.time.ns_per_ms);
}
