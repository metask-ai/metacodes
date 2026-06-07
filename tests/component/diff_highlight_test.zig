//! L2 组件测试:Edit/Write diff 的 tree-sitter 语法高亮(旁路缓存路径)。
//! DoD:证明"缓存命中 → tree-sitter span 着色生效";"无缓存 → 退回关键字表(零回归)"。
//!
//! 走 tool_card.renderResult(传 opts.edit_hl_cache + opts.tool_id),断言着色字节。

const std = @import("std");
const cc = @import("cc");

const tool_card = cc.tool_card;
const theme_mod = cc.tui_theme;
const EditHlCache = cc.core_edit_hl_cache.EditHlCache;

// ANSI 色常量(与 groupColor 复刻的 ansi.sgr 一致)。
const MAGENTA = "\x1b[35m"; // keyword
const YELLOW = "\x1b[33m"; // number/constant
const GREEN = "\x1b[32m"; // string
const BLUE = "\x1b[34m"; // type

test "diff 高亮: 缓存命中 → tree-sitter span 着色(zig const=magenta, 数字=yellow)" {
    const a = std.testing.allocator;
    const th = theme_mod.dark;

    var cache = EditHlCache.init(a);
    defer cache.deinit();

    // 新文件全文(Edit 后的内容)。tool_id = "tid-1"。
    const new_full = "const answer = 42;\nconst name = \"hi\";\n";
    cache.put("tid-1", "const answer = 0;\nconst name = \"hi\";\n", new_full);

    // gitDiff 引用 .zig 文件,add 行 = 新文件第 1 行(字节匹配)。
    const out_json = "{\"success\":true,\"file_path\":\"/proj/x.zig\",\"gitDiff\":\"--- a/x.zig\\n+++ b/x.zig\\n@@ -1,1 +1,1 @@\\n-const answer = 0;\\n+const answer = 42;\\n const name = \\\"hi\\\";\\n\"}";

    const s = try tool_card.renderResult(a, th, "Edit", "{\"file_path\":\"/proj/x.zig\"}", out_json, .ok, 100, .{
        .transcript = true,
        .edit_hl_cache = &cache,
        .tool_id = "tid-1",
    });
    defer a.free(s);

    // tree-sitter 路径:const → keyword(magenta),42 → number(yellow)。
    try std.testing.expect(std.mem.indexOf(u8, s, MAGENTA) != null); // const
    try std.testing.expect(std.mem.indexOf(u8, s, YELLOW) != null); // 42
    // 内容词仍在。
    try std.testing.expect(std.mem.indexOf(u8, s, "answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "42") != null);
}

test "diff 高亮: 无缓存 → 退回关键字表(零回归,仍着色不崩)" {
    const a = std.testing.allocator;
    const th = theme_mod.dark;

    const out_json = "{\"success\":true,\"file_path\":\"/x.zig\",\"gitDiff\":\"--- a/x.zig\\n+++ b/x.zig\\n@@ -1,1 +1,1 @@\\n-const b = 2;\\n+const b = 20;\\n\"}";
    // 不传 edit_hl_cache → 退回关键字表。
    const s = try tool_card.renderResult(a, th, "Edit", "{\"file_path\":\"/x.zig\"}", out_json, .ok, 100, .{ .transcript = true });
    defer a.free(s);

    // 仍有内容 + 不崩。关键字表也给 const 上 magenta。
    try std.testing.expect(std.mem.indexOf(u8, s, "20") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, MAGENTA) != null);
}

test "diff 高亮: 缓存命中但行文本不匹配 → 退回关键字表" {
    const a = std.testing.allocator;
    const th = theme_mod.dark;

    var cache = EditHlCache.init(a);
    defer cache.deinit();
    // 缓存的新文件第 1 行 ≠ diff 的 add 行 → 字节不等 → 退回。
    cache.put("tid-x", "old", "completely different content here\n");

    const out_json = "{\"success\":true,\"file_path\":\"/x.zig\",\"gitDiff\":\"--- a/x.zig\\n+++ b/x.zig\\n@@ -1,1 +1,1 @@\\n+const b = 20;\\n\"}";
    const s = try tool_card.renderResult(a, th, "Edit", "{\"file_path\":\"/x.zig\"}", out_json, .ok, 100, .{
        .transcript = true,
        .edit_hl_cache = &cache,
        .tool_id = "tid-x",
    });
    defer a.free(s);
    // 不崩 + 内容在(退回关键字表)。
    try std.testing.expect(std.mem.indexOf(u8, s, "20") != null);
}

test "diff 高亮: 非 tree-sitter 语言(.md)→ 退回关键字表不崩" {
    const a = std.testing.allocator;
    const th = theme_mod.dark;

    var cache = EditHlCache.init(a);
    defer cache.deinit();
    cache.put("tid-md", "old\n", "# Title\nbody\n");

    const out_json = "{\"success\":true,\"file_path\":\"/x.md\",\"gitDiff\":\"--- a/x.md\\n+++ b/x.md\\n@@ -1,1 +1,1 @@\\n+# Title\\n\"}";
    const s = try tool_card.renderResult(a, th, "Edit", "{\"file_path\":\"/x.md\"}", out_json, .ok, 100, .{
        .transcript = true,
        .edit_hl_cache = &cache,
        .tool_id = "tid-md",
    });
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "Title") != null);
}

test "diff 高亮: truecolor theme → type 用 teal RGB(basic-16 给不出的区分色)" {
    const a = std.testing.allocator;
    // select(.dark,.truecolor) 的 syntax 是 RGB 调色板。
    const th = theme_mod.select(.dark, .truecolor);

    var cache = EditHlCache.init(a);
    defer cache.deinit();
    // 新文件含一个类型名(zig:Point 在 struct 上下文是 type)+ 函数返回类型。
    const new_full = "pub fn dist(a: Point) void {}\n";
    cache.put("tt", "old\n", new_full);

    const out_json = "{\"file_path\":\"/x.zig\",\"gitDiff\":\"@@ -1,1 +1,1 @@\\n+pub fn dist(a: Point) void {}\\n\"}";
    const s = try tool_card.renderResult(a, th, "Edit", "{\"file_path\":\"/x.zig\"}", out_json, .ok, 100, .{
        .transcript = true,
        .edit_hl_cache = &cache,
        .tool_id = "tt",
    });
    defer a.free(s);

    // truecolor:keyword(pub/fn)用 RGB 紫 #C586C0,而非 basic-16 的 \x1b[35m。
    try std.testing.expect(std.mem.indexOf(u8, s, "38;2;197;134;192") != null);
    // type(Point/void)用 teal RGB #4EC9B0(basic-16 给不出的区分色)。
    try std.testing.expect(std.mem.indexOf(u8, s, "38;2;78;201;176") != null);
    // 不应再出现 basic-16 的裸 keyword 紫(\x1b[35m),证明走了 truecolor 调色板。
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1b[35m") == null);
}

test "NotebookEdit: replace cell → diff + tree-sitter 高亮(lang=python)" {
    const a = std.testing.allocator;
    const th = theme_mod.select(.dark, .truecolor);

    var cache = EditHlCache.init(a);
    defer cache.deinit();
    // 模拟 NotebookEdit replace 后:缓存里是 cell 的旧/新 source。
    cache.put("nb1", "x = 1\n", "x = 42\nprint(x)\n");

    // 结果 JSON 带 lang=python + gitDiff(NotebookEdit 现在产出的格式)。
    const out_json = "{\"success\":true,\"path\":\"/n.ipynb\",\"mode\":\"replace\",\"cells_after\":2,\"lang\":\"python\",\"gitDiff\":\"@@ -1,1 +1,2 @@\\n-x = 1\\n+x = 42\\n+print(x)\\n\"}";
    const s = try tool_card.renderResult(a, th, "NotebookEdit", "{\"notebook_path\":\"/n.ipynb\"}", out_json, .ok, 100, .{
        .transcript = true,
        .edit_hl_cache = &cache,
        .tool_id = "nb1",
    });
    defer a.free(s);

    // 摘要行 "replace cell in n.ipynb"。
    try std.testing.expect(std.mem.indexOf(u8, s, "replace cell") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "n.ipynb") != null);
    // diff 内容行(add 的 print)+ tree-sitter 高亮:python number 42 用 truecolor RGB。
    try std.testing.expect(std.mem.indexOf(u8, s, "print") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "38;2;181;206;168") != null); // number RGB
    // 不再裸吐 JSON 字段。
    try std.testing.expect(std.mem.indexOf(u8, s, "cells_after") == null);
}

test "NotebookEdit: 无 gitDiff(纯结构改)→ 退回 JSON 摘要不崩" {
    const a = std.testing.allocator;
    const th = theme_mod.monochrome;
    // 无 gitDiff 字段 → 退回摘要。
    const out_json = "{\"success\":true,\"path\":\"/n.ipynb\",\"mode\":\"delete\",\"cells_after\":3}";
    const s = try tool_card.renderResult(a, th, "NotebookEdit", "{\"notebook_path\":\"/n.ipynb\"}", out_json, .ok, 100, .{});
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "delete /n.ipynb") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "cells_after") == null);
}
