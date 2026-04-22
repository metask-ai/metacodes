//! 模型能力发现（model catalog）：启动时 `GET <base_url>/v1/models` 建 model → max_tokens map。
//!
//! 优先级（高到低）：
//!   1. 用户 CLI `--max-tokens N`（在 Config.max_tokens）
//!   2. 目标 base URL 的 `/v1/models` 返回的 max_tokens 字段（本模块缓存）
//!   3. util/model.zig 的本地兜底表（按模型前缀）
//!   4. util/model.zig 的 DEFAULT_MAX_TOKENS (16384)
//!
//! 为什么做动态探测：
//! - sglang-proxy 等自建 proxy 返回扩展字段 `max_tokens`（非 Anthropic 官方格式，
//!   但很多 proxy 都支持；napi 代理返空）
//! - 比本地写死的表更准——不同部署的 max_tokens 不一样
//!
//! 探测失败不报错，直接走 fallback。网络问题、proxy 不支持 /v1/models、返回格式
//! 不含 max_tokens 字段——全部容忍。
//!
//! 调用方式：
//!   var catalog = Catalog.init(allocator);
//!   defer catalog.deinit();
//!   catalog.probe(&client) catch {}; // 失败无所谓
//!   const mt = catalog.maxTokensFor("claude-sonnet-4-6", null); // 可选 CLI override

const std = @import("std");
const json_mod = @import("../json.zig");
const model_fallback = @import("../util/model.zig");
const log = @import("../util/log.zig");

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    /// model_id → {max_tokens, max_input_tokens}。entry 里的 string 由 allocator 拥有。
    entries: std.ArrayList(Entry),

    pub const Entry = struct {
        model_id: []u8,
        max_tokens: u32, // 单次请求可生成的 output tokens 上限
        max_input_tokens: u32, // context window（input 上限）
    };

    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{ .allocator = allocator, .entries = .empty };
    }

    pub fn deinit(self: *Catalog) void {
        for (self.entries.items) |e| self.allocator.free(e.model_id);
        self.entries.deinit(self.allocator);
    }

    /// 解析 `/v1/models` 响应 JSON，把 max_tokens 字段存入。
    /// 安全：不合法/缺字段直接忽略该条；全失败也不报错（只 debug 日志）。
    pub fn loadFromModelsListJson(self: *Catalog, json_body: []const u8) !void {
        // 响应结构：`{"data":[{"id":"...","max_tokens":12345, ...}, ...]}`
        const data_arr = findObjectField(json_body, "data") orelse {
            log.debug("catalog", "no 'data' field in /v1/models response", .{});
            return;
        };

        var pos: usize = 1; // 跳开头 '['
        while (pos < data_arr.len) {
            while (pos < data_arr.len and (data_arr[pos] == ' ' or data_arr[pos] == ',')) : (pos += 1) {}
            if (pos >= data_arr.len or data_arr[pos] != '{') break;
            const obj_end = findObjectEnd(data_arr, pos) orelse break;
            const obj = data_arr[pos..obj_end];
            pos = obj_end;

            const id = extractStringField(obj, "id") orelse continue;
            const mt = extractUintField(obj, "max_tokens") orelse {
                // 没有 max_tokens 字段（如 Anthropic 官方 / napi 代理）——跳过
                continue;
            };
            // max_input_tokens 可选，缺失时用保守默认 200K（Claude 标准 context window）
            const mit = extractUintField(obj, "max_input_tokens") orelse 200_000;

            const id_owned = try self.allocator.dupe(u8, id);
            errdefer self.allocator.free(id_owned);
            try self.entries.append(self.allocator, .{
                .model_id = id_owned,
                .max_tokens = @intCast(mt),
                .max_input_tokens = @intCast(mit),
            });
            log.debug("catalog", "model {s}: max_tokens={d} max_input_tokens={d}", .{ id, mt, mit });
        }
        log.info("catalog", "loaded {d} model entries from /v1/models", .{self.entries.items.len});
    }

    /// 返回合适的 max_tokens。
    /// user_override != null → 直接用用户 CLI 值
    /// 否则查 catalog；没命中 → 查本地 fallback 表；全没中 → 默认
    pub fn maxTokensFor(self: *const Catalog, model: []const u8, user_override: ?u32) u32 {
        if (user_override) |v| return v;
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.model_id, model)) return e.max_tokens;
        }
        return model_fallback.maxOutputTokens(model);
    }
};

// --- JSON 辅助 ---

fn findObjectField(data: []const u8, field: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (field.len > 200) return null;
    buf[0] = '"';
    @memcpy(buf[1..][0..field.len], field);
    buf[1 + field.len] = '"';
    buf[2 + field.len] = ':';
    const pat = buf[0 .. 3 + field.len];
    const idx = std.mem.indexOf(u8, data, pat) orelse return null;
    var pos = idx + pat.len;
    while (pos < data.len and data[pos] == ' ') : (pos += 1) {}
    if (pos >= data.len) return null;
    const open = data[pos];
    const close: u8 = switch (open) {
        '{' => '}',
        '[' => ']',
        else => return null,
    };
    var depth: i32 = 0;
    var in_str = false;
    var esc = false;
    var i = pos;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (esc) {
            esc = false;
            continue;
        }
        if (c == '\\') {
            esc = true;
            continue;
        }
        if (c == '"') {
            in_str = !in_str;
            continue;
        }
        if (in_str) continue;
        if (c == open) depth += 1;
        if (c == close) {
            depth -= 1;
            if (depth == 0) return data[pos .. i + 1];
        }
    }
    return null;
}

fn findObjectEnd(data: []const u8, start: usize) ?usize {
    if (start >= data.len or data[start] != '{') return null;
    var depth: i32 = 0;
    var in_str = false;
    var esc = false;
    var i = start;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (esc) {
            esc = false;
            continue;
        }
        if (c == '\\') {
            esc = true;
            continue;
        }
        if (c == '"') {
            in_str = !in_str;
            continue;
        }
        if (in_str) continue;
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return null;
}

fn extractStringField(data: []const u8, field: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (field.len > 200) return null;
    buf[0] = '"';
    @memcpy(buf[1..][0..field.len], field);
    buf[1 + field.len] = '"';
    buf[2 + field.len] = ':';
    buf[3 + field.len] = '"';
    const pat = buf[0 .. 4 + field.len];
    const idx = std.mem.indexOf(u8, data, pat) orelse return null;
    const s = idx + pat.len;
    var e = s;
    while (e < data.len) : (e += 1) {
        if (data[e] == '"' and data[e - 1] != '\\') break;
    }
    return data[s..e];
}

fn extractUintField(data: []const u8, field: []const u8) ?u64 {
    var buf: [256]u8 = undefined;
    if (field.len > 200) return null;
    buf[0] = '"';
    @memcpy(buf[1..][0..field.len], field);
    buf[1 + field.len] = '"';
    buf[2 + field.len] = ':';
    const pat = buf[0 .. 3 + field.len];
    const idx = std.mem.indexOf(u8, data, pat) orelse return null;
    var start = idx + pat.len;
    while (start < data.len and data[start] == ' ') : (start += 1) {}
    var end = start;
    while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(u64, data[start..end], 10) catch null;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Catalog: loadFromModelsListJson with sglang-proxy format" {
    // 紧凑 JSON（不带空格/换行）—— findObjectField/extractUintField 不处理中间空白
    const sample = "{\"data\":[{\"id\":\"claude-sonnet-4-6\",\"type\":\"model\",\"max_tokens\":64000,\"display_name\":\"Sonnet 4.6\"},{\"id\":\"claude-opus-4-6\",\"type\":\"model\",\"max_tokens\":128000,\"display_name\":\"Opus\"}],\"has_more\":false}";
    var c = Catalog.init(testing.allocator);
    defer c.deinit();
    try c.loadFromModelsListJson(sample);
    try testing.expect(c.entries.items.len == 2);
    try testing.expect(c.maxTokensFor("claude-sonnet-4-6", null) == 64000);
    try testing.expect(c.maxTokensFor("claude-opus-4-6", null) == 128000);
}

test "Catalog: user override beats catalog" {
    var c = Catalog.init(testing.allocator);
    defer c.deinit();
    try c.loadFromModelsListJson("{\"data\":[{\"id\":\"x\",\"max_tokens\":1000}]}");
    try testing.expect(c.maxTokensFor("x", 500) == 500);
}

test "Catalog: unknown model falls back to local table" {
    var c = Catalog.init(testing.allocator);
    defer c.deinit();
    // 空 catalog
    const r = c.maxTokensFor("claude-sonnet-4-20250514", null);
    try testing.expect(r == 32_000); // util/model.zig 的 sonnet-4 default
}

test "Catalog: completely unknown falls back to DEFAULT" {
    var c = Catalog.init(testing.allocator);
    defer c.deinit();
    const r = c.maxTokensFor("unknown-model", null);
    try testing.expect(r == model_fallback.DEFAULT_MAX_TOKENS);
}

test "Catalog: napi-style response without max_tokens field skipped" {
    // napi 代理返回格式：无 max_tokens 字段
    const sample = "{\"data\":[{\"id\":\"claude-sonnet-4-6\",\"type\":\"model\",\"display_name\":\"X\"}]}";
    var c = Catalog.init(testing.allocator);
    defer c.deinit();
    try c.loadFromModelsListJson(sample);
    try testing.expect(c.entries.items.len == 0); // 没 max_tokens 字段的条目被跳过
    // 查询仍有兜底（util/model.zig 的 claude-sonnet-4-6 default = 32000）
    try testing.expect(c.maxTokensFor("claude-sonnet-4-6", null) == 32_000);
}

test "Catalog: empty/invalid json no crash" {
    var c = Catalog.init(testing.allocator);
    defer c.deinit();
    try c.loadFromModelsListJson("not json");
    try c.loadFromModelsListJson("");
    try c.loadFromModelsListJson("{}");
    try testing.expect(c.entries.items.len == 0);
}
