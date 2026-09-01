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
    const prompt = "Reply with one short sentence. You may use the Host Echo tool if useful.";
    // Optional multimodal turn: METACODES_IMAGE=<path.png|jpg|jpeg|gif|webp>
    // attaches the image beside the prompt as one ordered text+image user
    // record, and METACODES_PDF=<path.pdf> attaches a PDF document the same
    // way. Capability gating stays in core and the two capabilities are
    // independent: a non-vision model fails with ImageInputUnsupported and a
    // model without native document input fails with DocumentInputUnsupported,
    // both before any network I/O. Setting both selects the PDF turn; this
    // example demonstrates one attachment kind at a time.
    const result = if (std.c.getenv("METACODES_PDF")) |pdf_env| blk: {
        const pdf_path = std.mem.span(pdf_env);
        const raw = std.Io.Dir.cwd().readFileAlloc(
            init.io,
            pdf_path,
            allocator,
            .limited(mc.pdf.MAX_PDF_BYTES + 1),
        ) catch |err| {
            std.debug.print("[example] METACODES_PDF {s}: {s}\n", .{ pdf_path, @errorName(err) });
            return;
        };
        // Admission before encoding: not a PDF, encrypted, or over the byte or
        // page limit fails here rather than being converted to something else.
        const pages = mc.pdf.inspect(raw) catch |err| {
            std.debug.print("[example] METACODES_PDF {s}: {s}\n", .{ pdf_path, mc.pdf.errorCode(err) });
            return;
        };
        const encoder = std.base64.standard.Encoder;
        const encoded = try allocator.alloc(u8, encoder.calcSize(raw.len));
        _ = encoder.encode(encoded, raw);
        break :blk session.runUserParts(
            1,
            &.{
                .{ .text = prompt },
                .{ .document = .{
                    .media_type = mc.pdf.MEDIA_TYPE,
                    .data = encoded,
                    .title = std.fs.path.basename(pdf_path),
                    .pages = pages,
                } },
            },
            4,
            .{ .ctx = &sink_context, .emit = PrintSink.emit },
        );
    } else if (std.c.getenv("METACODES_IMAGE")) |image_env| blk: {
        const image_path = std.mem.span(image_env);
        const media_type = mc.tool_read.imageMediaType(image_path) orelse {
            std.debug.print("[example] METACODES_IMAGE: unsupported image type: {s}\n", .{image_path});
            return;
        };
        // limit semantics are reached-or-exceeded, so +1 admits a file of
        // exactly MAX_IMAGE_BYTES and still rejects anything larger.
        const raw = std.Io.Dir.cwd().readFileAlloc(
            init.io,
            image_path,
            allocator,
            .limited(mc.tool_read.MAX_IMAGE_BYTES + 1),
        ) catch |err| {
            std.debug.print("[example] METACODES_IMAGE {s}: {s}\n", .{ image_path, @errorName(err) });
            return;
        };
        const encoder = std.base64.standard.Encoder;
        const encoded = try allocator.alloc(u8, encoder.calcSize(raw.len));
        _ = encoder.encode(encoded, raw);
        break :blk session.runUserParts(
            1,
            &.{
                .{ .text = prompt },
                .{ .image = .{ .media_type = media_type, .data = encoded } },
            },
            4,
            .{ .ctx = &sink_context, .emit = PrintSink.emit },
        );
    } else session.runText(
        1,
        prompt,
        4,
        .{ .ctx = &sink_context, .emit = PrintSink.emit },
    );
    const run = result catch |err| {
        std.debug.print("\n[example] run error: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print(
        "\n[example] stop={s} turns={d} tool_calls={d} plugin_calls={d} releases={d}\n",
        .{
            @tagName(run.stop_reason),
            run.turns,
            run.tool_calls,
            embedding.calls,
            embedding.releases,
        },
    );
}
