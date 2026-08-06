//! Diagnostic Zig test runner that keeps ordinary test semantics while
//! reporting where the wall clock goes. This is intentionally a separate
//! build entry point: timing output is evidence, not part of the fast gate.

const builtin = @import("builtin");
const std = @import("std");

const slow_test_top_count = 24;

const SlowTest = struct {
    elapsed_ns: u64 = 0,
    name: []const u8 = "",
};

fn elapsedMs(elapsed_ns: u64) f64 {
    return @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;
}

fn insertSlowest(top: *[slow_test_top_count]SlowTest, elapsed_ns: u64, name: []const u8) void {
    if (elapsed_ns <= top[top.len - 1].elapsed_ns) return;

    var index: usize = 0;
    while (index < top.len and elapsed_ns <= top[index].elapsed_ns) : (index += 1) {}

    var shift = top.len - 1;
    while (shift > index) : (shift -= 1) top[shift] = top[shift - 1];
    top[index] = .{ .elapsed_ns = elapsed_ns, .name = name };
}

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();

    const test_fns = builtin.test_functions;
    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaked: usize = 0;
    var slow_20_count: usize = 0;
    var slow_50_count: usize = 0;
    var slow_100_count: usize = 0;
    var slow_20_ns: u64 = 0;
    var slow_50_ns: u64 = 0;
    var slow_100_ns: u64 = 0;
    var slowest = [_]SlowTest{.{}} ** slow_test_top_count;
    var total_ns: u64 = 0;

    for (test_fns, 0..) |test_fn, index| {
        std.testing.allocator_instance = .{};
        std.testing.io_instance = .init(std.testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        defer {
            std.testing.io_instance.deinit();
            if (std.testing.allocator_instance.deinit() == .leak) {
                leaked = std.math.add(usize, leaked, 1) catch
                    @panic("leaked test count overflow");
            }
        }

        std.testing.log_level = .warn;
        std.testing.environ = init.environ;

        const start_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        const result = test_fn.func();
        const end_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        const elapsed_ns: u64 = @intCast(end_ns - start_ns);
        total_ns = std.math.add(u64, total_ns, elapsed_ns) catch
            @panic("aggregate test duration overflow");
        insertSlowest(&slowest, elapsed_ns, test_fn.name);

        if (elapsed_ns >= 20 * std.time.ns_per_ms) {
            slow_20_count = std.math.add(usize, slow_20_count, 1) catch
                @panic("20ms slow-test count overflow");
            slow_20_ns = std.math.add(u64, slow_20_ns, elapsed_ns) catch
                @panic("20ms slow-test duration overflow");
        }
        if (elapsed_ns >= 50 * std.time.ns_per_ms) {
            slow_50_count = std.math.add(usize, slow_50_count, 1) catch
                @panic("50ms slow-test count overflow");
            slow_50_ns = std.math.add(u64, slow_50_ns, elapsed_ns) catch
                @panic("50ms slow-test duration overflow");
        }
        if (elapsed_ns >= 100 * std.time.ns_per_ms) {
            slow_100_count = std.math.add(usize, slow_100_count, 1) catch
                @panic("100ms slow-test count overflow");
            slow_100_ns = std.math.add(u64, slow_100_ns, elapsed_ns) catch
                @panic("100ms slow-test duration overflow");
        }

        const status: []const u8 = if (result) |_| blk: {
            passed = std.math.add(usize, passed, 1) catch
                @panic("passed test count overflow");
            break :blk "ok";
        } else |err| switch (err) {
            error.SkipZigTest => blk: {
                skipped = std.math.add(usize, skipped, 1) catch
                    @panic("skipped test count overflow");
                break :blk "skip";
            },
            else => blk: {
                failed = std.math.add(usize, failed, 1) catch
                    @panic("failed test count overflow");
                std.debug.print(
                    "test_time_ms={d:.3} status=fail error={t} index={d}/{d} name=\"{s}\"\n",
                    .{ elapsedMs(elapsed_ns), err, index + 1, test_fns.len, test_fn.name },
                );
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
                break :blk "fail";
            },
        };
        if (!std.mem.eql(u8, status, "fail")) {
            std.debug.print(
                "test_time_ms={d:.3} status={s} index={d}/{d} name=\"{s}\"\n",
                .{ elapsedMs(elapsed_ns), status, index + 1, test_fns.len, test_fn.name },
            );
        }
    }

    std.debug.print("test_slow_bucket threshold_ms=20 count={} total_ms={d:.3}\n", .{ slow_20_count, elapsedMs(slow_20_ns) });
    std.debug.print("test_slow_bucket threshold_ms=50 count={} total_ms={d:.3}\n", .{ slow_50_count, elapsedMs(slow_50_ns) });
    std.debug.print("test_slow_bucket threshold_ms=100 count={} total_ms={d:.3}\n", .{ slow_100_count, elapsedMs(slow_100_ns) });
    for (slowest, 0..) |entry, rank| {
        if (entry.elapsed_ns == 0) break;
        std.debug.print(
            "test_slow_top rank={} test_time_ms={d:.3} name=\"{s}\"\n",
            .{ rank + 1, elapsedMs(entry.elapsed_ns), entry.name },
        );
    }
    std.debug.print(
        "test_total_ms={d:.3} passed={} skipped={} failed={} leaked={}\n",
        .{ elapsedMs(total_ns), passed, skipped, failed, leaked },
    );
    if (failed != 0 or leaked != 0) std.process.exit(1);
}
