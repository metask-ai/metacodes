//! L2:经 symlink 启动的进程仍从**物理** <prefix> 解析相邻产物(rg + 两个 Lean kernel)。
//!
//! 2026-09-21 实测(macOS arm64,release 布局,`~/bin/metacodes -> <prefix>/bin/metacodes`):
//! rg 落到 PATH 的 /opt/homebrew/bin/rg(digest 不匹配)、两个 kernel unresolved、只有已做
//! realpath 的 tinykg 命中。根因是 `_NSGetExecutablePath` 返回 symlink 自身,toolchain 的两个
//! 解析器直接拿它取目录。
//!
//! 本测试不模拟:把 `zig-out/bin/selfexe_probe` 复制成 `<tmp>/prefix/bin/metacodes`,在
//! `<tmp>/elsewhere/metacodes` 建 symlink,**经 symlink 起真进程**,断言探针打印的三个路径都在
//! prefix 下。toolchain.zig 里的 seam 单测覆盖同一逻辑的进程内形态;这里补的是 OS 那一环。
const std = @import("std");
const builtin = @import("builtin");
const cc = @import("cc");

const is_windows = builtin.os.tag == .windows;

fn field(output: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, line[0..eq], key)) return line[eq + 1 ..];
    }
    return null;
}

const Layout = struct {
    root: []const u8,
    link: []const u8,
    real_exe: []const u8,
    rg: []const u8,
    formal: []const u8,
    project: []const u8,

    fn stage(a: std.mem.Allocator, tmp: *std.testing.TmpDir) !Layout {
        const io = std.testing.io;
        try tmp.dir.createDirPath(io, "prefix/bin");
        try tmp.dir.createDirPath(io, "prefix/libexec/metacodes");
        try tmp.dir.createDirPath(io, "elsewhere");
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = try a.dupe(u8, root_buf[0..try tmp.dir.realPath(io, &root_buf)]);
        errdefer a.free(root);
        // 探针复制成 <prefix>/bin/metacodes(copyFile 保留源 permissions → 仍可执行)。
        try std.Io.Dir.cwd().copyFile("zig-out/bin/selfexe_probe", tmp.dir, "prefix/bin/metacodes", io, .{});
        try tmp.dir.writeFile(io, .{ .sub_path = "prefix/bin/rg", .data = "#!/bin/sh\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = "prefix/libexec/metacodes/metacodes-formal-kernel", .data = "kernel" });
        try tmp.dir.writeFile(io, .{ .sub_path = "prefix/libexec/metacodes/metacodes-project-kernel", .data = "kernel" });
        const real_exe = try std.fmt.allocPrint(a, "{s}/prefix/bin/metacodes", .{root});
        errdefer a.free(real_exe);
        try tmp.dir.symLink(io, real_exe, "elsewhere/metacodes", .{});
        const link = try std.fmt.allocPrint(a, "{s}/elsewhere/metacodes", .{root});
        errdefer a.free(link);
        const rg = try std.fmt.allocPrint(a, "{s}/prefix/bin/rg", .{root});
        errdefer a.free(rg);
        const formal = try std.fmt.allocPrint(a, "{s}/prefix/libexec/metacodes/metacodes-formal-kernel", .{root});
        errdefer a.free(formal);
        const project = try std.fmt.allocPrint(a, "{s}/prefix/libexec/metacodes/metacodes-project-kernel", .{root});
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

fn runProbe(a: std.mem.Allocator, exe: []const u8) ![]u8 {
    const exe_z = try a.dupeZ(u8, exe);
    defer a.free(exe_z);
    const argv = [_]?[*:0]const u8{ exe_z.ptr, null };
    return cc.tools_common.spawnCaptureStdoutAbortableTimed(argv[0..], a, null, 30_000);
}

test "adjacent rg and kernels resolve for a process started through a symlink in another directory" {
    if (is_windows) return error.SkipZigTest; // symlink 需特权;Windows 解析走 _fullpath
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const layout = try Layout.stage(a, &tmp);
    defer layout.deinit(a);

    const output = try runProbe(a, layout.link);
    defer a.free(output);

    // 前提先钉死:进程确实是经 symlink 起的,且物理路径解回 prefix。macOS 的 invoked 是
    // symlink 自身(bug 的成因);Linux /proc/self/exe 由内核解好,invoked 已是物理路径——
    // 两者都合法,但 physical 必须是 prefix 里的真文件。
    const invoked = field(output, "invoked") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.eql(u8, invoked, layout.link) or std.mem.eql(u8, invoked, layout.real_exe));
    if (builtin.os.tag == .macos) try std.testing.expectEqualStrings(layout.link, invoked);
    try std.testing.expectEqualStrings(layout.real_exe, field(output, "physical") orelse return error.TestUnexpectedResult);

    // 三个相邻解析器都落到 <prefix>,且 rg 是 adjacent 命中而非 PATH 兜底。
    try std.testing.expectEqualStrings(layout.rg, field(output, "rg") orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("adjacent", field(output, "rg_source") orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings(layout.formal, field(output, "formal") orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings(layout.project, field(output, "project") orelse return error.TestUnexpectedResult);
}

test "the same install started through its real path resolves identically" {
    // 对照组:symlink 与真路径启动必须给出同一组答案(修法是统一入口,不是给 symlink 开特例)。
    if (is_windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const layout = try Layout.stage(a, &tmp);
    defer layout.deinit(a);

    const via_link = try runProbe(a, layout.link);
    defer a.free(via_link);
    const via_real = try runProbe(a, layout.real_exe);
    defer a.free(via_real);
    for ([_][]const u8{ "physical", "rg", "rg_source", "formal", "project" }) |key| {
        try std.testing.expectEqualStrings(field(via_real, key).?, field(via_link, key).?);
    }
    try std.testing.expectEqualStrings(layout.real_exe, field(via_real, "invoked").?);
}
