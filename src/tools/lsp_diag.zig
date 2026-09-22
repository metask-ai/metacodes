//! Edit/Write/ApplyPatch/NotebookEdit 共享的 LSP 被动诊断 hook(Y2 Step3)。
//! 写前 snapshot baseline、写后取 delta 诊断附进工具结果。ctx.lsp==null(`--no-lsp` 或调用方
//! 没装配)→ 全 no-op。
//! best-effort:任何失败绝不阻断写入(graceful degradation)。
const std = @import("std");
const pfs = @import("platform").fs;
const ToolContext = @import("context.zig").ToolContext;
const log = @import("../util/log.zig");
const util_json = @import("../util/json.zig");

/// 解析 file_path 为绝对路径(LSP 需绝对做 workspace 检测/URI)。写进 buf(须 max_path_bytes)。
pub fn absPath(file_path: []const u8, buf: []u8) ?[]const u8 {
    if (std.fs.path.isAbsolute(file_path)) {
        if (file_path.len > buf.len) return null;
        @memcpy(buf[0..file_path.len], file_path);
        return buf[0..file_path.len];
    }
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = pfs.getCwd(&cwd_buf) orelse return null; // 哨兵与 Windows 宽字符 cwd 都在 pfs 里
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ cwd, file_path }) catch null;
}

/// 写前:用**旧内容** snapshot baseline(delta 基准)。ctx.lsp==null → no-op。
pub fn snapshotBaseline(ctx: *const ToolContext, file_path: []const u8, old_content: []const u8) void {
    const svc = ctx.lsp orelse return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ap = absPath(file_path, &buf) orelse return;
    svc.snapshotBaseline(ap, old_content);
}

/// 写后:取**新内容**的 delta 诊断(vs baseline)。owned;无诊断/未开 → 空串。
pub fn getDiagnostics(ctx: *const ToolContext, alloc: std.mem.Allocator, file_path: []const u8, new_content: []const u8) []u8 {
    const svc = ctx.lsp orelse return alloc.dupe(u8, "") catch "";
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ap = absPath(file_path, &buf) orelse return alloc.dupe(u8, "") catch "";
    return svc.getDiagnostics(alloc, ap, new_content);
}

/// 把 delta 诊断附到工具结果 JSON writer(非空才加 `,"lspDiagnostics":"..."`)。
pub fn appendToResult(ctx: *const ToolContext, alloc: std.mem.Allocator, out: anytype, file_path: []const u8, new_content: []const u8) !void {
    if (ctx.lsp == null) return;
    const diag = getDiagnostics(ctx, alloc, file_path, new_content);
    defer alloc.free(diag);
    // M3 可观测性:METACODES_LOG=1 时报告 LSP 是否产出诊断(用户排查"LSP 有没有工作")。
    // 空诊断也 log(区分"没接线/无 server"与"接了但代码没错")。
    if (diag.len > 0) {
        log.info("lsp", "attached {d} chars of diagnostics for {s}", .{ diag.len, file_path });
        try out.writeAll(",\"lspDiagnostics\":");
        try util_json.writeJsonString(out, diag);
    } else {
        log.debug("lsp", "no new diagnostics for {s} (server absent, outside workspace, or code clean)", .{file_path});
    }
}
