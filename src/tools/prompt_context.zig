//! PromptContext:生成工具长描述时的运行时上下文。
//!
//! 对应 cc/src/utils/api.ts 的 toolToAPISchema() 传给 tool.prompt(ctx) 的对象——
//! 让每个工具的 description 能按权限模式、当前工具集、agent 类型动态变化(动态耦合)。
//!
//! prompt 与工具集耦合的回归守卫见 tests/component/prompt_tool_coupling_test.zig。

const std = @import("std");
const PermissionMode = @import("../types.zig").PermissionMode;

pub const PromptContext = struct {
    /// 当前权限模式(plan/auto/...)。预留:未来可让描述按权限收紧措辞。
    permission_mode: PermissionMode = .default,
    /// 当前启用的工具名集合。描述里引用其它工具(如 Grep 提"多轮搜索用 Agent")时,
    /// 据此判断该工具是否存在——不存在则省略那句(对齐 TS embedded 分支)。
    enabled_tool_names: []const []const u8 = &.{},
    /// "" = 主对话;否则是 subagent 类型名(Explore/Plan/general-purpose/<custom>)。
    /// 只读 agent(Explore/Plan)的工具描述可加只读提醒。
    agent_type: []const u8 = "",
    /// 是否在 Bash 描述里包含 Git 协议段(对应 TS shouldIncludeGitInstructions)。
    include_git: bool = true,
    /// Swarm(teams/teammates)是否启用(--agent-teams)。false 时 TeamCreate/TeamDelete/
    /// SendMessage 不进 advertised tool_defs——避免污染单 agent 会话的工具菜单(对齐 cc
    /// agentSwarmsEnabled 门,Linus/PM SW2 F5)。
    agent_teams: bool = false,
    /// Whether TinyKG-specific memory tools are part of this runtime treatment.
    /// Task tools remain common to every arm; without TinyKG they use only the
    /// in-session task store.
    tinykg_enabled: bool = true,

    /// 便利:某工具名是否在当前启用集里。
    pub fn hasTool(self: *const PromptContext, name: []const u8) bool {
        for (self.enabled_tool_names) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    /// agent_type 是否为只读 agent(Explore/Plan)。
    pub fn isReadonlyAgent(self: *const PromptContext) bool {
        return std.mem.eql(u8, self.agent_type, "Explore") or
            std.mem.eql(u8, self.agent_type, "Plan");
    }
};

test "hasTool finds enabled tool" {
    const ctx = PromptContext{ .enabled_tool_names = &.{ "Read", "Grep" } };
    try std.testing.expect(ctx.hasTool("Read"));
    try std.testing.expect(ctx.hasTool("Grep"));
    try std.testing.expect(!ctx.hasTool("Glob"));
}

test "isReadonlyAgent" {
    const a = PromptContext{ .agent_type = "Explore" };
    const b = PromptContext{ .agent_type = "general-purpose" };
    const c = PromptContext{};
    try std.testing.expect(a.isReadonlyAgent());
    try std.testing.expect(!b.isReadonlyAgent());
    try std.testing.expect(!c.isReadonlyAgent());
}
