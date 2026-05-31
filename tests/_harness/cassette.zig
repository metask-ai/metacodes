//! Cassette 加载器(Stage 7,record/replay)。
//!
//! `--record <dir>` 录出 `<dir>/sse-001.txt`, `sse-002.txt`, ... (每轮一个 SSE 响应)。
//! 本模块把它们按序读回 `[]const []const u8`,喂给 MockServer.startCassette 回放。
//!
//! 注意:本仓库的 std 是裁剪版(无 std.fs.cwd),全程用 libc(opendir/readdir/open)。
//!
//! 用法:
//!   var cas = try Cassette.load(allocator, "runs/<ts>/<场景>/cassette");
//!   defer cas.deinit();
//!   var srv = try MockServer.startCassette(cas.bodies, 0);

const std = @import("std");

// libc dirent(macOS/Linux 通用最小声明)。
const DIR = opaque {};
extern "c" fn opendir(name: [*:0]const u8) ?*DIR;
extern "c" fn readdir(dirp: *DIR) ?*dirent;
extern "c" fn closedir(dirp: *DIR) c_int;

const dirent = extern struct {
    d_ino: u64,
    d_seekoff: u64,
    d_reclen: u16,
    d_namlen: u16,
    d_type: u8,
    d_name: [1024]u8,
};

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

        const dp = opendir(@ptrCast(&pbuf)) orelse return error.OpenDirFailed;
        defer _ = closedir(dp);

        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| allocator.free(n);
            names.deinit(allocator);
        }
        while (readdir(dp)) |ent| {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.d_name)), 0);
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
    const fd = std.c.open(@ptrCast(full.ptr), std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);
    var all: std.ArrayList(u8) = .empty;
    errdefer all.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try all.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return try all.toOwnedSlice(allocator);
}
