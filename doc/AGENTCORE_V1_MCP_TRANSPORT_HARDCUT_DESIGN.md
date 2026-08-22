# AgentCore ABI v1 Revision 9 hard cut：MCP HTTP AUTO 协商设计

> 状态：已实施并通过 ABI、真实 HTTP 组件和 source-free consumer 验证
> 日期：2026-08-22
> 目标：修复 2025-only Streamable HTTP Server 对 2026 probe 返回 HTTP 400 时，
> `MCP_NEGOTIATION_AUTO` 无法进入 Classic 的问题。

## 1. 问题

Revision 9 的 Host Connector 把 HTTP 400 折叠为
`MCP_EXCHANGE_SERVER_ERROR`。该状态既不携带 HTTP status，也不允许携带 body，
AgentCore 无法区分：

- 2025-only Server 按兼容规则拒绝 2026 probe；
- 401/403；
- 429/5xx；
- 普通网络或服务故障。

因此问题位于 Host transport 与 AgentCore protocol negotiation 的 ABI 边界，不应通过
放宽所有 `SERVER_ERROR` 来修复。

MCP 规范要求版本不匹配在 HTTP 上返回 400，并允许支持新旧 era 的 client 随后进入
legacy initialize：

- [SEP-2575 Unsupported Protocol Versions](https://modelcontextprotocol.io/seps/2575-stateless-mcp#unsupported-protocol-versions)
- [SEP-2575 Backwards Compatibility](https://modelcontextprotocol.io/seps/2575-stateless-mcp#backwards-compatibility)

## 2. 设计决定

只调整一个边界：

> Host 上报完整 HTTP response 的 status 与 body；AgentCore 负责解析 MCP 协议并决定
> 是否降级。

不新增 `PROTOCOL_INCOMPATIBLE` 状态。否则 Host 需要理解 JSON-RPC
`-32022`、`-32601` 和后续协议错误，协议责任会泄漏到每个消费方。

不重做 Connector、Catalog、Session 或 checkpoint，不改变已有 exact-era connection、
final revalidation 和 no-replay 规则。

## 3. 最小 ABI 变化

新增 request response descriptor：

```c
typedef struct {
    uint32_t struct_size;
    uint32_t http_status;
    metask_agentcore_owned_bytes_v1 body;
    uint64_t reserved[2];
} metask_agentcore_mcp_response_v1;
```

`mcp_request_fn_v1` 的最后一个参数由
`metask_agentcore_owned_bytes_v1 *` 改为
`metask_agentcore_mcp_response_v1 *`：

```c
typedef uint32_t (*metask_agentcore_mcp_request_fn_v1)(
    void *connector_ctx,
    void *connection_ctx,
    metask_agentcore_bytes_view_v1 request_json,
    uint32_t timeout_ms,
    const metask_agentcore_mcp_cancellation_v1 *cancellation,
    metask_agentcore_mcp_response_v1 *out_response);
```

现有 callback return codes 保留：

- `MCP_EXCHANGE_RESPONSE`：收到了完整 peer response；
- timeout/network/auth/server-error/child-exit/cancelled/indeterminate：没有完整 response；
- fatal：Host callback 合同失败。

约束：

- Streamable HTTP 的任何完整最终响应，不论 2xx、4xx、5xx，都返回
  `MCP_EXCHANGE_RESPONSE`，并填写 `http_status`；
- stdio response 的 `http_status` 必须为 0；
- 非 `MCP_EXCHANGE_RESPONSE` 的 status/body 必须为 0/empty；
- Streamable HTTP 的完整响应 body 允许为空（包括 2xx）；若非空，仍执行原有
  size/bounds 检查。stdio response 仍要求非空；
- `MCP_EXCHANGE_SERVER_ERROR` 保留：它只表示没有形成完整 peer response 的 Host/transport
  server failure，`http_status=0`、body empty，沿用现有 `.server_error` 分类且永不触发降级；
- Host-owned body 延续 exactly-once release 规则。现有
  `McpReleaseResponseFnV1` 签名不变，AgentCore 必须把
  `&out_response->body` 传给它；任何非 canonical empty body 都 exactly-once release；
- `notify`、`open` 和 `close` callback 不变。本问题只发生在 request/response probe。

这是 callback signature 的 breaking change。当前 Revision 9 尚未冻结发布，因此本次先
直接 hard-cut Revision 9 的 header、Zig/Rust SDK、manifest、AgentCore 和消费方，不保留
旧 callback shim。是否在发布前另行增加 `abi_revision`，作为独立发布决策处理；
negotiation policy 数值保持不变。

## 4. AgentCore 分类规则

### 4.1 Disposable Modern probe

仅 disposable Modern probe 使用以下规则：

1. 先验证 descriptor、status/body bounds，再按 HTTP status 设门：
   - 2xx 和 400 可以进入协议解析；
   - 401/403 立即返回 auth failure；
   - 其它任何 HTTP status（包括 3xx、其它 4xx、5xx）都失败且不降级；
   - stdio 的 `http_status=0` 直接进入协议解析。
2. 对允许进入协议解析的 body，若是合法、request id 匹配的 JSON-RPC response：
   - DiscoverResult：选择最高 mutual version；
   - `-32022 UnsupportedProtocolVersion`：严格验证 `requested` 和 `supported`，选择最高
     mutual version；
   - `-32601 MethodNotFound`：AUTO 进入 2025-11；
   - 其它 JSON-RPC error：失败，不降级。
3. HTTP 400 的 body 若不能形成上述合法、匹配的 JSON-RPC response：
   - AUTO 进入 2025-11；
   - exact policies 失败。
4. HTTP timeout、network/auth/server-error、cancelled、indeterminate：失败，不降级。
5. stdio 继续保留现有 MethodNotFound、probe timeout、child exit → Classic 规则。

这里不引入“看起来像 JSON-RPC”的启发式。HTTP 400 本身已经是 AUTO probe 接受的
legacy evidence；再按字符串前缀或局部 JSON shape 区分 empty、HTML、截断 JSON 和
malformed envelope，既不缩小降级面，也会制造另一套不稳定分类。只有完整、匹配且通过
协议验证的 response 能覆盖 HTTP 400 的默认 legacy evidence。

因此 empty、非 JSON、截断 JSON、invalid envelope 和 response-id mismatch 在 HTTP 400
AUTO probe 下都进入 Classic；但一个 envelope 若已被完整识别为 `-32022`，其
`requested/supported` 畸形属于 typed protocol failure，不能退回 bare-400 路径。
后续仍由新开的 exact Classic handshake 重新验证，不会把 probe connection 升格。

HTTP status gate 先于 body 语义：401/403、3xx、其它 4xx 或 5xx 即使携带
`-32601`/`-32022` body，也不得成为降级证据。

### 4.2 非 probe request

actual connection 上的 initialize/revalidation、tools/list、tools/call 等 request 不执行
era 分类。Connection 层先按 transport/status 折回 Revision 9 已有失败类型：

| Observation | 非 probe 结果 |
|---|---|
| stdio response，或 HTTP 2xx response | 进入现有 era-specific response parser |
| HTTP 401/403 | `.auth_error` |
| 其它任何 HTTP 非 2xx（含 3xx、400、404/405、408/429、5xx） | `.server_error` |
| timeout/network/auth/server-error/child-exit/cancelled/indeterminate | 沿用现有同名 failure |

因此 HTTP 500 + HTML body 的 `tools/call` 仍是 `.server_error`，不会流入
`parseCallToolResponse` 变成 malformed diagnostic；HTTP 400 + JSON-RPC body 在非 probe
路径同样按 `.server_error` 处理。所有这些路径均只调用一次，不换 era、不 replay。

## 5. 连接生命周期保持不变

```text
AUTO
  → open disposable Modern probe
  → classify response
  → close probe
  → open selected exact era
  → exact handshake/revalidation
  → list tools
  → publish final catalog
```

- probe connection 永不升格；
- probe 与 actual 不共享 HTTP session id 或 mutable state；
- 2025-11 initialize 选择 2025-06 时，继续 close 并 exact reopen 2025-06 一次；
- 只有 final exact handshake 的 capabilities 可以发布；
- actual connection 建立后的 HTTP 400/`-32022` 不在原连接内换 era；
- `tools/call` 失败不换 era、不自动重放。

## 6. 安全边界

允许 bare HTTP 400 成为 legacy evidence 只限于：

```text
policy=AUTO + purpose=disposable_probe + operation=server/discover
```

并要求 probe 与 actual 使用相同：

- `server_binding_identity`；
- configuration fingerprint；
- endpoint、TLS/redirect policy 和 authentication context。

降级不改变 canonical Tool identity、Permission、schema admission 或 Session authority。
401/403、5xx、timeout/network 不得借该路径降级。

## 7. 必须测试的场景

### ABI

- 新 descriptor 的 C/Zig/Rust size、align、offset；
- HTTP response status/body 传递；
- stdio status 必须为 0；
- 非 response 携带 status/body 被拒绝；
- body 在成功、非法和超限路径 exactly-once release；
- Revision 9 与任何其它 revision 的 exact mismatch 明确失败。

### Negotiation

| Probe 结果 | AUTO 结果 |
|---|---|
| HTTP 200 valid DiscoverResult | Modern |
| HTTP 400 empty/non-JSON body | 2025-11 initialize |
| HTTP 400 truncated JSON / invalid envelope / response-id mismatch | 2025-11 initialize |
| HTTP 400 + valid `-32601` | 2025-11 initialize |
| HTTP 400 + valid `-32022` supports 2025-06 | exact 2025-06 |
| malformed `-32022` | fail |
| HTTP 400 +其它合法 JSON-RPC error | fail |
| 401/403、404/405、429、5xx | fail，不 fallback |
| 未单列的 status（例如 302、422） | fail，不 fallback |
| timeout/network/cancelled/indeterminate | fail，不 fallback |
| exact Modern + HTTP 400 | fail，不 fallback |
| `tools/call` HTTP 401/403 | `.auth_error`；一次调用，无 replay/era switch |
| `tools/call` HTTP 400/5xx | `.server_error`；一次调用，无 replay/era switch |
| `tools/call` indeterminate | `.indeterminate`；一次调用，无 replay/era switch |
| 2025-11 handshake 选择 2025-06 | close + exact reopen 一次 |

至少一个组件测试必须使用真 HTTP Server，经 MetaWork-style Connector 进入 public ABI；
不能只用 coarse fake enum，否则会再次漏掉 transport observation。

## 8. 非目标与影响审计

- 不支持自动切换到 legacy HTTP+SSE；404/405 不触发 transport fallback；
- 不改变 Host-owned OAuth、headers、cookies、session id 或 connection pooling；
- 不新增 negotiation cache、catalog schema 或 checkpoint 字段；
- CLI/App 的 `src/mcp` 仍是独立 stdio-only Classic client，没有 HTTP/AUTO 路径，本次只跑
  回归，不修改其实现。

## 9. 完成标准

只有同时满足以下条件，才能宣称 Streamable HTTP AUTO 降级完成：

1. MetaWork 能上报完整 HTTP status/body；
2. AgentCore 能处理 bare 400、`-32022`、`-32601` 三条路径；
3. exact policies 和非 probe operation 永不降级；
4. auth、5xx、timeout/network 不被误判为 legacy；
5. probe/actual 隔离、final exact revalidation 和 no-replay 不变量保持；
6. 真 HTTP 2025-only/2026-only consumer matrix 通过。

在这些条件完成前，不修改 Revision 9 的 `SERVER_ERROR` fallback 行为。
