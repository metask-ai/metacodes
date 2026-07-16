# metacodes — 库对外接口能力

> 可复用的 LLM 编码-agent 引擎(Zig 0.16,无 UI、无 CLI)。**agent loop 核心**可作为库被
> 外部消费。本文档 = 库的对外接口契约(快速接入)。
>
> **架构参考**(模块职责图 + 协议契约 + 设计不变式 + 多前端接入)见 `doc/CORE_REFERENCE.md`。

## 1. 是什么

核心引擎包含:**agent 主循环**(请求→流式→工具调用→重复)、**工具集**(Read/Write/Edit/Bash/Grep/Glob/CodeMap/FindSymbol/Task/…)、**权限系统**、**MCP/Skill/Subagent**、**多 provider**(Anthropic/OpenAI/Gemini)、**协议层**(core↔前端契约)、以及两个**参考 backend**(打印型 / headless-JSON)。

**不含**任何 UI/CLI:REPL、TUI 渲染、终端对话框、命令行解析都留在宿主 app(`src/repl/`、`src/app.zig`、`src/main.zig`),不在库里。`src/lib.zig` 可达的模块图物理上够不到 UI 层 —— `zig build test:lib`(`refAllDecls` 编全图)即编译器证明此隔离。

> 注:这个"核心"不是裸循环 —— 它是**整个非 UI 引擎**(loop + 全工具 + 3 provider + 协议 + 权限/沙箱 + 高亮)。ReleaseSmall 静态库 ~1.1MB TEXT。TUI 是独立一层,不在其中。

## 2. 消费方式:两个交付物、三种路径

按"是否需要 core 源码 + 是否 Zig"分:

| 消费方 | 用哪个交付物 | 要 core 源? | 序列化开销 |
|--------|--------------|:---:|:---:|
| Zig(要极致性能/全类型) | **`metacodes-core`** Zig 模块 | 是 | **零**(直传结构) |
| Zig(不想编 core 源) | **`metacodes_agentcore`** 二进制包 + Zig SDK | 否 | 富数据 JSON |
| C / Rust / Go / … | **`metacodes_agentcore`** `.a` + `.h` | 否 | 富数据 JSON |

### 2A. `metacodes-core` —— Zig 原生源码包(§3–§9 详述)

- 身份:`build.zig.zon .name = .metacodes_core` + `b.addModule("metacodes-core")`(root=`src/lib.zig`)。
- 引用:宿主 `build.zig.zon` 加依赖(见 §3),`@import("metacodes-core")`。
- 机制:**源码级** —— core 源随宿主按自身 `optimize` 重编进其二进制。
- 特点:**零序列化**(`CoreEvent` 结构经 vtable 直传)、全 Zig 类型、编译期类型安全。
- 现成消费者:`example/`(`zig build example` 真跑);`test:lib` 守 UI 隔离。

### 2B. `metacodes_agentcore` —— 跨语言二进制包(C ABI)

`zig build agentcore:bundle -Dtarget=<triple> -Doptimize=ReleaseSmall` 产出自包含一套:
```
zig-out/lib/libmetacodes_agentcore.a    ← 静态库
zig-out/include/metacodes_agentcore.h   ← C 头
zig-out/sdk/metacodes_agentcore.zig     ← Zig 便利层(source-free,不 import core 源)
zig-out/sdk/metacodes_agentcore_protocol.zig
zig-out/sdk/metacodes_agentcore_types.zig
        + manifest(scripts/write_agentcore_manifest.sh 生成)
```
- 引用:C/Rust/Go/… link `.a` + include `.h` → 调 **单入口** `metacodes_agentcore_get_api(1)` 拿函数指针表(vtable):`runtime_create/destroy`、`session_create/destroy`、`session_run`(=agent loop)、`session_abort`、`buffer_release`。
- 机制:**单符号 + 版本协商** = 稳定 ABI；当前 v1 要求精确 struct size，破坏性扩展须新增 v2 table，不能在 v1 静默追加槽。富数据(事件流/UI 请求/工具结果)走独立冻结的 **AgentCore protocol v1 JSON**，不直接暴露内部 frontend/daemon `CoreEvent`；配置/结果走 **POD struct**(头文件 `_Static_assert` 锁布局)。
- source-free Zig:经 `sdk/metacodes_agentcore.zig`(`extern fn` link 预编译 `.a`,不要 core 源)。`agentcore:consumer` step 测这条。
- 契约测试:`agentcore:test`(ABI v1 布局 + typed protocol + C 头编译 + Zig↔C 往返)。正式 ReleaseSafe bundle 默认 strip DWARF，manifest 记录并校验 strip 设置。

> **选型一句话**:Zig 且在意零开销 → 吃源码包 `metacodes-core`;一切"不编源码"(跨语言 + source-free Zig)→ 走二进制包 `metacodes_agentcore`。

---

以下 §3–§9 是 **`metacodes-core` Zig 源码包**的接口契约。二进制包的 C 语义见 `sdk/metacodes_agentcore.h`。

## 3. 安装(metacodes-core Zig 模块)

宿主 `build.zig.zon` 加依赖:
```zig
.dependencies = .{
    // 本地并列 checkout:
    .metacodes_core = .{ .path = "../metacodes" },
    // 或远程:.metacodes_core = .{ .url = "git+https://…/cc-t2z#<rev>", .hash = "…" },
},
```
宿主 `build.zig`:
```zig
const dep = b.dependency("metacodes_core", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("metacodes-core", dep.module("metacodes-core"));
```
**注意**:① 高亮由 **highlight-zig**(纯 Zig submodule,`lib/highlight-zig`)提供,随 core 模块传入 —— 消费方无需再接,**无 C 源**(2026 已从 tree-sitter 迁走,不再有 `addCSourceFile`/duplicate-symbol 顾虑)。② 需 `link_libc`。③ 程序入口用 `pub fn main(init: std.process.Init)`(`Client.init` 要 `init.io`)。④ 远程依赖需 `--recurse-submodules`(highlight-zig 走 submodule)。

代码里:`const mc = @import("metacodes-core");`

## 4. 核心类型与 run() 契约

### run()
```zig
pub fn run(
    conversation: *Conversation,                    // 对话历史(in/out:turn 结束后含新消息)
    provider: api_provider.Provider,                // 中立 provider vtable(**值**,非 *Client)
    tool_defs: []const json.ToolDefinition,         // 暴露给模型的工具(可空)
    permission_ctx: *const permission.PermissionContext,
    opts: Options,
    backend: *const UiBackend,                      // 前端(emit 事件 / poll 输入)
    allocator: std.mem.Allocator,
) !RunResult
```
`provider` 从 Client 取:`var client = mc.client.Client.init(a, io, key, model); … client.provider()`。多 provider 重构后 `run` 收中立 `Provider`(vtable),背后是 Anthropic / OpenAI / Gemini 对 core 透明。

驱动 turn loop:组装 API 消息 → 流式请求(发 `text_chunk`)→ 模型若调工具则权限检查+执行(发 `tool_start`/`tool_result`)→ 工具结果回灌 → 再请求,直到模型不再调工具(`end_turn`)或触顶。

```zig
pub const RunResult = struct { stop_reason: StopReason, turns: u32, tool_calls: u32 };
pub const StopReason = enum { end_turn, max_turns, aborted, tool_error, api_error, tool_loop };
```

### Options(全可选,`.{}` 即最简跑)
关键字段:`max_turns`(默认 50)、`system_prompt`、`abort: ?*AbortSignal`、`emit_tool_cards: bool`(是否发 tool_start/result 事件,前台 UI=true,headless=false)、`colorize: bool`、`usage_sink`、`auto_compact_threshold`、`session`(多 session 归属)、`ui_request_fn`(工具→UI 阻塞请求,见 §6)、各注册表(`jobs`/`tasks`/`agents`/`dyn_registry`/`mcp_sessions`/`cron_registry`)。**模式**:几乎所有字段是可选指针/默认值,`null`/缺省 = 走简化路径,适合从最小用法逐步加。

### CoreEvent(backend.emit 收到的;**slice 是借,同步消费,返回前拷走**)
```zig
text_chunk: []const u8            // assistant 文本流
stream_begin / stream_done        // 一轮流式起止(前端决定颜色/换行)
tool_start: { id, name, input }   // 工具开始
tool_progress: { id, text }       // 工具执行中进度
set_current_tool / clear_current_tool   // 底部 spinner 喂/清
progress: { turn, tool_name, tool_input, tool_calls }
tool_result: { id, name, input, content, is_error, elapsed_ms }
usage: UsageDelta                 // token 增量
auto_compact: { dropped, kept, before_tokens, after_tokens }  // 历史压缩
retry_notice: { attempt, max, delay_ms }  // 建连重试
context_warning: { current_tokens, warning_threshold, … }     // 上下文压力
config_changed / session_lifecycle / agent_lifecycle / tasks_changed  // 状态变更
diag_*                            // 诊断事件(turn_begin/end/breaker/cache_break/…),TeeBackend 建 span 树
```
> **无 `phase_change`** —— 该变体从未落地(旧文档误列)。生成/输入相位由 `stream_begin`/`stream_done` + `set/clear_current_tool` 表达。

## 5. 实现自定义前端(UiBackend)

```zig
pub const UiBackend = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, session: SessionId, ev: CoreEvent) void,  // core→UI,同步,借 slice
    poll: *const fn (ctx: *anyopaque, session: SessionId) ?UiEvent,             // UI→core,非阻塞,无事件返 null
};
```
三件事:① 实现 `emit`(按 `CoreEvent` 变体渲染/转发;`session` 参数=事件归属会话,单会话可忽略);② 实现 `poll`(返回 `.interrupt`/`.queue_message` 或 null);③ 包成 `UiBackend{ .ctx=@ptrCast(self), .emit=…, .poll=… }`。

`poll` 返回 `UiEvent`:
```zig
interrupt: abort.Reason        // esc/ctrl+c/语音"停"
queue_message: []const u8      // 生成期入队的用户消息(in-process 转移所有权,调用方 free)
```

**CoreEvent → 前端该做什么**(对照):text_chunk=追加助手文本;tool_start=显示"调用 X";tool_result=显示结果(is_error 标红);tool_progress=刷新进度;set/clear_current_tool=spinner;usage=累计 token;auto_compact/retry_notice/context_warning=提示行;stream_begin/done=可忽略或控制颜色;diag_*=诊断可忽略。**最简前端只需处理 text_chunk + tool_result,其余 `else => {}`。**

## 6. 工具 → UI 请求(AskUserQuestion / 权限 / 计划审批)

工具需要用户输入时,经 `Options.ui_request_fn`(同步阻塞)统一发请求 —— 一个回调覆盖三类:
```zig
pub const UiRequestFn = *const fn (state: *anyopaque, allocator, req: *const UiRequest, out: *UiResponse) anyerror!void;
pub const UiRequest = union(enum) {
    ask_question: []const AskQuestion,                          // AskUserQuestion
    permission: struct { tool: []const u8, args: []const u8 },  // 权限确认
    plan_approval: struct { plan_md: []const u8 },              // ExitPlanMode 审批
};
pub const UiResponse = union(enum) {
    answers: []const []const u8,             // owned by allocator,caller free
    permission: protocol.PermissionChoice,   // allow_once/allow_always/deny_once/deny_tool_session
    plan_approval: PlanApproval,
};
```
不设 `ui_request_fn`(headless/子 agent)→ 工具按语义兜底(ask→NotATty,权限→文字 prompt/deny)。

## 7. 参考 backend(库自带,可直接用或当模板)

- `mc.writer_backend.WriterBackend` —— 把 CoreEvent 渲染成文本写进一个 sink(`fn(ctx, []const u8)`)。适合管道/日志/非交互。
- `mc.headless_backend` —— 把 CoreEvent 序列化成 JSON(每事件一行)。适合 RPC/前后端分离。

## 8. 最小示例(完整可跑见 `example/main.zig`,`zig build example`)

```zig
const mc = @import("metacodes-core");
const PrintBackend = struct {
    fn emit(_: *anyopaque, _: mc.session_id.SessionId, ev: mc.protocol.ui_event.CoreEvent) void {
        switch (ev) {
            .text_chunk => |t| std.debug.print("{s}", .{t}),
            .tool_result => |r| std.debug.print("\n[{s}] err={}\n", .{ r.name, r.is_error }),
            else => {},
        }
    }
    fn poll(_: *anyopaque, _: mc.session_id.SessionId) ?mc.protocol.ui_event.UiEvent { return null; }
};
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    var client = mc.client.Client.init(a, init.io, key, "claude-3-5-haiku-20241022");
    var conv = mc.conversation.Conversation.init(a); defer conv.deinit();
    try conv.appendText(.user, "hello");
    var perm = mc.permission.PermissionContext{ .allocator = a };
    var pb = PrintBackend{};
    const be = mc.protocol.ui_backend.UiBackend{ .ctx=@ptrCast(&pb), .emit=PrintBackend.emit, .poll=PrintBackend.poll };
    _ = try mc.agent_loop.run(&conv, client.provider(), &.{}, &perm, .{ .max_turns=2 }, &be, a);
}
```

## 9. 线程与所有权

- `emit` 可能在**工具线程**调用(如 `tool_progress` 来自后台子请求);前端 emit 实现须线程安全或只在自己的事件循环里处理。
- CoreEvent 的 slice 是**借用**,emit 返回即失效 —— 需保留就拷贝。
- `UiEvent.queue_message` 与 `UiResponse.answers`:in-process 时所有权转移给接收方(用完 free);序列化传输时是值拷贝。
- `run()` 在调用线程同步跑完整轮循环;`Options.abort` 用于跨线程中断(SIGINT handler / UI 线程戳 AbortSignal)。

## 10. 跑 example 的两种方式

```bash
# 真端点(需有效 key;不设 METACODES_API_KEY 则打印提示后正常退出——内置 demo token 已随多 provider 重构移除)
METACODES_API_KEY=sk-... zig build example
# 离线:把 Client 指向仓库自带 mock server(改 example 用 Client.initWithBaseUrl 指 mock_sse_server)
```
连接失败时 example 内 `catch` 打印 run error 后正常退出(不崩),便于离线验证接线。
