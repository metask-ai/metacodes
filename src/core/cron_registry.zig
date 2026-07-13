//! Cron registry:session 级定时任务存储。
//!
//! 与 Claude Code 一致:**session-scoped,不落盘(durable 默认 false)**。
//! 触发模型:REPL idle 时(每次准备读 prompt 前)检查 due 的 cron,把 prompt 注入。
//!
//! cron 表达式:标准 5 字段 "分 时 日 月 周",本地时间。
//! 也支持 delay_seconds 单次(one-shot)。
//!
//! 注意:cc-zig 当前是单线程 REPL,cron 不在后台线程跑 — 而是在 REPL 主循环
//! "准备读下一条 prompt 前"批量检查。这意味着 cron 只在用户回到 prompt 时触发,
//! 不会打断正在进行的生成。这是有意的简化(避免并发复杂度)。

const std = @import("std");
const rng = @import("../platform/rng.zig");
const util_time = @import("../util/time.zig");

pub const CronJob = struct {
    id: [12]u8, // hex id
    /// cron 5-field 表达式;one-shot 时为空(用 fire_at_unix)
    cron_expr: []const u8, // owned
    /// 要注入的 prompt
    prompt: []const u8, // owned
    /// recurring=false 时单次后删除
    recurring: bool,
    /// 下次触发的 unix 秒(由 cron_expr 或 delay 计算)
    next_fire_unix: i64,
    /// 创建时间(7 天自动过期用)
    created_unix: i64,
};

pub const CronRegistry = struct {
    allocator: std.mem.Allocator,
    jobs: std.ArrayList(CronJob),

    pub fn init(allocator: std.mem.Allocator) CronRegistry {
        return .{ .allocator = allocator, .jobs = .empty };
    }

    pub fn deinit(self: *CronRegistry) void {
        for (self.jobs.items) |j| {
            self.allocator.free(j.cron_expr);
            self.allocator.free(j.prompt);
        }
        self.jobs.deinit(self.allocator);
    }

    /// 创建一个 cron。cron_expr 或 delay_seconds 二选一。返回 job id。
    pub fn create(
        self: *CronRegistry,
        cron_expr: []const u8,
        delay_seconds: ?i64,
        prompt: []const u8,
        recurring: bool,
    ) ![12]u8 {
        const now = util_time.nowUnix();
        var next_fire: i64 = undefined;
        if (delay_seconds) |d| {
            next_fire = now + d;
        } else {
            next_fire = computeNextFire(cron_expr, now) catch return error.InvalidCronExpr;
        }

        const id = try genId();
        const job = CronJob{
            .id = id,
            .cron_expr = try self.allocator.dupe(u8, cron_expr),
            .prompt = try self.allocator.dupe(u8, prompt),
            .recurring = recurring,
            .next_fire_unix = next_fire,
            .created_unix = now,
        };
        try self.jobs.append(self.allocator, job);
        return id;
    }

    /// 删除指定 id。返回是否找到。
    pub fn delete(self: *CronRegistry, id: []const u8) bool {
        for (self.jobs.items, 0..) |j, i| {
            if (std.mem.eql(u8, j.id[0..], id)) {
                self.allocator.free(j.cron_expr);
                self.allocator.free(j.prompt);
                _ = self.jobs.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// 取所有 due(next_fire <= now)的 cron 的 prompt。同时:
    ///   - recurring=true → 重算 next_fire(滚动)
    ///   - recurring=false → 删除(one-shot)
    ///   - 超过 7 天的 recurring → 最后触发一次后删除(对齐 Claude Code)
    /// 返回的 prompts owned slice(caller free 每个 + 数组)。
    pub fn collectDue(self: *CronRegistry, allocator: std.mem.Allocator) ![]const []const u8 {
        const now = util_time.nowUnix();
        var out = std.ArrayList([]const u8).empty;
        errdefer {
            for (out.items) |p| allocator.free(p);
            out.deinit(allocator);
        }

        var i: usize = 0;
        while (i < self.jobs.items.len) {
            var j = &self.jobs.items[i];
            if (j.next_fire_unix > now) {
                i += 1;
                continue;
            }
            // due → 收集 prompt
            try out.append(allocator, try allocator.dupe(u8, j.prompt));

            const expired = (now - j.created_unix) > 7 * 24 * 3600;
            if (!j.recurring or expired) {
                self.allocator.free(j.cron_expr);
                self.allocator.free(j.prompt);
                _ = self.jobs.orderedRemove(i);
                // 不 i+=1,因为 orderedRemove 把后面前移
            } else {
                // 重算下次
                j.next_fire_unix = computeNextFire(j.cron_expr, now + 1) catch (now + 60);
                i += 1;
            }
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn count(self: *const CronRegistry) usize {
        return self.jobs.items.len;
    }

    fn genId() ![12]u8 {
        var raw: [6]u8 = undefined;
        if (!rng.randomBytes(&raw)) return error.RandomFailed;
        var id: [12]u8 = undefined;
        _ = std.fmt.bufPrint(&id, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ raw[0], raw[1], raw[2], raw[3], raw[4], raw[5] }) catch unreachable;
        return id;
    }
};

// ============================================================================
// cron 表达式计算(5 字段,本地时间)
// ============================================================================

/// 计算 from_unix 之后下一个匹配 cron_expr 的 unix 秒。
/// 简化实现:逐分钟扫描,最多扫 366 天(防死循环)。
fn computeNextFire(cron_expr: []const u8, from_unix: i64) !i64 {
    var fields: [5][]const u8 = undefined;
    var it = std.mem.tokenizeAny(u8, cron_expr, " \t");
    var n: usize = 0;
    while (it.next()) |f| {
        if (n >= 5) return error.TooManyFields;
        fields[n] = f;
        n += 1;
    }
    if (n != 5) return error.InvalidCronExpr;

    // 从下一分钟边界开始扫
    var candidate = ((@divFloor(from_unix, 60)) + 1) * 60;
    const limit = candidate + 366 * 24 * 3600;
    while (candidate < limit) : (candidate += 60) {
        const tm = unixToLocal(candidate);
        if (matchField(fields[0], tm.minute) and
            matchField(fields[1], tm.hour) and
            matchField(fields[2], tm.day) and
            matchField(fields[3], tm.month) and
            matchField(fields[4], tm.weekday))
        {
            return candidate;
        }
    }
    return error.NoMatchWithinYear;
}

const LocalTime = struct { minute: u32, hour: u32, day: u32, month: u32, weekday: u32 };

/// unix 秒 → 本地时间分量。简化:用 UTC(cc-zig 不处理 TZ database)。
/// 注:Claude Code 用本地 TZ,cc-zig 简化为 UTC — 文档需注明。
fn unixToLocal(unix: i64) LocalTime {
    const days_since_epoch = @divFloor(unix, 86400);
    const secs_of_day = @mod(unix, 86400);
    const minute: u32 = @intCast(@mod(@divFloor(secs_of_day, 60), 60));
    const hour: u32 = @intCast(@divFloor(secs_of_day, 3600));
    // weekday:1970-01-01 是周四(4)
    const weekday: u32 = @intCast(@mod(days_since_epoch + 4, 7)); // 0=Sun
    // 把 days 转 y/m/d(civil from days 算法)
    const ymd = civilFromDays(days_since_epoch);
    return .{ .minute = minute, .hour = hour, .day = ymd.day, .month = ymd.month, .weekday = weekday };
}

const YMD = struct { year: i64, month: u32, day: u32 };
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

/// 匹配一个 cron 字段。支持:`*` / 具体值 `5` / 列表 `1,2,3` / 范围 `1-5` / 步进 `*/5`。
fn matchField(field: []const u8, value: u32) bool {
    if (std.mem.eql(u8, field, "*")) return true;
    // 步进 */N
    if (std.mem.startsWith(u8, field, "*/")) {
        const step = std.fmt.parseInt(u32, field[2..], 10) catch return false;
        if (step == 0) return false;
        return @mod(value, step) == 0;
    }
    // 逗号列表
    var it = std.mem.tokenizeScalar(u8, field, ',');
    while (it.next()) |part| {
        // 范围 a-b
        if (std.mem.indexOfScalar(u8, part, '-')) |dash| {
            const lo = std.fmt.parseInt(u32, part[0..dash], 10) catch continue;
            const hi = std.fmt.parseInt(u32, part[dash + 1 ..], 10) catch continue;
            if (value >= lo and value <= hi) return true;
        } else {
            const v = std.fmt.parseInt(u32, part, 10) catch continue;
            if (v == value) return true;
        }
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "matchField: wildcard" {
    try testing.expect(matchField("*", 5));
    try testing.expect(matchField("*", 0));
}

test "matchField: exact" {
    try testing.expect(matchField("5", 5));
    try testing.expect(!matchField("5", 6));
}

test "matchField: list" {
    try testing.expect(matchField("1,3,5", 3));
    try testing.expect(!matchField("1,3,5", 4));
}

test "matchField: range" {
    try testing.expect(matchField("1-5", 3));
    try testing.expect(!matchField("1-5", 6));
}

test "matchField: step" {
    try testing.expect(matchField("*/5", 10));
    try testing.expect(matchField("*/5", 0));
    try testing.expect(!matchField("*/5", 7));
}

test "computeNextFire: every minute" {
    // "* * * * *" → 下一分钟边界
    const now: i64 = 1000;
    const next = try computeNextFire("* * * * *", now);
    try testing.expect(next > now);
    try testing.expect(@mod(next, 60) == 0);
}

test "computeNextFire: invalid expr" {
    try testing.expectError(error.InvalidCronExpr, computeNextFire("* * *", 0));
}

test "CronRegistry: create + delete" {
    const a = testing.allocator;
    var reg = CronRegistry.init(a);
    defer reg.deinit();
    const id = try reg.create("* * * * *", null, "do thing", true);
    try testing.expectEqual(@as(usize, 1), reg.count());
    try testing.expect(reg.delete(id[0..]));
    try testing.expectEqual(@as(usize, 0), reg.count());
    try testing.expect(!reg.delete("nonexistent12"));
}

test "CronRegistry: one-shot delay collects + removes" {
    const a = testing.allocator;
    var reg = CronRegistry.init(a);
    defer reg.deinit();
    // delay = -10 → 已经 due
    _ = try reg.create("", -10, "fire now", false);
    const due = try reg.collectDue(a);
    defer {
        for (due) |p| a.free(p);
        a.free(due);
    }
    try testing.expectEqual(@as(usize, 1), due.len);
    try testing.expectEqualStrings("fire now", due[0]);
    // one-shot 后应被删
    try testing.expectEqual(@as(usize, 0), reg.count());
}

test "CronRegistry: future job not collected" {
    const a = testing.allocator;
    var reg = CronRegistry.init(a);
    defer reg.deinit();
    _ = try reg.create("", 3600, "later", false);
    const due = try reg.collectDue(a);
    defer {
        for (due) |p| a.free(p);
        a.free(due);
    }
    try testing.expectEqual(@as(usize, 0), due.len);
    try testing.expectEqual(@as(usize, 1), reg.count()); // 仍在
}
