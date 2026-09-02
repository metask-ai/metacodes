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
    /// 用户输入的一等图像内容(issue #10)。base64 载荷 + MIME,与 text 按序混排,
    /// 参与当前请求、后续轮次与 session 恢复。绝不以 OCR/描述/占位文本替代。
    image: Image,

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
            .image => |img| {
                allocator.free(img.media_type);
                allocator.free(img.data);
            },
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
            .image => |img| blk: {
                const mt = try dst.dupe(u8, img.media_type);
                errdefer dst.free(mt);
                const data = try dst.dupe(u8, img.data);
                break :blk Block{ .image = .{ .media_type = mt, .data = data } };
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

/// 图像块(base64 载荷)。media_type 必须与实际内容一致(至少 image/png、image/jpeg)。
pub const Image = struct {
    media_type: []const u8,
    data: []const u8,
};

/// 一条对话消息（role + blocks）。所有 block 内部字节为 allocator 拥有。
pub const Message = struct {
    role: Role,
    blocks: []Block,
    /// 是否已被 provider 接受进入流式响应(agent_loop 在拿到流句柄后统一置位;被 HTTP
    /// 错误拒绝的请求不算)。
    /// 只能由送达证据推进:本地追加的 assistant 消息(AgentCore 预算终止标记等)不算,
    /// transcript resume 出来的消息一律 false,直到下一次请求带上它们。microcompact 据此
    /// 保护尚未被模型看到的图片结果。
    delivered: bool = false,

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
        return .{ .role = self.role, .blocks = blocks, .delivered = self.delivered };
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

/// 输入图像描述(路径无关的纯内容对):宿主先读文件/剪贴板并 base64,再交本构造函数。
pub const ImageInput = struct {
    media_type: []const u8,
    /// base64 编码字节。
    data: []const u8,
};

/// 构造多模态 user Message:可选前置 text + 按序图像列表(全部字节 dupe 成 owned)。
/// text 为空且 images 为空 → error.EmptyMessage(不产出空 content 消息)。
/// 定位:lib 嵌入方(borrowed 输入)的便利入口。CLI headless 自建 blocks(载荷所有权
/// 直接转移,免二次 MB 拷贝),故仓库内无生产调用方——这是刻意保留的公共 API。
pub fn userMessageWithImages(
    allocator: std.mem.Allocator,
    text: []const u8,
    images: []const ImageInput,
) !Message {
    const block_count = images.len + @intFromBool(text.len > 0);
    if (block_count == 0) return error.EmptyMessage;
    const blocks = try allocator.alloc(Block, block_count);
    errdefer allocator.free(blocks);
    var built: usize = 0;
    errdefer for (blocks[0..built]) |b| b.deinit(allocator);
    if (text.len > 0) {
        blocks[0] = .{ .text = try allocator.dupe(u8, text) };
        built = 1;
    }
    for (images) |img| {
        const mt = try allocator.dupe(u8, img.media_type);
        errdefer allocator.free(mt);
        const data = try allocator.dupe(u8, img.data);
        blocks[built] = .{ .image = .{ .media_type = mt, .data = data } };
        built += 1;
    }
    return .{ .role = .user, .blocks = blocks };
}

/// 一段借入的多模态根输入:text/image 任意有序混排(不限"前置 text + 图列表")。
/// 字节在构造/追加时复制;调用方保留切片所有权。
pub const UserContentPart = union(enum) {
    text: []const u8,
    image: ImageInput,
};

/// 构造 text/image 任意有序混排的 user Message(全部字节 dupe 成 owned)。
/// parts 为空 → error.EmptyMessage(不产出空 content 消息)。
pub fn userMessageFromParts(
    allocator: std.mem.Allocator,
    parts: []const UserContentPart,
) !Message {
    if (parts.len == 0) return error.EmptyMessage;
    const blocks = try allocator.alloc(Block, parts.len);
    errdefer allocator.free(blocks);
    var built: usize = 0;
    errdefer for (blocks[0..built]) |b| b.deinit(allocator);
    for (parts) |part| {
        blocks[built] = switch (part) {
            .text => |t| .{ .text = try allocator.dupe(u8, t) },
            .image => |img| blk: {
                const mt = try allocator.dupe(u8, img.media_type);
                errdefer allocator.free(mt);
                const data = try allocator.dupe(u8, img.data);
                break :blk .{ .image = .{ .media_type = mt, .data = data } };
            },
        };
        built += 1;
    }
    return .{ .role = .user, .blocks = blocks };
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

test "userMessageWithImages: text+images 按序构造(owned dupe)" {
    const a = std.testing.allocator;
    const inputs = [_]ImageInput{
        .{ .media_type = "image/png", .data = "UE5H" },
        .{ .media_type = "image/jpeg", .data = "SlBH" },
    };
    const m = try userMessageWithImages(a, "看图", &inputs);
    defer m.deinit(a);
    try std.testing.expect(m.role == .user);
    try std.testing.expectEqual(@as(usize, 3), m.blocks.len);
    try std.testing.expectEqualStrings("看图", m.blocks[0].text);
    try std.testing.expectEqualStrings("image/png", m.blocks[1].image.media_type);
    try std.testing.expectEqualStrings("SlBH", m.blocks[2].image.data);
}

test "userMessageWithImages: 空 text 只图;全空报 EmptyMessage" {
    const a = std.testing.allocator;
    const inputs = [_]ImageInput{.{ .media_type = "image/png", .data = "UE5H" }};
    const m = try userMessageWithImages(a, "", &inputs);
    defer m.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), m.blocks.len);
    try std.testing.expect(@as(std.meta.Tag(Block), m.blocks[0]) == .image);
    try std.testing.expectError(error.EmptyMessage, userMessageWithImages(a, "", &.{}));
}

test "Block.dupe/deinit image 深拷贝无泄漏" {
    const a = std.testing.allocator;
    const src = Block{ .image = .{
        .media_type = try a.dupe(u8, "image/png"),
        .data = try a.dupe(u8, "QUJDRA=="),
    } };
    const copy = try src.dupe(a);
    src.deinit(a);
    defer copy.deinit(a);
    try std.testing.expectEqualStrings("image/png", copy.image.media_type);
    try std.testing.expectEqualStrings("QUJDRA==", copy.image.data);
}

test "userMessageFromParts: 任意有序混排(text-image-text, owned dupe)" {
    const a = std.testing.allocator;
    const parts = [_]UserContentPart{
        .{ .text = "前文" },
        .{ .image = .{ .media_type = "image/png", .data = "UE5H" } },
        .{ .text = "后文" },
    };
    const m = try userMessageFromParts(a, &parts);
    defer m.deinit(a);
    try std.testing.expect(m.role == .user);
    try std.testing.expectEqual(@as(usize, 3), m.blocks.len);
    try std.testing.expectEqualStrings("前文", m.blocks[0].text);
    try std.testing.expectEqualStrings("image/png", m.blocks[1].image.media_type);
    try std.testing.expectEqualStrings("UE5H", m.blocks[1].image.data);
    try std.testing.expectEqualStrings("后文", m.blocks[2].text);
    try std.testing.expectError(error.EmptyMessage, userMessageFromParts(a, &.{}));
}
