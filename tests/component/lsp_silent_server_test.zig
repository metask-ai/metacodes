const std = @import("std");
const builtin = @import("builtin");
const cc = @import("cc");
const pfs = @import("platform").fs;
const ppaths = @import("platform").paths;

const tools = cc.tools;
const ToolContext = cc.tool_context.ToolContext;
const Service = cc.lsp.service.Service;

const MOCK_LSP = "tests/_harness/mock_lsp_server.py";
const WINDOW_MS: u64 = 2_000;
const FAST_MS: i64 = 1_000;

fn dispatchOk(ctx: *const ToolContext, name: []const u8, args: []const u8) ![]u8 {
    var outcome = try tools.dispatch(ctx, name, args);
    return switch (outcome) {
        .ok => |*body| (try body.takeModelBytes(ctx.allocator)).bytes,
        else => {
            outcome.deinit(ctx.allocator);
            return error.UnexpectedDispatchOutcome;
        },
    };
}

fn zPath(buf: []u8, path: []const u8) ![:0]const u8 {
    return std.fmt.bufPrintZ(buf, "{s}", .{path});
}

fn writeAt(path: []const u8, content: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const fd = pfs.open((try zPath(&buf, path)).ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o755));
    if (fd < 0) return error.CreateFailed;
    defer pfs.close(fd);
    _ = pfs.write(fd, content);
}

fn mkdirAt(path: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = pfs.mkdir((try zPath(&buf, path)).ptr, 0o755);
}

const EnvGuard = struct {
    allocator: std.mem.Allocator,
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(allocator: std.mem.Allocator, name: [*:0]const u8, value: [*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try allocator.dupeZ(u8, std.mem.span(raw)) else null;
        ppaths.setEnv(name, value);
        return .{ .allocator = allocator, .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            self.allocator.free(previous);
        } else {
            ppaths.unsetEnv(self.name);
        }
        self.* = undefined;
    }
};

const GoRepo = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    file: []const u8,
    path_guard: EnvGuard,
    svc: *Service,

    fn setup(self: *GoRepo, mock_flags: []const u8) !void {
        const gpa = std.testing.allocator;
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();

        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root_len = try self.tmp.dir.realPath(std.testing.io, &root_buf);
        self.root = try arena.dupe(u8, root_buf[0..root_len]);

        var mock_buf: [std.fs.max_path_bytes]u8 = undefined;
        var mock_z_buf: [std.fs.max_path_bytes]u8 = undefined;
        const mock_abs = pfs.realpath((try zPath(&mock_z_buf, MOCK_LSP)).ptr, &mock_buf) orelse return error.MockLspMissing;

        const bin = try std.fmt.allocPrint(arena, "{s}/bin", .{self.root});
        try mkdirAt(bin);
        const wrapper = try std.fmt.allocPrint(arena, "{s}/gopls", .{bin});
        const script = try std.fmt.allocPrint(arena, "#!/bin/sh\nexec \"{s}\" {s} \"$@\"\n", .{ std.mem.span(mock_abs), mock_flags });
        try writeAt(wrapper, script);
        var wrapper_z: [std.fs.max_path_bytes]u8 = undefined;
        _ = pfs.chmod((try zPath(&wrapper_z, wrapper)).ptr, 0o755);

        try mkdirAt(try std.fmt.allocPrint(arena, "{s}/.git", .{self.root}));
        try writeAt(try std.fmt.allocPrint(arena, "{s}/go.mod", .{self.root}), "module demo\n\ngo 1.22\n");
        self.file = try std.fmt.allocPrint(arena, "{s}/main.go", .{self.root});
        try writeAt(self.file, "package main\n\nfunc main() {}\n");

        const old_path = if (std.c.getenv("PATH")) |p| std.mem.span(p) else "/usr/bin:/bin";
        const new_path = try std.fmt.allocPrintSentinel(arena, "{s}:{s}", .{ bin, old_path }, 0);
        self.path_guard = try EnvGuard.set(gpa, "PATH", new_path.ptr);
        errdefer self.path_guard.restore();

        self.svc = try Service.create(gpa, self.root, null);
        self.svc.waits = .{ .baseline_ms = WINDOW_MS, .after_write_ms = WINDOW_MS };
    }

    fn ctx(self: *const GoRepo) ToolContext {
        var c = ToolContext.simple(std.testing.allocator);
        c.lsp = self.svc;
        c.cwd_abs = self.root;
        return c;
    }

    fn edit(self: *const GoRepo, old: []const u8, new: []const u8) !Timed {
        const c = self.ctx();
        var args: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer args.deinit();
        try args.writer.print("{{\"file_path\":\"{s}\",\"old_string\":\"{s}\",\"new_string\":\"{s}\"}}", .{ self.file, old, new });
        return timed(&c, "Edit", args.written());
    }

    fn write(self: *const GoRepo, content: []const u8) !Timed {
        const c = self.ctx();
        var args: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer args.deinit();
        try args.writer.print("{{\"file_path\":\"{s}\",\"content\":\"{s}\"}}", .{ self.file, content });
        return timed(&c, "Write", args.written());
    }

    fn deinit(self: *GoRepo) void {
        self.svc.shutdown();
        self.path_guard.restore();
        self.arena.deinit();
        self.tmp.cleanup();
    }
};

const Timed = struct {
    result: []u8,
    elapsed_ms: i64,

    fn deinit(self: Timed) void {
        std.testing.allocator.free(self.result);
    }

    fn hasDiagnostics(self: Timed) bool {
        return std.mem.indexOf(u8, self.result, "\"lspDiagnostics\"") != null;
    }
};

fn timed(c: *const ToolContext, name: []const u8, args: []const u8) !Timed {
    const start = cc.util_time.nowMs();
    const result = try dispatchOk(c, name, args);
    return .{ .result = result, .elapsed_ms = cc.util_time.nowMs() - start };
}

fn waitUntilNoSilentPath(svc: *Service) !void {
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        var silent = false;
        _ = svc.mutex.lock();
        var it = svc.clients.valueIterator();
        while (it.next()) |entry| {
            const cl = entry.client;
            _ = cl.mutex.lock();
            if (cl.server_silent or cl.silent_paths.count() > 0) silent = true;
            _ = cl.mutex.unlock();
        }
        _ = svc.mutex.unlock();
        if (!silent) return;
        cc.util_time.sleepMs(20);
    }
    return error.PathStayedSilent;
}

fn expectFast(t: Timed, label: []const u8) !void {
    if (t.elapsed_ms >= FAST_MS) {
        std.debug.print("{s} took {d} ms with a {d} ms diagnostics window\n", .{ label, t.elapsed_ms, WINDOW_MS });
        return error.WaitedOnSilentServer;
    }
}

test "L2 #669: a server that never publishes costs one bounded wait, later Edit and Write calls do not wait" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var repo: GoRepo = undefined;
    try repo.setup("--silent");
    defer repo.deinit();

    const first = try repo.edit("func main() {}", "func main() { _ = 1 }");
    defer first.deinit();
    try std.testing.expect(std.mem.indexOf(u8, first.result, "\"success\":true") != null);
    try std.testing.expect(!first.hasDiagnostics());
    try std.testing.expect(first.elapsed_ms < 2 * @as(i64, @intCast(WINDOW_MS)));

    const second = try repo.edit("_ = 1", "_ = 2");
    defer second.deinit();
    try std.testing.expect(std.mem.indexOf(u8, second.result, "\"success\":true") != null);
    try expectFast(second, "second Edit");

    const third = try repo.edit("_ = 2", "_ = 3");
    defer third.deinit();
    try expectFast(third, "third Edit");

    const rewrite = try repo.write("package main\\n\\nfunc main() {}\\n");
    defer rewrite.deinit();
    try std.testing.expect(std.mem.indexOf(u8, rewrite.result, "\"success\":true") != null);
    try expectFast(rewrite, "Write");
}

test "L2 #669: a publishing server still gets new diagnostics attached to every Edit and Write" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var repo: GoRepo = undefined;
    try repo.setup("--content");
    defer repo.deinit();

    const first = try repo.edit("func main() {}", "func main() {}\\nvar a = MOCK_BAD");
    defer first.deinit();
    try std.testing.expect(first.hasDiagnostics());
    try std.testing.expect(std.mem.indexOf(u8, first.result, "MOCK_LSP_DIAG at line 4") != null);

    const second = try repo.edit("var a = MOCK_BAD", "var a = MOCK_BAD\\nvar b = MOCK_BAD");
    defer second.deinit();
    try std.testing.expect(second.hasDiagnostics());
    try std.testing.expect(std.mem.indexOf(u8, second.result, "MOCK_LSP_DIAG at line 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.result, "MOCK_LSP_DIAG at line 4") == null);

    const rewrite = try repo.write("package main\\n\\nvar c = MOCK_BAD\\n");
    defer rewrite.deinit();
    try std.testing.expect(rewrite.hasDiagnostics());
    try std.testing.expect(std.mem.indexOf(u8, rewrite.result, "MOCK_LSP_DIAG at line 3") != null);
}

test "L2 #669: a path silenced by one missed window waits again once the server publishes for it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var repo: GoRepo = undefined;
    try repo.setup("--content --skip-first");
    defer repo.deinit();

    const first = try repo.edit("func main() {}", "func main() {}\\nvar a = MOCK_BAD");
    defer first.deinit();
    try std.testing.expect(std.mem.indexOf(u8, first.result, "\"success\":true") != null);
    try waitUntilNoSilentPath(repo.svc);

    const second = try repo.edit("var a = MOCK_BAD", "var a = MOCK_BAD\\nvar b = MOCK_BAD");
    defer second.deinit();
    try std.testing.expect(second.hasDiagnostics());
    try std.testing.expect(std.mem.indexOf(u8, second.result, "MOCK_LSP_DIAG at line 5") != null);
}
