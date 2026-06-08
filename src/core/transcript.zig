//! Session transcript 持久化。
//!
//! 设计：
//! - **布局**：`$HOME/.cc-zig/projects/<cwd_hash>/<session_id>/transcript.jsonl + meta.json`
//! - `cwd_hash`：cwd 的 xxhash64 → 16-char hex；同一项目目录的 session 聚在一起
//! - `session_id`：启动时生成（毫秒时间戳 hex + 4 byte 随机 hex），自然按时间排序
//! - **transcript.jsonl**：每 turn 结束时把 **新增** 的 message 追加成 JSONL
//!   - 每行一个 JSON：`{"role": "user|assistant", "blocks": [...]}`
//!   - blocks 数组里元素按类型序列化：
//!     - `{"type":"text","text":"..."}`
//!     - `{"type":"tool_use","id":"","name":"","input":"<json string>"}`
//!     - `{"type":"tool_result","tool_use_id":"","content":"...","is_error":bool}`
//! - **meta.json**：每次写 transcript 后覆盖写入 {model, last_modified_ns, message_count, title_guess}
//! - **title_guess**：首条 user text 的前 80 字节（去换行）
//! - **加载**：逐行 parse JSONL 重建 Conversation；meta 用于 /resume 列表
//!
//! 崩溃安全：JSONL append 原子性取决于 write(2) ≤ PIPE_BUF（Linux 4096 字节），
//! 超大 message（tool_use input 上 MB）不保证原子，但本期 MVP 接受此代价。
//! meta.json 用 rename() 原子替换。

const std = @import("std");
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
    fd: std.c.fd_t = FD_UNSET,
    /// 已刷盘的 message 数；下次 flush 从这里开始
    flushed_count: usize = 0,
    model: []const u8, // borrowed (session 期间不变)

    /// "fd 未打开" 哨兵值。POSIX 约定负 fd 无效。
    const FD_UNSET: std.c.fd_t = -1;

    pub fn init(
        allocator: std.mem.Allocator,
        cwd: []const u8,
        home: []const u8,
        model: []const u8,
        /// 会话 id(由 App 传入,统一 App.session_id 与 transcript 目录名)。
        sid: SessionId,
    ) !Writer {
        const cwd_hash = hashCwd(cwd);

        // 构造路径 $HOME/.cc-zig/projects/<cwd_hash>/<session_id>/
        const dir = try std.fmt.allocPrint(allocator, "{s}/.cc-zig/projects/{s}/{s}", .{ home, cwd_hash[0..], sid.bytes[0..] });
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
        if (self.fd != FD_UNSET) _ = std.c.close(self.fd);
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
        if (self.fd == FD_UNSET) {
            var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
            const path = try std.fmt.bufPrint(&pbuf, "{s}/transcript.jsonl\x00", .{self.dir});
            self.fd = std.c.open(@ptrCast(path.ptr), std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o600));
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

        try self.writeMeta(messages);
    }

    fn writeMessage(self: *Writer, m: *const msg_mod.Message) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        try aw.writer.writeAll("{\"role\":\"");
        try aw.writer.writeAll(roleStr(m.role));
        try aw.writer.writeAll("\",\"blocks\":[");
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
                    try aw.writer.print(",\"is_error\":{s}", .{if (tr.is_error) "true" else "false"});
                    try aw.writer.writeAll("}");
                },
                .thinking => |t| {
                    try aw.writer.writeAll("{\"type\":\"thinking\",\"thinking\":");
                    try std.json.Stringify.encodeJsonString(t, .{}, &aw.writer);
                    try aw.writer.writeAll("}");
                },
            }
        }
        try aw.writer.writeAll("]}\n");

        const bytes = aw.written();
        const n = std.c.write(self.fd, bytes.ptr, bytes.len);
        if (n < 0 or @as(usize, @intCast(n)) != bytes.len) return error.WriteFailed;
    }

    fn writeMeta(self: *Writer, messages: []const msg_mod.Message) !void {
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

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try aw.writer.writeAll("{\"model\":");
        try std.json.Stringify.encodeJsonString(self.model, .{}, &aw.writer);
        try aw.writer.print(",\"last_modified_ns\":{d},\"message_count\":{d},\"title_guess\":", .{ util_time.nowWallNs(), messages.len });
        try std.json.Stringify.encodeJsonString(title, .{}, &aw.writer);
        try aw.writer.writeAll("}\n");

        // 原子替换：写到 meta.json.tmp 再 rename
        var tpath_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const tpath = try std.fmt.bufPrint(&tpath_buf, "{s}/meta.json.tmp\x00", .{self.dir});
        const tfd = std.c.open(@ptrCast(tpath.ptr), std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        if (tfd < 0) return error.OpenFailed;
        defer _ = std.c.close(tfd);

        const bytes = aw.written();
        const n = std.c.write(tfd, bytes.ptr, bytes.len);
        if (n < 0 or @as(usize, @intCast(n)) != bytes.len) return error.WriteFailed;

        var fpath_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const fpath = try std.fmt.bufPrint(&fpath_buf, "{s}/meta.json\x00", .{self.dir});
        if (std.c.rename(@ptrCast(tpath.ptr), @ptrCast(fpath.ptr)) != 0) return error.RenameFailed;
    }
};

fn roleStr(r: types.MessageRole) []const u8 {
    return switch (r) {
        .user => "user",
        .assistant => "assistant",
    };
}

// nowNs 下沉到 util/time.zig（这里用的是 wall clock REALTIME）

// ============================================================================
// 加载器：从 transcript.jsonl 重建 Conversation
// ============================================================================

/// 从 session 目录加载 transcript，把所有 message append 到 conversation。
/// 失败则 conversation 保持调用前状态。
pub fn loadTranscript(conversation: *Conversation, session_dir: []const u8, allocator: std.mem.Allocator) !void {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "{s}/transcript.jsonl\x00", .{session_dir});
    const fd = std.c.open(@ptrCast(path.ptr), std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);

    // 读整文件
    var all = std.ArrayList(u8).empty;
    defer all.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        try all.appendSlice(allocator, buf[0..@intCast(n)]);
    }

    // 按行解析
    var line_start: usize = 0;
    while (line_start < all.items.len) {
        const nl = std.mem.indexOfScalarPos(u8, all.items, line_start, '\n') orelse all.items.len;
        const line = all.items[line_start..nl];
        line_start = nl + 1;
        if (line.len == 0) continue;

        const msg = try parseMessageLine(line, allocator);
        try conversation.append(msg);
    }
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
            blocks[idx] = .{ .tool_use = .{
                .id = try allocator.dupe(u8, id.string),
                .name = try allocator.dupe(u8, name.string),
                .input = try allocator.dupe(u8, input.string),
            } };
        } else if (std.mem.eql(u8, tv.string, "tool_result")) {
            const tuid = bv.object.get("tool_use_id") orelse return error.InvalidTranscript;
            const c = bv.object.get("content") orelse return error.InvalidTranscript;
            const is_err = bv.object.get("is_error") orelse std.json.Value{ .bool = false };
            if (tuid != .string or c != .string) return error.InvalidTranscript;
            blocks[idx] = .{ .tool_result = .{
                .tool_use_id = try allocator.dupe(u8, tuid.string),
                .content = try allocator.dupe(u8, c.string),
                .is_error = if (is_err == .bool) is_err.bool else false,
            } };
        } else {
            return error.InvalidTranscript;
        }
        constructed += 1;
    }

    return .{ .role = role, .blocks = blocks };
}

// ============================================================================
// Session 列表：扫 `$HOME/.cc-zig/projects/<cwd_hash>/` 所有子目录读 meta.json
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
    const root_path = try std.fmt.bufPrint(&root_buf, "{s}/.cc-zig/projects/{s}\x00", .{ home, cwd_hash[0..] });

    // 打开目录（用 opendir/readdir）
    const dirp = std.c.opendir(@ptrCast(root_path.ptr));
    if (dirp == null) {
        // 没目录 = 没 session
        return try allocator.alloc(SessionListEntry, 0);
    }
    defer _ = std.c.closedir(dirp.?);

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

    while (std.c.readdir(dirp.?)) |ent| {
        const name_ptr: [*:0]const u8 = @ptrCast(&ent.name);
        const name = std.mem.span(name_ptr);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        // 不判断 d_type 兼容性——后面 readMeta 失败会跳过

        const full_path = try std.fmt.allocPrint(allocator, "{s}/.cc-zig/projects/{s}/{s}", .{ home, cwd_hash[0..], name });
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
    const fd = std.c.open(@ptrCast(path.ptr), std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);

    var all = std.ArrayList(u8).empty;
    defer all.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
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
    const tmp_home = try std.fmt.allocPrint(a, "/tmp/cc-zig-transcript-test-{d}", .{util_time.nowMs()});
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

test "write tool_use and tool_result roundtrip" {
    const a = std.testing.allocator;
    const tmp_home = try std.fmt.allocPrint(a, "/tmp/cc-zig-transcript-test-tu-{d}", .{util_time.nowMs()});
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
    const tmp_home = try std.fmt.allocPrint(a, "/tmp/cc-zig-transcript-list-test-{d}", .{util_time.nowMs()});
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
        var req = std.c.timespec{ .sec = 0, .nsec = 2_000_000 };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
    }

    const list = try listSessions("/project-X", tmp_home, a);
    defer freeSessionList(list, a);

    try std.testing.expect(list.len == 3);
    // 降序：最新的在前
    try std.testing.expect(list[0].last_modified_ns >= list[1].last_modified_ns);
    try std.testing.expect(list[1].last_modified_ns >= list[2].last_modified_ns);
}
