//! 模型上下文窗口表(auto-compact 阈值用)。
//!
//! 源自 models.dev,精简成 ~/.metacodes/models.toml(极简 TOML:`[models]` 段 + `"key" = N`)。
//! 首次运行若文件缺失,把 bundled 默认(model_context_default.toml,@embedFile)写到该路径,
//! 并直接解析 embedded bytes(避免读盘竞态)。
//!
//! 查找:exact 优先,再 substring(长 key 优先,防 "gpt-4" 盖 "gpt-4o")。
//! precedence(见 client.resolveMaxInputTokens):本表命中 > /v1/models probe > 200K 默认。

const std = @import("std");
const pfs = @import("platform").fs;
const log = @import("../util/log.zig");
const model_name = @import("../api/model_name.zig");

const BUNDLED = @embedFile("model_context_default.toml");

pub const ModelContext = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct {
        key: []u8, // owned
        window: u32,
    };

    pub fn init(allocator: std.mem.Allocator) ModelContext {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ModelContext) void {
        for (self.entries.items) |e| self.allocator.free(e.key);
        self.entries.deinit(self.allocator);
    }

    /// 加载 ~/.metacodes/models.toml;缺则写 bundled 默认 + 解析 embedded。
    /// best-effort:任何 IO 失败都退回解析 embedded(保证表非空)。用 std.c syscall(裁剪 std 无 std.fs.cwd)。
    pub fn loadOrBundle(self: *ModelContext) void {
        const home = @import("platform").paths.homeDir() orelse { // HOME / Windows USERPROFILE
            self.parse(BUNDLED);
            return;
        };
        const dir = std.fmt.allocPrint(self.allocator, "{s}/.metacodes", .{home}) catch {
            self.parse(BUNDLED);
            return;
        };
        defer self.allocator.free(dir);
        const path = std.fmt.allocPrint(self.allocator, "{s}/models.toml", .{home}) catch {
            self.parse(BUNDLED);
            return;
        };
        // 注意:path 用 .metacodes/models.toml,上面 allocPrint 漏了子目录,下面重算。
        self.allocator.free(path);
        const full = std.fmt.allocPrint(self.allocator, "{s}/.metacodes/models.toml", .{home}) catch {
            self.parse(BUNDLED);
            return;
        };
        defer self.allocator.free(full);

        // 读现有文件;成功则解析它。
        if (self.readFileBytes(full)) |bytes| {
            defer self.allocator.free(bytes);
            self.parse(bytes);
            return;
        }

        // 缺失:best-effort 写 bundled(mkdir + write),然后解析 embedded(不依赖写成功)。
        self.writeFileBytes(dir, full, BUNDLED);
        self.parse(BUNDLED);
    }

    /// 读整文件到 owned slice(裁剪 std,std.c.open/read)。失败/不存在返 null。
    fn readFileBytes(self: *ModelContext, path: []const u8) ?[]u8 {
        const path_z = self.allocator.dupeZ(u8, path) catch return null;
        defer self.allocator.free(path_z);
        const fd = pfs.open(path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return null;
        defer _ = pfs.close(fd);
        var buf: [4096]u8 = undefined;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        while (true) {
            const n = pfs.read(fd, &buf);
            if (n <= 0) break;
            out.appendSlice(self.allocator, buf[0..@as(usize, @intCast(n))]) catch {
                out.deinit(self.allocator);
                return null;
            };
        }
        return out.toOwnedSlice(self.allocator) catch null;
    }

    /// best-effort 写 bundled(mkdir dir + 覆盖写 path)。失败静默。
    fn writeFileBytes(self: *ModelContext, dir: []const u8, path: []const u8, bytes: []const u8) void {
        const dir_z = self.allocator.dupeZ(u8, dir) catch return;
        defer self.allocator.free(dir_z);
        _ = std.c.mkdir(dir_z, 0o700);
        const path_z = self.allocator.dupeZ(u8, path) catch return;
        defer self.allocator.free(path_z);
        const fd = pfs.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) return;
        defer _ = pfs.close(fd);
        _ = pfs.write(fd, bytes);
        log.info("model_ctx", "wrote default model context table to {s}", .{path});
    }

    /// 极简 TOML 解析:`# 注释` / 空行 / `[section]`(只认 [models]) / `"key" = 12345`。
    pub fn parse(self: *ModelContext, source: []const u8) void {
        var in_models = false;
        var it = std.mem.splitScalar(u8, source, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                const sec = std.mem.trim(u8, line, "[]");
                in_models = std.mem.eql(u8, sec, "models");
                continue;
            }
            if (!in_models) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, std.mem.trim(u8, line[0..eq], " \t"), "\"");
            if (key.len == 0) continue;
            const val_str = std.mem.trim(u8, line[eq + 1 ..], " \t");
            const window = std.fmt.parseInt(u32, val_str, 10) catch continue;
            const key_owned = self.allocator.dupe(u8, key) catch continue;
            self.entries.append(self.allocator, .{ .key = key_owned, .window = window }) catch {
                self.allocator.free(key_owned);
            };
        }
    }

    /// 查 model 的上下文窗口。exact 优先;再 substring(命中 model 含该 key,长 key 优先)。
    /// 无命中返 null(调用方落 catalog/默认)。
    pub fn windowFor(self: *const ModelContext, model: []const u8) ?u32 {
        // exact 优先。
        for (self.entries.items) |e| {
            if (model_name.eqlIgnoreCase(e.key, model)) return e.window;
        }
        // substring:model 含 key;多个命中取最长 key(最具体)。
        var best: ?u32 = null;
        var best_len: usize = 0;
        for (self.entries.items) |e| {
            if (model_name.containsIgnoreCase(model, e.key) and e.key.len > best_len) {
                best = e.window;
                best_len = e.key.len;
            }
        }
        return best;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "TOML 解析 + windowFor exact/substring" {
    var mc = ModelContext.init(testing.allocator);
    defer mc.deinit();
    mc.parse(
        \\# comment
        \\[other]
        \\"ignored" = 999
        \\[models]
        \\"claude-opus-4-6" = 1000000
        \\"opus" = 200000
        \\"gpt-4o" = 128000
        \\"gpt-4" = 8192
        \\
    );
    // exact 命中。
    try testing.expectEqual(@as(?u32, 1000000), mc.windowFor("claude-opus-4-6"));
    // substring + 长 key 优先:含 "claude-opus-4-6" 取 1M 而非 "opus"。
    try testing.expectEqual(@as(?u32, 1000000), mc.windowFor("claude-opus-4-6-20991231"));
    // 只含 "opus"。
    try testing.expectEqual(@as(?u32, 200000), mc.windowFor("claude-opus-3"));
    // 长 key 防盖:gpt-4o-2024 含 gpt-4o(6) 和 gpt-4(5)→ 取 gpt-4o。
    try testing.expectEqual(@as(?u32, 128000), mc.windowFor("gpt-4o-2024-08"));
    // [other] 段被忽略。
    try testing.expectEqual(@as(?u32, null), mc.windowFor("ignored"));
    // 无命中。
    try testing.expectEqual(@as(?u32, null), mc.windowFor("llama-3"));
}

test "bundled 默认可解析且含主力模型" {
    var mc = ModelContext.init(testing.allocator);
    defer mc.deinit();
    mc.parse(BUNDLED);
    try testing.expect(mc.entries.items.len > 5);
    // opus-4-8 = 1M(用户主模型)。
    try testing.expectEqual(@as(?u32, 1000000), mc.windowFor("claude-opus-4-8"));
    // sonnet-4(20250514)= 200K。
    try testing.expectEqual(@as(?u32, 200000), mc.windowFor("claude-sonnet-4-20250514"));
}

test "容错:畸形行 + 空表 windowFor null" {
    var mc = ModelContext.init(testing.allocator);
    defer mc.deinit();
    mc.parse("[models]\ngarbage line no equals\n\"k\" = notanumber\n\"valid\" = 100\n");
    try testing.expectEqual(@as(?u32, 100), mc.windowFor("valid"));
    try testing.expectEqual(@as(?u32, null), mc.windowFor("k"));
}
