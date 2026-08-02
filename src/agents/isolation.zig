//! AgentDef.isolation=worktree 生命周期。创建独立 git worktree；agent 完成后若无任何
//! 工作树或提交变化则自动移除，有变化则保留路径交给父 agent/用户验收。

const std = @import("std");
const common = @import("../tools/common.zig");
const teammate_process = @import("../swarm/teammate_process.zig");

pub const Worktree = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    repo: []u8,
    branch: []u8,
    base_head: []u8,
    finalized: bool = false,
    kept: ?bool = null,
    cleanup_complete: ?bool = null,

    pub fn create(
        allocator: std.mem.Allocator,
        home_dir: []const u8,
        repo: []const u8,
        abort: anytype,
    ) !Worktree {
        if (home_dir.len == 0 or repo.len == 0) return error.AgentWorktreeUnavailable;
        const id = @import("../core/session_id.zig").gen();
        const id_s = id.asSlice();
        const slug = id_s[0..@min(id_s.len, 12)];
        const path = try std.fmt.allocPrint(allocator, "{s}/.metacodes/worktrees/agent-{s}", .{ home_dir, slug });
        errdefer allocator.free(path);
        const repo_owned = try allocator.dupe(u8, repo);
        errdefer allocator.free(repo_owned);
        const branch = try std.fmt.allocPrint(allocator, "metacodes-agent-{s}", .{slug});
        errdefer allocator.free(branch);
        const base_head = try gitOutput(allocator, repo, &.{ "rev-parse", "HEAD" }, abort);
        errdefer allocator.free(base_head);

        try teammate_process.createWorktree(allocator, path, branch, base_head, repo, abort);
        return .{
            .allocator = allocator,
            .path = path,
            .repo = repo_owned,
            .branch = branch,
            .base_head = base_head,
        };
    }

    /// 返回 true 表示 worktree 有变化并被保留；false 表示干净且已移除。
    /// 检测失败时 fail-safe 保留，绝不误删 agent 产物。
    pub fn finalize(self: *Worktree, abort: anytype) bool {
        if (self.finalized) return self.kept orelse true;
        self.finalized = true;

        const status = gitOutput(self.allocator, self.path, &.{ "status", "--porcelain" }, abort) catch {
            self.kept = true;
            self.cleanup_complete = false;
            return true;
        };
        defer self.allocator.free(status);
        const head = gitOutput(self.allocator, self.path, &.{ "rev-parse", "HEAD" }, abort) catch {
            self.kept = true;
            self.cleanup_complete = false;
            return true;
        };
        defer self.allocator.free(head);
        if (status.len != 0 or !std.mem.eql(u8, head, self.base_head)) {
            self.kept = true;
            self.cleanup_complete = true;
            return true;
        }

        teammate_process.removeWorktreeStrict(self.allocator, self.path, self.repo, abort) catch {
            self.kept = true;
            self.cleanup_complete = false;
            return true;
        };
        deleteBranch(self.allocator, self.repo, self.branch, abort) catch {
            // removeWorktreeStrict proved the path is gone. Do not lie that
            // the worktree was kept merely because branch cleanup failed;
            // expose the incomplete cleanup as a separate status.
            self.kept = false;
            self.cleanup_complete = false;
            return false;
        };
        self.kept = false;
        self.cleanup_complete = true;
        return false;
    }

    pub fn deinit(self: *Worktree) void {
        self.allocator.free(self.path);
        self.allocator.free(self.repo);
        self.allocator.free(self.branch);
        self.allocator.free(self.base_head);
        self.* = undefined;
    }
};

fn gitOutput(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    args: []const []const u8,
    abort: anytype,
) ![]u8 {
    var argv = std.ArrayList(?[*:0]const u8).empty;
    defer freeArgv(allocator, &argv);
    try appendZ(allocator, &argv, "/usr/bin/env");
    try appendZ(allocator, &argv, "git");
    try appendZ(allocator, &argv, "-C");
    try appendZ(allocator, &argv, cwd);
    for (args) |arg| try appendZ(allocator, &argv, arg);
    try argv.append(allocator, null);
    const out = try common.spawnCaptureWithStderrTimed(argv.items, allocator, abort, 30_000, null, common.MAX_SPAWN_CAPTURE_BYTES);
    defer allocator.free(out.stderr);
    if (out.exit_code != 0) {
        allocator.free(out.stdout);
        return error.GitCommandFailed;
    }
    const trimmed = std.mem.trimEnd(u8, out.stdout, "\r\n ");
    const result = try allocator.dupe(u8, trimmed);
    allocator.free(out.stdout);
    return result;
}

fn deleteBranch(allocator: std.mem.Allocator, repo: []const u8, branch: []const u8, abort: anytype) !void {
    const out = try gitOutput(allocator, repo, &.{ "branch", "-D", branch }, abort);
    allocator.free(out);
}

fn appendZ(allocator: std.mem.Allocator, argv: *std.ArrayList(?[*:0]const u8), value: []const u8) !void {
    try argv.append(allocator, (try allocator.dupeZ(u8, value)).ptr);
}

fn freeArgv(allocator: std.mem.Allocator, argv: *std.ArrayList(?[*:0]const u8)) void {
    for (argv.items) |item| if (item) |z| allocator.free(std.mem.span(z));
    argv.deinit(allocator);
}
