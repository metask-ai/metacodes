//! Every model-name consumer answers the same for either case.
//!
//! Kept apart from `model_name.zig` on purpose. That file is a leaf the
//! provider kernel reaches through `util/pricing.zig` and `util/model.zig`, so
//! each test in it compiles into the `test:provider` and `test:picker`
//! isolation roots. This one imports the system prompt, and through it the
//! tool set and the formal runtime; written there, it made both roots compile
//! the whole application, and stop compiling once the formal runtime needed a
//! build option. `zig build subsystem:boundary` rejects that reach.

const std = @import("std");
const model_name = @import("model_name.zig");

test "case-insensitive model routing, capability, pricing, catalog, and context" {
    const dialects = @import("dialect.zig");
    const adapter = @import("model_adapter.zig");
    const capability = @import("capability.zig");
    const pricing = @import("../util/pricing.zig");
    const Catalog = @import("catalog.zig").Catalog;
    const ModelContext = @import("model_context.zig").ModelContext;
    const prompt = @import("../core/system_prompt.zig");

    const a = std.testing.allocator;
    var upper_buf: std.ArrayList(u8) = .empty;
    defer upper_buf.deinit(a);
    var lower_buf: std.ArrayList(u8) = .empty;
    defer lower_buf.deinit(a);
    try dialects.dialectFor(.anthropic, "GLM-5.2").serializeThinking(.{}, .high, &upper_buf, a);
    try dialects.dialectFor(.anthropic, "glm-5.2").serializeThinking(.{}, .high, &lower_buf, a);
    try std.testing.expectEqualStrings(lower_buf.items, upper_buf.items);
    upper_buf.clearRetainingCapacity();
    try dialects.dialectFor(.openai, "GLM-5.2").serializeThinking(.{}, .high, &upper_buf, a);
    lower_buf.clearRetainingCapacity();
    try dialects.dialectFor(.openai, "glm-5.2").serializeThinking(.{}, .high, &lower_buf, a);
    try std.testing.expectEqualStrings(lower_buf.items, upper_buf.items);
    try std.testing.expectEqual(adapter.profileFor(.openai, "GLM-5.2"), adapter.profileFor(.openai, "glm-5.2"));
    try std.testing.expectEqual(capability.supports(.anthropic, "GLM-5.2", .structured_output), capability.supports(.anthropic, "glm-5.2", .structured_output));
    try std.testing.expectEqual(pricing.rateFor("GLM-5.2"), pricing.rateFor("glm-5.2"));
    try std.testing.expect(!model_name.containsIgnoreCase("glm-4", "glm-5"));
    try std.testing.expect(!model_name.containsIgnoreCase("claude-3-5-haiku", "claude-haiku-4"));

    var catalog = Catalog.init(a);
    defer catalog.deinit();
    try catalog.loadFromModelsListJson("{\"data\":[{\"id\":\"GLM-5.2\",\"max_tokens\":64000,\"max_input_tokens\":1048576}]} ");
    try std.testing.expectEqual(@as(u32, 64000), catalog.maxTokensFor("glm-5.2", null));
    var context = ModelContext.init(a);
    defer context.deinit();
    context.parse("[models]\n\"glm-5.2\" = 262144\n");
    try std.testing.expectEqual(@as(u32, 262144), context.windowFor("GLM-5.2"));
    try std.testing.expect(prompt.getKnowledgeCutoff("claude-3-5-haiku") == null);
}
