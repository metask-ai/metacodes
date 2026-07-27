//! Immutable Skill catalog snapshot used by the AgentCore ABI.
//!
//! The existing CLI `SkillSet` remains a tolerant product projection. This
//! resolver reuses its canonical frontmatter parser, but retains structural
//! candidates and snapshots selected trees so the ABI can expose deterministic
//! tombstones, revisions, and no-follow execution inputs.

const std = @import("std");
const builtin = @import("builtin");
const skill_mod = @import("metacodes-core").skills;

const Dir = std.Io.Dir;
const File = std.Io.File;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Limits = struct {
    max_slots: usize = 1024,
    max_descriptor_bytes: usize = 4 * 1024 * 1024,
    max_visited_entries: usize = 65536,
    max_depth: usize = 64,
    max_relative_path_bytes: usize = 4096,
    max_files: usize = 16384,
    max_single_file_bytes: usize = 4 * 1024 * 1024,
    max_snapshot_bytes: usize = 64 * 1024 * 1024,
};

pub const SourceScope = enum {
    enterprise,
    personal,
    project,
    plugin,
};

/// Higher numeric priority wins. Equal-priority candidates for the same
/// invocation name are a conflict, independent of source enumeration order.
pub const Source = struct {
    root: []const u8,
    scope: SourceScope,
    priority: u32,
    namespace: []const u8 = "",
};

pub const IssueCode = enum {
    invalid_definition,
    source_conflict,
    invalid_resource,
    invalid_invocation_name,
};

pub const Health = enum {
    healthy,
    degraded,
};

pub const FileRecord = struct {
    relative_path: []const u8,
    bytes: []const u8,
    executable: bool,
};

pub const SkillRecord = struct {
    skill_id: [64]u8,
    invocation_name: []const u8,
    definition: skill_mod.Skill,
    files: []const FileRecord,
};

pub const Issue = struct {
    code: IssueCode,
    invocation_name: ?[]const u8,
    source_scope: SourceScope,
    /// Internal-only stable identity for revision hashing and ordering. This
    /// preserves evidence for invalid raw names without exposing those names.
    revision_key: []const u8,
};

pub const BuildError = error{
    OutOfMemory,
    ResourceLimit,
    CatalogInvalid,
    InvalidScopeId,
};

pub const Snapshot = struct {
    owner_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    scope_id: [64]u8,
    revision: [64]u8,
    health: Health,
    skills: []const SkillRecord,
    issues: []const Issue,
    descriptor_json: []const u8,
    snapshot_bytes: usize,
    resident_bytes: usize,

    pub fn deinit(self: *Snapshot) void {
        const owner = self.owner_allocator;
        self.arena.deinit();
        owner.destroy(self);
    }

    pub fn findById(self: *const Snapshot, id: []const u8) ?*const SkillRecord {
        if (id.len != 64) return null;
        for (self.skills) |*skill| {
            if (std.mem.eql(u8, &skill.skill_id, id)) return skill;
        }
        return null;
    }

    pub fn findByInvocation(self: *const Snapshot, name: []const u8) ?*const SkillRecord {
        for (self.skills) |*skill| {
            if (std.mem.eql(u8, skill.invocation_name, name)) return skill;
        }
        return null;
    }
};

const Candidate = struct {
    root: []const u8,
    dir_name: []const u8,
    invocation_name: []const u8,
    scope: SourceScope,
    priority: u32,
    kind: File.Kind,
};

const EntryCopy = struct {
    name: []const u8,
    kind: File.Kind,
};

const Counters = struct {
    visited_entries: usize = 0,
    file_count: usize = 0,
    snapshot_bytes: usize = 0,
};

const LocalError = error{
    OutOfMemory,
    ResourceLimit,
    CatalogInvalid,
    InvalidDefinition,
    InvalidResource,
};

pub fn build(
    owner_allocator: std.mem.Allocator,
    io: std.Io,
    scope_id: []const u8,
    workspace_epoch: []const u8,
    sources: []const Source,
    limits: Limits,
) BuildError!*Snapshot {
    if (!isLowerHex64(scope_id)) return error.InvalidScopeId;

    const snapshot = owner_allocator.create(Snapshot) catch return error.OutOfMemory;
    snapshot.* = .{
        .owner_allocator = owner_allocator,
        .arena = std.heap.ArenaAllocator.init(owner_allocator),
        .scope_id = undefined,
        .revision = undefined,
        .health = .healthy,
        .skills = &.{},
        .issues = &.{},
        .descriptor_json = "",
        .snapshot_bytes = 0,
        .resident_bytes = 0,
    };
    errdefer {
        snapshot.arena.deinit();
        owner_allocator.destroy(snapshot);
    }
    @memcpy(&snapshot.scope_id, scope_id);
    const arena = snapshot.arena.allocator();
    var build_scratch = std.heap.ArenaAllocator.init(owner_allocator);
    defer build_scratch.deinit();
    const scratch = build_scratch.allocator();

    var candidates: std.ArrayList(Candidate) = .empty;
    var issues: std.ArrayList(Issue) = .empty;
    var counters = Counters{};

    for (sources) |source| {
        try enumerateSource(scratch, io, source, limits, &counters, &candidates, &issues);
    }
    std.mem.sort(Candidate, candidates.items, {}, candidateLessThan);
    std.mem.sort(Issue, issues.items, {}, issueLessThan);

    var records: std.ArrayList(SkillRecord) = .empty;
    var cursor: usize = 0;
    var slot_count: usize = 0;
    while (cursor < candidates.items.len) {
        const start = cursor;
        const invocation_name = candidates.items[start].invocation_name;
        while (cursor < candidates.items.len and
            std.mem.eql(u8, candidates.items[cursor].invocation_name, invocation_name))
        {
            cursor += 1;
        }
        slot_count = std.math.add(usize, slot_count, 1) catch return error.ResourceLimit;
        if (slot_count > limits.max_slots) return error.ResourceLimit;

        const group = candidates.items[start..cursor];
        const highest = group[0].priority;
        var top_count: usize = 1;
        while (top_count < group.len and group[top_count].priority == highest) : (top_count += 1) {}
        if (top_count != 1) {
            try issues.append(scratch, .{
                .code = .source_conflict,
                .invocation_name = invocation_name,
                .source_scope = group[0].scope,
                .revision_key = invocation_name,
            });
            continue;
        }

        const selected = group[0];
        if (selected.kind != .directory) {
            try issues.append(scratch, .{
                .code = .invalid_resource,
                .invocation_name = invocation_name,
                .source_scope = selected.scope,
                .revision_key = invocation_name,
            });
            continue;
        }
        const record = snapshotCandidate(
            arena,
            owner_allocator,
            io,
            selected,
            limits,
            &counters,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ResourceLimit => return error.ResourceLimit,
            error.CatalogInvalid => return error.CatalogInvalid,
            error.InvalidDefinition => {
                try issues.append(scratch, .{
                    .code = .invalid_definition,
                    .invocation_name = invocation_name,
                    .source_scope = selected.scope,
                    .revision_key = invocation_name,
                });
                continue;
            },
            error.InvalidResource => {
                try issues.append(scratch, .{
                    .code = .invalid_resource,
                    .invocation_name = invocation_name,
                    .source_scope = selected.scope,
                    .revision_key = invocation_name,
                });
                continue;
            },
        };
        try records.append(arena, record);
    }

    std.mem.sort(SkillRecord, records.items, {}, recordLessThan);
    std.mem.sort(Issue, issues.items, {}, issueLessThan);
    snapshot.skills = records.toOwnedSlice(arena) catch return error.OutOfMemory;
    snapshot.issues = cloneIssues(arena, issues.items) catch return error.OutOfMemory;
    snapshot.snapshot_bytes = counters.snapshot_bytes;
    snapshot.health = if (snapshot.issues.len == 0) .healthy else .degraded;
    snapshot.revision = computeRevision(snapshot, workspace_epoch);
    snapshot.descriptor_json = buildDescriptor(arena, snapshot, limits.max_descriptor_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ResourceLimit => return error.ResourceLimit,
        else => return error.CatalogInvalid,
    };
    snapshot.resident_bytes = std.math.add(
        usize,
        @sizeOf(Snapshot),
        snapshot.arena.queryCapacity(),
    ) catch return error.ResourceLimit;
    return snapshot;
}

fn enumerateSource(
    arena: std.mem.Allocator,
    io: std.Io,
    source: Source,
    limits: Limits,
    counters: *Counters,
    candidates: *std.ArrayList(Candidate),
    issues: *std.ArrayList(Issue),
) BuildError!void {
    if (source.root.len == 0 or !std.fs.path.isAbsolute(source.root)) return error.CatalogInvalid;
    if (source.namespace.len > 128) return error.ResourceLimit;
    var root = Dir.openDirAbsolute(io, source.root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return error.CatalogInvalid,
    };
    defer root.close(io);
    const before = root.stat(io) catch return error.CatalogInvalid;
    if (before.kind != .directory) return error.CatalogInvalid;

    var iterator = root.iterate();
    while (iterator.next(io) catch return error.CatalogInvalid) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        counters.visited_entries = std.math.add(usize, counters.visited_entries, 1) catch
            return error.ResourceLimit;
        if (counters.visited_entries > limits.max_visited_entries) return error.ResourceLimit;

        const invocation = makeInvocationName(arena, source.namespace, entry.name) catch
            return error.OutOfMemory;
        if (!validInvocationName(invocation)) {
            const raw_name_hash = hashHex(invocation);
            try issues.append(arena, .{
                .code = .invalid_invocation_name,
                .invocation_name = null,
                .source_scope = source.scope,
                .revision_key = try arena.dupe(u8, &raw_name_hash),
            });
            continue;
        }
        const kind = if (entry.kind == .unknown)
            (root.statFile(io, entry.name, .{ .follow_symlinks = false }) catch
                return error.CatalogInvalid).kind
        else
            entry.kind;
        try candidates.append(arena, .{
            // Sources are borrowed for the synchronous duration of `build`.
            .root = source.root,
            .dir_name = try arena.dupe(u8, entry.name),
            .invocation_name = invocation,
            .scope = source.scope,
            .priority = source.priority,
            .kind = kind,
        });
    }
    const after = root.stat(io) catch return error.CatalogInvalid;
    if (!sameDirectoryState(before, after)) return error.CatalogInvalid;
}

fn snapshotCandidate(
    destination: std.mem.Allocator,
    temporary_allocator: std.mem.Allocator,
    io: std.Io,
    candidate: Candidate,
    limits: Limits,
    counters: *Counters,
) LocalError!SkillRecord {
    var temporary = std.heap.ArenaAllocator.init(temporary_allocator);
    defer temporary.deinit();
    const scratch = temporary.allocator();

    const record = try snapshotCandidateTemporary(scratch, io, candidate, limits, counters);
    return cloneSkillRecord(destination, record);
}

fn snapshotCandidateTemporary(
    arena: std.mem.Allocator,
    io: std.Io,
    candidate: Candidate,
    limits: Limits,
    counters: *Counters,
) LocalError!SkillRecord {
    var root = Dir.openDirAbsolute(io, candidate.root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return error.CatalogInvalid;
    defer root.close(io);
    var skill_dir = root.openDir(io, candidate.dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return error.InvalidResource;
    defer skill_dir.close(io);

    var files: std.ArrayList(FileRecord) = .empty;
    try snapshotTree(arena, io, skill_dir, "", 0, limits, counters, &files);
    std.mem.sort(FileRecord, files.items, {}, fileLessThan);
    const owned_files = try files.toOwnedSlice(arena);

    var definition_bytes: ?[]const u8 = null;
    for (owned_files) |file| {
        if (std.mem.eql(u8, file.relative_path, "SKILL.md")) {
            definition_bytes = file.bytes;
            break;
        }
    }
    const md = definition_bytes orelse return error.InvalidDefinition;
    if (!std.unicode.utf8ValidateSlice(md)) return error.InvalidDefinition;
    validateSkillMetadata(md) catch return error.InvalidDefinition;
    const definition = skill_mod.parseSkillMdWithFallback(
        arena,
        md,
        "",
        candidate.dir_name,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.InvalidDefinition;
    };
    if (!validArgumentNames(definition.arguments)) return error.InvalidDefinition;

    return .{
        .skill_id = hashHex(candidate.invocation_name),
        .invocation_name = candidate.invocation_name,
        .definition = definition,
        .files = owned_files,
    };
}

fn cloneSkillRecord(arena: std.mem.Allocator, source: SkillRecord) error{OutOfMemory}!SkillRecord {
    const files = try arena.alloc(FileRecord, source.files.len);
    for (source.files, files) |file, *copy| {
        copy.* = .{
            .relative_path = try arena.dupe(u8, file.relative_path),
            .bytes = try arena.dupe(u8, file.bytes),
            .executable = file.executable,
        };
    }
    return .{
        .skill_id = source.skill_id,
        .invocation_name = try arena.dupe(u8, source.invocation_name),
        .definition = .{
            .name = try arena.dupe(u8, source.definition.name),
            .description = try arena.dupe(u8, source.definition.description),
            .body = try arena.dupe(u8, source.definition.body),
            .allowed_tools = try cloneStringList(arena, source.definition.allowed_tools),
            .disallowed_tools = try cloneStringList(arena, source.definition.disallowed_tools),
            .arguments = try cloneStringList(arena, source.definition.arguments),
            .disable_model_invocation = source.definition.disable_model_invocation,
            .context = source.definition.context,
            .agent = try arena.dupe(u8, source.definition.agent),
            .model = try arena.dupe(u8, source.definition.model),
            .shell = try arena.dupe(u8, source.definition.shell),
            .source_path = "",
        },
        .files = files,
    };
}

fn cloneStringList(
    arena: std.mem.Allocator,
    source: []const []const u8,
) error{OutOfMemory}![]const []const u8 {
    const result = try arena.alloc([]const u8, source.len);
    for (source, result) |value, *copy| copy.* = try arena.dupe(u8, value);
    return result;
}

fn cloneIssues(
    arena: std.mem.Allocator,
    source: []const Issue,
) error{OutOfMemory}![]const Issue {
    const result = try arena.alloc(Issue, source.len);
    for (source, result) |issue, *copy| {
        copy.* = .{
            .code = issue.code,
            .invocation_name = if (issue.invocation_name) |name|
                try arena.dupe(u8, name)
            else
                null,
            .source_scope = issue.source_scope,
            .revision_key = try arena.dupe(u8, issue.revision_key),
        };
    }
    return result;
}

fn snapshotTree(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: Dir,
    prefix: []const u8,
    depth: usize,
    limits: Limits,
    counters: *Counters,
    files: *std.ArrayList(FileRecord),
) LocalError!void {
    if (depth > limits.max_depth) return error.ResourceLimit;
    const before = dir.stat(io) catch return error.InvalidResource;
    if (before.kind != .directory) return error.InvalidResource;
    var entries: std.ArrayList(EntryCopy) = .empty;
    var iterator = dir.iterate();
    while (iterator.next(io) catch return error.InvalidResource) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        counters.visited_entries = std.math.add(usize, counters.visited_entries, 1) catch
            return error.ResourceLimit;
        if (counters.visited_entries > limits.max_visited_entries) return error.ResourceLimit;
        try entries.append(arena, .{
            .name = try arena.dupe(u8, entry.name),
            .kind = entry.kind,
        });
    }
    std.mem.sort(EntryCopy, entries.items, {}, entryLessThan);

    for (entries.items) |entry| {
        const relative_path = if (prefix.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });
        if (relative_path.len == 0 or relative_path.len > limits.max_relative_path_bytes)
            return error.ResourceLimit;

        switch (entry.kind) {
            .directory => {
                var child = dir.openDir(io, entry.name, .{
                    .iterate = true,
                    .follow_symlinks = false,
                }) catch return error.InvalidResource;
                defer child.close(io);
                try snapshotTree(arena, io, child, relative_path, depth + 1, limits, counters, files);
            },
            .file => try snapshotFile(arena, io, dir, entry.name, relative_path, limits, counters, files),
            .sym_link => return error.InvalidResource,
            .unknown => {
                const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch
                    return error.InvalidResource;
                switch (stat.kind) {
                    .directory => {
                        var child = dir.openDir(io, entry.name, .{
                            .iterate = true,
                            .follow_symlinks = false,
                        }) catch return error.InvalidResource;
                        defer child.close(io);
                        try snapshotTree(arena, io, child, relative_path, depth + 1, limits, counters, files);
                    },
                    .file => try snapshotFile(arena, io, dir, entry.name, relative_path, limits, counters, files),
                    else => return error.InvalidResource,
                }
            },
            else => return error.InvalidResource,
        }
    }
    const after = dir.stat(io) catch return error.InvalidResource;
    if (!sameDirectoryState(before, after)) return error.InvalidResource;
}

fn snapshotFile(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: Dir,
    name: []const u8,
    relative_path: []const u8,
    limits: Limits,
    counters: *Counters,
    files: *std.ArrayList(FileRecord),
) LocalError!void {
    var file = dir.openFile(io, name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch return error.InvalidResource;
    defer file.close(io);
    // Zig 0.16's Windows Threaded backend opens no-follow files with
    // `IO.ASYNCHRONOUS` but currently returns `nonblocking=false`. Correct the
    // local value so positional reads wait for PENDING completion instead of
    // treating it as an impossible synchronous result.
    if (builtin.os.tag == .windows) file.flags.nonblocking = true;
    const before = file.stat(io) catch return error.InvalidResource;
    if (before.kind != .file) return error.InvalidResource;
    if (before.size > limits.max_single_file_bytes) return error.ResourceLimit;
    const size = std.math.cast(usize, before.size) orelse return error.ResourceLimit;
    counters.file_count = std.math.add(usize, counters.file_count, 1) catch
        return error.ResourceLimit;
    if (counters.file_count > limits.max_files) return error.ResourceLimit;
    counters.snapshot_bytes = std.math.add(usize, counters.snapshot_bytes, size) catch
        return error.ResourceLimit;
    if (counters.snapshot_bytes > limits.max_snapshot_bytes) return error.ResourceLimit;

    var read_buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const read_limit = std.math.add(usize, limits.max_single_file_bytes, 1) catch
        return error.ResourceLimit;
    const bytes = reader.interface.allocRemaining(arena, .limited(read_limit)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.ResourceLimit,
        else => return error.InvalidResource,
    };
    if (bytes.len != size) return error.InvalidResource;
    const after = file.stat(io) catch return error.InvalidResource;
    if (after.size != before.size or
        after.mtime.nanoseconds != before.mtime.nanoseconds or
        after.ctime.nanoseconds != before.ctime.nanoseconds)
        return error.InvalidResource;

    const executable = if (File.Permissions.has_executable_bit)
        (@intFromEnum(before.permissions) & 0o111) != 0
    else
        false;
    try files.append(arena, .{
        .relative_path = relative_path,
        .bytes = bytes,
        .executable = executable,
    });
}

fn buildDescriptor(
    arena: std.mem.Allocator,
    snapshot: *const Snapshot,
    max_bytes: usize,
) ![]u8 {
    const ArgumentSchema = struct {
        schema: []const u8 = "metask.skill-arguments/v1",
        max_values: u32 = 64,
        names: []const []const u8,
    };
    const DescriptorSkill = struct {
        skill_id: []const u8,
        invocation_name: []const u8,
        display_name: []const u8,
        description: []const u8,
        argument_schema: ArgumentSchema,
    };
    const DescriptorIssue = struct {
        code: IssueCode,
        invocation_name: ?[]const u8,
        source_scope: SourceScope,
    };
    const Descriptor = struct {
        schema: []const u8 = "metask.skill-catalog/v1",
        catalog_scope_id: []const u8,
        catalog_revision: []const u8,
        health: Health,
        skills: []const DescriptorSkill,
        issues: []const DescriptorIssue,
    };

    const skills = try arena.alloc(DescriptorSkill, snapshot.skills.len);
    for (snapshot.skills, skills) |record, *descriptor| {
        descriptor.* = .{
            .skill_id = &record.skill_id,
            .invocation_name = record.invocation_name,
            .display_name = record.definition.name,
            .description = record.definition.description,
            .argument_schema = .{ .names = record.definition.arguments },
        };
    }
    const issues = try arena.alloc(DescriptorIssue, snapshot.issues.len);
    for (snapshot.issues, issues) |issue, *descriptor| {
        descriptor.* = .{
            .code = issue.code,
            .invocation_name = issue.invocation_name,
            .source_scope = issue.source_scope,
        };
    }
    const descriptor = Descriptor{
        .catalog_scope_id = &snapshot.scope_id,
        .catalog_revision = &snapshot.revision,
        .health = snapshot.health,
        .skills = skills,
        .issues = issues,
    };

    // Count the exact escaped JSON size before allocating the public buffer.
    // Descriptor caps therefore apply before output allocation, not after a
    // potentially unbounded `valueAlloc`.
    var count_buffer: [256]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&count_buffer);
    try std.json.Stringify.value(descriptor, .{}, &discarding.writer);
    const encoded_len_u64 = discarding.fullCount();
    if (encoded_len_u64 > max_bytes or encoded_len_u64 > std.math.maxInt(usize))
        return error.ResourceLimit;
    const encoded_len: usize = @intCast(encoded_len_u64);

    var allocating = try std.Io.Writer.Allocating.initCapacity(arena, encoded_len);
    defer allocating.deinit();
    try std.json.Stringify.value(descriptor, .{}, &allocating.writer);
    const encoded = try allocating.toOwnedSlice();
    std.debug.assert(encoded.len == encoded_len);
    return encoded;
}

fn computeRevision(snapshot: *const Snapshot, workspace_epoch: []const u8) [64]u8 {
    var hash = Sha256.init(.{});
    hashField(&hash, &snapshot.scope_id);
    hashField(&hash, workspace_epoch);
    for (snapshot.skills) |record| {
        hashField(&hash, "skill");
        hashField(&hash, record.invocation_name);
        hashField(&hash, record.definition.name);
        hashField(&hash, record.definition.description);
        hashField(&hash, record.definition.body);
        hashField(&hash, @tagName(record.definition.context));
        hashField(&hash, record.definition.agent);
        hashField(&hash, record.definition.model);
        hashField(&hash, record.definition.shell);
        hashU64(&hash, @intFromBool(record.definition.disable_model_invocation));
        for (record.definition.arguments) |value| hashField(&hash, value);
        for (record.definition.allowed_tools) |value| hashField(&hash, value);
        for (record.definition.disallowed_tools) |value| hashField(&hash, value);
        for (record.files) |file| {
            hashField(&hash, file.relative_path);
            hashU64(&hash, @intFromBool(file.executable));
            hashField(&hash, file.bytes);
        }
    }
    for (snapshot.issues) |issue| {
        hashField(&hash, "issue");
        hashField(&hash, @tagName(issue.code));
        hashField(&hash, issue.revision_key);
        hashField(&hash, @tagName(issue.source_scope));
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn hashHex(value: []const u8) [64]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(value, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn hashField(hash: *Sha256, value: []const u8) void {
    hashU64(hash, value.len);
    hash.update(value);
}

fn hashU64(hash: *Sha256, value: u64) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .big);
    hash.update(&encoded);
}

fn makeInvocationName(arena: std.mem.Allocator, namespace: []const u8, name: []const u8) ![]const u8 {
    return if (namespace.len == 0)
        arena.dupe(u8, name)
    else
        std.fmt.allocPrint(arena, "{s}:{s}", .{ namespace, name });
}

/// The shared parser remains the canonical materializer. The formal ABI adds
/// strict validation only where that parser intentionally has tolerant
/// fallbacks, so malformed policy metadata becomes a typed tombstone instead
/// of silently changing meaning.
fn validateSkillMetadata(md: []const u8) error{InvalidDefinition}!void {
    if (!std.mem.startsWith(u8, md, "---\n")) return;
    const fm_start: usize = 4;
    const fm_end = std.mem.indexOfPos(u8, md, fm_start, "\n---\n") orelse
        return error.InvalidDefinition;
    var lines = std.mem.splitScalar(u8, md[fm_start..fm_end], '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse
            return error.InvalidDefinition;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (std.mem.eql(u8, key, "context")) {
            if (!std.mem.eql(u8, value, "inline") and !std.mem.eql(u8, value, "fork"))
                return error.InvalidDefinition;
        } else if (std.mem.eql(u8, key, "shell")) {
            if (!std.mem.eql(u8, value, "bash") and !std.mem.eql(u8, value, "powershell"))
                return error.InvalidDefinition;
        } else if (std.mem.eql(u8, key, "disable-model-invocation") or
            std.mem.eql(u8, key, "disable_model_invocation"))
        {
            if (!validBoolean(value)) return error.InvalidDefinition;
        }
    }
}

fn validBoolean(value: []const u8) bool {
    return std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "yes") or
        std.mem.eql(u8, value, "1") or
        std.mem.eql(u8, value, "false") or
        std.mem.eql(u8, value, "no") or
        std.mem.eql(u8, value, "0");
}

fn validArgumentNames(names: []const []const u8) bool {
    if (names.len > 64) return false;
    for (names, 0..) |name, index| {
        if (name.len == 0 or name.len > 64) return false;
        if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
        for (name[1..]) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
        }
        for (names[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier, name)) return false;
        }
    }
    return true;
}

fn sameDirectoryState(lhs: File.Stat, rhs: File.Stat) bool {
    return lhs.kind == rhs.kind and
        lhs.inode == rhs.inode and
        lhs.mtime.nanoseconds == rhs.mtime.nanoseconds and
        lhs.ctime.nanoseconds == rhs.ctime.nanoseconds;
}

pub fn validInvocationName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    const first = name[0];
    if (!std.ascii.isAlphanumeric(first) and first != '_') return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != ':' and byte != '-')
            return false;
    }
    return true;
}

pub fn isLowerHex64(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    }
    return true;
}

fn candidateLessThan(_: void, lhs: Candidate, rhs: Candidate) bool {
    const by_name = std.mem.order(u8, lhs.invocation_name, rhs.invocation_name);
    if (by_name != .eq) return by_name == .lt;
    if (lhs.priority != rhs.priority) return lhs.priority > rhs.priority;
    const by_scope = std.mem.order(u8, @tagName(lhs.scope), @tagName(rhs.scope));
    if (by_scope != .eq) return by_scope == .lt;
    const by_root = std.mem.order(u8, lhs.root, rhs.root);
    if (by_root != .eq) return by_root == .lt;
    return std.mem.lessThan(u8, lhs.dir_name, rhs.dir_name);
}

fn issueLessThan(_: void, lhs: Issue, rhs: Issue) bool {
    const lhs_name = lhs.invocation_name orelse "";
    const rhs_name = rhs.invocation_name orelse "";
    const by_name = std.mem.order(u8, lhs_name, rhs_name);
    if (by_name != .eq) return by_name == .lt;
    const by_revision_key = std.mem.order(u8, lhs.revision_key, rhs.revision_key);
    if (by_revision_key != .eq) return by_revision_key == .lt;
    const by_code = std.mem.order(u8, @tagName(lhs.code), @tagName(rhs.code));
    if (by_code != .eq) return by_code == .lt;
    return std.mem.lessThan(u8, @tagName(lhs.source_scope), @tagName(rhs.source_scope));
}

fn recordLessThan(_: void, lhs: SkillRecord, rhs: SkillRecord) bool {
    return std.mem.lessThan(u8, lhs.invocation_name, rhs.invocation_name);
}

fn entryLessThan(_: void, lhs: EntryCopy, rhs: EntryCopy) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

fn fileLessThan(_: void, lhs: FileRecord, rhs: FileRecord) bool {
    return std.mem.lessThan(u8, lhs.relative_path, rhs.relative_path);
}

test "invocation grammar is intentionally wider than provider tool names" {
    try std.testing.expect(validInvocationName("review"));
    try std.testing.expect(validInvocationName("plugin:review-2"));
    try std.testing.expect(validInvocationName("9patch"));
    try std.testing.expect(!validInvocationName(":bad"));
    try std.testing.expect(!validInvocationName("bad.name"));
    try std.testing.expect(!validInvocationName("x" ** 129));
}

test "typed argument schema accepts only unique renderable names" {
    try std.testing.expect(validArgumentNames(&.{ "issue", "_branch2" }));
    try std.testing.expect(!validArgumentNames(&.{ "issue", "issue" }));
    try std.testing.expect(!validArgumentNames(&.{"bad-name"}));
    try std.testing.expect(!validArgumentNames(&.{"9bad"}));
}

test "catalog priority, tombstone, snapshot, parser parity, and revision are deterministic" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const low = try std.fmt.allocPrint(std.testing.allocator, "{s}/low", .{root});
    defer std.testing.allocator.free(low);
    const high = try std.fmt.allocPrint(std.testing.allocator, "{s}/high", .{root});
    defer std.testing.allocator.free(high);
    const low_resources = try std.fmt.allocPrint(std.testing.allocator, "{s}/review/resources", .{low});
    defer std.testing.allocator.free(low_resources);
    const high_resources = try std.fmt.allocPrint(std.testing.allocator, "{s}/review/resources", .{high});
    defer std.testing.allocator.free(high_resources);
    try Dir.cwd().createDirPath(io, low_resources);
    try Dir.cwd().createDirPath(io, high_resources);
    const low_md_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/review/SKILL.md", .{low});
    defer std.testing.allocator.free(low_md_path);
    const high_md_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/review/SKILL.md", .{high});
    defer std.testing.allocator.free(high_md_path);
    const resource_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/review/resources/rule.txt", .{high});
    defer std.testing.allocator.free(resource_path);
    const low_md = "---\nname: Low\n description: ignored\n---\nlow";
    const high_md = "---\nname: High\ndescription: selected\narguments: [topic]\n---\nhigh";
    try Dir.cwd().writeFile(io, .{ .sub_path = low_md_path, .data = low_md });
    try Dir.cwd().writeFile(io, .{ .sub_path = high_md_path, .data = high_md });
    try Dir.cwd().writeFile(io, .{ .sub_path = resource_path, .data = "frozen" });

    const sources = [_]Source{
        .{ .root = low, .scope = .project, .priority = 1 },
        .{ .root = high, .scope = .project, .priority = 2 },
    };
    const scope_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const first = try build(std.testing.allocator, io, scope_id, "epoch-1", &sources, .{});
    defer first.deinit();
    const second = try build(std.testing.allocator, io, scope_id, "epoch-1", &sources, .{});
    defer second.deinit();
    try std.testing.expectEqual(Health.healthy, first.health);
    try std.testing.expectEqual(@as(usize, 1), first.skills.len);
    try std.testing.expectEqualStrings("High", first.skills[0].definition.name);
    try std.testing.expect(first.skills[0].files.len == 2);
    try std.testing.expectEqualSlices(u8, &first.revision, &second.revision);
    try std.testing.expectEqualStrings(first.descriptor_json, second.descriptor_json);
    try std.testing.expect(std.mem.indexOf(u8, first.descriptor_json, "source_path") == null);
    try std.testing.expect(std.mem.indexOf(u8, first.descriptor_json, "\"body\"") == null);

    var parsed = try skill_mod.parseSkillMdWithFallback(std.testing.allocator, high_md, "", "review");
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(parsed.name, first.skills[0].definition.name);
    try std.testing.expectEqualStrings(parsed.description, first.skills[0].definition.description);

    try Dir.cwd().writeFile(io, .{ .sub_path = high_md_path, .data = "\xff" });
    const degraded = try build(std.testing.allocator, io, scope_id, "epoch-1", &sources, .{});
    defer degraded.deinit();
    try std.testing.expectEqual(Health.degraded, degraded.health);
    try std.testing.expectEqual(@as(usize, 0), degraded.skills.len);
    try std.testing.expectEqual(@as(usize, 1), degraded.issues.len);
    try std.testing.expectEqual(IssueCode.invalid_definition, degraded.issues[0].code);
    try std.testing.expectEqualStrings("review", degraded.issues[0].invocation_name.?);
}

test "catalog limits fail the whole query before publishing a partial snapshot" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const skill_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/one", .{root});
    defer std.testing.allocator.free(skill_dir);
    try Dir.cwd().createDirPath(io, skill_dir);
    const md_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/SKILL.md", .{skill_dir});
    defer std.testing.allocator.free(md_path);
    try Dir.cwd().writeFile(io, .{ .sub_path = md_path, .data = "---\nname: One\n---\nbody" });
    const sources = [_]Source{.{ .root = root, .scope = .project, .priority = 1 }};
    const scope_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expectError(
        error.ResourceLimit,
        build(std.testing.allocator, io, scope_id, "epoch", &sources, .{ .max_single_file_bytes = 1 }),
    );
    try std.testing.expectError(
        error.ResourceLimit,
        build(std.testing.allocator, io, scope_id, "epoch", &sources, .{ .max_descriptor_bytes = 1 }),
    );
}

test "invalid policy metadata is a slot tombstone and does not fall back" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const low = try std.fmt.allocPrint(std.testing.allocator, "{s}/low/review", .{root});
    defer std.testing.allocator.free(low);
    const high = try std.fmt.allocPrint(std.testing.allocator, "{s}/high/review", .{root});
    defer std.testing.allocator.free(high);
    try Dir.cwd().createDirPath(io, low);
    try Dir.cwd().createDirPath(io, high);
    const low_md = try std.fmt.allocPrint(std.testing.allocator, "{s}/SKILL.md", .{low});
    defer std.testing.allocator.free(low_md);
    const high_md = try std.fmt.allocPrint(std.testing.allocator, "{s}/SKILL.md", .{high});
    defer std.testing.allocator.free(high_md);
    try Dir.cwd().writeFile(io, .{ .sub_path = low_md, .data = "---\nname: Low\n---\nlow" });
    try Dir.cwd().writeFile(io, .{
        .sub_path = high_md,
        .data = "---\nname: High\ncontext: surprise\nshell: fish\n---\nhigh",
    });
    const sources = [_]Source{
        .{ .root = low[0 .. low.len - "/review".len], .scope = .project, .priority = 1 },
        .{ .root = high[0 .. high.len - "/review".len], .scope = .project, .priority = 2 },
    };
    const scope_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const catalog = try build(std.testing.allocator, io, scope_id, "epoch", &sources, .{});
    defer catalog.deinit();
    try std.testing.expectEqual(Health.degraded, catalog.health);
    try std.testing.expectEqual(@as(usize, 0), catalog.skills.len);
    try std.testing.expectEqual(@as(usize, 1), catalog.issues.len);
    try std.testing.expectEqual(IssueCode.invalid_definition, catalog.issues[0].code);
}

test "hidden invalid invocation identity still changes catalog revision" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const first_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/first", .{root});
    defer std.testing.allocator.free(first_root);
    const second_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/second", .{root});
    defer std.testing.allocator.free(second_root);
    const first_bad = try std.fmt.allocPrint(std.testing.allocator, "{s}/bad.one", .{first_root});
    defer std.testing.allocator.free(first_bad);
    const second_bad = try std.fmt.allocPrint(std.testing.allocator, "{s}/bad.two", .{second_root});
    defer std.testing.allocator.free(second_bad);
    try Dir.cwd().createDirPath(io, first_bad);
    try Dir.cwd().createDirPath(io, second_bad);
    const scope_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const first_sources = [_]Source{.{ .root = first_root, .scope = .project, .priority = 1 }};
    const second_sources = [_]Source{.{ .root = second_root, .scope = .project, .priority = 1 }};
    const first = try build(std.testing.allocator, io, scope_id, "epoch", &first_sources, .{});
    defer first.deinit();
    const second = try build(std.testing.allocator, io, scope_id, "epoch", &second_sources, .{});
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), first.issues.len);
    try std.testing.expect(first.issues[0].invocation_name == null);
    try std.testing.expect(!std.mem.eql(u8, &first.revision, &second.revision));
}

test "selected skill tree never follows symbolic links" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const skill_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/review", .{root});
    defer std.testing.allocator.free(skill_dir);
    try Dir.cwd().createDirPath(io, skill_dir);
    const md_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/SKILL.md", .{skill_dir});
    defer std.testing.allocator.free(md_path);
    const outside_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/outside.txt", .{root});
    defer std.testing.allocator.free(outside_path);
    const link_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/escape", .{skill_dir});
    defer std.testing.allocator.free(link_path);
    try Dir.cwd().writeFile(io, .{ .sub_path = md_path, .data = "---\nname: Review\n---\nbody" });
    try Dir.cwd().writeFile(io, .{ .sub_path = outside_path, .data = "secret" });
    Dir.symLinkAbsolute(io, outside_path, link_path, .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    const sources = [_]Source{.{ .root = root, .scope = .project, .priority = 1 }};
    const scope_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const catalog = try build(std.testing.allocator, io, scope_id, "epoch", &sources, .{});
    defer catalog.deinit();
    try std.testing.expectEqual(Health.degraded, catalog.health);
    try std.testing.expectEqual(@as(usize, 0), catalog.skills.len);
    try std.testing.expectEqual(IssueCode.invalid_resource, catalog.issues[0].code);
}
