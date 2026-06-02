//! Prompt cache 击穿检测(批3,对齐 cc promptCacheBreakDetection.ts)。
//!
//! 低成本观测:记录上次请求的 cache_read token + system/tools 指纹;本次 cache_read
//! 相对跌幅 > 阈值且指纹有变 → 判为击穿,log warn + 记 reason(model/system/tools 变 /
//! 可能 TTL 过期)。帮助定位"为什么这轮缓存没命中"。
//!
//! 单 session 单例(挂 agent_loop run 局部);不跨线程(主对话循环单线程消费 usage 事件)。

const std = @import("std");

/// cache_read 跌幅超过此(且占上次 >5%)才判击穿,避免噪声。对齐 cc MIN_CACHE_MISS_TOKENS。
const MIN_DROP_TOKENS: u64 = 2000;

pub const CacheBreakDetector = struct {
    prev_cache_read: ?u64 = null,
    prev_system_hash: u64 = 0,
    prev_tools_hash: u64 = 0,
    prev_model_hash: u64 = 0,
    call_count: u32 = 0,
    // recordRequest 暂存,checkResponse 时与 prev 比对后转正。
    cur_system_hash: u64 = 0,
    cur_tools_hash: u64 = 0,
    cur_model_hash: u64 = 0,

    /// 请求发出前调用:记录本次的 system/tools/model 指纹(供下次对比)。
    pub fn recordRequest(self: *CacheBreakDetector, system: []const u8, tools_blob: []const u8, model: []const u8) void {
        self.cur_system_hash = std.hash.Wyhash.hash(0, system);
        self.cur_tools_hash = std.hash.Wyhash.hash(0, tools_blob);
        self.cur_model_hash = std.hash.Wyhash.hash(0, model);
    }

    /// 收到响应 usage 后调用:对比 cache_read 跌幅 + 指纹变化,判击穿。
    /// 返回击穿原因(静态串)或 null(无击穿)。caller 负责 log(便于单测)。
    pub fn checkResponse(self: *CacheBreakDetector, cache_read: u64, cache_creation: u64) ?[]const u8 {
        _ = cache_creation;
        self.call_count += 1;
        defer {
            self.prev_cache_read = cache_read;
            self.prev_system_hash = self.cur_system_hash;
            self.prev_tools_hash = self.cur_tools_hash;
            self.prev_model_hash = self.cur_model_hash;
        }
        const prev = self.prev_cache_read orelse return null; // 首次无基线
        if (cache_read >= prev) return null; // 没跌 → 无击穿
        const drop = prev - cache_read;
        if (drop < MIN_DROP_TOKENS) return null; // 跌幅太小 → 噪声
        if (drop * 100 < prev * 5) return null; // < 5% → 噪声

        if (self.cur_model_hash != self.prev_model_hash) return "model changed";
        if (self.cur_system_hash != self.prev_system_hash) return "system prompt changed";
        if (self.cur_tools_hash != self.prev_tools_hash) return "tool schemas changed";
        return "prompt unchanged (likely TTL expiry or server-side)";
    }
};
