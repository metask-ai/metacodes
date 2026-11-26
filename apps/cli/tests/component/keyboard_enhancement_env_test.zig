const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");
const cc = @import("cc");

const pfs = platform.fs;
const ppaths = platform.paths;
const testing = std.testing;
const input = cc.repl_input;

extern "c" fn posix_openpt(oflag: std.c.O) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;

const Pty = struct {
    master: c_int,
    slave: c_int,
    mutex: platform.sync.Mutex = .{},
    received: std.ArrayList(u8) = .empty,
    taken: usize = 0,
    done: std.atomic.Value(bool) = .init(false),
    reader: ?std.Thread = null,

    fn open() !*Pty {
        const master = posix_openpt(.{ .ACCMODE = .RDWR, .NOCTTY = true });
        if (master < 0) return error.SkipZigTest;
        errdefer _ = std.c.close(master);
        if (grantpt(master) != 0 or unlockpt(master) != 0) return error.SkipZigTest;
        const name = ptsname(master) orelse return error.SkipZigTest;
        const slave = pfs.openZ(std.mem.span(name), .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0) catch return error.SkipZigTest;
        errdefer _ = std.c.close(slave);
        const pty = try testing.allocator.create(Pty);
        errdefer testing.allocator.destroy(pty);
        pty.* = .{ .master = master, .slave = slave };
        pty.reader = try platform.thread.spawn(.waiter, readMaster, .{pty});
        return pty;
    }

    fn close(self: *Pty) void {
        self.done.store(true, .release);
        if (self.reader) |reader| reader.join();
        _ = std.c.close(self.slave);
        _ = std.c.close(self.master);
        self.received.deinit(testing.allocator);
        testing.allocator.destroy(self);
    }

    fn readMaster(self: *Pty) void {
        while (!self.done.load(.acquire)) {
            var fds = [_]std.c.pollfd{.{ .fd = self.master, .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&fds, 1, 20) <= 0) continue;
            var buf: [512]u8 = undefined;
            const n = std.c.read(self.master, &buf, buf.len);
            if (n <= 0) {
                platform.sync.sleepMs(5);
                continue;
            }
            self.mutex.lock();
            defer self.mutex.unlock();
            self.received.appendSlice(testing.allocator, buf[0..@intCast(n)]) catch {};
        }
    }

    fn receivedLen(self: *Pty) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.received.items.len;
    }

    fn take(self: *Pty) ![]u8 {
        var last = self.receivedLen();
        var quiet_ms: u64 = 0;
        var waited_ms: u64 = 0;
        while (quiet_ms < 100 and waited_ms < 3000) : (waited_ms += 10) {
            platform.sync.sleepMs(10);
            const now = self.receivedLen();
            if (now == last) quiet_ms += 10 else {
                quiet_ms = 0;
                last = now;
            }
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        const fresh = try testing.allocator.dupe(u8, self.received.items[self.taken..]);
        self.taken = self.received.items.len;
        return fresh;
    }
};

const EnvVar = struct {
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(name: [*:0]const u8, value: ?[*:0]const u8) !EnvVar {
        const previous = if (std.c.getenv(name)) |raw| try testing.allocator.dupeZ(u8, std.mem.span(raw)) else null;
        if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
        return .{ .name = name, .previous = previous };
    }

    fn restore(self: EnvVar) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            testing.allocator.free(previous);
        } else {
            ppaths.unsetEnv(self.name);
        }
    }
};

const protocol_sequences = [_][]const u8{ "\x1b[<u", "\x1b[>1u", "\x1b[>4;2m", "\x1b[>4m" };

const Phase = enum { take, resume_after_stop, lend, take_back, give_back };

const Seen = std.EnumArray(Phase, []const u8);

fn runPhases(pty: *Pty) !Seen {
    var seen: Seen = .initFill("");
    errdefer for (seen.values) |bytes| testing.allocator.free(bytes);
    const saved = input.enterRawMode(pty.slave) orelse return error.SkipZigTest;
    seen.set(.take, try pty.take());
    input.installResumeHandler();
    try std.posix.raise(.CONT);
    try testing.expect(input.reconcileAfterResume(pty.slave));
    seen.set(.resume_after_stop, try pty.take());
    const lent = input.lendTerminal(pty.slave) orelse return error.TerminalNotLent;
    seen.set(.lend, try pty.take());
    input.takeBackTerminal(pty.slave, lent);
    seen.set(.take_back, try pty.take());
    input.restoreMode(pty.slave, saved);
    seen.set(.give_back, try pty.take());
    return seen;
}

fn freeSeen(seen: *Seen) void {
    for (seen.values) |bytes| testing.allocator.free(bytes);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "METACODES_NO_KEYBOARD_ENHANCEMENT keeps every keyboard protocol sequence off the terminal: taken, stopped and continued, lent and given back" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const pty = try Pty.open();
    defer pty.close();
    const term = try EnvVar.set("TERM", "xterm-kitty");
    defer term.restore();

    {
        const opt_out = try EnvVar.set(input.no_keyboard_enhancement_env, null);
        defer opt_out.restore();
        try testing.expect(input.shouldEnableKittyKeyboard());
        var seen = try runPhases(pty);
        defer freeSeen(&seen);
        for ([_]Phase{ .take, .resume_after_stop, .take_back }) |phase| {
            errdefer std.debug.print("protocol on, {t}: {f}\n", .{ phase, std.ascii.hexEscape(seen.get(phase), .upper) });
            try testing.expect(contains(seen.get(phase), input.kbd_enable_seq));
            try testing.expect(contains(seen.get(phase), "\x1b[?2004h"));
        }
        for ([_]Phase{ .lend, .give_back }) |phase| {
            errdefer std.debug.print("protocol on, {t}: {f}\n", .{ phase, std.ascii.hexEscape(seen.get(phase), .upper) });
            try testing.expect(contains(seen.get(phase), input.kbd_disable_seq));
            try testing.expect(contains(seen.get(phase), "\x1b[?2004l"));
        }
    }

    for ([_][*:0]const u8{ "1", "0", "" }) |value| {
        const opt_out = try EnvVar.set(input.no_keyboard_enhancement_env, value);
        defer opt_out.restore();
        try testing.expect(!input.shouldEnableKittyKeyboard());
        var seen = try runPhases(pty);
        defer freeSeen(&seen);
        for (std.enums.values(Phase)) |phase| {
            errdefer std.debug.print("{s}={s}, {t}: {f}\n", .{ input.no_keyboard_enhancement_env, value, phase, std.ascii.hexEscape(seen.get(phase), .upper) });
            for (protocol_sequences) |sequence| try testing.expect(!contains(seen.get(phase), sequence));
            const paste_mode = switch (phase) {
                .take, .resume_after_stop, .take_back => "\x1b[?2004h",
                .lend, .give_back => "\x1b[?2004l",
            };
            try testing.expect(contains(seen.get(phase), paste_mode));
        }
    }
}
