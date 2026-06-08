; C++ 符号查询。改写自 tree-sitter-cpp v0.23.4 tags.scm。

(struct_specifier
  name: (type_identifier) @name
  body: (_)) @definition.struct

(class_specifier
  name: (type_identifier) @name) @definition.class

(enum_specifier
  name: (type_identifier) @name) @definition.enum

(union_specifier
  name: (type_identifier) @name) @definition.union

; 函数(自由函数 / 成员函数定义)
(function_declarator
  declarator: (identifier) @name) @definition.function

(function_declarator
  declarator: (field_identifier) @name) @definition.method

; 命名空间限定的函数定义 → 方法
(function_declarator
  declarator: (qualified_identifier
    name: (identifier) @name)) @definition.method

; typedef / using 别名
(type_definition
  declarator: (type_identifier) @name) @definition.type
