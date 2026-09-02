//! 弱模型健壮性层(P0.6)。移植自 hermes-agent 的防御性修复,面向 OpenAI-compat 后端跑的弱
//! 模型(它们比 Anthropic 更容易产出畸形输出、更严格地校验请求)。三块能力:
//!
//! 1. **JSON 参数修复** `repairToolArgs`:模型产出的 tool input 非法(markdown 围栏 / trailing
//!    comma / 括号不配平 / 空 / Python None)时,尽力 salvage 成合法 JSON object,兜底 `{}`。
//! 2. **孤儿 tool_result 剥离 + 缺失 tool_result 补桩** `stripOrphanToolResults` /
//!    `stubMissingToolResults`:tool_use↔tool_result 必须配对,否则 OpenAI/Gemini(乃至 Anthropic
//!    同-turn)会 400。剥掉无对应 tool_use 的孤儿结果;给无结果的 tool_use 补一条占位结果。
//! 3. **角色交替修复** `mergeConsecutiveRoles`:合并相邻同角色消息(OpenAI/Gemini 要求严格
//!    user/assistant 交替;inject_user_context + 首条 user 就是一例连续 user)。
//!
//! `normalizeApiMessages` 把 2/3 串起来,在 buildApiMessages 出口跑一遍(发请求前唯一集中点)。
//! JSON 修复(1)在 SSE 累积完成处单独调(那里才拿到原始 input_json)。
//!
//! **内存契约**(与 buildApiMessages/freeApiMessages 对齐):ApiMessage.content 数组由 allocator
//! 拥有(freeApiMessages 会 free 它);block 内字符串是**借用**(lifetime 绑 conversation,不 free)。
//! 本层任何重建 content 数组处必须维持此契约:新数组 alloc、旧数组 free、block 字符串继续借用。
//! 补桩用的占位串是 static const(借用语义,永不 free)。

const std = @import("std");
const types = @import("../types.zig");
const log = @import("../util/log.zig");

// ============================================================================
// 1. JSON 参数修复
// ============================================================================

/// 语法校验:data 是否合法 JSON(不限 object——number/string/array 也算合法,与 Scanner 一致)。
/// 用 stackFallback(2KB 栈优先,深嵌套才落 page_allocator)避免每次 tool call 都向内核要页。
pub fn isValidJson(data: []const u8) bool {
    var sfa = std.heap.stackFallback(2048, std.heap.page_allocator);
    var scanner = std.json.Scanner.initCompleteInput(sfa.get(), data);
    defer scanner.deinit();
    while (true) {
        const tok = scanner.next() catch return false;
        if (tok == .end_of_document) return true;
    }
}

/// 尽力把 raw 修成合法 JSON。返回 owned(调用方 free);已合法则 dupe 原样返回。修不好兜底 `"{}"`。
/// 修复顺序(每步后重试解析,命中即返回):① 空/None/null → `{}` ② 剥 markdown 代码围栏
/// ③ 删除数组元素边界重复的 `}`（GLM 会在每个 object 后重复）或单个错位闭括号；
///    两种都只在删除后整个 object 立即合法时采用
/// ④ **抽取首个完整 JSON value**(同时吃掉前置**和尾部**噪声——弱模型高频:`{...} 我的理由是…`)
/// ⑤ 删 trailing comma ⑥ 补缺失闭合括号 ⑦ 补括号后再删 trailing comma(治 `{"a":1,`)⑧ 兜底 `{}`。
///
/// **明确不处理**(命中即落 ⑧ 兜底 `{}`,静默丢整个参数对象——弱模型这两类较少见,登记为已知缺口):
///   - 单引号→双引号(风险高:字符串内合法单引号会被误伤);
///   - Python 值字面量 `{"x": True/False/None}`(值位置,非 key);
///   - 未闭合字符串 `{"a":"hel`(缺闭合引号,非缺括号)。
pub fn repairToolArgs(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var cur = std.mem.trim(u8, raw, " \t\r\n");

    // ① 空 / Python None / JSON null → 空对象。tool args 期望 object,`null`/`""` 虽合法但对工具
    //   无意义,统一归一 {}。必须在 isValidJson 短路**之前**(否则 "null" 会被当合法原样返回)。
    if (cur.len == 0 or std.mem.eql(u8, cur, "None") or std.mem.eql(u8, cur, "null")) {
        return allocator.dupe(u8, "{}");
    }

    // 已合法:原样返回(避免无谓改写)。
    if (isValidJson(cur)) return allocator.dupe(u8, cur);

    // ② markdown 代码围栏:```json\n...\n``` 或 ```\n...\n```。
    cur = stripCodeFence(cur);
    cur = std.mem.trim(u8, cur, " \t\r\n");
    if (isValidJson(cur)) return allocator.dupe(u8, cur);

    // ③a GLM 实战样本会在 variants 数组的**每个** object 后多产一个 `}`。
    // 只删除这个可精确识别的数组元素边界 closer，且整体重新解析合法才采用。
    if (try removeRepeatedArrayItemExtraClosers(allocator, cur)) |repaired| {
        defer allocator.free(repaired);
        if (isValidJson(repaired)) return allocator.dupe(u8, repaired);
    }

    // ③b 删除一个其它错位的闭括号。必须在抽取首个 value 之前做：无类型 depth
    // 计数会把错位的 `}` 当作合法闭合并过早截掉其后的完整字段。
    if (try removeSingleMismatchedCloser(allocator, cur)) |repaired| {
        defer allocator.free(repaired);
        if (isValidJson(repaired)) return allocator.dupe(u8, repaired);
    }

    // ④ 抽取首个**完整** JSON value(depth 归零处截断)。这同时吃掉前置噪声(从首个 {/[ 起)
    //   和**尾部噪声**(完整 value 之后的 prose)。前缀合法+尾部废话是弱模型最高频畸形。
    if (extractFirstJsonValue(cur)) |v| {
        if (isValidJson(v)) return allocator.dupe(u8, v);
        cur = v; // 找到起点但 depth 未归零(截断)→ 在这个收窄的 slice 上继续补括号。
    } else {
        cur = stripLeadingNoise(cur); // 无完整 value → 至少剥前置噪声再试补救。
    }
    cur = std.mem.trim(u8, cur, " \t\r\n");
    if (isValidJson(cur)) return allocator.dupe(u8, cur);

    // ⑤ 删 trailing comma(`,` 后仅空白再跟 `}`/`]`)。
    const no_trailing = try removeTrailingCommas(allocator, cur);
    defer allocator.free(no_trailing);
    if (isValidJson(no_trailing)) return allocator.dupe(u8, no_trailing);

    // ⑥ 补缺失闭合括号(按 stack 逆序补 `}`/`]`;跳过字符串内)。
    const balanced = try balanceBrackets(allocator, no_trailing);
    defer allocator.free(balanced);
    if (isValidJson(balanced)) return allocator.dupe(u8, balanced);

    // ⑦ 补括号可能在 trailing comma 后追加了 `}`(如 `{"a":1,` → `{"a":1,}`)→ 再删一次 trailing comma。
    const balanced_notrail = try removeTrailingCommas(allocator, balanced);
    defer allocator.free(balanced_notrail);
    if (isValidJson(balanced_notrail)) return allocator.dupe(u8, balanced_notrail);

    // ⑧ 兜底:保证请求不崩(工具执行时缺参会再报错给模型,总比整轮 400 好)。
    log.warn("repair", "tool args 无法 salvage,兜底 {{}}(原文 {d} 字节)", .{raw.len});
    return allocator.dupe(u8, "{}");
}

/// 删除 GLM 偶发的数组元素重复 closer: `[{...}}, {...}}]` → `[{...}, {...}]`。
/// 只认可下列唯一形状：当 delimiter stack 正等待 `]`时遇到 `}`，前一个非空白字符
/// 已是 `}`（元素 object 已合法闭合），且后一个非空白字符是 `,` 或 `]`。其它任何
/// 不匹配括号都放弃这个候选；caller 还会要求修复后整体通过 JSON parser。
fn removeRepeatedArrayItemExtraClosers(allocator: std.mem.Allocator, s: []const u8) !?[]u8 {
    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(allocator);
    var remove_indices = std.ArrayList(usize).empty;
    defer remove_indices.deinit(allocator);

    var in_str = false;
    var escaped = false;
    for (s, 0..) |c, i| {
        if (in_str) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{' => try expected.append(allocator, '}'),
            '[' => try expected.append(allocator, ']'),
            '}', ']' => {
                if (expected.items.len > 0 and expected.items[expected.items.len - 1] == c) {
                    _ = expected.pop();
                    continue;
                }
                const stack_expects_array_end = expected.items.len > 0 and expected.items[expected.items.len - 1] == ']';
                const previous = previousNonWhitespace(s, i);
                const next = nextNonWhitespace(s, i + 1);
                const is_array_item_extra = c == '}' and stack_expects_array_end and
                    previous != null and previous.? == '}' and next != null and
                    (next.? == ',' or next.? == ']');
                if (!is_array_item_extra) return null;
                try remove_indices.append(allocator, i);
                // 忽略这个 closer，不改变 stack；后续数组元素仍按原结构继续校验。
            },
            else => {},
        }
    }
    if (remove_indices.items.len == 0) return null;

    const out = try allocator.alloc(u8, s.len - remove_indices.items.len);
    var source_index: usize = 0;
    var output_index: usize = 0;
    var remove_index: usize = 0;
    while (source_index < s.len) : (source_index += 1) {
        if (remove_index < remove_indices.items.len and remove_indices.items[remove_index] == source_index) {
            remove_index += 1;
            continue;
        }
        out[output_index] = s[source_index];
        output_index += 1;
    }
    return out;
}

fn previousNonWhitespace(s: []const u8, before: usize) ?u8 {
    var index = before;
    while (index > 0) {
        index -= 1;
        if (!std.ascii.isWhitespace(s[index])) return s[index];
    }
    return null;
}

fn nextNonWhitespace(s: []const u8, from: usize) ?u8 {
    var index = from;
    while (index < s.len) : (index += 1) {
        if (!std.ascii.isWhitespace(s[index])) return s[index];
    }
    return null;
}

/// 删除字符串外恰好一个与 delimiter stack 顶不匹配的闭括号。返回 null 表示没有
/// 错位闭括号或存在多个错位点；caller 只会在结果整体通过 JSON parser 时采用它。
fn removeSingleMismatchedCloser(allocator: std.mem.Allocator, s: []const u8) !?[]u8 {
    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(allocator);

    var mismatch_index: ?usize = null;
    var in_str = false;
    var escaped = false;
    for (s, 0..) |c, i| {
        if (in_str) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{' => try expected.append(allocator, '}'),
            '[' => try expected.append(allocator, ']'),
            '}', ']' => {
                if (expected.items.len > 0 and expected.items[expected.items.len - 1] == c) {
                    _ = expected.pop();
                } else {
                    if (mismatch_index != null) return null;
                    mismatch_index = i;
                }
            },
            else => {},
        }
    }
    const remove_at = mismatch_index orelse return null;
    const out = try allocator.alloc(u8, s.len - 1);
    @memcpy(out[0..remove_at], s[0..remove_at]);
    @memcpy(out[remove_at..], s[remove_at + 1 ..]);
    return out;
}

/// 抽取字符串里第一个**完整**的 JSON value(object 或 array)——从首个 `{`/`[` 到其配平的
/// 闭合括号(depth 归零)。返回借用 slice;无起始符或 depth 未归零(截断)→ null。跳过字符串内括号。
fn extractFirstJsonValue(s: []const u8) ?[]const u8 {
    const start = stripLeadingNoiseIdx(s) orelse return null;
    var depth: i32 = 0;
    var in_str = false;
    var esc = false;
    var i = start;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{', '[' => depth += 1,
            '}', ']' => {
                depth -= 1;
                if (depth == 0) return s[start .. i + 1];
            },
            else => {},
        }
    }
    return null; // depth 未归零 = 截断,交给 balanceBrackets。
}

/// 首个 `{`/`[` 的下标;无则 null。
fn stripLeadingNoiseIdx(s: []const u8) ?usize {
    const brace = std.mem.indexOfScalar(u8, s, '{');
    const bracket = std.mem.indexOfScalar(u8, s, '[');
    if (brace == null and bracket == null) return null;
    if (brace == null) return bracket;
    if (bracket == null) return brace;
    return @min(brace.?, bracket.?);
}

/// 剥 markdown 代码围栏。仅当整体被 ``` 包裹时剥;否则原样返回。
fn stripCodeFence(s: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, s, "```")) return s;
    // 跳过首行(```  或 ```json 等),到第一个换行后。
    const first_nl = std.mem.indexOfScalar(u8, s, '\n') orelse return s;
    var body = s[first_nl + 1 ..];
    // 剥尾部 ```(可能带尾随空白/换行)。
    const trimmed = std.mem.trimEnd(u8, body, " \t\r\n");
    if (std.mem.endsWith(u8, trimmed, "```")) {
        body = trimmed[0 .. trimmed.len - 3];
    }
    return body;
}

/// 剥首个 `{`/`[` 之前的噪声。若没有结构起始符,原样返回(交给后续兜底)。
fn stripLeadingNoise(s: []const u8) []const u8 {
    return if (stripLeadingNoiseIdx(s)) |i| s[i..] else s;
}

/// 删 trailing comma:字符串外的 `,` 若其后(跳空白)紧跟 `}`/`]` 则删。返回 owned。
fn removeTrailingCommas(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var in_str = false;
    var esc = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_str) {
            try out.append(allocator, c);
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        if (c == '"') {
            in_str = true;
            try out.append(allocator, c);
            continue;
        }
        if (c == ',') {
            // 前瞻:跳过空白后是否 }/]。
            var j = i + 1;
            while (j < s.len and (s[j] == ' ' or s[j] == '\t' or s[j] == '\r' or s[j] == '\n')) : (j += 1) {}
            if (j < s.len and (s[j] == '}' or s[j] == ']')) {
                continue; // 丢弃这个逗号
            }
        }
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

/// 按 stack 顺序补缺失的闭合括号(跳过字符串内的括号)。返回 owned。
fn balanceBrackets(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var stack = std.ArrayList(u8).empty;
    defer stack.deinit(allocator);
    var in_str = false;
    var esc = false;
    for (s) |c| {
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{' => try stack.append(allocator, '}'),
            '[' => try stack.append(allocator, ']'),
            '}', ']' => {
                if (stack.items.len > 0) _ = stack.pop();
            },
            else => {},
        }
    }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, s);
    // 逆序补(stack 顶是最内层,最先闭合)。
    var k: usize = stack.items.len;
    while (k > 0) : (k -= 1) {
        try out.append(allocator, stack.items[k - 1]);
    }
    return out.toOwnedSlice(allocator);
}

// ============================================================================
// 2/3. 消息序列规范化(孤儿剥离 + 补桩 + 角色合并)
// ============================================================================

/// 无结果 tool_use 的占位结果内容(static;借用语义永不 free)。
const MISSING_RESULT_STUB = "[tool_use had no result — omitted to keep the conversation valid]";

/// 发请求前对 ApiMessage 序列跑一遍规范化:剥孤儿 tool_result → 补缺失 tool_result → 合并连续
/// 同角色。就地改写 list(维持 content 数组 owned、block 借用的内存契约)。幂等:已规范的序列不变。
pub fn normalizeApiMessages(allocator: std.mem.Allocator, list: *std.ArrayList(types.ApiMessage)) !void {
    try stripOrphanToolResults(allocator, list);
    try stubMissingToolResults(allocator, list);
    try mergeConsecutiveRoles(allocator, list);
}

/// 剥离孤儿 tool_result block:**顺序配对**——一个 tool_result 只能答复最近一条 assistant
/// 消息里的 tool_use(Anthropic/OpenAI 协议都要求结果紧随其调用轮)。不能用全局 id 集合:
/// OpenAI 兼容端常复用 call_0/call_1 这类短 id,全局集合会让后一轮的同名调用"复活"早已
/// 成为孤儿的旧结果,把它排到新调用之前 → provider 拒绝或结果错配。整条消息 block 全被剥
/// 则删除该消息。
fn stripOrphanToolResults(allocator: std.mem.Allocator, list: *std.ArrayList(types.ApiMessage)) !void {
    // 最近一条 assistant 消息的 tool_use id;遇到下一条 assistant 消息即重置。
    var outstanding = std.StringHashMap(void).init(allocator);
    defer outstanding.deinit();

    var i: usize = 0;
    while (i < list.items.len) {
        const m = list.items[i];
        if (m.role == .assistant) {
            outstanding.clearRetainingCapacity();
            for (m.content) |c| switch (c) {
                .tool_use => |tu| try outstanding.put(tu.id, {}),
                else => {},
            };
            i += 1;
            continue;
        }
        // 该消息里哪些 tool_result 合法?id 在本轮未决集合里的首个答复**消费**该 id;
        // 同一 id 的第二个答复和无对应调用的答复都是孤儿(一个调用只能有一个结果)。
        const keep_flags = try allocator.alloc(bool, m.content.len);
        defer allocator.free(keep_flags);
        var orphan: usize = 0;
        for (m.content, 0..) |c, k| {
            keep_flags[k] = switch (c) {
                .tool_result => |tr| outstanding.remove(tr.tool_use_id),
                else => true,
            };
            if (!keep_flags[k]) orphan += 1;
        }
        if (orphan == 0) {
            i += 1;
            continue;
        }
        // 重建不含孤儿的 content 数组。
        const keep = m.content.len - orphan;
        log.debug("repair", "stripped {d} orphan tool_result block(s)", .{orphan});
        if (keep == 0) {
            // 整条消息作废。
            allocator.free(m.content);
            _ = list.orderedRemove(i);
            continue; // 不 i+=1:后移一位补上
        }
        const new_content = try allocator.alloc(types.ApiContent, keep);
        var idx: usize = 0;
        for (m.content, 0..) |c, k| {
            if (!keep_flags[k]) continue;
            new_content[idx] = c;
            idx += 1;
        }
        allocator.free(m.content);
        list.items[i].content = new_content;
        i += 1;
    }
}

/// 给无对应 tool_result 的 tool_use 补一条占位结果。Anthropic/OpenAI 都要求每个 tool_use 有答复。
/// 与剥孤儿同一口径**按轮配对**:只有紧跟在该 assistant 消息之后、下一条 assistant 之前的
/// tool_result 才算答复;后一轮复用同一 id 的结果不算(否则新调用会因"已有同名结果"漏补桩)。
/// 补桩策略:在含该 tool_use 的 assistant 消息**紧后**插入一条 user 消息,内含所有缺失结果的 stub。
fn stubMissingToolResults(allocator: std.mem.Allocator, list: *std.ArrayList(types.ApiMessage)) !void {
    var i: usize = 0;
    while (i < list.items.len) : (i += 1) {
        const m = list.items[i];
        if (m.role != .assistant) continue;
        // 本轮已答复的 id:下一条 assistant 消息之前的所有 tool_result。
        var answered = std.StringHashMap(void).init(allocator);
        defer answered.deinit();
        var j = i + 1;
        while (j < list.items.len and list.items[j].role != .assistant) : (j += 1) {
            for (list.items[j].content) |c| switch (c) {
                .tool_result => |tr| try answered.put(tr.tool_use_id, {}),
                else => {},
            };
        }
        // 该 assistant 消息里有哪些 tool_use 缺结果?
        var missing = std.ArrayList([]const u8).empty;
        defer missing.deinit(allocator);
        for (m.content) |c| switch (c) {
            .tool_use => |tu| {
                if (!answered.contains(tu.id)) try missing.append(allocator, tu.id);
            },
            else => {},
        };
        if (missing.items.len == 0) continue;

        const stub_content = try allocator.alloc(types.ApiContent, missing.items.len);
        for (missing.items, 0..) |id, k| {
            stub_content[k] = .{ .tool_result = .{ .tool_use_id = id, .content = MISSING_RESULT_STUB, .is_error = true } };
        }
        try list.insert(allocator, i + 1, .{ .role = .user, .content = stub_content });
        log.debug("repair", "stubbed {d} missing tool_result(s)", .{missing.items.len});
        // 跳过刚插入的桩消息。
        i += 1;
    }
}

/// 某消息是否含指定类别的 block。
fn hasText(m: types.ApiMessage) bool {
    for (m.content) |c| if (c == .text) return true;
    return false;
}
fn hasToolResult(m: types.ApiMessage) bool {
    for (m.content) |c| if (c == .tool_result) return true;
    return false;
}
fn hasImage(m: types.ApiMessage) bool {
    for (m.content) |c| if (c == .image) return true;
    return false;
}

/// 合并相邻同角色消息:新 content = 两者拼接。就地改写(旧数组 free,新数组 owned)。
/// **provider 安全**:OpenAI/Gemini 的序列化把含 tool_result 的消息当 wire 层 `role:"tool"`/
/// functionResponse,且遇 tool_result 消息**早返回丢弃同消息内 text/image**。故绝不合并出
/// "text/image + tool_result 混合"消息——若合并后会同时含用户可见内容(text 或 image)与
/// tool_result 则跳过。text+text(inject+首 user)、text+image(上下文注入+多模态 user)
/// 和 tool_result+tool_result(补桩+真结果)都安全,照合。
fn mergeConsecutiveRoles(allocator: std.mem.Allocator, list: *std.ArrayList(types.ApiMessage)) !void {
    var i: usize = 0;
    while (i + 1 < list.items.len) {
        const a = list.items[i];
        const b = list.items[i + 1];
        if (a.role != b.role) {
            i += 1;
            continue;
        }
        // 合并后是否会 text/image 与 tool_result 混合?会则跳过(防序列化丢用户内容)。
        const combined_has_text = hasText(a) or hasText(b) or hasImage(a) or hasImage(b);
        const combined_has_tr = hasToolResult(a) or hasToolResult(b);
        if (combined_has_text and combined_has_tr) {
            i += 1;
            continue;
        }
        const merged = try allocator.alloc(types.ApiContent, a.content.len + b.content.len);
        @memcpy(merged[0..a.content.len], a.content);
        @memcpy(merged[a.content.len..], b.content);
        allocator.free(a.content);
        allocator.free(b.content);
        list.items[i].content = merged;
        _ = list.orderedRemove(i + 1);
        log.debug("repair", "merged consecutive {s} messages", .{@tagName(a.role)});
        // 不 i+=1:合并后可能与再下一条又同角色,继续。
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "repairToolArgs: 已合法原样返回" {
    const r = try repairToolArgs(testing.allocator, "{\"a\":1}");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{\"a\":1}", r);
}

test "repairToolArgs: markdown 围栏剥离" {
    const r = try repairToolArgs(testing.allocator, "```json\n{\"a\":1}\n```");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{\"a\":1}", r);
}

test "repairToolArgs: 前置噪声文本剥离" {
    const r = try repairToolArgs(testing.allocator, "Here you go: {\"a\":1}");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{\"a\":1}", r);
}

test "repairToolArgs: trailing comma 删除" {
    const r = try repairToolArgs(testing.allocator, "{\"a\":1,\"b\":2,}");
    defer testing.allocator.free(r);
    try testing.expect(isValidJson(r));
    try testing.expect(std.mem.indexOf(u8, r, ",}") == null);
}

test "repairToolArgs: 缺失闭合括号补全" {
    const r = try repairToolArgs(testing.allocator, "{\"a\":{\"b\":1");
    defer testing.allocator.free(r);
    try testing.expect(isValidJson(r));
}

test "repairToolArgs: 空/None → {}" {
    for ([_][]const u8{ "", "  ", "None", "null" }) |input| {
        const r = try repairToolArgs(testing.allocator, input);
        defer testing.allocator.free(r);
        try testing.expectEqualStrings("{}", r);
    }
}

test "repairToolArgs: 完全无法 salvage 兜底 {}" {
    const r = try repairToolArgs(testing.allocator, "this is not json at all !!!");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{}", r);
}

test "repairToolArgs: 字符串内逗号/括号不被误伤" {
    const r = try repairToolArgs(testing.allocator, "{\"msg\":\"a,b}c\"}");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{\"msg\":\"a,b}c\"}", r);
}

test "repairToolArgs: 前缀合法 + 尾部 prose(弱模型高频)不丢数据" {
    // 完整合法对象后拖一段解释——必须救回对象,而非兜底 {}。
    const r = try repairToolArgs(testing.allocator, "{\"path\":\"a.txt\"} 这是我选它的理由...");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{\"path\":\"a.txt\"}", r);
}

test "repairToolArgs: 尾部逗号 + 截断(补括号后再删逗号)" {
    // `{"a":1,`(缺闭合 + trailing comma)→ 补 } → 再删逗号 → {"a":1}。
    const r = try repairToolArgs(testing.allocator, "{\"a\":1,");
    defer testing.allocator.free(r);
    try testing.expect(isValidJson(r));
    try testing.expect(std.mem.indexOf(u8, r, "1") != null); // 值没丢
    try testing.expect(std.mem.indexOf(u8, r, ",}") == null);
}

test "repairToolArgs: GLM nested array boundary extra closer preserves complete tool input" {
    const raw =
        "{\"lexical_plan\":{\"intent\":\"fact_lookup\",\"schema_version\":\"lexical-query-plan-v2\"," ++
        "\"stage\":\"semantic_expansion\",\"variant_index\":0,\"variants\":[" ++
        "{\"kind\":\"synonym\",\"text\":\"commencement\"}," ++
        "{\"kind\":\"synonym\",\"text\":\"graduation ceremony\"}," ++
        "{\"kind\":\"synonym\",\"text\":\"convocation\"}," ++
        "{\"kind\":\"synonym\",\"text\":\"degree ceremony\"}}]}," ++
        "\"query\":\"commencement\"}";
    const repaired = try repairToolArgs(testing.allocator, raw);
    defer testing.allocator.free(repaired);
    try testing.expect(isValidJson(repaired));
    try testing.expectEqualStrings(
        "{\"lexical_plan\":{\"intent\":\"fact_lookup\",\"schema_version\":\"lexical-query-plan-v2\"," ++
            "\"stage\":\"semantic_expansion\",\"variant_index\":0,\"variants\":[" ++
            "{\"kind\":\"synonym\",\"text\":\"commencement\"}," ++
            "{\"kind\":\"synonym\",\"text\":\"graduation ceremony\"}," ++
            "{\"kind\":\"synonym\",\"text\":\"convocation\"}," ++
            "{\"kind\":\"synonym\",\"text\":\"degree ceremony\"}]}," ++
            "\"query\":\"commencement\"}",
        repaired,
    );
}

test "repairToolArgs: GLM repeated array item extra closers preserve v3 batch" {
    const raw =
        "{\"lexical_plan\": {\"intent\": \"fact_lookup\", \"schema_version\": " ++
        "\"lexical-query-plan-v3\", \"stage\": \"seed\", \"variants\": [" ++
        "{\"kind\": \"exact\", \"text\": \"kitchen cleaning tips\"}}, " ++
        "{\"kind\": \"synonym\", \"text\": \"keeping kitchen clean\"}}, " ++
        "{\"kind\": \"paraphrase\", \"text\": \"kitchen mess organization\"}]}, " ++
        "\"query\": \"kitchen cleaning tips\"}";
    const repaired = try repairToolArgs(testing.allocator, raw);
    defer testing.allocator.free(repaired);
    try testing.expect(isValidJson(repaired));
    try testing.expectEqualStrings(
        "{\"lexical_plan\": {\"intent\": \"fact_lookup\", \"schema_version\": " ++
            "\"lexical-query-plan-v3\", \"stage\": \"seed\", \"variants\": [" ++
            "{\"kind\": \"exact\", \"text\": \"kitchen cleaning tips\"}, " ++
            "{\"kind\": \"synonym\", \"text\": \"keeping kitchen clean\"}, " ++
            "{\"kind\": \"paraphrase\", \"text\": \"kitchen mess organization\"}]}, " ++
            "\"query\": \"kitchen cleaning tips\"}",
        repaired,
    );
}

test "repairToolArgs: 前置+尾部双噪声(抽取中段完整 value)" {
    const r = try repairToolArgs(testing.allocator, "sure! {\"k\":\"v\"} done");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{\"k\":\"v\"}", r);
}

fn freeList(allocator: std.mem.Allocator, list: *std.ArrayList(types.ApiMessage)) void {
    for (list.items) |m| allocator.free(m.content);
    list.deinit(allocator);
}

test "normalizeApiMessages: 孤儿 tool_result 被剥离" {
    const a = testing.allocator;
    var list = std.ArrayList(types.ApiMessage).empty;
    defer freeList(a, &list);
    // user: 一条孤儿 tool_result(无对应 tool_use)+ 一条 text。
    const c1 = try a.alloc(types.ApiContent, 2);
    c1[0] = .{ .tool_result = .{ .tool_use_id = "ghost", .content = "x" } };
    c1[1] = .{ .text = "hello" };
    try list.append(a, .{ .role = .user, .content = c1 });

    try normalizeApiMessages(a, &list);
    // 孤儿被剥,text 保留 → 一条消息一个 block。
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqual(@as(usize, 1), list.items[0].content.len);
    try testing.expect(list.items[0].content[0] == .text);
}

test "normalizeApiMessages: 全孤儿消息被删除" {
    const a = testing.allocator;
    var list = std.ArrayList(types.ApiMessage).empty;
    defer freeList(a, &list);
    const c0 = try a.alloc(types.ApiContent, 1);
    c0[0] = .{ .text = "hi" };
    try list.append(a, .{ .role = .user, .content = c0 });
    const c1 = try a.alloc(types.ApiContent, 1);
    c1[0] = .{ .tool_result = .{ .tool_use_id = "ghost", .content = "x" } };
    try list.append(a, .{ .role = .user, .content = c1 });

    try normalizeApiMessages(a, &list);
    // 全孤儿的第二条被删(第一条 text 与之同 user 角色 → 但第二条已空删,不合并)。
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expect(list.items[0].content[0] == .text);
}

test "normalizeApiMessages: 缺失 tool_result 补桩" {
    const a = testing.allocator;
    var list = std.ArrayList(types.ApiMessage).empty;
    defer freeList(a, &list);
    // assistant: 一个 tool_use,无对应结果。
    const c0 = try a.alloc(types.ApiContent, 1);
    c0[0] = .{ .tool_use = .{ .id = "call_1", .name = "Read", .input = "{}" } };
    try list.append(a, .{ .role = .assistant, .content = c0 });

    try normalizeApiMessages(a, &list);
    // 紧后插入一条 user 桩,含 tool_use_id=call_1 的 tool_result。
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqual(types.MessageRole.user, list.items[1].role);
    try testing.expect(list.items[1].content[0] == .tool_result);
    try testing.expectEqualStrings("call_1", list.items[1].content[0].tool_result.tool_use_id);
}

test "normalizeApiMessages: 配对齐全时不补桩不剥离(幂等)" {
    const a = testing.allocator;
    var list = std.ArrayList(types.ApiMessage).empty;
    defer freeList(a, &list);
    const c0 = try a.alloc(types.ApiContent, 1);
    c0[0] = .{ .tool_use = .{ .id = "call_1", .name = "Read", .input = "{}" } };
    try list.append(a, .{ .role = .assistant, .content = c0 });
    const c1 = try a.alloc(types.ApiContent, 1);
    c1[0] = .{ .tool_result = .{ .tool_use_id = "call_1", .content = "ok" } };
    try list.append(a, .{ .role = .user, .content = c1 });

    try normalizeApiMessages(a, &list);
    try testing.expectEqual(@as(usize, 2), list.items.len);
}

test "normalizeApiMessages: 后轮复用同一 id 不能复活早已成为孤儿的旧结果(顺序配对)" {
    const a = testing.allocator;
    var list = std.ArrayList(types.ApiMessage).empty;
    defer freeList(a, &list);
    // 旧结果 call_0 的调用轮已被压缩掉;后面一轮 OpenAI 兼容端又发了 call_0。
    const c0 = try a.alloc(types.ApiContent, 1);
    c0[0] = .{ .tool_result = .{ .tool_use_id = "call_0", .content = "stale" } };
    try list.append(a, .{ .role = .user, .content = c0 });
    const c1 = try a.alloc(types.ApiContent, 1);
    c1[0] = .{ .tool_use = .{ .id = "call_0", .name = "Read", .input = "{}" } };
    try list.append(a, .{ .role = .assistant, .content = c1 });
    const c2 = try a.alloc(types.ApiContent, 1);
    c2[0] = .{ .tool_result = .{ .tool_use_id = "call_0", .content = "fresh" } };
    try list.append(a, .{ .role = .user, .content = c2 });

    try normalizeApiMessages(a, &list);
    // 全局 id 集合会保留 stale(排在调用之前 → provider 拒绝);顺序配对把它剥掉。
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqual(types.MessageRole.assistant, list.items[0].role);
    try testing.expectEqualStrings("fresh", list.items[1].content[0].tool_result.content);
}

test "normalizeApiMessages: 同一调用的第二个答复是孤儿(id 被首个答复消费)" {
    const a = testing.allocator;
    var list = std.ArrayList(types.ApiMessage).empty;
    defer freeList(a, &list);
    const c0 = try a.alloc(types.ApiContent, 1);
    c0[0] = .{ .tool_use = .{ .id = "x", .name = "Read", .input = "{}" } };
    try list.append(a, .{ .role = .assistant, .content = c0 });
    const c1 = try a.alloc(types.ApiContent, 2);
    c1[0] = .{ .tool_result = .{ .tool_use_id = "x", .content = "first" } };
    c1[1] = .{ .tool_result = .{ .tool_use_id = "x", .content = "duplicate" } };
    try list.append(a, .{ .role = .user, .content = c1 });

    try normalizeApiMessages(a, &list);
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqual(@as(usize, 1), list.items[1].content.len);
    try testing.expectEqualStrings("first", list.items[1].content[0].tool_result.content);
}

test "normalizeApiMessages: 补桩按轮判定,后轮同 id 的结果不算前轮的答复" {
    const a = testing.allocator;
    var list = std.ArrayList(types.ApiMessage).empty;
    defer freeList(a, &list);
    const c0 = try a.alloc(types.ApiContent, 1);
    c0[0] = .{ .tool_use = .{ .id = "call_0", .name = "Read", .input = "{}" } };
    try list.append(a, .{ .role = .assistant, .content = c0 });
    const c1 = try a.alloc(types.ApiContent, 1);
    c1[0] = .{ .tool_use = .{ .id = "call_0", .name = "Grep", .input = "{}" } };
    try list.append(a, .{ .role = .assistant, .content = c1 });
    const c2 = try a.alloc(types.ApiContent, 1);
    c2[0] = .{ .tool_result = .{ .tool_use_id = "call_0", .content = "grep result" } };
    try list.append(a, .{ .role = .user, .content = c2 });

    try normalizeApiMessages(a, &list);
    // 第一轮的 call_0 没有答复 → 紧后补桩;第二轮的真结果原样保留。
    try testing.expectEqual(@as(usize, 4), list.items.len);
    try testing.expectEqual(types.MessageRole.user, list.items[1].role);
    try testing.expectEqualStrings(MISSING_RESULT_STUB, list.items[1].content[0].tool_result.content);
    try testing.expectEqualStrings("grep result", list.items[3].content[0].tool_result.content);
}

test "normalizeApiMessages: 连续 user 合并" {
    const a = testing.allocator;
    var list = std.ArrayList(types.ApiMessage).empty;
    defer freeList(a, &list);
    const c0 = try a.alloc(types.ApiContent, 1);
    c0[0] = .{ .text = "context" };
    try list.append(a, .{ .role = .user, .content = c0 });
    const c1 = try a.alloc(types.ApiContent, 1);
    c1[0] = .{ .text = "question" };
    try list.append(a, .{ .role = .user, .content = c1 });

    try normalizeApiMessages(a, &list);
    // 两条 user 合并成一条,两个 text block。
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqual(@as(usize, 2), list.items[0].content.len);
}

test "normalizeApiMessages: 正常交替不被合并" {
    const a = testing.allocator;
    var list = std.ArrayList(types.ApiMessage).empty;
    defer freeList(a, &list);
    for ([_]types.MessageRole{ .user, .assistant, .user }) |role| {
        const c = try a.alloc(types.ApiContent, 1);
        c[0] = .{ .text = "x" };
        try list.append(a, .{ .role = role, .content = c });
    }
    try normalizeApiMessages(a, &list);
    try testing.expectEqual(@as(usize, 3), list.items.len);
}

test "mergeConsecutiveRoles: 不合并出 text+tool_result 混合(provider 安全)" {
    const a = testing.allocator;
    var list = std.ArrayList(types.ApiMessage).empty;
    defer freeList(a, &list);
    // assistant tool_use → user tool_result → user text。后两条同 user 但合并会混 tool_result+text,
    // OpenAI/Gemini 序列化会丢 text → 必须**不合并**。
    const c0 = try a.alloc(types.ApiContent, 1);
    c0[0] = .{ .tool_use = .{ .id = "c1", .name = "Read", .input = "{}" } };
    try list.append(a, .{ .role = .assistant, .content = c0 });
    const c1 = try a.alloc(types.ApiContent, 1);
    c1[0] = .{ .tool_result = .{ .tool_use_id = "c1", .content = "ok" } };
    try list.append(a, .{ .role = .user, .content = c1 });
    const c2 = try a.alloc(types.ApiContent, 1);
    c2[0] = .{ .text = "next question" };
    try list.append(a, .{ .role = .user, .content = c2 });

    try normalizeApiMessages(a, &list);
    // 两条 user 未合并(3 条保持)——text 不被序列化吞掉。
    try testing.expectEqual(@as(usize, 3), list.items.len);
}

test "normalizeApiMessages: 幂等(跑两遍结果不变)" {
    const a = testing.allocator;
    var list = std.ArrayList(types.ApiMessage).empty;
    defer freeList(a, &list);
    // 一个需修复的序列:孤儿 + 连续 user。
    const c0 = try a.alloc(types.ApiContent, 2);
    c0[0] = .{ .text = "ctx" };
    c0[1] = .{ .tool_result = .{ .tool_use_id = "ghost", .content = "x" } };
    try list.append(a, .{ .role = .user, .content = c0 });
    const c1 = try a.alloc(types.ApiContent, 1);
    c1[0] = .{ .text = "q" };
    try list.append(a, .{ .role = .user, .content = c1 });

    try normalizeApiMessages(a, &list);
    const after_first = list.items.len;
    const first_blocks = list.items[0].content.len;
    // 再跑一遍:长度与首条 block 数不变(幂等)。
    try normalizeApiMessages(a, &list);
    try testing.expectEqual(after_first, list.items.len);
    try testing.expectEqual(first_blocks, list.items[0].content.len);
}

test "merge: text+image 的多模态 user 与 inject 上下文合并保图(顺序保持)" {
    const a = testing.allocator;
    var list = std.ArrayList(types.ApiMessage).empty;
    defer {
        for (list.items) |m| a.free(m.content);
        list.deinit(a);
    }
    const c0 = try a.alloc(types.ApiContent, 1);
    c0[0] = .{ .text = "context" };
    try list.append(a, .{ .role = .user, .content = c0 });
    const c1 = try a.alloc(types.ApiContent, 2);
    c1[0] = .{ .text = "看图" };
    c1[1] = .{ .image = .{ .media_type = "image/png", .data = "UE5H" } };
    try list.append(a, .{ .role = .user, .content = c1 });

    try normalizeApiMessages(a, &list);
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqual(@as(usize, 3), list.items[0].content.len);
    try testing.expect(list.items[0].content[2] == .image);
    try testing.expectEqualStrings("UE5H", list.items[0].content[2].image.data);
}

test "merge: image 消息不与 tool_result 消息合并(防序列化丢图)" {
    const a = testing.allocator;
    var list = std.ArrayList(types.ApiMessage).empty;
    defer {
        for (list.items) |m| a.free(m.content);
        list.deinit(a);
    }
    // assistant tool_use → user tool_result → user image:后两条同角色但不得合并。
    const c0 = try a.alloc(types.ApiContent, 1);
    c0[0] = .{ .tool_use = .{ .id = "t1", .name = "Read", .input = "{}" } };
    try list.append(a, .{ .role = .assistant, .content = c0 });
    const c1 = try a.alloc(types.ApiContent, 1);
    c1[0] = .{ .tool_result = .{ .tool_use_id = "t1", .content = "ok" } };
    try list.append(a, .{ .role = .user, .content = c1 });
    const c2 = try a.alloc(types.ApiContent, 1);
    c2[0] = .{ .image = .{ .media_type = "image/png", .data = "UE5H" } };
    try list.append(a, .{ .role = .user, .content = c2 });

    try normalizeApiMessages(a, &list);
    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expect(list.items[1].content[0] == .tool_result);
    try testing.expect(list.items[2].content[0] == .image);
}
