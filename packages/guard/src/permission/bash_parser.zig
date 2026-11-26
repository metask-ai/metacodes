//! Bash 复合命令拆分 + process wrapper 剥离 + readonly 白名单。
//!
//! 用于权限判定:Bash 规则只对**单个**命令成立,复合命令(&& || ; | & |& 换行)
//! 必须每一段都被允许,否则按最危险的那段决策。
//!
//! 同时:wrapper 命令(timeout / time / nice / nohup / stdbuf / xargs / env)包着的才是
//! 目标命令,两种剥法对应两个失败方向:
//!   - stripWrapper(s):启发式,deny/ask 规则多一个候选(多匹中是 fail-closed),
//!     `env X=1 rm x`、`timeout 5 rm x` 都按 rm 判;
//!   - peelBenignWrapper:按 wrapper 的真实选项语法,只剥改"怎么跑"不改"跑什么"的
//!     那几种,allow 规则据此放行包着的命令。env 换环境(LD_PRELOAD/PATH)、xargs 从
//!     stdin 追加参数,剥掉它们看到的就不是真正运行的命令,不在其列。
//!
//! 还提供"readonly 命令"清单(READONLY_BASH + isReadonlyCommand):只看首词的
//! token 级判定,现仅供 delivery-cadence 探针使用。权限免询问与并发安全走
//! bash_readonly.zig 的严格判定(完整词法 + 逐段 + 重定向/写选项),两份清单
//! 命名同一组命令(编译期校验)。
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
/// 重定向运算符里的 `&`、`|` 不是分隔符:紧跟在未加引号、未转义的 `>`/`<` 后面的 `&`
/// (`2>&1`、`>&2`、`<&3`、`>&-`)和 `>` 后面的 `|`(`>|`)。`&>`、`&>>` 仍在 `&` 处拆开:
/// bash 把它当作两路输出写文件的重定向,dash 读成后台 `&` 加一条只有重定向的命令;按
/// dash 拆,`&` 前的命令照样单独成段,bash 下多出的 `> file` 段只让 allow 规则多问一次。
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
    // 上一个字节是未加引号、未转义的 `>` 或 `<` 时记下它,否则 0
    var redirect_op: u8 = 0;

    while (i < input.len) : (i += 1) {
        const c = input[i];
        const after_redirect = redirect_op;
        redirect_op = 0;

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

        if (c == '>' or c == '<') redirect_op = c;

        // 找分隔符
        const split_len: usize = blk: {
            // `>&`、`<&`、`>|` 是重定向运算符
            if (c == '&' and after_redirect != 0) break :blk 0;
            if (c == '|' and after_redirect == '>') break :blk 0;
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
    while (stripWrapper(s)) |inner| s = inner;
    return s;
}

/// stripWrappers 的一层:cmd 以 wrapper 开头时返回它包着的命令,否则 null。参数按
/// "-x / KEY=val / 数字"一律跳过,不保证剥到真正运行的命令(`timeout -s KILL 5 rm x`
/// 剥成 `KILL 5 rm x`),所以只给 deny/ask 规则当额外候选、给非权限探针用;allow 规则
/// 看穿 wrapper 走 peelBenignWrapper。
pub fn stripWrapper(cmd: []const u8) ?[]const u8 {
    const s = std.mem.trim(u8, cmd, " \t");
    const first_space = std.mem.indexOfAny(u8, s, " \t") orelse return null;
    const head = s[0..first_space];
    if (!isWrapper(head)) return null;
    // 跳过 wrapper 自带参数(数字 / -x / KEY=val),直到第一个看起来是命令的 token
    const rest = skipWrapperArgs(head, std.mem.trim(u8, s[first_space..], " \t"));
    if (rest.len == 0) return null; // 剥光了反而异常,不剥
    return rest;
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
// 良性 wrapper(allow 规则可以看穿)
// ============================================================================

/// 只改命令"怎么跑"、不改"跑什么"的 wrapper:时限、计时、调度/IO 优先级、挂断信号、
/// stdio 缓冲、PATH 查找、替换 shell 进程。运行哪个程序、带什么参数仍由被包的命令决定,
/// 调用方也没法借它们注入环境变量或库(stdbuf 预加载的是它自带的 libstdbuf),所以
/// `Bash(npm test)` 放行 `timeout 30 npm test` 与放行 `npm test` 是一回事。
/// 不在其列:env(`LD_PRELOAD=`、`PATH=`、`GIT_SSH_COMMAND=`、BSD `-P` 换掉真正运行的
/// 代码)、xargs(从 stdin 给命令追加参数)。
const BenignWrapper = enum { timeout, time, nice, ionice, nohup, stdbuf, command, exec };

/// cmd 以良性 wrapper 开头、且 wrapper 的参数完全落在它的选项语法内时,剥掉**一层**,
/// 返回它运行的命令;否则 null。与 stripWrapper 相反,这里宁少剥,因为 allow 规则据此
/// 替包着的命令放行:
///   - wrapper 名与它的每个参数都必须是 plain 词(isPlainWord):shell 不对它做引号
///     去除、展开、通配或重定向,wrapper 收到的 argv 就是这些字;
///   - 只认 GNU 与 BSD 实现含义一致的选项。未知选项、长选项缩写、短选项簇都不剥:
///     把带值的选项当成开关(或反过来),真正运行的命令就错开了一个词;
///   - 剥出的命令不能以 `-` 开头(那是没认出来的选项,不是命令)。
pub fn peelBenignWrapper(cmd: []const u8) ?[]const u8 {
    var words = WrapperWords{ .rest = std.mem.trim(u8, cmd, " \t") };
    const head = words.take() orelse return null;
    const wrapper = std.meta.stringToEnum(BenignWrapper, head) orelse return null;
    const parsed = switch (wrapper) {
        .timeout => skipTimeoutArgs(&words),
        .nice => skipNiceArgs(&words),
        .ionice => skipOptions(&words, &IONICE_OPTIONS),
        .stdbuf => skipOptions(&words, &STDBUF_OPTIONS),
        // 别的选项都不收:`exec -a NAME` 改 argv[0](git 按它选子命令),`command -v`
        // 只查名字不运行,GNU `time -o FILE` 写文件。
        .time => words.skipOptional("-p"),
        .command => words.skipOptional("-p") and words.skipOptional("--"),
        .nohup, .exec => words.skipOptional("--"),
    };
    if (!parsed) return null;
    const inner = words.rest;
    if (inner.len == 0 or inner[0] == '-') return null;
    return inner;
}

/// wrapper 前缀按空白切词的游标;rest 是尚未消费的原文(已去掉前导空白)。
const WrapperWords = struct {
    rest: []const u8,

    fn peek(self: *const WrapperWords) ?[]const u8 {
        if (self.rest.len == 0) return null;
        const end = std.mem.indexOfAny(u8, self.rest, " \t") orelse self.rest.len;
        return self.rest[0..end];
    }

    /// 消费下一个词作为 wrapper 语法的一部分;它不是 plain 词 → null。
    fn take(self: *WrapperWords) ?[]const u8 {
        const word = self.peek() orelse return null;
        if (!isPlainWord(word)) return null;
        self.rest = std.mem.trimStart(u8, self.rest[word.len..], " \t");
        return word;
    }

    /// 可选的一个词:下一个词正是 `word` 就消费。总返回 true,便于和必选语法用 `and` 串起来。
    fn skipOptional(self: *WrapperWords, word: []const u8) bool {
        const next = self.peek() orelse return true;
        if (std.mem.eql(u8, next, word)) _ = self.take();
        return true;
    }
};

/// shell 原样交给命令的词:只含字母数字与 `_ - + . , : / = @ %`。引号、`\`、`$`、反引号、
/// 通配与花括号、`~`、`!`、`#`、重定向与括号、控制字节、非 ASCII 都不算。
fn isPlainWord(word: []const u8) bool {
    if (word.len == 0) return false;
    for (word) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '+', '.', ',', ':', '/', '=', '@', '%' => {},
        else => return false,
    };
    return true;
}

/// wrapper 的一个选项:短名(0 = 没有)、长名("" = 没有)、是否带值。
const WrapperOption = struct { short: u8 = 0, long: []const u8 = "", value: bool };

/// `timeout [OPTION]... DURATION COMMAND`
const TIMEOUT_OPTIONS = [_]WrapperOption{
    .{ .short = 'k', .long = "kill-after", .value = true },
    .{ .short = 's', .long = "signal", .value = true },
    .{ .short = 'v', .long = "verbose", .value = false },
    .{ .long = "foreground", .value = false },
    .{ .long = "preserve-status", .value = false },
};

/// `nice [-n N | --adjustment=N] COMMAND`
const NICE_OPTIONS = [_]WrapperOption{
    .{ .short = 'n', .long = "adjustment", .value = true },
};

/// `ionice [-c CLASS] [-n LEVEL] [-t] COMMAND`;`-p`/`-P`/`-u` 之后是进程号,不是命令。
const IONICE_OPTIONS = [_]WrapperOption{
    .{ .short = 'c', .long = "class", .value = true },
    .{ .short = 'n', .long = "classdata", .value = true },
    .{ .short = 't', .long = "ignore", .value = false },
};

/// `stdbuf -i/-o/-e MODE... COMMAND`
const STDBUF_OPTIONS = [_]WrapperOption{
    .{ .short = 'i', .long = "input", .value = true },
    .{ .short = 'o', .long = "output", .value = true },
    .{ .short = 'e', .long = "error", .value = true },
};

/// 消费 `options` 里的选项,停在第一个非选项词(或 `--` 之后):这几个 wrapper 都在第一个
/// 非选项处停止解析(getopt `+`)。认不出的选项 → false。
fn skipOptions(words: *WrapperWords, options: []const WrapperOption) bool {
    while (words.peek()) |word| {
        if (word.len < 2 or word[0] != '-') return true;
        _ = words.take() orelse return false;
        if (std.mem.eql(u8, word, "--")) return true;
        const option = findOption(options, word) orelse return false;
        // 值可以写在同一个词里(`--name=VALUE`、`-xVALUE`),否则是下一个词;不带值的选项
        // 带了值(`--verbose=x`、短选项簇 `-vs`)不收。
        const inline_value = if (word[1] == '-') std.mem.indexOfScalar(u8, word, '=') != null else word.len > 2;
        if (inline_value and !option.value) return false;
        if (option.value and !inline_value) _ = words.take() orelse return false;
    }
    return true;
}

/// word 是 `-x…` 或 `--name[=…]`;长名须完整(不认缩写)。
fn findOption(options: []const WrapperOption, word: []const u8) ?WrapperOption {
    for (options) |option| {
        const matched = if (word[1] == '-') blk: {
            const name = word[2..];
            const end = std.mem.indexOfScalar(u8, name, '=') orelse name.len;
            break :blk option.long.len > 0 and std.mem.eql(u8, option.long, name[0..end]);
        } else option.short != 0 and option.short == word[1];
        if (matched) return option;
    }
    return null;
}

fn skipTimeoutArgs(words: *WrapperWords) bool {
    if (!skipOptions(words, &TIMEOUT_OPTIONS)) return false;
    const duration = words.take() orelse return false;
    return isDuration(duration);
}

/// `nice -N COMMAND` 是 GNU 与 BSD 都认的旧写法(`--N` 为负),只在第一个参数。
fn skipNiceArgs(words: *WrapperWords) bool {
    if (words.peek()) |first| {
        if (first.len > 1 and first[0] == '-' and isInteger(first[1..])) _ = words.take();
    }
    return skipOptions(words, &NICE_OPTIONS);
}

fn isInteger(s: []const u8) bool {
    const digits = if (s.len > 0 and (s[0] == '-' or s[0] == '+')) s[1..] else s;
    return digits.len > 0 and allDigits(digits);
}

/// timeout 的 DURATION:`30`、`1.5`、`2m`(小数 + 可选 s/m/h/d 后缀)。
fn isDuration(word: []const u8) bool {
    var number = word;
    if (number.len > 0 and std.mem.indexOfScalar(u8, "smhd", number[number.len - 1]) != null) {
        number = number[0 .. number.len - 1];
    }
    const dot = std.mem.indexOfScalar(u8, number, '.') orelse return number.len > 0 and allDigits(number);
    const whole = number[0..dot];
    const fraction = number[dot + 1 ..];
    return whole.len + fraction.len > 0 and allDigits(whole) and allDigits(fraction);
}

fn allDigits(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

// ============================================================================
// Readonly 命令清单
// ============================================================================

/// 读类命令名清单(token 级,首词匹配)。**不是**免询问判定:同名命令的写选项
/// (`sed -i`、`find -delete`、`sort -o` …)、重定向与复合段由 bash_readonly.zig
/// 判定;该文件的命令表与本清单须同名(编译期校验)。
pub const READONLY_BASH = [_][]const u8{
    "ls",    "cat",      "pwd",   "echo",  "printf",
    "head",  "tail",     "grep",  "egrep", "fgrep",
    "find",  "wc",       "which", "type",  "diff",
    "stat",  "du",       "df",    "file",  "sort",
    "uniq",  "cut",      "tr",    "awk",   "sed",
    "cd",    "true",     "false", "id",    "whoami",
    "uname", "hostname", "rg",
};

/// 检查 cmd(已 stripWrappers)的第一个 token 是否在 readonly 清单。
/// token 级粗判(delivery-cadence 探针用);权限与并发门用 bash_readonly.isReadonly。
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
            "status",    "log",      "diff",    "show",     "branch",
            "rev-parse", "ls-files", "ls-tree", "describe", "blame",
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

test "splitCompound: 重定向运算符里的 & 与 | 不拆" {
    const Case = struct { input: []const u8, segments: []const []const u8 };
    const cases = [_]Case{
        .{ .input = "npm test 2>&1 | tail -20", .segments = &.{ "npm test 2>&1", "tail -20" } },
        .{ .input = "echo x >&2", .segments = &.{"echo x >&2"} },
        .{ .input = "cmd <&3", .segments = &.{"cmd <&3"} },
        .{ .input = "exec 3>&-", .segments = &.{"exec 3>&-"} },
        .{ .input = "make 2>&1&& rm x", .segments = &.{ "make 2>&1", "rm x" } },
        .{ .input = "echo x >| out; ls", .segments = &.{ "echo x >| out", "ls" } },
        // 后台 `&`、`|&` 照旧是分隔符;`>` 与 `&` 之间有空白,或 `>` 被转义、加了引号,`&` 也是
        .{ .input = "ls & rm x", .segments = &.{ "ls", "rm x" } },
        .{ .input = "ls 2>&1 |& cat", .segments = &.{ "ls 2>&1", "cat" } },
        .{ .input = "echo x > &1", .segments = &.{ "echo x >", "1" } },
        .{ .input = "echo \\>&1", .segments = &.{ "echo \\>", "1" } },
        .{ .input = "echo '>'&1", .segments = &.{ "echo '>'", "1" } },
        // `&>` 按 dash 的读法在 `&` 处拆开(bash 里是重定向)
        .{ .input = "ls &> out", .segments = &.{ "ls", "> out" } },
    };
    for (cases) |case| {
        errdefer std.debug.print("input: {s}\n", .{case.input});
        const segs = try splitCompound(testing.allocator, case.input);
        defer testing.allocator.free(segs);
        try testing.expectEqual(case.segments.len, segs.len);
        for (case.segments, segs) |want, got| try testing.expectEqualStrings(want, got);
    }
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

test "stripWrapper: 一次剥一层,env 赋值与 xargs 也剥" {
    try testing.expectEqualStrings("nice -n 5 npm test", stripWrapper("timeout 30 nice -n 5 npm test").?);
    try testing.expectEqualStrings("git status", stripWrapper("env LD_PRELOAD=/tmp/x.so git status").?);
    try testing.expectEqualStrings("rm x", stripWrapper("xargs rm x").?);
    try testing.expect(stripWrapper("git status") == null);
    try testing.expect(stripWrapper("timeout 30") == null);
}

test "peelBenignWrapper: 按 wrapper 的真实选项语法剥一层" {
    const cases = [_][2][]const u8{
        .{ "timeout 30 npm test", "npm test" },
        .{ "timeout 1.5m npm test", "npm test" },
        .{ "timeout -s KILL -k 5 30 npm test", "npm test" },
        .{ "timeout -sKILL -k5 30 npm test", "npm test" },
        .{ "timeout --signal=TERM --kill-after 5 --foreground --preserve-status -v 30 npm test", "npm test" },
        .{ "timeout -- 30 npm test", "npm test" },
        .{ "time npm test", "npm test" },
        .{ "time -p npm test", "npm test" },
        .{ "nice npm test", "npm test" },
        .{ "nice -n 5 npm test", "npm test" },
        .{ "nice -n5 npm test", "npm test" },
        .{ "nice --adjustment=-5 npm test", "npm test" },
        .{ "nice -10 npm test", "npm test" },
        .{ "nice -- npm test", "npm test" },
        .{ "ionice -c 3 -n 7 -t npm test", "npm test" },
        .{ "ionice -c3 --classdata=7 npm test", "npm test" },
        .{ "nohup npm test", "npm test" },
        .{ "nohup -- npm test", "npm test" },
        .{ "stdbuf -oL -e 0 --input=0 npm test", "npm test" },
        .{ "command npm test", "npm test" },
        .{ "command -p -- npm test", "npm test" },
        .{ "exec npm test", "npm test" },
        .{ "exec -- npm test", "npm test" },
        // 一次一层;包着的命令原样返回(它的引号与展开由 pattern 按原文判)
        .{ "timeout 30 nice -n 5 npm test", "nice -n 5 npm test" },
        .{ "nohup  \t npm test 'a b' $X", "npm test 'a b' $X" },
    };
    for (cases) |case| {
        errdefer std.debug.print("command: {s}\n", .{case[0]});
        try testing.expectEqualStrings(case[1], peelBenignWrapper(case[0]) orelse return error.NotPeeled);
    }
}

test "peelBenignWrapper: 换环境、追加参数、语法之外的写法都不剥" {
    const refused = [_][]const u8{
        // 不是良性 wrapper
        "env LD_PRELOAD=/tmp/x.so git status",
        "env git status",
        "xargs git add",
        "sudo git status",
        "git status",
        "/usr/bin/timeout 30 git status",
        // wrapper 的词里有引号、展开、通配、重定向
        "'timeout' 30 git status",
        "timeout '30' git status",
        "timeout $T git status",
        "timeout -s $SIG 30 git status",
        "nice -n5* git status",
        "nice -n 2>/dev/null git status",
        // 未知选项、长选项缩写、短选项簇、不带值的选项带了值、缺值、不是时长
        "timeout -x 30 git status",
        "timeout --sig=KILL 30 git status",
        "timeout -vs KILL 30 git status",
        "timeout --verbose=1 30 git status",
        "timeout -s",
        "timeout git status",
        "timeout 1e3 git status",
        "nice -n 5 -10 git status",
        "nice -x git status",
        "ionice -p 1 git status",
        "ionice -tc3 git status",
        "stdbuf -x L git status",
        // 只认 `-p` / `--`:`exec -a` 改 argv[0],`command -v` 不运行,`time -o` 写文件
        "exec -a git-push git status",
        "exec -c git status",
        "command -v git",
        "time -o /tmp/out git status",
        "nohup -x git status",
        // 没有命令,或剥出来的是没认出的选项
        "timeout 30",
        "nice -n 5",
        "nohup --",
        "time -p",
        "exec -- -a git status",
        "timeout 30 -x git status",
    };
    for (refused) |command| {
        errdefer std.debug.print("command: {s}\n", .{command});
        try testing.expect(peelBenignWrapper(command) == null);
    }
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
