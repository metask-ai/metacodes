# metacodes 核心能力插件与热替换

Status: implemented for the source-level Zig `AgentRuntime` / `RuntimeHost`.
The Host support matrix below is normative for the current repository state;
unsupported cells are explicit gaps, not implied features.

## 1. 边界

metacodes 把“实现能力”做成插件，但不把因果与安全所有权做成插件。不可替换的
kernel TCB 是：

- `AgentLoop` 的 turn、tool ordering、result commit 与 Conversation 所有权；
- permission/settings/protected-path、sandbox、resource budget 与 cancellation；
- Lean/formal verdict 的最终裁决；
- TinyKG provenance、writer/CAS、task lease 与 ontology promotion；
- durable event/session ledger、checkpoint identity 与恢复校验。

插件可以贡献工具、数据、受限策略和适配器。它只能拒绝或缩小权限，不能批准、
抬高预算、伪造 formal verdict、直接写 TinyKG，或替换 AgentLoop。这样保留了
metacodes 的 agent loop、形式化+本体论和基于证据自我迭代三条设计主轴。

## 2. 首方核心能力包

`src/plugin/first_party.zig` 把原先硬编码在 `AgentRuntime` 默认配置中的工具面整理为
普通的 immutable `static_trusted` 插件。它们声明
`builtin_tool_bundle`，由 `plugin/runtime.zig` 投影到原生 `ToolCatalog`：

| Profile | 插件 | 原生工具 |
|---|---|---|
| `none` | 无 | 无 |
| `minimal` | `metacodes.core.minimal@1.0.0` | Read, Glob, Grep |
| `offline-coding` | `metacodes.core.offline-coding@1.0.0` | Read, Write, Edit, Glob, Grep, Bash, BashOutput, KillShell |
| `coding` | `metacodes.core.coding@1.0.0` | 原默认十工具；在 offline-coding 上增加 WebSearch、WebFetch |
| `coding-interactive` | coding + `metacodes.core.interaction@1.0.0` | coding 再增加 AskUserQuestion |

`coding` 是默认值，所以既有 `AgentRuntime.create(allocator, .{})` 的 provider-visible
工具顺序、原生 executor 和 permission category 不变。插件化只改变组合与生命周期，
不在执行热路径增加 callback、进程或 JSON 中转。

`RuntimeConfig.builtin_tools` 现在是兼容覆盖：

- `null`：选择 `core_profile`，默认 `.coding`；
- 非 null：保留旧式显式工具列表并不自动装入首方 profile；
- 显式 `static_plugins` 仍可额外贡献 `builtin_tool_bundle`；任何未知工具、声明/负载
  不一致或 provider-visible 重名都会使候选 Runtime 整体创建失败。

profile 的外部稳定名称由 `CoreProfile.parse` / `canonical` 给出，不使用 Zig enum 的
下划线拼写。

## 3. 热替换语义

需要热插拔的 Zig Host 以 `RuntimeHost` 为唯一组合根：

```zig
const host = try mc.agent_session.RuntimeHost.create(allocator, .{
    .core_profile = .minimal,
});
defer host.destroy() catch unreachable;

const session_v1 = try host.createSession(session_config);
_ = try host.replace(.{ .core_profile = .coding });
const session_v2 = try host.createSession(session_config_v2);
```

`replace` 执行 `stage -> validate -> resolve -> project -> activate -> publish`。只有完整
候选成功后才原子切换 admission pointer；失败不会消耗 generation，也不会改变现役
Runtime。热替换是 immutable generation replacement，不是修改活跃对象：

- `session_v1` 固定 generation 1，继续使用 minimal catalog 和旧插件 effect；
- `session_v2` 固定 generation 2，使用 coding catalog；
- 旧 Runtime 在最后一个旧 Session 销毁后自动按逆序清理；
- 不加载任意 dylib，也不让插件持有可变 kernel handle。

这给嵌入软件一个清晰的并发语义：一次业务会话内行为稳定，更新只影响随后接纳的
会话。需要回滚时，Host 用上一份冻结的 `RuntimeConfig` 再发布一个新 generation，
而不是把 generation number 倒退。

### 3.1 System prompt 与缓存不变量

Session 每次 Run 从同一份有效 `ToolCatalog` 同时生成 provider tool schema 和
`# Using your tools`。Read/Edit/Write/Bash/Glob/Grep/CodeMap/Task 与 deferred catalog
都按实际工具面投影；execution policy 或 provider capability 在 turn 边界继续缩窄工具时，
普通工具指导、deferred catalog、Skill/子 Agent 章节及 TinyKG 的 recall/context/remember/task
协议也一起缩窄。文本模式不会残留不存在的工具名。

插件化不把 plugin id、inventory、generation、加载路径或时间戳写入 provider request。
工具指导使用固定规则顺序，等价 Runtime 配置即使发布为不同 generation，也必须产生
byte-identical system prompt 与 tool schema；因此不会仅因“重载”击穿 prefix cache。
真正改变有效工具、方言输出、model、system 内容时，请求字节自然变化并形成有意的缓存边界。
旧 Session 固定旧 generation，因此新插件也不会改变它已经建立的缓存前缀。

### 3.2 Provider dialect 插件

`provider_dialect` 是 `static_trusted` 的 Runtime-scoped capability。它不替换 Provider
transport，而是在现有 Anthropic/OpenAI/Gemini transport 下面按
`{provider_kind, model_prefix}` 提供 `Dialect` vtable：

- ModelProfile 与 thinking/tool-choice/response-format/cache-key 等请求投影；
- provider-specific system modifier；
- 当前请求工具面导出的 typed `VisibleCapabilities`（首个字段为 `skill_tool`）及其
  model-specific system guidance；
- reasoning/thinking 响应增量提取。

匹配采用 longest-prefix；完全重复的 key 在 staging 时 fail closed。Resolver 属于不可变
Snapshot，主 Session、model replacement 和 Session 创建的隔离子 Provider 都借用同一代
Resolver。热替换只影响新 Session。默认 CLI/App 和没有匹配项的模型继续走内建 dialect 表，
不会改变既有请求字节。

三种现有 transport 都在序列化前把“这一次请求真正可见的工具”投影为 typed capability，
不靠扫描提示词猜测。因而 AgentCore 的 run-scoped `Skill` surface、主 Session、后台 Task
和 in-process Swarm 都会走同一个 Resolver。GLM 的 Anthropic/OpenAI 内建方言目前在且仅在
`Skill` 真可见时追加稳定的 tool-first 约束；相同 model/system/tools 重复序列化保持
byte-identical，不会仅因 capability 检查破坏缓存。

Skill 数据插件可声明 `model-activation: required-first`。该字段先进入 immutable Skill
catalog/revision，再投影为不序列化的 `ToolDefinition.model_activation`；只有恰好一个当前
可见、允许模型调用的 Skill 声明该模式时，才形成 `{tool=Skill, name=<exact invocation>}`
的 typed route。两个插件同时声明会 fail closed 回普通模型选择，绝不按加载顺序选赢家。
支持指定函数的方言（当前 Anthropic-compatible GLM）把它翻译成首请求 `tool_choice=Skill`
与精确参数指导；只有 exact `Skill(name=<invocation>)` 及其成功配对 `tool_result` 才自动释放。
错误参数、拒绝、dispatch error 和孤立 `tool_use` 都不释放。OpenAI-compatible GLM
当前只支持 `auto`，因此只发精确稳定指导，不伪造 provider 不支持的 forced choice。
`advisory`（默认值）不会产生 forced route。该路由只影响模型选择，真实执行仍经过原生
dispatcher、Skill policy frame、permission、budget、Lean/TinyKG 边界。

方言的 forced choice 是兼容性增强，不是正确性边界：部分 Anthropic-compatible 网关会接受
但忽略该字段。AgentLoop 因而拥有 provider-neutral `required-first` 不变量——激活前禁止
预取或执行任何非 exact route，给被拒调用返回结构化 `required_first_pending`，对无工具终止
最多发两次共享计量的修复提示，仍不服从则以 `tool_loop` fail closed。该约束在 pre-hook、
permission 与 dispatcher 之前执行，所以 Provider 方言、插件或模型都不能绕过。

完整 Conversation 保留激活事实；若 call/result 已被 compact boundary 隐藏，AgentLoop 只在
本轮浅拷贝的 `model_activation.satisfied` Host 元数据中携带它。该字段不进入 schema，方言的
system guidance 也忽略它；因此 system/tool cache 前缀 byte-identical，只移除已经不需要的
尾部 forced routing 字段，且不会重复激活。

Dialect callback 必须是其显式输入的确定性纯投影，不得注入时间、随机数、generation、
plugin id 或加载路径。Runtime 用不可变 Snapshot 保证生命周期与代际隔离，但不会替一个
故意非确定的 trusted callback 掩盖缓存破坏；这属于 `static_trusted` 插件契约违规。

缓存语义分两类：等价插件内容/方言跨 generation 热替换必须 request-byte identical；启用、
停用或修改一个真正改变 system/tool/tool-choice 的插件，则有意建立一个新缓存前缀。也就是
“重载”本身不清缓存，“有效模型输入改变”才改变缓存身份。

完整新协议、认证或网络 transport 仍是 Provider Host-plane seam，不等于 dialect 插件；
filesystem/process package 不能把自己升级为 in-process dialect callback。

## 4. 当前宿主矩阵

| 宿主/表面 | 首方 profile | 运行中代际替换 | 当前准确状态 |
|---|---:|---:|---|
| Zig `AgentRuntime` | 是 | 固定单代 | 可选择 profile，并读取 inventory |
| Zig `RuntimeHost` | 是 | 是 | 完整 stage/publish、Session pinning、失败保留旧代 |
| CLI/TUI App | 否 | 否 | data/process plugin 可在启动时组合；App 主 Provider、后台 Task 与 in-process Swarm 共用启动时 immutable Resolver；核心工具仍由 App 固定组装 |
| Web backend | 否 | 否 | 复用 App snapshot 和 inventory；没有 Web 热替换控制面 |
| AgentCore C/Zig/Rust ABI rev10 | 显式工具列表 | 否 | 保持 96-byte ABI；process plugin 可在 create 时加载 |
| Provider transport | 每 Session 可选 | 新 Session 可选 | 认证/HTTP/SSE 仍是 Host plane seam |
| Provider dialect | 是（static trusted） | 是 | Snapshot-scoped longest-prefix resolver + typed visible-capability projection；旧 Session 固定旧代 |
| UI backend | 每 Run/Session 注入 | 新 Run/Session 可选 | typed `CoreEvent` / `UiRequest` seam，不替换 AgentLoop |
| Skill/Agent data package | CLI 启动时 | 否 | namespaced data plugin 已接线；尚未投影进 Zig Runtime profile |
| Formal/TinyKG | 受治理输入 | 不允许替换裁决/写入器 | evidence adapter 可扩展，verdict/provenance/CAS 永属 TCB |

因此，“首方核心能力热插拔”当前是 Zig 嵌入 Runtime 的已实现能力。CLI/Web live
control plane、AgentCore 新 ABI revision，以及 Skill/Agent profile 投影是后续明确工作，
不能从保留字段或现有 inventory 接口推断为已支持。

## 5. 自我迭代如何进入插件代际

自我迭代不直接修改正在运行的插件：

1. agent 或插件提交 inert candidate；
2. TinyKG 记录来源、任务、观测和候选 hash；
3. 冻结 harness 做 paired evaluation；
4. Lean/native gate 对精确 hash 产出 verdict；
5. TinyKG CAS 只晋升同一份已审核 artifact；
6. Host 用该 artifact 组装并 stage 新 Runtime generation；
7. 新会话进入新代，旧会话自然 drain；回归则发布上一配置的新代。

这让“可热插拔”和“可自我迭代”共享同一个 promotion boundary，同时不牺牲
metacodes 的形式化和本体论可信链。

## 6. 验证门禁

当前实现必须同时满足：

- contract 单测：`builtin_tool_bundle` 仅允许 `static_trusted`；
- projector 负测：未知工具、声明/接线漂移、跨插件重名全部 fail closed；
- L2：运行中的 minimal Session 跨 replace 后仍能执行 Read，新 coding Session 能
  执行 Write，且 generation/inventory/provider schema/system prompt 一致；
- L2：dialect 插件只影响匹配模型与新 Session；相同插件配置跨 generation 的完整
  provider request byte-identical，证明插件元数据不击穿缓存；
- L2：`required-first` Skill 的首请求包含确定的 exact route，真实调用经过 canonical
  Skill Runtime 执行并缩窄 policy，后续请求释放 forced choice；多 route/disabled Skill
  不按插件顺序产生选择；
- 独立 embedding fixture：无密钥执行 `minimal -> coding`，打印两代 inventory；
- `test:lib`、component/integration、ReleaseSafe 和 coverage audit 全部通过后才发布。
