//! Retries of requests the server refused without running them, and the
//! waits between them.

const std = @import("std");
const types = @import("types.zig");

/// How often a request the server refused without running it is sent
/// again. Only a refusal whose status is overloaded or unavailable and whose
/// body says ran = no is retried: the server says it never ran, so resending
/// is safe for any operation, writes included. Each retry is a new request
/// with a new request id; the server routes it afresh.
pub const RetryPolicy = struct {
    /// Tries in all, the first included; 1 (or 0) turns retrying off.
    max_attempts: u32 = 4,
    /// Ceiling of the first wait; each later ceiling doubles, up to
    /// max_backoff_ms. Each wait is uniform in [0, ceiling].
    initial_backoff_ms: u64 = 50,
    max_backoff_ms: u64 = 1_000,

    /// The policy with max_backoff_ms raised to initial_backoff_ms if it was
    /// below it, so the ceiling only ever grows.
    pub fn normalized(self: RetryPolicy) RetryPolicy {
        var p = self;
        p.max_backoff_ms = @max(p.max_backoff_ms, p.initial_backoff_ms);
        return p;
    }
};

/// `ms` in nanoseconds, saturating: a huge backoff setting waits very long
/// rather than overflowing.
pub fn nsFromMs(ms: u64) u64 {
    return ms *| std.time.ns_per_ms;
}

/// Whether an answer with `status` and the refusal body's `ran` is one the
/// server says it didn't run, of a kind worth sending again.
pub fn isRefusedUnrun(status: types.StatusCode, ran: types.Ran) bool {
    return (status == .overloaded or status == .unavailable) and ran == .no;
}

/// A capped, doubling, fully jittered wait.
pub const Backoff = struct {
    initial_ms: u64,
    max_ms: u64,
    ceiling_ms: u64 = 0,

    /// Ceilings start at initial_ms and double up to max_ms (raised to
    /// initial_ms if below it).
    pub fn init(initial_ms: u64, max_ms: u64) Backoff {
        return .{ .initial_ms = initial_ms, .max_ms = @max(max_ms, initial_ms) };
    }

    /// The next wait in ms; doubles the ceiling for the one after.
    pub fn next(self: *Backoff, rand: std.Random) u64 {
        if (self.ceiling_ms == 0) self.ceiling_ms = self.initial_ms;
        const d = rand.uintAtMost(u64, self.ceiling_ms);
        self.ceiling_ms = @min(self.ceiling_ms *| 2, self.max_ms);
        return d;
    }

    /// Start the waits again from the initial ceiling.
    pub fn reset(self: *Backoff) void {
        self.ceiling_ms = 0;
    }
};

/// Worker poll loops wait this way after a failed poll, and start again
/// from the bottom after a poll that succeeds.
pub const worker_initial_backoff_ms: u64 = 100;
pub const worker_max_backoff_ms: u64 = 5_000;

pub fn workerBackoff() Backoff {
    return Backoff.init(worker_initial_backoff_ms, worker_max_backoff_ms);
}

/// A generator seeded from the OS, so clients started together don't wait
/// in step.
pub fn seededPrng() std.Random.DefaultPrng {
    var seed: u64 = undefined;
    std.crypto.random.bytes(std.mem.asBytes(&seed));
    return std.Random.DefaultPrng.init(seed);
}

test "isRefusedUnrun: only overloaded or unavailable with ran = no" {
    try std.testing.expect(isRefusedUnrun(.overloaded, .no));
    try std.testing.expect(isRefusedUnrun(.unavailable, .no));
    try std.testing.expect(!isRefusedUnrun(.overloaded, .unknown));
    try std.testing.expect(!isRefusedUnrun(.unavailable, .yes));
    try std.testing.expect(!isRefusedUnrun(.conflict, .no));
    try std.testing.expect(!isRefusedUnrun(.internal_error, .no));
}

test "Backoff waits stay under their doubling ceiling" {
    var prng = std.Random.DefaultPrng.init(1);
    var b = Backoff.init(50, 1_000);
    const ceilings = [_]u64{ 50, 100, 200, 400, 800, 1_000, 1_000 };
    for (0..200) |_| {
        b.reset();
        for (ceilings) |c| try std.testing.expect(b.next(prng.random()) <= c);
    }
}

test "a policy with max below initial waits at most initial" {
    const p = (RetryPolicy{ .initial_backoff_ms = 100, .max_backoff_ms = 10 }).normalized();
    try std.testing.expectEqual(@as(u64, 100), p.max_backoff_ms);
    var prng = std.Random.DefaultPrng.init(2);
    var b = Backoff.init(p.initial_backoff_ms, p.max_backoff_ms);
    var top: u64 = 0;
    for (0..500) |_| {
        const d = b.next(prng.random());
        try std.testing.expect(d <= 100);
        top = @max(top, d);
        try std.testing.expectEqual(@as(u64, 100), b.ceiling_ms);
    }
    // The ceiling held at 100 rather than dropping to 10.
    try std.testing.expect(top > 10);
    // A zero-length wait is still a valid bound.
    var zero = Backoff.init(0, 0);
    try std.testing.expectEqual(@as(u64, 0), zero.next(prng.random()));
}

test "a huge backoff converts to nanoseconds without overflowing" {
    try std.testing.expectEqual(@as(u64, 50 * std.time.ns_per_ms), nsFromMs(50));
    try std.testing.expectEqual(std.math.maxInt(u64), nsFromMs(std.math.maxInt(u64)));
}
