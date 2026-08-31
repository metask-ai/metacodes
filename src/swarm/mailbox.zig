//! Teammate 邮箱(对齐 cc utils/teammateMailbox.ts)。
//!
//! 一个邮箱 = 一个 JSON 数组文件 `{teams}/<team>/inboxes/<name>.json`,元素为
//! `{from, text, timestamp, read, color?, summary?}`(camelCase 同 cc,timestamp=ISO 8601 UTC)。
//! 投递 = 追加(写者任意);标记已读 = 只有邮箱主人做。全部读-改-写在 file_lock 下进行,
//! 且**锁内重读最新**再改(cc writeToMailbox 同款:ensure→lock→re-read→mutate→write→release)。
//!
//! 结构化协议:text 若是 JSON 且带 "type" 字段,可能是协议消息(idle/shutdown/审批/任务指派…),
//! 由 classify() 识别;协议消息由轮询方**路由**处理,不直接给模型看。
//! 普通消息给模型的 wire 格式:`<teammate-message teammate_id=... color=... summary=...>`。
//!
//! 偏差登记(vs cc):解析是类型化的,消息里未知字段在重写文件时会被丢弃(cc 用 JS 对象保留)。
//! 我们拥有协议两端,新增字段时同步扩这里的 Message struct 即可。
//!
//! ## 硬约束与已登记债务(SW0 双 review)
//! - **每个邮箱恰好一个消费者**(PM F4):readUnread 与 markReadCount 是两次独立加锁,非原子
//!   RMW——两个消费者会对同一批消息双投递/双路由。SW2 接线时 lead 邮箱只允许一个 poller 读;
//!   若未来必须多消费者,先迁移到 id/offset ack。
//! - **协议处理方必须按 request_id 幂等**(PM F10):邮箱无去重,重投递可能发生;SW4 的
//!   permission/plan 响应处理要拿 payload 里的 request_id 挡重复。
//! - **生产发送绝不吞 LockBusy**(PM F6):deliver 失败=指令丢失,SW2 的 SendMessage 必须把
//!   错误报给模型,不得 `catch {}`。
//! - 消息无独立 id(对齐 cc);SW4 关联靠 payload 内 request_id,够用。

const std = @import("std");
const team_mod = @import("team.zig");
const file_lock = @import("../util/file_lock.zig");
const util_fs = @import("../util/fs.zig");
const util_json = @import("../util/json.zig");
const util_time = @import("../util/time.zig");
const log = @import("../util/log.zig");
const pfs = @import("platform").fs;

/// 邮箱消息(所有字符串 owned by list allocator,见 MessageList.deinit)。
pub const Message = struct {
    from: []const u8,
    text: []const u8,
    timestamp: []const u8, // ISO 8601 UTC,如 2026-07-14T13:27:27.870Z
    read: bool = false,
    color: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    /// 运行时字段(不序列化):该消息在文件数组里的下标。投递只 append、只有主人标读/重写
    /// → 下标在主人视角稳定,可用于 markReadAt 选择性标读(只标真正消费掉的,协议消息留着
    /// 给 SW3/SW4 的消费者;Linus SW1 MED-2)。
    file_index: usize = 0,
};

/// 结构化协议类型(cc teammateMailbox.ts 的消息家族)。plain = 普通对话消息。
pub const MsgKind = enum {
    plain,
    idle_notification,
    permission_request,
    permission_response,
    sandbox_permission_request,
    sandbox_permission_response,
    shutdown_request,
    shutdown_approved,
    shutdown_rejected,
    plan_approval_request,
    plan_approval_response,
    task_assignment,
    team_permission_update,
    mode_set_request,

    /// 协议消息(轮询方路由,不给模型)= 除 plain 外全部。
    pub fn isProtocol(self: MsgKind) bool {
        return self != .plain;
    }
};

/// 从消息 text 识别协议类型。非 JSON / 无**顶层** type / 未知 type → plain。
/// 必须真 parse 只认顶层字段(Linus review MED-3):substring 扫描会把正文里嵌套/夹带
/// `"type":"shutdown_request"` 的普通消息误判成协议消息 → 静默吞消息。协议分类不在热路径,
/// 付得起一次 std.json parse。
pub fn classify(allocator: std.mem.Allocator, text: []const u8) MsgKind {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return .plain;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return .plain;
    defer parsed.deinit();
    const o = switch (parsed.value) {
        .object => |ob| ob,
        else => return .plain,
    };
    const t = strField(o, "type") orelse return .plain;
    return typeFromString(t) orelse .plain;
}

fn typeFromString(t: []const u8) ?MsgKind {
    // 逐一比对(协议类型个位数,无需查表结构;裁剪版 std 里 StaticStringMap 不保证在)。
    inline for (@typeInfo(MsgKind).@"enum".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "plain")) continue;
        if (std.mem.eql(u8, t, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

/// 一次读取的消息集合(拥有内部字符串)。
pub const MessageList = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Message) = .empty,

    pub fn deinit(self: *MessageList) void {
        for (self.items.items) |*m| freeMessage(self.allocator, m);
        self.items.deinit(self.allocator);
    }
};

fn freeMessage(a: std.mem.Allocator, m: *Message) void {
    a.free(m.from);
    a.free(m.text);
    a.free(m.timestamp);
    if (m.color) |c| a.free(c);
    if (m.summary) |s| a.free(s);
}

// ============================================================================
// 文件操作(全部锁内读-改-写)
// ============================================================================

/// 确保邮箱文件存在(父目录 mkdir -p + 不存在则写 "[]")。
pub fn ensureInbox(path: []const u8) !void {
    if (path.len == 0) return error.BadPath;
    if (std.fs.path.dirname(path)) |dir| try util_fs.mkdirParents(dir);
    var pbuf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= pbuf.len) return error.BadPath;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    // EXCL:已存在则失败=OK(不覆盖)。其它 errno(EACCES/ENOENT 等)是真错误,不静默吞
    // (Linus review LOW:权限问题被吞会让邮箱"看似存在实则永远写不进")。
    const fd = pfs.open(@ptrCast(&pbuf), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(c_uint, 0o644));
    if (fd < 0) {
        const e: std.c.E = @enumFromInt(std.c._errno().*);
        if (e == .EXIST) return; // 已存在
        return error.OpenFailed;
    }
    defer pfs.close(fd);
    _ = pfs.write(fd, "[]");
}

/// 投递一条消息(锁内 append)。from/text 必填;color/summary 可选。
/// timestamp 由本函数生成(wall clock ISO 8601)。
/// 邮箱消息条数**软**上限(SW5):超过时 deliver 前裁最旧的**已读**消息(未读优先保留)。
pub const MAILBOX_MAX_MESSAGES: usize = 500;
/// **硬**上限(Linus SW5):软上限只裁已读——若未读堆到硬顶(消费者一直不读),仍会无界增长
/// 且每 deliver 全量重解析/重写=O(n²)。到硬顶则**丢最旧的未读**并 **log.warn**(绝不静默——
/// 丢未读=丢没投递的工作)。硬顶 >> 软顶,正常绝不触及;只兜底 runaway sender/消费者卡死。
pub const MAILBOX_HARD_MAX: usize = 5000;

pub fn deliver(allocator: std.mem.Allocator, path: []const u8, from: []const u8, text: []const u8, color: ?[]const u8, summary: ?[]const u8) !void {
    try ensureInbox(path);
    var lock = try file_lock.acquire(path, .{});
    defer lock.release();

    var list = try readAllUnlocked(allocator, path);
    defer list.deinit();
    // SW5 体积上限:① 软顶——裁最旧已读(未读不丢);② 硬顶——未读堆到硬顶则丢最旧未读+warn。
    pruneReadIfOverCap(allocator, &list, MAILBOX_MAX_MESSAGES);
    dropOldestIfOverHardCap(allocator, &list, MAILBOX_HARD_MAX, path);
    var ts_buf: [40]u8 = undefined;
    const ts = formatIso8601(@divTrunc(util_time.nowWallNs(), 1_000_000), &ts_buf);
    try list.items.append(allocator, .{
        .from = try allocator.dupe(u8, from),
        .text = try allocator.dupe(u8, text),
        .timestamp = try allocator.dupe(u8, ts),
        .read = false,
        .color = if (color) |c| try allocator.dupe(u8, c) else null,
        .summary = if (summary) |s| try allocator.dupe(u8, s) else null,
        .file_index = list.items.items.len,
    });
    try writeAllUnlocked(allocator, path, &list);
}

/// 裁最旧的已读消息直到条数 ≤ cap 或无已读可裁(未读永不丢)。就地修改 list(free 被裁元素)。
fn pruneReadIfOverCap(allocator: std.mem.Allocator, list: *MessageList, cap: usize) void {
    var i: usize = 0;
    while (list.items.items.len > cap and i < list.items.items.len) {
        if (list.items.items[i].read) {
            var m = list.items.items[i];
            freeMessage(allocator, &m);
            _ = list.items.orderedRemove(i); // 保序;i 不前进(后一条补位)
        } else {
            i += 1; // 未读,跳过(不丢)
        }
    }
}

/// 硬顶兜底(Linus SW5):条数 ≥ hard 时丢**最旧的**消息(含未读)直到 < hard,每丢一条 warn。
/// 未读被丢 = 没投递的工作被丢弃,故绝不静默——log.warn 留证据。正常(消费者按时读)绝不触及。
fn dropOldestIfOverHardCap(allocator: std.mem.Allocator, list: *MessageList, hard: usize, path: []const u8) void {
    while (list.items.items.len >= hard) {
        var m = list.items.items[0];
        const was_unread = !m.read;
        freeMessage(allocator, &m);
        _ = list.items.orderedRemove(0);
        if (was_unread) {
            log.warn("swarm", "mailbox {s} hit hard cap ({d}) — DROPPED an UNREAD message (undelivered work lost); a consumer is stuck or a sender is runaway", .{ path, hard });
        }
    }
}

/// 读全部消息(锁内快照)。文件不存在 → 空列表。
pub fn readAll(allocator: std.mem.Allocator, path: []const u8) !MessageList {
    try ensureInbox(path);
    var lock = try file_lock.acquire(path, .{});
    defer lock.release();
    return readAllUnlocked(allocator, path);
}

/// 读未读消息(锁内快照,不改 read 位)。返回列表只含未读,保持文件序。
pub fn readUnread(allocator: std.mem.Allocator, path: []const u8) !MessageList {
    var all = try readAll(allocator, path);
    defer all.deinit();
    var out = MessageList{ .allocator = allocator };
    errdefer out.deinit();
    for (all.items.items) |*m| {
        if (m.read) continue;
        try out.items.append(allocator, .{
            .from = try allocator.dupe(u8, m.from),
            .text = try allocator.dupe(u8, m.text),
            .timestamp = try allocator.dupe(u8, m.timestamp),
            .read = false,
            .color = if (m.color) |c| try allocator.dupe(u8, c) else null,
            .summary = if (m.summary) |s| try allocator.dupe(u8, s) else null,
        });
    }
    return out;
}

/// 选择性标读:只标记 consumed 里列出的消息(按 file_index 定位 + from/timestamp 身份
/// 校验;错位则按身份线性回退)。协议消息等未消费的留在未读,给 SW3/SW4 的消费者
/// (Linus SW1 MED-2 / PM F4:mark-all-read 会把 plan/permission 回执吞掉)。
/// 只有邮箱主人调用;对齐 cc "mark-read 仅在成功投递给模型之后"。
pub fn markReadAt(allocator: std.mem.Allocator, path: []const u8, consumed: []const Message) !void {
    if (consumed.len == 0) return;
    try ensureInbox(path);
    var lock = try file_lock.acquire(path, .{});
    defer lock.release();
    var list = try readAllUnlocked(allocator, path);
    defer list.deinit();
    for (consumed) |*c| {
        // 快路径:序数直取 + 身份校验。
        if (c.file_index < list.items.items.len) {
            const m = &list.items.items[c.file_index];
            if (std.mem.eql(u8, m.from, c.from) and std.mem.eql(u8, m.timestamp, c.timestamp) and std.mem.eql(u8, m.text, c.text)) {
                m.read = true;
                continue;
            }
        }
        // 回退:身份线性搜(文件被并发修复/压缩过的罕见情形)。
        for (list.items.items) |*m| {
            if (m.read) continue;
            if (std.mem.eql(u8, m.from, c.from) and std.mem.eql(u8, m.timestamp, c.timestamp) and std.mem.eql(u8, m.text, c.text)) {
                m.read = true;
                break;
            }
        }
    }
    try writeAllUnlocked(allocator, path, &list);
}

/// 把最早的 n 条未读标记为已读(锁内重读再改;只有邮箱主人调用)。
/// 语义依据:投递只 append、只有主人标读 → 快照的前 n 条未读在重读后仍是前 n 条未读。
/// 对齐 cc "mark-read 仅在成功投递给模型之后"(useInboxPoller.ts:860)。
pub fn markReadCount(allocator: std.mem.Allocator, path: []const u8, n: usize) !void {
    if (n == 0) return;
    try ensureInbox(path);
    var lock = try file_lock.acquire(path, .{});
    defer lock.release();
    var list = try readAllUnlocked(allocator, path);
    defer list.deinit();
    var marked: usize = 0;
    for (list.items.items) |*m| {
        if (marked >= n) break;
        if (!m.read) {
            m.read = true;
            marked += 1;
        }
    }
    try writeAllUnlocked(allocator, path, &list);
}

/// 锁内裸读(调用方必须已持锁)。
fn readAllUnlocked(allocator: std.mem.Allocator, path: []const u8) !MessageList {
    var out = MessageList{ .allocator = allocator };
    errdefer out.deinit();
    const raw = team_mod.readFileAlloc(allocator, path) orelse return out;
    defer allocator.free(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return out;
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return out,
    };
    for (arr.items) |item| {
        const o = switch (item) {
            .object => |ob| ob,
            else => continue,
        };
        const from = strField(o, "from") orelse continue;
        const text = strField(o, "text") orelse continue;
        // 分步 dupe + errdefer,防前字段成功后字段 OOM 时前字段泄漏(Linus SW5 pre-existing)。
        const f_owned = try allocator.dupe(u8, from);
        errdefer allocator.free(f_owned);
        const t_owned = try allocator.dupe(u8, text);
        errdefer allocator.free(t_owned);
        const ts_owned = try allocator.dupe(u8, strField(o, "timestamp") orelse "");
        errdefer allocator.free(ts_owned);
        const c_owned: ?[]const u8 = if (strField(o, "color")) |c| try allocator.dupe(u8, c) else null;
        errdefer if (c_owned) |c| allocator.free(c);
        const s_owned: ?[]const u8 = if (strField(o, "summary")) |s| try allocator.dupe(u8, s) else null;
        try out.items.append(allocator, .{
            .from = f_owned,
            .text = t_owned,
            .timestamp = ts_owned,
            .read = boolField(o, "read") orelse false,
            .color = c_owned,
            .summary = s_owned,
            // 解析序数(非原始数组下标):写侧只落有效消息且保序,故序数在主人视角稳定。
            .file_index = out.items.items.len,
        });
    }
    return out;
}

/// 锁内裸写(原子写整个数组)。
fn writeAllUnlocked(allocator: std.mem.Allocator, path: []const u8, list: *const MessageList) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.append(allocator, '[');
    for (list.items.items, 0..) |*m, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"from\":");
        try util_json.serializeString(m.from, &out, allocator);
        try out.appendSlice(allocator, ",\"text\":");
        try util_json.serializeString(m.text, &out, allocator);
        try out.appendSlice(allocator, ",\"timestamp\":");
        try util_json.serializeString(m.timestamp, &out, allocator);
        try out.appendSlice(allocator, if (m.read) ",\"read\":true" else ",\"read\":false");
        if (m.color) |c| {
            try out.appendSlice(allocator, ",\"color\":");
            try util_json.serializeString(c, &out, allocator);
        }
        if (m.summary) |s| {
            try out.appendSlice(allocator, ",\"summary\":");
            try util_json.serializeString(s, &out, allocator);
        }
        try out.append(allocator, '}');
    }
    try out.append(allocator, ']');
    try team_mod.atomicWrite(path, out.items);
}

// ============================================================================
// wire 格式与时间
// ============================================================================

/// 普通消息注入模型的 XML 信封(cc constants/xml.ts TEAMMATE_MESSAGE_TAG)。owned。
pub fn formatForModel(allocator: std.mem.Allocator, m: *const Message) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "<teammate-message teammate_id=\"");
    try appendXmlEscaped(&out, allocator, m.from);
    try out.appendSlice(allocator, "\"");
    if (m.color) |c| {
        try out.appendSlice(allocator, " color=\"");
        try appendXmlEscaped(&out, allocator, c);
        try out.appendSlice(allocator, "\"");
    }
    if (m.summary) |s| {
        try out.appendSlice(allocator, " summary=\"");
        try appendXmlEscaped(&out, allocator, s);
        try out.appendSlice(allocator, "\"");
    }
    try out.appendSlice(allocator, ">\n");
    try out.appendSlice(allocator, m.text);
    try out.appendSlice(allocator, "\n</teammate-message>");
    return out.toOwnedSlice(allocator);
}

fn appendXmlEscaped(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '<' => try out.appendSlice(a, "&lt;"),
            '>' => try out.appendSlice(a, "&gt;"),
            '&' => try out.appendSlice(a, "&amp;"),
            '"' => try out.appendSlice(a, "&quot;"),
            else => try out.append(a, c),
        }
    }
}

/// unix 毫秒 → ISO 8601 UTC(`2026-07-14T13:27:27.870Z`)。写进 buf(≥25 字节),返回 slice。
/// 输入 clamp 到 [0, 9999-12-31](Linus review LOW:i128 极值会 @intCast panic / 年份超 4 位)。
pub fn formatIso8601(unix_ms: i128, buf: []u8) []const u8 {
    const MAX_MS: i128 = 253_402_300_799_999; // 9999-12-31T23:59:59.999Z
    const clamped: i128 = if (unix_ms > MAX_MS) MAX_MS else unix_ms;
    const ms_nonneg: i128 = if (clamped < 0) 0 else clamped;
    const total_secs: i64 = @intCast(@divFloor(ms_nonneg, 1000));
    const ms: u32 = @intCast(@mod(ms_nonneg, 1000));
    const days = @divFloor(total_secs, 86400);
    const secs_of_day = @mod(total_secs, 86400);
    const ymd = civilFromDays(days);
    const hh: u32 = @intCast(@divFloor(secs_of_day, 3600));
    const mm: u32 = @intCast(@mod(@divFloor(secs_of_day, 60), 60));
    const ss: u32 = @intCast(@mod(secs_of_day, 60));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        @as(u64, @intCast(ymd.year)), ymd.month, ymd.day, hh, mm, ss, ms,
    }) catch "1970-01-01T00:00:00.000Z";
}

const YMD = struct { year: i64, month: u32, day: u32 };
// civil-from-days(Howard Hinnant 算法;cron_registry.zig 同款,swarm 自包含不 import core)。
fn civilFromDays(z_in: i64) YMD {
    var z = z_in + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    z = if (m <= 2) y + 1 else y;
    return .{ .year = z, .month = @intCast(m), .day = @intCast(d) };
}

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

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn testInbox(buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "/tmp/cc-zig-mailbox-test-{d}/inboxes/bob.json", .{util_time.nowNs()});
}

fn rmTestRoot(path: []const u8) void {
    // path = <root>/inboxes/bob.json → 删 <root>
    const inboxes_dir = std.fs.path.dirname(path) orelse return;
    const root = std.fs.path.dirname(inboxes_dir) orelse return;
    util_fs.testing.rmrfBestEffort(root);
}

test "classify: 协议识别 + plain 兜底" {
    const a = testing.allocator;
    try testing.expectEqual(MsgKind.idle_notification, classify(a, "{\"type\":\"idle_notification\",\"from\":\"x\"}"));
    try testing.expectEqual(MsgKind.shutdown_request, classify(a, "  {\"type\":\"shutdown_request\"}"));
    try testing.expectEqual(MsgKind.plan_approval_response, classify(a, "{\"type\":\"plan_approval_response\",\"approve\":true}"));
    try testing.expectEqual(MsgKind.plain, classify(a, "hello world"));
    try testing.expectEqual(MsgKind.plain, classify(a, "{\"type\":\"unknown_thing\"}"));
    try testing.expectEqual(MsgKind.plain, classify(a, "{\"notype\":1}"));
    try testing.expectEqual(MsgKind.plain, classify(a, ""));
    try testing.expect(MsgKind.shutdown_request.isProtocol());
    try testing.expect(!MsgKind.plain.isProtocol());
}

test "classify: 只认顶层 type——嵌套/夹带不误判(Linus MED-3 回归)" {
    const a = testing.allocator;
    // 嵌套 type:普通 JSON 消息,必须是 plain(误判=静默吞消息)。
    try testing.expectEqual(MsgKind.plain, classify(a, "{\"data\":{\"type\":\"shutdown_request\"}}"));
    // 顶层无 type 但字符串值里夹带 "type":"...":同样 plain。
    try testing.expectEqual(MsgKind.plain, classify(a, "{\"note\":\"see {\\\"type\\\":\\\"shutdown_request\\\"}\"}"));
    // 顶层 type + 嵌套 type:按顶层判。
    try testing.expectEqual(MsgKind.task_assignment, classify(a, "{\"type\":\"task_assignment\",\"x\":{\"type\":\"shutdown_request\"}}"));
    // 非 object 顶层(数组):plain。
    try testing.expectEqual(MsgKind.plain, classify(a, "[{\"type\":\"shutdown_request\"}]"));
    // 截断/畸形 JSON:plain。
    try testing.expectEqual(MsgKind.plain, classify(a, "{\"type\":\"shutdown_request\""));
}

test "deliver → readUnread → markReadCount 全链" {
    const a = testing.allocator;
    var pbuf: [256]u8 = undefined;
    const path = try testInbox(&pbuf);
    defer rmTestRoot(path);

    try deliver(a, path, "team-lead", "do task 1", "blue", "assign work");
    try deliver(a, path, "peer", "fyi", null, null);

    var unread = try readUnread(a, path);
    defer unread.deinit();
    try testing.expectEqual(@as(usize, 2), unread.items.items.len);
    try testing.expectEqualStrings("team-lead", unread.items.items[0].from);
    try testing.expectEqualStrings("do task 1", unread.items.items[0].text);
    try testing.expectEqualStrings("blue", unread.items.items[0].color.?);
    try testing.expect(unread.items.items[0].timestamp.len >= 24); // ISO 8601

    // 标记第一条已读。
    try markReadCount(a, path, 1);
    var unread2 = try readUnread(a, path);
    defer unread2.deinit();
    try testing.expectEqual(@as(usize, 1), unread2.items.items.len);
    try testing.expectEqualStrings("peer", unread2.items.items[0].from);

    // 全部已读。
    try markReadCount(a, path, 10);
    var unread3 = try readUnread(a, path);
    defer unread3.deinit();
    try testing.expectEqual(@as(usize, 0), unread3.items.items.len);
    // readAll 仍有 2 条(已读消息不删)。
    var all = try readAll(a, path);
    defer all.deinit();
    try testing.expectEqual(@as(usize, 2), all.items.items.len);
    try testing.expect(all.items.items[0].read);
}

test "pruneReadIfOverCap: 超阈值裁最旧已读,未读永不丢" {
    const a = testing.allocator;
    var list = MessageList{ .allocator = a };
    defer list.deinit();
    // 6 条:0-2 已读,3-5 未读。cap=3 → 应裁掉最旧的已读(0,1,2),保 3 条未读。
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        try list.items.append(a, .{
            .from = try a.dupe(u8, "x"),
            .text = try a.dupe(u8, "m"),
            .timestamp = try a.dupe(u8, "t"),
            .read = i < 3, // 前 3 条已读
        });
    }
    pruneReadIfOverCap(a, &list, 3);
    try testing.expectEqual(@as(usize, 3), list.items.items.len);
    for (list.items.items) |*m| try testing.expect(!m.read); // 剩下的全是未读
}

test "dropOldestIfOverHardCap: 硬顶丢最旧(含未读),降到 <hard" {
    const a = testing.allocator;
    var list = MessageList{ .allocator = a };
    defer list.deinit();
    // 12 条全未读,hard=10 → 丢最旧 3 条降到 9(<10)。
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        try list.items.append(a, .{
            .from = try a.dupe(u8, "x"),
            .text = try std.fmt.allocPrint(a, "m{d}", .{i}),
            .timestamp = try a.dupe(u8, "t"),
            .read = false,
        });
    }
    dropOldestIfOverHardCap(a, &list, 10, "/tmp/test-inbox");
    try testing.expectEqual(@as(usize, 9), list.items.items.len);
    // 剩下的是较新的(m3..m11);最旧 m0 已丢。
    try testing.expectEqualStrings("m3", list.items.items[0].text);
}

test "deliver 邮箱体积上限:未读永不丢" {
    const a = testing.allocator;
    var pbuf: [256]u8 = undefined;
    const path = try testInbox(&pbuf);
    defer rmTestRoot(path);
    // 一次写入边界前状态，再走 5 次真实 deliver 穿过软顶。旧测试用 deliver 从 0
    // 搭到 505；由于生产协议要求每次锁内全量读-改-写，那是在重复测 O(n²) 的 fixture
    // 构造成本，而非新增语义，单测耗时约 22 秒。
    try ensureInbox(path);
    var seeded = MessageList{ .allocator = a };
    defer seeded.deinit();
    var i: usize = 0;
    while (i < MAILBOX_MAX_MESSAGES) : (i += 1) {
        try seeded.items.append(a, .{
            .from = try a.dupe(u8, "x"),
            .text = try a.dupe(u8, "unread"),
            .timestamp = try a.dupe(u8, "2026-08-06T00:00:00.000Z"),
            .read = false,
            .file_index = i,
        });
    }
    try writeAllUnlocked(a, path, &seeded);

    i = 0;
    while (i < 5) : (i += 1) {
        try deliver(a, path, "x", "unread", null, null);
    }
    var all = try readAll(a, path);
    defer all.deinit();
    try testing.expectEqual(@as(usize, MAILBOX_MAX_MESSAGES + 5), all.items.items.len); // 全未读=全留
}

test "markReadAt: 选择性标读(只标消费的,协议消息留未读)" {
    const a = testing.allocator;
    var pbuf: [256]u8 = undefined;
    const path = try testInbox(&pbuf);
    defer rmTestRoot(path);

    try deliver(a, path, "team-lead", "plain work", null, null);
    try deliver(a, path, "team-lead", "{\"type\":\"task_assignment\",\"taskId\":\"1\"}", null, null);
    try deliver(a, path, "peer", "another plain", null, null);

    // 只标读两条 plain(第 0、2),协议消息(第 1)留未读。
    var unread = try readUnread(a, path);
    defer unread.deinit();
    try testing.expectEqual(@as(usize, 3), unread.items.items.len);
    var consumed = [_]Message{ unread.items.items[0], unread.items.items[2] };
    try markReadAt(a, path, &consumed);

    var still = try readUnread(a, path);
    defer still.deinit();
    try testing.expectEqual(@as(usize, 1), still.items.items.len);
    try testing.expect(std.mem.indexOf(u8, still.items.items[0].text, "task_assignment") != null);
}

test "deliver 期间锁存在,释放后无 .lock 残留" {
    const a = testing.allocator;
    var pbuf: [256]u8 = undefined;
    const path = try testInbox(&pbuf);
    defer rmTestRoot(path);
    try deliver(a, path, "x", "y", null, null);
    var lbuf: [300:0]u8 = undefined;
    const lp = try std.fmt.bufPrintZ(&lbuf, "{s}.lock", .{path});
    try testing.expect(!pfs.exists(lp.ptr));
}

test "坏文件内容 → 当空邮箱(不崩),deliver 修复" {
    const a = testing.allocator;
    var pbuf: [256]u8 = undefined;
    const path = try testInbox(&pbuf);
    defer rmTestRoot(path);
    try ensureInbox(path);
    try team_mod.atomicWrite(path, "GARBAGE not json");
    var list = try readAll(a, path);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 0), list.items.items.len);
    try deliver(a, path, "x", "recovered", null, null);
    var list2 = try readAll(a, path);
    defer list2.deinit();
    try testing.expectEqual(@as(usize, 1), list2.items.items.len);
}

test "formatForModel: XML 信封 + 属性转义" {
    const a = testing.allocator;
    var m = Message{
        .from = "bob\"<x>",
        .text = "line1\nline2",
        .timestamp = "2026-07-14T00:00:00.000Z",
        .color = "blue",
        .summary = "a&b",
    };
    const s = try formatForModel(a, &m);
    defer a.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "teammate_id=\"bob&quot;&lt;x&gt;\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "summary=\"a&amp;b\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, ">\nline1\nline2\n</teammate-message>") != null);
}

test "formatIso8601: 已知时刻 + 边界" {
    var buf: [40]u8 = undefined;
    // 2026-07-14T13:27:27.870Z = 1784035647870 ms(由 civil 算法反推验证)
    const s = formatIso8601(1784035647870, &buf);
    try testing.expectEqualStrings("2026-07-14T13:27:27.870Z", s);
    const epoch = formatIso8601(0, &buf);
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z", epoch);
    const neg = formatIso8601(-5, &buf);
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z", neg);
}

test "并发投递不丢消息(两线程 × 10 条)" {
    const a = std.heap.c_allocator; // 线程测试用 c_allocator(GPA 非线程安全)
    var pbuf: [256]u8 = undefined;
    const path = try testInbox(&pbuf);
    defer rmTestRoot(path);

    const Worker = struct {
        fn run(p: []const u8, from: []const u8) void {
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                // 有界重试到成功——绝不吞投递失败(吞了会把锁 bug 显成 count 不齐的 flake)。
                var attempts: u32 = 0;
                while (true) {
                    deliver(std.heap.c_allocator, p, from, "msg", null, null) catch {
                        attempts += 1;
                        if (attempts > 50) @panic("deliver failed 50x under contention");
                        continue;
                    };
                    break;
                }
            }
        }
    };
    const t1 = try std.Thread.spawn(.{}, Worker.run, .{ path, "w1" });
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{ path, "w2" });
    t1.join();
    t2.join();

    var all = try readAll(a, path);
    defer all.deinit();
    try testing.expectEqual(@as(usize, 20), all.items.items.len);
}
