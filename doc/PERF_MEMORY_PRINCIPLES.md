# PERF_MEMORY_PRINCIPLES — cc-zig 极致性能/内存 设计原则 + 量化指标

> 来源:2026-06-05 session。用户定架构总目标:**极致的性能和内存使用**。本文是所有后续改动(含 UI 解耦/事件协议)的总约束。
> 基线实测(2026-06-05,ReleaseSmall,macOS):见 §1。任何改动不得显著回退基线。
> 关联:TUI_STATE_ARCHITECTURE(UI 解耦)、UI 双向协议设计——它们必须遵守本文热路径零分配约束。

## §1 实测基线(2026-06-05)

| 维度 | 当前值 | 说明 |
|------|--------|------|
| 二进制体积(ReleaseSmall) | **1.29 MB** | metacodes;Debug 8.6 MB |
| 启动时间(暖) | **<10 ms** | --help 路径;首次冷启 ~0.7s 是磁盘加载非代码 |
| 常驻内存峰值 | **1.78 MB RSS / 1.08 MB footprint** | --help 路径(未含对话/工具/网络) |
| 源码规模 | 127 文件 / 40K 行 | |

对比 Claude Code(Node/TS):RSS 数百 MB、启动秒级。cc-zig 已是**数量级优势**——目标是**守住并扩大**,绝不因功能堆叠回退。

## §2 量化目标指标(后续对标)

- **二进制**:ReleaseSmall ≤ 1.5 MB(留 0.2 MB 给新功能;超了要查 bloat)。
- **启动(暖)**:≤ 20 ms 到首个 prompt 可交互。
- **常驻内存**:空闲(无对话) ≤ 3 MB RSS;典型会话(20 轮 + 工具)≤ 30 MB RSS。
- **流式热路径**:每 token(text_chunk)**零堆分配**;spinner tick(100ms)单帧渲染 ≤ 单次 scratch 复用,无 per-tick alloc。
- **工具并发**:每工具独立 arena,批结束整体释放(已有)。

(指标是初版,实测校准。每次 release 跑基线脚本对比,回退 >10% 要查因。)

## §3 设计原则(所有改动遵守)

### 3a. 热路径零分配(最高优先级)
- **流式文本/spinner/工具进度** = 热路径(每 token / 每 100ms)。**绝不 per-event 堆分配**。
- 手段:借用 slice 同步消费(不持有)、定长数组(current_tool[48]/tool_cards)、scratch writer 复用(resetScratch 非重建)、行缓冲 line_buf 复用容量(clearRetainingCapacity)。
- **UI 事件协议(CoreEvent)**:emit 的 slice 是 borrow,backend 同步消费(写 scrollback/拷定长),**不堆分配、不持有**。进程内 vtable = 零序列化零拷贝。

### 3b. Arena 批量释放优于逐个 free
- 临时分配(一轮工具/一次请求)挂 arena,批量释放(已有)。命名:gpa(调用者释放)/arena(批量)/scratch(不逃逸)。
- 避免长生命周期持有短期数据（工具结果从 byte zero 写 Session CAS，Conversation 只持 artifact receipt）。
- 静态工具必须声明 `ResultProduction`：未知规模的外部生产者只能是 `byte_zero_spool`，并由
  comptime 拒绝 legacy callback；确定有界结果用 `bounded_inline`，编辑类结果用
  `input_derived`。不能用“之后会投影”替代生成期 OOM 边界。

### 3c. 定长 + 值语义优于动态 + 指针
- 跨线程状态用定长数组 + 持锁拷贝(防 {ptr,len} 撕裂 + 防悬挂)——见 UiState.tools。
- ID/key 用定长数组值语义(防 collection grow 悬挂)。

### 3d. comptime 消除 vs 运行时分发的权衡
- 进程内热路径:能 comptime 特化的(如 headless 无 UI 方法编译期消失)优先。
- 但 UI 解耦要 vtable(运行时分发)以支持 GUI/语音/跨进程——vtable 调用开销(一次间接跳转)远小于序列化,可接受;**热路径(text_chunk)的 vtable emit 仍须零分配**。

### 3e. 序列化只在跨进程边界付代价
- 进程内 vtable backend:CoreEvent 直传,**不序列化**。
- 进程外 WsBackend(未来):才 JSON 序列化。协议可序列化是为了**能**跨进程,不是**总是**序列化。token 级事件量大,进程内绝不序列化。

### 3f. 二进制体积:ReleaseSmall + 按需链接
- 默认 ReleaseSmall(已 1.29 MB)。新依赖/大表(verb 库/工具 schema)评估体积。vendor 工具(ripgrep)进程外调用,不进二进制。

## §4 验证机制

- **基线脚本**(scripts/perf_baseline.sh):量二进制体积 + 启动时间 + --help RSS,输出对比上次。每阶段/release 跑。
- **热路径零分配验证**:关键路径(流式/spinner)用 testing.allocator 或 failing_allocator 在单测里确认无意外分配(Zig 可注入 allocator 计分配次数)。
- **回退红线**:二进制 >1.5MB / 启动 >20ms / 空闲 RSS >3MB → 查因,不放行。

## §5 与 UI 解耦架构的交点(硬约束)

UI 双向协议(CoreEvent/UiEvent)+ vtable UiBackend 必须遵守:
- text_chunk/tool_progress 热路径 emit 零堆分配(borrow 同步消费)。
- 进程内默认零序列化(vtable 直传)。
- TuiBackend.emit 复用现有 scratch/line_buf/定长卡,不新增 per-event 分配。
- 这条是 UI 解耦能做的前提——若 vtable emit 引入热路径分配,宁可不解耦。
