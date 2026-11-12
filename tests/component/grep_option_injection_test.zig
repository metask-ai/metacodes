//! L2 regression for #460: a Grep pattern must never reach ripgrep as an option.
//!
//! Defect: both Grep execution paths (the direct `execute` and the
//! artifact-capture `executeBody`, every rung of the retry ladder) appended
//! the model's `pattern` to ripgrep's argv as a standalone argument. A
//! pattern starting with `-` was parsed as a ripgrep flag — `--pre=<program>`
//! makes ripgrep launch a program for every searched file — while Grep is a
//! read-only tool that `accept_edits` auto-allows and `ShellPolicy.disabled`
//! keeps available. A read-only approval could start a subprocess.
//!
//! Fix: one argv builder for every path and rung. The pattern is only ever
//! the value of `--regexp=`, every model option value is bound to its flag in
//! one element (`--glob=…`), and the search path follows `--`.
//!
//! Crosses agent_loop → permission decision → tools dispatch → grep argv
//! builder → the repository-pinned ripgrep (vendor/ripgrep, digest-checked)
//! → the artifact store. Y is the disk: the matched lines a search really
//! returns (inline and read back from the published artifact), and a marker
//! file that a `--pre` program would create.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");
const pfs = @import("platform").fs;

const Decision = cc.permission.PermissionResult;
const ToolContext = cc.tool_context.ToolContext;
const artifact_store = cc.tool_result_artifact;

// ============================================================================
// The repository-pinned ripgrep
// ============================================================================

/// Points `ripgrepPath` at the manifest-pinned binary build.zig hands this
/// process, after checking its digest. Returns false on a target that has no
/// vendored binary; a missing variable is a wiring failure, not a skip.
fn usePinnedRipgrep(path_buf: *[std.fs.max_path_bytes:0]u8) !bool {
    const raw = std.c.getenv("METACODES_TEST_PINNED_RG") orelse return error.PinnedRipgrepNotWired;
    const path = std.mem.span(raw);
    if (std.mem.eql(u8, path, "unavailable")) return false;
    const want = std.mem.span(std.c.getenv("METACODES_TEST_PINNED_RG_SHA256") orelse return error.PinnedRipgrepNotWired);
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z = path_buf[0..path.len :0];

    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (fd < 0) return error.PinnedRipgrepMissing;
    defer pfs.close(fd);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &chunk);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        hasher.update(chunk[0..@intCast(n)]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const got = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(want, &got);

    cc.util_toolchain.test_ripgrep_path_override = path_z;
    return true;
}

fn restoreRipgrep() void {
    cc.util_toolchain.test_ripgrep_path_override = null;
}

// ============================================================================
// Fixture
// ============================================================================

const Fixture = struct {
    dir_buf: [512]u8 = undefined,
    dir: [:0]const u8 = undefined,
    notes_buf: [640]u8 = undefined,
    notes: [:0]const u8 = undefined,
    sub_buf: [640]u8 = undefined,
    sub: [:0]const u8 = undefined,
    code_buf: [700]u8 = undefined,
    code: [:0]const u8 = undefined,
    script_buf: [640]u8 = undefined,
    script: [:0]const u8 = undefined,
    marker_buf: [640]u8 = undefined,
    marker: [:0]const u8 = undefined,
    /// `--pre=<script>`: the pattern that used to run the script.
    pre_pattern_buf: [700]u8 = undefined,
    pre_pattern: []const u8 = undefined,

    /// Fixture tree:
    ///   notes.txt     1 alpha / 2 --pre=<script> / 3 -v marker line /
    ///                 4 Beta Gamma / 5 beta lower
    ///   sub/code.zig  1 const x = 1; / 2 // --pre=<script> in zig
    ///   pre.sh        touches `pwned`, then prints its input (the --pre shape)
    fn init(self: *Fixture, name: []const u8) !void {
        self.dir = cc.util_fs.testing.uniqueDir(&self.dir_buf, name);
        _ = pfs.mkdir(self.dir.ptr, 0o755);
        self.notes = try std.fmt.bufPrintZ(&self.notes_buf, "{s}/notes.txt", .{self.dir});
        self.sub = try std.fmt.bufPrintZ(&self.sub_buf, "{s}/sub", .{self.dir});
        _ = pfs.mkdir(self.sub.ptr, 0o755);
        self.code = try std.fmt.bufPrintZ(&self.code_buf, "{s}/code.zig", .{self.sub});
        self.script = try std.fmt.bufPrintZ(&self.script_buf, "{s}/pre.sh", .{self.dir});
        self.marker = try std.fmt.bufPrintZ(&self.marker_buf, "{s}/pwned", .{self.dir});
        self.pre_pattern = try std.fmt.bufPrint(&self.pre_pattern_buf, "--pre={s}", .{self.script});

        var text_buf: [2048]u8 = undefined;
        try writeFile(self.notes, try std.fmt.bufPrint(&text_buf, "alpha\n{s}\n-v marker line\nBeta Gamma\nbeta lower\n", .{self.pre_pattern}), 0o644);
        try writeFile(self.code, try std.fmt.bufPrint(&text_buf, "const x = 1;\n// {s} in zig\n", .{self.pre_pattern}), 0o644);
        try writeFile(self.script, try std.fmt.bufPrint(&text_buf, "#!/bin/sh\ntouch '{s}'\nexec cat \"$1\"\n", .{self.marker}), 0o755);
    }

    fn deinit(self: *Fixture) void {
        cc.util_fs.testing.rmrfBestEffort(self.dir);
    }

    fn markerExists(self: *const Fixture) bool {
        return pfs.exists(self.marker.ptr);
    }
};

fn writeFile(path: [:0]const u8, content: []const u8, mode: u32) !void {
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @intCast(mode));
    if (fd < 0) return error.CreateFailed;
    defer pfs.close(fd);
    if (pfs.write(fd, content) != @as(isize, @intCast(content.len))) return error.WriteFailed;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// JSON-encodes a Grep call; `extra` is spliced in verbatim (`,"k":v…`).
fn grepArgs(a: std.mem.Allocator, pattern: []const u8, path: []const u8, extra: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"pattern\":{f},\"path\":{f}{s}}}", .{
        std.json.fmt(pattern, .{}),
        std.json.fmt(path, .{}),
        extra,
    });
}

/// Which search path a case drives.
const Path = enum {
    /// `execute`: no artifact store, the bytes come back inline.
    direct,
    /// `executeBody` with an artifact store and a one-byte result budget: the
    /// result is captured, sealed, published, and read back from the store.
    artifact,
};

/// Runs Grep down `path` and returns the bytes the search produced.
fn runGrep(a: std.mem.Allocator, path: Path, root: []const u8, args: []const u8) ![]u8 {
    switch (path) {
        .direct => {
            const ctx = ToolContext.simple(a);
            return cc.grep.execute(&ctx, args);
        },
        .artifact => {
            var ctx = ToolContext{ .allocator = a, .artifact_root = root };
            ctx.result_budget = .{ .per_result_bytes = 1, .per_turn_bytes = 1 };
            var body = try cc.grep.executeBody(&ctx, args);
            defer body.deinit(a);
            return readBackArtifact(a, root, &body);
        },
    }
}

/// Publishes a sealed Grep body and reads the artifact from the store.
fn readBackArtifact(a: std.mem.Allocator, root: []const u8, body: *cc.tool_context.ToolResultBody) ![]u8 {
    const sealed = switch (body.*) {
        .sealed => |*value| &value.spool,
        // Only an empty result fits the one-byte budget inline.
        .@"inline" => |value| {
            try std.testing.expectEqual(@as(usize, 0), value.bytes.len);
            return a.dupe(u8, value.bytes);
        },
        else => return error.ExpectedSealedArtifact,
    };
    const completed = try sealed.publish();
    var chunk = try artifact_store.readChunk(a, root, completed.receipt.id(), 0, artifact_store.MAX_READ_BYTES);
    defer chunk.deinit();
    try std.testing.expect(chunk.next_offset == null);
    return a.dupe(u8, chunk.bytes);
}

fn artifactRoot(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buf);
    return buf[0..len];
}

// ============================================================================
// Patterns that begin with `-`: literal matches, no preprocessor
// ============================================================================

test "L2 Grep #460: a pattern beginning with - matches literally on both paths and runs no --pre program" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // the --pre probe is a POSIX script
    var rg_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (!try usePinnedRipgrep(&rg_buf)) return error.SkipZigTest;
    defer restoreRipgrep();
    const a = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init("cc-zig-grep-460-dash");
    defer fx.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try artifactRoot(&tmp, &root_buf);

    var line2_buf: [800]u8 = undefined;
    const line2 = try std.fmt.bufPrint(&line2_buf, "2:{s}", .{fx.pre_pattern});
    for ([_]Path{ .direct, .artifact }) |path| {
        errdefer std.debug.print("path={s}\n", .{@tagName(path)});

        // Single file, content mode: the literal line and its number.
        {
            const args = try grepArgs(a, fx.pre_pattern, fx.notes, ",\"output_mode\":\"content\"");
            defer a.free(args);
            const out = try runGrep(a, path, root, args);
            defer a.free(out);
            errdefer std.debug.print("out={s} marker={}\n", .{ out, fx.markerExists() });
            // Checked first: before #460 this search ran pre.sh.
            try std.testing.expect(!fx.markerExists());
            try std.testing.expectEqualStrings(line2, std.mem.trimEnd(u8, out, "\n"));
        }
        // Directory, files_with_matches: exactly the two files holding the text.
        {
            const args = try grepArgs(a, fx.pre_pattern, fx.dir, "");
            defer a.free(args);
            const out = try runGrep(a, path, root, args);
            defer a.free(out);
            errdefer std.debug.print("out={s}\n", .{out});
            try std.testing.expect(contains(out, "notes.txt"));
            try std.testing.expect(contains(out, "code.zig"));
            try std.testing.expect(!contains(out, "pre.sh"));
            try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, std.mem.trimEnd(u8, out, "\n"), "\n") + 1);
        }
        // A short flag as the pattern: `-v` is a search for "-v", not --invert-match.
        {
            const args = try grepArgs(a, "-v", fx.notes, ",\"output_mode\":\"content\"");
            defer a.free(args);
            const out = try runGrep(a, path, root, args);
            defer a.free(out);
            errdefer std.debug.print("out={s}\n", .{out});
            try std.testing.expectEqualStrings("3:-v marker line", std.mem.trimEnd(u8, out, "\n"));
        }
        // The retry ladder: `--pre=<script>(` is not a valid regex, so the
        // literal (-F) rung answers — still with the pattern as a pattern.
        {
            var broken_buf: [800]u8 = undefined;
            const broken = try std.fmt.bufPrint(&broken_buf, "{s}(", .{fx.pre_pattern});
            var file_buf: [700]u8 = undefined;
            const file = try std.fmt.bufPrintZ(&file_buf, "{s}/paren.txt", .{fx.dir});
            var text_buf: [800]u8 = undefined;
            try writeFile(file, try std.fmt.bufPrint(&text_buf, "x\ncall {s}) here\n", .{broken}), 0o644);
            defer pfs.unlinkPath(file.ptr) catch {};
            const args = try grepArgs(a, broken, file, ",\"output_mode\":\"content\"");
            defer a.free(args);
            const out = try runGrep(a, path, root, args);
            defer a.free(out);
            errdefer std.debug.print("out={s}\n", .{out});
            try std.testing.expect(contains(out, "FIXED-STRING"));
            var want_buf: [900]u8 = undefined;
            try std.testing.expect(contains(out, try std.fmt.bufPrint(&want_buf, "2:call {s}) here", .{broken})));
        }
        // Option values that start with `-` stay values too: a glob naming a
        // file that itself begins with `-`.
        {
            var file_buf: [700]u8 = undefined;
            const file = try std.fmt.bufPrintZ(&file_buf, "{s}/-dash.txt", .{fx.dir});
            try writeFile(file, "alpha\nalpha again\n", 0o644);
            defer pfs.unlinkPath(file.ptr) catch {};
            const args = try grepArgs(a, "alpha", fx.dir, ",\"glob\":\"-*.txt\",\"output_mode\":\"count\"");
            defer a.free(args);
            const out = try runGrep(a, path, root, args);
            defer a.free(out);
            errdefer std.debug.print("out={s}\n", .{out});
            try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, out, "\n"), "/-dash.txt:2"));
            try std.testing.expect(!contains(out, "notes.txt"));
        }
        try std.testing.expect(!fx.markerExists());
    }
}

test "L2 Grep #460: a recovered artifact is searched for a leading-dash pattern without a --pre program" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // the --pre probe is a POSIX script
    var rg_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (!try usePinnedRipgrep(&rg_buf)) return error.SkipZigTest;
    defer restoreRipgrep();
    const a = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init("cc-zig-grep-460-artifact-id");
    defer fx.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try artifactRoot(&tmp, &root_buf);

    var payload_buf: [1024]u8 = undefined;
    const payload = try std.fmt.bufPrint(&payload_buf, "ok one\n{s}\nok three\n", .{fx.pre_pattern});
    const receipt = try artifact_store.persist(a, root, payload);
    const args = try std.fmt.allocPrint(a, "{{\"pattern\":{f},\"artifact_id\":\"{s}\",\"output_mode\":\"content\"}}", .{
        std.json.fmt(fx.pre_pattern, .{}),
        receipt.id(),
    });
    defer a.free(args);
    var ctx = ToolContext{ .allocator = a, .artifact_root = root };
    var body = try cc.grep.executeBody(&ctx, args);
    defer body.deinit(a);
    var rendered = try body.render(a);
    defer rendered.deinit(a);
    var want_buf: [800]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&want_buf, "2:{s}", .{fx.pre_pattern}),
        std.mem.trimEnd(u8, rendered.bytes, "\n"),
    );
    try std.testing.expect(!contains(rendered.bytes, root));
    try std.testing.expect(!fx.markerExists());
}

// ============================================================================
// Ordinary searches keep their meaning on both paths
// ============================================================================

test "L2 Grep #460: regex, case folding, file filters and line numbers are unchanged on both paths" {
    var rg_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (!try usePinnedRipgrep(&rg_buf)) return error.SkipZigTest;
    defer restoreRipgrep();
    const a = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init("cc-zig-grep-460-ordinary");
    defer fx.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try artifactRoot(&tmp, &root_buf);

    const Case = struct { pattern: []const u8, target: enum { notes, dir }, extra: []const u8, want: []const []const u8, absent: []const []const u8 = &.{} };
    const cases = [_]Case{
        // Regex over a single file: content and line numbers.
        .{ .pattern = "^a[a-z]+a$", .target = .notes, .extra = ",\"output_mode\":\"content\"", .want = &.{"1:alpha"} },
        // Case-sensitive by default; -i folds.
        .{ .pattern = "beta", .target = .notes, .extra = ",\"output_mode\":\"content\"", .want = &.{"5:beta lower"} },
        .{ .pattern = "beta", .target = .notes, .extra = ",\"output_mode\":\"content\",\"-i\":true", .want = &.{ "4:Beta Gamma", "5:beta lower" } },
        // Line numbers can be turned off.
        .{ .pattern = "Gamma", .target = .notes, .extra = ",\"output_mode\":\"content\",\"-n\":false", .want = &.{"Beta Gamma"} },
        // Context lines.
        .{ .pattern = "Gamma", .target = .notes, .extra = ",\"output_mode\":\"content\",\"-B\":\"1\",\"-A\":\"1\"", .want = &.{ "3--v marker line", "4:Beta Gamma", "5-beta lower" } },
        .{ .pattern = "Gamma", .target = .notes, .extra = ",\"output_mode\":\"content\",\"-C\":\"1\"", .want = &.{ "3--v marker line", "4:Beta Gamma", "5-beta lower" } },
        // Directory searches: which files matched.
        .{ .pattern = "pre=", .target = .dir, .extra = "", .want = &.{ "notes.txt", "code.zig" }, .absent = &.{"pre.sh"} },
        .{ .pattern = "pre=", .target = .dir, .extra = ",\"glob\":\"*.zig\"", .want = &.{"code.zig"} },
        .{ .pattern = "pre=", .target = .dir, .extra = ",\"type\":\"zig\"", .want = &.{"code.zig"} },
        .{ .pattern = "x = 1", .target = .dir, .extra = ",\"output_mode\":\"content\",\"glob\":\"*.zig\"", .want = &.{"code.zig:1:const x = 1;"} },
        // Count.
        .{ .pattern = "(?i)beta", .target = .notes, .extra = ",\"output_mode\":\"count\"", .want = &.{"2"} },
    };
    for ([_]Path{ .direct, .artifact }) |path| {
        for (cases) |case| {
            const target: []const u8 = if (case.target == .notes) fx.notes else fx.dir;
            const args = try grepArgs(a, case.pattern, target, case.extra);
            defer a.free(args);
            const out = try runGrep(a, path, root, args);
            defer a.free(out);
            errdefer std.debug.print("path={s} args={s}\nout={s}\n", .{ @tagName(path), args, out });
            // Exactly the wanted lines, in order.
            var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');
            var seen: usize = 0;
            while (lines.next()) |line| : (seen += 1) {
                try std.testing.expect(seen < case.want.len);
                if (case.target == .dir) {
                    // Paths print under the searched directory, in ripgrep's
                    // (unspecified) walk order: each line is one wanted entry.
                    var matched = false;
                    for (case.want) |want| matched = matched or std.mem.endsWith(u8, line, want);
                    try std.testing.expect(matched);
                } else {
                    try std.testing.expectEqualStrings(case.want[seen], line);
                }
            }
            for (case.want) |want| try std.testing.expect(contains(out, want));
            try std.testing.expectEqual(case.want.len, seen);
            for (case.absent) |name| try std.testing.expect(!contains(out, name));
        }
    }
}

// ============================================================================
// Permissions: Grep stays auto-allowed, Bash still asks
// ============================================================================

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_end\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const ToolCall = struct { name: []const u8, args: []const u8 };

/// One assistant message with one tool_use per call (ids `tu_0`, `tu_1`, …).
fn toolUseMessage(a: std.mem.Allocator, calls: []const ToolCall) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_tools\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n");
    for (calls, 0..) |call, i| {
        try w.print("data: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_{d}\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n", .{ i, i, call.name });
        try w.print("data: {{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{f}}}}}\n\n", .{ i, std.json.fmt(call.args, .{}) });
        try w.print("data: {{\"type\":\"content_block_stop\",\"index\":{d}}}\n\n", .{i});
    }
    try w.writeAll("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n");
    try w.writeAll("data: {\"type\":\"message_stop\"}\n\n");
    return out.toOwnedSlice();
}

/// Every tool_result the loop emits, keyed by tool_use id.
const ToolResults = struct {
    allocator: std.mem.Allocator,
    ids: std.ArrayList([]u8) = .empty,
    contents: std.ArrayList([]u8) = .empty,

    fn deinit(self: *ToolResults) void {
        for (self.ids.items) |id| self.allocator.free(id);
        for (self.contents.items) |content| self.allocator.free(content);
        self.ids.deinit(self.allocator);
        self.contents.deinit(self.allocator);
    }

    fn backend(self: *ToolResults) cc.ui_backend.UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emit, .poll = poll };
    }

    fn emit(raw: *anyopaque, _: cc.session_id.SessionId, event: cc.ui_event.CoreEvent) void {
        const self: *ToolResults = @ptrCast(@alignCast(raw));
        switch (event) {
            .tool_result => |result| {
                const id = self.allocator.dupe(u8, result.id) catch return;
                const content = self.allocator.dupe(u8, result.content) catch {
                    self.allocator.free(id);
                    return;
                };
                self.ids.append(self.allocator, id) catch {
                    self.allocator.free(id);
                    self.allocator.free(content);
                    return;
                };
                self.contents.append(self.allocator, content) catch {
                    self.allocator.free(self.ids.pop().?);
                    self.allocator.free(content);
                };
            },
            else => {},
        }
    }

    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }

    fn get(self: *const ToolResults, index: usize) ![]const u8 {
        var id_buf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "tu_{d}", .{index});
        for (self.ids.items, self.contents.items) |seen, content| {
            if (std.mem.eql(u8, seen, id)) return content;
        }
        return error.MissingToolResult;
    }
};

test "L2 Grep #460: accept_edits auto-allows Grep and a denied Bash request has no side effect" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // the --pre probe is a POSIX script
    var rg_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (!try usePinnedRipgrep(&rg_buf)) return error.SkipZigTest;
    defer restoreRipgrep();
    const a = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init("cc-zig-grep-460-accept-edits");
    defer fx.deinit();

    // The verdicts themselves: Grep (normal and leading-dash) allows, running
    // the same program through Bash asks.
    const permission_probe = cc.permission.createContext(.accept_edits, a);
    const normal_args = try grepArgs(a, "alpha", fx.notes, ",\"output_mode\":\"content\"");
    defer a.free(normal_args);
    const dash_args = try grepArgs(a, fx.pre_pattern, fx.notes, ",\"output_mode\":\"content\"");
    defer a.free(dash_args);
    try std.testing.expectEqual(Decision.allow, cc.permission.checkPermission(&permission_probe, "Grep", normal_args));
    try std.testing.expectEqual(Decision.allow, cc.permission.checkPermission(&permission_probe, "Grep", dash_args));
    var command_buf: [1400]u8 = undefined;
    const command = try std.fmt.bufPrint(&command_buf, "{s} {s}", .{ fx.script, fx.notes });
    const bash_args = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(.{ .command = command }, .{})});
    defer a.free(bash_args);
    try std.testing.expectEqual(Decision.ask, cc.permission.checkPermission(&permission_probe, "Bash", bash_args));

    // The real loop: both Grep calls run unprompted and return their literal
    // matches; the Bash request is denied (no interactive prompt answers
    // "deny") and its program never runs. Neither leaves the marker.
    const calls = [_]ToolCall{
        .{ .name = "Grep", .args = normal_args },
        .{ .name = "Grep", .args = dash_args },
        .{ .name = "Bash", .args = bash_args },
    };
    const first = try toolUseMessage(a, &calls);
    defer a.free(first);
    const responses = [_][]const u8{ first, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&responses, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var conversation = cc.conversation.Conversation.init(a);
    defer conversation.deinit();
    try conversation.appendText(.user, "search the notes");
    var jobs = try cc.job_registry.JobRegistry.init(a);
    defer jobs.deinit();

    var permission = cc.permission.createContext(.accept_edits, a);
    permission.no_interactive_prompt = true;
    var results = ToolResults{ .allocator = a };
    defer results.deinit();
    const backend = results.backend();
    const result = try cc.agent_loop.run(&conversation, client.provider(), &.{}, &permission, .{
        .max_turns = 4,
        .emit_tool_cards = true,
        .colorize = false,
        .jobs = &jobs,
        .cwd_abs = fx.dir,
    }, &backend, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);

    errdefer std.debug.print("grep={s}\ngrep-dash={s}\nbash={s}\n", .{
        results.get(0) catch "(none)",
        results.get(1) catch "(none)",
        results.get(2) catch "(none)",
    });
    try std.testing.expect(!contains(try results.get(0), "permission_denied"));
    try std.testing.expect(contains(try results.get(0), "1:alpha"));
    try std.testing.expect(!contains(try results.get(1), "permission_denied"));
    var line2_buf: [800]u8 = undefined;
    try std.testing.expect(contains(try results.get(1), try std.fmt.bufPrint(&line2_buf, "2:{s}", .{fx.pre_pattern})));
    try std.testing.expect(contains(try results.get(2), "permission_denied"));
    try std.testing.expect(!fx.markerExists());
}

test "L2 Grep #460: under ShellPolicy.disabled Grep stays available and still runs no program" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // the --pre probe is a POSIX script
    var rg_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (!try usePinnedRipgrep(&rg_buf)) return error.SkipZigTest;
    defer restoreRipgrep();
    const a = std.testing.allocator;
    var fx: Fixture = .{};
    try fx.init("cc-zig-grep-460-shell-disabled");
    defer fx.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try artifactRoot(&tmp, &root_buf);

    var policy = try cc.workspace_policy.WorkspacePolicy.init(a, .{ .root = fx.dir, .shell = .disabled });
    defer policy.deinit();
    try std.testing.expect(!policy.allowsTool("Bash"));
    try std.testing.expect(policy.allowsTool("Grep"));

    // Dispatched the way AgentCore runs it: through the tool table, with the
    // session's artifact store.
    var ctx = ToolContext{ .allocator = a, .artifact_root = root, .cwd_abs = policy.root };
    const args = try grepArgs(a, fx.pre_pattern, fx.dir, ",\"output_mode\":\"content\"");
    defer a.free(args);
    var outcome = try cc.tools.dispatch(&ctx, "Grep", args);
    defer outcome.deinit(a);
    const body = switch (outcome) {
        .ok => |*value| value,
        else => return error.GrepDispatchFailed,
    };
    var rendered = try body.render(a);
    defer rendered.deinit(a);
    errdefer std.debug.print("out={s}\n", .{rendered.bytes});
    var want_buf: [900]u8 = undefined;
    try std.testing.expect(contains(rendered.bytes, try std.fmt.bufPrint(&want_buf, "notes.txt:2:{s}", .{fx.pre_pattern})));
    try std.testing.expect(contains(rendered.bytes, "code.zig:2:"));
    try std.testing.expect(!fx.markerExists());
}
