//! Teamwork configuration (#515, #520): the `teamwork` object.
//!
//! Three steps, each pure:
//!
//! 1. `parse` / `parseValue` turn one source's `teamwork` object into a
//!    `Layer` (every field optional). Unknown keys, roles, harnesses and
//!    enumerations are rejected here.
//! 2. `merge` overlays a higher-precedence layer on a lower one. Sources, low
//!    to high: `<state root>/config.json` → `<project>/.metacodes/teamwork.json`
//!    → command-line overrides.
//! 3. `validate` turns the merged layer into a `Config` whose seats are
//!    `types.SeatSpec` values, or fails with one typed error.
//!
//! Not wired into the application's config loader yet; doc/TEAMWORK_DESIGN.md
//! names the wiring point.

const std = @import("std");
const types = @import("types.zig");

const Role = types.Role;
const Harness = types.Harness;
const ReasoningEffort = types.ReasoningEffort;

pub const BudgetEnforcementKind = enum {
    cost,
    wallclock_only,

    pub fn parse(text: []const u8) ?BudgetEnforcementKind {
        return std.meta.stringToEnum(BudgetEnforcementKind, text);
    }
};

/// One source's settings for one seat. Strings are borrowed from the parse
/// arena.
pub const SeatLayer = struct {
    harness: ?Harness = null,
    model: ?[]const u8 = null,
    effort: ?ReasoningEffort = null,
    command: ?[]const u8 = null,
    budget_enforcement: ?BudgetEnforcementKind = null,
    wallclock_seconds: ?u32 = null,
    demote_only: ?bool = null,
};

/// One source's `teamwork` object, before validation.
pub const Layer = struct {
    enabled: ?bool = null,
    budget_usd: ?f64 = null,
    seats: std.EnumArray(Role, SeatLayer) = .initFill(.{}),
};

/// Where a parse or validation failed, for the error message.
pub const Diagnostic = struct {
    role: ?Role = null,
    /// A key of the input (static or borrowed from the input).
    field: ?[]const u8 = null,
};

pub const ParseError = error{
    InvalidJson,
    /// The `teamwork` value, `seats`, or a seat entry is not an object.
    NotAnObject,
    UnknownField,
    UnknownRole,
    UnknownHarness,
    UnknownEffort,
    UnknownBudgetEnforcement,
    /// A known key holds a value of the wrong JSON type or range.
    WrongType,
    OutOfMemory,
};

pub const ValidateError = error{
    /// `enabled: true` without `budget_usd`: a paid run needs a dollar cap.
    BudgetMissing,
    /// `budget_usd` is not a finite number greater than zero.
    InvalidBudget,
    /// An external seat without `command`.
    ExternalCommandMissing,
    /// An external seat whose `command` is not an absolute path; harness
    /// binaries are never looked up on `PATH`.
    ExternalCommandNotAbsolute,
    /// A metacodes seat with `command`.
    MetacodesSeatHasCommand,
    /// A metacodes seat with `budget_enforcement`, `wallclock_seconds` or
    /// `demote_only`, which only mean something for an external harness.
    ExternalOnlyField,
    /// An external verifier without `demote_only: true`.
    ExternalVerifierNotDemoteOnly,
    /// `demote_only` on a role other than verifier.
    DemoteOnlyOutsideVerifier,
    /// `budget_enforcement: "wallclock_only"` without `wallclock_seconds`.
    WallclockLimitMissing,
    /// `wallclock_seconds` without `budget_enforcement: "wallclock_only"`;
    /// it would otherwise be silently ignored.
    WallclockWithoutWallclockOnly,
    /// `wallclock_seconds` of zero.
    InvalidWallclock,
};

/// A validated configuration.
pub const Config = union(enum) {
    disabled,
    enabled: Enabled,

    pub const Enabled = struct {
        /// Finite and > 0.
        budget_usd: f64,
        /// One spec per role; strings borrowed from the parse arenas.
        seats: std.EnumArray(Role, types.SeatSpec),
    };
};

// ── parse ───────────────────────────────────────────────────────────────────

/// Parse the text of a `teamwork` object. Strings in the result live in
/// `arena`.
pub fn parse(arena: std.mem.Allocator, text: []const u8, diag: ?*Diagnostic) ParseError!Layer {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    return parseValue(arena, root, diag);
}

/// Parse an already-decoded `teamwork` value (the loader of a larger document
/// passes its `teamwork` member). Strings are copied into `arena`.
pub fn parseValue(arena: std.mem.Allocator, value: std.json.Value, diag: ?*Diagnostic) ParseError!Layer {
    if (value != .object) return error.NotAnObject;
    var layer: Layer = .{};
    var it = value.object.iterator();
    while (it.next()) |pair| {
        const key = pair.key_ptr.*;
        const item = pair.value_ptr.*;
        setDiag(diag, null, key);
        if (std.mem.eql(u8, key, "enabled")) {
            if (item != .bool) return error.WrongType;
            layer.enabled = item.bool;
        } else if (std.mem.eql(u8, key, "budget_usd")) {
            layer.budget_usd = numberOf(item) orelse return error.WrongType;
        } else if (std.mem.eql(u8, key, "seats")) {
            if (item != .object) return error.NotAnObject;
            var seats = item.object.iterator();
            while (seats.next()) |seat| {
                setDiag(diag, null, seat.key_ptr.*);
                const role = Role.parse(seat.key_ptr.*) orelse return error.UnknownRole;
                layer.seats.set(role, try parseSeat(arena, role, seat.value_ptr.*, diag));
            }
        } else return error.UnknownField;
    }
    setDiag(diag, null, null);
    return layer;
}

fn parseSeat(arena: std.mem.Allocator, role: Role, value: std.json.Value, diag: ?*Diagnostic) ParseError!SeatLayer {
    if (value != .object) return error.NotAnObject;
    var seat: SeatLayer = .{};
    var it = value.object.iterator();
    while (it.next()) |pair| {
        const key = pair.key_ptr.*;
        const item = pair.value_ptr.*;
        setDiag(diag, role, key);
        if (std.mem.eql(u8, key, "harness")) {
            seat.harness = Harness.parse(try stringOf(item)) orelse return error.UnknownHarness;
        } else if (std.mem.eql(u8, key, "model")) {
            seat.model = try arena.dupe(u8, try stringOf(item));
        } else if (std.mem.eql(u8, key, "effort")) {
            seat.effort = ReasoningEffort.parse(try stringOf(item)) orelse return error.UnknownEffort;
        } else if (std.mem.eql(u8, key, "command")) {
            seat.command = try arena.dupe(u8, try stringOf(item));
        } else if (std.mem.eql(u8, key, "budget_enforcement")) {
            seat.budget_enforcement = BudgetEnforcementKind.parse(try stringOf(item)) orelse
                return error.UnknownBudgetEnforcement;
        } else if (std.mem.eql(u8, key, "wallclock_seconds")) {
            if (item != .integer or item.integer < 0 or item.integer > std.math.maxInt(u32)) return error.WrongType;
            seat.wallclock_seconds = @intCast(item.integer);
        } else if (std.mem.eql(u8, key, "demote_only")) {
            if (item != .bool) return error.WrongType;
            seat.demote_only = item.bool;
        } else return error.UnknownField;
    }
    return seat;
}

fn stringOf(value: std.json.Value) error{WrongType}![]const u8 {
    if (value != .string or value.string.len == 0) return error.WrongType;
    return value.string;
}

fn numberOf(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn setDiag(diag: ?*Diagnostic, role: ?Role, field: ?[]const u8) void {
    if (diag) |d| d.* = .{ .role = role, .field = field };
}

// ── merge ───────────────────────────────────────────────────────────────────

/// Overlay `upper` (higher precedence) on `lower`. Field by field, a value set
/// in `upper` wins. One exception: when `upper` names a different harness for
/// a seat than `lower` does, the lower layer's harness-specific fields
/// (`command`, `budget_enforcement`, `wallclock_seconds`, `demote_only`) are
/// dropped first, since they described the harness being replaced. `model`
/// and `effort` carry over. No allocation; slices stay borrowed.
pub fn merge(lower: Layer, upper: Layer) Layer {
    var out = lower;
    if (upper.enabled) |v| out.enabled = v;
    if (upper.budget_usd) |v| out.budget_usd = v;
    for (std.enums.values(Role)) |role| {
        out.seats.set(role, mergeSeat(lower.seats.get(role), upper.seats.get(role)));
    }
    return out;
}

fn mergeSeat(lower: SeatLayer, upper: SeatLayer) SeatLayer {
    var out = lower;
    if (upper.harness) |h| {
        if ((lower.harness orelse .metacodes) != h) {
            out.command = null;
            out.budget_enforcement = null;
            out.wallclock_seconds = null;
            out.demote_only = null;
        }
        out.harness = h;
    }
    inline for (.{ "model", "effort", "command", "budget_enforcement", "wallclock_seconds", "demote_only" }) |name| {
        if (@field(upper, name)) |v| @field(out, name) = v;
    }
    return out;
}

// ── validate ────────────────────────────────────────────────────────────────

/// Check the merged layer and build the seat specs. Every seat is checked
/// even when teamwork is disabled, so a bad file fails at startup, not when a
/// run is first requested. A role with no entry is a metacodes seat.
pub fn validate(layer: Layer, diag: ?*Diagnostic) ValidateError!Config {
    var seats: std.EnumArray(Role, types.SeatSpec) = undefined;
    for (std.enums.values(Role)) |role| {
        setDiag(diag, role, null);
        seats.set(role, try validateSeat(role, layer.seats.get(role), diag));
    }
    setDiag(diag, null, "budget_usd");
    if (layer.budget_usd) |usd| {
        if (!std.math.isFinite(usd) or usd <= 0) return error.InvalidBudget;
    }
    if (!(layer.enabled orelse false)) {
        setDiag(diag, null, null);
        return .disabled;
    }
    const budget_usd = layer.budget_usd orelse return error.BudgetMissing;
    setDiag(diag, null, null);
    return .{ .enabled = .{ .budget_usd = budget_usd, .seats = seats } };
}

fn validateSeat(role: Role, seat: SeatLayer, diag: ?*Diagnostic) ValidateError!types.SeatSpec {
    const harness: types.HarnessConfig = switch (seat.harness orelse .metacodes) {
        .metacodes => blk: {
            if (seat.command != null) return fail(diag, role, "command", error.MetacodesSeatHasCommand);
            if (seat.budget_enforcement != null) return fail(diag, role, "budget_enforcement", error.ExternalOnlyField);
            if (seat.wallclock_seconds != null) return fail(diag, role, "wallclock_seconds", error.ExternalOnlyField);
            if (seat.demote_only != null) return fail(diag, role, "demote_only", error.ExternalOnlyField);
            break :blk .metacodes;
        },
        .claude_code => .{ .claude_code = try validateExternal(role, seat, diag) },
    };
    return .{ .role = role, .harness = harness, .model = seat.model, .effort = seat.effort };
}

fn validateExternal(role: Role, seat: SeatLayer, diag: ?*Diagnostic) ValidateError!types.ExternalHarness {
    const command_text = seat.command orelse return fail(diag, role, "command", error.ExternalCommandMissing);
    const command = types.AbsolutePath.init(command_text) catch
        return fail(diag, role, "command", error.ExternalCommandNotAbsolute);

    const budget: types.BudgetEnforcement = switch (seat.budget_enforcement orelse .cost) {
        .cost => blk: {
            if (seat.wallclock_seconds != null)
                return fail(diag, role, "wallclock_seconds", error.WallclockWithoutWallclockOnly);
            break :blk .cost;
        },
        .wallclock_only => blk: {
            const seconds = seat.wallclock_seconds orelse
                return fail(diag, role, "wallclock_seconds", error.WallclockLimitMissing);
            if (seconds == 0) return fail(diag, role, "wallclock_seconds", error.InvalidWallclock);
            break :blk .{ .wallclock_only = .{ .seconds = seconds } };
        },
    };

    const demote_only = seat.demote_only orelse false;
    if (role == .verifier and !demote_only)
        return fail(diag, role, "demote_only", error.ExternalVerifierNotDemoteOnly);
    if (role != .verifier and seat.demote_only != null)
        return fail(diag, role, "demote_only", error.DemoteOnlyOutsideVerifier);

    return .{ .command = command, .budget = budget, .demote_only = demote_only };
}

fn fail(diag: ?*Diagnostic, role: Role, field: []const u8, err: ValidateError) ValidateError {
    setDiag(diag, role, field);
    return err;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const builtin = @import("builtin");

const abs_claude = if (builtin.os.tag == .windows) "C:/tools/claude.exe" else "/opt/claude/bin/claude";

/// Parse then validate one JSON document.
fn load(arena: std.mem.Allocator, text: []const u8) (ParseError || ValidateError)!Config {
    return validate(try parse(arena, text, null), null);
}

fn arenaFixture() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "config: defaults make every role a metacodes seat" {
    var arena = arenaFixture();
    defer arena.deinit();
    const config = try load(arena.allocator(), "{\"enabled\": true, \"budget_usd\": 5}");
    try testing.expect(config == .enabled);
    try testing.expectEqual(@as(f64, 5), config.enabled.budget_usd);
    for (std.enums.values(Role)) |role| {
        const spec = config.enabled.seats.get(role);
        try testing.expectEqual(role, spec.role);
        try testing.expectEqual(Harness.metacodes, spec.harnessKind());
    }
    try testing.expect(try load(arena.allocator(), "{}") == .disabled);
}

test "config: a full external configuration builds typed seat specs" {
    var arena = arenaFixture();
    defer arena.deinit();
    const text = "{\"enabled\":true,\"budget_usd\":12.5,\"seats\":{" ++
        "\"implementer\":{\"harness\":\"claude_code\",\"command\":\"" ++ abs_claude ++ "\",\"model\":\"m-1\",\"effort\":\"high\"}," ++
        "\"reviewer\":{\"harness\":\"claude_code\",\"command\":\"" ++ abs_claude ++ "\",\"budget_enforcement\":\"wallclock_only\",\"wallclock_seconds\":900}," ++
        "\"verifier\":{\"harness\":\"claude_code\",\"command\":\"" ++ abs_claude ++ "\",\"demote_only\":true}}}";
    const config = try load(arena.allocator(), text);
    const seats = config.enabled.seats;
    const implementer = seats.get(.implementer);
    try testing.expectEqualStrings(abs_claude, implementer.harness.claude_code.command.bytes);
    try testing.expectEqualStrings("m-1", implementer.model.?);
    try testing.expectEqual(ReasoningEffort.high, implementer.effort.?);
    try testing.expect(implementer.harness.claude_code.budget == .cost);
    try testing.expectEqual(@as(u32, 900), seats.get(.reviewer).harness.claude_code.budget.wallclock_only.seconds);
    try testing.expect(seats.get(.verifier).harness.claude_code.demote_only);
    try testing.expectEqual(Harness.metacodes, seats.get(.manager).harnessKind());
}

test "config: parse rejects unknown fields, roles, harnesses and enumerations" {
    var arena = arenaFixture();
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { text: []const u8, want: ParseError }{
        .{ .text = "{\"enable\":true}", .want = error.UnknownField },
        .{ .text = "{\"seats\":{\"implementer\":{\"harnes\":\"metacodes\"}}}", .want = error.UnknownField },
        .{ .text = "{\"seats\":{\"architect\":{}}}", .want = error.UnknownRole },
        .{ .text = "{\"seats\":{\"implementer\":{\"harness\":\"codex\"}}}", .want = error.UnknownHarness },
        .{ .text = "{\"seats\":{\"implementer\":{\"effort\":\"extreme\"}}}", .want = error.UnknownEffort },
        .{ .text = "{\"seats\":{\"reviewer\":{\"budget_enforcement\":\"tokens\"}}}", .want = error.UnknownBudgetEnforcement },
        .{ .text = "{\"enabled\":\"yes\"}", .want = error.WrongType },
        .{ .text = "{\"budget_usd\":\"5\"}", .want = error.WrongType },
        .{ .text = "{\"seats\":{\"reviewer\":{\"wallclock_seconds\":-1}}}", .want = error.WrongType },
        .{ .text = "{\"seats\":{\"reviewer\":{\"model\":\"\"}}}", .want = error.WrongType },
        .{ .text = "{\"seats\":[]}", .want = error.NotAnObject },
        .{ .text = "[]", .want = error.NotAnObject },
        .{ .text = "{", .want = error.InvalidJson },
    };
    for (cases) |case| try testing.expectError(case.want, parse(a, case.text, null));

    var diag: Diagnostic = .{};
    try testing.expectError(error.UnknownHarness, parse(a, "{\"seats\":{\"reviewer\":{\"harness\":\"x\"}}}", &diag));
    try testing.expectEqual(Role.reviewer, diag.role.?);
    try testing.expectEqualStrings("harness", diag.field.?);
}

test "config: claude_code requires an absolute command, never a PATH name" {
    var arena = arenaFixture();
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.ExternalCommandMissing, load(a, "{\"seats\":{\"implementer\":{\"harness\":\"claude_code\"}}}"));
    try testing.expectError(error.ExternalCommandNotAbsolute, load(a, "{\"seats\":{\"implementer\":{\"harness\":\"claude_code\",\"command\":\"claude\"}}}"));
    try testing.expectError(error.ExternalCommandNotAbsolute, load(a, "{\"seats\":{\"implementer\":{\"harness\":\"claude_code\",\"command\":\"./bin/claude\"}}}"));
}

test "config: metacodes seats reject command and external-only fields" {
    var arena = arenaFixture();
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};
    try testing.expectError(error.MetacodesSeatHasCommand, validate(try parse(a, "{\"seats\":{\"reviewer\":{\"command\":\"" ++ abs_claude ++ "\"}}}", null), &diag));
    try testing.expectEqual(Role.reviewer, diag.role.?);
    try testing.expectEqualStrings("command", diag.field.?);
    try testing.expectError(error.MetacodesSeatHasCommand, load(a, "{\"seats\":{\"reviewer\":{\"harness\":\"metacodes\",\"command\":\"" ++ abs_claude ++ "\"}}}"));
    try testing.expectError(error.ExternalOnlyField, load(a, "{\"seats\":{\"reviewer\":{\"budget_enforcement\":\"cost\"}}}"));
    try testing.expectError(error.ExternalOnlyField, load(a, "{\"seats\":{\"reviewer\":{\"wallclock_seconds\":5}}}"));
    try testing.expectError(error.ExternalOnlyField, load(a, "{\"seats\":{\"verifier\":{\"demote_only\":true}}}"));
}

test "config: an external verifier must be demote-only; demote_only is verifier-only" {
    var arena = arenaFixture();
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.ExternalVerifierNotDemoteOnly, load(a, "{\"seats\":{\"verifier\":{\"harness\":\"claude_code\",\"command\":\"" ++ abs_claude ++ "\"}}}"));
    try testing.expectError(error.ExternalVerifierNotDemoteOnly, load(a, "{\"seats\":{\"verifier\":{\"harness\":\"claude_code\",\"command\":\"" ++ abs_claude ++ "\",\"demote_only\":false}}}"));
    try testing.expectError(error.DemoteOnlyOutsideVerifier, load(a, "{\"seats\":{\"reviewer\":{\"harness\":\"claude_code\",\"command\":\"" ++ abs_claude ++ "\",\"demote_only\":true}}}"));
}

test "config: wallclock_only requires wallclock_seconds, and only it may carry one" {
    var arena = arenaFixture();
    defer arena.deinit();
    const a = arena.allocator();
    const ext = "\"harness\":\"claude_code\",\"command\":\"" ++ abs_claude ++ "\"";
    try testing.expectError(error.WallclockLimitMissing, load(a, "{\"seats\":{\"implementer\":{" ++ ext ++ ",\"budget_enforcement\":\"wallclock_only\"}}}"));
    try testing.expectError(error.InvalidWallclock, load(a, "{\"seats\":{\"implementer\":{" ++ ext ++ ",\"budget_enforcement\":\"wallclock_only\",\"wallclock_seconds\":0}}}"));
    try testing.expectError(error.WallclockWithoutWallclockOnly, load(a, "{\"seats\":{\"implementer\":{" ++ ext ++ ",\"wallclock_seconds\":60}}}"));
}

test "config: an enabled run without a positive dollar cap is rejected" {
    var arena = arenaFixture();
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.BudgetMissing, load(a, "{\"enabled\":true}"));
    try testing.expectError(error.InvalidBudget, load(a, "{\"enabled\":true,\"budget_usd\":0}"));
    try testing.expectError(error.InvalidBudget, load(a, "{\"enabled\":true,\"budget_usd\":-2.5}"));
    // A disabled run needs no cap, but a nonsensical one is still an error.
    try testing.expect(try load(a, "{\"enabled\":false}") == .disabled);
    try testing.expectError(error.InvalidBudget, load(a, "{\"budget_usd\":-1}"));
}

test "config: merge layers global < project < cli" {
    var arena = arenaFixture();
    defer arena.deinit();
    const a = arena.allocator();
    const global = try parse(a, "{\"budget_usd\":3,\"seats\":{" ++
        "\"implementer\":{\"harness\":\"claude_code\",\"command\":\"" ++ abs_claude ++ "\",\"model\":\"m-global\"}," ++
        "\"reviewer\":{\"effort\":\"low\"}}}", null);
    const project = try parse(a, "{\"enabled\":true,\"seats\":{\"implementer\":{\"model\":\"m-project\"},\"reviewer\":{\"effort\":\"high\"}}}", null);
    const cli = try parse(a, "{\"budget_usd\":1.5}", null);

    const merged = merge(merge(global, project), cli);
    const config = try validate(merged, null);
    try testing.expectEqual(@as(f64, 1.5), config.enabled.budget_usd);
    const implementer = config.enabled.seats.get(.implementer);
    try testing.expectEqualStrings("m-project", implementer.model.?);
    try testing.expectEqualStrings(abs_claude, implementer.harness.claude_code.command.bytes);
    try testing.expectEqual(ReasoningEffort.high, config.enabled.seats.get(.reviewer).effort.?);
    // Merge is pure: the inputs are unchanged.
    try testing.expect(global.enabled == null);
    try testing.expectEqualStrings("m-global", global.seats.get(.implementer).model.?);
}

test "config: switching a seat's harness in a higher layer drops the old harness's fields" {
    var arena = arenaFixture();
    defer arena.deinit();
    const a = arena.allocator();
    const global = try parse(a, "{\"seats\":{\"verifier\":{\"harness\":\"claude_code\",\"command\":\"" ++ abs_claude ++ "\",\"demote_only\":true,\"model\":\"m\"}}}", null);
    const project = try parse(a, "{\"seats\":{\"verifier\":{\"harness\":\"metacodes\"}}}", null);
    const config = try validate(merge(global, project), null);
    try testing.expect(config == .disabled);
    const merged = merge(global, project).seats.get(.verifier);
    try testing.expect(merged.command == null and merged.demote_only == null);
    try testing.expectEqualStrings("m", merged.model.?);
    // Re-stating the same harness keeps the lower layer's command.
    const same = try parse(a, "{\"seats\":{\"verifier\":{\"harness\":\"claude_code\"}}}", null);
    try testing.expectEqualStrings(abs_claude, merge(global, same).seats.get(.verifier).command.?);
}
