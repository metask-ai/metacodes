const std = @import("std");
const sdk = @import("metask_agentcore");
const wire = sdk.types;
const Server = @import("mock_server.zig").Server;

comptime {
    if (@hasDecl(wire, "SessionRefreshSkillCatalogFnV1") or
        @hasField(wire.ApiV1, "session_refresh_skill_catalog"))
        @compileError("revision 6 must not expose the removed catalog refresh entry");
}

const ASK_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"ask\",\"name\":\"AskUserQuestion\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"questions\\\":[{\\\"question\\\":\\\"Continue?\\\",\\\"header\\\":\\\"Choice\\\",\\\"options\\\":[{\\\"label\\\":\\\"Yes\\\",\\\"description\\\":\\\"Proceed\\\"},{\\\"label\\\":\\\"No\\\",\\\"description\\\":\\\"Stop\\\"}]}]}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const HOST_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m3\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"host\",\"name\":\"HostEcho\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"text\\\":\\\"hello\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m4\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"artifact done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const SpinMutex = struct {
    state: std.atomic.Value(u8) = .init(0),

    fn lock(self: *SpinMutex) void {
        while (self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null)
            std.Thread.yield() catch {};
    }

    fn unlock(self: *SpinMutex) void {
        self.state.store(0, .release);
    }
};

const Probe = struct {
    identity_mutex: SpinMutex = .{},
    session: ?*wire.SessionHandle = null,
    active_run_id: u64 = 0,
    bound_session_id_len: u8 = 0,
    bound_session_id: [wire.MAX_SESSION_ID_BYTES_V1]u8 = undefined,
    ui_calls: usize = 0,
    ui_releases: usize = 0,
    host_calls: usize = 0,
    host_releases: usize = 0,
    saw_read_result: bool = false,
    saw_host_result: bool = false,
    saw_final_text: bool = false,

    fn registerSession(self: *Probe, session: *wire.SessionHandle) !void {
        self.identity_mutex.lock();
        defer self.identity_mutex.unlock();
        if (self.session != null) return error.SessionAlreadyRegistered;
        self.session = session;
    }

    fn beginRun(self: *Probe, run_id: u64) !void {
        self.identity_mutex.lock();
        defer self.identity_mutex.unlock();
        if (self.session == null or self.active_run_id != 0 or run_id == 0) return error.InvalidHostLifecycle;
        self.active_run_id = run_id;
    }

    fn endRun(self: *Probe, run_id: u64) !void {
        self.identity_mutex.lock();
        defer self.identity_mutex.unlock();
        if (self.active_run_id != run_id) return error.InvalidHostLifecycle;
        self.active_run_id = 0;
    }

    fn acceptContext(self: *Probe, run_ptr: ?*const wire.RunContextV1) bool {
        const run = sdk.validateRunContext(run_ptr) catch return false;
        self.identity_mutex.lock();
        defer self.identity_mutex.unlock();
        if (run.session != self.session or run.run_id != self.active_run_id) return false;
        if (self.bound_session_id_len == 0) {
            self.bound_session_id_len = @intCast(run.session_id.len);
            @memcpy(self.bound_session_id[0..run.session_id.len], run.session_id);
            return true;
        }
        return self.bound_session_id_len == run.session_id.len and
            std.mem.eql(u8, self.bound_session_id[0..self.bound_session_id_len], run.session_id);
    }

    fn event(raw: ?*anyopaque, run: ?*const wire.RunContextV1, json_view: wire.BytesViewV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        if (!self.acceptContext(run)) return wire.EVENT_FATAL;
        const json = sdk.borrowedBytes(json_view) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, json) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        switch (parsed.value) {
            .known => |known_event| switch (known_event) {
                .tool_result => |result| {
                    if (std.mem.eql(u8, result.name, "Read") and !result.is_error and
                        std.mem.indexOf(u8, result.content, "artifact-read-ok") != null)
                        self.saw_read_result = true;
                    if (std.mem.eql(u8, result.name, "HostEcho") and !result.is_error and
                        std.mem.eql(u8, result.content, "artifact-host-ok"))
                        self.saw_host_result = true;
                },
                .text_chunk => |text| {
                    if (std.mem.eql(u8, text, "artifact done")) self.saw_final_text = true;
                },
                else => {},
            },
            .unknown => {},
        }
        return wire.EVENT_CONTINUE;
    }

    fn ui(raw: ?*anyopaque, run: ?*const wire.RunContextV1, request: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.UI_FATAL));
        if (!self.acceptContext(run)) return wire.UI_FATAL;
        const encoded = sdk.borrowedBytes(request) catch return wire.UI_FATAL;
        const parsed = sdk.decodeUiRequest(std.heap.c_allocator, encoded) catch return wire.UI_FATAL;
        defer parsed.deinit();
        const questions = switch (parsed.value) {
            .ask_question => |questions| questions,
            else => return wire.UI_FATAL,
        };
        if (questions.len != 1 or !std.mem.eql(u8, questions[0].question, "Continue?") or
            questions[0].options.len != 2 or !std.mem.eql(u8, questions[0].options[0].label, "Yes"))
            return wire.UI_FATAL;
        self.ui_calls += 1;
        const values = [_][]const u8{"Yes"};
        const answers = [_]sdk.protocol.Answer{.{ .values = &values }};
        const response = sdk.encodeUiResponse(std.heap.c_allocator, parsed.value, .{ .answers = &answers }) catch return wire.UI_FATAL;
        (out orelse {
            std.heap.c_allocator.free(response);
            return wire.UI_FATAL;
        }).* = .{ .ptr = response.ptr, .len = response.len };
        return wire.UI_ANSWERED;
    }

    fn uiRelease(raw: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return));
        self.ui_releases += 1;
        if (out) |value| {
            const len = std.math.cast(usize, value.len) orelse return;
            if (value.ptr) |ptr| std.heap.c_allocator.free(ptr[0..len]);
            value.* = .{ .ptr = null, .len = 0 };
        }
    }

    fn host(raw: ?*anyopaque, run: ?*const wire.RunContextV1, args: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.HOST_FAILED));
        if (!self.acceptContext(run)) return wire.HOST_FATAL;
        const Args = struct { text: []const u8 };
        const encoded = sdk.borrowedBytes(args) catch return wire.HOST_FAILED;
        const parsed = std.json.parseFromSlice(Args, std.heap.c_allocator, encoded, .{}) catch return wire.HOST_FAILED;
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.text, "hello")) return wire.HOST_FAILED;
        self.host_calls += 1;
        const result = "artifact-host-ok";
        (out orelse return wire.HOST_FAILED).* = .{ .ptr = @constCast(result.ptr), .len = result.len };
        return wire.HOST_OK;
    }

    fn hostRelease(raw: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return));
        self.host_releases += 1;
        if (out) |value| value.* = .{ .ptr = null, .len = 0 };
    }
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const api = try sdk.Api.discover();
    if (api.raw.abi_revision != wire.ABI_REVISION) return error.UnexpectedRevision;
    if (sdk.metask_agentcore_get_api(2) != null) return error.UnexpectedAbi;
    try verifyRevisionMismatchRejection(api);

    const process_root = try std.process.currentPathAlloc(init.io, a);
    var name_buf: [128]u8 = undefined;
    const workspace_name = try std.fmt.bufPrint(&name_buf, ".agentcore-consumer-{d}", .{std.Thread.getCurrentId()});
    const workspace = try std.fs.path.join(a, &.{ process_root, workspace_name });
    try std.Io.Dir.cwd().createDirPath(init.io, workspace);
    defer std.Io.Dir.cwd().deleteTree(init.io, workspace) catch {};
    const file_name = "artifact-read.txt";
    const file_path = try std.fs.path.join(a, &.{ workspace, file_name });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = file_path, .data = "artifact-read-ok" });
    const skill_dir = try std.fs.path.join(a, &.{ workspace, ".agents", "skills", "review" });
    try std.Io.Dir.cwd().createDirPath(init.io, skill_dir);
    const skill_path = try std.fs.path.join(a, &.{ skill_dir, "SKILL.md" });
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = skill_path,
        .data = "---\nname: Review\ndescription: Source-free typed invocation fixture\narguments: [target]\n---\nREVIEW_SKILL_SENTINEL $target",
    });
    const workctl_dir = try std.fs.path.join(a, &.{ workspace, ".agents", "skills", "workctl" });
    try std.Io.Dir.cwd().createDirPath(init.io, workctl_dir);
    const workctl_path = try std.fs.path.join(a, &.{ workctl_dir, "SKILL.md" });
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = workctl_path,
        .data = "---\nname: Workctl\ndescription: Second source-free typed invocation fixture\narguments: [target]\n---\nWORKCTL_SKILL_SENTINEL $target",
    });
    // Source-free proof: the model supplies a relative file path and the
    // binary facade resolves it against workspace_root, not process cwd.
    const read_sse = try readToolSse(a, file_name);
    const bodies = [_][]const u8{ ASK_SSE, read_sse, HOST_SSE, FINAL_SSE, FINAL_SSE };
    const server = try Server.start(init.io, &bodies);
    defer server.stop();
    const url = try server.url(a);

    var probe = Probe{};
    const builtins = [_]wire.BytesViewV1{ sdk.bytesView("AskUserQuestion"), sdk.bytesView("Read") };
    var host = wire.HostToolV1{
        .struct_size = @sizeOf(wire.HostToolV1),
        .reserved0 = 0,
        .ctx = &probe,
        .name = sdk.bytesView("HostEcho"),
        .description = sdk.bytesView("Host echo"),
        .input_schema_json = sdk.bytesView("{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}"),
        .execute = Probe.host,
        .release_result = Probe.hostRelease,
        .reserved = [_]u64{0} ** 2,
    };
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.builtin_tools = &builtins;
    runtime_config.builtin_tool_count = builtins.len;
    runtime_config.host_tools = @ptrCast(&host);
    runtime_config.host_tool_count = 1;
    var diagnostic = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try expectStatus(.ok, api.runtimeCreate()(&runtime_config, &runtime, &diagnostic), diagnostic);
    defer if (runtime) |handle| {
        _ = api.runtimeDestroy()(handle, &diagnostic);
    };

    var query = wire.SkillCatalogQueryV1{
        .struct_size = @sizeOf(wire.SkillCatalogQueryV1),
        .reserved0 = 0,
        .workspace_root = sdk.bytesView(workspace),
        .workspace_home = sdk.bytesView(workspace),
        .workspace_epoch = sdk.bytesView("fixture-epoch"),
        .reserved = [_]u64{0} ** 3,
    };
    var catalog: ?*wire.SkillCatalogHandle = null;
    defer if (catalog) |handle| {
        _ = api.skillCatalogRelease()(handle, &diagnostic);
    };
    var descriptor = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&descriptor);
    try expectStatus(.ok, api.runtimeQuerySkillCatalog()(
        runtime,
        &query,
        &catalog,
        &descriptor,
        &diagnostic,
    ), diagnostic);
    if (catalog == null or descriptor.ptr == null or descriptor.len == 0)
        return error.MissingSkillCatalog;
    const descriptor_bytes = try sdk.borrowedBytes(.{
        .ptr = descriptor.ptr,
        .len = descriptor.len,
    });
    const identities = try catalogIdentities(a, descriptor_bytes, "review");
    const workctl_identities = try catalogIdentities(a, descriptor_bytes, "workctl");
    if (!std.mem.eql(u8, identities.revision, workctl_identities.revision) or
        std.mem.eql(u8, identities.skill_id, workctl_identities.skill_id))
        return error.InvalidCatalogDescriptor;
    api.bufferRelease()(&descriptor);

    const allowed = [_]wire.BytesViewV1{ sdk.bytesView("AskUserQuestion"), sdk.bytesView("Read"), sdk.bytesView("HostEcho") };
    var skill_selection = std.mem.zeroes(wire.SkillSelectionV1);
    skill_selection.struct_size = @sizeOf(wire.SkillSelectionV1);
    skill_selection.default_state_code = wire.SKILL_SELECTION_ENABLED;
    var initial_rules = std.mem.zeroes(wire.PermissionRuleSetV1);
    initial_rules.struct_size = @sizeOf(wire.PermissionRuleSetV1);
    var session_host = wire.SessionHostConfigV1{
        .struct_size = @sizeOf(wire.SessionHostConfigV1),
        .provider_kind_code = wire.PROVIDER_ANTHROPIC,
        .permission_mode_code = wire.PERMISSION_FULL_ACCESS,
        .shell_policy_code = wire.SHELL_DISABLED,
        .api_key = sdk.bytesView("artifact-key"),
        .base_url = sdk.bytesView(url),
        .workspace_root = sdk.bytesView(workspace),
        .workspace_home = sdk.bytesView(workspace),
        .allowed_tools = &allowed,
        .allowed_tool_count = allowed.len,
        .skill_catalog = catalog,
        .skill_selection = &skill_selection,
        .permission_rules = &initial_rules,
        .mcp_selection = null,
        .durable_budget = null,
        .reserved = [_]u64{0} ** 4,
    };
    var config = wire.SessionCreateConfigV1{
        .struct_size = @sizeOf(wire.SessionCreateConfigV1),
        .reserved0 = 0,
        .host = &session_host,
        .model = sdk.bytesView("artifact-model"),
        .reserved = [_]u64{0} ** 4,
    };
    var callbacks = wire.SessionCallbacksV1{
        .struct_size = @sizeOf(wire.SessionCallbacksV1),
        .reserved0 = 0,
        .ctx = &probe,
        .on_event = Probe.event,
        .on_ui_request = Probe.ui,
        .release_response = Probe.uiRelease,
        .reserved = [_]u64{0} ** 4,
    };
    var session: ?*wire.SessionHandle = null;
    try expectStatus(.ok, api.sessionCreate()(runtime, &config, &callbacks, &session, &diagnostic), diagnostic);
    try expectStatus(.ok, api.skillCatalogRelease()(catalog, &diagnostic), diagnostic);
    catalog = null;
    try probe.registerSession(session.?);
    defer if (session) |handle| {
        _ = api.sessionDestroy()(handle, &diagnostic);
    };
    try expectStatus(
        .ok,
        api.sessionSetModel()(session, sdk.bytesView("artifact-model-v2"), &diagnostic),
        diagnostic,
    );
    try expectStatus(
        .ok,
        api.sessionUpdateSkills()(session, null, &skill_selection, &diagnostic),
        diagnostic,
    );
    try expectStatus(
        .ok,
        api.sessionUpdatePermissionRules()(session, &initial_rules, &diagnostic),
        diagnostic,
    );
    var compact_result = std.mem.zeroes(wire.CompactResultV1);
    try expectStatus(
        .ok,
        api.sessionCompact()(session, 1, &compact_result, &diagnostic),
        diagnostic,
    );
    if (compact_result.struct_size != @sizeOf(wire.CompactResultV1) or
        compact_result.outcome_code != wire.COMPACT_NO_CHANGE)
        return error.InvalidCompactResult;
    try expectStatus(
        .too_late,
        api.sessionAbortCompact()(session, 1, &diagnostic),
        diagnostic,
    );
    api.bufferRelease()(&diagnostic);
    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 6, .reserved = [_]u64{0} ** 4 };
    var result: wire.RunResultV1 = undefined;
    const encoded_arguments = try sdk.encodeSkillArguments(
        a,
        &.{"artifact-target"},
    );
    try probe.beginRun(1);
    try expectStatus(.ok, api.sessionRunSkill(
        session,
        1,
        sdk.bytesView(identities.skill_id),
        sdk.bytesView(identities.revision),
        sdk.bytesView(encoded_arguments),
        &options,
        &result,
        &diagnostic,
    ), diagnostic);
    try probe.endRun(1);
    if (try sdk.StopReason.fromCode(result.stop_reason_code) != .end_turn or result.tool_calls != 3) return error.UnexpectedRunResult;
    if (probe.ui_calls != 1 or probe.ui_releases != 1 or probe.host_calls != 1 or probe.host_releases != 1) return error.CallbackContractFailed;
    if (!probe.saw_read_result or !probe.saw_host_result or !probe.saw_final_text) return error.MissingCoreEvent;
    try probe.beginRun(2);
    try expectStatus(.ok, api.sessionRunSkill(
        session,
        2,
        sdk.bytesView(workctl_identities.skill_id),
        sdk.bytesView(workctl_identities.revision),
        sdk.bytesView(encoded_arguments),
        &options,
        &result,
        &diagnostic,
    ), diagnostic);
    try probe.endRun(2);
    if (try sdk.StopReason.fromCode(result.stop_reason_code) != .end_turn or
        result.tool_calls != 0)
        return error.UnexpectedRunResult;
    try expectStatus(.ok, api.sessionDestroy()(session, &diagnostic), diagnostic);
    session = null;
    try expectStatus(.ok, api.runtimeDestroy()(runtime, &diagnostic), diagnostic);
    runtime = null;
    std.debug.print("AgentCore source-free consumer: Revision 6 mutations, compact, catalog, typed Skill, tools, Host UI and events OK\n", .{});
}

const CatalogIdentities = struct {
    revision: []const u8,
    skill_id: []const u8,
};

fn catalogIdentities(
    allocator: std.mem.Allocator,
    descriptor_json: []const u8,
    invocation_name: []const u8,
) !CatalogIdentities {
    const parsed = try sdk.decodeSkillCatalog(allocator, descriptor_json);
    defer parsed.deinit();
    for (parsed.value.skills) |skill| {
        if (std.mem.eql(u8, skill.invocation_name, invocation_name)) {
            if (skill.argument_schema.names.len != 1 or
                !std.mem.eql(u8, skill.argument_schema.names[0], "target"))
                return error.InvalidCatalogDescriptor;
            return .{
                .revision = try allocator.dupe(u8, parsed.value.catalog_revision),
                .skill_id = try allocator.dupe(u8, skill.skill_id),
            };
        }
    }
    return error.SkillMissingFromCatalog;
}

fn verifyRevisionMismatchRejection(api: sdk.Api) !void {
    var wrong_revision = api.raw.*;
    wrong_revision.abi_revision = 5;
    if (sdk.Api.validate(&wrong_revision)) |_| return error.WrongRevisionAccepted else |err| {
        if (err != error.UnsupportedAbi) return err;
    }
}

fn readToolSse(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"m2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"read\",\"name\":\"Read\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"file_path\\\":\\\"{s}\\\"}}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{path});
}

fn expectStatus(expected: sdk.Status, actual_code: u32, diagnostic: wire.OwnedBytesV1) !void {
    const actual = sdk.Status.fromCode(actual_code) catch return error.UnknownStatus;
    if (actual == expected) return;
    const message = sdk.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len }) catch "invalid diagnostic";
    std.debug.print("AgentCore status {s}, expected {s}: {s}\n", .{ @tagName(actual), @tagName(expected), message });
    return error.UnexpectedStatus;
}
