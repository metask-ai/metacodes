//! L2:经 symlink / junction 启动的进程仍从**物理** <prefix> 解析相邻产物(rg + 两个 Lean kernel)。
//!
//! 2026-09-21 实测(macOS arm64,release 布局,`~/bin/metacodes -> <prefix>/bin/metacodes`):
//! rg 落到 PATH 的 /opt/homebrew/bin/rg(digest 不匹配)、两个 kernel unresolved、只有已做
//! realpath 的 tinykg 命中。根因是 `_NSGetExecutablePath` 返回 symlink 自身,toolchain 的两个
//! 解析器直接拿它取目录。Windows 同款(#140):`GetModuleFileNameW` 报被调用路径,而 `_fullpath`
//! 只做词法规范化,经 NTFS symlink 或 junction 启动时相邻产物同样落到链接旁边。
//!
//! 本测试不模拟:把 `zig-out/bin/selfexe_probe[.exe]` 复制成 `<tmp>/prefix/bin/metacodes[.exe]`,
//! 在别处建 symlink(或 Windows junction),**经链接起真进程**,断言探针打印的三个路径都在
//! prefix 下。toolchain.zig 里的 seam 单测覆盖同一逻辑的进程内形态;这里补的是 OS 那一环。
const std = @import("std");
const builtin = @import("builtin");
const cc = @import("cc");

const is_windows = builtin.os.tag == .windows;
const EXE = if (is_windows) "metacodes.exe" else "metacodes";
const PROBE = if (is_windows) "zig-out/bin/selfexe_probe.exe" else "zig-out/bin/selfexe_probe";
const RG = if (is_windows) "rg.exe" else "rg";
const FORMAL = if (is_windows) "metacodes-formal-kernel.exe" else "metacodes-formal-kernel";
const PROJECT = if (is_windows) "metacodes-project-kernel.exe" else "metacodes-project-kernel";

fn field(output: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (std.mem.eql(u8, trimmed[0..eq], key)) return trimmed[eq + 1 ..];
    }
    return null;
}

/// 路径相等,Windows 上不区分 `/` 与 `\`(toolchain 拼 `libexec/metacodes` 用的是正斜杠,而
/// GetFinalPathNameByHandle 给的是反斜杠——两者指同一个文件)。纯判断,不打印。
fn samePath(expected: []const u8, actual: []const u8) bool {
    if (!is_windows) return std.mem.eql(u8, expected, actual);
    if (expected.len != actual.len) return false;
    for (expected, actual) |e, a| {
        const en: u8 = if (e == '/') '\\' else e;
        const an: u8 = if (a == '/') '\\' else a;
        if (en != an) return false;
    }
    return true;
}

/// 只在真的不等时才走 expectEqualStrings(它会把 diff 打到 stderr;对"二选一"的断言不能提前
/// 调用它,否则通过的用例也会在日志里留下一份假的 expected/found)。
fn expectSamePath(expected: []const u8, actual: []const u8) !void {
    if (!samePath(expected, actual)) return std.testing.expectEqualStrings(expected, actual);
}

const LinkKind = enum { symlink, junction };

const Layout = struct {
    root: []const u8,
    /// 经链接的被调用路径。
    link: []const u8,
    // 下面四个来自 realPathFileAlloc([:0]u8):保留哨兵类型,free 才对得上分配大小。
    real_exe: [:0]const u8,
    rg: [:0]const u8,
    formal: [:0]const u8,
    project: [:0]const u8,

    fn stage(a: std.mem.Allocator, tmp: *std.testing.TmpDir, kind: LinkKind) !Layout {
        const io = std.testing.io;
        try tmp.dir.createDirPath(io, "prefix/bin");
        try tmp.dir.createDirPath(io, "prefix/libexec/metacodes");
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = try a.dupe(u8, root_buf[0..try tmp.dir.realPath(io, &root_buf)]);
        errdefer a.free(root);
        // 探针复制成 <prefix>/bin/metacodes(copyFile 保留源 permissions → 仍可执行)。
        try std.Io.Dir.cwd().copyFile(PROBE, tmp.dir, "prefix/bin/" ++ EXE, io, .{});
        try tmp.dir.writeFile(io, .{ .sub_path = "prefix/bin/" ++ RG, .data = "#!/bin/sh\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = "prefix/libexec/metacodes/" ++ FORMAL, .data = "kernel" });
        try tmp.dir.writeFile(io, .{ .sub_path = "prefix/libexec/metacodes/" ++ PROJECT, .data = "kernel" });
        // 期望值全部来自 std 的物理路径(Windows:NT 宽字符 API + GetFinalPathNameByHandle)。
        const real_exe = try tmp.dir.realPathFileAlloc(io, "prefix/bin/" ++ EXE, a);
        errdefer a.free(real_exe);
        const rg = try tmp.dir.realPathFileAlloc(io, "prefix/bin/" ++ RG, a);
        errdefer a.free(rg);
        const formal = try tmp.dir.realPathFileAlloc(io, "prefix/libexec/metacodes/" ++ FORMAL, a);
        errdefer a.free(formal);
        const project = try tmp.dir.realPathFileAlloc(io, "prefix/libexec/metacodes/" ++ PROJECT, a);
        errdefer a.free(project);
        const link = switch (kind) {
            .symlink => blk: {
                try tmp.dir.createDirPath(io, "elsewhere");
                // Windows 上 symlink 需要特权;runner 没有就 skip(junction 用例不需要特权)。
                tmp.dir.symLink(io, real_exe, "elsewhere/" ++ EXE, .{}) catch |err| switch (err) {
                    error.PermissionDenied, error.AccessDenied => return error.SkipZigTest,
                    else => return err,
                };
                break :blk try std.fmt.allocPrint(a, "{s}/elsewhere/{s}", .{ root, EXE });
            },
            .junction => blk: {
                if (!is_windows) return error.SkipZigTest;
                const junction = try std.fmt.allocPrint(a, "{s}\\elsewhere_j", .{root});
                defer a.free(junction);
                const target = try std.fmt.allocPrint(a, "{s}\\prefix", .{root});
                defer a.free(target);
                try makeJunction(a, junction, target);
                break :blk try std.fmt.allocPrint(a, "{s}\\elsewhere_j\\bin\\{s}", .{ root, EXE });
            },
        };
        return .{ .root = root, .link = link, .real_exe = real_exe, .rg = rg, .formal = formal, .project = project };
    }

    fn deinit(self: Layout, a: std.mem.Allocator) void {
        a.free(self.root);
        a.free(self.link);
        a.free(self.real_exe);
        a.free(self.rg);
        a.free(self.formal);
        a.free(self.project);
    }
};

/// `cmd.exe /c mklink /J <link> <target>`:NTFS junction,不需要任何特权,是 Windows 安装最常见的
/// 链接形态。mklink 只认反斜杠;结果以 `exists(link)` 为准(spawn 包装不把非零退出当错误)。
fn makeJunction(a: std.mem.Allocator, link: []const u8, target: []const u8) !void {
    const link_z = try a.dupeZ(u8, link);
    defer a.free(link_z);
    const target_z = try a.dupeZ(u8, target);
    defer a.free(target_z);
    const comspec: [*:0]const u8 = std.c.getenv("COMSPEC") orelse "cmd.exe";
    const argv = [_]?[*:0]const u8{ comspec, "/c", "mklink", "/J", link_z.ptr, target_z.ptr, null };
    const out = try cc.tools_common.spawnCaptureStdoutAbortableTimed(argv[0..], a, null, 30_000);
    a.free(out);
    if (!cc.platform_fs.exists(link_z.ptr)) return error.JunctionCreateFailed;
}

fn runProbe(a: std.mem.Allocator, exe: []const u8) ![]u8 {
    const exe_z = try a.dupeZ(u8, exe);
    defer a.free(exe_z);
    const argv = [_]?[*:0]const u8{ exe_z.ptr, null };
    return cc.tools_common.spawnCaptureStdoutAbortableTimed(argv[0..], a, null, 30_000);
}

fn expectResolvedBesidePhysical(layout: Layout, output: []const u8) !void {
    // 前提先钉死:进程确实是经链接起的,且物理路径解回 prefix。macOS 的 invoked 是
    // symlink 自身(bug 的成因);Linux /proc/self/exe 由内核解好,invoked 已是物理路径;Windows
    // GetModuleFileNameW 报被调用路径——都合法,但 physical 必须是 prefix 里的真文件。
    const invoked = field(output, "invoked") orelse return error.TestUnexpectedResult;
    if (!samePath(layout.link, invoked) and !samePath(layout.real_exe, invoked))
        return std.testing.expectEqualStrings(layout.link, invoked);
    if (builtin.os.tag == .macos) try std.testing.expectEqualStrings(layout.link, invoked);
    try expectSamePath(layout.real_exe, field(output, "physical") orelse return error.TestUnexpectedResult);

    // 三个相邻解析器都落到 <prefix>,且 rg 是 adjacent 命中而非 PATH 兜底。
    try expectSamePath(layout.rg, field(output, "rg") orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("adjacent", field(output, "rg_source") orelse return error.TestUnexpectedResult);
    try expectSamePath(layout.formal, field(output, "formal") orelse return error.TestUnexpectedResult);
    try expectSamePath(layout.project, field(output, "project") orelse return error.TestUnexpectedResult);
}

test "adjacent rg and kernels resolve for a process started through a symlink in another directory" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const layout = try Layout.stage(a, &tmp, .symlink);
    defer layout.deinit(a);

    const output = try runProbe(a, layout.link);
    defer a.free(output);
    try expectResolvedBesidePhysical(layout, output);
}

test "adjacent rg and kernels resolve for a process started through an NTFS junction (Windows)" {
    // #140:junction 是 Windows 安装最常见的链接形态,不需要特权;`_fullpath` 解不开它,
    // 经句柄的 realpath 才行。
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const layout = try Layout.stage(a, &tmp, .junction);
    defer layout.deinit(a);

    const output = try runProbe(a, layout.link);
    defer a.free(output);
    try expectResolvedBesidePhysical(layout, output);
}

test "the same install started through its real path resolves identically" {
    // 对照组:symlink 与真路径启动必须给出同一组答案(修法是统一入口,不是给 symlink 开特例)。
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const layout = try Layout.stage(a, &tmp, .symlink);
    defer layout.deinit(a);

    const via_link = try runProbe(a, layout.link);
    defer a.free(via_link);
    const via_real = try runProbe(a, layout.real_exe);
    defer a.free(via_real);
    for ([_][]const u8{ "physical", "rg", "rg_source", "formal", "project" }) |key| {
        try std.testing.expectEqualStrings(field(via_real, key).?, field(via_link, key).?);
    }
    try expectSamePath(layout.real_exe, field(via_real, "invoked").?);
}
