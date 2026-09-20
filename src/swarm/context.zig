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
const SessionId = @import("../core/session_id.zig").SessionId;

/// 一个进程外 teammate 的 lead 侧记录(owned strings)。
pub const ProcessTeammate = struct {
    pid: i64, // 平台中立(Windows std.c.pid_t 是 HANDLE=*anyopaque,不能格式化/@intCast)
    session: SessionId,
    name: []u8, // sanitized
    worktree_path: []u8, // 空 = 无 worktree
    repo: []u8, // git repo 根(removeWorktree 的 git -C);空 = 用进程 cwd
};

pub const SwarmContext = struct {
    allocator: std.mem.Allocator,
    /// Session that owns this team roster; resume must not address a prior
    /// session's teammates by name.
    session: SessionId = SessionId.single,
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
    /// issue #16:lead 已解析路由的 provider-declared auth scheme。null = 历史
    /// `authorization: Bearer` 字节。teammate 必须继承——lead 换到用 `x-api-key`
    /// 的 provider 后,teammate 还发 bearer 就是拿对的密钥打错的头。
    auth_scheme: ?@import("../provider/credential.zig").AuthScheme = null,
    /// Immutable App/Runtime-scoped resolver; in-process teammates drain before
    /// the owning plugin Snapshot is destroyed.
    dialect_resolver: dialect_mod.Resolver = .builtin(),
    limits: ?@import("../api/model_limits.zig").ModelLimitsSource = null,

    /// 非阻塞 reap:对进程外 teammate waitpid(WNOHANG),已退出的收尸+removeWorktree+摘除记录。
    /// 返回仍存活的数量。POSIX only(Windows 上没有 waitpid,直接报 0;列表本身未必为空,
    /// 注入 spawn_fn 时照样会登记——释放由 terminateProcessTeammates 负责)。
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
        if (self.process_teammates.items.len == 0) return;
        if (@import("builtin").os.tag == .windows) {
            // 没有 fork/kill/waitpid 可做,但记录里的 owned 字符串仍是本 context 的:
            // spawnTeammateProcess 接受任意 spawn_fn(测试注入 mock),登记成功后条目
            // 就存在。裸 return 会让 name/worktree_path/repo 全部泄漏——deinit 只释放
            // 列表本身。这里只跳过 POSIX 的信号、收尸与 worktree 删除,释放照做。
            for (self.process_teammates.items) |*pt| {
                self.allocator.free(pt.name);
                self.allocator.free(pt.worktree_path);
                self.allocator.free(pt.repo);
            }
            self.process_teammates.clearRetainingCapacity();
            return;
        }
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

    /// A lead can be resumed in a fresh process with no in-memory child list.
    /// Before deleting the durable team directory, refuse to proceed when the
    /// persisted roster says a process child exists without a matching local
    /// pid record. Even an idle child can wake on a mailbox message, so this
    /// conservative check prevents a resumed lead from deleting a live child's
    /// mailbox and worktree state.
    pub fn hasUntrackedProcessMember(self: *SwarmContext) bool {
        if (!self.is_lead or self.home.len == 0 or self.team_sanitized.len == 0) return false;
        var cfg_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cfg = self.configPath(&cfg_buf);
        var tf = team_mod.load(self.allocator, cfg) orelse return true;
        defer tf.deinit();
        const lead = tf.lead_session_id orelse return true;
        if (!std.mem.eql(u8, lead, self.session.asSlice())) return true;
        for (tf.members.items) |*member| {
            if (!std.mem.eql(u8, member.backend_type, "process")) continue;
            var tracked = false;
            for (self.process_teammates.items) |*process_member| {
                if (std.mem.eql(u8, process_member.session.asSlice(), self.session.asSlice()) and
                    std.mem.eql(u8, process_member.name, member.name))
                {
                    tracked = true;
                    break;
                }
            }
            if (!tracked) return true;
        }
        return false;
    }

    pub fn deinit(self: *SwarmContext) void {
        self.detachTeam();
        self.process_teammates.deinit(self.allocator);
    }

    /// Drop the current roster before changing session identity. A team is
    /// runtime state, not transcript state; retaining it across `/resume`
    /// would let the resumed session address workers owned by the old one.
    /// This is also used by `deinit`, so all worker and worktree cleanup stays
    /// in one ordered path.
    pub fn detachTeam(self: *SwarmContext) void {
        const preserve_durable_team = self.hasUntrackedProcessMember();
        // SW6:先关进程外 teammate(SIGTERM→等死→收尸→removeWorktree;等死在删 worktree 之前,
        // 否则与 teammate 写 worktree 竞态),再收 in-process。
        self.terminateProcessTeammates(2000);
        // 先 abort+join 全 teammate 线程(它们可能在写 config/inbox),再清目录——顺序不可换。
        if (self.teammates) |*t| {
            t.deinit();
            self.teammates = null;
        }
        // SW4 orphan 清理:lead 退出或 resume 换 session 时删当前 team 目录。
        if (!preserve_durable_team and self.is_lead and self.team_sanitized.len > 0 and self.home.len > 0) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const dir = team_mod.teamDirPath(self.home, self.team_sanitized, &buf);
            if (dir.len > 0) @import("../util/fs.zig").removeTeamDirTree(dir);
        }
        if (self.team_sanitized.len > 0) {
            self.allocator.free(self.team_sanitized);
            self.team_sanitized = &.{};
        }
    }

    /// 是否在一个 team 里(可 SendMessage / 邮箱寻址)。**只看 team 名**——teammate 视角
    /// team_sanitized 有值但 teammates=null(不持 registry),仍算 in-team。lead 的 spawn/Delete
    /// 另经 is_lead + teammates.? 门控(见 tools.zig)。
    pub fn hasTeam(self: *const SwarmContext) bool {
        return self.team_sanitized.len > 0;
    }

    pub fn hasTeamForSession(self: *const SwarmContext, session: SessionId) bool {
        return self.hasTeam() and std.mem.eql(u8, self.session.asSlice(), session.asSlice());
    }

    /// config.json 路径(当前 team;无 team → "")。写进 buf。
    pub fn configPath(self: *const SwarmContext, buf: []u8) []const u8 {
        if (!self.hasTeam()) return "";
        return team_mod.configPath(self.home, self.team_sanitized, buf);
    }
};
