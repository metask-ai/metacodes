//! Date and time-zone context for the model (issue #276).
//!
//! The model has no clock. Every entry point tells it today's date and the
//! time zone that date is in, independent of project instructions, memory or
//! the KG. The text never enters the system prompt: the CLI keeps it in the
//! user-context message it re-sends with every request and adds a notice to
//! the turn in which the date changes; AgentCore adds a `currentDate` context
//! block to each Run's user record. Either way history keeps the date each
//! turn was told, and the cached system prompt does not move at midnight.
//!
//! Time zone, strongest first: one the Host gives (a UTC offset), the
//! process's own (`platform.timezone`), or none - then UTC, said to be UTC
//! with the local zone unknown rather than passed off as local.

const std = @import("std");
const platform_tz = @import("platform").timezone;
const util_time = @import("metacodes-base").util.time;
const msg = @import("metacodes-kernel").message;

/// The context-block label a time snapshot uses. A Host block with this
/// label is the Run's time context and suppresses the runtime's own.
pub const label = "currentDate";

pub const Source = enum { host, system, unknown };

pub const Zone = struct {
    /// Minutes east of UTC.
    offset_minutes: i32,
    /// IANA id or abbreviation when known; borrowed from `name_storage` for
    /// system zones, empty otherwise.
    name_storage: [platform_tz.LocalZone.max_name_bytes]u8 = undefined,
    name_len: u8 = 0,
    source: Source,

    pub fn name(self: *const Zone) []const u8 {
        return self.name_storage[0..self.name_len];
    }

    pub const utc_unknown: Zone = .{ .offset_minutes = 0, .source = .unknown };

    /// A Host-given offset. Offsets outside UTC-14:00..UTC+14:00 do not exist.
    pub fn fromHostOffset(offset_minutes: i32) error{InvalidUtcOffset}!Zone {
        if (offset_minutes < min_offset_minutes or offset_minutes > max_offset_minutes) return error.InvalidUtcOffset;
        return .{ .offset_minutes = offset_minutes, .source = .host };
    }
};

pub const min_offset_minutes: i32 = -14 * 60;
pub const max_offset_minutes: i32 = 14 * 60;

/// The current time, unix seconds.
pub fn currentUnixSeconds() i64 {
    return util_time.nowUnix();
}

/// The process's zone at `unix_seconds`, or UTC marked unknown.
pub fn systemZone(unix_seconds: i64) Zone {
    const local = platform_tz.boundedLocal(unix_seconds) orelse return Zone.utc_unknown;
    var zone = Zone{ .offset_minutes = local.offset_minutes, .source = .system };
    const local_name = local.name();
    @memcpy(zone.name_storage[0..local_name.len], local_name);
    zone.name_len = @intCast(local_name.len);
    return zone;
}

pub const Weekday = enum { Sunday, Monday, Tuesday, Wednesday, Thursday, Friday, Saturday };

pub const LocalDate = struct {
    year: i32,
    month: u8,
    day: u8,
    weekday: Weekday,

    pub fn eql(a: LocalDate, b: LocalDate) bool {
        return a.year == b.year and a.month == b.month and a.day == b.day;
    }
};

/// The calendar date at `unix_seconds` in a zone `offset_minutes` east of UTC.
pub fn localDate(unix_seconds: i64, offset_minutes: i32) LocalDate {
    const date = platform_tz.civilDate(unix_seconds, offset_minutes);
    return .{ .year = date.year, .month = date.month, .day = date.day, .weekday = @enumFromInt(date.weekday) };
}

/// `UTC+08:00`, `UTC-05:30`, `UTC+00:00`.
pub fn formatOffset(buf: *[9]u8, offset_minutes: i32) []const u8 {
    return platform_tz.formatOffset(buf, offset_minutes);
}

fn writeDate(w: *std.Io.Writer, date: LocalDate) !void {
    try w.print("{d}-{d:0>2}-{d:0>2} ({s})", .{ date.year, date.month, date.day, @tagName(date.weekday) });
}

fn writeZone(w: *std.Io.Writer, zone: *const Zone) !void {
    var offset_buf: [9]u8 = undefined;
    const offset = formatOffset(&offset_buf, zone.offset_minutes);
    switch (zone.source) {
        .unknown => try w.writeAll("The date is in UTC; the user's time zone is unknown."),
        .host, .system => if (zone.name().len != 0)
            try w.print("Time zone: {s} ({s}).", .{ zone.name(), offset })
        else
            try w.print("Time zone: {s}.", .{offset}),
    }
}

/// `Today's date is 2026-10-16 (Friday). Time zone: Asia/Shanghai (UTC+08:00).`
pub fn writeToday(w: *std.Io.Writer, unix_seconds: i64, zone: *const Zone) !void {
    try w.writeAll("Today's date is ");
    try writeDate(w, localDate(unix_seconds, zone.offset_minutes));
    try w.writeAll(". ");
    try writeZone(w, zone);
}

pub fn today(allocator: std.mem.Allocator, unix_seconds: i64, zone: *const Zone) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeToday(&out.writer, unix_seconds, zone);
    return out.toOwnedSlice();
}

/// The CLI's per-session date bookkeeping: the user-context message carries
/// the date the session started on, and the first turn on a later date gets
/// one notice, so the model's timeline keeps every turn on the day it ran.
pub const Announcer = struct {
    /// The date the session-start text states.
    start: LocalDate,
    /// The last date the model was told.
    announced: LocalDate,
    now_fn: *const fn () i64 = defaultNow,

    pub fn defaultNow() i64 {
        return util_time.nowUnix();
    }

    /// Starts with the date the session-start text announced.
    pub fn init(unix_seconds: i64, zone: *const Zone, now_fn: *const fn () i64) Announcer {
        const date = localDate(unix_seconds, zone.offset_minutes);
        return .{ .start = date, .announced = date, .now_fn = now_fn };
    }

    /// History that may hold a notice was dropped or summarized (clear,
    /// rotation, compaction): only the session-start date is certain to
    /// reach the model now, so the next turn on a later date is told again.
    pub fn forget(self: *Announcer) void {
        self.announced = self.start;
    }

    /// A `<system-reminder>` notice when the local date differs from the one
    /// the model can still see, else null. `active` is the conversation's
    /// active window: when the last notice is no longer in it (compacted,
    /// trimmed, cleared, or a resumed history without it), the model sees only
    /// the session-start date again and the current date is told anew.
    pub fn noticeFor(self: *Announcer, allocator: std.mem.Allocator, active: []const msg.Message) !?[]u8 {
        if (!self.announced.eql(self.start) and !noticeVisible(active, self.announced)) self.forget();
        return self.noticeIfChanged(allocator);
    }

    /// As `noticeFor`, trusting that every earlier notice is still visible.
    pub fn noticeIfChanged(self: *Announcer, allocator: std.mem.Allocator) !?[]u8 {
        const now = self.now_fn();
        const zone = systemZone(now);
        const date = localDate(now, zone.offset_minutes);
        if (date.eql(self.announced)) return null;
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("<system-reminder>\nThe date has changed. ");
        try writeToday(w, now, &zone);
        comptime std.debug.assert(std.mem.endsWith(u8, notice_lead, "Today's date is "));
        try w.writeAll(" Do not mention this to the user explicitly because they are already aware.\n</system-reminder>");
        const text = try out.toOwnedSlice();
        self.announced = date;
        return text;
    }
};

const notice_lead = "<system-reminder>\nThe date has changed. Today's date is ";

/// Whether a user message in `active` carries the notice for `date`.
fn noticeVisible(active: []const msg.Message, date: LocalDate) bool {
    var marker_buf: [notice_lead.len + 32]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, notice_lead ++ "{d}-{d:0>2}-{d:0>2}", .{ date.year, date.month, date.day }) catch return false;
    var i = active.len;
    while (i > 0) {
        i -= 1;
        const message = active[i];
        if (message.role != .user) continue;
        for (message.blocks) |block| switch (block) {
            .text => |text| if (std.mem.startsWith(u8, text, marker)) return true,
            else => {},
        };
    }
    return false;
}

const testing = std.testing;

test "localDate follows the zone across midnight on both sides of UTC" {
    // 2026-10-16T16:30:00Z: still the 16th in UTC, already the 17th in Shanghai,
    // and the 16th in New York (EDT).
    const instant: i64 = 1_792_168_200;
    const utc = localDate(instant, 0);
    try testing.expectEqual(@as(i32, 2026), utc.year);
    try testing.expectEqual(@as(u8, 10), utc.month);
    try testing.expectEqual(@as(u8, 16), utc.day);
    try testing.expectEqual(Weekday.Friday, utc.weekday);
    const shanghai = localDate(instant, 8 * 60);
    try testing.expectEqual(@as(u8, 17), shanghai.day);
    try testing.expectEqual(Weekday.Saturday, shanghai.weekday);
    const new_york = localDate(instant, -4 * 60);
    try testing.expectEqual(@as(u8, 16), new_york.day);
    // One second before local midnight in Shanghai is still the 16th there.
    const before = localDate(1_792_166_399, 8 * 60);
    try testing.expectEqual(@as(u8, 16), before.day);
    // Leap day, year and month boundaries, and the epoch itself.
    const leap = localDate(1_709_164_800, 0); // 2024-02-29
    try testing.expectEqual(@as(u8, 2), leap.month);
    try testing.expectEqual(@as(u8, 29), leap.day);
    const new_year = localDate(1_798_761_599, 0); // 2026-12-31T23:59:59Z
    try testing.expectEqual(@as(u8, 31), new_year.day);
    try testing.expectEqual(@as(i32, 2027), localDate(1_798_761_599, 60).year);
    const epoch = localDate(0, 0);
    try testing.expectEqual(@as(i32, 1970), epoch.year);
    try testing.expectEqual(Weekday.Thursday, epoch.weekday);
    try testing.expectEqual(@as(i32, 1969), localDate(0, -60).year);
}

test "the date text names the zone, its offset, and an unknown zone as such" {
    const a = testing.allocator;
    const instant: i64 = 1_792_168_200;
    var shanghai = try Zone.fromHostOffset(8 * 60);
    @memcpy(shanghai.name_storage[0.."Asia/Shanghai".len], "Asia/Shanghai");
    shanghai.name_len = "Asia/Shanghai".len;
    const named = try today(a, instant, &shanghai);
    defer a.free(named);
    try testing.expectEqualStrings("Today's date is 2026-10-17 (Saturday). Time zone: Asia/Shanghai (UTC+08:00).", named);

    const india = try Zone.fromHostOffset(5 * 60 + 30);
    const offset_only = try today(a, instant, &india);
    defer a.free(offset_only);
    try testing.expectEqualStrings("Today's date is 2026-10-16 (Friday). Time zone: UTC+05:30.", offset_only);

    const west = try Zone.fromHostOffset(-(9 * 60 + 30));
    const negative = try today(a, instant, &west);
    defer a.free(negative);
    try testing.expectEqualStrings("Today's date is 2026-10-16 (Friday). Time zone: UTC-09:30.", negative);

    const unknown = try today(a, instant, &Zone.utc_unknown);
    defer a.free(unknown);
    try testing.expectEqualStrings("Today's date is 2026-10-16 (Friday). The date is in UTC; the user's time zone is unknown.", unknown);

    try testing.expectError(error.InvalidUtcOffset, Zone.fromHostOffset(14 * 60 + 1));
    try testing.expectError(error.InvalidUtcOffset, Zone.fromHostOffset(-14 * 60 - 1));
}

test "Announcer says nothing until the local date changes, then once per date" {
    const a = testing.allocator;
    const Clock = struct {
        var now: i64 = 0;
        fn read() i64 {
            return now;
        }
    };
    const zone = systemZone(1_792_000_000);
    // A session started at local noon on some day.
    const start_local_noon: i64 = 1_792_000_000 - @mod(1_792_000_000 + @as(i64, zone.offset_minutes) * 60, std.time.s_per_day) + 12 * 3600;
    Clock.now = start_local_noon;
    var announcer = Announcer.init(start_local_noon, &zone, Clock.read);
    try testing.expect((try announcer.noticeIfChanged(a)) == null);
    Clock.now = start_local_noon + 11 * 3600; // 23:00 the same day
    try testing.expect((try announcer.noticeIfChanged(a)) == null);
    Clock.now = start_local_noon + 13 * 3600; // 01:00 the next day
    const notice = (try announcer.noticeIfChanged(a)) orelse return error.MissingNotice;
    defer a.free(notice);
    try testing.expect(std.mem.startsWith(u8, notice, "<system-reminder>\nThe date has changed. Today's date is "));
    try testing.expect(std.mem.endsWith(u8, notice, "</system-reminder>"));
    try testing.expect((try announcer.noticeIfChanged(a)) == null);
    // After the history that held the notice is gone, the new date is told again.
    announcer.forget();
    const again = (try announcer.noticeIfChanged(a)) orelse return error.MissingNotice;
    a.free(again);
    try testing.expect((try announcer.noticeIfChanged(a)) == null);
}

test "noticeFor re-announces a date whose notice left the active window" {
    const a = testing.allocator;
    const Clock = struct {
        var now: i64 = 0;
        fn read() i64 {
            return now;
        }
    };
    const zone = systemZone(1_792_000_000);
    const start: i64 = 1_792_000_000 - @mod(1_792_000_000 + @as(i64, zone.offset_minutes) * 60, std.time.s_per_day) + 12 * 3600;
    Clock.now = start;
    var announcer = Announcer.init(start, &zone, Clock.read);
    Clock.now = start + 24 * 3600;
    const notice = (try announcer.noticeFor(a, &.{})) orelse return error.MissingNotice;
    defer a.free(notice);
    // The notice is in the window: nothing more to say.
    var blocks = [_]msg.Block{.{ .text = notice }};
    const with_notice = [_]msg.Message{.{ .role = .user, .blocks = &blocks }};
    try testing.expect((try announcer.noticeFor(a, &with_notice)) == null);
    // Compacted away: the model sees only the start date, so it is told again.
    const again = (try announcer.noticeFor(a, &.{})) orelse return error.MissingNotice;
    a.free(again);
}

test "systemZone is the process zone or UTC marked unknown" {
    const zone = systemZone(1_792_000_000);
    try testing.expect(zone.offset_minutes >= min_offset_minutes and zone.offset_minutes <= max_offset_minutes);
    if (zone.source == .unknown) try testing.expectEqual(@as(i32, 0), zone.offset_minutes);
}
