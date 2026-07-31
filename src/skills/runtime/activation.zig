//! Pure admission for a typed Skill invocation.
//!
//! `prepare` deliberately performs no filesystem, provider, tool, Conversation,
//! or Run-lifecycle work. A successful result is an immutable, owned plan that
//! may safely cross the `beginRun` admission point.

const std = @import("std");
const catalog = @import("catalog.zig");
const availability = @import("availability.zig");
const definition = @import("definition.zig");
const materialization = @import("materialization.zig");
const policy_frame = @import("policy_frame.zig");
const workspace = @import("../../core/workspace_policy.zig");
const AbortSignal = @import("../../util/abort.zig").AbortSignal;
const sandbox_config = @import("../../sandbox/config.zig");
const render = @import("../render.zig");

pub const MAX_ARGUMENT_VALUES: usize = 64;
pub const MAX_ARGUMENT_JSON_BYTES: usize = 1024 * 1024;

pub const PrepareError = error{
    OutOfMemory,
    ResourceLimit,
    InvalidCatalogRevision,
    StaleCatalog,
    InvalidSkillId,
    SkillNotFound,
    InvalidArguments,
    PolicyViolation,
    SkillDisabled,
    SkillUnavailable,
    ModelOverrideUnavailable,
};

pub const Context = enum {
    external_run_root,
    model_tool,
};

pub const ModelOverrideCapability = enum {
    forbidden,
    allowed,
};

pub const ModelSelection = union(enum) {
    inherit_parent,
    override: []const u8,
};

pub const ModelSelectionError = error{
    ModelOverrideUnavailable,
};

pub const PrepareOptions = struct {
    context: Context,
    shell_policy: workspace.ShellPolicy,
    model_override_capability: ModelOverrideCapability,
    availability: availability.View = .all,
};

pub const ActivationPlan = struct {
    arena: std.heap.ArenaAllocator,
    snapshot: *const catalog.Snapshot,
    skill: *const catalog.SkillRecord,
    arguments: []const []const u8,
    requires_shell: bool,
    context: Context,
    model_selection: ModelSelection,

    pub fn deinit(self: *ActivationPlan) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ExecuteOptions = struct {
    materializations: *materialization.Manager,
    parent_frame: *policy_frame.PolicyFrame,
    abort: *const AbortSignal,
    project_dir: []const u8,
    session_id: []const u8,
    sandbox: ?*const sandbox_config.SandboxSettings,
    cwd_abs: []const u8,
    home_dir: []const u8,
    additional_dirs: []const []const u8 = &.{},
    parent_agent_depth: u8 = 0,
};

/// Owned result of the one canonical activation kernel. External typed input
/// and model-tool invocation both prepare the same immutable plan and enter
/// here after their respective admission boundary.
pub const Activation = struct {
    owner_allocator: std.mem.Allocator,
    tree: materialization.WorkingTree,
    frame: *policy_frame.PolicyFrame,
    rendered_body: []u8,
    parent_agent_depth: u8,
    model_selection: ModelSelection,

    pub fn deinit(self: *Activation) materialization.Error!void {
        const owner_allocator = self.owner_allocator;
        freeModelSelection(owner_allocator, self.model_selection);
        owner_allocator.free(self.rendered_body);
        self.frame.release();
        self.tree.deinit() catch |err| {
            self.* = undefined;
            return err;
        };
        self.* = undefined;
    }
};

pub fn prepare(
    owner_allocator: std.mem.Allocator,
    snapshot: *const catalog.Snapshot,
    catalog_revision: []const u8,
    skill_id: []const u8,
    arguments_json: []const u8,
    options: PrepareOptions,
) PrepareError!ActivationPlan {
    var arena = std.heap.ArenaAllocator.init(owner_allocator);
    errdefer arena.deinit();
    const arguments = try parseArguments(arena.allocator(), arguments_json);
    return finishPrepare(
        arena,
        snapshot,
        catalog_revision,
        skill_id,
        arguments,
        options,
    );
}

/// Adapter-neutral typed entry. JSON decoding belongs only at a wire boundary;
/// CLI and in-process callers pass already-tokenized values here.
pub fn prepareValues(
    owner_allocator: std.mem.Allocator,
    snapshot: *const catalog.Snapshot,
    catalog_revision: []const u8,
    skill_id: []const u8,
    argument_values: []const []const u8,
    options: PrepareOptions,
) PrepareError!ActivationPlan {
    if (argument_values.len > MAX_ARGUMENT_VALUES) return error.InvalidArguments;
    var total_bytes: usize = 0;
    for (argument_values) |value| {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidArguments;
        total_bytes = std.math.add(usize, total_bytes, value.len) catch
            return error.ResourceLimit;
        if (total_bytes > MAX_ARGUMENT_JSON_BYTES) return error.ResourceLimit;
    }

    var arena = std.heap.ArenaAllocator.init(owner_allocator);
    errdefer arena.deinit();
    const arguments = try arena.allocator().alloc([]const u8, argument_values.len);
    for (argument_values, arguments) |value, *owned| {
        owned.* = try arena.allocator().dupe(u8, value);
    }
    return finishPrepare(
        arena,
        snapshot,
        catalog_revision,
        skill_id,
        arguments,
        options,
    );
}

fn finishPrepare(
    arena: std.heap.ArenaAllocator,
    snapshot: *const catalog.Snapshot,
    catalog_revision: []const u8,
    skill_id: []const u8,
    arguments: []const []const u8,
    options: PrepareOptions,
) PrepareError!ActivationPlan {
    if (!catalog.isLowerHex64(catalog_revision)) return error.InvalidCatalogRevision;
    if (!std.mem.eql(u8, &snapshot.revision, catalog_revision)) return error.StaleCatalog;
    if (!catalog.isLowerHex64(skill_id)) return error.InvalidSkillId;
    const skill = snapshot.findById(skill_id) orelse return error.SkillNotFound;
    if (!options.availability.isEnabled(snapshot, skill))
        return error.SkillDisabled;
    const model_selection = try resolveModelSelection(
        skill.definition.context,
        skill.definition.model,
        options.model_override_capability,
    );
    if (options.context == .model_tool and skill.definition.disable_model_invocation)
        return error.PolicyViolation;
    // AgentCore has no AgentDef catalog or profile-binding contract. Accepting
    // this metadata and silently using the generic fork prompt would claim a
    // capability the formal ABI cannot provide.
    if (skill.definition.agent.len != 0) return error.SkillUnavailable;
    policy_frame.validateRules(
        skill.definition.allowed_tools,
        skill.definition.disallowed_tools,
    ) catch return error.PolicyViolation;

    const requires_shell = render.hasShellInjection(skill.definition.body);

    if (requires_shell and options.shell_policy == .disabled) return error.PolicyViolation;
    if (requires_shell and std.mem.eql(u8, skill.definition.shell, "powershell"))
        return error.SkillUnavailable;

    return .{
        .arena = arena,
        .snapshot = snapshot,
        .skill = skill,
        .arguments = arguments,
        .requires_shell = requires_shell,
        .context = options.context,
        .model_selection = model_selection,
    };
}

pub fn resolveModelSelection(
    exec_context: definition.ExecContext,
    declared_model: []const u8,
    capability: ModelOverrideCapability,
) ModelSelectionError!ModelSelection {
    if (exec_context == .inline_ctx or
        declared_model.len == 0 or
        std.mem.eql(u8, declared_model, "inherit"))
        return .inherit_parent;
    return switch (capability) {
        .allowed => .{ .override = declared_model },
        .forbidden => error.ModelOverrideUnavailable,
    };
}

pub fn activate(
    owner_allocator: std.mem.Allocator,
    plan: *const ActivationPlan,
    options: ExecuteOptions,
) anyerror!Activation {
    const model_selection = try ownModelSelection(
        owner_allocator,
        plan.model_selection,
    );
    errdefer freeModelSelection(owner_allocator, model_selection);

    var tree = try options.materializations.materialize(
        plan.skill,
        options.abort,
    );
    const frame = policy_frame.PolicyFrame.derive(
        options.parent_frame,
        plan.skill.definition.allowed_tools,
        plan.skill.definition.disallowed_tools,
    ) catch |frame_error| {
        tree.deinit() catch return error.CoreError;
        return frame_error;
    };

    const rendered = render.renderBody(
        owner_allocator,
        plan.skill.definition.body,
        .{
            .arguments = plan.arguments,
            .arg_names = plan.skill.definition.arguments,
            .skill_dir = tree.path,
            .project_dir = options.project_dir,
            .session_id = options.session_id,
            .shell = plan.skill.definition.shell,
            .disable_shell_execution = frame.shellPolicy() == .disabled,
            .abort = options.abort,
            .sandbox = options.sandbox,
            .cwd_abs = options.cwd_abs,
            .home_dir = options.home_dir,
            .additional_dirs = options.additional_dirs,
        },
    ) catch |render_error| {
        frame.release();
        tree.deinit() catch return error.CoreError;
        return render_error;
    };
    options.abort.throwIfAborted() catch |abort_error| {
        owner_allocator.free(rendered);
        frame.release();
        tree.deinit() catch return error.CoreError;
        return abort_error;
    };

    return .{
        .owner_allocator = owner_allocator,
        .tree = tree,
        .frame = frame,
        .rendered_body = rendered,
        .parent_agent_depth = options.parent_agent_depth,
        .model_selection = model_selection,
    };
}

fn ownModelSelection(
    allocator: std.mem.Allocator,
    selection: ModelSelection,
) error{OutOfMemory}!ModelSelection {
    return switch (selection) {
        .inherit_parent => .inherit_parent,
        .override => |model| .{ .override = try allocator.dupe(u8, model) },
    };
}

fn freeModelSelection(
    allocator: std.mem.Allocator,
    selection: ModelSelection,
) void {
    switch (selection) {
        .inherit_parent => {},
        .override => |model| allocator.free(model),
    }
}

test "resolveModelSelection implements the complete context and capability matrix" {
    inline for (.{ ModelOverrideCapability.allowed, .forbidden }) |capability| {
        try std.testing.expect(
            (try resolveModelSelection(.inline_ctx, "arbitrary-model", capability)) ==
                .inherit_parent,
        );
        try std.testing.expect(
            (try resolveModelSelection(.fork, "", capability)) == .inherit_parent,
        );
        try std.testing.expect(
            (try resolveModelSelection(.fork, "inherit", capability)) ==
                .inherit_parent,
        );
    }

    const selected = try resolveModelSelection(
        .fork,
        "arbitrary-model",
        .allowed,
    );
    try std.testing.expectEqualStrings(
        "arbitrary-model",
        selected.override,
    );
    try std.testing.expectError(
        error.ModelOverrideUnavailable,
        resolveModelSelection(.fork, "arbitrary-model", .forbidden),
    );
}

fn parseArguments(
    arena: std.mem.Allocator,
    encoded: []const u8,
) PrepareError![]const []const u8 {
    if (encoded.len > MAX_ARGUMENT_JSON_BYTES) return error.ResourceLimit;
    if (encoded.len == 0) return &.{};
    if (!std.unicode.utf8ValidateSlice(encoded)) return error.InvalidArguments;

    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, encoded, .{
        .duplicate_field_behavior = .@"error",
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.InvalidArguments;
    };
    if (root != .object or root.object.count() != 1) return error.InvalidArguments;
    const values_node = root.object.get("values") orelse return error.InvalidArguments;
    if (values_node != .array) return error.InvalidArguments;
    if (values_node.array.items.len > MAX_ARGUMENT_VALUES) return error.InvalidArguments;

    const values = try arena.alloc([]const u8, values_node.array.items.len);
    for (values_node.array.items, values) |node, *value| {
        if (node != .string) return error.InvalidArguments;
        value.* = node.string;
    }
    return values;
}

const TestFixture = struct {
    arena: std.heap.ArenaAllocator,
    records: [1]catalog.SkillRecord,
    snapshot: catalog.Snapshot,

    fn init(body: []const u8, shell: []const u8) TestFixture {
        var fixture = TestFixture{
            .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
            .records = undefined,
            .snapshot = undefined,
        };
        fixture.records[0] = .{
            .skill_id = [_]u8{'b'} ** 64,
            .invocation_name = "review",
            .definition = .{
                .name = "Review",
                .description = "Review code",
                .body = body,
                .allowed_tools = &.{},
                .disallowed_tools = &.{},
                .arguments = &.{ "target", "depth" },
                .disable_model_invocation = false,
                .context = .inline_ctx,
                .agent = "",
                .model = "",
                .shell = shell,
                .source_path = "",
            },
            .directories = &.{},
            .files = &.{},
        };
        fixture.snapshot = .{
            .owner_allocator = std.testing.allocator,
            .arena = fixture.arena,
            .scope_id = [_]u8{'c'} ** 64,
            .revision = [_]u8{'a'} ** 64,
            .health = .healthy,
            .skills = &.{},
            .issues = &.{},
            .descriptor_json = "",
            .snapshot_bytes = 0,
            .resident_bytes = 0,
        };
        return fixture;
    }

    fn bind(self: *TestFixture) void {
        self.snapshot.skills = self.records[0..];
    }

    fn deinit(self: *TestFixture) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn prepareForTest(
    owner_allocator: std.mem.Allocator,
    snapshot: *const catalog.Snapshot,
    catalog_revision: []const u8,
    skill_id: []const u8,
    arguments_json: []const u8,
    shell_policy: workspace.ShellPolicy,
    context: Context,
) PrepareError!ActivationPlan {
    return prepare(
        owner_allocator,
        snapshot,
        catalog_revision,
        skill_id,
        arguments_json,
        .{
            .context = context,
            .shell_policy = shell_policy,
            .model_override_capability = .allowed,
        },
    );
}

test "ActivationPlan owns canonical typed arguments and retains immutable identities" {
    var fixture = TestFixture.init("Review $target at $depth.", "bash");
    defer fixture.deinit();
    fixture.bind();

    var plan = try prepareForTest(
        std.testing.allocator,
        &fixture.snapshot,
        &fixture.snapshot.revision,
        &fixture.records[0].skill_id,
        "{\"values\":[\"src/main.zig\",\"deep\"]}",
        .disabled,
        .external_run_root,
    );
    defer plan.deinit();

    try std.testing.expect(plan.snapshot == &fixture.snapshot);
    try std.testing.expect(plan.skill == &fixture.records[0]);
    try std.testing.expect(!plan.requires_shell);
    try std.testing.expectEqual(@as(usize, 2), plan.arguments.len);
    try std.testing.expectEqualStrings("src/main.zig", plan.arguments[0]);
    try std.testing.expectEqualStrings("deep", plan.arguments[1]);
}

test "ActivationPlan rejects identity and revision failures before argument allocation" {
    var fixture = TestFixture.init("Review.", "bash");
    defer fixture.deinit();
    fixture.bind();

    try std.testing.expectError(error.InvalidCatalogRevision, prepareForTest(
        std.testing.allocator,
        &fixture.snapshot,
        "A",
        &fixture.records[0].skill_id,
        "",
        .disabled,
        .external_run_root,
    ));
    try std.testing.expectError(error.StaleCatalog, prepareForTest(
        std.testing.allocator,
        &fixture.snapshot,
        &([_]u8{'d'} ** 64),
        &fixture.records[0].skill_id,
        "",
        .disabled,
        .external_run_root,
    ));
    try std.testing.expectError(error.InvalidSkillId, prepareForTest(
        std.testing.allocator,
        &fixture.snapshot,
        &fixture.snapshot.revision,
        "not-an-id",
        "",
        .disabled,
        .external_run_root,
    ));
    try std.testing.expectError(error.SkillNotFound, prepareForTest(
        std.testing.allocator,
        &fixture.snapshot,
        &fixture.snapshot.revision,
        &([_]u8{'d'} ** 64),
        "",
        .disabled,
        .external_run_root,
    ));
}

test "argument bounds and decoding precede catalog identity checks" {
    var fixture = TestFixture.init("Review.", "bash");
    defer fixture.deinit();
    fixture.bind();

    const too_large = try std.testing.allocator.alloc(u8, MAX_ARGUMENT_JSON_BYTES + 1);
    defer std.testing.allocator.free(too_large);
    @memset(too_large, 0xff);
    try std.testing.expectError(error.ResourceLimit, prepareForTest(
        std.testing.allocator,
        &fixture.snapshot,
        "not-a-revision",
        "not-an-id",
        too_large,
        .disabled,
        .external_run_root,
    ));
    try std.testing.expectError(error.InvalidArguments, prepareForTest(
        std.testing.allocator,
        &fixture.snapshot,
        "not-a-revision",
        "not-an-id",
        &[_]u8{0xff},
        .disabled,
        .external_run_root,
    ));
}

test "Skill arguments enforce the exact bounded wire schema" {
    var fixture = TestFixture.init("Review.", "bash");
    defer fixture.deinit();
    fixture.bind();

    const invalid = [_][]const u8{
        " ",
        "{}",
        "{\"values\":null}",
        "{\"values\":[1]}",
        "{\"values\":[],\"extra\":true}",
        "{\"values\":[],\"values\":[]}",
    };
    for (invalid) |encoded| {
        try std.testing.expectError(error.InvalidArguments, prepareForTest(
            std.testing.allocator,
            &fixture.snapshot,
            &fixture.snapshot.revision,
            &fixture.records[0].skill_id,
            encoded,
            .disabled,
            .external_run_root,
        ));
    }

    const too_large = try std.testing.allocator.alloc(u8, MAX_ARGUMENT_JSON_BYTES + 1);
    defer std.testing.allocator.free(too_large);
    @memset(too_large, 0xff);
    try std.testing.expectError(error.ResourceLimit, prepareForTest(
        std.testing.allocator,
        &fixture.snapshot,
        &fixture.snapshot.revision,
        &fixture.records[0].skill_id,
        too_large,
        .disabled,
        .external_run_root,
    ));

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try writer.writer.writeAll("{\"values\":[");
    for (0..MAX_ARGUMENT_VALUES + 1) |index| {
        if (index != 0) try writer.writer.writeByte(',');
        try writer.writer.writeAll("\"x\"");
    }
    try writer.writer.writeAll("]}");
    try std.testing.expectError(error.InvalidArguments, prepareForTest(
        std.testing.allocator,
        &fixture.snapshot,
        &fixture.snapshot.revision,
        &fixture.records[0].skill_id,
        writer.written(),
        .disabled,
        .external_run_root,
    ));
}

test "shell injection admission exactly follows renderer recognition" {
    const Cases = struct {
        body: []const u8,
        requires_shell: bool,
    };
    const cases = [_]Cases{
        .{ .body = "!`echo yes`", .requires_shell = true },
        .{ .body = "x !`echo yes`", .requires_shell = true },
        .{ .body = "x\t!`echo yes`", .requires_shell = true },
        .{ .body = "x\n```!bash\necho yes\n```", .requires_shell = true },
        .{ .body = "KEY=!`literal`", .requires_shell = false },
        .{ .body = "!`unterminated", .requires_shell = false },
        .{ .body = "x ```!bash\nliteral", .requires_shell = false },
    };
    for (cases) |case| {
        var fixture = TestFixture.init(case.body, "bash");
        defer fixture.deinit();
        fixture.bind();
        if (case.requires_shell) {
            try std.testing.expectError(error.PolicyViolation, prepareForTest(
                std.testing.allocator,
                &fixture.snapshot,
                &fixture.snapshot.revision,
                &fixture.records[0].skill_id,
                "",
                .disabled,
                .external_run_root,
            ));
            var allowed = try prepareForTest(
                std.testing.allocator,
                &fixture.snapshot,
                &fixture.snapshot.revision,
                &fixture.records[0].skill_id,
                "",
                .sandboxed,
                .external_run_root,
            );
            defer allowed.deinit();
            try std.testing.expect(allowed.requires_shell);
        } else {
            var plan = try prepareForTest(
                std.testing.allocator,
                &fixture.snapshot,
                &fixture.snapshot.revision,
                &fixture.records[0].skill_id,
                "",
                .disabled,
                .external_run_root,
            );
            defer plan.deinit();
            try std.testing.expect(!plan.requires_shell);
        }
    }
}

test "powershell is unavailable only when the Skill requires shell execution" {
    var executable = TestFixture.init("!`Write-Output ok`", "powershell");
    defer executable.deinit();
    executable.bind();
    try std.testing.expectError(error.SkillUnavailable, prepareForTest(
        std.testing.allocator,
        &executable.snapshot,
        &executable.snapshot.revision,
        &executable.records[0].skill_id,
        "",
        .unrestricted,
        .external_run_root,
    ));

    var inert = TestFixture.init("Explain PowerShell.", "powershell");
    defer inert.deinit();
    inert.bind();
    var plan = try prepareForTest(
        std.testing.allocator,
        &inert.snapshot,
        &inert.snapshot.revision,
        &inert.records[0].skill_id,
        "",
        .disabled,
        .external_run_root,
    );
    defer plan.deinit();
    try std.testing.expect(!plan.requires_shell);
}

test "malformed tool policy is rejected before Run admission" {
    var fixture = TestFixture.init("Review.", "bash");
    defer fixture.deinit();
    fixture.records[0].definition.allowed_tools = &.{"Bash("};
    fixture.bind();

    try std.testing.expectError(error.PolicyViolation, prepareForTest(
        std.testing.allocator,
        &fixture.snapshot,
        &fixture.snapshot.revision,
        &fixture.records[0].skill_id,
        "",
        .unrestricted,
        .external_run_root,
    ));
}

test "model-only admission guard does not block explicit external invocation" {
    var fixture = TestFixture.init("Review.", "bash");
    defer fixture.deinit();
    fixture.records[0].definition.disable_model_invocation = true;
    fixture.bind();

    try std.testing.expectError(error.PolicyViolation, prepareForTest(
        std.testing.allocator,
        &fixture.snapshot,
        &fixture.snapshot.revision,
        &fixture.records[0].skill_id,
        "",
        .disabled,
        .model_tool,
    ));
    var external = try prepareForTest(
        std.testing.allocator,
        &fixture.snapshot,
        &fixture.snapshot.revision,
        &fixture.records[0].skill_id,
        "",
        .disabled,
        .external_run_root,
    );
    defer external.deinit();
}

test "disabled Skill fails before activation or materialization" {
    var fixture = TestFixture.init("Review.", "bash");
    defer fixture.deinit();
    fixture.bind();
    const exceptions = [_]availability.Exception{
        .{
            .skill_id = &fixture.records[0].skill_id,
            .state = .disabled,
        },
    };
    var selection = try availability.Selection.init(
        std.testing.allocator,
        &fixture.snapshot,
        .{ .default_state = .enabled, .exceptions = &exceptions },
    );
    defer selection.deinit();

    try std.testing.expectError(error.SkillDisabled, prepare(
        std.testing.allocator,
        &fixture.snapshot,
        &fixture.snapshot.revision,
        &fixture.records[0].skill_id,
        "{\"values\":[]}",
        .{
            .context = .external_run_root,
            .shell_policy = .unrestricted,
            .model_override_capability = .allowed,
            .availability = .{ .selected = &selection },
        },
    ));
}

test "agent profile metadata fails closed when AgentCore has no AgentDef catalog" {
    var fixture = TestFixture.init("Review.", "bash");
    defer fixture.deinit();
    fixture.records[0].definition.agent = "reviewer";
    fixture.bind();

    try std.testing.expectError(
        error.SkillUnavailable,
        prepareForTest(
            std.testing.allocator,
            &fixture.snapshot,
            &fixture.snapshot.revision,
            &fixture.records[0].skill_id,
            "{\"values\":[]}",
            .sandboxed,
            .external_run_root,
        ),
    );
}

test "model-tool and external callers share activation kernel and parent lineage" {
    var fixture = TestFixture.init("Review $target.", "bash");
    defer fixture.deinit();
    fixture.records[0].definition.arguments = &.{"target"};
    fixture.records[0].definition.allowed_tools = &.{ "Read", "Write" };
    fixture.bind();

    var plan = try prepareForTest(
        std.testing.allocator,
        &fixture.snapshot,
        &fixture.snapshot.revision,
        &fixture.records[0].skill_id,
        "{\"values\":[\"src/main.zig\"]}",
        .disabled,
        .model_tool,
    );
    defer plan.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    var manager = try materialization.Manager.init(std.testing.allocator);
    defer manager.deinit() catch unreachable;
    const root_frame = try policy_frame.PolicyFrame.createRoot(
        std.testing.allocator,
        &.{ "Read", "Write" },
        .disabled,
        .default,
        .{ .cwd = root_path, .project_root = root_path, .home = root_path },
    );
    defer root_frame.release();
    const parent_frame = try policy_frame.PolicyFrame.derive(
        root_frame,
        &.{"Read"},
        &.{},
    );
    defer parent_frame.release();
    var abort = AbortSignal.init();

    {
        var activated = try activate(std.testing.allocator, &plan, .{
            .materializations = &manager,
            .parent_frame = parent_frame,
            .abort = &abort,
            .project_dir = root_path,
            .session_id = "session",
            .sandbox = null,
            .cwd_abs = root_path,
            .home_dir = root_path,
        });
        defer activated.deinit() catch unreachable;
        try std.testing.expect(activated.frame.parent() == parent_frame);
        try std.testing.expect(activated.frame.allowsInvocation("Read", "{}"));
        try std.testing.expect(!activated.frame.allowsInvocation("Write", "{}"));
        try std.testing.expectEqualStrings(
            "Review src/main.zig.\nARGUMENTS: src/main.zig\n",
            activated.rendered_body,
        );
    }
    try std.testing.expectEqual(@as(usize, 0), manager.active_count);
}

test "Activation owns model selection after Plan and catalog teardown" {
    var fixture = TestFixture.init("Review.", "bash");
    var fixture_live = true;
    defer if (fixture_live) fixture.deinit();
    fixture.records[0].definition.context = .fork;
    fixture.records[0].definition.model =
        try fixture.arena.allocator().dupe(u8, "owned-model");
    fixture.bind();

    var plan = try prepare(
        std.testing.allocator,
        &fixture.snapshot,
        &fixture.snapshot.revision,
        &fixture.records[0].skill_id,
        "",
        .{
            .context = .external_run_root,
            .shell_policy = .disabled,
            .model_override_capability = .allowed,
        },
    );
    var plan_live = true;
    defer if (plan_live) plan.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root_path = root_buffer[0..root_len];
    var manager = try materialization.Manager.init(std.testing.allocator);
    defer manager.deinit() catch unreachable;
    const root_frame = try policy_frame.PolicyFrame.createRoot(
        std.testing.allocator,
        &.{},
        .disabled,
        .default,
        .{ .cwd = root_path, .project_root = root_path, .home = root_path },
    );
    defer root_frame.release();
    var abort = AbortSignal.init();

    var activated = try activate(std.testing.allocator, &plan, .{
        .materializations = &manager,
        .parent_frame = root_frame,
        .abort = &abort,
        .project_dir = root_path,
        .session_id = "session",
        .sandbox = null,
        .cwd_abs = root_path,
        .home_dir = root_path,
    });
    defer activated.deinit() catch unreachable;

    plan.deinit();
    plan_live = false;
    fixture.deinit();
    fixture_live = false;
    try std.testing.expectEqualStrings(
        "owned-model",
        activated.model_selection.override,
    );
}

test "Activation model override copy reports allocation failure without leaks" {
    var fixture = TestFixture.init("Review.", "bash");
    defer fixture.deinit();
    fixture.records[0].definition.context = .fork;
    fixture.records[0].definition.model = "owned-model";
    fixture.bind();
    var plan = try prepare(
        std.testing.allocator,
        &fixture.snapshot,
        &fixture.snapshot.revision,
        &fixture.records[0].skill_id,
        "",
        .{
            .context = .external_run_root,
            .shell_policy = .disabled,
            .model_override_capability = .allowed,
        },
    );
    defer plan.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root_path = root_buffer[0..root_len];
    var manager = try materialization.Manager.init(std.testing.allocator);
    defer manager.deinit() catch unreachable;
    const root_frame = try policy_frame.PolicyFrame.createRoot(
        std.testing.allocator,
        &.{},
        .disabled,
        .default,
        .{ .cwd = root_path, .project_root = root_path, .home = root_path },
    );
    defer root_frame.release();
    var abort = AbortSignal.init();
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );

    try std.testing.expectError(
        error.OutOfMemory,
        activate(failing.allocator(), &plan, .{
            .materializations = &manager,
            .parent_frame = root_frame,
            .abort = &abort,
            .project_dir = root_path,
            .session_id = "session",
            .sandbox = null,
            .cwd_abs = root_path,
            .home_dir = root_path,
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), manager.active_count);
}
