//! Teamwork shared vocabulary (#514 / #515): roles, harnesses, seat specs,
//! seat outcomes, the handoff contract and the `SeatDriver` interface.
//!
//! The teamwork runtime is always metacodes. A *seat* is one role filled by
//! one harness; whatever the harness, the worker contract is the same:
//!
//! - input: a packet file path and a workspace directory;
//! - output: `handoff.md` at a fixed path (five required sections, parsed by
//!   `Handoff.parse`), plus the exit status and the git diff, which the runtime
//!   collects itself.
//!
//! The runtime never reads a harness transcript. Design:
//! doc/TEAMWORK_DESIGN.md.

const std = @import("std");
const builtin = @import("builtin");
pub const ReasoningEffort = @import("../types.zig").ReasoningEffort;
pub const AbortSignal = @import("../util/abort.zig").AbortSignal;

// ── roles and harnesses ─────────────────────────────────────────────────────

pub const Role = enum {
    manager,
    interviewer,
    implementer,
    reviewer,
    verifier,

    pub fn parse(text: []const u8) ?Role {
        return std.meta.stringToEnum(Role, text);
    }

    pub fn name(self: Role) []const u8 {
        return @tagName(self);
    }
};

pub const Harness = enum {
    /// An in-process metacodes subagent.
    metacodes,
    /// The Claude Code CLI as a child process.
    claude_code,

    pub fn parse(text: []const u8) ?Harness {
        return std.meta.stringToEnum(Harness, text);
    }

    pub fn name(self: Harness) []const u8 {
        return @tagName(self);
    }
};

// ── identifiers ─────────────────────────────────────────────────────────────

pub const IdError = error{InvalidId};

/// A path-safe identifier: `[a-z0-9][a-z0-9_-]*`, at most `max_len` bytes. It
/// is used verbatim as a directory name, so it can hold no separator, dot or
/// drive letter. Each `tag` yields a distinct type: a `SeatId` is not a `RunId`.
fn Id(comptime tag: []const u8) type {
    return struct {
        const Self = @This();
        pub const max_len = 64;
        pub const kind = tag;

        bytes: [max_len]u8,
        len: u8,

        pub fn parse(text: []const u8) IdError!Self {
            if (text.len == 0 or text.len > max_len) return error.InvalidId;
            for (text, 0..) |c, i| {
                const ok = switch (c) {
                    'a'...'z', '0'...'9' => true,
                    '_', '-' => i != 0,
                    else => false,
                };
                if (!ok) return error.InvalidId;
            }
            var id: Self = .{ .bytes = undefined, .len = @intCast(text.len) };
            @memcpy(id.bytes[0..text.len], text);
            return id;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn eql(a: Self, b: Self) bool {
            return std.mem.eql(u8, a.slice(), b.slice());
        }

        pub fn lessThan(_: void, a: Self, b: Self) bool {
            return std.mem.lessThan(u8, a.slice(), b.slice());
        }
    };
}

/// One teamwork run; names `<state_root>/teamwork/<run_id>/`. Never part of
/// provider-visible bytes.
pub const RunId = Id("run");

/// One seat of a run; names `seats/<seat_id>/`.
pub const SeatId = Id("seat");

/// The conventional seat id for the `ordinal`-th seat of `role`
/// (`implementer-1`, `reviewer-2`, ...).
pub fn seatIdFor(role: Role, ordinal: u32) SeatId {
    var buf: [SeatId.max_len]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{s}-{d}", .{ role.name(), ordinal }) catch unreachable;
    return SeatId.parse(text) catch unreachable;
}

/// An absolute filesystem path, checked at construction. External harness
/// binaries are named this way and never looked up on `PATH`.
pub const AbsolutePath = struct {
    bytes: []const u8,

    pub fn init(text: []const u8) error{NotAbsolute}!AbsolutePath {
        if (!isAbsolute(text)) return error.NotAbsolute;
        return .{ .bytes = text };
    }

    fn isAbsolute(text: []const u8) bool {
        if (text.len == 0) return false;
        if (builtin.os.tag == .windows) {
            // `C:\x` / `C:/x`; a bare `\x` is drive-relative, not absolute.
            return text.len >= 3 and std.ascii.isAlphabetic(text[0]) and text[1] == ':' and
                (text[2] == '\\' or text[2] == '/');
        }
        return text[0] == '/';
    }
};

// ── seat specification ──────────────────────────────────────────────────────

/// How a seat's spend is bounded. `wallclock_only` is for a harness whose
/// cost cannot be read; it carries its limit, so a wallclock-only seat
/// without one cannot be built.
pub const BudgetEnforcement = union(enum) {
    cost,
    wallclock_only: WallclockLimit,
};

pub const WallclockLimit = struct {
    /// Never zero (checked by config validation).
    seconds: u32,
};

/// Settings that exist only for an external (child-process) harness.
pub const ExternalHarness = struct {
    /// The harness binary, absolute; never resolved through `PATH`.
    command: AbsolutePath,
    budget: BudgetEnforcement = .cost,
    /// The seat's verdicts may only lower a result, never raise it. Required
    /// for an external verifier (only a metacodes verifier is isolated by
    /// mechanism), rejected for every other role.
    demote_only: bool = false,
};

/// The harness of a seat with its harness-specific settings. A metacodes seat
/// has none, so it cannot carry a `command`.
pub const HarnessConfig = union(Harness) {
    metacodes,
    claude_code: ExternalHarness,
};

pub const SeatSpec = struct {
    role: Role,
    harness: HarnessConfig = .metacodes,
    /// Borrowed; null = the harness's default model.
    model: ?[]const u8 = null,
    effort: ?ReasoningEffort = null,

    pub fn harnessKind(self: *const SeatSpec) Harness {
        return std.meta.activeTag(self.harness);
    }
};

// ── seat lifecycle ──────────────────────────────────────────────────────────

pub const SeatStatus = enum {
    queued,
    working,
    /// Blocked on the user (a question or a permission prompt).
    needs_you,
    /// Blocked on another seat.
    waiting,
    done,
    failed,

    pub fn parse(text: []const u8) ?SeatStatus {
        return std.meta.stringToEnum(SeatStatus, text);
    }

    pub fn name(self: SeatStatus) []const u8 {
        return @tagName(self);
    }

    pub fn isTerminal(self: SeatStatus) bool {
        return switch (self) {
            .done, .failed => true,
            .queued, .working, .needs_you, .waiting => false,
        };
    }
};

/// Why a seat failed. Judged from artifacts only: process status and the
/// handoff file, never a transcript.
pub const SeatError = union(enum) {
    /// The harness could not be started.
    spawn_failed,
    /// The harness exited with this nonzero status.
    exited: u8,
    /// The harness was killed by this signal.
    signaled: u32,
    /// The harness outlived the driver's hard time limit and was killed. (A
    /// `wallclock_only` seat that reaches its own limit is
    /// `budget_exhausted` instead: that limit is its budget.)
    timed_out,
    /// The harness ended without writing `handoff.md`.
    handoff_missing,
    /// `handoff.md` exists but breaks the contract.
    handoff_invalid: HandoffError,
};

pub const SeatOutcome = union(enum) {
    finished: Handoff,
    failed: SeatError,
    budget_exhausted,
    aborted,

    /// Frees what `finished` owns; `gpa` is the allocator the driver was given.
    pub fn deinit(self: *SeatOutcome, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .finished => |*handoff| handoff.deinit(gpa),
            .failed, .budget_exhausted, .aborted => {},
        }
        self.* = undefined;
    }
};

// ── handoff ─────────────────────────────────────────────────────────────────

pub const HandoffSection = enum {
    observation,
    reasoning,
    caveats,
    conclusion,
    verification,

    /// The markdown heading text, as in `## Observation`.
    pub fn title(self: HandoffSection) []const u8 {
        return switch (self) {
            .observation => "Observation",
            .reasoning => "Reasoning",
            .caveats => "Caveats",
            .conclusion => "Conclusion",
            .verification => "Verification",
        };
    }

    fn fromTitle(text: []const u8) ?HandoffSection {
        inline for (std.meta.fields(HandoffSection)) |field| {
            const section: HandoffSection = @enumFromInt(field.value);
            if (std.mem.eql(u8, text, section.title())) return section;
        }
        return null;
    }
};

pub const HandoffError = error{
    MissingObservation,
    MissingReasoning,
    MissingCaveats,
    MissingConclusion,
    MissingVerification,
    /// A required section appears twice.
    DuplicateSection,
    /// A required section has only whitespace.
    EmptySection,
    /// A level-2 heading that is not one of the five sections.
    UnknownSection,
};

/// A seat's report: five required sections. All slices point into `bytes`,
/// which the handoff owns.
pub const Handoff = struct {
    bytes: []u8,
    observation: []const u8,
    reasoning: []const u8,
    caveats: []const u8,
    conclusion: []const u8,
    verification: []const u8,

    /// Parse `markdown` strictly: every section is a `## <Title>` line outside
    /// a code fence, each of the five appears exactly once with a non-blank
    /// body, and no other level-2 heading appears. Text before the first
    /// section (a title, say) is ignored; deeper headings are body text.
    /// Copies `markdown` into `gpa`.
    pub fn parse(gpa: std.mem.Allocator, markdown: []const u8) (HandoffError || error{OutOfMemory})!Handoff {
        const bytes = try gpa.dupe(u8, markdown);
        errdefer gpa.free(bytes);
        var bodies = std.EnumArray(HandoffSection, ?[]const u8).initFill(null);

        var current: ?HandoffSection = null;
        var body_start: usize = 0;
        var in_fence = false;
        var line_start: usize = 0;
        while (true) {
            const line_end = std.mem.indexOfScalarPos(u8, bytes, line_start, '\n') orelse bytes.len;
            const line = std.mem.trimEnd(u8, bytes[line_start..line_end], " \t\r");
            if (isFence(line)) {
                in_fence = !in_fence;
            } else if (!in_fence and std.mem.startsWith(u8, line, "## ")) {
                if (current) |open| try closeSection(&bodies, open, bytes[body_start..line_start]);
                const title_text = std.mem.trim(u8, line[3..], " \t");
                const next = HandoffSection.fromTitle(title_text) orelse return error.UnknownSection;
                if (bodies.get(next) != null) return error.DuplicateSection;
                current = next;
                body_start = @min(line_end + 1, bytes.len);
            }
            if (line_end == bytes.len) break;
            line_start = line_end + 1;
        }
        if (current) |open| try closeSection(&bodies, open, bytes[body_start..]);

        return .{
            .bytes = bytes,
            .observation = bodies.get(.observation) orelse return error.MissingObservation,
            .reasoning = bodies.get(.reasoning) orelse return error.MissingReasoning,
            .caveats = bodies.get(.caveats) orelse return error.MissingCaveats,
            .conclusion = bodies.get(.conclusion) orelse return error.MissingConclusion,
            .verification = bodies.get(.verification) orelse return error.MissingVerification,
        };
    }

    pub fn section(self: *const Handoff, which: HandoffSection) []const u8 {
        return switch (which) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }

    pub fn deinit(self: *Handoff, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }

    fn closeSection(
        bodies: *std.EnumArray(HandoffSection, ?[]const u8),
        which: HandoffSection,
        raw: []const u8,
    ) HandoffError!void {
        if (bodies.get(which) != null) return error.DuplicateSection;
        const body = std.mem.trim(u8, raw, " \t\r\n");
        if (body.len == 0) return error.EmptySection;
        bodies.set(which, body);
    }

    fn isFence(line: []const u8) bool {
        const trimmed = std.mem.trimStart(u8, line, " ");
        return std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~");
    }
};

// ── seat driver ─────────────────────────────────────────────────────────────

/// Where one seat run reads and writes. Paths are absolute and borrowed.
pub const SeatPaths = struct {
    /// The packet the runtime wrote (`seats/<id>/packet.md`).
    packet: []const u8,
    /// Where the seat must leave its handoff (`seats/<id>/handoff.md`).
    handoff: []const u8,
    /// The seat's working tree (a worktree for an implementer).
    workspace: []const u8,
};

/// One harness's way of running a seat. Implementations:
/// `drivers/metacodes.zig` (in-process subagent) and
/// `drivers/claude_code.zig` (child process), chosen per seat by
/// `drivers/factory.zig`; `stub_driver.zig` is the test double.
///
/// Every harness-level failure (spawn error, nonzero exit, missing or invalid
/// handoff, abort, budget stop) is a `SeatOutcome`, not a Zig error: the only
/// error is running out of memory. A `.finished` handoff is allocated in
/// `gpa` and released with `SeatOutcome.deinit(gpa)`.
pub const SeatDriver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{OutOfMemory};

    pub const VTable = struct {
        run: *const fn (
            ptr: *anyopaque,
            gpa: std.mem.Allocator,
            spec: *const SeatSpec,
            paths: SeatPaths,
            abort: *const AbortSignal,
        ) Error!SeatOutcome,
    };

    pub fn run(
        self: SeatDriver,
        gpa: std.mem.Allocator,
        spec: *const SeatSpec,
        paths: SeatPaths,
        abort: *const AbortSignal,
    ) Error!SeatOutcome {
        return self.vtable.run(self.ptr, gpa, spec, paths, abort);
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const good_handoff =
    \\# Handoff
    \\
    \\## Observation
    \\The parser rejected `## Notes`.
    \\
    \\## Reasoning
    \\Unknown level-2 headings are contract violations.
    \\
    \\```
    \\## Not a heading inside a fence
    \\```
    \\
    \\## Caveats
    \\None known.
    \\
    \\## Conclusion
    \\Fixed.
    \\
    \\## Verification
    \\zig build test:units
    \\
;

test "handoff: all five sections parse; fenced headings are body text" {
    var handoff = try Handoff.parse(testing.allocator, good_handoff);
    defer handoff.deinit(testing.allocator);
    try testing.expectEqualStrings("The parser rejected `## Notes`.", handoff.observation);
    try testing.expect(std.mem.indexOf(u8, handoff.reasoning, "## Not a heading inside a fence") != null);
    try testing.expectEqualStrings("None known.", handoff.caveats);
    try testing.expectEqualStrings("Fixed.", handoff.section(.conclusion));
    try testing.expectEqualStrings("zig build test:units", handoff.verification);
}

test "handoff: last section without a trailing newline still parses" {
    const text = "## Observation\no\n## Reasoning\nr\n## Caveats\nc\n## Conclusion\nk\n## Verification\nv";
    var handoff = try Handoff.parse(testing.allocator, text);
    defer handoff.deinit(testing.allocator);
    try testing.expectEqualStrings("v", handoff.verification);
    try testing.expectEqualStrings("k", handoff.conclusion);
}

test "handoff: each missing section is its own typed error" {
    const cases = [_]struct { drop: HandoffSection, want: HandoffError }{
        .{ .drop = .observation, .want = error.MissingObservation },
        .{ .drop = .reasoning, .want = error.MissingReasoning },
        .{ .drop = .caveats, .want = error.MissingCaveats },
        .{ .drop = .conclusion, .want = error.MissingConclusion },
        .{ .drop = .verification, .want = error.MissingVerification },
    };
    for (cases) |case| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        inline for (std.meta.fields(HandoffSection)) |field| {
            const s: HandoffSection = @enumFromInt(field.value);
            if (s != case.drop) {
                try buf.print(testing.allocator, "## {s}\nbody of {s}\n\n", .{ s.title(), s.title() });
            }
        }
        try testing.expectError(case.want, Handoff.parse(testing.allocator, buf.items));
    }
}

test "handoff: duplicate, empty and unknown sections are rejected" {
    const dup = "## Observation\na\n## Observation\nb\n## Reasoning\nr\n## Caveats\nc\n## Conclusion\nk\n## Verification\nv\n";
    try testing.expectError(error.DuplicateSection, Handoff.parse(testing.allocator, dup));
    const empty = "## Observation\n\n   \n## Reasoning\nr\n## Caveats\nc\n## Conclusion\nk\n## Verification\nv\n";
    try testing.expectError(error.EmptySection, Handoff.parse(testing.allocator, empty));
    const unknown = "## Observation\no\n## Notes\nx\n## Reasoning\nr\n## Caveats\nc\n## Conclusion\nk\n## Verification\nv\n";
    try testing.expectError(error.UnknownSection, Handoff.parse(testing.allocator, unknown));
    // Headings are case-sensitive: `## observation` is not the Observation section.
    const lower = "## observation\no\n## Reasoning\nr\n## Caveats\nc\n## Conclusion\nk\n## Verification\nv\n";
    try testing.expectError(error.UnknownSection, Handoff.parse(testing.allocator, lower));
    try testing.expectError(error.MissingObservation, Handoff.parse(testing.allocator, ""));
}

test "ids: path-safe charset, distinct types, conventional seat ids" {
    _ = try RunId.parse("run-0001");
    try testing.expectEqualStrings("implementer-2", seatIdFor(.implementer, 2).slice());
    const bad = [_][]const u8{ "", "..", "a/b", "a\\b", "A", "-x", "x.y", "c:", "x" ** 65 };
    for (bad) |text| try testing.expectError(error.InvalidId, SeatId.parse(text));
    try testing.expect(RunId != SeatId);
}

test "seat spec: harness-specific settings live in the harness union" {
    const external: SeatSpec = .{
        .role = .verifier,
        .harness = .{ .claude_code = .{
            .command = try AbsolutePath.init(if (builtin.os.tag == .windows) "C:\\bin\\claude.exe" else "/usr/local/bin/claude"),
            .budget = .{ .wallclock_only = .{ .seconds = 600 } },
            .demote_only = true,
        } },
    };
    try testing.expectEqual(Harness.claude_code, external.harnessKind());
    const local: SeatSpec = .{ .role = .implementer };
    try testing.expectEqual(Harness.metacodes, local.harnessKind());
    try testing.expectError(error.NotAbsolute, AbsolutePath.init("claude"));
    try testing.expectError(error.NotAbsolute, AbsolutePath.init("bin/claude"));
}

test "seat status: terminal states" {
    try testing.expect(SeatStatus.done.isTerminal());
    try testing.expect(SeatStatus.failed.isTerminal());
    try testing.expect(!SeatStatus.needs_you.isTerminal());
    try testing.expectEqual(SeatStatus.needs_you, SeatStatus.parse("needs_you").?);
    try testing.expect(SeatStatus.parse("idle") == null);
}
