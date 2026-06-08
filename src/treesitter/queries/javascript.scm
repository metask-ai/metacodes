; JavaScript 符号查询。改写自 tree-sitter-javascript v0.25.0 tags.scm,去 @doc/@reference,kind 对齐 cc-zig。

(function_declaration
  name: (identifier) @name) @definition.function

(generator_function_declaration
  name: (identifier) @name) @definition.function

[
  (class_declaration name: (_) @name)
  (class name: (_) @name)
] @definition.class

(method_definition
  name: (property_identifier) @name) @definition.method

; const/let/var 顶层声明(函数体内的由 symbols.zig 后置过滤)
(variable_declarator
  name: (identifier) @name) @definition.variable
