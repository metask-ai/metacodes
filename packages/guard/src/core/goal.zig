//! Session-scoped goal state (issue #277).
//!
//! One objective per Session that its Runs work toward, with an optional
//! token budget the runtime charges as provider responses arrive. The shape
//! follows Codex's thread goals (codex-rs/ext/goal) where it matters: the six
//! statuses, `(input - cached) + output` accounting, and a budget crossed
//! mid-Run that tells the model to wrap up instead of cutting the Run off.
//! It is smaller elsewhere: no model-facing goal tools, a continuation Run
//! only when the user or Host asks for one, wall time counted per Run rather
//! than while idle, and refused transitions are errors rather than silent
//! coercions.
//!
//! `status` changes in two places only: `State.apply` (the user's or Host's
//! actions) and `Meter` (the budget running out). Accounting needs nothing
//! from the caller beyond `Meter.charge` per provider response, so every
//! entry point that runs the agent loop with a Meter charges alike - a Run
//! that ends in an error included.

const std = @import("std");
const pfs = @import("platform").fs;
const session_id = @import("metacodes-kernel").session_id;
const time = @import("metacodes-base").util.time;
const util_json = @import("metacodes-base").util.json;

/// Objectives longer than this many code points are refused (Codex's limit).
pub const max_objective_codepoints: usize = 4000;

pub const Status = enum {
    active,
    paused,
    blocked,
    usage_limited,
    budget_limited,
    complete,

    pub fn parse(s: []const u8) ?Status {
        inline for (@typeInfo(Status).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @field(Status, f.name);
        }
        return null;
    }
};

/// What a user or Host may do to the goal. `usage_limited` and
/// `budget_limited` are never requested: the runtime reaches them.
pub const Action = enum {
    /// active -> paused. A Run started while paused charges nothing.
    pause,
    /// Back to active from any other status (`resume` is a Zig keyword),
    /// unless the budget is used up: raise or clear the budget first.
    activate,
    complete,
    block,
};

pub const TransitionError = error{
    NoGoal,
    /// `pause` needs an active (or already paused) goal.
    GoalNotActive,
    /// `activate` with tokens_used >= token_budget.
    BudgetExhausted,
    /// `block` on a complete goal; `activate` reopens it instead.
    GoalComplete,
};

pub const ObjectiveError = error{ EmptyObjective, ObjectiveTooLong, InvalidObjective };

/// The objective as stored: trimmed, non-empty UTF-8 of at most
/// `max_objective_codepoints` code points. Borrows from `raw`.
pub fn normalizeObjective(raw: []const u8) ObjectiveError![]const u8 {
    const objective = std.mem.trim(u8, raw, " \t\r\n");
    if (objective.len == 0) return error.EmptyObjective;
    const codepoints = std.unicode.utf8CountCodepoints(objective) catch return error.InvalidObjective;
    if (codepoints > max_objective_codepoints) return error.ObjectiveTooLong;
    return objective;
}

pub const Goal = struct {
    id: [24]u8,
    objective: []u8,
    status: Status,
    token_budget: ?u64 = null,
    tokens_used: u64 = 0,
    time_used_ms: u64 = 0,
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn deinit(self: *Goal, allocator: std.mem.Allocator) void {
        allocator.free(self.objective);
        self.* = undefined;
    }

    pub fn budgetExhausted(self: *const Goal) bool {
        const budget = self.token_budget orelse return false;
        return self.tokens_used >= budget;
    }

    pub fn clone(self: *const Goal, allocator: std.mem.Allocator) !Goal {
        var copy = self.*;
        copy.objective = try allocator.dupe(u8, self.objective);
        return copy;
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    current: ?Goal = null,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        self.clearInMemory();
    }

    pub fn clearInMemory(self: *State) void {
        if (self.current) |*g| g.deinit(self.allocator);
        self.current = null;
    }

    /// Replaces any goal with a new active one: a new id, usage from zero.
    pub fn setNew(self: *State, objective_raw: []const u8, token_budget: ?u64) !void {
        const objective = try normalizeObjective(objective_raw);
        if (token_budget) |v| {
            if (v == 0) return error.InvalidBudget;
        }
        const owned = try self.allocator.dupe(u8, objective);
        self.clearInMemory();
        const now = nowWallMs();
        const id = session_id.gen();
        self.current = .{
            .id = id.bytes,
            .objective = owned,
            .status = .active,
            .token_budget = token_budget,
            .created_at_ms = now,
            .updated_at_ms = now,
        };
    }

    /// Edits the objective in place: same id, usage and status.
    pub fn editObjective(self: *State, objective_raw: []const u8) !void {
        try self.update(.{ .objective = objective_raw });
    }

    /// Applies a user or Host action, or refuses it and changes nothing.
    pub fn apply(self: *State, action: Action) (TransitionError || error{OutOfMemory})!void {
        self.update(.{ .action = action }) catch |err| return switch (err) {
            error.NoGoal, error.GoalNotActive, error.BudgetExhausted, error.GoalComplete, error.OutOfMemory => |e| e,
            else => unreachable, // no objective or budget in this update
        };
    }

    /// Sets or clears (null) the budget. Room again on a `budget_limited`
    /// goal makes it active; an active goal already past the new budget
    /// becomes `budget_limited` at once.
    pub fn setBudget(self: *State, token_budget: ?u64) !void {
        try self.update(.{ .token_budget = token_budget });
    }

    /// Changes to the current goal, applied together or not at all: the
    /// objective first, then the budget, then the action - so "raise the
    /// budget and resume" is one update.
    pub const Update = struct {
        objective: ?[]const u8 = null,
        /// Outer null keeps the budget; `.{ .token_budget = null }` clears it.
        token_budget: ??u64 = null,
        action: ?Action = null,
    };

    pub const UpdateError = TransitionError || ObjectiveError || error{ InvalidBudget, OutOfMemory };

    pub fn update(self: *State, changes: Update) UpdateError!void {
        const g = if (self.current) |*g| g else return error.NoGoal;
        const objective = if (changes.objective) |raw| try normalizeObjective(raw) else null;
        var next = g.*;
        if (changes.token_budget) |budget| {
            if (budget) |v| {
                if (v == 0) return error.InvalidBudget;
            }
            next.token_budget = budget;
            if (next.status == .budget_limited and !next.budgetExhausted()) {
                next.status = .active;
            } else if (next.status == .active and next.budgetExhausted()) {
                next.status = .budget_limited;
            }
        }
        if (changes.action) |action| next.status = try statusAfter(&next, action);
        const unchanged = next.status == g.status and next.token_budget == g.token_budget and
            (objective == null or std.mem.eql(u8, objective.?, g.objective));
        if (unchanged) return;
        // The only fallible step left; nothing has changed yet.
        if (objective) |text| next.objective = try self.allocator.dupe(u8, text);
        if (objective != null) self.allocator.free(g.objective);
        next.updated_at_ms = nowWallMs();
        g.* = next;
    }

    pub fn loadFromDir(self: *State, session_dir: []const u8) !void {
        const path = try goalPath(self.allocator, session_dir);
        defer self.allocator.free(path);
        const content = try readFileAlloc(self.allocator, path);
        defer self.allocator.free(content);
        const g = try decode(self.allocator, content);
        self.clearInMemory();
        self.current = g;
    }

    pub fn persistToDir(self: *const State, session_dir: []const u8) !void {
        const path = try goalPath(self.allocator, session_dir);
        defer self.allocator.free(path);
        if (self.current == null) {
            const path_z = try self.allocator.dupeZ(u8, path);
            defer self.allocator.free(path_z);
            pfs.unlinkPath(path_z.ptr) catch {}; // 宽字符(#121):goal.json 由 pfs 按精确名写,也按精确名删
            return;
        }
        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp);
        const tmp_z = try self.allocator.dupeZ(u8, tmp);
        defer self.allocator.free(tmp_z);
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        const bytes = try encodeLine(self.allocator, self.current.?);
        defer self.allocator.free(bytes);
        const fd = pfs.open(tmp_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return error.OpenFailed;
        const n = pfs.write(fd, bytes);
        pfs.close(fd); // **rename 前必须关**:Windows MoveFileEx 遇源文件仍打开会共享冲突失败(POSIX 容忍)。
        if (n < 0 or @as(usize, @intCast(n)) != bytes.len) return error.WriteFailed;
        if (pfs.renameReplace(tmp_z.ptr, path_z.ptr) != 0) return error.RenameFailed;
    }
};

/// The status `action` leads to from `g`, or why it is refused.
fn statusAfter(g: *const Goal, action: Action) TransitionError!Status {
    return switch (action) {
        .pause => switch (g.status) {
            .active, .paused => .paused,
            else => error.GoalNotActive,
        },
        .activate => if (g.status == .active)
            .active
        else if (g.budgetExhausted())
            error.BudgetExhausted
        else
            .active,
        .complete => .complete,
        .block => switch (g.status) {
            .complete => error.GoalComplete,
            else => .blocked,
        },
    };
}

/// Charges a Session's goal for the Runs that work toward it. One Meter per
/// Session, handed to the agent loop through `Options.goal_meter`; the loop
/// calls `beginRun`/`endRun` around a Run and `charge` per provider response.
/// A Run charges the goal only if that goal was active when the Run began;
/// once armed it is charged to the Run's end even after the budget runs out
/// mid-Run (the model is asked to wrap up, the Run is not cut off). Not
/// thread-safe: a Session runs one Run at a time, and goal mutations are
/// idle-only.
pub const Meter = struct {
    state: *State,
    observer: ?Observer = null,
    /// Nested `run` calls on the same Meter (a Run inside a Run) charge the
    /// outermost one; only depth 0 -> 1 arms and 1 -> 0 settles.
    depth: u32 = 0,
    armed: ?[24]u8 = null,
    started_ns: time.Nanos = 0,
    budget_notice_pending: bool = false,
    /// The monotonic clock a Run's time is measured with (tests replace it).
    now_ns: *const fn () time.Nanos = time.nowNs,

    pub const Change = enum {
        /// The budget ran out during the Run: the goal is now `budget_limited`.
        budget_reached,
        /// The Run ended and its usage and time are on the goal.
        run_settled,
    };

    pub const Observer = struct {
        ctx: *anyopaque,
        changed: *const fn (ctx: *anyopaque, state: *const State, change: Change) void,
    };

    pub fn init(state: *State) Meter {
        return .{ .state = state };
    }

    pub fn beginRun(self: *Meter) void {
        self.depth += 1;
        if (self.depth != 1) return;
        self.armed = if (self.state.current) |g| (if (g.status == .active) g.id else null) else null;
        self.started_ns = self.now_ns();
        self.budget_notice_pending = false;
    }

    /// Adds one provider response's billable tokens: non-cached input plus
    /// output (the neutral UsageDelta's `input_tokens` already excludes cache
    /// reads).
    /// Returns the goal when this response used up its budget (it is now
    /// `budget_limited`), for the loop to announce.
    pub fn charge(self: *Meter, input_tokens: u64, output_tokens: u64) ?*const Goal {
        if (self.depth == 0) return null;
        const tokens = input_tokens +| output_tokens;
        if (tokens == 0) return null;
        const g = self.armedGoal() orelse return null;
        g.tokens_used +|= tokens;
        g.updated_at_ms = nowWallMs();
        if (g.status != .active or !g.budgetExhausted()) return null;
        g.status = .budget_limited;
        self.budget_notice_pending = true;
        self.notify(.budget_reached);
        return g;
    }

    /// The wrap-up reminder, once per budget crossing, for the loop to append
    /// at the next turn boundary.
    pub fn takeBudgetNotice(self: *Meter) ?[]const u8 {
        if (!self.budget_notice_pending) return null;
        self.budget_notice_pending = false;
        return budget_notice;
    }

    /// Returns the goal the Run settled on, if it charged one.
    pub fn endRun(self: *Meter) ?*const Goal {
        std.debug.assert(self.depth != 0);
        self.depth -= 1;
        if (self.depth != 0) return null;
        defer self.armed = null;
        const g = self.armedGoal() orelse return null;
        const elapsed_ns = self.now_ns() - self.started_ns;
        const elapsed_ms: u64 = if (elapsed_ns <= 0) 0 else @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms));
        g.time_used_ms +|= elapsed_ms;
        g.updated_at_ms = nowWallMs();
        self.notify(.run_settled);
        return g;
    }

    /// The goal this Run is charging: still the one armed at `beginRun`
    /// (a goal replaced since then is not charged for this Run).
    fn armedGoal(self: *Meter) ?*Goal {
        const id = self.armed orelse return null;
        const g = if (self.state.current) |*g| g else return null;
        return if (std.mem.eql(u8, &g.id, &id)) g else null;
    }

    fn notify(self: *Meter, change: Change) void {
        if (self.observer) |o| o.changed(o.ctx, self.state, change);
    }
};

pub const budget_notice =
    "<system-reminder>\nThe token budget for the active goal is used up. Wrap up this turn soon: " ++
    "say what is done and what remains, and do not start new work. Do not mention this reminder.\n</system-reminder>";

/// The input of a continuation Run: work toward `g` from where the
/// conversation left off. The objective is XML-escaped inside `<objective>`.
pub fn continuationPrompt(allocator: std.mem.Allocator, g: *const Goal) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("<system-reminder>\nContinue working toward the active goal.\n<objective>\n");
    try writeXmlEscaped(w, g.objective);
    try w.writeAll("\n</objective>\n");
    if (g.token_budget) |budget| try w.print("Tokens used toward it so far: {d} of {d}.\n", .{ g.tokens_used, budget });
    try w.writeAll(
        "Pick up where the conversation left off and make concrete progress. If the goal is " ++
            "complete or genuinely blocked, say so explicitly in your response: marking the goal is the " ++
            "user's decision, not yours. Do not start unrelated work.\n</system-reminder>",
    );
    return out.toOwnedSlice();
}

fn writeXmlEscaped(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
}

/// `{"id":…,"objective":…,"status":…,"token_budget":…|null,"tokens_used":…,
/// "time_used_ms":…,"created_at_ms":…,"updated_at_ms":…}`: goal.json's
/// line, an AgentCore checkpoint's goal section and its `goal` JSON.
pub fn writeJson(w: *std.Io.Writer, goal: *const Goal) !void {
    try w.writeAll("{\"id\":");
    try util_json.writeJsonString(w, goal.id[0..]);
    try w.writeAll(",\"objective\":");
    try util_json.writeJsonString(w, goal.objective);
    try w.print(",\"status\":\"{s}\"", .{@tagName(goal.status)});
    if (goal.token_budget) |b| {
        try w.print(",\"token_budget\":{d}", .{b});
    } else {
        try w.writeAll(",\"token_budget\":null");
    }
    try w.print(
        ",\"tokens_used\":{d},\"time_used_ms\":{d},\"created_at_ms\":{d},\"updated_at_ms\":{d}}}",
        .{ goal.tokens_used, goal.time_used_ms, goal.created_at_ms, goal.updated_at_ms },
    );
}

pub fn encode(allocator: std.mem.Allocator, goal: Goal) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeJson(&aw.writer, &goal);
    return try aw.toOwnedSlice();
}

fn encodeLine(allocator: std.mem.Allocator, goal: Goal) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeJson(&aw.writer, &goal);
    try aw.writer.writeByte('\n');
    return try aw.toOwnedSlice();
}

/// Parses `encode`'s JSON (trailing whitespace allowed). The objective must
/// satisfy `normalizeObjective` as stored, so a decoded goal is one this
/// module could have written.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Goal {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    return parseGoal(allocator, parsed.value);
}

pub fn goalPath(allocator: std.mem.Allocator, session_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/goal.json", .{session_dir});
}

fn parseGoal(allocator: std.mem.Allocator, value: std.json.Value) !Goal {
    if (value != .object) return error.InvalidGoal;
    const obj = value.object;
    const id_s = try getString(obj, "id");
    if (id_s.len != 24) return error.InvalidGoal;
    var id: [24]u8 = undefined;
    @memcpy(id[0..], id_s);
    const status = Status.parse(try getString(obj, "status")) orelse return error.InvalidGoal;
    const stored = try getString(obj, "objective");
    const normalized = normalizeObjective(stored) catch return error.InvalidGoal;
    if (normalized.len != stored.len) return error.InvalidGoal;
    const objective = try allocator.dupe(u8, stored);
    errdefer allocator.free(objective);
    return .{
        .id = id,
        .objective = objective,
        .status = status,
        .token_budget = try getOptionalU64(obj, "token_budget"),
        .tokens_used = try getU64(obj, "tokens_used"),
        .time_used_ms = try getU64(obj, "time_used_ms"),
        .created_at_ms = try getI64(obj, "created_at_ms"),
        .updated_at_ms = try getI64(obj, "updated_at_ms"),
    };
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = obj.get(key) orelse return error.InvalidGoal;
    if (v != .string) return error.InvalidGoal;
    return v.string;
}

fn getU64(obj: std.json.ObjectMap, key: []const u8) !u64 {
    const v = obj.get(key) orelse return error.InvalidGoal;
    if (v != .integer) return error.InvalidGoal;
    if (v.integer < 0) return error.InvalidGoal;
    return @intCast(v.integer);
}

fn getI64(obj: std.json.ObjectMap, key: []const u8) !i64 {
    const v = obj.get(key) orelse return error.InvalidGoal;
    if (v != .integer) return error.InvalidGoal;
    return @intCast(v.integer);
}

fn getOptionalU64(obj: std.json.ObjectMap, key: []const u8) !?u64 {
    const v = obj.get(key) orelse return null;
    if (v == .null) return null;
    if (v != .integer or v.integer <= 0) return error.InvalidGoal;
    return @intCast(v.integer);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.NotFound;
    defer _ = pfs.close(fd);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &buf);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
        if (out.items.len > 1024 * 1024) return error.FileTooLarge;
    }
    return try out.toOwnedSlice(allocator);
}

fn nowWallMs() i64 {
    return @intCast(@divTrunc(time.nowWallNs(), std.time.ns_per_ms));
}

test "actions follow the transition table and a refusal changes nothing" {
    const a = std.testing.allocator;
    var st = State.init(a);
    defer st.deinit();
    try std.testing.expectError(error.NoGoal, st.apply(.pause));
    try st.setNew("ship it", 10);

    const Case = struct { from: Status, action: Action, to: ?Status, err: ?TransitionError = null };
    for ([_]Case{
        .{ .from = .active, .action = .pause, .to = .paused },
        .{ .from = .paused, .action = .pause, .to = .paused },
        .{ .from = .blocked, .action = .pause, .to = null, .err = error.GoalNotActive },
        .{ .from = .budget_limited, .action = .pause, .to = null, .err = error.GoalNotActive },
        .{ .from = .complete, .action = .pause, .to = null, .err = error.GoalNotActive },
        .{ .from = .paused, .action = .activate, .to = .active },
        .{ .from = .blocked, .action = .activate, .to = .active },
        .{ .from = .usage_limited, .action = .activate, .to = .active },
        .{ .from = .complete, .action = .activate, .to = .active },
        .{ .from = .active, .action = .complete, .to = .complete },
        .{ .from = .budget_limited, .action = .complete, .to = .complete },
        .{ .from = .paused, .action = .block, .to = .blocked },
        .{ .from = .complete, .action = .block, .to = null, .err = error.GoalComplete },
    }) |case| {
        st.current.?.status = case.from;
        if (case.err) |expected| {
            try std.testing.expectError(expected, st.apply(case.action));
            try std.testing.expectEqual(case.from, st.current.?.status);
        } else {
            try st.apply(case.action);
            try std.testing.expectEqual(case.to.?, st.current.?.status);
        }
    }

    // A used-up budget cannot be resumed past; raising it can.
    st.current.?.status = .paused;
    st.current.?.tokens_used = 10;
    try std.testing.expectError(error.BudgetExhausted, st.apply(.activate));
    try std.testing.expectEqual(Status.paused, st.current.?.status);
    st.current.?.status = .budget_limited;
    try std.testing.expectError(error.BudgetExhausted, st.apply(.activate));
    try st.setBudget(20);
    try std.testing.expectEqual(Status.active, st.current.?.status);
    // Lowering an active goal's budget below its usage limits it at once.
    try st.setBudget(5);
    try std.testing.expectEqual(Status.budget_limited, st.current.?.status);
    try st.setBudget(null);
    try std.testing.expectEqual(Status.active, st.current.?.status);
    try std.testing.expectError(error.InvalidBudget, st.setBudget(0));
}

test "an update applies objective, budget and action together or not at all" {
    const a = std.testing.allocator;
    var st = State.init(a);
    defer st.deinit();
    try st.setNew("ship it", 10);
    st.current.?.tokens_used = 10;
    st.current.?.status = .complete;
    const before = st.current.?.updated_at_ms;

    // The action is refused, so the new objective and budget are not kept.
    try std.testing.expectError(error.GoalNotActive, st.update(.{ .objective = "ship more", .token_budget = 50, .action = .pause }));
    try std.testing.expectEqualStrings("ship it", st.current.?.objective);
    try std.testing.expectEqual(@as(?u64, 10), st.current.?.token_budget);
    try std.testing.expectEqual(Status.complete, st.current.?.status);
    try std.testing.expectEqual(before, st.current.?.updated_at_ms);

    // Raise the budget and complete in one update; the budget alone would
    // have made the budget_limited goal active.
    st.current.?.status = .budget_limited;
    try st.update(.{ .objective = "ship more", .token_budget = 50, .action = .complete });
    try std.testing.expectEqualStrings("ship more", st.current.?.objective);
    try std.testing.expectEqual(@as(?u64, 50), st.current.?.token_budget);
    try std.testing.expectEqual(Status.complete, st.current.?.status);
    // Clearing the budget is a change of its own.
    try st.update(.{ .token_budget = @as(?u64, null) });
    try std.testing.expectEqual(@as(?u64, null), st.current.?.token_budget);
}

test "objectives are trimmed, non-empty UTF-8 of at most 4000 code points" {
    const a = std.testing.allocator;
    var st = State.init(a);
    defer st.deinit();
    try std.testing.expectError(error.InvalidBudget, st.setNew("bad budget", 0));
    try std.testing.expectError(error.EmptyObjective, st.setNew(" \t\n", null));
    try std.testing.expectError(error.InvalidObjective, st.setNew("bad \xff byte", null));
    // 4000 three-byte code points fit; one more does not.
    const longest = "\u{4e2d}" ** max_objective_codepoints;
    try st.setNew(" " ++ longest ++ " ", null);
    try std.testing.expectEqualStrings(longest, st.current.?.objective);
    try std.testing.expectError(error.ObjectiveTooLong, st.editObjective(longest ++ "x"));
    try std.testing.expectEqualStrings(longest, st.current.?.objective);
    try st.editObjective("ship it safely");
    try std.testing.expectEqualStrings("ship it safely", st.current.?.objective);
}

const FakeClock = struct {
    var now: time.Nanos = 0;
    fn read() time.Nanos {
        return now;
    }
};

const ObserverProbe = struct {
    budget_reached: u32 = 0,
    run_settled: u32 = 0,

    fn changed(raw: *anyopaque, _: *const State, change: Meter.Change) void {
        const self: *ObserverProbe = @ptrCast(@alignCast(raw));
        switch (change) {
            .budget_reached => self.budget_reached += 1,
            .run_settled => self.run_settled += 1,
        }
    }
};

test "the Meter charges a Run armed on an active goal, to its end, and asks once for a wrap-up" {
    const a = std.testing.allocator;
    var st = State.init(a);
    defer st.deinit();
    var probe = ObserverProbe{};
    var meter = Meter.init(&st);
    meter.observer = .{ .ctx = &probe, .changed = ObserverProbe.changed };
    meter.now_ns = FakeClock.read;
    FakeClock.now = 0;

    // No goal, or a paused one: nothing is charged.
    meter.beginRun();
    _ = meter.charge(5, 5);
    _ = meter.endRun();
    try st.setNew("ship it", 12);
    try st.apply(.pause);
    meter.beginRun();
    _ = meter.charge(5, 5);
    _ = meter.endRun();
    try std.testing.expectEqual(@as(u64, 0), st.current.?.tokens_used);
    try std.testing.expectEqual(@as(u32, 0), probe.run_settled);

    // Active: charged per response; crossing the budget mid-Run limits the
    // goal, asks once for a wrap-up, and keeps charging to the Run's end.
    try st.apply(.activate);
    FakeClock.now = 10 * std.time.ns_per_s;
    meter.beginRun();
    _ = meter.charge(4, 3);
    try std.testing.expect(meter.takeBudgetNotice() == null);
    meter.beginRun(); // a nested Run charges the outer one
    _ = meter.charge(3, 2);
    _ = meter.endRun();
    try std.testing.expectEqual(Status.budget_limited, st.current.?.status);
    try std.testing.expectEqual(@as(u32, 1), probe.budget_reached);
    try std.testing.expectEqualStrings(budget_notice, meter.takeBudgetNotice().?);
    try std.testing.expect(meter.takeBudgetNotice() == null);
    _ = meter.charge(1, 1);
    FakeClock.now += 2500 * std.time.ns_per_ms;
    _ = meter.endRun();
    try std.testing.expectEqual(@as(u64, 14), st.current.?.tokens_used);
    // The Run's wall time, once, however many Runs nested inside it.
    try std.testing.expectEqual(@as(u64, 2500), st.current.?.time_used_ms);
    try std.testing.expectEqual(@as(u32, 1), probe.budget_reached);
    try std.testing.expectEqual(@as(u32, 1), probe.run_settled);

    // A Run that starts budget_limited charges nothing.
    meter.beginRun();
    _ = meter.charge(9, 9);
    _ = meter.endRun();
    try std.testing.expectEqual(@as(u64, 14), st.current.?.tokens_used);

    // A goal replaced since the Run began is not charged for it.
    try st.setNew("first", null);
    meter.beginRun();
    try st.setNew("replacement", null);
    _ = meter.charge(9, 9);
    _ = meter.endRun();
    try std.testing.expectEqual(@as(u64, 0), st.current.?.tokens_used);
    try std.testing.expectEqual(@as(u64, 0), st.current.?.time_used_ms);
}

test "the continuation prompt escapes the objective and reports the budget" {
    const a = std.testing.allocator;
    var st = State.init(a);
    defer st.deinit();
    try st.setNew("fix <a> & </objective>", 100);
    st.current.?.tokens_used = 40;
    const prompt = try continuationPrompt(a, &st.current.?);
    defer a.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "<objective>\nfix &lt;a&gt; &amp; &lt;/objective&gt;\n</objective>") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Tokens used toward it so far: 40 of 100.") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, prompt, "</objective>"));
}

test "goal state persist/load roundtrip, and decode refuses what encode never writes" {
    const a = std.testing.allocator;
    var _db: [512]u8 = undefined;
    const dir = @import("metacodes-base").tools.test_tmp.path(&_db, "goal-roundtrip");
    ensureTestDir(dir) catch {};
    var st = State.init(a);
    defer st.deinit();
    try st.setNew("round trip", 123);
    var meter = Meter.init(&st);
    meter.beginRun();
    _ = meter.charge(4, 3);
    _ = meter.endRun();
    try st.persistToDir(dir);

    var loaded = State.init(a);
    defer loaded.deinit();
    try loaded.loadFromDir(dir);
    try std.testing.expectEqualStrings(st.current.?.id[0..], loaded.current.?.id[0..]);
    try std.testing.expectEqualStrings("round trip", loaded.current.?.objective);
    try std.testing.expectEqual(@as(u64, 123), loaded.current.?.token_budget.?);
    try std.testing.expectEqual(@as(u64, 7), loaded.current.?.tokens_used);

    const encoded = try encode(a, st.current.?);
    defer a.free(encoded);
    var decoded = try decode(a, encoded);
    defer decoded.deinit(a);
    try std.testing.expectEqualStrings("round trip", decoded.objective);
    const untrimmed = try std.mem.replaceOwned(u8, a, encoded, "\"round trip\"", "\" round trip\"");
    defer a.free(untrimmed);
    try std.testing.expectError(error.InvalidGoal, decode(a, untrimmed));

    loaded.clearInMemory();
    try loaded.persistToDir(dir);
    try std.testing.expectError(error.NotFound, loaded.loadFromDir(dir));
}

fn ensureTestDir(path: []const u8) !void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    if (pfs.mkdir(@ptrCast(&buf), 0o700) != 0) {
        if (!pfs.lastErrnoIs(.EXIST)) return error.MkdirFailed;
    }
}
