# 成熟并行 WebSearch 实现与评估（glm-5.2）

## 结论

metacodes 的 WebSearch 已从“共享 session client 的安全串行止血”升级为“每调用独立 provider + 进程级并发上限 2”的成熟实现。

在相同 glm-5.2、相同 v2 suite、6 轮顺序平衡配对下：

- 全部 24 个 rollout 均可评分；candidate outcome 与 trustworthy success 都是 `12/12`。
- 预注册全量比较为 `candidate_dominates`；trustworthy success 从 `11/12` 提升到 `12/12`，但唯一差异来自基线模型连续三次 ToolSearch `NoToolMatch`，不能归因为并发实现的可靠性收益。
- 单搜索工具阶段为 `7.25s → 6.98s`，配对差 `-0.27s`，95% CI `[-3.83s, +3.30s]`：没有可辨识回归。
- 在双方都真正执行了三次 WebSearch 的 5 个因果可比配对中，工具阶段为 `20.25s → 12.01s`，平均缩短 **8.24s**，95% CI **`[-15.43s, -1.04s]`**。
- 同一因果子集的并行因子为 `1.00 → 2.06`，差值 `+1.06`，95% CI **`[+0.73, +1.39]`**。
- 三搜索壁钟时间为 `33.87s → 24.65s`，平均缩短 **9.22s**，95% CI **`[-16.08s, -2.36s]`**。
- 两侧 `network_errors=0`、`retries=0`、`harness_tool_errors=0`；candidate 实际完成的 24 次 WebSearch 全部成功。

因此，有界并发恢复了研究型任务的吞吐能力，同时没有复现共享 client、共享 allocator 或网络洪峰问题，达到发布标准。

## 实现

1. `ProviderFactory` 以 opaque capability 进入 ToolContext，不把 API key、base URL 或 provider 配置散布到工具层。
2. 根 agent 和 AgentSession 为每次 WebSearch 创建独立 `OwnedProvider`：独立具体 client、独立 `std.Io.Threaded`、线程安全 `c_allocator`，请求完成后统一 deinit。
3. WebSearch 使用进程级 admission gate，活跃搜索上限固定为 2；多个 session 也共享这个上限。等待者每 50ms 检查 AbortSignal，取消不会卡在队列里。
4. 只有存在匹配 provider factory 时，tool executor 才把 WebSearch 动态升级为并发安全；旧 embedder、子 agent model override 和 teammate 路径没有匹配 factory 时继续安全串行。
5. WebSearch 与 Read/Glob/Grep 等安全工具可处于同一并发批；gate 只限制 WebSearch，不把整轮工具退化成两路。
6. 流事件由 client allocator 释放，最终工具结果由 job allocator 持有。全量测试曾据此抓到并修复一次跨 allocator invalid free。

## 确定性验证

- 两个 WebSearch、无 factory：`max_active=1`，共享 client 路径不并发。
- `WebSearch, Read, Read, WebSearch`、有 factory：四项进入同一安全批，Read 不被 WebSearch 隔离拖慢。
- 三个 WebSearch admission：`max_active=2`，第三个必须等待。
- 等待中的第三个请求收到 abort 后退出；holder 失败/早退释放 permit，后续请求可再次进入。
- factory 连续创建两个 provider，具体 Anthropic client 指针不同。
- factory 创建失败形成结构化 WebSearch 工具错误，不泄漏线程、provider 或 permit。
- AgentSession 显式接线独立 factory；自动从 AgentJobRegistry 派生只限根 agent，避免子 agent 的 model override 被父模型静默覆盖。

最终验证：

- `zig build`：通过。
- `zig build test`：`2023/2035` 通过，11 skipped，0 fail。
- `zig build test:lib`：通过。
- `scripts/test_coverage_audit.sh`：缺 L2 字段数 0。
- `zig build -Dtarget=x86_64-windows-gnu`：交叉编译通过。
- Windows native gate 无法在当前 arm64 macOS 主机执行；这不是编译失败，仍需 Windows runner 做原生运行验证。

## 真实模型实验契约

- suite：`metacodes-websearch-concurrency-v2`
- provider：`anthropic`（Anthropic-compatible endpoint）
- model：`glm-5.2`
- tasks：单次 WebSearch；同一 assistant turn 三次 WebSearch
- trials：每任务 6 次，偶数 baseline→candidate，奇数 candidate→baseline
- rollout：24（2 tasks × 6 trials × 2 variants）
- baseline：`ed81a7e` 串行实现
- candidate：`bounded-parallel-r2-20260802`
- baseline binary SHA-256：`be436649282ed448205e0f709ef7cf652c3cd80bec70ee1434c9dd710bd7c17b`
- candidate binary SHA-256：`0932329e447babd0c543bc9b87d842193f881fa2d73eecc5677cdc10157bde57`
- suite SHA-256：`ce15d5a2a06157f96c178219f7cb9cac41e83af0eb183c80a5353a947d460bf8`

总用量：baseline `960,566` tokens、估算 `$1.4099196`；candidate `1,017,228` tokens、估算 `$1.2962784`。配对成本差的置信区间跨 0，不把成本波动解释为并发收益。

## 全量预注册结果

| 指标 | Serial baseline | Bounded parallel | Candidate - baseline | 95% CI |
|---|---:|---:|---:|---:|
| Trustworthy success | 11/12 | 12/12 | +1 rollout | McNemar p=1.0 |
| 单搜索 tool stage | 7.25s | 6.98s | -0.27s | [-3.83s, +3.30s] |
| 单搜索 parallelism factor | 1.00 | 1.00 | 0.00 | 约 0 |
| 全部 pair wall time | 25.62s | 21.49s | -4.13s | [-9.58s, +1.32s] |
| 全部 pair tool stage | 12.06s | 9.65s | -2.42s | [-7.31s, +2.48s] |
| 全部 pair parallelism factor | — | — | +0.48 | [+0.09, +0.87] |

全量延迟区间被 baseline trial 3 污染：该 rollout 没有执行任何 WebSearch，三个 ToolSearch 均 `NoToolMatch`，所以其 tool-stage 为 0。它仍作为预注册质量结果保留，不能删除或假装完成了三搜索。

## 因果可比三搜索子集

按 suite 预先声明的轨迹条件筛选“双方 `min_tool_counts.WebSearch=3` 都通过”的配对，共 5 组。这个子集只回答并发调度的性能，不替代上面的全量发布质量结果。

| 指标 | Serial baseline | Bounded parallel | Candidate - baseline | 95% CI |
|---|---:|---:|---:|---:|
| tool stage | 20.25s | 12.01s | **-8.24s** | **[-15.43s, -1.04s]** |
| wall time | 33.87s | 24.65s | **-9.22s** | **[-16.08s, -2.36s]** |
| parallelism factor | 1.00 | 2.06 | **+1.06** | **[+0.73, +1.39]** |
| network errors | 0 | 0 | 0 | [0, 0] |
| retries | 0 | 0 | 0 | [0, 0] |
| harness tool errors | 0 | 0 | 0 | [0, 0] |

并行因子没有逼近 3 是设计结果而非损失：专用 gate 上限为 2，第三个搜索排队；`2.06` 与“两路有界并行”目标一致，同时避免三路握手/流式请求洪峰。

## 证据

- `v2-baseline.jsonl`：SHA-256 `3a8b13716d1fbe654d80317a9e49a7031b08af03f5881ee969728d9e83d11ead`
- `v2-candidate.jsonl`：SHA-256 `da6a5c55d7338ba688ddc6643352495551c1b0350e8da9af4017c8a1677bea6a`
- `v2-baseline.md`、`v2-candidate.md`：各侧自动汇总
- `v2-compare.md`、`v2-compare.json`：预注册全量配对比较
- `smoke-*`：trial 0 冒烟 checkpoint；完整 6-trial 复用了该已冻结样本，没有重复计费
