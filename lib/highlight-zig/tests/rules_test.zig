const std = @import("std");
const hl = @import("hl");
const lookupByExtension = hl.lookupByExtension;
const lookupByName = hl.lookupByName;
const ruleCount = hl.rules.ruleCount;
const ruleAt = hl.rules.ruleAt;

const testing = std.testing;

test "扩展名查找 .zig → zig" {
    const r = lookupByExtension(".zig").?;
    try testing.expectEqualStrings("zig", r.name);
}

test "扩展名查找 .py → python" {
    const r = lookupByExtension(".py").?;
    try testing.expectEqualStrings("python", r.name);
}

test "扩展名查找 .js → javascript" {
    const r = lookupByExtension(".js").?;
    try testing.expectEqualStrings("javascript", r.name);
}

test "扩展名查找 .ts → typescript" {
    const r = lookupByExtension(".ts").?;
    try testing.expectEqualStrings("typescript", r.name);
}

test "扩展名查找 .rs → rust" {
    const r = lookupByExtension(".rs").?;
    try testing.expectEqualStrings("rust", r.name);
}

test "扩展名查找 .go → go" {
    const r = lookupByExtension(".go").?;
    try testing.expectEqualStrings("go", r.name);
}

test "扩展名查找 .java → java" {
    const r = lookupByExtension(".java").?;
    try testing.expectEqualStrings("java", r.name);
}

test "扩展名查找 .c → c" {
    const r = lookupByExtension(".c").?;
    try testing.expectEqualStrings("c", r.name);
}

test "扩展名查找 .cpp → cpp" {
    const r = lookupByExtension(".cpp").?;
    try testing.expectEqualStrings("cpp", r.name);
}

test "扩展名查找 .sh → bash" {
    const r = lookupByExtension(".sh").?;
    try testing.expectEqualStrings("bash", r.name);
}

test "别名查找 js → javascript" {
    const r = lookupByName("js").?;
    try testing.expectEqualStrings("javascript", r.name);
}

test "别名查找 ts → typescript" {
    const r = lookupByName("ts").?;
    try testing.expectEqualStrings("typescript", r.name);
}

test "别名查找 py → python" {
    const r = lookupByName("py").?;
    try testing.expectEqualStrings("python", r.name);
}

test "别名查找 shell → bash" {
    const r = lookupByName("shell").?;
    try testing.expectEqualStrings("bash", r.name);
}

test "名称查找 zig → zig" {
    const r = lookupByName("zig").?;
    try testing.expectEqualStrings("zig", r.name);
}

test "未知扩展名返回 null" {
    try testing.expect(lookupByExtension(".unknown") == null);
    try testing.expect(lookupByExtension(".xyz") == null);
}

test "空扩展名返回 null" {
    try testing.expect(lookupByExtension("") == null);
}

test "未知名称返回 null" {
    try testing.expect(lookupByName("unknown") == null);
    try testing.expect(lookupByName("") == null);
}

test "规则总数 >= 200" {
    try testing.expect(ruleCount() >= 200);
}

test "核心语言有关键字" {
    for ([_][]const u8{ "zig", "python", "rust", "javascript", "typescript", "go", "java", "c", "cpp", "bash" }) |name| {
        const r = lookupByName(name).?;
        try testing.expect(r.keywords.len > 0);
    }
}

test "核心语言有字符串 delimiter" {
    for ([_][]const u8{ "zig", "python", "rust", "javascript", "typescript", "go", "java", "c", "cpp", "bash" }) |name| {
        const r = lookupByName(name).?;
        try testing.expect(r.string_delims.len > 0);
    }
}

test "核心语言有扩展名" {
    for ([_][]const u8{ "zig", "python", "rust", "javascript", "typescript", "go", "java", "c", "cpp", "bash" }) |name| {
        const r = lookupByName(name).?;
        try testing.expect(r.extensions.len > 0);
    }
}

test ".h 同时匹配 c 和 cpp（c 先注册）" {
    // .h 在 c 和 cpp 都声明了，lookupByExtension 返回第一个匹配（c）
    const r = lookupByExtension(".h").?;
    try testing.expectEqualStrings("c", r.name);
}

// ── 每语言关键字数量验证 ───────────────────────────────────

test "zig 关键字数量 >= 40" {
    const r = lookupByName("zig").?;
    try testing.expect(r.keywords.len >= 40);
}

test "python 关键字数量 >= 35" {
    const r = lookupByName("python").?;
    try testing.expect(r.keywords.len >= 35);
}

test "rust 关键字数量 >= 50" {
    const r = lookupByName("rust").?;
    try testing.expect(r.keywords.len >= 50);
}

test "typescript 关键字数量 >= 40" {
    const r = lookupByName("typescript").?;
    try testing.expect(r.keywords.len >= 40);
}

test "javascript 关键字数量 >= 30" {
    const r = lookupByName("javascript").?;
    try testing.expect(r.keywords.len >= 30);
}

test "go 关键字数量 >= 25" {
    const r = lookupByName("go").?;
    try testing.expect(r.keywords.len >= 25);
}

test "java 关键字数量 >= 50" {
    const r = lookupByName("java").?;
    try testing.expect(r.keywords.len >= 50);
}

test "c 关键字数量 >= 30" {
    const r = lookupByName("c").?;
    try testing.expect(r.keywords.len >= 30);
}

test "cpp 关键字数量 >= 70" {
    const r = lookupByName("cpp").?;
    try testing.expect(r.keywords.len >= 70);
}

test "bash 关键字数量 >= 25" {
    const r = lookupByName("bash").?;
    try testing.expect(r.keywords.len >= 25);
}

// ── delimiter 配置验证 ─────────────────────────────────────

test "python 有三引号 multiline string" {
    const r = lookupByName("python").?;
    var found_triple = false;
    for (r.string_delims) |d| {
        if (std.mem.eql(u8, d.open, "\"\"\"") and d.multiline) found_triple = true;
    }
    try testing.expect(found_triple);
}

test "javascript 有模板字符串 multiline" {
    const r = lookupByName("javascript").?;
    var found_template = false;
    for (r.string_delims) |d| {
        if (std.mem.eql(u8, d.open, "`") and d.multiline) found_template = true;
    }
    try testing.expect(found_template);
}

test "go 有 raw string（反引号 multiline）" {
    const r = lookupByName("go").?;
    var found_raw = false;
    for (r.string_delims) |d| {
        if (std.mem.eql(u8, d.open, "`") and d.multiline) found_raw = true;
    }
    try testing.expect(found_raw);
}

test "c/cpp 有块注释" {
    const r_c = lookupByName("c").?;
    const r_cpp = lookupByName("cpp").?;
    try testing.expect(r_c.comment_block.len > 0);
    try testing.expect(r_cpp.comment_block.len > 0);
    try testing.expectEqualStrings("/*", r_c.comment_block[0][0]);
    try testing.expectEqualStrings("*/", r_c.comment_block[0][1]);
}

test "python 无块注释" {
    const r = lookupByName("python").?;
    try testing.expectEqual(@as(usize, 0), r.comment_block.len);
}

test "bash 无块注释" {
    const r = lookupByName("bash").?;
    try testing.expectEqual(@as(usize, 0), r.comment_block.len);
}

test "python 行注释用 #" {
    const r = lookupByName("python").?;
    var found = false;
    for (r.comment_line) |c| {
        if (std.mem.eql(u8, c, "#")) found = true;
    }
    try testing.expect(found);
}

test "bash 行注释用 #" {
    const r = lookupByName("bash").?;
    var found = false;
    for (r.comment_line) |c| {
        if (std.mem.eql(u8, c, "#")) found = true;
    }
    try testing.expect(found);
}

test "zig/rust/c/go 行注释包含 //" {
    for ([_][]const u8{ "zig", "rust", "c", "go", "java", "javascript", "typescript", "cpp" }) |name| {
        const r = lookupByName(name).?;
        var found = false;
        for (r.comment_line) |c| {
            if (std.mem.eql(u8, c, "//")) found = true;
        }
        try testing.expect(found);
    }
}

test "c/cpp 有 0x/0b/0o 数字前缀" {
    for ([_][]const u8{ "c", "cpp", "rust", "go", "java", "javascript", "typescript", "zig" }) |name| {
        const r = lookupByName(name).?;
        try testing.expect(r.number_prefix.len >= 3);
    }
}

test "python 有 0x/0b/0o 但无 0o（用 0o）" {
    const r = lookupByName("python").?;
    var found_0x = false;
    var found_0b = false;
    var found_0o = false;
    for (r.number_prefix) |p| {
        if (std.mem.eql(u8, p, "0x")) found_0x = true;
        if (std.mem.eql(u8, p, "0b")) found_0b = true;
        if (std.mem.eql(u8, p, "0o")) found_0o = true;
    }
    try testing.expect(found_0x);
    try testing.expect(found_0b);
    try testing.expect(found_0o);
}

// ── 扩展名覆盖验证 ─────────────────────────────────────────

test ".mjs → javascript" {
    try testing.expectEqualStrings("javascript", lookupByExtension(".mjs").?.name);
}

test ".mts → typescript" {
    try testing.expectEqualStrings("typescript", lookupByExtension(".mts").?.name);
}

test ".cc → cpp" {
    try testing.expectEqualStrings("cpp", lookupByExtension(".cc").?.name);
}

test ".hpp → cpp" {
    try testing.expectEqualStrings("cpp", lookupByExtension(".hpp").?.name);
}

test ".pyw → python" {
    try testing.expectEqualStrings("python", lookupByExtension(".pyw").?.name);
}

test ".bash → bash" {
    try testing.expectEqualStrings("bash", lookupByExtension(".bash").?.name);
}

// ── 关键字内容验证 ─────────────────────────────────────────

fn keywordPresent(packed_kw: []const u8, target: []const u8) bool {
    var start: usize = 0;
    var i: usize = 0;
    while (i <= packed_kw.len) : (i += 1) {
        if (i == packed_kw.len or packed_kw[i] == 0) {
            if (std.mem.eql(u8, packed_kw[start..i], target)) return true;
            start = i + 1;
        }
    }
    return false;
}

test "zig 包含 comptime 关键字" {
    const r = lookupByName("zig").?;
    try testing.expect(keywordPresent(r.keywords, "comptime"));
}

test "rust 包含 unsafe 关键字" {
    const r = lookupByName("rust").?;
    try testing.expect(keywordPresent(r.keywords, "unsafe"));
}

test "python 包含 lambda 关键字" {
    const r = lookupByName("python").?;
    try testing.expect(keywordPresent(r.keywords, "lambda"));
}

test "go 包含 func 关键字" {
    const r = lookupByName("go").?;
    try testing.expect(keywordPresent(r.keywords, "func"));
}

test "java 包含 synchronized 关键字" {
    const r = lookupByName("java").?;
    try testing.expect(keywordPresent(r.keywords, "synchronized"));
}

test "cpp 包含 constexpr 关键字" {
    const r = lookupByName("cpp").?;
    try testing.expect(keywordPresent(r.keywords, "constexpr"));
}

test "typescript 包含 interface 关键字" {
    const r = lookupByName("typescript").?;
    try testing.expect(keywordPresent(r.keywords, "interface"));
}

test "bash 包含 function 关键字" {
    const r = lookupByName("bash").?;
    try testing.expect(keywordPresent(r.keywords, "function"));
}

// ── 别名完整性 ─────────────────────────────────────────────

test "所有别名可查" {
    const n = ruleCount();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = ruleAt(i).?;
        for (r.aliases) |a| {
            const found = lookupByName(a).?;
            try testing.expectEqualStrings(r.name, found.name);
        }
    }
}

// ── 规则无重复关键字 ───────────────────────────────────────

test "每语言关键字无重复" {
    const n = ruleCount();
    var ri: usize = 0;
    while (ri < n) : (ri += 1) {
        const r = ruleAt(ri).?;
        // packed \0 分隔，逐个提取比较
        var seen = std.StringHashMap(void).init(std.testing.allocator);
        defer seen.deinit();
        var start: usize = 0;
        var i: usize = 0;
        while (i <= r.keywords.len) : (i += 1) {
            if (i == r.keywords.len or r.keywords[i] == 0) {
                const kw = r.keywords[start..i];
                if (kw.len > 0) {
                    if (seen.contains(kw)) {
                        try testing.expect(false); // 重复关键字
                    }
                    try seen.put(kw, {});
                }
                start = i + 1;
            }
        }
    }
}

// ── init/deinit + 内存安全 ──────────────────────────────────

test "init + deinit 无泄漏" {
    var r = try hl.rules.init(std.testing.allocator);
    defer r.deinit();
    try testing.expect(r.rules.len > 200);
    try testing.expect(r.data.len > 0);
}

test "init 后 ruleAt 一致" {
    var r = try hl.rules.init(std.testing.allocator);
    defer r.deinit();
    // 和全局缓存对比前 3 条
    const n = ruleCount();
    try testing.expectEqual(n, r.rules.len);
    var i: usize = 0;
    while (i < @min(n, 3)) : (i += 1) {
        try testing.expectEqualStrings(ruleAt(i).?.name, r.rules[i].name);
    }
}

test "init 可重复调用（独立实例）" {
    var a = try hl.rules.init(std.testing.allocator);
    defer a.deinit();
    var b = try hl.rules.init(std.testing.allocator);
    defer b.deinit();
    try testing.expectEqualStrings(a.rules[0].name, b.rules[0].name);
    // slice 指向各自 data，不共享
    try testing.expect(a.data.ptr != b.data.ptr);
}