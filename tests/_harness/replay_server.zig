//! e2e replay 辅助:从 cassette 目录起一个 MockServer.startCassette,打印
//! base_url 到 stdout(供 shell 捕获),然后阻塞直到收到 SIGTERM/SIGINT。
//!
//! 用法:replay_server <cassette_dir>
//!   stdout 首行:http://127.0.0.1:<port>/v1/messages
//!   把它喂给 metacodes --base-url → 确定性回放该场景的真实模型响应(不连网络)。

const std = @import("std");
const pfs = @import("platform").fs;
const psync = @import("platform").sync;
const harness = @import("harness");
const Cassette = @import("cassette").Cassette;

pub fn main(init: std.process.Init) !void {
    const a = std.heap.page_allocator;

    // argv[1] = cassette 目录(走 std.process.Init,与主二进制同入口约定)。
    // iterateAllocator:Windows 上 iterate 是 @compileError(须 allocator 版解析 WTF-8 命令行)。
    var args = std.process.Args.iterateAllocator(init.minimal.args, a) catch std.process.exit(2);
    defer args.deinit();
    _ = args.next(); // argv[0]
    const dir_arg = args.next() orelse {
        const msg = "usage: replay_server <cassette_dir>\n";
        _ = pfs.write(2, msg);
        std.process.exit(2);
    };
    const dir: []const u8 = dir_arg;

    var cas = Cassette.load(a, dir) catch |e| {
        std.debug.print("load cassette {s} failed: {s}\n", .{ dir, @errorName(e) });
        std.process.exit(1);
    };
    defer cas.deinit();

    if (cas.bodies.len == 0) {
        std.debug.print("cassette {s} 为空(无 sse-*.txt)\n", .{dir});
        std.process.exit(1);
    }

    var srv = try harness.MockServer.startCassette(cas.bodies, 0);
    defer srv.stop();

    // 打印 base_url(首行,shell 捕获)
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}/v1/messages\n", .{srv.port});
    _ = pfs.write(1, line);

    // 阻塞直到被杀(shell 跑完场景后 kill 本进程)
    while (true) {
        psync.sleepMs(1000); // 可移植(POSIX nanosleep / Windows Sleep)
    }
}
