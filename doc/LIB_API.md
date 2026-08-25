# metacodes 嵌入接口

metacodes 有两条互补的嵌入路径。源码级 Zig Host 使用
`metacodes-core`；不把实现源码加入构建图的 Host 使用独立 AgentCore
二进制包。两条路径都保留同一个内核所有权：AgentLoop、Conversation、
权限/沙箱、取消、预算、Lean 判定、TinyKG CAS 与持久化不是插件能力。

插件契约见 `doc/PLUGIN_ARCHITECTURE.md`，二进制 ABI 的 normative 语义见
`doc/AGENTCORE_BINARY_ABI.md`。首方核心能力包、热替换语义和准确宿主矩阵见
`doc/CORE_PLUGIN_HOTSWAP.md`。

## 1. 源码级 Zig Host

`src/lib.zig` 导出 UI-neutral 的 `AgentRuntime` / `AgentSession`、typed
`CoreEvent` / `UiRequest`、Host tool callback 和插件 contract。它不导出
CLI、TUI 或 Web 实现。

`example/main.zig` 是独立消费 fixture：Host 注册一个 `static_trusted` 插件，把首方
核心能力从 `minimal` 热替换为 `coding`，读取两代不可变插件清单，创建 Session，
并通过 `EventSink` 消费流式事件。

### 外部 Zig 项目的 build 接线

把仓库作为 `build.zig.zon` 的 Git 或本地路径依赖后，在宿主 `build.zig` 中取得
同一个 `metacodes-core` 模块；不要重新导入 `src/` 下的内部文件，也不要手工复制
`highlight-zig`。下面的接线方式适用于 Zig 0.16：

宿主先在自己的 `build.zig.zon` 中声明依赖别名（本地开发示例）：

```zig
.dependencies = .{
    .metacodes = .{ .path = "../metacodes" },
};
```

发布构建应把同一个 `.metacodes` 别名改为固定 Git commit 的 URL/hash。

```zig
const metacodes = b.dependency("metacodes", .{
    .target = target,
    .optimize = optimize,
});
const app_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
app_mod.addImport("metacodes-core", metacodes.module("metacodes-core"));
```

`build.zig.zon` 中的依赖必须固定到审计过的 Git commit 或组织内部的路径版本；发布
包的 URL/hash 由宿主自己的供应链策略决定，不应使用浮动分支。完成接线后，宿主代码
通过 `@import("metacodes-core")` 访问 `agent_session`、`agent_loop`、`protocol` 等
命名空间；`zig build example` 是可运行的同仓消费者 fixture。

```sh
# 无密钥也会完成 Runtime/插件组装并打印清单
env -u METACODES_API_KEY zig build example

# 可选：跑一轮真实 AgentSession
METACODES_API_KEY=sk-... zig build example
```

直接管理一个固定代 Runtime 的核心生命周期是：

1. Host 构造 `AgentRuntime`，选择首方 `core_profile`，或用非 null
   `builtin_tools` 保留显式兼容覆盖，并传入兼容 Host tools、
   `StaticPlugin` 描述符或显式 `ProcessPlugin` package source；
2. Runtime 原子验证并持有一个不可变插件 snapshot；静态插件可在依赖序 activation
   中登记由该 snapshot 所有的同步 cleanup；
3. Host 用显式 workspace、provider、权限模式和工具 allow-list 创建
   `AgentSession`；
4. `runText` 同步运行，事件回调返回 `false` 会 poison Session；另一个线程
   可以按精确 `run_id` 调用 abort；
5. 先销毁所有 Session，最后销毁 Runtime。活跃 Session 会使 Runtime 销毁返回
   `RuntimeBusy`；成功销毁时插件 cleanup 按注册逆序恰好执行一次。Host callback 与
   activation cleanup context 必须活到 Runtime 销毁成功。

需要运行时更新的 Zig Host 使用 `RuntimeHost` 作为组合根。`createSession` 把会话固定
在当时的 immutable generation；`replace(new_config)` 先完整校验、投影并激活候选
Runtime，成功后才原子切换新会话入口。旧会话继续使用旧目录和 effect，最后一个旧
会话销毁时旧 Runtime 自动回收。候选构造失败不会消耗 generation，也不会改动现役
Runtime。`RuntimeHost.destroy` 停止新会话接纳，但已存在的 Session 可继续运行并在
最后释放时完成清理，因此 Session 可以安全晚于 Host owner 退出。

首方 profile 的稳定配置名是 `none`、`minimal`、`offline-coding`、`coding`、
`coding-interactive`；源码 API 对应 `agent_session.CoreProfile`。默认 `coding` 精确保留
旧默认工具面。profile 通过 `builtin_tool_bundle` 投影成原生 `ToolEntry`，不会给
Read/Write/Bash 等热路径增加 callback 或进程 hop。

Host tool 的结果带显式 `releaseFn`；Runtime 深拷贝描述符，但不拥有 callback
context。不同 Session 的 callback 可以并发，锁由 Host 自己负责。Session 内同一
时刻只允许一个 mutating/run/checkpoint 操作，非法并发返回 typed lifecycle error。
同一个 `host_tool` capability 可以通过 `StaticPlugin.tools` 提供有界 UTF-8 完成缓冲，
也可以通过 `StaticPlugin.stream_tools` 提供 byte-zero `HostStreamTool`；两者在同一
immutable snapshot 中统一命名、判重、广告、权限和 CAS 接线。顶层
`RuntimeConfig.host_sync_tools/host_stream_tools` 只是保留全局名字的 compatibility
plugin 投影，不再绕过插件目录。

`StaticPlugin.activation` 是源码级可信扩展的事务边界。回调只能通过借用的
`EffectScope.Registrar` 登记 `{label, context, CleanupFn}`，不能取得可变 AgentLoop、
Permission、Lean 或 TinyKG handle。activation 失败会回滚此前所有插件 effect，且
不会返回半初始化 Runtime；cleanup 为同步无错误函数，避免所有权释放后再打开错误
通道。当前提供的是完整 Runtime 的不可变代际替换，不提供单插件原地 HMR、任意
dylib 加载，也不把活跃 Session 的 catalog 改写为新代。

源码级静态插件还可声明 `service` capability。provider 在 activation 中调用
`Registrar.provide(T, local_name, pointer, cleanup)`，consumer 只有在 descriptor 的
`requires` 明确包含 provider 时，才能用相同 `T` 与 key 调用 `require`。解析发生在
依赖拓扑序 activation 中；consumer 把返回指针注入自己的 Host tool/context，commit
之后没有可变 service lookup。该能力不进入 AgentCore v1 revision 13 C ABI，也不暴露任何内核
service。

`advisory_hook` capability 接受一个 `StaticPlugin.advisory_policy`。它是同步、借用、
只返回布尔上限的接口：多个插件和 Host 的 per-Run policy 全部取交集。`false` 可从
provider schema 隐藏工具或在 dispatch 前拒绝具体参数；`true` 只表示继续执行原生
permission/workspace/sandbox/formal 链，绝不表示授权。callback context 与 Host tool
一样必须活到对应 Runtime generation 清理完成。v1 不允许插件在此改写输入、伪造
审批或替换工具结果。

`provider_dialect` 同样只接受 `static_trusted` 源码级扩展。Dialect callback 必须是
显式参数的确定性纯函数，不得把 generation、plugin id、时间、随机数或加载路径写进
请求；等价 Runtime replacement 因而保持 provider request 字节一致与 prefix cache 命中。

`provider_dialect` capability 接受一组 `StaticPlugin.provider_dialects`。每项用
`provider_kind + model_prefix` 把一个 `api_dialect.Dialect` 绑定到当前 immutable
Snapshot；最长前缀优先，重复 key 会使 staging 整体失败。Session 创建、model replacement
和 Session 内隔离 Provider 都使用该 Snapshot 的 Resolver，因此旧 Session 不会被新代
改写。Dialect 可以覆盖 ModelProfile、请求字段/system modifier 与响应 reasoning 提取，
但不能取得凭据、替换 HTTP/SSE transport 或绕过工具/权限/formal 管线。

`api_dialect.VisibleCapabilities` 是请求级、强类型的可见能力投影；当前包含
`skill_tool` 与至多一个 `required_first` exact route。Anthropic/OpenAI/Gemini serializer
都从真实 ToolDefinition slice 生成它，再调用 `Dialect.activateCapabilities` 和
`Dialect.routeToolChoice`。插件因此能针对某类模型调整能力调用表达，但不能虚构一个未广告
的工具。Skill frontmatter 的 `model-activation: required-first` 只有在唯一可见时才产生
`Skill(name=<invocation>)` route；冲突时回退普通选择，exact 调用的成功配对结果后才释放。
AgentLoop 会在任何 provider 方言之上拦截激活前的非 exact 工具，并对忽略 forced choice 的
网关作最多两次有界修复；方言路由不是授权，也不是唯一正确性防线。若只需要 metacodes
的稳定 Skill tool-first 文案，可复用
`api_capability_activation.injectStrictSkillToolFirst`。

缓存合同是 provider-visible bytes，而不是 generation：plugin inventory/id/version/path/
generation 不进入 system prompt 或 tool schema；等价配置跨 generation 生成相同请求字节。
`model_activation` 自身也不进入 tool schema，只由方言确定地投影为 system/tool-choice；
有效工具、route 或 dialect 输出实际改变时才形成新的缓存前缀。压缩隐藏旧 call/result 后，
Host 以不序列化的 `satisfied` 元数据继续携带激活态，system/tool schema 字节不变且不会重复
forced route。

`ProcessPlugin` 走另一条信任路径：Runtime 在 publish 前读取严格 manifest/process
配置、校验 entrypoint SHA-256 并完成握手；每次工具调用起一个受取消、超时和输出
上限约束的短生命周期进程。它不需要 Host callback identity，也拿不到任何内核指针。
具体 package/wire 合同见 `doc/PLUGIN_PROCESS_PROTOCOL.md`。

### Tool Result 数据面

源码级工具的统一返回类型是 `core.tool_result.ToolResultBody`：

```zig
const ToolResultBody = union(enum) {
    @"inline": InlineResult,
    artifact: ArtifactReceipt,
    structured_error: StructuredToolError,
};
```

`ToolEntry.execute` 是 `ToolExecutor` tagged union：兼容工具显式走 `legacy_inline`
adapter；需要控制峰值内存的原生工具走 `result_body`，在开始生成结果前调用
`tool_result_artifact.Capture.begin`/`Spool.begin`，分片 `write`，最后返回 typed inline、
receipt 或 bounded structured error。两种 executor 不能同时存在，也不能都缺失。
`ToolEntry.result_production` 进一步区分 `bounded_inline`、`input_derived` 与
`byte_zero_spool`，并在 comptime 禁止 byte-zero 声明接到 legacy callback。
`StructuredToolError` 只接受不超过 1 MiB 的 `{"error": {...}}` JSON 对象。

首方 byte-zero 工具为 `Glob`、`Grep`、`CodeMap`、`FindSymbol`、`Bash`、
`ListMcpResourcesTool`、`ReadMcpResourceTool` 和 `WebFetch`。Bash 的 JobRegistry、
MCP stdio、大型 WebFetch/curl、ripgrep 与代码索引输出都在子进程/生产者发出第一个字节前
取得私有 capture；小而完整的最终投影仍可安全降为 inline。`Write`、`Edit`、
`ApplyPatch`、`NotebookEdit` 明确归类为 `input_derived`：它们不复制一个未知外部输出流，
不能与 byte-zero 迁移缺口混为一谈。

Spool 在固定内存中增量计算 SHA-256、保存 1152-byte head 与 384-byte rolling tail，
并以 no-replace 原语原子发布到 Session 级 CAS；POSIX hard-link 发布会在 receipt
逃逸前同时持久化源/目标目录，竞争者不能覆盖同名 CAS 对象，失败路径只回滚本次精确
文件身份。单 artifact 上限 128 MiB，Session 上限 1 GiB。
`ReadArtifact` 每次最多恢复 32 KiB。结果的模型可见 envelope 是确定性的，不包含临时
路径、plugin generation、时间或随机数。

`ArtifactStoreConfig` 明确区分 `disabled`、`exact_root` 与
`session_under_workspace_home`。启用 artifact store 的 `AgentSession` 会从首方 kernel
插件自动选择 `ReadArtifact`；不会回退或放宽到其他全局 built-in。AgentCore 固定使用
`<workspace.home|root>/.metacodes/agentcore/sessions/<logical_session_id>`，restore 复用
同一路径，因此模型收到的恢复指令在 Host-only、MCP 和 process-plugin 会话中都闭合。

### Durable execution profile

源码级 `SessionConfig.run_journal` 是 tagged union：`ephemeral`（默认、零 journal
I/O）、`exact_root` 或 `session_under_workspace_home`。durable profile 使用已有
`tool_observation_journal` 作为唯一 provider/tool execution evidence，不创建第二套
Operation log。每个物理 provider attempt 和实际 tool dispatch 都形成先 intent、后
result 的闭合对；fork Skill 也通过 `RunExecutionEvidence` 进入同一边界。

工具 catalog 的 `ReplayDeclaration` 只是候选分类。内核只自动保留 `read_only`；
`idempotent`/`reobservable` 没有 invocation-bound operation key 或 receipt 时降级为
`never`。`run_recovery.Reducer` 对任意 crash prefix 给出确定性 retry/probe/interrupted
方向，但当前公开 API 只负责 durable evidence 与 fail-closed 检测，不执行 active-Run
原地恢复。journal、replay metadata 和 effect driver 都不进入 Conversation、system
prompt 或工具 schema，因此启用 durability 不改变 prompt-cache key。

## 2. 插件清单协议

同一份只读 JSON 可从三种 Host 入口获取：

- Zig：`AgentRuntime.describePlugins(allocator)`；
- CLI：`metacodes --dump-plugins [--plugin-dir <root> ...] [--process-plugin-dir <root> ...]`；
- Web：`GET /state` 的 `plugin_inventory` 字段。

CLI 清单模式不要求登录、不消耗 runtime credential，也不发网络请求。Schema
标识为 `metacodes.plugin-inventory/v1`，包含 contract version、generation、
插件 id/version/form/layer/lifecycle、capabilities、贡献数和数据包来源根目录。
它只暴露不可变 provenance/configuration，不暴露凭据、callback 指针、权限状态、
Conversation、Lean 或 TinyKG handle。

CLI 与 Web 复用 App 的同一个 snapshot；Zig Host 复用 AgentRuntime 的同一个
snapshot。清单可审计和持久化，但不是可变插件 handle，也不能用于绕过 native
admission。

## 3. AgentCore 二进制包

AgentCore 面向不把 metacodes 源码加入构建图的原生 Host：

| Host | 交付物 |
|---|---|
| C11 | `<metask/agentcore.h>` + 静态库 |
| C++17 | 同一 C Header（含 `extern "C"`）+ 静态库 |
| Zig | `bindings/zig` + 静态库 |
| Rust | `metask-agentcore-sys` + 静态库 |

消费入口只有：

```c
/* Returns const void *; cast to const metask_agentcore_api_v1 * after
 * validating version, revision, table size, and capabilities. */
const void *metask_agentcore_get_api(uint32_t requested_abi);
```

当前是实验性的 ABI v1 revision 13。Host 必须同时校验 abi version、精确
revision、table size、capability bitset、reserved fields 和 manifest hash；不存在
静默降级或旧 revision shim。该表已经覆盖 Runtime/Session、同步 run、跨线程
abort、流式事件、typed UI request/response、checkpoint/restore、权限规则、MCP、
Workspace Skill 与独立 Completion。ownership、回调重入、Session poison、并发和
持久化语义只以同 revision Header 与 `AGENTCORE_BINARY_ABI.md` 为准。

revision 13 的 `runtime_create_with_plugins` 接受显式、绝对路径的
`ProcessPluginSourceV1` 数组。AgentCore 在返回前完成 strict manifest/process 配置、
entrypoint SHA-256、握手与工具 schema 校验，并复制不可变 Runtime 状态；原有
`RuntimeConfigV1` 仍保持 96 字节，旧 `runtime_create` 继续表示“无进程插件”。
同一配置还接受独立的 `HostStreamToolV1` 数组；内核在回调前创建 Session CAS
spool，Host 只持有同步、借用、只写 sink，不能提交、回滚或保留它。Revision 13
还要求每个 `McpConnectorV1` 提供 `request_tool_stream`：普通 `request` 只处理有界
控制帧，`tools/call` 的完整 JSON-RPC 响应从 byte zero 写入内核 capture，经流式
校验后仅成功 `result` 区间可进入同一 CAS。
`SessionHostConfigV1.run_journal_mode_code` 另行选择零 I/O 的 ephemeral
profile，或把 provider/tool intent-result 对写入 Session 目录的 durable profile；
该数据面不进入 Conversation，因此不会改变 provider-visible bytes 或 prompt cache。
当前 journal 在崩溃前缀不完整时 fail closed，尚不宣称原地 active-Run resume。
该表尚不暴露通用 data/static plugin grouping 或 inventory 查询；完整插件清单仍通过
上节 JSON 协议暴露，reserved 字段不能充当隐式扩展通道。

## 4. Bundle 与门禁

Bundle 只有一个坐标根，包含 Header、目标静态库、Zig/Rust bindings、README
与带 SHA-256 白名单的 manifest。消费端拒绝未知/缺失/重复文件、hash 或 target
不匹配。

```sh
# 交叉构建并做 source-free C/C++/Zig link check
zig build agentcore:bundle \
  -Dtarget=<explicit-target> \
  -Doptimize=ReleaseSafe

# 在匹配原生 Host 上执行 ABI + C/C++/Zig/Rust 消费 gate
zig build agentcore:gate \
  -Dtarget=<native-target> \
  -Doptimize=ReleaseSafe
```

Windows 使用 `metask_agentcore.lib`，Linux/macOS 使用
`libmetask_agentcore.a`。发布状态按 target 记录；cross-build 成功不是原生可用性
声明。当前准确矩阵见 `AGENTCORE_BINARY_ABI.md`。

## 5. Host 选择

| 场景 | 推荐入口 |
|---|---|
| metacodes 同仓/同工具链的 Zig 产品 | `metacodes-core` + `AgentRuntime` |
| 审计当前数据插件组合 | plugin inventory JSON |
| 浏览器/桌面壳 | Web HTTP + SSE + typed request 回填 |
| 不带源码的 C/C++/Zig/Rust 原生产品 | 精确 pinned AgentCore bundle |
| 显式信任的可执行工具插件 | `--process-plugin-dir`、Zig `RuntimeConfig.process_plugins`，或 AgentCore v1 revision 13 `runtime_create_with_plugins`；见 `PLUGIN_PROCESS_PROTOCOL.md` |
| 不可信/多租户可执行插件 | 暂不支持；process v1 是故障/资源边界，不是 OS sandbox |

这些入口改变的是 Host 表达和扩展组合，不是 agent loop 的因果所有权。
