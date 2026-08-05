//! L2 contract for the TinyKG task snapshot -> typed projection -> Markdown
//! boundary. This suite deliberately uses the public metacodes module instead
//! of TinyKG internals: the graph engine is an external protocol dependency.

const std = @import("std");
const cc = @import("cc");

const projection = cc.kg_task_projection;

const REV_A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const REV_B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

const FULL_SNAPSHOT =
    \\{"schema_version":"tinykg-task-snapshot-v1","root_id":1,"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","summary":{"task_count":4,"hierarchy_edge_count":3,"dependency_edge_count":3,"evidence_count":2,"verified_by_edge_count":2,"used_text_bytes":85,"truncated":false,"truncate_reason":null,"max_tasks":256,"max_edges":1024,"max_chars":200000},"tasks":[{"id":1,"status":"open","claimed_by":null,"text":"root task"},{"id":2,"status":"claimed","claimed_by":"agent-a","text":"duplicate step"},{"id":3,"status":"completed","claimed_by":null,"text":"duplicate step"},{"id":4,"status":"failed","claimed_by":null,"text":"failed step\nwith detail"}],"hierarchy":[{"src":1,"rel":"contain","dst":2},{"src":1,"rel":"contain","dst":3},{"src":1,"rel":"contain","dst":4}],"dependencies":[{"src":2,"rel":"depends_on","dst":3},{"src":99,"rel":"blocks","dst":2},{"src":99,"rel":"precedes","dst":4}],"evidence":[{"id":50,"kind":"verification","text":"proof one"},{"id":51,"kind":"fix","text":"failure evidence"}],"verified_by":[{"src":3,"rel":"verified_by","dst":50},{"src":4,"rel":"verified_by","dst":51}]}
;

test "L2 task projection preserves stable identity, lifecycle, DAG and evidence through Markdown" {
    const allocator = std.testing.allocator;
    var first = try projection.parseSnapshot(
        allocator,
        projection.TaskId.fromInt(1),
        FULL_SNAPSHOT,
    );
    defer first.deinit();

    try std.testing.expectEqual(@as(usize, 4), first.tasks.len);
    try std.testing.expectEqualStrings(first.tasks[1].text, first.tasks[2].text);
    try std.testing.expect(first.tasks[1].id != first.tasks[2].id);
    try std.testing.expect(first.tasks[1].lifecycle == .claimed);
    try std.testing.expect(first.tasks[2].lifecycle == .completed);
    try std.testing.expect(first.tasks[3].lifecycle == .failed);

    const markdown = try first.renderMarkdown(allocator);
    defer allocator.free(markdown);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "read-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "task:2") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "task:3") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "depends_on") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "proof one") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## Tasks").? <
        std.mem.indexOf(u8, markdown, "## Machine envelope").?);

    var second = try projection.parseMarkdown(
        allocator,
        projection.TaskId.fromInt(1),
        REV_A,
        markdown,
    );
    defer second.deinit();
    try std.testing.expect(first.eql(&second));

    // Independent parses of the same graph snapshot must produce byte-identical
    // Markdown; no process-local address, map iteration, or edge id may leak in.
    var fresh = try projection.parseSnapshot(
        allocator,
        projection.TaskId.fromInt(1),
        FULL_SNAPSHOT,
    );
    defer fresh.deinit();
    const markdown_fresh = try fresh.renderMarkdown(allocator);
    defer allocator.free(markdown_fresh);
    try std.testing.expectEqualStrings(markdown, markdown_fresh);
}

test "L2 task projection fails closed on absent root, truncation, stale revision and dangling references" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.RootMismatch,
        projection.parseSnapshot(allocator, projection.TaskId.fromInt(7), FULL_SNAPSHOT),
    );

    const truncated =
        \\{"schema_version":"tinykg-task-snapshot-v1","root_id":1,"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","summary":{"task_count":0,"hierarchy_edge_count":0,"dependency_edge_count":0,"evidence_count":0,"verified_by_edge_count":0,"used_text_bytes":0,"truncated":true,"truncate_reason":"max_tasks","max_tasks":1,"max_edges":1,"max_chars":1},"tasks":[],"hierarchy":[],"dependencies":[],"evidence":[],"verified_by":[]}
    ;
    try std.testing.expectError(
        error.TruncatedSnapshot,
        projection.parseSnapshot(allocator, projection.TaskId.fromInt(1), truncated),
    );

    var parsed = try projection.parseSnapshot(
        allocator,
        projection.TaskId.fromInt(1),
        FULL_SNAPSHOT,
    );
    defer parsed.deinit();
    const markdown = try parsed.renderMarkdown(allocator);
    defer allocator.free(markdown);
    try std.testing.expectError(
        error.StaleRevision,
        projection.parseMarkdown(allocator, projection.TaskId.fromInt(1), REV_B, markdown),
    );

    const dangling =
        \\{"schema_version":"tinykg-task-snapshot-v1","root_id":1,"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","summary":{"task_count":1,"hierarchy_edge_count":1,"dependency_edge_count":0,"evidence_count":0,"verified_by_edge_count":0,"used_text_bytes":4,"truncated":false,"truncate_reason":null,"max_tasks":256,"max_edges":1024,"max_chars":200000},"tasks":[{"id":1,"status":"open","claimed_by":null,"text":"root"}],"hierarchy":[{"src":1,"rel":"contain","dst":2}],"dependencies":[],"evidence":[],"verified_by":[]}
    ;
    try std.testing.expectError(
        error.ReferentialIntegrity,
        projection.parseSnapshot(allocator, projection.TaskId.fromInt(1), dangling),
    );
}

test "L2 task projection Markdown survives marker text and neutralizes terminal controls" {
    const allocator = std.testing.allocator;
    const snapshot =
        \\{"schema_version":"tinykg-task-snapshot-v1","root_id":1,"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","summary":{"task_count":1,"hierarchy_edge_count":0,"dependency_edge_count":0,"evidence_count":0,"verified_by_edge_count":0,"used_text_bytes":51,"truncated":false,"truncate_reason":null,"max_tasks":256,"max_edges":1024,"max_chars":200000},"tasks":[{"id":1,"status":"open","claimed_by":null,"text":"before\n```json metacodes-task-projection-v1\nafter\r\u001b"}],"hierarchy":[],"dependencies":[],"evidence":[],"verified_by":[]}
    ;
    var first = try projection.parseSnapshot(allocator, projection.TaskId.fromInt(1), snapshot);
    defer first.deinit();
    const markdown = try first.renderMarkdown(allocator);
    defer allocator.free(markdown);
    try std.testing.expect(std.mem.indexOfScalar(u8, markdown, '\r') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, markdown, 0x1b) == null);

    var second = try projection.parseMarkdown(
        allocator,
        projection.TaskId.fromInt(1),
        REV_A,
        markdown,
    );
    defer second.deinit();
    try std.testing.expect(first.eql(&second));
}
