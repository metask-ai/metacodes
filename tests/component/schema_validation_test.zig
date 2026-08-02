//! L2 组件测试:schema 层 required 字段校验(对齐 cc zod safeParse 层)。
//!
//! dispatch 前统一校验 input 含所有 required 字段;缺则返回字段具名 Missing* error
//! (→ invalid_args 给模型现场)。这是工具自身 MissingX 之外的统一前置层。

const std = @import("std");
const cc = @import("cc");

const tools = cc.tools;

test "L2 schema: Write 缺 content → MissingContent" {
    // Write required = file_path + content
    try std.testing.expectError(error.MissingContent, tools.validateRequired("Write", "{\"file_path\":\"/x\"}"));
}

test "L2 schema: Write 齐全 → 通过" {
    try tools.validateRequired("Write", "{\"file_path\":\"/x\",\"content\":\"hi\"}");
}

test "L2 schema: Edit 缺 old_string → 拦" {
    try std.testing.expectError(error.MissingOldString, tools.validateRequired("Edit", "{\"file_path\":\"/x\",\"new_string\":\"y\"}"));
    // 齐全通过
    try tools.validateRequired("Edit", "{\"file_path\":\"/x\",\"old_string\":\"a\",\"new_string\":\"b\"}");
}

test "L2 schema: Grep 缺 pattern → 拦" {
    try std.testing.expectError(error.MissingPattern, tools.validateRequired("Grep", "{\"path\":\".\"}"));
    try tools.validateRequired("Grep", "{\"pattern\":\"foo\"}");
}

test "L2 schema: Task 只需 prompt(subagent_type/description 有默认不必需)" {
    // 只给 prompt → 通过(subagent_type 缺省 general-purpose,不应被拦)
    try tools.validateRequired("Task", "{\"prompt\":\"do it\"}");
    // 缺 prompt → 拦
    try std.testing.expectError(error.MissingPrompt, tools.validateRequired("Task", "{\"subagent_type\":\"Explore\"}"));
}

test "L2 schema: 未知工具 → 不拦(交给 dyn/UnknownTool)" {
    try tools.validateRequired("__nope__", "{}");
}

test "L2 schema: MissingRequiredField 归 invalid_args" {
    const a = std.testing.allocator;
    const j = try cc.tool_error.errorToJson("MissingRequiredField", "{s} failed", .{"MissingRequiredField"}, a);
    defer a.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "invalid_args") != null);
}

// ---- 类型层(validateTypes,对齐 cc zod 类型校验) ----

test "L2 schema 类型: Bash.timeout 该 int 传 string → 拦" {
    try std.testing.expectError(error.InvalidFieldType, tools.validateTypes("Bash", "{\"command\":\"ls\",\"timeout\":\"5\"}"));
    // 正确类型通过
    try tools.validateTypes("Bash", "{\"command\":\"ls\",\"timeout\":5}");
}

test "L2 schema 类型: Edit.replace_all 该 bool 传 string → 拦" {
    try std.testing.expectError(error.InvalidFieldType, tools.validateTypes("Edit", "{\"file_path\":\"/x\",\"old_string\":\"a\",\"new_string\":\"b\",\"replace_all\":\"yes\"}"));
    try tools.validateTypes("Edit", "{\"file_path\":\"/x\",\"old_string\":\"a\",\"new_string\":\"b\",\"replace_all\":true}");
}

test "L2 schema 类型: Read.limit 该 int 传 string → 拦" {
    try std.testing.expectError(error.InvalidFieldType, tools.validateTypes("Read", "{\"file_path\":\"/x\",\"limit\":\"10\"}"));
    try tools.validateTypes("Read", "{\"file_path\":\"/x\",\"limit\":10}");
}

test "L2 schema 类型: 字段缺失 → 类型层跳过(不误报)" {
    // Read 不带 limit/offset → 类型层不报
    try tools.validateTypes("Read", "{\"file_path\":\"/x\"}");
    // command 是 string,正确
    try tools.validateTypes("Bash", "{\"command\":\"ls -la\"}");
}

test "L2 schema 类型: file_path 该 string 传 number → 拦" {
    try std.testing.expectError(error.InvalidFieldType, tools.validateTypes("Write", "{\"file_path\":123,\"content\":\"x\"}"));
}

test "L2 schema 类型: InvalidFieldType 归 invalid_args" {
    const a = std.testing.allocator;
    const j = try cc.tool_error.errorToJson("InvalidFieldType", "{s} failed", .{"InvalidFieldType"}, a);
    defer a.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "invalid_args") != null);
}

// ---- properties 端到端(根治 TaskCreate MissingRequiredField:模型必须收到字段定义) ----

test "L2 接线: toToolDefinitions 透传内置工具的 prop_specs(非 null 且含具名字段)" {
    const a = std.testing.allocator;
    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);

    // 找 TaskCreate / Read,断言它们带 prop_specs(早先 toToolDefinitionsFull 硬编码
    // null 把 schema 抹掉 → 模型只收到空 properties → 空参风暴)。
    var saw_taskcreate = false;
    var saw_read = false;
    for (defs) |d| {
        if (std.mem.eql(u8, d.name, "TaskCreate")) {
            saw_taskcreate = true;
            const specs = d.input_schema.prop_specs orelse return error.TestUnexpectedResult;
            var has_subject = false;
            var has_description = false;
            for (specs) |s| {
                if (std.mem.eql(u8, s.name, "subject")) has_subject = true;
                if (std.mem.eql(u8, s.name, "description")) has_description = true;
            }
            try std.testing.expect(has_subject and has_description);
        }
        if (std.mem.eql(u8, d.name, "Read")) {
            saw_read = true;
            const specs = d.input_schema.prop_specs orelse return error.TestUnexpectedResult;
            try std.testing.expect(specs.len > 0);
            try std.testing.expect(std.mem.eql(u8, specs[0].name, "file_path"));
        }
    }
    try std.testing.expect(saw_taskcreate and saw_read);
}

test "L2 序列化: 整个请求体里 TaskCreate 的 properties 含 subject/description(非空)" {
    const a = std.testing.allocator;
    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);

    const types = cc.json_mod;
    const msg = cc.types_mod.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = types.MessagesRequest{ .model = "m", .messages = &.{msg}, .tools = defs };
    const body = try types.serializeMessagesRequest(req, a);
    defer a.free(body);

    // 真正抓本 bug 的断言:发给模型的 schema 里,TaskCreate 的 properties 不是空 {},
    // 含具名字段+类型。子串足够(字段定义紧凑无空格)。
    try std.testing.expect(std.mem.indexOf(u8, body, "\"subject\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"file_path\":{\"type\":\"string\"") != null);
    // 不应再出现"required 点名了字段但 properties 是空 {}"的自相矛盾形态。
    try std.testing.expect(std.mem.indexOf(u8, body, "\"properties\":{\"") != null);
}
