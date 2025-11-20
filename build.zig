const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bchan_mod = b.addModule("bchan", .{
        .root_source_file = b.path("src/lib.zig"),
    });

    // Benchmarks – these must use the new code
    const bench_mpsc_mod = b.createModule(.{
        .root_source_file = b.path("benches/batch.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mpsc_mod.addImport("bchan", bchan_mod);

    const bench_mpsc = b.addExecutable(.{
        .name = "bench-mpsc",
        .root_module = bench_mpsc_mod,
    });
    b.installArtifact(bench_mpsc);

    const run_mpsc = b.addRunArtifact(bench_mpsc);
    run_mpsc.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_mpsc.addArgs(args);

    const step_mpsc = b.step("bench-mpsc", "Run mpsc benchmark");
    step_mpsc.dependOn(&run_mpsc.step);

    const bench_spsc_mod = b.createModule(.{
        .root_source_file = b.path("benches/spsc.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_spsc_mod.addImport("bchan", bchan_mod);

    const bench_spsc = b.addExecutable(.{
        .name = "bench-spsc",
        .root_module = bench_spsc_mod,
    });
    b.installArtifact(bench_spsc);

    const run_spsc = b.addRunArtifact(bench_spsc);
    run_spsc.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_spsc.addArgs(args);

    const step_spsc = b.step("bench-spsc", "Run spsc benchmark");
    step_spsc.dependOn(&run_spsc.step);

    const bench_vyukov_mod = b.createModule(.{
        .root_source_file = b.path("benches/mpsc_vyukov.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_vyukov_mod.addImport("bchan", bchan_mod);

    const bench_vyukov = b.addExecutable(.{
        .name = "bench-mpsc-vyukov",
        .root_module = bench_vyukov_mod,
    });
    b.installArtifact(bench_vyukov);

    const run_vyukov = b.addRunArtifact(bench_vyukov);
    run_vyukov.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_vyukov.addArgs(args);

    const step_vyukov = b.step("bench-mpsc-vyukov", "Run vyukov mpmc bench");
    step_vyukov.dependOn(&run_vyukov.step);

    // Tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("bchan", bchan_mod);

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Example
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/simple.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_mod.addImport("bchan", bchan_mod);

    const example = b.addExecutable(.{
        .name = "simple-example",
        .root_module = example_mod,
    });

    const run_example = b.addRunArtifact(example);
    const example_step = b.step("example", "Run simple example");
    example_step.dependOn(&run_example.step);
}
