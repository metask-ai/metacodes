//! App 应用生命周期：持有所有顶层组件（Config, Conversation, Client, ToolDefs, Permission, AbortSignal）。
//!
//! 目的：让 main.zig 只负责参数解析 + 启动 App。所有业务状态和循环逻辑从 main.zig 下沉到
//! 此模块 + core/agent_loop.zig。
//!
//! M1.5 起加入 AbortSignal + SIGINT 绑定。signal handler 只做 atomic store，async-signal-safe。

const std = @import("std");
const types = @import("types.zig");
const client_mod = @import("client.zig");
const json_mod = @import("json.zig");
const tools_mod = @import("tools.zig");
const permission_mod = @import("permission.zig");
const Conversation = @import("core/conversation.zig").Conversation;
const AbortSignal = @import("util/abort.zig").AbortSignal;
const SkillSet = @import("skills/skill.zig").SkillSet;

/// 全局 AbortSignal 指针，供 signal handler 访问。installSigintHandler 绑定后非 null。
/// signal handler 只读该指针 + 调 abort.abort()——不分配、不 IO、不获锁。
var g_abort_signal: ?*AbortSignal = null;

pub const App = struct {
    allocator: std.mem.Allocator,
    config: types.Config,
    api_key: []const u8,
    conversation: Conversation,
    api_client: client_mod.Client,
    tool_defs: []json_mod.ToolDefinition,
    permission_ctx: permission_mod.PermissionContext,
    abort: AbortSignal,
    skills: SkillSet,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: types.Config,
        api_key: []const u8,
    ) !*App {
        const app = try allocator.create(App);
        errdefer allocator.destroy(app);

        const tool_defs = try tools_mod.toToolDefinitions(allocator);
        errdefer allocator.free(tool_defs);

        app.* = .{
            .allocator = allocator,
            .config = config,
            .api_key = api_key,
            .conversation = Conversation.init(allocator),
            .api_client = client_mod.Client.init(allocator, io, api_key, config.model),
            .tool_defs = tool_defs,
            .permission_ctx = permission_mod.createContext(config.permission_mode, allocator),
            .abort = AbortSignal.init(),
            .skills = SkillSet.init(allocator),
        };

        // 启动时加载 skills：project CWD + $HOME
        app.skills.loadFromStandardPaths("") catch {};

        // 探测 <base_url>/v1/models 取 model catalog（max_tokens）。失败静默，走本地 fallback。
        app.api_client.probeModels();
        // CLI --max-tokens 覆盖
        app.api_client.setMaxTokensOverride(config.max_tokens);

        return app;
    }

    pub fn deinit(app: *App) void {
        app.api_client.deinit();
        app.conversation.deinit();
        app.allocator.free(app.tool_defs);
        app.skills.deinit();
        app.allocator.destroy(app);
    }

    /// 把 app.abort 绑到进程级 SIGINT handler。只需调用一次。
    /// 再次按 Ctrl+C 时，handler 会 atomic-store true；主循环通过 isAborted() 观察。
    pub fn installSigintHandler(app: *App) !void {
        g_abort_signal = &app.abort;

        var act: std.posix.Sigaction = .{
            .handler = .{ .handler = sigintHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
    }
};

/// Signal handler: async-signal-safe (仅 atomic store)。
fn sigintHandler(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    if (g_abort_signal) |s| {
        s.abort(.user_ctrl_c);
    }
}

test "App init/deinit" {
    // 注意：init.io 在测试环境下不易构造，这里只校验 init/deinit 签名可用。
    // 真正的初始化测试放在集成测试层。
    _ = App;
}

