const std = @import("std");
const grammars = @import("vendor/tree-sitter/grammars.zig");

// 把 vendored tree-sitter runtime + grammar 的 C 源接到一个 module 上。
// C 源挂在 module(非 exe)上,所以每个 root=src/main.zig 的 module 都要调一次:
// release/debug exe + test_module + integ/new 循环里的 cc_mod。
//
// 关键:只编 runtime/src/lib.c(摊销头,#include 其余运行时 .c;逐个编会重复符号)。
// 生成的 parser.c/scanner.c 会触发 UBSan → -fno-sanitize=undefined。
// scanner 全是纯 C(.c),无 C++,故不需要 link_libcpp。
//
// grammar 列表来自 `vendor/tree-sitter/grammars.zig`(单一真理源)——加语言只改那里。
fn addTreeSitter(b: *std.Build, mod: *std.Build.Module) void {
    const ts = "vendor/tree-sitter";
    mod.addIncludePath(b.path(ts ++ "/runtime/include"));
    mod.addIncludePath(b.path(ts ++ "/runtime/src"));
    const flags = &[_][]const u8{ "-std=c11", "-D_GNU_SOURCE", "-D_DEFAULT_SOURCE", "-fno-sanitize=undefined" };
    mod.addCSourceFile(.{ .file = b.path(ts ++ "/runtime/src/lib.c"), .flags = flags });
    inline for (grammars.GRAMMARS) |g| {
        mod.addIncludePath(b.path(ts ++ "/grammars/" ++ g.dir ++ "/src"));
        mod.addCSourceFile(.{ .file = b.path(ts ++ "/grammars/" ++ g.dir ++ "/src/parser.c"), .flags = flags });
        if (g.has_scanner) {
            mod.addCSourceFile(.{ .file = b.path(ts ++ "/grammars/" ++ g.dir ++ "/src/scanner.c"), .flags = flags });
        }
        inline for (g.extra_csources) |extra| {
            mod.addCSourceFile(.{ .file = b.path(ts ++ "/grammars/" ++ g.dir ++ "/src/" ++ extra), .flags = flags });
        }
    }
}

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
    addTreeSitter(b, release_mod);
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
    addTreeSitter(b, debug_mod);
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

    // ── metacodes-core 可复用库 module(root=src/lib.zig,UI 图不可达)──────────
    // 供其他 Zig 项目经 build.zig.zon 依赖 `@import("metacodes-core")`。
    // 经 tools/* 用 tree-sitter → 必须 addTreeSitter。
    const core_mod = b.addModule("metacodes-core", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addTreeSitter(b, core_mod);

    // test:lib —— 编译库全图(refAllDeclsRecursive),绿即证库与 UI 物理隔离。
    const core_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addTreeSitter(b, core_test_mod);
    const core_test = b.addTest(.{ .name = "metacodes-core-test", .root_module = core_test_mod });
    const core_test_step = b.step("test:lib", "Test/compile the metacodes-core library module (proves UI isolation)");
    core_test_step.dependOn(&b.addRunArtifact(core_test).step);

    // example —— 独立消费者,经 module 用库跑一轮 agent loop(见 example/main.zig)。
    const example_mod = b.createModule(.{
        .root_source_file = b.path("example/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addImport("metacodes-core", core_mod);
    // 注:不在 example_mod 上 addTreeSitter —— C 对象随 core_mod 传入,重复接会 duplicate symbol。
    const example_exe = b.addExecutable(.{ .name = "example", .root_module = example_mod });
    const example_step = b.step("example", "Build & run the metacodes-core example");
    example_step.dependOn(&b.addRunArtifact(example_exe).step);

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
    addTreeSitter(b, test_module);
    const tfilter = b.option([]const u8, "tfilter", "test filter");
    const test_obj = b.addTest(.{
        .name = "cc-test",
        .root_module = test_module,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
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
        const t = b.addTest(.{
            .name = "spike",
            .root_module = m,
            .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
        });
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
        "tests/component/web_search_test.zig",
        "tests/component/allowed_tools_test.zig",
        "tests/component/skill_fork_test.zig",
        "tests/component/prompt_tool_coupling_test.zig",
        "tests/component/http_error_test.zig",
        "tests/component/answer_queue_test.zig",
        "tests/component/base_url_flag_test.zig",
        "tests/component/task_error_test.zig",
        "tests/component/tool_loop_breaker_test.zig",
        "tests/component/plan_mode_inject_test.zig",
        "tests/component/user_context_inject_test.zig",
        "tests/component/memdir_inject_test.zig",
        "tests/component/agent_background_test.zig",
        "tests/component/skill_fileref_test.zig",
        "tests/component/transcript_roundtrip_test.zig",
        "tests/component/headless_json_test.zig",
        "tests/component/compound_perm_test.zig",
        "tests/component/protected_skill_inject_test.zig",
        "tests/component/read_state_test.zig",
        "tests/component/tool_concurrency_test.zig",
        "tests/component/tool_result_storage_test.zig",
        "tests/component/cache_break_test.zig",
        "tests/component/microcompact_test.zig",
        "tests/component/kg_integration_test.zig",
        "tests/component/goal_state_test.zig",
        "tests/component/auth_test.zig",
        "tests/component/schema_validation_test.zig",
        "tests/component/tool_schema_coverage_test.zig",
        "tests/component/tool_smoke_test.zig",
        "tests/component/compact_summary_test.zig",
        "tests/component/auto_compact_request_test.zig",
        "tests/component/render_region_test.zig",
        "tests/component/stream_retry_test.zig",
        "tests/component/ui_state_test.zig",
        "tests/component/ui_render_test.zig",
        "tests/component/ui_backend_test.zig",
        "tests/component/ui_multifrontend_test.zig",
        "tests/component/diagnostics_test.zig",
        "tests/component/provider_vtable_test.zig",
        "tests/component/capability_gate_test.zig",
        "tests/component/openai_provider_test.zig",
        "tests/component/gemini_provider_test.zig",
        "tests/component/background_main_test.zig",
        "tests/component/suspend_resume_test.zig",
        "tests/component/code_map_test.zig",
        "tests/component/find_symbol_test.zig",
        "tests/component/read_outline_test.zig",
        "tests/component/export_symbols_test.zig",
        "tests/component/edit_syntaxcheck_test.zig",
        "tests/component/diff_highlight_test.zig",
        "tests/component/prompt_override_test.zig",
        "tests/component/web_ui_test.zig",
        "tests/component/weak_model_test.zig",
        "tests/component/task_batch_test.zig",
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
        addTreeSitter(b, cc_mod);
        const t = b.addTest(.{
            .name = "integration",
            .root_module = m,
            .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
        });
        const run_t = b.addRunArtifact(t);
        run_t.step.dependOn(b.getInstallStep()); // 确保 mock_mcp_server 被 build
        spike_step.dependOn(&run_t.step);
    }

    test_step.dependOn(spike_step);

    // test:new —— 只跑本次 e2e 框架新增的 L2 component 测试(隔离运行,绕开主套件已知
    // 的 integration 挂起)。每个文件独立 artifact,带 cc + harness imports。
    const new_step = b.step("test:new", "Run only the new e2e-framework L2 component tests");
    const new_files = [_][]const u8{
        "tests/component/user_context_inject_test.zig",
        "tests/component/http_error_test.zig",
        "tests/component/answer_queue_test.zig",
        "tests/component/base_url_flag_test.zig",
        "tests/component/task_error_test.zig",
        "tests/component/tool_loop_breaker_test.zig",
        "tests/component/plan_mode_inject_test.zig",
        "tests/component/agent_background_test.zig",
        "tests/component/skill_fileref_test.zig",
        "tests/component/transcript_roundtrip_test.zig",
        "tests/component/headless_json_test.zig",
        "tests/component/compound_perm_test.zig",
        "tests/component/protected_skill_inject_test.zig",
        "tests/component/read_state_test.zig",
        "tests/component/tool_concurrency_test.zig",
        "tests/component/tool_result_storage_test.zig",
        "tests/component/cache_break_test.zig",
        "tests/component/microcompact_test.zig",
        "tests/component/goal_state_test.zig",
        "tests/component/auth_test.zig",
        "tests/component/schema_validation_test.zig",
        "tests/component/tool_schema_coverage_test.zig",
        "tests/component/tool_smoke_test.zig",
        "tests/component/compact_summary_test.zig",
        "tests/component/auto_compact_request_test.zig",
        "tests/component/render_region_test.zig",
        "tests/component/stream_retry_test.zig",
        "tests/component/ui_state_test.zig",
        "tests/component/ui_render_test.zig",
        "tests/component/ui_backend_test.zig",
        "tests/component/ui_multifrontend_test.zig",
        "tests/component/diagnostics_test.zig",
        "tests/component/provider_vtable_test.zig",
        "tests/component/capability_gate_test.zig",
        "tests/component/openai_provider_test.zig",
        "tests/component/gemini_provider_test.zig",
        "tests/component/background_main_test.zig",
        "tests/component/suspend_resume_test.zig",
        "tests/component/code_map_test.zig",
        "tests/component/find_symbol_test.zig",
        "tests/component/read_outline_test.zig",
        "tests/component/export_symbols_test.zig",
        "tests/component/edit_syntaxcheck_test.zig",
        "tests/component/diff_highlight_test.zig",
        "tests/component/prompt_override_test.zig",
        "tests/component/weak_model_test.zig",
        "tests/component/task_batch_test.zig",
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
        addTreeSitter(b, cc_mod);
        const t = b.addTest(.{
            .name = "new-l2",
            .root_module = m,
            .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
        });
        new_step.dependOn(&b.addRunArtifact(t).step);
    }

    // test:mem —— 记忆系统 L2 组件测试(隔离 artifact,绕开主套件 integration 挂起)。
    // 通道 A:user_context_inject;通道 B:memdir_inject。MockServer 断言端到端进请求体。
    const mem_step = b.step("test:mem", "Run memory-system L2 component tests (isolated)");
    {
        const mem_files = [_][]const u8{
            "tests/component/user_context_inject_test.zig",
            "tests/component/memdir_inject_test.zig",
        };
        for (mem_files) |f| {
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
            addTreeSitter(b, cc_mod);
            const t = b.addTest(.{
                .name = "mem-l2",
                .root_module = m,
                .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
            });
            mem_step.dependOn(&b.addRunArtifact(t).step);
        }
    }

    // test:ts —— 只跑 tree-sitter 相关 L1 单测(隔离 artifact,绕开主套件 integration 挂起)。
    // root=src/treesitter/test_root.zig 聚合 ts/symbols 等,接 addTreeSitter 链 C。
    const ts_step = b.step("test:ts", "Run tree-sitter L1 unit tests (isolated)");
    {
        const m = b.createModule(.{
            .root_source_file = b.path("src/treesitter/test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        addTreeSitter(b, m);
        const t = b.addTest(.{
            .name = "ts-l1",
            .root_module = m,
            .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
        });
        ts_step.dependOn(&b.addRunArtifact(t).step);
    }

    // 注:TTY 渲染测试(tests/tty/)用独立 python runner 跑,**不接 zig build**——
    // PTY(pty.fork)在 zig build-runner 的进程/stdio 监管下时序不稳(直接跑 12/12 全过,
    // 经 build SystemCommand 跑会大面积假失败)。跑法:
    //   zig build && python3 tests/tty/run_tty_tests.py --bin zig-out/bin/metacodes-debug
    // 这与 e2e(走 shell 而非 zig build)同理。

    // test:e2e-tty —— tty 真模型工具 e2e(cases/test_e2e_*.py)。与渲染测试不同:这些用例
    // 自建 PTY、断言靠落盘的 transcript.jsonl(非 build-runner 捕获的屏幕字节),所以经
    // SystemCommand 跑不受 PTY 时序假失败影响(已实测 stdin=/dev/null 下通过)。
    // 打真模型(napi.metask-ai.com,client.zig 硬编码 token)→ 默认应设 TTY_SKIP_MODEL=1
    // 跳过(CI/离线);显式 `TTY_SKIP_MODEL= zig build test:e2e-tty` 才真打模型、真副作用
    // (真联网/真排程/真发通知/真改 git)。先 build debug 二进制 + mock_mcp_server。
    const e2e_tty_step = b.step("test:e2e-tty", "Run tty real-model tool e2e (打真模型, 设 TTY_SKIP_MODEL=1 跳过)");
    const e2e_tty_cmd = b.addSystemCommand(&.{
        "python3", "tests/tty/run_tty_tests.py",
        "--bin",   "zig-out/bin/metacodes-debug",
        "-k",      "e2e_",
    });
    e2e_tty_cmd.step.dependOn(b.getInstallStep()); // 确保 metacodes-debug + mock_mcp_server 已 build
    e2e_tty_step.dependOn(&e2e_tty_cmd.step);

    _ = b.addFmt(.{
        .paths = &.{"src/"},
        .exclude_paths = &.{},
    });
}
