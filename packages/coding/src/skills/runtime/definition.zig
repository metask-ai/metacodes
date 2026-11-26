const std = @import("std");
const frontmatter = @import("frontmatter.zig");

/// Skill execution mode. UI adapters may choose how to present it, but the
/// semantic value is owned by the shared Skill Runtime.
pub const ExecContext = enum { inline_ctx, fork };

/// Model-facing activation is behavioral routing metadata, not authority.
/// `required_first` asks a compatible provider dialect to select the Skill
/// tool once before ordinary work; dispatch and policy admission stay native.
pub const ModelActivation = enum {
    advisory,
    required_first,
};

/// Where a Skill's `description` came from. Listings - the model's and the
/// `/` menu's - are built from it, so a Skill without one is reported by
/// `/skills` instead of being listed silently with a guess or with nothing.
pub const DescriptionSource = enum {
    /// The frontmatter's own `description`.
    frontmatter,
    /// Absent or blank in the frontmatter; the first non-empty body line
    /// stands in (Claude Code's fallback, `ParseOptions.description_fallback`).
    body_first_line,
    /// Absent or blank, and nothing stands in: listings show no description.
    missing,
};

/// A SKILL.md that breaks the Agent Skills specification in a way the parser
/// repairs instead of refusing. A refusal is a `ParseError` (the catalog's
/// `invalid_definition`: the Skill does not load); a warning leaves the Skill
/// loaded, and `/skills` reports it.
pub const Warning = enum {
    /// `name` is empty or whitespace-only. It is read as absent, so the
    /// directory name stands in, as in Codex.
    blank_name,
    /// `description` is empty or whitespace-only. It is read as absent, so
    /// the first body line stands in where the profile falls back, as in
    /// Claude Code; `description_source` says what the listings got.
    blank_description,
};

pub const Warnings = std.EnumSet(Warning);

/// Canonical parsed SKILL.md definition shared by every product adapter.
pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    description_source: DescriptionSource,
    /// Required, like `description_source`, so a clone cannot drop it.
    warnings: Warnings,
    /// Claude Code `when_to_use`: appended to the description in listings.
    when_to_use: []const u8,
    /// Claude Code `argument-hint`: shown beside the command in the `/` menu.
    argument_hint: []const u8,
    body: []const u8,
    allowed_tools: []const []const u8,
    disallowed_tools: []const []const u8,
    arguments: []const []const u8,
    disable_model_invocation: bool,
    /// Claude Code `user-invocable: false` hides the Skill from the `/` menu
    /// while the model may still invoke it.
    user_invocable: bool,
    model_activation: ModelActivation = .advisory,
    context: ExecContext,
    agent: []const u8,
    model: []const u8,
    shell: []const u8,
    source_path: []const u8,
    /// SSP/1 binding (doc/SEALED_SKILL_PROTOCOL.md §9): set only for a pinned
    /// sealed Skill, whose body lives on that gateway. All three are present or
    /// all three are empty; a sealed Skill always runs as a fork.
    sealed_gateway: []const u8 = "",
    sealed_skill_id: []const u8 = "",
    sealed_manifest_digest: []const u8 = "",

    pub fn isSealed(self: *const Skill) bool {
        return self.sealed_skill_id.len != 0;
    }

    /// Loaded, but with something `/skills` reports: no `description` of its
    /// own, or a warning.
    pub fn hasDefinitionProblem(self: *const Skill) bool {
        return self.description_source != .frontmatter or self.warnings.count() != 0;
    }

    pub fn deinit(self: Skill, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.when_to_use);
        allocator.free(self.argument_hint);
        allocator.free(self.body);
        for (self.allowed_tools) |tool| allocator.free(tool);
        allocator.free(self.allowed_tools);
        for (self.disallowed_tools) |tool| allocator.free(tool);
        allocator.free(self.disallowed_tools);
        for (self.arguments) |argument| allocator.free(argument);
        allocator.free(self.arguments);
        allocator.free(self.agent);
        allocator.free(self.model);
        allocator.free(self.shell);
        allocator.free(self.source_path);
        allocator.free(self.sealed_gateway);
        allocator.free(self.sealed_skill_id);
        allocator.free(self.sealed_manifest_digest);
    }
};

pub const ParseError = error{
    OutOfMemory,
    MissingSkillName,
    InvalidFrontmatter,
    InvalidModelActivation,
    InvalidContext,
    InvalidShell,
    InvalidBoolean,
    InvalidFieldType,
    /// `sealed-gateway`, `sealed-skill-id` and `sealed-manifest-digest` must
    /// all be present (and non-empty) or all be absent.
    InvalidSealedBinding,
};

pub const ParseOptions = struct {
    /// Claude Code fills a missing `description` with the first non-empty body
    /// line. AgentCore's canonical catalog keeps the field empty instead.
    description_fallback: bool = false,
};

/// Parse SKILL.md, using the directory name when frontmatter omits `name`.
/// A blank `name` or `description` counts as omitted and adds a `Warning`.
///
/// The frontmatter is YAML (Claude Code and Codex both parse it as such), read
/// through the bounded subset parser in `frontmatter.zig`. Unknown keys are
/// ignored; the policy-bearing fields (`context`, `shell`, booleans,
/// `model-activation`) are validated strictly so a malformed value becomes a
/// typed failure instead of silently changing meaning.
pub fn parseSkillMdWithFallback(
    allocator: std.mem.Allocator,
    md: []const u8,
    source_path: []const u8,
    dir_name: []const u8,
) ParseError!Skill {
    return parseSkillMdWithOptions(allocator, md, source_path, dir_name, .{});
}

pub fn parseSkillMdWithOptions(
    allocator: std.mem.Allocator,
    md: []const u8,
    source_path: []const u8,
    dir_name: []const u8,
    options: ParseOptions,
) ParseError!Skill {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    var body: []const u8 = md;
    var root: frontmatter.Node = .{ .mapping = &.{} };
    const split = frontmatter.splitFrontmatter(md) catch return error.InvalidFrontmatter;
    if (split) |parts| {
        body = parts.body;
        root = frontmatter.parse(arena, parts.yaml, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidYaml => return error.InvalidFrontmatter,
        };
    }

    var name = try optionalText(root, &.{"name"});
    var description = try optionalText(root, &.{"description"});
    const when_to_use = try optionalText(root, &.{ "when_to_use", "when-to-use" });
    const argument_hint = try optionalHint(arena, root, &.{ "argument-hint", "argument_hint" });
    const disable_invoke = try optionalBool(root, &.{ "disable-model-invocation", "disable_model_invocation" }) orelse false;
    const user_invocable = try optionalBool(root, &.{ "user-invocable", "user_invocable" }) orelse true;
    const model_activation: ModelActivation = if (try optionalText(root, &.{ "model-activation", "model_activation" })) |value|
        parseModelActivation(value) orelse return error.InvalidModelActivation
    else
        .advisory;
    var context: ExecContext = if (try optionalText(root, &.{"context"})) |value| blk: {
        if (value.len == 0 or std.mem.eql(u8, value, "inline")) break :blk .inline_ctx;
        if (std.mem.eql(u8, value, "fork")) break :blk .fork;
        return error.InvalidContext;
    } else .inline_ctx;
    const sealed_gateway = try optionalText(root, &.{ "sealed-gateway", "sealed_gateway" }) orelse "";
    const sealed_skill_id = try optionalText(root, &.{ "sealed-skill-id", "sealed_skill_id" }) orelse "";
    const sealed_manifest_digest = try optionalText(root, &.{ "sealed-manifest-digest", "sealed_manifest_digest" }) orelse "";
    const sealed_present: u8 = @as(u8, @intFromBool(sealed_gateway.len != 0)) +
        @as(u8, @intFromBool(sealed_skill_id.len != 0)) +
        @as(u8, @intFromBool(sealed_manifest_digest.len != 0));
    if (sealed_present != 0 and sealed_present != 3) return error.InvalidSealedBinding;
    // The body of a sealed Skill is on the gateway; it can only run as a fork
    // whose model is the gateway. Never inline the (empty) local body.
    if (sealed_present == 3) context = .fork;
    const agent_str = try optionalText(root, &.{"agent"}) orelse "";
    const model_str = try optionalText(root, &.{"model"}) orelse "";
    const shell_str = if (try optionalText(root, &.{"shell"})) |value| blk: {
        if (value.len == 0) break :blk "bash";
        if (!std.mem.eql(u8, value, "bash") and !std.mem.eql(u8, value, "powershell"))
            return error.InvalidShell;
        break :blk value;
    } else "bash";

    // The Agent Skills specification requires both to be non-empty. Claude
    // Code (description) and Codex (both) read a blank one as absent, so the
    // same fallback stands in for it; the warning keeps the defect visible.
    var warnings: Warnings = .{};
    if (name != null and isBlank(name.?)) {
        name = null;
        warnings.insert(.blank_name);
    }
    if (description != null and isBlank(description.?)) {
        description = null;
        warnings.insert(.blank_description);
    }

    if (name == null) name = dir_name;
    if (name.?.len == 0) return error.MissingSkillName;
    var description_source: DescriptionSource = .frontmatter;
    if (description == null and options.description_fallback) {
        description = firstBodyLine(body);
        description_source = .body_first_line;
    }
    if (description == null) description_source = .missing;

    const allowed_tools = try optionalList(allocator, root, &.{ "allowed-tools", "allowed_tools" });
    errdefer freeStringList(allocator, allowed_tools);
    const disallowed_tools = try optionalList(allocator, root, &.{ "disallowed-tools", "disallowed_tools" });
    errdefer freeStringList(allocator, disallowed_tools);
    const arguments = try optionalList(allocator, root, &.{"arguments"});
    errdefer freeStringList(allocator, arguments);

    const owned_name = try allocator.dupe(u8, name.?);
    errdefer allocator.free(owned_name);
    const owned_description = try allocator.dupe(u8, description orelse "");
    errdefer allocator.free(owned_description);
    const owned_when_to_use = try allocator.dupe(u8, when_to_use orelse "");
    errdefer allocator.free(owned_when_to_use);
    const owned_argument_hint = try allocator.dupe(u8, argument_hint orelse "");
    errdefer allocator.free(owned_argument_hint);
    const owned_body = try allocator.dupe(u8, body);
    errdefer allocator.free(owned_body);
    const owned_agent = try allocator.dupe(u8, agent_str);
    errdefer allocator.free(owned_agent);
    const owned_model = try allocator.dupe(u8, model_str);
    errdefer allocator.free(owned_model);
    const owned_shell = try allocator.dupe(u8, shell_str);
    errdefer allocator.free(owned_shell);
    const owned_source_path = try allocator.dupe(u8, source_path);
    errdefer allocator.free(owned_source_path);
    const owned_sealed_gateway = try allocator.dupe(u8, sealed_gateway);
    errdefer allocator.free(owned_sealed_gateway);
    const owned_sealed_skill_id = try allocator.dupe(u8, sealed_skill_id);
    errdefer allocator.free(owned_sealed_skill_id);
    const owned_sealed_manifest_digest = try allocator.dupe(u8, sealed_manifest_digest);
    errdefer allocator.free(owned_sealed_manifest_digest);

    return .{
        .name = owned_name,
        .description = owned_description,
        .description_source = description_source,
        .warnings = warnings,
        .when_to_use = owned_when_to_use,
        .argument_hint = owned_argument_hint,
        .body = owned_body,
        .allowed_tools = allowed_tools,
        .disallowed_tools = disallowed_tools,
        .arguments = arguments,
        .disable_model_invocation = disable_invoke,
        .user_invocable = user_invocable,
        .model_activation = model_activation,
        .context = context,
        .agent = owned_agent,
        .model = owned_model,
        .shell = owned_shell,
        .source_path = owned_source_path,
        .sealed_gateway = owned_sealed_gateway,
        .sealed_skill_id = owned_sealed_skill_id,
        .sealed_manifest_digest = owned_sealed_manifest_digest,
    };
}

/// Codex `agents/openai.yaml` sidecar policy relevant to discovery. Parsing
/// fails open (null), as Codex does: a broken sidecar never hides the Skill.
pub const CodexSidecar = struct {
    allow_implicit_invocation: bool = true,
};

pub fn parseCodexSidecar(allocator: std.mem.Allocator, yaml: []const u8) error{OutOfMemory}!?CodexSidecar {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const root = frontmatter.parse(scratch.allocator(), yaml, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidYaml => return null,
    };
    var sidecar = CodexSidecar{};
    if (root.get("policy")) |policy| {
        if (policy.get("allow_implicit_invocation")) |value| {
            const text = value.text() orelse return null;
            sidecar.allow_implicit_invocation = frontmatter.parseBool(text) orelse return null;
        }
    }
    return sidecar;
}

fn lookup(root: frontmatter.Node, keys: []const []const u8) ?frontmatter.Node {
    for (keys) |key| {
        if (root.get(key)) |value| return value;
    }
    return null;
}

fn optionalText(root: frontmatter.Node, keys: []const []const u8) ParseError!?[]const u8 {
    const node = lookup(root, keys) orelse return null;
    return node.text() orelse error.InvalidFieldType;
}

/// Claude Code documents `argument-hint: [issue-number]`, which YAML reads as a
/// one-item sequence; render a sequence back to its bracketed text.
fn optionalHint(arena: std.mem.Allocator, root: frontmatter.Node, keys: []const []const u8) ParseError!?[]const u8 {
    const node = lookup(root, keys) orelse return null;
    switch (node) {
        .scalar => |text| return text,
        .sequence => |items| {
            var out: std.ArrayList(u8) = .empty;
            try out.append(arena, '[');
            for (items, 0..) |item, index| {
                if (index != 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, item.text() orelse return error.InvalidFieldType);
            }
            try out.append(arena, ']');
            return try out.toOwnedSlice(arena);
        },
        .mapping => return error.InvalidFieldType,
    }
}

fn optionalBool(root: frontmatter.Node, keys: []const []const u8) ParseError!?bool {
    const text = try optionalText(root, keys) orelse return null;
    return frontmatter.parseBool(text) orelse error.InvalidBoolean;
}

/// A list field is either a YAML sequence of scalars or one scalar using the
/// space/comma-separated Claude Code form.
fn optionalList(
    allocator: std.mem.Allocator,
    root: frontmatter.Node,
    keys: []const []const u8,
) ParseError![]const []const u8 {
    const node = lookup(root, keys) orelse return parseStringList(allocator, "");
    switch (node) {
        .scalar => |text| return parseStringList(allocator, text),
        .sequence => |items| {
            var out: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (out.items) |value| allocator.free(value);
                out.deinit(allocator);
            }
            for (items) |item| {
                const text = std.mem.trim(u8, item.text() orelse return error.InvalidFieldType, " \t");
                if (text.len == 0) continue;
                try appendOwnedString(allocator, &out, text);
            }
            return out.toOwnedSlice(allocator);
        },
        .mapping => return error.InvalidFieldType,
    }
}

fn isBlank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t\r\n").len == 0;
}

fn firstBodyLine(body: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len != 0) return trimmed;
    }
    return null;
}

pub fn parseSkillMd(
    allocator: std.mem.Allocator,
    md: []const u8,
    source_path: []const u8,
) ParseError!Skill {
    return parseSkillMdWithFallback(allocator, md, source_path, "");
}

pub fn parseStringList(allocator: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |value| allocator.free(value);
        out.deinit(allocator);
    }

    var value = std.mem.trim(u8, raw, " \t");
    if (value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']') {
        value = value[1 .. value.len - 1];
    }
    if (value.len == 0) return try out.toOwnedSlice(allocator);

    var depth: i32 = 0;
    var start: usize = 0;
    var index: usize = 0;
    while (index <= value.len) : (index += 1) {
        if (index == value.len or (value[index] == ',' and depth == 0)) {
            const segment = std.mem.trim(u8, value[start..index], " \t");
            if (segment.len > 0) {
                if (!hasParen(segment)) {
                    var tokens = std.mem.tokenizeAny(u8, segment, " \t");
                    while (tokens.next()) |token| {
                        const trimmed = std.mem.trim(u8, token, " \t");
                        if (trimmed.len > 0) {
                            try appendOwnedString(allocator, &out, trimmed);
                        }
                    }
                } else {
                    try appendOwnedString(allocator, &out, segment);
                }
            }
            start = index + 1;
            continue;
        }
        if (value[index] == '(') depth += 1;
        if (value[index] == ')') depth -= 1;
    }

    return try out.toOwnedSlice(allocator);
}

fn appendOwnedString(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try out.append(allocator, owned);
}

fn hasParen(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, '(') != null;
}

pub fn freeStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn parseModelActivation(value: []const u8) ?ModelActivation {
    if (std.mem.eql(u8, value, "advisory")) return .advisory;
    if (std.mem.eql(u8, value, "required-first") or
        std.mem.eql(u8, value, "required_first")) return .required_first;
    return null;
}

test "parseSkillMdWithFallback releases every partial allocation" {
    const md =
        "---\n" ++
        "description: >\n" ++
        "  allocation fault\n" ++
        "  fixture\n" ++
        "when_to_use: \"when 'quoted'\"\n" ++
        "allowed-tools:\n" ++
        "  - Read\n" ++
        "  - Bash(git *)\n" ++
        "  - Grep\n" ++
        "disallowed-tools: Write\n" ++
        "arguments: target, scope\n" ++
        "context: fork\n" ++
        "agent: general-purpose\n" ++
        "model: fixture-model\n" ++
        "shell: bash\n" ++
        "---\n" ++
        "Review $target in $scope.\n";

    var reached_success = false;
    var fail_index: usize = 0;
    while (fail_index < 1024) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        const result = parseSkillMdWithFallback(
            failing.allocator(),
            md,
            "/fixture/review",
            "review",
        );
        if (result) |skill| {
            skill.deinit(failing.allocator());
            reached_success = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
    try std.testing.expect(reached_success);
}

test "parseSkillMd preserves minimal frontmatter defaults" {
    const md =
        "---\n" ++
        "name: test-skill\n" ++
        "description: A test skill\n" ++
        "---\n" ++
        "Body content here.\n";
    const skill = try parseSkillMd(std.testing.allocator, md, "/tmp/fake");
    defer skill.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("test-skill", skill.name);
    try std.testing.expectEqualStrings("A test skill", skill.description);
    try std.testing.expect(std.mem.indexOf(u8, skill.body, "Body content") != null);
    try std.testing.expectEqual(@as(usize, 0), skill.allowed_tools.len);
    try std.testing.expect(!skill.disable_model_invocation);
    try std.testing.expectEqual(ExecContext.inline_ctx, skill.context);
}

test "parseSkillMd accepts allowed_tools legacy spelling" {
    const md =
        "---\n" ++
        "name: scoped\n" ++
        "description: desc\n" ++
        "allowed_tools: Read, Grep, Glob\n" ++
        "---\n" ++
        "body";
    const skill = try parseSkillMd(std.testing.allocator, md, "/tmp/fake");
    defer skill.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), skill.allowed_tools.len);
    try std.testing.expectEqualStrings("Read", skill.allowed_tools[0]);
}

test "parseSkillMd preserves parenthesized tool rules" {
    const md =
        "---\n" ++
        "name: gitops\n" ++
        "description: git ops\n" ++
        "allowed-tools: Read, Bash(git *), Grep\n" ++
        "---\n" ++
        "body";
    const skill = try parseSkillMd(std.testing.allocator, md, "/x");
    defer skill.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), skill.allowed_tools.len);
    try std.testing.expectEqualStrings("Read", skill.allowed_tools[0]);
    try std.testing.expectEqualStrings("Bash(git *)", skill.allowed_tools[1]);
    try std.testing.expectEqualStrings("Grep", skill.allowed_tools[2]);
}

test "parseSkillMd accepts bracketed lists" {
    const md =
        "---\n" ++
        "name: yl\n" ++
        "description: yaml list\n" ++
        "allowed-tools: [Read, Grep]\n" ++
        "arguments: [issue, branch]\n" ++
        "---\n" ++
        "body";
    const skill = try parseSkillMd(std.testing.allocator, md, "/x");
    defer skill.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), skill.allowed_tools.len);
    try std.testing.expectEqual(@as(usize, 2), skill.arguments.len);
    try std.testing.expectEqualStrings("issue", skill.arguments[0]);
}

test "parseSkillMd preserves invocation and execution metadata" {
    const md =
        "---\n" ++
        "name: pr-summary\n" ++
        "description: Summarize PR\n" ++
        "disable-model-invocation: true\n" ++
        "model-activation: required-first\n" ++
        "context: fork\n" ++
        "agent: Explore\n" ++
        "model: claude-haiku-4-5-20251001\n" ++
        "shell: bash\n" ++
        "---\n" ++
        "body";
    const skill = try parseSkillMd(std.testing.allocator, md, "/x");
    defer skill.deinit(std.testing.allocator);
    try std.testing.expect(skill.disable_model_invocation);
    try std.testing.expectEqual(ModelActivation.required_first, skill.model_activation);
    try std.testing.expectEqual(ExecContext.fork, skill.context);
    try std.testing.expectEqualStrings("Explore", skill.agent);
    try std.testing.expectEqualStrings("claude-haiku-4-5-20251001", skill.model);
    try std.testing.expectEqualStrings("bash", skill.shell);
}

test "parseSkillMd rejects unknown model activation instead of guessing" {
    try std.testing.expectError(
        error.InvalidModelActivation,
        parseSkillMd(
            std.testing.allocator,
            "---\nname: bad\nmodel-activation: sometimes\n---\nbody",
            "/x",
        ),
    );
}

test "parseSkillMdWithFallback uses directory invocation name" {
    const md =
        "---\n" ++
        "description: no name in fm\n" ++
        "---\n" ++
        "body";
    const skill = try parseSkillMdWithFallback(
        std.testing.allocator,
        md,
        "/tmp/auto",
        "auto-name",
    );
    defer skill.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("auto-name", skill.name);
}

test "parseSkillMd rejects nameless body without fallback" {
    try std.testing.expectError(
        error.MissingSkillName,
        parseSkillMd(std.testing.allocator, "just body\n", "/x"),
    );
}

test "parseSkillMd ignores frontmatter comments" {
    const md =
        "---\n" ++
        "# this is a comment\n" ++
        "name: c\n" ++
        "description: d\n" ++
        "---\n" ++
        "body";
    const skill = try parseSkillMd(std.testing.allocator, md, "/x");
    defer skill.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("c", skill.name);
}

test "parseStringList accepts whitespace and bracketed forms" {
    const whitespace = try parseStringList(std.testing.allocator, "Read Grep Glob");
    defer freeStringList(std.testing.allocator, whitespace);
    try std.testing.expectEqual(@as(usize, 3), whitespace.len);

    const bracketed = try parseStringList(std.testing.allocator, "[a, b, c]");
    defer freeStringList(std.testing.allocator, bracketed);
    try std.testing.expectEqual(@as(usize, 3), bracketed.len);
    try std.testing.expectEqualStrings("a", bracketed[0]);
}

test "parseStringList accepts empty input" {
    const values = try parseStringList(std.testing.allocator, "");
    defer freeStringList(std.testing.allocator, values);
    try std.testing.expectEqual(@as(usize, 0), values.len);
}

test "YAML frontmatter: folded, quoted, CRLF and block lists parse like Claude Code and Codex" {
    const md =
        "\xEF\xBB\xBF---\r\n" ++
        "name: \"pdf\"\r\n" ++
        "description: >\r\n" ++
        "  Use when tasks involve\r\n" ++
        "  PDF files.\r\n" ++
        "when_to_use: 'it''s a PDF'\r\n" ++
        "argument-hint: [file]\r\n" ++
        "user-invocable: No\r\n" ++
        "allowed-tools:\r\n" ++
        "  - Read\r\n" ++
        "  - Bash(pdftoppm *)\r\n" ++
        "metadata:\r\n" ++
        "  name: ignored-nested\r\n" ++
        "license: MIT\r\n" ++
        "---\r\n" ++
        "Body.\r\n";
    const skill = try parseSkillMdWithFallback(std.testing.allocator, md, "/x", "dir");
    defer skill.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("pdf", skill.name);
    try std.testing.expectEqualStrings("Use when tasks involve PDF files.\n", skill.description);
    try std.testing.expectEqualStrings("it's a PDF", skill.when_to_use);
    try std.testing.expectEqualStrings("[file]", skill.argument_hint);
    try std.testing.expect(!skill.user_invocable);
    try std.testing.expectEqual(@as(usize, 2), skill.allowed_tools.len);
    try std.testing.expectEqualStrings("Bash(pdftoppm *)", skill.allowed_tools[1]);
    try std.testing.expectEqualStrings("Body.\r\n", skill.body);
}

test "frontmatter type mismatches and malformed YAML are typed failures" {
    try std.testing.expectError(error.InvalidFrontmatter, parseSkillMd(std.testing.allocator, "---\nname: x\nno close\n", "/x"));
    try std.testing.expectError(error.InvalidFrontmatter, parseSkillMd(std.testing.allocator, "---\nname: &a x\n---\n", "/x"));
    try std.testing.expectError(error.InvalidFieldType, parseSkillMd(std.testing.allocator, "---\nname: [a, b]\n---\n", "/x"));
    try std.testing.expectError(error.InvalidBoolean, parseSkillMd(std.testing.allocator, "---\nname: x\ndisable-model-invocation: maybe\n---\n", "/x"));
    try std.testing.expectError(error.InvalidContext, parseSkillMd(std.testing.allocator, "---\nname: x\ncontext: sideways\n---\n", "/x"));
    try std.testing.expectError(error.InvalidShell, parseSkillMd(std.testing.allocator, "---\nname: x\nshell: zsh\n---\n", "/x"));
}

test "description falls back to the first body line only when asked" {
    const md = "---\nname: x\n---\n\n  # Title line\nmore\n";
    const plain = try parseSkillMd(std.testing.allocator, md, "/x");
    defer plain.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", plain.description);
    const fallback = try parseSkillMdWithOptions(std.testing.allocator, md, "/x", "x", .{ .description_fallback = true });
    defer fallback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("# Title line", fallback.description);
}

test "description source records the frontmatter, the fallback, or nothing" {
    const a = std.testing.allocator;
    const Case = struct { md: []const u8, fallback: bool, source: DescriptionSource, description: []const u8, blank: bool = false };
    const cases = [_]Case{
        .{ .md = "---\nname: x\ndescription: Review diffs\n---\nbody\n", .fallback = true, .source = .frontmatter, .description = "Review diffs" },
        .{ .md = "---\nname: x\ndescription: Review diffs\n---\nbody\n", .fallback = false, .source = .frontmatter, .description = "Review diffs" },
        .{ .md = "---\nname: x\n---\n\nFirst line\n", .fallback = true, .source = .body_first_line, .description = "First line" },
        .{ .md = "---\nname: x\n---\n\nFirst line\n", .fallback = false, .source = .missing, .description = "" },
        .{ .md = "---\nname: x\n---\n \n", .fallback = true, .source = .missing, .description = "" },
        // A blank `description` is read as absent (#395): it gets the same
        // fallback, or none, and records a warning. It used to be listed as
        // the blank text, with no fallback.
        .{ .md = "---\nname: x\ndescription: \"  \"\n---\nbody\n", .fallback = true, .source = .body_first_line, .description = "body", .blank = true },
        .{ .md = "---\nname: x\ndescription: \"  \"\n---\nbody\n", .fallback = false, .source = .missing, .description = "", .blank = true },
        .{ .md = "---\nname: x\ndescription: \"  \"\n---\n \n", .fallback = true, .source = .missing, .description = "", .blank = true },
        .{ .md = "No frontmatter at all\n", .fallback = true, .source = .body_first_line, .description = "No frontmatter at all" },
    };
    for (cases) |case| {
        const skill = try parseSkillMdWithOptions(a, case.md, "/x", "x", .{ .description_fallback = case.fallback });
        defer skill.deinit(a);
        try std.testing.expectEqual(case.source, skill.description_source);
        try std.testing.expectEqualStrings(case.description, skill.description);
        try std.testing.expectEqual(case.blank, skill.warnings.contains(.blank_description));
        try std.testing.expectEqual(case.source != .frontmatter, skill.hasDefinitionProblem());
    }
}

test "a blank name or description is read as absent, with a warning; an absent one has none" {
    const a = std.testing.allocator;
    const body = "\nUse for demonstrating an empty frontmatter.\n";
    const Case = struct {
        frontmatter: []const u8,
        name: []const u8,
        description: []const u8,
        source: DescriptionSource,
        warnings: Warnings,
    };
    const cases = [_]Case{
        // The #395 reproduction: both explicitly empty.
        .{ .frontmatter = "name: \"\"\ndescription: \"\"\n", .name = "demo", .description = "Use for demonstrating an empty frontmatter.", .source = .body_first_line, .warnings = .init(.{ .blank_name = true, .blank_description = true }) },
        // Explicitly empty, one field at a time; single quotes and a bare key.
        .{ .frontmatter = "name: ''\ndescription: Demo things\n", .name = "demo", .description = "Demo things", .source = .frontmatter, .warnings = .init(.{ .blank_name = true }) },
        .{ .frontmatter = "name: shown\ndescription:\n", .name = "shown", .description = "Use for demonstrating an empty frontmatter.", .source = .body_first_line, .warnings = .init(.{ .blank_description = true }) },
        // Whitespace-only, including a folded block with no text.
        .{ .frontmatter = "name: \"  \"\ndescription: \"\\t \"\n", .name = "demo", .description = "Use for demonstrating an empty frontmatter.", .source = .body_first_line, .warnings = .init(.{ .blank_name = true, .blank_description = true }) },
        .{ .frontmatter = "name: shown\ndescription: >\n\n", .name = "shown", .description = "Use for demonstrating an empty frontmatter.", .source = .body_first_line, .warnings = .init(.{ .blank_description = true }) },
        // Absent: the same fallbacks, and no warning.
        .{ .frontmatter = "description: Demo things\n", .name = "demo", .description = "Demo things", .source = .frontmatter, .warnings = .{} },
        .{ .frontmatter = "name: shown\n", .name = "shown", .description = "Use for demonstrating an empty frontmatter.", .source = .body_first_line, .warnings = .{} },
        .{ .frontmatter = "license: MIT\n", .name = "demo", .description = "Use for demonstrating an empty frontmatter.", .source = .body_first_line, .warnings = .{} },
        // Present: kept as written.
        .{ .frontmatter = "name: shown\ndescription: Demo things\n", .name = "shown", .description = "Demo things", .source = .frontmatter, .warnings = .{} },
    };
    for (cases) |case| {
        const md = try std.mem.concat(a, u8, &.{ "---\n", case.frontmatter, "---\n", body });
        defer a.free(md);
        const skill = try parseSkillMdWithOptions(a, md, "/x", "demo", .{ .description_fallback = true });
        defer skill.deinit(a);
        try std.testing.expectEqualStrings(case.name, skill.name);
        try std.testing.expectEqualStrings(case.description, skill.description);
        try std.testing.expectEqual(case.source, skill.description_source);
        try std.testing.expect(case.warnings.eql(skill.warnings));
        try std.testing.expectEqual(case.source != .frontmatter or case.warnings.count() != 0, skill.hasDefinitionProblem());
    }
}

test "a blank field never refuses a Skill that loads when the field is absent" {
    const a = std.testing.allocator;
    // Without a fallback the description stays empty, exactly as when absent.
    const strict = try parseSkillMdWithOptions(a, "---\nname: \"\"\ndescription: \"\"\n---\nbody\n", "/x", "demo", .{});
    defer strict.deinit(a);
    try std.testing.expectEqualStrings("demo", strict.name);
    try std.testing.expectEqualStrings("", strict.description);
    try std.testing.expectEqual(DescriptionSource.missing, strict.description_source);
    try std.testing.expect(strict.warnings.eql(.init(.{ .blank_name = true, .blank_description = true })));

    // An empty body leaves nothing to fall back to: listed with no description.
    const hollow = try parseSkillMdWithOptions(a, "---\ndescription: \" \"\n---\n", "/x", "hollow", .{ .description_fallback = true });
    defer hollow.deinit(a);
    try std.testing.expectEqualStrings("", hollow.description);
    try std.testing.expectEqual(DescriptionSource.missing, hollow.description_source);
    try std.testing.expect(hollow.warnings.eql(.init(.{ .blank_description = true })));

    // Only the lack of any name refuses, blank or absent alike.
    try std.testing.expectError(error.MissingSkillName, parseSkillMd(a, "---\nname: \" \"\ndescription: d\n---\nbody\n", "/x"));
    try std.testing.expectError(error.MissingSkillName, parseSkillMd(a, "---\ndescription: d\n---\nbody\n", "/x"));
}

test "Codex sidecar: implicit invocation policy, fail-open on malformed YAML" {
    const hidden = (try parseCodexSidecar(std.testing.allocator, "interface:\n  display_name: \"X\"\npolicy:\n  allow_implicit_invocation: false\n")).?;
    try std.testing.expect(!hidden.allow_implicit_invocation);
    const default = (try parseCodexSidecar(std.testing.allocator, "interface:\n  short_description: s\n")).?;
    try std.testing.expect(default.allow_implicit_invocation);
    try std.testing.expect((try parseCodexSidecar(std.testing.allocator, "policy: [unterminated")) == null);
}

test "sealed binding keys are all-or-nothing and force fork" {
    const a = std.testing.allocator;
    const md =
        \\---
        \\name: erp-post
        \\description: posts
        \\sealed-gateway: "https://g.example/ssp"
        \\sealed-skill-id: ssk_1
        \\sealed-manifest-digest: "sha256:ab"
        \\---
        \\$ARGUMENTS
        \\
    ;
    const skill = try parseSkillMdWithFallback(a, md, "", "erp-post");
    defer skill.deinit(a);
    try std.testing.expect(skill.isSealed());
    try std.testing.expectEqual(ExecContext.fork, skill.context);
    try std.testing.expectEqualStrings("https://g.example/ssp", skill.sealed_gateway);

    const partial =
        \\---
        \\name: x
        \\description: d
        \\sealed-skill-id: ssk_1
        \\---
        \\body
        \\
    ;
    try std.testing.expectError(error.InvalidSealedBinding, parseSkillMdWithFallback(a, partial, "", "x"));

    const plain_md =
        \\---
        \\name: x
        \\description: d
        \\---
        \\body
        \\
    ;
    const plain = try parseSkillMdWithFallback(a, plain_md, "", "x");
    defer plain.deinit(a);
    try std.testing.expect(!plain.isSealed());
}
