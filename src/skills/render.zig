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
//!    - 文件注入(@path,对齐 Claude Code memory @include):行首或空白后的 `@path` /
//!      `@./rel` / `@~/home` / `@/abs` / `@"含空格"` 被该文件内容替换。相对路径锚定
//!      skill_dir。**安全边界**:解析后必须落在 skill_dir 或 project_dir 之内(防
//!      `@/etc/passwd` 越界读),否则保留字面 `@path` 不读。文件不存在/越界/超限 →
//!      静默保留字面(对齐 Claude Code "non-existent silently ignored",不破坏渲染)。
//!      单文件上限 256KiB。不递归(读入内容不再扫 @/!)。

const std = @import("std");
const pfs = @import("platform").fs;
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
        for (segments.items) |seg| switch (seg) {
            .inject => |inj| allocator.free(inj.cmd),
            .file_ref => |fr| {
                allocator.free(fr.raw);
                allocator.free(fr.literal);
            },
            .literal => {},
        };
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
        .file_ref => |fr| {
            const content = readFileRef(allocator, fr.raw, opts) catch null;
            if (content) |c| {
                defer allocator.free(c);
                try out.appendSlice(allocator, c);
            } else {
                // 不存在/越界/超限:静默保留字面 @path(对齐 Claude Code)。
                try out.appendSlice(allocator, fr.literal);
            }
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
/// 文件注入:raw 是 `@` 后到分隔符的原始路径文本(可能含 ~ / ./);literal 是包含
/// 前导 `@` 的完整原文(读取失败/越界时原样回退)。
const FileRef = struct { raw: []u8, literal: []u8 };
const Segment = union(enum) { literal: Range, inject: Inject, file_ref: FileRef };

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
        // 文件注入 @path / @"quoted path":行首或紧跟空白。对齐 Claude Code 的 (^|\s)@。
        if (body[i] == '@') {
            const prev_ok = (i == 0) or isInlineLeftDelim(body[i - 1]);
            if (prev_ok and i + 1 < body.len) {
                var raw_start: usize = i + 1;
                var raw_end: usize = raw_start;
                var lit_end: usize = undefined;
                if (body[raw_start] == '"') {
                    // @"含空格的路径"
                    raw_start += 1;
                    if (std.mem.indexOfScalarPos(u8, body, raw_start, '"')) |q| {
                        raw_end = q;
                        lit_end = q + 1; // 含闭引号
                    } else {
                        raw_end = raw_start; // 无闭引号 → 不当作 file_ref
                    }
                } else {
                    // @非空白串(到下一个空白/换行止)
                    var p = raw_start;
                    while (p < body.len and !isPathTerminator(body[p])) : (p += 1) {}
                    raw_end = p;
                    lit_end = p;
                }
                // 路径非空才识别(纯 "@ " 或 "@\n" 不算)
                if (raw_end > raw_start) {
                    try segs.append(allocator, .{ .literal = .{ .start = lit_start, .end = i } });
                    const raw = try allocator.dupe(u8, body[raw_start..raw_end]);
                    errdefer allocator.free(raw);
                    const literal = try allocator.dupe(u8, body[i..lit_end]);
                    try segs.append(allocator, .{ .file_ref = .{ .raw = raw, .literal = literal } });
                    i = lit_end;
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

/// @path 的路径在遇到空白/换行/常见标点收尾(对齐 Claude Code 的 @([^\s]+)\b 直觉:
/// 取非空白串;但额外把行尾标点剔出路径,避免把 markdown 的 "see @a/b.md." 里的句点吞进路径)。
fn isPathTerminator(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// @path 文件注入上限。
const MAX_FILE_REF_BYTES: usize = 256 * 1024;

/// 读 @path 引用的文件,带安全边界。返回 owned 内容或 null(不存在/越界/超限/读失败)。
/// 解析:`~/...`→HOME;绝对路径原样;否则相对 skill_dir(空则相对 project_dir)。
/// 边界:解析后的绝对路径必须前缀匹配 skill_dir 或 project_dir 之一,否则拒读(防越界)。
fn readFileRef(allocator: std.mem.Allocator, raw: []const u8, opts: RenderOptions) !?[]u8 {
    if (raw.len == 0) return null;

    // 1) 解析成候选绝对路径(owned)
    const resolved: []u8 = blk: {
        if (raw[0] == '/') {
            break :blk try allocator.dupe(u8, raw);
        } else if (raw[0] == '~') {
            // ~ 或 ~/...
            const home_c = std.c.getenv("HOME") orelse return null;
            const home = std.mem.span(home_c);
            const rest = if (raw.len > 1 and raw[1] == '/') raw[2..] else raw[1..];
            break :blk try std.fs.path.join(allocator, &.{ home, rest });
        } else {
            // 相对:锚 skill_dir,退而锚 project_dir
            const base = if (opts.skill_dir.len > 0) opts.skill_dir else opts.project_dir;
            if (base.len == 0) return null;
            const rel = if (std.mem.startsWith(u8, raw, "./")) raw[2..] else raw;
            break :blk try std.fs.path.join(allocator, &.{ base, rel });
        }
    };
    defer allocator.free(resolved);

    // 2) 安全边界:必须落在 skill_dir 或 project_dir 之内(防 @../../../etc/passwd 越界)。
    //    用 realpath 归一化消除 .. 再前缀匹配。
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_z = try allocator.dupeZ(u8, resolved);
    defer allocator.free(resolved_z);
    const real_ptr = std.c.realpath(resolved_z, &real_buf);
    if (real_ptr == null) return null; // 不存在
    const real = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(real_ptr.?)), 0);

    if (!withinBoundary(allocator, real, opts.skill_dir) and !withinBoundary(allocator, real, opts.project_dir)) {
        log.warn("skill.fileref", "@{s} resolves outside skill/project dir ({s}); refusing", .{ raw, real });
        return null;
    }

    // 3) 读文件(libc,裁剪版 std),带 size cap。
    const fd = pfs.open(real.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = pfs.close(fd);

    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, chunk[0..chunk.len]);
        if (n <= 0) break;
        const un: usize = @intCast(n);
        if (buf.items.len + un > MAX_FILE_REF_BYTES) {
            log.warn("skill.fileref", "@{s} exceeds {d} bytes; refusing", .{ raw, MAX_FILE_REF_BYTES });
            buf.deinit(allocator);
            return null;
        }
        try buf.appendSlice(allocator, chunk[0..un]);
    }
    return try buf.toOwnedSlice(allocator);
}

/// real 是否在 boundary 目录之内。boundary 先 realpath 归一化(macOS /tmp→/private/tmp
/// 符号链接、相对成分等),再前缀匹配 + 路径分隔符边界。boundary 空或无法 realpath → false。
fn withinBoundary(allocator: std.mem.Allocator, real: []const u8, boundary: []const u8) bool {
    if (boundary.len == 0) return false;
    const bz = allocator.dupeZ(u8, boundary) catch return false;
    defer allocator.free(bz);
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    const bp = std.c.realpath(bz, &rb);
    if (bp == null) return false;
    const b = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(bp.?)), 0);
    if (!std.mem.startsWith(u8, real, b)) return false;
    // 防 /a/bc 误配 /a/b:边界后必须是路径分隔符或字符串结束。
    return real.len == b.len or real[b.len] == '/';
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
    // 轴A:skill 注入命令输出封顶 16MB(skill 半可信,一句 `cat hugefile` 就是 OOM 类;Linus P0 遗漏补)。
    const result = common.spawnCaptureStdoutCapped(argv[0..], allocator, opts.abort, opts.inject_timeout_ms, common.MAX_SPAWN_CAPTURE_BYTES) catch |err| {
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
    const out = try renderBody(
        testing.allocator,
        "Hello $ARGUMENTS world",
        .{ .arguments = &args },
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Hello foo bar world", out);
}

test "substitute: $N 0-based" {
    const args = [_][]const u8{ "alpha", "beta", "gamma" };
    const out = try renderBody(
        testing.allocator,
        "first=$0 second=$1 third=$2 $ARGUMENTS",
        .{ .arguments = &args },
    );
    defer testing.allocator.free(out);
    // $ARGUMENTS 占位存在 → 不追加 ARGUMENTS: 行
    try testing.expectEqualStrings("first=alpha second=beta third=gamma alpha beta gamma", out);
}

test "substitute: $ARGUMENTS[N]" {
    const args = [_][]const u8{ "x", "y" };
    const out = try renderBody(
        testing.allocator,
        "[$ARGUMENTS[0]] vs [$ARGUMENTS[1]]",
        .{ .arguments = &args },
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[x] vs [y]", out);
}

test "substitute: $name (named arg)" {
    const names = [_][]const u8{ "issue", "branch" };
    const args = [_][]const u8{ "#42", "main" };
    const out = try renderBody(
        testing.allocator,
        "fix $issue on $branch\n$ARGUMENTS",
        .{ .arguments = &args, .arg_names = &names },
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("fix #42 on main\n#42 main", out);
}

test "substitute: $N without \\$ARGUMENTS still triggers append" {
    // 对齐 Claude Code 字面规则:只检查 $ARGUMENTS。$0 $1 不算"用过 args"
    const args = [_][]const u8{ "a", "b" };
    const out = try renderBody(
        testing.allocator,
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
    const out = try renderBody(
        testing.allocator,
        "cd ${CLAUDE_SKILL_DIR}/scripts && ./go.sh",
        .{ .skill_dir = "/home/u/.metacodes/skills/foo" },
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("cd /home/u/.metacodes/skills/foo/scripts && ./go.sh", out);
}

test "substitute: \\${CLAUDE_SESSION_ID} + \\${CLAUDE_PROJECT_DIR}" {
    const out = try renderBody(
        testing.allocator,
        "session ${CLAUDE_SESSION_ID} in ${CLAUDE_PROJECT_DIR}",
        .{ .session_id = "abc-123", .project_dir = "/repo" },
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("session abc-123 in /repo", out);
}

test "missing \\$ARGUMENTS placeholder: appends ARGUMENTS: line" {
    const args = [_][]const u8{ "one", "two" };
    const out = try renderBody(
        testing.allocator,
        "Static skill body.",
        .{ .arguments = &args },
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.endsWith(u8, out, "ARGUMENTS: one two\n"));
}

test "present \\$ARGUMENTS placeholder: does NOT append" {
    const args = [_][]const u8{"one"};
    const out = try renderBody(
        testing.allocator,
        "Use $ARGUMENTS here.",
        .{ .arguments = &args },
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Use one here.", out);
}

test "inject: line-start !`cmd` runs and replaces" {
    const out = try renderBody(
        testing.allocator,
        "Output: !`echo hello`",
        .{},
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Output: hello") != null);
}

test "inject: mid-line after letter is NOT recognized (KEY=!`cmd`)" {
    const out = try renderBody(
        testing.allocator,
        "KEY=!`echo HELLO`",
        .{},
    );
    defer testing.allocator.free(out);
    // 原样保留,不执行
    try testing.expectEqualStrings("KEY=!`echo HELLO`", out);
}

test "inject: disabled by policy emits placeholder text" {
    const out = try renderBody(
        testing.allocator,
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
    const out = try renderBody(
        testing.allocator,
        "!`echo '!\\`echo nested\\`'`",
        .{},
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "echo nested") != null);
}

test "inject: failure emits placeholder, does not abort render" {
    const out = try renderBody(
        testing.allocator,
        "ok: !`/nonexistent-binary-xyz-99 foo` end",
        .{ .inject_timeout_ms = 2000 },
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "ok:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "end") != null);
}

// @path 文件注入的端到端测试见 tests/component/skill_fileref_test.zig
// (render.zig 的 inline test 依赖跨模块 import,无法 standalone 跑;主 cc-test 套件有已知
//  integration 挂起,故 @path 的 L2 放 component 测试,跑 `zig build test:new`)。
