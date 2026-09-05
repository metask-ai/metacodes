# vendored ripgrep(manifest-pinned 跨平台二进制)

- 上游:https://github.com/BurntSushi/ripgrep
- 版本:15.2.0 (rev e89fff89ac)(`rg --version` 可验)
- 许可:双许可 MIT OR Unlicense,见同目录 `LICENSE-MIT`(再分发所需)。
- 清单:`manifest.json`(`metacodes.ripgrep-bundle/v1`)按 target 钉每个二进制的
  SHA-256;`scripts/verify_ripgrep_binary.py` 做 fail-closed 校验(哈希、格式
  magic、`bin/` 目录清单与 manifest 严格一致——未声明的可执行文件即失败)。

## 二进制来源(全部为上游官方 release 资产,未修改)

| bin/ 文件 | 上游资产(release 15.2.0) | 资产 SHA256 |
|---|---|---|
| `rg-macos-aarch64` | `ripgrep-15.2.0-aarch64-apple-darwin.tar.gz` | `3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4` |
| `rg-macos-x86_64` | `ripgrep-15.2.0-x86_64-apple-darwin.tar.gz` | `af7825fcc69a2afc7a7aea55fc9af90e26421d8f20fe59df32e233c0b8a231c1` |
| `rg-linux-x86_64` | `ripgrep-15.2.0-x86_64-unknown-linux-musl.tar.gz`(static-pie) | `33e15bcf1624b25cdd2a55813a47a2f95dbe126268203e76aa6a585d1e7b149c` |
| `rg-linux-aarch64` | `ripgrep-15.2.0-aarch64-unknown-linux-musl.tar.gz`(static-pie,15.x 起上游才提供 aarch64 musl,#86) | `800b1e7206afe799dfb5a6901f23147cfaabe0e52210538100f61e86e1740915` |
| `rg-windows-x86_64.exe` | `ripgrep-15.2.0-x86_64-pc-windows-msvc.zip` | `71b2fef860abe467217a538ff31de02f5258807c0129f771846f87bd029aafc5`(rg.exe 本体 SHA256 见 manifest) |

资产 SHA256 逐一对照上游 release 的 `.sha256` 伴随文件与 GitHub Releases API 公布的 digest 核验后落库;二进制本体的
SHA-256 钉在 `manifest.json`。

上游没有 aarch64-windows 二进制:manifest 显式把 `rg-windows-x86_64.exe` 声明给
`aarch64-windows` target——Windows-on-ARM 经系统内建 x64 仿真执行它(功能完整,
性能次优),而不是让 ARM64 Windows bundle 缺少可用的 rg。

## 用途

1. **AgentCore bundle 运行期资产**:`zig build agentcore:bundle` 经
   `scripts/stage_ripgrep_binary.py` 按 target 校验 SHA-256 后把对应二进制
   staging 为 bundle 内 `bin/rg[.exe]`,并进入 bundle manifest 的 `files`
   allowlist 与 `runtime_assets` 声明——Glob/Grep 的执行依赖随包分发,
   宿主部署时放到自身可执行文件旁(或以 `RG_BIN` 指向)即可。
2. **开发/CI fallback**:`src/util/toolchain.zig` 的 fallback 路径按编译
   target 指向本目录对应二进制——机器无系统 rg 时 Grep/Glob 工具与其测试
   仍可用。

## 更新流程

下载新版官方 release 资产 → 用上游 `.sha256` 核验 → 解出二进制放入 `bin/`
(命名 `rg-<os>-<arch>[.exe]`)→ 更新 `manifest.json` 的 SHA-256 与版本字段、
本文件的来源表 → `python3 scripts/verify_ripgrep_binary.py` 通过后提交。
