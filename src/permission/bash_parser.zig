//! Bash 复合命令拆分 + process wrapper 剥离 + readonly 白名单。
//!
//! 用于权限判定:Bash 规则只对**单个**命令成立,复合命令(&& || ; | & |& 换行)
//! 必须每一段都被允许,否则按最危险的那段决策。
//!
//! 同时:wrapper 命令(timeout / time / nice / nohup / stdbuf / xargs / env)
//! 只是包装层,真正要匹配的是 wrapper 后面的目标命令。
//!
//! 还提供"readonly 命令"清单:ls / cat / pwd / 等读类命令永远算 low risk,
//! 在 default 模式不必询问。
//!
//! 对齐 Claude Code 文档:
//!   - permissions.md: Bash 规则匹配的是"single shell command";compound 需逐段判定
//!   - permissions.md: ":*" 后缀 = 任意参数 = " *"
//!   - sandbox.md: 默认 readonly 命令在 sandbox 下不询问

const std = @import("std");

// ============================================================================
// 复合命令拆分
// ============================================================================

/// 把 compound 命令拆成 N 个子命令(对应原始字符串的 slice)。
///
/// 分隔符:&& || ; | |& & 换行。
/// 注意引号内不拆(单引号 / 双引号 / 反引号)。
///
/// 返回的 slice 直接指向 input,调用方 free input 之前不能用。
pub fn splitCompound(allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);

    var start: usize = 0;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var in_back = false;

    while (i < input.len) : (i += 1) {
        const c = input[i];

        // 引号状态机
        if (!in_double and !in_back and c == '\'') {
            in_single = !in_single;
            continue;
        }
        if (!in_single and !in_back and c == '"') {
            in_double = !in_double;
            continue;
        }
        if (!in_single and !in_double and c == '`') {
            in_back = !in_back;
            continue;
        }
        if (in_single or in_double or in_back) continue;

        // 转义
        if (c == '\\' and i + 1 < input.len) {
            i += 1;
            continue;
        }

        // 找分隔符
        const split_len: usize = blk: {
            if (c == '&' and i + 1 < input.len and input[i + 1] == '&') break :blk 2;
            if (c == '|' and i + 1 < input.len and input[i + 1] == '|') break :blk 2;
            if (c == '|' and i + 1 < input.len and input[i + 1] == '&') break :blk 2;
            if (c == ';' or c == '|' or c == '&' or c == '\n') break :blk 1;
            break :blk 0;
        };
        if (split_len == 0) continue;

        const seg = std.mem.trim(u8, input[start..i], " \t\r\n");
        if (seg.len > 0) try out.append(allocator, seg);
        i += split_len - 1;
        start = i + 1;
    }
    if (start < input.len) {
        const seg = std.mem.trim(u8, input[start..], " \t\r\n");
        if (seg.len > 0) try out.append(allocator, seg);
    }
    return try out.toOwnedSlice(allocator);
}

// ============================================================================
// Process wrapper 剥离
// ============================================================================

/// 包装命令:其参数才是真正要审计的命令。
/// 对齐官方:timeout / time / nice / nohup / stdbuf / xargs / env / sudo
/// (sudo 单独拒,因为可能 sudo bash -c '...')
pub const WRAPPERS = [_][]const u8{
    "timeout",
    "time",
    "nice",
    "ionice",
    "nohup",
    "stdbuf",
    "env", // env FOO=bar real-cmd
    "xargs",
    "command", // command ls
    "exec", // exec ls
};

/// 把 wrapper 前缀剥掉,返回**真正目标命令**的 slice。
/// 不递归 sudo(sudo 应当被规则直接拒/允);递归剥纯包装。
///
/// 例:
///   "timeout 30 git status"  → "git status"
///   "env FOO=bar nice -n 5 npm test" → "npm test"
///   "ls -la" → "ls -la"(没 wrapper)
pub fn stripWrappers(cmd: []const u8) []const u8 {
    var s = std.mem.trim(u8, cmd, " \t");
    while (true) {
        const first_space = std.mem.indexOfAny(u8, s, " \t") orelse return s;
        const head = s[0..first_space];
        if (!isWrapper(head)) return s;
        // 跳过 wrapper 自带参数(数字 / -x / KEY=val),直到第一个看起来是命令的 token
        var rest = std.mem.trim(u8, s[first_space..], " \t");
        rest = skipWrapperArgs(head, rest);
        if (rest.len == 0) return s; // 剥光了反而异常,退回原始
        if (std.mem.eql(u8, rest, s)) return s;
        s = rest;
    }
}

fn isWrapper(name: []const u8) bool {
    inline for (WRAPPERS) |w| {
        if (std.mem.eql(u8, name, w)) return true;
    }
    return false;
}

/// 根据具体 wrapper 跳过它的参数。返回的 slice 指向真正命令。
fn skipWrapperArgs(wrapper: []const u8, rest: []const u8) []const u8 {
    _ = wrapper; // 当前用统一启发式:吃掉所有 "-x" 选项 / "KEY=val" / 纯数字
    var s = rest;
    while (true) {
        s = std.mem.trim(u8, s, " \t");
        const sp = std.mem.indexOfAny(u8, s, " \t") orelse {
            // 最后一个 token:如果像命令(纯字母开头,不是 KEY=val 不是 -x 不是 数字)就返回
            if (looksLikeCommand(s)) return s;
            return ""; // wrapper 后没东西可剥
        };
        const tok = s[0..sp];
        if (!looksLikeWrapperArg(tok)) return s;
        s = s[sp..];
    }
}

fn looksLikeWrapperArg(tok: []const u8) bool {
    if (tok.len == 0) return false;
    if (tok[0] == '-') return true; // -n 5 / --signal=KILL
    // KEY=VAL
    if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
        if (eq > 0) {
            const k = tok[0..eq];
            var all_alnum = true;
            for (k) |c| {
                if (!(std.ascii.isAlphanumeric(c) or c == '_')) {
                    all_alnum = false;
                    break;
                }
            }
            if (all_alnum) return true;
        }
    }
    // 纯数字(timeout 30)
    var all_digit = true;
    for (tok) |c| {
        if (!std.ascii.isDigit(c) and c != 's' and c != 'm' and c != 'h') {
            all_digit = false;
            break;
        }
    }
    if (all_digit) return true;
    return false;
}

fn looksLikeCommand(tok: []const u8) bool {
    if (tok.len == 0) return false;
    if (tok[0] == '-') return false;
    if (std.mem.indexOfScalar(u8, tok, '=') != null) return false;
    return std.ascii.isAlphabetic(tok[0]) or tok[0] == '/' or tok[0] == '.';
}

// ============================================================================
// Readonly 命令清单
// ============================================================================

/// 默认 readonly 命令:在 default 模式不询问,在 sandbox 下不需要专门白名单。
/// 对齐官方默认 allowUnsandboxedCommands 列表(粗集)。
pub const READONLY_BASH = [_][]const u8{
    "ls",     "cat",     "pwd",   "echo",  "printf",
    "head",   "tail",    "grep",  "egrep", "fgrep",
    "find",   "wc",      "which", "type",  "diff",
    "stat",   "du",      "df",    "file",  "sort",
    "uniq",   "cut",     "tr",    "awk",   "sed",
    "cd",     "true",    "false", "id",    "whoami",
    "uname",  "hostname",
};

/// 检查 cmd(已 stripWrappers)的第一个 token 是否在 readonly 清单。
pub fn isReadonlyCommand(cmd: []const u8) bool {
    const t = std.mem.trim(u8, cmd, " \t");
    const sp = std.mem.indexOfAny(u8, t, " \t") orelse t.len;
    const head = t[0..sp];

    inline for (READONLY_BASH) |w| {
        if (std.mem.eql(u8, head, w)) return true;
    }
    // git readonly 子命令:git status / git log / git diff / git show / git branch / git rev-parse
    if (std.mem.eql(u8, head, "git")) {
        const rest = std.mem.trim(u8, t[sp..], " \t");
        const sp2 = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        const sub = rest[0..sp2];
        const READONLY_GIT = [_][]const u8{
            "status",    "log",      "diff",    "show", "branch",
            "rev-parse", "ls-files", "ls-tree", "describe",
            "blame",
        };
        inline for (READONLY_GIT) |g| {
            if (std.mem.eql(u8, sub, g)) return true;
        }
        // config / remote 是**双态**(读/写):`git config k v` 写 .git/config、`git remote add` 改
        // remote。fail-closed(Linus MED-1:漏挡则并发/流式推测执行写命令,abort 后副作用已发生)——
        // 仅带明确读标志/读子命令才算 readonly,否则 unsafe。
        const gargs = std.mem.trim(u8, rest[sp2..], " \t");
        if (std.mem.eql(u8, sub, "config")) return gitConfigReadonly(gargs);
        if (std.mem.eql(u8, sub, "remote")) return gitRemoteReadonly(gargs);
    }
    return false;
}

/// `git config` 仅当带明确读标志(-l/--list/--get*)才 readonly。裸 `git config k`(读)也保守判
/// unsafe(宁可不预取也不误放写命令 `git config k v`)。
fn gitConfigReadonly(args: []const u8) bool {
    const READ_FLAGS = [_][]const u8{ "-l", "--list", "--get", "--get-all", "--get-regexp", "--get-urlall" };
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |tok| {
        inline for (READ_FLAGS) |f| if (std.mem.eql(u8, tok, f)) return true;
    }
    return false;
}

/// `git remote` 仅当无参(列 remote)或读子命令(-v/--verbose/show/get-url)才 readonly;
/// add/remove/rename/set-url 等写操作 → unsafe。
fn gitRemoteReadonly(args: []const u8) bool {
    if (args.len == 0) return true; // `git remote` 裸列
    var it = std.mem.tokenizeAny(u8, args, " \t");
    const first = it.next() orelse return true;
    const READ_SUB = [_][]const u8{ "-v", "--verbose", "show", "get-url" };
    inline for (READ_SUB) |s| if (std.mem.eql(u8, first, s)) return true;
    return false;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "isReadonlyCommand: git config/remote 双态(写命令 fail-closed unsafe · Linus MED-1)" {
    // 读:明确读标志/子命令 → readonly。
    try testing.expect(isReadonlyCommand("git config -l"));
    try testing.expect(isReadonlyCommand("git config --get user.name"));
    try testing.expect(isReadonlyCommand("git remote"));
    try testing.expect(isReadonlyCommand("git remote -v"));
    try testing.expect(isReadonlyCommand("git remote show origin"));
    // 写:必须 unsafe(否则流式/并发推测执行写副作用)。
    try testing.expect(!isReadonlyCommand("git config user.name foo")); // 写 .git/config
    try testing.expect(!isReadonlyCommand("git config user.email a@b.c"));
    try testing.expect(!isReadonlyCommand("git remote add origin url")); // 改 remote
    try testing.expect(!isReadonlyCommand("git remote set-url origin url"));
    // 裸 `git config key`(读)保守判 unsafe(不误放写)。
    try testing.expect(!isReadonlyCommand("git config user.name"));
    // 无条件只读子命令不受影响。
    try testing.expect(isReadonlyCommand("git status"));
    try testing.expect(isReadonlyCommand("git log --oneline"));
}

test "splitCompound: basic && || ; |" {
    const segs = try splitCompound(testing.allocator, "ls && cat foo || rm bar ; echo done | wc -l");
    defer testing.allocator.free(segs);
    try testing.expectEqual(@as(usize, 5), segs.len);
    try testing.expectEqualStrings("ls", segs[0]);
    try testing.expectEqualStrings("cat foo", segs[1]);
    try testing.expectEqualStrings("rm bar", segs[2]);
    try testing.expectEqualStrings("echo done", segs[3]);
    try testing.expectEqualStrings("wc -l", segs[4]);
}

test "splitCompound: ignore separators inside quotes" {
    const segs = try splitCompound(testing.allocator, "echo 'a && b' && echo \"c || d\"");
    defer testing.allocator.free(segs);
    try testing.expectEqual(@as(usize, 2), segs.len);
    try testing.expectEqualStrings("echo 'a && b'", segs[0]);
    try testing.expectEqualStrings("echo \"c || d\"", segs[1]);
}

test "splitCompound: trailing && handled" {
    const segs = try splitCompound(testing.allocator, "ls && ");
    defer testing.allocator.free(segs);
    try testing.expectEqual(@as(usize, 1), segs.len);
    try testing.expectEqualStrings("ls", segs[0]);
}

test "splitCompound: backslash escape" {
    const segs = try splitCompound(testing.allocator, "echo a\\;b ; ls");
    defer testing.allocator.free(segs);
    try testing.expectEqual(@as(usize, 2), segs.len);
    try testing.expectEqualStrings("echo a\\;b", segs[0]);
    try testing.expectEqualStrings("ls", segs[1]);
}

test "stripWrappers: timeout" {
    try testing.expectEqualStrings("git status", stripWrappers("timeout 30 git status"));
    try testing.expectEqualStrings("npm test", stripWrappers("timeout 5s npm test"));
}

test "stripWrappers: nested wrappers" {
    try testing.expectEqualStrings("npm test", stripWrappers("env FOO=bar nice -n 5 npm test"));
    try testing.expectEqualStrings("ls -la", stripWrappers("nohup stdbuf -oL ls -la"));
}

test "stripWrappers: no wrapper passes through" {
    try testing.expectEqualStrings("ls -la", stripWrappers("ls -la"));
    try testing.expectEqualStrings("git status", stripWrappers("git status"));
}

test "isReadonlyCommand: covers common reads" {
    try testing.expect(isReadonlyCommand("ls -la"));
    try testing.expect(isReadonlyCommand("cat /etc/hosts"));
    try testing.expect(isReadonlyCommand("grep -r foo ."));
    try testing.expect(isReadonlyCommand("git status"));
    try testing.expect(isReadonlyCommand("git log --oneline"));
    try testing.expect(!isReadonlyCommand("rm -rf /"));
    try testing.expect(!isReadonlyCommand("git push"));
    try testing.expect(!isReadonlyCommand("npm install"));
}
