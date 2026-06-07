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
// CJK-aware 显示宽度(表格列宽/cell 折行用);term 不引 render,无循环依赖。
const term = @import("tui/term.zig");
const theme_mod = @import("tui/theme.zig");
const SyntaxTheme = theme_mod.SyntaxTheme;
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
                try highlightCodeLine(line, code_lang, &hl_state, GRAY, &out, allocator, ansi.syntax_palette.b16);
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
        } else if (peekLine(md, next) != null and isTableStart(line, peekLine(md, next).?)) {
            // 表格前瞻:line 是表头、下一行是分隔行 → 收集整块渲染。
            var tbl_rows: std.ArrayList([]const u8) = .empty;
            defer tbl_rows.deinit(allocator);
            try tbl_rows.append(allocator, line); // 表头
            // 从下一行起收集分隔 + 连续 pipe 非空行。
            var scan = next;
            var last_end = line_end;
            while (scan < md.len) {
                const le = std.mem.indexOfScalarPos(u8, md, scan, '\n') orelse md.len;
                const l = md[scan..le];
                const trimmed = std.mem.trim(u8, l, " \t\r");
                if (trimmed.len == 0 or !lineHasPipe(l)) break;
                try tbl_rows.append(allocator, l);
                last_end = le;
                scan = if (le < md.len) le + 1 else md.len;
            }
            const t = try renderTable(tbl_rows.items, TABLE_BATCH_WIDTH, allocator);
            defer allocator.free(t);
            try out.appendSlice(allocator, t);
            if (last_end < md.len) try out.append(allocator, '\n');
            cursor = if (last_end < md.len) last_end + 1 else md.len;
            continue;
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

/// 流式跨行 markdown 状态(供 live 逐行渲染携带:代码块/语法高亮跨行)。
pub const StreamState = struct {
    in_code_block: bool = false,
    code_lang: []const u8 = "",
    hl_state: HlState = .{},
};

/// 渲染**单行** markdown(不含尾随 \n)到 out,携带跨行状态 st(代码块/高亮)。
/// 对齐 renderToOwned 的逐行逻辑,供 live 流式路径逐行调用——inline(bold/code/heading/list)
/// 行内即决,代码块靠 st.in_code_block 跨行。caller 自行追加 \n。
pub fn renderLineStreaming(line: []const u8, st: *StreamState, out: *std.ArrayList(u8), allocator: std.mem.Allocator, syn: SyntaxTheme) !void {
    if (st.in_code_block) {
        if (std.mem.startsWith(u8, line, "```")) {
            try out.appendSlice(allocator, RESET);
            st.in_code_block = false;
        } else {
            try highlightCodeLine(line, st.code_lang, &st.hl_state, GRAY, out, allocator, syn);
            try out.appendSlice(allocator, RESET);
        }
    } else if (std.mem.startsWith(u8, line, "```")) {
        st.code_lang = std.mem.trim(u8, line[3..], " \t\r");
        st.hl_state = .{};
        st.in_code_block = true;
        // 围栏行本身不输出内容(对齐 cc 去围栏)。
    } else if (isHeading(line)) |h| {
        try renderHeading(line, h, out, allocator);
    } else if (isListItem(line)) |prefix_len| {
        try out.appendSlice(allocator, "  • ");
        try renderInline(line[prefix_len..], out, allocator);
    } else {
        try renderInline(line, out, allocator);
    }
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

/// 从 md[from..] 取下一整行(到 \n 或 EOF);from>=len 返 null。
fn peekLine(md: []const u8, from: usize) ?[]const u8 {
    if (from >= md.len) return null;
    const end = std.mem.indexOfScalarPos(u8, md, from, '\n') orelse md.len;
    return md[from..end];
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
pub fn highlightCodeLine(line: []const u8, lang: []const u8, state: *HlState, base: []const u8, out: *std.ArrayList(u8), allocator: std.mem.Allocator, syn: SyntaxTheme) !void {
    const kind = classifyLang(lang);
    const kws = keywordsFor(kind);
    // syn 各组空时回退历史 basic-16 常量(保证 16 色/无主题路径零回归)。
    const c_str = if (syn.string.len > 0) syn.string else GREEN;
    const c_cmt = if (syn.comment.len > 0) syn.comment else DIM;

    // 跨行延续态:整行(或到闭合处)按对应色,然后继续常规扫描。
    if (state.in_block_comment) {
        if (std.mem.indexOf(u8, line, "*/")) |close| {
            const end = close + 2;
            try out.appendSlice(allocator, c_cmt);
            try out.appendSlice(allocator, line[0..end]);
            try out.appendSlice(allocator, RESET);
            try out.appendSlice(allocator, base);
            state.in_block_comment = false;
            try highlightRest(line[end..], kind, kws, state, base, out, allocator, syn);
        } else {
            try out.appendSlice(allocator, c_cmt);
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
            try out.appendSlice(allocator, c_str);
            try out.appendSlice(allocator, line[0..end]);
            try out.appendSlice(allocator, RESET);
            try out.appendSlice(allocator, base);
            state.in_multiline_str = false;
            try highlightRest(line[end..], kind, kws, state, base, out, allocator, syn);
        } else {
            try out.appendSlice(allocator, c_str);
            try out.appendSlice(allocator, line);
            try out.appendSlice(allocator, RESET);
            try out.appendSlice(allocator, base);
        }
        return;
    }

    try out.appendSlice(allocator, base);
    try highlightRest(line, kind, kws, state, base, out, allocator, syn);
}

/// 扫描一行(无跨行延续态),按 token 上色;每 token 收尾 RESET 后重铺 base(bg-aware)。
/// 可能在行尾**进入**跨行态(设 state)。syn 提供语义色,空组回退历史 basic-16。
fn highlightRest(line: []const u8, kind: LangKind, kws: []const []const u8, state: *HlState, base: []const u8, out: *std.ArrayList(u8), allocator: std.mem.Allocator, syn: SyntaxTheme) !void {
    const c_str = if (syn.string.len > 0) syn.string else GREEN;
    const c_num = if (syn.number.len > 0) syn.number else YELLOW;
    const c_kw = if (syn.keyword.len > 0) syn.keyword else MAGENTA;
    const c_cmt = if (syn.comment.len > 0) syn.comment else DIM;
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
                try out.appendSlice(allocator, c_cmt);
                try out.appendSlice(allocator, line[i..end]);
                try out.appendSlice(allocator, RESET);
                try out.appendSlice(allocator, base);
                i = end;
                continue;
            } else {
                // 未闭合 → 进入跨行块注释态,本行剩余整段 dim。
                try out.appendSlice(allocator, c_cmt);
                try out.appendSlice(allocator, line[i..]);
                try out.appendSlice(allocator, RESET);
                state.in_block_comment = true;
                return;
            }
        }

        // 行注释:// (c/js/rust/go/zig) 或 # (py/sh)
        const slash_comment = (c == '/' and i + 1 < line.len and line[i + 1] == '/');
        if (slash_comment or (c == '#' and line_comment_hash)) {
            try out.appendSlice(allocator, c_cmt);
            try out.appendSlice(allocator, line[i..]);
            try out.appendSlice(allocator, RESET);
            try out.appendSlice(allocator, base);
            break;
        }

        // python 多行字符串 """(本行未闭合 → 进入跨行态)
        if (kind == .python and c == '"' and i + 2 < line.len and line[i + 1] == '"' and line[i + 2] == '"') {
            if (std.mem.indexOfPos(u8, line, i + 3, "\"\"\"")) |close| {
                const end = close + 3;
                try out.appendSlice(allocator, c_str);
                try out.appendSlice(allocator, line[i..end]);
                try out.appendSlice(allocator, RESET);
                try out.appendSlice(allocator, base);
                i = end;
                continue;
            } else {
                try out.appendSlice(allocator, c_str);
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
            try out.appendSlice(allocator, c_str);
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
            try out.appendSlice(allocator, c_num);
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
                try out.appendSlice(allocator, c_kw);
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
// Markdown 表格(GFM)→ Unicode 框线渲染(对齐 cc)
// ============================================================================

// box-drawing 框线字符。
const BOX = struct {
    const tl = "┌";
    const tm = "┬";
    const tr = "┐";
    const ml = "├";
    const mm = "┼";
    const mr = "┤";
    const bl = "└";
    const bm = "┴";
    const br = "┘";
    const v = "│";
    const h = "─";
};

/// 批量路径(renderToOwned 宽度无关)的表格宽度预算;TTY 流式路径用真实 cols-2。
pub const TABLE_BATCH_WIDTH: usize = 80;

/// 列对齐(从分隔行的 `:` 标记解析)。
pub const Align = enum { left, center, right };

const MIN_COL: usize = 3;

/// 是否 GFM 表格分隔行:去首尾可选 `|` 后每个 cell 仅含空格/`:`/`-` 且至少一个 `-`,
/// 且整行至少有一个非空 cell。纯 `|`/空格(无 `-`)→ false。
pub fn isTableSeparator(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0) return false;
    // 去一层首尾 `|`。
    var body = t;
    if (body.len > 0 and body[0] == '|') body = body[1..];
    if (body.len > 0 and body[body.len - 1] == '|') body = body[0 .. body.len - 1];
    if (body.len == 0) return false;
    var any_cell = false;
    var it = std.mem.splitScalar(u8, body, '|');
    while (it.next()) |cell| {
        const c = std.mem.trim(u8, cell, " \t");
        if (c.len == 0) return false; // 空 cell(如 `| |`)不算分隔
        var has_dash = false;
        for (c) |ch| {
            if (ch == '-') {
                has_dash = true;
            } else if (ch != ':' and ch != ' ') {
                return false; // 出现非法字符
            }
        }
        if (!has_dash) return false;
        any_cell = true;
    }
    return any_cell;
}

/// 行是否含 `|`(快速判定 pipe 行)。
pub fn lineHasPipe(line: []const u8) bool {
    return std.mem.indexOfScalar(u8, line, '|') != null;
}

/// 表格是否从这两行开始:first 含 `|` 非围栏,且 second 是分隔行。
pub fn isTableStart(first: []const u8, second: []const u8) bool {
    if (std.mem.startsWith(u8, std.mem.trim(u8, first, " \t"), "```")) return false;
    if (!lineHasPipe(first)) return false;
    return isTableSeparator(second);
}

/// 把原始行拆成 trim 后的 cell slice(借 line 内存,只分配外层 slice)。
/// 去一层首尾可选 `|`,按 `|` 切,trim 空格/tab。v1 不处理 `\|` 转义。
pub fn splitTableRow(line: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    var body = t;
    if (body.len > 0 and body[0] == '|') body = body[1..];
    if (body.len > 0 and body[body.len - 1] == '|') body = body[0 .. body.len - 1];

    var cells: std.ArrayList([]const u8) = .empty;
    errdefer cells.deinit(allocator);
    var it = std.mem.splitScalar(u8, body, '|');
    while (it.next()) |cell| {
        try cells.append(allocator, std.mem.trim(u8, cell, " \t"));
    }
    return try cells.toOwnedSlice(allocator);
}

/// 从分隔行单个 cell 解析对齐:`:---`→left,`---:`→right,`:--:`→center,`---`→left。
fn parseAlign(sep_cell: []const u8) Align {
    const c = std.mem.trim(u8, sep_cell, " \t");
    if (c.len == 0) return .left;
    const left_colon = c[0] == ':';
    const right_colon = c[c.len - 1] == ':';
    if (left_colon and right_colon) return .center;
    if (right_colon) return .right;
    return .left;
}

/// 单元格内容的可见显示宽(按 renderInline 消费 `**`/`*`/`` ` `` 的方式只数可见字符)。
/// 载荷关键:cell 含 emphasis marker 时,边框须按可见宽对齐而非含 marker 的原始宽。
fn inlineDisplayWidth(text: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |close| {
                w += term.displayWidth(text[i + 1 .. close]);
                i = close + 1;
                continue;
            }
        }
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, text, i + 2, "**")) |close| {
                w += term.displayWidth(text[i + 2 .. close]);
                i = close + 2;
                continue;
            }
        }
        if (text[i] == '*' and (i + 1 >= text.len or text[i + 1] != '*')) {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '*')) |close| {
                if (close + 1 >= text.len or text[close + 1] != '*') {
                    w += term.displayWidth(text[i + 1 .. close]);
                    i = close + 1;
                    continue;
                }
            }
        }
        const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + cp_len, text.len);
        w += term.displayWidth(text[i..end]);
        i = end;
    }
    return w;
}

/// 从 s[i]=ESC 起扫完整转义序列,返回其后第一个字节索引(SGR-aware 折行原子透传)。
fn scanEsc(s: []const u8, i: usize) usize {
    var j = i + 1;
    if (j < s.len and s[j] == '[') {
        j += 1;
        while (j < s.len and !std.ascii.isAlphabetic(s[j])) : (j += 1) {}
        if (j < s.len) j += 1;
        return j;
    }
    return @min(i + 2, s.len);
}

/// 把已渲成 ANSI 的 cell 折成多物理子行,每行可见宽 ≤ width。
/// ASCII 空格处贪心折;单 token 超列宽按 codepoint 硬折(CJK 无空格必须硬折,不切多字节);
/// ESC 序列零宽原子透传。返回 owned 子行列表(每条 owned),调用方释放。
fn wrapCell(rendered: []const u8, width: usize, allocator: std.mem.Allocator) !std.ArrayList([]u8) {
    var lines: std.ArrayList([]u8) = .empty;
    errdefer {
        for (lines.items) |l| allocator.free(l);
        lines.deinit(allocator);
    }
    if (width == 0) {
        try lines.append(allocator, try allocator.dupe(u8, ""));
        return lines;
    }

    var cur: std.ArrayList(u8) = .empty;
    defer cur.deinit(allocator);
    var cur_w: usize = 0; // 当前行可见宽
    // 待定 word(自上个空格断点起的可见内容,含其 ESC);用于在空格处回退。
    var word: std.ArrayList(u8) = .empty;
    defer word.deinit(allocator);
    var word_w: usize = 0;

    const flushLine = struct {
        fn f(ls: *std.ArrayList([]u8), c: *std.ArrayList(u8), a: std.mem.Allocator) !void {
            try ls.append(a, try a.dupe(u8, c.items));
            c.clearRetainingCapacity();
        }
    }.f;

    var i: usize = 0;
    const s = rendered;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            const e = scanEsc(s, i);
            try word.appendSlice(allocator, s[i..e]); // ESC 跟随当前 word,零宽
            i = e;
            continue;
        }
        const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + cp_len, s.len);
        const ch = s[i..end];
        const cw = term.displayWidth(ch);

        if (s[i] == ' ') {
            // 空格 = word 断点:先把已攒 word 落到 cur(若放不下则换行)。
            if (word_w > 0) {
                if (cur_w + word_w > width and cur_w > 0) {
                    try flushLine(&lines, &cur, allocator);
                    cur_w = 0;
                }
                try cur.appendSlice(allocator, word.items);
                cur_w += word_w;
                word.clearRetainingCapacity();
                word_w = 0;
            }
            // 空格本身:行首的空格丢弃,否则附到 cur。
            if (cur_w > 0 and cur_w + 1 <= width) {
                try cur.append(allocator, ' ');
                cur_w += 1;
            } else if (cur_w + 1 > width) {
                try flushLine(&lines, &cur, allocator);
                cur_w = 0;
            }
            i = end;
            continue;
        }

        // 单字符就超列宽不可能(cw≤2≤width 当 width≥2);width==1 且 CJK 时硬塞一格。
        if (word_w + cw > width) {
            // word 自身超列宽:先把 word 落行(可能要先换行),硬折。
            if (cur_w + word_w > width and cur_w > 0) {
                try flushLine(&lines, &cur, allocator);
                cur_w = 0;
            }
            try cur.appendSlice(allocator, word.items);
            cur_w += word_w;
            word.clearRetainingCapacity();
            word_w = 0;
            if (cur_w + cw > width and cur_w > 0) {
                try flushLine(&lines, &cur, allocator);
                cur_w = 0;
            }
        }
        try word.appendSlice(allocator, ch);
        word_w += cw;
        i = end;
    }
    // 收尾:落最后的 word。
    if (word_w > 0) {
        if (cur_w + word_w > width and cur_w > 0) {
            try flushLine(&lines, &cur, allocator);
            cur_w = 0;
        }
        try cur.appendSlice(allocator, word.items);
        cur_w += word_w;
    }
    if (cur.items.len > 0 or lines.items.len == 0) {
        try flushLine(&lines, &cur, allocator);
    }
    return lines;
}

/// 把单元格 markdown 渲成 ANSI(借用 renderInline),返回 owned。
fn renderCellInline(cell: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try renderInline(cell, &out, allocator);
    return try out.toOwnedSlice(allocator);
}

/// 追加一条边框行:left + join(h×(col+2), mid) + right。
fn appendBorder(out: *std.ArrayList(u8), cols: []const usize, left: []const u8, mid: []const u8, right: []const u8, allocator: std.mem.Allocator) !void {
    try out.appendSlice(allocator, left);
    for (cols, 0..) |w, c| {
        if (c > 0) try out.appendSlice(allocator, mid);
        var k: usize = 0;
        while (k < w + 2) : (k += 1) try out.appendSlice(allocator, BOX.h);
    }
    try out.appendSlice(allocator, right);
}

/// 追加 `n` 个空格。
fn appendSpaces(out: *std.ArrayList(u8), n: usize, allocator: std.mem.Allocator) !void {
    var k: usize = 0;
    while (k < n) : (k += 1) try out.append(allocator, ' ');
}

/// 渲染 GFM 表格 → Unicode 框线多行字符串。
/// rows[0]=表头,rows[1]=分隔,rows[2..]=正文。输出含 `\n` 与表头加粗 ANSI,无尾随 `\n`,
/// 无外层前缀;每物理行可见宽 ≤ avail_width。rows.len<2 或 rows[1] 非分隔 → 退化逐行 renderInline。
pub fn renderTable(rows: []const []const u8, avail_width: usize, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (rows.len < 2 or !isTableSeparator(rows[1])) {
        // 退化:不是合法表格,各行过 renderInline 以 \n 连。
        for (rows, 0..) |row, idx| {
            if (idx > 0) try out.append(allocator, '\n');
            try renderInline(row, &out, allocator);
        }
        return try out.toOwnedSlice(allocator);
    }

    // 表头定列数。
    const header = try splitTableRow(rows[0], allocator);
    defer allocator.free(header);
    const n = header.len;
    if (n == 0) return try out.toOwnedSlice(allocator);

    // 对齐(从分隔行)。
    const sep_cells = try splitTableRow(rows[1], allocator);
    defer allocator.free(sep_cells);
    const aligns = try allocator.alloc(Align, n);
    defer allocator.free(aligns);
    for (aligns, 0..) |*a, c| a.* = if (c < sep_cells.len) parseAlign(sep_cells[c]) else .left;

    // 收集所有内容行(表头 + 正文),每行规整到 n 列(多余并入末列,缺补空)。
    var content_rows: std.ArrayList([][]const u8) = .empty;
    defer {
        for (content_rows.items) |r| allocator.free(r);
        content_rows.deinit(allocator);
    }
    {
        // 表头本身作为第一内容行。
        const hr = try allocator.alloc([]const u8, n);
        for (hr, 0..) |*cell, c| cell.* = if (c < header.len) header[c] else "";
        try content_rows.append(allocator, hr);
    }
    var body_idx: usize = 2;
    while (body_idx < rows.len) : (body_idx += 1) {
        const raw = try splitTableRow(rows[body_idx], allocator);
        defer allocator.free(raw);
        const r = try allocator.alloc([]const u8, n);
        for (r, 0..) |*cell, c| {
            if (c + 1 == n and raw.len > n) {
                // 多余 cell 并入末列:取从该列起到末尾的原始 cell 第一个(简化:仅取本列)。
                cell.* = raw[c];
            } else {
                cell.* = if (c < raw.len) raw[c] else "";
            }
        }
        try content_rows.append(allocator, r);
    }

    // 列自然宽 = 各行该列 inlineDisplayWidth 最大值。
    const nat = try allocator.alloc(usize, n);
    defer allocator.free(nat);
    for (nat) |*w| w.* = 0;
    for (content_rows.items) |row| {
        for (row, 0..) |cell, c| {
            const cw = inlineDisplayWidth(cell);
            if (cw > nat[c]) nat[c] = cw;
        }
    }

    // 列宽预算:chrome = 3n+1。
    const chrome = 3 * n + 1;
    const content_budget = if (avail_width > chrome) avail_width - chrome else 0;
    var nat_total: usize = 0;
    for (nat) |w| nat_total += w;

    const col = try allocator.alloc(usize, n);
    defer allocator.free(col);
    if (nat_total <= content_budget or content_budget == 0) {
        for (col, 0..) |*w, c| w.* = @max(@as(usize, 1), nat[c]);
    } else {
        // 按比例压缩 + MIN_COL 下限 + 确定性补偿使 sum==content_budget。
        for (col, 0..) |*w, c| {
            const scaled = if (nat_total > 0) nat[c] * content_budget / nat_total else 0;
            w.* = @max(MIN_COL, scaled);
        }
        var sum: usize = 0;
        for (col) |w| sum += w;
        // 太小:全列已 MIN_COL 仍超 budget → 接受溢出。
        if (content_budget >= n * MIN_COL) {
            while (sum < content_budget) {
                // 给"被压缩最多"(nat-col 最大)的列 +1。
                var best: usize = 0;
                var best_gap: usize = 0;
                for (col, 0..) |w, c| {
                    const gap = if (nat[c] > w) nat[c] - w else 0;
                    if (gap >= best_gap) {
                        best_gap = gap;
                        best = c;
                    }
                }
                col[best] += 1;
                sum += 1;
            }
            while (sum > content_budget) {
                // 从最宽且 >MIN_COL 的列 -1。
                var best: usize = 0;
                var best_w: usize = 0;
                var found = false;
                for (col, 0..) |w, c| {
                    if (w > MIN_COL and w >= best_w) {
                        best_w = w;
                        best = c;
                        found = true;
                    }
                }
                if (!found) break;
                col[best] -= 1;
                sum -= 1;
            }
        }
    }

    // 顶框。
    try appendBorder(&out, col, BOX.tl, BOX.tm, BOX.tr, allocator);
    try out.append(allocator, '\n');

    // 逐内容行渲染(表头行加粗);表头后插分隔。
    for (content_rows.items, 0..) |row, ri| {
        const is_header = ri == 0;
        // 每列:渲 inline → 折成子行。
        var sublines = try allocator.alloc(std.ArrayList([]u8), n);
        defer {
            for (sublines) |*sl| {
                for (sl.items) |l| allocator.free(l);
                sl.deinit(allocator);
            }
            allocator.free(sublines);
        }
        var hrows: usize = 1;
        for (row, 0..) |cell, c| {
            const ansi_cell = try renderCellInline(cell, allocator);
            defer allocator.free(ansi_cell);
            sublines[c] = try wrapCell(ansi_cell, col[c], allocator);
            if (sublines[c].items.len > hrows) hrows = sublines[c].items.len;
        }
        // 逐物理子行。
        var k: usize = 0;
        while (k < hrows) : (k += 1) {
            try out.appendSlice(allocator, BOX.v);
            for (col, 0..) |w, c| {
                try out.append(allocator, ' ');
                const sub = if (k < sublines[c].items.len) sublines[c].items[k] else "";
                const vis = visibleWidth(sub);
                const pad = if (w > vis) w - vis else 0;
                const lead = switch (aligns[c]) {
                    .left => 0,
                    .right => pad,
                    .center => pad / 2,
                };
                const trail = pad - lead;
                try appendSpaces(&out, lead, allocator);
                if (is_header and sub.len > 0) {
                    try out.appendSlice(allocator, BOLD);
                    try out.appendSlice(allocator, sub);
                    try out.appendSlice(allocator, RESET);
                } else {
                    try out.appendSlice(allocator, sub);
                }
                try appendSpaces(&out, trail, allocator);
                try out.append(allocator, ' ');
                try out.appendSlice(allocator, BOX.v);
            }
            try out.append(allocator, '\n');
        }
        // 表头后插中分隔。
        if (is_header) {
            try appendBorder(&out, col, BOX.ml, BOX.mm, BOX.mr, allocator);
            try out.append(allocator, '\n');
        }
    }

    // 底框(无尾随 \n)。
    try appendBorder(&out, col, BOX.bl, BOX.bm, BOX.br, allocator);

    return try out.toOwnedSlice(allocator);
}

/// 计算含 ANSI 的串的可见显示宽(ESC 零宽)。
fn visibleWidth(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i = scanEsc(s, i);
            continue;
        }
        const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + cp_len, s.len);
        w += term.displayWidth(s[i..end]);
        i = end;
    }
    return w;
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

test "renderLineStreaming: 逐行携带代码块状态 + 去标记" {
    var st: StreamState = .{};
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    // heading:## 去掉,bold cyan(只验文字 + 无 ## 残留)。
    out.clearRetainingCapacity();
    try renderLineStreaming("## Hi", &st, &out, testing.allocator, ansi.syntax_palette.b16);
    try testing.expect(std.mem.indexOf(u8, out.items, "Hi") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "##") == null);

    // inline bold:** 消化。
    out.clearRetainingCapacity();
    try renderLineStreaming("a **b** c", &st, &out, testing.allocator, ansi.syntax_palette.b16);
    try testing.expect(std.mem.indexOf(u8, out.items, "**") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "b") != null);

    // 代码块:围栏行进 in_code_block,围栏本身不输出文字内容(去围栏)。
    out.clearRetainingCapacity();
    try renderLineStreaming("```python", &st, &out, testing.allocator, ansi.syntax_palette.b16);
    try testing.expect(st.in_code_block);
    try testing.expect(std.mem.indexOf(u8, out.items, "```") == null);
    // 代码块内行:内容保留(语法高亮会插 ANSI,故只验关键 token 在)。
    out.clearRetainingCapacity();
    try renderLineStreaming("print('x')", &st, &out, testing.allocator, ansi.syntax_palette.b16);
    try testing.expect(std.mem.indexOf(u8, out.items, "print") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "'x'") != null);
    // 闭合围栏:退出代码块。
    out.clearRetainingCapacity();
    try renderLineStreaming("```", &st, &out, testing.allocator, ansi.syntax_palette.b16);
    try testing.expect(!st.in_code_block);
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

// ---- 表格(GFM)测试 ----

/// 剥掉 ANSI 转义(测试断言可见宽用)。
fn stripAnsi(s: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i = scanEsc(s, i);
            continue;
        }
        try out.append(allocator, s[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

test "isTableSeparator true cases" {
    try testing.expect(isTableSeparator("|---|---|"));
    try testing.expect(isTableSeparator("| :--- | ---: |"));
    try testing.expect(isTableSeparator("|:--:|:--:|"));
    try testing.expect(isTableSeparator("---|---"));
    try testing.expect(isTableSeparator("| --- |"));
}

test "isTableSeparator false cases" {
    try testing.expect(!isTableSeparator("| a | b |"));
    try testing.expect(!isTableSeparator("||"));
    try testing.expect(!isTableSeparator("|   |"));
    try testing.expect(!isTableSeparator(""));
    try testing.expect(!isTableSeparator("text"));
    try testing.expect(!isTableSeparator("|--x--|"));
}

test "isTableStart header+separator vs not" {
    try testing.expect(isTableStart("| a | b |", "|---|---|"));
    try testing.expect(!isTableStart("| a | b |", "| c | d |")); // 第二行非分隔
    try testing.expect(!isTableStart("```", "|---|---|")); // 围栏
    try testing.expect(!isTableStart("no pipe", "|---|---|")); // 无 pipe
}

test "splitTableRow trims and tolerates missing edge pipes" {
    {
        const cells = try splitTableRow("| a | b |", testing.allocator);
        defer testing.allocator.free(cells);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqualStrings("a", cells[0]);
        try testing.expectEqualStrings("b", cells[1]);
    }
    {
        const cells = try splitTableRow("a|b", testing.allocator); // 无首尾 pipe
        defer testing.allocator.free(cells);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqualStrings("a", cells[0]);
        try testing.expectEqualStrings("b", cells[1]);
    }
    {
        const cells = try splitTableRow("| 反对理由 | 典型声音 |", testing.allocator);
        defer testing.allocator.free(cells);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqualStrings("反对理由", cells[0]);
        try testing.expectEqualStrings("典型声音", cells[1]);
    }
}

test "parseAlign left/right/center" {
    try testing.expectEqual(Align.left, parseAlign("---"));
    try testing.expectEqual(Align.left, parseAlign(":---"));
    try testing.expectEqual(Align.right, parseAlign("---:"));
    try testing.expectEqual(Align.center, parseAlign(":--:"));
}

test "renderTable CJK: borders present, header bold, rows equal display width" {
    const rows = [_][]const u8{
        "| 反对理由 | 典型声音 |",
        "|---|---|",
        "| LLM 够用 | gpt-4o 推断结构 |",
        "| 增加复杂度 | grammar 编译 |",
    };
    const r = try renderTable(&rows, 80, testing.allocator);
    defer testing.allocator.free(r);

    // 框线齐全。
    for ([_][]const u8{ "┌", "┬", "┐", "├", "┼", "┤", "└", "┴", "┘", "│", "─" }) |g| {
        try testing.expect(std.mem.indexOf(u8, r, g) != null);
    }
    // 表头加粗。
    try testing.expect(std.mem.indexOf(u8, r, "\x1b[1m") != null);

    // 剥 ANSI 后每物理行可见宽相等(框对齐)。
    const plain = try stripAnsi(r, testing.allocator);
    defer testing.allocator.free(plain);
    var it = std.mem.splitScalar(u8, plain, '\n');
    var width: ?usize = null;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const w = term.displayWidth(line);
        if (width) |expected| {
            try testing.expectEqual(expected, w);
        } else width = w;
    }
    try testing.expect(width != null);
}

test "renderTable overflow: no line exceeds avail, long cell wraps" {
    const rows = [_][]const u8{
        "| col_a | col_b |",
        "|---|---|",
        "| short | this is a very long cell that must wrap across multiple physical lines |",
    };
    const avail: usize = 24;
    const r = try renderTable(&rows, avail, testing.allocator);
    defer testing.allocator.free(r);

    const plain = try stripAnsi(r, testing.allocator);
    defer testing.allocator.free(plain);
    var it = std.mem.splitScalar(u8, plain, '\n');
    var content_lines: usize = 0;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try testing.expect(term.displayWidth(line) <= avail);
        // 内容行(以 │ 开头)的 │ 数应为 N+1 = 3。
        if (std.mem.startsWith(u8, line, "│")) {
            var cnt: usize = 0;
            var idx: usize = 0;
            while (std.mem.indexOfPos(u8, line, idx, "│")) |p| {
                cnt += 1;
                idx = p + "│".len;
            }
            try testing.expectEqual(@as(usize, 3), cnt);
            content_lines += 1;
        }
    }
    // 长 cell 至少折成 2 行 → 内容行 > 行数(表头1+正文≥2)。
    try testing.expect(content_lines >= 3);
}

test "renderTable right alignment has leading spaces" {
    const rows = [_][]const u8{
        "| n |",
        "| ---: |",
        "| 7 |",
    };
    const r = try renderTable(&rows, 80, testing.allocator);
    defer testing.allocator.free(r);
    const plain = try stripAnsi(r, testing.allocator);
    defer testing.allocator.free(plain);
    // 表头 "n" 自然宽 1,正文 "7" 右对齐;此处单列宽=1 无 pad,改测多宽列。
    const rows2 = [_][]const u8{
        "| label |",
        "| ---: |",
        "| 7 |",
    };
    const r2 = try renderTable(&rows2, 80, testing.allocator);
    defer testing.allocator.free(r2);
    const plain2 = try stripAnsi(r2, testing.allocator);
    defer testing.allocator.free(plain2);
    // 列宽=5("label"),"7" 右对齐 → "    7"(4 前导空格)。
    try testing.expect(std.mem.indexOf(u8, plain2, "    7 ") != null);
}

test "renderTable degenerate: avail < N*MIN_COL still valid grid" {
    const rows = [_][]const u8{
        "| aaaa | bbbb | cccc |",
        "|---|---|---|",
        "| 1 | 2 | 3 |",
    };
    const r = try renderTable(&rows, 8, testing.allocator); // 远小于 3*3+chrome
    defer testing.allocator.free(r);
    // 至少能产出框(不 panic),含竖线。
    try testing.expect(std.mem.indexOf(u8, r, "│") != null);
    try testing.expect(std.mem.indexOf(u8, r, "┌") != null);
}

test "wrapCell CJK hard-break at width 6, valid utf8" {
    // 10 个汉字(每宽 2),width 6 → 每行 ≤3 字(宽 6)。
    const cell = "一二三四五六七八九十";
    var lines = try wrapCell(cell, 6, testing.allocator);
    defer {
        for (lines.items) |l| testing.allocator.free(l);
        lines.deinit(testing.allocator);
    }
    try testing.expect(lines.items.len >= 4); // 10 字 / 3 ≈ 4 行
    for (lines.items) |l| {
        try testing.expect(term.displayWidth(l) <= 6);
        try testing.expect(std.unicode.utf8ValidateSlice(l)); // 未切多字节
    }
}

test "renderToOwned batch: table between paragraphs" {
    const md =
        "before\n" ++
        "| a | b |\n" ++
        "|---|---|\n" ++
        "| 1 | 2 |\n" ++
        "after\n";
    const r = try renderToOwned(md, testing.allocator);
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "before") != null);
    try testing.expect(std.mem.indexOf(u8, r, "after") != null);
    try testing.expect(std.mem.indexOf(u8, r, "┌") != null); // 框线在
    try testing.expect(std.mem.indexOf(u8, r, "├") != null);
    try testing.expect(std.mem.indexOf(u8, r, "└") != null);
    // 原始分隔语法不应裸出现。
    try testing.expect(std.mem.indexOf(u8, r, "|---|---|") == null);
}

test "renderToOwned: lone pipe line is NOT a table" {
    const md = "a | b is just prose\nnext line\n";
    const r = try renderToOwned(md, testing.allocator);
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "┌") == null); // 无框
    try testing.expect(std.mem.indexOf(u8, r, "a | b is just prose") != null);
}
