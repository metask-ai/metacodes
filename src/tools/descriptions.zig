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
//! 见 doc/PROMPT_TOOL_RELATIONSHIP.md 第五节(原文素材)。

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
    \\- Files larger than 256KB are rejected for a full read — pass offset+limit to read a range, or use Grep to find specific content
    \\- Very long single lines are truncated; the marker "[line truncated]" indicates this
    \\- You can optionally specify a line offset and limit (especially handy for long files), but it's recommended to read the whole file by not providing these parameters
    \\- When you already know which part of the file you need, only read that part. This can be important for larger files.
    \\- Results are returned using cat -n format, with line numbers starting at 1
    \\- This tool allows MetaCode to read images (eg PNG, JPG, etc). When reading an image file the contents are presented visually as MetaCode is a multimodal LLM.
    \\- This tool can read PDF files (.pdf). For large PDFs (more than 10 pages), you MUST provide the pages parameter to read specific page ranges (e.g., pages: "1-5"). Reading a large PDF without the pages parameter will fail. Maximum 20 pages per request.
    \\- This tool can read Jupyter notebooks (.ipynb files) and returns all cells with their outputs, combining code, text, and visualizations.
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
        ,
    });
}

// ============================================================================
// CodeMap — tree-sitter 结构大纲。无 cc 对应物,描述自拟。
// 动态:若 FindSymbol 在工具集(或可经 ToolSearch 激活)则提一句"找定义用它"。
// 引导力度对齐 Grep:给明确 use case + "prefer over whole-file Read"。
// ============================================================================
pub fn describeCodeMap(allocator: std.mem.Allocator, ctx: *const PromptContext) anyerror![]u8 {
    // FindSymbol 现为默认工具(2026-06-08 从 deferred 提出),无需 ToolSearch 激活;
    // 描述里直接引导"按名找单个定义用 FindSymbol"。
    _ = ctx;
    return std.mem.concat(allocator, u8, &.{
        \\Produce a structural outline of SOURCE CODE — every function, type, class, constant, and method with its line number and signature — without reading the file bodies.
        \\
        \\Usage:
        \\- This tool is for source code only and requires --lsp plus an installed language server (zls, pyright, typescript-language-server, gopls, rust-analyzer, clangd, …). For plain-text, config, JSON, Markdown, non-code files, or when no server is available, fall back to Read or Grep.
        \\- ALWAYS prefer CodeMap over reading a whole file when your goal is to LOCATE definitions (where is function X? what methods does this type have? what's the shape of this module?). It returns just the skeleton, costing a fraction of the tokens of a full Read.
        \\- Pass a single file path to map one file, or a glob (e.g. `src/**/*`) to map many files at once — ideal for getting your bearings in an unfamiliar module or directory. The language of each file is inferred from its extension.
        \\- Typical workflow: CodeMap to find WHERE something is defined → Read with offset+limit to pull just that range → Edit. Reserve a full-file Read for when you genuinely need the entire contents.
        \\- Use Grep when you need to find all USES/occurrences of a string or regex; use CodeMap when you need the DEFINITIONS and overall structure.
        ,
        "\n- To jump straight to a single symbol's definition by name (when you don't know which file it lives in), use the FindSymbol tool instead.",
        "\n",
        \\- Supported languages: zig, typescript, tsx, python, c, bash. For other languages, fall back to Grep or Read.
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
    const git_section = if (ctx.include_git and !ctx.isReadonlyAgent()) BASH_GIT_SECTION else "";
    const readonly_note = if (ctx.isReadonlyAgent()) BASH_READONLY_NOTE else "";
    return std.fmt.allocPrint(allocator,
        \\Executes a given bash command in a persistent shell session with an optional timeout, ensuring proper handling and security measures.
        \\
        \\Usage:
        \\- The command argument is required.
        \\- You can specify an optional timeout in milliseconds. If not specified, commands will time out after the default.
        \\- It is very helpful if you write a clear, concise description of what this command does in 5-10 words.
        \\- You can use the `run_in_background` parameter to run the command in the background. Only use this if you don't need the result immediately and are OK being notified when the command completes later. You do not need to use '&' at the end of the command when using this parameter.
        \\- VERY IMPORTANT: You MUST avoid using search commands like `find` and `grep`. Instead use Grep, Glob, or Agent to search. You MUST avoid read tools like `cat`, `head`, `tail`, and `ls`, and use Read and LS to read files.
        \\- If you _still_ need to run `grep`, STOP. ALWAYS USE ripgrep at `rg` first, which all MetaCode users have pre-installed.
        \\- When issuing multiple commands, use the ';' or '&&' operator to separate them. DO NOT use newlines.
        \\- Output (stdout/stderr) is truncated to ~30KB; a "[N lines truncated]" marker indicates this. Pipe through `head`/`tail` or write to a file and Read a range when you need more.{s}{s}
    , .{ git_section, readonly_note });
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

test "describeCodeMap guides toward definitions and prefers over whole-file Read" {
    const a = std.testing.allocator;
    const ctx = PromptContext{};
    const d = try describeCodeMap(a, &ctx);
    defer a.free(d);
    try std.testing.expect(std.mem.indexOf(u8, d, "structural outline") != null);
    // 核心引导:LOCATE 定义优先 CodeMap 而非整文件 Read
    try std.testing.expect(std.mem.indexOf(u8, d, "prefer CodeMap over reading a whole file") != null);
    // 提及 FindSymbol(已提为默认工具,不再需要 ToolSearch 激活)
    try std.testing.expect(std.mem.indexOf(u8, d, "FindSymbol") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "ToolSearch") == null);
    // 强调仅针对源代码
    try std.testing.expect(std.mem.indexOf(u8, d, "source code only") != null);
    // 含字面 glob 大括号不应导致格式化崩溃(用 concat 而非 allocPrint);语言中立 glob
    try std.testing.expect(std.mem.indexOf(u8, d, "src/**/*`") != null);
}

test "describeBash includes Git section only when include_git and not readonly agent" {    const a = std.testing.allocator;
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
