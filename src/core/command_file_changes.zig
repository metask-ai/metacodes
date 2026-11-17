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

fn takeSnapshot(gpa: std.mem.Allocator, root: []const u8, abort: ?*const AbortSignal, limits: Limits) SnapshotResult {
    const rg = toolchain.ripgrepPath() catch return .{ .gap = .listing_failed };
    const argv = [_]?[*:0]const u8{
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
        null,
    };
    const captured = common.captureWithSpawnRetry(&argv, gpa, .{
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
    // flag can never pass for an empty workspace.
    switch (captured.exit_code) {
        0, 1 => {},
        2 => if (listing.len == 0) return .{ .gap = .listing_failed },
        else => return .{ .gap = .listing_failed },
    }

    var files: std.StringHashMapUnmanaged(pfs.PathStat) = .empty;
    errdefer files.deinit(gpa);
    const count = std.mem.count(u8, listing, "\x00");
    if (count > limits.max_files) return .{ .gap = .workspace_too_large };
    files.ensureTotalCapacity(gpa, @intCast(count)) catch return .{ .gap = .out_of_memory };

    var unobserved: usize = 0;
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    var it = std.mem.splitScalar(u8, listing, 0);
    while (it.next()) |rel| {
        if (rel.len == 0) continue;
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

    fn deinit(self: *GitBefore) void {
        self.arena.deinit();
    }
};

const Read = union(enum) { bytes: []u8, unavailable };

/// Read a regular file without following a final symlink, refusing anything
/// over `max_bytes`.
fn readRegular(allocator: std.mem.Allocator, path_z: [*:0]const u8, max_bytes: usize) error{OutOfMemory}!Read {
    const fd = pfs.open(path_z, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return .unavailable;
    defer pfs.close(fd);
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

    switch (try runGit(a, root, &.{ "rev-parse", "--show-prefix", "--git-path", "index" }, abort, limits.git_timeout_ms, 64 * 1024, null)) {
        .ok => |r| {
            var lines = std.mem.splitScalar(u8, r.out, '\n');
            before.prefix = std.mem.trimEnd(u8, lines.next() orelse "", "\r");
            const index_rel = std.mem.trimEnd(u8, lines.next() orelse "", "\r");
            if (index_rel.len == 0) return .none;
            before.index_path = if (std.fs.path.isAbsolute(index_rel))
                try a.dupeZ(u8, index_rel)
            else
                try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ root, index_rel }, 0);
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

/// Pure comparison of two snapshots. Slices borrow the snapshots.
fn compare(gpa: std.mem.Allocator, before: *const Snapshot, after: *const Snapshot) error{OutOfMemory}![]Change {
    var changes: std.ArrayList(Change) = .empty;
    errdefer changes.deinit(gpa);
    var gone: std.ArrayList(Change) = .empty;
    defer gone.deinit(gpa);

    var bit = before.files.iterator();
    while (bit.next()) |e| {
        if (after.files.get(e.key_ptr.*)) |now| {
            if (!now.eql(e.value_ptr.*))
                try changes.append(gpa, .{ .rel = e.key_ptr.*, .kind = .modified, .before = e.value_ptr.*, .after = now });
        } else {
            try gone.append(gpa, .{ .rel = e.key_ptr.*, .kind = .deleted, .before = e.value_ptr.*, .after = null });
        }
    }

    // New paths, indexed by file identity so a vanished path can claim the
    // file it was renamed to. Identity alone is not enough — a freed inode is
    // reused — so a move also needs the same size and modification time,
    // which `rename` preserves and a fresh file does not.
    const Identity = struct { device: u64, inode: u64 };
    var arrived: std.AutoHashMapUnmanaged(Identity, usize) = .empty;
    defer arrived.deinit(gpa);
    var ait = after.files.iterator();
    while (ait.next()) |e| {
        if (before.files.contains(e.key_ptr.*)) continue;
        try changes.append(gpa, .{ .rel = e.key_ptr.*, .kind = .created, .before = null, .after = e.value_ptr.* });
        if (e.value_ptr.inode != 0)
            try arrived.put(gpa, .{ .device = e.value_ptr.device, .inode = e.value_ptr.inode }, changes.items.len - 1);
    }
    for (gone.items) |g| {
        const b = g.before.?;
        if (b.inode != 0) if (arrived.get(.{ .device = b.device, .inode = b.inode })) |idx| {
            const c = &changes.items[idx];
            if (c.kind == .created and c.after.?.size == b.size and c.after.?.modified_ns == b.modified_ns) {
                c.kind = .moved;
                c.from_rel = g.rel;
                c.before = b;
                continue;
            }
        };
        try changes.append(gpa, g);
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
    state: union(enum) {
        watching: struct { snapshot: Snapshot, git: ?GitBefore },
        gap: Gap,
    },

    /// Observe the workspace before a command. Never fails: a workspace that
    /// cannot be observed yields an Observation whose `finish` reports `lost`.
    pub fn begin(gpa: std.mem.Allocator, root: []const u8, abort: ?*const AbortSignal, options: Options) Observation {
        const limits = options.limits;
        const owned = gpa.dupe(u8, root) catch return .{ .gpa = gpa, .root = &.{}, .limits = limits, .state = .{ .gap = .out_of_memory } };
        var self = Observation{ .gpa = gpa, .root = owned, .limits = limits, .state = .{ .gap = .listing_failed } };
        const remembered = breaker.get(root);
        if (remembered.too_large) {
            self.state = .{ .gap = .workspace_too_large_before };
            return self;
        }
        const started = util_time.nowMs();
        var snapshot = switch (takeSnapshot(gpa, root, abort, limits)) {
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
        var after = switch (takeSnapshot(self.gpa, self.root, abort, self.limits)) {
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
        const changes = try compare(self.gpa, before, after);
        defer self.gpa.free(changes);
        if (changes.len == 0) return;

        // Index "befores" are bounded by `max_baseline_bytes` in total.
        var baselines_state = std.heap.ArenaAllocator.init(self.gpa);
        defer baselines_state.deinit();
        const examined = @min(changes.len, self.limits.max_examined);
        const from_index = try self.indexBaselines(baselines_state.allocator(), changes[0..examined], git, abort);

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
                    const z = joinZ(&path_buf, self.root, change.rel) orelse break :blk null;
                    break :blk switch (try readRegular(per_file, z, self.limits.max_file_bytes)) {
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

        var request: std.ArrayList(u8) = .empty;
        var wanted: std.ArrayList(usize) = .empty;
        var expected_bytes: usize = 0;
        for (changes, 0..) |c, i| {
            if (c.kind != .modified and c.kind != .deleted) continue;
            if (g.copies.contains(c.rel) or g.dirty.contains(c.rel)) continue;
            const size = c.before.?.size;
            if (size > self.limits.max_file_bytes) continue;
            if (expected_bytes + size > self.limits.max_baseline_bytes) continue;
            if (std.mem.indexOfAny(u8, c.rel, "\n\r") != null) continue; // breaks the batch protocol
            if (request.items.len + g.prefix.len + c.rel.len + 2 > MAX_CAT_FILE_REQUEST_BYTES) continue;
            try request.print(allocator, ":{s}{s}\n", .{ g.prefix, c.rel });
            try wanted.append(allocator, i);
            expected_bytes += size;
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
            // A clean/smudge filter (CRLF, LFS) makes the index blob differ
            // from the bytes that were on disk; only an exact-size blob can be
            // the before.
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
    try testing.expectEqual(@as(usize, 4), got.records.items.len);

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
    try testing.expectEqual(file_change.Kind.moved, moved.kind);
    try testing.expectEqualStrings("old_name.txt", moved.from.?);
    try testing.expectEqualStrings("", moved.diff orelse return error.TestExpectedDiff);
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
