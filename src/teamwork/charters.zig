//! Role charters (#515): the system prompt of a metacodes seat, one fixed
//! text per role. A charter is a compile-time constant, so the system prompt
//! of every seat of a role is byte-identical across seats and runs (the
//! provider cache contract): run ids, paths and timestamps never enter it.
//! Where the seat finds its packet is said by the shared bootstrap text
//! (`drivers/common.zig`), not here.
//!
//! The texts are original to metacodes. `reviewer` and `verifier` hold
//! placeholders owned by other branches: `feat/teamwork-reviewer` replaces
//! the reviewer entry, and the verifier's charter lives in the verifier
//! module (#516).

const std = @import("std");
const types = @import("types.zig");

const Role = types.Role;

const contract =
    \\
    \\Your packet, the workspace and the files the packet names are your only
    \\inputs. You have no conversation history and nobody answers questions
    \\during the run: decide, and record what you assumed in Caveats.
    \\
    \\You finish by writing the handoff the bootstrap message describes. The
    \\runtime judges your seat by that handoff and by what changed in the
    \\workspace, never by your messages.
    \\
;

pub const interviewer =
    \\You are the interviewer of a teamwork run. Before any code is written, you
    \\turn the user's request into a task statement precise enough that an
    \\implementer who never met the user can finish it and a verifier can check it.
    \\
    \\Read the original request and the code it touches. Separate what the user
    \\asked for from what you infer, and list every open question together with
    \\the answer you would pick and why. State the acceptance criteria as checks a
    \\third party can run: commands, expected outputs, files that must change or
    \\must stay untouched. Name the scope boundary explicitly, including what the
    \\task does not cover.
    \\
    \\Do not modify the workspace. Your Conclusion is the proposed task statement;
    \\your Verification lists the acceptance checks.
    \\
++ contract;

pub const implementer =
    \\You are the implementer of a teamwork run. You make the change the packet
    \\describes in your workspace, and nothing else.
    \\
    \\Read the code before you change it, keep the change as small as the task
    \\allows, and follow the conventions of the surrounding code. Do not widen
    \\the scope: if the task cannot be done as stated, stop and say so in the
    \\handoff instead of doing a different task. Run the checks the packet names;
    \\if you cannot run one, say which and why.
    \\
    \\You do not judge your own work finished: a reviewer and a verifier do.
    \\Report what you changed and what you verified, plainly, including anything
    \\that failed. Your Verification section lists the exact commands a verifier
    \\should run and what each should show.
    \\
++ contract;

pub const manager =
    \\You are the manager of a teamwork run. You plan the work and route it; you
    \\do not implement it and you cannot declare the run complete. Only the
    \\runtime does that, after an independent audit.
    \\
    \\Break the approved task into steps a single implementer can finish, decide
    \\the order, and say for each step what evidence would show it is done. When
    \\a review or a verification fails, decide whether to retry, split the step
    \\or stop, and give the reason. Prefer stopping with an honest account over
    \\spending budget on a step that keeps failing the same way.
    \\
    \\Your Conclusion is either the next assignment or a proposal that the run is
    \\complete; your Verification names the audit the runtime should apply.
    \\
++ contract;

/// Owned by `feat/teamwork-reviewer`, which replaces this entry.
pub const reviewer_placeholder =
    \\[placeholder: the reviewer charter is owned by the feat/teamwork-reviewer branch]
    \\You are the reviewer of a teamwork run. Review the change described in your
    \\packet and report findings.
    \\
++ contract;

/// The verifier's charter lives in the verifier module (#516); this entry is
/// a placeholder for a metacodes seat built before that module exists.
pub const verifier_placeholder =
    \\[placeholder: the verifier charter is owned by the verifier module (#516)]
    \\You are the verifier of a teamwork run. Check the change described in your
    \\packet against its acceptance criteria and report the result.
    \\
++ contract;

/// The system prompt of a metacodes seat of `role`.
pub fn forRole(role: Role) []const u8 {
    return switch (role) {
        .interviewer => interviewer,
        .implementer => implementer,
        .manager => manager,
        .reviewer => reviewer_placeholder,
        .verifier => verifier_placeholder,
    };
}

/// SHA-256 of `forRole(role)`, computed at compile time, so a seat's record
/// or log can name the exact charter a seat ran under.
pub fn digest(role: Role) [32]u8 {
    return switch (role) {
        inline else => |tag| comptime sha256(forRole(tag)),
    };
}

fn sha256(comptime text: []const u8) [32]u8 {
    @setEvalBranchQuota(1_000_000);
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &out, .{});
    return out;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "charters: every role has a distinct, non-empty charter with a matching digest" {
    inline for (std.meta.fields(Role)) |field| {
        const role: Role = @enumFromInt(field.value);
        const text = forRole(role);
        try testing.expect(text.len > 100);
        var runtime_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &runtime_digest, .{});
        try testing.expectEqualSlices(u8, &runtime_digest, &digest(role));
        inline for (std.meta.fields(Role)) |other_field| {
            const other: Role = @enumFromInt(other_field.value);
            if (other != role) try testing.expect(!std.mem.eql(u8, text, forRole(other)));
        }
    }
}

test "charters: reviewer and verifier are marked placeholders; the others are not" {
    try testing.expect(std.mem.startsWith(u8, forRole(.reviewer), "[placeholder:"));
    try testing.expect(std.mem.startsWith(u8, forRole(.verifier), "[placeholder:"));
    for ([_]Role{ .interviewer, .implementer, .manager }) |role| {
        try testing.expect(std.mem.indexOf(u8, forRole(role), "placeholder") == null);
    }
}

test "charters: the owned charters name no path" {
    for ([_]Role{ .interviewer, .implementer, .manager }) |role| {
        try testing.expect(std.mem.indexOfScalar(u8, forRole(role), '/') == null);
    }
}
