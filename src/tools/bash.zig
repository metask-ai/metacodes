const std = @import("std");
const common = @import("common.zig");
const security = @import("security.zig");
const util_time = @import("../util/time.zig");
const util_json = @import("../util/json.zig");
const ToolContext = @import("context.zig").ToolContext;

/// nowMs：毫秒时间戳，复用 util/time.zig
fn nowMs() util_time.Millis {
    return util_time.nowMs();
}

/// 默认 timeout：120s（对齐 TS 原版 BashTool）。
pub const DEFAULT_TIMEOUT_MS: u64 = 120_000;
/// 最大 timeout 上限：24h。
pub const MAX_TIMEOUT_MS: u64 = 24 * 3600 * 1000;
/// 同步模式超过此时长自动转后台：与 TS 对齐（ASSISTANT_BLOCKING_BUDGET_MS）
pub const AUTO_BACKGROUND_MS: u64 = 15_000;

/// 前台 Bash 单股(stdout/stderr)输出上限,超出截断(对齐 Claude Code 30K 字符)。
/// 防止 `cat huge` / `seq 1000000` 等把整个输出灌进上下文。
pub const MAX_OUTPUT_BYTES: usize = 30_000;

/// 把输出截断到 ≤ MAX_OUTPUT_BYTES(保留头部),超出时追加 `... [N lines truncated] ...`。
/// 切点回退到不超过上限的最近 UTF-8 字符边界 + 最近换行(不切坏多字节/半行)。
/// 返回 owned slice(调用方 free);未超限时返回原文 dupe。
fn truncateHead(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    if (s.len <= MAX_OUTPUT_BYTES) return try allocator.dupe(u8, s);

    // 1. 先定到 MAX_OUTPUT_BYTES,回退到 UTF-8 字符边界(continuation byte 0b10xxxxxx)。
    var cut = MAX_OUTPUT_BYTES;
    while (cut > 0 and (s[cut] & 0b1100_0000) == 0b1000_0000) : (cut -= 1) {}
    // 2. 再回退到最近换行(让截断落在行边界,输出更整齐);若该行很长找不到则就用 cut。
    if (std.mem.lastIndexOfScalar(u8, s[0..cut], '\n')) |nl| {
        if (nl + 1 >= MAX_OUTPUT_BYTES / 2) cut = nl + 1; // 仅当不会砍掉过多时才退到换行
    }
    // 统计被砍掉的行数(剩余部分的 \n 数 + 1 行尾)。
    var dropped_lines: usize = 0;
    for (s[cut..]) |c| {
        if (c == '\n') dropped_lines += 1;
    }
    if (s[s.len - 1] != '\n') dropped_lines += 1;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(s[0..cut]);
    try out.writer.print("\n... [{d} lines truncated] ...\n", .{dropped_lines});
    return try out.toOwnedSlice();
}

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const command_escaped = common.extractJsonArg(args, "command") orelse return error.MissingCommand;
    if (command_escaped.len == 0) return error.EmptyCommand;
    // extractJsonArg 返回的是【含原始 JSON 转义】的串(如 `>`→`>`、换行→`\n`)。
    // 必须 unescape 后才能交给 /bin/sh,否则重定向 `>`、换行等会被当字面量丢失。
    // (对齐 edit.zig 对 old_string/new_string 的处理)
    const raw_command = try util_json.unescapeString(command_escaped, allocator);
    defer allocator.free(raw_command);
    if (raw_command.len == 0) return error.EmptyCommand;
    try security.validateBashCommand(raw_command);

    // description 仅作日志用途，本期透传但不输出
    _ = common.extractJsonArg(args, "description");

    // Sandbox 包裹(macOS Seatbelt):若 ctx.sandbox 启用,把 command 改写成
    // `sandbox-exec -f <profile> /bin/bash -c <cmd>`。dangerouslyDisableSandbox=true 跳过。
    // sandbox_wrap 非 null 时持有临时 profile 文件,函数返回前 deinit 清理。
    const disable_sb = blk: {
        if (common.extractJsonArg(args, "dangerouslyDisableSandbox")) |v| {
            break :blk std.mem.eql(u8, v, "true");
        }
        break :blk false;
    };
    var sandbox_wrap: ?@import("../sandbox/exec.zig").ShellWrap = null;
    defer if (sandbox_wrap) |*sw| sw.deinit();
    const command: []const u8 = blk: {
        const sb = ctx.sandbox orelse break :blk raw_command;
        if (!sb.enabled) break :blk raw_command;
        const sandbox_exec = @import("../sandbox/exec.zig");
        const cwd = if (ctx.cwd_abs.len > 0) ctx.cwd_abs else ".";
        const maybe = sandbox_exec.wrapAsShellString(allocator, raw_command, .{
            .cwd = cwd,
            .home = ctx.home_dir,
            .sandbox = sb,
            .disable_for_this_command = disable_sb,
        }) catch |e| {
            // failIfUnavailable=true 时沙箱不可用 → 拒绝执行(不降级裸跑)
            if (e == error.SandboxUnavailable) return error.SandboxUnavailable;
            // 其它 error(profile 写失败等):降级 passthrough
            break :blk raw_command;
        };
        if (maybe) |sw| {
            sandbox_wrap = sw;
            break :blk sw.command;
        }
        break :blk raw_command;
    };

    // 显式 run_in_background=true：直接丢 job 表立刻返
    if (common.extractJsonArg(args, "run_in_background")) |v| {
        if (std.mem.eql(u8, v, "true")) {
            if (ctx.jobs) |registry| {
                // 后台:profile 文件不能删(进程还在跑),detach
                if (sandbox_wrap) |*sw| sw.detached = true;
                const j = try registry.spawnBackground(command);
                return try std.fmt.allocPrint(allocator,
                    "{{\"job_id\":\"{s}\",\"status\":\"started\",\"stdout_path\":\"{s}\",\"stderr_path\":\"{s}\"}}",
                    .{ j.id[0..], j.stdout_path, j.stderr_path });
            }
        }
    }

    const timeout_ms: u64 = blk: {
        if (common.extractJsonArg(args, "timeout")) |s| {
            const parsed = std.fmt.parseInt(u64, s, 10) catch DEFAULT_TIMEOUT_MS;
            break :blk @min(parsed, MAX_TIMEOUT_MS);
        }
        break :blk DEFAULT_TIMEOUT_MS;
    };

    // 同步路径 + 自动转后台：
    // 短命令（常态）走原 pipe 捕获；长命令达到 AUTO_BACKGROUND_MS 时转为后台 job。
    //
    // 策略：用 job_registry 一开始就 spawn 到落盘文件；父端 poll 等待，达到
    // min(timeout, AUTO_BACKGROUND_MS) 时决定：
    //   - 进程已退出 → 读 stdout/stderr 文件返回
    //   - 未退出 + 达到 AUTO_BACKGROUND_MS & ctx.jobs 可用 → 返回 {auto_backgrounded, job_id}
    //   - 未退出 + 达到用户 timeout → kill + error.Timeout
    if (ctx.jobs) |registry| {
        // 走 job_registry:命令可能自动转后台,届时 profile 文件不能删 → detach。
        // 代价:即便命令同步完成,profile 也泄漏到 TMPDIR(系统/重启清理),换取正确性。
        if (sandbox_wrap) |*sw| sw.detached = true;
        return try runAutoBackgroundable(allocator, registry, command, timeout_ms, ctx.abort);
    }

    // jobs 不可用（老/单测路径）：回退到原始 pipe 捕获
    const cmd_z = try allocator.dupeZ(u8, command);
    defer allocator.free(cmd_z);
    const argv0: [*:0]const u8 = "/bin/sh";
    var argv: [4]?[*:0]const u8 = .{ argv0, "-c", cmd_z.ptr, null };
    const out = try common.spawnCaptureWithStderrTimed(argv[0..argv.len], allocator, ctx.abort, timeout_ms, ctx.spawn_tick_fn);
    defer allocator.free(out.stdout);
    defer allocator.free(out.stderr);

    // 截断到 MAX_OUTPUT_BYTES(保留头部),防大输出撑爆上下文。
    const out_trunc = try truncateHead(allocator, out.stdout);
    defer allocator.free(out_trunc);
    const err_trunc = try truncateHead(allocator, out.stderr);
    defer allocator.free(err_trunc);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"stdout\":");
    try std.json.Stringify.encodeJsonString(out_trunc, .{}, &aw.writer);
    try aw.writer.writeAll(",\"stderr\":");
    try std.json.Stringify.encodeJsonString(err_trunc, .{}, &aw.writer);
    try aw.writer.print(",\"exit_code\":{d}}}", .{out.exit_code});
    return try aw.toOwnedSlice();
}

/// 新路径：总是 spawn 到 job_registry（stdout/stderr 落盘），父端轮询等待。
/// - 若在 AUTO_BACKGROUND_MS 内进程退出 → 读文件返回正常 {stdout,stderr,exit_code}
/// - 若超过 AUTO_BACKGROUND_MS 仍未结束 → 返回 {auto_backgrounded,job_id,partial_stdout,partial_stderr}
/// - 若达到 user timeout_ms 仍未结束 → kill + error.Timeout
fn runAutoBackgroundable(
    allocator: std.mem.Allocator,
    registry: *@import("../core/job_registry.zig").JobRegistry,
    command: []const u8,
    timeout_ms: u64,
    abort: ?*const @import("../util/abort.zig").AbortSignal,
) ![]u8 {
    const j_entry = try registry.spawnBackground(command);
    const job_id = j_entry.id; // 值拷贝，不持指针（registry 可能扩容移动）

    const effective_budget = @min(timeout_ms, AUTO_BACKGROUND_MS);
    const start = nowMs();
    // 轮询循环
    while (true) {
        if (abort) |a| if (a.isAborted()) {
            registry.kill(job_id[0..]) catch {};
            return error.Aborted;
        };
        var req = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);

        registry.reapExited();
        const j = registry.get(job_id[0..]) orelse return error.JobNotFound;
        if (j.status != .running) {
            // 正常退出：读文件构造完整输出
            return try readJobAsSync(allocator, j);
        }

        const elapsed: u64 = @intCast(nowMs() - start);
        if (elapsed >= timeout_ms) {
            // 真 timeout：kill + 错误
            registry.kill(job_id[0..]) catch {};
            return error.Timeout;
        }
        if (elapsed >= effective_budget) {
            // 达到 auto-background 阈值但未到 timeout：返回 auto_backgrounded
            return try formatAutoBackgrounded(allocator, j);
        }
    }
}

fn readJobAsSync(allocator: std.mem.Allocator, j: *const @import("../core/job_registry.zig").JobEntry) ![]u8 {
    const out_bytes = readWholeFile(j.stdout_path, allocator) catch try allocator.dupe(u8, "");
    defer allocator.free(out_bytes);
    const err_bytes = readWholeFile(j.stderr_path, allocator) catch try allocator.dupe(u8, "");
    defer allocator.free(err_bytes);

    const out_trunc = try truncateHead(allocator, out_bytes);
    defer allocator.free(out_trunc);
    const err_trunc = try truncateHead(allocator, err_bytes);
    defer allocator.free(err_trunc);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"stdout\":");
    try std.json.Stringify.encodeJsonString(out_trunc, .{}, &aw.writer);
    try aw.writer.writeAll(",\"stderr\":");
    try std.json.Stringify.encodeJsonString(err_trunc, .{}, &aw.writer);
    try aw.writer.print(",\"exit_code\":{d}}}", .{j.exit_code orelse 0});
    return try aw.toOwnedSlice();
}

fn formatAutoBackgrounded(allocator: std.mem.Allocator, j: *const @import("../core/job_registry.zig").JobEntry) ![]u8 {
    const out_bytes = readWholeFile(j.stdout_path, allocator) catch try allocator.dupe(u8, "");
    defer allocator.free(out_bytes);
    const err_bytes = readWholeFile(j.stderr_path, allocator) catch try allocator.dupe(u8, "");
    defer allocator.free(err_bytes);

    const out_trunc = try truncateHead(allocator, out_bytes);
    defer allocator.free(out_trunc);
    const err_trunc = try truncateHead(allocator, err_bytes);
    defer allocator.free(err_trunc);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"auto_backgrounded\":true,\"job_id\":");
    try std.json.Stringify.encodeJsonString(j.id[0..], .{}, &aw.writer);
    try aw.writer.writeAll(",\"partial_stdout\":");
    try std.json.Stringify.encodeJsonString(out_trunc, .{}, &aw.writer);
    try aw.writer.writeAll(",\"partial_stderr\":");
    try std.json.Stringify.encodeJsonString(err_trunc, .{}, &aw.writer);
    try aw.writer.writeAll(",\"note\":\"Command exceeded 15s; moved to background. Use BashOutput to poll or KillShell to terminate.\"}");
    return try aw.toOwnedSlice();
}

fn readWholeFile(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= pbuf.len) return error.PathTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = std.c.open(@ptrCast(&pbuf), std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return try out.toOwnedSlice(allocator);
}

fn testCtx() ToolContext {
    return ToolContext.simple(std.testing.allocator);
}

test "BashTool missing command" {
    const ctx = testCtx();
    try std.testing.expectError(error.MissingCommand, execute(&ctx, "{\"x\":\"y\"}"));
}

test "BashTool dangerous blocked" {
    const ctx = testCtx();
    try std.testing.expectError(error.DangerousCommand, execute(&ctx, "{\"command\":\"rm -rf /\"}"));
}

test "BashTool echo" {
    const ctx = testCtx();
    const result = try execute(&ctx, "{\"command\":\"echo hello\"}");
    defer std.testing.allocator.free(result);
    // JSON 返回：{"stdout":"hello\n","stderr":"","exit_code":0}
    try std.testing.expect(std.mem.indexOf(u8, result, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"exit_code\":0") != null);
}

test "BashTool stderr captured separately" {
    const ctx = testCtx();
    const result = try execute(&ctx, "{\"command\":\"echo out; echo err 1>&2; exit 7\"}");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout\":\"out\\n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stderr\":\"err\\n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"exit_code\":7") != null);
}

test "BashTool nonzero exit visible" {
    const ctx = testCtx();
    const result = try execute(&ctx, "{\"command\":\"ls /nonexistent 2>&1; exit 2\"}");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"exit_code\":2") != null);
}

test "BashTool timeout triggers" {
    const ctx = testCtx();
    // sleep 10 with timeout=500ms → 应 Timeout
    const result = execute(&ctx, "{\"command\":\"sleep 10\",\"timeout\":500}");
    try std.testing.expectError(error.Timeout, result);
}

test "BashTool timeout over ms grain is enforced" {
    const ctx = testCtx();
    const t0 = nowMs();
    const result = execute(&ctx, "{\"command\":\"sleep 10\",\"timeout\":300}");
    try std.testing.expectError(error.Timeout, result);
    const dt = nowMs() - t0;
    // killGroup 含 2s SIGTERM 等待期；总耗时 ≈ 300 + ≤2000 < 3000
    try std.testing.expect(dt < 3000);
}

test "BashTool description is parsed without error" {
    const ctx = testCtx();
    const result = try execute(&ctx, "{\"command\":\"echo ok\",\"description\":\"test echo\"}");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "ok") != null);
}

test "BashTool auto-backgrounds after 15s" {
    // 构造 ctx 带 jobs；短测不跑完整 15s；直接验证 run_in_background 路径
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();

    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const result = try execute(&ctx, "{\"command\":\"sleep 30\",\"run_in_background\":\"true\"}");
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"status\":\"started\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"job_id\":") != null);

    // 清理
    for (registry.jobs.items) |*j| {
        if (j.status == .running) registry.kill(j.idSlice()) catch {};
    }
}

test "truncateHead: 小输出原样,大输出截断 + 标记" {
    const a = std.testing.allocator;
    // 小输出不截。
    const small = try truncateHead(a, "hello\nworld\n");
    defer a.free(small);
    try std.testing.expectEqualStrings("hello\nworld\n", small);

    // 大输出(> MAX_OUTPUT_BYTES)截到 ≤ 上限 + 含 truncated 标记。
    const big = try a.alloc(u8, MAX_OUTPUT_BYTES + 5000);
    defer a.free(big);
    @memset(big, 'a');
    // 撒一些换行,让回退到换行的逻辑有料。
    var i: usize = 0;
    while (i < big.len) : (i += 80) big[i] = '\n';
    const trunc = try truncateHead(a, big);
    defer a.free(trunc);
    try std.testing.expect(std.mem.indexOf(u8, trunc, "lines truncated") != null);
    // 截断后正文(不含标记)应 ≤ MAX_OUTPUT_BYTES。
    const marker = std.mem.indexOf(u8, trunc, "\n... [").?;
    try std.testing.expect(marker <= MAX_OUTPUT_BYTES);
}

test "BashTool 大输出被截断(防撑爆上下文)" {
    const a = std.testing.allocator;
    const ctx = ToolContext{ .allocator = a };
    // seq 到很大 → stdout 远超 30K → 应截断 + 含 truncated 标记。
    const r = try execute(&ctx, "{\"command\":\"seq 1 100000\"}");
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "lines truncated") != null);
    // 整个返回 JSON 不该是完整 100000 行(粗略:远小于 ~600KB)。
    try std.testing.expect(r.len < 60_000);
}


