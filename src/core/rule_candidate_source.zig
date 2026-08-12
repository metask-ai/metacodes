//! Reopen the complete source chain behind one immutable rule candidate.
//!
//! `rule_candidate` deliberately cannot import `rule_author`: doing so would
//! make the generic proposal format depend on one producer and would create a
//! module cycle.  Authorizing consumers use this neutral adapter instead.  A
//! provider-authored candidate is bound only when its author receipt reopens,
//! every response-derived field still matches, and (for protocol v2) the
//! receipt can reopen the exact ontology projection and its evidence.

const std = @import("std");
const rule_candidate = @import("rule_candidate.zig");
const rule_author = @import("rule_author.zig");

pub fn verify(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    candidate: *const rule_candidate.Loaded,
) !bool {
    return switch (candidate.source_kind) {
        .rule_author => blk: {
            const receipt_id = candidate.source_receipt_id orelse break :blk false;
            break :blk try rule_author.verifyCandidateBinding(
                allocator,
                session_dir,
                receipt_id,
                candidate.candidate_id,
            );
        },
        else => try candidate.sourceIsBound(allocator, session_dir),
    };
}
