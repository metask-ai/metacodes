//! L2: schema-declared BashOutput wait_ms reaches the real dispatcher and envelope.
//!
//! Both jobs are gated on a file instead of a timer so the test controls the
//! release time; the child's scheduling only controls release-to-spool
//! latency:
//! - the delayed job prints only after a helper thread releases it a fixed
//!   delay after the test's timing origin, so the release delay is
//!   independent of shell start-up latency;
//! - the snapshot job is never released, so it cannot exit before the test
//!   asserts "running"; registry teardown kills it.
//! The jobs run with the temporary directory as their working directory and
//! name the gate files relatively, so no path is ever embedded in shell source.
//!
//! What a wall-clock test still cannot exclude is the test thread or the
//! child being descheduled for a long stretch at the wrong moment: the test
//! thread not reaching the dispatcher's first spool check until after the
//! release (then `waited_ms` is legitimately 0), the child not printing
//! before the tool's deadline, or the test thread sleeping through most of
//! the budget after the output arrived. Closing those needs a seam inside
//! the tool, which is not worth carrying for this test.

const std = @import("std");
const cc = @import("cc");

/// How long after the test's timing origin the helper thread releases the
/// delayed job's output. `waited_ms > 0` needs the dispatcher to reach its
/// first spool check within this window, so it is sized for a loaded hosted
/// runner, not for a quiet laptop.
const RELEASE_DELAY_MS: i64 = 1000;

/// The wait budget handed to BashOutput for the delayed job. Once scheduled,
/// the dispatcher normally observes the spool within one nominal 200 ms poll
/// slice of the release, so the budget only has to be generous: on a loaded
/// hosted runner a timer-driven job ran past a 2x margin (PR #141, Gates
/// (macOS), 250 ms job vs 500 ms budget). A 10x margin keeps the contract
/// identical and costs nothing when the output is on time.
const DELAYED_WAIT_MS: usize = 10_000;

fn inlineBytes(outcome: anytype) ![]const u8 {
    return switch (outcome.*) {
        .ok => |body| switch (body) {
            .@"inline" => |result| result.bytes,
            else => error.UnexpectedBashOutputBody,
        },
        else => error.UnexpectedBashOutputOutcome,
    };
}

fn rootPath(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..len];
}

/// Creates the release file after the delay and records when it did so.
/// A failure to create it is recorded as the error's integer code so the
/// test can name it, and the dispatch is aborted as a host failure so the
/// test reports the infrastructure error at once instead of after BashOutput
/// has run out its budget.
///
/// The `std.Io.Dir` handle is a copy of the test's; the test keeps the
/// directory alive (no cleanup) until this thread has been joined.
const Releaser = struct {
    fn run(
        dir: std.Io.Dir,
        released_at: *std.atomic.Value(i64),
        failure: *std.atomic.Value(u16),
        abort: *cc.util_abort.AbortSignal,
    ) void {
        cc.util_time.sleepMs(@intCast(RELEASE_DELAY_MS));
        const file = dir.createFile(std.testing.io, "release", .{}) catch |err| {
            failure.store(@intFromError(err), .release);
            abort.abort(.host_failure);
            return;
        };
        file.close(std.testing.io);
        released_at.store(cc.util_time.nowMs(), .release);
    }
};

test "BashOutput L2 wait_ms schema drives a visible wait and waited_ms" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    var jobs = try cc.job_registry.JobRegistry.init(allocator);
    defer jobs.deinit();
    var abort = cc.util_abort.AbortSignal.init();
    var ctx = cc.tools.ToolContext{ .allocator = allocator, .jobs = &jobs, .abort = &abort };

    const delayed = try jobs.spawnBackground(
        "while [ ! -e release ]; do sleep 0.02; done; printf schema",
        root,
    );
    var delayed_input: [256]u8 = undefined;
    const delayed_json = try std.fmt.bufPrint(
        &delayed_input,
        "{{\"job_id\":\"{s}\",\"wait_ms\":{d}}}",
        .{ delayed.idSlice(), DELAYED_WAIT_MS },
    );

    var released_at = std.atomic.Value(i64).init(0);
    var release_failure = std.atomic.Value(u16).init(0);
    const started = cc.util_time.nowMs();
    const releaser = try std.Thread.spawn(.{}, Releaser.run, .{ tmp.dir, &released_at, &release_failure, &abort });
    // The helper writes to this frame, so it must be joined on every exit
    // path, and only once: this defer covers an error before the explicit
    // join below, which is what the timing assertions need.
    var releaser_joined = false;
    defer if (!releaser_joined) releaser.join();
    var delayed_result = cc.tools.dispatch(&ctx, "BashOutput", delayed_json);
    const returned_at = cc.util_time.nowMs();
    releaser.join();
    releaser_joined = true;
    // A helper failure aborts the dispatch, so name it before looking at
    // what the dispatch returned.
    const release_failure_code = release_failure.load(.acquire);
    if (release_failure_code != 0) {
        if (delayed_result) |*outcome| outcome.deinit(allocator) else |_| {}
        std.debug.print("release file could not be created: {s}\n", .{@errorName(@errorFromInt(release_failure_code))});
        return error.ReleaseFileNotCreated;
    }
    var delayed_outcome = try delayed_result;
    defer delayed_outcome.deinit(allocator);
    try std.testing.expect(released_at.load(.acquire) > 0);
    const delayed_bytes = try inlineBytes(&delayed_outcome);
    var delayed_body = try std.json.parseFromSlice(std.json.Value, allocator, delayed_bytes, .{});
    defer delayed_body.deinit();
    try std.testing.expectEqualStrings("schema", delayed_body.value.object.get("stdout").?.string);
    // The output did not exist before the release, so the dispatch spanned
    // the whole release delay ...
    try std.testing.expect(returned_at >= released_at.load(.acquire));
    try std.testing.expect(returned_at - started >= RELEASE_DELAY_MS);
    // ... and returned on readiness, not by running out the budget.
    try std.testing.expect(returned_at - started < @as(i64, @intCast(DELAYED_WAIT_MS)));
    // The envelope reports a wait that fits inside the dispatch.
    const waited_ms = delayed_body.value.object.get("waited_ms").?.integer;
    try std.testing.expect(waited_ms > 0);
    try std.testing.expect(waited_ms <= returned_at - started);

    // wait_ms 0 is a snapshot: no wait, and the job is still running. Nothing
    // ever creates this job's gate file, so it stays running until the
    // registry tears it down.
    const snapshot = try jobs.spawnBackground("while [ ! -e never ]; do sleep 0.02; done", root);
    var snapshot_input: [256]u8 = undefined;
    const snapshot_json = try std.fmt.bufPrint(
        &snapshot_input,
        "{{\"job_id\":\"{s}\",\"wait_ms\":0}}",
        .{snapshot.idSlice()},
    );
    const snapshot_started = cc.util_time.nowMs();
    var snapshot_outcome = try cc.tools.dispatch(&ctx, "BashOutput", snapshot_json);
    defer snapshot_outcome.deinit(allocator);
    const snapshot_bytes = try inlineBytes(&snapshot_outcome);
    try std.testing.expect(cc.util_time.nowMs() - snapshot_started < 2000);
    var snapshot_body = try std.json.parseFromSlice(std.json.Value, allocator, snapshot_bytes, .{});
    defer snapshot_body.deinit();
    try std.testing.expectEqual(@as(i64, 0), snapshot_body.value.object.get("waited_ms").?.integer);
    try std.testing.expectEqualStrings("running", snapshot_body.value.object.get("status").?.string);
}
