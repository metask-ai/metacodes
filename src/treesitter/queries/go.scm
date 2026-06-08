; Go 符号查询。约定:@name = 标识符,@definition.<kind> = 定义节点;kind 取 capture 名后缀。
; 改写自 tree-sitter-go v0.25.0 queries/tags.scm,去掉 @reference/@doc,kind 对齐 cc-zig Kind。

; 函数
(function_declaration
  name: (identifier) @name) @definition.function

; 方法(带 receiver)
(method_declaration
  name: (field_identifier) @name) @definition.method

; struct / interface —— 更具体的容器类型优先(symbols.zig 去重保留最具体)
(type_declaration
  (type_spec
    name: (type_identifier) @name
    type: (struct_type))) @definition.struct

(type_declaration
  (type_spec
    name: (type_identifier) @name
    type: (interface_type))) @definition.interface

; 其它具名类型(type Foo = Bar / type Foo Bar)→ type
(type_spec
  name: (type_identifier) @name) @definition.type

; 顶层 const / var
(const_declaration
  (const_spec
    name: (identifier) @name)) @definition.constant

(var_declaration
  (var_spec
    name: (identifier) @name)) @definition.variable
