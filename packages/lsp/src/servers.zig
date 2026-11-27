//! LSP server 注册表(对齐 hermes servers.py,精简到核心语言):按扩展名选 server + 每语言的
//! spawn 命令 / root markers / excludes。二进制经 PATH 解析(which);解析不到 → 该语言不启动。
//!
//! v1 覆盖:zig(zls)/python(pyright)/typescript+tsx+js+jsx(typescript-language-server)/
//! go(gopls)/rust(rust-analyzer)/c+cpp(clangd)。加语言只在 SERVERS 表加一行。
const std = @import("std");
const workspace = @import("workspace.zig");
const exe_lookup = @import("platform").exe_lookup;

pub const ServerDef = struct {
    server_id: []const u8,
    extensions: []const []const u8, // 含点,如 ".zig"
    binary: []const u8, // PATH 里的可执行名(如 "pyright-langserver")
    args: []const []const u8 = &.{}, // binary 之后的固定参数(如 "--stdio")
    root_markers: []const []const u8, // 定位 server root 的标记文件(如 "go.mod")
    root_excludes: []const []const u8 = &.{}, // 命中则该 server 在此不启动(如 ts 见 "deno.json")
    seed_first_push: bool = false, // TS 系:首个 publishDiagnostics 只存不 signal
};

pub const SERVERS = [_]ServerDef{
    .{
        .server_id = "zls",
        .extensions = &.{".zig"},
        .binary = "zls",
        .root_markers = &.{ "build.zig", "build.zig.zon" },
    },
    .{
        .server_id = "pyright",
        .extensions = &.{ ".py", ".pyi" },
        .binary = "pyright-langserver",
        .args = &.{"--stdio"},
        .root_markers = &.{ "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "pyrightconfig.json" },
    },
    .{
        .server_id = "typescript",
        .extensions = &.{ ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs" },
        .binary = "typescript-language-server",
        .args = &.{"--stdio"},
        .root_markers = &.{ "tsconfig.json", "jsconfig.json", "package.json" },
        .root_excludes = &.{ "deno.json", "deno.jsonc" }, // deno 项目不用 tsserver
        .seed_first_push = true,
    },
    .{
        .server_id = "gopls",
        .extensions = &.{".go"},
        .binary = "gopls",
        .root_markers = &.{ "go.mod", "go.work" },
    },
    .{
        .server_id = "rust-analyzer",
        .extensions = &.{".rs"},
        .binary = "rust-analyzer",
        .root_markers = &.{"Cargo.toml"},
    },
    .{
        .server_id = "clangd",
        .extensions = &.{ ".c", ".h", ".cpp", ".cc", ".hpp", ".cxx" },
        .binary = "clangd",
        .args = &.{ "--background-index", "--clang-tidy" },
        .root_markers = &.{ "compile_commands.json", "compile_flags.txt", ".clangd", "Makefile", "CMakeLists.txt" },
    },
};

/// 按文件扩展名选 server。无匹配 → null。
pub fn findServerForFile(path: []const u8) ?*const ServerDef {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    const ext = base[dot..]; // 含点
    for (&SERVERS) |*s| {
        for (s.extensions) |e| {
            if (std.ascii.eqlIgnoreCase(ext, e)) return s;
        }
    }
    return null;
}

/// 在 PATH 里找可执行 `binary`,写路径进 `out_buf` 返回;找不到 → null。
///
/// 平台差异(分隔符 `:` / `;`、拼接符 `/` / `\`、Windows 的 `PATHEXT` 后缀试探)全部下沉到
/// `platform.exe_lookup` —— 那里的解析是纯函数,可在任何宿主上按 Windows 语义断言。
/// 本函数只剩"用本机语义查一次"这一件事。
///
/// 历史(已修):此处曾硬编码 POSIX 三件套(`:` 切 / `/` 拼 / `access(X_OK)`)。在 Windows 上
/// `C:\bin;C:\other` 会被切成 `C` / `\bin;C` / `\other`,且注册表里 `zls`/`gopls`/`clangd`
/// 这类**无后缀**名永远命不中 `zls.exe` —— 结果是 `Service.getOrSpawn` 起不了任何 server、
/// `binaryAvailable` 对每种语言都报"未安装"。回归防线见 `platform/exe_lookup.zig` 的
/// "REGRESSION: Windows PATH 按 ':' 切会碎成 …"。
pub fn which(binary: []const u8, out_buf: []u8) ?[]const u8 {
    return exe_lookup.lookup(binary, out_buf);
}

/// def 的 language server 二进制**此刻是否真的可用**(PATH 可解析,或 binary 含 `/` 时该路径可执行)。
///
/// **注册表命中 ≠ 能力可用**(issue #17):`SERVERS` 是编译期静态表,`binary` 是运行期外部进程。
/// 判定"这个文件能不能出符号"必须同时过这一关,否则 `.py` 在没装 pyright 的机器上会被判成
/// "有能力",最终以裸空结果收场、被读成"查无定义"。
///
/// 成本 = 一次 PATH 扫描(POSIX 每段目录一次 `access(2)`;Windows 是每段 × 每个 PATHEXT
/// 后缀一次 `GetFileAttributesW`,更贵)。**实测不便宜**:PATH 30 段时单次 36µs
/// (命中)/ 43µs(未命中,要扫完整个 PATH 才放弃)。对"随后就要做一次 LSP 往返"的文件可以忽略,
/// 但对**被门禁挡掉、此外什么都不做**的文件就是纯浪费——FindSymbol 的候选上限量级 3200 个文件
/// × 36µs ≈ 116ms,而答案至多只有 7 种。
///
/// 因此:**不做进程级缓存**(那会把"跑到一半才装上 server"钉死成永久不可用,还会让测试互相
/// 污染),改由逐文件循环的调用方(FindSymbol 的候选扫描、CodeMap 的 glob 批量)各持一个
/// `symbol_provider.CapabilityCache`——生命周期只有那一次扫描。
pub fn binaryAvailable(def: *const ServerDef) bool {
    var buf: [exe_lookup.max_exe_path_bytes]u8 = undefined;
    return which(def.binary, &buf) != null;
}

/// 解析某文件的 server root(nearestRoot with markers/excludes,ceiling=git workspace root)。
/// 返回 root(写进 out_buf)或 null(无 marker / exclude 命中 → 该 server 不启动)。
pub fn resolveServerRoot(def: *const ServerDef, file_path: []const u8, git_root: ?[]const u8, out_buf: []u8) ?[]const u8 {
    const start = std.fs.path.dirname(file_path) orelse file_path;
    return workspace.nearestRoot(start, def.root_markers, def.root_excludes, git_root, out_buf) orelse
        // 无 marker:退回 git_root(hermes _root_or_workspace 行为)。
        (if (git_root) |g| blk: {
            if (g.len <= out_buf.len) {
                @memcpy(out_buf[0..g.len], g);
                break :blk out_buf[0..g.len];
            }
            break :blk null;
        } else null);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "findServerForFile: 按扩展名选 server" {
    try testing.expectEqualStrings("zls", findServerForFile("/proj/src/main.zig").?.server_id);
    try testing.expectEqualStrings("pyright", findServerForFile("/proj/app.py").?.server_id);
    try testing.expectEqualStrings("typescript", findServerForFile("/proj/x.tsx").?.server_id);
    try testing.expectEqualStrings("gopls", findServerForFile("/proj/main.go").?.server_id);
    try testing.expectEqualStrings("rust-analyzer", findServerForFile("/proj/lib.rs").?.server_id);
    try testing.expectEqualStrings("clangd", findServerForFile("/proj/x.cpp").?.server_id);
    try testing.expect(findServerForFile("/proj/README.md") == null);
    try testing.expect(findServerForFile("/proj/noext") == null);
}

test "which: 本机 PATH 能解析系统自带可执行文件,瞎名解析不到" {
    // **不 skip Windows**。解析逻辑本身(切分/拼接/PATHEXT)的断言在
    // `platform/exe_lookup.zig`,与宿主无关;这里断言的是"接线正确 + 本机真能查到",
    // 两平台各取一个必然存在的系统可执行文件即可,无须 POSIX 专属脚手架。
    var buf: [exe_lookup.max_exe_path_bytes]u8 = undefined;
    var buf2: [exe_lookup.max_exe_path_bytes]u8 = undefined;
    if (@import("builtin").os.tag == .windows) {
        // `cmd` 在 PATH 里的实体是 `cmd.exe` —— 查得到就证明 `;` 切分 + PATHEXT 后缀
        // 试探都接上了。这条一旦回归成 null,LSP 在 Windows 上就又一个 server 都起不来。
        const cmd = which("cmd", &buf) orelse return error.CmdNotFoundInPath;
        try testing.expect(std.ascii.endsWithIgnoreCase(cmd, "cmd.exe"));
        // 路径直查(带后缀,不应再被追加成 cmd.exe.exe)。
        const abs = which(cmd, &buf2) orelse return error.AbsolutePathLookupFailed;
        try testing.expect(std.ascii.eqlIgnoreCase(cmd, abs));
    } else {
        const sh = which("sh", &buf) orelse return error.ShNotFoundInPath;
        try testing.expect(std.mem.endsWith(u8, sh, "/sh"));
        // 绝对路径直查。
        try testing.expect(which("/bin/sh", &buf2) != null);
    }
    // 瞎名找不到(两平台同款)。
    var buf3: [exe_lookup.max_exe_path_bytes]u8 = undefined;
    try testing.expect(which("no-such-binary-xyz-9417", &buf3) == null);
}

test "SERVERS 的 binary 全是裸名 → Windows 上必须靠 PATHEXT 试探才可能命中" {
    // 这条钉的是**注册表与查找契约的耦合**,不是本机装了什么(那不可控)。
    // 每个 binary 都是无目录、无可执行后缀的裸名,于是在 Windows 上:
    //   ① 必须切 PATH(而 `:` 切会把 `C:\...` 切碎)② 必须补 PATHEXT 后缀(否则永远不是 `zls.exe`)。
    // 缺任一条,这六种语言在 Windows 上就全部报"未安装"——修复前的现场。
    // 若将来某行改成带路径或带后缀的 binary,这条会红,提示同步 `platform/exe_lookup.zig` 的假设。
    for (&SERVERS) |*def| {
        try testing.expect(def.binary.len > 0);
        try testing.expect(!exe_lookup.isPathLike(.posix, def.binary));
        try testing.expect(!exe_lookup.isPathLike(.windows, def.binary));
        try testing.expect(std.mem.indexOfScalar(u8, def.binary, '.') == null);
    }
}

test "resolveServerRoot: marker 命中 / 退回 git_root" {
    // 无真 FS 时 nearestRoot 找不到 marker → 退回 git_root。
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const def = &SERVERS[0]; // zls
    const r = resolveServerRoot(def, "/nonexistent_xyz/src/main.zig", "/nonexistent_xyz", &buf);
    try testing.expect(r != null);
    try testing.expectEqualStrings("/nonexistent_xyz", r.?);
}

test "binaryAvailable: 绝对路径 def 可判定(不依赖机器上装了哪个 language server)" {
    // issue #17 的核心谓词:注册表里"有一行"和"二进制真的在"是两回事,这里把两侧都钉死。
    // 用绝对路径构造 def → 不受 PATH 内容影响,server-absent 一侧在 CI 上无条件跑到。
    // **两平台都跑**:各取本平台一个必然存在的可执行文件作 present 样本。
    const is_win = @import("builtin").os.tag == .windows;
    const present = ServerDef{
        .server_id = "fake-present",
        .extensions = &.{".fakepresent"},
        .binary = if (is_win) "C:\\Windows\\System32\\cmd.exe" else "/bin/sh",
        .root_markers = &.{},
    };
    const absent = ServerDef{
        .server_id = "fake-absent",
        .extensions = &.{".fakeabsent"},
        .binary = if (is_win) "C:\\nonexistent\\no-such-langserver-9417.exe" else "/nonexistent/no-such-langserver-9417",
        .root_markers = &.{},
    };
    try testing.expect(binaryAvailable(&present));
    try testing.expect(!binaryAvailable(&absent));
}

test "binaryAvailable: PATH 里瞎名 → false(注册了但没装的那一侧)" {
    const absent = ServerDef{
        .server_id = "fake-absent-path",
        .extensions = &.{".fakeabsentpath"},
        .binary = "no-such-langserver-xyz-9417",
        .root_markers = &.{},
    };
    try testing.expect(!binaryAvailable(&absent));
}

test "REGRESSION issue #17: 注册表谓词与安装谓词是两回事" {
    // 老代码把"扩展名注册"当成"能力可用"。这里断言两个谓词**在类型层面就是两件事**:
    // 一个合成的、注册形态完全合法的 def,其二进制不存在时能力必须判为不可用。
    const def = ServerDef{
        .server_id = "ghost",
        .extensions = &.{".ghost"},
        .binary = "/nonexistent/ghost-langserver",
        .root_markers = &.{"ghost.toml"},
    };
    // 注册侧:形态合法(有扩展名、有 marker)。
    try testing.expect(def.extensions.len > 0);
    // 安装侧:不可用 —— 两者不得互相冒充。
    try testing.expect(!binaryAvailable(&def));
}
