//! Tool(specifier) 规则字符串解析 + 匹配。
//!
//! 完整对齐 Claude Code 规则语法,详见 doc/PERMISSION_DESIGN.md 第四节。
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
        return .{ .anchor = .absolute, .glob = raw[1..] }; // 留单个 / 让 glob 自然匹配
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
};

pub fn matches(spec: *const RuleSpec, mctx: *const MatchContext, tool_name: []const u8, args: []const u8) bool {
    return matchesMode(spec, mctx, tool_name, args, .deny);
}

/// 规则的 allow/deny 语义影响 symlink 处理(对齐 PERMISSION_DESIGN §4.3):
///   allow:路径规则要求 [原路径] 和 [realpath 解析后] **都**匹配(指向区外的链接也 prompt)
///   deny :路径规则 [原路径] 或 [realpath] **任一**匹配即触发(指向 denied 文件的链接也 deny)
/// 非路径规则不受影响。
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
        .bash_pattern => |pat| matchesBashCompound(pat, extractCommand(args)),
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
fn matchesPathDual(pp: PathPattern, mctx: *const MatchContext, file_path: []const u8, mode: RuleMode) bool {
    const orig_match = matchesPathPattern(pp, mctx, file_path);

    // 尝试 realpath 解析
    var rp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = realpathZ(&rp_buf, file_path);

    if (resolved == null or std.mem.eql(u8, resolved.?, file_path)) {
        // 无链接 / 解析失败:单路径语义
        return orig_match;
    }
    const target_match = matchesPathPattern(pp, mctx, resolved.?);

    return switch (mode) {
        .allow => orig_match and target_match, // 双匹配才放行
        .deny, .ask => orig_match or target_match, // 任一匹配即触发
    };
}

/// realpath(file_path) 写入 buf,返回 slice。失败返 null。
fn realpathZ(buf: []u8, file_path: []const u8) ?[]const u8 {
    var pz: [std.fs.max_path_bytes]u8 = undefined;
    if (file_path.len + 1 > pz.len) return null;
    @memcpy(pz[0..file_path.len], file_path);
    pz[file_path.len] = 0;
    var out: [std.fs.max_path_bytes]u8 = undefined;
    const res = std.c.realpath(@ptrCast(&pz), &out);
    if (res == null) return null;
    const resolved = std.mem.span(@as([*:0]u8, @ptrCast(res.?)));
    if (resolved.len > buf.len) return null;
    @memcpy(buf[0..resolved.len], resolved);
    return buf[0..resolved.len];
}

/// 复合 Bash 命令(allow 规则语义):每个子命令(strip wrappers 后)都得被 pattern 匹中。
/// 任一段没匹中 → 整体不匹中(因为放行 = 必须每段都允许)。
fn matchesBashCompound(pattern: []const u8, full_cmd: []const u8) bool {
    const bp = @import("bash_parser.zig");
    // 单段优化:无 compound 分隔符直接走老路径
    if (!hasCompoundSep(full_cmd)) {
        return matchesBashPattern(pattern, bp.stripWrappers(full_cmd));
    }
    // 拆 + 逐段判定
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const segs = bp.splitCompound(arena.allocator(), full_cmd) catch return false;
    if (segs.len == 0) return false;
    for (segs) |seg| {
        const real = bp.stripWrappers(seg);
        if (!matchesBashPattern(pattern, real)) return false;
    }
    return true;
}

fn hasCompoundSep(s: []const u8) bool {
    var in_s = false;
    var in_d = false;
    var in_b = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (!in_d and !in_b and c == '\'') { in_s = !in_s; continue; }
        if (!in_s and !in_b and c == '"')  { in_d = !in_d; continue; }
        if (!in_s and !in_d and c == '`')  { in_b = !in_b; continue; }
        if (in_s or in_d or in_b) continue;
        if (c == '\\' and i + 1 < s.len) { i += 1; continue; }
        if (c == ';' or c == '\n' or c == '|') return true;
        if (c == '&') {
            if (i + 1 < s.len and s[i + 1] == '&') return true;
            return true; // 单 & 也算后台分隔
        }
    }
    return false;
}

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
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = resolveAbs(&abs_buf, file_path_in, mctx) orelse return false;

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = anchorBase(&base_buf, pp.anchor, mctx) orelse return false;

    if (!std.mem.startsWith(u8, abs, base)) return false;

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

fn anchorBase(buf: []u8, anchor: PathAnchor, mctx: *const MatchContext) ?[]const u8 {
    _ = buf; // 暂未用 buf
    return switch (anchor) {
        .absolute => "/",
        .home => mctx.home,
        .project => mctx.project_root,
        .cwd => mctx.cwd,
    };
}

fn resolveAbs(buf: []u8, path: []const u8, mctx: *const MatchContext) ?[]const u8 {
    if (path.len == 0) return null;
    if (path[0] == '/') return path; // 已是绝对
    if (std.mem.startsWith(u8, path, "~/")) {
        return joinPath(buf, mctx.home, path[2..]);
    }
    return joinPath(buf, mctx.cwd, path);
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

pub fn extractCommand(args: []const u8) []const u8 {
    return extractStringField(args, "command") orelse "";
}

pub fn extractPath(args: []const u8) []const u8 {
    return extractStringField(args, "file_path") orelse extractStringField(args, "path") orelse "";
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

test "matches: Bash compound — all segs must match" {
    const r = try parseRule("Bash(git *)");
    var mctx = MatchContext{};
    // 单段:正常
    try testing.expect(matches(&r, &mctx, "Bash", "{\"command\":\"git status\"}"));
    // 复合且全是 git:OK
    try testing.expect(matches(&r, &mctx, "Bash", "{\"command\":\"git status && git log\"}"));
    // 复合且夹了 rm:整体拒
    try testing.expect(!matches(&r, &mctx, "Bash", "{\"command\":\"git status && rm -rf /\"}"));
}

test "matches: Bash with wrapper stripped before match" {
    const r = try parseRule("Bash(npm test)");
    var mctx = MatchContext{};
    try testing.expect(matches(&r, &mctx, "Bash", "{\"command\":\"timeout 30 npm test\"}"));
    try testing.expect(matches(&r, &mctx, "Bash", "{\"command\":\"nice -n 5 npm test\"}"));
}

test "matchesMode: symlink deny triggers if target matches (任一)" {
    // 建一个真 symlink: /tmp/cczig_link_<pid> → /tmp/cczig_secret_<pid>
    const pid = std.c.getpid();
    var secret_buf: [128]u8 = undefined;
    const secret = try std.fmt.bufPrint(&secret_buf, "/tmp/cczig_secret_{d}.env\x00", .{pid});
    const secret_path = secret[0 .. secret.len - 1];
    _ = secret_path;
    var link_buf: [128]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buf, "/tmp/cczig_link_{d}.txt\x00", .{pid});
    const link_path = link[0 .. link.len - 1];

    // 创建 secret 文件
    const fd = pfs.open(@ptrCast(secret.ptr), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.SkipZigTest;
    _ = pfs.close(fd);
    defer _ = std.c.unlink(@ptrCast(secret.ptr));
    // 创建 symlink link → secret
    _ = std.c.unlink(@ptrCast(link.ptr));
    if (std.c.symlink(@ptrCast(secret.ptr), @ptrCast(link.ptr)) != 0) return error.SkipZigTest;
    defer _ = std.c.unlink(@ptrCast(link.ptr));

    // deny 规则:Read(secret 的 basename) — 裸文件名 gitignore 语义,匹配任意深度
    // 用户访问 link(basename=cczig_link_*.txt 不匹配),但 realpath 解析到 secret
    // (basename=cczig_secret_*.env 匹配)→ deny 任一即触发
    var name_buf: [64]u8 = undefined;
    const secret_name = try std.fmt.bufPrint(&name_buf, "cczig_secret_{d}.env", .{pid});
    var pat_buf: [96]u8 = undefined;
    const pat = try std.fmt.bufPrint(&pat_buf, "Read({s})", .{secret_name}); // cwd anchor 裸文件名
    const r = try parseRule(pat);
    var mctx = MatchContext{ .cwd = "/private/tmp" };

    var args_buf: [256]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"file_path\":\"{s}\"}}", .{link_path});

    // deny 模式:link basename 不匹配,但 realpath(secret) basename 匹配 → 任一即触发
    try testing.expect(matchesMode(&r, &mctx, "Read", args, .deny));
}
