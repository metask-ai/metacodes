//! Side-effect boundary gate shared by the agent loop and compaction kernel.
//!
//! The checker owns policy and mutable accounting state. Callers only ask at
//! the last point before a provider request, so a completed in-budget request
//! is never retroactively turned into an abort merely because another request
//! would no longer fit.

pub const Gate = struct {
    ctx: *anyopaque,
    allows_fn: *const fn (ctx: *anyopaque) bool,

    pub fn allows(self: Gate) bool {
        return self.allows_fn(self.ctx);
    }
};
