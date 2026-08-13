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

/// Deterministically lower one model-proposed existing-file Write into the
/// exact Edit selected by Lean.  The source bytes come from a bounded,
/// no-follow descriptor read whose same-fd type, link-count, size and byte
/// count are checked before/after; the replacement bytes are the original
/// Write content. The later recovery-pre decision and
/// native same-descriptor compare remain the authority-bearing source checks.
/// No model-visible rendering (notably Read's line-number view) participates,
/// so terminal newlines and every other byte survive the transformation.
///
/// This function does not authorize or execute anything.  `executeOne` must
/// feed the returned Edit input through `observePre` and the formal gate again,
/// and only `admit_exact_edit` may reach the native whole-file implementation.
pub fn synthesizeExactEditInput(
    ctx: *const ToolContext,
    write_input: []const u8,
) ![]u8 {
    if (!pfs.atomic_final_nofollow)
        return error.ProjectExactEditNativeUnavailable;
    const escaped_path = common.extractJsonArg(write_input, "file_path") orelse
        common.extractJsonArg(write_input, "path") orelse return error.MissingPath;
    const escaped_content = common.extractJsonArg(write_input, "content") orelse
        return error.MissingContent;
    const path = try util_json.unescapeString(escaped_path, ctx.allocator);
    defer ctx.allocator.free(path);
    const replacement = try util_json.unescapeString(escaped_content, ctx.allocator);
    defer ctx.allocator.free(replacement);
    if (path.len == 0) return error.EmptyPath;
    const normalized = try path_mod.normalizeChecked(ctx.allocator, path, .{
        .home = ctx.home_dir,
        .base_dir = ctx.cwd_abs,
        .resolve_relative = ctx.resolve_relative_paths,
    });
    defer ctx.allocator.free(normalized);
    const source = try readStableRegularFile(ctx.allocator, normalized);
    defer ctx.allocator.free(source);
    // The synthesized Edit travels through the ordinary JSON tool-input seam.
    // Arbitrary file bytes are therefore not representable without inventing a
    // separate binary transport.  Reject them explicitly instead of relying on
    // encoder behavior that could produce malformed JSON or silently rewrite
    // the source snapshot.
    if (!std.unicode.utf8ValidateSlice(source))
        return error.ProjectExactEditSourceNotUtf8;

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"file_path\":");
    try std.json.Stringify.encodeJsonString(normalized, .{}, &out.writer);
    try out.writer.writeAll(",\"old_string\":");
    try std.json.Stringify.encodeJsonString(source, .{}, &out.writer);
    try out.writer.writeAll(",\"new_string\":");
    try std.json.Stringify.encodeJsonString(replacement, .{}, &out.writer);
    try out.writer.writeAll(",\"replace_all\":false}");
    if (out.written().len > project_rule_spec.MAX_INPUT_BYTES)
        return error.ProjectExactEditInputTooLarge;
    return try out.toOwnedSlice();
}

fn readStableRegularFile(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ProjectExactEditTargetUnavailable;
    defer _ = pfs.close(fd);
    pfs.makeCloseOnExec(fd) catch return error.ProjectExactEditTargetUnavailable;
    const before = pfs.fileInfo(fd) catch
        return error.ProjectExactEditTargetUnavailable;
    if (!before.is_regular or before.link_count != 1 or
        before.size > project_rule_spec.MAX_INPUT_BYTES)
        return error.ProjectExactEditTargetUnavailable;
    const bytes = common.readAllFromFdCapped(
        fd,
        allocator,
        @intCast(project_rule_spec.MAX_INPUT_BYTES),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ProjectExactEditTargetUnavailable,
    };
    errdefer allocator.free(bytes);
    const after = pfs.fileInfo(fd) catch
        return error.ProjectExactEditTargetUnavailable;
    if (!after.is_regular or after.link_count != 1 or
        after.size != before.size or bytes.len != @as(usize, @intCast(before.size)))
        return error.ProjectExactEditTargetUnavailable;
    return bytes;
}

pub fn observeFileTarget(
    ctx: *const ToolContext,
    tool: []const u8,
    input: []const u8,
) project_rule_spec.FileTargetState {
    const is_file_target = std.mem.eql(u8, tool, "Write") or
        std.mem.eql(u8, tool, "Edit") or
        std.mem.eql(u8, tool, "NotebookEdit");
    if (!is_file_target)
        return .unobserved;
    const escaped = if (std.mem.eql(u8, tool, "NotebookEdit"))
        common.extractJsonArg(input, "notebook_path") orelse
            common.extractJsonArg(input, "file_path") orelse
            common.extractJsonArg(input, "path") orelse return .unavailable
    else
        common.extractJsonArg(input, "file_path") orelse
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
