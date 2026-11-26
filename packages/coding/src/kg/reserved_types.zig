//! TinyKG schema types the host owns.
//!
//! The host writes these nodes on its own paths and later selects them by
//! schema type (plus a text marker) to decide what the next run enforces,
//! retracts, is nudged toward or is told about its last attempt. No reader
//! asks who wrote a node, so a node of one of these types stored by the
//! model's memory tool would be taken as the host's. `KgRemember` therefore
//! refuses every type listed here, except `lesson`, which it admits only
//! through the learning turn's host-bound header (`kg/lesson.zig`).
//!
//! The names are the owner modules' constants; this table only gathers them.
//! A host type added to an owner without an entry here is writable by the
//! model.

const std = @import("std");
const lesson = @import("lesson.zig");
const provider_audit = @import("provider_audit.zig");
const self_evolution = @import("../core/self_evolution.zig");
const obligation_gate = @import("../core/obligation_gate.zig");
const ontology = @import("../core/ontology_rule_projection.zig");

pub const Admission = enum {
    /// Written only by host code; the memory tool refuses it.
    host_only,
    /// Written by the model only inside a learning turn, under the header the
    /// host bound to the verdict (`kg_tools.admitLesson`).
    lesson,
};

pub const Reserved = struct {
    schema_type: []const u8,
    admission: Admission,
    /// What the host keeps under this type and who reads it back; the
    /// refusal quotes it.
    holds: []const u8,
};

const owned = [_]Reserved{
    .{ .schema_type = lesson.SCHEMA_TYPE, .admission = .lesson, .holds = "learning-turn lessons that the next same-task attempt is shown" },
    .{ .schema_type = self_evolution.SCHEMA_TYPE, .admission = .host_only, .holds = "provisional rules that the next run's rule gate enforces" },
    .{ .schema_type = self_evolution.RETRACT_SCHEMA_TYPE, .admission = .host_only, .holds = "retractions that disarm provisional rules and obligations" },
    .{ .schema_type = self_evolution.OBLIGATION_SCHEMA_TYPE, .admission = .host_only, .holds = "task-bound obligations that the next run is nudged to meet" },
    .{ .schema_type = self_evolution.OUTCOME_SCHEMA_TYPE, .admission = .host_only, .holds = "verifier outcomes that the next attempt and the rule author are shown" },
    .{ .schema_type = obligation_gate.TELEMETRY_SCHEMA_TYPE, .admission = .host_only, .holds = "obligation telemetry that decides when a needle retires" },
    .{ .schema_type = provider_audit.SCHEMA_TYPE, .admission = .host_only, .holds = "the provider decision audit trail" },
};

/// The kinds TinyKG's ontology snapshot exports. The host writes them with
/// authority, falsifier and provenance set before the node joins the project
/// (`KgClient.rememberOntologyItem`); one without them makes the whole
/// snapshot, and so the rule author's packet, fail.
const ontology_kinds = blk: {
    const fields = @typeInfo(ontology.OntologyKind).@"enum".fields;
    var out: [fields.len]Reserved = undefined;
    for (fields, 0..) |field, index| out[index] = .{
        .schema_type = field.name,
        .admission = .host_only,
        .holds = "governed ontology items that the rule author's snapshot projects",
    };
    break :blk out;
};

pub const TYPES = owned ++ ontology_kinds;

comptime {
    @setEvalBranchQuota(10_000);
    var lessons: usize = 0;
    for (TYPES, 0..) |entry, index| {
        if (entry.admission == .lesson) {
            lessons += 1;
            if (!std.mem.eql(u8, entry.schema_type, lesson.SCHEMA_TYPE))
                @compileError("only the lesson type has learning-turn admission: " ++ entry.schema_type);
        }
        for (TYPES[index + 1 ..]) |other| {
            if (std.ascii.eqlIgnoreCase(entry.schema_type, other.schema_type))
                @compileError("reserved schema type listed twice: " ++ entry.schema_type);
        }
    }
    if (lessons != 1) @compileError("the lesson type must be listed exactly once");
}

/// The entry `schema_type` names, ignoring ASCII case as `KgRemember` always
/// has for `lesson`. TinyKG's type filter is exact, so a case variant would
/// not be read back today; no memory has a reason to imitate a host type's
/// name either way.
pub fn lookup(schema_type: []const u8) ?*const Reserved {
    for (&TYPES) |*entry| {
        if (std.ascii.eqlIgnoreCase(schema_type, entry.schema_type)) return entry;
    }
    return null;
}

test "lookup finds every owner's type in any case and nothing that only resembles one" {
    const owners = [_][]const u8{
        lesson.SCHEMA_TYPE,
        self_evolution.SCHEMA_TYPE,
        self_evolution.RETRACT_SCHEMA_TYPE,
        self_evolution.OBLIGATION_SCHEMA_TYPE,
        self_evolution.OUTCOME_SCHEMA_TYPE,
        obligation_gate.TELEMETRY_SCHEMA_TYPE,
        provider_audit.SCHEMA_TYPE,
        "proposition",
        "prescription",
        "concept",
        "intent",
    };
    for (owners) |name| {
        const entry = lookup(name) orelse return error.TestExpectedReserved;
        try std.testing.expectEqualStrings(name, entry.schema_type);
        var upper_buffer: [64]u8 = undefined;
        try std.testing.expectEqual(@as(?*const Reserved, entry), lookup(std.ascii.upperString(&upper_buffer, name)));
    }
    try std.testing.expectEqual(Admission.lesson, lookup("Lesson").?.admission);
    try std.testing.expectEqual(Admission.host_only, lookup("task_outcome").?.admission);
    for ([_][]const u8{ "observation", "decision", "migration", "rule", "provisional_rule_notes", "task_outcomes", "lessons", "" }) |name| {
        try std.testing.expect(lookup(name) == null);
    }
}

test "every reserved type is a kind the memory tool would otherwise accept or already rejects" {
    // A table entry the tool's type grammar can never produce would be dead;
    // `concept` is the one the grammar already refuses on its own.
    const resolve = @import("client.zig").resolveMemoryType;
    for (TYPES) |entry| {
        const resolved = resolve(entry.schema_type) orelse {
            try std.testing.expectEqualStrings("concept", entry.schema_type);
            continue;
        };
        try std.testing.expect(lookup(resolved.schema_type) != null);
    }
}
