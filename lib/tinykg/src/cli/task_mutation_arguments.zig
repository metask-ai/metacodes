const std = @import("std");

/// Syntax boundary for task mutations and task-event recording. Execution,
/// authorization, persistence, and rendering deliberately stay with the CLI
/// façade until they have their own bounded command-family protocol.
pub const TaskMutationArguments = struct {
    pub const CloseStatus = enum {
        completed,
        failed,
    };

    pub const Claim = struct {
        task_id: []const u8,
        by: ?[]const u8,
        ttl_s: u64,
        steal: bool,
    };

    pub const Release = struct {
        task_id: []const u8,
        by: ?[]const u8,
        force: bool,
    };

    pub const Close = struct {
        task_id: []const u8,
        status: CloseStatus,
        by: ?[]const u8,
        evidence_id: ?[]const u8,
        evidence_text: ?[]const u8,
        force: bool,
    };

    pub const EventType = enum {
        write_attempt,
        write_error,
        dependency_edge_created,
        dependency_edge_deleted,
        prompt_adherence_ok,
        prompt_adherence_miss,
    };

    pub const Event = struct {
        root_id: []const u8,
        event_type: EventType,
        task_id: ?[]const u8 = null,
        relation_label: ?[]const u8 = null,
        note: ?[]const u8 = null,
    };

    pub fn parseClaim(rest: []const []const u8, default_ttl_s: u64) !Claim {
        if (default_ttl_s == 0) return error.InvalidLimit;
        var task_id: ?[]const u8 = null;
        var agent_arg: ?[]const u8 = null;
        var ttl_s = default_ttl_s;
        var ttl_explicit = false;
        var steal = false;
        var steal_explicit = false;

        var pos: usize = 0;
        while (pos < rest.len) {
            const arg = rest[pos];
            if (std.mem.eql(u8, arg, "--by")) {
                if (pos + 1 >= rest.len) return error.MissingArgument;
                if (agent_arg != null) return error.TooManyArguments;
                agent_arg = rest[pos + 1];
                pos += 2;
            } else if (std.mem.eql(u8, arg, "--ttl-s")) {
                if (pos + 1 >= rest.len) return error.MissingArgument;
                if (ttl_explicit) return error.TooManyArguments;
                ttl_s = std.fmt.parseInt(u64, rest[pos + 1], 10) catch return error.InvalidLimit;
                if (ttl_s == 0) return error.InvalidLimit;
                ttl_explicit = true;
                pos += 2;
            } else if (std.mem.eql(u8, arg, "--steal")) {
                if (steal_explicit) return error.TooManyArguments;
                steal = true;
                steal_explicit = true;
                pos += 1;
            } else if (std.mem.startsWith(u8, arg, "--")) {
                return error.UnknownOption;
            } else {
                if (task_id != null) return error.TooManyArguments;
                task_id = arg;
                pos += 1;
            }
        }

        return .{
            .task_id = task_id orelse return error.MissingArgument,
            .by = agent_arg,
            .ttl_s = ttl_s,
            .steal = steal,
        };
    }

    pub fn parseRelease(rest: []const []const u8) !Release {
        var task_id: ?[]const u8 = null;
        var by: ?[]const u8 = null;
        var force = false;
        var force_explicit = false;

        var pos: usize = 0;
        while (pos < rest.len) {
            const arg = rest[pos];
            if (std.mem.eql(u8, arg, "--by")) {
                if (pos + 1 >= rest.len) return error.MissingArgument;
                if (by != null) return error.TooManyArguments;
                by = rest[pos + 1];
                pos += 2;
            } else if (std.mem.eql(u8, arg, "--force")) {
                if (force_explicit) return error.TooManyArguments;
                force = true;
                force_explicit = true;
                pos += 1;
            } else if (std.mem.startsWith(u8, arg, "--")) {
                return error.UnknownOption;
            } else {
                if (task_id != null) return error.TooManyArguments;
                task_id = arg;
                pos += 1;
            }
        }

        return .{
            .task_id = task_id orelse return error.MissingArgument,
            .by = by,
            .force = force,
        };
    }

    pub fn parseClose(rest: []const []const u8) !Close {
        var task_id: ?[]const u8 = null;
        var close_status: ?CloseStatus = null;
        var by: ?[]const u8 = null;
        var evidence_id: ?[]const u8 = null;
        var evidence_text: ?[]const u8 = null;
        var force = false;
        var force_explicit = false;

        var pos: usize = 0;
        while (pos < rest.len) {
            const arg = rest[pos];
            if (std.mem.eql(u8, arg, "--by")) {
                if (pos + 1 >= rest.len) return error.MissingArgument;
                if (by != null) return error.TooManyArguments;
                by = rest[pos + 1];
                pos += 2;
            } else if (std.mem.eql(u8, arg, "--evidence")) {
                if (pos + 1 >= rest.len) return error.MissingArgument;
                if (evidence_id != null or evidence_text != null) return error.TooManyArguments;
                evidence_id = rest[pos + 1];
                pos += 2;
            } else if (std.mem.eql(u8, arg, "--evidence-text")) {
                if (pos + 1 >= rest.len) return error.MissingArgument;
                if (evidence_id != null or evidence_text != null) return error.TooManyArguments;
                evidence_text = rest[pos + 1];
                pos += 2;
            } else if (std.mem.eql(u8, arg, "--force")) {
                if (force_explicit) return error.TooManyArguments;
                force = true;
                force_explicit = true;
                pos += 1;
            } else if (std.mem.startsWith(u8, arg, "--")) {
                return error.UnknownOption;
            } else if (task_id == null) {
                task_id = arg;
                pos += 1;
            } else if (close_status == null) {
                if (std.mem.eql(u8, arg, "completed")) {
                    close_status = .completed;
                } else if (std.mem.eql(u8, arg, "failed")) {
                    close_status = .failed;
                } else {
                    return error.InvalidStatus;
                }
                pos += 1;
            } else {
                return error.TooManyArguments;
            }
        }

        return .{
            .task_id = task_id orelse return error.MissingArgument,
            .status = close_status orelse return error.MissingArgument,
            .by = by,
            .evidence_id = evidence_id,
            .evidence_text = evidence_text,
            .force = force,
        };
    }

    pub fn parseEvent(rest: []const []const u8) !Event {
        var root_id: ?[]const u8 = null;
        var event_type: ?EventType = null;
        var task_id: ?[]const u8 = null;
        var relation_label: ?[]const u8 = null;
        var note: ?[]const u8 = null;

        var pos: usize = 0;
        while (pos < rest.len) {
            const arg = rest[pos];
            if (std.mem.eql(u8, arg, "--task")) {
                if (pos + 1 >= rest.len) return error.MissingArgument;
                if (task_id != null) return error.TooManyArguments;
                task_id = rest[pos + 1];
                pos += 2;
            } else if (std.mem.eql(u8, arg, "--relation") or std.mem.eql(u8, arg, "--rel")) {
                if (pos + 1 >= rest.len) return error.MissingArgument;
                if (relation_label != null) return error.TooManyArguments;
                relation_label = rest[pos + 1];
                pos += 2;
            } else if (std.mem.eql(u8, arg, "--note")) {
                if (pos + 1 >= rest.len) return error.MissingArgument;
                if (note != null) return error.TooManyArguments;
                note = rest[pos + 1];
                pos += 2;
            } else if (std.mem.startsWith(u8, arg, "--")) {
                return error.UnknownOption;
            } else {
                if (root_id == null) {
                    root_id = arg;
                } else if (event_type == null) {
                    event_type = parseEventType(arg) orelse return error.InvalidRecord;
                } else {
                    return error.TooManyArguments;
                }
                pos += 1;
            }
        }

        const parsed_event_type = event_type orelse return error.MissingArgument;
        if (eventRequiresRelation(parsed_event_type) and relation_label == null) return error.MissingArgument;
        return .{
            .root_id = root_id orelse return error.MissingArgument,
            .event_type = parsed_event_type,
            .task_id = task_id,
            .relation_label = relation_label,
            .note = note,
        };
    }

    pub fn eventRequiresRelation(event_type: EventType) bool {
        return switch (event_type) {
            .dependency_edge_created, .dependency_edge_deleted => true,
            .write_attempt, .write_error, .prompt_adherence_ok, .prompt_adherence_miss => false,
        };
    }

    /// Canonical external identity shared by parsing, persisted metadata,
    /// event text, and CLI output.
    pub fn eventTypeName(event_type: EventType) []const u8 {
        return switch (event_type) {
            .write_attempt => "write_attempt",
            .write_error => "write_error",
            .dependency_edge_created => "dependency_edge_created",
            .dependency_edge_deleted => "dependency_edge_deleted",
            .prompt_adherence_ok => "prompt_adherence_ok",
            .prompt_adherence_miss => "prompt_adherence_miss",
        };
    }

    fn parseEventType(value: []const u8) ?EventType {
        inline for (std.meta.fields(EventType)) |field| {
            const event_type: EventType = @enumFromInt(field.value);
            if (std.mem.eql(u8, value, eventTypeName(event_type))) return event_type;
        }
        return null;
    }
};

const Args = TaskMutationArguments;

test "task claim and release parsers preserve authority defaults" {
    const claim = try Args.parseClaim(&.{ "7", "--by", "agent-a" }, 7200);
    try std.testing.expectEqualStrings("7", claim.task_id);
    try std.testing.expectEqualStrings("agent-a", claim.by.?);
    try std.testing.expectEqual(@as(u64, 7200), claim.ttl_s);
    try std.testing.expect(!claim.steal);

    const override = try Args.parseClaim(&.{ "7", "--by", "agent-b", "--ttl-s", "30", "--steal" }, 7200);
    try std.testing.expectEqual(@as(u64, 30), override.ttl_s);
    try std.testing.expect(override.steal);
    try std.testing.expectError(error.InvalidLimit, Args.parseClaim(&.{"7"}, 0));

    const release = try Args.parseRelease(&.{ "7", "--by", "agent-b", "--force" });
    try std.testing.expectEqualStrings("agent-b", release.by.?);
    try std.testing.expect(release.force);
}

test "task lifecycle parsers reject duplicate authority options" {
    try std.testing.expectError(error.TooManyArguments, Args.parseClaim(&.{ "1", "--by", "a", "--by", "b" }, 7200));
    try std.testing.expectError(error.TooManyArguments, Args.parseClaim(&.{ "1", "--ttl-s", "1", "--ttl-s", "2", "--by", "a" }, 7200));
    try std.testing.expectError(error.TooManyArguments, Args.parseClaim(&.{ "1", "--by", "a", "--steal", "--steal" }, 7200));
    try std.testing.expectError(error.TooManyArguments, Args.parseRelease(&.{ "1", "--by", "a", "--by", "b" }));
    try std.testing.expectError(error.TooManyArguments, Args.parseRelease(&.{ "1", "--force", "--force" }));
    try std.testing.expectError(error.TooManyArguments, Args.parseClose(&.{ "1", "completed", "--by", "a", "--by", "b" }));
    try std.testing.expectError(error.TooManyArguments, Args.parseClose(&.{ "1", "completed", "--force", "--force" }));
}

test "task close parser keeps terminal status and evidence exclusive" {
    const parsed = try Args.parseClose(&.{ "1", "failed", "--by", "agent", "--evidence-text", "failure evidence" });
    try std.testing.expectEqual(Args.CloseStatus.failed, parsed.status);
    try std.testing.expectEqualStrings("failure evidence", parsed.evidence_text.?);
    try std.testing.expect(parsed.evidence_id == null);

    try std.testing.expectError(error.InvalidStatus, Args.parseClose(&.{ "1", "open" }));
    try std.testing.expectError(error.TooManyArguments, Args.parseClose(&.{ "1", "completed", "--evidence", "2", "--evidence", "3" }));
    try std.testing.expectError(error.TooManyArguments, Args.parseClose(&.{ "1", "completed", "--evidence", "2", "--evidence-text", "text" }));
    try std.testing.expectError(error.TooManyArguments, Args.parseClose(&.{ "1", "completed", "--evidence-text", "a", "--evidence-text", "b" }));
}

test "task event parser enforces dependency relation and unique fields" {
    const write = try Args.parseEvent(&.{ "1", "write_attempt", "--task", "2", "--note", "ok" });
    try std.testing.expectEqualStrings("1", write.root_id);
    try std.testing.expectEqual(Args.EventType.write_attempt, write.event_type);
    try std.testing.expectEqualStrings("2", write.task_id.?);
    try std.testing.expectEqualStrings("ok", write.note.?);

    const dependency = try Args.parseEvent(&.{ "1", "dependency_edge_deleted", "--relation", "depends_on" });
    try std.testing.expectEqual(Args.EventType.dependency_edge_deleted, dependency.event_type);
    try std.testing.expectEqualStrings("depends_on", dependency.relation_label.?);

    const prompt = try Args.parseEvent(&.{ "1", "prompt_adherence_ok", "--task", "2" });
    try std.testing.expectEqual(Args.EventType.prompt_adherence_ok, prompt.event_type);
    try std.testing.expectEqualStrings("2", prompt.task_id.?);

    try std.testing.expectError(error.MissingArgument, Args.parseEvent(&.{ "1", "dependency_edge_created" }));
    try std.testing.expectError(error.InvalidRecord, Args.parseEvent(&.{ "1", "unknown_event" }));
    try std.testing.expectError(error.UnknownOption, Args.parseEvent(&.{ "1", "write_attempt", "--unknown" }));
    try std.testing.expectError(error.TooManyArguments, Args.parseEvent(&.{ "1", "write_attempt", "extra" }));
    try std.testing.expectError(error.TooManyArguments, Args.parseEvent(&.{ "1", "write_attempt", "--note", "a", "--note", "b" }));
}
