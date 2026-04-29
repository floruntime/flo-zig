//! Flo Client
//!
//! TCP connection management and request/response handling.

const std = @import("std");
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
    /// Connection/operation timeout in milliseconds (0 = no timeout, default: 5000)
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

        // Send
        stream.writeAll(serialized) catch return FloError.ConnectionFailed;

        // Read response header
        var header_buf: [24]u8 = undefined;
        readExact(stream, &header_buf) catch return FloError.UnexpectedEof;

        const response_header = @as(*align(1) const wire.ResponseHeader, @ptrCast(&header_buf)).*;
        try response_header.validate();

        // Read response data
        const data: []u8 = if (response_header.data_len > 0) blk: {
            const buf = self.allocator.alloc(u8, response_header.data_len) catch return FloError.ServerError;
            errdefer self.allocator.free(buf);
            readExact(stream, buf) catch {
                self.allocator.free(buf);
                return FloError.UnexpectedEof;
            };
            break :blk buf;
        } else &[_]u8{};

        return wire.RawResponse{
            .status = response_header.getStatus(),
            .data = data,
            .allocator = self.allocator,
        };
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
