; zig 符号查询。节点名/字段名见 tree-sitter-grammars/tree-sitter-zig v1.1.2。
; 约定:@name = 标识符,@definition.<kind> = 定义节点;kind 取 capture 名后缀。
; 用 name: 字段锚定,避免把参数/返回类型的 identifier 误当函数名。

; 函数:只取 name 字段(非参数/返回类型里的 identifier)
(function_declaration
  name: (identifier) @name) @definition.function

; struct / enum / union —— variable_declaration 右侧的容器声明
(variable_declaration
  (identifier) @name
  (struct_declaration)) @definition.struct

(variable_declaration
  (identifier) @name
  (enum_declaration)) @definition.enum

(variable_declaration
  (identifier) @name
  (union_declaration)) @definition.union

; 普通常量/变量声明(右侧非容器)。更具体的容器模式优先(symbols.zig 去重保留)。
; 函数体内的局部 const 由 symbols.zig 后置过滤(parent 是函数则丢弃)。
(variable_declaration
  (identifier) @name) @definition.constant

; 测试块
(test_declaration (string) @name) @definition.test
