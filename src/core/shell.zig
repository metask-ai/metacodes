//! 可移植 shell 抽象 —— 复刻 codex 三层策略的第①②层(shell 选择 + exec 参数)。
//!
//! 目的:Windows 上 Bash 工具**零 git-bash 依赖**,用系统自带 PowerShell / cmd 跑命令。
//! - POSIX:`/bin/sh -c <cmd>`
//! - Windows:优先 `powershell -NoProfile -Command <cmd>`(系统自带),兜底 `cmd /c <cmd>`
//!
//! 第③层(平台化工具描述,让模型在 windows 产 PowerShell 语法)在 tools/descriptions.zig。
//! 对齐 codex-rs/core/src/shell.rs derive_exec_args + shell-command/shell_detect.rs。

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const pfs = @import("platform").fs;

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

/// 默认 shell。POSIX=/bin/sh(sh);Windows 优先 pwsh7 → Windows PowerShell → cmd。
/// **零 git-bash**——全用系统自带 shell(复刻 codex shell_detect default_user_shell)。
pub fn detectDefault() Shell {
    if (is_windows) {
        if (fileExists(PWSH7)) return .{ .kind = .powershell, .path = PWSH7 };
        if (fileExists(WINPS)) return .{ .kind = .powershell, .path = WINPS };
        return .{ .kind = .cmd, .path = WINCMD };
    }
    return .{ .kind = .sh, .path = "/bin/sh" };
}

/// 把命令拼成 exec argv(复刻 codex derive_exec_args)。写进 out(尾部 null 填充);
/// 调用方把整个 out[0..] 传给 spawn(spawn 遇 null 即停,多余槽位无害)。out 至少 [5]。
/// - Sh/Bash:`[sh, "-c", cmd, null, null]`
/// - PowerShell:`[ps, "-NoProfile", "-Command", cmd, null]`(-NoProfile:不加载用户配置,快且纯净)
/// - Cmd:`[cmd, "/c", cmd, null, null]`
pub fn deriveExecArgs(shell: Shell, command_z: [*:0]const u8, out: *[5]?[*:0]const u8) void {
    switch (shell.kind) {
        .sh, .bash => out.* = .{ shell.path, "-c", command_z, null, null },
        .powershell => out.* = .{ shell.path, "-NoProfile", "-Command", command_z, null },
        .cmd => out.* = .{ shell.path, "/c", command_z, null, null },
    }
}

fn fileExists(path: [*:0]const u8) bool {
    const fd = pfs.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (fd < 0) return false;
    pfs.close(fd);
    return true;
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
    var argv: [5]?[*:0]const u8 = undefined;
    deriveExecArgs(s, "echo hi", &argv);
    try testing.expectEqualStrings("/bin/sh", std.mem.span(argv[0].?));
    try testing.expectEqualStrings("-c", std.mem.span(argv[1].?));
    try testing.expectEqualStrings("echo hi", std.mem.span(argv[2].?));
    try testing.expect(argv[3] == null);
}

test "deriveExecArgs: powershell 走 -NoProfile -Command" {
    const s = Shell{ .kind = .powershell, .path = "powershell.exe" };
    var argv: [5]?[*:0]const u8 = undefined;
    deriveExecArgs(s, "Get-ChildItem", &argv);
    try testing.expectEqualStrings("-NoProfile", std.mem.span(argv[1].?));
    try testing.expectEqualStrings("-Command", std.mem.span(argv[2].?));
    try testing.expectEqualStrings("Get-ChildItem", std.mem.span(argv[3].?));
    try testing.expect(argv[4] == null);
}

test "deriveExecArgs: cmd 走 /c" {
    const s = Shell{ .kind = .cmd, .path = "cmd.exe" };
    var argv: [5]?[*:0]const u8 = undefined;
    deriveExecArgs(s, "dir", &argv);
    try testing.expectEqualStrings("/c", std.mem.span(argv[1].?));
    try testing.expectEqualStrings("dir", std.mem.span(argv[2].?));
    try testing.expect(argv[3] == null);
}
