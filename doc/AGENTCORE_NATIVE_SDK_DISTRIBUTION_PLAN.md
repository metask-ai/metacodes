# AgentCore 原生 SDK 与分发方案

> 状态：已确认方案的可读投影
> 日期：2026-07-20
> 定位：公司内部使用的 AgentCore 原生静态库包
> 当前 ABI：experimental v1 revision 3，短期内不冻结

代码层面的当前 ABI 契约以 [AGENTCORE_BINARY_ABI.md](./AGENTCORE_BINARY_ABI.md) 为准，落地时必须同步更新该文档。

## 1. 范围

AgentCore 是现有执行引擎之上的二进制封装层。本方案只处理：

- `src/agentcore/` 中的 ABI facade；
- `sdk/` 中的公共 Header 与语言绑定；
- 静态库构建、导出目录和 manifest；
- 不包含 AgentCore 实现源码的消费端测试。

本次不改造 metacodes CLI、AgentLoop、认证系统、产品目录、配置加载或工具内部实现。AgentCore 公共接口也不规定 `.metacodes`、`.metawork` 等宿主产品策略。

首期只提供静态库，不提供 DLL、`.so`、`.dylib` 或托管语言绑定。

## 2. 公共命名

全局可寻址名称使用完整公司与组件前缀；语言包内部文件遵循各自生态惯例。

| 对象 | 名称 |
|---|---|
| 包 | `metask-agentcore` |
| C 函数与类型 | `metask_agentcore_*` |
| C 宏 | `METASK_AGENTCORE_*` |
| 发现符号 | `metask_agentcore_get_api` |
| Header | `<metask/agentcore.h>` |
| Header guard | `METASK_AGENTCORE_H` |
| Windows 静态库 | `metask_agentcore.lib` |
| Linux/macOS 静态库 | `libmetask_agentcore.a` |
| Zig module | `metask_agentcore` |
| Rust Cargo package | `metask-agentcore-sys` |
| Rust crate identifier | `metask_agentcore_sys` |

示例：

```text
metacodes_agentcore_get_api -> metask_agentcore_get_api
mc_session                  -> metask_agentcore_session
MC_STATUS_OK                -> METASK_AGENTCORE_STATUS_OK
```

ABI 尚未正式发布，不保留旧名称兼容别名。公共产物中不得残留 `metacodes_agentcore_*`、`mc_*`、`MC_*` 或重复的 `metask_agentcore_agentcore_*`。
旧 Header、bindings 或目录布局不属于兼容范围。消费者只认当前 manifest 白名单，归档也只收录该白名单；本地 staging 目录中的其他文件只是无效残留，不触发兼容逻辑，也不会进入产物。

## 3. 语言支持

| 语言 | 接入方式 |
|---|---|
| C11 | 公共 C Header + 静态库 |
| C++17 | 直接使用带 `extern "C"` 的 C Header |
| Zig 0.16.0 | 类型化 Zig binding |
| Rust | 低层 `-sys` crate |

首期不提供 C++ wrapper、Rust safe wrapper，也不承诺 Rust `Send`/`Sync`。

公共 C Header 是二进制布局、常量和函数签名的基准：

- C/C++ 直接消费 Header；
- Zig binding 手写，但测试必须校验 size、alignment、offset、常量和函数签名；
- Rust raw binding 从 Header 生成后提交，内部消费者不需要安装 bindgen；
- CI 使用固定 bindgen 版本和参数重新生成 `raw.rs`，与提交文件存在 diff 时失败；
- 暂不建设 IDL 或通用跨语言代码生成系统。

JSON `CoreEvent`、`UiRequest` 和 `UiResponse` 仍按现有 ABI protocol 维护，不假装由 C Header 描述。

公共 Header 必须保留 ownership、lifetime 和 concurrency 契约说明；包内 README 指向与该版本对应的 [AGENTCORE_BINARY_ABI.md](./AGENTCORE_BINARY_ABI.md)，不在方案文档中复制线程规则。

## 4. 导出结构

每个 target 一个自包含包：

```text
metask-agentcore-<version>-<target>/
|-- include/
|   `-- metask/
|       `-- agentcore.h
|-- lib/
|   `-- <target static library>
|-- bindings/
|   |-- zig/
|   |   |-- build.zig
|   |   |-- build.zig.zon
|   |   `-- src/
|   |       |-- root.zig
|   |       |-- types.zig
|   |       `-- protocol.zig
|   `-- rust/
|       |-- Cargo.toml
|       |-- Cargo.lock
|       |-- link.cfg
|       |-- build.rs
|       |-- examples/
|       |   `-- link_probe.rs
|       `-- src/
|           |-- lib.rs
|           `-- raw.rs
|-- README.md
`-- manifest.json
```

`bindings/zig` 和 `bindings/rust` 各自是完整语言包根目录。内部源码仍保留 `src/agentcore/` 和 `sdk/`，由 `build.zig` 映射到上述导出结构，不为了打包搬动实现目录。

Rust 包的 `Cargo.toml` 设置 `links = "metask_agentcore"`。`build.rs` 默认以 `CARGO_MANIFEST_DIR/../..` 为 bundle root，也允许 `METASK_AGENTCORE_BUNDLE_DIR` 覆盖；它从 `<bundle-root>/lib` 找静态库，并读取构建时从 manifest 链接信息投影出的 `link.cfg`。`link.cfg` 使用简单行格式记录 Cargo target、系统库和 framework，不在 `build.rs` 中手写 JSON parser。路径缺失或 target 不匹配时必须失败。

Zig 包的 `build.zig` 同样读取同包 manifest，比较消费端与 bundle 的 architecture、OS 和 ABI；不要求 deployment target 或版本范围逐字符相同。三者不匹配时必须在链接前失败。

Windows `.lib` 必须是包含实现 object 的完整 static archive，不是 DLL import library。静态 AgentCore 库仍可依赖系统 C runtime、系统库或 macOS framework，并在 manifest 中声明。

内部归档格式固定为 Windows `.zip`、Linux/macOS `.tar.gz`。
`zig build agentcore:archive` 从已经通过 bundle gate 的目录创建带坐标根目录的归档和相邻
`.sha256` 文件；已存在的同名坐标拒绝覆盖。该命令只是内部构建工具，不是发布或 staging 系统。

## 5. Target 包

首批目标为：

| 包目标 | Zig target | Rust target |
|---|---|---|
| `x86_64-windows-msvc` | `x86_64-windows-msvc` | `x86_64-pc-windows-msvc` |
| `x86_64-linux-gnu` | `x86_64-linux-gnu` | `x86_64-unknown-linux-gnu` |
| `x86_64-macos` | `x86_64-macos.<minimum>` | `x86_64-apple-darwin` |
| `aarch64-macos` | `aarch64-macos.<minimum>` | `aarch64-apple-darwin` |

四个包可以分阶段完成，不要求当前建设原子发布系统。交叉编译只能证明产物可生成；正式标记某个 target 可用前，必须在相应原生工具链上完成消费测试。

当前实现状态：

| 包目标 | 构建状态 | 原生消费状态 |
|---|---|---|
| `x86_64-windows-msvc` | bundle、zip、SHA-256 已验证 | C/C++/Zig/Rust 原生 gate 已通过，当前可用 |
| `x86_64-linux-gnu` | cross bundle/link、tar.gz、SHA-256 已验证 | 待 Linux x86_64 原生 gate，不标记可用 |
| `x86_64-macos` | cross bundle/link、tar.gz、SHA-256 已验证 | 待 macOS x86_64 原生 gate，不标记可用 |
| `aarch64-macos` | cross bundle/link、tar.gz、SHA-256 已验证 | 当前 Rust bundle 变更后待 macOS arm64 原生复验，不标记可用 |

这里的状态是当前代码证据投影。macOS 的 `system_frameworks`
当前为空，只表示交叉链接没有发现额外 framework，必须由后续原生 gate 最终确认。

暂不支持 Windows ARM64、Linux ARM64、musl 和 macOS Universal2。

## 6. 版本

AgentCore 使用独立版本，不复用 metacodes 的 `build.zig.zon`：

```text
sdk/VERSION
```

需要区分：

| 标识 | 用途 |
|---|---|
| AgentCore package version | 识别具体 SDK/静态库包 |
| Binary ABI version | 选择 ABI 主契约 |
| Binary ABI revision | 实验阶段精确识别不兼容 ABI |
| Manifest schema | 解析 manifest 结构 |

快速开发阶段：

```text
sdk/VERSION = 0.1.0-dev
package     = 0.1.0-dev+<commit-short>
```

dirty development build 追加 `.dirty`。正式内部版本使用纯 SemVer，不追加 commit：

```text
sdk/VERSION = 0.1.0
package     = 0.1.0
```

完整 commit 和 dirty 状态单独记录在 manifest 中。当前 bundle 工具不承担 stable tag、clean-tree 或 expected-commit 发布策略；正式发布流程建立前，归档命令拒绝不含 prerelease 的稳定版本。这些规则在真正建立稳定版发布流程时由发布 CI 统一定义，避免在实验阶段提前固化一套发布系统。

同一包中的 manifest、Zig package、Cargo package、README、目录名和归档名必须使用相同 package version，全部由构建生成或校验。

进入内部 artifact storage 的 `<version, target>` 坐标不可覆盖。

## 7. ABI 策略

当前保持：

- ABI version 1；
- revision 3；
- exact revision match；
- experimental 阶段不承诺跨 commit/revision 兼容；
- 只有二进制布局、函数签名、数值或语义契约变化才增加 revision；
- 文档、目录或不影响 ABI 的 binding 修改不增加 revision。

发现符号从 `metacodes_agentcore_get_api` 改为 `metask_agentcore_get_api` 属于 linker ABI 变化；该命名迁移已作为 revision 3 原子更新 Header、静态库、Zig binding、manifest 和消费测试，不提供旧符号别名。

短期内不冻结 v1；稳定兼容和扩展规则留到 freeze audit 再决定。

## 8. Manifest

继续使用 schema 1，首次内部稳定发布前允许调整。最小结构：

```json
{
  "schema_version": 1,
  "vendor": "metask",
  "name": "agentcore",
  "version": "0.1.0-dev+0123456789ab",
  "source": {
    "commit": "<40-hex>",
    "dirty": false
  },
  "toolchain": {
    "zig_version": "0.16.0"
  },
  "target": {
    "id": "x86_64-windows-msvc",
    "architecture": "x86_64",
    "os": "windows",
    "abi": "msvc",
    "zig_target": "x86_64-windows-msvc",
    "rust_target": "x86_64-pc-windows-msvc"
  },
  "build": {
    "optimize": "ReleaseSafe",
    "strip": true
  },
  "link": {
    "requires_c_runtime": true,
    "system_libraries": ["advapi32", "crypt32"],
    "system_frameworks": []
  },
  "contract": {
    "binary_abi_status": "experimental",
    "binary_abi_version": 1,
    "binary_abi_revision": 3
  },
  "files": []
}
```

公共命名迁移是 revision 2 之后的 ABI cut，因此当前值为 revision 3；实际值必须由 ABI 常量生成。源码身份只记录 commit 和 dirty 状态，payload 的实际内容由 `files` 中的 SHA-256 描述。

`files` 列出除 `manifest.json` 自身外的所有 payload 文件及 SHA-256。`libc` 不作为伪库名写进 `system_libraries`；用 `requires_c_runtime` 表达语义。

最低 Windows/MSVC、glibc、macOS deployment target 和 Rust MSRV 在对应 target 真正进入支持状态前确定，不提前设计复杂 compatibility schema。

## 9. 验证门禁

每个包必须在不访问 AgentCore 实现源码的目录中验证：

- C11、C++17、Zig 和 Rust 能使用包内文件完成编译与静态链接；
- 原生 target 上能运行基本 API discovery、Runtime/Session 生命周期和一次 Run；
- C/Zig/Rust ABI layout、常量和函数签名一致；
- manifest target、version、ABI、文件白名单和 SHA-256 正确；
- manifest 声明的系统链接依赖足够；
- Zig/Rust 使用错误 target 的包时在链接前失败；
- Windows `.lib` 不是 import library；
- 对 Header、bindings、manifest 和 README 做 token/text 级旧名称检查；
- 对静态库 exported/global symbol table 做旧符号检查，不扫描 archive 任意字节。

开发阶段不要求四个平台同时完成；哪个 target 通过原生 gate，哪个 target 才可以标记为已支持。

## 10. 实施顺序

1. 增加 `sdk/VERSION`，完成公共命名和导出目录迁移；
2. 合并必要的 facade ABI 调整，增加一次 experimental revision；
3. 更新 C Header、静态库和 C/C++/Zig consumer gates；
4. 增加 Rust `-sys` binding 和 consumer gate；
5. 依次完成 Windows MSVC、Linux GNU、macOS x86_64 与 aarch64 原生验证；
6. 增加简单的内部归档命令和 SHA-256 输出；
7. 实现落地时同步更新当前 ABI 文档。

## 11. 暂缓事项

- 动态库与托管语言 FFI；
- 其他 CPU/OS/ABI target；
- C++/Rust 高层封装；
- crates.io 或其他 registry 发布；
- 四目标原子发布、release record 和 staging/promote 系统；
- RC、签名、公开许可证和外部发布策略；
- reproducible-build 证明与独立 symbols package；
- ABI v1 freeze 后的兼容扩展模型。
