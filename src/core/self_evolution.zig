//! 臂内自演化(self-learning S1-S3):记忆连续性链上的临时规则闭环。
//!
//! 一次 headless Run 结束后,若本 Run 的观察日志满足稀疏触发条件
//! (repeated_typed_failure:≥3 次权威非成功),host 以隔离的单次
//! provider 调用走既有 evolution 管线(TinyKG 本体投影 → rule author →
//! RuleCandidate),把提案落成 KG store 里的 provisional_rule 节点——
//! 节点随 memory-accumulation 连续性链跨 trial 存活。下一个 Run 启动时,
//! 把 provisional 规则并入(或在无活跃束时单独构成)项目规则 gate,由
//! 固定 kernel 以 enforced 模式裁决。
//!
//! 临时规则不经 Lean 晋升管线;它的表达力被 project_rule_spec 的封闭
//! 枚举 IR 限死在任务无关的过程义务上,且每条都带 candidate 回执可反查。
//! 规则效果(命中/阻断计数)在 Run 末写回 KG 观察节点,进入下一轮
//! 本体投影——ontology→rules→behavior→observations→ontology 闭环。
//!
//! 铁律:本模块绝不触碰 actor Conversation/工具目录;author 调用只在
//! Run 结束后发生,不影响可缓存首请求;一切失败静默降级为"无规则/
//! 不提案",绝不让自演化故障放倒宿主 Run。

const std = @import("std");
const kg_client_mod = @import("../kg/client.zig");
const evolution = @import("project_rule_evolution.zig");
const rule_author = @import("rule_author.zig");
const rule_candidate = @import("rule_candidate.zig");
const spec_mod = @import("project_rule_spec.zig");
const bundle_mod = @import("project_rule_bundle.zig");
const runtime_gate_mod = @import("project_rule_gate.zig");
const kernel = @import("../formal/project_harness_runtime.zig");
const journal_mod = @import("tool_observation_journal.zig");
const observation = @import("../tools/observation.zig");
const protocol = @import("../tools/project_rule_gate.zig");
const provider_mod = @import("../api/provider.zig");
const activation_mod = @import("project_rule_activation.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const log = @import("../util/log.zig");

pub const ENV_FLAG = "METACODES_SELF_EVOLUTION";
pub const SCHEMA_TYPE = "provisional_rule";
pub const RETRACT_SCHEMA_TYPE = "provisional_rule_retracted";
// impact 记录直接以受治理 proposition 落库(rememberOntologyItem),不再有
// 专用 schema_type——schema_type 在 tinykg 不可事后翻转,必须建节点时就定。
/// impact 行正文前缀,滚动窗口按它召回旧行。
pub const IMPACT_MARKER = "provisional-rule-impact-v1";
pub const MARKER = "metacodes-provisional-rule-v1";
pub const RETRACT_MARKER = "metacodes-provisional-rule-retract-v1";
pub const MAX_PROVISIONAL_RULES: usize = 8;
/// 与真实晋升 revision 空间隔开的哨兵位移,журnal 事件里一眼可辨临时束。
pub const PROVISIONAL_REVISION_BASE: u64 = 1_000_000;

/// 每次 author 调用的硬上限(单价来源=保守常数,与 caps 一起保证
/// worst-case 成本可被 cost cap 覆盖;真实计费由 provider 侧结算)。
pub const AUTHOR_MAX_INPUT_TOKENS: u64 = 48_000;
/// 必须 ≥ actor provider 的 max_tokens 设置(rule_author.author 拒绝
/// provider.maxTokens() > cap;eval 里 actor 用 16384,非 eval 默认 32k)。
pub const AUTHOR_MAX_OUTPUT_TOKENS: u64 = 40_000;
/// 必须 ≥ rule_author.worstCaseCost(caps, pricing):输入按
/// max(input, cache_read, cache_write)=2.5µ$/Ktok 计 48k→120k,输出
/// 6µ$/Ktok 计 40k→240k,worst=360k。上限是许可天花板不是预期花费;
/// 实际 author 输出是一小段 JSON。有静态测试钉住这笔账。
pub const AUTHOR_MAX_COST_MICROUSD: u64 = 400_000;
fn authorPricing() rule_author.PricingAuthority {
    return .{
        .provenance_sha256 = observation.sha256Hex("metacodes-self-evolution-pricing-v1"),
        .input_microusd_per_mtok = 2_000_000,
        .output_microusd_per_mtok = 6_000_000,
        .cache_read_microusd_per_mtok = 200_000,
        .cache_write_microusd_per_mtok = 2_500_000,
    };
}

pub fn enabledFromEnv() bool {
    const raw = std.c.getenv(ENV_FLAG) orelse return false;
    const value = std.mem.span(raw);
    return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");
}

/// KG 节点文本信封。字段顺序即规范序;marker 字段兼作 recallTyped 的
/// 词法检索锚(TinyKG 无向量检索,固定 token 保证可召回)。
pub const Envelope = struct {
    schema_version: []const u8 = MARKER,
    candidate_id: []const u8,
    invariant_sha256: []const u8,
    lean_source_sha256: []const u8,
    rule: spec_mod.Wire,
};

pub const RetractEnvelope = struct {
    schema_version: []const u8 = RETRACT_MARKER,
    candidate_id: []const u8,
    reason: []const u8,
};

pub fn encodeEnvelope(allocator: std.mem.Allocator, envelope: Envelope) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, envelope, .{});
}

pub fn parseEnvelope(arena: std.mem.Allocator, text: []const u8) !Envelope {
    const parsed = try std.json.parseFromSliceLeaky(Envelope, arena, text, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    if (!std.mem.eql(u8, parsed.schema_version, MARKER)) return error.UnknownEnvelope;
    if (parsed.candidate_id.len != 64) return error.InvalidCandidateId;
    for (parsed.candidate_id) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return error.InvalidCandidateId,
    };
    // spec 必须能过封闭枚举校验——坏信封在装载期拒绝,不进 gate。
    const spec = try spec_mod.fromWire(parsed.rule);
    try spec_mod.validate(spec);
    // 无差别封禁核心工具没有任何合法过程义务读法,只会砖掉后续所有
    // trial(过程义务=边界/复观测/权威性要求,不是"禁用 Edit")。
    if (spec.deny_target and spec.target_scope == .all) {
        switch (spec.target) {
            .tool => |tool_name| {
                const core = [_][]const u8{ "Read", "Edit", "Write", "Bash" };
                for (core) |name| {
                    if (std.mem.eql(u8, tool_name, name))
                        return error.CoreToolBlanketDeny;
                }
            },
            .effect_class => {},
        }
    }
    return parsed;
}

fn parseRetraction(arena: std.mem.Allocator, text: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(RetractEnvelope, arena, text, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return null;
    if (!std.mem.eql(u8, parsed.schema_version, RETRACT_MARKER)) return null;
    if (parsed.candidate_id.len != 64) return null;
    return parsed.candidate_id;
}

/// 装载结果:合并(或独立)的临时规则运行时。持有自己的 LoadedActive,
/// 生命周期与 Run 等长;宿主在 Run 结束后 deinit。
pub const ProvisionalGate = struct {
    allocator: std.mem.Allocator,
    active: *bundle_mod.LoadedActive,
    runtime: runtime_gate_mod.RuntimeGate,
    provisional_count: usize,
    /// 临时规则的 candidate id 清单(borrow 自 active 的 arena;与 gate
    /// 同生命周期)。熔断器用它写撤回信封。
    provisional_candidate_ids: []const []const u8,

    pub fn gate(self: *ProvisionalGate) protocol.Gate {
        return self.runtime.protocolGate();
    }

    pub fn deinit(self: *ProvisionalGate) void {
        const allocator = self.allocator;
        self.active.deinit();
        allocator.destroy(self.active);
        allocator.destroy(self);
    }
};

/// 从 KG store 收集有效临时规则信封(去重、去撤回、封顶)。
/// 返回的切片与其内容都挂在 arena 上。
pub fn collectEnvelopes(
    arena: std.mem.Allocator,
    kg: *kg_client_mod.KgClient,
) ![]Envelope {
    var retracted = std.StringHashMapUnmanaged(void){};
    if (kg.recallTyped(
        RETRACT_MARKER,
        MAX_PROVISIONAL_RULES * 4,
        false,
        RETRACT_SCHEMA_TYPE,
    )) |retract_hits| {
        // recallTyped 返回 owned slice:逐项 deinit + free(kg_tools 同款
        // 惯用法;绝不对 catch 出来的静态空哨兵调 free)。
        defer {
            for (retract_hits) |*hit| hit.deinit(kg.allocator);
            kg.allocator.free(retract_hits);
        }
        for (retract_hits) |hit| {
            const full = kg.fetchNodeText(hit.node_id) catch continue;
            defer kg.allocator.free(full);
            if (parseRetraction(arena, full)) |cid|
                try retracted.put(arena, try arena.dupe(u8, cid), {});
        }
    } else |_| {}

    var out = std.array_list.Managed(Envelope).init(arena);
    var seen = std.StringHashMapUnmanaged(void){};
    if (kg.recallTyped(
        MARKER,
        MAX_PROVISIONAL_RULES * 4,
        false,
        SCHEMA_TYPE,
    )) |hits| {
        defer {
            for (hits) |*hit| hit.deinit(kg.allocator);
            kg.allocator.free(hits);
        }
        for (hits) |hit| {
            if (out.items.len >= MAX_PROVISIONAL_RULES) break;
            const full = kg.fetchNodeText(hit.node_id) catch continue;
            defer kg.allocator.free(full);
            const envelope = parseEnvelope(arena, full) catch continue;
            if (retracted.contains(envelope.candidate_id)) continue;
            if (seen.contains(envelope.candidate_id)) continue;
            try seen.put(arena, envelope.candidate_id, {});
            try out.append(envelope);
        }
    } else |_| {}
    return out.items;
}

/// 由(可选的)活跃束 + 临时信封构造合并 LoadedActive。哨兵 revision 与
/// 内容寻址 bundle_sha 让 journal 事件里的临时束身份可辨、可披露。
pub fn buildMergedActive(
    allocator: std.mem.Allocator,
    base: ?*const bundle_mod.LoadedActive,
    project_sha256: [64]u8,
    kernel_sha256: [64]u8,
    envelopes: []const Envelope,
) !*bundle_mod.LoadedActive {
    if (envelopes.len == 0) return error.NoProvisionalRules;
    const self = try allocator.create(bundle_mod.LoadedActive);
    errdefer allocator.destroy(self);
    self.* = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .project_sha256 = project_sha256,
        .bundle_sha256 = undefined,
        .revision = PROVISIONAL_REVISION_BASE +
            (if (base) |b| b.revision else 0) + envelopes.len,
        .kernel_sha256 = kernel_sha256,
        .promotion_receipt_id = [_]u8{'0'} ** 64,
        .promotion_request_sha256 = [_]u8{'0'} ** 64,
        .promotion_verdict_sha256 = [_]u8{'0'} ** 64,
        .active_pointer_sha256 = [_]u8{'0'} ** 64,
        .rules = &.{},
    };
    errdefer self.arena.deinit();
    const a = self.arena.allocator();

    const base_len: usize = if (base) |b| b.rules.len else 0;
    var rules = try a.alloc(bundle_mod.RuleEntry, base_len + envelopes.len);
    if (base) |b| for (b.rules, 0..) |entry, i| {
        rules[i] = .{
            .candidate_id = try a.dupe(u8, entry.candidate_id),
            .rule_spec = try dupeWire(a, entry.rule_spec),
        };
    };
    for (envelopes, 0..) |envelope, i| {
        rules[base_len + i] = .{
            .candidate_id = try a.dupe(u8, envelope.candidate_id),
            .rule_spec = try dupeWire(a, envelope.rule),
        };
    }
    self.rules = rules;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("metacodes-provisional-bundle-v1\x00");
    if (base) |b| hasher.update(&b.bundle_sha256);
    for (envelopes) |envelope| {
        hasher.update(envelope.candidate_id);
        const canonical = try std.json.Stringify.valueAlloc(a, envelope.rule, .{});
        hasher.update(canonical);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    self.bundle_sha256 = std.fmt.bytesToHex(digest, .lower);
    return self;
}

fn dupeWire(a: std.mem.Allocator, wire: spec_mod.Wire) !spec_mod.Wire {
    var out = wire;
    out.schema_version = try a.dupe(u8, wire.schema_version);
    out.target = try a.dupe(u8, wire.target);
    return out;
}

/// S2 入口:KG 里有有效临时规则 → 构造(合并)gate;没有 → null。
/// 任何 KG/解析失败都降级为 null(store 降级不放倒 Run)。
pub fn loadProvisionalGate(
    allocator: std.mem.Allocator,
    kg: *kg_client_mod.KgClient,
    base: ?*const bundle_mod.LoadedActive,
    project_root: []const u8,
    session_dir: []const u8,
    abort: ?*const AbortSignal,
    observation_sink: ?observation.Sink,
) ?*ProvisionalGate {
    if (observation_sink == null) return null;
    const config = switch (kernel.loadConfigFromEnv()) {
        .configured => |value| value,
        else => return null, // 无 kernel 身份 = 无法裁决 = 不装临时规则
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const envelopes = collectEnvelopes(arena.allocator(), kg) catch return null;
    if (envelopes.len == 0) return null;
    const project_sha = if (base) |b| b.project_sha256 else bundle_mod.projectIdentity(project_root);
    const active = buildMergedActive(
        allocator,
        base,
        project_sha,
        config.expected_sha256,
        envelopes,
    ) catch return null;
    const self = allocator.create(ProvisionalGate) catch {
        active.deinit();
        allocator.destroy(active);
        return null;
    };
    const base_len: usize = if (base) |b| b.rules.len else 0;
    const provisional_ids = blk: {
        const ids = active.arena.allocator().alloc(
            []const u8,
            active.rules.len - base_len,
        ) catch break :blk &[_][]const u8{};
        for (active.rules[base_len..], 0..) |entry, i| ids[i] = entry.candidate_id;
        break :blk ids;
    };
    self.* = .{
        .allocator = allocator,
        .active = active,
        .provisional_candidate_ids = provisional_ids,
        .runtime = .{
            .allocator = allocator,
            .active = active,
            .config = config,
            .abort = abort,
            // 尊重编译期 actuation 边界(shadow 评估构建里临时规则也
            // 必须是 shadow,绝不能让模型自写规则在 shadow 臂改变轨迹)。
            .actuation = activation_mod.artifact_actuation,
            .evidence_dir = session_dir,
            .observation_sink = observation_sink,
            .auto_exact_edit_recovery = true,
        },
        .provisional_count = envelopes.len,
    };
    return self;
}

/// 结局回灌(两遍法基座):host 把已完成 trial 的 verifier 结局写成
/// /logs/agent/task-outcomes.json,binary 在 Run 开始时摄取为 KG 观察
/// 节点(schema_type=task_outcome)。同任务同 attempt 幂等;节点随
/// 连续性链跨 trial/跨遍存活,scoped recall 与本体投影自然可见——
/// pass 2 重做任务 X 时,"上一遍 X 挂了哪些测试"就在召回面里。
pub const OUTCOME_SCHEMA_TYPE = "task_outcome";
pub const OUTCOME_MARKER = "task-outcome-v1";
comptime {
    // 确定性同题注入(kg/scoped_recall)按同一前缀识别结局行——漂移即断链。
    if (!std.mem.eql(u8, OUTCOME_MARKER, @import("../kg/scoped_recall.zig").OUTCOME_NOTE_MARKER))
        @compileError("outcome marker drift between self_evolution and scoped_recall");
}
pub const OUTCOMES_ENV = "METACODES_TASK_OUTCOMES";
pub const REPORT_ENV = "METACODES_SELF_EVOLUTION_REPORT";
/// 上限受 tinykg search --limit 约束:KgClient 超采 = 2L+4,tinykg HEAD
/// 上限 100 → L ≤ 48。40 留余量;静态测试钉死这笔账(2026-08-18 审查 B1:
/// 128→超采 260→InvalidLimit→去重全灭→重复节点毒化召回槽)。
pub const MAX_OUTCOME_ROWS: usize = 40;
pub const MAX_OUTCOME_BYTES: usize = 256 * 1024;

const OutcomeRow = struct {
    task: []const u8,
    attempt_key: []const u8,
    reward: f64,
    tests_passed: u32 = 0,
    tests_total: u32 = 0,
    failing_tests: []const []const u8 = &.{},
};

const OutcomeFile = struct {
    schema_version: []const u8,
    outcomes: []const OutcomeRow,
};

/// 摄取入口:失败静默(回灌是增强不是依赖),返回新写入节点数。
pub fn ingestOutcomes(
    allocator: std.mem.Allocator,
    kg: *kg_client_mod.KgClient,
) usize {
    const raw_path = std.c.getenv(OUTCOMES_ENV) orelse return 0;
    const pfs = @import("platform").fs;
    const fd = pfs.open(raw_path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return 0;
    defer _ = pfs.close(fd);
    const info = pfs.fileInfo(fd) catch return 0;
    if (!info.is_regular or info.size == 0 or info.size > MAX_OUTCOME_BYTES) return 0;
    const bytes = allocator.alloc(u8, @intCast(info.size)) catch return 0;
    defer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = pfs.read(fd, bytes[offset..]);
        if (n <= 0) return 0;
        offset += @intCast(n);
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(OutcomeFile, arena.allocator(), bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return 0;
    if (!std.mem.eql(u8, parsed.schema_version, OUTCOME_MARKER)) return 0;

    // 幂等:已在库的 (task, attempt_key) 不重写。
    var seen = std.StringHashMapUnmanaged(void){};
    if (kg.recallTyped(OUTCOME_MARKER, MAX_OUTCOME_ROWS, false, OUTCOME_SCHEMA_TYPE)) |hits| {
        defer {
            for (hits) |*hit| hit.deinit(kg.allocator);
            kg.allocator.free(hits);
        }
        for (hits) |hit| {
            // key 在文本前 ~60 字节;hit.text 已带前 800 字节,避免逐 hit
            // spawn get(2026-08-18 审查 R4)。
            if (extractOutcomeKey(hit.text)) |key| {
                seen.put(arena.allocator(), arena.allocator().dupe(u8, key) catch continue, {}) catch continue;
                continue;
            }
            const full = kg.fetchNodeText(hit.node_id) catch continue;
            defer kg.allocator.free(full);
            if (extractOutcomeKey(full)) |key|
                seen.put(arena.allocator(), arena.allocator().dupe(u8, key) catch continue, {}) catch continue;
        }
    } else |_| {}

    var written: usize = 0;
    for (parsed.outcomes, 0..) |row, index| {
        if (index >= MAX_OUTCOME_ROWS) break;
        if (row.task.len == 0 or row.task.len > 200) continue;
        if (row.attempt_key.len == 0 or row.attempt_key.len > 200) continue;
        var key_buffer: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buffer, "{s}#{s}", .{ row.task, row.attempt_key }) catch continue;
        if (seen.contains(key)) continue;
        var failing = std.array_list.Managed(u8).init(allocator);
        defer failing.deinit();
        for (row.failing_tests, 0..) |name, i| {
            if (i >= 20) break;
            if (i > 0) failing.appendSlice(", ") catch break;
            failing.appendSlice(if (name.len > 160) name[0..160] else name) catch break;
        }
        const text = std.fmt.allocPrint(
            allocator,
            OUTCOME_MARKER ++ ": key={s} task={s} reward={d:.4} tests={d}/{d} failing=[{s}]",
            .{ key, row.task, row.reward, row.tests_passed, row.tests_total, failing.items },
        ) catch continue;
        defer allocator.free(text);
        _ = kg.remember(.observation, text, OUTCOME_SCHEMA_TYPE, false) catch continue;
        written += 1;
    }
    if (written > 0)
        log.info("self-evolution", "ingested {d} task outcomes", .{written});
    return written;
}

fn extractOutcomeKey(text: []const u8) ?[]const u8 {
    const prefix = OUTCOME_MARKER ++ ": key=";
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    const rest = text[prefix.len..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    return rest[0..end];
}

pub const EndOfRunDeps = struct {
    kg: *kg_client_mod.KgClient,
    session_dir: []const u8,
    project_root: []const u8,
    provider: provider_mod.Provider,
    /// actor provider 的身份串(base_url+model 即可);author 身份由它
    /// 加角色后缀派生——这是防同角色误配的辨识,不是端点来源证明。
    actor_identity: []const u8,
    model: []const u8,
    run_binding: journal_mod.RunBinding,
    now_ns: i128,
    stop_reason: []const u8,
    provisional_active_count: usize,
    provisional_candidate_ids: []const []const u8 = &.{},
    provisional_bundle_sha256: ?[64]u8 = null,
    outcomes_ingested: usize = 0,
    abort: ?*const AbortSignal,
};

/// 单 Run 内规则阻断数达到此阈值 = 规则风暴(几乎必然是一条把自己
/// 砖住的坏规则):熔断——写撤回信封,下一 Run 不再装载。
pub const RETRACT_BLOCK_STORM_THRESHOLD: u64 = 8;

/// 诊断报告:结局/错误名/剂量计数落到 host 可见的文件(/logs/agent 挂载),
/// 让"零剂量"永远可归因(2026-08-18 审查 B4:r2 全臂 degraded 无迹可查)。
pub fn writeReport(
    allocator: std.mem.Allocator,
    outcome: []const u8,
    detail: []const u8,
    ingested: usize,
    provisional_loaded: usize,
) void {
    const raw_path = std.c.getenv(REPORT_ENV) orelse return;
    const text = std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":\"self-evolution-report-v1\",\"outcome\":\"{s}\"," ++
            "\"detail\":\"{s}\",\"outcomes_ingested\":{d},\"provisional_loaded\":{d}}}\n",
        .{ outcome, detail, ingested, provisional_loaded },
    ) catch return;
    defer allocator.free(text);
    const pfs = @import("platform").fs;
    const fd = pfs.open(raw_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return;
    defer _ = pfs.close(fd);
    var offset: usize = 0;
    while (offset < text.len) {
        const n = pfs.write(fd, text[offset..]);
        if (n <= 0) return;
        offset += @intCast(n);
    }
}

pub const Outcome = enum {
    disabled,
    no_trigger,
    ontology_missing,
    abstained,
    proposed,
    degraded,
};

/// S1+S3 入口。一切错误路径降级返回,不向宿主传播。
fn finish(
    allocator: std.mem.Allocator,
    deps: EndOfRunDeps,
    outcome: Outcome,
    detail: []const u8,
) Outcome {
    writeReport(
        allocator,
        @tagName(outcome),
        detail,
        deps.outcomes_ingested,
        deps.provisional_active_count,
    );
    return outcome;
}

pub fn endOfRun(allocator: std.mem.Allocator, deps: EndOfRunDeps) Outcome {
    // S3:每 Run 过程战绩写回本体(规则效果计数 + formal_faults 等过程
    // 信号)。不 gate 在 provisional_active_count 上:无规则时计数照样是
    // host 观测的过程事实,也是 author 冷启动仅有的本体内容;每 run 恰好
    // 1 节点,有界。
    writeImpactObservation(allocator, deps);

    const actor_sha = observation.sha256Hex(deps.actor_identity);
    var role_buffer: [512]u8 = undefined;
    const role_identity = std.fmt.bufPrint(
        &role_buffer,
        "{s}#self-evolution-rule-author-v1",
        .{deps.actor_identity},
    ) catch return finish(allocator, deps, .degraded, "unspecified");
    const author_sha = observation.sha256Hex(role_identity);
    var budget_buffer: [256]u8 = undefined;
    const budget_seed = std.fmt.bufPrint(
        &budget_buffer,
        "self-evolution-inline-budget-v1:{s}",
        .{deps.run_binding.run_id.asSlice()},
    ) catch return finish(allocator, deps, .degraded, "unspecified");

    const rules_root = std.fs.path.dirname(deps.session_dir) orelse return finish(allocator, deps, .degraded, "unspecified");
    var rules_dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const rules_dir = std.fmt.bufPrint(
        &rules_dir_buffer,
        "{s}/project-rules",
        .{rules_root},
    ) catch return finish(allocator, deps, .degraded, "unspecified");

    var source = evolution.KgClientSource.init(deps.kg);
    const kernel_config: ?kernel.Config = switch (kernel.loadConfigFromEnv()) {
        .configured => |value| value,
        else => null,
    };

    // 防泄漏框架的臂内实例化:生成窗 = 本 Run 的认证 journal 区间
    // (host_observation);held-out = 本任务尚未揭晓的 verifier 结局承诺。
    // 两个 window member 前缀不同,恰好互斥。
    const projection = @import("ontology_rule_projection.zig");
    var gen_member_buffer: [256]u8 = undefined;
    const gen_member_seed = std.fmt.bufPrint(
        &gen_member_buffer,
        "self-evolution-generation:{s}",
        .{deps.run_binding.run_id.asSlice()},
    ) catch return finish(allocator, deps, .degraded, "unspecified");
    var generation = projection.deriveRunObservationEvidence(
        allocator,
        deps.session_dir,
        bundle_mod.projectIdentity(deps.project_root),
        deps.run_binding,
        observation.sha256Hex(gen_member_seed),
    ) catch |err| {
        log.warn("self-evolution", "generation evidence degraded: {s}", .{@errorName(err)});
        return finish(allocator, deps, .degraded, @errorName(err));
    };
    defer generation.deinit();
    var held_member_buffer: [256]u8 = undefined;
    const held_member_seed = std.fmt.bufPrint(
        &held_member_buffer,
        "self-evolution-held-out-verifier:{s}",
        .{deps.run_binding.run_id.asSlice()},
    ) catch return finish(allocator, deps, .degraded, "unspecified");
    const held_member = observation.sha256Hex(held_member_seed);
    const held_members = [_][]const u8{held_member[0..]};
    const held_suite = observation.sha256Hex("workbuddy-held-out-verifier-suite-v1");
    const held_commitment = projection.heldOutCommitmentSha256(
        allocator,
        held_suite,
        &held_members,
    ) catch |err| {
        log.warn("self-evolution", "held-out commitment degraded: {s}", .{@errorName(err)});
        return finish(allocator, deps, .degraded, @errorName(err));
    };
    const held = [_]projection.HeldOutCommitment{.{
        .commitment_sha256 = held_commitment[0..],
        .suite_sha256 = held_suite[0..],
        .case_count = held_members.len,
        .member_sha256 = &held_members,
        .sealed = true,
    }};

    // 触发链:先过程信号轴(测试弱化/假闭合/终验失败——selflearn-r1
    // 判读确认本 cohort 的死法是"安静做错",不是工具失败风暴),不满足
    // 再退回 repeated_typed_failure。两次 prepare 都是离线零花费。
    const triggers = [_]rule_author.Trigger{
        .process_signal,
        .repeated_typed_failure,
    };
    var prepared: evolution.Prepared = undefined;
    var prepared_ready = false;
    for (triggers) |trigger| {
        prepared = evolution.prepare(allocator, .{
            .session_dir = deps.session_dir,
            .project_root = deps.project_root,
            .project_rules_dir = rules_dir,
            .ontology_source = source.source(),
            .kernel_config = kernel_config,
            .author_sha256 = author_sha,
            .actor_provider_sha256 = actor_sha,
            .provider_sha256 = author_sha,
            .budget_authorization_sha256 = observation.sha256Hex(budget_seed),
            .model = deps.model,
            .observation = deps.run_binding,
            .trigger = trigger,
            .evidence = &.{},
            .caps = .{
                .max_cost_microusd = AUTHOR_MAX_COST_MICROUSD,
                .max_input_tokens = AUTHOR_MAX_INPUT_TOKENS,
                .max_output_tokens = AUTHOR_MAX_OUTPUT_TOKENS,
            },
            .pricing = authorPricing(),
            .generation_evidence = &.{generation.value},
            .held_out_commitments = &held,
        }) catch |err| switch (err) {
            error.TriggerNotSatisfied => continue,
            error.ProjectOntologyMissing => return finish(allocator, deps, .ontology_missing, @errorName(err)),
            else => {
                log.warn("self-evolution", "prepare degraded: {s}", .{@errorName(err)});
                return finish(allocator, deps, .degraded, @errorName(err));
            },
        };
        prepared_ready = true;
        break;
    }
    if (!prepared_ready) return finish(allocator, deps, .no_trigger, "");
    defer prepared.deinit();

    const permit = rule_author.authorize(&prepared.author_request, .{
        .enabled = true,
        .now_ns = deps.now_ns,
        .cooldown_ns = 0,
        .remaining_requests = 1,
        .remaining_cost_microusd = AUTHOR_MAX_COST_MICROUSD,
        .remaining_input_tokens = AUTHOR_MAX_INPUT_TOKENS,
        .remaining_output_tokens = AUTHOR_MAX_OUTPUT_TOKENS,
    }) catch |err| {
        log.warn("self-evolution", "authorize degraded: {s}", .{@errorName(err)});
        return finish(allocator, deps, .degraded, @errorName(err));
    };

    const outcome = evolution.authorOnce(&prepared, .{
        .provider = deps.provider,
        .provider_sha256 = author_sha,
    }, permit, deps.abort) catch |err| {
        log.warn("self-evolution", "author degraded: {s}", .{@errorName(err)});
        return finish(allocator, deps, .degraded, @errorName(err));
    };

    if (outcome.decision != .propose or outcome.candidate_id == null)
        return finish(allocator, deps, .abstained, "");

    var loaded = rule_candidate.load(
        allocator,
        deps.session_dir,
        outcome.candidate_id.?,
    ) catch return finish(allocator, deps, .degraded, "unspecified");
    defer loaded.deinit();

    const envelope = Envelope{
        .candidate_id = outcome.candidate_id.?[0..],
        .invariant_sha256 = loaded.invariant_sha256[0..],
        .lean_source_sha256 = loaded.lean_source_sha256[0..],
        .rule = spec_mod.toWire(loaded.rule_spec),
    };
    const text = encodeEnvelope(allocator, envelope) catch return finish(allocator, deps, .degraded, "unspecified");
    defer allocator.free(text);
    _ = deps.kg.remember(.observation, text, SCHEMA_TYPE, false) catch |err|
        return finish(allocator, deps, .degraded, @errorName(err));
    return finish(allocator, deps, .proposed, "");
}

/// 把 marker 开头的旧本体行(keep_id 除外)标记 deprecated_by → keep_id,
/// 返回成功打边数。best-effort:召回或打边失败只缩小窗口效果,不报错——
/// 快照条目上限的硬保护由每 run 必执行的本函数收敛(漏网行下 run 再收)。
pub fn deprecateStaleOntologyRows(kg: *kg_client_mod.KgClient, marker: []const u8, keep_id: u64) usize {
    var deprecated: usize = 0;
    if (kg.recallTyped(marker, 40, false, "proposition")) |hits| {
        defer {
            for (hits) |*hit| hit.deinit(kg.allocator);
            kg.allocator.free(hits);
        }
        for (hits) |hit| {
            if (hit.node_id == keep_id) continue;
            // BM25 是词法邻近,可能捎带非 impact 的 proposition——按正文
            // 前缀二次确认,绝不误伤其它本体条目。
            if (!std.mem.startsWith(u8, hit.text, marker)) continue;
            kg.addEdge(hit.node_id, "deprecated_by", keep_id) catch continue;
            deprecated += 1;
        }
    } else |_| {}
    return deprecated;
}

fn writeImpactObservation(allocator: std.mem.Allocator, deps: EndOfRunDeps) void {
    var run = journal_mod.loadRunDispatches(
        allocator,
        deps.session_dir,
        deps.run_binding,
    ) catch return;
    defer run.deinit();
    const impact_stats = @import("rule_impact_stats.zig");
    var snapshot = impact_stats.derive(allocator, &run, .{}) catch return;
    defer snapshot.deinit(allocator);
    const bundle_hex: []const u8 = if (deps.provisional_bundle_sha256) |*sha|
        sha[0..]
    else
        "none";
    // run_id 必须进正文:tinykg 召回按文本重合折叠近重复,多个 run 的
    // 计数全零时文本逐字节相同 → search 只返回 1 条代表(常为新行自身)
    // → 滚动窗口永远打不出 deprecated_by 边(selflearn 两遍法生产取证:
    // 32 条全可见零边,再 16 run 撞快照 48 上限)。唯一文本同时让 author
    // packet 的本体行可区分。
    const text = std.fmt.allocPrint(
        allocator,
        "provisional-rule-impact-v1: run={s} active_rules={d} pre_dispatch_blocks={d} " ++
            "formal_faults={d} authoritative_non_successes={d} stop_reason={s} " ++
            "provisional_bundle_sha256={s}",
        .{
            deps.run_binding.run_id.asSlice(),
            deps.provisional_active_count,
            snapshot.enforced_pre_blocks_before_dispatch,
            snapshot.formal_faults,
            snapshot.authoritative_non_successes,
            deps.stop_reason,
            bundle_hex,
        },
    ) catch return;
    defer allocator.free(text);
    // 受治理本体命题(F1):快照只导出带 authority/falsifier/provenance 的
    // 四类 schema_type,普通记忆永不投影——这是 r2 零剂量的第三层根因。
    // impact 记录是 host 观测、任务无关、每 run 一条,恰是 author 该看到的
    // 过程级战绩。best-effort:失败不影响主流程(client 侧 forget 保证不留
    // 半成品毒化快照)。
    const impact_sha = observation.sha256Hex(text);
    const new_id = deps.kg.rememberOntologyItem(
        text,
        "proposition",
        "host_observed",
        "a run journal interval whose dispatch counters contradict this record",
        &impact_sha,
    ) catch |err| {
        log.warn(
            "self-evolution",
            "impact ontology write degraded: {s}",
            .{@errorName(err)},
        );
        return;
    };
    // 滚动窗口:快照对 >48 条可见条目是整体报错(OntologySnapshotTooLarge,
    // 数据面 :272),每 run +1 条不清理会在第 49 个 run 永久毒化投影。旧
    // impact 行的信息已被最新行取代(跨 run 趋势由熔断器独立承担),全部
    // deprecate——投影按 deprecated_by 出边**静默跳过**("v1 exports only
    // current candidates"),这是设计内出口;schema_type/retrieval_excluded
    // 均不可经 CLI 改写(实测 InvalidRecord)。召回上限 40 = 去重召回同款
    // tinykg --limit 安全值,覆盖两遍法全部 32 个 run。
    _ = deprecateStaleOntologyRows(deps.kg, IMPACT_MARKER, new_id);

    // 熔断器(2026-08-18 审查 P1-2c):坏规则的唯一带内逃生通道。阻断
    // 风暴 → 撤回全部临时规则;author 之后可以基于战绩重新提案更好的。
    if (snapshot.enforced_pre_blocks_before_dispatch >= RETRACT_BLOCK_STORM_THRESHOLD) {
        for (deps.provisional_candidate_ids) |cid| {
            const retract = std.json.Stringify.valueAlloc(allocator, RetractEnvelope{
                .candidate_id = cid,
                .reason = "block-storm circuit breaker",
            }, .{}) catch continue;
            defer allocator.free(retract);
            _ = deps.kg.remember(
                .observation,
                retract,
                RETRACT_SCHEMA_TYPE,
                false,
            ) catch continue;
        }
        log.warn(
            "self-evolution",
            "block storm ({d} blocks) — retracted {d} provisional rules",
            .{ snapshot.enforced_pre_blocks_before_dispatch, deps.provisional_candidate_ids.len },
        );
    }
}

// ---------------------------------------------------------------------------

test "author caps cover the worst-case cost and the actor output setting" {
    // P0 回归钉(2026-08-18 审查):这两条算不平,自演化在任何 Run 上都
    // 会在 prepare 第一行静默降级——一个测试就能拦住的静默空转。
    const worst = try rule_author.worstCaseCost(.{
        .max_cost_microusd = AUTHOR_MAX_COST_MICROUSD,
        .max_input_tokens = AUTHOR_MAX_INPUT_TOKENS,
        .max_output_tokens = AUTHOR_MAX_OUTPUT_TOKENS,
    }, authorPricing());
    try std.testing.expect(AUTHOR_MAX_COST_MICROUSD >= worst);
    const util_model = @import("../util/model.zig");
    try std.testing.expect(AUTHOR_MAX_OUTPUT_TOKENS >= util_model.DEFAULT_MAX_TOKENS);
}

test "outcome key extraction round-trips through the node text shape" {
    const text = OUTCOME_MARKER ++ ": key=etag#a1 task=etag reward=0.2727 tests=3/11 failing=[t1, t2]";
    try std.testing.expectEqualStrings("etag#a1", extractOutcomeKey(text).?);
    try std.testing.expect(extractOutcomeKey("other text") == null);
}

test "process-signal trigger fires on weakening, tier0-with-mutations, or known-failing" {
    // selflearn-r1 剂量为零的根因是触发轴错位;新轴按真实死法设计,
    // 单测钉住谓词语义。
    const ta = @import("rule_author.zig");
    const stats = @import("rule_impact_stats.zig");
    var snapshot = std.mem.zeroInit(stats.Snapshot, .{
        .source_interval_sha256 = [_]u8{'0'} ** 64,
        .labels = stats.RunLabels{},
        .rules = &[_]stats.RuleStats{},
    });
    const sat = struct {
        fn check(s2: stats.Snapshot) bool {
            return ta.testTriggerSatisfied(.process_signal, s2, &.{});
        }
    }.check;
    try std.testing.expect(!sat(snapshot));
    snapshot.test_weakening_candidates = 2;
    try std.testing.expect(sat(snapshot));
    snapshot.test_weakening_candidates = 1;
    try std.testing.expect(!sat(snapshot));
    snapshot.weakening_with_failed_verification = 1;
    try std.testing.expect(sat(snapshot));
    snapshot.weakening_with_failed_verification = 0;
    snapshot.final_closure_tier0_with_mutations = true;
    try std.testing.expect(sat(snapshot));
    snapshot.final_closure_tier0_with_mutations = false;
    snapshot.known_failing = true;
    try std.testing.expect(sat(snapshot));
}

test "envelope round-trips through encode/parse with spec validation" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const envelope = Envelope{
        .candidate_id = &([_]u8{'a'} ** 64),
        .invariant_sha256 = &([_]u8{'c'} ** 64),
        .lean_source_sha256 = &([_]u8{'d'} ** 64),
        .rule = .{
            .target_kind = .effect_class,
            .target = "existing_file_rewrite",
            .target_scope = .existing_file,
            .deny_target = false,
            .max_input_bytes = 1024 * 1024,
            .max_agent_depth = 4,
            .authoritative_only = true,
            .effect_requirement = .file_mutation_v1_reobserved,
        },
    };
    const text = try encodeEnvelope(a, envelope);
    defer a.free(text);
    const parsed = try parseEnvelope(arena.allocator(), text);
    try std.testing.expectEqualStrings(envelope.invariant_sha256, parsed.invariant_sha256);
    try std.testing.expectEqual(spec_mod.TargetKind.effect_class, parsed.rule.target_kind);
}

test "parseEnvelope rejects wrong marker, bad candidate id and invalid spec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(
        error.UnknownEnvelope,
        parseEnvelope(a, "{\"schema_version\":\"other\",\"candidate_id\":\"" ++ ("a" ** 64) ++ "\",\"invariant_sha256\":\"x\",\"lean_source_sha256\":\"y\",\"rule\":{\"schema_version\":\"metacodes-project-rule-spec-v3\",\"target_kind\":\"tool\",\"target\":\"Write\",\"target_scope\":\"all\",\"deny_target\":true,\"max_input_bytes\":1,\"max_agent_depth\":1,\"authoritative_only\":false,\"effect_requirement\":\"none\"}}"),
    );
    try std.testing.expectError(
        error.InvalidCandidateId,
        parseEnvelope(a, "{\"schema_version\":\"" ++ MARKER ++ "\",\"candidate_id\":\"short\",\"invariant_sha256\":\"x\",\"lean_source_sha256\":\"y\",\"rule\":{\"schema_version\":\"metacodes-project-rule-spec-v3\",\"target_kind\":\"tool\",\"target\":\"Write\",\"target_scope\":\"all\",\"deny_target\":true,\"max_input_bytes\":1,\"max_agent_depth\":1,\"authoritative_only\":false,\"effect_requirement\":\"none\"}}"),
    );
}

test "buildMergedActive appends provisional entries behind base rules" {
    const a = std.testing.allocator;
    var base = bundle_mod.LoadedActive{
        .arena = std.heap.ArenaAllocator.init(a),
        .project_sha256 = [_]u8{'1'} ** 64,
        .bundle_sha256 = [_]u8{'2'} ** 64,
        .revision = 7,
        .kernel_sha256 = [_]u8{'3'} ** 64,
        .promotion_receipt_id = [_]u8{'0'} ** 64,
        .promotion_request_sha256 = [_]u8{'0'} ** 64,
        .promotion_verdict_sha256 = [_]u8{'0'} ** 64,
        .active_pointer_sha256 = [_]u8{'0'} ** 64,
        .rules = &.{.{
            .candidate_id = "base-rule",
            .rule_spec = .{
                .target_kind = .tool,
                .target = "Write",
                .deny_target = true,
                .max_input_bytes = 1,
                .max_agent_depth = 1,
                .authoritative_only = false,
                .effect_requirement = .none,
            },
        }},
    };
    defer base.arena.deinit();
    const envelopes = [_]Envelope{.{
        .candidate_id = &([_]u8{'b'} ** 64),
        .invariant_sha256 = &([_]u8{'e'} ** 64),
        .lean_source_sha256 = &([_]u8{'f'} ** 64),
        .rule = .{
            .target_kind = .tool,
            .target = "Edit",
            .deny_target = false,
            .max_input_bytes = 2048,
            .max_agent_depth = 2,
            .authoritative_only = true,
            .effect_requirement = .none,
        },
    }};
    const merged = try buildMergedActive(
        a,
        &base,
        base.project_sha256,
        [_]u8{'9'} ** 64,
        &envelopes,
    );
    defer {
        merged.deinit();
        a.destroy(merged);
    }
    try std.testing.expectEqual(@as(usize, 2), merged.rules.len);
    try std.testing.expectEqualStrings("base-rule", merged.rules[0].candidate_id);
    try std.testing.expectEqualStrings("Edit", merged.rules[1].rule_spec.target);
    try std.testing.expectEqual(PROVISIONAL_REVISION_BASE + 7 + 1, merged.revision);
    // bundle sha 是内容寻址且非全零
    try std.testing.expect(!std.mem.eql(u8, &merged.bundle_sha256, &([_]u8{'0'} ** 64)));
    // 无信封 = 明确错误,不产生空束
    try std.testing.expectError(
        error.NoProvisionalRules,
        buildMergedActive(a, &base, base.project_sha256, [_]u8{'9'} ** 64, &.{}),
    );
}
