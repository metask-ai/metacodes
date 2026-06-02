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

    // replay_server 二进制(Stage 7):从 cassette 起 mock,供 e2e replay。测试专用。
    const replay_mod = b.createModule(.{
        .root_source_file = b.path("tests/_harness/replay_server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    replay_mod.addImport("harness", b.createModule(.{
        .root_source_file = b.path("tests/_harness/mock_sse_server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }));
    replay_mod.addImport("cassette", b.createModule(.{
        .root_source_file = b.path("tests/_harness/cassette.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }));
    const replay_exe = b.addExecutable(.{
        .name = "replay_server",
        .root_module = replay_mod,
    });
    b.installArtifact(replay_exe);

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
        "tests/component/prompt_tool_coupling_test.zig",
        "tests/component/http_error_test.zig",
        "tests/component/answer_queue_test.zig",
        "tests/component/base_url_flag_test.zig",
        "tests/component/task_error_test.zig",
        "tests/component/tool_loop_breaker_test.zig",
        "tests/component/agent_background_test.zig",
        "tests/component/render_region_test.zig",
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

    // test:new —— 只跑本次 e2e 框架新增的 L2 component 测试(隔离运行,绕开主套件已知
    // 的 integration 挂起)。每个文件独立 artifact,带 cc + harness imports。
    const new_step = b.step("test:new", "Run only the new e2e-framework L2 component tests");
    const new_files = [_][]const u8{
        "tests/component/http_error_test.zig",
        "tests/component/answer_queue_test.zig",
        "tests/component/base_url_flag_test.zig",
        "tests/component/task_error_test.zig",
        "tests/component/tool_loop_breaker_test.zig",
        "tests/component/agent_background_test.zig",
        "tests/component/render_region_test.zig",
    };
    for (new_files) |f| {
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
        const t = b.addTest(.{ .name = "new-l2", .root_module = m });
        new_step.dependOn(&b.addRunArtifact(t).step);
    }

    // 注:TTY 渲染测试(tests/tty/)用独立 python runner 跑,**不接 zig build**——
    // PTY(pty.fork)在 zig build-runner 的进程/stdio 监管下时序不稳(直接跑 12/12 全过,
    // 经 build SystemCommand 跑会大面积假失败)。跑法:
    //   zig build && python3 tests/tty/run_tty_tests.py --bin zig-out/bin/metacodes-debug
    // 这与 e2e(走 shell 而非 zig build)同理。

    _ = b.addFmt(.{
        .paths = &.{"src/"},
        .exclude_paths = &.{},
    });
}
