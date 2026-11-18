# JavaScript 工具编排协议

状态：已实现，Preview。本文是 ExecuteCode 的规范。Meta Code 主程序、权限与工具实现仍为
Zig；嵌入的 QuickJS 只负责执行模型编写的 JavaScript，不直接执行 TypeScript。

默认关闭。使用 `metacodes --preview`，或在 `<state root>/config.json` 根对象中保存
`"preview": true`；`--no-preview` 可覆盖已保存的开启设置。子 agent 继承该设置。
关闭时工具菜单不包含 ExecuteCode，猜测名称直接调用也会在创建 VM 前被拒绝。
SDK 使用 Python `Runtime(preview=True)`、Node.js `new Runtime({preview: true})`，
或 AgentCore ABI revision 29 的 `RuntimeConfigV1.preview = 1`。仅按名称选择工具
不能开启 preview；Session 工具选择、权限、sandbox 和预算检查仍然有效。

## 调用与返回

普通工具调用 `ExecuteCode({"code":"...", "timeout_ms":30000})`。脚本支持顶层
await，使用当前请求工具表中的原名，例如：

```js
var rows = await tools.Read({file_path: "/workspace/data.json"});
console.log("read complete");
({length: JSON.stringify(rows).length});
```

`tools.Name(args)` 返回 Promise。内核在 JS 让出执行后派发工具，再完成 Promise，
推动微任务继续脚本。宿主工具目前串行执行；Promise.all 可用，但不增加工具并行度。
工具参数按 JSON 复制；合法 JSON 结果转换为 JS 值，其他文本保持字符串。工具错误
reject 为 Error，`error.result` 保存解析后的结果。Host fatal、formal/observer fatal
直接终止宿主执行，JS catch 不能将它降格成普通工具错误。

成功返回 `{"value":42,"logs":["read complete"],"tool_calls":1}`，value 是最后一个
表达式，undefined 时省略。只提交这个外层结果和 Hooks 明确注入的 additionalContext
到模型历史。内部调用有工具、权限与文件变更证据，不增加 provider tool_use/result。
RunResult.tool_calls 同时计入外层和内部调用尝试。

## 状态与隔离

每个 Conversation 惰性创建一个 QuickJS 上下文。全局 var、let、const、对象与函数
可在成功的多轮调用和同一会话的不同 Run 之间复用。新会话和子 agent 使用独立上下文；
resume、fork 和进程重启不会恢复 JS 堆。对话压缩不把 JS 数据写入提示词或摘要。
执行失败会使上下文失效，下次调用前重新创建；已发生的工具副作用不会回滚。

工具请求每次都按当前请求的工具表重新准入；保存的 JS 函数不能保留旧工具权限。
不允许嵌套 ExecuteCode；AskUserQuestion 和可序列化的异步 UI 挂起应在脚本外调用。
没有文件、进程、网络、模块加载器或定时器绑定。QuickJS 的内存限制和执行中断并非
操作系统进程隔离；操作系统权限与 sandbox 仍由 Zig 工具管线实施。

## 边界与限制

外层和内部调用共用 ToolAdmission：规范化名称、PreToolUse block/updatedInput、
权限规则、用户确认与学习阶段限制。随后复用 executeSlots/executeOne 的参数校验、
执行策略、sandbox、formal/observer、TinyKG 准入和 CAS 机制。内部工具的 PostToolUse
和副作用证据交给原有的运行审计、检查门和验证传感器。ReadArtifact 共用本轮恢复预算。

每次代码最多 256 KiB，工具参数最多 256 KiB；每次执行最多 128 次工具请求、100000
个微任务、64 KiB 的结果 JSON（含日志），JS 堆限 64 MiB，JS 栈限 512 KiB。
异常诊断另有 8 KiB 上限。timeout_ms 取 1–120000，默认 30000；它限制 JS 执行，
并在工具调用之间检查。正在执行的工具保留其自身的超时与宿主取消语义；等待用户确认
或同步 Host 回调的时间可能超过此期限。Run abort 可中断 JS 和支持取消的原生工具。
未等待的工具请求、永不完成且没有宿主请求可推进的 Promise，以及在结果序列化时
新建的异步工作会报错并使 VM 失效，不能泄漏到下一次调用。

QuickJS 来源、归档哈希与本地补丁见 [vendor/quickjs](../vendor/quickjs/README.md)。
实现证据：`tests/component/execute_code_test.zig`；外部 SDK 消费者证据：
`sdk/python/tests/test_metacodes.py` 的 ExecuteCode 测试，均使用本地模拟 provider。
