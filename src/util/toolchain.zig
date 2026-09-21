//! 外部工具链路径解析。
//!
//! 目前职责：找可用的 ripgrep 二进制（rg / rg.exe）与相邻 Lean kernel。
//! 开发布局查找顺序：RG_BIN、PATH、可执行文件同目录、固定 fallback。
//! 发布布局查找顺序：RG_BIN、可执行文件同目录、PATH；不查询固定 fallback。
//!
//! "可执行文件同目录"一律从 `platform.paths.selfExeRealPath`(已解 symlink 的物理路径)
//! 推导,与 KgClient 的 vendored tinykg 定位共用同一入口——经 `~/bin/metacodes` symlink
//! 启动时三者必须落到同一个 `<prefix>`,不能一个解 symlink 两个不解。
//!
//! 未命中返回 error.RipgrepNotFound。结果缓存(进程内不变;并发 Grep 线程安全)。

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const pfs = @import("platform").fs;
const sync = @import("platform").sync;

const RG_NAME = if (is_windows) "rg.exe" else "rg";
pub const KernelName = enum { formal, project };
const FORMAL_KERNEL_NAME = if (is_windows) "metacodes-formal-kernel.exe" else "metacodes-formal-kernel";
const PROJECT_KERNEL_NAME = if (is_windows) "metacodes-project-kernel.exe" else "metacodes-project-kernel";

fn kernelFileName(name: KernelName) []const u8 {
    return switch (name) {
        .formal => FORMAL_KERNEL_NAME,
        .project => PROJECT_KERNEL_NAME,
    };
}

/// 仓库 vendored 二进制(manifest-pinned,见 vendor/ripgrep/manifest.json)。
/// 按编译 target 在 comptime 选中对应文件;无 vendored 二进制的 target(如
/// aarch64-linux)为 null,由 PATH/系统安装位兜底。相对路径 = 从仓库根运行的
/// 开发/CI 场景专用；发布布局不会查询此路径。
const VENDORED_RG: ?[:0]const u8 = switch (builtin.os.tag) {
    .macos => switch (builtin.cpu.arch) {
        .aarch64 => "./vendor/ripgrep/bin/rg-macos-aarch64",
        .x86_64 => "./vendor/ripgrep/bin/rg-macos-x86_64",
        else => null,
    },
    .linux => switch (builtin.cpu.arch) {
        .x86_64 => "./vendor/ripgrep/bin/rg-linux-x86_64",
        else => null,
    },
    .windows => switch (builtin.cpu.arch) {
        .x86_64 => "vendor\\ripgrep\\bin\\rg-windows-x86_64.exe",
        else => null,
    },
    else => null,
};

const VENDORED_FALLBACK = if (VENDORED_RG) |vendored| [_][:0]const u8{vendored} else [_][:0]const u8{};
// A distinct `vendored` source will arrive with the release layout in a later #47 stage.

const FALLBACK_PATHS = VENDORED_FALLBACK ++ (if (is_windows) [_][:0]const u8{
    // scoop / choco / winget 常见位(用户目录展开在 PATH 搜索兜住,这里放系统级)
    "C:\\ProgramData\\chocolatey\\bin\\rg.exe",
} else [_][:0]const u8{
    "/usr/bin/rg",
    "/usr/local/bin/rg",
    "/opt/homebrew/bin/rg",
    "/root/.cargo/bin/rg",
    "/usr/share/kiro/resources/app/node_modules/@vscode/ripgrep/bin/rg",
});

// 缓存:rg 路径进程内不变。PATH 搜索命中的路径存这里(静态生命周期)。
// **task#24 并发修**:cache_done atomic 只护"已缓存"读——首次 init 时多线程(并发后台 subagent
// 的 Glob)会同时进 resolve()→searchPath(),并发写**共享静态 path_buf** → 互相踩,返回的
// path_buf[0..need :0] sentinel 位是别的线程的字符 → sentinel mismatch 崩(test:new 后台 Glob 实证)。
// 修:init_mutex 双检锁串行首次 resolve;缓存后走无锁快路径(cache_done),path_buf 首次后不再写。
var cache_done = std.atomic.Value(bool).init(false);
var cached_resolution: ?RipgrepResolution = null;
var path_buf: [std.fs.max_path_bytes]u8 = undefined;
var init_mutex: sync.Mutex = .{};
pub const Layout = enum { development, release };
var current_layout: Layout = .development;

var formal_kernel_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
var project_kernel_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
var formal_kernel_buf: [std.fs.max_path_bytes]u8 = undefined;
var project_kernel_buf: [std.fs.max_path_bytes]u8 = undefined;
var formal_kernel_initialized = false;
var project_kernel_initialized = false;
var formal_kernel_cached: ?[:0]const u8 = null;
var project_kernel_cached: ?[:0]const u8 = null;

/// Must be called before the first resolution. A later call is a programming error.
pub fn setLayout(layout: Layout) void {
    _ = init_mutex.lock();
    defer _ = init_mutex.unlock();
    std.debug.assert(!cache_done.load(.acquire));
    current_layout = layout;
}

pub fn currentLayout() Layout {
    _ = init_mutex.lock();
    defer _ = init_mutex.unlock();
    return current_layout;
}

/// 测试 seam(仅测试构建存在;生产构建为 void,不可误用):catalog 依赖门的
/// 两个方向都需要确定性覆盖——开发机/CI 几乎总能解析到 rg,负路径在真实环境
/// 不可构造。串行 test runner 内设置后必须 defer 复位为 null。
pub var test_ripgrep_override: if (builtin.is_test) ?bool else void =
    if (builtin.is_test) null else {};

pub const RipgrepSource = enum { env, path, adjacent, fallback };
const Step = enum { env, path, adjacent, fallbacks };
fn resolutionOrder(layout: Layout) []const Step {
    return switch (layout) {
        .development => &[_]Step{ .env, .path, .adjacent, .fallbacks },
        .release => &[_]Step{ .env, .adjacent, .path },
    };
}
pub const RipgrepResolution = struct { path: [:0]const u8, source: RipgrepSource };

/// 依赖可用性探测(catalog 准入用):rg 是否可解析。复用 ripgrepPath 的
/// 进程内缓存,不引入新的解析顺序。
pub fn ripgrepAvailable() bool {
    if (comptime builtin.is_test) {
        if (test_ripgrep_override) |forced| return forced;
    }
    _ = ripgrepPath() catch return false;
    return true;
}

/// 返回可执行 rg。开发顺序为 RG_BIN、PATH、相邻、fallback；发布顺序为
/// RG_BIN、相邻、PATH。返回值静态生命周期。
pub fn ripgrepPath() error{RipgrepNotFound}![:0]const u8 {
    return (ripgrepResolution() catch return error.RipgrepNotFound).path;
}

pub fn ripgrepResolution() error{RipgrepNotFound}!RipgrepResolution {
    if (cache_done.load(.acquire)) {
        return cached_resolution orelse error.RipgrepNotFound;
    }
    // 首次 init:串行(双检)——否则并发 searchPath 踩共享 path_buf。
    _ = init_mutex.lock();
    defer _ = init_mutex.unlock();
    if (cache_done.load(.acquire)) {
        return cached_resolution orelse error.RipgrepNotFound;
    }
    const result = resolve();
    cached_resolution = result;
    cache_done.store(true, .release);
    return result orelse error.RipgrepNotFound;
}

fn resolve() ?RipgrepResolution {
    for (resolutionOrder(current_layout)) |step| switch (step) {
        .env => if (std.c.getenv("RG_BIN")) |env_c| {
            if (pfs.exists(env_c)) return .{ .path = std.mem.span(env_c), .source = .env };
        },
        .path => if (searchPath()) |p| return .{ .path = p, .source = .path },
        .adjacent => if (nextToExecutable()) |p| return .{ .path = p, .source = .adjacent },
        .fallbacks => for (FALLBACK_PATHS) |p| {
            if (pfs.exists(p.ptr)) return .{ .path = p, .source = .fallback };
        },
    };
    return null;
}

test "resolution order follows layout" {
    try std.testing.expectEqualSlices(Step, &[_]Step{ .env, .adjacent, .path }, resolutionOrder(.release));
    try std.testing.expectEqualSlices(Step, &[_]Step{ .env, .path, .adjacent, .fallbacks }, resolutionOrder(.development));
}

var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;

/// <dir-of-self-executable>/rg[.exe]。resolve() 已在 init_mutex 内,静态 buf 安全。
/// 目录取自物理路径(selfExeRealPath):经 symlink 启动时 rg 在 symlink 目标旁,不在 symlink 旁。
fn nextToExecutable() ?[:0]const u8 {
    const paths = @import("platform").paths;
    const exe = paths.selfExeRealPath(exe_dir_buf[0 .. exe_dir_buf.len - RG_NAME.len - 2]) orelse return null;
    const dir_sep: u8 = if (is_windows) '\\' else '/';
    const cut = std.mem.lastIndexOfScalar(u8, exe, dir_sep) orelse return null;
    const need = cut + 1 + RG_NAME.len;
    if (need + 1 > exe_dir_buf.len) return null;
    // selfExeRealPath 写在 buf 头部;截到目录后原地续接文件名。
    @memcpy(exe_dir_buf[cut + 1 ..][0..RG_NAME.len], RG_NAME);
    exe_dir_buf[need] = 0;
    if (pfs.exists(@ptrCast(&exe_dir_buf))) return exe_dir_buf[0..need :0];
    return null;
}

/// Resolve the fixed install-prefix location without consulting process state.
/// The caller owns `buf`; the result is null when the adjacent kernel is absent.
pub fn kernelPathBeside(exe_path: []const u8, name: KernelName, buf: []u8) ?[:0]const u8 {
    const exe_dir = std.fs.path.dirname(exe_path) orelse return null;
    const prefix = std.fs.path.dirname(exe_dir) orelse return null;
    const sep: u8 = if (is_windows) '\\' else '/';
    const file_name = kernelFileName(name);
    const need = prefix.len + 1 + "libexec/metacodes".len + 1 + file_name.len;
    if (need + 1 > buf.len) return null;
    var index: usize = 0;
    @memcpy(buf[index..][0..prefix.len], prefix);
    index += prefix.len;
    buf[index] = sep;
    index += 1;
    const libexec = "libexec/metacodes";
    @memcpy(buf[index..][0..libexec.len], libexec);
    index += libexec.len;
    buf[index] = sep;
    index += 1;
    @memcpy(buf[index..][0..file_name.len], file_name);
    index += file_name.len;
    buf[index] = 0;
    if (!pfs.exists(@ptrCast(buf.ptr))) return null;
    return buf[0..index :0];
}

/// Uncached: `<prefix>/libexec/metacodes/<kernel>` beside the **physical** executable
/// (`selfExeRealPath`), so a symlinked install resolves the prefix the symlink points into.
/// `exe_buf` receives the executable path, `buf` the kernel path; both outlive the result.
fn kernelBesideSelf(name: KernelName, exe_buf: []u8, buf: []u8) ?[:0]const u8 {
    const exe = @import("platform").paths.selfExeRealPath(exe_buf) orelse return null;
    return kernelPathBeside(exe, name, buf);
}

/// Cached adjacent kernel resolution. The init mutex also protects the static
/// sentinel byte: a first concurrent probe must not return another kernel's path.
pub fn kernelAdjacentPath(name: KernelName) ?[:0]const u8 {
    _ = init_mutex.lock();
    defer _ = init_mutex.unlock();
    const initialized = switch (name) {
        .formal => formal_kernel_initialized,
        .project => project_kernel_initialized,
    };
    if (initialized) return switch (name) {
        .formal => formal_kernel_cached,
        .project => project_kernel_cached,
    };
    const resolved = switch (name) {
        .formal => kernelBesideSelf(name, &formal_kernel_exe_buf, &formal_kernel_buf),
        .project => kernelBesideSelf(name, &project_kernel_exe_buf, &project_kernel_buf),
    };
    switch (name) {
        .formal => {
            formal_kernel_cached = resolved;
            formal_kernel_initialized = true;
        },
        .project => {
            project_kernel_cached = resolved;
            project_kernel_initialized = true;
        },
    }
    return resolved;
}

/// PATH 逐目录拼 <dir><sep>rg[.exe],存在即返回(写进 path_buf,静态)。
fn searchPath() ?[:0]const u8 {
    const path_env = std.c.getenv("PATH") orelse return null;
    const path = std.mem.span(path_env);
    const list_sep: u8 = if (is_windows) ';' else ':';
    const dir_sep: u8 = if (is_windows) '\\' else '/';
    var it = std.mem.splitScalar(u8, path, list_sep);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const need = dir.len + 1 + RG_NAME.len;
        if (need + 1 > path_buf.len) continue;
        @memcpy(path_buf[0..dir.len], dir);
        path_buf[dir.len] = dir_sep;
        @memcpy(path_buf[dir.len + 1 ..][0..RG_NAME.len], RG_NAME);
        path_buf[need] = 0;
        if (pfs.exists(@ptrCast(&path_buf))) return path_buf[0..need :0];
    }
    return null;
}

test "ripgrepPath resolves whenever a vendored rg exists" {
    // The dual-outcome ancestor of this test ("finds some rg or returns
    // NotFound") passed in every environment by construction and let the
    // deployed resolver stay broken for ~200 container trials.  A conditional
    // POSITIVE is the honest form: when the repo's vendored rg is present
    // (every dev/CI checkout running from the repo root), resolution MUST
    // succeed; only environments that genuinely lack any rg may skip.
    const vendored_reachable = if (VENDORED_RG) |vendored| pfs.exists(vendored.ptr) else false;
    const reachable = vendored_reachable or searchPath() != null;
    const resolved = ripgrepPath() catch |err| {
        try std.testing.expect(err == error.RipgrepNotFound);
        if (reachable) return error.TestUnexpectedResult;
        return error.SkipZigTest;
    };
    try std.testing.expect(resolved.len > 0);
}

test "ripgrepAvailable mirrors ripgrepPath and honors the test override" {
    // 无 override 时必须与 ripgrepPath 同判——探测是解析的布尔投影,不是第二套逻辑。
    const resolved = if (ripgrepPath()) |_| true else |_| false;
    try std.testing.expectEqual(resolved, ripgrepAvailable());

    test_ripgrep_override = false;
    defer test_ripgrep_override = null;
    try std.testing.expect(!ripgrepAvailable());
    test_ripgrep_override = true;
    try std.testing.expect(ripgrepAvailable());
}

test "next-to-executable probe finds an adjacent rg" {
    if (is_windows) return error.SkipZigTest;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const paths = @import("platform").paths;
    const exe = paths.selfExePath(&buf) orelse return error.SkipZigTest;
    const cut = std.mem.lastIndexOfScalar(u8, exe, '/') orelse return error.SkipZigTest;
    var rg_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rg_path = try std.fmt.bufPrint(&rg_path_buf, "{s}/rg", .{exe[0..cut]});
    std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = rg_path,
        .data = "#!/bin/sh\n",
    }) catch return error.SkipZigTest;
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, rg_path) catch {};
    const found = nextToExecutable() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.endsWith(u8, found, "/rg"));
}

/// Stage `<root>/prefix/{bin/metacodes,bin/rg,libexec/metacodes/<kernels>}` plus
/// `<root>/elsewhere/metacodes -> prefix/bin/metacodes`; returns the realpath'd root.
fn stageSymlinkedInstall(tmp: *std.testing.TmpDir, root_buf: []u8) ![]const u8 {
    try tmp.dir.createDirPath(std.testing.io, "prefix/bin");
    try tmp.dir.createDirPath(std.testing.io, "prefix/libexec/metacodes");
    try tmp.dir.createDirPath(std.testing.io, "elsewhere");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "prefix/bin/metacodes", .data = "#!/bin/sh\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "prefix/bin/" ++ RG_NAME, .data = "#!/bin/sh\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "prefix/libexec/metacodes/" ++ FORMAL_KERNEL_NAME, .data = "kernel" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "prefix/libexec/metacodes/" ++ PROJECT_KERNEL_NAME, .data = "kernel" });
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, root_buf)];
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = try std.fmt.bufPrint(&real_buf, "{s}/prefix/bin/metacodes", .{root});
    try tmp.dir.symLink(std.testing.io, real, "elsewhere/metacodes", .{});
    return root;
}

test "adjacent rg and kernels resolve when the executable is invoked through a symlink elsewhere" {
    // 复现 2026-09-21 的安装形态:`ln -s <prefix>/bin/metacodes ~/bin/metacodes`。macOS 的
    // selfExePath 报告的是 ~/bin 里的 symlink;相邻查找必须落到 <prefix>,不是 ~/bin。
    if (is_windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try stageSymlinkedInstall(&tmp, &root_buf);
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buf, "{s}/elsewhere/metacodes", .{root});
    const paths = @import("platform").paths;
    paths.test_self_exe_override = link;
    defer paths.test_self_exe_override = null;

    var expect_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rg = nextToExecutable() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect_buf, "{s}/prefix/bin/rg", .{root}), rg);

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    var out: [std.fs.max_path_bytes]u8 = undefined;
    const formal = kernelBesideSelf(.formal, &exe_buf, &out) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect_buf, "{s}/prefix/libexec/metacodes/{s}", .{ root, FORMAL_KERNEL_NAME }), formal);
    const project = kernelBesideSelf(.project, &exe_buf, &out) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect_buf, "{s}/prefix/libexec/metacodes/{s}", .{ root, PROJECT_KERNEL_NAME }), project);
}

test "adjacent lookups from the symlink directory itself find nothing (the fix is realpath, not a second search root)" {
    // 负例:没有 realpath 时同一布局在 elsewhere/ 旁一无所获。把 override 指向一个**不是**
    // symlink 的 elsewhere/metacodes 副本,证明命中来自解 symlink,而非 elsewhere 恰好也有产物。
    if (is_windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try stageSymlinkedInstall(&tmp, &root_buf);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "elsewhere/metacodes-copy", .data = "#!/bin/sh\n" });
    var copy_buf: [std.fs.max_path_bytes]u8 = undefined;
    const copy = try std.fmt.bufPrint(&copy_buf, "{s}/elsewhere/metacodes-copy", .{root});
    const paths = @import("platform").paths;
    paths.test_self_exe_override = copy;
    defer paths.test_self_exe_override = null;
    try std.testing.expect(nextToExecutable() == null);
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    var out: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect(kernelBesideSelf(.formal, &exe_buf, &out) == null);
    try std.testing.expect(kernelBesideSelf(.project, &exe_buf, &out) == null);
}

test "kernelPathBeside finds an adjacent Kernel without dot segments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "bin");
    try tmp.dir.createDirPath(std.testing.io, "libexec/metacodes");
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = try std.fmt.bufPrint(&exe_buf, "{s}/bin/metacodes", .{root});
    const file_name = if (is_windows) "metacodes-formal-kernel.exe" else "metacodes-formal-kernel";
    var file_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try std.fmt.bufPrint(&file_buf, "libexec/metacodes/{s}", .{file_name});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file, .data = "kernel" });
    var out: [std.fs.max_path_bytes]u8 = undefined;
    const found = kernelPathBeside(exe, .formal, &out) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, found, "..") == null);
    try std.testing.expect(std.mem.endsWith(u8, found, file_name));
    try tmp.dir.deleteFile(std.testing.io, file);
    try std.testing.expect(kernelPathBeside(exe, .formal, &out) == null);
}
