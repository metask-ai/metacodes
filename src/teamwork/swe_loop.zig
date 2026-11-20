//! The built-in software-engineering loop: the default metacodes manager
//! (#514). A deterministic policy, no model: it drives a `runtime.Run`
//! through the same operations any manager uses (`dispatch`,
//! `requestCompletion`), so a Claude Code manager over MCP (#522) gets the
//! same guarantees by construction.
//!
//! ```
//! implementer ─► reviewer ─┬─ changes requested / review invalid ─► implementer (open issues carried)
//!                          └─ approved ─► requestCompletion
//!                                          ├─ approval stale ─► reviewer
//!                                          ├─ 1st audit fail ─► implementer (audit report forwarded)
//!                                          └─ pass ─► merge-back ─► done
//! ```
//!
//! A seat that fails (crash, no handoff) is run again in a new seat. The loop
//! always terminates: every iteration dispatches a seat, which the runtime
//! caps at `max_rounds` per role, or audits, which it caps at two; budget,
//! cancellation and failures are terminal states the loop only observes.

const std = @import("std");
const runtime = @import("runtime.zig");

pub const Error = runtime.Error;

/// Drive `run` until it ends; returns its final state.
pub fn drive(run: *runtime.Run) Error!runtime.State {
    while (true) {
        switch (run.state) {
            .done, .failed, .budget_exhausted, .cancelled => return run.state,
            .approved, .implementing => _ = run.dispatch(.implementer, "") catch |err| switch (err) {
                // The run is in a terminal state now; the next turn returns it.
                error.RunEnded, error.RoundsExhausted, error.BudgetExhausted => continue,
                else => |e| return e,
            },
            .reviewing => _ = run.dispatch(.reviewer, "") catch |err| switch (err) {
                error.RunEnded, error.RoundsExhausted, error.BudgetExhausted => continue,
                else => |e| return e,
            },
            .review_approved => _ = run.requestCompletion() catch |err| switch (err) {
                error.RunEnded, error.BudgetExhausted => continue,
                else => |e| return e,
            },
            // Only inside `requestCompletion`; `Run.reopen` resolves both.
            .auditing, .merging => return error.IllegalTransition,
        }
    }
}
