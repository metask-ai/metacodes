//! tree-sitter 语言注册表——**单一真理源**(语义信息)。
//!
//! 每个 Lang 一条 LangSpec:enum tag、extern fn 名、扩展名、有无 symbols 查询。
//! `ts.zig` 的 language()/fromPath/extern 一致性、`highlight.zig`/`symbols.zig` 的查询嵌入
//! 都从这里 `inline for` 生成/校验。加一门语言 = 这里加一行(+ vendor grammar + 2 个 .scm)。
//!
//! grammar 物理信息(编译 C 源用)在 `vendor/tree-sitter/grammars.zig`(build.zig 也 import 它)。
//! 本文件聚焦"运行时/编译期语义",不碰构建图。

const std = @import("std");

pub const LangSpec = struct {
    /// 对应 ts.zig `Lang` enum 的 tag 名(必须逐一对应,有 comptime 断言守卫)。
    tag: []const u8,
    /// grammar 导出的 language 入口 extern fn 名(parser.c 里 `tree_sitter_<x>`)。
    ts_fn: []const u8,
    /// 查询文件基名(queries/<query_name>.scm 与 queries/highlights/<query_name>.scm)。
    /// 多数 = tag;但 tsx 复用 typescript 的查询 → query_name="typescript"。
    query_name: []const u8,
    /// 文件扩展名(含点,小写),fromPath 用。
    extensions: []const []const u8,
    /// 是否有 symbols 查询(queries/<query_name>.scm)。false → CodeMap/FindSymbol 对它
    /// fallback Grep,仅 highlights 可用。所有语言都需 highlights(queries/highlights/<query_name>.scm)。
    has_symbols: bool,
};

/// 顺序必须与 ts.zig `Lang` enum 成员顺序一致(comptime 断言会校验 tag 对应)。
pub const LANGS = [_]LangSpec{
    .{ .tag = "zig", .ts_fn = "tree_sitter_zig", .query_name = "zig", .extensions = &.{".zig"}, .has_symbols = true },
    .{ .tag = "typescript", .ts_fn = "tree_sitter_typescript", .query_name = "typescript", .extensions = &.{ ".ts", ".mts", ".cts" }, .has_symbols = true },
    .{ .tag = "tsx", .ts_fn = "tree_sitter_tsx", .query_name = "typescript", .extensions = &.{ ".tsx", ".jsx" }, .has_symbols = true },
    .{ .tag = "python", .ts_fn = "tree_sitter_python", .query_name = "python", .extensions = &.{ ".py", ".pyi" }, .has_symbols = true },
    .{ .tag = "c", .ts_fn = "tree_sitter_c", .query_name = "c", .extensions = &.{ ".c", ".h" }, .has_symbols = true },
    .{ .tag = "bash", .ts_fn = "tree_sitter_bash", .query_name = "bash", .extensions = &.{ ".sh", ".bash" }, .has_symbols = true },
    .{ .tag = "go", .ts_fn = "tree_sitter_go", .query_name = "go", .extensions = &.{".go"}, .has_symbols = true },
    .{ .tag = "javascript", .ts_fn = "tree_sitter_javascript", .query_name = "javascript", .extensions = &.{ ".js", ".mjs", ".cjs" }, .has_symbols = true },
    .{ .tag = "java", .ts_fn = "tree_sitter_java", .query_name = "java", .extensions = &.{".java"}, .has_symbols = true },
    .{ .tag = "rust", .ts_fn = "tree_sitter_rust", .query_name = "rust", .extensions = &.{".rs"}, .has_symbols = true },
    .{ .tag = "cpp", .ts_fn = "tree_sitter_cpp", .query_name = "cpp", .extensions = &.{ ".cpp", ".cc", ".cxx", ".hpp", ".hh" }, .has_symbols = true },
    .{ .tag = "ruby", .ts_fn = "tree_sitter_ruby", .query_name = "ruby", .extensions = &.{ ".rb", ".rake" }, .has_symbols = true },
    .{ .tag = "csharp", .ts_fn = "tree_sitter_c_sharp", .query_name = "csharp", .extensions = &.{".cs"}, .has_symbols = true },
    // ── 仅高亮(has_symbols=false → CodeMap/FindSymbol fallback Grep)──
    .{ .tag = "json", .ts_fn = "tree_sitter_json", .query_name = "json", .extensions = &.{".json"}, .has_symbols = false },
    .{ .tag = "yaml", .ts_fn = "tree_sitter_yaml", .query_name = "yaml", .extensions = &.{ ".yaml", ".yml" }, .has_symbols = false },
    .{ .tag = "toml", .ts_fn = "tree_sitter_toml", .query_name = "toml", .extensions = &.{".toml"}, .has_symbols = false },
    .{ .tag = "html", .ts_fn = "tree_sitter_html", .query_name = "html", .extensions = &.{ ".html", ".htm" }, .has_symbols = false },
    .{ .tag = "css", .ts_fn = "tree_sitter_css", .query_name = "css", .extensions = &.{".css"}, .has_symbols = false },
    .{ .tag = "markdown", .ts_fn = "tree_sitter_markdown", .query_name = "markdown", .extensions = &.{ ".md", ".markdown" }, .has_symbols = false },
};

/// 按 tag 找 LangSpec(comptime 用)。
pub fn specForTag(comptime tag: []const u8) ?LangSpec {
    inline for (LANGS) |s| {
        if (std.mem.eql(u8, s.tag, tag)) return s;
    }
    return null;
}

/// 该 Lang 是否有 symbols 查询(CodeMap/FindSymbol/outline 可用)。运行时按 tag 匹配。
/// 仅高亮语言(json/yaml/...)返回 false → 调用方回退(outline 退回正常读、CodeMap fallback Grep)。
pub fn hasSymbols(lang: anytype) bool {
    inline for (LANGS) |s| {
        if (lang == @field(@TypeOf(lang), s.tag)) return s.has_symbols;
    }
    return false;
}
