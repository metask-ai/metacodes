//! Side-effect boundary gate shared by the agent loop and compaction kernel.
//!
//! The checker owns policy and mutable accounting state. Callers only ask at
//! the last point before a provider request, so a completed in-budget request
//! is never retroactively turned into an abort merely because another request
//! would no longer fit.

pub const RequestBound = struct {
    /// Host-sealed conservative reserve for provider-visible input tokens of
    /// the request that is about to cross the side-effect boundary.
    max_input_tokens: u64,
    /// The output ceiling carried by that same provider request.
    max_output_tokens: u64,
};

pub const Gate = struct {
    ctx: *anyopaque,
    allows_fn: *const fn (ctx: *anyopaque) bool,
    allows_request_fn: ?*const fn (ctx: *anyopaque, bound: RequestBound) bool = null,

    pub fn allows(self: Gate) bool {
        return self.allows_fn(self.ctx);
    }

    /// Prefer a request-local conservative bound when the policy supports it.
    /// Existing gates retain their original no-argument behavior.
    pub fn allowsRequest(self: Gate, bound: RequestBound) bool {
        const callback = self.allows_request_fn orelse return self.allows();
        return callback(self.ctx, bound);
    }
};
