//! Canonical Conversation compaction transaction shared by Run auto-compact
//! and Host manual compact. All provider work happens against an owned preview;
//! the live Conversation changes at exactly one suffix-checked commit point.

const std = @import("std");
const Conversation = @import("conversation.zig").Conversation;
const msg = @import("message.zig");
const compact_summary = @import("compact_summary.zig");
const request_gate = @import("request_gate.zig");
const provider_mod = @import("../api/provider.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const UsageDelta = @import("../api/stream.zig").UsageDelta;
const util_time = @import("../util/time.zig");

pub const Outcome = enum {
    compacted,
    no_change,
    degraded,
    aborted,
};

pub const SummaryRequestOutcome = enum {
    success,
    degraded,
    aborted,
};

pub const SummaryRequest = struct {
    elapsed_ms: u64,
    outcome: SummaryRequestOutcome,
};

pub const Report = struct {
    outcome: Outcome,
    before_tokens: usize,
    after_tokens: usize,
    dropped: usize,
    kept: usize,
    usage: UsageDelta,
    emergency_reduced: bool = false,
    /// Tokens added by the realized summary over the no-summary lower bound.
    /// A caller can feed this back as the next optimistic reserve, preventing
    /// another paid request until the newly droppable prefix can absorb the
    /// last observed summary overhead and still meet the savings gate.
    summary_overhead_tokens: usize = 0,
    /// Present iff the kernel actually crossed the paid/provider boundary.
    /// Optimistic preview skips leave this null and therefore cannot be
    /// mistaken for model traffic by evaluation telemetry.
    summary_request: ?SummaryRequest = null,
};

pub const Estimator = struct {
    ctx: *anyopaque,
    estimate_fn: *const fn (ctx: *anyopaque, conversation: *const Conversation) usize,

    pub fn estimate(self: Estimator, conversation: *const Conversation) usize {
        return self.estimate_fn(self.ctx, conversation);
    }
};

pub const CommitResult = enum {
    committed,
    aborted,
    concurrent_mutation,
};

pub const Committer = struct {
    ctx: *anyopaque,
    commit_fn: *const fn (
        ctx: *anyopaque,
        live: *Conversation,
        suffix: *const Conversation.SuffixSnapshot,
        replacement: *Conversation,
        abort: *const AbortSignal,
    ) CommitResult,

    fn commit(
        self: Committer,
        live: *Conversation,
        suffix: *const Conversation.SuffixSnapshot,
        replacement: *Conversation,
        abort: *const AbortSignal,
    ) CommitResult {
        return self.commit_fn(
            self.ctx,
            live,
            suffix,
            replacement,
            abort,
        );
    }
};

pub const Options = struct {
    keep_recent: usize,
    model_override: ?[]const u8 = null,
    task_anchor: ?[]const u8 = null,
    estimator: ?Estimator = null,
    minimum_saved_percent: usize = 5,
    minimum_summary_reserve_tokens: usize = 0,
    request_gate: ?request_gate.Gate = null,
    target_tokens: ?usize = null,
    committer: ?Committer = null,
    /// Token budget for carrying the user's own requests verbatim through the
    /// summary (compact_summary.appendUserPrompts). 0 = off, which keeps the
    /// public/manual compaction contract exactly as before: the summary alone
    /// replaces the prefix. The agent loop's automatic compaction turns it on.
    preserve_user_prompts_tokens: usize = 0,
};

pub const Error = error{
    OutOfMemory,
    ConcurrentMutation,
};

pub fn run(
    allocator: std.mem.Allocator,
    conversation: *Conversation,
    provider: provider_mod.Provider,
    abort: *const AbortSignal,
    options: Options,
) Error!Report {
    const before_tokens = estimate(options.estimator, conversation);
    if (abort.isAborted()) return terminal(.aborted, before_tokens, before_tokens, 0, conversation.activeMessages().len, .{});

    // A summary can only add tokens compared with dropping the same prefix
    // without one.  Prove that even this optimistic lower bound can meet the
    // savings gate before spending a model call.  This matters when fixed
    // system/tool overhead dominates a small conversation: the old path paid
    // for a summary, rejected it as <5% savings, then retried after every new
    // message without advancing the compact boundary.
    var optimistic_after_tokens = before_tokens;
    if (options.minimum_saved_percent > 0) {
        var optimistic = conversation.cloneForCompactPreview(
            allocator,
            options.keep_recent,
        ) catch return error.OutOfMemory;
        defer optimistic.deinit();
        const NoSummary = struct {
            fn summarize(_: *@This(), _: []const msg.Message) ?[]u8 {
                return null;
            }
        };
        var no_summary = NoSummary{};
        const optimistic_report = optimistic.conversation.compactWithSummaryReport(
            options.keep_recent,
            &no_summary,
            NoSummary.summarize,
        ) catch return error.OutOfMemory;
        optimistic_after_tokens = estimate(
            options.estimator,
            &optimistic.conversation,
        );
        const reserved_after = optimistic_after_tokens +|
            options.minimum_summary_reserve_tokens;
        if (optimistic_report.dropped == 0 or !hasMinimumSavings(
            before_tokens,
            reserved_after,
            options.minimum_saved_percent,
        )) {
            return terminal(
                .no_change,
                before_tokens,
                before_tokens,
                0,
                conversation.activeMessages().len,
                .{},
            );
        }
    }

    var preview = conversation.cloneForCompactPreview(
        allocator,
        options.keep_recent,
    ) catch return error.OutOfMemory;
    defer preview.deinit();
    const before_active = preview.conversation.activeMessages().len;
    if (options.request_gate) |gate| {
        if (!gate.allows())
            return terminal(
                .aborted,
                before_tokens,
                before_tokens,
                0,
                before_active,
                .{},
            );
    }
    const SummaryContext = struct {
        allocator: std.mem.Allocator,
        provider: provider_mod.Provider,
        abort: *const AbortSignal,
        model_override: ?[]const u8,
        task_anchor: ?[]const u8,
        preserve_user_prompts_tokens: usize,
        usage: UsageDelta = .{},
        aborted: bool = false,
        degraded: bool = false,
        summary_request: ?SummaryRequest = null,

        fn summarize(self: *@This(), drop_msgs: []const msg.Message) ?[]u8 {
            const started_ns = util_time.nowNs();
            const result = compact_summary.summarizeAbortable(
                self.allocator,
                self.provider,
                drop_msgs,
                self.model_override,
                self.abort,
                &self.usage,
            ) catch {
                self.summary_request = .{
                    .elapsed_ms = elapsedMs(started_ns),
                    .outcome = .aborted,
                };
                self.aborted = true;
                return null;
            };
            const summary = result orelse {
                self.summary_request = .{
                    .elapsed_ms = elapsedMs(started_ns),
                    .outcome = .degraded,
                };
                self.degraded = true;
                // No model summary: still carry the user's own requests (and
                // the task anchor) across the boundary instead of nothing.
                if (self.preserve_user_prompts_tokens == 0) return null;
                const fallback = compact_summary.userPromptsOnly(
                    self.allocator,
                    drop_msgs,
                    self.preserve_user_prompts_tokens,
                ) orelse return null;
                return compact_summary.appendTaskAnchor(
                    self.allocator,
                    fallback,
                    self.task_anchor,
                );
            };
            self.summary_request = .{
                .elapsed_ms = elapsedMs(started_ns),
                .outcome = .success,
            };
            const with_anchor = compact_summary.appendTaskAnchor(
                self.allocator,
                summary,
                self.task_anchor,
            );
            if (self.preserve_user_prompts_tokens == 0) return with_anchor;
            return compact_summary.appendUserPrompts(
                self.allocator,
                with_anchor,
                drop_msgs,
                self.preserve_user_prompts_tokens,
            );
        }
    };
    var summary_ctx = SummaryContext{
        .allocator = allocator,
        .provider = provider,
        .abort = abort,
        .model_override = options.model_override,
        .task_anchor = options.task_anchor,
        .preserve_user_prompts_tokens = options.preserve_user_prompts_tokens,
    };
    const compact_report = preview.conversation.compactWithSummaryReport(
        options.keep_recent,
        &summary_ctx,
        SummaryContext.summarize,
    ) catch return error.OutOfMemory;
    if (summary_ctx.aborted or abort.isAborted()) {
        var report = terminal(
            .aborted,
            before_tokens,
            before_tokens,
            0,
            before_active,
            summary_ctx.usage,
        );
        report.summary_request = summary_ctx.summary_request;
        return report;
    }
    if (compact_report.dropped == 0) {
        var report = terminal(
            .no_change,
            before_tokens,
            before_tokens,
            0,
            before_active,
            summary_ctx.usage,
        );
        report.summary_request = summary_ctx.summary_request;
        return report;
    }

    var after_tokens = estimate(options.estimator, &preview.conversation);
    const summary_overhead_tokens = if (after_tokens > optimistic_after_tokens)
        after_tokens - optimistic_after_tokens
    else
        0;
    if (compact_report.summary_used and !hasMinimumSavings(
        before_tokens,
        after_tokens,
        options.minimum_saved_percent,
    )) {
        var report = terminal(
            .no_change,
            before_tokens,
            before_tokens,
            0,
            before_active,
            summary_ctx.usage,
        );
        report.summary_request = summary_ctx.summary_request;
        report.summary_overhead_tokens = summary_overhead_tokens;
        return report;
    }
    if (abort.isAborted()) {
        var report = terminal(
            .aborted,
            before_tokens,
            before_tokens,
            0,
            before_active,
            summary_ctx.usage,
        );
        report.summary_request = summary_ctx.summary_request;
        report.summary_overhead_tokens = summary_overhead_tokens;
        return report;
    }
    var emergency_reduced = false;
    if (options.target_tokens) |target| {
        if (after_tokens > target) {
            const reduction = preview.conversation.microcompactToolResultsByRecentResults(0);
            emergency_reduced = reduction.changed();
            if (emergency_reduced)
                after_tokens = estimate(options.estimator, &preview.conversation);
        }
    }
    const commit_result = if (options.committer) |committer|
        committer.commit(
            conversation,
            &preview.suffix,
            &preview.conversation,
            abort,
        )
    else
        defaultCommit(
            conversation,
            &preview.suffix,
            &preview.conversation,
            abort,
        );
    switch (commit_result) {
        .committed => {},
        .aborted => {
            var report = terminal(
                .aborted,
                before_tokens,
                before_tokens,
                0,
                before_active,
                summary_ctx.usage,
            );
            report.summary_request = summary_ctx.summary_request;
            report.summary_overhead_tokens = summary_overhead_tokens;
            return report;
        },
        .concurrent_mutation => return error.ConcurrentMutation,
    }

    var report = terminal(
        if (summary_ctx.degraded) .degraded else .compacted,
        before_tokens,
        after_tokens,
        compact_report.dropped,
        conversation.activeMessages().len,
        summary_ctx.usage,
    );
    report.emergency_reduced = emergency_reduced;
    report.summary_request = summary_ctx.summary_request;
    report.summary_overhead_tokens = summary_overhead_tokens;
    return report;
}

fn elapsedMs(started_ns: util_time.Nanos) u64 {
    const now = util_time.nowNs();
    if (started_ns <= 0 or now <= started_ns) return 0;
    return @intCast(@divTrunc(now - started_ns, std.time.ns_per_ms));
}

fn defaultCommit(
    live: *Conversation,
    suffix: *const Conversation.SuffixSnapshot,
    replacement: *Conversation,
    abort: *const AbortSignal,
) CommitResult {
    if (abort.isAborted()) return .aborted;
    return if (live.replaceWithOwnedIfSuffixUnchanged(suffix, replacement))
        .committed
    else
        .concurrent_mutation;
}

fn estimate(estimator: ?Estimator, conversation: *const Conversation) usize {
    return if (estimator) |value|
        value.estimate(conversation)
    else
        conversation.totalTokens();
}

fn terminal(
    outcome: Outcome,
    before_tokens: usize,
    after_tokens: usize,
    dropped: usize,
    kept: usize,
    usage: UsageDelta,
) Report {
    return .{
        .outcome = outcome,
        .before_tokens = before_tokens,
        .after_tokens = after_tokens,
        .dropped = dropped,
        .kept = kept,
        .usage = usage,
    };
}

fn hasMinimumSavings(before: usize, after: usize, percent: usize) bool {
    if (percent == 0) return true;
    if (percent > 100) return false;
    if (before == 0 or after >= before) return false;
    const saved = before - after;
    const whole = (before / 100) * percent;
    const remainder = before % 100;
    const remainder_required = std.math.divCeil(
        usize,
        remainder * percent,
        100,
    ) catch unreachable;
    const required = whole + remainder_required;
    return saved >= required;
}

test "minimum savings is exact and overflow safe" {
    try std.testing.expect(hasMinimumSavings(1000, 949, 5));
    try std.testing.expect(hasMinimumSavings(1000, 950, 5));
    try std.testing.expect(!hasMinimumSavings(1000, 951, 5));
    try std.testing.expect(!hasMinimumSavings(1000, 1000, 5));
    try std.testing.expect(!hasMinimumSavings(0, 0, 5));
    try std.testing.expect(hasMinimumSavings(
        std.math.maxInt(usize),
        0,
        100,
    ));
}
