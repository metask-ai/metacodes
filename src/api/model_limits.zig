const catalog_mod = @import("catalog.zig");
const model_context_mod = @import("../app/model_context.zig");

/// Input to a registry snapshot publication. The catalog is cloned into the
/// registry; ModelContext is App-lifetime immutable storage and may be borrowed.
pub const ModelLimitsSource = struct {
    catalog: ?*const catalog_mod.Catalog = null,
    model_context: ?*const model_context_mod.ModelContext = null,
    max_tokens_override: ?u32 = null,
};
