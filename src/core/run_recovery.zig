//! Pure reducer for active-Run recovery state.
//!
//! The reducer performs no I/O. Live execution and journal replay feed it the
//! same records, so every crash prefix has one deterministic interpretation.

const std = @import("std");
const effect = @import("execution_effect.zig");

pub const EffectKey = struct {
    bytes: [32]u8,

    pub fn fromBytes(value: []const u8) EffectKey {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
        return .{ .bytes = digest };
    }

    pub fn fromSha256Hex(value: [64]u8) error{InvalidEffectKey}!EffectKey {
        var decoded: [32]u8 = undefined;
        for (&decoded, 0..) |*byte, index| {
            const high = hexNibble(value[index * 2]) orelse return error.InvalidEffectKey;
            const low = hexNibble(value[index * 2 + 1]) orelse return error.InvalidEffectKey;
            byte.* = (@as(u8, high) << 4) | low;
        }
        return .{ .bytes = decoded };
    }
};

/// The Record tag supplies the effect kind. Keeping it out of this payload
/// makes a `provider_intent` carrying `kind = tool` unrepresentable.
pub const Intent = struct {
    key: EffectKey,
    replay: effect.ReplayPolicy,
};

pub const PendingEffect = struct {
    kind: enum { provider, tool },
    replay: effect.ReplayPolicy,
};

pub const ActivePhase = enum { running, closing };

pub const ActiveRun = struct {
    run_key: EffectKey,
    phase: ActivePhase = .running,
};

pub const State = union(enum) {
    idle,
    active: ActiveRun,
    poisoned,
};

pub const Record = union(enum) {
    run_started: EffectKey,
    provider_intent: Intent,
    provider_result: EffectKey,
    tool_intent: Intent,
    tool_result: EffectKey,
    run_closing,
    run_finished,
    poison,
};

pub const Error = error{
    RunAlreadyActive,
    NoActiveRun,
    DuplicateIntent,
    ResultWithoutIntent,
    RunHasPendingEffects,
    RunNotClosing,
    TooManyPendingEffects,
    Poisoned,
};

/// Pure state machine plus an allocator-owned pending set. Ephemeral sessions
/// construct none of this state; durable profiles pay only for effects that
/// are actually in flight. `max_pending` is a host-selected resource bound.
pub const Reducer = struct {
    allocator: std.mem.Allocator,
    max_pending: usize,
    state: State = .idle,
    pending: std.AutoHashMap(EffectKey, PendingEffect),
    initialized: bool = true,

    pub fn init(allocator: std.mem.Allocator, max_pending: usize) Reducer {
        return .{
            .allocator = allocator,
            .max_pending = max_pending,
            .pending = std.AutoHashMap(EffectKey, PendingEffect).init(allocator),
        };
    }

    pub fn deinit(self: *Reducer) void {
        if (!self.initialized) return;
        self.pending.deinit();
        self.initialized = false;
    }

    pub fn apply(self: *Reducer, record: Record) (Error || std.mem.Allocator.Error)!void {
        std.debug.assert(self.initialized);
        if (self.state == .poisoned) return error.Poisoned;
        if (record == .poison) {
            self.pending.clearRetainingCapacity();
            self.state = .poisoned;
            return;
        }
        switch (record) {
            .run_started => |run_key| switch (self.state) {
                .idle => self.state = .{ .active = .{ .run_key = run_key } },
                .active => return error.RunAlreadyActive,
                .poisoned => unreachable,
            },
            .provider_intent => |intent| try self.add(.provider, intent),
            .provider_result => |key| try self.remove(.provider, key),
            .tool_intent => |intent| try self.add(.tool, intent),
            .tool_result => |key| try self.remove(.tool, key),
            .run_closing => {
                const active = activeRun(&self.state) orelse return error.NoActiveRun;
                if (active.phase != .running) return error.RunNotClosing;
                if (self.pending.count() != 0) return error.RunHasPendingEffects;
                active.phase = .closing;
            },
            .run_finished => {
                const active = activeRun(&self.state) orelse return error.NoActiveRun;
                if (active.phase != .closing) return error.RunNotClosing;
                std.debug.assert(self.pending.count() == 0);
                self.state = .idle;
            },
            .poison => unreachable,
        }
    }

    pub fn nextRecoveryAction(self: *const Reducer) RecoveryAction {
        std.debug.assert(self.initialized);
        const active = switch (self.state) {
            .active => |value| value,
            .idle, .poisoned => return .none,
        };
        if (active.phase == .closing or self.pending.count() == 0) return .none;

        // Hash-map iteration is deliberately not part of the contract. Choose
        // the smallest key so replay is stable across targets/allocator history.
        var selected_key: ?EffectKey = null;
        var selected: PendingEffect = undefined;
        var iterator = self.pending.iterator();
        while (iterator.next()) |entry| {
            if (selected_key == null or std.mem.order(
                u8,
                &entry.key_ptr.bytes,
                &selected_key.?.bytes,
            ) == .lt) {
                selected_key = entry.key_ptr.*;
                selected = entry.value_ptr.*;
            }
        }
        return actionFor(selected_key.?, selected);
    }

    fn add(
        self: *Reducer,
        kind: @FieldType(PendingEffect, "kind"),
        intent: Intent,
    ) (Error || std.mem.Allocator.Error)!void {
        const active = activeRun(&self.state) orelse return error.NoActiveRun;
        if (active.phase != .running) return error.RunHasPendingEffects;
        if (self.pending.contains(intent.key)) return error.DuplicateIntent;
        if (self.pending.count() >= self.max_pending) return error.TooManyPendingEffects;
        try self.pending.put(intent.key, .{ .kind = kind, .replay = intent.replay });
    }

    fn remove(
        self: *Reducer,
        kind: @FieldType(PendingEffect, "kind"),
        key: EffectKey,
    ) Error!void {
        const active = activeRun(&self.state) orelse return error.NoActiveRun;
        if (active.phase != .running) return error.ResultWithoutIntent;
        const pending = self.pending.get(key) orelse return error.ResultWithoutIntent;
        if (pending.kind != kind) return error.ResultWithoutIntent;
        _ = self.pending.remove(key);
    }
};

pub const RecoveryAction = union(enum) {
    none,
    retry: EffectKey,
    probe_then_decide: EffectKey,
    synthesize_interrupted: EffectKey,
};

fn actionFor(key: EffectKey, pending: PendingEffect) RecoveryAction {
    return switch (pending.replay) {
        .read_only, .idempotent => .{ .retry = key },
        .reobservable => .{ .probe_then_decide = key },
        .never => .{ .synthesize_interrupted = key },
    };
}

fn activeRun(state: *State) ?*ActiveRun {
    return switch (state.*) {
        .active => |*active| active,
        .idle, .poisoned => null,
    };
}

fn hexNibble(byte: u8) ?u4 {
    return switch (byte) {
        '0'...'9' => @intCast(byte - '0'),
        'a'...'f' => @intCast(byte - 'a' + 10),
        else => null,
    };
}

test "reducer permits bounded parallel tools and closes only after every result" {
    const run_key = EffectKey.fromBytes("run");
    const first = Intent{ .key = EffectKey.fromBytes("first"), .replay = .read_only };
    const second = Intent{ .key = EffectKey.fromBytes("second"), .replay = .never };
    var reducer = Reducer.init(std.testing.allocator, 2);
    defer reducer.deinit();
    try reducer.apply(.{ .run_started = run_key });
    try reducer.apply(.{ .tool_intent = first });
    try reducer.apply(.{ .tool_intent = second });
    try std.testing.expectError(error.RunHasPendingEffects, reducer.apply(.run_closing));
    try reducer.apply(.{ .tool_result = first.key });
    try std.testing.expect(reducer.nextRecoveryAction() == .synthesize_interrupted);
    try reducer.apply(.{ .tool_result = second.key });
    try reducer.apply(.run_closing);
    try reducer.apply(.run_finished);
    try std.testing.expect(reducer.state == .idle);
}

test "reducer accepts provider and tool overlap while preserving typed results" {
    var reducer = Reducer.init(std.testing.allocator, 2);
    defer reducer.deinit();
    try reducer.apply(.{ .run_started = EffectKey.fromBytes("run") });
    const provider = Intent{ .key = EffectKey.fromBytes("provider"), .replay = .never };
    try reducer.apply(.{ .provider_intent = provider });
    const tool = Intent{ .key = EffectKey.fromBytes("tool"), .replay = .read_only };
    try reducer.apply(.{ .tool_intent = tool });
    try std.testing.expect(reducer.nextRecoveryAction() == .synthesize_interrupted);
    try std.testing.expectError(error.ResultWithoutIntent, reducer.apply(.{ .tool_result = provider.key }));
    try reducer.apply(.{ .provider_result = provider.key });
    try std.testing.expect(reducer.nextRecoveryAction() == .retry);
    try reducer.apply(.{ .tool_result = tool.key });
}

test "reducer enforces host bound without preallocating it" {
    var reducer = Reducer.init(std.testing.allocator, 1);
    defer reducer.deinit();
    try reducer.apply(.{ .run_started = EffectKey.fromBytes("run") });
    try reducer.apply(.{ .tool_intent = .{
        .key = EffectKey.fromBytes("first"),
        .replay = .read_only,
    } });
    try std.testing.expectError(error.TooManyPendingEffects, reducer.apply(.{ .tool_intent = .{
        .key = EffectKey.fromBytes("second"),
        .replay = .never,
    } }));
}

test "reducer requires matching intent and makes poison terminal" {
    var reducer = Reducer.init(std.testing.allocator, 1);
    defer reducer.deinit();
    try reducer.apply(.{ .run_started = EffectKey.fromBytes("run") });
    try std.testing.expectError(
        error.ResultWithoutIntent,
        reducer.apply(.{ .tool_result = EffectKey.fromBytes("missing") }),
    );
    try reducer.apply(.poison);
    try std.testing.expectError(error.Poisoned, reducer.apply(.run_finished));
}

test "sha256 effect keys decode rather than hash the printable hex" {
    const hex = [_]u8{'a'} ** 64;
    const key = try EffectKey.fromSha256Hex(hex);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xaa} ** 32), &key.bytes);
    try std.testing.expectError(
        error.InvalidEffectKey,
        EffectKey.fromSha256Hex([_]u8{'z'} ** 64),
    );
}
