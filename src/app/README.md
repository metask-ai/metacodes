# app/

应用级配置。

- `config.zig` — 持久化配置(`~/.metacodes/config.json`)读写与合并。

CLI 参数解析与 `printHelp` 在 `src/main.zig`(`parseArgsInto`);
版本常量单源在 `src/version.zig`。
