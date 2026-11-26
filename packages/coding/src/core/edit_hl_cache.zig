//! Edit/Write 旁路高亮缓存:存"工具产出的新旧文件全文",供 diff 工具卡做
//! tree-sitter 语法高亮。**不进对话历史、不占 token**——这是它存在的全部理由。
//!
//! 为什么旁路而非读盘/塞 tool_result:
//! - 读盘:渲染层碰 IO + 隐式时序假设(盘上==刚写)+ del 行拿不到(旧文件已被覆盖)。
//! - 塞 tool_result:Edit/Write 结果原样进对话历史 → 全文翻几倍 token。
//! - 旁路缓存:Edit 执行时手里现成的 old/new 全文存进来,渲染期按 tool_id 取,用完即弃。
//!
//! key = tool_use id(ctx.progress_tool_id 写,.tool_result.id 读,二者同源)。
//! 生命周期:挂 App,session 退出 deinit。MAX_ENTRIES 上限 + FIFO 驱逐防累积。
//! 线程安全:并发工具执行(批1)下 put 可能在工具线程,渲染在主线程 → 加锁。

const std = @import("std");
const sync = @import("platform").sync;

/// 单条:某次 Edit/Write 的新旧全文(owned)。
pub const Entry = struct {
    old: []u8,
    new: []u8,
    seq: u64, // 插入序号,FIFO 驱逐用
};

/// 超此大小的内容不缓存(大文件不值得高亮,也防爆内存)。
pub const CAP_BYTES: usize = 1 << 20; // 1MB
/// 最多缓存条目数;超出驱逐最老(diff 卡一次性 commit,旧条目读完即无用)。
pub const MAX_ENTRIES: usize = 16;

pub const EditHlCache = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(Entry),
    mutex: sync.Mutex = .{},
    next_seq: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) EditHlCache {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(Entry).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *EditHlCache) void {
        var it = self.map.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.free(kv.value_ptr.old);
            self.allocator.free(kv.value_ptr.new);
        }
        self.map.deinit();
    }

    fn lock(self: *EditHlCache) void {
        _ = self.mutex.lock();
    }
    fn unlock(self: *EditHlCache) void {
        _ = self.mutex.unlock();
    }

    /// 存一次 Edit/Write 的新旧全文。深拷贝 key+old+new。超 CAP 静默跳过。
    /// 失败静默(高亮是锦上添花,绝不影响工具结果)。重复 key 覆盖。
    pub fn put(self: *EditHlCache, tool_id: []const u8, old: []const u8, new: []const u8) void {
        if (tool_id.len == 0) return;
        if (old.len > CAP_BYTES or new.len > CAP_BYTES) return;
        self.lock();
        defer self.unlock();

        // 先驱逐(若已满且是新 key)。
        if (self.map.count() >= MAX_ENTRIES and !self.map.contains(tool_id)) {
            self.evictOldestLocked();
        }

        const old_dup = self.allocator.dupe(u8, old) catch return;
        const new_dup = self.allocator.dupe(u8, new) catch {
            self.allocator.free(old_dup);
            return;
        };

        const gop = self.map.getOrPut(tool_id) catch {
            self.allocator.free(old_dup);
            self.allocator.free(new_dup);
            return;
        };
        if (gop.found_existing) {
            // 覆盖:释放旧值,保留 key。
            self.allocator.free(gop.value_ptr.old);
            self.allocator.free(gop.value_ptr.new);
        } else {
            const key_dup = self.allocator.dupe(u8, tool_id) catch {
                self.allocator.free(old_dup);
                self.allocator.free(new_dup);
                _ = self.map.remove(tool_id); // 撤销半建的 entry
                return;
            };
            gop.key_ptr.* = key_dup;
        }
        gop.value_ptr.* = .{ .old = old_dup, .new = new_dup, .seq = self.next_seq };
        self.next_seq += 1;
    }

    /// 取(借,渲染期同步读)。返回 null = 未命中(渲染层退回关键字表)。
    pub fn get(self: *EditHlCache, tool_id: []const u8) ?Entry {
        self.lock();
        defer self.unlock();
        return self.map.get(tool_id);
    }

    /// 驱逐 seq 最小(最老)的条目。调用方须持锁。
    fn evictOldestLocked(self: *EditHlCache) void {
        var oldest_key: ?[]const u8 = null;
        var oldest_seq: u64 = std.math.maxInt(u64);
        var it = self.map.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.seq < oldest_seq) {
                oldest_seq = kv.value_ptr.seq;
                oldest_key = kv.key_ptr.*;
            }
        }
        if (oldest_key) |k| {
            if (self.map.fetchRemove(k)) |removed| {
                self.allocator.free(removed.key);
                self.allocator.free(removed.value.old);
                self.allocator.free(removed.value.new);
            }
        }
    }
};

// ============================================================================
// 测试
// ============================================================================
const testing = std.testing;

test "put/get 往返 + 深拷贝(原串释放后仍可读)" {
    const a = testing.allocator;
    var cache = EditHlCache.init(a);
    defer cache.deinit();

    {
        // 用堆上临时串 put,出作用域释放,验证 cache 内是深拷贝。
        const old_tmp = try a.dupe(u8, "old content");
        const new_tmp = try a.dupe(u8, "new content");
        cache.put("tool-1", old_tmp, new_tmp);
        a.free(old_tmp);
        a.free(new_tmp);
    }

    const e = cache.get("tool-1").?;
    try testing.expectEqualStrings("old content", e.old);
    try testing.expectEqualStrings("new content", e.new);
    try testing.expect(cache.get("nope") == null);
}

test "put 覆盖同 key" {
    const a = testing.allocator;
    var cache = EditHlCache.init(a);
    defer cache.deinit();
    cache.put("t", "o1", "n1");
    cache.put("t", "o2", "n2");
    const e = cache.get("t").?;
    try testing.expectEqualStrings("o2", e.old);
    try testing.expectEqualStrings("n2", e.new);
    try testing.expectEqual(@as(u32, 1), cache.map.count());
}

test "超 CAP_BYTES 不缓存" {
    const a = testing.allocator;
    var cache = EditHlCache.init(a);
    defer cache.deinit();
    const big = try a.alloc(u8, CAP_BYTES + 1);
    defer a.free(big);
    @memset(big, 'x');
    cache.put("big", "small", big); // new 超限
    try testing.expect(cache.get("big") == null);
    cache.put("big2", big, "small"); // old 超限
    try testing.expect(cache.get("big2") == null);
}

test "超 MAX_ENTRIES 驱逐最老" {
    const a = testing.allocator;
    var cache = EditHlCache.init(a);
    defer cache.deinit();

    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < MAX_ENTRIES) : (i += 1) {
        const k = try std.fmt.bufPrint(&buf, "t{d}", .{i});
        cache.put(k, "o", "n");
    }
    try testing.expectEqual(@as(u32, MAX_ENTRIES), cache.map.count());
    // t0 是最老。再 put 一个新 key → t0 应被驱逐。
    cache.put("newkey", "o", "n");
    try testing.expectEqual(@as(u32, MAX_ENTRIES), cache.map.count());
    try testing.expect(cache.get("t0") == null);
    try testing.expect(cache.get("newkey") != null);
    // t1 仍在(只驱逐了最老一个)。
    try testing.expect(cache.get("t1") != null);
}

test "空 tool_id 不存" {
    const a = testing.allocator;
    var cache = EditHlCache.init(a);
    defer cache.deinit();
    cache.put("", "o", "n");
    try testing.expectEqual(@as(u32, 0), cache.map.count());
}
