; Rust 符号查询。改写自 tree-sitter-rust v0.24.2 tags.scm,kind 用精确类型(tags.scm 粗略地把 struct/enum/union 都标 class)。

(struct_item
  name: (type_identifier) @name) @definition.struct

(enum_item
  name: (type_identifier) @name) @definition.enum

(union_item
  name: (type_identifier) @name) @definition.union

(type_item
  name: (type_identifier) @name) @definition.type

(trait_item
  name: (type_identifier) @name) @definition.interface

; 方法(impl/trait 体内的 function_item)
(declaration_list
  (function_item
    name: (identifier) @name) @definition.method)

; 自由函数
(function_item
  name: (identifier) @name) @definition.function

; 常量 / 静态
(const_item
  name: (identifier) @name) @definition.constant

(static_item
  name: (identifier) @name) @definition.variable
