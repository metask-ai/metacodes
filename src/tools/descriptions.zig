//! 工具长描述生成(动态耦合)。
//!
//! 逐字移植 cc/src/tools/*/prompt.ts 的长描述,"Claude Code" → "MetaCode",
//! 工具名用 cc-zig 实际名(Read/Write/Edit/Glob/Grep/Bash/Task)。
//!
//! 每个 describe* 函数签名:fn(allocator, *const PromptContext) anyerror![]u8,
//! 返回 owned slice(调用方用 arena 管理,session 结束统一释放)。
//!
//! 动态耦合点:
//! - 描述引用其它工具时,据 ctx.hasTool 判断存在性(对齐 TS embedded 分支)。
//! - describeBash 按 ctx.include_git 增删 Git 协议段。
//! - 只读 agent(ctx.isReadonlyAgent)的 Bash 描述加只读提醒。
//!
//! 工具描述原文与 prompt 的耦合守卫见 apps/cli/tests/component/prompt_tool_coupling_test.zig。

const std = @import("std");
const PromptContext = @import("prompt_context.zig").PromptContext;

// ============================================================================
// Read — cc/src/tools/FileReadTool/prompt.ts renderPromptTemplate
// ============================================================================
const READ_DESC =
    \\Reads a file from the local filesystem. You can access any file directly by using this tool.
    \\Assume this tool is able to read all files on the machine. If the User provides a path to a file assume that path is valid. It is okay to read a file that does not exist; an error will be returned.
    \\
    \\Usage:
    \\- The file_path parameter must be an absolute path, not a relative path
    \\- By default, it reads up to 2000 lines starting from the beginning of the file
    \\- Files larger than 256KB are rejected for a full read — pass offset+limit to read the lines you need
    \\- Very long single lines are truncated; the marker "[line truncated]" indicates this
    \\- You can optionally specify a line offset and limit (especially handy for long files), but it's recommended to read the whole file by not providing these parameters
    \\- When you already know which part of the file you need, only read that part. This can be important for larger files.
    \\- Results are returned using cat -n format, with line numbers starting at 1
    \\- This tool reads images (PNG, JPG, GIF, WEBP). When the active model supports image input the image is presented visually. When it does not, the call fails with error code capability_unsupported and the detail names which models on this route can view images; do not retry the same Read, pick another approach (switch model, or extract text/metadata with a script).
    \\- This tool cannot read PDF files. It has no PDF extraction or page-rendering path and no pages parameter; reading a .pdf here yields its raw bytes, not its contents.
    \\- Jupyter notebooks (.ipynb files) are read as their raw JSON, not as rendered cells; use NotebookEdit to modify a cell.
    \\- This tool can only read files, not directories. To read a directory, use an ls command via the Bash tool.
    \\- You will regularly be asked to read screenshots. If the user provides a path to a screenshot, ALWAYS use this tool to view the file at the path. This tool will work with all temporary file paths.
    \\- If you read a file that exists but has empty contents you will receive a system reminder warning in place of file contents.
;

pub fn describeRead(allocator: std.mem.Allocator, ctx: *const PromptContext) anyerror![]u8 {
    _ = ctx;
    return allocator.dupe(u8, READ_DESC);
}

// ============================================================================
// Write — cc/src/tools/FileWriteTool/prompt.ts getWriteToolDescription
// ============================================================================
const WRITE_DESC =
    \\Writes a file to the local filesystem.
    \\
    \\Usage:
    \\- This tool will overwrite the existing file if there is one at the provided path.
    \\- If this is an existing file, you MUST use the Read tool first to read the file's contents. This tool will fail if you did not read the file first.
    \\- Prefer the Edit tool for modifying existing files — it only sends the diff. Only use this tool to create new files or for complete rewrites.
    \\- NEVER create documentation files (*.md) or README files unless explicitly requested by the User.
    \\- Only use emojis if the user explicitly requests it. Avoid writing emojis to files unless asked.
;

pub fn describeWrite(allocator: std.mem.Allocator, ctx: *const PromptContext) anyerror![]u8 {
    _ = ctx;
    return allocator.dupe(u8, WRITE_DESC);
}

// ============================================================================
// Edit — cc/src/tools/FileEditTool/prompt.ts getDefaultEditDescription
// ============================================================================
const EDIT_DESC =
    \\Performs exact string replacements in files.
    \\
    \\Usage:
    \\- You must use your `Read` tool at least once in the conversation before editing. This tool will error if you attempt an edit without reading the file.
    \\- When editing text from Read tool output, ensure you preserve the exact indentation (tabs/spaces) as it appears AFTER the line number prefix. The line number prefix format is: line number + tab. Everything after that is the actual file content to match. Never include any part of the line number prefix in the old_string or new_string.
    \\- ALWAYS prefer editing existing files in the codebase. NEVER write new files unless explicitly required.
    \\- Only use emojis if the user explicitly requests it. Avoid adding emojis to files unless asked.
    \\- The edit will FAIL if `old_string` is not unique in the file. Either provide a larger string with more surrounding context to make it unique or use `replace_all` to change every instance of `old_string`.
    \\- Use `replace_all` for replacing and renaming strings across the file. This parameter is useful if you want to rename a variable for instance.
;

pub fn describeEdit(allocator: std.mem.Allocator, ctx: *const PromptContext) anyerror![]u8 {
    _ = ctx;
    return allocator.dupe(u8, EDIT_DESC);
}

// ============================================================================
// Glob — cc/src/tools/GlobTool/prompt.ts DESCRIPTION
// 动态:多轮搜索建议用 Agent,仅当 Agent/Task 在工具集时才提。
// ============================================================================
pub fn describeGlob(allocator: std.mem.Allocator, ctx: *const PromptContext) anyerror![]u8 {
    const agent_line = if (ctx.hasTool("Task") or ctx.hasTool("Agent"))
        "\n- When you are doing an open ended search that may require multiple rounds of globbing and grepping, use the Agent tool instead"
    else
        "";
    return std.fmt.allocPrint(allocator,
        \\- Fast file pattern matching tool that works with any codebase size
        \\- Supports glob patterns like "**/*.js" or "src/**/*.ts"
        \\- Returns matching file paths sorted by modification time
        \\- Use this tool when you need to find files by name patterns{s}
    , .{agent_line});
}

// ============================================================================
// Grep — cc/src/tools/GrepTool/prompt.ts getDescription
// 动态:多轮搜索用 Agent 一句仅当 Agent/Task 在工具集时才提。
// ============================================================================
pub fn describeGrep(allocator: std.mem.Allocator, ctx: *const PromptContext) anyerror![]u8 {
    // 用 concat 而非 allocPrint:描述里有大量字面 `{` `}`(ripgrep 正则),
    // allocPrint 会把它们当格式占位符。concat 不做格式解析,安全。
    const agent_line = if (ctx.hasTool("Task") or ctx.hasTool("Agent"))
        "\n- Use Agent tool for open-ended searches requiring multiple rounds"
    else
        "";
    return std.mem.concat(allocator, u8, &.{
        \\A powerful search tool built on ripgrep
        \\
        \\Usage:
        \\- ALWAYS use Grep for search tasks. NEVER invoke `grep` or `rg` as a Bash command. The Grep tool has been optimized for correct permissions and access.
        \\- Supports full regex syntax (e.g., "log.*Error", "function\s+\w+")
        \\- Filter files with glob parameter (e.g., "*.js", "**/*.tsx") or type parameter (e.g., "js", "py", "rust")
        \\- Output modes: "content" shows matching lines, "files_with_matches" shows only file paths (default), "count" shows match counts
        \\- Results are capped at 250 lines by default (head_limit); pass head_limit:0 for unlimited, or use offset to page. Prefer narrowing the pattern over fetching everything.
        ,
        agent_line,
        "\n",
        \\- Pattern syntax: Uses ripgrep (not grep) - literal braces need escaping (use `interface\{\}` to find `interface{}` in Go code)
        \\- Multiline matching: By default patterns match within single lines only. For cross-line patterns like `struct \{[\s\S]*?field`, use `multiline: true`
        \\- Searching a truncated tool result: pass its artifact_id instead of path. One search answers "where in this output is X" directly; paging the same result with ReadArtifact costs one round-trip per 32KB and re-sends the whole context each time. output_mode must be "content" or "count" (there is only one file to name), and path must be omitted.
        ,
    });
}

// ============================================================================
// Bash — cc/src/tools/BashTool/prompt.ts
// 动态:① background note;② Git 协议段(ctx.include_git);③ 只读 agent 提醒。
// ============================================================================
const BASH_GIT_SECTION =
    \\
    \\
    \\# Committing changes with git
    \\
    \\When the user asks you to create a new git commit, follow these steps carefully:
    \\1. Run a git status, git diff, and git log in parallel to see staged/unstaged changes and recent commit message style.
    \\2. Stage relevant files, then create the commit with a concise message focused on "why" rather than "what". Do NOT add co-author or tool attribution unless asked.
    \\3. Do NOT use destructive flags. NEVER force-push, run `git reset --hard`, amend published commits, or use `--no-verify` to bypass hooks.
    \\
    \\# Creating pull requests
    \\
    \\Use the `gh` command for GitHub operations. To create a PR:
    \\1. Run git status / git diff / git log on the base branch in parallel to understand the full set of changes.
    \\2. Push the branch with -u if needed, then create the PR with a summary and test plan.
    \\3. NEVER force-push to shared branches or close others' PRs without confirmation.
;

const BASH_READONLY_NOTE =
    \\
    \\
    \\NOTE: You are a read-only agent. Use Bash ONLY for read-only operations (ls, git status, git log, git diff, find, cat, head, tail). NEVER run state-changing commands (mkdir, touch, rm, cp, mv, git add, git commit, npm/pip install) or use redirection (>, >>) / heredocs to write files.
;

pub fn describeBash(allocator: std.mem.Allocator, ctx: *const PromptContext) anyerror![]u8 {
    const search =
        "Use the shell to search the workspace, run builds and tests, and inspect Git. " ++
        "Find files with `rg --files -g '*.zig'` and literal text with `rg -n -F -- 'text' src`. " ++
        "Narrow the path where possible. When available, use Read for the matching lines, Edit for changes, and Write for new files.";
    const git_section = if (ctx.include_git and !ctx.isReadonlyAgent()) BASH_GIT_SECTION else "";
    const readonly_note = if (ctx.isReadonlyAgent()) BASH_READONLY_NOTE else "";
    // 复刻 codex 第③层:平台化工具描述。Windows 上用系统自带 PowerShell 跑(零 git-bash),
    // 故告诉模型产 **PowerShell** cmdlet 而非 bash 命令(codex 实证:比 bash→ps 翻译层更稳)。
    if (@import("builtin").os.tag == .windows) {
        return std.fmt.allocPrint(allocator,
            \\Runs a PowerShell command (Windows) in a persistent shell session with an optional timeout, ensuring proper handling and security measures.
            \\
            \\Usage:
            \\- The command argument is required. Write **PowerShell** syntax (this runs via `powershell -NoProfile -Command`, not bash).
            \\- You can specify an optional timeout in milliseconds. If not specified, commands will time out after the default.
            \\- It is very helpful if you write a clear, concise description of what this command does in 5-10 words.
            \\- Use the `run_in_background` parameter to run it in the background; when it exits you will be notified automatically with a `<task-notification>` message at your next turn, so do not poll or sleep-wait; use BashOutput to read its output (on a still-running job BashOutput waits for it to exit, up to wait_ms); do not append '&'.
            \\- {s} If rg is unavailable, use Get-ChildItem and Select-String.
            \\- Chain multiple commands with ';'. DO NOT use newlines.
            \\- PowerShell examples: list all incl hidden → `Get-ChildItem -Force`; recursive by name → `Get-ChildItem -Recurse -Filter *.py`; set env var → `$env:FOO='bar'; echo $env:FOO`.
            \\- Windows safety: use one shell end-to-end (do not enumerate in PowerShell then pipe to cmd/batch for delete/move); prefer `Remove-Item`/`Move-Item -LiteralPath`; verify absolute target stays in workspace before any recursive delete/move; pass `Start-Process -WindowStyle Hidden` for background helpers.
            \\- Output comes back as a JSON envelope with one field group per channel. A channel that exceeds the context budget is reduced to a head/tail preview marked "...[middle omitted]..." and its "<channel>_truncated" field is set to true.
            \\- To read truncated output, pass its "<channel>_artifact_id" to ReadArtifact and continue at next_offset.{s}{s}
        , .{ search, git_section, readonly_note });
    }
    return std.fmt.allocPrint(allocator,
        \\Executes a given bash command in a persistent shell session with an optional timeout, ensuring proper handling and security measures.
        \\
        \\Usage:
        \\- The command argument is required.
        \\- You can specify an optional timeout in milliseconds. If not specified, commands will time out after the default.
        \\- It is very helpful if you write a clear, concise description of what this command does in 5-10 words.
        \\- You can use the `run_in_background` parameter to run it in the background; when it exits you will be notified automatically with a `<task-notification>` message at your next turn, so do not poll or sleep-wait; use BashOutput to read its output (on a still-running job BashOutput waits for it to exit, up to wait_ms). You do not need to use '&' at the end of the command when using this parameter.
        \\- {s} If rg is unavailable, use find and grep within the project.
        \\- When issuing multiple commands, use the ';' or '&&' operator to separate them. DO NOT use newlines.
        \\- Output comes back as a JSON envelope with one field group per channel. A channel that exceeds the context budget is reduced to a head/tail preview marked "...[middle omitted]..." and its "<channel>_truncated" field is set to true.
        \\- To read truncated output, pass its "<channel>_artifact_id" to ReadArtifact and continue at next_offset.{s}{s}
    , .{ search, git_section, readonly_note });
}

// ============================================================================
// Task / Agent — cc/src/tools/AgentTool/prompt.ts getPrompt (named-subagent 分支)
// 动态:列当前可用 subagent(此处保持静态主体,agent 列表由 system prompt 的
// # Available subagents 段提供,避免重复)。
// ============================================================================
const TASK_DESC =
    \\Launch a new agent to handle complex, multi-step tasks autonomously. Each agent starts with a fresh context — it cannot see this conversation, only the prompt you pass.
    \\
    \\Use subagents for: high-volume operations (running tests, processing logs) that would flood your context, parallel independent research, or isolating exploration. The agent runs in its own context and returns only a concise summary.
    \\
    \\Brief the agent like a smart colleague who just walked into the room — it hasn't seen this conversation, doesn't know what you've tried, doesn't understand why the task matters. Give it full context in the prompt.
    \\
    \\When using the Task tool, specify a subagent_type parameter to select which agent type to use (Explore / Plan / general-purpose / a custom agent). If omitted, the general-purpose agent is used.
;

pub fn describeTask(allocator: std.mem.Allocator, ctx: *const PromptContext) anyerror![]u8 {
    _ = ctx;
    return allocator.dupe(u8, TASK_DESC);
}

const TASK_GET_SESSION_DESC =
    "Fetch a task from the in-session task list by id. Use it when the list summary is not enough; tasks do not persist after this session.";
const TASK_GET_TINYKG_DESC =
    "Fetch a task by id. For persistent kg-* tasks this also returns a bounded TinyKG task_packet with parent objective, dependencies, evidence, truncation diagnostics and continuations. Call it after restart/compaction or whenever claim could not return a packet; do not work from the title alone.";
const TASK_CREATE_SESSION_DESC =
    "Create a task in the in-session task list. Returns the new task id. Use for multi-step work you want to track across turns.";
const TASK_CREATE_TINYKG_DESC =
    "Create a persistent task in TinyKG's project DAG. Returns a stable kg-* id that survives compaction and restart; use TaskUpdate to claim, close with evidence, or record terminal failure.";
const TASK_LIST_SESSION_DESC =
    "List the in-session task list. Pick an unblocked pending task, mark it in_progress before work, and complete it promptly; this list does not persist after the session.";
const TASK_LIST_TINYKG_DESC =
    "List the live task frontier. For kg-* tasks select only an open, ready, unclaimed leaf; then claim it with TaskUpdate status=in_progress before work. This is a summary/projection, so use TaskGet/task_packet for full recovery context.";
const TASK_UPDATE_SESSION_DESC =
    "Update an in-session task's status, fields, owner, or dependency links. Use pending/in_progress/completed/deleted and keep the list current as work proceeds.";
const TASK_UPDATE_TINYKG_DESC =
    "Update a task's status (pending/in_progress/completed/failed/deleted) and/or fields. For persistent kg-* tasks: claim with in_progress before work (the successful response contains the bounded task_packet); completed/failed are terminal while preserving the stable id; deleted is only a compatibility alias for failed. Close every claimed task with a verified conclusion and actual acts_on/uses/produces when known, then inspect the returned frontier.";

pub fn describeTaskGet(allocator: std.mem.Allocator, ctx: *const PromptContext) anyerror![]u8 {
    return allocator.dupe(u8, if (ctx.tinykg_enabled) TASK_GET_TINYKG_DESC else TASK_GET_SESSION_DESC);
}

pub fn describeTaskCreate(allocator: std.mem.Allocator, ctx: *const PromptContext) anyerror![]u8 {
    return allocator.dupe(u8, if (ctx.tinykg_enabled) TASK_CREATE_TINYKG_DESC else TASK_CREATE_SESSION_DESC);
}

pub fn describeTaskList(allocator: std.mem.Allocator, ctx: *const PromptContext) anyerror![]u8 {
    return allocator.dupe(u8, if (ctx.tinykg_enabled) TASK_LIST_TINYKG_DESC else TASK_LIST_SESSION_DESC);
}

pub fn describeTaskUpdate(allocator: std.mem.Allocator, ctx: *const PromptContext) anyerror![]u8 {
    return allocator.dupe(u8, if (ctx.tinykg_enabled) TASK_UPDATE_TINYKG_DESC else TASK_UPDATE_SESSION_DESC);
}

// ----------------------------------------------------------------------------
// tests
// ----------------------------------------------------------------------------
test "describeRead contains cat -n marker" {
    const a = std.testing.allocator;
    const ctx = PromptContext{};
    const d = try describeRead(a, &ctx);
    defer a.free(d);
    try std.testing.expect(std.mem.indexOf(u8, d, "cat -n format") != null);
}

test "describeEdit contains exact-replacement marker" {
    const a = std.testing.allocator;
    const ctx = PromptContext{};
    const d = try describeEdit(a, &ctx);
    defer a.free(d);
    try std.testing.expect(std.mem.indexOf(u8, d, "exact string replacements") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "replace_all") != null);
}

test "describeGrep contains ALWAYS-use-Grep + agent line only when Agent enabled" {
    const a = std.testing.allocator;
    const with_agent = PromptContext{ .enabled_tool_names = &.{ "Grep", "Task" } };
    const d1 = try describeGrep(a, &with_agent);
    defer a.free(d1);
    try std.testing.expect(std.mem.indexOf(u8, d1, "ALWAYS use Grep") != null);
    try std.testing.expect(std.mem.indexOf(u8, d1, "open-ended searches") != null);

    const no_agent = PromptContext{ .enabled_tool_names = &.{"Grep"} };
    const d2 = try describeGrep(a, &no_agent);
    defer a.free(d2);
    try std.testing.expect(std.mem.indexOf(u8, d2, "open-ended searches") == null);
}

test "describeBash includes Git section only when include_git and not readonly agent" {
    const a = std.testing.allocator;
    const main_ctx = PromptContext{ .include_git = true };
    const d1 = try describeBash(a, &main_ctx);
    defer a.free(d1);
    try std.testing.expect(std.mem.indexOf(u8, d1, "Committing changes with git") != null);

    const no_git = PromptContext{ .include_git = false };
    const d2 = try describeBash(a, &no_git);
    defer a.free(d2);
    try std.testing.expect(std.mem.indexOf(u8, d2, "Committing changes with git") == null);

    const explore = PromptContext{ .include_git = true, .agent_type = "Explore" };
    const d3 = try describeBash(a, &explore);
    defer a.free(d3);
    try std.testing.expect(std.mem.indexOf(u8, d3, "Committing changes with git") == null);
    try std.testing.expect(std.mem.indexOf(u8, d3, "read-only agent") != null);
}
