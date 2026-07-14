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
