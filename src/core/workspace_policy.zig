//! Session-owned inputs for the existing Workspace-aware tool context.
//!
//! This facade canonicalizes and owns root/home strings and maps the Host's
//! shell choice onto the sandbox settings already understood by AgentLoop. It
//! deliberately does not change or strengthen existing tool behavior.

const std = @import("std");
const pfs = @import("platform").fs;
const sandbox_config = @import("../sandbox/config.zig");

pub const ShellPolicy = enum {
    disabled,
    sandboxed,
    unrestricted,
};

pub const Config = struct {
    root: []const u8,
    home: []const u8 = "",
    shell: ShellPolicy = .disabled,
};

pub const WorkspacePolicy = struct {
    allocator: std.mem.Allocator,
    root: []u8,
    home: []u8,
    shell: ShellPolicy,
    sandbox_settings: sandbox_config.SandboxSettings,

    pub fn init(allocator: std.mem.Allocator, config: Config) !WorkspacePolicy {
        if (config.root.len == 0 or !std.fs.path.isAbsolute(config.root)) return error.InvalidWorkspaceRoot;
        const root = try realpathAlloc(allocator, config.root);
        errdefer allocator.free(root);

        const home_source = if (config.home.len > 0) config.home else root;
        if (!std.fs.path.isAbsolute(home_source)) return error.InvalidWorkspaceHome;
        const home = try allocator.dupe(u8, home_source);
        errdefer allocator.free(home);

        return .{
            .allocator = allocator,
            .root = root,
            .home = home,
            .shell = config.shell,
            .sandbox_settings = .{
                .enabled = config.shell == .sandboxed,
                .fail_if_unavailable = true,
                .allow_unsandboxed_commands = false,
                .auto_allow_bash_if_sandboxed = true,
            },
        };
    }

    pub fn deinit(self: *WorkspacePolicy) void {
        self.allocator.free(self.home);
        self.allocator.free(self.root);
        self.* = undefined;
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
