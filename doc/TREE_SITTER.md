# Tree-sitter 支持 (metacodes)

> 实现于 2026-06-07。三层全交付。Zig 0.16 + 静态链入 C runtime/grammar。

## 概览

metacodes 静态编译 tree-sitter C runtime + 6 语言 grammar(**zig / typescript / tsx / python / c / bash**),
零运行时依赖、无外部进程。提供三层能力:

1. **层一(优化现有工具)**:Read `outline` 模式 + 大文件出大纲;Edit 改后语法检查告警。
2. **层二(新工具)**:`CodeMap`(代码大纲,常驻)、`FindSymbol`(找定义,deferred)。
3. **层三(机制)**:`export-symbols` CLI 产出 `symbols.jsonl`,供外围 metaknow skill 灌知识图谱。
4. **diff 语法高亮**:Edit/Write 工具卡的 diff 用 tree-sitter token 级着色(替代旧关键字表)。

二进制体积:546K → **7.1M**(6 grammar 的 parser 表是数据,DCE 删不掉;用户已确认接受换取全语言能力)。

## diff 语法高亮(旁路缓存架构)

Edit/Write 工具卡的 diff 升级成 tree-sitter token 级高亮(`@import` builtin、类型名、关键字都准,
关键字表认不出)。**核心难点**:diff 逐行渲染单行片段,tree-sitter 要整文件上下文。

**数据流(关键设计:不读盘、不进对话历史)**:
- Edit/Write `finalizeWrite` 执行时手里现成的新旧全文 → `ctx.edit_hl_cache.put(tool_id, old, new)`
  存进**旁路进程内缓存**(`core/edit_hl_cache.zig`,App 拥有,mutex+FIFO 驱逐,CAP 1MB/16 条)。
- 渲染时(`tool_card.renderEditDiffImpl`)按 `tool_id`(== tool_use id,`progress_tool_id`==`.tool_result.id`)
  取新文件全文 → `highlight.highlightFile` 整文件解析 → 按行 span 索引 → `appendDiffLine` 按 `new_ln` 查。
- **为什么不读盘**:渲染层碰 IO + 隐式时序假设 + del 行拿不到。**为什么不塞 tool_result**:Edit/Write
  结果原样进对话历史 → 全文翻几倍 token。旁路缓存两者都避开。

**高亮器** `treesitter/highlight.zig`:paint-buffer 算法(每字节涂 group,后写覆盖="last wins",
按行合并连续同 group 成 span)规避 capture 嵌套/重叠。`highlights.scm` 各 grammar 官方查询
(ts/tsx = JS base + TS delta 拼接),`@embedFile` 进 `treesitter/queries/highlights/`。

**退回**:缓存未命中/不支持语言/行文本字节不匹配/del 行 → 退回旧关键字表 `render.highlightCodeLine`(零回归)。
颜色复刻 `ansi.sgr`:keyword=magenta / string=green / number=yellow / comment=dim / function=cyan / type=blue。

**覆盖工具**:Edit(diff +/-)、Write(plain 纯新建)、**NotebookEdit**(cell diff,lang 从结果 `lang` 字段取——.ipynb 推不出,默认 python;markdown cell 不高亮)。三者都 put `edit_hl_cache`,都走 `renderEditDiffImpl`。NotebookEdit 无 gitDiff(纯结构改/patch 失败)时退回 JSON 摘要。

**语义色 theme(随终端能力+背景自适应)**:见下节。


## 目录结构

```
vendor/tree-sitter/           # committed 进 git(生成稳定、MIT、CI 无网可编)
  runtime/{include,src}/       # tree-sitter core,只编 src/lib.c(摊销头)
  grammars/<lang>/src/         # 各语言生成的 parser.c (+scanner.c for ts/tsx/python/bash)
  grammars/typescript/common/scanner.h   # ts/tsx 共享 scanner 头
  VERSIONS.txt                 # 锁定 tag
src/treesitter/
  ts.zig                       # C API 的 Zig FFI 封装(Parser/Tree/Node/Query/Cursor + Lang)
  symbols.zig                  # extractSymbols:Query 抽符号 → Symbol{name,kind,line,sig,parent,lang}
  export.zig                   # export-symbols CLI 核心(walk dir → JSONL)
  queries/<lang>.scm           # @embedFile 的符号查询(每语言)
  test_root.zig                # test:ts 隔离测试入口
src/tools/code_map.zig         # CodeMap 工具 + renderOutlineForSource(Read 复用)
src/tools/find_symbol.zig      # FindSymbol 工具(deferred)
scripts/download-tree-sitter.sh # 拉取/升级 vendor 源(非构建前置)
```

## 构建

`build.zig` 的 `addTreeSitter(b, mod)` 把 C 源挂到每个 root=src/main.zig 的 module
(release/debug exe + test_module + integ/new 循环的 cc_mod)。flags:`-std=c11 -fno-sanitize=undefined`
(生成 parser 触发 UBSan)。scanner 全是纯 C,无需 link_libcpp。

升级 grammar:改 `scripts/download-tree-sitter.sh` 的 `*_TAG` → 重跑 → 跑测试 → commit。

## 工具

### CodeMap(常驻)
`{path(必填,文件或glob), lang?}` → 缩进文本树(kind name (start-end) signature)。glob 走 rg --files。

### FindSymbol(deferred,藏 ToolSearch 后)
`{name(必填), kind?, path?}` → 定义的 JSON 数组。先 `rg -l -w` 缩候选,再 tree-sitter 确认是定义。

### Read outline 模式
`{file_path, outline:true}` → 符号大纲而非内容;不支持的语言回退正常读。>256KB 文件自动出大纲(替代旧的死胡同报错)。

### Edit 语法检查
改后若新内容 parse 出错且旧内容本干净 → 结果加 `syntaxWarning`(非致命,不回滚)。

## 层三:symbols.jsonl 契约(KG 边界)

```
metacodes export-symbols <dir> [-o <file>]
```
walk `<dir>`(rg --files,遵守 .gitignore),对支持的语言抽符号,每符号一行 JSON:

```json
{"name":"extractSymbols","kind":"function","file":"src/treesitter/symbols.zig",
 "line_start":109,"line_end":199,
 "signature":"pub fn extractSymbols(gpa, file, source, lang) !Symbols",
 "parent":null,"doc":null,"lang":"zig"}
```

字段:`name`(str)/`kind`(str enum:function/method/struct/enum/union/type/constant/variable/class/interface/field/import/test/other)/
`file`(repo 相对)/`line_start`,`line_end`(int,1-based)/`signature`(str)/`parent`(str|null,外层定义名)/`doc`(str|null,v1 暂为 null)/`lang`(str)。

### 外围 metaknow skill 的职责(cc-zig 范围外)

cc-zig **只**产出忠实稳定的 `symbols.jsonl`,**永不**调 KG HTTP API。外围 skill:
1. 读 `symbols.jsonl` + repo checkout;
2. 逐行 upsert 一个 KG"代码符号"节点(键 `file:name:line_start`,带 kind/signature/doc);
3. 推导关系:`parent` → contains/member-of 边;`file`/`lang` → 分组边;后续 pass 可加 calls/references;
4. 负责幂等 upsert + 关系推断(scope `metask_business`)。

这样代码符号与设计文档(已在 KG)通过同名/同文件锚点建立连接,形成"文档↔代码地图"。

## 测试

- **L1**(`zig build test:ts`,隔离绕开主套件 integration 挂起):ts.zig FFI/ABI 守卫 + symbols.zig 6 语言抽取断言。
- **L2**(`zig build test:new`):code_map / find_symbol / read_outline / edit_syntaxcheck / export_symbols 端到端走 dispatch。
- fixtures:`tests/fixtures/treesitter/sample.{zig,ts,py,c,sh,md}`。

## 已知限制 / 后续

- `doc` 字段 v1 恒为 null(doc-comment 抽取留后续)。
- CodeMap 渲染只两级(顶层 + 直接 child),深嵌套不展开。
- grammar 节点名随版本变:`Query.init` 失败 → `error.QueryCompileFailed` 优雅降级(返回空符号,不崩)。
- tree-sitter-zig 社区维护,可能滞后 Zig 语法 → `zig.scm` 最可能需对锁定 tag 迭代。
