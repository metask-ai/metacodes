const std = @import("std");

const usage_text =
    \\tinykg commands:
    \\  default db: $TINYKG_STORE when set, otherwise .tinykg
    \\  init [db]
    \\  rebuild-text [db]
    \\  backup [db] <target-dir>
    \\  restore <backup-dir> <target-dir>
    \\  upgrade <source-db> [target-db] [--backup <dir>] [--warm-text] [--dry-run]
    \\  migrate-store-v2 <old-db> <new-db> [--backup <dir>] [--profile <agent-dag,markdown-document>] [--warm-text] [--verify] [--dry-run] [--strict] [--task-status-v1]
    \\  schema-info [--schema <schema.json>] [--profile <agent-dag,markdown-document>]
    \\  schema-show [db] [--json]
    \\  schema-apply <db> --schema <schema.json> [--profile <agent-dag,markdown-document>]
    \\  schema-validate <db> --schema <schema.json> [--profile <agent-dag,markdown-document>]
    \\  schema-reconcile <db> --schema <schema.json> --plan <reconciliation-plan.json> [--profile <agent-dag,markdown-document>]
    \\  schema-migrate <old-db> <new-db> [--from <old.json>] [--to <new.json>] [--profile <agent-dag,markdown-document>]
    \\  import-metaknow-replay <db> <corpus-dir> [--chunk <n>] [--warm-text]
    \\  import-jsonl <db> <dir> [--warm-text]
    \\  export-jsonl <db> <dir>
    \\  apply <db> <batch.jsonl>
    \\  import-markdown <db> <dir> [--warm-text]
    \\  export-markdown <db> <dir>
    \\  import-md-ast <db> <ast.json|-> [--format mdast] [--source <id>] [--durability safe|fast]
    \\  import-md-doc <db> <file.md> [--durability safe|fast]
    \\  render-md-doc <db> <document-id> [--section <node-id>] [--format text|json] [--meta] [--preview-lines <n>] [--page-size-bytes <n>] [--cursor <n>]
    \\  gc-md-orphans <db> [--apply]
    \\  get [db] <node-id> [--format text|json] [--meta] [--include-text]
    \\  node [db] <node-id> [--format text|json] [--meta] [--include-text]
    \\  add-node [db] <kind> <text> [--schema <schema.json>] [--name <text>] [--summary <text>] [--schema-type <type>] [--retrieval-hints <text>]
    \\  ensure-node [db] <kind> <text> [--schema-type <type>]   (原子 find-or-create,单锁内;输出 node <id> created=0|1)
    \\  schema-scope [db] <schema_type> --project <name|id>[,...] [--enforce block|report]   (项目级本体:声明 schema_type 只在这些 project 下可用;严格精确无继承)
    \\  ensure-anchor [db] <project-id> <task|docs|memory>   (project 三锚 find-or-create,每类唯一;输出 node <id> created=0|1)
    \\  update-node [db] <node-id> <kind> <text> [--schema <schema.json>] [--name <text>] [--summary <text>] [--schema-type <type>] [--retrieval-hints <text>]
    \\  append-node-version [db] <node-id> <kind> <text> [--schema <schema.json>] [--name <text>] [--summary <text>] [--schema-type <type>] [--retrieval-hints <text>]
    \\  set-property [db] <node|edge> <id> <key> <text> [--schema <schema.json>]
    \\  set-uint-property [db] <node|edge> <id> <generation|created_at|updated_at|byte_start|byte_end|line_start|line_end|order_key|tombstone_generation> <uint> [--schema <schema.json>]
    \\  set-node-property [db] <node-id> <name|summary|retrieval_hints> <text> [--schema <schema.json>]
    \\  set-edge-property [db] <edge-id> <markdown_attr|render_flags|source_span|confidence|created_by> <text> [--schema <schema.json>]
    \\  node-versions [db] <node-id> [--limit <n>]
    \\  node-latest [db] <node-id> [--limit <n>]
    \\  govern-node [db] <node-id> [--parent <id>] [--schema-type <type>]
    \\  reparent-contain [db] <from-id> <to-id>   (把 from 的全部 contain 子边增量迁到 to;重复 project 合并用)
    \\  delete-node [db] <node-id>
    \\  list-kinds [--schema <schema.json>] [--profile <agent-dag,markdown-document>]
    \\  list-recent [db] [--project <id>] [--kind <k>] [--limit <n>] [--with-type]
    \\  agent-write [db] --src <node-id> --rel <rel> --dst <node-id> [--document <node-id>|--section <node-id>|--agent-inbox] --text <markdown> [--name <text>] [--summary <text>] [--retrieval-hints <text>] [--render-rel <md:rel>] [--schema <schema.json>]
    \\  agent-write [db] --json <batch.json> [--schema <schema.json>]
    \\  add-edge [db] <src> <rel> <dst> [--schema <schema.json>]
    \\  delete-edge [db] <edge-id>
    \\  delete-edges [db] <edge-id>...
    \\  list-rels [--schema <schema.json>] [--profile <agent-dag,markdown-document>]
    \\  find [db] <kind> <text> [--schema <schema.json>] [--include-history]
    \\  search [db] <query> [--kind <kind>] [--project <id>] [--schema-type <t>] [--limit <n>] [--profile interactive|agent-memory] [--max-postings <n>] [--timeout-ms <n>] [--include-history] [--format text|json] [--meta]
    \\  context-plan [db] <query> [--task <node-id>] [--node <node-id>] [--limit <n>] [--profile interactive|agent-memory] [--max-postings <n>] [--timeout-ms <n>] [--include-history] [--format json] [--meta] [--neighbor-depth <n>] [--max-nodes <n>] [--max-edges <n>] [--max-chars <n>] [--markdown-preview-lines <n>]
    \\  context-packet [db] <query> [--task <node-id>] [--node <node-id>] [--limit <n>] [--profile interactive|agent-memory] [--max-postings <n>] [--timeout-ms <n>] [--include-history] [--format json] [--meta] [--neighbor-depth <n>] [--max-nodes <n>] [--max-edges <n>] [--max-chars <n>] [--markdown-preview-lines <n>]
    \\  neighbors [db] <node-id> [rel] [--limit <n>] [--offset <n>] [--schema <schema.json>] [--include-history] [--format text|json] [--meta] [--depth <n>] [--max-nodes <n>] [--max-edges <n>] [--max-chars <n>]
    \\  incoming [db] <node-id> [rel] [--schema <schema.json>] [--include-history]
    \\  path [db] <from> <to> [rel] [--schema <schema.json>]
    \\  query [db] <tinyql> [--schema <schema.json>] [--profile interactive|agent-memory] [--max-postings <n>] [--timeout-ms <n>]
    \\  query-explain [db] <tinyql> [--schema <schema.json>] [--profile interactive|agent-memory] [--max-postings <n>] [--timeout-ms <n>]
    \\  governance [db] [--schema <schema.json>] [--profile <agent-dag,markdown-document>]
    \\  segment-query <bundle-root> <tinyql>
    \\  segment-query-explain <bundle-root> <tinyql>
    \\  export-segment-bundle <db> <bundle-root>
    \\  gc-segment-bundle <bundle-root>
    \\  bench <db> <nodes> <edges> [--chunk <n>] [--workload synthetic-ring|realistic-agent-text|realistic-agent-diverse-text|metaknow-replay|metaknow-replay-shaped] [--corpus-file <path>] [--corpus-dir <dir>] [--edge-id-pattern sequential|gap-heavy] [--edge-delta-stats] [--edge-tombstone-probe] [--storage-only] [--agent-mixed] [--edge-compact-batch <n>] [--edge-compact-threshold <n>] [--maintenance-every <ops>] [--maintenance-max-segments <n>] [--maintenance-max-edges <n>] [--maintenance-gc] [--max-search-ns <n>] [--max-neighbors-ns <n>] [--max-tinyql-expand-p95-ns <n>] [--max-tinyql-context-render-p95-ns <n>] [--max-path-ns <n>] [--max-store-overhead-bps <n>]
    \\  bench-md-doc-edit <db> <paragraphs> [--edit-index <n>] [--repeat-local-edits <n>] [--repeat-update-edits <n>] [--agent-mixed-writes <n>] [--max-edit-changed-records <n>] [--max-edit-elapsed-ns <n>] [--max-edit-ns-per-paragraph <n>] [--max-edit-to-initial-bps <n>] [--max-repeat-edit-elapsed-ns <n>] [--max-repeat-update-edit-elapsed-ns <n>] [--max-render-local-subtree-elapsed-ns <n>]
    \\  maintain <db> [--edge-max-segments <n>] [--edge-max-edges <n>] [--edge-gc] [--node-text-max-records <n>] [--node-text-runs-max-records <n>] [--node-text-gc] [--compact-property-payload] [--max-passes <n>] [--until-clean] [--interval-ms <n>] [--watch] [--max-cycles <n>] [--stop-after-clean-cycles <n>] [--poll-ms <n>]
    \\  compact-edges <db> <segment-dir>
    \\  compact-edge-segments <db> <segment-dir>
    \\  maintain-edge-segments <db> [--max-segments <n>] [--max-edges <n>] [--gc]
    \\  gc-edge-segments <db>
    \\  gc-node-text-runs <db>
    \\  task-ready [db] <task-id>
    \\  task-packet [db] <task-id> [--limit <n>] [--format text|json] [--meta] [--max-nodes <n>] [--max-edges <n>] [--max-chars <n>]
    \\  task-frontier [db] <root-id> [--limit <n>] [--mine <agent>] [--unclaimed]
    \\  task-claim [db] <task-id> --by <agent> [--ttl-s <n>] [--steal]
    \\  task-release [db] <task-id> [--by <agent>] [--force]
    \\  task-close [db] <task-id> <completed|failed> [--by <agent>] [--evidence <node-id>|--evidence-text <text>] [--force]
    \\  task-ancestry [db] <task-id> [--depth <n>] [--limit <n>]
    \\  task-metrics [db] <root-id> [--limit <n>]
    \\  task-event [db] <root-id> <write_attempt|write_error|dependency_edge_created|dependency_edge_deleted|prompt_adherence_ok|prompt_adherence_miss> [--task <id>] [--relation <rel>] [--note <text>]
    \\  store-info [db]
    \\  stats [db]
    \\  version
    \\  aliases: remember=add-node, relate=add-edge, revise=update-node, tag-node=govern-node, forget=delete-node, recall=search, inspect=get, health=governance
    \\
;

/// Writes the stable CLI usage contract without owning parsing or dispatch.
pub fn writeHelp(writer: anytype) !void {
    try writer.writeAll(usage_text);
}

const CapturingWriter = struct {
    buffer: [usage_text.len]u8 = undefined,
    len: usize = 0,

    fn writeAll(self: *@This(), bytes: []const u8) !void {
        if (bytes.len > self.buffer.len - self.len) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
};

test "help renderer writes the stable complete usage contract" {
    var writer = CapturingWriter{};
    try writeHelp(&writer);

    const written = writer.buffer[0..writer.len];
    try std.testing.expectEqualStrings(usage_text, written);
    try std.testing.expect(std.mem.startsWith(u8, written, "tinykg commands:\n"));
    try std.testing.expect(std.mem.indexOf(u8, written, "  gc-md-orphans <db> [--apply]\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "gc-md-orphans <db> [--parent") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "  task-close [db]") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "inspect=get, health=governance\n"));
}

test "help renderer propagates writer failure" {
    const FailingWriter = struct {
        fn writeAll(_: *@This(), _: []const u8) error{OutputClosed}!void {
            return error.OutputClosed;
        }
    };

    var writer = FailingWriter{};
    try std.testing.expectError(error.OutputClosed, writeHelp(&writer));
}
