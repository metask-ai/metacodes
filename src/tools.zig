const std = @import("std");
const json = @import("json.zig");

const read_tool = @import("tools/read.zig");
const write_tool = @import("tools/write.zig");
const edit_tool = @import("tools/edit.zig");
const apply_patch_tool = @import("tools/apply_patch.zig");
const task_batch_tool = @import("tools/task_batch.zig");
const glob_tool = @import("tools/glob.zig");
const bash_tool = @import("tools/bash.zig");
const grep_tool = @import("tools/grep.zig");
const bash_output_tool = @import("tools/bash_output.zig");
const read_artifact_tool = @import("tools/read_artifact.zig");
const task_output_tool = @import("tools/task_output.zig");
const swarm_tools = @import("swarm/tools.zig");
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
/// pub:v36 读平面 supersede 的纯判定(hitSupersededByArtifact)需 L2 直测。
pub const kg_tools = @import("tools/kg_tools.zig");
const kg_retrieval = @import("kg/retrieval_protocol.zig");
const formal_task_audit = @import("formal/task_audit.zig");
const agent_tool = @import("tools/agent.zig");
const tool_search_tool = @import("tools/tool_search.zig");
const web_search_tool = @import("tools/web_search.zig");
const code_map_tool = @import("tools/code_map.zig");
const find_symbol_tool = @import("tools/find_symbol.zig");

pub const ToolContext = @import("tools/context.zig").ToolContext;
pub const ToolDispatcher = @import("tools/context.zig").ToolDispatcher;
pub const ToolExecutorKind = @import("tools/context.zig").ToolExecutorKind;
pub const ToolMeta = @import("tools/context.zig").ToolMeta;
pub const ToolDispatchOutcome = @import("tools/context.zig").ToolDispatchOutcome;
pub const ToolResultBody = @import("tools/context.zig").ToolResultBody;
pub const ToolExecutionPolicy = @import("tools/context.zig").ToolExecutionPolicy;
pub const RunIdentity = @import("tools/context.zig").RunIdentity;
pub const HostRunIdentity = @import("tools/context.zig").HostRunIdentity;
pub const HostServices = @import("tools/context.zig").HostServices;
pub const PendingRequest = @import("tools/context.zig").PendingRequest;
pub const ToolProgressReporter = @import("tools/context.zig").ToolProgressReporter;
pub const ToolObservationSink = @import("tools/context.zig").ToolObservationSink;
pub const ProjectRuleGate = @import("tools/context.zig").ProjectRuleGate;
pub const ToolObservationOrigin = @import("tools/context.zig").ToolObservationOrigin;
pub const tool_observation = @import("tools/observation.zig");
pub const ReplayDeclaration = @import("core/execution_effect.zig").ReplayDeclaration;
pub const PromptContext = @import("tools/prompt_context.zig").PromptContext;
pub const descriptions = @import("tools/descriptions.zig");

pub const ToolResult = struct {
    content: []const u8,
    is_error: bool = false,
};

/// 工具执行函数签名（M2 起）：ctx 携带 allocator、abort、未来还有 permission/cwd。
pub const ExecuteFn = *const fn (ctx: *const ToolContext, args: []const u8) anyerror![]u8;
pub const ExecuteBodyFn = *const fn (ctx: *const ToolContext, args: []const u8) anyerror!ToolResultBody;

/// Native tools migrate independently: legacy implementations are adapted at
/// this single boundary, while spool-aware implementations return the typed
/// body directly. The tagged union prevents a ToolEntry from carrying two
/// competing executors or neither.
pub const ToolExecutor = union(enum) {
    legacy_inline: ExecuteFn,
    result_body: ExecuteBodyFn,

    pub fn run(self: ToolExecutor, ctx: *const ToolContext, args: []const u8) anyerror!ToolResultBody {
        return switch (self) {
            .legacy_inline => |execute| ToolResultBody.initInline(try execute(ctx, args)),
            .result_body => |execute| execute(ctx, args),
        };
    }
};

/// Auditable producer classification. `byte_zero_spool` is a correctness
/// contract, not a tuning hint: such entries must use the typed executor and
/// acquire kernel storage before their unbounded producer starts.
pub const ResultProduction = enum {
    bounded_inline,
    input_derived,
    byte_zero_spool,
};

/// 工具长描述生成函数签名（动态耦合）：按 PromptContext 生成 owned 描述。
/// 对应 cc/src/Tool.ts 的 tool.prompt(ctx)。
pub const DescribeFn = *const fn (allocator: std.mem.Allocator, ctx: *const PromptContext) anyerror![]u8;

/// 内置工具执行期依赖的进程外可执行文件。catalog 准入按此探测可用性:
/// Runtime 不得广告一个在当前环境无法执行的工具——依赖缺失是创建期的
/// 类型化配置错误(ToolDependencyUnavailable),不是首调时的执行失败。
pub const RuntimeDependency = enum {
    /// rg / rg.exe,解析顺序见 util/toolchain.zig(RG_BIN → PATH →
    /// Host 可执行文件同目录 → 常见安装位)。
    ripgrep,
};

pub const ToolEntry = struct {
    name: []const u8,
    /// 静态短描述。describe_fn 为 null 时用它（简单工具）。
    description: []const u8,
    /// 动态长描述生成器。非 null 时优先于 description（核心工具用，支持动态耦合）。
    describe_fn: ?DescribeFn = null,
    input_schema: json.InputSchema,
    execute: ToolExecutor,
    /// Candidate recovery class. The kernel resolves this per invocation and
    /// may always downgrade it; extensions cannot grant their own replay.
    replay: ReplayDeclaration = .never,
    result_production: ResultProduction = .bounded_inline,
    /// deferred(对齐 cc ToolSearch):true = 不进默认 tools 数组,只在 prompt 列名;
    /// 模型须先调 ToolSearch 激活才可调。降低工具菜单稀释(弱后端会乱抓 Bash 的根因)。
    deferred: bool = false,
    /// 用户可见名(对齐 cc userFacingName):TUI 工具卡标题用它而非 registry 名。
    /// null = 用 name。如 WebSearch → "Web Search"(带空格)。
    display_name: ?[]const u8 = null,
    /// Swarm 门控工具(TeamCreate/TeamDelete/SendMessage):仅 --agent-teams 时进 advertised
    /// tool_defs(F5)。默认 false=常规工具不受门控。
    swarm_gated: bool = false,
    /// Only advertised when the active long-horizon treatment includes TinyKG.
    tinykg_gated: bool = false,
    /// 执行期必需的进程外可执行依赖。非 null 时 catalog 准入先探测可用性,
    /// 缺失则拒绝创建而不是广告后首调失败。
    runtime_dependency: ?RuntimeDependency = null,
};

const SESSION_TASK_STATUS_VALUES: []const []const u8 = &.{ "pending", "in_progress", "completed", "deleted" };
const SESSION_TASK_UPDATE_PROPS: []const json.PropSpec = &.{
    json.PropSpec{ .name = "taskId", .type = "string", .description = "The id of the in-session task to update" },
    json.PropSpec{ .name = "status", .type = "string", .description = "New in-session status", .enum_values = SESSION_TASK_STATUS_VALUES },
    json.PropSpec{ .name = "subject", .type = "string", .description = "New subject (title)" },
    json.PropSpec{ .name = "description", .type = "string", .description = "New description" },
    json.PropSpec{ .name = "activeForm", .type = "string", .description = "New present-continuous form" },
    json.PropSpec{ .name = "owner", .type = "string", .description = "New owner (agent name)" },
    json.PropSpec{ .name = "addBlocks", .type = "array", .description = "Task ids that this task blocks", .items_type = "string" },
    json.PropSpec{ .name = "addBlockedBy", .type = "array", .description = "Task ids that block this task", .items_type = "string" },
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
            .{ .name = "outline", .type = "boolean", .description = "Return a symbol outline (functions/types with line numbers) instead of file contents. Requires an installed language server for the file's language; falls back to normal reading otherwise, naming the reason when the language server is unavailable." },
        }, .required = &.{"file_path"} },
        .execute = .{ .legacy_inline = read_tool.execute },
        .replay = .read_only,
    },
    .{
        .name = "Write",
        .description = "Write a file to the local filesystem.",
        .describe_fn = descriptions.describeWrite,
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "file_path", .type = "string", .description = "The absolute path to the file to write" },
            .{ .name = "content", .type = "string", .description = "The content to write to the file" },
        }, .required = &.{ "file_path", "content" } },
        .execute = .{ .legacy_inline = write_tool.execute },
        .result_production = .input_derived,
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
        .execute = .{ .legacy_inline = edit_tool.execute },
        .result_production = .input_derived,
    },
    .{
        .name = "ApplyPatch",
        .description = "Apply a codex-style patch envelope to add/delete/update/rename one or more files in a single call. The patch format uses '*** Begin Patch' / '*** End Patch' with '*** Add File:', '*** Delete File:', '*** Update File:' (and optional '*** Move to:') sections; update hunks use '@@' context markers plus ' '/'-'/'+' lines (no line numbers — context is located fuzzily). Transactional: if any hunk fails to apply, no files are written.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "patch", .type = "string", .description = "The full patch text, from '*** Begin Patch' to '*** End Patch'." },
        }, .required = &.{"patch"} },
        .execute = .{ .legacy_inline = apply_patch_tool.execute },
        .result_production = .input_derived,
    },
    .{
        .name = "Glob",
        .description = "Find files matching a glob pattern",
        .describe_fn = descriptions.describeGlob,
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "pattern", .type = "string", .description = "The glob pattern to match files against (e.g. **/*.zig)" },
            .{ .name = "path", .type = "string", .description = "The directory to search in (defaults to cwd)" },
        }, .required = &.{"pattern"} },
        .execute = .{ .result_body = glob_tool.executeBody },
        .replay = .read_only,
        .result_production = .byte_zero_spool,
        .runtime_dependency = .ripgrep,
    },
    .{
        .name = "Grep",
        .description = "Search for patterns in files, or inside a recovered tool-result artifact, using ripgrep",
        .describe_fn = descriptions.describeGrep,
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "pattern", .type = "string", .description = "The regular expression pattern to search for in file contents" },
            .{ .name = "path", .type = "string", .description = "File or directory to search in (defaults to cwd)" },
            .{ .name = "artifact_id", .type = "string", .description = "Search a recovered tool-result artifact instead of a path. Use the sha256 artifact_id from a truncated result to find the part you need in one call, rather than paging it with ReadArtifact. Mutually exclusive with path; output_mode must be content or count" },
            .{ .name = "glob", .type = "string", .description = "Glob pattern to filter files (e.g. *.zig)" },
            .{ .name = "output_mode", .type = "string", .description = "Output mode", .enum_values = &.{ "content", "files_with_matches", "count" } },
            .{ .name = "-i", .type = "boolean", .description = "Case insensitive search" },
            .{ .name = "-n", .type = "boolean", .description = "Show line numbers (content mode)" },
        }, .required = &.{"pattern"} },
        .execute = .{ .result_body = grep_tool.executeBody },
        .replay = .read_only,
        .result_production = .byte_zero_spool,
        .runtime_dependency = .ripgrep,
    },
    // CodeMap:代码结构大纲(LSP documentSymbol,Y2 砍 tree-sitter 后)。排在搜索工具之后、Bash
    // 之前——和 Grep/Glob 同属"专用搜索/导航工具",比整文件 Read 省 token,引导模型优先用它定位定义。
    .{
        .name = "CodeMap",
        .description = "Produce a structural outline of source code: functions, types, classes, " ++
            "constants with line numbers and signatures. Operates on SOURCE CODE only (not " ++
            "plain-text, config, JSON, or docs). Pass a file path for one file, or a glob (e.g. " ++
            "src/**/*) to map many files. Far cheaper than reading whole files when you only " ++
            "need to find where things are defined. Requires an installed language server " ++
            "(zls, pyright, typescript-language-server, gopls, rust-analyzer, clangd); when one " ++
            "is unavailable the output says so instead of appearing empty.",
        .describe_fn = descriptions.describeCodeMap,
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "path", .type = "string", .description = "A file path OR a glob pattern (e.g. src/**/*)" },
        }, .required = &.{"path"} },
        .execute = .{ .result_body = code_map_tool.executeBody },
        .replay = .read_only,
        .result_production = .byte_zero_spool,
    },
    // FindSymbol:跨文件找符号*定义*(LSP documentSymbol)。常驻默认工具菜单——A/B 实验(2026-06-08,
    // 192 次真模型)证明 deferred(藏 ToolSearch 后)致"找定义题"压不动(命中率仅 17%,
    // p=0.156 不显著),模型大量退回 Grep/ToolSearch。提为默认后无需激活即可直接调。
    .{
        .name = "FindSymbol",
        .description = "Find where a symbol is DEFINED across the codebase (SOURCE CODE only). " ++
            "Unlike Grep (which returns all occurrences), this returns only definitions, with " ++
            "file:line and signature. Use this to jump to a function/type/class definition by " ++
            "name when you don't know which file it lives in. Requires an installed language " ++
            "server (zls, pyright, typescript-language-server, gopls, rust-analyzer, clangd); an " ++
            "empty result is qualified when one is unavailable, so `[]` alone means not defined.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "name", .type = "string", .description = "The symbol name to find the definition of" },
            .{ .name = "kind", .type = "string", .description = "Optional kind filter", .enum_values = &.{ "function", "method", "struct", "enum", "union", "type", "constant", "variable", "class", "interface" } },
            .{ .name = "path", .type = "string", .description = "Optional directory/glob to scope the search (defaults to cwd)" },
        }, .required = &.{"name"} },
        .execute = .{ .result_body = find_symbol_tool.executeBody },
        .replay = .read_only,
        .result_production = .byte_zero_spool,
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
        .execute = .{ .result_body = bash_tool.executeBody },
        .result_production = .byte_zero_spool,
    },
    .{
        .name = "BashOutput",
        .description = "Read stdout/stderr and status of a backgrounded Bash job by job_id. Returns stdout/stderr chunks plus status (running|exited|killed). Use stdout_since_byte/stderr_since_byte for incremental reads. max_bytes caps a single read; omit it to get as much as the context budget allows (maximum 262144, and a large explicit value may still be reduced to fit that budget). To follow a long job, pass the previous stdout_next_offset/stderr_next_offset as the next stdout_since_byte/stderr_since_byte — those are the resume cursors. stdout_total_bytes/stderr_total_bytes report the file's current size, NOT a cursor: using them as one skips everything between what was shown and the end of the file. NOTE: if the command used shell redirection (>/>>/2>), the redirected output went to the file you named and BashOutput will not show it — Read that file directly.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "job_id", .type = "string", .description = "The id of the backgrounded Bash job to read" },
            .{ .name = "stdout", .type = "boolean", .description = "Include stdout (default true)" },
            .{ .name = "stderr", .type = "boolean", .description = "Include stderr (default true)" },
            .{ .name = "stdout_since_byte", .type = "integer", .description = "Read stdout starting at this byte offset" },
            .{ .name = "stderr_since_byte", .type = "integer", .description = "Read stderr starting at this byte offset" },
            .{ .name = "max_bytes", .type = "integer", .description = "Maximum bytes per selected channel (1..262144; default 65536)" },
        }, .required = &.{"job_id"} },
        .execute = .{ .legacy_inline = bash_output_tool.execute },
        .replay = .read_only,
    },
    .{
        .name = "ReadArtifact",
        .description = "Read a bounded byte range from a recoverable tool-result artifact. Use this whenever a tool result reports it was truncated and names an artifact_id — re-running the tool costs a full round-trip and still will not return the omitted bytes. offset is zero-based bytes; limit is capped at 32768 and may be reduced further to fit the context budget, in which case next_offset carries the remainder. The result is always bounded and never spills recursively.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "artifact_id", .type = "string", .description = "Content-addressed id in sha256:<64 lowercase hex> form" },
            .{ .name = "offset", .type = "integer", .description = "Zero-based byte offset (default 0)" },
            .{ .name = "limit", .type = "integer", .description = "Maximum bytes to return. Omit it to get as much as the context budget allows; an explicit value is capped at 32768 and may still be reduced to fit that budget. Either way next_offset carries whatever did not fit" },
        }, .required = &.{"artifact_id"} },
        .execute = .{ .legacy_inline = read_artifact_tool.execute },
        .replay = .read_only,
    },
    .{
        .name = "KillShell",
        .description = "Terminate a running backgrounded Bash job by job_id",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "job_id", .type = "string", .description = "The id of the backgrounded Bash job to terminate" },
        }, .required = &.{"job_id"} },
        .execute = .{ .legacy_inline = kill_shell_tool.execute },
    },
    .{
        .name = "Monitor",
        .description = "Start a background monitor that runs a command and streams stdout line-by-line. Use to watch logs, poll status, or react to file changes mid-conversation. Each stdout line is collected into a ring buffer readable via BashOutput(job_id). Stop with KillShell(job_id). Args: command (required), description (required, e.g. 'errors in /var/log/app.log'). Optional: persistent (default false; if true, no timeout).",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "command", .type = "string", .description = "Shell command to run; each stdout line becomes an event" },
            .{ .name = "description", .type = "string", .description = "Short description of what is being monitored" },
            .{ .name = "persistent", .type = "boolean", .description = "If true, run with no timeout for the session lifetime" },
        }, .required = &.{ "command", "description" } },
        .execute = .{ .legacy_inline = monitor_tool.execute },
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
        .execute = .{ .legacy_inline = notebook_edit_tool.execute },
        .result_production = .input_derived,
    },
    .{
        .name = "EnterWorktree",
        .description = "Enter an isolated git worktree. Pass `path` to switch into an existing worktree, OR pass `name` (and optional `base` branch) to create a new worktree under .metacodes/worktrees/<name>/. Changes the session's working directory. Returns {worktree, branch, entered, created}.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "name", .type = "string", .description = "Name for a new worktree to create" },
            .{ .name = "path", .type = "string", .description = "Path of an existing worktree to switch into" },
            .{ .name = "base", .type = "string", .description = "Base branch for a newly created worktree" },
        }, .required = &.{} },
        .execute = .{ .legacy_inline = worktree_tool.enterExecute },
    },
    .{
        .name = "ExitWorktree",
        .description = "Exit the current worktree and return to the original directory. Args: action='keep' (leaves worktree and branch intact) or 'remove' (also deletes the worktree). Optional discard_changes=true to force-remove even with uncommitted changes.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "action", .type = "string", .description = "keep leaves worktree intact; remove deletes it", .enum_values = &.{ "keep", "remove" } },
            .{ .name = "discard_changes", .type = "boolean", .description = "Force-remove even with uncommitted changes" },
        }, .required = &.{"action"} },
        .execute = .{ .legacy_inline = worktree_tool.exitExecute },
    },
    .{
        .name = "ListMcpResourcesTool",
        .description = "List resources exposed by all connected MCP servers. Optional server arg to filter to a single server. Returns aggregated list of {server, uri, name, description, mimeType}.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "server", .type = "string", .description = "Optional: filter to a single MCP server name" },
        }, .required = &.{} },
        .execute = .{ .result_body = mcp_resources_tool.listExecuteBody },
        .result_production = .byte_zero_spool,
    },
    .{
        .name = "ReadMcpResourceTool",
        .description = "Read a specific MCP resource by URI. Required: uri. Optional: server (hint for which connected server to query first; otherwise tries all). Returns the resource content as JSON.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "uri", .type = "string", .description = "The URI of the MCP resource to read" },
            .{ .name = "server", .type = "string", .description = "Optional: hint for which server to query first" },
        }, .required = &.{"uri"} },
        .execute = .{ .result_body = mcp_resources_tool.readExecuteBody },
        .result_production = .byte_zero_spool,
    },
    .{
        .name = "PushNotification",
        .description = "Send a desktop notification to pull the user's attention back to the session — e.g. a long task finished, or you need a decision before continuing. Use sparingly: only when there's a real chance the user stepped away. Keep message under 200 chars, one line. Args: message (required).",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "message", .type = "string", .description = "The notification body, under 200 chars, one line" },
        }, .required = &.{"message"} },
        .execute = .{ .legacy_inline = push_notification_tool.execute },
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
        .execute = .{ .legacy_inline = cron_tool.createExecute },
    },
    .{
        .name = "CronDelete",
        .description = "Cancel a scheduled cron job by id.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "id", .type = "string", .description = "The id of the cron job to cancel" },
        }, .required = &.{"id"} },
        .execute = .{ .legacy_inline = cron_tool.deleteExecute },
    },
    .{
        .name = "CronList",
        .description = "List all scheduled cron jobs in this session.",
        .input_schema = .{ .type = "object", .prop_specs = &.{}, .required = &.{} },
        .execute = .{ .legacy_inline = cron_tool.listExecute },
    },
    .{
        .name = "WebFetch",
        .description = "Fetch a URL and return its text content (HTML stripped). Use for reading web pages, API docs, articles.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "url", .type = "string", .description = "The URL to fetch content from" },
            .{ .name = "prompt", .type = "string", .description = "Optional note about what you're looking for (currently NOT applied server-side — the full page text is returned for you to analyze directly)." },
        }, .required = &.{"url"} },
        .execute = .{ .result_body = web_fetch_tool.executeBody },
        .result_production = .byte_zero_spool,
    },
    .{
        .name = "AskUserQuestion",
        .description = "Ask the user a multiple-choice question. This is a possibly-unavailable interactive channel; if it fails, continue with a sensible default and explain. Use only when a decision genuinely belongs to the user and cannot be inferred from the request, code, or a reasonable default.",
        .input_schema = .{
            .type = "object",
            .prop_specs = &.{
                .{
                    .name = "questions",
                    .type = "array",
                    .description = "List of questions to ask the user (1-9). Prefer multiSelect when the user can pick several options for one question, rather than splitting into many single-select questions.",
                    // 嵌套 schema:每个 question 是对象,options 又是 {label,description} 对象数组。
                    .items_props = &.{
                        .{ .name = "question", .type = "string", .description = "The complete question to ask. Clear, specific, ends with '?'." },
                        .{ .name = "header", .type = "string", .description = "Very short label/chip for the question (max 12 chars)." },
                        .{
                            .name = "options",
                            .type = "array",
                            .description = "The available choices (2-4). Each a distinct option object.",
                            .items_props = &.{
                                .{ .name = "label", .type = "string", .description = "Display text the user selects. Concise (1-5 words)." },
                                .{ .name = "description", .type = "string", .description = "Explanation of what this option means / its trade-offs." },
                                .{ .name = "preview", .type = "string", .description = "Optional ASCII/markdown mockup shown side-by-side when this option is focused (single-select only). Use for layouts/code/diagram comparisons." },
                            },
                            .items_required = &.{ "label", "description" },
                        },
                        .{ .name = "multiSelect", .type = "boolean", .description = "Allow selecting multiple options instead of one. Default false." },
                    },
                    .items_required = &.{ "question", "header", "options" },
                },
            },
            .required = &.{"questions"},
        },
        .execute = .{ .legacy_inline = ask_user_tool.execute },
    },
    .{
        .name = "EnterPlanMode",
        .description = "Enter plan mode to research and design before implementing. Use this tool PROACTIVELY at the start of any non-trivial task — new features, multi-file changes, refactors, architectural decisions, anything with multiple valid approaches, or when the user asks for a plan/design. In plan mode only read-only tools (Read/Grep/Glob) are allowed; write/exec are denied, so you investigate first, then call ExitPlanMode with your plan for the user to approve. Skip it only for trivial one-line fixes or pure questions. When in doubt, prefer entering plan mode — getting sign-off before writing code prevents wasted work.",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{} },
        .execute = .{ .legacy_inline = plan_mode_tool.executeEnter },
    },
    .{
        .name = "ExitPlanMode",
        .description = "Present your plan and request approval to exit plan mode. Shows the plan to the user in an approval dialog: they choose to proceed (restores execution mode), proceed with auto-accept edits, or keep planning. Only call this once you have a complete plan. Pass the plan as markdown in the `plan` field so the user can review it. If rejected, keep refining and call again.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "plan", .type = "string", .description = "The plan to present to the user for approval, as concise markdown." },
        }, .required = &.{} },
        .execute = .{ .legacy_inline = plan_mode_tool.executeExit },
    },
    .{
        .name = "KgRemember",
        .description = "Persist a durable memory into the knowledge graph (survives across sessions). Use for SHORT ATOMIC facts: decisions made, user preferences/corrections, non-obvious project facts. Keep it short and structured; do NOT log transient task state. For long-form narrative use a memory markdown file instead (auto-imported into the same graph) — never store the same content both ways. Memories written while a task is in_progress are automatically linked to that task (provenance). The type taxonomy is a living ontology: as your understanding of the project deepens, prefer recording sharper type-specific facts over piling generic observations.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "text", .type = "string", .description = "The fact to remember. Short, self-contained; include Why when it is a correction or decision." },
            .{ .name = "kind", .type = "string", .description = "Memory type: decision | user_preference | module (a code module/component's responsibility or structure) | bug (a defect / wrong behavior) | observation (default, use only when none of the specific types fit). PREFER a specific type over observation — specific types make the memory retrievable by type." },
            .{ .name = "scope", .type = "string", .description = "project (default) | global — global only for cross-project user preferences" },
        }, .required = &.{"text"} },
        .execute = .{ .legacy_inline = kg_tools.executeRemember },
        .tinykg_gated = true,
    },
    .{
        .name = "KgRecall",
        .description = kg_retrieval.TOOL_DESCRIPTION,
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "query", .type = "string", .description = kg_retrieval.QUERY_DESCRIPTION },
            .{ .name = "type", .type = "string", .description = kg_retrieval.TYPE_DESCRIPTION },
            .{
                .name = "lexical_plan",
                .type = "object",
                .description = kg_retrieval.PLAN_DESCRIPTION,
                .object_props = &.{
                    .{ .name = "schema_version", .type = "string", .enum_values = &.{"lexical-query-plan-v3"} },
                    .{ .name = "intent", .type = "string", .description = "Use enumeration for count/cardinality, exhaustive-list, all/every-match, or absence questions; one positive hit is not complete coverage.", .enum_values = &.{ "fact_lookup", "procedure_reuse", "task_recovery", "enumeration", "temporal", "causal", "entity", "other" } },
                    .{ .name = "stage", .type = "string", .enum_values = &.{ "seed", "semantic_expansion", "focused_refinement" } },
                    .{
                        .name = "variants",
                        .type = "array",
                        .items_props = &.{
                            .{ .name = "kind", .type = "string", .enum_values = &.{ "exact", "alias", "synonym", "paraphrase", "mechanism", "symptom", "outcome", "broader", "narrower", "relation", "type", "time" } },
                            .{ .name = "text", .type = "string", .description = "One compact lexical probe, 1-400 UTF-8 bytes." },
                        },
                        .items_required = &.{ "kind", "text" },
                    },
                },
                .object_required = &.{ "schema_version", "intent", "stage", "variants" },
            },
        }, .required = &.{ "query", "lexical_plan" } },
        .execute = .{ .legacy_inline = kg_tools.executeRecall },
        .tinykg_gated = true,
    },
    .{
        .name = "KgContext",
        .description = kg_retrieval.CONTEXT_DESCRIPTION,
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "node_id", .type = "integer", .description = "Candidate node_id returned by KgRecall or a prior KgContext graph." },
            .{ .name = "limit", .type = "integer", .description = "Bounded neighboring-edge limit, 1-20 (default 12); the graph also includes the root node." },
            .{ .name = "text_offset", .type = "integer", .description = "Byte offset for paging long authoritative node text (default 0; use next_text_offset)." },
            .{ .name = "text_limit", .type = "integer", .description = "Maximum authoritative text bytes for this page, 4-12000 (default 6000; minimum fits one UTF-8 codepoint)." },
        }, .required = &.{"node_id"} },
        .execute = .{ .legacy_inline = kg_tools.executeContext },
        .tinykg_gated = true,
    },
    .{
        .name = "FormalAuditTask",
        .description = "Run a read-only, machine-checked audit of one bounded TinyKG task subgraph. Zig validates and hashes the real snapshot, invokes the deployment-pinned precompiled Lean kernel, verifies every verdict binding, and persists an engineering receipt. This does not mutate the graph and does not claim that reobserve/CAS/rollback are implemented. The checker path and SHA-256 are host configuration, never model arguments.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "root_task_id", .type = "integer", .description = "TinyKG root task id whose bounded task subgraph will be audited" },
        }, .required = &.{"root_task_id"} },
        .execute = .{ .legacy_inline = formal_task_audit.execute },
        .deferred = true,
        .tinykg_gated = true,
    },
    .{
        .name = "TaskCreate",
        .description = "Create a task in the in-session task list. Returns the new task id. Use for multi-step work you want to track across turns.",
        .describe_fn = descriptions.describeTaskCreate,
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "subject", .type = "string", .description = "A brief title for the task" },
            .{ .name = "description", .type = "string", .description = "What needs to be done" },
            .{ .name = "activeForm", .type = "string", .description = "Present-continuous form shown while in progress (e.g. 'Running tests')" },
        }, .required = &.{ "subject", "description" } },
        .execute = .{ .legacy_inline = task_tools.executeCreate },
    },
    .{
        .name = "TaskGet",
        .description = "Fetch a task by id. For persistent kg-* tasks this also returns a bounded TinyKG task_packet with parent objective, dependencies, evidence, truncation diagnostics and continuations. Call it after restart/compaction or whenever claim could not return a packet; do not work from the title alone.",
        .describe_fn = descriptions.describeTaskGet,
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "taskId", .type = "string", .description = "The id of the task to fetch" },
        }, .required = &.{"taskId"} },
        .execute = .{ .legacy_inline = task_tools.executeGet },
    },
    .{
        .name = "TaskList",
        .description = "List the live task frontier. For kg-* tasks select only an open, ready, unclaimed leaf; then claim it with TaskUpdate status=in_progress before work. This is a summary/projection, so use TaskGet/task_packet for full recovery context.",
        .describe_fn = descriptions.describeTaskList,
        .input_schema = .{ .type = "object", .prop_specs = &.{}, .required = &.{} },
        .execute = .{ .legacy_inline = task_tools.executeList },
    },
    .{
        .name = "TaskUpdate",
        .description = "Update a task's status (pending/in_progress/completed/failed/deleted) and/or fields. For persistent kg-* tasks: claim with in_progress before work (the successful response contains the bounded task_packet); completed/failed are terminal while preserving the stable id; deleted is only a compatibility alias for failed. Close every claimed task with a verified conclusion and actual acts_on/uses/produces when known, then inspect the returned frontier.",
        .describe_fn = descriptions.describeTaskUpdate,
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "taskId", .type = "string", .description = "The id of the task to update" },
            .{ .name = "status", .type = "string", .description = "New status; failed is for persistent KG tasks", .enum_values = &.{ "pending", "in_progress", "completed", "failed", "deleted" } },
            .{ .name = "subject", .type = "string", .description = "New subject (title)" },
            .{ .name = "description", .type = "string", .description = "New description" },
            .{ .name = "activeForm", .type = "string", .description = "New present-continuous form" },
            .{ .name = "owner", .type = "string", .description = "New owner (agent name)" },
            .{ .name = "addBlocks", .type = "array", .description = "Task ids that this task blocks", .items_type = "string" },
            .{ .name = "addBlockedBy", .type = "array", .description = "Task ids that block this task", .items_type = "string" },
            .{ .name = "conclusion", .type = "string", .description = "On completion: one-line summary of what this task accomplished (used as closure evidence)." },
            .{ .name = "acts_on", .type = "array", .description = "On completion: objects/files/modules this task actually acted on (KG projection).", .items_type = "string" },
            .{ .name = "uses", .type = "array", .description = "On completion: methods/concepts/tools this task actually used (KG projection).", .items_type = "string" },
            .{ .name = "produces", .type = "array", .description = "On completion: artifacts/outputs this task produced (KG projection).", .items_type = "string" },
        }, .required = &.{"taskId"} },
        .execute = .{ .legacy_inline = task_tools.executeUpdate },
    },
    .{
        .name = "TaskStop",
        .description = "Stop a task by id. For a backgrounded agent job (agent_* id, or agent_job_id arg), requests termination of the running subagent. For a todo task id, marks it completed (shortcut for TaskUpdate status=completed).",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "taskId", .type = "string", .description = "The task id (todo id or agent_* job id) to stop" },
            .{ .name = "agent_job_id", .type = "string", .description = "Alternative: the backgrounded agent job id to terminate" },
        }, .required = &.{"taskId"} },
        .execute = .{ .legacy_inline = task_tools.executeStop },
    },
    .{
        .name = "TaskOutput",
        .description = "Wait for a backgrounded Task subagent by agent_job_id. Omit since_byte to wait up to 30 seconds for terminal status; pass since_byte = previous output_total_bytes to wait for incremental output instead. When done, returns final_text + stop_reason. Args: agent_job_id (required), since_byte, max_bytes (optional).",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "agent_job_id", .type = "string", .description = "The backgrounded agent job id to read" },
            .{ .name = "since_byte", .type = "integer", .description = "Byte offset to poll from (previous output_total_bytes)" },
            .{ .name = "max_bytes", .type = "integer", .description = "Max bytes to return this call (1..262144)" },
        }, .required = &.{"agent_job_id"} },
        .execute = .{ .legacy_inline = task_output_tool.execute },
    },
    .{
        .name = "Task",
        .description = "Launch a subagent in an isolated context to handle a side task. Each subagent starts with a fresh context — it cannot see this conversation, only the prompt you pass. Use for: high-volume operations (running tests, processing logs), parallel research, isolating exploration that would flood your context. Args: subagent_type (Explore/Plan/general-purpose/<custom>), description (3-5 word UI label), prompt (the delegation message). Optional: max_turns, model, run_in_background (true returns an agent_job_id immediately; poll with TaskOutput, stop with TaskStop).",
        .describe_fn = descriptions.describeTask,
        // 工具 name 必须保持 "Task"——这是模型 SFT 训练时学到的工具标识符,改名会降低
        // 模型识别/调用可靠性。用户看到的 "subagent" 概念在 UI 层(tool_card 预览)体现,
        // 不动工具 name。
        // schema required 只列**真正必需**的:subagent_type 缺省 general-purpose、
        // description 只是 UI 标签 → 都不是硬必需(agent.zig 有默认)。只有 prompt 缺会真失败。
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "prompt", .type = "string", .description = "The task/delegation message for the subagent" },
            .{ .name = "subagent_type", .type = "string", .description = "Agent type (Explore/Plan/general-purpose/custom); defaults to general-purpose" },
            .{ .name = "description", .type = "string", .description = "3-5 word UI label for the task" },
            .{ .name = "max_turns", .type = "integer", .description = "Max agent loop turns" },
            .{ .name = "model", .type = "string", .description = "Model override for the subagent" },
            .{ .name = "run_in_background", .type = "boolean", .description = "Run async; returns agent_job_id immediately" },
            .{ .name = "name", .type = "string", .description = "Spawn a persistent teammate with this name (requires an active team via TeamCreate) instead of a one-shot subagent. The teammate joins the team, works, then idles waiting for SendMessage." },
        }, .required = &.{"prompt"} },
        .execute = .{ .legacy_inline = agent_tool.execute },
    },
    .{
        .name = "TaskBatch",
        .description = "Fan out a batch of subagents in parallel: one subagent per item, each running the same prompt template with the item's fields substituted. Use `{field}` placeholders in prompt_template (e.g. \"Review the file {path} for {concern}\") and pass items as an array of objects. Prefer this over emitting many individual Task calls when running the SAME task over a list of inputs — it guarantees parallel fan-out, avoids repeating the prompt, and returns aggregated results. Runs up to 8 concurrently; max 32 items. Results are returned inline (not persisted); for long-running detached work use Task with run_in_background.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "prompt_template", .type = "string", .description = "Prompt with {field} placeholders substituted per item. {{ }} are literal braces." },
            .{ .name = "items", .type = "array", .description = "Array of objects; each spawns one subagent with the template filled from its fields." },
            .{ .name = "subagent_type", .type = "string", .description = "Agent type for all items (Explore/Plan/general-purpose/custom); defaults to general-purpose" },
            .{ .name = "max_turns", .type = "integer", .description = "Max agent loop turns per subagent (default 20)" },
        }, .required = &.{ "prompt_template", "items" } },
        .execute = .{ .legacy_inline = task_batch_tool.execute },
    },
    .{
        // 兼容别名:某些上下文可能用 "Agent"。路由到同一 execute。主工具 name 是 "Task"
        // (SFT 锚点)。
        .name = "Agent",
        .description = "Alias for Task. Use Task with subagent_type instead. Routes to Task (subagent_type defaults to general-purpose).",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "prompt", .type = "string", .description = "The task/delegation message for the subagent" },
            .{ .name = "subagent_type", .type = "string", .description = "Agent type; defaults to general-purpose" },
            .{ .name = "description", .type = "string", .description = "3-5 word UI label for the task" },
        }, .required = &.{"prompt"} },
        .execute = .{ .legacy_inline = agent_tool.execute },
    },
    // ToolSearch:静态 registry 常驻，但 toToolDefinitionsFull 仅在确有 deferred 工具时
    // 广告。模型按 query 检索完整 schema 并激活，下一轮该 deferred 工具才进入 tools。
    .{
        .name = "ToolSearch",
        .description = "Fetches schemas only for deferred tools whose names appear under # Deferred tools. NEVER call ToolSearch for a tool whose full schema is already present in the current tools list (including KgRecall); call that tool directly. Pass keywords to find a deferred tool, or `select:<deferred_tool_name>` to fetch a listed deferred tool by exact name. Returns matched deferred schemas; once returned, each is callable like a core tool.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "query", .type = "string", .description = "Keywords to find deferred tools, or `select:<deferred_tool_name>` for an exact name listed under # Deferred tools. Do not select an already-visible core tool." },
            .{ .name = "max_results", .type = "integer", .description = "Maximum number of results to return (default 5)" },
        }, .required = &.{"query"} },
        .execute = .{ .legacy_inline = tool_search_tool.execute },
    },
    // WebSearch:普通函数工具(对齐 mecode)。execute 在隔离子请求里用 server tool 真搜,
    // 主请求只暴露此规整 schema——避免 server-tool 异形毒化后端。deferred(按需激活)。
    .{
        .name = "WebSearch",
        .description = "Searches the web and returns matching results. allowed_domains narrows the search scope; blocked_domains filters final returned results.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "query", .type = "string", .description = "The search query to use." },
            .{ .name = "allowed_domains", .type = "array", .description = "Restrict search results to these domains." },
            .{ .name = "blocked_domains", .type = "array", .description = "Exclude these domains from final returned results." },
        }, .required = &.{"query"} },
        .execute = .{ .legacy_inline = web_search_tool.execute },
        .display_name = "Web Search",
    },
    // ── Swarm(teams/teammates)。仅在 swarm-enabled(TUI lead)上下文注册;subagent/headless
    //    的 ToolContext.swarm=null → execute 返 SwarmUnavailable。deferred=false(lead 常驻)。
    .{
        .name = "TeamCreate",
        .description = "Create a team so you can delegate work to teammate agents that run in parallel and coordinate through a shared task list and mailbox. You become the team lead (not a teammate). One team per lead. After creating a team, spawn a teammate by calling the Task tool with a `name` argument (the team is implicit — one team per lead), then talk to teammates with SendMessage. Args: name (team name), description (optional).",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "name", .type = "string", .description = "Team name" },
            .{ .name = "description", .type = "string", .description = "Optional team description" },
        }, .required = &.{"name"} },
        .execute = .{ .legacy_inline = swarm_tools.executeTeamCreate },
        .swarm_gated = true,
    },
    .{
        .name = "TeamDelete",
        .description = "Delete the current team and clean up its directory. Refuses while any teammate is still active — shut teammates down first (SendMessage a shutdown request and wait for approval). Takes no arguments.",
        .input_schema = .{ .type = "object", .prop_specs = &.{}, .required = &.{} },
        .execute = .{ .legacy_inline = swarm_tools.executeTeamDelete },
        .swarm_gated = true,
    },
    .{
        .name = "SendMessage",
        .description = "Send a message to a teammate (or the team lead). Plain prose is delivered to the recipient's mailbox and injected into their turn. Args: to (teammate name, or \"*\" to broadcast to all teammates), message (the text), summary (optional 5-10 word preview). Your plain assistant text is NOT visible to teammates — you MUST use this tool to communicate with them.",
        .input_schema = .{ .type = "object", .prop_specs = &.{
            .{ .name = "to", .type = "string", .description = "Recipient teammate name, or \"*\" to broadcast" },
            .{ .name = "message", .type = "string", .description = "The message text" },
            .{ .name = "summary", .type = "string", .description = "Optional 5-10 word preview shown in the UI" },
        }, .required = &.{ "to", "message" } },
        .execute = .{ .legacy_inline = swarm_tools.executeSendMessage },
        .swarm_gated = true,
    },
};

comptime {
    for (registry) |tool| {
        if (tool.result_production == .byte_zero_spool) switch (tool.execute) {
            .result_body => {},
            .legacy_inline => @compileError("byte-zero native tool must use ToolExecutor.result_body: " ++ tool.name),
        };
    }
}

/// 用户可见名(对齐 cc userFacingName):TUI 工具卡标题用。查 registry display_name,
/// 无则回退原名。tool_card / 底部 spinner 用它显示 `⏺ Web Search` 而非 `WebSearch`。
pub fn displayName(name: []const u8) []const u8 {
    if (getTool(name)) |t| {
        if (t.display_name) |d| return d;
    }
    return name;
}

pub fn getTool(name: []const u8) ?*const ToolEntry {
    for (registry) |*tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

/// 把单个工具序列化为 schema JSON(`{"name","description","input_schema":{...}}`)。
/// ToolSearch 用它把命中的 deferred 工具 schema 喂给模型。describe_fn 需 PromptContext,
/// ToolSearch 处无之 → 用静态 description(足够模型理解参数)。caller free。
pub fn toolSchemaJson(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const t = getTool(name) orelse return error.UnknownTool;
    const def = json.ToolDefinition{
        .name = t.name,
        .description = t.description,
        .input_schema = .{
            .type = t.input_schema.type,
            .prop_specs = t.input_schema.prop_specs,
            .properties = null,
            .required = t.input_schema.required,
        },
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try @import("api/request.zig").serializeOneTool(def, &buf, allocator);
    return try buf.toOwnedSlice(allocator);
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

/// 查工具描述的 env override(slot "TOOL_DESC_<UPPER_NAME>")。命中返回 owned slice
/// (挂 allocator,同其它描述),否则 null。用于提示词 A/B:同一二进制热切工具描述。
fn overrideToolDesc(allocator: std.mem.Allocator, tool_name: []const u8) ?[]u8 {
    const prefix = "TOOL_DESC_";
    var slot_buf: [prefix.len + 64]u8 = undefined;
    if (tool_name.len > slot_buf.len - prefix.len) return null;
    @memcpy(slot_buf[0..prefix.len], prefix);
    for (tool_name, 0..) |c, i| slot_buf[prefix.len + i] = std.ascii.toUpper(c);
    const slot = slot_buf[0 .. prefix.len + tool_name.len];
    return @import("core/prompt_override.zig").lookup(allocator, slot);
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

    // Swarm 工具门控(F5):未开 --agent-teams 时不广告 TeamCreate/TeamDelete/SendMessage。
    const teams_on = if (prompt_ctx) |pc| pc.agent_teams else false;
    const tinykg_on = if (prompt_ctx) |pc| pc.tinykg_enabled else true;
    // ToolSearch 是 deferred 工具的发现/激活入口。没有任何 deferred 工具时仍广告它，
    // 会诱导模型对已经带完整 schema 的常驻工具做 select:Write/KgRecall，徒增一轮。
    // 静态内置当前全常驻；MCP 动态工具 deferred=true。未来若静态工具重新 deferred，
    // 此门会自动把 ToolSearch 放回。
    var has_deferred = false;
    for (registry) |tool| {
        if (tool.swarm_gated and !teams_on) continue;
        if (tool.tinykg_gated and !tinykg_on) continue;
        if (tool.deferred) {
            has_deferred = true;
            break;
        }
    }
    if (!has_deferred) {
        if (dyn) |d| {
            for (d.entries.items) |entry| {
                if (entry.deferred) {
                    has_deferred = true;
                    break;
                }
            }
        }
    }

    for (registry) |*tool| {
        if (tool.swarm_gated and !teams_on) continue;
        if (tool.tinykg_gated and !tinykg_on) continue;
        if (std.mem.eql(u8, tool.name, "ToolSearch") and !has_deferred) continue;
        const desc: []const u8 = blk: {
            // env override(slot "TOOL_DESC_<UPPER_NAME>")优先于 describe_fn / 静态描述。
            // 用于提示词 A/B 实验:同一二进制按 env 切换工具描述,无需重编译。
            if (overrideToolDesc(allocator, tool.name)) |ov| break :blk ov;
            if (prompt_ctx) |pc| {
                if (tool.describe_fn) |df| break :blk try df(allocator, pc);
            }
            break :blk tool.description;
        };
        const prop_specs = if (!tinykg_on and std.mem.eql(u8, tool.name, "TaskUpdate"))
            SESSION_TASK_UPDATE_PROPS
        else
            tool.input_schema.prop_specs;
        try defs.append(allocator, .{
            .name = tool.name,
            .description = desc,
            .input_schema = .{
                .type = tool.input_schema.type,
                // 透传 comptime prop_specs（内置工具字段定义）。早先这里硬编码 null，
                // 把 registry 声明的 schema 全抹掉 → 模型只收到空 properties，触发
                // 空参/漏参风暴（TaskCreate MissingRequiredField 即此根因）。
                .prop_specs = prop_specs,
                .properties = null,
                .required = tool.input_schema.required,
            },
            .deferred = tool.deferred,
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

    // 注:不再发 Anthropic server-tool 形态的 web_search(异形对象毒化弱后端 function-calling,
    // 二分实证为根因)。WebSearch 改为普通函数工具(对齐 mecode),见 registry 里的 "WebSearch"
    // 条目;其 execute 在隔离子请求里用 server tool 真搜,主请求只暴露规整 schema。

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
            if (std.mem.eql(u8, d.name, "TaskUpdate")) {
                d.input_schema.prop_specs = if (prompt_ctx.tinykg_enabled)
                    t.input_schema.prop_specs
                else
                    SESSION_TASK_UPDATE_PROPS;
            }
            if (t.describe_fn) |df| {
                d.description = try df(allocator, prompt_ctx);
            }
        }
    }
}

pub fn executeTool(tool: *const ToolEntry, ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    var body = try tool.execute.run(ctx, args);
    errdefer body.deinit(ctx.allocator);
    return (try body.takeModelBytes(ctx.allocator)).bytes;
}

/// Schema 层校验(对齐 cc 的 zod safeParse 层):执行前检查 input JSON 含所有 required
/// 字段。缺则返回字段具名错误(agent_loop 转 invalid_args 现场给模型)。
/// 这是工具自身 MissingX 检查之外的统一前置层——uniform + 在 dispatch 前拦,且对没写
/// 自检的工具也兜底。检查用顶层 "field": 子串(与 extractJsonArg 同口径,够分辨缺失)。
pub fn validateRequired(name: []const u8, args: []const u8) anyerror!void {
    const t = getTool(name) orelse return; // 动态工具(MCP/Skill)走自己的校验
    const required = t.input_schema.required orelse return;
    for (required) |field| {
        var pat_buf: [128]u8 = undefined;
        if (field.len + 3 > pat_buf.len) continue;
        // 匹配 "field": (顶层键)。简化:子串匹配(args 是工具入参 JSON,误报概率极低)。
        const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\"", .{field}) catch continue;
        if (std.mem.indexOf(u8, args, pat) == null) return missingRequiredFieldError(field);
    }
}

/// 把高频 schema 字段映射成稳定、可行动的错误码。无法枚举的动态字段仍用
/// MissingRequiredField 兜底；不要为了“更具体”拼运行时 error 名（Zig error set 是静态的）。
fn missingRequiredFieldError(field: []const u8) anyerror {
    if (std.mem.eql(u8, field, "file_path")) return error.MissingFilePath;
    if (std.mem.eql(u8, field, "path")) return error.MissingPath;
    if (std.mem.eql(u8, field, "command")) return error.MissingCommand;
    if (std.mem.eql(u8, field, "pattern")) return error.MissingPattern;
    if (std.mem.eql(u8, field, "content")) return error.MissingContent;
    if (std.mem.eql(u8, field, "old_string")) return error.MissingOldString;
    if (std.mem.eql(u8, field, "new_string")) return error.MissingNewString;
    if (std.mem.eql(u8, field, "prompt")) return error.MissingPrompt;
    if (std.mem.eql(u8, field, "prompt_template")) return error.MissingPromptTemplate;
    if (std.mem.eql(u8, field, "subject")) return error.MissingSubject;
    if (std.mem.eql(u8, field, "description")) return error.MissingDescription;
    if (std.mem.eql(u8, field, "taskId")) return error.MissingTaskId;
    if (std.mem.eql(u8, field, "agent_job_id")) return error.MissingAgentJobId;
    if (std.mem.eql(u8, field, "query")) return error.MissingQuery;
    if (std.mem.eql(u8, field, "url")) return error.MissingUrl;
    if (std.mem.eql(u8, field, "items")) return error.MissingItems;
    if (std.mem.eql(u8, field, "artifact_id")) return error.MissingArtifactId;
    return error.MissingRequiredField;
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
/// 找不到时先做 P0.6 弱模型工具名修复(归一化 + 模糊匹配),命中则改派到真工具;仍找不到
/// 返 error.UnknownTool —— 由 agent_loop 转 tool_error 给模型。
pub fn dispatch(ctx: *const ToolContext, name: []const u8, args: []const u8) anyerror!ToolDispatchOutcome {
    // Defense in depth: agent_loop/tool_exec normally checks this first, but
    // dispatch is also a public L2 seam and dynamic tools can be called through
    // it directly.  Never let a guessed name bypass a child execution ceiling.
    if (ctx.execution_policy) |policy| {
        if (!policy.allowsInvocation(name, args)) return error.ToolPolicyDenied;
    }
    // An embedding Session's immutable directory is an authority boundary, not
    // a lookup hint. Do not fall through to the process-wide registry on miss.
    if (ctx.tool_dispatcher) |dispatcher| return dispatcher.dispatch(ctx, name, args);
    if (getTool(name)) |t| {
        try validateRequired(name, args); // schema 层:缺 required 字段 → 早拦
        try validateTypes(name, args); // schema 层:字段类型不匹配 → 早拦
        return .{ .ok = try t.execute.run(ctx, args) };
    }
    if (ctx.dyn_registry) |dr| {
        if (dr.find(name)) |de| return .{ .ok = try de.execute(ctx, args) };
    }
    // P0.6:弱模型幻觉工具名修复。**只**用确定性无损归一化(大小写/`-`/空格/CamelCase→snake/剥
    // `_tool` 尾缀)自动改派——这些是安全的等价变换。**不**用模糊编辑距离自动执行(那会把 "Wrote"
    // 静默路由到 Write 真跑,用更坏的错误替换诚实的 UnknownTool)。模糊匹配只在错误里当"你是不是
    // 想调 X?"的建议(见 tool_exec.zig 的 suggestToolName),由模型确认后自纠。
    if (resolveToolNameExact(ctx, name)) |repaired| {
        if (!std.mem.eql(u8, repaired, name)) {
            @import("util/log.zig").warn("tool", "工具名归一化: '{s}' → '{s}'", .{ name, repaired });
            if (getTool(repaired)) |t| {
                try validateRequired(repaired, args);
                try validateTypes(repaired, args);
                return .{ .ok = try t.execute.run(ctx, args) };
            }
            if (ctx.dyn_registry) |dr| {
                if (dr.find(repaired)) |de| return .{ .ok = try de.execute(ctx, args) };
            }
        }
    }
    return error.UnknownTool;
}

/// Execute the only native operation allowed by an `admit_exact_edit` gate
/// result.  An embedding Session may implement a tool named Edit with
/// arbitrary semantics, so recovery cannot silently delegate to it.  Such a
/// Session fails closed and retains the outstanding recovery obligation.
pub fn dispatchProjectExactEdit(
    ctx: *const ToolContext,
    args: []const u8,
) anyerror!ToolDispatchOutcome {
    if (ctx.project_edit_mode != .whole_file_exact)
        return error.ProjectExactEditNotAuthorized;
    if (ctx.execution_policy) |policy| {
        if (!policy.allowsInvocation("Edit", args))
            return error.ToolPolicyDenied;
    }
    if (ctx.tool_dispatcher != null)
        return error.ProjectExactEditNativeUnavailable;
    try validateRequired("Edit", args);
    try validateTypes("Edit", args);
    return .{ .ok = ToolResultBody.initInline(try edit_tool.execute(ctx, args)) };
}

/// 逗号分隔的所有真实工具名(静态 + dyn),供 UnknownTool 错误引导模型。caller free。
pub fn availableToolNames(ctx: *const ToolContext, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var it = ToolNameIter.init(ctx);
    var first = true;
    while (it.next()) |nm| {
        if (!first) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, nm);
        first = false;
    }
    return out.toOwnedSlice(allocator);
}

/// 确定性工具名归一化解析:把大小写/分隔符/CamelCase/`_tool` 尾缀走样的名字解析回真工具名。
/// **只做无损等价变换**——归一化后精确相等才算命中,绝不做模糊猜测(那是 suggestToolName 的活)。
/// 返回借用的真工具名(dispatch 作用域内有效),无精确匹配 → null。安全到可以自动改派执行。
pub fn resolveToolNameExact(ctx: *const ToolContext, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    var buf: [128]u8 = undefined;
    const norm = normalizeToolName(&buf, name) orelse return null;
    var it = ToolNameIter.init(ctx);
    while (it.next()) |real| {
        var rbuf: [128]u8 = undefined;
        if (normalizeToolName(&rbuf, real)) |rnorm| {
            if (std.mem.eql(u8, norm, rnorm) or normEqualsStripTool(norm, rnorm)) return real;
        }
    }
    return null;
}

/// 模糊建议:归一化解析不中时,用编辑距离相似度(≥0.7,对齐 hermes difflib cutoff)找最接近的真
/// 工具名——**仅供 UnknownTool 错误的"你是不是想调 X?"提示**,绝不自动执行(防把 "Wrote" 静默
/// 路由到 Write 真跑)。返回借用真工具名或 null。
pub fn suggestToolName(ctx: *const ToolContext, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    var best: ?[]const u8 = null;
    var best_score: f32 = 0.7;
    var it = ToolNameIter.init(ctx);
    while (it.next()) |real| {
        const score = similarity(name, real);
        if (score > best_score) {
            best_score = score;
            best = real;
        }
    }
    return best;
}

/// 归一化:小写 + `-`/空格→`_` + CamelCase 边界插 `_`。写入 buf,返回 slice;超长返 null。
fn normalizeToolName(buf: []u8, name: []const u8) ?[]const u8 {
    var n: usize = 0;
    for (name, 0..) |c, i| {
        if (c >= 'A' and c <= 'Z') {
            // CamelCase 边界 = **lower→Upper** 或 **digit→Upper** 过渡才插 `_`(用原文前一字符判定)。
            // 连续大写(缩写 "READ"/"HTML")不插——否则 "READ"→"r_e_a_d" 匹配不上 "read"。
            const prev = if (i > 0) name[i - 1] else 0;
            const boundary = (prev >= 'a' and prev <= 'z') or (prev >= '0' and prev <= '9');
            if (boundary and n > 0 and buf[n - 1] != '_') {
                if (n >= buf.len) return null;
                buf[n] = '_';
                n += 1;
            }
            if (n >= buf.len) return null;
            buf[n] = c - 'A' + 'a';
            n += 1;
        } else if (c == '-' or c == ' ') {
            if (n >= buf.len) return null;
            buf[n] = '_';
            n += 1;
        } else {
            if (n >= buf.len) return null;
            buf[n] = c;
            n += 1;
        }
    }
    return buf[0..n];
}

/// 剥掉 `_tool` 尾缀(≤2 次)后比较是否相等(a 或 b 任一剥后等于另一)。
fn normEqualsStripTool(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, stripToolSuffix(a), stripToolSuffix(b));
}

fn stripToolSuffix(s: []const u8) []const u8 {
    var cur = s;
    var rounds: u8 = 0;
    while (rounds < 2) : (rounds += 1) {
        if (std.mem.endsWith(u8, cur, "_tool")) {
            cur = cur[0 .. cur.len - 5];
        } else if (std.mem.endsWith(u8, cur, "tool") and cur.len > 4) {
            cur = cur[0 .. cur.len - 4];
        } else break;
    }
    return cur;
}

/// 遍历所有真实工具名(静态 registry + dyn_registry)。
const ToolNameIter = struct {
    ctx: *const ToolContext,
    static_idx: usize = 0,
    dyn_idx: usize = 0,

    fn init(ctx: *const ToolContext) ToolNameIter {
        return .{ .ctx = ctx };
    }
    fn next(self: *ToolNameIter) ?[]const u8 {
        if (self.ctx.tool_dispatcher) |dispatcher| {
            while (dispatcher.nameAt(self.static_idx)) |name| {
                self.static_idx += 1;
                if (self.ctx.execution_policy) |policy| {
                    if (!policy.allowsTool(name)) continue;
                }
                return name;
            }
            return null;
        }
        while (self.static_idx < registry.len) {
            const nm = registry[self.static_idx].name;
            self.static_idx += 1;
            if (self.ctx.execution_policy) |policy| {
                if (!policy.allowsTool(nm)) continue;
            }
            return nm;
        }
        if (self.ctx.dyn_registry) |dr| {
            while (self.dyn_idx < dr.entries.items.len) {
                const nm = dr.entries.items[self.dyn_idx].name;
                self.dyn_idx += 1;
                if (self.ctx.execution_policy) |policy| {
                    if (!policy.allowsTool(nm)) continue;
                }
                return nm;
            }
        }
        return null;
    }
};

/// 大小写无关的相似度 [0,1]:1 - 归一化 Levenshtein 距离。对短工具名足够(hermes 用 difflib
/// SequenceMatcher,量级近似)。用栈上定长 DP 行(工具名 < 64)。
fn similarity(a: []const u8, b: []const u8) f32 {
    var abuf: [64]u8 = undefined;
    var bbuf: [64]u8 = undefined;
    if (a.len >= abuf.len or b.len >= bbuf.len) return 0;
    for (a, 0..) |c, i| abuf[i] = std.ascii.toLower(c);
    for (b, 0..) |c, i| bbuf[i] = std.ascii.toLower(c);
    const la = a.len;
    const lb = b.len;
    if (la == 0 and lb == 0) return 1;
    var prev: [65]usize = undefined;
    var curr: [65]usize = undefined;
    var j: usize = 0;
    while (j <= lb) : (j += 1) prev[j] = j;
    var i: usize = 1;
    while (i <= la) : (i += 1) {
        curr[0] = i;
        j = 1;
        while (j <= lb) : (j += 1) {
            const cost: usize = if (abuf[i - 1] == bbuf[j - 1]) 0 else 1;
            const del = prev[j] + 1;
            const ins = curr[j - 1] + 1;
            const sub = prev[j - 1] + cost;
            curr[j] = @min(del, @min(ins, sub));
        }
        @memcpy(prev[0 .. lb + 1], curr[0 .. lb + 1]);
    }
    const dist: f32 = @floatFromInt(prev[lb]);
    const maxlen: f32 = @floatFromInt(@max(la, lb));
    return 1.0 - dist / maxlen;
}

/// 工具是否可与同批工具并发执行(对齐 cc isConcurrencySafe)。
/// 安全 = 只读 + 不写任何共享态(或写的共享态已线程安全)。
///   Read(read_state 已加锁)/Glob/Grep/WebFetch/BashOutput → safe。
///   WebSearch 的静态分类仍保守为 unsafe；tool_exec 只有在 ToolContext 提供 per-call
///   provider factory 时才动态升级为 safe，并由专用 admission gate 限制并发为 2。
///   Write/Edit/Bash/Task*/NotebookEdit/MCP/Skill 等有副作用或写共享态 → unsafe。
/// 一期按工具名判定(cc 是 per-input;cc-zig 工具名足够,Bash 即便 readonly 也保守串行)。
pub fn isConcurrencySafe(name: []const u8) bool {
    const safe = [_][]const u8{ "Read", "ReadArtifact", "Glob", "Grep", "WebFetch", "BashOutput" };
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
    // 静态分类保守；拥有独立 provider factory 时由 tool_exec 动态升级。
    try std.testing.expect(!isConcurrencySafe("WebSearch"));
    try std.testing.expect(isConcurrencySafe("WebFetch"));
    try std.testing.expect(isConcurrencySafe("Read"));
    try std.testing.expect(!isConcurrencySafe("Write"));
    try std.testing.expect(!isConcurrencySafe("Edit"));
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

test "toToolDefinitions includes ToolSearch when native formal audit is deferred" {
    const defs = try toToolDefinitions(std.testing.allocator);
    defer std.testing.allocator.free(defs);
    // 不再追加 server-tool 形态的 web_search(异形毒化后端,已删)。FormalAuditTask
    // 是 deferred 静态工具，因此 ToolSearch 必须出现；只排除 swarm-gated 工具。
    var non_gated: usize = 0;
    for (registry) |t| {
        if (!t.swarm_gated) non_gated += 1;
    }
    try std.testing.expect(defs.len == non_gated);
    // WebSearch 作为普通函数工具在 registry 里,带 input_schema、无 server_type。
    // 内置工具全常驻(对齐 cc:只 defer MCP),故 WebSearch 不 deferred。
    const ws = getTool("WebSearch").?;
    try std.testing.expect(!ws.deferred);
    var found_ws = false;
    var found_tool_search = false;
    for (defs) |d| {
        if (std.mem.eql(u8, d.name, "WebSearch")) {
            found_ws = true;
            try std.testing.expect(d.server_type == null);
        }
        // 绝不应再出现 server-tool 形态的 web_search。
        try std.testing.expect(!std.mem.eql(u8, d.name, "web_search"));
        if (std.mem.eql(u8, d.name, "ToolSearch")) found_tool_search = true;
    }
    try std.testing.expect(found_ws);
    try std.testing.expect(found_tool_search);
}

test "toToolDefinitionsWithDyn appends dynamic tools after static (no server-tool web_search)" {
    const dyn_mod = @import("tools/dynamic.zig");
    var dyn = dyn_mod.DynRegistry.init(std.testing.allocator);
    defer dyn.deinit();
    const dummy = struct {
        fn exec(_: *const ToolContext, _: []const u8, _: ?*anyopaque) anyerror![]u8 {
            return std.testing.allocator.dupe(u8, "dummy");
        }
    }.exec;
    try dyn.register("MySkill", "a skill", &.{}, dummy, null, false);

    const defs = try toToolDefinitionsWithDyn(std.testing.allocator, &dyn);
    defer std.testing.allocator.free(defs);

    // 非 swarm-gated 静态(含 FormalAuditTask 激活的 ToolSearch) + 1 dyn；
    // prompt_ctx=null 门控 swarm。
    var non_gated: usize = 0;
    for (registry) |t| {
        if (!t.swarm_gated) non_gated += 1;
    }
    try std.testing.expect(defs.len == non_gated + 1);
    // 动态工具在末尾。
    try std.testing.expectEqualStrings("MySkill", defs[defs.len - 1].name);
}

test "dispatch finds static tool" {
    const ctx = ToolContext.simple(std.testing.allocator);
    // schema 层(validateRequired)先于工具自身校验，但错误仍指出具体缺失字段。
    try std.testing.expectError(error.MissingFilePath, dispatch(&ctx, "Read", "{}"));
    // 带 file_path 但工具内部其它校验:走到工具自身(此处文件不存在 → 工具错误,非 schema 层)。
    try std.testing.expectError(error.FileNotFound, dispatch(&ctx, "Read", "{\"file_path\":\"/no/such/file/xyz123\"}"));
}

test "schema validation returns actionable field-specific errors" {
    const ctx = ToolContext.simple(std.testing.allocator);
    try std.testing.expectError(error.MissingPrompt, dispatch(&ctx, "Task", "{}"));
    try std.testing.expectError(error.MissingSubject, dispatch(&ctx, "TaskCreate", "{}"));
    try std.testing.expectError(
        error.MissingDescription,
        dispatch(&ctx, "TaskCreate", "{\"subject\":\"inspect\"}"),
    );
    try std.testing.expectError(error.MissingTaskId, dispatch(&ctx, "TaskUpdate", "{}"));
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
    try dyn.register("Echo", "echoes input", &.{}, echo, null, false);

    var ctx = ToolContext.simple(std.testing.allocator);
    ctx.dyn_registry = &dyn;
    var out = try dispatch(&ctx, "Echo", "hello");
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", out.ok.@"inline".bytes);
}

test "ToolExecutor result_body preserves a native byte-zero artifact receipt" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const Native = struct {
        fn execute(ctx: *const ToolContext, args: []const u8) anyerror!ToolResultBody {
            var spool = try @import("core/tool_result_artifact.zig").Spool.begin(ctx.allocator, ctx.artifact_root);
            defer spool.deinit();
            try spool.write("native-head-");
            try spool.write(args);
            try spool.write("-native-tail");
            return ToolResultBody.fromCompletedSpool(
                try spool.finish(),
                .text_utf8,
            );
        }
    };
    const executor = ToolExecutor{ .result_body = Native.execute };
    var ctx = ToolContext{ .allocator = allocator, .artifact_root = root };
    var body = try executor.run(&ctx, "streamed");
    defer body.deinit(allocator);
    try std.testing.expect(body == .artifact);
    var recovered = try @import("core/tool_result_artifact.zig").readChunk(
        allocator,
        root,
        body.artifact.stored.id(),
        0,
        64,
    );
    defer recovered.deinit();
    try std.testing.expectEqualStrings("native-head-streamed-native-tail", recovered.bytes);
}

test "native byte-zero roster is declared and wired through typed executors" {
    const expected = [_][]const u8{
        "Glob",
        "Grep",
        "CodeMap",
        "FindSymbol",
        "Bash",
        "ListMcpResourcesTool",
        "ReadMcpResourceTool",
        "WebFetch",
    };
    var observed: usize = 0;
    for (registry) |tool| {
        if (tool.result_production != .byte_zero_spool) continue;
        observed += 1;
        var named = false;
        for (expected) |name| if (std.mem.eql(u8, name, tool.name)) {
            named = true;
            break;
        };
        try std.testing.expect(named);
        try std.testing.expect(tool.execute == .result_body);
    }
    try std.testing.expectEqual(expected.len, observed);
}

test "dispatch returns UnknownTool when missing everywhere" {
    var ctx = ToolContext.simple(std.testing.allocator);
    try std.testing.expectError(error.UnknownTool, dispatch(&ctx, "NoSuchTool", "{}"));
}

test "resolveToolNameExact: 大小写/分隔归一化命中真工具" {
    var ctx = ToolContext.simple(std.testing.allocator);
    // 小写、全大写、连字符/空格 → 归一化命中(无损等价变换)。
    try std.testing.expectEqualStrings("Read", resolveToolNameExact(&ctx, "read").?);
    try std.testing.expectEqualStrings("Read", resolveToolNameExact(&ctx, "READ").?);
    try std.testing.expectEqualStrings("Grep", resolveToolNameExact(&ctx, "grep").?);
    try std.testing.expectEqualStrings("Bash", resolveToolNameExact(&ctx, "bash").?);
}

test "resolveToolNameExact: 剥 _tool 尾缀" {
    var ctx = ToolContext.simple(std.testing.allocator);
    // "bash_tool"/"BashTool" 归一 → "bash_tool" 剥尾 → "bash" == "Bash" 归一。
    try std.testing.expectEqualStrings("Bash", resolveToolNameExact(&ctx, "bash_tool").?);
    try std.testing.expectEqualStrings("Bash", resolveToolNameExact(&ctx, "BashTool").?);
}

test "resolveToolNameExact: 模糊近似**不**自动命中(只归一化,不猜测)" {
    var ctx = ToolContext.simple(std.testing.allocator);
    // "Red" 归一后 ≠ 任何真工具归一名 → exact 返 null(不会静默路由到 Read)。
    try std.testing.expect(resolveToolNameExact(&ctx, "Red") == null);
    try std.testing.expect(resolveToolNameExact(&ctx, "xyzzy_frobnicate") == null);
    try std.testing.expect(resolveToolNameExact(&ctx, "") == null);
}

test "suggestToolName: 模糊近似作建议(≥0.7),差太远返 null" {
    var ctx = ToolContext.simple(std.testing.allocator);
    // "Red" → 建议 "Read"(编辑距离 1/4 = 0.75 ≥ 0.7),但仅供错误提示,不执行。
    try std.testing.expectEqualStrings("Read", suggestToolName(&ctx, "Red").?);
    try std.testing.expect(suggestToolName(&ctx, "xyzzy_frobnicate") == null);
    try std.testing.expect(suggestToolName(&ctx, "") == null);
}

test "dispatch: 确定性归一化幻觉名改派到真工具(端到端)" {
    // "grep"(大小写幻觉,归一化无损)→ resolveToolNameExact → "Grep" → 真执行。Grep 缺 pattern
    // 会返错,但**不是 UnknownTool**——证明改派发生了(名字被归一化,进了 Grep 的执行/校验)。
    var ctx = ToolContext.simple(std.testing.allocator);
    ctx.cwd_abs = ".";
    const err = dispatch(&ctx, "grep", "{}");
    if (err) |r| {
        var outcome = r;
        outcome.deinit(std.testing.allocator);
    } else |e| {
        try std.testing.expect(e != error.UnknownTool);
    }
}

test "dispatch: 模糊近似名**不**自动执行,仍 UnknownTool(诚实报错留给模型自纠)" {
    // "Wrote"(≈Write,0.8)→ resolveToolNameExact 不中 → UnknownTool(不静默路由到 Write 真跑)。
    var ctx = ToolContext.simple(std.testing.allocator);
    try std.testing.expectError(error.UnknownTool, dispatch(&ctx, "Wrote", "{}"));
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
    _ = &code_map_tool;
    _ = &find_symbol_tool;
    _ = &@import("tools/symbol_provider.zig");
}
