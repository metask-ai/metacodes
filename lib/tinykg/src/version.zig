const std = @import("std");

pub const string = "0.2.0";
pub const cli = "tinykg " ++ string;
pub const daemon_cli = "tinykgd " ++ string;
pub const semantic = std.SemanticVersion{ .major = 0, .minor = 2, .patch = 0 };

/// Published compatibility baselines. These are version identities, not a
/// promise that every nested implementation declaration is stable.
pub const storage_format_version: u32 = 3;
pub const schema_version: u32 = 3;

/// Stable implementation metadata consumed by the optional TinyKG Web remote
/// service. The Web service hashes the actual executable bytes separately;
/// this declaration is the semantic capability half of that identity.
pub const implementation = "tinykg-cli";
pub const task_hierarchy_canonical_read_capability = "task-hierarchy-canonical-read-v1";
pub const task_snapshot_capability = "tinykg-task-snapshot-v1";
pub const ontology_rule_snapshot_capability = "tinykg-ontology-rule-snapshot-v1";
pub const memory_migration_snapshot_capability = "tinykg-memory-migration-snapshot-v1";
pub const memory_migration_commit_capability = "tinykg-memory-migration-commit-v1";
pub const memory_migration_rollback_capability = "tinykg-memory-migration-rollback-v1";
pub const metadata_json =
    "{\"implementation\":\"" ++ implementation ++
    "\",\"version\":\"" ++ string ++
    "\",\"capabilities\":[\"" ++ task_hierarchy_canonical_read_capability ++
    "\",\"" ++ task_snapshot_capability ++
    "\",\"" ++ ontology_rule_snapshot_capability ++
    "\",\"" ++ memory_migration_snapshot_capability ++
    "\",\"" ++ memory_migration_commit_capability ++
    "\",\"" ++ memory_migration_rollback_capability ++ "\"]}";

test "version string matches semantic version" {
    var buffer: [32]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buffer, "{d}.{d}.{d}", .{ semantic.major, semantic.minor, semantic.patch });
    try std.testing.expectEqualStrings(string, rendered);
    try std.testing.expectEqualStrings("tinykgd 0.2.0", daemon_cli);
}

test "published compatibility baselines remain explicit" {
    try std.testing.expectEqual(@as(u32, 3), storage_format_version);
    try std.testing.expectEqual(@as(u32, 3), schema_version);
}

test "machine-readable version metadata declares canonical task hierarchy capability" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, metadata_json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(implementation, root.get("implementation").?.string);
    try std.testing.expectEqualStrings(string, root.get("version").?.string);
    const capabilities = root.get("capabilities").?.array.items;
    try std.testing.expectEqual(@as(usize, 6), capabilities.len);
    try std.testing.expectEqualStrings(task_hierarchy_canonical_read_capability, capabilities[0].string);
    try std.testing.expectEqualStrings(task_snapshot_capability, capabilities[1].string);
    try std.testing.expectEqualStrings(ontology_rule_snapshot_capability, capabilities[2].string);
    try std.testing.expectEqualStrings(memory_migration_snapshot_capability, capabilities[3].string);
    try std.testing.expectEqualStrings(memory_migration_commit_capability, capabilities[4].string);
    try std.testing.expectEqualStrings(memory_migration_rollback_capability, capabilities[5].string);
}
