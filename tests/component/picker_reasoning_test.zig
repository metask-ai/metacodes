//! L2 evidence: a reasoning level chosen in the `/model` picker is the level
//! the next request carries.
//!
//! Before: the options step of the picker had no key that applied a route
//! (Enter cycled a value), and a level committed through the kernel stayed in
//! the selection without reaching the client, so the request went out with
//! whatever level the session had before.
//!
//! The route is a configured relay on the OpenAI wire whose model declares a
//! `reasoning_effort` control, served by a MockServer; the session starts on
//! the historical Metask path and switches to the relay through the picker.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const ppaths = @import("platform").paths;

const App = cc.app_module.App;
const picker_host = cc.repl_picker_host;

const RELAY_KEY = "relay-secret";
const RELAY_ENV = "HOUSE_RELAY_TOKEN";

const OPENAI_END_TURN_SSE =
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}\n\n" ++
    "data: [DONE]\n\n";

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

const cleared_variables = [_][*:0]const u8{
    "METASK_API_KEY",
    "METASK_GATEWAY_URL",
    "METACODES_PROVIDER",
    "METACODES_CONFIG_FILE",
};

/// A scratch state root as HOME holding a relay whose model declares a
/// reasoning control; the relay key in its own variable; no probe, no KG.
const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8,
    root: []const u8,
    guards: [cleared_variables.len + 4]EnvGuard,
    guard_count: usize,

    fn init(self: *Case, relay_origin: []const u8) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.tmp = std.testing.tmpDir(.{});
        self.guard_count = 0;
        self.root = self.root_buf[0..try self.tmp.dir.realPath(std.testing.io, &self.root_buf)];
        const allocator = self.arena.allocator();
        for (cleared_variables) |name| try self.setEnv(name, null);
        try self.setEnv("HOME", (try allocator.dupeZ(u8, self.root)).ptr);
        try self.setEnv("METACODES_NO_PROBE", "1");
        try self.setEnv("METACODES_KG_AUTOSTART", "0");
        try self.setEnv(RELAY_ENV, RELAY_KEY);

        const definition = try std.fmt.allocPrint(allocator,
            \\{{"custom_providers": {{"house-relay": {{
            \\  "display_name": "House relay",
            \\  "credential_kinds": ["api_key"],
            \\  "env_aliases": [{{"name": "{s}", "kind": "api_key", "canonical": true}}],
            \\  "channels": [{{"id": "primary", "base_url": "{s}/relay/v1", "protocol": "openai_chat"}}],
            \\  "models": [{{"request_model_id": "relay-reasoner", "display_name": "Relay reasoner",
            \\    "controls": [{{"id": "reasoning_effort", "label": "Reasoning effort", "kind": "enumeration",
            \\                  "values": ["low", "high", "max"]}}]}}]}}}}}}
        , .{ RELAY_ENV, relay_origin });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.json", .data = definition });
    }

    fn setEnv(self: *Case, name: [*:0]const u8, value: ?[*:0]const u8) !void {
        for (self.guards[0..self.guard_count]) |*guard| {
            if (std.mem.orderZ(u8, guard.name, name) == .eq) {
                if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
                return;
            }
        }
        self.guards[self.guard_count] = try EnvGuard.set(self.arena.allocator(), name, value);
        self.guard_count += 1;
    }

    fn deinit(self: *Case) void {
        var index = self.guard_count;
        while (index > 0) {
            index -= 1;
            self.guards[index].restore();
        }
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn config(self: *Case) !cc.types_mod.Config {
        const argv = [_][*:0]const u8{"metacodes"};
        var parsed = cc.parseArgsForTest(&argv, self.arena.allocator());
        try std.testing.expect(parsed.parse_error == null);
        parsed.state_root = self.root;
        return parsed;
    }
};

fn sendOneTurn(app: *App) !void {
    const messages = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    var handle = try app.provider().sendStream(&messages, null, null, null, null, null, "");
    defer handle.deinit();
    while (try handle.next()) |event| switch (event) {
        .text => |text| app.allocator.free(text),
        else => {},
    };
}

/// Open the picker as `/model` does and put the cursor on the relay's model.
fn openRelayOptions(app: *App, ui: *cc.tui_ui_state.UiState) !void {
    picker_host.open(app, ui, .unguarded);
    // The whole id: the filter is a subsequence match, and "house" alone
    // also matches Metask's `anthropic/claude-sonnet-4-6`.
    for ("house-relay") |byte| _ = picker_host.onKey(app, ui, .{ .char = byte }, .unguarded);
    // The relay's one model, the cursor on it; it declares a control, shown
    // on the line under the list.
    try std.testing.expectEqual(cc.repl_model_picker.Stage.list, app.model_picker.stage);
    const offer = app.model_picker.focusedOffer() orelse return error.NoFocusedRoute;
    try std.testing.expect(cc.repl_model_picker.firstEnumeration(offer.controls) != null);
}

/// The reasoning level the focused route shows (and Enter would commit).
fn shownLevel(app: *App) ?[]const u8 {
    const offer = app.model_picker.focusedOffer() orelse return null;
    const spec = cc.repl_model_picker.firstEnumeration(offer.controls) orelse return null;
    return app.model_picker.effectiveValue(spec);
}

test "L2 picker: a reasoning level chosen on the line under the list is the one the request carries" {
    var gateway = try harness.MockServer.start(OPENAI_END_TURN_SSE, 0);
    defer gateway.stop();
    const messages_url = try gateway.urlOwned(std.testing.allocator);
    defer std.testing.allocator.free(messages_url);
    var case: Case = undefined;
    try case.init(messages_url[0 .. messages_url.len - "/v1/messages".len]);
    defer case.deinit();
    const allocator = case.arena.allocator();

    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), try case.config(), "metask-key");
    defer app.deinit();

    var ui: cc.tui_ui_state.UiState = .{};
    try openRelayOptions(app, &ui);
    // → walks the vocabulary: low, then high.
    _ = picker_host.onKey(app, &ui, .right, .unguarded);
    _ = picker_host.onKey(app, &ui, .right, .unguarded);
    try std.testing.expectEqualStrings("high", shownLevel(app).?);
    // Enter applies the route with the value shown.
    try std.testing.expectEqual(picker_host.Result.committed, picker_host.onKey(app, &ui, .enter, .unguarded));
    try std.testing.expectEqualStrings("relay-reasoner", app.activeModel());
    try std.testing.expectEqual(@as(?cc.types_mod.ReasoningEffort, .high), app.config.reasoning_effort);

    try sendOneTurn(app);
    const captured = gateway.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expectEqualStrings("\"relay-reasoner\"", captured.jsonField("model").?);
    try std.testing.expectEqualStrings("\"high\"", captured.jsonField("reasoning_effort").?);
}

test "L2 picker: the level the session runs with starts selected and survives the switch" {
    var gateway = try harness.MockServer.start(OPENAI_END_TURN_SSE, 0);
    defer gateway.stop();
    const messages_url = try gateway.urlOwned(std.testing.allocator);
    defer std.testing.allocator.free(messages_url);
    var case: Case = undefined;
    try case.init(messages_url[0 .. messages_url.len - "/v1/messages".len]);
    defer case.deinit();
    const allocator = case.arena.allocator();

    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), try case.config(), "metask-key");
    defer app.deinit();
    try app.setReasoningEffort(.max);

    var ui: cc.tui_ui_state.UiState = .{};
    try openRelayOptions(app, &ui);
    // The relay offers `max`, so it is already the selected value.
    try std.testing.expectEqualStrings("max", shownLevel(app).?);
    try std.testing.expectEqual(picker_host.Result.committed, picker_host.onKey(app, &ui, .enter, .unguarded));
    try std.testing.expectEqual(@as(?cc.types_mod.ReasoningEffort, .max), app.config.reasoning_effort);

    try sendOneTurn(app);
    const captured = gateway.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expectEqualStrings("\"max\"", captured.jsonField("reasoning_effort").?);
}
