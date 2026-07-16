//! 自动生成 — 从 Prism grammar 提取。勿手改。
//! 生成器：hl-zig/scripts/gen_rules.py
//! 数据: rules_blob.zlib（zlib 压缩），运行时解压构造。
//!
//! blob 格式 v1:
//!   magic: "HLZ1" (4 bytes)
//!   version: 1 (1 byte)
//!   count: u16 LE
//!   per-language: name_len(u8) name ext_len(u16) ext_data
//!     al_len(u16) al_data kw_len(u16) kw_data
//!     ndelim(u8) [open_len(u8) open close_len(u8) close multiline(u8) escape(u8)]
//!     ncmt_line(u8) [len(u8) data]
//!     ncmt_block(u8) [open_len(u8) open close_len(u8) close]
//!     nnp(u8) [len(u8) data]

const std = @import("std");
const LangRule = @import("types.zig").LangRule;
const StringDelim = @import("types.zig").StringDelim;

const COMPRESSED = @embedFile("rules_blob.zlib");

const MAGIC = "HLZ1";
const VERSION: u8 = 1;

/// 规则表。用 `init` 构造，`deinit` 释放。所有 slice 指向内部 `data` 缓冲或其子分配。
pub const Rules = struct {
    rules: []LangRule,
    data: []u8, // 解压后的完整 blob（rules 里的 slice 大多指向这里）
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Rules) void {
        // 释放每语言的 toOwnedSlice 子数组
        for (self.rules) |*r| {
            self.allocator.free(r.extensions);
            self.allocator.free(r.aliases);
            self.allocator.free(r.string_delims);
            self.allocator.free(r.comment_line);
            self.allocator.free(r.comment_block);
            self.allocator.free(r.number_prefix);
        }
        self.allocator.free(self.rules);
        self.allocator.free(self.data);
    }
};

// ── blob 读取器（带边界校验）────────────────────────────────

const BlobError = error{
    BadMagic,
    BadVersion,
    Truncated,
    DecompressFailed,
    OutOfMemory,
};

const BlobReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn remaining(self: *const BlobReader) usize {
        return self.data.len - self.pos;
    }

    fn readByte(self: *BlobReader) BlobError!u8 {
        if (self.remaining() < 1) return error.Truncated;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }

    fn readU16(self: *BlobReader) BlobError!u16 {
        if (self.remaining() < 2) return error.Truncated;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }

    fn readSlice(self: *BlobReader, len: usize) BlobError![]const u8 {
        if (self.remaining() < len) return error.Truncated;
        const s = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return s;
    }
};

/// 从压缩 blob 构造规则表。allocator 用于 rules 数组和子 slice 数组。
/// 解压后的 data 缓冲也由 allocator 分配，Rules.deinit 释放。
pub fn init(allocator: std.mem.Allocator) BlobError!Rules {
    // 解压
    var in: std.Io.Reader = .fixed(COMPRESSED);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var dec: std.compress.flate.Decompress = .init(&in, .zlib, &.{});
    const n = dec.reader.streamRemaining(&aw.writer) catch return error.DecompressFailed;
    const data = try allocator.dupe(u8, aw.written()[0..n]);

    var br = BlobReader{ .data = data };

    // 校验 magic + version
    const magic = try br.readSlice(4);
    if (!std.mem.eql(u8, magic, MAGIC)) return error.BadMagic;
    const ver = try br.readByte();
    if (ver != VERSION) return error.BadVersion;

    const count = try br.readU16();
    var rules = try allocator.alloc(LangRule, count);
    errdefer {
        // 回滚已构造的规则
        for (rules[0..0]) |_| {} // nothing allocated yet
        allocator.free(rules);
    }

    // 临时 ArrayList 复用
    var ext_lists = std.ArrayList([]const u8).empty;
    var alias_lists = std.ArrayList([]const u8).empty;
    var cmt_line_lists = std.ArrayList([]const u8).empty;
    var cmt_block_lists = std.ArrayList([2][]const u8).empty;
    var delim_lists = std.ArrayList(StringDelim).empty;
    var np_lists = std.ArrayList([]const u8).empty;
    defer {
        ext_lists.deinit(allocator);
        alias_lists.deinit(allocator);
        cmt_line_lists.deinit(allocator);
        cmt_block_lists.deinit(allocator);
        delim_lists.deinit(allocator);
        np_lists.deinit(allocator);
    }

    var i: usize = 0;
    while (i < count) : (i += 1) {
        // name
        const name_len = try br.readByte();
        const name = try br.readSlice(name_len);

        // extensions (NUL-separated)
        const ext_len = try br.readU16();
        ext_lists.clearRetainingCapacity();
        if (ext_len > 0) {
            const ext_data = try br.readSlice(ext_len);
            try splitZeros(allocator, &ext_lists, ext_data);
        }

        // aliases
        const al_len = try br.readU16();
        alias_lists.clearRetainingCapacity();
        if (al_len > 0) {
            const al_data = try br.readSlice(al_len);
            try splitZeros(allocator, &alias_lists, al_data);
        }

        // keywords (packed, NUL-separated)
        const kw_len = try br.readU16();
        const keywords = try br.readSlice(kw_len);

        // string_delims
        const nd = try br.readByte();
        delim_lists.clearRetainingCapacity();
        for (0..nd) |_| {
            const ol = try br.readByte();
            const o = try br.readSlice(ol);
            const cl = try br.readByte();
            const c = try br.readSlice(cl);
            const ml = (try br.readByte()) == 1;
            const esc = try br.readByte();
            try delim_lists.append(allocator, .{
                .open = o,
                .close = c,
                .multiline = ml,
                .escape = switch (esc) {
                    0 => .none,
                    1 => .backslash,
                    2 => .double,
                    else => .backslash, // 安全默认
                },
            });
        }

        // comment_line
        const ncl = try br.readByte();
        cmt_line_lists.clearRetainingCapacity();
        for (0..ncl) |_| {
            const cl = try br.readByte();
            const s = try br.readSlice(cl);
            try cmt_line_lists.append(allocator, s);
        }

        // comment_block
        const ncb = try br.readByte();
        cmt_block_lists.clearRetainingCapacity();
        for (0..ncb) |_| {
            const ol = try br.readByte();
            const o = try br.readSlice(ol);
            const cl = try br.readByte();
            const c = try br.readSlice(cl);
            try cmt_block_lists.append(allocator, .{ o, c });
        }

        // number_prefix
        const nnp = try br.readByte();
        np_lists.clearRetainingCapacity();
        for (0..nnp) |_| {
            const nl = try br.readByte();
            const s = try br.readSlice(nl);
            try np_lists.append(allocator, s);
        }

        rules[i] = .{
            .name = name,
            .extensions = try ext_lists.toOwnedSlice(allocator),
            .aliases = try alias_lists.toOwnedSlice(allocator),
            .keywords = keywords,
            .string_delims = try delim_lists.toOwnedSlice(allocator),
            .comment_line = try cmt_line_lists.toOwnedSlice(allocator),
            .comment_block = try cmt_block_lists.toOwnedSlice(allocator),
            .number_prefix = try np_lists.toOwnedSlice(allocator),
        };
    }

    return .{ .rules = rules, .data = data, .allocator = allocator };
}

/// 将 NUL 分隔的字符串拆成 slice 列表。slice 指向原数据（零拷贝）。
fn splitZeros(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), data: []const u8) !void {
    var start: usize = 0;
    for (data, 0..) |ch, j| {
        if (ch == 0) {
            if (j > start) try list.append(allocator, data[start..j]);
            start = j + 1;
        }
    }
    if (start < data.len) try list.append(allocator, data[start..]);
}

// ── 全局缓存（线程安全初始化）────────────────────────────────

var cached: ?Rules = null;
var cache_lock: std.atomic.Mutex = .unlocked;

fn getRules() []LangRule {
    if (cached == null) {
        // 自旋等待锁（高亮库无并发初始化 contention，自旋足够）
        while (!cache_lock.tryLock()) std.atomic.spinLoopHint();
        defer cache_lock.unlock();
        if (cached == null) {
            cached = init(std.heap.page_allocator) catch null;
        }
    }
    return if (cached) |*c| c.rules else &.{};
}

// ── 公共 API ────────────────────────────────────────────────

pub fn lookupByExtension(ext: []const u8) ?*const LangRule {
    const rules = getRules();
    for (rules) |*r| {
        for (r.extensions) |e| {
            if (std.mem.eql(u8, e, ext)) return r;
        }
    }
    return null;
}

pub fn lookupByName(name: []const u8) ?*const LangRule {
    const rules = getRules();
    for (rules) |*r| {
        if (std.mem.eql(u8, r.name, name)) return r;
        for (r.aliases) |a| {
            if (std.mem.eql(u8, a, name)) return r;
        }
    }
    return null;
}

pub fn ruleCount() usize {
    return getRules().len;
}

pub fn ruleAt(i: usize) ?*const LangRule {
    const rules = getRules();
    if (i >= rules.len) return null;
    return &rules[i];
}
