# permission/

权限决策链:模式、规则、交互授权与 hooks。已完整实现(早期"骨架"阶段
的描述已过时);对齐 Claude Code 的权限语义。

- `mode.zig` — 官方权限模式枚举与 CLI 解析。
- `decision.zig` — `check(...) -> allow | deny | ask` 决策核心。
- `rule_spec.zig` / `rule_matcher.zig` — 规则语法(`Bash(git status:*)` 等)
  解析与匹配;`bash_parser.zig` 供 Bash 命令结构化。
- `bash_readonly.zig` — Bash 免询问与并发安全共用的严格只读判定(按 `sh` 词法
  完整解析,每段只读,拒写重定向/替换/写选项;无法判定即非只读)。
- `prompt.zig` — 交互授权(UiRequest 桥、会话内记忆、
  `settings.local.json` 持久化)。
- `settings.zig` / `settings_writer.zig` / `loader.zig` — 设置文件读写。
- `session_rules.zig` — 会话级授权状态。
- `hooks.zig` — 权限 hooks。
- `category.zig` — ToolCategory / RiskLevel。

`PermissionContext` 等聚合类型在上层 `src/permission.zig`。
规则语义以本目录类型与 `tests/component` 权限测试为准。
