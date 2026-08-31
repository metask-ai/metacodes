//! 可移植可执行文件查找（PATH 解析）。LSP server 二进制定位（`lsp/servers.zig` 的
//! `which` / `binaryAvailable`）与后续任何 "在 PATH 里找一个外部工具" 的需求共用。
//!
//! 为什么单独一层:同一件事在两平台有**三处**不兼容,少一处就整条链失效——
//! 1. **PATH 分隔符**:POSIX `:`;Windows `;`。用 `:` 切 Windows PATH 会把
//!    `C:\bin;C:\other` 切成 `C` / `\bin;C` / `\other`——每一段都不是目录,
//!    结果是"PATH 里什么都找不到",而不是报错。
//! 2. **路径拼接符**:POSIX `/`;Windows `\`。
//! 3. **可执行判定**:POSIX 是权限位(`access(X_OK)`);Windows **没有执行位**,
//!    可执行性由 `PATHEXT` 后缀名单(`.COM;.EXE;.BAT;.CMD;...`)决定。注册表里的
//!    `ServerDef.binary` 全是 `zls` / `gopls` / `clangd` 这种**无后缀**名,在 Windows
//!    上必须逐个后缀试探才可能命中 `zls.exe`。顺带:MSVCRT `_access` 根本不支持
//!    `X_OK`(mode 只认 0/2/4/6),传 1 恒返 -1 —— 即"永远判定不可执行"。
//!
//! **可测试性契约**:解析(切 PATH → 生成候选路径)与探测(碰文件系统)分离。
//! `Search` 是纯函数迭代器:喂一个合成 PATH 字符串 + 显式 `Style`,在**任何**宿主上都能
//! 断言 Windows 语义,不需要 Windows 机器、不碰环境变量、不碰磁盘。`lookupWith` 再把
//! 探测函数做成参数,于是"`C:\bin;C:\other` 里找 `zls` 命中 `C:\other\zls.exe`"
//! 这种端到端断言也能在 macOS/Linux CI 上跑。真实入口 `lookup` 才读 env + 碰磁盘。

const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("fs.zig");

const is_windows = builtin.os.tag == .windows;

/// 平台的 PATH 语义。**显式参数而非隐式 builtin**——测试要在 POSIX 宿主上断言 Windows 行为。
pub const Style = enum {
    posix,
    windows,

    /// PATH 各段之间的分隔符。
    pub fn listSeparator(self: Style) u8 {
        return switch (self) {
            .posix => ':',
            .windows => ';',
        };
    }

    /// 目录与文件名之间的分隔符。
    pub fn dirSeparator(self: Style) u8 {
        return switch (self) {
            .posix => '/',
            .windows => '\\',
        };
    }
};

/// 本机语义。
pub const host_style: Style = if (is_windows) .windows else .posix;

/// `PATHEXT` 未设时的兜底(与 cmd.exe 的内建缺省一致)。
pub const default_pathext = ".COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC";

/// 候选路径长度上限。**刻意不用 `std.fs.max_path_bytes`**:它在 Windows 上是
/// 98302(32767 宽字符 ×3),按候选在栈上开一份会把 `lookup → probe` 调用链推到
/// 几百 KB;而可执行文件路径根本没有那个量级(Windows 不开长路径支持时上限 260)。
/// 4096 = Linux `PATH_MAX`,对 POSIX 侧零行为变化;超长候选被跳过而非崩溃。
pub const max_exe_path_bytes = 4096;

/// `name` 是否已经是一个路径(而不是要去 PATH 里搜的裸名)。
/// POSIX 只看 `/`;Windows 还要认 `\` 和盘符冒号(`C:zls` 是驱动器相对路径)。
pub fn isPathLike(style: Style, name: []const u8) bool {
    return switch (style) {
        .posix => std.mem.indexOfScalar(u8, name, '/') != null,
        .windows => std.mem.indexOfAny(u8, name, "/\\:") != null,
    };
}

/// PATH 单段清洗。**只在 Windows 侧清洗**:去首尾空白 + 剥掉包裹的双引号
/// (`"C:\Program Files\x"` 是 Windows 上的合法写法,cmd/`where` 也这么处理)。
/// POSIX 侧按字节原样用——`sh` 的 PATH 查找不 trim,目录名首尾带空格是合法的,
/// 跟着 trim 会把它们变成查不到。
fn cleanDir(style: Style, raw: []const u8) []const u8 {
    if (style != .windows) return raw;
    var d = std.mem.trim(u8, raw, " \t");
    if (d.len >= 2 and d[0] == '"' and d[d.len - 1] == '"') {
        d = std.mem.trim(u8, d[1 .. d.len - 1], " \t");
    }
    return d;
}

/// 后缀是否已在 PATHEXT 名单里(大小写不敏感——Windows 文件系统如此)。
/// 命中 → 该名字**已经带了可执行后缀**,不再往后追加(否则会去找 `zls.exe.exe`)。
fn hasKnownExtension(style: Style, binary: []const u8, pathext: []const u8) bool {
    if (style != .windows) return false;
    const base = binary[lastSepIndex(style, binary)..];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return false;
    const ext = base[dot..];
    var it = std.mem.splitScalar(u8, pathext, ';');
    while (it.next()) |raw| {
        const e = std.mem.trim(u8, raw, " \t");
        if (e.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
        // PATHEXT 段允许不写前导点(非标准但见于手工设置的环境)。
        if (e[0] != '.' and ext.len == e.len + 1 and std.ascii.eqlIgnoreCase(ext[1..], e)) return true;
    }
    return false;
}

/// basename 起点(最后一个分隔符之后)。无分隔符 → 0。
fn lastSepIndex(style: Style, path: []const u8) usize {
    const idx = switch (style) {
        .posix => std.mem.lastIndexOfScalar(u8, path, '/'),
        .windows => std.mem.lastIndexOfAny(u8, path, "/\\:"),
    };
    return if (idx) |i| i + 1 else 0;
}

/// 候选可执行路径迭代器 —— **纯函数,不读 env、不碰磁盘**。
///
/// 产出顺序(每个基路径内):先按 `PATHEXT` 顺序补后缀,最后才是裸名。
/// 顺序有意义:npm 在 Windows 装出的是 `typescript-language-server.cmd` 和一个同名
/// 无后缀的 shell 脚本,先试后缀才不会返回那个 Windows 上跑不了的脚本。
///
/// 基路径来源二选一:`binary` 本身像路径 → 只有它自己一个基路径(仍要试后缀,
/// `C:\tools\zls` 得能命中 `C:\tools\zls.exe`);否则 → PATH 每一段拼上 `binary`。
pub const Search = struct {
    style: Style,
    binary: []const u8,
    pathext: []const u8,
    /// null = binary 本身是路径,不扫 PATH。
    dirs: ?std.mem.SplitIterator(u8, .scalar),
    /// 当前基路径的目录部分(指向 path_env 内部,不拥有)。null = 基路径就是 binary 自身。
    cur_dir: ?[]const u8 = null,
    /// 当前基路径的后缀游标;null = 该基路径尚未开始/已耗尽。
    exts: ?std.mem.SplitIterator(u8, .scalar) = null,
    /// 当前基路径的裸名候选是否已产出。
    bare_done: bool = true,
    /// 基路径是否已耗尽(path-like 单基路径用)。
    single_done: bool = false,
    /// binary 自带已知后缀 → 不追加,只产裸名。
    exact_only: bool,

    /// `path_env` / `pathext_env` 是**字符串参数**(不是从环境读)——这是本类型可在任意
    /// 宿主上测试 Windows 语义的全部原因。`pathext_env` 传 null 时:Windows 用
    /// `default_pathext`,POSIX 恒为空(POSIX 没有这个概念)。
    pub fn init(style: Style, binary: []const u8, path_env: []const u8, pathext_env: ?[]const u8) Search {
        const pathext: []const u8 = if (style == .windows)
            (pathext_env orelse default_pathext)
        else
            "";
        const path_like = isPathLike(style, binary);
        return .{
            .style = style,
            .binary = binary,
            .pathext = pathext,
            .dirs = if (path_like) null else std.mem.splitScalar(u8, path_env, style.listSeparator()),
            .exact_only = hasKnownExtension(style, binary, pathext),
        };
    }

    /// 下一个候选绝对/相对路径,写进 `buf`。返回 null = 候选耗尽。
    /// 超过 `buf` 的候选被跳过(不是终止)——一段病态长的 PATH 目录不该埋掉它后面的正常目录。
    pub fn next(self: *Search, buf: []u8) ?[]const u8 {
        while (true) {
            if (self.exts) |*it| {
                while (it.next()) |raw| {
                    const e = std.mem.trim(u8, raw, " \t");
                    if (e.len == 0) continue;
                    if (self.format(buf, e)) |p| return p;
                }
                self.exts = null;
            }
            if (!self.bare_done) {
                self.bare_done = true;
                if (self.format(buf, "")) |p| return p;
                continue;
            }
            if (!self.advance()) return null;
        }
    }

    /// 推进到下一个基路径。false = 没有了。
    fn advance(self: *Search) bool {
        if (self.dirs) |*it| {
            while (it.next()) |raw| {
                const d = cleanDir(self.style, raw);
                // 空段在 POSIX 上意为"当前目录"。**故意不搜 CWD**:那等于让工作目录里
                // 一个叫 `zls` 的文件劫持 language server 启动(经典 PATH 注入面)。
                if (d.len == 0) continue;
                self.cur_dir = d;
                self.startBase();
                return true;
            }
            return false;
        }
        if (self.single_done) return false;
        self.single_done = true;
        self.cur_dir = null;
        self.startBase();
        return true;
    }

    fn startBase(self: *Search) void {
        if (self.exact_only) {
            self.exts = null;
            self.bare_done = false; // 只产裸名(binary 已带已知后缀)
        } else {
            self.exts = if (self.pathext.len > 0) std.mem.splitScalar(u8, self.pathext, ';') else null;
            self.bare_done = false;
        }
    }

    /// 基路径 + 后缀 → buf。放不下 → null(调用方跳过该候选)。
    fn format(self: *const Search, buf: []u8, ext: []const u8) ?[]const u8 {
        var n: usize = 0;
        if (self.cur_dir) |d| {
            if (d.len > buf.len) return null;
            @memcpy(buf[0..d.len], d);
            n = d.len;
            // 目录已自带尾分隔符(`C:\` / `/usr/bin/`)就别再补一个。
            const tail = d[d.len - 1];
            if (tail != '/' and !(self.style == .windows and tail == '\\')) {
                if (n + 1 > buf.len) return null;
                buf[n] = self.style.dirSeparator();
                n += 1;
            }
        }
        if (n + self.binary.len > buf.len) return null;
        @memcpy(buf[n..][0..self.binary.len], self.binary);
        n += self.binary.len;
        if (ext.len > 0) {
            // PATHEXT 段允许不写前导点。
            const need_dot = ext[0] != '.';
            const total = n + ext.len + @intFromBool(need_dot);
            if (total > buf.len) return null;
            if (need_dot) {
                buf[n] = '.';
                n += 1;
            }
            @memcpy(buf[n..][0..ext.len], ext);
            n += ext.len;
        }
        return buf[0..n];
    }
};

/// 探测谓词:该路径是否是一个可执行文件。测试注入假实现,生产用 `realProbe`。
pub const Probe = *const fn (ctx: ?*anyopaque, path: []const u8) bool;

/// 真实文件系统探测。
/// - POSIX:`access(X_OK)`(跟随 symlink——PATH 里的 `zls` 常是软链)**且不是目录**。
///   裸 `access(X_OK)` 对可搜索目录也返 0,会把目录当成 server 二进制交给 spawn。
/// - Windows:文件存在且不是目录即可(没有执行位;可执行性由后缀决定,后缀已在候选生成阶段管了)。
pub fn realProbe(_: ?*anyopaque, path: []const u8) bool {
    var buf: [max_exe_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return false;
    // `else` 而非顺序两段:`is_windows` 是 comptime 已知的,写成 else 才能让 Zig **不分析**
    // 未选中的那支 —— 否则 `std.c.access`(POSIX 符号)会被 windows-msvc 链接阶段要求解析。
    if (is_windows) {
        return pfs.isExistingNonDir(z.ptr);
    } else {
        if (std.c.access(z.ptr, 1) != 0) return false; // X_OK = 1
        return pfs.isExistingNonDir(z.ptr);
    }
}

/// 全参数版查找:样式 / PATH / PATHEXT / 探测函数全部显式。**任何宿主可跑 Windows 语义**。
/// 命中 → 路径写进 `out_buf` 返回;未命中或 `out_buf` 装不下 → null。
pub fn lookupWith(
    style: Style,
    binary: []const u8,
    path_env: []const u8,
    pathext_env: ?[]const u8,
    probe: Probe,
    probe_ctx: ?*anyopaque,
    out_buf: []u8,
) ?[]const u8 {
    if (binary.len == 0) return null;
    var search = Search.init(style, binary, path_env, pathext_env);
    var buf: [max_exe_path_bytes]u8 = undefined;
    while (search.next(&buf)) |cand| {
        if (!probe(probe_ctx, cand)) continue;
        if (cand.len > out_buf.len) return null;
        @memcpy(out_buf[0..cand.len], cand);
        return out_buf[0..cand.len];
    }
    return null;
}

/// 生产入口:本机样式 + 真 `PATH`/`PATHEXT` + 真文件系统。
pub fn lookup(binary: []const u8, out_buf: []u8) ?[]const u8 {
    // `PATH` 未设 → 空串,**不是** early-return:`binary` 本身是路径时根本不看 PATH,
    // 早退会把 `which("/bin/sh")` 在无 PATH 的环境里判成"找不到"。
    const path_env = envSpan("PATH") orelse "";
    const pathext_env = if (is_windows) envSpan("PATHEXT") else null;
    return lookupWith(host_style, binary, path_env, pathext_env, realProbe, null, out_buf);
}

fn envSpan(comptime name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len > 0) s else null;
}

// ============================================================================
// Tests —— 解析侧全部是纯函数,**在任何宿主上都跑**(含 Windows CI 的 test:platform)。
// 这正是本模块存在的意义:Windows 语义不该只能在 Windows 上被验证。
// ============================================================================

const testing = std.testing;

/// 把 Search 的全部候选收集成一个列表,便于逐项断言。
fn collect(alloc: std.mem.Allocator, style: Style, binary: []const u8, path_env: []const u8, pathext: ?[]const u8) ![][]u8 {
    var out = std.ArrayList([]u8).empty;
    errdefer {
        for (out.items) |i| alloc.free(i);
        out.deinit(alloc);
    }
    var s = Search.init(style, binary, path_env, pathext);
    var buf: [max_exe_path_bytes]u8 = undefined;
    while (s.next(&buf)) |c| try out.append(alloc, try alloc.dupe(u8, c));
    return out.toOwnedSlice(alloc);
}

fn freeAll(alloc: std.mem.Allocator, items: [][]u8) void {
    for (items) |i| alloc.free(i);
    alloc.free(items);
}

test "Style: 分隔符两平台不同(三条差异的第 1、2 条)" {
    try testing.expectEqual(@as(u8, ':'), Style.posix.listSeparator());
    try testing.expectEqual(@as(u8, ';'), Style.windows.listSeparator());
    try testing.expectEqual(@as(u8, '/'), Style.posix.dirSeparator());
    try testing.expectEqual(@as(u8, '\\'), Style.windows.dirSeparator());
}

test "REGRESSION: Windows PATH 按 ':' 切会碎成 C / \\bin;C / \\other" {
    const a = testing.allocator;
    // 这是缺陷本体:同一个字符串,用错样式切出来的每一段都不是目录。
    var wrong = std.mem.splitScalar(u8, "C:\\bin;C:\\other", ':');
    try testing.expectEqualStrings("C", wrong.next().?);
    try testing.expectEqualStrings("\\bin;C", wrong.next().?);
    try testing.expectEqualStrings("\\other", wrong.next().?);
    try testing.expect(wrong.next() == null);

    // 正确样式:两段完整目录,各自拼出带盘符的候选。
    const got = try collect(a, .windows, "zls", "C:\\bin;C:\\other", ".EXE");
    defer freeAll(a, got);
    try testing.expectEqual(@as(usize, 4), got.len); // 2 目录 × (.EXE + 裸名)
    try testing.expectEqualStrings("C:\\bin\\zls.EXE", got[0]);
    try testing.expectEqualStrings("C:\\bin\\zls", got[1]);
    try testing.expectEqualStrings("C:\\other\\zls.EXE", got[2]);
    try testing.expectEqualStrings("C:\\other\\zls", got[3]);
}

test "POSIX 候选:':' 切、'/' 拼、无后缀试探" {
    const a = testing.allocator;
    const got = try collect(a, .posix, "zls", "/usr/bin:/opt/homebrew/bin", null);
    defer freeAll(a, got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("/usr/bin/zls", got[0]);
    try testing.expectEqualStrings("/opt/homebrew/bin/zls", got[1]);
}

test "Windows PATHEXT:按名单顺序补后缀,裸名垫底" {
    const a = testing.allocator;
    const got = try collect(a, .windows, "gopls", "C:\\bin", ".COM;.EXE;.CMD");
    defer freeAll(a, got);
    try testing.expectEqual(@as(usize, 4), got.len);
    try testing.expectEqualStrings("C:\\bin\\gopls.COM", got[0]);
    try testing.expectEqualStrings("C:\\bin\\gopls.EXE", got[1]);
    try testing.expectEqualStrings("C:\\bin\\gopls.CMD", got[2]);
    // 裸名最后:npm 装出的无后缀 shell 脚本不该盖过同名 .CMD。
    try testing.expectEqualStrings("C:\\bin\\gopls", got[3]);
}

test "Windows PATHEXT 缺省:未传 → cmd.exe 内建名单" {
    const a = testing.allocator;
    const got = try collect(a, .windows, "clangd", "C:\\bin", null);
    defer freeAll(a, got);
    try testing.expect(got.len > 4);
    try testing.expectEqualStrings("C:\\bin\\clangd.COM", got[0]);
    try testing.expectEqualStrings("C:\\bin\\clangd.EXE", got[1]);
    try testing.expectEqualStrings("C:\\bin\\clangd", got[got.len - 1]);
}

test "Windows:binary 已带 PATHEXT 内后缀 → 不再追加(不去找 zls.exe.exe)" {
    const a = testing.allocator;
    const got = try collect(a, .windows, "zls.exe", "C:\\bin;D:\\tools", ".COM;.EXE");
    defer freeAll(a, got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("C:\\bin\\zls.exe", got[0]);
    try testing.expectEqualStrings("D:\\tools\\zls.exe", got[1]);
}

test "Windows:后缀比对大小写不敏感" {
    try testing.expect(hasKnownExtension(.windows, "zls.EXE", ".exe;.cmd"));
    try testing.expect(hasKnownExtension(.windows, "zls.exe", ".COM;.EXE"));
    try testing.expect(!hasKnownExtension(.windows, "rust-analyzer", ".COM;.EXE"));
    // POSIX 不认这个概念。
    try testing.expect(!hasKnownExtension(.posix, "zls.exe", ".EXE"));
}

test "Windows:PATHEXT 段可不带前导点" {
    const a = testing.allocator;
    const got = try collect(a, .windows, "zls", "C:\\bin", "EXE;CMD");
    defer freeAll(a, got);
    try testing.expectEqualStrings("C:\\bin\\zls.EXE", got[0]);
    try testing.expectEqualStrings("C:\\bin\\zls.CMD", got[1]);
    // 且此时 `zls.EXE` 仍应被认成"已带已知后缀"。
    try testing.expect(hasKnownExtension(.windows, "zls.exe", "EXE;CMD"));
}

test "isPathLike:Windows 认 \\ 和盘符冒号,POSIX 只认 /" {
    try testing.expect(isPathLike(.posix, "/bin/sh"));
    try testing.expect(!isPathLike(.posix, "sh"));
    // POSIX 上反斜杠是普通字符,不是路径分隔符。
    try testing.expect(!isPathLike(.posix, "C:\\bin\\zls.exe"));
    try testing.expect(isPathLike(.windows, "C:\\bin\\zls.exe"));
    try testing.expect(isPathLike(.windows, "C:zls")); // 驱动器相对
    try testing.expect(isPathLike(.windows, "tools/zls")); // Windows 也吃正斜杠
    try testing.expect(!isPathLike(.windows, "zls"));
}

test "binary 本身是路径:不扫 PATH,但仍试后缀" {
    const a = testing.allocator;
    // POSIX:原样一条。
    const p = try collect(a, .posix, "/usr/local/bin/zls", "/usr/bin", null);
    defer freeAll(a, p);
    try testing.expectEqual(@as(usize, 1), p.len);
    try testing.expectEqualStrings("/usr/local/bin/zls", p[0]);

    // Windows:PATH 被忽略,但无后缀的路径仍要试探 —— C:\tools\zls 得能命中 C:\tools\zls.exe。
    const w = try collect(a, .windows, "C:\\tools\\zls", "C:\\bin", ".EXE;.CMD");
    defer freeAll(a, w);
    try testing.expectEqual(@as(usize, 3), w.len);
    try testing.expectEqualStrings("C:\\tools\\zls.EXE", w[0]);
    try testing.expectEqualStrings("C:\\tools\\zls.CMD", w[1]);
    try testing.expectEqualStrings("C:\\tools\\zls", w[2]);
}

test "PATH 段清洗:空段跳过(不搜 CWD)、Windows 剥引号、尾分隔符不重复" {
    const a = testing.allocator;
    // 空段:POSIX 规范里意为 CWD,这里故意不搜(PATH 注入面)。
    const p = try collect(a, .posix, "zls", "/a::/b:", null);
    defer freeAll(a, p);
    try testing.expectEqual(@as(usize, 2), p.len);
    try testing.expectEqualStrings("/a/zls", p[0]);
    try testing.expectEqualStrings("/b/zls", p[1]);

    // Windows:带引号的段(含空格的 Program Files 路径常这么写)+ 尾反斜杠。
    const w = try collect(a, .windows, "zls", "\"C:\\Program Files\\LSP\";C:\\bin\\", ".EXE");
    defer freeAll(a, w);
    try testing.expectEqualStrings("C:\\Program Files\\LSP\\zls.EXE", w[0]);
    try testing.expectEqualStrings("C:\\bin\\zls.EXE", w[2]);

    // POSIX 尾斜杠同理不重复。
    const p2 = try collect(a, .posix, "zls", "/usr/bin/", null);
    defer freeAll(a, p2);
    try testing.expectEqualStrings("/usr/bin/zls", p2[0]);
}

test "POSIX 段不做空白清洗(目录名首尾空格是合法的)" {
    const a = testing.allocator;
    const p = try collect(a, .posix, "zls", "/has space :/b", null);
    defer freeAll(a, p);
    // 段是 `/has space ` —— 尾部空格属于目录名,trim 掉就查不到了。
    try testing.expectEqualStrings("/has space /zls", p[0]);
    try testing.expectEqualStrings("/b/zls", p[1]);
}

test "候选超 buf 被跳过,不终止后续目录" {
    // 第一段目录长到放不下 → 该候选被跳过,第二段仍须产出。
    var long: [max_exe_path_bytes]u8 = undefined;
    @memset(&long, 'x');
    long[0] = '/';
    var path_buf: [max_exe_path_bytes + 16]u8 = undefined;
    const path_env = std.fmt.bufPrint(&path_buf, "{s}:/b", .{long[0..]}) catch unreachable;

    var s = Search.init(.posix, "zls", path_env, null);
    var buf: [max_exe_path_bytes]u8 = undefined;
    const first = s.next(&buf);
    try testing.expect(first != null);
    try testing.expectEqualStrings("/b/zls", first.?);
    try testing.expect(s.next(&buf) == null);
}

// ── lookupWith:注入假文件系统,端到端解析在任何宿主上可断言 ──────────────────

const FakeFs = struct {
    files: []const []const u8,
    /// Windows 文件系统大小写不敏感 —— 候选带的是 PATHEXT 的写法(`.EXE`),磁盘上可能是
    /// `.exe`。假文件系统必须照抄这个语义,否则测出来的是假失败。
    ignore_case: bool = false,
    fn probe(ctx: ?*anyopaque, path: []const u8) bool {
        const self: *const FakeFs = @ptrCast(@alignCast(ctx.?));
        for (self.files) |f| {
            const hit = if (self.ignore_case)
                std.ascii.eqlIgnoreCase(f, path)
            else
                std.mem.eql(u8, f, path);
            if (hit) return true;
        }
        return false;
    }
};

test "lookupWith(windows):C:\\bin;C:\\other 里命中第二段的 zls.exe" {
    var fs = FakeFs{ .files = &.{"C:\\other\\zls.exe"}, .ignore_case = true };
    var out: [max_exe_path_bytes]u8 = undefined;
    const got = lookupWith(.windows, "zls", "C:\\bin;C:\\other", ".COM;.EXE", FakeFs.probe, &fs, &out);
    try testing.expect(got != null);
    // 返回的是**候选**的写法(后缀来自 PATHEXT),不是磁盘上的写法——Windows 路径大小写
    // 不敏感,CreateProcess 照样打得开,故断言也按大小写不敏感比。
    try testing.expect(std.ascii.eqlIgnoreCase("C:\\other\\zls.exe", got.?));
}

test "lookupWith(windows):同目录 .cmd 与无后缀脚本并存 → 取 .cmd" {
    // npm 在 Windows 上装 typescript-language-server 就是这个形态。
    var fs = FakeFs{ .files = &.{
        "C:\\npm\\typescript-language-server",
        "C:\\npm\\typescript-language-server.cmd",
    }, .ignore_case = true };
    var out: [max_exe_path_bytes]u8 = undefined;
    const got = lookupWith(.windows, "typescript-language-server", "C:\\npm", ".EXE;.CMD", FakeFs.probe, &fs, &out);
    try testing.expect(std.ascii.eqlIgnoreCase("C:\\npm\\typescript-language-server.cmd", got.?));
}

test "lookupWith(windows):PATH 里没有 → null(而不是把 PATH 切碎后误判)" {
    var fs = FakeFs{ .files = &.{"C:\\bin\\other.exe"}, .ignore_case = true };
    var out: [max_exe_path_bytes]u8 = undefined;
    try testing.expect(lookupWith(.windows, "zls", "C:\\bin;C:\\other", ".EXE", FakeFs.probe, &fs, &out) == null);
}

test "lookupWith(posix):第一段命中优先于第二段" {
    var fs = FakeFs{ .files = &.{ "/opt/bin/zls", "/usr/bin/zls" } };
    var out: [max_exe_path_bytes]u8 = undefined;
    const got = lookupWith(.posix, "zls", "/usr/bin:/opt/bin", null, FakeFs.probe, &fs, &out);
    try testing.expectEqualStrings("/usr/bin/zls", got.?);
}

test "lookupWith:空 binary → null(不去 stat 每个 PATH 目录本身)" {
    var fs = FakeFs{ .files = &.{"/usr/bin"} };
    var out: [max_exe_path_bytes]u8 = undefined;
    try testing.expect(lookupWith(.posix, "", "/usr/bin", null, FakeFs.probe, &fs, &out) == null);
}

test "lookupWith:out_buf 装不下命中路径 → null(不截断)" {
    var fs = FakeFs{ .files = &.{"/usr/bin/zls"} };
    var out: [4]u8 = undefined;
    try testing.expect(lookupWith(.posix, "zls", "/usr/bin", null, FakeFs.probe, &fs, &out) == null);
}

test "REGRESSION:PATH 为空时,路径形态的 binary 仍要能解析" {
    // 旧 `which` 先处理"含 `/` 的路径",再读 PATH;下沉时若把"读 PATH 失败"提到最前面
    // early-return,`ServerDef.binary` 写绝对路径的那种配置在无 PATH 环境里会集体判为未安装。
    var fs = FakeFs{ .files = &.{"/opt/langservers/zls"} };
    var out: [max_exe_path_bytes]u8 = undefined;
    const got = lookupWith(.posix, "/opt/langservers/zls", "", null, FakeFs.probe, &fs, &out);
    try testing.expectEqualStrings("/opt/langservers/zls", got.?);
    // 裸名 + 空 PATH → 确实无处可找。
    try testing.expect(lookupWith(.posix, "zls", "", null, FakeFs.probe, &fs, &out) == null);
}

// ── 真机行为:两平台各断言一个必然存在的系统可执行文件 ────────────────────────

test "lookup:本机 PATH 能找到系统自带可执行文件" {
    var buf: [max_exe_path_bytes]u8 = undefined;
    if (is_windows) {
        // Windows 上 cmd 只有靠 PATHEXT 才找得到(PATH 里是 cmd.exe,查的是 cmd)。
        // 这条一旦回归成 null,就说明 ';' 切分或 PATHEXT 试探又坏了。
        const cmd = lookup("cmd", &buf) orelse return error.CmdNotFoundInPath;
        try testing.expect(std.ascii.endsWithIgnoreCase(cmd, "cmd.exe"));
    } else {
        const sh = lookup("sh", &buf) orelse return error.ShNotFoundInPath;
        try testing.expect(std.mem.endsWith(u8, sh, "/sh"));
    }
}

test "lookup:瞎名找不到" {
    var buf: [max_exe_path_bytes]u8 = undefined;
    try testing.expect(lookup("no-such-binary-xyz-9417", &buf) == null);
}

test "realProbe:目录不算可执行文件" {
    // POSIX 上可搜索目录的 access(X_OK) 返 0 —— 裸 access 会把目录当二进制交给 spawn。
    const dir: []const u8 = if (is_windows) "C:\\Windows" else "/usr/bin";
    try testing.expect(!realProbe(null, dir));
}
