//! Shared immutable execution-context policy lineage for typed Skill activations.
//!
//! Frames are refcounted because fork siblings may outlive their caller's
//! stack. A child can only add intersections and denials; it never mutates or
//! re-authorizes its parent.

const std = @import("std");
const rule_spec = @import("../../permission/rule_spec.zig");
const workspace = @import("../../core/workspace_policy.zig");
const types = @import("../../types.zig");
const tool_types = @import("../../tools.zig");

pub const Error = error{
    OutOfMemory,
    ResourceLimit,
    InvalidPolicy,
};

pub const PolicyFrame = struct {
    owner_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    references: std.atomic.Value(usize) = .init(1),
    parent_frame: ?*PolicyFrame,
    effective_tools: []const []const u8,
    local_allowed: []const []const u8,
    local_disallowed: []const []const u8,
    local_allowed_rules: []const rule_spec.RuleSpec,
    local_disallowed_rules: []const rule_spec.RuleSpec,
    shell: workspace.ShellPolicy,
    permission: types.PermissionMode,
    match_context: rule_spec.MatchContext,

    pub fn createRoot(
        owner_allocator: std.mem.Allocator,
        session_tools: []const []const u8,
        shell: workspace.ShellPolicy,
        permission: types.PermissionMode,
        match_context: rule_spec.MatchContext,
    ) Error!*PolicyFrame {
        if (hasDuplicate(session_tools)) return error.InvalidPolicy;
        const self = owner_allocator.create(PolicyFrame) catch
            return error.OutOfMemory;
        self.* = .{
            .owner_allocator = owner_allocator,
            .arena = std.heap.ArenaAllocator.init(owner_allocator),
            .parent_frame = null,
            .effective_tools = &.{},
            .local_allowed = &.{},
            .local_disallowed = &.{},
            .local_allowed_rules = &.{},
            .local_disallowed_rules = &.{},
            .shell = shell,
            .permission = permission,
            .match_context = undefined,
        };
        errdefer {
            self.arena.deinit();
            owner_allocator.destroy(self);
        }
        const arena = self.arena.allocator();
        self.effective_tools = try cloneStrings(arena, session_tools);
        self.match_context = try cloneMatchContext(arena, owner_allocator, match_context);
        return self;
    }

    pub fn derive(
        base_frame: *PolicyFrame,
        allowed: []const []const u8,
        disallowed: []const []const u8,
    ) Error!*PolicyFrame {
        if (!validRules(allowed) or !validRules(disallowed))
            return error.InvalidPolicy;
        const owner_allocator = base_frame.owner_allocator;
        const self = owner_allocator.create(PolicyFrame) catch
            return error.OutOfMemory;
        self.* = .{
            .owner_allocator = owner_allocator,
            .arena = std.heap.ArenaAllocator.init(owner_allocator),
            .parent_frame = base_frame,
            .effective_tools = &.{},
            .local_allowed = &.{},
            .local_disallowed = &.{},
            .local_allowed_rules = &.{},
            .local_disallowed_rules = &.{},
            .shell = base_frame.shell,
            .permission = base_frame.permission,
            // The child retains base_frame before returning, so these borrowed
            // slices remain alive for the whole child lifetime. Copying the
            // context into every sibling would add allocations without adding
            // ownership safety.
            .match_context = base_frame.match_context,
        };
        errdefer {
            self.arena.deinit();
            owner_allocator.destroy(self);
        }
        const arena = self.arena.allocator();
        self.local_allowed = try cloneStrings(arena, allowed);
        self.local_disallowed = try cloneStrings(arena, disallowed);
        self.local_allowed_rules = try parseRules(arena, self.local_allowed);
        self.local_disallowed_rules = try parseRules(arena, self.local_disallowed);

        var effective: std.ArrayList([]const u8) = .empty;
        for (base_frame.effective_tools) |tool_name| {
            if (allowed.len != 0 and
                !anyRuleTargetsTool(
                    self.local_allowed_rules,
                    &base_frame.match_context,
                    tool_name,
                ))
                continue;
            if (anyRuleFullyDeniesTool(
                self.local_disallowed_rules,
                &base_frame.match_context,
                tool_name,
            ))
                continue;
            effective.append(arena, tool_name) catch return error.OutOfMemory;
        }
        self.effective_tools = effective.toOwnedSlice(arena) catch
            return error.OutOfMemory;
        try base_frame.retain();
        return self;
    }

    pub fn retain(self: *PolicyFrame) Error!void {
        var current = self.references.load(.monotonic);
        while (true) {
            if (current == std.math.maxInt(usize)) return error.ResourceLimit;
            if (self.references.cmpxchgWeak(
                current,
                current + 1,
                .monotonic,
                .monotonic,
            )) |observed| {
                current = observed;
            } else {
                return;
            }
        }
    }

    pub fn release(self: *PolicyFrame) void {
        const previous = self.references.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
        if (previous != 1) return;
        const retained_parent = self.parent_frame;
        const owner_allocator = self.owner_allocator;
        self.arena.deinit();
        owner_allocator.destroy(self);
        if (retained_parent) |value| value.release();
    }

    pub fn parent(self: *const PolicyFrame) ?*const PolicyFrame {
        return self.parent_frame;
    }

    pub fn effectiveTools(self: *const PolicyFrame) []const []const u8 {
        return self.effective_tools;
    }

    pub fn shellPolicy(self: *const PolicyFrame) workspace.ShellPolicy {
        return self.shell;
    }

    pub fn permissionMode(self: *const PolicyFrame) types.PermissionMode {
        return self.permission;
    }

    pub fn executionPolicy(self: *const PolicyFrame) tool_types.ToolExecutionPolicy {
        return .{
            .ctx = @ptrCast(self),
            .allowsToolFn = allowsToolAdapter,
            .allowsInvocationFn = allowsInvocationAdapter,
        };
    }

    /// This is an upper-bound check only. A true result still goes through the
    /// Session's ordinary permission decision; Skill metadata never grants.
    pub fn allowsInvocation(
        self: *const PolicyFrame,
        tool_name: []const u8,
        arguments_json: []const u8,
    ) bool {
        if (!containsTool(self.effective_tools, tool_name)) return false;
        var cursor: ?*const PolicyFrame = self;
        while (cursor) |frame| : (cursor = frame.parent_frame) {
            if (frame.local_allowed_rules.len != 0 and
                !anyRuleMatches(
                    frame.local_allowed_rules,
                    &frame.match_context,
                    tool_name,
                    arguments_json,
                    .allow,
                ))
                return false;
            if (anyRuleMatches(
                frame.local_disallowed_rules,
                &frame.match_context,
                tool_name,
                arguments_json,
                .deny,
            ))
                return false;
        }
        return true;
    }

    /// The internal Skill tool is an activation boundary, not a Session tool,
    /// so ordinary allowed-tool intersections do not implicitly hide it.
    /// Explicit `Skill(...)` rules still constrain nested composition.
    pub fn allowsSkillTool(self: *const PolicyFrame) bool {
        var cursor: ?*const PolicyFrame = self;
        while (cursor) |frame| : (cursor = frame.parent_frame) {
            if (anyRuleFullyDeniesTool(
                frame.local_disallowed_rules,
                &frame.match_context,
                "Skill",
            )) return false;
        }
        return true;
    }

    pub fn allowsSkillInvocation(
        self: *const PolicyFrame,
        arguments_json: []const u8,
    ) bool {
        var cursor: ?*const PolicyFrame = self;
        while (cursor) |frame| : (cursor = frame.parent_frame) {
            var constrained = false;
            var matched = false;
            for (frame.local_allowed_rules) |*rule| {
                if (!ruleTargetsTool(rule, &frame.match_context, "Skill"))
                    continue;
                constrained = true;
                if (rule_spec.matchesMode(
                    rule,
                    &frame.match_context,
                    "Skill",
                    arguments_json,
                    .allow,
                )) matched = true;
            }
            if (constrained and !matched) return false;
            if (anyRuleMatches(
                frame.local_disallowed_rules,
                &frame.match_context,
                "Skill",
                arguments_json,
                .deny,
            )) return false;
        }
        return true;
    }

    fn referenceCountForTesting(self: *const PolicyFrame) usize {
        if (comptime !@import("builtin").is_test)
            @compileError("PolicyFrame reference count is test-only");
        return self.references.load(.acquire);
    }

    fn allowsToolAdapter(raw: *const anyopaque, name: []const u8) bool {
        const self: *const PolicyFrame = @ptrCast(@alignCast(raw));
        return containsTool(self.effective_tools, name);
    }

    fn allowsInvocationAdapter(
        raw: *const anyopaque,
        name: []const u8,
        arguments_json: []const u8,
    ) bool {
        const self: *const PolicyFrame = @ptrCast(@alignCast(raw));
        return self.allowsInvocation(name, arguments_json);
    }
};

pub fn validateRules(
    allowed: []const []const u8,
    disallowed: []const []const u8,
) Error!void {
    if (!validRules(allowed) or !validRules(disallowed))
        return error.InvalidPolicy;
}

fn cloneMatchContext(
    arena: std.mem.Allocator,
    owner_allocator: std.mem.Allocator,
    source: rule_spec.MatchContext,
) error{OutOfMemory}!rule_spec.MatchContext {
    return .{
        .cwd = try arena.dupe(u8, source.cwd),
        .project_root = try arena.dupe(u8, source.project_root),
        .home = try arena.dupe(u8, source.home),
        .additional_dirs = try cloneStrings(arena, source.additional_dirs),
        .alloc = owner_allocator,
    };
}

fn cloneStrings(
    arena: std.mem.Allocator,
    source: []const []const u8,
) error{OutOfMemory}![]const []const u8 {
    const result = try arena.alloc([]const u8, source.len);
    for (source, result) |value, *copy| copy.* = try arena.dupe(u8, value);
    return result;
}

fn validRules(rules: []const []const u8) bool {
    for (rules) |raw| {
        const parsed = rule_spec.parseRule(raw) catch return false;
        if (parsed.tool.len == 0) return false;
    }
    return true;
}

fn parseRules(
    arena: std.mem.Allocator,
    rules: []const []const u8,
) Error![]const rule_spec.RuleSpec {
    const parsed = arena.alloc(rule_spec.RuleSpec, rules.len) catch
        return error.OutOfMemory;
    for (rules, parsed) |raw, *rule| {
        rule.* = rule_spec.parseRule(raw) catch return error.InvalidPolicy;
        if (rule.tool.len == 0) return error.InvalidPolicy;
    }
    return parsed;
}

fn hasDuplicate(values: []const []const u8) bool {
    for (values, 0..) |value, index| {
        if (value.len == 0) return true;
        for (values[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier, value)) return true;
        }
    }
    return false;
}

fn anyRuleTargetsTool(
    rules: []const rule_spec.RuleSpec,
    context: *const rule_spec.MatchContext,
    tool_name: []const u8,
) bool {
    for (rules) |*parsed| {
        if (ruleTargetsTool(parsed, context, tool_name)) return true;
    }
    return false;
}

fn anyRuleFullyDeniesTool(
    rules: []const rule_spec.RuleSpec,
    context: *const rule_spec.MatchContext,
    tool_name: []const u8,
) bool {
    for (rules) |*parsed| {
        if (!ruleTargetsTool(parsed, context, tool_name)) continue;
        switch (parsed.spec) {
            .all, .mcp_match => return true,
            else => {},
        }
    }
    return false;
}

fn ruleTargetsTool(
    parsed: *const rule_spec.RuleSpec,
    context: *const rule_spec.MatchContext,
    tool_name: []const u8,
) bool {
    if (std.mem.eql(u8, parsed.tool, "mcp"))
        return rule_spec.matches(parsed, context, tool_name, "{}");
    if (std.mem.eql(u8, parsed.tool, "Agent"))
        return std.mem.eql(u8, tool_name, "Task") or
            std.mem.eql(u8, tool_name, "Agent");
    return std.mem.eql(u8, parsed.tool, tool_name);
}

fn anyRuleMatches(
    rules: []const rule_spec.RuleSpec,
    context: *const rule_spec.MatchContext,
    tool_name: []const u8,
    arguments_json: []const u8,
    mode: rule_spec.RuleMode,
) bool {
    for (rules) |*parsed| {
        if (rule_spec.matchesMode(
            parsed,
            context,
            tool_name,
            arguments_json,
            mode,
        )) return true;
    }
    return false;
}

fn containsTool(tools: []const []const u8, name: []const u8) bool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool, name)) return true;
    }
    return false;
}

test "parent narrowing cannot be recovered by a broad child" {
    const root = try PolicyFrame.createRoot(
        std.testing.allocator,
        &.{ "Read", "Write", "Bash" },
        .sandboxed,
        .default,
        .{ .cwd = "/work", .project_root = "/work", .home = "/home/test" },
    );
    defer root.release();
    const parent = try PolicyFrame.derive(root, &.{ "Read", "Bash(git *)" }, &.{});
    defer parent.release();
    const child = try PolicyFrame.derive(parent, &.{ "Read", "Write", "Bash" }, &.{});
    defer child.release();

    try std.testing.expect(child.parent() == parent);
    try std.testing.expectEqual(workspace.ShellPolicy.sandboxed, child.shellPolicy());
    try std.testing.expectEqual(types.PermissionMode.default, child.permissionMode());
    try std.testing.expect(child.allowsInvocation("Read", "{\"file_path\":\"/work/a\"}"));
    try std.testing.expect(!child.allowsInvocation("Write", "{\"file_path\":\"/work/a\"}"));
    try std.testing.expect(child.allowsInvocation("Bash", "{\"command\":\"git status\"}"));
    try std.testing.expect(!child.allowsInvocation("Bash", "{\"command\":\"rm -rf /\"}"));
    const execution_policy = child.executionPolicy();
    try std.testing.expect(execution_policy.allowsTool("Read"));
    try std.testing.expect(!execution_policy.allowsTool("Write"));
    try std.testing.expect(execution_policy.allowsInvocation(
        "Bash",
        "{\"command\":\"git status\"}",
    ));
    try std.testing.expect(!execution_policy.allowsInvocation(
        "Bash",
        "{\"command\":\"rm -rf /\"}",
    ));
}

test "nested Skill remains composable but explicit Skill rules are enforced" {
    const root = try PolicyFrame.createRoot(
        std.testing.allocator,
        &.{ "Read", "Write" },
        .sandboxed,
        .default,
        .{ .cwd = "/work", .project_root = "/work", .home = "/home/test" },
    );
    defer root.release();
    const ordinary_narrow = try PolicyFrame.derive(root, &.{"Read"}, &.{});
    defer ordinary_narrow.release();
    try std.testing.expect(ordinary_narrow.allowsSkillTool());
    try std.testing.expect(ordinary_narrow.allowsSkillInvocation(
        "{\"name\":\"review\"}",
    ));

    const named = try PolicyFrame.derive(
        ordinary_narrow,
        &.{ "Read", "Skill(review)" },
        &.{},
    );
    defer named.release();
    try std.testing.expect(named.allowsSkillInvocation(
        "{\"name\":\"review\"}",
    ));
    try std.testing.expect(!named.allowsSkillInvocation(
        "{\"name\":\"deploy\"}",
    ));

    const denied = try PolicyFrame.derive(
        ordinary_narrow,
        &.{},
        &.{"Skill"},
    );
    defer denied.release();
    try std.testing.expect(!denied.allowsSkillTool());
    try std.testing.expect(!denied.allowsSkillInvocation(
        "{\"name\":\"review\"}",
    ));
}

test "three-level intersections and denials leave every ancestor immutable" {
    const root = try PolicyFrame.createRoot(
        std.testing.allocator,
        &.{ "Read", "Write", "Bash" },
        .unrestricted,
        .accept_edits,
        .{ .cwd = "/work", .project_root = "/work", .home = "/home/test" },
    );
    defer root.release();
    const first = try PolicyFrame.derive(root, &.{ "Read", "Bash(git *)" }, &.{});
    defer first.release();
    const second = try PolicyFrame.derive(first, &.{ "Read", "Bash" }, &.{"Bash(git push *)"});
    defer second.release();
    const third = try PolicyFrame.derive(second, &.{ "Read", "Bash" }, &.{"Read"});
    defer third.release();

    try std.testing.expect(first.allowsInvocation("Read", "{}"));
    try std.testing.expect(first.allowsInvocation("Bash", "{\"command\":\"git push origin main\"}"));
    try std.testing.expect(second.allowsInvocation("Bash", "{\"command\":\"git status\"}"));
    try std.testing.expect(!second.allowsInvocation("Bash", "{\"command\":\"git push origin main\"}"));
    try std.testing.expect(!third.allowsInvocation("Read", "{}"));
    try std.testing.expect(third.allowsInvocation("Bash", "{\"command\":\"git status\"}"));
    try std.testing.expectEqual(@as(usize, 1), third.effectiveTools().len);
    try std.testing.expectEqualStrings("Bash", third.effectiveTools()[0]);
}

test "concurrent siblings share an immutable retained parent without interference" {
    const root = try PolicyFrame.createRoot(
        std.testing.allocator,
        &.{ "Read", "Bash" },
        .disabled,
        .plan,
        .{},
    );
    const read_child = try PolicyFrame.derive(root, &.{"Read"}, &.{});
    const bash_child = try PolicyFrame.derive(root, &.{"Bash"}, &.{});
    try std.testing.expectEqual(@as(usize, 3), root.referenceCountForTesting());

    const Worker = struct {
        fn run(frame: *PolicyFrame, expected: []const u8) void {
            for (0..1000) |_| {
                std.debug.assert(frame.allowsInvocation(expected, "{}"));
            }
            frame.release();
        }
    };
    const read_thread = try std.Thread.spawn(.{}, Worker.run, .{ read_child, "Read" });
    const bash_thread = try std.Thread.spawn(.{}, Worker.run, .{ bash_child, "Bash" });
    root.release();
    read_thread.join();
    bash_thread.join();
}

test "invalid rules and duplicate baseline tools fail before publishing a frame" {
    try std.testing.expectError(error.InvalidPolicy, PolicyFrame.createRoot(
        std.testing.allocator,
        &.{ "Read", "Read" },
        .disabled,
        .default,
        .{},
    ));
    const root = try PolicyFrame.createRoot(
        std.testing.allocator,
        &.{"Read"},
        .disabled,
        .default,
        .{},
    );
    defer root.release();
    try std.testing.expectError(
        error.InvalidPolicy,
        PolicyFrame.derive(root, &.{"Bash(unclosed"}, &.{}),
    );
}
