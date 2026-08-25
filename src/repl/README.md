# repl/

终端交互层:REPL 主循环、行编辑、渲染与 headless 模式。

- `loop.zig` — REPL 主循环;slash 命令(`/help` `/compact` `/model` …)
  直接在此派发(没有独立 commands.zig)。
- `input.zig` / `multiline.zig` / `paste.zig` / `vim.zig` / `complete.zig` /
  `history.zig` — termios raw mode 行编辑、多行、粘贴检测、vim 键位、
  补全与历史。
- `render.zig` / `progress.zig` / `statusline.zig` / `transcript_viewer.zig`
  — Markdown/ANSI 渲染与状态显示。
- `headless.zig` / `stream_json_backend.zig` — `-p/--print` 无 REPL 运行与
  NDJSON 输出。
- `tui/` — 状态驱动 TUI(架构见
  [doc/TUI_STATE_ARCHITECTURE.md](../../doc/TUI_STATE_ARCHITECTURE.md))。
