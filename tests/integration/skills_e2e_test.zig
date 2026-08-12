//! Shared Skill Runtime integration tests.
//!
//! These replace the retired CLI-only loader/tool tests. Each fixture enters
//! through the canonical catalog, projects the snapshot for CLI presentation,
//! and invokes the same typed activation used by AgentCore.

const std = @import("std");
const cc = @import("cc");
const pfs = @import("platform").fs;

const Runtime = cc.skills_cli_adapter.Runtime;
const Source = cc.skills_runtime.catalog.Source;

fn dispatchOk(
    ctx: *const cc.tools.ToolContext,
    name: []const u8,
    args: []const u8,
) ![]u8 {
    var outcome = try cc.tools.dispatch(ctx, name, args);
    return switch (outcome) {
        .ok => |bytes| bytes,
        else => {
            outcome.deinit(ctx.allocator);
            return error.UnexpectedDispatchOutcome;
        },
    };
}

fn makeSkill(parent: []const u8, name: []const u8, md: []const u8) !void {
    const allocator = std.testing.allocator;
    const parent_z = try allocator.dupeZ(u8, parent);
    defer allocator.free(parent_z);
    _ = std.c.mkdir(parent_z, 0o755);
    const skill_dir = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/{s}",
        .{ parent, name },
        0,
    );
    defer allocator.free(skill_dir);
    _ = std.c.mkdir(skill_dir, 0o755);
    const definition_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/{s}/SKILL.md",
        .{ parent, name },
        0,
    );
    defer allocator.free(definition_path);
    const fd = pfs.open(
        definition_path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );
    _ = pfs.write(fd, md);
    pfs.close(fd);
}

fn tmpRoot(
    tmp: *std.testing.TmpDir,
    buffer: *[std.fs.max_path_bytes]u8,
) ![]const u8 {
    const length = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..length];
}

const HostCapture = struct {
    calls: usize = 0,
    effective_count: usize = 0,

    fn activate(
        raw: *anyopaque,
        _: []const u8,
        effective: []const []const u8,
        _: []const []const u8,
    ) anyerror!void {
        const self: *HostCapture = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.effective_count = effective.len;
    }

    fn services(self: *HostCapture) cc.tool_context.HostServices {
        return .{
            .ctx = @ptrCast(self),
            .activateSkillFn = &activate,
        };
    }
};

const Fixture = struct {
    runtime: Runtime,
    projection: cc.skills.SkillSet,
    registry: cc.tools_dynamic.DynRegistry,
    abort: cc.util_abort.AbortSignal,
    permission: cc.permission.PermissionContext,
    host: HostCapture = .{},
    tool_defs: []cc.json_mod.ToolDefinition,

    fn init(
        self: *Fixture,
        allocator: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
    ) !void {
        self.* = .{
            .runtime = Runtime.init(allocator, io),
            .projection = cc.skills.SkillSet.init(allocator),
            .registry = cc.tools_dynamic.DynRegistry.init(allocator),
            .abort = cc.util_abort.AbortSignal.init(),
            .permission = .{
                .mode = .init(.bypass_permissions),
                .allocator = allocator,
            },
            .tool_defs = try cc.tools.toToolDefinitions(allocator),
        };
        errdefer allocator.free(self.tool_defs);
        errdefer self.registry.deinit();
        errdefer self.projection.deinit();
        errdefer self.runtime.deinit();

        const sources = [_]Source{.{
            .root = root,
            .scope = .project,
            .priority = 300,
        }};
        try self.runtime.loadSources(
            root,
            "",
            "",
            &sources,
            &self.projection,
        );
        try cc.skills_tool.registerSkillTool(
            &self.registry,
            &self.runtime,
        );
        const model_defs = try cc.tools.toToolDefinitionsWithDyn(
            allocator,
            &self.registry,
        );
        allocator.free(self.tool_defs);
        self.tool_defs = model_defs;
        if (!cc.skills_cli_adapter.applyModelToolSchema(self.tool_defs))
            return error.SkillSchemaMissing;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.registry.deinit();
        self.runtime.deinit();
        self.projection.deinit();
        allocator.free(self.tool_defs);
        self.* = undefined;
    }

    fn context(self: *Fixture, allocator: std.mem.Allocator, root: []const u8) cc.tools.ToolContext {
        var ctx = cc.tools.ToolContext.withAbort(allocator, &self.abort);
        ctx.permission_ctx = &self.permission;
        ctx.dyn_registry = &self.registry;
        ctx.host_services = self.host.services();
        ctx.tool_defs = self.tool_defs;
        ctx.project_dir = root;
        ctx.cwd_abs = root;
        return ctx;
    }
};

test "Skills E2E: canonical catalog projects into CLI and system prompt" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buffer);
    try makeSkill(
        root,
        "refactor",
        "---\nname: Display Refactor\ndescription: Refactor safely\n---\nSteps: read, plan, edit.\n",
    );
    try makeSkill(
        root,
        "review",
        "---\nname: Display Review\ndescription: Review PR\n---\nChecklist: security and clarity.\n",
    );

    var fixture: Fixture = undefined;
    try fixture.init(allocator, std.testing.io, root);
    defer fixture.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), fixture.projection.len());
    try std.testing.expect(fixture.projection.find("refactor") != null);
    try std.testing.expect(fixture.projection.find("review") != null);
    try std.testing.expectEqualSlices(
        u8,
        &fixture.runtime.snapshot.?.revision,
        &fixture.projection.catalog_revision,
    );
    const skill_definition = blk: {
        for (fixture.tool_defs) |definition| {
            if (std.mem.eql(u8, definition.name, "Skill"))
                break :blk definition;
        }
        return error.SkillSchemaMissing;
    };
    try std.testing.expectEqual(
        @as(usize, 2),
        skill_definition.input_schema.prop_specs.?.len,
    );
    try std.testing.expectEqualStrings(
        "values",
        skill_definition.input_schema.prop_specs.?[1].name,
    );

    const prompt = try cc.system_prompt.buildWithSkills(
        allocator,
        "claude-opus-4-7",
        &fixture.projection,
        "/tmp",
    );
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "**refactor**") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Refactor safely") != null);
}

test "Skills E2E: model dispatch uses typed activation and working tree" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buffer);
    try makeSkill(
        root,
        "greet",
        "---\nname: greet\ndescription: hello\narguments: [target]\nallowed-tools: Read\n---\nHello $target from ${CLAUDE_SKILL_DIR}.\n",
    );

    var fixture: Fixture = undefined;
    try fixture.init(allocator, std.testing.io, root);
    defer fixture.deinit(allocator);
    var ctx = fixture.context(allocator, root);

    const output = try dispatchOk(
        &ctx,
        "Skill",
        "{\"name\":\"greet\",\"values\":[\"world\"]}",
    );
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "# Skill: greet") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Hello world from ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, root) == null);
    try std.testing.expect(fixture.permission.active_skill != null);
    try std.testing.expect(fixture.runtime.currentPolicyFrame() != null);
}

test "Skills E2E: shell rendering and model-only admission share Runtime" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buffer);
    try makeSkill(
        root,
        "echoer",
        "---\nname: echoer\ndescription: shell\n---\nOutput: !`echo hello-from-runtime`\n",
    );
    try makeSkill(
        root,
        "explicit",
        "---\nname: explicit\ndescription: explicit only\ndisable-model-invocation: true\n---\nMust be explicit.\n",
    );

    var fixture: Fixture = undefined;
    try fixture.init(allocator, std.testing.io, root);
    defer fixture.deinit(allocator);
    var ctx = fixture.context(allocator, root);

    const rendered = try dispatchOk(&ctx, "Skill", "{\"name\":\"echoer\"}");
    defer allocator.free(rendered);
    try std.testing.expect(
        std.mem.indexOf(u8, rendered, "Output: hello-from-runtime") != null,
    );

    var outcome = cc.tools.dispatch(&ctx, "Skill", "{\"name\":\"explicit\"}") catch |err| {
        try std.testing.expectEqual(error.PolicyViolation, err);
        return;
    };
    defer outcome.deinit(allocator);
    return error.ExpectedPolicyViolation;
}

test "Skills E2E: execution contexts keep sibling policy projections isolated" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buffer);
    try makeSkill(
        root,
        "reader",
        "---\nname: reader\ndescription: read only\nallowed-tools: Read\n---\nread\n",
    );
    try makeSkill(
        root,
        "writer",
        "---\nname: writer\ndescription: write only\nallowed-tools: Write\n---\nwrite\n",
    );

    var fixture: Fixture = undefined;
    try fixture.init(allocator, std.testing.io, root);
    defer fixture.deinit(allocator);

    var reader_permission = cc.permission.PermissionContext{
        .mode = .init(.bypass_permissions),
        .allocator = allocator,
    };
    var writer_permission = cc.permission.PermissionContext{
        .mode = .init(.bypass_permissions),
        .allocator = allocator,
    };
    var reader_ctx = fixture.context(allocator, root);
    reader_ctx.permission_ctx = &reader_permission;
    reader_ctx.agent_ident = cc.session_id.gen();
    var writer_ctx = fixture.context(allocator, root);
    writer_ctx.permission_ctx = &writer_permission;
    writer_ctx.agent_ident = cc.session_id.gen();

    _ = try fixture.runtime.activate(
        &reader_ctx,
        "reader",
        &.{},
        .model_tool,
    );
    try fixture.runtime.projectCurrent(
        reader_ctx.agent_ident,
        &reader_permission,
    );
    _ = try fixture.runtime.activate(
        &writer_ctx,
        "writer",
        &.{},
        .model_tool,
    );
    try fixture.runtime.projectCurrent(
        writer_ctx.agent_ident,
        &writer_permission,
    );

    try std.testing.expect(
        !reader_permission.active_skill.?.isDisallowed("Read", "{}"),
    );
    try std.testing.expect(
        reader_permission.active_skill.?.isDisallowed("Write", "{}"),
    );
    try std.testing.expect(
        !writer_permission.active_skill.?.isDisallowed("Write", "{}"),
    );
    try std.testing.expect(
        writer_permission.active_skill.?.isDisallowed("Read", "{}"),
    );

    fixture.runtime.clearContext(reader_ctx.agent_ident);
    try std.testing.expect(reader_permission.active_skill == null);
    try std.testing.expect(writer_permission.active_skill != null);
    fixture.runtime.clearContext(writer_ctx.agent_ident);
    try std.testing.expect(writer_permission.active_skill == null);
}

test "Skills E2E: unmanaged child activation fails closed without leaking lineage" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buffer);
    try makeSkill(
        root,
        "reader",
        "---\nname: reader\ndescription: read only\nallowed-tools: Read\n---\nread\n",
    );

    var fixture: Fixture = undefined;
    try fixture.init(allocator, std.testing.io, root);
    defer fixture.deinit(allocator);
    var child_permission = cc.permission.PermissionContext{
        .mode = .init(.bypass_permissions),
        .allocator = allocator,
    };
    var child_ctx = fixture.context(allocator, root);
    child_ctx.permission_ctx = &child_permission;
    child_ctx.agent_ident = cc.session_id.gen();
    child_ctx.agent_depth = 1;

    try std.testing.expectError(
        error.SkillUnavailable,
        fixture.runtime.activate(
            &child_ctx,
            "reader",
            &.{},
            .model_tool,
        ),
    );
    try std.testing.expect(child_permission.active_skill == null);
    try std.testing.expect(fixture.runtime.currentPolicyFrame() == null);
}

test "Skills E2E: project root lookup remains presentation-only utility" {
    const allocator = std.testing.allocator;
    const cwd = try cc.util_fs.getCwd(allocator);
    defer allocator.free(cwd);
    const root = try cc.skills.findRepoRoot(allocator, cwd);
    defer allocator.free(root);

    const root_is_cwd = std.mem.eql(u8, root, cwd);
    const root_is_ancestor = cwd.len > root.len and
        std.mem.eql(u8, root, cwd[0..root.len]) and
        (cwd[root.len] == '/' or cwd[root.len] == '\\');
    try std.testing.expect(root_is_cwd or root_is_ancestor);

    const git_marker = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/.git",
        .{root},
        0,
    );
    defer allocator.free(git_marker);
    try std.testing.expect(pfs.exists(git_marker));
}

test "Skills E2E: slash adapter tokenization is bounded and rejects partial quotes" {
    const allocator = std.testing.allocator;
    const values = try cc.skills_cli_adapter.parseSlashValues(
        allocator,
        "alpha \"two words\"",
    );
    defer {
        for (values) |value| allocator.free(value);
        allocator.free(values);
    }
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqualStrings("two words", values[1]);
    try std.testing.expectError(
        error.InvalidArguments,
        cc.skills_cli_adapter.parseSlashValues(
            allocator,
            "\"unterminated",
        ),
    );

    var too_many: std.Io.Writer.Allocating = .init(allocator);
    defer too_many.deinit();
    for (0..65) |index| {
        if (index != 0) try too_many.writer.writeByte(' ');
        try too_many.writer.writeByte('x');
    }
    try std.testing.expectError(
        error.InvalidArguments,
        cc.skills_cli_adapter.parseSlashValues(
            allocator,
            too_many.written(),
        ),
    );
}

test "Skills E2E: slash syntax preserves path-first ordinary messages" {
    const adapter = cc.skills_cli_adapter;
    switch (adapter.parseSlashSyntax("tmp/foo.zig help me")) {
        .not_a_command => {},
        .command => return error.TestExpectedOrdinaryMessage,
    }
    switch (adapter.parseSlashSyntax("")) {
        .not_a_command => {},
        .command => return error.TestExpectedOrdinaryMessage,
    }
    switch (adapter.parseSlashSyntax("unknown argument")) {
        .command => |head| try std.testing.expectEqualStrings("unknown", head),
        .not_a_command => return error.TestExpectedCommand,
    }
}
