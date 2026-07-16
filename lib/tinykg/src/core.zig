const std = @import("std");

pub const NodeId = enum(u64) {
    none = 0,
    _,

    pub fn fromInt(value: u64) NodeId {
        return @enumFromInt(value);
    }

    pub fn toInt(self: NodeId) u64 {
        return @intFromEnum(self);
    }
};

pub const EdgeId = enum(u64) {
    none = 0,
    _,

    pub fn fromInt(value: u64) EdgeId {
        return @enumFromInt(value);
    }

    pub fn toInt(self: EdgeId) u64 {
        return @intFromEnum(self);
    }
};

pub const StringId = enum(u64) {
    none = 0,
    _,
};

pub const PropBlockId = enum(u64) {
    none = 0,
    _,
};

pub const NodeKind = enum(u16) {
    repo,
    directory,
    file,
    symbol,
    function,
    type_decl,
    document,
    document_section,
    image,
    media,
    task,
    decision,
    evidence,
    verification,
    observation,
    command,
    error_event,
    edit,
    fix,
    concept,
    user_preference,
    relation_kind,
    relation_policy,
    project,
    _,
};

pub const RelKind = enum(u16) {
    contains,
    defines,
    declares,
    calls,
    imports,
    depends_on,
    mentions,
    explains,
    references,
    based_on,
    evidences,
    verified_by,
    blocks,
    precedes,
    derived_from,
    summarizes,
    modified,
    resolved_by,
    related_to,
    deprecated_by,
    merged_into,
    task_event,
    contain,
    // 跨模块引用关系(RelationClass .ref)—— 任务闭合时的"目标导向投影":
    // acts_on=作用于对象 / uses=使用了方法·概念·工具 / produces=产出产物 / about=兜底。
    // src 限 task 系,dst 松(见 addAgentDagProfile 的 endpoint rule)。
    acts_on, // 23
    uses, // 24
    produces, // 25
    about, // 26
    _,
};

pub fn parseNodeKind(value: []const u8) ?NodeKind {
    inline for (@typeInfo(NodeKind).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(value, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

pub fn parseRelKind(value: []const u8) ?RelKind {
    inline for (@typeInfo(RelKind).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(value, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

pub const EpistemicStatus = enum(u8) {
    observed,
    asserted,
    hypothesis,
    decision,
    derived,
    verified,
    disputed,
    stale,
};

pub const RecordStatus = enum(u8) {
    active,
    deleted,
    stale,
    disputed,
    merged,
};

pub const QueryBudget = struct {
    max_depth: u8 = 3,
    max_results: usize = 200,
    max_visited_nodes: usize = 10_000,
    max_visited_edges: usize = 50_000,
    max_text_postings_scanned: usize = default_max_text_postings_scanned,
    timeout_ms: u64 = 1_000,
};

pub const default_max_text_postings_scanned: usize = 100_000;

pub const QueryDeadline = union(enum) {
    none,
    immediate,
    at: struct {
        io: std.Io,
        timestamp: std.Io.Timestamp,
    },

    pub fn immediateOrNone(timeout_ms: u64) QueryDeadline {
        return if (timeout_ms == 0) .immediate else .none;
    }

    pub fn fromIo(io: std.Io, timeout_ms: u64) QueryDeadline {
        if (timeout_ms == 0) return .immediate;
        const start = std.Io.Clock.awake.now(io);
        return .{ .at = .{ .io = io, .timestamp = start.addDuration(queryTimeoutDuration(timeout_ms)) } };
    }

    pub fn expired(self: QueryDeadline) bool {
        return switch (self) {
            .none => false,
            .immediate => true,
            .at => |deadline| !std.math.order(std.Io.Clock.awake.now(deadline.io).nanoseconds, deadline.timestamp.nanoseconds).compare(.lt),
        };
    }
};

pub fn queryTimeoutDuration(timeout_ms: u64) std.Io.Duration {
    const capped_ms: i64 = if (timeout_ms > @as(u64, @intCast(std.math.maxInt(i64))))
        std.math.maxInt(i64)
    else
        @intCast(timeout_ms);
    return std.Io.Duration.fromMilliseconds(capped_ms);
}

pub const Error = error{
    InvalidId,
    NotFound,
    BudgetExceeded,
    CycleDetected,
    CycleCheckUncertain,
    Unsupported,
};

test "ids round-trip through integers" {
    const node = NodeId.fromInt(42);
    try std.testing.expectEqual(@as(u64, 42), node.toInt());

    const edge = EdgeId.fromInt(9);
    try std.testing.expectEqual(@as(u64, 9), edge.toInt());
}

test "default query budget is bounded" {
    const budget = QueryBudget{};
    try std.testing.expectEqual(@as(u8, 3), budget.max_depth);
    try std.testing.expect(budget.max_visited_nodes < 1_000_000);
}

test "query timeout duration saturates oversized millisecond values" {
    const duration = queryTimeoutDuration(std.math.maxInt(u64));
    try std.testing.expectEqual(
        std.Io.Duration.fromMilliseconds(std.math.maxInt(i64)).nanoseconds,
        duration.nanoseconds,
    );
}

test "query deadline distinguishes immediate and no-clock modes" {
    try std.testing.expect(QueryDeadline.immediateOrNone(0).expired());
    try std.testing.expect(!QueryDeadline.immediateOrNone(1).expired());
    try std.testing.expect(QueryDeadline.fromIo(std.testing.io, 0).expired());
}

test "kinds parse from stable tag texts" {
    try std.testing.expectEqual(NodeKind.file, parseNodeKind("file").?);
    try std.testing.expectEqual(NodeKind.file, parseNodeKind("File").?);
    try std.testing.expectEqual(RelKind.defines, parseRelKind("defines").?);
    try std.testing.expectEqual(RelKind.defines, parseRelKind("DEFINES").?);
    try std.testing.expectEqual(RelKind.task_event, parseRelKind("task_event").?);
    try std.testing.expect(parseNodeKind("missing") == null);
}
