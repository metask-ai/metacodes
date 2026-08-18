//! L2:自演化端到端(真 tinykg store + 真 Journal + MockServer provider)。
//!
//! selflearn-r2 生产观察:5 个 trial 满足 process_signal 触发谓词,却零
//! 提案且 provider 无 author 请求——降级点在 prepare 链内且 stderr 不
//! 留档。本测试用与生产同构的件复现整链:触发 → 本体快照 → 起草 →
//! 临时规则落库 → 下一 Run 装载。这是审查 P2-2 点名缺失的组件测试。

const std = @import("std");
const cc = @import("cc");
const harness = @import("harness");
const observation = cc.tools.tool_observation;
const self_evolution = cc.self_evolution;
const journal_mod = cc.tool_observation_journal;

fn findKgBin(allocator: std.mem.Allocator) ?[]u8 {
    if (std.c.getenv("METACODES_KG_BIN")) |v| {
        return allocator.dupe(u8, std.mem.span(v)) catch null;
    }
    const cwd = cc.util_fs.getCwd(allocator) catch return null;
    defer allocator.free(cwd);
    const local = std.fmt.allocPrint(
        allocator,
        "{s}/zig-out/vendor/tinykg/tinykg",
        .{cwd},
    ) catch return null;
    const local_z = allocator.dupeZ(u8, local) catch {
        allocator.free(local);
        return null;
    };
    defer allocator.free(local_z);
    if (std.c.access(local_z.ptr, 1) == 0) return local; // X_OK
    allocator.free(local);
    return null;
}

/// 与生产同形的观察日志:一个成功 dispatch 对 + 2 个弱化候选 +
/// run 末 gate 总结(tier1),满足 process_signal(weak>=2)。
fn completedWeakeningRun(session_dir: []const u8) !journal_mod.RunBinding {
    const sid = cc.session_id.SessionId.fromSlice("fedcba987654321001234567").?;
    var journal = try journal_mod.Journal.init(session_dir, sid);
    errdefer journal.deinit();
    try std.testing.expect(journal.sink().emit(.{ .dispatch_started = .{
        .id = "edit-0",
        .requested_name = "Edit",
        .dispatched_name = "Edit",
        .origin = .authoritative,
        .agent_depth = 0,
        .input_bytes = 2,
        .input_sha256 = observation.sha256Hex("{}"),
    } }));
    try std.testing.expect(journal.sink().emit(.{ .dispatch_finished = .{
        .id = "edit-0",
        .requested_name = "Edit",
        .dispatched_name = "Edit",
        .origin = .authoritative,
        .agent_depth = 0,
        .outcome = .succeeded,
        .error_code = null,
        .elapsed_ms = 1,
        .result_present = true,
        .result_bytes = 2,
        .result_sha256 = observation.sha256Hex("{}"),
        .effect = null,
        .effect_valid = true,
    } }));
    for ([_][]const u8{ "weak-0", "weak-1" }) |id| {
        try std.testing.expect(journal.sink().emit(.{ .test_weakening_candidate = .{
            .dispatch_id = id,
            .path_sha256 = observation.sha256Hex("tests/test_x.py"),
            .tool = "Edit",
            .assert_tokens_touched = true,
            .last_verification_failed = false,
        } }));
    }
    try std.testing.expect(journal.sink().emit(.{ .verification_final_gate = .{
        .enforced = true,
        .mutations_occurred = true,
        .obligation_met = true,
        .nudges = 0,
        .max_nudges = 2,
        .tier1_verifications = 1,
        .tier2_verifications = 0,
        .redundant_verifications = 0,
        .final_closure_tier = 1,
        .reopened_after_verification = 0,
        .known_failing = false,
    } }));
    try journal.finishRun("end_turn");
    const binding = try journal.runBinding();
    journal.deinit();
    return binding;
}

fn proposalSse(allocator: std.mem.Allocator) ![]u8 {
    // 与 parseResponse 同一套件构造响应:Wire→Spec→canonical lean,杜绝
    // 手写 JSON 与校验器(schema_version/reason/lean 逐字节一致)漂移。
    const wire = cc.project_rule_spec.Wire{
        .target_kind = .tool,
        .target = "NotebookEdit",
        .target_scope = .all,
        .deny_target = false,
        .max_input_bytes = 1_048_576,
        .max_agent_depth = 4,
        .authoritative_only = true,
        .effect_requirement = .none,
    };
    const spec = try cc.project_rule_spec.fromWire(wire);
    const lean = try cc.rule_author.renderCanonicalLean(allocator, spec);
    defer allocator.free(lean);
    const proposal = try std.json.Stringify.valueAlloc(allocator, .{
        .schema_version = cc.rule_author.RESPONSE_SCHEMA_VERSION,
        .decision = "propose",
        .reason = "repeated weakening without reobservation in this run",
        .invariant = "authoritative rewrites of existing files must be reobserved",
        .falsifier = "an unobserved rewrite",
        .rule_spec = wire,
        .lean_source = lean,
    }, .{});
    defer allocator.free(proposal);
    const escaped = try std.json.Stringify.valueAlloc(allocator, proposal, .{});
    defer allocator.free(escaped);
    return std.fmt.allocPrint(
        allocator,
        "event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"delta\":{{\"type\":\"text_delta\",\"text\":{s}}}}}\n\n" ++
            "event: message_delta\ndata: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"end_turn\"}},\"usage\":{{\"input_tokens\":10,\"output_tokens\":5}}}}\n\n" ++
            "event: message_stop\ndata: {{\"type\":\"message_stop\"}}\n\n",
        .{escaped},
    );
}

test "L2: end-of-run evolution proposes and the next run arms the provisional rule" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const kg_bin = findKgBin(a) orelse return error.SkipZigTest;
    defer a.free(kg_bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    // 项目状态布局:<state>/<session>/ + <state>/project-rules(无 active)。
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const state_dir = try std.fmt.bufPrint(&path_buffer, "{s}/state", .{root});
    var session_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const session_dir = try std.fmt.bufPrint(&session_buffer, "{s}/state/session-1", .{root});
    var rules_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const rules_dir = try std.fmt.bufPrint(&rules_buffer, "{s}/state/project-rules", .{root});
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_dir = try std.fmt.bufPrint(&store_buffer, "{s}/store", .{root});
    var project_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const project_root = try std.fmt.bufPrint(&project_buffer, "{s}/project", .{root});
    for ([_][]const u8{ state_dir, session_dir, rules_dir, project_root }) |dir|
        cc.util_fs.mkdirParents(dir) catch {};

    // 真 store + 项目锚(KgRemember 建 project 节点 = 本体投影的前提)。
    var kg = try cc.kg_client.KgClient.init(a, .{
        .home = root,
        .domain = "selfevo-l2",
        .config_bin = kg_bin,
        .config_store = store_dir,
        .env_bin = "",
        .env_store = "",
    });
    defer kg.deinit();
    kg.ensureReady();
    _ = kg.remember(.observation, "prior memory: the hidden suite pins exit codes", "observation", false) catch
        return error.SkipZigTest; // store 不可用 = 环境缺陷,不算失败

    const binding = try completedWeakeningRun(session_dir);

    // MockServer 扮演 author provider。
    const sse = try proposalSse(a);
    defer a.free(sse);
    var server = try harness.MockServer.start(sse, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "author-key", "test-model", url);
    defer client.deinit();
    client.setMaxTokensOverride(256);

    var report_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const report_path = try std.fmt.bufPrint(&report_buffer, "{s}/evo-report.json", .{root});
    var report_value_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const report_z = try std.fmt.bufPrintZ(&report_value_buffer, "{s}", .{report_path});
    const ppaths = @import("platform").paths;
    ppaths.setEnv(self_evolution.REPORT_ENV, report_z.ptr);
    defer ppaths.unsetEnv(self_evolution.REPORT_ENV);

    const outcome = self_evolution.endOfRun(a, .{
        .kg = &kg,
        .session_dir = session_dir,
        .project_root = project_root,
        .provider = client.provider(),
        .actor_identity = "mock|test-model",
        .model = "test-model",
        .run_binding = binding,
        .now_ns = 1_000_000_000,
        .stop_reason = "end_turn",
        .provisional_active_count = 0,
        .abort = null,
    });
    if (outcome != .proposed) {
        const pfs2 = @import("platform").fs;
        const report_z2 = try a.dupeZ(u8, report_path);
        defer a.free(report_z2);
        const rfd = pfs2.open(report_z2.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (rfd >= 0) {
            defer _ = pfs2.close(rfd);
            var buf: [512]u8 = undefined;
            const n = pfs2.read(rfd, &buf);
            if (n > 0) std.debug.print("EVO REPORT: {s}\n", .{buf[0..@intCast(n)]});
        }
    }
    try std.testing.expectEqual(self_evolution.Outcome.proposed, outcome);

    // F1 实锚:每 Run 战绩记录被提升为受治理 proposition。提升发生在
    // prepare 快照之前,所以 outcome==proposed 已经证明 tinykg 导出侧
    // 接受了它(治理属性畸形会让快照整体报错 → degraded);这里再钉
    // "提升确实发生"——promoteToOntology 是 best-effort,静默失败会让
    // 本体退回永远为空的 r2 状态。
    const impact_hits = try kg.recallTyped("provisional-rule-impact-v1", 8, false, "proposition");
    defer {
        for (impact_hits) |*hit| hit.deinit(kg.allocator);
        kg.allocator.free(impact_hits);
    }
    try std.testing.expect(impact_hits.len >= 1);

    // 滚动窗口实锚:第二条 impact 行落库后,窗口函数把 endOfRun 写的第一
    // 条真打上 deprecated_by 边(快照 >48 条是整体报错,窗口是硬保护)。
    const second_sha = observation.sha256Hex("provisional-rule-impact-v1: second row");
    const second_id = try kg.rememberOntologyItem(
        "provisional-rule-impact-v1: second row",
        "proposition",
        "host_observed",
        "a run journal interval whose dispatch counters contradict this record",
        &second_sha,
    );
    const deprecated = self_evolution.deprecateStaleOntologyRows(&kg, self_evolution.IMPACT_MARKER, second_id);
    try std.testing.expect(deprecated >= 1);

    // S2:下一 Run 装载(无 kernel env → loadProvisionalGate 返回 null 是
    // 预期——它要求 kernel 身份;此处直接验证信封收集与解析)。
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const envelopes = try self_evolution.collectEnvelopes(arena.allocator(), &kg);
    try std.testing.expectEqual(@as(usize, 1), envelopes.len);
    try std.testing.expectEqualStrings("NotebookEdit", envelopes[0].rule.target);
}

test "L2: outcome ingestion is idempotent through the real recall path" {
    // 2026-08-18 审查 B1 的回归钉:去重依赖 recallTyped 真的返回已写节点
    // ——limit 超采算术错一步,重复节点就静默毒化召回槽。第二次摄取必须
    // 返回 0。
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const kg_bin = findKgBin(a) orelse return error.SkipZigTest;
    defer a.free(kg_bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_dir = try std.fmt.bufPrint(&store_buffer, "{s}/store", .{root});
    var project_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const project_root = try std.fmt.bufPrint(&project_buffer, "{s}/project", .{root});
    cc.util_fs.mkdirParents(project_root) catch {};
    var kg = try cc.kg_client.KgClient.init(a, .{
        .home = root,
        .domain = "selfevo-l2b",
        .config_bin = kg_bin,
        .config_store = store_dir,
        .env_bin = "",
        .env_store = "",
    });
    defer kg.deinit();
    kg.ensureReady();

    const outcomes_path = try std.fmt.bufPrint(&store_buffer, "{s}/task-outcomes.json", .{root});
    {
        const payload = "{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[" ++
            "{\"task\":\"etag\",\"attempt_key\":\"a1\",\"reward\":0.27,\"tests_passed\":3,\"tests_total\":11,\"failing_tests\":[\"t::a\",\"t::b\"]}," ++
            "{\"task\":\"bugfix\",\"attempt_key\":\"a1\",\"reward\":0.5,\"tests_passed\":2,\"tests_total\":4,\"failing_tests\":[]}]}";
        const pfs = @import("platform").fs;
        const outcomes_z = try a.dupeZ(u8, outcomes_path);
        defer a.free(outcomes_z);
        const fd = pfs.open(outcomes_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = pfs.close(fd);
        var off: usize = 0;
        while (off < payload.len) {
            const n = pfs.write(fd, payload[off..]);
            try std.testing.expect(n > 0);
            off += @intCast(n);
        }
    }
    var value_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const value_z = try std.fmt.bufPrintZ(&value_buffer, "{s}", .{outcomes_path});
    const ppaths = @import("platform").paths;
    ppaths.setEnv(self_evolution.OUTCOMES_ENV, value_z.ptr);
    defer ppaths.unsetEnv(self_evolution.OUTCOMES_ENV);

    try std.testing.expectEqual(@as(usize, 2), self_evolution.ingestOutcomes(a, &kg));
    try std.testing.expectEqual(@as(usize, 0), self_evolution.ingestOutcomes(a, &kg));
}
