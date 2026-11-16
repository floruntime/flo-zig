//! Flo Time-Series Operations
//!
//! Write points, read a measurement field's points a page at a time (oldest
//! or newest first), aggregate them into windows, describe a measurement,
//! and run FloQL queries. Every time and window is nanoseconds, as i64, on
//! the way in and out.
//!
//! ```zig
//! var ts = flo.TimeSeries.init(&client);
//! _ = try ts.write("cpu", 0.5, .{ .tags = "host=a", .time_ns = 1_700_000_000_123_456_789 });
//! var it = ts.readAll("cpu", .{ .tags = "host=a" });
//! defer it.deinit();
//! while (try it.next()) |point| std.debug.print("{d} {d}\n", .{ point.time_ns, point.value });
//! ```

const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");
const Client = @import("client.zig").Client;
const kv = @import("kv.zig");
const Reader = kv.Reader;

const Allocator = std.mem.Allocator;
const FloError = types.FloError;

/// The most points one read page holds.
pub const MAX_READ: u32 = 4096;
/// A read's tag filter's longest text.
pub const MAX_TAG_FILTER: usize = 1024;
/// A read cursor's length. It is opaque: pass it back as it came.
pub const CURSOR_LEN: usize = 16;

/// Which way a read goes through the points.
pub const Order = enum(u8) { oldest_first = 0, newest_first = 1 };

/// One point: its time in Unix nanoseconds, and its value.
pub const Point = struct {
    time_ns: i64,
    value: f64,
};

pub const WriteOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// The field written; the server's default is "value".
    field: ?[]const u8 = null,
    /// The series' tags, "key=value" pairs separated by commas.
    tags: ?[]const u8 = null,
    /// The point's time in Unix nanoseconds; 0 for the server's time. One
    /// before 1970 (negative) is refused bad_request.
    time_ns: i64 = 0,
};

pub const WriteResult = struct {
    /// The point's time in Unix nanoseconds: the one given, or the server's.
    time_ns: i64,
    /// The write's position in its shard's log.
    sequence: u64,
};

pub const ReadOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    field: []const u8 = "value",
    /// Only series whose tags include every "key=value" pair of this
    /// comma-separated list; "" for every series. At most 1024 bytes.
    tags: []const u8 = "",
    /// The earliest time read, inclusive, in Unix ns (at least 0); null for
    /// the first point.
    from_ns: ?i64 = null,
    /// The latest time read, inclusive; null for the last point.
    to_ns: ?i64 = null,
    /// Most points on a page, 1 to 4096.
    limit: u32 = MAX_READ,
    order: Order = .oldest_first,
    /// The cursor the previous page returned; null for the first page.
    cursor: ?[]const u8 = null,
};

/// One page of points. Free with `deinit`.
pub const ReadPage = struct {
    /// Every matching series' points, merged in time order (then write
    /// order), or the reverse when newest first.
    points: []Point,
    /// Where the next page starts; null on the last page. A page can come
    /// back short, or empty, with a cursor: page until this is null.
    cursor: ?[]const u8,
    /// A stale read (see `GetResult.stale`).
    stale: bool = false,
    allocator: Allocator,

    pub fn deinit(self: *ReadPage) void {
        self.allocator.free(self.points);
        if (self.cursor) |c| self.allocator.free(c);
    }
};

/// Options for `floql` and `info`.
pub const FloQLOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
};

/// A FloQL answer's series. Free with `deinit`.
pub const FloQLResult = struct {
    series: []FloQLSeries,
    allocator: Allocator,

    pub fn deinit(self: *FloQLResult) void {
        for (self.series) |*s| s.free(self.allocator);
        self.allocator.free(self.series);
    }
};

pub const FloQLSeries = struct {
    key: []const u8,
    field: []const u8,
    points: []FloQLPoint,

    fn free(self: *FloQLSeries, allocator: Allocator) void {
        allocator.free(self.key);
        allocator.free(self.field);
        allocator.free(self.points);
    }
};

/// A FloQL point, its time in Unix nanoseconds.
pub const FloQLPoint = struct {
    time_ns: i64,
    value: f64,
};

pub const Aggregation = enum { avg, sum, count, min, max };

pub const QueryOptions = struct {
    /// Override client's default namespace
    namespace: ?[]const u8 = null,
    /// The field aggregated; the server's default is "value".
    field: ?[]const u8 = null,
    /// Only series whose tags include every "key=value" pair of this
    /// comma-separated list.
    tags: ?[]const u8 = null,
    /// The earliest time, inclusive, in Unix ns; null (or 0) for no bound.
    from_ns: ?i64 = null,
    /// The latest time, inclusive, in Unix ns; null (or 0) for no bound.
    to_ns: ?i64 = null,
    /// The window's width in ns; null for a minute. 0 or a negative width
    /// is refused, and so is one that makes more than 1024 windows.
    window_ns: ?i64 = null,
    aggregation: Aggregation = .avg,
};

/// One window's aggregate: the window's start, in Unix ns, aligned to the
/// epoch (time / window * window).
pub const Bucket = struct {
    start_ns: i64,
    value: f64,
};

/// A query's windows, oldest first; a window with no points is left out.
/// Free with `deinit`.
pub const QueryResult = struct {
    buckets: []Bucket,
    allocator: Allocator,

    pub fn deinit(self: *QueryResult) void {
        self.allocator.free(self.buckets);
    }
};

/// A measurement's summary. Free with `deinit`.
pub const Info = struct {
    /// Its series: each field of each tag set.
    series: u32,
    /// Its distinct fields, counted up to 256.
    field_count: u32,
    /// It has more fields than were counted or listed.
    fields_capped: bool,
    /// Its fields' names, up to 256 of them.
    fields: [][]const u8,
    points: u64,
    /// Its oldest and newest points' times, in Unix ns; null without points.
    oldest_ns: ?i64,
    newest_ns: ?i64,
    allocator: Allocator,

    pub fn deinit(self: *Info) void {
        for (self.fields) |f| self.allocator.free(f);
        self.allocator.free(self.fields);
    }
};

/// Time-series operations interface
pub const TimeSeries = struct {
    client: *Client,

    pub fn init(client: *Client) TimeSeries {
        return .{ .client = client };
    }

    /// Write one point to `measurement`.
    pub fn write(self: *TimeSeries, measurement: []const u8, value: f64, options: WriteOptions) FloError!WriteResult {
        var opts_buf: [3 * (2 + 255)]u8 = undefined;
        const opts = try encodeWriteOptions(&opts_buf, options);
        var value_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &value_buf, @bitCast(value), .little);
        var response = try self.client.sendRequest(.ts_write, self.client.getNamespace(options.namespace), measurement, &value_buf, opts);
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        return decodeWriteAnswer(response.data);
    }

    /// One page of a measurement field's points. Pass the returned
    /// `cursor` back for the next page, and stop when it is null, not when
    /// a page comes back short. A page continues strictly after the
    /// cursor (before it, newest first), so a point there for the whole
    /// read is read once. A field with no series matching the tag filter
    /// is `FloError.NotFound`; one with series but no points in range is
    /// an empty page. A not-found marked stale is `FloError.StaleNotFound`:
    /// the series may exist, but the node that answered hasn't seen it
    /// yet; read again rather than treat it as gone.
    /// **Caller owns the returned `ReadPage` and must call `page.deinit()`.**
    pub fn read(self: *TimeSeries, measurement: []const u8, options: ReadOptions) FloError!ReadPage {
        var buf: [MAX_READ_BODY]u8 = undefined;
        const body = try encodeReadBody(&buf, options);
        var response = try self.client.sendRequest(.ts_read, self.client.getNamespace(options.namespace), measurement, body, "");
        defer response.deinit();
        if (response.status != .ok) return kv.refusalError(self.client, &response);
        var page = try decodeReadAnswer(self.client.allocator, response.data);
        page.stale = response.stale;
        return page;
    }

    /// Every point `options` selects, page by page from `options.cursor`
    /// (null for the start). `measurement` and the option slices must
    /// outlive the iterator. A refusal, such as not found, is returned from
    /// `next`, never taken for the end.
    pub fn readAll(self: *TimeSeries, measurement: []const u8, options: ReadOptions) PointIterator {
        var it: PointIterator = .{ .ts = self.*, .measurement = measurement, .options = options };
        if (options.cursor) |c| {
            const n = @min(c.len, it.cursor_buf.len);
            @memcpy(it.cursor_buf[0..n], c[0..n]);
            it.cursor_len = c.len;
        }
        it.options.cursor = null;
        return it;
    }

    /// Aggregate a field's points into windows of `window_ns`.
    /// **Caller owns the returned `QueryResult` and must call `result.deinit()`.**
    pub fn query(self: *TimeSeries, measurement: []const u8, options: QueryOptions) FloError!QueryResult {
        var opts_buf: [2 * (2 + 255) + 3 * 10 + 2 + 5]u8 = undefined;
        const opts = try encodeQueryOptions(&opts_buf, options);
        var response = try self.client.sendRequest(.ts_query, self.client.getNamespace(options.namespace), measurement, "", opts);
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        return decodeQueryAnswer(self.client.allocator, response.data);
    }

    /// A measurement's series, fields, points and the times of its oldest
    /// and newest points. One with no series is `FloError.NotFound`.
    /// **Caller owns the returned `Info` and must call `info.deinit()`.**
    pub fn info(self: *TimeSeries, measurement: []const u8, options: FloQLOptions) FloError!Info {
        var response = try self.client.sendRequest(.ts_info, self.client.getNamespace(options.namespace), measurement, "", "");
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        return decodeInfoAnswer(self.client.allocator, response.data);
    }

    /// Run a FloQL query. In its text, a bare number in a range is epoch
    /// milliseconds (`cpu[1700000000000..1700000060000]`); `[1h]` and
    /// `[2h..1h]` count back from now. The answer's times are ns. An answer of more than 4096 raw points is
    /// refused bad_request (aggregate them, narrow the query, or page
    /// with `read`); `client.lastError()` carries the server's text.
    /// **Caller owns the returned `FloQLResult` and must call `result.deinit()`.**
    pub fn floql(self: *TimeSeries, text: []const u8, options: FloQLOptions) FloError!FloQLResult {
        var response = try self.client.sendRequest(.ts_floql, self.client.getNamespace(options.namespace), "", text, "");
        defer response.deinit();
        if (response.status != .ok) return response.status.toError();
        return decodeFloQLAnswer(self.client.allocator, response.data);
    }
};

/// Walks pages of a read. Free with `deinit`.
pub const PointIterator = struct {
    ts: TimeSeries,
    measurement: []const u8,
    options: ReadOptions,
    cursor_buf: [CURSOR_LEN]u8 = undefined,
    /// The cursor to read from; may be any length the caller passed, so
    /// the server refuses a bad one rather than this iterator guessing.
    cursor_len: usize = 0,
    page: ?ReadPage = null,
    index: usize = 0,
    done: bool = false,

    /// The next point, or null once a page answers no cursor.
    pub fn next(self: *PointIterator) FloError!?Point {
        while (true) {
            if (self.page) |*p| {
                if (self.index < p.points.len) {
                    defer self.index += 1;
                    return p.points[self.index];
                }
                const more = p.cursor;
                if (more) |c| {
                    // A cursor is CURSOR_LEN bytes; decode refused anything longer.
                    @memcpy(self.cursor_buf[0..c.len], c);
                    self.cursor_len = c.len;
                }
                p.deinit();
                self.page = null;
                if (more == null) self.done = true;
            }
            if (self.done) return null;
            var options = self.options;
            if (self.cursor_len > 0) {
                if (self.cursor_len > CURSOR_LEN) return FloError.BadRequest;
                options.cursor = self.cursor_buf[0..self.cursor_len];
            }
            self.page = try self.ts.read(self.measurement, options);
            self.index = 0;
        }
    }

    pub fn deinit(self: *PointIterator) void {
        if (self.page) |*p| p.deinit();
        self.page = null;
    }
};

// =============================================================================
// Encoding
// =============================================================================

fn encodeWriteOptions(buf: []u8, options: WriteOptions) FloError![]const u8 {
    var builder = wire.OptionsBuilder.init(buf);
    if (options.field) |f| try builder.addBytes(.ts_field, f);
    if (options.tags) |t| try builder.addBytes(.ts_tags, t);
    // 0 is the server's time; the option is left out for it.
    if (options.time_ns != 0) try builder.addU64(.ts_timestamp_ns, @bitCast(options.time_ns));
    return builder.getOptions();
}

fn encodeQueryOptions(buf: []u8, options: QueryOptions) FloError![]const u8 {
    var builder = wire.OptionsBuilder.init(buf);
    if (options.field) |f| try builder.addBytes(.ts_field, f);
    if (options.tags) |t| try builder.addBytes(.ts_tags, t);
    if (options.from_ns) |t| try builder.addU64(.ts_from_ns, @bitCast(t));
    if (options.to_ns) |t| try builder.addU64(.ts_to_ns, @bitCast(t));
    if (options.window_ns) |w| try builder.addU64(.ts_window_ns, @bitCast(w));
    try builder.addBytes(.ts_aggregation, @tagName(options.aggregation));
    return builder.getOptions();
}

/// field, tags, from_ns, to_ns, limit, order, cursor.
const MAX_READ_BODY = (1 + 2 + types.MAX_KEY_SIZE) + (1 + 2 + MAX_TAG_FILTER) + 9 + 9 + 5 + 2 + (1 + 1 + CURSOR_LEN);

/// ts.read's request, each field in the op's order: defaulted fields are
/// sent present, an optional one as a presence byte then its value.
fn encodeReadBody(buf: *[MAX_READ_BODY]u8, options: ReadOptions) FloError![]const u8 {
    if (options.limit < 1 or options.limit > MAX_READ) return FloError.BadRequest;
    if (options.field.len > types.MAX_KEY_SIZE) return FloError.KeyTooLarge;
    if (options.tags.len > MAX_TAG_FILTER) return FloError.BadRequest;
    if ((options.from_ns orelse 0) < 0 or (options.to_ns orelse 0) < 0) return FloError.BadRequest;
    const cursor = options.cursor orelse "";
    if (cursor.len > CURSOR_LEN) return FloError.BadRequest;
    var w: Writer = .{ .buf = buf };
    w.put(&.{1});
    w.lenBytes(u16, options.field);
    w.put(&.{1});
    w.lenBytes(u16, options.tags);
    w.optI64(options.from_ns);
    w.optI64(options.to_ns);
    w.put(&.{1});
    w.int(u32, options.limit);
    w.put(&.{ 1, @intFromEnum(options.order) });
    w.put(&.{1});
    w.lenBytes(u8, cursor);
    return w.buf[0..w.pos];
}

const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    fn put(w: *Writer, bytes: []const u8) void {
        @memcpy(w.buf[w.pos..][0..bytes.len], bytes);
        w.pos += bytes.len;
    }
    fn int(w: *Writer, comptime T: type, v: T) void {
        std.mem.writeInt(T, w.buf[w.pos..][0..@sizeOf(T)], v, .little);
        w.pos += @sizeOf(T);
    }
    fn lenBytes(w: *Writer, comptime Len: type, bytes: []const u8) void {
        w.int(Len, @intCast(bytes.len));
        w.put(bytes);
    }
    fn optI64(w: *Writer, v: ?i64) void {
        if (v) |x| {
            w.put(&.{1});
            w.int(i64, x);
        } else w.put(&.{0});
    }
};

// =============================================================================
// Decoding
// =============================================================================

/// ts.write's answer: [series_hash:u64][time_ns:i64][sequence:u64].
fn decodeWriteAnswer(data: []const u8) FloError!WriteResult {
    var r: Reader = .{ .data = data };
    _ = try r.int(u64);
    const time_ns = try r.int(i64);
    const sequence = try r.int(u64);
    try r.end();
    return .{ .time_ns = time_ns, .sequence = sequence };
}

/// ts.read's answer: points as [count:u16]([time_ns:i64][value:f64])*,
/// then cursor, optional, at most 16 bytes with a u8 length.
fn decodeReadAnswer(allocator: Allocator, data: []const u8) FloError!ReadPage {
    var r: Reader = .{ .data = data };
    const count = try r.int(u16);
    if (count > MAX_READ or @as(usize, count) * 16 > r.remaining()) return FloError.IncompleteResponse;
    const points = try allocator.alloc(Point, count);
    errdefer allocator.free(points);
    for (points) |*p| p.* = .{ .time_ns = try r.int(i64), .value = @bitCast(try r.int(u64)) };
    var cursor: ?[]const u8 = null;
    if (try r.boolean()) {
        const c = try r.lenBytes(u8);
        if (c.len > CURSOR_LEN) return FloError.UnexpectedResponse;
        cursor = c;
    }
    try r.end();
    return .{ .points = points, .cursor = if (cursor) |c| try allocator.dupe(u8, c) else null, .allocator = allocator };
}

/// ts.query's answer: [series:u32], 0 or 1, then for the one
/// [name_len:u32][name][buckets:u32]([start_ns:i64][value:f64])*.
fn decodeQueryAnswer(allocator: Allocator, data: []const u8) FloError!QueryResult {
    var r: Reader = .{ .data = data };
    const series = try r.int(u32);
    if (series > 1) return FloError.UnexpectedResponse;
    var buckets: []Bucket = &.{};
    if (series == 1) {
        _ = try r.lenBytes(u32);
        const n = try r.int(u32);
        if (n > r.remaining() / 16) return FloError.IncompleteResponse;
        buckets = try allocator.alloc(Bucket, n);
        for (buckets) |*b| b.* = .{ .start_ns = r.int(i64) catch unreachable, .value = @bitCast(r.int(u64) catch unreachable) };
    } else buckets = try allocator.alloc(Bucket, 0);
    errdefer allocator.free(buckets);
    try r.end();
    return .{ .buckets = buckets, .allocator = allocator };
}

/// ts.info's answer: series, field_count, fields_capped, fields
/// ([count:u16]([len:u16][name])*), points, oldest_ns, newest_ns.
fn decodeInfoAnswer(allocator: Allocator, data: []const u8) FloError!Info {
    var r: Reader = .{ .data = data };
    const series = try r.int(u32);
    const field_count = try r.int(u32);
    const fields_capped = try r.boolean();
    const count = try r.int(u16);
    if (count > r.remaining() / 2) return FloError.IncompleteResponse;
    const fields = try allocator.alloc([]const u8, count);
    var filled: usize = 0;
    errdefer {
        for (fields[0..filled]) |f| allocator.free(f);
        allocator.free(fields);
    }
    while (filled < count) : (filled += 1) fields[filled] = try allocator.dupe(u8, try r.lenBytes(u16));
    const points = try r.int(u64);
    const oldest_ns = try r.opt(i64);
    const newest_ns = try r.opt(i64);
    try r.end();
    return .{ .series = series, .field_count = field_count, .fields_capped = fields_capped, .fields = fields, .points = points, .oldest_ns = oldest_ns, .newest_ns = newest_ns, .allocator = allocator };
}

/// A FloQL answer: [series:u32]([key_len:u32][key][field_len:u32][field]
/// [points:u32]([time_ns:i64][value:f64])*)*.
fn decodeFloQLAnswer(allocator: Allocator, data: []const u8) FloError!FloQLResult {
    var r: Reader = .{ .data = data };
    const count = try r.int(u32);
    // A series takes at least its three lengths.
    if (count > r.remaining() / 12) return FloError.IncompleteResponse;
    const series = try allocator.alloc(FloQLSeries, count);
    var filled: usize = 0;
    errdefer {
        for (series[0..filled]) |*s| s.free(allocator);
        allocator.free(series);
    }
    while (filled < count) : (filled += 1) {
        const key = try r.lenBytes(u32);
        const field = try r.lenBytes(u32);
        const n = try r.int(u32);
        if (n > r.remaining() / 16) return FloError.IncompleteResponse;
        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);
        const field_copy = try allocator.dupe(u8, field);
        errdefer allocator.free(field_copy);
        const points = try allocator.alloc(FloQLPoint, n);
        for (points) |*p| p.* = .{ .time_ns = r.int(i64) catch unreachable, .value = @bitCast(r.int(u64) catch unreachable) };
        series[filled] = .{ .key = key_copy, .field = field_copy, .points = points };
    }
    try r.end();
    return .{ .series = series, .allocator = allocator };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const test_server = @import("test_server.zig");
const le = std.mem.toBytes;

fn pointBytes(comptime time_ns: i64, comptime value: f64) [16]u8 {
    return le(time_ns) ++ le(@as(u64, @bitCast(value)));
}

const cursor_a = "AAAAAAAAAAAAAAAA";
const cursor_b = "BBBBBBBBBBBBBBBB";

test "a read sends every field in the op's order" {
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{ .{ .status = 0, .body = "\x00\x00\x00" }, .{ .status = 0, .body = "\x00\x00\x00" } };
    try srv.start();
    defer srv.deinit();
    var client = Client.init(testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var ts = TimeSeries.init(&client);

    var page = try ts.read("cpu", .{ .field = "user", .tags = "host=a", .from_ns = 5, .to_ns = 1_700_000_000_123_456_789, .limit = 7, .order = .newest_first, .cursor = cursor_a });
    page.deinit();
    try testing.expectEqual(@as(u16, 0x1A1), srv.last_op);
    try testing.expectEqualStrings("cpu", srv.lastKey());
    try testing.expectEqualSlices(u8, "\x01\x04\x00user" ++ "\x01\x06\x00host=a" ++ "\x01" ++ le(@as(i64, 5)) ++ "\x01" ++ le(@as(i64, 1_700_000_000_123_456_789)) ++
        "\x01" ++ le(@as(u32, 7)) ++ "\x01\x01" ++ "\x01\x10" ++ cursor_a, srv.lastBody());

    // The defaults: "value", every series, no range, 4096, oldest first, no cursor.
    var first = try ts.read("cpu", .{});
    first.deinit();
    try testing.expectEqualSlices(u8, "\x01\x05\x00value" ++ "\x01\x00\x00" ++ "\x00" ++ "\x00" ++ "\x01" ++ le(@as(u32, 4096)) ++ "\x01\x00" ++ "\x01\x00", srv.lastBody());
}

test "a read refuses a limit, range, filter or cursor the server can't take, before sending" {
    var client = Client.init(testing.allocator, "127.0.0.1:1", .{});
    defer client.deinit();
    var ts = TimeSeries.init(&client);
    try testing.expectError(FloError.BadRequest, ts.read("cpu", .{ .limit = 0 }));
    try testing.expectError(FloError.BadRequest, ts.read("cpu", .{ .limit = 4097 }));
    try testing.expectError(FloError.BadRequest, ts.read("cpu", .{ .from_ns = -1 }));
    try testing.expectError(FloError.BadRequest, ts.read("cpu", .{ .tags = &([_]u8{'a'} ** 1025) }));
    try testing.expectError(FloError.BadRequest, ts.read("cpu", .{ .cursor = cursor_a ++ "x" }));
}

test "a read answer decodes with and without a cursor" {
    const a = testing.allocator;
    const two = "\x02\x00" ++ pointBytes(1_700_000_000_123_456_789, 1.5) ++ pointBytes(-3, -2.25);
    var with = try decodeReadAnswer(a, two ++ "\x01\x10" ++ cursor_a);
    defer with.deinit();
    try testing.expectEqual(@as(usize, 2), with.points.len);
    try testing.expectEqual(Point{ .time_ns = 1_700_000_000_123_456_789, .value = 1.5 }, with.points[0]);
    try testing.expectEqual(Point{ .time_ns = -3, .value = -2.25 }, with.points[1]);
    try testing.expectEqualStrings(cursor_a, with.cursor.?);

    var without = try decodeReadAnswer(a, two ++ "\x00");
    defer without.deinit();
    try testing.expect(without.cursor == null);

    // Cut anywhere, or overlong, it is refused.
    const full = two ++ "\x01\x10" ++ cursor_a;
    for (0..full.len) |n| try testing.expectError(FloError.IncompleteResponse, decodeReadAnswer(a, full[0..n]));
    try testing.expectError(FloError.IncompleteResponse, decodeReadAnswer(a, full ++ "\x00"));
    try testing.expectError(FloError.UnexpectedResponse, decodeReadAnswer(a, "\x00\x00\x01\x11" ++ cursor_a ++ "x"));
}

test "readAll pages until the cursor is none, not until a page comes back short, newest first" {
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{
        // A short page, then an empty one, both with a cursor; then the last.
        .{ .status = 0, .body = "\x01\x00" ++ pointBytes(30, 3) ++ "\x01\x10" ++ cursor_a },
        .{ .status = 0, .body = "\x00\x00" ++ "\x01\x10" ++ cursor_b },
        .{ .status = 0, .body = "\x02\x00" ++ pointBytes(20, 2) ++ pointBytes(10, 1) ++ "\x00" },
    };
    try srv.start();
    defer srv.deinit();
    var client = Client.init(testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var ts = TimeSeries.init(&client);

    var it = ts.readAll("cpu", .{ .limit = 2, .order = .newest_first });
    defer it.deinit();
    var times: [3]i64 = undefined;
    var n: usize = 0;
    while (try it.next()) |p| : (n += 1) times[n] = p.time_ns;
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(i64, &.{ 30, 20, 10 }, &times);
    try testing.expectEqual(@as(u32, 3), srv.requests.load(.acquire));
    // The last request carried the second page's cursor, newest first.
    const body = srv.lastBody();
    try testing.expectEqualSlices(u8, "\x01\x01" ++ "\x01\x10" ++ cursor_b, body[body.len - 20 ..]);
    // Done: no more requests.
    try testing.expectEqual(@as(?Point, null), try it.next());
    try testing.expectEqual(@as(u32, 3), srv.requests.load(.acquire));
}

test "a refused cursor is bad_request with the server's text, from read and from the iterator" {
    var srv = try test_server.OkServer.listen();
    const refusal: test_server.Reply = .{ .status = @intFromEnum(types.StatusCode.bad_request), .body = "\x02\x00\x00bad request: a cursor is the 16 bytes a page answered" };
    srv.replies = &.{ refusal, refusal };
    try srv.start();
    defer srv.deinit();
    var client = Client.init(testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var ts = TimeSeries.init(&client);
    try testing.expectError(FloError.BadRequest, ts.read("cpu", .{ .cursor = "short" }));
    try testing.expectEqualStrings("bad request: a cursor is the 16 bytes a page answered", client.lastError().?.message);
    var it = ts.readAll("cpu", .{ .cursor = "short" });
    defer it.deinit();
    try testing.expectError(FloError.BadRequest, it.next());
}

test "a read of a series that isn't there is error.NotFound; an empty page is ok" {
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{
        .{ .status = @intFromEnum(types.StatusCode.not_found), .body = "\x0d\x00\x00not found: 'cpu' has no series of field 'value'" },
        .{ .status = 0, .body = "\x00\x00\x00" },
    };
    try srv.start();
    defer srv.deinit();
    var client = Client.init(testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var ts = TimeSeries.init(&client);
    try testing.expectError(FloError.NotFound, ts.read("cpu", .{}));
    try testing.expectEqualStrings("not found: 'cpu' has no series of field 'value'", client.lastError().?.message);
    var empty = try ts.read("cpu", .{ .from_ns = 5, .to_ns = 6 });
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.points.len);
    try testing.expect(empty.cursor == null);
}

test "a not-found marked stale is StaleNotFound, from read and from the iterator; unmarked it stays NotFound" {
    var srv = try test_server.OkServer.listen();
    const missing = "\x0d\x00\x00not found: 'cpu' has no series of field 'value'";
    const not_found = @intFromEnum(types.StatusCode.not_found);
    srv.replies = &.{
        .{ .status = not_found, .body = missing, .flags = 1 },
        .{ .status = not_found, .body = missing },
        .{ .status = 0, .body = "\x01\x00" ++ pointBytes(1, 1) ++ "\x01\x10" ++ cursor_a },
        .{ .status = not_found, .body = missing, .flags = 1 },
    };
    try srv.start();
    defer srv.deinit();
    var client = Client.init(testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var ts = TimeSeries.init(&client);
    try testing.expectError(FloError.StaleNotFound, ts.read("cpu", .{}));
    try testing.expectError(FloError.NotFound, ts.read("cpu", .{}));
    var it = ts.readAll("cpu", .{});
    defer it.deinit();
    try testing.expectEqual(@as(i64, 1), (try it.next()).?.time_ns);
    try testing.expectError(FloError.StaleNotFound, it.next());
}

test "a not-found read ends the iterator with the error, not as the end" {
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{
        .{ .status = 0, .body = "\x01\x00" ++ pointBytes(1, 1) ++ "\x01\x10" ++ cursor_a },
        .{ .status = @intFromEnum(types.StatusCode.not_found), .body = "\x0d\x00\x00not found: no such measurement" },
    };
    try srv.start();
    defer srv.deinit();
    var client = Client.init(testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var ts = TimeSeries.init(&client);
    var it = ts.readAll("cpu", .{});
    defer it.deinit();
    try testing.expectEqual(@as(i64, 1), (try it.next()).?.time_ns);
    try testing.expectError(FloError.NotFound, it.next());
}

test "a write sends its time as an i64 of nanoseconds, a fraction of a ms included" {
    var srv = try test_server.OkServer.listen();
    srv.body = &(le(@as(u64, 0xabc)) ++ le(@as(i64, 1_700_000_000_123_456_789)) ++ le(@as(u64, 42)));
    try srv.start();
    defer srv.deinit();
    var client = Client.init(testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var ts = TimeSeries.init(&client);

    const got = try ts.write("cpu", 0.5, .{ .field = "user", .tags = "host=a", .time_ns = 1_700_000_000_123_456_789 });
    try testing.expectEqual(WriteResult{ .time_ns = 1_700_000_000_123_456_789, .sequence = 42 }, got);
    try testing.expectEqual(@as(u16, 0x1A0), srv.last_op);
    try testing.expectEqualStrings("cpu", srv.lastKey());
    try testing.expectEqualSlices(u8, &le(@as(f64, 0.5)), srv.lastValue());
    try testing.expectEqualSlices(u8, "\x64\x04user" ++ "\x65\x06host=a" ++ "\x67\x08" ++ le(@as(i64, 1_700_000_000_123_456_789)), srv.lastOptions());

    // No time: the server's, and no option.
    _ = try ts.write("cpu", 1, .{});
    try testing.expectEqualSlices(u8, "", srv.lastOptions());
}

test "a write before 1970 is the server's bad_request, with its text" {
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{.{ .status = @intFromEnum(types.StatusCode.bad_request), .body = "\x0c\x00\x00ts write: a point's time must not be before 1970" }};
    try srv.start();
    defer srv.deinit();
    var client = Client.init(testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var ts = TimeSeries.init(&client);
    try testing.expectError(FloError.BadRequest, ts.write("cpu", 1, .{ .time_ns = -1 }));
    try testing.expectEqualSlices(u8, "\x67\x08" ++ le(@as(i64, -1)), srv.lastOptions());
    try testing.expectEqualStrings("ts write: a point's time must not be before 1970", client.lastError().?.message);
}

test "a FloQL answer decodes; one cut anywhere or short of memory leaks nothing" {
    const a = testing.allocator;
    const answer = le(@as(u32, 1)) ++ le(@as(u32, 3)) ++ "cpu" ++ le(@as(u32, 5)) ++ "value" ++ le(@as(u32, 2)) ++
        le(@as(i64, 1000)) ++ le(@as(f64, 1.5)) ++ le(@as(i64, 1_700_000_000_123_456_789)) ++ le(@as(f64, 2.5));
    var got = try decodeFloQLAnswer(a, answer);
    defer got.deinit();
    try testing.expectEqual(@as(usize, 1), got.series.len);
    try testing.expectEqualStrings("cpu", got.series[0].key);
    try testing.expectEqualStrings("value", got.series[0].field);
    try testing.expectEqual(FloQLPoint{ .time_ns = 1_700_000_000_123_456_789, .value = 2.5 }, got.series[0].points[1]);
    for (0..answer.len) |n| try testing.expectError(FloError.IncompleteResponse, decodeFloQLAnswer(a, answer[0..n]));
    try testing.checkAllAllocationFailures(a, decodeAndFree, .{@as([]const u8, answer)});
}

fn decodeAndFree(a: Allocator, data: []const u8) !void {
    var r = try decodeFloQLAnswer(a, data);
    r.deinit();
}

test "a query sends its times and window as i64 ns, a fraction of a ms included, and decodes its buckets" {
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{
        .{ .status = 0, .body = &(le(@as(u32, 1)) ++ le(@as(u32, 3)) ++ "cpu".* ++ le(@as(u32, 2)) ++ le(@as(i64, 1_700_000_000_000_000_000)) ++ le(@as(f64, 1.5)) ++ le(@as(i64, 1_700_000_000_000_000_250)) ++ le(@as(f64, 4))) },
        .{ .status = 0, .body = &le(@as(u32, 0)) },
    };
    try srv.start();
    defer srv.deinit();
    var client = Client.init(testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var ts = TimeSeries.init(&client);

    var got = try ts.query("cpu", .{ .field = "user", .tags = "host=a", .from_ns = 1_700_000_000_000_000_001, .to_ns = 1_700_000_000_123_456_789, .window_ns = 250, .aggregation = .max });
    defer got.deinit();
    try testing.expectEqual(@as(u16, 0x1A2), srv.last_op);
    try testing.expectEqualStrings("cpu", srv.lastKey());
    try testing.expectEqualSlices(u8, "\x64\x04user" ++ "\x65\x06host=a" ++ "\x60\x08" ++ le(@as(i64, 1_700_000_000_000_000_001)) ++
        "\x61\x08" ++ le(@as(i64, 1_700_000_000_123_456_789)) ++ "\x62\x08" ++ le(@as(i64, 250)) ++ "\x63\x03max", srv.lastOptions());
    try testing.expectEqualSlices(Bucket, &.{ .{ .start_ns = 1_700_000_000_000_000_000, .value = 1.5 }, .{ .start_ns = 1_700_000_000_000_000_250, .value = 4 } }, got.buckets);

    // No bounds or window: the server's defaults; no windows answered.
    var none = try ts.query("cpu", .{});
    defer none.deinit();
    try testing.expectEqualSlices(u8, "\x63\x03avg", srv.lastOptions());
    try testing.expectEqual(@as(usize, 0), none.buckets.len);
}

test "a query whose window makes too many buckets is bad_request, with the server's text" {
    const text = "bad request: the range holds more than 1024 windows of this width; widen the window (it is in nanoseconds) or narrow the range";
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{.{ .status = @intFromEnum(types.StatusCode.bad_request), .body = "\x0c\x00\x00" ++ text }};
    try srv.start();
    defer srv.deinit();
    var client = Client.init(testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var ts = TimeSeries.init(&client);
    try testing.expectError(FloError.BadRequest, ts.query("cpu", .{ .window_ns = 1 }));
    try testing.expectEqualStrings(text, client.lastError().?.message);
}

test "a query answer cut anywhere is refused" {
    const answer = le(@as(u32, 1)) ++ le(@as(u32, 1)) ++ "c".* ++ le(@as(u32, 1)) ++ le(@as(i64, 5)) ++ le(@as(f64, 1));
    for (0..answer.len) |n| try testing.expectError(FloError.IncompleteResponse, decodeQueryAnswer(testing.allocator, answer[0..n]));
    try testing.expectError(FloError.UnexpectedResponse, decodeQueryAnswer(testing.allocator, &le(@as(u32, 2))));
}

const info_answer = le(@as(u32, 3)) ++ le(@as(u32, 2)) ++ "\x00".* ++ le(@as(u16, 2)) ++ le(@as(u16, 4)) ++ "user".* ++ le(@as(u16, 5)) ++ "value".* ++
    le(@as(u64, 9)) ++ "\x01".* ++ le(@as(i64, 1_700_000_000_123_456_789)) ++ "\x01".* ++ le(@as(i64, 1_700_000_000_999_999_999));

test "info is a table op with no body, and its answer's times are ns" {
    var srv = try test_server.OkServer.listen();
    srv.replies = &.{
        .{ .status = 0, .body = &info_answer },
        .{ .status = 0, .body = &(le(@as(u32, 0)) ++ le(@as(u32, 0)) ++ "\x00".* ++ le(@as(u16, 0)) ++ le(@as(u64, 0)) ++ "\x00\x00".*) },
    };
    try srv.start();
    defer srv.deinit();
    var client = Client.init(testing.allocator, srv.endpoint, .{});
    defer client.deinit();
    try client.connect();
    var ts = TimeSeries.init(&client);
    var got = try ts.info("cpu", .{});
    defer got.deinit();
    try testing.expectEqual(@as(u16, 0x1A7), srv.last_op);
    try testing.expectEqualStrings("cpu", srv.lastKey());
    try testing.expectEqualSlices(u8, "", srv.lastBody());
    try testing.expectEqual(@as(u32, 3), got.series);
    try testing.expectEqual(@as(usize, 2), got.fields.len);
    try testing.expectEqualStrings("value", got.fields[1]);
    try testing.expectEqual(@as(u64, 9), got.points);
    try testing.expectEqual(@as(?i64, 1_700_000_000_123_456_789), got.oldest_ns);
    try testing.expectEqual(@as(?i64, 1_700_000_000_999_999_999), got.newest_ns);
    var empty = try ts.info("cpu", .{});
    defer empty.deinit();
    try testing.expectEqual(@as(?i64, null), empty.oldest_ns);
}

fn infoAndFree(a: Allocator, data: []const u8) !void {
    var i = try decodeInfoAnswer(a, data);
    i.deinit();
}

test "an info answer cut anywhere or short of memory leaks nothing" {
    for (0..info_answer.len) |n| try testing.expectError(FloError.IncompleteResponse, infoAndFree(testing.allocator, info_answer[0..n]));
    try testing.checkAllAllocationFailures(testing.allocator, infoAndFree, .{@as([]const u8, &info_answer)});
}
