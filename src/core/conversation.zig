//! 对话历史管理。
//!
//! 与旧的 `App.messages: std.ArrayList(Message(role, content: []const u8))` 不同，
//! 这里 Message 持结构化 blocks，能正确表达 `.tool_use` / `.tool_result` content blocks。
//!
//! 所有权：`append` 消费传入的 Message（Message.blocks 的字节必须是 allocator 拥有）。
//! `deinit` 释放所有 blocks。不做 compact 的实现（留给未来 M6）。

const std = @import("std");
const sync = @import("platform").sync;
const types = @import("../types.zig");
const msg = @import("message.zig");
const result_projection = @import("result_projection.zig");
const json_mod = @import("../json.zig");

pub const TOOL_RESULT_CLEARED_STUB = "[tool result cleared to save context]";
pub const TOOL_RESULT_COMMITMENT_PREFIX = "[tool-result-commitment ";
pub const TOOL_RESULT_CONTEXT_MIN_BYTES: usize = 8 * 1024;
pub const TOOL_RESULT_CONTEXT_MAX_BYTES: usize = 64 * 1024;
/// window(token 数)/8 → 单条 tool_result 内联字节上限(≈ window/32 token,4 bytes/token)。
/// 200K 窗口 → 25KB,与 cc 的 25000 字符截断对齐;262K(glm-5.2)→ 32KB;1M → 64KB cap。
/// 旧值 /16 直接把 token 数当字节数用(200K → 12.5KB),单位错配导致截断过狠。
pub const TOOL_RESULT_CONTEXT_WINDOW_DIVISOR: usize = 8;

/// 单张输入图像的 token 估算上限;定义见 types.IMAGE_TOKEN_ESTIMATE(IR 层单一口径)。
pub const IMAGE_TOKEN_ESTIMATE: usize = types.IMAGE_TOKEN_ESTIMATE;

pub fn toolResultContextBytes(max_input_tokens: usize) usize {
    const derived = if (max_input_tokens == 0)
        TOOL_RESULT_CONTEXT_MIN_BYTES
    else
        max_input_tokens / TOOL_RESULT_CONTEXT_WINDOW_DIVISOR;
    return @min(@max(derived, TOOL_RESULT_CONTEXT_MIN_BYTES), TOOL_RESULT_CONTEXT_MAX_BYTES);
}
pub const DEFAULT_RECENT_TOOL_RESULTS_TO_KEEP: usize = 2;

pub const Conversation = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(msg.Message),
    /// P1.5 纯投影压缩:boundary 型压缩**不删除原始消息**。压缩=推进
    /// 这个 boundary 游标 + 存一条 compact_summary。发给模型 / token 估算都只看 [boundary..] + summary
    /// (见 activeStart/totalTokens/buildApiMessages)。对齐 cc 的 getMessagesAfterCompactBoundary。
    /// **持久化语义(R2/F1 后)**:transcript 是**活态镜像**——前缀破坏性变更(/retry 回卷、
    /// compact 的 replaceWithOwned)触发全量重写,resume == 当时的活对话。微压缩/截断把
    /// 已 flush 的 tool_result 原地改成 stub 后,一旦发生重写,盘上也定格为 stub(模型
    /// 视角的真实状态);不再承诺盘上永远保留 stub 化之前的完整原文。
    /// **一致性铁律**:任何"发给模型"的投影和"token 估算"的投影必须用同一 boundary+summary,否则
    /// 压缩后估算不降→死循环,或估算降了实际发全量→爆 context。
    compact_boundary: usize = 0,
    compact_summary: ?[]u8 = null, // owned;压缩摘要,投影时作为边界前的一条 assistant 消息注入
    mutation_version: u64 = 0,
    /// **前缀破坏代数**(R2/F1):删除或整体替换已存在消息的变更在此 +1(/retry 回卷、
    /// compact 的 replaceWithOwned)。transcript.Writer 据此发现 append-only 假设失效 →
    /// 全量重写;否则 flushed_count 单调,回卷再增长到同长度时重生成的回合永不落盘,
    /// resume 会复活被丢弃的旧回合。纯 append 不 bump。
    shrink_epoch: u64 = 0,
    /// API usage 锚点:上次请求服务端实际计的 prompt tokens(in+cache_r+cache_w)。
    /// auto-compact 的 token 估算以它为基准,只对锚点之后新 append 的消息做本地估算,
    /// 避免估算器与各家 tokenizer 的偏差随会话长度放大(对齐 cc 用 usage 算 context%)。
    usage_anchor: ?UsageAnchor = null,
    // 快照锁:保护 messages.items 的结构性改动(append → 可能 realloc)与 transcript 快照
    // 遍历的互斥。生成期 watcher 线程按 Ctrl+O 调 transcript_viewer 遍历 messages.items,
    // 与主线程 agent_loop 的 append 并发——append 触发 ArrayList realloc 会使遍历中的旧
    // items slice 失效(UAF)。append 与 lockSnapshot/unlockSnapshot 包裹的快照读持同一锁。
    // 竞争极低:append 一轮几次、快照仅 Ctrl+O 时,故用粗粒度锁无性能问题。
    snapshot_mutex: sync.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) Conversation {
        return .{ .allocator = allocator, .messages = .empty };
    }

    pub fn deinit(self: *Conversation) void {
        for (self.messages.items) |m| m.deinit(self.allocator);
        self.messages.deinit(self.allocator);
        if (self.compact_summary) |s| self.allocator.free(s);
    }

    /// 投影起点:活跃窗口 = messages[activeStart()..]。boundary 若越界(消息被 reset)则回 0。
    pub fn activeStart(self: *const Conversation) usize {
        return @min(self.compact_boundary, self.messages.items.len);
    }

    /// 活跃(投影后)消息切片:发给模型 / token 估算都基于它 + compact_summary。
    pub fn activeMessages(self: *const Conversation) []const msg.Message {
        return self.messages.items[self.activeStart()..];
    }

    /// 压缩摘要作为边界前一条虚拟 assistant 消息注入(P1.5:投影时才拼,不改原始 messages)。
    /// 设 compact_summary(替换旧摘要,owned 转移;传 null 清除)。
    fn setCompactSummary(self: *Conversation, s: ?[]u8) void {
        if (self.compact_summary) |old| self.allocator.free(old);
        self.compact_summary = s;
    }

    /// resume 恢复投影状态(A:transcript 持久化 boundary/summary)。boundary 防御性 cap 到已加载
    /// 消息数(meta 陈旧/损坏时不越界);summary dupe 成 owned(传 null 清)。释放旧 summary 防泄漏。
    pub fn restoreCompactState(self: *Conversation, boundary: usize, summary: ?[]const u8) !void {
        self.compact_boundary = @min(boundary, self.messages.items.len);
        if (self.compact_summary) |old| self.allocator.free(old);
        self.compact_summary = if (summary) |s| try self.allocator.dupe(u8, s) else null;
    }

    /// 把一段文本追加到 compact_summary 末尾(PostCompact hook 注入 skill/plan/MCP 上下文用)。
    /// 无摘要则直接设为该文本。失败(OOM)静默保持原摘要不变(注入是增强,非正确性)。
    pub fn appendToCompactSummary(self: *Conversation, extra: []const u8) void {
        if (extra.len == 0) return;
        _ = self.snapshot_mutex.lock();
        defer _ = self.snapshot_mutex.unlock();
        if (self.compact_summary) |old| {
            const merged = std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ old, extra }) catch return;
            self.allocator.free(old);
            self.compact_summary = merged;
        } else {
            self.compact_summary = self.allocator.dupe(u8, extra) catch return;
        }
        self.mutation_version +%= 1;
    }

    /// transcript 快照读前后持锁——与 append 互斥,防遍历 messages.items 时被 realloc 抽走。
    pub fn lockSnapshot(self: *Conversation) void {
        _ = self.snapshot_mutex.lock();
    }
    pub fn unlockSnapshot(self: *Conversation) void {
        _ = self.snapshot_mutex.unlock();
    }

    pub const UsageAnchor = struct {
        /// 服务端实计 prompt tokens(input + cache_read + cache_creation)。
        context_tokens: usize,
        /// 采样时的消息数:该 usage 覆盖 messages[0..msg_count](含 system/tools/注入)。
        msg_count: usize,
    };

    /// 记录 API usage 锚点(agent_loop 在收到 message_start usage 时调)。
    /// context_tokens=0 视为后端不报 usage,不建锚点。
    pub fn setUsageAnchor(self: *Conversation, context_tokens: usize) void {
        if (context_tokens == 0) return;
        _ = self.snapshot_mutex.lock();
        defer _ = self.snapshot_mutex.unlock();
        self.usage_anchor = .{
            .context_tokens = context_tokens,
            .msg_count = self.messages.items.len,
        };
    }

    /// 取仍有效的 usage 锚点。锚点由前缀改写操作精确作废(见 noteShrinkAtLocked):
    /// 只有 messages[0..msg_count) 被改写/丢弃才失效;截断/清理锚点后追加的消息不影响
    /// 前缀实计数(否则每轮 preflight 截断新结果都会把锚点打回冷路径字节估算)。
    pub fn usageAnchor(self: *const Conversation) ?UsageAnchor {
        const a = self.usage_anchor orelse return null;
        if (a.msg_count > self.messages.items.len) return null;
        return a;
    }

    /// 前缀改写通知(调用方须已持 snapshot_mutex):msg_index 落在锚点覆盖区 → 作废。
    fn noteShrinkAtLocked(self: *Conversation, msg_index: usize) void {
        if (self.usage_anchor) |a| {
            if (msg_index < a.msg_count) self.usage_anchor = null;
        }
    }

    /// 显式作废锚点。context-window recovery 进入时调:让 before/after 遥测同用
    /// 冷路径基准(否则 before 锚点实计、after 冷估算,删一条消息数字反而翻倍)。
    pub fn invalidateUsageAnchor(self: *Conversation) void {
        _ = self.snapshot_mutex.lock();
        defer _ = self.snapshot_mutex.unlock();
        self.usage_anchor = null;
    }

    /// 追加消息（转移所有权）。传入的 Message 不得再手动 deinit。
    pub fn append(self: *Conversation, m: msg.Message) !void {
        _ = self.snapshot_mutex.lock();
        defer _ = self.snapshot_mutex.unlock();
        try self.messages.append(self.allocator, m);
        self.mutation_version +%= 1; // append 只 bump mutation,不 bump shrink(不改前缀)
    }

    /// 便利方法：追加仅 text 的消息。字节被复制。
    pub fn appendText(self: *Conversation, role: msg.Role, text: []const u8) !void {
        const m = try msg.textMessage(role, text, self.allocator);
        errdefer m.deinit(self.allocator);
        try self.append(m);
    }

    /// 便利方法：追加 text/image 任意有序混排的 user 消息。字节被复制。
    pub fn appendUserParts(self: *Conversation, parts: []const msg.UserContentPart) !void {
        const m = try msg.userMessageFromParts(self.allocator, parts);
        errdefer m.deinit(self.allocator);
        try self.append(m);
    }

    pub fn len(self: *const Conversation) usize {
        return self.messages.items.len;
    }

    /// /retry 的回卷:丢弃 messages[user_idx+1..](user_idx = 要重发的最后一条 user 下标)。
    /// 持快照锁(与并发 transcript 快照/append 互斥)+ bump mutation_version(前缀变了,
    /// 旧快照必须失效)。**compact_boundary 钳到 ≤ user_idx**:回卷穿过 boundary 时,若不钳,
    /// activeStart 的逐读 clamp 会让活跃窗口投影为空——重发的 user 消息被藏在 boundary 之下,
    /// 请求只剩 compact_summary、无 user 消息;其后追加的消息也一直隐形到 len 重新超过
    /// stale boundary。钳到 user_idx(而非 len)保证重发消息本身在窗口内;它与 summary 的
    /// 内容重叠是可接受的冗余(模型必须逐字看到要重答的 user 消息)。
    pub fn rollbackForRetry(self: *Conversation, user_idx: usize) void {
        _ = self.snapshot_mutex.lock();
        defer _ = self.snapshot_mutex.unlock();
        std.debug.assert(user_idx < self.messages.items.len);
        const popped = self.messages.items.len > user_idx + 1;
        while (self.messages.items.len > user_idx + 1) {
            const m = self.messages.pop().?;
            m.deinit(self.allocator);
        }
        const clamped = self.compact_boundary > user_idx;
        if (clamped) self.compact_boundary = user_idx;
        self.mutation_version +%= 1;
        // 无 pop 且无 clamp(如中止 run 后立即 /retry)= 前缀未破坏,不触发全量重写(R3-3)。
        if (popped or clamped) self.shrink_epoch +%= 1;
    }

    /// 深拷贝整个对话到 dst allocator(转后台续跑用)。返回的 Conversation 与源 **0 共享指针**
    /// (每 message/block 的字节都 dupe 到 dst),可安全交给后台线程,源在前台被 reset 不影响它。
    /// 持快照锁:防拷贝遍历时被并发 append realloc 抽走 items(同 transcript 快照纪律)。
    /// 失败回收已拷部分,不泄漏。
    pub fn cloneInto(self: *Conversation, dst: std.mem.Allocator) !Conversation {
        _ = self.snapshot_mutex.lock();
        defer _ = self.snapshot_mutex.unlock();
        var out = Conversation.init(dst);
        errdefer out.deinit();
        try out.messages.ensureTotalCapacity(dst, self.messages.items.len);
        for (self.messages.items) |m| {
            const mc = try m.dupe(dst);
            errdefer mc.deinit(dst);
            try out.messages.append(dst, mc);
        }
        // P1.5 投影:后台续跑必须继承压缩状态(boundary+summary),否则后台 job 会发全量历史 +
        // 无摘要 → 爆 context/丢压缩。summary dupe 到 dst;errdefer out.deinit() 失败时释放。
        out.compact_boundary = self.compact_boundary;
        if (self.compact_summary) |s| out.compact_summary = try dst.dupe(u8, s);
        return out;
    }

    pub const SuffixSnapshot = struct {
        allocator: std.mem.Allocator,
        version: u64,
        start_index: usize,
        items: []msg.Message,

        pub fn deinit(self: *SuffixSnapshot) void {
            for (self.items) |m| m.deinit(self.allocator);
            self.allocator.free(self.items);
            self.items = &.{};
        }
    };

    pub const CompactPreview = struct {
        conversation: Conversation,
        suffix: SuffixSnapshot,

        pub fn deinit(self: *CompactPreview) void {
            self.conversation.deinit();
            self.suffix.deinit();
        }
    };

    /// Clone full history and the retained compact suffix under one lock. The
    /// suffix snapshot is later used to reject replacing history if another
    /// turn/tool path appended or edited the active suffix while summarizing.
    pub fn cloneForCompactPreview(self: *Conversation, dst: std.mem.Allocator, keep_n: usize) !CompactPreview {
        _ = self.snapshot_mutex.lock();
        defer _ = self.snapshot_mutex.unlock();

        const start_index = compactBoundaryForItems(self.messages.items, keep_n);
        var out = Conversation.init(dst);
        errdefer out.deinit();
        try out.messages.ensureTotalCapacity(dst, self.messages.items.len);
        for (self.messages.items) |m| {
            const mc = try m.dupe(dst);
            errdefer mc.deinit(dst);
            try out.messages.append(dst, mc);
        }

        const suffix_len = self.messages.items.len - start_index;
        const suffix_items = try dst.alloc(msg.Message, suffix_len);
        errdefer dst.free(suffix_items);
        var copied: usize = 0;
        errdefer for (suffix_items[0..copied]) |m| m.deinit(dst);
        for (self.messages.items[start_index..], 0..) |m, i| {
            suffix_items[i] = try m.dupe(dst);
            copied = i + 1;
        }

        return .{
            .conversation = out,
            .suffix = .{
                .allocator = dst,
                .version = self.mutation_version,
                .start_index = start_index,
                .items = suffix_items,
            },
        };
    }

    /// Literal replacement with an owned conversation: no suffix CAS and no
    /// delivery-watermark merge (the replacement's own flags are taken as is).
    /// Production compaction goes through `replaceWithOwnedIfSuffixUnchanged`;
    /// this entry exists only for the allocator-boundary tests in this file and
    /// is deliberately not public. `replacement` is drained on success.
    fn replaceWithOwned(self: *Conversation, replacement: *Conversation) bool {
        _ = self.snapshot_mutex.lock();
        defer _ = self.snapshot_mutex.unlock();
        return self.replaceWithOwnedLocked(replacement);
    }

    pub fn replaceWithOwnedIfSuffixUnchanged(self: *Conversation, snapshot: *const SuffixSnapshot, replacement: *Conversation) bool {
        _ = self.snapshot_mutex.lock();
        defer _ = self.snapshot_mutex.unlock();
        if (self.mutation_version != snapshot.version) return false;
        if (snapshot.start_index > self.messages.items.len) return false;
        if (self.messages.items.len - snapshot.start_index != snapshot.items.len) return false;
        for (self.messages.items[snapshot.start_index..], snapshot.items) |live, snap| {
            if (!messageEql(live, snap)) return false;
        }
        // Reject before mutating anything so a failed call is mutation-free.
        if (!sameAllocator(self.allocator, replacement.allocator)) return false;
        self.mergeDeliveredIntoLocked(replacement);
        return self.replaceWithOwnedLocked(replacement);
    }

    /// Carry the live delivery watermark into a replacement produced off to
    /// the side: a request may have delivered messages while a compact
    /// preview was being summarized, and the preview's copies still say
    /// `false`. The replacement's watermarks are derived exclusively from
    /// live identity: a replacement message is delivered iff the live message
    /// at the same index is delivered and content-equal (`messageEql`). This
    /// both carries a watermark set while the preview was in flight and
    /// clears a stale `true` that `Message.dupe` copied into a message the
    /// preview later rewrote; a reordered or rewritten message can never end
    /// up delivered by position. When the counts differ (a compact preview
    /// always yields an equal count; the suffix CAS does not itself constrain
    /// the replacement's length, so any other caller lands here) every
    /// replacement flag is cleared: undelivered is the conservative direction
    /// and self-heals at the next accepted request.
    fn mergeDeliveredIntoLocked(self: *const Conversation, replacement: *Conversation) void {
        if (replacement.messages.items.len != self.messages.items.len) {
            for (replacement.messages.items) |*rep| rep.delivered = false;
            return;
        }
        for (replacement.messages.items, self.messages.items) |*rep, live| {
            rep.delivered = live.delivered and messageEql(live, rep.*);
        }
    }

    fn replaceWithOwnedLocked(self: *Conversation, replacement: *Conversation) bool {
        if (!sameAllocator(self.allocator, replacement.allocator)) return false;
        for (self.messages.items) |m| m.deinit(self.allocator);
        self.messages.deinit(self.allocator);
        self.messages = replacement.messages;
        replacement.messages = .empty;
        // P1.5 投影:整体采用 replacement 的消息集时,也必须采用它的投影状态(boundary/summary)——
        // 否则 self.compact_boundary 会指向旧消息数(越界)、compact_summary 描述已被替换的消息(错乱)。
        // sameAllocator 已校验,summary 指针可安全 move。释放 self 旧摘要防泄漏,replacement 侧置 null 防 double-free。
        if (self.compact_summary) |old| self.allocator.free(old);
        self.compact_summary = replacement.compact_summary;
        self.compact_boundary = replacement.compact_boundary;
        replacement.compact_summary = null;
        replacement.compact_boundary = 0;
        self.mutation_version +%= 1;
        self.shrink_epoch +%= 1; // 整体替换 = 前缀破坏(transcript 须全量重写)
        self.usage_anchor = null; // 前缀被丢弃/替换,实计锚点作废
        return true;
    }

    /// 校准 token 估算:ASCII ≈ 4 字符/token,非 ASCII 码点(CJK 等)≈ 1 码点/token。
    /// 空字符串 0;无效 UTF-8 退化为 `len/4`。
    /// 依据:metask/glm-5.2 实测 3.54 bytes/token(2026-07-06 usage 对拍),claude/gpt
    /// 英文/代码/JSON 3.3~4.5。旧实现按码点计数(ASCII 下≈字节数)超估 ~4x:
    /// glm-5.2(262K 窗口)在真实用量 ~65K 时就触发 auto-compact / blocking-limit,
    /// 并发工具风暴下把全部 tool_result 清成 stub(auto compact"失效"根因之一)。
    /// 注意这是冷路径兜底;有 API usage 时以 usage anchor 为准(见 setUsageAnchor)。
    pub fn estimateTokens(text: []const u8) usize {
        if (text.len == 0) return 0;
        var ascii: usize = 0;
        var other: usize = 0;
        var view = std.unicode.Utf8View.init(text) catch return text.len / 4;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp < 0x80) ascii += 1 else other += 1;
        }
        return (ascii + 3) / 4 + other;
    }

    /// **投影后**消息的 token 估算(P1.5:只算 compact_summary + 活跃窗口 [boundary..],与发给模型的
    /// 完全一致)。压缩后 boundary 前移 → 此值下降 → 不再死循环压缩。tool_use/tool_result JSON 也算入。
    pub fn totalTokens(self: *const Conversation) usize {
        var total: usize = 0;
        if (self.compact_summary) |s| total += estimateTokens(s);
        for (self.activeMessages()) |m| {
            for (m.blocks) |b| switch (b) {
                .text => |t| total += estimateTokens(t),
                .tool_use => |tu| total += estimateTokens(tu.input) + estimateTokens(tu.name),
                // Read 工具图像形态 tool_result 与一等 image 同口径:按 IMAGE_TOKEN_ESTIMATE
                // 计,不按 base64 字节/4(否则 3.75MB 截图 ≈ 125 万 token,fallback 估算
                // 误触发 auto-compact——与 serializeForEstimation 投影同一不变量)。
                .tool_result => |tr| total += if (json_mod.extractImageResult(tr.content) != null)
                    IMAGE_TOKEN_ESTIMATE
                else
                    estimateTokens(tr.content),
                .thinking => |t| total += estimateTokens(t),
                .image => total += IMAGE_TOKEN_ESTIMATE,
            };
        }
        return total;
    }

    /// Token 估算是否已超过阈值。上层据此决定是否 compact。
    pub fn isOverThreshold(self: *const Conversation, threshold: usize) bool {
        return self.totalTokens() > threshold;
    }

    /// 压缩：丢弃最老的一半消息（保留最近 N/2）。
    /// 本期"诚实 MVP"——不调 API 生成摘要（那需要 API key）；
    /// 这个简单策略能在 token 压力下腾出空间而不撒谎。
    ///
    /// 注意：这种粗暴压缩可能破坏 tool_use / tool_result 的 pair——留给后续
    /// 完整版本（调 haiku 生成摘要并保持语义完整性）。
    pub fn compact(self: *Conversation, threshold: usize) !usize {
        if (!self.isOverThreshold(threshold)) return 0;

        _ = self.snapshot_mutex.lock();
        defer _ = self.snapshot_mutex.unlock();
        const start = self.activeStart();
        const active = self.messages.items.len - start;
        if (active < 4) return 0;
        // P1.5 投影:推进 boundary 到活跃窗口的中点(丢活跃前一半),不删消息。
        const new_boundary = start + active / 2;
        const dropped = new_boundary - self.compact_boundary;
        self.compact_boundary = new_boundary;
        self.mutation_version +%= 1;
        self.usage_anchor = null;
        return dropped;
    }

    /// 保留最近 keep_n 条 message，丢前面的。对 tool_use/tool_result 配对友好：
    /// 若保留区的第一条是 tool_result（orphan——它指向已丢的 tool_use），则把
    /// 这条也往前扩展一条"再往前找"，直到保留区首条是 user 非 tool_result 或 assistant 非 tool_use。
    ///
    /// 注意：仍会丢老的 user 消息 + 它们对应的 assistant 回答；这是故意的（这是 compact 的本意）。
    /// 只保证 *边界处* 不留孤儿。
    pub fn compactKeepRecent(self: *Conversation, keep_n: usize) usize {
        _ = self.snapshot_mutex.lock();
        defer _ = self.snapshot_mutex.unlock();
        // P1.5 投影:新 boundary=全量保留最近 keep_n 的边界(单调前移)。无摘要降级(老消息投影掉不总结)。
        const new_boundary = self.compactBoundary(keep_n);
        if (new_boundary <= self.compact_boundary) return 0;
        const dropped = new_boundary - self.compact_boundary;
        self.compact_boundary = new_boundary;
        self.mutation_version +%= 1;
        self.usage_anchor = null;
        return dropped;
    }

    /// Context-window-exceeded recovery: remove the oldest history item and
    /// any immediately orphaned tool_result boundary. This mirrors the Rust
    /// recovery path's one-item-at-a-time shrink while preserving Anthropic's
    /// tool_use/tool_result pairing invariant at the retained boundary.
    pub fn removeOldestForContextRecovery(self: *Conversation) usize {
        _ = self.snapshot_mutex.lock();
        defer _ = self.snapshot_mutex.unlock();
        // P1.5 投影:推进 boundary 丢最老活跃消息 + 紧邻孤儿 tool_result,不删原始。
        const total = self.messages.items.len;
        if (total - self.activeStart() <= 1) return 0;

        var dropped: usize = 0;
        self.compact_boundary += 1;
        dropped += 1;
        while ((total - self.compact_boundary) > 1 and isLeadingOrphanToolResult(self.messages.items[self.compact_boundary])) {
            self.compact_boundary += 1;
            dropped += 1;
        }
        self.mutation_version +%= 1;
        self.usage_anchor = null;
        return dropped;
    }

    /// 计算 compactKeepRecent 会丢的消息数(boundary):total-keep_n,但把边界左移以避免
    /// 保留区首条是孤儿 tool_result。供 compactWithSummary 先总结再丢用。
    pub fn compactBoundary(self: *const Conversation, keep_n: usize) usize {
        return compactBoundaryForItems(self.messages.items, keep_n);
    }

    /// 9 段结构化 compact:先把要丢的消息交给 summarize_fn 生成 summary,再丢老消息,
    /// 把 summary 作为一条 assistant 消息 prepend 到队首(保住早期上下文,对齐 cc)。
    /// summarize_fn 返回 null(无 client/失败)→ 退回纯 compactKeepRecent(降级)。
    /// 返回丢弃的消息数。
    pub fn compactWithSummary(
        self: *Conversation,
        keep_n: usize,
        ctx: anytype,
        comptime summarize_fn: fn (@TypeOf(ctx), []const msg.Message) ?[]u8,
    ) !usize {
        const report = try self.compactWithSummaryReport(keep_n, ctx, summarize_fn);
        return report.dropped;
    }

    pub const CompactReport = struct {
        dropped: usize,
        summary_used: bool,
    };

    pub const ToolResultReduction = struct {
        cleared: usize = 0,
        truncated: usize = 0,
        bytes_before: usize = 0,
        bytes_after: usize = 0,

        pub fn changed(self: ToolResultReduction) bool {
            return self.cleared > 0 or self.truncated > 0;
        }
    };

    pub fn compactWithSummaryReport(
        self: *Conversation,
        keep_n: usize,
        ctx: anytype,
        comptime summarize_fn: fn (@TypeOf(ctx), []const msg.Message) ?[]u8,
    ) !CompactReport {
        // P1.5 纯投影:新 boundary = 保留最近 keep_n 的前缀边界(全量算,单调前移;原始不删)。
        var new_boundary: usize = 0;
        var summary_input: []msg.Message = &.{};
        {
            _ = self.snapshot_mutex.lock();
            defer _ = self.snapshot_mutex.unlock();
            new_boundary = self.compactBoundary(keep_n);
            if (new_boundary <= self.compact_boundary) return .{ .dropped = 0, .summary_used = false };

            // 总结**全部**被投影掉的前缀 [0, new_boundary)(原始都在 → 完整摘要,替换旧摘要)。
            // dupe owned snapshot,不借用 messages.items(防 summarize 期间 append/realloc 悬挂)。
            summary_input = try self.allocator.alloc(msg.Message, new_boundary);
            errdefer self.allocator.free(summary_input);
            var copied: usize = 0;
            errdefer for (summary_input[0..copied]) |m| m.deinit(self.allocator);
            for (self.messages.items[0..new_boundary], 0..) |m, i| {
                summary_input[i] = try m.dupe(self.allocator);
                copied = i + 1;
            }
        }
        defer {
            for (summary_input) |m| m.deinit(self.allocator);
            self.allocator.free(summary_input);
        }

        const summary = summarize_fn(ctx, summary_input);
        errdefer if (summary) |s| self.allocator.free(s);

        // **投影**:不删任何消息,只推进 boundary + 替换摘要。原始永久保留供 transcript/resume/查看。
        _ = self.snapshot_mutex.lock();
        defer _ = self.snapshot_mutex.unlock();
        const old_boundary = self.compact_boundary;
        self.compact_boundary = new_boundary;
        if (summary) |s| self.setCompactSummary(s); // s owned → 转移
        self.mutation_version +%= 1;
        self.usage_anchor = null; // 投影窗口变了,实计锚点作废
        return .{ .dropped = new_boundary - old_boundary, .summary_used = summary != null };
    }

    /// Microcompact(批4,对齐 cc 的工具结果清理):把"较老"消息里的 tool_result 内容
    /// 替换成短 stub(释放 token),但**保留消息结构**(对话流不断、不调 API)。
    /// 比 compactKeepRecent 温和:不丢消息,只清旧工具结果(最占 token 的部分)。
    /// keep_recent_n:最近 N 条消息的 tool_result 不动(可能还要引用)。
    /// 返回清理的 tool_result 个数。
    pub fn microcompactToolResults(self: *Conversation, keep_recent_n: usize) usize {
        const total = self.messages.items.len;
        if (total <= keep_recent_n) return 0;
        const boundary = total - keep_recent_n; // [0, boundary) 是"老"消息
        _ = self.snapshot_mutex.lock();
        defer _ = self.snapshot_mutex.unlock();

        var cleared: usize = 0;
        var mi: usize = 0;
        while (mi < boundary) : (mi += 1) {
            const m = self.messages.items[mi];
            for (m.blocks, 0..) |b, bi| {
                switch (b) {
                    .tool_result => |tr| {
                        // 已是 stub 的不重复清(幂等)。
                        if (isClearedToolResultProjection(tr.content)) continue;
                        if (!m.delivered and result_projection.isImageResult(tr.content)) continue;
                        if (self.clearToolResultAt(m, bi) == null) continue;
                        self.noteShrinkAtLocked(mi);
                        cleared += 1;
                    },
                    else => {},
                }
            }
        }
        if (cleared > 0) self.mutation_version +%= 1;
        return cleared;
    }

    /// Codex-style tool output pressure valve: keep only the most recent K
    /// tool_result blocks intact, independent of message boundaries. This avoids
    /// the common failure mode where "recent N messages" preserves many old tool
    /// outputs in a dense tool turn and full compact keeps firing with low savings.
    pub fn microcompactToolResultsByRecentResults(self: *Conversation, keep_recent_results: usize) ToolResultReduction {
        _ = self.snapshot_mutex.lock();
        defer _ = self.snapshot_mutex.unlock();
        var out = ToolResultReduction{};
        var seen_recent: usize = 0;
        var mi = self.messages.items.len;
        while (mi > 0) {
            mi -= 1;
            const m = self.messages.items[mi];
            var bi = m.blocks.len;
            while (bi > 0) {
                bi -= 1;
                const b = m.blocks[bi];
                if (b != .tool_result) continue;
                seen_recent += 1;
                if (seen_recent <= keep_recent_results) continue;
                const tr = b.tool_result;
                if (isClearedToolResultProjection(tr.content)) continue;
                if (!m.delivered and result_projection.isImageResult(tr.content)) continue;
                const before = tr.content.len;
                const after = self.clearToolResultAt(m, bi) orelse continue;
                self.noteShrinkAtLocked(mi);
                out.cleared += 1;
                out.bytes_before += before;
                out.bytes_after += after;
            }
        }
        if (out.changed()) self.mutation_version +%= 1;
        return out;
    }

    /// Bound every inline tool_result. The latest result is still shown to the
    /// model, but as a head/tail preview instead of an unbounded blob. This is
    /// intentionally independent of full compact: a single recent tool result
    /// can be enough to exceed the context window.
    pub fn truncateLargeToolResults(self: *Conversation, max_bytes: usize) ToolResultReduction {
        _ = self.snapshot_mutex.lock();
        defer _ = self.snapshot_mutex.unlock();
        var out = ToolResultReduction{};
        if (max_bytes == 0) return out;
        for (self.messages.items, 0..) |m, mi| {
            for (m.blocks, 0..) |b, bi| {
                if (b != .tool_result) continue;
                const tr = b.tool_result;
                if (tr.content.len <= max_bytes) continue;
                if (isCommittedToolResultProjection(tr.content)) continue;
                // A truncated base64 payload is neither an image nor useful
                // text; images are charged at IMAGE_TOKEN_ESTIMATE anyway.
                if (result_projection.isImageResult(tr.content)) continue;
                const before = tr.content.len;
                const new_content = truncateToolResultContent(self.allocator, tr.content, max_bytes) catch continue;
                self.allocator.free(@constCast(tr.content));
                m.blocks[bi] = .{ .tool_result = .{
                    .tool_use_id = tr.tool_use_id,
                    .content = new_content,
                    .is_error = tr.is_error,
                } };
                self.noteShrinkAtLocked(mi);
                out.truncated += 1;
                out.bytes_before += before;
                out.bytes_after += new_content.len;
            }
        }
        if (out.changed()) self.mutation_version +%= 1;
        return out;
    }

    /// Delivery watermark: the entire retained history is treated as
    /// delivered — every active message was carried by the request just
    /// accepted, and compacted prefix messages were delivered before they
    /// were compacted (`rollbackForRetry` may re-admit some of them; they are
    /// then re-sent as already-delivered history). Called by agent_loop once the provider has
    /// accepted the request for streaming (a stream handle came back; a
    /// request the provider rejected with an HTTP error does not deliver).
    /// Nothing else may claim delivery: a local assistant append such as the
    /// AgentCore budget terminal marker is not a provider reply.
    ///
    /// Granularity is the message. A tool_result the request normalizer
    /// strips as an orphan (no matching tool_use in the immediately preceding
    /// assistant turn, see message_repair.stripOrphanToolResults) is marked as
    /// well, deliberately: pairing is sequential, later assistant turns come
    /// after the result, and the active range only shrinks from the front
    /// (the one backwards move, rollbackForRetry, deletes everything after
    /// the retried user message first), so an orphan can never reach a
    /// provider in any later request either; protecting it from microcompact
    /// would only pin dead bytes.
    ///
    /// Image results that are not yet delivered are protected from
    /// microcompact: a picture is a raw payload here rather than a
    /// recoverable envelope (projection exempts it), and the recent-N valve
    /// counts results rather than turns, so a Read(image) with two parallel
    /// siblings would otherwise be cleared before the provider ever saw it.
    /// Delivered images clear like any other result, so the valve keeps
    /// working on image-heavy history. Undelivered text results keep their
    /// historical behaviour (see doc/CORE_REFERENCE.md).
    ///
    /// `images_visible` is the route's `supports(.image_input)`: a non-vision
    /// model receives a bounded placeholder instead of the picture
    /// (request.zig), so a message carrying an image result is not delivered
    /// by such a request — switching to a vision model later must still let
    /// it see the picture before microcompact may clear it.
    pub fn markDelivered(self: *Conversation, opts: DeliveryOptions) void {
        _ = self.snapshot_mutex.lock();
        defer _ = self.snapshot_mutex.unlock();
        const active_start = @min(self.compact_boundary, self.messages.items.len);
        for (self.messages.items, 0..) |*m, i| {
            // The vision exception only protects an image that some later
            // vision-capable request could still carry: an active message whose
            // image result is paired with the nearest preceding assistant turn.
            // A message behind the compact boundary cannot be carried paired
            // again: the boundary only moves forward, and the one backwards
            // move (`rollbackForRetry`) re-admits from the selected user message
            // itself, never the assistant turn that precedes it, so the result
            // would be stripped as an orphan. An orphan image result is stripped
            // by the request normalizer for the same reason. Leaving either
            // undelivered would only pin its base64 forever.
            if (!opts.images_visible and i >= active_start and
                messageHasImageResult(m.*) and !self.imageResultsAreOrphansLocked(i, active_start))
                continue;
            m.delivered = true;
        }
    }

    /// Whether every image result in message `index` is an orphan under the
    /// request normalizer's sequential pairing (message_repair): its id must
    /// be outstanding from the nearest preceding assistant turn of the active
    /// range, and each id answers only once, in message and block order — a
    /// second result for an already-answered id is an orphan too. On OOM the
    /// message is treated as paired (kept protected).
    fn imageResultsAreOrphansLocked(self: *const Conversation, index: usize, active_start: usize) bool {
        var turn_index: ?usize = null;
        var i = index;
        while (i > active_start) {
            i -= 1;
            if (self.messages.items[i].role == .assistant) {
                turn_index = i;
                break;
            }
        }
        const turn = turn_index orelse return true;
        var outstanding = std.StringHashMap(void).init(self.allocator);
        defer outstanding.deinit();
        for (self.messages.items[turn].blocks) |b| switch (b) {
            .tool_use => |tu| outstanding.put(tu.id, {}) catch return false,
            else => {},
        };
        var j = turn + 1;
        while (j < index) : (j += 1) {
            for (self.messages.items[j].blocks) |b| switch (b) {
                .tool_result => |tr| _ = outstanding.remove(tr.tool_use_id),
                else => {},
            };
        }
        for (self.messages.items[index].blocks) |b| switch (b) {
            .tool_result => |tr| {
                const paired = outstanding.remove(tr.tool_use_id);
                if (paired and result_projection.isImageResult(tr.content)) return false;
            },
            else => {},
        };
        return true;
    }

    pub const DeliveryOptions = struct {
        /// The serializer's own report for the accepted request
        /// (`StreamHandle.image_results_native`): true iff every image result
        /// in it went out as a native image part. Never route capability —
        /// a plugin dialect may refuse to emit images although the model's
        /// profile says it could.
        images_visible: bool,
    };

    fn messageHasImageResult(m: msg.Message) bool {
        for (m.blocks) |b| switch (b) {
            .tool_result => |tr| if (result_projection.isImageResult(tr.content)) return true,
            else => {},
        };
        return false;
    }

    fn clearToolResultAt(self: *Conversation, m: msg.Message, bi: usize) ?usize {
        const tr = m.blocks[bi].tool_result;
        // Artifact envelopes are already compact and are the only recovery
        // capability for the omitted bytes. Microcompact must not erase that
        // capability merely because the result became old.
        if (result_projection.hasRecoverableArtifact(tr.content)) return null;
        const new_content = if (toolResultCommitmentLine(tr.content)) |commitment|
            std.fmt.allocPrint(
                self.allocator,
                "{s}\n{s}",
                .{ TOOL_RESULT_CLEARED_STUB, commitment },
            ) catch return null
        else blk: {
            const digest = sha256Hex(tr.content);
            break :blk std.fmt.allocPrint(
                self.allocator,
                "{s}\n{s}original_bytes={d} sha256={s}]",
                .{ TOOL_RESULT_CLEARED_STUB, TOOL_RESULT_COMMITMENT_PREFIX, tr.content.len, digest[0..] },
            ) catch return null;
        };
        if (new_content.len >= tr.content.len) {
            self.allocator.free(new_content);
            return null;
        }
        self.allocator.free(@constCast(tr.content));
        m.blocks[bi] = .{ .tool_result = .{
            .tool_use_id = tr.tool_use_id,
            .content = new_content,
            .is_error = tr.is_error,
        } };
        return new_content.len;
    }
};

fn isLeadingOrphanToolResult(m: msg.Message) bool {
    if (m.role != .user) return false;
    if (m.blocks.len == 0) return false;
    return @as(std.meta.Tag(msg.Block), m.blocks[0]) == .tool_result;
}

fn compactBoundaryForItems(items: []const msg.Message, keep_n: usize) usize {
    const total = items.len;
    if (total <= keep_n) return 0;
    var drop_count = total - keep_n;
    while (drop_count < total) {
        const first_kept = items[drop_count];
        if (first_kept.role != .user) break;
        if (first_kept.blocks.len == 0) break;
        if (@as(std.meta.Tag(msg.Block), first_kept.blocks[0]) != .tool_result) break;
        drop_count += 1;
    }
    if (drop_count >= total) drop_count = total - 1;
    return drop_count;
}

fn messageEql(a: msg.Message, b: msg.Message) bool {
    if (a.role != b.role) return false;
    if (a.blocks.len != b.blocks.len) return false;
    for (a.blocks, b.blocks) |ab, bb| {
        if (!blockEql(ab, bb)) return false;
    }
    return true;
}

fn blockEql(a: msg.Block, b: msg.Block) bool {
    const tag_a = @as(std.meta.Tag(msg.Block), a);
    const tag_b = @as(std.meta.Tag(msg.Block), b);
    if (tag_a != tag_b) return false;
    return switch (a) {
        .text => |t| std.mem.eql(u8, t, b.text),
        .thinking => |t| std.mem.eql(u8, t, b.thinking),
        .tool_use => |tu| std.mem.eql(u8, tu.id, b.tool_use.id) and
            std.mem.eql(u8, tu.name, b.tool_use.name) and
            std.mem.eql(u8, tu.input, b.tool_use.input),
        .tool_result => |tr| std.mem.eql(u8, tr.tool_use_id, b.tool_result.tool_use_id) and
            std.mem.eql(u8, tr.content, b.tool_result.content) and
            tr.is_error == b.tool_result.is_error,
        .image => |img| std.mem.eql(u8, img.media_type, b.image.media_type) and
            std.mem.eql(u8, img.data, b.image.data),
    };
}

fn sameAllocator(a: std.mem.Allocator, b: std.mem.Allocator) bool {
    return a.ptr == b.ptr and a.vtable == b.vtable;
}

fn truncateToolResultContent(allocator: std.mem.Allocator, content: []const u8, max_bytes: usize) ![]u8 {
    if (content.len <= max_bytes) return try allocator.dupe(u8, content);
    const digest = sha256Hex(content);
    if (max_bytes < 1024) {
        return try std.fmt.allocPrint(
            allocator,
            "{s}original_bytes={d} sha256={s}]\n[tool output truncated to fit context]",
            .{ TOOL_RESULT_COMMITMENT_PREFIX, content.len, digest[0..] },
        );
    }

    const preview_budget = max_bytes - 512;
    const wanted_head_len = preview_budget * 3 / 4;
    const wanted_tail_len = preview_budget - wanted_head_len;
    const content_is_valid_utf8 = std.unicode.utf8ValidateSlice(content);
    const head_end = if (content_is_valid_utf8)
        floorUtf8Boundary(content, wanted_head_len)
    else
        validUtf8PrefixLen(content, wanted_head_len);
    var tail_start = if (content_is_valid_utf8)
        ceilUtf8Boundary(content, content.len - wanted_tail_len)
    else
        content.len;
    if (tail_start < head_end) tail_start = head_end;
    const omitted = tail_start - head_end;
    return try std.fmt.allocPrint(
        allocator,
        "{s}original_bytes={d} sha256={s}]\n[tool output truncated to fit context: shown_head_bytes={d}, shown_tail_bytes={d}]\n\n{s}\n\n...[truncated {d} bytes]...\n\n{s}",
        .{ TOOL_RESULT_COMMITMENT_PREFIX, content.len, digest[0..], head_end, content.len - tail_start, content[0..head_end], omitted, content[tail_start..] },
    );
}

pub fn isCommittedToolResultProjection(content: []const u8) bool {
    return isClearedToolResultProjection(content) or isTruncatedToolResultProjection(content);
}

fn isClearedToolResultProjection(content: []const u8) bool {
    if (std.mem.eql(u8, content, TOOL_RESULT_CLEARED_STUB)) return true;
    const prefix = TOOL_RESULT_CLEARED_STUB ++ "\n";
    if (!std.mem.startsWith(u8, content, prefix)) return false;
    const commitment = commitmentLineAt(content, prefix.len) orelse return false;
    return prefix.len + commitment.len == content.len;
}

fn isTruncatedToolResultProjection(content: []const u8) bool {
    const commitment = commitmentLineAt(content, 0) orelse return false;
    const rest = content[commitment.len..];
    return std.mem.startsWith(u8, rest, "\n[tool output truncated to fit context");
}

fn toolResultCommitmentLine(content: []const u8) ?[]const u8 {
    const start = if (isTruncatedToolResultProjection(content))
        @as(usize, 0)
    else if (isClearedToolResultProjection(content) and !std.mem.eql(u8, content, TOOL_RESULT_CLEARED_STUB))
        TOOL_RESULT_CLEARED_STUB.len + 1
    else
        return null;
    return commitmentLineAt(content, start);
}

fn commitmentLineAt(content: []const u8, start: usize) ?[]const u8 {
    if (start > content.len) return null;
    const tail = content[start..];
    const end = std.mem.indexOfScalar(u8, tail, '\n') orelse tail.len;
    const line = tail[0..end];
    const bytes_prefix = TOOL_RESULT_COMMITMENT_PREFIX ++ "original_bytes=";
    if (!std.mem.startsWith(u8, line, bytes_prefix)) return null;
    var cursor = bytes_prefix.len;
    const digits_start = cursor;
    while (cursor < line.len and std.ascii.isDigit(line[cursor])) : (cursor += 1) {}
    if (cursor == digits_start) return null;
    _ = std.fmt.parseInt(usize, line[digits_start..cursor], 10) catch return null;
    const hash_prefix = " sha256=";
    if (!std.mem.startsWith(u8, line[cursor..], hash_prefix)) return null;
    cursor += hash_prefix.len;
    if (line.len - cursor != 65 or line[line.len - 1] != ']') return null;
    for (line[cursor .. cursor + 64]) |char| {
        if (!std.ascii.isDigit(char) and !(char >= 'a' and char <= 'f')) return null;
    }
    return line;
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn floorUtf8Boundary(s: []const u8, desired: usize) usize {
    var end = @min(desired, s.len);
    if (end == s.len) return end;
    while (end > 0 and isUtf8ContinuationByte(s[end])) : (end -= 1) {}
    return end;
}

fn ceilUtf8Boundary(s: []const u8, desired: usize) usize {
    var start = @min(desired, s.len);
    while (start < s.len and isUtf8ContinuationByte(s[start])) : (start += 1) {}
    return start;
}

fn validUtf8PrefixLen(s: []const u8, desired: usize) usize {
    var i: usize = 0;
    var last: usize = 0;
    const limit = @min(desired, s.len);
    while (i < limit) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch break;
        if (i + n > limit) break;
        _ = std.unicode.utf8Decode(s[i .. i + n]) catch break;
        i += n;
        last = i;
    }
    return last;
}

fn isUtf8ContinuationByte(b: u8) bool {
    return (b & 0b1100_0000) == 0b1000_0000;
}

test "Conversation init / deinit empty" {
    var c = Conversation.init(std.testing.allocator);
    defer c.deinit();
    try std.testing.expect(c.len() == 0);
}

test "Conversation appendText roundtrip" {
    var c = Conversation.init(std.testing.allocator);
    defer c.deinit();
    try c.appendText(.user, "hello");
    try c.appendText(.assistant, "hi");
    try std.testing.expect(c.len() == 2);
    try std.testing.expect(c.messages.items[0].role == .user);
    try std.testing.expectEqualStrings("hello", c.messages.items[0].blocks[0].text);
}

test "Conversation append structured message" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();

    const blocks = try a.alloc(msg.Block, 1);
    blocks[0] = .{ .tool_use = .{
        .id = try a.dupe(u8, "t1"),
        .name = try a.dupe(u8, "Read"),
        .input = try a.dupe(u8, "{\"path\":\"/tmp/x\"}"),
    } };
    try c.append(.{ .role = .assistant, .blocks = blocks });
    try std.testing.expect(c.len() == 1);
}

test "estimateTokens ASCII" {
    try std.testing.expect(Conversation.estimateTokens("hello world") >= 2);
}

test "estimateTokens CJK" {
    try std.testing.expect(Conversation.estimateTokens("你好") == 2);
}

test "estimateTokens empty" {
    try std.testing.expect(Conversation.estimateTokens("") == 0);
}

test "estimateTokens invalid utf8 falls back to len/4" {
    try std.testing.expect(Conversation.estimateTokens("\xff\xff\xff\xff\xff\xff\xff\xff") == 2);
}

test "estimateTokens calibrated: ASCII/4 + non-ASCII codepoints" {
    // 8 ASCII → 2;9 ASCII → ceil(9/4)=3。
    try std.testing.expectEqual(@as(usize, 2), Conversation.estimateTokens("abcdefgh"));
    try std.testing.expectEqual(@as(usize, 3), Conversation.estimateTokens("abcdefghi"));
    // 混合:4 ASCII(1)+ 2 CJK(2)= 3。
    try std.testing.expectEqual(@as(usize, 3), Conversation.estimateTokens("abcd你好"));
}

test "usage anchor: append keeps it valid, shrink invalidates it" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "first message");
    try std.testing.expect(c.usageAnchor() == null); // 未设锚点

    c.setUsageAnchor(12_345);
    const anchor = c.usageAnchor().?;
    try std.testing.expectEqual(@as(usize, 12_345), anchor.context_tokens);
    try std.testing.expectEqual(@as(usize, 1), anchor.msg_count);

    // append 不作废锚点(新消息属于锚点后缀)。
    try c.appendText(.assistant, "reply");
    try std.testing.expect(c.usageAnchor() != null);
    try std.testing.expectEqual(@as(usize, 1), c.usageAnchor().?.msg_count);

    // 收缩(compactKeepRecent 丢老消息)→ 锚点作废。
    try c.appendText(.user, "third");
    try c.appendText(.assistant, "fourth");
    _ = c.compactKeepRecent(2);
    try std.testing.expect(c.usageAnchor() == null);
}

test "delivery watermark: a non-vision route leaves image-result messages undelivered" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "look");
    // The image result must be paired with a preceding tool_use: an unpaired
    // (orphan) result is stripped by the normalizer and delivers unconditionally.
    const tu = try a.alloc(msg.Block, 1);
    tu[0] = .{ .tool_use = .{ .id = try a.dupe(u8, "t1"), .name = try a.dupe(u8, "Read"), .input = try a.dupe(u8, "{}") } };
    try c.append(.{ .role = .assistant, .blocks = tu });
    const blocks = try a.alloc(msg.Block, 1);
    blocks[0] = .{ .tool_result = .{
        .tool_use_id = try a.dupe(u8, "t1"),
        .content = try a.dupe(u8, "{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"AAAA\"}"),
        .is_error = false,
    } };
    try c.append(.{ .role = .user, .blocks = blocks });
    // Non-vision request: the placeholder went out, not the picture.
    c.markDelivered(.{ .images_visible = false });
    try std.testing.expect(c.messages.items[0].delivered);
    try std.testing.expect(c.messages.items[1].delivered);
    try std.testing.expect(!c.messages.items[2].delivered);
    // A vision-capable request delivers it.
    c.markDelivered(.{ .images_visible = true });
    try std.testing.expect(c.messages.items[2].delivered);
}

test "delivery watermark: non-vision requests still deliver inactive and orphan image messages" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    const img = "{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"AAAA\"}";
    const T = struct {
        fn imageResult(conv: *Conversation, al: std.mem.Allocator, id: []const u8) !void {
            const blocks = try al.alloc(msg.Block, 1);
            blocks[0] = .{ .tool_result = .{ .tool_use_id = try al.dupe(u8, id), .content = try al.dupe(u8, img), .is_error = false } };
            try conv.append(.{ .role = .user, .blocks = blocks });
        }
        fn toolUse(conv: *Conversation, al: std.mem.Allocator, id: []const u8) !void {
            const blocks = try al.alloc(msg.Block, 1);
            blocks[0] = .{ .tool_use = .{ .id = try al.dupe(u8, id), .name = try al.dupe(u8, "Read"), .input = try al.dupe(u8, "{}") } };
            try conv.append(.{ .role = .assistant, .blocks = blocks });
        }
    };
    try T.imageResult(&c, a, "old"); // 0: behind the boundary after resume
    try c.appendText(.assistant, "seen"); // 1
    try T.imageResult(&c, a, "ghost"); // 2: active orphan (nearest assistant turn has no tool_use "ghost")
    try T.toolUse(&c, a, "t1"); // 3
    try T.imageResult(&c, a, "t1"); // 4: active, legitimately paired
    try c.restoreCompactState(1, null);

    c.markDelivered(.{ .images_visible = false });
    try std.testing.expect(c.messages.items[0].delivered);
    try std.testing.expect(c.messages.items[2].delivered);
    try std.testing.expect(!c.messages.items[4].delivered);
    c.markDelivered(.{ .images_visible = true });
    try std.testing.expect(c.messages.items[4].delivered);
}

test "delivery watermark: a second result for an already-answered id is an orphan, like in the normalizer" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    const tu = try a.alloc(msg.Block, 1);
    tu[0] = .{ .tool_use = .{ .id = try a.dupe(u8, "x"), .name = try a.dupe(u8, "Read"), .input = try a.dupe(u8, "{}") } };
    try c.append(.{ .role = .assistant, .blocks = tu });
    const blocks = try a.alloc(msg.Block, 2);
    blocks[0] = .{ .tool_result = .{ .tool_use_id = try a.dupe(u8, "x"), .content = try a.dupe(u8, "text answer"), .is_error = false } };
    blocks[1] = .{ .tool_result = .{ .tool_use_id = try a.dupe(u8, "x"), .content = try a.dupe(u8, "{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"AAAA\"}"), .is_error = false } };
    try c.append(.{ .role = .user, .blocks = blocks });
    // The text result consumed `x`; the image is a duplicate the normalizer strips,
    // so a non-vision request must still deliver (not pin) this message.
    c.markDelivered(.{ .images_visible = false });
    try std.testing.expect(c.messages.items[1].delivered);
}

test "compact preview commit keeps a delivery watermark set while the preview was in flight" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "look at the picture");
    try c.appendText(.assistant, "ok");
    var preview = try c.cloneForCompactPreview(a, 2);
    defer preview.deinit();
    // A provider request goes out while the summary is still being produced.
    c.markDelivered(.{ .images_visible = true });
    try std.testing.expect(!preview.conversation.messages.items[0].delivered);
    // The suffix CAS still matches (delivery is not a content mutation), and the
    // committed history must not regress to the preview's stale `false`.
    try std.testing.expect(c.replaceWithOwnedIfSuffixUnchanged(&preview.suffix, &preview.conversation));
    for (c.messages.items) |m| try std.testing.expect(m.delivered);
}

test "delivery watermark is carried only to the same message, never by position to a rewritten one" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "first");
    try c.appendText(.assistant, "second");
    var preview = try c.cloneForCompactPreview(a, 1);
    defer preview.deinit();
    c.markDelivered(.{ .images_visible = true });
    // Rewrite the first message of the replacement (outside the retained suffix,
    // so the CAS still passes): it is a different message and must not inherit
    // the live watermark by index.
    const rewritten = try a.dupe(u8, "rewritten prefix");
    a.free(@constCast(preview.conversation.messages.items[0].blocks[0].text));
    preview.conversation.messages.items[0].blocks[0] = .{ .text = rewritten };
    try std.testing.expect(c.replaceWithOwnedIfSuffixUnchanged(&preview.suffix, &preview.conversation));
    try std.testing.expect(!c.messages.items[0].delivered);
    try std.testing.expect(c.messages.items[1].delivered);
}

test "delivery watermark copied into a preview is cleared when the preview rewrites that message" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "first");
    try c.appendText(.assistant, "second");
    // Delivered BEFORE cloning: Message.dupe copies `delivered = true` into the preview.
    c.markDelivered(.{ .images_visible = true });
    var preview = try c.cloneForCompactPreview(a, 1);
    defer preview.deinit();
    try std.testing.expect(preview.conversation.messages.items[0].delivered);
    // The preview rewrites the prefix message (outside the retained suffix, CAS
    // still passes). It is a different message the provider has never seen, so
    // the stale copied watermark must not survive the commit.
    const rewritten = try a.dupe(u8, "rewritten prefix");
    a.free(@constCast(preview.conversation.messages.items[0].blocks[0].text));
    preview.conversation.messages.items[0].blocks[0] = .{ .text = rewritten };
    try std.testing.expect(c.replaceWithOwnedIfSuffixUnchanged(&preview.suffix, &preview.conversation));
    try std.testing.expect(!c.messages.items[0].delivered);
    try std.testing.expect(c.messages.items[1].delivered);
}

test "usage anchor: microcompact clear invalidates it" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    const blocks = try a.alloc(msg.Block, 1);
    const content = try a.alloc(u8, 512);
    @memset(content, 'x');
    blocks[0] = .{ .tool_result = .{
        .tool_use_id = try a.dupe(u8, "t1"),
        .content = content,
        .is_error = false,
    } };
    try c.append(.{ .role = .user, .blocks = blocks });
    try c.appendText(.assistant, "done");
    c.setUsageAnchor(50_000);
    try std.testing.expect(c.usageAnchor() != null);

    const reduced = c.microcompactToolResultsByRecentResults(0);
    try std.testing.expectEqual(@as(usize, 1), reduced.cleared);
    try std.testing.expect(c.usageAnchor() == null); // 前缀被改写,实计数不再可信
}

test "usage anchor: microcompact never expands a short result" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    const blocks = try a.alloc(msg.Block, 1);
    blocks[0] = .{ .tool_result = .{
        .tool_use_id = try a.dupe(u8, "t1"),
        .content = try a.dupe(u8, "short result"),
        .is_error = false,
    } };
    try c.append(.{ .role = .user, .blocks = blocks });
    try c.appendText(.assistant, "done");
    c.setUsageAnchor(50_000);

    const reduced = c.microcompactToolResultsByRecentResults(0);
    try std.testing.expectEqual(@as(usize, 0), reduced.cleared);
    try std.testing.expectEqualStrings("short result", c.messages.items[0].blocks[0].tool_result.content);
    try std.testing.expect(c.usageAnchor() != null);
}

test "usage anchor: truncating a post-anchor tool_result keeps the anchor (glm 逐轮截断回归)" {
    // 实测回归(2026-07-06 fix2.log):每轮新 Read 结果被 preflight truncate,
    // 粗粒度失效把锚点每轮打回冷路径字节估算 → 真实 106K 被估成 222K+ 误触发 microcompact。
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "read files");
    c.setUsageAnchor(100_000); // 覆盖 messages[0..1]

    // 锚点之后追加一条超大 tool_result(属于后缀)。
    const blocks = try a.alloc(msg.Block, 1);
    const huge = try a.alloc(u8, 100 * 1024);
    @memset(huge, 'x');
    blocks[0] = .{ .tool_result = .{
        .tool_use_id = try a.dupe(u8, "t1"),
        .content = huge,
        .is_error = false,
    } };
    try c.append(.{ .role = .user, .blocks = blocks });

    const reduced = c.truncateLargeToolResults(32 * 1024);
    try std.testing.expectEqual(@as(usize, 1), reduced.truncated);
    // 后缀截断不影响前缀实计数 → 锚点仍有效。
    try std.testing.expect(c.usageAnchor() != null);

    // 清后缀 result(index 1 ≥ msg_count 1,不在锚点覆盖区)同样保锚点。
    const cleared = c.microcompactToolResultsByRecentResults(0);
    try std.testing.expectEqual(@as(usize, 1), cleared.cleared);
    try std.testing.expect(c.usageAnchor() != null);
}

test "usage anchor: zero usage from backend does not create an anchor" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "msg");
    c.setUsageAnchor(0);
    try std.testing.expect(c.usageAnchor() == null);
}

test "totalTokens across mixed blocks" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "hello");
    const blocks = try a.alloc(msg.Block, 1);
    blocks[0] = .{ .tool_use = .{
        .id = try a.dupe(u8, "t1"),
        .name = try a.dupe(u8, "Read"),
        .input = try a.dupe(u8, "{\"path\":\"/x\"}"),
    } };
    try c.append(.{ .role = .assistant, .blocks = blocks });
    try std.testing.expect(c.totalTokens() > 0);
}

test "compact returns NotImplemented" {
    // 本期改为：低于阈值 → 返回 0（不压缩）
    var c = Conversation.init(std.testing.allocator);
    defer c.deinit();
    try c.appendText(.user, "tiny");
    const dropped = try c.compact(10_000);
    try std.testing.expect(dropped == 0);
}

test "compact drops oldest half when over threshold" {
    var c = Conversation.init(std.testing.allocator);
    defer c.deinit();
    // 塞 10 条消息，每条含一个带汉字的 text 增加 token
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try c.appendText(.user, "这是一条很长的中文消息用来凑 token 数量");
    }
    const before = c.len();
    const dropped = try c.compact(1);
    try std.testing.expect(dropped == before / 2);
    // 投影语义:原始消息永不删除,len() 仍全量;活跃窗口收缩 before-dropped。
    try std.testing.expect(c.len() == before);
    try std.testing.expect(c.activeMessages().len == before - dropped);
}

test "compact is no-op for short conversation even over threshold" {
    var c = Conversation.init(std.testing.allocator);
    defer c.deinit();
    try c.appendText(.user, "a");
    try c.appendText(.user, "b");
    const dropped = try c.compact(0);
    try std.testing.expect(dropped == 0);
}

test "isOverThreshold" {
    var c = Conversation.init(std.testing.allocator);
    defer c.deinit();
    try c.appendText(.user, "hello");
    try std.testing.expect(!c.isOverThreshold(10_000));
    try std.testing.expect(c.isOverThreshold(0));
}

test "Conversation append takes ownership (no double free)" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit(); // 应负责释放所有 append 过的 blocks
    const blks = try a.alloc(msg.Block, 1);
    blks[0] = .{ .text = try a.dupe(u8, "owned") };
    try c.append(.{ .role = .user, .blocks = blks });
    // 不要手动 deinit 传入的 Message——conversation 拥有所有权
}

test "appendText multiple messages order preserved" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "1");
    try c.appendText(.assistant, "2");
    try c.appendText(.user, "3");
    try std.testing.expect(c.len() == 3);
    try std.testing.expectEqualStrings("1", c.messages.items[0].blocks[0].text);
    try std.testing.expectEqualStrings("2", c.messages.items[1].blocks[0].text);
    try std.testing.expectEqualStrings("3", c.messages.items[2].blocks[0].text);
}

test "totalTokens zero on empty" {
    var c = Conversation.init(std.testing.allocator);
    defer c.deinit();
    try std.testing.expect(c.totalTokens() == 0);
}

test "compactKeepRecent keeps last N" {
    var c = Conversation.init(std.testing.allocator);
    defer c.deinit();
    try c.appendText(.user, "m1");
    try c.appendText(.assistant, "m2");
    try c.appendText(.user, "m3");
    try c.appendText(.assistant, "m4");
    try c.appendText(.user, "m5");

    const dropped = c.compactKeepRecent(2);
    try std.testing.expect(dropped == 3);
    // 投影:全量保留,活跃窗口=最近 2 条。
    try std.testing.expect(c.len() == 5);
    try std.testing.expectEqual(@as(usize, 3), c.activeStart());
    const active = c.activeMessages();
    try std.testing.expectEqual(@as(usize, 2), active.len);
    try std.testing.expectEqualStrings("m4", active[0].blocks[0].text);
    try std.testing.expectEqualStrings("m5", active[1].blocks[0].text);
    // 被投影掉的老消息仍原样保留在 messages 头部(供 transcript/resume)。
    try std.testing.expectEqualStrings("m1", c.messages.items[0].blocks[0].text);
}

test "compactKeepRecent no-op when under keep_n" {
    var c = Conversation.init(std.testing.allocator);
    defer c.deinit();
    try c.appendText(.user, "m1");
    const dropped = c.compactKeepRecent(5);
    try std.testing.expect(dropped == 0);
    try std.testing.expect(c.len() == 1);
}

test "compactKeepRecent avoids orphan tool_result at boundary" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();

    // user msg, assistant w/ tool_use, user w/ tool_result, assistant text, user text
    try c.appendText(.user, "initial user");

    const au_blks = try a.alloc(msg.Block, 1);
    au_blks[0] = .{ .tool_use = .{
        .id = try a.dupe(u8, "t1"),
        .name = try a.dupe(u8, "Read"),
        .input = try a.dupe(u8, "{}"),
    } };
    try c.append(.{ .role = .assistant, .blocks = au_blks });

    const ur_blks = try a.alloc(msg.Block, 1);
    ur_blks[0] = .{ .tool_result = .{
        .tool_use_id = try a.dupe(u8, "t1"),
        .content = try a.dupe(u8, "result"),
    } };
    try c.append(.{ .role = .user, .blocks = ur_blks });

    try c.appendText(.assistant, "answer");
    try c.appendText(.user, "follow up");

    // keep_n=3 → 理论上应丢前 2，留最后 3（tool_result + answer + follow-up）
    // 但 tool_result 是 orphan（其 tool_use 在 index=1 被丢）→ 应该往右挪一个
    const dropped = c.compactKeepRecent(3);
    try std.testing.expect(dropped == 3); // 多丢一个 orphan tool_result
    // 投影:全量保留,活跃窗口首条不是孤儿 tool_result。
    try std.testing.expect(c.len() == 5);
    try std.testing.expectEqual(@as(usize, 3), c.activeStart());
    const active = c.activeMessages();
    try std.testing.expectEqual(@as(usize, 2), active.len);
    try std.testing.expectEqualStrings("answer", active[0].blocks[0].text);
    try std.testing.expectEqualStrings("follow up", active[1].blocks[0].text);
}

test "removeOldestForContextRecovery drops orphan tool_result boundary" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();

    const au_blks = try a.alloc(msg.Block, 1);
    au_blks[0] = .{ .tool_use = .{
        .id = try a.dupe(u8, "t1"),
        .name = try a.dupe(u8, "Read"),
        .input = try a.dupe(u8, "{}"),
    } };
    try c.append(.{ .role = .assistant, .blocks = au_blks });

    const ur_blks = try a.alloc(msg.Block, 1);
    ur_blks[0] = .{ .tool_result = .{
        .tool_use_id = try a.dupe(u8, "t1"),
        .content = try a.dupe(u8, "result"),
    } };
    try c.append(.{ .role = .user, .blocks = ur_blks });
    try c.appendText(.assistant, "after");

    const dropped = c.removeOldestForContextRecovery();
    try std.testing.expectEqual(@as(usize, 2), dropped);
    // 投影:全量保留,活跃窗口=最后一条 "after"。
    try std.testing.expectEqual(@as(usize, 3), c.len());
    try std.testing.expectEqual(@as(usize, 2), c.activeStart());
    const active = c.activeMessages();
    try std.testing.expectEqual(@as(usize, 1), active.len);
    try std.testing.expectEqualStrings("after", active[0].blocks[0].text);
}

test "replaceWithOwned swaps only after preview succeeds" {
    const a = std.testing.allocator;
    var live = Conversation.init(a);
    defer live.deinit();
    try live.appendText(.user, "old");

    var preview = try live.cloneInto(a);
    defer preview.deinit();
    try preview.appendText(.assistant, "new");
    try std.testing.expect(live.replaceWithOwned(&preview));

    try std.testing.expectEqual(@as(usize, 2), live.len());
    try std.testing.expectEqual(@as(usize, 0), preview.len());
    try std.testing.expectEqualStrings("old", live.messages.items[0].blocks[0].text);
    try std.testing.expectEqualStrings("new", live.messages.items[1].blocks[0].text);
}

test "replaceWithOwned rejects replacement with different allocator" {
    const a = std.testing.allocator;
    var live = Conversation.init(a);
    defer live.deinit();
    try live.appendText(.user, "old");

    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var replacement = Conversation.init(fba.allocator());
    defer replacement.deinit();
    try replacement.appendText(.assistant, "new");

    try std.testing.expect(!live.replaceWithOwned(&replacement));
    try std.testing.expectEqual(@as(usize, 1), live.len());
    try std.testing.expectEqual(@as(usize, 1), replacement.len());
    try std.testing.expectEqualStrings("old", live.messages.items[0].blocks[0].text);
    try std.testing.expectEqualStrings("new", replacement.messages.items[0].blocks[0].text);
}

test "replaceWithOwnedIfSuffixUnchanged accepts unchanged suffix" {
    const a = std.testing.allocator;
    var live = Conversation.init(a);
    defer live.deinit();
    try live.appendText(.user, "old 1");
    try live.appendText(.assistant, "old 2");
    try live.appendText(.user, "keep");

    var preview = try live.cloneForCompactPreview(a, 1);
    defer preview.deinit();
    _ = preview.conversation.compactKeepRecent(1);
    try preview.conversation.appendText(.assistant, "summary");

    try std.testing.expect(live.replaceWithOwnedIfSuffixUnchanged(&preview.suffix, &preview.conversation));
    // 投影:preview 的 boundary 一并被采用(replaceWithOwnedLocked 的 P1.5 修复);live 全量保留,
    // 活跃窗口 = keep + summary。boundary 未采用 → 压缩会白做(这条正是回归防线)。
    try std.testing.expectEqual(@as(usize, 4), live.len());
    try std.testing.expectEqual(@as(usize, 0), preview.conversation.len());
    try std.testing.expectEqual(@as(usize, 2), live.activeStart());
    const active = live.activeMessages();
    try std.testing.expectEqual(@as(usize, 2), active.len);
    try std.testing.expectEqualStrings("keep", active[0].blocks[0].text);
    try std.testing.expectEqualStrings("summary", active[1].blocks[0].text);
}

test "replaceWithOwnedIfSuffixUnchanged rejects concurrent append" {
    const a = std.testing.allocator;
    var live = Conversation.init(a);
    defer live.deinit();
    try live.appendText(.user, "old 1");
    try live.appendText(.assistant, "old 2");
    try live.appendText(.user, "keep");

    var preview = try live.cloneForCompactPreview(a, 1);
    defer preview.deinit();
    _ = preview.conversation.compactKeepRecent(1);
    try preview.conversation.appendText(.assistant, "summary");

    try live.appendText(.user, "concurrent new message");
    try std.testing.expect(!live.replaceWithOwnedIfSuffixUnchanged(&preview.suffix, &preview.conversation));
    try std.testing.expectEqual(@as(usize, 4), live.len());
    try std.testing.expectEqualStrings("concurrent new message", live.messages.items[3].blocks[0].text);
    try std.testing.expect(preview.conversation.len() > 0);
}

test "cloneInto 深拷贝独立 + 源 reset 不影响副本 + 无泄漏" {
    const a = std.testing.allocator;
    var src = Conversation.init(a);
    // 含 text + tool_use + tool_result 的多消息对话。
    try src.appendText(.user, "q1");
    const au = try a.alloc(msg.Block, 1);
    au[0] = .{ .tool_use = .{ .id = try a.dupe(u8, "t1"), .name = try a.dupe(u8, "Bash"), .input = try a.dupe(u8, "{}") } };
    try src.append(.{ .role = .assistant, .blocks = au });
    const ur = try a.alloc(msg.Block, 1);
    ur[0] = .{ .tool_result = .{ .tool_use_id = try a.dupe(u8, "t1"), .content = try a.dupe(u8, "out"), .is_error = false } };
    try src.append(.{ .role = .user, .blocks = ur });

    var copy = try src.cloneInto(a);
    defer copy.deinit();
    try std.testing.expectEqual(@as(usize, 3), copy.len());
    // 指针不共享:首消息 text 字节地址不同。
    try std.testing.expect(src.messages.items[0].blocks[0].text.ptr != copy.messages.items[0].blocks[0].text.ptr);

    // 源 reset(deinit + 重 init)→ 副本仍完整有效。
    src.deinit();
    src = Conversation.init(a);
    src.deinit();
    try std.testing.expectEqualStrings("q1", copy.messages.items[0].blocks[0].text);
    try std.testing.expectEqualStrings("Bash", copy.messages.items[1].blocks[0].tool_use.name);
    try std.testing.expectEqualStrings("out", copy.messages.items[2].blocks[0].tool_result.content);
}

test "cloneInto 继承投影状态(boundary+summary)供后台续跑" {
    const a = std.testing.allocator;
    var src = Conversation.init(a);
    defer src.deinit();
    try src.appendText(.user, "m1");
    try src.appendText(.assistant, "m2");
    try src.appendText(.user, "m3");
    _ = src.compactKeepRecent(1); // boundary → 2,活跃 = [m3]
    src.setCompactSummary(try a.dupe(u8, "prior summary"));

    try std.testing.expectEqual(@as(usize, 3), src.len()); // 投影:全量保留
    try std.testing.expectEqual(@as(usize, 2), src.activeStart());

    var copy = try src.cloneInto(a);
    defer copy.deinit();
    // 全量消息 + 投影状态都随 clone 转移,后台 job 才不会重发已压缩的历史。
    try std.testing.expectEqual(@as(usize, 3), copy.len());
    try std.testing.expectEqual(@as(usize, 2), copy.compact_boundary);
    try std.testing.expect(copy.compact_summary != null);
    try std.testing.expectEqualStrings("prior summary", copy.compact_summary.?);
    // summary 深拷贝:字节地址不共享。
    try std.testing.expect(src.compact_summary.?.ptr != copy.compact_summary.?.ptr);
    const active = copy.activeMessages();
    try std.testing.expectEqual(@as(usize, 1), active.len);
    try std.testing.expectEqualStrings("m3", active[0].blocks[0].text);
}

test "totalTokens: image block 按 IMAGE_TOKEN_ESTIMATE 计入" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    const blocks = try a.alloc(msg.Block, 1);
    blocks[0] = .{ .image = .{
        .media_type = try a.dupe(u8, "image/png"),
        .data = try a.dupe(u8, "UE5HREFUQQ=="),
    } };
    try c.append(.{ .role = .user, .blocks = blocks });
    try std.testing.expect(c.totalTokens() >= IMAGE_TOKEN_ESTIMATE);
}

test "totalTokens: Read 图像形态 tool_result 按 IMAGE_TOKEN_ESTIMATE 计(fallback 不爆表)" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    const big = try a.alloc(u8, 400_000);
    defer a.free(big);
    @memset(big, 'A');
    const tr_content = try std.fmt.allocPrint(a, "{{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"{s}\"}}", .{big});
    const blocks = try a.alloc(msg.Block, 1);
    blocks[0] = .{ .tool_result = .{ .tool_use_id = try a.dupe(u8, "t1"), .content = tr_content } };
    try c.append(.{ .role = .user, .blocks = blocks });
    const total = c.totalTokens();
    try std.testing.expect(total >= IMAGE_TOKEN_ESTIMATE);
    try std.testing.expect(total < 50_000); // 远小于按字节计的 ~10 万
}
