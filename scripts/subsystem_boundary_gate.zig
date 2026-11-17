//! Enforce the subsystem import boundaries #16, #405 and #448 rely on.
//!
//! `zig build test:provider` and `test:picker` compile each subsystem from a
//! narrow root and their doc comments claim that a dependency on the transport,
//! the TUI, or `App` would stop them compiling. It would not: the test module's
//! root is `src/`, so *any* file under it is importable, and the only named
//! module either subsystem needs is `platform`. Both gates were decorative —
//! adding `src/client.zig` to the provider root compiles cleanly.
//!
//! The boundary is a source-level rule, so this checks it at the source level:
//! every `@import` in each subsystem must be on that subsystem's allowlist.
//! Widening a list is then a deliberate, reviewable act rather than something
//! that happens by accident because the module graph allowed it.
//!
//! The check follows the closure, not just the first hop. A file a subsystem
//! may reach is held to the same lists, test blocks included, because an
//! isolation root compiles every test in every file it reaches. Checking only
//! the subsystem's own files let both roots compile the whole application:
//! the approved `util/pricing.zig` began importing `api/model_name.zig`, whose
//! test imported the system prompt and, through it, the tool set. A file that
//! belongs to another subsystem listed here is entered but not followed; that
//! subsystem's own entry checks its closure.
//!
//! The fourth subsystem, metacodes-core (#448), is checked the other way
//! round. The library is most of `src/`, so an allowlist would only restate
//! it; what it must not reach is the application side: the REPL and TUI, the
//! web and daemon hosts, `app/`, and the application roots. `refAllDecls` in
//! `src/lib.zig` cannot prove that. Analysis is lazy, so an import in a
//! function body or a test block that the library never reaches is never
//! compiled. This follows every `@import` from `src/lib.zig`, wherever it
//! sits, and fails on each edge into the application side that `LIBRARY`'s
//! baseline does not name. The baseline may only shrink: an entry whose edge
//! is gone fails too, and no file under `src/core/` may have one at all.
//!
//! The last rule is a ratchet for #445: `serve` and `--web` are to become
//! transports over `src/core/session_host.zig`, so no file under `src/daemon/`
//! or `src/web/` may drive the kernel by importing `src/core/agent_loop.zig`.
//! `HOST_KERNEL`'s baseline names the files that still do; like the library's,
//! it may only shrink.

const std = @import("std");

const Subsystem = struct {
    /// What a violation calls it.
    name: []const u8,
    /// Directory that defines the subsystem, relative to the repository root.
    /// Its files (see `recursive` and `only`) are by definition part of it.
    dir: []const u8,
    /// Scan nested directories too.
    recursive: bool,
    /// Only these files, when non-empty.
    only: []const []const u8 = &.{},
    /// Named modules the subsystem, and every file it reaches, may depend on.
    modules: []const []const u8,
    /// Files *outside* the subsystem it may reach, directly or through another
    /// file on this list, as repository-relative paths. Resolved from the
    /// importing file, so `../types.zig` from `src/provider/ids.zig` and from
    /// `src/provider/profiles/metask.zig` are both checked as the one path
    /// they actually name.
    reaches: []const []const u8,
};

const SUBSYSTEMS = [_]Subsystem{
    .{
        // The provider kernel: `std`, `types.zig`, the approved leaf
        // utilities, and the portable platform layer. Not the transport, not
        // a UI.
        .name = "provider kernel",
        .dir = "src/provider",
        .recursive = true,
        .modules = &.{ "std", "builtin", "platform" },
        .reaches = &.{
            "src/types.zig",
            "src/util/model.zig",
            "src/util/pricing.zig",
            "src/util/fs.zig",
            "src/util/file_lock.zig",
            "src/util/json_merge.zig",
            "src/util/json.zig",
            // Reached through the files above.
            "src/api/model_name.zig",
            "src/util/log.zig",
            "src/util/time.zig",
            "src/core/read_state.zig",
            "src/tools/test_tmp.zig",
        },
    },
    .{
        // The picker is a *client* of the control plane: the provider kernel
        // and the terminal theme, and nothing else. Not `App`, not a client.
        .name = "model picker",
        .dir = "src/repl",
        .recursive = false,
        .only = &.{ "model_picker.zig", "model_picker_view.zig" },
        .modules = &.{ "std", "platform" },
        .reaches = &.{
            "src/repl/tui/ansi.zig",
            "src/repl/tui/theme.zig",
            "src/repl/tui/term.zig",
            "src/provider/ids.zig",
            "src/provider/offer.zig",
            "src/provider/controls.zig",
            "src/provider/selection.zig",
            "src/provider/control_plane.zig",
        },
    },
    .{
        // The shared MCP client (#405): protocol, transports, catalog. Not the
        // CLI, not AgentCore, not the AgentLoop. `registry_bridge.zig` and
        // `tool_invocation.zig` are its integration with the tool system, and
        // sit outside; `config.zig` and `launch.zig` are the CLI's imports.
        .name = "MCP client",
        .dir = "src/mcp",
        .recursive = false,
        .only = &.{
            "canonical.zig",
            "json_admission.zig",
            "wire.zig",
            "era_modern.zig",
            "era_classic.zig",
            "negotiation.zig",
            "schema.zig",
            "result_stream.zig",
            "protocol.zig",
            "client.zig",
            "transport.zig",
            "transport_stdio.zig",
            "transport_http.zig",
            "transport_sse.zig",
            "host_transport.zig",
            "runtime.zig",
            "instance_pool.zig",
            "catalog.zig",
            "conformance.zig",
            "test_support.zig",
        },
        .modules = &.{ "std", "builtin", "platform" },
        .reaches = &.{
            "src/api/auth_header.zig",
            "src/api/capability_activation.zig",
            "src/api/dialect.zig",
            "src/api/dialects/bedrock.zig",
            "src/api/dialects/claude.zig",
            "src/api/dialects/deepseek.zig",
            "src/api/dialects/gemini.zig",
            "src/api/dialects/glm.zig",
            "src/api/dialects/kimi.zig",
            "src/api/dialects/minimax.zig",
            "src/api/dialects/mistral.zig",
            "src/api/dialects/openai.zig",
            "src/api/dialects/openai_compat.zig",
            "src/api/dialects/openrouter.zig",
            "src/api/dialects/qwen.zig",
            "src/api/dialects/registry.zig",
            "src/api/error_class.zig",
            "src/api/http_connection.zig",
            "src/api/http_status.zig",
            "src/api/image_capability.zig",
            "src/api/last_error.zig",
            "src/api/model_adapter.zig",
            "src/api/model_error.zig",
            "src/api/model_name.zig",
            "src/api/provider.zig",
            "src/api/request.zig",
            "src/api/request_overrides.zig",
            "src/api/stream.zig",
            "src/core/auth.zig",
            "src/core/execution_effect.zig",
            "src/core/recorder.zig",
            "src/core/result_budget.zig",
            "src/core/tool_error.zig",
            "src/core/tool_result.zig",
            "src/core/tool_result_artifact.zig",
            "src/json.zig",
            "src/mcp/config.zig",
            "src/mcp/oauth.zig",
            "src/mcp/url.zig",
            "src/provider/controls.zig",
            "src/provider/credential.zig",
            "src/provider/ids.zig",
            "src/provider/oauth.zig",
            "src/provider/offer.zig",
            "src/provider/profile.zig",
            "src/provider/vendor.zig",
            "src/tools/observation.zig",
            "src/tools/test_tmp.zig",
            "src/types.zig",
            "src/util/abort.zig",
            "src/util/fs.zig",
            "src/util/json.zig",
            "src/util/log.zig",
            "src/util/time.zig",
            "src/util/toml.zig",
            "src/version.zig",
        },
    },
};

/// An import from a library file into the application side.
const Edge = struct {
    from: []const u8,
    to: []const u8,
};

/// A library whose import closure, followed from `root`, must not reach the
/// application side.
const Library = struct {
    name: []const u8,
    /// The library's root file, relative to the repository root.
    root: []const u8,
    /// The application side: directories (ending in `/`) and files.
    app_side: []const []const u8,
    /// Directories (ending in `/`) whose files may have no baseline entry.
    unbaselined: []const []const u8,
    /// The edges that exist today. Delete an entry when its edge goes (a
    /// stale entry fails the gate); never add one.
    baseline: []const Edge,
};

const LIBRARY = Library{
    .name = "metacodes-core",
    .root = "src/lib.zig",
    .app_side = &.{
        "src/repl/",
        "src/web/",
        "src/daemon/",
        "src/app/",
        "src/main.zig",
        "src/app.zig",
        "src/session_service.zig",
        "src/session_intent.zig",
    },
    .unbaselined = &.{"src/core/"},
    .baseline = &.{
        // Re-exported as `config` and `doctor`: consumers reach them by those
        // names, so moving the files out of `app/` is its own change.
        .{ .from = "src/lib.zig", .to = "src/app/config.zig" },
        .{ .from = "src/lib.zig", .to = "src/app/doctor.zig" },
        .{ .from = "src/version_info.zig", .to = "src/app/config.zig" },
        // The out-of-process teammate main loop drives a whole `App`. The
        // library reaches it from `swarm/context.zig` inside function bodies
        // only, so lazy analysis never compiles it into the library.
        .{ .from = "src/swarm/teammate_process.zig", .to = "src/app.zig" },
    },
};

comptime {
    if (baselineError(LIBRARY)) |message| @compileError(message);
    if (ratchetError(HOST_KERNEL)) |message| @compileError(message);
}

/// A file that no file under `dirs` may import, except the `baseline` files
/// that still do.
const Ratchet = struct {
    name: []const u8,
    /// Directories (ending in `/`) whose files, nested ones included, are held
    /// to the rule.
    dirs: []const []const u8,
    /// The forbidden import, relative to the repository root.
    target: []const u8,
    /// The files that import `target` today. Delete an entry when its import
    /// goes (a stale entry fails the gate); never add one.
    baseline: []const []const u8,
};

/// #445: the bundled hosts reach the kernel through the one SessionHost, not
/// by running the AgentLoop themselves.
const HOST_KERNEL = Ratchet{
    .name = "single session host (#445)",
    .dirs = &.{ "src/daemon/", "src/web/" },
    .target = "src/core/agent_loop.zig",
    .baseline = &.{
        // The daemon's per-session driver runs an `App` Run itself.
        "src/daemon/app_driver.zig",
        // `--web`'s driver loop, which `app_driver.zig` mirrors.
        "src/web/session.zig",
    },
};

/// Why `ratchet` is malformed, or null when it is not.
fn ratchetError(ratchet: Ratchet) ?[]const u8 {
    for (ratchet.dirs) |dir| {
        if (!std.mem.endsWith(u8, dir, "/")) return "a ratchet directory must end in `/`";
    }
    for (ratchet.baseline, 0..) |file, index| {
        if (!inRatchet(ratchet, file)) return "a ratchet baseline file must be under one of its directories";
        if (ratchetIndex(ratchet, file).? != index) return "a ratchet baseline file is listed twice";
    }
    return null;
}

fn inRatchet(ratchet: Ratchet, path: []const u8) bool {
    for (ratchet.dirs) |dir| {
        if (std.mem.startsWith(u8, path, dir)) return true;
    }
    return false;
}

fn ratchetIndex(ratchet: Ratchet, path: []const u8) ?usize {
    for (ratchet.baseline, 0..) |file, index| {
        if (std.mem.eql(u8, file, path)) return index;
    }
    return null;
}

/// Why `library`'s baseline is malformed, or null when it is not.
fn baselineError(library: Library) ?[]const u8 {
    for (library.baseline, 0..) |edge, index| {
        if (!isAppSide(library, edge.to)) return "a baseline edge must end on the application side";
        if (isAppSide(library, edge.from)) return "a baseline edge must start in the library";
        for (library.unbaselined) |dir| {
            if (std.mem.startsWith(u8, edge.from, dir)) return "a baseline edge starts in a directory that may have none";
        }
        if (baselineIndex(library, edge.from, edge.to).? != index) return "a baseline edge is listed twice";
    }
    return null;
}

fn isAppSide(library: Library, path: []const u8) bool {
    for (library.app_side) |entry| {
        if (std.mem.endsWith(u8, entry, "/")) {
            if (std.mem.startsWith(u8, path, entry)) return true;
        } else if (std.mem.eql(u8, path, entry)) return true;
    }
    return false;
}

fn baselineIndex(library: Library, from: []const u8, to: []const u8) ?usize {
    for (library.baseline, 0..) |edge, index| {
        if (std.mem.eql(u8, edge.from, from) and std.mem.eql(u8, edge.to, to)) return index;
    }
    return null;
}

/// Resolve `target` against the directory of `from`, collapsing `..`.
/// Returns null for a named module (no `.zig` suffix).
fn resolve(buffer: []u8, from: []const u8, target: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, target, ".zig")) return null;
    const dir = std.fs.path.dirnamePosix(from) orelse "";
    var len: usize = 0;
    var segments = std.mem.splitScalar(u8, dir, '/');
    var stack: [32][]const u8 = undefined;
    var depth: usize = 0;
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (depth == stack.len) return null;
        stack[depth] = segment;
        depth += 1;
    }
    var parts = std.mem.splitScalar(u8, target, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (depth == 0) return null;
            depth -= 1;
            continue;
        }
        if (depth == stack.len) return null;
        stack[depth] = part;
        depth += 1;
    }
    for (stack[0..depth], 0..) |segment, index| {
        if (index > 0) {
            if (len == buffer.len) return null;
            buffer[len] = '/';
            len += 1;
        }
        if (len + segment.len > buffer.len) return null;
        @memcpy(buffer[len..][0..segment.len], segment);
        len += segment.len;
    }
    return buffer[0..len];
}

/// True when `path` is one of `subsystem`'s own files.
fn isMember(subsystem: Subsystem, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, subsystem.dir) or
        path.len <= subsystem.dir.len or
        path[subsystem.dir.len] != '/') return false;
    const rest = path[subsystem.dir.len + 1 ..];
    if (subsystem.only.len > 0) return isListed(subsystem.only, rest);
    return subsystem.recursive or std.mem.indexOfScalar(u8, rest, '/') == null;
}

fn isListed(list: []const []const u8, name: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

/// The files one subsystem reaches, each with the file it was reached from
/// (null for the subsystem's own files), and those still to be checked.
const Walk = struct {
    allocator: std.mem.Allocator,
    reached_from: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    pending: std.ArrayList([]const u8) = .empty,

    fn visit(walk: *Walk, path: []const u8, from: ?[]const u8) !void {
        if (walk.reached_from.contains(path)) return;
        const owned = try walk.allocator.dupe(u8, path);
        try walk.reached_from.put(walk.allocator, owned, from);
        try walk.pending.append(walk.allocator, owned);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = std.process.Args.iterateAllocator(init.minimal.args, allocator) catch
        return error.InvalidArguments;
    defer args.deinit();
    _ = args.next();
    const root_path = args.next() orelse ".";

    var root = try std.Io.Dir.cwd().openDir(init.io, root_path, .{});
    defer root.close(init.io);

    var violations: usize = 0;
    for (SUBSYSTEMS, 0..) |subsystem, index| {
        var walk: Walk = .{ .allocator = allocator };
        var dir = try root.openDir(init.io, subsystem.dir, .{ .iterate = true, .follow_symlinks = false });
        defer dir.close(init.io);
        try seed(allocator, init.io, dir, subsystem, subsystem.dir, &walk);
        while (walk.pending.pop()) |path| {
            const source = root.readFileAlloc(init.io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| {
                violations += 1;
                std.debug.print("{s}: cannot be read ({s})\n", .{ path, @errorName(err) });
                continue;
            };
            try check(&walk, source, path, &SUBSYSTEMS, index, &violations);
        }
    }
    violations += try checkLibrary(allocator, init.io, root, LIBRARY);
    violations += try checkRatchet(allocator, init.io, root, HOST_KERNEL);
    if (violations != 0) return error.SubsystemBoundaryViolation;
}

/// Follow `library`'s import closure under `root` and count its violations:
/// every unlisted edge into the application side, every unreadable file, and
/// every baseline entry whose edge no longer exists.
fn checkLibrary(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, library: Library) !usize {
    var walk: Walk = .{ .allocator = allocator };
    const used = try allocator.alloc(bool, library.baseline.len);
    defer allocator.free(used);
    @memset(used, false);
    var violations: usize = 0;
    try walk.visit(library.root, null);
    while (walk.pending.pop()) |path| {
        const source = root.readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| {
            violations += 1;
            std.debug.print("{s}: cannot be read ({s})\n", .{ path, @errorName(err) });
            continue;
        };
        try checkLibraryFile(&walk, source, path, library, used, &violations);
    }
    violations += staleBaseline(library, used);
    return violations;
}

/// Check every `@import` in `source`, the text of `path`, a file of
/// `library`'s closure: queue each library file it reaches, mark each
/// baseline edge it still has, and count every other edge into the
/// application side. An application-side file is never followed.
fn checkLibraryFile(
    walk: *Walk,
    source: []const u8,
    path: []const u8,
    library: Library,
    used: []bool,
    violations: *usize,
) !void {
    const needle = "@import(\"";
    var cursor: usize = 0;
    var line: usize = 1;
    var scanned: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, needle)) |found| {
        while (scanned < found) : (scanned += 1) {
            if (source[scanned] == '\n') line += 1;
        }
        const start = found + needle.len;
        const end = std.mem.indexOfScalarPos(u8, source, start, '"') orelse break;
        cursor = end + 1;
        const target = source[start..end];
        // The library's files name the application side in prose, such as
        // the note on where a type used to live; only code is an edge.
        const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..found], '\n')) |newline| newline + 1 else 0;
        if (isProse(source[line_start..found])) continue;
        var buffer: [512]u8 = undefined;
        // A named module is the build graph's business, not this check's.
        const resolved = resolve(&buffer, path, target) orelse continue;
        if (!isAppSide(library, resolved)) {
            try walk.visit(resolved, path);
            continue;
        }
        if (baselineIndex(library, path, resolved)) |index| {
            used[index] = true;
            continue;
        }
        violations.* += 1;
        std.debug.print(
            "{s}:{d}: `{s}` takes {s} into the application side",
            .{ path, line, target, library.name },
        );
        if (walk.reached_from.get(path)) |from| {
            if (from) |parent| std.debug.print(" (reached from {s})", .{parent});
        }
        std.debug.print("\n", .{});
    }
}

/// True when text following `prefix`, the start of its line, is a comment or
/// a multiline string line rather than code.
fn isProse(prefix: []const u8) bool {
    const code = std.mem.trimStart(u8, prefix, " \t");
    if (std.mem.startsWith(u8, code, "\\\\")) return true;
    var in_string = false;
    var index: usize = 0;
    while (index < code.len) : (index += 1) {
        const byte = code[index];
        if (in_string) {
            if (byte == '\\') index += 1 else if (byte == '"') in_string = false;
        } else if (byte == '"') {
            in_string = true;
        } else if (byte == '/' and index + 1 < code.len and code[index + 1] == '/') {
            return true;
        }
    }
    return false;
}

/// Count, and name, every baseline entry whose edge no file still has.
fn staleBaseline(library: Library, used: []const bool) usize {
    var stale: usize = 0;
    for (library.baseline, used) |edge, still| {
        if (still) continue;
        stale += 1;
        std.debug.print(
            "{s} -> {s}: stale {s} baseline entry; the edge is gone, so delete the entry\n",
            .{ edge.from, edge.to, library.name },
        );
    }
    return stale;
}

/// Count `ratchet`'s violations under `root`: every import of its target from
/// a file the baseline does not name, and every baseline entry whose import is
/// gone.
fn checkRatchet(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, ratchet: Ratchet) !usize {
    const used = try allocator.alloc(bool, ratchet.baseline.len);
    defer allocator.free(used);
    @memset(used, false);
    var violations: usize = 0;
    for (ratchet.dirs) |dir_path| {
        const prefix = dir_path[0 .. dir_path.len - 1];
        var dir = root.openDir(io, prefix, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
            // A directory that is gone holds no import.
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(io);
        try checkRatchetDir(allocator, io, root, dir, prefix, ratchet, used, &violations);
    }
    for (ratchet.baseline, used) |file, still| {
        if (still) continue;
        violations += 1;
        std.debug.print(
            "{s}: stale {s} baseline entry; it no longer imports {s}, so delete the entry\n",
            .{ file, ratchet.name, ratchet.target },
        );
    }
    return violations;
}

fn checkRatchetDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    dir: std.Io.Dir,
    prefix: []const u8,
    ratchet: Ratchet,
    used: []bool,
    violations: *usize,
) !void {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        defer allocator.free(path);
        switch (entry.kind) {
            .directory => {
                var child = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                defer child.close(io);
                try checkRatchetDir(allocator, io, root, child, path, ratchet, used, violations);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const source = root.readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| {
                    violations.* += 1;
                    std.debug.print("{s}: cannot be read ({s})\n", .{ path, @errorName(err) });
                    continue;
                };
                defer allocator.free(source);
                checkRatchetFile(source, path, ratchet, used, violations);
            },
            else => {},
        }
    }
}

/// Check every `@import` in `source`, the text of `path`: mark the baseline
/// entry of a listed file that still imports the target, and count every
/// other import of it.
fn checkRatchetFile(source: []const u8, path: []const u8, ratchet: Ratchet, used: []bool, violations: *usize) void {
    const needle = "@import(\"";
    var cursor: usize = 0;
    var line: usize = 1;
    var scanned: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, needle)) |found| {
        while (scanned < found) : (scanned += 1) {
            if (source[scanned] == '\n') line += 1;
        }
        const start = found + needle.len;
        const end = std.mem.indexOfScalarPos(u8, source, start, '"') orelse break;
        cursor = end + 1;
        const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..found], '\n')) |newline| newline + 1 else 0;
        if (isProse(source[line_start..found])) continue;
        var buffer: [512]u8 = undefined;
        const resolved = resolve(&buffer, path, source[start..end]) orelse continue;
        if (!std.mem.eql(u8, resolved, ratchet.target)) continue;
        if (ratchetIndex(ratchet, path)) |index| {
            used[index] = true;
            continue;
        }
        violations.* += 1;
        std.debug.print(
            "{s}:{d}: imports {s}, which the {s} rule forbids; drive the kernel through src/core/session_host.zig\n",
            .{ path, line, ratchet.target, ratchet.name },
        );
    }
}

/// Queue every file of the subsystem.
fn seed(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    subsystem: Subsystem,
    prefix: []const u8,
    walk: *Walk,
) !void {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (!subsystem.recursive) continue;
                var child = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                defer child.close(io);
                const nested = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
                try seed(allocator, io, child, subsystem, nested, walk);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
                if (isMember(subsystem, path)) try walk.visit(path, null);
            },
            else => {},
        }
    }
}

/// Check every `@import` in `source`, the text of `path`, against the lists of
/// `subsystems[index]`, and queue each file it may reach that is not another
/// subsystem's.
fn check(
    walk: *Walk,
    source: []const u8,
    path: []const u8,
    subsystems: []const Subsystem,
    index: usize,
    violations: *usize,
) !void {
    const subsystem = subsystems[index];
    const needle = "@import(\"";
    var cursor: usize = 0;
    var line: usize = 1;
    var scanned: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, needle)) |found| {
        while (scanned < found) : (scanned += 1) {
            if (source[scanned] == '\n') line += 1;
        }
        const start = found + needle.len;
        const end = std.mem.indexOfScalarPos(u8, source, start, '"') orelse break;
        cursor = end + 1;
        const target = source[start..end];
        var buffer: [512]u8 = undefined;
        if (resolve(&buffer, path, target)) |resolved| {
            if (isMember(subsystem, resolved)) {
                try walk.visit(resolved, path);
                continue;
            }
            if (isListed(subsystem.reaches, resolved)) {
                if (!ownedElsewhere(subsystems, index, resolved)) try walk.visit(resolved, path);
                continue;
            }
        } else if (isListed(subsystem.modules, target)) continue;

        violations.* += 1;
        std.debug.print(
            "{s}:{d}: `{s}` is outside the {s} import boundary",
            .{ path, line, target, subsystem.name },
        );
        if (walk.reached_from.get(path)) |from| {
            if (from) |parent| std.debug.print(" (reached from {s})", .{parent});
        }
        std.debug.print("\n", .{});
    }
}

fn ownedElsewhere(subsystems: []const Subsystem, index: usize, path: []const u8) bool {
    for (subsystems, 0..) |other, other_index| {
        if (other_index != index and isMember(other, path)) return true;
    }
    return false;
}

test "a reach outside the subsystem must be listed by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const subsystems = [_]Subsystem{.{
        .name = "provider",
        .dir = "src/provider",
        .recursive = true,
        .modules = &.{ "std", "platform" },
        .reaches = &.{"src/types.zig"},
    }};
    var walk: Walk = .{ .allocator = arena.allocator() };
    var violations: usize = 0;

    // Inside the subsystem, from its root and from a nested directory.
    try check(&walk, "@import(\"ids.zig\")", "src/provider/registry.zig", &subsystems, 0, &violations);
    try check(&walk, "@import(\"../ids.zig\")", "src/provider/profiles/metask.zig", &subsystems, 0, &violations);
    try check(&walk, "@import(\"profiles/metask.zig\")", "src/provider/registry.zig", &subsystems, 0, &violations);
    try check(&walk, "@import(\"std\")", "src/provider/registry.zig", &subsystems, 0, &violations);
    try check(&walk, "@import(\"../types.zig\")", "src/provider/ids.zig", &subsystems, 0, &violations);
    try std.testing.expectEqual(@as(usize, 0), violations);

    // The reach this boundary exists to prevent, from both depths — a textual
    // `../` rule admitted the first of these, which is how the transport could
    // have entered the provider kernel unnoticed.
    try check(&walk, "@import(\"../client.zig\")", "src/provider/registry.zig", &subsystems, 0, &violations);
    try std.testing.expectEqual(@as(usize, 1), violations);
    try check(&walk, "@import(\"../../client.zig\")", "src/provider/profiles/metask.zig", &subsystems, 0, &violations);
    try std.testing.expectEqual(@as(usize, 2), violations);
    // An undeclared named module is a dependency too.
    try check(&walk, "@import(\"hl\")", "src/provider/registry.zig", &subsystems, 0, &violations);
    try std.testing.expectEqual(@as(usize, 3), violations);
}

test "a reached file is held to the same lists, its tests included" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const subsystems = [_]Subsystem{.{
        .name = "provider",
        .dir = "src/provider",
        .recursive = true,
        .modules = &.{"std"},
        .reaches = &.{ "src/util/pricing.zig", "src/api/model_name.zig" },
    }};
    var walk: Walk = .{ .allocator = arena.allocator() };
    var violations: usize = 0;

    // A listed file is followed, and so is a listed file it reaches.
    try check(&walk, "@import(\"../../util/pricing.zig\")", "src/provider/profiles/metask.zig", &subsystems, 0, &violations);
    try std.testing.expectEqualStrings("src/util/pricing.zig", walk.pending.pop().?);
    try check(&walk, "const model_name = @import(\"../api/model_name.zig\");", "src/util/pricing.zig", &subsystems, 0, &violations);
    try std.testing.expectEqualStrings("src/api/model_name.zig", walk.pending.pop().?);
    try std.testing.expectEqual(@as(usize, 0), violations);

    // The leak that broke both isolation roots: a test in a reached leaf that
    // imports the system prompt.
    try check(&walk,
        \\test "routing" {
        \\    const prompt = @import("../core/system_prompt.zig");
        \\}
    , "src/api/model_name.zig", &subsystems, 0, &violations);
    try std.testing.expectEqual(@as(usize, 1), violations);
    // A reached file's named modules are held to the subsystem's list too.
    try check(&walk, "@import(\"platform\")", "src/util/pricing.zig", &subsystems, 0, &violations);
    try std.testing.expectEqual(@as(usize, 2), violations);
    try std.testing.expectEqual(@as(usize, 0), walk.pending.items.len);
}

test "a file another subsystem owns is entered, not followed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const subsystems = [_]Subsystem{
        .{
            .name = "picker",
            .dir = "src/repl",
            .recursive = false,
            .only = &.{"model_picker.zig"},
            .modules = &.{"std"},
            .reaches = &.{"src/provider/control_plane.zig"},
        },
        .{ .name = "provider", .dir = "src/provider", .recursive = true, .modules = &.{"std"}, .reaches = &.{} },
    };
    var walk: Walk = .{ .allocator = arena.allocator() };
    var violations: usize = 0;

    try check(&walk, "@import(\"../provider/control_plane.zig\")", "src/repl/model_picker.zig", &subsystems, 0, &violations);
    try std.testing.expectEqual(@as(usize, 0), violations);
    try std.testing.expectEqual(@as(usize, 0), walk.pending.items.len);
    // Its entry point is still the only way in.
    try check(&walk, "@import(\"../provider/registry.zig\")", "src/repl/model_picker.zig", &subsystems, 0, &violations);
    try std.testing.expectEqual(@as(usize, 1), violations);
}

test "membership follows `only` and `recursive`, not the directory prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const picker = Subsystem{
        .name = "picker",
        .dir = "src/repl",
        .recursive = false,
        .only = &.{ "model_picker.zig", "model_picker_view.zig" },
        .modules = &.{"std"},
        .reaches = &.{},
    };
    const subsystems = [_]Subsystem{picker};
    var walk: Walk = .{ .allocator = arena.allocator() };
    var violations: usize = 0;

    try check(&walk, "@import(\"model_picker.zig\")", "src/repl/model_picker_view.zig", &subsystems, 0, &violations);
    try std.testing.expectEqual(@as(usize, 0), violations);
    // A sibling in the same directory is not part of the picker; a prefix
    // rule admitted it, and with it the whole REPL.
    try check(&walk, "@import(\"loop.zig\")", "src/repl/model_picker.zig", &subsystems, 0, &violations);
    try std.testing.expectEqual(@as(usize, 1), violations);

    try std.testing.expect(isMember(picker, "src/repl/model_picker.zig"));
    try std.testing.expect(!isMember(picker, "src/repl/loop.zig"));
    try std.testing.expect(!isMember(picker, "src/repl_extra/model_picker.zig"));
    const flat = Subsystem{ .name = "flat", .dir = "src/repl", .recursive = false, .modules = &.{}, .reaches = &.{} };
    try std.testing.expect(isMember(flat, "src/repl/loop.zig"));
    try std.testing.expect(!isMember(flat, "src/repl/tui/theme.zig"));
    const deep = Subsystem{ .name = "deep", .dir = "src/repl", .recursive = true, .modules = &.{}, .reaches = &.{} };
    try std.testing.expect(isMember(deep, "src/repl/tui/theme.zig"));
}

test "paths resolve the way the compiler would read them" {
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "src/provider/ids.zig",
        resolve(&buffer, "src/provider/profiles/metask.zig", "../ids.zig").?,
    );
    try std.testing.expectEqualStrings(
        "src/util/model.zig",
        resolve(&buffer, "src/provider/profiles/metask.zig", "../../util/model.zig").?,
    );
    try std.testing.expectEqualStrings(
        "src/app.zig",
        resolve(&buffer, "src/repl/model_picker.zig", "../app.zig").?,
    );
    // A named module has no path to resolve.
    try std.testing.expect(resolve(&buffer, "src/provider/ids.zig", "platform") == null);
}

/// A miniature of `LIBRARY`, with one baseline edge.
const TEST_LIBRARY = Library{
    .name = "core",
    .root = "src/lib.zig",
    .app_side = &.{ "src/repl/", "src/app/", "src/app.zig" },
    .unbaselined = &.{"src/core/"},
    .baseline = &.{.{ .from = "src/version_info.zig", .to = "src/app/config.zig" }},
};

/// Lay out `files`, path then source, under a fresh directory, and run the
/// library check there as `main` runs it on the repository.
fn checkTree(library: Library, files: []const [2][]const u8) !usize {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (files) |file| {
        if (std.fs.path.dirnamePosix(file[0])) |dir| try tmp.dir.createDirPath(std.testing.io, dir);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file[0], .data = file[1] });
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    return checkLibrary(arena.allocator(), std.testing.io, tmp.dir, library);
}

test "the library closure may not gain an edge into the application side" {
    const clean = [_][2][]const u8{
        .{ "src/lib.zig", "pub const conversation = @import(\"core/conversation.zig\");\npub const version_info = @import(\"version_info.zig\");\n" },
        .{ "src/core/conversation.zig", "const std = @import(\"std\");\nconst platform = @import(\"platform\");\n" },
        .{ "src/version_info.zig", "const config = @import(\"app/config.zig\");\n" },
    };
    try std.testing.expectEqual(@as(usize, 0), try checkTree(TEST_LIBRARY, &clean));

    // The import #448 plants, in a test block that lazy analysis of the
    // library never compiles.
    var planted = clean;
    planted[1][1] =
        \\const std = @import("std");
        \\test "theme" {
        \\    const theme = @import("../repl/tui/theme.zig");
        \\    _ = theme;
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 1), try checkTree(TEST_LIBRARY, &planted));

    // Two hops away, inside a function body, still counts.
    const deep = [_][2][]const u8{
        clean[0],
        .{ "src/core/conversation.zig", "fn later() void {\n    _ = @import(\"../swarm/teammate.zig\");\n}\n" },
        .{ "src/swarm/teammate.zig", "const App = @import(\"../app.zig\").App;\n" },
        clean[2],
    };
    try std.testing.expectEqual(@as(usize, 1), try checkTree(TEST_LIBRARY, &deep));
}

test "a baseline entry whose edge is gone fails the library check" {
    const pruned = [_][2][]const u8{
        .{ "src/lib.zig", "pub const version_info = @import(\"version_info.zig\");\n" },
        .{ "src/version_info.zig", "const config = @import(\"config.zig\");\n" },
        .{ "src/config.zig", "" },
    };
    try std.testing.expectEqual(@as(usize, 1), try checkTree(TEST_LIBRARY, &pruned));
    // An entry names its edge, not its target: the same target reached from
    // another file is a new edge, and the entry is stale besides.
    const moved = [_][2][]const u8{
        .{ "src/lib.zig", "pub const config = @import(\"app/config.zig\");\n" },
    };
    try std.testing.expectEqual(@as(usize, 2), try checkTree(TEST_LIBRARY, &moved));
}

test "the library check reads imports, not prose about them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var walk: Walk = .{ .allocator = arena.allocator() };
    var used = [_]bool{false};
    var violations: usize = 0;

    try checkLibraryFile(&walk,
        \\//! Moved out of app.zig, which reached it as `@import("../app.zig")`.
        \\const text = "see"; // @import("../app.zig")
        \\const sample =
        \\    \\const app = @import("../app.zig");
        \\;
    , "src/core/mcp_session.zig", TEST_LIBRARY, &used, &violations);
    try std.testing.expectEqual(@as(usize, 0), violations);
    // Code after a string holding `//` is still code.
    try checkLibraryFile(&walk, "const url = \"http://x\"; const app = @import(\"../app.zig\");", "src/core/mcp_session.zig", TEST_LIBRARY, &used, &violations);
    try std.testing.expectEqual(@as(usize, 1), violations);
    try std.testing.expectEqual(@as(usize, 0), walk.pending.items.len);
}

test "the library baseline admits no core file, no duplicate, and only app-side targets" {
    try std.testing.expectEqual(@as(?[]const u8, null), baselineError(LIBRARY));
    try std.testing.expectEqual(@as(?[]const u8, null), baselineError(TEST_LIBRARY));
    var library = TEST_LIBRARY;
    library.baseline = &.{.{ .from = "src/core/conversation.zig", .to = "src/repl/tui/theme.zig" }};
    try std.testing.expect(baselineError(library) != null);
    library.baseline = &.{.{ .from = "src/version_info.zig", .to = "src/util/fs.zig" }};
    try std.testing.expect(baselineError(library) != null);
    library.baseline = &.{.{ .from = "src/app.zig", .to = "src/app/config.zig" }};
    try std.testing.expect(baselineError(library) != null);
    library.baseline = &.{ TEST_LIBRARY.baseline[0], TEST_LIBRARY.baseline[0] };
    try std.testing.expect(baselineError(library) != null);
}

test "the real library's application side is the one #448 names" {
    for ([_][]const u8{
        "src/repl/tui/theme.zig",
        "src/web/server.zig",
        "src/daemon/main.zig",
        "src/app/config.zig",
        "src/main.zig",
        "src/app.zig",
        "src/session_service.zig",
        "src/session_intent.zig",
    }) |path| try std.testing.expect(isAppSide(LIBRARY, path));
    try std.testing.expect(!isAppSide(LIBRARY, "src/api/model_context.zig"));
    try std.testing.expect(!isAppSide(LIBRARY, "src/application.zig"));
    try std.testing.expect(!isAppSide(LIBRARY, "src/app_extra.zig"));
}

/// A miniature of `HOST_KERNEL`, with one baseline file.
const TEST_RATCHET = Ratchet{
    .name = "host",
    .dirs = &.{ "src/daemon/", "src/web/" },
    .target = "src/core/agent_loop.zig",
    .baseline = &.{"src/daemon/app_driver.zig"},
};

/// Lay out `files` as `checkTree` does and run the ratchet check there.
fn checkRatchetTree(ratchet: Ratchet, files: []const [2][]const u8) !usize {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (files) |file| {
        if (std.fs.path.dirnamePosix(file[0])) |dir| try tmp.dir.createDirPath(std.testing.io, dir);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file[0], .data = file[1] });
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    return checkRatchet(arena.allocator(), std.testing.io, tmp.dir, ratchet);
}

test "a host file may not start importing the AgentLoop (#445)" {
    const driver = [2][]const u8{ "src/daemon/app_driver.zig", "const agent_loop = @import(\"../core/agent_loop.zig\");\n" };
    const clean = [_][2][]const u8{
        driver,
        .{ "src/web/server.zig", "const host = @import(\"../core/session_host.zig\");\n" },
        .{ "src/core/agent_loop.zig", "" },
    };
    try std.testing.expectEqual(@as(usize, 0), try checkRatchetTree(TEST_RATCHET, &clean));

    // A new edge, from the other directory and from a nested one.
    var web = clean;
    web[1][1] = "const agent_loop = @import(\"../core/agent_loop.zig\");\n";
    try std.testing.expectEqual(@as(usize, 1), try checkRatchetTree(TEST_RATCHET, &web));
    const nested = [_][2][]const u8{
        driver,
        .{ "src/web/static/run.zig", "fn later() void {\n    _ = @import(\"../../core/agent_loop.zig\");\n}\n" },
    };
    try std.testing.expectEqual(@as(usize, 1), try checkRatchetTree(TEST_RATCHET, &nested));

    // Outside the hosts, and in prose, it is not this rule's business.
    const elsewhere = [_][2][]const u8{
        driver,
        .{ "src/session_service.zig", "const agent_loop = @import(\"core/agent_loop.zig\");\n" },
        .{ "src/web/session.zig", "//! Used to call `@import(\"../core/agent_loop.zig\")` directly.\n" },
    };
    try std.testing.expectEqual(@as(usize, 0), try checkRatchetTree(TEST_RATCHET, &elsewhere));
}

test "a host baseline entry whose import is gone fails the ratchet" {
    const migrated = [_][2][]const u8{
        .{ "src/daemon/app_driver.zig", "const host = @import(\"../core/session_host.zig\");\n" },
    };
    try std.testing.expectEqual(@as(usize, 1), try checkRatchetTree(TEST_RATCHET, &migrated));
    // The file itself gone counts the same way.
    const deleted = [_][2][]const u8{.{ "src/web/server.zig", "" }};
    try std.testing.expectEqual(@as(usize, 1), try checkRatchetTree(TEST_RATCHET, &deleted));
}

test "the host ratchet's baseline is under its directories and has no duplicate" {
    try std.testing.expectEqual(@as(?[]const u8, null), ratchetError(HOST_KERNEL));
    try std.testing.expectEqual(@as(usize, 2), HOST_KERNEL.baseline.len);
    var ratchet = TEST_RATCHET;
    ratchet.baseline = &.{"src/session_service.zig"};
    try std.testing.expect(ratchetError(ratchet) != null);
    ratchet.baseline = &.{ "src/web/session.zig", "src/web/session.zig" };
    try std.testing.expect(ratchetError(ratchet) != null);
    ratchet = TEST_RATCHET;
    ratchet.dirs = &.{"src/web"};
    try std.testing.expect(ratchetError(ratchet) != null);
}
