const std = @import("std");
const tt = @import("test_tmp.zig");
const pfs = @import("platform").fs;
const common = @import("common.zig");
const toolchain = @import("../util/toolchain.zig");
const ToolContext = @import("context.zig").ToolContext;
const path_mod = @import("../util/path.zig");
const read_state = @import("../core/read_state.zig");
const util_json = @import("../util/json.zig");
const ToolResultBody = @import("context.zig").ToolResultBody;
const artifact_store = @import("../core/tool_result_artifact.zig");

const STDERR_CAPTURE_BYTES: usize = 64 * 1024;

/// Production path: ripgrep writes to a private Session capture from byte
/// zero, then only the first 100 bounded path rows are materialized.
pub fn executeBody(ctx: *const ToolContext, args: []const u8) anyerror!ToolResultBody {
    if (ctx.artifact_root.len == 0)
        return ToolResultBody.initInline(try execute(ctx, args));

    const allocator = ctx.allocator;
    const pattern = common.extractJsonArg(args, "pattern") orelse return error.MissingPattern;
    const path_raw = common.extractJsonArg(args, "path") orelse ".";
    if (pattern.len == 0) return error.EmptyPattern;
    const path = try path_mod.normalizeChecked(allocator, path_raw, .{
        .home = ctx.home_dir,
        .base_dir = ctx.cwd_abs,
        .resolve_relative = ctx.resolve_relative_paths,
    });
    defer allocator.free(path);
    _ = read_state.statPath(path) catch {
        common.setErrorDetail(ctx.error_detail, allocator, "path not found: '{s}' (用绝对路径或 ~/...?)", .{path});
        return error.PathNotFound;
    };

    const rg_path = try toolchain.ripgrepPath();
    const pattern_z = try allocator.dupeZ(u8, pattern);
    defer allocator.free(pattern_z);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    var argv = [_]?[*:0]const u8{
        rg_path.ptr,
        "--files",
        "--no-messages",
        "--glob",
        pattern_z.ptr,
        path_z.ptr,
        null,
    };
    var spawned = try common.spawnCaptureToSpoolTimed(
        argv[0..],
        allocator,
        ctx.artifact_root,
        ctx.abort,
        0,
        ctx.spawn_tick_fn,
        artifact_store.MAX_ARTIFACT_BYTES,
        STDERR_CAPTURE_BYTES,
        null,
    );
    defer spawned.deinit();

    const startup_failure = spawned.exit_code < 0 or spawned.exit_code > 2 or
        (spawned.exit_code == 2 and spawned.stderr.bytes > 0);
    if (spawned.stdout.bytes == 0 and startup_failure) {
        const detail = try spawned.stderr.readRangeAlloc(
            allocator,
            0,
            @intCast(@min(spawned.stderr.bytes, 300)),
        );
        defer allocator.free(detail);
        common.setErrorDetail(ctx.error_detail, allocator, "ripgrep failed (exit {d}): {s}", .{
            spawned.exit_code,
            detail,
        });
        return error.GlobExecFailed;
    }

    var summary = try summarizeCapture(allocator, &spawned.stdout, spawned.capture_complete);
    defer summary.deinit(allocator);
    return ToolResultBody.initInline(try renderSummary(allocator, summary));
}

const CaptureSummary = struct {
    files: std.ArrayList([]u8) = .empty,
    count: usize = 0,
    truncated: bool = false,

    fn deinit(self: *CaptureSummary, allocator: std.mem.Allocator) void {
        for (self.files.items) |file| allocator.free(file);
        self.files.deinit(allocator);
    }
};

fn summarizeCapture(
    allocator: std.mem.Allocator,
    capture: *artifact_store.Capture,
    capture_complete: bool,
) !CaptureSummary {
    var summary = CaptureSummary{ .truncated = !capture_complete };
    errdefer summary.deinit(allocator);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try capture.rewind();
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const read_count = try capture.read(&buffer);
        if (read_count == 0) break;
        for (buffer[0..read_count]) |byte| {
            if (byte == '\n') {
                if (line.items.len != 0) {
                    summary.count += 1;
                    if (summary.files.items.len < 100)
                        try summary.files.append(allocator, try allocator.dupe(u8, line.items));
                }
                line.clearRetainingCapacity();
                continue;
            }
            if (line.items.len >= std.fs.max_path_bytes) return error.ResultLineTooLong;
            try line.append(allocator, byte);
        }
    }
    if (line.items.len != 0) {
        summary.count += 1;
        if (summary.files.items.len < 100)
            try summary.files.append(allocator, try allocator.dupe(u8, line.items));
    }
    summary.truncated = summary.truncated or summary.count > summary.files.items.len;
    return summary;
}

fn renderSummary(allocator: std.mem.Allocator, summary: CaptureSummary) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"filenames\":[");
    for (summary.files.items, 0..) |file, index| {
        if (index > 0) try out.append(allocator, ',');
        try util_json.serializeString(file, &out, allocator);
    }
    try out.appendSlice(allocator, "],\"numFiles\":");
    var number: [32]u8 = undefined;
    try out.appendSlice(allocator, try std.fmt.bufPrint(&number, "{d}", .{summary.count}));
    try out.appendSlice(allocator, ",\"truncated\":");
    try out.appendSlice(allocator, if (summary.truncated) "true" else "false");
    try out.appendSlice(allocator, ",\"durationMs\":0}");
    return out.toOwnedSlice(allocator);
}

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const pattern = common.extractJsonArg(args, "pattern") orelse return error.MissingPattern;
    const path_raw = common.extractJsonArg(args, "path") orelse ".";
    if (pattern.len == 0) return error.EmptyPattern;
    // 归一化(展开 ~、折叠、查 traversal)。替代旧 validateNoTraversal。
    const path = try path_mod.normalizeChecked(allocator, path_raw, .{
        .home = ctx.home_dir,
        .base_dir = ctx.cwd_abs,
        .resolve_relative = ctx.resolve_relative_paths,
    });
    defer allocator.free(path);
    // 存在性检查:--no-messages 会把"路径不存在"静默成空结果 → 先拦给明确错误。
    _ = read_state.statPath(path) catch {
        common.setErrorDetail(ctx.error_detail, allocator, "path not found: '{s}' (用绝对路径或 ~/...?)", .{path});
        return error.PathNotFound;
    };

    const rg_path = try toolchain.ripgrepPath();

    const pattern_z = try allocator.dupeZ(u8, pattern);
    defer allocator.free(pattern_z);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var argv = [_]?[*:0]const u8{
        rg_path.ptr,
        "--files",
        "--no-messages",
        "--glob",
        pattern_z.ptr,
        path_z.ptr,
        null,
    };
    // rg 退出语义:0=有结果,1=无匹配(合法空),>=2/信号死=真实故障。旧版只收
    // stdout 忽略退出码,rg 在沙箱内 dyld 加载失败会被静默当成"零文件"——
    // 假空结果比报错危险(模型会当成"目录为空"下结论)。fail loud。
    const spawned = try common.spawnCaptureWithStderrTimed(
        argv[0..argv.len],
        allocator,
        ctx.abort,
        0,
        ctx.spawn_tick_fn,
        common.MAX_SPAWN_CAPTURE_BYTES,
        null,
    );
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
        return error.GlobExecFailed;
    }
    const raw = spawned.stdout;
    defer allocator.free(raw);

    var files = std.ArrayList([]const u8).empty;
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, raw, cursor, '\n')) |nl| {
        if (nl > cursor) {
            const line = raw[cursor..nl];
            try files.append(allocator, try allocator.dupe(u8, line));
        }
        cursor = nl + 1;
    }

    const num = files.items.len;
    const truncated = num > 100;
    const display: usize = if (truncated) 100 else num;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"filenames\":[");
    for (files.items[0..display], 0..) |f, i| {
        if (i > 0) try out.append(allocator, ',');
        try util_json.serializeString(f, &out, allocator);
    }
    try out.appendSlice(allocator, "],\"numFiles\":");
    var num_buf: [32]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{num}) catch return error.OutOfMemory;
    try out.appendSlice(allocator, num_str);
    try out.appendSlice(allocator, ",\"truncated\":");
    try out.appendSlice(allocator, if (truncated) "true" else "false");
    try out.appendSlice(allocator, ",\"durationMs\":0}");

    return try out.toOwnedSlice(allocator);
}

fn testCtx() ToolContext {
    return ToolContext.simple(std.testing.allocator);
}

test "GlobTool missing pattern" {
    const ctx = testCtx();
    try std.testing.expectError(error.MissingPattern, execute(&ctx, "{\"path\":\".\"}"));
}

test "GlobTool path traversal blocked" {
    const ctx = testCtx();
    try std.testing.expectError(error.PathTraversal, execute(&ctx, "{\"pattern\":\"*.txt\",\"path\":\"../..\"}"));
}

test "GlobTool returns valid json" {
    const ctx = testCtx();
    var dbuf: [512]u8 = undefined;
    const dir = tt.path(&dbuf, "."); // per-pid 临时目录(可移植,替 /tmp)
    const json = try std.fmt.allocPrint(std.testing.allocator, "{{\"pattern\":\"*\",\"path\":\"{s}\"}}", .{dir});
    defer std.testing.allocator.free(json);
    const result = try execute(&ctx, json);
    defer std.testing.allocator.free(result);
    try std.testing.expect(result[0] == '{');
    try std.testing.expect(result[result.len - 1] == '}');
    try std.testing.expect(std.mem.indexOf(u8, result, "\"filenames\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"numFiles\":") != null);
}

test "GlobTool brace pattern (*.{ts,tsx})" {
    const ctx = testCtx();
    // 先造 2 个 .ts / .tsx，1 个 .txt(可移植临时目录)
    var b1: [512]u8 = undefined;
    var b2: [512]u8 = undefined;
    var b3: [512]u8 = undefined;
    var bd: [512]u8 = undefined;
    const ts_path = tt.path(&b1, "cc-zig-glob-brace-a.ts");
    const tsx_path = tt.path(&b2, "cc-zig-glob-brace-a.tsx");
    const txt_path = tt.path(&b3, "cc-zig-glob-brace-a.txt");
    const dir = tt.path(&bd, ".");
    for ([_][:0]const u8{ ts_path, tsx_path, txt_path }) |p| {
        const fd = pfs.open(p.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        _ = pfs.write(fd, "x\n");
        _ = pfs.close(fd);
    }
    defer pfs.unlinkPath(ts_path.ptr) catch {};
    defer pfs.unlinkPath(tsx_path.ptr) catch {};
    defer pfs.unlinkPath(txt_path.ptr) catch {};

    const json = try std.fmt.allocPrint(std.testing.allocator, "{{\"pattern\":\"cc-zig-glob-brace-*.{{ts,tsx}}\",\"path\":\"{s}\"}}", .{dir});
    defer std.testing.allocator.free(json);
    const result = try execute(&ctx, json);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "cc-zig-glob-brace-a.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "cc-zig-glob-brace-a.tsx") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "cc-zig-glob-brace-a.txt") == null);
}
