//! update_unit_probe —— the executable of a fixture release unit for the
//! `metacodes update` component tests (`zig-out/bin/update_unit_probe`).
//!
//! The tests copy it to `<unit>/bin/metacodes[.exe]` of a fixture release and
//! let `update` run it the way it runs a real unit:
//!   - `install --help` prints the option names of the installer contract
//!     (doc/UPDATE_DESIGN.md §4), or `METACODES_UPDATE_PROBE_HELP` instead;
//!   - `--help` names the `update` command;
//!   - `install …` runs the real installer (apps/cli/src/app/install.zig) from the unit
//!     around this executable, without the `doctor --strict` self check, unless
//!     `METACODES_UPDATE_PROBE_EXIT` asks for a failure exit first;
//!   - `sleep <ms>` stands for a session: it runs from the prefix and waits;
//!   - `kgd` stands for this install's TinyKG service: it starts the prefix's
//!     `vendor/tinykg/tinykgd wait-stdin` on a pipe and waits, and
//!     `wait-stdin` exits when its stdin closes, as tinykgd does when its
//!     supervisor goes away;
//!   - anything else (`kg install`, …) exits 0.
//! Every invocation is appended to `METACODES_UPDATE_PROBE_LOG` as one line:
//! the arguments after argv[0], tab-separated.
const std = @import("std");
const platform = @import("platform");
const root = @import("install_root");
const install = root.install;

const contract_help =
    \\usage: metacodes install --prefix <dir> [--state-dir <dir>] [--sdk <agentcore-bundle-dir>]
    \\                         [--upgrade] [--allow-downgrade] [--force]
    \\                         [--release-base <url> | --checkout <dir>]
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    var args_it = try std.process.Args.iterateAllocator(init.minimal.args, arena);
    defer args_it.deinit();
    _ = args_it.next();
    var args: std.ArrayList([]const u8) = .empty;
    while (args_it.next()) |arg| try args.append(arena, try arena.dupe(u8, arg));

    if (init.environ_map.get("METACODES_UPDATE_PROBE_LOG")) |log_path| {
        var line: std.ArrayList(u8) = .empty;
        for (args.items, 0..) |arg, i| {
            if (i > 0) try line.append(arena, '\t');
            try line.appendSlice(arena, arg);
        }
        try line.append(arena, '\n');
        // Opened with read access as well: on Windows `stat` needs it (a
        // write-only handle has no FILE_READ_ATTRIBUTES, and the query is
        // refused with AccessDenied).
        var file = try std.Io.Dir.cwd().createFile(init.io, log_path, .{ .read = true, .truncate = false });
        defer file.close(init.io);
        const end = (try file.stat(init.io)).size;
        try file.writePositionalAll(init.io, line.items, end);
    }

    const a = args.items;
    if (a.len == 2 and std.mem.eql(u8, a[0], "install") and std.mem.eql(u8, a[1], "--help")) {
        try writeStdout(init.io, init.environ_map.get("METACODES_UPDATE_PROBE_HELP") orelse contract_help);
        return 0;
    }
    if (a.len == 1 and std.mem.eql(u8, a[0], "--help")) {
        try writeStdout(init.io, "  update [--check] [--version X.Y.Z]\n");
        return 0;
    }
    if (a.len == 2 and std.mem.eql(u8, a[0], "sleep")) {
        try std.Io.sleep(init.io, .fromMilliseconds(try std.fmt.parseInt(i64, a[1], 10)), .awake);
        return 0;
    }
    if (a.len == 1 and std.mem.eql(u8, a[0], "wait-stdin")) {
        var buf: [256]u8 = undefined;
        var reader = std.Io.File.stdin().reader(init.io, &buf);
        _ = reader.interface.discardRemaining() catch {};
        return 0;
    }
    if (a.len == 1 and std.mem.eql(u8, a[0], "kgd")) {
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe = platform.paths.selfExeRealPath(&exe_buf) orelse return error.NoSelfPath;
        const prefix = root.state_root.prefixOf(exe) orelse return error.NotInAUnit;
        const daemon = try std.fs.path.join(arena, &.{ prefix, "vendor", "tinykg", if (@import("builtin").os.tag == .windows) "tinykgd.exe" else "tinykgd" });
        var child = try std.process.spawn(init.io, .{ .argv = &.{ daemon, "wait-stdin" }, .stdin = .pipe, .stdout = .ignore, .stderr = .ignore });
        _ = &child;
        try std.Io.sleep(init.io, .fromSeconds(120), .awake);
        return 0;
    }
    if (a.len == 0 or !std.mem.eql(u8, a[0], "install")) return 0;
    if (init.environ_map.get("METACODES_UPDATE_PROBE_EXIT")) |code| return std.fmt.parseInt(u8, code, 10) catch 1;

    var options: install.Options = .{ .prefix = "", .self_check = false };
    var i: usize = 1;
    while (i < a.len) : (i += 1) {
        const arg = a[i];
        if (std.mem.eql(u8, arg, "--upgrade")) {
            options.upgrade = true;
        } else if (std.mem.eql(u8, arg, "--allow-downgrade")) {
            options.allow_downgrade = true;
        } else if (i + 1 < a.len and std.mem.eql(u8, arg, "--prefix")) {
            i += 1;
            options.prefix = a[i];
        } else if (i + 1 < a.len and std.mem.eql(u8, arg, "--sdk")) {
            i += 1;
            options.sdk = a[i];
        } else if (i + 1 < a.len and std.mem.eql(u8, arg, "--release-base")) {
            i += 1;
            options.update_source = .{ .set = try root.release_source.parseBase(arena, a[i]) };
        } else if (i + 1 < a.len and std.mem.eql(u8, arg, "--checkout")) {
            i += 1;
            options.update_source = .{ .set = try root.release_source.parseCheckout(arena, a[i]) };
        } else {
            std.debug.print("update_unit_probe: unknown install argument {s}\n", .{arg});
            return 2;
        }
    }
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = platform.paths.selfExeRealPath(&exe_buf) orelse return error.NoSelfPath;
    const unit = root.state_root.prefixOf(exe) orelse return error.NotInAUnit;
    var log: std.Io.Writer.Allocating = .init(arena);
    _ = install.run(arena, init.io, unit, options, &log.writer) catch |err| {
        std.debug.print("{s}update_unit_probe: install failed: {s}\n", .{ log.written(), @errorName(err) });
        return 1;
    };
    return 0;
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}
