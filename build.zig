const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library module
    const flo_module = b.createModule(.{
        .root_source_file = b.path("src/flo.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/flo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Basic example executable
    const basic_example_module = b.createModule(.{
        .root_source_file = b.path("examples/basic.zig"),
        .target = target,
        .optimize = optimize,
    });
    basic_example_module.addImport("flo", flo_module);

    const basic_example = b.addExecutable(.{
        .name = "example-basic",
        .root_module = basic_example_module,
    });

    const run_basic_example = b.addRunArtifact(basic_example);
    run_basic_example.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_basic_example.addArgs(args);
    }

    const run_step = b.step("run", "Run the basic example");
    run_step.dependOn(&run_basic_example.step);

    // Worker example executable
    const worker_example_module = b.createModule(.{
        .root_source_file = b.path("examples/worker.zig"),
        .target = target,
        .optimize = optimize,
    });
    worker_example_module.addImport("flo", flo_module);

    const worker_example = b.addExecutable(.{
        .name = "example-worker",
        .root_module = worker_example_module,
    });

    const run_worker_example = b.addRunArtifact(worker_example);
    run_worker_example.step.dependOn(b.getInstallStep());

    const run_worker_step = b.step("run-worker", "Run the worker example");
    run_worker_step.dependOn(&run_worker_example.step);

    // Stream Worker example executable
    const stream_worker_example_module = b.createModule(.{
        .root_source_file = b.path("examples/stream_worker.zig"),
        .target = target,
        .optimize = optimize,
    });
    stream_worker_example_module.addImport("flo", flo_module);

    const stream_worker_example = b.addExecutable(.{
        .name = "example-stream-worker",
        .root_module = stream_worker_example_module,
    });

    const run_stream_worker_example = b.addRunArtifact(stream_worker_example);
    run_stream_worker_example.step.dependOn(b.getInstallStep());

    const run_stream_worker_step = b.step("run-stream-worker", "Run the stream worker example");
    run_stream_worker_step.dependOn(&run_stream_worker_example.step);

    // Install examples
    b.installArtifact(basic_example);
    b.installArtifact(worker_example);
    b.installArtifact(stream_worker_example);
}
