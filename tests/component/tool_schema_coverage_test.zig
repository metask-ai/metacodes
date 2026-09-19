//! L2 组件测试(层1):工具 schema 全覆盖 + 机制化防复发守卫。
//!
//! 背景:TaskCreate MissingRequiredField bug 根因——内置工具 input_schema.properties
//! 全为 null,序列化给模型的 schema 是自相矛盾的 `{"properties":{},"required":[...]}`,
//! 模型拿不到字段定义 → 漏参风暴。修复后每个工具补了 comptime prop_specs。
//!
//! 本测试是**机制级守卫**:数据驱动遍历 cc.tools.registry,强制"每个 required 字段
//! 必须在 prop_specs 里有定义",并断言序列化后的真实请求体里 properties 非空含具名
//! 字段。以后谁加工具/加 required 字段却忘了填 prop_specs,这里立即变红——把"声明=
//! 接线=测试"从人工纪律变成编译/测试纪律。
//!
//! 反向验证(plan §验证):临时删掉某工具一个 required 对应的 prop_spec,本测试应变红。

const std = @import("std");
const cc = @import("cc");

const tools = cc.tools;

/// 在 prop_specs 里查字段名是否有定义。
fn propSpecHas(specs: []const cc.json_mod.PropSpec, name: []const u8) bool {
    for (specs) |s| {
        if (std.mem.eql(u8, s.name, name)) return true;
    }
    return false;
}

test "L2 守卫: registry 每个工具的 required 字段都在 prop_specs 里有定义" {
    // 这是防 TaskCreate-类 bug 复发的核心断言。required 声明了字段名,prop_specs 必须
    // 给出该字段的定义(type/description),否则模型只知道"有这个必填字段"却不知怎么传。
    for (tools.registry) |entry| {
        const required = entry.input_schema.required orelse continue;
        if (required.len == 0) continue;
        // 有 required 字段 → 必须有 prop_specs(不能是 null/空)
        const specs = entry.input_schema.prop_specs orelse {
            std.debug.print("\n工具 {s} 有 required 字段但 prop_specs=null —— 模型收不到字段定义!\n", .{entry.name});
            return error.MissingPropSpecs;
        };
        for (required) |field| {
            if (!propSpecHas(specs, field)) {
                std.debug.print("\n工具 {s} 的 required 字段 '{s}' 在 prop_specs 里没有定义!\n", .{ entry.name, field });
                return error.RequiredFieldNotInPropSpecs;
            }
        }
    }
}

test "L2 守卫: 有 prop_specs 的工具,每个 spec 的 type 非空(模型需要类型)" {
    for (tools.registry) |entry| {
        const specs = entry.input_schema.prop_specs orelse continue;
        for (specs) |s| {
            if (s.name.len == 0) return error.EmptyPropSpecName;
            if (s.type.len == 0) {
                std.debug.print("\n工具 {s} 字段 '{s}' 的 type 为空\n", .{ entry.name, s.name });
                return error.EmptyPropSpecType;
            }
        }
    }
}

test "L2 端到端: 序列化请求体里每个有 required 的工具 properties 含其字段+type(非空 {})" {
    const a = std.testing.allocator;
    const defs = try tools.toToolDefinitions(a);
    defer a.free(defs);

    const types = cc.json_mod;
    const msg = cc.types_mod.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = types.MessagesRequest{ .model = "m", .messages = &.{msg}, .tools = defs };
    const body = try types.serializeMessagesRequest(req, a);
    defer a.free(body);

    // 对每个 registry 工具:若有 required 字段,其在请求体里的字段定义必须出现为
    // `"<field>":{"type":` 形态(证明 properties 不是空 {} 且字段带类型)。
    for (tools.registry) |entry| {
        if (entry.swarm_gated) continue; // swarm 工具仅 --agent-teams 时进 body(此处默认 off)
        const required = entry.input_schema.required orelse continue;
        if (required.len == 0) continue;
        for (required) |field| {
            var buf: [160]u8 = undefined;
            const needle = std.fmt.bufPrint(&buf, "\"{s}\":{{\"type\":", .{field}) catch continue;
            if (std.mem.indexOf(u8, body, needle) == null) {
                std.debug.print("\n请求体缺少工具 {s} 的字段定义: {s}\n", .{ entry.name, needle });
                return error.FieldDefinitionMissingInRequest;
            }
        }
    }
}

test "L2 回归锚点: 核心工具的具名字段+类型(人读快照)" {
    const a = std.testing.allocator;
    const defs = try tools.toToolDefinitions(a);
    defer a.free(defs);

    const types = cc.json_mod;
    const msg = cc.types_mod.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = types.MessagesRequest{ .model = "m", .messages = &.{msg}, .tools = defs };
    const body = try types.serializeMessagesRequest(req, a);
    defer a.free(body);

    // TaskCreate(本次 bug 的当事工具)
    try std.testing.expect(std.mem.indexOf(u8, body, "\"subject\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"description\":{\"type\":\"string\"") != null);
    // 文件工具
    try std.testing.expect(std.mem.indexOf(u8, body, "\"file_path\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"old_string\":{\"type\":\"string\"") != null);
    // Bash / Grep
    try std.testing.expect(std.mem.indexOf(u8, body, "\"command\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"pattern\":{\"type\":\"string\"") != null);
    // ExitPlanMode 的 plan 字段(可选,但必须序列化进请求体,模型才知道该传计划摘要)。
    // 实测 bug:plan 曾误设 required → 模型不传就被 validateRequired 拦死;改可选后仍须可见。
    try std.testing.expect(std.mem.indexOf(u8, body, "\"plan\":{\"type\":\"string\"") != null);
    // 不应再出现"required 点名字段但 properties 空 {}"的自相矛盾形态
    try std.testing.expect(std.mem.indexOf(u8, body, "\"properties\":{\"") != null);
}

test "L2 嵌套守卫: AskUserQuestion 两层嵌套 schema 完整序列化进请求体" {
    // AskUserQuestion 是唯一两层嵌套(questions[].options[].{label,description})的工具。
    // d7b3dd0 改 request.zig 加递归 serializePropSpec,但当年没补字节级断言守卫——本测补洞。
    const a = std.testing.allocator;
    const defs = try tools.toToolDefinitions(a);
    defer a.free(defs);

    const types = cc.json_mod;
    const msg = cc.types_mod.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = types.MessagesRequest{ .model = "m", .messages = &.{msg}, .tools = defs };
    const body = try types.serializeMessagesRequest(req, a);
    defer a.free(body);

    // 第一层:questions 是 array。
    try std.testing.expect(std.mem.indexOf(u8, body, "\"questions\":{\"type\":\"array\"") != null);
    // 第二层:question/header/options/multiSelect 出现在 questions 的 items.properties。
    try std.testing.expect(std.mem.indexOf(u8, body, "\"question\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"options\":{\"type\":\"array\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"multiSelect\":{\"type\":\"boolean\"") != null);
    // 第三层(options 的 items):label/description 必须出现(最深嵌套,最易被序列化漏掉)。
    try std.testing.expect(std.mem.indexOf(u8, body, "\"label\":{\"type\":\"string\"") != null);
    // 嵌套 required:options items 的 required 含 label/description。
    try std.testing.expect(std.mem.indexOf(u8, body, "\"required\":[\"label\",\"description\"]") != null);
}

/// 取某工具某字段的 description(找不到返回 null)。
fn propDescription(tool_name: []const u8, field: []const u8) ?[]const u8 {
    for (tools.registry) |entry| {
        if (!std.mem.eql(u8, entry.name, tool_name)) continue;
        const specs = entry.input_schema.prop_specs orelse return null;
        for (specs) |s| {
            if (std.mem.eql(u8, s.name, field)) return s.description;
        }
        return null;
    }
    return null;
}

test "L2 守卫: BashOutput max_bytes 的 schema 描述与预算实现不分叉" {
    // 血泪:实现从固定 65536 改成按 `result_budget.payloadAllowance` 派生后,顶层
    // `.description` 改了,而模型真正据以规划参数的 **property description** 还写着
    // "default 65536"。声明与实现分叉,且两边都"看起来"被更新过。
    //
    // description 是自然语言,不能整体对照实现;但它引用的**每个数字**都能。这里把
    // 描述里出现的常量逐个绑回真实来源,任何一边动了而另一边没跟,立刻红。
    const desc = propDescription("BashOutput", "max_bytes") orelse
        return error.BashOutputMaxBytesSpecMissing;

    // ① 不得再声明固定默认值——这正是分叉过的那句。
    try std.testing.expect(std.mem.indexOf(u8, desc, "default 65536") == null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "no fixed default") != null);

    // ② 硬上限必须等于实现里的 MAX_MAX_BYTES,**两处都要**。
    //    只断言"这个数字出现过"太弱:描述里 262144 出现两次(范围 + 显式值上限),
    //    改其中一处另一处仍在,断言照样通过——实测确认过这个漏网。所以两个短语都
    //    从常量拼出来验。代价是改写措辞会撞红,这正是想要的:动了文案就得重核数字。
    var range_buf: [32]u8 = undefined;
    var cap_buf: [32]u8 = undefined;
    const cap = cc.tools_bash_output.MAX_MAX_BYTES;
    try std.testing.expect(std.mem.indexOf(
        u8,
        desc,
        try std.fmt.bufPrint(&range_buf, "1..{d})", .{cap}),
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        desc,
        try std.fmt.bufPrint(&cap_buf, "capped at {d}", .{cap}),
    ) != null);

    // ③ 描述举的两个预算示例必须等于 payloadAllowance 真算出来的值。举例给的是
    //    具体数字而不是"大约",就是为了能这样绑住。
    const window_budget = cc.result_budget.Budget.fromModel(200_000);
    const floor_budget = cc.result_budget.Budget.fromModel(0);
    inline for (.{ window_budget, floor_budget }) |budget| {
        const allowance = budget.payloadAllowance(cc.tools_bash_output.ENVELOPE_OVERHEAD_BYTES);
        var buf: [24]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d}", .{allowance.raw()});
        try std.testing.expect(std.mem.indexOf(u8, desc, text) != null);
    }
}

test "L2 守卫: BashOutput wait_ms 的 schema 描述绑定等待常量" {
    const desc = propDescription("BashOutput", "wait_ms") orelse
        return error.BashOutputWaitMsSpecMissing;
    var default_buf: [32]u8 = undefined;
    var max_buf: [32]u8 = undefined;
    const default_text = try std.fmt.bufPrint(&default_buf, "default {d} ms", .{cc.tools_bash_output.DEFAULT_WAIT_MS});
    const max_text = try std.fmt.bufPrint(&max_buf, "maximum {d} ms", .{cc.tools_bash_output.MAX_WAIT_MS});
    try std.testing.expect(std.mem.indexOf(u8, desc, default_text) != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "0 for an immediate snapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, max_text) != null);
}
