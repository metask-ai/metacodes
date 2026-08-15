const root = @import("cli/root.zig");

pub const Command = root.Command;
pub const parseCommand = root.parseCommand;
pub const Invocation = root.Invocation;
pub const invoke = root.invoke;
pub const invokeAlloc = root.invokeAlloc;
pub const invokePersistentQueryAlloc = root.invokePersistentQueryAlloc;
pub const invokeStoreMutationAlloc = root.invokeStoreMutationAlloc;
pub const invokeAddNodeGroupAlloc = root.invokeAddNodeGroupAlloc;
pub const invokeStoreReadAlloc = root.invokeStoreReadAlloc;
pub const invokePersistentQueryCachedAlloc = root.invokePersistentQueryCachedAlloc;
pub const QueryCatalogCache = root.QueryCatalogCache;
pub const invokeCheckpointQueryAlloc = root.invokeCheckpointQueryAlloc;

/// Advanced compatibility surface. Stable embedded callers should use
/// `Invocation` plus `invoke` so environment lifetime is scoped to one call.
pub const setRuntimeEnvMap = root.setRuntimeEnvMap;

/// Advanced compatibility surface retaining the original generic Writer API.
/// It reaches the same exhaustive parser/dispatch as `invoke`.
pub const run = root.run;

test {
    _ = Invocation;
    _ = invoke;
    _ = invokeAlloc;
    _ = invokePersistentQueryAlloc;
    _ = invokeCheckpointQueryAlloc;
    _ = root.run;
}
