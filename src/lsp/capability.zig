//! 符号能力状态的**唯一**词汇表(issue #17)。
//!
//! 病根:符号能力曾有两个互不约束的谓词——决策侧 `hasSymbolsFor` 查编译期静态 `SERVERS` 表
//! (只看扩展名),使用侧 `service.getOrSpawn` 查运行期(which → spawn → broken-set)。tree-sitter
//! 时代 grammar 静态链接,"扩展名注册"⇔"能力可用"成立,一个谓词两个状态就够;`1515b34` 把符号
//! 来源换成外部 LSP 进程后,依赖的性质从编译期事实变成运行期进程,能力契约却没跟着改——
//! 于是"能力缺失"被压成空结果,模型读成"查无定义"。
//!
//! 修法:三态取代两态,且**原因只有这一份定义**。上层拿到 `Unavailable` 必须把它讲出来,
//! 绝不允许退化成裸 `[]` / 空大纲。
const std = @import("std");

/// 符号能力缺失的原因。**不是**"查无符号"——文件真的没有符号时走的是"能力在位 + 空列表"。
///
/// 产出方分两层(各自只产自己能观测到的子集,注释标明):
///  - 工具层(`tools/symbol_provider.zig`):`lsp_disabled` / `path_unresolved`
///    以及门禁阶段的 `no_server_for_language` / `server_not_installed`。
///  - LSP 层(`lsp/service.zig`):`no_server_for_language` / `outside_workspace` /
///    `server_not_installed` / `server_unavailable`。
pub const Reason = enum {
    /// 进程没开 `--lsp`,符号子系统整体未装配。(工具层产)
    lsp_disabled,
    /// 该扩展名在 `SERVERS` 里没有注册的 language server。
    no_server_for_language,
    /// 注册表里有,但它的可执行文件此刻解析不到(不在 PATH)。**issue #17 的原始病例**。
    server_not_installed,
    /// 二进制在,但 server 起不来:spawn/initialize 失败、已在 broken-set、client 满员,
    /// 或 didOpen/documentSymbol 请求失败。
    server_unavailable,
    /// 文件不在 git workspace 内(或解析不出 server root),LSP 按设计不启动。
    outside_workspace,
    /// 拿不到 cwd,相对路径转不成绝对路径,无法构造 LSP URI。(工具层产)
    path_unresolved,
};

/// `why()` 输出的建议缓冲大小(最长一条 = 前缀 + 一个 server 二进制名)。
pub const WHY_BUF: usize = 256;

/// 能力缺失(原因 + 一个静态细节串)。`detail` 指向 `SERVERS` 里的常量(binary / server_id),
/// 无所有权、可自由按值复制、生命周期与程序等长。
pub const Unavailable = struct {
    reason: Reason,
    /// `.server_not_installed` → 缺失的可执行名;`.server_unavailable` → server_id;其余为空。
    detail: []const u8 = "",

    /// 一句"为什么没有符号"的说明,供工具直接嵌进给模型看的输出。**不带主语和句号**,
    /// 调用方自己包前后文——措辞只有这一份,CodeMap / FindSymbol / Read-outline 不会各自漂移。
    /// `buf` 建议 `WHY_BUF` 字节;不够时退回不含 detail 的静态串(绝不截断出半截单词)。
    pub fn why(self: Unavailable, buf: []u8) []const u8 {
        return switch (self.reason) {
            .lsp_disabled => "no language server is configured (restart with --lsp)",
            .no_server_for_language => "no language server is registered for this file type",
            .server_not_installed => std.fmt.bufPrint(
                buf,
                "the '{s}' language server is not installed (not found in PATH)",
                .{self.detail},
            ) catch "the language server for this file type is not installed (not found in PATH)",
            .server_unavailable => std.fmt.bufPrint(
                buf,
                "the '{s}' language server could not be started",
                .{self.detail},
            ) catch "the language server for this file type could not be started",
            .outside_workspace => "this file is outside a git workspace, where language servers are not started",
            .path_unresolved => "this file path could not be resolved to an absolute path",
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "why: server_not_installed 点名缺失的二进制" {
    var buf: [WHY_BUF]u8 = undefined;
    const u = Unavailable{ .reason = .server_not_installed, .detail = "pyright-langserver" };
    const s = u.why(&buf);
    try testing.expect(std.mem.indexOf(u8, s, "pyright-langserver") != null);
    try testing.expect(std.mem.indexOf(u8, s, "not installed") != null);
}

test "why: buf 太小 → 退回不含 detail 的静态串,不产半截输出" {
    var tiny: [4]u8 = undefined;
    const u = Unavailable{ .reason = .server_not_installed, .detail = "pyright-langserver" };
    const s = u.why(&tiny);
    try testing.expect(std.mem.indexOf(u8, s, "not installed") != null);
    try testing.expect(std.mem.indexOf(u8, s, "pyright-langserver") == null);
}

test "why: 每个 reason 都有非空说明(新增 reason 漏写措辞会在此暴露)" {
    var buf: [WHY_BUF]u8 = undefined;
    inline for (@typeInfo(Reason).@"enum".fields) |f| {
        const u = Unavailable{ .reason = @field(Reason, f.name), .detail = "srv" };
        try testing.expect(u.why(&buf).len > 0);
    }
}

test "why: lsp_disabled 指出 --lsp(工具层据此引导用户)" {
    var buf: [WHY_BUF]u8 = undefined;
    const s = (Unavailable{ .reason = .lsp_disabled }).why(&buf);
    try testing.expect(std.mem.indexOf(u8, s, "--lsp") != null);
}
