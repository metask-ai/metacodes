# permission/

权限模块骨架。

**本期（M0-M4）范围限定**：仅保留接口与骨架逻辑，完整权限由未来的沙箱方案（seccomp / landlock / namespace）实现。

| 文件 | 职责 | 本期状态 |
|---|---|---|
| `mode.zig` | `Mode` 枚举：default / accept_edits / bypass / plan / dont_ask；CLI 解析 | 完整实现 |
| `decision.zig` | `Decision` union + `check(ctx, tool, input) -> .allow \| .deny(reason) \| .ask(reason)` | 骨架：bypass → allow；plan → write/exec 类 deny；危险命令命中 → deny；其他 → allow |
| `context.zig` | `PermissionContext`（持 Mode、RuleSet、Prompter、Hooks 引用） | 仅字段 + init |
| `rule.zig` | Rule DSL：`Bash(git status:*)` / `Read(/tmp/**)` | **空实现，`TODO(sandbox)` 注释** |
| `prompt.zig` | 用户交互 y/n/A/q | **空实现，`TODO(sandbox)` 注释** |
| `category.zig` | ToolCategory / RiskLevel | `src/permission.zig:12-76` 迁移 |

占位目录 — M0.6 开始填充骨架。
