const std = @import("std");
const hl = @import("hl");
const language_rules = @import("metacodes-base").highlight.hl_adapter;
const common = @import("metacodes-guard").tools.common;
const ToolContext = @import("context.zig").ToolContext;

pub fn checkFile(ctx: *const ToolContext, path: []const u8, before: []const u8, after: []const u8) !void {
    if (!ctx.preview.comment_guard or after.len == 0) return;
    const rule = language_rules.ruleForPath(path) orelse return;
    try check(ctx, path, rule, before, after);
}

pub fn checkCell(ctx: *const ToolContext, path: []const u8, language: []const u8, before: []const u8, after: []const u8) !void {
    if (!ctx.preview.comment_guard or language.len == 0 or after.len == 0) return;
    const rule = language_rules.ruleForName(language) orelse return;
    try check(ctx, path, rule, before, after);
}

fn exempt(rule: *const hl.LangRule, source: []const u8, comment: []const u8) bool {
    const offset = @intFromPtr(comment.ptr) - @intFromPtr(source.ptr);
    if (std.mem.eql(u8, rule.name, "zig")) {
        const start = if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |newline| newline + 1 else 0;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, source[start..offset], " \t"), "\\\\")) return true;
        const eintr_directive = "// no EINTR: ";
        if (std.mem.startsWith(u8, comment, eintr_directive) and std.mem.trim(u8, comment[eintr_directive.len..], " \t\r").len > 0) return true;
    }
    if (std.mem.eql(u8, rule.name, "bash") and offset > 0 and
        std.mem.indexOfScalar(u8, " \t\r\n;&|()", source[offset - 1]) == null) return true;
    if (comment.ptr == source.ptr and std.mem.startsWith(u8, comment, "#!")) return true;
    if (std.mem.eql(u8, rule.name, "bash")) return std.mem.startsWith(u8, comment, "# shellcheck ");
    if (std.mem.eql(u8, rule.name, "go")) return std.mem.startsWith(u8, comment, "//go:");
    if (std.mem.eql(u8, rule.name, "python")) {
        const directive = std.mem.trimEnd(u8, comment, " \t\r");
        return std.mem.eql(u8, directive, "# noqa") or std.mem.startsWith(u8, directive, "# noqa:") or
            std.mem.eql(u8, directive, "# type: ignore") or std.mem.startsWith(u8, directive, "# type: ignore[");
    }
    return false;
}

fn check(ctx: *const ToolContext, path: []const u8, rule: *const hl.LangRule, before: []const u8, after: []const u8) !void {
    if (rule.string_delims.len == 0 or rule.comment_line.len + rule.comment_block.len == 0 or std.mem.eql(u8, before, after)) return;
    const max_source_bytes = 512 * 1024;
    if (before.len > max_source_bytes or after.len > max_source_bytes or std.mem.indexOfScalar(u8, after, 0) != null) return;
    if (std.mem.eql(u8, rule.name, "bash") and (std.mem.indexOf(u8, before, "<<") != null or std.mem.indexOf(u8, after, "<<") != null)) return;
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var occurrences = std.StringHashMap(usize).init(arena);
    var lexical_rule = rule.*;
    lexical_rule.keywords = "";
    lexical_rule.number_prefix = &.{};
    for (try hl.tokenize(arena, before, &lexical_rule)) |span| {
        if (span.token != .comment or exempt(rule, before, span.text)) continue;
        const entry = try occurrences.getOrPut(std.mem.trimEnd(u8, span.text, " \t\r"));
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }
    for (try hl.tokenize(arena, after, &lexical_rule)) |span| {
        if (span.token != .comment or exempt(rule, after, span.text)) continue;
        if (occurrences.getPtr(std.mem.trimEnd(u8, span.text, " \t\r"))) |remaining| {
            if (remaining.* > 0) {
                remaining.* -= 1;
                continue;
            }
        }
        const offset = @intFromPtr(span.text.ptr) - @intFromPtr(after.ptr);
        const line = std.mem.count(u8, after[0..offset], "\n") + 1;
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "{s}:{d} adds a code comment. Remove the new comment and retry the edit.", .{ path, line });
        return error.AddedCodeComment;
    }
}

test "comment preview compares comment tokens and their multiplicity" {
    const ctx: ToolContext = .{ .allocator = std.testing.allocator, .preview = .all };
    try checkFile(&ctx, "tool.py", "", "#!/usr/bin/env python3\nprint('#tag')  # noqa\n");
    try checkFile(&ctx, "main.c", "/* existing */\n", "int x; /* existing */\n");
    try checkFile(&ctx, "main.c", "/* removed */\n", "int x;\n");
    try std.testing.expectError(error.AddedCodeComment, checkFile(&ctx, "main.c", "/* old */", "/* new */"));
    try std.testing.expectError(error.AddedCodeComment, checkFile(&ctx, "tool.py", "# keep\n", "# keep\n# keep\n"));
    try std.testing.expectError(error.AddedCodeComment, checkFile(&ctx, "main.c", "", "int x; /* a\nblock */"));
    try checkFile(&ctx, "readme.md", "", "# heading\n");
    try checkFile(&ctx, "example.zig", "", "const text =\n    \\\\// sample text\n;\n");
    try checkFile(&ctx, "example.zig", "", "_ = pfs.read(fd, &raw); // no EINTR: regular file, not the terminal\n");
    try std.testing.expectError(error.AddedCodeComment, checkFile(&ctx, "example.zig", "", "_ = pfs.read(fd, &raw); // read the config file\n"));
    try std.testing.expectError(error.AddedCodeComment, checkFile(&ctx, "example.zig", "", "_ = pfs.read(fd, &raw); // no EINTR: \n"));
    try checkFile(&ctx, "example.sh", "", "echo ${#word}\n");
    try checkFile(&ctx, "example.sh", "", "cat <<'TEXT'\n# heading\nTEXT\n");
    try checkFile(&ctx, "config.yaml", "", "color: '#aa0000'\n");
}
