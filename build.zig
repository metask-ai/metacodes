const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 固定产出两个二进制：metacodes (ReleaseSmall) 和 metacodes-debug (Debug)。
    // 不受 -Doptimize 影响，一次 build 同时得到发布版和调试版。
    const release_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .link_libc = true,
    });
    const exe = b.addExecutable(.{
        .name = "metacodes",
        .root_module = release_mod,
    });
    b.installArtifact(exe);

    const debug_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    const debug_exe = b.addExecutable(.{
        .name = "metacodes-debug",
        .root_module = debug_mod,
    });
    b.installArtifact(debug_exe);

    // mock MCP server 二进制：测试专用，不 install。
    const mock_mcp_mod = b.createModule(.{
        .root_source_file = b.path("tests/_harness/mock_mcp_server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const mock_mcp_exe = b.addExecutable(.{
        .name = "mock_mcp_server",
        .root_module = mock_mcp_mod,
    });
    b.installArtifact(mock_mcp_exe);

    const run_step = b.step("run", "Run the release app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_debug_step = b.step("run-debug", "Run the debug app");
    const run_debug_cmd = b.addRunArtifact(debug_exe);
    run_debug_step.dependOn(&run_debug_cmd.step);
    if (b.args) |args| {
        run_debug_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Run tests");
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const test_obj = b.addTest(.{
        .name = "cc-test",
        .root_module = test_module,
    });
    const test_run = b.addRunArtifact(test_obj);
    test_step.dependOn(&test_run.step);

    // ------------------------------------------------------------------
    // Extra test step: spike / standalone harness files under tests/
    // Each file is compiled as an independent test artifact so main src
    // stays clean. Add new files here as they land.
    // ------------------------------------------------------------------
    const spike_step = b.step("test:spike", "Run spike / harness tests");
    const spike_files = [_][]const u8{
        "tests/unit/stream_reader_spike.zig",
        "tests/unit/termios_spike.zig",
        "tests/_harness/mock_sse_server.zig",
    };
    for (spike_files) |f| {
        const m = b.createModule(.{
            .root_source_file = b.path(f),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const t = b.addTest(.{ .name = "spike", .root_module = m });
        spike_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Integration / Component 测试:都需要 cc + harness imports,共享构建配置。
    // 目录区分用途:integration = 真子进程/真 fs;component = mock HTTP + 请求捕获(L2)。
    const integ_files = [_][]const u8{
        "tests/integration/http_stream_e2e_test.zig",
        "tests/integration/tool_abort_test.zig",
        "tests/integration/mcp_e2e_test.zig",
        "tests/integration/skills_e2e_test.zig",
        "tests/integration/agents_e2e_test.zig",
        "tests/component/subagent_model_test.zig",
        "tests/component/allowed_tools_test.zig",
        "tests/component/skill_fork_test.zig",
    };
    for (integ_files) |f| {
        const m = b.createModule(.{
            .root_source_file = b.path(f),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const harness_mod = b.createModule(.{
            .root_source_file = b.path("tests/_harness/mock_sse_server.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const cc_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        m.addImport("harness", harness_mod);
        m.addImport("cc", cc_mod);
        const t = b.addTest(.{ .name = "integration", .root_module = m });
        const run_t = b.addRunArtifact(t);
        run_t.step.dependOn(b.getInstallStep()); // 确保 mock_mcp_server 被 build
        spike_step.dependOn(&run_t.step);
    }

    test_step.dependOn(spike_step);

    _ = b.addFmt(.{
        .paths = &.{"src/"},
        .exclude_paths = &.{},
    });
}
