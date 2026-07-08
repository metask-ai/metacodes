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
const util_json = @import("../util/json.zig");

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

/// 从 ~/.metacodes/config.json 加载。文件不存在返回全默认（null 字段）。
pub fn loadFromHome(allocator: std.mem.Allocator) !FileConfig {
    const path = try homePath(allocator);
    defer allocator.free(path);
    return loadFromFile(allocator, path);
}

pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !FileConfig {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = std.c.open(path_z, std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return .{}; // 不存在 = 空配置

    defer _ = std.c.close(fd);

    var buf: [16384]u8 = undefined;
    var contents = std.ArrayList(u8).empty;
    defer contents.deinit(allocator);

    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
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

    const fd = std.c.open(path_z, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.WriteError;
    defer _ = std.c.close(fd);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.append(allocator, '{');
    var first = true;
    if (config.model) |v| {
        if (!first) try out.append(allocator, ',');
        first = false;
        try out.appendSlice(allocator, "\"model\":");
        try util_json.serializeString(v, &out, allocator);
    }
    if (config.permission_mode) |v| {
        if (!first) try out.append(allocator, ',');
        first = false;
        try out.appendSlice(allocator, "\"permission_mode\":");
        try util_json.serializeString(v, &out, allocator);
    }
    if (config.max_turns) |v| {
        if (!first) try out.append(allocator, ',');
        first = false;
        const s = try std.fmt.allocPrint(allocator, "\"max_turns\":{d}", .{v});
        defer allocator.free(s);
        try out.appendSlice(allocator, s);
    }
    if (config.verbose) |v| {
        if (!first) try out.append(allocator, ',');
        first = false;
        try out.appendSlice(allocator, "\"verbose\":");
        try out.appendSlice(allocator, if (v) "true" else "false");
    }
    if (config.no_theme) |v| {
        if (!first) try out.append(allocator, ',');
        first = false;
        try out.appendSlice(allocator, "\"no_theme\":");
        try out.appendSlice(allocator, if (v) "true" else "false");
    }
    try out.append(allocator, '}');

    _ = std.c.write(fd, out.items.ptr, out.items.len);
    _ = std.c.fsync(fd);
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
    const home_c = std.c.getenv("HOME") orelse return error.NoHome;
    const home = std.mem.span(home_c);
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
