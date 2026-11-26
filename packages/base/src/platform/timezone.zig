//! The process's local time zone (issue #276): the UTC offset in force at an
//! instant and a name to show for it.
//!
//! POSIX asks libc - `tzset` then `localtime_r`, which honour `TZ`,
//! `/etc/localtime` and the zone's daylight-saving rules (tzdata's "slim"
//! files keep later rules only in their POSIX footer, so reading the
//! transition table alone would be wrong for half the year in DST zones).
//! Windows asks the system's dynamic time-zone information. `local` returns
//! null when the platform cannot tell, so a caller can say "UTC, time zone
//! unknown" instead of guessing.

const std = @import("std");
const builtin = @import("builtin");

pub const LocalZone = struct {
    /// Minutes east of UTC in force at the queried instant.
    offset_minutes: i32,
    name_buf: [max_name_bytes]u8 = undefined,
    name_len: u8 = 0,

    pub const max_name_bytes = 64;

    /// IANA id (`Asia/Shanghai`), Windows time-zone key, or abbreviation;
    /// empty when none is known.
    pub fn name(self: *const LocalZone) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn setName(self: *LocalZone, value: []const u8) void {
        if (value.len == 0 or value.len > max_name_bytes or !std.unicode.utf8ValidateSlice(value)) return;
        @memcpy(self.name_buf[0..value.len], value);
        self.name_len = @intCast(value.len);
    }
};

/// The local zone at `unix_seconds` (POSIX) or now (Windows), or null when
/// this platform cannot tell.
pub fn local(unix_seconds: i64) ?LocalZone {
    return switch (builtin.os.tag) {
        .windows => windowsLocal(),
        .macos, .ios, .linux, .freebsd, .netbsd, .openbsd, .dragonfly => posixLocal(unix_seconds),
        else => null,
    };
}

pub const min_offset_minutes: i32 = -14 * 60;
pub const max_offset_minutes: i32 = 14 * 60;

pub fn boundedLocal(unix_seconds: i64) ?LocalZone {
    const zone = local(unix_seconds) orelse return null;
    if (zone.offset_minutes < min_offset_minutes or zone.offset_minutes > max_offset_minutes) return null;
    return zone;
}

pub const CivilDate = struct {
    year: i32,
    month: u8,
    day: u8,
    weekday: u3,
};

/// The calendar date at `unix_seconds` in a zone `offset_minutes` east of UTC.
pub fn civilDate(unix_seconds: i64, offset_minutes: i32) CivilDate {
    const local_seconds = unix_seconds + @as(i64, offset_minutes) * 60;
    const days = @divFloor(local_seconds, std.time.s_per_day);
    // Civil-from-days (Howard Hinnant), valid on both sides of 1970.
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe: i64 = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day: i64 = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month: i64 = if (mp < 10) mp + 3 else mp - 9;
    const year: i64 = yoe + era * 400 + @as(i64, if (month <= 2) 1 else 0);
    // 1970-01-01 was a Thursday.
    const weekday: u3 = @intCast(@mod(days + 4, 7));
    return .{
        .year = @intCast(year),
        .month = @intCast(month),
        .day = @intCast(day),
        .weekday = weekday,
    };
}

/// `UTC+08:00`, `UTC-05:30`, `UTC+00:00`.
pub fn formatOffset(buf: *[9]u8, offset_minutes: i32) []const u8 {
    const sign: u8 = if (offset_minutes < 0) '-' else '+';
    const magnitude: u32 = @abs(offset_minutes);
    return std.fmt.bufPrint(buf, "UTC{c}{d:0>2}:{d:0>2}", .{ sign, magnitude / 60, magnitude % 60 }) catch unreachable;
}

// ── POSIX ─────────────────────────────────────────────────────────────────

/// `struct tm` with the BSD/glibc/musl `tm_gmtoff` and `tm_zone` members, on
/// the 64-bit ABIs this module is built for.
const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

extern "c" fn tzset() void;
extern "c" fn localtime_r(timep: *const i64, result: *Tm) ?*Tm;

fn posixLocal(unix_seconds: i64) ?LocalZone {
    if (@sizeOf(usize) != 8 or @sizeOf(c_long) != 8) return null;
    tzset();
    var tm: Tm = undefined;
    _ = localtime_r(&unix_seconds, &tm) orelse return null;
    const offset_seconds: i64 = tm.tm_gmtoff;
    if (offset_seconds < -18 * 3600 or offset_seconds > 18 * 3600) return null;
    var zone = LocalZone{ .offset_minutes = @intCast(@divTrunc(offset_seconds, 60)) };
    setPosixZoneName(&zone);
    if (zone.name_len == 0) if (tm.tm_zone) |abbr| zone.setName(std.mem.span(abbr));
    return zone;
}

/// Names `zone` with the IANA id the process runs under: `TZ` when it names
/// a zone, else the target of `/etc/localtime`. Leaves it unnamed when neither
/// does (a POSIX rule string such as "CST-8" names no zone).
fn setPosixZoneName(zone: *LocalZone) void {
    if (std.c.getenv("TZ")) |raw| {
        const tz = std.mem.span(raw);
        const value = if (tz.len != 0 and tz[0] == ':') tz[1..] else tz;
        if (value.len != 0) {
            if (zoneinfoName(value)) |name| return zone.setName(name);
            if (looksLikeZoneId(value)) return zone.setName(value);
            return;
        }
    }
    var buf: [1024]u8 = undefined;
    const n = std.c.readlink("/etc/localtime", &buf, buf.len);
    if (n <= 0 or @as(usize, @intCast(n)) >= buf.len) return;
    if (zoneinfoName(buf[0..@intCast(n)])) |name| zone.setName(name);
}

/// `.../zoneinfo/Asia/Shanghai` -> `Asia/Shanghai`.
fn zoneinfoName(path: []const u8) ?[]const u8 {
    const marker = "zoneinfo/";
    const at = std.mem.lastIndexOf(u8, path, marker) orelse return null;
    const name = path[at + marker.len ..];
    return if (looksLikeZoneId(name)) name else null;
}

/// `Area/Location`, `UTC`, `Etc/GMT-8`: letters, digits and `/_-+`, no path
/// syntax and no POSIX rule punctuation.
fn looksLikeZoneId(value: []const u8) bool {
    if (value.len == 0 or value.len > LocalZone.max_name_bytes or value[0] == '/' or value[0] == '.') return false;
    for (value) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '/' or c == '_' or c == '-' or c == '+')) return false;
    }
    if (std.mem.indexOf(u8, value, "..") != null) return false;
    // A bare rule like "CST6CDT" has no slash and digits inside; a bare id
    // like "UTC" or "Japan" has neither.
    if (std.mem.indexOfScalar(u8, value, '/') == null) {
        for (value) |c| if (std.ascii.isDigit(c)) return false;
    }
    return true;
}

// ── Windows ───────────────────────────────────────────────────────────────

const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};

const DYNAMIC_TIME_ZONE_INFORMATION = extern struct {
    Bias: i32,
    StandardName: [32]u16,
    StandardDate: SYSTEMTIME,
    StandardBias: i32,
    DaylightName: [32]u16,
    DaylightDate: SYSTEMTIME,
    DaylightBias: i32,
    TimeZoneKeyName: [128]u16,
    DynamicDaylightTimeDisabled: u8,
};

const TIME_ZONE_ID_STANDARD: u32 = 1;
const TIME_ZONE_ID_DAYLIGHT: u32 = 2;
const TIME_ZONE_ID_INVALID: u32 = 0xFFFF_FFFF;

extern "kernel32" fn GetDynamicTimeZoneInformation(info: *DYNAMIC_TIME_ZONE_INFORMATION) callconv(.winapi) u32;

fn windowsLocal() ?LocalZone {
    if (builtin.os.tag != .windows) return null;
    var info = std.mem.zeroes(DYNAMIC_TIME_ZONE_INFORMATION);
    const id = GetDynamicTimeZoneInformation(&info);
    if (id == TIME_ZONE_ID_INVALID) return null;
    // Bias is minutes *west* of UTC: local = UTC - (Bias + seasonal bias).
    const seasonal: i32 = switch (id) {
        TIME_ZONE_ID_DAYLIGHT => info.DaylightBias,
        TIME_ZONE_ID_STANDARD => info.StandardBias,
        else => 0,
    };
    const offset = -(info.Bias + seasonal);
    if (offset < -18 * 60 or offset > 18 * 60) return null;
    var zone = LocalZone{ .offset_minutes = offset };
    const key_len = std.mem.indexOfScalar(u16, &info.TimeZoneKeyName, 0) orelse info.TimeZoneKeyName.len;
    var utf8: [LocalZone.max_name_bytes * 3]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&utf8, info.TimeZoneKeyName[0..key_len]) catch 0;
    zone.setName(utf8[0..n]);
    return zone;
}

test "zone ids are recognised and rule strings are not" {
    try std.testing.expectEqualStrings("Asia/Shanghai", zoneinfoName("/var/db/timezone/zoneinfo/Asia/Shanghai").?);
    try std.testing.expectEqualStrings("America/Argentina/Buenos_Aires", zoneinfoName("/usr/share/zoneinfo/America/Argentina/Buenos_Aires").?);
    try std.testing.expectEqualStrings("Etc/GMT-8", zoneinfoName("../usr/share/zoneinfo/Etc/GMT-8").?);
    try std.testing.expect(zoneinfoName("/etc/localtime") == null);
    try std.testing.expect(looksLikeZoneId("UTC"));
    try std.testing.expect(looksLikeZoneId("Europe/London"));
    try std.testing.expect(!looksLikeZoneId("CST-8"));
    try std.testing.expect(!looksLikeZoneId("CST6CDT"));
    try std.testing.expect(!looksLikeZoneId("EST5EDT,M3.2.0,M11.1.0"));
    try std.testing.expect(!looksLikeZoneId("/usr/share/zoneinfo/UTC"));
    try std.testing.expect(!looksLikeZoneId("../../etc/passwd"));
}

test "local reports a plausible offset and a valid name where the platform can tell" {
    const now: i64 = 1_792_000_000; // 2026-10-15
    const zone = local(now) orelse {
        if (builtin.os.tag == .windows or builtin.os.tag == .macos or builtin.os.tag == .linux)
            return error.TestExpectedLocalZone;
        return;
    };
    try std.testing.expect(zone.offset_minutes >= -18 * 60 and zone.offset_minutes <= 18 * 60);
    try std.testing.expect(std.unicode.utf8ValidateSlice(zone.name()));
}

test "local follows TZ through daylight saving, and a rule string falls back to its abbreviation" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // Without tzdata the libc answer is UTC, which would test nothing.
    if (std.c.access("/usr/share/zoneinfo/America/New_York", 4) != 0) return error.SkipZigTest; // R_OK
    const paths = @import("paths.zig");
    var saved_buf: [256]u8 = undefined;
    const saved: ?[:0]const u8 = if (std.c.getenv("TZ")) |raw|
        std.fmt.bufPrintZ(&saved_buf, "{s}", .{std.mem.span(raw)}) catch return error.SkipZigTest
    else
        null;
    defer if (saved) |value| paths.setEnv("TZ", value) else paths.unsetEnv("TZ");

    const january: i64 = 1_768_478_400; // 2026-01-15T12:00:00Z
    const july: i64 = 1_784_116_800; // 2026-07-15T12:00:00Z
    paths.setEnv("TZ", "America/New_York");
    const winter = local(january) orelse return error.TestExpectedLocalZone;
    const summer = local(july) orelse return error.TestExpectedLocalZone;
    try std.testing.expectEqual(@as(i32, -300), winter.offset_minutes);
    try std.testing.expectEqual(@as(i32, -240), summer.offset_minutes);
    try std.testing.expectEqualStrings("America/New_York", winter.name());

    paths.setEnv("TZ", "CST-8");
    const rule = local(january) orelse return error.TestExpectedLocalZone;
    try std.testing.expectEqual(@as(i32, 480), rule.offset_minutes);
    try std.testing.expectEqualStrings("CST", rule.name());
}

test "LocalZone keeps only short valid names" {
    var zone = LocalZone{ .offset_minutes = 0 };
    zone.setName("x" ** (LocalZone.max_name_bytes + 1));
    try std.testing.expectEqualStrings("", zone.name());
    zone.setName("Asia/Shanghai");
    try std.testing.expectEqualStrings("Asia/Shanghai", zone.name());
}
