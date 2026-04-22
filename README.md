# Claude Code CLI — Zig Port

> 从 Anthropic Claude Code CLI 泄漏源码 (2026-03-31) 移植到 Zig

## 状态

✅ **可运行** — REPL 基本功能已实现

## 构建与运行

```bash
cd /home/raymond/prj/cc-zig
zig build
./zig-out/bin/cc
```

## 当前功能

- ✅ REPL 交互界面
- ✅ 命令处理 (/help, /exit, /clear, /tools)
- ✅ 消息历史 (std.ArrayList)
- ✅ 命令行参数解析
- ✅ 核心类型定义 (Config, Message, App, ToolDefinition)

## 架构

```
cc-zig/
├── build.zig              # Zig 构建配置
├── src/
│   └── main.zig           # 入口 + REPL + 核心类型
└── README.md
```

## 待实现

- [ ] Anthropic API 客户端
- [ ] 工具系统 (Read, Write, Bash, Grep)
- [ ] 权限系统
- [ ] TUI 增强 (分页、颜色主题)
- [ ] MCP/LSP 协议支持
- [ ] 插件架构

## 技术栈

| 组件 | 技术 |
|------|------|
| 语言 | Zig 0.17 |
| 分配器 | ArenaAllocator |
| I/O | std.Io + posix.read |
| 容器 | std.ArrayList |
| 构建 | zig build |

## 原版 vs Zig 端口

| 组件 | 原版 (TypeScript/Bun) | Zig 端口 |
|------|----------------------|----------|
| 运行时 | Bun | 原生编译 |
| UI | React + Ink | 终端原生 |
| 类型 | 运行时检查 | 编译时检查 |
| 体积 | ~50MB+ | <1MB |
| 启动 | ~2s | <100ms |