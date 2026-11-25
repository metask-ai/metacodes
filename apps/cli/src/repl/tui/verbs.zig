//! 趣味动词词库 + spinner 动画帧(复刻 Claude Code 状态栏观感)。
//!
//! Claude Code 生成期间状态栏显示一个旋转字符 + 一个趣味动词(如 "Cooking…"),
//! 一轮一个动词、动画字符每 ~100ms 推进一帧。本模块提供 Zig 自建的精简词库
//! (不照搬 cc 的 200+ 商标词表)+ 帧字符 + 取词函数。
//!
//! 随机源:不用 crypto/Math.random(某些环境受限/偏重),用调用方传入的 seed
//! (通常 std.time.milliTimestamp() 低位 或 stream RequestId 哈希)。

const std = @import("std");

/// 趣味动词(进行时省略 …,由渲染方补)。自建精简版,~50 个。
pub const verbs = [_][]const u8{
    "Thinking",    "Pondering",   "Cooking",    "Brewing",       "Conjuring",
    "Noodling",    "Computing",   "Crunching",  "Churning",      "Tinkering",
    "Wrangling",   "Sculpting",   "Assembling", "Orchestrating", "Synthesizing",
    "Untangling",  "Percolating", "Marinating", "Distilling",    "Reticulating",
    "Calibrating", "Forging",     "Weaving",    "Spinning",      "Hatching",
    "Plotting",    "Scheming",    "Divining",   "Channeling",    "Summoning",
    "Crafting",    "Polishing",   "Tuning",     "Wiring",        "Stitching",
    "Composing",   "Drafting",    "Mulling",    "Ruminating",    "Cogitating",
    "Processing",  "Calculating", "Iterating",  "Pondering",     "Deliberating",
    "Whirring",    "Buzzing",     "Humming",    "Simmering",     "Bubbling",
};

/// spinner 动画帧字符(有颜色能力时用)。每 tick 推进一帧。
pub const frames = [_][]const u8{ "✻", "✦", "✶", "✺", "✷", "✸" };

/// monochrome / 无 unicode 时的降级帧。
pub const frames_ascii = [_][]const u8{ "|", "/", "-", "\\" };

/// 按 seed 取一个动词(整轮固定)。
pub fn pick(seed: u64) []const u8 {
    return verbs[@intCast(seed % verbs.len)];
}

/// 按 frame 序号取动画字符。use_unicode=false 用 ASCII 降级集。
pub fn frame(idx: u8, use_unicode: bool) []const u8 {
    if (use_unicode) {
        return frames[@intCast(idx % frames.len)];
    }
    return frames_ascii[@intCast(idx % frames_ascii.len)];
}

test "pick deterministic + in range" {
    const v1 = pick(0);
    try std.testing.expectEqualStrings(verbs[0], v1);
    const v2 = pick(verbs.len); // wrap → verbs[0]
    try std.testing.expectEqualStrings(verbs[0], v2);
    // 任意 seed 不越界
    var s: u64 = 0;
    while (s < 200) : (s += 7) {
        const v = pick(s);
        try std.testing.expect(v.len > 0);
    }
}

test "frame unicode + ascii in range" {
    try std.testing.expectEqualStrings(frames[0], frame(0, true));
    try std.testing.expectEqualStrings(frames_ascii[0], frame(0, false));
    // wrap
    try std.testing.expectEqualStrings(frames[0], frame(frames.len, true));
    try std.testing.expectEqualStrings(frames_ascii[0], frame(frames_ascii.len, false));
}
