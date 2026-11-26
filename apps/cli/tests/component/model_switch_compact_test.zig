const std = @import("std");
const cc = @import("cc");
const ppaths = @import("platform").paths;

const WIDE = "compact-wide-model";
const MIDDLE = "compact-middle-model";
const NARROW = "compact-narrow-model";

const MODELS =
    \\{"data":[
    \\{"id":"compact-wide-model","max_tokens":8192,"max_input_tokens":400000},
    \\{"id":"compact-middle-model","max_tokens":8192,"max_input_tokens":300000},
    \\{"id":"compact-narrow-model","max_tokens":8192,"max_input_tokens":100000}
    \\]}
;

const EnvGuard = struct {
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(name: [*:0]const u8, value: [*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try std.testing.allocator.dupeZ(u8, std.mem.span(raw)) else null;
        ppaths.setEnv(name, value);
        return .{ .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            std.testing.allocator.free(previous);
        } else ppaths.unsetEnv(self.name);
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    guards: [4]EnvGuard,
    app: *cc.app_module.App,

    fn setup(self: *Fixture) !void {
        const a = std.testing.allocator;
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try self.tmp.dir.realPath(std.testing.io, &root_buffer);
        self.arena = std.heap.ArenaAllocator.init(a);
        errdefer self.arena.deinit();
        const allocator = self.arena.allocator();
        try self.tmp.dir.createDirPath(std.testing.io, "home");
        const home = try std.fs.path.join(allocator, &.{ root_buffer[0..len], "home" });

        self.guards = .{
            try EnvGuard.set("HOME", (try allocator.dupeZ(u8, home)).ptr),
            try EnvGuard.set("CODEX_HOME", (try std.fs.path.joinZ(allocator, &.{ home, ".codex" })).ptr),
            try EnvGuard.set("METACODES_NO_PROBE", "1"),
            try EnvGuard.set("METACODES_KG_AUTOSTART", "0"),
        };
        errdefer for (&self.guards) |*guard| guard.restore();

        const argv = [_][*:0]const u8{
            "metacodes",         "--base-url", "http://127.0.0.1:1/v1/messages",
            "--model",           WIDE,         "--permission",
            "bypassPermissions",
        };
        const config = cc.parseArgsForTest(&argv, allocator);
        try std.testing.expect(config.parse_error == null);
        self.io_rt = @import("platform").signal.threadedIo(allocator, .{});
        errdefer self.io_rt.deinit();
        self.app = try cc.app_module.App.init(allocator, self.io_rt.io(), config, "test-key");
        errdefer self.app.deinit();
        try self.app.api_client.catalog.loadFromModelsListJson(MODELS);
    }

    fn deinit(self: *Fixture) void {
        self.app.deinit();
        self.io_rt.deinit();
        var i = self.guards.len;
        while (i > 0) {
            i -= 1;
            self.guards[i].restore();
        }
        self.arena.deinit();
        self.tmp.cleanup();
    }
};

fn expectQueued(app: *cc.app_module.App, previous_model: []const u8, previous_window: u32, current_window: u32) !void {
    const queued = app.pendingModelSwitchCompact() orelse return error.NoCompactionQueued;
    try std.testing.expectEqualStrings(previous_model, queued.previous_model);
    try std.testing.expectEqual(previous_window, queued.previous_context_window);
    try std.testing.expectEqual(current_window, queued.current_context_window);
}

test "model switch compaction: picking the narrower model again before the next turn keeps what its switch queued" {
    var fx: Fixture = undefined;
    try fx.setup();
    defer fx.deinit();

    try fx.app.switchModel(NARROW);
    try expectQueued(fx.app, WIDE, 400_000, 100_000);
    try fx.app.switchModel(NARROW);
    try expectQueued(fx.app, WIDE, 400_000, 100_000);
}

test "model switch compaction: switches before the next turn are measured against the model the conversation was last sized for" {
    var fx: Fixture = undefined;
    try fx.setup();
    defer fx.deinit();

    try fx.app.switchModel(NARROW);
    try fx.app.switchModel(MIDDLE);
    try expectQueued(fx.app, WIDE, 400_000, 300_000);
    try fx.app.switchModel(WIDE);
    try std.testing.expect(fx.app.pendingModelSwitchCompact() == null);
}

test "model switch compaction: a switch to a wider model queues nothing, and the next switch starts from there" {
    var fx: Fixture = undefined;
    try fx.setup();
    defer fx.deinit();

    try fx.app.switchModel(NARROW);
    fx.app.clearPendingModelSwitchCompact();
    try fx.app.switchModel(WIDE);
    try std.testing.expect(fx.app.pendingModelSwitchCompact() == null);
    try fx.app.switchModel(NARROW);
    try expectQueued(fx.app, WIDE, 400_000, 100_000);
}
