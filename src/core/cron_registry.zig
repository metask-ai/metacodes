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
const rng = @import("platform").rng;
const util_time = @import("../util/time.zig");

/// A job's id: 12 lowercase hex digits, as `create` makes them. A Host
/// names a job by it (`SessionHost.Command.cancel_cron_job`, #493); `parse`
/// takes only that form, so a malformed id never reaches the registry.
pub const JobId = struct {
    bytes: [12]u8,

    pub fn parse(text: []const u8) error{InvalidCronJobId}!JobId {
        if (text.len != 12) return error.InvalidCronJobId;
        var id: JobId = .{ .bytes = undefined };
        for (text, &id.bytes) |c, *slot| {
            switch (c) {
                '0'...'9', 'a'...'f' => slot.* = c,
                else => return error.InvalidCronJobId,
            }
        }
        return id;
    }

    pub fn slice(self: *const JobId) []const u8 {
        return self.bytes[0..];
    }

    pub fn eql(a: JobId, b: JobId) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

/// How a job fires (#493): once and then it is gone, or again on its cron
/// expression after each fire (a recurring job always has one: `create`
/// refuses one it cannot repeat).
pub const Schedule = union(enum) {
    once,
    /// The job's 5-field cron expression.
    recurring: []const u8,
};

/// A job as a Host sees it (`CronRegistry.list`): its id, when it fires
/// next (unix seconds), and whether it repeats. Its prompt stays with the
/// model.
pub const JobView = struct {
    id: JobId,
    next_fire_unix: i64,
    schedule: Schedule,

    pub fn dupe(self: JobView, allocator: std.mem.Allocator) error{OutOfMemory}!JobView {
        var copy = self;
        switch (self.schedule) {
            .once => {},
            .recurring => |expr| copy.schedule = .{ .recurring = try allocator.dupe(u8, expr) },
        }
        return copy;
    }

    pub fn deinit(self: JobView, allocator: std.mem.Allocator) void {
        switch (self.schedule) {
            .once => {},
            .recurring => |expr| allocator.free(expr),
        }
    }
};

/// Frees `views` (`CronRegistry.list`) and each view's expression.
pub fn freeViews(allocator: std.mem.Allocator, views: []const JobView) void {
    for (views) |view| view.deinit(allocator);
    allocator.free(views);
}

/// `views`, each owned by `allocator` (`freeViews`).
pub fn dupeViews(allocator: std.mem.Allocator, views: []const JobView) error{OutOfMemory}![]JobView {
    const copy = try allocator.alloc(JobView, views.len);
    var filled: usize = 0;
    errdefer {
        for (copy[0..filled]) |view| view.deinit(allocator);
        allocator.free(copy);
    }
    for (views, copy) |view, *slot| {
        slot.* = try view.dupe(allocator);
        filled += 1;
    }
    return copy;
}

pub const CronJob = struct {
    id: JobId,
    /// cron 5-field 表达式;one-shot 时为空(用 fire_at_unix)
    cron_expr: []const u8, // owned
    /// 要注入的 prompt
    prompt: []const u8, // owned
    /// recurring=false 时单次后删除。A recurring job has an expression to
    /// repeat on (`create` refuses one without).
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
    /// A recurring job repeats on its expression, also after a first fire
    /// that delay_seconds set, so it needs one that matches within the
    /// scan's year: otherwise error.InvalidCronExpr, and nothing is stored.
    pub fn create(
        self: *CronRegistry,
        cron_expr: []const u8,
        delay_seconds: ?i64,
        prompt: []const u8,
        recurring: bool,
    ) !JobId {
        const now = util_time.nowUnix();
        const by_expr: ?i64 = if (recurring or delay_seconds == null)
            computeNextFire(cron_expr, now) catch return error.InvalidCronExpr
        else
            null;
        const next_fire = if (delay_seconds) |d| now + d else by_expr.?;

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

    /// 删除指定 id(as the model wrote it)。返回是否找到。
    pub fn delete(self: *CronRegistry, id: []const u8) bool {
        return self.remove(JobId.parse(id) catch return false);
    }

    /// Removes job `id`; whether it was there.
    pub fn remove(self: *CronRegistry, id: JobId) bool {
        for (self.jobs.items, 0..) |j, i| {
            if (j.id.eql(id)) {
                self.freeJob(j);
                _ = self.jobs.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Removes every job; how many there were.
    pub fn clear(self: *CronRegistry) usize {
        const removed = self.jobs.items.len;
        for (self.jobs.items) |j| self.freeJob(j);
        self.jobs.clearRetainingCapacity();
        return removed;
    }

    fn freeJob(self: *CronRegistry, j: CronJob) void {
        self.allocator.free(j.cron_expr);
        self.allocator.free(j.prompt);
    }

    /// 取所有 due(next_fire <= now)的 cron 的 prompt。同时:
    ///   - recurring=true → 重算 next_fire(滚动)
    ///   - recurring=false → 删除(one-shot)
    ///   - 超过 7 天的 recurring → 最后触发一次后删除(对齐 Claude Code)
    ///   - a recurring job whose next fire cannot be computed (no expression,
    ///     or no match within the scan's year) → removed after this fire, not
    ///     rescheduled
    /// At most `limit` prompts, oldest job first (#493): a due job past the
    /// limit is left as it is, still due, and fires on a later call.
    /// 返回的 prompts owned slice(caller free 每个 + 数组)。
    pub fn collectDue(self: *CronRegistry, allocator: std.mem.Allocator, limit: usize) ![]const []const u8 {
        const now = util_time.nowUnix();
        var out = std.ArrayList([]const u8).empty;
        errdefer {
            for (out.items) |p| allocator.free(p);
            out.deinit(allocator);
        }

        var i: usize = 0;
        while (i < self.jobs.items.len and out.items.len < limit) {
            var j = &self.jobs.items[i];
            if (j.next_fire_unix > now) {
                i += 1;
                continue;
            }
            // due → 收集 prompt
            try out.append(allocator, try allocator.dupe(u8, j.prompt));

            const expired = (now - j.created_unix) > 7 * 24 * 3600;
            // A recurring job with no next fire goes too: rescheduled a
            // minute on instead, it fired every minute until it expired.
            const next: ?i64 = if (j.recurring and !expired)
                computeNextFire(j.cron_expr, now + 1) catch null
            else
                null;
            if (next) |n| {
                j.next_fire_unix = n;
                i += 1;
            } else {
                self.freeJob(j.*);
                _ = self.jobs.orderedRemove(i);
                // 不 i+=1,因为 orderedRemove 把后面前移
            }
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn count(self: *const CronRegistry) usize {
        return self.jobs.items.len;
    }

    /// How many jobs `collectDue` would take now without a limit. A job
    /// counted stays due until it is taken or removed.
    pub fn dueCount(self: *const CronRegistry) usize {
        const now = util_time.nowUnix();
        var due: usize = 0;
        for (self.jobs.items) |j| {
            if (j.next_fire_unix <= now) due += 1;
        }
        return due;
    }

    /// What a Host sees of each job, in the order they were created (#493),
    /// owned by `allocator` (`freeViews`).
    pub fn list(self: *const CronRegistry, allocator: std.mem.Allocator) error{OutOfMemory}![]JobView {
        const views = try allocator.alloc(JobView, self.jobs.items.len);
        var filled: usize = 0;
        errdefer {
            for (views[0..filled]) |view| view.deinit(allocator);
            allocator.free(views);
        }
        for (self.jobs.items, views) |j, *view| {
            view.* = .{
                .id = j.id,
                .next_fire_unix = j.next_fire_unix,
                .schedule = if (j.recurring) .{ .recurring = try allocator.dupe(u8, j.cron_expr) } else .once,
            };
            filled += 1;
        }
        return views;
    }

    fn genId() !JobId {
        var raw: [6]u8 = undefined;
        if (!rng.randomBytes(&raw)) return error.RandomFailed;
        var id: JobId = .{ .bytes = undefined };
        _ = std.fmt.bufPrint(&id.bytes, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ raw[0], raw[1], raw[2], raw[3], raw[4], raw[5] }) catch unreachable;
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
    try testing.expect(reg.delete(id.slice()));
    try testing.expectEqual(@as(usize, 0), reg.count());
    try testing.expect(!reg.delete("nonexistent12"));
}

test "CronRegistry: one-shot delay collects + removes" {
    const a = testing.allocator;
    var reg = CronRegistry.init(a);
    defer reg.deinit();
    // delay = -10 → 已经 due
    _ = try reg.create("", -10, "fire now", false);
    const due = try reg.collectDue(a, std.math.maxInt(usize));
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
    const due = try reg.collectDue(a, std.math.maxInt(usize));
    defer {
        for (due) |p| a.free(p);
        a.free(due);
    }
    try testing.expectEqual(@as(usize, 0), due.len);
    try testing.expectEqual(@as(usize, 1), reg.count()); // 仍在
}

test "CronRegistry: a recurring job with no next fire is removed after it fires" {
    const a = testing.allocator;
    // No expression: what a CronCreate with only delaySeconds stored before
    // this fix. "0 0 30 2 *" (Feb 30) never matches, as a Feb 29 job finds no
    // match within a year after a leap day. `create` refuses both as
    // recurring, so each is stored one-shot and made recurring here.
    for ([_][]const u8{ "", "0 0 30 2 *" }) |expr| {
        var reg = CronRegistry.init(a);
        defer reg.deinit();
        _ = try reg.create(expr, 0, "fire once", false);
        reg.jobs.items[0].recurring = true;

        const due = try reg.collectDue(a, std.math.maxInt(usize));
        defer {
            for (due) |p| a.free(p);
            a.free(due);
        }
        try testing.expectEqual(@as(usize, 1), due.len);
        try testing.expectEqualStrings("fire once", due[0]);
        try testing.expectEqual(@as(usize, 0), reg.count());
    }
}

test "CronRegistry: create refuses a recurring job it cannot repeat" {
    const a = testing.allocator;
    var reg = CronRegistry.init(a);
    defer reg.deinit();
    try testing.expectError(error.InvalidCronExpr, reg.create("", 60, "x", true));
    try testing.expectError(error.InvalidCronExpr, reg.create("0 0 30 2 *", 60, "x", true));
    try testing.expectEqual(@as(usize, 0), reg.count());
    // A delay alone fires once; a delay with an expression is a recurring
    // job's first fire.
    _ = try reg.create("", 60, "once", false);
    _ = try reg.create("*/5 * * * *", 60, "every 5 min", true);
    try testing.expectEqual(@as(usize, 2), reg.count());
}

test "CronRegistry: a recurring job is rescheduled on its expression after it fires" {
    const a = testing.allocator;
    var reg = CronRegistry.init(a);
    defer reg.deinit();
    const before = util_time.nowUnix();
    _ = try reg.create("* * * * *", 0, "every minute", true);

    const due = try reg.collectDue(a, std.math.maxInt(usize));
    defer {
        for (due) |p| a.free(p);
        a.free(due);
    }
    try testing.expectEqual(@as(usize, 1), due.len);
    try testing.expectEqual(@as(usize, 1), reg.count());
    const next = reg.jobs.items[0].next_fire_unix;
    try testing.expect(next > before);
    try testing.expectEqual(@as(i64, 0), @mod(next, 60));
}

test "JobId.parse takes only what create makes" {
    const id = try JobId.parse("0123456789ab");
    try testing.expectEqualStrings("0123456789ab", id.slice());
    for ([_][]const u8{ "", "0123456789a", "0123456789abc", "0123456789AB", "0123456789ag" }) |text| {
        try testing.expectError(error.InvalidCronJobId, JobId.parse(text));
    }
}

test "CronRegistry: collectDue takes at most limit prompts, oldest first; the rest stay due" {
    const a = testing.allocator;
    var reg = CronRegistry.init(a);
    defer reg.deinit();
    _ = try reg.create("", 0, "one", false);
    _ = try reg.create("* * * * *", 0, "two", true);
    _ = try reg.create("", 0, "three", false);
    _ = try reg.create("", 3600, "later", false);
    try testing.expectEqual(@as(usize, 3), reg.dueCount());

    for ([_][]const []const u8{ &.{ "one", "two" }, &.{"three"} }) |expected| {
        const due = try reg.collectDue(a, 2);
        defer {
            for (due) |p| a.free(p);
            a.free(due);
        }
        try testing.expectEqual(expected.len, due.len);
        for (expected, due) |want, got| try testing.expectEqualStrings(want, got);
    }
    // The recurring job was rescheduled, the due one-shots are gone.
    try testing.expectEqual(@as(usize, 2), reg.count());
    try testing.expectEqual(@as(usize, 0), reg.dueCount());
    const views = try reg.list(a);
    defer freeViews(a, views);
    try testing.expectEqualStrings("* * * * *", views[0].schedule.recurring);
    try testing.expect(views[1].schedule == .once);
    try testing.expect(views[1].next_fire_unix > util_time.nowUnix());

    const none = try reg.collectDue(a, 0);
    defer a.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "CronRegistry: remove by id and clear" {
    const a = testing.allocator;
    var reg = CronRegistry.init(a);
    defer reg.deinit();
    const first = try reg.create("", 60, "a", false);
    _ = try reg.create("", 60, "b", false);
    _ = try reg.create("", 60, "c", false);
    try testing.expect(reg.remove(first));
    try testing.expect(!reg.remove(first));
    try testing.expect(!reg.delete("not-an-id"));
    try testing.expectEqual(@as(usize, 2), reg.clear());
    try testing.expectEqual(@as(usize, 0), reg.count());
    try testing.expectEqual(@as(usize, 0), reg.clear());
}
