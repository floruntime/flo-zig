//! Example: High-level Worker API usage with the Flo Zig SDK
//!
//! This example demonstrates how to use the Worker to process actions.

const std = @import("std");
const flo = @import("flo");

// =============================================================================
// Data Types
// =============================================================================

const OrderItem = struct {
    sku: []const u8,
    quantity: u32,
    price: f64,
};

const OrderRequest = struct {
    order_id: []const u8,
    customer_id: []const u8,
    amount: f64,
    items: []const OrderItem,
};

const OrderResult = struct {
    order_id: []const u8,
    status: []const u8,
    processed_by: []const u8,
};

const NotificationRequest = struct {
    user_id: []const u8,
    channel: []const u8,
    message: []const u8,
};

// =============================================================================
// Action Handlers
// =============================================================================

/// Process an order - demonstrates long-running tasks with Touch.
fn processOrder(ctx: *flo.ActionContext) anyerror!flo.ActionHandlerResult {
    // Parse input
    const parsed = try ctx.json(OrderRequest);
    defer parsed.deinit();
    const req = parsed.value;

    std.log.info("Processing order {s} for customer {s} (amount: ${d:.2})", .{
        req.order_id,
        req.customer_id,
        req.amount,
    });

    // Simulate a long-running order processing task
    // For long tasks, periodically call Touch to extend the lease
    for (req.items, 0..) |item, i| {
        std.log.info("  Processing item {d}/{d}: {s} (qty: {d})", .{
            i + 1,
            req.items.len,
            item.sku,
            item.quantity,
        });

        // Simulate work for each item
        std.Thread.sleep(2 * std.time.ns_per_s);

        // Extend the lease every few items to prevent timeout
        // This is critical for long-running tasks
        if ((i + 1) % 3 == 0) {
            ctx.touch(30000) catch |err| {
                std.log.warn("Warning: failed to extend lease: {}", .{err});
            };
            std.log.info("  Extended lease for order {s}", .{req.order_id});
        }
    }

    // Return result
    const result = OrderResult{
        .order_id = req.order_id,
        .status = "processed",
        .processed_by = ctx.task_id,
    };

    return .{ .bytes = try ctx.toBytes(result) };
}

/// Send a notification - demonstrates simple action.
fn sendNotification(ctx: *flo.ActionContext) anyerror!flo.ActionHandlerResult {
    const parsed = try ctx.json(NotificationRequest);
    defer parsed.deinit();
    const req = parsed.value;

    std.log.info("Sending {s} notification to user {s}: {s}", .{
        req.channel,
        req.user_id,
        req.message,
    });

    // Simulate sending notification
    std.Thread.sleep(500 * std.time.ns_per_ms);

    const result = .{
        .success = true,
        .channel = req.channel,
        .user_id = req.user_id,
    };

    return .{ .bytes = try ctx.toBytes(result) };
}

/// Generate a report - demonstrates context usage.
fn generateReport(ctx: *flo.ActionContext) anyerror!flo.ActionHandlerResult {
    const ReportRequest = struct {
        type: []const u8 = "summary",
        date_range: []const u8 = "last_7_days",
    };

    const parsed = try ctx.json(ReportRequest);
    defer parsed.deinit();
    const req = parsed.value;

    std.log.info("Generating {s} report for {s} (attempt {d}, task {s})", .{
        req.type,
        req.date_range,
        ctx.attempt,
        ctx.task_id,
    });

    // Simulate report generation with progress
    const total_steps: u32 = 5;
    var step: u32 = 0;
    while (step < total_steps) : (step += 1) {
        std.log.info("  Report generation step {d}/{d}", .{ step + 1, total_steps });
        std.Thread.sleep(1 * std.time.ns_per_s);

        // Extend lease periodically
        if (step == 2) {
            try ctx.touch(30000);
        }
    }

    const result = .{
        .report_type = req.type,
        .date_range = req.date_range,
        .generated_at = ctx.created_at,
        .rows = @as(u32, 1500),
    };

    return .{ .bytes = try ctx.toBytes(result) };
}

/// Simple health check action.
fn healthCheck(ctx: *flo.ActionContext) anyerror!flo.ActionHandlerResult {
    const result = .{
        .status = "healthy",
        .worker_id = ctx.task_id,
        .timestamp = ctx.created_at,
    };

    return .{ .bytes = try ctx.toBytes(result) };
}

// =============================================================================
// Main
// =============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get configuration from environment
    const endpoint = std.posix.getenv("FLO_ENDPOINT") orelse "localhost:3000";
    const namespace = std.posix.getenv("FLO_NAMESPACE") orelse "myapp";

    // Create worker
    var worker = try flo.Worker.init(allocator, .{
        .endpoint = endpoint,
        .namespace = namespace,
        .concurrency = 5,
        .action_timeout_ms = 300_000, // 5 minutes
    });
    defer worker.deinit();

    // Register action handlers
    try worker.registerAction("process-order", processOrder);
    try worker.registerAction("send-notification", sendNotification);
    try worker.registerAction("generate-report", generateReport);
    try worker.registerAction("health-check", healthCheck);

    std.log.info("Starting worker...", .{});

    // Start worker (blocks until stopped)
    try worker.start();
}
