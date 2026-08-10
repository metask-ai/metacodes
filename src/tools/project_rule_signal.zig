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
        .exact_edit_material = observeExactEditMaterial(ctx, tool, input),
    };
}

pub fn observeFileTarget(
    ctx: *const ToolContext,
    tool: []const u8,
    input: []const u8,
) project_rule_spec.FileTargetState {
    if (!std.mem.eql(u8, tool, "Write") and !std.mem.eql(u8, tool, "Edit"))
        return .unobserved;
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

fn observeExactEditMaterial(
    ctx: *const ToolContext,
    tool: []const u8,
    input: []const u8,
) protocol.ExactEditMaterial {
    // Do not advertise an exact-recovery capability that the native platform
    // cannot execute with an atomic final-component no-follow open. The deny
    // rule still blocks the original overwrite; only the recovery direction
    // is unavailable until Windows uses a handle-based reparse-point open.
    if (!pfs.atomic_final_nofollow) return .{};
    const is_write = std.mem.eql(u8, tool, "Write");
    const is_edit = std.mem.eql(u8, tool, "Edit");
    if (!is_write and !is_edit) return .{};
    const escaped_path = common.extractJsonArg(input, "file_path") orelse
        common.extractJsonArg(input, "path") orelse return .{};
    const path = util_json.unescapeString(escaped_path, ctx.allocator) catch return .{};
    defer ctx.allocator.free(path);
    if (path.len == 0) return .{};
    const normalized = path_mod.normalizeChecked(ctx.allocator, path, .{
        .home = ctx.home_dir,
        .base_dir = ctx.cwd_abs,
        .resolve_relative = ctx.resolve_relative_paths,
    }) catch return .{};
    defer ctx.allocator.free(normalized);
    var material = protocol.ExactEditMaterial{
        .target_sha256 = @import("observation.zig").sha256Hex(normalized),
    };
    material.current_sha256 = hashRegularFile(ctx.allocator, normalized);
    if (is_write) {
        const escaped = common.extractJsonArg(input, "content") orelse return material;
        const content = util_json.unescapeString(escaped, ctx.allocator) catch return material;
        defer ctx.allocator.free(content);
        material.write_content_sha256 = @import("observation.zig").sha256Hex(content);
        return material;
    }
    const escaped_old = common.extractJsonArg(input, "old_string") orelse return material;
    const escaped_new = common.extractJsonArg(input, "new_string") orelse return material;
    const old = util_json.unescapeString(escaped_old, ctx.allocator) catch return material;
    defer ctx.allocator.free(old);
    const new = util_json.unescapeString(escaped_new, ctx.allocator) catch return material;
    defer ctx.allocator.free(new);
    material.edit_old_sha256 = @import("observation.zig").sha256Hex(old);
    material.edit_new_sha256 = @import("observation.zig").sha256Hex(new);
    return material;
}

fn hashRegularFile(allocator: std.mem.Allocator, path: []const u8) ?[64]u8 {
    const path_z = allocator.dupeZ(u8, path) catch return null;
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return null;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return null;
    if (!before.is_regular or before.link_count != 1 or
        before.size > project_rule_spec.MAX_INPUT_BYTES)
        return null;
    const bytes = common.readAllFromFdCapped(
        fd,
        allocator,
        @intCast(project_rule_spec.MAX_INPUT_BYTES),
    ) catch return null;
    defer allocator.free(bytes);
    const after = pfs.fileInfo(fd) catch return null;
    if (!after.is_regular or after.link_count != 1 or after.size != before.size)
        return null;
    return @import("observation.zig").sha256Hex(bytes);
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
    try std.testing.expectEqual(project_rule_spec.FileTargetState.regular_existing, observeFileTarget(&ctx, "Edit", existing_input));
}
