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

    // 任务上下文素材:host 声明 hint + 店内该任务的带名结局行 → author
    // packet 必须携带(义务提案的素材面)。
    _ = kg.remember(
        .observation,
        "task-outcome-v1: key=demo-task#a1 task=demo-task reward=0.5000 tests=2/4 failing=[named failing check]",
        "task_outcome",
        false,
    ) catch return error.SkipZigTest;
    const ppaths_hint = @import("platform").paths;
    ppaths_hint.setEnv("METACODES_TASK_HINT", "demo-task");
    defer ppaths_hint.unsetEnv("METACODES_TASK_HINT");

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

    // 任务上下文实锚:author 请求体必须携带 task_context(hint + 上次
    // 结局行含错题名)——义务提案的素材面,packet wire 接线断言。
    const author_request = server.lastRequest() orelse return error.TestExpectedRequest;
    try std.testing.expect(std.mem.indexOf(u8, author_request.body(), "task_context") != null);
    try std.testing.expect(std.mem.indexOf(u8, author_request.body(), "named failing check") != null);
    // packet 以转义字符串嵌入请求体,断言用免引号 token。
    try std.testing.expect(std.mem.indexOf(u8, author_request.body(), "task_hint") != null);
    try std.testing.expect(std.mem.indexOf(u8, author_request.body(), "demo-task") != null);

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
    // 唯一文本接线锚:正文必须带 run id——tinykg 召回按文本重合折叠近
    // 重复,同文本的多 run 行会折叠成 1 条,滚动窗口就永远打不出边
    // (selflearn 两遍法生产取证)。
    try std.testing.expect(std.mem.indexOf(u8, impact_hits[0].text, "run=") != null);

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

    // 升级写(p3 取证抓的真 bug 的回归钉):存量 bugfix 行 failing=[],新
    // 文件同 key 但带错题名 → 必须升级写 1 条;etag 存量已带名 → 跳过;
    // 升级后再摄取回到幂等 0。
    {
        const upgraded_payload = "{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[" ++
            "{\"task\":\"etag\",\"attempt_key\":\"a1\",\"reward\":0.27,\"tests_passed\":3,\"tests_total\":11,\"failing_tests\":[\"t::a\",\"t::b\"]}," ++
            "{\"task\":\"bugfix\",\"attempt_key\":\"a1\",\"reward\":0.5,\"tests_passed\":2,\"tests_total\":4,\"failing_tests\":[\"named now\"],\"final_note\":\"kept my approach unchanged last time\"}]}";
        const pfs = @import("platform").fs;
        const outcomes_z2 = try a.dupeZ(u8, outcomes_path);
        defer a.free(outcomes_z2);
        const fd = pfs.open(outcomes_z2.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = pfs.close(fd);
        var off: usize = 0;
        while (off < upgraded_payload.len) {
            const n = pfs.write(fd, upgraded_payload[off..]);
            try std.testing.expect(n > 0);
            off += @intCast(n);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), self_evolution.ingestOutcomes(a, &kg));
    try std.testing.expectEqual(@as(usize, 0), self_evolution.ingestOutcomes(a, &kg));

    // 确定性同题注入(到达层修复的 L2 锚):host 声明 task hint 后,
    // 该题结局行必须钉进注入尾——**独立于 BM25 相关性门**(空对话=
    // 无 query,被动召回路径整个短路,只剩确定性段)。两遍法生产取证:
    // 被动召回 16 trial 仅 4 次命中且全是别题成绩单。
    var hint_buffer: [8:0]u8 = undefined;
    @memcpy(hint_buffer[0..4], "etag");
    hint_buffer[4] = 0;
    ppaths.setEnv("METACODES_TASK_HINT", @as([*:0]const u8, @ptrCast(&hint_buffer)));
    defer ppaths.unsetEnv("METACODES_TASK_HINT");
    var conversation = cc.conversation.Conversation.init(a);
    defer conversation.deinit();
    var abort_signal = cc.util_abort.AbortSignal.init();
    var built = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conversation, &abort_signal);
    defer built.deinit(a);
    const injected_text = built.text orelse return error.TestExpectedInjection;
    try std.testing.expect(std.mem.indexOf(u8, injected_text, "task=etag") != null);
    // 自我历史对质:etag 行升级前无 note;换 hint 验 bugfix 行的 note 贯通。
    try std.testing.expect(std.mem.indexOf(u8, injected_text, "t::b") != null);
    try std.testing.expect(std.mem.indexOf(u8, injected_text, "task=bugfix") == null);
    try std.testing.expectEqualStrings("injected", built.receipt.status);
    try std.testing.expect(built.receipt.injected_count >= 1);
}

test "L2: task obligation rides the store and arms the gate for the same task only" {
    // 动态层"合法过拟合"的存取链:义务信封(任务绑定+内容寻址)落真
    // store → 同任务收集命中 / 异任务隔离 → 执行门装载 → 命令观察满足。
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
    var kg = try cc.kg_client.KgClient.init(a, .{
        .home = root,
        .domain = "selfevo-l2c",
        .config_bin = kg_bin,
        .config_store = store_dir,
        .env_bin = "",
        .env_store = "",
    });
    defer kg.deinit();
    kg.ensureReady();

    const hint = "bug_fix-easy-invalid_filterwarnings_regex_error";
    const task_sha = self_evolution.taskIdentity(hint);
    const needle = "pytest testing/test_warnings.py::TestDeprecationWarningsByDefault";
    const reason = "the named failing tests were never executed before finishing";
    const cid = self_evolution.obligationCandidateId(task_sha[0..], needle, reason);
    const envelope_text = try self_evolution.encodeObligation(a, .{
        .candidate_id = cid[0..],
        .task_sha256 = task_sha[0..],
        .command_needle = needle,
        .reason = reason,
    });
    defer a.free(envelope_text);
    _ = kg.remember(.observation, envelope_text, self_evolution.OBLIGATION_SCHEMA_TYPE, false) catch
        return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const same = try self_evolution.collectObligations(arena.allocator(), &kg, hint);
    try std.testing.expectEqual(@as(usize, 1), same.len);
    try std.testing.expectEqualStrings(needle, same[0].command_needle);
    const other = try self_evolution.collectObligations(arena.allocator(), &kg, "some-other-task");
    try std.testing.expectEqual(@as(usize, 0), other.len);

    // 执行门:未命中 → 索引 0;观察到含 needle 的命令 → 无动作。
    const obligation_gate = cc.obligation_gate;
    const runtime = obligation_gate.load(a, &kg, hint) orelse return error.TestExpectedRuntime;
    defer {
        runtime.deinit();
        a.destroy(runtime);
    }
    try std.testing.expectEqual(@as(?usize, 0), runtime.decide().index);
    // 2.0:执行成功才算履约(失败的 dispatch 不清账)。
    runtime.observeDispatch("call_a", "cd /workspace && pytest testing/test_warnings.py::TestDeprecationWarningsByDefault -x");
    runtime.observeResult("call_a", false);
    try std.testing.expectEqual(@as(?usize, 0), runtime.decide().index);
    runtime.observeDispatch("call_b", "pytest testing/test_warnings.py::TestDeprecationWarningsByDefault -x");
    runtime.observeResult("call_b", true);
    try std.testing.expectEqual(@as(?usize, null), runtime.decide().index);
}

test "L2: author obligation proposal lands as an envelope the same task collects" {
    // p5 生产命中的回归钉:propose_obligation 曾在 receiptMatchesResult 被
    // 写死 `== .abstain` 恒判不匹配 → AuthorReceiptResultMismatch,首个真
    // 义务提案被丢弃。本测走全链:真 store + hint + MockServer 义务响应 →
    // endOfRun proposed("obligation")→ collectObligations 命中。
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const kg_bin = findKgBin(a) orelse return error.SkipZigTest;
    defer a.free(kg_bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
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
    var kg = try cc.kg_client.KgClient.init(a, .{
        .home = root,
        .domain = "selfevo-l2d",
        .config_bin = kg_bin,
        .config_store = store_dir,
        .env_bin = "",
        .env_store = "",
    });
    defer kg.deinit();
    kg.ensureReady();
    _ = kg.remember(.observation, "prior memory: baseline", "observation", false) catch
        return error.SkipZigTest;
    _ = kg.remember(
        .observation,
        "task-outcome-v1: key=obl-task#a1 task=obl-task reward=0.5000 tests=2/4 failing=[pytest testing/test_x.py::test_a]",
        "task_outcome",
        false,
    ) catch return error.SkipZigTest;
    const ppaths = @import("platform").paths;
    ppaths.setEnv("METACODES_TASK_HINT", "obl-task");
    defer ppaths.unsetEnv("METACODES_TASK_HINT");

    const binding = try completedWeakeningRun(session_dir);
    const proposal =
        "{\"schema_version\":\"metacodes-rule-author-response-v1\",\"decision\":\"propose_obligation\"," ++
        "\"reason\":\"named failing test never executed\",\"invariant\":null,\"falsifier\":null," ++
        "\"rule_spec\":null,\"lean_source\":null," ++
        "\"obligation_needle\":\"pytest testing/test_x.py::test_a\"," ++
        "\"obligation_reason\":\"run the named failing test before finishing\"}";
    const escaped = try std.json.Stringify.valueAlloc(a, proposal, .{});
    defer a.free(escaped);
    const sse = try std.fmt.allocPrint(
        a,
        "event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"delta\":{{\"type\":\"text_delta\",\"text\":{s}}}}}\n\n" ++
            "event: message_delta\ndata: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"end_turn\"}},\"usage\":{{\"input_tokens\":10,\"output_tokens\":5}}}}\n\n" ++
            "event: message_stop\ndata: {{\"type\":\"message_stop\"}}\n\n",
        .{escaped},
    );
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
        .outcomes_ingested = 0,
        .provisional_candidate_ids = &.{},
        .provisional_bundle_sha256 = null,
        .abort = null,
    });
    try std.testing.expectEqual(self_evolution.Outcome.proposed, outcome);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const obligations = try self_evolution.collectObligations(arena.allocator(), &kg, "obl-task");
    try std.testing.expectEqual(@as(usize, 1), obligations.len);
    try std.testing.expectEqualStrings("pytest testing/test_x.py::test_a", obligations[0].command_needle);
}

test "L2: final_note rides the outcome row into note and GIGO stays intact" {
    // 自我历史对质贯通:带 final_note 的行入店 → 同题 note 含 note=;
    // GIGO 派生仍按 failing=[...] 定界(note 在括号之后,adapter 已剥括号)。
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
    var kg = try cc.kg_client.KgClient.init(a, .{
        .home = root,
        .domain = "selfevo-l2e",
        .config_bin = kg_bin,
        .config_store = store_dir,
        .env_bin = "",
        .env_store = "",
    });
    defer kg.deinit();
    kg.ensureReady();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const outcomes_path = try std.fmt.bufPrint(&path_buffer, "{s}/o.json", .{root});
    {
        const payload = "{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[" ++
            "{\"task\":\"wall-task\",\"attempt_key\":\"a1\",\"reward\":0.27,\"tests_passed\":3,\"tests_total\":11," ++
            "\"failing_tests\":[\"tests/t.py::TestX::test_uses_sha256 (skipped)\"]," ++
            "\"final_note\":\"I concluded the (skipped) file was stale and changed nothing\"}]}";
        const pfs = @import("platform").fs;
        const z = try a.dupeZ(u8, outcomes_path);
        defer a.free(z);
        const fd = pfs.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
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
    try std.testing.expectEqual(@as(usize, 1), self_evolution.ingestOutcomes(a, &kg));

    ppaths.setEnv("METACODES_TASK_HINT", "wall-task");
    defer ppaths.unsetEnv("METACODES_TASK_HINT");
    var conversation = cc.conversation.Conversation.init(a);
    defer conversation.deinit();
    var abort_signal = cc.util_abort.AbortSignal.init();
    var built = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conversation, &abort_signal);
    defer built.deinit(a);
    const text = built.text orelse return error.TestExpectedInjection;
    try std.testing.expect(std.mem.indexOf(u8, text, "note=I concluded the (skipped) file was stale") != null);
    // GIGO 派生不受 note 污染:needle = skip 名(剥后缀),非 note 内容。
    const runtime = cc.obligation_gate.load(a, &kg, "wall-task") orelse return error.TestExpectedRuntime;
    defer {
        runtime.deinit();
        a.destroy(runtime);
    }
    try std.testing.expectEqual(@as(usize, 1), runtime.count());
    try std.testing.expectEqualStrings("tests/t.py::TestX::test_uses_sha256", runtime.envelopes[0].command_needle);

    // 认知模式调度:同名第二次失败 → streak=2 → construct 指令进 note。
    {
        const payload2 = "{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[" ++
            "{\"task\":\"wall-task\",\"attempt_key\":\"a2\",\"reward\":0.27,\"tests_passed\":3,\"tests_total\":11," ++
            "\"failing_tests\":[\"tests/t.py::TestX::test_uses_sha256 (skipped)\"]}]}";
        const pfs = @import("platform").fs;
        const z2 = try a.dupeZ(u8, outcomes_path);
        defer a.free(z2);
        const fd = pfs.open(z2.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = pfs.close(fd);
        var off: usize = 0;
        while (off < payload2.len) {
            const n = pfs.write(fd, payload2[off..]);
            try std.testing.expect(n > 0);
            off += @intCast(n);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), self_evolution.ingestOutcomes(a, &kg));
    var built2 = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conversation, &abort_signal);
    defer built2.deinit(a);
    const text2 = built2.text orelse return error.TestExpectedInjection;
    try std.testing.expect(std.mem.indexOf(u8, text2, "Per-point reading mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, text2, "failed 2 consecutive attempt(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text2, "read it constructively") != null);
    // streak=2 时仍是完整框架(未升级)。
    try std.testing.expect(std.mem.indexOf(u8, text2, "Garbage In, Garbage Out") != null);

    // 第三次同名失败 → streak=3 → union 指令 + 升级态瘦身(说教消失)。
    {
        const payload3 = "{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[" ++
            "{\"task\":\"wall-task\",\"attempt_key\":\"a3\",\"reward\":0.27,\"tests_passed\":3,\"tests_total\":11," ++
            "\"failing_tests\":[\"tests/t.py::TestX::test_uses_sha256 (skipped)\"]}]}";
        const pfs = @import("platform").fs;
        const z3 = try a.dupeZ(u8, outcomes_path);
        defer a.free(z3);
        const fd = pfs.open(z3.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = pfs.close(fd);
        var off: usize = 0;
        while (off < payload3.len) {
            const n = pfs.write(fd, payload3[off..]);
            try std.testing.expect(n > 0);
            off += @intCast(n);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), self_evolution.ingestOutcomes(a, &kg));
    var built3 = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conversation, &abort_signal);
    defer built3.deinit(a);
    const text3 = built3.text orelse return error.TestExpectedInjection;
    try std.testing.expect(std.mem.indexOf(u8, text3, "failed 3 consecutive attempt(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text3, "UNION") != null);
    // v36 卡滞平台冷却(策略更新,取代 v25 的 ESCALATED 钉):3 行 reward
    // 与 failing 段逐字节相同 → 压力栈已证非因果 → COOLED 短注取代
    // ESCALATED 重注(mode 行保留:数据面照旧,只撤律令面)。
    try std.testing.expect(std.mem.indexOf(u8, text3, "COOLED") != null);
    try std.testing.expect(std.mem.indexOf(u8, text3, "ESCALATED") == null);
    try std.testing.expect(std.mem.indexOf(u8, text3, "Garbage In, Garbage Out") == null);
    // 冷却的义务面:nudge 预算降为 1(nudges_used 预充 MAX-1)。
    {
        const runtime_cool = cc.obligation_gate.load(a, &kg, "wall-task") orelse
            return error.TestExpectedRuntime;
        defer {
            runtime_cool.deinit();
            a.destroy(runtime_cool);
        }
        try std.testing.expectEqual(cc.obligation_gate.MAX_OBLIGATION_NUDGES - 1, runtime_cool.nudges_used);
    }
    // 新剂量打破平台键(冷却绝不能误杀新证据):第 4 行同名但带新注解 →
    // failing 段变化 → 平台破 → ESCALATED 全额回归,义务预算复原。
    {
        const payload4b = "{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[" ++
            "{\"task\":\"wall-task\",\"attempt_key\":\"a4\",\"reward\":0.27,\"tests_passed\":3,\"tests_total\":11," ++
            "\"failing_tests\":[\"tests/t.py::TestX::test_uses_sha256 (skipped: fresh reason arrived)\"]}]}";
        const pfs = @import("platform").fs;
        const z4b = try a.dupeZ(u8, outcomes_path);
        defer a.free(z4b);
        const fd = pfs.open(z4b.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = pfs.close(fd);
        var off: usize = 0;
        while (off < payload4b.len) {
            const n = pfs.write(fd, payload4b[off..]);
            try std.testing.expect(n > 0);
            off += @intCast(n);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), self_evolution.ingestOutcomes(a, &kg));
    var built4b = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conversation, &abort_signal);
    defer built4b.deinit(a);
    const text4b = built4b.text orelse return error.TestExpectedInjection;
    try std.testing.expect(std.mem.indexOf(u8, text4b, "ESCALATED") != null);
    try std.testing.expect(std.mem.indexOf(u8, text4b, "FIRST ACTION: enter every point above") != null);
    try std.testing.expect(std.mem.indexOf(u8, text4b, "COOLED") == null);
    {
        const runtime_warm = cc.obligation_gate.load(a, &kg, "wall-task") orelse
            return error.TestExpectedRuntime;
        defer {
            runtime_warm.deinit();
            a.destroy(runtime_warm);
        }
        try std.testing.expectEqual(@as(u8, 0), runtime_warm.nudges_used);
    }

    // 召回摘录 800 字符截断(p10 取证雷):8 个长 pytest 名的 failing 列表
    // 超 800 → 摘录无闭括号 → failingSection=null → mode 段静默消失,
    // 升级态/正名条款永不触发(任务越难越必然)。修复=collectHistory 对
    // truncated 命中补取全文;此 stanza 若无补取必失败。
    {
        var rows = std.array_list.Managed(u8).init(a);
        defer rows.deinit();
        var attempt: usize = 0;
        while (attempt < 2) : (attempt += 1) {
            if (attempt > 0) try rows.appendSlice(",");
            const head = try std.fmt.allocPrint(a,
                "{{\"task\":\"long-wall-task\",\"attempt_key\":\"la{d}\",\"reward\":0.27,\"tests_passed\":3,\"tests_total\":11,\"failing_tests\":[",
                .{attempt});
            defer a.free(head);
            try rows.appendSlice(head);
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                if (i > 0) try rows.appendSlice(",");
                const name = try std.fmt.allocPrint(a,
                    "\"tests/test_static_utils_prehistoric_standalone_verification.py::TestExtremelyDescriptiveEtagClassName::test_case_number_{d}_with_a_very_long_descriptive_behavior_suffix (skipped)\"",
                    .{i});
                defer a.free(name);
                try rows.appendSlice(name);
            }
            // 生产杀伤条件:note 足够长把 failing 的闭括号推出头尾摘录窗
            // (p10 现场 = 300B 中文 note + 8 长名)。无 note 的行闭括号在
            // 尾窗存活,mode 段照常渲染——测不出这颗雷。
            try rows.appendSlice("],\"final_note\":\"");
            var pad: usize = 0;
            while (pad < 30) : (pad += 1)
                try rows.appendSlice("conceptually verified ");
            try rows.appendSlice("\"}");
        }
        const payload_long = try std.fmt.allocPrint(a,
            "{{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[{s}]}}",
            .{rows.items});
        defer a.free(payload_long);
        const pfs = @import("platform").fs;
        const zl = try a.dupeZ(u8, outcomes_path);
        defer a.free(zl);
        const fd = pfs.open(zl.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = pfs.close(fd);
        var off: usize = 0;
        while (off < payload_long.len) {
            const n = pfs.write(fd, payload_long[off..]);
            try std.testing.expect(n > 0);
            off += @intCast(n);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), self_evolution.ingestOutcomes(a, &kg));
    ppaths.setEnv("METACODES_TASK_HINT", "long-wall-task");
    var built_long = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conversation, &abort_signal);
    defer built_long.deinit(a);
    const text_long = built_long.text orelse return error.TestExpectedInjection;
    try std.testing.expect(std.mem.indexOf(u8, text_long, "Per-point reading mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_long, "failed 2 consecutive attempt(s)") != null);
    // 新框架:等价替代授权句已铲除,字面制计分语义在场。
    try std.testing.expect(std.mem.indexOf(u8, text_long, "with your own equivalent check") == null);
    try std.testing.expect(std.mem.indexOf(u8, text_long, "scores nothing") != null);
    // p12 取证桥:note 要求必须并轨进任务清单(workflow 吃 reminder 的修法)。
    try std.testing.expect(std.mem.indexOf(u8, text_long, "task ledger (TaskCreate)") != null);
    ppaths.setEnv("METACODES_TASK_HINT", "wall-task");

    // 理由通道(p11 取证):adapter 把验证器 results.xml 的 skip/失败
    // message 注解进错题名——"(skipped: reason)"。断言:① 裸名身份让
    // streak 跨"无注解→有注解"行保持连续;② mode 行渲染裸名;③ 注解
    // 文本到达注入面;④ GIGO 派生针剥掉整个括号注解。
    {
        const payload_r = "{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[" ++
            "{\"task\":\"reason-task\",\"attempt_key\":\"r1\",\"reward\":0.2,\"tests_passed\":1,\"tests_total\":3," ++
            "\"failing_tests\":[\"tests/t.py::TestR::test_module_exists (skipped)\"]}," ++
            "{\"task\":\"reason-task\",\"attempt_key\":\"r2\",\"reward\":0.2,\"tests_passed\":1,\"tests_total\":3," ++
            "\"failing_tests\":[\"tests/t.py::TestR::test_module_exists (skipped: widget._helpers not available; create it)\"]}]}";
        const pfs = @import("platform").fs;
        const zr = try a.dupeZ(u8, outcomes_path);
        defer a.free(zr);
        const fd = pfs.open(zr.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = pfs.close(fd);
        var off: usize = 0;
        while (off < payload_r.len) {
            const n = pfs.write(fd, payload_r[off..]);
            try std.testing.expect(n > 0);
            off += @intCast(n);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), self_evolution.ingestOutcomes(a, &kg));
    ppaths.setEnv("METACODES_TASK_HINT", "reason-task");
    var built_r = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conversation, &abort_signal);
    defer built_r.deinit(a);
    const text_r = built_r.text orelse return error.TestExpectedInjection;
    // 注解到达注入面(newest 行原文含理由)。
    try std.testing.expect(std.mem.indexOf(u8, text_r, "(skipped: widget._helpers not available; create it)") != null);
    // streak 跨注解变化连续:裸名身份 → failed 2。
    try std.testing.expect(std.mem.indexOf(u8, text_r, "- tests/t.py::TestR::test_module_exists — failed 2 consecutive attempt(s)") != null);
    // 第三次尝试:新注解无点分 token(形状类失败)——棘轮断言的前提。
    {
        const payload_r3 = "{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[" ++
            "{\"task\":\"reason-task\",\"attempt_key\":\"r3\",\"reward\":0.5,\"tests_passed\":2,\"tests_total\":3," ++
            "\"failing_tests\":[\"tests/t.py::TestR::test_module_exists (failed: AttributeError; coroutine has no attribute startswith)\"]}]}";
        const pfs = @import("platform").fs;
        const zr3 = try a.dupeZ(u8, outcomes_path);
        defer a.free(zr3);
        const fd = pfs.open(zr3.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = pfs.close(fd);
        var off: usize = 0;
        while (off < payload_r3.len) {
            const n = pfs.write(fd, payload_r3[off..]);
            try std.testing.expect(n > 0);
            off += @intCast(n);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), self_evolution.ingestOutcomes(a, &kg));
    var built_r3 = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conversation, &abort_signal);
    defer built_r3.deinit(a);
    const text_r3 = built_r3.text orelse return error.TestExpectedInjection;
    // 累积规格(v26 起为全量去重列表):历史结构理由仍在行上。
    try std.testing.expect(std.mem.indexOf(u8, text_r3, "every past report for this point: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_r3, "skipped: widget._helpers not available; create it") != null);

    // 最佳工件重放(v28):r3(最佳 0.5)重发并携带 best_artifact(含括号/
    // 逗号的真实代码)→ 工件升级写;newest=r4 时最佳锚整行引用,工件随行
    // 进注入;行文法(首个 ']' 定界)不被代码括号劫持,GIGO 针保持干净。
    {
        const payload_a = "{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[" ++
            "{\"task\":\"reason-task\",\"attempt_key\":\"r3\",\"reward\":0.5,\"tests_passed\":2,\"tests_total\":3," ++
            "\"failing_tests\":[\"tests/t.py::TestR::test_module_exists (failed: AttributeError; coroutine has no attribute startswith)\"]," ++
            "\"best_artifact\":\"--- widget/_helpers.py ---\\ndef calc(path, size=4096):\\n    data = [1, 2]\\n    return chr(34) + digest(path)[:16] + chr(34)\"}]}";
        const pfs = @import("platform").fs;
        const za = try a.dupeZ(u8, outcomes_path);
        defer a.free(za);
        const fd = pfs.open(za.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = pfs.close(fd);
        var off: usize = 0;
        while (off < payload_a.len) {
            const n = pfs.write(fd, payload_a[off..]);
            try std.testing.expect(n > 0);
            off += @intCast(n);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), self_evolution.ingestOutcomes(a, &kg));
    // 幂等:同工件重发不再升级写。
    try std.testing.expectEqual(@as(usize, 0), self_evolution.ingestOutcomes(a, &kg));

    // 第四次尝试:回归(reward 跌回)+ 注解含省略号截断哈希(p19 误火源)。
    {
        const payload_r4 = "{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[" ++
            "{\"task\":\"reason-task\",\"attempt_key\":\"r4\",\"reward\":0.4,\"tests_passed\":1,\"tests_total\":3," ++
            "\"failing_tests\":[\"tests/t.py::TestR::test_module_exists (failed: assert '(376ba3b6208...18d68c49644d)' == '(376ba3b62082d25e)')\"]}]}";
        const pfs = @import("platform").fs;
        const zr4 = try a.dupeZ(u8, outcomes_path);
        defer a.free(zr4);
        const fd = pfs.open(zr4.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = pfs.close(fd);
        var off: usize = 0;
        while (off < payload_r4.len) {
            const n = pfs.write(fd, payload_r4[off..]);
            try std.testing.expect(n > 0);
            off += @intCast(n);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), self_evolution.ingestOutcomes(a, &kg));
    var built_r4 = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conversation, &abort_signal);
    defer built_r4.deinit(a);
    const text_r4 = built_r4.text orelse return error.TestExpectedInjection;
    // 约束累积:r4 为 newest,mode 行须同时携带 r3(AttributeError)与
    // r2(not available)两代历史报告——整合失败的解药是 harness 代记。
    try std.testing.expect(std.mem.indexOf(u8, text_r4, "every past report for this point: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_r4, "AttributeError; coroutine has no attribute startswith") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_r4, "widget._helpers not available") != null);
    // 最佳工件随最佳锚进注入(升级写的 r3 带工件,reward 0.5 仍为最佳)。
    try std.testing.expect(std.mem.indexOf(u8, text_r4, "best-attempt artifact (host-extracted, verbatim):") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_r4, "digest(path)[:16]") != null);
    // 工件里的括号/代码不得污染 GIGO 针(首 ']' 定界回归钉);且 v30
    // 工件路径义务居首(逐字优先命令走全勤通道)。
    {
        const runtime_a = cc.obligation_gate.load(a, &kg, "reason-task") orelse return error.TestExpectedRuntime;
        defer {
            runtime_a.deinit();
            a.destroy(runtime_a);
        }
        try std.testing.expectEqualStrings("widget/_helpers.py", runtime_a.envelopes[0].command_needle);
        try std.testing.expect(std.mem.indexOf(u8, runtime_a.envelopes[0].reason, "UNCHANGED as your FIRST edit") != null);
        for (runtime_a.envelopes) |envelope| {
            try std.testing.expect(std.mem.indexOf(u8, envelope.command_needle, "digest") == null);
            try std.testing.expect(std.mem.indexOf(u8, envelope.command_needle, "data = ") == null);
        }
    }
    // 最佳尝试锚:newest=r4(0.4) < best=r3(0.5) → r3 整行进注入。
    try std.testing.expect(std.mem.indexOf(u8, text_r4, "历史最佳尝试") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_r4, "#r3 ") != null or std.mem.indexOf(u8, text_r4, "reward=0.5000") != null);
    // 省略号截断哈希绝不能成为 import 义务(p19 垃圾针回归钉)。
    const runtime_r4 = cc.obligation_gate.load(a, &kg, "reason-task") orelse return error.TestExpectedRuntime;
    defer {
        runtime_r4.deinit();
        a.destroy(runtime_r4);
    }
    for (runtime_r4.envelopes) |envelope| {
        try std.testing.expect(std.mem.indexOf(u8, envelope.command_needle, "...") == null);
        try std.testing.expect(std.mem.indexOf(u8, envelope.command_needle, "376ba") == null);
    }

    // GIGO 派生针 = 裸 node id(括号注解整体剥离)。
    const runtime_r = cc.obligation_gate.load(a, &kg, "reason-task") orelse return error.TestExpectedRuntime;
    defer {
        runtime_r.deinit();
        a.destroy(runtime_r);
    }
    // 理由派生义务居首(p13 取证:nudge 预算优先给"创建缺失工件"的
    // import 针——自建测试满足不了 import,名字针可以被自建测试绕过)。
    // 截断工件 → 参考-重建语义(禁逐字):r5 重发 r3 带超长工件。
    {
        var big_art = std.array_list.Managed(u8).init(a);
        defer big_art.deinit();
        try big_art.appendSlice("--- widget/_helpers.py ---\\ndef calc(path):\\n");
        var bi: usize = 0;
        while (big_art.items.len < 2100) : (bi += 1)
            try big_art.appendSlice("    x = 1\\n");
        const payload_t = try std.fmt.allocPrint(a,
            "{{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[" ++
                "{{\"task\":\"trunc-task\",\"attempt_key\":\"t1\",\"reward\":0.9,\"tests_passed\":9,\"tests_total\":10," ++
                "\"failing_tests\":[\"tests/t.py::TestT::test_last (skipped: widget._case not available)\"]," ++
                "\"best_artifact\":\"{s}\"}}]}}",
            .{big_art.items});
        defer a.free(payload_t);
        const pfs = @import("platform").fs;
        const zt = try a.dupeZ(u8, outcomes_path);
        defer a.free(zt);
        const fd = pfs.open(zt.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = pfs.close(fd);
        var off: usize = 0;
        while (off < payload_t.len) {
            const n = pfs.write(fd, payload_t[off..]);
            try std.testing.expect(n > 0);
            off += @intCast(n);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), self_evolution.ingestOutcomes(a, &kg));
    ppaths.setEnv("METACODES_TASK_HINT", "trunc-task");
    {
        const runtime_t = cc.obligation_gate.load(a, &kg, "trunc-task") orelse return error.TestExpectedRuntime;
        defer {
            runtime_t.deinit();
            a.destroy(runtime_t);
        }
        try std.testing.expectEqualStrings("widget/_helpers.py", runtime_t.envelopes[0].command_needle);
        try std.testing.expect(std.mem.indexOf(u8, runtime_t.envelopes[0].reason, "HOST-TRUNCATED") != null);
        try std.testing.expect(std.mem.indexOf(u8, runtime_t.envelopes[0].reason, "do NOT copy it verbatim") != null);
        try std.testing.expect(std.mem.indexOf(u8, runtime_t.envelopes[0].reason, "UNCHANGED") == null);
    }
    ppaths.setEnv("METACODES_TASK_HINT", "reason-task");

    // 队列全序(v30):工件路径居首→import 棘轮→名字义务;
    // 棘轮:最新行(r4)无点分 token,import 义务只能来自历史行(r2)。
    try std.testing.expectEqual(@as(usize, 3), runtime_r.count());
    try std.testing.expectEqualStrings("widget/_helpers.py", runtime_r.envelopes[0].command_needle);
    try std.testing.expect(std.mem.indexOf(u8, runtime_r.envelopes[0].reason, "UNCHANGED as your FIRST edit") != null);
    try std.testing.expectEqualStrings("import widget._helpers", runtime_r.envelopes[1].command_needle);
    try std.testing.expectEqualStrings("tests/t.py::TestR::test_module_exists", runtime_r.envelopes[2].command_needle);
    // v22:名字义务的 reason 携带验证器报告原文(nudge 通道递送形状指令)。
    // v27:reason 累积历史全部去重报告并要求同时满足(整合失败的解药)。
    try std.testing.expect(std.mem.indexOf(u8, runtime_r.envelopes[2].reason, "the verifier reported: failed: assert ") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_r.envelopes[2].reason, "  PLUS  ") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_r.envelopes[2].reason, "Satisfy EVERY one of these simultaneously") != null);
    // 原生 host-run 裁决全链(v32):钉住假检查(pytest 风格输出,exit 1)
    // → host 执行 → 解析 → 入库(prov=host_run)→ 注入可见。全程真 spawn。
    {
        ppaths.setEnv("METACODES_HOST_CHECK", "printf 'FAILED tests/hc.py::TestH::test_native_loop - AssertionError: native\\n'; exit 1");
        defer ppaths.unsetEnv("METACODES_HOST_CHECK");
        const host_check = cc.host_check;
        const pin = host_check.Pin.fromEnv() orelse return error.TestExpectedPin;
        ppaths.setEnv("METACODES_TASK_HINT", "native-task");
        const summary = host_check.runAndIngest(a, &kg, &pin, "native-task", "native final note", 424242) orelse
            return error.TestExpectedSummary;
        try std.testing.expectEqual(@as(u32, 0), summary.passed);
        try std.testing.expectEqual(@as(usize, 1), summary.ingested);
        var built_hc = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conversation, &abort_signal);
        defer built_hc.deinit(a);
        const text_hc = built_hc.text orelse return error.TestExpectedInjection;
        try std.testing.expect(std.mem.indexOf(u8, text_hc, "prov=host_run") != null);
        try std.testing.expect(std.mem.indexOf(u8, text_hc, "tests/hc.py::TestH::test_native_loop") != null);
        try std.testing.expect(std.mem.indexOf(u8, text_hc, "native final note") != null);
        // 钉住防篡改:改环境后拒跑。
        ppaths.setEnv("METACODES_HOST_CHECK", "echo tampered; exit 0");
        try std.testing.expect(host_check.runAndIngest(a, &kg, &pin, "native-task", "", 424243) == null);
    }
    // 已解决静默(v33,p33 filterwarnings 回归钉):全过行 → 零义务 +
    // 短注(无 ESCALATED/GIGO/mode 压力面),防棘轮在解决态投毒。
    {
        const payload_s = "{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[" ++
            "{\"task\":\"solved-task\",\"attempt_key\":\"s1\",\"reward\":1.0,\"tests_passed\":4,\"tests_total\":4," ++
            "\"failing_tests\":[],\"final_note\":\"all four checks green; ledger closed\"}]}";
        const pfs = @import("platform").fs;
        const zs = try a.dupeZ(u8, outcomes_path);
        defer a.free(zs);
        const fd = pfs.open(zs.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = pfs.close(fd);
        var off: usize = 0;
        while (off < payload_s.len) {
            const n = pfs.write(fd, payload_s[off..]);
            try std.testing.expect(n > 0);
            off += @intCast(n);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), self_evolution.ingestOutcomes(a, &kg));
    ppaths.setEnv("METACODES_TASK_HINT", "solved-task");
    // 手工存一条陈年义务:解决态必须拒载(棘轮释放)。
    _ = kg.remember(.observation, "metacodes-provisional-obligation-v1 task=solved-task needle=tests/s.py::T::t_old reason=stale ghost", "provisional_obligation", false) catch {};
    try std.testing.expect(cc.obligation_gate.load(a, &kg, "solved-task") == null);
    var built_s = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conversation, &abort_signal);
    defer built_s.deinit(a);
    const text_s = built_s.text orelse return error.TestExpectedInjection;
    try std.testing.expect(std.mem.indexOf(u8, text_s, "already proven by the verdict above") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_s, "ESCALATED") == null);
    try std.testing.expect(std.mem.indexOf(u8, text_s, "Garbage In, Garbage Out") == null);
    try std.testing.expect(std.mem.indexOf(u8, text_s, "Per-point reading mode") == null);
    // 回归后仍静默(v34,p34 取证):曾全过的任务,最新行回归 → 依旧
    // 零义务,note = 复现最佳 + "最新失败是回归损伤非新需求"。
    {
        const payload_rg = "{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[" ++
            "{\"task\":\"solved-task\",\"attempt_key\":\"s2\",\"reward\":0.5,\"tests_passed\":2,\"tests_total\":4," ++
            "\"failing_tests\":[\"tests/s.py::T::t_ghost1 (failed: exact match empty)\"]}]}";
        const pfs = @import("platform").fs;
        const zg = try a.dupeZ(u8, outcomes_path);
        defer a.free(zg);
        const fd = pfs.open(zg.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = pfs.close(fd);
        var off: usize = 0;
        while (off < payload_rg.len) {
            const n = pfs.write(fd, payload_rg[off..]);
            try std.testing.expect(n > 0);
            off += @intCast(n);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), self_evolution.ingestOutcomes(a, &kg));
    ppaths.setEnv("METACODES_TASK_HINT", "solved-task");
    try std.testing.expect(cc.obligation_gate.load(a, &kg, "solved-task") == null);
    var built_rg = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conversation, &abort_signal);
    defer built_rg.deinit(a);
    const text_rg = built_rg.text orelse return error.TestExpectedInjection;
    try std.testing.expect(std.mem.indexOf(u8, text_rg, "REGRESSED from an already-proven configuration") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_rg, "damage introduced by that regression") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_rg, "tests=4/4") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_rg, "ESCALATED") == null);
    try std.testing.expect(std.mem.indexOf(u8, text_rg, "Per-point reading mode") == null);
    // v35 冲突记忆失效句(p35 取证:etag 剂量到达且 thinking 复述正确,
    // 行动被店内 CORRECTION 记忆反杀):静默 note 必须声明已证配置压过
    // 矛盾记忆。
    try std.testing.expect(std.mem.indexOf(u8, text_rg, "the proven configuration wins") != null);

    // v35 L2(静默换针,撤修复必红——v34 在解决态一律 load()==null):
    // 曾全过且最佳行携带工件路径 → 义务=复现最佳单针(工件路径逐字令),
    // 陈年 stored 义务仍拒载。
    {
        const payload_af = "{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[" ++
            "{\"task\":\"artifact-task\",\"attempt_key\":\"af1\",\"reward\":1.0,\"tests_passed\":3,\"tests_total\":3," ++
            "\"failing_tests\":[],\"final_note\":\"module landed; all green\"," ++
            "\"best_artifact\":\"--- pkg/_helper.py ---\\nfrom hashlib import sha256\\n\\n\\ndef calc_helper(filepath):\\n    return sha256(open(filepath,'rb').read()).hexdigest()[:16]\\n\"}]}";
        const pfs = @import("platform").fs;
        const za = try a.dupeZ(u8, outcomes_path);
        defer a.free(za);
        const fd = pfs.open(za.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = pfs.close(fd);
        var off: usize = 0;
        while (off < payload_af.len) {
            const n = pfs.write(fd, payload_af[off..]);
            try std.testing.expect(n > 0);
            off += @intCast(n);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), self_evolution.ingestOutcomes(a, &kg));
    {
        const payload_af2 = "{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[" ++
            "{\"task\":\"artifact-task\",\"attempt_key\":\"af2\",\"reward\":0.3,\"tests_passed\":1,\"tests_total\":3," ++
            "\"failing_tests\":[\"tests/af.py::T::t_regressed (failed: assert)\"]}]}";
        const pfs = @import("platform").fs;
        const zb = try a.dupeZ(u8, outcomes_path);
        defer a.free(zb);
        const fd = pfs.open(zb.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = pfs.close(fd);
        var off: usize = 0;
        while (off < payload_af2.len) {
            const n = pfs.write(fd, payload_af2[off..]);
            try std.testing.expect(n > 0);
            off += @intCast(n);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), self_evolution.ingestOutcomes(a, &kg));
    ppaths.setEnv("METACODES_TASK_HINT", "artifact-task");
    // 陈年义务:解决态必须拒载,即便换针通道开着。
    _ = kg.remember(.observation, "metacodes-provisional-obligation-v1 task=artifact-task needle=tests/af.py::T::t_stale reason=stale ghost", "provisional_obligation", false) catch {};
    {
        const runtime_af = cc.obligation_gate.load(a, &kg, "artifact-task") orelse
            return error.TestExpectedReproduceNeedle;
        defer {
            runtime_af.deinit();
            a.destroy(runtime_af);
        }
        // v44 更新(KG 12738):本 pin 的形态(带工件已解 + 最新行回归)与 etag
        // e2-dev 故障完全相同, 而"恰好 1 针"正是产出 0.2727 的那条策略——
        // p35 当年只证明了 0 针不如 1 针, 从未检验 1 针是否足够, e2-dev 补上
        // 了反例(剂量完整递送、agent 复述逐字指令, 仍被冲突记忆翻盘)。故计数
        // 断言放宽为"工件针在首 + 回归行派生针跟随"; 本 pin 真正守护的内容
        // (陈年 stored 义务必须拒载、工件针带 VERBATIM 且排第一)逐条保留。
        try std.testing.expect(runtime_af.envelopes.len >= 2);
        try std.testing.expectEqualStrings("pkg/_helper.py", runtime_af.envelopes[0].command_needle);
        try std.testing.expect(std.mem.indexOf(u8, runtime_af.envelopes[0].reason, "VERBATIM") != null);
        for (runtime_af.envelopes) |e| {
            try std.testing.expect(std.mem.indexOf(u8, e.command_needle, "t_stale") == null);
        }
    }
    // v36 读平面 supersede(撤修复必红——p36 取证:毒经 6 次主动 KgRecall
    // 绕过注入面,模型在正确路径写了冲突记忆的 async 版):① 静默态从已证
    // 工件正文词法提取定义符号;② 提及符号的非结局命中判 superseded。
    {
        var sym_storage: [cc.kg_scoped_recall.MAX_SUPERSEDED_SYMBOLS][64]u8 = undefined;
        var sym_lens: [cc.kg_scoped_recall.MAX_SUPERSEDED_SYMBOLS]usize = undefined;
        const n = cc.kg_scoped_recall.artifactSupersededSymbols(a, &kg, "artifact-task", &sym_storage, &sym_lens);
        try std.testing.expectEqual(@as(usize, 1), n);
        try std.testing.expectEqualStrings("calc_helper", sym_storage[0][0..sym_lens[0]]);
        const syms = [_][]const u8{sym_storage[0][0..sym_lens[0]]};
        try std.testing.expect(cc.tools.kg_tools.hitSupersededByArtifact(
            &syms,
            "CORRECTION: calc_helper is async and content-based",
            "observation",
        ));
        // 结局行永不盖戳(它携带裁决本身)。
        try std.testing.expect(!cc.tools.kg_tools.hitSupersededByArtifact(
            &syms,
            "task-outcome row mentioning calc_helper",
            "task_outcome",
        ));
        // 不提及符号的记忆不盖戳。
        try std.testing.expect(!cc.tools.kg_tools.hitSupersededByArtifact(
            &syms,
            "unrelated memory about widgets",
            "observation",
        ));
        // 非静默态任务(未曾全过)提不出符号。
        var sym_storage2: [cc.kg_scoped_recall.MAX_SUPERSEDED_SYMBOLS][64]u8 = undefined;
        var sym_lens2: [cc.kg_scoped_recall.MAX_SUPERSEDED_SYMBOLS]usize = undefined;
        try std.testing.expectEqual(@as(usize, 0), cc.kg_scoped_recall.artifactSupersededSymbols(a, &kg, "wall-task", &sym_storage2, &sym_lens2));
    }
    // v37 note 载体逐字指令(撤修复必红——p37 取证:义务提前 met 让 nudge
    // 里的 VERBATIM 指令永不送达,模型第三次徒手重打漏 'rb'):回归态
    // note 正文必须自带 FIRST-edit 逐字令与工件路径。
    {
        var built_vb = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conversation, &abort_signal);
        defer built_vb.deinit(a);
        const text_vb = built_vb.text orelse return error.TestExpectedInjection;
        try std.testing.expect(std.mem.indexOf(u8, text_vb, "FIRST EDIT: write the artifact quoted above to `pkg/_helper.py`") != null);
        try std.testing.expect(std.mem.indexOf(u8, text_vb, "byte-for-byte UNCHANGED") != null);
    }


    // v41 L2(针效能折叠,撤修复必红——旧码无遥测/无退休,二次 load 原样):
    // Rule A 惰性:同 cid 三轮 nudged=1 dispatched=0 遥测 → 针退休;
    // Rule B 非因果:met=1 且 best 无增 → 退休;增益行入店后针复活。
    {
        const payload_rt = "{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[" ++
            "{\"task\":\"ret-task\",\"attempt_key\":\"r1\",\"reward\":0.3,\"tests_passed\":1,\"tests_total\":3," ++
            "\"failing_tests\":[\"tests/rt.py::T::t_r (skipped: widget._retmod not available)\"]}]}";
        const pfs = @import("platform").fs;
        {
            const zr = try a.dupeZ(u8, outcomes_path);
            defer a.free(zr);
            const fd = pfs.open(zr.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
            try std.testing.expect(fd >= 0);
            defer _ = pfs.close(fd);
            var off: usize = 0;
            while (off < payload_rt.len) {
                const n = pfs.write(fd, payload_rt[off..]);
                try std.testing.expect(n > 0);
                off += @intCast(n);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), self_evolution.ingestOutcomes(a, &kg));
        ppaths.setEnv("METACODES_TASK_HINT", "ret-task");
        // 首次 load:派生针在场,取真 cid。
        var cid_buf: [64]u8 = undefined;
        var baseline_count: usize = 0;
        {
            const rt0 = cc.obligation_gate.load(a, &kg, "ret-task") orelse return error.TestExpectedRuntime;
            defer {
                rt0.deinit();
                a.destroy(rt0);
            }
            baseline_count = rt0.envelopes.len;
            try std.testing.expect(baseline_count >= 1);
            @memcpy(cid_buf[0..], rt0.envelopes[0].candidate_id[0..64]);
        }
        // Rule A:三轮惰性遥测(不同 run id,nudged=1 dispatched=0)。
        var round: usize = 0;
        while (round < 3) : (round += 1) {
            const trow = try std.fmt.allocPrint(a,
                "metacodes-needle-telemetry-v1: cid={s} task=ret-task run=ra{d} nudged=1 dispatched=0 met=0 best=0.3000 needle=x",
                .{ cid_buf[0..64], round });
            defer a.free(trow);
            _ = kg.remember(.observation, trow, "obligation_telemetry", false) catch {};
        }
        {
            const rt1 = cc.obligation_gate.load(a, &kg, "ret-task");
            if (rt1) |r1| {
                defer {
                    r1.deinit();
                    a.destroy(r1);
                }
                // 目标针必须消失(其余针可存续)。
                for (r1.envelopes) |envelope| {
                    try std.testing.expect(!std.mem.eql(u8, envelope.candidate_id[0..64], cid_buf[0..64]));
                }
                try std.testing.expect(r1.envelopes.len < baseline_count);
            }
            // null = 全部退休,同样满足断言语义。
        }
    }

    // v43 L2(重放自证伪,撤修复必红——旧码声明 1.0 后静默恒在:REGRESSED
    // 措辞常驻、压力针拒载、met 无增益针被 Rule B 错杀):
    // ① solved 行 + 连续 2 轮未达 → 静默解除:note 无 REGRESSED 措辞,
    //    load 装载完整压力栈(工件针+派生针);
    // ② solved 行 + 仅 1 轮未达(宽限) → REGRESSED 静默保持,且 v43 多文件
    //    工件的 (apply-diff) 段带 diff 应用指令;
    // ③ 声明失信时 Rule B 停用:met=1 且 best 无增益的针仍在场。
    {
        const artifact_block = "\nbest-attempt artifact (host-extracted, verbatim):" ++
            "\n--- pkg/repro_mod.py ---\nfrom hashlib import sha256\n\ndef make_tag(body):\n    return sha256(body).hexdigest()[:16]" ++
            "\n--- pkg/wire.py (apply-diff) ---\n@@ -10,3 +10,4 @@\n import os\n+from pkg.repro_mod import make_tag\n def handler():";
        const solved_row = "metacodes-task-outcome-v1: key=repro-task#s1 task=repro-task reward=1.0000 tests=3/3 prov=verifier failing=[]" ++ artifact_block;
        const fail_row_1 = "metacodes-task-outcome-v1: key=repro-task#f1 task=repro-task reward=0.4545 tests=1/3 prov=verifier failing=[tests/rp.py::T::t_wire (failed: assert)]";
        const fail_row_2 = "metacodes-task-outcome-v1: key=repro-task#f2 task=repro-task reward=0.4545 tests=1/3 prov=verifier failing=[tests/rp.py::T::t_wire (failed: assert)]";
        _ = kg.remember(.observation, solved_row, "task_outcome", false) catch {};
        _ = kg.remember(.observation, fail_row_1, "task_outcome", false) catch {};
        ppaths.setEnv("METACODES_TASK_HINT", "repro-task");
        // ② v44 改语义(原 v43 pin 锁的是 grace=2 的"1 连败仍静默"):
        // **一次未达即失信** → 静默立刻解除(无 REGRESSED 措辞), 但多文件工件
        // 与逐字令必须仍在——失信的回应是加压, 不是丢掉唯一已证配置。
        {
            var built_g = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conversation, &abort_signal);
            defer built_g.deinit(a);
            const text_g = built_g.text orelse return error.TestExpectedInjection;
            try std.testing.expect(std.mem.indexOf(u8, text_g, "REGRESSED from an already-proven configuration") == null);
            try std.testing.expect(std.mem.indexOf(u8, text_g, "pkg/wire.py (apply-diff)") != null);
            try std.testing.expect(std.mem.indexOf(u8, text_g, "FIRST EDIT") != null);
        }
        // ① 第二次未达:失信保持稳定(不因再次失败而回摆)。
        _ = kg.remember(.observation, fail_row_2, "task_outcome", false) catch {};
        {
            var built_i = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conversation, &abort_signal);
            defer built_i.deinit(a);
            const text_i = built_i.text orelse return error.TestExpectedInjection;
            try std.testing.expect(std.mem.indexOf(u8, text_i, "REGRESSED from an already-proven configuration") == null);
            try std.testing.expect(std.mem.indexOf(u8, text_i, "already proven by the verdict") == null);
        }
        var repro_cid: [64]u8 = undefined;
        {
            const rt_i = cc.obligation_gate.load(a, &kg, "repro-task") orelse return error.TestExpectedRuntime;
            defer {
                rt_i.deinit();
                a.destroy(rt_i);
            }
            // 完整压力栈:工件针之外必须还有派生针(旧码 reproduce_only 仅 1 针)。
            try std.testing.expect(rt_i.envelopes.len >= 2);
            var found_artifact_needle = false;
            for (rt_i.envelopes) |envelope| {
                if (std.mem.eql(u8, envelope.command_needle, "pkg/repro_mod.py")) {
                    found_artifact_needle = true;
                    @memcpy(repro_cid[0..], envelope.candidate_id[0..64]);
                }
            }
            try std.testing.expect(found_artifact_needle);
        }
        // ③ Rule B 豁免:met=1 且 best 记录声明值(1.0)→ 无豁免时
        // current_best(1.0)≤best_at+ε 必退;声明失信下针必须存活。
        {
            const trow = try std.fmt.allocPrint(a,
                "metacodes-needle-telemetry-v1: cid={s} task=repro-task run=rb0 nudged=0 dispatched=1 met=1 best=1.0000 needle=pkg/repro_mod.py",
                .{repro_cid[0..64]});
            defer a.free(trow);
            _ = kg.remember(.observation, trow, "obligation_telemetry", false) catch {};
            const rt_b = cc.obligation_gate.load(a, &kg, "repro-task") orelse return error.TestExpectedRuntime;
            defer {
                rt_b.deinit();
                a.destroy(rt_b);
            }
            var still_there = false;
            for (rt_b.envelopes) |envelope| {
                if (std.mem.eql(u8, envelope.candidate_id[0..64], repro_cid[0..64])) still_there = true;
            }
            try std.testing.expect(still_there);
        }
    }

    // v44 L2(etag 下滑环三修,撤任一修必红——KG 12738):
    // ① 宽限收紧:带工件声明**一次**未达即失信(旧码需连败 2 轮);
    // ② 复现态压力兜底:回归行下复现针之外必须挂该行派生针(旧码仅 1 针);
    // ③ 冲突记忆硬性撤回:被已证工件取代的记忆正文换存根(旧码仅加 caveat)。
    {
        const art = "\nbest-attempt artifact (host-extracted, verbatim):" ++
            "\n--- pkg/v44_mod.py ---\ndef make_tag(b):\n    return b[:8]";
        const solved = "metacodes-task-outcome-v1: key=v44-task#s1 task=v44-task reward=1.0000 tests=4/4 prov=verifier failing=[]" ++ art;
        const regressed = "metacodes-task-outcome-v1: key=v44-task#f1 task=v44-task reward=0.2500 tests=1/4 prov=verifier " ++
            "failing=[tests/v44.py::T::t_a (skipped: pkg.v44_helper not available)]";
        _ = kg.remember(.observation, solved, "task_outcome", false) catch {};
        _ = kg.remember(.observation, regressed, "task_outcome", false) catch {};
        ppaths.setEnv("METACODES_TASK_HINT", "v44-task");
        // ① 一次未达即失信 → 静默解除(旧码 grace=2 时此处仍静默)。
        var hist = std.array_list.Managed([]u8).init(a);
        defer {
            for (hist.items) |row| a.free(row);
            hist.deinit();
        }
        cc.kg_scoped_recall.collectHistory(a, &kg, "v44-task", &hist);
        try std.testing.expect(cc.obligation_gate.claimNotReproduced(hist.items));
        try std.testing.expectEqual(@as(usize, 1), cc.obligation_gate.REPRO_GRACE_ROUNDS);
        // ② 压力兜底:装载针数必须 >1(工件针 + 回归行派生针)。
        {
            const rt = cc.obligation_gate.load(a, &kg, "v44-task") orelse return error.TestExpectedRuntime;
            defer {
                rt.deinit();
                a.destroy(rt);
            }
            try std.testing.expect(rt.envelopes.len >= 2);
            var has_artifact_needle = false;
            for (rt.envelopes) |e| {
                if (std.mem.eql(u8, e.command_needle, "pkg/v44_mod.py")) has_artifact_needle = true;
            }
            try std.testing.expect(has_artifact_needle);
        }
        // ③ 冲突记忆正文撤回:走**真实渲染路径** appendRecallHitRow, 断言冲突
        // 记忆正文不再出现在 provider 可见 JSON 中(旧码只加 caveat、正文照发,
        // 模型两次据此翻盘:p35 与 e2-dev 同为 0.2727)。
        {
            const syms = [_][]const u8{"make_tag"};
            const poison = "CORRECTION: make_tag must be async and content-based";
            var row: std.ArrayList(u8) = .empty;
            defer row.deinit(a);
            const hit = cc.kg_client.RecallHit{
                .node_id = 4242,
                .kind = try a.dupe(u8, "observation"),
                .domain = try a.dupe(u8, "project"),
                .schema_type = try a.dupe(u8, "observation"),
                .text = try a.dupe(u8, poison),
                .text_total_bytes = poison.len,
                .text_truncated = false,
                .score = 9.0,
                .source_label = try a.dupe(u8, ""),
            };
            defer hit.deinit(a);
            try cc.tools.kg_tools.appendRecallHitRow(&row, a, hit, false, false, 4096, &syms);
            const rendered = row.items;
            try std.testing.expect(std.mem.indexOf(u8, rendered, "async and content-based") == null);
            try std.testing.expect(std.mem.indexOf(u8, rendered, "withdrawn by host-run artifact") != null);
            try std.testing.expect(std.mem.indexOf(u8, rendered, "\"body_withheld\":true") != null);
            try std.testing.expect(std.mem.indexOf(u8, rendered, "4242") != null);
            // 结局行携带裁决本身, 永不撤回。
            try std.testing.expect(!cc.tools.kg_tools.hitSupersededByArtifact(&syms, poison, "task_outcome"));
        }
    }

    // v38 L2(灌店自愈,撤修复必红——旧码同键双行永存且重摄取穿透):手工
    // 灌两条同键行(模拟跨 run 重摄取穿透),同键行再次到达时定点探测
    // GC 较老副本、拒绝再写:同键只剩一行,ingest 计 0。
    {
        const dup_row = "metacodes-task-outcome-v1: key=gc-task#g1 task=gc-task reward=0.5000 tests=1/2 prov=verifier failing=[tests/g.py::T::t_x (failed: assert)]";
        _ = kg.remember(.observation, dup_row, "task_outcome", false) catch {};
        _ = kg.remember(.observation, dup_row, "task_outcome", false) catch {};
        // 同键行再次到达(模拟下一轮根重投)。
        const payload_gc = "{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[" ++
            "{\"task\":\"gc-task\",\"attempt_key\":\"g1\",\"reward\":0.5,\"tests_passed\":1,\"tests_total\":2," ++
            "\"failing_tests\":[\"tests/g.py::T::t_x (failed: assert)\"]}]}";
        {
            const pfs = @import("platform").fs;
            const zg = try a.dupeZ(u8, outcomes_path);
            defer a.free(zg);
            const fd = pfs.open(zg.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
            try std.testing.expect(fd >= 0);
            defer _ = pfs.close(fd);
            var off: usize = 0;
            while (off < payload_gc.len) {
                const n = pfs.write(fd, payload_gc[off..]);
                try std.testing.expect(n > 0);
                off += @intCast(n);
            }
        }
        // 已在库且带名 → 拒绝重写(计 0);探测顺带 GC 较老副本。
        try std.testing.expectEqual(@as(usize, 0), self_evolution.ingestOutcomes(a, &kg));
        // 同键去重后仅剩一行(GC 保最新副本)。
        const hits_gc = kg.recallTyped("task-outcome-v1 gc-task", 50, false, "task_outcome") catch
            return error.TestExpectedRecall;
        defer {
            for (hits_gc) |*h| h.deinit(kg.allocator);
            kg.allocator.free(hits_gc);
        }
        var remaining: usize = 0;
        for (hits_gc) |h| {
            if (std.mem.indexOf(u8, h.text, " key=gc-task#g1 ") != null) remaining += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), remaining);
    }

    // v35 L2(cap 钉最佳,撤修复必红——旧 cap 只留最新 8 行,最老的全过
    // 行被驱逐 → 曾经全过失明 → 鬼义务复武装):唯一全过行最老 + 8 条
    // 回归行,曾经全过判定必须仍然成立(回归框架 note + 零陈年义务)。
    {
        const pfs = @import("platform").fs;
        var attempt: usize = 0;
        while (attempt < 9) : (attempt += 1) {
            const payload_cap = if (attempt == 0)
                try std.fmt.allocPrint(a,
                    "{{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[" ++
                        "{{\"task\":\"cap-task\",\"attempt_key\":\"c{d}\",\"reward\":1.0,\"tests_passed\":2,\"tests_total\":2," ++
                        "\"failing_tests\":[],\"final_note\":\"proven early\"}}]}}", .{attempt})
            else
                try std.fmt.allocPrint(a,
                    "{{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[" ++
                        "{{\"task\":\"cap-task\",\"attempt_key\":\"c{d}\",\"reward\":0.5,\"tests_passed\":1,\"tests_total\":2," ++
                        "\"failing_tests\":[\"tests/cap.py::T::t_late (failed: assert)\"]}}]}}", .{attempt});
            defer a.free(payload_cap);
            const zc = try a.dupeZ(u8, outcomes_path);
            defer a.free(zc);
            const fd = pfs.open(zc.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
            try std.testing.expect(fd >= 0);
            defer _ = pfs.close(fd);
            var off: usize = 0;
            while (off < payload_cap.len) {
                const n = pfs.write(fd, payload_cap[off..]);
                try std.testing.expect(n > 0);
                off += @intCast(n);
            }
            try std.testing.expectEqual(@as(usize, 1), self_evolution.ingestOutcomes(a, &kg));
        }
        ppaths.setEnv("METACODES_TASK_HINT", "cap-task");
        _ = kg.remember(.observation, "metacodes-provisional-obligation-v1 task=cap-task needle=tests/cap.py::T::t_ghost reason=stale ghost", "provisional_obligation", false) catch {};
        // 最佳行无工件 → 真静默(零义务);cap 若驱逐 1.0 行则鬼义务复载。
        try std.testing.expect(cc.obligation_gate.load(a, &kg, "cap-task") == null);
        var built_cap = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conversation, &abort_signal);
        defer built_cap.deinit(a);
        const text_cap = built_cap.text orelse return error.TestExpectedInjection;
        try std.testing.expect(std.mem.indexOf(u8, text_cap, "REGRESSED from an already-proven configuration") != null);
        try std.testing.expect(std.mem.indexOf(u8, text_cap, "Garbage In, Garbage Out") == null);
    }
    ppaths.setEnv("METACODES_TASK_HINT", "wall-task");

    // UTF-8 截断安全(p10 现场雷):中文 note >300 字节,裸字节截断切码点
    // 中间 → tinykg InvalidRecord 整行丢失。必须退到码点边界后成功入店。
    {
        var long_note = std.array_list.Managed(u8).init(a);
        defer long_note.deinit();
        var i: usize = 0;
        while (i < 120) : (i += 1) try long_note.appendSlice("判定结论");
        const payload4 = try std.fmt.allocPrint(a,
            "{{\"schema_version\":\"task-outcome-v1\",\"outcomes\":[" ++
                "{{\"task\":\"utf8-task\",\"attempt_key\":\"a1\",\"reward\":0.1,\"tests_passed\":1,\"tests_total\":2," ++
                "\"failing_tests\":[\"some named check\"],\"final_note\":\"{s}\"}}]}}",
            .{long_note.items});
        defer a.free(payload4);
        const pfs = @import("platform").fs;
        const z4 = try a.dupeZ(u8, outcomes_path);
        defer a.free(z4);
        const fd = pfs.open(z4.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = pfs.close(fd);
        var off: usize = 0;
        while (off < payload4.len) {
            const n = pfs.write(fd, payload4[off..]);
            try std.testing.expect(n > 0);
            off += @intCast(n);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), self_evolution.ingestOutcomes(a, &kg));
}

// 取证重放(环境门控,CI 永不跑):对真实导出 store 跑 v15 note 构造器,
// 对拍生产 stderr 里的 bytes/sha。METACODES_REPLAY_STORE=<store dir> 激活。
test "forensic replay: deterministic note against real store" {
    const a = std.testing.allocator;
    const store_c = std.c.getenv("METACODES_REPLAY_STORE") orelse return error.SkipZigTest;
    const store = std.mem.span(store_c);
    const kg_bin = if (std.c.getenv("METACODES_REPLAY_KG_BIN")) |b|
        try a.dupe(u8, std.mem.span(b))
    else
        findKgBin(a) orelse return error.SkipZigTest;
    defer a.free(kg_bin);
    @import("platform").paths.setEnv("METACODES_TASK_HINT", "feature-medium-etag_header_for_static");
    @import("platform").paths.setEnv("METACODES_KG_TRANSPORT", "cli-exclusive");
    // 可选:先重放 ingest(METACODES_REPLAY_OUTCOMES=<file>)再看注入。
    if (std.c.getenv("METACODES_REPLAY_OUTCOMES")) |of| {
        @import("platform").paths.setEnv("METACODES_TASK_OUTCOMES", of);
        var kg0 = try cc.kg_client.KgClient.init(a, .{
            .home = "/tmp/replay-home",
            .domain = "workspace-5807156e",
            .config_bin = kg_bin,
            .config_store = store,
            .env_bin = "",
            .env_store = "",
        });
        defer kg0.deinit();
        kg0.ensureReady();
        const n = cc.self_evolution.ingestOutcomes(a, &kg0);
        std.debug.print("REPLAY ingest wrote {d} rows\n", .{n});
    }
    const domains = [_][]const u8{ "workspace-5807156e", "workspace", "global" };
    for (domains) |domain| {
        var kg = try cc.kg_client.KgClient.init(a, .{
            .home = "/tmp/replay-home",
            .domain = domain,
            .config_bin = kg_bin,
            .config_store = store,
            .env_bin = "",
            .env_store = "",
        });
        defer kg.deinit();
        kg.ensureReady();
        std.debug.print("domain={s} ready={}\n", .{ domain, kg.ready });
        {
            const hits = kg.recallTyped("metacodes-outcome-note-v1 feature-medium-etag_header_for_static", 40, false, "task_outcome") catch &.{};
            defer {
                for (hits) |*h| h.deinit(kg.allocator);
                kg.allocator.free(hits);
            }
            std.debug.print("  recall hits={d}\n", .{hits.len});
            for (hits) |h| if (std.mem.indexOf(u8, h.text, "etag_header") != null) {
                std.debug.print("  hit id={d} trunc={} len={d}\n", .{ h.node_id, h.text_truncated, h.text.len });
            };
        }
        const note = cc.scoped_recall.sameTaskOutcomeNote(a, &kg) orelse {
            std.debug.print("domain={s}: note=null\n", .{domain});
            continue;
        };
        defer a.free(note);
        var sha_buf: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(note, &sha_buf, .{});
        std.debug.print("domain={s} bytes={d} sha={x}\n", .{ domain, note.len, sha_buf[0..8] });
        std.debug.print("---- note ----\n{s}\n---- end ----\n", .{note});
        break;
    }
}
