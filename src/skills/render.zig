//! Skill body 渲染器:执行所有替换 + 注入,产出最终发给模型的文本。
//!
//! 处理顺序(对齐 Claude Code,**单遍扫描,不递归**):
//!
//! 1. 字符串替换(纯文本):
//!    - $ARGUMENTS          全部参数(以空格连接);若 body 不含此占位,后追加 `ARGUMENTS: <val>` 一行
//!    - $ARGUMENTS[N]       第 N 个参数,0-based
//!    - $N                  shorthand of $ARGUMENTS[N]
//!    - $<name>             命名参数(arguments frontmatter 的第 N 个对应位置 N)
//!    - ${CLAUDE_SKILL_DIR} skill 自己的目录(从 Skill.source_path 取)
//!    - ${CLAUDE_PROJECT_DIR}  当前 repo root(cwd 向上找 .git)
//!    - ${CLAUDE_SESSION_ID} 当前 session id
//!
//! 2. 注入:
//!    - 行首/空白后的 !`cmd`   bash 注入。占位整体被 stdout 替换(stderr 忽略)。
//!                            **跟在非空白字符后(如 KEY=!`cmd`)不识别**。
//!    - ```! 起始 fenced       多行 bash 注入。块整体被 stdout 替换。
//!    - 注入失败:占位被 `[shell command "<cmd>" failed: <err>]` 替换,不中止渲染。
//!    - 全局开关:disable_shell_execution=true → 占位被 `[shell command execution disabled by policy]`。
//!
//! 安全:
//!    - 注入默认 10s 超时,可由调用方覆盖
//!    - 替换/注入只跑**一次** —— 注入输出不再被扫描(防递归 + 防恶意工具回吐占位符)
//!    - 文件注入(@path)cc-zig 不实现 —— Claude Code 也未明文支持(只支持 bash 注入)

const std = @import("std");
const common = @import("../tools/common.zig");
const log = @import("../util/log.zig");

pub const RenderOptions = struct {
    arguments: []const []const u8 = &.{},
    /// arguments frontmatter 里声明的命名参数列表(顺序对应 arguments 位置)
    arg_names: []const []const u8 = &.{},
    skill_dir: []const u8 = "",
    project_dir: []const u8 = "",
    session_id: []const u8 = "",
    shell: []const u8 = "bash", // "bash" / "powershell"(后者目前不支持,占位)
    inject_timeout_ms: u64 = 10_000,
    disable_shell_execution: bool = false,
    /// AbortSignal 透传到 bash 注入
    abort: ?*const @import("../util/abort.zig").AbortSignal = null,
};

/// 渲染 body。返回 owned bytes,caller free。
pub fn renderBody(allocator: std.mem.Allocator, body: []const u8, opts: RenderOptions) ![]u8 {
    // 第一遍:扫描整 body,识别 !`cmd` 和 ```! fenced 注入,产出"片段列表"
    //         (literal 字节区间 / inject 命令字符串 owned)。
    // 第二遍:逐片段输出。literal 段先做字符串替换,inject 段执行/或被 policy 替换。
    // 单遍最后 append ARGUMENTS: if needed。

    var segments = std.ArrayList(Segment).empty;
    defer {
        for (segments.items) |seg| {
            if (seg == .inject) allocator.free(seg.inject.cmd);
        }
        segments.deinit(allocator);
    }
    try scanInjections(allocator, body, &segments);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var saw_arguments_placeholder = false;
    for (segments.items) |seg| switch (seg) {
        .literal => |range| {
            const text = body[range.start..range.end];
            const expanded = try substitute(allocator, text, opts);
            defer allocator.free(expanded);
            if (std.mem.indexOf(u8, expanded, "$ARGUMENTS") != null or std.mem.indexOf(u8, expanded, "$ARGS") != null) {
                // Shouldn't happen — substitute 已替换。仅当 $ARGUMENTS 在 escape 上下文时残留。
            }
            // 检测原 body 含有占位(用于决定是否末尾追加 ARGUMENTS:)
            if (!saw_arguments_placeholder and containsArgsPlaceholder(text)) {
                saw_arguments_placeholder = true;
            }
            try out.appendSlice(allocator, expanded);
        },
        .inject => |inj| {
            const replacement = try runInjection(allocator, inj.cmd, opts);
            defer allocator.free(replacement);
            try out.appendSlice(allocator, replacement);
        },
    };

    // 若 body 不含 $ARGUMENTS 但用户传了参数 → 追加
    if (!saw_arguments_placeholder and opts.arguments.len > 0) {
        const all = try joinArgs(allocator, opts.arguments);
        defer allocator.free(all);
        // 保证至少有一个换行隔开
        if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') {
            try out.append(allocator, '\n');
        }
        try out.appendSlice(allocator, "ARGUMENTS: ");
        try out.appendSlice(allocator, all);
        try out.append(allocator, '\n');
    }

    return try out.toOwnedSlice(allocator);
}

// ============================================================================
// 段切分(literal vs inject)
// ============================================================================

const Range = struct { start: usize, end: usize };
const Inject = struct { cmd: []u8 };
const Segment = union(enum) { literal: Range, inject: Inject };

fn scanInjections(allocator: std.mem.Allocator, body: []const u8, segs: *std.ArrayList(Segment)) !void {
    var lit_start: usize = 0;
    var i: usize = 0;

    while (i < body.len) {
        // 优先识别 fenced block: 行首 "```!" + (lang 可选) 直到下一个行首 ```
        if (atLineStart(body, i) and i + 4 <= body.len and std.mem.startsWith(u8, body[i..], "```!")) {
            // close 段
            try segs.append(allocator, .{ .literal = .{ .start = lit_start, .end = i } });
            // 找开 fence 行的结尾(到第一个换行)
            const open_line_end = std.mem.indexOfScalarPos(u8, body, i, '\n') orelse body.len;
            const cmd_start = open_line_end + 1;
            // 找下一个行首 ``` (匹配关闭)
            var p: usize = cmd_start;
            const close_pos = while (p < body.len) : (p = (std.mem.indexOfScalarPos(u8, body, p, '\n') orelse body.len) + 1) {
                if (atLineStart(body, p) and p + 3 <= body.len and std.mem.startsWith(u8, body[p..], "```")) {
                    break p;
                }
            } else body.len;
            const cmd_end = if (close_pos > cmd_start and body[close_pos - 1] == '\n') close_pos - 1 else close_pos;
            const cmd = try allocator.dupe(u8, body[cmd_start..cmd_end]);
            try segs.append(allocator, .{ .inject = .{ .cmd = cmd } });
            // 跳过 close fence 行
            const close_line_end = std.mem.indexOfScalarPos(u8, body, close_pos, '\n') orelse body.len;
            i = if (close_line_end < body.len) close_line_end + 1 else body.len;
            lit_start = i;
            continue;
        }

        // 内联 !`cmd`: 必须在行首或紧跟空白(\s 或 \t)
        if (body[i] == '!' and i + 1 < body.len and body[i + 1] == '`') {
            const prev_ok = (i == 0) or isInlineLeftDelim(body[i - 1]);
            if (prev_ok) {
                // 找闭合 `
                if (std.mem.indexOfScalarPos(u8, body, i + 2, '`')) |close| {
                    try segs.append(allocator, .{ .literal = .{ .start = lit_start, .end = i } });
                    const cmd = try allocator.dupe(u8, body[i + 2 .. close]);
                    try segs.append(allocator, .{ .inject = .{ .cmd = cmd } });
                    i = close + 1;
                    lit_start = i;
                    continue;
                }
            }
        }
        i += 1;
    }
    // 收尾 literal
    try segs.append(allocator, .{ .literal = .{ .start = lit_start, .end = body.len } });
}

fn atLineStart(body: []const u8, i: usize) bool {
    return i == 0 or body[i - 1] == '\n';
}

fn isInlineLeftDelim(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

// ============================================================================
// 字符串替换
// ============================================================================

fn substitute(allocator: std.mem.Allocator, text: []const u8, opts: RenderOptions) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '$') {
            // ${VAR}
            if (i + 1 < text.len and text[i + 1] == '{') {
                if (std.mem.indexOfScalarPos(u8, text, i + 2, '}')) |close| {
                    const var_name = text[i + 2 .. close];
                    const repl = lookupBraced(var_name, opts);
                    if (repl) |r| {
                        try out.appendSlice(allocator, r);
                        i = close + 1;
                        continue;
                    }
                    // 未知 ${} 原样保留
                }
            }
            // $ARGUMENTS[N]
            if (i + 11 <= text.len and std.mem.startsWith(u8, text[i..], "$ARGUMENTS[")) {
                if (std.mem.indexOfScalarPos(u8, text, i + 11, ']')) |close| {
                    if (std.fmt.parseInt(usize, text[i + 11 .. close], 10)) |idx| {
                        if (idx < opts.arguments.len) {
                            try out.appendSlice(allocator, opts.arguments[idx]);
                        }
                        i = close + 1;
                        continue;
                    } else |_| {}
                }
            }
            // $ARGUMENTS
            if (i + 10 <= text.len and std.mem.startsWith(u8, text[i..], "$ARGUMENTS")) {
                const next = if (i + 10 < text.len) text[i + 10] else 0;
                if (!isIdentChar(next)) {
                    const all = try joinArgs(allocator, opts.arguments);
                    defer allocator.free(all);
                    try out.appendSlice(allocator, all);
                    i += 10;
                    continue;
                }
            }
            // $N (digit, 0-based)
            if (i + 1 < text.len and std.ascii.isDigit(text[i + 1])) {
                var j: usize = i + 1;
                while (j < text.len and std.ascii.isDigit(text[j])) : (j += 1) {}
                if (std.fmt.parseInt(usize, text[i + 1 .. j], 10)) |idx| {
                    if (idx < opts.arguments.len) {
                        try out.appendSlice(allocator, opts.arguments[idx]);
                    }
                    i = j;
                    continue;
                } else |_| {}
            }
            // $name (命名参数,从 arg_names 找位置 → arguments[pos])
            if (i + 1 < text.len and (std.ascii.isAlphabetic(text[i + 1]) or text[i + 1] == '_')) {
                var j: usize = i + 1;
                while (j < text.len and isIdentChar(text[j])) : (j += 1) {}
                const name = text[i + 1 .. j];
                if (lookupNamed(name, opts)) |val| {
                    try out.appendSlice(allocator, val);
                    i = j;
                    continue;
                }
                // 未知 $name 原样保留(避免吞掉 markdown 里的 $foo)
            }
        }
        try out.append(allocator, text[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

fn lookupBraced(name: []const u8, opts: RenderOptions) ?[]const u8 {
    if (std.mem.eql(u8, name, "CLAUDE_SKILL_DIR")) return opts.skill_dir;
    if (std.mem.eql(u8, name, "CLAUDE_PROJECT_DIR")) return opts.project_dir;
    if (std.mem.eql(u8, name, "CLAUDE_SESSION_ID")) return opts.session_id;
    return null;
}

fn lookupNamed(name: []const u8, opts: RenderOptions) ?[]const u8 {
    for (opts.arg_names, 0..) |n, idx| {
        if (std.mem.eql(u8, n, name) and idx < opts.arguments.len) return opts.arguments[idx];
    }
    return null;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn containsArgsPlaceholder(text: []const u8) bool {
    // 用于判断"原 body 是否提到过 $ARGUMENTS";substitute 之后值可能被替换走,无法回判
    return std.mem.indexOf(u8, text, "$ARGUMENTS") != null;
}

fn joinArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    if (args.len == 0) return try allocator.dupe(u8, "");
    var total: usize = 0;
    for (args) |a| total += a.len;
    total += args.len - 1; // spaces
    var out = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (args, 0..) |a, idx| {
        if (idx > 0) {
            out[pos] = ' ';
            pos += 1;
        }
        @memcpy(out[pos .. pos + a.len], a);
        pos += a.len;
    }
    return out;
}

// ============================================================================
// Bash 注入执行
// ============================================================================

fn runInjection(allocator: std.mem.Allocator, cmd: []const u8, opts: RenderOptions) ![]u8 {
    if (opts.disable_shell_execution) {
        return try allocator.dupe(u8, "[shell command execution disabled by policy]");
    }
    if (std.mem.eql(u8, opts.shell, "powershell")) {
        return try allocator.dupe(u8, "[powershell shell not supported in cc-zig]");
    }
    // /bin/sh -c <cmd>
    const cmd_z = try allocator.dupeZ(u8, cmd);
    defer allocator.free(cmd_z);
    const sh_z: [*:0]const u8 = "/bin/sh";
    const flag_z: [*:0]const u8 = "-c";
    var argv: [4]?[*:0]const u8 = .{ sh_z, flag_z, cmd_z.ptr, null };

    log.debug("skill.inject", "running: {s}", .{cmd});
    const result = common.spawnCaptureStdoutAbortableTimed(argv[0..], allocator, opts.abort, opts.inject_timeout_ms) catch |err| {
        log.warn("skill.inject", "failed: {s}: {s}", .{ cmd, @errorName(err) });
        return try std.fmt.allocPrint(allocator, "[shell command failed: {s}]", .{@errorName(err)});
    };
    // 去掉尾部单个换行(很常见,模型不需要那个空行)
    if (result.len > 0 and result[result.len - 1] == '\n') {
        const trimmed = try allocator.dupe(u8, result[0 .. result.len - 1]);
        allocator.free(result);
        return trimmed;
    }
    return result;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "substitute: $ARGUMENTS" {
    const args = [_][]const u8{ "foo", "bar" };
    const out = try renderBody(testing.allocator,
        "Hello $ARGUMENTS world",
        .{ .arguments = &args },
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Hello foo bar world", out);
}

test "substitute: $N 0-based" {
    const args = [_][]const u8{ "alpha", "beta", "gamma" };
    const out = try renderBody(testing.allocator,
        "first=$0 second=$1 third=$2 $ARGUMENTS",
        .{ .arguments = &args },
    );
    defer testing.allocator.free(out);
    // $ARGUMENTS 占位存在 → 不追加 ARGUMENTS: 行
    try testing.expectEqualStrings("first=alpha second=beta third=gamma alpha beta gamma", out);
}

test "substitute: $ARGUMENTS[N]" {
    const args = [_][]const u8{ "x", "y" };
    const out = try renderBody(testing.allocator,
        "[$ARGUMENTS[0]] vs [$ARGUMENTS[1]]",
        .{ .arguments = &args },
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[x] vs [y]", out);
}

test "substitute: $name (named arg)" {
    const names = [_][]const u8{ "issue", "branch" };
    const args = [_][]const u8{ "#42", "main" };
    const out = try renderBody(testing.allocator,
        "fix $issue on $branch\n$ARGUMENTS",
        .{ .arguments = &args, .arg_names = &names },
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("fix #42 on main\n#42 main", out);
}

test "substitute: $N without \\$ARGUMENTS still triggers append" {
    // 对齐 Claude Code 字面规则:只检查 $ARGUMENTS。$0 $1 不算"用过 args"
    const args = [_][]const u8{ "a", "b" };
    const out = try renderBody(testing.allocator,
        "$0 then $1",
        .{ .arguments = &args },
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "a then b") != null);
    try testing.expect(std.mem.endsWith(u8, out, "ARGUMENTS: a b\n"));
}

test "substitute: unknown \\$foo is preserved as literal" {
    const out = try renderBody(testing.allocator, "price: $foo", .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("price: $foo", out);
}

test "substitute: \\${CLAUDE_SKILL_DIR}" {
    const out = try renderBody(testing.allocator,
        "cd ${CLAUDE_SKILL_DIR}/scripts && ./go.sh",
        .{ .skill_dir = "/home/u/.cc-zig/skills/foo" },
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("cd /home/u/.cc-zig/skills/foo/scripts && ./go.sh", out);
}

test "substitute: \\${CLAUDE_SESSION_ID} + \\${CLAUDE_PROJECT_DIR}" {
    const out = try renderBody(testing.allocator,
        "session ${CLAUDE_SESSION_ID} in ${CLAUDE_PROJECT_DIR}",
        .{ .session_id = "abc-123", .project_dir = "/repo" },
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("session abc-123 in /repo", out);
}

test "missing \\$ARGUMENTS placeholder: appends ARGUMENTS: line" {
    const args = [_][]const u8{ "one", "two" };
    const out = try renderBody(testing.allocator,
        "Static skill body.",
        .{ .arguments = &args },
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.endsWith(u8, out, "ARGUMENTS: one two\n"));
}

test "present \\$ARGUMENTS placeholder: does NOT append" {
    const args = [_][]const u8{ "one" };
    const out = try renderBody(testing.allocator,
        "Use $ARGUMENTS here.",
        .{ .arguments = &args },
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Use one here.", out);
}

test "inject: line-start !`cmd` runs and replaces" {
    const out = try renderBody(testing.allocator,
        "Output: !`echo hello`",
        .{},
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Output: hello") != null);
}

test "inject: mid-line after letter is NOT recognized (KEY=!`cmd`)" {
    const out = try renderBody(testing.allocator,
        "KEY=!`echo HELLO`",
        .{},
    );
    defer testing.allocator.free(out);
    // 原样保留,不执行
    try testing.expectEqualStrings("KEY=!`echo HELLO`", out);
}

test "inject: disabled by policy emits placeholder text" {
    const out = try renderBody(testing.allocator,
        "Output: !`echo bad`",
        .{ .disable_shell_execution = true },
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "disabled by policy") != null);
    try testing.expect(std.mem.indexOf(u8, out, "echo bad") == null);
}

test "inject: fenced ```! multi-line block" {
    const body = "Before\n```!\necho first\necho second\n```\nAfter";
    const out = try renderBody(testing.allocator, body, .{});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Before") != null);
    try testing.expect(std.mem.indexOf(u8, out, "first") != null);
    try testing.expect(std.mem.indexOf(u8, out, "second") != null);
    try testing.expect(std.mem.indexOf(u8, out, "After") != null);
    // ``` 边界都被吃掉
    try testing.expect(std.mem.indexOf(u8, out, "```") == null);
}

test "inject: not recursive — output is plain text" {
    // 注入的 echo 输出 "!`echo nested`",**不**再被当作 inject 处理
    const out = try renderBody(testing.allocator,
        "!`echo '!\\`echo nested\\`'`",
        .{},
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "echo nested") != null);
}

test "inject: failure emits placeholder, does not abort render" {
    const out = try renderBody(testing.allocator,
        "ok: !`/nonexistent-binary-xyz-99 foo` end",
        .{ .inject_timeout_ms = 2000 },
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "ok:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "end") != null);
}
