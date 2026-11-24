//! 启动期终端探测:一轮往返问清背景色(OSC 11)与 Kitty 键盘协议(`CSI ? u`),DA1 作哨兵(#327)。
//!
//! 机制:进 raw(保留已到的输入)→ 一次写出 `[OSC 11 ?][CSI ? u] CSI c` → 读应答直到 DA1
//! 回来或超时 → 还原 termios。每个终端都答 DA1(primary device attributes),而终端按顺序应答:
//! DA1 到了还没见到 Kitty 应答,就是确定的"不支持",不用等超时;OSC 11 同理。超时(~120ms)
//! 只是兜底——应答在路上太久(慢 SSH)或终端什么都不答,结果是"不知道",调用方沿用旧默认;
//! 迟到的应答由 `Late` 接着读掉(终端保持安静,不回显),直到 REPL 接管。
//! 查询发出前已经排在队列里的应答(上一个程序没读走的)不算这一轮的。
//! 背景色:`\x1b]11;rgb:RRRR/GGGG/BBBB\x07`(或 ST `\x1b\\` 结尾)→ 解析高字节 → BT.601 亮度判明暗。
//!
//! 同一批字节里不是应答的(探测期间敲的键、粘贴的文字)原样交还 stdin
//! (platform.terminal.replayInput):输入 parser 照常读到它们,应答本身不会被当成按键。
//!
//! 谨慎:① 只在交互 tty 启动期调一次;② 超时短不拖慢启动;③ 还原 termios;
//! ④ 管道/NO_PROBE/非 tty 由调用方跳过(本模块也自带非 tty 守卫)。
const std = @import("std");
const builtin = @import("builtin");
const platform_term = @import("metacodes-internal").platform.terminal;
const pfs = @import("metacodes-internal").platform.fs;
const util_time = @import("metacodes-internal").util.time;
const log = @import("metacodes-internal").util.log;

pub const Rgb = struct { r: u8, g: u8, b: u8 };

/// BT.601 相对亮度 > 128 → 浅色背景(对齐 metacode color.zig is_light)。
pub fn isLight(c: Rgb) bool {
    const y = 0.299 * @as(f32, @floatFromInt(c.r)) +
        0.587 * @as(f32, @floatFromInt(c.g)) +
        0.114 * @as(f32, @floatFromInt(c.b));
    return y > 128.0;
}

/// 解析 OSC 11 响应里的 `rgb:RRRR/GGGG/BBBB`(各通道 1-4 hex,取高 8 位)。
/// 找不到/格式错 → null。容忍前后包裹(ESC]11; 前缀、BEL/ST 后缀)。
pub fn parseOsc11(resp: []const u8) ?Rgb {
    const marker = "rgb:";
    const idx = std.mem.indexOf(u8, resp, marker) orelse return null;
    var rest = resp[idx + marker.len ..];
    var ch: [3]u8 = undefined;
    var n: usize = 0;
    while (n < 3) : (n += 1) {
        const slash = std.mem.indexOfScalar(u8, rest, '/');
        const seg = if (n < 2)
            (rest[0 .. slash orelse return null])
        else blk: {
            // 第三段:到非 hex 字符(BEL/ESC/\)或串尾。
            var e: usize = 0;
            while (e < rest.len and isHex(rest[e])) : (e += 1) {}
            break :blk rest[0..e];
        };
        if (seg.len == 0 or seg.len > 4) return null;
        const v16 = std.fmt.parseInt(u16, seg, 16) catch return null;
        // 通道值按 hex 位宽归一到 8 位:1位→<<4|x、2位→原、4位→取高字节。
        ch[n] = switch (seg.len) {
            1 => @intCast((v16 << 4) | v16),
            2 => @intCast(v16 & 0xFF),
            3 => @intCast(v16 >> 4),
            4 => @intCast(v16 >> 8),
            else => unreachable,
        };
        if (n < 2) rest = rest[(slash.?) + 1 ..];
    }
    return Rgb{ .r = ch[0], .g = ch[1], .b = ch[2] };
}

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

// ============================================================================
// 一轮探测
// ============================================================================

/// The questions a round asks. DA1 is always asked last: it is the sentinel.
pub const Want = struct {
    background: bool = false,
    keyboard: bool = false,

    pub fn any(self: Want) bool {
        return self.background or self.keyboard;
    }
};

pub const osc11_query = "\x1b]11;?\x07";
/// Kitty progressive enhancement: "which flags are set?". A terminal that
/// speaks the protocol answers `CSI ? flags u`; one that does not ignores it.
pub const kitty_query = "\x1b[?u";
/// Primary device attributes. Every terminal answers, after everything asked before it.
pub const da1_query = "\x1b[c";

/// What a round writes for `want`: one write, so the answers come back in one burst.
pub fn queryFor(want: Want) []const u8 {
    if (want.background and want.keyboard) return osc11_query ++ kitty_query ++ da1_query;
    if (want.background) return osc11_query ++ da1_query;
    if (want.keyboard) return kitty_query ++ da1_query;
    return "";
}

/// Whether the terminal speaks the Kitty keyboard protocol.
pub const Keyboard = enum {
    /// It answered the flags query.
    supported,
    /// DA1 came back first: terminals answer in order, so it never will.
    unsupported,
    /// Not asked, or the round ended on its deadline before DA1.
    unknown,
};

pub const Result = struct {
    /// Null when not asked, not answered, or malformed.
    background: ?Rgb = null,
    keyboard: Keyboard = .unknown,
    /// DA1 ended the round, not the deadline.
    sentinel: bool = false,
};

/// Splits what the terminal sent during a round into its answers and the
/// rest. The rest — keys typed and text pasted while the round waited — keeps
/// its bytes and their order exactly, so handing it back to stdin leaves the
/// input parser a stream that looks as if no probe had run.
///
/// A byte is typed input unless it belongs to one of the answer shapes:
/// `ESC ] 11 ; … (BEL | ESC \)`, `ESC [ ? digits u` (Kitty flags) and
/// `ESC [ ? digits/semicolons c` (DA1). No key produces those: keys send
/// `ESC [` with no `?`, and Alt+] typed by hand is followed by anything but
/// `11;`. A sequence still open when the round ends is typed input as well.
pub const Scanner = struct {
    want: Want,
    result: Result = .{},
    state: State = .ground,
    /// The sequence begun with ESC, until it is known to be an answer or not.
    seq: [seq_capacity]u8 = undefined,
    seq_len: usize = 0,
    /// How many sequences have begun: a different count means the open one
    /// is not the one that was open before.
    begun: u32 = 0,
    /// Every byte that was not an answer, in arrival order.
    typed: [typed_capacity]u8 = undefined,
    typed_len: usize = 0,

    const State = enum { ground, esc, csi, osc, osc_esc };
    /// Longer than any answer: Windows Terminal's DA1 is 42 bytes. A longer
    /// sequence is typed input (or an answer the input parser then skips).
    pub const seq_capacity = 128;
    pub const typed_capacity = platform_term.replay_capacity;
    const osc11_prefix = "11;";

    pub fn init(want: Want) Scanner {
        return .{ .want = want };
    }

    /// Each byte adds at most one to typed + seq, so `room` bytes always fit.
    pub fn room(self: *const Scanner) usize {
        return typed_capacity - self.typed_len - self.seq_len;
    }

    pub fn feed(self: *Scanner, bytes: []const u8) void {
        std.debug.assert(bytes.len <= self.room());
        for (bytes) |b| self.step(b);
    }

    /// Whether DA1 came back: every answer asked for has arrived.
    pub fn done(self: *const Scanner) bool {
        return self.result.sentinel;
    }

    /// No more bytes will be read: a sequence still open is resolved. One
    /// only an answer could be (`ESC [ ?`, `ESC ] 11 ;`) is an answer cut
    /// short and is dropped: handed to the input parser it would wait there
    /// for a tail that may never come, and take the next typed key for it.
    /// Anything else (a lone Esc, half an arrow key) goes out as typed.
    pub fn finish(self: *Scanner) void {
        self.finishTyping(self.seq_len);
    }

    /// `finish`, except that the bytes a cut answer took from `from` on are
    /// typed instead of dropped with it: they fitted its tail without
    /// completing it.
    pub fn finishTyping(self: *Scanner, from: usize) void {
        if (self.openAnswer()) {
            const kept = self.seq[@min(from, self.seq_len)..self.seq_len];
            @memcpy(self.typed[self.typed_len..][0..kept.len], kept);
            self.typed_len += kept.len;
            self.seq_len = 0;
            self.state = .ground;
        } else self.flushSeq();
    }

    fn openAnswer(self: *const Scanner) bool {
        const seq = self.seq[0..self.seq_len];
        return std.mem.startsWith(u8, seq, "\x1b[?") or std.mem.startsWith(u8, seq, "\x1b]" ++ osc11_prefix);
    }

    /// The bytes an OSC 11 answer's colour is written with (`rgb:RRRR/GGGG/BBBB`).
    const osc11_colour = "rgb:0123456789abcdefABCDEF/";

    /// Whether `next` can be the rest of the open answer: only the bytes its
    /// shape allows, up to its terminator (or as far as `next` goes). A DA1
    /// or Kitty answer continues with digits and `;` up to `c` or `u`; an OSC
    /// 11 answer with its colour up to BEL or ST. The tail of a cut answer
    /// fits (`22c`); keys typed after it do not (`ls`, `fix the bug`). An open
    /// sequence a key could be is not judged: true.
    pub fn tailFits(self: *const Scanner, next: []const u8) bool {
        if (!self.openAnswer()) return true;
        if (self.state == .osc_esc) return next.len == 0 or next[0] == '\\';
        const csi = self.seq[1] == '[';
        for (next) |b| {
            if (csi) {
                if (b == 'c' or b == 'u') return true;
                if (std.mem.indexOfScalar(u8, "0123456789;", b) == null) return false;
            } else {
                if (b == 0x07 or b == 0x1b) return true;
                if (std.mem.indexOfScalar(u8, osc11_colour, b) == null) return false;
            }
        }
        return true;
    }

    /// The typed bytes so far were handed on; collect afresh.
    pub fn clearTyped(self: *Scanner) void {
        self.typed_len = 0;
    }

    pub fn typedBytes(self: *const Scanner) []const u8 {
        return self.typed[0..self.typed_len];
    }

    fn step(self: *Scanner, b: u8) void {
        switch (self.state) {
            .ground => if (b == 0x1b) self.begin() else self.type1(b),
            .esc => switch (b) {
                '[' => self.advance(b, .csi),
                ']' => self.advance(b, .osc),
                else => self.abort(b),
            },
            .csi => switch (b) {
                0x20...0x3f => self.advance(b, .csi), // parameters, intermediates
                0x40...0x7e => if (self.take(b)) self.endCsi() else self.abort(b),
                else => self.abort(b),
            },
            .osc => {
                const at = self.seq_len - 2; // bytes after `ESC ]`
                if (at < osc11_prefix.len) {
                    if (b == osc11_prefix[at]) self.advance(b, .osc) else self.abort(b);
                    return;
                }
                switch (b) {
                    0x07 => self.endOsc(),
                    0x1b => self.advance(b, .osc_esc),
                    0x20...0x7e => self.advance(b, .osc),
                    else => self.abort(b),
                }
            },
            .osc_esc => {
                if (b == '\\') return self.endOsc();
                // Not ST: the OSC was cut short. What came before the ESC was
                // typed; the ESC begins whatever follows.
                self.seq_len -= 1;
                self.flushSeq();
                self.begin();
                self.step(b);
            },
        }
    }

    fn type1(self: *Scanner, b: u8) void {
        self.typed[self.typed_len] = b;
        self.typed_len += 1;
    }

    fn begin(self: *Scanner) void {
        self.seq[0] = 0x1b;
        self.seq_len = 1;
        self.state = .esc;
        self.begun +%= 1;
    }

    fn take(self: *Scanner, b: u8) bool {
        if (self.seq_len == seq_capacity) return false;
        self.seq[self.seq_len] = b;
        self.seq_len += 1;
        return true;
    }

    fn advance(self: *Scanner, b: u8, next: State) void {
        if (!self.take(b)) return self.abort(b);
        self.state = next;
    }

    /// `b` cannot continue the open sequence: the sequence was typed, and `b`
    /// starts over from the ground state.
    fn abort(self: *Scanner, b: u8) void {
        self.flushSeq();
        self.step(b);
    }

    fn flushSeq(self: *Scanner) void {
        @memcpy(self.typed[self.typed_len..][0..self.seq_len], self.seq[0..self.seq_len]);
        self.typed_len += self.seq_len;
        self.seq_len = 0;
        self.state = .ground;
    }

    fn endCsi(self: *Scanner) void {
        const final = self.seq[self.seq_len - 1];
        const params = self.seq[2 .. self.seq_len - 1];
        const private = params.len >= 2 and params[0] == '?';
        if (private and final == 'u' and allIn(params[1..], "0123456789")) {
            if (self.want.keyboard) self.result.keyboard = .supported;
        } else if (private and final == 'c' and allIn(params[1..], "0123456789;")) {
            self.result.sentinel = true;
            if (self.want.keyboard and self.result.keyboard == .unknown) self.result.keyboard = .unsupported;
        } else return self.flushSeq();
        self.seq_len = 0;
        self.state = .ground;
    }

    fn endOsc(self: *Scanner) void {
        if (self.want.background) self.result.background = parseOsc11(self.seq[0..self.seq_len]);
        self.seq_len = 0;
        self.state = .ground;
    }
};

fn allIn(bytes: []const u8, set: []const u8) bool {
    for (bytes) |b| if (std.mem.indexOfScalar(u8, set, b) == null) return false;
    return true;
}

/// What a round's transport reports when it waits for the terminal.
pub const Wait = enum { readable, timeout, interrupted, closed };

/// One round over `io`: write the query for `want`, then read until DA1 or
/// until `deadline_ms` has passed. `io` is the terminal (`TerminalIo`) or a
/// scripted one in tests: `sendQuery([]const u8) bool`, `wait(timeout_ms: u32)
/// Wait`, `read([]u8) isize`, `nowMs() i64`.
///
/// Reading stops while the typed bytes would overflow what stdin can be
/// handed back: anything after that stays with the terminal, in order.
///
/// What the terminal had queued before the query is read first and is not
/// this round's: a program that ran before may have left answers unread, and
/// its DA1 taken for this round's would end the round before this round's
/// Kitty answer. Answers among it are dropped, the rest is typed.
///
/// A round that DA1 ended is finished (`Scanner.finish`). One the deadline
/// ended keeps its open sequence: it may be an answer whose tail is still on
/// its way, and the caller decides (`probe` keeps reading it, `Late`).
pub fn runRound(io: anytype, want: Want, deadline_ms: u32) Scanner {
    var scanner = Scanner.init(want);
    if (!want.any()) return scanner;
    readQueued(io, &scanner);
    scanner.finish();
    scanner.result = .{};
    if (!io.sendQuery(queryFor(want))) return scanner;
    const start = io.nowMs();
    while (!scanner.done()) {
        const elapsed = io.nowMs() - start;
        if (elapsed >= deadline_ms) break;
        var chunk: [256]u8 = undefined;
        const limit = @min(chunk.len, scanner.room());
        if (limit == 0) break;
        switch (io.wait(@intCast(@as(i64, deadline_ms) - elapsed))) {
            .readable => {},
            // A signal (a resize) cut the wait short; the deadline still bounds the loop.
            .interrupted => continue,
            .timeout, .closed => break,
        }
        const n = io.read(chunk[0..limit]);
        if (n <= 0) break;
        scanner.feed(chunk[0..@intCast(n)]);
    }
    if (scanner.done()) scanner.finish();
    return scanner;
}

/// Feed what `io` has queued right now into `scanner`, without waiting.
fn readQueued(io: anytype, scanner: *Scanner) void {
    var chunk: [256]u8 = undefined;
    while (true) {
        const limit = @min(chunk.len, scanner.room());
        if (limit == 0 or io.wait(0) != .readable) return;
        const n = io.read(chunk[0..limit]);
        if (n <= 0) return;
        scanner.feed(chunk[0..@intCast(n)]);
    }
}

/// The deadline when DA1 does not come back. A local terminal answers in well
/// under a millisecond (Windows Terminal through ConPTY: ~0.1 ms); this is
/// for slow links, and for a pseudo terminal with nothing behind it.
pub const budget_ms: u32 = 120;

const TerminalIo = struct {
    fd: c_int,

    pub fn sendQuery(self: *const TerminalIo, bytes: []const u8) bool {
        return pfs.writeAll(self.fd, bytes);
    }

    pub fn wait(self: *const TerminalIo, timeout_ms: u32) Wait {
        const rc = platform_term.waitReadable(self.fd, @intCast(timeout_ms));
        if (rc > 0) return .readable;
        if (rc == 0) return .timeout;
        return if (pfs.lastErrnoIs(.INTR)) .interrupted else .closed;
    }

    pub fn read(self: *const TerminalIo, buf: []u8) isize {
        return platform_term.readInput(self.fd, buf); // no EINTR: wait reported data
    }

    pub fn nowMs(_: *const TerminalIo) i64 {
        return util_time.nowMs();
    }
};

/// Ask the terminal what `want` names, in one round. The terminal is stdin's
/// when stdin is one (its answers arrive there, and so do keys typed
/// meanwhile, which go back to stdin), else stdout's, which is asked only for
/// its background: with no terminal on stdin no key reaches the REPL's parser.
/// No terminal, or nothing to ask → nothing known.
///
/// Windows console: not asked. Measured on Windows Terminal 1.24 under
/// Windows 11 26300: the console host (ConPTY) answers DA1 itself in about
/// 0.1 ms and never answers `CSI ? u`, not even after a push, so the keyboard
/// answer could only be "unsupported"; and the enable sequence, written to the
/// stdin descriptor, cannot reach a Windows console anyway. It does answer
/// OSC 11; the theme keeps its Windows default until that is wired.
///
/// `hand_over`: the REPL takes stdin's terminal next (`handOver`). A round the
/// deadline ended then leaves the terminal quiet and keeps reading its answers
/// until the REPL takes over (`Late`); otherwise the terminal is restored.
pub fn probe(want: Want, hand_over: bool) Result {
    if (builtin.os.tag == .windows) return .{};
    var asked = want;
    const fd: c_int = if (platform_term.isatty(0)) 0 else 1;
    if (fd != 0) asked.keyboard = false;
    if (!asked.any() or !platform_term.isatty(fd)) return .{};
    const saved = platform_term.enterRawKeepingInput(fd) orelse return .{};

    const started = util_time.nowNs();
    var io: TerminalIo = .{ .fd = fd };
    var round = runRound(&io, asked, budget_ms);
    // DA1 ends the round: the time it took is the terminal's round trip. A
    // round the deadline ended took at least that long (`Late` may learn more).
    g_round_trip_ms = @intCast(@divTrunc(util_time.nowNs() - started, std.time.ns_per_ms));
    const late = !round.done() and fd == 0 and hand_over and platform_term.enterQuiet(fd, saved);
    if (!late) round.finish();
    log.debug("probe", "terminal answered in {d}us: sentinel={} keyboard={s} background={} typed={d}B", .{
        @divTrunc(util_time.nowNs() - started, std.time.ns_per_us),
        round.result.sentinel,
        @tagName(round.result.keyboard),
        round.result.background != null,
        round.typed_len,
    });
    // The scanner holds at most replay_capacity typed bytes: all of it fits.
    if (fd == 0) _ = platform_term.replayInput(0, round.typedBytes());
    if (late) {
        round.clearTyped();
        platform_term.restoreAtExit(fd, saved);
        g_late = Late.init(fd, saved, round);
        g_late.?.asked_ms = @intCast(@divTrunc(started, std.time.ns_per_ms));
    } else platform_term.restoreModeKeepingInput(fd, saved);
    return round.result;
}

/// How long the terminal took to answer the startup probe, in ms, for a
/// reader that waits for the rest of what the terminal is sending
/// (`input.collectStartupInput`: a paste split by a slow link). Null when no
/// round was run (Windows, nothing asked). Written before the REPL's first
/// raw-mode entry reads it (by the splash's thread when a late DA1 comes
/// while it plays, which has ended by then).
var g_round_trip_ms: ?i64 = null;

pub fn roundTripMs() ?i64 {
    return g_round_trip_ms;
}

/// How long an open answer in `Late` waits for the rest of it before what
/// comes next must prove to be that rest (`Scanner.tailFits`): one read wait
/// of the REPL's key loop. A terminal writes an answer in one piece.
const late_tail_ms: i64 = 200;

/// A round the deadline ended, on the REPL's terminal: its answers may still
/// be on their way (a slow link). Until the REPL takes the terminal
/// (`handOver`) it stays quiet (`platform.terminal.enterQuiet`: nothing is
/// echoed, Ctrl+C still works), so a late answer is not printed over the
/// startup screen; and what it queues is read through the round's scanner, so
/// a late answer is not taken for a key (the splash skips on a key) nor typed
/// into the prompt. A process that exits before the REPL restores `original`
/// at exit. Read by the splash's thread while it plays, then by the REPL's
/// first raw-mode entry, which comes after the splash has ended: never by two
/// threads at once.
const Late = struct {
    fd: c_int,
    /// The terminal's mode before the probe: the REPL restores it when it
    /// leaves raw mode.
    original: platform_term.SavedMode,
    /// The round's scanner, with any sequence the deadline cut still open.
    scanner: Scanner,
    /// `platform.terminal.discardCount` when the terminal was last read: a
    /// different count means queued input was thrown away since (a TCSAFLUSH
    /// mode switch), and what came right after the open sequence is its rest.
    discards: u32,
    /// When the open sequence last grew while its tail was awaited.
    progress_ms: i64,
    /// `Scanner.begun` at `progress_ms`: another count is another sequence.
    begun: u32,
    /// Once the open sequence has waited `late_tail_ms`, how long it was
    /// then. From there on every byte must fit its tail and none restarts the
    /// wait. Null while it waits.
    overdue_from: ?usize = null,
    /// When the round's query went out: a DA1 that comes now tells the
    /// terminal's real round trip (`roundTripMs`).
    asked_ms: ?i64 = null,

    fn init(fd: c_int, original: platform_term.SavedMode, scanner: Scanner) Late {
        return .{
            .fd = fd,
            .original = original,
            .scanner = scanner,
            .discards = platform_term.discardCount(),
            .progress_ms = util_time.nowMs(),
            .begun = scanner.begun,
        };
    }

    /// The open sequence is resolved (`Scanner.finish`: a cut answer is
    /// dropped, a cut key is typed). The bytes a cut answer took after it
    /// went overdue are typed: they fitted its tail without completing it.
    fn giveUp(self: *Late) void {
        self.scanner.finishTyping(self.overdue_from orelse self.scanner.seq_len);
        self.overdue_from = null;
    }

    /// Input was discarded since the open sequence was read: its tail may be
    /// gone with it, so it is given up now and the keys typed next are not
    /// fed to it.
    fn expireDiscarded(self: *Late) void {
        const discards = platform_term.discardCount();
        const discarded = discards != self.discards;
        self.discards = discards;
        if (discarded and self.scanner.seq_len > 0) self.giveUp();
    }

    /// Feed one byte, read at `now`. An open sequence that has not grown for
    /// a read wait is overdue: a byte that cannot be its tail gives it up,
    /// and one that can does not restart the wait, so text typed key by key
    /// is not taken for a tail just because `f` fits a colour. The tail may
    /// well have arrived in time and only been read late (nothing reads
    /// between the splash and the REPL), so the time alone does not decide.
    fn take(self: *Late, b: u8, now: i64) void {
        const s = &self.scanner;
        if (s.seq_len > 0 and self.overdue_from == null and now - self.progress_ms >= late_tail_ms) self.overdue_from = s.seq_len;
        if (self.overdue_from != null and !s.tailFits(&.{b})) self.giveUp();
        const answered = s.done();
        s.feed(&.{b});
        if (!answered and s.done()) if (self.asked_ms) |asked| {
            g_round_trip_ms = now - asked;
        };
        if (s.begun != self.begun) {
            // Another sequence began: it waits afresh.
            self.begun = s.begun;
            self.overdue_from = null;
            self.progress_ms = now;
        } else if (s.seq_len == 0) {
            self.overdue_from = null;
        } else if (self.overdue_from == null) self.progress_ms = now;
    }

    /// Hand the typed bytes to stdin. Every byte read adds at most one to
    /// typed + open sequence, and reads are bounded so both fit the replay
    /// (`absorb`): nothing is cut.
    fn replayTyped(self: *Late) bool {
        if (self.scanner.typed_len == 0) return false;
        _ = platform_term.replayInput(self.fd, self.scanner.typedBytes());
        self.scanner.clearTyped();
        return true;
    }

    /// Read what the terminal queued since the round ended through its
    /// scanner: answers are dropped, the rest goes back to stdin
    /// (`replayInput`). True when some of it was typed. Reading stops while
    /// the replay could not take what the next bytes may produce (the open
    /// sequence included): the rest stays with the terminal, in order, for
    /// stdin's next reader.
    fn absorb(self: *Late) bool {
        self.expireDiscarded();
        var typed = self.replayTyped();
        var chunk: [256]u8 = undefined;
        while (true) {
            const room = platform_term.replayRoom(self.fd) -| self.scanner.seq_len;
            const limit = @min(chunk.len, self.scanner.room(), room);
            if (limit == 0) break;
            const n = platform_term.readPending(self.fd, chunk[0..limit]);
            if (n <= 0) break;
            const now = util_time.nowMs();
            // Giving up the open sequence moves its bytes to the typed ones
            // or drops them: the bound above still holds.
            for (chunk[0..@intCast(n)]) |b| self.take(b, now);
            if (self.replayTyped()) typed = true;
        }
        return typed;
    }
};
var g_late: ?Late = null;

/// Whether what stdin has pending is only the late answers of a round the
/// deadline ended (they are read and dropped here). False when something was
/// typed (it stays pending, for stdin's next reader) and when there is no
/// such round: then whatever is pending is input.
pub fn lateAnswersOnly(fd: c_int) bool {
    const late = if (g_late) |*l| l else return false;
    if (late.fd != fd or platform_term.replayRoom(fd) < platform_term.replay_capacity) return false;
    return !late.absorb();
}

/// The REPL takes stdin's terminal. After a round the deadline ended, what is
/// queued is read through its scanner one last time, an answer still cut
/// short is dropped, and the mode the terminal had before the probe is
/// returned: the REPL restores it when it leaves raw mode (the terminal is
/// quiet now). Null when no such round is pending.
pub fn handOver(fd: c_int) ?platform_term.SavedMode {
    const late = if (g_late) |*l| l else return null;
    if (late.fd != fd) return null;
    _ = late.absorb();
    late.giveUp();
    _ = late.replayTyped();
    const original = late.original;
    g_late = null;
    platform_term.cancelRestoreAtExit();
    return original;
}

// ============================================================================
// 测试
// ============================================================================
const testing = std.testing;

test "isLight: 黑→暗, 白→亮, 中灰边界" {
    try testing.expect(!isLight(.{ .r = 0, .g = 0, .b = 0 }));
    try testing.expect(isLight(.{ .r = 255, .g = 255, .b = 255 }));
    try testing.expect(!isLight(.{ .r = 30, .g = 30, .b = 30 })); // 典型暗终端
    try testing.expect(isLight(.{ .r = 240, .g = 240, .b = 240 })); // 典型亮终端
}

test "parseOsc11: 4-hex 各通道取高字节" {
    // 白:ffff/ffff/ffff → 255,255,255
    const w = parseOsc11("\x1b]11;rgb:ffff/ffff/ffff\x07").?;
    try testing.expectEqual(@as(u8, 255), w.r);
    try testing.expectEqual(@as(u8, 255), w.b);
    // 黑
    const b = parseOsc11("\x1b]11;rgb:0000/0000/0000\x1b\\").?;
    try testing.expectEqual(@as(u8, 0), b.r);
    // 典型暗背景 #1e1e1e → 1e1e/1e1e/1e1e
    const dark = parseOsc11("\x1b]11;rgb:1e1e/1e1e/1e1e\x07").?;
    try testing.expectEqual(@as(u8, 0x1e), dark.r);
    try testing.expect(!isLight(dark));
}

test "parseOsc11: 2-hex 通道" {
    const c = parseOsc11("rgb:ab/cd/ef").?;
    try testing.expectEqual(@as(u8, 0xab), c.r);
    try testing.expectEqual(@as(u8, 0xcd), c.g);
    try testing.expectEqual(@as(u8, 0xef), c.b);
}

test "parseOsc11: 畸形 → null" {
    try testing.expect(parseOsc11("garbage") == null);
    try testing.expect(parseOsc11("\x1b]11;rgb:zz/00/00\x07") == null);
    try testing.expect(parseOsc11("rgb:") == null);
}

const both: Want = .{ .background = true, .keyboard = true };

fn scan(want: Want, bytes: []const u8) Scanner {
    var s = Scanner.init(want);
    s.feed(bytes);
    return s;
}

test "queryFor: one write per round, DA1 last" {
    try testing.expectEqualStrings("\x1b]11;?\x07\x1b[?u\x1b[c", queryFor(both));
    try testing.expectEqualStrings("\x1b[?u\x1b[c", queryFor(.{ .keyboard = true }));
    try testing.expectEqualStrings("\x1b]11;?\x07\x1b[c", queryFor(.{ .background = true }));
    try testing.expectEqualStrings("", queryFor(.{}));
}

test "Scanner: a Kitty answer before DA1 is support; DA1 ends the round" {
    var s = scan(both, "\x1b]11;rgb:ffff/ffff/ffff\x1b\\\x1b[?0u\x1b[?62;22c");
    try testing.expect(s.done());
    try testing.expectEqual(Keyboard.supported, s.result.keyboard);
    try testing.expect(isLight(s.result.background.?));
    s.finish();
    try testing.expectEqualStrings("", s.typedBytes());
}

test "Scanner: DA1 without a Kitty answer is a definite no" {
    // Windows Terminal through ConPTY, as measured.
    const s = scan(.{ .keyboard = true }, "\x1b[?61;4;6;7;14;21;22;23;24;28;32;42;52c");
    try testing.expect(s.done());
    try testing.expectEqual(Keyboard.unsupported, s.result.keyboard);
    try testing.expect(s.result.background == null);
}

test "Scanner: an answer split across reads is still an answer" {
    var s = Scanner.init(both);
    const stream = "\x1b]11;rgb:1e1e/1e1e/2e2e\x07\x1b[?1u\x1b[?64;1c";
    for (0..stream.len) |i| {
        try testing.expect(!s.done());
        s.feed(stream[i .. i + 1]);
    }
    try testing.expect(s.done());
    try testing.expectEqual(Keyboard.supported, s.result.keyboard);
    try testing.expectEqual(@as(u8, 0x1e), s.result.background.?.r);
    try testing.expectEqualStrings("", s.typedBytes());
}

test "Scanner: keys typed between the answers keep their bytes and order" {
    // Text, an arrow key, Alt+x, a Kitty-encoded Shift+Enter, Enter and a
    // lone Esc, around and between the answers.
    var s = scan(both, "a\x1b]11;rgb:0/0/0\x07b\x1b[A\x1b[?1uc\x1bx\x1b[13;2u\r\x1b[?62c\x1b");
    try testing.expect(s.done());
    try testing.expectEqual(Keyboard.supported, s.result.keyboard);
    try testing.expectEqual(@as(u8, 0), s.result.background.?.r);
    s.finish();
    try testing.expectEqualStrings("ab\x1b[Ac\x1bx\x1b[13;2u\r\x1b", s.typedBytes());
}

test "Scanner: what only looks like the start of an answer is typed" {
    // Alt+] then text, Esc Esc, CSI with a private marker but another final,
    // a C0 control inside a sequence, an OSC that is not 11, an OSC 11 cut
    // short by another sequence.
    var s = scan(both, "\x1b]ab\x1b\x1b[?25h\x1b[?6\x03\x1b]10;x\x07\x1b]11;rgb\x1b[B");
    try testing.expect(!s.done());
    s.finish();
    try testing.expectEqualStrings("\x1b]ab\x1b\x1b[?25h\x1b[?6\x03\x1b]10;x\x07\x1b]11;rgb\x1b[B", s.typedBytes());
    try testing.expectEqual(Keyboard.unknown, s.result.keyboard);
    try testing.expect(s.result.background == null);
}

test "Scanner: an echo of the query itself is not an answer" {
    var s = scan(.{ .keyboard = true }, "\x1b[?u");
    s.finish();
    try testing.expectEqualStrings("\x1b[?u", s.typedBytes());
    try testing.expectEqual(Keyboard.unknown, s.result.keyboard);
}

test "Scanner: a sequence longer than any answer is typed, and room never runs out" {
    var s = Scanner.init(.{ .keyboard = true });
    var long: [Scanner.seq_capacity + 10]u8 = undefined;
    @memset(&long, '1');
    long[0] = 0x1b;
    long[1] = '[';
    long[2] = '?';
    s.feed(&long);
    s.feed("c");
    s.finish();
    try testing.expect(!s.done());
    try testing.expectEqual(long.len + 1, s.typed_len);
}

test "Scanner: a Kitty answer not asked for is consumed but proves nothing" {
    const s = scan(.{ .background = true }, "\x1b[?1u\x1b[?62c");
    try testing.expect(s.done());
    try testing.expectEqual(Keyboard.unknown, s.result.keyboard);
    try testing.expectEqualStrings("", s.typedBytes());
}

/// A terminal played from a script: `(at_ms, bytes)` arrive at their times.
/// Time moves only when the round waits, so every run is the same.
const ScriptedTerminal = struct {
    events: []const Event,
    next: usize = 0,
    offset: usize = 0,
    now: i64 = 0,
    written: [64]u8 = undefined,
    written_len: usize = 0,
    write_ok: bool = true,

    const Event = struct { at_ms: i64, bytes: []const u8 };

    pub fn sendQuery(self: *ScriptedTerminal, bytes: []const u8) bool {
        @memcpy(self.written[self.written_len..][0..bytes.len], bytes);
        self.written_len += bytes.len;
        return self.write_ok;
    }

    pub fn wait(self: *ScriptedTerminal, timeout_ms: u32) Wait {
        if (self.next == self.events.len) {
            self.now += timeout_ms;
            return .timeout;
        }
        const at = self.events[self.next].at_ms;
        if (at > self.now + timeout_ms) {
            self.now += timeout_ms;
            return .timeout;
        }
        self.now = @max(self.now, at);
        return .readable;
    }

    pub fn read(self: *ScriptedTerminal, buf: []u8) isize {
        const ev = self.events[self.next];
        const n = @min(buf.len, ev.bytes.len - self.offset);
        @memcpy(buf[0..n], ev.bytes[self.offset..][0..n]);
        self.offset += n;
        if (self.offset == ev.bytes.len) {
            self.next += 1;
            self.offset = 0;
        }
        return @intCast(n);
    }

    pub fn nowMs(self: *const ScriptedTerminal) i64 {
        return self.now;
    }

    /// Bytes the round left unread, in order.
    fn unread(self: *const ScriptedTerminal, out: []u8) []const u8 {
        var len: usize = 0;
        var i = self.next;
        var off = self.offset;
        while (i < self.events.len) : (i += 1) {
            const rest = self.events[i].bytes[off..];
            @memcpy(out[len..][0..rest.len], rest);
            len += rest.len;
            off = 0;
        }
        return out[0..len];
    }
};

test "runRound: a positive answer ends the round when DA1 arrives" {
    var term: ScriptedTerminal = .{ .events = &.{
        .{ .at_ms = 2, .bytes = "\x1b]11;rgb:ffff/ffff/ffff\x07\x1b[?1u" },
        .{ .at_ms = 3, .bytes = "\x1b[?62c" },
    } };
    const round = runRound(&term, both, budget_ms);
    try testing.expectEqualStrings(queryFor(both), term.written[0..term.written_len]);
    try testing.expect(round.result.sentinel);
    try testing.expectEqual(Keyboard.supported, round.result.keyboard);
    try testing.expect(isLight(round.result.background.?));
    // Finished at DA1, not at the deadline.
    try testing.expectEqual(@as(i64, 3), term.now);
}

test "runRound: DA1 alone is a negative at once, not after the deadline" {
    var term: ScriptedTerminal = .{ .events = &.{.{ .at_ms = 1, .bytes = "\x1b[?62;22c" }} };
    const round = runRound(&term, .{ .keyboard = true }, budget_ms);
    try testing.expectEqual(Keyboard.unsupported, round.result.keyboard);
    try testing.expectEqual(@as(i64, 1), term.now);
}

test "runRound: a late answer within the budget still counts" {
    // A slow link: the answers take 100 ms of the 120.
    var term: ScriptedTerminal = .{ .events = &.{
        .{ .at_ms = 100, .bytes = "\x1b[?1u" },
        .{ .at_ms = 110, .bytes = "\x1b[?62c" },
    } };
    const round = runRound(&term, .{ .keyboard = true }, budget_ms);
    try testing.expectEqual(Keyboard.supported, round.result.keyboard);
    try testing.expect(round.result.sentinel);
}

test "runRound: no DA1 by the deadline is unknown, and what came is kept" {
    // The Kitty answer would prove support, but this terminal never gets
    // that far before the deadline; a typed key arrives meanwhile.
    var term: ScriptedTerminal = .{ .events = &.{
        .{ .at_ms = 30, .bytes = "x" },
        .{ .at_ms = 300, .bytes = "\x1b[?1u\x1b[?62c" },
    } };
    const round = runRound(&term, .{ .keyboard = true }, budget_ms);
    try testing.expect(!round.result.sentinel);
    try testing.expectEqual(Keyboard.unknown, round.result.keyboard);
    try testing.expectEqualStrings("x", round.typedBytes());
    try testing.expectEqual(@as(i64, budget_ms), term.now);
}

test "runRound: an answer still arriving at the deadline is not handed back as typed" {
    var term: ScriptedTerminal = .{ .events = &.{
        .{ .at_ms = 5, .bytes = "h\x1b[?62;" },
        .{ .at_ms = 500, .bytes = "22c" },
    } };
    var round = runRound(&term, .{ .keyboard = true }, budget_ms);
    try testing.expectEqual(Keyboard.unknown, round.result.keyboard);
    round.finish();
    // `ESC [ ?` is a shape only an answer has. Handed to the input parser,
    // it waited there for a tail that a later raw-mode entry flushed, and
    // ate the next key the user typed.
    try testing.expectEqualStrings("h", round.typedBytes());
}

test "Scanner: finish drops an open sequence only an answer could be, keeps one a key could be" {
    const cases = [_]struct { in: []const u8, typed: []const u8 }{
        .{ .in = "a\x1b[?62;", .typed = "a" }, // DA1 cut short
        .{ .in = "a\x1b[?", .typed = "a" },
        .{ .in = "a\x1b]11;rgb:1e1e/", .typed = "a" }, // OSC 11 cut short
        .{ .in = "a\x1b]11;", .typed = "a" },
        .{ .in = "a\x1b[", .typed = "a\x1b[" }, // half an arrow key
        .{ .in = "a\x1b[1;5", .typed = "a\x1b[1;5" }, // half of Ctrl+Up
        .{ .in = "a\x1b]1", .typed = "a\x1b]1" }, // Alt+] then 1
        .{ .in = "a\x1b", .typed = "a\x1b" }, // Esc
    };
    for (cases) |c| {
        var s = scan(both, c.in);
        s.finish();
        try testing.expectEqualStrings(c.typed, s.typedBytes());
    }
}

test "runRound: answers already queued before the query are not this round's" {
    // A program that ran before left its DA1 answer unread. Read as this
    // round's sentinel it made a Kitty terminal look unsupported.
    var term: ScriptedTerminal = .{ .events = &.{
        .{ .at_ms = -1, .bytes = "k\x1b[?62;22c\x1b]11;rgb:0/0/0\x07" },
        .{ .at_ms = 2, .bytes = "\x1b[?1u" },
        .{ .at_ms = 3, .bytes = "\x1b[?62;22c" },
    } };
    var round = runRound(&term, .{ .keyboard = true }, budget_ms);
    try testing.expectEqual(Keyboard.supported, round.result.keyboard);
    try testing.expect(round.result.background == null);
    round.finish();
    // The key typed before the round is kept.
    try testing.expectEqualStrings("k", round.typedBytes());
}

test "runRound: keys typed before, between and after the answers come back in order" {
    var term: ScriptedTerminal = .{ .events = &.{
        .{ .at_ms = 0, .bytes = "he" },
        .{ .at_ms = 1, .bytes = "\x1b[?1ul" },
        .{ .at_ms = 2, .bytes = "l\x1b[?62co\x1b[" },
    } };
    const round = runRound(&term, .{ .keyboard = true }, budget_ms);
    try testing.expectEqual(Keyboard.supported, round.result.keyboard);
    // The `ESC [` after DA1 is half an arrow key: it goes back as is and the
    // terminal's next bytes complete it.
    try testing.expectEqualStrings("hello\x1b[", round.typedBytes());
}

test "runRound: interrupted waits retry within the deadline; a closed terminal ends it" {
    const Flaky = struct {
        inner: ScriptedTerminal,
        interruptions: u8 = 2,
        pub fn sendQuery(self: *@This(), bytes: []const u8) bool {
            return self.inner.sendQuery(bytes);
        }
        pub fn wait(self: *@This(), timeout_ms: u32) Wait {
            if (self.interruptions > 0) {
                self.interruptions -= 1;
                self.inner.now += 1;
                return .interrupted;
            }
            return self.inner.wait(timeout_ms);
        }
        pub fn read(self: *@This(), buf: []u8) isize {
            return self.inner.read(buf);
        }
        pub fn nowMs(self: *const @This()) i64 {
            return self.inner.now;
        }
    };
    var flaky: Flaky = .{ .inner = .{ .events = &.{.{ .at_ms = 10, .bytes = "\x1b[?62c" }} } };
    const round = runRound(&flaky, .{ .keyboard = true }, budget_ms);
    try testing.expectEqual(Keyboard.unsupported, round.result.keyboard);

    const Closed = struct {
        pub fn sendQuery(_: *@This(), _: []const u8) bool {
            return true;
        }
        pub fn wait(_: *@This(), _: u32) Wait {
            return .closed;
        }
        pub fn read(_: *@This(), _: []u8) isize {
            unreachable;
        }
        pub fn nowMs(_: *const @This()) i64 {
            return 0;
        }
    };
    var closed: Closed = .{};
    try testing.expectEqual(Keyboard.unknown, runRound(&closed, .{ .keyboard = true }, budget_ms).result.keyboard);
}

test "runRound: nothing asked reads nothing; an unwritten query reads only what was queued" {
    var term: ScriptedTerminal = .{ .events = &.{
        .{ .at_ms = -1, .bytes = "k" },
        .{ .at_ms = 5, .bytes = "\x1b[?62c" },
    } };
    _ = runRound(&term, .{}, budget_ms);
    try testing.expectEqual(@as(usize, 0), term.written_len);
    term.write_ok = false;
    const round = runRound(&term, .{ .keyboard = true }, budget_ms);
    try testing.expectEqual(Keyboard.unknown, round.result.keyboard);
    // The key typed before the round is the probe's to hand back.
    try testing.expectEqualStrings("k", round.typedBytes());
    var rest: [8]u8 = undefined;
    try testing.expectEqualStrings("\x1b[?62c", term.unread(&rest));
}

test "Late: answers that come after the deadline are dropped, keys are kept, a cut answer is dropped at hand-over" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // a pipe stands in for the terminal
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    const r = fds[0];
    defer forgetOwedForTest(r);
    // The deadline cut the round inside DA1.
    g_late = Late.init(r, std.mem.zeroes(platform_term.SavedMode), scan(both, "\x1b[?62;"));
    defer g_late = null;
    var buf: [32]u8 = undefined;

    // Its tail and a late OSC 11 answer: not a key, nothing for the prompt.
    try testing.expect(pfs.writeAll(fds[1], "22c\x1b]11;rgb:0/0/0\x07"));
    try testing.expect(lateAnswersOnly(r));
    try testing.expectEqual(@as(i32, 0), platform_term.waitReadable(r, 0));

    // A key typed meanwhile is a key; it stays pending for the prompt.
    try testing.expect(pfs.writeAll(fds[1], "x"));
    try testing.expect(!lateAnswersOnly(r));
    // Pending bytes owed to the prompt are input too.
    try testing.expect(!lateAnswersOnly(r));

    // The REPL takes over while another answer is still cut short: dropped.
    try testing.expect(pfs.writeAll(fds[1], "y\x1b[?1"));
    try testing.expect(handOver(r) != null);
    try testing.expect(g_late == null);
    try testing.expect(handOver(r) == null);
    try testing.expectEqual(@as(isize, 2), platform_term.readInput(r, &buf));
    try testing.expectEqualStrings("xy", buf[0..2]);
    try testing.expectEqual(@as(i32, 0), platform_term.waitReadable(r, 0));
}

/// A test that stops early leaves bytes owed to its pipe's fd, which the
/// next test's pipe may reuse.
fn forgetOwedForTest(fd: c_int) void {
    var sink: [256]u8 = undefined;
    while (platform_term.replayRoom(fd) < platform_term.replay_capacity) {
        if (platform_term.readInput(fd, &sink) <= 0) break; // no EINTR: the replay buffer, no syscall
    }
}

/// Read everything `replayInput` owes `fd`, then what the pipe still holds.
fn drainForTest(fd: c_int, owed: []u8, rest: []u8) struct { owed: []u8, rest: []u8 } {
    var o: usize = 0;
    while (platform_term.replayRoom(fd) < platform_term.replay_capacity) {
        const n = platform_term.readInput(fd, owed[o..]); // no EINTR: the replay buffer, no syscall
        if (n <= 0) break;
        o += @intCast(n);
    }
    var r: usize = 0;
    while (platform_term.waitReadable(fd, 0) > 0) {
        const n = platform_term.readInput(fd, rest[r..]); // no EINTR: a test pipe that poll reported readable
        if (n <= 0) break;
        r += @intCast(n);
    }
    return .{ .owed = owed[0..o], .rest = rest[0..r] };
}

test "Late: a cut answer whose tail a mode switch discarded does not swallow the keys typed after it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // a pipe stands in for the terminal
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    const r = fds[0];
    defer forgetOwedForTest(r);
    g_late = Late.init(r, std.mem.zeroes(platform_term.SavedMode), scan(both, "\x1b[?62;"));
    defer g_late = null;
    // The tail arrives and a TCSAFLUSH mode switch (the splash's raw entry,
    // a resume) discards it.
    try testing.expect(pfs.writeAll(fds[1], "22c"));
    platform_term.discardPendingInput(r);
    // What is typed next is typed, all of it.
    try testing.expect(pfs.writeAll(fds[1], "ls"));
    try testing.expect(!lateAnswersOnly(r));
    try testing.expect(handOver(r) != null);
    var owed: [16]u8 = undefined;
    var rest: [16]u8 = undefined;
    const got = drainForTest(r, &owed, &rest);
    try testing.expectEqualStrings("ls", got.owed);
}

test "Late: a discard that found nothing queued leaves a cut answer to the tail that comes after it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    const r = fds[0];
    defer forgetOwedForTest(r);
    g_late = Late.init(r, std.mem.zeroes(platform_term.SavedMode), scan(both, "\x1b[?62;"));
    defer g_late = null;
    // The splash enters raw mode (TCSAFLUSH) right after the probe, before
    // the tail; the tail comes while it plays, then a key.
    platform_term.discardPendingInput(r);
    try testing.expect(pfs.writeAll(fds[1], "22c"));
    try testing.expect(lateAnswersOnly(r));
    try testing.expect(pfs.writeAll(fds[1], "ls"));
    try testing.expect(!lateAnswersOnly(r));
    try testing.expect(handOver(r) != null);
    var owed: [16]u8 = undefined;
    var rest: [16]u8 = undefined;
    const got = drainForTest(r, &owed, &rest);
    try testing.expectEqualStrings("ls", got.owed);
}

test "Late: a cut answer that waited a read wait for its tail is given up, and the text typed next is typed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    const r = fds[0];
    defer forgetOwedForTest(r);
    // An OSC 11 answer cut inside its colour; nothing discarded the tail,
    // it just never came.
    g_late = Late.init(r, std.mem.zeroes(platform_term.SavedMode), scan(both, "\x1b]11;rgb:1e1e/"));
    defer g_late = null;
    g_late.?.progress_ms -= late_tail_ms;
    // Text the OSC body would have taken as its payload.
    try testing.expect(pfs.writeAll(fds[1], "fix the bug"));
    try testing.expect(!lateAnswersOnly(r));
    try testing.expect(pfs.writeAll(fds[1], " now"));
    try testing.expect(handOver(r) != null);
    var owed: [32]u8 = undefined;
    var rest: [8]u8 = undefined;
    const got = drainForTest(r, &owed, &rest);
    try testing.expectEqualStrings("fix the bug now", got.owed);
}

test "Late: a cut answer read only after a read wait still takes the tail that completes it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    const r = fds[0];
    defer forgetOwedForTest(r);
    // The tail came right after the deadline and sat in the queue; nothing
    // read it until the REPL took over, seconds later (App.init).
    g_late = Late.init(r, std.mem.zeroes(platform_term.SavedMode), scan(both, "\x1b[?62;"));
    defer g_late = null;
    g_late.?.progress_ms -= 10 * late_tail_ms;
    try testing.expect(pfs.writeAll(fds[1], "22cls"));
    try testing.expect(handOver(r) != null);
    var owed: [16]u8 = undefined;
    var rest: [8]u8 = undefined;
    const got = drainForTest(r, &owed, &rest);
    try testing.expectEqualStrings("ls", got.owed);
}

test "Late: keys typed one by one after a cut answer went overdue are typed, those that fit its tail too" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // What the prompt gets when, after the cut answer waited a read wait for
    // its tail, the text is typed key by key, each key read on its own.
    const cases = [_]struct { cut: []const u8, typed: []const u8, prompt: []const u8 }{
        // `f` is a hex digit: it fits the colour. Taking it used to restart
        // the wait, so the next key fitted too (an OSC body takes any printable).
        .{ .cut = "\x1b]11;rgb:1e1e/", .typed = "fix the bug", .prompt = "fix the bug" },
        .{ .cut = "\x1b[?62;", .typed = "1. fix", .prompt = "1. fix" },
        .{ .cut = "\x1b]11;rgb:1e1e/", .typed = "hello", .prompt = "hello" },
        // The tail itself, arriving late and in pieces, still completes it.
        .{ .cut = "\x1b[?62;", .typed = "22cls", .prompt = "ls" },
    };
    for (cases) |case| {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
        defer _ = std.c.close(fds[0]);
        defer _ = std.c.close(fds[1]);
        const r = fds[0];
        defer forgetOwedForTest(r);
        g_late = Late.init(r, std.mem.zeroes(platform_term.SavedMode), scan(both, case.cut));
        defer g_late = null;
        g_late.?.progress_ms -= late_tail_ms;
        for (case.typed) |c| {
            try testing.expect(pfs.writeAll(fds[1], &.{c}));
            _ = lateAnswersOnly(r); // the splash looks, frame after frame
        }
        try testing.expect(handOver(r) != null);
        var owed: [32]u8 = undefined;
        var rest: [8]u8 = undefined;
        try testing.expectEqualStrings(case.prompt, drainForTest(r, &owed, &rest).owed);
    }
}

test "Late: a DA1 that comes after the deadline gives the terminal's round trip" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // a pipe stands in for the terminal
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    const r = fds[0];
    defer forgetOwedForTest(r);
    defer g_round_trip_ms = null;
    // The round ended on its deadline: the round trip is at least that.
    g_round_trip_ms = budget_ms;
    g_late = Late.init(r, std.mem.zeroes(platform_term.SavedMode), Scanner.init(both));
    defer g_late = null;
    g_late.?.asked_ms = util_time.nowMs() - 300;
    // An OSC 11 answer is not the end of the round; DA1 is.
    try testing.expect(pfs.writeAll(fds[1], "\x1b]11;rgb:0/0/0\x07"));
    try testing.expect(lateAnswersOnly(r));
    try testing.expectEqual(@as(?i64, budget_ms), roundTripMs());
    try testing.expect(pfs.writeAll(fds[1], "\x1b[?62;22c"));
    try testing.expect(lateAnswersOnly(r));
    try testing.expect(roundTripMs().? >= 300);
}

test "Scanner.tailFits: an answer's own bytes fit it, typed text does not" {
    try testing.expect(scan(both, "\x1b[?62;").tailFits("22c"));
    try testing.expect(scan(both, "\x1b[?62;").tailFits("2")); // as far as it goes
    try testing.expect(scan(both, "\x1b[?").tailFits("1u"));
    try testing.expect(!scan(both, "\x1b[?62;").tailFits("ls"));
    try testing.expect(!scan(both, "\x1b[?62;").tailFits("4x"));
    try testing.expect(scan(both, "\x1b]11;rgb:1e1e/").tailFits("1e1e/2e2e\x07"));
    try testing.expect(scan(both, "\x1b]11;rgb:1e1e/").tailFits("2e2e\x1b\\"));
    try testing.expect(!scan(both, "\x1b]11;rgb:1e1e/").tailFits("fix the bug"));
    try testing.expect(scan(both, "\x1b]11;rgb:1e1e/2e2e/2e2e\x1b").tailFits("\\"));
    try testing.expect(!scan(both, "\x1b]11;rgb:1e1e/2e2e/2e2e\x1b").tailFits("[A"));
    // A sequence a key could be is not judged here.
    try testing.expect(scan(both, "\x1b[").tailFits("ls"));
}

test "Late: absorbing stops where stdin's replay is full, and what is left stays queued in order" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    const r = fds[0];
    defer forgetOwedForTest(r);
    g_late = Late.init(r, std.mem.zeroes(platform_term.SavedMode), Scanner.init(both));
    defer g_late = null;
    // One byte short of a full replay, then a Left arrow that straddles the
    // limit, then a key.
    var paste: [platform_term.replay_capacity - 1]u8 = undefined;
    @memset(&paste, 'p');
    try testing.expect(pfs.writeAll(fds[1], &paste));
    try testing.expect(pfs.writeAll(fds[1], "\x1b[Dd"));
    try testing.expect(handOver(r) != null);
    var owed: [platform_term.replay_capacity]u8 = undefined;
    var rest: [16]u8 = undefined;
    const got = drainForTest(r, &owed, &rest);
    // Everything arrives once, in order: what fitted was handed back, the
    // rest was left with the terminal.
    var all: [platform_term.replay_capacity + 16]u8 = undefined;
    @memcpy(all[0..got.owed.len], got.owed);
    @memcpy(all[got.owed.len..][0..got.rest.len], got.rest);
    const whole = all[0 .. got.owed.len + got.rest.len];
    try testing.expectEqual(paste.len + 4, whole.len);
    try testing.expectEqualStrings("\x1b[Dd", whole[paste.len..]);
    try testing.expect(got.owed.len <= platform_term.replay_capacity);
}

test "runRound: a paste larger than stdin can be handed stays with the terminal" {
    var paste: [Scanner.typed_capacity + 100]u8 = undefined;
    @memset(&paste, 'p');
    var term: ScriptedTerminal = .{ .events = &.{
        .{ .at_ms = 0, .bytes = &paste },
        .{ .at_ms = 1, .bytes = "\x1b[?62c" },
    } };
    const round = runRound(&term, .{ .keyboard = true }, budget_ms);
    try testing.expectEqual(@as(usize, Scanner.typed_capacity), round.typed_len);
    try testing.expectEqual(Keyboard.unknown, round.result.keyboard);
    var rest: [200]u8 = undefined;
    const left = term.unread(&rest);
    try testing.expectEqual(@as(usize, 100 + 6), left.len);
    try testing.expectEqualStrings("\x1b[?62c", left[100..]);
}

test "probe: no terminal, nothing asked → nothing known, nothing owed" {
    // The test runner's stdin is a pipe or /dev/null; asking nothing returns before any I/O.
    const nothing = probe(.{}, true);
    try testing.expect(nothing.background == null and nothing.keyboard == .unknown and !nothing.sentinel);
    try testing.expect(g_late == null);
}
