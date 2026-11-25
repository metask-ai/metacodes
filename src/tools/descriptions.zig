//! 工具长描述生成(动态耦合)。
//!
//! 逐字移植 cc/src/tools/*/prompt.ts 的长描述,"Claude Code" → "MetaCode",
//! 工具名用 cc-zig 实际名(Read/Write/Edit/Bash/Task)。
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
const BASH_GIT_SECTION =
    \\
    \\
    \\# Committing changes with git
    \\Commit when the user or the requested workflow calls for it. Use noninteractive Git commands and preserve the user's other work.
    \\1. Inspect the working tree, index and recent history. Independent checks such as `git status --short`, `git diff`, `git diff --cached` and `git log -5 --oneline` can run together. The staged diff is what the commit will contain.
    \\2. Stage paths belonging to this change by name. Inspect previously staged files for unrelated work and check for credentials or local configuration before committing. If someone else's changes are staged, preserve them and keep them out of this commit.
    \\3. Match the repository's message style and explain the reason for the change. Create a new commit after staging and checking its contents. If a hook fails, the proposed commit did not land: fix the cause, stage that fix and retry. Amending HEAD at that point would change the preceding commit.
    \\4. Verify the new commit and the remaining working tree with `git log -1 --oneline` and `git status --short`. Report any work still unstaged. Push only when the task includes publication.
    \\Keep hooks, signing and Git configuration intact. Preserve existing history and local changes. Destructive resets, broad cleans and force-pushes can erase another person's work; check the target and obtain explicit authorization for destructive actions. Never force-push a shared branch.
    \\
    \\# Creating pull requests
    \\1. Identify the intended base and the current branch's upstream. Review the branch's entire change using `git log <base>..HEAD` and `git diff <base>...HEAD`; also check the working tree for changes the PR would leave behind.
    \\2. Run the checks relevant to those changes. Summarize the user-visible effect, why it was needed, and the checks actually run. State outstanding validation separately.
    \\3. Push the intended branch, setting its upstream if needed. Once the push succeeds, use `gh pr create` with the intended base and head. For a multiline description, pass a body file so quoting and formatting survive. If the branch already has a PR, update that PR.
    \\4. Return the PR URL and its verification state. A successful local commit or push alone does not establish that a PR exists.
;

pub fn describeBash(allocator: std.mem.Allocator, ctx: *const PromptContext) anyerror![]u8 {
    const windows = @import("builtin").os.tag == .windows;
    const readonly = ctx.isReadonlyAgent();
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    const out = &text.writer;

    try out.writeAll(if (windows)
        "Run a Windows shell command. Use PowerShell syntax when PowerShell is installed; the fallback shell is cmd.exe."
    else
        "Run a shell command through /bin/sh. Use portable shell syntax, or invoke a specific interpreter when the task requires it.");
    try out.writeAll(
        \\
        \\Each call starts a fresh process in the session working directory. A directory change, variable assignment or shell option lasts only for that call. Supply the directory to the command when possible, e.g. `git -C "project with spaces" status --short`.
        \\
        \\# Choosing a tool
    );
    try out.writeAll("\nFind files with `rg --files -g \"*.zig\"` and literal text with `rg -n -F -- \"text\" src`. Scope searches to the project or a relevant subdirectory.");
    try out.writeAll(if (windows)
        " In PowerShell, Get-ChildItem can list matching files and Select-String with -SimpleMatch can search known files when rg is unavailable."
    else
        " If rg is unavailable, list files with `find src -type f -name '*.zig'` and search text with `grep -rnF -- 'text' src`.");
    if (ctx.hasTool("Read")) try out.writeAll(" Use Read to inspect the matching lines.");
    if (!readonly and ctx.hasTool("Edit")) try out.writeAll(" Use Edit for targeted replacements.");
    if (!readonly and ctx.hasTool("Write")) try out.writeAll(" Use Write to create files.");

    try out.writeAll(
        \\
        \\
        \\# Running commands
        \\Pass the command in `command`. Give the user a short description of its purpose, such as "Run the parser regression tests". Quote paths with spaces. Before creating files in an unfamiliar directory, verify the parent and destination.
        \\Run independent inspections in parallel. Keep dependent operations in order: a successful build must finish before an install that consumes its output. If a prerequisite fails, inspect the error before continuing.
    );
    try out.writeAll(if (windows)
        "\nIn PowerShell, use -LiteralPath for exact paths and check $LASTEXITCODE after a native executable before running a dependent step. Use a single shell for file operations; verify the resolved target before recursive deletion."
    else
        "\nUse `&&` when the next command requires the previous one to succeed. For independent checks, separate calls preserve each exit status.");
    try out.writeAll(
        \\
        \\
        \\# Long-running commands and results
        \\The foreground timeout is in milliseconds. Set it to suit the work. For background work on a host with job support, set `run_in_background` and use the returned `job_id`. A long foreground call can also return a job ID while work continues. Starting a job does not mean it succeeded.
    );
    if (ctx.hasTool("BashOutput")) try out.writeAll(" Use BashOutput with that ID when you need the result: it waits for exit up to `wait_ms` by default. The CLI also delivers a completion notification. Avoid sleep loops and repeated empty polls.");
    try out.writeAll("\nFor a completed command, inspect `exit_code`, `stdout` and `stderr`. A search exit code of 1 from rg means no match; check diagnostics for other failures. A channel marked truncated contains only a preview.");
    if (ctx.hasTool("ReadArtifact")) try out.writeAll(" Pass the returned channel artifact ID to ReadArtifact and continue at `next_offset` to recover the omitted output.");
    try out.writeAll(" Report the relevant finding or failure to the user; they may only see your summary.");
    if (readonly) {
        try out.writeAll("\n\nYou are a read-only agent. Limit shell use to inspection. Builds, installations, filesystem writes (including redirection), staging and commits can change state.");
    } else if (ctx.include_git) {
        try out.writeAll(BASH_GIT_SECTION);
    }
    return text.toOwnedSlice();
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
