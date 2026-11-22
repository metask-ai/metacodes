const std = @import("std");
const builtin = @import("builtin");
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

fn toolCall(a: std.mem.Allocator, id: []const u8, name: []const u8, input: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_tools\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n");
    try w.print("data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n", .{ id, name });
    try w.print("data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{f}}}}}\n\n", .{std.json.fmt(input, .{})});
    try w.writeAll("data: {\"type\":\"content_block_stop\",\"index\":0}\n\n");
    try w.writeAll("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n");
    try w.writeAll("data: {\"type\":\"message_stop\"}\n\n");
    return out.toOwnedSlice();
}

fn skillMd(a: std.mem.Allocator, name: []const u8, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "---\nname: {s}\ndescription: The {s} skill describes itself\n---\n{s}\n", .{ name, name, body });
}

fn chdirTo(path: []const u8) !void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    if (pfs.chdir(z.ptr) != 0) return error.ChdirFailed;
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    guards: [4]EnvGuard,
    server: *harness.MockServer,
    previous_cwd: []u8,
    root: []const u8,
    home: []const u8,
    app: *cc.app_module.App,

    fn setup(self: *Fixture, responses: []const []const u8, skills: []const []const u8) !void {
        const a = std.testing.allocator;
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try self.tmp.dir.realPath(std.testing.io, &root_buffer);
        self.arena = std.heap.ArenaAllocator.init(a);
        errdefer self.arena.deinit();
        const allocator = self.arena.allocator();
        self.root = try allocator.dupe(u8, root_buffer[0..len]);
        self.home = try std.fs.path.join(allocator, &.{ self.root, "home" });
        const repo = try std.fs.path.join(allocator, &.{ self.root, "repo" });
        try self.tmp.dir.createDirPath(std.testing.io, "repo/.git");
        try self.tmp.dir.createDirPath(std.testing.io, "home/.claude/skills");
        for (skills) |name| try self.writeSkill(name, "Run the first steps.");

        self.guards = .{
            try EnvGuard.set(a, "HOME", (try allocator.dupeZ(u8, self.home)).ptr),
            try EnvGuard.set(a, "CODEX_HOME", (try std.fs.path.joinZ(allocator, &.{ self.home, ".codex" })).ptr),
            try EnvGuard.set(a, "METACODES_NO_PROBE", "1"),
            try EnvGuard.set(a, "METACODES_KG_AUTOSTART", "0"),
        };
        self.server = try harness.MockServer.startCassette(responses, 0);
        const url_z = try allocator.dupeZ(u8, try self.server.urlOwned(allocator));
        const argv = [_][*:0]const u8{ "metacodes", "--base-url", url_z.ptr, "--model", "test-model", "--permission", "bypassPermissions" };
        const config = cc.parseArgsForTest(&argv, allocator);
        try std.testing.expect(config.parse_error == null);
        self.previous_cwd = try cc.util_fs.getCwd(a);
        try chdirTo(repo);
        self.io_rt = @import("platform").signal.threadedIo(allocator, .{});
        self.app = try cc.app_module.App.init(a, self.io_rt.io(), config, "test-key");
    }

    fn deinit(self: *Fixture) void {
        self.app.deinit();
        self.io_rt.deinit();
        chdirTo(self.previous_cwd) catch {};
        std.testing.allocator.free(self.previous_cwd);
        self.server.stop();
        var i = self.guards.len;
        while (i > 0) {
            i -= 1;
            self.guards[i].restore();
        }
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn writeSkill(self: *Fixture, name: []const u8, body: []const u8) !void {
        const a = std.testing.allocator;
        const dir = try std.fmt.allocPrint(a, "home/.claude/skills/{s}", .{name});
        defer a.free(dir);
        try self.tmp.dir.createDirPath(std.testing.io, dir);
        const path = try std.fmt.allocPrint(a, "{s}/SKILL.md", .{dir});
        defer a.free(path);
        const data = try skillMd(a, name, body);
        defer a.free(data);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    }

    fn removeSkill(self: *Fixture, name: []const u8) !void {
        const a = std.testing.allocator;
        const dir = try std.fmt.allocPrint(a, "home/.claude/skills/{s}", .{name});
        defer a.free(dir);
        try self.tmp.dir.deleteTree(std.testing.io, dir);
    }

    fn run(self: *Fixture, prompt: []const u8) !void {
        try self.app.conversation.appendText(.user, prompt);
        var options = cc.session_service.buildRunOptions(self.app, null);
        options.max_turns = 5;
        var sink = cc.writer_backend.WriterBackend.initNull();
        const backend = sink.backend();
        const result = try cc.agent_loop.run(&self.app.conversation, self.app.provider(), self.app.tool_defs, &self.app.permission_ctx, options, &backend, self.app.allocator);
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    }

    fn request(self: *Fixture, index: usize) []const u8 {
        return (self.server.requestAt(index) orelse return "").body();
    }
};

fn prefix(a: std.mem.Allocator, body: []const u8) ![2][]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    var out: [2][]u8 = undefined;
    for ([_][]const u8{ "system", "tools" }, 0..) |key, i| {
        const value = parsed.value.object.get(key) orelse return error.MissingField;
        out[i] = try std.json.Stringify.valueAlloc(a, value, .{});
    }
    return out;
}

fn expectSamePrefix(a: std.mem.Allocator, before_body: []const u8, after_body: []const u8) !void {
    const before = try prefix(a, before_body);
    defer for (before) |part| a.free(part);
    const after = try prefix(a, after_body);
    defer for (after) |part| a.free(part);
    for (before, after) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
}

fn toolResult(body: []const u8, id: []const u8) ![]const u8 {
    var key_buf: [64]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "\"tool_use_id\":\"{s}\"", .{id});
    const at = std.mem.indexOf(u8, body, key) orelse return error.ToolResultMissing;
    const end = std.mem.indexOfPos(u8, body, at + key.len, "\"tool_use_id\"") orelse body.len;
    return body[at..end];
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "L2 a skill added during a Run is told before the next request and the Skill tool runs it; the prefix stays the same" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var stage_dir = std.testing.tmpDir(.{});
    defer stage_dir.cleanup();
    try stage_dir.dir.writeFile(std.testing.io, .{ .sub_path = "SKILL.md", .data = try skillMd(aa, "fresh", "Run the fresh steps.") });
    var stage_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const stage = stage_buffer[0..try stage_dir.dir.realPath(std.testing.io, &stage_buffer)];
    const command = try std.fmt.allocPrint(aa, "{{\"command\":\"mkdir -p \\\"$HOME/.claude/skills/fresh\\\" && cp '{s}/SKILL.md' \\\"$HOME/.claude/skills/fresh/SKILL.md\\\"\"}}", .{stage});
    const responses = [_][]const u8{
        try toolCall(aa, "tu_install", "Bash", command),
        try toolCall(aa, "tu_fresh", "Skill", "{\"name\":\"fresh\"}"),
        FINAL_SSE,
    };
    var fixture: Fixture = undefined;
    try fixture.setup(&responses, &.{"alpha"});
    defer fixture.deinit();

    try fixture.run("add the fresh skill and use it");

    try std.testing.expectEqual(@as(usize, 3), fixture.server.requestCount());
    const first = fixture.request(0);
    const second = fixture.request(1);
    try std.testing.expect(!contains(first, "fresh skill describes itself"));
    try expectSamePrefix(a, first, second);
    try std.testing.expect(contains(second, "Skills changed during this session."));
    try std.testing.expect(contains(second, "- fresh — The fresh skill describes itself"));
    const ran = try toolResult(fixture.request(2), "tu_fresh");
    try std.testing.expect(contains(ran, "Run the fresh steps."));
    try std.testing.expect(fixture.app.currentSkills() != &fixture.app.skills);
    try std.testing.expectEqual(@as(usize, 1), fixture.app.skills.len());
    try std.testing.expectEqual(@as(usize, 2), fixture.app.currentSkills().len());
}

test "L2 an edited SKILL.md alone is told as changed and used by the next call; a removed skill is then reported gone and refused" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const responses = [_][]const u8{
        FINAL_SSE,
        try toolCall(aa, "tu_alpha", "Skill", "{\"name\":\"alpha\"}"),
        FINAL_SSE,
        try toolCall(aa, "tu_beta", "Skill", "{\"name\":\"beta\"}"),
        FINAL_SSE,
    };
    var fixture: Fixture = undefined;
    try fixture.setup(&responses, &.{ "alpha", "beta" });
    defer fixture.deinit();

    try fixture.run("hello");
    try fixture.writeSkill("alpha", "Run the second steps, which are longer.");
    try fixture.run("use alpha");

    try expectSamePrefix(a, fixture.request(0), fixture.request(1));
    const edited = fixture.request(1);
    try std.testing.expect(contains(edited, "Skills whose SKILL.md changed (the Skill tool uses the new one):\\n- alpha\\n"));
    try std.testing.expect(!contains(edited, "no longer available"));
    try std.testing.expect(contains(try toolResult(fixture.request(2), "tu_alpha"), "Run the second steps, which are longer."));

    @import("platform").sync.sleepMs(1100);
    try fixture.removeSkill("beta");
    try fixture.run("use beta");

    try std.testing.expectEqual(@as(usize, 5), fixture.server.requestCount());
    const removed = fixture.request(3);
    try std.testing.expect(contains(removed, "The following skills are no longer available; the Skill tool refuses them:\\n- beta\\n"));
    const refused = try toolResult(fixture.request(4), "tu_beta");
    try std.testing.expect(!contains(refused, "Run the first steps."));
    try std.testing.expect(contains(refused, "\"is_error\":true"));
}

test "L2 a session that started without skills gets the Skill tool once one is added" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const responses = [_][]const u8{
        FINAL_SSE,
        try toolCall(aa, "tu_late", "Skill", "{\"name\":\"late\"}"),
        FINAL_SSE,
    };
    var fixture: Fixture = undefined;
    try fixture.setup(&responses, &.{});
    defer fixture.deinit();

    try fixture.run("hello");
    try std.testing.expect(!contains(fixture.request(0), "\"name\":\"Skill\""));
    try fixture.writeSkill("late", "Run the late steps.");
    try fixture.run("use it");

    const told = fixture.request(1);
    try std.testing.expect(contains(told, "\"name\":\"Skill\""));
    try std.testing.expect(contains(told, "- late — The late skill describes itself"));
    try std.testing.expect(contains(try toolResult(fixture.request(2), "tu_late"), "Run the late steps."));
}
