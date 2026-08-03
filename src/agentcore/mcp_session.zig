//! Session-filtered MCP view and immutable Run tool overlay.

const std = @import("std");
const core = @import("metacodes-core");
const catalog = @import("mcp_catalog.zig");
const canonical = @import("mcp_canonical.zig");
const runtime = @import("mcp_runtime.zig");
const schema = @import("mcp_schema.zig");
const session_permission = @import("session_permission.zig");

pub const MAX_MODEL_TOOL_NAME_BYTES: usize = 64;

pub const Selector = struct {
    server_binding_identity: [32]u8,
    tool_name: []const u8,
    /// Set only by checkpoint restore. Fresh Host selection uses null; a
    /// restored grant is invalidated if the current semantic schema changed.
    expected_schema_fingerprint: ?[32]u8 = null,
};

pub const BuildMode = enum { fresh, restore_degraded };

pub const Error = error{
    OutOfMemory,
    InvalidSelection,
    ResourceLimit,
};

pub const Entry = struct {
    server: *const catalog.ServerRecord,
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
            if (selector.expected_schema_fingerprint) |expected| {
                if (!std.mem.eql(u8, &expected, &resolved.tool.identity.schema_fingerprint)) {
                    if (mode == .fresh) return error.InvalidSelection;
                    invalidated += 1;
                    continue;
                }
            }
            const model_name = try deriveModelName(
                a,
                resolved.server.namespace,
                &selector.server_binding_identity,
                selector.tool_name,
            );
            for (entries.items) |entry| if (std.mem.eql(u8, entry.model_name, model_name))
                return error.InvalidSelection;
            // `arena` is moved by value into the returned View. A child arena
            // must therefore use the stable caller-provided backing allocator,
            // not `a`, whose allocator pointer refers to this stack-local arena
            // value before that move.
            const admission = schema.prepareTool(backing, model_name, resolved.tool, .{}) catch
                return error.OutOfMemory;
            const prepared = switch (admission) {
                .available => |value| value,
                .unavailable => {
                    if (mode == .fresh) return error.InvalidSelection;
                    invalidated += 1;
                    continue;
                },
            };
            entries.append(a, .{
                .server = resolved.server,
                .tool = resolved.tool,
                .model_name = model_name,
                .prepared = prepared,
            }) catch {
                var cleanup = prepared;
                cleanup.deinit();
                return error.OutOfMemory;
            };
        }
        const owned_entries = entries.toOwnedSlice(a) catch return error.OutOfMemory;
        return .{
            .allocator = backing,
            .arena = arena,
            .snapshot = retained,
            .entries = owned_entries,
            .catalog_generation = retained.generation,
            .catalog_fingerprint = retained.fingerprint,
            .selection_fingerprint = selectionFingerprint(owned_entries),
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
        const entry = self.findModelTool(model_name) orelse return false;
        return schema.validateArguments(
            self.allocator,
            entry.tool.input_schema_json,
            arguments_json,
            .{},
        ) == .valid;
    }
};

pub const Environment = struct {
    allocator: std.mem.Allocator,
    view: *const View,
    base_definitions: []const core.json.ToolDefinition,
    base_dispatcher: core.tools.ToolDispatcher,
    base_policy: ?core.tools.ToolExecutionPolicy,
    definitions: []core.json.ToolDefinition,

    pub fn init(
        allocator: std.mem.Allocator,
        view: *const View,
        base_definitions: []const core.json.ToolDefinition,
        base_dispatcher: core.tools.ToolDispatcher,
        base_policy: ?core.tools.ToolExecutionPolicy,
    ) Error!Environment {
        const definitions = allocator.alloc(
            core.json.ToolDefinition,
            base_definitions.len + view.entries.len,
        ) catch return error.OutOfMemory;
        @memcpy(definitions[0..base_definitions.len], base_definitions);
        for (view.entries, definitions[base_definitions.len..]) |entry, *definition|
            definition.* = entry.prepared.definition;
        return .{
            .allocator = allocator,
            .view = view,
            .base_definitions = base_definitions,
            .base_dispatcher = base_dispatcher,
            .base_policy = base_policy,
            .definitions = definitions,
        };
    }

    pub fn deinit(self: *Environment) void {
        self.allocator.free(self.definitions);
        self.* = undefined;
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
            .prefetchSafeFn = prefetchSafe,
            .nameAtFn = nameAt,
            .hostSyncFn = hostSync,
        };
    }

    fn dispatch(
        raw: *const anyopaque,
        tool_ctx: *const core.tool_context.ToolContext,
        name: []const u8,
        arguments_json: []const u8,
    ) anyerror!core.tools.ToolDispatchOutcome {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        const entry = self.view.findModelTool(name) orelse
            return self.base_dispatcher.dispatch(tool_ctx, name, arguments_json);
        if (!self.view.validatesInvocation(name, arguments_json))
            return .{ .host_rejected = try tool_ctx.allocator.dupe(u8, "MCP arguments violate the admitted schema") };
        const cancellation = runtime.Cancellation{
            .ctx = if (tool_ctx.abort) |abort| abort else null,
            .is_cancelled_fn = abortAdapter,
        };
        var outcome = entry.server.client.callTool(
            tool_ctx.allocator,
            entry.tool,
            arguments_json,
            cancellation,
        );
        return switch (outcome) {
            .result => |*result| blk: {
                const encoded = try tool_ctx.allocator.dupe(u8, result.raw_result_json);
                const is_error = result.is_error;
                result.deinit();
                break :blk if (is_error)
                    .{ .host_failed = encoded }
                else
                    .{ .ok = encoded };
            },
            .failed => |failure| switch (failure) {
                .out_of_memory => error.OutOfMemory,
                else => .{ .host_failed = try encodeFailure(tool_ctx.allocator, failure) },
            },
        };
    }

    fn prefetchSafe(raw: *const anyopaque, name: []const u8) bool {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        if (self.view.findModelTool(name) != null) return false;
        return self.base_dispatcher.prefetchSafe(name);
    }

    fn nameAt(raw: *const anyopaque, index: usize) ?[]const u8 {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        if (index < self.base_definitions.len) return self.base_dispatcher.nameAt(index);
        const mcp_index = index - self.base_definitions.len;
        if (mcp_index >= self.view.entries.len) return null;
        return self.view.entries[mcp_index].model_name;
    }

    fn hostSync(raw: *const anyopaque, name: []const u8) bool {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        if (self.view.findModelTool(name) != null) return false;
        return self.base_dispatcher.isHostSync(name);
    }

    fn allowsTool(raw: *const anyopaque, name: []const u8) bool {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        if (self.view.findModelTool(name) != null)
            return if (self.base_policy) |policy| policy.allowsTool(name) else true;
        return if (self.base_policy) |policy| policy.allowsTool(name) else true;
    }

    fn allowsInvocation(raw: *const anyopaque, name: []const u8, arguments_json: []const u8) bool {
        const self: *const Environment = @ptrCast(@alignCast(raw));
        if (self.view.findModelTool(name) != null) {
            if (self.base_policy) |policy|
                if (!policy.allowsInvocation(name, arguments_json)) return false;
            return self.view.validatesInvocation(name, arguments_json);
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
    if (namespace.len == 0 or namespace.len > 24) return error.InvalidSelection;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("agentcore-r6-mcp-model-tool\x00");
    hasher.update(binding);
    hasher.update(tool_name);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const prefix = "mcp__";
    const middle = "__";
    const size = prefix.len + namespace.len + middle.len + 32;
    if (size > MAX_MODEL_TOOL_NAME_BYTES) return error.ResourceLimit;
    const result = allocator.alloc(u8, size) catch return error.OutOfMemory;
    @memcpy(result[0..prefix.len], prefix);
    @memcpy(result[prefix.len .. prefix.len + namespace.len], namespace);
    const middle_start = prefix.len + namespace.len;
    @memcpy(result[middle_start .. middle_start + middle.len], middle);
    const hex = "0123456789abcdef";
    for (digest[0..16], 0..) |byte, index| {
        result[middle_start + middle.len + index * 2] = hex[byte >> 4];
        result[middle_start + middle.len + index * 2 + 1] = hex[byte & 0x0f];
    }
    return result;
}

fn selectionFingerprint(entries: []const Entry) [32]u8 {
    var digests: [1024][32]u8 = undefined;
    std.debug.assert(entries.len <= digests.len);
    for (entries, digests[0..entries.len]) |entry, *digest| {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&entry.tool.identity.server_binding_identity);
        hasher.update(entry.tool.identity.name);
        hasher.update(&entry.tool.identity.schema_fingerprint);
        hasher.final(digest);
    }
    std.mem.sort([32]u8, digests[0..entries.len], {}, struct {
        fn lessThan(_: void, left: [32]u8, right: [32]u8) bool {
            return std.mem.order(u8, &left, &right) == .lt;
        }
    }.lessThan);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("agentcore-r6-mcp-session-selection\x00");
    for (digests[0..entries.len]) |digest| hasher.update(&digest);
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

test "Session MCP view binds canonical identity validates before dispatch and retains its generation" {
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
        fn prefetchSafe(_: *const anyopaque, _: []const u8) bool {
            return false;
        }
        fn nameAt(_: *const anyopaque, _: usize) ?[]const u8 {
            return null;
        }
        fn hostSync(_: *const anyopaque, _: []const u8) bool {
            return false;
        }
        fn dispatcher() core.tools.ToolDispatcher {
            return .{
                .ctx = &unit,
                .dispatchFn = dispatch,
                .prefetchSafeFn = prefetchSafe,
                .nameAtFn = nameAt,
                .hostSyncFn = hostSync,
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
    try std.testing.expect(!first.validatesInvocation(model_name, "{\"city\":7}"));

    var environment = try Environment.init(
        std.testing.allocator,
        &first,
        &.{},
        Base.dispatcher(),
        Deny.policy(),
    );
    defer environment.deinit();
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
    try std.testing.expect(!environment.executionPolicy().allowsInvocation(
        model_name,
        "{\"city\":7}",
    ));
    var tool_context = core.tool_context.ToolContext{ .allocator = std.testing.allocator };
    var rejected = try environment.surface().dispatcher.dispatch(
        &tool_context,
        model_name,
        "{\"city\":7}",
    );
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expect(rejected == .host_rejected);
    try std.testing.expectEqual(@as(u32, 0), server.calls);
    var result = try environment.surface().dispatcher.dispatch(
        &tool_context,
        model_name,
        "{\"city\":\"Paris\"}",
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .ok);
    try std.testing.expectEqual(@as(u32, 1), server.calls);

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

test "modern and legacy peers enter the same Session identity and dispatch seam" {
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
            fn no(_: *const anyopaque, _: []const u8) bool {
                return false;
            }
            fn name(_: *const anyopaque, _: usize) ?[]const u8 {
                return null;
            }
            fn dispatcher() core.tools.ToolDispatcher {
                return .{
                    .ctx = &unit,
                    .dispatchFn = dispatch,
                    .prefetchSafeFn = no,
                    .nameAtFn = name,
                    .hostSyncFn = no,
                };
            }
            const unit: u8 = 0;
        };

        fn run(era: canonical.Era, policy: negotiation.Policy) !Result {
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
            try std.testing.expectEqual(era, view.entries[0].server.client.era);
            var environment = try Environment.init(
                std.testing.allocator,
                &view,
                &.{},
                Base.dispatcher(),
                null,
            );
            defer environment.deinit();
            var tool_context = core.tool_context.ToolContext{ .allocator = std.testing.allocator };
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
    const legacy_result = try Exercise.run(.legacy_2025_11_25, .legacy_only);
    try std.testing.expectEqualStrings(
        modern_result.model_name[0..modern_result.model_name_len],
        legacy_result.model_name[0..legacy_result.model_name_len],
    );
    try std.testing.expectEqualSlices(
        u8,
        &modern_result.permission_binding,
        &legacy_result.permission_binding,
    );
    try std.testing.expectEqual(@as(u32, 1), modern_result.calls);
    try std.testing.expectEqual(@as(u32, 1), legacy_result.calls);
}
