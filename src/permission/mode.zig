//! 权限模式(Mode):Claude Code 的 5 个执行模式 + cc-zig 历史别名。
//!
//! 不含 plan:plan 模式已移除,`plan` 是词表外的值(严格解析返回 null,由边界报错)。
//! 语义以本模块枚举与其测试为准。解析支持驼峰(acceptEdits)和下划线(accept_edits)两种写法。

const std = @import("std");
const types = @import("../types.zig");

pub const Mode = types.PermissionMode;

/// 严格解析:词表外返回 null,由调用方决定 fail-closed 还是回退。
/// CLI 边界必须用这个——`--permission BOGUS` 静默落 .default 会让评估
/// treatment 参数拼错时无声降级(2026-08-17 harness 复审 #3)。
/// 接受:default/acceptEdits/auto/dontAsk/bypassPermissions(官方驼峰)
///   + accept_edits/dont_ask/bypass_permissions(下划线变体)
///   + prompt/bypass(历史 cc-zig 名)
pub fn parseStrict(s: []const u8) ?Mode {
    // 官方驼峰
    if (std.mem.eql(u8, s, "default")) return .default;
    if (std.mem.eql(u8, s, "acceptEdits")) return .accept_edits;
    if (std.mem.eql(u8, s, "auto")) return .auto;
    if (std.mem.eql(u8, s, "dontAsk")) return .dont_ask;
    if (std.mem.eql(u8, s, "bypassPermissions")) return .bypass_permissions;
    // 下划线变体
    if (std.mem.eql(u8, s, "accept_edits")) return .accept_edits;
    if (std.mem.eql(u8, s, "dont_ask")) return .dont_ask;
    if (std.mem.eql(u8, s, "bypass_permissions")) return .bypass_permissions;
    // 历史别名
    if (std.mem.eql(u8, s, "prompt")) return .default;
    if (std.mem.eql(u8, s, "bypass")) return .bypass_permissions;
    return null;
}

/// A mode name as a person or a client types it: everything `parseStrict`
/// accepts, plus the hyphenated spelling of the underscore variants
/// (`accept-edits`, `dont-ask`, `bypass-permissions`). Unknown → null.
/// `/mode <name>` and the web/daemon `permission_mode` message field share it,
/// so the two surfaces cannot drift apart on which names they accept.
pub fn parseName(s: []const u8) ?Mode {
    if (parseStrict(s)) |m| return m;
    var buf: [32]u8 = undefined;
    if (s.len > buf.len) return null;
    for (s, 0..) |ch, i| buf[i] = if (ch == '-') '_' else ch;
    return parseStrict(buf[0..s.len]);
}

/// Why a mode the settings disable (`disableBypassPermissionsMode`,
/// `disableAutoMode`) was refused, in words: what `--web`/`serve` and
/// `SessionHost` (#445) journal as `message_rejected.message`.
pub fn disabledReason(m: Mode) []const u8 {
    return switch (canonical(m)) {
        .bypass_permissions => "bypassPermissions is disabled by settings",
        .auto => "auto mode is disabled by settings",
        else => "permission mode is disabled by settings",
    };
}

/// 宽松解析(settings/config 层沿用):未知值退化为 .default。
pub fn parse(s: []const u8) Mode {
    return parseStrict(s) orelse .default;
}

/// 把 Mode 标准化:把 prompt/bypass 历史别名映到 default/bypass_permissions。
pub fn canonical(m: Mode) Mode {
    return switch (m) {
        .prompt => .default,
        .bypass => .bypass_permissions,
        else => m,
    };
}

test "parse all official modes" {
    try std.testing.expect(parse("default") == .default);
    try std.testing.expect(parse("acceptEdits") == .accept_edits);
    try std.testing.expect(parse("auto") == .auto);
    try std.testing.expect(parse("dontAsk") == .dont_ask);
    try std.testing.expect(parse("bypassPermissions") == .bypass_permissions);
}

test "parse historic aliases" {
    try std.testing.expect(parse("prompt") == .default);
    try std.testing.expect(parse("bypass") == .bypass_permissions);
}

test "parse underscore variants" {
    try std.testing.expect(parse("accept_edits") == .accept_edits);
    try std.testing.expect(parse("dont_ask") == .dont_ask);
    try std.testing.expect(parse("bypass_permissions") == .bypass_permissions);
}

test "parse unknown → default" {
    try std.testing.expect(parse("garbage") == .default);
}

test "plan is no longer a permission mode" {
    try std.testing.expect(parseStrict("plan") == null);
    try std.testing.expect(parseName("plan") == null);
}

test "parseName: strict names, hyphenated spellings, nothing else" {
    try std.testing.expect(parseName("acceptEdits") == .accept_edits);
    try std.testing.expect(parseName("accept_edits") == .accept_edits);
    try std.testing.expect(parseName("accept-edits") == .accept_edits);
    try std.testing.expect(parseName("dont-ask") == .dont_ask);
    try std.testing.expect(parseName("bypass-permissions") == .bypass_permissions);
    try std.testing.expect(parseName("default") == .default);
    try std.testing.expect(parseName("") == null);
    try std.testing.expect(parseName("accept edits") == null);
    try std.testing.expect(parseName("-") == null);
    try std.testing.expect(parseName("a" ** 33) == null);
}

test "canonical maps aliases" {
    try std.testing.expect(canonical(.prompt) == .default);
    try std.testing.expect(canonical(.bypass) == .bypass_permissions);
    try std.testing.expect(canonical(.default) == .default);
    try std.testing.expect(canonical(.dont_ask) == .dont_ask);
}
