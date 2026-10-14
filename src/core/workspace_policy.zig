//! Session-owned inputs for the existing Workspace-aware tool context.
//!
//! This facade canonicalizes and owns root/home strings and maps the Host's
//! shell choice onto the sandbox settings already understood by AgentLoop. It
//! deliberately does not change or strengthen existing tool behavior.

const std = @import("std");
const pfs = @import("platform").fs;
const pdir = @import("platform").dir;
const sandbox_config = @import("../sandbox/config.zig");
const StateRoot = @import("../util/state_root.zig").StateRoot;

pub const ShellPolicy = enum {
    disabled,
    sandboxed,
    unrestricted,
};

pub const Config = struct {
    root: []const u8,
    home: []const u8 = "",
    /// Where this session keeps metacodes state (agentcore sessions, KG,
    /// worktrees, telemetry). The host decides; "" = `<home>/.metacodes`, the
    /// layout every host had before the state root existed.
    state_root: []const u8 = "",
    shell: ShellPolicy = .disabled,
    /// Further absolute directories the Session works in beside `root` (the
    /// CLI's `/add-dir` set). Each must exist; the policy keeps real paths.
    /// They widen exactly what `root` grants: `accept_edits` auto-approval of
    /// Write/Edit/NotebookEdit and sandboxed shell writes. They are not named
    /// in the system prompt; a Host that wants the model to know says so in a
    /// context block or its prompt profile.
    additional_dirs: []const []const u8 = &.{},
};

pub const WorkspacePolicy = struct {
    allocator: std.mem.Allocator,
    root: []u8,
    home: []u8,
    state_root: []u8,
    shell: ShellPolicy,
    sandbox_settings: sandbox_config.SandboxSettings,
    /// Real paths of `Config.additional_dirs`, deduplicated, `root` excluded.
    /// The list and every entry are owned by `allocator`.
    additional_dirs: []const []const u8,

    pub fn init(allocator: std.mem.Allocator, config: Config) !WorkspacePolicy {
        if (config.root.len == 0 or !std.fs.path.isAbsolute(config.root)) return error.InvalidWorkspaceRoot;
        const root = try realpathAlloc(allocator, config.root);
        errdefer allocator.free(root);

        const home_source = if (config.home.len > 0) config.home else root;
        if (!std.fs.path.isAbsolute(home_source)) return error.InvalidWorkspaceHome;
        const home = try allocator.dupe(u8, home_source);
        errdefer allocator.free(home);
        if (config.state_root.len > 0 and !std.fs.path.isAbsolute(config.state_root)) return error.InvalidWorkspaceStateRoot;
        const state_root = if (config.state_root.len > 0)
            try allocator.dupe(u8, config.state_root)
        else
            try @import("../util/state_root.zig").legacyDefault(allocator, home);
        errdefer allocator.free(state_root);
        const additional_dirs = try resolveAdditionalDirs(allocator, root, config.additional_dirs);
        errdefer freeDirs(allocator, additional_dirs);

        return .{
            .allocator = allocator,
            .root = root,
            .home = home,
            .state_root = state_root,
            .shell = config.shell,
            .sandbox_settings = .{
                .enabled = config.shell == .sandboxed,
                .fail_if_unavailable = true,
                .allow_unsandboxed_commands = false,
                .auto_allow_bash_if_sandboxed = true,
            },
            .additional_dirs = additional_dirs,
        };
    }

    pub fn deinit(self: *WorkspacePolicy) void {
        freeDirs(self.allocator, self.additional_dirs);
        self.allocator.free(self.state_root);
        self.allocator.free(self.home);
        self.allocator.free(self.root);
        self.* = undefined;
    }

    /// The state root this workspace resolved: `Config.state_root`, or
    /// `<home>/.metacodes` when none was given. Borrowed from the policy.
    /// A Host persisting transcripts passes it with `root` to
    /// `transcript.sessionDir` / `transcript.Writer.init`; resolving a policy
    /// from the same `Config` before a restore yields the same path.
    pub fn stateRoot(self: *const WorkspacePolicy) StateRoot {
        return .{ .path = self.state_root };
    }

    pub fn sandbox(self: *const WorkspacePolicy) ?*const sandbox_config.SandboxSettings {
        return if (self.shell == .sandboxed) &self.sandbox_settings else null;
    }

    pub fn allowsTool(self: *const WorkspacePolicy, name: []const u8) bool {
        if (!isShellTool(name)) return true;
        return self.shell != .disabled;
    }
};

pub fn isShellTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "Bash") or
        std.mem.eql(u8, name, "BashOutput") or
        std.mem.eql(u8, name, "KillShell");
}

/// Validates and resolves every directory before returning; on any error
/// nothing is retained. Entries equal to `root` or to an earlier entry are
/// dropped, so the result is the set the Host meant.
pub fn resolveAdditionalDirs(
    allocator: std.mem.Allocator,
    root: []const u8,
    dirs: []const []const u8,
) error{ InvalidAdditionalDirectory, OutOfMemory }![]const []const u8 {
    var resolved: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (resolved.items) |dir| allocator.free(dir);
        resolved.deinit(allocator);
    }
    for (dirs) |dir| {
        if (dir.len == 0 or !std.fs.path.isAbsolute(dir)) return error.InvalidAdditionalDirectory;
        const real = realpathAlloc(allocator, dir) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidAdditionalDirectory,
        };
        // A directory that exists now: a file would widen the working set to
        // that one path, and Windows' lexical realpath accepts missing paths.
        if (!isDirectory(real)) {
            allocator.free(real);
            return error.InvalidAdditionalDirectory;
        }
        var duplicate = std.mem.eql(u8, real, root);
        for (resolved.items) |kept| duplicate = duplicate or std.mem.eql(u8, real, kept);
        if (duplicate) {
            allocator.free(real);
            continue;
        }
        resolved.append(allocator, real) catch |err| {
            allocator.free(real);
            return err;
        };
    }
    return resolved.toOwnedSlice(allocator);
}

fn isDirectory(path: []const u8) bool {
    var path_z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= path_z.len) return false;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    var it = pdir.open(@ptrCast(&path_z)) orelse return false;
    pdir.close(&it);
    return true;
}

pub fn freeDirs(allocator: std.mem.Allocator, dirs: []const []const u8) void {
    for (dirs) |dir| allocator.free(dir);
    allocator.free(dirs);
}

fn realpathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len >= std.fs.max_path_bytes) return error.InvalidWorkspaceRoot;
    var path_z: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    var out: [std.fs.max_path_bytes + 1]u8 = undefined;
    const resolved = pfs.realpath(@ptrCast(&path_z), &out) orelse return error.InvalidWorkspaceRoot;
    return allocator.dupe(u8, std.mem.span(resolved));
}

test "WorkspacePolicy requires an existing absolute root and fails shell closed" {
    try std.testing.expectError(error.InvalidWorkspaceRoot, WorkspacePolicy.init(std.testing.allocator, .{ .root = "." }));
    const cwd = try @import("../util/fs.zig").getCwd(std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    var policy = try WorkspacePolicy.init(std.testing.allocator, .{ .root = cwd });
    defer policy.deinit();
    try std.testing.expect(policy.allowsTool("Read"));
    try std.testing.expect(!policy.allowsTool("Bash"));
    try std.testing.expect(policy.sandbox() == null);
}

test "WorkspacePolicy keeps the real paths of distinct additional directories and refuses invalid ones" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "root");
    try tmp.dir.createDirPath(std.testing.io, "extra");
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(std.testing.io, &base_buf)];
    const root = try std.fs.path.join(a, &.{ base, "root" });
    defer a.free(root);
    const extra = try std.fs.path.join(a, &.{ base, "extra" });
    defer a.free(extra);
    // `extra/../extra` names the same directory as `extra`.
    const extra_again = try std.fs.path.join(a, &.{ base, "extra", "..", "extra" });
    defer a.free(extra_again);

    var policy = try WorkspacePolicy.init(a, .{ .root = root, .additional_dirs = &.{ extra, root, extra_again } });
    defer policy.deinit();
    try std.testing.expectEqual(@as(usize, 1), policy.additional_dirs.len);
    try std.testing.expectEqualStrings(extra, policy.additional_dirs[0]);

    const missing = try std.fs.path.join(a, &.{ base, "missing" });
    defer a.free(missing);
    try std.testing.expectError(error.InvalidAdditionalDirectory, WorkspacePolicy.init(a, .{ .root = root, .additional_dirs = &.{ extra, missing } }));
    try std.testing.expectError(error.InvalidAdditionalDirectory, WorkspacePolicy.init(a, .{ .root = root, .additional_dirs = &.{"relative/dir"} }));
    // An existing file is not a working directory.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "extra/notes.txt", .data = "x" });
    const file = try std.fs.path.join(a, &.{ extra, "notes.txt" });
    defer a.free(file);
    try std.testing.expectError(error.InvalidAdditionalDirectory, WorkspacePolicy.init(a, .{ .root = root, .additional_dirs = &.{file} }));
}
