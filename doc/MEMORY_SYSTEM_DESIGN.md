# 记忆系统设计规格 (Memory System) — zig-cc 对齐 Claude Code

> 状态：规格 v1（2026-06-08）。范围决策：**A+B 全量对齐 + @import 完整递归**（用户拍板）。
> 真理来源：本文档将上传 metaknow scope `metask_business`。
> 参考实现证据：`cc/src/` TS 反混淆源码（已逐项核实，见 §7 证据表）。

---

## 0. 全景：记忆是两条独立通道

Claude Code 的"记忆"不是一个东西，是**两条正交的注入通道**，落盘格式都是 Markdown，但加载器、注入位置、生命周期完全不同：

| | 通道 A：CLAUDE.md 链 | 通道 B：自动记忆 memdir |
|---|---|---|
| **内容** | 人写的指令（项目约定、用户偏好、企业策略） | 模型自己沉淀的知识（4 类带 frontmatter 的单文件记忆） |
| **谁维护** | 人（手写 / `/init` / `/memory` 编辑器 / `#` 快捷） | 模型（用 Write/Read 工具自管） |
| **落盘** | `~/.claude/CLAUDE.md`、`<repo>/CLAUDE.md`、`.claude/CLAUDE.md`、`CLAUDE.local.md`、`rules/*.md`、managed | `<memoryBase>/projects/<sanitized-git-root>/memory/` 下 `MEMORY.md` + 一条一文件 `*.md` |
| **注入位置** | **首条 user message**，`<system-reminder>` 包裹，键 `# claudeMd` | 两半：① `MEMORY.md` 索引走通道 A（AutoMem 类型）注入到同一 user message；② **记忆操作说明** 注入 **system prompt** |
| **生命周期** | 每会话加载一次，memoize；compact 后重读 | 同上 |
| **现状(zig-cc)** | 仅 subagent preload 用硬编码 4 文件链；主 session **完全不注入** | **完全没有** |

关键洞察（本会话活证据）：**当前运行的 Claude Code 自己就在用这套**——本会话开头的 `<system-reminder>` 里 `# claudeMd` 段、`MEMORY_INSTRUCTION_PROMPT` 原文、`MEMORY.md` 索引「(user's auto-memory, persists across conversations)」标签全是实证，不是猜测。

---

## 1. 通道 A：CLAUDE.md 加载链

### 1.1 加载路径与层级

参考实现：`cc/src/utils/claudemd.ts:getMemoryFiles`（790），`utils/config.ts:getMemoryPath`（1779）。

**记忆类型枚举**（`utils/memory/types.ts`）：`Managed | User | Project | Local | AutoMem`（团队记忆 TeamMem 不做）。

加载路径表：

| 类型 | 路径 | 备注 |
|------|------|------|
| Managed（企业） | macOS `/Library/Application Support/ClaudeCode/CLAUDE.md`；Linux `/etc/claude-code/CLAUDE.md` | zig-cc **可做但低优先级**（企业场景），先留接口 |
| Managed rules | `<managed>/.claude/rules/*.md` | 同上 |
| User | `~/.claude/CLAUDE.md`（`CLAUDE_CONFIG_DIR` 覆盖 `~/.claude`） | **必做** |
| User rules | `~/.claude/rules/*.md` | 必做 |
| Project | 每个祖先目录的 `<dir>/CLAUDE.md` **和** `<dir>/.claude/CLAUDE.md` | **必做** |
| Project rules | `<dir>/.claude/rules/*.md` | 必做 |
| Local | `<dir>/CLAUDE.local.md`（gitignored，私有） | **必做** |
| AutoMem | memdir 的 `MEMORY.md` | 见通道 B |

zig-cc 额外保留：`~/.cc-zig/CLAUDE.md`（本项目历史已有，向后兼容）。

### 1.2 向上递归 + 子目录按需（核心）

- **向上递归：YES**。从 `cwd` 一路 `dirname` 走到文件系统根，收集每个目录；然后**反转成 根→cwd 顺序**处理，使越靠近 cwd 的越晚加载 = **优先级越高**（`dirs.reverse()`，claudemd.ts:850-934）。
- **子目录(child) CLAUDE.md：按需，非启动加载**。启动只向上走。当模型读/写某子目录文件时，惰性加载该子树的 CLAUDE.md/rules（`getMemoryFilesForNestedDirectory`，1205-1342，从 `attachments.ts:1832` 触发）。**zig-cc v1 范围：做向上递归（必做），子目录按需加载列为 §6 后续**——它依赖 attachment 系统，且价值低于向上链。

### 1.3 优先级与合并

加载顺序（docstring 1-10）：**Managed → User → Project(根→cwd) → Local**，"后加载者优先级最高"。全部拼接，每块带标签：

```
Contents of <绝对路径> (<描述>):
<内容>
```

描述字面量（必须一字不差，本会话已见）：
- User CLAUDE.md → `(user's private global instructions for all projects)`
- Project CLAUDE.md → `(project instructions, checked into the codebase)`
- AutoMem MEMORY.md → `(user's auto-memory, persists across conversations)`
- Local → `(user's private project instructions, not checked in)`（推测，cc 未直接见；按语义定）

### 1.4 `@path` import 递归内联（用户要求：完整做）

参考：`extractIncludePathsFromTokens`（claudemd.ts:451），`processMemoryFile`（618），`MAX_INCLUDE_DEPTH=5`（537）。

规格：
- **语法**：`@path`、`@./rel`、`@~/home`、`@/abs`。裸 `@path` = 相对当前文件目录。正则锚点：`(?:^|\s)@((?:[^\s\\]|\\ )+)`——前面必须是行首或空白；支持 `\ ` 转义空格；剥掉 `#fragment`。**简化（与 cc 差异）**：fragment 剥离用"截首个 `#`"，而非 cc 的正则边界——Unix 文件名可含 `#`，故 `@my#file.md` 会被截成 `my`。CLAUDE.md import 路径含 `#` 极罕见，故接受此简化（代码注释 + 测试 `extractImportsFromLine: # 在路径中段被截断` 已标注）。
- **内联隔离（与 cc 实现差异，语义对齐）**：cc 把每个 import 作为**独立 `Contents of...` 条目**注入，天然隔离 markdown 串扰。zig-cc 用单一拼接缓冲，故每个内联 child 前后加显式边界 `<!-- BEGIN @import <path> -->` ... `<!-- END @import -->` + 强制空行。这防止 child 内**未闭合的 ``` 围栏**吞掉父文件的后续文本（测试 `child 未闭合围栏不污染父后续文本` 覆盖）。
- **只在叶子文本节点展开**：代码块 ` ``` `、行内 code `` ` `` 、HTML 注释体里的 `@path` **不展开**（按 markdown 词法判定；zig-cc 用轻量行级扫描近似：跳过 ```` ``` ```` 围栏内、跳过 `` `...` `` 行内）。
- **递归内联**：被引文件内容**作为独立条目插在父之前**（带 `parent` 关系），父继续展开自身其余文本。
- **深度上限 5**：`MAX_INCLUDE_DEPTH`，超出停止。
- **循环检测**：`processedPaths: Set<规范化路径>`（realpath + symlink 解析），已见路径返回空。
- **扩展名白名单**：只允许文本扩展名（cc `TEXT_FILE_EXTENSIONS` ~150 项）；zig-cc 用精简白名单 `.md .txt .markdown .mdx .rst .text` + 无扩展名放行（够用）。
- **外部路径（cwd 外）**：cc 需用户批准（`hasClaudeMdExternalIncludesApproved`）；user 记忆永远允许外部。**zig-cc v1：外部 import 直接放行**（单机工具，无多租户安全边界），但 log.debug 记录，§6 列"加批准对话框"为后续。

### 1.5 注入：首条 user message + system-reminder（铁律）

参考：`context.ts:getUserContext`（155）→ `getClaudeMds`（1153）→ `utils/api.ts:prependUserContext`（449）。

**不是拼 system prompt，是合成一条 `isMeta:true` 的首条 user message**：

```
<system-reminder>
As you answer the user's questions, you can use the following context:
# claudeMd
<MEMORY_INSTRUCTION_PROMPT>

<拼好的 CLAUDE.md 链 + AutoMem 索引>
# currentDate
Today's date is YYYY/MM/DD.

      IMPORTANT: this context may or may not be relevant to your tasks. You should not respond to this context unless it is highly relevant to your task.
</system-reminder>
```

`MEMORY_INSTRUCTION_PROMPT` 原文（claudemd.ts:89，必须一字不差）：

```
Codebase and user instructions are shown below. Be sure to adhere to these instructions. IMPORTANT: These instructions OVERRIDE any default behavior and you MUST follow them exactly as written.
```

注入点（zig-cc）：`agent_loop.zig:buildApiMessages`（805）。在遍历 conversation 之前，**prepend 一条合成 user message**，content 为上述 `<system-reminder>` 文本。

约束：
- 仅**主 session** 注入（subagent 走 preload.zig 自己的链，不重复）。判定：opts 里加 `inject_user_context: ?[]const u8`，主 session 传文本，subagent 传 null。
- 内容**每会话算一次缓存**（避免每轮重读盘）。compact 后失效重读（对齐 cc `resetGetMemoryFilesCache`）。
- env 关闭：`CLAUDE_CODE_DISABLE_CLAUDE_MDS` 或 `--bare` → 不注入。
- `currentDate` 同条消息内随附（zig-cc 走 `util/time.zig`）。

---

## 2. 通道 B：自动记忆 memdir

参考：`cc/src/memdir/memdir.ts`、`memdir/paths.ts`、`memdir/memoryTypes.ts`；system prompt 注入 `constants/prompts.ts:495`。

### 2.1 存储路径

```
<memoryBase>/projects/<sanitized-git-root>/memory/
  ├── MEMORY.md          # 索引（always-loaded，≤200 行 / ≤25KB）
  ├── <slug-1>.md        # 一条记忆一文件
  ├── <slug-2>.md
  └── ...
```

- `memoryBase` = `$CLAUDE_CODE_REMOTE_MEMORY_DIR`（cc）→ zig-cc 用 `~/.cc-zig`（与现有 transcript/plans 同根）。
- `<sanitized-git-root>` = git 仓库根路径净化（`/` → `-` 之类）。zig-cc 复用现有 cwd_hash 或路径净化逻辑（transcript 已有 `<cwd_hash>`，可直接复用）。
- **路径投影**：`~/.claude/projects/<净化路径>/memory/`，净化规则是把绝对路径中每个 `/` 换为 `-`（包括前导 `/`）。metacodes 保持相同投影语义，自身数据写入 `~/.metacodes/projects/<净化>/memory/`。

### 2.2 四类记忆 + frontmatter

参考 `memdir/memoryTypes.ts`，taxonomy = `user | feedback | project | reference`，**显式排除可从代码/git 推出的事实**。

单条记忆文件格式（本会话 system prompt 已给模型这套规则，原样对齐）：

```markdown
---
name: <short-kebab-case-slug>
description: <one-line summary — used to decide relevance during recall>
metadata:
  type: user | feedback | project | reference
---

<事实正文；feedback/project 类型后跟 **Why:** 与 **How to apply:** 行；用 [[other-name]] 链接相关记忆>
```

四类语义：
- `user` — 用户是谁（角色、专长、偏好）
- `feedback` — 用户给的工作方式指导（纠正/确认），**必含 why**
- `project` — 进行中的工作/目标/约束，**相对日期转绝对**
- `reference` — 外部资源指针（URL、dashboard、ticket）

### 2.3 MEMORY.md 索引

- 一行一指针：`- [Title](file.md) — hook`（hook = 一句话钩子）。
- 上限 `MAX_ENTRYPOINT_LINES=200` / `MAX_ENTRYPOINT_BYTES=25_000`，超出截断（`truncateEntrypointContent`）。
- **作为 AutoMem 类型经通道 A 注入**到首条 user message，标签 `(user's auto-memory, persists across conversations)`。

### 2.4 system prompt 操作说明段（关键）

cc 在 **system prompt** 注入 `systemPromptSection('memory', ...)`（区别于 CLAUDE.md 的 user-message 注入）。内容 = 教模型如何读写记忆的完整说明（本会话 system prompt 里那段 "# Memory" 就是它）。

zig-cc：在 `core/system_prompt.zig:buildFull` 拼接列表里加一段 `MEMORY_SECTION`（仅当 memdir 启用）。内容覆盖：
- memdir 绝对路径（运行时算，注入实际路径）
- 文件格式（frontmatter + 四类）
- MEMORY.md 索引维护（一行指针，`[[name]]` 链接）
- 什么该记 / 不该记（信息价值 = 新鲜度 × 重要性 × 不可再生性；不记代码可推出的）
- 写前查重、矛盾覆盖、错误删除
- recalled 记忆在 `<system-reminder>` 内是背景非指令；引用的文件/函数/flag 用前先核实仍存在

文本以 cc 的 `loadMemoryPrompt`/`buildMemoryLines` 为骨架，融合本项目 L0 记忆原则（已在用户全局 CLAUDE.md，避免重复——只放 memdir 操作机制）。

### 2.5 写权限豁免

参考 `memdir/paths.ts:isAutoMemPath`。模型默认不能写危险目录，但 memdir 路径豁免（否则模型无法落记忆）。

zig-cc：`permission/decision.zig` 决策链加一支——目标路径在 memdir 内 → 特许写（对齐已有 plan_file 的 `isSessionPlanFile` 豁免做法，§同款实现）。安全约束：只豁免 memdir 精确子树，其它写仍按原决策。

### 2.6 启用开关

`isAutoMemoryEnabled()`：默认 **ON**；关：`CLAUDE_CODE_DISABLE_AUTO_MEMORY` / `--bare` / 设置 `autoMemoryEnabled:false`。

**不新增 Memory 工具**——对齐 cc，模型用现有 Write/Read/Grep 自管 memdir（cc 无 dedicated Memory tool）。

---

## 3. REPL 命令

### 3.1 `/memory`
参考 `commands/memory/memory.tsx` + `MemoryFileSelector.tsx`。列出已发现记忆文件 + 合成 "User memory"(`~/.claude/CLAUDE.md`) / "Project memory"(`./CLAUDE.md`) 项（即使不存在标 `(new)`）+ "Open auto-memory folder"。选中 → mkdir + `wx` 创建（保留已存在）→ `$VISUAL`/`$EDITOR` 打开。

zig-cc 现状：`/memory add/无参` 写/读 `~/.cc-zig/memory.md` 但**从不注入模型**——这条断链直接废弃，改为对齐 cc 的文件选择器 + 编辑器打开。

### 3.2 `/init`
参考 `commands/init.ts`，是 `type:'prompt'` 命令——注入大段指令让**模型**扫码库写 CLAUDE.md（`OLD_INIT_PROMPT`）。zig-cc 现状 `/init` 只建 `.cc-zig/config.json`，**名不副实**（补全描述写着 "Initialize project memory (CLAUDE.md)" 但不建）。改为 prompt 型：注入 OLD_INIT_PROMPT 风格指令引导模型分析代码库 + 写 CLAUDE.md（含标准头 `# CLAUDE.md\n\nThis file provides guidance to Claude Code...`）。

### 3.3 `#` 快捷记忆
cc **当前 build 已移除**（grep 无 `startsWith('#')` 输入模式）。zig-cc **可选不做**——优先级最低，§6 列为后续。

---

## 4. 模块划分（zig-cc 实现）

```
src/core/memory/
  ├── claudemd.zig      # 通道A加载器:递归收集 + @import + 标签拼接 + MEMORY_INSTRUCTION_PROMPT
  ├── import.zig        # @path 提取 + 递归内联 + 深度/循环/扩展名
  ├── user_context.zig  # 合成首条 <system-reminder> user message
  ├── memdir.zig        # 通道B:路径解析 + MEMORY.md 索引读取/截断 + system prompt section
  └── paths.zig         # memdir 路径净化 + isAutoMemPath 豁免判定
```

复用与重构：
- `agents/preload.zig:injectClaudeMd` **重构**为调用 `core/memory/claudemd.zig` 同一加载器（消除两份 CLAUDE.md 链逻辑）。preload 仍走 system-prompt 拼接（subagent 无 user-context 通道），但加载/解析共享。
- `agent_loop.zig:buildApiMessages` 加 prepend 逻辑（opts 传 `inject_user_context`）。
- `app.zig` init：算 memdir 路径 + 构建 user-context 文本 + 构建含 MEMORY_SECTION 的 system prompt。
- `permission/decision.zig`：加 memdir 写豁免（仿 plan_file）。

---

## 5. 测试 DoD（声明=接线=测试）

每个字段/机制必须有 L2 端到端断言（项目铁律）：

| 机制 | L2 断言 |
|------|---------|
| CLAUDE.md 注入主 session | MockServer + `lastRequest()`：首条 user message 含 `<system-reminder>` + `# claudeMd` + 文件内容 |
| 向上递归 | 临时建 `a/b/c` 三层各放 CLAUDE.md，cwd=c，断言三块都在且 c 在最后（优先级） |
| @import 递归 | CLAUDE.md 含 `@sub.md`，sub.md 含 `@subsub.md`，断言三层内容都内联 |
| @import 循环检测 | a 引 b，b 引 a，断言不无限循环、各出现一次 |
| @import 深度上限 | 6 层链，断言第 6 层不展开 |
| @import 不展开代码块 | ` ``` @x.md ``` ` 内的 @ 不展开 |
| MEMORY_INSTRUCTION_PROMPT 原文 | 字节断言含完整原文 |
| AutoMem 索引注入 | memdir 有 MEMORY.md，断言出现在 user message 且带正确标签 |
| MEMORY.md 截断 | >200 行/>25KB 断言被截 |
| system prompt memory section | MockServer 断言 system prompt 含 memory 操作说明 + memdir 路径 |
| memdir 写豁免 | decision.check 对 memdir 内路径返回 allow，对外返回原决策 |
| env 关闭 | `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` 断言 user message 无 claudeMd 段 |
| /init prompt | 断言注入的指令含 "create a CLAUDE.md" 风格文本 |

---

## 6. 明确不做 / 后续（诚实范围）

- **子目录按需加载**（attachment 触发）——依赖 attachment 系统，价值低于向上链。
- **Managed/企业级 CLAUDE.md**——留路径接口，默认不读（单机场景无意义）。
- **@import 外部路径批准对话框**——v1 直接放行 + log，后续加 UX。
- **`#` 快捷记忆**——cc 已移除，最低优先级。
- **团队记忆 TeamMem / autoDream / `/dream` / KAIROS 日志 / 后台 extractMemories / agent-memory**——外围高级功能，本轮不做。
- **conditional rules（`paths:` frontmatter glob）**——随子目录按需一起后续。

---

## 7. 证据表（cc TS 源码 file:fn，已核实）

| 机制 | 证据 |
|------|------|
| 加载链+向上递归 | `utils/claudemd.ts:getMemoryFiles`(790), docstring(1-26), `dirs.reverse()`(850-934) |
| 路径 | `utils/config.ts:getMemoryPath`(1779); managed `utils/settings/managedPath.ts:8`; `~/.claude` `utils/envUtils.ts:7` |
| @import | `extractIncludePathsFromTokens`(451), `processMemoryFile`(618), `MAX_INCLUDE_DEPTH=5`(537), `processedPaths` Set |
| 注入 | `context.ts:getUserContext`(155)→`getClaudeMds`(1153)→`utils/api.ts:prependUserContext`(449); `MEMORY_INSTRUCTION_PROMPT`(claudemd.ts:89) |
| memdir | `memdir/memdir.ts:loadMemoryPrompt`(419)/`buildMemoryLines`(199); `paths.ts:isAutoMemoryEnabled`(30)/`getAutoMemPath`(223)/`isAutoMemPath`; `memoryTypes.ts`; 注入 `constants/prompts.ts:495` |
| /memory | `commands/memory/memory.tsx`, `components/memory/MemoryFileSelector.tsx` |
| /init | `commands/init.ts`(`OLD_INIT_PROMPT`) |
| MEMORY.md 上限 | `MAX_ENTRYPOINT_LINES=200`/`MAX_ENTRYPOINT_BYTES=25_000`, `truncateEntrypointContent` |
| `#` 已移除 | grep REPL/PromptInput 无 `startsWith('#')` 记忆模式 |

## 8. zig-cc 现状基线（实现前）

| 机制 | 现状 | 证据 |
|------|------|------|
| 主 session CLAUDE.md 注入 | **无** | `buildFull`(system_prompt.zig:283) 不含 CLAUDE.md；app.zig 无首条 user-context |
| subagent CLAUDE.md 链 | 有（硬编码 4 文件，无递归无 @import） | `agents/preload.zig:injectClaudeMd`(109) |
| @import | **无** | preload `injectFile` verbatim 读 |
| /memory | 断链（写 `~/.cc-zig/memory.md` 但不注入模型） | `repl/loop.zig:handleMemory`(1714), `appendMemory`(1859), `readMemory`(1878) |
| /init | 名不副实（只建 config.json） | `repl/loop.zig:handleInit`(1385) |
| `#` 快捷 | 无 | 输入分发只处理 `/` 和 `!` |
| Memory 工具 | 无（对齐 cc，本就不该有） | tools.zig 17 工具组无 Memory |
| memdir | **无** | — |
| 注入接缝点 | `buildApiMessages`(agent_loop.zig:805) 可 prepend | 已确认结构 |
