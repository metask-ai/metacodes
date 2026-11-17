//! A log file private to one test capture (#472).
//!
//! `test:integration` runs as several shard processes at once, all with the
//! same temp directory. A capture at a fixed path such as
//! `<tmp>/cc-zig-<name>-test.log` is shared by every process: one shard
//! truncates or unlinks the file another is logging into, and the reader sees
//! a foreign line or loses its own. Each `LogFile` instead names the process
//! (pid) and the capture (a per-process counter), and creates the file with
//! `O_EXCL`, so a capture never opens a file someone else made.

const std = @import("std");
const platform = @import("platform");
const pfs = platform.fs;

/// Per-process capture number; with the pid it makes each path unique.
var g_sequence = std.atomic.Value(u32).init(0);

/// A fresh, exclusively created log file under the temp directory. The caller
/// owns it: `deinit` closes the descriptor and removes the path.
pub const LogFile = struct {
    fd: pfs.Fd,
    path_buf: [512]u8,
    path_len: usize,

    /// Creates `<tmp>/cc-zig-<tag>-<pid>-<n>.log` with `CREAT | EXCL`. A name
    /// left over from an earlier process with the same pid is skipped, never
    /// reused.
    pub fn create(tag: []const u8) !LogFile {
        const pid = platform.process.currentPid();
        var attempts: u32 = 0;
        while (attempts < 64) : (attempts += 1) {
            var self: LogFile = .{ .fd = pfs.invalid_fd, .path_buf = undefined, .path_len = 0 };
            const n = g_sequence.fetchAdd(1, .monotonic);
            const path_z = try std.fmt.bufPrintZ(&self.path_buf, "{s}/cc-zig-{s}-{d}-{d}.log", .{ platform.paths.tempDir(), tag, pid, n });
            self.path_len = path_z.len;
            const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, 0o600);
            if (fd >= 0) {
                self.fd = fd;
                return self;
            }
            if (!pfs.lastErrnoIs(.EXIST)) return error.LogFileCreateFailed;
        }
        return error.LogFileCreateFailed;
    }

    pub fn path(self: *const LogFile) [:0]const u8 {
        return self.path_buf[0..self.path_len :0];
    }

    /// Reads the whole file from offset 0 to EOF into `buf`. A file larger than
    /// `buf` is an error, not a silently cut capture.
    pub fn readAll(self: *const LogFile, buf: []u8) ![]const u8 {
        if (pfs.lseek(self.fd, 0, .set) != 0) return error.LogFileSeekFailed;
        var len: usize = 0;
        while (len < buf.len) {
            const n = pfs.read(self.fd, buf[len..]);
            if (n < 0) return error.LogFileReadFailed;
            if (n == 0) return buf[0..len];
            len += @intCast(n);
        }
        var probe: [1]u8 = undefined;
        const more = pfs.read(self.fd, &probe);
        if (more < 0) return error.LogFileReadFailed;
        if (more > 0) return error.LogFileTooLong;
        return buf[0..len];
    }

    pub fn deinit(self: *LogFile) void {
        pfs.close(self.fd);
        self.fd = pfs.invalid_fd;
        pfs.unlinkPath(self.path().ptr) catch {};
    }
};
