# app/

应用级配置与模型上下文。

- `config.zig` — 持久化配置(`~/.metacodes/config.json`)读写与合并。
- `model_context.zig` + `model_context_default.toml` — 模型上下文窗口/价格等
  元数据(内置默认 + 可覆盖)。

CLI 参数解析与 `printHelp` 在 `src/main.zig`(`parseArgsInto`);
版本常量单源在 `src/version.zig`。
