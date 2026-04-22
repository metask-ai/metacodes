# app/

应用生命周期与入口辅助。

| 文件 | 职责 | 来源（迁移后） |
|---|---|---|
| `args.zig` | CLI 参数解析 + printHelp | `src/main.zig:38-78` |
| `config.zig` | Config 结构体 + 合并优先级（env > CLI > file > default） | `src/types.zig:4-9` + 未来扩展 |
| `constants.zig` | VERSION / ANTHROPIC_API_URL / 默认 model 等常量 | `src/main.zig:8`, `src/client.zig:7-8` |

占位目录 — M0.5 开始填充。
