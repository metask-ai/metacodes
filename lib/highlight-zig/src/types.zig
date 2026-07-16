//! 核心类型。
///
/// 所有权：LangRule 里的 slice 由 Rules 拥有，Rules.deinit 释放。
/// slice 指向 Rules.data（解压后的 blob 缓冲）或 Rules.allocator 分配的子数组。
pub const TokenType = enum(u3) { none = 0, keyword, string, comment, number };

pub const ColoredSpan = struct { text: []const u8, token: TokenType };

pub const Escape = enum(u2) {
    none = 0,
    backslash = 1, // \ 转义
    double = 2,    // '' 转义（SQL/Pascal 等）

    pub fn chars(self: Escape) []const u8 {
        return switch (self) {
            .none => "",
            .backslash => "\\",
            .double => "''",
        };
    }
};

pub const StringDelim = struct {
    open: []const u8,
    close: []const u8,
    multiline: bool = false,
    escape: Escape = .backslash,
};

pub const LangRule = struct {
    name: []const u8,
    extensions: []const []const u8,
    aliases: []const []const u8 = &.{},
    /// 关键字列表，\0 分隔的 packed string（省指针开销）。
    keywords: []const u8,
    string_delims: []const StringDelim,
    comment_line: []const []const u8 = &.{},
    comment_block: []const [2][]const u8 = &.{},
    number_prefix: []const []const u8 = &.{},
};