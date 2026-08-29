//! 兼容性 re-export shim。M0.3 已把内容拆分到 api/ 和 util/。
//! 保留此文件是为了让 client.zig / main.zig / tools.zig 不改 import。
//! 后续里程碑会逐步把 import 换成新路径，再删除本文件。

const api_request = @import("api/request.zig");
const api_stream = @import("api/stream.zig");
const util_json = @import("util/json.zig");

// --- api/request.zig 重导出 ---
pub const MessagesRequest = api_request.MessagesRequest;
pub const ToolChoice = api_request.ToolChoice;
pub const ToolDefinition = api_request.ToolDefinition;
pub const ModelToolActivation = api_request.ModelToolActivation;
pub const InputSchema = api_request.InputSchema;
pub const PropSpec = api_request.PropSpec;
pub const serializeMessagesRequest = api_request.serializeMessagesRequest;
pub const serializeCanonicalRequestProjection = api_request.serializeCanonicalRequestProjection;
pub const serializeMessagesRequestWithDialect = api_request.serializeMessagesRequestWithDialect;

// --- api/stream.zig 重导出 ---
pub const SseParser = api_stream.SseParser;
pub const SseEventType = api_stream.SseEventType;
pub const parseEventType = api_stream.parseEventType;
pub const ToolUseResult = api_stream.ToolUseResult;
pub const extractTextDelta = api_stream.extractTextDelta;
pub const extractToolUse = api_stream.extractToolUse;

// --- util/json.zig 重导出 ---
pub const serializeString = util_json.serializeString;

// --- 以下是尚未被其他模块引用的旧 API，保留签名防止后续破坏 ---

/// API 错误响应结构。
pub const ApiError = struct {
    @"error": struct {
        type: []const u8,
        message: []const u8,
    },
};

/// 解析 API 错误响应（best-effort，未匹配返回 null）。
pub fn parseApiError(data: []const u8) ?ApiError {
    const std_mod = @import("std");
    const type_idx = std_mod.mem.indexOf(u8, data, "\"type\":\"") orelse return null;
    const msg_idx = std_mod.mem.indexOf(u8, data, "\"message\":\"") orelse return null;

    const type_start = type_idx + 8;
    const type_end = std_mod.mem.indexOfScalar(u8, data[type_start..], '"') orelse return null;

    const msg_start = msg_idx + 10;
    const msg_end = std_mod.mem.indexOfScalar(u8, data[msg_start..], '"') orelse return null;

    return ApiError{
        .@"error" = .{
            .type = data[type_start .. type_start + type_end],
            .message = data[msg_start .. msg_start + msg_end],
        },
    };
}

/// 从非流式响应的 content 数组中提取 text。
pub fn extractTextContent(data: []const u8, allocator: @import("std").mem.Allocator) ![]u8 {
    const std_mod = @import("std");
    const arr_start = std_mod.mem.indexOf(u8, data, "\"content\":[") orelse return try allocator.dupe(u8, "");
    var i = arr_start + 11;
    if (i >= data.len or data[i] != '{') return try allocator.dupe(u8, "");

    var depth: i32 = 1;
    i += 1;
    while (i < data.len and depth > 0) : (i += 1) {
        if (data[i] == '{') depth += 1;
        if (data[i] == '}') depth -= 1;
    }
    i += 1;
    while (i < data.len and data[i] != ']') : (i += 1) {}

    const content_obj = data[arr_start + 11 .. i];
    if (std_mod.mem.indexOf(u8, content_obj, "\"type\":\"text\"") != null) {
        if (std_mod.mem.indexOf(u8, content_obj, "\"text\":\"")) |text_start| {
            const s = text_start + 8;
            var e = s;
            while (e < content_obj.len) : (e += 1) {
                if (content_obj[e] == '"' and content_obj[e - 1] != '\\') break;
            }
            return try util_json.unescapeString(content_obj[s..e], allocator);
        }
    }
    return try allocator.dupe(u8, "");
}

test {
    _ = &api_request;
    _ = &api_stream;
    _ = &util_json;
}
