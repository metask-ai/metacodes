//! Typed execution-effect protocol shared by the fixed AgentLoop, durable
//! journals, and deterministic tests.
//!
//! A declaration is only a candidate supplied by a tool/runtime catalog.  The
//! kernel resolves it into a `ReplayPolicy` for one concrete invocation.  This
//! separation prevents a plugin from turning executable authority into a
//! replay-safe operation merely by setting metadata.

const std = @import("std");

pub const SCHEMA_VERSION = "metacodes-execution-effect-v1";

/// Static candidate attached to a tool implementation.  `idempotent` and
/// `reobservable` still resolve to `.never` unless the kernel can bind the
/// invocation to the corresponding non-zero receipt.
pub const ReplayDeclaration = enum {
    never,
    read_only,
    idempotent,
    reobservable,
};

pub const OperationKey = struct {
    bytes: [64]u8,

    pub fn parse(value: [64]u8) error{InvalidOperationKey}!OperationKey {
        if (!validSha256(value) or allZero(value)) return error.InvalidOperationKey;
        return .{ .bytes = value };
    }
};

pub const ReobservationKind = enum {
    file_target,
    host_resource,
};

pub const ReobservationReceipt = struct {
    kind: ReobservationKind,
    receipt_sha256: [64]u8,

    pub fn init(
        kind: ReobservationKind,
        receipt_sha256: [64]u8,
    ) error{InvalidReobservationReceipt}!ReobservationReceipt {
        if (!validSha256(receipt_sha256) or allZero(receipt_sha256))
            return error.InvalidReobservationReceipt;
        return .{ .kind = kind, .receipt_sha256 = receipt_sha256 };
    }
};

/// Invocation-bound recovery authority.  The payload-bearing variants make an
/// unsupported "idempotent=true" state unrepresentable.
pub const ReplayPolicy = union(enum) {
    never,
    read_only,
    idempotent: OperationKey,
    reobservable: ReobservationReceipt,

    pub fn permitsAutomaticReplay(self: ReplayPolicy) bool {
        return switch (self) {
            .read_only, .idempotent => true,
            .never, .reobservable => false,
        };
    }
};

/// Resolve a declaration without invocation evidence.  The kernel may later
/// upgrade the result only by supplying a typed key/receipt through the two
/// explicit resolver functions below.
pub fn resolveWithoutEvidence(declaration: ReplayDeclaration) ReplayPolicy {
    return switch (declaration) {
        .read_only => .read_only,
        .never, .idempotent, .reobservable => .never,
    };
}

pub fn resolveIdempotent(
    declaration: ReplayDeclaration,
    key: OperationKey,
) ReplayPolicy {
    return if (declaration == .idempotent) .{ .idempotent = key } else .never;
}

pub fn resolveReobservable(
    declaration: ReplayDeclaration,
    receipt: ReobservationReceipt,
) ReplayPolicy {
    return if (declaration == .reobservable)
        .{ .reobservable = receipt }
    else
        .never;
}

pub const Usage = struct {
    input_tokens: u64,
    output_tokens: u64,
    cache_read_input_tokens: u64,
    cache_creation_input_tokens: u64,
};

/// A failed request that produced no provider usage object is unknown, never a
/// synthetic zero.  `known` may legitimately contain four zero counters when a
/// provider explicitly reports them.
pub const Metering = union(enum) {
    unknown,
    known: Usage,
};

pub const ProviderAttemptOutcome = enum {
    succeeded,
    api_error,
    context_window_exceeded,
    stream_error,
    aborted,
};

pub const ProviderAttemptStarted = struct {
    schema_version: []const u8 = SCHEMA_VERSION,
    attempt_id: [64]u8,
    actor_id: [24]u8,
    request_sha256: [64]u8,
    logical_turn: u32,
    context_generation: u32,
    physical_attempt: u32,
    max_attempts: u32,
};

pub const ProviderAttemptFinished = struct {
    schema_version: []const u8 = SCHEMA_VERSION,
    attempt_id: [64]u8,
    outcome: ProviderAttemptOutcome,
    metering: Metering,
};

pub const ToolDispatchStarted = struct {
    id_sha256: [64]u8,
    input_sha256: [64]u8,
    replay: ReplayPolicy,
};

pub const ToolDispatchFinished = struct {
    id_sha256: [64]u8,
    outcome: enum { succeeded, failed, pending, indeterminate },
};

pub const Intent = union(enum) {
    provider_request: ProviderAttemptStarted,
    tool_dispatch: ToolDispatchStarted,
};

pub const Result = union(enum) {
    provider_request: ProviderAttemptFinished,
    tool_dispatch: ToolDispatchFinished,
};

pub const BoundaryEvent = union(enum) {
    before: Intent,
    after: Result,
};

/// Optional execution boundary.  Product builds leave it null unless a
/// durability adapter is configured; deterministic tests install a gate that
/// can stop at every event.  Returning false is fail-closed.
pub const Boundary = struct {
    ctx: *anyopaque,
    emitFn: *const fn (ctx: *anyopaque, event: BoundaryEvent) bool,

    pub fn emit(self: Boundary, event: BoundaryEvent) bool {
        return self.emitFn(self.ctx, event);
    }
};

pub const ProviderAttemptEvent = union(enum) {
    started: ProviderAttemptStarted,
    finished: ProviderAttemptFinished,
};

pub fn validateProviderAttemptEvent(event: ProviderAttemptEvent) bool {
    return switch (event) {
        .started => |started| std.mem.eql(u8, started.schema_version, SCHEMA_VERSION) and
            validSha256(started.attempt_id) and !allZero(started.attempt_id) and
            validLowerHex(&started.actor_id) and
            validSha256(started.request_sha256) and !allZero(started.request_sha256) and
            std.mem.eql(u8, &started.attempt_id, &providerAttemptId(
                started.actor_id,
                started.request_sha256,
                started.logical_turn,
                started.context_generation,
                started.physical_attempt,
            )) and
            started.logical_turn != 0 and started.physical_attempt != 0 and
            started.max_attempts != 0 and started.physical_attempt <= started.max_attempts,
        .finished => |finished| std.mem.eql(u8, finished.schema_version, SCHEMA_VERSION) and
            validSha256(finished.attempt_id) and !allZero(finished.attempt_id),
    };
}

pub fn sha256Hex(parts: []const []const u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (parts) |part| {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(part.len), .little);
        hasher.update(&length);
        hasher.update(part);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn providerAttemptId(
    actor_id: [24]u8,
    request_sha256: [64]u8,
    logical_turn: u32,
    context_generation: u32,
    physical_attempt: u32,
) [64]u8 {
    var turn_bytes: [4]u8 = undefined;
    var generation_bytes: [4]u8 = undefined;
    var attempt_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &turn_bytes, logical_turn, .little);
    std.mem.writeInt(u32, &generation_bytes, context_generation, .little);
    std.mem.writeInt(u32, &attempt_bytes, physical_attempt, .little);
    return sha256Hex(&.{
        "metacodes-provider-attempt-v1",
        &actor_id,
        &request_sha256,
        &turn_bytes,
        &generation_bytes,
        &attempt_bytes,
    });
}

pub fn validSha256(value: [64]u8) bool {
    return validLowerHex(&value);
}

fn validLowerHex(value: []const u8) bool {
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn allZero(value: [64]u8) bool {
    for (value) |byte| if (byte != '0') return false;
    return true;
}

test "replay declarations cannot grant idempotent or reobservable authority without evidence" {
    try std.testing.expect(resolveWithoutEvidence(.never) == .never);
    try std.testing.expect(resolveWithoutEvidence(.read_only) == .read_only);
    try std.testing.expect(resolveWithoutEvidence(.idempotent) == .never);
    try std.testing.expect(resolveWithoutEvidence(.reobservable) == .never);

    const key = try OperationKey.parse(.{'a'} ** 64);
    const resolved = resolveIdempotent(.idempotent, key);
    try std.testing.expect(resolved == .idempotent);
    try std.testing.expect(resolved.permitsAutomaticReplay());
    try std.testing.expect(resolveIdempotent(.never, key) == .never);

    const receipt = try ReobservationReceipt.init(.file_target, .{'b'} ** 64);
    try std.testing.expect(resolveReobservable(.reobservable, receipt) == .reobservable);
    try std.testing.expect(!resolveReobservable(.reobservable, receipt).permitsAutomaticReplay());
}

test "unknown provider metering is distinct from a known zero report" {
    const unknown = Metering.unknown;
    const known = Metering{ .known = .{
        .input_tokens = 0,
        .output_tokens = 0,
        .cache_read_input_tokens = 0,
        .cache_creation_input_tokens = 0,
    } };
    try std.testing.expect(unknown == .unknown);
    try std.testing.expect(known == .known);
}

test "provider attempt identity separates concurrent actors" {
    const request = sha256Hex(&.{"same-request"});
    const first = providerAttemptId([_]u8{'1'} ** 24, request, 1, 0, 1);
    const second = providerAttemptId([_]u8{'2'} ** 24, request, 1, 0, 1);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}
