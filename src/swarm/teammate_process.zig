//! SW6:进程外 teammate 运行时(`metacodes --teammate --agent-name X --team-name Y ...`)。
//!
//! 与 in-process teammate(teammate.zig 线程)的区别与理由:
//!   - in-process:同进程线程,共享 cwd(chdir 是进程全局 → teammate 不能有独立工作目录)。
//!   - **out-of-process(本文件)**:独立进程,可 chdir 进自己的 git worktree(cwd 隔离,多
//!     teammate 并行改不同 worktree 不撞车)。身份经 CLI args 注入(--agent-name/--team-name/
//!     --parent-session-id/--cwd),不靠进程全局(对齐 cc spawnMultiAgent 的 CLI-args 身份)。
//!
//! 消息循环(对齐 cc out-of-process boot + inProcessRunner idle-wait,但作为进程 main):
//!   启动 chdir(worktree)→ 注册 config 成员(is_active)→ loop{ waitForMail(自己 inbox)→
//!   agent_loop.run → idle notification → 等下一条 } 直到 shutdown_request(from team-lead)/abort。
//!
//! 复用 mailbox.zig 全部原语(deliver/readUnread/markReadAt/classify/formatForModel)+ SwarmContext
//! (SendMessage 回 lead/peer)+ agent_loop.run。跟 in-process teammate 共享 SW1-SW5 的所有语义
//! (伪造防御 from==team-lead / 选择性标读 / 软截断不洗白 / 自领 KG frontier)。
//!
//! SW6 边界(runtime + lead-spawn 接线已做,真机 e2e 归 SW7):
//!   - ✅ **`--teammate` runtime**:main.zig dispatch;身份 CLI args;worktree chdir + **同步更新
//!     app.cwd_abs/project_dir**(Linus CRITICAL:光 chdir 没用,工具用 cwd_abs 解析路径);mailbox
//!     消息循环(waitForWork 镜像 in-process waitForMail);no_interactive_prompt fail-closed。
//!   - ✅ **lead-spawn 接线**:`--teammate-mode process` → Task(name) 走 spawnTeammateProcess(
//!     createWorktree(git -C repo)+ 登记 member backend_type=process/worktree_path + forkExecTeammate +
//!     追踪 process_teammates 供 deinit kill+removeWorktree)。DI mock 测接线(member 登记/追踪/保留名)。
//!   - ✅ **隔离建块**:createWorktree/removeWorktree(真 git,git -C,有测)/ buildTeammateArgv/
//!     selfExePath(有测)/ forkExecTeammate(fork 后**零分配**只 async-signal-safe,Linus HIGH 修)。
//!   - **register(SW7 真机 e2e + 剩项)**:① 完整 lead→fork+exec 真 metacodes→处理消息→shutdown
//!     e2e(须干净进程 harness——组件测试带 live MockServer 线程 fork() 多线程不安全);forkExecTeammate
//!     的真 fork+exec 待真机验。② plan-mode-required 非继承:buildTeammateArgv 不传 --permission →
//!     子进程默认 default(非 bypass),满足"绝不继承 bypass"但无显式 guard/测试,SW7 补。③ Seatbelt
//!     Bash 包裹:teammate 进程用同 App/同 Bash 工具,settings 开沙箱则自然套 wrapCommand(未测,SW7 验)。
//!   - **排除(用户指令)**:Linux bubblewrap 沙箱不做(登记差距矩阵)。

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../app.zig");
const agent_loop = @import("../core/agent_loop.zig");
const mailbox = @import("mailbox.zig");
const team_mod = @import("team.zig");
const swarm_ctx = @import("context.zig");
const util_time = @import("../util/time.zig");
const log = @import("../util/log.zig");
const pfs = @import("platform").fs;
const process_mod = @import("platform").process;
const SessionId = @import("../core/session_id.zig").SessionId;

pub const Identity = struct {
    name: []const u8, // 未清洗(内部 sanitize)
    team: []const u8, // 未清洗
    parent_session: []const u8 = "",
    lease_id: []const u8 = "",
    cwd: []const u8 = "", // 非空 → 启动 chdir(worktree 隔离)
};

/// 轮询间隔(同 in-process)。
const POLL_MS: u64 = 500;

/// 进程外 teammate 主循环。返回进程退出码。app 已由 main 建好(provider/tools/system_prompt)。
pub fn run(app: *app_mod.App, allocator: std.mem.Allocator, id: Identity) !u8 {
    var name_buf: [64]u8 = undefined;
    const name_s = team_mod.sanitizeAgentName(id.name[0..@min(id.name.len, 64)], &name_buf);
    if (name_s.len == 0 or id.name.len > 64 or !std.mem.eql(u8, name_s, id.name)) {
        log.err("swarm", "teammate process: empty/invalid --agent-name", .{});
        return 2;
    }
    // "team-lead" 保留名不可作 teammate 进程身份(同 in-process 伪造防御)。
    if (std.ascii.eqlIgnoreCase(name_s, team_mod.TEAM_LEAD_NAME)) {
        log.err("swarm", "teammate process: 'team-lead' is a reserved name", .{});
        return 2;
    }
    if (id.team.len == 0) {
        log.err("swarm", "teammate process: empty --team-name", .{});
        return 2;
    }
    if (id.parent_session.len == 0 or id.lease_id.len == 0) {
        log.err("swarm", "teammate process: parent session and lease are required", .{});
        return 2;
    }
    var team_buf: [64]u8 = undefined;
    const team_s = team_mod.sanitizeTeamName(id.team[0..@min(id.team.len, 64)], &team_buf);
    // The lead always passes the canonical team name. Reject transformed
    // input so a manually invoked child cannot traverse or alias another
    // team's directory through the path helpers.
    if (team_s.len == 0 or !std.mem.eql(u8, team_s, id.team)) {
        log.err("swarm", "teammate process: non-canonical --team-name", .{});
        return 2;
    }
    // Keep the child coordination identity distinct from the inherited
    // routing/session identity used for permissions, KG, and persistence.
    const agent_ident = @import("../core/session_id.zig").gen();
    const parent_session = if (id.parent_session.len > 0)
        (SessionId.fromSlice(id.parent_session) orelse {
            log.err("swarm", "teammate process: invalid --parent-session-id", .{});
            return 2;
        })
    else
        return 2;
    const lease_id = SessionId.fromSlice(id.lease_id) orelse {
        log.err("swarm", "teammate process: invalid --teammate-lease-id", .{});
        return 2;
    };
    app.adoptSessionIdentity(parent_session) catch |err| {
        log.err("swarm", "teammate process: cannot bind parent session writer: {s}", .{@errorName(err)});
        return 2;
    };

    // worktree 隔离:chdir 进自己的工作目录(独立进程,安全)。**关键(Linus SW6 CRITICAL)**:
    // 光 chdir 没用——所有路径工具用 ctx.cwd_abs(App.init 时捕获的启动 cwd)解析相对路径,不是
    // 进程 cwd。必须 chdir 后**同步更新 app.cwd_abs + project_dir 到 worktree**,否则 teammate
    // 被告知在 worktree 干活却实际读写 lead 原仓(两 teammate 撞同一原目录,隔离形同虚设)。
    // Windows 无 std.c.chdir POSIX 绑定 + 进程外 teammate 在 Windows 不可用 → comptime 剔除。
    if (id.cwd.len > 0 and @import("builtin").os.tag != .windows) {
        var cwd_z: [std.fs.max_path_bytes:0]u8 = undefined;
        if (id.cwd.len < cwd_z.len) {
            @memcpy(cwd_z[0..id.cwd.len], id.cwd);
            cwd_z[id.cwd.len] = 0;
            if (std.c.chdir(&cwd_z) != 0) {
                log.err("swarm", "teammate process: chdir({s}) failed", .{id.cwd});
                return 2;
            } else {
                // realpath 归一化 worktree 路径 → 覆盖 app.cwd_abs(工具路径基准)+ project_dir(git 根)。
                var rp_buf: [std.fs.max_path_bytes]u8 = undefined;
                const resolved: []const u8 = if (pfs.realpath(&cwd_z, &rp_buf)) |r| std.mem.span(r) else {
                    log.err("swarm", "teammate process: cannot resolve cwd {s}", .{id.cwd});
                    return 2;
                };
                if (allocator.dupe(u8, resolved)) |new_cwd| {
                    if (app.cwd_abs) |old| allocator.free(old);
                    app.cwd_abs = new_cwd;
                } else |_| {}
                const new_root = @import("../skills/skill.zig").findRepoRoot(allocator, resolved) catch null;
                if (new_root) |nr| {
                    if (app.project_dir) |old| allocator.free(old);
                    app.project_dir = nr;
                }
                log.info("swarm", "teammate {s} chdir + cwd_abs → {s} (worktree isolation)", .{ name_s, resolved });
            }
        }
    }

    const home = app.homeDir();
    if (home.len == 0) {
        log.err("swarm", "teammate process: no HOME", .{});
        return 2;
    }

    // 路径。
    var inbox_buf: [std.fs.max_path_bytes]u8 = undefined;
    const inbox = team_mod.inboxPath(home, team_s, name_s, &inbox_buf);
    var lead_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lead_inbox = team_mod.inboxPath(home, team_s, team_mod.TEAM_LEAD_NAME, &lead_buf);
    var cfg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = team_mod.configPath(home, team_s, &cfg_buf);
    // The process has no in-memory registry, so the persisted config is its
    // ownership boundary. Fail closed if the team was replaced, the member
    // was removed, or an old config lacks session identities.
    if (!ownsPersistedMember(allocator, config_path, name_s, parent_session, lease_id, id.cwd)) {
        log.err("swarm", "teammate process: team lead session mismatch", .{});
        return 2;
    }
    mailbox.ensureInbox(inbox) catch {};
    mailbox.ensureInbox(lead_inbox) catch {};

    // SwarmContext(is_lead=false):让本 teammate 进程的 SendMessage 能回 lead/peer。
    var team_owned = try allocator.dupe(u8, team_s);
    var sw = swarm_ctx.SwarmContext{
        .allocator = allocator,
        .session = parent_session,
        .lease = lease_id,
        .home = home,
        .self_name = name_s,
        .is_lead = false,
        .team_sanitized = team_owned,
    };
    defer {
        // 不 rmrf(teammate 不清 team 目录,那是 lead 的职责);只 free team 名。
        allocator.free(team_owned);
        team_owned = &.{};
    }

    // teammate 权限:绝不读 fd 0(headless 进程 fd 0 可能是 pipe/tty,行为不定)。fail-closed。
    app.permission_ctx.no_interactive_prompt = true;

    // 对外身份(KG 租约):进程外 teammate 用 name@team 做 claim 身份(kanban 显名)。
    var agent_id_buf: [96]u8 = undefined;
    const agent_id = team_mod.formatAgentId(name_s, team_s, &agent_id_buf) orelse name_s;

    log.info("swarm", "teammate process {s} online (parent session {s})", .{ agent_id, id.parent_session });

    // 无 TUI:WriterBackend null-sink 吞流式输出(同 headless.zig),usage 仍累计。
    var wb = @import("../core/writer_backend.zig").WriterBackend.initNullWithUsage(&app.usage);
    const backend = wb.backend();

    // 初次:标记 active,发一个 "online" idle 通知让 lead 知道就绪。
    _ = setMemberActive(allocator, config_path, name_s, parent_session, lease_id, true);

    var exit_code: u8 = 0;
    while (true) {
        if (app.abort.isAborted()) break;
        if (!ownsPersistedMember(allocator, config_path, name_s, parent_session, lease_id, id.cwd)) break;

        // 等下一条工作(mailbox 轮询;shutdown 优先且仅认 team-lead)。
        const prompt = waitForWork(allocator, &app.abort, inbox, name_s, config_path, parent_session, lease_id, id.cwd) orelse break;
        defer allocator.free(prompt);
        if (!ownsPersistedMember(allocator, config_path, name_s, parent_session, lease_id, id.cwd)) break;

        if (!setMemberActive(allocator, config_path, name_s, parent_session, lease_id, true)) break;
        try app.conversation.appendText(.user, prompt);

        const result = agent_loop.run(
            &app.conversation,
            app.provider(),
            app.tool_defs,
            &app.permission_ctx,
            .{
                .session = parent_session,
                .abort = &app.abort,
                .api_client = app.anthropicClientOrNull(),
                .tool_defs = app.tool_defs,
                .system_prompt = app.system_prompt,
                .swarm = &sw,
                .tasks = &app.tasks,
                .kg = if (app.kg) |*k| k else null,
                .kg_projects_dir = app.kg_projects_dir,
                .dyn_registry = &app.dyn_registry,
                .agents = &app.agents,
                .parent_model = app.activeModel(),
                .project_dir = app.project_dir_or_empty(),
                // task#12(Linus review 第五处):进程外 teammate 的 Bash 也须套 sandbox。此前只传
                // cwd_abs/home_dir/additional_dirs,漏 .sandbox → ctx.sandbox=null → wrapCommand 被跳过,
                // Bash 脱管("共享 App 就以为共享沙箱"的假设缺口)。App 已从 settings 载 sandbox,直接接上。
                .sandbox = app.sandboxPtr(),
                .cwd_abs = app.cwdAbs(),
                .additional_dirs = app.additionalDirs(),
                .home_dir = home,
                .artifact_root = app.sessionDir() orelse "",
                .tool_result_metrics = &app.tool_result_metrics,
                // agent_ident 仍是进程自己的 24-hex session id，用于通用
                // agent-loop 身份。TinyKG 租约单独使用 name@team，保证宿主自领与
                // 模型后续 TaskUpdate/TaskStop 共用完全相同的 holder 字符串。
                .agent_ident = agent_ident,
                .kg_agent_ident = agent_id,
                .colorize = false,
            },
            &backend,
            allocator,
        ) catch |err| {
            log.warn("swarm", "teammate {s} run failed: {s}", .{ agent_id, @errorName(err) });
            _ = setMemberActive(allocator, config_path, name_s, parent_session, lease_id, false);
            sendNotice(allocator, lead_inbox, name_s, parent_session, lease_id, "failed", @errorName(err));
            exit_code = 1;
            continue; // 进程留活(lead 可 shutdown/nudge),不退出
        };

        _ = setMemberActive(allocator, config_path, name_s, parent_session, lease_id, false);
        // 软截断不洗白(同 in-process)。
        if (result.stop_reason == .end_turn) {
            sendNotice(allocator, lead_inbox, name_s, parent_session, lease_id, "available", null);
        } else if (result.stop_reason == .aborted) {
            break;
        } else {
            sendNotice(allocator, lead_inbox, name_s, parent_session, lease_id, "needs_continuation", @tagName(result.stop_reason));
        }
    }

    _ = setMemberActive(allocator, config_path, name_s, parent_session, lease_id, false);
    log.info("swarm", "teammate process {s} exiting", .{agent_id});
    return exit_code;
}

/// 等 mailbox 里下一条工作 prompt(owned)。null = 退出(abort / lead shutdown)。
/// 复刻 in-process waitForMail 的核心:shutdown 只认 team-lead;plain 组装成 prompt(lead 优先);
/// 协议消息留未读(SW3/SW4 消费者)。
fn waitForWork(
    a: std.mem.Allocator,
    abort: anytype,
    inbox: []const u8,
    self_name: []const u8,
    config_path: []const u8,
    session: SessionId,
    lease: SessionId,
    expected_cwd: []const u8,
) ?[]u8 {
    while (true) {
        if (abort.isAborted()) return null;
        if (!ownsPersistedMember(a, config_path, self_name, session, lease, expected_cwd)) return null;
        var unread = mailbox.readUnread(a, inbox) catch {
            util_time.sleepMs(POLL_MS);
            continue;
        };
        defer unread.deinit();
        if (unread.items.items.len > 0) {
            // shutdown(仅 team-lead)。
            for (unread.items.items) |*m| {
                if (mailbox.classify(a, m.text) != .shutdown_request) continue;
                if (!std.mem.eql(u8, m.from, team_mod.TEAM_LEAD_NAME) or
                    !leadMessageMatchesCurrentSession(m, session))
                {
                    const bad = [1]mailbox.Message{m.*};
                    mailbox.markReadAt(a, inbox, &bad) catch {};
                    continue; // 伪造 shutdown:丢弃
                }
                const one = [1]mailbox.Message{m.*};
                mailbox.markReadAt(a, inbox, &one) catch {};
                return null; // 优雅退出
            }
            // plain:lead 优先 + peer FIFO。
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(a);
            var consumed: std.ArrayList(mailbox.Message) = .empty;
            defer consumed.deinit(a);
            for ([_]bool{ true, false }) |lead_pass| {
                for (unread.items.items) |*m| {
                    const is_lead = std.mem.eql(u8, m.from, team_mod.TEAM_LEAD_NAME);
                    if (is_lead != lead_pass) continue;
                    if (mailbox.classify(a, m.text) != .plain) continue;
                    if (!plainMessageMatchesCurrentMember(a, config_path, self_name, session, m)) {
                        consumed.append(a, m.*) catch {};
                        continue;
                    }
                    const wire = mailbox.formatForModel(a, m) catch continue;
                    defer a.free(wire);
                    if (out.items.len > 0) out.appendSlice(a, "\n\n") catch {};
                    out.appendSlice(a, wire) catch {};
                    consumed.append(a, m.*) catch {};
                }
            }
            if (consumed.items.len > 0) {
                mailbox.markReadAt(a, inbox, consumed.items) catch {};
                return out.toOwnedSlice(a) catch null;
            }
        }
        util_time.sleepMs(POLL_MS);
    }
}

fn leadMessageMatchesCurrentSession(m: *const mailbox.Message, session: SessionId) bool {
    const raw_session = m.session_id orelse return false;
    const raw_lease = m.lease_id orelse return false;
    const sender_session = SessionId.fromSlice(raw_session) orelse return false;
    const sender_lease = SessionId.fromSlice(raw_lease) orelse return false;
    return std.mem.eql(u8, sender_session.asSlice(), session.asSlice()) and
        std.mem.eql(u8, sender_lease.asSlice(), session.asSlice());
}

fn plainMessageMatchesCurrentMember(
    a: std.mem.Allocator,
    config_path: []const u8,
    self_name: []const u8,
    session: SessionId,
    m: *const mailbox.Message,
) bool {
    const raw_session = m.session_id orelse return false;
    const raw_lease = m.lease_id orelse return false;
    const sender_session = SessionId.fromSlice(raw_session) orelse return false;
    const sender_lease = SessionId.fromSlice(raw_lease) orelse return false;
    if (!std.mem.eql(u8, sender_session.asSlice(), session.asSlice())) return false;
    var name_buf: [64]u8 = undefined;
    const sender = team_mod.sanitizeAgentName(m.from, &name_buf);
    if (std.mem.eql(u8, sender, team_mod.TEAM_LEAD_NAME)) {
        return std.mem.eql(u8, sender_lease.asSlice(), session.asSlice());
    }
    if (std.mem.eql(u8, sender, self_name)) return false;
    var tf = team_mod.load(a, config_path) orelse return false;
    defer tf.deinit();
    const member = tf.findMember(sender) orelse return false;
    const member_session = member.session_id orelse return false;
    const member_lease = member.lease_id orelse return false;
    return std.mem.eql(u8, member_session, sender_session.asSlice()) and
        std.mem.eql(u8, member_lease, sender_lease.asSlice());
}

fn sendNotice(
    a: std.mem.Allocator,
    lead_inbox: []const u8,
    name: []const u8,
    session: SessionId,
    lease: SessionId,
    reason: []const u8,
    detail: ?[]const u8,
) void {
    var ts_buf: [40]u8 = undefined;
    const ts = mailbox.formatIso8601(@divTrunc(util_time.nowWallNs(), 1_000_000), &ts_buf);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    out.writer.writeAll("{\"type\":\"idle_notification\",\"from\":") catch return;
    @import("../util/json.zig").writeJsonString(&out.writer, name) catch return;
    out.writer.writeAll(",\"session_id\":") catch return;
    @import("../util/json.zig").writeJsonString(&out.writer, session.asSlice()) catch return;
    out.writer.writeAll(",\"lease_id\":") catch return;
    @import("../util/json.zig").writeJsonString(&out.writer, lease.asSlice()) catch return;
    out.writer.writeAll(",\"timestamp\":") catch return;
    @import("../util/json.zig").writeJsonString(&out.writer, ts) catch return;
    out.writer.writeAll(",\"idleReason\":") catch return;
    @import("../util/json.zig").writeJsonString(&out.writer, reason) catch return;
    if (detail) |d| {
        if (std.mem.eql(u8, reason, "failed")) {
            out.writer.writeAll(",\"failureReason\":") catch return;
            @import("../util/json.zig").writeJsonString(&out.writer, d) catch return;
        } else {
            out.writer.writeAll(",\"stopReason\":") catch return;
            @import("../util/json.zig").writeJsonString(&out.writer, d) catch return;
        }
    }
    out.writer.writeByte('}') catch return;
    const body = out.toOwnedSlice() catch return;
    defer a.free(body);
    mailbox.deliverWithIdentity(
        a,
        lead_inbox,
        name,
        body,
        null,
        null,
        session.asSlice(),
        lease.asSlice(),
    ) catch {};
}

const ActiveCtx = struct { name: []const u8, lead_session: []const u8, lease: []const u8, active: bool };
fn setActiveMutate(c: ActiveCtx, tf: *team_mod.TeamFile) anyerror!void {
    const lead = tf.lead_session_id orelse return error.SessionMismatch;
    if (!std.mem.eql(u8, lead, c.lead_session)) return error.SessionMismatch;
    const m = tf.findMember(c.name) orelse return error.MemberNotFound;
    if (m.session_id == null or !std.mem.eql(u8, m.session_id.?, c.lead_session)) return error.SessionMismatch;
    if (m.lease_id == null or !std.mem.eql(u8, m.lease_id.?, c.lease)) return error.SessionMismatch;
    m.is_active = c.active;
}
fn setMemberActive(a: std.mem.Allocator, config_path: []const u8, name: []const u8, session: SessionId, lease: SessionId, active: bool) bool {
    if (config_path.len == 0) return false;
    team_mod.updateTeam(a, config_path, ActiveCtx{ .name = name, .lead_session = session.asSlice(), .lease = lease.asSlice(), .active = active }, setActiveMutate) catch return false;
    return true;
}

fn ownsPersistedMember(a: std.mem.Allocator, config_path: []const u8, name: []const u8, session: SessionId, lease: SessionId, expected_cwd: []const u8) bool {
    var tf = team_mod.load(a, config_path) orelse return false;
    defer tf.deinit();
    const lead = tf.lead_session_id orelse return false;
    if (!std.mem.eql(u8, lead, session.asSlice())) return false;
    const member = tf.findMember(name) orelse return false;
    const member_session = member.session_id orelse return false;
    const member_lease = member.lease_id orelse return false;
    if (!std.mem.eql(u8, member_session, session.asSlice()) or
        !std.mem.eql(u8, member_lease, lease.asSlice())) return false;
    if (!std.mem.eql(u8, member.cwd, expected_cwd)) return false;
    if (member.worktree_path) |worktree| if (!std.mem.eql(u8, worktree, expected_cwd)) return false;
    return true;
}

// ============================================================================
// Lead 侧:spawn 进程外 teammate(fork+exec metacodes --teammate)+ worktree 隔离
// ============================================================================

pub const SpawnProcessParams = struct {
    name: []const u8, // sanitized
    team: []const u8, // sanitized
    parent_session: []const u8 = "",
    lease_id: []const u8 = "",
    /// worktree/cwd 目录(非空 → teammate 进程 chdir 进去;lead 应已 git worktree add)。
    cwd: []const u8 = "",
    /// 额外 CLI flag 透传(如 --agent-teams --model X);借用。
    extra_flags: []const []const u8 = &.{},
};

/// 构造 teammate 子进程 argv(可测)。exe = 自身可执行文件;身份 + cwd + 透传 flag。
/// 返回 owned `[]?[*:0]const u8`(execve 格式,末尾 null);字符串挂 allocator,caller free(freeArgv)。
pub fn buildTeammateArgv(a: std.mem.Allocator, exe: []const u8, p: SpawnProcessParams) ![]?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    errdefer freeArgv(a, list.items);
    try list.append(a, (try a.dupeZ(u8, exe)).ptr);
    try list.append(a, (try a.dupeZ(u8, "--teammate")).ptr);
    try list.append(a, (try a.dupeZ(u8, "--agent-name")).ptr);
    try list.append(a, (try a.dupeZ(u8, p.name)).ptr);
    try list.append(a, (try a.dupeZ(u8, "--team-name")).ptr);
    try list.append(a, (try a.dupeZ(u8, p.team)).ptr);
    if (p.parent_session.len > 0) {
        try list.append(a, (try a.dupeZ(u8, "--parent-session-id")).ptr);
        try list.append(a, (try a.dupeZ(u8, p.parent_session)).ptr);
    }
    if (p.lease_id.len > 0) {
        try list.append(a, (try a.dupeZ(u8, "--teammate-lease-id")).ptr);
        try list.append(a, (try a.dupeZ(u8, p.lease_id)).ptr);
    }
    if (p.cwd.len > 0) {
        try list.append(a, (try a.dupeZ(u8, "--teammate-cwd")).ptr);
        try list.append(a, (try a.dupeZ(u8, p.cwd)).ptr);
    }
    for (p.extra_flags) |f| try list.append(a, (try a.dupeZ(u8, f)).ptr);
    try list.append(a, null);
    return list.toOwnedSlice(a);
}

pub fn freeArgv(a: std.mem.Allocator, argv: []?[*:0]const u8) void {
    for (argv) |item| {
        if (item) |s| a.free(std.mem.span(s));
    }
    a.free(argv);
}

/// 自身可执行文件路径(fork+exec teammate 用)。写进 buf,返回 slice;失败 null。
/// 实现收敛在 platform.paths(KgClient 等共用,三 OS 一份)。
pub fn selfExePath(buf: []u8) ?[]const u8 {
    return @import("platform").paths.selfExePath(buf);
}

/// git worktree add <path> -b <branch> <base>,在 repo 里执行(Linus SW6 MED-2:用 `git -C <repo>`
/// 显式指定 repo,不依赖多线程 lead 的进程全局 cwd)。repo 为空则退回进程 cwd(测试自 chdir)。
/// best-effort:失败返回 error(调用方降级为无 worktree,共享 cwd)。
pub fn createWorktree(a: std.mem.Allocator, wt_path: []const u8, branch: []const u8, base: []const u8, repo: []const u8, abort: anytype) !void {
    const common = @import("../tools/common.zig");
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer freeGitArgv(a, &argv);
    try appendZ(a, &argv, "/usr/bin/env");
    try appendZ(a, &argv, "git");
    if (repo.len > 0) {
        try appendZ(a, &argv, "-C");
        try appendZ(a, &argv, repo);
    }
    for ([_][]const u8{ "worktree", "add", "-b", branch, wt_path, base }) |w| try appendZ(a, &argv, w);
    try argv.append(a, null);
    const out = try common.spawnCaptureWithStderrTimed(argv.items, a, abort, 30_000, null, common.MAX_SPAWN_CAPTURE_BYTES, null);
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    if (out.exit_code != 0) return error.WorktreeAddFailed;
}

fn appendZ(a: std.mem.Allocator, argv: *std.ArrayList(?[*:0]const u8), s: []const u8) !void {
    try argv.append(a, (try a.dupeZ(u8, s)).ptr);
}
fn freeGitArgv(a: std.mem.Allocator, argv: *std.ArrayList(?[*:0]const u8)) void {
    for (argv.items) |it| if (it) |s| a.free(std.mem.span(s));
    argv.deinit(a);
}

/// git worktree remove --force <path>(teammate 关闭后 lead 清理)。repo 同款 -C。best-effort。
pub fn removeWorktree(a: std.mem.Allocator, wt_path: []const u8, repo: []const u8, abort: anytype) void {
    removeWorktreeStrict(a, wt_path, repo, abort) catch |err| {
        log.warn("swarm", "removeWorktree({s}) failed: {s}", .{ wt_path, @errorName(err) });
    };
}

/// Strict variant for callers that publish cleanup state. Returning success
/// means both git accepted the removal and the worktree path is confirmed
/// absent. Swarm teardown intentionally keeps the best-effort wrapper above;
/// AgentDef isolation uses this result to avoid reporting a false cleanup.
pub fn removeWorktreeStrict(a: std.mem.Allocator, wt_path: []const u8, repo: []const u8, abort: anytype) !void {
    const common = @import("../tools/common.zig");
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer freeGitArgv(a, &argv);
    try appendZ(a, &argv, "/usr/bin/env");
    try appendZ(a, &argv, "git");
    if (repo.len > 0) {
        try appendZ(a, &argv, "-C");
        try appendZ(a, &argv, repo);
    }
    for ([_][]const u8{ "worktree", "remove", "--force", wt_path }) |w| try appendZ(a, &argv, w);
    try argv.append(a, null);
    const out = try common.spawnCaptureWithStderrTimed(argv.items, a, abort, 30_000, null, common.MAX_SPAWN_CAPTURE_BYTES, null);
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    if (out.exit_code != 0) return error.WorktreeRemoveFailed;
    const path_z = try a.dupeZ(u8, wt_path);
    defer a.free(path_z);
    if (pfs.exists(path_z.ptr)) return error.WorktreeStillExists;
}

/// spawn 函数签名(DI):生产 = forkExecTeammate;测试注入 mock(不真 fork)验证接线。
pub const SpawnFn = *const fn (a: std.mem.Allocator, p: SpawnProcessParams) anyerror!i64;

/// **lead 侧:spawn 一个进程外 teammate**(C1 接线)。步骤:
///   ① 有 worktree_base → createWorktree(隔离 cwd);② 登记 config 成员(backend_type=process +
///   worktree_path);③ spawn_fn fork+exec 子进程;④ 记录 {pid,name,worktree} 进 sw.process_teammates
///   供关闭时 kill+removeWorktree。spawn_fn 默认 forkExecTeammate(生产);测试注入 mock。
///   前置:team config.json 已存在(TeamCreate 先行)。返回子 pid。
pub fn spawnTeammateProcess(
    sw: *swarm_ctx.SwarmContext,
    name_raw: []const u8,
    worktree_path: []const u8, // 空 = 无 worktree(共享 cwd)
    worktree_base: []const u8, // 非空且 worktree_path 非空 → createWorktree(git 起点,如 HEAD)
    repo: []const u8, // git repo 根(git -C;lead 的 project_dir)。空退回进程 cwd
    parent_session: []const u8,
    abort: anytype,
    spawn_fn: SpawnFn,
    /// lead 的 LSP 是否在位。false → 给子进程带上 `--no-lsp`。LSP 默认开之后不带就等于
    /// "lead 关了、teammate 照样起 rust-analyzer",逃生口在进程边界上漏掉。
    lsp_enabled: bool,
) !i64 {
    const a = sw.allocator;
    const parent_id = SessionId.fromSlice(parent_session) orelse return error.InvalidSession;
    const lease_id = @import("../core/session_id.zig").gen();
    if (!std.mem.eql(u8, parent_id.asSlice(), sw.session.asSlice()))
        return error.SessionMismatch;
    var name_buf: [64]u8 = undefined;
    const name_s = team_mod.sanitizeAgentName(name_raw[0..@min(name_raw.len, 64)], &name_buf);
    if (name_s.len == 0) return error.BadName;
    if (std.ascii.eqlIgnoreCase(name_s, team_mod.TEAM_LEAD_NAME)) return error.ReservedName;
    if (!sw.hasTeam()) return error.NoActiveTeam;

    // ① worktree(best-effort:失败降级为无隔离)。
    var effective_wt = worktree_path;
    if (worktree_path.len > 0 and worktree_base.len > 0) {
        var br_buf: [96]u8 = undefined;
        const branch = std.fmt.bufPrint(&br_buf, "teammate-{s}", .{name_s}) catch name_s;
        createWorktree(a, worktree_path, branch, worktree_base, repo, abort) catch {
            log.warn("swarm", "createWorktree({s}) failed; teammate {s} shares cwd", .{ worktree_path, name_s });
            effective_wt = ""; // 降级
        };
    }
    errdefer if (effective_wt.len > 0 and worktree_base.len > 0) removeWorktree(a, effective_wt, repo, abort);

    // ② 登记 config 成员(backend_type=process + worktree_path)。
    var cfg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cfg = sw.configPath(&cfg_buf);
    var id_buf: [96]u8 = undefined;
    const agent_id = team_mod.formatAgentId(name_s, sw.team_sanitized, &id_buf) orelse return error.BadName;
    const AddCtx = struct { agent_id: []const u8, name: []const u8, cwd: []const u8, wt: []const u8, session: []const u8, lease: []const u8 };
    const addFn = struct {
        fn f(c: AddCtx, tf: *team_mod.TeamFile) anyerror!void {
            const lead_session = tf.lead_session_id orelse return error.SessionMismatch;
            if (!std.mem.eql(u8, lead_session, c.session)) return error.SessionMismatch;
            if (tf.findMember(c.name) != null) return error.DuplicateTeammateName;
            try tf.addMember(.{
                .agent_id = c.agent_id,
                .name = c.name,
                .cwd = c.cwd,
                .session_id = c.session,
                .lease_id = c.lease,
                .worktree_path = if (c.wt.len > 0) c.wt else null,
                .backend_type = "process",
                .is_active = true,
            });
        }
    }.f;
    try team_mod.updateTeam(a, cfg, AddCtx{ .agent_id = agent_id, .name = name_s, .cwd = effective_wt, .wt = effective_wt, .session = parent_id.asSlice(), .lease = lease_id.asSlice() }, addFn);
    errdefer {
        const RmCtx = struct { name: []const u8, session: []const u8, lease: []const u8 };
        const rmFn = struct {
            fn f(c: RmCtx, tf: *team_mod.TeamFile) anyerror!void {
                const lead_session = tf.lead_session_id orelse return error.SessionMismatch;
                if (!std.mem.eql(u8, lead_session, c.session)) return error.SessionMismatch;
                const member = tf.findMember(c.name) orelse return error.MemberNotFound;
                const member_session = member.session_id orelse return error.SessionMismatch;
                const member_lease = member.lease_id orelse return error.SessionMismatch;
                if (!std.mem.eql(u8, member_session, c.session) or
                    !std.mem.eql(u8, member_lease, c.lease)) return error.SessionMismatch;
                _ = tf.removeMember(c.name);
            }
        }.f;
        team_mod.updateTeam(a, cfg, RmCtx{ .name = name_s, .session = parent_id.asSlice(), .lease = lease_id.asSlice() }, rmFn) catch {};
    }

    // ③ fork+exec(或 mock)。
    const lsp_off = [_][]const u8{"--no-lsp"};
    const pid = try spawn_fn(a, .{
        .name = name_s,
        .team = sw.team_sanitized,
        .parent_session = parent_session,
        .lease_id = lease_id.asSlice(),
        .cwd = effective_wt,
        .extra_flags = if (lsp_enabled) &.{} else &lsp_off,
    });
    // The child is live but not yet owned by process_teammates. Any
    // allocation/append failure below must terminate and reap it before the
    // config rollback removes its membership.
    // `forkExecTeammate` is POSIX-only and returns an integer pid.  The
    // injected spawn seam is still compiled on Windows for ABI/component
    // tests, where the platform process handle is a pointer.  Keep the
    // cleanup branch compile-time eliminated there instead of attempting an
    // invalid integer cast (and keep Windows ownership cleanup in
    // `terminateProcessTeammates`).
    errdefer {
        if (comptime builtin.os.tag != .windows) {
            process_mod.killJob(@intCast(pid));
            process_mod.reapBlocking(@intCast(pid));
        }
    }

    // ④ 记录供关闭清理。
    const name_owned = try a.dupe(u8, name_s);
    errdefer a.free(name_owned);
    const wt_owned = try a.dupe(u8, effective_wt);
    errdefer a.free(wt_owned);
    const repo_owned = try a.dupe(u8, repo);
    errdefer a.free(repo_owned);
    try sw.process_teammates.append(a, .{ .pid = pid, .session = parent_id, .lease = lease_id, .name = name_owned, .worktree_path = wt_owned, .repo = repo_owned });
    log.info("swarm", "spawned out-of-process teammate {s} pid={d} worktree={s}", .{ agent_id, pid, effective_wt });
    return pid;
}

/// fork+exec 一个 detached teammate 子进程。返回子 pid(>0)。失败返回 error。
/// setsid 脱离控制终端(不被 lead 的 Ctrl+C 直杀;lead 经 mailbox shutdown 优雅关);
/// stdin/out/err 重定向 /dev/null(headless teammate 绝不碰终端)。
pub fn forkExecTeammate(a: std.mem.Allocator, p: SpawnProcessParams) !i64 {
    // 进程外 teammate 是 POSIX-only(fork/setsid/execve)。Windows 不支持(要 CreateProcessW,
    // 完全不同)——comptime gate 让下方 POSIX 分支在 Windows 编译时被剔除,swarm 进程外后端
    // 在 Windows 降级不可用(--teammate-mode process 报 Unsupported)。in-process teammate 仍可用。
    if (@import("builtin").os.tag == .windows) return error.Unsupported;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = selfExePath(&exe_buf) orelse return error.NoSelfExe;
    // **全部分配在 fork 之前**(Linus SW6:fork 与 execve 之间只允许 async-signal-safe 调用,
    // 分配器加锁非 async-signal-safe,子进程里 dupeZ 可能死锁)。argv[0] 已是 exe 的 [*:0],
    // execve 直接用它,子进程不再分配。
    const argv = try buildTeammateArgv(a, exe, p);
    defer freeArgv(a, argv);
    const exe_path_z: [*:0]const u8 = argv[0].?; // argv[0] = dupeZ(exe),NUL 结尾

    // 与 platform/process 的 spawn 共用 fork 串行锁:这个 fork 不能落在别处"建了 pipe
    // 还没关子进程侧"的窗口里,否则那条 pipe 会跟着进 teammate 进程,对方永远等不到 EOF。
    process_mod.forkSerialLock();
    const pid = std.c.fork();
    if (pid < 0) {
        process_mod.forkSerialUnlock();
        return error.ForkFailed;
    }
    if (pid == 0) {
        // 子进程:只用 async-signal-safe 调用(setsid/open/dup2/close/execve),不分配。
        _ = std.c.setsid();
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 0);
            _ = std.c.dup2(devnull, 1);
            _ = std.c.dup2(devnull, 2);
            if (devnull > 2) _ = std.c.close(devnull);
        }
        _ = std.c.execve(exe_path_z, @ptrCast(argv.ptr), @ptrCast(std.c.environ));
        std.c._exit(127); // execve 失败
    }
    process_mod.forkSerialUnlock();
    return @intCast(pid); // 父进程:返回子 pid(i64 平台中立)
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Identity sanitize + reserved-name guard 语义" {
    var buf: [64]u8 = undefined;
    const s = team_mod.sanitizeAgentName("Worker_1", &buf);
    try testing.expectEqualStrings("Worker_1", s);
    try testing.expect(std.ascii.eqlIgnoreCase("team-lead", "Team-Lead"));
}

test "buildTeammateArgv: 身份 + cwd + 透传 flag 全在 argv" {
    const a = testing.allocator;
    const argv = try buildTeammateArgv(a, "/usr/local/bin/metacodes", .{
        .name = "bob",
        .team = "proj",
        .parent_session = "sess1",
        .lease_id = "lease1",
        .cwd = "/tmp/wt",
        .extra_flags = &.{ "--agent-teams", "--model", "x" },
    });
    defer freeArgv(a, argv);
    // 收集成字符串集合断言。
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(a);
    for (argv) |item| {
        if (item) |s| {
            try joined.appendSlice(a, std.mem.span(s));
            try joined.append(a, '\n');
        }
    }
    const all = joined.items;
    try testing.expect(std.mem.indexOf(u8, all, "/usr/local/bin/metacodes\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "--teammate\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "--agent-name\nbob\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "--team-name\nproj\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "--parent-session-id\nsess1\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "--teammate-lease-id\nlease1\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "--teammate-cwd\n/tmp/wt\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "--agent-teams\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "--model\nx\n") != null);
    try testing.expect(argv[argv.len - 1] == null); // execve null 结尾
}

test "buildTeammateArgv: 无 parent/cwd 时省略对应 flag" {
    const a = testing.allocator;
    const argv = try buildTeammateArgv(a, "metacodes", .{ .name = "x", .team = "t" });
    defer freeArgv(a, argv);
    var found_parent = false;
    var found_cwd = false;
    for (argv) |item| {
        if (item) |s| {
            const sp = std.mem.span(s);
            if (std.mem.eql(u8, sp, "--parent-session-id")) found_parent = true;
            if (std.mem.eql(u8, sp, "--teammate-cwd")) found_cwd = true;
        }
    }
    try testing.expect(!found_parent and !found_cwd);
}

test "process ownership requires lead session and per-spawn lease" {
    const a = testing.allocator;
    const session = SessionId.fromSlice("0123456789abcdef01234567").?;
    const lease = SessionId.fromSlice("fedcba987654321001234567").?;
    const other_lease = SessionId.fromSlice("aaaaaaaaaaaaaaaaaaaaaaaa").?;
    var home_buf: [256]u8 = undefined;
    const home = @import("../util/fs.zig").testing.uniqueDir(&home_buf, "cc-zig-process-owner");
    defer @import("../util/fs.zig").testing.rmrfBestEffort(home);
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    try @import("../util/fs.zig").mkdirParents(team_mod.teamDirPath(home, "proj", &dir_buf));
    var tf = team_mod.TeamFile{
        .allocator = a,
        .name = try a.dupe(u8, "proj"),
        .lead_agent_id = try a.dupe(u8, "team-lead@proj"),
        .lead_session_id = try a.dupe(u8, session.asSlice()),
    };
    defer tf.deinit();
    try tf.addMember(.{ .agent_id = "worker@proj", .name = "worker", .session_id = session.asSlice(), .lease_id = lease.asSlice() });
    var cfg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cfg = team_mod.configPath(home, "proj", &cfg_buf);
    try team_mod.save(a, &tf, cfg);
    try testing.expect(ownsPersistedMember(a, cfg, "worker", session, lease, ""));
    try testing.expect(!ownsPersistedMember(a, cfg, "worker", session, other_lease, ""));
    try testing.expect(!ownsPersistedMember(a, cfg, "worker", other_lease, lease, ""));
    try testing.expect(!ownsPersistedMember(a, cfg, "worker", session, lease, "/wrong-worktree"));
}

test "selfExePath 返回非空(macos/linux/windows)" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = selfExePath(&buf);
    try testing.expect(p != null);
    try testing.expect(p.?.len > 0);
}
