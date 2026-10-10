//! BashOutput：查询后台作业的输出和状态。
//!
//! input 参数：
//!   - `job_id` (必填)：12-hex job id
//!   - `stdout`：true/false，默认 true
//!   - `stderr`：true/false，默认 true
//!   - `stdout_since_byte`：从 stdout 文件的第 N 字节开始读（增量）。省略时续接该 job 的记忆游标。
//!   - `stderr_since_byte`：同上对 stderr。
//!   - `max_bytes`：单次读出上限。**没有固定默认值**,省略时由 `ctx.result_budget`
//!     派生(200K window 为 24488,预算下限为 7680);硬上限 262144。读到的内容还会
//!     按同一预算裁剪,余量走 `*_next_offset`。registry 里那份 property description
//!     由 `tests/component/tool_schema_coverage_test.zig` 绑回这些常量,不会再分叉。
//!   - `wait_ms`：运行中作业最多等多久。省略默认 30 秒，0 为快照，最大 600 秒。
//!   - `until`：除作业结束与 `wait_ms` 到期外，什么还能让等待提前返回：
//!     `exit`(默认,只等结束;未读积压已填满一页则立即返回 `backlog`) /
//!     `output`(任一未读字节,流式读 Monitor 用) /
//!     `quiet`(输出停顿 `quiet_ms`;积压填满一页同样返回 `backlog`) /
//!     `pattern`(游标后的输出出现字面子串 `pattern`;积压不打断,命中位置见 `pattern_match`)。
//!     只给 `quiet_ms` 或只给 `pattern` 时推断为对应模式;与 `until` 冲突即报错。
//!   - `quiet_ms`：`until=quiet` 的停顿时长,默认 2000,范围 200..600000(按 200ms 采样)。
//!   - `pattern`：`until=pattern` 的字面子串(非正则),1..256 字节。
//!
//! output:两条通道对称,各带同样的四个字段(此前这里只列了 stdout 的
//! encoding/next_offset,stderr 的两个实际会发却没写——见 `writeChannel` 调用处)。
//!   {
//!     "job_id":"...","status":"running|exited|killed","exit_code":N?,
//!     "stdout":"...","stdout_encoding":"utf-8"|"base64",
//!     "stdout_total_bytes":N,"stdout_next_offset":N,"stdout_truncated":bool,
//!     "stderr":"...","stderr_encoding":"utf-8"|"base64",
//!     "stderr_total_bytes":N,"stderr_next_offset":N,"stderr_truncated":bool,
//!     "waited_ms":N,
//!     "returned_on":"snapshot|exit|output|quiet|pattern|backlog|deadline",
//!     "pattern_match":{"channel":"stdout|stderr","offset":N}?,
//!     "pattern_searched_to":{"stdout":N,"stderr":N}?,   (搜索没追上输出时的进度)
//!     "poll_guard":{"low_yield_polls":N,"until":"exit|pattern","min_wait_ms":N}?,
//!     "note":"..."?   (仅作业仍在运行时)
//!   }
//!
//! 轮询守卫:同一作业连续 `POLL_GUARD_STREAK` 次"要求等待、作业仍在跑、只返回不到
//! `POLL_GUARD_LOW_YIELD_BYTES` 字节"之后,后续等待调用不再被进度字节唤醒(`output`/
//! `quiet` 改为 `exit`,`pattern` 保留),等待上限抬到 `guardWaitMs(streak)`(作业结束仍
//! 立即返回)。作业结束、命中 pattern、整页输出清零计数;未受守卫时足量输出也清零,
//! 受守卫时攒下的进度字节不清零(否则倍增永远到不了)。`wait_ms=0` 快照不计数也不受守卫;
//! 上次返回后隔了 `POLL_GUARD_IDLE_RESET_MS` 才再查,不算连续。
//!
//! 续读只认 `*_next_offset`:下一次传 `stdout_since_byte = 上次 stdout_next_offset`。
//! 它等于 `since + 本次实际展示的字节数`。
//! `*_total_bytes` 是文件当前大小,**不是游标**——拿它当游标会跳过"本次展示到文件末尾"
//! 之间的全部内容(读取按预算限界后,这段通常不为空)。
//! `truncated=true` 表示本次没读完,继续从 `*_next_offset` 读即可;提高 `max_bytes`
//! 只在预算允许时有用,并不能替代游标。
//! `*_encoding` 按通道各自判定:该通道本次展示的字节不是合法 UTF-8 就发 base64
//! (`stdout` 与 `stderr` 可以一个 base64 一个 utf-8)。

const std = @import("std");
const builtin = @import("builtin");
const time = @import("../util/time.zig");
const pfs = @import("platform").fs;
const common = @import("common.zig");
const ToolContext = @import("context.zig").ToolContext;
const result_budget = @import("../core/result_budget.zig");
const util_json = @import("../util/json.zig");
const utf8 = @import("../util/utf8.zig");
const job_registry = @import("../core/job_registry.zig");
const JobRegistry = job_registry.JobRegistry;
const JobEntry = job_registry.JobEntry;

/// 单次 tool_result 中 stdout/stderr 的默认字节上限；避免 100MB 文件塞爆 context。
/// Fixed JSON scaffolding of one BashOutput result: job id, status, exit code,
/// both channels' byte counters and truncation flags.
pub const ENVELOPE_OVERHEAD_BYTES: result_budget.Encoded = .of(512);
pub const MAX_MAX_BYTES: usize = 256 * 1024;
pub const DEFAULT_WAIT_MS: usize = 30_000;
pub const MAX_WAIT_MS: usize = 600_000;
const WAIT_POLL_SLICE_MS: u64 = 200;

// 2026-09-19 incident (session 000001a0b86114522f8eb6a0): 375 one-round-trip
// polls kept returning identical running snapshots. Long-polling plus remembered
// cursors makes one visible call wait for progress instead of replaying the spool.
// 2026-09-19 事故:375 次轮询反复返回相同 running 快照;长轮询与记忆游标合并修复。
//
// 2026-10 follow-up: the long poll woke on *any* new byte, so a script that
// prints a progress line every 10 s turned one wait_ms=300000 call into a model
// turn per line - one 300 s job took 32 turns, and across 13.5K turns of one
// project 17% were BashOutput polls, 72% of the `running` ones carrying under
// 200 new bytes. Waiting now defaults to exit (`until`), and the poll guard
// stops an explicit `output` loop from doing the same.

pub const DEFAULT_QUIET_MS: u64 = 2_000;
/// `quiet_ms` floor: output growth is sampled once per poll slice, so a
/// shorter pause cannot be told apart from this one.
pub const MIN_QUIET_MS: u64 = WAIT_POLL_SLICE_MS;
pub const MAX_PATTERN_BYTES: usize = 256;
/// Bytes scanned per read when looking for `pattern`.
const SCAN_CHUNK_BYTES: usize = 16 * 1024;
/// Bytes one pattern check scans before yielding, so a cursor far behind a
/// multi-gigabyte spool neither blocks an abort nor stalls the call: the wait
/// loop resumes the scan on its next pass without sleeping.
const SCAN_BUDGET_BYTES: u64 = 8 * 1024 * 1024;

/// Low-yield waiting polls of one running job before the guard engages.
pub const POLL_GUARD_STREAK: u8 = 3;
/// An unguarded waiting poll that shows fewer bytes than this (both channels
/// together) while the job keeps running counts as low-yield: a progress
/// tick, not output worth a model turn.
pub const POLL_GUARD_LOW_YIELD_BYTES: u64 = 256;
/// The guard's minimum wait at `POLL_GUARD_STREAK`, doubling with each further
/// low-yield poll up to `POLL_GUARD_MAX_WAIT_MS`.
pub const POLL_GUARD_BASE_WAIT_MS: u64 = 30_000;
pub const POLL_GUARD_MAX_WAIT_MS: u64 = 300_000;
/// A streak only continues while each poll starts within this long of the
/// previous one returning; a longer gap is the model doing other work, an
/// occasional check rather than a loop. Measured on the same project's 1,373
/// pairs of consecutive polls of one job: median 4.8 s, p95 13.8 s, 98.5%
/// within 60 s.
pub const POLL_GUARD_IDLE_RESET_MS: time.Millis = 60_000;

/// What ends a waiting call besides job exit, abort and `wait_ms`.
pub const UntilKind = enum { exit, output, quiet, pattern };

/// `until` values as the schema advertises them, in declaration order.
pub const UNTIL_VALUES: []const []const u8 = blk: {
    const fields = @typeInfo(UntilKind).@"enum".fields;
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |field, i| names[i] = field.name;
    const final = names;
    break :blk &final;
};

pub const Until = union(UntilKind) {
    /// Only the job's end (or the deadline) returns.
    exit,
    /// Any unread byte on a requested channel returns (streaming).
    output,
    /// Requested channels not growing for this many ms returns.
    quiet: u64,
    /// This literal occurring in output past the read cursor returns.
    pattern: []const u8,
};

/// Why a call returned, rendered as `returned_on`.
pub const ReturnedOn = enum {
    snapshot,
    exit,
    output,
    quiet,
    pattern,
    /// Unread output already fills this result, so waiting could not change
    /// what it shows; page through it first.
    backlog,
    deadline,
};

pub const Channel = enum { stdout, stderr };

/// Where `pattern` matched: the channel and the byte offset of the match,
/// which may lie past what this result shows.
pub const PatternMatch = struct { channel: Channel, offset: u64 };

/// How far a pattern search got when it could not catch up with the output
/// before the call returned: per requested channel, the offset searched to.
/// Passing it as `*_since_byte` resumes the search there.
pub const SearchFrontier = struct { stdout: ?u64, stderr: ?u64 };

/// What a pattern search established by the time the call returned: where
/// it matched, or how far it got without matching. Never both - the envelope
/// reservation counts on it - and absent when a finished search found
/// nothing.
pub const PatternResult = union(enum) {
    match: PatternMatch,
    searched_to: SearchFrontier,
};

/// The guard's minimum wait for a job with `streak` low-yield polls
/// (`streak >= POLL_GUARD_STREAK`).
pub fn guardWaitMs(streak: u8) u64 {
    var wait_ms = guardBaseWaitMs();
    var step = POLL_GUARD_STREAK;
    while (step < streak and wait_ms < POLL_GUARD_MAX_WAIT_MS) : (step += 1) wait_ms *= 2;
    return @min(wait_ms, POLL_GUARD_MAX_WAIT_MS);
}

/// Test seam: tests shorten the guard's base wait so a guarded wait can run
/// out in well under a second. Only test builds have the variable at all.
var guard_base_wait_ms_for_test: if (builtin.is_test) u64 else void = if (builtin.is_test) POLL_GUARD_BASE_WAIT_MS else {};

fn guardBaseWaitMs() u64 {
    return if (builtin.is_test) guard_base_wait_ms_for_test else POLL_GUARD_BASE_WAIT_MS;
}

/// Test seam: tests lengthen the poll slice so "slept between slices" is
/// measurably different from "did not", independent of machine load.
var poll_slice_ms_for_test: if (builtin.is_test) u64 else void = if (builtin.is_test) WAIT_POLL_SLICE_MS else {};

fn pollSliceMs() u64 {
    return if (builtin.is_test) poll_slice_ms_for_test else WAIT_POLL_SLICE_MS;
}

/// Every argument, read from one JSON parse. Integer fields also accept a
/// string of digits and the channel flags the strings "true"/"false", as the
/// field scraper this replaced did; null means "not given" for every field.
const Args = struct {
    job_id: []const u8,
    stdout: bool,
    stderr: bool,
    stdout_since: ?usize,
    stderr_since: ?usize,
    wait_ms: ?usize,
    max_bytes: ?usize,
    until: Until,
};

/// How much one result can show: each channel reads at most `max_bytes`,
/// and both share `allowance_raw` bytes of rendered output.
const Page = struct {
    max_bytes: usize,
    allowance_raw: u64,
    /// Under the guard a channel's read only counts as a full page if it can
    /// hold more than a progress tick; otherwise an explicit tiny max_bytes
    /// would end every guarded wait on a few bytes.
    guarded: bool = false,

    fn channelFull(self: Page, pending: u64) bool {
        if (pending < self.max_bytes) return false;
        return !self.guarded or self.max_bytes >= POLL_GUARD_LOW_YIELD_BYTES;
    }
};

/// The channels a call reads, each with the cursor it reads from; null means
/// the channel was not requested.
const Reads = struct {
    stdout: ?u64,
    stderr: ?u64,

    fn any(self: Reads) bool {
        return self.stdout != null or self.stderr != null;
    }

    fn unread(self: Reads, job: JobEntry) bool {
        if (self.stdout) |since| if ((fileSize(job.stdout_path) catch 0) > since) return true;
        if (self.stderr) |since| if ((fileSize(job.stderr_path) catch 0) > since) return true;
        return false;
    }

    /// The requested spools' combined size, or null when one could not be
    /// measured - a transient open failure, which must not read as growth.
    fn spoolBytes(self: Reads, job: JobEntry) ?u64 {
        var total: u64 = 0;
        if (self.stdout != null) total += fileSize(job.stdout_path) catch return null;
        if (self.stderr != null) total += fileSize(job.stderr_path) catch return null;
        return total;
    }

    /// Each requested channel's spool and the cursor it is read from.
    fn channels(self: Reads, job: JobEntry) [2]?Pending {
        return .{
            if (self.stdout) |since| .{ .path = job.stdout_path, .since = since } else null,
            if (self.stderr) |since| .{ .path = job.stderr_path, .since = since } else null,
        };
    }
};

const Pending = struct { path: []const u8, since: u64 };

/// JSON escaping grows a byte at most this much (`\u001b`); base64 grows it
/// by 4:3. Below `allowance / MAX_ESCAPE_GROWTH` unread bytes no encoding can
/// fill a result.
const MAX_ESCAPE_GROWTH: u64 = 6;

/// Whether unread output already fills a result, priced the way `execute`
/// renders it: a channel holding a full read, or the channels' encoded cost
/// reaching the shared allowance. Raw bytes alone undercount - a base64
/// channel costs 4:3 and an ANSI colour code's ESC costs six bytes - so past
/// the cheap bounds it reads the pending page and prices it. The answer is
/// kept until the spools grow, so a wait does not re-read unchanged output.
const BacklogCheck = struct {
    reads: Reads,
    page: Page,
    checked_size: ?u64 = null,
    full: bool = false,

    fn fills(self: *BacklogCheck, allocator: std.mem.Allocator, job: JobEntry) bool {
        const size = self.reads.spoolBytes(job) orelse return self.full;
        if (self.checked_size) |checked| if (checked == size) return self.full;
        self.checked_size = size;
        self.full = self.measure(allocator, job);
        return self.full;
    }

    fn measure(self: *const BacklogCheck, allocator: std.mem.Allocator, job: JobEntry) bool {
        const allowance = self.page.allowance_raw;
        var pending_total: u64 = 0;
        for (self.reads.channels(job)) |maybe| if (maybe) |channel| {
            const pending = (fileSize(channel.path) catch 0) -| channel.since;
            if (self.page.channelFull(pending)) return true;
            // One read shows at most max_bytes of a channel; more pending
            // there cannot fill this result.
            pending_total += @min(pending, self.page.max_bytes);
        };
        if (pending_total >= allowance) return true;
        if (pending_total * MAX_ESCAPE_GROWTH < allowance) return false;
        var cost: u64 = 0;
        for (self.reads.channels(job)) |maybe| if (maybe) |channel| {
            var chunk = readFileRange(channel.path, @intCast(channel.since), self.page.max_bytes, allocator) catch return false;
            defer chunk.deinit(allocator);
            cost += result_budget.encodedCost(chunk.data, !std.unicode.utf8ValidateSlice(chunk.data)).raw();
        };
        return cost >= allowance;
    }
};

/// The guard in force for one call: the job had `streak` low-yield polls in a
/// row, so this call may wait up to `min_wait_ms` even when asked for less,
/// and only for exit (or the caller's pattern, or a full page).
const PollGuard = struct {
    streak: u8,
    min_wait_ms: u64,

    fn engage(status: job_registry.JobStatus, streak: u8, wait_ms: u64, reads: Reads) ?PollGuard {
        if (wait_ms == 0 or status != .running or !reads.any()) return null;
        if (streak < POLL_GUARD_STREAK) return null;
        return .{ .streak = streak, .min_wait_ms = guardWaitMs(streak) };
    }

    /// `output` and `quiet` wake on progress bytes, which is the loop being
    /// broken; `exit` already does not, and a pattern is a specific condition
    /// the caller asked for.
    fn until(requested: Until) Until {
        return switch (requested) {
            .output, .quiet => .exit,
            .exit, .pattern => requested,
        };
    }
};

const Wait = struct {
    returned_on: ReturnedOn,
    waited_ms: u64,
    pattern: ?PatternResult = null,
};

const GUARD_NOTE_EXIT = "Several polls in a row returned only a few bytes while this job kept running, so this call ignored progress output and waited up to the larger of wait_ms and poll_guard.min_wait_ms for the job to end. Its exit is announced to you automatically: do other work or end your turn instead of polling again.";
/// Only the exit is announced; a pattern is not. Ending the turn would wait
/// for the exit and never for the pattern, so this note does not suggest it.
const GUARD_NOTE_PATTERN = "Several polls in a row returned only a few bytes while this job kept running, so this call ignored other output and waited up to the larger of wait_ms and poll_guard.min_wait_ms for your pattern; it has not appeared yet. Poll again with the same pattern when you need it, do other work meanwhile, or KillShell the job.";

/// What a guarded result carries beyond the fixed envelope: the `poll_guard`
/// object (at most ~90 bytes) and the longer of the notes.
pub const GUARD_ENVELOPE_BYTES: result_budget.Encoded = .of(@max(GUARD_NOTE_EXIT.len, GUARD_NOTE_PATTERN.len) + 128);

pub fn execute(ctx: *const ToolContext, args_json: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    // One parse for every field. A scraped field and a parsed one disagreed
    // (`"wait_ms" : 0` with spaces was invisible to the scraper), and
    // `pattern` must be JSON-unescaped before it can match raw output.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            common.setErrorDetail(ctx.error_detail, allocator, "BashOutput arguments must be one JSON object with no duplicate keys", .{});
            return error.InvalidBashOutputArgs;
        },
    };
    defer parsed.deinit();
    const args = try parseArgs(ctx, parsed.value);
    const job_id = args.job_id;
    const registry = ctx.jobs orelse return error.JobsNotAvailable;

    // 先 reap 一次最新状态
    registry.reapExited();

    var job = registry.getForOwner(job_id, ctx.session) orelse return error.JobNotFound;
    const call_started = time.nowMs();

    const want_stdout = args.stdout;
    const want_stderr = args.stderr;
    const stdout_since = args.stdout_since orelse @as(usize, @intCast(job.stdout_read_offset));
    const stderr_since = args.stderr_since orelse @as(usize, @intCast(job.stderr_read_offset));
    const wait_ms_limit: u64 = args.wait_ms orelse DEFAULT_WAIT_MS;

    if (want_stdout) validateCursor(job.stdout_path, stdout_since) catch |err| {
        common.setErrorDetail(ctx.error_detail, allocator, "BashOutput stdout_since_byte is outside the spool", .{});
        return err;
    };
    if (want_stderr) validateCursor(job.stderr_path, stderr_since) catch |err| {
        common.setErrorDetail(ctx.error_detail, allocator, "BashOutput stderr_since_byte is outside the spool", .{});
        return err;
    };

    const reads: Reads = .{
        .stdout = if (want_stdout) @as(u64, @intCast(stdout_since)) else null,
        .stderr = if (want_stderr) @as(u64, @intCast(stderr_since)) else null,
    };
    const streak = activeStreak(job.poll_streak, call_started);
    const guard = PollGuard.engage(job.status, streak, wait_ms_limit, reads);

    // Default from the turn's budget, not a private constant. 64 KiB of
    // *source* bytes was chosen against "do not blow up the context", but the
    // per-result budget counts *rendered* bytes and tops out at 64 KiB too -
    // two different 64Ks - so a default read of a large enough job produced a
    // 65_717-byte result that the projection layer then spilled to an
    // artifact, handing the model an envelope instead of the output it had
    // just asked for.
    //
    // How often, measured rather than assumed: across 314 real BashOutput
    // results the median is 164 bytes and exactly one exceeded a 200K-window
    // budget. Most polls of a background job return very little. So this is a
    // tail case, not the common path - worth fixing because the failure is
    // silent and the fix is the same one `ReadArtifact` already got, not
    // because it was happening constantly. A guarded result also carries the
    // guard object and its note, so it reserves room for them.
    const overhead: result_budget.Encoded = if (guard != null)
        .of(ENVELOPE_OVERHEAD_BYTES.raw() + GUARD_ENVELOPE_BYTES.raw())
    else
        ENVELOPE_OVERHEAD_BYTES;
    const allowance = ctx.result_budget.payloadAllowance(overhead);
    const max_bytes = args.max_bytes orelse @max(1, @min(MAX_MAX_BYTES, allowance.raw()));
    const page: Page = .{ .max_bytes = max_bytes, .allowance_raw = allowance.raw(), .guarded = guard != null };

    // A BashOutput poll is deliberately demand-driven, and the wait stays
    // visible to the model instead of hiding in speculative prefetch.
    const until = if (guard != null) PollGuard.until(args.until) else args.until;
    const wait_limit_ms = if (guard) |g| @max(wait_ms_limit, g.min_wait_ms) else wait_ms_limit;
    const wait = try waitForJob(ctx, registry, job_id, &job, until, wait_limit_ms, reads, page);

    var stdout_chunk: Chunk = .{};
    var stderr_chunk: Chunk = .{};
    defer stdout_chunk.deinit(allocator);
    defer stderr_chunk.deinit(allocator);

    if (want_stdout) {
        stdout_chunk = readFileRange(job.stdout_path, stdout_since, max_bytes, allocator) catch .{};
    }
    if (want_stderr) {
        stderr_chunk = readFileRange(job.stderr_path, stderr_since, max_bytes, allocator) catch .{};
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"job_id\":");
    try util_json.writeJsonString(&aw.writer, job_id);
    try aw.writer.print(",\"status\":\"{s}\"", .{@tagName(job.status)});
    if (job.exit_code) |ec| {
        try aw.writer.print(",\"exit_code\":{d}", .{ec});
    }
    // `max_bytes` bounds the *read*; what the model is charged for is the
    // rendered result, so the two channels share one encoded allowance the
    // same way a completed Bash result's channels do. A channel cut here is
    // still "not finished", which is what `truncated` already means, so the
    // caller's `since_byte` loop needs no new concept.
    // A channel that is not valid UTF-8 cannot go into a JSON string: Zig's
    // writer escapes control bytes but passes 0x80..0xff through unchanged, so
    // `printf '\xff'` produced a result that is not UTF-8 at all. The completed
    // Bash envelope has always picked per channel and said which; this one
    // wrote everything as text. Budget, cut and render all read the same flag,
    // for the reason the completed path learned the hard way.
    const stdout_base64 = !std.unicode.utf8ValidateSlice(stdout_chunk.data);
    const stderr_base64 = !std.unicode.utf8ValidateSlice(stderr_chunk.data);
    const shares = result_budget.splitPair(
        allowance,
        result_budget.encodedCost(stdout_chunk.data, stdout_base64),
        result_budget.encodedCost(stderr_chunk.data, stderr_base64),
    );
    const stdout_shown = result_budget.headCut(stdout_chunk.data, shares.first, stdout_base64);
    const stderr_shown = result_budget.headCut(stderr_chunk.data, shares.second, stderr_base64);
    const stdout_next_offset: u64 = @as(u64, @intCast(stdout_since)) + stdout_shown.raw();
    const stderr_next_offset: u64 = @as(u64, @intCast(stderr_since)) + stderr_shown.raw();
    const stdout_truncated = stdout_chunk.truncated or stdout_shown.raw() < stdout_chunk.data.len;
    const stderr_truncated = stderr_chunk.truncated or stderr_shown.raw() < stderr_chunk.data.len;
    const page_full = (want_stdout and stdout_truncated) or (want_stderr and stderr_truncated);
    if (want_stdout) {
        try writeChannel(&aw.writer, allocator, "stdout", stdout_shown.head(stdout_chunk.data), stdout_base64);
        try writeChannelCursor(&aw.writer, .stdout, stdout_chunk.total_bytes, stdout_next_offset, stdout_truncated);
    }
    if (want_stderr) {
        try writeChannel(&aw.writer, allocator, "stderr", stderr_shown.head(stderr_chunk.data), stderr_base64);
        try writeChannelCursor(&aw.writer, .stderr, stderr_chunk.total_bytes, stderr_next_offset, stderr_truncated);
    }
    try writeWaitFields(&aw.writer, wait);
    if (guard) |g| try writeGuardFields(&aw.writer, g, until, guardNoteFits(job.status, wait, page_full));
    try aw.writer.writeAll("}");
    // Only advance after the bytes are owned by the caller; an OOM before
    // toOwnedSlice must leave the model's unread output available next time.
    const out = try aw.toOwnedSlice();
    registry.updateReadCursors(
        job_id,
        if (want_stdout) stdout_next_offset else null,
        if (want_stderr) stderr_next_offset else null,
    );
    const shown_bytes: u64 = (if (want_stdout) stdout_shown.raw() else 0) + (if (want_stderr) stderr_shown.raw() else 0);
    if (streakUpdate(job.status, wait.returned_on, guard != null, page_full, shown_bytes)) |update| switch (update) {
        .reset => registry.resetPollStreak(job_id),
        .extend => registry.extendPollStreak(job_id, call_started, time.nowMs(), POLL_GUARD_IDLE_RESET_MS),
    };
    if (job.status != .running) registry.markExitObserved(job_id);
    return out;
}

/// The guard's "stop polling" advice fits only a guarded wait that ran out on
/// a job still printing ticks; after the exit, a pattern or a full page there
/// is something to read first.
fn guardNoteFits(status: job_registry.JobStatus, wait: Wait, page_full: bool) bool {
    // An unfinished pattern search has not shown the pattern is absent.
    const unfinished = if (wait.pattern) |result| result == .searched_to else false;
    return status == .running and wait.returned_on == .deadline and !page_full and !unfinished;
}

fn writeChannelCursor(writer: *std.Io.Writer, channel: Channel, total_bytes: u64, next_offset: u64, truncated: bool) !void {
    const label = @tagName(channel);
    try writer.print(",\"{s}_total_bytes\":{d},\"{s}_next_offset\":{d},\"{s}_truncated\":{s}", .{
        label, total_bytes, label, next_offset, label, if (truncated) "true" else "false",
    });
}

fn writeWaitFields(writer: *std.Io.Writer, wait: Wait) !void {
    try writer.print(",\"waited_ms\":{d},\"returned_on\":\"{s}\"", .{ wait.waited_ms, @tagName(wait.returned_on) });
    const result = wait.pattern orelse return;
    switch (result) {
        .match => |match| try writer.print(",\"pattern_match\":{{\"channel\":\"{s}\",\"offset\":{d}}}", .{ @tagName(match.channel), match.offset }),
        .searched_to => |frontier| {
            try writer.writeAll(",\"pattern_searched_to\":{");
            if (frontier.stdout) |offset| try writer.print("\"stdout\":{d}", .{offset});
            if (frontier.stdout != null and frontier.stderr != null) try writer.writeAll(",");
            if (frontier.stderr) |offset| try writer.print("\"stderr\":{d}", .{offset});
            try writer.writeAll("}");
        },
    }
}

fn writeGuardFields(writer: *std.Io.Writer, guard: PollGuard, until: Until, with_note: bool) !void {
    try writer.print(
        ",\"poll_guard\":{{\"low_yield_polls\":{d},\"until\":\"{s}\",\"min_wait_ms\":{d}}}",
        .{ guard.streak, @tagName(until), guard.min_wait_ms },
    );
    if (with_note) {
        try writer.writeAll(",\"note\":");
        try util_json.writeJsonString(writer, if (until == .pattern) GUARD_NOTE_PATTERN else GUARD_NOTE_EXIT);
    }
}

fn parseArgs(ctx: *const ToolContext, value: std.json.Value) !Args {
    const allocator = ctx.allocator;
    if (value != .object) {
        common.setErrorDetail(ctx.error_detail, allocator, "BashOutput arguments must be one JSON object with no duplicate keys", .{});
        return error.InvalidBashOutputArgs;
    }
    const object = value.object;
    const job_id = switch (presentField(object, "job_id") orelse return error.MissingJobId) {
        .string => |text| text,
        else => {
            common.setErrorDetail(ctx.error_detail, allocator, "BashOutput job_id must be a string", .{});
            return error.InvalidJobId;
        },
    };
    const stdout = channelFlag(object, "stdout") catch {
        common.setErrorDetail(ctx.error_detail, allocator, "BashOutput stdout must be true or false", .{});
        return error.InvalidChannelFlag;
    };
    const stderr = channelFlag(object, "stderr") catch {
        common.setErrorDetail(ctx.error_detail, allocator, "BashOutput stderr must be true or false", .{});
        return error.InvalidChannelFlag;
    };
    const stdout_since = optionalCount(object, "stdout_since_byte") catch return sinceByteError(ctx);
    const stderr_since = optionalCount(object, "stderr_since_byte") catch return sinceByteError(ctx);
    const wait_ms = optionalCount(object, "wait_ms") catch null;
    if ((wait_ms == null and presentField(object, "wait_ms") != null) or (wait_ms orelse 0) > MAX_WAIT_MS) {
        common.setErrorDetail(ctx.error_detail, allocator, "BashOutput wait_ms must be an integer in 0..{d}", .{MAX_WAIT_MS});
        return error.InvalidWaitMs;
    }
    const max_bytes = optionalCount(object, "max_bytes") catch null;
    if ((max_bytes == null and presentField(object, "max_bytes") != null) or max_bytes == 0 or (max_bytes orelse 0) > MAX_MAX_BYTES) {
        common.setErrorDetail(ctx.error_detail, allocator, "BashOutput max_bytes must be an integer in 1..{d}", .{MAX_MAX_BYTES});
        return error.InvalidMaxBytes;
    }
    const until = try parseUntil(ctx, object);
    if (!stdout and !stderr) switch (until) {
        // Waiting for the exit needs no output; the other conditions do.
        .exit => {},
        .pattern => {
            common.setErrorDetail(ctx.error_detail, allocator, "BashOutput pattern needs stdout or stderr to search", .{});
            return error.InvalidPattern;
        },
        .output, .quiet => {
            common.setErrorDetail(ctx.error_detail, allocator, "BashOutput until output/quiet needs stdout or stderr to watch", .{});
            return error.InvalidUntil;
        },
    };
    return .{
        .job_id = job_id,
        .stdout = stdout,
        .stderr = stderr,
        .stdout_since = stdout_since,
        .stderr_since = stderr_since,
        .wait_ms = wait_ms,
        .max_bytes = max_bytes,
        .until = until,
    };
}

fn sinceByteError(ctx: *const ToolContext) error{InvalidSinceByte} {
    common.setErrorDetail(ctx.error_detail, ctx.allocator, "BashOutput *_since_byte must be a non-negative integer", .{});
    return error.InvalidSinceByte;
}

/// A non-negative integer field: a JSON integer or a string of digits.
fn optionalCount(object: std.json.ObjectMap, name: []const u8) error{NotACount}!?usize {
    const value = presentField(object, name) orelse return null;
    return switch (value) {
        .integer => |n| if (n >= 0) @intCast(n) else error.NotACount,
        .string => |text| std.fmt.parseInt(usize, text, 10) catch error.NotACount,
        else => error.NotACount,
    };
}

/// A channel flag: a JSON boolean or the string "true"/"false"; default true.
fn channelFlag(object: std.json.ObjectMap, name: []const u8) error{NotAFlag}!bool {
    const value = presentField(object, name) orelse return true;
    return switch (value) {
        .bool => |flag| flag,
        .string => |text| if (std.mem.eql(u8, text, "true")) true else if (std.mem.eql(u8, text, "false")) false else error.NotAFlag,
        else => error.NotAFlag,
    };
}

/// The low-yield polls that still count for a call starting at `now_ms`.
fn activeStreak(streak: job_registry.PollStreak, now_ms: time.Millis) u8 {
    if (now_ms - streak.last_ms > POLL_GUARD_IDLE_RESET_MS) return 0;
    return streak.low_yield;
}

const StreakUpdate = enum { reset, extend };

/// How a poll moves the job's low-yield streak; null leaves it alone.
/// - The exit and a matched pattern reset it.
/// - A waiting poll that shows fewer than `POLL_GUARD_LOW_YIELD_BYTES`
///   extends it, whatever ended the wait: a "full page" of an explicit tiny
///   max_bytes is still a progress tick.
/// - Showing more resets it, except under the guard unless the page is full:
///   a long guarded wait gathers ticks past the threshold, and resetting on
///   them would send the next polls back to one per tick.
/// - A snapshot is a status check, not a wait that came back empty-handed.
fn streakUpdate(
    status: job_registry.JobStatus,
    returned_on: ReturnedOn,
    guarded: bool,
    page_full: bool,
    shown_bytes: u64,
) ?StreakUpdate {
    if (status != .running) return .reset;
    return switch (returned_on) {
        .snapshot => null,
        // `exit` only comes back for a job that is no longer running, which
        // the first check already handled.
        .exit, .pattern => .reset,
        .backlog, .output, .quiet, .deadline => if (shown_bytes < POLL_GUARD_LOW_YIELD_BYTES)
            .extend
        else if (!guarded or page_full)
            .reset
        else
            .extend,
    };
}

/// Resolve `until`, `quiet_ms` and `pattern` into one condition. A lone
/// `quiet_ms` or `pattern` implies its mode; a field that contradicts an
/// explicit `until` is rejected rather than silently ignored.
fn parseUntil(ctx: *const ToolContext, object: std.json.ObjectMap) !Until {
    const allocator = ctx.allocator;
    const kind: ?UntilKind = if (presentField(object, "until")) |value| try parseUntilKind(ctx, value) else null;
    const quiet_ms: ?u64 = if (presentField(object, "quiet_ms") != null) try parseQuietMs(ctx, object) else null;
    const pattern: ?[]const u8 = if (presentField(object, "pattern")) |value| try parsePattern(ctx, value) else null;

    const resolved: UntilKind = kind orelse implied: {
        if (quiet_ms != null and pattern != null) {
            common.setErrorDetail(ctx.error_detail, allocator, "BashOutput takes quiet_ms or pattern, not both", .{});
            return error.InvalidUntil;
        }
        if (pattern != null) break :implied .pattern;
        if (quiet_ms != null) break :implied .quiet;
        break :implied .exit;
    };
    if (pattern != null and resolved != .pattern) {
        common.setErrorDetail(ctx.error_detail, allocator, "BashOutput pattern only applies to until \"pattern\"", .{});
        return error.InvalidPattern;
    }
    if (quiet_ms != null and resolved != .quiet) {
        common.setErrorDetail(ctx.error_detail, allocator, "BashOutput quiet_ms only applies to until \"quiet\"", .{});
        return error.InvalidQuietMs;
    }
    return switch (resolved) {
        .exit => .exit,
        .output => .output,
        .quiet => .{ .quiet = quiet_ms orelse DEFAULT_QUIET_MS },
        .pattern => .{ .pattern = pattern orelse {
            common.setErrorDetail(ctx.error_detail, allocator, "BashOutput until \"pattern\" needs a pattern", .{});
            return error.InvalidPattern;
        } },
    };
}

/// A field that is absent or JSON null is not given.
fn presentField(object: std.json.ObjectMap, name: []const u8) ?std.json.Value {
    const value = object.get(name) orelse return null;
    return if (value == .null) null else value;
}

fn parseUntilKind(ctx: *const ToolContext, value: std.json.Value) !UntilKind {
    if (value == .string) if (std.meta.stringToEnum(UntilKind, value.string)) |kind| return kind;
    common.setErrorDetail(ctx.error_detail, ctx.allocator, "BashOutput until must be one of \"exit\", \"output\", \"quiet\", \"pattern\"", .{});
    return error.InvalidUntil;
}

fn parseQuietMs(ctx: *const ToolContext, object: std.json.ObjectMap) !u64 {
    const parsed: ?usize = optionalCount(object, "quiet_ms") catch null;
    if (parsed) |ms| if (ms >= MIN_QUIET_MS and ms <= MAX_WAIT_MS) return ms;
    common.setErrorDetail(ctx.error_detail, ctx.allocator, "BashOutput quiet_ms must be in {d}..{d}", .{ MIN_QUIET_MS, MAX_WAIT_MS });
    return error.InvalidQuietMs;
}

fn parsePattern(ctx: *const ToolContext, value: std.json.Value) ![]const u8 {
    if (value == .string and value.string.len > 0 and value.string.len <= MAX_PATTERN_BYTES) return value.string;
    common.setErrorDetail(ctx.error_detail, ctx.allocator, "BashOutput pattern must be a non-empty string of at most {d} bytes", .{MAX_PATTERN_BYTES});
    return error.InvalidPattern;
}

//// Wait on a running job until `until` is met, it ends, or `limit_ms` runs
/// out. `job` is refreshed so the caller renders the state it returned on.
fn waitForJob(
    ctx: *const ToolContext,
    registry: *JobRegistry,
    job_id: []const u8,
    job: *JobEntry,
    until: Until,
    limit_ms: u64,
    reads: Reads,
    page: Page,
) !Wait {
    var watch: ?PatternWatch = switch (until) {
        .pattern => |pattern| try PatternWatch.init(ctx.allocator, pattern, reads),
        else => null,
    };
    defer if (watch) |*w| w.deinit(ctx.allocator);
    const watch_ptr: ?*PatternWatch = if (watch) |*w| w else null;
    var backlog: BacklogCheck = .{ .reads = reads, .page = page };

    const started = time.nowMs();
    const deadline = started + @as(i64, @intCast(limit_ms));
    var wait = try waitOutcome(ctx, registry, job_id, job, until, started, deadline, limit_ms == 0, reads, watch_ptr, &backlog);
    if (watch_ptr) |w| {
        // Finish a search the outcome cut short - a snapshot, a job that had
        // already exited, or one that printed the pattern and exited within
        // one poll slice - for as long as wait_ms allows.
        if (w.match == null) {
            _ = w.found(job.*);
            var searched = false;
            while (w.match == null and w.behind and time.nowMs() < deadline) {
                try ctx.throwIfAborted();
                _ = w.found(job.*);
                searched = true;
            }
            if (searched) wait.waited_ms = @max(wait.waited_ms, @as(u64, @intCast(@max(0, time.nowMs() - started))));
        }
        settlePatternSearch(&wait, w.match, w.behind, w.frontier());
    }
    return wait;
}

/// Fold a pattern search into how the call returned. A late match beats the
/// deadline; a snapshot stays a snapshot and the exit stays the exit, with the
/// match attached. Without a match, a search that did not catch up says how
/// far it got: "not found" must not stand in for "not searched".
fn settlePatternSearch(wait: *Wait, match: ?PatternMatch, behind: bool, frontier: SearchFrontier) void {
    if (match) |found_at| {
        wait.pattern = .{ .match = found_at };
        if (wait.returned_on == .deadline) wait.returned_on = .pattern;
    } else if (behind) wait.pattern = .{ .searched_to = frontier };
}

fn waitOutcome(
    ctx: *const ToolContext,
    registry: *JobRegistry,
    job_id: []const u8,
    job: *JobEntry,
    until: Until,
    started: time.Millis,
    deadline: time.Millis,
    snapshot: bool,
    reads: Reads,
    watch: ?*PatternWatch,
    backlog: *BacklogCheck,
) !Wait {
    if (job.status != .running) return .{ .returned_on = .exit, .waited_ms = 0 };
    if (snapshot) return .{ .returned_on = .snapshot, .waited_ms = 0 };

    // A condition already met by unread output returns without waiting.
    if (readyNow(ctx.allocator, job.*, until, watch, reads, backlog)) |ready| return .{ .returned_on = ready, .waited_ms = 0 };

    // `quiet` is a pause after output: a job that has printed nothing yet
    // has not paused, so the clock only runs once there is output to read.
    // Spools only grow and the cursors are fixed, so "there is unread output"
    // is "the spools are past the cursors" - read from the same sample as the
    // size. The first size that could be measured is the baseline, never
    // growth.
    const cursors = (reads.stdout orelse 0) + (reads.stderr orelse 0);
    var last_size: ?u64 = reads.spoolBytes(job.*);
    var seen_output = if (last_size) |size| size > cursors else false;
    var last_growth = started;
    const returned_on: ReturnedOn = while (true) {
        try ctx.throwIfAborted();
        registry.reapExited();
        job.* = registry.getForOwner(job_id, ctx.session) orelse return error.JobNotFound;
        if (job.status != .running) break .exit;
        if (readyNow(ctx.allocator, job.*, until, watch, reads, backlog)) |ready| break ready;
        const now = time.nowMs();
        switch (until) {
            .quiet => |quiet_ms| if (reads.spoolBytes(job.*)) |size| {
                if (size > cursors) seen_output = true;
                if (last_size == null) {
                    last_size = size;
                } else if (size != last_size.?) {
                    last_size = size;
                    last_growth = now;
                } else if (seen_output and now - last_growth >= @as(i64, @intCast(quiet_ms))) break .quiet;
            },
            .exit, .output, .pattern => {},
        }
        if (now >= deadline) break .deadline;
        // A pattern scan still catching up with the spool continues at once.
        if (watch) |w| if (w.behind) continue;
        const remaining: u64 = @intCast(deadline - now);
        time.sleepMs(@min(remaining, pollSliceMs()));
    };
    const elapsed = time.nowMs() - started;
    return .{ .returned_on = returned_on, .waited_ms = if (elapsed > 0) @intCast(elapsed) else 0 };
}

// The condition the unread output meets right now, if any. `exit` and
/// `quiet` also return on a backlog: once a result is full, waiting longer
/// cannot change what it shows. A pattern keeps waiting through a backlog -
/// skipping noise until the match is what it was asked for.
fn readyNow(
    allocator: std.mem.Allocator,
    job: JobEntry,
    until: Until,
    watch: ?*PatternWatch,
    reads: Reads,
    backlog: *BacklogCheck,
) ?ReturnedOn {
    return switch (until) {
        .output => if (reads.unread(job)) .output else null,
        .pattern => if (watch.?.found(job)) .pattern else null,
        .exit, .quiet => if (backlog.fills(allocator, job)) .backlog else null,
    };
}

/// Incremental literal search over the requested spools from each read
/// cursor on. Every check scans only what was appended since the previous
/// one, plus `pattern.len - 1` bytes of overlap so a match written across two
/// checks is still found; a match before the cursor never counts.
const PatternWatch = struct {
    pattern: []const u8,
    reads: Reads,
    buffer: []u8,
    stdout_next: u64,
    stderr_next: u64,
    match: ?PatternMatch = null,
    behind: bool = false,

    fn init(allocator: std.mem.Allocator, pattern: []const u8, reads: Reads) !PatternWatch {
        std.debug.assert(pattern.len > 0 and pattern.len <= MAX_PATTERN_BYTES);
        return .{
            .pattern = pattern,
            .reads = reads,
            .buffer = try allocator.alloc(u8, SCAN_CHUNK_BYTES + MAX_PATTERN_BYTES),
            .stdout_next = reads.stdout orelse 0,
            .stderr_next = reads.stderr orelse 0,
        };
    }

    fn deinit(self: *PatternWatch, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
    }

    /// Where the next scan would start: the scanned end minus the
    /// `pattern.len - 1` bytes of overlap, so a match straddling it is found
    /// when the search resumes there.
    fn frontier(self: *const PatternWatch) SearchFrontier {
        return .{
            .stdout = if (self.reads.stdout) |origin| self.resumeAt(origin, self.stdout_next) else null,
            .stderr = if (self.reads.stderr) |origin| self.resumeAt(origin, self.stderr_next) else null,
        };
    }

    fn resumeAt(self: *const PatternWatch, origin: u64, next: u64) u64 {
        return @max(origin, next -| (self.pattern.len - 1));
    }

    /// Scans what was appended since the last check, at most
    /// `SCAN_BUDGET_BYTES` per channel; `behind` says the scan has not caught
    /// up with the spools yet.
    fn found(self: *PatternWatch, job: JobEntry) bool {
        self.behind = false;
        if (self.reads.stdout) |origin| if (self.scan(job.stdout_path, origin, &self.stdout_next)) |offset| {
            self.match = .{ .channel = .stdout, .offset = offset };
            return true;
        };
        if (self.reads.stderr) |origin| if (self.scan(job.stderr_path, origin, &self.stderr_next)) |offset| {
            self.match = .{ .channel = .stderr, .offset = offset };
            return true;
        };
        return false;
    }

    /// The byte offset of the first match at or past `origin` among the
    /// bytes appended since `next`, or null.
    fn scan(self: *PatternWatch, path: []const u8, origin: u64, next: *u64) ?u64 {
        const fd = openSpool(path) catch return null;
        defer _ = pfs.close(fd);
        const size = pfs.lseek(fd, 0, .end);
        if (size < 0) return null;
        const total: u64 = @intCast(size);
        if (total <= next.*) return null;
        const start = self.resumeAt(origin, next.*);
        const stop = @min(total, start + SCAN_BUDGET_BYTES);
        if (stop < total) self.behind = true;
        if (pfs.lseek(fd, @intCast(start), .set) < 0) return null;
        var carry: usize = 0;
        var pos = start;
        while (pos < stop) {
            const want: usize = @intCast(@min(@as(u64, SCAN_CHUNK_BYTES), stop - pos));
            const n = pfs.read(fd, self.buffer[carry..][0..want]);
            if (n <= 0) break;
            const got: usize = @intCast(n);
            const filled = carry + got;
            pos += got;
            // buffer[0..filled] holds file bytes [pos - filled, pos).
            if (std.mem.indexOf(u8, self.buffer[0..filled], self.pattern)) |at| return pos - filled + at;
            const keep = @min(self.pattern.len - 1, filled);
            std.mem.copyForwards(u8, self.buffer[0..keep], self.buffer[filled - keep .. filled]);
            carry = keep;
        }
        next.* = pos;
        return null;
    }
};

const Chunk = struct {
    data: []const u8 = &.{},
    total_bytes: u64 = 0, // 文件整体大小（不只是本次读到的）
    truncated: bool = false, // 还没读完（文件还有剩）

    fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        if (self.data.len > 0) allocator.free(@constCast(self.data));
    }
};

/// 从 path 的 since 字节开始读最多 max 字节。若文件更大，truncated=true。
/// total_bytes 是文件整体大小,**不是下次的 since**——续读游标由调用方按实际展示的
/// 字节数算成 `*_next_offset`。这行注释原本写着"便于模型决定下次 since",正是把
/// 文件长度当游标的那句,与模块头的契约相反。
fn readFileRange(path: []const u8, since: usize, max: usize, allocator: std.mem.Allocator) !Chunk {
    const fd = try openSpool(path);
    defer _ = pfs.close(fd);

    // lseek 到 end 取 total_bytes(可移植 pfs.lseek,POSIX lseek / Windows _lseek)
    const total = pfs.lseek(fd, 0, .end);
    if (total < 0) return error.SeekFailed;
    const total_u: u64 = @intCast(total);

    if (since >= total_u) return .{ .total_bytes = total_u };

    _ = pfs.lseek(fd, @intCast(since), .set);

    const available = total_u - since;
    // Read a few bytes past the display budget so a valid code point straddling
    // the budget can be kept whole. The cursor still advances only by the
    // returned page length, so a subsequent call never starts in a continuation
    // byte. Malformed/binary data remains byte-addressable and is base64-encoded
    // by the caller.
    const read_limit = max + 3; // UTF-8's longest code point is four bytes.
    const to_read: usize = @intCast(@min(@as(u64, read_limit), available));

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, to_read);

    var buf: [4096]u8 = undefined;
    var remaining = to_read;
    while (remaining > 0) {
        const chunk_size = @min(remaining, buf.len);
        const n = pfs.read(fd, buf[0..chunk_size]);
        if (n <= 0) break;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
        remaining -= @intCast(n);
    }

    const page = if (std.unicode.utf8ValidateSlice(out.items))
        utf8.pagePrefix(out.items, max)
    else
        out.items[0..@min(out.items.len, max)];
    const page_len = page.len;
    out.items.len = page_len;
    return .{
        .data = try out.toOwnedSlice(allocator),
        .total_bytes = total_u,
        .truncated = page_len < available,
    };
}

fn openSpool(path: []const u8) !pfs.Fd {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= pbuf.len) return error.PathTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = pfs.open(@ptrCast(&pbuf), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    return fd;
}

/// Read only the current spool size for the long-poll readiness check.
fn fileSize(path: []const u8) !u64 {
    const fd = try openSpool(path);
    defer _ = pfs.close(fd);
    const total = pfs.lseek(fd, 0, .end);
    if (total < 0) return error.SeekFailed;
    return @intCast(total);
}

/// A cursor is a byte offset contract. It may point anywhere in binary output;
/// if a page then starts in the middle of a UTF-8 sequence, the channel is
/// encoded as base64 for that page. The only invalid cursor is one beyond the
/// current spool end, which otherwise makes a running long poll wait forever.
fn validateCursor(path: []const u8, since: usize) !void {
    const total = fileSize(path) catch return;
    if (@as(u64, @intCast(since)) > total) return error.InvalidSinceByte;
}

/// Write one channel plus the encoding it is in. `*_next_offset` is the cursor
/// to resume from: `total_bytes` is the file's current size, and a caller that
/// used it as the next `since_byte` - which the schema told it to - skipped
/// everything between what was shown and the end of the file. With the read
/// bounded by a budget rather than by 64 KiB, that gap became the common case:
/// a 100 KB log showed 24 KB and lost 75 KB with `truncated: true` and no
/// usable position to continue from.
fn writeChannel(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    label: []const u8,
    data: []const u8,
    base64: bool,
) !void {
    try writer.print(",\"{s}\":", .{label});
    if (base64) {
        const encoder = std.base64.standard.Encoder;
        const encoded = try allocator.alloc(u8, encoder.calcSize(data.len));
        defer allocator.free(encoded);
        _ = encoder.encode(encoded, data);
        try util_json.writeJsonString(writer, encoded);
    } else {
        try util_json.writeJsonString(writer, data);
    }
    try writer.print(",\"{s}_encoding\":\"{s}\"", .{ label, if (base64) "base64" else "utf-8" });
}

fn waitForSpoolBytes(registry: *@import("../core/job_registry.zig").JobRegistry, id: []const u8, want: u64) !void {
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        const job = registry.get(id) orelse return error.JobNotFound;
        if ((fileSize(job.stdout_path) catch 0) >= want) return;
        registry.reapExited();
        time.sleepMs(10);
    }
    return error.TestTimeout;
}

fn waitForExit(registry: *@import("../core/job_registry.zig").JobRegistry, id: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        registry.reapExited();
        const job = registry.get(id) orelse return error.JobNotFound;
        if (job.status != .running) return;
        time.sleepMs(10);
    }
    return error.TestTimeout;
}

fn parseEnvelope(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

test "BashOutput on nonexistent job" {
    const a = std.testing.allocator;
    var r = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer r.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &r };
    try std.testing.expectError(error.JobNotFound, execute(&ctx, "{\"job_id\":\"deadbeef0001\"}"));
}

test "BashOutput returns stdout after exit" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
    const a = std.testing.allocator;
    var r = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer r.deinit();
    const j = try r.spawnBackground("echo hello; exit 0", null);

    // 等子进程结束
    time.sleepMs(200);

    var args_buf: [128]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"job_id\":\"{s}\"}}", .{j.id[0..]});

    const ctx = ToolContext{ .allocator = a, .jobs = &r };
    const result = try execute(&ctx, args);
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"exit_code\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"status\":\"exited\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout_total_bytes\":6") != null); // "hello\n"
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout_truncated\":false") != null);
}

test "BashOutput observed exit is not announced" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("../core/session_id.zig").gen();
    const j = try r.spawnBackgroundOwned("printf done", null, owner);
    try waitForExit(&r, j.idSlice());
    const ctx = ToolContext{ .allocator = a, .jobs = &r, .agent_ident = owner, .session = owner };
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\"}}", .{j.idSlice()});
    defer a.free(args);
    const result = try execute(&ctx, args);
    defer a.free(result);
    const events = try r.takeUnannouncedExits(owner, a);
    defer @import("../core/job_registry.zig").freeJobExitEvents(a, events);
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "BashOutput since_byte skips prefix" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
    const a = std.testing.allocator;
    var r = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer r.deinit();
    const j = try r.spawnBackground("printf 'ABCDEFG'; exit 0", null);

    time.sleepMs(200);

    var args_buf: [128]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"job_id\":\"{s}\",\"stdout_since_byte\":\"3\"}}", .{j.id[0..]});

    const ctx = ToolContext{ .allocator = a, .jobs = &r };
    const result = try execute(&ctx, args);
    defer a.free(result);
    // 只应看到 "DEFG"，不是 "ABCDEFG"
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout\":\"DEFG\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout_total_bytes\":7") != null);
}

test "BashOutput rejects a cursor beyond the spool end" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer r.deinit();
    const job = try r.spawnBackground("printf x; exit 0", null);
    try waitForExit(&r, job.idSlice());
    const ctx = ToolContext{ .allocator = a, .jobs = &r };
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"stdout_since_byte\":2,\"wait_ms\":100}}", .{job.idSlice()});
    defer a.free(args);
    try std.testing.expectError(error.InvalidSinceByte, execute(&ctx, args));
}

test "BashOutput max_bytes truncates" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
    const a = std.testing.allocator;
    var r = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer r.deinit();
    const j = try r.spawnBackground("printf 'ABCDEFGHIJ'; exit 0", null);

    time.sleepMs(200);

    var args_buf: [128]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"job_id\":\"{s}\",\"max_bytes\":\"3\"}}", .{j.id[0..]});

    const ctx = ToolContext{ .allocator = a, .jobs = &r };
    const result = try execute(&ctx, args);
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout\":\"ABC\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout_total_bytes\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout_truncated\":true") != null);
}

test "BashOutput waits for delayed output" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const job = try registry.spawnBackground("sleep 0.4; printf hi", null);
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const start = time.nowMs();
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\"}}", .{job.idSlice()});
    defer a.free(args);
    const result = try execute(&ctx, args);
    defer a.free(result);
    const elapsed = time.nowMs() - start;
    try std.testing.expect(elapsed >= 300);
    try std.testing.expect(elapsed < @as(i64, @intCast(DEFAULT_WAIT_MS)));
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout\":\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"waited_ms\":") != null);
}

test "BashOutput until output returns immediately when unread bytes exist" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const job = try registry.spawnBackground("printf ready; sleep 5", null);
    try waitForSpoolBytes(&registry, job.idSlice(), 5);
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const start = time.nowMs();
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"wait_ms\":500,\"until\":\"output\"}}", .{job.idSlice()});
    defer a.free(args);
    const result = try execute(&ctx, args);
    defer a.free(result);
    try std.testing.expect(time.nowMs() - start < 2000);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout\":\"ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"waited_ms\":0") != null);
}

test "BashOutput returns immediately when the job exited" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const job = try registry.spawnBackground("printf done; exit 0", null);
    try waitForExit(&registry, job.idSlice());
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\"}}", .{job.idSlice()});
    defer a.free(args);
    const start = time.nowMs();
    const result = try execute(&ctx, args);
    defer a.free(result);
    try std.testing.expect(time.nowMs() - start < 2000);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"status\":\"exited\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"waited_ms\":0") != null);
}

test "BashOutput wait_ms zero preserves snapshot behavior" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const job = try registry.spawnBackground("sleep 5", null);
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"wait_ms\":0}}", .{job.idSlice()});
    defer a.free(args);
    const start = time.nowMs();
    const result = try execute(&ctx, args);
    defer a.free(result);
    try std.testing.expect(time.nowMs() - start < 2000);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"status\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"waited_ms\":0") != null);
}

test "BashOutput deadline returns a still-running job" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const job = try registry.spawnBackground("sleep 5", null);
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"wait_ms\":300}}", .{job.idSlice()});
    defer a.free(args);
    const start = time.nowMs();
    const result = try execute(&ctx, args);
    defer a.free(result);
    try std.testing.expect(time.nowMs() - start >= 300);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"status\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"stdout\":\"\"") != null);
    var parsed = try parseEnvelope(a, result);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("waited_ms").?.integer >= 300);
}

test "BashOutput abort interrupts its wait" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const job = try registry.spawnBackground("sleep 5", null);
    var signal = @import("../util/abort.zig").AbortSignal.init();
    const Aborter = struct {
        fn run(target: *@import("../util/abort.zig").AbortSignal) void {
            time.sleepMs(100);
            target.abort(.user_interrupt);
        }
    };
    const thread = try std.Thread.spawn(.{}, Aborter.run, .{&signal});
    defer thread.join();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry, .abort = &signal };
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"wait_ms\":5000}}", .{job.idSlice()});
    defer a.free(args);
    const start = time.nowMs();
    try std.testing.expectError(error.Aborted, execute(&ctx, args));
    try std.testing.expect(time.nowMs() - start < 1000);
}

test "BashOutput remembered cursor and explicit offset override" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const job = try registry.spawnBackground("printf once; sleep 1", null);
    try waitForSpoolBytes(&registry, job.idSlice(), 4);
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const first_args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"wait_ms\":0}}", .{job.idSlice()});
    defer a.free(first_args);
    const first = try execute(&ctx, first_args);
    defer a.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"stdout\":\"once\"") != null);

    const second_args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"wait_ms\":100}}", .{job.idSlice()});
    defer a.free(second_args);
    const second = try execute(&ctx, second_args);
    defer a.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"stdout\":\"\"") != null);

    const explicit_args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"stdout_since_byte\":0,\"wait_ms\":0}}", .{job.idSlice()});
    defer a.free(explicit_args);
    const explicit = try execute(&ctx, explicit_args);
    defer a.free(explicit);
    try std.testing.expect(std.mem.indexOf(u8, explicit, "\"stdout\":\"once\"") != null);

    const large = try registry.spawnBackground("awk 'BEGIN { for(i=0;i<100000;i++) printf \"x\" }'", null);
    try waitForExit(&registry, large.idSlice());
    const small_args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"max_bytes\":3,\"wait_ms\":0}}", .{large.idSlice()});
    defer a.free(small_args);
    const small = try execute(&ctx, small_args);
    defer a.free(small);
    try std.testing.expect(std.mem.indexOf(u8, small, "\"stdout_next_offset\":3") != null);
    const next = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"max_bytes\":3,\"wait_ms\":0}}", .{large.idSlice()});
    defer a.free(next);
    const continued = try execute(&ctx, next);
    defer a.free(continued);
    try std.testing.expect(std.mem.indexOf(u8, continued, "\"stdout_next_offset\":6") != null);
}

test "BashOutput rejects wait_ms above the maximum" {
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    try std.testing.expectError(error.JobNotFound, execute(&ctx, "{\"job_id\":\"deadbeef0001\"}"));
    // Validate the wait bound on a real job so the error is not masked by lookup.
    const job = try registry.spawnBackground("sleep 1", null);
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"wait_ms\":{d}}}", .{ job.idSlice(), MAX_WAIT_MS + 1 });
    defer a.free(args);
    try std.testing.expectError(error.InvalidWaitMs, execute(&ctx, args));
}

const Envelope = std.json.Parsed(std.json.Value);

/// Run one BashOutput call and parse its envelope.
fn poll(ctx: *const ToolContext, comptime fmt: []const u8, args: anytype) !Envelope {
    const a = ctx.allocator;
    const input = try std.fmt.allocPrint(a, fmt, args);
    defer a.free(input);
    const out = try execute(ctx, input);
    defer a.free(out);
    return std.json.parseFromSlice(std.json.Value, a, out, .{ .allocate = .alloc_always });
}

fn envString(env: Envelope, name: []const u8) []const u8 {
    return env.value.object.get(name).?.string;
}

/// Prints `tick` every 100 ms, `n` times, then `done` and exits.
fn tickerCommand(buf: []u8, n: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "i=0; while [ $i -lt {d} ]; do printf 'tick\\n'; sleep 0.1; i=$((i+1)); done; printf done", .{n});
}

test "BashOutput waits for exit by default while the job prints progress" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    var cmd: [160]u8 = undefined;
    const job = try registry.spawnBackground(try tickerCommand(&cmd, 8), null);
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    var env = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":10000}}", .{job.idSlice()});
    defer env.deinit();
    try std.testing.expectEqualStrings("exit", envString(env, "returned_on"));
    try std.testing.expectEqualStrings("exited", envString(env, "status"));
    const stdout = envString(env, "stdout");
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, stdout, "tick"));
    try std.testing.expect(std.mem.endsWith(u8, stdout, "done"));
    try std.testing.expect(env.value.object.get("waited_ms").?.integer > 0);
    try std.testing.expect(env.value.object.get("poll_guard") == null);
}

test "BashOutput until output returns on the first progress line" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    var cmd: [160]u8 = undefined;
    const job = try registry.spawnBackground(try tickerCommand(&cmd, 30), null);
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const start = time.nowMs();
    var env = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":10000,\"until\":\"output\"}}", .{job.idSlice()});
    defer env.deinit();
    try std.testing.expect(time.nowMs() - start < 2500);
    try std.testing.expectEqualStrings("output", envString(env, "returned_on"));
    try std.testing.expectEqualStrings("running", envString(env, "status"));
    try std.testing.expect(std.mem.indexOf(u8, envString(env, "stdout"), "tick") != null);
}

test "BashOutput a polling loop over a progress ticker costs one call by default and stays bounded with until output" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // The loop a model runs: call until the job is no longer running. Before
    // `until`, every progress line ended the wait, so a 20-line ticker cost
    // about 20 calls. By default the first call waits for the exit; an
    // explicit `output` loop is cut off by the poll guard.
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    var cmd: [160]u8 = undefined;
    inline for (.{ .{ "", @as(usize, 1) }, .{ ",\"until\":\"output\"", @as(usize, POLL_GUARD_STREAK + 1) } }) |case| {
        const job = try registry.spawnBackground(try tickerCommand(&cmd, 20), null);
        var calls: usize = 0;
        var guarded = false;
        while (true) {
            var env = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":10000" ++ case[0] ++ "}}", .{job.idSlice()});
            defer env.deinit();
            calls += 1;
            if (env.value.object.get("poll_guard")) |g| {
                guarded = true;
                try std.testing.expectEqual(@as(i64, POLL_GUARD_STREAK), g.object.get("low_yield_polls").?.integer);
                try std.testing.expectEqualStrings("exit", g.object.get("until").?.string);
                try std.testing.expectEqual(@as(i64, @intCast(guardWaitMs(POLL_GUARD_STREAK))), g.object.get("min_wait_ms").?.integer);
                // It ended on the exit, so there is no advice to stop polling.
                try std.testing.expect(env.value.object.get("note") == null);
            }
            if (!std.mem.eql(u8, envString(env, "status"), "running")) break;
            try std.testing.expect(calls < 20);
        }
        try std.testing.expectEqual(case[1], calls);
        try std.testing.expectEqual(case[1] > 1, guarded);
    }
}

test "BashOutput poll guard leaves informative polls alone" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // Each line is 301 bytes: real output, not a progress tick.
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const job = try registry.spawnBackground("i=0; while [ $i -lt 30 ]; do printf '%0300d\\n' 0; sleep 0.1; i=$((i+1)); done", null);
    try waitForSpoolBytes(&registry, job.idSlice(), 301);
    var i: usize = 0;
    while (i < POLL_GUARD_STREAK + 2) : (i += 1) {
        var env = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":10000,\"until\":\"output\"}}", .{job.idSlice()});
        defer env.deinit();
        try std.testing.expect(env.value.object.get("poll_guard") == null);
        try std.testing.expectEqualStrings("output", envString(env, "returned_on"));
        time.sleepMs(150); // let the next line land so each poll shows a full one
    }
}

test "BashOutput snapshots neither count toward nor trip the poll guard" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    var cmd: [160]u8 = undefined;
    const job = try registry.spawnBackground(try tickerCommand(&cmd, 30), null);
    var i: usize = 0;
    while (i < POLL_GUARD_STREAK + 2) : (i += 1) {
        var env = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":0}}", .{job.idSlice()});
        defer env.deinit();
        try std.testing.expectEqualStrings("snapshot", envString(env, "returned_on"));
        time.sleepMs(120);
    }
    var env = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":5000,\"until\":\"output\"}}", .{job.idSlice()});
    defer env.deinit();
    try std.testing.expect(env.value.object.get("poll_guard") == null);
    try std.testing.expectEqualStrings("output", envString(env, "returned_on"));
}

test "BashOutput until quiet returns once output pauses" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const job = try registry.spawnBackground("printf a; sleep 0.05; printf b; sleep 5", null);
    // Start after "a" so a slow shell start-up cannot pass for a pause.
    try waitForSpoolBytes(&registry, job.idSlice(), 1);
    const start = time.nowMs();
    var env = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":10000,\"until\":\"quiet\",\"quiet_ms\":800}}", .{job.idSlice()});
    defer env.deinit();
    const elapsed = time.nowMs() - start;
    try std.testing.expectEqualStrings("quiet", envString(env, "returned_on"));
    try std.testing.expectEqualStrings("running", envString(env, "status"));
    try std.testing.expectEqualStrings("ab", envString(env, "stdout"));
    try std.testing.expect(elapsed >= 800);
    // The given quiet_ms is what ended it: the default would still be waiting.
    try std.testing.expect(elapsed < DEFAULT_QUIET_MS);
}

test "BashOutput until quiet does not return while output keeps arriving" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const job = try registry.spawnBackground("while :; do printf t; sleep 0.05; done", null);
    // A lone quiet_ms implies until quiet.
    var env = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":1500,\"quiet_ms\":1000}}", .{job.idSlice()});
    defer env.deinit();
    try std.testing.expectEqualStrings("deadline", envString(env, "returned_on"));
    try std.testing.expectEqualStrings("running", envString(env, "status"));
    try std.testing.expect(env.value.object.get("waited_ms").?.integer >= 1500);
}

test "BashOutput until pattern returns when the text appears, on either channel" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };

    const server = try registry.spawnBackground("printf 'starting\\n'; sleep 0.3; printf 'listening READY\\n'; sleep 5", null);
    const start = time.nowMs();
    var ready = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":10000,\"pattern\":\"READY\"}}", .{server.idSlice()});
    defer ready.deinit();
    try std.testing.expect(time.nowMs() - start < 4000);
    try std.testing.expectEqualStrings("pattern", envString(ready, "returned_on"));
    try std.testing.expectEqualStrings("running", envString(ready, "status"));
    try std.testing.expect(std.mem.indexOf(u8, envString(ready, "stdout"), "READY") != null);
    const ready_match = ready.value.object.get("pattern_match").?.object;
    try std.testing.expectEqualStrings("stdout", ready_match.get("channel").?.string);
    try std.testing.expectEqual(@as(i64, "starting\nlistening ".len), ready_match.get("offset").?.integer);

    const failing = try registry.spawnBackground("printf 'boom\\n' >&2; sleep 5", null);
    var boom = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":10000,\"until\":\"pattern\",\"pattern\":\"boom\"}}", .{failing.idSlice()});
    defer boom.deinit();
    try std.testing.expectEqualStrings("pattern", envString(boom, "returned_on"));
    try std.testing.expectEqualStrings("boom\n", envString(boom, "stderr"));
    try std.testing.expectEqualStrings("stderr", boom.value.object.get("pattern_match").?.object.get("channel").?.string);
}

test "BashOutput until pattern finds a match written across two checks" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    // "ADY" waits for a gate file the test creates while the call is already
    // waiting, so the first check can only have seen "RE".
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    const job = try registry.spawnBackground("printf RE; while [ ! -e go ]; do sleep 0.02; done; printf ADY; sleep 5", root);
    try waitForSpoolBytes(&registry, job.idSlice(), 2);
    const Gate = struct {
        fn open(dir: std.Io.Dir) void {
            // Sized for a loaded hosted runner, as in bash_output_wait_test.
            time.sleepMs(1_000);
            const file = dir.createFile(std.testing.io, "go", .{}) catch return;
            file.close(std.testing.io);
        }
    };
    const gate = try std.Thread.spawn(.{}, Gate.open, .{tmp.dir});
    var env = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":10000,\"pattern\":\"READY\"}}", .{job.idSlice()});
    gate.join();
    defer env.deinit();
    try std.testing.expectEqualStrings("pattern", envString(env, "returned_on"));
    try std.testing.expect(env.value.object.get("waited_ms").?.integer > 0);
    try std.testing.expectEqualStrings("READY", envString(env, "stdout"));
    try std.testing.expectEqual(@as(i64, 0), env.value.object.get("pattern_match").?.object.get("offset").?.integer);
}

test "BashOutput until pattern ignores text before the read cursor" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const job = try registry.spawnBackground("printf READY; sleep 5", null);
    try waitForSpoolBytes(&registry, job.idSlice(), 5);
    var seen = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":0}}", .{job.idSlice()});
    seen.deinit();
    var after = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":400,\"pattern\":\"READY\"}}", .{job.idSlice()});
    defer after.deinit();
    try std.testing.expectEqualStrings("deadline", envString(after, "returned_on"));
    // An explicit cursor before it brings it back into range, without waiting.
    var rewound = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":400,\"pattern\":\"READY\",\"stdout_since_byte\":0}}", .{job.idSlice()});
    defer rewound.deinit();
    try std.testing.expectEqualStrings("pattern", envString(rewound, "returned_on"));
    try std.testing.expectEqual(@as(i64, 0), rewound.value.object.get("waited_ms").?.integer);
}

test "BashOutput rejects contradictory or malformed wait conditions" {
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const job = try registry.spawnBackground("sleep 1", null);
    const long_pattern = "x" ** (MAX_PATTERN_BYTES + 1);
    const cases = .{
        .{ ",\"until\":\"forever\"", error.InvalidUntil },
        .{ ",\"until\":3", error.InvalidUntil },
        .{ ",\"quiet_ms\":500,\"pattern\":\"x\"", error.InvalidUntil },
        .{ ",\"until\":\"exit\",\"pattern\":\"x\"", error.InvalidPattern },
        .{ ",\"until\":\"output\",\"quiet_ms\":500", error.InvalidQuietMs },
        .{ ",\"until\":\"pattern\"", error.InvalidPattern },
        .{ ",\"pattern\":\"\"", error.InvalidPattern },
        .{ ",\"pattern\":\"" ++ long_pattern ++ "\"", error.InvalidPattern },
        .{ ",\"quiet_ms\":0", error.InvalidQuietMs },
        .{ ",\"quiet_ms\":600001", error.InvalidQuietMs },
        .{ ",\"quiet_ms\":\"soon\"", error.InvalidQuietMs },
        .{ ",\"quiet_ms\":" ++ std.fmt.comptimePrint("{d}", .{MIN_QUIET_MS - 1}), error.InvalidQuietMs },
        .{ ",\"stdout\":\"maybe\"", error.InvalidChannelFlag },
        .{ ",\"stderr\":1", error.InvalidChannelFlag },
        .{ ",\"stdout_since_byte\":-1", error.InvalidSinceByte },
        .{ ",\"max_bytes\":0", error.InvalidMaxBytes },
        .{ ",\"max_bytes\":\"lots\"", error.InvalidMaxBytes },
        // A second wait_ms: one parse sees both, so it is refused, not first-wins.
        .{ ",\"wait_ms\":5", error.InvalidBashOutputArgs },
        .{ ",\"stdout\":false,\"stderr\":false,\"pattern\":\"x\"", error.InvalidPattern },
        .{ ",\"stdout\":false,\"stderr\":false,\"until\":\"output\"", error.InvalidUntil },
        .{ ",\"stdout\":false,\"stderr\":false,\"quiet_ms\":500", error.InvalidUntil },
    };
    inline for (cases) |case| {
        const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"wait_ms\":0" ++ case[0] ++ "}}", .{job.idSlice()});
        defer a.free(args);
        try std.testing.expectError(case[1], execute(&ctx, args));
    }
    // Accepted spellings: a lone field implies its mode, null means absent,
    // and a numeric string is a number as for the other integer fields.
    inline for (.{
        ",\"pattern\":\"x\"",
        ",\"quiet_ms\":\"500\"",
        ",\"until\":null,\"pattern\":null",
        ",\"until\":\"quiet\"",
        ",\"until\":\"pattern\",\"pattern\":\"" ++ ("y" ** MAX_PATTERN_BYTES) ++ "\"",
        ",\"stdout\":\"false\",\"stderr\":true,\"max_bytes\":\"3\"",
    }) |extra| {
        const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"wait_ms\":0" ++ extra ++ "}}", .{job.idSlice()});
        defer a.free(args);
        const out = try execute(&ctx, args);
        a.free(out);
    }
}

test "BashOutput poll guard wait doubles from the base to the cap" {
    try std.testing.expectEqual(POLL_GUARD_BASE_WAIT_MS, guardWaitMs(POLL_GUARD_STREAK));
    try std.testing.expectEqual(POLL_GUARD_BASE_WAIT_MS * 2, guardWaitMs(POLL_GUARD_STREAK + 1));
    try std.testing.expectEqual(POLL_GUARD_BASE_WAIT_MS * 4, guardWaitMs(POLL_GUARD_STREAK + 2));
    try std.testing.expectEqual(POLL_GUARD_MAX_WAIT_MS, guardWaitMs(std.math.maxInt(u8)));
    var streak: u8 = POLL_GUARD_STREAK;
    var previous: u64 = 0;
    while (streak < std.math.maxInt(u8)) : (streak += 1) {
        const wait_ms = guardWaitMs(streak);
        try std.testing.expect(wait_ms >= previous);
        try std.testing.expect(wait_ms <= POLL_GUARD_MAX_WAIT_MS);
        try std.testing.expect(wait_ms <= MAX_WAIT_MS);
        previous = wait_ms;
    }
}

test "BashOutput streak: what extends, resets or leaves it alone" {
    const low = POLL_GUARD_LOW_YIELD_BYTES - 1;
    const enough = POLL_GUARD_LOW_YIELD_BYTES;
    // A waiting poll of a running job that shows only a few bytes extends it.
    inline for (.{ ReturnedOn.output, ReturnedOn.quiet, ReturnedOn.deadline }) |on| {
        try std.testing.expectEqual(StreakUpdate.extend, streakUpdate(.running, on, false, false, low).?);
        // Unguarded, enough output resets it ...
        try std.testing.expectEqual(StreakUpdate.reset, streakUpdate(.running, on, false, false, enough).?);
        // ... but under the guard the batched ticks it waited for do not.
        try std.testing.expectEqual(StreakUpdate.extend, streakUpdate(.running, on, true, false, enough).?);
        // A full page of real output is informative, guarded or not ...
        try std.testing.expectEqual(StreakUpdate.reset, streakUpdate(.running, on, true, true, enough).?);
        // ... but a "full page" of a tiny explicit max_bytes is a tick.
        try std.testing.expectEqual(StreakUpdate.extend, streakUpdate(.running, on, true, true, low).?);
        try std.testing.expectEqual(StreakUpdate.extend, streakUpdate(.running, on, false, true, low).?);
    }
    try std.testing.expectEqual(StreakUpdate.reset, streakUpdate(.running, .pattern, true, false, 0).?);
    try std.testing.expectEqual(StreakUpdate.reset, streakUpdate(.running, .backlog, true, true, enough).?);
    try std.testing.expectEqual(StreakUpdate.extend, streakUpdate(.running, .backlog, false, true, low).?);
    try std.testing.expectEqual(StreakUpdate.reset, streakUpdate(.exited, .exit, true, false, 0).?);
    try std.testing.expectEqual(StreakUpdate.reset, streakUpdate(.killed, .deadline, true, false, 0).?);
    try std.testing.expect(streakUpdate(.running, .snapshot, false, false, 0) == null);
}

test "BashOutput streak lapses after an idle gap but not across a loop" {
    const streak: job_registry.PollStreak = .{ .low_yield = 4, .last_ms = 1_000 };
    try std.testing.expectEqual(@as(u8, 4), activeStreak(streak, 1_000));
    try std.testing.expectEqual(@as(u8, 4), activeStreak(streak, 1_000 + POLL_GUARD_IDLE_RESET_MS));
    try std.testing.expectEqual(@as(u8, 0), activeStreak(streak, 1_000 + POLL_GUARD_IDLE_RESET_MS + 1));
    try std.testing.expectEqual(@as(u8, 0), activeStreak(.{}, time.nowMs()));
}

test "BashOutput guard engages only for a waiting read of a running job past the streak" {
    const both: Reads = .{ .stdout = 0, .stderr = 0 };
    const none: Reads = .{ .stdout = null, .stderr = null };
    try std.testing.expect(PollGuard.engage(.running, POLL_GUARD_STREAK - 1, 5_000, both) == null);
    try std.testing.expect(PollGuard.engage(.running, POLL_GUARD_STREAK, 0, both) == null);
    try std.testing.expect(PollGuard.engage(.exited, POLL_GUARD_STREAK, 5_000, both) == null);
    try std.testing.expect(PollGuard.engage(.running, POLL_GUARD_STREAK, 5_000, none) == null);
    const guard = PollGuard.engage(.running, POLL_GUARD_STREAK + 1, 5_000, both).?;
    try std.testing.expectEqual(guardWaitMs(POLL_GUARD_STREAK + 1), guard.min_wait_ms);
    // Progress-driven conditions become exit; exit and a pattern are kept.
    try std.testing.expectEqual(UntilKind.exit, std.meta.activeTag(PollGuard.until(.output)));
    try std.testing.expectEqual(UntilKind.exit, std.meta.activeTag(PollGuard.until(.{ .quiet = 500 })));
    try std.testing.expectEqual(UntilKind.exit, std.meta.activeTag(PollGuard.until(.exit)));
    try std.testing.expectEqualStrings("ready", PollGuard.until(.{ .pattern = "ready" }).pattern);
}

test "BashOutput resolves until, quiet_ms and pattern into one condition" {
    const a = std.testing.allocator;
    const ctx = ToolContext{ .allocator = a };
    const Case = struct { json: []const u8, kind: UntilKind, quiet_ms: u64 = 0, pattern: []const u8 = "" };
    const cases = [_]Case{
        .{ .json = "{}", .kind = .exit },
        .{ .json = "{\"until\":\"output\"}", .kind = .output },
        .{ .json = "{\"until\":\"quiet\"}", .kind = .quiet, .quiet_ms = DEFAULT_QUIET_MS },
        .{ .json = "{\"quiet_ms\":750}", .kind = .quiet, .quiet_ms = 750 },
        .{ .json = "{\"until\":\"quiet\",\"quiet_ms\":\"900\"}", .kind = .quiet, .quiet_ms = 900 },
        .{ .json = "{\"pattern\":\"a\\\"b\\nc\"}", .kind = .pattern, .pattern = "a\"b\nc" },
        .{ .json = "{\"until\":null,\"pattern\":null,\"quiet_ms\":null}", .kind = .exit },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, a, case.json, .{});
        defer parsed.deinit();
        const until = try parseUntil(&ctx, parsed.value.object);
        try std.testing.expectEqual(case.kind, std.meta.activeTag(until));
        switch (until) {
            .quiet => |ms| try std.testing.expectEqual(case.quiet_ms, ms),
            .pattern => |text| try std.testing.expectEqualStrings(case.pattern, text),
            .exit, .output => {},
        }
    }
}

test "BashOutput rejects arguments that are not a JSON object" {
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const job = try registry.spawnBackground("sleep 1", null);
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"wait_ms\":0,}}", .{job.idSlice()});
    defer a.free(args);
    try std.testing.expectError(error.InvalidBashOutputArgs, execute(&ctx, args));
    const not_object = try std.fmt.allocPrint(a, "[\"{s}\"]", .{job.idSlice()});
    defer a.free(not_object);
    try std.testing.expectError(error.InvalidBashOutputArgs, execute(&ctx, not_object));
    const numeric_id = "{\"job_id\":5}";
    try std.testing.expectError(error.InvalidJobId, execute(&ctx, numeric_id));
    try std.testing.expectError(error.MissingJobId, execute(&ctx, "{\"job_id\":null}"));
}

test "BashOutput reads every field the same way, spaces around the colon included" {
    // The old scraper needed `"key":` with no space; `"wait_ms" : 0` was
    // silently a 30 s wait.
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const job = try registry.spawnBackground("sleep 5", null);
    const start = time.nowMs();
    var env = try poll(&ctx, "{{ \"job_id\" : \"{s}\" , \"wait_ms\" : 0 }}", .{job.idSlice()});
    defer env.deinit();
    try std.testing.expect(time.nowMs() - start < 2000);
    try std.testing.expectEqualStrings("snapshot", envString(env, "returned_on"));
}

test "BashOutput under the guard still returns on the caller's pattern, and quiet waits for exit" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const server = try registry.spawnBackground("printf 'boot\\n'; sleep 0.3; printf 'READY\\n'; sleep 5", null);
    primeStreak(&registry, server.idSlice(), time.nowMs());
    var ready = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":1000,\"pattern\":\"READY\"}}", .{server.idSlice()});
    defer ready.deinit();
    try std.testing.expectEqualStrings("pattern", envString(ready, "returned_on"));
    try std.testing.expectEqualStrings("pattern", ready.value.object.get("poll_guard").?.object.get("until").?.string);
    try std.testing.expectEqual(@as(u8, 0), registry.get(server.idSlice()).?.poll_streak.low_yield);
    try std.testing.expect(ready.value.object.get("note") == null);

    // Output pauses after "a", which would end a plain quiet wait; under the
    // guard the call waits for the exit instead.
    const job = try registry.spawnBackground("printf a; sleep 1; printf b", null);
    try waitForSpoolBytes(&registry, job.idSlice(), 1);
    primeStreak(&registry, job.idSlice(), time.nowMs());
    var exited = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":200,\"quiet_ms\":200}}", .{job.idSlice()});
    defer exited.deinit();
    try std.testing.expectEqualStrings("exit", envString(exited, "returned_on"));
    try std.testing.expectEqualStrings("ab", envString(exited, "stdout"));
    try std.testing.expectEqualStrings("exit", exited.value.object.get("poll_guard").?.object.get("until").?.string);
    // "Do not poll again" is moot once the job has ended.
    try std.testing.expect(exited.value.object.get("note") == null);

    // The same streak after an idle gap does not engage the guard.
    const idle = try registry.spawnBackground("sleep 5", null);
    primeStreak(&registry, idle.idSlice(), time.nowMs() - POLL_GUARD_IDLE_RESET_MS - 1);
    var fresh = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":200}}", .{idle.idSlice()});
    defer fresh.deinit();
    try std.testing.expect(fresh.value.object.get("poll_guard") == null);
    try std.testing.expectEqualStrings("deadline", envString(fresh, "returned_on"));
    try std.testing.expectEqual(@as(u8, 1), registry.get(idle.idSlice()).?.poll_streak.low_yield);
}

/// Record `POLL_GUARD_STREAK` low-yield polls that returned at `at_ms`.
fn primeStreak(registry: *JobRegistry, id: []const u8, at_ms: time.Millis) void {
    var i: u8 = 0;
    while (i < POLL_GUARD_STREAK) : (i += 1) registry.extendPollStreak(id, at_ms, at_ms, POLL_GUARD_IDLE_RESET_MS);
}

test "BashOutput returns a full page of a running job without waiting, and waits on a small one" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry, .result_budget = result_budget.Budget.fromModel(200_000) };

    // Paging a running job: each page returns at once instead of after wait_ms.
    const chatty = try registry.spawnBackground("awk 'BEGIN { for(i=0;i<100000;i++) printf \"x\" }'; sleep 5", null);
    try waitForSpoolBytes(&registry, chatty.idSlice(), 100_000);
    const start = time.nowMs();
    for (0..2) |_| {
        var page = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":10000}}", .{chatty.idSlice()});
        defer page.deinit();
        try std.testing.expectEqualStrings("backlog", envString(page, "returned_on"));
        try std.testing.expectEqualStrings("running", envString(page, "status"));
        try std.testing.expect(page.value.object.get("stdout_truncated").?.bool);
        try std.testing.expectEqual(@as(i64, 0), page.value.object.get("waited_ms").?.integer);
    }
    try std.testing.expect(time.nowMs() - start < 2000);

    // A few unread bytes do not fill a page: the call still waits.
    const quiet = try registry.spawnBackground("printf ready; sleep 5", null);
    try waitForSpoolBytes(&registry, quiet.idSlice(), 5);
    var waited = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":400}}", .{quiet.idSlice()});
    defer waited.deinit();
    try std.testing.expectEqualStrings("deadline", envString(waited, "returned_on"));
    try std.testing.expectEqualStrings("ready", envString(waited, "stdout"));
}

test "BashOutput a guarded result still fits the per-result budget" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const job = try registry.spawnBackground("awk 'BEGIN { for(i=0;i<100000;i++) printf \"x\" }'; sleep 5", null);
    try waitForSpoolBytes(&registry, job.idSlice(), 100_000);
    for ([_]usize{ 0, 200_000, 1_048_576 }) |window| {
        const budget = result_budget.Budget.fromModel(window);
        const ctx = ToolContext{ .allocator = a, .jobs = &registry, .result_budget = budget };
        primeStreak(&registry, job.idSlice(), time.nowMs());
        const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"stdout_since_byte\":0,\"until\":\"output\"}}", .{job.idSlice()});
        defer a.free(args);
        const out = try execute(&ctx, args);
        defer a.free(out);
        try std.testing.expect(out.len <= budget.per_result_bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("poll_guard") != null);
        try std.testing.expectEqualStrings("backlog", parsed.value.object.get("returned_on").?.string);
        try std.testing.expect(parsed.value.object.get("note") == null);
        try std.testing.expect(parsed.value.object.get("stdout_truncated").?.bool);
    }
}

test "BashOutput the guard raises a short wait to its floor" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const job = try registry.spawnBackground("sleep 60", null);
    primeStreak(&registry, job.idSlice(), time.nowMs());
    var signal = @import("../util/abort.zig").AbortSignal.init();
    const Aborter = struct {
        fn run(target: *@import("../util/abort.zig").AbortSignal) void {
            time.sleepMs(600);
            target.abort(.user_interrupt);
        }
    };
    const thread = try std.Thread.spawn(.{}, Aborter.run, .{&signal});
    defer thread.join();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry, .abort = &signal };
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"wait_ms\":100}}", .{job.idSlice()});
    defer a.free(args);
    // Unguarded this returns after 100 ms; under the guard only the abort
    // ends it, well inside the 30 s floor.
    const start = time.nowMs();
    try std.testing.expectError(error.Aborted, execute(&ctx, args));
    try std.testing.expect(time.nowMs() - start >= 500);
}

test "BashOutput the guard note fits only a guarded wait that ran out on a running job" {
    const ran_out: Wait = .{ .returned_on = .deadline, .waited_ms = 1 };
    try std.testing.expect(guardNoteFits(.running, ran_out, false));
    try std.testing.expect(!guardNoteFits(.running, ran_out, true));
    inline for (.{ ReturnedOn.backlog, ReturnedOn.pattern, ReturnedOn.output, ReturnedOn.quiet, ReturnedOn.snapshot }) |on| {
        try std.testing.expect(!guardNoteFits(.running, .{ .returned_on = on, .waited_ms = 1 }, false));
    }
    try std.testing.expect(!guardNoteFits(.exited, .{ .returned_on = .exit, .waited_ms = 0 }, false));
    // A pattern search that did not finish has not shown the pattern absent.
    var unfinished = ran_out;
    unfinished.pattern = .{ .searched_to = .{ .stdout = 7, .stderr = null } };
    try std.testing.expect(!guardNoteFits(.running, unfinished, false));
}

test "BashOutput a backlog fills the page per channel, shared, and by encoded size" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const floor = result_budget.Budget.fromModel(0);
    const ctx = ToolContext{ .allocator = a, .jobs = &registry, .result_budget = floor };
    const allowance = floor.payloadAllowance(ENVELOPE_OVERHEAD_BYTES).raw();

    // One channel holds a full read of an explicit small max_bytes.
    const one = try registry.spawnBackground("printf '%0500d' 0; sleep 5", null);
    try waitForSpoolBytes(&registry, one.idSlice(), 500);
    var per_channel = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":5000,\"max_bytes\":100}}", .{one.idSlice()});
    defer per_channel.deinit();
    try std.testing.expectEqualStrings("backlog", envString(per_channel, "returned_on"));

    // Neither channel reaches max_bytes, but together they fill the result.
    const half = allowance * 2 / 3;
    var cmd: [256]u8 = undefined;
    const both = try registry.spawnBackground(try std.fmt.bufPrint(&cmd, "printf '%0{d}d' 0; printf '%0{d}d' 0 >&2; sleep 5", .{ half, half }), null);
    try waitForSpoolBytes(&registry, both.idSlice(), half);
    time.sleepMs(100);
    var shared = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":5000}}", .{both.idSlice()});
    defer shared.deinit();
    try std.testing.expectEqualStrings("backlog", envString(shared, "returned_on"));

    // Few raw bytes, but each ESC renders as six: the page is full anyway.
    const escapes = allowance / 4;
    const ansi = try registry.spawnBackground(try std.fmt.bufPrint(&cmd, "awk 'BEGIN {{ for(i=0;i<{d};i++) printf \"\\033\" }}'; sleep 5", .{escapes}), null);
    try waitForSpoolBytes(&registry, ansi.idSlice(), escapes);
    var encoded = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":5000}}", .{ansi.idSlice()});
    defer encoded.deinit();
    try std.testing.expectEqualStrings("backlog", envString(encoded, "returned_on"));
    try std.testing.expect(encoded.value.object.get("stdout_truncated").?.bool);
}

test "BashOutput pattern search carries across its own read chunks and never starts before the cursor" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };

    // "READY" straddles the first 16 KiB read of one scan.
    var cmd: [128]u8 = undefined;
    const prefix = SCAN_CHUNK_BYTES - 4;
    const long = try registry.spawnBackground(try std.fmt.bufPrint(&cmd, "printf '%0{d}d' 0; printf READY; sleep 5", .{prefix}), null);
    try waitForSpoolBytes(&registry, long.idSlice(), prefix + 5);
    var straddle = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":1000,\"pattern\":\"READY\"}}", .{long.idSlice()});
    defer straddle.deinit();
    try std.testing.expectEqualStrings("pattern", envString(straddle, "returned_on"));
    try std.testing.expectEqual(@as(i64, @intCast(prefix)), straddle.value.object.get("pattern_match").?.object.get("offset").?.integer);

    // The cursor sits inside "READY": that match is behind it, "ADY" is not.
    const short = try registry.spawnBackground("printf READY; sleep 5", null);
    try waitForSpoolBytes(&registry, short.idSlice(), 5);
    var head = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":0,\"max_bytes\":2}}", .{short.idSlice()});
    head.deinit();
    var behind = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":300,\"pattern\":\"READY\"}}", .{short.idSlice()});
    defer behind.deinit();
    try std.testing.expectEqualStrings("deadline", envString(behind, "returned_on"));
    try std.testing.expect(behind.value.object.get("pattern_match") == null);
    var ahead = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":300,\"pattern\":\"ADY\",\"stdout_since_byte\":2}}", .{short.idSlice()});
    defer ahead.deinit();
    try std.testing.expectEqualStrings("pattern", envString(ahead, "returned_on"));
    try std.testing.expectEqual(@as(i64, 2), ahead.value.object.get("pattern_match").?.object.get("offset").?.integer);
}

test "BashOutput reports a pattern already in the output without waiting or after the exit" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };

    const running = try registry.spawnBackground("printf 'x ERROR y'; sleep 5", null);
    try waitForSpoolBytes(&registry, running.idSlice(), 9);
    registry.extendPollStreak(running.idSlice(), time.nowMs(), time.nowMs(), POLL_GUARD_IDLE_RESET_MS);
    var snapshot = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":0,\"pattern\":\"ERROR\"}}", .{running.idSlice()});
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("snapshot", envString(snapshot, "returned_on"));
    try std.testing.expectEqual(@as(i64, 2), snapshot.value.object.get("pattern_match").?.object.get("offset").?.integer);
    // A snapshot neither counts nor resets, match or no match.
    try std.testing.expectEqual(@as(u8, 1), registry.get(running.idSlice()).?.poll_streak.low_yield);

    const ended = try registry.spawnBackground("printf ERROR; exit 0", null);
    try waitForExit(&registry, ended.idSlice());
    var exited = try poll(&ctx, "{{\"job_id\":\"{s}\",\"pattern\":\"ERROR\"}}", .{ended.idSlice()});
    defer exited.deinit();
    try std.testing.expectEqualStrings("exit", envString(exited, "returned_on"));
    try std.testing.expectEqual(@as(i64, 0), exited.value.object.get("pattern_match").?.object.get("offset").?.integer);
}

test "BashOutput until quiet keeps waiting for a job that has not printed yet" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const job = try registry.spawnBackground("sleep 5", null);
    var env = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":800,\"quiet_ms\":200}}", .{job.idSlice()});
    defer env.deinit();
    try std.testing.expectEqualStrings("deadline", envString(env, "returned_on"));
}

test "BashOutput the guard counts what a poll shows, not how big the spool is" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    // 300 bytes up front, then ticks: the spool is never small again, but
    // every poll after the first shows only a tick.
    const job = try registry.spawnBackground("printf '%0300d' 0; i=0; while [ $i -lt 30 ]; do printf 'tick\\n'; sleep 0.1; i=$((i+1)); done", null);
    try waitForSpoolBytes(&registry, job.idSlice(), 300);
    var i: usize = 0;
    while (i <= POLL_GUARD_STREAK) : (i += 1) {
        var env = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":10000,\"until\":\"output\"}}", .{job.idSlice()});
        defer env.deinit();
        try std.testing.expect(env.value.object.get("poll_guard") == null);
    }
    var guarded = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":10000,\"until\":\"output\"}}", .{job.idSlice()});
    defer guarded.deinit();
    try std.testing.expect(guarded.value.object.get("poll_guard") != null);
}

test "BashOutput envelope reservations cover their worst case" {
    const a = std.testing.allocator;
    const max = std.math.maxInt(u64);
    // The fixed envelope at its longest: every counter 20 digits, both
    // channels base64 and empty, an exit code, and either pattern result
    // (`PatternResult` holds one; an exited job can carry either).
    const pattern_fields = [_]Wait{
        .{ .returned_on = .exit, .waited_ms = max, .pattern = .{ .match = .{ .channel = .stderr, .offset = max } } },
        .{ .returned_on = .exit, .waited_ms = max, .pattern = .{ .searched_to = .{ .stdout = max, .stderr = max } } },
    };
    for (pattern_fields) |wait| {
        var base: std.Io.Writer.Allocating = .init(a);
        defer base.deinit();
        try base.writer.writeAll("{\"job_id\":\"0123456789ab\",\"status\":\"running\",\"exit_code\":-2147483648");
        inline for (.{ Channel.stdout, Channel.stderr }) |channel| {
            try writeChannel(&base.writer, a, @tagName(channel), "ÿ", true);
            try writeChannelCursor(&base.writer, channel, max, max, true);
        }
        try writeWaitFields(&base.writer, wait);
        try base.writer.writeAll("}");
        // writeChannel above rendered one byte of payload per channel ("/w==").
        try std.testing.expect(base.written().len - 2 * 4 <= ENVELOPE_OVERHEAD_BYTES.raw());
    }

    var guard: std.Io.Writer.Allocating = .init(a);
    defer guard.deinit();
    try writeGuardFields(&guard.writer, .{ .streak = std.math.maxInt(u8), .min_wait_ms = POLL_GUARD_MAX_WAIT_MS }, .{ .pattern = "x" }, true);
    try std.testing.expect(guard.written().len <= GUARD_ENVELOPE_BYTES.raw());
}

test "BashOutput finds a pattern far past one scan budget" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const filler = 5 * SCAN_BUDGET_BYTES + 1024;
    var cmd: [160]u8 = undefined;
    const job = try registry.spawnBackground(try std.fmt.bufPrint(&cmd, "head -c {d} /dev/zero | tr '\\000' x; printf READY; sleep 5", .{filler}), null);
    var attempts: usize = 0;
    while ((fileSize(registry.get(job.idSlice()).?.stdout_path) catch 0) < filler + 5) : (attempts += 1) {
        if (attempts > 500) return error.TestTimeout;
        time.sleepMs(10);
    }
    // One check scans a bounded slice. A snapshot reports how far that got
    // instead of a "not found"; a waiting call keeps scanning, without
    // sleeping between slices, until it catches up.
    var snapshot = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":0,\"pattern\":\"READY\",\"stdout_since_byte\":0}}", .{job.idSlice()});
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("snapshot", envString(snapshot, "returned_on"));
    try std.testing.expect(snapshot.value.object.get("pattern_match") == null);
    const searched = snapshot.value.object.get("pattern_searched_to").?.object;
    try std.testing.expectEqual(@as(i64, @intCast(SCAN_BUDGET_BYTES - ("READY".len - 1))), searched.get("stdout").?.integer);
    try std.testing.expect(searched.get("stderr") != null);
    // A 2 s poll slice: sleeping between the four remaining slices would take
    // 8 s, scanning straight through takes a fraction of that even on a busy
    // runner (measured up to ~2 s at 2x CPU oversubscription).
    const slice = withPollSlice(2_000);
    defer slice.restore();
    var waited = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":30000,\"pattern\":\"READY\",\"stdout_since_byte\":0}}", .{job.idSlice()});
    defer waited.deinit();
    try std.testing.expectEqualStrings("pattern", envString(waited, "returned_on"));
    try std.testing.expectEqual(@as(i64, @intCast(filler)), waited.value.object.get("pattern_match").?.object.get("offset").?.integer);
    try std.testing.expect(waited.value.object.get("waited_ms").?.integer < 6_000);
}

test "BashOutput under the guard a tiny max_bytes page is not a backlog" {
    const page: Page = .{ .max_bytes = 100, .allowance_raw = 24_000 };
    try std.testing.expect(page.channelFull(500));
    var guarded = page;
    guarded.guarded = true;
    try std.testing.expect(!guarded.channelFull(500));
    guarded.max_bytes = POLL_GUARD_LOW_YIELD_BYTES;
    try std.testing.expect(guarded.channelFull(POLL_GUARD_LOW_YIELD_BYTES));
    try std.testing.expect(!guarded.channelFull(POLL_GUARD_LOW_YIELD_BYTES - 1));
}

test "BashOutput the guard note matches what the wait was for" {
    const a = std.testing.allocator;
    const guard: PollGuard = .{ .streak = POLL_GUARD_STREAK, .min_wait_ms = POLL_GUARD_BASE_WAIT_MS };
    var exit_note: std.Io.Writer.Allocating = .init(a);
    defer exit_note.deinit();
    try writeGuardFields(&exit_note.writer, guard, .exit, true);
    try std.testing.expect(std.mem.indexOf(u8, exit_note.written(), "end your turn") != null);
    var pattern_note: std.Io.Writer.Allocating = .init(a);
    defer pattern_note.deinit();
    try writeGuardFields(&pattern_note.writer, guard, .{ .pattern = "READY" }, true);
    // Ending the turn waits for the exit, never for a pattern.
    try std.testing.expect(std.mem.indexOf(u8, pattern_note.written(), "end your turn") == null);
    try std.testing.expect(std.mem.indexOf(u8, pattern_note.written(), "pattern") != null);
}

test "BashOutput reports running out of memory as such, not as bad arguments" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const ctx = ToolContext{ .allocator = failing.allocator() };
    try std.testing.expectError(error.OutOfMemory, execute(&ctx, "{\"job_id\":\"deadbeef0001\"}"));
}

fn withPollSlice(slice_ms: u64) PollSliceRestore {
    const previous = poll_slice_ms_for_test;
    poll_slice_ms_for_test = slice_ms;
    return .{ .previous = previous };
}

const PollSliceRestore = struct {
    previous: u64,
    fn restore(self: PollSliceRestore) void {
        poll_slice_ms_for_test = self.previous;
    }
};

/// Shorten the guard's base wait to `base_ms` until `restore`.
fn withGuardBase(base_ms: u64) GuardBaseRestore {
    const previous = guard_base_wait_ms_for_test;
    guard_base_wait_ms_for_test = base_ms;
    return .{ .previous = previous };
}

const GuardBaseRestore = struct {
    previous: u64,
    fn restore(self: GuardBaseRestore) void {
        guard_base_wait_ms_for_test = self.previous;
    }
};

test "BashOutput a guarded wait that runs out raises the wait and says why" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const base = withGuardBase(300);
    defer base.restore();
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const job = try registry.spawnBackground("sleep 60", null);
    primeStreak(&registry, job.idSlice(), time.nowMs());
    var env = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":100}}", .{job.idSlice()});
    defer env.deinit();
    try std.testing.expectEqualStrings("deadline", envString(env, "returned_on"));
    // The 100 ms asked for became the guard's 300 ms floor.
    try std.testing.expect(env.value.object.get("waited_ms").?.integer >= 280);
    try std.testing.expectEqual(@as(i64, 300), env.value.object.get("poll_guard").?.object.get("min_wait_ms").?.integer);
    try std.testing.expect(env.value.object.get("note") != null);
    // A silent guarded wait extends the streak further.
    try std.testing.expectEqual(POLL_GUARD_STREAK + 1, registry.get(job.idSlice()).?.poll_streak.low_yield);
}

test "BashOutput a guarded result with a near-full page still fits its budget" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const base = withGuardBase(300);
    defer base.restore();
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const budget = result_budget.Budget.fromModel(200_000);
    const ctx = ToolContext{ .allocator = a, .jobs = &registry, .result_budget = budget };
    // Just under what an unguarded result could show: only the guard's own
    // reservation keeps it from overflowing once the note is added.
    const payload = budget.payloadAllowance(ENVELOPE_OVERHEAD_BYTES).raw() - 16;
    var cmd: [96]u8 = undefined;
    const job = try registry.spawnBackground(try std.fmt.bufPrint(&cmd, "printf '%0{d}d' 0; sleep 60", .{payload}), null);
    try waitForSpoolBytes(&registry, job.idSlice(), payload);
    primeStreak(&registry, job.idSlice(), time.nowMs());
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"wait_ms\":100}}", .{job.idSlice()});
    defer a.free(args);
    const out = try execute(&ctx, args);
    defer a.free(out);
    try std.testing.expect(out.len <= budget.per_result_bytes);
}

test "BashOutput under the guard a tiny max_bytes keeps waiting, a real full page resets the count" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const base = withGuardBase(300);
    defer base.restore();
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };

    const small = try registry.spawnBackground("printf '%0500d' 0; sleep 60", null);
    try waitForSpoolBytes(&registry, small.idSlice(), 500);
    primeStreak(&registry, small.idSlice(), time.nowMs());
    var tiny = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":100,\"max_bytes\":100}}", .{small.idSlice()});
    defer tiny.deinit();
    try std.testing.expectEqualStrings("deadline", envString(tiny, "returned_on"));
    try std.testing.expect(tiny.value.object.get("waited_ms").?.integer >= 280);

    const big = try registry.spawnBackground("awk 'BEGIN { for(i=0;i<100000;i++) printf \"x\" }'; sleep 60", null);
    try waitForSpoolBytes(&registry, big.idSlice(), 100_000);
    // A tiny max_bytes stays a tiny page however much is pending behind it.
    primeStreak(&registry, big.idSlice(), time.nowMs());
    var tiny_big = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":100,\"max_bytes\":100}}", .{big.idSlice()});
    defer tiny_big.deinit();
    try std.testing.expectEqualStrings("deadline", envString(tiny_big, "returned_on"));
    var full = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":100}}", .{big.idSlice()});
    defer full.deinit();
    try std.testing.expectEqualStrings("backlog", envString(full, "returned_on"));
    try std.testing.expectEqual(@as(u8, 0), registry.get(big.idSlice()).?.poll_streak.low_yield);
}

test "BashOutput ticks batched by a guarded wait keep the streak growing" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const base = withGuardBase(400);
    defer base.restore();
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    // 130-byte lines every 50 ms: a 400 ms guarded wait gathers well past
    // POLL_GUARD_LOW_YIELD_BYTES without filling a page.
    const job = try registry.spawnBackground("i=0; while [ $i -lt 100 ]; do printf '%0129d\\n' 0; sleep 0.05; i=$((i+1)); done", null);
    try waitForSpoolBytes(&registry, job.idSlice(), 1);
    var head = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":0}}", .{job.idSlice()});
    head.deinit();
    primeStreak(&registry, job.idSlice(), time.nowMs());
    var env = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":100,\"until\":\"output\"}}", .{job.idSlice()});
    defer env.deinit();
    try std.testing.expectEqualStrings("deadline", envString(env, "returned_on"));
    try std.testing.expect(envString(env, "stdout").len >= POLL_GUARD_LOW_YIELD_BYTES);
    try std.testing.expectEqual(POLL_GUARD_STREAK + 1, registry.get(job.idSlice()).?.poll_streak.low_yield);
}

test "BashOutput until quiet also returns a full page at once" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const job = try registry.spawnBackground("awk 'BEGIN { for(i=0;i<100000;i++) printf \"x\" }'; sleep 60", null);
    try waitForSpoolBytes(&registry, job.idSlice(), 100_000);
    var env = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":5000,\"quiet_ms\":2000}}", .{job.idSlice()});
    defer env.deinit();
    try std.testing.expectEqualStrings("backlog", envString(env, "returned_on"));
    try std.testing.expectEqual(@as(i64, 0), env.value.object.get("waited_ms").?.integer);
}

test "BashOutput finishes a pattern search on an exited job's long output" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const filler = 4 * SCAN_BUDGET_BYTES + 1024;
    var cmd: [128]u8 = undefined;
    const job = try registry.spawnBackground(try std.fmt.bufPrint(&cmd, "head -c {d} /dev/zero | tr '\\000' x; printf READY", .{filler}), null);
    var attempts: usize = 0;
    while (registry.get(job.idSlice()).?.status == .running) : (attempts += 1) {
        if (attempts > 500) return error.TestTimeout;
        time.sleepMs(10);
        registry.reapExited();
    }
    var env = try poll(&ctx, "{{\"job_id\":\"{s}\",\"pattern\":\"READY\"}}", .{job.idSlice()});
    defer env.deinit();
    try std.testing.expectEqualStrings("exit", envString(env, "returned_on"));
    try std.testing.expectEqual(@as(i64, @intCast(filler)), env.value.object.get("pattern_match").?.object.get("offset").?.integer);
    // Searching past the first slice took time, and the result says so.
    try std.testing.expect(env.value.object.get("waited_ms").?.integer > 0);
}

test "BashOutput waiting for the exit needs no channel" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const job = try registry.spawnBackground("sleep 60", null);
    var env = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":300,\"stdout\":false,\"stderr\":false}}", .{job.idSlice()});
    defer env.deinit();
    try std.testing.expectEqualStrings("deadline", envString(env, "returned_on"));
    try std.testing.expect(env.value.object.get("waited_ms").?.integer >= 280);
}

test "BashOutput settles a pattern search into how the call returned" {
    const at: PatternMatch = .{ .channel = .stdout, .offset = 9 };
    const frontier: SearchFrontier = .{ .stdout = 4, .stderr = null };
    const Case = struct { on: ReturnedOn, match: ?PatternMatch, behind: bool, want_on: ReturnedOn, want_match: bool, want_frontier: bool };
    const cases = [_]Case{
        // A late match beats the deadline ...
        .{ .on = .deadline, .match = at, .behind = false, .want_on = .pattern, .want_match = true, .want_frontier = false },
        // ... a snapshot and the exit keep their name and carry the match.
        .{ .on = .snapshot, .match = at, .behind = true, .want_on = .snapshot, .want_match = true, .want_frontier = false },
        .{ .on = .exit, .match = at, .behind = false, .want_on = .exit, .want_match = true, .want_frontier = false },
        // No match: only an unfinished search reports how far it got.
        .{ .on = .deadline, .match = null, .behind = true, .want_on = .deadline, .want_match = false, .want_frontier = true },
        .{ .on = .deadline, .match = null, .behind = false, .want_on = .deadline, .want_match = false, .want_frontier = false },
        .{ .on = .snapshot, .match = null, .behind = true, .want_on = .snapshot, .want_match = false, .want_frontier = true },
    };
    for (cases) |case| {
        var wait: Wait = .{ .returned_on = case.on, .waited_ms = 0 };
        settlePatternSearch(&wait, case.match, case.behind, frontier);
        try std.testing.expectEqual(case.want_on, wait.returned_on);
        const result = wait.pattern;
        try std.testing.expectEqual(case.want_match, result != null and result.? == .match);
        try std.testing.expectEqual(case.want_frontier, result != null and result.? == .searched_to);
    }
}

test "BashOutput a search resumed at pattern_searched_to finds a match straddling it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    // "READY" starts two bytes before the end of the first scan slice.
    const filler = SCAN_BUDGET_BYTES - 2;
    var cmd: [128]u8 = undefined;
    const job = try registry.spawnBackground(try std.fmt.bufPrint(&cmd, "head -c {d} /dev/zero | tr '\\000' x; printf READY; sleep 30", .{filler}), null);
    try waitForSpoolBytes(&registry, job.idSlice(), filler + 5);
    var snapshot = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":0,\"pattern\":\"READY\",\"stdout_since_byte\":0}}", .{job.idSlice()});
    defer snapshot.deinit();
    try std.testing.expect(snapshot.value.object.get("pattern_match") == null);
    const resume_at = snapshot.value.object.get("pattern_searched_to").?.object.get("stdout").?.integer;
    var resumed = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":1000,\"pattern\":\"READY\",\"stdout_since_byte\":{d}}}", .{ job.idSlice(), resume_at });
    defer resumed.deinit();
    try std.testing.expectEqualStrings("pattern", envString(resumed, "returned_on"));
    try std.testing.expectEqual(@as(i64, @intCast(filler)), resumed.value.object.get("pattern_match").?.object.get("offset").?.integer);
}

test "BashOutput a finished search without a match claims no frontier" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };

    const short = try registry.spawnBackground("printf nothing-here; sleep 30", null);
    try waitForSpoolBytes(&registry, short.idSlice(), 12);
    var none = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":300,\"pattern\":\"READY\"}}", .{short.idSlice()});
    defer none.deinit();
    try std.testing.expectEqualStrings("deadline", envString(none, "returned_on"));
    try std.testing.expect(none.value.object.get("pattern_searched_to") == null);

    // A search that fell behind for one slice and then caught up is finished.
    const long_filler = SCAN_BUDGET_BYTES + 1024;
    var cmd: [128]u8 = undefined;
    const long = try registry.spawnBackground(try std.fmt.bufPrint(&cmd, "head -c {d} /dev/zero | tr '\\000' x; sleep 30", .{long_filler}), null);
    try waitForSpoolBytes(&registry, long.idSlice(), long_filler);
    var caught_up = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":1000,\"pattern\":\"READY\",\"stdout_since_byte\":0}}", .{long.idSlice()});
    defer caught_up.deinit();
    try std.testing.expectEqualStrings("deadline", envString(caught_up, "returned_on"));
    try std.testing.expect(caught_up.value.object.get("pattern_searched_to") == null);
}

test "BashOutput the guard's idle gap runs from the last return to this start, not across its own wait" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // A 1.5 s guarded wait that starts 59 s after the last poll returned:
    // still back-to-back. Measured from its own return it would be 60.5 s,
    // past the 60 s idle reset, and the streak would start over at 1.
    const base = withGuardBase(1_500);
    defer base.restore();
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const job = try registry.spawnBackground("sleep 60", null);
    primeStreak(&registry, job.idSlice(), time.nowMs() - (POLL_GUARD_IDLE_RESET_MS - 1_000));
    var env = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":100}}", .{job.idSlice()});
    defer env.deinit();
    try std.testing.expect(env.value.object.get("poll_guard") != null);
    try std.testing.expectEqual(POLL_GUARD_STREAK + 1, registry.get(job.idSlice()).?.poll_streak.low_yield);
}

/// CPU time this process has used, in ms.
fn processCpuMs() i64 {
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    const micros = (@as(i64, @intCast(usage.utime.sec)) + @as(i64, @intCast(usage.stime.sec))) * std.time.us_per_s +
        @as(i64, @intCast(usage.utime.usec)) + @as(i64, @intCast(usage.stime.usec));
    return @divTrunc(micros, std.time.us_per_ms);
}

test "BashOutput until quiet waits for a first output that arrives after the call" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // The usual shape: start a server, then wait for its output to settle.
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const job = try registry.spawnBackground("sleep 0.3; printf x; sleep 30", null);
    var env = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":5000,\"quiet_ms\":400}}", .{job.idSlice()});
    defer env.deinit();
    try std.testing.expectEqualStrings("quiet", envString(env, "returned_on"));
    try std.testing.expectEqualStrings("x", envString(env, "stdout"));
}

test "BashOutput until quiet does not count output that was already read" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const job = try registry.spawnBackground("printf a; sleep 30", null);
    try waitForSpoolBytes(&registry, job.idSlice(), 1);
    var read = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":0}}", .{job.idSlice()});
    read.deinit();
    var env = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":1500,\"quiet_ms\":400}}", .{job.idSlice()});
    defer env.deinit();
    try std.testing.expectEqualStrings("deadline", envString(env, "returned_on"));
    try std.testing.expectEqualStrings("", envString(env, "stdout"));
}

test "BashOutput a pattern wait neither spins on a finished search nor between slices" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var registry = try JobRegistry.init(a);
    defer registry.deinit();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };

    // An exited job without the pattern: the search finishes at once.
    const ended = try registry.spawnBackground("printf nothing-here; exit 0", null);
    try waitForExit(&registry, ended.idSlice());
    const start = time.nowMs();
    var none = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":3000,\"pattern\":\"READY\"}}", .{ended.idSlice()});
    defer none.deinit();
    try std.testing.expect(time.nowMs() - start < 1000);
    try std.testing.expectEqualStrings("exit", envString(none, "returned_on"));
    try std.testing.expect(none.value.object.get("pattern_searched_to") == null);

    // A running job that prints nothing: the wait sleeps between slices.
    // CPU time is this process's own, so a loaded runner does not inflate it.
    const silent = try registry.spawnBackground("sleep 30", null);
    const cpu_before = processCpuMs();
    var waited = try poll(&ctx, "{{\"job_id\":\"{s}\",\"wait_ms\":1000,\"pattern\":\"READY\"}}", .{silent.idSlice()});
    defer waited.deinit();
    try std.testing.expectEqualStrings("deadline", envString(waited, "returned_on"));
    // Sleeping costs ~0-1 ms of CPU; spinning for the 1 s wait costs about
    // a core-second, still several hundred ms when the runner is oversubscribed.
    try std.testing.expect(processCpuMs() - cpu_before < 100);
}

test "BashOutput 的默认读取落在单条预算内" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // 默认值曾是 64KiB **源**字节,而 per-result 预算数的是**渲染后**字节、上限
    // 同样是 64KiB —— 两个不同的 64K。输出足够大时(下面构造的 100KB 纯 ASCII,
    // 已是最省字节的情形)默认读会产出 65_717 字节的结果,被投影层溢出成
    // artifact,模型拿回信封而不是它刚要的输出。
    //
    // 尾部情形而非常态:审计 314 次真实 BashOutput 结果,中位 164 字节,只有 1 次
    // 超过 200K 窗口的预算。值得修是因为它静默失败、且修法与 ReadArtifact 同源,
    // 不是因为它频繁发生。
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const j = try registry.spawnBackground("awk 'BEGIN { for(i=0;i<100000;i++) printf \"x\" }'", null);
    while (registry.get(j.idSlice())) |e| {
        if (e.status != .running) break;
        time.sleepMs(20);
        registry.reapExited();
    }
    registry.reapExited();

    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\",\"stdout_since_byte\":0,\"stderr_since_byte\":0}}", .{j.idSlice()});
    defer a.free(args);

    // 窄窗口与宽窗口都必须落在各自预算内。
    for ([_]usize{ 200_000, 1_048_576 }) |window| {
        const budget = result_budget.Budget.fromModel(window);
        const ctx = ToolContext{ .allocator = a, .jobs = &registry, .result_budget = budget };
        const out = try execute(&ctx, args);
        defer a.free(out);
        try std.testing.expect(out.len <= budget.per_result_bytes);

        var parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
        defer parsed.deinit();
        // 没读完就得说没读完 —— 调用方靠它决定要不要继续推进 since_byte。
        try std.testing.expect(parsed.value.object.get("stdout_truncated").?.bool);
        // 而且仍然给出真正的内容,不是空壳。
        try std.testing.expect(parsed.value.object.get("stdout").?.string.len > 4096);
        try std.testing.expectEqual(@as(i64, 100_000), parsed.value.object.get("stdout_total_bytes").?.integer);
    }
}

test "BashOutput 增量游标能真正续读,不跳过被预算裁掉的部分" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // `*_total_bytes` 是文件当前大小;schema 曾让模型拿它当下次 since_byte。
    // 读取按预算限界后,"展示到文件末尾"之间就有一大段——实测 100KB 文件首轮展示
    // 24488 字节,按 total 续读会永久跳过 75512 字节,而 truncated=true 却没给出
    // 任何可用位置。`*_next_offset` 就是那个位置。
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    const j = try registry.spawnBackground("awk 'BEGIN { for(i=0;i<100000;i++) printf \"x\" }'", null);
    while (registry.get(j.idSlice())) |e| {
        if (e.status != .running) break;
        time.sleepMs(20);
        registry.reapExited();
    }
    registry.reapExited();
    const ctx = ToolContext{
        .allocator = a,
        .jobs = &registry,
        .result_budget = result_budget.Budget.fromModel(200_000),
    };

    const first_args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\"}}", .{j.idSlice()});
    defer a.free(first_args);
    const first = try execute(&ctx, first_args);
    defer a.free(first);
    var first_parsed = try std.json.parseFromSlice(std.json.Value, a, first, .{});
    defer first_parsed.deinit();
    const shown_first = first_parsed.value.object.get("stdout").?.string.len;
    const next = first_parsed.value.object.get("stdout_next_offset").?.integer;
    try std.testing.expect(first_parsed.value.object.get("stdout_truncated").?.bool);
    // 游标 == 已展示的字节数,而不是文件总长。
    try std.testing.expectEqual(@as(i64, @intCast(shown_first)), next);
    try std.testing.expectEqual(@as(i64, 100_000), first_parsed.value.object.get("stdout_total_bytes").?.integer);

    // 第二轮从游标续读:必须真的拿到后面的内容,而不是空。
    const second_args = try std.fmt.allocPrint(
        a,
        "{{\"job_id\":\"{s}\",\"stdout_since_byte\":{d}}}",
        .{ j.idSlice(), next },
    );
    defer a.free(second_args);
    const second = try execute(&ctx, second_args);
    defer a.free(second);
    var second_parsed = try std.json.parseFromSlice(std.json.Value, a, second, .{});
    defer second_parsed.deinit();
    const shown_second = second_parsed.value.object.get("stdout").?.string.len;
    try std.testing.expect(shown_second > 0);
    // 两轮相加严格前进;若拿 total 当游标,第二轮会是 0。
    try std.testing.expect(shown_first + shown_second > shown_first);
    try std.testing.expectEqual(
        @as(i64, @intCast(shown_first + shown_second)),
        second_parsed.value.object.get("stdout_next_offset").?.integer,
    );
}

test "BashOutput 二进制通道走 base64,结果仍是合法 UTF-8 JSON" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // Zig 的 JSON writer 只转义控制符,0x80..0xff 原样写出——含非 UTF-8 字节的
    // 通道因此产出的根本不是合法 UTF-8。完成态信封一直按通道选编码并携带
    // `*_encoding`,这里没有。
    const a = std.testing.allocator;
    var registry = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer registry.deinit();
    // 八进制而非 `\xff`:job 走 `/bin/sh -c`,Linux 上那是 dash,它的 printf 不认
    // 十六进制转义,会原样吐出字面量 `A\xffB\xfe`——纯 ASCII,于是通道被判成 utf-8
    // 而不是 base64,断言在 Linux 上失败而在 macOS(/bin/sh 即 bash)上通过。
    // `\ddd` 是 POSIX printf 的八进制转义,dash 与 bash 都实现。
    const j = try registry.spawnBackground("printf 'A\\377B\\376'", null);
    while (registry.get(j.idSlice())) |e| {
        if (e.status != .running) break;
        time.sleepMs(20);
        registry.reapExited();
    }
    registry.reapExited();
    const ctx = ToolContext{ .allocator = a, .jobs = &registry };
    const args = try std.fmt.allocPrint(a, "{{\"job_id\":\"{s}\"}}", .{j.idSlice()});
    defer a.free(args);
    const out = try execute(&ctx, args);
    defer a.free(out);

    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    var parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("base64", parsed.value.object.get("stdout_encoding").?.string);
    // 而且解出来就是原始字节。
    const encoded = parsed.value.object.get("stdout").?.string;
    const decoder = std.base64.standard.Decoder;
    const decoded = try a.alloc(u8, try decoder.calcSizeForSlice(encoded));
    defer a.free(decoded);
    try decoder.decode(decoded, encoded);
    try std.testing.expectEqualSlices(u8, "A\xffB\xfe", decoded);
    // 纯文本通道不受影响。
    try std.testing.expectEqualStrings("utf-8", parsed.value.object.get("stderr_encoding").?.string);

    // 两条通道对称:模块头声明各带同样四个字段,stderr 的 encoding/next_offset 曾经
    // 实际会发但没写进契约。这里把"对称"这句话变成断言,免得它退回成一句自述。
    inline for (.{ "stdout", "stderr" }) |channel| {
        inline for (.{ "", "_encoding", "_total_bytes", "_next_offset", "_truncated" }) |suffix| {
            const field = channel ++ suffix;
            if (parsed.value.object.get(field) == null) {
                std.debug.print("BashOutput 信封缺字段: {s}\n", .{field});
                return error.ChannelFieldMissing;
            }
        }
    }
}
