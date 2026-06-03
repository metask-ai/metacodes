//! Markdown 子集 → ANSI 渲染。
//!
//! 支持：
//! - `**bold**` → ANSI bold
//! - `*italic*` → ANSI italic
//! - `` `code` `` → dim + 灰背景
//! - `### heading` → bold cyan（支持 #/##/###/####）
//! - ```` ```lang\n...\n``` ```` → 代码块（dim，前后换行）
//! - `- item` / `* item` → `  • item`
//!
//! 设计选择（有意保持简单）：
//! - 单遍扫描，不建 AST
//! - 行内 emphasis 解析：遇到 `**` / `*` / `` ` `` 成对配对；不成对按字面输出
//! - 代码块：` ``` ` 独占一行时切换状态
//! - 不支持嵌套 emphasis、表格、引用块——留到未来
//!
//! 调用：`renderToOwned(markdown, allocator) → []u8`

const std = @import("std");

// ANSI 常量(集中走 tui/ansi.zig;markdown 渲染不感知主题,关色用 NO_COLOR=1)
const ansi = @import("tui/ansi.zig");
const RESET = ansi.sgr.reset;
const BOLD = ansi.sgr.bold;
const DIM = ansi.sgr.dim;
const ITALIC = ansi.sgr.italic;
const CYAN = ansi.sgr.fg_cyan;
const GRAY = ansi.sgr.fg_bright_black;
const GREEN = ansi.sgr.fg_green;
const YELLOW = ansi.sgr.fg_yellow;
const MAGENTA = ansi.sgr.fg_magenta;
const BLUE = ansi.sgr.fg_blue;

pub fn renderToOwned(md: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var cursor: usize = 0;
    var in_code_block = false;
    var code_lang: []const u8 = "";
    var hl_state: HlState = .{};

    while (cursor < md.len) {
        // 行首：找下一行边界
        const line_end = std.mem.indexOfScalarPos(u8, md, cursor, '\n') orelse md.len;
        const line = md[cursor..line_end];
        const next = if (line_end < md.len) line_end + 1 else md.len;

        if (in_code_block) {
            if (std.mem.startsWith(u8, line, "```")) {
                try out.appendSlice(allocator, RESET);
                try out.append(allocator, '\n');
                in_code_block = false;
            } else {
                try highlightCodeLine(line, code_lang, &hl_state, GRAY, &out, allocator);
                try out.appendSlice(allocator, RESET);
                try out.append(allocator, '\n');
            }
        } else if (std.mem.startsWith(u8, line, "```")) {
            // 进入代码块：捕获语言标记用于高亮;重置跨行高亮状态。
            code_lang = std.mem.trim(u8, line[3..], " \t\r");
            hl_state = .{};
            try out.append(allocator, '\n');
            in_code_block = true;
        } else if (isHeading(line)) |h| {
            try renderHeading(line, h, &out, allocator);
            try out.append(allocator, '\n');
        } else if (isListItem(line)) |prefix_len| {
            try out.appendSlice(allocator, "  • ");
            try renderInline(line[prefix_len..], &out, allocator);
            try out.append(allocator, '\n');
        } else {
            try renderInline(line, &out, allocator);
            if (line_end < md.len) try out.append(allocator, '\n');
        }
        cursor = next;
    }

    if (in_code_block) {
        try out.appendSlice(allocator, RESET);
    }

    return try out.toOwnedSlice(allocator);
}

/// 返回 '#' 数量（1-4），非标题返 null。
fn isHeading(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len and i < 5 and line[i] == '#') : (i += 1) {}
    if (i == 0 or i > 4) return null;
    if (i >= line.len or line[i] != ' ') return null;
    return i;
}

/// 返回 list 前缀长度（"- " 或 "* "），非 list 返 null。
fn isListItem(line: []const u8) ?usize {
    if (line.len < 2) return null;
    if ((line[0] == '-' or line[0] == '*') and line[1] == ' ') return 2;
    return null;
}

fn renderHeading(line: []const u8, hash_count: usize, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try out.appendSlice(allocator, BOLD);
    try out.appendSlice(allocator, CYAN);
    try renderInline(line[hash_count + 1 ..], out, allocator);
    try out.appendSlice(allocator, RESET);
}

/// 行内：`**bold**` / `*italic*` / `` `code` ``。成对扫描。
fn renderInline(text: []const u8, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    var i: usize = 0;
    while (i < text.len) {
        // 代码 `...`
        if (text[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |close| {
                try out.appendSlice(allocator, DIM);
                try out.appendSlice(allocator, text[i + 1 .. close]);
                try out.appendSlice(allocator, RESET);
                i = close + 1;
                continue;
            }
        }

        // 粗体 **...**
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, text, i + 2, "**")) |close| {
                try out.appendSlice(allocator, BOLD);
                try out.appendSlice(allocator, text[i + 2 .. close]);
                try out.appendSlice(allocator, RESET);
                i = close + 2;
                continue;
            }
        }

        // 斜体 *...*（只在不是 ** 的时候）
        if (text[i] == '*' and (i + 1 >= text.len or text[i + 1] != '*')) {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '*')) |close| {
                // 保证不是 ** 的情况
                if (close + 1 >= text.len or text[close + 1] != '*') {
                    try out.appendSlice(allocator, ITALIC);
                    try out.appendSlice(allocator, text[i + 1 .. close]);
                    try out.appendSlice(allocator, RESET);
                    i = close + 1;
                    continue;
                }
            }
        }

        try out.append(allocator, text[i]);
        i += 1;
    }
}

// ============================================================================
// 代码块语法高亮（轻量 tokenizer，分语言 + 跨行状态）
// ============================================================================

/// 语言族(从 fence info-string 归类)。决定关键字集 + 注释/字符串语法。
const LangKind = enum { c_like, zig, python, js_ts, rust, go, shell, json, generic };

/// 跨行高亮状态(块注释 / 多行字符串跨行延续)。逐行高亮时由调用方持有并传入。
pub const HlState = struct {
    in_block_comment: bool = false, // C 系 /* ... */ 跨行
    in_multiline_str: bool = false, // python """ / zig \\ / 等
};

fn classifyLang(lang: []const u8) LangKind {
    const L = struct {
        fn eq(a: []const u8, comptime b: []const u8) bool {
            return std.ascii.eqlIgnoreCase(a, b);
        }
    };
    if (L.eq(lang, "zig")) return .zig;
    if (L.eq(lang, "py") or L.eq(lang, "python") or L.eq(lang, "python3")) return .python;
    if (L.eq(lang, "js") or L.eq(lang, "ts") or L.eq(lang, "jsx") or L.eq(lang, "tsx") or
        L.eq(lang, "javascript") or L.eq(lang, "typescript")) return .js_ts;
    if (L.eq(lang, "rust") or L.eq(lang, "rs")) return .rust;
    if (L.eq(lang, "go") or L.eq(lang, "golang")) return .go;
    if (L.eq(lang, "sh") or L.eq(lang, "bash") or L.eq(lang, "shell") or L.eq(lang, "zsh")) return .shell;
    if (L.eq(lang, "json")) return .json;
    if (L.eq(lang, "c") or L.eq(lang, "h") or L.eq(lang, "cpp") or L.eq(lang, "cc") or
        L.eq(lang, "c++") or L.eq(lang, "hpp") or L.eq(lang, "java")) return .c_like;
    return .generic;
}

/// 各语言关键字集。generic 用并集(尽量上色)。
fn keywordsFor(kind: LangKind) []const []const u8 {
    return switch (kind) {
        .zig => &.{ "const", "var", "fn", "pub", "struct", "enum", "union", "error", "comptime", "inline", "defer", "errdefer", "try", "catch", "return", "if", "else", "switch", "while", "for", "break", "continue", "and", "or", "orelse", "unreachable", "test", "extern", "export", "usingnamespace", "async", "await", "suspend", "resume", "anytype", "void", "bool", "true", "false", "null", "undefined", "u8", "u16", "u32", "u64", "usize", "i8", "i16", "i32", "i64", "isize", "f32", "f64", "type" },
        .python => &.{ "def", "class", "return", "if", "elif", "else", "for", "while", "break", "continue", "import", "from", "as", "with", "try", "except", "finally", "raise", "lambda", "yield", "async", "await", "pass", "global", "nonlocal", "and", "or", "not", "in", "is", "None", "True", "False", "self", "del", "assert" },
        .js_ts => &.{ "const", "let", "var", "function", "return", "if", "else", "for", "while", "switch", "case", "break", "continue", "class", "extends", "new", "this", "super", "import", "export", "from", "default", "async", "await", "yield", "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "void", "null", "undefined", "true", "false", "interface", "type", "enum", "implements", "public", "private", "protected", "readonly", "string", "number", "boolean", "any" },
        .rust => &.{ "fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "pub", "use", "mod", "return", "if", "else", "match", "for", "while", "loop", "break", "continue", "where", "self", "Self", "super", "crate", "as", "ref", "move", "async", "await", "dyn", "unsafe", "extern", "true", "false", "Some", "None", "Ok", "Err", "i32", "u32", "i64", "u64", "usize", "isize", "f32", "f64", "bool", "str", "String", "Vec" },
        .go => &.{ "func", "var", "const", "type", "struct", "interface", "map", "chan", "package", "import", "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "go", "defer", "select", "fallthrough", "nil", "true", "false", "int", "int32", "int64", "uint", "string", "bool", "byte", "rune", "error", "make", "new" },
        .shell => &.{ "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "return", "export", "local", "readonly", "in", "echo", "cd", "set", "unset", "source" },
        .json => &.{ "true", "false", "null" },
        .c_like => &.{ "int", "char", "void", "float", "double", "long", "short", "unsigned", "signed", "const", "static", "struct", "enum", "union", "typedef", "return", "if", "else", "for", "while", "switch", "case", "default", "break", "continue", "goto", "sizeof", "extern", "inline", "class", "public", "private", "protected", "virtual", "template", "namespace", "using", "new", "delete", "this", "true", "false", "nullptr", "bool", "auto" },
        .generic => &KEYWORDS,
    };
}

/// 通用关键字集（generic 语言用;覆盖各语言高频词的并集）。
const KEYWORDS = [_][]const u8{
    "if",     "else",      "for",     "while",   "switch",   "case",      "default",  "break",    "continue",
    "return", "match",     "loop",    "do",      "try",      "catch",     "finally",  "throw",    "defer",
    "const",  "var",       "let",     "fn",      "func",     "function",  "def",      "class",    "struct",
    "enum",   "union",     "interface", "type",  "trait",    "impl",      "pub",      "static",
    "import", "export",    "from",    "use",     "package",  "mod",       "extern",   "comptime",
    "inline", "async",     "await",   "new",     "void",     "true",      "false",    "null",     "nil",
    "self",   "this",      "int",     "bool",    "string",   "and",       "or",       "not",      "in",
};

fn isKeywordIn(word: []const u8, kws: []const []const u8) bool {
    for (kws) |kw| {
        if (std.mem.eql(u8, kw, word)) return true;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// 单行代码高亮(分语言关键字 + 跨行块注释/多行字符串状态)。
/// state 跨行持有:进入 C 系 `/* */` 或多行字符串后,后续行整段着色直到闭合。
/// base:行基色——markdown 代码块传 GRAY;diff 行内高亮传"背景块+默认前景",每个 token
///   收尾的 RESET 之后重铺 base,使背景色块在整行内不被 token 的 RESET 清掉(bg-aware)。
/// 行尾不补 RESET(交调用方,diff 行尾要带行号/换行控制)。
pub fn highlightCodeLine(line: []const u8, lang: []const u8, state: *HlState, base: []const u8, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    const kind = classifyLang(lang);
    const kws = keywordsFor(kind);

    // 跨行延续态:整行(或到闭合处)按对应色,然后继续常规扫描。
    if (state.in_block_comment) {
        if (std.mem.indexOf(u8, line, "*/")) |close| {
            const end = close + 2;
            try out.appendSlice(allocator, DIM);
            try out.appendSlice(allocator, line[0..end]);
            try out.appendSlice(allocator, RESET);
            try out.appendSlice(allocator, base);
            state.in_block_comment = false;
            try highlightRest(line[end..], kind, kws, state, base, out, allocator);
        } else {
            try out.appendSlice(allocator, DIM);
            try out.appendSlice(allocator, line);
            try out.appendSlice(allocator, RESET);
            try out.appendSlice(allocator, base);
        }
        return;
    }
    if (state.in_multiline_str) {
        // python """ 闭合;其余多行(zig \\)逐行延续,行首已无引号。
        const py_close: ?usize = if (kind == .python) std.mem.indexOf(u8, line, "\"\"\"") else null;
        if (py_close) |close| {
            const end = close + 3;
            try out.appendSlice(allocator, GREEN);
            try out.appendSlice(allocator, line[0..end]);
            try out.appendSlice(allocator, RESET);
            try out.appendSlice(allocator, base);
            state.in_multiline_str = false;
            try highlightRest(line[end..], kind, kws, state, base, out, allocator);
        } else {
            try out.appendSlice(allocator, GREEN);
            try out.appendSlice(allocator, line);
            try out.appendSlice(allocator, RESET);
            try out.appendSlice(allocator, base);
        }
        return;
    }

    try out.appendSlice(allocator, base);
    try highlightRest(line, kind, kws, state, base, out, allocator);
}

/// 扫描一行(无跨行延续态),按 token 上色;每 token 收尾 RESET 后重铺 base(bg-aware)。
/// 可能在行尾**进入**跨行态(设 state)。
fn highlightRest(line: []const u8, kind: LangKind, kws: []const []const u8, state: *HlState, base: []const u8, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    const line_comment_hash = (kind == .python or kind == .shell or kind == .generic);
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];

        // 块注释起始 /*(C 系 / zig 无块注释,js/rust 有)
        if (c == '/' and i + 1 < line.len and line[i + 1] == '*' and
            (kind == .c_like or kind == .js_ts or kind == .rust or kind == .generic))
        {
            if (std.mem.indexOfPos(u8, line, i, "*/")) |close| {
                const end = close + 2;
                try out.appendSlice(allocator, DIM);
                try out.appendSlice(allocator, line[i..end]);
                try out.appendSlice(allocator, RESET);
                try out.appendSlice(allocator, base);
                i = end;
                continue;
            } else {
                // 未闭合 → 进入跨行块注释态,本行剩余整段 dim。
                try out.appendSlice(allocator, DIM);
                try out.appendSlice(allocator, line[i..]);
                try out.appendSlice(allocator, RESET);
                state.in_block_comment = true;
                return;
            }
        }

        // 行注释:// (c/js/rust/go/zig) 或 # (py/sh)
        const slash_comment = (c == '/' and i + 1 < line.len and line[i + 1] == '/');
        if (slash_comment or (c == '#' and line_comment_hash)) {
            try out.appendSlice(allocator, DIM);
            try out.appendSlice(allocator, line[i..]);
            try out.appendSlice(allocator, RESET);
            try out.appendSlice(allocator, base);
            break;
        }

        // python 多行字符串 """(本行未闭合 → 进入跨行态)
        if (kind == .python and c == '"' and i + 2 < line.len and line[i + 1] == '"' and line[i + 2] == '"') {
            if (std.mem.indexOfPos(u8, line, i + 3, "\"\"\"")) |close| {
                const end = close + 3;
                try out.appendSlice(allocator, GREEN);
                try out.appendSlice(allocator, line[i..end]);
                try out.appendSlice(allocator, RESET);
                try out.appendSlice(allocator, base);
                i = end;
                continue;
            } else {
                try out.appendSlice(allocator, GREEN);
                try out.appendSlice(allocator, line[i..]);
                try out.appendSlice(allocator, RESET);
                state.in_multiline_str = true;
                return;
            }
        }

        // 字符串:"..." 或 '...'
        if (c == '"' or c == '\'') {
            const quote = c;
            var j = i + 1;
            while (j < line.len) : (j += 1) {
                if (line[j] == '\\') {
                    j += 1;
                    continue;
                }
                if (line[j] == quote) break;
            }
            const end = if (j < line.len) j + 1 else line.len;
            try out.appendSlice(allocator, GREEN);
            try out.appendSlice(allocator, line[i..end]);
            try out.appendSlice(allocator, RESET);
            try out.appendSlice(allocator, base);
            i = end;
            continue;
        }

        // 数字
        if (std.ascii.isDigit(c)) {
            var j = i;
            while (j < line.len and (std.ascii.isAlphanumeric(line[j]) or line[j] == '.' or line[j] == '_')) : (j += 1) {}
            try out.appendSlice(allocator, YELLOW);
            try out.appendSlice(allocator, line[i..j]);
            try out.appendSlice(allocator, RESET);
            try out.appendSlice(allocator, base);
            i = j;
            continue;
        }

        // 标识符/关键字
        if (std.ascii.isAlphabetic(c) or c == '_') {
            var j = i;
            while (j < line.len and isIdentChar(line[j])) : (j += 1) {}
            const word = line[i..j];
            if (isKeywordIn(word, kws)) {
                try out.appendSlice(allocator, MAGENTA);
                try out.appendSlice(allocator, word);
                try out.appendSlice(allocator, RESET);
                try out.appendSlice(allocator, base);
            } else {
                try out.appendSlice(allocator, word);
            }
            i = j;
            continue;
        }

        try out.append(allocator, c);
        i += 1;
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "render plain text passes through" {
    const r = try renderToOwned("hello world", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("hello world", r);
}

test "render bold" {
    const r = try renderToOwned("**bold**", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\x1b[1mbold\x1b[0m", r);
}

test "render italic" {
    const r = try renderToOwned("*italic*", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\x1b[3mitalic\x1b[0m", r);
}

test "render code span" {
    const r = try renderToOwned("`x`", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\x1b[2mx\x1b[0m", r);
}

test "render heading level 1" {
    const r = try renderToOwned("# Title", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "\x1b[1m") != null);
    try testing.expect(std.mem.indexOf(u8, r, "\x1b[36m") != null);
    try testing.expect(std.mem.indexOf(u8, r, "Title") != null);
}

test "render heading level 3" {
    const r = try renderToOwned("### Sub", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "Sub") != null);
}

test "render unordered list dash" {
    const r = try renderToOwned("- item", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("  • item\n", r);
}

test "render unordered list asterisk" {
    const r = try renderToOwned("* item", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("  • item\n", r);
}

test "render fenced code block" {
    const md =
        "```zig\n" ++
        "pub fn x() void {}\n" ++
        "```\n";
    const r = try renderToOwned(md, testing.allocator);
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "\x1b[90m") != null); // gray base for code
    try testing.expect(std.mem.indexOf(u8, r, "\x1b[35m") != null); // magenta keyword (pub/fn)
    try testing.expect(std.mem.indexOf(u8, r, "x()") != null); // identifier present
}

test "highlight code: string is green" {
    const md = "```c\nchar *s = \"hi\";\n```\n";
    const r = try renderToOwned(md, testing.allocator);
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "\x1b[32m") != null); // green string
    try testing.expect(std.mem.indexOf(u8, r, "\"hi\"") != null);
}

test "highlight code: number is yellow" {
    const md = "```\nx = 42\n```\n";
    const r = try renderToOwned(md, testing.allocator);
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "\x1b[33m") != null); // yellow number
    try testing.expect(std.mem.indexOf(u8, r, "42") != null);
}

test "highlight code: comment dimmed" {
    const md = "```py\n# a comment\n```\n";
    const r = try renderToOwned(md, testing.allocator);
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "a comment") != null);
}

test "highlight code: 跨行块注释(C 系 /* */)整段 dim" {
    // 块注释跨 3 行,中间行不含 /* 也应是 dim(跨行状态生效)。
    const md =
        "```c\n" ++
        "int x; /* start\n" ++
        "middle of comment\n" ++
        "end */ int y;\n" ++
        "```\n";
    const r = try renderToOwned(md, testing.allocator);
    defer testing.allocator.free(r);
    // 中间行整段在 DIM 内(\x1b[2m ... middle ...);若跨行状态没生效,middle 会被当代码高亮。
    const mid = std.mem.indexOf(u8, r, "middle of comment").?;
    // middle 之前最近的 SGR 应是 DIM(\x1b[2m)而非 magenta/green。
    const dim_before = std.mem.lastIndexOf(u8, r[0..mid], "\x1b[2m") orelse 0;
    const kw_before = std.mem.lastIndexOf(u8, r[0..mid], "\x1b[35m") orelse 0;
    try testing.expect(dim_before > kw_before); // DIM 比关键字色更近 → middle 在块注释里
}

test "highlight code: python 多行字符串跨行 green" {
    const md =
        "```py\n" ++
        "x = \"\"\"line one\n" ++
        "line two\n" ++
        "\"\"\"\n" ++
        "```\n";
    const r = try renderToOwned(md, testing.allocator);
    defer testing.allocator.free(r);
    // line two 在多行字符串内 → 它之前最近的色应是 GREEN(\x1b[32m)。
    const two = std.mem.indexOf(u8, r, "line two").?;
    const green_before = std.mem.lastIndexOf(u8, r[0..two], "\x1b[32m") orelse 0;
    const gray_before = std.mem.lastIndexOf(u8, r[0..two], "\x1b[90m") orelse 0;
    try testing.expect(green_before > gray_before);
}

test "highlight code: 分语言关键字(go func 高亮,py 不识 func 同等)" {
    // go:func 是关键字 → magenta。
    const go = try renderToOwned("```go\nfunc main() {}\n```\n", testing.allocator);
    defer testing.allocator.free(go);
    // func 紧跟 magenta。
    const f = std.mem.indexOf(u8, go, "func").?;
    try testing.expect(std.mem.lastIndexOf(u8, go[0..f], "\x1b[35m") != null);
    // python:def 是关键字,func 不是 → def 高亮,普通标识符 func 不会误判为本语言关键字。
    const py = try renderToOwned("```py\ndef f(): pass\n```\n", testing.allocator);
    defer testing.allocator.free(py);
    try testing.expect(std.mem.indexOf(u8, py, "\x1b[35m") != null); // def magenta
}

test "render multiple paragraphs preserve newlines" {
    const r = try renderToOwned("a\nb\nc", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a\nb\nc", r);
}

test "render mixed bold in text" {
    const r = try renderToOwned("say **hi** now", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "say ") != null);
    try testing.expect(std.mem.indexOf(u8, r, "\x1b[1mhi\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, r, " now") != null);
}

test "render unclosed bold is literal" {
    const r = try renderToOwned("**no close", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("**no close", r);
}

test "render unclosed code span is literal" {
    const r = try renderToOwned("`open", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("`open", r);
}

test "render heading with bold inside" {
    const r = try renderToOwned("## **bold head**", testing.allocator);
    defer testing.allocator.free(r);
    // 会有两层 ANSI（heading + bold）
    try testing.expect(std.mem.indexOf(u8, r, "bold head") != null);
}

test "render empty input" {
    const r = try renderToOwned("", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("", r);
}

test "render trailing newline preserved in plain text" {
    const r = try renderToOwned("line\n", testing.allocator);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("line\n", r);
}
