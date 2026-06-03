const std = @import("std");
const json = @import("json.zig");

const read_tool = @import("tools/read.zig");
const write_tool = @import("tools/write.zig");
const edit_tool = @import("tools/edit.zig");
const glob_tool = @import("tools/glob.zig");
const bash_tool = @import("tools/bash.zig");
const grep_tool = @import("tools/grep.zig");
const bash_output_tool = @import("tools/bash_output.zig");
const task_output_tool = @import("tools/task_output.zig");
const kill_shell_tool = @import("tools/kill_shell.zig");
const monitor_tool = @import("tools/monitor.zig");
const notebook_edit_tool = @import("tools/notebook_edit.zig");
const worktree_tool = @import("tools/worktree.zig");
const mcp_resources_tool = @import("tools/mcp_resources.zig");
const push_notification_tool = @import("tools/push_notification.zig");
const cron_tool = @import("tools/cron.zig");
const web_fetch_tool = @import("tools/web_fetch.zig");
const ask_user_tool = @import("tools/ask_user.zig");
const plan_mode_tool = @import("tools/plan_mode.zig");
const task_tools = @import("tools/task_tools.zig");
const agent_tool = @import("tools/agent.zig");

pub const ToolContext = @import("tools/context.zig").ToolContext;
pub const PromptContext = @import("tools/prompt_context.zig").PromptContext;
pub const descriptions = @import("tools/descriptions.zig");

pub const ToolResult = struct {
    content: []const u8,
    is_error: bool = false,
};

/// 工具执行函数签名（M2 起）：ctx 携带 allocator、abort、未来还有 permission/cwd。
pub const ExecuteFn = *const fn (ctx: *const ToolContext, args: []const u8) anyerror![]u8;

/// 工具长描述生成函数签名（动态耦合）：按 PromptContext 生成 owned 描述。
/// 对应 cc/src/Tool.ts 的 tool.prompt(ctx)。
pub const DescribeFn = *const fn (allocator: std.mem.Allocator, ctx: *const PromptContext) anyerror![]u8;

pub const ToolEntry = struct {
    name: []const u8,
    /// 静态短描述。describe_fn 为 null 时用它（简单工具）。
    description: []const u8,
    /// 动态长描述生成器。非 null 时优先于 description（核心工具用，支持动态耦合）。
    describe_fn: ?DescribeFn = null,
    input_schema: json.InputSchema,
    execute: ExecuteFn,
};

pub const registry: []const ToolEntry = &.{
    .{
        .name = "Read",
        .description = "Read a file from the local filesystem.",
        .describe_fn = descriptions.describeRead,
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "file_path", .type = "string", .description = "The absolute path to the file to read" },
            .{ .name = "offset", .type = "integer", .description = "The line number to start reading from (1-based)" },
            .{ .name = "limit", .type = "integer", .description = "The number of lines to read" },
        }, .required = &.{"file_path"} },
        .execute = read_tool.execute,
    },
    .{
        .name = "Write",
        .description = "Write a file to the local filesystem.",
        .describe_fn = descriptions.describeWrite,
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "file_path", .type = "string", .description = "The absolute path to the file to write" },
            .{ .name = "content", .type = "string", .description = "The content to write to the file" },
        }, .required = &.{ "file_path", "content" } },
        .execute = write_tool.execute,
    },
    .{
        .name = "Edit",
        .description = "Performs exact string replacements in files.",
        .describe_fn = descriptions.describeEdit,
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "file_path", .type = "string", .description = "The absolute path to the file to modify" },
            .{ .name = "old_string", .type = "string", .description = "The text to replace" },
            .{ .name = "new_string", .type = "string", .description = "The text to replace it with (must differ from old_string)" },
            .{ .name = "replace_all", .type = "boolean", .description = "Replace all occurrences of old_string (default false)" },
        }, .required = &.{ "file_path", "old_string", "new_string" } },
        .execute = edit_tool.execute,
    },
    .{
        .name = "Glob",
        .description = "Find files matching a glob pattern",
        .describe_fn = descriptions.describeGlob,
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "pattern", .type = "string", .description = "The glob pattern to match files against (e.g. **/*.zig)" },
            .{ .name = "path", .type = "string", .description = "The directory to search in (defaults to cwd)" },
        }, .required = &.{"pattern"} },
        .execute = glob_tool.execute,
    },
    .{
        .name = "Grep",
        .description = "Search for patterns in files using ripgrep",
        .describe_fn = descriptions.describeGrep,
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "pattern", .type = "string", .description = "The regular expression pattern to search for in file contents" },
            .{ .name = "path", .type = "string", .description = "File or directory to search in (defaults to cwd)" },
            .{ .name = "glob", .type = "string", .description = "Glob pattern to filter files (e.g. *.zig)" },
            .{ .name = "output_mode", .type = "string", .description = "Output mode", .enum_values = &.{ "content", "files_with_matches", "count" } },
            .{ .name = "-i", .type = "boolean", .description = "Case insensitive search" },
            .{ .name = "-n", .type = "boolean", .description = "Show line numbers (content mode)" },
        }, .required = &.{"pattern"} },
        .execute = grep_tool.execute,
    },
    // Bash 排在所有文件/搜索专用工具(Read/Write/Edit/Glob/Grep)之后,对齐 mecode 的
    // 工具顺序(default.md 工具清单:…Glob, Grep, NotebookEdit, Bash…)。MiniMax 类模型
    // 对工具顺序敏感:Bash(万能工具)若排在 Grep 前,模型易"先看到 Bash 就用",
    // 即便提示词写了"用 Grep 别用 Bash grep"。把 Bash 后置降低这种误选。
    .{
        .name = "Bash",
        .description = "Execute a bash command",
        .describe_fn = descriptions.describeBash,
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "command", .type = "string", .description = "The command to execute" },
            .{ .name = "description", .type = "string", .description = "Clear, concise description of what this command does in 5-10 words" },
            .{ .name = "timeout", .type = "integer", .description = "Optional timeout in milliseconds (max 600000)" },
            .{ .name = "run_in_background", .type = "boolean", .description = "Set to true to run this command in the background" },
        }, .required = &.{"command"} },
        .execute = bash_tool.execute,
    },
    .{
        .name = "BashOutput",
        .description = "Read stdout/stderr and status of a backgrounded Bash job by job_id",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "job_id", .type = "string", .description = "The id of the backgrounded Bash job to read" },
        }, .required = &.{"job_id"} },
        .execute = bash_output_tool.execute,
    },
    .{
        .name = "KillShell",
        .description = "Terminate a running backgrounded Bash job by job_id",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "job_id", .type = "string", .description = "The id of the backgrounded Bash job to terminate" },
        }, .required = &.{"job_id"} },
        .execute = kill_shell_tool.execute,
    },
    .{
        .name = "Monitor",
        .description = "Start a background monitor that runs a command and streams stdout line-by-line. Use to watch logs, poll status, or react to file changes mid-conversation. Each stdout line is collected into a ring buffer readable via BashOutput(job_id). Stop with KillShell(job_id). Args: command (required), description (required, e.g. 'errors in /var/log/app.log'). Optional: persistent (default false; if true, no timeout).",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "command", .type = "string", .description = "Shell command to run; each stdout line becomes an event" },
            .{ .name = "description", .type = "string", .description = "Short description of what is being monitored" },
            .{ .name = "persistent", .type = "boolean", .description = "If true, run with no timeout for the session lifetime" },
        }, .required = &.{ "command", "description" } },
        .execute = monitor_tool.execute,
    },
    .{
        .name = "NotebookEdit",
        .description = "Modify a Jupyter notebook (.ipynb) cell. Modes: replace (default) overwrites the cell's source; insert adds a new cell after target (or at start if no cell_id); delete removes the target cell. Args: notebook_path (required), new_source (required, may be empty for delete), cell_id (required for replace/delete; optional for insert), cell_type ('code' or 'markdown', required for insert), edit_mode.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "notebook_path", .type = "string", .description = "The absolute path to the .ipynb file" },
            .{ .name = "new_source", .type = "string", .description = "The new source for the cell (may be empty for delete)" },
            .{ .name = "cell_id", .type = "string", .description = "Target cell id (required for replace/delete)" },
            .{ .name = "cell_type", .type = "string", .description = "Cell type (required for insert)", .enum_values = &.{ "code", "markdown" } },
            .{ .name = "edit_mode", .type = "string", .description = "Edit mode", .enum_values = &.{ "replace", "insert", "delete" } },
        }, .required = &.{ "notebook_path", "new_source" } },
        .execute = notebook_edit_tool.execute,
    },
    .{
        .name = "EnterWorktree",
        .description = "Enter an isolated git worktree. Pass `path` to switch into an existing worktree, OR pass `name` (and optional `base` branch) to create a new worktree under .cc-zig/worktrees/<name>/. Changes the session's working directory. Returns {worktree, branch, entered, created}.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "name", .type = "string", .description = "Name for a new worktree to create" },
            .{ .name = "path", .type = "string", .description = "Path of an existing worktree to switch into" },
            .{ .name = "base", .type = "string", .description = "Base branch for a newly created worktree" },
        }, .required = &.{} },
        .execute = worktree_tool.enterExecute,
    },
    .{
        .name = "ExitWorktree",
        .description = "Exit the current worktree and return to the original directory. Args: action='keep' (leaves worktree and branch intact) or 'remove' (also deletes the worktree). Optional discard_changes=true to force-remove even with uncommitted changes.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "action", .type = "string", .description = "keep leaves worktree intact; remove deletes it", .enum_values = &.{ "keep", "remove" } },
            .{ .name = "discard_changes", .type = "boolean", .description = "Force-remove even with uncommitted changes" },
        }, .required = &.{"action"} },
        .execute = worktree_tool.exitExecute,
    },
    .{
        .name = "ListMcpResourcesTool",
        .description = "List resources exposed by all connected MCP servers. Optional server arg to filter to a single server. Returns aggregated list of {server, uri, name, description, mimeType}.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "server", .type = "string", .description = "Optional: filter to a single MCP server name" },
        }, .required = &.{} },
        .execute = mcp_resources_tool.listExecute,
    },
    .{
        .name = "ReadMcpResourceTool",
        .description = "Read a specific MCP resource by URI. Required: uri. Optional: server (hint for which connected server to query first; otherwise tries all). Returns the resource content as JSON.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "uri", .type = "string", .description = "The URI of the MCP resource to read" },
            .{ .name = "server", .type = "string", .description = "Optional: hint for which server to query first" },
        }, .required = &.{"uri"} },
        .execute = mcp_resources_tool.readExecute,
    },
    .{
        .name = "PushNotification",
        .description = "Send a desktop notification to pull the user's attention back to the session — e.g. a long task finished, or you need a decision before continuing. Use sparingly: only when there's a real chance the user stepped away. Keep message under 200 chars, one line. Args: message (required).",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "message", .type = "string", .description = "The notification body, under 200 chars, one line" },
        }, .required = &.{"message"} },
        .execute = push_notification_tool.execute,
    },
    .{
        .name = "CronCreate",
        .description = "Schedule a prompt to fire at a future time. Recurring (cron) or one-shot (delaySeconds). Args: cron (5-field 'M H DoM Mon DoW') OR delaySeconds; prompt (required); recurring (default true). Session-scoped, fires when you return to the prompt. Returns job id.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "prompt", .type = "string", .description = "The prompt to enqueue at each fire time" },
            .{ .name = "cron", .type = "string", .description = "5-field cron expression 'M H DoM Mon DoW'" },
            .{ .name = "delaySeconds", .type = "integer", .description = "One-shot delay in seconds (alternative to cron)" },
            .{ .name = "recurring", .type = "boolean", .description = "Fire repeatedly (default true) vs once" },
        }, .required = &.{"prompt"} },
        .execute = cron_tool.createExecute,
    },
    .{
        .name = "CronDelete",
        .description = "Cancel a scheduled cron job by id.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "id", .type = "string", .description = "The id of the cron job to cancel" },
        }, .required = &.{"id"} },
        .execute = cron_tool.deleteExecute,
    },
    .{
        .name = "CronList",
        .description = "List all scheduled cron jobs in this session.",
        .input_schema = .{ .type = "object", .prop_specs = &.{}, .required = &.{} },
        .execute = cron_tool.listExecute,
    },
    .{
        .name = "WebFetch",
        .description = "Fetch a URL and return its text content (HTML stripped). Use for reading web pages, API docs, articles.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "url", .type = "string", .description = "The URL to fetch content from" },
            .{ .name = "prompt", .type = "string", .description = "Optional prompt to run against the fetched content" },
        }, .required = &.{"url"} },
        .execute = web_fetch_tool.execute,
    },
    .{
        .name = "AskUserQuestion",
        .description = "Ask the user a multiple-choice question interactively. Only works in TTY. Use when you need user decision to proceed (architecture choices, ambiguous requests).",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "questions", .type = "array", .description = "List of questions, each with header/question/options", .items_type = "object" },
        }, .required = &.{"questions"} },
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
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "subject", .type = "string", .description = "A brief title for the task" },
            .{ .name = "description", .type = "string", .description = "What needs to be done" },
            .{ .name = "activeForm", .type = "string", .description = "Present-continuous form shown while in progress (e.g. 'Running tests')" },
        }, .required = &.{ "subject", "description" } },
        .execute = task_tools.executeCreate,
    },
    .{
        .name = "TaskGet",
        .description = "Fetch the full Task record (description, status, owner, blocks, blockedBy) by id.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "taskId", .type = "string", .description = "The id of the task to fetch" },
        }, .required = &.{"taskId"} },
        .execute = task_tools.executeGet,
    },
    .{
        .name = "TaskList",
        .description = "List all tasks with id, subject, status, owner and blockedBy (summary view).",
        .input_schema = .{ .type = "object", .prop_specs = &.{}, .required = &.{} },
        .execute = task_tools.executeList,
    },
    .{
        .name = "TaskUpdate",
        .description = "Update a task's status (pending/in_progress/completed/deleted) and/or fields (subject, description, activeForm, owner) and/or addBlocks/addBlockedBy id lists.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "taskId", .type = "string", .description = "The id of the task to update" },
            .{ .name = "status", .type = "string", .description = "New status", .enum_values = &.{ "pending", "in_progress", "completed", "deleted" } },
            .{ .name = "subject", .type = "string", .description = "New subject (title)" },
            .{ .name = "description", .type = "string", .description = "New description" },
            .{ .name = "activeForm", .type = "string", .description = "New present-continuous form" },
            .{ .name = "owner", .type = "string", .description = "New owner (agent name)" },
            .{ .name = "addBlocks", .type = "array", .description = "Task ids that this task blocks", .items_type = "string" },
            .{ .name = "addBlockedBy", .type = "array", .description = "Task ids that block this task", .items_type = "string" },
        }, .required = &.{"taskId"} },
        .execute = task_tools.executeUpdate,
    },
    .{
        .name = "TaskStop",
        .description = "Stop a task by id. For a backgrounded agent job (agent_* id, or agent_job_id arg), requests termination of the running subagent. For a todo task id, marks it completed (shortcut for TaskUpdate status=completed).",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "taskId", .type = "string", .description = "The task id (todo id or agent_* job id) to stop" },
            .{ .name = "agent_job_id", .type = "string", .description = "Alternative: the backgrounded agent job id to terminate" },
        }, .required = &.{"taskId"} },
        .execute = task_tools.executeStop,
    },
    .{
        .name = "TaskOutput",
        .description = "Read status and incremental output of a backgrounded Task subagent by agent_job_id. While running, returns incremental output (poll with since_byte = previous output_total_bytes); when done, returns final_text + stop_reason. Args: agent_job_id (required), since_byte, max_bytes (optional).",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "agent_job_id", .type = "string", .description = "The backgrounded agent job id to read" },
            .{ .name = "since_byte", .type = "integer", .description = "Byte offset to poll from (previous output_total_bytes)" },
            .{ .name = "max_bytes", .type = "integer", .description = "Max bytes to return this call" },
        }, .required = &.{"agent_job_id"} },
        .execute = task_output_tool.execute,
    },
    .{
        .name = "Task",
        .description = "Launch a subagent in an isolated context to handle a side task. Each subagent starts with a fresh context — it cannot see this conversation, only the prompt you pass. Use for: high-volume operations (running tests, processing logs), parallel research, isolating exploration that would flood your context. Args: subagent_type (Explore/Plan/general-purpose/<custom>), description (3-5 word UI label), prompt (the delegation message). Optional: max_turns, model, run_in_background (true returns an agent_job_id immediately; poll with TaskOutput, stop with TaskStop).",
        .describe_fn = descriptions.describeTask,
        // schema required 只列**真正必需**的:subagent_type 缺省 general-purpose、
        // description 只是 UI 标签 → 都不是硬必需(agent.zig 有默认)。只有 prompt 缺会真失败。
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "prompt", .type = "string", .description = "The task/delegation message for the subagent" },
            .{ .name = "subagent_type", .type = "string", .description = "Agent type (Explore/Plan/general-purpose/custom); defaults to general-purpose" },
            .{ .name = "description", .type = "string", .description = "3-5 word UI label for the task" },
            .{ .name = "max_turns", .type = "integer", .description = "Max agent loop turns" },
            .{ .name = "model", .type = "string", .description = "Model override for the subagent" },
            .{ .name = "run_in_background", .type = "boolean", .description = "Run async; returns agent_job_id immediately" },
        }, .required = &.{"prompt"} },
        .execute = agent_tool.execute,
    },
    .{
        .name = "Agent",
        .description = "Deprecated alias for Task. Use Task with subagent_type instead. Currently routes to Task with subagent_type=\"general-purpose\".",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "prompt", .type = "string", .description = "The task/delegation message for the subagent" },
            .{ .name = "subagent_type", .type = "string", .description = "Agent type; defaults to general-purpose" },
            .{ .name = "description", .type = "string", .description = "3-5 word UI label for the task" },
        }, .required = &.{"prompt"} },
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
    return toToolDefinitionsFull(allocator, null, null);
}

/// 合并静态 + 动态工具 + web_search server tool。`dyn` 为 null 时等价 toToolDefinitions。
/// 顺序：静态 → 动态（Skill/MCP）→ web_search。
pub fn toToolDefinitionsWithDyn(
    allocator: std.mem.Allocator,
    dyn: ?*const @import("tools/dynamic.zig").DynRegistry,
) ![]json.ToolDefinition {
    return toToolDefinitionsFull(allocator, dyn, null);
}

/// 完整版：额外接收 PromptContext。非 null 时，有 describe_fn 的工具用动态长描述
/// （对应 cc 的 tool.prompt(ctx)）；否则回退静态 description。
/// 动态描述在 `allocator` 上分配（调用方用 arena，session 结束统一释放）。
pub fn toToolDefinitionsFull(
    allocator: std.mem.Allocator,
    dyn: ?*const @import("tools/dynamic.zig").DynRegistry,
    prompt_ctx: ?*const PromptContext,
) ![]json.ToolDefinition {
    var defs = try std.ArrayList(json.ToolDefinition).initCapacity(allocator, registry.len + 1);
    defer defs.deinit(allocator);

    for (registry) |*tool| {
        const desc: []const u8 = blk: {
            if (prompt_ctx) |pc| {
                if (tool.describe_fn) |df| break :blk try df(allocator, pc);
            }
            break :blk tool.description;
        };
        try defs.append(allocator, .{
            .name = tool.name,
            .description = desc,
            .input_schema = .{
                .type = tool.input_schema.type,
                // 透传 comptime prop_specs（内置工具字段定义）。早先这里硬编码 null，
                // 把 registry 声明的 schema 全抹掉 → 模型只收到空 properties，触发
                // 空参/漏参风暴（TaskCreate MissingRequiredField 即此根因）。
                .prop_specs = tool.input_schema.prop_specs,
                .properties = null,
                .required = tool.input_schema.required,
            },
        });
    }

    // 动态工具(Skill/MCP)按 name 排序后追加(对齐 cc:builtin 前缀稳定 + dyn 排序,
    // 这样增删一个 MCP 工具不会打乱其余顺序、击穿下游 prompt cache)。静态 registry
    // 是 comptime 固定序,不动(reorder 它本身就会击穿缓存)。
    if (dyn) |d| {
        const dyn_start = defs.items.len;
        try d.appendDefinitions(&defs, allocator);
        const dyn_slice = defs.items[dyn_start..];
        std.sort.block(json.ToolDefinition, dyn_slice, {}, struct {
            fn lt(_: void, a: json.ToolDefinition, b: json.ToolDefinition) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lt);
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

/// 就地用新的 PromptContext 重写已有 defs 里"有 describe_fn"工具的 description。
/// 用于 subagent:父 defs 是用主对话 context 建的,subagent(尤其只读 Explore/Plan)
/// 需要不同描述(Bash 去 Git 段 + 加只读提醒)。新描述在 allocator 上分配(arena)。
/// 非 describe_fn 工具 / 动态 Skill / web_search 不动。
pub fn redescribeForContext(
    allocator: std.mem.Allocator,
    defs: []json.ToolDefinition,
    prompt_ctx: *const PromptContext,
) !void {
    for (defs) |*d| {
        if (getTool(d.name)) |t| {
            if (t.describe_fn) |df| {
                d.description = try df(allocator, prompt_ctx);
            }
        }
    }
}

pub fn executeTool(tool: *const ToolEntry, ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    return tool.execute(ctx, args);
}

/// Schema 层校验(对齐 cc 的 zod safeParse 层):执行前检查 input JSON 含所有 required
/// 字段。缺则返 error.MissingRequiredField(agent_loop 转 invalid_args 现场给模型)。
/// 这是工具自身 MissingX 检查之外的统一前置层——uniform + 在 dispatch 前拦,且对没写
/// 自检的工具也兜底。检查用顶层 "field": 子串(与 extractJsonArg 同口径,够分辨缺失)。
pub fn validateRequired(name: []const u8, args: []const u8) error{MissingRequiredField}!void {
    const t = getTool(name) orelse return; // 动态工具(MCP/Skill)走自己的校验
    const required = t.input_schema.required orelse return;
    for (required) |field| {
        var pat_buf: [128]u8 = undefined;
        if (field.len + 3 > pat_buf.len) continue;
        // 匹配 "field": (顶层键)。简化:子串匹配(args 是工具入参 JSON,误报概率极低)。
        const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\"", .{field}) catch continue;
        if (std.mem.indexOf(u8, args, pat) == null) return error.MissingRequiredField;
    }
}

/// schema 类型层(对齐 cc zod 的类型校验维度):对 input JSON 中**已出现**的高风险字段,
/// 校验 JSON 值类型匹配(该传 int 传了 string 等)。缺失字段不在此层报(交 validateRequired)。
/// cc-zig 不引入 zod 等价框架,改用 per-tool 显式类型表 + 单点类型探测,只覆盖模型最易
/// 传错类型的字段(offset/limit/timeout=int, replace_all/run_in_background=bool)。
pub const FieldType = enum { string, integer, boolean };
const FieldSpec = struct { name: []const u8, ty: FieldType };

fn fieldSpecs(name: []const u8) []const FieldSpec {
    if (std.mem.eql(u8, name, "Read")) return &.{
        .{ .name = "file_path", .ty = .string },
        .{ .name = "offset", .ty = .integer },
        .{ .name = "limit", .ty = .integer },
    };
    if (std.mem.eql(u8, name, "Write")) return &.{
        .{ .name = "file_path", .ty = .string },
        .{ .name = "content", .ty = .string },
    };
    if (std.mem.eql(u8, name, "Edit")) return &.{
        .{ .name = "file_path", .ty = .string },
        .{ .name = "old_string", .ty = .string },
        .{ .name = "new_string", .ty = .string },
        .{ .name = "replace_all", .ty = .boolean },
    };
    if (std.mem.eql(u8, name, "Bash")) return &.{
        .{ .name = "command", .ty = .string },
        .{ .name = "timeout", .ty = .integer },
        .{ .name = "run_in_background", .ty = .boolean },
    };
    if (std.mem.eql(u8, name, "Grep")) return &.{
        .{ .name = "pattern", .ty = .string },
        .{ .name = "path", .ty = .string },
    };
    if (std.mem.eql(u8, name, "Glob")) return &.{
        .{ .name = "pattern", .ty = .string },
        .{ .name = "path", .ty = .string },
    };
    return &.{};
}

/// schema 类型层:已出现的声明字段值类型必须匹配,否则 error.InvalidFieldType
/// (→ invalid_args 给模型现场)。
pub fn validateTypes(name: []const u8, args: []const u8) error{InvalidFieldType}!void {
    for (fieldSpecs(name)) |spec| {
        const kind = jsonValueKind(args, spec.name) orelse continue; // 字段不存在 → 跳
        const ok = switch (spec.ty) {
            .string => kind == .string,
            .integer => kind == .number,
            .boolean => kind == .boolean,
        };
        if (!ok) return error.InvalidFieldType;
    }
}

const JsonKind = enum { string, number, boolean, null_, array, object };

/// 定位顶层 "key": 后的值,判其 JSON 类型(单点探测,不解析整树)。
fn jsonValueKind(args: []const u8, key: []const u8) ?JsonKind {
    var pat_buf: [128]u8 = undefined;
    if (key.len + 3 > pat_buf.len) return null;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, args, pat) orelse return null;
    var p = at + pat.len;
    // 跳过空白到冒号
    while (p < args.len and (args[p] == ' ' or args[p] == '\t')) : (p += 1) {}
    if (p >= args.len or args[p] != ':') return null;
    p += 1;
    while (p < args.len and (args[p] == ' ' or args[p] == '\t' or args[p] == '\n' or args[p] == '\r')) : (p += 1) {}
    if (p >= args.len) return null;
    return switch (args[p]) {
        '"' => .string,
        '[' => .array,
        '{' => .object,
        't', 'f' => .boolean,
        'n' => .null_,
        '-', '0'...'9' => .number,
        else => null,
    };
}

/// 统一派发：先查静态注册表，未命中查 ctx.dyn_registry。
/// 找不到返 error.UnknownTool —— 由 agent_loop 转 tool_error 给模型。
pub fn dispatch(ctx: *const ToolContext, name: []const u8, args: []const u8) anyerror![]u8 {
    if (getTool(name)) |t| {
        try validateRequired(name, args); // schema 层:缺 required 字段 → 早拦
        try validateTypes(name, args); // schema 层:字段类型不匹配 → 早拦
        return t.execute(ctx, args);
    }
    if (ctx.dyn_registry) |dr| {
        if (dr.find(name)) |de| return de.execute(ctx, args, de.ctx_ptr);
    }
    return error.UnknownTool;
}

/// 工具是否可与同批工具并发执行(对齐 cc isConcurrencySafe)。
/// 安全 = 只读 + 不写任何共享态(或写的共享态已线程安全)。
///   Read(read_state 已加锁)/Glob/Grep/WebFetch/BashOutput → safe。
///   Write/Edit/Bash/Task*/NotebookEdit/MCP/Skill 等有副作用或写共享态 → unsafe。
/// 一期按工具名判定(cc 是 per-input;cc-zig 工具名足够,Bash 即便 readonly 也保守串行)。
pub fn isConcurrencySafe(name: []const u8) bool {
    const safe = [_][]const u8{ "Read", "Glob", "Grep", "WebFetch", "BashOutput" };
    for (safe) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// per-input 并发安全判定（对齐 cc isConcurrencySafe(input)，toolOrchestration.ts）。
/// 非 Bash 工具沿用 per-tool 名单（isConcurrencySafe）；Bash 解析 command 字符串，
/// 复合命令**每一段** stripWrappers 后都是 readonly 才算 safe，否则保守 unsafe。
/// fail-closed：提取失败 / 危险子串(重定向·命令替换·管道入 shell) / 任一段非 readonly → unsafe。
pub fn isConcurrencySafeInput(name: []const u8, input: []const u8) bool {
    if (!std.mem.eql(u8, name, "Bash")) return isConcurrencySafe(name);
    return bashInputReadonly(input);
}

const bash_parser = @import("permission/bash_parser.zig");
const shell_lex = @import("tools/shell_lex.zig");
const common = @import("tools/common.zig");

fn bashInputReadonly(input: []const u8) bool {
    const cmd = common.extractJsonArg(input, "command") orelse return false;
    if (cmd.len == 0) return false;
    // 危险子串(管道入 shell / fork bomb / $(curl 等)→ 直接 unsafe。
    shell_lex.validate(cmd) catch return false;
    // 命令替换 $(...) / `...` 内是任意命令——并发安全无法保证,一律 unsafe
    // (比 shell_lex 的安全语义更严:这里是并发门,宁可串行)。
    if (std.mem.indexOf(u8, cmd, "$(") != null) return false;
    if (std.mem.indexOfScalar(u8, cmd, '`') != null) return false;
    // 输出重定向 > / >> 是写操作(shell_lex 不挡、splitCompound 不拆),显式判 unsafe。
    // 注意 2>&1 / 2>/dev/null 这类 fd 重定向也按写处理(保守 unsafe，宁可串行)。
    if (hasOutputRedirect(cmd)) return false;
    // 复合拆分：每段剥 wrapper 后必须 readonly，否则按最危险段判 unsafe。
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const segs = bash_parser.splitCompound(arena.allocator(), cmd) catch return false;
    if (segs.len == 0) return false;
    for (segs) |seg| {
        const real = bash_parser.stripWrappers(seg);
        if (!bash_parser.isReadonlyCommand(real)) return false;
    }
    return true;
}

/// 检测引号外的输出重定向 `>` / `>>`（写文件，非并发安全）。
fn hasOutputRedirect(cmd: []const u8) bool {
    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    while (i < cmd.len) : (i += 1) {
        const c = cmd[i];
        if (c == '\\') {
            i += 1;
            continue;
        }
        if (!in_double and c == '\'') {
            in_single = !in_single;
            continue;
        }
        if (!in_single and c == '"') {
            in_double = !in_double;
            continue;
        }
        if (!in_single and !in_double and c == '>') return true;
    }
    return false;
}

test "isConcurrencySafeInput: Bash readonly per-input" {
    // 单命令只读 → safe
    try std.testing.expect(isConcurrencySafeInput("Bash", "{\"command\":\"ls -la /tmp\"}"));
    try std.testing.expect(isConcurrencySafeInput("Bash", "{\"command\":\"cat /etc/hosts\"}"));
    try std.testing.expect(isConcurrencySafeInput("Bash", "{\"command\":\"git status\"}"));
    try std.testing.expect(isConcurrencySafeInput("Bash", "{\"command\":\"find . -name x\"}"));
    // 写/破坏类 → unsafe
    try std.testing.expect(!isConcurrencySafeInput("Bash", "{\"command\":\"rm -rf /\"}"));
    try std.testing.expect(!isConcurrencySafeInput("Bash", "{\"command\":\"git push\"}"));
    try std.testing.expect(!isConcurrencySafeInput("Bash", "{\"command\":\"npm install\"}"));
    try std.testing.expect(!isConcurrencySafeInput("Bash", "{\"command\":\"mkdir x\"}"));
}

test "isConcurrencySafeInput: Bash compound 按最危险段" {
    try std.testing.expect(!isConcurrencySafeInput("Bash", "{\"command\":\"ls && rm -rf x\"}"));
    try std.testing.expect(isConcurrencySafeInput("Bash", "{\"command\":\"ls && cat f && git log\"}"));
}

test "isConcurrencySafeInput: Bash 重定向/命令替换 → unsafe" {
    try std.testing.expect(!isConcurrencySafeInput("Bash", "{\"command\":\"cat a > b\"}"));
    try std.testing.expect(!isConcurrencySafeInput("Bash", "{\"command\":\"echo $(rm x)\"}"));
}

test "isConcurrencySafeInput: wrapper 剥离后判 readonly" {
    try std.testing.expect(isConcurrencySafeInput("Bash", "{\"command\":\"timeout 5 git status\"}"));
}

test "isConcurrencySafeInput: 非 Bash 工具沿用名单" {
    try std.testing.expect(isConcurrencySafeInput("Read", "{\"file_path\":\"/x\"}"));
    try std.testing.expect(isConcurrencySafeInput("Grep", "{\"pattern\":\"x\"}"));
    try std.testing.expect(!isConcurrencySafeInput("Write", "{\"file_path\":\"/x\",\"content\":\"y\"}"));
    try std.testing.expect(!isConcurrencySafeInput("Edit", "{\"file_path\":\"/x\"}"));
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
    // schema 层(validateRequired)先于工具自身校验:Read 缺 required file_path
    // → MissingRequiredField(对齐 cc zod safeParse 在 validateInput 之前)。
    try std.testing.expectError(error.MissingRequiredField, dispatch(&ctx, "Read", "{}"));
    // 带 file_path 但工具内部其它校验:走到工具自身(此处文件不存在 → 工具错误,非 schema 层)。
    try std.testing.expectError(error.FileNotFound, dispatch(&ctx, "Read", "{\"file_path\":\"/no/such/file/xyz123\"}"));
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
    _ = &mcp_resources_tool;
    _ = &push_notification_tool;
    _ = &cron_tool;
    _ = &web_fetch_tool;
    _ = &ask_user_tool;
    _ = &plan_mode_tool;
    _ = &task_tools;
    _ = &agent_tool;
}
