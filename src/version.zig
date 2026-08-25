//! Single in-source authority for the metacodes semver string.
//!
//! `build.zig.zon` 的 `.version` 是仓库层的版本声明;本常量是代码侧唯一拷贝,
//! 由 main(--version)、lib(公开 VERSION)、MCP clientInfo 共同消费。两者的一致性
//! 由 `scripts/eval/runtime_arm_smoke.py` 的 --expected-version 断言在
//! `zig build test` 中端到端强制:build.zig 读取 build.zig.zon 传入期望值,
//! smoke 用真实二进制的 `--version` 输出比对——改一处漏一处会直接红。

pub const semver = "0.1.0";
