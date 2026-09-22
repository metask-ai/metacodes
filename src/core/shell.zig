//! 可移植 shell 抽象 —— 复刻 codex 三层策略的第①②层(shell 选择 + exec 参数)。
//!
//! 目的:Windows 上 Bash 工具**零 git-bash 依赖**,用系统自带 PowerShell / cmd 跑命令。
//! - POSIX:`/bin/sh -c <cmd>`
//! - Windows:`powershell -NoProfile -NonInteractive -Command <cmd>`(系统自带),兜底 `cmd /c <cmd>`
//!
//! 第③层(平台化工具描述,让模型在 windows 产 PowerShell 语法)在 tools/descriptions.zig。
//! 危险命令防护(PowerShell/cmd 等价)在 tools/shell_lex.zig validateWindows。
//! 对齐 codex-rs/core/src/shell.rs derive_exec_args + shell-command/shell_detect.rs。

const std = @import("std");
const pfs = @import("platform").fs;
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const win = std.os.windows;

pub const ShellType = enum { sh, bash, powershell, cmd };

pub const Shell = struct {
    kind: ShellType,
    /// shell 可执行路径(静态 well-known 字符串,进程生命周期有效)。
    path: [*:0]const u8,

    pub fn name(self: Shell) []const u8 {
        return switch (self.kind) {
            .sh => "sh",
            .bash => "bash",
            .powershell => "powershell",
            .cmd => "cmd",
        };
    }
};

// Windows 系统自带 shell 固定路径。powershell.exe(Windows PowerShell 5.1)Win10+ 必有;
// pwsh.exe(PowerShell 7)需单独装,有则优先(体验更好);cmd.exe 永远存在,终极兜底。
const PWSH7 = "C:\\Program Files\\PowerShell\\7\\pwsh.exe";
const WINPS = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
const WINCMD = "C:\\Windows\\System32\\cmd.exe";

// 检测结果缓存:一个进程内 shell 不变,避免每条 Bash 命令重复探测(Linus perf)。并发工具
// 线程(executeSlots 批量)会并发调 detectDefault,故用 atomic 标志(release/acquire)守卫:
// 读到 done=true 时 cached_shell 已完整可见(release 配对)。竞态首访多线程重复写 cached_shell
// 无害——检测确定性、值恒等,release fence 保最终一致(无锁,lock-free)。
var cache_done = std.atomic.Value(bool).init(false);
var cached_shell: Shell = undefined;

/// 默认 shell。POSIX=/bin/sh(sh);Windows 优先 pwsh7 → Windows PowerShell → cmd。
/// **零 git-bash**——全用系统自带 shell(复刻 codex shell_detect default_user_shell)。
/// 结果缓存(进程内不变)。
pub fn detectDefault() Shell {
    if (cache_done.load(.acquire)) return cached_shell;
    const s = detectUncached();
    cached_shell = s;
    cache_done.store(true, .release);
    return s;
}

fn detectUncached() Shell {
    if (is_windows) {
        if (fileExists(PWSH7)) return .{ .kind = .powershell, .path = PWSH7 };
        if (fileExists(WINPS)) return .{ .kind = .powershell, .path = WINPS };
        return .{ .kind = .cmd, .path = WINCMD };
    }
    return .{ .kind = .sh, .path = "/bin/sh" };
}

/// 把命令拼成 exec argv(复刻 codex derive_exec_args)。写进 out(尾部 null 填充);
/// 调用方把整个 out[0..] 传给 spawn(spawn 遇 null 即停,多余槽位无害)。out 至少 [6]。
/// - Sh/Bash:`[sh, "-c", cmd, null, ...]`
/// - PowerShell:`[ps, "-NoProfile", "-NonInteractive", "-Command", cmd, null]`
///   -NoProfile:不加载用户配置(快+纯净);-NonInteractive:cmdlet 遇确认提示直接失败而非
///   挂到超时(子进程无可用 stdin,交互提示会死等)。
/// - Cmd:`[cmd, "/c", cmd, null, ...]`
pub fn deriveExecArgs(shell: Shell, command_z: [*:0]const u8, out: *[6]?[*:0]const u8) void {
    switch (shell.kind) {
        .sh, .bash => out.* = .{ shell.path, "-c", command_z, null, null, null },
        .powershell => out.* = .{ shell.path, "-NoProfile", "-NonInteractive", "-Command", command_z, null },
        .cmd => out.* = .{ shell.path, "/c", command_z, null, null, null },
    }
}

/// 为 shell 准备最终要跑的命令串(caller free)。PowerShell:前置强制 UTF-8 输出编码——
/// Windows PowerShell 5.1 默认按控制台 OEM 代码页/UTF-16 输出,原样喂给 JSON(按 UTF-8 编码)
/// 会对非 ASCII(CJK/带音符文件名/框线字符)产生乱码或 stringify 失败(Linus finding 2)。
/// cmd:chcp 65001 切 UTF-8 代码页。sh/bash:原样(已 UTF-8)。
pub fn wrapCommand(allocator: std.mem.Allocator, shell: Shell, command: []const u8) ![:0]u8 {
    return switch (shell.kind) {
        .powershell => std.fmt.allocPrintSentinel(allocator, "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; $OutputEncoding=[System.Text.Encoding]::UTF8; {s}", .{command}, 0),
        .cmd => std.fmt.allocPrintSentinel(allocator, "chcp 65001>nul & {s}", .{command}, 0),
        .sh, .bash => allocator.dupeZ(u8, command),
    };
}

// 存在性检测走 pfs.exists:Windows GetFileAttributesW(≠ INVALID),不打开文件——open-RDONLY 遇 ACL
// 读禁但可执行的系统二进制会误报"不存在"→ 错退 cmd(Linus finding 3);POSIX access(F_OK)。
fn fileExists(path: [*:0]const u8) bool {
    return pfs.exists(path);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "detectDefault: POSIX 返回 /bin/sh" {
    if (is_windows) return;
    const s = detectDefault();
    try testing.expectEqual(ShellType.sh, s.kind);
    try testing.expectEqualStrings("/bin/sh", std.mem.span(s.path));
}

test "deriveExecArgs: sh 走 -c" {
    const s = Shell{ .kind = .sh, .path = "/bin/sh" };
    var argv: [6]?[*:0]const u8 = undefined;
    deriveExecArgs(s, "echo hi", &argv);
    try testing.expectEqualStrings("/bin/sh", std.mem.span(argv[0].?));
    try testing.expectEqualStrings("-c", std.mem.span(argv[1].?));
    try testing.expectEqualStrings("echo hi", std.mem.span(argv[2].?));
    try testing.expect(argv[3] == null);
}

test "deriveExecArgs: powershell 走 -NoProfile -NonInteractive -Command" {
    const s = Shell{ .kind = .powershell, .path = "powershell.exe" };
    var argv: [6]?[*:0]const u8 = undefined;
    deriveExecArgs(s, "Get-ChildItem", &argv);
    try testing.expectEqualStrings("-NoProfile", std.mem.span(argv[1].?));
    try testing.expectEqualStrings("-NonInteractive", std.mem.span(argv[2].?));
    try testing.expectEqualStrings("-Command", std.mem.span(argv[3].?));
    try testing.expectEqualStrings("Get-ChildItem", std.mem.span(argv[4].?));
    try testing.expect(argv[5] == null);
}

test "deriveExecArgs: cmd 走 /c" {
    const s = Shell{ .kind = .cmd, .path = "cmd.exe" };
    var argv: [6]?[*:0]const u8 = undefined;
    deriveExecArgs(s, "dir", &argv);
    try testing.expectEqualStrings("/c", std.mem.span(argv[1].?));
    try testing.expectEqualStrings("dir", std.mem.span(argv[2].?));
    try testing.expect(argv[3] == null);
}

test "wrapCommand: powershell 前置 UTF-8 编码;sh 原样" {
    const a = testing.allocator;
    const ps = Shell{ .kind = .powershell, .path = "powershell.exe" };
    const w = try wrapCommand(a, ps, "Get-ChildItem");
    defer a.free(w);
    try testing.expect(std.mem.indexOf(u8, w, "OutputEncoding") != null);
    try testing.expect(std.mem.endsWith(u8, w, "Get-ChildItem"));

    const sh = Shell{ .kind = .sh, .path = "/bin/sh" };
    const w2 = try wrapCommand(a, sh, "echo hi");
    defer a.free(w2);
    try testing.expectEqualStrings("echo hi", w2);
}
