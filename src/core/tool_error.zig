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
const util_json = @import("../util/json.zig");

pub const Code = enum {
    not_read,
    stale_file,
    permission_denied,
    dangerous_command,
    project_rule_blocked,
    timeout,
    aborted,
    spawn_failed,
    /// 会话工作目录进不去了(改名/删除):platform/process 的子进程报告通道认定的
    /// chdir 失败。换命令重试无意义 —— 每次 Bash 都在这个目录里起。
    working_dir_unavailable,
    path_traversal,
    invalid_args,
    unknown_tool,
    io_error,
    file_not_found,
    multiple_matches,
    string_not_found,
    no_op_edit,
    required_first_pending,
    /// 当前 (provider, model) 没有这项能力(如非 vision 模型读图、本 session 没连 MCP)。
    /// 换模型/接上依赖后同一调用可能成功,所以它不是 invalid_args,也不是 safety。
    capability_unsupported,
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
            .working_dir_unavailable => "working_dir_unavailable",
            .path_traversal => "path_traversal",
            .invalid_args => "invalid_args",
            .unknown_tool => "unknown_tool",
            .io_error => "io_error",
            .file_not_found => "file_not_found",
            .multiple_matches => "multiple_matches",
            .string_not_found => "string_not_found",
            .no_op_edit => "no_op_edit",
            .required_first_pending => "required_first_pending",
            .capability_unsupported => "capability_unsupported",
            .other => "other",
        };
    }
};

pub const Category = enum {
    user_error, // 模型可以纠正
    system_error, // 环境/机器问题，重试可能有用
    safety, // 规则/沙箱拒绝，重试无用
    /// 用户或宿主中断了这次调用(Esc/Ctrl+C/前端 Stop)。既不是模型的错,也不是环境坏了:
    /// 用户重新发起时同一调用可以再跑。它**不是** system_error——2026-09-23 实录里一次 Esc
    /// 中断被 environment_fault 熔断当成"环境故障 1/3"报给用户,就是因为它曾挂在 system_error 下。
    interrupted,

    pub fn name(self: Category) []const u8 {
        return switch (self) {
            .user_error => "user_error",
            .system_error => "system_error",
            .safety => "safety",
            .interrupted => "interrupted",
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
        try util_json.writeJsonString(writer, self.detail);
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
    // 用户/宿主中断:不是环境故障(不进 environment_fault 计数),用户再发一次即可重跑。
    .{ .name = "Aborted", .code = .aborted, .category = .interrupted, .recoverable = true },
    .{ .name = "SpawnError", .code = .spawn_failed, .category = .system_error, .recoverable = true },
    // 子进程自己交代的启动失败(platform/process 报告通道):cwd 进不去 / 程序起不来。
    // 同一调用换个命令重试没有意义,所以不可恢复;它们是环境故障,不是模型的错。
    .{ .name = "WorkingDirectoryUnavailable", .code = .working_dir_unavailable, .category = .system_error, .recoverable = false },
    .{ .name = "ChildChdirFailed", .code = .working_dir_unavailable, .category = .system_error, .recoverable = false },
    .{ .name = "ChildExecFailed", .code = .spawn_failed, .category = .system_error, .recoverable = false },
    // A sealed result could not be published at the batch commit boundary (#45): a storage problem, not the tool's fault; retrying the call may succeed.
    .{ .name = "ArtifactPublishFailed", .code = .io_error, .category = .system_error, .recoverable = true },
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
    // 图片读取:非 vision 模型的门控(换模型即可成功 → recoverable);超限是输入问题。
    .{ .name = "ImageInputUnsupported", .code = .capability_unsupported, .category = .system_error, .recoverable = true },
    .{ .name = "ImageTooLarge", .code = .invalid_args, .category = .user_error, .recoverable = true },
    // MCP:本 session 一个 server 都没连 → 换参数无用;server 名不存在 → 换名可成功。
    .{ .name = "NoMcpSessions", .code = .capability_unsupported, .category = .system_error, .recoverable = false },
    .{ .name = "McpServerNotFound", .code = .invalid_args, .category = .user_error, .recoverable = true },
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
    try util_json.writeJsonString(&aw.writer, detail);
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
    try util_json.writeJsonString(&aw.writer, detail);
    try aw.writer.print(
        ",\"recoverable\":false,\"recovery\":{{\"schema_version\":\"{s}\",\"task_recoverable\":true,\"action\":\"edit_existing_file_exact\",\"requirements\":[",
        .{PROJECT_RULE_RECOVERY_SCHEMA},
    );
    try util_json.writeJsonString(&aw.writer, "Use Edit on the existing regular file; this is not permission to retry Write.");
    try aw.writer.writeByte(',');
    try util_json.writeJsonString(&aw.writer, "For whole-file replacement, old_string must match the current file exactly, including whether it ends with a newline.");
    try aw.writer.writeByte(',');
    try util_json.writeJsonString(&aw.writer, "Reuse the blocked Write content as new_string exactly; do not add or remove a terminal newline.");
    try aw.writer.writeByte(',');
    try util_json.writeJsonString(&aw.writer, "Read or otherwise reobserve the final file before reporting completion.");
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

test "fromErrorName maps image and MCP capability errors" {
    const a = std.testing.allocator;
    const img = fromErrorName("ImageInputUnsupported", try a.dupe(u8, "d"));
    defer img.deinit(a);
    try std.testing.expectEqual(Code.capability_unsupported, img.code);
    try std.testing.expectEqual(Category.system_error, img.category);
    try std.testing.expect(img.recoverable);
    try std.testing.expectEqualStrings("capability_unsupported", img.code.name());
    const big = fromErrorName("ImageTooLarge", try a.dupe(u8, "d"));
    defer big.deinit(a);
    try std.testing.expectEqual(Code.invalid_args, big.code);
    const none = fromErrorName("NoMcpSessions", try a.dupe(u8, "d"));
    defer none.deinit(a);
    try std.testing.expectEqual(Code.capability_unsupported, none.code);
    try std.testing.expect(!none.recoverable);
    const missing = fromErrorName("McpServerNotFound", try a.dupe(u8, "d"));
    defer missing.deinit(a);
    try std.testing.expectEqual(Code.invalid_args, missing.code);
    try std.testing.expect(missing.recoverable);
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

test "Aborted 是用户/宿主中断:interrupted 类别、可恢复,与环境故障(system_error+不可恢复)分开" {
    const a = std.testing.allocator;
    const e = fromErrorName("Aborted", try a.dupe(u8, "Bash failed with Aborted"));
    defer e.deinit(a);
    try std.testing.expectEqual(Code.aborted, e.code);
    try std.testing.expectEqual(Category.interrupted, e.category);
    try std.testing.expect(e.recoverable);
    const json = try e.toJson(a);
    defer a.free(json);
    try std.testing.expectEqualStrings("{\"error\":{\"code\":\"aborted\",\"category\":\"interrupted\",\"detail\":\"Bash failed with Aborted\",\"recoverable\":true}}", json);
}

test "spawn 报告通道的错误名:环境故障,不可恢复,带专属 code" {
    const a = std.testing.allocator;
    const wd = fromErrorName("WorkingDirectoryUnavailable", try a.dupe(u8, "gone"));
    defer wd.deinit(a);
    try std.testing.expectEqual(Code.working_dir_unavailable, wd.code);
    try std.testing.expectEqual(Category.system_error, wd.category);
    try std.testing.expect(!wd.recoverable);
    const json = try wd.toJson(a);
    defer a.free(json);
    try std.testing.expectEqualStrings("{\"error\":{\"code\":\"working_dir_unavailable\",\"category\":\"system_error\",\"detail\":\"gone\",\"recoverable\":false}}", json);
    const chdir = fromErrorName("ChildChdirFailed", try a.dupe(u8, "x"));
    defer chdir.deinit(a);
    try std.testing.expectEqual(Code.working_dir_unavailable, chdir.code);
    const exec = fromErrorName("ChildExecFailed", try a.dupe(u8, "x"));
    defer exec.deinit(a);
    try std.testing.expectEqual(Code.spawn_failed, exec.code);
    try std.testing.expect(!exec.recoverable);
    // 资源性 spawn 失败(fork/pipe)仍然可重试:与子进程报告的确定性失败区分开。
    const res = fromErrorName("SpawnError", try a.dupe(u8, "x"));
    defer res.deinit(a);
    try std.testing.expect(res.recoverable);
}
