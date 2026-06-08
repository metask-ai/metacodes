//! tree-sitter grammar 物理信息(构建期数据)。
//!
//! **这个文件被 build.zig `@import` 用于构建图**,所以:
//! - 只能是纯数据,**无 std 依赖、无任何 import**(build.zig 在构建期求值,跨编译单元)。
//! - 字段是"编译 grammar C 源需要的信息":vendor 子目录、有无 scanner.c。
//!
//! 语义信息(扩展名、有无 symbols 查询、extern fn 名)在 `src/treesitter/registry.zig`,
//! 它 `@import` 本文件取 grammar 列表,再补语义字段——保持**单一真理源**(加语言只改这里 + registry)。
//!
//! 加一门语言:在 GRAMMARS 加一条 + vendor `grammars/<dir>/src/{parser.c, scanner.c?}`。

pub const Grammar = struct {
    /// vendor/tree-sitter/grammars/ 下的子目录。多数=语言名;tsx 是 "typescript/tsx"。
    dir: []const u8,
    /// 有无 scanner.c(部分 grammar 有外部 scanner)。
    has_scanner: bool,
    /// 额外需单独编译的 .c(scanner.c 不 #include 它们时)。如 yaml 的 schema.*.c。
    /// 路径相对 grammar 的 src/。默认空。
    extra_csources: []const []const u8 = &.{},
};

pub const GRAMMARS = [_]Grammar{
    .{ .dir = "zig", .has_scanner = false },
    .{ .dir = "typescript/typescript", .has_scanner = true },
    .{ .dir = "typescript/tsx", .has_scanner = true },
    .{ .dir = "python", .has_scanner = true },
    .{ .dir = "c", .has_scanner = false },
    .{ .dir = "bash", .has_scanner = true },
    .{ .dir = "go", .has_scanner = false },
    .{ .dir = "javascript", .has_scanner = true },
    .{ .dir = "java", .has_scanner = false },
    .{ .dir = "rust", .has_scanner = true },
    .{ .dir = "cpp", .has_scanner = true },
    .{ .dir = "ruby", .has_scanner = true },
    .{ .dir = "csharp", .has_scanner = true },
    // ── 仅高亮(has_symbols=false in registry.zig)──
    .{ .dir = "json", .has_scanner = false },
    .{ .dir = "yaml", .has_scanner = true, .extra_csources = &.{ "schema.core.c", "schema.json.c", "schema.legacy.c" } },
    .{ .dir = "toml", .has_scanner = true },
    .{ .dir = "html", .has_scanner = true },
    .{ .dir = "css", .has_scanner = true },
    .{ .dir = "markdown", .has_scanner = true },
};
