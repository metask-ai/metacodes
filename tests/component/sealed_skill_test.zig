//! L2: a sealed Skill (doc/SEALED_SKILL_PROTOCOL.md) runs end to end through
//! real modules: the reference gateway whose brain is the real agent loop, the
//! client's pin store and catalog, the forked subagent loop with the gateway
//! as its Provider, local tool execution, the policy frame, the confirm gate,
//! the credential store and the usage ledger. The model is a mock Anthropic
//! SSE server that plays the *client's* provider: the gateway reaches it over
//! the route and credential the client sends (§8.1). Only the two
//! process-external boundaries (the model's HTTP and the gateway's HTTP) are
//! mocked or loopback-served.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const pfs = @import("platform").fs;

const protocol = cc.skills_sealed_protocol;
const transport = cc.skills_sealed_transport;
const pin_mod = cc.skills_sealed_pin;
const gateway_mod = cc.skills_sealed_gateway;
const credentials = cc.skills_sealed_credentials;
const ui_request = cc.ui_request;

const SECRET_BODY = "SECRET_SKILL_BODY: read the data file the user names and summarize it.";
const SKILL_MD = "---\nname: erp-post\ndescription: Posts invoices. Use when asked to post an invoice.\n---\n" ++ SECRET_BODY ++ "\n";
const CLIENT_KEY = "client-key-7f3a";
const CLIENT_MODEL = "claude-sonnet-4-20250514";
const STATE_KEY = [_]u8{7} ** 32;

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_f\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":40,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"final-from-sealed\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn escapeJson(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var escaped: std.ArrayList(u8) = .empty;
    errdefer escaped.deinit(allocator);
    for (raw) |c| switch (c) {
        '"' => try escaped.appendSlice(allocator, "\\\""),
        '\\' => try escaped.appendSlice(allocator, "\\\\"),
        else => try escaped.append(allocator, c),
    };
    return escaped.toOwnedSlice(allocator);
}

/// One assistant turn that ends with `text` and no tool call.
fn finalSse(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const escaped = try escapeJson(allocator, text);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_f\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":40,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"{s}\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"end_turn\"}},\"usage\":{{\"output_tokens\":5}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{escaped},
    );
}

/// One assistant turn calling `tool` with `input_json` (already a JSON object).
fn toolCallSse(allocator: std.mem.Allocator, tool: []const u8, input_json: []const u8) ![]u8 {
    return toolCallSseWithText(allocator, "", tool, input_json);
}

/// One assistant turn: optional narration `text`, then a call of `tool`.
fn toolCallSseWithText(allocator: std.mem.Allocator, text: []const u8, tool: []const u8, input_json: []const u8) ![]u8 {
    const escaped = try escapeJson(allocator, input_json);
    defer allocator.free(escaped);
    const escaped_text = try escapeJson(allocator, text);
    defer allocator.free(escaped_text);
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_t\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":30,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"{s}\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{s}\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":1}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":9}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{ escaped_text, tool, escaped },
    );
}

/// One assistant turn with two tool calls (`tu_a` then `tu_b`).
fn twoCallSse(allocator: std.mem.Allocator, tool_a: []const u8, input_a: []const u8, tool_b: []const u8, input_b: []const u8) ![]u8 {
    const escaped_a = try escapeJson(allocator, input_a);
    defer allocator.free(escaped_a);
    const escaped_b = try escapeJson(allocator, input_b);
    defer allocator.free(escaped_b);
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_t\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":30,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_a\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{s}\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_b\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{s}\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":1}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":9}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{ tool_a, escaped_a, tool_b, escaped_b },
    );
}

fn writeFileAt(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    try cc.util_fs.mkdirParentsOf(path);
    const z = try allocator.dupeZ(u8, path);
    defer allocator.free(z);
    const fd = pfs.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (fd < 0) return error.FixtureWriteFailed;
    defer pfs.close(fd);
    const n = pfs.write(fd, bytes);
    if (n < 0 or @as(usize, @intCast(n)) != bytes.len) return error.FixtureWriteFailed;
}

fn readFileAt(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const z = try allocator.dupeZ(u8, path);
    defer allocator.free(z);
    const fd = pfs.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (fd < 0) return null;
    defer pfs.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &chunk);
        if (n < 0) return error.FixtureReadFailed;
        if (n == 0) break;
        try out.appendSlice(allocator, chunk[0..@intCast(n)]);
    }
    return try out.toOwnedSlice(allocator);
}

const Host = struct {
    fn activate(_: *anyopaque, _: []const u8, _: []const []const u8, _: []const []const u8) anyerror!void {}
};

/// The session's UI channel, as the client sees it: it answers permission
/// prompts with `permission_answer` and question dialogs with
/// `question_answer`, and records what it was asked.
const UiProbe = struct {
    permission_answer: ui_request.PermissionChoice = .allow_once,
    /// Null means no front end can take a question (the requester reports
    /// `unavailable`).
    question_answer: ?[]const u8 = "main",
    permission_requests: usize = 0,
    question_requests: usize = 0,
    last_permission_tool: [64]u8 = undefined,
    last_permission_tool_len: usize = 0,
    last_question: [256]u8 = undefined,
    last_question_len: usize = 0,
    last_question_options: usize = 0,

    fn requester(self: *UiProbe) ui_request.UiRequester {
        return .{ .ctx = @ptrCast(self), .requestFn = &request };
    }

    fn request(ctx: *anyopaque, _: ui_request.SessionId, allocator: std.mem.Allocator, req: *const ui_request.UiRequest, out: *ui_request.UiResponse) anyerror!ui_request.RequestOutcome {
        const self: *UiProbe = @ptrCast(@alignCast(ctx));
        switch (req.*) {
            .permission => |p| {
                self.permission_requests += 1;
                const n = @min(p.tool.len, self.last_permission_tool.len);
                @memcpy(self.last_permission_tool[0..n], p.tool[0..n]);
                self.last_permission_tool_len = n;
                out.* = .{ .permission = self.permission_answer };
                return .answered;
            },
            .ask_question => |questions| {
                self.question_requests += 1;
                if (questions.len != 0) {
                    const n = @min(questions[0].question.len, self.last_question.len);
                    @memcpy(self.last_question[0..n], questions[0].question[0..n]);
                    self.last_question_len = n;
                    self.last_question_options = questions[0].options.len;
                }
                const answer = self.question_answer orelse return .unavailable;
                const answers = try allocator.alloc([]const u8, questions.len);
                for (answers) |*slot| slot.* = try allocator.dupe(u8, answer);
                out.* = .{ .answers = answers };
                return .answered;
            },
            .custom => return .unavailable,
        }
    }

    fn lastPermissionTool(self: *const UiProbe) []const u8 {
        return self.last_permission_tool[0..self.last_permission_tool_len];
    }

    fn lastQuestion(self: *const UiProbe) []const u8 {
        return self.last_question[0..self.last_question_len];
    }
};

const PackageFile = struct { path: []const u8, bytes: []const u8 };

/// Everything one scenario needs: the mock model (the client's provider), the
/// gateway, and a client whose catalog holds the pinned Skill.
const Lab = struct {
    allocator: std.mem.Allocator,
    root: []u8,
    packages_dir: []u8,
    state_dir: []u8,
    data_path: []u8,
    model: *harness.MockServer,
    model_url: []u8,
    /// The client's own provider: the route the gateway is given.
    owned: cc.api_provider_factory.OwnedProvider,
    gateway: *gateway_mod.Gateway,
    server: *gateway_mod.Server,
    gateway_url: []u8,
    io_runtime: std.Io.Threaded,
    runtime: cc.skills_cli_adapter.Runtime,
    projection: cc.skills.SkillSet,
    registry: cc.tools_dynamic.DynRegistry,
    abort: cc.util_abort.AbortSignal,
    permission: cc.permission.PermissionContext,
    tool_defs: []cc.json_mod.ToolDefinition,
    probe: UiProbe,
    /// The builtin agents, so a fork builds the real subagent prompt (the
    /// general-purpose profile with the codebase context) as the App's does.
    agents: cc.agents_set.AgentSet,
    host_token: u8 = 0,

    fn start(self: *Lab, allocator: std.mem.Allocator, tag: []const u8, cassette: []const []const u8, manifest_json: []const u8, options: gateway_mod.Options) !void {
        return self.startWithFiles(allocator, tag, cassette, manifest_json, options, &.{});
    }

    fn startWithFiles(self: *Lab, allocator: std.mem.Allocator, tag: []const u8, cassette: []const []const u8, manifest_json: []const u8, options: gateway_mod.Options, files: []const PackageFile) !void {
        var root_buf: [512]u8 = undefined;
        const root_slice = cc.util_fs.testing.perPidDir(&root_buf, tag);
        const root = try allocator.dupe(u8, root_slice);
        _ = harness.normalizeSlashes(root);
        self.allocator = allocator;
        self.root = root;
        self.packages_dir = try std.fmt.allocPrint(allocator, "{s}/packages", .{root});
        self.state_dir = try std.fmt.allocPrint(allocator, "{s}/state", .{root});
        self.data_path = try std.fmt.allocPrint(allocator, "{s}/data.txt", .{root});
        const md_path = try std.fmt.allocPrint(allocator, "{s}/erp-post/SKILL.md", .{self.packages_dir});
        defer allocator.free(md_path);
        try writeFileAt(allocator, md_path, SKILL_MD);
        const manifest_path = try std.fmt.allocPrint(allocator, "{s}/erp-post/manifest.json", .{self.packages_dir});
        defer allocator.free(manifest_path);
        try writeFileAt(allocator, manifest_path, manifest_json);
        for (files) |file| {
            const path = try std.fmt.allocPrint(allocator, "{s}/erp-post/{s}", .{ self.packages_dir, file.path });
            defer allocator.free(path);
            try writeFileAt(allocator, path, file.bytes);
        }
        try writeFileAt(allocator, self.data_path, "DATA_MARKER line one\n");
        try cc.util_fs.mkdirParents(self.state_dir);

        self.model = try harness.MockServer.startCassette(cassette, 0);
        self.model_url = try self.model.urlOwned(allocator);
        self.owned = try cc.api_provider_factory.makeProvider(allocator, .anthropic, CLIENT_KEY, CLIENT_MODEL, self.model_url);
        var gateway_options = options;
        if (gateway_options.state_key == null) gateway_options.state_key = STATE_KEY;
        self.gateway = try gateway_mod.Gateway.init(allocator, self.packages_dir, gateway_options);
        self.server = try gateway_mod.Server.start(allocator, self.gateway, 0);
        self.gateway_url = try self.server.url(allocator);

        self.io_runtime = @import("platform").signal.threadedIo(allocator, .{});
        self.runtime = cc.skills_cli_adapter.Runtime.init(allocator, self.io_runtime.io());
        self.projection = cc.skills.SkillSet.init(allocator);
        self.registry = cc.tools_dynamic.DynRegistry.init(allocator);
        self.abort = cc.util_abort.AbortSignal.init();
        self.probe = .{};
        // The permission context carries the session's UI channel into every
        // scoped child, exactly as the App's does.
        self.permission = .{ .mode = .init(.bypass_permissions), .allocator = allocator, .ui_requester = self.probe.requester() };
        self.tool_defs = try cc.tools.toToolDefinitions(allocator);
        self.agents = cc.agents_set.AgentSet.init(allocator);
        try self.agents.loadBuiltins();
    }

    /// Install the Skill the way `metacodes sealed install` does: fetch the
    /// Entry from the gateway, verify it, pin it, and install its public
    /// assets under the pin directory.
    fn install(self: *Lab, token: []const u8) !void {
        var client = try transport.Client.init(self.allocator, self.io_runtime.io(), self.gateway_url, token);
        defer client.deinit();
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        try protocol.writeSkillsGetParams(&params.writer, "ssk_test");
        var response = try client.call(.skills_get, params.written(), null);
        defer response.deinit();
        const entry_json = response.response.result;
        var parsed = try protocol.parseEntry(self.allocator, entry_json);
        defer parsed.deinit();
        try pin_mod.write(self.allocator, self.state_dir, self.gateway_url, "", entry_json, &parsed.entry);
        for (parsed.entry.assets) |asset| {
            var asset_params: std.Io.Writer.Allocating = .init(self.allocator);
            defer asset_params.deinit();
            try protocol.writeSkillsAssetParams(&asset_params.writer, parsed.entry.skill_id, asset.path);
            var asset_response = try client.call(.skills_asset, asset_params.written(), null);
            defer asset_response.deinit();
            var fetched = try protocol.parseAsset(self.allocator, asset_response.response.result);
            defer fetched.deinit();
            try std.testing.expectEqualStrings(asset.sha256, fetched.sha256);
            try pin_mod.writeAsset(self.allocator, self.state_dir, parsed.entry.manifest.name, asset.path, fetched.content);
        }
    }

    /// The pin directory: the Skill's base directory as the brain sees it.
    fn pinDir(self: *Lab) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/sealed-skills/erp-post", .{self.state_dir});
    }

    /// Load the client catalog from the pin root (and, when given, a local
    /// skills directory) and register the Skill tool.
    fn loadCatalog(self: *Lab) !void {
        return self.loadCatalogWith(null);
    }

    fn loadCatalogWith(self: *Lab, local_root: ?[]const u8) !void {
        const pin_root = try pin_mod.pinRoot(self.allocator, self.state_dir);
        defer self.allocator.free(pin_root);
        var sources: std.ArrayList(cc.skills_runtime.catalog.Source) = .empty;
        defer sources.deinit(self.allocator);
        try sources.append(self.allocator, .{ .root = pin_root, .scope = .personal, .priority = 2005, .profile = .compat });
        if (local_root) |root| try sources.append(self.allocator, .{ .root = root, .scope = .personal, .priority = 2000, .profile = .compat });
        try self.runtime.loadSources(self.root, "", "", sources.items, &self.projection);
        try cc.skills_tool.registerSkillTool(&self.registry, &self.runtime);
        const model_defs = try cc.tools.toToolDefinitionsWithDyn(self.allocator, &self.registry);
        self.allocator.free(self.tool_defs);
        self.tool_defs = model_defs;
        if (!cc.skills_cli_adapter.applyModelToolSchema(self.tool_defs)) return error.SkillSchemaMissing;
    }

    fn context(self: *Lab) cc.tools.ToolContext {
        var ctx = cc.tools.ToolContext.withAbort(self.allocator, &self.abort);
        // The client's own provider: a local fork calls it directly; a sealed
        // fork hands its route to the gateway.
        ctx.api_client = self.owned.anthropicClient();
        ctx.provider = self.owned.provider();
        ctx.tool_defs = self.tool_defs;
        ctx.permission_ctx = &self.permission;
        ctx.dyn_registry = &self.registry;
        ctx.agents = &self.agents;
        ctx.project_dir = self.root;
        ctx.cwd_abs = self.root;
        ctx.state_root = self.state_dir;
        ctx.session_id = "sess-sealed";
        ctx.host_services = .{ .ctx = @ptrCast(&self.host_token), .activateSkillFn = &Host.activate };
        ctx.ui_requester = self.probe.requester();
        return ctx;
    }

    fn runSkill(self: *Lab, invocation: []const u8) ![]u8 {
        var ctx = self.context();
        const entry = self.registry.find("Skill") orelse return error.SkillToolMissing;
        var body = try entry.execute(&ctx, invocation);
        defer body.deinit(self.allocator);
        return self.allocator.dupe(u8, body.@"inline".bytes);
    }

    fn ledger(self: *Lab) !?[]u8 {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/ledger/sealed.ndjson", .{self.state_dir});
        defer self.allocator.free(path);
        return readFileAt(self.allocator, path);
    }

    /// Every model request (headers and body), concatenated: what the
    /// client's provider saw, and from whom.
    fn allModelRequests(self: *Lab, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var index: usize = 0;
        while (self.model.requestAt(index)) |request| : (index += 1) {
            try out.appendSlice(allocator, request.raw);
            try out.append(allocator, '\n');
        }
        return out.toOwnedSlice(allocator);
    }

    /// Restart the gateway process (same sealing key, same packages) and
    /// point the pin at the new port: a run in flight must survive it.
    fn restartGateway(self: *Lab) !void {
        self.server.stop();
        self.gateway.deinit();
        self.gateway = try gateway_mod.Gateway.init(self.allocator, self.packages_dir, .{ .state_key = STATE_KEY });
        self.server = try gateway_mod.Server.start(self.allocator, self.gateway, 0);
        self.allocator.free(self.gateway_url);
        self.gateway_url = try self.server.url(self.allocator);
    }

    fn stop(self: *Lab) void {
        const a = self.allocator;
        self.agents.deinit();
        self.registry.deinit();
        self.runtime.deinit();
        self.projection.deinit();
        a.free(self.tool_defs);
        self.io_runtime.deinit();
        self.server.stop();
        self.gateway.deinit();
        self.owned.deinit();
        self.model.stop();
        a.free(self.gateway_url);
        a.free(self.model_url);
        cc.util_fs.testing.rmrfBestEffort(self.root);
        a.free(self.data_path);
        a.free(self.state_dir);
        a.free(self.packages_dir);
        a.free(self.root);
        self.* = undefined;
    }
};

/// The value of `key` (`"name":"`) on the first ledger line containing `marker`.
fn ledgerField(ledger: []const u8, marker: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, ledger, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, marker) == null) continue;
        const start = (std.mem.indexOf(u8, line, key) orelse return null) + key.len;
        const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return null;
        return line[start..end];
    }
    return null;
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, index, needle)) |found| : (index = found + needle.len) count += 1;
    return count;
}

fn readDataSse(a: std.mem.Allocator, tag: []const u8) ![]u8 {
    var pre_buf: [512]u8 = undefined;
    const pre_root = harness.normalizeSlashes(@constCast(cc.util_fs.testing.perPidDir(&pre_buf, tag)));
    const read_input = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}/data.txt\"}}", .{pre_root});
    defer a.free(read_input);
    return toolCallSse(a, "Read", read_input);
}

// ── Brain on the gateway, hands and account on the client ─────────────────

test "L2 sealed: brain on the gateway, hands on the client, model on the client's account, charge in the ledger" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    const read_sse = try readDataSse(a, "cc-zig-sealed-e2e");
    defer a.free(read_sse);
    try lab.start(a, "cc-zig-sealed-e2e", &.{ read_sse, FINAL_SSE }, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();

    // The catalog shows the Skill as sealed with an empty-of-content body.
    const record = lab.runtime.findRecord("erp-post") orelse return error.SkillNotInCatalog;
    try std.testing.expect(record.definition.isSealed());
    try std.testing.expect(std.mem.indexOf(u8, record.definition.body, "SECRET") == null);

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"post the invoice in data.txt\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "(forked)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "final-from-sealed") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SECRET_SKILL_BODY") == null);
    // Read is not in `confirmation.required_for`: bypass mode asks nobody.
    try std.testing.expectEqual(@as(usize, 0), lab.probe.permission_requests);
    try std.testing.expectEqual(@as(usize, 0), lab.probe.question_requests);

    // Model request 1, made by the gateway with the client's key and model:
    // the fork's system prompt, the Skill body as the first user turn with
    // the user's arguments, the client's tool definitions; request 2: the
    // locally executed result.
    try std.testing.expectEqual(@as(usize, 2), lab.model.requestCount());
    const first = lab.model.requestAt(0) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, first.raw, CLIENT_KEY) != null);
    try std.testing.expect(std.mem.indexOf(u8, first.body(), "\"model\":\"" ++ CLIENT_MODEL ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.body(), "You are a general-purpose subagent") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.body(), SECRET_BODY) != null);
    try std.testing.expect(std.mem.indexOf(u8, first.body(), "post the invoice in data.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.body(), "\"name\":\"Read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.body(), "\"name\":\"AskUserQuestion\"") != null);
    const second = lab.model.requestAt(1) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "DATA_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "\"tool_use_id\":\"tu_1\"") != null);

    // Ledger: two Steps and one charge, each carrying the gateway's cost;
    // the Step names its call and the one continue digests what was sent (§6.6).
    const ledger = (try lab.ledger()) orelse return error.LedgerMissing;
    defer a.free(ledger);
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(ledger, "\"kind\":\"step\""));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(ledger, "\"kind\":\"results\""));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(ledger, "\"kind\":\"charge\""));
    // Every Step carries the gateway's cost (a results record has none).
    var ledger_lines = std.mem.splitScalar(u8, ledger, '\n');
    while (ledger_lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"kind\":\"step\"") == null) continue;
        try std.testing.expect(std.mem.indexOf(u8, line, "\"cost_micros\":0,") == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"skill_id\":\"ssk_test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"inference_gateway\":\"metacodes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"tool_calls\":[{\"id\":\"tu_1\",\"name\":\"Read\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"results\":[{\"tool_use_id\":\"tu_1\",\"sha256\":\"sha256:") != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"is_error\":false,\"truncated\":false,\"redactions\":[]}]") != null);
    // Contents never enter the ledger, only their digests.
    try std.testing.expect(std.mem.indexOf(u8, ledger, "DATA_MARKER") == null);
    // §8.3: the digest of the results the client sent is bound into the Step
    // the gateway derived from them — the `results` record and the `final`
    // step record carry the same value, and it is not empty.
    const sent_digest = ledgerField(ledger, "\"kind\":\"results\"", "\"results_digest\":\"") orelse return error.ResultsDigestMissing;
    const bound_digest = ledgerField(ledger, "\"step_kind\":\"final\"", "\"results_digest\":\"") orelse return error.ResultsDigestMissing;
    try std.testing.expect(std.mem.startsWith(u8, sent_digest, "sha256:"));
    try std.testing.expectEqualStrings(sent_digest, bound_digest);
    const first_step_digest = ledgerField(ledger, "\"seq\":1,\"step_kind\":\"tool_calls\"", "\"results_digest\":\"") orelse return error.ResultsDigestMissing;
    try std.testing.expectEqualStrings("", first_step_digest);
    // The client's credential went to the model and nowhere else: not into
    // the ledger, not into the fork's output.
    try std.testing.expect(std.mem.indexOf(u8, ledger, CLIENT_KEY) == null);
    try std.testing.expect(std.mem.indexOf(u8, output, CLIENT_KEY) == null);
}

test "L2 sealed: a request without the client's provider credential is refused before any model call" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    try lab.start(a, "cc-zig-sealed-nocred", &.{FINAL_SSE}, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    try lab.install("");

    var client = try transport.Client.init(a, lab.io_runtime.io(), lab.gateway_url, "");
    defer client.deinit();
    var params: std.Io.Writer.Allocating = .init(a);
    defer params.deinit();
    try protocol.writeStartParams(&params.writer, .{
        .skill_id = "ssk_test",
        .manifest_digest = lab.gateway.packages[0].entry.manifest_digest,
        .prompt = "go",
        .max_cost_micros = 1000,
        .max_steps = 10,
        .client_name = "metacodes",
        .client_version = "0",
        .client_platform = "p",
        .provider_kind = "anthropic",
        .provider_base_url = lab.model_url,
        .model = CLIENT_MODEL,
        .max_tokens = 64,
    });
    var response = try client.call(.runs_start, params.written(), null);
    defer response.deinit();
    try std.testing.expect(response.response == .err);
    try std.testing.expect(std.mem.indexOf(u8, response.response.err.message, protocol.PROVIDER_CREDENTIAL_HEADER) != null);
    try std.testing.expectEqual(@as(usize, 0), lab.model.requestCount());
}

test "L2 sealed: provider server tools in runs.start are refused as invalid params before any model call" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    try lab.start(a, "cc-zig-sealed-srvtools", &.{FINAL_SSE}, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    try lab.install("");

    var client = try transport.Client.init(a, lab.io_runtime.io(), lab.gateway_url, "");
    defer client.deinit();
    client.provider_credential = CLIENT_KEY;
    var params: std.Io.Writer.Allocating = .init(a);
    defer params.deinit();
    try protocol.writeStartParams(&params.writer, .{
        .skill_id = "ssk_test",
        .manifest_digest = lab.gateway.packages[0].entry.manifest_digest,
        .prompt = "go",
        .max_cost_micros = 1000,
        .max_steps = 10,
        .client_name = "metacodes",
        .client_version = "0",
        .client_platform = "p",
        .provider_kind = "anthropic",
        .provider_base_url = lab.model_url,
        .provider_tools_json = "[{\"type\":\"web_search_20250305\",\"name\":\"web_search\"}]",
        .model = CLIENT_MODEL,
        .max_tokens = 64,
    });
    var response = try client.call(.runs_start, params.written(), null);
    defer response.deinit();
    try std.testing.expect(response.response == .err);
    try std.testing.expectEqual(@as(i64, -32602), response.response.err.code);
    try std.testing.expect(std.mem.indexOf(u8, response.response.err.message, "provider_tools") != null);
    try std.testing.expectEqual(@as(usize, 0), lab.model.requestCount());
}

test "L2 sealed: a provider kind outside SSP/1 (bedrock) is refused as invalid params before any model call" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    try lab.start(a, "cc-zig-sealed-bedrock", &.{FINAL_SSE}, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    try lab.install("");

    var client = try transport.Client.init(a, lab.io_runtime.io(), lab.gateway_url, "");
    defer client.deinit();
    client.provider_credential = CLIENT_KEY;
    var params: std.Io.Writer.Allocating = .init(a);
    defer params.deinit();
    try protocol.writeStartParams(&params.writer, .{
        .skill_id = "ssk_test",
        .manifest_digest = lab.gateway.packages[0].entry.manifest_digest,
        .prompt = "go",
        .max_cost_micros = 1000,
        .max_steps = 10,
        .client_name = "metacodes",
        .client_version = "0",
        .client_platform = "p",
        .provider_kind = "bedrock",
        .provider_base_url = lab.model_url,
        .model = CLIENT_MODEL,
        .max_tokens = 64,
    });
    var response = try client.call(.runs_start, params.written(), null);
    defer response.deinit();
    try std.testing.expect(response.response == .err);
    try std.testing.expectEqual(@as(i64, -32602), response.response.err.code);
    try std.testing.expectEqual(@as(usize, 0), lab.model.requestCount());
}

test "L2 sealed: the gateway holds no run state — it restarts between two Steps and the run continues" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    const read_sse = try readDataSse(a, "cc-zig-sealed-stateless");
    defer a.free(read_sse);
    try lab.start(a, "cc-zig-sealed-stateless", &.{ read_sse, FINAL_SSE }, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    try lab.install("");

    // Drive the protocol by hand: start, restart the gateway, continue.
    var client = try transport.Client.init(a, lab.io_runtime.io(), lab.gateway_url, "");
    defer client.deinit();
    client.provider_credential = CLIENT_KEY;
    var params: std.Io.Writer.Allocating = .init(a);
    defer params.deinit();
    try protocol.writeStartParams(&params.writer, .{
        .skill_id = "ssk_test",
        .manifest_digest = lab.gateway.packages[0].entry.manifest_digest,
        .prompt = "go",
        .tools_json = "[{\"name\":\"Read\",\"description\":\"read\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"file_path\":{\"type\":\"string\"}},\"required\":[\"file_path\"]}}]",
        .max_cost_micros = 100_000,
        .max_steps = 10,
        .client_name = "metacodes",
        .client_version = "0",
        .client_platform = "p",
        .system = "You are a subagent.",
        .provider_kind = "anthropic",
        .provider_base_url = lab.model_url,
        .model = CLIENT_MODEL,
        .max_tokens = 64,
    });
    var started = try client.call(.runs_start, params.written(), null);
    defer started.deinit();
    try std.testing.expect(started.response == .result);
    var step1 = try protocol.parseStep(a, started.response.result);
    defer step1.deinit();
    try std.testing.expectEqual(protocol.StepKind.tool_calls, step1.step.kind);
    try std.testing.expectEqualStrings("Read", step1.step.calls[0].name);

    try lab.restartGateway();
    var client2 = try transport.Client.init(a, lab.io_runtime.io(), lab.gateway_url, "");
    defer client2.deinit();
    client2.provider_credential = CLIENT_KEY;
    var cont: std.Io.Writer.Allocating = .init(a);
    defer cont.deinit();
    try protocol.writeContinueParams(&cont.writer, step1.step.run_id, step1.step.run_state, step1.step.seq, &.{
        .{ .tool_use_id = step1.step.calls[0].id, .content = "DATA_MARKER from the client" },
    });
    var continued = try client2.call(.runs_continue, cont.written(), null);
    defer continued.deinit();
    if (continued.response == .err) std.debug.print("runs.continue refused: {d} {s}\n", .{ continued.response.err.code, continued.response.err.message });
    try std.testing.expect(continued.response == .result);
    var step2 = try protocol.parseStep(a, continued.response.result);
    defer step2.deinit();
    try std.testing.expectEqual(protocol.StepKind.final, step2.step.kind);
    try std.testing.expectEqualStrings("final-from-sealed", step2.step.text);
    try std.testing.expectEqualStrings(step1.step.digest, step2.step.prev_digest);
    try std.testing.expectEqual(@as(u64, 2), step2.step.seq);
    // §8.3: the Step derived from our results binds their digest.
    const expected_digest = try protocol.resultsDigest(a, &.{
        .{ .tool_use_id = step1.step.calls[0].id, .content = "DATA_MARKER from the client" },
    });
    defer a.free(expected_digest);
    try std.testing.expectEqualStrings(expected_digest, step2.step.results_digest);
    try std.testing.expectEqualStrings("", step1.step.results_digest);
    // The new process made the second model call from the carried state.
    try std.testing.expectEqual(@as(usize, 2), lab.model.requestCount());
    const second = lab.model.requestAt(1) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "DATA_MARKER from the client") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), SECRET_BODY) != null);
}

test "L2 sealed: a call outside the pinned allowlist is refused locally and reported" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    var pre_buf: [512]u8 = undefined;
    const pre_root = harness.normalizeSlashes(@constCast(cc.util_fs.testing.perPidDir(&pre_buf, "cc-zig-sealed-policy")));
    const bash_input = try std.fmt.allocPrint(a, "{{\"command\":\"echo pwned > {s}/pwned.txt\"}}", .{pre_root});
    defer a.free(bash_input);
    const bash_sse = try toolCallSse(a, "Bash", bash_input);
    defer a.free(bash_sse);
    // The manifest allows Read only.
    const manifest = "{\"schema\":\"metask.sealed-skill.manifest/v1\",\"skill_id\":\"ssk_test\",\"version\":\"1.0.0\",\"name\":\"erp-post\",\"description\":\"Posts invoices.\",\"tools\":{\"allow\":[\"Read\"]},\"egress\":{\"classes\":[\"file_contents\"]}}";
    try lab.start(a, "cc-zig-sealed-policy", &.{ bash_sse, FINAL_SSE }, manifest, .{});
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"go\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "final-from-sealed") != null);

    const pwned = try std.fmt.allocPrint(a, "{s}/pwned.txt", .{lab.root});
    defer a.free(pwned);
    try std.testing.expect((try readFileAt(a, pwned)) == null);
    const second = lab.model.requestAt(1) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "\"is_error\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "pwned") == null or std.mem.indexOf(u8, second.body(), "not allowed") != null or std.mem.indexOf(u8, second.body(), "denied") != null);
}

test "L2 sealed: bearer token gates the gateway" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    try lab.start(a, "cc-zig-sealed-auth", &.{FINAL_SSE}, protocol.TEST_MANIFEST_JSON, .{ .token = "t0k-secret" });
    defer lab.stop();

    var anonymous = try transport.Client.init(a, lab.io_runtime.io(), lab.gateway_url, "");
    defer anonymous.deinit();
    try std.testing.expectError(error.Unauthorized, anonymous.call(.discover, "{}", null));

    var wrong = try transport.Client.init(a, lab.io_runtime.io(), lab.gateway_url, "t0k-wrong");
    defer wrong.deinit();
    try std.testing.expectError(error.Unauthorized, wrong.call(.discover, "{}", null));

    var member = try transport.Client.init(a, lab.io_runtime.io(), lab.gateway_url, "t0k-secret");
    defer member.deinit();
    var response = try member.call(.discover, "{}", null);
    defer response.deinit();
    try std.testing.expect(std.mem.indexOf(u8, response.response.result, protocol.PROTOCOL_ID) != null);
    try std.testing.expect(std.mem.indexOf(u8, response.response.result, "\"client_provider\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.response.result, "\"input_required\":true") != null);
}

test "L2 sealed: a second gateway on a port in use is refused, not shared" {
    // `metacodes sealed serve` started twice on one port: the second start
    // fails at bind, so a client never reaches a stale instance by chance.
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    try lab.start(a, "cc-zig-sealed-port", &.{FINAL_SSE}, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    try std.testing.expectError(error.BindFailed, gateway_mod.Server.start(a, lab.gateway, lab.server.port));
}

test "L2 sealed: a pin whose manifest changed on the gateway is refused, not run" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    try lab.start(a, "cc-zig-sealed-pin", &.{FINAL_SSE}, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    try lab.install("");

    // The creator republishes with a wider allowlist; the gateway restarts.
    const manifest_path = try std.fmt.allocPrint(a, "{s}/erp-post/manifest.json", .{lab.packages_dir});
    defer a.free(manifest_path);
    const widened = try std.mem.replaceOwned(u8, a, protocol.TEST_MANIFEST_JSON, "\"allow\":[\"Read\"", "\"allow\":[\"Write\",\"Read\"");
    defer a.free(widened);
    try writeFileAt(a, manifest_path, widened);
    try lab.restartGateway();
    // The pin still names the old gateway port; rewrite its URL only, keeping
    // the old digest, as a client whose gateway moved would.
    const pin_path = try std.fmt.allocPrint(a, "{s}/sealed-skills/erp-post/sealed.json", .{lab.state_dir});
    defer a.free(pin_path);
    const md_path = try std.fmt.allocPrint(a, "{s}/sealed-skills/erp-post/SKILL.md", .{lab.state_dir});
    defer a.free(md_path);
    try rewriteGatewayUrl(a, pin_path, lab.gateway_url);
    try rewriteGatewayUrl(a, md_path, lab.gateway_url);
    try lab.loadCatalog();

    try std.testing.expectError(error.SealedManifestChanged, lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"go\"]}"));
    try std.testing.expectEqual(@as(usize, 0), lab.model.requestCount());
}

/// Replace the `http://127.0.0.1:<port>/ssp` URL inside a pin file.
fn rewriteGatewayUrl(a: std.mem.Allocator, path: []const u8, new_url: []const u8) !void {
    const bytes = (try readFileAt(a, path)) orelse return error.PinMissing;
    defer a.free(bytes);
    const start = std.mem.indexOf(u8, bytes, "http://127.0.0.1:") orelse return error.PinUrlMissing;
    const end = std.mem.indexOfPos(u8, bytes, start, "/ssp") orelse return error.PinUrlMissing;
    const rewritten = try std.mem.concat(a, u8, &.{ bytes[0..start], new_url, bytes[end + "/ssp".len ..] });
    defer a.free(rewritten);
    try writeFileAt(a, path, rewritten);
}

// ── The mirror (§9.1) ─────────────────────────────────────────────────────

const LOCAL_SKILL_MD = "---\nname: erp-local\ndescription: Posts invoices. Use when asked to post an invoice.\ncontext: fork\n---\n" ++ SECRET_BODY ++ "\n";
/// The mirror Skill declares `repository_structure`: the local fork carries
/// the codebase context, so the sealed one must carry it too (§5).
const MIRROR_MANIFEST = "{\"schema\":\"metask.sealed-skill.manifest/v1\",\"skill_id\":\"ssk_test\",\"version\":\"1.0.0\",\"name\":\"erp-post\",\"description\":\"Posts invoices. Use when asked to post an invoice.\",\"tools\":{\"allow\":[\"*\"]},\"egress\":{\"classes\":[\"file_contents\",\"command_output\",\"repository_structure\"]}}";

/// The model request with the Skill's base directory (the value of the
/// `Base directory for this skill:` line, as the request spells it) replaced
/// by a marker: the one thing that legitimately differs between a local fork
/// and its sealed shadow.
fn normalizedRequest(a: std.mem.Allocator, body: []const u8) ![]u8 {
    const marker = "Base directory for this skill: ";
    const start = (std.mem.indexOf(u8, body, marker) orelse return error.BaseDirMissing) + marker.len;
    const end = std.mem.indexOfPos(u8, body, start, "\\n") orelse return error.BaseDirMissing;
    const base_dir = body[start..end];
    if (base_dir.len == 0) return error.BaseDirMissing;
    return std.mem.replaceOwned(u8, a, body, base_dir, "<BASE>");
}

test "L2 sealed: the shadow's model request is byte-identical to the local fork's" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    try lab.start(a, "cc-zig-sealed-mirror", &.{ FINAL_SSE, FINAL_SSE }, MIRROR_MANIFEST, .{});
    defer lab.stop();
    try lab.install("");
    // The same Skill, as a plain local forked Skill.
    const local_root = try std.fmt.allocPrint(a, "{s}/local-skills", .{lab.root});
    defer a.free(local_root);
    const local_md = try std.fmt.allocPrint(a, "{s}/erp-local/SKILL.md", .{local_root});
    defer a.free(local_md);
    try writeFileAt(a, local_md, LOCAL_SKILL_MD);
    try lab.loadCatalogWith(local_root);

    const local_output = try lab.runSkill("{\"name\":\"erp-local\",\"values\":[\"post the invoice in data.txt\"]}");
    defer a.free(local_output);
    try std.testing.expect(std.mem.indexOf(u8, local_output, "final-from-sealed") != null);
    const sealed_output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"post the invoice in data.txt\"]}");
    defer a.free(sealed_output);
    try std.testing.expect(std.mem.indexOf(u8, sealed_output, "final-from-sealed") != null);
    try std.testing.expectEqual(@as(usize, 2), lab.model.requestCount());

    const local_request = lab.model.requestAt(0) orelse return error.NoModelRequest;
    const sealed_request = lab.model.requestAt(1) orelse return error.NoModelRequest;
    const local_normalized = try normalizedRequest(a, local_request.body());
    defer a.free(local_normalized);
    const sealed_normalized = try normalizedRequest(a, sealed_request.body());
    defer a.free(sealed_normalized);
    try std.testing.expect(std.mem.indexOf(u8, local_normalized, "<BASE>") != null);
    try std.testing.expect(std.mem.indexOf(u8, sealed_normalized, "<BASE>") != null);
    try std.testing.expectEqualStrings(local_normalized, sealed_normalized);
    // Same account, same key, same header.
    try std.testing.expect(std.mem.indexOf(u8, local_request.raw, CLIENT_KEY) != null);
    try std.testing.expect(std.mem.indexOf(u8, sealed_request.raw, CLIENT_KEY) != null);
}

test "L2 sealed: narration between tool calls stays on the gateway; only the final text comes back" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    var pre_buf: [512]u8 = undefined;
    const pre_root = harness.normalizeSlashes(@constCast(cc.util_fs.testing.perPidDir(&pre_buf, "cc-zig-sealed-silent")));
    const read_input = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}/data.txt\"}}", .{pre_root});
    defer a.free(read_input);
    const narrated = try toolCallSseWithText(a, "THINKING_ALOUD: I will read the file now", "Read", read_input);
    defer a.free(narrated);
    try lab.start(a, "cc-zig-sealed-silent", &.{ narrated, FINAL_SSE }, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"go\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "final-from-sealed") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "THINKING_ALOUD") == null);
    // The brain still sees its own narration in its conversation.
    const second = lab.model.requestAt(1) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "THINKING_ALOUD") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "DATA_MARKER") != null);
}

// ── Sealed reference files and public assets (§5, §12) ────────────────────

/// `perPidDir(tag)` spelled the way the catalog records it and the brain is
/// told it. The catalog canonicalizes every source root with
/// `Dir.realPathFileAbsolute`, so on macOS `/tmp/...` becomes
/// `/private/tmp/...`, and that spelling is the `base_dir` the client sends.
/// A model fixture that names a file under `<base_dir>/sealed/` must use it:
/// the gateway's prefix check is a string comparison, and with the raw
/// `/tmp` spelling it sends the Read to the client instead of serving it.
fn brainVisibleRoot(allocator: std.mem.Allocator, tag: []const u8) ![]u8 {
    var dir_buf: [512]u8 = undefined;
    const per_pid = harness.normalizeSlashes(@constCast(cc.util_fs.testing.perPidDir(&dir_buf, tag)));
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_root = cc.util_fs.testing.tmpRoot(&tmp_buf);
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_len = try std.Io.Dir.realPathFileAbsolute(std.testing.io, tmp_root, &real_buf);
    const real_root = harness.normalizeSlashes(real_buf[0..real_len]);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ real_root, per_pid[tmp_root.len..] });
}

test "L2 sealed: sealed files are read on the gateway without a Step; public assets are installed and read on the client" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    // The brain reads under the base directory it was told, which is the
    // catalog's canonical spelling of the pin directory, not perPidDir's.
    const brain_root = try brainVisibleRoot(a, "cc-zig-sealed-files");
    defer a.free(brain_root);
    const sealed_read = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}/state/sealed-skills/erp-post/sealed/notes.md\"}}", .{brain_root});
    defer a.free(sealed_read);
    const public_read = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}/state/sealed-skills/erp-post/scripts/post.py\"}}", .{brain_root});
    defer a.free(public_read);
    const sealed_sse = try toolCallSse(a, "Read", sealed_read);
    defer a.free(sealed_sse);
    const public_sse = try toolCallSse(a, "Read", public_read);
    defer a.free(public_sse);
    try lab.startWithFiles(a, "cc-zig-sealed-files", &.{ sealed_sse, public_sse, FINAL_SSE }, protocol.TEST_MANIFEST_JSON, .{}, &.{
        .{ .path = "sealed/notes.md", .bytes = "SEALED_NOTE_MARKER: the rule nobody else reads\n" },
        .{ .path = "scripts/post.py", .bytes = "print('PUBLIC_SCRIPT_MARKER')\n" },
    });
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();

    // Install put the public asset where the brain believes it is, and
    // nothing of the sealed set.
    const pin_dir = try lab.pinDir();
    defer a.free(pin_dir);
    const installed = try std.fmt.allocPrint(a, "{s}/scripts/post.py", .{pin_dir});
    defer a.free(installed);
    const installed_bytes = (try readFileAt(a, installed)) orelse return error.AssetNotInstalled;
    defer a.free(installed_bytes);
    try std.testing.expect(std.mem.indexOf(u8, installed_bytes, "PUBLIC_SCRIPT_MARKER") != null);
    const leaked = try std.fmt.allocPrint(a, "{s}/sealed/notes.md", .{pin_dir});
    defer a.free(leaked);
    try std.testing.expect((try readFileAt(a, leaked)) == null);

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"go\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "final-from-sealed") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SEALED_NOTE_MARKER") == null);
    // Three model turns: the sealed read was served inside the first Step,
    // the public read went to the client as the only tool_calls Step.
    try std.testing.expectEqual(@as(usize, 3), lab.model.requestCount());
    const first = lab.model.requestAt(0) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, first.body(), "sealed/notes.md") != null);
    const second = lab.model.requestAt(1) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "SEALED_NOTE_MARKER") != null);
    const third = lab.model.requestAt(2) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, third.body(), "PUBLIC_SCRIPT_MARKER") != null);
    const ledger = (try lab.ledger()) orelse return error.LedgerMissing;
    defer a.free(ledger);
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(ledger, "\"kind\":\"step\""));
    try std.testing.expect(std.mem.indexOf(u8, ledger, "SEALED_NOTE_MARKER") == null);
}

/// Glob results are `repository_structure` (§5): declared, so the Glob over
/// the Skill directory may run on the client.
const SEARCH_MANIFEST = "{\"schema\":\"metask.sealed-skill.manifest/v1\",\"skill_id\":\"ssk_test\",\"version\":\"1.0.0\",\"name\":\"erp-post\",\"description\":\"Posts invoices.\",\"tools\":{\"allow\":[\"Read\",\"Glob\",\"Grep\"]},\"egress\":{\"classes\":[\"file_contents\",\"repository_structure\"]}}";

test "L2 sealed: Glob and Grep under sealed/ are answered on the gateway; a Glob over the Skill directory goes to the client" {
    _ = cc.util_toolchain.ripgrepPath() catch return error.SkipZigTest;
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    // The brain names paths under the base directory it was told — the
    // catalog's canonical spelling of the pin directory (brainVisibleRoot).
    const brain_root = try brainVisibleRoot(a, "cc-zig-sealed-search");
    defer a.free(brain_root);
    const base = try std.fmt.allocPrint(a, "{s}/state/sealed-skills/erp-post", .{brain_root});
    defer a.free(base);
    const glob_sealed = try std.fmt.allocPrint(a, "{{\"pattern\":\"**/*.md\",\"path\":\"{s}/sealed\"}}", .{base});
    defer a.free(glob_sealed);
    const grep_sealed = try std.fmt.allocPrint(a, "{{\"pattern\":\"SEALED_NOTE_MARKER\",\"path\":\"{s}/sealed\",\"output_mode\":\"content\"}}", .{base});
    defer a.free(grep_sealed);
    const glob_public = try std.fmt.allocPrint(a, "{{\"pattern\":\"**/*.py\",\"path\":\"{s}\"}}", .{base});
    defer a.free(glob_public);
    const glob_sealed_sse = try toolCallSse(a, "Glob", glob_sealed);
    defer a.free(glob_sealed_sse);
    const grep_sealed_sse = try toolCallSse(a, "Grep", grep_sealed);
    defer a.free(grep_sealed_sse);
    const glob_public_sse = try toolCallSse(a, "Glob", glob_public);
    defer a.free(glob_public_sse);
    try lab.startWithFiles(a, "cc-zig-sealed-search", &.{ glob_sealed_sse, grep_sealed_sse, glob_public_sse, FINAL_SSE }, SEARCH_MANIFEST, .{}, &.{
        .{ .path = "sealed/notes.md", .bytes = "SEALED_NOTE_MARKER: the rule nobody else reads\n" },
        .{ .path = "sealed/sub/rules.md", .bytes = "SEALED_RULE_MARKER threshold\n" },
        .{ .path = "scripts/post.py", .bytes = "print('PUBLIC_SCRIPT_MARKER')\n" },
    });
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"go\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "final-from-sealed") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SEALED_") == null);

    // Four model turns: the two sealed searches were answered inside the
    // first Step; the Glob over the Skill directory went to the client as the
    // only tool_calls Step and saw the public asset.
    try std.testing.expectEqual(@as(usize, 4), lab.model.requestCount());
    const after_glob = lab.model.requestAt(1) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, after_glob.body(), "sealed/notes.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_glob.body(), "sealed/sub/rules.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_glob.body(), "numFiles\\\":2") != null);
    const after_grep = lab.model.requestAt(2) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, after_grep.body(), "notes.md:1:SEALED_NOTE_MARKER: the rule nobody else reads") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_grep.body(), "SEALED_RULE_MARKER") == null);
    const after_public = lab.model.requestAt(3) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, after_public.body(), "post.py") != null);
    // The brain was shown the client's sealed directory, never the gateway's
    // package directory, in either separator spelling.
    const requests = try lab.allModelRequests(a);
    defer a.free(requests);
    try std.testing.expect(std.mem.indexOf(u8, requests, "packages/erp-post") == null);
    try std.testing.expect(std.mem.indexOf(u8, requests, "packages\\\\erp-post") == null);
    // One Step crossed the wire — the public Glob — then the final; nothing
    // sealed in the ledger.
    const ledger = (try lab.ledger()) orelse return error.LedgerMissing;
    defer a.free(ledger);
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(ledger, "\"kind\":\"step\""));
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"name\":\"Glob\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"name\":\"Grep\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "SEALED_") == null);
}

// ── Egress classes (§5, §6.1, §6.2) ─────────────────────────────────────────

/// Read is allowed, but its results (`file_contents`) are not among the
/// declared classes.
const CLASSLESS_READ_MANIFEST = "{\"schema\":\"metask.sealed-skill.manifest/v1\",\"skill_id\":\"ssk_test\",\"version\":\"1.0.0\",\"name\":\"erp-post\",\"description\":\"Posts invoices.\",\"tools\":{\"allow\":[\"Read\",\"Glob\"]},\"egress\":{\"classes\":[\"command_output\"]}}";
const CONTEXT_MANIFEST = "{\"schema\":\"metask.sealed-skill.manifest/v1\",\"skill_id\":\"ssk_test\",\"version\":\"1.0.0\",\"name\":\"erp-post\",\"description\":\"Posts invoices.\",\"tools\":{\"allow\":[\"Read\"]},\"egress\":{\"classes\":[\"file_contents\",\"repository_structure\"]}}";
const PROJECT_CLAUDE_MD = "PROJECT_CLAUDE_MD_MARKER: instructions that stay home unless consented\n";

test "L2 sealed: a call whose result class the manifest does not declare is refused before it runs" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    const read_sse = try readDataSse(a, "cc-zig-sealed-egress");
    defer a.free(read_sse);
    try lab.start(a, "cc-zig-sealed-egress", &.{ read_sse, FINAL_SSE }, CLASSLESS_READ_MANIFEST, .{});
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"go\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "final-from-sealed") != null);
    // The brain was told why, in the result; the file was never read.
    try std.testing.expectEqual(@as(usize, 2), lab.model.requestCount());
    const second = lab.model.requestAt(1) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "declares no such egress class") != null);
    const requests = try lab.allModelRequests(a);
    defer a.free(requests);
    try std.testing.expect(std.mem.indexOf(u8, requests, "DATA_MARKER") == null);
    try std.testing.expectEqual(@as(usize, 0), lab.probe.permission_requests);
    const ledger = (try lab.ledger()) orelse return error.LedgerMissing;
    defer a.free(ledger);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"refusal\":\"policy_violation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "DATA_MARKER") == null);
}

test "L2 sealed: the fork's codebase context stays home when repository_structure is not declared" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    try lab.start(a, "cc-zig-sealed-ctx-off", &.{FINAL_SSE}, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    const claude_md = try std.fmt.allocPrint(a, "{s}/CLAUDE.md", .{lab.root});
    defer a.free(claude_md);
    try writeFileAt(a, claude_md, PROJECT_CLAUDE_MD);
    try lab.install("");
    try lab.loadCatalog();

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"go\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "final-from-sealed") != null);
    const requests = try lab.allModelRequests(a);
    defer a.free(requests);
    try std.testing.expect(std.mem.indexOf(u8, requests, "PROJECT_CLAUDE_MD_MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, requests, "Project CLAUDE.md") == null);
}

test "L2 sealed: the fork's codebase context reaches the gateway under repository_structure" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    try lab.start(a, "cc-zig-sealed-ctx-on", &.{FINAL_SSE}, CONTEXT_MANIFEST, .{});
    defer lab.stop();
    const claude_md = try std.fmt.allocPrint(a, "{s}/CLAUDE.md", .{lab.root});
    defer a.free(claude_md);
    try writeFileAt(a, claude_md, PROJECT_CLAUDE_MD);
    try lab.install("");
    try lab.loadCatalog();

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"go\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "final-from-sealed") != null);
    const first = lab.model.requestAt(0) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, first.body(), "PROJECT_CLAUDE_MD_MARKER") != null);
}

// ── Disclosure screen (§8.5) ───────────────────────────────────────────────

const SEALED_RULE_LINE = "The rule nobody else reads applies to every invoice over the threshold.";
const DISCLOSURE_MANIFEST = "{\"schema\":\"metask.sealed-skill.manifest/v1\",\"skill_id\":\"ssk_test\",\"version\":\"1.0.0\",\"name\":\"erp-post\",\"description\":\"Posts invoices.\",\"tools\":{\"allow\":[\"Read\",\"Write\"]},\"egress\":{\"classes\":[\"file_contents\"]}}";
const DISCLOSURE_FAIL_MANIFEST = "{\"schema\":\"metask.sealed-skill.manifest/v1\",\"skill_id\":\"ssk_test\",\"version\":\"1.0.0\",\"name\":\"erp-post\",\"description\":\"Posts invoices.\",\"tools\":{\"allow\":[\"Read\"]},\"egress\":{\"classes\":[\"file_contents\"],\"disclosure\":\"fail\"}}";

test "L2 sealed: a final that quotes a sealed line reaches the client with the passage replaced and counted" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    const quoting = try finalSse(a, "Posted. " ++ SEALED_RULE_LINE ++ " Nothing else to do.");
    defer a.free(quoting);
    try lab.startWithFiles(a, "cc-zig-sealed-disclose", &.{quoting}, DISCLOSURE_MANIFEST, .{}, &.{
        .{ .path = "sealed/notes.md", .bytes = SEALED_RULE_LINE ++ "\n" },
    });
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"go\"]}");
    defer a.free(output);
    // The quoted sentence goes; its closing period, outside the last token, stays.
    try std.testing.expect(std.mem.indexOf(u8, output, "Posted. [sealed]. Nothing else to do.") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "nobody else reads") == null);
    // The user is told, once, and the ledger keeps the count.
    try std.testing.expect(std.mem.indexOf(u8, output, "[sealed skill] the gateway withheld passages") != null);
    const ledger = (try lab.ledger()) orelse return error.LedgerMissing;
    defer a.free(ledger);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"disclosure_redactions\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "nobody else reads") == null);
}

test "L2 sealed: a tool input that quotes a sealed line reaches the client's tool redacted" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    var pre_buf: [512]u8 = undefined;
    const pre_root = harness.normalizeSlashes(@constCast(cc.util_fs.testing.perPidDir(&pre_buf, "cc-zig-sealed-disclose-input")));
    const write_input = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}/leak.txt\",\"content\":\"Reminder: {s}\"}}", .{ pre_root, SEALED_RULE_LINE });
    defer a.free(write_input);
    const write_sse = try toolCallSse(a, "Write", write_input);
    defer a.free(write_sse);
    try lab.startWithFiles(a, "cc-zig-sealed-disclose-input", &.{ write_sse, FINAL_SSE }, DISCLOSURE_MANIFEST, .{}, &.{
        .{ .path = "sealed/notes.md", .bytes = SEALED_RULE_LINE ++ "\n" },
    });
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"go\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "final-from-sealed") != null);
    const leak = try std.fmt.allocPrint(a, "{s}/leak.txt", .{lab.root});
    defer a.free(leak);
    const written = (try readFileAt(a, leak)) orelse return error.FileNotWritten;
    defer a.free(written);
    try std.testing.expectEqualStrings("Reminder: [sealed].", written);
    const ledger = (try lab.ledger()) orelse return error.LedgerMissing;
    defer a.free(ledger);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"step_kind\":\"tool_calls\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"disclosure_redactions\":1") != null);
    // The brain itself still remembers what it asked for.
    const second = lab.model.requestAt(1) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "nobody else reads") != null);
}

test "L2 sealed: under disclosure: fail a quoting final ends the run and nothing of it reaches the client" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    const quoting = try finalSse(a, "Posted. " ++ SEALED_RULE_LINE);
    defer a.free(quoting);
    try lab.startWithFiles(a, "cc-zig-sealed-disclose-fail", &.{quoting}, DISCLOSURE_FAIL_MANIFEST, .{}, &.{
        .{ .path = "sealed/notes.md", .bytes = SEALED_RULE_LINE ++ "\n" },
    });
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"go\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "[sealed skill failed: disclosure") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Posted.") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "nobody else reads") == null);
    const ledger = (try lab.ledger()) orelse return error.LedgerMissing;
    defer a.free(ledger);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"step_kind\":\"failed\"") != null);
}

/// One brain turn with `text`, cut at the output-token limit.
fn cutSse(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const escaped = try escapeJson(allocator, text);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_cut\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":40,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"{s}\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"max_tokens\"}},\"usage\":{{\"output_tokens\":5}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{escaped},
    );
}

test "L2 sealed: an answer still cut at the output-token limit fails the run without leaking its text (#394)" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    // The first request and its three continuations are all cut.
    const cut = try cutSse(a, "half-sealed-answer ");
    defer a.free(cut);
    try lab.start(a, "cc-zig-sealed-max-tokens", &.{ cut, cut, cut, cut }, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"write the report\"]}");
    defer a.free(output);
    try std.testing.expectEqual(@as(usize, 4), lab.model.requestCount());
    try std.testing.expect(std.mem.indexOf(u8, output, "[sealed skill failed: skill_error: the Skill's output was still cut off at the model's output-token limit after 3 continuations]") != null);
    // Not a `final`, and nothing of the truncated answer reaches the client.
    try std.testing.expect(std.mem.indexOf(u8, output, "half-sealed-answer") == null);
    const ledger = (try lab.ledger()) orelse return error.LedgerMissing;
    defer a.free(ledger);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "half-sealed-answer") == null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"step_kind\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"step_kind\":\"final\"") == null);
    // Charged like any other failed run that used the model: the Step
    // carries the four calls' cost and the run has its charge.
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(ledger, "\"kind\":\"step\""));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(ledger, "\"kind\":\"charge\""));
    var lines = std.mem.splitScalar(u8, ledger, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"kind\":\"step\"") == null) continue;
        try std.testing.expect(std.mem.indexOf(u8, line, "\"cost_micros\":0,") == null);
    }
}

// ── confirm: true (§4.3, §6.2) ────────────────────────────────────────────

const CONFIRM_READ_MANIFEST = "{\"schema\":\"metask.sealed-skill.manifest/v1\",\"skill_id\":\"ssk_test\",\"version\":\"1.0.0\",\"name\":\"erp-post\",\"description\":\"Posts invoices.\",\"tools\":{\"allow\":[\"Read\"]},\"confirmation\":{\"required_for\":[\"Read\"]},\"egress\":{\"classes\":[\"file_contents\"]}}";

test "L2 sealed: confirm: true forces an interactive approval that bypass mode would skip" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    const read_sse = try readDataSse(a, "cc-zig-sealed-confirm");
    defer a.free(read_sse);
    try lab.start(a, "cc-zig-sealed-confirm", &.{ read_sse, FINAL_SSE }, CONFIRM_READ_MANIFEST, .{});
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();
    // Even a remembered "allow always" for Read does not answer a confirm.
    var rules: cc.permission_session_rules.SessionRules = .{};
    rules.rememberAllow("Read");
    lab.permission.session_rules = &rules;

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"go\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "final-from-sealed") != null);
    try std.testing.expectEqual(@as(usize, 1), lab.probe.permission_requests);
    try std.testing.expectEqualStrings("Read", lab.probe.lastPermissionTool());
    // Approved once: the Read ran and its content reached the gateway's model.
    const second = lab.model.requestAt(1) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "DATA_MARKER") != null);
}

test "L2 sealed: a declined confirm is not executed and is reported as permission_denied" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    const read_sse = try readDataSse(a, "cc-zig-sealed-confirm-deny");
    defer a.free(read_sse);
    try lab.start(a, "cc-zig-sealed-confirm-deny", &.{ read_sse, FINAL_SSE }, CONFIRM_READ_MANIFEST, .{});
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();
    lab.probe.permission_answer = .deny_once;

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"go\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "final-from-sealed") != null);
    try std.testing.expectEqual(@as(usize, 1), lab.probe.permission_requests);
    const second = lab.model.requestAt(1) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "DATA_MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "\"is_error\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "permission_denied") != null);
}

// ── input_required (§4.3): the brain's AskUserQuestion, answered by the client ──

const ASK_INPUT = "{\"questions\":[{\"question\":\"Which ledger should the invoice go to?\",\"header\":\"Ledger\",\"options\":[{\"label\":\"main\",\"description\":\"the main ledger\"},{\"label\":\"test\",\"description\":\"the test ledger\"}]}]}";

test "L2 sealed: an AskUserQuestion of the brain is asked through the client's own dialog and the run continues" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    const ask_sse = try toolCallSse(a, gateway_mod.ASK_USER_TOOL, ASK_INPUT);
    defer a.free(ask_sse);
    const read_sse = try readDataSse(a, "cc-zig-sealed-input");
    defer a.free(read_sse);
    try lab.start(a, "cc-zig-sealed-input", &.{ ask_sse, read_sse, FINAL_SSE }, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"post it\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "final-from-sealed") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "needs input") == null);
    // One dialog, with the brain's own options, over the session's UI.
    try std.testing.expectEqual(@as(usize, 1), lab.probe.question_requests);
    try std.testing.expectEqualStrings("Which ledger should the invoice go to?", lab.probe.lastQuestion());
    try std.testing.expectEqual(@as(usize, 2), lab.probe.last_question_options);
    try std.testing.expectEqual(@as(usize, 0), lab.probe.permission_requests);
    // The brain got the answer in the tool's own result shape, then the
    // Read's content: the run was continued, not cancelled.
    try std.testing.expectEqual(@as(usize, 3), lab.model.requestCount());
    const second = lab.model.requestAt(1) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "\"tool_use_id\":\"tu_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "answers") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "main") != null);
    const third = lab.model.requestAt(2) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, third.body(), "DATA_MARKER") != null);
    const ledger = (try lab.ledger()) orelse return error.LedgerMissing;
    defer a.free(ledger);
    try std.testing.expectEqual(@as(usize, 3), countOccurrences(ledger, "\"kind\":\"step\""));
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"step_kind\":\"input_required\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"step_kind\":\"failed\"") == null);
}

test "L2 sealed: without a UI channel an input_required Step ends the run with the question" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    const ask_sse = try toolCallSse(a, gateway_mod.ASK_USER_TOOL, ASK_INPUT);
    defer a.free(ask_sse);
    try lab.start(a, "cc-zig-sealed-input-noui", &.{ ask_sse, FINAL_SSE }, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();
    lab.probe.question_answer = null;

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"post it\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "[sealed skill needs input] Which ledger should the invoice go to?") != null);
    try std.testing.expectEqual(@as(usize, 1), lab.probe.question_requests);
    try std.testing.expectEqual(@as(usize, 1), lab.model.requestCount());
    const ledger = (try lab.ledger()) orelse return error.LedgerMissing;
    defer a.free(ledger);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"step_kind\":\"input_required\"") != null);
    // The run was released with runs.cancel: a failed/cancelled Step closed it.
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"step_kind\":\"failed\"") != null);
}

test "L2 sealed: a call issued beside a question waits; the gateway answers it and the brain calls again" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    var pre_buf: [512]u8 = undefined;
    const pre_root = harness.normalizeSlashes(@constCast(cc.util_fs.testing.perPidDir(&pre_buf, "cc-zig-sealed-input-sibling")));
    const read_input = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}/data.txt\"}}", .{pre_root});
    defer a.free(read_input);
    const both_sse = try twoCallSse(a, gateway_mod.ASK_USER_TOOL, ASK_INPUT, "Read", read_input);
    defer a.free(both_sse);
    try lab.start(a, "cc-zig-sealed-input-sibling", &.{ both_sse, FINAL_SSE }, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"post it\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "final-from-sealed") != null);
    try std.testing.expectEqual(@as(usize, 1), lab.probe.question_requests);
    try std.testing.expectEqual(@as(usize, 2), lab.model.requestCount());
    // The sibling Read was never sent to the client; the brain got the
    // answer for tu_a and a "call again" error for tu_b in one user turn.
    const second = lab.model.requestAt(1) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "\"tool_use_id\":\"tu_a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "answers") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "\"tool_use_id\":\"tu_b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "call it again") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "DATA_MARKER") == null);
}

test "L2 sealed: a malformed AskUserQuestion is answered by the client's tool as an error, never asked" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    const bad_ask = try toolCallSse(a, gateway_mod.ASK_USER_TOOL, "{\"schema\":{}}");
    defer a.free(bad_ask);
    try lab.start(a, "cc-zig-sealed-input-invalid", &.{ bad_ask, FINAL_SSE }, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"post it\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "final-from-sealed") != null);
    try std.testing.expectEqual(@as(usize, 0), lab.probe.question_requests);
    try std.testing.expectEqual(@as(usize, 2), lab.model.requestCount());
    const second = lab.model.requestAt(1) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "AskUserQuestion failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "\"is_error\":true") != null);
}

// ── credentials (§6.4) ────────────────────────────────────────────────────

const SECRET = "s3cr3t-pw-9f2";

/// A Read whose path names the credential placeholder: only a client that
/// substituted the bound value finds the file.
fn credentialReadSse(a: std.mem.Allocator, tag: []const u8) ![]u8 {
    var pre_buf: [512]u8 = undefined;
    const pre_root = harness.normalizeSlashes(@constCast(cc.util_fs.testing.perPidDir(&pre_buf, tag)));
    const read_input = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}/vault-${{SEALED_CRED:erp-main}}.txt\"}}", .{pre_root});
    defer a.free(read_input);
    return toolCallSse(a, "Read", read_input);
}

test "L2 sealed: a bound credential is substituted into the call and redacted from the result" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    const read_sse = try credentialReadSse(a, "cc-zig-sealed-cred");
    defer a.free(read_sse);
    try lab.start(a, "cc-zig-sealed-cred", &.{ read_sse, FINAL_SSE }, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();
    try credentials.bind(a, lab.state_dir, "ssk_test", "erp-main", SECRET);
    const vault_path = try std.fmt.allocPrint(a, "{s}/vault-{s}.txt", .{ lab.root, SECRET });
    defer a.free(vault_path);
    try writeFileAt(a, vault_path, "token=" ++ SECRET ++ "\nVAULT_MARKER\n");

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"post it\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "final-from-sealed") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "not bound") == null);
    // The brain was told the placeholder, never the value; the call's result
    // reached it with the value redacted and the rest of the file intact.
    const first = lab.model.requestAt(0) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, first.body(), "${SEALED_CRED:erp-main}") != null);
    const second = lab.model.requestAt(1) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "VAULT_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "token=[redacted:erp-main]") != null);
    const everything = try lab.allModelRequests(a);
    defer a.free(everything);
    try std.testing.expect(std.mem.indexOf(u8, everything, SECRET) == null);
    const ledger = (try lab.ledger()) orelse return error.LedgerMissing;
    defer a.free(ledger);
    try std.testing.expect(std.mem.indexOf(u8, ledger, SECRET) == null);
    // The results record names the redaction that was applied.
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"redactions\":[\"erp-main\"]") != null);
}

test "L2 sealed: an unbound credential refuses the call with permission_denied and tells the user how to bind it" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    const read_sse = try credentialReadSse(a, "cc-zig-sealed-cred-unbound");
    defer a.free(read_sse);
    try lab.start(a, "cc-zig-sealed-cred-unbound", &.{ read_sse, FINAL_SSE }, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();
    const vault_path = try std.fmt.allocPrint(a, "{s}/vault-{s}.txt", .{ lab.root, SECRET });
    defer a.free(vault_path);
    try writeFileAt(a, vault_path, "VAULT_MARKER\n");

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"post it\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "final-from-sealed") != null);
    // The user is told what to do, in the fork's result.
    try std.testing.expect(std.mem.indexOf(u8, output, "metacodes sealed bind erp-post erp-main") != null);
    // The call never ran; the gateway got a permission_denied refusal.
    try std.testing.expectEqual(@as(usize, 2), lab.model.requestCount());
    const second = lab.model.requestAt(1) orelse return error.NoModelRequest;
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "VAULT_MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "\"is_error\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "not bound on this client") != null);
    try std.testing.expectEqual(@as(usize, 0), lab.probe.permission_requests);
    // The refusal is on the record for the Step it answered.
    const ledger = (try lab.ledger()) orelse return error.LedgerMissing;
    defer a.free(ledger);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"refusal\":\"permission_denied\"") != null);
}

// ── Scale design (doc/SEALED_GATEWAY_SCALE_DESIGN.md): admission, route cache ──

/// Restart only the server with explicit capacity options and point the pin
/// at the new port; the gateway (packages, sealing key, route cache) stays.
fn restartServerWith(lab: *Lab, options: gateway_mod.ServerOptions) !void {
    const a = lab.allocator;
    lab.server.stop();
    lab.server = try gateway_mod.Server.startWith(a, lab.gateway, options);
    a.free(lab.gateway_url);
    lab.gateway_url = try lab.server.url(a);
    const pin_path = try std.fmt.allocPrint(a, "{s}/sealed-skills/erp-post/sealed.json", .{lab.state_dir});
    defer a.free(pin_path);
    const md_path = try std.fmt.allocPrint(a, "{s}/sealed-skills/erp-post/SKILL.md", .{lab.state_dir});
    defer a.free(md_path);
    try rewriteGatewayUrl(a, pin_path, lab.gateway_url);
    try rewriteGatewayUrl(a, md_path, lab.gateway_url);
    try lab.loadCatalog();
}

/// A `runs.start` sent straight over the transport (no fork): it occupies a
/// model slot for as long as the mock model's gate holds its answer.
const DirectStart = struct {
    lab: *Lab,
    outcome: ?anyerror = null,
    kind: ?protocol.StepKind = null,

    fn run(self: *DirectStart) void {
        self.go() catch |err| {
            self.outcome = err;
        };
    }

    fn go(self: *DirectStart) !void {
        const a = self.lab.allocator;
        var client = try transport.Client.init(a, self.lab.io_runtime.io(), self.lab.gateway_url, "");
        defer client.deinit();
        client.provider_credential = "direct-credential";
        var params: std.Io.Writer.Allocating = .init(a);
        defer params.deinit();
        try protocol.writeStartParams(&params.writer, .{
            .skill_id = "ssk_test",
            .manifest_digest = self.lab.gateway.packages[0].entry.manifest_digest,
            .prompt = "go",
            .tools_json = "[]",
            .max_cost_micros = 0,
            .max_steps = 8,
            .client_name = "test",
            .client_version = "0",
            .client_platform = "test",
            .base_dir = "/t/skill",
            .provider_kind = "anthropic",
            .provider_base_url = self.lab.model_url,
            .model = "claude-sonnet-4-20250514",
        });
        var response = try client.call(.runs_start, params.written(), null);
        defer response.deinit();
        switch (response.response) {
            .result => |result| {
                var step = try protocol.parseStep(a, result);
                defer step.deinit();
                self.kind = step.step.kind;
            },
            .err => return error.DirectStartRefused,
        }
    }
};

/// A `discover` over its own connection, for queue-pressure scenarios.
const Discover = struct {
    lab: *Lab,
    outcome: ?anyerror = null,
    retry_after_ms: u64 = 0,
    ok: bool = false,

    fn run(self: *Discover) void {
        const a = self.lab.allocator;
        var client = transport.Client.init(a, self.lab.io_runtime.io(), self.lab.gateway_url, "") catch |err| {
            self.outcome = err;
            return;
        };
        defer client.deinit();
        var response = client.call(.discover, "{}", null) catch |err| {
            self.outcome = err;
            self.retry_after_ms = client.last_retry_after_ms;
            return;
        };
        defer response.deinit();
        self.ok = response.response == .result;
    }
};

fn releaseAfter(model: *harness.MockServer, delay_ms: u64) void {
    cc.util_time.sleepMs(delay_ms);
    model.releaseGatedResponse();
}

test "L2 sealed scale: a Step refused for a busy model slot is resent by the client and completes" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    const read_sse = try toolCallSse(a, "Read", "{\"file_path\":\"does-not-exist.txt\"}");
    defer a.free(read_sse);
    // conn1: the direct run (gated); conn2/conn3: the client run's two Steps.
    try lab.start(a, "cc-zig-sealed-scale-admit", &.{ read_sse, read_sse, FINAL_SSE }, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    try lab.install("");
    try restartServerWith(&lab, .{ .max_model_calls = 1, .workers = 4, .queue_depth = 8, .keepalive_ms = 100 });

    lab.model.gateNextResponse();
    var holder = DirectStart{ .lab = &lab };
    const holder_thread = try std.Thread.spawn(.{}, DirectStart.run, .{&holder});
    try lab.model.waitUntilResponseGated();

    // With the only slot busy, a Step is refused before any state is read.
    var probe = try transport.Client.init(a, lab.io_runtime.io(), lab.gateway_url, "");
    defer probe.deinit();
    probe.provider_credential = "probe";
    var refused = try probe.call(.runs_start, "{\"skill_id\":\"ssk_test\"}", null);
    defer refused.deinit();
    try std.testing.expect(refused.response == .err);
    try std.testing.expectEqual(protocol.ErrorCode.rate_limited, refused.response.err.known.?);
    try std.testing.expect(cc.util_json.extractIntField(refused.response.err.data_json, "retry_after_ms") > 0);
    // Not a model method: served even now.
    var open = try probe.call(.discover, "{}", null);
    defer open.deinit();
    try std.testing.expect(open.response == .result);

    // The real client waits as told and gets through once the slot frees.
    const releaser = try std.Thread.spawn(.{}, releaseAfter, .{ lab.model, @as(u64, 1500) });
    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"go\"]}");
    defer a.free(output);
    releaser.join();
    holder_thread.join();
    try std.testing.expect(std.mem.indexOf(u8, output, "final-from-sealed") != null);
    try std.testing.expect(holder.outcome == null);
    try std.testing.expectEqual(protocol.StepKind.tool_calls, holder.kind.?);
    const stats = lab.server.stats();
    try std.testing.expect(stats.rejected_model >= 2);
    try std.testing.expectEqual(@as(u64, 0), stats.rejected_queue);
}

test "L2 sealed scale: a full queue answers 503 with Retry-After before reading the request" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    const read_sse = try toolCallSse(a, "Read", "{\"file_path\":\"does-not-exist.txt\"}");
    defer a.free(read_sse);
    try lab.start(a, "cc-zig-sealed-scale-queue", &.{read_sse}, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    try lab.install("");
    try restartServerWith(&lab, .{ .workers = 1, .queue_depth = 1, .max_model_calls = 1, .keepalive_ms = 0 });

    lab.model.gateNextResponse();
    var holder = DirectStart{ .lab = &lab };
    const holder_thread = try std.Thread.spawn(.{}, DirectStart.run, .{&holder});
    try lab.model.waitUntilResponseGated();
    // The single worker is busy; the next connection waits in the queue…
    var queued = Discover{ .lab = &lab };
    const queued_thread = try std.Thread.spawn(.{}, Discover.run, .{&queued});
    cc.util_time.sleepMs(300);
    // …and the one after it is refused on arrival.
    var refused = Discover{ .lab = &lab };
    refused.run();
    lab.model.releaseGatedResponse();
    holder_thread.join();
    queued_thread.join();
    try std.testing.expect(queued.ok);
    try std.testing.expectError(error.Overloaded, if (refused.outcome) |err| @as(anyerror!void, err) else {});
    try std.testing.expectEqual(@as(u64, 1000), refused.retry_after_ms);
    const stats = lab.server.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.rejected_queue);
}

test "L2 sealed scale: consecutive Steps of a run reuse one built provider" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    const read_sse = try toolCallSse(a, "Read", "{\"file_path\":\"does-not-exist.txt\"}");
    defer a.free(read_sse);
    try lab.start(a, "cc-zig-sealed-scale-pool", &.{ read_sse, FINAL_SSE }, protocol.TEST_MANIFEST_JSON, .{});
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();
    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"go\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "final-from-sealed") != null);
    const pool = lab.gateway.poolStats();
    try std.testing.expectEqual(@as(u64, 1), pool.misses);
    try std.testing.expectEqual(@as(u64, 1), pool.hits);
    try std.testing.expectEqual(@as(usize, 1), pool.size);
}

const DISCLOSURE_SPLIT_MANIFEST = "{\"schema\":\"metask.sealed-skill.manifest/v1\",\"skill_id\":\"ssk_test\",\"version\":\"1.0.0\",\"name\":\"erp-post\",\"description\":\"Posts invoices.\",\"tools\":{\"allow\":[\"Read\"]},\"egress\":{\"classes\":[\"file_contents\"],\"disclosure\":{\"body\":\"redact\",\"references\":\"off\"}}}";
const DISCLOSURE_REFERENCES_FAIL_MANIFEST = "{\"schema\":\"metask.sealed-skill.manifest/v1\",\"skill_id\":\"ssk_test\",\"version\":\"1.0.0\",\"name\":\"erp-post\",\"description\":\"Posts invoices.\",\"tools\":{\"allow\":[\"Read\"]},\"egress\":{\"classes\":[\"file_contents\"],\"disclosure\":{\"body\":\"off\",\"references\":\"fail\"}}}";

test "L2 sealed: a documentation Skill quotes its references freely while its instructions stay screened" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    // The final cites a reference sentence verbatim and restates the body.
    const quoting = try finalSse(a, "From the docs: " ++ SEALED_RULE_LINE ++ " And my instructions were: " ++ SECRET_BODY);
    defer a.free(quoting);
    try lab.startWithFiles(a, "cc-zig-sealed-disclose-split", &.{quoting}, DISCLOSURE_SPLIT_MANIFEST, .{}, &.{
        .{ .path = "sealed/notes.md", .bytes = SEALED_RULE_LINE ++ "\n" },
    });
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"go\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "From the docs: " ++ SEALED_RULE_LINE) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SECRET_SKILL_BODY") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[sealed]") != null);
    const ledger = (try lab.ledger()) orelse return error.LedgerMissing;
    defer a.free(ledger);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"disclosure_redactions\":1") != null);
}

test "L2 sealed: references under fail end the run even when the body screen is off" {
    const a = std.testing.allocator;
    var lab: Lab = undefined;
    const quoting = try finalSse(a, "Posted. " ++ SEALED_RULE_LINE);
    defer a.free(quoting);
    try lab.startWithFiles(a, "cc-zig-sealed-disclose-reffail", &.{quoting}, DISCLOSURE_REFERENCES_FAIL_MANIFEST, .{}, &.{
        .{ .path = "sealed/notes.md", .bytes = SEALED_RULE_LINE ++ "\n" },
    });
    defer lab.stop();
    try lab.install("");
    try lab.loadCatalog();

    const output = try lab.runSkill("{\"name\":\"erp-post\",\"values\":[\"go\"]}");
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "[sealed skill failed: disclosure") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "nobody else reads") == null);
}
