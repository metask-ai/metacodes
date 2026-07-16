# vendored ripgrep(Windows)

- 上游:https://github.com/BurntSushi/ripgrep
- 版本:14.1.1 (rev 4649aa9700)(`rg.exe --version` 可验)
- 构建:上游官方 release `ripgrep-14.1.1-x86_64-pc-windows-msvc`
- SHA256(rg.exe):`f162b54de2adfc72d78adb1dbada2dedda111ae0a5e2f6e9500f4f909664c5d2`
- 许可:ripgrep 双许可 MIT OR Unlicense,见同目录 `LICENSE-MIT`(再分发所需)。

用途:`src/util/toolchain.zig` 的 Windows fallback 路径 `vendor\ripgrep\rg.exe`——
机器无系统 rg 时 Grep/Glob 工具与其测试仍可用。更新时同步本文件的版本与 SHA256。
