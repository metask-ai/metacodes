//! 价格表（USD per million tokens）。
//! 数字可能随 Anthropic 调价变化，属于 L2 事实而非 L1 记忆——需要时更新常量即可。
//! 参考：https://www.anthropic.com/pricing （2026-04 snapshot）

const std = @import("std");
const model_name = @import("../api/model_name.zig");

pub const Rates = struct {
    /// 每百万 input token USD
    input_per_mtok: f64,
    output_per_mtok: f64,
    cache_read_per_mtok: f64,
    cache_write_per_mtok: f64,
};

/// 默认 fallback：按 sonnet 4 的价格算。
pub const DEFAULT_RATES: Rates = .{
    .input_per_mtok = 3.0,
    .output_per_mtok = 15.0,
    .cache_read_per_mtok = 0.30,
    .cache_write_per_mtok = 3.75,
};

/// GLM-5.2 production pilot guardrail. This deliberately keeps the higher
/// Sonnet-4 USD rates instead of pretending the provider's RMB bill is known.
/// Zhipu's 2026-08-07 public price (8/28 RMB per MTok, 2 RMB cache hit) and
/// Metask's official-price policy make this conservative for authorization;
/// it remains an estimate, never a provider-billed cost.
pub const GLM_52_GUARDRAIL_RATES = DEFAULT_RATES;
pub const GLM_52_GUARDRAIL_PROVENANCE = "metacodes_glm-5.2_conservative_sonnet4_usd_guardrail_2026-08-07_not_provider_bill";

/// 按 model 名称（子串匹配）返回单价。未匹配到 → DEFAULT_RATES。
pub fn rateFor(model: []const u8) Rates {
    if (model_name.eqlIgnoreCase(model, "glm-5.2")) return GLM_52_GUARDRAIL_RATES;
    // opus 系列
    if (model_name.containsIgnoreCase(model, "opus")) {
        return .{
            .input_per_mtok = 15.0,
            .output_per_mtok = 75.0,
            .cache_read_per_mtok = 1.50,
            .cache_write_per_mtok = 18.75,
        };
    }
    // haiku 系列
    if (model_name.containsIgnoreCase(model, "haiku")) {
        return .{
            .input_per_mtok = 1.0,
            .output_per_mtok = 5.0,
            .cache_read_per_mtok = 0.10,
            .cache_write_per_mtok = 1.25,
        };
    }
    // sonnet / 默认
    return DEFAULT_RATES;
}

pub fn provenanceFor(model: []const u8) []const u8 {
    if (model_name.eqlIgnoreCase(model, "glm-5.2")) return GLM_52_GUARDRAIL_PROVENANCE;
    return "metacodes_builtin_2026-04_with_fallback";
}

/// A model's price from `<state root>/config.json` `model_prices`, in USD
/// per million tokens.
pub const ModelPrice = struct {
    model: []const u8,
    rates: Rates,
};

pub const CONFIGURED_PROVENANCE = "user_config_model_prices";

var configured: []const ModelPrice = &.{};

/// Prices every later `effectiveRates` consults first. The App installs its
/// state root's table at startup and clears it when it is destroyed.
pub fn installConfigured(prices: []const ModelPrice) void {
    configured = prices;
}

pub fn installedConfigured() []const ModelPrice {
    return configured;
}

/// The rates a session is charged: the configured price of `model` (also
/// matched without its first `provider/` segment), else the built-in table.
pub fn effectiveRates(model: []const u8) Rates {
    return configuredRates(model) orelse rateFor(model);
}

pub fn effectiveProvenance(model: []const u8) []const u8 {
    return if (configuredRates(model) != null) CONFIGURED_PROVENANCE else provenanceFor(model);
}

fn configuredRates(model: []const u8) ?Rates {
    const bare = if (std.mem.indexOfScalar(u8, model, '/')) |slash| model[slash + 1 ..] else model;
    for (configured) |price| {
        if (model_name.eqlIgnoreCase(price.model, model) or model_name.eqlIgnoreCase(price.model, bare)) return price.rates;
    }
    return null;
}

pub const ParseError = error{ InvalidModelPrices, OutOfMemory };

/// `model_prices` of a whole config.json: null when the key is absent.
/// `input` and `output` are required; `cached_input` and `cache_write`
/// default to `input`. Unknown fields and negative prices are refused.
pub fn parseConfigured(allocator: std.mem.Allocator, config_json: []const u8) ParseError!?[]ModelPrice {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, config_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModelPrices,
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidModelPrices,
    };
    const table = switch (root.get("model_prices") orelse return null) {
        .object => |o| o,
        else => return error.InvalidModelPrices,
    };
    var prices: std.ArrayList(ModelPrice) = .empty;
    errdefer prices.deinit(allocator);
    errdefer freeConfigured(allocator, prices.items);
    var it = table.iterator();
    while (it.next()) |entry| {
        const fields = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => return error.InvalidModelPrices,
        };
        var field_it = fields.iterator();
        while (field_it.next()) |field| {
            const known = [_][]const u8{ "input", "output", "cached_input", "cache_write" };
            for (known) |name| {
                if (std.mem.eql(u8, field.key_ptr.*, name)) break;
            } else return error.InvalidModelPrices;
        }
        const input = try priceField(fields, "input") orelse return error.InvalidModelPrices;
        const output = try priceField(fields, "output") orelse return error.InvalidModelPrices;
        const model = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(model);
        try prices.append(allocator, .{ .model = model, .rates = .{
            .input_per_mtok = input,
            .output_per_mtok = output,
            .cache_read_per_mtok = try priceField(fields, "cached_input") orelse input,
            .cache_write_per_mtok = try priceField(fields, "cache_write") orelse input,
        } });
    }
    return try prices.toOwnedSlice(allocator);
}

fn priceField(fields: std.json.ObjectMap, name: []const u8) ParseError!?f64 {
    const value: f64 = switch (fields.get(name) orelse return null) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return error.InvalidModelPrices,
    };
    if (!(value >= 0) or std.math.isInf(value)) return error.InvalidModelPrices;
    return value;
}

pub fn freeConfigured(allocator: std.mem.Allocator, prices: []const ModelPrice) void {
    for (prices) |price| allocator.free(price.model);
}

/// `<state root>/config.json` `model_prices`; a missing or unreadable file is
/// null (none configured), a malformed table an error.
pub fn loadConfiguredFromHome(allocator: std.mem.Allocator, state_root: []const u8) ParseError!?[]ModelPrice {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/config.json\x00", .{state_root}) catch return null;
    const pfs = @import("platform").fs;
    const fd = pfs.open(@ptrCast(path.ptr), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = pfs.close(fd);
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, buf[0..buf.len]);
        if (n < 0) return null;
        if (n == 0) break;
        try all.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return parseConfigured(allocator, all.items);
}

/// 计算给定 usage 的总 cost（USD）。
pub fn computeCost(rates: Rates, input_tokens: u64, output_tokens: u64, cache_read: u64, cache_write: u64) f64 {
    const i = @as(f64, @floatFromInt(input_tokens)) / 1_000_000.0 * rates.input_per_mtok;
    const o = @as(f64, @floatFromInt(output_tokens)) / 1_000_000.0 * rates.output_per_mtok;
    const cr = @as(f64, @floatFromInt(cache_read)) / 1_000_000.0 * rates.cache_read_per_mtok;
    const cw = @as(f64, @floatFromInt(cache_write)) / 1_000_000.0 * rates.cache_write_per_mtok;
    return i + o + cr + cw;
}

test "rateFor sonnet default" {
    const r = rateFor("claude-sonnet-4-20250514");
    try std.testing.expect(r.input_per_mtok == 3.0);
}

test "glm-5.2 uses explicit conservative guardrail provenance" {
    const rates = rateFor("glm-5.2");
    try std.testing.expectEqual(GLM_52_GUARDRAIL_RATES, rates);
    try std.testing.expectEqualStrings(GLM_52_GUARDRAIL_PROVENANCE, provenanceFor("glm-5.2"));
}

test "rateFor opus" {
    const r = rateFor("claude-opus-4");
    try std.testing.expect(r.input_per_mtok == 15.0);
}

test "rateFor haiku" {
    const r = rateFor("claude-haiku-4-5");
    try std.testing.expect(r.input_per_mtok == 1.0);
}

test "computeCost basic" {
    const r = DEFAULT_RATES;
    const c = computeCost(r, 1_000_000, 0, 0, 0);
    try std.testing.expect(@abs(c - 3.0) < 1e-9);
}

test "computeCost all components" {
    const r = DEFAULT_RATES;
    const c = computeCost(r, 1_000_000, 1_000_000, 1_000_000, 1_000_000);
    // 3 + 15 + 0.30 + 3.75 = 22.05
    try std.testing.expect(@abs(c - 22.05) < 1e-6);
}

test "configured prices win over the built-in table, also without a provider prefix" {
    const gpa = std.testing.allocator;
    const prices = (try parseConfigured(gpa,
        \\{"model_prices": {"DeepSeek-V4.1-Flash-1017": {"input": 0.15, "output": 0.6, "cached_input": 0.003}}}
    )).?;
    defer gpa.free(prices);
    defer freeConfigured(gpa, prices);
    installConfigured(prices);
    defer installConfigured(&.{});
    const rates = effectiveRates("metask/deepseek-v4.1-flash-1017");
    try std.testing.expectEqual(@as(f64, 0.15), rates.input_per_mtok);
    try std.testing.expectEqual(@as(f64, 0.003), rates.cache_read_per_mtok);
    try std.testing.expectEqual(@as(f64, 0.15), rates.cache_write_per_mtok);
    try std.testing.expectEqualStrings(CONFIGURED_PROVENANCE, effectiveProvenance("DeepSeek-V4.1-Flash-1017"));
    try std.testing.expectEqual(DEFAULT_RATES, effectiveRates("some-other-model"));
    try std.testing.expectEqual(DEFAULT_RATES, effectiveRates("gateway/acme/deepseek-v4.1-flash-1017"));
}

test "a namespaced configured price matches the model behind its provider prefix only" {
    const gpa = std.testing.allocator;
    const prices = (try parseConfigured(gpa,
        \\{"model_prices": {"acme/model": {"input": 1, "output": 2}}}
    )).?;
    defer gpa.free(prices);
    defer freeConfigured(gpa, prices);
    installConfigured(prices);
    defer installConfigured(&.{});
    try std.testing.expectEqual(@as(f64, 1), effectiveRates("gateway/acme/model").input_per_mtok);
    try std.testing.expectEqual(@as(f64, 1), effectiveRates("acme/model").input_per_mtok);
    try std.testing.expectEqual(DEFAULT_RATES, effectiveRates("other/model"));
}

test "a malformed model_prices table is refused and an absent one is null" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]ModelPrice, null), try parseConfigured(gpa, "{\"model\": \"x\"}"));
    const bad = [_][]const u8{
        "{\"model_prices\": []}",
        "{\"model_prices\": {\"m\": {\"input\": 1}}}",
        "{\"model_prices\": {\"m\": {\"input\": -1, \"output\": 1}}}",
        "{\"model_prices\": {\"m\": {\"input\": 1, \"output\": 1, \"currency\": \"USD\"}}}",
        "{\"model_prices\": {\"m\": {\"input\": \"1\", \"output\": 1}}}",
    };
    for (bad) |text| try std.testing.expectError(error.InvalidModelPrices, parseConfigured(gpa, text));
}
