//! Fail-closed aggregate verifier for reports from sharded_test_runner.zig.

const std = @import("std");

const Report = struct {
    index: usize,
    count: usize,
    total: usize,
    selected: usize,
    passed: usize,
    skipped: usize,
    failed: usize,
    leaked: usize,
    test_total_ms: f64,
    partition: []const u8,
    all_xor: u64,
    all_sum: u64,
    selected_xor: u64,
    selected_sum: u64,
};

const Summary = struct {
    total: usize,
    passed: usize,
    skipped: usize,
    critical_path_ms: f64,
    partition: []const u8,
};

fn fieldValue(line: []const u8, key: []const u8) ![]const u8 {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    _ = fields.next();
    var found: ?[]const u8 = null;
    while (fields.next()) |field| {
        const separator = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        if (std.mem.eql(u8, field[0..separator], key)) {
            if (found != null) return error.DuplicateShardReportField;
            found = field[separator + 1 ..];
        }
    }
    return found orelse error.MissingShardReportField;
}

fn unsignedField(line: []const u8, key: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, try fieldValue(line, key), 10);
}

fn hexField(line: []const u8, key: []const u8) !u64 {
    return std.fmt.parseUnsigned(u64, try fieldValue(line, key), 16);
}

fn parseReport(bytes: []const u8) !Report {
    var header: ?[]const u8 = null;
    var summary: ?[]const u8 = null;
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "test_shard index=")) {
            if (header != null) return error.DuplicateShardReportHeader;
            header = line;
        }
        if (std.mem.startsWith(u8, line, "test_shard_summary index=")) {
            if (summary != null) return error.DuplicateShardReportSummary;
            summary = line;
        }
    }

    const header_line = header orelse return error.MissingShardReportHeader;
    const summary_line = summary orelse return error.MissingShardReportSummary;
    const report: Report = .{
        .index = try unsignedField(summary_line, "index"),
        .count = try unsignedField(summary_line, "count"),
        .total = try unsignedField(header_line, "total"),
        .selected = try unsignedField(summary_line, "selected"),
        .passed = try unsignedField(summary_line, "passed"),
        .skipped = try unsignedField(summary_line, "skipped"),
        .failed = try unsignedField(summary_line, "failed"),
        .leaked = try unsignedField(summary_line, "leaked"),
        .test_total_ms = try std.fmt.parseFloat(f64, try fieldValue(summary_line, "test_total_ms")),
        .partition = try fieldValue(summary_line, "partition"),
        .all_xor = try hexField(header_line, "all_xor"),
        .all_sum = try hexField(header_line, "all_sum"),
        .selected_xor = try hexField(summary_line, "selected_xor"),
        .selected_sum = try hexField(summary_line, "selected_sum"),
    };
    if (!std.math.isFinite(report.test_total_ms) or report.test_total_ms < 0) return error.InvalidShardTestTime;
    if (report.index != try unsignedField(header_line, "index") or
        report.count != try unsignedField(header_line, "count") or
        report.selected != try unsignedField(header_line, "selected") or
        !std.mem.eql(u8, report.partition, try fieldValue(header_line, "partition")))
    {
        return error.InconsistentShardReport;
    }
    return report;
}

fn verifyReports(reports: []const Report) !Summary {
    if (reports.len == 0 or reports.len > 64) return error.InvalidShardReportCount;

    var seen: u64 = 0;
    var expected_total: ?usize = null;
    var expected_partition: ?[]const u8 = null;
    var expected_all_xor: ?u64 = null;
    var expected_all_sum: ?u64 = null;
    var selected: usize = 0;
    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaked: usize = 0;
    var selected_xor: u64 = 0;
    var selected_sum: u64 = 0;
    var critical_path_ms: f64 = 0;

    for (reports) |report| {
        if (report.count != reports.len or report.index >= report.count) return error.InvalidShardReportIdentity;
        const bit = @as(u64, 1) << @intCast(report.index);
        if (seen & bit != 0) return error.DuplicateShardReport;
        seen |= bit;

        if (expected_total) |value| {
            if (report.total != value) return error.InconsistentShardTestTotal;
        } else expected_total = report.total;
        if (expected_partition) |value| {
            if (!std.mem.eql(u8, report.partition, value)) return error.InconsistentShardPartition;
        } else expected_partition = report.partition;
        if (expected_all_xor) |value| {
            if (report.all_xor != value) return error.InconsistentAllTestFingerprint;
        } else expected_all_xor = report.all_xor;
        if (expected_all_sum) |value| {
            if (report.all_sum != value) return error.InconsistentAllTestFingerprint;
        } else expected_all_sum = report.all_sum;

        const accounted = try std.math.add(usize, try std.math.add(usize, report.passed, report.skipped), report.failed);
        if (accounted != report.selected) return error.InvalidShardResultTotal;
        selected = try std.math.add(usize, selected, report.selected);
        passed = try std.math.add(usize, passed, report.passed);
        skipped = try std.math.add(usize, skipped, report.skipped);
        failed = try std.math.add(usize, failed, report.failed);
        leaked = try std.math.add(usize, leaked, report.leaked);
        selected_xor ^= report.selected_xor;
        selected_sum +%= report.selected_sum;
        critical_path_ms = @max(critical_path_ms, report.test_total_ms);
    }

    const expected_seen = if (reports.len == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(reports.len)) - 1;
    if (seen != expected_seen) return error.IncompleteShardSet;
    const total = expected_total.?;
    if (total == 0) return error.EmptyTestSuite;
    const result_total = try std.math.add(usize, try std.math.add(usize, passed, skipped), failed);
    if (selected != total or result_total != total) return error.IncompleteTestCoverage;
    if (selected_xor != expected_all_xor.? or selected_sum != expected_all_sum.?) return error.IncompleteTestFingerprint;
    if (failed != 0 or leaked != 0) return error.FailedShardReportedSuccess;

    return .{
        .total = total,
        .passed = passed,
        .skipped = skipped,
        .critical_path_ms = critical_path_ms,
        .partition = expected_partition.?,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const report_paths = args[1..];
    if (report_paths.len == 0 or report_paths.len > 64) return error.InvalidShardReportCount;

    const reports = try allocator.alloc(Report, report_paths.len);
    for (report_paths, 0..) |path, index| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(1024 * 1024));
        reports[index] = try parseReport(bytes);
    }
    const summary = try verifyReports(reports);

    for (0..reports.len) |expected_index| {
        const report = for (reports) |candidate| {
            if (candidate.index == expected_index) break candidate;
        } else return error.IncompleteShardSet;
        std.debug.print(
            "test_shard_verified index={} count={} selected={} passed={} skipped={} test_total_ms={d:.3} partition={s}\n",
            .{ report.index, report.count, report.selected, report.passed, report.skipped, report.test_total_ms, report.partition },
        );
    }
    std.debug.print(
        "test_shards_summary count={} total={} passed={} skipped={} failed=0 leaked=0 critical_path_ms={d:.3} partition={s}\n",
        .{ reports.len, summary.total, summary.passed, summary.skipped, summary.critical_path_ms, summary.partition },
    );
}

fn sampleReport(index: usize) Report {
    return .{
        .index = index,
        .count = 2,
        .total = 3,
        .selected = if (index == 0) 2 else 1,
        .passed = if (index == 0) 2 else 1,
        .skipped = 0,
        .failed = 0,
        .leaked = 0,
        .test_total_ms = @floatFromInt(index + 1),
        .partition = "fnv1a64-name-v1",
        .all_xor = 0x6,
        .all_sum = 0x6,
        .selected_xor = if (index == 0) 0x3 else 0x5,
        .selected_sum = if (index == 0) 0x1 else 0x5,
    };
}

test "parse report rejects header-summary drift" {
    const valid =
        \\test_shard index=1 count=2 selected=1 total=3 partition=fnv1a64-name-v1 all_xor=6 all_sum=6
        \\test_shard_summary index=1 count=2 selected=1 passed=1 skipped=0 failed=0 leaked=0 test_total_ms=2.0 partition=fnv1a64-name-v1 selected_xor=5 selected_sum=5
    ;
    const report = try parseReport(valid);
    try std.testing.expectEqual(@as(usize, 3), report.total);
    try std.testing.expectEqual(@as(u64, 5), report.selected_xor);

    const inconsistent =
        \\test_shard index=1 count=2 selected=1 total=3 partition=fnv1a64-name-v1 all_xor=6 all_sum=6
        \\test_shard_summary index=0 count=2 selected=1 passed=1 skipped=0 failed=0 leaked=0 test_total_ms=2.0 partition=fnv1a64-name-v1 selected_xor=5 selected_sum=5
    ;
    try std.testing.expectError(error.InconsistentShardReport, parseReport(inconsistent));

    const duplicate_field =
        \\test_shard index=1 count=2 selected=1 total=3 total=3 partition=fnv1a64-name-v1 all_xor=6 all_sum=6
        \\test_shard_summary index=1 count=2 selected=1 passed=1 skipped=0 failed=0 leaked=0 test_total_ms=2.0 partition=fnv1a64-name-v1 selected_xor=5 selected_sum=5
    ;
    try std.testing.expectError(error.DuplicateShardReportField, parseReport(duplicate_field));
}

test "aggregate verifies exact count and commutative fingerprints" {
    const reports = [_]Report{ sampleReport(0), sampleReport(1) };
    const summary = try verifyReports(&reports);
    try std.testing.expectEqual(@as(usize, 3), summary.total);
    try std.testing.expectEqual(@as(f64, 2), summary.critical_path_ms);

    var duplicate = reports;
    duplicate[1].index = 0;
    try std.testing.expectError(error.DuplicateShardReport, verifyReports(&duplicate));

    var missing_name = reports;
    missing_name[1].selected_xor = 0x4;
    try std.testing.expectError(error.IncompleteTestFingerprint, verifyReports(&missing_name));

    var hidden_failure = reports;
    hidden_failure[1].passed = 0;
    hidden_failure[1].failed = 1;
    try std.testing.expectError(error.FailedShardReportedSuccess, verifyReports(&hidden_failure));

    var empty = reports;
    for (&empty) |*report| {
        report.total = 0;
        report.selected = 0;
        report.passed = 0;
        report.selected_xor = 0;
        report.selected_sum = 0;
        report.all_xor = 0;
        report.all_sum = 0;
    }
    try std.testing.expectError(error.EmptyTestSuite, verifyReports(&empty));
}
