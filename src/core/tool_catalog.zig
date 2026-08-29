//! Immutable Runtime tool catalog and per-Session selection.
//!
//! The Runtime owns `Catalog`; each Session owns a `Selection` derived from it.
//! Definitions, admission and dispatch therefore resolve through the same
//! selected `Entry`. Built-in and Host executors deliberately share this one
//! directory so advertisement, admission and execution cannot drift apart.

const std = @import("std");
const json = @import("../json.zig");
const tools = @import("../tools.zig");
const permission_category = @import("../permission/category.zig");
const artifact_store = @import("tool_result_artifact.zig");
const tool_result = @import("tool_result.zig");
const execution_effect = @import("execution_effect.zig");

/// Legacy completed Host results are model-visible text and deliberately
/// bounded. Larger or binary producers must use `HostStreamTool`, which starts
/// a kernel-owned CAS spool before byte zero and carries an explicit media type.
/// This matches the public AgentCore ABI instead of letting source-level Zig
/// plugins bypass the same data-plane contract.
pub const MAX_HOST_SYNC_RESULT_BYTES: usize = 16 * 1024 * 1024;

pub const CatalogError = error{
    UnknownBuiltinTool,
    DuplicateToolName,
    ToolNotInRuntime,
    InvalidHostTool,
    /// A selected built-in declares an external executable dependency
    /// (ToolEntry.runtime_dependency) that cannot be resolved in this
    /// environment. Refused at admission so a Runtime never advertises a
    /// tool that cannot execute.
    ToolDependencyUnavailable,
};

pub const HostToolResult = struct {
    bytes: []const u8,
    release_ctx: *anyopaque,
    releaseFn: *const fn (ctx: *anyopaque, bytes: []const u8) void,

    pub fn release(self: HostToolResult) void {
        self.releaseFn(self.release_ctx, self.bytes);
    }
};

/// Typed Host tool outcome. Zig errors carry no payload, so business-failure
/// detail must live in a union, not an error set. Ownership per branch:
/// `ok` transfers to the caller (released via result.release() after copy);
/// `failed`/`rejected` payloads are optional details, borrowed until the
/// dispatch layer copies them, then released; `fatal` carries nothing —
/// the fatal control flow owns everything downstream.
pub const HostToolOutcome = union(enum) {
    ok: HostToolResult,
    failed: ?HostToolResult,
    rejected: ?HostToolResult,
    fatal,
};

pub const RunIdentity = tools.RunIdentity;
pub const HostRunIdentity = tools.HostRunIdentity;

pub const HostSyncExecuteFn = *const fn (
    ctx: *anyopaque,
    identity: HostRunIdentity,
    args: []const u8,
) error{OutOfMemory}!HostToolOutcome;

/// Runtime copies `definition` recursively. `ctx` remains Host-owned and must
/// outlive the Runtime. The thin library contract accepts completed results
/// only. Callbacks may run concurrently for different Sessions; the Host owns
/// `ctx` locking.
/// `args` is the provider-produced JSON envelope; the Host owns its validation.
/// Session lifecycle locks are not held, but abort is the only supported
/// reentrant AgentSession operation. Returned bytes must be valid UTF-8 and no
/// larger than `MAX_HOST_SYNC_RESULT_BYTES`; larger/binary producers must use
/// `HostStreamTool`.
pub const HostSyncTool = struct {
    definition: json.ToolDefinition,
    ctx: *anyopaque,
    execute: HostSyncExecuteFn,
    /// Conservative by default: a Host callback is executable authority unless
    /// its trusted registrar explicitly proves a narrower read/write effect.
    category: permission_category.ToolCategory = .execute,
    replay: execution_effect.ReplayDeclaration = .never,
};

/// Errors observable by a streaming Host producer. The sink is borrowed for
/// one synchronous callback and owns neither commit nor rollback authority.
pub const HostResultSinkError = error{
    Aborted,
    ArtifactTooLarge,
    ArtifactSinkFailed,
    ArtifactSinkClosed,
};

pub const HostResultSink = struct {
    ctx: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, bytes: []const u8) HostResultSinkError!void,

    pub fn write(self: *const HostResultSink, bytes: []const u8) HostResultSinkError!void {
        return self.writeFn(self.ctx, bytes);
    }
};

/// A successful streaming callback publishes exactly the bytes already sent
/// to the sink. Business failures may carry the same bounded Host-owned detail
/// as legacy callbacks; partial sink bytes are discarded by the kernel.
pub const HostStreamOutcome = union(enum) {
    artifact: tool_result.MediaType,
    failed: ?HostToolResult,
    rejected: ?HostToolResult,
    fatal,
};

pub const HostStreamExecuteError = error{
    OutOfMemory,
    Aborted,
    ArtifactTooLarge,
    ArtifactSinkFailed,
    ArtifactSinkClosed,
};

pub const HostStreamExecuteFn = *const fn (
    ctx: *anyopaque,
    identity: HostRunIdentity,
    args: []const u8,
    sink: *const HostResultSink,
) HostStreamExecuteError!HostStreamOutcome;

/// Streaming Host tools are a distinct registration type: a descriptor can
/// never accidentally provide both the legacy full-buffer callback and the
/// byte-zero callback. The Session must enable its artifact store before this
/// tool can be selected.
pub const HostStreamTool = struct {
    definition: json.ToolDefinition,
    ctx: *anyopaque,
    execute: HostStreamExecuteFn,
    category: permission_category.ToolCategory = .execute,
    replay: execution_effect.ReplayDeclaration = .never,
};

pub const HostSyncExecutor = struct {
    ctx: *anyopaque,
    execute: HostSyncExecuteFn,
};

pub const HostStreamExecutor = struct {
    ctx: *anyopaque,
    execute: HostStreamExecuteFn,
};

/// Kernel-owned adapter for an isolated executor (currently a process plugin).
/// Unlike `host_sync`, the callback receives the full borrowed ToolContext so
/// cancellation can terminate the child process. It receives no Host session
/// pointer and returns the already-typed dispatch outcome, keeping process code
/// outside Host callback authority.
pub const IsolatedExecuteFn = *const fn (
    ctx: *anyopaque,
    tool_ctx: *const tools.ToolContext,
    args: []const u8,
) anyerror!tools.ToolDispatchOutcome;

pub const IsolatedTool = struct {
    definition: json.ToolDefinition,
    ctx: *anyopaque,
    execute: IsolatedExecuteFn,
    /// Non-zero digest of the executable/package/schema authority. Embedding
    /// adapters use it to bind Session permission memory and checkpoints to
    /// this exact isolated implementation instead of only its display name.
    authority_binding: [32]u8,
    replay: execution_effect.ReplayDeclaration = .never,
};

pub const IsolatedExecutor = struct {
    ctx: *anyopaque,
    execute: IsolatedExecuteFn,
    authority_binding: [32]u8,
};

pub const Executor = union(enum) {
    builtin: *const tools.ToolEntry,
    host_sync: HostSyncExecutor,
    host_stream: HostStreamExecutor,
    isolated: IsolatedExecutor,
};

pub const Entry = struct {
    definition: json.ToolDefinition,
    executor: Executor,
    prefetch_safe: bool,
    category: permission_category.ToolCategory,
    replay: execution_effect.ReplayDeclaration,
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    entries: []Entry,

    pub fn initBuiltins(allocator: std.mem.Allocator, names: []const []const u8) !Catalog {
        return init(allocator, names, &.{});
    }

    pub fn init(allocator: std.mem.Allocator, builtin_names: []const []const u8, host_tools: []const HostSyncTool) !Catalog {
        return initWithIsolated(allocator, builtin_names, host_tools, &.{});
    }

    pub fn initWithIsolated(
        allocator: std.mem.Allocator,
        builtin_names: []const []const u8,
        host_tools: []const HostSyncTool,
        isolated_tools: []const IsolatedTool,
    ) !Catalog {
        return initWithExecutors(allocator, builtin_names, host_tools, &.{}, isolated_tools);
    }

    pub fn initWithExecutors(
        allocator: std.mem.Allocator,
        builtin_names: []const []const u8,
        host_tools: []const HostSyncTool,
        host_stream_tools: []const HostStreamTool,
        isolated_tools: []const IsolatedTool,
    ) !Catalog {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = .init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        var entries = try std.ArrayList(Entry).initCapacity(
            owned,
            builtin_names.len + host_tools.len + host_stream_tools.len + isolated_tools.len,
        );

        for (builtin_names) |name| {
            if (findEntry(entries.items, name) != null) return error.DuplicateToolName;
            const builtin = tools.getTool(name) orelse return error.UnknownBuiltinTool;
            // 准入 = 可执行性:凡进 catalog 的内置工具都会被广告给 Provider,
            // 其执行期外部依赖必须在此刻可解析。缺失是创建期类型化配置错误,
            // 不是广告之后首调时的 RipgrepNotFound。
            if (builtin.runtime_dependency) |dependency| {
                if (!runtimeDependencyAvailable(dependency)) return error.ToolDependencyUnavailable;
            }
            try entries.append(owned, .{
                .definition = .{
                    .name = builtin.name,
                    .description = builtin.description,
                    .input_schema = .{
                        .type = builtin.input_schema.type,
                        .prop_specs = builtin.input_schema.prop_specs,
                        .properties = null,
                        .required = builtin.input_schema.required,
                    },
                    .deferred = builtin.deferred,
                },
                .executor = .{ .builtin = builtin },
                // Preserve the existing AgentLoop prefetch policy for selected
                // built-ins. The extra gate exists only to keep Host and
                // unselected entries out of the prefetch path.
                .prefetch_safe = true,
                .category = permission_category.getToolCategory(builtin.name),
                .replay = builtin.replay,
            });
        }

        for (host_tools) |host| {
            if (host.definition.name.len == 0 or
                !std.mem.eql(u8, host.definition.input_schema.type, "object") or
                host.definition.server_type != null or
                host.definition.deferred) return error.InvalidHostTool;
            if (findEntry(entries.items, host.definition.name) != null) return error.DuplicateToolName;
            try entries.append(owned, .{
                .definition = try cloneDefinition(owned, host.definition),
                .executor = .{ .host_sync = .{ .ctx = host.ctx, .execute = host.execute } },
                .prefetch_safe = false,
                .category = host.category,
                .replay = host.replay,
            });
        }
        for (host_stream_tools) |host| {
            if (host.definition.name.len == 0 or
                !std.mem.eql(u8, host.definition.input_schema.type, "object") or
                host.definition.server_type != null or
                host.definition.deferred) return error.InvalidHostTool;
            if (findEntry(entries.items, host.definition.name) != null) return error.DuplicateToolName;
            try entries.append(owned, .{
                .definition = try cloneDefinition(owned, host.definition),
                .executor = .{ .host_stream = .{ .ctx = host.ctx, .execute = host.execute } },
                .prefetch_safe = false,
                .category = host.category,
                .replay = host.replay,
            });
        }
        for (isolated_tools) |isolated| {
            if (isolated.definition.name.len == 0 or
                !std.mem.eql(u8, isolated.definition.input_schema.type, "object") or
                isolated.definition.server_type != null or
                isolated.definition.deferred or
                std.mem.allEqual(u8, &isolated.authority_binding, 0)) return error.InvalidHostTool;
            if (findEntry(entries.items, isolated.definition.name) != null) return error.DuplicateToolName;
            try entries.append(owned, .{
                .definition = try cloneDefinition(owned, isolated.definition),
                .executor = .{ .isolated = .{
                    .ctx = isolated.ctx,
                    .execute = isolated.execute,
                    .authority_binding = isolated.authority_binding,
                } },
                .prefetch_safe = false,
                // Process manifests cannot self-classify into a weaker native
                // permission category. Executable authority is conservative.
                .category = .execute,
                .replay = isolated.replay,
            });
        }
        return .{ .allocator = allocator, .arena = arena, .entries = try entries.toOwnedSlice(owned) };
    }

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn find(self: *const Catalog, name: []const u8) ?*const Entry {
        return findEntry(self.entries, name);
    }
};

fn runtimeDependencyAvailable(dependency: tools.RuntimeDependency) bool {
    return switch (dependency) {
        .ripgrep => @import("../util/toolchain.zig").ripgrepAvailable(),
    };
}

fn findEntry(entries: []const Entry, name: []const u8) ?*const Entry {
    for (entries) |*entry| if (std.mem.eql(u8, entry.definition.name, name)) return entry;
    return null;
}

fn cloneDefinition(allocator: std.mem.Allocator, source: json.ToolDefinition) std.mem.Allocator.Error!json.ToolDefinition {
    return .{
        .name = try allocator.dupe(u8, source.name),
        .description = try allocator.dupe(u8, source.description),
        .input_schema = try cloneInputSchema(allocator, source.input_schema),
        .server_type = null,
        .deferred = false,
        .model_activation = if (source.model_activation) |activation| .{
            .mode = activation.mode,
            .argument_name = if (activation.argument_name) |value|
                try allocator.dupe(u8, value)
            else
                null,
            .argument_value = if (activation.argument_value) |value|
                try allocator.dupe(u8, value)
            else
                null,
        } else null,
    };
}

pub fn cloneHostTool(allocator: std.mem.Allocator, source: HostSyncTool) std.mem.Allocator.Error!HostSyncTool {
    return .{
        .definition = try cloneDefinition(allocator, source.definition),
        .ctx = source.ctx,
        .execute = source.execute,
        .category = source.category,
        .replay = source.replay,
    };
}

pub fn cloneHostStreamTool(allocator: std.mem.Allocator, source: HostStreamTool) std.mem.Allocator.Error!HostStreamTool {
    return .{
        .definition = try cloneDefinition(allocator, source.definition),
        .ctx = source.ctx,
        .execute = source.execute,
        .category = source.category,
        .replay = source.replay,
    };
}

fn cloneInputSchema(allocator: std.mem.Allocator, source: json.InputSchema) std.mem.Allocator.Error!json.InputSchema {
    return .{
        .type = try allocator.dupe(u8, source.type),
        .properties = if (source.properties) |properties| try cloneObject(allocator, properties) else null,
        .prop_specs = if (source.prop_specs) |specs| try clonePropSpecs(allocator, specs) else null,
        .required = if (source.required) |required| try cloneStrings(allocator, required) else null,
    };
}

fn cloneStrings(allocator: std.mem.Allocator, source: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    const out = try allocator.alloc([]const u8, source.len);
    for (source, 0..) |value, i| out[i] = try allocator.dupe(u8, value);
    return out;
}

fn clonePropSpecs(allocator: std.mem.Allocator, source: []const json.PropSpec) std.mem.Allocator.Error![]const json.PropSpec {
    const out = try allocator.alloc(json.PropSpec, source.len);
    for (source, 0..) |spec, i| {
        out[i] = .{
            .name = try allocator.dupe(u8, spec.name),
            .type = try allocator.dupe(u8, spec.type),
            .description = try allocator.dupe(u8, spec.description),
            .items_type = if (spec.items_type) |value| try allocator.dupe(u8, value) else null,
            .enum_values = if (spec.enum_values) |values| try cloneStrings(allocator, values) else null,
            .items_props = if (spec.items_props) |values| try clonePropSpecs(allocator, values) else null,
            .items_required = if (spec.items_required) |values| try cloneStrings(allocator, values) else null,
            .object_props = if (spec.object_props) |values| try clonePropSpecs(allocator, values) else null,
            .object_required = if (spec.object_required) |values| try cloneStrings(allocator, values) else null,
        };
    }
    return out;
}

fn cloneObject(allocator: std.mem.Allocator, source: std.json.ObjectMap) std.mem.Allocator.Error!std.json.ObjectMap {
    var out: std.json.ObjectMap = .empty;
    var it = source.iterator();
    while (it.next()) |item| {
        try out.put(allocator, try allocator.dupe(u8, item.key_ptr.*), try cloneValue(allocator, item.value_ptr.*));
    }
    return out;
}

fn cloneValue(allocator: std.mem.Allocator, source: std.json.Value) std.mem.Allocator.Error!std.json.Value {
    return switch (source) {
        .null => .null,
        .bool => |value| .{ .bool = value },
        .integer => |value| .{ .integer = value },
        .float => |value| .{ .float = value },
        .number_string => |value| .{ .number_string = try allocator.dupe(u8, value) },
        .string => |value| .{ .string = try allocator.dupe(u8, value) },
        .array => |array| blk: {
            var out = std.json.Array.init(allocator);
            for (array.items) |value| try out.append(try cloneValue(allocator, value));
            break :blk .{ .array = out };
        },
        .object => |object| .{ .object = try cloneObject(allocator, object) },
    };
}

pub const Selection = struct {
    allocator: std.mem.Allocator,
    /// 持有 redescribeForContext 重写后的描述串(混合 comptime 静态串 + arena 新串)。
    /// deinit 时先释放 arena(描述串),再释放 entries/definitions slice。
    arena: *std.heap.ArenaAllocator,
    entries: []*const Entry,
    definitions: []json.ToolDefinition,

    pub fn init(allocator: std.mem.Allocator, catalog: *const Catalog, allowlist: []const []const u8) !Selection {
        var selected = try std.ArrayList(*const Entry).initCapacity(allocator, allowlist.len);
        errdefer selected.deinit(allocator);
        var definitions = try std.ArrayList(json.ToolDefinition).initCapacity(allocator, allowlist.len);
        errdefer definitions.deinit(allocator);

        for (allowlist) |name| {
            for (selected.items) |existing| {
                if (std.mem.eql(u8, existing.definition.name, name)) return error.DuplicateToolName;
            }
            const entry = catalog.find(name) orelse return error.ToolNotInRuntime;
            try selected.append(allocator, entry);
            try definitions.append(allocator, entry.definition);
        }

        const entries_owned = try selected.toOwnedSlice(allocator);
        errdefer allocator.free(entries_owned);
        const definitions_owned = try definitions.toOwnedSlice(allocator);
        errdefer allocator.free(definitions_owned);

        // 缺陷 A 修复:调 redescribeForContext 就地重写描述为平台化动态长描述。
        // 对 Host 工具(getTool 返 null)和无 describe_fn 的工具自动跳过,恰好"Host 描述不变"。
        // 不调 overrideToolDesc(env A/B)——库不应受宿主进程环境变量摆布。
        // 必须用 arena:definitions[i].description 会混三类指针(comptime 静态 / catalog arena /
        // redescribe 新分配),逐个 free 会崩溃,arena 统一释放。
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }

        // PromptContext:enabled_tool_names 用 allowlist(让 USING_TOOLS 段按集裁剪)。
        // 其余字段默认值对齐 CLI 路径(prompt_context.zig 默认)。
        var prompt_ctx: @import("../tools.zig").PromptContext = .{};
        // allowlist_dup 只供 redescribeForContext 在本 init 内同步消费；因此仅
        // 复制 slice 表，不复制调用方拥有的字符串内容。
        const allowlist_dup = try arena.allocator().alloc([]const u8, allowlist.len);
        for (allowlist, 0..) |n, i| allowlist_dup[i] = n;
        prompt_ctx.enabled_tool_names = allowlist_dup;

        try @import("../tools.zig").redescribeForContext(arena.allocator(), definitions_owned, &prompt_ctx);

        return .{
            .allocator = allocator,
            .arena = arena,
            .entries = entries_owned,
            .definitions = definitions_owned,
        };
    }

    pub fn deinit(self: *Selection) void {
        // 顺序:先释放 arena(描述串指针指向的内存),再释放 slice(描述串已失效,free slice 本身)。
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.allocator.free(self.entries);
        self.allocator.free(self.definitions);
        self.* = undefined;
    }

    pub fn find(self: *const Selection, name: []const u8) ?*const Entry {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.definition.name, name)) return entry;
        }
        return null;
    }

    pub fn contains(self: *const Selection, name: []const u8) bool {
        return self.find(name) != null;
    }

    pub fn dispatcher(self: *const Selection) tools.ToolDispatcher {
        return .{ .ctx = @ptrCast(self), .dispatchFn = dispatch, .metadataFn = resolveMeta, .nameAtFn = nameAt };
    }

    fn dispatch(raw: *const anyopaque, tool_ctx: *const tools.ToolContext, name: []const u8, args: []const u8) anyerror!tools.ToolDispatchOutcome {
        const self: *const Selection = @ptrCast(@alignCast(raw));
        const entry = self.find(name) orelse return error.UnknownTool;
        switch (entry.executor) {
            .builtin => |builtin| {
                try tools.validateRequired(builtin.name, args);
                try tools.validateTypes(builtin.name, args);
                return .{ .ok = try builtin.execute.run(tool_ctx, args) };
            },
            .host_sync => |host| {
                // Identity is admission-fixed and passed by value; a selected
                // Host tool without identity is a wiring bug, not a tool error.
                const identity = tool_ctx.host_run orelse return error.HostRunIdentityMissing;
                const outcome = try host.execute(host.ctx, identity, args);
                // Ownership chain: Host descriptor is copied into
                // tool_ctx.allocator and released here exactly once — on the
                // success path, the detail paths and the copy-OOM path alike.
                switch (outcome) {
                    .ok => |result| {
                        defer result.release();
                        if (!validHostSyncText(result.bytes))
                            return .{ .host_failed = null };
                        return .{ .ok = tools.ToolResultBody.initInline(try tool_ctx.allocator.dupe(u8, result.bytes)) };
                    },
                    .failed => |maybe| {
                        const detail = try copyDetail(tool_ctx.allocator, maybe);
                        return .{ .host_failed = detail };
                    },
                    .rejected => |maybe| {
                        const detail = try copyDetail(tool_ctx.allocator, maybe);
                        return .{ .host_rejected = detail };
                    },
                    .fatal => return .host_fatal,
                }
            },
            .host_stream => |host| {
                const identity = tool_ctx.host_run orelse return error.HostRunIdentityMissing;
                if (tool_ctx.artifact_root.len == 0) return error.ArtifactStoreRequired;
                var spool = try artifact_store.Spool.begin(tool_ctx.allocator, tool_ctx.artifact_root);
                defer spool.deinit();
                var stream_state = StreamState{
                    .spool = &spool,
                    .abort = tool_ctx.abort,
                };
                const sink = HostResultSink{ .ctx = &stream_state, .writeFn = StreamState.write };
                const outcome = try host.execute(host.ctx, identity, args, &sink);
                switch (outcome) {
                    .artifact => |media_type| {
                        try stream_state.requireHealthy();
                        return .{ .ok = tool_result.ToolResultBody.fromCompletedSpool(
                            try spool.finish(),
                            media_type,
                        ) };
                    },
                    .failed => |maybe| {
                        const detail = try copyDetail(tool_ctx.allocator, maybe);
                        return .{ .host_failed = detail };
                    },
                    .rejected => |maybe| {
                        const detail = try copyDetail(tool_ctx.allocator, maybe);
                        return .{ .host_rejected = detail };
                    },
                    .fatal => return .host_fatal,
                }
            },
            .isolated => |isolated| {
                try validateIsolatedEnvelope(tool_ctx.allocator, entry.definition.input_schema, args);
                return isolated.execute(isolated.ctx, tool_ctx, args);
            },
        }
    }

    fn validateIsolatedEnvelope(
        allocator: std.mem.Allocator,
        schema: json.InputSchema,
        args: []const u8,
    ) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{
            .duplicate_field_behavior = .@"error",
        }) catch return error.InvalidToolInput;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidToolInput;
        if (schema.required) |required| {
            for (required) |name| {
                if (parsed.value.object.get(name) == null) return error.MissingRequiredField;
            }
        }
    }

    /// Copies an optional Host detail into the caller allocator and releases
    /// the Host descriptor exactly once, including on copy failure.
    fn copyDetail(allocator: std.mem.Allocator, maybe: ?HostToolResult) error{OutOfMemory}!?[]u8 {
        const result = maybe orelse return null;
        defer result.release();
        if (!validHostSyncText(result.bytes)) return null;
        return try allocator.dupe(u8, result.bytes);
    }

    fn validHostSyncText(bytes: []const u8) bool {
        return bytes.len <= MAX_HOST_SYNC_RESULT_BYTES and
            std.unicode.utf8ValidateSlice(bytes);
    }

    const StreamFailure = enum {
        aborted,
        too_large,
        sink_failed,
        closed,
    };

    const StreamState = struct {
        spool: *artifact_store.Spool,
        abort: ?*const @import("../util/abort.zig").AbortSignal,
        failure: ?StreamFailure = null,

        fn write(raw: *anyopaque, bytes: []const u8) HostResultSinkError!void {
            const self: *StreamState = @ptrCast(@alignCast(raw));
            if (self.failure) |failure| return failureError(failure);
            if (self.abort) |signal| {
                if (signal.isAborted()) {
                    self.failure = .aborted;
                    return error.Aborted;
                }
            }
            self.spool.write(bytes) catch |err| {
                const failure: StreamFailure = switch (err) {
                    error.ArtifactTooLarge => .too_large,
                    error.ArtifactSpoolClosed => .closed,
                    else => .sink_failed,
                };
                self.failure = failure;
                return failureError(failure);
            };
        }

        fn requireHealthy(self: *const StreamState) HostResultSinkError!void {
            if (self.failure) |failure| return failureError(failure);
            if (self.abort) |signal| if (signal.isAborted()) return error.Aborted;
        }

        fn failureError(failure: StreamFailure) HostResultSinkError {
            return switch (failure) {
                .aborted => error.Aborted,
                .too_large => error.ArtifactTooLarge,
                .sink_failed => error.ArtifactSinkFailed,
                .closed => error.ArtifactSinkClosed,
            };
        }
    };

    /// One metadata resolution per name, derived from the same `Entry` lookup
    /// `dispatch` uses. Selection misses stay conservative through the
    /// `ToolDispatcher` derived defaults (false/null/.never), and dispatch of
    /// such a name fails with UnknownTool above.
    fn resolveMeta(raw: *const anyopaque, name: []const u8) ?tools.ToolMeta {
        const self: *const Selection = @ptrCast(@alignCast(raw));
        const entry = self.find(name) orelse return null;
        return .{
            .kind = switch (entry.executor) {
                .builtin => .builtin,
                .host_sync, .host_stream => .host,
                .isolated => .external,
            },
            .category = entry.category,
            .replay = entry.replay,
            .prefetch_safe = entry.prefetch_safe,
        };
    }

    fn nameAt(raw: *const anyopaque, index: usize) ?[]const u8 {
        const self: *const Selection = @ptrCast(@alignCast(raw));
        if (index >= self.entries.len) return null;
        return self.entries[index].definition.name;
    }
};

test "Selection rejects names outside Runtime and dispatches only selected entries" {
    var catalog = try Catalog.initBuiltins(std.testing.allocator, &.{ "Read", "Grep" });
    defer catalog.deinit();
    var selection = try Selection.init(std.testing.allocator, &catalog, &.{"Read"});
    defer selection.deinit();

    try std.testing.expect(selection.contains("Read"));
    try std.testing.expect(!selection.contains("Grep"));
    try std.testing.expect(selection.dispatcher().isBuiltin("Read"));
    try std.testing.expect(!selection.dispatcher().isBuiltin("Grep"));
    try std.testing.expect(selection.dispatcher().replayDeclaration("Read") == .read_only);
    try std.testing.expect(selection.dispatcher().replayDeclaration("Grep") == .never);
    try std.testing.expectError(error.ToolNotInRuntime, Selection.init(std.testing.allocator, &catalog, &.{"Bash"}));

    var ctx = tools.ToolContext{ .allocator = std.testing.allocator, .tool_dispatcher = selection.dispatcher() };
    try std.testing.expectError(error.UnknownTool, tools.dispatch(&ctx, "Grep", "{}"));
    const names = try tools.availableToolNames(&ctx, std.testing.allocator);
    defer std.testing.allocator.free(names);
    try std.testing.expectEqualStrings("Read", names);
    try std.testing.expect(tools.suggestToolName(&ctx, "Grepp") == null);
}

test "builtin admission verifies runtime dependencies before advertisement" {
    const toolchain = @import("../util/toolchain.zig");

    // 依赖不可解析:声明了 runtime_dependency 的内置(Glob/Grep)必须在准入时
    // 被拒,而不是进 catalog 后首调返回 RipgrepNotFound。
    toolchain.test_ripgrep_override = false;
    defer toolchain.test_ripgrep_override = null;
    try std.testing.expectError(
        error.ToolDependencyUnavailable,
        Catalog.initBuiltins(std.testing.allocator, &.{"Grep"}),
    );
    try std.testing.expectError(
        error.ToolDependencyUnavailable,
        Catalog.initBuiltins(std.testing.allocator, &.{ "Read", "Glob" }),
    );

    // 门只看真实依赖:同一环境下无依赖声明的内置不受影响。
    var unaffected = try Catalog.initBuiltins(std.testing.allocator, &.{ "Read", "Write", "Bash" });
    unaffected.deinit();

    // 依赖可解析:Glob/Grep 正常准入并可被 Session 选择。
    toolchain.test_ripgrep_override = true;
    var catalog = try Catalog.initBuiltins(std.testing.allocator, &.{ "Glob", "Grep" });
    defer catalog.deinit();
    try std.testing.expect(catalog.find("Glob") != null);
    try std.testing.expect(catalog.find("Grep") != null);
}

test "Selection redescribes builtin tool descriptions via describe_fn (缺陷 A)" {
    // 缺陷 A:Selection.init 必须调 redescribeForContext,让 describe_fn 生成平台化动态长描述,
    // 而非静态短句(builtin.description)。Bash 的 describe_fn 输出 "Executes a given bash command"(POSIX)
    // 或 "Runs a PowerShell command"(Windows),静态短句是 "Execute a bash command"。
    var catalog = try Catalog.initBuiltins(std.testing.allocator, &.{ "Read", "Bash", "Grep" });
    defer catalog.deinit();
    var selection = try Selection.init(std.testing.allocator, &catalog, &.{ "Read", "Bash", "Grep" });
    defer selection.deinit();

    // 找 Bash 的 definition,断言描述已被 describe_fn 重写为长描述。
    var bash_desc: []const u8 = "";
    for (selection.definitions) |d| {
        if (std.mem.eql(u8, d.name, "Bash")) bash_desc = d.description;
    }
    try std.testing.expect(bash_desc.len > 0);
    // 静态短句是 "Execute a bash command";describe_fn 输出 "Executes a given bash command"(POSIX)
    // 或 "Runs a PowerShell command"(Windows)。断言不再是静态短句。
    try std.testing.expect(!std.mem.eql(u8, bash_desc, "Execute a bash command"));
    // POSIX 上含 "Executes a given bash command";Windows 上含 "PowerShell"。
    if (@import("builtin").os.tag == .windows) {
        try std.testing.expect(std.mem.indexOf(u8, bash_desc, "PowerShell") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, bash_desc, "Executes a given bash command") != null);
    }
}

test "Selection preserves Host tool descriptions (redescribe skips unknown tools)" {
    // redescribeForContext 对 Host 工具(getTool 返 null)跳过,描述保持 Catalog clone 的原样。
    // 这确保 Host 工具描述不被库改写——描述所有权归 Host。
    var probe = HostProbe{};
    const host_def = json.ToolDefinition{
        .name = "host_probe",
        .description = "Host-defined probe description",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{} },
    };
    const host_tools = [_]HostSyncTool{
        .{ .definition = host_def, .ctx = @ptrCast(&probe), .execute = HostProbe.execute },
    };
    var catalog = try Catalog.init(std.testing.allocator, &.{"Read"}, &host_tools);
    defer catalog.deinit();
    var selection = try Selection.init(std.testing.allocator, &catalog, &.{ "Read", "host_probe" });
    defer selection.deinit();

    for (selection.definitions) |d| {
        if (std.mem.eql(u8, d.name, "host_probe")) {
            // Host 工具描述保持原样,未被 redescribe 改写
            try std.testing.expectEqualStrings("Host-defined probe description", d.description);
        }
    }
}

const HostProbe = struct {
    calls: usize = 0,
    releases: usize = 0,
    last_session: SessionIdT = SessionIdT.single,
    last_run_id: u64 = 0,
    last_host_ctx: ?*anyopaque = null,

    const SessionIdT = @import("session_id.zig").SessionId;

    fn execute(raw: *anyopaque, identity: HostRunIdentity, args: []const u8) error{OutOfMemory}!HostToolOutcome {
        const self: *HostProbe = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.last_session = identity.identity.session_id;
        self.last_run_id = identity.identity.run_id;
        self.last_host_ctx = identity.host_session_ctx;
        return .{ .ok = .{ .bytes = args, .release_ctx = raw, .releaseFn = release } };
    }

    fn release(raw: *anyopaque, _: []const u8) void {
        const self: *HostProbe = @ptrCast(@alignCast(raw));
        self.releases += 1;
    }
};

const HostStreamProbe = struct {
    bytes_to_write: usize,
    calls: usize = 0,
    writes: usize = 0,
    max_chunk_bytes: usize = 0,

    fn execute(
        raw: *anyopaque,
        _: HostRunIdentity,
        _: []const u8,
        sink: *const HostResultSink,
    ) HostStreamExecuteError!HostStreamOutcome {
        const self: *HostStreamProbe = @ptrCast(@alignCast(raw));
        self.calls += 1;
        var chunk: [64 * 1024]u8 = undefined;
        @memset(&chunk, 's');
        var remaining = self.bytes_to_write;
        while (remaining != 0) {
            const count = @min(remaining, chunk.len);
            try sink.write(chunk[0..count]);
            self.writes += 1;
            self.max_chunk_bytes = @max(self.max_chunk_bytes, count);
            remaining -= count;
        }
        return .{ .artifact = .text_utf8 };
    }

    fn tool(self: *HostStreamProbe) HostStreamTool {
        return .{
            .definition = .{
                .name = "HostStream",
                .description = "Stream directly into the kernel CAS",
                .input_schema = .{ .type = "object", .required = &.{} },
            },
            .ctx = self,
            .execute = execute,
        };
    }
};

const HostStreamFailureProbe = struct {
    calls: usize = 0,
    releases: usize = 0,

    fn execute(
        raw: *anyopaque,
        _: HostRunIdentity,
        _: []const u8,
        sink: *const HostResultSink,
    ) HostStreamExecuteError!HostStreamOutcome {
        const self: *HostStreamFailureProbe = @ptrCast(@alignCast(raw));
        self.calls += 1;
        try sink.write("partial-must-rollback");
        return .{ .failed = .{
            .bytes = "bounded failure detail",
            .release_ctx = self,
            .releaseFn = release,
        } };
    }

    fn release(raw: *anyopaque, _: []const u8) void {
        const self: *HostStreamFailureProbe = @ptrCast(@alignCast(raw));
        self.releases += 1;
    }

    fn tool(self: *HostStreamFailureProbe) HostStreamTool {
        return .{
            .definition = .{
                .name = "HostStreamFailure",
                .description = "Write partial bytes then fail",
                .input_schema = .{ .type = "object", .required = &.{} },
            },
            .ctx = self,
            .execute = execute,
        };
    }
};

const HostTextContractProbe = struct {
    payload: []const u8,
    status: enum { ok, failed },
    calls: usize = 0,
    releases: usize = 0,

    fn execute(
        raw: *anyopaque,
        _: HostRunIdentity,
        _: []const u8,
    ) error{OutOfMemory}!HostToolOutcome {
        const self: *HostTextContractProbe = @ptrCast(@alignCast(raw));
        self.calls += 1;
        const result = HostToolResult{
            .bytes = self.payload,
            .release_ctx = self,
            .releaseFn = release,
        };
        return switch (self.status) {
            .ok => .{ .ok = result },
            .failed => .{ .failed = result },
        };
    }

    fn release(raw: *anyopaque, _: []const u8) void {
        const self: *HostTextContractProbe = @ptrCast(@alignCast(raw));
        self.releases += 1;
    }

    fn tool(self: *HostTextContractProbe, name: []const u8) HostSyncTool {
        return .{
            .definition = .{
                .name = name,
                .description = "Exercise the legacy Host text contract",
                .input_schema = .{ .type = "object", .required = &.{} },
            },
            .ctx = self,
            .execute = execute,
        };
    }
};

fn testIdentity(anchor: *anyopaque) HostRunIdentity {
    return .{
        .identity = .{ .session_id = @import("session_id.zig").SessionId.single, .run_id = 7 },
        .host_session_ctx = anchor,
    };
}

fn hostTool(name: []const u8, probe: *HostProbe) HostSyncTool {
    return .{
        .definition = .{
            .name = name,
            .description = "Host echo",
            .input_schema = .{
                .type = "object",
                .prop_specs = &.{.{ .name = "text", .type = "string" }},
                .required = &.{"text"},
            },
        },
        .ctx = probe,
        .execute = HostProbe.execute,
    };
}

test "Host sync entry is Runtime-owned, selected once and released once" {
    var probe = HostProbe{};
    var name = [_]u8{ 'H', 'o', 's', 't', 'E', 'c', 'h', 'o' };
    var catalog = try Catalog.init(std.testing.allocator, &.{"Read"}, &.{hostTool(&name, &probe)});
    defer catalog.deinit();
    name[0] = 'X';

    var selection = try Selection.init(std.testing.allocator, &catalog, &.{"HostEcho"});
    defer selection.deinit();
    const dispatcher = selection.dispatcher();
    try std.testing.expect(!dispatcher.prefetchSafe("HostEcho"));
    try std.testing.expect(dispatcher.isHostSync("HostEcho"));
    var ctx = tools.ToolContext{
        .allocator = std.testing.allocator,
        .session_id = "session-a",
        .host_run = testIdentity(@ptrCast(&probe)),
        .tool_dispatcher = dispatcher,
    };
    var outcome = try tools.dispatch(&ctx, "HostEcho", "{\"text\":\"ok\"}");
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{\"text\":\"ok\"}", outcome.ok.@"inline".bytes);
    try std.testing.expectEqual(@as(u64, 7), probe.last_run_id);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&probe)), probe.last_host_ctx);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), probe.releases);
    // 身份缺失是接线 bug,不是工具错误——独立错误码,不落模型可见面。
    ctx.host_run = null;
    try std.testing.expectError(error.HostRunIdentityMissing, tools.dispatch(&ctx, "HostEcho", "{\"text\":\"x\"}"));
}

test "Host sync boundary rejects invalid UTF-8 and oversized legacy buffers before copy" {
    const allocator = std.testing.allocator;
    const invalid_utf8 = [_]u8{0xff};
    var invalid = HostTextContractProbe{ .payload = &invalid_utf8, .status = .ok };
    const oversized = try allocator.alloc(u8, MAX_HOST_SYNC_RESULT_BYTES + 1);
    defer allocator.free(oversized);
    @memset(oversized, 'x');
    var too_large = HostTextContractProbe{ .payload = oversized, .status = .ok };
    var invalid_failure = HostTextContractProbe{ .payload = &invalid_utf8, .status = .failed };
    var catalog = try Catalog.init(
        allocator,
        &.{},
        &.{
            invalid.tool("InvalidUtf8Host"),
            too_large.tool("OversizedHost"),
            invalid_failure.tool("InvalidFailureDetail"),
        },
    );
    defer catalog.deinit();
    var selection = try Selection.init(
        allocator,
        &catalog,
        &.{ "InvalidUtf8Host", "OversizedHost", "InvalidFailureDetail" },
    );
    defer selection.deinit();
    var ctx = tools.ToolContext{
        .allocator = allocator,
        .host_run = testIdentity(@ptrCast(&invalid)),
        .tool_dispatcher = selection.dispatcher(),
    };

    var invalid_outcome = try tools.dispatch(&ctx, "InvalidUtf8Host", "{}");
    defer invalid_outcome.deinit(allocator);
    try std.testing.expect(invalid_outcome == .host_failed);
    try std.testing.expect(invalid_outcome.host_failed == null);

    ctx.host_run = testIdentity(@ptrCast(&too_large));
    var oversized_outcome = try tools.dispatch(&ctx, "OversizedHost", "{}");
    defer oversized_outcome.deinit(allocator);
    try std.testing.expect(oversized_outcome == .host_failed);
    try std.testing.expect(oversized_outcome.host_failed == null);

    ctx.host_run = testIdentity(@ptrCast(&invalid_failure));
    var failure_outcome = try tools.dispatch(&ctx, "InvalidFailureDetail", "{}");
    defer failure_outcome.deinit(allocator);
    try std.testing.expect(failure_outcome == .host_failed);
    try std.testing.expect(failure_outcome.host_failed == null);
    try std.testing.expectEqual(@as(usize, 1), invalid.releases);
    try std.testing.expectEqual(@as(usize, 1), too_large.releases);
    try std.testing.expectEqual(@as(usize, 1), invalid_failure.releases);
}

test "Host stream entry writes byte zero into CAS and returns no full inline buffer" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const payload_bytes = 17 * 1024 * 1024 + 37;
    var probe = HostStreamProbe{ .bytes_to_write = payload_bytes };
    var catalog = try Catalog.initWithExecutors(
        allocator,
        &.{},
        &.{},
        &.{probe.tool()},
        &.{},
    );
    defer catalog.deinit();
    var selection = try Selection.init(allocator, &catalog, &.{"HostStream"});
    defer selection.deinit();
    var ctx = tools.ToolContext{
        .allocator = allocator,
        .host_run = testIdentity(@ptrCast(&probe)),
        .tool_dispatcher = selection.dispatcher(),
        .artifact_root = root,
    };
    var outcome = try tools.dispatch(&ctx, "HostStream", "{}");
    defer outcome.deinit(allocator);
    try std.testing.expect(outcome == .ok);
    try std.testing.expect(outcome.ok == .artifact);
    try std.testing.expectEqual(@as(u64, payload_bytes), outcome.ok.artifact.stored.bytes);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(probe.writes > 1);
    try std.testing.expectEqual(@as(usize, 64 * 1024), probe.max_chunk_bytes);
    var recovered = try artifact_store.readChunk(
        allocator,
        root,
        outcome.ok.artifact.stored.id(),
        0,
        32,
    );
    defer recovered.deinit();
    try std.testing.expectEqualSlices(u8, "ssssssssssssssssssssssssssssssss", recovered.bytes);
}

test "Host stream entry requires artifact authority before callback" {
    var probe = HostStreamProbe{ .bytes_to_write = 1 };
    var catalog = try Catalog.initWithExecutors(
        std.testing.allocator,
        &.{},
        &.{},
        &.{probe.tool()},
        &.{},
    );
    defer catalog.deinit();
    var selection = try Selection.init(std.testing.allocator, &catalog, &.{"HostStream"});
    defer selection.deinit();
    var ctx = tools.ToolContext{
        .allocator = std.testing.allocator,
        .host_run = testIdentity(@ptrCast(&probe)),
        .tool_dispatcher = selection.dispatcher(),
    };
    try std.testing.expectError(error.ArtifactStoreRequired, tools.dispatch(&ctx, "HostStream", "{}"));
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
}

test "Host stream business failure rolls back partial bytes and releases detail once" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    _ = try artifact_store.persist(allocator, root, "unrelated-sentinel");
    var probe = HostStreamFailureProbe{};
    var catalog = try Catalog.initWithExecutors(
        allocator,
        &.{},
        &.{},
        &.{probe.tool()},
        &.{},
    );
    defer catalog.deinit();
    var selection = try Selection.init(allocator, &catalog, &.{"HostStreamFailure"});
    defer selection.deinit();
    var ctx = tools.ToolContext{
        .allocator = allocator,
        .host_run = testIdentity(@ptrCast(&probe)),
        .tool_dispatcher = selection.dispatcher(),
        .artifact_root = root,
    };
    var outcome = try tools.dispatch(&ctx, "HostStreamFailure", "{}");
    defer outcome.deinit(allocator);
    try std.testing.expect(outcome == .host_failed);
    try std.testing.expectEqualStrings("bounded failure detail", outcome.host_failed.?);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), probe.releases);
    const digest = artifact_store.sha256Hex("partial-must-rollback");
    var id: [artifact_store.ID_BYTES]u8 = undefined;
    @memcpy(id[0..artifact_store.ID_PREFIX.len], artifact_store.ID_PREFIX);
    @memcpy(id[artifact_store.ID_PREFIX.len..], digest[0..]);
    try std.testing.expectError(
        error.ArtifactNotFound,
        artifact_store.readChunk(allocator, root, id[0..], 0, 1),
    );
}

test "Host stream cancellation is latched and publishes no partial artifact" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    _ = try artifact_store.persist(allocator, root, "unrelated-sentinel");
    var probe = HostStreamProbe{ .bytes_to_write = 1 };
    var catalog = try Catalog.initWithExecutors(allocator, &.{}, &.{}, &.{probe.tool()}, &.{});
    defer catalog.deinit();
    var selection = try Selection.init(allocator, &catalog, &.{"HostStream"});
    defer selection.deinit();
    var abort = @import("../util/abort.zig").AbortSignal.init();
    abort.abort(.user_interrupt);
    var ctx = tools.ToolContext{
        .allocator = allocator,
        .abort = &abort,
        .host_run = testIdentity(@ptrCast(&probe)),
        .tool_dispatcher = selection.dispatcher(),
        .artifact_root = root,
    };
    try std.testing.expectError(error.Aborted, tools.dispatch(&ctx, "HostStream", "{}"));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    const digest = artifact_store.sha256Hex("s");
    var id: [artifact_store.ID_BYTES]u8 = undefined;
    @memcpy(id[0..artifact_store.ID_PREFIX.len], artifact_store.ID_PREFIX);
    @memcpy(id[artifact_store.ID_PREFIX.len..], digest[0..]);
    try std.testing.expectError(
        error.ArtifactNotFound,
        artifact_store.readChunk(allocator, root, id[0..], 0, 1),
    );
}

test "Host stream sink latches the artifact size violation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var spool = try artifact_store.Spool.begin(allocator, root_buffer[0..root_len]);
    defer spool.deinit();
    spool.preview.total_bytes = artifact_store.MAX_ARTIFACT_BYTES;
    var state = Selection.StreamState{ .spool = &spool, .abort = null };
    const sink = HostResultSink{ .ctx = &state, .writeFn = Selection.StreamState.write };
    try std.testing.expectError(error.ArtifactTooLarge, sink.write("x"));
    spool.preview.total_bytes = 0;
    try std.testing.expectError(error.ArtifactTooLarge, sink.write("now-small"));
    try std.testing.expectError(error.ArtifactTooLarge, state.requireHealthy());
}

test "Host stream equal bytes render cache-stable envelopes across artifact roots" {
    const allocator = std.testing.allocator;
    var first_tmp = std.testing.tmpDir(.{});
    defer first_tmp.cleanup();
    var second_tmp = std.testing.tmpDir(.{});
    defer second_tmp.cleanup();
    var first_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var second_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const first_len = try first_tmp.dir.realPath(std.testing.io, &first_buffer);
    const second_len = try second_tmp.dir.realPath(std.testing.io, &second_buffer);
    const first_root = first_buffer[0..first_len];
    const second_root = second_buffer[0..second_len];
    var probe = HostStreamProbe{ .bytes_to_write = 4097 };
    var catalog = try Catalog.initWithExecutors(allocator, &.{}, &.{}, &.{probe.tool()}, &.{});
    defer catalog.deinit();
    var selection = try Selection.init(allocator, &catalog, &.{"HostStream"});
    defer selection.deinit();
    var first_ctx = tools.ToolContext{
        .allocator = allocator,
        .host_run = testIdentity(@ptrCast(&probe)),
        .tool_dispatcher = selection.dispatcher(),
        .artifact_root = first_root,
    };
    var second_ctx = first_ctx;
    second_ctx.artifact_root = second_root;
    var first = try tools.dispatch(&first_ctx, "HostStream", "{}");
    defer first.deinit(allocator);
    var second = try tools.dispatch(&second_ctx, "HostStream", "{}");
    defer second.deinit(allocator);
    try std.testing.expect(first == .ok and first.ok == .artifact);
    try std.testing.expect(second == .ok and second.ok == .artifact);
    var first_rendered = try first.ok.render(allocator);
    defer first_rendered.deinit(allocator);
    var second_rendered = try second.ok.render(allocator);
    defer second_rendered.deinit(allocator);
    try std.testing.expectEqualStrings(first_rendered.bytes, second_rendered.bytes);
    try std.testing.expect(std.mem.indexOf(u8, first_rendered.bytes, first_root) == null);
    try std.testing.expect(std.mem.indexOf(u8, first_rendered.bytes, second_root) == null);
    try std.testing.expect(std.mem.indexOf(u8, first_rendered.bytes, "ReadArtifact") != null);
}

test "Host sync names cannot duplicate built-ins or each other" {
    var first = HostProbe{};
    var second = HostProbe{};
    try std.testing.expectError(error.DuplicateToolName, Catalog.init(std.testing.allocator, &.{"Read"}, &.{hostTool("Read", &first)}));
    try std.testing.expectError(error.DuplicateToolName, Catalog.init(std.testing.allocator, &.{}, &.{ hostTool("HostEcho", &first), hostTool("HostEcho", &second) }));
}

test "Host tool named Read is not classified as the built-in file tool" {
    var probe = HostProbe{};
    var catalog = try Catalog.init(std.testing.allocator, &.{}, &.{hostTool("Read", &probe)});
    defer catalog.deinit();
    var selection = try Selection.init(std.testing.allocator, &catalog, &.{"Read"});
    defer selection.deinit();

    const dispatcher = selection.dispatcher();
    try std.testing.expect(dispatcher.isHostSync("Read"));
    try std.testing.expect(!dispatcher.isBuiltin("Read"));
}

test "Host sync registration rejects non-object tool schemas" {
    var probe = HostProbe{};
    var invalid = hostTool("HostArray", &probe);
    invalid.definition.input_schema.type = "array";
    try std.testing.expectError(error.InvalidHostTool, Catalog.init(std.testing.allocator, &.{}, &.{invalid}));
}

test "Host sync selections sharing one Runtime keep executors isolated" {
    var first = HostProbe{};
    var second = HostProbe{};
    var catalog = try Catalog.init(std.testing.allocator, &.{}, &.{ hostTool("HostA", &first), hostTool("HostB", &second) });
    defer catalog.deinit();
    var selection_a = try Selection.init(std.testing.allocator, &catalog, &.{"HostA"});
    defer selection_a.deinit();
    var selection_b = try Selection.init(std.testing.allocator, &catalog, &.{"HostB"});
    defer selection_b.deinit();

    var ctx_a = tools.ToolContext{ .allocator = std.testing.allocator, .host_run = testIdentity(@ptrCast(&first)), .tool_dispatcher = selection_a.dispatcher() };
    var ctx_b = tools.ToolContext{ .allocator = std.testing.allocator, .host_run = testIdentity(@ptrCast(&second)), .tool_dispatcher = selection_b.dispatcher() };
    var outcome_a = try tools.dispatch(&ctx_a, "HostA", "{\"text\":\"a\"}");
    defer outcome_a.deinit(std.testing.allocator);
    var outcome_b = try tools.dispatch(&ctx_b, "HostB", "{\"text\":\"b\"}");
    defer outcome_b.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnknownTool, tools.dispatch(&ctx_a, "HostB", "{\"text\":\"x\"}"));
    try std.testing.expectEqual(@as(usize, 1), first.calls);
    try std.testing.expectEqual(@as(usize, 1), second.calls);
}

test "Host outcome detail is copied, released once and typed through dispatch" {
    const DetailProbe = struct {
        releases: usize = 0,
        mode: enum { failed_with_detail, failed_null, rejected_with_detail, rejected_null, fatal } = .failed_with_detail,

        fn execute(raw: *anyopaque, _: HostRunIdentity, _: []const u8) error{OutOfMemory}!HostToolOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return switch (self.mode) {
                .failed_with_detail => .{ .failed = .{ .bytes = "field 'x' is invalid", .release_ctx = raw, .releaseFn = release } },
                .failed_null => .{ .failed = null },
                .rejected_with_detail => .{ .rejected = .{ .bytes = "policy rejected", .release_ctx = raw, .releaseFn = release } },
                .rejected_null => .{ .rejected = null },
                .fatal => .fatal,
            };
        }

        fn release(raw: *anyopaque, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.releases += 1;
        }
    };
    var probe = DetailProbe{};
    var catalog = try Catalog.init(std.testing.allocator, &.{}, &.{.{
        .definition = .{
            .name = "HostDetail",
            .description = "detail probe",
            .input_schema = .{ .type = "object", .prop_specs = &.{}, .required = &.{} },
        },
        .ctx = &probe,
        .execute = DetailProbe.execute,
    }});
    defer catalog.deinit();
    var selection = try Selection.init(std.testing.allocator, &catalog, &.{"HostDetail"});
    defer selection.deinit();
    var ctx = tools.ToolContext{ .allocator = std.testing.allocator, .host_run = testIdentity(@ptrCast(&probe)), .tool_dispatcher = selection.dispatcher() };

    var failed = try tools.dispatch(&ctx, "HostDetail", "{}");
    defer failed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("field 'x' is invalid", failed.host_failed.?);
    try std.testing.expectEqual(@as(usize, 1), probe.releases); // 详情复制后恰好释放一次

    probe.mode = .failed_null;
    var failed_null = try tools.dispatch(&ctx, "HostDetail", "{}");
    defer failed_null.deinit(std.testing.allocator);
    try std.testing.expect(failed_null.host_failed == null);
    try std.testing.expectEqual(@as(usize, 1), probe.releases);

    probe.mode = .rejected_with_detail;
    var rejected_detail = try tools.dispatch(&ctx, "HostDetail", "{}");
    defer rejected_detail.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("policy rejected", rejected_detail.host_rejected.?);
    try std.testing.expectEqual(@as(usize, 2), probe.releases);

    probe.mode = .rejected_null;
    var rejected = try tools.dispatch(&ctx, "HostDetail", "{}");
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expect(rejected.host_rejected == null);
    try std.testing.expectEqual(@as(usize, 2), probe.releases); // null 详情无描述符可释放

    probe.mode = .fatal;
    var fatal = try tools.dispatch(&ctx, "HostDetail", "{}");
    defer fatal.deinit(std.testing.allocator);
    try std.testing.expect(fatal == .host_fatal); // fatal 无 payload
}

test "Host descriptors release exactly once when dispatch copy runs out of memory" {
    const CopyProbe = struct {
        releases: usize = 0,
        mode: enum { ok, failed } = .ok,

        fn execute(raw: *anyopaque, _: HostRunIdentity, _: []const u8) error{OutOfMemory}!HostToolOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const result = HostToolResult{ .bytes = "owned by host", .release_ctx = raw, .releaseFn = release };
            return switch (self.mode) {
                .ok => .{ .ok = result },
                .failed => .{ .failed = result },
            };
        }

        fn release(raw: *anyopaque, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.releases += 1;
        }
    };

    var probe = CopyProbe{};
    var catalog = try Catalog.init(std.testing.allocator, &.{}, &.{.{
        .definition = .{
            .name = "HostCopyOom",
            .description = "copy OOM probe",
            .input_schema = .{ .type = "object", .prop_specs = &.{}, .required = &.{} },
        },
        .ctx = &probe,
        .execute = CopyProbe.execute,
    }});
    defer catalog.deinit();
    var selection = try Selection.init(std.testing.allocator, &catalog, &.{"HostCopyOom"});
    defer selection.deinit();

    var failing_ok = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var ok_ctx = tools.ToolContext{ .allocator = failing_ok.allocator(), .host_run = testIdentity(@ptrCast(&probe)), .tool_dispatcher = selection.dispatcher() };
    try std.testing.expectError(error.OutOfMemory, tools.dispatch(&ok_ctx, "HostCopyOom", "{}"));
    try std.testing.expectEqual(@as(usize, 1), probe.releases);

    probe.mode = .failed;
    var failing_detail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var detail_ctx = tools.ToolContext{ .allocator = failing_detail.allocator(), .host_run = testIdentity(@ptrCast(&probe)), .tool_dispatcher = selection.dispatcher() };
    try std.testing.expectError(error.OutOfMemory, tools.dispatch(&detail_ctx, "HostCopyOom", "{}"));
    try std.testing.expectEqual(@as(usize, 2), probe.releases);
}
