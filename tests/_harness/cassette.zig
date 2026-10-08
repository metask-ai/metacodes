//! Cassette 加载器(Stage 7,record/replay)。
//!
//! `--record <dir>` 录出 `<dir>/sse-001.txt`, `sse-002.txt`, ... (每轮一个 SSE 响应)。
//! 本模块把它们按序读回 `[]const []const u8`,喂给 MockServer.startCassette 回放。
//!
//! 目录遍历走 `platform.dir`,读文件走 `platform.fs`。这里曾手写 macOS 布局的 libc
//! `dirent`(`d_seekoff`/`d_namlen`/`d_name[1024]`):Linux 上文件名偏移错位,一个
//! `sse-*.txt` 都认不出,replay_server 在 Linux 上从未工作过——依赖它的 TTY 用例
//! 只因"未就绪就 return"才显得通过(#222)。
//!
//! 用法:
//!   var cas = try Cassette.load(allocator, "runs/<ts>/<场景>/cassette");
//!   defer cas.deinit();
//!   var srv = try MockServer.startCassette(cas.bodies, 0);

const std = @import("std");
const pfs = @import("platform").fs; // 可移植文件 IO(std.c.open 的 O 在 Windows 是 void)
const pdir = @import("platform").dir;

pub const Cassette = struct {
    allocator: std.mem.Allocator,
    /// 各轮 SSE 响应原始字节(sse-NNN.txt 顺序)。borrowed 给 startCassette。
    bodies: []const []const u8,
    storage: [][]u8,

    /// 从目录加载所有 sse-*.txt(按文件名排序 = 轮次序)。
    pub fn load(allocator: std.mem.Allocator, dir_path: []const u8) !Cassette {
        var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (dir_path.len + 1 > pbuf.len) return error.PathTooLong;
        @memcpy(pbuf[0..dir_path.len], dir_path);
        pbuf[dir_path.len] = 0;

        var it = pdir.open(@ptrCast(&pbuf)) orelse return error.OpenDirFailed;
        defer pdir.close(&it);

        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| allocator.free(n);
            names.deinit(allocator);
        }
        while (pdir.next(&it)) |ent| {
            const name = ent.name;
            if (!std.mem.startsWith(u8, name, "sse-")) continue;
            if (!std.mem.endsWith(u8, name, ".txt")) continue;
            try names.append(allocator, try allocator.dupe(u8, name));
        }
        std.mem.sort([]u8, names.items, {}, struct {
            fn lt(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);

        var storage = try allocator.alloc([]u8, names.items.len);
        errdefer allocator.free(storage);
        for (names.items, 0..) |name, i| {
            storage[i] = try readFileAlloc(allocator, dir_path, name);
        }

        const bodies = try allocator.alloc([]const u8, storage.len);
        for (storage, 0..) |s, i| bodies[i] = s;

        return .{ .allocator = allocator, .bodies = bodies, .storage = storage };
    }

    pub fn deinit(self: *Cassette) void {
        for (self.storage) |s| self.allocator.free(s);
        self.allocator.free(self.storage);
        self.allocator.free(self.bodies);
    }
};

fn readFileAlloc(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const full = try std.fmt.bufPrint(&pbuf, "{s}/{s}\x00", .{ dir, name });
    const fd = pfs.open(@ptrCast(full.ptr), .{ .ACCMODE = .RDONLY }, 0);
    if (fd < 0) return error.FileNotFound;
    defer pfs.close(fd);
    var all: std.ArrayList(u8) = .empty;
    errdefer all.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &buf);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try all.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return try all.toOwnedSlice(allocator);
}
