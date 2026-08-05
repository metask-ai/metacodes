//! `/kg plan` read path: TinyKG snapshot -> validated typed projection ->
//! deterministic Markdown. No historical document or fuzzy text overlay is
//! consulted; the canonical task graph is the only progress source.

const std = @import("std");
const client_mod = @import("client.zig");
const projection = @import("task_projection.zig");

pub const Error = client_mod.KgError || projection.Error;

pub fn render(
    allocator: std.mem.Allocator,
    kg: *client_mod.KgClient,
    root_id: u64,
) Error![]u8 {
    const snapshot = try kg.taskSnapshot(root_id);
    defer kg.allocator.free(snapshot);
    var typed = try projection.parseSnapshot(
        allocator,
        projection.TaskId.fromInt(root_id),
        snapshot,
    );
    defer typed.deinit();
    return typed.renderMarkdown(allocator);
}
