//! L2 component test: the built-in System-One advisor default reaches
//! `App.init` exactly when the host opts in (`Config.jev_builtin_default`,
//! which the CLI sets), advises only `scoped_recall`, and config.json narrows,
//! widens or turns it off.
//!
//! The build exports `METACODES_JEV_URL=off` to every step, so each case clears
//! the METACODES_JEV_* variables first and restores them afterwards.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const ppaths = @import("platform").paths;

const jev = cc.jev_runtime;

const END_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const EnvGuard = struct {
    allocator: std.mem.Allocator,
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(allocator: std.mem.Allocator, name: [*:0]const u8, value: ?[*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try allocator.dupeZ(u8, std.mem.span(raw)) else null;
        if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
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

const jev_variables = [_][*:0]const u8{ jev.ENV_URL, jev.ENV_MODE, jev.ENV_TIMEOUT_MS, jev.ENV_MODEL, jev.ENV_DECISIONS };

/// Start an App over `state_root` with no METACODES_JEV_* set, and hand it to
/// `check`. `config_json` is written to `<state_root>/config.json` first.
fn withApp(
    state_root: []const u8,
    config_json: ?[]const u8,
    builtin_default: bool,
    comptime check: fn (app: *cc.app_module.App) anyerror!void,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server = try harness.MockServer.start(END_TURN_SSE, 0);
    defer server.stop();
    const url_z = try allocator.dupeZ(u8, try server.urlOwned(allocator));

    const config_path = try std.fs.path.join(allocator, &.{ state_root, "config.json" });
    if (config_json) |bytes| {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = config_path, .data = bytes });
    } else {
        std.Io.Dir.cwd().deleteFile(std.testing.io, config_path) catch {};
    }

    var guards: [jev_variables.len]EnvGuard = undefined;
    for (jev_variables, 0..) |name, index| guards[index] = try EnvGuard.set(allocator, name, null);
    defer for (&guards) |*guard| guard.restore();
    const home_z = try allocator.dupeZ(u8, state_root);
    var home_guard = try EnvGuard.set(allocator, "HOME", home_z.ptr);
    defer home_guard.restore();
    var probe_guard = try EnvGuard.set(allocator, "METACODES_NO_PROBE", "1");
    defer probe_guard.restore();

    const argv = [_][*:0]const u8{ "metacodes", "--base-url", url_z.ptr, "--model", "glm-5.2" };
    var config = cc.parseArgsForTest(&argv, allocator);
    try std.testing.expect(config.parse_error == null);
    config.state_root = state_root;
    config.jev_builtin_default = builtin_default;

    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    const app = try cc.app_module.App.init(allocator, io_runtime.io(), config, "test-key");
    defer app.deinit();
    try check(app);
}

fn expectBuiltinAdvisor(app: *cc.app_module.App) anyerror!void {
    const runtime = app.jev orelse return error.TestExpectedAdvisor;
    const expected_url = jev.BUILTIN_DEFAULT.url.? ++ "/v1/systemone";
    try std.testing.expectEqualStrings(expected_url, runtime.client.url);
    try std.testing.expectEqual(cc.jev_advisor.Mode.advisory, runtime.advisor.mode);
    try std.testing.expect(runtime.advisor.actuates());
    // Only the recall gate is advised; the other surfaces run as with no
    // advisor (the narrowing itself is proven in jev_memory_plane_test.zig).
    try std.testing.expect(runtime.advisor.advises(.scoped_recall));
    try std.testing.expect(!runtime.advisor.advises(.recall_evidence));
    try std.testing.expect(!runtime.advisor.advises(.memory_relation));
    try std.testing.expect(!runtime.advisor.advises(.enumeration_intent));
}

fn expectBuiltinAdvisorAllSurfaces(app: *cc.app_module.App) anyerror!void {
    const runtime = app.jev orelse return error.TestExpectedAdvisor;
    const expected_url = jev.BUILTIN_DEFAULT.url.? ++ "/v1/systemone";
    try std.testing.expectEqualStrings(expected_url, runtime.client.url);
    try std.testing.expectEqual(cc.jev_advisor.Mode.advisory, runtime.advisor.mode);
    try std.testing.expect(runtime.advisor.surfaces.eql(.initFull()));
}

fn expectNoAdvisor(app: *cc.app_module.App) anyerror!void {
    try std.testing.expect(app.jev == null);
    try std.testing.expect(app.jevAdvisor() == null);
}

fn expectFileAdvisor(app: *cc.app_module.App) anyerror!void {
    const runtime = app.jev orelse return error.TestExpectedAdvisor;
    try std.testing.expectEqualStrings("http://127.0.0.1:9/v1/systemone", runtime.client.url);
    try std.testing.expectEqual(cc.jev_advisor.Mode.shadow, runtime.advisor.mode);
}

fn tmpRoot(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    return buf[0..try tmp.dir.realPath(std.testing.io, buf)];
}

test "L2 jev default: a CLI host with nothing configured gets the built-in advisor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    try withApp(root, null, true, expectBuiltinAdvisor);
    // A config.json about something else keeps the default.
    try withApp(root, "{\"mcp_servers\":{}}", true, expectBuiltinAdvisor);
}

test "L2 jev default: a host that does not opt in gets no advisor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    try withApp(root, null, false, expectNoAdvisor);
}

test "L2 jev default: config.json overrides or turns off the built-in advisor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    try withApp(root, "{\"jev\":false}", true, expectNoAdvisor);
    try withApp(root, "{\"jev\":{\"url\":\"\"}}", true, expectNoAdvisor);
    try withApp(root, "{\"jev\":{\"url\":\"http://127.0.0.1:9\",\"mode\":\"shadow\"}}", true, expectFileAdvisor);
    // `decisions` alone replaces the default's surface list and keeps its service.
    try withApp(
        root,
        "{\"jev\":{\"decisions\":[\"scoped_recall\",\"recall_evidence\",\"memory_relation\",\"enumeration_intent\"]}}",
        true,
        expectBuiltinAdvisorAllSurfaces,
    );
}
