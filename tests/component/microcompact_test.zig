//! L2 组件测试:microcompact 工具结果清理(批4,对齐 cc 工具结果清理)。
//!
//! 验证:老消息(boundary 外)的 tool_result content 被替换成 stub;最近 keep_recent_n
//! 条不动;text/tool_use block 不受影响;幂等(重复清不重复算)。

const std = @import("std");
const cc = @import("cc");

const Conversation = cc.conversation.Conversation;
const msg = cc.core_message;

fn appendToolResult(conv: *Conversation, a: std.mem.Allocator, id: []const u8, content: []const u8) !void {
    const blocks = try a.alloc(msg.Block, 1);
    blocks[0] = .{ .tool_result = .{
        .tool_use_id = try a.dupe(u8, id),
        .content = try a.dupe(u8, content),
        .is_error = false,
    } };
    try conv.append(.{ .role = .user, .blocks = blocks });
}

test "L2 microcompact: 老 tool_result 被清成 stub,最近的不动" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();

    // 6 条消息:0..3 是老的(各带一个大 tool_result),4..5 是最近的
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        var buf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&buf, "tu{d}", .{i});
        try appendToolResult(&conv, a, id, "AAAAAAAAAA_big_tool_output_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    }

    // keep_recent_n=2 → boundary=4,清 [0,4) 的 tool_result
    const cleared = conv.microcompactToolResults(2);
    try std.testing.expectEqual(@as(usize, 4), cleared);

    // 老的(0..3)被清
    for (conv.messages.items[0..4]) |m| {
        const content = m.blocks[0].tool_result.content;
        try std.testing.expect(cc.conversation.isCommittedToolResultProjection(content));
        try std.testing.expect(std.mem.indexOf(u8, content, "original_bytes=") != null);
        try std.testing.expect(std.mem.indexOf(u8, content, "sha256=") != null);
    }
    // 最近的(4,5)不动
    for (conv.messages.items[4..6]) |m| {
        try std.testing.expect(std.mem.indexOf(u8, m.blocks[0].tool_result.content, "big_tool_output") != null);
    }
}

test "L2 microcompact: 幂等(重复清,第二次 0)" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try appendToolResult(&conv, a, "x", "some_tool_output_data_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    }
    const c1 = conv.microcompactToolResults(1); // 清 [0,4)
    try std.testing.expectEqual(@as(usize, 4), c1);
    const c2 = conv.microcompactToolResults(1); // 已 stub → 0
    try std.testing.expectEqual(@as(usize, 0), c2);
}

test "L2 microcompact: recoverable Bash channel artifact remains readable" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();
    const artifact_id = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const result =
        "{\"schema_version\":\"metacodes.bash-result.v2\",\"stdout\":\"head\\n...[middle omitted]...\\ntail\",\"stdout_artifact_id\":\"" ++ artifact_id ++
        "\",\"stdout_recoverable\":true,\"stderr_artifact_id\":null,\"stderr_recoverable\":true}";
    try appendToolResult(&conv, a, "bash", result);
    try conv.appendText(.assistant, "after bash");

    const cleared = conv.microcompactToolResultsByRecentResults(0);
    try std.testing.expectEqual(@as(usize, 0), cleared.cleared);
    const preserved = conv.messages.items[0].blocks[0].tool_result.content;
    try std.testing.expect(std.mem.indexOf(u8, preserved, artifact_id) != null);
}

test "L2 microcompact: 消息少于 keep_recent_n → 不清" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();
    try appendToolResult(&conv, a, "x", "data");
    try std.testing.expectEqual(@as(usize, 0), conv.microcompactToolResults(5));
}

test "L2 microcompact: text/tool_use block 不受影响" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();
    // 老消息是纯 text(无 tool_result)
    try conv.appendText(.user, "old question one");
    try conv.appendText(.assistant, "old answer one");
    try appendToolResult(&conv, a, "t", "tool_output_here_xxxxx_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    try conv.appendText(.user, "recent");

    const cleared = conv.microcompactToolResults(1); // boundary=3,清 [0,3)
    try std.testing.expectEqual(@as(usize, 1), cleared); // 只有 1 个 tool_result
    // text 消息不变
    try std.testing.expect(std.mem.indexOf(u8, conv.messages.items[0].blocks[0].text, "old question one") != null);
}

test "L2 microcompact: 按最近 tool_result 个数保留,不被消息边界误保护" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();

    try conv.appendText(.user, "old plain message");
    try appendToolResult(&conv, a, "tu1", "old_tool_result_1 with enough payload to shrink after clearing_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    try appendToolResult(&conv, a, "tu2", "old_tool_result_2 with enough payload to shrink after clearing_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
    try conv.appendText(.assistant, "recent assistant text");
    try appendToolResult(&conv, a, "tu3", "latest_tool_result");

    const reduced = conv.microcompactToolResultsByRecentResults(1);
    try std.testing.expectEqual(@as(usize, 2), reduced.cleared);
    try std.testing.expect(reduced.bytes_before > reduced.bytes_after);
    try std.testing.expect(cc.conversation.isCommittedToolResultProjection(conv.messages.items[1].blocks[0].tool_result.content));
    try std.testing.expect(cc.conversation.isCommittedToolResultProjection(conv.messages.items[2].blocks[0].tool_result.content));
    try std.testing.expect(std.mem.indexOf(u8, conv.messages.items[4].blocks[0].tool_result.content, "latest_tool_result") != null);
}

test "L2 microcompact: huge recent tool_result is truncated before full compact can repeat" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try conv.appendText(.user, "old context line that can be compacted later");
    }

    const limit = cc.conversation.toolResultContextBytes(200_000);
    const huge = try a.alloc(u8, limit * 3);
    defer a.free(huge);
    @memset(huge, 'A');
    huge[huge.len - 1] = 'Z';
    try appendToolResult(&conv, a, "huge", huge);

    const before = conv.totalTokens();
    const reduced = conv.truncateLargeToolResults(limit);
    try std.testing.expectEqual(@as(usize, 1), reduced.truncated);
    try std.testing.expect(reduced.bytes_before > reduced.bytes_after);
    try std.testing.expect(conv.totalTokens() < before);
    try std.testing.expect(conv.messages.items[8].blocks[0].tool_result.content.len <= limit);
    try std.testing.expect(std.mem.indexOf(u8, conv.messages.items[8].blocks[0].tool_result.content, "original_bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, conv.messages.items[8].blocks[0].tool_result.content, "Z") != null);

    _ = conv.compactKeepRecent(3);
    const after_first_compact = conv.totalTokens();
    _ = conv.compactKeepRecent(3);
    try std.testing.expectEqual(after_first_compact, conv.totalTokens());
}

test "L2 microcompact: truncated projection clears without losing original commitment" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();

    const huge = try a.alloc(u8, 64 * 1024);
    defer a.free(huge);
    @memset(huge, 'Q');
    try appendToolResult(&conv, a, "huge", huge);
    try conv.appendText(.assistant, "after tool");

    const truncated = conv.truncateLargeToolResults(8 * 1024);
    try std.testing.expectEqual(@as(usize, 1), truncated.truncated);
    const before = try a.dupe(u8, conv.messages.items[0].blocks[0].tool_result.content);
    defer a.free(before);
    const commitment_end = std.mem.indexOfScalar(u8, before, '\n') orelse return error.MissingCommitment;
    const commitment = before[0..commitment_end];

    const cleared = conv.microcompactToolResultsByRecentResults(0);
    try std.testing.expectEqual(@as(usize, 1), cleared.cleared);
    const after = conv.messages.items[0].blocks[0].tool_result.content;
    try std.testing.expect(after.len < before.len);
    try std.testing.expect(std.mem.indexOf(u8, after, commitment) != null);
}

test "L2 microcompact: truncated UTF-8 tool_result stays valid and second preflight is no-op" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();

    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(a);
    while (payload.items.len < cc.conversation.toolResultContextBytes(0) * 3) {
        try payload.appendSlice(a, "中文🙂");
    }
    try appendToolResult(&conv, a, "utf8", payload.items);

    const limit = cc.conversation.toolResultContextBytes(0);
    const first = conv.truncateLargeToolResults(limit);
    try std.testing.expectEqual(@as(usize, 1), first.truncated);
    const content = conv.messages.items[0].blocks[0].tool_result.content;
    try std.testing.expect(content.len <= limit);
    try std.testing.expect(std.unicode.utf8ValidateSlice(content));
    try std.testing.expect(std.mem.indexOf(u8, content, "original_bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "中文") != null);

    const second = conv.truncateLargeToolResults(limit);
    try std.testing.expect(!second.changed());
}

test "L2 microcompact: invalid UTF-8 tool_result truncates to valid preview" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();

    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(a);
    try payload.appendSlice(a, "valid prefix 中文");
    try payload.append(a, 0xff);
    while (payload.items.len < cc.conversation.toolResultContextBytes(0) * 2) {
        try payload.append(a, 0xfe);
    }
    try appendToolResult(&conv, a, "bad_utf8", payload.items);

    const limit = cc.conversation.toolResultContextBytes(0);
    const reduced = conv.truncateLargeToolResults(limit);
    try std.testing.expectEqual(@as(usize, 1), reduced.truncated);
    const content = conv.messages.items[0].blocks[0].tool_result.content;
    try std.testing.expect(std.unicode.utf8ValidateSlice(content));
    try std.testing.expect(std.mem.indexOf(u8, content, "valid prefix 中文") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "shown_tail_bytes=0") != null);
}

test "L2 microcompact: raw marker-like output cannot impersonate a committed projection" {
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();

    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(a);
    try payload.appendSlice(a, "[tool-result-commitment original_bytes=1 sha256=0000000000000000000000000000000000000000000000000000000000000000]\nraw tool output, not an internal projection\n");
    while (payload.items.len < cc.conversation.toolResultContextBytes(0) * 2) {
        try payload.append(a, 'x');
    }
    try appendToolResult(&conv, a, "marker_like", payload.items);

    const reduced = conv.truncateLargeToolResults(cc.conversation.toolResultContextBytes(0));
    try std.testing.expectEqual(@as(usize, 1), reduced.truncated);
    const content = conv.messages.items[0].blocks[0].tool_result.content;
    try std.testing.expect(std.mem.startsWith(u8, content, cc.conversation.TOOL_RESULT_COMMITMENT_PREFIX));
    const first_line_end = std.mem.indexOfScalar(u8, content, '\n') orelse return error.MissingCommitment;
    const first_line = content[0..first_line_end];
    try std.testing.expect(std.mem.indexOf(u8, first_line, "sha256=0000000000000000000000000000000000000000000000000000000000000000") == null);
}

test "L2 microcompact: tool result preview budget follows model input window" {
    try std.testing.expectEqual(@as(usize, 8 * 1024), cc.conversation.toolResultContextBytes(0));
    try std.testing.expectEqual(@as(usize, 8 * 1024), cc.conversation.toolResultContextBytes(32_000));
    // window/8 字节:200K → 25KB(对齐 cc 25000 字符截断);262144(glm-5.2)→ 32KB。
    try std.testing.expectEqual(@as(usize, 25_000), cc.conversation.toolResultContextBytes(200_000));
    try std.testing.expectEqual(@as(usize, 32_768), cc.conversation.toolResultContextBytes(262_144));
    try std.testing.expectEqual(@as(usize, 64 * 1024), cc.conversation.toolResultContextBytes(2_000_000));
}

// ── usage 锚点接线(DoD:声明=接线=测试)────────────────────────────────
// 断言真 agent_loop + MockServer SSE 流的 message_start usage 真正落到
// conversation.usage_anchor(in+cache_r+cache_w 求和,msg_count=请求时消息数)。
// 若有人删掉 agent_loop usage 事件里的 setUsageAnchor 调用,此测试红。

const harness = @import("harness");

const USAGE_ANCHOR_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":100,\"cache_read_input_tokens\":2000,\"cache_creation_input_tokens\":345,\"output_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "L2 usage 锚点接线: message_start usage → conversation.usageAnchor(in+cache_r+cache_w)" {
    const a = std.testing.allocator;
    const bodies = [_][]const u8{USAGE_ANCHOR_SSE};
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var conv = Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");

    const perm = cc.permission.createContext(.bypass_permissions, a);
    var wb = cc.writer_backend.WriterBackend.initNull();
    const be = wb.backend();
    const result = cc.agent_loop.run(&conv, client.provider(), &.{}, &perm, .{ .max_turns = 2 }, &be, a) catch |e| {
        std.debug.print("agent_loop.run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);

    const anchor = conv.usageAnchor() orelse return error.TestExpectedAnchor;
    // 100 + 2000 + 345:三段求和 = 服务端实计完整 prompt(Anthropic-exclusive 语义)。
    try std.testing.expectEqual(@as(usize, 2445), anchor.context_tokens);
    // usage 到达时 assistant 消息尚未 append → 锚点只覆盖请求时的 1 条消息。
    try std.testing.expectEqual(@as(usize, 1), anchor.msg_count);
}

test "L2 microcompact: 生产组合(先清后截)——clear 保留的最近大结果由 truncate 兜底" {
    // 回归守卫:`truncateLargeToolResults` 曾经零生产调用者,而
    // `agent_loop` 的 microcompact 日志行一直打印 `truncated={d}`——那个字段
    // 结构性恒为 0。本测试复刻生产里两趟的组合顺序与预算,证明 clear 故意
    // 保留的最近结果确实会被 truncate 兜住。
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();

    const limit = cc.conversation.toolResultContextBytes(200_000);

    // 两条老结果(会被清成 stub)。
    try appendToolResult(&conv, a, "old0", "old tool output 0 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    try appendToolResult(&conv, a, "old1", "old tool output 1 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");

    // 最近两条:clear 按 keep_recent=2 全部保留。其中一条远超单条预算——
    // 这正是 projection 管不到的形态(/resume 的历史、或切到更小窗口的模型)。
    try appendToolResult(&conv, a, "recent_small", "recent small tool output");
    const huge = try a.alloc(u8, limit * 2);
    defer a.free(huge);
    @memset(huge, 'A');
    huge[huge.len - 1] = 'Z';
    try appendToolResult(&conv, a, "recent_huge", huge);

    // 与 agent_loop.runAutoCompactIfNeeded 完全同序、同预算。
    var reduced = conv.microcompactToolResultsByRecentResults(
        cc.conversation.DEFAULT_RECENT_TOOL_RESULTS_TO_KEEP,
    );
    reduced.merge(conv.truncateLargeToolResults(limit));

    try std.testing.expectEqual(@as(usize, 2), reduced.cleared);
    try std.testing.expectEqual(@as(usize, 1), reduced.truncated);
    try std.testing.expect(reduced.bytes_before > reduced.bytes_after);

    // 老的两条被清成 stub。
    try std.testing.expect(cc.conversation.isCommittedToolResultProjection(conv.messages.items[0].blocks[0].tool_result.content));
    try std.testing.expect(cc.conversation.isCommittedToolResultProjection(conv.messages.items[1].blocks[0].tool_result.content));
    // 最近的小结果原样保留:truncate 不该动它。
    try std.testing.expectEqualStrings("recent small tool output", conv.messages.items[2].blocks[0].tool_result.content);
    // 最近的大结果被 clear 保留、被 truncate 兜住:有界、留 sha256 承诺、保尾部。
    const bounded = conv.messages.items[3].blocks[0].tool_result.content;
    try std.testing.expect(bounded.len <= limit);
    try std.testing.expect(std.mem.indexOf(u8, bounded, "original_bytes=") != null);
    try std.testing.expect(std.mem.indexOf(u8, bounded, "sha256=") != null);
    try std.testing.expect(std.mem.endsWith(u8, bounded, "Z"));

    // 幂等:再跑一遍两趟都不该有新动作。
    var again = conv.microcompactToolResultsByRecentResults(
        cc.conversation.DEFAULT_RECENT_TOOL_RESULTS_TO_KEEP,
    );
    again.merge(conv.truncateLargeToolResults(limit));
    try std.testing.expect(!again.changed());
}

test "L2 microcompact: 两趟压力阀不得毁掉唯一的恢复能力" {
    // `clearToolResultAt` 明确拒绝清掉带 recoverable artifact 的结果(那是被省略
    // 字节的唯一取回途径)。本 PR 把 `truncateLargeToolResults` 接进同两个压力阀,
    // 而它原来只跳过已清/已截的 stub——于是 clear 特意保下来的信封,紧接着就被
    // 通用头尾截断切成不可解析的 JSON:artifact_id / sha256 / read 指令一起没了,
    // 且下一轮 clear 因为再也看不到 recoverable artifact,会把残骸清成 stub。
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();
    const limit = cc.conversation.toolResultContextBytes(200_000);

    // 超预算的可恢复信封:切到更小窗口的模型 / /resume 的历史就是这个形态。
    const id = "sha256:" ++ ("a" ** 64);
    const filler = try a.alloc(u8, limit * 2);
    defer a.free(filler);
    @memset(filler, 'P');
    filler[0] = 'H';
    filler[filler.len - 1] = 'T';
    const envelope = try std.fmt.allocPrint(
        a,
        "{{\"schema_version\":\"metacodes.tool-result-projection.v1\",\"projection\":\"artifact\"," ++
            "\"artifact_id\":\"{s}\",\"media_type\":\"text/plain; charset=utf-8\",\"original_bytes\":999999," ++
            "\"sha256\":\"{s}\",\"capture_complete\":true,\"recoverable\":true," ++
            "\"preview_encoding\":\"utf-8\",\"preview_head\":\"{s}\",\"preview_tail\":\"TAILMARK\"," ++
            "\"preview_head_bytes\":{d},\"preview_tail_bytes\":8,\"omitted_bytes\":1," ++
            "\"read\":{{\"tool\":\"ReadArtifact\",\"offset\":0,\"limit_max\":32768}}}}",
        .{ id, "b" ** 64, filler, filler.len },
    );
    defer a.free(envelope);
    try appendToolResult(&conv, a, "tu_env", envelope);

    // 生产同序:先 clear(keep_recent=2 → 两条都保),再 truncate。
    var reduced = conv.microcompactToolResultsByRecentResults(
        cc.conversation.DEFAULT_RECENT_TOOL_RESULTS_TO_KEEP,
    );
    reduced.merge(conv.truncateLargeToolResults(limit));
    try std.testing.expectEqual(@as(usize, 1), reduced.truncated);

    const bounded = conv.messages.items[0].blocks[0].tool_result.content;
    // 有界了,而且仍然是合法 JSON、仍然可恢复、身份字段一个不少。
    try std.testing.expect(bounded.len <= limit);
    try std.testing.expect(bounded.len < envelope.len);
    try std.testing.expect(cc.result_projection.hasRecoverableArtifact(bounded));
    var parsed = try std.json.parseFromSlice(std.json.Value, a, bounded, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(id, parsed.value.object.get("artifact_id").?.string);
    try std.testing.expectEqualStrings("b" ** 64, parsed.value.object.get("sha256").?.string);
    try std.testing.expect(parsed.value.object.get("recoverable").?.bool);
    try std.testing.expectEqual(@as(i64, 999999), parsed.value.object.get("original_bytes").?.integer);
    try std.testing.expect(parsed.value.object.get("read").? == .object);
    // 预览还是真预览:头尾都在,记账数字跟着重算而不是留旧值。
    try std.testing.expect(std.mem.startsWith(u8, parsed.value.object.get("preview_head").?.string, "H"));
    try std.testing.expectEqualStrings("TAILMARK", parsed.value.object.get("preview_tail").?.string);
    try std.testing.expect(parsed.value.object.get("preview_head_bytes").?.integer < @as(i64, @intCast(filler.len)));
    try std.testing.expect(parsed.value.object.get("omitted_bytes").?.integer > 1);

    // 且下一轮 clear 仍然看得见恢复能力,不会把它清成 stub。
    const again = conv.microcompactToolResultsByRecentResults(0);
    try std.testing.expectEqual(@as(usize, 0), again.cleared);
}

test "L2 microcompact: 无法重写的可恢复信封宁可留着也不切坏" {
    // Bash v2 信封没有 shrink 路径。留着超预算只多花一次请求;切坏则同时毁掉
    // stdout_artifact_id 与 stdout_path,输出就真没了。
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();
    const limit = cc.conversation.toolResultContextBytes(200_000);

    const filler = try a.alloc(u8, limit * 2);
    defer a.free(filler);
    @memset(filler, 'B');
    const bash = try std.fmt.allocPrint(
        a,
        "{{\"schema_version\":\"metacodes.bash-result.v2\",\"stdout\":\"{s}\"," ++
            "\"stdout_artifact_id\":\"sha256:{s}\",\"stdout_recoverable\":true,\"exit_code\":0}}",
        .{ filler, "c" ** 64 },
    );
    defer a.free(bash);
    try appendToolResult(&conv, a, "tu_bash", bash);

    const reduced = conv.truncateLargeToolResults(limit);
    try std.testing.expectEqual(@as(usize, 0), reduced.truncated);
    const kept = conv.messages.items[0].blocks[0].tool_result.content;
    try std.testing.expectEqualStrings(bash, kept);
    try std.testing.expect(cc.result_projection.hasRecoverableArtifact(kept));
}

test "L2 microcompact: 大到发布不了的 Bash 捕获,靠 spool 路径免于被清空" {
    // 已完成的 Bash 信封给出 `<channel>_path`,理由正是"捕获超过 MAX_ARTIFACT_BYTES
    // 无法发布时唯一剩下的句柄"。可 clear 判定原本只看 artifact 字段,于是这条
    // 结果在下一次上下文压力就被清成 stub——句柄只活了一轮,那份磁盘上完好的
    // 输出对模型等于没有。
    const a = std.testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();

    const unpublishable =
        "{\"schema_version\":\"metacodes.bash-result.v2\",\"stdout\":\"head...tail\"," ++
        "\"stdout_captured_bytes\":200000000,\"stdout_capture_complete\":false," ++
        "\"stdout_truncated\":true,\"stdout_artifact_id\":null,\"stdout_recoverable\":false," ++
        "\"stdout_path\":\"/tmp/metacodes-job-abc/stdout\"," ++
        "\"stdout_storage_error\":\"artifact_too_large\",\"exit_code\":0}";
    try appendToolResult(&conv, a, "tu_spool", unpublishable);

    // 一条模型已经完整看到的结果作对照:它没有要恢复的东西,该清就清。
    const whole =
        "{\"schema_version\":\"metacodes.bash-result.v2\",\"stdout\":\"all of it right here\"," ++
        "\"stdout_truncated\":false,\"stdout_artifact_id\":null,\"stdout_recoverable\":true," ++
        "\"stdout_path\":\"/tmp/metacodes-job-def/stdout\"," ++
        "\"stderr_truncated\":false,\"stderr_path\":\"/tmp/metacodes-job-def/stderr\",\"exit_code\":0}";
    try appendToolResult(&conv, a, "tu_whole", whole);

    const reduced = conv.microcompactToolResultsByRecentResults(0);
    try std.testing.expectEqual(@as(usize, 1), reduced.cleared);
    try std.testing.expectEqualStrings(unpublishable, conv.messages.items[0].blocks[0].tool_result.content);
    try std.testing.expect(cc.conversation.isCommittedToolResultProjection(
        conv.messages.items[1].blocks[0].tool_result.content,
    ));
}
