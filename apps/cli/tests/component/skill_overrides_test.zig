//! L2: `skillOverrides` reach the provider request and the Skill tool.
//!
//! Claude Code's per-Skill overrides ("on", "name-only",
//! "user-invocable-only", "off"; user < project < local settings) decide what
//! the model is told about each Skill and what the Skill tool admits. Locked
//! here against a real App, agent loop and Skill Runtime, with a mock provider
//! capturing the request bodies:
//!   - the Skill tool description and the system prompt's skills section list
//!     an "on" Skill in full, a "name-only" one by name, and leave
//!     "user-invocable-only" and "off" out (both sides of each);
//!   - precedence: a local "on" beats a project "name-only";
//!   - the Skill tool refuses a hidden Skill with Claude Code's message, and
//!     `/name` refuses only an "off" one;
//!   - `/skills` (App.applySkillOverrides) writes the local settings file and
//!     the next request carries the new listing, and the Skill tool admits the
//!     Skill it now lists;
//!   - nothing changes the request bytes when nothing changed.
//!
//! Cross-module: app (init, applySkillOverrides) + skills/overrides +
//! skills/cli_adapter + skills/runtime/model_tool + core/system_prompt +
//! session_service + agent_loop. chdir is process-wide: the fixture restores
//! the process cwd.

const std = @import("std");
const cc = @import("cc");
const harness = @import("harness");
const ppaths = @import("platform").paths;
const pfs = @import("platform").fs;

const EnvGuard = struct {
    allocator: std.mem.Allocator,
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(allocator: std.mem.Allocator, name: [*:0]const u8, value: [*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try allocator.dupeZ(u8, std.mem.span(raw)) else null;
        ppaths.setEnv(name, value);
        return .{ .allocator = allocator, .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            self.allocator.free(previous);
        } else {
            ppaths.unsetEnv(self.name);
        }
        self.* = undefined;
    }
};

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_final\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// One assistant message calling `Skill` with `input`, tool_use id `tu_<id>`.
fn skillCall(a: std.mem.Allocator, id: usize, input: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_tools\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n");
    try w.print("data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_{d}\",\"name\":\"Skill\",\"input\":{{}}}}}}\n\n", .{id});
    try w.print("data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{f}}}}}\n\n", .{std.json.fmt(input, .{})});
    try w.writeAll("data: {\"type\":\"content_block_stop\",\"index\":0}\n\n");
    try w.writeAll("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n");
    try w.writeAll("data: {\"type\":\"message_stop\"}\n\n");
    return out.toOwnedSlice();
}

fn chdirTo(path: []const u8) !void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    if (pfs.chdir(z.ptr) != 0) return error.ChdirFailed;
}

const File = struct { path: []const u8, data: []const u8 };

fn skillFile(comptime name: []const u8) File {
    return .{
        .path = "home/.claude/skills/" ++ name ++ "/SKILL.md",
        .data = "---\nname: " ++ name ++ "\ndescription: The " ++ name ++ " skill describes itself\n---\nRun the " ++ name ++ " steps.\n",
    };
}

/// A real App: HOME `<tmp>/home` (four personal Skills), working directory
/// the repository `<tmp>/repo`, provider a mock server playing `responses`.
/// `setup` must run on the caller's final address.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    home_guard: EnvGuard,
    codex_guard: EnvGuard,
    probe_guard: EnvGuard,
    autostart_guard: EnvGuard,
    server: *harness.MockServer,
    previous_cwd: []u8,
    app: *cc.app_module.App,

    fn setup(self: *Fixture, responses: []const []const u8, settings: []const File) !void {
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
        const skills = [_]File{ skillFile("alpha"), skillFile("beta"), skillFile("gamma"), skillFile("delta") };
        for ([_][]const File{ &skills, settings }) |files| for (files) |file| {
            if (std.fs.path.dirname(file.path)) |dir| try self.tmp.dir.createDirPath(std.testing.io, dir);
            try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = file.path, .data = file.data });
        };

        self.home_guard = try EnvGuard.set(a, "HOME", (try allocator.dupeZ(u8, home)).ptr);
        errdefer self.home_guard.restore();
        // `$CODEX_HOME` is absolute: left alone it would add the host's Codex Skills.
        self.codex_guard = try EnvGuard.set(a, "CODEX_HOME", (try std.fs.path.joinZ(allocator, &.{ home, ".codex" })).ptr);
        errdefer self.codex_guard.restore();
        self.probe_guard = try EnvGuard.set(a, "METACODES_NO_PROBE", "1");
        errdefer self.probe_guard.restore();
        self.autostart_guard = try EnvGuard.set(a, "METACODES_KG_AUTOSTART", "0");
        errdefer self.autostart_guard.restore();

        self.server = try harness.MockServer.startCassette(responses, 0);
        errdefer self.server.stop();
        const url_z = try allocator.dupeZ(u8, try self.server.urlOwned(allocator));
        const argv = [_][*:0]const u8{ "metacodes", "--base-url", url_z.ptr, "--model", "test-model", "--permission", "bypassPermissions" };
        const config = cc.parseArgsForTest(&argv, allocator);
        try std.testing.expect(config.parse_error == null);

        self.previous_cwd = try cc.util_fs.getCwd(a);
        errdefer a.free(self.previous_cwd);
        try chdirTo(repo);
        errdefer chdirTo(self.previous_cwd) catch {};

        self.io_rt = @import("platform").signal.threadedIo(allocator, .{});
        errdefer self.io_rt.deinit();
        self.app = try cc.app_module.App.init(a, self.io_rt.io(), config, "test-key");
    }

    fn deinit(self: *Fixture) void {
        self.app.deinit();
        self.io_rt.deinit();
        chdirTo(self.previous_cwd) catch {};
        std.testing.allocator.free(self.previous_cwd);
        self.server.stop();
        self.autostart_guard.restore();
        self.probe_guard.restore();
        self.codex_guard.restore();
        self.home_guard.restore();
        self.arena.deinit();
        self.tmp.cleanup();
    }

    /// One Run with the options the product assembles for the main session.
    fn run(self: *Fixture, prompt: []const u8) !void {
        try self.app.conversation.appendText(.user, prompt);
        var jobs = try cc.job_registry.JobRegistry.init(std.testing.allocator);
        defer jobs.deinit();
        var options = cc.session_service.buildRunOptions(self.app, null);
        options.max_turns = 4;
        options.jobs = &jobs;
        var sink = cc.writer_backend.WriterBackend.initNull();
        const backend = sink.backend();
        const result = try cc.agent_loop.run(&self.app.conversation, self.app.provider(), self.app.tool_defs, &self.app.permission_ctx, options, &backend, self.app.allocator);
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    }

    fn request(self: *Fixture, index: usize) ![]const u8 {
        const captured = self.server.requestAt(index) orelse return error.NoRequestCaptured;
        return captured.body();
    }

    fn readLocalSettings(self: *Fixture) ![]u8 {
        return self.tmp.dir.readFileAlloc(std.testing.io, "repo/.claude/settings.local.json", std.testing.allocator, .limited(1 << 16));
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find\n  {s}\nin\n  {s}\n", .{ needle, haystack });
        return error.TestExpectedSubstring;
    }
}

fn expectAbsent(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("expected NOT to find\n  {s}\nin\n  {s}\n", .{ needle, haystack });
        return error.TestUnexpectedSubstring;
    }
}

/// The Skill tool's JSON entry in a request body (a `tool_use` of Skill in
/// the messages comes first, so the search starts at the tools array).
fn skillToolEntry(body: []const u8) ![]const u8 {
    const tools = std.mem.indexOf(u8, body, "\"tools\":[") orelse return error.ToolsMissing;
    const at = std.mem.indexOfPos(u8, body, tools, "\"name\":\"Skill\"") orelse return error.SkillToolMissing;
    const end = std.mem.indexOfPos(u8, body, at, "\"input_schema\"") orelse body.len;
    return body[at..end];
}

/// The tool_result for `id` in a request body, up to the next block.
fn toolResult(body: []const u8, id: []const u8) ![]const u8 {
    var key_buf: [64]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "\"tool_use_id\":\"{s}\"", .{id});
    const at = std.mem.indexOf(u8, body, key) orelse return error.ToolResultMissing;
    const end = std.mem.indexOfPos(u8, body, at + key.len, "\"type\":") orelse body.len;
    return body[at..end];
}

/// The system prompt's skills section in a request body (JSON-escaped).
fn skillsSection(body: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, body, "# Available skills") orelse return error.SkillsSectionMissing;
    const end = std.mem.indexOfPos(u8, body, at + 1, "\\n\\n#") orelse body.len;
    return body[at..end];
}

test "L2 skillOverrides: listing, admission, and a /skills change reach the request" {
    const a = std.testing.allocator;
    const call_gamma_hidden = try skillCall(a, 0, "{\"name\":\"gamma\"}");
    defer a.free(call_gamma_hidden);
    const call_gamma_listed = try skillCall(a, 1, "{\"name\":\"gamma\"}");
    defer a.free(call_gamma_listed);

    var fx: Fixture = undefined;
    try fx.setup(&.{ call_gamma_hidden, FINAL_SSE, call_gamma_listed, FINAL_SSE }, &.{
        // user: delta off. project: alpha name-only, beta name-only.
        // local: alpha back on, gamma user-invocable-only.
        .{ .path = "home/.claude/settings.json", .data = "{\"skillOverrides\":{\"delta\":\"off\"}}" },
        .{ .path = "repo/.claude/settings.json", .data = "{\"skillOverrides\":{\"alpha\":\"name-only\",\"beta\":\"name-only\"}}" },
        .{ .path = "repo/.claude/settings.local.json", .data = "{\"permissions\":{\"allow\":[\"Read\"]},\"skillOverrides\":{\"alpha\":\"on\",\"gamma\":\"user-invocable-only\"}}" },
    });
    defer fx.deinit();
    const app = fx.app;

    // ── Run 1: the model is told about alpha (full) and beta (name only). ──
    try fx.run("use a skill");
    {
        const body = try fx.request(0);
        const tool = try skillToolEntry(body);
        try expectContains(tool, "- alpha: The alpha skill describes itself");
        try expectContains(tool, "- beta\\n");
        try expectAbsent(tool, "beta skill describes");
        try expectAbsent(tool, "gamma");
        try expectAbsent(tool, "delta");

        const section = try skillsSection(body);
        try expectContains(section, "**alpha**");
        try expectContains(section, "The alpha skill describes itself");
        try expectContains(section, "- **beta**\\n");
        try expectAbsent(section, "beta skill describes");
        try expectAbsent(section, "gamma");
        try expectAbsent(section, "delta");

        // The model called gamma anyway: refused with Claude Code's words.
        const result = try toolResult(try fx.request(1), "tu_0");
        try expectContains(result, "Skill gamma is disabled for model invocation in skillOverrides settings");
        try expectAbsent(result, "Run the gamma steps");
    }

    // ── `/name`: user-invocable-only still runs for the user, off does not. ──
    try std.testing.expectEqual(cc.skills_cli_adapter.SlashDisposition.disabled, try cc.skills_cli_adapter.handleSlash(app, a, "delta"));
    const conversation_len = app.conversation.len();
    try std.testing.expectEqual(cc.skills_cli_adapter.SlashDisposition.run, try cc.skills_cli_adapter.handleSlash(app, a, "gamma"));
    try std.testing.expect(app.conversation.len() > conversation_len);
    app.clearActiveSkill();

    // ── Nothing changed: the request bytes stay as they were. ──
    const prompt_before = app.system_prompt.?;
    try app.applySkillOverrides(&.{});
    try std.testing.expectEqual(prompt_before.ptr, app.system_prompt.?.ptr);

    // ── /skills: gamma on, alpha off. ──
    try app.applySkillOverrides(&.{
        .{ .name = "gamma", .state = .on },
        .{ .name = "alpha", .state = .off },
    });
    {
        const text = try fx.readLocalSettings();
        defer a.free(text);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
        defer parsed.deinit();
        // Other settings are kept; gamma's "on" is the default, so its entry goes.
        try std.testing.expectEqualStrings("Read", parsed.value.object.get("permissions").?.object.get("allow").?.array.items[0].string);
        const entries = parsed.value.object.get("skillOverrides").?.object;
        try std.testing.expectEqualStrings("off", entries.get("alpha").?.string);
        try std.testing.expect(entries.get("gamma") == null);
    }

    {
        // The plain `/skills` report names every non-default state.
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try cc.repl_loop.writeSkillsReport(&out.writer, app);
        try expectContains(out.written(), "/alpha\x1b[0m \x1b[2m(user · off)");
        try expectContains(out.written(), "/beta\x1b[0m \x1b[2m(user · name-only)");
        try expectContains(out.written(), "/gamma\x1b[0m \x1b[2m(user)");
    }

    try fx.run("use it again");
    {
        const body = try fx.request(2);
        const tool = try skillToolEntry(body);
        try expectContains(tool, "- gamma: The gamma skill describes itself");
        try expectContains(tool, "- beta\\n");
        try expectAbsent(tool, "alpha");
        const section = try skillsSection(body);
        try expectContains(section, "**gamma**");
        try expectContains(section, "The gamma skill describes itself");
        try expectAbsent(section, "alpha");

        // gamma is listed now, and the Skill tool admits it.
        const result = try toolResult(try fx.request(3), "tu_1");
        try expectContains(result, "Run the gamma steps");
        try expectAbsent(result, "disabled for model invocation");
    }
}

test "L2 skillOverrides: without settings every Skill is listed in full, as before" {
    var fx: Fixture = undefined;
    try fx.setup(&.{FINAL_SSE}, &.{});
    defer fx.deinit();
    try fx.run("hello");
    const body = try fx.request(0);
    const tool = try skillToolEntry(body);
    inline for (.{ "alpha", "beta", "gamma", "delta" }) |name| {
        try expectContains(tool, "- " ++ name ++ ": The " ++ name ++ " skill describes itself");
    }
    // Nothing is written unless `/skills` changes something.
    try std.testing.expectError(error.FileNotFound, fx.readLocalSettings());
}
