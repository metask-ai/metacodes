//! hl-zig — 轻量代码高亮引擎。4 类 token 状态机，零依赖纯 Zig。
//! 223 语言规则从 Prism grammar 提取，zlib 压缩后 @embedFile，运行时解压。
pub const types = @import("types.zig");
pub const engine = @import("engine.zig");
pub const ansi = @import("ansi.zig");
pub const rules = @import("rules.zig");

pub const LangRule = types.LangRule;
pub const ColoredSpan = types.ColoredSpan;
pub const TokenType = types.TokenType;
pub const StringDelim = types.StringDelim;
pub const Escape = types.Escape;
pub const Rules = rules.Rules;
pub const Palette = ansi.Palette;
pub const tokenize = engine.tokenize;
pub const colorize = ansi.colorize;
pub const colorizeSource = ansi.colorizeSource;
pub const lookupByExtension = rules.lookupByExtension;
pub const lookupByName = rules.lookupByName;
pub const ruleCount = rules.ruleCount;
pub const ruleAt = rules.ruleAt;