# Tree-sitter 支持（历史说明）

本文档描述的是 2026-07-13 之前的实验实现，已经不再对应当前仓库，不能作为
构建、工具能力或依赖清单使用。Tree-sitter runtime、grammar、`src/treesitter/`
以及相关下载脚本已从 metacodes 移除；当前构建不会编译或下载 Tree-sitter。

当前实现以 `highlight-zig` 提供 diff/源码高亮。它是仓库唯一保留的源码级高亮
依赖，纯 Zig、无 C runtime；`src/lib.zig` 会通过 `hl` module 接入。CodeMap、
FindSymbol 和 Read outline 使用 LSP/现有文本工具链，不依赖 Tree-sitter。

如果需要了解当前可消费的库模块和工具边界，请看：

- [metacodes 嵌入接口](LIB_API.md)
- [API 总览](API.md)
- [插件架构](PLUGIN_ARCHITECTURE.md)

历史设计内容保留在 Git 历史中，不应复制回当前构建图或作为公开 API 承诺。
