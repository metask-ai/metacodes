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
        }
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
