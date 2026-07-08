//! B/C 合并:AutoMem markdown 自动入图(KG 唯一真相)。
//!
//! 模型用 Write/Edit 管理 memdir(`{home}/.metacodes/projects/<hash>/memory/*.md`)——通道 B。
//! 本模块把落盘的记忆 markdown **自动** import 进 tinykg(通道 C):
//! Write/Edit 成功后调 maybeImportMemoryFile → importMarkdownDoc(内容 hash 幂等,同内容不重导)
//! → document 根自动挂进 project 子树(client.attachToProject)→ search --project 沿 md:* 投影
//! 下钻 section 正文(tinykg c598e75)→ **KgRecall/scoped 自动召回同一条路覆盖结构化 + 叙事记忆**。
//!
//! 纪律:
//! - **best-effort,绝不影响工具结果**(KG 是增强非依赖):任何失败只 log warn。
//! - MEMORY.md(索引文件)不入图——它是目录不是记忆内容,且每次记忆更新都会改它(噪声)。
//! - 只处理 .md;isAutoMemPath realpath 归一化防穿越(复用权限豁免同一判定)。
//! - 文件更新 = 新 document(旧成孤儿,gc-md-orphans 低频清;external_key 复用是后续优化)。

const std = @import("std");
const memdir = @import("../core/memory/memdir.zig");
const log = @import("../util/log.zig");
const ToolContext = @import("../tools/context.zig").ToolContext;

/// Write/Edit 成功落盘后调用:若 path 是 memdir 内记忆 markdown → 自动入图。
/// content = 落盘后的**全文**(Edit 调用方负责读盘)。所有失败静默降级(仅 log)。
pub fn maybeImportMemoryFile(ctx: *const ToolContext, path: []const u8, content: []const u8) void {
    const kg = ctx.kg orelse return;
    if (ctx.memdir_abs.len == 0) return;
    if (!std.mem.endsWith(u8, path, ".md")) return;
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "MEMORY.md")) return; // 索引非记忆
    if (std.mem.trim(u8, content, " \t\r\n").len == 0) return; // 空文件无意义
    if (!memdir.isAutoMemPath(ctx.allocator, ctx.memdir_abs, path)) return;

    const doc_id = kg.importMarkdownDoc(content) catch |e| {
        log.warn("kg", "AutoMem markdown 入图失败({s}): {s}", .{ @errorName(e), base });
        return;
    };
    log.info("kg", "AutoMem markdown 入图: {s} → document {d}", .{ base, doc_id });
}
