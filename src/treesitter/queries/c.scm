; c 符号查询。节点名/字段见 tree-sitter-c v0.24.1。

; 函数定义:function_definition > declarator: function_declarator > identifier
(function_definition
  declarator: (function_declarator
    declarator: (identifier) @name)) @definition.function

; 指针返回类型的函数:declarator 多包一层 pointer_declarator
(function_definition
  declarator: (pointer_declarator
    declarator: (function_declarator
      declarator: (identifier) @name))) @definition.function

; struct/enum/union:**仅定义**(带 body:),排除 typedef/参数里的类型*引用*。
(struct_specifier
  name: (type_identifier) @name
  body: (field_declaration_list)) @definition.struct
(enum_specifier
  name: (type_identifier) @name
  body: (enumerator_list)) @definition.enum
(union_specifier
  name: (type_identifier) @name
  body: (field_declaration_list)) @definition.union

; typedef:取被定义的 type_identifier
(type_definition
  declarator: (type_identifier) @name) @definition.type
