//! 用户配置持久化：~/.metacodes/config.json
//!
//! 字段（全部可选，缺失用默认）：
//!   {
//!     "model": "claude-sonnet-4-20250514",
//!     "permission_mode": "prompt",
//!     "max_turns": 50,
//!     "verbose": false,
//!     "no_theme": false
//!   }
//!
//! 优先级：CLI 参数 > 环境变量 > 文件 > 默认。
//! 本模块只负责"从文件加载" + "保存到文件"。CLI 和 env 合并由 main.zig 控制。

const std = @import("std");
const pfs = @import("platform").fs;
const util_json = @import("../util/json.zig");
const json_merge = @import("../util/json_merge.zig");

pub const FileConfig = struct {
    model: ?[]const u8 = null,
    permission_mode: ?[]const u8 = null,
    max_turns: ?u32 = null,
    verbose: ?bool = null,
    no_theme: ?bool = null,

    pub fn deinit(self: FileConfig, allocator: std.mem.Allocator) void {
        if (self.model) |m| allocator.free(m);
        if (self.permission_mode) |p| allocator.free(p);
    }
};

/// Schema version of `~/.metacodes/config.json` this build reads and writes
/// (doc/API.md); `--version --json` reports it as `contract.config_schema_version`.
pub const SCHEMA_VERSION: u32 = 1;

/// 从 ~/.metacodes/config.json 加载。文件不存在返回全默认（null 字段）。
pub fn loadFromHome(allocator: std.mem.Allocator) !FileConfig {
    const path = try homePath(allocator);
    defer allocator.free(path);
    return loadFromFile(allocator, path);
}

pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !FileConfig {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = pfs.open(path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return .{}; // 不存在 = 空配置

    defer _ = pfs.close(fd);

    var buf: [16384]u8 = undefined;
    var contents = std.ArrayList(u8).empty;
    defer contents.deinit(allocator);

    while (true) {
        const n = pfs.read(fd, &buf);
        if (n <= 0) break;
        try contents.appendSlice(allocator, buf[0..@as(usize, @intCast(n))]);
    }

    return parseJson(allocator, contents.items);
}

/// 保存到 ~/.metacodes/config.json（覆盖写 + fsync）。
pub fn saveToHome(config: FileConfig, allocator: std.mem.Allocator) !void {
    const path = try homePath(allocator);
    defer allocator.free(path);
    return saveToFile(config, allocator, path);
}

pub fn saveToFile(config: FileConfig, allocator: std.mem.Allocator, path: []const u8) !void {
    // 确保父目录
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        const parent = path[0..slash];
        if (parent.len > 0) {
            const parent_z = try allocator.dupeZ(u8, parent);
            defer allocator.free(parent_z);
            _ = std.c.mkdir(parent_z, 0o700);
        }
    }

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    // Read-modify-write. `config.json` has several independent owners
    // (theme, mcp_servers, permission_rules, model_tiers, and the issue #16
    // provider control plane). Serializing only this struct's fields would
    // delete every other owner's data, so replace exactly these keys and keep
    // the rest of the document — and its key order — intact.
    const existing = try readWhole(allocator, path_z);
    defer allocator.free(existing);

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    var fields: std.ArrayList(json_merge.Field) = .empty;
    if (config.model) |v| {
        var buf: std.ArrayList(u8) = .empty;
        try util_json.serializeString(v, &buf, arena);
        try fields.append(arena, .{ .key = "model", .json = buf.items });
    }
    if (config.permission_mode) |v| {
        var buf: std.ArrayList(u8) = .empty;
        try util_json.serializeString(v, &buf, arena);
        try fields.append(arena, .{ .key = "permission_mode", .json = buf.items });
    }
    if (config.max_turns) |v| {
        try fields.append(arena, .{
            .key = "max_turns",
            .json = try std.fmt.allocPrint(arena, "{d}", .{v}),
        });
    }
    if (config.verbose) |v| {
        try fields.append(arena, .{ .key = "verbose", .json = if (v) "true" else "false" });
    }
    if (config.no_theme) |v| {
        try fields.append(arena, .{ .key = "no_theme", .json = if (v) "true" else "false" });
    }

    const merged = json_merge.mergeObjectFields(allocator, existing, fields.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A document we cannot parse must not be overwritten: that would turn
        // a hand-edit typo into silent data loss.
        else => return error.MalformedExistingConfig,
    };
    defer allocator.free(merged);

    const fd = pfs.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.WriteError;
    defer _ = pfs.close(fd);
    const written = pfs.write(fd, merged);
    if (written < 0 or @as(usize, @intCast(written)) != merged.len) return error.WriteError;
    _ = pfs.fsync(fd);
}

fn readWhole(allocator: std.mem.Allocator, path_z: [:0]const u8) ![]u8 {
    const fd = pfs.open(path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) {
        // Only an absent file is an empty document. Descriptor exhaustion, an
        // I/O error, or a transient permission failure must not be read as
        // "nothing here" — the caller merges onto this result and writes it
        // back, so a wrong empty read truncates every other writer's data.
        const errno: std.c.E = @enumFromInt(std.c._errno().*);
        if (errno != .NOENT) return error.ConfigUnreadable;
        return allocator.dupe(u8, "");
    }
    defer _ = pfs.close(fd);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &buf);
        if (n == 0) break;
        if (n < 0) return error.ConfigUnreadable;
        try out.appendSlice(allocator, buf[0..@as(usize, @intCast(n))]);
    }
    return out.toOwnedSlice(allocator);
}

fn parseJson(allocator: std.mem.Allocator, data: []const u8) !FileConfig {
    var cfg = FileConfig{};
    if (util_json.extractStringField(data, "model")) |v| {
        cfg.model = try allocator.dupe(u8, v);
    }
    if (util_json.extractStringField(data, "permission_mode")) |v| {
        cfg.permission_mode = try allocator.dupe(u8, v);
    }
    cfg.max_turns = parseUintField(data, "max_turns");
    cfg.verbose = parseBoolField(data, "verbose");
    cfg.no_theme = parseBoolField(data, "no_theme");
    return cfg;
}

fn parseUintField(data: []const u8, field: []const u8) ?u32 {
    var buf: [128]u8 = undefined;
    if (field.len > 100) return null;
    buf[0] = '"';
    @memcpy(buf[1..][0..field.len], field);
    buf[1 + field.len] = '"';
    buf[2 + field.len] = ':';
    const pattern = buf[0 .. 3 + field.len];
    const idx = std.mem.indexOf(u8, data, pattern) orelse return null;
    var start = idx + pattern.len;
    while (start < data.len and data[start] == ' ') : (start += 1) {}
    var end = start;
    while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(u32, data[start..end], 10) catch null;
}

fn parseBoolField(data: []const u8, field: []const u8) ?bool {
    var buf: [128]u8 = undefined;
    if (field.len > 100) return null;
    buf[0] = '"';
    @memcpy(buf[1..][0..field.len], field);
    buf[1 + field.len] = '"';
    buf[2 + field.len] = ':';
    const pattern = buf[0 .. 3 + field.len];
    const idx = std.mem.indexOf(u8, data, pattern) orelse return null;
    var start = idx + pattern.len;
    while (start < data.len and data[start] == ' ') : (start += 1) {}
    if (start >= data.len) return null;
    if (std.mem.startsWith(u8, data[start..], "true")) return true;
    if (std.mem.startsWith(u8, data[start..], "false")) return false;
    return null;
}

fn homePath(allocator: std.mem.Allocator) ![]u8 {
    const home = @import("platform").paths.homeDir() orelse return error.NoHome; // HOME / Windows USERPROFILE
    return std.fmt.allocPrint(allocator, "{s}/.metacodes/config.json", .{home});
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "FileConfig: load missing file returns empty" {
    const cfg = try loadFromFile(testing.allocator, "/tmp/cc-zig-nonexistent-config-xxxxx.json");
    try testing.expect(cfg.model == null);
    try testing.expect(cfg.max_turns == null);
}

test "FileConfig: save + load roundtrip" {
    const path = "/tmp/cc-zig-config-roundtrip.json";
    defer _ = std.c.unlink(path);

    const src = FileConfig{
        .model = "claude-test",
        .permission_mode = "auto",
        .max_turns = 25,
        .verbose = true,
        .no_theme = false,
    };
    try saveToFile(src, testing.allocator, path);

    const loaded = try loadFromFile(testing.allocator, path);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqualStrings("claude-test", loaded.model.?);
    try testing.expectEqualStrings("auto", loaded.permission_mode.?);
    try testing.expect(loaded.max_turns.? == 25);
    try testing.expect(loaded.verbose.? == true);
    try testing.expect(loaded.no_theme.? == false);
}

test "FileConfig: partial fields" {
    const path = "/tmp/cc-zig-config-partial.json";
    defer _ = std.c.unlink(path);
    const src = FileConfig{ .model = "only-model" };
    try saveToFile(src, testing.allocator, path);
    const loaded = try loadFromFile(testing.allocator, path);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqualStrings("only-model", loaded.model.?);
    try testing.expect(loaded.permission_mode == null);
    try testing.expect(loaded.max_turns == null);
}

test "FileConfig: parseJson handles formatted JSON" {
    // 严格紧凑格式（无空格）——我们自己 save 的也是这种
    const data = "{\"model\":\"formatted\",\"max_turns\":7,\"verbose\":false}";
    const cfg = try parseJson(testing.allocator, data);
    defer cfg.deinit(testing.allocator);
    try testing.expectEqualStrings("formatted", cfg.model.?);
    try testing.expect(cfg.max_turns.? == 7);
    try testing.expect(cfg.verbose.? == false);
}

test "saving preserves keys owned by other writers" {
    const a = std.testing.allocator;
    const path = "/tmp/metacodes-config-preserve-test.json";
    const path_z: [:0]const u8 = path;
    defer _ = pfs.unlinkPath(path_z) catch {};

    {
        const fd = pfs.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = pfs.close(fd);
        const existing =
            \\{"model":"old","mcp_servers":[{"name":"kg"}],"permission_rules":[{"tool":"Bash"}],
            \\ "schema_version":1,"providers":{"metask":{"enabled":true}}}
        ;
        _ = pfs.write(fd, existing);
    }

    try saveToFile(.{ .model = "glm-4.6", .verbose = true }, a, path);

    const written = try readWhole(a, path_z);
    defer a.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "glm-4.6") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"old\"") == null);
    // Every other owner's data survived the write.
    for ([_][]const u8{ "mcp_servers", "permission_rules", "schema_version", "providers", "metask" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, written, needle) != null);
    }

    const reloaded = try loadFromFile(a, path);
    defer reloaded.deinit(a);
    try std.testing.expectEqualStrings("glm-4.6", reloaded.model.?);
    try std.testing.expectEqual(@as(?bool, true), reloaded.verbose);
}

test "a malformed existing document is never silently overwritten" {
    const a = std.testing.allocator;
    const path = "/tmp/metacodes-config-malformed-test.json";
    const path_z: [:0]const u8 = path;
    defer _ = pfs.unlinkPath(path_z) catch {};
    {
        const fd = pfs.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = pfs.close(fd);
        _ = pfs.write(fd, "{ this is not json");
    }
    try std.testing.expectError(error.MalformedExistingConfig, saveToFile(.{ .model = "x" }, a, path));
    const untouched = try readWhole(a, path_z);
    defer a.free(untouched);
    try std.testing.expectEqualStrings("{ this is not json", untouched);
}

test "an unreadable existing document is never treated as empty" {
    const a = std.testing.allocator;
    // A directory in place of the config file makes `open` fail with something
    // other than ENOENT, which must not be read as "no configuration yet".
    const dir_path = "/tmp/metacodes-config-unreadable-test";
    const dir_z: [:0]const u8 = dir_path;
    _ = std.c.mkdir(dir_z.ptr, 0o700);
    defer _ = std.c.rmdir(dir_z.ptr);

    try std.testing.expectError(error.ConfigUnreadable, readWhole(a, dir_z));
    try std.testing.expectError(error.ConfigUnreadable, saveToFile(.{ .model = "x" }, a, dir_path));
}
