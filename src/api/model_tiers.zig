//! Provider 内模型档位(tier)表:高/中/低三档模型 + 各档推理深度。
//!
//! 语义:agent 定义与 /model 里的档位名(low/mid/high;兼容别名 haiku/sonnet/opus
//! 分别映射 low/mid/high)解析为**当前 provider 配置的**具体 {model, effort}。
//! 未配置的档位回退 inherit(父/当前模型)——档位名永远不会产出跨 provider 的
//! 硬编码模型 ID(issue #11:Explore pin "haiku" 在 metask 中继上被解析成
//! Anthropic ID,子请求 503 而父会话正常的差分根源)。
//!
//! 配置来源:`~/.metacodes/config.json` 顶层 `model_tiers` 字段,按 provider
//! kind 分组:
//!
//! ```json
//! "model_tiers": {
//!   "openai": {
//!     "low":  {"model": "gpt-5.6-mini", "effort": "medium"},
//!     "high": {"model": "gpt-5.6-sol",  "effort": "xhigh"}
//!   }
//! }
//! ```
//!
//! effort 的 wire 翻译不在本模块:agent_loop 只传统一的 ReasoningEffort,
//! 各家格式(OpenAI effort 字符串 / GLM prompt 标签 / Kimi 顶层字段 /
//! DeepSeek thinking body)由 api/model_adapter.zig 按模型族处理。

const std = @import("std");
const types = @import("../types.zig");

pub const Tier = enum {
    low,
    mid,
    high,

    /// 档位名解析。兼容别名:haiku→low、sonnet→mid、opus→high(存量 agent
    /// 定义不破);其余字符串不是档位(调用方按显式模型名透传)。
    pub fn parse(name: []const u8) ?Tier {
        if (std.ascii.eqlIgnoreCase(name, "low") or std.ascii.eqlIgnoreCase(name, "haiku")) return .low;
        if (std.ascii.eqlIgnoreCase(name, "mid") or std.ascii.eqlIgnoreCase(name, "sonnet")) return .mid;
        if (std.ascii.eqlIgnoreCase(name, "high") or std.ascii.eqlIgnoreCase(name, "opus")) return .high;
        return null;
    }
};

/// 一档的具体配置。两个字段独立可缺:model 缺 = inherit 当前模型,
/// effort 缺 = inherit 当前 effort。
pub const TierSpec = struct {
    model: ?[]u8 = null,
    effort: ?types.ReasoningEffort = null,
};

/// 一个 provider 的三档表。全默认 = 三档都完全 inherit(用户不配置时,
/// "3 个档位就是那一个模型")。
pub const ProviderTiers = struct {
    low: TierSpec = .{},
    mid: TierSpec = .{},
    high: TierSpec = .{},

    pub fn spec(self: *const ProviderTiers, tier: Tier) *const TierSpec {
        return switch (tier) {
            .low => &self.low,
            .mid => &self.mid,
            .high => &self.high,
        };
    }

    fn deinitSpecs(self: *ProviderTiers, allocator: std.mem.Allocator) void {
        inline for (.{ &self.low, &self.mid, &self.high }) |s| {
            if (s.model) |m| allocator.free(m);
        }
    }
};

/// 按 provider kind 分组的档位表(配置文件按用户级存放,一份文件服务
/// 任意 --provider 启动的 session;按 kind 分组保证换 provider 不串档)。
pub const TierTable = struct {
    allocator: std.mem.Allocator,
    anthropic: ProviderTiers = .{},
    openai: ProviderTiers = .{},
    gemini: ProviderTiers = .{},

    pub fn forKind(self: *const TierTable, kind: types.ProviderKind) *const ProviderTiers {
        return switch (kind) {
            .anthropic => &self.anthropic,
            .openai => &self.openai,
            .gemini => &self.gemini,
        };
    }

    pub fn deinit(self: *TierTable) void {
        self.anthropic.deinitSpecs(self.allocator);
        self.openai.deinitSpecs(self.allocator);
        self.gemini.deinitSpecs(self.allocator);
    }
};

/// 档位名/模型名 → 具体覆盖。三类输入:
///   - 档位名(或兼容别名):查表;命中档的 model/effort 缺失分别回退 inherit(null)。
///   - 其余非空字符串:显式模型名,原样透传(model=输入,effort=null)。
/// "inherit"/空串由调用方在进入本函数前过滤(与既有 spawn 语义一致)。
pub const Resolved = struct {
    model: ?[]const u8,
    effort: ?types.ReasoningEffort,
};

/// Resolve child effort in Codex order: definition, explicit tier selection,
/// inherited parent effort for the same model, then provider default.
pub fn resolveChildEffort(def_effort: ?types.ReasoningEffort, selection: Resolved, parent_effort: ?types.ReasoningEffort) ?types.ReasoningEffort {
    if (def_effort) |effort| return effort;
    if (selection.effort) |effort| return effort;
    if (selection.model == null) return parent_effort;
    return null;
}

test "resolveChildEffort covers all precedence branches" {
    try std.testing.expectEqual(types.ReasoningEffort.low, resolveChildEffort(.low, .{ .model = "child", .effort = .high }, .none).?);
    try std.testing.expectEqual(types.ReasoningEffort.medium, resolveChildEffort(null, .{ .model = "child", .effort = .medium }, .high).?);
    try std.testing.expectEqual(types.ReasoningEffort.none, resolveChildEffort(null, .{ .model = null, .effort = null }, .none).?);
    try std.testing.expect(resolveChildEffort(null, .{ .model = "other", .effort = null }, .high) == null);
}

pub fn resolveName(tiers: ?*const ProviderTiers, name: []const u8) Resolved {
    if (Tier.parse(name)) |tier| {
        const spec = (tiers orelse return .{ .model = null, .effort = null }).spec(tier);
        return .{ .model = if (spec.model) |m| m else null, .effort = spec.effort };
    }
    return .{ .model = name, .effort = null };
}

pub const ParseError = error{
    InvalidTierTable,
    InvalidTierSpec,
    InvalidTierEffort,
    OutOfMemory,
};

/// 读 `~/.metacodes/config.json` 并解析 model_tiers。文件缺失/不可读 → null
/// (未配置);解析错误原样上抛(调用方决定降级策略并告警)。
pub fn loadFromHome(allocator: std.mem.Allocator, home: []const u8) ParseError!?TierTable {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.metacodes/config.json\x00", .{home}) catch return null;
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
    return parseTableFromConfig(allocator, all.items);
}

/// 从整份 config.json 文本解析 `model_tiers` 字段。字段缺失 → null(未配置)。
/// 结构严格:未知 provider 键 / 未知档位键 / 未知 spec 字段 / 非法 effort
/// 都在解析期拒绝,不静默吞掉拼写错误。
pub fn parseTableFromConfig(allocator: std.mem.Allocator, config_json: []const u8) ParseError!?TierTable {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, config_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidTierTable,
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidTierTable,
    };
    const tiers_value = root.get("model_tiers") orelse return null;
    return try parseTable(allocator, tiers_value);
}

fn parseTable(allocator: std.mem.Allocator, value: std.json.Value) ParseError!TierTable {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidTierTable,
    };
    var table = TierTable{ .allocator = allocator };
    errdefer table.deinit();
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const dest: *ProviderTiers = if (std.mem.eql(u8, key, "anthropic"))
            &table.anthropic
        else if (std.mem.eql(u8, key, "openai"))
            &table.openai
        else if (std.mem.eql(u8, key, "gemini"))
            &table.gemini
        else
            return error.InvalidTierTable;
        try parseProviderTiers(allocator, entry.value_ptr.*, dest);
    }
    return table;
}

fn parseProviderTiers(allocator: std.mem.Allocator, value: std.json.Value, dest: *ProviderTiers) ParseError!void {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidTierTable,
    };
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const spec: *TierSpec = if (std.mem.eql(u8, key, "low"))
            &dest.low
        else if (std.mem.eql(u8, key, "mid"))
            &dest.mid
        else if (std.mem.eql(u8, key, "high"))
            &dest.high
        else
            return error.InvalidTierTable;
        try parseSpec(allocator, entry.value_ptr.*, spec);
    }
}

fn parseSpec(allocator: std.mem.Allocator, value: std.json.Value, dest: *TierSpec) ParseError!void {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidTierSpec,
    };
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "model")) {
            const raw = switch (entry.value_ptr.*) {
                .string => |s| s,
                else => return error.InvalidTierSpec,
            };
            if (raw.len == 0) return error.InvalidTierSpec;
            dest.model = try allocator.dupe(u8, raw);
        } else if (std.mem.eql(u8, key, "effort")) {
            const raw = switch (entry.value_ptr.*) {
                .string => |s| s,
                else => return error.InvalidTierEffort,
            };
            dest.effort = types.ReasoningEffort.parse(raw) orelse return error.InvalidTierEffort;
        } else return error.InvalidTierSpec;
    }
}

// ────────────────────────────────────────────────────────────────────────────

test "tier names parse with legacy aliases and reject arbitrary models" {
    try std.testing.expectEqual(Tier.low, Tier.parse("low").?);
    try std.testing.expectEqual(Tier.low, Tier.parse("haiku").?);
    try std.testing.expectEqual(Tier.mid, Tier.parse("sonnet").?);
    try std.testing.expectEqual(Tier.high, Tier.parse("opus").?);
    try std.testing.expectEqual(Tier.high, Tier.parse("HIGH").?);
    try std.testing.expect(Tier.parse("gpt-5.6-sol") == null);
    try std.testing.expect(Tier.parse("claude-3-5-haiku-20241022") == null);
    try std.testing.expect(Tier.parse("") == null);
}

test "resolveName: configured tier yields model+effort, unconfigured tier inherits, explicit passes through" {
    const a = std.testing.allocator;
    var table = (try parseTableFromConfig(a,
        \\{"model_tiers":{"openai":{
        \\  "low":{"model":"gpt-5.6-mini","effort":"medium"},
        \\  "high":{"effort":"xhigh"}
        \\}}}
    )).?;
    defer table.deinit();
    const tiers = table.forKind(.openai);

    const low = resolveName(tiers, "haiku");
    try std.testing.expectEqualStrings("gpt-5.6-mini", low.model.?);
    try std.testing.expectEqual(types.ReasoningEffort.medium, low.effort.?);

    // mid 未配置 → 完全 inherit:决不回退任何硬编码模型 ID。
    const mid = resolveName(tiers, "sonnet");
    try std.testing.expect(mid.model == null);
    try std.testing.expect(mid.effort == null);

    // high 只配了 effort → model inherit + effort 覆盖。
    const high = resolveName(tiers, "opus");
    try std.testing.expect(high.model == null);
    try std.testing.expectEqual(types.ReasoningEffort.xhigh, high.effort.?);

    // 显式模型名透传;无表(null tiers)时档位名全 inherit。
    const explicit = resolveName(tiers, "gpt-5.6-sol");
    try std.testing.expectEqualStrings("gpt-5.6-sol", explicit.model.?);
    const no_table = resolveName(null, "haiku");
    try std.testing.expect(no_table.model == null and no_table.effort == null);

    // 换 provider kind 查不到 openai 的配置 → inherit(不串档)。
    const other = resolveName(table.forKind(.anthropic), "haiku");
    try std.testing.expect(other.model == null and other.effort == null);
}

test "tier table parse is strict about unknown keys and invalid efforts" {
    const a = std.testing.allocator;
    try std.testing.expect((try parseTableFromConfig(a, "{}")) == null);
    try std.testing.expect((try parseTableFromConfig(a, "{\"theme\":\"dark\"}")) == null);
    try std.testing.expectError(
        error.InvalidTierTable,
        parseTableFromConfig(a, "{\"model_tiers\":{\"metask\":{}}}"),
    );
    try std.testing.expectError(
        error.InvalidTierTable,
        parseTableFromConfig(a, "{\"model_tiers\":{\"openai\":{\"cheap\":{}}}}"),
    );
    try std.testing.expectError(
        error.InvalidTierSpec,
        parseTableFromConfig(a, "{\"model_tiers\":{\"openai\":{\"low\":{\"mdel\":\"x\"}}}}"),
    );
    try std.testing.expectError(
        error.InvalidTierSpec,
        parseTableFromConfig(a, "{\"model_tiers\":{\"openai\":{\"low\":{\"model\":\"\"}}}}"),
    );
    try std.testing.expectError(
        error.InvalidTierEffort,
        parseTableFromConfig(a, "{\"model_tiers\":{\"openai\":{\"low\":{\"effort\":\"ultra\"}}}}"),
    );
}
