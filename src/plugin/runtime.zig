//! Transactional immutable plugin snapshot.
//!
//! Snapshot creation is the only mutation point: discover, parse, resolve,
//! validate contributions, then publish the fully-owned value. Active Sessions
//! retain their Runtime and therefore their exact plugin generation.

const std = @import("std");
const pfs = @import("platform").fs;
const pdir = @import("platform").dir;
const contract = @import("contract.zig");
const effect_scope = @import("effect_scope.zig");
const manifest = @import("manifest.zig");
const process_plugin = @import("process.zig");
const tool_catalog = @import("../core/tool_catalog.zig");
const tool_context = @import("../tools/context.zig");
const tools_mod = @import("../tools.zig");
const skill_catalog = @import("../skills/runtime/catalog.zig");
const dialect_mod = @import("../api/dialect.zig");

pub const Error = process_plugin.Error || effect_scope.Error || error{
    InvalidPackageRoot,
    PackageRootSymlink,
    PackageManifestMissing,
    PackageManifestUntrusted,
    PackageManifestTooLarge,
    InvalidManifest,
    UnsupportedSchema,
    UnsupportedCapability,
    UnsupportedHostCapability,
    InvalidPluginForm,
    ReservedPluginId,
    DuplicatePluginAtLayer,
    MissingDependency,
    IncompatibleDependency,
    DependencyCycle,
    MissingContributionDirectory,
    ContributionDirectorySymlink,
    InvalidStaticTool,
    InvalidBuiltinTool,
    InvalidProviderDialect,
    UnsupportedContribution,
    DuplicateToolName,
    DuplicateProviderDialect,
    TooManyPlugins,
};

pub const MAX_PLUGIN_CANDIDATES: usize = 128;

pub const Layer = enum(u8) {
    builtin = 10,
    personal = 20,
    project = 30,
    session = 40,
    managed = 50,

    pub fn priority(self: Layer) u32 {
        return @as(u32, @intFromEnum(self)) * 10;
    }
};

pub const PackageSource = struct {
    root: []const u8,
    layer: Layer,
};

/// `tool.definition.name` is a local name. Snapshot creation publishes the
/// collision-free provider name `<encoded-plugin-id>__<local>`.
pub const StaticPlugin = struct {
    descriptor: contract.Descriptor,
    layer: Layer = .builtin,
    tools: []const tool_catalog.HostSyncTool = &.{},
    /// First-party native tools keep their original global provider names and
    /// builtin executor/category. Only a static trusted descriptor carrying
    /// `builtin_tool_bundle` may publish these names.
    builtin_tools: []const []const u8 = &.{},
    /// Runtime-scoped wire/model dialects below an existing Provider
    /// transport. Prefix matching is longest-first; exact duplicate
    /// `{provider_kind, model_prefix}` keys fail snapshot staging.
    provider_dialects: []const ProviderDialect = &.{},
    /// Monotonic, synchronous execution ceiling. `true` only lets the native
    /// permission/formal pipeline continue; it can never grant authority.
    advisory_policy: ?tool_context.ToolExecutionPolicy = null,
    /// Optional trusted-code activation. It runs only against a staging
    /// Snapshot and may register reverse-order cleanup with its EffectScope.
    activation: ?effect_scope.StaticActivation = null,
};

pub const ProviderDialect = struct {
    provider_kind: dialect_mod.ProviderKind,
    model_prefix: []const u8,
    /// Every callback must be a deterministic function of its explicit inputs.
    /// Runtime generation/plugin metadata must never enter provider bytes.
    dialect: dialect_mod.Dialect,
};

pub const ProviderDialectBinding = struct {
    provider_kind: dialect_mod.ProviderKind,
    model_prefix: []const u8,
    dialect: dialect_mod.Dialect,
    plugin_id: []const u8,
};

pub const Config = struct {
    generation: contract.GenerationId,
    supported_capabilities: contract.CapabilitySet,
    /// Legacy AgentRuntime host tools become one explicit builtin compatibility
    /// contribution and retain their existing global names.
    compatibility_host_tools: []const tool_catalog.HostSyncTool = &.{},
    static_plugins: []const StaticPlugin = &.{},
    /// Executable authority is a distinct loading channel. A data package can
    /// never promote itself to this form through manifest contents.
    process_packages: []const PackageSource = &.{},
    packages: []const PackageSource = &.{},
};

pub const PluginRecord = struct {
    descriptor: contract.Descriptor,
    layer: Layer,
    root: ?[]const u8,
    lifecycle: contract.LifecycleState = .active,
    contribution_count: usize,
};

pub const AgentSource = struct {
    root: []const u8,
    namespace: []const u8,
    plugin_id: []const u8,
    priority: u32,
};

const CandidateKind = union(enum) {
    compatibility,
    static: usize,
    data_package,
    process_package,
};

const Candidate = struct {
    descriptor: contract.Descriptor,
    layer: Layer,
    root: ?[]const u8,
    kind: CandidateKind,
};

const DependencyMark = enum { unseen, visiting, complete };

pub const Snapshot = struct {
    owner_allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    effects: *effect_scope.Scope,
    generation: contract.GenerationId,
    plugins: []PluginRecord,
    host_tools: []tool_catalog.HostSyncTool,
    builtin_tools: []const []const u8,
    process_tools: []tool_catalog.IsolatedTool,
    advisory_policies: []tool_context.ToolExecutionPolicy,
    provider_dialects: []ProviderDialectBinding,
    skill_sources: []skill_catalog.Source,
    agent_sources: []AgentSource,

    pub fn create(allocator: std.mem.Allocator, config: Config) Error!*Snapshot {
        const package_count = std.math.add(usize, config.packages.len, config.process_packages.len) catch
            return error.TooManyPlugins;
        const explicit_count = std.math.add(usize, config.static_plugins.len, package_count) catch
            return error.TooManyPlugins;
        const candidate_count = std.math.add(
            usize,
            explicit_count,
            @intFromBool(config.compatibility_host_tools.len != 0),
        ) catch return error.TooManyPlugins;
        if (candidate_count > MAX_PLUGIN_CANDIDATES) return error.TooManyPlugins;
        const self = try allocator.create(Snapshot);
        errdefer allocator.destroy(self);
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = .init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const effects = try effect_scope.Scope.create(allocator);
        var effects_published = false;
        defer if (!effects_published) effects.destroy();

        var candidates: std.ArrayList(Candidate) = .empty;
        if (config.compatibility_host_tools.len != 0) {
            var caps: contract.CapabilitySet = .{};
            caps.insert(.host_tool) catch unreachable;
            try candidates.append(owned, .{
                .descriptor = .{
                    .id = try cloneId(owned, contract.PluginId.parse(COMPAT_PLUGIN_ID) catch unreachable),
                    .version = .{ .major = 1, .minor = 0, .patch = 0 },
                    .form = .static_trusted,
                    .capabilities = caps,
                },
                .layer = .builtin,
                .root = null,
                .kind = .compatibility,
            });
        }

        for (config.static_plugins, 0..) |plugin, index| {
            plugin.descriptor.validate() catch return error.InvalidManifest;
            if (plugin.descriptor.form != .static_trusted) return error.InvalidPluginForm;
            if (std.mem.eql(u8, plugin.descriptor.id.bytes, COMPAT_PLUGIN_ID)) return error.ReservedPluginId;
            try candidates.append(owned, .{
                .descriptor = try cloneDescriptor(owned, plugin.descriptor),
                .layer = plugin.layer,
                .root = null,
                .kind = .{ .static = index },
            });
        }

        for (config.packages) |package| {
            const canonical_root = try canonicalPackageRoot(owned, package.root);
            const bytes = try readManifest(owned, canonical_root);
            const descriptor = manifest.parse(arena, bytes) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.UnsupportedSchema => error.UnsupportedSchema,
                error.UnsupportedCapability => error.UnsupportedCapability,
                error.InvalidManifest => error.InvalidManifest,
            };
            if (std.mem.eql(u8, descriptor.id.bytes, COMPAT_PLUGIN_ID)) return error.ReservedPluginId;
            try candidates.append(owned, .{
                .descriptor = descriptor,
                .layer = package.layer,
                .root = canonical_root,
                .kind = .data_package,
            });
        }

        for (config.process_packages) |package| {
            const canonical_root = try canonicalPackageRoot(owned, package.root);
            const bytes = try readManifest(owned, canonical_root);
            const descriptor = manifest.parseForForm(arena, bytes, .out_of_process) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.UnsupportedSchema => error.UnsupportedSchema,
                error.UnsupportedCapability => error.UnsupportedCapability,
                error.InvalidManifest => error.InvalidManifest,
            };
            if (std.mem.eql(u8, descriptor.id.bytes, COMPAT_PLUGIN_ID)) return error.ReservedPluginId;
            try candidates.append(owned, .{
                .descriptor = descriptor,
                .layer = package.layer,
                .root = canonical_root,
                .kind = .process_package,
            });
        }

        std.mem.sort(Candidate, candidates.items, {}, candidateLessThan);
        const winners = try selectWinners(owned, candidates.items);
        for (winners) |candidate| {
            if (!candidate.descriptor.capabilities.isSubsetOf(config.supported_capabilities))
                return error.UnsupportedHostCapability;
        }
        const activation_order = try dependencyOrder(owned, winners);

        var records: std.ArrayList(PluginRecord) = .empty;
        var host_tools: std.ArrayList(tool_catalog.HostSyncTool) = .empty;
        var builtin_tools: std.ArrayList([]const u8) = .empty;
        var process_tools: std.ArrayList(tool_catalog.IsolatedTool) = .empty;
        var advisory_policies: std.ArrayList(tool_context.ToolExecutionPolicy) = .empty;
        var provider_dialects: std.ArrayList(ProviderDialectBinding) = .empty;
        var skill_sources: std.ArrayList(skill_catalog.Source) = .empty;
        var agent_sources: std.ArrayList(AgentSource) = .empty;

        for (winners) |candidate| {
            var contribution_count: usize = 0;
            switch (candidate.kind) {
                .compatibility => {
                    for (config.compatibility_host_tools) |tool| {
                        try validateHostTool(tool);
                        try appendUniqueHostTool(owned, &host_tools, try tool_catalog.cloneHostTool(owned, tool));
                        contribution_count += 1;
                    }
                },
                .static => |index| {
                    const plugin = config.static_plugins[index];
                    const static_projectors = contract.CapabilitySet.from(&.{ .host_tool, .advisory_hook, .service, .builtin_tool_bundle, .provider_dialect });
                    if (!candidate.descriptor.capabilities.isSubsetOf(static_projectors))
                        return error.UnsupportedContribution;
                    const contributes_tools = candidate.descriptor.capabilities.contains(.host_tool);
                    const contributes_advisory = candidate.descriptor.capabilities.contains(.advisory_hook);
                    const contributes_services = candidate.descriptor.capabilities.contains(.service);
                    const contributes_builtins = candidate.descriptor.capabilities.contains(.builtin_tool_bundle);
                    const contributes_dialects = candidate.descriptor.capabilities.contains(.provider_dialect);
                    if (contributes_tools != (plugin.tools.len != 0)) return error.UnsupportedContribution;
                    if (contributes_builtins != (plugin.builtin_tools.len != 0)) return error.UnsupportedContribution;
                    if (contributes_advisory != (plugin.advisory_policy != null)) return error.UnsupportedContribution;
                    if (contributes_dialects != (plugin.provider_dialects.len != 0)) return error.UnsupportedContribution;
                    if (contributes_services and plugin.activation == null) return error.UnsupportedContribution;
                    if (contributes_tools) {
                        for (plugin.tools) |tool| {
                            try validateHostTool(tool);
                            const global_name = contract.toolName(owned, candidate.descriptor.id, tool.definition.name) catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                                else => return error.InvalidStaticTool,
                            };
                            var owned_tool = try tool_catalog.cloneHostTool(owned, tool);
                            owned_tool.definition.name = global_name;
                            try appendUniqueHostTool(owned, &host_tools, owned_tool);
                            contribution_count += 1;
                        }
                    }
                    if (contributes_builtins) {
                        for (plugin.builtin_tools) |name| {
                            if (tools_mod.getTool(name) == null) return error.InvalidBuiltinTool;
                            for (builtin_tools.items) |existing| {
                                if (std.mem.eql(u8, existing, name)) return error.DuplicateToolName;
                            }
                            try builtin_tools.append(owned, try owned.dupe(u8, name));
                            contribution_count += 1;
                        }
                    }
                    if (plugin.advisory_policy) |policy| {
                        try advisory_policies.append(owned, policy);
                        contribution_count += 1;
                    }
                    if (contributes_dialects) {
                        for (plugin.provider_dialects) |provider_dialect| {
                            try validateAndAppendProviderDialect(
                                owned,
                                &provider_dialects,
                                candidate.descriptor.id.bytes,
                                provider_dialect,
                            );
                            contribution_count += 1;
                        }
                    }
                },
                .data_package => {
                    const root = candidate.root.?;
                    const namespace = try contract.toolNamespace(owned, candidate.descriptor.id);
                    var projected: contract.CapabilitySet = .{};
                    if (candidate.descriptor.capabilities.contains(.skill_bundle)) {
                        const skill_root = try contributionDirectory(owned, root, "skills");
                        try skill_sources.append(owned, .{
                            .root = skill_root,
                            .scope = .plugin,
                            .priority = candidate.layer.priority(),
                            .namespace = namespace,
                            .provider_id = candidate.descriptor.id.bytes,
                            .source_instance_id = try sourceInstanceId(owned, candidate.descriptor),
                        });
                        contribution_count += 1;
                        projected.insert(.skill_bundle) catch unreachable;
                    }
                    if (candidate.descriptor.capabilities.contains(.agent_bundle)) {
                        try agent_sources.append(owned, .{
                            .root = try contributionDirectory(owned, root, "agents"),
                            .namespace = namespace,
                            .plugin_id = candidate.descriptor.id.bytes,
                            .priority = candidate.layer.priority(),
                        });
                        contribution_count += 1;
                        projected.insert(.agent_bundle) catch unreachable;
                    }
                    if (projected.bits != candidate.descriptor.capabilities.bits)
                        return error.UnsupportedContribution;
                },
                .process_package => {
                    const staged = try process_plugin.stage(arena, candidate.root.?, candidate.descriptor);
                    for (staged.tools) |tool| {
                        try appendUniqueProcessTool(owned, &host_tools, &process_tools, tool);
                        contribution_count += 1;
                    }
                },
            }
            try records.append(owned, .{
                .descriptor = candidate.descriptor,
                .layer = candidate.layer,
                .root = candidate.root,
                .contribution_count = contribution_count,
            });
        }

        // Publication must be independent of candidate sort order. A process
        // tool already checks the host list when it is appended, but a later
        // compatibility/static contribution must not be able to introduce the
        // same provider-visible name after that check has run.
        try validateNoCrossChannelToolCollisions(host_tools.items, process_tools.items);
        try validateNoBuiltinToolCollisions(builtin_tools.items, host_tools.items, process_tools.items);

        // Finish every fallible projection/allocation before trusted activation.
        // If activation fails, `effects` rolls back all prior registrations and
        // the immutable Snapshot is never published.
        const published_plugins = try records.toOwnedSlice(owned);
        const published_host_tools = try host_tools.toOwnedSlice(owned);
        const published_builtin_tools = try builtin_tools.toOwnedSlice(owned);
        const published_process_tools = try process_tools.toOwnedSlice(owned);
        const published_advisory_policies = try advisory_policies.toOwnedSlice(owned);
        const published_provider_dialects = try provider_dialects.toOwnedSlice(owned);
        const published_skill_sources = try skill_sources.toOwnedSlice(owned);
        const published_agent_sources = try agent_sources.toOwnedSlice(owned);
        for (activation_order) |candidate_index| {
            const candidate = winners[candidate_index];
            switch (candidate.kind) {
                .static => |static_index| {
                    const before_services = effects.serviceCountFor(candidate.descriptor.id.bytes);
                    if (config.static_plugins[static_index].activation) |activation| {
                        var registrar_value = try effects.registrar(
                            candidate.descriptor.id.bytes,
                            candidate.descriptor.dependencies,
                        );
                        try activation.activate(activation.ctx, &registrar_value);
                    }
                    const added_services = effects.serviceCountFor(candidate.descriptor.id.bytes) - before_services;
                    if (candidate.descriptor.capabilities.contains(.service)) {
                        if (added_services == 0) return error.UnsupportedContribution;
                        published_plugins[candidate_index].contribution_count += added_services;
                    } else if (added_services != 0) {
                        return error.UnsupportedContribution;
                    }
                },
                else => {},
            }
        }
        try effects.commit();

        self.* = .{
            .owner_allocator = allocator,
            .arena = arena,
            .effects = effects,
            .generation = config.generation,
            .plugins = published_plugins,
            .host_tools = published_host_tools,
            .builtin_tools = published_builtin_tools,
            .process_tools = published_process_tools,
            .advisory_policies = published_advisory_policies,
            .provider_dialects = published_provider_dialects,
            .skill_sources = published_skill_sources,
            .agent_sources = published_agent_sources,
        };
        effects_published = true;
        return self;
    }

    pub fn destroy(self: *Snapshot) void {
        const owner = self.owner_allocator;
        self.effects.destroy();
        self.arena.deinit();
        owner.destroy(self.arena);
        self.* = undefined;
        owner.destroy(self);
    }

    pub fn find(self: *const Snapshot, id: []const u8) ?*const PluginRecord {
        for (self.plugins) |*record| if (std.mem.eql(u8, record.descriptor.id.bytes, id)) return record;
        return null;
    }

    /// Intersection of every active static advisory hook. The returned view is
    /// borrowed from this immutable Snapshot and remains valid until destroy.
    pub fn executionPolicy(self: *const Snapshot) ?tool_context.ToolExecutionPolicy {
        if (self.advisory_policies.len == 0) return null;
        return .{
            .ctx = @ptrCast(self),
            .allowsToolFn = allowsToolAdapter,
            .allowsInvocationFn = allowsInvocationAdapter,
        };
    }

    /// Borrowed immutable resolver pinned to this Snapshot generation.
    /// Provider clients keep the cheap value; `Runtime` retention guarantees
    /// the Snapshot and every static dialect ctx outlive those clients.
    pub fn dialectResolver(self: *const Snapshot) dialect_mod.Resolver {
        return .{ .ctx = @ptrCast(self), .resolveFn = resolveDialectAdapter };
    }

    fn resolveDialectAdapter(raw: *const anyopaque, kind: dialect_mod.ProviderKind, model: []const u8) dialect_mod.Dialect {
        const self: *const Snapshot = @ptrCast(@alignCast(raw));
        var best: ?*const ProviderDialectBinding = null;
        for (self.provider_dialects) |*binding| {
            if (binding.provider_kind != kind or !std.mem.startsWith(u8, model, binding.model_prefix)) continue;
            if (best == null or binding.model_prefix.len > best.?.model_prefix.len) best = binding;
        }
        return if (best) |binding| binding.dialect else dialect_mod.dialectFor(kind, model);
    }

    fn allowsToolAdapter(raw: *const anyopaque, name: []const u8) bool {
        const self: *const Snapshot = @ptrCast(@alignCast(raw));
        for (self.advisory_policies) |policy| {
            if (!policy.allowsTool(name)) return false;
        }
        return true;
    }

    fn allowsInvocationAdapter(raw: *const anyopaque, name: []const u8, arguments_json: []const u8) bool {
        const self: *const Snapshot = @ptrCast(@alignCast(raw));
        for (self.advisory_policies) |policy| {
            if (!policy.allowsInvocation(name, arguments_json)) return false;
        }
        return true;
    }

    /// Stable Host-facing inventory. It intentionally exposes immutable
    /// provenance/configuration only—never callback contexts, mutable kernel
    /// state, credentials, Conversation, permissions, or TinyKG handles.
    pub fn describe(self: *const Snapshot, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try writeInventory(&out.writer, self);
        return try out.toOwnedSlice();
    }
};

pub fn emptyInventory(allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    return allocator.dupe(
        u8,
        "{\"schema\":\"metacodes.plugin-inventory/v1\",\"contract_version\":1,\"generation\":0,\"plugins\":[]}",
    );
}

fn writeInventory(writer: *std.Io.Writer, snapshot: *const Snapshot) !void {
    try writer.print(
        "{{\"schema\":\"metacodes.plugin-inventory/v1\",\"contract_version\":{d},\"generation\":{d},\"plugins\":[",
        .{ contract.CONTRACT_VERSION, @intFromEnum(snapshot.generation) },
    );
    for (snapshot.plugins, 0..) |record, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":");
        try std.json.Stringify.encodeJsonString(record.descriptor.id.bytes, .{}, writer);
        try writer.writeAll(",\"version\":");
        try writeVersion(writer, record.descriptor.version);
        try writer.writeAll(",\"form\":");
        try std.json.Stringify.encodeJsonString(@tagName(record.descriptor.form), .{}, writer);
        try writer.writeAll(",\"layer\":");
        try std.json.Stringify.encodeJsonString(@tagName(record.layer), .{}, writer);
        try writer.writeAll(",\"lifecycle\":");
        try std.json.Stringify.encodeJsonString(@tagName(record.lifecycle), .{}, writer);
        try writer.writeAll(",\"capabilities\":[");
        var capability_index: usize = 0;
        inline for (std.meta.fields(contract.Capability)) |field| {
            const capability: contract.Capability = @enumFromInt(field.value);
            if (record.descriptor.capabilities.contains(capability)) {
                if (capability_index != 0) try writer.writeByte(',');
                try std.json.Stringify.encodeJsonString(field.name, .{}, writer);
                capability_index += 1;
            }
        }
        try writer.print(
            "],\"contribution_count\":{d},\"source_root\":",
            .{record.contribution_count},
        );
        if (record.root) |root| {
            try std.json.Stringify.encodeJsonString(root, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

fn writeVersion(writer: *std.Io.Writer, version: contract.Version) !void {
    try writer.writeByte('"');
    try writer.print("{d}.{d}.{d}", .{ version.major, version.minor, version.patch });
    if (version.prerelease.len != 0) try writer.print("-{s}", .{version.prerelease});
    if (version.build.len != 0) try writer.print("+{s}", .{version.build});
    try writer.writeByte('"');
}

const COMPAT_PLUGIN_ID = "metacodes.host-compat";

fn cloneId(allocator: std.mem.Allocator, id: contract.PluginId) !contract.PluginId {
    return .{ .bytes = try allocator.dupe(u8, id.bytes) };
}

fn cloneVersion(allocator: std.mem.Allocator, version: contract.Version) !contract.Version {
    return .{
        .major = version.major,
        .minor = version.minor,
        .patch = version.patch,
        .prerelease = try allocator.dupe(u8, version.prerelease),
        .build = try allocator.dupe(u8, version.build),
    };
}

fn cloneDescriptor(allocator: std.mem.Allocator, descriptor: contract.Descriptor) !contract.Descriptor {
    const dependencies = try allocator.alloc(contract.Dependency, descriptor.dependencies.len);
    for (descriptor.dependencies, 0..) |dependency, index| {
        dependencies[index] = .{
            .id = try cloneId(allocator, dependency.id),
            .minimum = try cloneVersion(allocator, dependency.minimum),
        };
    }
    return .{
        .id = try cloneId(allocator, descriptor.id),
        .version = try cloneVersion(allocator, descriptor.version),
        .form = descriptor.form,
        .capabilities = descriptor.capabilities,
        .dependencies = dependencies,
    };
}

fn candidateLessThan(_: void, lhs: Candidate, rhs: Candidate) bool {
    const id_order = std.mem.order(u8, lhs.descriptor.id.bytes, rhs.descriptor.id.bytes);
    if (id_order != .eq) return id_order == .lt;
    if (@intFromEnum(lhs.layer) != @intFromEnum(rhs.layer))
        return @intFromEnum(lhs.layer) > @intFromEnum(rhs.layer);
    const lhs_root = lhs.root orelse "";
    const rhs_root = rhs.root orelse "";
    return std.mem.lessThan(u8, lhs_root, rhs_root);
}

fn selectWinners(allocator: std.mem.Allocator, sorted: []const Candidate) Error![]Candidate {
    var winners: std.ArrayList(Candidate) = .empty;
    var cursor: usize = 0;
    while (cursor < sorted.len) {
        const start = cursor;
        const id = sorted[start].descriptor.id.bytes;
        while (cursor < sorted.len and std.mem.eql(u8, sorted[cursor].descriptor.id.bytes, id)) : (cursor += 1) {}
        if (cursor - start > 1 and sorted[start].layer == sorted[start + 1].layer)
            return error.DuplicatePluginAtLayer;
        try winners.append(allocator, sorted[start]);
    }
    return winners.toOwnedSlice(allocator);
}

fn dependencyOrder(allocator: std.mem.Allocator, candidates: []const Candidate) Error![]usize {
    for (candidates) |candidate| {
        for (candidate.descriptor.dependencies) |dependency| {
            const target = findCandidate(candidates, dependency.id.bytes) orelse return error.MissingDependency;
            if (!target.descriptor.version.satisfies(dependency.minimum)) return error.IncompatibleDependency;
        }
    }
    const marks = try allocator.alloc(DependencyMark, candidates.len);
    defer allocator.free(marks);
    @memset(marks, .unseen);
    var order: std.ArrayList(usize) = .empty;
    errdefer order.deinit(allocator);
    for (candidates, 0..) |_, index| try visitDependency(candidates, marks, index, &order, allocator);
    return order.toOwnedSlice(allocator);
}

fn visitDependency(
    candidates: []const Candidate,
    marks: []DependencyMark,
    index: usize,
    order: *std.ArrayList(usize),
    allocator: std.mem.Allocator,
) Error!void {
    switch (marks[index]) {
        .complete => return,
        .visiting => return error.DependencyCycle,
        .unseen => {},
    }
    marks[index] = .visiting;
    for (candidates[index].descriptor.dependencies) |dependency| {
        const dependency_index = findCandidateIndex(candidates, dependency.id.bytes) orelse return error.MissingDependency;
        try visitDependency(candidates, marks, dependency_index, order, allocator);
    }
    marks[index] = .complete;
    try order.append(allocator, index);
}

fn findCandidate(candidates: []const Candidate, id: []const u8) ?*const Candidate {
    const index = findCandidateIndex(candidates, id) orelse return null;
    return &candidates[index];
}

fn findCandidateIndex(candidates: []const Candidate, id: []const u8) ?usize {
    for (candidates, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate.descriptor.id.bytes, id)) return index;
    }
    return null;
}

fn canonicalPackageRoot(allocator: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    if (!std.fs.path.isAbsolute(raw) or raw.len >= std.fs.max_path_bytes) return error.InvalidPackageRoot;
    const raw_z = try allocator.dupeZ(u8, raw);
    if (pfs.isSymlink(raw_z.ptr)) return error.PackageRootSymlink;
    var resolved: [std.fs.max_path_bytes]u8 = undefined;
    const pointer = pfs.realpath(raw_z.ptr, &resolved) orelse return error.InvalidPackageRoot;
    return allocator.dupe(u8, std.mem.span(pointer));
}

fn readManifest(allocator: std.mem.Allocator, root: []const u8) Error![]const u8 {
    const meta_dir = try std.fmt.allocPrint(allocator, "{s}/.metacodes-plugin", .{root});
    const meta_dir_z = try allocator.dupeZ(u8, meta_dir);
    if (pfs.isSymlink(meta_dir_z.ptr)) return error.PackageManifestUntrusted;
    var dir = pdir.open(meta_dir_z.ptr) orelse return error.PackageManifestMissing;
    pdir.close(&dir);

    const path = try std.fmt.allocPrint(allocator, "{s}/plugin.json", .{meta_dir});
    const path_z = try allocator.dupeZ(u8, path);
    if (pfs.isSymlink(path_z.ptr)) return error.PackageManifestUntrusted;
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.PackageManifestMissing;
    defer pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.PackageManifestUntrusted;
    if (!before.is_regular or before.size == 0 or before.size > manifest.MAX_MANIFEST_BYTES)
        return error.PackageManifestTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.readZ(fd, bytes[offset..]) catch return error.PackageManifestUntrusted;
        if (count == 0) return error.PackageManifestUntrusted;
        offset += count;
    }
    var probe: [1]u8 = undefined;
    if ((pfs.readZ(fd, &probe) catch return error.PackageManifestUntrusted) != 0)
        return error.PackageManifestUntrusted;
    const after = pfs.fileInfo(fd) catch return error.PackageManifestUntrusted;
    if (after.device != before.device or after.inode != before.inode or after.size != before.size)
        return error.PackageManifestUntrusted;
    return bytes;
}

fn contributionDirectory(allocator: std.mem.Allocator, root: []const u8, name: []const u8) Error![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, name });
    const path_z = try allocator.dupeZ(u8, path);
    if (pfs.isSymlink(path_z.ptr)) return error.ContributionDirectorySymlink;
    var dir = pdir.open(path_z.ptr) orelse return error.MissingContributionDirectory;
    pdir.close(&dir);
    return path;
}

fn sourceInstanceId(allocator: std.mem.Allocator, descriptor: contract.Descriptor) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}@{d}.{d}.{d}", .{
        descriptor.id.bytes,
        descriptor.version.major,
        descriptor.version.minor,
        descriptor.version.patch,
    });
}

fn validateHostTool(tool: tool_catalog.HostSyncTool) Error!void {
    if (tool.definition.name.len == 0 or
        !std.mem.eql(u8, tool.definition.input_schema.type, "object") or
        tool.definition.server_type != null or tool.definition.deferred)
        return error.InvalidStaticTool;
}

fn validateAndAppendProviderDialect(
    allocator: std.mem.Allocator,
    dialects: *std.ArrayList(ProviderDialectBinding),
    plugin_id: []const u8,
    candidate: ProviderDialect,
) Error!void {
    if (candidate.provider_kind == .other or
        candidate.model_prefix.len == 0 or
        candidate.model_prefix.len > 128 or
        !std.unicode.utf8ValidateSlice(candidate.model_prefix))
        return error.InvalidProviderDialect;
    for (dialects.items) |existing| {
        if (existing.provider_kind == candidate.provider_kind and
            std.mem.eql(u8, existing.model_prefix, candidate.model_prefix))
            return error.DuplicateProviderDialect;
    }
    try dialects.append(allocator, .{
        .provider_kind = candidate.provider_kind,
        .model_prefix = try allocator.dupe(u8, candidate.model_prefix),
        .dialect = candidate.dialect,
        .plugin_id = try allocator.dupe(u8, plugin_id),
    });
}

fn appendUniqueHostTool(
    allocator: std.mem.Allocator,
    tools: *std.ArrayList(tool_catalog.HostSyncTool),
    candidate: tool_catalog.HostSyncTool,
) Error!void {
    for (tools.items) |existing| {
        if (std.mem.eql(u8, existing.definition.name, candidate.definition.name))
            return error.DuplicateToolName;
    }
    try tools.append(allocator, candidate);
}

fn appendUniqueProcessTool(
    allocator: std.mem.Allocator,
    host_tools: *const std.ArrayList(tool_catalog.HostSyncTool),
    process_tools: *std.ArrayList(tool_catalog.IsolatedTool),
    candidate: tool_catalog.IsolatedTool,
) Error!void {
    for (host_tools.items) |existing| {
        if (std.mem.eql(u8, existing.definition.name, candidate.definition.name))
            return error.DuplicateToolName;
    }
    for (process_tools.items) |existing| {
        if (std.mem.eql(u8, existing.definition.name, candidate.definition.name))
            return error.DuplicateToolName;
    }
    try process_tools.append(allocator, candidate);
}

fn validateNoCrossChannelToolCollisions(
    host_tools: []const tool_catalog.HostSyncTool,
    process_tools: []const tool_catalog.IsolatedTool,
) Error!void {
    for (host_tools) |host_tool| {
        for (process_tools) |process_tool| {
            if (std.mem.eql(u8, host_tool.definition.name, process_tool.definition.name))
                return error.DuplicateToolName;
        }
    }
}

fn validateNoBuiltinToolCollisions(
    builtin_tools: []const []const u8,
    host_tools: []const tool_catalog.HostSyncTool,
    process_tools: []const tool_catalog.IsolatedTool,
) Error!void {
    for (builtin_tools) |builtin_name| {
        for (host_tools) |host_tool| {
            if (std.mem.eql(u8, builtin_name, host_tool.definition.name))
                return error.DuplicateToolName;
        }
        for (process_tools) |process_tool| {
            if (std.mem.eql(u8, builtin_name, process_tool.definition.name))
                return error.DuplicateToolName;
        }
    }
}

test "higher layer deterministically replaces a lower data package" {
    const low = Candidate{
        .descriptor = .{
            .id = try contract.PluginId.parse("acme.review"),
            .version = try contract.Version.parse("1.0.0"),
            .form = .data_package,
            .capabilities = contract.CapabilitySet.from(&.{.skill_bundle}),
        },
        .layer = .personal,
        .root = "/low",
        .kind = .data_package,
    };
    const high = Candidate{
        .descriptor = .{
            .id = try contract.PluginId.parse("acme.review"),
            .version = try contract.Version.parse("2.0.0"),
            .form = .data_package,
            .capabilities = contract.CapabilitySet.from(&.{.skill_bundle}),
        },
        .layer = .project,
        .root = "/high",
        .kind = .data_package,
    };
    var candidates = [_]Candidate{ low, high };
    std.mem.sort(Candidate, &candidates, {}, candidateLessThan);
    const winners = try selectWinners(std.testing.allocator, &candidates);
    defer std.testing.allocator.free(winners);
    try std.testing.expectEqual(@as(usize, 1), winners.len);
    try std.testing.expectEqualStrings("/high", winners[0].root.?);
}

test "dependency validation rejects missing incompatible and cyclic graphs" {
    const caps = contract.CapabilitySet.from(&.{.skill_bundle});
    const version = try contract.Version.parse("1.0.0");
    const id_a = try contract.PluginId.parse("acme.a");
    const id_b = try contract.PluginId.parse("acme.b");
    const requires_b = [_]contract.Dependency{.{ .id = id_b, .minimum = version }};
    const requires_a = [_]contract.Dependency{.{ .id = id_a, .minimum = version }};
    const a = Candidate{ .descriptor = .{ .id = id_a, .version = version, .form = .data_package, .capabilities = caps, .dependencies = &requires_b }, .layer = .project, .root = "/a", .kind = .data_package };
    const b = Candidate{ .descriptor = .{ .id = id_b, .version = version, .form = .data_package, .capabilities = caps, .dependencies = &requires_a }, .layer = .project, .root = "/b", .kind = .data_package };
    try std.testing.expectError(error.MissingDependency, dependencyOrder(std.testing.allocator, &.{a}));
    try std.testing.expectError(error.DependencyCycle, dependencyOrder(std.testing.allocator, &.{ a, b }));
}

test "snapshot rejects an unbounded plugin source set before filesystem access" {
    const sources = [_]PackageSource{.{ .root = "/not-read", .layer = .session }} ** (MAX_PLUGIN_CANDIDATES + 1);
    try std.testing.expectError(error.TooManyPlugins, Snapshot.create(std.testing.allocator, .{
        .generation = @enumFromInt(1),
        .supported_capabilities = contract.CapabilitySet.from(&.{.skill_bundle}),
        .packages = &sources,
    }));
}

fn builtinBundle(id: []const u8, names: []const []const u8) StaticPlugin {
    return .{
        .descriptor = .{
            .id = contract.PluginId.parse(id) catch unreachable,
            .version = .{ .major = 1, .minor = 0, .patch = 0 },
            .form = .static_trusted,
            .capabilities = contract.CapabilitySet.from(&.{.builtin_tool_bundle}),
        },
        .builtin_tools = names,
    };
}

test "static builtin bundle publishes native tools and inventory provenance" {
    const plugin = builtinBundle("acme.core", &.{ "Read", "Grep" });
    const snapshot = try Snapshot.create(std.testing.allocator, .{
        .generation = @enumFromInt(7),
        .supported_capabilities = contract.CapabilitySet.from(&.{.builtin_tool_bundle}),
        .static_plugins = &.{plugin},
    });
    defer snapshot.destroy();

    try std.testing.expectEqual(@as(usize, 2), snapshot.builtin_tools.len);
    try std.testing.expectEqualStrings("Read", snapshot.builtin_tools[0]);
    try std.testing.expectEqualStrings("Grep", snapshot.builtin_tools[1]);
    const record = snapshot.find("acme.core") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 2), record.contribution_count);
    const inventory = try snapshot.describe(std.testing.allocator);
    defer std.testing.allocator.free(inventory);
    try std.testing.expect(std.mem.indexOf(u8, inventory, "builtin_tool_bundle") != null);
    try std.testing.expect(std.mem.indexOf(u8, inventory, "\"generation\":7") != null);
}

test "static builtin bundle rejects unknown tools and declaration wiring drift" {
    const unknown = builtinBundle("acme.unknown", &.{"NotARealMetacodesTool"});
    try std.testing.expectError(error.InvalidBuiltinTool, Snapshot.create(std.testing.allocator, .{
        .generation = @enumFromInt(1),
        .supported_capabilities = contract.CapabilitySet.from(&.{.builtin_tool_bundle}),
        .static_plugins = &.{unknown},
    }));

    var missing_declaration = builtinBundle("acme.undeclared", &.{"Read"});
    missing_declaration.descriptor.capabilities = contract.CapabilitySet.from(&.{.host_tool});
    try std.testing.expectError(error.UnsupportedContribution, Snapshot.create(std.testing.allocator, .{
        .generation = @enumFromInt(1),
        .supported_capabilities = contract.CapabilitySet.from(&.{ .host_tool, .builtin_tool_bundle }),
        .static_plugins = &.{missing_declaration},
    }));

    const missing_payload = builtinBundle("acme.empty", &.{});
    try std.testing.expectError(error.UnsupportedContribution, Snapshot.create(std.testing.allocator, .{
        .generation = @enumFromInt(1),
        .supported_capabilities = contract.CapabilitySet.from(&.{.builtin_tool_bundle}),
        .static_plugins = &.{missing_payload},
    }));
}

test "static builtin bundles reject provider-visible name collisions" {
    const first = builtinBundle("acme.first", &.{"Read"});
    const second = builtinBundle("acme.second", &.{"Read"});
    try std.testing.expectError(error.DuplicateToolName, Snapshot.create(std.testing.allocator, .{
        .generation = @enumFromInt(1),
        .supported_capabilities = contract.CapabilitySet.from(&.{.builtin_tool_bundle}),
        .static_plugins = &.{ first, second },
    }));
}

test "provider dialect snapshot resolves longest prefix and rejects duplicate keys" {
    const broad = dialect_mod.Dialect{ .ctx = @ptrFromInt(@as(usize, 0x21)) };
    const specific = dialect_mod.Dialect{ .ctx = @ptrFromInt(@as(usize, 0x22)) };
    const caps = contract.CapabilitySet.from(&.{.provider_dialect});
    const first = StaticPlugin{
        .descriptor = .{
            .id = try contract.PluginId.parse("acme.dialects"),
            .version = try contract.Version.parse("1.0.0"),
            .form = .static_trusted,
            .capabilities = caps,
        },
        .provider_dialects = &.{
            .{ .provider_kind = .openai, .model_prefix = "acme-", .dialect = broad },
            .{ .provider_kind = .openai, .model_prefix = "acme-coder-", .dialect = specific },
        },
    };
    const snapshot = try Snapshot.create(std.testing.allocator, .{
        .generation = @enumFromInt(3),
        .supported_capabilities = caps,
        .static_plugins = &.{first},
    });
    defer snapshot.destroy();
    const resolved = snapshot.dialectResolver().resolve(.openai, "acme-coder-v2");
    try std.testing.expectEqual(@as(usize, 0x22), @intFromPtr(resolved.ctx));
    try std.testing.expectEqual(@as(usize, 2), snapshot.provider_dialects.len);

    const duplicate = StaticPlugin{
        .descriptor = .{
            .id = try contract.PluginId.parse("acme.duplicate"),
            .version = try contract.Version.parse("1.0.0"),
            .form = .static_trusted,
            .capabilities = caps,
        },
        .provider_dialects = &.{.{ .provider_kind = .openai, .model_prefix = "acme-", .dialect = specific }},
    };
    try std.testing.expectError(error.DuplicateProviderDialect, Snapshot.create(std.testing.allocator, .{
        .generation = @enumFromInt(4),
        .supported_capabilities = caps,
        .static_plugins = &.{ first, duplicate },
    }));
}
