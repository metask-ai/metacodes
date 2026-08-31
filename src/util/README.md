# util/

跨模块共用工具。**这里不放业务逻辑**——只放纯函数、类型、helpers。

| 文件 | 职责 | 来源（迁移后） |
|---|---|---|
| `json.zig` | 纯 JSON：`unescapeString`、`findJsonObjectEnd`、`findJsonArrayEnd`、`extractJsonString` | `src/json.zig` SSE 之外的部分 + `src/client.zig:346-421` |
| `abort.zig` | `AbortSignal`：atomic flag + reason enum + SIGINT handler 绑定 | M1 新建 |
| `toolchain.zig` | vendor 工具（ripgrep 等）路径解析 | 现 `src/toolchain.zig`（若存在）迁入 |
| `alloc.zig` | `makeList(T, a)` 等分配器抽象层，屏蔽 Zig 标准库容器 API 漂移 | M0 新建 |
| `file_lock.zig` | 跨进程 advisory 文件锁：`<path>.lock` O_EXCL 哨兵 + 陈旧检测 + 原子两阶段抢占 | `src/swarm/file_lock.zig`（swarm 之外已有 4 个消费者，非 swarm 专属） |

工具链版本契约见 `build.zig.zon` 的 `minimum_zig_version`。
