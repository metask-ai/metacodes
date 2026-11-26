//! Per-call interactive confirmation demanded from outside the decision chain.
//!
//! A sealed Skill's gateway marks a call `confirm: true`
//! (doc/SEALED_SKILL_PROTOCOL.md §4.3, §6.2): the client MUST obtain an
//! explicit user approval for that call even in a permission mode that would
//! otherwise auto-allow it. The principal that knows which calls carry the
//! flag (the sealed provider, which owns the Step) is not part of the
//! permission chain and must not become one, so it only answers a question
//! the chain asks: *does this tool use require interactive confirmation?*
//!
//! The gate can only tighten. agent_loop consults it after the ordinary
//! decision: a `.deny` stays a deny, an `.ask` stays an ask, and an `.allow`
//! becomes an `.ask` whose prompt ignores "allow always" memory for the tool
//! (`prompt.askForced`). Nothing in the gate can turn a deny or an ask into an
//! allow, and the stream prefetch never starts a gated call.

const std = @import("std");

pub const ConfirmGate = struct {
    ctx: *anyopaque,
    requiresFn: *const fn (ctx: *anyopaque, tool_use_id: []const u8, tool_name: []const u8) bool,

    /// Whether the tool use `tool_use_id` (named `tool_name`) needs an
    /// interactive confirmation regardless of the permission decision.
    pub fn requires(self: ConfirmGate, tool_use_id: []const u8, tool_name: []const u8) bool {
        return self.requiresFn(self.ctx, tool_use_id, tool_name);
    }
};

test "a gate answers per tool use id" {
    const Probe = struct {
        fn requires(_: *anyopaque, id: []const u8, _: []const u8) bool {
            return std.mem.eql(u8, id, "call_2");
        }
    };
    var token: u8 = 0;
    const gate = ConfirmGate{ .ctx = @ptrCast(&token), .requiresFn = &Probe.requires };
    try std.testing.expect(!gate.requires("call_1", "Read"));
    try std.testing.expect(gate.requires("call_2", "Read"));
}
