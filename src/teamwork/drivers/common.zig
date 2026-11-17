//! What the seat drivers share: the fixed bootstrap text, where a seat's own
//! directory is, the ledger a seat charges, and how a charge turns into an
//! outcome.

const std = @import("std");
const types = @import("../types.zig");
const ledger_mod = @import("../ledger.zig");
const log = @import("../../util/log.zig");

/// The first instruction every seat receives, whatever its harness and role:
/// the metacodes driver sends it as the first user message, the Claude Code
/// driver as the `-p` prompt. A compile-time constant: no run id, path or
/// timestamp, so it is byte-identical for every seat of every run.
///
/// Files are named relative to the seat directory. The harness learns where
/// that directory is as an environment fact, the way it learns its working
/// directory: Claude Code from `--add-dir` (its own environment section),
/// the metacodes harness from the environment block that follows this text.
pub const bootstrap =
    \\You are one seat of a metacodes teamwork run.
    \\
    \\Your assignment is the file packet.md in your seat directory. Read it
    \\first, together with the files it names. The seat directory is the one
    \\extra working directory you were given; your current working directory is
    \\the workspace you work in. You can write only inside the workspace and the
    \\seat directory.
    \\
    \\When you are done, write your report to the file handoff.md in the seat
    \\directory. It must contain exactly these five level-2 sections, each once
    \\and each non-empty:
    \\
    \\## Observation
    \\## Reasoning
    \\## Caveats
    \\## Conclusion
    \\## Verification
    \\
    \\Nobody answers questions during this run, and any action that would need
    \\a permission prompt is refused. Work within what is allowed, and say in
    \\Caveats what you could not do.
    \\
;

/// The seat this driver instance runs for, and the run ledger it charges.
/// The ledger is the runtime's; the driver only appends to it, and the
/// runtime serializes seats that share it.
pub const Binding = struct {
    ledger: *ledger_mod.Ledger,
    seat: types.SeatId,
};

/// The seat's own directory: the one holding `handoff.md` (and `packet.md`).
pub fn seatDir(paths: types.SeatPaths) []const u8 {
    return std.fs.path.dirname(paths.handoff) orelse ".";
}

pub const Charged = enum {
    /// Recorded; the run still has budget.
    recorded,
    /// Recorded, and the run's total has reached its cap.
    exhausted,
    /// Not recorded (the ledger could not be written, or the amount was not
    /// a finite non-negative number). Spend the runtime cannot account for
    /// stops the run, as the ledger's own policy does.
    unrecorded,
};

pub fn charge(binding: Binding, harness: types.Harness, wallclock_ms: u64, cost: ledger_mod.Cost) Charged {
    binding.ledger.charge(.{
        .seat_id = binding.seat,
        .harness = harness,
        .wallclock_ms = wallclock_ms,
        .cost = cost,
    }) catch |err| switch (err) {
        error.BudgetExhausted => return .exhausted,
        error.InvalidAmount, error.WriteFailed => {
            log.warn("teamwork", "seat {s}: charge not recorded: {s}", .{ binding.seat.slice(), @errorName(err) });
            return .unrecorded;
        },
    };
    return .recorded;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "bootstrap: fixed text, no path or id material, names both seat files and all five sections" {
    try testing.expect(std.mem.indexOfScalar(u8, bootstrap, '/') == null);
    try testing.expect(std.mem.indexOfScalar(u8, bootstrap, '\\') == null);
    try testing.expect(std.mem.indexOf(u8, bootstrap, "packet.md") != null);
    try testing.expect(std.mem.indexOf(u8, bootstrap, "handoff.md") != null);
    inline for (std.meta.fields(types.HandoffSection)) |field| {
        const section: types.HandoffSection = @enumFromInt(field.value);
        var heading_buf: [32]u8 = undefined;
        const heading = try std.fmt.bufPrint(&heading_buf, "## {s}\n", .{section.title()});
        try testing.expect(std.mem.indexOf(u8, bootstrap, heading) != null);
    }
}

test "seat dir: the directory holding handoff.md" {
    const paths: types.SeatPaths = .{ .packet = "/s/r/seats/a-1/packet.md", .handoff = "/s/r/seats/a-1/handoff.md", .workspace = "/w" };
    try testing.expectEqualStrings("/s/r/seats/a-1", seatDir(paths));
}
