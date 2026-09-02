//! Session transcript 持久化。
//!
//! 设计：
//! - **布局**：`$HOME/.metacodes/projects/<cwd_hash>/<session_id>/transcript.jsonl + meta.json`
//! - `cwd_hash`：cwd 的 xxhash64 → 16-char hex；同一项目目录的 session 聚在一起
//! - `session_id`：启动时生成（毫秒时间戳 hex + 4 byte 随机 hex），自然按时间排序
//! - **transcript.jsonl**：每 turn 结束时把 **新增** 的 message 追加成 JSONL
//!   - 每行一个 JSON：`{"role": "user|assistant", "blocks": [...]}`
//!   - blocks 数组里元素按类型序列化：
//!     - `{"type":"text","text":"..."}`
//!     - `{"type":"tool_use","id":"","name":"","input":"<json string>"}`
//!     - `{"type":"tool_result","tool_use_id":"","content":"...","is_error":bool}`
//!     - `{"type":"thinking","thinking":"..."}`
//!     - `{"type":"image","media_type":"image/png","data":"<base64>"}`
//!     - `{"type":"reasoning_item","model":"<model>","item":"<provider item JSON>"}`
//! - **meta.json**：每次写 transcript 后覆盖写入 {model, last_modified_ns, message_count, title_guess}
//! - **title_guess**：首条 user text 的前 80 字节（去换行）
//! - **加载**：逐行 parse JSONL 重建 Conversation；meta 用于 /resume 列表
//!
//! 崩溃安全：JSONL append 原子性取决于 write(2) ≤ PIPE_BUF（Linux 4096 字节），
//! 超大 message（tool_use input 上 MB）不保证原子，但本期 MVP 接受此代价。
//! meta.json 用 rename() 原子替换。

const std = @import("std");
const pfs = @import("platform").fs;
const pdir = @import("platform").dir;
const msg_mod = @import("message.zig");
const Conversation = @import("conversation.zig").Conversation;
const types = @import("../types.zig");
const util_json = @import("../util/json.zig");
const util_fs = @import("../util/fs.zig");
const util_time = @import("../util/time.zig");
const log = @import("../util/log.zig");

const session_id_mod = @import("session_id.zig");
pub const SessionId = session_id_mod.SessionId;

/// genSessionId 是 session_id.gen 的兼容别名(保留供既有调用方;新代码直接用 session_id.gen)。
pub fn genSessionId() SessionId {
    return session_id_mod.gen();
}

/// 计算 cwd hash（xxhash64 lo 32 位 hex + hi 32 位 hex）。
pub fn hashCwd(cwd: []const u8) [16]u8 {
    const h = std.hash.XxHash64.hash(0, cwd);
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>16}", .{h}) catch unreachable;
    return out;
}

pub const Metadata = struct {
    model: []const u8, // borrowed slice; don't free
    last_modified_ns: i128,
    message_count: usize,
    title_guess: []const u8, // borrowed
};

pub const Writer = struct {
    allocator: std.mem.Allocator,
    /// session 目录（owned）。basename 就是 session_id，想展示给用户时从这里 parse。
    dir: []const u8,
    /// transcript 文件 fd；FD_UNSET 表未打开（首次 flush 时懒打开）
    fd: pfs.Fd = FD_UNSET,
    /// 已刷盘的 message 数；下次 flush 从这里开始
    flushed_count: usize = 0,
    /// 上次 flush 时见到的 conversation.shrink_epoch(前缀破坏代数;不等 → 全量重写)。
    seen_shrink_epoch: u64 = 0,
    model: []const u8, // borrowed (session 期间不变)

    /// "fd 未打开" 哨兵值。POSIX 约定负 fd 无效。
    const FD_UNSET: pfs.Fd = -1;

    pub fn init(
        allocator: std.mem.Allocator,
        cwd: []const u8,
        home: []const u8,
        model: []const u8,
        /// 会话 id(由 App 传入,统一 App.session_id 与 transcript 目录名)。
        sid: SessionId,
    ) !Writer {
        const cwd_hash = hashCwd(cwd);

        // 构造路径 $HOME/.metacodes/projects/<cwd_hash>/<session_id>/
        const dir = try std.fmt.allocPrint(allocator, "{s}/.metacodes/projects/{s}/{s}", .{ home, cwd_hash[0..], sid.bytes[0..] });
        errdefer allocator.free(dir);

        // mkdir -p 递归
        try util_fs.mkdirParents(dir);

        log.info("transcript", "session dir={s}", .{dir});
        return .{
            .allocator = allocator,
            .dir = dir,
            .model = model,
            .fd = FD_UNSET,
            .flushed_count = 0,
        };
    }

    /// 从已存在的 session 目录恢复 writer。用于 /resume 后继续追加。
    /// `already_flushed` 告诉 writer 这个目录里的 transcript 已有多少条 message，
    /// 下次 flush 会跳过它们。`dir` 必须是 caller 拥有的 slice，Writer 取走所有权。
    pub fn openExisting(
        allocator: std.mem.Allocator,
        dir_owned: []const u8,
        model: []const u8,
        already_flushed: usize,
    ) Writer {
        return .{
            .allocator = allocator,
            .dir = dir_owned,
            .model = model,
            .fd = FD_UNSET,
            .flushed_count = already_flushed,
        };
    }

    pub fn deinit(self: *Writer) void {
        if (self.fd != FD_UNSET) _ = pfs.close(self.fd);
        self.allocator.free(self.dir);
    }

    /// 把 conversation 里从 flushed_count 起的所有 message 追加到 transcript。
    /// 同时覆盖写 meta.json。失败不 panic——记录 warn 就行（不影响 session 继续）。
    pub fn flush(self: *Writer, conversation: *const Conversation) void {
        self.flushImpl(conversation) catch |err| {
            log.warn("transcript", "flush failed: {s}", .{@errorName(err)});
        };
    }

    fn flushImpl(self: *Writer, conversation: *const Conversation) !void {
        // 前缀破坏(/retry 回卷、compact replaceWithOwned)后 append-only 假设失效:
        // flushed_count 单调 + O_APPEND 意味着"回卷再涨回同长度"的重生成回合永不落盘,
        // resume 读回的是被丢弃的旧回合(R2/F1)。据 conversation.shrink_epoch 察觉,
        // 原子全量重写(tmp + renameReplace,崩溃窗口只丢本次重写,不产生半文件)。
        if (self.seen_shrink_epoch != conversation.shrink_epoch) {
            try self.rewriteAll(conversation);
            self.seen_shrink_epoch = conversation.shrink_epoch;
        }
        if (self.fd == FD_UNSET) {
            var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
            const path = try std.fmt.bufPrint(&pbuf, "{s}/transcript.jsonl\x00", .{self.dir});
            self.fd = pfs.open(@ptrCast(path.ptr), .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o600));
            if (self.fd < 0) {
                self.fd = FD_UNSET; // 保持 sentinel 语义；下次 flush 会再试
                return error.OpenFailed;
            }
        }

        const messages = conversation.messages.items;
        while (self.flushed_count < messages.len) : (self.flushed_count += 1) {
            const m = messages[self.flushed_count];
            try self.writeMessage(&m);
        }

        try self.writeMeta(conversation);
    }

    /// 全量重写 transcript.jsonl(见 flushImpl 注)。借用 writeMessage:临时把 self.fd
    /// 指向 tmp 文件写全量,成功后 renameReplace 原子替换,fd 复位 FD_UNSET(下次 flush
    /// 重新以 O_APPEND 打开新文件,恢复 append-crash 语义)。任何失败都恢复原 fd 语义。
    fn rewriteAll(self: *Writer, conversation: *const Conversation) !void {
        if (self.fd != FD_UNSET) {
            _ = pfs.close(self.fd);
            self.fd = FD_UNSET;
        }
        var tbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&tbuf, "{s}/transcript.jsonl.tmp\x00", .{self.dir});
        const tmp_fd = pfs.open(@ptrCast(tmp_path.ptr), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        if (tmp_fd < 0) return error.OpenFailed;
        self.fd = tmp_fd;
        errdefer {
            _ = pfs.close(self.fd);
            self.fd = FD_UNSET;
        }
        for (conversation.messages.items) |*m| try self.writeMessage(m);
        _ = pfs.close(self.fd);
        self.fd = FD_UNSET;
        var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const path = try std.fmt.bufPrint(&pbuf, "{s}/transcript.jsonl\x00", .{self.dir});
        if (pfs.renameReplace(@ptrCast(tmp_path.ptr), @ptrCast(path.ptr)) != 0) return error.RenameFailed;
        self.flushed_count = conversation.messages.items.len;
    }

    fn writeMessage(self: *Writer, m: *const msg_mod.Message) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        try aw.writer.writeAll("{\"role\":\"");
        try aw.writer.writeAll(roleStr(m.role));
        // 送达水位随消息持久化(消息级 + 每个 tool_result 块级):resume 后图片结果的
        // microcompact 保护与请求级裁剪都靠它,不再从消息位置推断。旧文件缺字段 → false(保守)。
        try aw.writer.print("\",\"delivered\":{s},\"blocks\":[", .{if (m.delivered) "true" else "false"});
        for (m.blocks, 0..) |b, i| {
            if (i > 0) try aw.writer.writeAll(",");
            switch (b) {
                .text => |t| {
                    try aw.writer.writeAll("{\"type\":\"text\",\"text\":");
                    try std.json.Stringify.encodeJsonString(t, .{}, &aw.writer);
                    try aw.writer.writeAll("}");
                },
                .tool_use => |tu| {
                    try aw.writer.writeAll("{\"type\":\"tool_use\",\"id\":");
                    try std.json.Stringify.encodeJsonString(tu.id, .{}, &aw.writer);
                    try aw.writer.writeAll(",\"name\":");
                    try std.json.Stringify.encodeJsonString(tu.name, .{}, &aw.writer);
                    try aw.writer.writeAll(",\"input\":");
                    try std.json.Stringify.encodeJsonString(tu.input, .{}, &aw.writer);
                    try aw.writer.writeAll("}");
                },
                .tool_result => |tr| {
                    try aw.writer.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
                    try std.json.Stringify.encodeJsonString(tr.tool_use_id, .{}, &aw.writer);
                    try aw.writer.writeAll(",\"content\":");
                    try std.json.Stringify.encodeJsonString(tr.content, .{}, &aw.writer);
                    try aw.writer.print(",\"is_error\":{s},\"delivered\":{s}", .{ if (tr.is_error) "true" else "false", if (tr.delivered) "true" else "false" });
                    try aw.writer.writeAll("}");
                },
                .thinking => |t| {
                    try aw.writer.writeAll("{\"type\":\"thinking\",\"thinking\":");
                    try std.json.Stringify.encodeJsonString(t, .{}, &aw.writer);
                    try aw.writer.writeAll("}");
                },
                .image => |img| {
                    // base64 载荷 JSON 安全;resume 后图像语义原样恢复(issue #10)。
                    try aw.writer.writeAll("{\"type\":\"image\",\"media_type\":");
                    try std.json.Stringify.encodeJsonString(img.media_type, .{}, &aw.writer);
                    try aw.writer.writeAll(",\"data\":");
                    try std.json.Stringify.encodeJsonString(img.data, .{}, &aw.writer);
                    try aw.writer.writeAll("}");
                },
                .reasoning_item => |item| {
                    // provider 私有的推理续传项:item JSON 作为**字符串**存(不内联
                    // 展开),resume 后逐字节还原后回传(issue #23)。
                    try aw.writer.writeAll("{\"type\":\"reasoning_item\",\"model\":");
                    try std.json.Stringify.encodeJsonString(item.model, .{}, &aw.writer);
                    try aw.writer.writeAll(",\"item\":");
                    try std.json.Stringify.encodeJsonString(item.json, .{}, &aw.writer);
                    try aw.writer.writeAll("}");
                },
            }
        }
        try aw.writer.writeAll("]}\n");

        const bytes = aw.written();
        const n = pfs.write(self.fd, bytes);
        if (n < 0 or @as(usize, @intCast(n)) != bytes.len) return error.WriteFailed;
    }

    fn writeMeta(self: *Writer, conversation: *const Conversation) !void {
        const messages = conversation.messages.items;
        // title_guess：首条 user text 的前 80 字节
        var title: []const u8 = "";
        for (messages) |m| {
            if (m.role != .user) continue;
            for (m.blocks) |b| if (b == .text) {
                title = b.text[0..@min(b.text.len, 80)];
                break;
            };
            if (title.len > 0) break;
        }
        // 纯图会话兜底:整个扫描找不到任何 user text(--image 允许空 prompt)才落
        // "[image]" 标签——首条是图、后续消息有 text 时,text 仍然胜出(不因图占位
        // 而永远锁死 /resume 列表标题)。
        if (title.len == 0) {
            outer: for (messages) |m| {
                if (m.role != .user) continue;
                for (m.blocks) |b| if (b == .image) {
                    title = "[image]";
                    break :outer;
                };
            }
        }

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try aw.writer.writeAll("{\"model\":");
        try std.json.Stringify.encodeJsonString(self.model, .{}, &aw.writer);
        try aw.writer.print(",\"last_modified_ns\":{d},\"message_count\":{d},\"title_guess\":", .{ util_time.nowWallNs(), messages.len });
        try std.json.Stringify.encodeJsonString(title, .{}, &aw.writer);
        // A(P1.5 投影持久化):存 compact_boundary + compact_summary,resume 时恢复投影窗口,
        // 避免重放全量历史 + 首个请求重复压缩(对齐 cc 的 compact boundary 持久化)。
        try aw.writer.print(",\"compact_boundary\":{d},\"compact_summary\":", .{conversation.compact_boundary});
        if (conversation.compact_summary) |s| {
            try std.json.Stringify.encodeJsonString(s, .{}, &aw.writer);
        } else {
            try aw.writer.writeAll("null");
        }
        try aw.writer.writeAll("}\n");

        // 原子替换：写到 meta.json.tmp 再 rename
        var tpath_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const tpath = try std.fmt.bufPrint(&tpath_buf, "{s}/meta.json.tmp\x00", .{self.dir});
        const tfd = pfs.open(@ptrCast(tpath.ptr), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        if (tfd < 0) return error.OpenFailed;

        const bytes = aw.written();
        const n = pfs.write(tfd, bytes);
        pfs.close(tfd); // **rename 前关**:Windows MoveFileEx 遇源仍打开会共享冲突(POSIX 容忍)。
        if (n < 0 or @as(usize, @intCast(n)) != bytes.len) return error.WriteFailed;

        var fpath_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const fpath = try std.fmt.bufPrint(&fpath_buf, "{s}/meta.json\x00", .{self.dir});
        if (pfs.renameReplace(@ptrCast(tpath.ptr), @ptrCast(fpath.ptr)) != 0) return error.RenameFailed;
    }
};

fn roleStr(r: types.MessageRole) []const u8 {
    return switch (r) {
        .user => "user",
        .assistant => "assistant",
    };
}

// nowNs 下沉到 util/time.zig（这里用的是 wall clock REALTIME）

/// 读一块 transcript/meta 字节。负值是 I/O 错误,不是 EOF:当 EOF 处理会把一个
/// 被截断的前缀当作完整历史"成功"恢复(PR #46 review B)。其中 EINTR 直接重试——
/// SIGINT/SIGWINCH 处理器未设 SA_RESTART,/resume 读文件期间一次 Ctrl+C 或终端
/// resize 就会打断 read,这不该让恢复失败(review F5);其它错误才是 ReadFailed。
fn readChunk(fd: c_int, buf: []u8) error{ReadFailed}!usize {
    while (true) {
        const n = pfs.read(fd, buf);
        if (n >= 0) return @intCast(n);
        if (comptime @import("builtin").os.tag != .windows) {
            if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
        }
        return error.ReadFailed;
    }
}

// ============================================================================
// 加载器：从 transcript.jsonl 重建 Conversation
// ============================================================================

/// 从 session 目录加载 transcript，把所有 message append 到 conversation。
/// 失败则 conversation 保持调用前状态。
pub fn loadTranscript(conversation: *Conversation, session_dir: []const u8, allocator: std.mem.Allocator) !void {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "{s}/transcript.jsonl\x00", .{session_dir});
    const fd = pfs.open(@ptrCast(path.ptr), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);

    // 读整文件
    var all = std.ArrayList(u8).empty;
    defer all.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try readChunk(fd, &buf);
        if (n == 0) break;
        try all.appendSlice(allocator, buf[0..@intCast(n)]);
    }

    // 按行解析。**全解析成功才提交**:此前是边解析边 append,任何一行失败都会
    // 给调用方留下一个半填充的 conversation——一个"恢复了一半的会话"比明确失败
    // 危险得多,模型会拿着残缺历史继续往下写。先落到暂存表,全部成功再整体转移。
    var staged: std.ArrayList(msg_mod.Message) = .empty;
    defer staged.deinit(allocator);
    errdefer for (staged.items) |m| m.deinit(allocator);

    var line_start: usize = 0;
    while (line_start < all.items.len) {
        const nl = std.mem.indexOfScalarPos(u8, all.items, line_start, '\n') orelse all.items.len;
        const line = all.items[line_start..nl];
        line_start = nl + 1;
        if (line.len == 0) continue;

        const parsed = try parseMessageLine(line, allocator);
        errdefer parsed.deinit(allocator);
        try staged.append(allocator, parsed);
    }
    // 批量接管:预留成功后逐条追加不可能失败,所以要么一条不进、要么全进。
    // 逐条 append 在第 k>0 条扩容失败时会让前 k 条同时归 conversation 和上面的
    // errdefer 所有——调用方 deinit conversation 就是 use-after-free。
    try conversation.appendAllOwned(staged.items);
    staged.clearRetainingCapacity(); // 所有权已转移给 conversation

    // A:恢复投影状态(compact_boundary/summary)。失败非致命——退回全量重放(旧行为),不阻断 resume。
    loadCompactStateFromMeta(conversation, session_dir, allocator) catch |err| {
        log.warn("transcript", "compact state restore skipped: {s}", .{@errorName(err)});
    };
}

/// 从 meta.json 恢复 compact_boundary + compact_summary 到 conversation(A:投影持久化)。
/// meta 不存在/无这些字段(旧 session)→ boundary=0/summary=null(无投影,全量重放,与旧行为一致)。
fn loadCompactStateFromMeta(conversation: *Conversation, session_dir: []const u8, allocator: std.mem.Allocator) !void {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "{s}/meta.json\x00", .{session_dir});
    const fd = pfs.open(@ptrCast(path.ptr), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return; // 无 meta → 无投影状态,静默(旧 session 兼容)
    defer _ = pfs.close(fd);

    var all = std.ArrayList(u8).empty;
    defer all.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try readChunk(fd, &buf);
        if (n == 0) break;
        try all.appendSlice(allocator, buf[0..@intCast(n)]);
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, all.items, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const boundary_v = parsed.value.object.get("compact_boundary");
    const boundary: usize = if (boundary_v) |bv| (if (bv == .integer and bv.integer >= 0) @intCast(bv.integer) else 0) else 0;
    const summary: ?[]const u8 = blk: {
        const sv = parsed.value.object.get("compact_summary") orelse break :blk null;
        break :blk if (sv == .string) sv.string else null;
    };
    if (boundary == 0 and summary == null) return; // 无投影,保持默认
    try conversation.restoreCompactState(boundary, summary);
}

/// 解析一行 JSONL 为 Message。字符串字段 dupe 成 owned。
fn parseMessageLine(line: []const u8, allocator: std.mem.Allocator) !msg_mod.Message {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidTranscript;

    const role_v = root.object.get("role") orelse return error.InvalidTranscript;
    if (role_v != .string) return error.InvalidTranscript;
    const role: types.MessageRole = if (std.mem.eql(u8, role_v.string, "user"))
        .user
    else if (std.mem.eql(u8, role_v.string, "assistant"))
        .assistant
    else
        return error.InvalidTranscript;

    const msg_delivered = if (root.object.get("delivered")) |dv| (dv == .bool and dv.bool) else false;
    const blocks_v = root.object.get("blocks") orelse return error.InvalidTranscript;
    if (blocks_v != .array) return error.InvalidTranscript;

    const blocks = try allocator.alloc(msg_mod.Block, blocks_v.array.items.len);
    errdefer allocator.free(blocks);
    var constructed: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < constructed) : (i += 1) blocks[i].deinit(allocator);
    }

    for (blocks_v.array.items, 0..) |bv, idx| {
        if (bv != .object) return error.InvalidTranscript;
        const tv = bv.object.get("type") orelse return error.InvalidTranscript;
        if (tv != .string) return error.InvalidTranscript;

        if (std.mem.eql(u8, tv.string, "text")) {
            const t = bv.object.get("text") orelse return error.InvalidTranscript;
            if (t != .string) return error.InvalidTranscript;
            blocks[idx] = .{ .text = try allocator.dupe(u8, t.string) };
        } else if (std.mem.eql(u8, tv.string, "tool_use")) {
            const id = bv.object.get("id") orelse return error.InvalidTranscript;
            const name = bv.object.get("name") orelse return error.InvalidTranscript;
            const input = bv.object.get("input") orelse return error.InvalidTranscript;
            if (id != .string or name != .string or input != .string) return error.InvalidTranscript;
            // 逐字段 errdefer:第 2/3 个 dupe OOM 时,已 dupe 的前串未进 blocks
            // (constructed 尚未 +1),函数级清理够不到——必须在此释放。
            const id_owned = try allocator.dupe(u8, id.string);
            errdefer allocator.free(id_owned);
            const name_owned = try allocator.dupe(u8, name.string);
            errdefer allocator.free(name_owned);
            blocks[idx] = .{ .tool_use = .{
                .id = id_owned,
                .name = name_owned,
                .input = try allocator.dupe(u8, input.string),
            } };
        } else if (std.mem.eql(u8, tv.string, "tool_result")) {
            const tuid = bv.object.get("tool_use_id") orelse return error.InvalidTranscript;
            const c = bv.object.get("content") orelse return error.InvalidTranscript;
            const is_err = bv.object.get("is_error") orelse std.json.Value{ .bool = false };
            const delivered_v = bv.object.get("delivered") orelse std.json.Value{ .bool = false };
            if (tuid != .string or c != .string) return error.InvalidTranscript;
            const tuid_owned = try allocator.dupe(u8, tuid.string);
            errdefer allocator.free(tuid_owned);
            blocks[idx] = .{ .tool_result = .{
                .tool_use_id = tuid_owned,
                .content = try allocator.dupe(u8, c.string),
                .is_error = if (is_err == .bool) is_err.bool else false,
                .delivered = if (delivered_v == .bool) delivered_v.bool else false,
            } };
        } else if (std.mem.eql(u8, tv.string, "thinking")) {
            // 写侧一直会写 thinking 块,读侧此前缺此分支 → 任何带 thinking 的会话
            // resume 整体 InvalidTranscript(roundtrip bug,随 image 支持一并修复)。
            const t = bv.object.get("thinking") orelse return error.InvalidTranscript;
            if (t != .string) return error.InvalidTranscript;
            blocks[idx] = .{ .thinking = try allocator.dupe(u8, t.string) };
        } else if (std.mem.eql(u8, tv.string, "reasoning_item")) {
            const model = bv.object.get("model") orelse return error.InvalidTranscript;
            const item = bv.object.get("item") orelse return error.InvalidTranscript;
            if (model != .string or item != .string) return error.InvalidTranscript;
            const model_owned = try allocator.dupe(u8, model.string);
            errdefer allocator.free(model_owned);
            blocks[idx] = .{ .reasoning_item = .{
                .model = model_owned,
                .json = try allocator.dupe(u8, item.string),
            } };
        } else if (std.mem.eql(u8, tv.string, "image")) {
            const mt = bv.object.get("media_type") orelse return error.InvalidTranscript;
            const data = bv.object.get("data") orelse return error.InvalidTranscript;
            if (mt != .string or data != .string) return error.InvalidTranscript;
            const mt_owned = try allocator.dupe(u8, mt.string);
            errdefer allocator.free(mt_owned);
            blocks[idx] = .{ .image = .{
                .media_type = mt_owned,
                .data = try allocator.dupe(u8, data.string),
            } };
        } else if (std.mem.eql(u8, tv.string, "document")) {
            // 撤回的一等 PDF 文档输入(见 issue #25 的复盘)。这类会话的语义
            // 本进程已经无法忠实重建——**明确拒绝**,而不是丢块继续:少一个
            // 文档的"恢复"是在悄悄改写用户看过的历史。与通用 InvalidTranscript
            // 分开,好让上层给出可行动的提示而不是"文件坏了"。
            return error.WithdrawnDocumentBlock;
        } else {
            return error.InvalidTranscript;
        }
        constructed += 1;
    }

    return .{ .role = role, .blocks = blocks, .delivered = msg_delivered };
}

// ============================================================================
// Session 列表：扫 `$HOME/.metacodes/projects/<cwd_hash>/` 所有子目录读 meta.json
// ============================================================================

pub const SessionListEntry = struct {
    id: []const u8, // owned
    path: []const u8, // owned 完整路径
    title: []const u8, // owned
    last_modified_ns: i128,
    message_count: usize,
    model: []const u8, // owned
};

/// 扫项目目录下所有 session，返回按 last_modified 降序的数组。
/// 调用方负责 free 每个 entry 的各字段和 slice。
pub fn listSessions(cwd: []const u8, home: []const u8, allocator: std.mem.Allocator) ![]SessionListEntry {
    const cwd_hash = hashCwd(cwd);
    var root_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const root_path = try std.fmt.bufPrint(&root_buf, "{s}/.metacodes/projects/{s}\x00", .{ home, cwd_hash[0..] });

    // 打开目录(可移植遍历)
    var it = pdir.open(@ptrCast(root_path.ptr)) orelse {
        // 没目录 = 没 session
        return try allocator.alloc(SessionListEntry, 0);
    };
    defer pdir.close(&it);

    var list = std.ArrayList(SessionListEntry).empty;
    errdefer {
        for (list.items) |e| {
            allocator.free(e.id);
            allocator.free(e.path);
            allocator.free(e.title);
            allocator.free(e.model);
        }
        list.deinit(allocator);
    }

    while (pdir.next(&it)) |ent| {
        const name = ent.name;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        // 不判断 is_dir 兼容性——后面 readMeta 失败会跳过

        const full_path = try std.fmt.allocPrint(allocator, "{s}/.metacodes/projects/{s}/{s}", .{ home, cwd_hash[0..], name });
        errdefer allocator.free(full_path);

        // 读 meta.json
        const meta = readMeta(full_path, allocator) catch {
            allocator.free(full_path);
            continue;
        };

        try list.append(allocator, .{
            .id = try allocator.dupe(u8, name),
            .path = full_path,
            .title = meta.title,
            .last_modified_ns = meta.last_modified_ns,
            .message_count = meta.message_count,
            .model = meta.model,
        });
    }

    const out = try list.toOwnedSlice(allocator);
    // 按 last_modified_ns 降序
    std.sort.heap(SessionListEntry, out, {}, struct {
        fn lt(_: void, a: SessionListEntry, b: SessionListEntry) bool {
            return a.last_modified_ns > b.last_modified_ns;
        }
    }.lt);
    return out;
}

/// 从 session dir 读 meta.json；字符串字段 dupe 成 owned。
fn readMeta(session_dir: []const u8, allocator: std.mem.Allocator) !struct {
    title: []const u8,
    model: []const u8,
    last_modified_ns: i128,
    message_count: usize,
} {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "{s}/meta.json\x00", .{session_dir});
    const fd = pfs.open(@ptrCast(path.ptr), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);

    var all = std.ArrayList(u8).empty;
    defer all.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try readChunk(fd, &buf);
        if (n == 0) break;
        try all.appendSlice(allocator, buf[0..@intCast(n)]);
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, all.items, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidMeta;

    const title_v = root.object.get("title_guess") orelse std.json.Value{ .string = "" };
    const model_v = root.object.get("model") orelse std.json.Value{ .string = "" };
    const lm_v = root.object.get("last_modified_ns") orelse std.json.Value{ .integer = 0 };
    const mc_v = root.object.get("message_count") orelse std.json.Value{ .integer = 0 };

    return .{
        .title = try allocator.dupe(u8, if (title_v == .string) title_v.string else ""),
        .model = try allocator.dupe(u8, if (model_v == .string) model_v.string else ""),
        .last_modified_ns = if (lm_v == .integer) lm_v.integer else 0,
        .message_count = if (mc_v == .integer) @intCast(mc_v.integer) else 0,
    };
}

pub fn freeSessionList(list: []SessionListEntry, allocator: std.mem.Allocator) void {
    for (list) |e| {
        allocator.free(e.id);
        allocator.free(e.path);
        allocator.free(e.title);
        allocator.free(e.model);
    }
    allocator.free(list);
}

// ============================================================================
// Tests
// ============================================================================

test "SessionId format" {
    const id = genSessionId();
    try std.testing.expect(id.bytes.len == 24);
    // 全部是 hex 字符
    for (id.bytes) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "hashCwd deterministic" {
    const a = hashCwd("/home/user/project");
    const b = hashCwd("/home/user/project");
    try std.testing.expectEqualSlices(u8, &a, &b);
    const c = hashCwd("/other");
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
}

test "write then load roundtrip" {
    const a = std.testing.allocator;
    // 用 /tmp 模拟 HOME
    const tmp_home = blk_home: {
        var _tb: [512]u8 = undefined;
        break :blk_home try std.fmt.allocPrint(a, "{s}/cc-zig-transcript-test-{d}", .{ @import("../tools/test_tmp.zig").dir(&_tb), util_time.nowMs() });
    };
    defer {
        util_fs.testing.rmrfBestEffort(tmp_home);
        a.free(tmp_home);
    }

    var writer = try Writer.init(a, "/dummy/cwd", tmp_home, "claude-sonnet-4-20250514", genSessionId());
    defer writer.deinit();

    var conv = Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hello");
    try conv.appendText(.assistant, "hi there");

    writer.flush(&conv);

    // 再加一条
    try conv.appendText(.user, "follow up");
    writer.flush(&conv);

    // 重新加载到新 conversation 比较
    var conv2 = Conversation.init(a);
    defer conv2.deinit();
    try loadTranscript(&conv2, writer.dir, a);

    try std.testing.expect(conv2.len() == 3);
    try std.testing.expectEqualStrings("hello", conv2.messages.items[0].blocks[0].text);
    try std.testing.expectEqualStrings("hi there", conv2.messages.items[1].blocks[0].text);
    try std.testing.expectEqualStrings("follow up", conv2.messages.items[2].blocks[0].text);
}

test "delivery watermark round-trip:消息级与块级 delivered 随 transcript 持久化,缺字段默认 false" {
    const a = std.testing.allocator;
    const tmp_home = "/tmp/cc-zig-transcript-delivered-rt";
    @import("../util/fs.zig").testing.rmrfBestEffort(tmp_home);
    defer @import("../util/fs.zig").testing.rmrfBestEffort(tmp_home);
    var writer = try Writer.init(a, "/dummy", tmp_home, "m", genSessionId());
    defer writer.deinit();
    {
        var conv = Conversation.init(a);
        defer conv.deinit();
        const tu = try a.alloc(msg_mod.Block, 1);
        tu[0] = .{ .tool_use = .{ .id = try a.dupe(u8, "t1"), .name = try a.dupe(u8, "Read"), .input = try a.dupe(u8, "{}") } };
        try conv.append(.{ .role = .assistant, .blocks = tu });
        const blocks = try a.alloc(msg_mod.Block, 1);
        blocks[0] = .{ .tool_result = .{ .tool_use_id = try a.dupe(u8, "t1"), .content = try a.dupe(u8, "{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"AAAA\"}"), .is_error = false } };
        try conv.append(.{ .role = .user, .blocks = blocks });
        conv.markDelivered(.{ .image_placeholder_ids = &.{} });
        try conv.appendText(.assistant, "seen"); // appended after the request: not delivered
        writer.flush(&conv);
    }
    var loaded = Conversation.init(a);
    defer loaded.deinit();
    try loadTranscript(&loaded, writer.dir, a);
    try std.testing.expectEqual(@as(usize, 3), loaded.messages.items.len);
    try std.testing.expect(loaded.messages.items[0].delivered);
    try std.testing.expect(loaded.messages.items[1].delivered);
    try std.testing.expect(loaded.messages.items[1].blocks[0].tool_result.delivered);
    try std.testing.expect(!loaded.messages.items[2].delivered);
    // A record without the field (older transcript) restores as undelivered.
    var legacy = try parseMessageLine("{\"role\":\"user\",\"blocks\":[{\"type\":\"tool_result\",\"tool_use_id\":\"x\",\"content\":\"c\"}]}", a);
    defer legacy.deinit(a);
    try std.testing.expect(!legacy.delivered);
    try std.testing.expect(!legacy.blocks[0].tool_result.delivered);
}

test "A:compact 投影状态 round-trip(flush 存 meta → load 恢复 boundary/summary)" {
    const a = std.testing.allocator;
    const tmp_home = blk_home: {
        var _tb: [512]u8 = undefined;
        break :blk_home try std.fmt.allocPrint(a, "{s}/cc-zig-transcript-compact-{d}", .{ @import("../tools/test_tmp.zig").dir(&_tb), util_time.nowMs() });
    };
    defer {
        util_fs.testing.rmrfBestEffort(tmp_home);
        a.free(tmp_home);
    }
    var writer = try Writer.init(a, "/dummy/cwd", tmp_home, "claude-sonnet", genSessionId());
    defer writer.deinit();

    var conv = Conversation.init(a);
    defer conv.deinit();
    var i: usize = 0;
    while (i < 5) : (i += 1) try conv.appendText(.user, "msg");
    // 直接设投影状态(不经 restoreCompactState 避免自证):boundary=3 + summary。
    conv.compact_boundary = 3;
    conv.compact_summary = try a.dupe(u8, "PROJECTED_SUMMARY_XYZ");

    writer.flush(&conv);

    // 全新 conversation 从盘恢复:全量消息重放 + 投影状态恢复。
    var conv2 = Conversation.init(a);
    defer conv2.deinit();
    try loadTranscript(&conv2, writer.dir, a);

    try std.testing.expectEqual(@as(usize, 5), conv2.len()); // 原始全量
    try std.testing.expectEqual(@as(usize, 3), conv2.compact_boundary); // 投影 boundary 恢复
    try std.testing.expect(conv2.compact_summary != null);
    try std.testing.expectEqualStrings("PROJECTED_SUMMARY_XYZ", conv2.compact_summary.?);
    try std.testing.expectEqual(@as(usize, 2), conv2.activeMessages().len); // 活跃窗口=最后 2
}

test "A:未压缩 session 兼容(meta 无投影字段 → boundary=0/summary=null,不崩)" {
    const a = std.testing.allocator;
    const tmp_home = blk_home: {
        var _tb: [512]u8 = undefined;
        break :blk_home try std.fmt.allocPrint(a, "{s}/cc-zig-transcript-nocompact-{d}", .{ @import("../tools/test_tmp.zig").dir(&_tb), util_time.nowMs() });
    };
    defer {
        util_fs.testing.rmrfBestEffort(tmp_home);
        a.free(tmp_home);
    }
    var writer = try Writer.init(a, "/dummy/cwd", tmp_home, "claude-sonnet", genSessionId());
    defer writer.deinit();

    var conv = Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "just chatting");
    try conv.appendText(.assistant, "ok");
    writer.flush(&conv); // 无压缩 → meta 写 boundary=0/summary=null

    var conv2 = Conversation.init(a);
    defer conv2.deinit();
    try loadTranscript(&conv2, writer.dir, a);
    try std.testing.expectEqual(@as(usize, 2), conv2.len());
    try std.testing.expectEqual(@as(usize, 0), conv2.compact_boundary);
    try std.testing.expect(conv2.compact_summary == null);
    try std.testing.expectEqual(@as(usize, 2), conv2.activeMessages().len); // 无投影=全量活跃
}

test "write tool_use and tool_result roundtrip" {
    const a = std.testing.allocator;
    const tmp_home = blk_home: {
        var _tb: [512]u8 = undefined;
        break :blk_home try std.fmt.allocPrint(a, "{s}/cc-zig-transcript-test-tu-{d}", .{ @import("../tools/test_tmp.zig").dir(&_tb), util_time.nowMs() });
    };
    defer {
        util_fs.testing.rmrfBestEffort(tmp_home);
        a.free(tmp_home);
    }

    var writer = try Writer.init(a, "/dummy", tmp_home, "claude-sonnet", genSessionId());
    defer writer.deinit();

    var conv = Conversation.init(a);
    defer conv.deinit();

    const blks = try a.alloc(msg_mod.Block, 1);
    blks[0] = .{ .tool_use = .{
        .id = try a.dupe(u8, "t1"),
        .name = try a.dupe(u8, "Read"),
        .input = try a.dupe(u8, "{\"path\":\"/x\"}"),
    } };
    try conv.append(.{ .role = .assistant, .blocks = blks });

    const blks2 = try a.alloc(msg_mod.Block, 1);
    blks2[0] = .{ .tool_result = .{
        .tool_use_id = try a.dupe(u8, "t1"),
        .content = try a.dupe(u8, "file content here"),
        .is_error = false,
    } };
    try conv.append(.{ .role = .user, .blocks = blks2 });

    writer.flush(&conv);

    var conv2 = Conversation.init(a);
    defer conv2.deinit();
    try loadTranscript(&conv2, writer.dir, a);
    try std.testing.expect(conv2.len() == 2);
    try std.testing.expect(@as(std.meta.Tag(msg_mod.Block), conv2.messages.items[0].blocks[0]) == .tool_use);
    try std.testing.expect(@as(std.meta.Tag(msg_mod.Block), conv2.messages.items[1].blocks[0]) == .tool_result);
    try std.testing.expectEqualStrings("file content here", conv2.messages.items[1].blocks[0].tool_result.content);
}

test "listSessions orders by last_modified desc" {
    const a = std.testing.allocator;
    // 可移植临时目录(POSIX /tmp / Windows TEMP,正斜杠)。
    var _tb: [512]u8 = undefined;
    const tmp_home = try std.fmt.allocPrint(a, "{s}/cc-zig-transcript-list-test-{d}", .{ @import("../tools/test_tmp.zig").dir(&_tb), util_time.nowMs() });
    defer {
        util_fs.testing.rmrfBestEffort(tmp_home);
        a.free(tmp_home);
    }

    // 写三个 session
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var w = try Writer.init(a, "/project-X", tmp_home, "m", genSessionId());
        defer w.deinit();
        var conv = Conversation.init(a);
        defer conv.deinit();
        const fmt_buf = try std.fmt.allocPrint(a, "msg {d}", .{i});
        defer a.free(fmt_buf);
        try conv.appendText(.user, fmt_buf);
        w.flush(&conv);
        // 保证时间戳不同(Zig 0.16 无 std.time.sleep,用 std.c.nanosleep)。
        util_time.sleepMs(2);
    }

    const list = try listSessions("/project-X", tmp_home, a);
    defer freeSessionList(list, a);

    try std.testing.expect(list.len == 3);
    // 降序：最新的在前
    try std.testing.expect(list[0].last_modified_ns >= list[1].last_modified_ns);
    try std.testing.expect(list[1].last_modified_ns >= list[2].last_modified_ns);
}

test "image + thinking 块 transcript roundtrip(issue #10 会话恢复语义)" {
    // image:媒体类型/base64 原样恢复。thinking:写侧一直会写,读侧此前缺分支 →
    // 任何带 thinking 的会话 resume 整体失败(随 image 支持一并修复,此测试锁定)。
    const a = std.testing.allocator;
    const tmp_home = blk_home: {
        var _tb: [512]u8 = undefined;
        break :blk_home try std.fmt.allocPrint(a, "{s}/cc-zig-transcript-test-img-{d}", .{ @import("../tools/test_tmp.zig").dir(&_tb), util_time.nowMs() });
    };
    defer {
        util_fs.testing.rmrfBestEffort(tmp_home);
        a.free(tmp_home);
    }

    var writer = try Writer.init(a, "/dummy", tmp_home, "claude-sonnet", genSessionId());
    defer writer.deinit();

    var conv = Conversation.init(a);
    defer conv.deinit();

    const blks = try a.alloc(msg_mod.Block, 3);
    blks[0] = .{ .text = try a.dupe(u8, "这是截图") };
    blks[1] = .{ .image = .{
        .media_type = try a.dupe(u8, "image/png"),
        .data = try a.dupe(u8, "UE5HREFUQQ=="),
    } };
    blks[2] = .{ .image = .{
        .media_type = try a.dupe(u8, "image/jpeg"),
        .data = try a.dupe(u8, "SlBFRw=="),
    } };
    try conv.append(.{ .role = .user, .blocks = blks });

    const blks2 = try a.alloc(msg_mod.Block, 2);
    blks2[0] = .{ .thinking = try a.dupe(u8, "推理内容") };
    blks2[1] = .{ .text = try a.dupe(u8, "两张图分别是…") };
    try conv.append(.{ .role = .assistant, .blocks = blks2 });

    writer.flush(&conv);

    var conv2 = Conversation.init(a);
    defer conv2.deinit();
    try loadTranscript(&conv2, writer.dir, a);
    try std.testing.expectEqual(@as(usize, 2), conv2.len());
    const user_blocks = conv2.messages.items[0].blocks;
    try std.testing.expectEqual(@as(usize, 3), user_blocks.len);
    try std.testing.expectEqualStrings("这是截图", user_blocks[0].text);
    try std.testing.expectEqualStrings("image/png", user_blocks[1].image.media_type);
    try std.testing.expectEqualStrings("UE5HREFUQQ==", user_blocks[1].image.data);
    try std.testing.expectEqualStrings("image/jpeg", user_blocks[2].image.media_type);
    const asst_blocks = conv2.messages.items[1].blocks;
    try std.testing.expectEqualStrings("推理内容", asst_blocks[0].thinking);
    try std.testing.expectEqualStrings("两张图分别是…", asst_blocks[1].text);
}

test "reasoning_item 块 transcript roundtrip(issue #23 跨 resume 的推理续传)" {
    // `store:false` 下推理状态只存在于客户端:resume 后必须逐字节还原,
    // 否则续传的会话就把 encrypted_content 永久丢了。
    const a = std.testing.allocator;
    const tmp_home = blk_home: {
        var _tb: [512]u8 = undefined;
        break :blk_home try std.fmt.allocPrint(a, "{s}/cc-zig-transcript-test-reason-{d}", .{ @import("../tools/test_tmp.zig").dir(&_tb), util_time.nowMs() });
    };
    defer {
        util_fs.testing.rmrfBestEffort(tmp_home);
        a.free(tmp_home);
    }

    var writer = try Writer.init(a, "/dummy", tmp_home, "gpt-5.2", genSessionId());
    defer writer.deinit();

    var conv = Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "what time is it");

    const item_json =
        "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[],\"encrypted_content\":\"opaque\\\"quoted\"}";
    const blks = try a.alloc(msg_mod.Block, 2);
    blks[0] = .{ .reasoning_item = .{
        .model = try a.dupe(u8, "gpt-5.2"),
        .json = try a.dupe(u8, item_json),
    } };
    blks[1] = .{ .tool_use = .{
        .id = try a.dupe(u8, "call_1"),
        .name = try a.dupe(u8, "get_time"),
        .input = try a.dupe(u8, "{}"),
    } };
    try conv.append(.{ .role = .assistant, .blocks = blks });

    writer.flush(&conv);

    var conv2 = Conversation.init(a);
    defer conv2.deinit();
    try loadTranscript(&conv2, writer.dir, a);
    try std.testing.expectEqual(@as(usize, 2), conv2.len());
    const asst = conv2.messages.items[1].blocks;
    try std.testing.expectEqual(@as(usize, 2), asst.len);
    try std.testing.expectEqualStrings("gpt-5.2", asst[0].reasoning_item.model);
    try std.testing.expectEqualStrings(item_json, asst[0].reasoning_item.json);
    try std.testing.expectEqualStrings("call_1", asst[1].tool_use.id);
}

test "title_guess: 纯图首条不锁死标题,后续 user text 胜出;全程无 text 才落 [image]" {
    const a = std.testing.allocator;
    const tmp_home = blk_home: {
        var _tb: [512]u8 = undefined;
        break :blk_home try std.fmt.allocPrint(a, "{s}/cc-zig-transcript-title-img-{d}", .{ @import("../tools/test_tmp.zig").dir(&_tb), util_time.nowMs() });
    };
    defer {
        util_fs.testing.rmrfBestEffort(tmp_home);
        a.free(tmp_home);
    }
    var writer = try Writer.init(a, "/dummy", tmp_home, "m", genSessionId());
    defer writer.deinit();

    var conv = Conversation.init(a);
    defer conv.deinit();
    const blks = try a.alloc(msg_mod.Block, 1);
    blks[0] = .{ .image = .{ .media_type = try a.dupe(u8, "image/png"), .data = try a.dupe(u8, "UE5H") } };
    try conv.append(.{ .role = .user, .blocks = blks });
    writer.flush(&conv);

    {
        const raw = try readMetaForTest(a, writer.dir);
        defer a.free(raw);
        try std.testing.expect(std.mem.indexOf(u8, raw, "\"title_guess\":\"[image]\"") != null);
    }

    // 后续 user text → 标题被 text 取代(不被 [image] 占位锁死)。
    try conv.appendText(.user, "fix the login bug");
    writer.flush(&conv);
    {
        const raw = try readMetaForTest(a, writer.dir);
        defer a.free(raw);
        try std.testing.expect(std.mem.indexOf(u8, raw, "\"title_guess\":\"fix the login bug\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, raw, "[image]") == null);
    }
}

fn readMetaForTest(allocator: std.mem.Allocator, session_dir: []const u8) ![]u8 {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "{s}/meta.json\x00", .{session_dir});
    const fd = pfs.open(@ptrCast(path.ptr), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    var all = std.ArrayList(u8).empty;
    errdefer all.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &buf);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try all.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return all.toOwnedSlice(allocator);
}

test "旧的含 PDF 会话:明确拒绝,且绝不半读(撤回兼容策略)" {
    const a = std.testing.allocator;
    const tmp_home = blk_home: {
        var _tb: [512]u8 = undefined;
        break :blk_home try std.fmt.allocPrint(a, "{s}/cc-zig-transcript-withdrawn-{d}", .{ @import("../tools/test_tmp.zig").dir(&_tb), util_time.nowMs() });
    };
    defer {
        util_fs.testing.rmrfBestEffort(tmp_home);
        a.free(tmp_home);
    }
    var writer = try Writer.init(a, "/dummy", tmp_home, "claude-sonnet-4", genSessionId());
    defer writer.deinit();

    // 手写一份 revision-16 时代写下的 transcript:两条正常消息 + 一条 document 块。
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/transcript.jsonl\x00", .{writer.dir});
    const fd = pfs.open(@ptrCast(path.ptr), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.SkipZigTest;
    const legacy =
        "{\"role\":\"user\",\"blocks\":[{\"type\":\"text\",\"text\":\"first\"}]}\n" ++
        "{\"role\":\"assistant\",\"blocks\":[{\"type\":\"text\",\"text\":\"second\"}]}\n" ++
        "{\"role\":\"user\",\"blocks\":[{\"type\":\"document\",\"media_type\":\"application/pdf\"," ++
        "\"title\":\"r.pdf\",\"pages\":2,\"data\":\"JVBERi0xLjcK\"}]}\n";
    _ = pfs.write(fd, legacy);
    pfs.close(fd);

    var conv = Conversation.init(a);
    defer conv.deinit();
    // ① 明确、专属的错误 —— 不是通用 InvalidTranscript,上层据此给可行动提示。
    try std.testing.expectError(error.WithdrawnDocumentBlock, loadTranscript(&conv, writer.dir, a));
    // ② 绝不半读:失败前那两条已解析成功的消息一条都不许进 conversation。
    try std.testing.expectEqual(@as(usize, 0), conv.len());
}

test "回退边界:thinking round-trip 与 [image] 标题兜底必须完好" {
    const a = std.testing.allocator;
    const tmp_home = blk_home: {
        var _tb: [512]u8 = undefined;
        break :blk_home try std.fmt.allocPrint(a, "{s}/cc-zig-transcript-boundary-{d}", .{ @import("../tools/test_tmp.zig").dir(&_tb), util_time.nowMs() });
    };
    defer {
        util_fs.testing.rmrfBestEffort(tmp_home);
        a.free(tmp_home);
    }
    var writer = try Writer.init(a, "/dummy", tmp_home, "claude-sonnet-4", genSessionId());
    defer writer.deinit();

    var conv = Conversation.init(a);
    defer conv.deinit();
    // 纯图会话(无任何 user text):标题兜底必须仍是 [image]。
    const user_blocks = try a.alloc(msg_mod.Block, 1);
    user_blocks[0] = .{ .image = .{
        .media_type = try a.dupe(u8, "image/png"),
        .data = try a.dupe(u8, "UE5HREFUQQ=="),
    } };
    try conv.append(.{ .role = .user, .blocks = user_blocks });
    // thinking 块必须写得出、也读得回(#10 时代修好的 round-trip)。
    const asst_blocks = try a.alloc(msg_mod.Block, 2);
    asst_blocks[0] = .{ .thinking = try a.dupe(u8, "推理内容") };
    asst_blocks[1] = .{ .text = try a.dupe(u8, "答案") };
    try conv.append(.{ .role = .assistant, .blocks = asst_blocks });
    writer.flush(&conv);

    var restored = Conversation.init(a);
    defer restored.deinit();
    try loadTranscript(&restored, writer.dir, a);
    try std.testing.expectEqual(@as(usize, 2), restored.len());
    try std.testing.expectEqualStrings("image/png", restored.messages.items[0].blocks[0].image.media_type);
    try std.testing.expectEqualStrings("推理内容", restored.messages.items[1].blocks[0].thinking);
    try std.testing.expectEqualStrings("答案", restored.messages.items[1].blocks[1].text);

    var meta_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const meta_path = try std.fmt.bufPrint(&meta_buf, "{s}/meta.json\x00", .{writer.dir});
    const meta_fd = pfs.open(@ptrCast(meta_path.ptr), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (meta_fd < 0) return error.SkipZigTest;
    defer _ = pfs.close(meta_fd);
    var meta: [1024]u8 = undefined;
    const n = pfs.read(meta_fd, &meta);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, meta[0..@intCast(n)], "[image]") != null);
}

const LoadOutcome = union(enum) {
    /// loadTranscript 报错;载荷 = 失败后 conversation 里剩下的消息数(必须为 0)。
    failed: usize,
    /// loadTranscript 成功(注入的失败可能被非致命的 meta 路径吸收)。
    loaded: struct { len: usize, boundary: usize, has_summary: bool },
};

fn loadIntoFreshConversation(a: std.mem.Allocator, dir: []const u8) !LoadOutcome {
    var conv = Conversation.init(a);
    defer conv.deinit();
    loadTranscript(&conv, dir, a) catch |e| {
        try std.testing.expectEqual(error.OutOfMemory, e);
        return .{ .failed = conv.len() };
    };
    return .{ .loaded = .{
        .len = conv.len(),
        .boundary = conv.compact_boundary,
        .has_summary = conv.compact_summary != null,
    } };
}

test "原子提交:任意分配点失败都不留半填充、不二次释放(FailingAllocator 逐点扫描;PR #46 review A)" {
    const base = std.testing.allocator;
    const tmp_home = blk_home: {
        var _tb: [512]u8 = undefined;
        break :blk_home try std.fmt.allocPrint(base, "{s}/cc-zig-transcript-oomsweep-{d}", .{ @import("../tools/test_tmp.zig").dir(&_tb), util_time.nowMs() });
    };
    defer {
        util_fs.testing.rmrfBestEffort(tmp_home);
        base.free(tmp_home);
    }
    var writer = try Writer.init(base, "/dummy", tmp_home, "claude-sonnet-4", genSessionId());
    defer writer.deinit();
    {
        var conv = Conversation.init(base);
        defer conv.deinit();
        // 48 条:让 messages 列表在转移期间跨过 5/12/23/39 四个扩容点——旧实现正是
        // 在第 k>0 次扩容失败时把已转移的前缀二次释放(4 条消息时初始容量已够,
        // 扫不到)。扫描代价随消息数平方增长(每个分配点都重跑一次加载),128 条在
        // Debug 下要 20 秒以上,会挤压同机并行的时序敏感 L2;48 条约 3 秒,覆盖不变。
        var i: usize = 0;
        while (i < 48) : (i += 1) {
            try conv.appendText(if (i % 2 == 0) .user else .assistant, "message body");
        }
        // 带一份持久化的压缩投影:meta 路径的失败被 loadTranscript 当非致命吞掉,
        // 所以它只允许"整体没恢复"(0/null),不允许半恢复(boundary 推进、summary
        // 为空)——那会让模型悄悄丢掉前缀(review F1)。
        conv.compact_boundary = 1;
        conv.compact_summary = try base.dupe(u8, "SUMMARY");
        writer.flush(&conv);
    }

    var idx: usize = 0;
    while (idx < 100_000) : (idx += 1) {
        var fa = std.testing.FailingAllocator.init(base, .{ .fail_index = idx });
        const outcome = try loadIntoFreshConversation(fa.allocator(), writer.dir);
        if (!fa.has_induced_failure) break; // 这一轮没注入失败 = 扫描完毕
        switch (outcome) {
            // 报错的一轮:conversation 一条都不许留。半填充是唯一不允许的结果。
            .failed => |left| try std.testing.expectEqual(@as(usize, 0), left),
            // 成功的一轮:消息齐全,投影要么完整恢复、要么完全未恢复。
            .loaded => |l| {
                try std.testing.expectEqual(@as(usize, 48), l.len);
                try std.testing.expect((l.boundary == 1 and l.has_summary) or
                    (l.boundary == 0 and !l.has_summary));
            },
        }
    }
    try std.testing.expect(idx < 100_000); // 扫描必须自然收敛
}

test "transcript.jsonl 读失败(EISDIR)→ 明确 ReadFailed,不当 EOF 静默恢复空会话(PR #46 review B)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const tmp_home = blk_home: {
        var _tb: [512]u8 = undefined;
        break :blk_home try std.fmt.allocPrint(a, "{s}/cc-zig-transcript-readfail-{d}", .{ @import("../tools/test_tmp.zig").dir(&_tb), util_time.nowMs() });
    };
    defer {
        util_fs.testing.rmrfBestEffort(tmp_home);
        a.free(tmp_home);
    }
    // 把 transcript.jsonl 做成目录:open(O_RDONLY) 成功,read 返回 -1(EISDIR)。
    // 旧实现把 -1 当 EOF → 零行 → "成功"恢复出一个空会话。
    const session_dir = try std.fmt.allocPrint(a, "{s}/sess", .{tmp_home});
    defer a.free(session_dir);
    const bogus = try std.fmt.allocPrint(a, "{s}/transcript.jsonl", .{session_dir});
    defer a.free(bogus);
    try util_fs.mkdirParents(bogus);

    var conv = Conversation.init(a);
    defer conv.deinit();
    try std.testing.expectError(error.ReadFailed, loadTranscript(&conv, session_dir, a));
    try std.testing.expectEqual(@as(usize, 0), conv.len());
}
