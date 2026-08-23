//! Independent in-process Host fixture for `metacodes-core`.
//!
//! The Host contributes one trusted static plugin, hot-swaps the shipped core
//! capability profile, observes each immutable plugin inventory, creates a
//! stateful AgentSession, and consumes typed CoreEvents. AgentLoop,
//! permissions, cancellation, Conversation ownership, and tool dispatch remain
//! kernel-owned.
//!
//! Without a key this still proves Runtime/plugin composition:
//!   env -u METACODES_API_KEY zig build example
//! With a key it additionally runs one live turn:
//!   METACODES_API_KEY=sk-... zig build example

const std = @import("std");
const mc = @import("metacodes-core");

const ExampleHost = struct {
    calls: usize = 0,
    releases: usize = 0,

    fn execute(
        raw: *anyopaque,
        identity: mc.agent_session.HostRunIdentity,
        args: []const u8,
    ) error{OutOfMemory}!mc.agent_session.HostToolOutcome {
        const self: *ExampleHost = @ptrCast(@alignCast(raw));
        self.calls += 1;
        std.debug.print(
            "[plugin tool] session={s} run={d} args={s}\n",
            .{ identity.identity.session_id.asSlice(), identity.identity.run_id, args },
        );
        return .{ .ok = .{
            .bytes = "echo accepted by embedding Host",
            .release_ctx = raw,
            .releaseFn = release,
        } };
    }

    fn release(raw: *anyopaque, _: []const u8) void {
        const self: *ExampleHost = @ptrCast(@alignCast(raw));
        self.releases += 1;
    }

    fn tool(self: *ExampleHost) mc.agent_session.HostSyncTool {
        return .{
            .definition = .{
                // Local name: Runtime publishes `example_dembed__Echo`.
                .name = "Echo",
                .description = "A trusted tool supplied by the embedding Host",
                .input_schema = .{
                    .type = "object",
                    .prop_specs = &.{.{
                        .name = "text",
                        .type = "string",
                        .description = "Text to acknowledge",
                    }},
                    .required = &.{"text"},
                },
            },
            .ctx = self,
            .execute = execute,
            .category = .execute,
        };
    }
};

const PrintSink = struct {
    fn emit(
        _: *anyopaque,
        _: mc.session_id.SessionId,
        _: u64,
        event: mc.protocol.ui_event.CoreEvent,
    ) bool {
        switch (event) {
            .text_chunk => |text| std.debug.print("{s}", .{text}),
            .tool_start => |start| std.debug.print(
                "\n[tool_start] {s} {s}\n",
                .{ start.name, start.input },
            ),
            .tool_result => |result| std.debug.print(
                "[tool_result] {s} (is_error={})\n",
                .{ result.name, result.is_error },
            ),
            .stream_done => std.debug.print("\n", .{}),
            else => {},
        }
        return true;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var embedding = ExampleHost{};

    const plugins = [_]mc.agent_session.StaticPlugin{.{
        .descriptor = .{
            .id = try mc.plugin.contract.PluginId.parse("example.embed"),
            .version = try mc.plugin.contract.Version.parse("1.0.0"),
            .form = .static_trusted,
            .capabilities = mc.plugin.contract.CapabilitySet.from(&.{.host_tool}),
        },
        .tools = &.{embedding.tool()},
    }};
    const runtime_host = try mc.agent_session.RuntimeHost.create(allocator, .{
        .core_profile = .minimal,
        .static_plugins = &plugins,
    });
    defer runtime_host.destroy() catch unreachable;

    const initial_inventory = try runtime_host.describePlugins(allocator);
    std.debug.print("[plugin inventory generation 1] {s}\n", .{initial_inventory});
    const generation = try runtime_host.replace(.{
        .core_profile = .coding,
        .static_plugins = &plugins,
    });
    const current_inventory = try runtime_host.describePlugins(allocator);
    std.debug.print(
        "[plugin inventory generation {d}] {s}\n",
        .{ @intFromEnum(generation), current_inventory },
    );

    const api_key = if (std.c.getenv("METACODES_API_KEY")) |value|
        std.mem.span(value)
    else {
        std.debug.print(
            "plugin composition succeeded; set METACODES_API_KEY to run a live AgentSession\n",
            .{},
        );
        return;
    };
    const model = if (std.c.getenv("METACODES_MODEL")) |value|
        std.mem.span(value)
    else
        "claude-3-5-haiku-20241022";
    const base_url: ?[]const u8 = if (std.c.getenv("METACODES_BASE_URL")) |value|
        std.mem.span(value)
    else
        null;
    const cwd = try mc.util_fs.getCwd(allocator);

    const session = try runtime_host.createSession(.{
        .provider_kind = .anthropic,
        .api_key = api_key,
        .model = model,
        .base_url = base_url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = cwd },
        .allowed_tools = &.{ "Read", "example_dembed__Echo" },
        .host_identity_ctx = &embedding,
    });
    defer session.destroy() catch unreachable;

    var sink_context: u8 = 0;
    const result = session.runText(
        1,
        "Reply with one short sentence. You may use the Host Echo tool if useful.",
        4,
        .{ .ctx = &sink_context, .emit = PrintSink.emit },
    ) catch |err| {
        std.debug.print("\n[example] run error: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print(
        "\n[example] stop={s} turns={d} tool_calls={d} plugin_calls={d} releases={d}\n",
        .{
            @tagName(result.stop_reason),
            result.turns,
            result.tool_calls,
            embedding.calls,
            embedding.releases,
        },
    );
}
