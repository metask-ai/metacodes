const std = @import("std");
const json = @import("json.zig");

const read_tool = @import("tools/read.zig");
const write_tool = @import("tools/write.zig");
const edit_tool = @import("tools/edit.zig");
const glob_tool = @import("tools/glob.zig");
const bash_tool = @import("tools/bash.zig");
const grep_tool = @import("tools/grep.zig");

pub const ToolContext = @import("tools/context.zig").ToolContext;

pub const ToolResult = struct {
    content: []const u8,
    is_error: bool = false,
};

/// 工具执行函数签名（M2 起）：ctx 携带 allocator、abort、未来还有 permission/cwd。
pub const ExecuteFn = *const fn (ctx: *const ToolContext, args: []const u8) anyerror![]u8;

pub const ToolEntry = struct {
    name: []const u8,
    description: []const u8,
    input_schema: json.InputSchema,
    execute: ExecuteFn,
};

pub const registry: []const ToolEntry = &.{
    .{
        .name = "Read",
        .description = "Read the contents of a file from the file system",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{"path"} },
        .execute = read_tool.execute,
    },
    .{
        .name = "Write",
        .description = "Write content to a file, replacing the file if it already exists",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{ "path", "content" } },
        .execute = write_tool.execute,
    },
    .{
        .name = "Edit",
        .description = "Edit a file by replacing a specific string with new content",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{ "file_path", "old_string", "new_string" } },
        .execute = edit_tool.execute,
    },
    .{
        .name = "Glob",
        .description = "Find files matching a glob pattern",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{"pattern"} },
        .execute = glob_tool.execute,
    },
    .{
        .name = "Bash",
        .description = "Execute a bash command",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{"command"} },
        .execute = bash_tool.execute,
    },
    .{
        .name = "Grep",
        .description = "Search for patterns in files using ripgrep",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{"pattern"} },
        .execute = grep_tool.execute,
    },
};

pub fn getTool(name: []const u8) ?*const ToolEntry {
    for (registry) |*tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

pub fn toToolDefinitions(allocator: std.mem.Allocator) ![]json.ToolDefinition {
    var defs = try std.ArrayList(json.ToolDefinition).initCapacity(allocator, registry.len);
    defer defs.deinit(allocator);

    for (registry) |*tool| {
        try defs.append(allocator, .{
            .name = tool.name,
            .description = tool.description,
            .input_schema = .{
                .type = tool.input_schema.type,
                .properties = null,
                .required = tool.input_schema.required,
            },
        });
    }

    return try defs.toOwnedSlice(allocator);
}

pub fn executeTool(tool: *const ToolEntry, ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    return tool.execute(ctx, args);
}

test "getTool by name" {
    try std.testing.expect(getTool("Read") != null);
    try std.testing.expect(getTool("Write") != null);
    try std.testing.expect(getTool("Edit") != null);
    try std.testing.expect(getTool("Glob") != null);
    try std.testing.expect(getTool("Bash") != null);
    try std.testing.expect(getTool("Grep") != null);
    try std.testing.expect(getTool("NonExistent") == null);
}

test "toToolDefinitions creates all tools" {
    const defs = try toToolDefinitions(std.testing.allocator);
    defer std.testing.allocator.free(defs);
    try std.testing.expect(defs.len == registry.len);
}

test {
    _ = &read_tool;
    _ = &write_tool;
    _ = &edit_tool;
    _ = &glob_tool;
    _ = &bash_tool;
    _ = &grep_tool;
}
