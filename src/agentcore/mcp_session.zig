//! Session-filtered MCP view and immutable Run tool overlay.

const std = @import("std");
const core = @import("metacodes-core");
const catalog = @import("mcp_catalog.zig");
const canonical = @import("mcp_canonical.zig");
const runtime = @import("mcp_runtime.zig");
const schema = @import("mcp_schema.zig");
const session_permission = @import("session_permission.zig");

pub const MAX_MODEL_TOOL_NAME_BYTES: usize = catalog.MAX_MODEL_TOOL_NAME_BYTES;

pub const Selector = struct {
    server_binding_identity: [32]u8,
    tool_name: []const u8,
    /// Set only by checkpoint restore. Fresh Host selection uses null; a
    /// restored grant is invalidated if the current semantic schema changed.
    expected_schema_fingerprint: ?[32]u8 = null,
};

pub const BuildMode = enum {
    /// Explicit Host selection update: every selector must resolve and be
    /// fresh, otherwise the update is rejected atomically.
    fresh,
    /// Checkpoint restore: unavailable historical authority is invalidated.
    restore_degraded,
    /// Run admission: unavailable MCP tools shrink this Run's tool surface;
    /// they must never prevent the Conversation itself from running.
    run_tolerant,
};

pub const Error = error{
    OutOfMemory,
    InvalidSelection,
    NotRefreshed,
    ResourceLimit,
    AdmissionInvariantViolation,
};

pub const Entry = struct {
    server: *const catalog.ServerRecord,
    admitted: *const catalog.AdmittedTool,
    tool: *const canonical.Tool,
    model_name: []const u8,
    prepared: schema.PreparedTool,

    pub fn permissionIdentity(self: *const Entry) session_permission.ToolIdentity {
        return .{
            .namespace = .mcp,
            .name = self.tool.identity.name,
            .binding = self.tool.identity.permissionBinding(),
        };
    }

    /// Shared product rules historically match MCP names as
    /// `<server>__<tool>`. The model-facing alias is deliberately opaque, so
    /// AgentCore must project the canonical Session binding back into that
    /// matcher vocabulary instead of authorizing the alias itself.
    pub fn permissionRuleName(
        self: *const Entry,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "{s}__{s}",
            .{ self.server.namespace, self.tool.identity.name },
        ) catch error.OutOfMemory;
    }
};

/// Durable Session MCP authority. This owns only copied values; it never
/// retains a Runtime catalog generation or a live ServerInstance. A Run uses
/// `materialize` to resolve these selectors against the then-current catalog.
pub const Selection = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    selectors: []Selector,
    entries: []SelectedEntry,
    catalog_generation: u64,
    catalog_fingerprint: [32]u8,
    selection_fingerprint: [32]u8,
    invalidated: u32,

    pub const SelectedEntry = struct {
        server_binding_identity: [32]u8,
        schema_fingerprint: [32]u8,
        tool_name: []const u8,
        model_name: []const u8,
        namespace: []const u8,
        era: canonical.Era,

        pub fn permissionIdentity(self: SelectedEntry) session_permission.ToolIdentity {
            const identity = canonical.ToolIdentity{
                .server_binding_identity = self.server_binding_identity,
                .name = self.tool_name,
                .schema_fingerprint = self.schema_fingerprint,
            };
            return .{
                .namespace = .mcp,
                .name = self.tool_name,
                .binding = identity.permissionBinding(),
            };
        }
    };

    pub fn init(
        backing: std.mem.Allocator,
        source: *catalog.Snapshot,
        selectors: []const Selector,
        mode: BuildMode,
    ) Error!Selection {
        var view = try View.init(backing, source, selectors, mode);
        defer view.deinit();
        return fromView(backing, &view);
    }

    pub fn fromView(backing: std.mem.Allocator, view: *const View) Error!Selection {
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const a = arena.allocator();
        const selectors = a.alloc(Selector, view.entries.len) catch
            return error.OutOfMemory;
        const entries = a.alloc(SelectedEntry, view.entries.len) catch
            return error.OutOfMemory;
        for (view.entries, selectors, entries) |entry, *selector, *selected| {
            const tool_name = a.dupe(u8, entry.tool.identity.name) catch
                return error.OutOfMemory;
            selector.* = .{
                .server_binding_identity = entry.tool.identity.server_binding_identity,
                .tool_name = tool_name,
                .expected_schema_fingerprint = entry.tool.identity.schema_fingerprint,
            };
            selected.* = .{
                .server_binding_identity = entry.tool.identity.server_binding_identity,
                .schema_fingerprint = entry.tool.identity.schema_fingerprint,
                .tool_name = tool_name,
                .model_name = a.dupe(u8, entry.model_name) catch
                    return error.OutOfMemory,
                .namespace = a.dupe(u8, entry.server.namespace) catch
                    return error.OutOfMemory,
                .era = entry.server.era,
            };
        }
        return .{
            .allocator = backing,
            .arena = arena,
            .selectors = selectors,
            .entries = entries,
            .catalog_generation = view.catalog_generation,
            .catalog_fingerprint = view.catalog_fingerprint,
            .selection_fingerprint = view.selection_fingerprint,
            .invalidated = view.invalidated,
        };
    }

    pub fn deinit(self: *Selection) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn materialize(
        self: *const Selection,
        backing: std.mem.Allocator,
        source: *catalog.Snapshot,
    ) Error!View {
        return View.init(backing, source, self.selectors, .run_tolerant);
    }

    pub fn findCanonicalTool(
        self: *const Selection,
        binding: *const [32]u8,
        name: []const u8,
    ) ?*const SelectedEntry {
        for (self.entries) |*entry|
            if (std.mem.eql(u8, &entry.server_binding_identity, binding) and
                std.mem.eql(u8, entry.tool_name, name)) return entry;
        return null;
    }
};

/// One Skill metadata layer. Slices borrow the immutable Skill catalog
/// snapshot retained by the admitted Run.
pub const SkillRestriction = struct {
    allowed: []const []const u8,
    disallowed: []const []const u8,
};

pub const View = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    snapshot: *catalog.Snapshot,
    entries: []Entry,
    catalog_generation: u64,
    catalog_fingerprint: [32]u8,
    selection_fingerprint: [32]u8,
    invalidated: u32,

    pub fn init(
        backing: std.mem.Allocator,
        source: *catalog.Snapshot,
        selectors: []const Selector,
        mode: BuildMode,
    ) Error!View {
        if (selectors.len > (canonical.Limits{}).max_tools)
            return error.ResourceLimit;
        const retained = source.retain() catch return error.ResourceLimit;
        errdefer retained.release();
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const a = arena.allocator();
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(a);
        errdefer for (entries.items) |*entry| entry.prepared.deinit();
        var invalidated: u32 = 0;

        for (selectors, 0..) |selector, index| {
            for (selectors[0..index]) |previous| {
                if (std.mem.eql(u8, &previous.server_binding_identity, &selector.server_binding_identity) and
                    std.mem.eql(u8, previous.tool_name, selector.tool_name))
                    return error.InvalidSelection;
            }
            const resolved = retained.findTool(
                &selector.server_binding_identity,
                selector.tool_name,
            ) orelse {
                if (mode == .fresh) return error.InvalidSelection;
                invalidated += 1;
                continue;
            };
            if (!resolved.server.isFreshAt(retained.now())) {
                if (mode == .fresh) return error.NotRefreshed;
                invalidated += 1;
                continue;
            }
            if (selector.expected_schema_fingerprint) |expected| {
                if (!std.mem.eql(u8, &expected, &resolved.admitted.canonical.identity.schema_fingerprint)) {
                    if (mode == .fresh) return error.InvalidSelection;
                    invalidated += 1;
                    continue;
                }
            }
            const model_name = resolved.admitted.model_name;
            for (entries.items) |entry| if (std.mem.eql(u8, entry.model_name, model_name))
                return error.InvalidSelection;
            // `arena` is moved by value into the returned View. A child arena
            // must therefore use the stable caller-provided backing allocator,
            // not `a`, whose allocator pointer refers to this stack-local arena
            // value before that move.
            const prepared = catalog.materializeAdmittedTool(
                backing,
                resolved.admitted,
                resolved.server.protocol_limits,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.AdmissionInvariantViolation => return error.AdmissionInvariantViolation,
            };
            entries.append(a, .{
                .server = resolved.server,
                .admitted = resolved.admitted,
                .tool = &resolved.admitted.canonical,
                .model_name = model_name,
                .prepared = prepared,
            }) catch {
                var cleanup = prepared;
                cleanup.deinit();
                return error.OutOfMemory;
            };
        }
        // Compute every fallible derived value while `entries` still owns the
        // prepared schemas, so errdefer can release them on allocation failure.
        const selection_fingerprint = selectionFingerprint(backing, entries.items) catch
            return error.OutOfMemory;
        const owned_entries = entries.toOwnedSlice(a) catch return error.OutOfMemory;
        return .{
            .allocator = backing,
            .arena = arena,
            .snapshot = retained,
            .entries = owned_entries,
            .catalog_generation = retained.generation,
            .catalog_fingerprint = retained.fingerprint,
            .selection_fingerprint = selection_fingerprint,
            .invalidated = invalidated,
        };
    }

    pub fn deinit(self: *View) void {
        for (self.entries) |*entry| entry.prepared.deinit();
        self.snapshot.release();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn findModelTool(self: *const View, model_name: []const u8) ?*const Entry {
        for (self.entries) |*entry|
            if (std.mem.eql(u8, entry.model_name, model_name)) return entry;
        return null;
    }

    pub fn findCanonicalTool(
        self: *const View,
        binding: *const [32]u8,
        name: []const u8,
    ) ?*const Entry {
        for (self.entries) |*entry|
            if (std.mem.eql(u8, &entry.tool.identity.server_binding_identity, binding) and
                std.mem.eql(u8, entry.tool.identity.name, name)) return entry;
        return null;
    }

    pub fn validatesInvocation(
        self: *const View,
        model_name: []const u8,
        arguments_json: []const u8,
    ) bool {
        return self.validateInvocation(model_name, arguments_json) == .valid;
    }

    pub fn validateInvocation(
        self: *const View,
        model_name: []const u8,
        arguments_json: []const u8,
    ) schema.Validation {
        const entry = self.findModelTool(model_name) orelse
            return .{ .invalid = .not_object };
        return schema.validateArguments(
            self.allocator,
            arguments_json,
            schema.Limits.fromProtocol(entry.server.protocol_limits),
        );
    }

    /// Evaluate Skill MCP rules against canonical server/tool identity. The
    /// provider alias is never a policy identity. Every layer intersects its
    /// parent: a non-empty allow list must explicitly select this MCP tool,
    /// while any matching deny removes it.
    pub fn allowsSkillRestrictions(
        self: *const View,
        model_name: []const u8,
        restrictions: []const SkillRestriction,
    ) bool {
        const entry = self.findModelTool(model_name) orelse return false;
        return allowsEntrySkillRestrictions(entry, restrictions);
    }
};

fn allowsEntrySkillRestrictions(
    entry: *const Entry,
    restrictions: []const SkillRestriction,
) bool {
    for (restrictions) |restriction| {
        if (restriction.allowed.len != 0 and
            !anyMcpRuleMatches(restriction.allowed, entry))
            return false;
        if (anyMcpRuleMatches(restriction.disallowed, entry)) return false;
    }
    return true;
}

pub const Environment = struct {
    allocator: std.mem.Allocator,
    view: *const View,
    base_definitions: []const core.json.ToolDefinition,
    base_dispatcher: core.tools.ToolDispatcher,
    base_policy: ?core.tools.ToolExecutionPolicy,
    skill_restrictions: []const SkillRestriction,
    entries: []const *const Entry,
    definitions: []core.json.ToolDefinition,

    pub fn init(
        allocator: std.mem.Allocator,
        view: *const View,
        base_definitions: []const core.json.ToolDefinition,
        base_dispatcher: core.tools.ToolDispatcher,
        base_policy: ?core.tools.ToolExecutionPolicy,
    ) Error!Environment {
        return initRestricted(
            allocator,
            view,
            base_definitions,
            base_dispatcher,
            base_policy,
            &.{},
        );
    }

    pub fn initRestricted(
        allocator: std.mem.Allocator,
        view: *const View,
        base_definitions: []const core.json.ToolDefinition,
        base_dispatcher: core.tools.ToolDispatcher,
        base_policy: ?core.tools.ToolExecutionPolicy,
        skill_restrictions: []const SkillRestriction,
    ) Error!Environment {
        const admitted_at_ns = view.snapshot.now();
        var admitted: std.ArrayList(*const Entry) = .empty;
        defer admitted.deinit(allocator);
        for (view.entries) |*entry| {
            if (!entry.server.isFreshAt(admitted_at_ns)) continue;
            admitted.append(allocator, entry) catch return error.OutOfMemory;
        }
        const entries = admitted.toOwnedSlice(allocator) catch return error.OutOfMemory;
        errdefer allocator.free(entries);
        const definitions = allocator.alloc(
            core.json.ToolDefinition,
            base_definitions.len + entries.len,
        ) catch return error.OutOfMemory;
        @memcpy(definitions[0..base_definitions.len], base_definitions);
        for (entries, definitions[base_definitions.len..]) |entry, *definition|
            definition.* = entry.prepared.definition;
        return .{
            .allocator = allocator,
            .view = view,
            .base_definitions = base_definitions,
            .base_dispatcher = base_dispatcher,
            .base_policy = base_policy,
            .skill_restrictions = skill_restrictions,
            .entries = entries,
            .definitions = definitions,
        };
    }

    pub fn deinit(self: *Environment) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.definitions);
        self.* = undefined;
    }

    pub fn findModelTool(self: *const Environment, name: []const u8) ?*const Entry {
        for (self.entries) |entry|
            if (std.mem.eql(u8, entry.model_name, name)) return entry;
        return null;
    }

    pub fn validatesInvocation(
        self: *const Environment,
        name: []const u8,
        arguments_json: []const u8,
    ) bool {
        return self.validateInvocation(name, arguments_json) == .valid;
    }

    pub fn validateInvocation(
        self: *const Environment,
        name: []const u8,
        arguments_json: []const u8,
    ) schema.Validation {
        const entry = self.findModelTool(name) orelse
            return .{ .invalid = .not_object };
        return schema.validateArguments(
            self.allocator,
            arguments_json,
            schema.Limits.fromProtocol(entry.server.protocol_limits),
        );
    }

    pub fn surface(self: *const Environment) core.agent_session.RunToolSurface {
        return .{ .definitions = self.definitions, .dispatcher = self.dispatcher() };
    }

    pub fn executionPolicy(self: *const Environment) core.tools.ToolExecutionPolicy {
        return .{
            .ctx = self,
            .allowsToolFn = allowsTool,
            .allowsInvocationFn = allowsInvocation,
        };
    }

    fn dispatcher(self: *const Environment) core.tools.ToolDispatcher {
        return .{
            .ctx = self,
            .dispatchFn = dispatch,
            .metadataFn = metadata,
            .nameAtFn = nameAt,
        };
    }

    const ResolvedTool = union(enum) {
        mcp: *const Entry,
        base,
    };

    fn resolveTool(self: *const Environment, name: []const u8) ResolvedTool {
        if (self.findModelTool(name)) |entry| return .{ .mcp = entry };
        return .base;
    }

    fn dispatch(
        raw: *const anyopaque,
        tool_ctx: *const core.tool_context.ToolContext,
        name: []const u8,
        arguments_json: []const u8,
    ) anyerror!core.tools.ToolDispatchOutcome {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        const entry = switch (self.resolveTool(name)) {
            .mcp => |entry| entry,
            .base => return self.base_dispatcher.dispatch(tool_ctx, name, arguments_json),
        };
        switch (self.validateInvocation(name, arguments_json)) {
            .valid => {},
            .invalid => |issue| switch (issue) {
                .resource_limit => return error.ResourceLimit,
                .invalid_json, .not_object => return .{ .host_rejected = try tool_ctx.allocator.dupe(u8, "MCP arguments must be a valid JSON object") },
            },
            .out_of_memory => return error.OutOfMemory,
        }
        const cancellation = runtime.Cancellation{
            .ctx = if (tool_ctx.abort) |abort| abort else null,
            .is_cancelled_fn = abortAdapter,
        };
        var instance = self.view.snapshot.retainInstance(
            entry.server.instance_id,
        ) catch |err| return .{ .host_failed = try encodeFailure(
            tool_ctx.allocator,
            switch (err) {
                error.InstanceUnavailable => .instance_unavailable,
                error.ResourceLimit => .resource_limit,
                error.OutOfMemory => .out_of_memory,
            },
        ) };
        defer instance.deinit();
        const outcome = instance.client().callToolBody(
            tool_ctx.allocator,
            tool_ctx.artifact_root,
            entry.tool,
            arguments_json,
            cancellation,
        );
        return switch (outcome) {
            .result => |body| .{ .ok = body },
            .failed => |failure| switch (failure) {
                .out_of_memory => error.OutOfMemory,
                else => .{ .host_failed = try encodeFailure(tool_ctx.allocator, failure) },
            },
        };
    }

    /// The same resolution `dispatch` performs, answered once for every
    /// metadata query. A Session MCP tool is a remote connector call: it is
    /// executable authority (`.execute`, never a weaker self-classification),
    /// non-builtin/non-host by kind (kind `.external` keeps isHostSync false,
    /// so MCP calls stay on the serial slotSafe path), never replayable and
    /// never prefetched. Base names delegate wholesale.
    fn metadata(raw: *const anyopaque, name: []const u8) ?core.tools.ToolMeta {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        return switch (self.resolveTool(name)) {
            .mcp => .{
                .kind = .external,
                .category = .execute,
                .replay = .never,
                .prefetch_safe = false,
            },
            .base => self.base_dispatcher.metadata(name),
        };
    }

    fn nameAt(raw: *const anyopaque, index: usize) ?[]const u8 {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        if (index < self.base_definitions.len) return self.base_dispatcher.nameAt(index);
        const mcp_index = index - self.base_definitions.len;
        if (mcp_index >= self.entries.len) return null;
        return self.entries[mcp_index].model_name;
    }

    fn allowsTool(raw: *const anyopaque, name: []const u8) bool {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        if (self.findModelTool(name)) |entry|
            return allowsEntrySkillRestrictions(entry, self.skill_restrictions) and
                if (self.base_policy) |policy| policy.allowsTool(name) else true;
        return if (self.base_policy) |policy| policy.allowsTool(name) else true;
    }

    fn allowsInvocation(raw: *const anyopaque, name: []const u8, arguments_json: []const u8) bool {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        if (self.findModelTool(name)) |entry| {
            if (!allowsEntrySkillRestrictions(entry, self.skill_restrictions))
                return false;
            if (self.base_policy) |policy|
                if (!policy.allowsInvocation(name, arguments_json)) return false;
            // Preserve the ordinary arguments-envelope deny fast path, but let typed
            // resource/OOM failures reach dispatch. Collapsing those failures
            // into this bool would misreport infrastructure failure as user
            // denial.
            return switch (self.validateInvocation(name, arguments_json)) {
                .valid => true,
                .invalid => |issue| issue == .resource_limit,
                .out_of_memory => true,
            };
        }
        return if (self.base_policy) |policy|
            policy.allowsInvocation(name, arguments_json)
        else
            true;
    }
};

pub fn deriveModelName(
    allocator: std.mem.Allocator,
    namespace: []const u8,
    binding: *const [32]u8,
    tool_name: []const u8,
) Error![]u8 {
    return catalog.deriveModelName(allocator, namespace, binding, tool_name);
}

fn selectionFingerprint(
    allocator: std.mem.Allocator,
    entries: []const Entry,
) error{OutOfMemory}![32]u8 {
    const digests = allocator.alloc([32]u8, entries.len) catch
        return error.OutOfMemory;
    defer allocator.free(digests);
    for (entries, digests) |entry, *digest| {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&entry.tool.identity.server_binding_identity);
        hasher.update(entry.tool.identity.name);
        hasher.update(&entry.tool.identity.schema_fingerprint);
        hasher.final(digest);
    }
    std.mem.sort([32]u8, digests, {}, struct {
        fn lessThan(_: void, left: [32]u8, right: [32]u8) bool {
            return std.mem.order(u8, &left, &right) == .lt;
        }
    }.lessThan);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    // Must match mcp_checkpoint.zig.
    hasher.update("agentcore-mcp-session-selection\x00");
    for (digests) |digest| hasher.update(&digest);
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

fn abortAdapter(raw: ?*const anyopaque) bool {
    const abort: *const core.util_abort.AbortSignal = @ptrCast(@alignCast(raw orelse return false));
    return abort.isAborted();
}

fn encodeFailure(
    allocator: std.mem.Allocator,
    failure: runtime.CallFailure,
) error{OutOfMemory}![]u8 {
    const Dto = struct {
        code: []const u8,
        phase: []const u8,
        rpc_code: ?i64,
    };
    const dto = switch (failure) {
        .diagnostic => |diagnostic| Dto{
            .code = @tagName(diagnostic.code),
            .phase = @tagName(diagnostic.phase),
            .rpc_code = diagnostic.rpc_code,
        },
        else => Dto{
            .code = @tagName(failure),
            .phase = "transport",
            .rpc_code = @as(?i64, null),
        },
    };
    return std.json.Stringify.valueAlloc(allocator, dto, .{}) catch error.OutOfMemory;
}

fn anyMcpRuleMatches(rules: []const []const u8, entry: *const Entry) bool {
    for (rules) |rule| if (mcpRuleMatches(rule, entry)) return true;
    return false;
}

/// Canonical interpretation of the existing Skill/Permission authoring
/// vocabulary. Namespace uniqueness is enforced by the Runtime catalog;
/// binding identity remains attached to `entry` and is never inferred from
/// the author-facing namespace.
fn mcpRuleMatches(rule: []const u8, entry: *const Entry) bool {
    const prefix = "mcp__";
    if (!std.mem.startsWith(u8, rule, prefix)) return false;
    const remainder = rule[prefix.len..];
    if (remainder.len == 0) return false;
    const separator = std.mem.indexOf(u8, remainder, "__") orelse
        return std.mem.eql(u8, remainder, entry.server.namespace);
    const namespace = remainder[0..separator];
    const tool = remainder[separator + 2 ..];
    if (!std.mem.eql(u8, namespace, entry.server.namespace) or tool.len == 0)
        return false;
    return std.mem.eql(u8, tool, "*") or
        std.mem.eql(u8, tool, entry.tool.identity.name);
}

test "model-facing MCP name is stable bounded and does not expose raw tool name" {
    const binding = [_]u8{4} ** 32;
    const first = try deriveModelName(std.testing.allocator, "weather", &binding, "get forecast/unsafe");
    defer std.testing.allocator.free(first);
    const second = try deriveModelName(std.testing.allocator, "weather", &binding, "get forecast/unsafe");
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(first.len <= MAX_MODEL_TOOL_NAME_BYTES);
    try std.testing.expect(std.mem.startsWith(u8, first, "mcp__weather__"));
    try std.testing.expect(std.mem.indexOf(u8, first, "forecast") == null);
}

test "Skill MCP rules resolve opaque aliases through canonical identity" {
    const fixture = @import("mcp_test_support.zig");
    var server = fixture.Server{};
    const binding = [_]u8{0x64} ** 32;
    const specs = [_]catalog.ServerSpec{.{
        .binding = binding,
        .namespace = "weather",
        .connector = server.connector(),
        .transport = .stdio,
        .client = .{ .name = "agentcore-test", .version = "1" },
    }};
    var manager = try catalog.Manager.init(std.testing.allocator, &specs, .{});
    defer manager.deinit();
    _ = try manager.refresh();
    const snapshot = try manager.retainCurrent();
    defer snapshot.release();
    var view = try View.init(std.testing.allocator, snapshot, &.{.{
        .server_binding_identity = binding,
        .tool_name = "weather",
    }}, .fresh);
    defer view.deinit();
    const alias = view.entries[0].model_name;
    try std.testing.expect(std.mem.startsWith(u8, alias, "mcp__weather__"));
    try std.testing.expect(view.allowsSkillRestrictions(alias, &.{.{
        .allowed = &.{"mcp__weather__weather"},
        .disallowed = &.{},
    }}));
    try std.testing.expect(view.allowsSkillRestrictions(alias, &.{.{
        .allowed = &.{"mcp__weather__*"},
        .disallowed = &.{},
    }}));
    try std.testing.expect(!view.allowsSkillRestrictions(alias, &.{.{
        .allowed = &.{"Read"},
        .disallowed = &.{},
    }}));
    try std.testing.expect(!view.allowsSkillRestrictions(alias, &.{.{
        .allowed = &.{"mcp__weather"},
        .disallowed = &.{"mcp__weather__weather"},
    }}));
    const rule_name = try view.entries[0].permissionRuleName(std.testing.allocator);
    defer std.testing.allocator.free(rule_name);
    try std.testing.expectEqualStrings("weather__weather", rule_name);
}

test "Session MCP view never auto-selects wider Runtime authority" {
    const fixture = @import("mcp_test_support.zig");
    var weather = fixture.Server{ .tool_name = "weather" };
    var calendar = fixture.Server{ .tool_name = "events" };
    const weather_binding = [_]u8{0x65} ** 32;
    const calendar_binding = [_]u8{0x66} ** 32;
    const specs = [_]catalog.ServerSpec{
        .{
            .binding = weather_binding,
            .namespace = "weather",
            .connector = weather.connector(),
            .transport = .stdio,
            .client = .{ .name = "agentcore-test", .version = "1" },
        },
        .{
            .binding = calendar_binding,
            .namespace = "calendar",
            .connector = calendar.connector(),
            .transport = .stdio,
            .client = .{ .name = "agentcore-test", .version = "1" },
        },
    };
    var manager = try catalog.Manager.init(std.testing.allocator, &specs, .{});
    defer manager.deinit();
    _ = try manager.refresh();
    const snapshot = try manager.retainCurrent();
    defer snapshot.release();

    var view = try View.init(std.testing.allocator, snapshot, &.{.{
        .server_binding_identity = weather_binding,
        .tool_name = "weather",
    }}, .fresh);
    defer view.deinit();
    try std.testing.expectEqual(@as(usize, 1), view.entries.len);
    try std.testing.expect(view.findCanonicalTool(&weather_binding, "weather") != null);
    try std.testing.expect(view.findCanonicalTool(&calendar_binding, "events") == null);
    try std.testing.expectEqual(@as(u32, 0), view.invalidated);
}

test "Session cannot select a Tool with a broken Provider projection" {
    const fixture = @import("mcp_test_support.zig");
    var server = fixture.Server{
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"x\":{\"$ref\":\"#/$defs/x\"}}}",
    };
    const binding = [_]u8{0x67} ** 32;
    const specs = [_]catalog.ServerSpec{.{
        .binding = binding,
        .namespace = "invalid",
        .connector = server.connector(),
        .transport = .stdio,
        .client = .{ .name = "agentcore-test", .version = "1" },
    }};
    var manager = try catalog.Manager.init(std.testing.allocator, &specs, .{});
    defer manager.deinit();
    _ = try manager.refresh();
    const snapshot = try manager.retainCurrent();
    defer snapshot.release();
    try std.testing.expectError(
        error.InvalidSelection,
        View.init(std.testing.allocator, snapshot, &.{.{
            .server_binding_identity = binding,
            .tool_name = "weather",
        }}, .fresh),
    );
    try std.testing.expectEqual(@as(u32, 0), server.calls);
}

test "Session MCP view binds identity validates argument envelope and retains generation" {
    const fixture = @import("mcp_test_support.zig");
    const Base = struct {
        fn dispatch(
            _: *const anyopaque,
            _: *const core.tool_context.ToolContext,
            _: []const u8,
            _: []const u8,
        ) anyerror!core.tools.ToolDispatchOutcome {
            return .host_fatal;
        }
        fn nameAt(_: *const anyopaque, index: usize) ?[]const u8 {
            return if (index == 0) "Read" else null;
        }
        fn metadata(_: *const anyopaque, name: []const u8) ?core.tools.ToolMeta {
            if (std.mem.eql(u8, name, "Read")) return .{
                .kind = .builtin,
                .category = .read,
                .replay = .read_only,
                .prefetch_safe = true,
            };
            return null;
        }
        fn dispatcher() core.tools.ToolDispatcher {
            return .{
                .ctx = &unit,
                .dispatchFn = dispatch,
                .metadataFn = metadata,
                .nameAtFn = nameAt,
            };
        }
        const unit: u8 = 0;
    };
    const Deny = struct {
        fn tool(_: *const anyopaque, _: []const u8) bool {
            return false;
        }
        fn invocation(_: *const anyopaque, _: []const u8, _: []const u8) bool {
            return false;
        }
        fn policy() core.tools.ToolExecutionPolicy {
            return .{
                .ctx = &unit,
                .allowsToolFn = tool,
                .allowsInvocationFn = invocation,
            };
        }
        const unit: u8 = 0;
    };

    var server = fixture.Server{};
    const binding = [_]u8{0x71} ** 32;
    const specs = [_]catalog.ServerSpec{.{
        .binding = binding,
        .namespace = "weather",
        .connector = server.connector(),
        .transport = .stdio,
        .client = .{ .name = "agentcore-test", .version = "1" },
    }};
    var manager = try catalog.Manager.init(std.testing.allocator, &specs, .{});
    defer manager.deinit();
    try std.testing.expectEqual(@as(u64, 1), try manager.refresh());
    const first_snapshot = try manager.retainCurrent();
    defer first_snapshot.release();
    var first = try View.init(std.testing.allocator, first_snapshot, &.{.{
        .server_binding_identity = binding,
        .tool_name = "weather",
    }}, .fresh);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 1), first.entries.len);
    try std.testing.expectEqual(@as(u64, 1), first.catalog_generation);
    const model_name = try std.testing.allocator.dupe(u8, first.entries[0].model_name);
    defer std.testing.allocator.free(model_name);
    const identity = first.entries[0].permissionIdentity();
    try std.testing.expectEqual(session_permission.ToolNamespace.mcp, identity.namespace);
    try std.testing.expectEqualStrings("weather", identity.name);
    try std.testing.expectEqualSlices(
        u8,
        &first.entries[0].tool.identity.permissionBinding(),
        &identity.binding,
    );
    try std.testing.expect(first.validatesInvocation(model_name, "{\"city\":\"Paris\"}"));
    try std.testing.expect(first.validatesInvocation(model_name, "{\"city\":7}"));
    try std.testing.expect(!first.validatesInvocation(model_name, "[]"));

    const base_definition = core.json.ToolDefinition{
        .name = "Read",
        .description = "Base metadata fixture",
        .input_schema = .{ .type = "object", .required = &.{} },
    };
    var environment = try Environment.init(
        std.testing.allocator,
        &first,
        &.{base_definition},
        Base.dispatcher(),
        Deny.policy(),
    );
    defer environment.deinit();
    const dispatcher = environment.surface().dispatcher;
    try std.testing.expect(!dispatcher.prefetchSafe(model_name));
    try std.testing.expect(!dispatcher.isHostSync(model_name));
    try std.testing.expect(!dispatcher.isBuiltin(model_name));
    // 远程 connector 调用是可执行权限:自有 MCP 名显式归 .execute,
    // 不再落 null 让权限层按名字猜(unknown-read 兜底)。
    try std.testing.expectEqual(core.tool_context.ToolCategory.execute, dispatcher.category(model_name).?);
    try std.testing.expectEqual(core.tools.ReplayDeclaration.never, dispatcher.replayDeclaration(model_name));
    try std.testing.expect(dispatcher.prefetchSafe("Read"));
    try std.testing.expect(dispatcher.isBuiltin("Read"));
    try std.testing.expect(!dispatcher.isHostSync("Read"));
    try std.testing.expectEqual(core.tool_context.ToolCategory.read, dispatcher.category("Read").?);
    try std.testing.expectEqual(core.tools.ReplayDeclaration.read_only, dispatcher.replayDeclaration("Read"));
    try std.testing.expect(!dispatcher.isBuiltin("unknown"));
    try std.testing.expect(dispatcher.category("unknown") == null);
    try std.testing.expect(!environment.executionPolicy().allowsTool(model_name));
    try std.testing.expect(!environment.executionPolicy().allowsInvocation(
        model_name,
        "{\"city\":\"Paris\"}",
    ));
    environment.base_policy = null;
    try std.testing.expect(environment.executionPolicy().allowsInvocation(
        model_name,
        "{\"city\":\"Paris\"}",
    ));
    try std.testing.expect(environment.executionPolicy().allowsInvocation(
        model_name,
        "{\"city\":7}",
    ));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var artifact_root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const artifact_root = artifact_root_buffer[0..try tmp.dir.realPath(
        std.testing.io,
        &artifact_root_buffer,
    )];
    var tool_context = core.tool_context.ToolContext{
        .allocator = std.testing.allocator,
        .artifact_root = artifact_root,
    };
    var semantically_opaque = try environment.surface().dispatcher.dispatch(
        &tool_context,
        model_name,
        "{\"city\":7}",
    );
    defer semantically_opaque.deinit(std.testing.allocator);
    try std.testing.expect(semantically_opaque == .ok);
    try std.testing.expectEqual(@as(u32, 1), server.calls);
    var result = try environment.surface().dispatcher.dispatch(
        &tool_context,
        model_name,
        "{\"city\":\"Paris\"}",
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .ok);
    try std.testing.expectEqual(@as(u32, 2), server.calls);

    try std.testing.expectEqual(@as(u64, 2), try manager.refresh());
    const second_snapshot = try manager.retainCurrent();
    defer second_snapshot.release();
    var second = try View.init(std.testing.allocator, second_snapshot, &.{.{
        .server_binding_identity = binding,
        .tool_name = "weather",
    }}, .fresh);
    defer second.deinit();
    try std.testing.expectEqualStrings(model_name, second.entries[0].model_name);
    try std.testing.expectEqual(@as(u64, 1), first.catalog_generation);
    try std.testing.expectEqual(@as(u64, 2), second.catalog_generation);
}

test "MCP expiry excludes new Runs without mutating an admitted Run environment" {
    const fixture = @import("mcp_test_support.zig");
    const FakeClock = struct {
        now_ns: core.util_time.Nanos,

        fn read(raw: ?*const anyopaque) core.util_time.Nanos {
            const self: *const @This() = @ptrCast(@alignCast(raw.?));
            return self.now_ns;
        }

        fn value(self: *const @This()) catalog.Clock {
            return .{ .ctx = self, .now_fn = read };
        }
    };
    const Base = struct {
        fn dispatch(
            _: *const anyopaque,
            _: *const core.tool_context.ToolContext,
            _: []const u8,
            _: []const u8,
        ) anyerror!core.tools.ToolDispatchOutcome {
            return .host_fatal;
        }
        fn name(_: *const anyopaque, _: usize) ?[]const u8 {
            return null;
        }
        fn noMeta(_: *const anyopaque, _: []const u8) ?core.tools.ToolMeta {
            return null;
        }
        fn dispatcher() core.tools.ToolDispatcher {
            return .{
                .ctx = &unit,
                .dispatchFn = dispatch,
                .metadataFn = noMeta,
                .nameAtFn = name,
            };
        }
        const unit: u8 = 0;
    };

    var clock = FakeClock{ .now_ns = 100 * std.time.ns_per_s };
    var server = fixture.Server{};
    const binding = [_]u8{0x72} ** 32;
    const specs = [_]catalog.ServerSpec{.{
        .binding = binding,
        .namespace = "weather",
        .connector = server.connector(),
        .transport = .stdio,
        .client = .{ .name = "agentcore-test", .version = "1" },
    }};
    var manager = try catalog.Manager.initWithClock(
        std.testing.allocator,
        &specs,
        .{},
        clock.value(),
    );
    defer manager.deinit();
    _ = try manager.refresh();
    const snapshot = try manager.retainCurrent();
    defer snapshot.release();
    const selectors = [_]Selector{.{
        .server_binding_identity = binding,
        .tool_name = "weather",
    }};
    var view = try View.init(std.testing.allocator, snapshot, &selectors, .fresh);
    defer view.deinit();
    var selection = try Selection.fromView(std.testing.allocator, &view);
    defer selection.deinit();
    const model_name = view.entries[0].model_name;
    var admitted = try Environment.init(
        std.testing.allocator,
        &view,
        &.{},
        Base.dispatcher(),
        null,
    );
    defer admitted.deinit();
    try std.testing.expect(admitted.findModelTool(model_name) != null);

    clock.now_ns += 1001 * std.time.ns_per_ms;
    try std.testing.expect(admitted.findModelTool(model_name) != null);
    var after_expiry = try Environment.init(
        std.testing.allocator,
        &view,
        &.{},
        Base.dispatcher(),
        null,
    );
    defer after_expiry.deinit();
    try std.testing.expect(after_expiry.findModelTool(model_name) == null);
    try std.testing.expectError(
        error.NotRefreshed,
        View.init(std.testing.allocator, snapshot, &selectors, .fresh),
    );
    var degraded = try View.init(
        std.testing.allocator,
        snapshot,
        &selectors,
        .restore_degraded,
    );
    defer degraded.deinit();
    try std.testing.expectEqual(@as(usize, 0), degraded.entries.len);
    try std.testing.expectEqual(@as(u32, 1), degraded.invalidated);
    var admitted_after_expiry = try selection.materialize(
        std.testing.allocator,
        snapshot,
    );
    defer admitted_after_expiry.deinit();
    try std.testing.expectEqual(@as(usize, 0), admitted_after_expiry.entries.len);
    try std.testing.expectEqual(@as(u32, 1), admitted_after_expiry.invalidated);
}

test "Run materialization tolerates a selected server removed by Apply" {
    const fixture = @import("mcp_test_support.zig");
    var server = fixture.Server{};
    const binding = [_]u8{0x73} ** 32;
    const specs = [_]catalog.ServerSpec{.{
        .binding = binding,
        .namespace = "weather",
        .connector = server.connector(),
        .transport = .stdio,
        .client = .{ .name = "agentcore-test", .version = "1" },
    }};
    var manager = try catalog.Manager.init(std.testing.allocator, &specs, .{});
    defer manager.deinit();
    _ = try manager.refresh();
    const first_snapshot = try manager.retainCurrent();
    var selected = try Selection.init(std.testing.allocator, first_snapshot, &.{.{
        .server_binding_identity = binding,
        .tool_name = "weather",
    }}, .fresh);
    first_snapshot.release();
    defer selected.deinit();

    const report = try manager.apply(1, &.{});
    try std.testing.expectEqual(catalog.ApplyDisposition.applied, report.disposition);
    const current = try manager.retainCurrent();
    defer current.release();
    var run_view = try selected.materialize(std.testing.allocator, current);
    defer run_view.deinit();
    try std.testing.expectEqual(@as(usize, 0), run_view.entries.len);
    try std.testing.expectEqual(@as(u32, 1), run_view.invalidated);
}

test "Run materialization invalidates a selected tool after schema drift" {
    const fixture = @import("mcp_test_support.zig");
    var server = fixture.Server{};
    const binding = [_]u8{0x74} ** 32;
    const specs = [_]catalog.ServerSpec{.{
        .binding = binding,
        .namespace = "weather",
        .connector = server.connector(),
        .transport = .stdio,
        .client = .{ .name = "agentcore-test", .version = "1" },
    }};
    var manager = try catalog.Manager.init(std.testing.allocator, &specs, .{});
    defer manager.deinit();
    _ = try manager.refresh();
    const first = try manager.retainCurrent();
    var selected = try Selection.init(std.testing.allocator, first, &.{.{
        .server_binding_identity = binding,
        .tool_name = "weather",
    }}, .fresh);
    first.release();
    defer selected.deinit();
    try std.testing.expect(selected.selectors[0].expected_schema_fingerprint != null);

    server.input_schema_json =
        "{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\"}},\"required\":[\"location\"]}";
    _ = try manager.refresh();
    const current = try manager.retainCurrent();
    defer current.release();
    var run_view = try selected.materialize(std.testing.allocator, current);
    defer run_view.deinit();
    try std.testing.expectEqual(@as(usize, 0), run_view.entries.len);
    try std.testing.expectEqual(@as(u32, 1), run_view.invalidated);
}

test "all three protocol eras enter the same Session identity and dispatch seam" {
    const fixture = @import("mcp_test_support.zig");
    const negotiation = @import("mcp_negotiation.zig");
    const Exercise = struct {
        const Result = struct {
            model_name: [MAX_MODEL_TOOL_NAME_BYTES]u8,
            model_name_len: usize,
            permission_binding: [32]u8,
            calls: u32,
        };
        const Base = struct {
            fn dispatch(
                _: *const anyopaque,
                _: *const core.tool_context.ToolContext,
                _: []const u8,
                _: []const u8,
            ) anyerror!core.tools.ToolDispatchOutcome {
                return .host_fatal;
            }
            fn name(_: *const anyopaque, _: usize) ?[]const u8 {
                return null;
            }
            fn noMeta(_: *const anyopaque, _: []const u8) ?core.tools.ToolMeta {
                return null;
            }
            fn dispatcher() core.tools.ToolDispatcher {
                return .{
                    .ctx = &unit,
                    .dispatchFn = dispatch,
                    .metadataFn = noMeta,
                    .nameAtFn = name,
                };
            }
            const unit: u8 = 0;
        };

        fn run(era: canonical.Era, policy: negotiation.Policy) !Result {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var artifact_root_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const artifact_root = artifact_root_buffer[0..try tmp.dir.realPath(
                std.testing.io,
                &artifact_root_buffer,
            )];
            var server = fixture.Server{ .era = era };
            const binding = [_]u8{0x91} ** 32;
            const specs = [_]catalog.ServerSpec{.{
                .binding = binding,
                .namespace = "weather",
                .connector = server.connector(),
                .transport = .stdio,
                .policy = policy,
                .client = .{ .name = "agentcore-test", .version = "1" },
            }};
            var manager = try catalog.Manager.init(std.testing.allocator, &specs, .{});
            defer manager.deinit();
            _ = try manager.refresh();
            const snapshot = try manager.retainCurrent();
            defer snapshot.release();
            var view = try View.init(std.testing.allocator, snapshot, &.{.{
                .server_binding_identity = binding,
                .tool_name = "weather",
            }}, .fresh);
            defer view.deinit();
            try std.testing.expectEqual(era, view.entries[0].server.era);
            var environment = try Environment.init(
                std.testing.allocator,
                &view,
                &.{},
                Base.dispatcher(),
                null,
            );
            defer environment.deinit();
            var tool_context = core.tool_context.ToolContext{
                .allocator = std.testing.allocator,
                .artifact_root = artifact_root,
            };
            var outcome = try environment.surface().dispatcher.dispatch(
                &tool_context,
                view.entries[0].model_name,
                "{\"city\":\"Paris\"}",
            );
            defer outcome.deinit(std.testing.allocator);
            try std.testing.expect(outcome == .ok);
            var result = Result{
                .model_name = undefined,
                .model_name_len = view.entries[0].model_name.len,
                .permission_binding = view.entries[0].permissionIdentity().binding,
                .calls = server.calls,
            };
            @memcpy(
                result.model_name[0..result.model_name_len],
                view.entries[0].model_name,
            );
            return result;
        }
    };

    const modern_result = try Exercise.run(.modern_2026_07_28, .modern_only);
    const legacy_result = try Exercise.run(.classic_2025_11_25, .legacy_only);
    const classic_06_result = try Exercise.run(
        .classic_2025_06_18,
        .legacy_2025_06_only,
    );
    try std.testing.expectEqualStrings(
        modern_result.model_name[0..modern_result.model_name_len],
        legacy_result.model_name[0..legacy_result.model_name_len],
    );
    try std.testing.expectEqualStrings(
        modern_result.model_name[0..modern_result.model_name_len],
        classic_06_result.model_name[0..classic_06_result.model_name_len],
    );
    try std.testing.expectEqualSlices(
        u8,
        &modern_result.permission_binding,
        &legacy_result.permission_binding,
    );
    try std.testing.expectEqualSlices(
        u8,
        &modern_result.permission_binding,
        &classic_06_result.permission_binding,
    );
    try std.testing.expectEqual(@as(u32, 1), modern_result.calls);
    try std.testing.expectEqual(@as(u32, 1), legacy_result.calls);
    try std.testing.expectEqual(@as(u32, 1), classic_06_result.calls);
}
