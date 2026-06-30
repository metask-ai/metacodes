//! Structured conversation message types.
//!
//! Content 是 tagged union，区分三种类型：text / tool_use / tool_result。
//! 这是为了对齐 Anthropic Messages API 契约，也是消除 "所有内容扁平为 text" hack
//! 和假想的 `__TOOL_RESULT__:` 字符串前缀的唯一正确路径。
//!
//! 所有字符串字段都是 owned（allocator 拥有），Conversation 负责 deinit 时释放。

const std = @import("std");
const types = @import("../types.zig");

/// Role 直接复用 types.MessageRole，避免两套枚举互转。
pub const Role = types.MessageRole;

/// 一个消息内容块。
///
/// 对应 Anthropic API 的 content block 类型：
/// - `.text`：普通文本片段
/// - `.tool_use`：assistant 发起的工具调用（id + name + input JSON）
/// - `.tool_result`：user 提交的工具执行结果（对应某个 tool_use_id）
pub const Block = union(enum) {
    text: []const u8,
    tool_use: ToolUse,
    tool_result: ToolResult,
    /// Extended thinking 内容(对齐 Claude 3.7+)。content_block_start type="thinking"
    /// + thinking_delta 累积。展示走 tui/widget/thinking.zig。
    thinking: []const u8,

    pub fn deinit(self: Block, allocator: std.mem.Allocator) void {
        switch (self) {
            .text => |t| allocator.free(t),
            .tool_use => |tu| {
                allocator.free(tu.id);
                allocator.free(tu.name);
                allocator.free(tu.input);
            },
            .tool_result => |tr| {
                allocator.free(tr.tool_use_id);
                allocator.free(tr.content);
            },
            .thinking => |t| allocator.free(t),
        }
    }

    /// 深拷贝本 block 的全部 owned 字节到 dst allocator(转后台 conversation 副本用)。
    /// 失败时已分配部分自行回收(errdefer),不泄漏。返回的 Block 完全归 dst。
    pub fn dupe(self: Block, dst: std.mem.Allocator) !Block {
        return switch (self) {
            .text => |t| Block{ .text = try dst.dupe(u8, t) },
            .thinking => |t| Block{ .thinking = try dst.dupe(u8, t) },
            .tool_use => |tu| blk: {
                const id = try dst.dupe(u8, tu.id);
                errdefer dst.free(id);
                const name = try dst.dupe(u8, tu.name);
                errdefer dst.free(name);
                const input = try dst.dupe(u8, tu.input);
                break :blk Block{ .tool_use = .{ .id = id, .name = name, .input = input } };
            },
            .tool_result => |tr| blk: {
                const tid = try dst.dupe(u8, tr.tool_use_id);
                errdefer dst.free(tid);
                const content = try dst.dupe(u8, tr.content);
                break :blk Block{ .tool_result = .{ .tool_use_id = tid, .content = content, .is_error = tr.is_error } };
            },
        };
    }
};

pub const ToolUse = struct {
    id: []const u8,
    name: []const u8,
    input: []const u8, // JSON string
};

pub const ToolResult = struct {
    tool_use_id: []const u8,
    content: []const u8,
    is_error: bool = false,
};

/// 一条对话消息（role + blocks）。所有 block 内部字节为 allocator 拥有。
pub const Message = struct {
    role: Role,
    blocks: []Block,

    pub fn deinit(self: Message, allocator: std.mem.Allocator) void {
        for (self.blocks) |b| b.deinit(allocator);
        allocator.free(self.blocks);
    }

    /// 深拷贝本消息(role + 每个 block)到 dst allocator。失败回收已拷部分,不泄漏。
    pub fn dupe(self: Message, dst: std.mem.Allocator) !Message {
        const blocks = try dst.alloc(Block, self.blocks.len);
        errdefer dst.free(blocks);
        var n: usize = 0;
        errdefer for (blocks[0..n]) |b| b.deinit(dst);
        for (self.blocks, 0..) |b, i| {
            blocks[i] = try b.dupe(dst);
            n = i + 1;
        }
        return .{ .role = self.role, .blocks = blocks };
    }
};

/// 构造仅含一条 text block 的 Message（方便测试和简单用例）。
pub fn textMessage(role: Role, text: []const u8, allocator: std.mem.Allocator) !Message {
    const text_owned = try allocator.dupe(u8, text);
    errdefer allocator.free(text_owned);
    const blocks = try allocator.alloc(Block, 1);
    blocks[0] = .{ .text = text_owned };
    return .{ .role = role, .blocks = blocks };
}

test "textMessage roundtrip" {
    var m = try textMessage(.user, "hello", std.testing.allocator);
    defer m.deinit(std.testing.allocator);
    try std.testing.expect(m.role == .user);
    try std.testing.expect(m.blocks.len == 1);
    try std.testing.expectEqualStrings("hello", m.blocks[0].text);
}

test "Block.deinit tool_use releases all strings" {
    const a = std.testing.allocator;
    const blk = Block{ .tool_use = .{
        .id = try a.dupe(u8, "tool_1"),
        .name = try a.dupe(u8, "Bash"),
        .input = try a.dupe(u8, "{\"command\":\"ls\"}"),
    } };
    blk.deinit(a);
    // 不泄漏即通过（testing.allocator 会检查）
}

test "Block.deinit tool_result releases strings" {
    const a = std.testing.allocator;
    const blk = Block{ .tool_result = .{
        .tool_use_id = try a.dupe(u8, "tool_1"),
        .content = try a.dupe(u8, "{\"ok\":true}"),
        .is_error = false,
    } };
    blk.deinit(a);
}

test "Message with multiple blocks" {
    const a = std.testing.allocator;
    const blocks = try a.alloc(Block, 2);
    blocks[0] = .{ .text = try a.dupe(u8, "Using tool:") };
    blocks[1] = .{ .tool_use = .{
        .id = try a.dupe(u8, "t1"),
        .name = try a.dupe(u8, "Read"),
        .input = try a.dupe(u8, "{\"path\":\"/x\"}"),
    } };
    const m = Message{ .role = .assistant, .blocks = blocks };
    defer m.deinit(a);
    try std.testing.expect(m.blocks.len == 2);
    try std.testing.expect(@as(std.meta.Tag(Block), m.blocks[1]) == .tool_use);
}

test "Message.dupe 深拷贝独立 + 无泄漏(含 4 种 block)" {
    const a = std.testing.allocator;
    const blocks = try a.alloc(Block, 4);
    blocks[0] = .{ .text = try a.dupe(u8, "hi") };
    blocks[1] = .{ .thinking = try a.dupe(u8, "thinking...") };
    blocks[2] = .{ .tool_use = .{ .id = try a.dupe(u8, "t1"), .name = try a.dupe(u8, "Bash"), .input = try a.dupe(u8, "{}") } };
    blocks[3] = .{ .tool_result = .{ .tool_use_id = try a.dupe(u8, "t1"), .content = try a.dupe(u8, "ok"), .is_error = true } };
    var src = Message{ .role = .assistant, .blocks = blocks };

    var copy = try src.dupe(a);
    // 释放源 → 副本仍有效(证明深拷贝,无共享指针)。
    src.deinit(a);
    defer copy.deinit(a);
    try std.testing.expect(copy.role == .assistant);
    try std.testing.expectEqual(@as(usize, 4), copy.blocks.len);
    try std.testing.expectEqualStrings("hi", copy.blocks[0].text);
    try std.testing.expectEqualStrings("thinking...", copy.blocks[1].thinking);
    try std.testing.expectEqualStrings("Bash", copy.blocks[2].tool_use.name);
    try std.testing.expectEqualStrings("ok", copy.blocks[3].tool_result.content);
    try std.testing.expect(copy.blocks[3].tool_result.is_error);
}
