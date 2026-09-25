//! Tool(specifier) 规则字符串解析 + 匹配。
//!
//! 完整对齐 Claude Code 规则语法;规则语义以本模块类型与
//! tests/component 权限测试为准(早期 PERMISSION_DESIGN 设计稿已移出仓库)。
//!
//! 入口 API:
//!   parseRule("Bash(npm run *)") → RuleSpec{ .tool="Bash", .spec=.{ .bash_pattern="npm run *" } }
//!   matches(spec, tool_name, args) → bool
//!
//! 支持的工具 specifier:
//!   - Bash(pattern)         glob 通配 + word boundary;`:*` 末尾等价 ` *`
//!   - PowerShell(pattern)   同 Bash(cc-zig 短期不实现,占位)
//!   - Read(path)            gitignore 风格,4 路径前缀(//, ~/, /, ./)
//!   - Edit(path)            同 Read
//!   - Write(path)           等价 Edit(覆盖共用)
//!   - WebFetch(domain:x)    域名匹配
//!   - Skill(name) / Skill(name *)
//!   - Agent(name)           subagent type 精确名
//!   - mcp__server           MCP 整 server
//!   - mcp__server__*        MCP server wildcard
//!   - mcp__server__tool     MCP 具体工具
//!
//! 不在本模块:compound 命令拆分、process wrapper 剥离、readonly 内置免询问
//! → 在 bash_parser.zig(下一步)

const std = @import("std");
const tt = @import("../tools/test_tmp.zig"); // 测试 fixture 唯一路径(并发隔离)
const pfs = @import("platform").fs;

pub const Spec = union(enum) {
    /// 整工具(无 specifier 或 `*`)
    all,
    /// Bash glob pattern(含 `*` 任意位置 + word boundary 语义)
    bash_pattern: []const u8,
    /// PowerShell 同 Bash(占位)
    powershell_pattern: []const u8,
    /// Read/Edit/Write 路径 gitignore-style + 4 路径前缀
    path_pattern: PathPattern,
    /// WebFetch 域名
    web_domain: []const u8,
    /// Skill 精确名 + 可选 ` *` 表示前缀
    skill_match: SkillMatch,
    /// Agent subagent type 精确名
    agent_name: []const u8,
    /// MCP `mcp__server__tool` 整路径(`*` 通配 server 和 tool 部分)
    mcp_match: []const u8,
};

pub const PathAnchor = enum {
    /// `//path` 文件系统绝对
    absolute,
    /// `~/path` HOME 相对
    home,
    /// `/path` project root 相对
    project,
    /// `path` 或 `./path` cwd 相对
    cwd,
};

pub const PathPattern = struct {
    anchor: PathAnchor,
    /// 锚点之后的 pattern(已去掉前缀字符)
    glob: []const u8,
};

pub const SkillMatch = struct {
    name: []const u8,
    /// true = `Skill(deploy *)` 形式,name 是前缀;false = exact
    prefix: bool,
};

pub const RuleSpec = struct {
    /// 工具名(如 "Bash" / "Read" / "Edit" / "Skill" / "Agent" / "WebFetch")
    /// MCP 用特殊值 "mcp"(spec.mcp_match 含完整匹配串)
    tool: []const u8,
    spec: Spec,
};

pub const ParseError = error{
    EmptyRule,
    UnterminatedParen,
    InvalidWebFetchSpec,
};

/// 解析一条规则字符串。返回值 borrow 输入(slice 都指 raw),caller 保证 raw 寿命。
pub fn parseRule(raw: []const u8) ParseError!RuleSpec {
    const s = std.mem.trim(u8, raw, " \t");
    if (s.len == 0) return error.EmptyRule;

    // MCP 特殊形式:mcp__... 没括号
    if (std.mem.startsWith(u8, s, "mcp__")) {
        return .{ .tool = "mcp", .spec = .{ .mcp_match = s } };
    }

    // 找括号
    const paren_open = std.mem.indexOfScalar(u8, s, '(');
    if (paren_open == null) {
        // 裸工具名 = 整工具
        return .{ .tool = s, .spec = .all };
    }
    const open = paren_open.?;
    if (s[s.len - 1] != ')') return error.UnterminatedParen;
    const tool = std.mem.trim(u8, s[0..open], " \t");
    var inner = std.mem.trim(u8, s[open + 1 .. s.len - 1], " \t");

    // 空 specifier 或 "*" → 整工具
    if (inner.len == 0 or std.mem.eql(u8, inner, "*")) {
        return .{ .tool = tool, .spec = .all };
    }

    // 按工具名走相应解析
    if (std.mem.eql(u8, tool, "Bash")) {
        return .{ .tool = "Bash", .spec = .{ .bash_pattern = normalizeColonStarSuffix(inner) } };
    }
    if (std.mem.eql(u8, tool, "PowerShell")) {
        return .{ .tool = "PowerShell", .spec = .{ .powershell_pattern = normalizeColonStarSuffix(inner) } };
    }
    if (std.mem.eql(u8, tool, "Read") or std.mem.eql(u8, tool, "Edit") or std.mem.eql(u8, tool, "Write")) {
        const pp = parsePathPattern(inner);
        return .{ .tool = tool, .spec = .{ .path_pattern = pp } };
    }
    if (std.mem.eql(u8, tool, "WebFetch")) {
        if (!std.mem.startsWith(u8, inner, "domain:")) return error.InvalidWebFetchSpec;
        return .{ .tool = "WebFetch", .spec = .{ .web_domain = std.mem.trim(u8, inner[7..], " \t") } };
    }
    if (std.mem.eql(u8, tool, "Skill")) {
        const trimmed = std.mem.trim(u8, inner, " \t");
        if (std.mem.endsWith(u8, trimmed, " *")) {
            const name = std.mem.trim(u8, trimmed[0 .. trimmed.len - 2], " \t");
            return .{ .tool = "Skill", .spec = .{ .skill_match = .{ .name = name, .prefix = true } } };
        }
        return .{ .tool = "Skill", .spec = .{ .skill_match = .{ .name = trimmed, .prefix = false } } };
    }
    if (std.mem.eql(u8, tool, "Agent")) {
        return .{ .tool = "Agent", .spec = .{ .agent_name = inner } };
    }
    // 未知工具:不报错,当 bash-style pattern 处理(以后扩展用)
    return .{ .tool = tool, .spec = .{ .bash_pattern = normalizeColonStarSuffix(inner) } };
}

/// `:*` 末尾等价 ` *`(Claude Code 规范)。
fn normalizeColonStarSuffix(s: []const u8) []const u8 {
    if (std.mem.endsWith(u8, s, ":*")) {
        return s; // 保留原样,matchesBashPattern 处理时检测
    }
    return s;
}

/// 解析路径 pattern 的锚点 + glob 体。
fn parsePathPattern(raw: []const u8) PathPattern {
    if (std.mem.startsWith(u8, raw, "//")) {
        // **P1 修复(安全)**:glob 必须剥掉**两个**前导 `/`,与 matchesPathPattern 的
        // rel(base="/" 后 abs 剥前导 `/`,无前导斜杠)对齐。旧版 raw[1..] 留 `/etc/**`,
        // 而 rel 是 `etc/passwd` → matchGitignoreGlob 前导斜杠恒对不上 → 绝对锚规则**永不匹配**
        // = deny 规则静默 fail-open(硬边界失效,无条件,连 payload 都不用)。
        return .{ .anchor = .absolute, .glob = raw[2..] };
    }
    if (std.mem.startsWith(u8, raw, "~/")) {
        return .{ .anchor = .home, .glob = raw[2..] };
    }
    if (std.mem.startsWith(u8, raw, "/")) {
        return .{ .anchor = .project, .glob = raw[1..] };
    }
    if (std.mem.startsWith(u8, raw, "./")) {
        return .{ .anchor = .cwd, .glob = raw[2..] };
    }
    return .{ .anchor = .cwd, .glob = raw };
}

// ============================================================================
// 匹配:RuleSpec.matches(tool_name, args)
// ============================================================================

pub const MatchContext = struct {
    /// 当前 cwd 绝对路径
    cwd: []const u8 = "",
    /// project root 绝对路径(可同 cwd)
    project_root: []const u8 = "",
    /// HOME 目录
    home: []const u8 = "",
    /// 额外工作目录(--add-dir / settings additionalDirectories,已解析为绝对路径)。
    /// 与 cwd 共同构成"工作目录集":accept_edits 自动放行 scope + sandbox 可写白名单。
    additional_dirs: []const []const u8 = &.{},
    /// **安全关键(B1)**:路径规则匹配(allow/ask/deny 的 path_pattern)前把待匹配路径
    /// canonicalize——**unescape**(与工具层 write.zig 落盘等价)+ **词法折叠 `..`**——
    /// 否则 `allow: Write(/**)` 圈定 /proj 却自动放行 `/proj/../../etc/passwd`(明文 `..`
    /// 不折叠即绕过,转义 `..` a fortiori)。null → 降级为原始字节(仅单测/无 alloc:那里
    /// 路径是干净字面量,无绕过面)。shim/App 填 ctx.allocator。
    alloc: ?std.mem.Allocator = null,
};

pub fn matches(spec: *const RuleSpec, mctx: *const MatchContext, tool_name: []const u8, args: []const u8) bool {
    return matchesMode(spec, mctx, tool_name, args, .deny);
}

/// 规则种类决定"一次调用有多个候选时,几个匹中才算命中"——allow 要**全部**(放行须每个都被
/// 允许),deny/ask **任一**即触发(无害的那个稀释不了限制):
///   路径规则:候选 = [原路径] 与 [realpath 解析后](指向区外的链接也 prompt,指向 denied
///             文件的链接也 deny);
///   Bash 规则:候选 = 复合命令的每一段(`ls && rm x` 的 rm 段触发 deny `Bash(rm *)`)。
/// 其它规则只有一个候选,不受影响。
pub const RuleMode = enum { allow, deny, ask };

pub fn matchesMode(spec: *const RuleSpec, mctx: *const MatchContext, tool_name: []const u8, args: []const u8, mode: RuleMode) bool {
    // 工具名匹配(MCP 特例)
    if (std.mem.eql(u8, spec.tool, "mcp")) {
        return matchesMcp(spec.spec.mcp_match, tool_name);
    }
    // Agent 规则对 Task 工具和(历史)Agent 工具生效(两者都 spawn subagent)
    if (std.mem.eql(u8, spec.tool, "Agent")) {
        if (!std.mem.eql(u8, tool_name, "Task") and !std.mem.eql(u8, tool_name, "Agent")) return false;
    } else if (!std.mem.eql(u8, spec.tool, tool_name)) {
        return false;
    }

    return switch (spec.spec) {
        .all => true,
        .bash_pattern => |pat| matchesBashCompound(pat, mctx, args, mode),
        .powershell_pattern => |pat| matchesBashPattern(pat, extractCommand(args)),
        .path_pattern => |pp| matchesPathDual(pp, mctx, extractPath(args), mode),
        .web_domain => |dom| matchesWebDomain(dom, args),
        .skill_match => |sm| matchesSkill(sm, args),
        .agent_name => |an| matchesAgent(an, args),
        .mcp_match => |m| matchesMcp(m, tool_name),
    };
}

/// symlink 双路径匹配。原路径 + realpath 解析后的路径。
/// allow:两者都匹配才命中(更严);deny/ask:任一匹配即命中(更宽)。
/// realpath 失败(文件不存在 / 非链接)→ 只用原路径单匹配。
fn matchesPathDual(pp: PathPattern, mctx: *const MatchContext, file_path_raw: []const u8, mode: RuleMode) bool {
    // **B1 修复**:先 canonicalize(unescape + 词法折叠 `..`)再匹配。realpath 分支只在
    // 路径**物理存在**时兜住 `..`;新建文件 / 不存在的父目录 realpath 失败 → 退回纯词法
    // orig_match,若不折叠 `..` 则 allow 规则被绕过、deny 规则被降级。故词法折叠是主防线,
    // realpath 是 symlink 的额外一层。unescape 用 util_json.unescapeString(与工具层同函数)。
    var canon_buf: [std.fs.max_path_bytes]u8 = undefined;
    var unesc_owned: ?[]u8 = null;
    defer if (unesc_owned) |u| (mctx.alloc.?).free(u);
    const file_path: []const u8 = blk: {
        const a = mctx.alloc orelse break :blk file_path_raw; // 降级:无 alloc(单测干净字面量)
        const unesc = util_json_mod.unescapeString(file_path_raw, a) catch break :blk file_path_raw;
        unesc_owned = unesc;
        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs = resolveAbs(&abs_buf, unesc, mctx) orelse break :blk unesc;
        break :blk normalizeLexical(&canon_buf, abs) orelse unesc;
    };

    const orig_match = matchesPathPattern(pp, mctx, file_path);

    // ⚠️ Windows 已知限制(review F6):realpath 层整个跳过。pfs.realpath 走 CRT
    // `_fullpath`——**纯词法**,不解 symlink/junction,该层在 Windows 提供不了任何
    // symlink 防护;反而因"①分隔符/盘符词法改写 ②相对路径按进程 cwd(≠mctx.cwd)展开"
    // 制造假分歧,把所有 allow 规则打进双匹配分支误杀。真解析需
    // GetFinalPathNameByHandle(roadmap)。缓解:Windows 创建 symlink 需管理员/开发者
    // 模式,攻击面有限。POSIX 语义零变化。
    if (@import("builtin").os.tag == .windows) return orig_match;

    // 尝试 realpath 解析(symlink 额外一层;用 canonicalize 后的路径,escaped 原文 realpath 会失败)
    var rp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = realpathZ(&rp_buf, file_path);

    if (resolved == null or std.mem.eql(u8, resolved.?, file_path)) {
        // 无链接 / 解析失败:单路径语义(此时 orig_match 已基于折叠后路径,`..` 不再漏)
        return orig_match;
    }
    const target_match = matchesPathPattern(pp, mctx, resolved.?);

    return switch (mode) {
        .allow => orig_match and target_match, // 双匹配才放行
        .deny, .ask => orig_match or target_match, // 任一匹配即触发
    };
}

const util_json_mod = @import("../util/json.zig");

/// realpath(file_path) 写入 buf,返回 slice。失败返 null。
fn realpathZ(buf: []u8, file_path: []const u8) ?[]const u8 {
    var pz: [std.fs.max_path_bytes]u8 = undefined;
    if (file_path.len + 1 > pz.len) return null;
    @memcpy(pz[0..file_path.len], file_path);
    pz[file_path.len] = 0;
    var out: [std.fs.max_path_bytes]u8 = undefined;
    const res = pfs.realpath(@ptrCast(&pz), &out);
    if (res == null) return null;
    const resolved = std.mem.span(@as([*:0]u8, @ptrCast(res.?)));
    if (resolved.len > buf.len) return null;
    @memcpy(buf[0..resolved.len], resolved);
    return buf[0..resolved.len];
}

/// Bash 规则只描述**单条**命令:复合命令(&& || ; | |& & 换行)拆段,每段 stripWrappers 后
/// 与 pattern 比对,按规则种类聚合(见 RuleMode)——
///   allow:**每段**都匹中才命中(`git status && rm x` 不被 Bash(git *) 放行);
///   deny/ask:**任一段**匹中即命中(`ls && rm x` 的 rm 段触发 Bash(rm *);否则无害前缀
///   让 deny 失效,bypass_permissions 等兜底 allow 的模式照样执行被 deny 的命令)。
/// 拆的是 shell 真正收到的字节(commandFromArgs)。判不了(内存不足)时 allow 不命中、
/// deny/ask 命中:两个方向都 fail-closed。
fn matchesBashCompound(pattern: []const u8, mctx: *const MatchContext, args: []const u8, mode: RuleMode) bool {
    const bp = @import("bash_parser.zig");
    const fail_closed = mode != .allow;
    // 常见命令不上堆;超长命令(heredoc 等)落到 mctx.alloc(未填则 page_allocator)。
    var sfa = std.heap.stackFallback(2048, mctx.alloc orelse std.heap.page_allocator);
    const scratch = sfa.get();
    const command = commandFromArgs(scratch, args) catch return fail_closed;
    defer if (command) |c| scratch.free(c);
    const segs = bp.splitCompound(scratch, command orelse "") catch return fail_closed;
    defer scratch.free(segs);
    // 无段可比(没有 command 字段——未知工具名也按 bash-style pattern 解析,如 `Grep(**)`
    // ——或空命令):pattern 对空串判定,与拆段前一致,这类规则不因拆段失效。
    if (segs.len == 0) return matchesBashPattern(pattern, "");
    for (segs) |seg| {
        const hit = matchesBashPattern(pattern, bp.stripWrappers(seg));
        switch (mode) {
            .allow => if (!hit) return false,
            .deny, .ask => if (hit) return true,
        }
    }
    return mode == .allow; // allow:每段都匹中;deny/ask:没有一段匹中
}

/// Bash 工具真正交给 shell 的命令:与 tools/bash.zig executeInner(及 monitor.zig)同一取字段
/// (common.extractJsonArg)+ 同一 JSON unescape。拿转义原文拆段时 `\n`、`\u0026\u0026` 这类
/// 分隔符不可见(deny 被当单段漏判,allow 被 `echo hi\nrm -rf ~` 骗过),`\"` 又让引号内的
/// `;` 被误拆。字段缺失 → null。caller 持有返回值。旧 config.json 规则(rule_matcher)同用。
pub fn commandFromArgs(gpa: std.mem.Allocator, args: []const u8) error{OutOfMemory}!?[]u8 {
    const escaped = tools_common.extractJsonArg(args, "command") orelse return null;
    return try util_json_mod.unescapeString(escaped, gpa);
}

const tools_common = @import("../tools/common.zig");

// ============================================================================
// Bash 通配:* 任意 + 末尾 word boundary + :* 后缀等价
// ============================================================================

/// Bash pattern 匹配规则:
///   `npm run build` exact
///   `npm *` prefix
///   `* install` suffix
///   `git * main` middle wildcard
///   `npm test *` prefix + 必须 word boundary(空格或字符串末)
///   `ls *` 同上
///   `ls*` (无空格)前缀无 boundary 约束
///   `ls:*` 末尾 :* 等价 ` *`
pub fn matchesBashPattern(pattern: []const u8, cmd: []const u8) bool {
    var pat = pattern;
    // :* 后缀等价 ` *`
    if (std.mem.endsWith(u8, pat, ":*")) {
        // 但只能在末尾;转写为 trailing ` *` 含义
        const prefix = pat[0 .. pat.len - 2];
        return matchPrefixWithBoundary(prefix, cmd);
    }
    // 末尾 ` *`(空格+星)— 前缀 + word boundary
    if (std.mem.endsWith(u8, pat, " *")) {
        const prefix = pat[0 .. pat.len - 2];
        return matchPrefixWithBoundary(prefix, cmd);
    }
    // 末尾 `*`(无空格)— glob 任意尾
    if (std.mem.endsWith(u8, pat, "*") and (pat.len < 2 or pat[pat.len - 2] != ' ')) {
        return matchGlob(pat, cmd);
    }
    return matchGlob(pat, cmd);
}

/// 前缀 + word boundary:cmd 必须等于 prefix,或以 `prefix ` 开头。
fn matchPrefixWithBoundary(prefix: []const u8, cmd: []const u8) bool {
    if (std.mem.eql(u8, prefix, cmd)) return true;
    if (cmd.len > prefix.len and std.mem.startsWith(u8, cmd, prefix) and cmd[prefix.len] == ' ') return true;
    return false;
}

/// 简化 glob:`*` 匹配任意字符序列(含空格);其它字符精确。
fn matchGlob(pattern: []const u8, s: []const u8) bool {
    return matchGlobImpl(pattern, 0, s, 0);
}

fn matchGlobImpl(p: []const u8, pi: usize, s: []const u8, si: usize) bool {
    var i = pi;
    var j = si;
    while (i < p.len) {
        if (p[i] == '*') {
            // 跳过连续 *
            while (i < p.len and p[i] == '*') i += 1;
            if (i >= p.len) return true; // 末尾 * 吞剩余
            // 试每个 j..len 位置
            while (j <= s.len) : (j += 1) {
                if (matchGlobImpl(p, i, s, j)) return true;
            }
            return false;
        }
        if (j >= s.len) return false;
        if (p[i] != s[j]) return false;
        i += 1;
        j += 1;
    }
    return j == s.len;
}

// ============================================================================
// 路径匹配(gitignore-style + 锚点)
// ============================================================================

fn matchesPathPattern(pp: PathPattern, mctx: *const MatchContext, file_path_in: []const u8) bool {
    const is_windows = @import("builtin").os.tag == .windows;
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_raw = resolveAbs(&abs_buf, file_path_in, mctx) orelse return false;
    // Windows:词法规范化成 "X:/a/b"(正斜杠、盘符大写)再比对——否则 "D:\x" 对
    // "D:/x" 前缀永假,所有路径规则失效。POSIX 原样零变化。
    var wnorm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = if (is_windows) (normalizeLexical(&wnorm_buf, abs_raw) orelse return false) else abs_raw;

    var wbase_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base: []const u8 = blk: {
        const raw = anchorBase(pp.anchor, mctx) orelse return false;
        if (!is_windows) break :blk raw;
        if (pp.anchor == .absolute) {
            // 绝对锚 = 文件系统根:盘符路径的根是 "X:/";POSIX 形("/x")保持 "/"。
            if (abs.len >= 3 and abs[1] == ':') break :blk abs[0..3];
            break :blk "/";
        }
        break :blk normalizeLexical(&wbase_buf, raw) orelse return false;
    };

    if (!pathStartsWith(abs, base)) return false;

    var rel: []const u8 = abs[base.len..];
    if (rel.len > 0 and rel[0] == '/') rel = rel[1..];

    // gitignore 语义:pattern 无 / → 匹配任意深度的 basename
    if (std.mem.indexOfScalar(u8, pp.glob, '/') == null) {
        return basenameMatchesAnyDepth(pp.glob, rel);
    }
    return matchGitignoreGlob(pp.glob, rel);
}

/// gitignore 风格:无 / 的 pattern 匹配任意深度的 basename。
fn basenameMatchesAnyDepth(pattern: []const u8, rel: []const u8) bool {
    // 直接 basename
    const slash = std.mem.lastIndexOfScalar(u8, rel, '/');
    const name = if (slash) |i| rel[i + 1 ..] else rel;
    return matchGitignoreGlob(pattern, name);
}

fn anchorBase(anchor: PathAnchor, mctx: *const MatchContext) ?[]const u8 {
    return switch (anchor) {
        .absolute => "/",
        .home => mctx.home,
        .project => mctx.project_root,
        .cwd => mctx.cwd,
    };
}

/// 路径前缀比较。Windows 文件系统大小写不敏感 → ASCII 折叠比较;POSIX 精确。
fn pathStartsWith(path: []const u8, prefix: []const u8) bool {
    if (@import("builtin").os.tag != .windows) return std.mem.startsWith(u8, path, prefix);
    if (path.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(path[0..prefix.len], prefix);
}

fn resolveAbs(buf: []u8, path: []const u8, mctx: *const MatchContext) ?[]const u8 {
    if (path.len == 0) return null;
    if (path[0] == '/') return path; // 已是绝对
    if (@import("builtin").os.tag == .windows) {
        // 盘符绝对("C:\x"/"C:/x")与 UNC/根相对("\x")也算绝对——否则会被当
        // 相对路径拼到 cwd 后面,产出垃圾路径(review F7)。
        if (path.len >= 2 and path[1] == ':') return path;
        if (path[0] == '\\') return path;
    }
    if (std.mem.startsWith(u8, path, "~/")) {
        return joinPath(buf, mctx.home, path[2..]);
    }
    return joinPath(buf, mctx.cwd, path);
}

// ============================================================================
// 工作目录集(cwd + additional_dirs)成员判定
// ============================================================================

/// file_path 是否落在工作目录集(cwd + additional_dirs)内。
/// 用途:accept_edits 模式下 Write/Edit 自动放行的 scope 门(对齐 cc:acceptEdits
/// 只自动接受工作目录内的编辑,/add-dir 扩展该集合)。
///
/// 语义(allow 侧,对齐 matchesPathDual 的 allow):
///   - 路径先词法归一化(消 `.`/`..`/`//`),防 `..` 逃逸绕过前缀判定;
///   - 原路径与 realpath(若解析出不同路径)**都**必须在集内——指向区外的
///     symlink 不自动放行;
///   - 相对路径按 cwd 解析,`~/` 按 home;cwd 为空时恒 false(无 scope 信息)。
pub fn isInWorkingDirs(mctx: *const MatchContext, file_path: []const u8) bool {
    if (file_path.len == 0) return false;
    if (mctx.cwd.len == 0) return false;
    if (!pathInWorkingDirs(mctx, file_path)) return false;
    // symlink:realpath 解析出不同路径 → 目标也必须在集内。
    // Windows 跳过该层:_fullpath 纯词法不解 symlink(防护为零),且相对路径按
    // **进程 cwd** 展开(≠mctx.cwd)会制造假分歧误拒——与 matchesPathDual 同款取舍。
    if (@import("builtin").os.tag == .windows) return true;
    var rp_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (realpathZ(&rp_buf, file_path)) |resolved| {
        if (!std.mem.eql(u8, resolved, file_path)) {
            if (!pathInWorkingDirs(mctx, resolved)) return false;
        }
    }
    return true;
}

fn pathInWorkingDirs(mctx: *const MatchContext, path: []const u8) bool {
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = resolveAbs(&abs_buf, path, mctx) orelse return false;
    var norm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const norm = normalizeLexical(&norm_buf, abs) orelse return false;
    if (dirContains(mctx.cwd, norm)) return true;
    for (mctx.additional_dirs) |d| {
        if (dirContains(d, norm)) return true;
    }
    return false;
}

/// path(已归一化)是否在 dir 子树内(含 dir 自身)。dir 亦先归一化
/// (配置可能带尾 `/` 或 `.` 段);前缀命中后要求段边界(防 /proj 匹配 /project)。
fn dirContains(dir_in: []const u8, path: []const u8) bool {
    if (dir_in.len == 0) return false;
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = normalizeLexical(&dbuf, dir_in) orelse return false;
    if (!pathStartsWith(path, dir)) return false;
    if (path.len == dir.len) return true;
    if (dir[dir.len - 1] == '/') return true; // 根("/"、Windows "C:/")自带尾分隔符
    return path[dir.len] == '/';
}

/// 词法归一化绝对路径:消 `//`、`.` 段;`..` 弹出上一段(根处 clamp)。
/// 不触盘(纯词法);非绝对路径返 null。输出写进 buf。
///
/// Windows 扩展(POSIX 分支零变化):
///   - 盘符绝对("C:\x"/"c:/x")→ 规范形 "C:/x"(盘符大写、全正斜杠);
///   - 两种分隔符都认,`..` clamp 在盘符根("C:/")不再弹;
///   - 盘符相对("C:foo")语义依赖每盘独立 cwd → 拒绝(null);
///   - UNC("\\server\share")不支持:退化为 '/'-根处理,share 语义丢失——已知限制,
///     permission 规则不建议对 UNC 路径下断言(review F1)。
fn normalizeLexical(buf: []u8, path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    const is_windows = @import("builtin").os.tag == .windows;
    var prefix_len: usize = 0;
    var rest = path;
    if (is_windows and path.len >= 2 and path[1] == ':') {
        if (path.len < 3 or (path[2] != '/' and path[2] != '\\')) return null; // 盘符相对
        if (buf.len < 2) return null;
        buf[0] = std.ascii.toUpper(path[0]);
        buf[1] = ':';
        prefix_len = 2;
        rest = path[2..];
    } else if (path[0] != '/' and !(is_windows and path[0] == '\\')) {
        return null;
    }
    if (path.len > buf.len) return null;
    var len: usize = prefix_len; // buf 中已写入长度;不含尾 /(根除外)
    const seps = if (is_windows) "/\\" else "/";
    var it = std.mem.splitAny(u8, rest, seps);
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            // 弹出上一段(根处 clamp 不再弹)
            if (len > prefix_len) {
                const prev = std.mem.lastIndexOfScalar(u8, buf[prefix_len..len], '/') orelse 0;
                len = prefix_len + prev;
            }
            continue;
        }
        if (len + 1 + seg.len > buf.len) return null;
        buf[len] = '/';
        @memcpy(buf[len + 1 .. len + 1 + seg.len], seg);
        len += 1 + seg.len;
    }
    if (len == prefix_len) {
        if (len + 1 > buf.len) return null;
        buf[len] = '/';
        return buf[0 .. len + 1]; // 全消光 → 根("/" 或 "C:/")
    }
    return buf[0..len];
}

/// 词法折叠 `.`/`..`/`//`,**支持绝对与相对路径**(相对时保留无法抵消的前导 `../`)。
/// 用途:旧 rule_matcher(config.json permission_rules)对**未锚定**的 path_glob 做匹配,
/// 路径可能是相对的(`src/foo`),无 cwd 可 resolveAbs——故用相对折叠:`src/../../etc/x`
/// → `../etc/x`(不再匹配 `src/**`),消除 B1 `..` 逃逸。绝对路径 `/proj/../etc` → `/etc`。
/// 输出写进 buf;path 超出 buf 或空 → null。语义对齐 Go filepath.Clean / Rust Path 词法。
pub fn foldLexicalRel(buf: []u8, path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (path.len > buf.len) return null;
    const absolute = path[0] == '/';
    var len: usize = 0; // 已写入长度(不含前导 / 的隐式根)
    // 段栈用 buf 本身;相对路径无法抵消的前导 `..` 段原样保留(has_poppable 判 last_seg==".."
    // 阻止后续段错误抵消它)。
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            // 能否弹出上一段?能弹的条件:存在一个"非前导 .."的已写段。
            const has_poppable = blk: {
                if (len == 0) break :blk false;
                // 最后一段起点
                const last_start = std.mem.lastIndexOfScalar(u8, buf[0..len], '/');
                const seg_start = if (last_start) |i| i + 1 else 0;
                const last_seg = buf[seg_start..len];
                if (std.mem.eql(u8, last_seg, "..")) break :blk false; // 前导 ..,不可抵消
                break :blk true;
            };
            if (has_poppable) {
                const prev = std.mem.lastIndexOfScalar(u8, buf[0..len], '/') orelse 0;
                len = prev;
                continue;
            }
            // 不可抵消:绝对路径在根处 clamp(丢弃);相对路径保留前导 ..
            if (absolute) continue;
            const piece = if (len == 0) ".." else "/..";
            if (len + piece.len > buf.len) return null;
            @memcpy(buf[len .. len + piece.len], piece);
            len += piece.len;
            continue;
        }
        const piece_len = seg.len + 1; // "/seg" 或(相对首段)"seg"
        if (len == 0 and !absolute) {
            if (seg.len > buf.len) return null;
            @memcpy(buf[0..seg.len], seg);
            len = seg.len;
        } else {
            if (len + piece_len > buf.len) return null;
            buf[len] = '/';
            @memcpy(buf[len + 1 .. len + 1 + seg.len], seg);
            len += piece_len;
        }
    }
    if (len == 0) {
        if (absolute) {
            buf[0] = '/';
            return buf[0..1];
        }
        buf[0] = '.'; // 相对全消光 → "."(当前目录)
        return buf[0..1];
    }
    return buf[0..len];
}

fn joinPath(buf: []u8, a: []const u8, b: []const u8) ?[]const u8 {
    const total = a.len + 1 + b.len;
    if (total > buf.len) return null;
    @memcpy(buf[0..a.len], a);
    buf[a.len] = '/';
    @memcpy(buf[a.len + 1 .. a.len + 1 + b.len], b);
    return buf[0..total];
}

/// gitignore 风格 glob:`*` 单段、`**` 多段。
fn matchGitignoreGlob(pattern: []const u8, path: []const u8) bool {
    // 简化:** 当作 `*` 包含 / 处理;`*` 不跨 /
    return matchGitignoreImpl(pattern, 0, path, 0);
}

fn matchGitignoreImpl(p: []const u8, pi: usize, s: []const u8, si: usize) bool {
    var i = pi;
    var j = si;
    while (i < p.len) {
        if (i + 1 < p.len and p[i] == '*' and p[i + 1] == '*') {
            // ** 吞任意(含 /)
            i += 2;
            // 跳一个 / 让 `**/` 匹配
            if (i < p.len and p[i] == '/') i += 1;
            if (i >= p.len) return true;
            while (j <= s.len) : (j += 1) {
                if (matchGitignoreImpl(p, i, s, j)) return true;
            }
            return false;
        }
        if (p[i] == '*') {
            // * 不跨 /
            i += 1;
            if (i >= p.len) {
                // 末尾 *:吞到下个 / 或 EOL
                while (j < s.len and s[j] != '/') j += 1;
                return j == s.len;
            }
            while (j <= s.len) : (j += 1) {
                if (matchGitignoreImpl(p, i, s, j)) return true;
                if (j < s.len and s[j] == '/') break; // * 不跨 /
            }
            return false;
        }
        if (j >= s.len) return false;
        if (p[i] != s[j]) return false;
        i += 1;
        j += 1;
    }
    return j == s.len;
}

/// 裸文件名匹配任意深度(gitignore 语义)。
fn basenameMatches(pattern: []const u8, path: []const u8) bool {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const name = if (slash) |i| path[i + 1 ..] else path;
    return matchGitignoreGlob(pattern, name);
}

// ============================================================================
// WebFetch domain
// ============================================================================

fn matchesWebDomain(allowed: []const u8, args: []const u8) bool {
    // 从 args 抽 url 字段 → 解析 host
    const url = extractStringField(args, "url") orelse return false;
    const host = hostFromUrl(url) orelse return false;
    // 严格相等 或 `*.example.com` 子域名
    if (std.mem.eql(u8, host, allowed)) return true;
    if (std.mem.startsWith(u8, allowed, "*.")) {
        const suffix = allowed[1..]; // ".example.com"
        return std.mem.endsWith(u8, host, suffix);
    }
    return false;
}

fn hostFromUrl(url: []const u8) ?[]const u8 {
    // 跳过 scheme://
    var s = url;
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
    // 取到第一个 / 或 ? 或 # 或 :(port)
    var end: usize = s.len;
    for (s, 0..) |c, i| {
        if (c == '/' or c == '?' or c == '#' or c == ':') {
            end = i;
            break;
        }
    }
    if (end == 0) return null;
    return s[0..end];
}

// ============================================================================
// Skill / Agent / MCP
// ============================================================================

fn matchesSkill(sm: SkillMatch, args: []const u8) bool {
    const name = extractStringField(args, "name") orelse return false;
    if (sm.prefix) return std.mem.startsWith(u8, name, sm.name);
    return std.mem.eql(u8, name, sm.name);
}

fn matchesAgent(allowed_name: []const u8, args: []const u8) bool {
    const subtype = extractStringField(args, "subagent_type") orelse return false;
    return std.mem.eql(u8, subtype, allowed_name);
}

/// `mcp__server` / `mcp__server__*` / `mcp__server__tool` 三种形式。
/// MCP 工具名约定:`<server>__<tool>`(cc-zig 的 registry_bridge 命名)。
fn matchesMcp(pattern: []const u8, tool_name: []const u8) bool {
    // 兼容 cc-zig 命名(无前导 mcp__):剥前缀
    if (!std.mem.startsWith(u8, pattern, "mcp__")) return false;
    const after = pattern[5..];
    // 拆 server / tool
    const sep = std.mem.indexOf(u8, after, "__");
    if (sep == null) {
        // mcp__server — 匹配该 server 任意工具(tool_name 须以 server__ 开头)
        const prefix = try_concat(after, "__");
        _ = prefix;
        var buf: [256]u8 = undefined;
        const need = std.fmt.bufPrint(&buf, "{s}__", .{after}) catch return false;
        return std.mem.startsWith(u8, tool_name, need);
    }
    const server = after[0..sep.?];
    const tool_part = after[sep.? + 2 ..];
    if (std.mem.eql(u8, tool_part, "*")) {
        var buf: [256]u8 = undefined;
        const need = std.fmt.bufPrint(&buf, "{s}__", .{server}) catch return false;
        return std.mem.startsWith(u8, tool_name, need);
    }
    var buf: [512]u8 = undefined;
    const need = std.fmt.bufPrint(&buf, "{s}__{s}", .{ server, tool_part }) catch return false;
    return std.mem.eql(u8, tool_name, need);
}

fn try_concat(_: []const u8, _: []const u8) []const u8 {
    return "";
}

// ============================================================================
// args 抽字段(共用 util/json 但简化)
// ============================================================================

/// command 字段的 JSON 转义原文(未 unescape)。Bash 规则匹配不用它,用 commandFromArgs。
pub fn extractCommand(args: []const u8) []const u8 {
    return extractStringField(args, "command") orelse "";
}

pub fn extractPath(args: []const u8) []const u8 {
    return extractStringField(args, "file_path") orelse
        extractStringField(args, "notebook_path") orelse
        extractStringField(args, "path") orelse "";
}

fn extractStringField(args: []const u8, field: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "\"{s}\":", .{field}) catch return null;
    const idx = std.mem.indexOf(u8, args, key) orelse return null;
    var pos = idx + key.len;
    while (pos < args.len and (args[pos] == ' ' or args[pos] == '\t')) : (pos += 1) {}
    if (pos >= args.len or args[pos] != '"') return null;
    pos += 1;
    var end = pos;
    while (end < args.len) : (end += 1) {
        if (args[end] == '\\') {
            end += 1;
            continue;
        }
        if (args[end] == '"') break;
    }
    if (end >= args.len) return null;
    return args[pos..end];
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseRule: bare tool name = all" {
    const r = try parseRule("Bash");
    try testing.expectEqualStrings("Bash", r.tool);
    try testing.expect(r.spec == .all);
}

test "parseRule: Bash(*) = all" {
    const r = try parseRule("Bash(*)");
    try testing.expect(r.spec == .all);
}

test "parseRule: Bash(npm run *) parses pattern" {
    const r = try parseRule("Bash(npm run *)");
    try testing.expectEqualStrings("npm run *", r.spec.bash_pattern);
}

test "parseRule: Read(./.env) path cwd" {
    const r = try parseRule("Read(./.env)");
    try testing.expect(r.spec.path_pattern.anchor == .cwd);
    try testing.expectEqualStrings(".env", r.spec.path_pattern.glob);
}

test "parseRule: Edit(/src/**) path project" {
    const r = try parseRule("Edit(/src/**)");
    try testing.expect(r.spec.path_pattern.anchor == .project);
    try testing.expectEqualStrings("src/**", r.spec.path_pattern.glob);
}

test "parseRule: Read(//Users/alice/secrets/**) absolute" {
    const r = try parseRule("Read(//Users/alice/secrets/**)");
    try testing.expect(r.spec.path_pattern.anchor == .absolute);
}

test "parseRule: Read(~/.ssh/**) home" {
    const r = try parseRule("Read(~/.ssh/**)");
    try testing.expect(r.spec.path_pattern.anchor == .home);
    try testing.expectEqualStrings(".ssh/**", r.spec.path_pattern.glob);
}

test "parseRule: WebFetch(domain:example.com)" {
    const r = try parseRule("WebFetch(domain:example.com)");
    try testing.expectEqualStrings("example.com", r.spec.web_domain);
}

test "parseRule: WebFetch missing domain: errors" {
    try testing.expectError(error.InvalidWebFetchSpec, parseRule("WebFetch(example.com)"));
}

test "parseRule: Skill(deploy) exact + Skill(deploy *) prefix" {
    const r1 = try parseRule("Skill(deploy)");
    try testing.expect(r1.spec.skill_match.prefix == false);
    try testing.expectEqualStrings("deploy", r1.spec.skill_match.name);

    const r2 = try parseRule("Skill(deploy *)");
    try testing.expect(r2.spec.skill_match.prefix == true);
    try testing.expectEqualStrings("deploy", r2.spec.skill_match.name);
}

test "parseRule: Agent(Explore)" {
    const r = try parseRule("Agent(Explore)");
    try testing.expectEqualStrings("Explore", r.spec.agent_name);
}

test "parseRule: mcp__server" {
    const r = try parseRule("mcp__puppeteer");
    try testing.expectEqualStrings("mcp", r.tool);
    try testing.expectEqualStrings("mcp__puppeteer", r.spec.mcp_match);
}

test "parseRule: unterminated paren errors" {
    try testing.expectError(error.UnterminatedParen, parseRule("Bash(npm"));
}

test "matchesBashPattern: exact" {
    try testing.expect(matchesBashPattern("npm run build", "npm run build"));
    try testing.expect(!matchesBashPattern("npm run build", "npm run test"));
}

test "matchesBashPattern: prefix with boundary 'npm *'" {
    try testing.expect(matchesBashPattern("npm *", "npm install"));
    try testing.expect(matchesBashPattern("npm *", "npm"));
    try testing.expect(!matchesBashPattern("npm *", "npmext"));
}

test "matchesBashPattern: 'ls *' boundary vs 'ls*' no boundary" {
    try testing.expect(matchesBashPattern("ls *", "ls -la"));
    try testing.expect(!matchesBashPattern("ls *", "lsof"));
    try testing.expect(matchesBashPattern("ls*", "ls -la"));
    try testing.expect(matchesBashPattern("ls*", "lsof"));
}

test "matchesBashPattern: ':*' suffix equals ' *'" {
    try testing.expect(matchesBashPattern("ls:*", "ls -la"));
    try testing.expect(!matchesBashPattern("ls:*", "lsof"));
}

test "matchesBashPattern: middle wildcard 'git * main'" {
    try testing.expect(matchesBashPattern("git * main", "git checkout main"));
    try testing.expect(matchesBashPattern("git * main", "git log --oneline main"));
    try testing.expect(!matchesBashPattern("git * main", "git push origin master"));
}

test "matchesBashPattern: suffix '* install'" {
    try testing.expect(matchesBashPattern("* install", "npm install"));
    try testing.expect(matchesBashPattern("* install", "pip install"));
    try testing.expect(!matchesBashPattern("* install", "npm test"));
}

test "matchGitignoreGlob: ** recursive, * single segment" {
    try testing.expect(matchGitignoreGlob("**/*.ts", "src/foo.ts"));
    try testing.expect(matchGitignoreGlob("**/*.ts", "deep/nested/foo.ts"));
    try testing.expect(matchGitignoreGlob("src/**", "src/foo/bar.ts"));
    try testing.expect(!matchGitignoreGlob("src/*", "src/foo/bar.ts")); // * 不跨 /
    try testing.expect(matchGitignoreGlob("src/*", "src/foo.ts"));
}

test "hostFromUrl: extract hostname" {
    try testing.expectEqualStrings("github.com", hostFromUrl("https://github.com/foo/bar").?);
    try testing.expectEqualStrings("api.example.com", hostFromUrl("http://api.example.com:8080/path").?);
}

test "matchesWebDomain: exact + wildcard" {
    const r1 = RuleSpec{ .tool = "WebFetch", .spec = .{ .web_domain = "github.com" } };
    var mctx = MatchContext{};
    try testing.expect(matches(&r1, &mctx, "WebFetch", "{\"url\":\"https://github.com/foo\"}"));
    try testing.expect(!matches(&r1, &mctx, "WebFetch", "{\"url\":\"https://example.com/\"}"));

    const r2 = RuleSpec{ .tool = "WebFetch", .spec = .{ .web_domain = "*.googleapis.com" } };
    try testing.expect(matches(&r2, &mctx, "WebFetch", "{\"url\":\"https://maps.googleapis.com/api\"}"));
    try testing.expect(!matches(&r2, &mctx, "WebFetch", "{\"url\":\"https://google.com/\"}"));
}

test "matches: Bash rule via spec" {
    const r = try parseRule("Bash(git *)");
    var mctx = MatchContext{};
    try testing.expect(matches(&r, &mctx, "Bash", "{\"command\":\"git status\"}"));
    try testing.expect(!matches(&r, &mctx, "Bash", "{\"command\":\"rm -rf /\"}"));
}

test "matches: Read path glob (cwd anchor)" {
    const r = try parseRule("Read(*.env)");
    var mctx = MatchContext{ .cwd = "/proj" };
    try testing.expect(matches(&r, &mctx, "Read", "{\"file_path\":\"/proj/.env\"}"));
    // gitignore semantics:裸文件名匹配任意深度
    try testing.expect(matches(&r, &mctx, "Read", "{\"file_path\":\"/proj/sub/.env\"}"));
}

test "matches: Agent rule by subagent_type" {
    const r = try parseRule("Agent(Explore)");
    var mctx = MatchContext{};
    try testing.expect(matches(&r, &mctx, "Task", "{\"subagent_type\":\"Explore\"}"));
    try testing.expect(!matches(&r, &mctx, "Task", "{\"subagent_type\":\"Plan\"}"));
}

test "matches: mcp__server matches all tools from that server" {
    const r = try parseRule("mcp__puppeteer");
    var mctx = MatchContext{};
    try testing.expect(matches(&r, &mctx, "puppeteer__navigate", "{}"));
    try testing.expect(matches(&r, &mctx, "puppeteer__screenshot", "{}"));
    try testing.expect(!matches(&r, &mctx, "slack__send", "{}"));
}

test "matches: mcp__server__tool exact" {
    const r = try parseRule("mcp__puppeteer__navigate");
    var mctx = MatchContext{};
    try testing.expect(matches(&r, &mctx, "puppeteer__navigate", "{}"));
    try testing.expect(!matches(&r, &mctx, "puppeteer__screenshot", "{}"));
}

test "matchesMode: Bash compound — allow 要每段都匹中,deny/ask 任一段即命中" {
    const r = try parseRule("Bash(git *)");
    const mctx = MatchContext{};
    const mixed = "{\"command\":\"git status && rm -rf /\"}";
    // 单段:正常
    try testing.expect(matchesMode(&r, &mctx, "Bash", "{\"command\":\"git status\"}", .allow));
    // 复合且全是 git:OK
    try testing.expect(matchesMode(&r, &mctx, "Bash", "{\"command\":\"git status && git log\"}", .allow));
    // 复合且夹了 rm:allow 整体拒;deny/ask 的 git 段已匹中 → 命中
    try testing.expect(!matchesMode(&r, &mctx, "Bash", mixed, .allow));
    try testing.expect(matchesMode(&r, &mctx, "Bash", mixed, .deny));
    try testing.expect(matchesMode(&r, &mctx, "Bash", mixed, .ask));
    // 没有一段匹中 → 都不命中
    try testing.expect(!matchesMode(&r, &mctx, "Bash", "{\"command\":\"ls && rm x\"}", .deny));
    // 空命令按空串判定:`git *` 匹不中空串 → allow 不放行,deny 不命中
    try testing.expect(!matchesMode(&r, &mctx, "Bash", "{\"command\":\"\"}", .allow));
    try testing.expect(!matchesMode(&r, &mctx, "Bash", "{\"command\":\"\"}", .deny));
}

test "matchesMode: 无 command 字段的 bash-style 规则仍按空命令判定" {
    // 未知工具名按 bash-style pattern 解析;Grep 调用没有 command 字段,`**` 匹中空串 →
    // 等价整工具,deny 与 allow 都命中(拆段前即如此,不能因拆段静默失效)。
    const any = try parseRule("Grep(**)");
    const mctx = MatchContext{};
    try testing.expect(matchesMode(&any, &mctx, "Grep", "{\"pattern\":\"x\"}", .deny));
    try testing.expect(matchesMode(&any, &mctx, "Grep", "{\"pattern\":\"x\"}", .allow));
    // 匹不中空串的 pattern 照旧不命中
    const rm = try parseRule("Bash(rm *)");
    try testing.expect(!matchesMode(&rm, &mctx, "Bash", "{\"description\":\"x\"}", .deny));
}

test "commandFromArgs: 与 Bash 工具同一取字段 + unescape" {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const a = fba.allocator();
    // JSON 转义的换行、`&&`、引号是 shell 收到的真字节
    try testing.expectEqualStrings("ls\nrm x", (try commandFromArgs(a, "{\"command\":\"ls\\nrm x\"}")).?);
    try testing.expectEqualStrings("a && b", (try commandFromArgs(a, "{\"command\":\"a \\u0026\\u0026 b\"}")).?);
    try testing.expectEqualStrings("echo \"x\"", (try commandFromArgs(a, "{\"command\": \"echo \\\"x\\\"\"}")).?);
    // 非字符串值:Bash 工具照样把裸 token 交给 shell,规则也按它判
    try testing.expectEqualStrings("true", (try commandFromArgs(a, "{\"command\":true}")).?);
    try testing.expect((try commandFromArgs(a, "{\"description\":\"x\"}")) == null);
}

test "matchesMode: Bash 判不了(内存不足)时 allow 不命中、deny/ask 命中" {
    // 超出栈缓冲的命令落到 mctx.alloc:失败分配器下 unescape 做不完。
    var args: [4096]u8 = undefined;
    const head = "{\"command\":\"echo ";
    @memcpy(args[0..head.len], head);
    @memset(args[head.len .. args.len - 2], 'a');
    @memcpy(args[args.len - 2 ..], "\"}");
    const deny_rm = try parseRule("Bash(rm *)");
    const allow_echo = try parseRule("Bash(echo *)");

    const oom = MatchContext{ .alloc = testing.failing_allocator };
    try testing.expect(matchesMode(&deny_rm, &oom, "Bash", &args, .deny));
    try testing.expect(matchesMode(&deny_rm, &oom, "Bash", &args, .ask));
    try testing.expect(!matchesMode(&allow_echo, &oom, "Bash", &args, .allow));
    // 对照:分配成功时按内容判定
    const ok = MatchContext{ .alloc = testing.allocator };
    try testing.expect(!matchesMode(&deny_rm, &ok, "Bash", &args, .deny));
    try testing.expect(matchesMode(&allow_echo, &ok, "Bash", &args, .allow));
}

test "matches: Bash with wrapper stripped before match" {
    const r = try parseRule("Bash(npm test)");
    var mctx = MatchContext{};
    try testing.expect(matches(&r, &mctx, "Bash", "{\"command\":\"timeout 30 npm test\"}"));
    try testing.expect(matches(&r, &mctx, "Bash", "{\"command\":\"nice -n 5 npm test\"}"));
}

test "matchesMode: symlink deny triggers if target matches (任一)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // 用 POSIX symlink() 造真符号链接测拒绝,windows 无此 syscall
    // 建一个真 symlink: <per-pid dir>/link.txt → <per-pid dir>/secret.env
    var secret_buf: [512]u8 = undefined;
    const secret = tt.path(&secret_buf, "secret.env");
    var link_buf: [512]u8 = undefined;
    const link = tt.path(&link_buf, "link.txt");
    const link_path: []const u8 = link;

    // 创建 secret 文件
    const fd = pfs.open(secret.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.SkipZigTest;
    _ = pfs.close(fd);
    defer pfs.unlinkPath(secret.ptr) catch {};
    // 创建 symlink link → secret
    pfs.unlinkPath(link.ptr) catch {};
    if (std.c.symlink(secret.ptr, link.ptr) != 0) return error.SkipZigTest;
    defer pfs.unlinkPath(link.ptr) catch {};

    // deny 规则:Read(secret 的 basename) — 裸文件名 gitignore 语义,匹配任意深度
    // 用户访问 link(basename=link.txt 不匹配),但 realpath 解析到 secret
    // (basename=secret.env 匹配)→ deny 任一即触发;两者都在 cwd(/tmp)之下的 per-pid 目录里
    const secret_name = "secret.env";
    var pat_buf: [96]u8 = undefined;
    const pat = try std.fmt.bufPrint(&pat_buf, "Read({s})", .{secret_name}); // cwd anchor 裸文件名
    const r = try parseRule(pat);
    // cwd 必须是 /tmp 的**解析后**路径:macOS 上 /tmp 是 /private/tmp 的符号链接,
    // Linux 上就是 /tmp。硬编码任一侧都会让另一侧的 realpath 落在 cwd 之外。
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_z = pfs.realpath("/tmp", &cwd_buf) orelse return error.SkipZigTest;
    var mctx = MatchContext{ .cwd = std.mem.span(cwd_z) };

    var args_buf: [256]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"file_path\":\"{s}\"}}", .{link_path});

    // deny 模式:link basename 不匹配,但 realpath(secret) basename 匹配 → 任一即触发
    try testing.expect(matchesMode(&r, &mctx, "Read", args, .deny));
}

test "normalizeLexical: 消 . .. // 与根 clamp" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("/a/b", normalizeLexical(&buf, "/a/b").?);
    try testing.expectEqualStrings("/a/b", normalizeLexical(&buf, "/a//b/").?);
    try testing.expectEqualStrings("/a/b", normalizeLexical(&buf, "/a/./b").?);
    try testing.expectEqualStrings("/etc/passwd", normalizeLexical(&buf, "/proj/../etc/passwd").?);
    try testing.expectEqualStrings("/", normalizeLexical(&buf, "/..").?);
    try testing.expectEqualStrings("/", normalizeLexical(&buf, "/a/..").?);
    // 非绝对路径 → null
    try testing.expect(normalizeLexical(&buf, "a/b") == null);
    try testing.expect(normalizeLexical(&buf, "") == null);
}

test "isInWorkingDirs: cwd 内/外 + additional_dirs + .. 逃逸 + 边界" {
    const extra = [_][]const u8{ "/extra/lib", "/opt/data/" };
    const mctx = MatchContext{ .cwd = "/proj", .additional_dirs = &extra };

    // cwd 子树内(不存在的路径:realpath 失败 → 只词法判定)
    try testing.expect(isInWorkingDirs(&mctx, "/proj/src/cczig_wd_nonexistent.zig"));
    try testing.expect(isInWorkingDirs(&mctx, "/proj"));
    // additional dir 内(含尾 / 配置的归一化)
    try testing.expect(isInWorkingDirs(&mctx, "/extra/lib/cczig_wd_x.txt"));
    try testing.expect(isInWorkingDirs(&mctx, "/opt/data/cczig_wd_y.bin"));
    // 集外
    try testing.expect(!isInWorkingDirs(&mctx, "/etc/passwd"));
    try testing.expect(!isInWorkingDirs(&mctx, "/extra/other/z"));
    // `..` 逃逸:词法归一化后指向集外 → 拒
    try testing.expect(!isInWorkingDirs(&mctx, "/proj/../etc/passwd"));
    try testing.expect(!isInWorkingDirs(&mctx, "/extra/lib/../../etc/x"));
    // 前缀非段边界:/proj 不匹配 /project
    try testing.expect(!isInWorkingDirs(&mctx, "/project/file"));
    // 相对路径按 cwd 解析
    try testing.expect(isInWorkingDirs(&mctx, "src/cczig_wd_rel.zig"));
    try testing.expect(!isInWorkingDirs(&mctx, "../outside.txt"));
    // cwd 空 → 恒 false(无 scope 信息)
    const mctx_nocwd = MatchContext{ .additional_dirs = &extra };
    try testing.expect(!isInWorkingDirs(&mctx_nocwd, "/extra/lib/f"));
    // 空路径
    try testing.expect(!isInWorkingDirs(&mctx, ""));
}

test "isInWorkingDirs: 指向区外的 symlink 不放行(allow 双匹配语义)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // 每进程唯一目录里造 dir + 指向 /etc/hosts 的 symlink
    var dir_buf: [512]u8 = undefined;
    const dir = @import("../util/fs.zig").testing.perPidDir(&dir_buf, "cc-zig-wd");
    _ = pfs.mkdir(dir.ptr, 0o755);
    defer _ = pfs.rmdir(dir.ptr);
    var link_buf: [600]u8 = undefined;
    const linkz = try std.fmt.bufPrint(&link_buf, "{s}/esc.txt\x00", .{dir});
    const link = linkz[0 .. linkz.len - 1];
    pfs.unlinkPath(@ptrCast(linkz.ptr)) catch {};
    if (std.c.symlink("/etc/hosts", @ptrCast(linkz.ptr)) != 0) return error.SkipZigTest;
    defer pfs.unlinkPath(@ptrCast(linkz.ptr)) catch {};

    // dir 为唯一工作目录:link 词法在内,但 realpath 指向 /etc/hosts(集外)→ 拒
    const mctx = MatchContext{ .cwd = dir };
    try testing.expect(!isInWorkingDirs(&mctx, link));
    // 对照:dir 内真实文件放行(不存在的普通路径,realpath 失败走词法)
    var f_buf: [160]u8 = undefined;
    const f = try std.fmt.bufPrint(&f_buf, "{s}/normal.txt", .{dir});
    try testing.expect(isInWorkingDirs(&mctx, f));
}

test "extractPath: notebook_path 也可提取(NotebookEdit protected/scope 门用)" {
    try testing.expectEqualStrings(
        "/x/n.ipynb",
        extractPath("{\"notebook_path\":\"/x/n.ipynb\",\"new_source\":\"y\"}"),
    );
}

test "foldLexicalRel: 绝对 + 相对 + 前导 .. 保留 + 全消光" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // 绝对
    try testing.expectEqualStrings("/a/b", foldLexicalRel(&buf, "/a/b").?);
    try testing.expectEqualStrings("/etc/passwd", foldLexicalRel(&buf, "/proj/../etc/passwd").?);
    try testing.expectEqualStrings("/etc", foldLexicalRel(&buf, "/proj/../../etc").?); // 根 clamp
    try testing.expectEqualStrings("/", foldLexicalRel(&buf, "/..").?);
    // 相对:.. 抵消 + 无法抵消的前导 .. 保留
    try testing.expectEqualStrings("etc/passwd", foldLexicalRel(&buf, "src/../etc/passwd").?);
    try testing.expectEqualStrings("../etc/passwd", foldLexicalRel(&buf, "src/../../etc/passwd").?);
    try testing.expectEqualStrings("../../x", foldLexicalRel(&buf, "../../x").?);
    try testing.expectEqualStrings("a/b", foldLexicalRel(&buf, "a/./b").?);
    try testing.expectEqualStrings("a/b", foldLexicalRel(&buf, "a//b/").?);
    // 全消光
    try testing.expectEqualStrings(".", foldLexicalRel(&buf, "a/..").?);
    try testing.expectEqualStrings(".", foldLexicalRel(&buf, ".").?);
    // 空 → null
    try testing.expect(foldLexicalRel(&buf, "") == null);
}

test "P1 修复: 绝对锚 //etc/** deny 规则不再 fail-open(实际匹配 /etc/passwd)" {
    // 修复前:glob=/etc/**(留前导 /)vs rel=etc/passwd → 恒不匹配 → deny 静默失效。
    const r = try parseRule("Edit(//etc/**)");
    try testing.expect(r.spec.path_pattern.anchor == .absolute);
    try testing.expectEqualStrings("etc/**", r.spec.path_pattern.glob); // 剥两个前导 /

    const mctx = MatchContext{ .cwd = "/proj", .project_root = "/proj" };
    var abuf: [256]u8 = undefined;
    // /etc/passwd 命中 → deny 模式真触发(修复前 false=fail-open)
    const args = try std.fmt.bufPrint(&abuf, "{{\"file_path\":\"/etc/passwd\"}}", .{});
    try testing.expect(matchesMode(&r, &mctx, "Edit", args, .deny));
    // 非 /etc 路径不误伤
    const args2 = try std.fmt.bufPrint(&abuf, "{{\"file_path\":\"/proj/src/a.zig\"}}", .{});
    try testing.expect(!matchesMode(&r, &mctx, "Edit", args2, .deny));
}

test "Windows: normalizeLexical 盘符/反斜杠/大小写规范化" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("D:/a/b", normalizeLexical(&buf, "d:\\a\\.\\c\\..\\b").?);
    try testing.expectEqualStrings("C:/", normalizeLexical(&buf, "C:\\").?);
    try testing.expectEqualStrings("C:/", normalizeLexical(&buf, "C:/x/../..").?); // 盘符根 clamp
    try testing.expect(normalizeLexical(&buf, "C:foo") == null); // 盘符相对拒绝
    try testing.expectEqualStrings("/tmp/x", normalizeLexical(&buf, "/tmp//x/.").?); // POSIX 形原语义
}

test "Windows: 盘符绝对路径规则命中(cwd 锚 + 绝对锚 + 大小写不敏感)" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    // cwd 锚:allow Write(./src/**),cwd=D:\proj → D:/proj/src 命中(分隔符/大小写混用)
    {
        const r = try parseRule("Write(./src/**)");
        const mctx = MatchContext{ .cwd = "D:\\proj", .project_root = "D:\\proj" };
        var abuf: [256]u8 = undefined;
        const args = try std.fmt.bufPrint(&abuf, "{{\"file_path\":\"D:/proj/src/a.zig\"}}", .{});
        try testing.expect(matchesMode(&r, &mctx, "Write", args, .allow));
        const args_case = try std.fmt.bufPrint(&abuf, "{{\"file_path\":\"d:/PROJ/src/b.zig\"}}", .{});
        try testing.expect(matchesMode(&r, &mctx, "Write", args_case, .allow));
        const args_out = try std.fmt.bufPrint(&abuf, "{{\"file_path\":\"D:/other/src/c.zig\"}}", .{});
        try testing.expect(!matchesMode(&r, &mctx, "Write", args_out, .allow));
    }
    // 绝对锚:deny //Users/x/** → 任意盘符根下的 Users/x 命中(盘符根即文件系统根)
    {
        const r = try parseRule("Write(//Users/x/**)");
        const mctx = MatchContext{ .cwd = "D:\\proj", .project_root = "D:\\proj" };
        var abuf: [256]u8 = undefined;
        const args = try std.fmt.bufPrint(&abuf, "{{\"file_path\":\"C:/Users/x/key.pem\"}}", .{});
        try testing.expect(matchesMode(&r, &mctx, "Write", args, .deny));
    }
}

test "P1 修复: 绝对锚 allow //Users/x/secrets/** 命中" {
    const r = try parseRule("Write(//Users/x/secrets/**)");
    try testing.expectEqualStrings("Users/x/secrets/**", r.spec.path_pattern.glob);
    const mctx = MatchContext{ .cwd = "/proj", .project_root = "/proj" };
    var abuf: [256]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"file_path\":\"/Users/x/secrets/key.pem\"}}", .{});
    try testing.expect(matchesMode(&r, &mctx, "Write", args, .allow));
    // project 内不误命中绝对锚 /Users 规则
    const args2 = try std.fmt.bufPrint(&abuf, "{{\"file_path\":\"/proj/Users/x/secrets/k\"}}", .{});
    try testing.expect(!matchesMode(&r, &mctx, "Write", args2, .allow));
}
