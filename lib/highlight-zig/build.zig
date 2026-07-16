const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── 库 module（供消费方 addImport("hl", ...) 引用；主消费方式）──
    const hl_mod = b.addModule("hl", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── 静态库制品 libhighlight.a（独立可链接交付物）────────────
    // 纯 Zig API 主经 module 消费(见上);此 artifact 供需要独立 .a 的场景。
    const hl_lib = b.addLibrary(.{
        .name = "highlight",
        .linkage = .static,
        .root_module = hl_mod,
    });
    b.installArtifact(hl_lib);

    // ── 测试 ───────────────────────────────────────────────────
    const test_step = b.step("test", "Run all tests");

    const test_files = [_][]const u8{
        "tests/engine_test.zig",
        "tests/ansi_test.zig",
        "tests/rules_test.zig",
    };

    const tfilter = b.option([]const u8, "tfilter", "test filter");

    for (test_files) |f| {
        const m = b.createModule(.{
            .root_source_file = b.path(f),
            .target = target,
            .optimize = optimize,
        });
        m.addImport("hl", hl_mod);
        const t = b.addTest(.{
            .name = b.fmt("hl-test-{s}", .{std.fs.path.stem(f)}),
            .root_module = m,
            .filters = if (tfilter) |ft| &.{ft} else &.{},
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}