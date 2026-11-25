//! The implementer's worktree and merge-back (#523).
//!
//! At run start the runtime snapshots the user's workspace as it is on disk
//! (tracked changes and untracked, non-ignored files included) into a commit
//! object that no ref names, and adds a detached git worktree at that commit
//! inside the run directory. The implementer therefore starts from exactly
//! what the user sees, uncommitted work included, and the user's index,
//! refs and files are never touched: the only side effects on the user's
//! repository are objects in its object store and the worktree's entry
//! under `.git/worktrees/`.
//!
//! (`agents/isolation.zig` bases its worktree on `HEAD` and creates a
//! branch, which would drop the user's uncommitted work and leave a ref
//! behind; this module uses the same git primitives — `git worktree add` and
//! `git worktree remove` — with the snapshot commit and a
//! detached `HEAD` instead.)
//!
//! Merge-back, only after a passing completion audit, applies the diff from
//! the snapshot commit to the approved tree onto the user's workspace with
//! `git apply --index` against a disposable index, with no commit. If the user changed, during the run,
//! any path the implementer changed (or a parent or child of one), nothing
//! is applied: the conflicting paths go to `merge-conflicts.txt`, the patch
//! to `merge.patch`, the worktree is kept, and both sides stay as they are.
//! Git checks the patch against full preimages before writing. This does
//! not lock the checkout against unrelated processes while Git writes files.

const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const common = @import("../tools/common.zig");
const controller_git = @import("../util/controller_git.zig");
const log = @import("../util/log.zig");
const run_dir = @import("run_dir.zig");
const reviewer = @import("reviewer.zig");
const types = @import("types.zig");

const Abort = ?*const types.AbortSignal;

pub const TreeId = reviewer.TreeId;
/// A git object id (commit or tree): 40 or 64 lowercase hex digits.
pub const ObjectId = reviewer.TreeId;

pub const Error = error{
    /// The workspace is not inside a git work tree.
    NotARepository,
    GitFailed,
    /// Not implemented on this platform (Windows: `reviewer.workspaceTree`).
    Unsupported,
    PathTooLong,
    Aborted,
    OutOfMemory,
};

const git_timeout_ms: u64 = 120_000;
const max_git_output: usize = 64 * 1024 * 1024;

const GitOut = struct {
    exit_code: i32,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *GitOut, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

fn git(gpa: std.mem.Allocator, cwd: []const u8, args: []const []const u8, abort: Abort) Error!GitOut {
    return gitWithIndex(gpa, cwd, args, abort, null);
}

fn gitWithIndex(gpa: std.mem.Allocator, cwd: []const u8, args: []const []const u8, abort: Abort, index: ?[]const u8) Error!GitOut {
    const prefix = try controller_git.prefix(gpa, cwd, abort);
    defer prefix.deinit(gpa);
    var owned: std.ArrayList([:0]u8) = .empty;
    defer {
        for (owned.items) |arg| gpa.free(arg);
        owned.deinit(gpa);
    }
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "/usr/bin/env");
    if (index) |path| {
        const assignment = try std.fmt.allocPrint(gpa, "GIT_INDEX_FILE={s}", .{path});
        defer gpa.free(assignment);
        try appendArgument(gpa, &owned, &argv, assignment);
    }
    for (prefix.items) |arg| try appendArgument(gpa, &owned, &argv, arg);
    for (args) |arg| {
        try appendArgument(gpa, &owned, &argv, arg);
    }
    try argv.append(gpa, null);
    const out = common.spawnCaptureWithStderrTimed(argv.items, gpa, abort, git_timeout_ms, null, max_git_output, cwd) catch |err| switch (err) {
        error.Aborted => return error.Aborted,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.GitFailed,
    };
    if (!out.capture_complete) {
        gpa.free(out.stdout);
        gpa.free(out.stderr);
        return error.GitFailed;
    }
    return .{ .exit_code = out.exit_code, .stdout = out.stdout, .stderr = out.stderr };
}

fn appendArgument(gpa: std.mem.Allocator, owned: *std.ArrayList([:0]u8), argv: *std.ArrayList(?[*:0]const u8), arg: []const u8) error{OutOfMemory}!void {
    const z = try gpa.dupeZ(u8, arg);
    owned.append(gpa, z) catch |err| {
        gpa.free(z);
        return err;
    };
    try argv.append(gpa, z.ptr);
}

/// stdout of a git command that must succeed, trimmed; owned by `gpa`.
fn gitText(gpa: std.mem.Allocator, cwd: []const u8, args: []const []const u8, abort: Abort) Error![]u8 {
    var out = try git(gpa, cwd, args, abort);
    defer out.deinit(gpa);
    if (out.exit_code != 0) {
        log.warn("teamwork", "git {s} failed in {s}: {s}", .{ args[0], cwd, std.mem.trimEnd(u8, out.stderr, "\r\n") });
        return error.GitFailed;
    }
    return gpa.dupe(u8, std.mem.trimEnd(u8, out.stdout, "\r\n "));
}

fn parseObject(text: []const u8) Error!ObjectId {
    return ObjectId.parse(text) catch error.GitFailed;
}

/// The top directory of the git work tree holding `workspace`, owned by
/// `gpa`. Every merge-back path is relative to it.
pub fn toplevel(gpa: std.mem.Allocator, workspace: []const u8, abort: Abort) Error![]u8 {
    if (builtin.os.tag == .windows) return error.Unsupported;
    var out = try git(gpa, workspace, &.{ "rev-parse", "--show-toplevel" }, abort);
    defer out.deinit(gpa);
    if (out.exit_code != 0) return error.NotARepository;
    return gpa.dupe(u8, std.mem.trimEnd(u8, out.stdout, "\r\n"));
}

pub const Snapshot = struct {
    /// A commit of `tree` (parent: `HEAD`, if the repository has one) that
    /// no ref names: the implementer worktree's base.
    commit: ObjectId,
    /// The user's workspace as it was on disk at run start.
    tree: TreeId,
};

/// Snapshot the workspace at `repo` without touching its index, refs or
/// files. `scratch_dir` (outside the workspace) holds a throwaway index.
pub fn snapshot(gpa: std.mem.Allocator, repo: []const u8, scratch_dir: []const u8, abort: Abort) Error!Snapshot {
    const tree = reviewer.workspaceTree(gpa, repo, scratch_dir, abort) catch |err| return switch (err) {
        error.NotARepository => error.NotARepository,
        error.Unsupported => error.Unsupported,
        error.PathTooLong => error.PathTooLong,
        error.Aborted => error.Aborted,
        error.OutOfMemory => error.OutOfMemory,
        error.GitFailed => error.GitFailed,
    };
    var head_out = try git(gpa, repo, &.{ "rev-parse", "--verify", "-q", "HEAD^{commit}" }, abort);
    defer head_out.deinit(gpa);
    const head: ?[]const u8 = if (head_out.exit_code == 0) std.mem.trimEnd(u8, head_out.stdout, "\r\n") else null;
    // A fixed identity: the user's may be unset, and the commit is never
    // published (no ref names it).
    var args = [_][]const u8{ "-c", "user.name=metacodes teamwork", "-c", "user.email=teamwork@metacodes.invalid", "-c", "commit.gpgSign=false", "commit-tree", tree.slice(), "-m", "metacodes teamwork base", "-p", "" };
    const used: usize = if (head) |parent| blk: {
        args[args.len - 1] = parent;
        break :blk args.len;
    } else args.len - 2;
    const commit_text = try gitText(gpa, repo, args[0..used], abort);
    defer gpa.free(commit_text);
    return .{ .commit = try parseObject(commit_text), .tree = tree };
}

/// Add a detached worktree without running hooks or content filters outside
/// the seat sandbox.
pub fn addWorktree(gpa: std.mem.Allocator, repo: []const u8, path: []const u8, commit: ObjectId, abort: Abort) Error!void {
    // Conditional includes can enable different filters in the new gitdir.
    // Register without checking out, then discover its own effective config
    // before populating files. Source-repository overrides alone are not enough.
    const added = try gitText(gpa, repo, &.{ "worktree", "add", "--no-checkout", "--detach", "--quiet", path, commit.slice() }, abort);
    defer gpa.free(added);
    errdefer _ = removeWorktree(gpa, repo, path);
    const checked_out = try gitText(gpa, path, &.{ "read-tree", "-u", "--reset", commit.slice() }, abort);
    defer gpa.free(checked_out);
}

/// The persisted approval says no seat was ever dispatched into this
/// checkout. Discard a partial registration before retrying initialization.
pub fn ensureInitialWorktree(gpa: std.mem.Allocator, repo: []const u8, path: []const u8, commit: ObjectId) Error!void {
    const z = try gpa.dupeZ(u8, path);
    defer gpa.free(z);
    if (pfs.exists(z.ptr) and !removeWorktree(gpa, repo, path)) return error.GitFailed;
    try addWorktree(gpa, repo, path, commit, null);
}

/// Remove the worktree at `path`; true when it is confirmed gone.
pub fn removeWorktree(gpa: std.mem.Allocator, repo: []const u8, path: []const u8) bool {
    const path_z = gpa.dupeZ(u8, path) catch return false;
    defer gpa.free(path_z);
    const out = gitText(gpa, repo, &.{ "worktree", "remove", "--force", path }, null) catch |err| {
        log.warn("teamwork", "worktree {s} kept: removal failed: {s}", .{ path, @errorName(err) });
        return false;
    };
    defer gpa.free(out);
    return !pfs.exists(path_z.ptr);
}

/// Paths that differ between two tree-ish objects (repository-relative,
/// renames as delete + add), owned by `gpa`.
pub fn changedPaths(gpa: std.mem.Allocator, repo: []const u8, from: ObjectId, to: ObjectId, abort: Abort) Error!PathList {
    var list: PathList = .{};
    errdefer list.deinit(gpa);
    if (from.eql(to)) return list;
    // The flags keep the user's git configuration out of machine-read output.
    var out = try git(gpa, repo, &.{ "diff", "--name-only", "-z", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--ignore-submodules=none", from.slice(), to.slice() }, abort);
    defer out.deinit(gpa);
    if (out.exit_code != 0) return error.GitFailed;
    var it = std.mem.splitScalar(u8, out.stdout, 0);
    while (it.next()) |name| {
        if (name.len == 0) continue;
        try list.items.append(gpa, try gpa.dupe(u8, name));
    }
    return list;
}

pub const PathList = struct {
    items: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *PathList, gpa: std.mem.Allocator) void {
        for (self.items.items) |p| gpa.free(p);
        self.items.deinit(gpa);
        self.* = undefined;
    }
};

/// The binary patch from `from` to `to`, owned by `gpa`.
pub fn diffPatch(gpa: std.mem.Allocator, repo: []const u8, from: ObjectId, to: ObjectId, abort: Abort) Error![]u8 {
    const out = try git(gpa, repo, &.{ "diff", "--binary", "--full-index", "--src-prefix=a/", "--dst-prefix=b/", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--ignore-submodules=none", from.slice(), to.slice() }, abort);
    defer gpa.free(out.stderr);
    if (out.exit_code != 0) {
        gpa.free(out.stdout);
        return error.GitFailed;
    }
    return out.stdout;
}

/// Two repository-relative paths collide when they are equal or one is a
/// directory prefix of the other (a file replaced by a directory).
fn collide(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const short, const long = if (a.len < b.len) .{ a, b } else .{ b, a };
    return std.mem.startsWith(u8, long, short) and long[short.len] == '/';
}

pub const Input = struct {
    /// The user's work tree top (`toplevel`).
    repo: []const u8,
    /// The implementer worktree's base and the user's tree at run start.
    base: Snapshot,
    /// The tree the reviewer approved and the audit passed.
    approved: TreeId,
    /// A directory outside the workspace for a throwaway index.
    scratch_dir: []const u8,
    /// Where the patch and the conflict list are written (run directory).
    patch_path: [:0]const u8,
    conflicts_path: [:0]const u8,
};

pub const Result = union(enum) {
    /// The workspace now carries the implementer's change, uncommitted.
    applied: struct { files: u32 },
    /// The user changed this many of the implementer's paths during the
    /// run; nothing was applied (see `merge-conflicts.txt`).
    conflict: u32,
    /// `git apply` refused the patch; nothing was applied.
    apply_failed,
};

/// Apply the approved change to the user's workspace, or report why not.
/// Conflict detection and patch validation precede writes to the workspace.
pub fn mergeBack(gpa: std.mem.Allocator, in: Input) Error!Result {
    return mergeBackAfterScan(gpa, in, null);
}

/// Test seam for the interval between conflict discovery and apply.
pub fn mergeBackAfterScan(gpa: std.mem.Allocator, in: Input, after_scan: ?*const fn (Input) Error!void) Error!Result {
    var ours = try changedPaths(gpa, in.repo, in.base.commit, in.approved, null);
    defer ours.deinit(gpa);
    const patch = try diffPatch(gpa, in.repo, in.base.commit, in.approved, null);
    defer gpa.free(patch);
    run_dir.writeAtomic(in.patch_path, patch) catch return error.GitFailed;

    if (try changesGitlinks(gpa, in)) {
        run_dir.writeAtomic(in.conflicts_path, "The approved diff changes submodule commits. Apply the saved patch manually.\n") catch return error.GitFailed;
        return .apply_failed;
    }

    if (ours.items.items.len == 0) return .{ .applied = .{ .files = 0 } };

    // Keep the index that produced the conflict scan's tree. Its rehashed
    // entries describe the actual worktree and include the file stat data
    // git apply --index needs to check the relevant preimages before writing.
    const index = try std.fs.path.joinZ(gpa, &.{ in.scratch_dir, "merge-index" });
    defer gpa.free(index);
    defer pfs.unlinkPath(index.ptr) catch {};
    const user_now = try reviewer.workspaceTreeWithIndex(gpa, in.repo, index, null);
    const conflicts = try recordConflicts(gpa, in, ours.items.items, user_now);
    if (conflicts != 0) return .{ .conflict = conflicts };
    if (after_scan) |hook| try hook(in);

    var out = try gitWithIndex(gpa, in.repo, &.{ "-c", "core.splitIndex=false", "apply", "--index", "--binary", "--whitespace=nowarn", in.patch_path }, null, index);
    defer out.deinit(gpa);
    if (out.exit_code != 0) {
        const latest = try reviewer.workspaceTree(gpa, in.repo, in.scratch_dir, null);
        const late_conflicts = try recordConflicts(gpa, in, ours.items.items, latest);
        if (late_conflicts != 0) return .{ .conflict = late_conflicts };
        run_dir.writeAtomic(in.conflicts_path, out.stderr) catch {};
        log.warn("teamwork", "merge-back: git apply refused the patch: {s}", .{std.mem.trimEnd(u8, out.stderr, "\r\n")});
        return .apply_failed;
    }
    return .{ .applied = .{ .files = @intCast(ours.items.items.len) } };
}

fn changesGitlinks(gpa: std.mem.Allocator, in: Input) Error!bool {
    var out = try git(gpa, in.repo, &.{ "diff", "--raw", "-z", "--no-renames", "--no-ext-diff", "--no-textconv", "--ignore-submodules=none", in.base.commit.slice(), in.approved.slice() }, null);
    defer out.deinit(gpa);
    if (out.exit_code != 0) return error.GitFailed;
    var fields = std.mem.splitScalar(u8, out.stdout, 0);
    while (fields.next()) |header| {
        if (header.len == 0) break;
        if (header.len < 15 or header[0] != ':' or header[7] != ' ' or header[14] != ' ') return error.GitFailed;
        if ((fields.next() orelse return error.GitFailed).len == 0) return error.GitFailed;
        if (std.mem.eql(u8, header[1..7], "160000") or std.mem.eql(u8, header[8..14], "160000")) return true;
    }
    return false;
}

fn recordConflicts(gpa: std.mem.Allocator, in: Input, ours: []const []u8, user_now: TreeId) Error!u32 {
    var theirs = try changedPaths(gpa, in.repo, in.base.tree, user_now, null);
    defer theirs.deinit(gpa);

    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(gpa);
    var conflicts: u32 = 0;
    for (ours) |path| {
        for (theirs.items.items) |user_path| {
            if (!collide(path, user_path)) continue;
            conflicts += 1;
            try report.print(gpa, "{s}\n", .{path});
            break;
        }
    }
    if (conflicts != 0) run_dir.writeAtomic(in.conflicts_path, report.items) catch return error.GitFailed;
    return conflicts;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "merge-back: colliding paths are equal or nested" {
    try testing.expect(collide("src/a.zig", "src/a.zig"));
    try testing.expect(collide("src", "src/a.zig"));
    try testing.expect(collide("src/a.zig", "src"));
    try testing.expect(!collide("src/a.zig", "src/a.zig2"));
    try testing.expect(!collide("src/ab", "src/a"));
}
