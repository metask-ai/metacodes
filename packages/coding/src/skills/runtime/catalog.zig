//! Canonical immutable Skill catalog snapshot shared by product adapters.

const std = @import("std");
const builtin = @import("builtin");
const definition_mod = @import("definition.zig");
const util_json = @import("metacodes-base").util.json;

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

/// How a source is discovered and what a Skill from it references.
pub const Profile = enum {
    /// AgentCore Revision 22 contract (doc/AGENTCORE_BINARY_ABI.md, "Skill
    /// catalog and typed input"): Skills sit one directory below the root,
    /// symlinks are `unsupported_entry`, any failure to open a present root
    /// fails the whole query, and the complete Skill tree is snapshotted and
    /// later materialized into a private working tree.
    canonical,
    /// Claude Code / Codex compatible discovery for the CLI's own sources:
    /// - a symlinked root or Skill directory is resolved, and a Skill reached
    ///   through several links is loaded once (by canonical path);
    /// - SKILL.md is found up to `COMPAT_MAX_DISCOVERY_DEPTH` directories below
    ///   the root (Codex), skipping hidden directories and Claude Code's
    ///   reserved `synced` folder;
    /// - a root that exists but cannot be read, or exceeds its scan budget, is
    ///   reported in `Snapshot.skipped_sources` instead of failing every other
    ///   source;
    /// - only SKILL.md and `agents/openai.yaml` are read. Activation references
    ///   the live Skill directory, as `${CLAUDE_SKILL_DIR}` does in Claude Code
    ///   and the SKILL.md path does in Codex, so Skills that carry a venv,
    ///   node_modules or large assets work as they do there;
    /// - invocation names may contain non-ASCII letters (e.g. `地址库`);
    /// - a missing `description` falls back to the first body line (Claude
    ///   Code), and `agents/openai.yaml` `policy.allow_implicit_invocation:
    ///   false` hides the Skill from the model (Codex).
    compat,
};

/// Codex scans at most six directory levels below a skills root.
pub const COMPAT_MAX_DISCOVERY_DEPTH: usize = 6;
/// Per-root scan budget for compat sources (Codex: 2000 directories, 20000
/// entries per root). Exceeding it skips the rest of that source only.
pub const COMPAT_MAX_SCAN_DIRECTORIES: usize = 2000;
pub const COMPAT_MAX_SCAN_ENTRIES: usize = 20000;

/// Higher numeric priority wins. Equal-priority candidates for the same
/// invocation name are a conflict, independent of source enumeration order.
/// `scope` does not rank candidates: a caller that orders scopes encodes that
/// order in `priority` (the CLI's bands below, AgentCore's scope bands).
pub const Source = struct {
    root: []const u8,
    scope: SourceScope,
    priority: u64,
    namespace: []const u8 = "",
    /// Logical parser/provider identity. This is metadata only; the shared
    /// catalog keeps owning canonical parsing and resolution.
    provider_id: []const u8 = DEFAULT_PROVIDER_ID,
    /// Stable opaque identity for this configured source. Empty keeps legacy
    /// in-process callers working and derives an identity from the root.
    source_instance_id: []const u8 = "",
    profile: Profile = .canonical,
};

/// Inputs of the CLI's built-in source list.
pub const DefaultSourceInputs = struct {
    /// Current working directory (absolute).
    cwd: []const u8,
    /// Repository root containing `cwd`, or `cwd` itself outside a repository.
    workspace_root: []const u8,
    /// User home. "" skips every personal source.
    home: []const u8,
    /// Host state root: `<state_root>/skills` is the metacodes personal tier.
    /// "" skips it.
    state_root: []const u8,
    /// `$CODEX_HOME`; "" means `<home>/.codex`.
    codex_home: []const u8 = "",
    /// `--add-dir` directories; each contributes its own skills directories.
    additional_dirs: []const []const u8 = &.{},
};

/// Priority bands. Claude Code resolves a name clash enterprise > personal >
/// project, so a cloned repository cannot shadow a Skill the user installed.
const ENTERPRISE_PRIORITY: u32 = 3000;
const PERSONAL_PRIORITY: u32 = 2000;
const PROJECT_PRIORITY: u32 = 1000;
const ADDITIONAL_DIR_PRIORITY: u32 = 500;
/// Directories between the repository root and cwd that contribute project
/// sources. Each level takes 10 priority slots, so this bound keeps the
/// project band below the personal band.
const MAX_PROJECT_CHAIN: usize = 64;

/// Within one directory, metacodes' own folder wins, then the cross-agent
/// `.agents` convention, then Claude Code, then Codex.
const ProjectDirKind = struct { parts: []const []const u8, rank: u32 };
const PROJECT_DIR_KINDS = [_]ProjectDirKind{
    .{ .parts = &.{ ".metacodes", "skills" }, .rank = 4 },
    .{ .parts = &.{ ".agents", "skills" }, .rank = 3 },
    .{ .parts = &.{ ".claude", "skills" }, .rank = 2 },
    .{ .parts = &.{ ".codex", "skills" }, .rank = 1 },
};

/// Built-in CLI source order: metacodes' own directories plus the directories
/// Claude Code and Codex read, all with the `compat` profile. AgentCore
/// deliberately supplies its own neutral-only `.agents/skills` policy to the
/// shared engine.
pub fn defaultSources(
    arena: std.mem.Allocator,
    inputs: DefaultSourceInputs,
) error{OutOfMemory}![]const Source {
    var sources: std.ArrayList(Source) = .empty;

    // Enterprise / admin. metacodes defines its managed directory on POSIX only.
    if (builtin.os.tag == .windows) {
        try appendSource(arena, &sources, "C:\\Program Files\\ClaudeCode", &.{ ".claude", "skills" }, .enterprise, ENTERPRISE_PRIORITY + 2);
        try appendSource(arena, &sources, "C:\\ProgramData\\OpenAI\\Codex", &.{"skills"}, .enterprise, ENTERPRISE_PRIORITY + 1);
    } else {
        try appendSource(arena, &sources, "/etc/metacodes", &.{"skills"}, .enterprise, ENTERPRISE_PRIORITY + 3);
        const claude_managed = if (builtin.os.tag == .macos)
            "/Library/Application Support/ClaudeCode"
        else
            "/etc/claude-code";
        try appendSource(arena, &sources, claude_managed, &.{ ".claude", "skills" }, .enterprise, ENTERPRISE_PRIORITY + 2);
        try appendSource(arena, &sources, "/etc/codex", &.{"skills"}, .enterprise, ENTERPRISE_PRIORITY + 1);
    }

    // Personal: pinned sealed Skills (doc/SEALED_SKILL_PROTOCOL.md §9) sit
    // above every other personal source: a pin is explicit consent, and no
    // local file may shadow the name the user subscribed to. Then metacodes'
    // own state root.
    try appendSource(arena, &sources, inputs.state_root, &.{"sealed-skills"}, .personal, PERSONAL_PRIORITY + 5);
    try appendSource(arena, &sources, inputs.state_root, &.{"skills"}, .personal, PERSONAL_PRIORITY + 4);
    try appendSource(arena, &sources, inputs.home, &.{ ".agents", "skills" }, .personal, PERSONAL_PRIORITY + 3);
    try appendSource(arena, &sources, inputs.home, &.{ ".claude", "skills" }, .personal, PERSONAL_PRIORITY + 2);
    if (inputs.codex_home.len != 0) {
        try appendSource(arena, &sources, inputs.codex_home, &.{"skills"}, .personal, PERSONAL_PRIORITY + 1);
    } else {
        try appendSource(arena, &sources, inputs.home, &.{ ".codex", "skills" }, .personal, PERSONAL_PRIORITY + 1);
    }

    // Project: every directory from the repository root down to cwd. A level
    // closer to cwd wins (Claude Code searches from the start directory up).
    const chain = try projectChain(arena, inputs.workspace_root, inputs.cwd);
    for (chain, 0..) |directory, level| {
        const level_base = PROJECT_PRIORITY + @as(u32, @intCast(level)) * 10;
        for (PROJECT_DIR_KINDS) |kind| {
            try appendSource(arena, &sources, directory, kind.parts, .project, level_base + kind.rank);
        }
    }

    // `--add-dir` directories (Claude Code loads `.claude/skills` from them).
    for (inputs.additional_dirs, 0..) |directory, index| {
        if (index >= MAX_PROJECT_CHAIN) break;
        const base = ADDITIONAL_DIR_PRIORITY - @as(u32, @intCast(index)) * 5;
        for (PROJECT_DIR_KINDS[0..3]) |kind| {
            try appendSource(arena, &sources, directory, kind.parts, .project, base - (4 - kind.rank));
        }
    }
    return sources.toOwnedSlice(arena);
}

/// Directories from `workspace_root` down to `cwd`, root first. A `cwd` that
/// is not below `workspace_root` contributes only itself.
fn projectChain(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    cwd: []const u8,
) error{OutOfMemory}![]const []const u8 {
    var chain: std.ArrayList([]const u8) = .empty;
    const root = std.mem.trimEnd(u8, workspace_root, "/\\");
    const start = std.mem.trimEnd(u8, cwd, "/\\");
    const below_root = root.len != 0 and std.mem.startsWith(u8, start, root) and
        (start.len == root.len or start[root.len] == '/' or start[root.len] == '\\');
    if (!below_root) {
        if (start.len != 0) try chain.append(arena, start);
        return chain.toOwnedSlice(arena);
    }
    try chain.append(arena, root);
    var cursor = root.len;
    while (cursor < start.len and chain.items.len < MAX_PROJECT_CHAIN) {
        const next = std.mem.indexOfAnyPos(u8, start, cursor + 1, "/\\") orelse start.len;
        try chain.append(arena, start[0..next]);
        cursor = next;
    }
    return chain.toOwnedSlice(arena);
}

fn appendSource(
    arena: std.mem.Allocator,
    sources: *std.ArrayList(Source),
    base: []const u8,
    suffix: []const []const u8,
    scope: SourceScope,
    priority: u32,
) error{OutOfMemory}!void {
    if (base.len == 0 or !std.fs.path.isAbsolute(base)) return;
    const parts = try arena.alloc([]const u8, suffix.len + 1);
    parts[0] = base;
    @memcpy(parts[1..], suffix);
    try sources.append(arena, .{
        .root = try std.fs.path.join(arena, parts),
        .scope = scope,
        .priority = priority,
        .profile = .compat,
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
    /// `compat` sources only: the canonical live Skill directory. Activation
    /// references it instead of materializing `files`, which then hold only the
    /// parsed metadata files (SKILL.md, `agents/openai.yaml`).
    live_dir: ?[]const u8 = null,
    /// The configured root the Skill was discovered under (display only).
    source_root: []const u8 = "",
};

pub const SkipReason = enum {
    /// The root exists but could not be opened or enumerated.
    unreadable,
    /// The root holds more directories or entries than the compat scan budget.
    scan_limit,
};

/// A `compat` source left out of the catalog. Canonical sources never skip:
/// they fail the whole query instead (AgentCore contract).
pub const SkippedSource = struct {
    root: []const u8,
    scope: SourceScope,
    reason: SkipReason,
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
    skipped_sources: []const SkippedSource = &.{},
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
    /// Absolute directory holding the Skill directory; opened without following
    /// a final symlink.
    parent: []const u8,
    /// Skill directory name below `parent`.
    dir_name: []const u8,
    /// The name the Skill is listed under in its root (a link keeps its own
    /// name); the invocation fallback and contribution identity.
    identity_name: []const u8,
    /// Deduplication key: the canonical Skill directory for compat sources,
    /// `root/entry` for canonical ones.
    canonical: []const u8,
    source_root: []const u8,
    profile: Profile = .canonical,
    invocation_name: []const u8,
    scope: SourceScope,
    provider_id: []const u8 = DEFAULT_PROVIDER_ID,
    source_instance_id: []const u8 = "",
    priority: u64,
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
    var skipped: std.ArrayList(SkippedSource) = .empty;
    var work_budget = WorkBudget{};
    var catalog_usage = CatalogUsage{};

    for (sources) |source| switch (source.profile) {
        .canonical => try enumerateSource(scratch, io, source, limits, &work_budget, &candidates, &issues),
        .compat => try enumerateCompatSource(scratch, io, source, &candidates, &issues, &skipped),
    };
    try dropDuplicateTargets(scratch, &candidates);
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
    snapshot.skipped_sources = cloneSkipped(arena, skipped.items) catch return error.OutOfMemory;
    snapshot.content_bytes = catalog_usage.content_bytes;
    snapshot.health = if (snapshot.issues.len == 0 and snapshot.skipped_sources.len == 0)
        .healthy
    else
        .degraded;
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
                    try canonicalLocation(arena, source.root, entry.name),
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
        try appendCandidate(arena, source, try canonicalLocation(arena, source.root, entry.name), state, candidates, issues);
    }
    const after = root.stat(io) catch return error.CatalogIncomplete;
    if (!sameDirectoryState(before, after)) return error.CatalogIncomplete;
}

const CandidateLocation = struct {
    parent: []const u8,
    dir_name: []const u8,
    identity_name: []const u8,
    canonical: []const u8,
};

fn appendCandidate(
    arena: std.mem.Allocator,
    source: Source,
    location: CandidateLocation,
    state: Candidate.State,
    candidates: *std.ArrayList(Candidate),
    issues: *std.ArrayList(Issue),
) error{OutOfMemory}!void {
    const invocation = try makeInvocationName(arena, source.namespace, location.identity_name);
    const valid = switch (source.profile) {
        .canonical => validInvocationName(invocation),
        .compat => validCompatInvocationName(invocation),
    };
    if (!valid) {
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
        .parent = try arena.dupe(u8, location.parent),
        .dir_name = try arena.dupe(u8, location.dir_name),
        .identity_name = try arena.dupe(u8, location.identity_name),
        .canonical = try arena.dupe(u8, location.canonical),
        // Sources are borrowed for the synchronous duration of `build`.
        .source_root = source.root,
        .profile = source.profile,
        .invocation_name = invocation,
        .scope = source.scope,
        .provider_id = source.provider_id,
        .source_instance_id = try sourceInstanceId(arena, source),
        .priority = source.priority,
        .state = state,
    });
}

/// A Skill reached through several roots or links is one Skill: keep the
/// highest-priority path to it (Claude Code: "loads the skill once even if
/// several locations point at the same target"; Codex dedupes on the
/// canonical SKILL.md path). Distinct targets are left for name resolution.
fn dropDuplicateTargets(
    scratch: std.mem.Allocator,
    candidates: *std.ArrayList(Candidate),
) BuildError!void {
    var best = std.StringHashMapUnmanaged(usize).empty;
    defer best.deinit(scratch);
    var keep = scratch.alloc(bool, candidates.items.len) catch return error.OutOfMemory;
    @memset(keep, true);
    for (candidates.items, 0..) |candidate, index| {
        const entry = best.getOrPut(scratch, candidate.canonical) catch return error.OutOfMemory;
        if (!entry.found_existing) {
            entry.value_ptr.* = index;
            continue;
        }
        const previous = &candidates.items[entry.value_ptr.*];
        if (candidate.priority > previous.priority) {
            keep[entry.value_ptr.*] = false;
            entry.value_ptr.* = index;
        } else {
            keep[index] = false;
        }
    }
    var write: usize = 0;
    for (candidates.items, keep) |candidate, kept| {
        if (!kept) continue;
        candidates.items[write] = candidate;
        write += 1;
    }
    candidates.shrinkRetainingCapacity(write);
}

fn sourceInstanceId(arena: std.mem.Allocator, source: Source) error{OutOfMemory}![]const u8 {
    if (source.source_instance_id.len != 0)
        return arena.dupe(u8, source.source_instance_id);
    const derived = hashHex(source.root);
    return arena.dupe(u8, &derived);
}

fn canonicalLocation(
    arena: std.mem.Allocator,
    root: []const u8,
    entry_name: []const u8,
) error{OutOfMemory}!CandidateLocation {
    return .{
        .parent = root,
        .dir_name = entry_name,
        .identity_name = entry_name,
        .canonical = try std.fs.path.join(arena, &.{ root, entry_name }),
    };
}

const CompatScanError = error{ OutOfMemory, ScanLimit, RootUnavailable };

/// Claude Code / Codex compatible discovery; see `Profile.compat`.
fn enumerateCompatSource(
    arena: std.mem.Allocator,
    io: std.Io,
    source: Source,
    candidates: *std.ArrayList(Candidate),
    issues: *std.ArrayList(Issue),
    skipped: *std.ArrayList(SkippedSource),
) BuildError!void {
    if (source.root.len == 0 or !std.fs.path.isAbsolute(source.root)) return error.CatalogInvalid;
    if (source.namespace.len > 128 or source.provider_id.len == 0 or
        source.provider_id.len > 128 or source.source_instance_id.len > 128)
        return error.ResourceLimit;

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = Dir.realPathFileAbsolute(io, source.root, &root_buffer) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => {
            try skipped.append(arena, .{ .root = source.root, .scope = source.scope, .reason = .unreadable });
            return;
        },
    };
    const root = try arena.dupe(u8, root_buffer[0..root_len]);

    const candidate_checkpoint = candidates.items.len;
    const issue_checkpoint = issues.items.len;
    var scan = CompatScan{
        .arena = arena,
        .io = io,
        .source = source,
        .candidates = candidates,
        .issues = issues,
    };
    try scan.visited.put(arena, root, {});
    scan.walk(root, 1) catch |err| {
        // A partial walk depends on directory enumeration order; publish the
        // source whole or not at all.
        candidates.shrinkRetainingCapacity(candidate_checkpoint);
        issues.shrinkRetainingCapacity(issue_checkpoint);
        try skipped.append(arena, .{
            .root = source.root,
            .scope = source.scope,
            .reason = switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ScanLimit => .scan_limit,
                error.RootUnavailable => .unreadable,
            },
        });
    };
}

const CompatScan = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    source: Source,
    candidates: *std.ArrayList(Candidate),
    issues: *std.ArrayList(Issue),
    /// Canonical directories already walked or registered (cycle guard).
    visited: std.StringHashMapUnmanaged(void) = .empty,
    directories: usize = 0,
    entries: usize = 0,

    const Child = struct { name: []const u8, kind: File.Kind };

    fn walk(self: *CompatScan, dir_path: []const u8, depth: usize) CompatScanError!void {
        self.directories += 1;
        if (self.directories > COMPAT_MAX_SCAN_DIRECTORIES) return error.ScanLimit;
        var dir = Dir.openDirAbsolute(self.io, dir_path, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch {
            // A nested directory that cannot be opened has no visible SKILL.md.
            if (depth == 1) return error.RootUnavailable;
            return;
        };
        defer dir.close(self.io);

        var children: std.ArrayList(Child) = .empty;
        var iterator = dir.iterate();
        while (iterator.next(self.io) catch {
            if (depth == 1) return error.RootUnavailable;
            return;
        }) |entry| {
            self.entries += 1;
            if (self.entries > COMPAT_MAX_SCAN_ENTRIES) return error.ScanLimit;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            if (depth == 1 and std.ascii.eqlIgnoreCase(entry.name, "synced")) continue;
            try children.append(self.arena, .{ .name = try self.arena.dupe(u8, entry.name), .kind = entry.kind });
        }
        std.mem.sort(Child, children.items, {}, childLessThan);

        for (children.items) |child| {
            const target = (try self.resolveDirectory(dir, dir_path, child)) orelse continue;
            const seen = try self.visited.getOrPut(self.arena, target);
            if (seen.found_existing) continue;
            if (try self.probe(target)) |state| {
                try appendCandidate(self.arena, self.source, .{
                    .parent = std.fs.path.dirname(target) orelse continue,
                    .dir_name = std.fs.path.basename(target),
                    .identity_name = child.name,
                    .canonical = target,
                }, state, self.candidates, self.issues);
                continue;
            }
            if (depth < COMPAT_MAX_DISCOVERY_DEPTH) try self.walk(target, depth + 1);
        }
    }

    /// Canonical path of a child directory, following a symlink. Anything that
    /// is not (or does not lead to) a directory is not a Skill location.
    fn resolveDirectory(self: *CompatScan, dir: Dir, dir_path: []const u8, child: Child) CompatScanError!?[]const u8 {
        switch (child.kind) {
            .directory => return try std.fs.path.join(self.arena, &.{ dir_path, child.name }),
            .sym_link, .unknown => {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const length = dir.realPathFile(self.io, child.name, &buffer) catch return null;
                const target = try self.arena.dupe(u8, buffer[0..length]);
                var probe_dir = Dir.openDirAbsolute(self.io, target, .{ .follow_symlinks = false }) catch
                    return null;
                probe_dir.close(self.io);
                return target;
            },
            else => return null,
        }
    }

    /// `null` when the directory has no SKILL.md (keep descending); a failed
    /// state when SKILL.md exists but is not a stable regular file.
    fn probe(self: *CompatScan, target: []const u8) CompatScanError!?Candidate.State {
        var skill_dir = Dir.openDirAbsolute(self.io, target, .{ .follow_symlinks = false }) catch
            return null;
        defer skill_dir.close(self.io);
        const stat = skill_dir.statFile(self.io, "SKILL.md", .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return .{ .invalid_resource = .resource_unavailable },
        };
        if (stat.kind != .file) return .{ .invalid_resource = .unsupported_entry };
        return .ready;
    }

    fn childLessThan(_: void, lhs: Child, rhs: Child) bool {
        return std.mem.lessThan(u8, lhs.name, rhs.name);
    }
};

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
    var root = Dir.openDirAbsolute(io, candidate.parent, .{
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
    if (candidate.profile == .compat)
        return snapshotCompatMetadata(arena, io, candidate, skill_dir, limits, candidate_usage);
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
    const definition = try parseDefinition(arena, md, candidate, .{});
    return finishRecord(candidate, definition, owned_directories, owned_files, null);
}

/// Compat sources read only the metadata the catalog parses; the Skill's other
/// files stay in its live directory (see `Profile.compat`).
fn snapshotCompatMetadata(
    arena: std.mem.Allocator,
    io: std.Io,
    candidate: Candidate,
    skill_dir: Dir,
    limits: Limits,
    candidate_usage: *CandidateUsage,
) LocalError!SkillRecord {
    var files: std.ArrayList(FileRecord) = .empty;
    var directories: std.ArrayList([]const u8) = .empty;
    try snapshotFile(arena, io, skill_dir, "SKILL.md", "SKILL.md", limits, candidate_usage, &files);
    const md = files.items[0].bytes;

    var sidecar: ?definition_mod.CodexSidecar = null;
    if (skill_dir.openDir(io, "agents", .{ .follow_symlinks = false })) |opened| {
        var agents_dir = opened;
        defer agents_dir.close(io);
        const present = if (agents_dir.statFile(io, "openai.yaml", .{ .follow_symlinks = false })) |stat|
            stat.kind == .file
        else |_|
            false;
        if (present) {
            try snapshotFile(arena, io, agents_dir, "openai.yaml", "agents/openai.yaml", limits, candidate_usage, &files);
            try directories.append(arena, "agents");
            sidecar = try definition_mod.parseCodexSidecar(arena, files.items[1].bytes);
        }
    } else |_| {}

    var definition = try parseDefinition(arena, md, candidate, .{ .description_fallback = true });
    if (sidecar) |policy| {
        if (!policy.allow_implicit_invocation) definition.disable_model_invocation = true;
    }
    const live_dir = try std.fs.path.join(arena, &.{ candidate.parent, candidate.dir_name });
    return finishRecord(
        candidate,
        definition,
        try directories.toOwnedSlice(arena),
        try files.toOwnedSlice(arena),
        live_dir,
    );
}

fn parseDefinition(
    arena: std.mem.Allocator,
    md: []const u8,
    candidate: Candidate,
    options: definition_mod.ParseOptions,
) LocalError!definition_mod.Skill {
    if (!std.unicode.utf8ValidateSlice(md)) return error.InvalidDefinition;
    const definition = definition_mod.parseSkillMdWithOptions(
        arena,
        md,
        "",
        candidate.identity_name,
        options,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.InvalidDefinition;
    };
    if (!validArgumentNames(definition.arguments)) return error.InvalidDefinition;
    return definition;
}

fn finishRecord(
    candidate: Candidate,
    definition: definition_mod.Skill,
    directories: []const []const u8,
    files: []const FileRecord,
    live_dir: ?[]const u8,
) SkillRecord {
    var record = SkillRecord{
        .skill_id = hashHex(candidate.invocation_name),
        .invocation_name = candidate.invocation_name,
        .provider_id = candidate.provider_id,
        .source_scope = candidate.scope,
        .source_instance_id = candidate.source_instance_id,
        .contribution_id = hashHex(candidate.identity_name),
        .definition = definition,
        .directories = directories,
        .files = files,
        .live_dir = live_dir,
        .source_root = candidate.source_root,
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
            .description_source = source.definition.description_source,
            .warnings = source.definition.warnings,
            .when_to_use = try arena.dupe(u8, source.definition.when_to_use),
            .argument_hint = try arena.dupe(u8, source.definition.argument_hint),
            .body = try arena.dupe(u8, source.definition.body),
            .allowed_tools = try cloneStringList(arena, source.definition.allowed_tools),
            .disallowed_tools = try cloneStringList(arena, source.definition.disallowed_tools),
            .arguments = try cloneStringList(arena, source.definition.arguments),
            .disable_model_invocation = source.definition.disable_model_invocation,
            .user_invocable = source.definition.user_invocable,
            .model_activation = source.definition.model_activation,
            .context = source.definition.context,
            .agent = try arena.dupe(u8, source.definition.agent),
            .model = try arena.dupe(u8, source.definition.model),
            .shell = try arena.dupe(u8, source.definition.shell),
            .source_path = "",
            .sealed_gateway = try arena.dupe(u8, source.definition.sealed_gateway),
            .sealed_skill_id = try arena.dupe(u8, source.definition.sealed_skill_id),
            .sealed_manifest_digest = try arena.dupe(u8, source.definition.sealed_manifest_digest),
        },
        .directories = directories,
        .files = files,
        .live_dir = if (source.live_dir) |path| try arena.dupe(u8, path) else null,
        .source_root = try arena.dupe(u8, source.source_root),
    };
}

fn cloneSkipped(
    arena: std.mem.Allocator,
    source: []const SkippedSource,
) error{OutOfMemory}![]const SkippedSource {
    const result = try arena.alloc(SkippedSource, source.len);
    for (source, result) |skipped, *copy| {
        copy.* = .{
            .root = try arena.dupe(u8, skipped.root),
            .scope = skipped.scope,
            .reason = skipped.reason,
        };
    }
    return result;
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
        if (record.live_dir) |live_dir| {
            hashField(&hash, "live_dir");
            hashField(&hash, live_dir);
        }
    }
    for (snapshot.skipped_sources) |skipped| {
        hashField(&hash, "skipped_source");
        hashField(&hash, skipped.root);
        hashField(&hash, @tagName(skipped.reason));
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

/// Compat invocation grammar: the canonical grammar plus any non-ASCII letter,
/// so a Skill directory such as `地址库` (which Claude Code loads) is
/// invocable. Unicode whitespace, controls and format characters stay out, so
/// a name is always one visible `/token`.
pub fn validCompatInvocationName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (!std.unicode.utf8ValidateSlice(name)) return false;
    var view = std.unicode.Utf8View.initUnchecked(name);
    var iterator = view.iterator();
    var first = true;
    while (iterator.nextCodepoint()) |codepoint| {
        defer first = false;
        if (codepoint < 0x80) {
            const byte: u8 = @intCast(codepoint);
            if (std.ascii.isAlphanumeric(byte) or byte == '_') continue;
            if (!first and (byte == ':' or byte == '-')) continue;
            return false;
        }
        if (codepoint <= 0x9f or isUnicodeSpaceOrFormat(codepoint)) return false;
    }
    return true;
}

fn isUnicodeSpaceOrFormat(codepoint: u21) bool {
    return switch (codepoint) {
        0xa0, 0xad, 0x1680, 0x180e, 0x2000...0x200f, 0x2028...0x202f, 0x205f...0x206f, 0x3000, 0xfeff => true,
        else => false,
    };
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
    const by_root = std.mem.order(u8, lhs.parent, rhs.parent);
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

test "product default sources follow Claude Code tiers and read every compatible directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sep = std.fs.path.sep_str;
    const base = if (builtin.os.tag == .windows) "C:\\w" else "/w";
    const repo = base ++ sep ++ "repo";
    const cwd = repo ++ sep ++ "pkg" ++ sep ++ "app";
    const home = base ++ sep ++ "home";
    const state = base ++ sep ++ "state";
    const extra = base ++ sep ++ "extra";

    const sources = try defaultSources(a, .{
        .cwd = cwd,
        .workspace_root = repo,
        .home = home,
        .state_root = state,
        .additional_dirs = &.{extra},
    });
    for (sources) |source| try std.testing.expectEqual(Profile.compat, source.profile);

    const Expect = struct { root: []const u8, scope: SourceScope };
    const join = struct {
        fn f(alloc: std.mem.Allocator, parts: []const []const u8) []const u8 {
            return std.fs.path.join(alloc, parts) catch unreachable;
        }
    }.f;
    const personal_and_project = [_]Expect{
        .{ .root = join(a, &.{ state, "sealed-skills" }), .scope = .personal },
        .{ .root = join(a, &.{ state, "skills" }), .scope = .personal },
        .{ .root = join(a, &.{ home, ".agents", "skills" }), .scope = .personal },
        .{ .root = join(a, &.{ home, ".claude", "skills" }), .scope = .personal },
        .{ .root = join(a, &.{ home, ".codex", "skills" }), .scope = .personal },
        .{ .root = join(a, &.{ cwd, ".metacodes", "skills" }), .scope = .project },
        .{ .root = join(a, &.{ cwd, ".agents", "skills" }), .scope = .project },
        .{ .root = join(a, &.{ cwd, ".claude", "skills" }), .scope = .project },
        .{ .root = join(a, &.{ cwd, ".codex", "skills" }), .scope = .project },
        .{ .root = join(a, &.{ repo, "pkg", ".agents", "skills" }), .scope = .project },
        .{ .root = join(a, &.{ repo, ".metacodes", "skills" }), .scope = .project },
        .{ .root = join(a, &.{ repo, ".codex", "skills" }), .scope = .project },
        .{ .root = join(a, &.{ extra, ".metacodes", "skills" }), .scope = .project },
        .{ .root = join(a, &.{ extra, ".claude", "skills" }), .scope = .project },
    };
    // Sorting by priority (highest first) must reproduce the documented order:
    // enterprise > personal (metacodes, .agents, Claude Code, Codex) > project
    // (closest to cwd first; metacodes, .agents, Claude Code, Codex within a
    // directory) > --add-dir.
    const sorted = try a.dupe(Source, sources);
    std.mem.sort(Source, sorted, {}, struct {
        fn lessThan(_: void, lhs: Source, rhs: Source) bool {
            return lhs.priority > rhs.priority;
        }
    }.lessThan);
    for (sorted[0 .. sorted.len - 1], sorted[1..]) |higher, lower| {
        try std.testing.expect(higher.priority != lower.priority);
    }
    var enterprise_count: usize = 0;
    for (sorted) |source| {
        if (source.scope == .enterprise) enterprise_count += 1;
    }
    for (sorted[0..enterprise_count]) |source| try std.testing.expectEqual(SourceScope.enterprise, source.scope);
    const rest = sorted[enterprise_count..];
    var cursor: usize = 0;
    for (personal_and_project) |want| {
        while (cursor < rest.len and !std.mem.eql(u8, rest[cursor].root, want.root)) cursor += 1;
        if (cursor == rest.len) {
            std.debug.print("missing or out of order: {s}\n", .{want.root});
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqual(want.scope, rest[cursor].scope);
    }
}

test "project chain covers repository root down to cwd, or cwd alone outside it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const chain = try projectChain(arena.allocator(), "/r", "/r/a/b/");
    try std.testing.expectEqual(@as(usize, 3), chain.len);
    try std.testing.expectEqualStrings("/r", chain[0]);
    try std.testing.expectEqualStrings("/r/a/b", chain[2]);
    const outside = try projectChain(arena.allocator(), "/r", "/rx/y");
    try std.testing.expectEqual(@as(usize, 1), outside.len);
    try std.testing.expectEqualStrings("/rx/y", outside[0]);
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
        .when_to_use = "",
        .description_source = .missing,
        .warnings = .{},
        .argument_hint = "",
        .user_invocable = true,
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
                .parent = root,
                .dir_name = "review",
                .identity_name = "review",
                .canonical = "review",
                .source_root = root,
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

// ============================================================================
// Compat profile (Claude Code / Codex directories)
// ============================================================================

const CompatFixture = struct {
    tmp: std.testing.TmpDir,
    root_buffer: [std.fs.max_path_bytes]u8 = undefined,
    root_len: usize = 0,

    fn init() !CompatFixture {
        var fixture = CompatFixture{ .tmp = std.testing.tmpDir(.{}) };
        fixture.root_len = try fixture.tmp.dir.realPath(std.testing.io, &fixture.root_buffer);
        return fixture;
    }

    fn deinit(self: *CompatFixture) void {
        self.tmp.cleanup();
    }

    fn root(self: *const CompatFixture) []const u8 {
        return self.root_buffer[0..self.root_len];
    }

    fn path(self: *const CompatFixture, arena: std.mem.Allocator, relative: []const u8) []const u8 {
        return std.fs.path.join(arena, &.{ self.root(), relative }) catch unreachable;
    }

    fn write(self: *const CompatFixture, arena: std.mem.Allocator, relative: []const u8, data: []const u8) !void {
        const full = self.path(arena, relative);
        if (std.fs.path.dirname(full)) |parent| try Dir.cwd().createDirPath(std.testing.io, parent);
        try Dir.cwd().writeFile(std.testing.io, .{ .sub_path = full, .data = data });
    }

    fn link(self: *const CompatFixture, arena: std.mem.Allocator, target: []const u8, relative_link: []const u8) !bool {
        const link_path = self.path(arena, relative_link);
        if (std.fs.path.dirname(link_path)) |parent| try Dir.cwd().createDirPath(std.testing.io, parent);
        Dir.symLinkAbsolute(std.testing.io, self.path(arena, target), link_path, .{ .is_directory = true }) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => return false,
            else => return err,
        };
        return true;
    }

    fn source(self: *const CompatFixture, arena: std.mem.Allocator, relative: []const u8, scope: SourceScope, priority: u32) Source {
        return .{ .root = self.path(arena, relative), .scope = scope, .priority = priority, .profile = .compat };
    }
};

const compat_scope_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn expectSkill(snapshot: *const Snapshot, name: []const u8) !*const SkillRecord {
    return snapshot.findByInvocation(name) orelse {
        std.debug.print("missing skill {s}\n", .{name});
        return error.TestUnexpectedResult;
    };
}

test "compat: a Skill linked from several roots loads once, through its highest-priority path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = try CompatFixture.init();
    defer fixture.deinit();

    // `npx skills add` layout: the real copy in ~/.agents/skills, a link in ~/.claude/skills.
    try fixture.write(a, "agents/browser/SKILL.md", "---\ndescription: drive a browser\n---\nbody");
    if (!try fixture.link(a, "agents/browser", "claude/browser")) return error.SkipZigTest;
    // A link that points outside every root, under its own name.
    try fixture.write(a, "elsewhere/real-name/SKILL.md", "---\ndescription: linked in\n---\nbody");
    if (!try fixture.link(a, "elsewhere/real-name", "claude/link-name")) return error.SkipZigTest;
    // A dangling link and a plain file are not Skills.
    _ = try fixture.link(a, "missing", "claude/dangling");
    try fixture.write(a, "claude/README.md", "not a skill");

    const sources = [_]Source{
        fixture.source(a, "claude", .personal, 2002),
        fixture.source(a, "agents", .personal, 2003),
    };
    const snapshot = try build(std.testing.allocator, std.testing.io, compat_scope_id, "", &sources, .{});
    defer snapshot.deinit();
    try std.testing.expectEqual(Health.healthy, snapshot.health);
    try std.testing.expectEqual(@as(usize, 2), snapshot.skills.len);
    const browser = try expectSkill(snapshot, "browser");
    try std.testing.expect(std.mem.endsWith(u8, browser.source_root, "agents"));
    const linked = try expectSkill(snapshot, "link-name");
    try std.testing.expect(std.mem.endsWith(u8, linked.live_dir.?, "real-name"));
}

test "compat: a symlinked root, nested Skills, hidden and reserved folders" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = try CompatFixture.init();
    defer fixture.deinit();

    try fixture.write(a, "dotfiles/skills/top/SKILL.md", "---\ndescription: top\n---\nb");
    try fixture.write(a, "dotfiles/skills/group/inner/SKILL.md", "---\ndescription: nested one level\n---\nb");
    try fixture.write(a, "dotfiles/skills/a/b/c/d/e/six/SKILL.md", "---\ndescription: depth six\n---\nb");
    try fixture.write(a, "dotfiles/skills/a/b/c/d/e/f/seven/SKILL.md", "---\ndescription: too deep\n---\nb");
    try fixture.write(a, "dotfiles/skills/.system/hidden/SKILL.md", "---\ndescription: hidden\n---\nb");
    try fixture.write(a, "dotfiles/skills/Synced/claude-ai/SKILL.md", "---\ndescription: reserved\n---\nb");
    // A Skill's own subtree is not searched for more Skills.
    try fixture.write(a, "dotfiles/skills/top/examples/sub/SKILL.md", "---\ndescription: inside top\n---\nb");
    if (!try fixture.link(a, "dotfiles/skills", "home/skills")) return error.SkipZigTest;

    const sources = [_]Source{fixture.source(a, "home/skills", .personal, 2000)};
    const snapshot = try build(std.testing.allocator, std.testing.io, compat_scope_id, "", &sources, .{});
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 3), snapshot.skills.len);
    _ = try expectSkill(snapshot, "top");
    _ = try expectSkill(snapshot, "inner");
    _ = try expectSkill(snapshot, "six");
}

test "compat: only metadata is read, the live directory is referenced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = try CompatFixture.init();
    defer fixture.deinit();

    try fixture.write(a, "skills/heavy/SKILL.md", "---\ndescription: carries a venv\n---\nRun `.venv/bin/python scripts/x.py`.");
    try fixture.write(a, "skills/heavy/agents/openai.yaml", "interface:\n  display_name: Heavy\npolicy:\n  allow_implicit_invocation: false\n");
    // More files than a snapshot Skill may hold, and a link leaving the tree:
    // a canonical source rejects this Skill, a compat source never reads them.
    var index: usize = 0;
    while (index < 1100) : (index += 1) {
        try fixture.write(a, try std.fmt.allocPrint(a, "skills/heavy/.venv/lib/f{d}.py", .{index}), "x");
    }
    _ = try fixture.link(a, "skills", "skills/heavy/.venv/escape");

    const sources = [_]Source{fixture.source(a, "skills", .project, 1000)};
    const snapshot = try build(std.testing.allocator, std.testing.io, compat_scope_id, "", &sources, .{});
    defer snapshot.deinit();
    try std.testing.expectEqual(Health.healthy, snapshot.health);
    const heavy = try expectSkill(snapshot, "heavy");
    try std.testing.expectEqual(@as(usize, 2), heavy.files.len);
    try std.testing.expectEqualStrings("SKILL.md", heavy.files[0].relative_path);
    try std.testing.expectEqualStrings("agents/openai.yaml", heavy.files[1].relative_path);
    try std.testing.expect(std.mem.endsWith(u8, heavy.live_dir.?, "heavy"));
    // Codex `allow_implicit_invocation: false` hides it from the model.
    try std.testing.expect(heavy.definition.disable_model_invocation);

    const canonical_sources = [_]Source{.{ .root = fixture.path(a, "skills"), .scope = .project, .priority = 1 }};
    const strict = try build(std.testing.allocator, std.testing.io, compat_scope_id, "", &canonical_sources, .{});
    defer strict.deinit();
    try std.testing.expectEqual(@as(usize, 0), strict.skills.len);
    try std.testing.expect(strict.skills.len == 0 and strict.issues.len == 1);
}

test "compat: Claude Code precedence, Unicode names and description fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = try CompatFixture.init();
    defer fixture.deinit();

    try fixture.write(a, "personal/deploy/SKILL.md", "---\ndescription: personal deploy\n---\nb");
    try fixture.write(a, "project/deploy/SKILL.md", "---\ndescription: project deploy\n---\nb");
    try fixture.write(a, "project/地址库/SKILL.md", "---\ndescription: 查询地址\n---\nb");
    try fixture.write(a, "project/untitled/SKILL.md", "---\nname: untitled\n---\n\nFirst body line describes it.\n");
    try fixture.write(a, "project/bad name/SKILL.md", "---\ndescription: spaces are not invocable\n---\nb");

    const sources = [_]Source{
        fixture.source(a, "personal", .personal, 2000),
        fixture.source(a, "project", .project, 1000),
    };
    const snapshot = try build(std.testing.allocator, std.testing.io, compat_scope_id, "", &sources, .{});
    defer snapshot.deinit();
    const deploy = try expectSkill(snapshot, "deploy");
    try std.testing.expectEqualStrings("personal deploy", deploy.definition.description);
    _ = try expectSkill(snapshot, "地址库");
    const untitled = try expectSkill(snapshot, "untitled");
    try std.testing.expectEqualStrings("First body line describes it.", untitled.definition.description);
    // The invalid name is a typed issue, not a silent drop.
    try std.testing.expectEqual(@as(usize, 1), snapshot.issues.len);
    try std.testing.expectEqual(IssueCode.invalid_invocation_name, snapshot.issues[0].code);
}

test "blank name and description load in both profiles, read as absent, with warnings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = try CompatFixture.init();
    defer fixture.deinit();

    // The #395 reproduction.
    try fixture.write(a, "skills/demo/SKILL.md", "---\nname: \"\"\ndescription: \"\"\n---\n\nUse for demonstrating an empty frontmatter.\n");
    try fixture.write(a, "skills/plain/SKILL.md", "---\nname: plain\ndescription: Plain things\n---\nbody\n");
    const both = definition_mod.Warnings.init(.{ .blank_name = true, .blank_description = true });

    // Compat (the CLI hosts): Claude Code's first-line fallback stands in.
    const compat_sources = [_]Source{fixture.source(a, "skills", .project, 1000)};
    const compat = try build(std.testing.allocator, std.testing.io, compat_scope_id, "", &compat_sources, .{});
    defer compat.deinit();
    try std.testing.expectEqual(Health.healthy, compat.health);
    try std.testing.expectEqual(@as(usize, 0), compat.issues.len);
    const demo = try expectSkill(compat, "demo");
    try std.testing.expectEqualStrings("demo", demo.definition.name);
    try std.testing.expectEqualStrings("Use for demonstrating an empty frontmatter.", demo.definition.description);
    try std.testing.expectEqual(definition_mod.DescriptionSource.body_first_line, demo.definition.description_source);
    try std.testing.expect(both.eql(demo.definition.warnings));
    try std.testing.expectEqual(@as(usize, 0), (try expectSkill(compat, "plain")).definition.warnings.count());

    // Canonical (AgentCore): no fallback, so the description stays empty, as
    // when absent; the slot is still valid, not an `invalid_definition` issue.
    const canonical_sources = [_]Source{.{ .root = fixture.path(a, "skills"), .scope = .project, .priority = 1 }};
    const canonical = try build(std.testing.allocator, std.testing.io, compat_scope_id, "", &canonical_sources, .{});
    defer canonical.deinit();
    try std.testing.expectEqual(Health.healthy, canonical.health);
    try std.testing.expectEqual(@as(usize, 0), canonical.issues.len);
    const strict = try expectSkill(canonical, "demo");
    try std.testing.expectEqualStrings("demo", strict.definition.name);
    try std.testing.expectEqualStrings("", strict.definition.description);
    try std.testing.expectEqual(definition_mod.DescriptionSource.missing, strict.definition.description_source);
    try std.testing.expect(both.eql(strict.definition.warnings));
    try std.testing.expect(std.mem.indexOf(u8, canonical.descriptor_json, "\"display_name\":\"demo\",\"description\":\"\"") != null);
}

test "compat: an unreadable root is skipped and reported; siblings still load" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = try CompatFixture.init();
    defer fixture.deinit();

    try fixture.write(a, "good/ok/SKILL.md", "---\ndescription: ok\n---\nb");
    try fixture.write(a, "locked/hidden/SKILL.md", "---\ndescription: unreachable\n---\nb");
    const locked = fixture.path(a, "locked");
    const locked_z = try a.dupeZ(u8, locked);
    if (std.c.chmod(locked_z.ptr, 0) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(locked_z.ptr, 0o755);
    // Root can still list a 000 directory: skip the test there.
    if (Dir.openDirAbsolute(std.testing.io, locked, .{ .iterate = true })) |opened| {
        var dir = opened;
        var iterator = dir.iterate();
        const readable = if (iterator.next(std.testing.io)) |_| true else |_| false;
        dir.close(std.testing.io);
        if (readable) return error.SkipZigTest;
    } else |_| {}

    const sources = [_]Source{
        fixture.source(a, "locked", .personal, 2000),
        fixture.source(a, "good", .project, 1000),
    };
    const snapshot = try build(std.testing.allocator, std.testing.io, compat_scope_id, "", &sources, .{});
    defer snapshot.deinit();
    try std.testing.expectEqual(Health.degraded, snapshot.health);
    _ = try expectSkill(snapshot, "ok");
    try std.testing.expectEqual(@as(usize, 1), snapshot.skipped_sources.len);
    try std.testing.expectEqual(SkipReason.unreadable, snapshot.skipped_sources[0].reason);
}

test "compat invocation grammar admits non-ASCII letters but no blanks or controls" {
    try std.testing.expect(validCompatInvocationName("地址库"));
    try std.testing.expect(validCompatInvocationName("plugin:review-2"));
    try std.testing.expect(validCompatInvocationName("Résumé"));
    try std.testing.expect(!validCompatInvocationName("two words"));
    try std.testing.expect(!validCompatInvocationName("全角\u{3000}空格"));
    try std.testing.expect(!validCompatInvocationName("zero\u{200b}width"));
    try std.testing.expect(!validCompatInvocationName("-leading"));
    try std.testing.expect(!validCompatInvocationName("bad.name"));
    try std.testing.expect(!validCompatInvocationName("\xff"));
}
