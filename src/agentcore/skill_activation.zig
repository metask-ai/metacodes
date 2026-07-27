//! Pure admission for a typed Skill invocation.
//!
//! `prepare` deliberately performs no filesystem, provider, tool, Conversation,
//! or Run-lifecycle work. A successful result is an immutable, owned plan that
//! may safely cross the `beginRun` admission point.

const std = @import("std");
const catalog = @import("skill_catalog.zig");
const core = @import("metacodes-core");
const workspace = core.workspace_policy;

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
    SkillUnavailable,
};

pub const ActivationPlan = struct {
    arena: std.heap.ArenaAllocator,
    snapshot: *const catalog.Snapshot,
    skill: *const catalog.SkillRecord,
    arguments: []const []const u8,
    requires_shell: bool,

    pub fn deinit(self: *ActivationPlan) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn prepare(
    owner_allocator: std.mem.Allocator,
    snapshot: *const catalog.Snapshot,
    catalog_revision: []const u8,
    skill_id: []const u8,
    arguments_json: []const u8,
    shell_policy: workspace.ShellPolicy,
) PrepareError!ActivationPlan {
    var arena = std.heap.ArenaAllocator.init(owner_allocator);
    errdefer arena.deinit();
    const arguments = try parseArguments(arena.allocator(), arguments_json);

    if (!catalog.isLowerHex64(catalog_revision)) return error.InvalidCatalogRevision;
    if (!std.mem.eql(u8, &snapshot.revision, catalog_revision)) return error.StaleCatalog;
    if (!catalog.isLowerHex64(skill_id)) return error.InvalidSkillId;
    const skill = snapshot.findById(skill_id) orelse return error.SkillNotFound;

    const requires_shell = core.skills_render.hasShellInjection(skill.definition.body);

    if (requires_shell and shell_policy == .disabled) return error.PolicyViolation;
    if (requires_shell and std.mem.eql(u8, skill.definition.shell, "powershell"))
        return error.SkillUnavailable;

    return .{
        .arena = arena,
        .snapshot = snapshot,
        .skill = skill,
        .arguments = arguments,
        .requires_shell = requires_shell,
    };
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

test "ActivationPlan owns canonical typed arguments and retains immutable identities" {
    var fixture = TestFixture.init("Review $target at $depth.", "bash");
    defer fixture.deinit();
    fixture.bind();

    var plan = try prepare(
        std.testing.allocator,
        &fixture.snapshot,
        &fixture.snapshot.revision,
        &fixture.records[0].skill_id,
        "{\"values\":[\"src/main.zig\",\"deep\"]}",
        .disabled,
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

    try std.testing.expectError(error.InvalidCatalogRevision, prepare(
        std.testing.allocator,
        &fixture.snapshot,
        "A",
        &fixture.records[0].skill_id,
        "",
        .disabled,
    ));
    try std.testing.expectError(error.StaleCatalog, prepare(
        std.testing.allocator,
        &fixture.snapshot,
        &([_]u8{'d'} ** 64),
        &fixture.records[0].skill_id,
        "",
        .disabled,
    ));
    try std.testing.expectError(error.InvalidSkillId, prepare(
        std.testing.allocator,
        &fixture.snapshot,
        &fixture.snapshot.revision,
        "not-an-id",
        "",
        .disabled,
    ));
    try std.testing.expectError(error.SkillNotFound, prepare(
        std.testing.allocator,
        &fixture.snapshot,
        &fixture.snapshot.revision,
        &([_]u8{'d'} ** 64),
        "",
        .disabled,
    ));
}

test "argument bounds and decoding precede catalog identity checks" {
    var fixture = TestFixture.init("Review.", "bash");
    defer fixture.deinit();
    fixture.bind();

    const too_large = try std.testing.allocator.alloc(u8, MAX_ARGUMENT_JSON_BYTES + 1);
    defer std.testing.allocator.free(too_large);
    @memset(too_large, 0xff);
    try std.testing.expectError(error.ResourceLimit, prepare(
        std.testing.allocator,
        &fixture.snapshot,
        "not-a-revision",
        "not-an-id",
        too_large,
        .disabled,
    ));
    try std.testing.expectError(error.InvalidArguments, prepare(
        std.testing.allocator,
        &fixture.snapshot,
        "not-a-revision",
        "not-an-id",
        &[_]u8{0xff},
        .disabled,
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
        try std.testing.expectError(error.InvalidArguments, prepare(
            std.testing.allocator,
            &fixture.snapshot,
            &fixture.snapshot.revision,
            &fixture.records[0].skill_id,
            encoded,
            .disabled,
        ));
    }

    const too_large = try std.testing.allocator.alloc(u8, MAX_ARGUMENT_JSON_BYTES + 1);
    defer std.testing.allocator.free(too_large);
    @memset(too_large, 0xff);
    try std.testing.expectError(error.ResourceLimit, prepare(
        std.testing.allocator,
        &fixture.snapshot,
        &fixture.snapshot.revision,
        &fixture.records[0].skill_id,
        too_large,
        .disabled,
    ));

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try writer.writer.writeAll("{\"values\":[");
    for (0..MAX_ARGUMENT_VALUES + 1) |index| {
        if (index != 0) try writer.writer.writeByte(',');
        try writer.writer.writeAll("\"x\"");
    }
    try writer.writer.writeAll("]}");
    try std.testing.expectError(error.InvalidArguments, prepare(
        std.testing.allocator,
        &fixture.snapshot,
        &fixture.snapshot.revision,
        &fixture.records[0].skill_id,
        writer.written(),
        .disabled,
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
            try std.testing.expectError(error.PolicyViolation, prepare(
                std.testing.allocator,
                &fixture.snapshot,
                &fixture.snapshot.revision,
                &fixture.records[0].skill_id,
                "",
                .disabled,
            ));
            var allowed = try prepare(
                std.testing.allocator,
                &fixture.snapshot,
                &fixture.snapshot.revision,
                &fixture.records[0].skill_id,
                "",
                .sandboxed,
            );
            defer allowed.deinit();
            try std.testing.expect(allowed.requires_shell);
        } else {
            var plan = try prepare(
                std.testing.allocator,
                &fixture.snapshot,
                &fixture.snapshot.revision,
                &fixture.records[0].skill_id,
                "",
                .disabled,
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
    try std.testing.expectError(error.SkillUnavailable, prepare(
        std.testing.allocator,
        &executable.snapshot,
        &executable.snapshot.revision,
        &executable.records[0].skill_id,
        "",
        .unrestricted,
    ));

    var inert = TestFixture.init("Explain PowerShell.", "powershell");
    defer inert.deinit();
    inert.bind();
    var plan = try prepare(
        std.testing.allocator,
        &inert.snapshot,
        &inert.snapshot.revision,
        &inert.records[0].skill_id,
        "",
        .disabled,
    );
    defer plan.deinit();
    try std.testing.expect(!plan.requires_shell);
}
