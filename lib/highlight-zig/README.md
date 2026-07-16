# highlight-zig

轻量语法高亮引擎，纯 Zig，零 C 依赖。为 [metacodes](https://github.com/shuzuan-org/cc-t2z) 的 diff / 源码高亮而生，也可独立使用。

- **纯 Zig**：规则表以 zlib 压缩 blob 嵌入二进制（`src/rules_blob.zlib`），200+ 语言，demand-paging 零常驻内存代价。
- **无 tree-sitter**：取代早期 tree-sitter 集成做 diff 高亮，无 grammar 编译、无 scanner。
- **两种消费方式**：
  - **Zig 模块**（主）：`b.dependency("highlight_zig", .{}).module("hl")`，`@import("hl")`。
  - **静态库**：`zig build` 产出 `zig-out/lib/libhighlight.a`。

## API

```zig
const hl = @import("hl");

// 按扩展名 / 语言名查规则
const rule = hl.lookupByExtension("zig") orelse return;
const rule2 = hl.lookupByName("python") orelse return;

// tokenize → 着色 span
const spans = try hl.tokenize(allocator, source, rule);
// ANSI 着色
const colored = try hl.colorizeSource(allocator, source, rule, palette);
```

主要导出：`tokenize` / `colorize` / `colorizeSource` / `lookupByExtension` / `lookupByName` / `ruleCount` / `ruleAt`，类型 `ColoredSpan` / `TokenType` / `LangRule` / `Palette`。

## 构建

```sh
zig build           # 产出 libhighlight.a
zig build test      # 跑引擎 / ansi / rules 测试
```

规则表由 `scripts/gen_rules.py` 生成（重新生成 `src/rules_blob.zlib`）。

## License

见 [LICENSE](LICENSE)。
