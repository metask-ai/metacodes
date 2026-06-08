"""CodeMap 引导提示词 A/B 实验定义。

验证:# Using your tools 引导行 + describeCodeMap 是否提高模型在自然编程问题下
选对工具(结构题→CodeMap;找定义题→FindSymbol)的比率。

判分按题类别(见 score),不合并——两工具语义正交,合并会掩盖"是否各导向对的工具"。
"""

# ── 当前已落地的引导文本(与 src 里编译进去的逐字对齐,作为 variant "current")──

CURRENT_CODEMAP_DESC = (
    "Produce a structural outline of source code — every function, type, class, "
    "constant, and method with its line number and signature — without reading the "
    "file bodies.\n\nUsage:\n"
    "- ALWAYS prefer CodeMap over reading a whole file when your goal is to LOCATE "
    "definitions (where is function X? what methods does this type have? what's the "
    "shape of this module?). It returns just the skeleton, costing a fraction of the "
    "tokens of a full Read.\n"
    "- Pass a single file path to map one file, or a glob (e.g. `src/**/*.zig`) to map "
    "many files at once — ideal for getting your bearings in an unfamiliar module or "
    "directory.\n"
    "- Typical workflow: CodeMap to find WHERE something is defined → Read with "
    "offset+limit to pull just that range → Edit. Reserve a full-file Read for when you "
    "genuinely need the entire contents.\n"
    "- Use Grep when you need to find all USES/occurrences of a string or regex; use "
    "CodeMap when you need the DEFINITIONS and overall structure.\n"
    "- To jump straight to a single symbol's definition by name across the codebase, the "
    "FindSymbol tool is purpose-built (it may need to be activated via ToolSearch first).\n"
    "- Supported languages: zig, typescript, tsx, python, c, bash. For other languages, "
    "fall back to Grep or Read."
)

# v2:在 current 基础上补"枚举/列举跨文件所有定义"的措辞(治旧实验 Q5 盲区:
# "list every public function" 被模型当成文件遍历走 Glob/Bash)。
V2_CODEMAP_DESC = CURRENT_CODEMAP_DESC.replace(
    "- Use Grep when you need to find all USES/occurrences",
    "- To LIST or ENUMERATE every function/type/definition across one or more files "
    "(e.g. \"list all public functions\", \"what does this directory define\"), CodeMap "
    "with a glob is the right tool — never shell out to grep/ls/find for this.\n"
    "- Use Grep when you need to find all USES/occurrences",
)

# USING_TOOLS 段:current 用编译进去的默认(含 CodeMap 引导行),这里给 v2 一个加强版,
# 但本实验主要调 TOOL_DESC_CODEMAP,USING_TOOLS 在 current/v2 都用 None(走默认编译值)
# 来隔离单一变量。baseline 则两个 slot 都不覆盖。
# 注:baseline 要的是"无引导",但二进制已编译进引导——所以 baseline 必须显式用
# "去掉引导"的文本覆盖,而非空 dict。见下 VARIANTS。

# 去引导版 CodeMap 描述(回到加引导前的静态短描述,模拟 baseline)。
BASELINE_CODEMAP_DESC = (
    "Produce a structural outline of code: functions, types, classes, constants with "
    "line numbers and signatures. Pass a file path for one file, or a glob (e.g. "
    "src/**/*.zig) to map many files. Far cheaper than reading whole files when you only "
    "need to find where things are defined. Supports zig, typescript, tsx, python, c, bash."
)

# 去引导版 # Using your tools(删掉 CodeMap/FindSymbol 那一行,模拟改动前)。
BASELINE_USING_TOOLS = (
    "# Using your tools\n"
    " - Do NOT use the Bash to run commands when a relevant dedicated tool is provided. "
    "Using dedicated tools allows the user to better understand and review your work. "
    "This is CRITICAL to assisting the user:\n"
    "  - To read files use Read instead of cat, head, tail, or sed\n"
    "  - To edit files use Edit instead of sed or awk\n"
    "  - To create files use Write instead of cat with heredoc or echo redirection\n"
    "  - To search for files use Glob instead of find or ls\n"
    "  - To search the content of files, use Grep instead of grep or rg\n"
    "  - Reserve using the Bash exclusively for system commands and terminal operations "
    "that require shell execution. If you are unsure and there is a relevant dedicated "
    "tool, default to using the dedicated tool and only fallback on using the Bash tool "
    "for these if it is absolutely necessary.\n"
    " - You can call multiple tools in a single response. Maximize use of parallel tool "
    "calls where possible to increase efficiency."
)

SLOTS = ["TOOL_DESC_CODEMAP", "USING_TOOLS"]

VARIANTS = {
    # baseline:显式覆盖成"去引导"文本(因二进制已编译进引导,空 dict 反而是 treated)。
    "baseline": {
        "TOOL_DESC_CODEMAP": BASELINE_CODEMAP_DESC,
        "USING_TOOLS": BASELINE_USING_TOOLS,
    },
    # current:空 dict = 不覆盖,用编译进二进制的当前引导(等价"已落地版")。
    "current": {},
    # v2:加强版 CodeMap 描述(补枚举措辞),USING_TOOLS 仍用编译默认。
    "v2_enumerate": {
        "TOOL_DESC_CODEMAP": V2_CODEMAP_DESC,
    },
}

FIXTURE_FILES = {
    "shapes.zig": (
        'const std = @import("std");\n\n'
        "pub const Color = enum { red, green, blue };\n\n"
        "pub const Rect = struct {\n"
        "    w: i32,\n    h: i32,\n"
        "    pub fn area(self: Rect) i32 { return self.w * self.h; }\n"
        "    pub fn perimeter(self: Rect) i32 { return 2 * (self.w + self.h); }\n"
        "};\n\n"
        "pub const Circle = struct {\n"
        "    r: i32,\n"
        "    pub fn area(self: Circle) i32 { return 3 * self.r * self.r; }\n"
        "};\n\n"
        "pub fn maxArea(a: i32, b: i32) i32 { return if (a > b) a else b; }\n"
    ),
    "util.zig": (
        'const std = @import("std");\n\n'
        "pub fn clamp(v: i32, lo: i32, hi: i32) i32 {\n"
        "    if (v < lo) return lo;\n    if (v > hi) return hi;\n    return v;\n}\n\n"
        "pub fn sum(items: []const i32) i32 {\n"
        "    var t: i32 = 0;\n    for (items) |x| t += x;\n    return t;\n}\n\n"
        'pub const VERSION = "1.2.3";\n'
    ),
}

# 题库:每题带 category + split(train 调参用 / holdout 防过拟合验证用)。
QUESTIONS = [
    # ── structure: "我有这文件/目录,里面定义了啥" → CodeMap ──
    {"split": "train", "category": "structure",
     "prompt": "I just opened this project. Without dumping whole files, show me what "
               "types and functions are defined in shapes.zig and where each one is."},
    {"split": "train", "category": "structure",
     "prompt": "Give me a high-level structural overview of util.zig — just the function "
               "and constant definitions with their line numbers, not the full bodies."},
    {"split": "train", "category": "structure",
     "prompt": "List every public function and type across these two files with "
               "signatures, as compactly as possible."},
    {"split": "holdout", "category": "structure",
     "prompt": "I'm unfamiliar with shapes.zig and util.zig. Map out their structure so "
               "I know what's defined where, without reading the entire files."},
    {"split": "holdout", "category": "structure",
     "prompt": "What's the shape of util.zig? Just the outline of what it defines."},

    # ── locate_symbol: "X 定义在哪(不知在哪个文件)" → FindSymbol(CodeMap 次优) ──
    {"split": "train", "category": "locate_symbol",
     "prompt": "Where is the `clamp` function defined in this codebase? I only want its "
               "definition location, not every place it's mentioned."},
    {"split": "train", "category": "locate_symbol",
     "prompt": "Find the definition of the `area` method by name across the project."},
    {"split": "holdout", "category": "locate_symbol",
     "prompt": "Which file and line defines `maxArea`? Just point me to the definition."},
]


def score(first_tool, q):
    """按题类别分别判分,返回 0.0~1.0。"""
    cat = q["category"]
    if cat == "structure":
        return 1.0 if first_tool == "CodeMap" else 0.0
    if cat == "locate_symbol":
        if first_tool == "FindSymbol":
            return 1.0
        if first_tool == "CodeMap":
            return 0.5  # 次优:能定位但绕(map 整文件再找)
        return 0.0
    return 0.0


# 主指标二值化(供 z 检验,避免 0.5 破坏比例检验):
# structure → 命中 == (first_tool == CodeMap);locate_symbol → 命中 == (first_tool == FindSymbol)。
def primary_hit(first_tool, q):
    if q["category"] == "structure":
        return first_tool == "CodeMap"
    if q["category"] == "locate_symbol":
        return first_tool == "FindSymbol"
    return False
