//! LSP server 注册表(对齐 hermes servers.py,精简到核心语言):按扩展名选 server + 每语言的
//! spawn 命令 / root markers / excludes。二进制经 PATH 解析(which);解析不到 → 该语言不启动。
//!
//! v1 覆盖:zig(zls)/python(pyright)/typescript+tsx+js+jsx(typescript-language-server)/
//! go(gopls)/rust(rust-analyzer)/c+cpp(clangd)。加语言只在 SERVERS 表加一行。
const std = @import("std");
const workspace = @import("workspace.zig");

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

/// 在 PATH 里找可执行 binary,写绝对路径进 out_buf 返回;找不到 → null。
pub fn which(binary: []const u8, out_buf: []u8) ?[]const u8 {
    // binary 含 '/' 视为路径直接查。
    if (std.mem.indexOfScalar(u8, binary, '/') != null) {
        if (isExecutable(binary)) {
            if (binary.len <= out_buf.len) {
                @memcpy(out_buf[0..binary.len], binary);
                return out_buf[0..binary.len];
            }
        }
        return null;
    }
    const path_env = std.c.getenv("PATH") orelse return null;
    const path = std.mem.span(path_env);
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, binary }) catch continue;
        if (isExecutable(full)) {
            if (full.len <= out_buf.len) {
                @memcpy(out_buf[0..full.len], full);
                return out_buf[0..full.len];
            }
        }
    }
    return null;
}

/// def 的 language server 二进制**此刻是否真的可用**(PATH 可解析,或 binary 含 `/` 时该路径可执行)。
///
/// **注册表命中 ≠ 能力可用**(issue #17):`SERVERS` 是编译期静态表,`binary` 是运行期外部进程。
/// 判定"这个文件能不能出符号"必须同时过这一关,否则 `.py` 在没装 pyright 的机器上会被判成
/// "有能力",最终以裸空结果收场、被读成"查无定义"。
///
/// 成本 = 一次 PATH 扫描(每个目录一次 `access(2)`)。**刻意不做进程级缓存**:逐文件调用的循环
/// 都是有界的(CodeMap `MAX_FILES` / FindSymbol `MAX_CANDIDATE_FILES`),相对每文件一次 LSP 往返
/// (~30ms)可忽略;而缓存会把"跑到一半才装上 server"钉死成永久不可用,也会让测试互相污染。
pub fn binaryAvailable(def: *const ServerDef) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return which(def.binary, &buf) != null;
}

fn isExecutable(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return false;
    return std.c.access(z.ptr, 1) == 0; // X_OK=1
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

test "which: 找得到 /bin/sh,找不到瞎名" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // sh 一定在 PATH。
    const sh = which("sh", &buf);
    try testing.expect(sh != null);
    try testing.expect(std.mem.endsWith(u8, sh.?, "/sh"));
    // 绝对路径直查。
    var buf2: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(which("/bin/sh", &buf2) != null);
    // 瞎名找不到。
    var buf3: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(which("no-such-binary-xyz-9417", &buf3) == null);
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(/bin/sh 作已知可执行样本)
    // issue #17 的核心谓词:注册表里"有一行"和"二进制真的在"是两回事,这里把两侧都钉死。
    // 用绝对路径构造 def → 不受 PATH 内容影响,server-absent 一侧在 CI 上无条件跑到。
    const present = ServerDef{
        .server_id = "fake-present",
        .extensions = &.{".fakepresent"},
        .binary = "/bin/sh",
        .root_markers = &.{},
    };
    const absent = ServerDef{
        .server_id = "fake-absent",
        .extensions = &.{".fakeabsent"},
        .binary = "/nonexistent/no-such-langserver-9417",
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
