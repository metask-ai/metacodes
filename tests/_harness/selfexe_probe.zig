//! selfexe_probe —— 相邻产物解析的进程级探针(测试专用,`zig-out/bin/selfexe_probe`)。
//!
//! 组件测试把本二进制**复制**成 `<prefix>/bin/metacodes`,在别处建 symlink 指过来,再经
//! symlink 启动它。它以 release 布局(env → adjacent → PATH)跑一遍 toolchain 的三个相邻
//! 解析器并逐行打印结果。这是唯一能证明 OS 真把 symlink 路径报给进程(macOS
//! `_NSGetExecutablePath`)而解析器仍落到物理 <prefix> 的证据;进程内的 seam 测试只能模拟。
//!
//! 输出(每行 `key=value`,缺席为 `-`):
//!   invoked=<selfExePath>            OS 报告的被调用路径
//!   physical=<selfExeRealPath>       解 symlink 后
//!   rg=<path> rg_source=<source>     ripgrepResolution
//!   formal=<path> project=<path>     kernelAdjacentPath
//!
//! RG_BIN 在解析前被清掉:探针量的是 adjacent 一步,不是调用方环境里的覆盖。
const std = @import("std");
const platform = @import("platform");
const toolchain = @import("toolchain");

pub fn main() !void {
    // 清掉 env 覆盖;失败则 fail closed(否则 rg 行会静默变成 env 命中)。
    if (std.c.getenv("RG_BIN") != null and !platform.paths.unsetEnvChecked("RG_BIN")) return error.CannotUnsetRgBin;
    toolchain.setLayout(.release);

    var out_buf: [8 * std.fs.max_path_bytes]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&out_buf);
    const w = &fbs;

    var invoked_buf: [std.fs.max_path_bytes]u8 = undefined;
    try w.print("invoked={s}\n", .{platform.paths.selfExePath(&invoked_buf) orelse "-"});
    var physical_buf: [std.fs.max_path_bytes]u8 = undefined;
    try w.print("physical={s}\n", .{platform.paths.selfExeRealPath(&physical_buf) orelse "-"});
    if (toolchain.ripgrepResolution()) |rg| {
        try w.print("rg={s}\nrg_source={s}\n", .{ rg.path, @tagName(rg.source) });
    } else |_| {
        try w.print("rg=-\nrg_source=-\n", .{});
    }
    try w.print("formal={s}\n", .{toolchain.kernelAdjacentPath(.formal) orelse "-"});
    try w.print("project={s}\n", .{toolchain.kernelAdjacentPath(.project) orelse "-"});

    const written = fbs.buffered();
    var off: usize = 0;
    while (off < written.len) {
        const n = platform.fs.write(1, written[off..]);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}
