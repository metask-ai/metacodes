# util/

跨模块共用工具。**这里不放业务逻辑**——只放纯函数、类型、helpers。

| 文件 | 职责 | 来源（迁移后） |
|---|---|---|
| `json.zig` | 纯 JSON：`unescapeString`、`findJsonObjectEnd`、`findJsonArrayEnd`、`extractJsonString` | `src/json.zig` SSE 之外的部分 + `src/client.zig:346-421` |
| `abort.zig` | `AbortSignal`：atomic flag + reason enum + SIGINT handler 绑定 | M1 新建 |
| `toolchain.zig` | vendor 工具（ripgrep 等）路径解析 | 现 `src/toolchain.zig`（若存在）迁入 |
| `alloc.zig` | `makeList(T, a)` 等分配器抽象层，屏蔽 Zig 0.17 dev API 漂移 | M0 新建 |

占位目录。
