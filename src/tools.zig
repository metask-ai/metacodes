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
const monitor_tool = @import("tools/monitor.zig");
const notebook_edit_tool = @import("tools/notebook_edit.zig");
const worktree_tool = @import("tools/worktree.zig");
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
        .name = "Monitor",
        .description = "Start a background monitor that runs a command and streams stdout line-by-line. Use to watch logs, poll status, or react to file changes mid-conversation. Each stdout line is collected into a ring buffer readable via BashOutput(job_id). Stop with KillShell(job_id). Args: command (required), description (required, e.g. 'errors in /var/log/app.log'). Optional: persistent (default false; if true, no timeout).",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{ "command", "description" } },
        .execute = monitor_tool.execute,
    },
    .{
        .name = "NotebookEdit",
        .description = "Modify a Jupyter notebook (.ipynb) cell. Modes: replace (default) overwrites the cell's source; insert adds a new cell after target (or at start if no cell_id); delete removes the target cell. Args: notebook_path (required), new_source (required, may be empty for delete), cell_id (required for replace/delete; optional for insert), cell_type ('code' or 'markdown', required for insert), edit_mode.",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{ "notebook_path", "new_source" } },
        .execute = notebook_edit_tool.execute,
    },
    .{
        .name = "EnterWorktree",
        .description = "Enter an isolated git worktree. Pass `path` to switch into an existing worktree, OR pass `name` (and optional `base` branch) to create a new worktree under .cc-zig/worktrees/<name>/. Changes the session's working directory. Returns {worktree, branch, entered, created}.",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{} },
        .execute = worktree_tool.enterExecute,
    },
    .{
        .name = "ExitWorktree",
        .description = "Exit the current worktree and return to the original directory. Args: action='keep' (leaves worktree and branch intact) or 'remove' (also deletes the worktree). Optional discard_changes=true to force-remove even with uncommitted changes.",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{"action"} },
        .execute = worktree_tool.exitExecute,
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
        .name = "Task",
        .description = "Launch a subagent in an isolated context to handle a side task. Each subagent starts with a fresh context — it cannot see this conversation, only the prompt you pass. Use for: high-volume operations (running tests, processing logs), parallel research, isolating exploration that would flood your context. Args: subagent_type (Explore/Plan/general-purpose/<custom>), description (3-5 word UI label), prompt (the delegation message). Optional: max_turns, model.",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{ "subagent_type", "description", "prompt" } },
        .execute = agent_tool.execute,
    },
    .{
        .name = "Agent",
        .description = "Deprecated alias for Task. Use Task with subagent_type instead. Currently routes to Task with subagent_type=\"general-purpose\".",
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
    return toToolDefinitionsWithDyn(allocator, null);
}

/// 合并静态 + 动态工具 + web_search server tool。`dyn` 为 null 时等价 toToolDefinitions。
/// 顺序：静态 18 → 动态（Skill/MCP）→ web_search。
pub fn toToolDefinitionsWithDyn(
    allocator: std.mem.Allocator,
    dyn: ?*const @import("tools/dynamic.zig").DynRegistry,
) ![]json.ToolDefinition {
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

    if (dyn) |d| try d.appendDefinitions(&defs, allocator);

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

/// 统一派发：先查静态注册表，未命中查 ctx.dyn_registry。
/// 找不到返 error.UnknownTool —— 由 agent_loop 转 tool_error 给模型。
pub fn dispatch(ctx: *const ToolContext, name: []const u8, args: []const u8) anyerror![]u8 {
    if (getTool(name)) |t| return t.execute(ctx, args);
    if (ctx.dyn_registry) |dr| {
        if (dr.find(name)) |de| return de.execute(ctx, args, de.ctx_ptr);
    }
    return error.UnknownTool;
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
    try std.testing.expect(getTool("Task") != null);
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

test "toToolDefinitionsWithDyn appends dynamic tools before web_search" {
    const dyn_mod = @import("tools/dynamic.zig");
    var dyn = dyn_mod.DynRegistry.init(std.testing.allocator);
    defer dyn.deinit();
    const dummy = struct {
        fn exec(_: *const ToolContext, _: []const u8, _: ?*anyopaque) anyerror![]u8 {
            return std.testing.allocator.dupe(u8, "dummy");
        }
    }.exec;
    try dyn.register("MySkill", "a skill", &.{}, dummy, null);

    const defs = try toToolDefinitionsWithDyn(std.testing.allocator, &dyn);
    defer std.testing.allocator.free(defs);

    try std.testing.expect(defs.len == registry.len + 2); // static + 1 dyn + web_search
    // web_search 始终在最后
    try std.testing.expectEqualStrings("web_search", defs[defs.len - 1].name);
    // 倒数第二是 MySkill（dyn 在 web_search 之前 append）
    try std.testing.expectEqualStrings("MySkill", defs[defs.len - 2].name);
}

test "dispatch finds static tool" {
    const ctx = ToolContext.simple(std.testing.allocator);
    try std.testing.expectError(error.MissingPath, dispatch(&ctx, "Read", "{}"));
}

test "dispatch falls back to dyn_registry" {
    const dyn_mod = @import("tools/dynamic.zig");
    var dyn = dyn_mod.DynRegistry.init(std.testing.allocator);
    defer dyn.deinit();
    const echo = struct {
        fn exec(_: *const ToolContext, args: []const u8, _: ?*anyopaque) anyerror![]u8 {
            return std.testing.allocator.dupe(u8, args);
        }
    }.exec;
    try dyn.register("Echo", "echoes input", &.{}, echo, null);

    var ctx = ToolContext.simple(std.testing.allocator);
    ctx.dyn_registry = &dyn;
    const out = try dispatch(&ctx, "Echo", "hello");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "dispatch returns UnknownTool when missing everywhere" {
    var ctx = ToolContext.simple(std.testing.allocator);
    try std.testing.expectError(error.UnknownTool, dispatch(&ctx, "NoSuchTool", "{}"));
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
    _ = &monitor_tool;
    _ = &notebook_edit_tool;
    _ = &worktree_tool;
    _ = &web_fetch_tool;
    _ = &ask_user_tool;
    _ = &plan_mode_tool;
    _ = &task_tools;
    _ = &agent_tool;
}
