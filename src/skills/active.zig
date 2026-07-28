//! Compatibility-shaped projection of the canonical immutable PolicyFrame.
//!
//! Generic permission and pool-filter call sites still carry
//! `ActiveSkillState`; this adapter owns no rule parser or policy semantics.

const std = @import("std");
const PolicyFrame = @import("runtime/policy_frame.zig").PolicyFrame;
const model_tool = @import("runtime/model_tool.zig");

pub const ActiveSkillState = struct {
    /// Borrowed from the immutable catalog record that owns the activation.
    skill_name: []const u8,
    /// Presentation-only projection used by the existing `/status` surface.
    allowed_tools: []const []const u8,
    disallowed_tools: []const []const u8,
    /// Borrowed from the activation entry. The CLI adapter always removes this
    /// projection before releasing the corresponding frame.
    policy_frame: *PolicyFrame,
    owns_frame: bool,

    pub fn initFromPolicyFrame(
        _: std.mem.Allocator,
        skill_name: []const u8,
        frame: *PolicyFrame,
    ) !ActiveSkillState {
        try frame.retain();
        return .{
            .skill_name = skill_name,
            .allowed_tools = frame.effectiveTools(),
            .disallowed_tools = &.{},
            .policy_frame = frame,
            .owns_frame = true,
        };
    }

    pub fn borrowFromPolicyFrame(
        skill_name: []const u8,
        frame: *PolicyFrame,
    ) ActiveSkillState {
        return .{
            .skill_name = skill_name,
            .allowed_tools = frame.effectiveTools(),
            .disallowed_tools = &.{},
            .policy_frame = frame,
            .owns_frame = false,
        };
    }

    pub fn deinit(self: *ActiveSkillState) void {
        if (self.owns_frame) self.policy_frame.release();
        self.* = undefined;
    }

    /// Tool-pool visibility is derived from the same frame that guards
    /// execution. It is an optimization, not a separate permission engine.
    pub fn allowsTool(self: *const ActiveSkillState, tool_name: []const u8) bool {
        // Skill is the typed narrowing boundary itself. Keeping it visible
        // cannot widen authority because the child frame is derived from this
        // frame; AgentCore applies the same special case in its tool overlay.
        if (std.mem.eql(u8, tool_name, model_tool.TOOL_NAME))
            return self.policy_frame.allowsSkillTool();
        return self.policy_frame.executionPolicy().allowsTool(tool_name);
    }

    /// Skill metadata never grants permission; the ordinary Session decision
    /// still runs after this projection.
    pub fn isAllowed(_: *const ActiveSkillState, _: []const u8, _: []const u8) bool {
        return false;
    }

    pub fn isDisallowed(
        self: *const ActiveSkillState,
        tool_name: []const u8,
        arguments_json: []const u8,
    ) bool {
        if (std.mem.eql(u8, tool_name, model_tool.TOOL_NAME))
            return !self.policy_frame.allowsSkillInvocation(arguments_json);
        return !self.policy_frame.allowsInvocation(tool_name, arguments_json);
    }
};

test "ActiveSkillState is a non-granting PolicyFrame projection" {
    const allocator = std.testing.allocator;
    const tools = [_][]const u8{ "Read", "Bash" };
    const MatchContext = @import("../permission/rule_spec.zig").MatchContext;
    const root = try PolicyFrame.createRoot(
        allocator,
        &tools,
        .unrestricted,
        .default,
        MatchContext{
            .cwd = "/workspace",
            .project_root = "/workspace",
            .home = "/home/test",
            .alloc = allocator,
        },
    );
    defer root.release();
    const child = try PolicyFrame.derive(
        root,
        &.{"Read"},
        &.{},
    );
    defer child.release();

    var state = try ActiveSkillState.initFromPolicyFrame(
        allocator,
        "review",
        child,
    );
    defer state.deinit();

    try std.testing.expect(state.allowsTool("Read"));
    try std.testing.expect(!state.allowsTool("Bash"));
    try std.testing.expect(state.allowsTool("Skill"));
    try std.testing.expect(!state.isAllowed("Read", "{}"));
    try std.testing.expect(!state.isDisallowed("Read", "{}"));
    try std.testing.expect(state.isDisallowed("Bash", "{}"));
    try std.testing.expect(!state.isDisallowed("Skill", "{\"name\":\"next\"}"));
}
