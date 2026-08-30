//! Stable, host-neutral contract for what a Run's file-modifying tools
//! actually changed on disk.
//!
//! Requirement: `doc/frommetawork/CORE_FILE_CHANGE_OBSERVABILITY_REQUIREMENT.md`.
//!
//! Two things already existed and neither answers "what changed":
//!
//!   - `file_reference.FileReference` names the files a tool *touched*. It has
//!     no before/after and no per-file outcome.
//!   - `tools/observation.FileMutationV1` is audit evidence: SHA-256
//!     commitments and byte counts, deliberately without the plaintext path or
//!     content, and capped at one target per dispatch.
//!
//! Consumers therefore scraped `gitDiff` out of `tool_result.content`. That
//! field is a tool-private rendering detail: it is absent on `Read`, reshaped
//! per tool, dropped when a result is spilled to an artifact, and free to
//! change whenever a tool's result JSON changes. This module is the supported
//! replacement.
//!
//! **Shape.** A tool publishes one `Draft` per affected file at the moment it
//! knows the outcome for that file; the per-dispatch `Collector` copies it out
//! of the tool's arena into the parent allocator immediately. Once the turn's
//! tools have run, the agent loop drains every slot at a single choke point —
//! emitting `CoreEvent.file_changes` and appending to the optional `Journal` —
//! *before* any branch that could return early. Suspension, a host-fatal tool
//! and a failed result assembly all happen after bytes may already be on disk,
//! so evidence that is not collected there is evidence silently lost.
//!
//! Sub executions (Agent / Skill / TaskBatch) inherit the same Journal pointer,
//! so their changes land in the same place with their own `agent_depth`.
//!
//! **What is out of scope**, per the requirement: preview/aggregation/UI,
//! review verdicts, and filesystem changes made by `Bash` or any other
//! arbitrary command — this contract covers the typed file tools only, and
//! says so rather than pretending to be complete.

const std = @import("std");
const file_reference = @import("file_reference.zig");
const ToolContext = @import("../tools/context.zig").ToolContext;
// 裁剪 std 无 Thread.Mutex;全仓惯例走 platform.sync(pthread 包装)。
const sync = @import("platform").sync;

/// Stamped into the JSON projection so a consumer can tell which field set it
/// is reading. Following the repo convention (see `core/rule_source_receipt.zig`):
/// a schema version that is declared but never carried is decoration, not a
/// contract — `writeJsonEnvelope` is what makes this one real.
pub const SCHEMA_VERSION = "metacodes-file-change-v1";

/// One tool call may legitimately touch many files (`ApplyPatch`). Beyond this
/// the collector stops copying and sets `overflow`; it never silently drops.
pub const MAX_FILE_CHANGES_PER_TOOL_RESULT_V1: usize = 64;
/// Per-file diff retention. A larger change still reports its byte counts and
/// status with `diff_complete = false`.
pub const MAX_UNIFIED_DIFF_BYTES_V1: usize = 256 * 1024;
/// Journal retention across a whole Run.
pub const MAX_JOURNAL_ENTRIES_V1: usize = 4096;
/// Total diff bytes a Journal keeps. A REPL session accumulates across turns,
/// so the entry cap alone is not a memory bound (4096 × 256 KB is not a bound
/// anyone wants). Past this the journal keeps recording *which* files changed
/// and how, but stops retaining diff text and marks itself truncated.
pub const MAX_JOURNAL_DIFF_BYTES_V1: usize = 8 * 1024 * 1024;

/// What happened to the file itself.
pub const Kind = enum {
    created,
    modified,
    deleted,
    /// Content moved to `locator`; `from_locator` holds the vacated path. The
    /// move may also change content, in which case the diff describes it.
    moved,
};

/// Whether the intended change reached the filesystem. `partial` exists
/// because a multi-file tool can commit some files and fail on a later one.
pub const Status = enum {
    /// Committed to disk.
    applied,
    /// The tool ran and the target ended byte-identical to how it started.
    no_change,
    /// The tool attempted this file and failed.
    failed,
    /// Permission, policy, or a formal gate refused before anything was
    /// written. Nothing on disk changed.
    rejected,
    /// This file was part of a batch that did not complete; whether its own
    /// bytes landed is stated by `before_bytes`/`after_bytes`, not assumed.
    partial,

    /// Whether disk contents differ from before the call.
    pub fn changedDisk(self: Status) bool {
        return self == .applied or self == .partial;
    }
};

/// Borrowed view a tool publishes. Every slice may live in the tool's arena;
/// the collector copies what it keeps before returning.
pub const Draft = struct {
    /// The path the tool actually operated on, already normalized by the tool.
    path: []const u8,
    /// Vacated path for `.moved`.
    from_path: ?[]const u8 = null,
    kind: Kind,
    status: Status,
    before_bytes: u64 = 0,
    after_bytes: u64 = 0,
    /// Unified diff of this file's change, or null when the tool could not
    /// produce one (binary, oversized, or a failure before any content was
    /// computed). Absence is information, not an error.
    unified_diff: ?[]const u8 = null,
    /// False when the diff was truncated or omitted while a real change
    /// happened, so a consumer never renders a partial diff as the whole
    /// change.
    diff_complete: bool = true,
};

/// One recorded change. All slices are owned by the record's allocator.
pub const Record = struct {
    locator: file_reference.Locator,
    from_locator: ?file_reference.Locator = null,
    kind: Kind,
    status: Status,
    /// Dispatched tool name, e.g. "Write" / "Edit" / "NotebookEdit" / "ApplyPatch".
    tool: []const u8,
    /// The `tool_use` id this change belongs to, so a consumer can pair it with
    /// the tool card it is already showing.
    tool_use_id: []const u8,
    /// 0 = the Run's own agent; >0 = a sub execution (Agent / Skill).
    agent_depth: u8,
    before_bytes: u64,
    after_bytes: u64,
    unified_diff: ?[]const u8 = null,
    diff_complete: bool = true,

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        freeLocator(allocator, self.locator);
        if (self.from_locator) |loc| freeLocator(allocator, loc);
        allocator.free(self.tool);
        allocator.free(self.tool_use_id);
        if (self.unified_diff) |d| allocator.free(d);
        self.* = undefined;
    }

    pub fn clone(self: Record, allocator: std.mem.Allocator) !Record {
        var out = Record{
            .locator = try cloneLocator(allocator, self.locator),
            .from_locator = null,
            .kind = self.kind,
            .status = self.status,
            .tool = &.{},
            .tool_use_id = &.{},
            .agent_depth = self.agent_depth,
            .before_bytes = self.before_bytes,
            .after_bytes = self.after_bytes,
            .unified_diff = null,
            .diff_complete = self.diff_complete,
        };
        errdefer freeLocator(allocator, out.locator);
        if (self.from_locator) |loc| out.from_locator = try cloneLocator(allocator, loc);
        errdefer if (out.from_locator) |loc| freeLocator(allocator, loc);
        out.tool = try allocator.dupe(u8, self.tool);
        errdefer allocator.free(out.tool);
        out.tool_use_id = try allocator.dupe(u8, self.tool_use_id);
        errdefer allocator.free(out.tool_use_id);
        if (self.unified_diff) |d| out.unified_diff = try allocator.dupe(u8, d);
        return out;
    }

    /// Path text of the locator, whichever variant it is. Handy for consumers
    /// that only want to display or group by path.
    pub fn path(self: Record) []const u8 {
        return switch (self.locator) {
            inline else => |value| value,
        };
    }
};

fn freeLocator(allocator: std.mem.Allocator, locator: file_reference.Locator) void {
    switch (locator) {
        inline else => |value| allocator.free(value),
    }
}

fn cloneLocator(allocator: std.mem.Allocator, locator: file_reference.Locator) !file_reference.Locator {
    return switch (locator) {
        .workspace_path => |v| .{ .workspace_path = try allocator.dupe(u8, v) },
        .absolute_path => |v| .{ .absolute_path = try allocator.dupe(u8, v) },
        .uri => |v| .{ .uri = try allocator.dupe(u8, v) },
    };
}

pub fn freeRecords(allocator: std.mem.Allocator, records: []Record) void {
    for (records) |*r| r.deinit(allocator);
    allocator.free(records);
}

/// Publication capability handed to a tool through `ToolContext`. It is a
/// reporting channel only: publishing cannot authorize anything, and a tool
/// that publishes nothing is not thereby exempt — the dispatch seam synthesizes
/// a record for a refused or failed file tool.
pub const Sink = struct {
    ctx: *anyopaque,
    publishFn: *const fn (ctx: *anyopaque, draft: Draft) void,

    pub fn publish(self: Sink, draft: Draft) void {
        self.publishFn(self.ctx, draft);
    }
};

/// Per-dispatch accumulator installed by `tool_exec.executeOne`. It copies each
/// draft into `allocator` (the parent allocator) so records outlive the tool's
/// arena.
///
/// Recording never fails a tool: a copy that cannot be made sets `lost`, and an
/// over-cap publication sets `overflow`. Both travel with the result so a
/// consumer can say "incomplete" instead of quietly showing less than happened.
pub const Collector = struct {
    allocator: std.mem.Allocator,
    ctx: *const ToolContext,
    tool: []const u8,
    tool_use_id: []const u8,
    agent_depth: u8,
    items: std.ArrayList(Record) = .empty,
    overflow: bool = false,
    lost: bool = false,

    pub fn sink(self: *Collector) Sink {
        return .{ .ctx = @ptrCast(self), .publishFn = publishTrampoline };
    }

    fn publishTrampoline(ctx: *anyopaque, draft: Draft) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        self.publish(draft);
    }

    pub fn publish(self: *Collector, draft: Draft) void {
        if (self.items.items.len >= MAX_FILE_CHANGES_PER_TOOL_RESULT_V1) {
            self.overflow = true;
            return;
        }
        const record = self.build(draft) catch {
            self.lost = true;
            return;
        };
        var owned = record;
        self.items.append(self.allocator, owned) catch {
            owned.deinit(self.allocator);
            self.lost = true;
        };
    }

    fn build(self: *Collector, draft: Draft) !Record {
        const target = (try file_reference.classifyPath(self.allocator, self.ctx, draft.path, .unobserved)) orelse
            return error.UnclassifiablePath;
        defer self.allocator.free(target.path);
        const locator = try locatorFor(self.allocator, target);
        errdefer freeLocator(self.allocator, locator);

        var from_locator: ?file_reference.Locator = null;
        errdefer if (from_locator) |loc| freeLocator(self.allocator, loc);
        if (draft.from_path) |from| {
            if (try file_reference.classifyPath(self.allocator, self.ctx, from, .unobserved)) |from_target| {
                defer self.allocator.free(from_target.path);
                from_locator = try locatorFor(self.allocator, from_target);
            }
        }

        const tool = try self.allocator.dupe(u8, self.tool);
        errdefer self.allocator.free(tool);
        const tool_use_id = try self.allocator.dupe(u8, self.tool_use_id);
        errdefer self.allocator.free(tool_use_id);

        var diff_complete = draft.diff_complete;
        var diff: ?[]const u8 = null;
        if (draft.unified_diff) |raw| {
            if (raw.len > MAX_UNIFIED_DIFF_BYTES_V1) {
                diff = try self.allocator.dupe(u8, raw[0..MAX_UNIFIED_DIFF_BYTES_V1]);
                diff_complete = false;
            } else {
                diff = try self.allocator.dupe(u8, raw);
            }
        } else if (draft.status.changedDisk() and draft.kind != .deleted) {
            // A real content change with no diff attached is incomplete
            // evidence; say so rather than letting the consumer read the
            // missing diff as "nothing changed".
            diff_complete = false;
        }

        return .{
            .locator = locator,
            .from_locator = from_locator,
            .kind = draft.kind,
            .status = draft.status,
            .tool = tool,
            .tool_use_id = tool_use_id,
            .agent_depth = self.agent_depth,
            .before_bytes = draft.before_bytes,
            .after_bytes = draft.after_bytes,
            .unified_diff = diff,
            .diff_complete = diff_complete,
        };
    }

    /// Transfer the collected records to the caller. The collector is **always**
    /// left empty — including when the transfer itself fails — so a later
    /// `deinit` is a no-op, a caller without a `defer deinit` cannot leak, and a
    /// double free is impossible. A failed transfer sets `lost`; it never
    /// silently reports "nothing changed".
    pub fn toOwnedSlice(self: *Collector) ?[]Record {
        if (self.items.items.len == 0) return null;
        return self.items.toOwnedSlice(self.allocator) catch {
            for (self.items.items) |*r| r.deinit(self.allocator);
            self.items.clearRetainingCapacity();
            self.lost = true;
            return null;
        };
    }

    pub fn deinit(self: *Collector) void {
        for (self.items.items) |*r| r.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }
};

fn locatorFor(
    allocator: std.mem.Allocator,
    target: file_reference.ResolvedFileTarget,
) !file_reference.Locator {
    return switch (target.locator_kind) {
        .workspace_path => .{ .workspace_path = try allocator.dupe(u8, target.path) },
        .absolute_path => .{ .absolute_path = try allocator.dupe(u8, target.path) },
        .uri => .{ .uri = try allocator.dupe(u8, target.path) },
    };
}

/// Run-scoped accumulation of every file change, including those made by sub
/// executions. The caller owns it and passes a pointer via
/// `agent_loop.Options.file_change_journal`.
///
/// Background subagents and swarm teammates run on their own threads and share
/// the parent's Journal pointer, so every entry point takes the mutex.
///
/// **Allocator contract**: the mutex serializes this journal's own calls, but
/// it cannot make the *allocator* thread-safe, so a journal shared with
/// background execution must be constructed with one that is.
///
/// The App allocator would in fact qualify — it is `std.process.Init`'s arena
/// (`main.zig`), and Zig 0.16's `ArenaAllocator` is threadsafe given a
/// threadsafe child, which `page_allocator` is; every vtable entry drives
/// `end_index` through `@atomicRmw`/`@cmpxchgStrong`. (An earlier version of
/// this comment claimed "the App GPA is not thread-safe"; it is neither a GPA
/// nor unsafe. Verify against the installed std before acting on either
/// claim.) The reason production still passes `std.heap.c_allocator` is
/// **reclamation, not safety**: an arena cannot free anything but its most
/// recent allocation, so the entry and diff-byte caps below — which exist
/// because a REPL journal accumulates across turns — would cap what is
/// *retained* while never returning a byte.
pub const Journal = struct {
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    items: std.ArrayList(Record) = .empty,
    /// Diff bytes currently retained, against `MAX_JOURNAL_DIFF_BYTES_V1`.
    diff_bytes: usize = 0,
    /// Entries or diff text were dropped (a cap was reached or a copy failed).
    /// What is retained is a subset of the truth and must be presented as such.
    truncated: bool = false,

    pub fn init(allocator: std.mem.Allocator) Journal {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Journal) void {
        for (self.items.items) |*r| r.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    /// Append clones of `records`. Best effort: never fails the Run.
    pub fn recordAll(self: *Journal, records: []const Record) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (records) |r| {
            if (self.items.items.len >= MAX_JOURNAL_ENTRIES_V1) {
                self.truncated = true;
                return;
            }
            // Over budget: keep the fact of the change, drop only its text.
            var source = r;
            const diff_len = if (r.unified_diff) |d| d.len else 0;
            if (diff_len != 0 and self.diff_bytes + diff_len > MAX_JOURNAL_DIFF_BYTES_V1) {
                source.unified_diff = null;
                source.diff_complete = false;
                self.truncated = true;
            }
            var copy = source.clone(self.allocator) catch {
                self.truncated = true;
                return;
            };
            self.items.append(self.allocator, copy) catch {
                copy.deinit(self.allocator);
                self.truncated = true;
                return;
            };
            if (copy.unified_diff) |d| self.diff_bytes += d.len;
        }
    }

    /// Mark that a producer could not report everything it changed.
    pub fn noteTruncated(self: *Journal) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.truncated = true;
    }

    /// Drop every retained record. Used when a session resets its transcript
    /// (`/clear`): the journal describes the session it belongs to, and keeping
    /// changes from a discarded conversation would misreport it.
    pub fn reset(self: *Journal) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |*r| r.deinit(self.allocator);
        self.items.clearRetainingCapacity();
        self.diff_bytes = 0;
        self.truncated = false;
    }

    pub fn count(self: *Journal) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.items.items.len;
    }

    /// Borrow the accumulated records **while holding the journal lock**. A
    /// background subagent shares this journal and may still be appending, so
    /// there is deliberately no lock-free accessor that could hand out a slice
    /// an append then reallocates.
    ///
    ///     const records = journal.acquire();
    ///     defer journal.release();
    pub fn acquire(self: *Journal) []const Record {
        self.mutex.lock();
        return self.items.items;
    }

    pub fn release(self: *Journal) void {
        self.mutex.unlock();
    }
};

/// Stable JSON projection of a record set. This is the wire form for consumers
/// that are not linked against Zig types (headless `--json`, an out-of-process
/// UI). Field names are part of the v1 contract; `locator_kind` says how to read
/// `path` (workspace-relative / absolute / URI).
pub fn writeJsonEnvelope(w: *std.Io.Writer, records: []const Record, truncated: bool) !void {
    try w.writeAll("{\"schema_version\":\"" ++ SCHEMA_VERSION ++ "\",\"truncated\":");
    try w.print("{},\"changes\":", .{truncated});
    try writeJsonArray(w, records);
    try w.writeByte('}');
}

pub fn writeJsonArray(w: *std.Io.Writer, records: []const Record) !void {
    try w.writeByte('[');
    for (records, 0..) |rec, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"path\":");
        try std.json.Stringify.encodeJsonString(rec.path(), .{}, w);
        try w.writeAll(",\"locator_kind\":\"");
        try w.writeAll(@tagName(rec.locator));
        try w.writeAll("\"");
        if (rec.from_locator) |from| {
            try w.writeAll(",\"from_path\":");
            try std.json.Stringify.encodeJsonString(switch (from) {
                inline else => |value| value,
            }, .{}, w);
        }
        try w.print(
            ",\"kind\":\"{s}\",\"status\":\"{s}\",\"agent_depth\":{d},\"before_bytes\":{d},\"after_bytes\":{d},\"diff_complete\":{}",
            .{ @tagName(rec.kind), @tagName(rec.status), rec.agent_depth, rec.before_bytes, rec.after_bytes, rec.diff_complete },
        );
        try w.writeAll(",\"tool\":");
        try std.json.Stringify.encodeJsonString(rec.tool, .{}, w);
        try w.writeAll(",\"tool_use_id\":");
        try std.json.Stringify.encodeJsonString(rec.tool_use_id, .{}, w);
        if (rec.unified_diff) |d| {
            try w.writeAll(",\"unified_diff\":");
            try std.json.Stringify.encodeJsonString(d, .{}, w);
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

// ---------------------------------------------------------------------------
// L1 tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testCollector(a: std.mem.Allocator, ctx: *const ToolContext) Collector {
    return .{
        .allocator = a,
        .ctx = ctx,
        .tool = "Write",
        .tool_use_id = "tu-1",
        .agent_depth = 0,
    };
}

test "collector: a workspace write is classified relative and carries its diff" {
    const a = testing.allocator;
    var ctx = ToolContext{ .allocator = a, .cwd_abs = "/work", .resolve_relative_paths = true };
    var collector = testCollector(a, &ctx);
    defer collector.deinit();

    collector.sink().publish(.{
        .path = "/work/src/main.zig",
        .kind = .created,
        .status = .applied,
        .before_bytes = 0,
        .after_bytes = 12,
        .unified_diff = "--- a\n+++ b\n@@ -0,0 +1 @@\n+hi\n",
    });

    try testing.expectEqual(@as(usize, 1), collector.items.items.len);
    const rec = collector.items.items[0];
    try testing.expectEqualStrings("src/main.zig", rec.locator.workspace_path);
    try testing.expectEqualStrings("src/main.zig", rec.path());
    try testing.expectEqual(Kind.created, rec.kind);
    try testing.expectEqual(Status.applied, rec.status);
    try testing.expect(rec.diff_complete);
    try testing.expect(std.mem.indexOf(u8, rec.unified_diff.?, "+hi") != null);
    try testing.expectEqualStrings("Write", rec.tool);
    try testing.expectEqualStrings("tu-1", rec.tool_use_id);
}

test "collector: a move keeps both the vacated and the new locator" {
    const a = testing.allocator;
    var ctx = ToolContext{ .allocator = a, .cwd_abs = "/work", .resolve_relative_paths = true };
    var collector = testCollector(a, &ctx);
    defer collector.deinit();

    collector.publish(.{
        .path = "/work/dst.txt",
        .from_path = "/work/src.txt",
        .kind = .moved,
        .status = .applied,
        .before_bytes = 4,
        .after_bytes = 4,
        .unified_diff = "",
    });

    const rec = collector.items.items[0];
    try testing.expectEqualStrings("dst.txt", rec.locator.workspace_path);
    try testing.expectEqualStrings("src.txt", rec.from_locator.?.workspace_path);
    try testing.expectEqual(Kind.moved, rec.kind);
}

test "collector: a real change without a diff is reported as incomplete evidence" {
    const a = testing.allocator;
    var ctx = ToolContext{ .allocator = a, .cwd_abs = "/work", .resolve_relative_paths = true };
    var collector = testCollector(a, &ctx);
    defer collector.deinit();

    collector.publish(.{
        .path = "/work/bin.dat",
        .kind = .modified,
        .status = .applied,
        .before_bytes = 10,
        .after_bytes = 20,
        .unified_diff = null,
    });

    const rec = collector.items.items[0];
    try testing.expect(rec.unified_diff == null);
    try testing.expect(!rec.diff_complete);
}

test "collector: a deletion needs no diff to be complete evidence" {
    const a = testing.allocator;
    var ctx = ToolContext{ .allocator = a, .cwd_abs = "/work", .resolve_relative_paths = true };
    var collector = testCollector(a, &ctx);
    defer collector.deinit();

    collector.publish(.{ .path = "/work/gone.txt", .kind = .deleted, .status = .applied, .before_bytes = 7 });
    const rec = collector.items.items[0];
    try testing.expectEqual(Kind.deleted, rec.kind);
    try testing.expect(rec.diff_complete);
}

test "collector: an oversized diff is truncated and flagged, never silently shortened" {
    const a = testing.allocator;
    var ctx = ToolContext{ .allocator = a, .cwd_abs = "/work", .resolve_relative_paths = true };
    var collector = testCollector(a, &ctx);
    defer collector.deinit();

    const big = try a.alloc(u8, MAX_UNIFIED_DIFF_BYTES_V1 + 32);
    defer a.free(big);
    @memset(big, '+');
    collector.publish(.{
        .path = "/work/huge.txt",
        .kind = .modified,
        .status = .applied,
        .after_bytes = big.len,
        .unified_diff = big,
    });

    const rec = collector.items.items[0];
    try testing.expectEqual(MAX_UNIFIED_DIFF_BYTES_V1, rec.unified_diff.?.len);
    try testing.expect(!rec.diff_complete);
}

test "collector: publishing past the per-call cap sets overflow instead of dropping silently" {
    const a = testing.allocator;
    var ctx = ToolContext{ .allocator = a, .cwd_abs = "/work", .resolve_relative_paths = true };
    var collector = testCollector(a, &ctx);
    defer collector.deinit();

    var i: usize = 0;
    while (i < MAX_FILE_CHANGES_PER_TOOL_RESULT_V1 + 3) : (i += 1) {
        collector.publish(.{ .path = "/work/f.txt", .kind = .modified, .status = .applied });
    }
    try testing.expectEqual(MAX_FILE_CHANGES_PER_TOOL_RESULT_V1, collector.items.items.len);
    try testing.expect(collector.overflow);
}

test "collector: toOwnedSlice hands ownership over and leaves nothing to double free" {
    const a = testing.allocator;
    var ctx = ToolContext{ .allocator = a, .cwd_abs = "/work", .resolve_relative_paths = true };
    var collector = testCollector(a, &ctx);
    defer collector.deinit();

    collector.publish(.{ .path = "/work/a.txt", .kind = .created, .status = .applied, .unified_diff = "d" });
    const taken = collector.toOwnedSlice().?;
    defer freeRecords(a, taken);
    try testing.expectEqual(@as(usize, 1), taken.len);
    try testing.expectEqual(@as(usize, 0), collector.items.items.len);
    try testing.expect(collector.toOwnedSlice() == null);
}

test "journal: clones records so it outlives the dispatch that produced them" {
    const a = testing.allocator;
    var ctx = ToolContext{ .allocator = a, .cwd_abs = "/work", .resolve_relative_paths = true };
    var journal = Journal.init(a);
    defer journal.deinit();

    {
        var collector = testCollector(a, &ctx);
        defer collector.deinit();
        collector.publish(.{
            .path = "/work/a.txt",
            .kind = .modified,
            .status = .applied,
            .before_bytes = 1,
            .after_bytes = 2,
            .unified_diff = "-a\n+b\n",
        });
        journal.recordAll(collector.items.items);
    }

    try testing.expectEqual(@as(usize, 1), journal.count());
    const records = journal.acquire();
    defer journal.release();
    const rec = records[0];
    try testing.expectEqualStrings("a.txt", rec.path());
    try testing.expectEqualStrings("-a\n+b\n", rec.unified_diff.?);
    try testing.expect(!journal.truncated);
}

test "journal: exceeding the retention cap reports truncation" {
    const a = testing.allocator;
    var ctx = ToolContext{ .allocator = a, .cwd_abs = "/work", .resolve_relative_paths = true };
    var journal = Journal.init(a);
    defer journal.deinit();

    var collector = testCollector(a, &ctx);
    defer collector.deinit();
    collector.publish(.{ .path = "/work/a.txt", .kind = .modified, .status = .applied });

    var i: usize = 0;
    while (i < MAX_JOURNAL_ENTRIES_V1 + 2) : (i += 1) journal.recordAll(collector.items.items);

    try testing.expectEqual(MAX_JOURNAL_ENTRIES_V1, journal.count());
    try testing.expect(journal.truncated);
}

test "json projection: v1 field names, locator kind, and move provenance" {
    const a = testing.allocator;
    const records = [_]Record{
        .{
            .locator = .{ .workspace_path = "src/a.zig" },
            .kind = .modified,
            .status = .applied,
            .tool = "Edit",
            .tool_use_id = "tu-1",
            .agent_depth = 0,
            .before_bytes = 3,
            .after_bytes = 4,
            .unified_diff = "-a\n+b\n",
        },
        .{
            .locator = .{ .workspace_path = "dst.txt" },
            .from_locator = .{ .workspace_path = "src.txt" },
            .kind = .moved,
            .status = .applied,
            .tool = "ApplyPatch",
            .tool_use_id = "tu-2",
            .agent_depth = 1,
            .before_bytes = 5,
            .after_bytes = 5,
        },
    };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try writeJsonArray(&aw.writer, &records);
    const out = aw.written();

    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();
    const arr = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expectEqualStrings("src/a.zig", arr[0].object.get("path").?.string);
    try testing.expectEqualStrings("workspace_path", arr[0].object.get("locator_kind").?.string);
    try testing.expectEqualStrings("modified", arr[0].object.get("kind").?.string);
    try testing.expectEqualStrings("applied", arr[0].object.get("status").?.string);
    try testing.expectEqualStrings("-a\n+b\n", arr[0].object.get("unified_diff").?.string);
    try testing.expect(arr[0].object.get("from_path") == null);
    try testing.expectEqualStrings("src.txt", arr[1].object.get("from_path").?.string);
    try testing.expectEqual(@as(i64, 1), arr[1].object.get("agent_depth").?.integer);
    // A deletion/move with no diff must not fabricate one.
    try testing.expect(arr[1].object.get("unified_diff") == null);
}

test "journal: over the diff budget it keeps the change, drops only the text" {
    const a = testing.allocator;
    var ctx = ToolContext{ .allocator = a, .cwd_abs = "/work", .resolve_relative_paths = true };
    var journal = Journal.init(a);
    defer journal.deinit();

    const big = try a.alloc(u8, MAX_UNIFIED_DIFF_BYTES_V1);
    defer a.free(big);
    @memset(big, '+');

    var collector = testCollector(a, &ctx);
    defer collector.deinit();
    collector.publish(.{
        .path = "/work/big.txt",
        .kind = .modified,
        .status = .applied,
        .after_bytes = big.len,
        .unified_diff = big,
    });

    var rounds: usize = 0;
    while (rounds < (MAX_JOURNAL_DIFF_BYTES_V1 / MAX_UNIFIED_DIFF_BYTES_V1) + 2) : (rounds += 1) {
        journal.recordAll(collector.items.items);
    }

    try testing.expect(journal.truncated);
    try testing.expect(journal.diff_bytes <= MAX_JOURNAL_DIFF_BYTES_V1);
    const records = journal.acquire();
    defer journal.release();
    try testing.expectEqual(rounds, records.len); // every change still recorded
    var dropped: usize = 0;
    for (records) |rec| {
        try testing.expectEqualStrings("big.txt", rec.path());
        try testing.expectEqual(Status.applied, rec.status);
        if (rec.unified_diff == null) {
            dropped += 1;
            try testing.expect(!rec.diff_complete);
        }
    }
    try testing.expect(dropped > 0);
}

test "journal: reset drops the retained session and its budget" {
    const a = testing.allocator;
    var ctx = ToolContext{ .allocator = a, .cwd_abs = "/work", .resolve_relative_paths = true };
    var journal = Journal.init(a);
    defer journal.deinit();

    var collector = testCollector(a, &ctx);
    defer collector.deinit();
    collector.publish(.{ .path = "/work/a.txt", .kind = .created, .status = .applied, .unified_diff = "+a\n" });
    journal.recordAll(collector.items.items);
    try testing.expectEqual(@as(usize, 1), journal.count());

    journal.reset();
    try testing.expectEqual(@as(usize, 0), journal.count());
    try testing.expectEqual(@as(usize, 0), journal.diff_bytes);
    try testing.expect(!journal.truncated);
}

test "json envelope: carries the schema version and the truncation flag" {
    const a = testing.allocator;
    const records = [_]Record{.{
        .locator = .{ .workspace_path = "a.txt" },
        .kind = .created,
        .status = .applied,
        .tool = "Write",
        .tool_use_id = "t",
        .agent_depth = 0,
        .before_bytes = 0,
        .after_bytes = 1,
    }};
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try writeJsonEnvelope(&aw.writer, &records, true);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, aw.written(), .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings(SCHEMA_VERSION, obj.get("schema_version").?.string);
    try testing.expect(obj.get("truncated").?.bool);
    try testing.expectEqual(@as(usize, 1), obj.get("changes").?.array.items.len);
}

test "status: only applied and partial claim the disk changed" {
    try testing.expect(Status.applied.changedDisk());
    try testing.expect(Status.partial.changedDisk());
    try testing.expect(!Status.no_change.changedDisk());
    try testing.expect(!Status.failed.changedDisk());
    try testing.expect(!Status.rejected.changedDisk());
}

test "record is JSON-serializable for a process boundary" {
    const a = testing.allocator;
    const rec = Record{
        .locator = .{ .workspace_path = "src/a.zig" },
        .kind = .modified,
        .status = .applied,
        .tool = "Edit",
        .tool_use_id = "tu-9",
        .agent_depth = 1,
        .before_bytes = 3,
        .after_bytes = 4,
        .unified_diff = "-a\n+b\n",
    };
    const out = try std.json.Stringify.valueAlloc(a, rec, .{});
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"modified\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"applied\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "src/a.zig") != null);
}
