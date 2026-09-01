//! UI-independent, thread-safe operational counters for tool-result
//! projection and recovery. The snapshot is intentionally plain data so the
//! evaluation harness and future Lean observation adapter can consume it
//! without coupling either one to the agent loop.

const std = @import("std");
const projection = @import("result_projection.zig");

pub const Snapshot = struct {
    /// Bytes tools produced, measured at the Conversation projection seam. A
    /// Bash v2 envelope is billed by what its channels actually captured, not
    /// by the small envelope that carries them, so this and `projected_bytes`
    /// really are a before/after pair. `captured_stream_bytes` remains the
    /// independent count taken inside the Bash channel writer.
    raw_bytes: u64,
    projected_bytes: u64,
    captured_stream_bytes: u64,
    artifact_bytes: u64,
    artifact_spill_count: u64,
    artifact_recovery_calls: u64,
    artifact_recovered_bytes: u64,
    unrecoverable_fallback_count: u64,
    structured_result_count: u64,
    structured_projection_failures: u64,
    turn_budget_spills: u64,
    /// Image results kept inline that byte-length rules would otherwise have
    /// spilled (over the per-result cap); see result_projection.Stats.
    image_exempt_count: u64,
    /// Committed artifact envelopes re-rendered against this turn's budget,
    /// and of those the ones returned to the model in full.
    envelope_regrown_count: u64,
    envelope_reinlined_count: u64,
    budget_exhausted_count: u64,
};

pub const Metrics = struct {
    raw_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    projected_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    captured_stream_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    artifact_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    artifact_spill_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    artifact_recovery_calls: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    artifact_recovered_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    unrecoverable_fallback_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    structured_result_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    structured_projection_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    turn_budget_spills: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    image_exempt_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    envelope_regrown_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    envelope_reinlined_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    budget_exhausted_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn recordProjection(self: *Metrics, stats: projection.Stats) void {
        add(&self.raw_bytes, stats.raw_bytes);
        add(&self.projected_bytes, stats.projected_bytes);
        add(&self.artifact_bytes, stats.artifact_bytes);
        add(&self.artifact_spill_count, stats.artifact_spill_count);
        add(&self.unrecoverable_fallback_count, stats.unrecoverable_fallback_count);
        add(&self.structured_result_count, stats.structured_result_count);
        add(&self.structured_projection_failures, stats.structured_projection_failures);
        add(&self.turn_budget_spills, stats.turn_budget_spills);
        add(&self.image_exempt_count, stats.image_exempt_count);
        add(&self.envelope_regrown_count, stats.envelope_regrown_count);
        add(&self.envelope_reinlined_count, stats.envelope_reinlined_count);
        if (stats.budget_exhausted) add(&self.budget_exhausted_count, 1);
    }

    pub fn recordRecovery(self: *Metrics, bytes: usize) void {
        add(&self.artifact_recovery_calls, 1);
        add(&self.artifact_recovered_bytes, bytes);
    }

    pub fn recordCapturedStream(self: *Metrics, bytes: u64) void {
        _ = self.captured_stream_bytes.fetchAdd(bytes, .monotonic);
    }

    pub fn recordDirectArtifact(self: *Metrics, bytes: u64) void {
        _ = self.artifact_spill_count.fetchAdd(1, .monotonic);
        _ = self.artifact_bytes.fetchAdd(bytes, .monotonic);
    }

    pub fn recordDirectFallback(self: *Metrics) void {
        _ = self.unrecoverable_fallback_count.fetchAdd(1, .monotonic);
    }

    pub fn snapshot(self: *const Metrics) Snapshot {
        return .{
            .raw_bytes = self.raw_bytes.load(.monotonic),
            .projected_bytes = self.projected_bytes.load(.monotonic),
            .captured_stream_bytes = self.captured_stream_bytes.load(.monotonic),
            .artifact_bytes = self.artifact_bytes.load(.monotonic),
            .artifact_spill_count = self.artifact_spill_count.load(.monotonic),
            .artifact_recovery_calls = self.artifact_recovery_calls.load(.monotonic),
            .artifact_recovered_bytes = self.artifact_recovered_bytes.load(.monotonic),
            .unrecoverable_fallback_count = self.unrecoverable_fallback_count.load(.monotonic),
            .structured_result_count = self.structured_result_count.load(.monotonic),
            .structured_projection_failures = self.structured_projection_failures.load(.monotonic),
            .turn_budget_spills = self.turn_budget_spills.load(.monotonic),
            .image_exempt_count = self.image_exempt_count.load(.monotonic),
            .envelope_regrown_count = self.envelope_regrown_count.load(.monotonic),
            .envelope_reinlined_count = self.envelope_reinlined_count.load(.monotonic),
            .budget_exhausted_count = self.budget_exhausted_count.load(.monotonic),
        };
    }
};

fn add(counter: *std.atomic.Value(u64), value: usize) void {
    _ = counter.fetchAdd(@intCast(value), .monotonic);
}

test "metrics aggregate projection and recovery without UI state" {
    var metrics = Metrics{};
    metrics.recordProjection(.{
        .raw_bytes = 100,
        .projected_bytes = 20,
        .artifact_bytes = 100,
        .artifact_spill_count = 1,
        .structured_result_count = 1,
        .turn_budget_spills = 1,
    });
    metrics.recordRecovery(32);
    metrics.recordCapturedStream(256);
    const observed = metrics.snapshot();
    try std.testing.expectEqual(@as(u64, 100), observed.raw_bytes);
    try std.testing.expectEqual(@as(u64, 1), observed.artifact_spill_count);
    try std.testing.expectEqual(@as(u64, 1), observed.artifact_recovery_calls);
    try std.testing.expectEqual(@as(u64, 32), observed.artifact_recovered_bytes);
    try std.testing.expectEqual(@as(u64, 256), observed.captured_stream_bytes);
}
