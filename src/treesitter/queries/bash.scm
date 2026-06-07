; bash 符号查询。节点名见 tree-sitter-bash v0.23.3。

(function_definition (word) @name) @definition.function

; 顶层变量赋值
(variable_assignment (variable_name) @name) @definition.variable
