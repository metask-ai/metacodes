//! B/C 合并:AutoMem markdown 自动入图(KG 唯一真相)。
//!
//! 模型用 Write/Edit 管理 memdir(`{home}/.metacodes/projects/<hash>/memory/*.md`)——通道 B。
//! 本模块把落盘的记忆 markdown **自动** import 进 tinykg(通道 C):
//! Write/Edit 成功后调 maybeImportMemoryFile → **importMarkdownDocStable(文件路径 hash 做稳定
//! key)** → tinykg 真 upsert(同文件同 document,增量合并删旧投影边 projection_edges_deleted)
//! → document 根自动挂 project 子树 → search --project 沿 md:* 投影下钻 section 正文
//! → **KgRecall/scoped 自动召回同一条路覆盖结构化 + 叙事记忆,且永远只见最新版**。
//!
//! 为什么必须稳定 upsert 而非"content-hash 新 doc + 删旧 doc"(Linus BLOCKER 的第一版修法):
//! import 按 text 复用 section 节点(实证:v1/v2 共享 "## root cause" 节点),共享节点持旧
//! md:* 出边把**旧正文接进新子树**——删旧 doc 根也断不开,旧版本永远在召回里。稳定 upsert 让
//! tinykg 自己替换投影边(旧正文变孤儿退出 membership,gc-md-orphans 事后清),语义才干净。
//! 代价:增量合并 order_key 撞车会乱 render 顺序——记忆召回不 render(真相在磁盘 md 文件),
//! 无影响;render 顺序敏感的 plan 走 content-hash 版 importMarkdownDoc,不受影响。
//!
//! 纪律:
//! - **best-effort,绝不影响工具结果**(KG 是增强非依赖):任何失败只 log warn。
//! - MEMORY.md(索引文件)不入图——它是目录不是记忆内容,且每次记忆更新都会改它(噪声)。
//! - 只处理 .md;isAutoMemPath realpath 归一化防穿越(复用权限豁免同一判定)。

const std = @import("std");
const memdir = @import("../core/memory/memdir.zig");
const log = @import("../util/log.zig");
const ToolContext = @import("../tools/context.zig").ToolContext;

/// Write/Edit 成功落盘后调用:若 path 是 memdir 内记忆 markdown → 稳定 upsert 入图。
/// content = 落盘后的**全文**(Edit 调用方负责传编辑后全文)。所有失败静默降级(仅 log)。
pub fn maybeImportMemoryFile(ctx: *const ToolContext, path: []const u8, content: []const u8) void {
    const kg = ctx.kg orelse return;
    if (ctx.memdir_abs.len == 0) return;
    if (!std.mem.endsWith(u8, path, ".md")) return;
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "MEMORY.md")) return; // 索引非记忆
    // canonical 判定 + 派生一体(Linus 复审严重条):stable_key 必须哈希 **canonical** 路径。
    // 哈希裸 path 的话,同一文件的不同拼写(APFS 大小写不敏感 / /tmp vs /private/tmp /
    // symlink / 相对路径)各算一个 key → 各建一个 document → 旧版本永久留在召回里。
    const canon = memdir.canonicalAutoMemPath(ctx.allocator, ctx.memdir_abs, path) orelse return;
    defer ctx.allocator.free(canon);

    // 稳定 key = canonical 路径 hash:同文件永远 upsert 同一 document(旧投影边被 tinykg
    // 替换,旧正文退出召回)。
    const stable_key = std.hash.Wyhash.hash(0x9e3d, canon);

    // **删除语义(PM P0-2)**:Write 空内容 = 删除记忆——空 upsert 让 tinykg 删旧投影边,
    // 旧正文退出召回(否则"删错误记忆"这个被 prompt 明确鼓励的动作删不掉图里的幽灵版本,
    // 错误记忆以最高置信形态持续注入未来 session)。Memory 段指引模型用 Write 清空而非 rm。
    if (std.mem.trim(u8, content, " \t\r\n").len == 0) {
        kg.clearMarkdownDocStable(stable_key) catch |e| {
            log.warn("kg", "AutoMem markdown 图删除失败({s}): {s}", .{ @errorName(e), base });
            kg.noteAutosync(@errorName(e), base);
            return;
        };
        log.info("kg", "AutoMem markdown 图删除(空 upsert): {s}", .{base});
        kg.noteAutosync(null, base);
        return;
    }

    const doc_id = kg.importMarkdownDocLabeled(content, stable_key, base) catch |e| {
        log.warn("kg", "AutoMem markdown 入图失败({s}): {s}", .{ @errorName(e), base });
        kg.noteAutosync(@errorName(e), base);
        return;
    };
    log.info("kg", "AutoMem markdown 入图(upsert): {s} → document {d}", .{ base, doc_id });
    kg.noteAutosync(null, base);
}

pub const SyncStats = struct { synced: u32 = 0, failed: u32 = 0, skipped: u32 = 0 };

/// /kg sync:遍历 memdir/*.md 重跑稳定 upsert(PM P1:手工 vim 编辑文件不经 Write 工具
/// → 图里永远旧版;本命令给用户一个明确的 reconcile 出口)。upsert 幂等:未变的文件
/// tinykg 侧 nodes_imported=0,重跑无害。MEMORY.md/隐藏文件/非 .md 跳过。
pub fn syncAll(allocator: std.mem.Allocator, kg: *@import("client.zig").KgClient, memdir_abs: []const u8) SyncStats {
    var stats = SyncStats{};
    if (memdir_abs.len == 0) return stats;
    const dir_z = allocator.dupeZ(u8, memdir_abs) catch return stats;
    defer allocator.free(dir_z);
    const dir = std.c.opendir(dir_z) orelse return stats; // memdir 不存在即 no-op
    defer _ = std.c.closedir(dir);

    while (std.c.readdir(dir)) |entry_ptr| {
        const entry = entry_ptr.*;
        const name = std.mem.sliceTo(&entry.name, 0);
        if (name.len == 0 or name[0] == '.') continue;
        if (!std.mem.endsWith(u8, name, ".md")) continue;
        if (std.mem.eql(u8, name, "MEMORY.md")) {
            stats.skipped += 1;
            continue;
        }
        const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ memdir_abs, name }) catch return stats;
        defer allocator.free(full);
        const content = readWholeFile(allocator, full) orelse {
            stats.failed += 1;
            continue;
        };
        defer allocator.free(content);
        // 与 Write 钩子同一套 canonical key 派生(单一基准)。
        const canon = memdir.canonicalAutoMemPath(allocator, memdir_abs, full) orelse {
            stats.skipped += 1;
            continue;
        };
        defer allocator.free(canon);
        const stable_key = std.hash.Wyhash.hash(0x9e3d, canon);
        if (std.mem.trim(u8, content, " \t\r\n").len == 0) {
            kg.clearMarkdownDocStable(stable_key) catch {
                stats.failed += 1;
                continue;
            };
        } else {
            _ = kg.importMarkdownDocLabeled(content, stable_key, name) catch {
                stats.failed += 1;
                continue;
            };
        }
        stats.synced += 1;
    }
    return stats;
}

fn readWholeFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const path_z = allocator.dupeZ(u8, path) catch return null;
    defer allocator.free(path_z);
    const fd = std.posix.openat(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.c.close(fd);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        out.appendSlice(allocator, buf[0..@intCast(n)]) catch {
            out.deinit(allocator);
            return null;
        };
        if (out.items.len > 8 << 20) break; // 8MB 防呆
    }
    return out.toOwnedSlice(allocator) catch null;
}
