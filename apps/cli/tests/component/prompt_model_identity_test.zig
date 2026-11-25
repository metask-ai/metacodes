//! L2: the model the system prompt names survives every rebuild.
//!
//! `--model-display-name` is the startup identity the prompt advertises for
//! the startup route; an explicit `/model` switch selects a new real model,
//! and from then on the prompt names that model (`switchModel`). The prompt
//! is rebuilt again later — a `/skills` change, a working directory renamed
//! under the session, a worktree switch — and each of those rebuilds must
//! keep the identity the last one established, never fall back to the
//! startup display name. Locked against a real App (one personal Skill, a
//! repository as the working directory).
//!
//! Cross-module: app (init, switchModel, applySkillOverrides,
//! refreshWorkspaceRoot) + core/system_prompt + skills/overrides. chdir is
//! process-wide: the fixture restores the process cwd.

const std = @import("std");
const builtin = @import("builtin");
const cc = @import("cc");
const ppaths = @import("platform").paths;
const pfs = @import("platform").fs;

const REAL_MODEL = "identity-real-model";
const DISPLAY_NAME = "identity-display-name";
const SWITCHED_MODEL = "identity-switched-model";

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

fn chdirTo(path: []const u8) !void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    if (pfs.chdir(z.ptr) != 0) return error.ChdirFailed;
}

/// A real App started with `--model REAL_MODEL --model-display-name
/// DISPLAY_NAME`: HOME `<tmp>/home` with one personal Skill, working
/// directory the repository `<tmp>/repo`. `setup` runs on the caller's final
/// address.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    guards: [4]EnvGuard,
    previous_cwd: []u8,
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
        const root = try allocator.dupe(u8, root_buffer[0..len]);
        const home = try std.fs.path.join(allocator, &.{ root, "home" });
        const repo = try std.fs.path.join(allocator, &.{ root, "repo" });
        // A `.git` directory is all `findRepoRoot` needs to make `repo` the project.
        try self.tmp.dir.createDirPath(std.testing.io, "repo/.git");
        try self.tmp.dir.createDirPath(std.testing.io, "home/.claude/skills/alpha");
        try self.tmp.dir.writeFile(std.testing.io, .{
            .sub_path = "home/.claude/skills/alpha/SKILL.md",
            .data = "---\nname: alpha\ndescription: The alpha skill describes itself\n---\nRun the alpha steps.\n",
        });

        self.guards = .{
            try EnvGuard.set("HOME", (try allocator.dupeZ(u8, home)).ptr),
            // `$CODEX_HOME` is absolute: left alone it would add the host's Codex Skills.
            try EnvGuard.set("CODEX_HOME", (try std.fs.path.joinZ(allocator, &.{ home, ".codex" })).ptr),
            try EnvGuard.set("METACODES_NO_PROBE", "1"),
            try EnvGuard.set("METACODES_KG_AUTOSTART", "0"),
        };
        errdefer for (&self.guards) |*guard| guard.restore();

        const argv = [_][*:0]const u8{
            "metacodes",  "--base-url",   "http://127.0.0.1:1/v1/messages",
            "--model",    REAL_MODEL,     "--model-display-name",
            DISPLAY_NAME, "--permission", "bypassPermissions",
        };
        const config = cc.parseArgsForTest(&argv, allocator);
        try std.testing.expect(config.parse_error == null);

        self.previous_cwd = try cc.util_fs.getCwd(a);
        errdefer a.free(self.previous_cwd);
        try chdirTo(repo);
        errdefer chdirTo(self.previous_cwd) catch {};

        self.io_rt = @import("platform").signal.threadedIo(allocator, .{});
        errdefer self.io_rt.deinit();
        self.app = try cc.app_module.App.init(allocator, self.io_rt.io(), config, "test-key");
    }

    fn deinit(self: *Fixture) void {
        self.app.deinit();
        self.io_rt.deinit();
        chdirTo(self.previous_cwd) catch {};
        std.testing.allocator.free(self.previous_cwd);
        var i = self.guards.len;
        while (i > 0) {
            i -= 1;
            self.guards[i].restore();
        }
        self.arena.deinit();
        self.tmp.cleanup();
    }

    /// The prompt names `expected` and neither of `absent`.
    fn expectNames(self: *const Fixture, expected: []const u8, absent: []const []const u8) !void {
        const prompt = self.app.system_prompt orelse return error.NoSystemPrompt;
        if (std.mem.indexOf(u8, prompt, expected) == null) {
            std.debug.print("the system prompt does not name {s}\n", .{expected});
            return error.TestExpectedModelName;
        }
        for (absent) |name| if (std.mem.indexOf(u8, prompt, name) != null) {
            std.debug.print("the system prompt still names {s}\n", .{name});
            return error.TestUnexpectedModelName;
        };
    }
};

test "a /model switch stays the model the prompt names through later rebuilds" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // renames the working directory in place
    var fx: Fixture = undefined;
    try fx.setup();
    defer fx.deinit();
    const app = fx.app;

    // Startup: the display identity, not the transport model.
    try fx.expectNames(DISPLAY_NAME, &.{REAL_MODEL});

    try app.switchModel(SWITCHED_MODEL);
    try fx.expectNames(SWITCHED_MODEL, &.{ DISPLAY_NAME, REAL_MODEL });

    // `/skills` rebuilds the prompt's skills section.
    try app.applySkillOverrides(&.{.{ .name = "alpha", .state = .name_only }});
    try fx.expectNames(SWITCHED_MODEL, &.{ DISPLAY_NAME, REAL_MODEL });

    // The working directory renamed under the session: the environment
    // section is rebuilt with the new path.
    try fx.tmp.dir.rename("repo", fx.tmp.dir, "repo-renamed", std.testing.io);
    try std.testing.expect(app.refreshWorkspaceRoot() == .renamed);
    try std.testing.expect(std.mem.endsWith(u8, app.cwdAbs(), "repo-renamed"));
    try fx.expectNames(SWITCHED_MODEL, &.{ DISPLAY_NAME, REAL_MODEL });
}

test "without a /model switch every rebuild keeps the startup display name" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // renames the working directory in place
    var fx: Fixture = undefined;
    try fx.setup();
    defer fx.deinit();
    const app = fx.app;

    try fx.expectNames(DISPLAY_NAME, &.{REAL_MODEL});
    try app.applySkillOverrides(&.{.{ .name = "alpha", .state = .name_only }});
    try fx.expectNames(DISPLAY_NAME, &.{REAL_MODEL});
    try fx.tmp.dir.rename("repo", fx.tmp.dir, "repo-renamed", std.testing.io);
    try std.testing.expect(app.refreshWorkspaceRoot() == .renamed);
    try fx.expectNames(DISPLAY_NAME, &.{REAL_MODEL});
}
