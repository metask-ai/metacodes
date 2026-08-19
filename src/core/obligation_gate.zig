//! 任务范围收尾义务的执行面(动态层"合法过拟合"的 actuation 半边)。
//!
//! 义务由运行期 author 从任务环境学得(self_evolution.ObligationEnvelope,
//! 绑定 task_sha256、随店走、可撤回);本模块只做两件事:
//! ① 观察本 Run 内执行过的 Bash 命令,子串命中即记 met;
//! ② 提前收尾时对未满足义务给**有界 nudge**(ledger 同款哲学:纯注入、
//!    绝不硬拒、预算封顶、prompt 未给不罚)。
//! 策略纯函数 decide() 与 Lean 文档级证明镜面对应
//! (control-plane/lean/MetaCodesControl/ObligationGate.lean)。

const std = @import("std");
const self_evolution = @import("self_evolution.zig");
const kg_client_mod = @import("../kg/client.zig");

pub const MAX_OBLIGATION_NUDGES: u8 = 2;

pub const NUDGE_FMT =
    "[task obligation]\n" ++
    "A rule you authored for this task in a previous attempt is not yet " ++
    "satisfied: {s}\n" ++
    "It requires that, before finishing, you execute a command containing " ++
    "`{s}` and it must SUCCEED. Run it now and show the outcome. If the " ++
    "reference names a file, module, class or function that does not exist, " ++
    "that absence is the unfinished work itself — create the named artifact " ++
    "at exactly the location the reference implies, then run the command " ++
    "again until it succeeds. Absence is never inapplicability, and a " ++
    "substitute check of your own does not satisfy this rule.";

pub const Decision = struct {
    /// 需要 nudge 的义务下标;null = 无动作。
    index: ?usize,
};

pub const Runtime = struct {
    arena: std.heap.ArenaAllocator,
    envelopes: []self_evolution.ObligationEnvelope,
    met: []bool,
    nudged: []bool,
    /// 每义务一个待验证 dispatch id 槽(后发覆盖先发;同批多命中最坏丢
    /// 一次早成功 → 义务保持未满足 → 至多多一次 nudge,有界)。
    pending_ids: [][64]u8,
    pending_lens: []usize,
    nudges_used: u8 = 0,

    pub fn deinit(self: *Runtime) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const Runtime) usize {
        return self.envelopes.len;
    }

    /// 成功条件义务 2.0(p7-p9 取证:失败的 pytest 收集被当作履约):
    /// dispatch 只记账,met 由 observeResult 在该命令**成功**时置位。
    pub fn observeDispatch(self: *Runtime, id: []const u8, command: []const u8) void {
        for (self.envelopes, 0..) |envelope, index| {
            if (self.met[index]) continue;
            if (std.mem.indexOf(u8, command, envelope.command_needle) == null) continue;
            if (id.len == 0 or id.len > self.pending_ids[index].len) continue;
            @memcpy(self.pending_ids[index][0..id.len], id);
            self.pending_lens[index] = id.len;
        }
    }

    /// 结果观察:待验证 id 的执行成功 → met(单调:met 永不撤销——
    /// Lean 镜面 met_monotone)。失败结果不满足也不清账(同 id 不复用)。
    pub fn observeResult(self: *Runtime, id: []const u8, success: bool) void {
        if (!success) return;
        for (self.envelopes, 0..) |_, index| {
            if (self.met[index]) continue;
            const len = self.pending_lens[index];
            if (len == 0 or len != id.len) continue;
            if (!std.mem.eql(u8, self.pending_ids[index][0..len], id)) continue;
            self.met[index] = true;
        }
    }

    /// 提前收尾时的策略(纯:只读状态,不落副作用——调用方按返回值
    /// 记账,与 ledger 的 State.decide 同款)。Lean 镜面:ObligationGate。
    pub fn decide(self: *const Runtime) Decision {
        if (self.nudges_used >= MAX_OBLIGATION_NUDGES) return .{ .index = null };
        for (self.envelopes, 0..) |_, index| {
            if (self.met[index] or self.nudged[index]) continue;
            return .{ .index = index };
        }
        return .{ .index = null };
    }

    /// 记账:该义务已 nudge(每义务一次,全局预算封顶)。
    pub fn noteNudged(self: *Runtime, index: usize) void {
        self.nudged[index] = true;
        self.nudges_used += 1;
    }
};

/// GIGO 门:host 从同题上次结局行机械派生证据 token(失败/跳过名),构造
/// 会话本地义务——不落库、不等 author 两轮学习。"什么算 token"是工程
/// 分类器;策略与 author 义务共用同一 Runtime,Lean ObligationGate 定理
/// (met/nudged 永不再选、预算封顶、纯注入)原样覆盖。
pub const MAX_DERIVED: usize = 3;
pub const GIGO_REASON =
    "input-audit (Garbage In, Garbage Out): a previous attempt failed " ++
    "exactly this point. Reproduce before you fix — make the referenced " ++
    "check itself collect and succeed; if what it names is missing, " ++
    "creating it at the named location is the work, not grounds to skip";

/// 从结局行文本("… failing=[a, b, c]")解析派生义务,追加进 list(去重、
/// 截 " (skipped)" 后缀、边界过滤)。返回追加条数。
fn appendDerived(
    a: std.mem.Allocator,
    list: *std.array_list.Managed(self_evolution.ObligationEnvelope),
    task_sha: [64]u8,
    row_text: []const u8,
) usize {
    const open = std.mem.indexOf(u8, row_text, "failing=[") orelse return 0;
    const body_start = open + "failing=[".len;
    const close = std.mem.lastIndexOfScalar(u8, row_text, ']') orelse return 0;
    if (close <= body_start) return 0;
    var appended: usize = 0;
    var it = std.mem.splitSequence(u8, row_text[body_start..close], ", ");
    while (it.next()) |raw_name| {
        if (appended >= MAX_DERIVED) break;
        var needle = std.mem.trim(u8, raw_name, " ");
        if (std.mem.endsWith(u8, needle, " (skipped)"))
            needle = needle[0 .. needle.len - " (skipped)".len];
        if (needle.len < self_evolution.MIN_NEEDLE_LEN or
            needle.len > self_evolution.MAX_NEEDLE_LEN) continue;
        var duplicate = false;
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing.command_needle, needle)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        const owned_needle = a.dupe(u8, needle) catch continue;
        const cid = self_evolution.obligationCandidateId(task_sha[0..], owned_needle, GIGO_REASON);
        const owned_cid = a.dupe(u8, cid[0..]) catch continue;
        const owned_task = a.dupe(u8, task_sha[0..]) catch continue;
        list.append(.{
            .candidate_id = owned_cid,
            .task_sha256 = owned_task,
            .command_needle = owned_needle,
            .reason = GIGO_REASON,
        }) catch continue;
        appended += 1;
    }
    return appended;
}

/// 从 KG 装载当前任务的义务运行时(author 学得的 + GIGO 派生的)。
/// 两路皆空/店不可用 → null(零开销)。
pub fn load(
    gpa: std.mem.Allocator,
    kg: *kg_client_mod.KgClient,
    task_hint: []const u8,
) ?*Runtime {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const stored = self_evolution.collectObligations(a, kg, task_hint) catch {
        arena.deinit();
        return null;
    };
    var combined = std.array_list.Managed(self_evolution.ObligationEnvelope).init(a);
    combined.appendSlice(stored) catch {
        arena.deinit();
        return null;
    };
    if (task_hint.len > 0 and task_hint.len <= 200) {
        const scoped_recall = @import("../kg/scoped_recall.zig");
        if (scoped_recall.sameTaskOutcomeRow(a, kg, task_hint)) |row| {
            _ = appendDerived(a, &combined, self_evolution.taskIdentity(task_hint), row);
        }
    }
    const envelopes = combined.items;
    if (envelopes.len == 0) {
        arena.deinit();
        return null;
    }
    const met = a.alloc(bool, envelopes.len) catch {
        arena.deinit();
        return null;
    };
    const nudged = a.alloc(bool, envelopes.len) catch {
        arena.deinit();
        return null;
    };
    const pending_ids = a.alloc([64]u8, envelopes.len) catch {
        arena.deinit();
        return null;
    };
    const pending_lens = a.alloc(usize, envelopes.len) catch {
        arena.deinit();
        return null;
    };
    @memset(met, false);
    @memset(nudged, false);
    @memset(pending_lens, 0);
    const runtime = gpa.create(Runtime) catch {
        arena.deinit();
        return null;
    };
    runtime.* = .{
        .arena = arena,
        .envelopes = envelopes,
        .met = met,
        .nudged = nudged,
        .pending_ids = pending_ids,
        .pending_lens = pending_lens,
    };
    return runtime;
}

fn testRuntime(envelope_count: usize) Runtime {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const a = arena.allocator();
    const envelopes = a.alloc(self_evolution.ObligationEnvelope, envelope_count) catch unreachable;
    for (envelopes, 0..) |*e, i| {
        e.* = .{
            .candidate_id = "00" ** 32,
            .task_sha256 = "11" ** 32,
            .command_needle = if (i == 0) "pytest test_a.py" else "make check",
            .reason = "learned closure obligation",
        };
    }
    const met = a.alloc(bool, envelope_count) catch unreachable;
    const nudged = a.alloc(bool, envelope_count) catch unreachable;
    const pending_ids = a.alloc([64]u8, envelope_count) catch unreachable;
    const pending_lens = a.alloc(usize, envelope_count) catch unreachable;
    @memset(met, false);
    @memset(nudged, false);
    @memset(pending_lens, 0);
    return .{
        .arena = arena,
        .envelopes = envelopes,
        .met = met,
        .nudged = nudged,
        .pending_ids = pending_ids,
        .pending_lens = pending_lens,
    };
}

test "GIGO derivation parses failing names, strips skip suffix, dedupes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var list = std.array_list.Managed(self_evolution.ObligationEnvelope).init(a);
    const task_sha = self_evolution.taskIdentity("etag-task");
    const row = "task-outcome-v1: key=etag-task#a1 task=etag-task reward=0.27 tests=3/11 " ++
        "failing=[tests/t.py::TestX::test_uses_sha256 (skipped), etag present, etag present, ab]";
    const n = appendDerived(a, &list, task_sha, row);
    try std.testing.expectEqual(@as(usize, 2), n); // 重复去重 + "ab" 过短被滤
    try std.testing.expectEqualStrings("tests/t.py::TestX::test_uses_sha256", list.items[0].command_needle);
    try std.testing.expectEqualStrings("etag present", list.items[1].command_needle);
    try std.testing.expectEqualStrings(GIGO_REASON, list.items[0].reason);
}

test "only a successful execution satisfies the obligation" {
    // 2.0 回归钉:p7-p9 里"跑了但收集失败"的 pytest 被当作履约。
    var runtime = testRuntime(1);
    defer runtime.arena.deinit();
    try std.testing.expectEqual(@as(?usize, 0), runtime.decide().index);
    runtime.observeDispatch("call_1", "cd /workspace && pytest test_a.py -q");
    runtime.observeResult("call_1", false);
    try std.testing.expectEqual(@as(?usize, 0), runtime.decide().index);
    runtime.observeDispatch("call_2", "pytest test_a.py -q");
    runtime.observeResult("call_2", true);
    try std.testing.expectEqual(@as(?usize, null), runtime.decide().index);
    // met 单调:后续失败不撤销(Lean 镜面 met_monotone)。
    runtime.observeDispatch("call_3", "pytest test_a.py -q");
    runtime.observeResult("call_3", false);
    try std.testing.expectEqual(@as(?usize, null), runtime.decide().index);
}

test "each obligation nudges at most once and the budget is global" {
    // Lean mirror: ObligationGate.per_obligation_one_shot / budget_bound.
    var runtime = testRuntime(2);
    defer runtime.arena.deinit();
    const first = runtime.decide().index orelse return error.TestExpectedNudge;
    runtime.noteNudged(first);
    const second = runtime.decide().index orelse return error.TestExpectedNudge;
    try std.testing.expect(second != first);
    runtime.noteNudged(second);
    try std.testing.expectEqual(@as(?usize, null), runtime.decide().index);
    // 预算封顶:即使有第三个义务也不再 nudge(nudges_used=2)。
    try std.testing.expectEqual(@as(u8, 2), runtime.nudges_used);
}

test "unmatched command leaves the obligation open" {
    var runtime = testRuntime(1);
    defer runtime.arena.deinit();
    runtime.observeDispatch("call_x", "ls -la");
    runtime.observeResult("call_x", true);
    try std.testing.expectEqual(@as(?usize, 0), runtime.decide().index);
}
