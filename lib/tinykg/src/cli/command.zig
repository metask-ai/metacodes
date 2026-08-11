const std = @import("std");

/// Stable command identity used by the CLI façade and dispatch layer.
pub const Command = enum {
    help,
    version,
    init,
    stats,
    store_info,
    rebuild_text,
    backup,
    restore,
    upgrade,
    migrate_store_v2,
    schema_info,
    schema_show,
    schema_apply,
    schema_validate,
    schema_reconcile,
    schema_migrate,
    import_metaknow_replay,
    import_jsonl,
    export_jsonl,
    apply,
    import_markdown,
    export_markdown,
    import_md_ast,
    import_md_doc,
    render_md_doc,
    gc_md_orphans,
    get,
    get_node,
    add_node,
    ensure_node,
    ensure_anchor,
    schema_scope,
    update_node,
    append_node_version,
    set_property,
    set_uint_property,
    set_node_property,
    set_edge_property,
    node_versions,
    node_latest,
    govern_node,
    delete_node,
    list_kinds,
    list_recent,
    agent_write,
    add_edge,
    delete_edge,
    delete_edges,
    reparent_contain,
    list_rels,
    find,
    search,
    context_plan,
    context_packet,
    neighbors,
    incoming,
    path,
    task_ready,
    task_packet,
    task_frontier,
    task_claim,
    task_release,
    task_close,
    task_ancestry,
    task_metrics,
    task_event,
    query,
    query_explain,
    governance,
    segment_query,
    segment_query_explain,
    export_segment_bundle,
    gc_segment_bundle,
    bench,
    bench_md_doc_edit,
    maintain,
    compact_edges,
    compact_edge_segments,
    maintain_edge_segments,
    gc_edge_segments,
    gc_node_text_runs,
};

/// Canonical spellings follow the non-help enum tags exactly. Keeping this as
/// one ordered contract makes missing dispatch identities observable without
/// coupling parsing to command implementations or help rendering.
const canonical_spellings = [_][]const u8{
    "version",
    "init",
    "stats",
    "store-info",
    "rebuild-text",
    "backup",
    "restore",
    "upgrade",
    "migrate-store-v2",
    "schema-info",
    "schema-show",
    "schema-apply",
    "schema-validate",
    "schema-reconcile",
    "schema-migrate",
    "import-metaknow-replay",
    "import-jsonl",
    "export-jsonl",
    "apply",
    "import-markdown",
    "export-markdown",
    "import-md-ast",
    "import-md-doc",
    "render-md-doc",
    "gc-md-orphans",
    "get",
    "node",
    "add-node",
    "ensure-node",
    "ensure-anchor",
    "schema-scope",
    "update-node",
    "append-node-version",
    "set-property",
    "set-uint-property",
    "set-node-property",
    "set-edge-property",
    "node-versions",
    "node-latest",
    "govern-node",
    "delete-node",
    "list-kinds",
    "list-recent",
    "agent-write",
    "add-edge",
    "delete-edge",
    "delete-edges",
    "reparent-contain",
    "list-rels",
    "find",
    "search",
    "context-plan",
    "context-packet",
    "neighbors",
    "incoming",
    "path",
    "task-ready",
    "task-packet",
    "task-frontier",
    "task-claim",
    "task-release",
    "task-close",
    "task-ancestry",
    "task-metrics",
    "task-event",
    "query",
    "query-explain",
    "governance",
    "segment-query",
    "segment-query-explain",
    "export-segment-bundle",
    "gc-segment-bundle",
    "bench",
    "bench-md-doc-edit",
    "maintain",
    "compact-edges",
    "compact-edge-segments",
    "maintain-edge-segments",
    "gc-edge-segments",
    "gc-node-text-runs",
};

const Alias = struct {
    spelling: []const u8,
    command: Command,
};

const aliases = [_]Alias{
    .{ .spelling = "inspect", .command = .get },
    .{ .spelling = "remember", .command = .add_node },
    .{ .spelling = "revise", .command = .update_node },
    .{ .spelling = "tag-node", .command = .govern_node },
    .{ .spelling = "forget", .command = .delete_node },
    .{ .spelling = "relate", .command = .add_edge },
    .{ .spelling = "recall", .command = .search },
    .{ .spelling = "health", .command = .governance },
};

/// Resolves one shell spelling without performing argument parsing or I/O.
/// `null` is the implicit help request; an explicit `help` token intentionally
/// remains unknown for compatibility with the existing CLI contract.
pub fn parseCommand(arg: ?[]const u8) !Command {
    const value = arg orelse return .help;
    inline for (canonical_spellings, 1..) |spelling, tag| {
        if (std.mem.eql(u8, value, spelling)) return @enumFromInt(tag);
    }
    inline for (aliases) |alias| {
        if (std.mem.eql(u8, value, alias.spelling)) return alias.command;
    }
    return error.UnknownCommand;
}

test "command catalog maps every non-help identity to one canonical spelling" {
    try std.testing.expectEqual(std.meta.fields(Command).len - 1, canonical_spellings.len);
    inline for (canonical_spellings, 1..) |spelling, tag| {
        try std.testing.expectEqual(@as(Command, @enumFromInt(tag)), try parseCommand(spelling));
    }
    for (canonical_spellings, 0..) |spelling, index| {
        for (canonical_spellings[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, spelling, other));
        }
    }
}

test "command catalog preserves compatibility aliases without shadowing canonical names" {
    inline for (aliases) |alias| {
        try std.testing.expectEqual(alias.command, try parseCommand(alias.spelling));
        for (canonical_spellings) |canonical| {
            try std.testing.expect(!std.mem.eql(u8, alias.spelling, canonical));
        }
    }
}

test "command catalog keeps implicit help and unknown-command errors stable" {
    try std.testing.expectEqual(Command.help, try parseCommand(null));
    try std.testing.expectError(error.UnknownCommand, parseCommand("help"));
    try std.testing.expectError(error.UnknownCommand, parseCommand("statsu"));
    try std.testing.expectError(error.UnknownCommand, parseCommand(""));
}
