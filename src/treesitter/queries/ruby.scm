; Ruby 符号查询。改写自 tree-sitter-ruby v0.23.1 tags.scm,去 @doc/@reference。

(method
  name: (_) @name) @definition.method

(singleton_method
  name: (_) @name) @definition.method

; class —— name 可能是 constant 或 scope_resolution
(class
  name: [
    (constant) @name
    (scope_resolution name: (_) @name)
  ]) @definition.class

(module
  name: [
    (constant) @name
    (scope_resolution name: (_) @name)
  ]) @definition.class

(alias
  name: (_) @name) @definition.method
