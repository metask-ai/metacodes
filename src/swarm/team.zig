//! Team 数据模型(对齐 cc utils/swarm/teamHelpers.ts TeamFile schema)。
//!
//! 磁盘布局(根 `{home}/.metacodes/teams/`):
//!   {home}/.metacodes/teams/<sanitizedTeam>/config.json   — TeamFile
//!   {home}/.metacodes/teams/<sanitizedTeam>/inboxes/<sanitizedAgentName>.json — 邮箱(见 mailbox.zig)
//!
//! JSON 字段名保持 cc 的 camelCase(阅读对照方便)。**但写方是有损的**:parse/serialize 只认
//! 本文件建模的字段,load→改→save 会剥掉任何未建模字段——metacodes 的 team 目录**不可**与
//! 真 cc 或更新版二进制共写(PM review F2 登记:我们的 writer 是 authoritative-and-lossy)。
//! 身份:AgentId = `name@team`(确定性,lead 可推算任何 teammate 的 id;重启不变)。
//! lead 铁律:lead 是创建 team 的 session,**不是成员**——members 里没有 lead 条目也不给
//! lead 发 agent-id(cc TeamCreateTool.ts:224 同款;teamContext.leadAgentId 单独存)。
//!
//! 并发:纯数据 + load/save(原子写);**一切读-改-写必须走 updateTeam()**(锁内 RMW,
//! PM review F3——绕开它直接 load+save 会互相覆盖丢更新)。
//!
//! ## 偏差登记(vs cc TeamFile schema,PM review F1)
//! - `subscriptions`(成员订阅列表)——未移植;SW2 消息路由若需要再补。
//! - `teamAllowedPaths`(团队级路径白名单)——未移植;归 SW4 权限协议决定。
//! - `hiddenPaneIds` / `tmuxPaneId`——tmux 窗格 UX,metacodes 无 tmux 集成,不移植
//!   (成员的 backend_type 区分 in-process/process,进程外形态归 SW6)。
//! - Member.prompt(spawn prompt 存档)——未移植;spawn prompt 由 runner 持有。
//!
//! ## 使用约束(PM review F9)
//! - home 为空时路径 helper 返回 ""——**调用方必须先拒绝空 home**,别把 "" 传进 load/save
//!   (load("")=null 与"队不存在"不可分;save("") 会在 CWD 留 .tmp 垃圾)。
//! - sanitize 截断超长名(不报错)——两个超长名可能撞同一目录;工具层(SW2)先限名字长度。

const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const util_fs = @import("../util/fs.zig");
const util_json = @import("../util/json.zig");
const file_lock = @import("../util/file_lock.zig");
const util_time = @import("../util/time.zig");
const log = @import("../util/log.zig");

const is_windows = builtin.os.tag == .windows;
// Windows can keep a target in delete-pending state while MoveFileExW and CRT
// readers contend.  32 attempts × 5 ms = 160 ms per operation: bounded in the
// low hundreds of milliseconds. A genuinely absent path gets only the short
// not-found budget below; its preflight can itself hit delete-pending.
const WINDOWS_FILE_RETRY_LIMIT: usize = 32;
const WINDOWS_FILE_RETRY_SLEEP_MS: u64 = 5;
const WINDOWS_ABSENT_FILE_RETRY_LIMIT: usize = 4;

pub const TEAM_LEAD_NAME = "team-lead";

/// 成员条目(cc TeamFile.members[] 子集;省略字段见文末"偏差登记")。
pub const Member = struct {
    agent_id: []const u8, // name@team
    name: []const u8,
    agent_type: ?[]const u8 = null,
    model: ?[]const u8 = null,
    color: ?[]const u8 = null,
    plan_mode_required: bool = false,
    joined_at_ms: i64 = 0,
    cwd: []const u8 = "",
    worktree_path: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    /// Per-spawn lease for process teammates. Unlike session_id (shared by
    /// the whole lead session), this changes on every spawn and rejects an
    /// old process after a same-name delete/recreate.
    lease_id: ?[]const u8 = null,
    /// "in-process" | "process"(cc 是 in-process|tmux;metacodes 进程外走 headless,SW6)
    backend_type: []const u8 = "in-process",
    /// false=idle;true=active(cc isActive?:undefined 视为 active)
    is_active: bool = true,
    mode: ?[]const u8 = null,
};

pub const TeamFile = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    description: ?[]const u8 = null,
    created_at_ms: i64 = 0,
    lead_agent_id: []const u8,
    lead_session_id: ?[]const u8 = null,
    members: std.ArrayList(Member) = .empty,

    pub fn deinit(self: *TeamFile) void {
        const a = self.allocator;
        a.free(self.name);
        if (self.description) |d| a.free(d);
        a.free(self.lead_agent_id);
        if (self.lead_session_id) |s| a.free(s);
        for (self.members.items) |*m| freeMember(a, m);
        self.members.deinit(a);
    }

    pub fn findMember(self: *const TeamFile, name: []const u8) ?*Member {
        for (self.members.items) |*m| {
            if (std.mem.eql(u8, m.name, name)) return m;
        }
        return null;
    }

    /// 深拷贝新增成员(所有字符串 dupe 到 self.allocator)。
    pub fn addMember(self: *TeamFile, m: Member) !void {
        var owned: Member = undefined;
        try dupeMember(self.allocator, m, &owned);
        errdefer freeMember(self.allocator, &owned);
        try self.members.append(self.allocator, owned);
    }

    /// 按名摘除成员(释放其内存)。返回是否找到。
    pub fn removeMember(self: *TeamFile, name: []const u8) bool {
        for (self.members.items, 0..) |*m, i| {
            if (std.mem.eql(u8, m.name, name)) {
                freeMember(self.allocator, m);
                _ = self.members.orderedRemove(i);
                return true;
            }
        }
        return false;
    }
};

fn dupeMember(a: std.mem.Allocator, src: Member, out: *Member) !void {
    // 全部先 dupe 进带 errdefer 的局部,最后一次性赋值——中途 OOM 不泄漏已 dupe 的字段
    // (Linus review LOW:老写法 out.* 先整体赋值,后续可选字段 dupe 失败会漏 free 前面的)。
    const agent_id = try a.dupe(u8, src.agent_id);
    errdefer a.free(agent_id);
    const name = try a.dupe(u8, src.name);
    errdefer a.free(name);
    const cwd = try a.dupe(u8, src.cwd);
    errdefer a.free(cwd);
    const backend_type = try a.dupe(u8, src.backend_type);
    errdefer a.free(backend_type);
    const agent_type: ?[]const u8 = if (src.agent_type) |v| try a.dupe(u8, v) else null;
    errdefer if (agent_type) |v| a.free(v);
    const model: ?[]const u8 = if (src.model) |v| try a.dupe(u8, v) else null;
    errdefer if (model) |v| a.free(v);
    const color: ?[]const u8 = if (src.color) |v| try a.dupe(u8, v) else null;
    errdefer if (color) |v| a.free(v);
    const worktree_path: ?[]const u8 = if (src.worktree_path) |v| try a.dupe(u8, v) else null;
    errdefer if (worktree_path) |v| a.free(v);
    const session_id: ?[]const u8 = if (src.session_id) |v| try a.dupe(u8, v) else null;
    errdefer if (session_id) |v| a.free(v);
    const lease_id: ?[]const u8 = if (src.lease_id) |v| try a.dupe(u8, v) else null;
    errdefer if (lease_id) |v| a.free(v);
    const mode: ?[]const u8 = if (src.mode) |v| try a.dupe(u8, v) else null;
    out.* = .{
        .agent_id = agent_id,
        .name = name,
        .agent_type = agent_type,
        .model = model,
        .color = color,
        .plan_mode_required = src.plan_mode_required,
        .joined_at_ms = src.joined_at_ms,
        .cwd = cwd,
        .worktree_path = worktree_path,
        .session_id = session_id,
        .lease_id = lease_id,
        .backend_type = backend_type,
        .is_active = src.is_active,
        .mode = mode,
    };
}

fn freeMember(a: std.mem.Allocator, m: *Member) void {
    a.free(m.agent_id);
    a.free(m.name);
    a.free(m.cwd);
    a.free(m.backend_type);
    if (m.agent_type) |v| a.free(v);
    if (m.model) |v| a.free(v);
    if (m.color) |v| a.free(v);
    if (m.worktree_path) |v| a.free(v);
    if (m.session_id) |v| a.free(v);
    if (m.lease_id) |v| a.free(v);
    if (m.mode) |v| a.free(v);
}

// ============================================================================
// 身份与命名
// ============================================================================

/// team 目录名清洗(cc sanitizeName):小写 + 非 [a-z0-9] → '-'。
pub fn sanitizeTeamName(name: []const u8, buf: []u8) []const u8 {
    const n = @min(name.len, buf.len);
    for (name[0..n], 0..) |c, i| {
        buf[i] = switch (c) {
            'a'...'z', '0'...'9' => c,
            'A'...'Z' => c + 32,
            else => '-',
        };
    }
    return buf[0..n];
}

/// agent 名清洗:非 [A-Za-z0-9_-] → '-'(覆盖 cc sanitizeAgentName 的 '@'→'-' 且防路径注入)。
pub fn sanitizeAgentName(name: []const u8, buf: []u8) []const u8 {
    const n = @min(name.len, buf.len);
    for (name[0..n], 0..) |c, i| {
        buf[i] = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => c,
            else => '-',
        };
    }
    return buf[0..n];
}

/// AgentId = `name@team`。
pub fn formatAgentId(name: []const u8, team: []const u8, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}@{s}", .{ name, team }) catch null;
}

pub const ParsedAgentId = struct { name: []const u8, team: []const u8 };

/// 按第一个 '@' 切分(name 清洗后不含 '@')。无 '@' → null。
pub fn parseAgentId(id: []const u8) ?ParsedAgentId {
    const at = std.mem.indexOfScalar(u8, id, '@') orelse return null;
    if (at == 0 or at + 1 >= id.len) return null;
    return .{ .name = id[0..at], .team = id[at + 1 ..] };
}

// ============================================================================
// 路径
// ============================================================================

pub fn teamsDir(home: []const u8, buf: []u8) []const u8 {
    if (home.len == 0) return "";
    return std.fmt.bufPrint(buf, "{s}/.metacodes/teams", .{home}) catch "";
}

pub fn teamDirPath(home: []const u8, team_sanitized: []const u8, buf: []u8) []const u8 {
    if (home.len == 0 or team_sanitized.len == 0) return "";
    return std.fmt.bufPrint(buf, "{s}/.metacodes/teams/{s}", .{ home, team_sanitized }) catch "";
}

pub fn configPath(home: []const u8, team_sanitized: []const u8, buf: []u8) []const u8 {
    if (home.len == 0 or team_sanitized.len == 0) return "";
    return std.fmt.bufPrint(buf, "{s}/.metacodes/teams/{s}/config.json", .{ home, team_sanitized }) catch "";
}

pub fn inboxesDirPath(home: []const u8, team_sanitized: []const u8, buf: []u8) []const u8 {
    if (home.len == 0 or team_sanitized.len == 0) return "";
    return std.fmt.bufPrint(buf, "{s}/.metacodes/teams/{s}/inboxes", .{ home, team_sanitized }) catch "";
}

pub fn inboxPath(home: []const u8, team_sanitized: []const u8, agent_name_sanitized: []const u8, buf: []u8) []const u8 {
    if (home.len == 0 or team_sanitized.len == 0 or agent_name_sanitized.len == 0) return "";
    return std.fmt.bufPrint(buf, "{s}/.metacodes/teams/{s}/inboxes/{s}.json", .{ home, team_sanitized, agent_name_sanitized }) catch "";
}

// ============================================================================
// load / save
// ============================================================================

/// 读并解析 config.json。文件不存在/解析失败 → null(调用方决定是否致命)。
/// 返回的 TeamFile 拥有全部字符串(deinit 释放)。
pub fn load(allocator: std.mem.Allocator, path: []const u8) ?TeamFile {
    const raw = readFileAlloc(allocator, path) orelse return null;
    defer allocator.free(raw);
    return parse(allocator, raw);
}

/// 解析 TeamFile JSON(独立出来可测)。
pub fn parse(allocator: std.mem.Allocator, raw: []const u8) ?TeamFile {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const name_v = strField(root, "name") orelse return null;
    const lead_v = strField(root, "leadAgentId") orelse return null;

    var tf = TeamFile{
        .allocator = allocator,
        .name = allocator.dupe(u8, name_v) catch return null,
        .lead_agent_id = "",
    };
    var ok = false;
    defer if (!ok) tf.deinit();
    tf.lead_agent_id = allocator.dupe(u8, lead_v) catch return null;
    if (strField(root, "description")) |v| tf.description = allocator.dupe(u8, v) catch return null;
    if (strField(root, "leadSessionId")) |v| tf.lead_session_id = allocator.dupe(u8, v) catch return null;
    tf.created_at_ms = intField(root, "createdAt") orelse 0;

    if (root.get("members")) |mv| switch (mv) {
        .array => |arr| {
            for (arr.items) |item| {
                const mo = switch (item) {
                    .object => |o| o,
                    else => continue,
                };
                const m = Member{
                    .agent_id = strField(mo, "agentId") orelse continue,
                    .name = strField(mo, "name") orelse continue,
                    .agent_type = strField(mo, "agentType"),
                    .model = strField(mo, "model"),
                    .color = strField(mo, "color"),
                    .plan_mode_required = boolField(mo, "planModeRequired") orelse false,
                    .joined_at_ms = intField(mo, "joinedAt") orelse 0,
                    .cwd = strField(mo, "cwd") orelse "",
                    .worktree_path = strField(mo, "worktreePath"),
                    .session_id = strField(mo, "sessionId"),
                    .lease_id = strField(mo, "leaseId"),
                    .backend_type = strField(mo, "backendType") orelse "in-process",
                    .is_active = boolField(mo, "isActive") orelse true,
                    .mode = strField(mo, "mode"),
                };
                // Name is the routing key. Duplicate entries make
                // findMember()/active updates depend on array order and can
                // route a stale session to the wrong process.
                if (tf.findMember(m.name) != null) return null;
                tf.addMember(m) catch return null;
            }
        },
        else => {},
    };
    ok = true;
    return tf;
}

/// 序列化(camelCase,字段序稳定)。owned,caller free。
pub fn serialize(allocator: std.mem.Allocator, tf: *const TeamFile) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"name\":");
    try util_json.serializeString(tf.name, &out, allocator);
    if (tf.description) |d| {
        try out.appendSlice(allocator, ",\"description\":");
        try util_json.serializeString(d, &out, allocator);
    }
    try appendFmt(&out, allocator, ",\"createdAt\":{d}", .{tf.created_at_ms});
    try out.appendSlice(allocator, ",\"leadAgentId\":");
    try util_json.serializeString(tf.lead_agent_id, &out, allocator);
    if (tf.lead_session_id) |s| {
        try out.appendSlice(allocator, ",\"leadSessionId\":");
        try util_json.serializeString(s, &out, allocator);
    }
    try out.appendSlice(allocator, ",\"members\":[");
    for (tf.members.items, 0..) |*m, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"agentId\":");
        try util_json.serializeString(m.agent_id, &out, allocator);
        try out.appendSlice(allocator, ",\"name\":");
        try util_json.serializeString(m.name, &out, allocator);
        if (m.agent_type) |v| {
            try out.appendSlice(allocator, ",\"agentType\":");
            try util_json.serializeString(v, &out, allocator);
        }
        if (m.model) |v| {
            try out.appendSlice(allocator, ",\"model\":");
            try util_json.serializeString(v, &out, allocator);
        }
        if (m.color) |v| {
            try out.appendSlice(allocator, ",\"color\":");
            try util_json.serializeString(v, &out, allocator);
        }
        try appendFmt(&out, allocator, ",\"planModeRequired\":{},\"joinedAt\":{d}", .{ m.plan_mode_required, m.joined_at_ms });
        try out.appendSlice(allocator, ",\"cwd\":");
        try util_json.serializeString(m.cwd, &out, allocator);
        if (m.worktree_path) |v| {
            try out.appendSlice(allocator, ",\"worktreePath\":");
            try util_json.serializeString(v, &out, allocator);
        }
        if (m.session_id) |v| {
            try out.appendSlice(allocator, ",\"sessionId\":");
            try util_json.serializeString(v, &out, allocator);
        }
        if (m.lease_id) |v| {
            try out.appendSlice(allocator, ",\"leaseId\":");
            try util_json.serializeString(v, &out, allocator);
        }
        try out.appendSlice(allocator, ",\"backendType\":");
        try util_json.serializeString(m.backend_type, &out, allocator);
        try appendFmt(&out, allocator, ",\"isActive\":{}", .{m.is_active});
        if (m.mode) |v| {
            try out.appendSlice(allocator, ",\"mode\":");
            try util_json.serializeString(v, &out, allocator);
        }
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

/// 原子写 config.json(tmp + close + renameReplace;rename 前必 close)。
pub fn save(allocator: std.mem.Allocator, tf: *const TeamFile, path: []const u8) !void {
    const body = try serialize(allocator, tf);
    defer allocator.free(body);
    try atomicWrite(path, body);
}

/// 锁内读-改-写 config.json(PM review F3:**所有** team 变更的唯一入口)。
/// 语义:file_lock(config.json) → load 最新 → mutate(fn) → save(原子写) → release。
/// config 不存在 → error.TeamNotFound(mutate 不执行)。mutate 返回错误则不落盘。
pub fn updateTeam(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    ctx: anytype,
    mutate: fn (@TypeOf(ctx), *TeamFile) anyerror!void,
) !void {
    if (config_path.len == 0) return error.BadPath;
    // fast-path:config 不存在直接 TeamNotFound(也避免对不存在目录空耗锁重试)。
    {
        var pbuf: [std.fs.max_path_bytes:0]u8 = undefined;
        if (config_path.len >= pbuf.len) return error.BadPath;
        @memcpy(pbuf[0..config_path.len], config_path);
        pbuf[config_path.len] = 0;
        if (!pfs.exists(@ptrCast(&pbuf))) return error.TeamNotFound;
    }
    var lock = file_lock.acquire(config_path, .{}) catch |e| switch (e) {
        error.NoParentDir => return error.TeamNotFound, // 目录整个没了(TeamDelete 竞态)
        else => return e,
    };
    defer lock.release();
    var tf = load(allocator, config_path) orelse return error.TeamNotFound;
    defer tf.deinit();
    try mutate(ctx, &tf);
    try save(allocator, &tf, config_path);
}

/// 原子写任意小文件(swarm 共用:config/inbox)。
pub fn atomicWrite(path: []const u8, body: []const u8) !void {
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}.tmp", .{path}) catch return error.PathTooLong;
    const fd = pfs.open(tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
    if (fd < 0) return error.OpenFailed;
    var written: usize = 0;
    while (written < body.len) {
        const n = pfs.write(fd, body[written..]);
        if (n <= 0) {
            pfs.close(fd);
            _ = std.c.unlink(tmp.ptr);
            return error.WriteFailed;
        }
        written += @intCast(n);
    }
    pfs.close(fd); // rename 前必 close(Windows 语义 + 01348ba 血泪)
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    var rename_ok = false;
    if (is_windows) {
        var retries: usize = 0;
        var retried = false;
        while (true) {
            if (pfs.renameReplace(tmp.ptr, @ptrCast(&path_buf)) == 0) {
                rename_ok = true;
                break;
            }
            if (retries >= WINDOWS_FILE_RETRY_LIMIT or
                !pfs.isWindowsTransientFileError(false)) break;
            retries += 1;
            retried = true;
            util_time.sleepMs(WINDOWS_FILE_RETRY_SLEEP_MS);
        }
        if (retried) {
            log.warn("swarm", "atomicWrite retried Windows replace for {s} ({d} attempts)", .{ path, retries });
        }
    } else {
        rename_ok = pfs.renameReplace(tmp.ptr, @ptrCast(&path_buf)) == 0;
    }
    if (!rename_ok) {
        _ = std.c.unlink(tmp.ptr);
        return error.RenameFailed;
    }
}

/// 读整个文件(owned)。不存在 → null。
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    var pbuf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= pbuf.len) return null;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    var was_present = false;
    if (is_windows) {
        // Sample before _open: during MoveFileExW's delete-pending window both
        // lookups can miss. Even a negative sample therefore gets four short
        // retries (20 ms total); a known-present file gets the full 160 ms.
        was_present = pfs.exists(@ptrCast(&pbuf));
    }
    var fd = pfs.open(@ptrCast(&pbuf), .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (is_windows and fd < 0) {
        var retryable = pfs.isWindowsTransientFileError(true);
        var retries: usize = 0;
        var retried = false;
        const retry_limit = if (was_present) WINDOWS_FILE_RETRY_LIMIT else WINDOWS_ABSENT_FILE_RETRY_LIMIT;
        while (retries < retry_limit and retryable) {
            retries += 1;
            retried = true;
            util_time.sleepMs(WINDOWS_FILE_RETRY_SLEEP_MS);
            fd = pfs.open(@ptrCast(&pbuf), .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
            if (fd >= 0) break;
            retryable = pfs.isWindowsTransientFileError(true);
        }
        if (retried) {
            log.warn("swarm", "readFileAlloc retried Windows open for {s} ({d} attempts)", .{ path, retries });
        }
    }
    if (fd < 0) return null;
    defer pfs.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var rb: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &rb);
        if (n < 0) {
            out.deinit(allocator);
            return null;
        }
        if (n == 0) break;
        out.appendSlice(allocator, rb[0..@intCast(n)]) catch {
            out.deinit(allocator);
            return null;
        };
    }
    return out.toOwnedSlice(allocator) catch null;
}

// ---- JSON Value 取字段小工具 ----

fn strField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn boolField(o: std.json.ObjectMap, key: []const u8) ?bool {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn intField(o: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        // 损坏文件里的 1e300/NaN 直接 @intFromFloat 会 panic(Linus review LOW)→ 范围外返 null。
        .float => |f| if (std.math.isNan(f) or f < -9.2e18 or f > 9.2e18) null else @intFromFloat(f),
        else => null,
    };
}

fn appendFmt(out: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return error.OutOfMemory;
    try out.appendSlice(a, s);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "sanitize: team 小写化,agent 保大小写,@ 均被清洗" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("my-project", sanitizeTeamName("My Project", &buf));
    try testing.expectEqualStrings("a-b", sanitizeTeamName("a@b", &buf));
    try testing.expectEqualStrings("Res_earcher-1", sanitizeAgentName("Res_earcher@1", &buf));
    try testing.expectEqualStrings("a--b", sanitizeAgentName("a/.b", &buf));
}

test "agentId format/parse 往返 + 畸形拒绝" {
    var buf: [64]u8 = undefined;
    const id = formatAgentId("researcher", "proj", &buf).?;
    try testing.expectEqualStrings("researcher@proj", id);
    const p = parseAgentId(id).?;
    try testing.expectEqualStrings("researcher", p.name);
    try testing.expectEqualStrings("proj", p.team);
    try testing.expect(parseAgentId("noat") == null);
    try testing.expect(parseAgentId("@team") == null);
    try testing.expect(parseAgentId("name@") == null);
}

test "路径拼装 + 空 home 降级" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("/h/.metacodes/teams/t/config.json", configPath("/h", "t", &buf));
    try testing.expectEqualStrings("/h/.metacodes/teams/t/inboxes/bob.json", inboxPath("/h", "t", "bob", &buf));
    try testing.expectEqualStrings("", configPath("", "t", &buf));
    try testing.expectEqualStrings("", inboxPath("/h", "", "bob", &buf));
}

test "TeamFile serialize→parse 往返(全字段)" {
    const a = testing.allocator;
    var tf = TeamFile{
        .allocator = a,
        .name = try a.dupe(u8, "proj"),
        .description = try a.dupe(u8, "desc"),
        .created_at_ms = 1234,
        .lead_agent_id = try a.dupe(u8, "team-lead@proj"),
        .lead_session_id = try a.dupe(u8, "abc123"),
    };
    defer tf.deinit();
    try tf.addMember(.{
        .agent_id = "bob@proj",
        .name = "bob",
        .agent_type = "researcher",
        .model = "claude-x",
        .color = "blue",
        .plan_mode_required = true,
        .joined_at_ms = 99,
        .cwd = "/tmp/x",
        .worktree_path = "/tmp/wt",
        .session_id = "s1",
        .lease_id = "lease1",
        .backend_type = "in-process",
        .is_active = false,
        .mode = "acceptEdits",
    });
    const body = try serialize(a, &tf);
    defer a.free(body);

    var back = parse(a, body) orelse return error.ParseFailed;
    defer back.deinit();
    try testing.expectEqualStrings("proj", back.name);
    try testing.expectEqualStrings("desc", back.description.?);
    try testing.expectEqual(@as(i64, 1234), back.created_at_ms);
    try testing.expectEqualStrings("team-lead@proj", back.lead_agent_id);
    try testing.expectEqualStrings("abc123", back.lead_session_id.?);
    try testing.expectEqual(@as(usize, 1), back.members.items.len);
    const m = &back.members.items[0];
    try testing.expectEqualStrings("bob@proj", m.agent_id);
    try testing.expectEqualStrings("s1", m.session_id.?);
    try testing.expectEqualStrings("lease1", m.lease_id.?);
    try testing.expectEqualStrings("researcher", m.agent_type.?);
    try testing.expect(m.plan_mode_required);
    try testing.expect(!m.is_active);
    try testing.expectEqualStrings("acceptEdits", m.mode.?);
}

test "parse: 缺必填字段/畸形 JSON → null" {
    const a = testing.allocator;
    try testing.expect(parse(a, "not json") == null);
    try testing.expect(parse(a, "{\"name\":\"x\"}") == null); // 缺 leadAgentId
    try testing.expect(parse(a, "[]") == null);
}

test "parse: duplicate member names are rejected" {
    const raw = "{\"name\":\"p\",\"leadAgentId\":\"team-lead@p\",\"members\":[{\"agentId\":\"a@p\",\"name\":\"a\"},{\"agentId\":\"b@p\",\"name\":\"a\"}]}";
    try testing.expect(parse(testing.allocator, raw) == null);
}

test "addMember/findMember/removeMember" {
    const a = testing.allocator;
    var tf = TeamFile{
        .allocator = a,
        .name = try a.dupe(u8, "t"),
        .lead_agent_id = try a.dupe(u8, "team-lead@t"),
    };
    defer tf.deinit();
    try tf.addMember(.{ .agent_id = "x@t", .name = "x", .cwd = "/" });
    try tf.addMember(.{ .agent_id = "y@t", .name = "y", .cwd = "/" });
    try testing.expect(tf.findMember("x") != null);
    tf.findMember("x").?.is_active = false;
    try testing.expect(!tf.findMember("x").?.is_active);
    try testing.expect(tf.removeMember("x"));
    try testing.expect(!tf.removeMember("x"));
    try testing.expect(tf.findMember("x") == null);
    try testing.expectEqual(@as(usize, 1), tf.members.items.len);
}

test "save/load 磁盘往返(原子写)" {
    const a = testing.allocator;
    var dbuf: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&dbuf, "/tmp/cc-zig-team-test-{d}", .{util_time.nowNs()});
    defer util_fs.testing.rmrfBestEffort(home);
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    try util_fs.mkdirParents(teamDirPath(home, "proj", &dirbuf));
    const path = configPath(home, "proj", &pbuf);

    var tf = TeamFile{
        .allocator = a,
        .name = try a.dupe(u8, "proj"),
        .lead_agent_id = try a.dupe(u8, "team-lead@proj"),
        .created_at_ms = 7,
    };
    defer tf.deinit();
    try tf.addMember(.{ .agent_id = "bob@proj", .name = "bob", .cwd = "/w" });
    try save(a, &tf, path);

    var back = load(a, path) orelse return error.LoadFailed;
    defer back.deinit();
    try testing.expectEqualStrings("proj", back.name);
    try testing.expectEqual(@as(usize, 1), back.members.items.len);
    // tmp 文件不残留
    var tbuf: [std.fs.max_path_bytes:0]u8 = undefined;
    const tmp = try std.fmt.bufPrintZ(&tbuf, "{s}.tmp", .{path});
    try testing.expect(!pfs.exists(tmp.ptr));
}

test "load: 不存在 → null" {
    try testing.expect(load(testing.allocator, "/nonexistent/team/config.json") == null);
}

test "updateTeam: 锁内 RMW 生效 + 不存在报 TeamNotFound + mutate 出错不落盘" {
    const a = testing.allocator;
    var dbuf: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&dbuf, "/tmp/cc-zig-team-upd-{d}", .{util_time.nowNs()});
    defer util_fs.testing.rmrfBestEffort(home);
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    try util_fs.mkdirParents(teamDirPath(home, "proj", &dirbuf));
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = configPath(home, "proj", &pbuf);

    // 不存在 → TeamNotFound。
    const Noop = struct {
        fn mutate(_: void, _: *TeamFile) anyerror!void {}
    };
    try testing.expectError(error.TeamNotFound, updateTeam(a, path, {}, Noop.mutate));

    // 建初始 config。
    var tf = TeamFile{ .allocator = a, .name = try a.dupe(u8, "proj"), .lead_agent_id = try a.dupe(u8, "team-lead@proj") };
    defer tf.deinit();
    try save(a, &tf, path);

    // RMW:加成员。
    const AddBob = struct {
        fn mutate(_: void, t: *TeamFile) anyerror!void {
            try t.addMember(.{ .agent_id = "bob@proj", .name = "bob", .cwd = "/w" });
        }
    };
    try updateTeam(a, path, {}, AddBob.mutate);
    var back = load(a, path) orelse return error.LoadFailed;
    defer back.deinit();
    try testing.expectEqual(@as(usize, 1), back.members.items.len);

    // mutate 报错 → 不落盘(成员数不变)。
    const Fail = struct {
        fn mutate(_: void, t: *TeamFile) anyerror!void {
            try t.addMember(.{ .agent_id = "x@proj", .name = "x", .cwd = "/" });
            return error.Boom;
        }
    };
    try testing.expectError(error.Boom, updateTeam(a, path, {}, Fail.mutate));
    var back2 = load(a, path) orelse return error.LoadFailed;
    defer back2.deinit();
    try testing.expectEqual(@as(usize, 1), back2.members.items.len);
}
