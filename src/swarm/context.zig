//! SwarmContext:App 拥有的 swarm 会话状态,经 ToolContext.swarm 传给工具。
//!
//! 一个进程一个 lead + 至多一个 team(对齐 cc 一 lead 一队铁律)。teammates registry
//! 在 TeamCreate 时惰性建、TeamDelete 时拆。self_name 区分调用者身份:lead = "team-lead",
//! teammate = 自己的 sanitized 名(teammate 的 ToolContext 也挂 swarm 让它能 SendMessage)。

const std = @import("std");
const teammate_mod = @import("teammate.zig");
const team_mod = @import("team.zig");
const types_mod = @import("../types.zig");
const dialect_mod = @import("../api/dialect.zig");

/// 一个进程外 teammate 的 lead 侧记录(owned strings)。
pub const ProcessTeammate = struct {
    pid: i64, // 平台中立(Windows std.c.pid_t 是 HANDLE=*anyopaque,不能格式化/@intCast)
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
    /// OpenAI wire 协议(仅 provider_kind==.openai 时消费):teammate 继承 lead 的显式选择。
    openai_protocol: types_mod.OpenAIProtocol = .chat_completions,
    /// Immutable App/Runtime-scoped resolver; in-process teammates drain before
    /// the owning plugin Snapshot is destroyed.
    dialect_resolver: dialect_mod.Resolver = .builtin(),

    /// 非阻塞 reap:对进程外 teammate waitpid(WNOHANG),已退出的收尸+removeWorktree+摘除记录。
    /// 返回仍存活的数量。POSIX only(Windows 列表恒空)。
    pub fn reapDeadProcessTeammates(self: *SwarmContext) usize {
        if (@import("builtin").os.tag == .windows) return 0;
        var i: usize = 0;
        while (i < self.process_teammates.items.len) {
            const pt = &self.process_teammates.items[i];
            var status: c_int = 0;
            const WNOHANG: c_int = 1;
            const r = std.c.waitpid(@intCast(pt.pid), &status, WNOHANG);
            // r==pid:已退出收尸完成。r==-1(ECHILD/ESRCH):非我子进程/已消失(如测试假 pid、
            // 已被收过)→ 同样清记录,绝不当"存活"(否则 terminate 白等宽限期)。r==0:仍活着。
            if (r == pt.pid or r == -1) {
                // 进程已死/不存在 → 清 worktree(无写入竞态)+ 释放记录。
                if (pt.worktree_path.len > 0)
                    @import("teammate_process.zig").removeWorktree(self.allocator, pt.worktree_path, pt.repo, null);
                self.allocator.free(pt.name);
                self.allocator.free(pt.worktree_path);
                self.allocator.free(pt.repo);
                _ = self.process_teammates.swapRemove(i);
                continue; // swapRemove 换入新元素,i 不动
            }
            i += 1;
        }
        return self.process_teammates.items.len;
    }

    /// 终止全部进程外 teammate:SIGTERM → 宽限期 poll waitpid(WNOHANG)→ 顽固 SIGKILL → 阻塞收尸
    /// → removeWorktree。**必须先等死再删 worktree**:teammate 可能还在写,强删是竞态(旧 bug)。
    pub fn terminateProcessTeammates(self: *SwarmContext, grace_ms: u64) void {
        if (@import("builtin").os.tag == .windows) return;
        if (self.process_teammates.items.len == 0) return;
        const time = @import("../util/time.zig");
        for (self.process_teammates.items) |*pt| _ = std.c.kill(@intCast(pt.pid), std.c.SIG.TERM);
        var waited: u64 = 0;
        while (self.reapDeadProcessTeammates() > 0 and waited < grace_ms) : (waited += 50) time.sleepMs(50);
        // 宽限期后仍活着的:SIGKILL + 阻塞收尸(KILL 不可忽略,waitpid 必返)。
        for (self.process_teammates.items) |*pt| {
            _ = std.c.kill(@intCast(pt.pid), std.c.SIG.KILL);
            var status: c_int = 0;
            _ = std.c.waitpid(@intCast(pt.pid), &status, 0);
            if (pt.worktree_path.len > 0)
                @import("teammate_process.zig").removeWorktree(self.allocator, pt.worktree_path, pt.repo, null);
            self.allocator.free(pt.name);
            self.allocator.free(pt.worktree_path);
            self.allocator.free(pt.repo);
        }
        self.process_teammates.clearRetainingCapacity();
    }

    pub fn deinit(self: *SwarmContext) void {
        // SW6:先关进程外 teammate(SIGTERM→等死→收尸→removeWorktree;等死在删 worktree 之前,
        // 否则与 teammate 写 worktree 竞态),再收 in-process。
        self.terminateProcessTeammates(2000);
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
