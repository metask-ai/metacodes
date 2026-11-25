//! Bench workbench bootstrap. The binary carries the exact Python/frontend
//! files it invokes, so installs do not discover a sibling checkout.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("metacodes-internal").platform;
const assets = @import("bench_assets");
const version = @import("metacodes-internal").version;

fn environmentValue(entries: []const [:0]const u8, key: []const u8) ?[]const u8 {
    for (entries) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.ascii.eqlIgnoreCase(entry[0..eq], key) and entry.len > eq + 1) return entry[eq + 1 ..];
    }
    return null;
}

fn pythonPath(arena: std.mem.Allocator) ![:0]const u8 {
    const env = try platform.paths.environment(arena);
    if (environmentValue(env, "METACODES_BENCH_PYTHON")) |explicit| return arena.dupeZ(u8, explicit);
    const path = environmentValue(env, "PATH") orelse return error.PythonNotFound;
    const names: []const []const u8 = if (builtin.os.tag == .windows) &.{ "python3.exe", "python.exe" } else &.{"python3"};
    var dirs = std.mem.splitScalar(u8, path, if (builtin.os.tag == .windows) ';' else ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        for (names) |name| {
            const candidate = try arena.dupeZ(u8, try std.fs.path.join(arena, &.{ dir, name }));
            if (platform.fs.exists(candidate)) return candidate;
        }
    }
    return error.PythonNotFound;
}

fn extract(arena: std.mem.Allocator, io: std.Io, state_root: []const u8) ![]const u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (assets.files) |file| {
        hash.update(file.path);
        hash.update(file.bytes);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest[0..8], .lower);
    const root = try std.fs.path.join(arena, &.{ state_root, "bench", "runtime", &hex });
    var nonce: [8]u8 = undefined;
    if (!platform.rng.randomBytes(&nonce)) return error.RandomUnavailable;
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    for (assets.files) |file| {
        const path = try std.fs.path.join(arena, &.{ root, file.path });
        // Never truncate a module a running worker may be importing.
        if (std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(file.bytes.len + 1))) |existing| {
            if (std.mem.eql(u8, existing, file.bytes)) continue;
        } else |_| {}
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
        const temporary = try std.fmt.allocPrintSentinel(arena, "{s}.{s}.tmp", .{ path, nonce_hex }, 0);
        const destination = try arena.dupeZ(u8, path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = file.bytes });
        if (platform.fs.renameReplace(temporary, destination) != 0) return error.RenameFailed;
    }
    return root;
}

pub fn run(args: *std.process.Args.Iterator, gpa: std.mem.Allocator, io: std.Io, state_root: []const u8) u8 {
    var storage = std.heap.ArenaAllocator.init(gpa);
    defer storage.deinit();
    const arena = storage.allocator();
    const python = pythonPath(arena) catch {
        std.debug.print("bench: Python 3.9+ is required; install python3 or set METACODES_BENCH_PYTHON\n", .{});
        return 1;
    };
    const root = extract(arena, io, state_root) catch |err| {
        std.debug.print("bench: cannot prepare workbench ({s})\n", .{@errorName(err)});
        return 1;
    };
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    const bootstrap = "import sys; sys.path.insert(0, sys.argv.pop(1)); from scripts.eval.harbor.cli import main; sys.exit(main())";
    for ([_][]const u8{ python, "-c", bootstrap, root, "--state-root", state_root, "--metacodes-version", version.semver }) |arg| {
        const z = arena.dupeZ(u8, arg) catch return 1;
        argv.append(arena, z.ptr) catch return 1;
    }
    // `bench setup` picks the Linux release matching this executable, and the
    // page's sign-in runs this executable's `login`.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (platform.paths.selfExeRealPath(&exe_buf)) |exe| {
        for ([_][]const u8{ "--metacodes-binary", exe }) |arg| {
            const z = arena.dupeZ(u8, arg) catch return 1;
            argv.append(arena, z.ptr) catch return 1;
        }
    }
    while (args.next()) |arg| {
        const z = arena.dupeZ(u8, arg) catch return 1;
        argv.append(arena, z.ptr) catch return 1;
    }
    argv.append(arena, null) catch return 1;
    const code = platform.process.runInherit(argv.items, true) catch |err| {
        std.debug.print("bench: cannot start Python ({s})\n", .{@errorName(err)});
        return 1;
    };
    return if (code >= 0 and code <= 255) @intCast(code) else 1;
}
