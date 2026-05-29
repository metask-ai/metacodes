//! 解析 settings.json 的 `sandbox` 段 → SandboxSettings。
//!
//! Schema(对齐 doc/PERMISSION_DESIGN.md 9.4):
//!   "sandbox": {
//!     "enabled": true,
//!     "failIfUnavailable": false,
//!     "allowUnsandboxedCommands": true,   // 逃生口开关
//!     "autoAllowBashIfSandboxed": true,   // 沙箱内 bash 自动放行
//!     "filesystem": { "allowWrite":[], "denyWrite":[], "allowRead":[], "denyRead":[] },
//!     "network": { "allowedDomains":[], "deniedDomains":[] },
//!     "excludedCommands": ["docker"]      // 这些命令不进沙箱
//!   }
//!
//! 多层 settings 的 filesystem/network 数组**合并**(由 caller 跨层合并;本模块只解析单层)。

const std = @import("std");

pub const SandboxSettings = struct {
    enabled: bool = false,
    fail_if_unavailable: bool = false,
    allow_unsandboxed_commands: bool = true,
    auto_allow_bash_if_sandboxed: bool = true,

    allow_write: []const []const u8 = &.{},
    deny_write: []const []const u8 = &.{},
    allow_read: []const []const u8 = &.{},
    deny_read: []const []const u8 = &.{},

    allowed_domains: []const []const u8 = &.{},
    denied_domains: []const []const u8 = &.{},

    excluded_commands: []const []const u8 = &.{},

    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *SandboxSettings) void {
        const a = self.allocator orelse return;
        freeList(a, self.allow_write);
        freeList(a, self.deny_write);
        freeList(a, self.allow_read);
        freeList(a, self.deny_read);
        freeList(a, self.allowed_domains);
        freeList(a, self.denied_domains);
        freeList(a, self.excluded_commands);
    }

    /// excludedCommands 命中?(第一个 token 匹配)
    pub fn isExcludedCommand(self: *const SandboxSettings, cmd_head: []const u8) bool {
        for (self.excluded_commands) |e| {
            if (std.mem.eql(u8, e, cmd_head)) return true;
        }
        return false;
    }
};

fn freeList(a: std.mem.Allocator, list: []const []const u8) void {
    for (list) |s| a.free(s);
    a.free(list);
}

/// 从一个 settings JSON root 解析 sandbox 段。无 sandbox 段返回 disabled 默认。
pub fn parse(alloc: std.mem.Allocator, root: std.json.Value) !SandboxSettings {
    var s = SandboxSettings{ .allocator = alloc };
    if (root != .object) return s;
    const sb_v = root.object.get("sandbox") orelse return s;
    if (sb_v != .object) return s;
    const sb = sb_v.object;

    s.enabled = getBool(sb, "enabled", false);
    s.fail_if_unavailable = getBool(sb, "failIfUnavailable", false);
    s.allow_unsandboxed_commands = getBool(sb, "allowUnsandboxedCommands", true);
    s.auto_allow_bash_if_sandboxed = getBool(sb, "autoAllowBashIfSandboxed", true);

    if (sb.get("filesystem")) |fs_v| {
        if (fs_v == .object) {
            s.allow_write = try getStrArray(alloc, fs_v.object, "allowWrite");
            s.deny_write = try getStrArray(alloc, fs_v.object, "denyWrite");
            s.allow_read = try getStrArray(alloc, fs_v.object, "allowRead");
            s.deny_read = try getStrArray(alloc, fs_v.object, "denyRead");
        }
    }
    if (sb.get("network")) |net_v| {
        if (net_v == .object) {
            s.allowed_domains = try getStrArray(alloc, net_v.object, "allowedDomains");
            s.denied_domains = try getStrArray(alloc, net_v.object, "deniedDomains");
        }
    }
    s.excluded_commands = try getStrArrayTop(alloc, sb, "excludedCommands");

    return s;
}

fn getBool(obj: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const v = obj.get(key) orelse return default;
    return if (v == .bool) v.bool else default;
}

fn getStrArray(alloc: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    return getStrArrayTop(alloc, obj, key);
}

fn getStrArrayTop(alloc: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const v = obj.get(key) orelse return &.{};
    if (v != .array) return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |s| alloc.free(s);
        list.deinit(alloc);
    }
    for (v.array.items) |item| {
        if (item != .string) continue;
        try list.append(alloc, try alloc.dupe(u8, item.string));
    }
    return try list.toOwnedSlice(alloc);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parse: full sandbox config" {
    const src =
        \\{"sandbox":{
        \\  "enabled":true,
        \\  "allowUnsandboxedCommands":false,
        \\  "autoAllowBashIfSandboxed":false,
        \\  "filesystem":{"allowWrite":["/tmp/x","~/.kube"],"denyRead":["~/.ssh"]},
        \\  "network":{"allowedDomains":["github.com"]},
        \\  "excludedCommands":["docker","direnv"]
        \\}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    var s = try parse(testing.allocator, parsed.value);
    defer s.deinit();

    try testing.expect(s.enabled);
    try testing.expect(!s.allow_unsandboxed_commands);
    try testing.expect(!s.auto_allow_bash_if_sandboxed);
    try testing.expectEqual(@as(usize, 2), s.allow_write.len);
    try testing.expectEqualStrings("/tmp/x", s.allow_write[0]);
    try testing.expectEqual(@as(usize, 1), s.deny_read.len);
    try testing.expectEqual(@as(usize, 1), s.allowed_domains.len);
    try testing.expect(s.isExcludedCommand("docker"));
    try testing.expect(s.isExcludedCommand("direnv"));
    try testing.expect(!s.isExcludedCommand("git"));
}

test "parse: no sandbox section → disabled default" {
    const src = "{\"permissions\":{}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    var s = try parse(testing.allocator, parsed.value);
    defer s.deinit();
    try testing.expect(!s.enabled);
    try testing.expect(s.allow_unsandboxed_commands); // 默认 true
    try testing.expect(s.auto_allow_bash_if_sandboxed); // 默认 true
}
