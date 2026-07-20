# AgentCore 二进制库交付接口

> AgentCore 是公司内部使用的独立原生组件，不是 metacodes 产品 API。
> ABI 的 normative 语义见 `doc/AGENTCORE_BINARY_ABI.md`；目标范围与当前验证状态见
> `doc/AGENTCORE_NATIVE_SDK_DISTRIBUTION_PLAN.md`。

## 1. 交付边界

消费端不把 AgentCore 或 metacodes 实现源码加入构建图，只使用预编译静态库和同包 SDK：

| Host | 交付物 |
|---|---|
| C11 | `<metask/agentcore.h>` + 静态库 |
| C++17 | 同一 C Header（带 `extern "C"`）+ 静态库 |
| Zig 0.16.0 | `bindings/zig` + 静态库 |
| Rust | `bindings/rust` 中的 `metask-agentcore-sys` + 静态库 |

`metacodes-core`、`src/lib.zig` 和 AgentLoop 都不是消费端接口。首期不提供动态库、托管语言
FFI、C++ wrapper 或 Rust safe wrapper。

## 2. Bundle 布局

归档解压后只有一个坐标根目录：

```text
metask-agentcore-<version>-<target>/
├── include/metask/agentcore.h
├── lib/<target static library>
├── bindings/zig/{build.zig,build.zig.zon,src/}
├── bindings/rust/{Cargo.toml,Cargo.lock,link.cfg,build.rs,examples/,src/}
├── README.md
└── manifest.json
```

Windows 使用 `metask_agentcore.lib`；Linux/macOS 使用 `libmetask_agentcore.a`。
`manifest.json` 记录独立 package version、源码身份、生产端 Zig target、Cargo target、ABI、链接输入和
每个 payload 文件的 SHA-256。消费门禁拒绝 manifest 清单缺失、重复、含未识别条目、hash
不符或 target 不匹配的包；磁盘上未列入 manifest 的 staging 残留会被忽略，也不会进入归档。

## 3. 构建与门禁

交叉构建和 source-free C/C++/Zig link check：

```sh
zig build agentcore:bundle \
  -Dtarget=x86_64-linux-gnu \
  -Doptimize=ReleaseSafe
```

在匹配原生 Host 上执行 ABI、C/C++、Zig 和 Rust 探针：

```sh
zig build agentcore:gate \
  -Dtarget=x86_64-windows-msvc \
  -Doptimize=ReleaseSafe
```

创建 Windows zip 或 Unix tar.gz，并写出相邻 SHA-256 文件：

```sh
zig build agentcore:archive \
  -Dtarget=x86_64-windows-msvc \
  -Doptimize=ReleaseSafe \
  -Dagentcore-archive-dir=<empty-output-directory>
```

归档坐标不可覆盖。当前工具只生成和校验内部 bundle；稳定版的 tag、clean-tree 和发布身份
策略留到正式发布流程建立时由 CI 统一定义。

## 4. 消费入口

C ABI 只导出发现入口：

```c
const metask_agentcore_api_v1 *metask_agentcore_get_api(uint32_t abi_version);
```

Host 通过返回的 vtable 创建 Runtime/Session、执行和中止 Run，并释放 AgentCore 诊断缓冲区。
ownership、lifetime、回调重入、并发、`run_id`、Session poison 和错误语义只以
`doc/AGENTCORE_BINARY_ABI.md` 与同版本公共 Header 为准。

当前只有 `x86_64-windows-msvc` 完成 C/C++/Zig/Rust 原生消费门禁；Linux GNU、Intel macOS
和 arm64 macOS 已完成 cross bundle/link/archive，但在各自原生复验完成前不标记可用。
