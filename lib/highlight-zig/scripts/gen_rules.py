#!/usr/bin/env python3
"""
从 Prism grammar JS 文件文本提取关键字/字符串/注释规则，生成 hl-zig rules.zig。
纯文本解析，不执行 JS。
"""
from __future__ import annotations
import re
import sys
from pathlib import Path
from collections import OrderedDict

PRISM_SRC = Path("/tmp/prism-src/src/languages")

# ── JS 文件 → grammar 文本字段 ──────────────────────────────

def extract_field_text(source: str, field_name: str) -> list[str]:
    """从 JS 源码提取 'field': 后面的正则 pattern 源码字符串。"""
    results = []
    # 匹配 'field': /regex/flags  或  'field': { pattern: /regex/flags ... } 或 'field': [ ... ]
    # 先找 'field':
    for m in re.finditer(rf"'{field_name}'\s*:", source):
        rest = source[m.end():]
        patterns = parse_value_patterns(rest)
        results.extend(patterns)
    return results


def parse_value_patterns(rest: str) -> list[str]:
    """解析一个值（可能是 /regex/、{pattern:/regex/}、[...]）并提取所有 regex source。"""
    results = []
    rest = rest.lstrip()
    if not rest:
        return results

    if rest[0] == '/':
        # 直接正则 /.../flags
        regex_src = read_regex(rest)
        if regex_src:
            results.append(regex_src)
    elif rest[0] == '{':
        # 对象 { pattern: /regex/ ... }
        obj_text = read_balanced(rest, '{', '}')
        # 找 pattern: /regex/
        for pm in re.finditer(r'pattern\s*:\s*', obj_text):
            after = obj_text[pm.end():]
            regex_src = read_regex(after)
            if regex_src:
                results.append(regex_src)
    elif rest[0] == '[':
        # 数组 [...]
        arr_text = read_balanced(rest, '[', ']')
        # 先去 JS 注释 //... 和 /*...*/
        arr_text = re.sub(r'//[^\n]*', '', arr_text)
        arr_text = re.sub(r'/\*.*?\*/', '', arr_text, flags=re.DOTALL)
        # 递归找所有 /regex/（不跨行）
        for rm in re.finditer(r'/(?:[^/\\\n]|\\.)+/', arr_text):
            results.append(rm.group(0))
        for pm in re.finditer(r'pattern\s*:\s*', arr_text):
            after = arr_text[pm.end():]
            regex_src = read_regex(after)
            if regex_src:
                results.append(regex_src)

    return results


def read_regex(s: str) -> str | None:
    """读取 /regex/flags，返回 regex source（不含定界符）。"""
    if not s or s[0] != '/':
        return None
    i = 1
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s):
            i += 2
            continue
        if s[i] == '/':
            return s[1:i]  # 不含 flags
        if s[i] == '\n':
            return None
        i += 1
    return None


def read_balanced(s: str, open_ch: str, close_ch: str) -> str:
    """读取平衡的 {...} 或 [...]。"""
    if not s or s[0] != open_ch:
        return ""
    depth = 0
    i = 0
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s):
            i += 2
            continue
        if s[i] == open_ch:
            depth += 1
        elif s[i] == close_ch:
            depth -= 1
            if depth == 0:
                return s[:i + 1]
        i += 1
    return s


# ── 从正则 source 提取关键字 ────────────────────────────────

def extract_keywords(regex_source: str) -> list[str]:
    """从 \b(?:kw1|kw2|...)\b 提取关键字。"""
    s = regex_source
    # 去 \b
    s = s.replace(r'\b', '')
    # 去 ^ 和 lookahead/lookbehind: (^|[^.]) (\(?=...) (\?<=...) 等
    s = re.sub(r'\(\^[^)]*\)', '', s)
    s = re.sub(r'\(\?[<!=][^)]*\)', '', s)
    s = s.lstrip('^')

    # 找 (?:...) 里纯标识符 alternation
    # 直接在整个字符串里找 (?:ident|ident|...)
    keywords = []
    for m in re.finditer(r'\(\?:((?:[A-Za-z_][A-Za-z0-9_]*(?:\|))+(?:[A-Za-z_][A-Za-z0-9_]*))\)', s):
        for kw in m.group(1).split('|'):
            kw = kw.strip()
            if re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', kw):
                keywords.append(kw)

    # 如果没找到，尝试直接 split
    if not keywords:
        s2 = s.strip()
        # 去 (?:...) 包裹
        while s2.startswith('(?:') and s2.endswith(')') and balanced(s2[3:-1]):
            s2 = s2[3:-1]
        parts = split_alternation(s2)
        for p in parts:
            p = p.strip()
            if p and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', p):
                keywords.append(p)

    return keywords


def balanced(s: str) -> bool:
    depth = 0
    for i, c in enumerate(s):
        if c == '\\' and i + 1 < len(s):
            continue
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth < 0:
                return False
    return depth == 0


def split_alternation(s: str) -> list[str]:
    parts = []
    depth = 0
    current = ""
    i = 0
    while i < len(s):
        c = s[i]
        if c == '\\' and i + 1 < len(s):
            current += c + s[i + 1]
            i += 2
            continue
        if c == '[':
            # 字符类，整个跳过
            j = i + 1
            while j < len(s) and s[j] != ']':
                if s[j] == '\\' and j + 1 < len(s):
                    j += 2
                else:
                    j += 1
            current += s[i:j + 1]
            i = j + 1
            continue
        if c == '(':
            depth += 1
            current += c
        elif c == ')':
            depth -= 1
            current += c
        elif c == '|' and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += c
        i += 1
    if current:
        parts.append(current)
    return parts


# ── 提取注释/字符串 ─────────────────────────────────────────

def extract_comment_markers(source: str) -> tuple[list[str], list[tuple[str,str]]]:
    line_cmts = []
    block_cmts = []

    for field in ('comment', 'eol-comment'):
        patterns = extract_field_text(source, field)
        for p in patterns:
            # 还原转义： \/ → /
            p_unesc = p.replace('\\/', '/')
            # block comment /* */
            if r'\*' in p or '/*' in p_unesc:
                if ('/*', '*/') not in block_cmts:
                    # 检查是否有 */ 闭合
                    if r'\*/' in p or '*/' in p_unesc:
                        block_cmts.append(("/*", "*/"))
                continue
            # 行注释: 提取开头字面符号
            # /\/\/.*/ → //  (pattern source: \/\/.*)
            # /#.*/  → #
            # /;.*/  → ;
            # /--.*/ → --
            # /^\*.*/m → *
            # /(^|\s)".*/  → "
            # /\/{2}.*/ → //  (\/{2} → //)
            # 先还原 \/ → /, \{2\} → 去掉
            p2 = p_unesc.replace('{2}', '').replace('{1}', '')
            m = re.match(r'^\^?(?:\([^)]*\))?(\\{0,2})([/#;\-!*>]+)', p2)
            if m:
                sym = m.group(1).replace('\\', '') + m.group(2)
                sym = sym.replace('\\', '')
                if sym and sym not in line_cmts and len(sym) <= 3:
                    # 过滤误提取：只接受已知注释标记
                    if sym in ("//", "#", ";", "--", "/*", "*", "!", ">", "%"):
                        if sym == "*" or sym == ">" or sym == "%":
                            continue  # 这些太容易误匹配，跳过
                        line_cmts.append(sym)

    return line_cmts, block_cmts


def extract_string_delims(source: str) -> list[dict]:
    delims = []
    seen = set()

    # 去注释
    src = re.sub(r'//[^\n]*', '', source)
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.DOTALL)

    for field in ('string', 'triple-quoted-string', 'template-string', 'here-string', 'string-interpolation', 'char'):
        # 找 'field': 后面的内容
        for m in re.finditer(rf"'{field}'\s*:", src):
            rest = src[m.end():].lstrip()
            if not rest:
                continue
            # 收集这个值里的所有正则
            if rest[0] == '[':
                arr_text = read_balanced(rest, '[', ']')
            elif rest[0] == '{':
                arr_text = read_balanced(rest, '{', '}')
            elif rest[0] == '/':
                arr_text = rest[:100]
            else:
                continue

            # 找所有正则
            for rm in re.finditer(r'/(?:[^/\\\n]|\\.)+/', arr_text):
                p = rm.group(0)[1:rm.group(0).rfind('/')]

                if '"""' in p:
                    if ('triple', '"""') not in seen:
                        seen.add(('triple', '"""'))
                        delims.append({"open": '"""', "close": '"""', "multiline": True})
                if "'''" in p:
                    if ('triple', "'''") not in seen:
                        seen.add(('triple', "'''"))
                        delims.append({"open": "'''", "close": "'''", "multiline": True})
                if '`' in p:
                    if ('single', '`') not in seen:
                        seen.add(('single', '`'))
                        delims.append({"open": '`', "close": '`', "multiline": True})
                if '"' in p:
                    if ('single', '"') not in seen:
                        seen.add(('single', '"'))
                        delims.append({"open": '"', "close": '"'})
                if "'" in p:
                    if ('single', "'") not in seen:
                        seen.add(('single', "'"))
                        delims.append({"open": "'", "close": "'"})

    return delims


# ── 语言名 → 扩展名映射（手工维护常用，其余用语言名）─────

EXT_MAP = {
    "bash": [".sh", ".bash"],
    "c": [".c", ".h"],
    "cpp": [".cpp", ".cc", ".cxx", ".hpp", ".hxx", ".h"],
    "csharp": [".cs"],
    "css": [".css"],
    "dart": [".dart"],
    "elixir": [".ex", ".exs"],
    "elm": [".elm"],
    "erlang": [".erl", ".hrl"],
    "fsharp": [".fs", ".fsx"],
    "go": [".go"],
    "graphql": [".graphql", ".gql"],
    "groovy": [".groovy", ".gradle"],
    "haskell": [".hs"],
    "java": [".java"],
    "javascript": [".js", ".mjs", ".cjs"],
    "json": [".json"],
    "julia": [".jl"],
    "kotlin": [".kt", ".kts"],
    "latex": [".tex", ".latex"],
    "lua": [".lua"],
    "makefile": ["Makefile", ".mk", ".make"],
    "markdown": [".md", ".markdown"],
    "matlab": [".m"],
    "nim": [".nim"],
    "ocaml": [".ml", ".mli"],
    "pascal": [".pas", ".pp"],
    "perl": [".pl", ".pm"],
    "php": [".php"],
    "powershell": [".ps1", ".psm1"],
    "prolog": [".pl", ".pro"],
    "python": [".py", ".pyw"],
    "r": [".r", ".R"],
    "ruby": [".rb"],
    "rust": [".rs"],
    "scala": [".scala", ".sc"],
    "scheme": [".scm", ".ss"],
    "smalltalk": [".st"],
    "sql": [".sql"],
    "swift": [".swift"],
    "tcl": [".tcl"],
    "toml": [".toml"],
    "typescript": [".ts", ".mts", ".cts"],
    "vala": [".vala"],
    "vbnet": [".vb"],
    "verilog": [".v", ".sv"],
    "vhdl": [".vhd", ".vhdl"],
    "vim": [".vim"],
    "visual-basic": [".bas", ".vb"],
    "yaml": [".yaml", ".yml"],
    "zig": [".zig"],
    "ada": [".adb", ".ads"],
    "arduino": [".ino"],
    "asm6502": [".asm", ".s"],
    "autohotkey": [".ahk"],
    "batch": [".bat", ".cmd"],
    "brainfuck": [".bf"],
    "clojure": [".clj", ".cljs"],
    "cmake": [".cmake"],
    "coffeescript": [".coffee"],
    "crystal": [".cr"],
    "d": [".d"],
    "docker": ["Dockerfile", ".dockerfile"],
    "ejs": [".ejs"],
    "fortran": [".f", ".f90", ".f95", ".f03"],
    "gdscript": [".gd"],
    "glsl": [".glsl", ".vert", ".frag"],
    "haml": [".haml"],
    "handlebars": [".hbs", ".handlebars"],
    "haxe": [".hx"],
    "hcl": [".hcl", ".tf"],
    "hlsl": [".hlsl"],
    "http": [".http"],
    "ini": [".ini", ".cfg", ".conf"],
    "jade": [".jade"],
    "less": [".less"],
    "lisp": [".lisp", ".lsp"],
    "llvm": [".ll"],
    "nginx": [".conf", "nginx.conf"],
    "nix": [".nix"],
    "objective-c": [".m", ".mm"],
    "odin": [".odin"],
    "openqasm": [".qasm"],
    "pug": [".pug"],
    "puppet": [".pp"],
    "purescript": [".purs"],
    "qsharp": [".qs"],
    "racket": [".rkt"],
    "reason": [".re", ".rei"],
    "rescript": [".res", ".resi"],
    "sass": [".sass"],
    "scss": [".scss"],
    "solidity": [".sol"],
    "squirrel": [".nut"],
    "stylus": [".styl"],
    "supercollider": [".sc", ".scd"],
    "systemd": [".service", ".timer"],
    "twig": [".twig"],
    "typst": [".typ"],
    "wasm": [".wat", ".wast"],
    "wgsl": [".wgsl"],
    "wolfram": [".wl", ".wls"],
    "wren": [".wren"],
    "yang": [".yang"],
}

ALIAS_MAP = {
    "bash": ["sh", "shell"],
    "csharp": ["cs", "c#"],
    "cpp": ["c++"],
    "coffeescript": ["coffee"],
    "javascript": ["js"],
    "markdown": ["md"],
    "objective-c": ["objc", "obj-c"],
    "powershell": ["ps1", "pwsh"],
    "python": ["py"],
    "ruby": ["rb"],
    "rust": ["rs"],
    "typescript": ["ts"],
    "visual-basic": ["vb", "vb6"],
    "yaml": ["yml"],
}


def get_extensions(lang_id: str) -> list[str]:
    return EXT_MAP.get(lang_id, [])


def get_aliases(lang_id: str) -> list[str]:
    return ALIAS_MAP.get(lang_id, [])


# ── Zig 代码生成 ────────────────────────────────────────────

def zig_escape(s: str) -> str:
    return s.replace('\\', '\\\\').replace('"', '\\"')


def zig_str_array(items: list[str]) -> str:
    if not items:
        return "&.{}"
    return "&.{ " + ", ".join(f'"{zig_escape(s)}"' for s in items) + " }"


def zig_packed_keywords(keywords: list[str]) -> str:
    """\0 分隔的单字符串，省每关键字 16 字节指针开销。"""
    if not keywords:
        return "\"\""
    # 用 \x00 分隔
    joined = "\\x00".join(keywords)
    return f'"{joined}"'


def zig_delim_array(delims: list[dict]) -> str:
    if not delims:
        return "&.{}"
    parts = []
    for d in delims:
        ml = "true" if d.get("multiline") else "false"
        parts.append(
            f'.{{ .open = "{zig_escape(d["open"])}", .close = "{zig_escape(d["close"])}", .multiline = {ml} }}'
        )
    return "&.{ " + ", ".join(parts) + " }"


def zig_block_array(blocks: list[tuple[str,str]]) -> str:
    if not blocks:
        return "&.{}"
    return "&.{ " + ", ".join(f'.{{ "{zig_escape(o)}", "{zig_escape(c)}" }}' for o, c in blocks) + " }"


# ── 手工 override：clike 继承/复杂 grammar 的语言 ──────────

# string/comment override for clike-derived languages
STRING_COMMENT_OVERRIDE = {
    "javascript": {
        "string_delims": [
            {"open": '"', "close": '"'},
            {"open": "'", "close": "'"},
            {"open": "`", "close": "`", "multiline": True},
        ],
        "comment_line": ["//"],
        "comment_block": [("/*", "*/")],
    },
    "typescript": {
        "string_delims": [
            {"open": '"', "close": '"'},
            {"open": "'", "close": "'"},
            {"open": "`", "close": "`", "multiline": True},
        ],
        "comment_line": ["//"],
        "comment_block": [("/*", "*/")],
    },
    "java": {
        "string_delims": [
            {"open": '"', "close": '"'},
            {"open": "'", "close": "'"},
        ],
        "comment_line": ["//"],
        "comment_block": [("/*", "*/")],
    },
    "csharp": {
        "string_delims": [
            {"open": '"', "close": '"'},
            {"open": "'", "close": "'"},
        ],
        "comment_line": ["//"],
        "comment_block": [("/*", "*/")],
    },
    "kotlin": {
        "string_delims": [
            {"open": '"', "close": '"'},
            {"open": "'", "close": "'"},
            {"open": '"""', "close": '"""', "multiline": True},
        ],
        "comment_line": ["//"],
        "comment_block": [("/*", "*/")],
    },
    "dart": {
        "string_delims": [
            {"open": '"', "close": '"'},
            {"open": "'", "close": "'"},
        ],
        "comment_line": ["//"],
        "comment_block": [("/*", "*/")],
    },
    "swift": {
        "string_delims": [
            {"open": '"', "close": '"'},
        ],
        "comment_line": ["//"],
        "comment_block": [("/*", "*/")],
    },
    "go": {
        "string_delims": [
            {"open": '"', "close": '"'},
            {"open": "'", "close": "'"},
            {"open": "`", "close": "`", "multiline": True},
        ],
        "comment_line": ["//"],
        "comment_block": [("/*", "*/")],
    },
    "rust": {
        "string_delims": [
            {"open": '"', "close": '"'},
        ],
        "comment_line": ["//"],
        "comment_block": [("/*", "*/")],
    },
    "c": {
        "string_delims": [
            {"open": '"', "close": '"'},
            {"open": "'", "close": "'"},
        ],
        "comment_line": ["//"],
        "comment_block": [("/*", "*/")],
    },
    "cpp": {
        "string_delims": [
            {"open": '"', "close": '"'},
            {"open": "'", "close": "'"},
        ],
        "comment_line": ["//"],
        "comment_block": [("/*", "*/")],
    },
    "scala": {
        "string_delims": [
            {"open": '"', "close": '"'},
        ],
        "comment_line": ["//"],
        "comment_block": [("/*", "*/")],
    },
    "php": {
        "string_delims": [
            {"open": '"', "close": '"'},
            {"open": "'", "close": "'"},
        ],
        "comment_line": ["//", "#"],
        "comment_block": [("/*", "*/")],
    },
    "ruby": {
        "string_delims": [
            {"open": '"', "close": '"'},
            {"open": "'", "close": "'"},
        ],
        "comment_line": ["#"],
        "comment_block": [("=begin", "=end")],
    },
    "python": {
        "string_delims": [
            {"open": '"""', "close": '"""', "multiline": True},
            {"open": "'''", "close": "'''", "multiline": True},
            {"open": '"', "close": '"'},
            {"open": "'", "close": "'"},
        ],
        "comment_line": ["#"],
    },
    "zig": {
        "string_delims": [
            {"open": '"', "close": '"'},
            {"open": "'", "close": "'"},
        ],
        "comment_line": ["//"],
    },
    "bash": {
        "string_delims": [
            {"open": '"', "close": '"'},
            {"open": "'", "close": "'"},
        ],
        "comment_line": ["#"],
    },
}

KEYWORD_OVERRIDE = {
    "javascript": [
        "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "export", "extends", "finally",
        "for", "function", "if", "import", "in", "instanceof", "new",
        "return", "super", "switch", "this", "throw", "try", "typeof",
        "var", "void", "while", "with", "yield", "let", "static",
        "async", "await", "of", "get", "set", "using", "as", "from",
        "false", "true", "null", "undefined",
    ],
    "typescript": [
        "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "export", "extends", "finally",
        "for", "function", "if", "import", "in", "instanceof", "new",
        "return", "super", "switch", "this", "throw", "try", "typeof",
        "var", "void", "while", "with", "yield", "let", "static",
        "async", "await", "of", "get", "set", "using", "as", "from",
        "abstract", "declare", "enum", "implements", "interface",
        "namespace", "package", "private", "protected", "public",
        "readonly", "satisfies", "type", "infer", "is", "keyof", "module",
        "asserts", "assert", "false", "true", "null", "undefined",
    ],
    "java": [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch",
        "char", "class", "const", "continue", "default", "do", "double",
        "else", "enum", "extends", "final", "finally", "float", "for",
        "goto", "if", "implements", "import", "instanceof", "int",
        "interface", "long", "native", "new", "package", "private",
        "protected", "public", "return", "short", "static", "strictfp",
        "super", "switch", "synchronized", "this", "throw", "throws",
        "transient", "try", "void", "volatile", "while", "var", "yield",
        "record", "sealed", "permits", "false", "true", "null",
    ],
    "kotlin": [
        "as", "break", "class", "continue", "do", "else", "false", "for",
        "fun", "if", "in", "interface", "is", "null", "object", "package",
        "return", "super", "this", "throw", "true", "try", "typealias",
        "typeof", "val", "var", "when", "while", "by", "catch", "constructor",
        "delegate", "dynamic", "field", "file", "finally", "get", "import",
        "init", "param", "property", "receiver", "set", "setparam",
        "value", "abstract", "actual", "annotation", "companion", "const",
        "crossinline", "data", "enum", "expect", "external", "final",
        "infix", "inline", "inner", "internal", "lateinit", "noinline",
        "open", "operator", "out", "override", "private", "protected",
        "public", "reified", "sealed", "suspend", "tailrec", "vararg",
        "where",
    ],
    "csharp": [
        "abstract", "as", "base", "bool", "break", "byte", "case", "catch",
        "char", "checked", "class", "const", "continue", "decimal", "default",
        "delegate", "do", "double", "else", "enum", "event", "explicit",
        "extern", "false", "finally", "fixed", "float", "for", "foreach",
        "goto", "if", "implicit", "in", "int", "interface", "internal",
        "is", "lock", "long", "namespace", "new", "null", "object",
        "operator", "out", "override", "params", "private", "protected",
        "public", "readonly", "ref", "return", "sbyte", "sealed", "short",
        "sizeof", "stackalloc", "static", "string", "struct", "switch",
        "this", "throw", "true", "try", "typeof", "uint", "ulong",
        "unchecked", "unsafe", "ushort", "using", "virtual", "void",
        "volatile", "while", "async", "await", "yield", "var", "record",
        "init", "global",
    ],
    "bash": [
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "while",
        "do", "done", "function", "in", "return", "break", "continue",
        "export", "local", "readonly", "declare", "unset", "shift",
        "source", "alias", "unalias", "exit", "trap", "set",
    ],
    "dart": [
        "abstract", "assert", "async", "await", "break", "case", "catch",
        "class", "const", "continue", "covariant", "default", "deferred",
        "do", "dynamic", "else", "enum", "export", "extends", "extension",
        "external", "factory", "final", "finally", "for", "get", "hide",
        "if", "implements", "import", "in", "interface", "library", "mixin",
        "new", "null", "on", "operator", "part", "rethrow", "return", "set",
        "show", "static", "super", "switch", "sync", "this", "throw", "try",
        "typedef", "var", "void", "while", "with", "yield", "false", "true",
    ],
    "swift": [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
        "func", "import", "init", "inout", "internal", "let", "open", "operator",
        "private", "protocol", "public", "static", "struct", "subscript",
        "typealias", "var", "break", "case", "continue", "default", "defer",
        "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat",
        "return", "switch", "where", "while", "as", "Any", "catch", "false",
        "is", "nil", "rethrows", "super", "self", "Self", "throw", "throws",
        "true", "try", "async", "await", "actor", "distributed", "some",
        "any", "borrowing", "consuming", "each",
    ],
    "go": [
        "break", "case", "chan", "const", "continue", "default", "defer",
        "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
        "interface", "map", "package", "range", "return", "select",
        "struct", "switch", "type", "var", "true", "false", "nil", "iota",
    ],
    "rust": [
        "as", "async", "await", "break", "const", "continue", "crate",
        "dyn", "else", "enum", "extern", "false", "fn", "for", "if",
        "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub",
        "ref", "return", "self", "Self", "static", "struct", "super",
        "trait", "true", "type", "unsafe", "use", "where", "while",
        "abstract", "become", "box", "do", "final", "macro", "override",
        "priv", "typeof", "unsized", "virtual", "yield", "try",
    ],
    "c": [
        "auto", "break", "case", "char", "const", "continue", "default",
        "do", "double", "else", "enum", "extern", "float", "for", "goto",
        "if", "inline", "int", "long", "register", "restrict", "return",
        "short", "signed", "sizeof", "static", "struct", "switch",
        "typedef", "union", "unsigned", "void", "volatile", "while",
        "_Bool", "_Complex", "_Imaginary",
    ],
    "cpp": [
        "alignas", "alignof", "auto", "bool", "break", "case", "catch",
        "char", "char8_t", "char16_t", "char32_t", "class", "concept",
        "const", "consteval", "constexpr", "constinit", "continue",
        "co_await", "co_return", "co_yield", "decltype", "default",
        "delete", "do", "double", "dynamic_cast", "else", "enum",
        "explicit", "export", "extern", "false", "float", "for", "friend",
        "goto", "if", "inline", "int", "long", "mutable", "namespace",
        "new", "noexcept", "nullptr", "operator", "private", "protected",
        "public", "register", "reinterpret_cast", "requires", "return",
        "short", "signed", "sizeof", "static", "static_assert",
        "static_cast", "struct", "switch", "template", "this",
        "thread_local", "throw", "true", "try", "typedef", "typeid",
        "typename", "union", "unsigned", "using", "virtual", "void",
        "volatile", "while",
    ],
    "python": [
        "False", "None", "True", "and", "as", "assert", "async", "await",
        "break", "class", "continue", "def", "del", "elif", "else",
        "except", "finally", "for", "from", "global", "if", "import",
        "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise",
        "return", "try", "while", "with", "yield", "match", "case",
    ],
    "ruby": [
        "BEGIN", "END", "alias", "and", "begin", "break", "case", "class",
        "def", "defined?", "do", "else", "elsif", "end", "ensure", "false",
        "for", "if", "in", "module", "next", "nil", "not", "or", "redo",
        "rescue", "retry", "return", "self", "super", "then", "true",
        "undef", "unless", "until", "when", "while", "yield",
    ],
    "php": [
        "abstract", "and", "array", "as", "break", "callable", "case",
        "catch", "class", "clone", "const", "continue", "declare", "default",
        "die", "do", "echo", "else", "elseif", "empty", "enddeclare",
        "endfor", "endforeach", "endif", "endswitch", "endwhile", "eval",
        "exit", "extends", "final", "finally", "fn", "for", "foreach",
        "function", "global", "goto", "if", "implements", "include",
        "include_once", "instanceof", "insteadof", "interface", "isset",
        "list", "match", "namespace", "new", "or", "print", "private",
        "protected", "public", "readonly", "require", "require_once",
        "return", "static", "switch", "throw", "trait", "try", "unset",
        "use", "var", "while", "xor", "yield", "true", "false", "null",
    ],
    "scala": [
        "abstract", "case", "catch", "class", "def", "do", "else", "extends",
        "false", "final", "finally", "for", "forSome", "if", "implicit",
        "import", "lazy", "match", "new", "null", "object", "override",
        "package", "private", "protected", "return", "sealed", "super",
        "this", "throw", "trait", "try", "true", "type", "val", "var",
        "while", "with", "yield", "given", "using", "enum", "export",
        "then",
    ],
}


# ── C 系语言 number prefix ──────────────────────────────────

C_FAMILY = {
    "c", "cpp", "java", "javascript", "typescript", "go", "rust", "zig",
    "csharp", "python", "swift", "kotlin", "dart", "scala", "d", "odin",
    "nim", "arduino", "objective-c", "fsharp", "haxe", "vala", "solidity",
    "gdscript", "julia", "pascal", "crystal", "coffeescript", "openqasm",
    "verilog", "vhdl", "glsl", "hlsl", "wgsl", "nand2tetris-hdl",
}

# ── 主流程 ──────────────────────────────────────────────────

def process_lang(filepath: Path) -> dict | None:
    source = filepath.read_text()
    lang_id = filepath.stem

    # 提取关键字：全文搜索所有 \b(?:...)\b 正则
    keywords = []
    seen_kw = set()

    # 策略 0: 解析 const/let/var 变量 → 正则，再追踪 'keyword': varname 引用
    var_regex_map = {}  # var name → regex source
    for m in re.finditer(r'(?:const|let|var)\s+(\w+)\s*=\s*(/((?:[^/\\]|\\.)+)/)', source):
        var_regex_map[m.group(1)] = m.group(3)

    for field in ("keyword", "boolean", "builtin", "builtin-type"):
        # 'field': varname  或 'field': /regex/
        for m in re.finditer(rf"'{field}'\s*:\s*(\w+)\s*[,}}\n]", source):
            varname = m.group(1)
            if varname in var_regex_map:
                for kw in extract_keywords(var_regex_map[varname]):
                    if kw not in seen_kw:
                        seen_kw.add(kw)
                        keywords.append(kw)

    # 策略 1: 找 'keyword'/'boolean'/'builtin' 字段的直接正则
    for field in ("keyword", "boolean", "builtin", "builtin-type"):
        patterns = extract_field_text(source, field)
        for p in patterns:
            for kw in extract_keywords(p):
                if kw not in seen_kw:
                    seen_kw.add(kw)
                    keywords.append(kw)

    # 策略 2: 如果字段提取失败，全文搜 \b(?:word|word|...)\b 正则
    if not keywords:
        # 找所有 /\b(?:[a-z_][a-z0-9_|]*?)\b/i 形式
        for m in re.finditer(r'/\\b\(\?:([A-Za-z_][A-Za-z0-9_|]*?)\)\\b/', source):
            inner = m.group(1)
            for kw in inner.split('|'):
                kw = kw.strip()
                if re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', kw) and kw not in seen_kw:
                    seen_kw.add(kw)
                    keywords.append(kw)

    # 策略 3: const keywords = [ /...(kw1|kw2).../, ... ] 形式
    if not keywords:
        for m in re.finditer(r'(?:const|let|var)\s+keywords\s*=\s*\[(.*?)\]', source, re.DOTALL):
            arr_body = m.group(1)
            for rm in re.finditer(r'/(?:[^/\\]|\\.)+/', arr_body):
                for kw in extract_keywords(rm.group(0)[1:rm.group(0).rfind('/')]):
                    if kw not in seen_kw:
                        seen_kw.add(kw)
                        keywords.append(kw)

    # 提取注释
    line_cmts, block_cmts = extract_comment_markers(source)

    # 提取字符串
    string_delims = extract_string_delims(source)

    # override 关键字
    if lang_id in KEYWORD_OVERRIDE:
        keywords = KEYWORD_OVERRIDE[lang_id]

    # override string/comment
    if lang_id in STRING_COMMENT_OVERRIDE:
        ov = STRING_COMMENT_OVERRIDE[lang_id]
        string_delims = ov["string_delims"]
        line_cmts = ov["comment_line"]
        block_cmts = ov.get("comment_block", [])

    if not keywords and not string_delims and not line_cmts and not block_cmts:
        return None

    exts = get_extensions(lang_id)
    aliases = get_aliases(lang_id)

    return {
        "name": lang_id,
        "extensions": exts,
        "aliases": aliases,
        "keywords": keywords,
        "string_delims": string_delims,
        "line_comments": line_cmts,
        "block_comments": block_cmts,
    }


# 跳过辅助/依赖文件（非独立语言）
SKIP = {
    "clike", "js-templates", "jsdoc", "javadoclike", "phpdoc", "php-extras",
    "markup", "markup-templating", "xml-doc", "css-extras", "css-selector",
    "flow", "jsx", "tsx", "aspnet", "t4-cs", "t4-vb", "t4-templating",
    "javastacktrace", "jsstacktrace", "typescript-extras", "javascript-extras",
    "json", "jsonp", "json5",  # json 算数据格式
    "concurnas", "cilkc", "cilkcpp", "cil", "cfscript",
    "plain", "plaintext", "text",
    "regex", "parser",
    "csv", "tsv",
    "diff",
    "git", "gitignore", "dockerignore",
    "hpkp", "hsts",
    "uri", "url",
    "gettext",
    "gherkin",
    "wiki",
    "treeview",
    "log",
    "ebnf", "bnf", "abnf",
    "solution-file", "pcaxis",
    "gedcom",
    "cooklang",
    "robotframework",
    "tap",
    "mermaid",
    "plant-uml",
    "icebreaker",
    "nand2tetris-hdl",
    "web-idl",
    "pure", "purebasic",
    "q",
}


def main():
    entries = []
    skipped = []

    for lf in sorted(PRISM_SRC.glob("*.js")):
        lang_id = lf.stem
        if lang_id in SKIP:
            continue
        entry = process_lang(lf)
        if entry is None:
            skipped.append(lang_id)
            continue
        entries.append(entry)

    # ── 序列化为二进制 blob ──────────────────────────────────
    import struct, zlib

    # escape 类型映射: 0=无转义, 1=\, 2=''
    ESCAPE_BACKSLASH = 1
    ESCAPE_DOUBLE = 2
    ESCAPE_NONE = 0

    # 某些语言用 '' 转义而非 \
    DOUBLE_ESCAPE_LANGS = {"sql", "pascal", "vbnet", "visual-basic", "delphi", "ada", "eiffel", "fortran"}

    blob = bytearray()
    # header: magic(4) + version(1) + 语言数(u16)
    blob.extend(b'HLZ1')  # magic
    blob.append(1)        # version
    blob.extend(struct.pack('<H', len(entries)))
    for e in entries:
        # name
        name_b = e["name"].encode()
        blob.append(len(name_b))
        blob.extend(name_b)
        # extensions: \0 separated
        ext_str = '\x00'.join(e["extensions"]).encode()
        blob.extend(struct.pack('<H', len(ext_str)))
        blob.extend(ext_str)
        # aliases
        al_str = '\x00'.join(e["aliases"]).encode()
        blob.extend(struct.pack('<H', len(al_str)))
        blob.extend(al_str)
        # keywords (already \0 separated in packed form)
        kw_str = '\x00'.join(e["keywords"]).encode()
        blob.extend(struct.pack('<H', len(kw_str)))
        blob.extend(kw_str)
        # string_delims
        blob.append(len(e["string_delims"]))
        for d in e["string_delims"]:
            o = d["open"].encode()
            c = d["close"].encode()
            blob.append(len(o))
            blob.extend(o)
            blob.append(len(c))
            blob.extend(c)
            blob.append(1 if d.get("multiline") else 0)
            # escape: 0=none, 1=\, 2=''
            esc = ESCAPE_DOUBLE if e["name"] in DOUBLE_ESCAPE_LANGS else ESCAPE_BACKSLASH
            blob.append(esc)
        # comment_line
        blob.append(len(e["line_comments"]))
        for c in e["line_comments"]:
            cb = c.encode()
            blob.append(len(cb))
            blob.extend(cb)
        # comment_block
        blob.append(len(e["block_comments"]))
        for o, c in e["block_comments"]:
            ob = o.encode()
            cb = c.encode()
            blob.append(len(ob))
            blob.extend(ob)
            blob.append(len(cb))
            blob.extend(cb)
        # number_prefix
        np = ["0x", "0b", "0o"] if e["name"] in C_FAMILY else []
        blob.append(len(np))
        for n in np:
            nb = n.encode()
            blob.append(len(nb))
            blob.extend(nb)

    compressed = zlib.compress(bytes(blob), 9)

    # 写压缩 blob
    blob_path = Path("/Users/david/prj/cc-t2z/hl-zig/src/rules_blob.zlib")
    blob_path.write_bytes(compressed)
    print(f"blob: {len(blob)} bytes → zlib {len(compressed)} bytes")

    # ── 生成 Zig 代码（运行时解压+构造）──────────────────────
    zig_code = '''//! 自动生成 — 从 Prism grammar 提取。勿手改。
//! 生成器：hl-zig/scripts/gen_rules.py
//! 数据: rules_blob.zlib（zlib 压缩），运行时解压构造。
//!
//! blob 格式 v1:
//!   magic: "HLZ1" (4 bytes)
//!   version: 1 (1 byte)
//!   count: u16 LE
//!   per-language: name_len(u8) name ext_len(u16) ext_data
//!     al_len(u16) al_data kw_len(u16) kw_data
//!     ndelim(u8) [open_len(u8) open close_len(u8) close multiline(u8) escape(u8)]
//!     ncmt_line(u8) [len(u8) data]
//!     ncmt_block(u8) [open_len(u8) open close_len(u8) close]
//!     nnp(u8) [len(u8) data]

const std = @import("std");
const LangRule = @import("types.zig").LangRule;
const StringDelim = @import("types.zig").StringDelim;

const COMPRESSED = @embedFile("rules_blob.zlib");

const MAGIC = "HLZ1";
const VERSION: u8 = 1;

/// 规则表。用 `init` 构造，`deinit` 释放。所有 slice 指向内部 `data` 缓冲或其子分配。
pub const Rules = struct {
    rules: []LangRule,
    data: []u8, // 解压后的完整 blob（rules 里的 slice 大多指向这里）
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Rules) void {
        // 释放每语言的 toOwnedSlice 子数组
        for (self.rules) |*r| {
            self.allocator.free(r.extensions);
            self.allocator.free(r.aliases);
            self.allocator.free(r.string_delims);
            self.allocator.free(r.comment_line);
            self.allocator.free(r.comment_block);
            self.allocator.free(r.number_prefix);
        }
        self.allocator.free(self.rules);
        self.allocator.free(self.data);
    }
};

// ── blob 读取器（带边界校验）────────────────────────────────

const BlobError = error{
    BadMagic,
    BadVersion,
    Truncated,
    DecompressFailed,
    OutOfMemory,
};

const BlobReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn remaining(self: *const BlobReader) usize {
        return self.data.len - self.pos;
    }

    fn readByte(self: *BlobReader) BlobError!u8 {
        if (self.remaining() < 1) return error.Truncated;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }

    fn readU16(self: *BlobReader) BlobError!u16 {
        if (self.remaining() < 2) return error.Truncated;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }

    fn readSlice(self: *BlobReader, len: usize) BlobError![]const u8 {
        if (self.remaining() < len) return error.Truncated;
        const s = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return s;
    }
};

/// 从压缩 blob 构造规则表。allocator 用于 rules 数组和子 slice 数组。
/// 解压后的 data 缓冲也由 allocator 分配，Rules.deinit 释放。
pub fn init(allocator: std.mem.Allocator) BlobError!Rules {
    // 解压
    var in: std.Io.Reader = .fixed(COMPRESSED);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var dec: std.compress.flate.Decompress = .init(&in, .zlib, &.{});
    const n = dec.reader.streamRemaining(&aw.writer) catch return error.DecompressFailed;
    const data = try allocator.dupe(u8, aw.written()[0..n]);

    var br = BlobReader{ .data = data };

    // 校验 magic + version
    const magic = try br.readSlice(4);
    if (!std.mem.eql(u8, magic, MAGIC)) return error.BadMagic;
    const ver = try br.readByte();
    if (ver != VERSION) return error.BadVersion;

    const count = try br.readU16();
    var rules = try allocator.alloc(LangRule, count);
    errdefer {
        // 回滚已构造的规则
        for (rules[0..0]) |_| {} // nothing allocated yet
        allocator.free(rules);
    }

    // 临时 ArrayList 复用
    var ext_lists = std.ArrayList([]const u8).empty;
    var alias_lists = std.ArrayList([]const u8).empty;
    var cmt_line_lists = std.ArrayList([]const u8).empty;
    var cmt_block_lists = std.ArrayList([2][]const u8).empty;
    var delim_lists = std.ArrayList(StringDelim).empty;
    var np_lists = std.ArrayList([]const u8).empty;
    defer {
        ext_lists.deinit(allocator);
        alias_lists.deinit(allocator);
        cmt_line_lists.deinit(allocator);
        cmt_block_lists.deinit(allocator);
        delim_lists.deinit(allocator);
        np_lists.deinit(allocator);
    }

    var i: usize = 0;
    while (i < count) : (i += 1) {
        // name
        const name_len = try br.readByte();
        const name = try br.readSlice(name_len);

        // extensions (NUL-separated)
        const ext_len = try br.readU16();
        ext_lists.clearRetainingCapacity();
        if (ext_len > 0) {
            const ext_data = try br.readSlice(ext_len);
            try splitZeros(allocator, &ext_lists, ext_data);
        }

        // aliases
        const al_len = try br.readU16();
        alias_lists.clearRetainingCapacity();
        if (al_len > 0) {
            const al_data = try br.readSlice(al_len);
            try splitZeros(allocator, &alias_lists, al_data);
        }

        // keywords (packed, NUL-separated)
        const kw_len = try br.readU16();
        const keywords = try br.readSlice(kw_len);

        // string_delims
        const nd = try br.readByte();
        delim_lists.clearRetainingCapacity();
        for (0..nd) |_| {
            const ol = try br.readByte();
            const o = try br.readSlice(ol);
            const cl = try br.readByte();
            const c = try br.readSlice(cl);
            const ml = (try br.readByte()) == 1;
            const esc = try br.readByte();
            try delim_lists.append(allocator, .{
                .open = o,
                .close = c,
                .multiline = ml,
                .escape = switch (esc) {
                    0 => .none,
                    1 => .backslash,
                    2 => .double,
                    else => .backslash, // 安全默认
                },
            });
        }

        // comment_line
        const ncl = try br.readByte();
        cmt_line_lists.clearRetainingCapacity();
        for (0..ncl) |_| {
            const cl = try br.readByte();
            const s = try br.readSlice(cl);
            try cmt_line_lists.append(allocator, s);
        }

        // comment_block
        const ncb = try br.readByte();
        cmt_block_lists.clearRetainingCapacity();
        for (0..ncb) |_| {
            const ol = try br.readByte();
            const o = try br.readSlice(ol);
            const cl = try br.readByte();
            const c = try br.readSlice(cl);
            try cmt_block_lists.append(allocator, .{ o, c });
        }

        // number_prefix
        const nnp = try br.readByte();
        np_lists.clearRetainingCapacity();
        for (0..nnp) |_| {
            const nl = try br.readByte();
            const s = try br.readSlice(nl);
            try np_lists.append(allocator, s);
        }

        rules[i] = .{
            .name = name,
            .extensions = try ext_lists.toOwnedSlice(allocator),
            .aliases = try alias_lists.toOwnedSlice(allocator),
            .keywords = keywords,
            .string_delims = try delim_lists.toOwnedSlice(allocator),
            .comment_line = try cmt_line_lists.toOwnedSlice(allocator),
            .comment_block = try cmt_block_lists.toOwnedSlice(allocator),
            .number_prefix = try np_lists.toOwnedSlice(allocator),
        };
    }

    return .{ .rules = rules, .data = data, .allocator = allocator };
}

/// 将 NUL 分隔的字符串拆成 slice 列表。slice 指向原数据（零拷贝）。
fn splitZeros(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), data: []const u8) !void {
    var start: usize = 0;
    for (data, 0..) |ch, j| {
        if (ch == 0) {
            if (j > start) try list.append(allocator, data[start..j]);
            start = j + 1;
        }
    }
    if (start < data.len) try list.append(allocator, data[start..]);
}

// ── 全局缓存（线程安全初始化）────────────────────────────────

var cached: ?Rules = null;
var cache_lock: std.atomic.Mutex = .unlocked;

fn getRules() []LangRule {
    if (cached == null) {
        // 自旋等待锁（高亮库无并发初始化 contention，自旋足够）
        while (!cache_lock.tryLock()) std.atomic.spinLoopHint();
        defer cache_lock.unlock();
        if (cached == null) {
            cached = init(std.heap.page_allocator) catch null;
        }
    }
    return if (cached) |*c| c.rules else &.{};
}

// ── 公共 API ────────────────────────────────────────────────

pub fn lookupByExtension(ext: []const u8) ?*const LangRule {
    const rules = getRules();
    for (rules) |*r| {
        for (r.extensions) |e| {
            if (std.mem.eql(u8, e, ext)) return r;
        }
    }
    return null;
}

pub fn lookupByName(name: []const u8) ?*const LangRule {
    const rules = getRules();
    for (rules) |*r| {
        if (std.mem.eql(u8, r.name, name)) return r;
        for (r.aliases) |a| {
            if (std.mem.eql(u8, a, name)) return r;
        }
    }
    return null;
}

pub fn ruleCount() usize {
    return getRules().len;
}

pub fn ruleAt(i: usize) ?*const LangRule {
    const rules = getRules();
    if (i >= rules.len) return null;
    return &rules[i];
}
'''

    out_path = Path("/Users/david/prj/cc-t2z/hl-zig/src/rules.zig")
    out_path.write_text(zig_code)
    print(f"生成 {len(entries)} 语言 → {out_path}")
    print(f"跳过 {len(skipped)}: {', '.join(skipped[:30])}")


if __name__ == "__main__":
    main()