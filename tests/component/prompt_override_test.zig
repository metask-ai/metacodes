//! L2 组件测试:提示词 env 覆盖旁路端到端贯穿(守"声明=接线=测试")。
//!
//! 验证 `METACODES_PROMPT_OVERRIDE_<SLOT>`(base64)→ 实际工具描述 / system prompt 段被替换。
//! 仅断言"配置 X → 输出 Y",不依赖网络/mock server——直接调组装函数检结果。
//!
//! 覆盖两个注入点:
//!   ① TOOL_DESC_CODEMAP → cc.tools.toToolDefinitionsFull 里 CodeMap 的 description
//!   ② USING_TOOLS       → cc.system_prompt.buildFull 里 # Using your tools 段
//! 并验证"不设 env → 走默认"(零回归)。

const std = @import("std");
const cc = @import("cc");

// std.c 未导出 setenv/unsetenv,直接 extern。
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const PREFIX = "METACODES_PROMPT_OVERRIDE_";

fn setOverride(slot_z: [*:0]const u8, plain: []const u8) void {
    // base64 编码 plain,setenv。
    const enc = std.base64.standard.Encoder;
    var b64_buf: [4096]u8 = undefined;
    const b64 = b64_buf[0..enc.calcSize(plain.len)];
    _ = enc.encode(b64, plain);
    var val_buf: [4096]u8 = undefined;
    const val = std.fmt.bufPrintZ(&val_buf, "{s}", .{b64}) catch unreachable;
    _ = setenv(slot_z, val.ptr, 1);
}

fn findDesc(defs: []cc.json_mod.ToolDefinition, name: []const u8) ?[]const u8 {
    for (defs) |d| {
        if (std.mem.eql(u8, d.name, name)) return d.description;
    }
    return null;
}

test "TOOL_DESC_<NAME> env overrides tool description" {
    const a = std.testing.allocator;
    const slot_z = PREFIX ++ "TOOL_DESC_CODEMAP";
    const sentinel = "OVERRIDDEN CODEMAP DESC — ab-test marker\nwith newline";

    // ① 不设 env:CodeMap 走默认描述(含 "structural outline"),不含 sentinel。
    {
        _ = unsetenv(slot_z);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var pc = cc.tools.PromptContext{ .enabled_tool_names = &.{"CodeMap"} };
        const defs = try cc.tools.toToolDefinitionsFull(arena.allocator(), null, &pc);
        const desc = findDesc(defs, "CodeMap") orelse return error.NoCodeMap;
        try std.testing.expect(std.mem.indexOf(u8, desc, sentinel) == null);
        try std.testing.expect(std.mem.indexOf(u8, desc, "structural outline") != null);
    }

    // ② 设 env:CodeMap 描述变成 sentinel。
    {
        setOverride(slot_z, sentinel);
        defer _ = unsetenv(slot_z);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var pc = cc.tools.PromptContext{ .enabled_tool_names = &.{"CodeMap"} };
        const defs = try cc.tools.toToolDefinitionsFull(arena.allocator(), null, &pc);
        const desc = findDesc(defs, "CodeMap") orelse return error.NoCodeMap;
        try std.testing.expectEqualStrings(sentinel, desc);
    }
}

test "USING_TOOLS env overrides # Using your tools section in buildFull" {
    const a = std.testing.allocator;
    const slot_z = PREFIX ++ "USING_TOOLS";
    const sentinel = "MARKER_USING_TOOLS_OVERRIDE_ab_test";

    // ① 不设:默认段含 "Do NOT use the Bash",不含 sentinel。
    {
        _ = unsetenv(slot_z);
        const s = try cc.system_prompt.buildFull(a, "claude-opus-4-7", null, null, &.{ "Read", "CodeMap" }, "");
        defer a.free(s);
        try std.testing.expect(std.mem.indexOf(u8, s, sentinel) == null);
        try std.testing.expect(std.mem.indexOf(u8, s, "Do NOT use the Bash") != null);
    }

    // ② 设:段被替换成 sentinel(整段 # Using your tools 内容),且默认那句不再出现。
    {
        setOverride(slot_z, sentinel);
        defer _ = unsetenv(slot_z);
        const s = try cc.system_prompt.buildFull(a, "claude-opus-4-7", null, null, &.{ "Read", "CodeMap" }, "");
        defer a.free(s);
        try std.testing.expect(std.mem.indexOf(u8, s, sentinel) != null);
        try std.testing.expect(std.mem.indexOf(u8, s, "Do NOT use the Bash") == null);
    }
}
