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
    project_rule_blocked,
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
    required_first_pending,
    other,

    pub fn name(self: Code) []const u8 {
        return switch (self) {
            .not_read => "not_read",
            .stale_file => "stale_file",
            .permission_denied => "permission_denied",
            .dangerous_command => "dangerous_command",
            .project_rule_blocked => "project_rule_blocked",
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
            .required_first_pending => "required_first_pending",
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

    fn writeJson(self: *const ToolError, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"error\":{\"code\":\"");
        try writer.writeAll(self.code.name());
        try writer.writeAll("\",\"category\":\"");
        try writer.writeAll(self.category.name());
        try writer.writeAll("\",\"detail\":");
        try std.json.Stringify.encodeJsonString(self.detail, .{}, writer);
        try writer.print(",\"recoverable\":{s}}}}}", .{if (self.recoverable) "true" else "false"});
    }

    /// 序列化成 JSON 字符串（owned）。形如：
    ///   {"error":{"code":"not_read","category":"user_error","detail":"...","recoverable":true}}
    pub fn toJson(self: *const ToolError, allocator: std.mem.Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try self.writeJson(&aw.writer);
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
    .{ .name = "ToolPolicyDenied", .code = .permission_denied, .category = .safety, .recoverable = false },
    .{ .name = "PreToolUseBlocked", .code = .permission_denied, .category = .safety, .recoverable = false },
    .{ .name = "ProjectRuleBlocked", .code = .project_rule_blocked, .category = .safety, .recoverable = false },
    .{ .name = "ProjectRulesRequireSynchronousExecution", .code = .project_rule_blocked, .category = .safety, .recoverable = false },
    .{ .name = "ProjectRulesRequireSynchronousAgent", .code = .project_rule_blocked, .category = .safety, .recoverable = false },
    .{ .name = "ProjectExactEditNotAuthorized", .code = .project_rule_blocked, .category = .safety, .recoverable = false },
    .{ .name = "ProjectExactEditNativeUnavailable", .code = .project_rule_blocked, .category = .safety, .recoverable = false },
    .{ .name = "ExactRecoverySourceChanged", .code = .stale_file, .category = .user_error, .recoverable = true },
    .{ .name = "ExactRecoveryTargetUnavailable", .code = .file_not_found, .category = .user_error, .recoverable = true },
    .{ .name = "ExactRecoveryReplaceAllForbidden", .code = .invalid_args, .category = .user_error, .recoverable = true },
    .{ .name = "UnknownTool", .code = .unknown_tool, .category = .user_error, .recoverable = true },
    .{ .name = "NoToolMatch", .code = .unknown_tool, .category = .user_error, .recoverable = true },
    .{ .name = "FileNotFound", .code = .file_not_found, .category = .user_error, .recoverable = true },
    .{ .name = "MultipleMatches", .code = .multiple_matches, .category = .user_error, .recoverable = true },
    .{ .name = "StringNotFound", .code = .string_not_found, .category = .user_error, .recoverable = true },
    .{ .name = "ContextNotFound", .code = .string_not_found, .category = .user_error, .recoverable = true },
    .{ .name = "OldLinesNotFound", .code = .string_not_found, .category = .user_error, .recoverable = true },
    .{ .name = "NoOpEdit", .code = .no_op_edit, .category = .user_error, .recoverable = true },
    .{ .name = "RequiredFirstPending", .code = .required_first_pending, .category = .user_error, .recoverable = true },
    // invalid_args 的 error 名字比较多（MissingPath/EmptyPath/InvalidOffset 等），
    // 先列 code=invalid_args 的部分，查询时用 hasAny 辅助而非表中枚举全部
};

/// invalid_args 类别的 error 前缀集合（精简维护）。
/// 改成"以任一 prefix 开头"的匹配 —— Missing* / Empty* / Invalid* 都归入 invalid_args。
const INVALID_ARGS_PREFIXES = [_][]const u8{ "Missing", "Empty", "Invalid" };

const Classification = struct {
    code: Code,
    category: Category,
    recoverable: bool,
};

fn classifyErrorName(err_name: []const u8) Classification {
    for (ERROR_MAP) |spec| {
        if (std.mem.eql(u8, err_name, spec.name)) return .{
            .code = spec.code,
            .category = spec.category,
            .recoverable = spec.recoverable,
        };
    }
    for (INVALID_ARGS_PREFIXES) |prefix| {
        if (std.mem.startsWith(u8, err_name, prefix)) return .{
            .code = .invalid_args,
            .category = .user_error,
            .recoverable = true,
        };
    }
    return .{ .code = .other, .category = .system_error, .recoverable = true };
}

pub fn fromErrorName(err_name: []const u8, detail_owned: []const u8) ToolError {
    const classification = classifyErrorName(err_name);
    return .{
        .code = classification.code,
        .category = classification.category,
        .detail = detail_owned,
        .recoverable = classification.recoverable,
    };
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

pub const PROJECT_RULE_RECOVERY_SCHEMA = "metacodes-project-rule-recovery-v1";

/// Render the task-level recovery contract selected by the fixed Lean kernel.
/// `recoverable` remains false for the denied Write itself: only the distinct
/// Edit path is recoverable, and it must pass the normal gate again.
/// State-aware no-recovery block detail. The one field-adjudicated false
/// intervention (mkdocs `docs/index.md -> README.md`) cost a 12-turn
/// confusion spiral mostly because the bare message carried nothing
/// actionable; the target state is host-observed and task-agnostic, so say
/// it.
pub fn projectRuleBlockedJson(
    tool: []const u8,
    target_state: @import("../tools/observation.zig").FileTargetState,
    allocator: std.mem.Allocator,
) ![]u8 {
    const hint: []const u8 = switch (target_state) {
        .other_existing => " The target path exists but is not a regular file — it is likely a symlink or a directory. Check with `ls -la <path>`; if it is a symlink, read and edit the resolved real path directly instead of retrying this call.",
        .unavailable => " The target path could not be observed (ambiguous filesystem state); verify the path exists and is accessible before retrying a different approach.",
        .missing, .regular_existing, .unobserved => "",
    };
    return errToJsonState(tool, hint, allocator);
}

fn errToJsonState(tool: []const u8, hint: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const detail = try std.fmt.allocPrint(
        allocator,
        "Project formal rule blocked tool '{s}' before dispatch.{s}",
        .{ tool, hint },
    );
    defer allocator.free(detail);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"error\":{\"code\":\"project_rule_blocked\",\"category\":\"safety\",\"detail\":");
    try std.json.Stringify.encodeJsonString(detail, .{}, &aw.writer);
    try aw.writer.writeAll(",\"recoverable\":false}}");
    return aw.toOwnedSlice();
}

pub fn projectRuleExactEditBlockedJson(
    tool: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    const detail = try std.fmt.allocPrint(
        allocator,
        "Project formal rule blocked tool '{s}' before dispatch. Do not retry the blocked tool; follow the recovery contract.",
        .{tool},
    );
    defer allocator.free(detail);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"error\":{\"code\":\"project_rule_blocked\",\"category\":\"safety\",\"detail\":");
    try std.json.Stringify.encodeJsonString(detail, .{}, &aw.writer);
    try aw.writer.print(
        ",\"recoverable\":false,\"recovery\":{{\"schema_version\":\"{s}\",\"task_recoverable\":true,\"action\":\"edit_existing_file_exact\",\"requirements\":[",
        .{PROJECT_RULE_RECOVERY_SCHEMA},
    );
    try std.json.Stringify.encodeJsonString(
        "Use Edit on the existing regular file; this is not permission to retry Write.",
        .{},
        &aw.writer,
    );
    try aw.writer.writeByte(',');
    try std.json.Stringify.encodeJsonString(
        "For whole-file replacement, old_string must match the current file exactly, including whether it ends with a newline.",
        .{},
        &aw.writer,
    );
    try aw.writer.writeByte(',');
    try std.json.Stringify.encodeJsonString(
        "Reuse the blocked Write content as new_string exactly; do not add or remove a terminal newline.",
        .{},
        &aw.writer,
    );
    try aw.writer.writeByte(',');
    try std.json.Stringify.encodeJsonString(
        "Read or otherwise reobserve the final file before reporting completion.",
        .{},
        &aw.writer,
    );
    try aw.writer.writeAll("]}}}");
    return try aw.toOwnedSlice();
}

/// Serialize a borrowed external detail only if the complete encoded JSON fits
/// `max_bytes`. The first pass writes into a fixed-buffer discarding writer, so
/// hostile escaping expansion is measured without allocating. The second pass
/// allocates exactly the measured size; `null` means invalid UTF-8 or over cap.
pub fn errorToJsonCapped(
    err_name: []const u8,
    detail: []const u8,
    max_bytes: usize,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!?[]u8 {
    if (!std.unicode.utf8ValidateSlice(detail)) return null;
    const classification = classifyErrorName(err_name);
    const borrowed = ToolError{
        .code = classification.code,
        .category = classification.category,
        .detail = detail,
        .recoverable = classification.recoverable,
    };

    var count_buffer: [256]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&count_buffer);
    borrowed.writeJson(&discarding.writer) catch unreachable;
    const encoded_len_u64 = discarding.fullCount();
    if (encoded_len_u64 > max_bytes or encoded_len_u64 > std.math.maxInt(usize)) return null;
    const encoded_len: usize = @intCast(encoded_len_u64);

    var aw = try std.Io.Writer.Allocating.initCapacity(allocator, encoded_len);
    defer aw.deinit();
    borrowed.writeJson(&aw.writer) catch return error.OutOfMemory;
    const encoded = try aw.toOwnedSlice();
    std.debug.assert(encoded.len == encoded_len);
    return encoded;
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

test "capped serializer preserves external detail and rejects escaping expansion before allocation" {
    const allocator = std.testing.allocator;
    const detail = "quote=\" slash=\\ line=\n nul=\x00 end";
    const encoded = (try errorToJsonCapped("HostToolFailed", detail, 1024 * 1024, allocator)).?;
    defer allocator.free(encoded);
    try std.testing.expect(encoded.len <= 1024 * 1024);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    const decoded = parsed.value.object.get("error").?.object.get("detail").?.string;
    try std.testing.expectEqualStrings(detail, decoded);

    // 200 KiB of NUL expands to roughly 1.2 MiB (`\\u0000` each). A failing
    // output allocator proves the rejection path performs no allocation.
    const hostile = try allocator.alloc(u8, 200 * 1024);
    defer allocator.free(hostile);
    @memset(hostile, 0);
    var no_alloc = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expect((try errorToJsonCapped("HostToolFailed", hostile, 1024 * 1024, no_alloc.allocator())) == null);

    var fail_small = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, errorToJsonCapped("HostToolFailed", "small", 1024 * 1024, fail_small.allocator()));
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

    const d4 = try a.dupe(u8, "patch context generated by the model does not match");
    const e4 = fromErrorName("OldLinesNotFound", d4);
    defer e4.deinit(a);
    try std.testing.expect(e4.code == .string_not_found);
    try std.testing.expect(e4.category == .user_error);
    try std.testing.expect(e4.recoverable);

    const d5 = try a.dupe(u8, "deferred tool was not visible");
    const e5 = fromErrorName("NoToolMatch", d5);
    defer e5.deinit(a);
    try std.testing.expect(e5.code == .unknown_tool);
    try std.testing.expect(e5.category == .user_error);
    try std.testing.expect(e5.recoverable);

    const d6 = try a.dupe(u8, "blocked by configured hook");
    const e6 = fromErrorName("PreToolUseBlocked", d6);
    defer e6.deinit(a);
    try std.testing.expect(e6.code == .permission_denied);
    try std.testing.expect(e6.category == .safety);
    try std.testing.expect(!e6.recoverable);
}

test "errorToJson oneliner" {
    const a = std.testing.allocator;
    const j = try errorToJson("NotRead", "path={s}", .{"src/foo.zig"}, a);
    defer a.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"code\":\"not_read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "src/foo.zig") != null);
}

test "project rule exact edit recovery distinguishes denied action from task recovery" {
    const a = std.testing.allocator;
    const encoded = try projectRuleExactEditBlockedJson("Write", a);
    defer a.free(encoded);
    const Parsed = struct {
        @"error": struct {
            code: []const u8,
            category: []const u8,
            detail: []const u8,
            recoverable: bool,
            recovery: struct {
                schema_version: []const u8,
                task_recoverable: bool,
                action: []const u8,
                requirements: []const []const u8,
            },
        },
    };
    var parsed = try std.json.parseFromSlice(Parsed, a, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("project_rule_blocked", parsed.value.@"error".code);
    try std.testing.expect(!parsed.value.@"error".recoverable);
    try std.testing.expect(parsed.value.@"error".recovery.task_recoverable);
    try std.testing.expectEqualStrings(
        "edit_existing_file_exact",
        parsed.value.@"error".recovery.action,
    );
    try std.testing.expectEqual(@as(usize, 4), parsed.value.@"error".recovery.requirements.len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        parsed.value.@"error".recovery.requirements[1],
        "ends with a newline",
    ) != null);
}

test "no-recovery block detail names a non-regular target actionably" {
    const a = std.testing.allocator;
    const other = try projectRuleBlockedJson("Edit", .other_existing, a);
    defer a.free(other);
    try std.testing.expect(std.mem.indexOf(u8, other, "symlink") != null);
    try std.testing.expect(std.mem.indexOf(u8, other, "resolved real path") != null);
    const plain = try projectRuleBlockedJson("Edit", .regular_existing, a);
    defer a.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "symlink") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "project_rule_blocked") != null);
}
