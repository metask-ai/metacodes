//! 粘贴检测 + 大文本外部存储。
//!
//! 终端 bracketed paste mode 下，粘贴内容被 ESC[200~ ... ESC[201~ 包裹。
//! 驱动循环（loop.zig）收集这段字节后调 `process`：
//!   - 小粘贴（行数/字节数都在阈值内）→ 原样内联插入。
//!   - 大粘贴 → 写到 ~/.metacodes/pastes/<n>.txt，buffer 里只放占位符
//!     `[Pasted text #N +M lines]`，避免大段文字吃满 prompt + 终端刷屏。
//!
//! 占位符里的 #N 是本 session 内递增的粘贴编号；+M 是行数。
//! 占位符 → 真实内容的还原由调用方在提交时做（expandPlaceholders）。

const std = @import("std");
const pfs = @import("platform").fs;

/// 触发外部存储的阈值：行数 > 此值 或 字节数 > 此值。
/// 真 cc v2.1.172 实测(record_input_behavior.py threshold.txt):≤3 行内联,≥4 行转占位符
/// → 阈值 3(`> 3` 即 ≥4 行)。
pub const LINE_THRESHOLD: usize = 3;
pub const BYTE_THRESHOLD: usize = 1600;

pub fn isLarge(text: []const u8) bool {
    if (text.len > BYTE_THRESHOLD) return true;
    return countLines(text) > LINE_THRESHOLD;
}

fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var n: usize = 1;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// 把一段粘贴写到 ~/.metacodes/pastes/<id>.txt。返回占位符（owned）。
/// id 由调用方维护（session 内递增）。失败时返回 null → 调用方退回内联。
pub fn store(allocator: std.mem.Allocator, home: []const u8, id: usize, text: []const u8) !?[]u8 {
    const dir_z = try std.fmt.allocPrintSentinel(allocator, "{s}/.metacodes/pastes", .{home}, 0);
    defer allocator.free(dir_z);
    // mkdir -p：先建 .metacodes，再建 pastes
    const parent_z = try std.fmt.allocPrintSentinel(allocator, "{s}/.metacodes", .{home}, 0);
    defer allocator.free(parent_z);
    _ = pfs.mkdir(parent_z.ptr, 0o700);
    _ = pfs.mkdir(dir_z.ptr, 0o700);

    const path_z = try std.fmt.allocPrintSentinel(allocator, "{s}/.metacodes/pastes/{d}.txt", .{ home, id }, 0);
    defer allocator.free(path_z);

    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return null;
    defer _ = pfs.close(fd);
    var pos: usize = 0;
    while (pos < text.len) {
        const n = pfs.write(fd, text[pos..][0 .. text.len - pos]);
        if (n <= 0) return null;
        pos += @intCast(n);
    }

    // 占位符计数对齐真 cc:+M 的 M = 总行数 − 1(4 行→+3,20 行→+19)。
    return try std.fmt.allocPrint(allocator, "[Pasted text #{d} +{d} lines]", .{ id, countLines(text) -| 1 });
}

/// 读回某个粘贴文件的内容（提交时 expand 用）。
pub fn load(allocator: std.mem.Allocator, home: []const u8, id: usize) !?[]u8 {
    const path_z = try std.fmt.allocPrintSentinel(allocator, "{s}/.metacodes/pastes/{d}.txt", .{ home, id }, 0);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = pfs.close(fd);
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = pfs.readZ(fd, &chunk) catch break;
        if (n == 0) break;
        try buf.appendSlice(allocator, chunk[0..@intCast(n)]);
    }
    return try buf.toOwnedSlice(allocator);
}

/// 把一行里的所有 `[Pasted text #N +M lines]` 占位符替换为对应粘贴文件的真实内容。
/// 无占位符则返回 input 的 dupe。提交前调用，让模型收到完整文本。
pub fn expandPlaceholders(allocator: std.mem.Allocator, home: []const u8, input: []const u8) ![]u8 {
    const marker = "[Pasted text #";
    if (std.mem.indexOf(u8, input, marker) == null) return try allocator.dupe(u8, input);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], marker)) {
            // 解析 #N
            const num_start = i + marker.len;
            var j = num_start;
            while (j < input.len and std.ascii.isDigit(input[j])) : (j += 1) {}
            // 找占位符结束 ']'
            const close = std.mem.indexOfScalarPos(u8, input, i, ']') orelse {
                try out.append(allocator, input[i]);
                i += 1;
                continue;
            };
            const id = std.fmt.parseInt(usize, input[num_start..j], 10) catch {
                try out.append(allocator, input[i]);
                i += 1;
                continue;
            };
            if (try load(allocator, home, id)) |content| {
                defer allocator.free(content);
                try out.appendSlice(allocator, content);
            } else {
                // 文件丢了 → 保留占位符原样
                try out.appendSlice(allocator, input[i .. close + 1]);
            }
            i = close + 1;
        } else {
            try out.append(allocator, input[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "isLarge by lines" {
    try testing.expect(!isLarge("a\nb\nc"));
    var buf: [200]u8 = undefined;
    @memset(&buf, '\n');
    try testing.expect(isLarge(&buf));
}

test "isLarge boundary: 3 inline, 4 large (cc v2.1.172)" {
    // 真 cc 实测:≤3 行内联,≥4 行转占位符。
    try testing.expect(!isLarge("a\nb\nc")); // 3 行
    try testing.expect(isLarge("a\nb\nc\nd")); // 4 行
}

test "isLarge by bytes" {
    const big = "x" ** (BYTE_THRESHOLD + 1);
    try testing.expect(isLarge(big));
    try testing.expect(!isLarge("short"));
}

test "store + load + expand round trip" {
    const a = testing.allocator;
    var home_buf: [512]u8 = undefined;
    const home = @import("../util/fs.zig").testing.perPidDir(&home_buf, "cc-zig-paste-home");
    _ = pfs.mkdir(home.ptr, 0o700);
    defer @import("../util/fs.zig").testing.rmrfBestEffort(home);
    defer {
        // cleanup
        var pz: [256]u8 = undefined;
        const p = std.fmt.bufPrintZ(&pz, "{s}/.metacodes/pastes/1.txt", .{home}) catch unreachable;
        pfs.unlinkPath(p.ptr) catch {};
    }

    const text = "line A\nline B\nline C\n";
    const placeholder = (try store(a, home, 1, text)).?;
    defer a.free(placeholder);
    try testing.expect(std.mem.indexOf(u8, placeholder, "[Pasted text #1") != null);

    const loaded = (try load(a, home, 1)).?;
    defer a.free(loaded);
    try testing.expectEqualStrings(text, loaded);

    // expand placeholder back to content
    const line = try std.fmt.allocPrint(a, "before {s} after", .{placeholder});
    defer a.free(line);
    const expanded = try expandPlaceholders(a, home, line);
    defer a.free(expanded);
    try testing.expect(std.mem.indexOf(u8, expanded, "line A\nline B\nline C") != null);
    try testing.expect(std.mem.indexOf(u8, expanded, "before ") != null);
    try testing.expect(std.mem.indexOf(u8, expanded, " after") != null);
}

test "store placeholder count = lines - 1 (cc v2.1.172)" {
    const a = testing.allocator;
    var home_buf: [512]u8 = undefined;
    const home = @import("../util/fs.zig").testing.perPidDir(&home_buf, "cc-zig-paste-home");
    _ = pfs.mkdir(home.ptr, 0o700);
    defer @import("../util/fs.zig").testing.rmrfBestEffort(home);
    defer {
        var pz: [256]u8 = undefined;
        inline for (.{ 4, 20 }) |id| {
            const p = std.fmt.bufPrintZ(&pz, "{s}/.metacodes/pastes/{d}.txt", .{ home, id }) catch unreachable;
            pfs.unlinkPath(p.ptr) catch {};
        }
    }

    // 4 行 → "+3 lines"
    const four = "L0\nL1\nL2\nL3";
    const ph4 = (try store(a, home, 4, four)).?;
    defer a.free(ph4);
    try testing.expect(std.mem.indexOf(u8, ph4, "+3 lines") != null);

    // 20 行 → "+19 lines"
    var buf: [200]u8 = undefined;
    var w: usize = 0;
    inline for (0..20) |i| {
        const seg = std.fmt.bufPrint(buf[w..], "R{d}\n", .{i}) catch unreachable;
        w += seg.len;
    }
    const ph20 = (try store(a, home, 20, buf[0 .. w - 1])).?; // 去掉末尾 \n → 恰 20 行
    defer a.free(ph20);
    try testing.expect(std.mem.indexOf(u8, ph20, "+19 lines") != null);
}

test "expandPlaceholders no marker returns dupe" {
    const a = testing.allocator;
    const r = try expandPlaceholders(a, "/tmp", "plain text");
    defer a.free(r);
    try testing.expectEqualStrings("plain text", r);
}

test "expandPlaceholders missing file keeps placeholder" {
    const a = testing.allocator;
    const r = try expandPlaceholders(a, "/tmp/cc-zig-nonexistent-home", "[Pasted text #999 +3 lines]");
    defer a.free(r);
    try testing.expectEqualStrings("[Pasted text #999 +3 lines]", r);
}
