const std = @import("std");
const pfs = @import("platform").fs;
const common = @import("common.zig");
const tt = @import("test_tmp.zig"); // 测试 fixture 唯一路径(并发隔离)
const toolchain = @import("../util/toolchain.zig");
const ToolContext = @import("context.zig").ToolContext;
const path_mod = @import("../util/path.zig");
const read_state = @import("../core/read_state.zig");
const ToolResultBody = @import("context.zig").ToolResultBody;
const artifact_store = @import("../core/tool_result_artifact.zig");
const result_spool = @import("result_spool.zig");

const STDERR_CAPTURE_BYTES: usize = 64 * 1024;

/// Typed production path. The child stdout is captured on disk from byte zero;
/// pagination and navigation prefixes are rendered into a second bounded
/// capture, while an unmodified full result can become a CAS receipt directly.
pub fn executeBody(ctx: *const ToolContext, args: []const u8) anyerror!ToolResultBody {
    const artifact_id = common.extractJsonArg(args, "artifact_id");
    if (ctx.artifact_root.len == 0) {
        if (artifact_id != null) return error.ArtifactStoreRequired;
        return ToolResultBody.initInline(try execute(ctx, args));
    }

    const allocator = ctx.allocator;
    const pattern = common.extractJsonArg(args, "pattern") orelse return error.MissingPattern;
    if (pattern.len == 0) return error.EmptyPattern;

    // Searching a recovered result in place. `ReadArtifact` can only page byte
    // ranges, so answering "where is the failure in this 40MB log" costs
    // O(size / 32KiB) round trips and re-sends the context each time; the blob
    // is an ordinary file, so one ripgrep answers it. The resolved path names
    // the kernel-private store and must never reach the model, which is why
    // filename output is suppressed below and `files_with_matches` - the one
    // mode whose whole output *is* the path - is refused.
    const path = if (artifact_id) |id| blk: {
        if (common.extractJsonArg(args, "path") != null) {
            common.setErrorDetail(ctx.error_detail, allocator, "pass either path or artifact_id, not both", .{});
            return error.GrepTargetConflict;
        }
        break :blk artifact_store.resolveSearchPath(allocator, ctx.artifact_root, id) catch |err| {
            common.setErrorDetail(ctx.error_detail, allocator, "artifact '{s}' is not searchable: {s}", .{ id, @errorName(err) });
            return err;
        };
    } else try path_mod.normalizeChecked(allocator, common.extractJsonArg(args, "path") orelse ".", .{
        .home = ctx.home_dir,
        .base_dir = ctx.cwd_abs,
        .resolve_relative = ctx.resolve_relative_paths,
    });
    defer allocator.free(path);
    if (artifact_id == null) {
        _ = read_state.statPath(path) catch {
            common.setErrorDetail(ctx.error_detail, allocator, "path not found: '{s}' (用绝对路径或 ~/...?)", .{path});
            return error.PathNotFound;
        };
    }

    const rg_path = try toolchain.ripgrepPath();
    const output_mode = common.extractJsonArg(args, "output_mode") orelse
        if (artifact_id != null) "content" else "files_with_matches";
    var base_argv = std.ArrayList([]const u8).empty;
    defer base_argv.deinit(allocator);
    try base_argv.append(allocator, rg_path);
    try base_argv.append(allocator, "--no-messages");
    if (artifact_id != null) {
        // Belt and braces: ripgrep already omits the filename for a single
        // explicit file, and this makes that independent of its heuristics.
        try base_argv.append(allocator, "--no-filename");
    }
    if (std.mem.eql(u8, output_mode, "files_with_matches")) {
        if (artifact_id != null) {
            common.setErrorDetail(ctx.error_detail, allocator, "output_mode files_with_matches is meaningless for a single artifact; use content or count", .{});
            return error.InvalidOutputMode;
        }
        try base_argv.append(allocator, "-l");
    } else if (std.mem.eql(u8, output_mode, "count")) {
        try base_argv.append(allocator, "-c");
    } else if (std.mem.eql(u8, output_mode, "content")) {
        if (common.extractJsonArg(args, "-n") == null or isTrue(common.extractJsonArg(args, "-n")))
            try base_argv.append(allocator, "-n");
    } else return error.InvalidOutputMode;

    if (std.mem.eql(u8, output_mode, "content")) {
        if (common.extractJsonArg(args, "-B")) |value| {
            try base_argv.append(allocator, "-B");
            try base_argv.append(allocator, value);
        }
        if (common.extractJsonArg(args, "-A")) |value| {
            try base_argv.append(allocator, "-A");
            try base_argv.append(allocator, value);
        }
        if (common.extractJsonArg(args, "-C")) |value| {
            try base_argv.append(allocator, "-C");
            try base_argv.append(allocator, value);
        } else if (common.extractJsonArg(args, "context")) |value| {
            try base_argv.append(allocator, "-C");
            try base_argv.append(allocator, value);
        }
    }
    if (isTrue(common.extractJsonArg(args, "-i"))) try base_argv.append(allocator, "-i");
    if (common.extractJsonArg(args, "type")) |value| {
        try base_argv.append(allocator, "--type");
        try base_argv.append(allocator, value);
    }
    if (common.extractJsonArg(args, "glob")) |value| {
        try base_argv.append(allocator, "--glob");
        try base_argv.append(allocator, value);
    }
    if (isTrue(common.extractJsonArg(args, "multiline"))) {
        try base_argv.append(allocator, "-U");
        try base_argv.append(allocator, "--multiline-dotall");
    }

    const head_limit = parseUsize(common.extractJsonArg(args, "head_limit")) orelse DEFAULT_HEAD_LIMIT;
    const offset = parseUsize(common.extractJsonArg(args, "offset")) orelse 0;
    const collapsed = collapseDoubleBackslashes(allocator, pattern);
    defer if (collapsed) |value| allocator.free(value);
    const Attempt = struct { pat: []const u8, literal: bool, note: ?[]const u8 };
    var attempts: [3]Attempt = undefined;
    var attempt_count: usize = 0;
    attempts[attempt_count] = .{ .pat = pattern, .literal = false, .note = null };
    attempt_count += 1;
    if (collapsed) |value| {
        attempts[attempt_count] = .{ .pat = value, .literal = false, .note = "[Grep: pattern auto-repaired — double-escaped backslashes collapsed]\n" };
        attempt_count += 1;
    }
    attempts[attempt_count] = .{ .pat = pattern, .literal = true, .note = "[Grep: pattern was not a valid regex — matched as FIXED-STRING literal instead]\n" };
    attempt_count += 1;

    var spawned: common.SpoolSpawnOut = undefined;
    var spawned_valid = false;
    defer if (spawned_valid) spawned.deinit();
    var used_note: ?[]const u8 = null;
    var attempt_index: usize = 0;
    while (attempt_index < attempt_count) : (attempt_index += 1) {
        const attempt = attempts[attempt_index];
        var items = std.array_list.Managed([]const u8).init(allocator);
        defer items.deinit();
        try items.appendSlice(base_argv.items);
        if (attempt.literal) try items.append("-F");
        try items.append(attempt.pat);
        try items.append(path);
        var argv_z = try allocator.alloc(?[*:0]const u8, items.items.len + 1);
        defer {
            for (argv_z[0..items.items.len]) |value| if (value) |ptr| allocator.free(std.mem.span(ptr));
            allocator.free(argv_z);
        }
        for (items.items, 0..) |value, index|
            argv_z[index] = (try allocator.dupeZ(u8, value)).ptr;
        argv_z[items.items.len] = null;

        spawned = try common.spawnCaptureToSpoolTimed(
            argv_z,
            allocator,
            ctx.artifact_root,
            ctx.abort,
            0,
            ctx.spawn_tick_fn,
            artifact_store.MAX_ARTIFACT_BYTES,
            STDERR_CAPTURE_BYTES,
            null,
        );
        spawned_valid = true;
        const parse_error = spawned.exit_code == 2 and
            try captureContains(allocator, &spawned.stderr, "regex parse error");
        if (parse_error and attempt_index + 1 < attempt_count) {
            spawned.deinit();
            spawned_valid = false;
            continue;
        }
        used_note = attempt.note;
        break;
    }

    const startup_failure = spawned.exit_code < 0 or spawned.exit_code > 2 or
        (spawned.exit_code == 2 and spawned.stderr.bytes > 0);
    if (spawned.stdout.bytes == 0 and startup_failure) {
        const detail = try spawned.stderr.readRangeAlloc(
            allocator,
            0,
            @intCast(@min(spawned.stderr.bytes, 300)),
        );
        defer allocator.free(detail);
        // `error_detail` is rendered straight into the model-visible tool
        // error, so a child's diagnostics are a second way the store path
        // could reach the model. `--no-messages` suppresses ripgrep's file I/O
        // errors today, but that is a property of ripgrep's flags rather than
        // an invariant this file controls; the check costs one scan.
        if (artifact_id != null and std.mem.indexOf(u8, detail, path) != null) {
            common.setErrorDetail(ctx.error_detail, allocator, "ripgrep failed on the artifact (exit {d})", .{spawned.exit_code});
        } else {
            common.setErrorDetail(ctx.error_detail, allocator, "ripgrep failed (exit {d}): {s}", .{ spawned.exit_code, detail });
        }
        return error.GrepExecFailed;
    }

    // The LSP definition hitchhiker resolves workspace symbols; an artifact is
    // not a workspace file and its path must not be handed to the LSP either.
    const prefix = if (artifact_id != null) null else definitionsPrefix(allocator, pattern, path, ctx);
    defer if (prefix) |value| allocator.free(value);
    const needs_projection = used_note != null or prefix != null or head_limit != 0 or offset != 0;
    if (!needs_projection) {
        return result_spool.finishCaptureAsBody(
            allocator,
            ctx.artifact_root,
            &spawned.stdout,
            .text_utf8,
            spawned.capture_complete,
        );
    }

    var projected = try artifact_store.Capture.begin(
        allocator,
        ctx.artifact_root,
        artifact_store.MAX_ARTIFACT_BYTES,
    );
    defer projected.deinit();
    if (used_note) |value| try projected.write(value);
    if (prefix) |value| try projected.write(value);
    if (head_limit == 0 and offset == 0) {
        try result_spool.copyAll(&spawned.stdout, &projected);
    } else {
        try paginateCapture(&spawned.stdout, &projected, offset, head_limit);
    }
    try projected.seal();
    return result_spool.finishCaptureAsBody(
        allocator,
        ctx.artifact_root,
        &projected,
        .text_utf8,
        spawned.capture_complete,
    );
}

fn captureContains(
    allocator: std.mem.Allocator,
    capture: *artifact_store.Capture,
    needle: []const u8,
) !bool {
    const bytes = try capture.readRangeAlloc(allocator, 0, @intCast(capture.bytes));
    defer allocator.free(bytes);
    return std.mem.indexOf(u8, bytes, needle) != null;
}

fn paginateCapture(
    source: *artifact_store.Capture,
    destination: *artifact_store.Capture,
    offset: usize,
    head_limit: usize,
) !void {
    try source.rewind();
    var buffer: [64 * 1024]u8 = undefined;
    var line_index: usize = 0;
    var line_has_bytes = false;
    while (true) {
        const read_count = try source.read(&buffer);
        if (read_count == 0) break;
        var cursor: usize = 0;
        while (cursor < read_count) {
            const newline = std.mem.indexOfScalarPos(u8, buffer[0..read_count], cursor, '\n');
            const end = newline orelse read_count;
            const selected = line_index >= offset and
                (head_limit == 0 or line_index - offset < head_limit);
            if (selected and end > cursor) try destination.write(buffer[cursor..end]);
            line_has_bytes = line_has_bytes or end > cursor;
            if (newline != null) {
                if (selected) try destination.write("\n");
                line_index += 1;
                line_has_bytes = false;
                cursor = end + 1;
            } else cursor = end;
        }
    }
    if (line_has_bytes) line_index += 1;
    const start = @min(offset, line_index);
    const remaining = line_index - start;
    const take = if (head_limit == 0) remaining else @min(head_limit, remaining);
    const end = start + take;
    if (end < line_index or start > 0) {
        var marker: [160]u8 = undefined;
        const bytes = try std.fmt.bufPrint(
            &marker,
            "\n[appliedLimit: showing lines {d}-{d} of {d}; pass offset={d} for the next page]\n",
            .{ start + 1, end, line_index, end },
        );
        try destination.write(bytes);
    }
}

/// 默认 head_limit(对齐 Claude Code GrepTool):content 模式不传 head_limit 时只返前 250 行,
/// 防止宽匹配把整个文件灌进上下文。显式传 head_limit=0 = 无限。
pub const DEFAULT_HEAD_LIMIT: usize = 250;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const pattern = common.extractJsonArg(args, "pattern") orelse return error.MissingPattern;
    const path_raw = common.extractJsonArg(args, "path") orelse ".";
    if (pattern.len == 0) return error.EmptyPattern;

    // 归一化路径(展开 ~、折叠 //、查 traversal)。execve 不经 shell,~ 必须自己展开。
    const path = try path_mod.normalizeChecked(allocator, path_raw, .{
        .home = ctx.home_dir,
        .base_dir = ctx.cwd_abs,
        .resolve_relative = ctx.resolve_relative_paths,
    });
    defer allocator.free(path);
    // 存在性检查:rg 的 --no-messages 会把"路径不存在"静默成空结果。这里先拦,给模型明确错误。
    _ = read_state.statPath(path) catch {
        common.setErrorDetail(ctx.error_detail, allocator, "path not found: '{s}' (用绝对路径或 ~/...?)", .{path});
        return error.PathNotFound;
    };

    const rg_path = try toolchain.ripgrepPath();

    // output_mode: content (默认，带行号) / files_with_matches / count
    const output_mode = common.extractJsonArg(args, "output_mode") orelse "files_with_matches";

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, rg_path);
    // 静默 stderr 上的权限/访问错误，避免污染 tool_result 和 CI 日志。
    try argv.append(allocator, "--no-messages");

    // 基础模式选择
    if (std.mem.eql(u8, output_mode, "files_with_matches")) {
        try argv.append(allocator, "-l");
    } else if (std.mem.eql(u8, output_mode, "count")) {
        try argv.append(allocator, "-c");
    } else if (std.mem.eql(u8, output_mode, "content")) {
        // 默认 content 模式开 -n
        if (common.extractJsonArg(args, "-n") == null or isTrue(common.extractJsonArg(args, "-n"))) {
            try argv.append(allocator, "-n");
        }
    } else {
        return error.InvalidOutputMode;
    }

    // -B / -A / -C（仅在 content 模式有意义，但 rg 会忽略非 content 的数值）
    if (std.mem.eql(u8, output_mode, "content")) {
        if (common.extractJsonArg(args, "-B")) |s| {
            try argv.append(allocator, "-B");
            try argv.append(allocator, s);
        }
        if (common.extractJsonArg(args, "-A")) |s| {
            try argv.append(allocator, "-A");
            try argv.append(allocator, s);
        }
        if (common.extractJsonArg(args, "-C")) |s| {
            try argv.append(allocator, "-C");
            try argv.append(allocator, s);
        } else if (common.extractJsonArg(args, "context")) |s| {
            // 兼容旧 "context" 参数
            try argv.append(allocator, "-C");
            try argv.append(allocator, s);
        }
    }

    // -i 大小写不敏感
    if (isTrue(common.extractJsonArg(args, "-i"))) {
        try argv.append(allocator, "-i");
    }

    // --type
    if (common.extractJsonArg(args, "type")) |t| {
        try argv.append(allocator, "--type");
        try argv.append(allocator, t);
    }

    // --glob
    if (common.extractJsonArg(args, "glob")) |g| {
        try argv.append(allocator, "--glob");
        try argv.append(allocator, g);
    }

    // multiline：-U 启用多行模式（需要 -P PCRE）
    if (isTrue(common.extractJsonArg(args, "multiline"))) {
        try argv.append(allocator, "-U");
        try argv.append(allocator, "--multiline-dotall");
    }

    // head_limit / offset：全局（跨文件）分页。
    // 不再用 rg 的 -m（那是每文件上限，跨文件会失真）；改为抓全量输出后按行截断。
    // offset = 跳过前 N 行；head_limit = 截断后保留 N 行。
    // **默认 head_limit=250**（对齐 Claude Code,防止 `grep "."` 把整个文件灌进上下文）。
    // 显式传 head_limit=0 = 无限（用户主动要全量时）。缺省（null）→ 用默认 250。
    const head_limit: usize = parseUsize(common.extractJsonArg(args, "head_limit")) orelse DEFAULT_HEAD_LIMIT;
    const offset = parseUsize(common.extractJsonArg(args, "offset")) orelse 0;

    // v39 G1 修复阶梯(终局取证:GLM 在 JSON 里双重转义正则——`\\\\(` 到达
    // rg 成"字面反斜杠+未闭合组",sealed 一轮 28 次 GrepExecFailed/20 trial,
    // 且错误经 system_error 黑盒化,模型自纠慢)。确定性阶梯:
    //   ① 原样 → ② 反斜杠折叠(\\→\,仅当模式含双反斜杠) → ③ -F 字面量。
    // 仅对 rg 的 "regex parse error" 降级;修复命中时在输出首行注明,模型
    // 可见可学。任务无关:纯入参转义修复,不看模式语义。
    const collapsed = collapseDoubleBackslashes(allocator, pattern);
    defer if (collapsed) |c| allocator.free(c);
    const Attempt = struct { pat: []const u8, literal: bool, note: ?[]const u8 };
    var attempts_buf: [3]Attempt = undefined;
    var n_attempts: usize = 0;
    attempts_buf[n_attempts] = .{ .pat = pattern, .literal = false, .note = null };
    n_attempts += 1;
    if (collapsed) |c| {
        attempts_buf[n_attempts] = .{ .pat = c, .literal = false, .note = "[Grep: pattern auto-repaired — double-escaped backslashes collapsed]\n" };
        n_attempts += 1;
    }
    attempts_buf[n_attempts] = .{ .pat = pattern, .literal = true, .note = "[Grep: pattern was not a valid regex — matched as FIXED-STRING literal instead]\n" };
    n_attempts += 1;

    var spawned: common.SpawnOut = undefined;
    var used_note: ?[]const u8 = null;
    var ai: usize = 0;
    while (ai < n_attempts) : (ai += 1) {
        const at = attempts_buf[ai];
        var items = std.array_list.Managed([]const u8).init(allocator);
        defer items.deinit();
        try items.appendSlice(argv.items);
        if (at.literal) try items.append("-F");
        try items.append(at.pat);
        try items.append(path);
        var argv_z = try allocator.alloc(?[*:0]const u8, items.items.len + 1);
        defer {
            for (argv_z[0..items.items.len]) |p| if (p) |pp| allocator.free(std.mem.span(pp));
            allocator.free(argv_z);
        }
        for (items.items, 0..) |s, i| {
            argv_z[i] = (try allocator.dupeZ(u8, s)).ptr;
        }
        argv_z[items.items.len] = null;

        // rg 退出语义:0=有匹配,1=无匹配(合法空),>=2/信号死=真实故障。
        spawned = try common.spawnCaptureWithStderrTimed(
            argv_z,
            allocator,
            ctx.abort,
            0,
            ctx.spawn_tick_fn,
            common.MAX_SPAWN_CAPTURE_BYTES,
            null,
        );
        const parse_error = spawned.exit_code == 2 and
            std.mem.indexOf(u8, spawned.stderr, "regex parse error") != null;
        if (parse_error and ai + 1 < n_attempts) {
            allocator.free(spawned.stdout);
            allocator.free(spawned.stderr);
            continue;
        }
        used_note = at.note;
        break;
    }
    defer allocator.free(spawned.stderr);
    // 有输出的 exit 2 = 部分目录不可读的 best-effort 结果,照常返回。
    // 空输出时只把"工具没跑起来"当故障:信号死(负值,如沙箱内 dyld 加载失败)、
    // exit>2、或 exit 2 且带 stderr(用法/启动错误)。exit 2 + 空 stderr 是
    // --no-messages 吞掉的权限噪音,维持旧的空结果语义。
    const startup_failure = spawned.exit_code < 0 or spawned.exit_code > 2 or
        (spawned.exit_code == 2 and spawned.stderr.len > 0);
    if (spawned.stdout.len == 0 and startup_failure) {
        allocator.free(spawned.stdout);
        common.setErrorDetail(ctx.error_detail, allocator, "ripgrep failed (exit {d}): {s}", .{
            spawned.exit_code,
            spawned.stderr[0..@min(spawned.stderr.len, 300)],
        });
        return error.GrepExecFailed;
    }
    var raw = spawned.stdout;
    if (used_note) |note| {
        if (raw.len > 0) {
            const with_note = try std.mem.concat(allocator, u8, &.{ note, raw });
            allocator.free(raw);
            raw = with_note;
        }
    }

    // grep 主体结果(可能分页)。
    const grep_out: []u8 = blk: {
        if (head_limit == 0 and offset == 0) break :blk raw; // 原样(测试兼容)
        defer allocator.free(raw);
        break :blk try paginate(allocator, raw, offset, head_limit);
    };

    // 搭车增强:pattern 是裸标识符时,前置 FindSymbol 定义块——模型找符号时定义就是
    // 它最想要的,直接塞到眼前,省一次显式 FindSymbol 调用。非标识符(正则/含空格)跳过。
    if (definitionsPrefix(allocator, pattern, path, ctx)) |prefix| {
        defer allocator.free(prefix);
        defer allocator.free(grep_out);
        return try std.mem.concat(allocator, u8, &.{ prefix, grep_out });
    }
    return grep_out;
}

/// pattern 是裸标识符(无正则元字符、合法标识符形态)→ 返回 FindSymbol 定义块字符串,
/// 否则 null。定义块形如:
///   Definitions of `clamp` (via FindSymbol — exact symbol definitions):
///     util.zig:3  function  pub fn clamp(...)
///   ── all grep matches below ──
/// 找不到定义 / 任何错误 → null(静默降级,绝不影响 grep 主结果)。
fn definitionsPrefix(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    path: []const u8,
    ctx: *const ToolContext,
) ?[]u8 {
    if (!isBareIdentifier(pattern)) return null;
    const find_symbol = @import("find_symbol.zig");
    const defs = find_symbol.findDefinitions(allocator, pattern, path, null, ctx) catch return null;
    defer {
        for (defs) |s| find_symbol.freeSymbolPublic(allocator, s);
        allocator.free(defs);
    }
    if (defs.len == 0) return null;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    w.print("Definitions of `{s}` (via FindSymbol — exact symbol definitions):\n", .{pattern}) catch return null;
    for (defs) |s| {
        w.print("  {s}:{d}  {s}  {s}\n", .{ s.file, s.line_start, s.kind.jsonName(), s.signature }) catch return null;
    }
    w.writeAll("── all grep matches below ──\n") catch return null;
    return out.toOwnedSlice() catch null;
}

/// 合法标识符:首字符字母/下划线,其余字母/数字/下划线;非空。
/// 排除一切正则元字符、空格、点号等——这些是真·正则搜索,不该触发符号查找。
fn isBareIdentifier(s: []const u8) bool {
    if (s.len == 0 or s.len > 128) return false;
    for (s, 0..) |c, i| {
        const ok = std.ascii.isAlphabetic(c) or c == '_' or (i > 0 and std.ascii.isDigit(c));
        if (!ok) return false;
    }
    return true;
}

/// 按行做全局 offset + head_limit 截断。head_limit=0 表示无限。
/// 截断发生时在末尾追加一行 appliedLimit 提示，让模型知道还有更多结果、可用 offset 翻页。
fn paginate(allocator: std.mem.Allocator, raw: []const u8, offset: usize, head_limit: usize) ![]u8 {
    // 统计 + 收集行（保留行内容，不含换行符）
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |ln| {
        // splitScalar 末尾的空串（raw 以 \n 结尾）跳过
        if (ln.len == 0 and it.peek() == null) break;
        try lines.append(allocator, ln);
    }
    const total = lines.items.len;

    const start = @min(offset, total);
    const remaining = total - start;
    const take = if (head_limit == 0) remaining else @min(head_limit, remaining);
    const end = start + take;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (lines.items[start..end]) |ln| {
        try out.writer.writeAll(ln);
        try out.writer.writeByte('\n');
    }

    const truncated = end < total or start > 0;
    if (truncated) {
        try out.writer.print(
            "\n[appliedLimit: showing lines {d}-{d} of {d}; pass offset={d} for the next page]\n",
            .{ start + 1, end, total, end },
        );
    }
    return try out.toOwnedSlice();
}

fn parseUsize(s: ?[]const u8) ?usize {
    const v = s orelse return null;
    return std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t"), 10) catch null;
}

fn isTrue(s: ?[]const u8) bool {
    return s != null and std.mem.eql(u8, s.?, "true");
}

fn testCtx() ToolContext {
    return ToolContext.simple(std.testing.allocator);
}

/// v39 G1:把双反斜杠折叠一级(`\\\\` 到 `\\`)。模式不含双反斜杠 → null(无可修)。
fn collapseDoubleBackslashes(allocator: std.mem.Allocator, pat: []const u8) ?[]u8 {
    if (std.mem.indexOf(u8, pat, "\\\\") == null) return null;
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    var i: usize = 0;
    while (i < pat.len) : (i += 1) {
        if (i + 1 < pat.len and pat[i] == '\\' and pat[i + 1] == '\\') {
            out.append('\\') catch return null;
            i += 1;
        } else {
            out.append(pat[i]) catch return null;
        }
    }
    return out.toOwnedSlice() catch null;
}

test "GrepTool missing pattern" {
    const ctx = testCtx();
    try std.testing.expectError(error.MissingPattern, execute(&ctx, "{\"path\":\".\"}"));
}

test "GrepTool empty pattern" {
    const ctx = testCtx();
    try std.testing.expectError(error.EmptyPattern, execute(&ctx, "{\"pattern\":\"\"}"));
}

test "GrepTool invalid output_mode" {
    const ctx = testCtx();
    try std.testing.expectError(error.InvalidOutputMode, execute(&ctx, "{\"pattern\":\"x\",\"output_mode\":\"bogus\"}"));
}

test "GrepTool files_with_matches default" {
    // pattern 只需不崩即可，rg 可能返空
    const ctx = testCtx();
    var dbuf: [512]u8 = undefined;
    const dpath = tt.path(&dbuf, "."); // per-pid 临时目录本身
    const djson = try std.fmt.allocPrint(std.testing.allocator, "{{\"pattern\":\"zzzzzz-nonexistent-zzzzzz\",\"path\":\"{s}\"}}", .{dpath});
    defer std.testing.allocator.free(djson);
    const r = try execute(&ctx, djson);
    defer std.testing.allocator.free(r);
}

test "GrepTool content mode with -n" {
    const ctx = testCtx();
    // 准备一个包含 "needle" 的临时文件(per-pid 唯一路径,避免并发撞车)
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "grep-content-test.txt");
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const text = "pre\nneedle line\npost\n";
    _ = pfs.write(fd, text);
    _ = pfs.close(fd);
    defer _ = std.c.unlink(path.ptr);

    var abuf: [320]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"pattern\":\"needle\",\"path\":\"{s}\",\"output_mode\":\"content\"}}", .{path});
    const r = try execute(&ctx, args);
    defer std.testing.allocator.free(r);
    // content 模式应含行号 "2:" 和匹配文本 "needle"
    try std.testing.expect(std.mem.indexOf(u8, r, "needle") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "2:") != null);
}

test "GrepTool count mode" {
    const ctx = testCtx();
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "grep-count-test.txt");
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const text = "x\nx\ny\nx\n";
    _ = pfs.write(fd, text);
    _ = pfs.close(fd);
    defer _ = std.c.unlink(path.ptr);

    var abuf: [320]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"pattern\":\"x\",\"path\":\"{s}\",\"output_mode\":\"count\"}}", .{path});
    const r = try execute(&ctx, args);
    defer std.testing.allocator.free(r);
    // rg -c 对单文件输出 "3\n"（无 path 前缀）
    const trimmed = std.mem.trim(u8, r, " \r\n");
    try std.testing.expectEqualStrings("3", trimmed);
}

test "GrepTool case insensitive" {
    const ctx = testCtx();
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "grep-i-test.txt");
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const text = "HELLO\nworld\n";
    _ = pfs.write(fd, text);
    _ = pfs.close(fd);
    defer _ = std.c.unlink(path.ptr);

    var abuf: [320]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"pattern\":\"hello\",\"path\":\"{s}\",\"output_mode\":\"content\",\"-i\":true}}", .{path});
    const r = try execute(&ctx, args);
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "HELLO") != null);
}

test "GrepTool -B -A context" {
    const ctx = testCtx();
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "grep-ctx-test.txt");
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const text = "before\nmatch\nafter\nother\n";
    _ = pfs.write(fd, text);
    _ = pfs.close(fd);
    defer _ = std.c.unlink(path.ptr);

    var abuf: [360]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"pattern\":\"match\",\"path\":\"{s}\",\"output_mode\":\"content\",\"-B\":\"1\",\"-A\":\"1\"}}", .{path});
    const r = try execute(&ctx, args);
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "after") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "other") == null);
}

test "GrepTool -C context shorthand" {
    const ctx = testCtx();
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "grep-cC-test.txt");
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const text = "a\nb\nHIT\nc\nd\n";
    _ = pfs.write(fd, text);
    _ = pfs.close(fd);
    defer _ = std.c.unlink(path.ptr);

    var abuf: [360]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"pattern\":\"HIT\",\"path\":\"{s}\",\"output_mode\":\"content\",\"-C\":\"1\"}}", .{path});
    const r = try execute(&ctx, args);
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "b") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "c") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "a") == null);
}

test "GrepTool glob filter" {
    const ctx = testCtx();
    // 在 per-pid 临时目录造两个文件：一个 .zig 一个 .txt
    var zbuf: [256]u8 = undefined;
    var tbuf: [256]u8 = undefined;
    const zig_path = tt.path(&zbuf, "grep-glob.zig");
    const txt_path = tt.path(&tbuf, "grep-glob.txt");
    const text = "hello\n";

    const fd1 = pfs.open(zig_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = pfs.write(fd1, text);
    _ = pfs.close(fd1);
    const fd2 = pfs.open(txt_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    _ = pfs.write(fd2, text);
    _ = pfs.close(fd2);
    defer _ = std.c.unlink(zig_path.ptr);
    defer _ = std.c.unlink(txt_path.ptr);

    // 搜索 per-pid 目录,glob 只命中 .zig。
    var dbuf: [256]u8 = undefined;
    const dir = tt.path(&dbuf, ""); // 目录本身(末尾 /)
    var abuf: [384]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"pattern\":\"hello\",\"path\":\"{s}\",\"output_mode\":\"files_with_matches\",\"glob\":\"grep-glob.zig\"}}", .{dir});
    const r = try execute(&ctx, args);
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "grep-glob.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "grep-glob.txt") == null);
}

test "paginate: head_limit truncates and adds appliedLimit notice" {
    const a = std.testing.allocator;
    const raw = "l1\nl2\nl3\nl4\nl5\n";
    const r = try paginate(a, raw, 0, 2);
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "l1\nl2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "l3") == null);
    try std.testing.expect(std.mem.indexOf(u8, r, "appliedLimit") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "of 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "offset=2") != null);
}

test "paginate: offset skips leading lines" {
    const a = std.testing.allocator;
    const raw = "l1\nl2\nl3\nl4\n";
    const r = try paginate(a, raw, 2, 0); // 0 = 无限 head_limit
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "l1") == null);
    try std.testing.expect(std.mem.indexOf(u8, r, "l3\nl4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "appliedLimit") != null);
}

test "paginate: limit >= total has no notice" {
    const a = std.testing.allocator;
    const raw = "l1\nl2\n";
    const r = try paginate(a, raw, 0, 10);
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "l1\nl2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "appliedLimit") == null);
}

test "paginate: offset beyond total returns just notice" {
    const a = std.testing.allocator;
    const raw = "l1\nl2\n";
    const r = try paginate(a, raw, 99, 0); // 0 = 无限
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "l1") == null);
    try std.testing.expect(std.mem.indexOf(u8, r, "of 2") != null);
}

test "GrepTool global head_limit across content" {
    const ctx = testCtx();
    var pbuf: [512]u8 = undefined;
    const path = tt.path(&pbuf, "grep-headlimit.txt");
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    const text = "m\nm\nm\nm\nm\n";
    _ = pfs.write(fd, text);
    _ = pfs.close(fd);
    defer _ = std.c.unlink(path.ptr);

    const json = try std.fmt.allocPrint(std.testing.allocator, "{{\"pattern\":\"m\",\"path\":\"{s}\",\"output_mode\":\"content\",\"head_limit\":2}}", .{path});
    defer std.testing.allocator.free(json);
    const r = try execute(&ctx, json);
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "appliedLimit") != null);
}

test "GrepTool 默认 head_limit=250:不传时宽匹配被截断(防撑爆)" {
    const ctx = testCtx();
    var pbuf: [512]u8 = undefined;
    const path = tt.path(&pbuf, "grep-default-cap.txt");
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    // 写 300 行全匹配 → 不传 head_limit → 应只返 250 行 + appliedLimit 提示。
    var i: usize = 0;
    while (i < 300) : (i += 1) _ = pfs.write(fd, "match\n");
    _ = pfs.close(fd);
    defer _ = std.c.unlink(path.ptr);

    const json = try std.fmt.allocPrint(std.testing.allocator, "{{\"pattern\":\"match\",\"path\":\"{s}\",\"output_mode\":\"content\"}}", .{path});
    defer std.testing.allocator.free(json);
    const r = try execute(&ctx, json);
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "appliedLimit") != null); // 被截断
    // 数 match 行数应 ≤ 250(+提示行)。
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, r, '\n');
    while (it.next()) |ln| {
        if (std.mem.indexOf(u8, ln, "match") != null) count += 1;
    }
    try std.testing.expect(count <= 250);
}

test "GrepTool head_limit=0 显式无限:返回全部不截断" {
    const ctx = testCtx();
    var pbuf: [512]u8 = undefined;
    const path = tt.path(&pbuf, "grep-unlimited.txt");
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    var i: usize = 0;
    while (i < 300) : (i += 1) _ = pfs.write(fd, "match\n");
    _ = pfs.close(fd);
    defer _ = std.c.unlink(path.ptr);

    const json = try std.fmt.allocPrint(std.testing.allocator, "{{\"pattern\":\"match\",\"path\":\"{s}\",\"output_mode\":\"content\",\"head_limit\":0}}", .{path});
    defer std.testing.allocator.free(json);
    const r = try execute(&ctx, json);
    defer std.testing.allocator.free(r);
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, r, '\n');
    while (it.next()) |ln| {
        if (std.mem.indexOf(u8, ln, "match") != null) count += 1;
    }
    try std.testing.expect(count == 300); // 全返回
}

test "isBareIdentifier 仅接受裸标识符,拒绝正则/空格/点号" {
    // 裸标识符 → true
    try std.testing.expect(isBareIdentifier("clamp"));
    try std.testing.expect(isBareIdentifier("maxArea"));
    try std.testing.expect(isBareIdentifier("_priv"));
    try std.testing.expect(isBareIdentifier("Parser2"));
    // 正则/特殊 → false(这些是真·正则搜索,不该触发符号查找)
    try std.testing.expect(!isBareIdentifier("log.*Error"));
    try std.testing.expect(!isBareIdentifier("function\\s+\\w+"));
    try std.testing.expect(!isBareIdentifier("foo bar"));
    try std.testing.expect(!isBareIdentifier("a.b"));
    try std.testing.expect(!isBareIdentifier("2fast")); // 数字开头非法标识符
    try std.testing.expect(!isBareIdentifier(""));
    try std.testing.expect(!isBareIdentifier("a" ** 129)); // 超长
}

test "Grep 搭车:裸标识符前置 FindSymbol 定义块;正则不触发(需 zls,Y2 LSP 符号)" {
    const a = std.testing.allocator;
    // Y2 砍 tree-sitter 后:FindSymbol 走 LSP documentSymbol,搭车需 ctx.lsp + git workspace + zls。
    const lsp_servers = @import("../lsp/servers.zig");
    var zbuf: [std.fs.max_path_bytes]u8 = undefined;
    if (lsp_servers.which("zls", &zbuf) == null) return error.SkipZigTest; // 未装 zls → skip

    // per-pid 唯一目录 + fake .git 过 workspace gate。
    var dbuf: [256]u8 = undefined;
    const dir = tt.path(&dbuf, "grep-hitch");
    _ = std.c.mkdir(dir.ptr, 0o755);
    var gbuf: [320]u8 = undefined;
    const gdir = std.fmt.bufPrintZ(&gbuf, "{s}/.git", .{dir}) catch unreachable;
    _ = std.c.mkdir(gdir.ptr, 0o755);
    var fbuf: [320]u8 = undefined;
    const fpath = std.fmt.bufPrintZ(&fbuf, "{s}/sample.zig", .{dir}) catch unreachable;
    defer _ = std.c.unlink(fpath.ptr);
    {
        const fd = pfs.open(fpath.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        try std.testing.expect(fd >= 0);
        const text = "pub fn clamp(v: i32) i32 { return v; }\nconst x = clamp(3);\n";
        _ = pfs.write(fd, text);
        _ = pfs.close(fd);
    }

    const Service = @import("../lsp/service.zig").Service;
    var svc = Service.create(a, dir, null) catch return;
    defer svc.shutdown();
    var ctx = testCtx();
    ctx.lsp = svc;

    // ① 裸标识符 "clamp" → 应前置定义块(zls documentSymbol 报 clamp Function)
    {
        var abuf: [320]u8 = undefined;
        const args = try std.fmt.bufPrint(&abuf, "{{\"pattern\":\"clamp\",\"path\":\"{s}\",\"output_mode\":\"content\"}}", .{dir});
        const r = try execute(&ctx, args);
        defer a.free(r);
        try std.testing.expect(std.mem.indexOf(u8, r, "via FindSymbol") != null);
        try std.testing.expect(std.mem.indexOf(u8, r, "all grep matches below") != null);
        const def_pos = std.mem.indexOf(u8, r, "via FindSymbol").?;
        const sep_pos = std.mem.indexOf(u8, r, "all grep matches below").?;
        try std.testing.expect(def_pos < sep_pos);
    }
    // ② 正则 "clamp.*i32" → 不触发(isBareIdentifier=false),无定义块
    {
        var abuf: [320]u8 = undefined;
        const args = try std.fmt.bufPrint(&abuf, "{{\"pattern\":\"clamp.*i32\",\"path\":\"{s}\",\"output_mode\":\"content\"}}", .{dir});
        const r = try execute(&ctx, args);
        defer a.free(r);
        try std.testing.expect(std.mem.indexOf(u8, r, "via FindSymbol") == null);
    }
}

test "GrepTool 不存在路径 → PathNotFound(非静默空)" {
    // 静默 bug 回归:--no-messages 曾把"路径不存在"吞成空结果。现应明确报错。
    const ctx = testCtx();
    try std.testing.expectError(error.PathNotFound, execute(&ctx, "{\"pattern\":\"x\",\"path\":\"/no/such/dir/zzz-nonexistent\"}"));
}

test "GrepTool path=. 默认值不被存在性检查误伤" {
    const ctx = testCtx();
    // path 缺省 = "." 必存在,statPath 不该拦;pattern 无匹配返空但不报 PathNotFound。
    const r = try execute(&ctx, "{\"pattern\":\"zzzzzz-nonexistent-zzzzzz\"}");
    defer std.testing.allocator.free(r);
}

test "GrepTool v39 repair ladder: double-escaped pattern auto-collapses" {
    // 撤修复必红:GLM 双重转义的 `validate\\\\(` 在 v38 直接 GrepExecFailed;
    // v39 阶梯折叠为 `validate\\(` 后命中,且输出首行携带修复注记。
    const ctx = testCtx();
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "grep-repair-test.txt");
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    _ = pfs.write(fd, "call validate(x) here\n");
    _ = pfs.close(fd);
    defer _ = std.c.unlink(path.ptr);

    var abuf: [400]u8 = undefined;
    // 生产形态:extractJsonArg 不做 JSON 反转义,模型按 JSON 规范写的 `\\(`
    // (意图 `\(`)以**双反斜杠原始字节**抵达工具 → rg 视角=字面反斜杠+未闭合组。
    const args = try std.fmt.bufPrint(&abuf, "{{\"pattern\":\"(?:validate\\\\()\",\"path\":\"{s}\",\"output_mode\":\"content\"}}", .{path});
    const r = try execute(&ctx, args);
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "auto-repaired") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "validate(x)") != null);
}

test "GrepTool v39 repair ladder: hopeless regex degrades to fixed-string" {
    const ctx = testCtx();
    var pbuf: [256]u8 = undefined;
    const path = tt.path(&pbuf, "grep-literal-test.txt");
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    _ = pfs.write(fd, "weird (?:token here\n");
    _ = pfs.close(fd);
    defer _ = std.c.unlink(path.ptr);

    var abuf: [400]u8 = undefined;
    // 无双反斜杠可折叠、本身也不是合法正则 → 第三级 -F 字面量命中。
    const args = try std.fmt.bufPrint(&abuf, "{{\"pattern\":\"(?:token\",\"path\":\"{s}\",\"output_mode\":\"content\"}}", .{path});
    const r = try execute(&ctx, args);
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "FIXED-STRING") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "weird (?:token here") != null);
}

test "collapseDoubleBackslashes unit" {
    const a = std.testing.allocator;
    const c1 = collapseDoubleBackslashes(a, "no backslash");
    try std.testing.expect(c1 == null);
    const c2 = collapseDoubleBackslashes(a, "a\\\\(b").?;
    defer a.free(c2);
    try std.testing.expectEqualStrings("a\\(b", c2);
}

test "Grep searches a recovered artifact without leaking the store path" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    // A result far past any preview: the answer sits in the middle, where
    // neither the head nor the tail of a head/tail preview can reach it.
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(a);
    var line: usize = 0;
    while (line < 40_000) : (line += 1) {
        if (line == 20_000) {
            try payload.appendSlice(a, "fatal: ARTIFACT_NEEDLE not found\n");
        } else {
            try payload.appendSlice(a, "ok: routine build line\n");
        }
    }
    const receipt = try artifact_store.persist(a, root, payload.items);

    var ctx = ToolContext{ .allocator = a, .artifact_root = root };
    const args = try std.fmt.allocPrint(
        a,
        "{{\"pattern\":\"ARTIFACT_NEEDLE\",\"artifact_id\":\"{s}\",\"output_mode\":\"content\"}}",
        .{receipt.id()},
    );
    defer a.free(args);
    var body = try executeBody(&ctx, args);
    defer body.deinit(a);
    var rendered = try body.render(a);
    defer rendered.deinit(a);

    // One call, and the needle is found — versus 20_000 lines of paging.
    try std.testing.expect(std.mem.indexOf(u8, rendered.bytes, "ARTIFACT_NEEDLE") != null);
    // The kernel-private store must not appear anywhere in the model-visible
    // result: leaking it would let any file tool read blobs outside the
    // bounded recovery contract.
    try std.testing.expect(std.mem.indexOf(u8, rendered.bytes, root) == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.bytes, "sha256") == null);

    // count mode answers "how many" without naming anything either.
    const count_args = try std.fmt.allocPrint(
        a,
        "{{\"pattern\":\"ARTIFACT_NEEDLE\",\"artifact_id\":\"{s}\",\"output_mode\":\"count\"}}",
        .{receipt.id()},
    );
    defer a.free(count_args);
    var count_body = try executeBody(&ctx, count_args);
    defer count_body.deinit(a);
    var count_rendered = try count_body.render(a);
    defer count_rendered.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, count_rendered.bytes, "1") != null);
    try std.testing.expect(std.mem.indexOf(u8, count_rendered.bytes, root) == null);
}

test "Grep artifact search refuses ambiguous or path-shaped requests" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const receipt = try artifact_store.persist(a, root, "needle here");

    var ctx = ToolContext{ .allocator = a, .artifact_root = root };
    const both = try std.fmt.allocPrint(
        a,
        "{{\"pattern\":\"needle\",\"artifact_id\":\"{s}\",\"path\":\".\"}}",
        .{receipt.id()},
    );
    defer a.free(both);
    try std.testing.expectError(error.GrepTargetConflict, executeBody(&ctx, both));

    // files_with_matches would emit the store path as its entire output.
    const listing = try std.fmt.allocPrint(
        a,
        "{{\"pattern\":\"needle\",\"artifact_id\":\"{s}\",\"output_mode\":\"files_with_matches\"}}",
        .{receipt.id()},
    );
    defer a.free(listing);
    try std.testing.expectError(error.InvalidOutputMode, executeBody(&ctx, listing));

    const unknown = "{\"pattern\":\"needle\",\"artifact_id\":\"sha256:" ++ ("b" ** 64) ++ "\"}";
    try std.testing.expectError(error.ArtifactNotFound, executeBody(&ctx, unknown));

    // Without a store there is nothing to search, and the legacy path must not
    // silently reinterpret artifact_id as a cwd search.
    var bare = ToolContext{ .allocator = a };
    const bare_args = try std.fmt.allocPrint(a, "{{\"pattern\":\"needle\",\"artifact_id\":\"{s}\"}}", .{receipt.id()});
    defer a.free(bare_args);
    try std.testing.expectError(error.ArtifactStoreRequired, executeBody(&bare, bare_args));
}
