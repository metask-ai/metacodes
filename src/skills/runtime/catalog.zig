//! Canonical immutable Skill catalog snapshot shared by product adapters.

const std = @import("std");
const builtin = @import("builtin");
const definition_mod = @import("definition.zig");
const util_json = @import("../../util/json.zig");

const Dir = std.Io.Dir;
const File = std.Io.File;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Limits = struct {
    max_slots: usize = 1024,
    max_descriptor_bytes: usize = 4 * 1024 * 1024,
    max_visited_entries: usize = 65536,
    max_depth: usize = 64,
    max_relative_path_bytes: usize = 4096,
    max_skill_entries: usize = 4096,
    max_skill_files: usize = 1024,
    max_skill_content_bytes: usize = 32 * 1024 * 1024,
    max_file_content_bytes: usize = 16 * 1024 * 1024,
    max_catalog_files: usize = 16384,
    max_catalog_content_bytes: usize = 64 * 1024 * 1024,
};

pub const SourceScope = enum {
    enterprise,
    personal,
    project,
    plugin,
};

pub const DEFAULT_PROVIDER_ID = "agents.directory";

/// Higher numeric priority wins. Equal-priority candidates for the same
/// invocation name are a conflict, independent of source enumeration order.
pub const Source = struct {
    root: []const u8,
    scope: SourceScope,
    priority: u32,
    namespace: []const u8 = "",
    /// Logical parser/provider identity. This is metadata only; the shared
    /// catalog keeps owning canonical parsing and resolution.
    provider_id: []const u8 = DEFAULT_PROVIDER_ID,
    /// Stable opaque identity for this configured source. Empty keeps legacy
    /// in-process callers working and derives an identity from the root.
    source_instance_id: []const u8 = "",
};

/// Built-in product source order. AgentCore deliberately supplies its own
/// neutral-only `.agents/skills` policy to the shared engine.
pub fn defaultSources(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    workspace_home: []const u8,
) error{OutOfMemory}![]const Source {
    var sources: std.ArrayList(Source) = .empty;
    const enterprise = "/etc/metacodes/skills";
    if (std.fs.path.isAbsolute(enterprise)) {
        try sources.append(arena, .{
            .root = enterprise,
            .scope = .enterprise,
            .priority = 100,
        });
    }
    try appendDefaultSource(arena, &sources, workspace_home, &.{ ".claude", "skills" }, .personal, 200);
    try appendDefaultSource(arena, &sources, workspace_home, &.{ ".metacodes", "skills" }, .personal, 201);
    try appendDefaultSource(arena, &sources, workspace_home, &.{ ".agents", "skills" }, .personal, 202);
    try appendDefaultSource(arena, &sources, workspace_root, &.{ ".claude", "skills" }, .project, 300);
    try appendDefaultSource(arena, &sources, workspace_root, &.{ ".metacodes", "skills" }, .project, 301);
    try appendDefaultSource(arena, &sources, workspace_root, &.{ ".agents", "skills" }, .project, 302);
    return sources.toOwnedSlice(arena);
}

fn appendDefaultSource(
    arena: std.mem.Allocator,
    sources: *std.ArrayList(Source),
    base: []const u8,
    suffix: []const []const u8,
    scope: SourceScope,
    priority: u32,
) error{OutOfMemory}!void {
    if (base.len == 0) return;
    const parts = try arena.alloc([]const u8, suffix.len + 1);
    parts[0] = base;
    @memcpy(parts[1..], suffix);
    try sources.append(arena, .{
        .root = try std.fs.path.join(arena, parts),
        .scope = scope,
        .priority = priority,
    });
}

pub const IssueCode = enum {
    invalid_definition,
    source_conflict,
    invalid_resource,
    invalid_invocation_name,
};

pub const ResourceReason = enum {
    file_too_large,
    skill_too_large,
    too_many_files,
    too_many_entries,
    directory_too_deep,
    path_too_long,
    unsupported_entry,
    resource_unavailable,
    resource_changed,
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
    /// Internal logical lookup ID retained for shared Runtime callers.
    skill_id: [64]u8,
    invocation_name: []const u8,
    provider_id: []const u8 = DEFAULT_PROVIDER_ID,
    source_scope: SourceScope = .project,
    source_instance_id: []const u8 = "",
    contribution_id: [64]u8 = [_]u8{'0'} ** 64,
    content_revision: [64]u8 = [_]u8{'0'} ** 64,
    /// Concrete source+content identity exposed by AgentCore.
    execution_id: [64]u8 = [_]u8{'0'} ** 64,
    definition: definition_mod.Skill,
    directories: []const []const u8,
    files: []const FileRecord,
};

pub const Issue = struct {
    code: IssueCode,
    /// Present exactly when `code == .invalid_resource`.
    reason: ?ResourceReason,
    invocation_name: ?[]const u8,
    source_scope: SourceScope,
    provider_id: []const u8 = DEFAULT_PROVIDER_ID,
    source_instance_id: []const u8 = "",
    /// Internal-only stable identity for revision hashing and ordering. This
    /// preserves evidence for invalid raw names without exposing those names.
    revision_key: []const u8,
};

pub const BuildError = error{
    OutOfMemory,
    ResourceLimit,
    CatalogInvalid,
    CatalogIncomplete,
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
    content_bytes: usize,
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

    pub fn findByExecutionId(self: *const Snapshot, id: []const u8) ?*const SkillRecord {
        if (id.len != 64) return null;
        for (self.skills) |*skill| {
            if (std.mem.eql(u8, &skill.execution_id, id)) return skill;
        }
        return null;
    }
};

const Candidate = struct {
    root: []const u8,
    dir_name: []const u8,
    invocation_name: []const u8,
    scope: SourceScope,
    provider_id: []const u8 = DEFAULT_PROVIDER_ID,
    source_instance_id: []const u8 = "",
    priority: u32,
    state: State,

    const State = union(enum) {
        ready,
        invalid_resource: ResourceReason,
    };
};

const EntryCopy = struct {
    name: []const u8,
    kind: File.Kind,
    relative_path_len: usize,
};

const WorkBudget = struct {
    visited_entries: usize = 0,
};

const CandidateUsage = struct {
    entries: usize = 0,
    file_count: usize = 0,
    content_bytes: usize = 0,
};

const CatalogUsage = struct {
    file_count: usize = 0,
    content_bytes: usize = 0,
};

const LocalError = error{
    OutOfMemory,
    ResourceLimit,
    CatalogInvalid,
    InvalidDefinition,
    FileTooLarge,
    SkillTooLarge,
    TooManyFiles,
    TooManyEntries,
    DirectoryTooDeep,
    PathTooLong,
    UnsupportedEntry,
    ResourceUnavailable,
    ResourceChanged,
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
        .content_bytes = 0,
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
    var work_budget = WorkBudget{};
    var catalog_usage = CatalogUsage{};

    for (sources) |source| {
        try enumerateSource(scratch, io, source, limits, &work_budget, &candidates, &issues);
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
                .reason = null,
                .invocation_name = invocation_name,
                .source_scope = group[0].scope,
                .provider_id = group[0].provider_id,
                .source_instance_id = group[0].source_instance_id,
                .revision_key = invocation_name,
            });
            continue;
        }

        const selected = group[0];
        switch (selected.state) {
            .ready => {},
            .invalid_resource => |reason| {
                try issues.append(scratch, .{
                    .code = .invalid_resource,
                    .reason = reason,
                    .invocation_name = invocation_name,
                    .source_scope = selected.scope,
                    .provider_id = selected.provider_id,
                    .source_instance_id = selected.source_instance_id,
                    .revision_key = invocation_name,
                });
                continue;
            },
        }
        const record = snapshotCandidate(
            arena,
            owner_allocator,
            io,
            selected,
            limits,
            &work_budget,
            &catalog_usage,
        ) catch |err| {
            if (resourceReasonFromError(err)) |reason| {
                try issues.append(scratch, .{
                    .code = .invalid_resource,
                    .reason = reason,
                    .invocation_name = invocation_name,
                    .source_scope = selected.scope,
                    .provider_id = selected.provider_id,
                    .source_instance_id = selected.source_instance_id,
                    .revision_key = invocation_name,
                });
                continue;
            }
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ResourceLimit => return error.ResourceLimit,
                error.CatalogInvalid => return error.CatalogInvalid,
                error.InvalidDefinition => {
                    try issues.append(scratch, .{
                        .code = .invalid_definition,
                        .reason = null,
                        .invocation_name = invocation_name,
                        .source_scope = selected.scope,
                        .provider_id = selected.provider_id,
                        .source_instance_id = selected.source_instance_id,
                        .revision_key = invocation_name,
                    });
                    continue;
                },
                else => unreachable,
            }
        };
        try records.append(arena, record);
    }

    std.mem.sort(SkillRecord, records.items, {}, recordLessThan);
    std.mem.sort(Issue, issues.items, {}, issueLessThan);
    try validateUniqueSkillIds(scratch, records.items);
    snapshot.skills = records.toOwnedSlice(arena) catch return error.OutOfMemory;
    snapshot.issues = cloneIssues(arena, issues.items) catch return error.OutOfMemory;
    snapshot.content_bytes = catalog_usage.content_bytes;
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
    work_budget: *WorkBudget,
    candidates: *std.ArrayList(Candidate),
    issues: *std.ArrayList(Issue),
) BuildError!void {
    if (source.root.len == 0 or !std.fs.path.isAbsolute(source.root)) return error.CatalogInvalid;
    if (source.namespace.len > 128 or source.provider_id.len == 0 or
        source.provider_id.len > 128 or source.source_instance_id.len > 128)
        return error.ResourceLimit;
    var root = Dir.openDirAbsolute(io, source.root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return error.CatalogIncomplete,
    };
    defer root.close(io);
    const before = root.stat(io) catch return error.CatalogIncomplete;
    if (before.kind != .directory) return error.CatalogIncomplete;

    var iterator = root.iterate();
    while (iterator.next(io) catch return error.CatalogIncomplete) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        try chargeWork(work_budget, limits);

        const kind = if (entry.kind == .unknown)
            (root.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| {
                try appendCandidate(
                    arena,
                    source,
                    entry.name,
                    .{ .invalid_resource = discoveryFailureReason(err) },
                    candidates,
                    issues,
                );
                continue;
            }).kind
        else
            entry.kind;
        if (kind != .directory) continue;

        // A discovery-root entry is a Skill candidate only when its directory
        // contains a stable no-follow SKILL.md file. A stable ordinary
        // directory is ignored; an entry that cannot be proven ordinary is a
        // failed candidate so it remains in priority/no-fallback selection.
        const state = probeCandidateDirectory(io, root, entry.name) orelse continue;
        try appendCandidate(arena, source, entry.name, state, candidates, issues);
    }
    const after = root.stat(io) catch return error.CatalogIncomplete;
    if (!sameDirectoryState(before, after)) return error.CatalogIncomplete;
}

fn appendCandidate(
    arena: std.mem.Allocator,
    source: Source,
    dir_name: []const u8,
    state: Candidate.State,
    candidates: *std.ArrayList(Candidate),
    issues: *std.ArrayList(Issue),
) BuildError!void {
    const invocation = makeInvocationName(arena, source.namespace, dir_name) catch
        return error.OutOfMemory;
    if (!validInvocationName(invocation)) {
        const raw_name_hash = hashHex(invocation);
        try issues.append(arena, .{
            .code = .invalid_invocation_name,
            .reason = null,
            .invocation_name = null,
            .source_scope = source.scope,
            .provider_id = source.provider_id,
            .source_instance_id = try sourceInstanceId(arena, source),
            .revision_key = try arena.dupe(u8, &raw_name_hash),
        });
        return;
    }
    try candidates.append(arena, .{
        // Sources are borrowed for the synchronous duration of `build`.
        .root = source.root,
        .dir_name = try arena.dupe(u8, dir_name),
        .invocation_name = invocation,
        .scope = source.scope,
        .provider_id = source.provider_id,
        .source_instance_id = try sourceInstanceId(arena, source),
        .priority = source.priority,
        .state = state,
    });
}

fn sourceInstanceId(arena: std.mem.Allocator, source: Source) error{OutOfMemory}![]const u8 {
    if (source.source_instance_id.len != 0)
        return arena.dupe(u8, source.source_instance_id);
    const derived = hashHex(source.root);
    return arena.dupe(u8, &derived);
}

fn probeCandidateDirectory(
    io: std.Io,
    root: Dir,
    dir_name: []const u8,
) ?Candidate.State {
    var candidate_dir = root.openDir(io, dir_name, .{
        .follow_symlinks = false,
    }) catch |err| return .{ .invalid_resource = discoveryFailureReason(err) };
    defer candidate_dir.close(io);
    const candidate_before = candidate_dir.stat(io) catch |err|
        return .{ .invalid_resource = discoveryFailureReason(err) };
    if (candidate_before.kind != .directory)
        return .{ .invalid_resource = .resource_changed };

    const definition = candidate_dir.statFile(io, "SKILL.md", .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return .{ .invalid_resource = discoveryFailureReason(err) },
    };
    const candidate_after = candidate_dir.stat(io) catch |err|
        return .{ .invalid_resource = discoveryFailureReason(err) };
    if (!sameDirectoryState(candidate_before, candidate_after))
        return .{ .invalid_resource = .resource_changed };
    const definition_stat = definition orelse return null;
    if (definition_stat.kind != .file)
        return .{ .invalid_resource = .unsupported_entry };
    return .ready;
}

fn discoveryFailureReason(err: anyerror) ResourceReason {
    return if (err == error.FileNotFound)
        .resource_changed
    else
        .resource_unavailable;
}

fn chargeWork(
    budget: *WorkBudget,
    limits: Limits,
) error{ResourceLimit}!void {
    budget.visited_entries = std.math.add(usize, budget.visited_entries, 1) catch
        return error.ResourceLimit;
    if (budget.visited_entries > limits.max_visited_entries)
        return error.ResourceLimit;
}

fn checkedRelativePathLength(
    prefix: []const u8,
    name: []const u8,
    limits: Limits,
) error{ PathTooLong, UnsupportedEntry }!usize {
    if (name.len == 0 or
        std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, "..") or
        !std.unicode.utf8ValidateSlice(name))
        return error.UnsupportedEntry;
    const length = if (prefix.len == 0)
        name.len
    else blk: {
        const with_separator = std.math.add(usize, prefix.len, 1) catch
            return error.PathTooLong;
        break :blk std.math.add(usize, with_separator, name.len) catch
            return error.PathTooLong;
    };
    if (length > limits.max_relative_path_bytes) return error.PathTooLong;
    return length;
}

fn projectCatalogUsage(
    current: CatalogUsage,
    candidate: CandidateUsage,
    limits: Limits,
) error{ResourceLimit}!CatalogUsage {
    const file_count = std.math.add(usize, current.file_count, candidate.file_count) catch
        return error.ResourceLimit;
    if (file_count > limits.max_catalog_files) return error.ResourceLimit;
    const content_bytes = std.math.add(usize, current.content_bytes, candidate.content_bytes) catch
        return error.ResourceLimit;
    if (content_bytes > limits.max_catalog_content_bytes) return error.ResourceLimit;
    return .{
        .file_count = file_count,
        .content_bytes = content_bytes,
    };
}

fn resourceReasonFromError(err: LocalError) ?ResourceReason {
    return switch (err) {
        error.FileTooLarge => .file_too_large,
        error.SkillTooLarge => .skill_too_large,
        error.TooManyFiles => .too_many_files,
        error.TooManyEntries => .too_many_entries,
        error.DirectoryTooDeep => .directory_too_deep,
        error.PathTooLong => .path_too_long,
        error.UnsupportedEntry => .unsupported_entry,
        error.ResourceUnavailable => .resource_unavailable,
        error.ResourceChanged => .resource_changed,
        error.OutOfMemory,
        error.ResourceLimit,
        error.CatalogInvalid,
        error.InvalidDefinition,
        => null,
    };
}

fn snapshotCandidate(
    destination: std.mem.Allocator,
    temporary_allocator: std.mem.Allocator,
    io: std.Io,
    candidate: Candidate,
    limits: Limits,
    work_budget: *WorkBudget,
    catalog_usage: *CatalogUsage,
) LocalError!SkillRecord {
    var temporary = std.heap.ArenaAllocator.init(temporary_allocator);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    var candidate_usage = CandidateUsage{};

    const record = try snapshotCandidateTemporary(
        scratch,
        io,
        candidate,
        limits,
        work_budget,
        &candidate_usage,
    );
    const admitted_usage = try projectCatalogUsage(catalog_usage.*, candidate_usage, limits);
    const cloned = try cloneSkillRecord(destination, record);
    catalog_usage.* = admitted_usage;
    return cloned;
}

fn snapshotCandidateTemporary(
    arena: std.mem.Allocator,
    io: std.Io,
    candidate: Candidate,
    limits: Limits,
    work_budget: *WorkBudget,
    candidate_usage: *CandidateUsage,
) LocalError!SkillRecord {
    var root = Dir.openDirAbsolute(io, candidate.root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return error.ResourceUnavailable;
    defer root.close(io);
    var skill_dir = root.openDir(io, candidate.dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return error.ResourceUnavailable;
    defer skill_dir.close(io);

    var files: std.ArrayList(FileRecord) = .empty;
    var directories: std.ArrayList([]const u8) = .empty;
    try snapshotTree(
        arena,
        io,
        skill_dir,
        "",
        0,
        limits,
        work_budget,
        candidate_usage,
        &directories,
        &files,
    );
    std.mem.sort([]const u8, directories.items, {}, stringLessThan);
    std.mem.sort(FileRecord, files.items, {}, fileLessThan);
    const owned_directories = try directories.toOwnedSlice(arena);
    const owned_files = try files.toOwnedSlice(arena);

    var definition_bytes: ?[]const u8 = null;
    for (owned_files) |file| {
        if (std.mem.eql(u8, file.relative_path, "SKILL.md")) {
            definition_bytes = file.bytes;
            break;
        }
    }
    const md = definition_bytes orelse return error.ResourceChanged;
    if (!std.unicode.utf8ValidateSlice(md)) return error.InvalidDefinition;
    validateSkillMetadata(md) catch return error.InvalidDefinition;
    const definition = definition_mod.parseSkillMdWithFallback(
        arena,
        md,
        "",
        candidate.dir_name,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.InvalidDefinition;
    };
    if (!validArgumentNames(definition.arguments)) return error.InvalidDefinition;

    var record = SkillRecord{
        .skill_id = hashHex(candidate.invocation_name),
        .invocation_name = candidate.invocation_name,
        .provider_id = candidate.provider_id,
        .source_scope = candidate.scope,
        .source_instance_id = candidate.source_instance_id,
        .contribution_id = hashHex(candidate.dir_name),
        .definition = definition,
        .directories = owned_directories,
        .files = owned_files,
    };
    record.content_revision = computeContentRevision(&record);
    record.execution_id = computeExecutionId(&record);
    return record;
}

fn cloneSkillRecord(arena: std.mem.Allocator, source: SkillRecord) error{OutOfMemory}!SkillRecord {
    const directories = try cloneStringList(arena, source.directories);
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
        .provider_id = try arena.dupe(u8, source.provider_id),
        .source_scope = source.source_scope,
        .source_instance_id = try arena.dupe(u8, source.source_instance_id),
        .contribution_id = source.contribution_id,
        .content_revision = source.content_revision,
        .execution_id = source.execution_id,
        .definition = .{
            .name = try arena.dupe(u8, source.definition.name),
            .description = try arena.dupe(u8, source.definition.description),
            .body = try arena.dupe(u8, source.definition.body),
            .allowed_tools = try cloneStringList(arena, source.definition.allowed_tools),
            .disallowed_tools = try cloneStringList(arena, source.definition.disallowed_tools),
            .arguments = try cloneStringList(arena, source.definition.arguments),
            .disable_model_invocation = source.definition.disable_model_invocation,
            .model_activation = source.definition.model_activation,
            .context = source.definition.context,
            .agent = try arena.dupe(u8, source.definition.agent),
            .model = try arena.dupe(u8, source.definition.model),
            .shell = try arena.dupe(u8, source.definition.shell),
            .source_path = "",
        },
        .directories = directories,
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
            .reason = issue.reason,
            .invocation_name = if (issue.invocation_name) |name|
                try arena.dupe(u8, name)
            else
                null,
            .source_scope = issue.source_scope,
            .provider_id = try arena.dupe(u8, issue.provider_id),
            .source_instance_id = try arena.dupe(u8, issue.source_instance_id),
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
    work_budget: *WorkBudget,
    candidate_usage: *CandidateUsage,
    directories: *std.ArrayList([]const u8),
    files: *std.ArrayList(FileRecord),
) LocalError!void {
    if (depth > limits.max_depth) return error.DirectoryTooDeep;
    const before = dir.stat(io) catch return error.ResourceUnavailable;
    if (before.kind != .directory) return error.UnsupportedEntry;
    var entries: std.ArrayList(EntryCopy) = .empty;
    var iterator = dir.iterate();
    while (iterator.next(io) catch return error.ResourceUnavailable) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        try chargeWork(work_budget, limits);
        candidate_usage.entries = std.math.add(usize, candidate_usage.entries, 1) catch
            return error.TooManyEntries;
        if (candidate_usage.entries > limits.max_skill_entries)
            return error.TooManyEntries;
        const relative_path_len = try checkedRelativePathLength(prefix, entry.name, limits);
        try entries.append(arena, .{
            .name = try arena.dupe(u8, entry.name),
            .kind = entry.kind,
            .relative_path_len = relative_path_len,
        });
    }
    std.mem.sort(EntryCopy, entries.items, {}, entryLessThan);

    for (entries.items) |entry| {
        const relative_path = if (prefix.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });
        std.debug.assert(relative_path.len == entry.relative_path_len);

        switch (entry.kind) {
            .directory => {
                if (depth == limits.max_depth) return error.DirectoryTooDeep;
                try directories.append(arena, relative_path);
                var child = dir.openDir(io, entry.name, .{
                    .iterate = true,
                    .follow_symlinks = false,
                }) catch return error.ResourceUnavailable;
                defer child.close(io);
                try snapshotTree(
                    arena,
                    io,
                    child,
                    relative_path,
                    depth + 1,
                    limits,
                    work_budget,
                    candidate_usage,
                    directories,
                    files,
                );
            },
            .file => try snapshotFile(arena, io, dir, entry.name, relative_path, limits, candidate_usage, files),
            .sym_link => return error.UnsupportedEntry,
            .unknown => {
                const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch
                    return error.ResourceUnavailable;
                switch (stat.kind) {
                    .directory => {
                        if (depth == limits.max_depth) return error.DirectoryTooDeep;
                        try directories.append(arena, relative_path);
                        var child = dir.openDir(io, entry.name, .{
                            .iterate = true,
                            .follow_symlinks = false,
                        }) catch return error.ResourceUnavailable;
                        defer child.close(io);
                        try snapshotTree(
                            arena,
                            io,
                            child,
                            relative_path,
                            depth + 1,
                            limits,
                            work_budget,
                            candidate_usage,
                            directories,
                            files,
                        );
                    },
                    .file => try snapshotFile(arena, io, dir, entry.name, relative_path, limits, candidate_usage, files),
                    else => return error.UnsupportedEntry,
                }
            },
            else => return error.UnsupportedEntry,
        }
    }
    const after = dir.stat(io) catch return error.ResourceUnavailable;
    if (!sameDirectoryState(before, after)) return error.ResourceChanged;
}

fn snapshotFile(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: Dir,
    name: []const u8,
    relative_path: []const u8,
    limits: Limits,
    candidate_usage: *CandidateUsage,
    files: *std.ArrayList(FileRecord),
) LocalError!void {
    var file = dir.openFile(io, name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch return error.ResourceUnavailable;
    defer file.close(io);
    // Zig 0.16's Windows Threaded backend opens no-follow files with
    // `IO.ASYNCHRONOUS` but currently returns `nonblocking=false`. Correct the
    // local value so positional reads wait for PENDING completion instead of
    // treating it as an impossible synchronous result.
    if (builtin.os.tag == .windows) file.flags.nonblocking = true;
    const before = file.stat(io) catch return error.ResourceUnavailable;
    if (before.kind != .file) return error.UnsupportedEntry;
    if (before.size > limits.max_file_content_bytes) return error.FileTooLarge;
    const size = std.math.cast(usize, before.size) orelse return error.FileTooLarge;
    candidate_usage.file_count = std.math.add(usize, candidate_usage.file_count, 1) catch
        return error.TooManyFiles;
    if (candidate_usage.file_count > limits.max_skill_files) return error.TooManyFiles;
    candidate_usage.content_bytes = std.math.add(usize, candidate_usage.content_bytes, size) catch
        return error.SkillTooLarge;
    if (candidate_usage.content_bytes > limits.max_skill_content_bytes)
        return error.SkillTooLarge;

    var read_buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const read_limit = std.math.add(usize, limits.max_file_content_bytes, 1) catch
        return error.ResourceLimit;
    const bytes = reader.interface.allocRemaining(arena, .limited(read_limit)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.ResourceChanged,
        else => return error.ResourceUnavailable,
    };
    if (bytes.len != size) return error.ResourceChanged;
    const after = file.stat(io) catch return error.ResourceUnavailable;
    if (after.size != before.size or
        after.mtime.nanoseconds != before.mtime.nanoseconds or
        after.ctime.nanoseconds != before.ctime.nanoseconds)
        return error.ResourceChanged;

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
    // Count the exact escaped JSON size before allocating the public buffer.
    // Descriptor caps therefore apply before output allocation, not after a
    // potentially unbounded `valueAlloc`.
    var count_buffer: [256]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&count_buffer);
    try writeDescriptor(&discarding.writer, snapshot);
    const encoded_len_u64 = discarding.fullCount();
    if (encoded_len_u64 > max_bytes or encoded_len_u64 > std.math.maxInt(usize))
        return error.ResourceLimit;
    const encoded_len: usize = @intCast(encoded_len_u64);

    var allocating = try std.Io.Writer.Allocating.initCapacity(arena, encoded_len);
    defer allocating.deinit();
    try writeDescriptor(&allocating.writer, snapshot);
    const encoded = try allocating.toOwnedSlice();
    std.debug.assert(encoded.len == encoded_len);
    return encoded;
}

fn writeDescriptor(writer: *std.Io.Writer, snapshot: *const Snapshot) !void {
    try writer.writeAll("{\"schema\":\"metask.skill-catalog/v1\",\"catalog_scope_id\":");
    try util_json.writeJsonString(writer, &snapshot.scope_id);
    try writer.writeAll(",\"catalog_revision\":");
    try util_json.writeJsonString(writer, &snapshot.revision);
    try writer.writeAll(",\"health\":");
    try util_json.writeJsonString(writer, @tagName(snapshot.health));
    try writer.writeAll(",\"skills\":[");
    for (snapshot.skills, 0..) |*record, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"skill_id\":");
        try util_json.writeJsonString(writer, &record.execution_id);
        try writer.writeAll(",\"skill_policy_key\":");
        try util_json.writeJsonString(writer, record.invocation_name);
        try writer.writeAll(",\"invocation_name\":");
        try util_json.writeJsonString(writer, record.invocation_name);
        try writer.writeAll(",\"source\":{\"provider_id\":");
        try util_json.writeJsonString(writer, record.provider_id);
        try writer.writeAll(",\"source_scope\":");
        try util_json.writeJsonString(writer, publicScope(record.source_scope));
        try writer.writeAll(",\"source_instance_id\":");
        try util_json.writeJsonString(writer, record.source_instance_id);
        try writer.writeAll(",\"contribution_id\":");
        try util_json.writeJsonString(writer, &record.contribution_id);
        try writer.writeAll("},\"content_revision\":");
        try util_json.writeJsonString(writer, &record.content_revision);
        try writer.writeAll(",\"display_name\":");
        try util_json.writeJsonString(writer, record.definition.name);
        try writer.writeAll(",\"description\":");
        try util_json.writeJsonString(writer, record.definition.description);
        try writer.writeAll(
            ",\"argument_schema\":{\"schema\":\"metask.skill-arguments/v1\",\"max_values\":64,\"names\":[",
        );
        for (record.definition.arguments, 0..) |name, name_index| {
            if (name_index != 0) try writer.writeByte(',');
            try util_json.writeJsonString(writer, name);
        }
        try writer.writeAll("]}}");
    }
    try writer.writeAll("],\"issues\":[");
    for (snapshot.issues, 0..) |*issue, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"kind\":");
        try util_json.writeJsonString(writer, issueKind(issue));
        try writer.writeAll(",\"code\":");
        try util_json.writeJsonString(writer, @tagName(issue.code));
        try writer.writeAll(",\"skill_policy_key\":");
        if (issue.invocation_name) |name|
            try util_json.writeJsonString(writer, name)
        else
            try writer.writeAll("null");
        try writer.writeAll(",\"reason\":");
        if (issue.reason) |reason|
            try util_json.writeJsonString(writer, @tagName(reason))
        else
            try writer.writeAll("null");
        try writer.writeAll(",\"source_scope\":");
        try util_json.writeJsonString(writer, publicScope(issue.source_scope));
        try writer.writeAll(",\"provider_id\":");
        try util_json.writeJsonString(writer, issue.provider_id);
        try writer.writeAll(",\"source_instance_id\":");
        try util_json.writeJsonString(writer, issue.source_instance_id);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

fn issueKind(issue: *const Issue) []const u8 {
    return switch (issue.code) {
        .source_conflict => "conflict",
        .invalid_resource => switch (issue.reason.?) {
            .resource_unavailable, .resource_changed => "unavailable",
            else => "invalid",
        },
        .invalid_definition, .invalid_invocation_name => "invalid",
    };
}

fn validateUniqueSkillIds(
    allocator: std.mem.Allocator,
    records: []const SkillRecord,
) BuildError!void {
    var seen = std.AutoHashMap([64]u8, void).init(allocator);
    defer seen.deinit();
    for (records) |record| {
        const entry = seen.getOrPut(record.skill_id) catch return error.OutOfMemory;
        if (entry.found_existing) return error.CatalogInvalid;
    }
    seen.clearRetainingCapacity();
    for (records) |record| {
        const entry = seen.getOrPut(record.execution_id) catch return error.OutOfMemory;
        if (entry.found_existing) return error.CatalogInvalid;
    }
}

fn computeContentRevision(record: *const SkillRecord) [64]u8 {
    var hash = Sha256.init(.{});
    hashField(&hash, record.definition.name);
    hashField(&hash, record.definition.description);
    hashField(&hash, record.definition.body);
    hashField(&hash, @tagName(record.definition.context));
    hashField(&hash, record.definition.agent);
    hashField(&hash, record.definition.model);
    hashField(&hash, record.definition.shell);
    hashU64(&hash, @intFromBool(record.definition.disable_model_invocation));
    hashField(&hash, @tagName(record.definition.model_activation));
    for (record.definition.arguments) |value| hashField(&hash, value);
    for (record.definition.allowed_tools) |value| hashField(&hash, value);
    for (record.definition.disallowed_tools) |value| hashField(&hash, value);
    for (record.directories) |directory| hashField(&hash, directory);
    for (record.files) |file| {
        hashField(&hash, file.relative_path);
        hashU64(&hash, @intFromBool(file.executable));
        hashField(&hash, file.bytes);
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn computeExecutionId(record: *const SkillRecord) [64]u8 {
    var hash = Sha256.init(.{});
    hashField(&hash, "agentcore-skill-execution/v1");
    hashField(&hash, record.provider_id);
    hashField(&hash, publicScope(record.source_scope));
    hashField(&hash, record.source_instance_id);
    hashField(&hash, &record.contribution_id);
    hashField(&hash, &record.content_revision);
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn publicScope(scope: SourceScope) []const u8 {
    return switch (scope) {
        .personal => "user",
        .project => "workspace",
        .enterprise => "enterprise",
        .plugin => "plugin",
    };
}

fn computeRevision(snapshot: *const Snapshot, workspace_epoch: []const u8) [64]u8 {
    var hash = Sha256.init(.{});
    hashField(&hash, &snapshot.scope_id);
    hashField(&hash, workspace_epoch);
    for (snapshot.skills) |record| {
        hashField(&hash, "skill");
        hashField(&hash, record.provider_id);
        hashField(&hash, publicScope(record.source_scope));
        hashField(&hash, record.source_instance_id);
        hashField(&hash, &record.contribution_id);
        hashField(&hash, &record.content_revision);
        hashField(&hash, &record.execution_id);
        hashField(&hash, record.invocation_name);
        hashField(&hash, record.definition.name);
        hashField(&hash, record.definition.description);
        hashField(&hash, record.definition.body);
        hashField(&hash, @tagName(record.definition.context));
        hashField(&hash, record.definition.agent);
        hashField(&hash, record.definition.model);
        hashField(&hash, record.definition.shell);
        hashU64(&hash, @intFromBool(record.definition.disable_model_invocation));
        hashField(&hash, @tagName(record.definition.model_activation));
        for (record.definition.arguments) |value| hashField(&hash, value);
        for (record.definition.allowed_tools) |value| hashField(&hash, value);
        for (record.definition.disallowed_tools) |value| hashField(&hash, value);
        for (record.directories) |directory| {
            hashField(&hash, "directory");
            hashField(&hash, directory);
        }
        for (record.files) |file| {
            hashField(&hash, file.relative_path);
            hashU64(&hash, @intFromBool(file.executable));
            hashField(&hash, file.bytes);
        }
    }
    for (snapshot.issues) |issue| {
        hashField(&hash, "issue");
        hashField(&hash, @tagName(issue.code));
        hashField(&hash, if (issue.reason) |reason| @tagName(reason) else "");
        hashField(&hash, issue.revision_key);
        hashField(&hash, @tagName(issue.source_scope));
        hashField(&hash, issue.provider_id);
        hashField(&hash, issue.source_instance_id);
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
        } else if (std.mem.eql(u8, key, "model-activation") or
            std.mem.eql(u8, key, "model_activation"))
        {
            if (!std.mem.eql(u8, value, "advisory") and
                !std.mem.eql(u8, value, "required-first") and
                !std.mem.eql(u8, value, "required_first"))
                return error.InvalidDefinition;
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
    const lhs_reason = if (lhs.reason) |reason| @tagName(reason) else "";
    const rhs_reason = if (rhs.reason) |reason| @tagName(reason) else "";
    const by_reason = std.mem.order(u8, lhs_reason, rhs_reason);
    if (by_reason != .eq) return by_reason == .lt;
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

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn createTestDir(
    arena: std.mem.Allocator,
    io: std.Io,
    parts: []const []const u8,
) !void {
    try Dir.cwd().createDirPath(io, try std.fs.path.join(arena, parts));
}

fn writeTestFile(
    arena: std.mem.Allocator,
    io: std.Io,
    parts: []const []const u8,
    data: []const u8,
) !void {
    const path = try std.fs.path.join(arena, parts);
    if (std.fs.path.dirname(path)) |parent| try Dir.cwd().createDirPath(io, parent);
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
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

test "product default sources preserve product-owned directory policy" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const workspace_root = try std.fs.path.join(a, &.{ root_buffer[0..root_len], "workspace" });
    const workspace_home = try std.fs.path.join(a, &.{ root_buffer[0..root_len], "home" });

    const sources = try defaultSources(a, workspace_root, workspace_home);
    const has_enterprise: usize = @intFromBool(std.fs.path.isAbsolute("/etc/metacodes/skills"));
    try std.testing.expectEqual(6 + has_enterprise, sources.len);
    if (has_enterprise == 1) {
        try std.testing.expectEqualStrings("/etc/metacodes/skills", sources[0].root);
        try std.testing.expectEqual(SourceScope.enterprise, sources[0].scope);
        try std.testing.expectEqual(@as(u32, 100), sources[0].priority);
    }

    const expected = [_]Source{
        .{ .root = try std.fs.path.join(a, &.{ workspace_home, ".claude", "skills" }), .scope = .personal, .priority = 200 },
        .{ .root = try std.fs.path.join(a, &.{ workspace_home, ".metacodes", "skills" }), .scope = .personal, .priority = 201 },
        .{ .root = try std.fs.path.join(a, &.{ workspace_home, ".agents", "skills" }), .scope = .personal, .priority = 202 },
        .{ .root = try std.fs.path.join(a, &.{ workspace_root, ".claude", "skills" }), .scope = .project, .priority = 300 },
        .{ .root = try std.fs.path.join(a, &.{ workspace_root, ".metacodes", "skills" }), .scope = .project, .priority = 301 },
        .{ .root = try std.fs.path.join(a, &.{ workspace_root, ".agents", "skills" }), .scope = .project, .priority = 302 },
    };
    for (expected, 0..) |want, index| {
        const got = sources[has_enterprise + index];
        try std.testing.expectEqualStrings(want.root, got.root);
        try std.testing.expectEqual(want.scope, got.scope);
        try std.testing.expectEqual(want.priority, got.priority);
        try std.testing.expectEqualStrings("", got.namespace);
    }
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
    try std.testing.expectEqual(@as(usize, 1), first.skills[0].directories.len);
    try std.testing.expectEqualStrings("resources", first.skills[0].directories[0]);
    try std.testing.expect(first.skills[0].files.len == 2);
    try std.testing.expectEqualSlices(u8, &first.revision, &second.revision);
    try std.testing.expectEqualStrings(first.descriptor_json, second.descriptor_json);
    try std.testing.expect(std.mem.indexOf(u8, first.descriptor_json, "source_path") == null);
    try std.testing.expect(std.mem.indexOf(u8, first.descriptor_json, "\"body\"") == null);

    var parsed = try definition_mod.parseSkillMdWithFallback(std.testing.allocator, high_md, "", "review");
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

test "catalog descriptor preserves each Skill identity across multiple records" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    const review_dir = try std.fs.path.join(allocator, &.{ root, "review" });
    defer allocator.free(review_dir);
    const workctl_dir = try std.fs.path.join(allocator, &.{ root, "workctl" });
    defer allocator.free(workctl_dir);
    try Dir.cwd().createDirPath(io, review_dir);
    try Dir.cwd().createDirPath(io, workctl_dir);

    const review_path = try std.fs.path.join(allocator, &.{ review_dir, "SKILL.md" });
    defer allocator.free(review_path);
    const workctl_path = try std.fs.path.join(allocator, &.{ workctl_dir, "SKILL.md" });
    defer allocator.free(workctl_path);
    try Dir.cwd().writeFile(io, .{
        .sub_path = review_path,
        .data = "---\nname: Review\ndescription: Review code\n---\nReview the target.",
    });
    try Dir.cwd().writeFile(io, .{
        .sub_path = workctl_path,
        .data = "---\nname: Workctl\ndescription: Operate Work Agent\n---\nOperate the requested resource.",
    });

    const sources = [_]Source{
        .{ .root = root, .scope = .project, .priority = 1 },
    };
    const scope_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const snapshot = try build(allocator, io, scope_id, "epoch-1", &sources, .{});
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 2), snapshot.skills.len);

    const PublicSkill = struct {
        skill_id: []const u8,
        skill_policy_key: []const u8,
        invocation_name: []const u8,
        content_revision: []const u8,
    };
    const PublicCatalog = struct {
        skills: []const PublicSkill,
    };
    var parsed = try std.json.parseFromSlice(
        PublicCatalog,
        allocator,
        snapshot.descriptor_json,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(snapshot.skills.len, parsed.value.skills.len);

    for (parsed.value.skills) |skill| {
        const logical_id = hashHex(skill.invocation_name);
        const record = snapshot.findById(&logical_id) orelse
            return error.SkillMissingFromSnapshot;
        try std.testing.expectEqualStrings(skill.invocation_name, skill.skill_policy_key);
        try std.testing.expectEqualStrings(&record.execution_id, skill.skill_id);
        try std.testing.expectEqualStrings(&record.content_revision, skill.content_revision);
    }
    try std.testing.expect(!std.mem.eql(
        u8,
        parsed.value.skills[0].skill_id,
        parsed.value.skills[1].skill_id,
    ));
}

test "catalog identity validation rejects duplicates and preserves allocation failure" {
    const definition = definition_mod.Skill{
        .name = "",
        .description = "",
        .body = "",
        .allowed_tools = &.{},
        .disallowed_tools = &.{},
        .arguments = &.{},
        .disable_model_invocation = false,
        .context = .inline_ctx,
        .agent = "",
        .model = "",
        .shell = "",
        .source_path = "",
    };
    const records = [_]SkillRecord{
        .{
            .skill_id = [_]u8{'a'} ** 64,
            .invocation_name = "review",
            .definition = definition,
            .directories = &.{},
            .files = &.{},
        },
        .{
            .skill_id = [_]u8{'a'} ** 64,
            .invocation_name = "workctl",
            .definition = definition,
            .directories = &.{},
            .files = &.{},
        },
    };
    try std.testing.expectError(
        error.CatalogInvalid,
        validateUniqueSkillIds(std.testing.allocator, &records),
    );

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        validateUniqueSkillIds(failing.allocator(), records[0..1]),
    );
}

test "candidate resource limits degrade while catalog limits fail the whole query" {
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
    const degraded = try build(
        std.testing.allocator,
        io,
        scope_id,
        "epoch",
        &sources,
        .{ .max_file_content_bytes = 1 },
    );
    defer degraded.deinit();
    try std.testing.expectEqual(Health.degraded, degraded.health);
    try std.testing.expectEqual(@as(usize, 0), degraded.skills.len);
    try std.testing.expectEqual(@as(usize, 1), degraded.issues.len);
    try std.testing.expectEqual(IssueCode.invalid_resource, degraded.issues[0].code);
    try std.testing.expectEqual(ResourceReason.file_too_large, degraded.issues[0].reason.?);
    try std.testing.expectError(
        error.ResourceLimit,
        build(std.testing.allocator, io, scope_id, "epoch", &sources, .{ .max_catalog_content_bytes = 1 }),
    );
    try std.testing.expectError(
        error.ResourceLimit,
        build(std.testing.allocator, io, scope_id, "epoch", &sources, .{ .max_descriptor_bytes = 1 }),
    );
}

test "one oversized Skill does not poison siblings in the same source" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    const a_md = "---\nname: A\n---\na";
    const b_md = "---\nname: B\n---\nb";
    const c_md = "---\nname: C\n---\nc";
    inline for (.{ .{ "a", a_md }, .{ "b", b_md }, .{ "c", c_md } }) |fixture| {
        const skill_dir = try std.fs.path.join(allocator, &.{ root, fixture[0] });
        defer allocator.free(skill_dir);
        try Dir.cwd().createDirPath(io, skill_dir);
        const md_path = try std.fs.path.join(allocator, &.{ skill_dir, "SKILL.md" });
        defer allocator.free(md_path);
        try Dir.cwd().writeFile(io, .{ .sub_path = md_path, .data = fixture[1] });
    }
    const oversized_path = try std.fs.path.join(allocator, &.{ root, "b", "oversized.bin" });
    defer allocator.free(oversized_path);
    try Dir.cwd().writeFile(io, .{ .sub_path = oversized_path, .data = "x" ** 65 });

    const sources = [_]Source{.{ .root = root, .scope = .project, .priority = 1 }};
    const scope_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const snapshot = try build(allocator, io, scope_id, "epoch", &sources, .{
        .max_file_content_bytes = 64,
        .max_skill_content_bytes = 128,
        .max_catalog_content_bytes = a_md.len + c_md.len,
    });
    defer snapshot.deinit();

    try std.testing.expectEqual(Health.degraded, snapshot.health);
    try std.testing.expectEqual(@as(usize, 2), snapshot.skills.len);
    try std.testing.expectEqualStrings("a", snapshot.skills[0].invocation_name);
    try std.testing.expectEqualStrings("c", snapshot.skills[1].invocation_name);
    try std.testing.expectEqual(a_md.len + c_md.len, snapshot.content_bytes);
    try std.testing.expectEqual(@as(usize, 1), snapshot.issues.len);
    try std.testing.expectEqualStrings("b", snapshot.issues[0].invocation_name.?);
    try std.testing.expectEqual(IssueCode.invalid_resource, snapshot.issues[0].code);
    try std.testing.expectEqual(ResourceReason.file_too_large, snapshot.issues[0].reason.?);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.descriptor_json, "\"reason\":\"file_too_large\"") != null);
}

test "per-Skill entry limit is local and checked before sibling admission" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    inline for (.{ "a", "b", "c" }) |name| {
        const skill_dir = try std.fs.path.join(allocator, &.{ root, name });
        defer allocator.free(skill_dir);
        try Dir.cwd().createDirPath(io, skill_dir);
        const md_path = try std.fs.path.join(allocator, &.{ skill_dir, "SKILL.md" });
        defer allocator.free(md_path);
        try Dir.cwd().writeFile(io, .{ .sub_path = md_path, .data = "---\nname: Skill\n---\nbody" });
    }
    const extra_path = try std.fs.path.join(allocator, &.{ root, "b", "extra.txt" });
    defer allocator.free(extra_path);
    try Dir.cwd().writeFile(io, .{ .sub_path = extra_path, .data = "extra" });

    const sources = [_]Source{.{ .root = root, .scope = .project, .priority = 1 }};
    const scope_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const snapshot = try build(allocator, io, scope_id, "epoch", &sources, .{
        .max_skill_entries = 1,
    });
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 2), snapshot.skills.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.issues.len);
    try std.testing.expectEqual(ResourceReason.too_many_entries, snapshot.issues[0].reason.?);
}

test "candidate discovery failure is local and does not fall back" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    var paths = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer paths.deinit();
    const a = paths.allocator();
    const low = try std.fs.path.join(a, &.{ root, "low" });
    const high = try std.fs.path.join(a, &.{ root, "high" });
    try writeTestFile(a, io, &.{ low, "review", "SKILL.md" }, "---\nname: Low Review\n---\nlow");
    try createTestDir(a, io, &.{ high, "review", "SKILL.md" });
    try writeTestFile(a, io, &.{ high, "good", "SKILL.md" }, "---\nname: Good\n---\ngood");

    const sources = [_]Source{
        .{ .root = low, .scope = .personal, .priority = 1 },
        .{ .root = high, .scope = .project, .priority = 2 },
    };
    const scope_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const snapshot = try build(std.testing.allocator, io, scope_id, "epoch", &sources, .{});
    defer snapshot.deinit();

    try std.testing.expectEqual(Health.degraded, snapshot.health);
    try std.testing.expectEqual(@as(usize, 1), snapshot.skills.len);
    try std.testing.expectEqualStrings("good", snapshot.skills[0].invocation_name);
    try std.testing.expect(snapshot.findByInvocation("review") == null);
    try std.testing.expectEqual(@as(usize, 1), snapshot.issues.len);
    try std.testing.expectEqualStrings("review", snapshot.issues[0].invocation_name.?);
    try std.testing.expectEqual(ResourceReason.unsupported_entry, snapshot.issues[0].reason.?);
    try std.testing.expectEqual(ResourceReason.resource_changed, discoveryFailureReason(error.FileNotFound));
    try std.testing.expectEqual(ResourceReason.resource_unavailable, discoveryFailureReason(error.AccessDenied));
}

test "candidate resource reasons are isolated from a valid sibling" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    var paths = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer paths.deinit();
    const a = paths.allocator();
    const skill_md = "---\nname: X\n---\nx";

    inline for (.{ "good", "file-large", "skill-large", "files-many", "deep", "path-long" }) |name| {
        try writeTestFile(a, io, &.{ root, name, "SKILL.md" }, skill_md);
    }
    try writeTestFile(a, io, &.{ root, "file-large", "asset.bin" }, "x" ** 65);
    try writeTestFile(a, io, &.{ root, "skill-large", "asset.bin" }, "x" ** 32);
    inline for (.{ "a", "b" }) |name| {
        try writeTestFile(a, io, &.{ root, "files-many", name }, "");
    }
    try createTestDir(a, io, &.{ root, "deep", "one", "two" });
    try writeTestFile(a, io, &.{ root, "path-long", "123456789012345678901" }, "");

    const sources = [_]Source{.{ .root = root, .scope = .project, .priority = 1 }};
    const scope_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const snapshot = try build(std.testing.allocator, io, scope_id, "epoch", &sources, .{
        .max_file_content_bytes = 64,
        .max_skill_content_bytes = 48,
        .max_skill_files = 2,
        .max_depth = 1,
        .max_relative_path_bytes = 20,
    });
    defer snapshot.deinit();

    try std.testing.expectEqual(Health.degraded, snapshot.health);
    try std.testing.expectEqual(@as(usize, 1), snapshot.skills.len);
    try std.testing.expectEqualStrings("good", snapshot.skills[0].invocation_name);
    const expected = [_]struct { name: []const u8, reason: ResourceReason }{
        .{ .name = "file-large", .reason = .file_too_large },
        .{ .name = "files-many", .reason = .too_many_files },
        .{ .name = "deep", .reason = .directory_too_deep },
        .{ .name = "path-long", .reason = .path_too_long },
        .{ .name = "skill-large", .reason = .skill_too_large },
    };
    try std.testing.expectEqual(expected.len, snapshot.issues.len);
    for (expected) |want| {
        var found = false;
        for (snapshot.issues) |issue| {
            if (!std.mem.eql(u8, issue.invocation_name orelse continue, want.name)) continue;
            found = true;
            try std.testing.expectEqual(want.reason, issue.reason.?);
            break;
        }
        try std.testing.expect(found);
    }
}

test "definition loss after discovery is resource_changed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try createTestDir(arena.allocator(), io, &.{ root, "review" });
    var work_budget = WorkBudget{};
    var usage = CandidateUsage{};
    try std.testing.expectError(
        error.ResourceChanged,
        snapshotCandidateTemporary(
            arena.allocator(),
            io,
            .{
                .root = root,
                .dir_name = "review",
                .invocation_name = "review",
                .scope = .project,
                .priority = 1,
                .state = .ready,
            },
            .{},
            &work_budget,
            &usage,
        ),
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
    const first_md = try std.fmt.allocPrint(std.testing.allocator, "{s}/SKILL.md", .{first_bad});
    defer std.testing.allocator.free(first_md);
    const second_md = try std.fmt.allocPrint(std.testing.allocator, "{s}/SKILL.md", .{second_bad});
    defer std.testing.allocator.free(second_md);
    try Dir.cwd().writeFile(io, .{ .sub_path = first_md, .data = "first" });
    try Dir.cwd().writeFile(io, .{ .sub_path = second_md, .data = "second" });
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

test "unrelated root entries do not degrade or perturb catalog revision" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const skill_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/review", .{root});
    defer std.testing.allocator.free(skill_dir);
    try Dir.cwd().createDirPath(io, skill_dir);
    const md_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/SKILL.md", .{skill_dir});
    defer std.testing.allocator.free(md_path);
    try Dir.cwd().writeFile(io, .{
        .sub_path = md_path,
        .data = "---\nname: Review\n---\nbody",
    });
    const sources = [_]Source{.{ .root = root, .scope = .project, .priority = 1 }};
    const scope_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const baseline = try build(std.testing.allocator, io, scope_id, "epoch", &sources, .{});
    defer baseline.deinit();

    const readme = try std.fmt.allocPrint(std.testing.allocator, "{s}/README", .{root});
    defer std.testing.allocator.free(readme);
    const dotted = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{root});
    defer std.testing.allocator.free(dotted);
    const hidden = try std.fmt.allocPrint(std.testing.allocator, "{s}/.DS_Store", .{root});
    defer std.testing.allocator.free(hidden);
    const notes = try std.fmt.allocPrint(std.testing.allocator, "{s}/notes", .{root});
    defer std.testing.allocator.free(notes);
    try Dir.cwd().writeFile(io, .{ .sub_path = readme, .data = "ordinary" });
    try Dir.cwd().writeFile(io, .{ .sub_path = dotted, .data = "ordinary" });
    try Dir.cwd().writeFile(io, .{ .sub_path = hidden, .data = "ordinary" });
    try Dir.cwd().createDirPath(io, notes);

    const with_unrelated = try build(
        std.testing.allocator,
        io,
        scope_id,
        "epoch",
        &sources,
        .{},
    );
    defer with_unrelated.deinit();
    try std.testing.expectEqual(Health.healthy, with_unrelated.health);
    try std.testing.expectEqual(@as(usize, 0), with_unrelated.issues.len);
    try std.testing.expectEqual(@as(usize, 1), with_unrelated.skills.len);
    try std.testing.expectEqualSlices(
        u8,
        &baseline.revision,
        &with_unrelated.revision,
    );
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
    try std.testing.expectEqual(ResourceReason.unsupported_entry, catalog.issues[0].reason.?);
}
