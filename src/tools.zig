const std = @import("std");
const json = @import("json.zig");

const read_tool = @import("tools/read.zig");
const write_tool = @import("tools/write.zig");
const edit_tool = @import("tools/edit.zig");
const glob_tool = @import("tools/glob.zig");
const bash_tool = @import("tools/bash.zig");
const grep_tool = @import("tools/grep.zig");
const bash_output_tool = @import("tools/bash_output.zig");
const kill_shell_tool = @import("tools/kill_shell.zig");
const web_fetch_tool = @import("tools/web_fetch.zig");
const ask_user_tool = @import("tools/ask_user.zig");
const plan_mode_tool = @import("tools/plan_mode.zig");
const task_tools = @import("tools/task_tools.zig");
const agent_tool = @import("tools/agent.zig");

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
    .{
        .name = "BashOutput",
        .description = "Read stdout/stderr and status of a backgrounded Bash job by job_id",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{"job_id"} },
        .execute = bash_output_tool.execute,
    },
    .{
        .name = "KillShell",
        .description = "Terminate a running backgrounded Bash job by job_id",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{"job_id"} },
        .execute = kill_shell_tool.execute,
    },
    .{
        .name = "WebFetch",
        .description = "Fetch a URL and return its text content (HTML stripped). Use for reading web pages, API docs, articles.",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{"url"} },
        .execute = web_fetch_tool.execute,
    },
    .{
        .name = "AskUserQuestion",
        .description = "Ask the user a multiple-choice question interactively. Only works in TTY. Use when you need user decision to proceed (architecture choices, ambiguous requests).",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{"questions"} },
        .execute = ask_user_tool.execute,
    },
    .{
        .name = "EnterPlanMode",
        .description = "Enter plan mode: read-only tools are allowed, write/exec are denied. Use when you want to analyze and propose before acting.",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{} },
        .execute = plan_mode_tool.executeEnter,
    },
    .{
        .name = "ExitPlanMode",
        .description = "Exit plan mode, restoring the previous permission mode. Use after the user has approved the plan.",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{} },
        .execute = plan_mode_tool.executeExit,
    },
    .{
        .name = "TaskCreate",
        .description = "Create a task in the in-session task list. Returns the new task id. Use for multi-step work you want to track across turns.",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{ "subject", "description" } },
        .execute = task_tools.executeCreate,
    },
    .{
        .name = "TaskGet",
        .description = "Fetch the full Task record (description, status, owner, blocks, blockedBy) by id.",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{"taskId"} },
        .execute = task_tools.executeGet,
    },
    .{
        .name = "TaskList",
        .description = "List all tasks with id, subject, status, owner and blockedBy (summary view).",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{} },
        .execute = task_tools.executeList,
    },
    .{
        .name = "TaskUpdate",
        .description = "Update a task's status (pending/in_progress/completed/deleted) and/or fields (subject, description, activeForm, owner) and/or addBlocks/addBlockedBy id lists.",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{"taskId"} },
        .execute = task_tools.executeUpdate,
    },
    .{
        .name = "TaskStop",
        .description = "Mark a task as completed by id. Shortcut for TaskUpdate status=completed.",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{"taskId"} },
        .execute = task_tools.executeStop,
    },
    .{
        .name = "Agent",
        .description = "Spawn a sub-agent with an isolated conversation to handle an independent sub-task. The sub-agent shares tools + permissions with the parent. Returns the sub-agent's final text and stop info. Use for focused research or tool-heavy work you don't want polluting your context.",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{"prompt"} },
        .execute = agent_tool.execute,
    },
};

pub fn getTool(name: []const u8) ?*const ToolEntry {
    for (registry) |*tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

pub fn toToolDefinitions(allocator: std.mem.Allocator) ![]json.ToolDefinition {
    var defs = try std.ArrayList(json.ToolDefinition).initCapacity(allocator, registry.len + 1);
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

    // WebSearch：Anthropic server tool，不走本地 execute；声明后 API 自己执行。
    // name 固定 "web_search"，type 是版本化的 "web_search_20250305"。
    try defs.append(allocator, .{
        .name = "web_search",
        .description = "",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{} },
        .server_type = "web_search_20250305",
    });

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
    try std.testing.expect(getTool("BashOutput") != null);
    try std.testing.expect(getTool("KillShell") != null);
    try std.testing.expect(getTool("WebFetch") != null);
    try std.testing.expect(getTool("AskUserQuestion") != null);
    try std.testing.expect(getTool("EnterPlanMode") != null);
    try std.testing.expect(getTool("ExitPlanMode") != null);
    try std.testing.expect(getTool("TaskCreate") != null);
    try std.testing.expect(getTool("TaskGet") != null);
    try std.testing.expect(getTool("TaskList") != null);
    try std.testing.expect(getTool("TaskUpdate") != null);
    try std.testing.expect(getTool("TaskStop") != null);
    try std.testing.expect(getTool("Agent") != null);
    try std.testing.expect(getTool("NonExistent") == null);
    try std.testing.expect(getTool("web_search") == null);
}

test "toToolDefinitions creates all tools + web_search server tool" {
    const defs = try toToolDefinitions(std.testing.allocator);
    defer std.testing.allocator.free(defs);
    try std.testing.expect(defs.len == registry.len + 1); // +1 = web_search
    // 最后一个是 web_search
    try std.testing.expectEqualStrings("web_search", defs[defs.len - 1].name);
    try std.testing.expect(defs[defs.len - 1].server_type != null);
}

test {
    _ = &read_tool;
    _ = &write_tool;
    _ = &edit_tool;
    _ = &glob_tool;
    _ = &bash_tool;
    _ = &grep_tool;
    _ = &bash_output_tool;
    _ = &kill_shell_tool;
    _ = &web_fetch_tool;
    _ = &ask_user_tool;
    _ = &plan_mode_tool;
    _ = &task_tools;
    _ = &agent_tool;
}
