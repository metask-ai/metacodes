//! Provider 工厂(P0.5:"造 LLM 客户端"也走中立化)。
//!
//! 背景/债务:主循环选 provider 已中立(App.provider() switch provider_kind),但**构造** per-call
//! client 的路径(subagent spawn、并发 Task)硬编码 `client_mod.Client.initWithBaseUrl`(只造 Anthropic)。
//! 结果:parent 用 OpenAI/Gemini 时,子 agent 仍被迫用 Anthropic。
//!
//! 本工厂据 provider_kind 造对应具体 client(堆分配)+ 独立 io_runtime,包成 OwnedProvider:
//! `.provider()` 出中立 Provider vtable 给 agent_loop;`.anthropicClient()` 出具体 *Client(仅
//! Anthropic kind 非空)供 ctx.api_client(web_search 是 Anthropic server tool,只 Anthropic 用)。
//! 用完 `.deinit()` 释放具体 client + io。这样 subagent/并发 Task 的构造路径也 provider-neutral。

const std = @import("std");
const client_mod = @import("../client.zig");
const openai_mod = @import("openai_client.zig");
const gemini_mod = @import("gemini_client.zig");
const bedrock_mod = @import("bedrock_client.zig");
const provider_mod = @import("provider.zig");
const types = @import("../types.zig");
const dialect_mod = @import("dialect.zig");
const auth_header_mod = @import("auth_header.zig");
const limits_mod = @import("model_limits.zig");
const image_capability = @import("image_capability.zig");
const credential_mod = @import("credential_cell.zig");

/// 三选一具体 client。tagged union(ProviderKind)→ "kind 说 X 但字段 null" 的非法态
/// 编译期不可表示(遵 CLAUDE.md "Make Illegal States Unrepresentable")。
const OwnedClient = union(types.ProviderKind) {
    anthropic: *client_mod.Client,
    openai: *openai_mod.OpenAIClient,
    gemini: *gemini_mod.GeminiClient,
    bedrock: *bedrock_mod.BedrockClient,
};

pub const OwnedProvider = struct {
    io: *std.Io.Threaded,
    allocator: std.mem.Allocator,
    client: OwnedClient,

    /// 造出的 provider_kind(= client 的 active tag)。
    pub fn kind(self: *const OwnedProvider) types.ProviderKind {
        return std.meta.activeTag(self.client);
    }

    /// 中立 Provider vtable(agent_loop 用)。
    pub fn provider(self: *OwnedProvider) provider_mod.Provider {
        return switch (self.client) {
            .anthropic => |c| c.provider(),
            .openai => |c| c.provider(),
            .gemini => |c| c.provider(),
            .bedrock => |c| c.provider(),
        };
    }

    /// Anthropic 具体 client(供 ctx.api_client / web_search);非 Anthropic kind → null。
    pub fn anthropicClient(self: *OwnedProvider) ?*client_mod.Client {
        return switch (self.client) {
            .anthropic => |c| c,
            else => null,
        };
    }

    pub fn deinit(self: OwnedProvider) void {
        const a = self.allocator;
        switch (self.client) {
            .anthropic => |c| {
                c.deinit();
                a.destroy(c);
            },
            .openai => |c| {
                c.deinit();
                a.destroy(c);
            },
            .gemini => |c| {
                c.deinit();
                a.destroy(c);
            },
            .bedrock => |c| {
                c.deinit();
                a.destroy(c);
            },
        }
        self.io.deinit();
        a.destroy(self.io);
    }
};

/// Opaque capability for creating a per-call provider. ToolContext carries this
/// instead of API keys/base URLs, so concurrent tools can ask their owner for an
/// isolated client without leaking provider configuration across the tool API.
pub const Factory = struct {
    ctx: *anyopaque,
    makeFn: *const fn (ctx: *anyopaque) anyerror!OwnedProvider,

    pub fn make(self: Factory) anyerror!OwnedProvider {
        return self.makeFn(self.ctx);
    }
};

/// 据 provider_kind 造 OwnedProvider(独立 io_runtime + 对应具体 client,堆分配)。
/// openai_protocol 走默认 chat/completions(需要 Responses 的调用方走带 resolver 的全参入口)。
pub fn makeProvider(
    a: std.mem.Allocator,
    kind: types.ProviderKind,
    api_key: []const u8,
    model: []const u8,
    base_url: ?[]const u8,
) !OwnedProvider {
    return makeProviderWithDialectResolver(a, kind, api_key, model, base_url, .chat_completions, .builtin());
}

/// Optional per-route knobs. Defaulted so existing call sites keep their exact
/// behaviour; a call site that owns a resolved offer passes its auth scheme so
/// child agents authenticate the same way the parent does.
pub const Options = struct {
    auth_scheme: ?auth_header_mod.AuthScheme = null,
    /// The vendor dialect the route declares, for the model the provider is
    /// built for; empty infers it from the model name. Travels with
    /// `auth_scheme`: both are properties of the route.
    dialect: dialect_mod.DialectDeclaration = .{},
    limits: ?limits_mod.ModelLimitsSource = null,
    /// 收头阶段流空闲上限(毫秒;见 client.zig DEFAULT_STREAM_IDLE_TIMEOUT_MS)。null = 各 client 自己
    /// 从 env/默认取;测试用小值让"对端沉默"在秒级可复现。
    stream_idle_timeout_ms: ?u64 = null,
    /// 正文阶段流空闲上限的平覆盖(毫秒;见 client.zig bodyIdleLimitMs)。null = 各 client 自己
    /// 从 env 取,未设则按 max_tokens 自动;测试用小值让正文阶段 stall 秒级可复现。
    stream_body_idle_timeout_ms: ?u64 = null,
    /// Host declarations about models' image input (issue #273), already
    /// validated and borrowed; each client keeps its own copy. They outrank
    /// the catalog and the family table.
    capability_declarations: image_capability.Declarations = .{},
};

/// Runtime-scoped provider construction. The resolver is a borrowed immutable
/// view owned by the Runtime Snapshot and therefore remains stable for the
/// complete Provider/Session lifetime.
/// openai_protocol 仅 OpenAI arm 消费(anthropic/gemini 忽略):子 provider 继承父的
/// wire 协议选择(chat/completions 或 Responses),协议绝不从 base_url/model 推断。
pub fn makeProviderWithDialectResolver(
    a: std.mem.Allocator,
    kind: types.ProviderKind,
    api_key: []const u8,
    model: []const u8,
    base_url: ?[]const u8,
    openai_protocol: types.OpenAIProtocol,
    dialect_resolver: dialect_mod.Resolver,
) !OwnedProvider {
    return makeProviderWithOptions(a, kind, .{ .fixed = api_key }, model, base_url, openai_protocol, dialect_resolver, .{});
}

/// `credential` is borrowed: fixed bytes or a replaceable cell must outlive
/// the returned provider.
pub fn makeProviderWithOptions(
    a: std.mem.Allocator,
    kind: types.ProviderKind,
    credential: credential_mod.Credential,
    model: []const u8,
    base_url: ?[]const u8,
    openai_protocol: types.OpenAIProtocol,
    dialect_resolver: dialect_mod.Resolver,
    options: Options,
) !OwnedProvider {
    @import("../util/log.zig").info("mp", "makeProvider kind={s} base_url={s}", .{ @tagName(kind), base_url orelse "<null>" });
    const io_rt = try a.create(std.Io.Threaded);
    errdefer a.destroy(io_rt);
    @import("../util/log.zig").info("mp", "io_rt created, calling Threaded.init", .{});
    io_rt.* = @import("platform").signal.threadedIo(a, .{});
    errdefer io_rt.deinit();
    @import("../util/log.zig").info("mp", "Threaded.init done, creating client", .{});

    const owned: OwnedClient = switch (kind) {
        .anthropic => blk: {
            const c = try a.create(client_mod.Client);
            errdefer {
                c.deinit();
                a.destroy(c);
            }
            c.* = client_mod.Client.initWithBaseUrl(a, io_rt.io(), "", model, base_url);
            c.credential = credential;
            c.dialect_resolver = dialect_resolver;
            c.declared_dialect = options.dialect;
            c.auth_scheme = options.auth_scheme;
            if (options.stream_idle_timeout_ms) |idle| c.stream_idle_timeout_ms = idle;
            if (options.stream_body_idle_timeout_ms) |idle| c.stream_body_idle_timeout_ms = idle;
            if (options.limits) |limits| {
                if (limits.catalog) |catalog| c.catalog = try catalog.clone(a);
                c.model_context = limits.model_context;
                c.max_tokens_override = limits.max_tokens_override;
            }
            c.host_capabilities = try options.capability_declarations.clone(a);
            break :blk .{ .anthropic = c };
        },
        .openai => blk: {
            const c = try a.create(openai_mod.OpenAIClient);
            errdefer a.destroy(c);
            c.* = openai_mod.OpenAIClient.init(a, io_rt.io(), "", model, base_url);
            c.credential = credential;
            errdefer c.deinit();
            c.protocol = openai_protocol;
            c.dialect_resolver = dialect_resolver;
            c.declared_dialect = options.dialect;
            c.auth_scheme = options.auth_scheme;
            if (options.stream_idle_timeout_ms) |idle| c.stream_idle_timeout_ms = idle;
            if (options.stream_body_idle_timeout_ms) |idle| c.stream_body_idle_timeout_ms = idle;
            if (options.limits) |limits| {
                if (limits.catalog) |catalog| c.catalog = try catalog.clone(a);
                c.model_context = limits.model_context;
            }
            c.host_capabilities = try options.capability_declarations.clone(a);
            break :blk .{ .openai = c };
        },
        .gemini => blk: {
            const c = try a.create(gemini_mod.GeminiClient);
            errdefer a.destroy(c);
            c.* = gemini_mod.GeminiClient.init(a, io_rt.io(), "", model, base_url);
            c.credential = credential;
            errdefer c.deinit();
            c.dialect_resolver = dialect_resolver;
            c.declared_dialect = options.dialect;
            if (options.stream_idle_timeout_ms) |idle| c.stream_idle_timeout_ms = idle;
            if (options.stream_body_idle_timeout_ms) |idle| c.stream_body_idle_timeout_ms = idle;
            if (options.limits) |limits| {
                if (limits.catalog) |catalog| c.catalog = try catalog.clone(a);
                c.model_context = limits.model_context;
            }
            c.host_capabilities = try options.capability_declarations.clone(a);
            break :blk .{ .gemini = c };
        },
        .bedrock => blk: {
            const c = try a.create(bedrock_mod.BedrockClient);
            errdefer a.destroy(c);
            c.* = bedrock_mod.BedrockClient.init(a, io_rt.io(), "", model, base_url);
            c.credential = credential;
            errdefer c.deinit();
            c.dialect_resolver = dialect_resolver;
            c.declared_dialect = options.dialect;
            c.auth_scheme = options.auth_scheme;
            if (options.stream_idle_timeout_ms) |idle| c.stream_idle_timeout_ms = idle;
            if (options.stream_body_idle_timeout_ms) |idle| c.stream_body_idle_timeout_ms = idle;
            if (options.limits) |limits| {
                if (limits.catalog) |catalog| c.catalog = try catalog.clone(a);
                c.model_context = limits.model_context;
                c.max_tokens_override = limits.max_tokens_override;
            }
            c.host_capabilities = try options.capability_declarations.clone(a);
            break :blk .{ .bedrock = c };
        },
    };
    return .{ .io = io_rt, .allocator = a, .client = owned };
}

test "makeProvider:三 kind 各造对应 client + provider() 出中立 vtable" {
    const a = std.testing.allocator;
    inline for (.{ types.ProviderKind.anthropic, .openai, .gemini, .bedrock }) |k| {
        var op = try makeProvider(a, k, "test-key", "some-model", null);
        defer op.deinit();
        try std.testing.expectEqual(k, op.kind());
        // provider() 不 crash + model 透传(经具体 client)。
        const p = op.provider();
        try std.testing.expectEqualStrings("some-model", p.model());
        // anthropicClient 仅 anthropic 非空。
        if (k == .anthropic) {
            try std.testing.expect(op.anthropicClient() != null);
        } else {
            try std.testing.expect(op.anthropicClient() == null);
        }
    }
}

test "provider factory limits inherit and defaults remain provider specific" {
    const a = std.testing.allocator;
    var catalog = @import("catalog.zig").Catalog.init(a);
    defer catalog.deinit();
    try catalog.loadFromModelsListJson("{\"data\":[{\"id\":\"GLM-5.2\",\"max_tokens\":64000,\"max_input_tokens\":1048576}]} ");
    var context = @import("../app/model_context.zig").ModelContext.init(a);
    defer context.deinit();
    context.parse("[models]\n\"gpt-5\" = 400000\n");

    const limits = limits_mod.ModelLimitsSource{ .catalog = &catalog, .model_context = &context };
    var anthropic = try makeProviderWithOptions(a, .anthropic, .{ .fixed = "test-key" }, "GLM-5.2", null, .chat_completions, .builtin(), .{ .limits = limits });
    defer anthropic.deinit();
    try std.testing.expectEqual(@as(u32, 64000), anthropic.provider().maxTokensFor("glm-5.2"));
    try std.testing.expectEqual(@as(u32, 1048576), anthropic.provider().maxInputTokensFor("GLM-5.2"));

    var openai = try makeProviderWithOptions(a, .openai, .{ .fixed = "test-key" }, "gpt-5", null, .chat_completions, .builtin(), .{ .limits = limits });
    defer openai.deinit();
    try std.testing.expectEqual(@as(u32, 400000), openai.provider().maxInputTokensFor("GPT-5-mini"));
    try std.testing.expectEqual(@as(u32, 4096), openai.provider().maxTokensFor("gpt-5"));

    var overridden = try makeProviderWithOptions(a, .anthropic, .{ .fixed = "test-key" }, "GLM-5.2", null, .chat_completions, .builtin(), .{ .limits = .{ .catalog = &catalog, .max_tokens_override = 1234 } });
    defer overridden.deinit();
    try std.testing.expectEqual(@as(u32, 1234), overridden.provider().maxTokensFor("GLM-5.2"));

    var anthropic_default = try makeProvider(a, .anthropic, "test-key", "unknown", null);
    defer anthropic_default.deinit();
    try std.testing.expectEqual(@as(u32, 200000), anthropic_default.provider().maxInputTokensFor("unknown"));
    try std.testing.expectEqual(@as(u32, 32000), anthropic_default.provider().maxTokensFor("unknown"));
    var openai_default = try makeProvider(a, .openai, "test-key", "unknown", null);
    defer openai_default.deinit();
    try std.testing.expectEqual(@as(u32, 128000), openai_default.provider().maxInputTokensFor("unknown"));
    try std.testing.expectEqual(@as(u32, 4096), openai_default.provider().maxTokensFor("unknown"));
}
