//! CLI-facing projection of the canonical Skill Runtime catalog.
//!
//! This file intentionally owns no discovery, priority, snapshot, policy, or
//! activation semantics. `SkillSet` exists because older generic call shapes
//! consume a simple list; the list is rebuilt only from an immutable Runtime
//! snapshot.

const std = @import("std");
const pfs = @import("platform").fs;
const catalog = @import("runtime/catalog.zig");

pub const definition = @import("runtime/definition.zig");
pub const ExecContext = definition.ExecContext;
pub const Skill = definition.Skill;
pub const parseSkillMdWithFallback = definition.parseSkillMdWithFallback;
pub const parseSkillMd = definition.parseSkillMd;

pub const SkillSet = struct {
    allocator: std.mem.Allocator,
    /// Presentation/preload projection. Entries are owned clones of canonical
    /// records; execution must resolve the corresponding Runtime snapshot.
    skills: std.ArrayList(Skill),
    catalog_revision: [64]u8 = [_]u8{0} ** 64,

    pub fn init(allocator: std.mem.Allocator) SkillSet {
        return .{ .allocator = allocator, .skills = .empty };
    }

    pub fn deinit(self: *SkillSet) void {
        deinitItems(self.allocator, &self.skills);
        self.* = undefined;
    }

    pub fn replaceFromSnapshot(self: *SkillSet, snapshot: *const catalog.Snapshot) !void {
        var replacement: std.ArrayList(Skill) = .empty;
        errdefer deinitItems(self.allocator, &replacement);
        for (snapshot.skills) |record| {
            const projected = try cloneProjection(self.allocator, record);
            errdefer projected.deinit(self.allocator);
            try replacement.append(self.allocator, projected);
        }

        deinitItems(self.allocator, &self.skills);
        self.skills = replacement;
        self.catalog_revision = snapshot.revision;
    }

    pub fn find(self: *const SkillSet, invocation_name: []const u8) ?*const Skill {
        for (self.skills.items) |*skill| {
            if (std.mem.eql(u8, skill.name, invocation_name)) return skill;
        }
        return null;
    }

    pub fn len(self: *const SkillSet) usize {
        return self.skills.items.len;
    }
};

fn cloneProjection(allocator: std.mem.Allocator, record: catalog.SkillRecord) !Skill {
    const source = record.definition;
    const name = try allocator.dupe(u8, record.invocation_name);
    errdefer allocator.free(name);
    const description = try allocator.dupe(u8, source.description);
    errdefer allocator.free(description);
    const body = try allocator.dupe(u8, source.body);
    errdefer allocator.free(body);
    const allowed_tools = try cloneStrings(allocator, source.allowed_tools);
    errdefer freeStrings(allocator, allowed_tools);
    const disallowed_tools = try cloneStrings(allocator, source.disallowed_tools);
    errdefer freeStrings(allocator, disallowed_tools);
    const arguments = try cloneStrings(allocator, source.arguments);
    errdefer freeStrings(allocator, arguments);
    const agent = try allocator.dupe(u8, source.agent);
    errdefer allocator.free(agent);
    const model = try allocator.dupe(u8, source.model);
    errdefer allocator.free(model);
    const shell = try allocator.dupe(u8, source.shell);
    errdefer allocator.free(shell);
    // A projection must never hand an executable path back to the old live-tree
    // path. Runtime activation supplies a per-invocation working tree instead.
    const source_path = try allocator.dupe(u8, "");
    errdefer allocator.free(source_path);

    return .{
        .name = name,
        .description = description,
        .body = body,
        .allowed_tools = allowed_tools,
        .disallowed_tools = disallowed_tools,
        .arguments = arguments,
        .disable_model_invocation = source.disable_model_invocation,
        .context = source.context,
        .agent = agent,
        .model = model,
        .shell = shell,
        .source_path = source_path,
    };
}

fn cloneStrings(allocator: std.mem.Allocator, source: []const []const u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, source.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |value| allocator.free(value);
        allocator.free(result);
    }
    while (initialized < source.len) : (initialized += 1) {
        result[initialized] = try allocator.dupe(u8, source[initialized]);
    }
    return result;
}

fn freeStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn deinitItems(allocator: std.mem.Allocator, items: *std.ArrayList(Skill)) void {
    for (items.items) |skill| skill.deinit(allocator);
    items.deinit(allocator);
    items.* = .empty;
}

/// Locate the canonical repository root used as the Runtime workspace scope.
pub fn findRepoRoot(allocator: std.mem.Allocator, start_dir: []const u8) ![]u8 {
    var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (start_dir.len >= buffer.len) return error.PathTooLong;
    @memcpy(buffer[0..start_dir.len], start_dir);
    var dir_len = start_dir.len;
    while (dir_len > 1 and isSep(buffer[dir_len - 1])) dir_len -= 1;

    while (dir_len > 0) {
        const suffix = "/.git";
        if (dir_len + suffix.len + 1 >= buffer.len) return error.PathTooLong;
        @memcpy(buffer[dir_len .. dir_len + suffix.len], suffix);
        buffer[dir_len + suffix.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&buffer);
        if (pfs.exists(path_z)) return allocator.dupe(u8, buffer[0..dir_len]);
        if (dir_len == 1) break;
        var parent_len = dir_len;
        while (parent_len > 1 and !isSep(buffer[parent_len - 1])) parent_len -= 1;
        while (parent_len > 1 and isSep(buffer[parent_len - 1])) parent_len -= 1;
        if (parent_len == dir_len) break;
        dir_len = parent_len;
    }
    return error.NotInGitRepo;
}

inline fn isSep(value: u8) bool {
    return value == '/' or value == '\\';
}

test "SkillSet projection uses invocation identity and no live source path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var record = catalog.SkillRecord{
        .skill_id = [_]u8{'a'} ** 64,
        .invocation_name = "review",
        .definition = try definition.parseSkillMdWithFallback(
            arena.allocator(),
            "---\nname: Display Name\ndescription: desc\n---\nbody",
            "/live/source",
            "fallback",
        ),
        .directories = &.{},
        .files = &.{},
    };
    _ = &record;
    var snapshot = catalog.Snapshot{
        .owner_allocator = std.testing.allocator,
        .arena = arena,
        .scope_id = [_]u8{'b'} ** 64,
        .revision = [_]u8{'c'} ** 64,
        .health = .healthy,
        .skills = (&[_]catalog.SkillRecord{record})[0..],
        .issues = &.{},
        .descriptor_json = "",
        .snapshot_bytes = 0,
        .resident_bytes = 0,
    };
    _ = &snapshot;

    var set = SkillSet.init(std.testing.allocator);
    defer set.deinit();
    try set.replaceFromSnapshot(&snapshot);
    try std.testing.expectEqualStrings("review", set.skills.items[0].name);
    try std.testing.expectEqualStrings("", set.skills.items[0].source_path);
}
