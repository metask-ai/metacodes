; typescript / tsx 符号查询。节点名/字段见 tree-sitter-typescript v0.23.2。
; export_statement 包裹的声明:查询直接匹配内层声明节点(export 透明)。
; 用 name: 字段锚定,避免参数/类型的 identifier 误匹配。

(function_declaration
  name: (identifier) @name) @definition.function

(class_declaration
  name: (type_identifier) @name) @definition.class

(method_definition
  name: (property_identifier) @name) @definition.method

(interface_declaration
  name: (type_identifier) @name) @definition.interface

(type_alias_declaration
  name: (type_identifier) @name) @definition.type

(enum_declaration
  name: (identifier) @name) @definition.enum

; 顶层 const/let/var
(lexical_declaration
  (variable_declarator name: (identifier) @name)) @definition.constant
(variable_declaration
  (variable_declarator name: (identifier) @name)) @definition.variable
