//! Enforce the subsystem import boundaries #16 and #405 rely on.
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
            "src/api/dialects/claude.zig",
            "src/api/dialects/gemini.zig",
            "src/api/dialects/openai.zig",
            "src/api/error_class.zig",
            "src/api/http_connection.zig",
            "src/api/http_status.zig",
            "src/api/image_capability.zig",
            "src/api/last_error.zig",
            "src/api/model_adapter.zig",
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
    if (violations != 0) return error.SubsystemBoundaryViolation;
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
