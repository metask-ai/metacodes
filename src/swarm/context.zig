//! SwarmContext:App 拥有的 swarm 会话状态,经 ToolContext.swarm 传给工具。
//!
//! 一个进程一个 lead + 至多一个 team(对齐 cc 一 lead 一队铁律)。teammates registry
//! 在 TeamCreate 时惰性建、TeamDelete 时拆。self_name 区分调用者身份:lead = "team-lead",
//! teammate = 自己的 sanitized 名(teammate 的 ToolContext 也挂 swarm 让它能 SendMessage)。

const std = @import("std");
const teammate_mod = @import("teammate.zig");
const team_mod = @import("team.zig");
const types_mod = @import("../types.zig");

/// 一个进程外 teammate 的 lead 侧记录(owned strings)。
pub const ProcessTeammate = struct {
    pid: std.c.pid_t,
    name: []u8, // sanitized
    worktree_path: []u8, // 空 = 无 worktree
    repo: []u8, // git repo 根(removeWorktree 的 git -C);空 = 用进程 cwd
};

pub const SwarmContext = struct {
    allocator: std.mem.Allocator,
    /// HOME(teams 目录根 `{home}/.metacodes/teams`)。空 = swarm 不可用。
    home: []const u8 = "",
    /// 调用者身份(lead="team-lead";teammate=自己 sanitized 名)。
    self_name: []const u8 = team_mod.TEAM_LEAD_NAME,
    /// 是否 lead(只有 lead 能 TeamCreate/TeamDelete/spawn teammate)。
    is_lead: bool = true,
    /// SW6:teammate spawn 后端。true = 进程外(fork+exec metacodes --teammate,cwd/worktree 隔离);
    /// false = 进程内线程(默认,SW1)。lead 从 config.teammate_out_of_process 设。
    out_of_process: bool = false,

    /// 当前 team 名(sanitized)。空 = 尚未 TeamCreate。owned(建/拆时管理)。
    team_sanitized: []u8 = &.{},
    /// teammates 运行时。null = 未 TeamCreate。lead 持有;teammate 侧为 null(不 spawn)。
    teammates: ?teammate_mod.TeammateRegistry = null,
    /// SW6:进程外 teammate 追踪(pid + name + worktree),供 lead 关闭时 kill + removeWorktree
    /// (in-process teammate 在 teammates registry;out-of-process 是独立进程,lead 只持记录)。
    process_teammates: std.ArrayList(ProcessTeammate) = .empty,

    // teammates registry 构造参数(TeamCreate 时据此建;dupe 自 App)。
    api_key: []const u8 = "",
    base_url: ?[]const u8 = null,
    model: []const u8 = "",
    provider_kind: types_mod.ProviderKind = .anthropic,

    pub fn deinit(self: *SwarmContext) void {
        // SW6:先关进程外 teammate(SIGTERM + removeWorktree),再收 in-process。
        for (self.process_teammates.items) |*pt| {
            _ = std.c.kill(pt.pid, std.c.SIG.TERM);
            if (pt.worktree_path.len > 0) {
                @import("teammate_process.zig").removeWorktree(self.allocator, pt.worktree_path, pt.repo, null);
            }
            self.allocator.free(pt.name);
            self.allocator.free(pt.worktree_path);
            self.allocator.free(pt.repo);
        }
        self.process_teammates.deinit(self.allocator);
        // 先 abort+join 全 teammate 线程(它们可能在写 config/inbox),再清目录——顺序不可换。
        if (self.teammates) |*t| t.deinit();
        // SW4 orphan 清理:lead 退出时删会话创建的 team 目录(对齐 cc cleanupSessionTeams;
        // 否则 lead 崩溃/正常退出都留一堆 ~/.metacodes/teams/<t> 僵尸目录)。
        if (self.is_lead and self.team_sanitized.len > 0 and self.home.len > 0) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const dir = team_mod.teamDirPath(self.home, self.team_sanitized, &buf);
            if (dir.len > 0) @import("../util/fs.zig").removeTeamDirTree(dir); // 生产安全(Linus HIGH-1)
        }
        if (self.team_sanitized.len > 0) self.allocator.free(self.team_sanitized);
    }

    /// 是否在一个 team 里(可 SendMessage / 邮箱寻址)。**只看 team 名**——teammate 视角
    /// team_sanitized 有值但 teammates=null(不持 registry),仍算 in-team。lead 的 spawn/Delete
    /// 另经 is_lead + teammates.? 门控(见 tools.zig)。
    pub fn hasTeam(self: *const SwarmContext) bool {
        return self.team_sanitized.len > 0;
    }

    /// config.json 路径(当前 team;无 team → "")。写进 buf。
    pub fn configPath(self: *const SwarmContext, buf: []u8) []const u8 {
        if (!self.hasTeam()) return "";
        return team_mod.configPath(self.home, self.team_sanitized, buf);
    }
};
