# AgentCore 二进制库交付接口

> 本文档定义 metacodes 核心能力对第三方 Host 的唯一受支持交付方式：
> **预编译 `metacodes_agentcore` 静态库 + C 头文件或 source-free Zig SDK**。
> ABI 的 normative 语义见 `doc/AGENTCORE_BINARY_ABI.md`。

## 1. 交付边界

第三方应用不把 metacodes 实现源码加入自己的构建图，即使 Host 使用 Zig。
这样做同时守住两个边界：

- 安全边界：实现细节、依赖图和内部状态机不成为第三方可直接耦合的接口。
- 兼容边界：Host 只依赖冻结的 C ABI v1 和独立的 AgentCore protocol v1，内部 Zig 类型可以继续演进。

仓库中的 `metacodes-core` module、`src/lib.zig`、`example/` 和 `zig build test:lib`
仅用于 metacodes 自身的模块化、隔离验证与内部 dogfood。它们不是发行物，不承诺源码兼容，
也不是第三方接入路径。

| Host | 受支持的交付物 | 是否编译 core 源码 |
|------|----------------|:------------------:|
| Zig | 静态库 + `sdk/metacodes_agentcore.zig` | 否 |
| C / C++ | 静态库 + `include/metacodes_agentcore.h` | 否 |
| Rust / Go / 其他语言 | 经 C ABI 绑定静态库和头文件 | 否 |

## 2. Bundle 布局

每个 resolved target 对应一个隔离 bundle：

```text
<prefix>/agentcore/<resolved-target>/
├── lib/<target-specific out_filename>
├── include/metacodes_agentcore.h
├── sdk/metacodes_agentcore.zig
├── sdk/metacodes_agentcore_protocol.zig
├── sdk/metacodes_agentcore_types.zig
└── manifest.json
```

静态库文件名来自 Zig 的 `out_filename`，构建、manifest 和 consumer 都不猜测 `.lib`
或 `.a`。`manifest.json` 记录 resolved target、toolchain/source identity、优化与 strip
设置、系统链接输入，以及所有交付文件的 SHA-256；bundle 外多文件或缺文件都会被 consumer
拒绝。

## 3. 构建与门禁

交叉构建并执行 source-free Zig/C/C++ link check：

```sh
zig build agentcore:bundle \
  -Dtarget=x86_64-windows-gnu \
  -Doptimize=ReleaseSmall
```

在目标平台原生执行 ABI 测试、bundle、source-free link 和 consumer：

```sh
zig build agentcore:gate \
  -Dtarget=x86_64-windows-gnu \
  -Doptimize=ReleaseSmall
```

`agentcore:gate` 只接受可在当前 Host 原生运行的显式 target。交叉验证使用
`agentcore:bundle`，不会等到执行 foreign consumer 时才报模糊错误。

Windows 的平台抽象与 CLI smoke 由以下独立门禁负责：

```sh
zig build windows:gate -Dtarget=x86_64-windows-gnu
```

它不替代全仓测试。全量套件仍是独立命令：

```sh
zig build test -Dtarget=x86_64-windows-gnu
```

## 4. 消费入口

C 头文件只导出单入口：

```c
const McAgentCoreApiV1 *metacodes_agentcore_get_api(uint32_t abi_version);
```

Host 通过返回的 vtable 使用 `runtime_create/destroy`、`session_create/destroy`、
`session_run`、`session_abort` 和 `buffer_release`。配置与结果使用固定布局 POD；富数据事件和
UI request/response 使用 AgentCore protocol v1 JSON。

Zig Host 使用 bundle 中的 `sdk/metacodes_agentcore.zig`。这个 SDK 只声明 ABI、校验 wire
类型并提供便利封装，不 import `src/` 或 `metacodes-core`，仍然是 source-free consumer。

所有权、回调重入、并发、`run_id`、毒化 Session、错误码优先级和 ABI 演进规则均由
`doc/AGENTCORE_BINARY_ABI.md`、`sdk/metacodes_agentcore.h` 与 SDK doc comments 共同约束；
本文不复制第二份语义。

## 5. Windows 工具链边界

当前已验证的 Windows 交付 target 是 `x86_64-windows-gnu`，并由原生 Windows CI 运行
`agentcore:gate`。这只证明对应 GNU bundle 能被门禁中的 source-free consumers 正确链接
和运行。

没有验证 `x86_64-windows-msvc` bundle，也没有验证 MSVC `link.exe` 或 `clang-cl` 消费
GNU bundle。因此这些组合不在当前支持声明内。未来若支持 MSVC，应单独生成
`x86_64-windows-msvc` bundle，并用该工具链的 native consumer 门禁证明兼容性；不能从
GNU/COFF “理论上应该兼容”推导支持。

## 6. 发布约束

- 发布必须使用显式 target 和新的空 prefix，避免旧文件污染 exact-file allowlist。
- 正式 bundle 使用 `-Dagentcore-require-clean-bundle=true`，并用
  `-Dagentcore-expected-commit=<full hash>` 绑定源码身份。
- ABI v1 已冻结。bug/security fix 必须保持 v1 可观察行为；任何扩展使用 v2 table/types。
- 不向第三方分发或承诺 `metacodes-core` 源码 API。
