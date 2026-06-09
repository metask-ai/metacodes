# metacodes-core — 库对外接口能力

> 可复用的 LLM 编码-agent 引擎(Zig 0.16,无 UI、无 CLI)。从 cc-zig 抽出,供其他
> Zig 项目经 `build.zig.zon` 依赖。本文档 = 库的对外接口契约(快速接入)。
>
> **架构参考**(模块职责图 + 协议契约 + 设计不变式 + 多前端接入)见 `doc/CORE_REFERENCE.md`。

## 1. 是什么

`metacodes-core` 是一个命名 Zig module(root = `src/lib.zig`),包含:**agent 主循环**(请求→流式→工具调用→重复)、**工具集**(Read/Write/Edit/Bash/Grep/Glob/CodeMap/FindSymbol/Task/…)、**权限系统**、**MCP/Skill/Subagent**、**协议层**(core↔前端契约)、以及两个**参考 backend**(打印型 / headless-JSON)。

**不含**任何 UI/CLI:REPL、TUI 渲染、终端对话框、命令行解析都留在宿主 app(`src/repl/`、`src/app.zig`、`src/main.zig`),不在库里。`src/lib.zig` 可达的模块图物理上够不到 UI 层 —— `zig build test:lib`(`refAllDecls` 编全图)即编译器证明此隔离。

## 2. 安装

宿主 `build.zig.zon` 加依赖:
```zig
.dependencies = .{
    .metacodes_core = .{ .path = "../cc-zig" }, // 或 .url + .hash 远程拉
},
```
宿主 `build.zig`:
```zig
const dep = b.dependency("metacodes_core", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("metacodes-core", dep.module("metacodes-core"));
```
**注意**:① 库经 `tools/*` 用 tree-sitter,模块自带 C 源(随 module 传入,无需消费方再接——切勿重复 `addCSourceFile`,否则 duplicate symbol)。② 需 `link_libc`。③ 程序入口用 `pub fn main(init: std.process.Init)`(库的 `Client.init` 要 `init.io`)。

代码里:`const mc = @import("metacodes-core");`

## 3. 核心类型与 run() 契约

### run()
```zig
pub fn run(
    conversation: *Conversation,                    // 对话历史(in/out:turn 结束后含新消息)
    api_client: *client.Client,                     // API 连接
    tool_defs: []const json.ToolDefinition,         // 暴露给模型的工具(可空)
    permission_ctx: *const permission.PermissionContext,
    opts: Options,
    backend: *const UiBackend,                      // 前端(emit 事件 / poll 输入)
    allocator: std.mem.Allocator,
) !RunResult
```
驱动 turn loop:组装 API 消息 → 流式请求(发 `text_chunk`)→ 模型若调工具则权限检查+执行(发 `tool_start`/`tool_result`)→ 工具结果回灌 → 再请求,直到模型不再调工具(`end_turn`)或触顶。

```zig
pub const RunResult = struct { stop_reason: StopReason, turns: u32, tool_calls: u32 };
pub const StopReason = enum { end_turn, max_turns, aborted, tool_error, api_error, tool_loop };
```

### Options(全可选,`.{}` 即最简跑)
关键字段:`max_turns`(默认 50)、`system_prompt`、`abort: ?*AbortSignal`、`emit_tool_cards: bool`(是否发 tool_start/result 事件,前台 UI=true,headless=false)、`colorize: bool`、`usage_sink`、`auto_compact_threshold`、各注册表(`jobs`/`tasks`/`agents`/`dyn_registry`/`mcp_sessions`/`cron_registry`)、`ui_request_fn`(工具→UI 阻塞请求,见 §5)。**模式**:几乎所有字段是可选指针/默认值,`null`/缺省 = 走简化路径(无该能力),适合从最小用法逐步加。

### CoreEvent(backend.emit 收到的;**slice 是借,同步消费,返回前拷走**)
```zig
text_chunk: []const u8            // assistant 文本流
stream_begin / stream_done        // 一轮流式起止(前端决定颜色/换行)
tool_start: { id, name, input }   // 工具开始
tool_progress: { id, text }       // 工具执行中进度
set_current_tool / clear_current_tool   // 底部 spinner 喂/清
tool_result: { id, name, input, content, is_error, elapsed_ms }
usage: UsageDelta                 // token 增量
phase_change: Phase               // input ↔ generating
auto_compact: { dropped, kept }   // 历史压缩
retry_notice: { attempt, max, delay_ms }  // 建连重试
```

## 4. 实现自定义前端(UiBackend)

```zig
pub const UiBackend = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, ev: CoreEvent) void,   // core→UI,同步,借 slice
    poll: *const fn (ctx: *anyopaque) ?UiEvent,              // UI→core,非阻塞,无事件返 null
};
```
三件事:① 实现 `emit`(按 `CoreEvent` 变体渲染/转发);② 实现 `poll`(返回 `.interrupt`/`.queue_message` 或 null);③ 包成 `UiBackend{ .ctx=@ptrCast(self), .emit=…, .poll=… }`。

`poll` 返回 `UiEvent`:
```zig
interrupt: abort.Reason        // esc/ctrl+c/语音"停"
queue_message: []const u8      // 生成期入队的用户消息(in-process 转移所有权,调用方 free)
```

**CoreEvent → 前端该做什么**(对照):text_chunk=追加助手文本;tool_start=显示"调用 X";tool_result=显示结果(is_error 标红);tool_progress=刷新进度;set/clear_current_tool=spinner;usage=累计 token;auto_compact/retry_notice=提示行;stream_begin/done=可忽略或控制颜色。**最简前端只需处理 text_chunk + tool_result,其余 `else => {}`。**

## 5. 工具 → UI 请求(AskUserQuestion / 权限 / 计划审批)

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

## 6. 参考 backend(库自带,可直接用或当模板)

- `mc.writer_backend.WriterBackend` —— 把 CoreEvent 渲染成文本写进一个 sink(`fn(ctx, []const u8)`)。适合管道/日志/非交互。
- `mc.headless_backend` —— 把 CoreEvent 序列化成 JSON(每事件一行)。适合 RPC/前后端分离。

## 7. 最小示例(完整可跑见 `example/main.zig`,`zig build example`)

```zig
const mc = @import("metacodes-core");
const PrintBackend = struct {
    fn emit(_: *anyopaque, ev: mc.protocol.ui_event.CoreEvent) void {
        switch (ev) {
            .text_chunk => |t| std.debug.print("{s}", .{t}),
            .tool_result => |r| std.debug.print("\n[{s}] err={}\n", .{ r.name, r.is_error }),
            else => {},
        }
    }
    fn poll(_: *anyopaque) ?mc.protocol.ui_event.UiEvent { return null; }
};
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    var client = mc.client.Client.init(a, init.io, key, "claude-3-5-haiku-20241022");
    var conv = mc.conversation.Conversation.init(a); defer conv.deinit();
    try conv.appendText(.user, "hello");
    var perm = mc.permission.PermissionContext{ .allocator = a };
    var pb = PrintBackend{};
    const be = mc.protocol.ui_backend.UiBackend{ .ctx=@ptrCast(&pb), .emit=PrintBackend.emit, .poll=PrintBackend.poll };
    _ = try mc.agent_loop.run(&conv, &client, &.{}, &perm, .{ .max_turns=2 }, &be, a);
}
```

## 8. 线程与所有权

- `emit` 可能在**工具线程**调用(如 `tool_progress` 来自后台子请求);前端 emit 实现须线程安全或只在自己的事件循环里处理。
- CoreEvent 的 slice 是**借用**,emit 返回即失效 —— 需保留就拷贝。
- `UiEvent.queue_message` 与 `UiResponse.answers`:in-process 时所有权转移给接收方(用完 free);序列化传输时是值拷贝。
- `run()` 在调用线程同步跑完整轮循环;`Options.abort` 用于跨线程中断(SIGINT handler / UI 线程戳 AbortSignal)。

## 9. 跑 example 的两种方式

```bash
# 真端点(需有效 key;不设则用仓库内置 demo token)
METACODES_API_KEY=sk-... zig build example
# 离线:把 Client 指向仓库自带 mock server(改 example 用 Client.initWithBaseUrl 指 mock_sse_server)
```
连接失败时 example 内 `catch` 打印 run error 后正常退出(不崩),便于离线验证接线。
