const std = @import("std");
const model_name = @import("metacodes-base").api.model_name;

test "model routing source guard rejects direct case-sensitive model matching" {
    const paths = [_][]const u8{
        "packages/ai/src/api/model_adapter.zig",
        "packages/ai/src/api/capability.zig",
        "packages/ai/src/api/dialect.zig",
        "packages/ai/src/api/dialects/openai.zig",
        "packages/ai/src/api/dialects/claude.zig",
        "packages/ai/src/api/catalog.zig",
        "packages/ai/src/api/dialects/glm.zig",
        "packages/ai/src/api/dialects/kimi.zig",
        "packages/ai/src/api/dialects/deepseek.zig",
        "packages/ai/src/api/dialects/qwen.zig",
        "packages/ai/src/api/dialects/minimax.zig",
        "packages/ai/src/api/dialects/mistral.zig",
        "packages/ai/src/api/dialects/openrouter.zig",
        "packages/ai/src/api/dialects/gemini.zig",
        "packages/ai/src/api/dialects/registry.zig",
        "packages/ai/src/api/dialects/openai_compat.zig",
        "packages/ai/src/api/model_context.zig",
        "packages/base/src/util/pricing.zig",
        "packages/base/src/util/model.zig",
        "packages/coding/src/core/system_prompt.zig",
        "packages/coding/src/plugin/runtime.zig",
    };
    for (paths) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(16 * 1024 * 1024));
        defer std.testing.allocator.free(source);
        for (model_name.case_sensitive_model_matches) |needle| {
            if (std.mem.indexOf(u8, source, needle) != null) {
                std.debug.print("{s}: case-sensitive model comparison {s}\n", .{ path, needle });
                return error.CaseSensitiveModelComparison;
            }
        }
    }
}
