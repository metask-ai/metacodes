//! 模型能力发现（model catalog）：启动时 `GET <base_url>/v1/models` 建 model → {max_tokens, max_input_tokens} map。
//!
//! 两类数值各自独立解析、独立 fallback（字段解耦）：
//!   - max_tokens      = output 上限。优先级：CLI `--max-tokens` > catalog > util/model.zig 兜底表 > DEFAULT(16384)
//!   - max_input_tokens = input 上限(context window)。优先级：catalog > 默认 200K。auto-compact 阈值用它。
//!
//! 为什么做动态探测：
//! - 后端(自建 proxy / 官方端点)返回 `max_tokens` / `max_input_tokens`，比本地写死的表更准。
//! - Anthropic 官方 /v1/models 的 `max_input_tokens` 语义即"Maximum input context window size"。
//!
//! 容错：探测失败、proxy 不支持 /v1/models、字段缺失或为占位 0——全部容忍，各字段走 fallback。
//! 关键：只要 entry 有 `id` 就建立，绝不因某个数值字段缺失而整条丢弃(历史 bug，见
//! loadFromModelsListJson 注释)。
//!
//! 调用方式：
//!   var catalog = Catalog.init(allocator);
//!   defer catalog.deinit();
//!   catalog.probe(&client) catch {}; // 失败无所谓
//!   const mt = catalog.maxTokensFor("claude-sonnet-4-6", null); // 可选 CLI override
//!   const cw = catalog.maxInputTokensFor("claude-sonnet-4-6");  // context window

const std = @import("std");
const json_mod = @import("../json.zig");
const model_fallback = @import("../util/model.zig");
const log = @import("../util/log.zig");
const types = @import("../types.zig");
const model_name = @import("model_name.zig");

/// 顶档(内部 `.xhigh`)在某条路由上的叫法。neutral = 目录没说、或用 OpenAI 词汇 xhigh。
pub const EffortVocabulary = enum { neutral, max };

/// 给人看的档位标签:顶档按路由词汇,其余档位各家叫法一致。
pub fn effortLabel(vocabulary: EffortVocabulary, effort: types.ReasoningEffort) []const u8 {
    return switch (effort) {
        .xhigh => switch (vocabulary) {
            .max => "max",
            .neutral => effort.name(),
        },
        else => effort.name(),
    };
}

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    /// model_id → {max_tokens, max_input_tokens}。entry 里的 string 由 allocator 拥有。
    entries: std.ArrayList(Entry),
    /// Each materially narrow user override is warned once per catalog. The
    /// atomic keeps the read-only lookup API safe when providers share a
    /// catalog across worker threads.
    narrow_override_warning_emitted: std.atomic.Value(bool) = .init(false),

    pub const Entry = struct {
        model_id: []u8,
        // 两个字段独立可选——解耦：后端可能只返回其中一个。
        // null = 后端未给该字段 → 查询时各自走 fallback，互不牵连。
        max_tokens: ?u32, // 单次请求可生成的 output tokens 上限
        max_input_tokens: ?u32, // context window（input 上限）
        reasoning_mask: u8 = 0,
        /// `capabilities.image_input.supported`:后端对**这条路由上这个模型**是否收图的
        /// 声明。null = 后端没说(走 model_adapter 的家族表);true/false = 后端说了算——
        /// 目录是路由的事实,家族表只是离线兜底(issue #112:同一个模型名在不同路由上
        /// 能力不同,名字猜不出来)。
        image_input: ?bool = null,
        /// 目录声明顶档用的词汇:`capabilities.effort` 里有 "max" 而没有 "xhigh" → 这条路由把
        /// 最高档叫 max(Anthropic 官方 / Metask 网关 / GLM / Kimi / DeepSeek 的叫法)。内部
        /// 枚举仍是中立的 `.xhigh`,只有给人看的标签跟着目录走——用户在 picker 里看到的
        /// 必须是 provider 自己的词。
        effort_vocabulary: EffortVocabulary = .neutral,

        pub fn supportsReasoning(self: Entry, effort: types.ReasoningEffort) bool {
            return (self.reasoning_mask & reasoningBit(effort)) != 0;
        }
    };

    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{ .allocator = allocator, .entries = .empty };
    }

    pub fn clone(self: *const Catalog, allocator: std.mem.Allocator) !Catalog {
        var copy = Catalog.init(allocator);
        errdefer copy.deinit();
        for (self.entries.items) |entry| {
            const id = try allocator.dupe(u8, entry.model_id);
            errdefer allocator.free(id);
            try copy.entries.append(allocator, .{ .model_id = id, .max_tokens = entry.max_tokens, .max_input_tokens = entry.max_input_tokens, .reasoning_mask = entry.reasoning_mask, .image_input = entry.image_input, .effort_vocabulary = entry.effort_vocabulary });
        }
        return copy;
    }

    pub fn deinit(self: *Catalog) void {
        for (self.entries.items) |e| self.allocator.free(e.model_id);
        self.entries.deinit(self.allocator);
    }

    /// 解析 `/v1/models` 响应 JSON，把 max_tokens / max_input_tokens 字段存入。
    /// 安全：不合法/缺字段直接忽略该条；全失败也不报错（只 debug 日志）。
    ///
    /// 字段解耦：只要有 `id` 就建 entry。max_tokens 与 max_input_tokens 各自独立——
    /// 缺哪个就存 null，查询时该字段单独走 fallback，不会因为另一个缺失而整条丢弃。
    /// （历史 bug：曾把 max_tokens 当必需字段，缺失即 `continue` 跳过整条，
    ///  连带丢掉同条的 max_input_tokens → context window 永远拿不到 → auto-compact 过早触发。）
    pub fn loadFromModelsListJson(self: *Catalog, json_body: []const u8) !void {
        // 响应结构：`{"data":[{"id":"...","max_tokens":12345, ...}, ...]}`
        const data_arr = findObjectField(json_body, "data") orelse {
            log.debug("catalog", "no 'data' field in /v1/models response", .{});
            return;
        };

        var pos: usize = 1; // 跳开头 '['
        while (pos < data_arr.len) {
            while (pos < data_arr.len and (isJsonWs(data_arr[pos]) or data_arr[pos] == ',')) : (pos += 1) {}
            if (pos >= data_arr.len or data_arr[pos] != '{') break;
            const obj_end = findObjectEnd(data_arr, pos) orelse break;
            const obj = data_arr[pos..obj_end];
            pos = obj_end;

            const id = extractStringField(obj, "id") orelse continue;
            // 两个数值字段都可选、各自独立。后端返回非正值(0/负)等同未给——避免
            // `max_input_tokens: 0` 这类占位值被当成"上下文为 0"(对齐 Anthropic 官方
            // /v1/models 文档示例里 max_input_tokens 常为占位 0 的情况)。
            const mt = nonZero(extractUintField(obj, "max_tokens"));
            const mit = nonZero(extractUintField(obj, "max_input_tokens"));
            const reasoning_mask = extractReasoningMask(obj);
            const effort_vocabulary = extractEffortVocabulary(obj);
            const image_input = extractImageInput(obj);

            const id_owned = try self.allocator.dupe(u8, id);
            errdefer self.allocator.free(id_owned);
            try self.entries.append(self.allocator, .{
                .model_id = id_owned,
                .max_tokens = mt,
                .max_input_tokens = mit,
                .reasoning_mask = reasoning_mask,
                .image_input = image_input,
                .effort_vocabulary = effort_vocabulary,
            });
            log.debug("catalog", "model {s}: max_tokens={?d} max_input_tokens={?d} image_input={?}", .{ id, mt, mit, image_input });
        }
        log.info("catalog", "loaded {d} model entries from /v1/models", .{self.entries.items.len});
    }

    /// 返回合适的 max_tokens。
    /// user_override != null → 直接用用户 CLI 值
    /// 否则查 catalog（命中且字段非 null）；缺失 → 查本地 fallback 表；全没中 → 默认
    pub fn maxTokensFor(self: *const Catalog, model: []const u8, user_override: ?u32) u32 {
        if (user_override) |v| {
            for (self.entries.items) |e| {
                if (!model_name.eqlIgnoreCase(e.model_id, model)) continue;
                if (e.max_tokens) |catalog_value| {
                    if (@as(u64, v) * 2 < @as(u64, catalog_value) and
                        @constCast(&self.narrow_override_warning_emitted).cmpxchgStrong(false, true, .acq_rel, .acquire) == null)
                    {
                        log.warn("catalog", "max_tokens override {d} is materially below catalog value {d} for model {s}", .{ v, catalog_value, model });
                    }
                }
                break;
            }
            return v;
        }
        for (self.entries.items) |e| {
            if (model_name.eqlIgnoreCase(e.model_id, model)) {
                if (e.max_tokens) |v| return v;
                break; // 命中 entry 但后端没给 max_tokens → 走 fallback
            }
        }
        return model_fallback.maxOutputTokens(model);
    }

    /// 返回 model 的 input context window(用于 auto-compact 阈值)。
    /// 查 catalog 的 max_input_tokens(命中且非 null);缺失 → 保守默认 200K(Claude 标准 context window)。
    /// 注意:这是 **input 上限**,与 maxTokensFor(output 上限)是两回事——auto-compact 该用本函数。
    pub fn maxInputTokensFor(self: *const Catalog, model: []const u8) u32 {
        for (self.entries.items) |e| {
            if (model_name.eqlIgnoreCase(e.model_id, model)) {
                if (e.max_input_tokens) |v| return v;
                break; // 命中 entry 但后端没给 max_input_tokens → 走默认
            }
        }
        return 200_000;
    }

    pub fn reasoningMaskFor(self: *const Catalog, model: []const u8) u8 {
        for (self.entries.items) |e| {
            if (model_name.eqlIgnoreCase(e.model_id, model)) return e.reasoning_mask;
        }
        return 0;
    }

    /// `model` 在这条路由上的档位标签(顶档按目录词汇);目录里没有这个模型 → 中立名。
    pub fn effortLabelFor(self: *const Catalog, model: []const u8, effort: types.ReasoningEffort) []const u8 {
        for (self.entries.items) |e| {
            if (model_name.eqlIgnoreCase(e.model_id, model)) return effortLabel(e.effort_vocabulary, effort);
        }
        return effort.name();
    }

    /// 后端目录对 `model` 的 image_input 声明。null = 目录里没有这个模型、或有但没声明
    /// → 调用方回退家族表(model_adapter.profileFor)。命中 true/false 时目录说了算。
    pub fn imageInputFor(self: *const Catalog, model: []const u8) ?bool {
        for (self.entries.items) |e| {
            if (model_name.eqlIgnoreCase(e.model_id, model)) return e.image_input;
        }
        return null;
    }

    /// 目录里声明 `image_input.supported=true` 的模型名(借用 catalog 内存,调用方不释放)。
    /// 供 Read 图片门控在报错时告诉模型"这条路由上谁能看图"。
    pub fn visionModels(self: *const Catalog, allocator: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(allocator);
        for (self.entries.items) |e| {
            if (e.image_input == true) try out.append(allocator, e.model_id);
        }
        return try out.toOwnedSlice(allocator);
    }
};

test "Catalog.clone deep-copies model identifiers" {
    var original = Catalog.init(std.testing.allocator);
    defer original.deinit();
    try original.loadFromModelsListJson("{\"data\":[{\"id\":\"GLM-5.2\",\"max_tokens\":64000,\"max_input_tokens\":1048576}]} ");
    var copy = try original.clone(std.testing.allocator);
    defer copy.deinit();
    original.entries.items[0].model_id[0] = 'X';
    try std.testing.expectEqualStrings("GLM-5.2", copy.entries.items[0].model_id);
    try std.testing.expectEqual(@as(u32, 64000), copy.maxTokensFor("glm-5.2", null));
}

pub fn reasoningBit(effort: types.ReasoningEffort) u8 {
    return switch (effort) {
        .none => 1 << 0,
        .minimal => 1 << 1,
        .low => 1 << 2,
        .medium => 1 << 3,
        .high => 1 << 4,
        .xhigh => 1 << 5,
    };
}

pub fn defaultReasoningForMask(mask: u8) ?types.ReasoningEffort {
    const ordered = [_]types.ReasoningEffort{ .low, .medium, .high, .xhigh };
    var supported: [4]types.ReasoningEffort = undefined;
    var n: usize = 0;
    for (ordered) |effort| {
        if ((mask & reasoningBit(effort)) != 0) {
            supported[n] = effort;
            n += 1;
        }
    }
    if (n == 0) return null;
    return supported[(n - 1) / 2];
}

/// 把解析结果归一成 `?u32`：缺失或 0(占位值)→ null；超 u32 上限 → 饱和到 maxInt(u32)。
/// 后端用 0 占位的数值字段不应被当成有效值(对齐 Anthropic 官方 /v1/models 示例)。
fn nonZero(v: ?u64) ?u32 {
    if (v) |n| {
        if (n == 0) return null;
        return if (n > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(n);
    }
    return null;
}

fn extractReasoningMask(obj: []const u8) u8 {
    const caps = findObjectField(obj, "capabilities") orelse return 0;
    const effort = findObjectField(caps, "effort") orelse return 0;
    var mask: u8 = 0;
    if (capSupported(effort, "low")) mask |= reasoningBit(.low);
    if (capSupported(effort, "medium")) mask |= reasoningBit(.medium);
    if (capSupported(effort, "high")) mask |= reasoningBit(.high);
    if (capSupported(effort, "max")) mask |= reasoningBit(.xhigh);
    if (capSupported(effort, "xhigh")) mask |= reasoningBit(.xhigh);
    return mask;
}

/// 目录顶档词汇:声明了 xhigh → neutral(OpenAI 叫法);只声明 max → max;都没有 → neutral。
fn extractEffortVocabulary(obj: []const u8) EffortVocabulary {
    const caps = findObjectField(obj, "capabilities") orelse return .neutral;
    const effort = findObjectField(caps, "effort") orelse return .neutral;
    if (capSupported(effort, "xhigh")) return .neutral;
    if (capSupported(effort, "max")) return .max;
    return .neutral;
}

/// `capabilities.image_input.supported` 三态:缺 capabilities / 缺 image_input / 缺
/// supported → null;true/false 按字面。只认布尔字面量,别的形状一律当"没说"。
fn extractImageInput(obj: []const u8) ?bool {
    const caps = findObjectField(obj, "capabilities") orelse return null;
    const image_input = findObjectField(caps, "image_input") orelse return null;
    const value_start = findFieldValueStart(image_input, "supported") orelse return null;
    const rest = image_input[value_start..];
    if (std.mem.startsWith(u8, rest, "true")) return true;
    if (std.mem.startsWith(u8, rest, "false")) return false;
    return null;
}

fn capSupported(effort_obj: []const u8, name: []const u8) bool {
    const cap = findObjectField(effort_obj, name) orelse return false;
    return std.mem.indexOf(u8, cap, "\"supported\":true") != null or
        std.mem.indexOf(u8, cap, "\"supported\": true") != null;
}

// --- JSON 辅助 ---

fn findObjectField(data: []const u8, field: []const u8) ?[]const u8 {
    const pos = findFieldValueStart(data, field) orelse return null;
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
    var s = findFieldValueStart(data, field) orelse return null;
    if (s >= data.len or data[s] != '"') return null;
    s += 1;
    var e = s;
    while (e < data.len) : (e += 1) {
        if (data[e] == '"' and data[e - 1] != '\\') break;
    }
    return data[s..e];
}

fn extractUintField(data: []const u8, field: []const u8) ?u64 {
    const start = findFieldValueStart(data, field) orelse return null;
    var end = start;
    while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(u64, data[start..end], 10) catch null;
}

fn findFieldValueStart(data: []const u8, field: []const u8) ?usize {
    var buf: [256]u8 = undefined;
    if (field.len > 200) return null;
    buf[0] = '"';
    @memcpy(buf[1..][0..field.len], field);
    buf[1 + field.len] = '"';
    const pat = buf[0 .. 2 + field.len];
    const idx = std.mem.indexOf(u8, data, pat) orelse return null;
    var pos = idx + pat.len;
    while (pos < data.len and isJsonWs(data[pos])) : (pos += 1) {}
    if (pos >= data.len or data[pos] != ':') return null;
    pos += 1;
    while (pos < data.len and isJsonWs(data[pos])) : (pos += 1) {}
    return pos;
}

fn isJsonWs(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n' => true,
        else => false,
    };
}

test "catalog parses model list with JSON whitespace" {
    var c = Catalog.init(std.testing.allocator);
    defer c.deinit();
    try c.loadFromModelsListJson(
        \\{
        \\  "data": [
        \\    { "id": "claude-dev-sonnet-20260702", "max_tokens": 8192, "max_input_tokens": 200000 }
        \\  ]
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), c.entries.items.len);
    try std.testing.expectEqualStrings("claude-dev-sonnet-20260702", c.entries.items[0].model_id);
    try std.testing.expectEqual(@as(?u32, 8192), c.entries.items[0].max_tokens);
    try std.testing.expectEqual(@as(?u32, 200000), c.entries.items[0].max_input_tokens);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Catalog: loadFromModelsListJson with sglang-proxy format" {
    // 紧凑 JSON 是 sglang-proxy 常见返回格式。
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

test "Catalog: materially narrow user override warns once and still wins" {
    var c = Catalog.init(testing.allocator);
    defer c.deinit();
    try c.loadFromModelsListJson("{\"data\":[{\"id\":\"x\",\"max_tokens\":1000}]}");

    try testing.expectEqual(@as(u32, 400), c.maxTokensFor("x", 400));
    try testing.expect(c.narrow_override_warning_emitted.load(.acquire));
    try testing.expectEqual(@as(u32, 400), c.maxTokensFor("x", 400));
}

test "Catalog: 非显著偏低的 override 不告警(负例,防条件恒真)" {
    var c = Catalog.init(testing.allocator);
    defer c.deinit();
    try c.loadFromModelsListJson("{\"data\":[{\"id\":\"x\",\"max_tokens\":1000}]}");

    // 600*2 >= 1000 → 不算 materially below,不应告警。
    try testing.expectEqual(@as(u32, 600), c.maxTokensFor("x", 600));
    try testing.expect(!c.narrow_override_warning_emitted.load(.acquire));

    // catalog 没有该 model 的 max_tokens 时,也不应告警。
    try testing.expectEqual(@as(u32, 1), c.maxTokensFor("unknown-model", 1));
    try testing.expect(!c.narrow_override_warning_emitted.load(.acquire));
}

test "Catalog: 端到端——后端只返回 max_input_tokens=1M 时 auto-compact 阈值放大到 800K(非 160K)" {
    // DoD 端到端断言:字段解耦修复的实际收益。
    // 链路:后端返回 max_input_tokens=1M → catalog 采纳 → maxInputTokensFor=1M
    //       → agent_loop 阈值算式 `× 8/10` → 800K(而非 catalog 空时的 200K×0.8=160K)。
    // 这正是 bug 场景:opus-4-8[1m] 实际 1M 上下文,旧实现因 max_tokens 缺失丢弃 entry,
    // context window 退回 200K → 阈值 160K → 读几个文件就过早 compact。
    const sample = "{\"data\":[{\"id\":\"claude-opus-4-8\",\"type\":\"model\",\"max_input_tokens\":1000000}]}";
    var c = Catalog.init(testing.allocator);
    defer c.deinit();
    try c.loadFromModelsListJson(sample);

    const cw = c.maxInputTokensFor("claude-opus-4-8");
    try testing.expect(cw == 1_000_000);

    // 复刻 agent_loop.zig:267 的阈值算式(× 8/10),断言数值收益。
    const threshold: usize = @as(usize, cw) * 8 / 10;
    try testing.expect(threshold == 800_000); // 非旧的 160_000
}

test "Catalog: maxInputTokensFor 用 context window 非 output max_tokens(auto-compact 阈值用)" {
    var c = Catalog.init(testing.allocator);
    defer c.deinit();
    // max_input_tokens 显式给 → 用它(context window);缺失 → 200K 默认。
    try c.loadFromModelsListJson("{\"data\":[{\"id\":\"m1\",\"max_tokens\":32000,\"max_input_tokens\":200000},{\"id\":\"m2\",\"max_tokens\":8192}]}");
    try testing.expect(c.maxInputTokensFor("m1") == 200_000); // 不是 32000
    try testing.expect(c.maxInputTokensFor("m2") == 200_000); // 缺失 → 默认
    try testing.expect(c.maxInputTokensFor("unknown") == 200_000); // 未命中 → 默认
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

test "Catalog: napi-style response without max_tokens still creates entry (字段解耦)" {
    // napi 代理返回格式：无 max_tokens / max_input_tokens 字段。
    // 修复后：只要有 id 就建 entry(字段解耦)，缺失字段各自走 fallback——
    // 不再因 max_tokens 缺失而整条丢弃(那会连带丢掉同条的 max_input_tokens)。
    const sample = "{\"data\":[{\"id\":\"claude-sonnet-4-6\",\"type\":\"model\",\"display_name\":\"X\"}]}";
    var c = Catalog.init(testing.allocator);
    defer c.deinit();
    try c.loadFromModelsListJson(sample);
    try testing.expect(c.entries.items.len == 1); // entry 建立(不再跳过)
    try testing.expect(c.entries.items[0].max_tokens == null); // 后端没给 → null
    try testing.expect(c.entries.items[0].max_input_tokens == null);
    // 查询仍有兜底（util/model.zig 的 claude-sonnet-4-6 default = 32000；context 默认 200K）
    try testing.expect(c.maxTokensFor("claude-sonnet-4-6", null) == 32_000);
    try testing.expect(c.maxInputTokensFor("claude-sonnet-4-6") == 200_000);
}

test "Catalog: 字段解耦——只返回 max_input_tokens 也采纳 context window" {
    // 关键回归：后端只给 context window(无 output max_tokens)。
    // 修复前：max_tokens 缺失 → 整条 continue → max_input_tokens 丢失 → context 退回 200K。
    // 修复后：context window 正确采纳为 1M，output 走 fallback。
    const sample = "{\"data\":[{\"id\":\"claude-opus-4-8\",\"type\":\"model\",\"max_input_tokens\":1000000}]}";
    var c = Catalog.init(testing.allocator);
    defer c.deinit();
    try c.loadFromModelsListJson(sample);
    try testing.expect(c.entries.items.len == 1);
    try testing.expect(c.maxInputTokensFor("claude-opus-4-8") == 1_000_000); // 采纳，非 200K 默认
    try testing.expect(c.entries.items[0].max_tokens == null); // output 缺失记 null
    // maxTokensFor 命中 entry 但字段 null → 走本地 fallback(opus 不在表则 DEFAULT)
    _ = c.maxTokensFor("claude-opus-4-8", null); // 不崩、有兜底即可
}

test "Catalog: 字段解耦——只返回 max_tokens 时 context 走默认" {
    const sample = "{\"data\":[{\"id\":\"m\",\"max_tokens\":64000}]}";
    var c = Catalog.init(testing.allocator);
    defer c.deinit();
    try c.loadFromModelsListJson(sample);
    try testing.expect(c.entries.items.len == 1);
    try testing.expect(c.maxTokensFor("m", null) == 64_000); // output 采纳
    try testing.expect(c.maxInputTokensFor("m") == 200_000); // context 缺失 → 默认
}

test "Catalog: max_input_tokens=0 占位值不被当成有效 context window" {
    // 对齐 Anthropic 官方 /v1/models 示例：字段可能为占位 0。0 不能当"上下文为 0"。
    const sample = "{\"data\":[{\"id\":\"m\",\"max_tokens\":0,\"max_input_tokens\":0}]}";
    var c = Catalog.init(testing.allocator);
    defer c.deinit();
    try c.loadFromModelsListJson(sample);
    try testing.expect(c.entries.items.len == 1);
    try testing.expect(c.entries.items[0].max_input_tokens == null); // 0 归一成 null
    try testing.expect(c.entries.items[0].max_tokens == null);
    try testing.expect(c.maxInputTokensFor("m") == 200_000); // 走默认而非 0
}

test "Catalog: image_input 三态——目录声明 true/false 按字面,缺失为 null" {
    var c = Catalog.init(testing.allocator);
    defer c.deinit();
    try c.loadFromModelsListJson(
        \\{"data":[
        \\ {"id":"GLM-5.2","max_input_tokens":1048576,"capabilities":{"thinking":{"supported":true},"image_input":{"supported":false}}},
        \\ {"id":"glm-5.3-flash","capabilities":{"image_input":{"supported": true}}},
        \\ {"id":"mystery","capabilities":{"thinking":{"supported":true}}},
        \\ {"id":"bare"},
        \\ {"id":"odd","capabilities":{"image_input":{"supported":"yes"}}}
        \\]}
    );
    try std.testing.expectEqual(@as(?bool, false), c.imageInputFor("glm-5.2"));
    try std.testing.expectEqual(@as(?bool, true), c.imageInputFor("GLM-5.3-FLASH"));
    try std.testing.expectEqual(@as(?bool, null), c.imageInputFor("mystery"));
    try std.testing.expectEqual(@as(?bool, null), c.imageInputFor("bare"));
    try std.testing.expectEqual(@as(?bool, null), c.imageInputFor("odd"));
    try std.testing.expectEqual(@as(?bool, null), c.imageInputFor("not-in-catalog"));
    const vision = try c.visionModels(testing.allocator);
    defer testing.allocator.free(vision);
    try std.testing.expectEqual(@as(usize, 1), vision.len);
    try std.testing.expectEqualStrings("glm-5.3-flash", vision[0]);
    // clone 保留三态
    var copy = try c.clone(testing.allocator);
    defer copy.deinit();
    try std.testing.expectEqual(@as(?bool, true), copy.imageInputFor("glm-5.3-flash"));
    try std.testing.expectEqual(@as(?bool, false), copy.imageInputFor("GLM-5.2"));
}

test "Catalog: 顶档标签跟目录词汇——只声明 max 的路由标 max,声明 xhigh / 未声明的标 xhigh" {
    var c = Catalog.init(testing.allocator);
    defer c.deinit();
    // Metask 网关真实形状(glm-5.3-flash):effort 里 high/max 支持,low/medium 不支持。
    try c.loadFromModelsListJson(
        \\{"data":[
        \\ {"id":"glm-5.3-flash","capabilities":{"effort":{"high": {"supported": true}, "low": {"supported": false}, "max": {"supported": true}, "medium": {"supported": false}, "supported": true}}},
        \\ {"id":"gpt-5.2","capabilities":{"effort":{"high":{"supported":true},"xhigh":{"supported":true},"max":{"supported":true}}}},
        \\ {"id":"plain"}
        \\]}
    );
    try std.testing.expectEqualStrings("max", c.effortLabelFor("GLM-5.3-Flash", .xhigh));
    try std.testing.expectEqualStrings("high", c.effortLabelFor("glm-5.3-flash", .high));
    try std.testing.expectEqualStrings("xhigh", c.effortLabelFor("gpt-5.2", .xhigh));
    try std.testing.expectEqualStrings("xhigh", c.effortLabelFor("plain", .xhigh));
    try std.testing.expectEqualStrings("xhigh", c.effortLabelFor("not-in-catalog", .xhigh));
    // 档位集合本身不变:max 与 xhigh 都是同一个顶档位,low/medium 未支持不进 mask。
    try std.testing.expect(c.entries.items[0].supportsReasoning(.xhigh));
    try std.testing.expect(c.entries.items[0].supportsReasoning(.high));
    try std.testing.expect(!c.entries.items[0].supportsReasoning(.low));
    try std.testing.expect(!c.entries.items[0].supportsReasoning(.medium));
    var copy = try c.clone(testing.allocator);
    defer copy.deinit();
    try std.testing.expectEqualStrings("max", copy.effortLabelFor("glm-5.3-flash", .xhigh));
    try std.testing.expectEqualStrings("xhigh", effortLabel(.neutral, .xhigh));
    try std.testing.expectEqualStrings("medium", effortLabel(.max, .medium));
}

test "Catalog: empty/invalid json no crash" {
    var c = Catalog.init(testing.allocator);
    defer c.deinit();
    try c.loadFromModelsListJson("not json");
    try c.loadFromModelsListJson("");
    try c.loadFromModelsListJson("{}");
    try testing.expect(c.entries.items.len == 0);
}
