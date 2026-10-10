//! Flo Queue Operations
//!
//! Message queue operations: enqueue, dequeue, ack, nack, DLQ management.

const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");
const Client = @import("client.zig").Client;

const Allocator = std.mem.Allocator;
const FloError = types.FloError;

/// Queue operations interface
pub const Queue = struct {
    client: *Client,

    pub fn init(client: *Client) Queue {
        return .{ .client = client };
    }

    /// Enqueue a message to a queue.
    /// Returns the message sequence number.
    pub fn enqueue(
        self: *Queue,
        queue_name: []const u8,
        payload: []const u8,
        options: types.EnqueueOptions,
    ) FloError!u64 {
        const ns = self.client.getNamespace(options.namespace);

        var opts_buf: [64]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);

        try builder.addU8(.priority, options.priority);

        var response = try self.client.sendRequest(
            .queue_enqueue,
            ns,
            queue_name,
            payload,
            builder.getOptions(),
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }

        // Parse response to get sequence number
        if (response.data.len >= 8) {
            return std.mem.readInt(u64, response.data[0..8], .little);
        }

        return 0;
    }

    /// Dequeue messages from a queue.
    /// **Caller owns the returned `DequeueResult` and must call `result.deinit()`.**
    pub fn dequeue(
        self: *Queue,
        queue_name: []const u8,
        count: u32,
        options: types.DequeueOptions,
    ) FloError!types.DequeueResult {
        const ns = self.client.getNamespace(options.namespace);

        var opts_buf: [48]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);

        try builder.addU32(.count, count);

        if (options.block_ms) |block| {
            try builder.addU32(.block_ms, block);
        }

        var response = try self.client.sendRequest(
            .queue_dequeue,
            ns,
            queue_name,
            "",
            builder.getOptions(),
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }

        return wire.parseDequeueResponse(self.client.allocator, response.data);
    }

    /// Acknowledge messages. Dequeue already acknowledges each message it
    /// hands out (queues are at-most-once), so this has no effect on one.
    pub fn ack(
        self: *Queue,
        queue_name: []const u8,
        seqs: []const u64,
        options: types.AckOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var value_buf: [4096]u8 = undefined;
        const value = try wire.serializeSeqs(&value_buf, seqs);

        var response = try self.client.sendRequest(
            .queue_complete,
            ns,
            queue_name,
            value,
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }
    }

    /// Negative acknowledge messages. Dequeue already acknowledged them, so
    /// this has no effect on a dequeued message and does not retry it.
    pub fn nack(
        self: *Queue,
        queue_name: []const u8,
        seqs: []const u64,
        options: types.NackOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var value_buf: [4096]u8 = undefined;
        const value = try wire.serializeSeqs(&value_buf, seqs);

        var response = try self.client.sendRequest(
            .queue_fail,
            ns,
            queue_name,
            value,
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }
    }

    /// List messages in the Dead Letter Queue.
    /// **Caller owns the returned `DequeueResult` and must call `result.deinit()`.**
    pub fn dlqList(
        self: *Queue,
        queue_name: []const u8,
        options: types.DlqListOptions,
    ) FloError!types.DequeueResult {
        const ns = self.client.getNamespace(options.namespace);

        var response = try self.client.sendRequest(
            .queue_dlq_list,
            ns,
            queue_name,
            "",
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }

        return wire.parseDequeueResponse(self.client.allocator, response.data);
    }

    /// Requeue messages from DLQ back to main queue. The server refuses this
    /// as not implemented.
    pub fn dlqRequeue(
        self: *Queue,
        queue_name: []const u8,
        seqs: []const u64,
        options: types.DlqRequeueOptions,
    ) FloError!void {
        const ns = self.client.getNamespace(options.namespace);

        var value_buf: [4096]u8 = undefined;
        const value = try wire.serializeSeqs(&value_buf, seqs);

        var response = try self.client.sendRequest(
            .queue_dlq_requeue,
            ns,
            queue_name,
            value,
            "",
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }
    }

    /// Peek at messages without creating leases (no visibility timeout).
    /// Messages remain available for dequeue by other consumers.
    /// **Caller owns the returned `DequeueResult` and must call `result.deinit()`.**
    pub fn peek(
        self: *Queue,
        queue_name: []const u8,
        count: u32,
        options: types.PeekOptions,
    ) FloError!types.DequeueResult {
        const ns = self.client.getNamespace(options.namespace);

        var opts_buf: [16]u8 = undefined;
        var builder = wire.OptionsBuilder.init(&opts_buf);

        try builder.addU32(.count, count);

        var response = try self.client.sendRequest(
            .queue_peek,
            ns,
            queue_name,
            "",
            builder.getOptions(),
        );
        defer response.deinit();

        if (response.status != .ok) {
            return response.status.toError();
        }

        return wire.parseDequeueResponse(self.client.allocator, response.data);
    }
};
