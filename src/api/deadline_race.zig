const std = @import("std");
const util_time = @import("../util/time.zig");

pub const Error = error{
    TimedOut,
    Unavailable,
};

pub fn Answer(comptime task: anytype) type {
    return @typeInfo(@TypeOf(task)).@"fn".return_type.?;
}

pub fn Args(comptime task: anytype) type {
    return std.meta.ArgsTuple(@TypeOf(task));
}

pub fn run(
    io: std.Io,
    limit_ms: u32,
    comptime task: anytype,
    args: Args(task),
    comptime discard: fn (Args(task), Answer(task)) void,
) Error!Answer(task) {
    const Race = union(enum) {
        answer: Answer(task),
        deadline: std.Io.Cancelable!void,
    };
    const Drain = struct {
        fn all(race: *std.Io.Select(Race), task_args: Args(task)) void {
            while (race.cancel()) |late| switch (late) {
                .answer => |answer| discard(task_args, answer),
                .deadline => {},
            };
        }
    };
    var results: [2]Race = undefined;
    var race = std.Io.Select(Race).init(io, &results);
    race.concurrent(.answer, task, args) catch return error.Unavailable;
    race.concurrent(.deadline, sleep, .{ io, limit_ms }) catch {
        Drain.all(&race, args);
        return error.Unavailable;
    };
    const first = race.await() catch {
        Drain.all(&race, args);
        return error.Unavailable;
    };
    switch (first) {
        .answer => |answer| {
            race.cancelDiscard();
            return answer;
        },
        .deadline => {
            Drain.all(&race, args);
            return error.TimedOut;
        },
    }
}

fn sleep(io: std.Io, limit_ms: u32) std.Io.Cancelable!void {
    return util_time.sleepAtLeast(io, .{ .raw = .fromMilliseconds(@as(i64, limit_ms)), .clock = .awake });
}

const testing = std.testing;

const Probe = struct {
    fn quick(value: u32) error{Failed}!u32 {
        return value;
    }

    fn stuck(io: std.Io) error{Canceled}!u32 {
        while (true) try std.Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } }, io);
    }

    fn ignoreQuick(_: Args(quick), _: Answer(quick)) void {}
    fn ignoreStuck(_: Args(stuck), _: Answer(stuck)) void {}
};

test "deadline race: an answer before the deadline comes back as it is" {
    try testing.expectEqual(@as(u32, 7), try (try run(testing.io, 5_000, Probe.quick, .{7}, Probe.ignoreQuick)));
}

test "deadline race: an exchange that never answers ends at the deadline" {
    const started = util_time.nowMs();
    try testing.expectError(error.TimedOut, run(testing.io, 100, Probe.stuck, .{testing.io}, Probe.ignoreStuck));
    const waited = util_time.nowMs() - started;
    try testing.expect(waited >= 90);
    try testing.expect(waited < 5_000);
}
