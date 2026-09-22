//! Deterministic, process-level Zig test sharding for the metacodes core graph.
//!
//! The build compiles the suite once and runs this executable N times. Each
//! process selects tests by a stable hash of the full test name. Reports carry
//! count plus two commutative 64-bit fingerprints so the aggregate gate can
//! reject missing or duplicated coverage rather than trusting exit codes alone.

const builtin = @import("builtin");
const std = @import("std");

const shard_count_env = "METACODES_TEST_SHARD_COUNT";
const shard_index_env = "METACODES_TEST_SHARD_INDEX";
const fnv1a_offset_basis: u64 = 14_695_981_039_346_656_037;
const fnv1a_prime: u64 = 1_099_511_628_211;
const partition = "fnv1a64-name-v1";

const ShardConfig = struct {
    count: usize,
    index: usize,
};

const Fingerprint = struct {
    xor: u64 = 0,
    sum: u64 = 0,

    fn add(self: *Fingerprint, hash: u64) void {
        self.xor ^= hash;
        self.sum +%= hash;
    }
};

fn readUnsignedEnvironment(environ: std.process.Environ, key: []const u8) !usize {
    const allocator = std.heap.page_allocator;
    const raw = try environ.getAlloc(allocator, key);
    defer allocator.free(raw);
    return std.fmt.parseUnsigned(usize, raw, 10);
}

fn readShardConfig(environ: std.process.Environ) !ShardConfig {
    const count = try readUnsignedEnvironment(environ, shard_count_env);
    const index = try readUnsignedEnvironment(environ, shard_index_env);
    if (count == 0 or count > 64 or index >= count) return error.InvalidShardConfiguration;
    return .{ .count = count, .index = index };
}

fn hashTestName(name: []const u8) u64 {
    var hash = fnv1a_offset_basis;
    for (name) |byte| {
        hash ^= byte;
        hash *%= fnv1a_prime;
    }
    return hash;
}

fn shardForTest(name: []const u8, shard_count: usize) usize {
    return @intCast(hashTestName(name) % @as(u64, @intCast(shard_count)));
}

fn elapsedMs(elapsed_ns: u64) f64 {
    return @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
}

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();

    const shard = readShardConfig(init.environ) catch |err|
        std.debug.panic("invalid {s}/{s}: {t}", .{ shard_count_env, shard_index_env, err });
    const test_fns = builtin.test_functions;
    const runner_io = std.Io.Threaded.global_single_threaded.io();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), runner_io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var selected_total: usize = 0;
    var all_fingerprint: Fingerprint = .{};
    var selected_fingerprint: Fingerprint = .{};
    for (test_fns) |test_fn| {
        const hash = hashTestName(test_fn.name);
        all_fingerprint.add(hash);
        if (shardForTest(test_fn.name, shard.count) == shard.index) {
            selected_total = std.math.add(usize, selected_total, 1) catch
                @panic("selected test count overflow");
            selected_fingerprint.add(hash);
        }
    }

    stdout.print(
        "test_shard index={} count={} selected={} total={} partition={s} all_xor={x} all_sum={x}\n",
        .{ shard.index, shard.count, selected_total, test_fns.len, partition, all_fingerprint.xor, all_fingerprint.sum },
    ) catch @panic("failed to write test shard header");

    var selected_index: usize = 0;
    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaked: usize = 0;
    var total_ns: u64 = 0;

    for (test_fns, 0..) |test_fn, global_index| {
        if (shardForTest(test_fn.name, shard.count) != shard.index) continue;
        selected_index = std.math.add(usize, selected_index, 1) catch
            @panic("selected test index overflow");

        std.testing.allocator_instance = .{};
        std.testing.io_instance = .init(std.testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        // The fast gate stays terse: tests that intentionally exercise warning
        // paths should assert behavior, not make a successful build look like
        // a failed command. The timing diagnostic keeps .warn for investigation.
        std.testing.log_level = .err;
        std.testing.environ = init.environ;

        // The error return trace lives in this frame and is only appended to: every
        // `return error.X` that unwinds into this loop (a skip is one) leaves its frames
        // behind, so a later failure would print them ahead of its own. Start each test
        // from an empty trace so what is dumped belongs to the test that failed.
        if (@errorReturnTrace()) |trace| trace.index = 0;
        const start_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        const result = test_fn.func();
        const end_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        const elapsed_ns: u64 = @intCast(end_ns - start_ns);
        total_ns = std.math.add(u64, total_ns, elapsed_ns) catch
            @panic("aggregate test duration overflow");

        std.testing.io_instance.deinit();
        if (std.testing.allocator_instance.deinit() == .leak) {
            leaked = std.math.add(usize, leaked, 1) catch
                @panic("leaked test count overflow");
            std.debug.print(
                "test_time_ms={d:.3} status=leak shard={}/{} global_index={}/{} name=\"{s}\"\n",
                .{ elapsedMs(elapsed_ns), shard.index, shard.count, global_index + 1, test_fns.len, test_fn.name },
            );
        }

        if (result) |_| {
            passed = std.math.add(usize, passed, 1) catch
                @panic("passed test count overflow");
        } else |err| switch (err) {
            error.SkipZigTest => {
                skipped = std.math.add(usize, skipped, 1) catch
                    @panic("skipped test count overflow");
                stdout.print(
                    "test_time_ms={d:.3} status=skip shard={}/{} shard_index={}/{} global_index={}/{} name=\"{s}\"\n",
                    .{ elapsedMs(elapsed_ns), shard.index, shard.count, selected_index, selected_total, global_index + 1, test_fns.len, test_fn.name },
                ) catch @panic("failed to write skipped test result");
            },
            else => {
                failed = std.math.add(usize, failed, 1) catch
                    @panic("failed test count overflow");
                std.debug.print(
                    "test_time_ms={d:.3} status=fail error={t} shard={}/{} shard_index={}/{} global_index={}/{} name=\"{s}\"\n",
                    .{ elapsedMs(elapsed_ns), err, shard.index, shard.count, selected_index, selected_total, global_index + 1, test_fns.len, test_fn.name },
                );
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
    }

    stdout.print(
        "test_shard_summary index={} count={} selected={} passed={} skipped={} failed={} leaked={} test_total_ms={d:.3} partition={s} selected_xor={x} selected_sum={x}\n",
        .{ shard.index, shard.count, selected_total, passed, skipped, failed, leaked, elapsedMs(total_ns), partition, selected_fingerprint.xor, selected_fingerprint.sum },
    ) catch @panic("failed to write test shard summary");
    stdout.flush() catch @panic("failed to flush test shard summary");
    if (failed != 0 or leaked != 0) std.process.exit(1);
}

test "stable FNV partition does not drift" {
    try std.testing.expectEqual(@as(usize, 1), shardForTest("cli.test.example", 4));
}

test "each test name belongs to exactly one shard" {
    const names = [_][]const u8{ "suite.test.alpha", "suite.test.beta", "suite.test.gamma", "suite.test.delta" };
    for (1..9) |count| {
        for (names) |name| {
            var matches: usize = 0;
            for (0..count) |index| {
                if (shardForTest(name, count) == index) matches += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), matches);
        }
    }
}
