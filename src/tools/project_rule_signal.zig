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

/// The single source of truth for which tools an effect-class rule can see.
/// A tool belongs here exactly when its primary operation mutates one observed
/// file target — the same roster `observeFileTarget` senses. Opaque tools
/// (Bash) are deliberately absent: their file effects are not attributable at
/// pre time, and post-hoc the rule_coverage_gap signal reports them.
pub fn isFileMutatingTool(tool: []const u8) bool {
    return std.mem.eql(u8, tool, "Write") or
        std.mem.eql(u8, tool, "Edit") or
        std.mem.eql(u8, tool, "NotebookEdit");
}

pub fn observePre(
    ctx: *const ToolContext,
    dispatch_id: []const u8,
    tool: []const u8,
    input: []const u8,
) protocol.PreSignal {
    const target = observeFileTarget(ctx, tool, input);
    return .{
        .dispatch_id = dispatch_id,
        .tool = tool,
        .input_bytes = input.len,
        .agent_depth = ctx.agent_depth,
        .authoritative = ctx.tool_observation_origin == .authoritative,
        .file_target_state = target.state,
        .within_root = target.within_root,
        .exact_edit_material = observeExactEditMaterial(ctx, tool, input),
        .file_mutating = isFileMutatingTool(tool),
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
) TargetObservation {
    if (!isFileMutatingTool(tool))
        return .{ .state = .unobserved, .within_root = true };
    const escaped = if (std.mem.eql(u8, tool, "NotebookEdit"))
        common.extractJsonArg(input, "notebook_path") orelse
            common.extractJsonArg(input, "file_path") orelse
            common.extractJsonArg(input, "path") orelse return .{ .state = .unavailable, .within_root = false }
    else
        common.extractJsonArg(input, "file_path") orelse
            common.extractJsonArg(input, "path") orelse return .{ .state = .unavailable, .within_root = false };
    const path_unescaped = util_json.unescapeString(escaped, ctx.allocator) catch
        return .{ .state = .unavailable, .within_root = false };
    defer ctx.allocator.free(path_unescaped);
    if (path_unescaped.len == 0) return .{ .state = .unavailable, .within_root = false };
    const normalized = path_mod.normalizeChecked(ctx.allocator, path_unescaped, .{
        .home = ctx.home_dir,
        .base_dir = ctx.cwd_abs,
        .resolve_relative = ctx.resolve_relative_paths,
    }) catch return .{ .state = .unavailable, .within_root = false };
    defer ctx.allocator.free(normalized);
    const path_z = ctx.allocator.dupeZ(u8, normalized) catch return .{ .state = .unavailable, .within_root = false };
    defer ctx.allocator.free(path_z);
    return classifyEffectiveTarget(ctx, path_z, normalized);
}

pub const TargetObservation = struct {
    state: project_rule_spec.FileTargetState,
    within_root: bool,
};

/// Classify the EFFECTIVE mutation target (RRP-001): symlinks are resolved
/// before classification, so the state describes the file whose bytes would
/// actually change, and `within_root` reports containment of the resolved
/// path inside the project root.  The adjudicated false intervention (mkdocs
/// `docs/index.md -> README.md`) was a handle-vs-target confusion; this
/// classifier removes the class while keeping every escape closed:
/// resolution failing, escaping the root, or landing on a non-regular file
/// all stay conservative.  Lean mirror: `escaping_resolution_fails_closed`,
/// `resolved_regular_within_root_admits`.
fn classifyEffectiveTarget(
    ctx: *const ToolContext,
    path_z: [:0]const u8,
    normalized: []const u8,
) TargetObservation {
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_z = ctx.allocator.dupeZ(u8, ctx.cwd_abs) catch
        return .{ .state = .unavailable, .within_root = false };
    defer ctx.allocator.free(root_z);
    const root_resolved: []const u8 = if (pfs.realpath(root_z.ptr, &root_buf)) |r|
        std.mem.span(r)
    else
        ctx.cwd_abs;

    switch (pfs.pathKindNoFollow(path_z.ptr)) {
        .missing => {
            // A to-be-created path: containment is judged on the resolved
            // parent directory plus the final component, so a symlinked
            // ancestor cannot smuggle the creation out of the root.
            const dir = std.fs.path.dirname(normalized) orelse
                return .{ .state = .missing, .within_root = false };
            const base = std.fs.path.basename(normalized);
            const dir_z = ctx.allocator.dupeZ(u8, dir) catch
                return .{ .state = .unavailable, .within_root = false };
            defer ctx.allocator.free(dir_z);
            var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
            const parent = pfs.realpath(dir_z.ptr, &parent_buf) orelse
                return .{ .state = .missing, .within_root = false };
            var joined_buf: [std.fs.max_path_bytes]u8 = undefined;
            const joined = std.fmt.bufPrint(&joined_buf, "{s}/{s}", .{
                std.mem.span(parent), base,
            }) catch return .{ .state = .unavailable, .within_root = false };
            return .{
                .state = .missing,
                .within_root = pathContained(root_resolved, joined),
            };
        },
        .regular, .other => {
            var target_buf: [std.fs.max_path_bytes]u8 = undefined;
            const resolved = pfs.realpath(path_z.ptr, &target_buf) orelse
                // Broken symlink or unresolvable target: fail closed.
                return .{ .state = .unavailable, .within_root = false };
            const resolved_slice = std.mem.span(resolved);
            const contained = pathContained(root_resolved, resolved_slice);
            const mode_regular = blk: {
                const followed = pfs.statMode(path_z.ptr, true) orelse break :blk false;
                break :blk (followed & 0o170000) == 0o100000;
            };
            return .{
                .state = if (mode_regular) .regular_existing else .other_existing,
                .within_root = contained,
            };
        },
        .unavailable => return .{ .state = .unavailable, .within_root = false },
    }
}

fn pathContained(root: []const u8, target: []const u8) bool {
    if (std.mem.eql(u8, root, target)) return true;
    if (!std.mem.startsWith(u8, target, root)) return false;
    return target.len > root.len and target[root.len] == '/';
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
    try std.testing.expectEqual(project_rule_spec.FileTargetState.regular_existing, observeFileTarget(&ctx, "Write", existing_input).state);
    try std.testing.expectEqual(project_rule_spec.FileTargetState.missing, observeFileTarget(&ctx, "Write", missing_input).state);
    try std.testing.expectEqual(project_rule_spec.FileTargetState.other_existing, observeFileTarget(&ctx, "Write", dir_input).state);
    try std.testing.expectEqual(project_rule_spec.FileTargetState.unavailable, observeFileTarget(&ctx, "Write", "{}").state);
    try std.testing.expectEqual(project_rule_spec.FileTargetState.regular_existing, observeFileTarget(&ctx, "Edit", existing_input).state);
}

test "effective target: symlink to a regular file inside the root is regular+contained" {
    // The adjudicated false-intervention shape (RRP-001): docs symlink to an
    // in-root README must classify as the resolved regular file.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = try std.fmt.bufPrint(&real_buf, "{s}/README.md", .{root});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = real, .data = "readme\n" });
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buf, "{s}/index.md", .{root});
    {
        const link_z = try a.dupeZ(u8, link);
        defer a.free(link_z);
        const target_z = try a.dupeZ(u8, "README.md");
        defer a.free(target_z);
        if (std.c.symlink(target_z.ptr, link_z.ptr) != 0) return error.SkipZigTest;
    }
    var ctx = ToolContext{ .allocator = a, .cwd_abs = root, .home_dir = root };
    var input_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf, "{{\"file_path\":\"{s}\"}}", .{link});
    const obs = observeFileTarget(&ctx, "Edit", input);
    try std.testing.expectEqual(project_rule_spec.FileTargetState.regular_existing, obs.state);
    try std.testing.expect(obs.within_root);
}

test "effective target: symlink escaping the root stays fail-closed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const whole = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    // root = <tmp>/proj; escape target lives beside it, outside the root.
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "{s}/proj", .{whole});
    std.Io.Dir.cwd().createDirPath(std.testing.io, root) catch return error.SkipZigTest;
    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const outside = try std.fmt.bufPrint(&out_buf, "{s}/secret.txt", .{whole});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = outside, .data = "s\n" });
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buf, "{s}/escape.md", .{root});
    {
        const link_z = try a.dupeZ(u8, link);
        defer a.free(link_z);
        const target_z = try a.dupeZ(u8, "../secret.txt");
        defer a.free(target_z);
        if (std.c.symlink(target_z.ptr, link_z.ptr) != 0) return error.SkipZigTest;
    }
    var ctx = ToolContext{ .allocator = a, .cwd_abs = root, .home_dir = root };
    var input_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf, "{{\"file_path\":\"{s}\"}}", .{link});
    const obs = observeFileTarget(&ctx, "Edit", input);
    // Resolved regular, but OUTSIDE the root: the decision ladders block it.
    try std.testing.expect(!obs.within_root);
    const spec = project_rule_spec.Spec{
        .target = .{ .effect_class = .existing_file_rewrite },
        .deny_target = false,
        .max_input_bytes = 100000,
        .max_agent_depth = 4,
        .authoritative_only = false,
        .effect_requirement = .file_mutation_v1_reobserved,
    };
    const sig = project_rule_spec.PreSignal{
        .tool = "Edit",
        .input_bytes = 10,
        .agent_depth = 0,
        .authoritative = true,
        .file_target_state = obs.state,
        .file_mutating = true,
        .within_root = obs.within_root,
    };
    try std.testing.expect(!project_rule_spec.preDecision(spec, sig));
}

test "effective target: directory still fails closed even inside the root" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sub = try std.fmt.bufPrint(&dir_buf, "{s}/docs", .{root});
    std.Io.Dir.cwd().createDirPath(std.testing.io, sub) catch return error.SkipZigTest;
    var ctx = ToolContext{ .allocator = a, .cwd_abs = root, .home_dir = root };
    var input_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf, "{{\"file_path\":\"{s}\"}}", .{sub});
    const obs = observeFileTarget(&ctx, "Edit", input);
    try std.testing.expectEqual(project_rule_spec.FileTargetState.other_existing, obs.state);
}
