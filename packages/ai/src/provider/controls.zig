//! Provider-declared runtime controls (issue #16, "model-dependent runtime
//! controls").
//!
//! The kernel owns *no* control vocabulary. It does not know that "fast" means
//! less reasoning, and it does not assume a reasoning enum is shared across
//! vendors. A provider declares a `ControlSpec` per offer; the kernel validates
//! values against that declaration, normalizes according to the declared policy,
//! and reports requested versus effective values.
//!
//! Values are bounded and copyable by design. A `RuntimeSelection` — including
//! its controls — is stored in configuration documents, snapshotted per turn,
//! and compared across revisions; an allocator-backed map would make every one
//! of those a lifetime problem. The bounds are explicit limits, not silent
//! truncation: exceeding one is an error.

const std = @import("std");

pub const MAX_CONTROLS: usize = 8;
pub const MAX_CONTROL_ID_LEN: usize = 48;
pub const MAX_CONTROL_TEXT_LEN: usize = 192;

pub fn Bounded(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        bytes: [capacity]u8 = @splat(0),
        len: u16 = 0,

        pub fn parse(text: []const u8) error{ControlTextTooLong}!Self {
            if (text.len > capacity) return error.ControlTextTooLong;
            var out = Self{ .len = @intCast(text.len) };
            @memcpy(out.bytes[0..text.len], text);
            return out;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn eqlText(self: Self, text: []const u8) bool {
            return std.mem.eql(u8, self.bytes[0..self.len], text);
        }
    };
}

pub const ControlId = Bounded(MAX_CONTROL_ID_LEN);
pub const ControlText = Bounded(MAX_CONTROL_TEXT_LEN);

pub const ValueKind = enum { enumeration, range, boolean, object };

/// A control value. `object` carries a small JSON document verbatim so a
/// provider extension round-trips without the kernel interpreting it.
pub const Value = union(enum) {
    text: ControlText,
    number: i64,
    boolean: bool,
    object: ControlText,

    pub fn fromText(text: []const u8) error{ControlTextTooLong}!Value {
        return .{ .text = try ControlText.parse(text) };
    }

    pub fn fromObject(json: []const u8) error{ControlTextTooLong}!Value {
        return .{ .object = try ControlText.parse(json) };
    }

    pub fn eql(self: Value, other: Value) bool {
        return switch (self) {
            .text => |value| other == .text and other.text.eqlText(value.slice()),
            .number => |value| other == .number and other.number == value,
            .boolean => |value| other == .boolean and other.boolean == value,
            .object => |value| other == .object and other.object.eqlText(value.slice()),
        };
    }

    pub fn kind(self: Value) ValueKind {
        return switch (self) {
            .text => .enumeration,
            .number => .range,
            .boolean => .boolean,
            .object => .object,
        };
    }
};

pub const Range = struct {
    min: i64,
    max: i64,
    step: ?i64 = null,
};

/// How a provider wants out-of-domain values handled.
pub const Normalization = enum {
    /// Refuse the value. The default: silently changing what the user asked
    /// for is worse than an error they can act on.
    reject,
    /// Pull a numeric value into range.
    clamp,
    /// Substitute the declared default.
    map,
};

/// One provider-declared control on one offer.
pub const ControlSpec = struct {
    schema_version: u16 = 1,
    id: []const u8,
    label: []const u8,
    kind: ValueKind,
    /// Vocabulary for `enumeration` controls. Provider-owned; the kernel never
    /// supplies or extends it.
    allowed_values: []const []const u8 = &.{},
    range: ?Range = null,
    default_value: ?Value = null,
    normalization: Normalization = .reject,
    /// Human-facing note, e.g. "higher cost and latency".
    cost_latency_warning: ?[]const u8 = null,
    confirmation_required: bool = false,
    /// Opaque provider payload, round-tripped through the control plane.
    extension_data: ?[]const u8 = null,
};

pub const ValidationError = error{
    UnknownControl,
    ControlTypeMismatch,
    ValueNotAllowed,
    ValueOutOfRange,
    ControlTextTooLong,
};

/// Narrow error set for storing a value: the only ways `set` can fail are an
/// oversized id and a full set. Keeping it separate from `ValidationError`
/// stops callers from having to handle validation outcomes that cannot occur.
pub const SetError = error{ ControlTextTooLong, TooManyControls };

pub const Validated = struct {
    /// What the caller asked for.
    requested: Value,
    /// What the provider will actually receive after normalization.
    effective: Value,
    normalized: bool,
    warning: ?[]const u8 = null,
    confirmation_required: bool = false,
};

pub fn findSpec(specs: []const ControlSpec, id: []const u8) ?ControlSpec {
    for (specs) |spec| if (std.mem.eql(u8, spec.id, id)) return spec;
    return null;
}

/// Validate one value against its declaration. Runs before any network I/O:
/// selecting an unsupported service tier or reasoning value must fail here,
/// not at the provider.
pub fn validate(spec: ControlSpec, requested: Value) ValidationError!Validated {
    if (requested.kind() != spec.kind) return error.ControlTypeMismatch;
    var result = Validated{
        .requested = requested,
        .effective = requested,
        .normalized = false,
        .warning = spec.cost_latency_warning,
        .confirmation_required = spec.confirmation_required,
    };

    switch (spec.kind) {
        .enumeration => {
            for (spec.allowed_values) |allowed| {
                if (requested.text.eqlText(allowed)) return result;
            }
            switch (spec.normalization) {
                .reject, .clamp => return error.ValueNotAllowed,
                .map => {
                    const fallback = spec.default_value orelse return error.ValueNotAllowed;
                    result.effective = fallback;
                    result.normalized = true;
                    return result;
                },
            }
        },
        .range => {
            const range = spec.range orelse return error.ValueOutOfRange;
            const value = requested.number;
            if (value >= range.min and value <= range.max) return result;
            switch (spec.normalization) {
                .reject => return error.ValueOutOfRange,
                .clamp => {
                    result.effective = .{ .number = std.math.clamp(value, range.min, range.max) };
                    result.normalized = true;
                    return result;
                },
                .map => {
                    const fallback = spec.default_value orelse return error.ValueOutOfRange;
                    result.effective = fallback;
                    result.normalized = true;
                    return result;
                },
            }
        },
        .boolean, .object => return result,
    }
}

// ── control value sets ───────────────────────────────────────────────────────

pub const Entry = struct {
    id: ControlId,
    value: Value,
};

/// Bounded, copyable control set carried by a `RuntimeSelection`.
pub const ControlValues = struct {
    entries: [MAX_CONTROLS]Entry = undefined,
    len: u8 = 0,

    pub fn items(self: *const ControlValues) []const Entry {
        return self.entries[0..self.len];
    }

    pub fn get(self: *const ControlValues, id: []const u8) ?Value {
        for (self.items()) |entry| {
            if (entry.id.eqlText(id)) return entry.value;
        }
        return null;
    }

    pub fn set(self: *ControlValues, id: []const u8, value: Value) SetError!void {
        const key = try ControlId.parse(id);
        for (self.entries[0..self.len]) |*entry| {
            if (entry.id.eqlText(id)) {
                entry.value = value;
                return;
            }
        }
        if (self.len == MAX_CONTROLS) return error.TooManyControls;
        self.entries[self.len] = .{ .id = key, .value = value };
        self.len += 1;
    }

    pub fn remove(self: *ControlValues, id: []const u8) bool {
        for (self.entries[0..self.len], 0..) |entry, index| {
            if (!entry.id.eqlText(id)) continue;
            var cursor = index;
            while (cursor + 1 < self.len) : (cursor += 1) {
                self.entries[cursor] = self.entries[cursor + 1];
            }
            self.len -= 1;
            return true;
        }
        return false;
    }

    pub fn eql(self: ControlValues, other: ControlValues) bool {
        if (self.len != other.len) return false;
        for (self.items()) |entry| {
            const counterpart = other.get(entry.id.slice()) orelse return false;
            if (!entry.value.eql(counterpart)) return false;
        }
        return true;
    }
};

pub const RevalidationOutcome = struct {
    /// Controls that survived, with provider normalization applied.
    effective: ControlValues,
    /// Ids dropped because the new offer does not declare them, or declares
    /// them with an incompatible domain.
    cleared: [MAX_CONTROLS]ControlId = undefined,
    cleared_len: u8 = 0,
    normalized_len: u8 = 0,

    pub fn clearedItems(self: *const RevalidationOutcome) []const ControlId {
        return self.cleared[0..self.cleared_len];
    }

    pub fn changed(self: *const RevalidationOutcome) bool {
        return self.cleared_len != 0 or self.normalized_len != 0;
    }
};

/// Re-validate an existing control set against a different offer's declared
/// controls.
///
/// Switching model, protocol, region, plan, or offer must revalidate: a value
/// the new offer cannot honor is cleared or normalized, never silently carried
/// over. The caller commits the whole outcome atomically or keeps the old
/// runtime — this function never mutates its input.
pub fn revalidate(current: ControlValues, specs: []const ControlSpec) RevalidationOutcome {
    var outcome = RevalidationOutcome{ .effective = .{} };
    for (current.items()) |entry| {
        const spec = findSpec(specs, entry.id.slice()) orelse {
            recordCleared(&outcome, entry.id);
            continue;
        };
        const validated = validate(spec, entry.value) catch {
            recordCleared(&outcome, entry.id);
            continue;
        };
        if (validated.normalized) outcome.normalized_len += 1;
        outcome.effective.set(entry.id.slice(), validated.effective) catch {
            recordCleared(&outcome, entry.id);
        };
    }
    return outcome;
}

fn recordCleared(outcome: *RevalidationOutcome, id: ControlId) void {
    if (outcome.cleared_len == MAX_CONTROLS) return;
    outcome.cleared[outcome.cleared_len] = id;
    outcome.cleared_len += 1;
}

// ── tests ────────────────────────────────────────────────────────────────────

const REASONING_VALUES = [_][]const u8{ "low", "medium", "high" };
const TIER_VALUES = [_][]const u8{ "standard", "priority" };

const OFFER_A_CONTROLS = [_]ControlSpec{
    .{
        .id = "reasoning_effort",
        .label = "Reasoning effort",
        .kind = .enumeration,
        .allowed_values = &REASONING_VALUES,
        .default_value = .{ .text = ControlText.parse("medium") catch unreachable },
        .cost_latency_warning = "higher effort costs more and responds slower",
    },
    .{
        .id = "service_tier",
        .label = "Service tier",
        .kind = .enumeration,
        .allowed_values = &TIER_VALUES,
        .confirmation_required = true,
    },
    .{
        .id = "max_output_tokens",
        .label = "Max output tokens",
        .kind = .range,
        .range = .{ .min = 1, .max = 64_000 },
        .normalization = .clamp,
    },
};

/// A second offer that shares no control vocabulary — the case the kernel must
/// not paper over by assuming enums are shared across vendors.
const OFFER_B_CONTROLS = [_]ControlSpec{.{
    .id = "thinking_budget_tokens",
    .label = "Thinking budget",
    .kind = .range,
    .range = .{ .min = 0, .max = 32_000 },
}};

test "reasoning effort and service tier are separate controls" {
    try std.testing.expect(findSpec(&OFFER_A_CONTROLS, "reasoning_effort") != null);
    try std.testing.expect(findSpec(&OFFER_A_CONTROLS, "service_tier") != null);
    const tier = findSpec(&OFFER_A_CONTROLS, "service_tier").?;
    // Nothing in the tier vocabulary mentions reasoning; the kernel must not
    // conflate "priority" with an effort level.
    for (tier.allowed_values) |value| {
        try std.testing.expect(!std.mem.eql(u8, value, "low"));
        try std.testing.expect(!std.mem.eql(u8, value, "high"));
    }
}

test "an unsupported enum value fails before any request is built" {
    const spec = findSpec(&OFFER_A_CONTROLS, "reasoning_effort").?;
    try std.testing.expectError(
        error.ValueNotAllowed,
        validate(spec, try Value.fromText("ultra")),
    );
    const accepted = try validate(spec, try Value.fromText("high"));
    try std.testing.expect(!accepted.normalized);
    try std.testing.expectEqualStrings(
        "higher effort costs more and responds slower",
        accepted.warning.?,
    );
}

test "normalization policy decides between reject, clamp, and map" {
    const clamped = findSpec(&OFFER_A_CONTROLS, "max_output_tokens").?;
    const outcome = try validate(clamped, .{ .number = 999_999 });
    try std.testing.expect(outcome.normalized);
    try std.testing.expectEqual(@as(i64, 64_000), outcome.effective.number);
    try std.testing.expectEqual(@as(i64, 999_999), outcome.requested.number);

    var mapped = findSpec(&OFFER_A_CONTROLS, "reasoning_effort").?;
    mapped.normalization = .map;
    const substituted = try validate(mapped, try Value.fromText("ultra"));
    try std.testing.expect(substituted.normalized);
    try std.testing.expect(substituted.effective.text.eqlText("medium"));
}

test "a type mismatch is rejected, not coerced" {
    const spec = findSpec(&OFFER_A_CONTROLS, "reasoning_effort").?;
    try std.testing.expectError(error.ControlTypeMismatch, validate(spec, .{ .number = 3 }));
}

test "confirmation requirement is provider-declared and surfaced" {
    const spec = findSpec(&OFFER_A_CONTROLS, "service_tier").?;
    const outcome = try validate(spec, try Value.fromText("priority"));
    try std.testing.expect(outcome.confirmation_required);
}

test "switching offers clears controls the new offer cannot honor" {
    var values = ControlValues{};
    try values.set("reasoning_effort", try Value.fromText("high"));
    try values.set("max_output_tokens", .{ .number = 8_000 });

    const outcome = revalidate(values, &OFFER_B_CONTROLS);
    try std.testing.expect(outcome.changed());
    try std.testing.expectEqual(@as(u8, 2), outcome.cleared_len);
    try std.testing.expectEqual(@as(u8, 0), outcome.effective.len);
    // The input is untouched, so a failed switch can keep the old runtime.
    try std.testing.expectEqual(@as(u8, 2), values.len);
}

test "revalidation keeps compatible controls and normalizes the rest" {
    var values = ControlValues{};
    try values.set("reasoning_effort", try Value.fromText("low"));
    try values.set("max_output_tokens", .{ .number = 120_000 });

    const outcome = revalidate(values, &OFFER_A_CONTROLS);
    try std.testing.expectEqual(@as(u8, 0), outcome.cleared_len);
    try std.testing.expectEqual(@as(u8, 1), outcome.normalized_len);
    try std.testing.expect(outcome.effective.get("reasoning_effort").?.text.eqlText("low"));
    try std.testing.expectEqual(@as(i64, 64_000), outcome.effective.get("max_output_tokens").?.number);
}

test "control values are bounded, copyable, and order-insensitive on compare" {
    var left = ControlValues{};
    try left.set("a", .{ .boolean = true });
    try left.set("b", .{ .number = 2 });
    var right = ControlValues{};
    try right.set("b", .{ .number = 2 });
    try right.set("a", .{ .boolean = true });
    try std.testing.expect(left.eql(right));

    const copy = left;
    try std.testing.expect(copy.eql(left));

    try std.testing.expect(left.remove("a"));
    try std.testing.expect(!left.eql(right));
    try std.testing.expectEqual(@as(?Value, null), left.get("a"));

    var full = ControlValues{};
    var index: usize = 0;
    while (index < MAX_CONTROLS) : (index += 1) {
        var name: [8]u8 = undefined;
        try full.set(try std.fmt.bufPrint(&name, "c{d}", .{index}), .{ .number = 1 });
    }
    try std.testing.expectError(error.TooManyControls, full.set("overflow", .{ .number = 1 }));
    // Overwriting an existing id still works at capacity.
    try full.set("c0", .{ .number = 9 });
    try std.testing.expectEqual(@as(i64, 9), full.get("c0").?.number);
}

test "oversized control text is an error, never silent truncation" {
    const long = "x" ** (MAX_CONTROL_TEXT_LEN + 1);
    try std.testing.expectError(error.ControlTextTooLong, Value.fromText(long));
    var values = ControlValues{};
    const long_id = "i" ** (MAX_CONTROL_ID_LEN + 1);
    try std.testing.expectError(error.ControlTextTooLong, values.set(long_id, .{ .number = 1 }));
}

test "unknown provider extensions round-trip without interpretation" {
    const spec = ControlSpec{
        .id = "vendor_knob",
        .label = "Vendor knob",
        .kind = .object,
        .extension_data = "{\"vendor\":\"acme\"}",
    };
    const outcome = try validate(spec, try Value.fromObject("{\"depth\":2}"));
    try std.testing.expect(outcome.effective.object.eqlText("{\"depth\":2}"));
    try std.testing.expectEqualStrings("{\"vendor\":\"acme\"}", spec.extension_data.?);
}
