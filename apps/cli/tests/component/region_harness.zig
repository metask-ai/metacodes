//! Drives a real RenderRegion against the component-test virtual terminal
//! (vterm.zig, #319). The region's frames go to `RenderRegion.sink`; `sync`
//! replays the bytes written since the last call into the screen, so a test
//! asserts what a person would see after each public call, never the
//! region's internal fields.

const std = @import("std");
const cc = @import("cc");
const ppaths = @import("platform").paths;
pub const vterm = @import("vterm.zig");

pub const RenderRegion = cc.tui_render_region.RenderRegion;
pub const App = cc.app_module.App;

const EnvGuard = struct {
    gpa: std.mem.Allocator,
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(gpa: std.mem.Allocator, name: [*:0]const u8, value: [*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try gpa.dupeZ(u8, std.mem.span(raw)) else null;
        ppaths.setEnv(name, value);
        return .{ .gpa = gpa, .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            self.gpa.free(previous);
        } else {
            ppaths.unsetEnv(self.name);
        }
        self.* = undefined;
    }
};

/// A real App (the generation-phase region draws its spinner, footer and
/// border colour from it) in a throwaway HOME, with probes and the KG
/// daemon off. Heap-pinned: the App keeps pointers into the I/O runtime.
pub const AppFixture = struct {
    gpa: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    guards: [3]EnvGuard,
    app: *App,

    pub fn create(gpa: std.mem.Allocator) !*AppFixture {
        const self = try gpa.create(AppFixture);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();

        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try self.tmp.dir.realPath(std.testing.io, &root_buffer);
        const home_z = try arena.dupeZ(u8, root_buffer[0..len]);
        self.guards[0] = try EnvGuard.set(gpa, "HOME", home_z.ptr);
        errdefer self.guards[0].restore();
        self.guards[1] = try EnvGuard.set(gpa, "METACODES_NO_PROBE", "1");
        errdefer self.guards[1].restore();
        self.guards[2] = try EnvGuard.set(gpa, "METACODES_KG_AUTOSTART", "0");
        errdefer self.guards[2].restore();

        const argv = [_][*:0]const u8{ "metacodes", "--permission", "bypassPermissions" };
        const config = cc.parseArgsForTest(&argv, arena);
        if (config.parse_error != null) return error.TestUnexpectedResult;
        self.io_rt = @import("platform").signal.threadedIo(arena, .{});
        errdefer self.io_rt.deinit();
        self.app = try App.init(arena, self.io_rt.io(), config, "test-key");
        // Colour on, so SGR runs reach the screen and take part in comparisons.
        self.app.theme = cc.tui_theme.select(.dark, .basic_16);
        return self;
    }

    pub fn destroy(self: *AppFixture) void {
        self.app.deinit();
        self.io_rt.deinit();
        var i = self.guards.len;
        while (i > 0) {
            i -= 1;
            self.guards[i].restore();
        }
        self.arena.deinit();
        self.tmp.cleanup();
        self.gpa.destroy(self);
    }
};

/// The prompt row of the input box: one per drawn region.
pub fn isPromptRow(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "❯") != null;
}

/// The input box's border: a row of nothing but `─`. Table frames use `─`
/// too, but always with corners and junctions.
pub fn isRuleRow(text: []const u8) bool {
    const rule = "─";
    if (text.len < rule.len * 8 or text.len % rule.len != 0) return false;
    var i: usize = 0;
    while (i < text.len) : (i += rule.len) {
        if (!std.mem.eql(u8, text[i .. i + rule.len], rule)) return false;
    }
    return true;
}

/// A row the live region draws (prompt or border).
pub fn isRegionRow(text: []const u8) bool {
    return isPromptRow(text) or isRuleRow(text);
}

/// The clock of every `Term` that runs with the merge window on. Only
/// `Term.sync` moves it, and only to the deadline of a frame that waits: a
/// frame is painted at the clock's time, so the next request after it always
/// falls inside the window.
pub const MergeClock = struct {
    var now: i64 = 1_000_000;
    pub fn read() i64 {
        return now;
    }
};

/// A RenderRegion wired to a virtual terminal of the given size.
/// Heap-pinned: the region's sink points into it.
pub const Term = struct {
    gpa: std.mem.Allocator,
    out: std.Io.Writer.Allocating,
    region: RenderRegion,
    screen: vterm.Screen,
    fed: usize = 0,
    merging: bool = false,

    pub const Options = struct {
        rows: usize = 24,
        cols: usize = 80,
        autowrap: bool = false,
        /// Run the generating region with the merge window on (#328), on
        /// `MergeClock` and without the timer thread. Every request after a
        /// painted frame waits for the window (only a phase's first frame and
        /// the immediate channel paint at once), and `sync` paints it, as the
        /// timer would at the window's end: what a test sees after a sync is
        /// the merged frame, not each request's own.
        merge_window: bool = false,
        /// The region's own allocator (its frame buffer, pending text);
        /// `gpa` when null. The screen and the byte sink always use `gpa`.
        region_gpa: ?std.mem.Allocator = null,
    };

    pub fn create(gpa: std.mem.Allocator, opts: Options) !*Term {
        const self = try gpa.create(Term);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .out = .init(gpa),
            // fd -1 has no size: the region keeps the geometry set below and
            // never sees a resize.
            .region = RenderRegion.init(opts.region_gpa orelse gpa, -1, cc.tui_theme.select(.dark, .basic_16), .basic_16),
            .screen = undefined,
        };
        errdefer {
            self.region.deinit();
            self.out.deinit();
        }
        self.screen = try vterm.Screen.init(gpa, opts.rows, opts.cols, .{ .autowrap = opts.autowrap });
        self.region.rows = @intCast(opts.rows);
        self.region.cols = @intCast(opts.cols);
        self.region.sink = &self.out.writer;
        if (opts.merge_window) {
            self.region.merge = .{ .now_ms = MergeClock.read, .timer = false };
            self.merging = true;
        }
        return self;
    }

    pub fn destroy(self: *Term) void {
        self.region.deinit();
        self.out.deinit();
        self.screen.deinit();
        self.gpa.destroy(self);
    }

    /// Replay what the region wrote since the last sync, through the tty's
    /// output processing: the REPL's raw mode keeps OPOST|ONLCR (and the
    /// Windows console auto-returns on LF), so every LF reaches the terminal
    /// as CR LF. With the merge window on, a frame waiting for the window is
    /// painted first, at the window's end.
    pub fn sync(self: *Term) !void {
        if (self.merging) {
            if (self.region.merge) |m| if (m.sched.deadline()) |due| {
                MergeClock.now = @max(MergeClock.now, due);
            };
            _ = self.region.pumpFrame();
        }
        const bytes = self.out.written();
        var rest = bytes[self.fed..];
        self.fed = bytes.len;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            try self.screen.feed(rest[0..nl]);
            try self.screen.feed("\r\n");
            rest = rest[nl + 1 ..];
        }
        try self.screen.feed(rest);
    }

    /// Resize the terminal, as a SIGWINCH would: the screen reflows (or clips)
    /// what it shows now, and the region sees the new size the next time it
    /// measures (`RenderRegion.size_override`).
    pub fn resize(self: *Term, rows: usize, cols: usize, reflow: bool) !void {
        try self.sync();
        try self.screen.resize(rows, cols, reflow);
        self.region.reflows = reflow;
        self.region.size_override = .{ .rows = @intCast(rows), .cols = @intCast(cols) };
    }

    /// Every byte the region has written so far.
    pub fn written(self: *Term) []const u8 {
        return self.out.written();
    }

    /// History and screen, top to bottom, blank rows at the bottom dropped.
    pub fn transcriptAlloc(self: *Term, opts: vterm.Screen.TranscriptOptions) ![]u8 {
        try self.sync();
        return self.screen.transcriptAlloc(self.gpa, opts);
    }

    pub fn printDump(self: *Term) void {
        const dump = self.screen.dumpAlloc(self.gpa) catch return;
        defer self.gpa.free(dump);
        std.debug.print("{s}", .{dump});
    }
};
