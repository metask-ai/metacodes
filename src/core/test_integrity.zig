//! Test integrity obligation.
//!
//! Tests that existed when a run started are the user's record of behavior
//! that callers already depend on. A run that rewrites, deletes or disables
//! them can turn a red suite green without fixing anything. check-gate v2 saw
//! exactly that: the model changed a shared function, then edited the existing
//! assertions to match — the suite went green and the pristine tests failed.
//! Disclosure alone does not help: both runs said so in their final answer,
//! with a wrong reason (evals/experiments/test-integrity-proposal.md).
//!
//! Sensor (engineering). At run start the host records the commit `HEAD` and
//! the content of every test-suite file that is already modified or
//! untracked. At an end-of-turn boundary after the run used a tool, it
//! compares every suite file that existed then with that baseline, line by
//! line, ignoring whitespace and line order:
//!
//!   * a test case file (`test_*.py`, `*_test.go`, `*.spec.ts`, …) is
//!     weakened when an existing non-blank, non-import, non-comment line is
//!     gone or a skip/xfail/only marker was added; appending tests is fine;
//!   * any other file in the suite (`conftest.py`, runners, helpers, data
//!     under `tests/`) is weakened by any change, since it changes every test;
//!   * a deleted file, or one moved out of the suite, is weakened.
//!
//! The sensor reads the workspace, not tool events, so edits through Bash,
//! subagents and commits are all visible, and restoring the lines disarms it
//! without any declaration from the model. It never writes to the repository,
//! and it looks only below the run's working directory.
//!
//! A suite file a file tool changed that git ignores, and that existed before
//! the run, has no baseline and cannot be compared: it counts as unverified.
//! That never earns a message — there is no evidence of weakening — but it
//! taints a check-gate pass, as any file-tool change to an existing test did
//! before this sensor. (A file that is neither committed, nor snapshotted,
//! nor ignored did not exist at run start: `status -uall` lists all others.)
//!
//! Policy (pure; control-plane/lean/MetaCodesControl/TestIntegrity.lean). In
//! enforce mode, ending a turn with weakened tests earns one message, at most
//! `MAX_NUDGES` per run: restore them, or quote the sentence of the request
//! that requires each change. Observe mode only records. The budget sits
//! outside the host-injection meter: an integrity signal must not be skipped
//! because advisory nudges spent the shared allowance. Either way the final
//! state goes into the caller's `Report`, so the host tells the user itself.
//! The check gate reads the same sensor to taint a pass.
//!
//! Registered gaps: non-git workspaces; ignored files; test configuration
//! outside the suite directories (pytest.ini, package.json scripts, CI
//! files); a snapshot file that was renamed counts as deleted; an early
//! `return` appended inside a test is an addition and goes unseen.

const std = @import("std");
const pfs = @import("platform").fs;
const tool_exec = @import("tool_exec.zig");
const file_reference = @import("file_reference.zig");
const common = @import("../tools/common.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

pub const MARKER = "[test integrity]";
/// Messages per run (TestIntegrity.lean `maxNudges`).
pub const MAX_NUDGES: u8 = 1;
/// Suite files compared per scan, and snapshots kept at run start.
pub const MAX_FILES: usize = 32;
pub const MAX_FILE_BYTES: usize = 256 * 1024;
pub const MAX_LISTING_BYTES: usize = 4 * 1024 * 1024;
/// Excerpt bytes kept per finding, and shown per message.
pub const MAX_EXCERPT_BYTES: usize = 1200;
const MAX_EXCERPT_LINE_BYTES: usize = 200;
pub const GIT_TIMEOUT_MS: u64 = 10_000;

pub const Mode = enum { enforce, observe };

pub const Options = struct {
    mode: Mode,
    /// Caller-owned; filled at run end with the final state for the user.
    report: ?*Report = null,
};

/// Options from the CLI flags; null when the obligation is off. Enforce wins
/// when both modes are given (same precedence as the sibling gates).
pub fn optionsFromFlags(enforce: bool, observe: bool) ?Options {
    if (!enforce and !observe) return null;
    return .{ .mode = if (enforce) .enforce else .observe };
}

pub const Decision = enum { finish, record_only, nudge, finish_kept };

/// Pure policy; transcription of `TestIntegrity.policy`.
pub fn policy(mode: Mode, nudges: u8, weakened: bool) Decision {
    if (!weakened) return .finish;
    return switch (mode) {
        .observe => .record_only,
        .enforce => if (nudges < MAX_NUDGES) .nudge else .finish_kept,
    };
}

pub const Coverage = enum { git, no_git, git_failed };
pub const FileKind = enum { deleted, rewritten, support_changed };
pub const Outcome = enum { clean, restored, kept_cited, kept_silent, observed };

// ── Path classification ────────────────────────────────────────────────────

const CASE_PREFIXES = [_][]const u8{ "test_", "test." };
const CASE_INFIXES = [_][]const u8{ "_test.", ".test.", ".spec.", "_spec." };
const SUITE_DIRS = [_][]const u8{ "tests", "test", "__tests__", "spec" };

fn baseName(path: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[cut + 1 ..];
}

/// A file that holds test cases: appending to it is fine, removing from it
/// is not.
pub fn isTestCaseName(name: []const u8) bool {
    for (CASE_PREFIXES) |prefix| if (std.mem.startsWith(u8, name, prefix)) return true;
    for (CASE_INFIXES) |infix| if (std.mem.indexOf(u8, name, infix) != null) return true;
    return false;
}

/// Any file of the test suite: case files, `conftest.py`, and every file
/// below a `tests/`, `test/`, `__tests__/` or `spec/` directory. Paths are
/// repository-relative, `/`-separated (git output).
pub fn isSuitePath(path: []const u8) bool {
    const name = baseName(path);
    if (isTestCaseName(name) or std.mem.eql(u8, name, "conftest.py")) return true;
    var parts = std.mem.splitAny(u8, path[0 .. path.len - name.len], "/\\");
    while (parts.next()) |part| {
        for (SUITE_DIRS) |dir| if (std.mem.eql(u8, part, dir)) return true;
    }
    return false;
}

// ── Line comparison ────────────────────────────────────────────────────────

const SKIP_MARKERS = [_][]const u8{
    "@unittest.skip", "skipTest(", "pytest.mark.skip", "pytest.mark.xfail", "pytest.xfail(",
    ".skip(",         "xit(",      "xdescribe(",       "xtest(",            ".only(",
    "#[ignore",       "t.Skip(",   "@Disabled",        "@Ignore",
};

fn isImportLine(line: []const u8) bool {
    const starts = [_][]const u8{ "import ", "#include", "use ", "using ", "require(", "package " };
    for (starts) |s| if (std.mem.startsWith(u8, line, s)) return true;
    if (std.mem.startsWith(u8, line, "from ") and std.mem.indexOf(u8, line, " import ") != null) return true;
    return std.mem.indexOf(u8, line, "= require(") != null or std.mem.indexOf(u8, line, "=require(") != null;
}

fn isCommentLine(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "#")) return !std.mem.startsWith(u8, line, "#[");
    return std.mem.startsWith(u8, line, "//") or std.mem.startsWith(u8, line, "/*") or
        std.mem.startsWith(u8, line, "*");
}

fn hasSkipMarker(line: []const u8) bool {
    for (SKIP_MARKERS) |marker| if (std.mem.indexOf(u8, line, marker) != null) return true;
    return false;
}

fn mentionsAssertion(key: []const u8) bool {
    var i: usize = 0;
    while (i + 6 <= key.len) : (i += 1) {
        const window = key[i .. i + 6];
        if (std.ascii.eqlIgnoreCase(window, "assert") or std.ascii.eqlIgnoreCase(window, "expect")) return true;
    }
    return false;
}

/// The comparison key of a line: every ASCII whitespace byte removed, so
/// re-indentation and CRLF never count as a change.
fn normalize(arena: std.mem.Allocator, line: []const u8) ![]const u8 {
    var out = try arena.alloc(u8, line.len);
    var n: usize = 0;
    for (line) |c| {
        if (std.ascii.isWhitespace(c)) continue;
        out[n] = c;
        n += 1;
    }
    return out[0..n];
}

pub const Finding = struct {
    /// Repository-relative path.
    path: []u8,
    kind: FileKind,
    removed_lines: u32 = 0,
    removed_assert_lines: u32 = 0,
    added_lines: u32 = 0,
    skip_markers_added: u32 = 0,
    /// Removed (`- `) and relevant added (`+ `) lines, one per line, bounded.
    excerpt: []u8 = &.{},

    pub fn deinit(self: *Finding, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.excerpt.len > 0) allocator.free(self.excerpt);
        self.* = undefined;
    }
};

const Excerpt = struct {
    out: std.ArrayList(u8) = .empty,
    full: bool = false,

    fn add(self: *Excerpt, allocator: std.mem.Allocator, sign: u8, line: []const u8) !void {
        if (self.full) return;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        var shown = trimmed;
        if (shown.len > MAX_EXCERPT_LINE_BYTES) {
            var cut = MAX_EXCERPT_LINE_BYTES;
            while (cut > 0 and (shown[cut] & 0xC0) == 0x80) cut -= 1;
            shown = shown[0..cut];
        }
        const needed = shown.len + 3 + @as(usize, if (shown.len < trimmed.len) 4 else 0);
        if (self.out.items.len + needed > MAX_EXCERPT_BYTES) {
            self.full = true;
            return;
        }
        try self.out.append(allocator, sign);
        try self.out.append(allocator, ' ');
        try self.out.appendSlice(allocator, shown);
        if (shown.len < trimmed.len) try self.out.appendSlice(allocator, " …");
        try self.out.append(allocator, '\n');
    }
};

/// Compare one suite file's baseline content with its current content.
/// Returns a finding when the file is weakened, null when it is not.
pub fn classifyContents(
    allocator: std.mem.Allocator,
    path: []const u8,
    before: []const u8,
    after: []const u8,
) !?Finding {
    if (std.mem.eql(u8, before, after)) return null;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const case_file = isTestCaseName(baseName(path));

    // counts[key] = occurrences before − occurrences after.
    var counts = std.StringHashMap(i32).init(arena);
    var before_lines = std.mem.splitScalar(u8, before, '\n');
    while (before_lines.next()) |line| {
        const key = try normalize(arena, line);
        if (key.len == 0) continue;
        const entry = try counts.getOrPutValue(key, 0);
        entry.value_ptr.* += 1;
    }
    var after_lines = std.mem.splitScalar(u8, after, '\n');
    while (after_lines.next()) |line| {
        const key = try normalize(arena, line);
        if (key.len == 0) continue;
        const entry = try counts.getOrPutValue(key, 0);
        entry.value_ptr.* -= 1;
    }

    var finding = Finding{ .path = &.{}, .kind = if (case_file) .rewritten else .support_changed };
    var excerpt = Excerpt{};
    defer excerpt.out.deinit(allocator);
    // Removal pass: an occurrence beyond what the current content still has.
    before_lines = std.mem.splitScalar(u8, before, '\n');
    while (before_lines.next()) |line| {
        const key = try normalize(arena, line);
        if (key.len == 0) continue;
        const count = counts.getPtr(key).?;
        if (count.* <= 0) continue;
        count.* -= 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (case_file and (isImportLine(trimmed) or isCommentLine(trimmed))) continue;
        finding.removed_lines += 1;
        if (mentionsAssertion(key)) finding.removed_assert_lines += 1;
        try excerpt.add(allocator, '-', line);
    }
    // Addition pass: only the negative counts are left to settle.
    after_lines = std.mem.splitScalar(u8, after, '\n');
    while (after_lines.next()) |line| {
        const key = try normalize(arena, line);
        if (key.len == 0) continue;
        const count = counts.getPtr(key).?;
        if (count.* >= 0) continue;
        count.* += 1;
        finding.added_lines += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const marker = hasSkipMarker(trimmed);
        if (marker) finding.skip_markers_added += 1;
        if (marker or !case_file) try excerpt.add(allocator, '+', line);
    }

    const weakened = if (case_file)
        finding.removed_lines > 0 or finding.skip_markers_added > 0
    else
        finding.removed_lines > 0 or finding.added_lines > 0;
    if (!weakened) return null;
    finding.path = try allocator.dupe(u8, path);
    errdefer allocator.free(finding.path);
    finding.excerpt = try excerpt.out.toOwnedSlice(allocator);
    return finding;
}

// ── Git and workspace access ───────────────────────────────────────────────

pub const Error = error{ Aborted, OutOfMemory };

const GitResult = union(enum) {
    /// stdout, owned.
    ok: []u8,
    /// git ran and refused (not a repository, unknown revision).
    refused,
    /// git did not run or did not finish (missing binary, timeout).
    unavailable,
};

fn runGit(
    allocator: std.mem.Allocator,
    dir: ?[]const u8,
    args: []const []const u8,
    abort: ?*const AbortSignal,
    max_bytes: usize,
) Error!GitResult {
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer {
        if (argv.items.len > 2) for (argv.items[2..]) |arg| if (arg) |a| allocator.free(std.mem.span(a));
        argv.deinit(allocator);
    }
    // `/usr/bin/env git` follows PATH; the Windows backend strips the env
    // prefix and lets CreateProcessW search PATH (see agents/preload.zig).
    try argv.appendSlice(allocator, &.{ "/usr/bin/env", "git" });
    for (args) |arg| try argv.append(allocator, try allocator.dupeZ(u8, arg));
    try argv.append(allocator, null);
    const out = common.spawnCaptureWithStderrTimed(argv.items, allocator, abort, GIT_TIMEOUT_MS, null, max_bytes, dir) catch |err| switch (err) {
        error.Aborted => return error.Aborted,
        error.OutOfMemory => return error.OutOfMemory,
        else => return .unavailable,
    };
    allocator.free(out.stderr);
    if (out.exit_code != 0) {
        allocator.free(out.stdout);
        return .refused;
    }
    return .{ .ok = out.stdout };
}

const FileRead = union(enum) { content: []u8, missing, too_big, unreadable };

fn readWorkspaceFile(allocator: std.mem.Allocator, root: []const u8, rel: []const u8) Error!FileRead {
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ root, rel }, 0);
    defer allocator.free(path);
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return if (pfs.exists(path.ptr)) .unreadable else .missing;
    defer _ = pfs.close(fd);
    const info = pfs.fileInfo(fd) catch return .unreadable;
    if (!info.is_regular) return .unreadable;
    if (info.size > MAX_FILE_BYTES) return .too_big;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, buf[0..]);
        if (n < 0) {
            out.deinit(allocator);
            return .unreadable;
        }
        if (n == 0) break;
        if (out.items.len + @as(usize, @intCast(n)) > MAX_FILE_BYTES) {
            out.deinit(allocator);
            return .too_big;
        }
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return .{ .content = try out.toOwnedSlice(allocator) };
}

// ── Baseline ───────────────────────────────────────────────────────────────

const Snapshot = struct { path: []u8, content: []u8 };

/// What the test suite looked like when the run started. Never writes to the
/// repository: committed files are read back from `HEAD` later, and only the
/// files already modified or untracked are copied here.
pub const Baseline = struct {
    coverage: Coverage = .no_git,
    /// Repository top level, owned.
    root: []u8 = &.{},
    /// The working directory relative to `root`, with a trailing `/`; empty
    /// at the top level. The scans look only below it. Owned.
    prefix: []u8 = &.{},
    /// `HEAD` commit, owned; null in a repository without commits.
    head: ?[]u8 = null,
    snapshots: std.ArrayList(Snapshot) = .empty,
    /// Some suite files at run start could not be recorded (too many, too
    /// large, an oversized status listing): those stay invisible.
    overflow: bool = false,

    pub fn deinit(self: *Baseline, allocator: std.mem.Allocator) void {
        if (self.root.len > 0) allocator.free(self.root);
        if (self.prefix.len > 0) allocator.free(self.prefix);
        if (self.head) |h| allocator.free(h);
        for (self.snapshots.items) |s| {
            allocator.free(s.path);
            allocator.free(s.content);
        }
        self.snapshots.deinit(allocator);
        self.* = .{};
    }

    pub fn take(allocator: std.mem.Allocator, cwd: ?[]const u8, abort: ?*const AbortSignal) Error!Baseline {
        var base = Baseline{};
        errdefer base.deinit(allocator);
        switch (try runGit(allocator, cwd, &.{ "rev-parse", "--show-toplevel", "--show-prefix" }, abort, 64 * 1024)) {
            .ok => |out| {
                defer allocator.free(out);
                var lines = std.mem.splitScalar(u8, out, '\n');
                const top = std.mem.trim(u8, lines.next() orelse "", " \r");
                if (top.len == 0) return base;
                base.root = try allocator.dupe(u8, top);
                const prefix = std.mem.trim(u8, lines.next() orelse "", " \r");
                if (prefix.len > 0) base.prefix = try allocator.dupe(u8, prefix);
            },
            .refused => return base,
            .unavailable => {
                base.coverage = .git_failed;
                return base;
            },
        }
        switch (try runGit(allocator, base.root, &.{ "rev-parse", "--verify", "--quiet", "HEAD^{commit}" }, abort, 4096)) {
            .ok => |out| {
                defer allocator.free(out);
                const head = std.mem.trim(u8, out, " \r\n");
                if (head.len > 0) base.head = try allocator.dupe(u8, head);
            },
            .refused => {}, // no commit yet: only the snapshots count
            .unavailable => {
                base.coverage = .git_failed;
                return base;
            },
        }
        const listing = switch (try runGit(allocator, base.root, &.{ "status", "--porcelain=v1", "-z", "-uall", "--no-renames", "--", base.pathspec() }, abort, MAX_LISTING_BYTES)) {
            .ok => |out| out,
            .refused, .unavailable => {
                base.coverage = .git_failed;
                return base;
            },
        };
        defer allocator.free(listing);
        if (listing.len >= MAX_LISTING_BYTES) base.overflow = true;
        var entries = std.mem.splitScalar(u8, listing, 0);
        while (entries.next()) |entry| {
            if (entry.len < 4) continue;
            const x = entry[0];
            const y = entry[1];
            const rel = entry[3..];
            // Deleted before the run: the file did not exist when it started.
            if (x == 'D' or y == 'D' or !isSuitePath(rel)) continue;
            if (base.snapshots.items.len == MAX_FILES) {
                base.overflow = true;
                break;
            }
            switch (try readWorkspaceFile(allocator, base.root, rel)) {
                .content => |content| {
                    errdefer allocator.free(content);
                    const owned_path = try allocator.dupe(u8, rel);
                    errdefer allocator.free(owned_path);
                    try base.snapshots.append(allocator, .{ .path = owned_path, .content = content });
                },
                .missing => {},
                .too_big, .unreadable => base.overflow = true,
            }
        }
        base.coverage = .git;
        return base;
    }

    /// Pathspec for the working directory's subtree (`:/` = whole repository).
    fn pathspec(self: *const Baseline) []const u8 {
        return if (self.prefix.len > 0) self.prefix else ":/";
    }

    fn snapshotted(self: *const Baseline, rel: []const u8) bool {
        for (self.snapshots.items) |s| if (std.mem.eql(u8, s.path, rel)) return true;
        return false;
    }
};

// ── Scan ───────────────────────────────────────────────────────────────────

pub const Scan = struct {
    findings: std.ArrayList(Finding) = .empty,
    /// Some candidate files were not compared (too many, too large).
    overflow: bool = false,

    pub fn deinit(self: *Scan, allocator: std.mem.Allocator) void {
        for (self.findings.items) |*f| f.deinit(allocator);
        self.findings.deinit(allocator);
        self.* = undefined;
    }

    pub fn weakened(self: *const Scan) u32 {
        return @intCast(self.findings.items.len);
    }

    fn appendDeleted(self: *Scan, allocator: std.mem.Allocator, rel: []const u8) Error!void {
        const owned = try allocator.dupe(u8, rel);
        errdefer allocator.free(owned);
        try self.findings.append(allocator, .{ .path = owned, .kind = .deleted });
    }

    fn compare(self: *Scan, allocator: std.mem.Allocator, rel: []const u8, before: []const u8, root: []const u8) Error!void {
        switch (try readWorkspaceFile(allocator, root, rel)) {
            .content => |after| {
                defer allocator.free(after);
                if (try classifyContents(allocator, rel, before, after)) |found| {
                    var finding = found;
                    errdefer finding.deinit(allocator);
                    try self.findings.append(allocator, finding);
                }
            },
            .missing => try self.appendDeleted(allocator, rel),
            .too_big, .unreadable => self.overflow = true,
        }
    }
};

/// Compare every suite file that existed at run start with the baseline.
/// Null when there is no git baseline or git failed this time (the check
/// gate then falls back to file-tool evidence).
pub fn scan(allocator: std.mem.Allocator, baseline: *const Baseline, abort: ?*const AbortSignal) Error!?Scan {
    if (baseline.coverage != .git) return null;
    var result = Scan{ .overflow = baseline.overflow };
    errdefer result.deinit(allocator);
    var compared: usize = 0;
    if (baseline.head) |head| {
        const listing = switch (try runGit(allocator, baseline.root, &.{ "diff", "--name-status", "-z", "-M", head, "--", baseline.pathspec() }, abort, MAX_LISTING_BYTES)) {
            .ok => |out| out,
            .refused, .unavailable => {
                result.deinit(allocator);
                return null;
            },
        };
        defer allocator.free(listing);
        if (listing.len >= MAX_LISTING_BYTES) result.overflow = true;
        var tokens = std.mem.splitScalar(u8, listing, 0);
        while (tokens.next()) |status| {
            if (status.len == 0) continue;
            const old = tokens.next() orelse break;
            const new = if (status[0] == 'R' or status[0] == 'C') tokens.next() orelse break else old;
            // A file the user had already changed is compared against the
            // snapshot below, not against HEAD.
            if (!isSuitePath(old) or baseline.snapshotted(old)) continue;
            switch (status[0]) {
                'A', 'C', 'U', 'X' => continue,
                else => {},
            }
            if (compared == MAX_FILES) {
                result.overflow = true;
                break;
            }
            compared += 1;
            if (status[0] == 'D' or (status[0] == 'R' and !isSuitePath(new))) {
                try result.appendDeleted(allocator, old);
                continue;
            }
            const spec = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ head, old });
            defer allocator.free(spec);
            const before = switch (try runGit(allocator, baseline.root, &.{ "cat-file", "blob", spec }, abort, MAX_FILE_BYTES + 1)) {
                .ok => |out| out,
                .refused, .unavailable => {
                    result.overflow = true;
                    continue;
                },
            };
            defer allocator.free(before);
            if (before.len > MAX_FILE_BYTES) {
                result.overflow = true;
                continue;
            }
            try result.compare(allocator, new, before, baseline.root);
        }
    }
    for (baseline.snapshots.items) |snapshot| {
        if (compared == MAX_FILES) {
            result.overflow = true;
            break;
        }
        compared += 1;
        try result.compare(allocator, snapshot.path, snapshot.content, baseline.root);
    }
    return result;
}

// ── Run state ──────────────────────────────────────────────────────────────

const ToolPath = struct {
    /// Repository-relative. Owned.
    rel: []u8,
    /// The run's first record of this path was not a creation.
    existed: bool,
    /// Ignored by git, so the baseline cannot compare it (decided once).
    unverifiable: ?bool = null,
};

pub const State = struct {
    armed: bool = false,
    baseline: Baseline = .{},
    /// A tool ran since run start: the workspace may differ from the baseline.
    touched: bool = false,
    /// `last` reflects the workspace (no tool ran since the scan).
    scan_fresh: bool = false,
    nudges: u8 = 0,
    scans: u32 = 0,
    peak: u32 = 0,
    last: ?Scan = null,
    nudged_paths: [MAX_FILES]u64 = undefined,
    nudged_count: usize = 0,
    /// Most weakened files at a scan after the message that it did not name.
    post_nudge_new_files: u32 = 0,
    /// Whether the final answer named every file still weakened at its scan.
    final_cites_all: ?bool = null,
    /// Suite files the file tools changed, first record per path.
    tool_paths: std.ArrayList(ToolPath) = .empty,
    tool_paths_overflow: bool = false,
    /// Of those, existing before the run but without a baseline, at the last scan.
    unverified: u32 = 0,

    /// Take the baseline. An abort leaves the sensor without a verdict.
    pub fn arm(self: *State, allocator: std.mem.Allocator, cwd: ?[]const u8, abort: ?*const AbortSignal) error{OutOfMemory}!void {
        self.armed = true;
        self.baseline = Baseline.take(allocator, cwd, abort) catch |err| switch (err) {
            error.Aborted => .{ .coverage = .git_failed },
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.last) |*s| s.deinit(allocator);
        self.baseline.deinit(allocator);
        for (self.tool_paths.items) |t| allocator.free(t.rel);
        self.tool_paths.deinit(allocator);
        self.* = .{};
    }

    /// Any started tool may have changed the workspace (Task subagents, MCP
    /// tools and Bash included); the scan itself decides what changed. The
    /// file tools' own records also name the suite files they changed, for
    /// the files the baseline cannot see.
    /// Never fails: a path it cannot keep (out of memory) widens the overflow
    /// flag, which taints a check-gate pass rather than vouching for it.
    pub fn observeSlots(self: *State, allocator: std.mem.Allocator, slots: []const tool_exec.Slot) void {
        for (slots) |slot| {
            if (slot.decision != .run or slot.pending) continue;
            self.touched = true;
            self.scan_fresh = false;
            const changes = slot.file_changes orelse continue;
            for (changes) |record| {
                if (!record.status.changedDisk()) continue;
                // The first record of a path decides whether it existed
                // before the run: a file this run created is the model's own.
                self.notePath(allocator, record.locator, record.kind != .created) catch {
                    self.tool_paths_overflow = true;
                };
                if (record.from_locator) |from| self.notePath(allocator, from, true) catch {
                    self.tool_paths_overflow = true;
                };
            }
        }
    }

    fn notePath(self: *State, allocator: std.mem.Allocator, locator: file_reference.Locator, existed: bool) error{OutOfMemory}!void {
        const base = &self.baseline;
        if (base.coverage != .git) return;
        // Repository-relative; a file outside the repository is not the suite's.
        const rel = switch (locator) {
            .workspace_path => |p| try std.fmt.allocPrint(allocator, "{s}{s}", .{ base.prefix, p }),
            .absolute_path => |p| if (p.len > base.root.len + 1 and std.mem.startsWith(u8, p, base.root) and p[base.root.len] == '/')
                try allocator.dupe(u8, p[base.root.len + 1 ..])
            else
                return,
            .uri => return,
        };
        var keep = false;
        defer if (!keep) allocator.free(rel);
        if (!isSuitePath(rel)) return;
        for (self.tool_paths.items) |t| if (std.mem.eql(u8, t.rel, rel)) return;
        if (self.tool_paths.items.len == MAX_FILES) {
            self.tool_paths_overflow = true;
            return;
        }
        try self.tool_paths.append(allocator, .{ .rel = rel, .existed = existed });
        keep = true;
    }

    /// Count the suite files a file tool changed that existed before the run
    /// but that the baseline cannot compare. Decided once per path.
    fn countUnverified(self: *State, allocator: std.mem.Allocator, abort: ?*const AbortSignal) Error!u32 {
        var count: u32 = 0;
        for (self.tool_paths.items) |*t| {
            if (!t.existed) continue;
            if (t.unverifiable == null) t.unverifiable = try self.unverifiable(allocator, t.rel, abort);
            if (t.unverifiable.?) count += 1;
        }
        return count;
    }

    fn unverifiable(self: *const State, allocator: std.mem.Allocator, rel: []const u8, abort: ?*const AbortSignal) Error!bool {
        const base = &self.baseline;
        if (base.snapshotted(rel)) return false;
        if (base.head) |head| {
            const spec = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ head, rel });
            defer allocator.free(spec);
            switch (try runGit(allocator, base.root, &.{ "cat-file", "-e", spec }, abort, 4096)) {
                .ok => |out| {
                    allocator.free(out);
                    return false; // committed: the scan compares it
                },
                .refused, .unavailable => {},
            }
        }
        // Not committed and not snapshotted: either git ignores it, or it did
        // not exist when the run started (the status listing names every
        // other file). An incomplete listing proves nothing either way.
        if (base.overflow) return true;
        return switch (try runGit(allocator, base.root, &.{ "check-ignore", "-q", "--", rel }, abort, 4096)) {
            .ok => |out| blk: {
                allocator.free(out);
                break :blk true;
            },
            .refused => false,
            .unavailable => true,
        };
    }

    pub fn rescan(self: *State, allocator: std.mem.Allocator, abort: ?*const AbortSignal) Error!void {
        const next = try scan(allocator, &self.baseline, abort);
        if (self.last) |*old| old.deinit(allocator);
        self.last = next;
        self.unverified = if (next != null) try self.countUnverified(allocator, abort) else 0;
        self.scans +|= 1;
        self.scan_fresh = true;
        const now = self.weakenedNow();
        if (now > self.peak) self.peak = now;
        if (self.nudges > 0) {
            var unnamed: u32 = 0;
            if (self.last) |s| for (s.findings.items) |f| {
                if (!self.wasNamed(f.path)) unnamed += 1;
            };
            if (unnamed > self.post_nudge_new_files) self.post_nudge_new_files = unnamed;
        }
    }

    pub fn weakenedNow(self: *const State) u32 {
        return if (self.last) |s| s.weakened() else 0;
    }

    /// For the check gate's pass taint: weakened or unverified existing
    /// tests; null when the sensor has no verdict (no git, a failed scan).
    pub fn testsWeakened(self: *const State) ?bool {
        const s = self.last orelse return null;
        return s.weakened() > 0 or self.unverified > 0 or self.tool_paths_overflow;
    }

    fn wasNamed(self: *const State, path: []const u8) bool {
        const hash = std.hash.Wyhash.hash(0, path);
        for (self.nudged_paths[0..self.nudged_count]) |known| if (known == hash) return true;
        return false;
    }

    pub fn noteNudged(self: *State) void {
        self.nudges +|= 1;
        const s = self.last orelse return;
        for (s.findings.items) |f| {
            if (self.nudged_count == MAX_FILES or self.wasNamed(f.path)) continue;
            self.nudged_paths[self.nudged_count] = std.hash.Wyhash.hash(0, f.path);
            self.nudged_count += 1;
        }
    }

    /// The run ends on this answer: does it name every file still weakened?
    pub fn noteFinalAnswer(self: *State, text: []const u8) void {
        const s = self.last orelse return;
        if (!self.scan_fresh) return;
        for (s.findings.items) |f| {
            if (std.mem.indexOf(u8, text, f.path) == null and std.mem.indexOf(u8, text, baseName(f.path)) == null) {
                self.final_cites_all = false;
                return;
            }
        }
        self.final_cites_all = true;
    }

    /// Make `last` describe the final workspace when the run ended without a
    /// scan after its last tool (turn cap, abort, error). Best effort.
    pub fn settle(self: *State, allocator: std.mem.Allocator) void {
        if (!self.armed or !self.touched or self.scan_fresh) return;
        self.rescan(allocator, null) catch {
            if (self.last) |*old| old.deinit(allocator);
            self.last = null;
        };
    }

    pub fn outcome(self: *const State, mode: Mode) Outcome {
        const weakened = self.weakenedNow() > 0;
        return switch (mode) {
            .observe => if (weakened) .observed else .clean,
            .enforce => if (!weakened)
                (if (self.nudges > 0) .restored else .clean)
            else if (self.final_cites_all orelse false)
                .kept_cited
            else
                .kept_silent,
        };
    }

    pub const Totals = struct {
        removed_lines: u32 = 0,
        removed_assert_lines: u32 = 0,
        skip_markers_added: u32 = 0,
        deleted_files: u32 = 0,
        support_files_changed: u32 = 0,
    };

    pub fn totals(self: *const State) Totals {
        var t = Totals{};
        const s = self.last orelse return t;
        for (s.findings.items) |f| {
            t.removed_lines +|= f.removed_lines;
            t.removed_assert_lines +|= f.removed_assert_lines;
            t.skip_markers_added +|= f.skip_markers_added;
            switch (f.kind) {
                .deleted => t.deleted_files += 1,
                .support_changed => t.support_files_changed += 1,
                .rewritten => {},
            }
        }
        return t;
    }

    pub fn overflow(self: *const State) bool {
        if (self.baseline.overflow or self.tool_paths_overflow) return true;
        return if (self.last) |s| s.overflow else false;
    }

    /// Copy the final state into the caller's report.
    pub fn fillReport(self: *const State, report: *Report, mode: Mode) error{OutOfMemory}!void {
        report.reset();
        report.filled = true;
        report.coverage = self.baseline.coverage;
        report.outcome = self.outcome(mode);
        report.nudged = self.nudges > 0;
        report.overflow = self.overflow();
        report.unverified = self.unverified;
        const s = self.last orelse return;
        for (s.findings.items) |f| {
            const path = try report.allocator.dupe(u8, f.path);
            errdefer report.allocator.free(path);
            try report.files.append(report.allocator, .{
                .path = path,
                .kind = f.kind,
                .removed_lines = f.removed_lines,
                .added_lines = f.added_lines,
                .skip_markers_added = f.skip_markers_added,
            });
        }
    }
};

// ── Messages ───────────────────────────────────────────────────────────────

fn writeFileLine(w: *std.Io.Writer, f: *const Finding) !void {
    try w.print("- {s}: ", .{f.path});
    switch (f.kind) {
        .deleted => try w.writeAll("deleted, or moved out of the test suite\n"),
        .rewritten => {
            if (f.removed_lines > 0) try w.print("{d} existing line(s) changed or removed", .{f.removed_lines});
            if (f.removed_lines > 0 and f.skip_markers_added > 0) try w.writeAll("; ");
            if (f.skip_markers_added > 0) try w.print("{d} skip/only marker(s) added", .{f.skip_markers_added});
            try w.writeByte('\n');
        },
        .support_changed => try w.print("test support file changed ({d} line(s) removed, {d} added)\n", .{ f.removed_lines, f.added_lines }),
    }
}

/// The one message enforce mode sends. Carries only paths, counts and the
/// changed lines; no task content.
pub fn renderNudge(allocator: std.mem.Allocator, s: *const Scan) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll(MARKER ++ "\nThis run changed tests that existed before it started:\n");
    var budget: usize = MAX_EXCERPT_BYTES;
    for (s.findings.items) |*f| {
        try writeFileLine(w, f);
        if (f.excerpt.len == 0 or budget == 0) continue;
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, f.excerpt, "\n"), '\n');
        while (lines.next()) |line| {
            if (line.len + 5 > budget) {
                budget = 0;
                try w.writeAll("    …\n");
                break;
            }
            budget -= line.len + 5;
            try w.print("    {s}\n", .{line});
        }
    }
    if (s.overflow) try w.writeAll("(Some test files were too many or too large to compare.)\n");
    try w.writeAll(
        "Existing tests record behavior that callers already depend on. Change one only when the request " ++
            "explicitly asks to change the behavior that test checks. If the request asks for new behavior " ++
            "elsewhere, keep the tested behavior as it was (add a new function, parameter or code path for the " ++
            "new behavior) and restore these lines.\n" ++
            "If the request does explicitly require a change above, keep it, and in your final answer quote, for " ++
            "each file, the sentence of the request that requires it.\n" ++
            "Tests you created in this run are not affected. The host sends this once and reports the final " ++
            "state of these files to the user either way.",
    );
    return out.toOwnedSlice();
}

// ── Report (user-visible disclosure) ───────────────────────────────────────

pub const ReportFile = struct {
    path: []u8,
    kind: FileKind,
    removed_lines: u32,
    added_lines: u32,
    skip_markers_added: u32,
};

/// The final state of the suite, for the user. Filled by the agent loop at
/// run end; the host prints it (REPL notice, headless `--json` field).
pub const Report = struct {
    allocator: std.mem.Allocator,
    filled: bool = false,
    coverage: Coverage = .no_git,
    outcome: Outcome = .clean,
    nudged: bool = false,
    overflow: bool = false,
    /// Existing test files a file tool changed that had no baseline to compare.
    unverified: u32 = 0,
    files: std.ArrayList(ReportFile) = .empty,

    pub fn init(allocator: std.mem.Allocator) Report {
        return .{ .allocator = allocator };
    }

    fn reset(self: *Report) void {
        for (self.files.items) |f| self.allocator.free(f.path);
        self.files.clearRetainingCapacity();
        self.filled = false;
    }

    pub fn deinit(self: *Report) void {
        self.reset();
        self.files.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn writeJson(self: *const Report, w: *std.Io.Writer) !void {
        try w.print("{{\"coverage\":\"{s}\",\"outcome\":\"{s}\",\"nudged\":{},\"overflow\":{},\"unverified\":{d},\"files\":[", .{
            @tagName(self.coverage), @tagName(self.outcome), self.nudged, self.overflow, self.unverified,
        });
        for (self.files.items, 0..) |f, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"path\":");
            try std.json.Stringify.encodeJsonString(f.path, .{}, w);
            try w.print(",\"kind\":\"{s}\",\"removed_lines\":{d},\"added_lines\":{d},\"skip_markers_added\":{d}}}", .{
                @tagName(f.kind), f.removed_lines, f.added_lines, f.skip_markers_added,
            });
        }
        try w.writeAll("]}");
    }

    /// One notice line for an interactive host; null when there is nothing
    /// to report.
    pub fn renderNotice(self: *const Report, allocator: std.mem.Allocator) !?[]u8 {
        if (!self.filled or (self.files.items.len == 0 and self.unverified == 0)) return null;
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;
        if (self.files.items.len == 0) {
            try w.print("⚠ This run changed {d} existing test file(s) the host has no baseline for (ignored or outside the repository).", .{self.unverified});
            return try out.toOwnedSlice();
        }
        try w.writeAll("⚠ This run changed tests that existed before it started: ");
        for (self.files.items, 0..) |f, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(f.path);
            switch (f.kind) {
                .deleted => try w.writeAll(" (deleted)"),
                .rewritten => try w.print(" ({d} line(s) changed or removed, {d} skip marker(s))", .{ f.removed_lines, f.skip_markers_added }),
                .support_changed => try w.print(" (support file: -{d} +{d})", .{ f.removed_lines, f.added_lines }),
            }
        }
        try w.writeByte('.');
        if (self.unverified > 0) try w.print(" {d} more existing test file(s) had no baseline to compare.", .{self.unverified});
        return try out.toOwnedSlice();
    }
};

// ── Tests (policy names mirror TestIntegrity.lean) ─────────────────────────

const testing = std.testing;

test "pristine tests are never nudged" {
    // Lean: pristine_never_nudged.
    for ([_]Mode{ .enforce, .observe }) |mode| {
        for (0..3) |n| try testing.expect(policy(mode, @intCast(n), false) == .finish);
    }
}

test "observe mode never nudges" {
    // Lean: observe_never_nudges.
    for (0..3) |n| {
        for ([_]bool{ false, true }) |weakened| try testing.expect(policy(.observe, @intCast(n), weakened) != .nudge);
    }
    try testing.expectEqual(Decision.record_only, policy(.observe, 0, true));
}

test "a nudge needs enforce mode, weakened tests and budget" {
    // Lean: nudge_iff.
    try testing.expectEqual(Decision.nudge, policy(.enforce, 0, true));
    try testing.expectEqual(Decision.finish_kept, policy(.enforce, MAX_NUDGES, true));
    var nudges: u8 = 0;
    for (0..10) |_| {
        if (policy(.enforce, nudges, true) == .nudge) nudges += 1;
    }
    try testing.expectEqual(MAX_NUDGES, nudges); // Lean: nudges_bounded
}

test "optionsFromFlags: off without a mode; enforce wins" {
    try testing.expect(optionsFromFlags(false, false) == null);
    try testing.expectEqual(Mode.enforce, optionsFromFlags(true, true).?.mode);
    try testing.expectEqual(Mode.observe, optionsFromFlags(false, true).?.mode);
}

test "suite paths: case files, conftest and everything under a test directory" {
    try testing.expect(isSuitePath("tests/test_tokenize.py"));
    try testing.expect(isSuitePath("pkg/test_util.py"));
    try testing.expect(isSuitePath("src/lexer_test.go"));
    try testing.expect(isSuitePath("web/app.spec.ts"));
    try testing.expect(isSuitePath("conftest.py"));
    try testing.expect(isSuitePath("tests/run.py"));
    try testing.expect(isSuitePath("tests/data/events.json"));
    try testing.expect(isSuitePath("ui/__tests__/button.js"));
    try testing.expect(!isSuitePath("textkit/tokenize.py"));
    try testing.expect(!isSuitePath("contest/entry.py"));
    try testing.expect(!isSuitePath("README.md"));
    try testing.expect(isTestCaseName("test_tokenize.py"));
    try testing.expect(!isTestCaseName("run.py"));
}

fn expectFinding(before: []const u8, after: []const u8, path: []const u8) !Finding {
    return (try classifyContents(testing.allocator, path, before, after)) orelse error.TestExpectedFinding;
}

fn expectClean(before: []const u8, after: []const u8, path: []const u8) !void {
    if (try classifyContents(testing.allocator, path, before, after)) |found| {
        var f = found;
        f.deinit(testing.allocator);
        return error.TestUnexpectedFinding;
    }
}

const TOKENIZE_BEFORE =
    \\import unittest
    \\
    \\from textkit.tokenize import words
    \\
    \\
    \\class TokenizeTest(unittest.TestCase):
    \\    def test_splits_on_non_alphanumerics(self):
    \\        self.assertEqual(words("Don't stop"), ["don", "t", "stop"])
    \\
    \\    def test_empty(self):
    \\        self.assertEqual(words(""), [])
    \\
;

test "classify: a changed assertion is a rewrite, with the removed line in the excerpt" {
    const after =
        \\import unittest
        \\
        \\from textkit.tokenize import words
        \\
        \\
        \\class TokenizeTest(unittest.TestCase):
        \\    def test_joins_contractions(self):
        \\        self.assertEqual(words("Don't stop"), ["don't", "stop"])
        \\
        \\    def test_empty(self):
        \\        self.assertEqual(words(""), [])
        \\
    ;
    var f = try expectFinding(TOKENIZE_BEFORE, after, "tests/test_tokenize.py");
    defer f.deinit(testing.allocator);
    try testing.expectEqual(FileKind.rewritten, f.kind);
    try testing.expectEqual(@as(u32, 2), f.removed_lines); // the def line and the assertion
    try testing.expectEqual(@as(u32, 1), f.removed_assert_lines);
    try testing.expect(std.mem.indexOf(u8, f.excerpt, "- self.assertEqual(words(\"Don't stop\"), [\"don\", \"t\", \"stop\"])\n") != null);
    try testing.expectEqualStrings("tests/test_tokenize.py", f.path);
}

test "classify: appending tests, re-indenting, CRLF and import changes are not weakening" {
    const appended = TOKENIZE_BEFORE ++
        \\
        \\    def test_more(self):
        \\        self.assertEqual(words("a b"), ["a", "b"])
        \\
    ;
    try expectClean(TOKENIZE_BEFORE, appended, "tests/test_tokenize.py");
    const reindented = "class T:\n  def test_a(self):\n    assert f(1) == 2\n";
    try expectClean("class T:\n    def test_a(self):\n        assert f(1) == 2\n", reindented, "tests/test_a.py");
    try expectClean("assert f(1) == 2\n", "assert f(1) == 2\r\n", "tests/test_a.py");
    try expectClean("from old.place import f\nassert f(1) == 2\n", "from new.place import f\nassert f(1) == 2\n", "tests/test_a.py");
    try expectClean("# old note\nassert f(1) == 2\n", "assert f(1) == 2\n", "tests/test_a.py");
    try expectClean(TOKENIZE_BEFORE, TOKENIZE_BEFORE, "tests/test_tokenize.py");
}

test "classify: a moved block is not weakening; a duplicate removed is" {
    try expectClean("def test_a():\n    assert a()\ndef test_b():\n    assert b()\n", "def test_b():\n    assert b()\ndef test_a():\n    assert a()\n", "test_x.py");
    var f = try expectFinding("assert a()\nassert a()\n", "assert a()\n", "test_x.py");
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), f.removed_lines);
}

test "classify: an added skip marker is weakening even with nothing removed" {
    var f = try expectFinding("def test_a():\n    assert a()\n", "@pytest.mark.skip(reason=\"flaky\")\ndef test_a():\n    assert a()\n", "tests/test_a.py");
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), f.removed_lines);
    try testing.expectEqual(@as(u32, 1), f.skip_markers_added);
    try testing.expect(std.mem.indexOf(u8, f.excerpt, "+ @pytest.mark.skip") != null);
    var only = try expectFinding("it('a', () => {})\nit('b', () => {})\n", "it.only('a', () => {})\nit('b', () => {})\n", "web/a.spec.js");
    defer only.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), only.skip_markers_added);
}

test "classify: any change to a support file is weakening, additions included" {
    var f = try expectFinding("import sys\nrun()\n", "import sys\nrun()\nsys.exit(0)\n", "tests/run.py");
    defer f.deinit(testing.allocator);
    try testing.expectEqual(FileKind.support_changed, f.kind);
    try testing.expectEqual(@as(u32, 1), f.added_lines);
    try testing.expect(std.mem.indexOf(u8, f.excerpt, "+ sys.exit(0)") != null);
    var data = try expectFinding("{\"total\": 42}\n", "{\"total\": 41}\n", "tests/data/expected.json");
    defer data.deinit(testing.allocator);
    try testing.expectEqual(FileKind.support_changed, data.kind);
}

test "classify: the excerpt stays bounded" {
    var before: std.ArrayList(u8) = .empty;
    defer before.deinit(testing.allocator);
    for (0..200) |i| try before.print(testing.allocator, "assert value_{d} == {d}\n", .{ i, i });
    var f = try expectFinding(before.items, "", "tests/test_big.py");
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 200), f.removed_lines);
    try testing.expect(f.excerpt.len <= MAX_EXCERPT_BYTES);
}

test "renderNudge names files, shows changed lines and asks to restore or quote" {
    var s = Scan{};
    defer s.deinit(testing.allocator);
    const found = try expectFinding(TOKENIZE_BEFORE, "import unittest\n", "tests/test_tokenize.py");
    try s.findings.append(testing.allocator, found);
    try s.appendDeleted(testing.allocator, "tests/test_old.py");
    const text = try renderNudge(testing.allocator, &s);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, MARKER));
    try testing.expect(std.mem.indexOf(u8, text, "- tests/test_tokenize.py: ") != null);
    try testing.expect(std.mem.indexOf(u8, text, "    - self.assertEqual(words(\"Don't stop\")") != null);
    try testing.expect(std.mem.indexOf(u8, text, "- tests/test_old.py: deleted") != null);
    try testing.expect(std.mem.indexOf(u8, text, "restore these lines") != null);
    try testing.expect(std.mem.indexOf(u8, text, "quote") != null);
}

test "state: outcome follows mode, the message and the final answer" {
    var state = State{ .armed = true };
    defer state.deinit(testing.allocator);
    try testing.expectEqual(Outcome.clean, state.outcome(.enforce));
    var s = Scan{};
    try s.appendDeleted(testing.allocator, "tests/test_old.py");
    state.last = s;
    state.scan_fresh = true;
    state.peak = 1;
    try testing.expectEqual(Outcome.observed, state.outcome(.observe));
    try testing.expectEqual(Outcome.kept_silent, state.outcome(.enforce));
    state.noteNudged();
    try testing.expect(state.wasNamed("tests/test_old.py"));
    state.noteFinalAnswer("I removed test_old.py because the request retires that API.");
    try testing.expectEqual(Outcome.kept_cited, state.outcome(.enforce));
    state.noteFinalAnswer("All done.");
    try testing.expectEqual(Outcome.kept_silent, state.outcome(.enforce));
    state.last.?.deinit(testing.allocator);
    state.last = Scan{};
    try testing.expectEqual(Outcome.restored, state.outcome(.enforce));
    try testing.expectEqual(@as(?bool, false), state.testsWeakened());
}

test "report: JSON and notice carry the final files" {
    var state = State{ .armed = true, .baseline = .{ .coverage = .git } };
    defer state.deinit(testing.allocator);
    var s = Scan{};
    try s.appendDeleted(testing.allocator, "tests/test_old.py");
    state.last = s;
    var report = Report.init(testing.allocator);
    defer report.deinit();
    try state.fillReport(&report, .observe);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try report.writeJson(&aw.writer);
    try testing.expectEqualStrings(
        "{\"coverage\":\"git\",\"outcome\":\"observed\",\"nudged\":false,\"overflow\":false,\"unverified\":0,\"files\":[{\"path\":\"tests/test_old.py\",\"kind\":\"deleted\",\"removed_lines\":0,\"added_lines\":0,\"skip_markers_added\":0}]}",
        aw.written(),
    );
    const notice = (try report.renderNotice(testing.allocator)).?;
    defer testing.allocator.free(notice);
    try testing.expect(std.mem.indexOf(u8, notice, "tests/test_old.py (deleted)") != null);
    var empty = Report.init(testing.allocator);
    defer empty.deinit();
    try testing.expect((try empty.renderNotice(testing.allocator)) == null);
}
