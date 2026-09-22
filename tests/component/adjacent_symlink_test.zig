//! L2:经 symlink / junction 启动的进程仍从**物理** <prefix> 解析相邻产物(rg + 两个 Lean kernel)。
//!
//! 2026-09-21 实测(macOS arm64,release 布局,`~/bin/metacodes -> <prefix>/bin/metacodes`):
//! rg 落到 PATH 的 /opt/homebrew/bin/rg(digest 不匹配)、两个 kernel unresolved、只有已做
//! realpath 的 tinykg 命中。根因是 `_NSGetExecutablePath` 返回 symlink 自身,toolchain 的两个
//! 解析器直接拿它取目录。Windows 同款(#140):`GetModuleFileNameW` 报被调用路径,而词法的
//! `_fullpath` 解不开 NTFS symlink / junction,相邻产物同样落到链接旁边。
//!
//! 本测试不模拟:把 `zig-out/bin/selfexe_probe[.exe]` 复制成 `<tmp>/prefix/bin/metacodes[.exe]`,
//! 在别处建 symlink(或 Windows junction),**经链接起真进程**,断言探针打印的三个路径都在
//! prefix 下。toolchain.zig 里的 seam 单测覆盖同一逻辑的进程内形态;这里补的是 OS 那一环。
//! 所有路径比较前统一成正斜杠(`harness.normalizeSlashes`):toolchain 拼 `libexec/metacodes`
//! 用正斜杠,GetFinalPathNameByHandle 给反斜杠,两者指同一个文件。
const std = @import("std");
const builtin = @import("builtin");
const cc = @import("cc");
const harness = @import("harness");

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

const LinkKind = enum { symlink, junction };

/// 所有字段都是正斜杠形态(见文件头);`real_exe`/`rg`/`formal`/`project` 的期望值来自 std 的
/// 物理路径(Windows:NT 宽字符 API + GetFinalPathNameByHandle),不是被测代码自己。
const Layout = struct {
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    /// 经链接的被调用路径。
    link: []const u8,
    real_exe: []const u8,
    rg: []const u8,
    formal: []const u8,
    project: []const u8,

    fn stage(gpa: std.mem.Allocator, tmp: *std.testing.TmpDir, kind: LinkKind) !Layout {
        const io = std.testing.io;
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        try tmp.dir.createDirPath(io, "prefix/bin");
        try tmp.dir.createDirPath(io, "prefix/libexec/metacodes");
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = harness.normalizeSlashes(try a.dupe(u8, root_buf[0..try tmp.dir.realPath(io, &root_buf)]));
        // 探针复制成 <prefix>/bin/metacodes(copyFile 保留源 permissions → 仍可执行)。
        try std.Io.Dir.cwd().copyFile(PROBE, tmp.dir, "prefix/bin/" ++ EXE, io, .{});
        try tmp.dir.writeFile(io, .{ .sub_path = "prefix/bin/" ++ RG, .data = "#!/bin/sh\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = "prefix/libexec/metacodes/" ++ FORMAL, .data = "kernel" });
        try tmp.dir.writeFile(io, .{ .sub_path = "prefix/libexec/metacodes/" ++ PROJECT, .data = "kernel" });
        const real_exe = harness.normalizeSlashes(try tmp.dir.realPathFileAlloc(io, "prefix/bin/" ++ EXE, a));
        const rg = harness.normalizeSlashes(try tmp.dir.realPathFileAlloc(io, "prefix/bin/" ++ RG, a));
        const formal = harness.normalizeSlashes(try tmp.dir.realPathFileAlloc(io, "prefix/libexec/metacodes/" ++ FORMAL, a));
        const project = harness.normalizeSlashes(try tmp.dir.realPathFileAlloc(io, "prefix/libexec/metacodes/" ++ PROJECT, a));
        const link = switch (kind) {
            .symlink => blk: {
                try tmp.dir.createDirPath(io, "elsewhere");
                // Windows 上 symlink 需要特权;runner 没有就 skip(junction 用例不需要特权)。
                try cc.platform_test_support.symlinkOrSkip(tmp.dir, io, real_exe, "elsewhere/" ++ EXE, .{});
                break :blk try std.fmt.allocPrint(a, "{s}/elsewhere/{s}", .{ root, EXE });
            },
            .junction => blk: {
                if (!is_windows) return error.SkipZigTest;
                const junction = try std.fmt.allocPrint(a, "{s}/elsewhere_j", .{root});
                const target = try std.fmt.allocPrint(a, "{s}/prefix", .{root});
                try cc.platform_test_support.junction(a, junction, target);
                break :blk try std.fmt.allocPrint(a, "{s}/elsewhere_j/bin/{s}", .{ root, EXE });
            },
        };
        return .{ .arena = arena, .root = root, .link = link, .real_exe = real_exe, .rg = rg, .formal = formal, .project = project };
    }

    fn deinit(self: *Layout) void {
        self.arena.deinit();
    }
};

/// 起探针,输出统一成正斜杠(owned)。
fn runProbe(a: std.mem.Allocator, exe: []const u8) ![]u8 {
    const exe_z = try a.dupeZ(u8, exe);
    defer a.free(exe_z);
    const argv = [_]?[*:0]const u8{ exe_z.ptr, null };
    const out = try cc.tools_common.spawnCaptureStdoutAbortableTimed(argv[0..], a, null, 30_000);
    _ = harness.normalizeSlashes(out);
    return out;
}

fn expectResolvedBesidePhysical(layout: *const Layout, output: []const u8) !void {
    // 前提先钉死:进程确实是经链接起的,且物理路径解回 prefix。macOS 的 invoked 是
    // symlink 自身(bug 的成因);Linux /proc/self/exe 由内核解好,invoked 已是物理路径;Windows
    // GetModuleFileNameW 报被调用路径——都合法,但 physical 必须是 prefix 里的真文件。
    const invoked = field(output, "invoked") orelse return error.TestUnexpectedResult;
    if (!std.mem.eql(u8, invoked, layout.link) and !std.mem.eql(u8, invoked, layout.real_exe))
        return std.testing.expectEqualStrings(layout.link, invoked);
    if (builtin.os.tag == .macos) try std.testing.expectEqualStrings(layout.link, invoked);
    try std.testing.expectEqualStrings(layout.real_exe, field(output, "physical") orelse return error.TestUnexpectedResult);

    // 三个相邻解析器都落到 <prefix>,且 rg 是 adjacent 命中而非 PATH 兜底。
    try std.testing.expectEqualStrings(layout.rg, field(output, "rg") orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("adjacent", field(output, "rg_source") orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings(layout.formal, field(output, "formal") orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings(layout.project, field(output, "project") orelse return error.TestUnexpectedResult);
}

test "adjacent rg and kernels resolve for a process started through a symlink in another directory" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var layout = try Layout.stage(a, &tmp, .symlink);
    defer layout.deinit();

    const output = try runProbe(a, layout.link);
    defer a.free(output);
    try expectResolvedBesidePhysical(&layout, output);
}

test "adjacent rg and kernels resolve for a process started through an NTFS junction (Windows)" {
    // #140:junction 是 Windows 安装最常见的链接形态,不需要特权;词法的 `_fullpath` 解不开它,
    // 经句柄的 `finalPath` 才行。
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var layout = try Layout.stage(a, &tmp, .junction);
    defer layout.deinit();

    const output = try runProbe(a, layout.link);
    defer a.free(output);
    try expectResolvedBesidePhysical(&layout, output);
}

test "the same install started through its real path resolves identically" {
    // 对照组:symlink 与真路径启动必须给出同一组答案(修法是统一入口,不是给 symlink 开特例)。
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var layout = try Layout.stage(a, &tmp, .symlink);
    defer layout.deinit();

    const via_link = try runProbe(a, layout.link);
    defer a.free(via_link);
    const via_real = try runProbe(a, layout.real_exe);
    defer a.free(via_real);
    for ([_][]const u8{ "physical", "rg", "rg_source", "formal", "project" }) |key| {
        try std.testing.expectEqualStrings(field(via_real, key).?, field(via_link, key).?);
    }
    try std.testing.expectEqualStrings(layout.real_exe, field(via_real, "invoked").?);
}
