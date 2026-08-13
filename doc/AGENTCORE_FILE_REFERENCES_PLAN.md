# AgentCore 文件引用与宿主快捷打开方案

## 1. 目标与边界

AgentCore 只发布结构化文件引用，宿主决定是否展示、是否打开以及如何打开。

AgentCore 不发送 `open_file` 命令，不等待宿主打开文件，也不参与宿主 UI 决策。

宿主可以是 Web、IDE、TUI 或无 UI 消费方：

- Web：展示预览或打开按钮；
- IDE：转换成编辑器 URI 和范围；
- TUI：调用 `$VISUAL` 或 `$EDITOR`；
- 无 UI：忽略或持久化引用。

## 2. Revision 结论

本方案完整能力在 AgentCore ABI v1 Revision 8 内闭合，明确不升级 revision。

不改变：

- `ABI_REVISION`；
- `ApiV1` 函数表布局；
- `RunResultV1` 等固定二进制结构体；
- capability 集合；
- reserved 字段语义；
- UI request/response 控制协议。

`file_refs` 是 `tool_result` observation 中的可选字段。现有协议允许已知事件增加可选字段，因此旧消费方可以忽略它，新消费方可以读取它。

为保证同一 Revision 8 内的兼容性，所有 Locator 变体、范围语义和安全限制在 Phase 1 一次性冻结。后续阶段只增加实现和宿主适配，不增加 union variant、enum variant 或控制消息。

## 3. 文件引用协议

`tool_result` 增加可选 `file_refs`：

```json
{
  "tool_result": {
    "id": "tool-1",
    "name": "Edit",
    "input": "{\"file_path\":\"src/main.zig\"}",
    "content": "...",
    "is_error": false,
    "file_refs": [
      {
        "locator": {
          "workspace_path": "src/main.zig"
        },
        "title": "main.zig",
        "kind": "modified",
        "range": {
          "start": { "line": 42, "column": 3 },
          "end": { "line": 48, "column": 12 }
        }
      }
    ]
  }
}
```

建议类型：

```zig
pub const FileReference = struct {
    locator: Locator,
    title: []const u8,
    kind: []const u8,
    range: ?FileRange = null,
};

pub const Locator = union(enum) {
    workspace_path: []const u8,
    absolute_path: []const u8,
    uri: []const u8,
};

pub const FileRange = struct {
    start: FilePosition,
    end: FilePosition,
};

pub const FilePosition = struct {
    line: u32,
    column: u32,
};
```

### 3.1 Locator 语义

Locator 必须表达工具实际访问的目标，不能把 workspace 外路径伪装成 workspace-relative 路径。

- `workspace_path`：规范化后位于 `workspace_root` 子树内的路径；使用 `/` 分隔，永远不含 `..`；
- `absolute_path`：规范化后位于 workspace 外、但工具实际访问的本地绝对路径；
- `uri`：非本地文件或宿主提供的其他资源；URI scheme 由宿主安全策略决定。

路径分类规则：

```text
规范化目标位于 workspace 子树内  → workspace_path
规范化目标是其他本地绝对路径    → absolute_path
目标不是本地文件资源             → uri
```

`absolute_path` 不表示宿主必须允许打开。它只保证引用不会指向错误的位置；宿主仍须按自己的 workspace、additional_dirs、sandbox 和权限策略重新校验。

### 3.2 范围语义

- `line`：1-based；
- `column`：1-based UTF-16 code unit；
- `range.start`：包含；
- `range.end`：不包含；
- 没有可靠范围时省略 `range`，不得猜测。

该定义便于适配 LSP/VS Code，同时避免 CJK 和 surrogate pair 导致不同消费方定位不一致。

### 3.3 kind 语义

`kind` 使用有界字符串而不是 closed enum，以便未知语义在同一 Revision 内安全降级。初始值包括：

- `read`；
- `created`；
- `modified`；
- `deleted`；
- `generated`；
- `notebook`。

消费方遇到未知 `kind` 时按普通文件引用处理，不得因此丢弃整个 `tool_result`。

### 3.4 Payload 限制

建议在 ABI 文档和 SDK 中冻结以下 Revision 8 常量：

```zig
pub const MAX_FILE_REFS_PER_TOOL_RESULT_V1: usize = 32;
pub const MAX_FILE_REF_PATH_BYTES_V1: usize = 4096;
pub const MAX_FILE_REF_URI_BYTES_V1: usize = 8192;
pub const MAX_FILE_REF_TITLE_BYTES_V1: usize = 256;
pub const MAX_FILE_REF_KIND_BYTES_V1: usize = 64;
```

生产端和 SDK decoder 两侧都必须校验这些限制。超限应形成有界的 resource-limit/invalid-payload 结果，不得无界分配。

## 4. 真实路径解析与引用投影

引用生成不能只依赖工具名、原始 JSON 和结果文本。真实路径语义必须复用工具执行链已有的解析和观察机制。

建议拆为两层：

```text
路径解析/观察层
  └─ ToolContext + normalizeChecked + file target observation

引用投影层
  └─ 已解析目标 + 执行结果 → FileReference DTO
```

实现应复用：

- `ToolContext.home_dir`；
- `ToolContext.cwd_abs`；
- `ToolContext.resolve_relative_paths`；
- `common.extractJsonArg`；
- `path.normalizeChecked`；
- 现有 `observeFileTarget` / `file_target_state`；
- 现有 symlink/reparse point 和 no-follow 规则。

`src/core/file_reference.zig` 可以提供纯 DTO 投影函数，但路径解析本身必须接收已经由执行上下文解析出的 `ResolvedFileTarget`，不能重新从字符串猜路径。

文件目标观测不能依赖 Permission、project-rule 或普通 tool-observer 是否启用；这些开关服务于不同的审计/策略语义，不能让文件引用使用不同的传感器。实现应将文件引用需求作为独立触发源，或直接无条件执行所需的有界目标观测，并复用观测结果。当前已有的 `observeFileTarget` 覆盖 `Write`/`Edit`/`NotebookEdit`，不得把 `.unobserved` 或 `.unavailable` 猜成某种写入状态。

## 5. 工具产出规则

### 5.1 只对真正的内建文件工具生成引用

不能仅按模型传入的工具名字符串判断。AgentCore Session 可以注册同名 Host tool。

引用生成条件必须绑定：

```text
tool_catalog.Entry.executor == .builtin
且名称解析结果确实是 AgentCore 内建文件工具
```

应使用实际派发后的：

- `dispatched_name`；
- `dispatch_input`；
- `is_builtin_file_tool`；
- `file_target_state`。

事件仍可保留模型原始 `name`/`input` 供展示，但引用不能由 Host tool 的同名字段推导。

`tool_dispatcher != null` 不能作为排除条件：AgentCore Session 的内建工具同样经过 dispatcher。Host tool 即使使用 `Read`、`Write` 或 `Edit` 同名，也必须因 `Entry.executor != .builtin` 而不生成内建文件引用。

### 5.2 执行前确定 created/modified

使用执行前的 `file_target_state`：

```text
missing             → created
regular_existing    → modified
other_existing      → 不生成写入引用
```

若状态为 `.unobserved` 或 `.unavailable`，不得默认按 `modified` 处理；对写入类工具应不生成 `created`/`modified` 引用。当前目标观测覆盖 `Write`/`Edit`/`NotebookEdit`，读取类工具可以在路径解析成功后生成 `read`，无需借用写入状态。

执行失败、权限拒绝或目标未发生预期变更时：

- `is_error = true`：不得生成 `created` 或 `modified`；
- `decision = denied`：不得生成写入引用；
- `Read` 等读取类工具可以生成 `read` 引用；
- `old_string not found` 等 Edit 失败不得标为 `modified`。

### 5.3 Phase 1 工具范围

- `Read`：生成 `read`；
- `Write`：依据执行前状态生成 `created` 或 `modified`；
- `Edit`：成功时生成 `modified`；
- `NotebookEdit`：成功时生成 `notebook` 或 `modified`。

不从任意 `Bash` stdout 或助手 Markdown 文本中猜测路径，也不把任意 `file://` 文本自动视为可信本地文件。

### 5.4 后续实现不扩展协议形状

后续可以增加：

- Edit 根据 unified diff 计算范围；
- Grep/Glob 生成多个 `file_refs`；
- MCP `resource_link` 映射为 `uri`；
- Web、IDE、TUI 的打开和预览适配。

这些只使用已冻结的 Locator、kind、range 和限制，不新增协议 variant，因此仍属于 Revision 8。

## 6. 生命周期与所有权

引用是 `tool_exec.Slot` 的 owned 数据：

```text
工具执行完成
  → Slot 持有 refs
  → agent_loop 发出 tool_result
  → backend/AgentCore 同步消费或深拷贝
  → Slot.deinit 统一释放
```

串行和并行工具批次都必须遵守同一生命周期。消费方若要在回调结束后保存引用，必须深拷贝。

挂起/恢复路径不产生新的 `tool_result` 引用事件；恢复使用既有的 UI 请求和结果路径，不得重复发布或伪造引用。

## 7. 宿主消费与安全

AgentCore 不新增 `open_file` 回调。宿主只消费事件：

```text
on_tool_result(event)
  └─ for each file_ref:
       host_policy.should_offer(ref)
       host_ui.render(ref)
       host_action.open(ref)   // 宿主自行决定
```

宿主打开前必须重新校验：

- workspace、additional_dirs、sandbox 和权限策略；
- `workspace_path` 不含 `..`；
- `absolute_path` 是否被宿主策略允许；
- symlink/reparse point 是否逃逸；
- URI scheme 是否在 allowlist；
- 文件是否仍存在且类型允许；
- 不把路径拼接进未经转义的 shell 命令。

Web 不能把任意本地路径直接放进浏览器 URL，应由本地 Host 提供带 session/ref token 的受控预览接口。

## 8. 实施阶段

### Phase 1：Revision 8 协议和 AgentCore 产出

- 冻结完整 `FileReference`、Locator、range、kind 和限制；
- 在 `tool_result` 增加可选 `file_refs`；
- 接入 `Read`、`Write`、`Edit`、`NotebookEdit`；
- 复用现有 ToolContext 路径解析和执行前 target observation；
- SDK 增加 decoder；
- 不把引用写入模型可见 tool result。

### Phase 2：定位和多引用消费

- Edit 根据 unified diff 生成范围；
- Grep/Glob 生成多个引用；
- Web 预览和定位；
- IDE Range 适配。

### Phase 3：多宿主体验

- TUI 快捷键；
- Rust/C/C++ 消费示例；
- URI 资源宿主适配；
- transcript replay 和引用持久化；
- 完整安全审计。

Phase 2/3 不增加 ABI variant，不改变 Revision 8。

## 9. 测试门禁

### L1：投影和边界

- 内建 Read/Write/Edit/NotebookEdit 字段提取；
- 相对路径、`~`、cwd 和 home 解析；
- workspace 内路径 → `workspace_path`；
- workspace 外绝对路径 → `absolute_path`；
- URI → `uri`；
- Windows 路径和大小写规则；
- `..`、symlink/reparse point 边界；
- `file_target_state` 到 `created/modified` 映射；
- denied/error/failed Edit 不产生写入引用；
- 在 dispatcher 非空的 AgentCore Session 中，Host tool 同名不产生内建文件引用；
- payload 数量和字节限制；
- line/column UTF-16、1-based、半开范围。

### L2：AgentCore 端到端

- MockServer 驱动真实 Run；
- `tool_result.file_refs` 端到端出现；
- 引用不进入下一次 provider request；
- 旧 payload 和新 payload 均可解码；
- 未知 `kind` 不导致整个事件失败；
- 串行/并行工具批次引用不交叉；
- Slot、backend、SDK 回调生命周期无悬挂或 double-free；
- 挂起/恢复路径不重复发布引用。

### 消费端 E2E

- Web 正确渲染引用；
- 宿主忽略引用不影响 Run；
- 受限 absolute path 不能打开；
- workspace 和 additional_dirs 路径定位准确；
- IDE/TUI adapter 的打开动作由宿主策略控制。

## 10. 预计修改范围

第一阶段预计涉及：

- `src/core/file_reference.zig`；
- `src/core/protocol/ui_event.zig`；
- `src/core/tool_exec.zig`；
- `src/core/tool_catalog.zig`（暴露/传递 `Entry.executor` 身份）；
- `src/tools/project_rule_signal.zig`（复用现有 Write/Edit 目标观测）；
- `src/core/agent_loop.zig`；
- `src/agentcore/protocol_v1.zig`；
- `sdk/zig/protocol.zig`；
- `doc/AGENTCORE_BINARY_ABI.md`（补充 observation 字段和限制）；
- AgentCore、SDK、Web 组件测试。

第一阶段不修改：

- `RunResultV1`；
- `ApiV1` 函数表布局；
- `ABI_REVISION`；
- reserved 字段语义；
- AgentCore UI request/response 控制协议。
