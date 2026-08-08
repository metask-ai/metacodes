//! Native pre-dispatch sensors for the bounded project-rule vocabulary.
//!
//! These observations are host facts, not fields copied from model output.
//! They run immediately before the fixed Lean gate at `executeOne`.  Filesystem
//! classification is lstat-style and does not follow the final symlink.  There
//! is still an unavoidable path TOCTOU window between this observation and the
//! tool's later open; this signal claims only what the host observed here.

const std = @import("std");
const pfs = @import("platform").fs;
const common = @import("common.zig");
const ToolContext = @import("context.zig").ToolContext;
const protocol = @import("project_rule_gate.zig");
const project_rule_spec = @import("../core/project_rule_spec.zig");
const path_mod = @import("../util/path.zig");
const util_json = @import("../util/json.zig");

pub fn observePre(
    ctx: *const ToolContext,
    dispatch_id: []const u8,
    tool: []const u8,
    input: []const u8,
) protocol.PreSignal {
    return .{
        .dispatch_id = dispatch_id,
        .tool = tool,
        .input_bytes = input.len,
        .agent_depth = ctx.agent_depth,
        .authoritative = ctx.tool_observation_origin == .authoritative,
        .file_target_state = observeFileTarget(ctx, tool, input),
    };
}

pub fn observeFileTarget(
    ctx: *const ToolContext,
    tool: []const u8,
    input: []const u8,
) project_rule_spec.FileTargetState {
    if (!std.mem.eql(u8, tool, "Write")) return .unobserved;
    const escaped = common.extractJsonArg(input, "file_path") orelse
        common.extractJsonArg(input, "path") orelse return .unavailable;
    const path_unescaped = util_json.unescapeString(escaped, ctx.allocator) catch
        return .unavailable;
    defer ctx.allocator.free(path_unescaped);
    if (path_unescaped.len == 0) return .unavailable;
    const normalized = path_mod.normalizeChecked(ctx.allocator, path_unescaped, .{
        .home = ctx.home_dir,
        .base_dir = ctx.cwd_abs,
        .resolve_relative = ctx.resolve_relative_paths,
    }) catch return .unavailable;
    defer ctx.allocator.free(normalized);
    const path_z = ctx.allocator.dupeZ(u8, normalized) catch return .unavailable;
    defer ctx.allocator.free(path_z);
    return switch (pfs.pathKindNoFollow(path_z.ptr)) {
        .missing => .missing,
        .regular => .regular_existing,
        .other => .other_existing,
        .unavailable => .unavailable,
    };
}

test "project rule Write sensor distinguishes new regular and non-regular targets" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const existing = try std.fmt.allocPrintSentinel(allocator, "{s}/existing.txt", .{root}, 0);
    defer allocator.free(existing);
    const fd = pfs.open(existing.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    try std.testing.expect(fd >= 0);
    pfs.close(fd);
    const missing = try std.fmt.allocPrint(allocator, "{s}/missing.txt", .{root});
    defer allocator.free(missing);
    const dir = try std.fmt.allocPrint(allocator, "{s}", .{root});
    defer allocator.free(dir);
    const existing_input = try std.fmt.allocPrint(allocator, "{{\"file_path\":\"{s}\",\"content\":\"x\"}}", .{existing});
    defer allocator.free(existing_input);
    const missing_input = try std.fmt.allocPrint(allocator, "{{\"file_path\":\"{s}\",\"content\":\"x\"}}", .{missing});
    defer allocator.free(missing_input);
    const dir_input = try std.fmt.allocPrint(allocator, "{{\"file_path\":\"{s}\",\"content\":\"x\"}}", .{dir});
    defer allocator.free(dir_input);
    const ctx = ToolContext.simple(allocator);
    try std.testing.expectEqual(project_rule_spec.FileTargetState.regular_existing, observeFileTarget(&ctx, "Write", existing_input));
    try std.testing.expectEqual(project_rule_spec.FileTargetState.missing, observeFileTarget(&ctx, "Write", missing_input));
    try std.testing.expectEqual(project_rule_spec.FileTargetState.other_existing, observeFileTarget(&ctx, "Write", dir_input));
    try std.testing.expectEqual(project_rule_spec.FileTargetState.unavailable, observeFileTarget(&ctx, "Write", "{}"));
    try std.testing.expectEqual(project_rule_spec.FileTargetState.unobserved, observeFileTarget(&ctx, "Edit", existing_input));
}
