const builtin = @import("builtin");
const std = @import("std");
const test_id_record = @import("test_id_record.zig");
const testing = std.testing;

pub const std_options: std.Options = .{
    .logFn = log,
};

comptime {
    if (builtin.fuzz) @compileError("scripts/recording_test_runner.zig does not run fuzz tests");
}

const runner_io = std.Io.Threaded.global_single_threaded.io();
var log_err_count: usize = 0;
var stdin_buffer: [4096]u8 = undefined;
var stdout_buffer: [4096]u8 = undefined;
var stdin_reader: std.Io.File.Reader = undefined;
var stdout_writer: std.Io.File.Writer = undefined;
var test_ids: test_id_record.Record = undefined;
var test_ids_buffer: [4096]u8 = undefined;
var recording = false;
var picker_trace: ?std.Io.File.Writer = null;
var trace_buffer: [1024]u8 = undefined;

fn openPickerTrace(environ: std.process.Environ, argv0: []const u8) !void {
    if (!std.mem.eql(u8, std.fs.path.stem(argv0), "picker-test")) return;
    const path = environ.getAlloc(std.heap.page_allocator, "METACODES_PICKER_TRACE") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return,
        else => return err,
    };
    defer std.heap.page_allocator.free(path);
    const file = try std.Io.Dir.cwd().createFile(runner_io, path, .{ .truncate = false });
    errdefer file.close(runner_io);
    var writer = file.writer(runner_io, &trace_buffer);
    try writer.seekTo(try file.length(runner_io));
    picker_trace = writer;
    try trace("server starting", "");
}

fn trace(phase: []const u8, name: []const u8) !void {
    if (picker_trace) |*writer| {
        try writer.interface.print("{s}\t{s}\n", .{ phase, name });
        try writer.interface.flush();
    }
}

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();
    const allocator = std.heap.page_allocator;
    const args = init.args.toSlice(allocator) catch |err| std.debug.panic("unable to parse command line args: {t}", .{err});
    var listen = false;
    var dir_path = test_id_record.dirFromEnviron(init.environ);
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--listen=-")) {
            listen = true;
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed command line argument");
        } else if (std.mem.startsWith(u8, arg, test_id_record.dir_arg)) {
            dir_path = arg[test_id_record.dir_arg.len..];
        } else if (!std.mem.startsWith(u8, arg, "--cache-dir=")) {
            std.debug.panic("unrecognized command line argument: {s}", .{arg});
        }
    }
    if (listen) openPickerTrace(init.environ, args[0]) catch |err|
        std.debug.panic("cannot open picker trace: {t}", .{err});
    if (dir_path) |path| {
        test_id_record.open(&test_ids, &test_ids_buffer, runner_io, init.environ, path, args[0], "");
        recording = true;
    }

    if (listen) {
        mainServer(init) catch |err| std.debug.panic("internal test runner failure: {t}", .{err});
    } else {
        mainTerminal(init);
    }
}

const Outcome = struct {
    status: std.zig.Server.Message.TestResults.Status,
    leak_count: usize,
};

fn runTest(init: std.process.Init.Minimal, test_fn: std.builtin.TestFn) Outcome {
    testing.environ = init.environ;
    testing.allocator_instance = .{};
    testing.io_instance = .init(testing.allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    log_err_count = 0;
    const status: std.zig.Server.Message.TestResults.Status = if (test_fn.func()) |_| .pass else |err| switch (err) {
        error.SkipZigTest => .skip,
        else => s: {
            if (@errorReturnTrace()) |stack_trace| std.debug.dumpErrorReturnTrace(stack_trace);
            break :s .fail;
        },
    };
    testing.io_instance.deinit();
    const leak_count = testing.allocator_instance.detectLeaks();
    testing.allocator_instance.deinitWithoutLeakChecks();
    if (recording) test_ids.write(switch (status) {
        .pass => .pass,
        .skip => .skip,
        .fail => .fail,
    }, test_fn.name);
    return .{ .status = status, .leak_count = leak_count };
}

fn mainServer(init: std.process.Init.Minimal) !void {
    @disableInstrumentation();
    stdin_reader = .initStreaming(.stdin(), runner_io, &stdin_buffer);
    stdout_writer = .initStreaming(.stdout(), runner_io, &stdout_buffer);
    var server = try std.zig.Server.init(.{
        .in = &stdin_reader.interface,
        .out = &stdout_writer.interface,
        .zig_version = builtin.zig_version_string,
    });

    while (true) {
        try trace("waiting for command", "");
        const hdr = try server.receiveMessage();
        switch (hdr.tag) {
            .exit => {
                try trace("exit requested", "");
                if (recording) test_ids.close(runner_io);
                try trace("exiting", "");
                if (picker_trace) |writer| writer.file.close(runner_io);
                return std.process.exit(0);
            },
            .query_test_metadata => {
                try trace("sending metadata", "");
                const allocator = std.heap.page_allocator;
                const test_fns = builtin.test_functions;
                var string_bytes: std.ArrayList(u8) = .empty;
                defer string_bytes.deinit(allocator);
                try string_bytes.append(allocator, 0);
                const names = try allocator.alloc(u32, test_fns.len);
                defer allocator.free(names);
                const expected_panic_msgs = try allocator.alloc(u32, test_fns.len);
                defer allocator.free(expected_panic_msgs);
                for (test_fns, names, expected_panic_msgs) |test_fn, *name, *expected_panic_msg| {
                    name.* = @intCast(string_bytes.items.len);
                    try string_bytes.appendSlice(allocator, test_fn.name);
                    try string_bytes.append(allocator, 0);
                    expected_panic_msg.* = 0;
                }
                try server.serveTestMetadata(.{
                    .names = names,
                    .expected_panic_msgs = expected_panic_msgs,
                    .string_bytes = string_bytes.items,
                });
            },
            .run_test => {
                try trace("reading test index", "");
                const index = try server.receiveBody_u32();
                const test_fn = builtin.test_functions[index];
                try trace("sending test_started", test_fn.name);
                try server.serveStringMessage(.test_started, &.{});
                try trace("started", test_fn.name);
                const outcome = runTest(init, test_fn);
                try trace(@tagName(outcome.status), test_fn.name);
                const Flags = std.zig.Server.Message.TestResults.Flags;
                try server.serveTestResults(.{
                    .index = index,
                    .flags = .{
                        .status = outcome.status,
                        .fuzz = false,
                        .log_err_count = std.math.lossyCast(@FieldType(Flags, "log_err_count"), log_err_count),
                        .leak_count = std.math.lossyCast(@FieldType(Flags, "leak_count"), outcome.leak_count),
                    },
                });
            },
            else => {
                std.debug.print("unsupported message: {x}\n", .{@intFromEnum(hdr.tag)});
                std.process.exit(1);
            },
        }
    }
}

fn mainTerminal(init: std.process.Init.Minimal) void {
    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaked: usize = 0;
    var logged_errors: usize = 0;
    for (builtin.test_functions) |test_fn| {
        testing.log_level = .warn;
        const outcome = runTest(init, test_fn);
        logged_errors += log_err_count;
        if (outcome.leak_count != 0) leaked += 1;
        switch (outcome.status) {
            .pass => passed += 1,
            .skip => skipped += 1,
            .fail => {
                failed += 1;
                std.debug.print("FAIL {s}\n", .{test_fn.name});
            },
        }
    }
    if (recording) test_ids.close(runner_io);
    std.debug.print("{d} passed; {d} skipped; {d} failed; {d} leaked; {d} errors logged.\n", .{ passed, skipped, failed, leaked, logged_errors });
    if (failed != 0 or leaked != 0 or logged_errors != 0) std.process.exit(1);
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}
