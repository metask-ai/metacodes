//! Swarm 工具 execute 函数(对齐 cc TeamCreate/TeamDelete/SendMessage)+ lead 邮箱轮询。
//!
//! 心智:TeamCreate 建队 + 建 teammates registry;spawn 走 Task 工具的 name+team_name
//! 分支(见 tools/agent.zig)→ SwarmContext.teammates.spawnTeammate;SendMessage 投消息进
//! 收件人邮箱(name 直达 / "*" 广播);TeamDelete 拆队。lead 的 REPL 空闲期调 pollLeadInbox
//! 把 teammate 的消息/通知拉进对话(idle 立即注入,busy 由上层排队)。
//!
//! 权限:TeamCreate/TeamDelete/spawn 只 lead 可做(is_lead 门)。SendMessage lead 与 teammate
//! 都可(peer 通信)。"裸文本对 peer 不可见,必须用 SendMessage"的纪律有两处载体:①SendMessage
//! 工具描述明写;②有 team 时 system prompt 追加 SWARM_ADDENDUM(见 system_prompt.zig,gated on
//! app.swarm.hasTeam())——对齐 cc 的 teammate addendum。

const std = @import("std");
const ToolContext = @import("../tools/context.zig").ToolContext;
const SwarmContext = @import("context.zig").SwarmContext;
const team_mod = @import("team.zig");
const mailbox = @import("mailbox.zig");
const teammate_mod = @import("teammate.zig");
const util_json = @import("../util/json.zig");
const util_time = @import("../util/time.zig");
const log = @import("../util/log.zig");

/// 有 team 活跃时追加到 system prompt(agent_loop 每轮注入,gated on swarm.hasTeam)。
/// 纪律核心:普通助手文本对 teammate/lead 互相不可见,一切协作必须走 SendMessage。
pub const SWARM_ADDENDUM =
    \\# Team collaboration (active team)
    \\You are part of a team. Your plain assistant text is NOT visible to your teammates or the
    \\team lead — the only way to communicate is the SendMessage tool. To hand off a result,
    \\ask a question, or coordinate, you MUST call SendMessage; narrating in prose sends it
    \\nowhere. As team lead, spawn teammates with the Task tool (pass a `name`) and talk to them
    \\with SendMessage(to: "<name>"). As a teammate, report progress and final results to the
    \\lead with SendMessage(to: "team-lead"). "Idle" notifications only signal turn-end, not
    \\completion — deliver actual work products explicitly via SendMessage.
    \\While a team is active, tasks you create with TaskCreate become the team's SHARED backlog:
    \\idle teammates automatically claim ready, unblocked tasks and work on them. Use TaskCreate
    \\to hand out delegatable work; if a task is NOT meant for a teammate, don't create it while
    \\the team is active. A teammate that claims a task MUST close it with TaskUpdate(status:
    \\"completed") when done, or it stays locked to that teammate.
;

// ============================================================================
// TeamCreate
// ============================================================================

/// {name:str(必需), description:str(可选)} → 建 team 目录 + config.json + teammates registry。
/// 一 lead 一队:已有 team → error.TeamAlreadyExists。
pub fn executeTeamCreate(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    // Teammates outlive the parent Run and therefore cannot borrow its journal
    // or RuntimeGate. Until each worker owns an independent durable RunControl,
    // enabling a project rule makes detached swarm creation fail closed.
    if (ctx.project_rule_gate != null) return error.ProjectRulesRequireSynchronousAgent;
    const sw = ctx.swarm orelse return error.SwarmUnavailable;
    if (!sw.is_lead) return error.NotTeamLead;
    if (sw.home.len == 0) return error.SwarmUnavailable;
    if (sw.hasTeam()) return error.TeamAlreadyExists;

    const name_raw = util_json.extractStringField(args, "name") orelse return error.MissingName;
    const name = try util_json.unescapeString(name_raw, ctx.allocator);
    defer ctx.allocator.free(name);
    if (name.len == 0 or name.len > 64) return error.BadName;

    var team_buf: [64]u8 = undefined;
    const team_s = team_mod.sanitizeTeamName(name, &team_buf);
    if (team_s.len == 0) return error.BadName;

    // 目录 + config.json(lead 为非成员,members 空)。
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = team_mod.teamDirPath(sw.home, team_s, &dirbuf);
    try @import("../util/fs.zig").mkdirParents(dir);

    var lead_id_buf: [96]u8 = undefined;
    const lead_id = team_mod.formatAgentId(team_mod.TEAM_LEAD_NAME, team_s, &lead_id_buf) orelse return error.BadName;

    var tf = team_mod.TeamFile{
        .allocator = ctx.allocator,
        .name = try ctx.allocator.dupe(u8, team_s),
        .lead_agent_id = try ctx.allocator.dupe(u8, lead_id),
        .created_at_ms = @intCast(@divTrunc(util_time.nowWallNs(), 1_000_000)),
    };
    defer tf.deinit();
    if (util_json.extractStringField(args, "description")) |d| {
        const desc = try util_json.unescapeString(d, ctx.allocator);
        tf.description = desc; // owned by tf, freed in deinit
    }
    var cfgbuf: [std.fs.max_path_bytes]u8 = undefined;
    const cfg_path = team_mod.configPath(sw.home, team_s, &cfgbuf);
    try team_mod.save(ctx.allocator, &tf, cfg_path);

    // lead 邮箱就位(teammate 通知投这里)。
    var leadbuf: [std.fs.max_path_bytes]u8 = undefined;
    try mailbox.ensureInbox(team_mod.inboxPath(sw.home, team_s, team_mod.TEAM_LEAD_NAME, &leadbuf));

    // teammates registry。ctx 虽是 *const,但 swarm 字段是 ?*SwarmContext,pointee 可变
    // (Zig const 浅层),无需 @constCast(Linus L2)。
    // 先 dupe team_sanitized(带 errdefer),再建 registry——避免 registry 建成后 dupe OOM
    // 留下"teammates 已置但 team_sanitized 未置"的半态(Linus L1)。
    const team_owned = try sw.allocator.dupe(u8, team_s);
    errdefer sw.allocator.free(team_owned);
    sw.teammates = try teammate_mod.TeammateRegistry.initWithDialectResolver(
        sw.allocator,
        sw.api_key,
        sw.base_url,
        sw.model,
        sw.provider_kind,
        sw.openai_protocol,
        sw.home,
        sw.dialect_resolver,
    );
    errdefer if (sw.teammates) |*t| {
        t.deinit();
        sw.teammates = null;
    };
    // SW3:确保共享 KG inbox root 存在(lead 的 TaskCreate 落此,teammate frontier 自领此)。
    // best-effort——KG 不可用只是没有 DAG 协调,mailbox 派活仍工作。
    ensureSharedTaskRoot(ctx);

    // 出口前最后一步赋值(此后不再有可失败操作);allocPrint 失败由上面两 errdefer 回滚。
    const out = try std.fmt.allocPrint(ctx.allocator, "{{\"team\":\"{s}\",\"leadAgentId\":\"{s}\",\"status\":\"created\"}}", .{ team_s, lead_id });
    sw.team_sanitized = team_owned;
    return out;
}

// ============================================================================
// TeamDelete
// ============================================================================

/// {} → 拆当前 team:拒绝有活跃成员;abort+join 全 teammate;删目录。
pub fn executeTeamDelete(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    _ = args;
    const sw = ctx.swarm orelse return error.SwarmUnavailable;
    if (!sw.is_lead) return error.NotTeamLead;
    if (!sw.hasTeam()) return error.NoActiveTeam;

    // 拒绝有 working/idle 成员(对齐 cc:活跃时不删)。
    if (sw.teammates) |*t| {
        if (t.liveCount() > 0) return error.TeammatesStillActive;
    }
    // 进程外 teammate 同款检查(旧缺口:只查 in-process registry,活跃进程外成员时照样 rmrf
    // 掉 team 目录抽走其邮箱)。先非阻塞收尸(已死的清掉),仍存活 → 拒绝。
    if (sw.reapDeadProcessTeammates() > 0) return error.TeammatesStillActive;

    // 拆 registry(abort+join 已终止的尸体)。
    if (sw.teammates) |*t| {
        t.deinit();
        sw.teammates = null;
    }
    // 删 team 目录(best-effort)。
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = team_mod.teamDirPath(sw.home, sw.team_sanitized, &dirbuf);
    rmrf(dir);

    const team_name = sw.team_sanitized;
    defer {
        sw.allocator.free(team_name);
        sw.team_sanitized = &.{};
    }
    return std.fmt.allocPrint(ctx.allocator, "{{\"team\":\"{s}\",\"status\":\"deleted\"}}", .{team_name});
}

// ============================================================================
// SendMessage
// ============================================================================

/// {to:str(必需,name 或 "*"), message:str(必需), summary:str(可选)} → 投消息进收件人邮箱。
/// to="*" 广播给所有成员(除自己)。发送者 = ctx.swarm.self_name。
/// **绝不吞 LockBusy**(投递失败=指令丢失,返回 error 让模型知道)。
pub fn executeSendMessage(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const sw = ctx.swarm orelse return error.SwarmUnavailable;
    if (!sw.hasTeam()) return error.NoActiveTeam;

    const to_raw = util_json.extractStringField(args, "to") orelse return error.MissingRecipient;
    const to = try util_json.unescapeString(to_raw, ctx.allocator);
    defer ctx.allocator.free(to);
    if (to.len == 0) return error.MissingRecipient;
    if (std.mem.indexOfScalar(u8, to, '@') != null) return error.BadRecipient; // name 不含 @

    const msg_raw = util_json.extractStringField(args, "message") orelse return error.MissingMessage;
    const message = try util_json.unescapeString(msg_raw, ctx.allocator);
    defer ctx.allocator.free(message);

    const summary: ?[]const u8 = if (util_json.extractStringField(args, "summary")) |s|
        try util_json.unescapeString(s, ctx.allocator)
    else
        null;
    defer if (summary) |s| ctx.allocator.free(s);

    if (std.mem.eql(u8, to, "*")) {
        const n = try broadcast(ctx, sw, message, summary);
        return std.fmt.allocPrint(ctx.allocator, "{{\"to\":\"*\",\"delivered\":{d}}}", .{n});
    }

    // 单点投递。收件人 = to(或字面 "team-lead")。
    var name_buf: [64]u8 = undefined;
    const to_s = team_mod.sanitizeAgentName(to, &name_buf);
    // 收件人存在性校验:必须是 lead 或在 roster。
    if (!std.mem.eql(u8, to_s, team_mod.TEAM_LEAD_NAME)) {
        var cfgbuf: [std.fs.max_path_bytes]u8 = undefined;
        var tf = team_mod.load(ctx.allocator, sw.configPath(&cfgbuf)) orelse return error.NoActiveTeam;
        defer tf.deinit();
        if (tf.findMember(to_s) == null) return error.UnknownRecipient;
    }
    var inbox_buf: [std.fs.max_path_bytes]u8 = undefined;
    const inbox = team_mod.inboxPath(sw.home, sw.team_sanitized, to_s, &inbox_buf);
    try mailbox.deliver(ctx.allocator, inbox, sw.self_name, message, null, summary);
    return std.fmt.allocPrint(ctx.allocator, "{{\"to\":\"{s}\",\"delivered\":1}}", .{to_s});
}

/// 广播给所有 roster 成员(除自己)+ lead(若发送者非 lead)。返回投递数。
fn broadcast(ctx: *const ToolContext, sw: *const SwarmContext, message: []const u8, summary: ?[]const u8) !usize {
    var cfgbuf: [std.fs.max_path_bytes]u8 = undefined;
    var tf = team_mod.load(ctx.allocator, sw.configPath(&cfgbuf)) orelse return error.NoActiveTeam;
    defer tf.deinit();
    var n: usize = 0;
    for (tf.members.items) |*m| {
        if (std.mem.eql(u8, m.name, sw.self_name)) continue;
        var inbox_buf: [std.fs.max_path_bytes]u8 = undefined;
        const inbox = team_mod.inboxPath(sw.home, sw.team_sanitized, m.name, &inbox_buf);
        mailbox.deliver(ctx.allocator, inbox, sw.self_name, message, null, summary) catch |e| {
            log.warn("swarm", "broadcast to {s} failed: {s}", .{ m.name, @errorName(e) });
            continue;
        };
        n += 1;
    }
    // teammate 广播也抄送 lead(除非发送者就是 lead)。
    if (!std.mem.eql(u8, sw.self_name, team_mod.TEAM_LEAD_NAME)) {
        var inbox_buf: [std.fs.max_path_bytes]u8 = undefined;
        const inbox = team_mod.inboxPath(sw.home, sw.team_sanitized, team_mod.TEAM_LEAD_NAME, &inbox_buf);
        mailbox.deliver(ctx.allocator, inbox, sw.self_name, message, null, summary) catch {};
        n += 1;
    }
    return n;
}

// ============================================================================
// Lead inbox poller(REPL 空闲期调用)
// ============================================================================

/// 拉取 lead 邮箱里的消息,组装成注入对话的文本(owned;空 = 无新消息 → null)。
/// 消费:plain(teammate 回复)+ idle 通知(转可读提示)+ shutdown_approved(SW4:摘牌 +
/// 提示"队友已关闭")。plan/permission 回执留未读(SW4 审批代理消费)。选择性标读只标消费的。
pub fn pollLeadInbox(allocator: std.mem.Allocator, sw: *SwarmContext) !?[]u8 {
    if (!sw.hasTeam()) return null;
    var inbox_buf: [std.fs.max_path_bytes]u8 = undefined;
    const inbox = team_mod.inboxPath(sw.home, sw.team_sanitized, team_mod.TEAM_LEAD_NAME, &inbox_buf);

    var unread = mailbox.readUnread(allocator, inbox) catch return null;
    defer unread.deinit();
    if (unread.items.items.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var consumed: std.ArrayList(mailbox.Message) = .empty;
    defer consumed.deinit(allocator);

    for (unread.items.items) |*m| {
        const kind = mailbox.classify(allocator, m.text);
        switch (kind) {
            .plain => {
                const wire = mailbox.formatForModel(allocator, m) catch continue;
                defer allocator.free(wire);
                if (out.items.len > 0) out.appendSlice(allocator, "\n\n") catch {};
                out.appendSlice(allocator, wire) catch {};
                consumed.append(allocator, m.*) catch {};
            },
            .idle_notification => {
                const line = renderIdleNotice(allocator, m) catch continue;
                defer allocator.free(line);
                if (out.items.len > 0) out.appendSlice(allocator, "\n\n") catch {};
                out.appendSlice(allocator, line) catch {};
                consumed.append(allocator, m.*) catch {};
            },
            .shutdown_approved => {
                // SW4(Linus MED-1 修):**只有当该 teammate 线程确已终止**才摘牌——否则一个仍在
                // 跑的 teammate 用 SendMessage 手发 shutdown_approved 能把自己从 roster 摘掉,变得
                // 不可寻址(SendMessage→UnknownRecipient)又不可关(TeamDelete 见 liveCount>0 拒),
                // 且继续占 KG 任务。策略:线程 terminated/failed(或已不在 registry)→ 摘牌+消费;
                // 仍 working/idle → **留未读**,等线程真退出后的下一次 poll 再处理(自愈竞态窗口)。
                const alive = if (sw.teammates) |*t| blk: {
                    var nb: [64]u8 = undefined;
                    const ns = team_mod.sanitizeAgentName(m.from, &nb);
                    if (t.findByName(ns)) |e| {
                        const s = e.statusSnapshot();
                        break :blk (s == .working or s == .idle);
                    }
                    break :blk false; // 不在 registry = 已收尾,可摘
                } else false;
                if (alive) continue; // 仍在跑:留未读,不摘牌(不加入 consumed)
                var cfgbuf: [std.fs.max_path_bytes]u8 = undefined;
                const cfg = sw.configPath(&cfgbuf);
                removeMemberFromConfig(allocator, cfg, m.from);
                var lb: [256]u8 = undefined;
                const line = std.fmt.bufPrint(&lb, "<teammate-status from=\"{s}\" state=\"shutdown\">teammate has shut down and left the team</teammate-status>", .{m.from}) catch "";
                if (line.len > 0) {
                    if (out.items.len > 0) out.appendSlice(allocator, "\n\n") catch {};
                    out.appendSlice(allocator, line) catch {};
                }
                consumed.append(allocator, m.*) catch {};
            },
            else => {
                // plan/permission 回执 → SW4 审批代理消费,留未读。
            },
        }
    }

    if (consumed.items.len == 0) return null;
    mailbox.markReadAt(allocator, inbox, consumed.items) catch {};
    return out.toOwnedSlice(allocator) catch null;
}

const RmNameCtx = struct { name: []const u8 };
fn rmMemberMutate(c: RmNameCtx, tf: *team_mod.TeamFile) anyerror!void {
    _ = tf.removeMember(c.name);
}
fn removeMemberFromConfig(a: std.mem.Allocator, config_path: []const u8, name_sanitized: []const u8) void {
    if (config_path.len == 0) return;
    var nb: [64]u8 = undefined;
    const ns = team_mod.sanitizeAgentName(name_sanitized, &nb);
    team_mod.updateTeam(a, config_path, RmNameCtx{ .name = ns }, rmMemberMutate) catch {};
}

/// SW3:确保共享 KG inbox root 存在并写好 kg_inbox 指针,让 lead 的 TaskCreate 与 teammate
/// 的 frontier 自领指向同一 root。复用 task_tools 的 inbox root 机制(同一指针名 kg_inbox)。
/// best-effort:KG 未就绪 → 静默跳过(mailbox 派活不受影响)。
fn ensureSharedTaskRoot(ctx: *const ToolContext) void {
    const kg = ctx.kg orelse return;
    if (!kg.ready or ctx.kg_projects_dir.len == 0) return;
    const inject = @import("../kg/inject.zig");
    // 已有有效指针 → 用现成的(lead 之前的 todo 已建 root)。
    if (inject.readIdPointer(ctx.allocator, ctx.kg_projects_dir, "kg_inbox")) |id| {
        if (kg.nodeIsTask(id) catch false) return;
        inject.clearIdPointer(ctx.allocator, ctx.kg_projects_dir, "kg_inbox");
    }
    const root = kg.createTask("团队共享待办(teammates 自领)", "inbox_root") catch return;
    inject.writeIdPointer(ctx.allocator, ctx.kg_projects_dir, "kg_inbox", root) catch {};
    if (kg.ensureTaskAnchorId()) |aid| {
        inject.writeIdPointer(ctx.allocator, ctx.kg_projects_dir, "kg_task_anchor", aid) catch {};
    } else |_| {}
}

/// idle_notification → 可读的 `<teammate-status>` 提示行。
fn renderIdleNotice(allocator: std.mem.Allocator, m: *const mailbox.Message) ![]u8 {
    const reason = util_json.extractStringField(m.text, "idleReason") orelse "available";
    const stop = util_json.extractStringField(m.text, "stopReason");
    const failure = util_json.extractStringField(m.text, "failureReason");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "<teammate-status from=\"");
    try out.appendSlice(allocator, m.from);
    try out.appendSlice(allocator, "\" state=\"");
    try out.appendSlice(allocator, reason);
    try out.appendSlice(allocator, "\"");
    if (stop) |s| {
        try out.appendSlice(allocator, " stopReason=\"");
        try out.appendSlice(allocator, s);
        try out.appendSlice(allocator, "\"");
    }
    try out.appendSlice(allocator, ">");
    if (failure) |f| {
        try out.appendSlice(allocator, f);
    } else if (std.mem.eql(u8, reason, "available")) {
        try out.appendSlice(allocator, "teammate finished its turn and is idle");
    } else if (std.mem.eql(u8, reason, "needs_continuation")) {
        try out.appendSlice(allocator, "teammate paused mid-work (not finished)");
    }
    try out.appendSlice(allocator, "</teammate-status>");
    return out.toOwnedSlice(allocator);
}

fn rmrf(path: []const u8) void {
    // 生产安全递归删(Linus HIGH-1:旧 testing.rmrfBestEffort 仅 /tmp/cc-zig- 生效,
    // TeamDelete 在生产静默 no-op)。护栏=路径须在 /.metacodes/teams/ 下 + symlink 不跟随。
    @import("../util/fs.zig").removeTeamDirTree(path);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const permission_mod = @import("../permission.zig");
const json_mod = @import("../json.zig");

fn mkHome(buf: []u8) ![]const u8 {
    const home = try std.fmt.bufPrint(buf, "/tmp/cc-zig-swtools-{d}", .{util_time.nowNs()});
    try @import("../util/fs.zig").mkdirParents(home);
    return home;
}

fn leadCtx(a: std.mem.Allocator, sw: *SwarmContext) ToolContext {
    return ToolContext{ .allocator = a, .swarm = sw };
}

test "TeamCreate → SendMessage(lead→lead 自投拒 via unknown?) + TeamDelete 全链" {
    const a = testing.allocator;
    var hbuf: [128]u8 = undefined;
    const home = try mkHome(&hbuf);
    defer @import("../util/fs.zig").testing.rmrfBestEffort(home);

    var sw = SwarmContext{ .allocator = a, .home = home, .api_key = "k", .model = "m", .provider_kind = .anthropic };
    defer sw.deinit();
    const ctx = leadCtx(a, &sw);

    // TeamCreate。
    const r1 = try executeTeamCreate(&ctx, "{\"name\":\"My Proj\",\"description\":\"d\"}");
    defer a.free(r1);
    try testing.expect(std.mem.indexOf(u8, r1, "\"team\":\"my-proj\"") != null);
    try testing.expect(sw.hasTeam());
    // config.json 落盘。
    var cfgbuf: [std.fs.max_path_bytes]u8 = undefined;
    var tf0 = team_mod.load(a, sw.configPath(&cfgbuf)) orelse return error.NoConfig;
    tf0.deinit();

    // 二次 TeamCreate → TeamAlreadyExists。
    try testing.expectError(error.TeamAlreadyExists, executeTeamCreate(&ctx, "{\"name\":\"other\"}"));

    // SendMessage 给不存在的 teammate → UnknownRecipient。
    try testing.expectError(error.UnknownRecipient, executeSendMessage(&ctx, "{\"to\":\"ghost\",\"message\":\"hi\",\"summary\":\"x\"}"));

    // SendMessage 给 team-lead(自己邮箱,合法)。
    const r2 = try executeSendMessage(&ctx, "{\"to\":\"team-lead\",\"message\":\"note to self\",\"summary\":\"s\"}");
    defer a.free(r2);
    try testing.expect(std.mem.indexOf(u8, r2, "\"delivered\":1") != null);

    // TeamDelete(无活跃成员)→ deleted。
    const r3 = try executeTeamDelete(&ctx, "{}");
    defer a.free(r3);
    try testing.expect(std.mem.indexOf(u8, r3, "\"status\":\"deleted\"") != null);
    try testing.expect(!sw.hasTeam());
}

test "SendMessage 无 team → NoActiveTeam;非 lead TeamCreate → NotTeamLead" {
    const a = testing.allocator;
    var hbuf: [128]u8 = undefined;
    const home = try mkHome(&hbuf);
    defer @import("../util/fs.zig").testing.rmrfBestEffort(home);

    var sw = SwarmContext{ .allocator = a, .home = home };
    defer sw.deinit();
    const ctx = leadCtx(a, &sw);
    try testing.expectError(error.NoActiveTeam, executeSendMessage(&ctx, "{\"to\":\"x\",\"message\":\"y\"}"));

    var sw2 = SwarmContext{ .allocator = a, .home = home, .is_lead = false, .self_name = "bob" };
    defer sw2.deinit();
    const ctx2 = leadCtx(a, &sw2);
    try testing.expectError(error.NotTeamLead, executeTeamCreate(&ctx2, "{\"name\":\"x\"}"));
}

test "pollLeadInbox: plain + idle_notification 消费,协议回执留未读" {
    const a = testing.allocator;
    var hbuf: [128]u8 = undefined;
    const home = try mkHome(&hbuf);
    defer @import("../util/fs.zig").testing.rmrfBestEffort(home);

    var sw = SwarmContext{ .allocator = a, .home = home, .api_key = "k", .model = "m" };
    defer sw.deinit();
    const ctx = leadCtx(a, &sw);
    const r1 = try executeTeamCreate(&ctx, "{\"name\":\"proj\"}");
    a.free(r1);

    var inbox_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lead_inbox = team_mod.inboxPath(home, "proj", "team-lead", &inbox_buf);
    try mailbox.deliver(a, lead_inbox, "bob", "here is my result", "blue", "result");
    try mailbox.deliver(a, lead_inbox, "bob", "{\"type\":\"idle_notification\",\"from\":\"bob\",\"idleReason\":\"failed\",\"failureReason\":\"boom\"}", null, null);
    // plan_approval_response 归 SW4 审批代理消费,pollLeadInbox 留未读(不吞)。
    try mailbox.deliver(a, lead_inbox, "bob", "{\"type\":\"plan_approval_response\",\"request_id\":\"r1\",\"approve\":true}", null, null);

    const pulled = (try pollLeadInbox(a, &sw)) orelse return error.NothingPulled;
    defer a.free(pulled);
    try testing.expect(std.mem.indexOf(u8, pulled, "here is my result") != null);
    try testing.expect(std.mem.indexOf(u8, pulled, "state=\"failed\"") != null);
    try testing.expect(std.mem.indexOf(u8, pulled, "boom") != null);

    // plan_approval_response 留未读(SW4 审批代理消费,不被 poll 吞掉)。
    var unread = try mailbox.readUnread(a, lead_inbox);
    defer unread.deinit();
    try testing.expectEqual(@as(usize, 1), unread.items.items.len);
    try testing.expect(std.mem.indexOf(u8, unread.items.items[0].text, "plan_approval_response") != null);
}
