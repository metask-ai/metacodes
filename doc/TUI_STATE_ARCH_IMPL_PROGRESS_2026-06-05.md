# TUI_STATE_ARCH_IMPL_PROGRESS_2026-06-05 — 状态驱动架构分阶段实施记录

> 配套 TUI_STATE_ARCHITECTURE(设计稿)。本文记录 2026-06-05 逐阶段落地结果 + 阶段5诚实范围判断。

## §7 实施进度(2026-06-05 落地)

逐阶段实施→测试→改 bug→下一阶段。每阶段编译+全量单测绿。

- **阶段0 骨架+纯测试 ✅**:新建 ui_state.zig/event.zig/ui.zig + main.zig 导出 + tests/component/{ui_state,ui_render}_test.zig(23 内存级测试:dispatch 状态转移 + render 帧内容 + 全链路)。反向破坏验证(禁 `?` 拦截→测试红)证明真锚定。主循环未接线(零风险增量)。
- **阶段1 ? help + Ctrl+O transcript ✅**:RenderRegion 加 `ui:UiState`+`applyEvent`+`renderOverlayInner`(复用 renderFrameInner 的 erase/prev_rows 骨架,中段换 ui.render);readLineRaw 非 vim 路径 key 先经 applyEvent 分流(overlay 消费/pass_to_editor)。Ctrl+O **从退 raw mode 旁路改成视图态**(overlay=.transcript,复用 renderToLinesWithTheme,不进 alt screen)。`?` 空框即时切 help。5 个 pty 测试。**修 1 真 bug**:ui.render 末行带 \r\n 致光标回顶偏移、help 关闭后标题残留——renderOverlayInner 画完先 up(1) 回区最后一行对齐 renderFrameInner 约定。
- **阶段2 footer ✅**:drawFooter 改读 self.ui.footer(app fallback);ui.renderFooterLine 升级完整版(左+右 tokens 两端对齐)pub 复用。诚实范围:输入期 footer 单线程裸读本安全,未强行接 usage_sink(无净收益);多线程 usage 事件归后续。
- **阶段3 spinner+phase ✅**:enterGenerating/tickSpinner/leaveGenerating 同步写 self.ui.{spinner,phase}(双写过渡)。渲染零风险(drawGenRegion 暂仍读旧字段)。
- **阶段4 tools ✅**:setCurrentTool/clearCurrentTool/addToolCard/clearToolCard/setToolProgress 同步写 self.ui.tools(双写过渡)。
- **阶段5 文本+收尾**:**诚实范围收缩(L0:不为架构纯粹破坏正常工作的东西)**。文本/scrollback 协议(writeGenText/emitToScroll/半行续接/行缓冲)现工作正常+pty 覆盖(test_shrink_jitter/wrap_resize),改成事件流**无功能收益、高风险**(半行续接快照极易破)→**不做**。"删双写消除技术债"需 drawGenRegion 整体搬进 ui.renderGenFrame(独立大重构)→**登记后续迭代**。当前双写无 bug、UiState 状态已就位(为未来纯 render 铺路)。

**已达成用户三诉求**:① 真 Ctrl+O(视图态,可纯单测,非旁路)② 真测试(23 内存级 dispatch/render,不依赖真模型/key,Ctrl+O/? 现可纯单测)③ 可测+易对齐 CC(UiState/dispatch/render 硬边界不碰 IO;加 CC 功能=加 Event+字段+dispatch+render 四点闭环,闭合 union 漏分支编译报错)。

**遗留(后续迭代)**:drawGenRegion 整体搬进 ui.renderGenFrame + 删 RenderRegion 双写字段(spinner_frame/verb/tool_cards 等)+ 文本事件流。这是把"双写过渡"收敛为"单一真相源"的纯重构,无功能变化,可独立安全推进。
