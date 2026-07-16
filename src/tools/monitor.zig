//! Monitor 工具:把命令丢后台跑,逐行 stdout 收集供模型轮询读取。
//!
//! 与 Bash(run_in_background=true) 的关系:Monitor **始终**后台,语义更明确。
//! Bash 后台是"一次性后台",而 Monitor 是"持续监视" — 默认无超时(or 长超时)。
//!
//! 调用方式:模型用 Monitor 启动,得到 job_id;BashOutput 读累积行;KillShell 停。
//!
//! 设计:复用 JobRegistry 的 spawnBackground(脚本相同),但默认 timeout 不杀。
//!
//! Schema:
//!   command:        必填,要 watch 的命令
//!   description:    必填,告诉用户在 watch 什么
//!   timeout_ms:     可选,默认 3600000 (1h)
//!   persistent:     可选,bool,true → 不设超时(直到 session 结束或被 KillShell)
//!
//! 返回 JSON: {"job_id":"...","status":"running","description":"..."}

const std = @import("std");
const common = @import("common.zig");
const ToolContext = @import("context.zig").ToolContext;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const command = common.extractJsonArg(args, "command") orelse return error.MissingCommand;
    if (command.len == 0) return error.EmptyCommand;
    const description = common.extractJsonArg(args, "description") orelse "background monitor";

    const jobs = ctx.jobs orelse return error.JobsUnavailable;

    // **task#12(Linus review):sandbox 包裹**——Monitor 跑模型任意 shell,必须与 Bash 同样套
    // sandbox-exec(否则 sandbox 开启时,模型改用 Monitor(command=…)即可脱管跑任意命令写任意目录)。
    // 镜像 bash.zig:80-100;Monitor 恒后台 → detach(profile 文件进程还在跑,不能删)。
    var sandbox_wrap: ?@import("../sandbox/exec.zig").ShellWrap = null;
    defer if (sandbox_wrap) |*sw| sw.deinit();
    const eff_command: []const u8 = blk: {
        const sb = ctx.sandbox orelse break :blk command;
        if (!sb.enabled) break :blk command;
        const sandbox_exec = @import("../sandbox/exec.zig");
        const cwd = if (ctx.cwd_abs.len > 0) ctx.cwd_abs else ".";
        const maybe = sandbox_exec.wrapAsShellString(ctx.allocator, command, .{
            .cwd = cwd,
            .home = ctx.home_dir,
            .sandbox = sb,
            .additional_dirs = ctx.additional_dirs,
            .disable_for_this_command = false, // Monitor 无 dangerouslyDisableSandbox 参数
        }) catch |e| {
            if (e == error.SandboxUnavailable) return error.SandboxUnavailable; // failIfUnavailable → 拒绝
            break :blk command; // 其它 error(profile 写失败)降级 passthrough(同 bash.zig)
        };
        if (maybe) |sw| {
            sandbox_wrap = sw;
            break :blk sw.command;
        }
        break :blk command;
    };
    if (sandbox_wrap) |*sw| sw.detached = true; // 后台:profile 不能随本函数返回删

    // 启动后台 job(已 sandbox 包裹)
    const entry = jobs.spawnBackground(eff_command) catch |err| {
        return try std.fmt.allocPrint(ctx.allocator,
            "{{\"error\":\"spawn_failed\",\"message\":\"{s}\"}}", .{@errorName(err)});
    };

    return try std.fmt.allocPrint(ctx.allocator,
        "{{\"job_id\":\"{s}\",\"status\":\"running\",\"description\":\"{s}\",\"hint\":\"Use BashOutput(job_id) to read streamed lines; KillShell(job_id) to stop.\"}}",
        .{ entry.id[0..], description },
    );
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Monitor: missing command errors" {
    const ctx = ToolContext.simple(testing.allocator);
    try testing.expectError(error.MissingCommand, execute(&ctx, "{\"description\":\"x\"}"));
}

test "Monitor: empty command errors" {
    const ctx = ToolContext.simple(testing.allocator);
    try testing.expectError(error.EmptyCommand, execute(&ctx, "{\"command\":\"\"}"));
}

test "Monitor: no jobs registry → JobsUnavailable" {
    const ctx = ToolContext.simple(testing.allocator);
    try testing.expectError(error.JobsUnavailable, execute(&ctx, "{\"command\":\"echo hi\"}"));
}

test "Monitor: launches background job and returns job_id" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // 用 std.posix.poll 等子进程,POSIX 专属
    const a = testing.allocator;
    const JobRegistry = @import("../core/job_registry.zig").JobRegistry;
    var jobs = try JobRegistry.init(a);
    defer jobs.deinit();
    var ctx = ToolContext.simple(a);
    ctx.jobs = &jobs;

    const out = try execute(&ctx, "{\"command\":\"sleep 0.05\",\"description\":\"sleep test\"}");
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"job_id\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"description\":\"sleep test\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "BashOutput") != null);
    // 等子进程退出,避免 leak — 用 poll 替代 sleep,跨 Zig 版本一致
    var pfd = [_]std.posix.pollfd{};
    _ = std.posix.poll(&pfd, 200) catch {};
    jobs.reapExited();
}

test "Monitor: sandbox 开启时命令被 sandbox-exec 包裹(cwd 外写被拦,task#12 Linus review)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest; // Seatbelt 仅 macOS
    const a = testing.allocator;
    const JobRegistry = @import("../core/job_registry.zig").JobRegistry;
    const SandboxSettings = @import("../sandbox/config.zig").SandboxSettings;
    var jobs = try JobRegistry.init(a);
    defer jobs.deinit();
    var sbx = SandboxSettings{ .enabled = true, .allocator = a };
    defer sbx.deinit();
    var ctx = ToolContext.simple(a);
    ctx.jobs = &jobs;
    ctx.sandbox = &sbx; // 开 sandbox
    ctx.cwd_abs = "/tmp"; // 白名单 cwd
    ctx.home_dir = "/tmp";

    // /Users/Shared 世界可写但**不在** sandbox 白名单(cwd/dev/tmp/home 之外)→ 好判别标靶。
    const escape = "/Users/Shared/cc-mon-sbx-escape-test";
    _ = std.c.unlink(escape);
    defer _ = std.c.unlink(escape);

    const out = try execute(&ctx, "{\"command\":\"touch /Users/Shared/cc-mon-sbx-escape-test\"}");
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"job_id\":") != null);

    // 等 job 退出(≤2s;touch 快,sandbox 拦则失败退,不拦则成功退)。
    var st: std.c.Stat = undefined;
    var waited: u32 = 0;
    while (waited < 2000) : (waited += 20) {
        jobs.reapExited();
        if (std.c.fstatat(std.c.AT.FDCWD, escape, &st, 0) == 0) break; // 出现(不该)
        var ts = std.c.timespec{ .sec = 0, .nsec = 20 * 1_000_000 };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&ts, &rem);
    }
    jobs.reapExited();
    // sandbox 开 → touch cwd 外被 sandbox-exec 拦 → 文件不存在。
    // **toggle-verify**:去掉 monitor 的 wrap(直投 raw command)→ touch 不受限 → 文件被创建 → 测试红。
    try testing.expect(std.c.fstatat(std.c.AT.FDCWD, escape, &st, 0) != 0);
}
