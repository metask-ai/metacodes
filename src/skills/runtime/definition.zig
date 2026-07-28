const std = @import("std");

/// Skill execution mode. UI adapters may choose how to present it, but the
/// semantic value is owned by the shared Skill Runtime.
pub const ExecContext = enum { inline_ctx, fork };

/// Canonical parsed SKILL.md definition shared by every product adapter.
pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    body: []const u8,
    allowed_tools: []const []const u8,
    disallowed_tools: []const []const u8,
    arguments: []const []const u8,
    disable_model_invocation: bool,
    context: ExecContext,
    agent: []const u8,
    model: []const u8,
    shell: []const u8,
    source_path: []const u8,

    pub fn deinit(self: Skill, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
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
    }
};

/// Parse SKILL.md, using the directory name when frontmatter omits `name`.
pub fn parseSkillMdWithFallback(
    allocator: std.mem.Allocator,
    md: []const u8,
    source_path: []const u8,
    dir_name: []const u8,
) !Skill {
    var name: []const u8 = "";
    var description: []const u8 = "";
    var allowed_raw: []const u8 = "";
    var disallowed_raw: []const u8 = "";
    var arguments_raw: []const u8 = "";
    var disable_invoke = false;
    var context_str: []const u8 = "inline";
    var agent_str: []const u8 = "";
    var model_str: []const u8 = "";
    var shell_str: []const u8 = "bash";
    var body: []const u8 = md;

    if (std.mem.startsWith(u8, md, "---\n")) {
        const fm_start = 4;
        if (std.mem.indexOfPos(u8, md, fm_start, "\n---\n")) |fm_end| {
            const fm = md[fm_start..fm_end];
            body = md[fm_end + 5 ..];
            var line_it = std.mem.splitScalar(u8, fm, '\n');
            while (line_it.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0 or trimmed[0] == '#') continue;
                const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
                const key = std.mem.trim(u8, trimmed[0..colon], " \t");
                const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                if (std.mem.eql(u8, key, "name")) {
                    name = value;
                } else if (std.mem.eql(u8, key, "description")) {
                    description = value;
                } else if (std.mem.eql(u8, key, "allowed-tools") or std.mem.eql(u8, key, "allowed_tools")) {
                    allowed_raw = value;
                } else if (std.mem.eql(u8, key, "disallowed-tools") or std.mem.eql(u8, key, "disallowed_tools")) {
                    disallowed_raw = value;
                } else if (std.mem.eql(u8, key, "arguments")) {
                    arguments_raw = value;
                } else if (std.mem.eql(u8, key, "disable-model-invocation") or std.mem.eql(u8, key, "disable_model_invocation")) {
                    disable_invoke = parseBool(value);
                } else if (std.mem.eql(u8, key, "context")) {
                    context_str = value;
                } else if (std.mem.eql(u8, key, "agent")) {
                    agent_str = value;
                } else if (std.mem.eql(u8, key, "model")) {
                    model_str = value;
                } else if (std.mem.eql(u8, key, "shell")) {
                    shell_str = value;
                }
            }
        }
    }

    if (name.len == 0) name = dir_name;
    if (name.len == 0) return error.MissingSkillName;

    const allowed_tools = try parseStringList(allocator, allowed_raw);
    errdefer freeStringList(allocator, allowed_tools);
    const disallowed_tools = try parseStringList(allocator, disallowed_raw);
    errdefer freeStringList(allocator, disallowed_tools);
    const arguments = try parseStringList(allocator, arguments_raw);
    errdefer freeStringList(allocator, arguments);

    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_description = try allocator.dupe(u8, description);
    errdefer allocator.free(owned_description);
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

    return .{
        .name = owned_name,
        .description = owned_description,
        .body = owned_body,
        .allowed_tools = allowed_tools,
        .disallowed_tools = disallowed_tools,
        .arguments = arguments,
        .disable_model_invocation = disable_invoke,
        .context = if (std.mem.eql(u8, context_str, "fork")) .fork else .inline_ctx,
        .agent = owned_agent,
        .model = owned_model,
        .shell = owned_shell,
        .source_path = owned_source_path,
    };
}

pub fn parseSkillMd(
    allocator: std.mem.Allocator,
    md: []const u8,
    source_path: []const u8,
) !Skill {
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

fn parseBool(value: []const u8) bool {
    return std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "yes") or
        std.mem.eql(u8, value, "1");
}

test "parseSkillMdWithFallback releases every partial allocation" {
    const md =
        "---\n" ++
        "description: allocation fault fixture\n" ++
        "allowed-tools: Read, Bash(git *), Grep\n" ++
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
    while (fail_index < 64) : (fail_index += 1) {
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
        "context: fork\n" ++
        "agent: Explore\n" ++
        "model: claude-haiku-4-5-20251001\n" ++
        "shell: bash\n" ++
        "---\n" ++
        "body";
    const skill = try parseSkillMd(std.testing.allocator, md, "/x");
    defer skill.deinit(std.testing.allocator);
    try std.testing.expect(skill.disable_model_invocation);
    try std.testing.expectEqual(ExecContext.fork, skill.context);
    try std.testing.expectEqualStrings("Explore", skill.agent);
    try std.testing.expectEqualStrings("claude-haiku-4-5-20251001", skill.model);
    try std.testing.expectEqualStrings("bash", skill.shell);
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
