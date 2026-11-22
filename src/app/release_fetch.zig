//! The network half of `metacodes update` for a release install
//! (doc/UPDATE_DESIGN.md §4.2, §5): which tag `<base>/latest` names, the
//! release's SHA256SUMS, and its assets.
//!
//! Every transfer is a `curl` run, as in `scripts/install.sh`, so proxies
//! (`https_proxy`, `all_proxy`, SOCKS, `NO_PROXY`), timeouts and retries
//! behave the same for both. `std.http.Client` (Zig 0.16) does not fit:
//! - it sends HTTPS through an HTTP proxy's CONNECT tunnel without a TLS
//!   handshake (`connectProxied` returns the plain tunnel). That was observed
//!   2026-10-25 as `HttpConnectionClosing` from github.com under
//!   `HTTPS_PROXY`, while the same request without the proxy worked;
//! - its connect has no timeout (`ConnectTcpOptions.timeout` is never
//!   passed on).
//!
//! Policy, all of it in `baseArgs`:
//! - `-q` first, so `~/.curlrc` cannot add options (an `insecure` there would
//!   turn TLS checks off);
//! - `--proto`/`--proto-redir` `=https`, or `=http,https` for a loopback base
//!   (tests, a local mirror), which is also never proxied;
//! - no credential, cookie or netrc;
//! - a 30 s connect timeout, and a transfer that moves no byte for 60 s stops.
//!
//! Downloaded bytes are checked here against the release's sums, never by
//! trusting curl.

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const platform = @import("platform");
const release_source = @import("release_source.zig");

pub const max_sums_bytes: u64 = 64 << 10;
pub const max_archive_bytes: u64 = 512 << 20;
pub const idle_limit_s = 60;
const null_device = if (is_windows) "NUL" else "/dev/null";

pub const Error = error{
    /// No `curl` on PATH.
    CurlUnavailable,
    InvalidUrl,
    /// A final status of 400 or more (curl exit 22; curl names the status).
    HttpStatus,
    /// `<base>/latest` did not redirect to `…/tag/<X.Y.Z>`.
    NoLatestTag,
    TooLarge,
    DigestMismatch,
    /// The host could not be reached, or TLS failed (`Report.curl_exit`).
    ConnectFailed,
    /// The transfer stalled or broke off (`Report.curl_exit`).
    TransferFailed,
};

/// What a failed request was about, for the message.
pub const Report = struct {
    url: []const u8 = "",
    curl_exit: i32 = 0,
};

pub const Fetcher = struct {
    curl: []const u8,
    base_is_loopback: bool,
    user_agent: []const u8,
    /// curl draws its progress bar on stderr for an archive download.
    progress: bool,
    echo_errors: bool = true,

    /// `curl` is the override, or the one on PATH. `arena` owns the path.
    pub fn init(arena: std.mem.Allocator, base: []const u8, user_agent: []const u8, curl: ?[]const u8) !Fetcher {
        const uri = std.Uri.parse(base) catch return error.InvalidUrl;
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = (uri.host orelse return error.InvalidUrl).toRaw(&host_buf) catch return error.InvalidUrl;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const found = curl orelse (platform.exe_lookup.lookup(if (is_windows) "curl.exe" else "curl", &path_buf) orelse return error.CurlUnavailable);
        return .{
            .curl = try arena.dupe(u8, found),
            .base_is_loopback = release_source.isLoopbackHost(host),
            .user_agent = user_agent,
            .progress = platform.terminal.isatty(2),
        };
    }

    /// The tag `<base>/latest` redirects to, found the way `install.sh` finds
    /// it: follow the redirects with HEAD requests and read the final URL.
    pub fn latestTag(self: *const Fetcher, arena: std.mem.Allocator, base: []const u8, report: *Report) ![]const u8 {
        const url = try std.fmt.allocPrint(arena, "{s}/latest", .{base});
        var argv = try self.baseArgs(arena);
        try argv.appendSlice(arena, &.{ "-sS", "-L", "-I", "-o", null_device, "-w", "%{url_effective}", url });
        const out = try captureCurl(arena, argv.items, url, 4096, self.echo_errors, report);
        return tagFromLocation(std.mem.trim(u8, out, " \r\n")) orelse error.NoLatestTag;
    }

    /// A small document (SHA256SUMS), whole.
    pub fn getSmall(self: *const Fetcher, arena: std.mem.Allocator, url: []const u8, limit: u64, report: *Report) ![]const u8 {
        var argv = try self.baseArgs(arena);
        try argv.appendSlice(arena, &.{ "-sS", "-L", "--max-filesize", try std.fmt.allocPrint(arena, "{d}", .{limit}), url });
        const out = try captureCurl(arena, argv.items, url, limit + 1, self.echo_errors, report);
        if (out.len > limit) return error.TooLarge;
        return out;
    }

    /// Download `url` into a new file at `dest`, and check its SHA-256
    /// against `expected_hex`. A mismatch removes the file.
    pub fn download(self: *const Fetcher, arena: std.mem.Allocator, io: std.Io, url: []const u8, dest: []const u8, limit: u64, expected_hex: []const u8, report: *Report) !u64 {
        report.* = .{ .url = url };
        var argv = try self.baseArgs(arena);
        try argv.appendSlice(arena, &.{ if (self.progress) "--progress-bar" else "-sS", "-L", "--max-filesize", try std.fmt.allocPrint(arena, "{d}", .{limit}), "-o", dest, url });
        const code = platform.process.runInherit(try zArgv(arena, argv.items), true) catch return error.CurlUnavailable;
        errdefer std.Io.Dir.cwd().deleteFile(io, dest) catch {};
        if (code != 0) return curlError(code, report);
        const size = (try std.Io.Dir.cwd().statFile(io, dest, .{})).size;
        if (size > limit) return error.TooLarge;
        const actual = try @import("install.zig").fileDigest(io, dest);
        if (!std.mem.eql(u8, &actual, expected_hex)) return error.DigestMismatch;
        return size;
    }

    fn baseArgs(self: *const Fetcher, arena: std.mem.Allocator) !std.ArrayList([]const u8) {
        var argv: std.ArrayList([]const u8) = .empty;
        const protocols = if (self.base_is_loopback) "=http,https" else "=https";
        try argv.appendSlice(arena, &.{
            self.curl,                                     "-q",
            "-f",                                          "--retry",
            "3",                                           "--connect-timeout",
            "30",                                          "--speed-limit",
            "1",                                           "--speed-time",
            std.fmt.comptimePrint("{d}", .{idle_limit_s}), "--proto",
            protocols,                                     "--proto-redir",
            protocols,                                     "-A",
            self.user_agent,
        });
        if (self.base_is_loopback) try argv.appendSlice(arena, &.{ "--noproxy", "*" });
        return argv;
    }
};

/// Run curl for its stdout; its stderr (the error message under `-sS`) is
/// passed on.
fn captureCurl(arena: std.mem.Allocator, argv: []const []const u8, url: []const u8, max_bytes: u64, echo_errors: bool, report: *Report) ![]const u8 {
    report.* = .{ .url = url };
    const captured = platform.process.capture(try zArgv(arena, argv), arena, .{
        .max_bytes = @intCast(max_bytes),
        .inherit_env = true,
        .timeout_ms = 10 * 60_000,
    }) catch return error.CurlUnavailable;
    if (echo_errors and captured.stderr.len > 0) std.debug.print("{s}", .{captured.stderr});
    if (captured.exit_code != 0) return curlError(captured.exit_code, report);
    return captured.stdout;
}

/// curl's exit status as this module names it (curl(1), EXIT CODES).
fn curlError(code: i32, report: *Report) Error {
    report.curl_exit = code;
    return switch (code) {
        22 => error.HttpStatus,
        63 => error.TooLarge,
        // URL malformed, unsupported protocol (refused by --proto-redir)
        1, 3 => error.InvalidUrl,
        // resolve, connect, proxy, TLS and certificate failures
        5, 6, 7, 35, 51, 53, 54, 58, 59, 60, 77, 83, 90, 91, 97 => error.ConnectFailed,
        else => error.TransferFailed,
    };
}

fn zArgv(arena: std.mem.Allocator, argv: []const []const u8) ![]const ?[*:0]const u8 {
    const out = try arena.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |arg, i| out[i] = (try arena.dupeZ(u8, arg)).ptr;
    out[argv.len] = null;
    return out;
}

// ── release documents ────────────────────────────────────────────────────────

/// The `<tag>` of a `…/tag/<tag>` location, when it is a bare stable
/// `X.Y.Z` (the only form `release.yml` publishes).
pub fn tagFromLocation(location: []const u8) ?[]const u8 {
    const at = std.mem.lastIndexOf(u8, location, "/tag/") orelse return null;
    var rest = location[at + "/tag/".len ..];
    if (std.mem.indexOfAny(u8, rest, "?#")) |end| rest = rest[0..end];
    rest = std.mem.trimEnd(u8, rest, "/");
    if (!isStableVersion(rest)) return null;
    return rest;
}

/// `X.Y.Z`, three decimal numbers without leading zeros.
pub fn isStableVersion(text: []const u8) bool {
    var parts = std.mem.splitScalar(u8, text, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (count > 3 or part.len == 0 or part.len > 19) return false;
        if (part.len > 1 and part[0] == '0') return false;
        for (part) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return count == 3;
}

pub const Sums = struct {
    entries: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    pub fn get(self: Sums, name: []const u8) ?[]const u8 {
        return self.entries.get(name);
    }
};

pub const SumsError = error{ MalformedSums, DuplicateSum };

/// `sha256sum` output: `<64 lowercase hex>  <name>` (or ` *<name>`) per line.
pub fn parseSums(arena: std.mem.Allocator, bytes: []const u8) !Sums {
    var sums: Sums = .{};
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line.len < 67) return error.MalformedSums;
        const hex = line[0..64];
        for (hex) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return error.MalformedSums;
        if (line[64] != ' ' or (line[65] != ' ' and line[65] != '*')) return error.MalformedSums;
        const name = line[66..];
        if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\ \t") != null) return error.MalformedSums;
        const gop = try sums.entries.getOrPut(arena, name);
        if (gop.found_existing) return error.DuplicateSum;
        gop.value_ptr.* = hex;
    }
    return sums;
}

pub const Asset = struct { name: []const u8, sha256: []const u8 };

pub const Assets = struct {
    cli: Asset,
    /// Null when no SDK was asked for, or the release carries none for the
    /// target (`sdk_missing`).
    sdk: ?Asset,
    sdk_missing: bool = false,
};

pub const AssetError = error{ NoCliAsset, AmbiguousSdk };

/// The archive extension a target's release assets use.
pub fn archiveExtension(target_id: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, target_id, "windows") != null) ".zip" else ".tar.gz";
}

pub fn selectAssets(arena: std.mem.Allocator, sums: Sums, tag: []const u8, target_id: []const u8, want_sdk: bool) !Assets {
    const ext = archiveExtension(target_id);
    const cli_name = try std.fmt.allocPrint(arena, "metacodes-{s}-{s}{s}", .{ tag, target_id, ext });
    const cli_sum = sums.get(cli_name) orelse return error.NoCliAsset;
    var assets: Assets = .{ .cli = .{ .name = cli_name, .sha256 = cli_sum }, .sdk = null };
    if (!want_sdk) return assets;
    const suffix = try std.fmt.allocPrint(arena, "-{s}{s}", .{ target_id, ext });
    var it = sums.entries.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, name, "metask-agentcore-") or !std.mem.endsWith(u8, name, suffix)) continue;
        if (assets.sdk != null) return error.AmbiguousSdk;
        assets.sdk = .{ .name = name, .sha256 = entry.value_ptr.* };
    }
    assets.sdk_missing = assets.sdk == null;
    return assets;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "tagFromLocation takes a bare stable tag and nothing else" {
    try testing.expectEqualStrings("0.6.0", tagFromLocation("https://github.com/metask-ai/metacodes/releases/tag/0.6.0").?);
    try testing.expectEqualStrings("10.20.30", tagFromLocation("/releases/tag/10.20.30/").?);
    try testing.expectEqualStrings("1.2.3", tagFromLocation("https://m.example/r/tag/1.2.3?x=1").?);
    try testing.expect(tagFromLocation("https://github.com/metask-ai/metacodes/releases") == null);
    try testing.expect(tagFromLocation("https://x/releases/tag/v1.2.3") == null);
    try testing.expect(tagFromLocation("https://x/releases/tag/1.2.3-dev") == null);
    try testing.expect(tagFromLocation("https://x/releases/tag/01.2.3") == null);
    try testing.expect(tagFromLocation("https://x/releases/tag/1.2") == null);
    try testing.expect(tagFromLocation("https://x/releases/tag/1.2.3.4") == null);
    try testing.expect(tagFromLocation("https://x/releases/tag/../../1.2.3x") == null);
}

test "parseSums reads sha256sum output strictly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = "a" ** 64;
    const b = "0123456789abcdef" ** 4;
    const sums = try parseSums(arena, a ++ "  metacodes-1.0.0-aarch64-macos.tar.gz\n" ++ b ++ " *metacodes-1.0.0-SHA256SUMS\r\n\n");
    try testing.expectEqualStrings(a, sums.get("metacodes-1.0.0-aarch64-macos.tar.gz").?);
    try testing.expectEqualStrings(b, sums.get("metacodes-1.0.0-SHA256SUMS").?);
    try testing.expectError(error.DuplicateSum, parseSums(arena, a ++ "  x\n" ++ b ++ "  x\n"));
    try testing.expectError(error.MalformedSums, parseSums(arena, "A" ** 64 ++ "  x\n"));
    try testing.expectError(error.MalformedSums, parseSums(arena, a ++ " x\n"));
    try testing.expectError(error.MalformedSums, parseSums(arena, a ++ "  ../x\n"));
    try testing.expectError(error.MalformedSums, parseSums(arena, a[0..63] ++ "  x\n"));
    try testing.expectError(error.MalformedSums, parseSums(arena, a ++ "  \n"));
}

test "selectAssets: the target's archive, the one SDK, a missing or ambiguous SDK" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const h = "c" ** 64;
    const sums = try parseSums(arena, h ++ "  metacodes-1.0.0-aarch64-macos.tar.gz\n" ++
        h ++ "  metacodes-1.0.0-x86_64-windows-gnu.zip\n" ++
        h ++ "  metacodes-1.0.0-x86_64-linux-gnu.tar.gz\n" ++
        h ++ "  metask-agentcore-0.11.0-dev+9c2f68671198-aarch64-macos.tar.gz\n" ++
        h ++ "  metask-agentcore-0.11.0-dev+9c2f68671198-x86_64-windows-gnu.zip\n" ++
        h ++ "  metask-agentcore-0.11.0-x86_64-linux-gnu.tar.gz\n" ++
        h ++ "  metask-agentcore-0.12.0-x86_64-linux-gnu.tar.gz\n");
    const mac = try selectAssets(arena, sums, "1.0.0", "aarch64-macos", true);
    try testing.expectEqualStrings("metacodes-1.0.0-aarch64-macos.tar.gz", mac.cli.name);
    try testing.expectEqualStrings("metask-agentcore-0.11.0-dev+9c2f68671198-aarch64-macos.tar.gz", mac.sdk.?.name);
    const win = try selectAssets(arena, sums, "1.0.0", "x86_64-windows-gnu", true);
    try testing.expectEqualStrings("metacodes-1.0.0-x86_64-windows-gnu.zip", win.cli.name);
    try testing.expectEqualStrings("metask-agentcore-0.11.0-dev+9c2f68671198-x86_64-windows-gnu.zip", win.sdk.?.name);
    try testing.expect((try selectAssets(arena, sums, "1.0.0", "aarch64-macos", false)).sdk == null);
    try testing.expectError(error.AmbiguousSdk, selectAssets(arena, sums, "1.0.0", "x86_64-linux-gnu", true));
    try testing.expectError(error.NoCliAsset, selectAssets(arena, sums, "1.0.1", "aarch64-macos", true));

    const no_sdk = try parseSums(arena, h ++ "  metacodes-2.0.0-aarch64-macos.tar.gz\n");
    const without = try selectAssets(arena, no_sdk, "2.0.0", "aarch64-macos", true);
    try testing.expect(without.sdk == null and without.sdk_missing);
}

test "curl exit codes map to what the update reports" {
    var report: Report = .{};
    try testing.expectEqual(Error.HttpStatus, curlError(22, &report));
    try testing.expectEqual(@as(i32, 22), report.curl_exit);
    try testing.expectEqual(Error.ConnectFailed, curlError(6, &report));
    try testing.expectEqual(Error.ConnectFailed, curlError(60, &report));
    try testing.expectEqual(Error.TooLarge, curlError(63, &report));
    try testing.expectEqual(Error.InvalidUrl, curlError(1, &report));
    try testing.expectEqual(Error.TransferFailed, curlError(28, &report));
    try testing.expectEqual(Error.TransferFailed, curlError(56, &report));
}
