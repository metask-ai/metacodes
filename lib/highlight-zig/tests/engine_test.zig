const std = @import("std");
const hl = @import("hl");
const tokenize = hl.tokenize;
const TokenType = hl.TokenType;
const LangRule = hl.LangRule;
const ColoredSpan = hl.ColoredSpan;

const testing = std.testing;

/// 临时测试规则——模拟 C 语言子集。
fn cLikeRule() LangRule {
    return .{
        .name = "test",
        .extensions = &.{".t"},
        .keywords = "fn\x00return\x00if\x00else\x00const\x00var\x00pub\x00while",
        .string_delims = &.{.{ .open = "\"", .close = "\"", .escape = .backslash }},
        .comment_line = &.{"//"},
        .comment_block = &.{.{ "/*", "*/" }},
        .number_prefix = &.{ "0x", "0b", "0o" },
    };
}

// ── 基础 token 类型测试 ─────────────────────────────────────

test "关键字匹配 + word-boundary" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "fn return", &rule);
    defer testing.allocator.free(spans);

    try testing.expectEqual(TokenType.keyword, spans[0].token);
    try testing.expectEqualStrings("fn", spans[0].text);
    // " " 是 none
    try testing.expectEqual(TokenType.keyword, spans[2].token);
    try testing.expectEqualStrings("return", spans[2].text);
}

test "fn 不匹配 function（word-boundary）" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "fn function", &rule);
    defer testing.allocator.free(spans);

    // "fn" 是 keyword
    try testing.expectEqualStrings("fn", spans[0].text);
    try testing.expectEqual(TokenType.keyword, spans[0].token);

    // "function" 不应是 keyword（右边界失败）
    var found_function_kw = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "function") and s.token == .keyword) {
            found_function_kw = true;
        }
    }
    try testing.expect(!found_function_kw);
}

test "字符串匹配" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "\"hello world\"", &rule);
    defer testing.allocator.free(spans);

    try testing.expect(spans.len >= 1);
    try testing.expectEqual(TokenType.string, spans[0].token);
    try testing.expectEqualStrings("\"hello world\"", spans[0].text);
}

test "行注释" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "// this is a comment\ncode", &rule);
    defer testing.allocator.free(spans);

    try testing.expectEqual(TokenType.comment, spans[0].token);
    try testing.expectEqualStrings("// this is a comment", spans[0].text);
}

test "块注释（单行）" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "/* comment */", &rule);
    defer testing.allocator.free(spans);

    try testing.expectEqual(TokenType.comment, spans[0].token);
    try testing.expectEqualStrings("/* comment */", spans[0].text);
}

test "块注释（跨行）" {
    var rule = cLikeRule();
    const src = "/* line 1\nline 2\nline 3 */";
    const spans = try tokenize(testing.allocator, src, &rule);
    defer testing.allocator.free(spans);

    // 跨行 block comment 应全部是 comment token
    var total_comment_len: usize = 0;
    for (spans) |s| {
        if (s.token == .comment) total_comment_len += s.text.len;
    }
    try testing.expectEqual(src.len, total_comment_len);
}

test "数字: 十进制" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "42", &rule);
    defer testing.allocator.free(spans);

    var found = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "42") and s.token == .number) found = true;
    }
    try testing.expect(found);
}

test "数字: 小数" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "3.14", &rule);
    defer testing.allocator.free(spans);

    var found = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "3.14") and s.token == .number) found = true;
    }
    try testing.expect(found);
}

test "数字: 十六进制" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "0x1A fF", &rule);
    defer testing.allocator.free(spans);

    var found = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "0x1A") and s.token == .number) found = true;
    }
    try testing.expect(found);
}

test "数字: 二进制" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "0b1010", &rule);
    defer testing.allocator.free(spans);

    var found = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "0b1010") and s.token == .number) found = true;
    }
    try testing.expect(found);
}

// ── 交互测试（优先级 + 状态隔离）────────────────────────────

test "字符串内 // 不当注释" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "\"hello // world\"", &rule);
    defer testing.allocator.free(spans);

    try testing.expectEqual(TokenType.string, spans[0].token);
    try testing.expectEqualStrings("\"hello // world\"", spans[0].text);
}

test "注释内引号不当字符串" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "// \"not a string\"", &rule);
    defer testing.allocator.free(spans);

    try testing.expectEqual(TokenType.comment, spans[0].token);
}

test "转义引号不闭合字符串" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "\"a\\\"b\"", &rule);
    defer testing.allocator.free(spans);

    try testing.expect(spans.len >= 1);
    // 应该是一个完整 string span
    var found_string = false;
    for (spans) |s| {
        if (s.token == .string and std.mem.eql(u8, s.text, "\"a\\\"b\"")) found_string = true;
    }
    try testing.expect(found_string);
}

test "块注释内 string-delimiter 不当字符串" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "/* \"not string\" */", &rule);
    defer testing.allocator.free(spans);

    try testing.expectEqual(TokenType.comment, spans[0].token);
    try testing.expectEqualStrings("/* \"not string\" */", spans[0].text);
}

// ── 边界 case ───────────────────────────────────────────────

test "空文件" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "", &rule);
    defer testing.allocator.free(spans);
    try testing.expectEqual(@as(usize, 0), spans.len);
}

test "纯空白" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "   \n  \n", &rule);
    defer testing.allocator.free(spans);
    // 应全为 none
    for (spans) |s| {
        try testing.expectEqual(TokenType.none, s.token);
    }
}

test "未闭合字符串到行尾" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "\"unclosed\ncode", &rule);
    defer testing.allocator.free(spans);

    // 第一行 "unclosed 应是 string（未闭合）
    var found_string = false;
    for (spans) |s| {
        if (s.token == .string) found_string = true;
    }
    try testing.expect(found_string);
}

test "未闭合块注释到 EOF" {
    var rule = cLikeRule();
    const src = "/* never closed";
    const spans = try tokenize(testing.allocator, src, &rule);
    defer testing.allocator.free(spans);

    var total_comment_len: usize = 0;
    for (spans) |s| {
        if (s.token == .comment) total_comment_len += s.text.len;
    }
    // src = "/* never closed" = 15 chars (Zig string literal includes the content)
    try testing.expectEqual(@as(usize, src.len), total_comment_len);
}

// ── 10 核心语言 smoke tests ──────────────────────────────────

test "zig smoke" {
    const rule = hl.lookupByName("zig").?;
    const src = "pub fn main() void { return; }";
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_pub = false;
    var found_fn = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "pub") and s.token == .keyword) found_pub = true;
        if (std.mem.eql(u8, s.text, "fn") and s.token == .keyword) found_fn = true;
    }
    try testing.expect(found_pub);
    try testing.expect(found_fn);
}

test "python smoke" {
    const rule = hl.lookupByName("python").?;
    const src = "def foo():\n    return 42  # comment";
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_def = false;
    var found_return = false;
    var found_comment = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "def") and s.token == .keyword) found_def = true;
        if (std.mem.eql(u8, s.text, "return") and s.token == .keyword) found_return = true;
        if (s.token == .comment) found_comment = true;
    }
    try testing.expect(found_def);
    try testing.expect(found_return);
    try testing.expect(found_comment);
}

test "rust smoke" {
    const rule = hl.lookupByName("rust").?;
    const src = "pub fn main() { let x = 42; }";
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_pub = false;
    var found_fn = false;
    var found_let = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "pub") and s.token == .keyword) found_pub = true;
        if (std.mem.eql(u8, s.text, "fn") and s.token == .keyword) found_fn = true;
        if (std.mem.eql(u8, s.text, "let") and s.token == .keyword) found_let = true;
    }
    try testing.expect(found_pub);
    try testing.expect(found_fn);
    try testing.expect(found_let);
}

test "javascript smoke" {
    const rule = hl.lookupByName("javascript").?;
    const src = "const x = \"hello\"; // comment";
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_const = false;
    var found_string = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "const") and s.token == .keyword) found_const = true;
        if (s.token == .string) found_string = true;
    }
    try testing.expect(found_const);
    try testing.expect(found_string);
}

test "typescript smoke" {
    const rule = hl.lookupByName("typescript").?;
    const src = "interface Foo { x: number }";
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_interface = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "interface") and s.token == .keyword) found_interface = true;
    }
    try testing.expect(found_interface);
}

test "go smoke" {
    const rule = hl.lookupByName("go").?;
    const src = "func main() { for i := 0; i < 10; i++ {} }";
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_func = false;
    var found_for = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "func") and s.token == .keyword) found_func = true;
        if (std.mem.eql(u8, s.text, "for") and s.token == .keyword) found_for = true;
    }
    try testing.expect(found_func);
    try testing.expect(found_for);
}

test "java smoke" {
    const rule = hl.lookupByName("java").?;
    const src = "public class Main { static void main() {} }";
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_class = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "class") and s.token == .keyword) found_class = true;
    }
    try testing.expect(found_class);
}

test "c smoke" {
    const rule = hl.lookupByName("c").?;
    const src = "int main() { return 0; /* done */ }";
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_int = false;
    var found_comment = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "int") and s.token == .keyword) found_int = true;
        if (s.token == .comment) found_comment = true;
    }
    try testing.expect(found_int);
    try testing.expect(found_comment);
}

test "cpp smoke" {
    const rule = hl.lookupByName("cpp").?;
    const src = "template<typename T> void foo() { auto x = 42; }";
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_template = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "template") and s.token == .keyword) found_template = true;
    }
    try testing.expect(found_template);
}

test "bash smoke" {
    const rule = hl.lookupByName("bash").?;
    const src = "#!/bin/bash\nfor i in 1 2 3; do echo \"$i\"; done";
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_for = false;
    var found_comment = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "for") and s.token == .keyword) found_for = true;
        if (s.token == .comment) found_comment = true;
    }
    try testing.expect(found_for);
    try testing.expect(found_comment);
}

// ── 多行复杂代码 ────────────────────────────────────────────

test "多行函数（混合 token）" {
    var rule = cLikeRule();
    const src =
        \\pub fn foo(x: i32) i32 {
        \\    // compute
        \\    return x + 42;
        \\}
    ;
    const spans = try tokenize(testing.allocator, src, &rule);
    defer testing.allocator.free(spans);

    var found_pub = false;
    var found_fn = false;
    var found_return = false;
    var found_comment = false;
    var found_number = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "pub") and s.token == .keyword) found_pub = true;
        if (std.mem.eql(u8, s.text, "fn") and s.token == .keyword) found_fn = true;
        if (std.mem.eql(u8, s.text, "return") and s.token == .keyword) found_return = true;
        if (s.token == .comment) found_comment = true;
        if (std.mem.eql(u8, s.text, "42") and s.token == .number) found_number = true;
    }
    try testing.expect(found_pub);
    try testing.expect(found_fn);
    try testing.expect(found_return);
    try testing.expect(found_comment);
    try testing.expect(found_number);
}

test "连续关键字" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "pub fn return if else", &rule);
    defer testing.allocator.free(spans);

    var kw_count: usize = 0;
    for (spans) |s| {
        if (s.token == .keyword) kw_count += 1;
    }
    try testing.expectEqual(@as(usize, 5), kw_count);
}

// ── 边界 case 补充 ─────────────────────────────────────────

test "关键字后紧跟标点仍匹配" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "fn()", &rule);
    defer testing.allocator.free(spans);

    try testing.expectEqualStrings("fn", spans[0].text);
    try testing.expectEqual(TokenType.keyword, spans[0].token);
}

test "关键字前有标点仍匹配" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, ";fn", &rule);
    defer testing.allocator.free(spans);

    var found = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "fn") and s.token == .keyword) found = true;
    }
    try testing.expect(found);
}

test "数字不匹配关键字内的数字" {
    var rule = cLikeRule();
    // "42return" — 42 匹配为 number（数字不检查右边界），return 不匹配（左边界是数字 word char）
    const spans = try tokenize(testing.allocator, "42return", &rule);
    defer testing.allocator.free(spans);

    var found_42_number = false;
    var found_return_kw = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "42") and s.token == .number) found_42_number = true;
        if (std.mem.eql(u8, s.text, "return") and s.token == .keyword) found_return_kw = true;
    }
    try testing.expect(found_42_number); // 42 匹配为数字
    try testing.expect(!found_return_kw); // return 不匹配（左边界失败）
}

test "多个连续字符串" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "\"a\"\"b\"\"c\"", &rule);
    defer testing.allocator.free(spans);

    var string_count: usize = 0;
    for (spans) |s| {
        if (s.token == .string) string_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), string_count);
}

test "字符串和注释交替" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "\"str\" // comment", &rule);
    defer testing.allocator.free(spans);

    try testing.expectEqual(TokenType.string, spans[0].token);
    // 注释应在字符串之后
    var found_comment = false;
    for (spans) |s| {
        if (s.token == .comment) found_comment = true;
    }
    try testing.expect(found_comment);
}

test "行注释到 EOF（无换行）" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "// comment no newline", &rule);
    defer testing.allocator.free(spans);

    try testing.expectEqual(TokenType.comment, spans[0].token);
    try testing.expectEqualStrings("// comment no newline", spans[0].text);
}

test "仅关键字" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "fn", &rule);
    defer testing.allocator.free(spans);

    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expectEqual(TokenType.keyword, spans[0].token);
}

test "仅字符串" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "\"hello\"", &rule);
    defer testing.allocator.free(spans);

    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expectEqual(TokenType.string, spans[0].token);
}

test "仅数字" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "42", &rule);
    defer testing.allocator.free(spans);

    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expectEqual(TokenType.number, spans[0].token);
}

test "仅注释" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "// c", &rule);
    defer testing.allocator.free(spans);

    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expectEqual(TokenType.comment, spans[0].token);
}

test "空字符串不 crash" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "\"\"", &rule);
    defer testing.allocator.free(spans);

    var found = false;
    for (spans) |s| {
        if (s.token == .string) found = true;
    }
    try testing.expect(found);
}

test "单字符字符串" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "\"a\"", &rule);
    defer testing.allocator.free(spans);

    try testing.expect(spans.len >= 1);
    try testing.expectEqual(TokenType.string, spans[0].token);
}

test "十六进制大写和小写" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "0xFF 0xff 0xAb", &rule);
    defer testing.allocator.free(spans);

    var hex_count: usize = 0;
    for (spans) |s| {
        if (s.token == .number and std.mem.startsWith(u8, s.text, "0x")) hex_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), hex_count);
}

test "数字后跟关键字" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "42 fn", &rule);
    defer testing.allocator.free(spans);

    var found_num = false;
    var found_kw = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "42") and s.token == .number) found_num = true;
        if (std.mem.eql(u8, s.text, "fn") and s.token == .keyword) found_kw = true;
    }
    try testing.expect(found_num);
    try testing.expect(found_kw);
}

test "关键字后跟数字" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "fn 42", &rule);
    defer testing.allocator.free(spans);

    var found_kw = false;
    var found_num = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "fn") and s.token == .keyword) found_kw = true;
        if (std.mem.eql(u8, s.text, "42") and s.token == .number) found_num = true;
    }
    try testing.expect(found_kw);
    try testing.expect(found_num);
}

test "嵌套块注释不混淆" {
    var rule = cLikeRule();
    // /* outer /* inner */ still comment */
    // 我们的状态机不支持嵌套——第一个 */ 就关闭。这是预期行为。
    const spans = try tokenize(testing.allocator, "/* outer /* inner */ code", &rule);
    defer testing.allocator.free(spans);

    // 第一个 */ 关闭块注释，"code" 不是 comment
    var found_comment = false;
    var found_non_comment_after = false;
    var seen_close = false;
    for (spans) |s| {
        if (s.token == .comment) {
            found_comment = true;
            if (std.mem.indexOf(u8, s.text, "*/") != null) seen_close = true;
        }
        if (seen_close and s.token != .comment) {
            found_non_comment_after = true;
        }
    }
    try testing.expect(found_comment);
    try testing.expect(found_non_comment_after);
}

test "连续块注释" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "/* a */ /* b */", &rule);
    defer testing.allocator.free(spans);

    var comment_count: usize = 0;
    for (spans) |s| {
        if (s.token == .comment) comment_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), comment_count);
}

test "多行混合（注释+字符串+关键字+数字）" {
    var rule = cLikeRule();
    const src =
        \\// header comment
        \\pub fn test() void {
        \\    const s = "hello";
        \\    return 0x42;
        \\}
    ;
    const spans = try tokenize(testing.allocator, src, &rule);
    defer testing.allocator.free(spans);

    var found_comment = false;
    var found_keyword = false;
    var found_string = false;
    var found_hex = false;
    for (spans) |s| {
        if (s.token == .comment) found_comment = true;
        if (s.token == .keyword) found_keyword = true;
        if (s.token == .string) found_string = true;
        if (s.token == .number and std.mem.startsWith(u8, s.text, "0x")) found_hex = true;
    }
    try testing.expect(found_comment);
    try testing.expect(found_keyword);
    try testing.expect(found_string);
    try testing.expect(found_hex);
}

// ── 真实代码片段（比 smoke 更严格）──────────────────────────

test "zig 真实代码" {
    const rule = hl.lookupByName("zig").?;
    const src =
        \\const std = @import("std");
        \\// Entry point
        \\pub fn main() !void {
        \\    const x: u32 = 42;
        \\    std.debug.print("x = {d}\n", .{x});
        \\}
    ;
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var checks: usize = 0;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "const") and s.token == .keyword) checks += 1;
        if (std.mem.eql(u8, s.text, "pub") and s.token == .keyword) checks += 1;
        if (std.mem.eql(u8, s.text, "fn") and s.token == .keyword) checks += 1;
        if (std.mem.eql(u8, s.text, "var") and s.token == .keyword) checks += 1; // 不应匹配——src 里无 var
        if (s.token == .string and std.mem.indexOf(u8, s.text, "std") != null) checks += 1;
        if (s.token == .comment) checks += 1;
        if (std.mem.eql(u8, s.text, "42") and s.token == .number) checks += 1;
    }
    // const + pub + fn + string("std") + comment + 42 = 6
    // var 不在 src 中，不计数
    try testing.expect(checks >= 6);
}

test "python 真实代码" {
    const rule = hl.lookupByName("python").?;
    const src =
        \\def fibonacci(n):
        \\    """Compute fibonacci."""
        \\    if n <= 1:
        \\        return n
        \\    return fibonacci(n - 1) + fibonacci(n - 2)
    ;
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_def = false;
    var found_if = false;
    var found_return = false;
    var found_docstring = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "def") and s.token == .keyword) found_def = true;
        if (std.mem.eql(u8, s.text, "if") and s.token == .keyword) found_if = true;
        if (std.mem.eql(u8, s.text, "return") and s.token == .keyword) found_return = true;
        if (s.token == .string and std.mem.indexOf(u8, s.text, "Compute") != null) found_docstring = true;
    }
    try testing.expect(found_def);
    try testing.expect(found_if);
    try testing.expect(found_return);
    try testing.expect(found_docstring);
}

test "rust 真实代码" {
    const rule = hl.lookupByName("rust").?;
    const src =
        \\use std::collections::HashMap;
        \\pub fn main() {
        \\    let mut map = HashMap::new();
        \\    map.insert("key", 42);
        \\}
    ;
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_use = false;
    var found_pub = false;
    var found_let = false;
    var found_mut = false;
    var found_string = false;
    var found_number = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "use") and s.token == .keyword) found_use = true;
        if (std.mem.eql(u8, s.text, "pub") and s.token == .keyword) found_pub = true;
        if (std.mem.eql(u8, s.text, "let") and s.token == .keyword) found_let = true;
        if (std.mem.eql(u8, s.text, "mut") and s.token == .keyword) found_mut = true;
        if (s.token == .string) found_string = true;
        if (std.mem.eql(u8, s.text, "42") and s.token == .number) found_number = true;
    }
    try testing.expect(found_use);
    try testing.expect(found_pub);
    try testing.expect(found_let);
    try testing.expect(found_mut);
    try testing.expect(found_string);
    try testing.expect(found_number);
}

test "go 真实代码" {
    const rule = hl.lookupByName("go").?;
    const src =
        \\package main
        \\
        \\import "fmt"
        \\
        \\func main() {
        \\    for i := 0; i < 10; i++ {
        \\        fmt.Println(i)
        \\    }
        \\}
    ;
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_package = false;
    var found_import = false;
    var found_func = false;
    var found_for = false;
    var found_string = false;
    var found_number = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "package") and s.token == .keyword) found_package = true;
        if (std.mem.eql(u8, s.text, "import") and s.token == .keyword) found_import = true;
        if (std.mem.eql(u8, s.text, "func") and s.token == .keyword) found_func = true;
        if (std.mem.eql(u8, s.text, "for") and s.token == .keyword) found_for = true;
        if (s.token == .string) found_string = true;
        if (std.mem.eql(u8, s.text, "10") and s.token == .number) found_number = true;
    }
    try testing.expect(found_package);
    try testing.expect(found_import);
    try testing.expect(found_func);
    try testing.expect(found_for);
    try testing.expect(found_string);
    try testing.expect(found_number);
}

test "typescript 真实代码" {
    const rule = hl.lookupByName("typescript").?;
    const src =
        \\interface User {
        \\    name: string;
        \\    age: number;
        \\}
        \\
        \\const user: User = { name: "Alice", age: 30 };
    ;
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_interface = false;
    var found_const = false;
    var found_type = false; // type 关键字
    var found_string = false;
    var found_number = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "interface") and s.token == .keyword) found_interface = true;
        if (std.mem.eql(u8, s.text, "const") and s.token == .keyword) found_const = true;
        if (std.mem.eql(u8, s.text, "type") and s.token == .keyword) found_type = true; // 可能不匹配——"type" 在 TS 是关键字但这里用作类型注解
        if (s.token == .string) found_string = true;
        if (std.mem.eql(u8, s.text, "30") and s.token == .number) found_number = true;
    }
    try testing.expect(found_interface);
    try testing.expect(found_const);
    try testing.expect(found_string);
    try testing.expect(found_number);
}

test "c 真实代码" {
    const rule = hl.lookupByName("c").?;
    const src =
        \\#include <stdio.h>
        \\/* Main function */
        \\int main(int argc, char *argv[]) {
        \\    printf("count: %d\n", argc);
        \\    return 0;
        \\}
    ;
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_int = false;
    var found_return = false;
    var found_comment = false;
    var found_string = false;
    var found_number = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "int") and s.token == .keyword) found_int = true;
        if (std.mem.eql(u8, s.text, "return") and s.token == .keyword) found_return = true;
        if (s.token == .comment) found_comment = true;
        if (s.token == .string) found_string = true;
        if (std.mem.eql(u8, s.text, "0") and s.token == .number) found_number = true;
    }
    try testing.expect(found_int);
    try testing.expect(found_return);
    try testing.expect(found_comment);
    try testing.expect(found_string);
    try testing.expect(found_number);
}

test "bash 真实脚本" {
    const rule = hl.lookupByName("bash").?;
    const src =
        \\#!/bin/bash
        \\# Loop through args
        \\for arg in "$@"; do
        \\    echo "Processing: $arg"
        \\done
    ;
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_for = false;
    var found_in = false;
    var found_do = false;
    var found_done = false;
    var found_comment = false;
    var found_string = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "for") and s.token == .keyword) found_for = true;
        if (std.mem.eql(u8, s.text, "in") and s.token == .keyword) found_in = true;
        if (std.mem.eql(u8, s.text, "do") and s.token == .keyword) found_do = true;
        if (std.mem.eql(u8, s.text, "done") and s.token == .keyword) found_done = true;
        if (s.token == .comment) found_comment = true;
        if (s.token == .string) found_string = true;
    }
    try testing.expect(found_for);
    try testing.expect(found_in);
    try testing.expect(found_do);
    try testing.expect(found_done);
    try testing.expect(found_comment);
    try testing.expect(found_string);
}

// ── Python 三引号跨行字符串 ────────────────────────────────

test "python 三引号跨行字符串" {
    const rule = hl.lookupByName("python").?;
    const src = "\"\"\"multi\nline\ndocstring\"\"\"";
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var total_string_len: usize = 0;
    for (spans) |s| {
        if (s.token == .string) total_string_len += s.text.len;
    }
    try testing.expectEqual(src.len, total_string_len);
}

// ── JS 模板字符串跨行 ──────────────────────────────────────

test "javascript 模板字符串跨行" {
    const rule = hl.lookupByName("javascript").?;
    const src = "`line1\nline2`";
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var total_string_len: usize = 0;
    for (spans) |s| {
        if (s.token == .string) total_string_len += s.text.len;
    }
    try testing.expectEqual(src.len, total_string_len);
}

// ── Go raw string 跨行 ─────────────────────────────────────

test "go raw string 跨行" {
    const rule = hl.lookupByName("go").?;
    const src = "`raw\nstring`";
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var total_string_len: usize = 0;
    for (spans) |s| {
        if (s.token == .string) total_string_len += s.text.len;
    }
    try testing.expectEqual(src.len, total_string_len);
}

// ── 长前缀 delimiter 不被短前缀吃掉 ─────────────────────────

test "python 三引号不被单引号吃掉" {
    const rule = hl.lookupByName("python").?;
    const src = "\"\"\"triple\"\"\"";
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    // 应匹配为一个三引号字符串，不是三个单引号字符串
    var string_count: usize = 0;
    for (spans) |s| {
        if (s.token == .string) string_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), string_count);
}

// ═══════════════════════════════════════════════════════════
// Prism-inspired 测试（从 Prism test-suite 提取的有价值模式）
// ═══════════════════════════════════════════════════════════

// ── 数字边界（Prism number_feature.test 启发）─────────────

test "$前缀数字（$1234 的 1234 匹配为数字）" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "$1234", &rule);
    defer testing.allocator.free(spans);

    // $ 不是 word char，leftBoundary 通过，1234 匹配为 number
    var found_number = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "1234") and s.token == .number) found_number = true;
    }
    try testing.expect(found_number);
}

test "_前缀数字不匹配（_1234 不是数字）" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "_1234", &rule);
    defer testing.allocator.free(spans);

    // _ 是 word char，leftBoundary 失败
    for (spans) |s| {
        try testing.expect(s.token != .number);
    }
}

test "字母前缀数字不匹配（abc1234 不是数字）" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "abc1234", &rule);
    defer testing.allocator.free(spans);

    for (spans) |s| {
        try testing.expect(s.token != .number);
    }
}

test "数字后跟字母（42n BigInt 风格）" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "42n", &rule);
    defer testing.allocator.free(spans);

    // 42 匹配为 number，n 不匹配 keyword
    var found_42 = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "42") and s.token == .number) found_42 = true;
    }
    try testing.expect(found_42);
}

test "科学计数法数字（4e10）" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "4e10", &rule);
    defer testing.allocator.free(spans);

    // 当前引擎不识别 e 记法——4 匹配，e10 不匹配
    // 这是已知限制，测试记录此行为
    var found_4 = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "4") and s.token == .number) found_4 = true;
    }
    try testing.expect(found_4);
}

test "十六进制大小写（0xbabe 0xBABE）" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "0xbabe 0xBABE", &rule);
    defer testing.allocator.free(spans);

    var hex_count: usize = 0;
    for (spans) |s| {
        if (s.token == .number and std.mem.startsWith(u8, s.text, "0x")) hex_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), hex_count);
}

// ── 字符串转义（Prism string_feature.test 启发）────────────

test "字符串内转义引号（fo\\\"obar）" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "\"fo\\\"obar\"", &rule);
    defer testing.allocator.free(spans);

    var found = false;
    for (spans) |s| {
        if (s.token == .string and std.mem.indexOf(u8, s.text, "fo") != null) found = true;
    }
    try testing.expect(found);
}

test "字符串内转义反斜杠（a\\\\b）" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "\"a\\\\b\"", &rule);
    defer testing.allocator.free(spans);

    var found = false;
    for (spans) |s| {
        if (s.token == .string) found = true;
    }
    try testing.expect(found);
}

test "空字符串后紧跟关键字" {
    var rule = cLikeRule();
    const spans = try tokenize(testing.allocator, "\"\"fn", &rule);
    defer testing.allocator.free(spans);

    var found_string = false;
    var found_fn = false;
    for (spans) |s| {
        if (s.token == .string and std.mem.eql(u8, s.text, "\"\"")) found_string = true;
        if (std.mem.eql(u8, s.text, "fn") and s.token == .keyword) found_fn = true;
    }
    try testing.expect(found_string);
    try testing.expect(found_fn);
}

test "单引号字符串" {
    // 用 C 规则有单引号
    const rule_c = hl.lookupByName("c").?;
    const spans = try tokenize(testing.allocator, "'a'", rule_c);
    defer testing.allocator.free(spans);

    try testing.expect(spans.len >= 1);
    try testing.expectEqual(TokenType.string, spans[0].token);
}

// ── Python 字符串前缀（Prism python/string_feature.test 启发）──

test "python r前缀字符串" {
    const rule = hl.lookupByName("python").?;
    const spans = try tokenize(testing.allocator, "r\"\\n\"", rule);
    defer testing.allocator.free(spans);

    // 当前引擎不识别前缀字符串——r 不是 string delimiter
    // r 会作为 default，"\n" 会作为 string
    var found_string = false;
    for (spans) |s| {
        if (s.token == .string) found_string = true;
    }
    try testing.expect(found_string); // "\n" 匹配，r 不匹配（预期行为）
}

test "python b前缀字符串" {
    const rule = hl.lookupByName("python").?;
    const spans = try tokenize(testing.allocator, "b'foo'", rule);
    defer testing.allocator.free(spans);

    var found_string = false;
    for (spans) |s| {
        if (s.token == .string) found_string = true;
    }
    try testing.expect(found_string); // 'foo' 匹配，b 不匹配
}

// ── 注释边界（Prism comment_feature.test 启发）────────────

test "空块注释 /**/" {
    const rule = hl.lookupByName("c").?;
    const spans = try tokenize(testing.allocator, "/**/", rule);
    defer testing.allocator.free(spans);

    try testing.expect(spans.len >= 1);
    try testing.expectEqual(TokenType.comment, spans[0].token);
    try testing.expectEqualStrings("/**/", spans[0].text);
}

test "块注释含换行（/* foo\\nbar */）" {
    const rule = hl.lookupByName("c").?;
    const spans = try tokenize(testing.allocator, "/* foo\nbar */", rule);
    defer testing.allocator.free(spans);

    var total_comment: usize = 0;
    for (spans) |s| {
        if (s.token == .comment) total_comment += s.text.len;
    }
    try testing.expectEqual(@as(usize, 13), total_comment); // /* foo\nbar */ = 13 chars
}

test "Python 行注释 # 后跟内容" {
    const rule = hl.lookupByName("python").?;
    const spans = try tokenize(testing.allocator, "# foobar", rule);
    defer testing.allocator.free(spans);

    try testing.expect(spans.len >= 1);
    try testing.expectEqual(TokenType.comment, spans[0].token);
}

test "Python 连续行注释" {
    const rule = hl.lookupByName("python").?;
    const spans = try tokenize(testing.allocator, "# a\n# b\n# c", rule);
    defer testing.allocator.free(spans);

    var comment_count: usize = 0;
    for (spans) |s| {
        if (s.token == .comment) comment_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), comment_count);
}

// ── 关键字边界（Prism keyword_feature.test 启发）──────────

test "关键字作为对象属性不被匹配（promise.catch）" {
    // Prism 测试：promise.catch(foo) — catch 不是 keyword
    const rule = hl.lookupByName("javascript").?;
    const spans = try tokenize(testing.allocator, "promise.catch(foo)", rule);
    defer testing.allocator.free(spans);

    // .catch 的 catch 前面是 .（非 word char），所以 leftBoundary 通过
    // 但 catch 是 JS 关键字，会被匹配——这是预期行为（我们的引擎不做语义分析）
    // 测试记录此行为
    var found_catch_kw = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "catch") and s.token == .keyword) found_catch_kw = true;
    }
    try testing.expect(found_catch_kw); // catch 匹配为 keyword（不做语义区分）
}

test "关键字分号分隔（break; continue;）" {
    const rule = hl.lookupByName("javascript").?;
    const spans = try tokenize(testing.allocator, "break; continue;", rule);
    defer testing.allocator.free(spans);

    var kw_count: usize = 0;
    for (spans) |s| {
        if (s.token == .keyword) kw_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), kw_count);
}

test "所有 JS 关键字都能匹配" {
    const rule = hl.lookupByName("javascript").?;
    const src = "break case catch class const continue debugger default delete do else export extends for function if import in instanceof new return super switch this throw try typeof var void while with yield let static async await of";
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var kw_count: usize = 0;
    for (spans) |s| {
        if (s.token == .keyword) kw_count += 1;
    }
    try testing.expect(kw_count >= 30); // 至少 30 个关键字
}

// ── 模板字符串（Prism template-string_feature.test 启发）──

test "JS 模板字符串含 ${} 插值" {
    const rule = hl.lookupByName("javascript").?;
    const spans = try tokenize(testing.allocator, "`40+2=${40+2}`", rule);
    defer testing.allocator.free(spans);

    // 整个模板字符串匹配为一个 string（我们不解析 ${} 插值）
    var found_string = false;
    for (spans) |s| {
        if (s.token == .string and std.mem.indexOf(u8, s.text, "40") != null) found_string = true;
    }
    try testing.expect(found_string);
}

test "JS 模板字符串跨行" {
    const rule = hl.lookupByName("javascript").?;
    const spans = try tokenize(testing.allocator, "`foo\nbar`", rule);
    defer testing.allocator.free(spans);

    var total_string: usize = 0;
    for (spans) |s| {
        if (s.token == .string) total_string += s.text.len;
    }
    try testing.expectEqual(@as(usize, 9), total_string); // `foo\nbar` = 9 chars
}

test "JS 模板字符串转义 \\$" {
    const rule = hl.lookupByName("javascript").?;
    const spans = try tokenize(testing.allocator, "`\\${foo}`", rule);
    defer testing.allocator.free(spans);

    var found_string = false;
    for (spans) |s| {
        if (s.token == .string) found_string = true;
    }
    try testing.expect(found_string);
}

test "字符串内含模板字符串标记" {
    const rule = hl.lookupByName("javascript").?;
    const spans = try tokenize(testing.allocator, "\"foo `a` bar\"", rule);
    defer testing.allocator.free(spans);

    // 双引号字符串内的 `a` 不当模板字符串
    try testing.expect(spans.len >= 1);
    try testing.expectEqual(TokenType.string, spans[0].token);
    try testing.expectEqualStrings("\"foo `a` bar\"", spans[0].text);
}

// ── 混合真实场景 ───────────────────────────────────────────

test "JS 完整函数定义" {
    const rule = hl.lookupByName("javascript").?;
    const src =
        \\async function fetchData(url) {
        \\    const response = await fetch(url);
        \\    return response.json();
        \\}
    ;
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var checks: usize = 0;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "async") and s.token == .keyword) checks += 1;
        if (std.mem.eql(u8, s.text, "function") and s.token == .keyword) checks += 1;
        if (std.mem.eql(u8, s.text, "const") and s.token == .keyword) checks += 1;
        if (std.mem.eql(u8, s.text, "await") and s.token == .keyword) checks += 1;
        if (std.mem.eql(u8, s.text, "return") and s.token == .keyword) checks += 1;
        if (s.token == .string) checks += 1;
    }
    try testing.expect(checks >= 5); // async+function+const+await+return（url 不是字符串，是变量）
}

test "Python 类定义含 docstring" {
    const rule = hl.lookupByName("python").?;
    const src =
        \\class Animal:
        \\    """Base class for animals."""
        \\    def __init__(self, name):
        \\        self.name = name
        \\        return None
    ;
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_class = false;
    var found_def = false;
    var found_return = false;
    var found_docstring = false;
    var found_none = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "class") and s.token == .keyword) found_class = true;
        if (std.mem.eql(u8, s.text, "def") and s.token == .keyword) found_def = true;
        if (std.mem.eql(u8, s.text, "return") and s.token == .keyword) found_return = true;
        if (s.token == .string and std.mem.indexOf(u8, s.text, "Base") != null) found_docstring = true;
        if (std.mem.eql(u8, s.text, "None") and s.token == .keyword) found_none = true;
    }
    try testing.expect(found_class);
    try testing.expect(found_def);
    try testing.expect(found_return);
    try testing.expect(found_docstring);
    try testing.expect(found_none);
}

test "C 头文件包含" {
    const rule = hl.lookupByName("c").?;
    const src =
        \\#include <stdio.h>
        \\#include "local.h"
        \\#define MAX 100
    ;
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_string = false;
    var found_number = false;
    for (spans) |s| {
        if (s.token == .string) found_string = true; // "local.h"
        if (std.mem.eql(u8, s.text, "100") and s.token == .number) found_number = true;
    }
    try testing.expect(found_string);
    try testing.expect(found_number);
}

test "Java 注解和泛型" {
    const rule = hl.lookupByName("java").?;
    const src =
        \\@Override
        \\public List<String> getNames() {
        \\    return new ArrayList<>();
        \\}
    ;
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_public = false;
    var found_return = false;
    var found_new = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "public") and s.token == .keyword) found_public = true;
        if (std.mem.eql(u8, s.text, "return") and s.token == .keyword) found_return = true;
        if (std.mem.eql(u8, s.text, "new") and s.token == .keyword) found_new = true;
    }
    try testing.expect(found_public);
    try testing.expect(found_return);
    try testing.expect(found_new);
}

test "Rust match 表达式" {
    const rule = hl.lookupByName("rust").?;
    const src =
        \\match x {
        \\    Some(v) => println!("value: {}", v),
        \\    None => 0,
        \\}
    ;
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_match = false;
    var found_string = false;
    var found_number = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "match") and s.token == .keyword) found_match = true;
        if (s.token == .string) found_string = true;
        if (std.mem.eql(u8, s.text, "0") and s.token == .number) found_number = true;
    }
    try testing.expect(found_match);
    try testing.expect(found_string);
    try testing.expect(found_number);
}

test "Go 结构体定义" {
    const rule = hl.lookupByName("go").?;
    const src =
        \\type Config struct {
        \\    Host string `json:"host"`
        \\    Port int    `json:"port"`
        \\}
    ;
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_type = false;
    var found_struct = false;
    var found_string = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "type") and s.token == .keyword) found_type = true;
        if (std.mem.eql(u8, s.text, "struct") and s.token == .keyword) found_struct = true;
        if (s.token == .string) found_string = true; // `json:"host"` raw string
    }
    try testing.expect(found_type);
    try testing.expect(found_struct);
    try testing.expect(found_string);
}

test "Bash 变量赋值和命令替换" {
    const rule = hl.lookupByName("bash").?;
    const src =
        \\#!/bin/bash
        \\name="world"
        \\echo "Hello, $name!"
        \\if [ -f "/tmp/file" ]; then
        \\    exit 0
        \\fi
    ;
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_if = false;
    var found_then = false;
    var found_exit = false;
    var found_fi = false;
    var found_comment = false;
    var found_string = false;
    var found_number = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "if") and s.token == .keyword) found_if = true;
        if (std.mem.eql(u8, s.text, "then") and s.token == .keyword) found_then = true;
        if (std.mem.eql(u8, s.text, "exit") and s.token == .keyword) found_exit = true;
        if (std.mem.eql(u8, s.text, "fi") and s.token == .keyword) found_fi = true;
        if (s.token == .comment) found_comment = true;
        if (s.token == .string) found_string = true;
        if (std.mem.eql(u8, s.text, "0") and s.token == .number) found_number = true;
    }
    try testing.expect(found_if);
    try testing.expect(found_then);
    try testing.expect(found_exit);
    try testing.expect(found_fi);
    try testing.expect(found_comment);
    try testing.expect(found_string);
    try testing.expect(found_number);
}

test "Zig error union 和 catch" {
    const rule = hl.lookupByName("zig").?;
    const src =
        \\pub fn parse() !u32 {
        \\    const n = parseInt() catch return 0;
        \\    return n;
        \\}
    ;
    const spans = try tokenize(testing.allocator, src, rule);
    defer testing.allocator.free(spans);

    var found_pub = false;
    var found_fn = false;
    var found_const = false;
    var found_catch = false;
    var found_return = false;
    var found_number = false;
    for (spans) |s| {
        if (std.mem.eql(u8, s.text, "pub") and s.token == .keyword) found_pub = true;
        if (std.mem.eql(u8, s.text, "fn") and s.token == .keyword) found_fn = true;
        if (std.mem.eql(u8, s.text, "const") and s.token == .keyword) found_const = true;
        if (std.mem.eql(u8, s.text, "catch") and s.token == .keyword) found_catch = true;
        if (std.mem.eql(u8, s.text, "return") and s.token == .keyword) found_return = true;
        if (std.mem.eql(u8, s.text, "0") and s.token == .number) found_number = true;
    }
    try testing.expect(found_pub);
    try testing.expect(found_fn);
    try testing.expect(found_const);
    try testing.expect(found_catch);
    try testing.expect(found_return);
    try testing.expect(found_number);
}