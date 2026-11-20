//! The file changes a shell command made, observed from outside the command.
//!
//! The typed file tools report every change they make (`file_change.zig`).
//! `Bash` cannot: the command is arbitrary. In practice models also edit
//! source through it — on 2026-11-17's local transcripts glm-5.3-flash made
//! about 40% of its in-place edits as `python3 - <<EOF` read/replace/write
//! scripts — and every such write bypassed the file-change contract.
//!
//! So the Bash tool brackets a command with two observations of the
//! workspace and publishes the difference on the same contract:
//!
//!   - **Before**: list the workspace's files with the bundled ripgrep (its
//!     ignore rules, hidden files included, VCS metadata excluded) and lstat
//!     each one. In a git workspace, also note which files already differ
//!     from the index and copy those (bounded), so a later diff has a "before"
//!     for them; a file that matches the index gets its "before" from the index
//!     afterwards, and only if the command left the index untouched.
//!   - **After**: list and lstat again. A path whose identity, size or
//!     timestamps moved is a change; a vanished path paired with a new one of
//!     the same inode, size and modification time is a move.
//!
//! **Scope, stated rather than implied.** Observed: regular files below the
//! workspace root that ripgrep lists. Not observed: ignored files, symlinks,
//! anything outside the root, and anything a process does after the
//! observation ends (a command still running in the background). A record
//! names what changed in the workspace *while* the command ran; another
//! writer active in the same window (a background subagent, the user's
//! editor) can appear in it.
//!
//! **Silence is a claim.** When the observation cannot cover the call — the
//! listing fails, the workspace is too large, the command outlives it — the
//! sink is told (`noteIncomplete`), which reaches the consumer as `lost`.
//! A content comparison that is merely unavailable (no git, a file over the
//! size cap, binary bytes) still reports the change, without a diff and with
//! `diff_complete = false`.

const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const process = @import("platform").process;
const sync = @import("platform").sync;
const file_change = @import("file_change.zig");
const patch = @import("patch.zig");
const toolchain = @import("../util/toolchain.zig");
const common = @import("../tools/common.zig");
const log = @import("../util/log.zig");
const util_time = @import("../util/time.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const ToolContext = @import("../tools/context.zig").ToolContext;
const sandbox_fs = @import("../sandbox/filesystem.zig");

pub const Limits = struct {
    /// Files one listing may hold. Beyond this the workspace is "too large"
    /// for the process lifetime (see `Breaker`).
    max_files: usize = 100_000,
    max_listing_bytes: usize = 8 * 1024 * 1024,
    listing_timeout_ms: u64 = 3_000,
    git_timeout_ms: u64 = 2_000,
    max_status_bytes: usize = 4 * 1024 * 1024,
    /// Files already differing from the index that are copied before the
    /// command runs, and the bytes that may cost. The same byte budget caps
    /// what is read back from the index afterwards.
    max_baseline_files: usize = 256,
    max_baseline_bytes: usize = 8 * 1024 * 1024,
    /// Largest file whose content is read for a diff.
    max_file_bytes: usize = 256 * 1024,
    /// LCS table bound for one file's diff (`patch.computeBounded`).
    max_diff_cells: usize = 4 * 1024 * 1024,
    /// Changed paths examined per call. Past the per-result record cap more
    /// changes may still be touch-only (skipped), so a few more are examined;
    /// anything left after this is reported as overflow, never dropped.
    max_examined: usize = 4 * file_change.MAX_FILE_CHANGES_PER_TOOL_RESULT_V1,
    /// A path the listing shows only afterwards (an ignore rule was removed)
    /// was already there when its status-change time is this much older than
    /// the observation: filesystem clocks are coarse (FAT: 2 s).
    clock_slack_ms: u64 = 2_000,
};

pub const Options = struct {
    limits: Limits = .{},
    /// Ask git which files differ from the index and read "befores" from it.
    /// Must be false when the command runs in a sandbox: the sandboxed
    /// command may write `.git/config` (it is inside the writable root), and
    /// this module runs git *outside* the sandbox — a planted fsmonitor hook
    /// or clean filter would execute unconfined. Without git, modifications
    /// are still reported, only without a diff.
    git_baselines: bool = true,
    /// The session's sandbox, when the command runs in one. The listing then
    /// runs inside it and a change is published only if the sandbox lets the
    /// command open the file, whose contents are read through it too: what
    /// the sandbox hides from the command (`denyRead`) stays out of the
    /// event and the journal. A sandbox that cannot be reached makes the call
    /// `lost`.
    confined: ?*const ToolContext = null,
};

/// Why a call went unobserved. Every gap reaches the consumer as `lost`.
pub const Gap = enum {
    /// The bundled ripgrep is missing, failed, or printed nothing it should have.
    listing_failed,
    /// More files or listing bytes than `Limits` allow.
    workspace_too_large,
    /// The listing did not finish in time.
    listing_timed_out,
    /// An earlier call in this process found the workspace too large.
    workspace_too_large_before,
    /// The workspace root cannot be entered.
    root_unavailable,
    aborted,
    out_of_memory,
};

// ── Process-wide memory of slow workspaces ─────────────────────────────────

/// A workspace that overflowed a listing does so on every call; re-listing it
/// before and after each command would cost seconds for a guaranteed `lost`.
/// Likewise a git status too large to read. A timeout can be a cold cache or a
/// busy machine, so it takes `TIMEOUTS_TO_TRIP` of them. Keyed by root,
/// remembered for the process; a fixed table, so a forgotten entry only costs
/// one more failed attempt.
const Breaker = struct {
    const TIMEOUTS_TO_TRIP = 2;
    const Entry = struct {
        root: u64,
        too_large: bool = false,
        git_slow: bool = false,
        listing_timeouts: u8 = 0,
        git_timeouts: u8 = 0,
    };
    const Event = enum { too_large, listing_timeout, git_too_large, git_timeout };

    mutex: sync.Mutex = .{},
    entries: [16]Entry = undefined,
    len: usize = 0,
    next: usize = 0,

    fn key(root: []const u8) u64 {
        return std.hash.Wyhash.hash(0x6669_6c65_6368_6e67, root);
    }

    fn get(self: *Breaker, root: []const u8) Entry {
        const k = key(root);
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries[0..self.len]) |e| if (e.root == k) return e;
        return .{ .root = k };
    }

    fn note(self: *Breaker, root: []const u8, event: Event) void {
        const k = key(root);
        self.mutex.lock();
        defer self.mutex.unlock();
        const e = for (self.entries[0..self.len]) |*e| {
            if (e.root == k) break e;
        } else blk: {
            const slot = if (self.len < self.entries.len) s: {
                self.len += 1;
                break :s self.len - 1;
            } else s: {
                const s = self.next;
                self.next = (self.next + 1) % self.entries.len;
                break :s s;
            };
            self.entries[slot] = .{ .root = k };
            break :blk &self.entries[slot];
        };
        switch (event) {
            .too_large => e.too_large = true,
            .git_too_large => e.git_slow = true,
            .listing_timeout => {
                e.listing_timeouts +|= 1;
                if (e.listing_timeouts >= TIMEOUTS_TO_TRIP) e.too_large = true;
            },
            .git_timeout => {
                e.git_timeouts +|= 1;
                if (e.git_timeouts >= TIMEOUTS_TO_TRIP) e.git_slow = true;
            },
        }
    }

    fn forget(self: *Breaker, root: []const u8) void {
        const k = key(root);
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries[0..self.len]) |*e| if (e.root == k) {
            e.* = .{ .root = k };
        };
    }
};

var breaker: Breaker = .{};

fn noteGap(root: []const u8, gap: Gap) void {
    switch (gap) {
        .workspace_too_large => breaker.note(root, .too_large),
        .listing_timed_out => breaker.note(root, .listing_timeout),
        else => {},
    }
}

// ── Snapshot ───────────────────────────────────────────────────────────────

const Snapshot = struct {
    /// ripgrep's NUL-separated output; the map's keys borrow it.
    listing: []u8,
    files: std.StringHashMapUnmanaged(pfs.PathStat),
    /// Listed paths that could not be observed (a name too long to join, a
    /// stat that failed for a reason other than absence). Their changes would
    /// be invisible, so a non-zero count makes the report incomplete.
    unobserved: usize = 0,

    fn deinit(self: *Snapshot, gpa: std.mem.Allocator) void {
        self.files.deinit(gpa);
        gpa.free(self.listing);
    }
};

const SnapshotResult = union(enum) { ok: Snapshot, gap: Gap };

const AbortBridge = struct {
    fn poll(ctx: ?*const anyopaque) bool {
        const a: *const AbortSignal = @ptrCast(@alignCast(ctx.?));
        return a.isAborted();
    }
};

fn takeSnapshot(gpa: std.mem.Allocator, root: []const u8, abort: ?*const AbortSignal, limits: Limits, confined: ?*const ToolContext) SnapshotResult {
    const rg = toolchain.ripgrepPath() catch return .{ .gap = .listing_failed };
    var root_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    // A confined listing names the root explicitly: the sandbox wrapper may
    // run it from the session's directory, not from `root`.
    const root_z: ?[*:0]const u8 = if (confined != null)
        (std.fmt.bufPrintZ(&root_buf, "{s}", .{root}) catch return .{ .gap = .listing_failed }).ptr
    else
        null;
    var argv = [_]?[*:0]const u8{
        rg.ptr,
        "--files",
        "--hidden",
        "--no-config",
        "--no-messages",
        "--no-require-git",
        "--null",
        "--path-separator=/",
        "--glob=!.git",
        "--glob=!.hg",
        "--glob=!.svn",
        "--glob=!.jj",
        "--",
        root_z,
        null,
    };
    var wrapped: ?sandbox_fs.SearchCommand = if (confined) |ctx|
        (sandbox_fs.wrapArgv(ctx, &argv) catch return .{ .gap = .listing_failed }) orelse
            return .{ .gap = .listing_failed }
    else
        null;
    defer if (wrapped) |*w| w.deinit();
    const captured = common.captureWithSpawnRetry(if (wrapped) |w| w.argv else &argv, gpa, .{
        .timeout_ms = limits.listing_timeout_ms,
        .max_bytes = limits.max_listing_bytes,
        .want_stderr = false,
        .cwd = root,
        .abort_ctx = @ptrCast(abort),
        .abort_poll = if (abort != null) AbortBridge.poll else null,
    }) catch |err| return .{ .gap = switch (err) {
        error.Timeout => .listing_timed_out,
        error.Aborted => .aborted,
        error.OutOfMemory => .out_of_memory,
        error.ChildChdirFailed => .root_unavailable,
        else => .listing_failed,
    } };
    gpa.free(captured.stderr);
    const listing = captured.stdout;
    var keep = false;
    defer if (!keep) gpa.free(listing);
    if (!captured.capture_complete) return .{ .gap = .workspace_too_large };
    // 0 = files listed, 1 = none. 2 is an error that may still have listed
    // (an unreadable subdirectory): accept it only with output, so a rejected
    // flag can never pass for an empty workspace, and count it as unobserved:
    // what that directory holds, and what happens in it, is not seen.
    var unobserved: usize = 0;
    switch (captured.exit_code) {
        0, 1 => {},
        2 => {
            if (listing.len == 0) return .{ .gap = .listing_failed };
            unobserved += 1;
        },
        else => return .{ .gap = .listing_failed },
    }

    var files: std.StringHashMapUnmanaged(pfs.PathStat) = .empty;
    errdefer files.deinit(gpa);
    const count = std.mem.count(u8, listing, "\x00");
    if (count > limits.max_files) return .{ .gap = .workspace_too_large };
    files.ensureTotalCapacity(gpa, @intCast(count)) catch return .{ .gap = .out_of_memory };

    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    var it = std.mem.splitScalar(u8, listing, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const rel = if (confined != null) underRoot(root, entry) orelse {
            unobserved += 1;
            continue;
        } else entry;
        const z = joinZ(&path_buf, root, rel) orelse {
            unobserved += 1;
            continue;
        };
        const stat = pfs.statNoFollow(z) catch |err| switch (err) {
            error.NotFound => continue, // gone since the listing
            error.Unavailable => {
                unobserved += 1;
                continue;
            },
        };
        if (stat.kind != .regular) continue;
        files.putAssumeCapacity(rel, stat);
    }
    keep = true;
    return .{ .ok = .{ .listing = listing, .files = files, .unobserved = unobserved } };
}

/// `entry` without the `root/` a listing of `root` by name prefixes it with.
fn underRoot(root: []const u8, entry: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, root, "/");
    if (entry.len <= trimmed.len + 1 or !std.mem.startsWith(u8, entry, trimmed) or entry[trimmed.len] != '/') return null;
    return entry[trimmed.len + 1 ..];
}

fn joinZ(buf: *[std.fs.max_path_bytes + 1]u8, root: []const u8, rel: []const u8) ?[*:0]const u8 {
    const sep: usize = if (root.len > 0 and (root[root.len - 1] == '/' or root[root.len - 1] == '\\')) 0 else 1;
    const total = root.len + sep + rel.len;
    if (total >= buf.len) return null;
    @memcpy(buf[0..root.len], root);
    if (sep == 1) buf[root.len] = '/';
    @memcpy(buf[root.len + sep ..][0..rel.len], rel);
    buf[total] = 0;
    return @ptrCast(buf[0..total :0]);
}

// ── Git baseline ───────────────────────────────────────────────────────────

const GitResult = union(enum) {
    /// stdout, owned by the caller's allocator; `complete` is false when the
    /// byte cap cut it short.
    ok: struct { out: []u8, complete: bool },
    /// git ran and refused (not a repository).
    refused,
    /// git did not run (not installed, could not be spawned).
    unavailable,
    timed_out,
    aborted,
};

fn runGit(
    allocator: std.mem.Allocator,
    root: []const u8,
    args: []const []const u8,
    abort: ?*const AbortSignal,
    timeout_ms: u64,
    max_bytes: usize,
    stdin: ?[]const u8,
) error{OutOfMemory}!GitResult {
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer {
        if (argv.items.len > 2) for (argv.items[2..]) |arg| if (arg) |a| allocator.free(std.mem.span(a));
        argv.deinit(allocator);
    }
    // The child gets an empty environment, so `/usr/bin/env` finds git on its
    // default search path (`/usr/bin:/bin`), not the user's PATH; the Windows
    // backend strips the env prefix and lets CreateProcessW search PATH (same
    // as test_integrity). `core.fsmonitor=false`: a configured fsmonitor hook
    // is a program from the repository's config, and this runs on every
    // observed call.
    try argv.appendSlice(allocator, &.{ "/usr/bin/env", "git" });
    for ([_][]const u8{ "-c", "core.fsmonitor=false" }) |arg| try argv.append(allocator, try allocator.dupeZ(u8, arg));
    for (args) |arg| try argv.append(allocator, try allocator.dupeZ(u8, arg));
    try argv.append(allocator, null);
    const captured = common.captureWithSpawnRetry(argv.items, allocator, .{
        .timeout_ms = timeout_ms,
        .max_bytes = max_bytes,
        .want_stderr = false,
        .stdin_data = stdin,
        .cwd = root,
        .abort_ctx = @ptrCast(abort),
        .abort_poll = if (abort != null) AbortBridge.poll else null,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Aborted => .aborted,
        error.Timeout => .timed_out,
        else => .unavailable,
    };
    allocator.free(captured.stderr);
    if (captured.exit_code != 0) {
        allocator.free(captured.stdout);
        return .refused;
    }
    return .{ .ok = .{ .out = captured.stdout, .complete = captured.capture_complete } };
}

/// What git said about the workspace before the command ran. Everything is
/// owned by `arena`.
const GitBefore = struct {
    arena: std.heap.ArenaAllocator,
    /// The root's path inside the repository ("" or "sub/dir/").
    prefix: []const u8,
    index_path: [:0]const u8,
    /// Null when the repository has no index yet.
    index_stat: ?pfs.PathStat,
    /// Root-relative paths that already differed from the index, or were
    /// untracked, before the command: the index is not their "before".
    dirty: std.StringHashMapUnmanaged(void) = .empty,
    /// Copies of dirty files, root-relative path → bytes.
    copies: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Where attributes and config come from, outside the listing: the
    /// repository's `info/attributes` and `config`, and the `.gitattributes`
    /// of the directories between the repository top and the root. Paired
    /// with their state before the command (null: absent).
    attribute_sources: std.ArrayListUnmanaged(Source) = .empty,

    const Source = struct { path: [:0]const u8, then: ?pfs.PathStat };

    fn deinit(self: *GitBefore) void {
        self.arena.deinit();
    }

    /// The attributes that decide how a file's index blob relates to its
    /// bytes on disk are the ones the command started with.
    fn attributesUnchanged(self: *const GitBefore, changes: []const Change) bool {
        for (changes) |c| {
            if (std.mem.eql(u8, std.fs.path.basenamePosix(c.rel), ".gitattributes")) return false;
            if (c.from_rel) |f| if (std.mem.eql(u8, std.fs.path.basenamePosix(f), ".gitattributes")) return false;
        }
        for (self.attribute_sources.items) |src| {
            const now: ?pfs.PathStat = pfs.statNoFollow(src.path.ptr) catch |err| switch (err) {
                error.NotFound => null,
                error.Unavailable => return false,
            };
            if ((src.then == null) != (now == null)) return false;
            if (src.then) |t| if (!t.eql(now.?)) return false;
        }
        return true;
    }
};

fn resolveGitPath(a: std.mem.Allocator, root: []const u8, path: []const u8) error{OutOfMemory}![:0]const u8 {
    return if (std.fs.path.isAbsolute(path))
        try a.dupeZ(u8, path)
    else
        try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ root, path }, 0);
}

fn addSource(before: *GitBefore, path: [:0]const u8) error{OutOfMemory}!void {
    const then: ?pfs.PathStat = pfs.statNoFollow(path.ptr) catch null;
    try before.attribute_sources.append(before.arena.allocator(), .{ .path = path, .then = then });
}

const Read = union(enum) { bytes: []u8, unavailable };

/// Read a regular file without following a final symlink, refusing anything
/// over `max_bytes`.
fn readRegular(allocator: std.mem.Allocator, path_z: [*:0]const u8, max_bytes: usize) error{OutOfMemory}!Read {
    const fd = pfs.open(path_z, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return .unavailable;
    defer pfs.close(fd);
    return readOpen(allocator, fd, max_bytes);
}

/// Read an open regular file, refusing anything over `max_bytes`.
fn readOpen(allocator: std.mem.Allocator, fd: pfs.Fd, max_bytes: usize) error{OutOfMemory}!Read {
    const info = pfs.fileInfo(fd) catch return .unavailable;
    if (!info.is_regular or info.size > max_bytes) return .unavailable;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, @intCast(info.size));
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, buf[0..]);
        if (n < 0) {
            out.deinit(allocator);
            return .unavailable;
        }
        if (n == 0) break;
        if (out.items.len + @as(usize, @intCast(n)) > max_bytes) {
            out.deinit(allocator);
            return .unavailable;
        }
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return .{ .bytes = try out.toOwnedSlice(allocator) };
}

const GitBeforeResult = union(enum) {
    ok: GitBefore,
    /// Not a repository, or no git to ask.
    none,
    /// The status listing outgrew its cap: it would every time.
    too_large,
    timed_out,
    aborted,
};

fn takeGitBefore(
    gpa: std.mem.Allocator,
    root: []const u8,
    snapshot: *const Snapshot,
    abort: ?*const AbortSignal,
    limits: Limits,
) error{OutOfMemory}!GitBeforeResult {
    var before = GitBefore{ .arena = std.heap.ArenaAllocator.init(gpa), .prefix = "", .index_path = "", .index_stat = null };
    var keep = false;
    defer if (!keep) before.deinit();
    const a = before.arena.allocator();

    switch (try runGit(a, root, &.{
        "rev-parse",  "--show-prefix",   "--git-path", "index",
        "--git-path", "info/attributes", "--git-path", "config",
    }, abort, limits.git_timeout_ms, 64 * 1024, null)) {
        .ok => |r| {
            var lines = std.mem.splitScalar(u8, r.out, '\n');
            before.prefix = std.mem.trimEnd(u8, lines.next() orelse "", "\r");
            const index_rel = std.mem.trimEnd(u8, lines.next() orelse "", "\r");
            const info_attributes = std.mem.trimEnd(u8, lines.next() orelse "", "\r");
            const config = std.mem.trimEnd(u8, lines.next() orelse "", "\r");
            if (index_rel.len == 0 or info_attributes.len == 0 or config.len == 0) return .none;
            before.index_path = try resolveGitPath(a, root, index_rel);
            try addSource(&before, try resolveGitPath(a, root, info_attributes));
            try addSource(&before, try resolveGitPath(a, root, config));
            // One `.gitattributes` per directory between the top and the root;
            // the root's own and those below it are in the listing.
            var up: std.ArrayList(u8) = .empty;
            var depth = std.mem.count(u8, before.prefix, "/");
            while (depth > 0) : (depth -= 1) {
                try up.appendSlice(a, "../");
                try addSource(&before, try std.fmt.allocPrintSentinel(a, "{s}/{s}.gitattributes", .{ root, up.items }, 0));
            }
        },
        .refused, .unavailable => return .none,
        .timed_out => return .timed_out,
        .aborted => return .aborted,
    }
    before.index_stat = pfs.statNoFollow(before.index_path.ptr) catch null;

    const status = switch (try runGit(a, root, &.{
        "--no-optional-locks",   "status",       "--porcelain=v2",          "-z",
        "--untracked-files=all", "--no-renames", "--ignore-submodules=all", "--",
        ".",
    }, abort, limits.git_timeout_ms, limits.max_status_bytes, null)) {
        .ok => |r| r,
        .refused, .unavailable => return .none,
        .timed_out => return .timed_out,
        .aborted => return .aborted,
    };
    // A truncated status cannot say which files are clean; without that,
    // the index is nobody's trustworthy "before".
    if (!status.complete) return .too_large;

    var copied_bytes: usize = 0;
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    var entries = std.mem.splitScalar(u8, status.out, 0);
    while (entries.next()) |entry| {
        if (entry.len < 2) continue;
        const repo_path: []const u8, const dirty = switch (entry[0]) {
            // `1 XY sub mH mI mW hH hI path`: dirty when the worktree side (Y)
            // differs from the index. Staged-only changes leave the index equal
            // to the worktree, so the index is still the "before".
            '1' => .{ fieldTail(entry, 8) orelse continue, entry.len > 3 and entry[3] != '.' },
            '2' => blk: {
                _ = entries.next(); // the original path of a rename
                break :blk .{ fieldTail(entry, 9) orelse continue, true };
            },
            'u' => .{ fieldTail(entry, 10) orelse continue, true },
            '?' => .{ entry[2..], true },
            else => continue,
        };
        if (!dirty) continue;
        if (!std.mem.startsWith(u8, repo_path, before.prefix)) continue;
        const rel = try a.dupe(u8, repo_path[before.prefix.len..]);
        try before.dirty.put(a, rel, {});

        const stat = snapshot.files.get(rel) orelse continue;
        if (before.copies.count() >= limits.max_baseline_files) continue;
        if (stat.size > limits.max_file_bytes or copied_bytes + stat.size > limits.max_baseline_bytes) continue;
        const z = joinZ(&path_buf, root, rel) orelse continue;
        switch (try readRegular(a, z, limits.max_file_bytes)) {
            .bytes => |bytes| {
                copied_bytes += bytes.len;
                try before.copies.put(a, rel, bytes);
            },
            .unavailable => {},
        }
    }
    keep = true;
    return .{ .ok = before };
}

/// The text after the first `n` space-separated fields.
fn fieldTail(entry: []const u8, n: usize) ?[]const u8 {
    var i: usize = 0;
    var seen: usize = 0;
    while (i < entry.len) : (i += 1) {
        if (entry[i] != ' ') continue;
        seen += 1;
        if (seen == n) return entry[i + 1 ..];
    }
    return null;
}

// ── Changes ────────────────────────────────────────────────────────────────

const Change = struct {
    rel: []const u8,
    from_rel: ?[]const u8 = null,
    kind: file_change.Kind,
    before: ?pfs.PathStat,
    after: ?pfs.PathStat,

    fn lessThan(_: void, x: Change, y: Change) bool {
        return std.mem.lessThan(u8, x.rel, y.rel);
    }
};

/// The file was there, untouched, before `since_ns`. POSIX ctime moves on
/// every write, rename and metadata change and no tool can set it back;
/// Windows reports no ctime here, so its creation and last write must both
/// predate it.
fn untouchedSince(stat: pfs.PathStat, since_ns: i128) bool {
    if (builtin.os.tag == .windows)
        return stat.created_ns != 0 and stat.created_ns < since_ns and stat.modified_ns < since_ns;
    return stat.changed_ns != 0 and stat.changed_ns < since_ns;
}

/// Compare two snapshots of `root`. A listing only shows what its ignore
/// rules let through, so a path's presence in one listing and absence from
/// the other is a fact about the listing until the file itself is asked:
/// a vanished path still on disk is not a deletion (an ignore rule now covers
/// it) and a new path untouched since before `since_ns` is not a creation
/// (one stopped covering it). Paths that cannot be asked add to
/// `unobserved`. Slices borrow the snapshots.
fn compare(
    gpa: std.mem.Allocator,
    root: []const u8,
    before: *const Snapshot,
    after: *const Snapshot,
    since_ns: i128,
    unobserved: *usize,
) error{OutOfMemory}![]Change {
    var changes: std.ArrayList(Change) = .empty;
    errdefer changes.deinit(gpa);
    var gone: std.ArrayList(Change) = .empty;
    defer gone.deinit(gpa);
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;

    var bit = before.files.iterator();
    while (bit.next()) |e| {
        const was = e.value_ptr.*;
        if (after.files.get(e.key_ptr.*)) |now| {
            if (!now.eql(was))
                try changes.append(gpa, .{ .rel = e.key_ptr.*, .kind = .modified, .before = was, .after = now });
            continue;
        }
        const z = joinZ(&path_buf, root, e.key_ptr.*) orelse {
            unobserved.* += 1;
            continue;
        };
        if (pfs.statNoFollow(z)) |now| {
            if (now.kind == .regular) {
                if (!now.eql(was))
                    try changes.append(gpa, .{ .rel = e.key_ptr.*, .kind = .modified, .before = was, .after = now });
                continue;
            }
            // Replaced by a directory, a link or a device: the file is gone.
        } else |err| switch (err) {
            error.NotFound => {},
            error.Unavailable => {
                unobserved.* += 1;
                continue;
            },
        }
        try gone.append(gpa, .{ .rel = e.key_ptr.*, .kind = .deleted, .before = was, .after = null });
    }

    // New paths, indexed by file identity so a vanished path can claim the
    // file it was renamed to. Identity alone is not enough — a freed inode is
    // reused — so a move also needs the same size and modification time,
    // which `rename` preserves and a fresh file does not.
    var arrived: std.ArrayList(Change) = .empty;
    defer arrived.deinit(gpa);
    const Identity = struct { device: u64, inode: u64 };
    var by_identity: std.AutoHashMapUnmanaged(Identity, usize) = .empty;
    defer by_identity.deinit(gpa);
    var ait = after.files.iterator();
    while (ait.next()) |e| {
        if (before.files.contains(e.key_ptr.*)) continue;
        try arrived.append(gpa, .{ .rel = e.key_ptr.*, .kind = .created, .before = null, .after = e.value_ptr.* });
        if (e.value_ptr.inode != 0)
            try by_identity.put(gpa, .{ .device = e.value_ptr.device, .inode = e.value_ptr.inode }, arrived.items.len - 1);
    }
    // What a vanished file looked like, for the unpaired: a new path that
    // could be one of them is reported, never explained away as old.
    const Shape = struct { size: u64, modified_ns: i128 };
    var unpaired_gone: std.AutoHashMapUnmanaged(Shape, void) = .empty;
    defer unpaired_gone.deinit(gpa);
    for (gone.items) |g| {
        const b = g.before.?;
        if (b.inode != 0) if (by_identity.get(.{ .device = b.device, .inode = b.inode })) |idx| {
            const c = &arrived.items[idx];
            if (c.kind == .created and c.after.?.size == b.size and c.after.?.modified_ns == b.modified_ns) {
                c.kind = .moved;
                c.from_rel = g.rel;
                c.before = b;
                continue;
            }
        };
        try unpaired_gone.put(gpa, .{ .size = b.size, .modified_ns = b.modified_ns }, {});
        try changes.append(gpa, g);
    }
    for (arrived.items) |c| {
        if (c.kind == .created and untouchedSince(c.after.?, since_ns) and
            !unpaired_gone.contains(.{ .size = c.after.?.size, .modified_ns = c.after.?.modified_ns }))
            continue;
        try changes.append(gpa, c);
    }
    const out = try changes.toOwnedSlice(gpa);
    std.mem.sort(Change, out, {}, Change.lessThan);
    return out;
}

fn isBinary(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, 8000)], 0) != null;
}

// ── Observation ────────────────────────────────────────────────────────────

/// The `cat-file` request is written whole before any output is read. Linux
/// shrinks a user's new pipes to a single page once `pipe-user-pages-soft` is
/// exceeded, so a request larger than that could block against cat-file's own
/// output. One page always fits.
const MAX_CAT_FILE_REQUEST_BYTES: usize = 4000;

fn missingFinalNewline(bytes: []const u8) bool {
    return bytes.len > 0 and bytes[bytes.len - 1] != '\n';
}

pub const Observation = struct {
    gpa: std.mem.Allocator,
    /// Owned; empty when `begin` could not copy it.
    root: []u8,
    limits: Limits,
    /// See `Options.confined`; borrowed for the observation's lifetime.
    confined: ?*const ToolContext = null,
    /// Wall clock when the observation began, less `Limits.clock_slack_ms`:
    /// a file untouched since then was not the command's doing.
    since_ns: i128 = 0,
    state: union(enum) {
        watching: struct { snapshot: Snapshot, git: ?GitBefore },
        gap: Gap,
    },

    /// Observe the workspace before a command. Never fails: a workspace that
    /// cannot be observed yields an Observation whose `finish` reports `lost`.
    pub fn begin(gpa: std.mem.Allocator, root: []const u8, abort: ?*const AbortSignal, options: Options) Observation {
        const limits = options.limits;
        const owned = gpa.dupe(u8, root) catch return .{ .gpa = gpa, .root = &.{}, .limits = limits, .state = .{ .gap = .out_of_memory } };
        const slack: i128 = @as(i128, limits.clock_slack_ms) * std.time.ns_per_ms;
        var self = Observation{
            .gpa = gpa,
            .root = owned,
            .limits = limits,
            .confined = options.confined,
            .since_ns = @as(i128, util_time.nowWallNs()) - slack,
            .state = .{ .gap = .listing_failed },
        };
        const remembered = breaker.get(root);
        if (remembered.too_large) {
            self.state = .{ .gap = .workspace_too_large_before };
            return self;
        }
        const started = util_time.nowMs();
        var snapshot = switch (takeSnapshot(gpa, root, abort, limits, options.confined)) {
            .ok => |s| s,
            .gap => |gap| {
                noteGap(root, gap);
                self.state = .{ .gap = gap };
                return self;
            },
        };
        var git: ?GitBefore = null;
        if (options.git_baselines and !remembered.git_slow) {
            const got = takeGitBefore(gpa, root, &snapshot, abort, limits) catch {
                snapshot.deinit(gpa);
                self.state = .{ .gap = .out_of_memory };
                return self;
            };
            switch (got) {
                .ok => |g| git = g,
                .none => {},
                .too_large => breaker.note(root, .git_too_large),
                .timed_out => breaker.note(root, .git_timeout),
                .aborted => {
                    snapshot.deinit(gpa);
                    self.state = .{ .gap = .aborted };
                    return self;
                },
            }
        }
        log.debug("bash_fc", "before: files={d} unobserved={d} git={} dirty_copies={d} ms={d}", .{
            snapshot.files.count(),
            snapshot.unobserved,
            git != null,
            if (git) |g| g.copies.count() else 0,
            util_time.nowMs() - started,
        });
        self.state = .{ .watching = .{ .snapshot = snapshot, .git = git } };
        return self;
    }

    pub fn deinit(self: *Observation) void {
        switch (self.state) {
            .watching => |*w| {
                w.snapshot.deinit(self.gpa);
                if (w.git) |*g| g.deinit();
            },
            .gap => {},
        }
        if (self.root.len > 0) self.gpa.free(self.root);
        self.* = undefined;
    }

    /// Observe the workspace again and publish every change to `sink`.
    /// `outlived` = the command was still running when this was called (it
    /// went to the background), so anything it does next is unobserved.
    pub fn finish(self: *Observation, abort: ?*const AbortSignal, sink: file_change.Sink, outlived: bool) void {
        const w = switch (self.state) {
            .watching => |*w| w,
            .gap => |gap| {
                log.debug("bash_fc", "unobserved: {s}", .{@tagName(gap)});
                sink.noteIncomplete();
                return;
            },
        };
        var after = switch (takeSnapshot(self.gpa, self.root, abort, self.limits, self.confined)) {
            .ok => |s| s,
            .gap => |gap| {
                noteGap(self.root, gap);
                log.debug("bash_fc", "after unobserved: {s}", .{@tagName(gap)});
                sink.noteIncomplete();
                return;
            },
        };
        defer after.deinit(self.gpa);
        // What is published below is true; these say it is not everything.
        if (outlived or w.snapshot.unobserved > 0 or after.unobserved > 0) sink.noteIncomplete();
        self.publishChanges(&w.snapshot, if (w.git) |*g| g else null, &after, abort, sink) catch {
            sink.noteIncomplete();
        };
    }

    fn publishChanges(
        self: *Observation,
        before: *const Snapshot,
        git: ?*const GitBefore,
        after: *const Snapshot,
        abort: ?*const AbortSignal,
        sink: file_change.Sink,
    ) error{OutOfMemory}!void {
        var unasked: usize = 0;
        const changes = try compare(self.gpa, self.root, before, after, self.since_ns, &unasked);
        defer self.gpa.free(changes);
        if (unasked > 0) sink.noteIncomplete();
        if (changes.len == 0) return;

        // Index "befores" are bounded by `max_baseline_bytes` in total.
        var baselines_state = std.heap.ArenaAllocator.init(self.gpa);
        defer baselines_state.deinit();
        const examined = @min(changes.len, self.limits.max_examined);
        // An attribute or config the command changed may have changed how a
        // blob maps to the bytes on disk: then no index blob is a known before.
        const trusted_git: ?*const GitBefore = if (git) |g| (if (g.attributesUnchanged(changes)) g else null) else null;
        const from_index = try self.indexBaselines(baselines_state.allocator(), changes[0..examined], trusted_git, abort);

        // One file's contents, LCS table and diff at a time: the arena is reset
        // between files and reuses its largest buffer, so peak memory is the
        // largest single file's worth rather than the sum over every changed
        // file. The sink copies each draft before the reset.
        var per_file_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer per_file_state.deinit();
        const per_file = per_file_state.allocator();

        const cap = file_change.MAX_FILE_CHANGES_PER_TOOL_RESULT_V1;
        var published: usize = 0;
        var next: usize = 0;
        var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        while (next < examined and published < cap) : (next += 1) {
            defer _ = per_file_state.reset(.retain_capacity);
            const change = changes[next];
            // Under a sandbox, a file the command could not open is not
            // reported at all: its path, size and contents stay inside.
            var confined_fd: ?pfs.Fd = null;
            defer if (confined_fd) |fd| pfs.close(fd);
            if (change.kind != .deleted) if (self.confined) |ctx| {
                confined_fd = self.openConfined(ctx, per_file, change.rel, change.after.?) orelse {
                    sink.noteIncomplete();
                    continue;
                };
            };
            const old: ?[]const u8 = switch (change.kind) {
                .created => "",
                .moved => null, // same size and mtime: the move carried the content
                .modified, .deleted => if (git) |g| (g.copies.get(change.rel) orelse from_index[next]) else null,
            };
            const new: ?[]const u8 = switch (change.kind) {
                .deleted => "",
                .moved => null,
                .created, .modified => blk: {
                    if (change.after.?.size > self.limits.max_file_bytes) break :blk null;
                    const read = if (confined_fd) |fd|
                        try readOpen(per_file, fd, self.limits.max_file_bytes)
                    else
                        try readRegular(per_file, joinZ(&path_buf, self.root, change.rel) orelse break :blk null, self.limits.max_file_bytes);
                    break :blk switch (read) {
                        .bytes => |b| b,
                        .unavailable => null,
                    };
                },
            };
            // Proven unchanged content (a `touch`, a rewrite of the same bytes)
            // is not a change of the file.
            if (change.kind == .modified) if (old) |o| if (new) |n| if (std.mem.eql(u8, o, n)) continue;

            var diff: ?[]const u8 = null;
            var complete = false;
            if (change.kind == .moved) {
                diff = "";
                complete = true;
            } else if (old != null and new != null and !isBinary(old.?) and !isBinary(new.?)) {
                if (try patch.computeBounded(per_file, old.?, new.?, self.limits.max_diff_cells)) |computed| {
                    var owned = computed;
                    defer owned.deinit(per_file);
                    diff = patch.toGitDiff(per_file, change.rel, owned.hunks) catch null;
                }
                if (diff) |d| {
                    if (d.len == 0) {
                        // The bytes differ but no line does: only the final
                        // newline changed, which the line diff cannot show.
                        diff = null;
                    } else {
                        // The diff carries no "\ No newline at end of file"
                        // marker, so without a final newline it is not exact.
                        complete = !missingFinalNewline(old.?) and !missingFinalNewline(new.?);
                    }
                }
            }
            // A deletion is fully stated by its kind and byte count.
            if (diff == null and change.kind == .deleted) complete = true;

            sink.publish(.{
                .path = try std.fs.path.join(per_file, &.{ self.root, change.rel }),
                .from_path = if (change.from_rel) |f| try std.fs.path.join(per_file, &.{ self.root, f }) else null,
                .kind = change.kind,
                .status = .applied,
                .before_bytes = if (change.before) |b| b.size else 0,
                .after_bytes = if (change.after) |a| a.size else 0,
                .unified_diff = diff,
                .diff_complete = complete,
            });
            published += 1;
        }
        if (next < changes.len) {
            if (published == cap) {
                // The record cap is full and more changed paths remain: one
                // more publication makes the collector record the overflow.
                const extra = changes[next];
                if (extra.kind != .deleted) if (self.confined) |ctx| {
                    const fd = self.openConfined(ctx, per_file, extra.rel, extra.after.?) orelse {
                        sink.noteIncomplete();
                        return;
                    };
                    pfs.close(fd);
                };
                sink.publish(.{
                    .path = try std.fs.path.join(per_file, &.{ self.root, extra.rel }),
                    .kind = extra.kind,
                    .status = .applied,
                    .diff_complete = false,
                });
            } else {
                // Paths past `max_examined` were never looked at.
                sink.noteIncomplete();
            }
        }
        log.debug("bash_fc", "after: changes={d} examined={d} published={d}", .{ changes.len, next, published });
    }

    /// Open `rel` read-only the way the sandboxed command would, and only if
    /// that opens the very file `seen` describes: bubblewrap hides a file by
    /// binding `/dev/null` over it, which opens fine and is something else.
    fn openConfined(self: *const Observation, ctx: *const ToolContext, scratch: std.mem.Allocator, rel: []const u8, seen: pfs.PathStat) ?pfs.Fd {
        const path = std.fs.path.join(scratch, &.{ self.root, rel }) catch return null;
        const fd = sandbox_fs.open(ctx, path, .{ .ACCMODE = .RDONLY }, 0, false) catch return null;
        const info = pfs.fileInfo(fd) catch {
            pfs.close(fd);
            return null;
        };
        if (!info.is_regular or info.device != seen.device or info.inode != seen.inode) {
            pfs.close(fd);
            return null;
        }
        return fd;
    }

    /// "Before" bytes from the index for changed files that matched it before
    /// the command. Index-sourced only while the command left the index alone:
    /// `git add`/`stash`/`checkout` inside the command would otherwise hand
    /// back its *after* as the before. Returned slice is parallel to `changes`.
    fn indexBaselines(
        self: *Observation,
        allocator: std.mem.Allocator,
        changes: []const Change,
        git: ?*const GitBefore,
        abort: ?*const AbortSignal,
    ) error{OutOfMemory}![]?[]const u8 {
        const out = try allocator.alloc(?[]const u8, changes.len);
        @memset(out, null);
        const g = git orelse return out;
        const index_then = g.index_stat orelse return out;
        const index_now = pfs.statNoFollow(g.index_path.ptr) catch return out;
        if (!index_then.eql(index_now)) return out;

        var candidates: std.ArrayList(usize) = .empty;
        var attr_request: std.ArrayList(u8) = .empty;
        var request_bytes: usize = 0;
        var expected_bytes: usize = 0;
        for (changes, 0..) |c, i| {
            if (c.kind != .modified and c.kind != .deleted) continue;
            if (g.copies.contains(c.rel) or g.dirty.contains(c.rel)) continue;
            const size = c.before.?.size;
            if (size > self.limits.max_file_bytes) continue;
            if (expected_bytes + size > self.limits.max_baseline_bytes) continue;
            if (std.mem.indexOfAny(u8, c.rel, "\n\r") != null) continue; // breaks the batch protocol
            const line = 1 + g.prefix.len + c.rel.len + 1; // `:<prefix><rel>\n`
            if (request_bytes + line > MAX_CAT_FILE_REQUEST_BYTES) continue;
            request_bytes += line;
            try attr_request.appendSlice(allocator, c.rel);
            try attr_request.append(allocator, 0);
            try candidates.append(allocator, i);
            expected_bytes += size;
        }
        if (candidates.items.len == 0) return out;

        // The index holds the cleaned form. End-of-line and `ident`
        // conversions change a file's size whenever they change its bytes, so
        // an equal-size blob is the file; a `filter` or a working-tree
        // encoding can keep the size and change every byte (UTF-16LE `中\n`
        // and its UTF-8 blob are both 4 bytes). Those files have no index
        // before.
        const attr_bytes = switch (try runGit(allocator, self.root, &.{
            "check-attr", "-z", "--stdin", "filter", "working-tree-encoding", "ident",
        }, abort, self.limits.git_timeout_ms, attr_request.items.len * 3 + candidates.items.len * 96 + 4096, attr_request.items)) {
            .ok => |r| if (r.complete) r.out else return out,
            else => return out,
        };
        var request: std.ArrayList(u8) = .empty;
        var wanted: std.ArrayList(usize) = .empty;
        var answers = std.mem.splitScalar(u8, attr_bytes, 0);
        for (candidates.items) |i| {
            var plain = true;
            for (0..3) |_| {
                const path = answers.next() orelse return out;
                _ = answers.next() orelse return out; // attribute name
                const info = answers.next() orelse return out;
                // Answers come back in request order; anything else means
                // the stream is not what was asked for.
                if (!std.mem.eql(u8, path, changes[i].rel)) return out;
                if (!std.mem.eql(u8, info, "unspecified") and !std.mem.eql(u8, info, "unset")) plain = false;
            }
            if (!plain) continue;
            try request.print(allocator, ":{s}{s}\n", .{ g.prefix, changes[i].rel });
            try wanted.append(allocator, i);
        }
        if (wanted.items.len == 0) return out;
        // Each answer is a header line plus the blob and a newline.
        const output_cap = expected_bytes + wanted.items.len * 128 + 4096;
        const bytes = switch (try runGit(allocator, self.root, &.{ "cat-file", "--batch" }, abort, self.limits.git_timeout_ms, output_cap, request.items)) {
            .ok => |r| r.out,
            else => return out,
        };
        var pos: usize = 0;
        for (wanted.items) |i| {
            const nl = std.mem.indexOfScalarPos(u8, bytes, pos, '\n') orelse break;
            const header = bytes[pos..nl];
            pos = nl + 1;
            // `<request> missing` echoes the request, which may hold spaces;
            // an object header is `<oid> <type> <size>`, none of which do.
            if (std.mem.endsWith(u8, header, " missing") or std.mem.endsWith(u8, header, " ambiguous")) continue;
            var fields = std.mem.tokenizeScalar(u8, header, ' ');
            _ = fields.next() orelse break;
            const kind = fields.next() orelse break;
            const size = std.fmt.parseInt(usize, fields.next() orelse break, 10) catch break;
            if (fields.next() != null) break; // not the shape asked for: stop trusting the stream
            if (pos + size + 1 > bytes.len) break;
            const blob = bytes[pos..][0..size];
            pos += size + 1;
            // An end-of-line or `ident` conversion makes the blob differ in
            // size from the bytes that were on disk; only an exact-size blob
            // can be the before.
            if (std.mem.eql(u8, kind, "blob") and size == changes[i].before.?.size) out[i] = blob;
        }
        return out;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const Captured = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(Record) = .empty,
    incomplete: bool = false,

    const Record = struct {
        path: []u8,
        from: ?[]u8,
        kind: file_change.Kind,
        before_bytes: u64,
        after_bytes: u64,
        diff: ?[]u8,
        diff_complete: bool,
    };

    fn deinit(self: *Captured) void {
        for (self.records.items) |r| {
            self.allocator.free(r.path);
            if (r.from) |f| self.allocator.free(f);
            if (r.diff) |d| self.allocator.free(d);
        }
        self.records.deinit(self.allocator);
    }

    fn sink(self: *Captured) file_change.Sink {
        return .{ .ctx = @ptrCast(self), .publishFn = publishFn, .incompleteFn = incompleteFn };
    }

    fn publishFn(ctx: *anyopaque, draft: file_change.Draft) void {
        const self: *Captured = @ptrCast(@alignCast(ctx));
        const base = std.fs.path.basename(draft.path);
        self.records.append(self.allocator, .{
            .path = self.allocator.dupe(u8, base) catch unreachable,
            .from = if (draft.from_path) |f| self.allocator.dupe(u8, std.fs.path.basename(f)) catch unreachable else null,
            .kind = draft.kind,
            .before_bytes = draft.before_bytes,
            .after_bytes = draft.after_bytes,
            .diff = if (draft.unified_diff) |d| self.allocator.dupe(u8, d) catch unreachable else null,
            .diff_complete = draft.diff_complete,
        }) catch unreachable;
    }

    fn incompleteFn(ctx: *anyopaque) void {
        const self: *Captured = @ptrCast(@alignCast(ctx));
        self.incomplete = true;
    }

    fn find(self: *Captured, name: []const u8) ?Record {
        for (self.records.items) |r| if (std.mem.eql(u8, r.path, name)) return r;
        return null;
    }

    fn get(self: *Captured, name: []const u8) !Record {
        return self.find(name) orelse error.TestExpectedRecord;
    }
};

const Fixture = struct {
    tmp: testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = "",

    fn init() Fixture {
        return .{ .tmp = testing.tmpDir(.{}) };
    }

    fn setup(self: *Fixture) !void {
        self.root = self.root_buf[0..try self.tmp.dir.realPath(testing.io, &self.root_buf)];
    }

    fn deinit(self: *Fixture) void {
        breaker.forget(self.root);
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, rel: []const u8, bytes: []const u8) !void {
        if (std.fs.path.dirname(rel)) |dir| try self.tmp.dir.createDirPath(testing.io, dir);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = bytes });
    }

    fn remove(self: *Fixture, rel: []const u8) !void {
        try self.tmp.dir.deleteFile(testing.io, rel);
    }

    fn rename(self: *Fixture, from: []const u8, to: []const u8) !void {
        try self.tmp.dir.rename(from, self.tmp.dir, to, testing.io);
    }

    fn git(self: *Fixture, args: []const []const u8) !void {
        var all: std.ArrayList([]const u8) = .empty;
        defer all.deinit(testing.allocator);
        try all.appendSlice(testing.allocator, &.{ "-c", "user.email=t@example.invalid", "-c", "user.name=t", "-c", "commit.gpgsign=false" });
        try all.appendSlice(testing.allocator, args);
        switch (try runGit(testing.allocator, self.root, all.items, null, 30_000, 1 << 20, null)) {
            .ok => |r| testing.allocator.free(r.out),
            else => return error.GitFailed,
        }
    }
};

/// Linux stamps inodes from a coarse clock: a write in the same tick as the
/// file's previous write keeps its timestamps, which is exactly the
/// "same-length rewrite" a snapshot can then miss. Tests leave a gap.
fn tick() void {
    util_time.sleepMs(30);
}

/// Limits for tests about what an observation reports rather than when it
/// gives up. A loaded machine (a full parallel test run) can make the bundled
/// listing or git outlast the production timeouts; that ends in an honest
/// `lost`, which is not what these tests are asking about. The gaps have
/// their own tests.
const unhurried: Limits = .{ .listing_timeout_ms = 60_000, .git_timeout_ms = 60_000 };

test "observation reports created, modified, deleted and moved files with diffs where it has both sides" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    try fx.write("keep.txt", "same\n");
    try fx.write("edit.txt", "alpha\nbeta\n");
    try fx.write("gone.txt", "bye\n");
    try fx.write("old_name.txt", "moved bytes\n");
    tick();

    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = unhurried });
    defer obs.deinit();
    try testing.expect(obs.state == .watching);

    try fx.write("edit.txt", "alpha\nBETA\n");
    try fx.write("sub/new.txt", "fresh\n");
    try fx.remove("gone.txt");
    try fx.rename("old_name.txt", "new_name.txt");

    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    try testing.expect(!got.incomplete);
    // Windows stats carry no file identity (FindFirstFileW has no file ID), so
    // there a rename is reported as the deletion and creation it looks like.
    const renames_pair = builtin.os.tag != .windows;
    try testing.expectEqual(@as(usize, if (renames_pair) 4 else 5), got.records.items.len);

    const created = try got.get("new.txt");
    try testing.expectEqual(file_change.Kind.created, created.kind);
    try testing.expectEqualStrings("--- a/sub/new.txt\n+++ b/sub/new.txt\n@@ -0,0 +1,1 @@\n+fresh\n", created.diff orelse return error.TestExpectedDiff);

    // No git: a modification has no recorded "before", so it is reported
    // without a diff rather than guessed.
    const modified = try got.get("edit.txt");
    try testing.expectEqual(file_change.Kind.modified, modified.kind);
    try testing.expect(modified.diff == null and !modified.diff_complete);
    try testing.expectEqual(@as(u64, 11), modified.before_bytes);

    const deleted = try got.get("gone.txt");
    try testing.expectEqual(file_change.Kind.deleted, deleted.kind);
    try testing.expectEqual(@as(u64, 0), deleted.after_bytes);

    const moved = try got.get("new_name.txt");
    if (renames_pair) {
        try testing.expectEqual(file_change.Kind.moved, moved.kind);
        try testing.expectEqualStrings("old_name.txt", moved.from.?);
        try testing.expectEqualStrings("", moved.diff orelse return error.TestExpectedDiff);
        try testing.expect(got.find("old_name.txt") == null);
    } else {
        try testing.expectEqual(file_change.Kind.created, moved.kind);
        try testing.expect(moved.from == null);
        try testing.expectEqualStrings("--- a/new_name.txt\n+++ b/new_name.txt\n@@ -0,0 +1,1 @@\n+moved bytes\n", moved.diff orelse return error.TestExpectedDiff);
        try testing.expectEqual(file_change.Kind.deleted, (try got.get("old_name.txt")).kind);
    }
    try testing.expect(got.find("keep.txt") == null);
}

test "observation in a git workspace diffs clean and dirty files against what was on disk" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // git + coarse-free mtimes are a POSIX fixture
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    try fx.write(".gitignore", "build/\n");
    try fx.write("clean.py", "x = 1\ny = 2\n");
    try fx.write("dirty.py", "a = 1\n");
    try fx.git(&.{"init"});
    try fx.git(&.{ "add", "-A" });
    try fx.git(&.{ "commit", "-qm", "init" });
    try fx.write("dirty.py", "a = 1\nb = 2\n"); // differs from the index before the command
    try fx.write("build/out.bin", "ignored\n");
    tick();

    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = unhurried });
    defer obs.deinit();
    try testing.expect(obs.state.watching.git != null);

    // What a python read/replace/write script does.
    try fx.write("clean.py", "x = 1\ny = 20\n");
    try fx.write("dirty.py", "a = 1\nb = 3\n");
    try fx.write("build/out.bin", "rebuilt\n");

    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    try testing.expect(!got.incomplete);
    try testing.expectEqual(@as(usize, 2), got.records.items.len); // the ignored build output is out of scope
    try testing.expectEqualStrings(
        "--- a/clean.py\n+++ b/clean.py\n@@ -1,2 +1,2 @@\n x = 1\n-y = 2\n+y = 20\n",
        (try got.get("clean.py")).diff orelse return error.TestExpectedDiff,
    );
    // The before of a dirty file is the copy taken before the command, not
    // the index (which would show `b = 2` as never having existed).
    try testing.expectEqualStrings(
        "--- a/dirty.py\n+++ b/dirty.py\n@@ -1,2 +1,2 @@\n a = 1\n-b = 2\n+b = 3\n",
        (try got.get("dirty.py")).diff orelse return error.TestExpectedDiff,
    );
}

test "an index the command changed is not trusted as the before" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    try fx.write("f.txt", "one\n");
    try fx.git(&.{"init"});
    try fx.git(&.{ "add", "-A" });
    try fx.git(&.{ "commit", "-qm", "init" });
    tick();

    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = unhurried });
    defer obs.deinit();
    try fx.write("f.txt", "two\n");
    try fx.git(&.{ "add", "f.txt" }); // the index now holds the *after*

    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    const rec = try got.get("f.txt");
    try testing.expectEqual(file_change.Kind.modified, rec.kind);
    try testing.expect(rec.diff == null and !rec.diff_complete);
}

test "a touch without new bytes is not a change when the before is known" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    try fx.write("t.txt", "same\n");
    try fx.git(&.{"init"});
    try fx.git(&.{ "add", "-A" });
    try fx.git(&.{ "commit", "-qm", "init" });
    tick();
    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = unhurried });
    defer obs.deinit();
    try fx.write("t.txt", "same\n");
    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    try testing.expectEqual(@as(usize, 0), got.records.items.len);
    try testing.expect(!got.incomplete);
}

test "an unobservable workspace says so instead of reporting nothing" {
    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    var obs = Observation.begin(testing.allocator, "/nonexistent/metacodes-observation-root", null, .{});
    defer obs.deinit();
    try testing.expect(obs.state == .gap);
    obs.finish(null, got.sink(), false);
    try testing.expect(got.incomplete);
    try testing.expectEqual(@as(usize, 0), got.records.items.len);
}

test "a workspace over the file cap is remembered and not listed again" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    try fx.write("a.txt", "a\n");
    try fx.write("b.txt", "b\n");
    var first = Observation.begin(testing.allocator, fx.root, null, .{ .limits = .{ .max_files = 1, .listing_timeout_ms = unhurried.listing_timeout_ms, .git_timeout_ms = unhurried.git_timeout_ms } });
    defer first.deinit();
    try testing.expectEqual(Gap.workspace_too_large, first.state.gap);
    // The default limits would fit, but the process already knows better.
    var second = Observation.begin(testing.allocator, fx.root, null, .{ .limits = unhurried });
    defer second.deinit();
    try testing.expectEqual(Gap.workspace_too_large_before, second.state.gap);
}

test "a workspace that cannot be listed after the command is reported lost, not unchanged" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    try fx.write("ws/a.txt", "a\n");
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "{s}/ws", .{fx.root});
    defer breaker.forget(root);
    var obs = Observation.begin(testing.allocator, root, null, .{ .limits = unhurried });
    defer obs.deinit();
    try testing.expect(obs.state == .watching);
    try fx.tmp.dir.deleteTree(testing.io, "ws"); // `cd .. && rm -rf ws`
    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    try testing.expect(got.incomplete);
    try testing.expectEqual(@as(usize, 0), got.records.items.len);
}

test "a command that outlives the observation is reported as incomplete" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    try fx.write("a.txt", "a\n");
    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = unhurried });
    defer obs.deinit();
    try fx.write("b.txt", "b\n");
    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), true);
    try testing.expect(got.incomplete);
    try testing.expectEqual(@as(usize, 1), got.records.items.len); // what it did so far still counts
}

test "VCS metadata is never a workspace change" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    try fx.write(".git/HEAD", "ref: refs/heads/main\n");
    try fx.write("nested/.git/config", "[core]\n");
    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = unhurried });
    defer obs.deinit();
    try fx.write(".git/HEAD", "ref: refs/heads/other\n");
    try fx.write("nested/.git/config", "[core]\nbare = false\n");
    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    try testing.expectEqual(@as(usize, 0), got.records.items.len);
}

test "porcelain field tails keep paths with spaces" {
    try testing.expectEqualStrings("a b.txt", fieldTail("1 .M N... 100644 100644 100644 h1 h2 a b.txt", 8).?);
    try testing.expect(fieldTail("1 .M", 8) == null);
}

fn commitAll(fx: *Fixture) !void {
    try fx.git(&.{"init"});
    try fx.git(&.{ "add", "-A" });
    try fx.git(&.{ "commit", "-qm", "init" });
}

test "touch-only rewrites do not use up the record cap or hide a later real change" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    var name_buf: [32]u8 = undefined;
    for (0..70) |i| try fx.write(try std.fmt.bufPrint(&name_buf, "a{d:0>3}.txt", .{i}), "same\n");
    try fx.write("z_last.txt", "old\n");
    try commitAll(&fx);
    tick();

    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = unhurried });
    defer obs.deinit();
    // What `sed -i` over every file does when only one of them matches.
    for (0..70) |i| try fx.write(try std.fmt.bufPrint(&name_buf, "a{d:0>3}.txt", .{i}), "same\n");
    try fx.write("z_last.txt", "new\n");

    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    try testing.expect(!got.incomplete);
    try testing.expectEqual(@as(usize, 1), got.records.items.len);
    try testing.expectEqualStrings("--- a/z_last.txt\n+++ b/z_last.txt\n@@ -1,1 +1,1 @@\n-old\n+new\n", (try got.get("z_last.txt")).diff orelse return error.TestExpectedDiff);
}

test "more real changes than the record cap end in one extra publication, which is the overflow signal" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = unhurried });
    defer obs.deinit();
    var name_buf: [32]u8 = undefined;
    const cap = file_change.MAX_FILE_CHANGES_PER_TOOL_RESULT_V1;
    for (0..cap + 5) |i| try fx.write(try std.fmt.bufPrint(&name_buf, "n{d:0>3}.txt", .{i}), "x\n");
    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    // The collector stores `cap` records and turns the next one into `overflow`.
    try testing.expectEqual(cap + 1, got.records.items.len);
    try testing.expect(got.records.items[cap].diff == null and !got.records.items[cap].diff_complete);
}

test "paths beyond the examined limit make the report incomplete" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = .{ .max_examined = 2, .listing_timeout_ms = unhurried.listing_timeout_ms, .git_timeout_ms = unhurried.git_timeout_ms } });
    defer obs.deinit();
    try fx.write("a.txt", "a\n");
    try fx.write("b.txt", "b\n");
    try fx.write("c.txt", "c\n");
    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    try testing.expectEqual(@as(usize, 2), got.records.items.len);
    try testing.expect(got.incomplete);
}

test "a diff that cannot show the final newline is not claimed complete" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    try fx.write("eol.txt", "x\n");
    try fx.write("noeol.txt", "a\nb");
    try commitAll(&fx);
    tick();
    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = unhurried });
    defer obs.deinit();
    try fx.write("eol.txt", "x"); // only the final newline goes
    try fx.write("noeol.txt", "a\nc"); // a real line change in a file without one
    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    const eol = try got.get("eol.txt");
    try testing.expect(eol.diff == null and !eol.diff_complete);
    const noeol = try got.get("noeol.txt");
    try testing.expect(noeol.diff != null and !noeol.diff_complete);
}

test "without git baselines a git workspace is still observed, only without modification diffs" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    try fx.write("f.txt", "one\n");
    try commitAll(&fx);
    tick();
    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = unhurried, .git_baselines = false });
    defer obs.deinit();
    try testing.expect(obs.state.watching.git == null);
    try fx.write("f.txt", "two\n");
    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    const rec = try got.get("f.txt");
    try testing.expectEqual(file_change.Kind.modified, rec.kind);
    try testing.expect(rec.diff == null and !rec.diff_complete);
    try testing.expect(!got.incomplete);
}

test "the breaker trips at once on size and only on a repeated timeout" {
    var b: Breaker = .{};
    b.note("/w", .listing_timeout);
    try testing.expect(!b.get("/w").too_large);
    b.note("/w", .listing_timeout);
    try testing.expect(b.get("/w").too_large);
    b.note("/v", .git_timeout);
    try testing.expect(!b.get("/v").git_slow);
    b.note("/v", .git_too_large);
    try testing.expect(b.get("/v").git_slow);
    b.note("/u", .too_large);
    try testing.expect(b.get("/u").too_large);
}

test "a path an ignore rule hides during the command is not reported deleted" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    try fx.write("build/report.txt", "report\n");
    try fx.write("keep.txt", "keep\n");
    tick();
    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = unhurried });
    defer obs.deinit();
    try fx.write(".gitignore", "build/\n");
    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    try testing.expect(!got.incomplete);
    try testing.expect(got.find("report.txt") == null);
    try testing.expectEqual(file_change.Kind.created, (try got.get(".gitignore")).kind);
    try testing.expectEqual(@as(usize, 1), got.records.items.len);
}

test "a file the command changes and hides is a modification, not a deletion" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    try fx.write("build/report.txt", "v1\n");
    tick();
    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = unhurried });
    defer obs.deinit();
    try fx.write("build/report.txt", "version two\n");
    try fx.write(".gitignore", "build/\n");
    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    const rec = try got.get("report.txt");
    try testing.expectEqual(file_change.Kind.modified, rec.kind);
    try testing.expectEqual(@as(u64, 12), rec.after_bytes);
}

test "a path an ignore rule reveals during the command is not reported created" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    try fx.write(".gitignore", "build/\n");
    try fx.write("build/old.txt", "old\n");
    tick();
    var limits = unhurried;
    limits.clock_slack_ms = 0; // the tick above is the gap
    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = limits });
    defer obs.deinit();
    try fx.write(".gitignore", "# nothing ignored\n");
    try fx.write("build/new.txt", "new\n");
    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    try testing.expect(!got.incomplete);
    try testing.expect(got.find("old.txt") == null);
    try testing.expectEqual(file_change.Kind.created, (try got.get("new.txt")).kind);
    try testing.expectEqual(file_change.Kind.modified, (try got.get(".gitignore")).kind);
    try testing.expectEqual(@as(usize, 2), got.records.items.len);
}

test "a listing that could not read every directory makes the report incomplete" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // POSIX permissions
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    try fx.write("open.txt", "o\n");
    try fx.write("locked/inner.txt", "i\n");
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const locked = joinZ(&path_buf, fx.root, "locked").?;
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(locked, 0));
    defer _ = std.c.chmod(locked, 0o755);
    // A superuser reads it anyway, and there is nothing to test.
    const probe = std.c.open(locked, .{ .ACCMODE = .RDONLY, .DIRECTORY = true });
    if (probe >= 0) {
        _ = std.c.close(probe);
        return error.SkipZigTest;
    }
    tick();
    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = unhurried });
    defer obs.deinit();
    try fx.write("open.txt", "o, changed\n");
    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    try testing.expect(got.incomplete);
    try testing.expectEqual(file_change.Kind.modified, (try got.get("open.txt")).kind);
}

/// `中\n` in UTF-16LE: four bytes, like its UTF-8 form in the index.
const UTF16LE_ZHONG = "\x2d\x4e\x0a\x00";
const UTF8_ZHONG = "\xe4\xb8\xad\n";

test "a clean file under a working-tree encoding does not take its index blob as the before" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    try fx.write(".gitattributes", "u16.txt working-tree-encoding=UTF-16LE\n");
    try fx.write("u16.txt", UTF16LE_ZHONG);
    try fx.write("plain.txt", "a\nb\n");
    try commitAll(&fx);
    tick();
    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = unhurried });
    defer obs.deinit();
    try testing.expect(obs.state.watching.git != null);
    // The index blob's exact bytes: equal to it, yet a real change.
    try fx.write("u16.txt", UTF8_ZHONG);
    try fx.write("plain.txt", "a\nc\n");
    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    const enc = try got.get("u16.txt");
    try testing.expectEqual(file_change.Kind.modified, enc.kind);
    try testing.expect(enc.diff == null and !enc.diff_complete);
    // A file without a converting attribute still gets its diff from the index.
    try testing.expectEqualStrings(
        "--- a/plain.txt\n+++ b/plain.txt\n@@ -1,2 +1,2 @@\n a\n-b\n+c\n",
        (try got.get("plain.txt")).diff orelse return error.TestExpectedDiff,
    );
}

test "attributes the command changes stop the index from standing in for the before" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    try fx.write(".gitattributes", "u16.txt working-tree-encoding=UTF-16LE\n");
    try fx.write("u16.txt", UTF16LE_ZHONG);
    try commitAll(&fx);
    tick();
    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = unhurried });
    defer obs.deinit();
    // Migrate the file to UTF-8 and drop the attribute in one command.
    try fx.write(".gitattributes", "# utf-8 now\n");
    try fx.write("u16.txt", UTF8_ZHONG);
    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    const enc = try got.get("u16.txt");
    try testing.expectEqual(file_change.Kind.modified, enc.kind);
    try testing.expect(enc.diff == null and !enc.diff_complete);
}

fn sandboxed(fx: *const Fixture, ctx: *ToolContext, sb: *@import("../sandbox/config.zig").SandboxSettings, hidden: []const []const u8) !void {
    if (comptime !@import("../sandbox/filesystem_helper.zig").supported) return error.SkipZigTest;
    if (!@import("../sandbox/exec.zig").hostSupported()) return error.SkipZigTest;
    sb.* = .{ .enabled = true, .deny_read = hidden };
    ctx.* = ToolContext.simple(testing.allocator);
    ctx.cwd_abs = fx.root;
    ctx.sandbox = sb;
}

test "under a sandbox the observation reports only what the sandbox lets the command open" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    try fx.write("secret/old.txt", "kept out\n");
    try fx.write("token.env", "TOKEN=1\n");
    try fx.write("visible.txt", "v1\n");
    var secret_buf: [std.fs.max_path_bytes]u8 = undefined;
    var token_buf: [std.fs.max_path_bytes]u8 = undefined;
    const hidden = [_][]const u8{
        try std.fmt.bufPrint(&secret_buf, "{s}/secret", .{fx.root}),
        try std.fmt.bufPrint(&token_buf, "{s}/token.env", .{fx.root}),
    };
    var sb: @import("../sandbox/config.zig").SandboxSettings = undefined;
    var ctx: ToolContext = undefined;
    try sandboxed(&fx, &ctx, &sb, &hidden);
    tick();

    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = unhurried, .git_baselines = false, .confined = &ctx });
    defer obs.deinit();
    try testing.expect(obs.state == .watching);
    // A hidden directory's files are not even listed: their deletion would
    // need no opening to be reported.
    try fx.write("secret/new.txt", "SANDBOX-HIDDEN-MARKER\n");
    try fx.remove("secret/old.txt");
    // A hidden file can be listed (Seatbelt shows its name in a readable
    // directory) but the command cannot open it.
    try fx.write("token.env", "TOKEN=SANDBOX-HIDDEN-MARKER\n");
    try fx.write("visible.txt", "v2\n");

    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    try testing.expectEqual(@as(usize, 1), got.records.items.len);
    const rec = try got.get("visible.txt");
    try testing.expectEqual(file_change.Kind.modified, rec.kind);
    for (got.records.items) |r| if (r.diff) |d| try testing.expect(std.mem.indexOf(u8, d, "SANDBOX-HIDDEN-MARKER") == null);
    // Seatbelt refuses the directory and the file, so the listing knows it
    // missed something; bubblewrap shows them empty and read-only.
    if (builtin.os.tag == .macos) try testing.expect(got.incomplete);
}

test "under a sandbox the overflow signal never names a file the command cannot open" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    try fx.write("zz.env", "a\n");
    var token_buf: [std.fs.max_path_bytes]u8 = undefined;
    const hidden = [_][]const u8{try std.fmt.bufPrint(&token_buf, "{s}/zz.env", .{fx.root})};
    var sb: @import("../sandbox/config.zig").SandboxSettings = undefined;
    var ctx: ToolContext = undefined;
    try sandboxed(&fx, &ctx, &sb, &hidden);
    tick();
    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = unhurried, .git_baselines = false, .confined = &ctx });
    defer obs.deinit();
    const cap = file_change.MAX_FILE_CHANGES_PER_TOOL_RESULT_V1;
    var name_buf: [32]u8 = undefined;
    for (0..cap) |i| try fx.write(try std.fmt.bufPrint(&name_buf, "n{d:0>3}.txt", .{i}), "x\n");
    try fx.write("zz.env", "changed\n"); // sorts after every n*.txt: the one past the cap
    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    try testing.expectEqual(cap, got.records.items.len);
    try testing.expect(got.find("zz.env") == null);
}

test "a sandbox that cannot be reached makes the call lost" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    try fx.write("a.txt", "a\n");
    // `confined` with no sandbox to run in: the listing cannot be confined.
    var ctx = ToolContext.simple(testing.allocator);
    ctx.cwd_abs = fx.root;
    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = unhurried, .git_baselines = false, .confined = &ctx });
    defer obs.deinit();
    try testing.expectEqual(Gap.listing_failed, switch (obs.state) {
        .gap => |gap| gap,
        .watching => return error.TestExpectedGap,
    });
    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    try testing.expect(got.incomplete);
    try testing.expectEqual(@as(usize, 0), got.records.items.len);
}

test "files of a renamed directory are moves, not files that were already there" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.setup();
    try fx.write("olddir/a.txt", "a\n");
    try fx.write("olddir/b.txt", "bb\n");
    tick();
    // Renaming a directory leaves its files' ctime alone: only pairing them
    // with the paths they left keeps them from passing for untouched.
    var limits = unhurried;
    limits.clock_slack_ms = 0;
    var obs = Observation.begin(testing.allocator, fx.root, null, .{ .limits = limits });
    defer obs.deinit();
    try fx.rename("olddir", "newdir");
    var got = Captured{ .allocator = testing.allocator };
    defer got.deinit();
    obs.finish(null, got.sink(), false);
    try testing.expect(!got.incomplete);
    var kinds = std.EnumArray(file_change.Kind, usize).initFill(0);
    for (got.records.items) |r| kinds.getPtr(r.kind).* += 1;
    if (builtin.os.tag == .windows) {
        // No file identity: each file is a deletion and a creation.
        try testing.expectEqual(@as(usize, 2), kinds.get(.deleted));
        try testing.expectEqual(@as(usize, 2), kinds.get(.created));
    } else {
        try testing.expectEqual(@as(usize, 2), kinds.get(.moved));
        try testing.expectEqual(@as(usize, 2), got.records.items.len);
    }
}
