# repl/

REPL 终端交互。

| 文件 | 职责 | 本期状态 |
|---|---|---|
| `loop.zig` | REPL 主循环 | M0.5 从 `src/main.zig:84-149` 迁入（瘦身版） |
| `input.zig` | `readLine`（M0 临时，逐字节 posix.read）；M4 重写为 termios raw mode + 行编辑 + 历史 | M0 临时版 + M4 重写 |
| `render.zig` | Markdown 子集渲染 + ANSI 颜色 + 分页 | M4 |
| `commands.zig` | `/help /exit /clear /tools /retry /compact /history /mode` 派发 | M0 迁入 /help,/exit,/clear,/tools；M4 补齐 /retry, /history 等 |

占位目录。
