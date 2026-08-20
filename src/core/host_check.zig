//! host-run 裁决:收尾时 host 进程亲自执行**开工即钉住**的检查命令,把
//! (exit code, 输出) 经 verdict codec(raw 兜底)解析成 outcome 行直接入库。
//!
//! 权威内化的核心:模型无权改写命令、无权解读输出——"概念上已验证"绕不过
//! 一次 host 亲手跑的检查。诚实半边:检查涉及的文件若在本次运行被改动,
//! 行降级 host_run_tainted(机械检测,git status 交集),溯源策略
//! (Lean VerdictProvenance)保证污染行在同分下绝不压过干净行。
//!
//! 钉住协议:METACODES_HOST_CHECK 在进程启动时读取并**内容哈希固定**;
//! 收尾执行前重读环境比对哈希,不匹配即拒跑(fail-closed,防运行期被
//! 篡改——模型工具面能 export 环境变量的话就是攻击面)。

const std = @import("std");
const verdict = @import("verdict.zig");
const kg_client_mod = @import("../kg/client.zig");
const self_evolution = @import("self_evolution.zig");
const log = @import("../util/log.zig");

pub const CHECK_ENV = "METACODES_HOST_CHECK";
pub const MAX_OUTPUT_BYTES: usize = 256 * 1024;
pub const TIMEOUT_MS: u32 = 180_000;

/// 开工钉住:命令 + 内容哈希。启动期调用一次,收尾执行时比对。
pub const Pin = struct {
    command: [512]u8 = undefined,
    command_len: usize = 0,
    sha256: [32]u8 = undefined,

    pub fn fromEnv() ?Pin {
        const raw = std.c.getenv(CHECK_ENV) orelse return null;
        const cmd = std.mem.span(raw);
        if (cmd.len == 0 or cmd.len > 512) return null;
        var pin = Pin{};
        @memcpy(pin.command[0..cmd.len], cmd);
        pin.command_len = cmd.len;
        std.crypto.hash.sha2.Sha256.hash(cmd, &pin.sha256, .{});
        return pin;
    }

    pub fn commandSlice(self: *const Pin) []const u8 {
        return self.command[0..self.command_len];
    }

    /// 收尾校验:环境里的命令仍与钉住哈希一致。不一致 → 拒跑(fail-closed)。
    pub fn stillIntact(self: *const Pin) bool {
        const raw = std.c.getenv(CHECK_ENV) orelse return false;
        const cmd = std.mem.span(raw);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(cmd, &digest, .{});
        return std.mem.eql(u8, &digest, &self.sha256);
    }
};

pub const Summary = struct {
    passed: u32,
    total: u32,
    tainted: bool,
    ingested: usize,
};

fn runShell(allocator: std.mem.Allocator, command: []const u8) ?struct { output: []u8, exit_code: i64 } {
    const common = @import("../tools/common.zig");
    const cmd_z = allocator.dupeZ(u8, command) catch return null;
    defer allocator.free(cmd_z);
    const argv = [_]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr, null };
    const result = common.spawnCaptureWithStderrTimed(&argv, allocator, null, TIMEOUT_MS, null, MAX_OUTPUT_BYTES, null) catch return null;
    defer allocator.free(result.stderr);
    // stderr 并入 stdout 尾部(pytest 摘要走 stdout,编译器/rust 走 stderr;
    // raw 兜底需要两者)。
    var merged = std.array_list.Managed(u8).init(allocator);
    merged.appendSlice(result.stdout) catch {
        allocator.free(result.stdout);
        return null;
    };
    allocator.free(result.stdout);
    if (result.stderr.len > 0) {
        merged.appendSlice("\n") catch {};
        merged.appendSlice(result.stderr) catch {};
    }
    const output = merged.toOwnedSlice() catch return null;
    return .{ .output = output, .exit_code = result.exit_code };
}

/// 收尾执行:跑钉住检查 → 解析 → 污染检测 → git 工件 → 合成行 → 入库。
/// 任何一步失败降级为 null(绝不放倒 Run;host 裁决是增强不是门)。
pub fn runAndIngest(
    allocator: std.mem.Allocator,
    kg: *kg_client_mod.KgClient,
    pin: *const Pin,
    task_hint: []const u8,
    final_note: []const u8,
    attempt_seed_ns: u64,
) ?Summary {
    if (task_hint.len == 0 or task_hint.len > 200) return null;
    if (!pin.stillIntact()) {
        log.warn("verdict", "host check pin mismatch — refusing to execute (fail-closed)", .{});
        return null;
    }
    const run = runShell(allocator, pin.commandSlice()) orelse return null;
    defer allocator.free(run.output);
    var parsed = verdict.parseAuto(allocator, run.output, run.exit_code) catch return null;
    defer parsed.deinit();

    // 污染检测 + 工件(best-effort;git 不在或非仓库 → 空)。
    var tainted = false;
    if (runShell(allocator, "git status --porcelain")) |st| {
        defer allocator.free(st.output);
        tainted = verdict.taintedByWorkspaceEdits(&parsed, st.output);
    }
    var artifact: []u8 = &.{};
    defer if (artifact.len > 0) allocator.free(artifact);
    if (runShell(allocator, "git diff HEAD")) |df| {
        defer allocator.free(df.output);
        artifact = verdict.extractNewFileArtifact(allocator, df.output) catch &.{};
    }

    var attempt_buffer: [32]u8 = undefined;
    const attempt_key = std.fmt.bufPrint(&attempt_buffer, "host{x:0>16}", .{attempt_seed_ns}) catch return null;
    const provenance: verdict.Provenance = if (tainted) .host_run_tainted else .host_run;
    const json = verdict.composeOutcomesJson(allocator, &parsed, .{
        .task = task_hint,
        .attempt_key = attempt_key,
        .provenance = provenance,
        .final_note = final_note,
        .best_artifact = artifact,
    }) catch return null;
    defer allocator.free(json);
    const ingested = self_evolution.ingestOutcomesFromText(allocator, kg, json);
    log.warn("verdict", "host check verdict: {d}/{d} passed prov={s} ingested={d}", .{
        parsed.passed, parsed.total, @tagName(provenance), ingested,
    });
    return .{ .passed = parsed.passed, .total = parsed.total, .tainted = tainted, .ingested = ingested };
}

// ── 测试 ─────────────────────────────────────────────────────────────

test "pin: content hash fixed at start, mismatch refuses (fail-closed)" {
    const ppaths = @import("platform").paths;
    ppaths.setEnv(CHECK_ENV, "pytest -q");
    var pin = Pin.fromEnv() orelse return error.TestExpectedPin;
    try std.testing.expect(pin.stillIntact());
    ppaths.setEnv(CHECK_ENV, "echo tampered");
    try std.testing.expect(!pin.stillIntact());
    ppaths.unsetEnv(CHECK_ENV);
    try std.testing.expect(!pin.stillIntact());
}
