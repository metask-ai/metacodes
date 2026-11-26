//! AgentDef.isolation=worktree 生命周期。创建独立 git worktree；agent 完成后若无任何
//! 工作树或提交变化则自动移除，有变化则保留路径交给父 agent/用户验收。

const std = @import("std");
const controller_git = @import("metacodes-base").util.controller_git;
const common = @import("metacodes-guard").tools.common;
const teammate_process = @import("../swarm/teammate_process.zig");
const pfs = @import("platform").fs;

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
        /// Host state root: worktrees live under `<state_root>/worktrees`.
        state_root: []const u8,
        repo: []const u8,
        abort: anytype,
    ) !Worktree {
        if (state_root.len == 0 or repo.len == 0) return error.AgentWorktreeUnavailable;
        const id = @import("metacodes-kernel").session_id.gen();
        const id_s = id.asSlice();
        const slug = id_s[0..@min(id_s.len, 12)];
        const path = try std.fmt.allocPrint(allocator, "{s}/worktrees/agent-{s}", .{ state_root, slug });
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

/// A disposable, git-isolated copy of a repository's working tree for the
/// isolated verifier (doc/ISOLATED_VERIFIER_DESIGN.md §2.3). Unlike
/// `Worktree` it snapshots the **working tree** (uncommitted and untracked,
/// not ignored), never writes the actor's index, `HEAD`, refs or stash, and is
/// a separate repository whose objects resolve read-only through
/// `objects/info/alternates`. It holds two host-written commits and no
/// history: `base` (the run-start `HEAD`'s tree) and `candidate` (tree **T**,
/// parent `base`). `finalize` always deletes it: a verifier's probes are not
/// products.
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    /// `<state_root>/verify/<id>`: holds the temporary index and the repository.
    root: []u8,
    /// `<root>/repo`: the snapshot repository, checked out at `candidate`.
    path: []u8,
    /// The actor repository (a copy of the path).
    repo: []u8,
    /// The run-start `HEAD` the snapshot diffs against; null = an empty base.
    base_head: ?[]u8,
    /// Tree id **T** of the actor's working tree at creation.
    tree: []u8,
    base: []u8,
    candidate: []u8,
    finalized: bool = false,
    cleanup_complete: ?bool = null,

    pub const MESSAGE_BASE = "metacodes isolated verifier: base";
    pub const MESSAGE_CANDIDATE = "metacodes isolated verifier: candidate";

    pub fn create(
        allocator: std.mem.Allocator,
        state_root: []const u8,
        repo: []const u8,
        /// Run-start `HEAD` (recorded when the check gate is armed); null =
        /// the repository's current `HEAD`, or an empty base when unborn.
        base_head: ?[]const u8,
        abort: anytype,
    ) !Snapshot {
        if (state_root.len == 0 or repo.len == 0) return error.SnapshotUnavailable;
        const id = @import("metacodes-kernel").session_id.gen();
        const id_s = id.asSlice();
        const slug = id_s[0..@min(id_s.len, 16)];
        const root = try std.fmt.allocPrint(allocator, "{s}/verify/{s}", .{ state_root, slug });
        errdefer allocator.free(root);
        const path = try std.fmt.allocPrint(allocator, "{s}/repo", .{root});
        errdefer allocator.free(path);
        const repo_owned = try allocator.dupe(u8, repo);
        errdefer allocator.free(repo_owned);
        const head: ?[]u8 = if (base_head) |h| try allocator.dupe(u8, h) else gitOutput(allocator, repo, &.{ "rev-parse", "--verify", "-q", "HEAD" }, abort) catch null;
        errdefer if (head) |h| allocator.free(h);

        // The snapshot repository first: `git init` creates `<root>` too, so
        // the temporary index has a directory to live in.
        const init_out = try gitOutput(allocator, state_root, &.{ "init", "-q", path }, abort);
        allocator.free(init_out);
        var created = true;
        errdefer if (created) removeTree(allocator, root);

        const tree = try workingTree(allocator, repo, root, head, abort);
        errdefer allocator.free(tree);
        const base_tree = if (head) |h| blk: {
            const spec = try std.fmt.allocPrint(allocator, "{s}^{{tree}}", .{h});
            defer allocator.free(spec);
            break :blk try gitOutput(allocator, repo, &.{ "rev-parse", spec }, abort);
        } else try emptyTree(allocator, repo, root, abort);
        defer allocator.free(base_tree);
        const base = try gitEnvOutput(allocator, repo, &COMMIT_ENV, &.{ "commit-tree", "--no-gpg-sign", base_tree, "-m", MESSAGE_BASE }, abort);
        errdefer allocator.free(base);
        const candidate = try gitEnvOutput(allocator, repo, &COMMIT_ENV, &.{ "commit-tree", "--no-gpg-sign", tree, "-p", base, "-m", MESSAGE_CANDIDATE }, abort);
        errdefer allocator.free(candidate);

        // Objects resolve read-only through alternates; refs, stash and any
        // object the verifier writes stay in the snapshot repository.
        const objects = try gitOutput(allocator, repo, &.{ "rev-parse", "--path-format=absolute", "--git-path", "objects" }, abort);
        defer allocator.free(objects);
        const alternates = try std.fmt.allocPrint(allocator, "{s}/.git/objects/info/alternates", .{path});
        defer allocator.free(alternates);
        const alternates_text = try std.fmt.allocPrint(allocator, "{s}\n", .{objects});
        defer allocator.free(alternates_text);
        try writeFile(allocator, alternates, alternates_text);
        // Refs are written as plain files and the work tree is filled by
        // `read-tree -u`: no ref transaction, no hooks, no reflog. The
        // snapshot is disposable, so nothing here needs git's durability.
        for ([_][2][]const u8{ .{ "refs/heads/base", base }, .{ "refs/heads/candidate", candidate } }) |ref| {
            const ref_path = try std.fmt.allocPrint(allocator, "{s}/.git/{s}", .{ path, ref[0] });
            defer allocator.free(ref_path);
            const ref_text = try std.fmt.allocPrint(allocator, "{s}\n", .{ref[1]});
            defer allocator.free(ref_text);
            try writeFile(allocator, ref_path, ref_text);
        }
        const head_path = try std.fmt.allocPrint(allocator, "{s}/.git/HEAD", .{path});
        defer allocator.free(head_path);
        try writeFile(allocator, head_path, "ref: refs/heads/candidate\n");
        const checkout = try gitOutput(allocator, path, &.{ "read-tree", "-u", "--reset", "candidate" }, abort);
        allocator.free(checkout);
        created = false;
        return .{
            .allocator = allocator,
            .root = root,
            .path = path,
            .repo = repo_owned,
            .base_head = head,
            .tree = tree,
            .base = base,
            .candidate = candidate,
        };
    }

    /// Recompute the actor workspace's tree id (**T′**) the same way.
    /// Owned by the snapshot allocator.
    pub fn currentTree(self: *const Snapshot, abort: anytype) ![]u8 {
        return workingTree(self.allocator, self.repo, self.root, self.base_head, abort);
    }

    /// T′ = T. A failed recomputation counts as changed: the verdict would
    /// otherwise describe a tree nobody can confirm.
    pub fn workspaceUnchanged(self: *const Snapshot, abort: anytype) bool {
        const now = self.currentTree(abort) catch return false;
        defer self.allocator.free(now);
        return std.mem.eql(u8, now, self.tree);
    }

    /// Delete the snapshot whatever it contains. Returns `cleanup_complete`;
    /// a failed removal is reported, never fatal.
    pub fn finalize(self: *Snapshot) bool {
        if (self.finalized) return self.cleanup_complete orelse false;
        self.finalized = true;
        removeTree(self.allocator, self.root);
        const root_z = self.allocator.dupeZ(u8, self.root) catch {
            self.cleanup_complete = false;
            return false;
        };
        defer self.allocator.free(root_z);
        self.cleanup_complete = !pfs.exists(root_z.ptr);
        return self.cleanup_complete.?;
    }

    pub fn deinit(self: *Snapshot) void {
        if (!self.finalized) _ = self.finalize();
        self.allocator.free(self.root);
        self.allocator.free(self.path);
        self.allocator.free(self.repo);
        if (self.base_head) |h| self.allocator.free(h);
        self.allocator.free(self.tree);
        self.allocator.free(self.base);
        self.allocator.free(self.candidate);
        self.* = undefined;
    }
};

/// The repository's current `HEAD` commit, or null (no git, not a
/// repository, an unborn branch). Owned.
pub fn headOf(allocator: std.mem.Allocator, repo: []const u8, abort: anytype) ?[]u8 {
    if (repo.len == 0) return null;
    return gitOutput(allocator, repo, &.{ "rev-parse", "--verify", "-q", "HEAD" }, abort) catch null;
}

/// Fixed identity and dates: the host's commits are byte-identical for the
/// same trees, and no user configuration is needed to write them.
const COMMIT_ENV = [_][]const u8{
    "GIT_AUTHOR_NAME=metacodes",
    "GIT_AUTHOR_EMAIL=verifier@metacodes.invalid",
    "GIT_AUTHOR_DATE=1700000000 +0000",
    "GIT_COMMITTER_NAME=metacodes",
    "GIT_COMMITTER_EMAIL=verifier@metacodes.invalid",
    "GIT_COMMITTER_DATE=1700000000 +0000",
};

/// Tree id of `repo`'s working tree (tracked plus untracked-not-ignored),
/// staged through a temporary index under `scratch`: the actor's index is
/// never read or written. `base_head` seeds the index (null = empty), so with
/// no files staged the result is the empty tree. `scratch`, when it lies
/// inside `repo`, is excluded.
fn workingTree(allocator: std.mem.Allocator, repo: []const u8, scratch: []const u8, base_head: ?[]const u8, abort: anytype) ![]u8 {
    const index = try std.fmt.allocPrint(allocator, "{s}/index", .{scratch});
    defer allocator.free(index);
    const index_z = try allocator.dupeZ(u8, index);
    defer allocator.free(index_z);
    pfs.unlinkPath(index_z.ptr) catch |err| switch (err) {
        error.NotFound => {},
        error.UnlinkFailed => return error.SnapshotUnavailable,
    };
    defer pfs.unlinkPath(index_z.ptr) catch {};
    const env_index = try std.fmt.allocPrint(allocator, "GIT_INDEX_FILE={s}", .{index});
    defer allocator.free(env_index);
    const env = [_][]const u8{env_index};
    if (base_head) |head| {
        const out = try gitEnvOutput(allocator, repo, &env, &.{ "read-tree", head }, abort);
        allocator.free(out);
        // Only the working tree counts: a base with files the run deleted
        // must not keep them, so `add -A` below sees every deletion.
    }
    const exclude: ?[]u8 = if (std.mem.startsWith(u8, scratch, repo) and scratch.len > repo.len and scratch[repo.len] == '/')
        try std.fmt.allocPrint(allocator, ":(exclude){s}", .{scratch[repo.len + 1 ..]})
    else
        null;
    defer if (exclude) |e| allocator.free(e);
    const add_out = if (exclude) |e|
        try gitEnvOutput(allocator, repo, &env, &.{ "add", "-A", "--", ".", e }, abort)
    else
        try gitEnvOutput(allocator, repo, &env, &.{ "add", "-A" }, abort);
    allocator.free(add_out);
    return gitEnvOutput(allocator, repo, &env, &.{"write-tree"}, abort);
}

/// The empty tree's id in `repo`'s object format (an unborn base).
fn emptyTree(allocator: std.mem.Allocator, repo: []const u8, scratch: []const u8, abort: anytype) ![]u8 {
    const index = try std.fmt.allocPrint(allocator, "{s}/empty-index", .{scratch});
    defer allocator.free(index);
    const env_index = try std.fmt.allocPrint(allocator, "GIT_INDEX_FILE={s}", .{index});
    defer allocator.free(env_index);
    return gitEnvOutput(allocator, repo, &.{env_index}, &.{"write-tree"}, abort);
}

fn writeFile(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (fd < 0) return error.SnapshotUnavailable;
    defer pfs.close(fd);
    if (!pfs.writeAll(fd, bytes)) return error.SnapshotUnavailable;
}

fn removeTree(allocator: std.mem.Allocator, path: []const u8) void {
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    std.Io.Dir.cwd().deleteTree(io_runtime.io(), path) catch |err| {
        @import("metacodes-base").util.log.warn("verifier", "snapshot removal failed: {s}", .{@errorName(err)});
    };
}

fn gitOutput(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    args: []const []const u8,
    abort: anytype,
) ![]u8 {
    return gitEnvOutput(allocator, cwd, &.{}, args, abort);
}

/// `env <assignments> git -C <cwd> <args>`: the same capped, timed spawn for
/// every host git call; `env` carries per-call variables such as
/// `GIT_INDEX_FILE` without touching the process environment.
fn gitEnvOutput(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    env: []const []const u8,
    args: []const []const u8,
    abort: anytype,
) ![]u8 {
    const prefix = try controller_git.prefix(allocator, cwd, abort);
    defer prefix.deinit(allocator);
    var argv = std.ArrayList(?[*:0]const u8).empty;
    defer freeArgv(allocator, &argv);
    try appendZ(allocator, &argv, "/usr/bin/env");
    for (env) |assignment| try appendZ(allocator, &argv, assignment);
    for (prefix.items) |arg| try appendZ(allocator, &argv, arg);
    try appendZ(allocator, &argv, "-C");
    try appendZ(allocator, &argv, cwd);
    for (args) |arg| try appendZ(allocator, &argv, arg);
    try argv.append(allocator, null);
    const out = try common.spawnCaptureWithStderrTimed(argv.items, allocator, abort, 30_000, null, common.MAX_SPAWN_CAPTURE_BYTES, null);
    defer allocator.free(out.stderr);
    if (out.exit_code != 0 or !out.capture_complete) {
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
    const z = try allocator.dupeZ(u8, value);
    errdefer allocator.free(z);
    try argv.append(allocator, z.ptr);
}

fn freeArgv(allocator: std.mem.Allocator, argv: *std.ArrayList(?[*:0]const u8)) void {
    for (argv.items) |item| if (item) |z| allocator.free(std.mem.span(z));
    argv.deinit(allocator);
}

// ── Snapshot tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn testGit(dir: []const u8, args: []const []const u8) ![]u8 {
    return gitEnvOutput(testing.allocator, dir, &COMMIT_ENV, args, null);
}

fn testWrite(dir: []const u8, name: []const u8, bytes: []const u8) !void {
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(path);
    try writeFile(testing.allocator, path, bytes);
}

fn testExists(dir: []const u8, name: []const u8) !bool {
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/{s}", .{ dir, name }, 0);
    defer testing.allocator.free(path);
    return pfs.exists(path.ptr);
}

/// A repository with one commit, an ignore rule, a stash entry, a modified
/// tracked file, an untracked file and an ignored file.
fn testRepo(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const root = buf[0..try tmp.dir.realPath(testing.io, buf)];
    for ([_][]const []const u8{ &.{ "init", "-q" }, &.{ "config", "user.name", "t" }, &.{ "config", "user.email", "t@t" } }) |args| testing.allocator.free(try testGit(root, args));
    try testWrite(root, ".gitignore", "build/\n*.log\n");
    try testWrite(root, "lib.txt", "v1\n");
    for ([_][]const []const u8{ &.{ "add", "-A" }, &.{ "commit", "-q", "-m", "actor history message" } }) |args| testing.allocator.free(try testGit(root, args));
    try testWrite(root, "lib.txt", "stashed\n");
    testing.allocator.free(try testGit(root, &.{ "stash", "-q" }));
    try testWrite(root, "lib.txt", "v2\n");
    try testWrite(root, "new.txt", "untracked\n");
    try testWrite(root, "debug.log", "ignored\n");
    return root;
}

test "Snapshot: candidate content filters never execute on the controller" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = try testRepo(&tmp, &buf);
    var state_tmp = testing.tmpDir(.{});
    defer state_tmp.cleanup();
    var state_buf: [std.fs.max_path_bytes]u8 = undefined;
    const state_root = state_buf[0..try state_tmp.dir.realPath(testing.io, &state_buf)];
    try testWrite(repo, ".gitattributes", "*.dat filter=candidate\n");
    try testWrite(repo, "filter.sh", "printf called > filter-ran\ncat\n");
    try testWrite(repo, "data.dat", "candidate bytes\n");
    for ([_][]const []const u8{
        &.{ "config", "filter.candidate.clean", "/bin/sh ./filter.sh" },
        &.{ "config", "filter.candidate.smudge", "/bin/sh ./filter.sh" },
        &.{ "config", "filter.candidate.required", "true" },
    }) |args| gpa.free(try testGit(repo, args));
    var snap = try Snapshot.create(gpa, state_root, repo, null, null);
    defer snap.deinit();
    try testing.expect(!try testExists(repo, "filter-ran"));
    try testing.expect(!try testExists(snap.path, "filter-ran"));
    const data = try testGit(snap.path, &.{ "show", "candidate:data.dat" });
    defer gpa.free(data);
    try testing.expectEqualStrings("candidate bytes", data);
    try testing.expect(snap.workspaceUnchanged(null));
    try testWrite(repo, "data.dat", "changed bytes\n");
    try testing.expect(!snap.workspaceUnchanged(null));
    try testing.expect(!try testExists(repo, "filter-ran"));
}

test "Snapshot: working tree in, ignored out, actor index/HEAD/refs/stash untouched, always deleted" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // /usr/bin/env git
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = try testRepo(&tmp, &buf);
    var state_tmp = testing.tmpDir(.{});
    defer state_tmp.cleanup();
    var state_buf: [std.fs.max_path_bytes]u8 = undefined;
    const state_root = state_buf[0..try state_tmp.dir.realPath(testing.io, &state_buf)];

    const before_status = try testGit(repo, &.{ "status", "--porcelain" });
    defer a.free(before_status);
    const before_refs = try testGit(repo, &.{ "for-each-ref", "--format=%(refname) %(objectname)" });
    defer a.free(before_refs);
    const before_stash = try testGit(repo, &.{ "stash", "list" });
    defer a.free(before_stash);
    const before_head = try testGit(repo, &.{ "rev-parse", "HEAD" });
    defer a.free(before_head);

    var snap = try Snapshot.create(a, state_root, repo, null, null);
    defer snap.deinit();
    try testing.expect(try testExists(snap.path, "new.txt"));
    try testing.expect(!try testExists(snap.path, "debug.log"));
    const lib = try testGit(snap.path, &.{ "show", "candidate:lib.txt" });
    defer a.free(lib);
    try testing.expectEqualStrings("v2", lib);
    // Two host commits and no actor history.
    const log_out = try testGit(snap.path, &.{ "log", "--format=%s", "candidate" });
    defer a.free(log_out);
    try testing.expect(std.mem.indexOf(u8, log_out, "actor history message") == null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, log_out, "\n"));
    const diff = try testGit(snap.path, &.{ "diff", "--name-only", "base", "candidate" });
    defer a.free(diff);
    try testing.expect(std.mem.indexOf(u8, diff, "lib.txt") != null);
    try testing.expect(std.mem.indexOf(u8, diff, "new.txt") != null);

    // A git stash in the snapshot never reaches the actor's stash.
    try testWrite(snap.path, "probe.txt", "probe\n");
    try testWrite(snap.path, "lib.txt", "probe edit\n");
    a.free(try testGit(snap.path, &.{ "stash", "-q" }));
    try testing.expect(snap.workspaceUnchanged(null));

    const after_status = try testGit(repo, &.{ "status", "--porcelain" });
    defer a.free(after_status);
    const after_refs = try testGit(repo, &.{ "for-each-ref", "--format=%(refname) %(objectname)" });
    defer a.free(after_refs);
    const after_stash = try testGit(repo, &.{ "stash", "list" });
    defer a.free(after_stash);
    const after_head = try testGit(repo, &.{ "rev-parse", "HEAD" });
    defer a.free(after_head);
    try testing.expectEqualStrings(before_status, after_status);
    try testing.expectEqualStrings(before_refs, after_refs);
    try testing.expectEqualStrings(before_stash, after_stash);
    try testing.expectEqualStrings(before_head, after_head);

    // T' != T after a write to the actor's tree.
    try testWrite(repo, "new.txt", "changed\n");
    try testing.expect(!snap.workspaceUnchanged(null));

    const root_copy = try a.dupe(u8, snap.root);
    defer a.free(root_copy);
    try testing.expect(snap.finalize());
    const root_z = try a.dupeZ(u8, root_copy);
    defer a.free(root_z);
    try testing.expect(!pfs.exists(root_z.ptr));
}
