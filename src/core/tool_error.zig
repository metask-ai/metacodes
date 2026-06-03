//! 结构化工具错误：让 tool_result 里的错误信息包含 code/category，便于模型自纠。
//!
//! 输出格式（tool_result.content 会用这个 JSON）：
//!   {"error":{"code":"not_read","category":"user_error","detail":"...","recoverable":true}}
//!
//! 模型 prompt 可以学"遇到 code=not_read 就先 Read"这种规则，比纯字符串 "tool error: xxx"
//! 更可操作。
//!
//! 用法：
//!   const e = ToolError.notRead("src/foo.zig");
//!   defer e.deinit(allocator);
//!   const json_str = try e.toJson(allocator);  // owned

const std = @import("std");

pub const Code = enum {
    not_read,
    stale_file,
    permission_denied,
    dangerous_command,
    timeout,
    aborted,
    spawn_failed,
    path_traversal,
    invalid_args,
    unknown_tool,
    io_error,
    file_not_found,
    multiple_matches,
    string_not_found,
    no_op_edit,
    other,

    pub fn name(self: Code) []const u8 {
        return switch (self) {
            .not_read => "not_read",
            .stale_file => "stale_file",
            .permission_denied => "permission_denied",
            .dangerous_command => "dangerous_command",
            .timeout => "timeout",
            .aborted => "aborted",
            .spawn_failed => "spawn_failed",
            .path_traversal => "path_traversal",
            .invalid_args => "invalid_args",
            .unknown_tool => "unknown_tool",
            .io_error => "io_error",
            .file_not_found => "file_not_found",
            .multiple_matches => "multiple_matches",
            .string_not_found => "string_not_found",
            .no_op_edit => "no_op_edit",
            .other => "other",
        };
    }
};

pub const Category = enum {
    user_error, // 模型可以纠正
    system_error, // 环境/机器问题，重试可能有用
    safety, // 规则/沙箱拒绝，重试无用

    pub fn name(self: Category) []const u8 {
        return switch (self) {
            .user_error => "user_error",
            .system_error => "system_error",
            .safety => "safety",
        };
    }
};

pub const ToolError = struct {
    code: Code,
    category: Category,
    detail: []const u8, // owned
    recoverable: bool,

    pub fn init(code: Code, category: Category, detail_owned: []const u8, recoverable: bool) ToolError {
        return .{ .code = code, .category = category, .detail = detail_owned, .recoverable = recoverable };
    }

    pub fn deinit(self: *const ToolError, allocator: std.mem.Allocator) void {
        allocator.free(self.detail);
    }

    /// 序列化成 JSON 字符串（owned）。形如：
    ///   {"error":{"code":"not_read","category":"user_error","detail":"...","recoverable":true}}
    pub fn toJson(self: *const ToolError, allocator: std.mem.Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try aw.writer.writeAll("{\"error\":{\"code\":\"");
        try aw.writer.writeAll(self.code.name());
        try aw.writer.writeAll("\",\"category\":\"");
        try aw.writer.writeAll(self.category.name());
        try aw.writer.writeAll("\",\"detail\":");
        try std.json.Stringify.encodeJsonString(self.detail, .{}, &aw.writer);
        try aw.writer.print(",\"recoverable\":{s}}}}}", .{if (self.recoverable) "true" else "false"});
        return try aw.toOwnedSlice();
    }
};

/// 把 Zig error name 映射到 ToolError。各工具的典型错误都走这里。
/// 未匹配的走 .other。detail 由调用方生成后传入（owned）。
/// error name → ToolError 的映射表。加新错误只改这里，不改 fromErrorName 函数体。
const ErrorSpec = struct {
    name: []const u8,
    code: Code,
    category: Category,
    recoverable: bool,
};

const ERROR_MAP = [_]ErrorSpec{
    .{ .name = "NotRead", .code = .not_read, .category = .user_error, .recoverable = true },
    .{ .name = "StaleFile", .code = .stale_file, .category = .user_error, .recoverable = true },
    .{ .name = "Timeout", .code = .timeout, .category = .system_error, .recoverable = true },
    .{ .name = "Aborted", .code = .aborted, .category = .system_error, .recoverable = false },
    .{ .name = "SpawnError", .code = .spawn_failed, .category = .system_error, .recoverable = true },
    .{ .name = "PathTraversal", .code = .path_traversal, .category = .safety, .recoverable = false },
    .{ .name = "DangerousCommand", .code = .dangerous_command, .category = .safety, .recoverable = false },
    .{ .name = "PermissionDenied", .code = .permission_denied, .category = .safety, .recoverable = false },
    .{ .name = "UnknownTool", .code = .unknown_tool, .category = .user_error, .recoverable = true },
    .{ .name = "FileNotFound", .code = .file_not_found, .category = .user_error, .recoverable = true },
    .{ .name = "MultipleMatches", .code = .multiple_matches, .category = .user_error, .recoverable = true },
    .{ .name = "StringNotFound", .code = .string_not_found, .category = .user_error, .recoverable = true },
    .{ .name = "NoOpEdit", .code = .no_op_edit, .category = .user_error, .recoverable = true },
    // invalid_args 的 error 名字比较多（MissingPath/EmptyPath/InvalidOffset 等），
    // 先列 code=invalid_args 的部分，查询时用 hasAny 辅助而非表中枚举全部
};

/// invalid_args 类别的 error 前缀集合（精简维护）。
/// 改成"以任一 prefix 开头"的匹配 —— Missing* / Empty* / Invalid* 都归入 invalid_args。
const INVALID_ARGS_PREFIXES = [_][]const u8{ "Missing", "Empty", "Invalid" };

pub fn fromErrorName(err_name: []const u8, detail_owned: []const u8) ToolError {
    // 精确匹配 ERROR_MAP
    for (ERROR_MAP) |spec| {
        if (std.mem.eql(u8, err_name, spec.name)) {
            return .{
                .code = spec.code,
                .category = spec.category,
                .detail = detail_owned,
                .recoverable = spec.recoverable,
            };
        }
    }
    // 前缀匹配 invalid_args
    for (INVALID_ARGS_PREFIXES) |prefix| {
        if (std.mem.startsWith(u8, err_name, prefix)) {
            return .{
                .code = .invalid_args,
                .category = .user_error,
                .detail = detail_owned,
                .recoverable = true,
            };
        }
    }
    // fallback
    return .{ .code = .other, .category = .system_error, .detail = detail_owned, .recoverable = true };
}

/// 便利：给 agent_loop 用——从 Zig error 直接生成 JSON。allocator 负责 detail 和返回值。
/// detail_fmt 必须是 comptime（std.fmt.allocPrint 要求）。
///
/// 所有权路径：
///   1. allocPrint 分配 detail（owned by 本函数）
///   2. fromErrorName 立刻接管 detail 所有权存到 e.detail
///   3. defer e.deinit 在任何路径（成功 / toJson 失败）释放 detail
///
/// 不要加 `errdefer free(detail)`：第 2 步之后 detail 已转移；errdefer + defer 会 double-free。
pub fn errorToJson(err_name: []const u8, comptime detail_fmt: []const u8, detail_args: anytype, allocator: std.mem.Allocator) ![]u8 {
    const detail = try std.fmt.allocPrint(allocator, detail_fmt, detail_args);
    var e = fromErrorName(err_name, detail);
    defer e.deinit(allocator);
    return try e.toJson(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "toJson basic" {
    const a = std.testing.allocator;
    const detail = try a.dupe(u8, "file src/x.zig not read");
    const e = ToolError.init(.not_read, .user_error, detail, true);
    defer e.deinit(a);
    const j = try e.toJson(a);
    defer a.free(j);
    try std.testing.expectEqualStrings(
        "{\"error\":{\"code\":\"not_read\",\"category\":\"user_error\",\"detail\":\"file src/x.zig not read\",\"recoverable\":true}}",
        j,
    );
}

test "fromErrorName maps common errors" {
    const a = std.testing.allocator;
    const d1 = try a.dupe(u8, "x");
    const e1 = fromErrorName("NotRead", d1);
    defer e1.deinit(a);
    try std.testing.expect(e1.code == .not_read);

    const d2 = try a.dupe(u8, "y");
    const e2 = fromErrorName("DangerousCommand", d2);
    defer e2.deinit(a);
    try std.testing.expect(e2.category == .safety);
    try std.testing.expect(!e2.recoverable);

    const d3 = try a.dupe(u8, "z");
    const e3 = fromErrorName("UnknownFoo", d3);
    defer e3.deinit(a);
    try std.testing.expect(e3.code == .other);
}

test "errorToJson oneliner" {
    const a = std.testing.allocator;
    const j = try errorToJson("NotRead", "path={s}", .{"src/foo.zig"}, a);
    defer a.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"code\":\"not_read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "src/foo.zig") != null);
}
