; Java 符号查询。改写自 tree-sitter-java v0.23.5 tags.scm,去 @reference。

(class_declaration
  name: (identifier) @name) @definition.class

(interface_declaration
  name: (identifier) @name) @definition.interface

(enum_declaration
  name: (identifier) @name) @definition.enum

(method_declaration
  name: (identifier) @name) @definition.method

(constructor_declaration
  name: (identifier) @name) @definition.method

; 字段(类成员)
(field_declaration
  declarator: (variable_declarator name: (identifier) @name)) @definition.field
