//! 粘贴检测 + 大文本外部存储。
//!
//! 终端 bracketed paste mode 下，粘贴内容被 ESC[200~ ... ESC[201~ 包裹。
//! 驱动循环（loop.zig）收集这段字节后调 `process`：
//!   - 小粘贴（行数/字节数都在阈值内）→ 原样内联插入。
//!   - 大粘贴 → 写到 <state_root>/pastes/<n>.txt，buffer 里只放占位符
//!     `[Pasted text #N +M lines]`，避免大段文字吃满 prompt + 终端刷屏。
//!
//! 占位符 → 真实内容的还原由调用方在提交时做（expandPlaceholders）。

const std = @import("std");
const pfs = @import("metacodes-internal").platform.fs;
const pdir = @import("metacodes-internal").platform.dir;
const LineEditor = @import("input.zig").LineEditor;

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

/// 把一段粘贴写到 <state_root>/pastes/<id>.txt。返回占位符（owned）。
/// 失败时返回 null → 调用方退回内联。
pub fn store(allocator: std.mem.Allocator, state_root: []const u8, text: []const u8) !?[]u8 {
    const dir_z = try std.fmt.allocPrintSentinel(allocator, "{s}/pastes", .{state_root}, 0);
    defer allocator.free(dir_z);
    // mkdir:先建状态根(单层),再建 pastes
    const parent_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{state_root}, 0);
    defer allocator.free(parent_z);
    _ = pfs.mkdir(parent_z.ptr, 0o700);
    _ = pfs.mkdir(dir_z.ptr, 0o700);

    const file = (try claim(allocator, dir_z, highestId(dir_z) +| 1)) orelse return null;
    defer allocator.free(file.path);
    var pos: usize = 0;
    while (pos < text.len) {
        const n = pfs.write(file.fd, text[pos..]); // no EINTR: regular file
        if (n <= 0) {
            pfs.close(file.fd);
            pfs.unlinkPath(file.path.ptr) catch {};
            return null;
        }
        pos += @intCast(n);
    }
    pfs.close(file.fd);

    // 占位符计数对齐真 cc:+M 的 M = 总行数 − 1(4 行→+3,20 行→+19)。
    return try std.fmt.allocPrint(allocator, "[Pasted text #{d} +{d} lines]", .{ file.id, countLines(text) -| 1 });
}

const ClaimedFile = struct {
    id: usize,
    fd: c_int,
    path: [:0]u8,
};

const max_claim_attempts = 64;

fn claim(allocator: std.mem.Allocator, dir_z: [:0]const u8, first_id: usize) !?ClaimedFile {
    var id = first_id;
    for (0..max_claim_attempts) |_| {
        const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{d}.txt", .{ dir_z, id }, 0);
        const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
        if (fd >= 0) return .{ .id = id, .fd = fd, .path = path };
        const taken = pfs.lastErrnoIs(.EXIST);
        allocator.free(path);
        if (!taken) return null;
        id +|= 1;
    }
    return null;
}

fn highestId(dir_z: [:0]const u8) usize {
    var it = pdir.open(dir_z.ptr) orelse return 0;
    defer pdir.close(&it);
    var highest: usize = 0;
    while (pdir.next(&it)) |entry| {
        if (fileId(entry.name)) |id| highest = @max(highest, id);
    }
    return highest;
}

fn fileId(name: []const u8) ?usize {
    if (!std.mem.endsWith(u8, name, ".txt")) return null;
    const digits = name[0 .. name.len - ".txt".len];
    if (digits.len == 0) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseUnsigned(usize, digits, 10) catch null;
}

/// 读回某个粘贴文件的内容（提交时 expand 用）。
pub fn load(allocator: std.mem.Allocator, state_root: []const u8, id: usize) !?[]u8 {
    const path_z = try std.fmt.allocPrintSentinel(allocator, "{s}/pastes/{d}.txt", .{ state_root, id }, 0);
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
pub fn expandPlaceholders(allocator: std.mem.Allocator, state_root: []const u8, input: []const u8) ![]u8 {
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
            if (try load(allocator, state_root, id)) |content| {
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

/// 插入一段粘贴的文字:小粘贴内联;大粘贴存 ~/.metacodes/pastes/<N>.txt 并插入占位符。
pub fn insert(
    editor: *LineEditor,
    allocator: std.mem.Allocator,
    state_root: []const u8,
    text: []const u8,
) !void {
    if (text.len == 0) return;

    if (isLarge(text)) {
        if (state_root.len > 0) {
            if (store(allocator, state_root, text) catch null) |placeholder| {
                defer allocator.free(placeholder);
                try insertAtCursor(editor, allocator, placeholder);
                return;
            }
        }
        // store 失败 / 无 HOME → 退回内联
    }
    try insertAtCursor(editor, allocator, text);
}

/// 在光标处插入一段文本，光标移到插入末尾。
fn insertAtCursor(editor: *LineEditor, allocator: std.mem.Allocator, text: []const u8) !void {
    const line = editor.view();
    var nl = std.ArrayList(u8).empty;
    defer nl.deinit(allocator);
    try nl.appendSlice(allocator, line[0..editor.cursor]);
    try nl.appendSlice(allocator, text);
    try nl.appendSlice(allocator, line[editor.cursor..]);
    const new_cursor = editor.cursor + text.len;
    try editor.setLine(nl.items);
    editor.cursor = new_cursor;
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
    const state_root = @import("metacodes-internal").util.fs.testing.perPidDir(&home_buf, "cc-zig-paste-state_root");
    _ = pfs.mkdir(state_root.ptr, 0o700);
    defer @import("metacodes-internal").util.fs.testing.rmrfBestEffort(state_root);
    defer {
        // cleanup
        var pz: [256]u8 = undefined;
        const p = std.fmt.bufPrintZ(&pz, "{s}/pastes/1.txt", .{state_root}) catch unreachable;
        pfs.unlinkPath(p.ptr) catch {};
    }

    const text = "line A\nline B\nline C\n";
    const placeholder = (try store(a, state_root, text)).?;
    defer a.free(placeholder);
    try testing.expect(std.mem.indexOf(u8, placeholder, "[Pasted text #1") != null);

    const loaded = (try load(a, state_root, 1)).?;
    defer a.free(loaded);
    try testing.expectEqualStrings(text, loaded);

    // expand placeholder back to content
    const line = try std.fmt.allocPrint(a, "before {s} after", .{placeholder});
    defer a.free(line);
    const expanded = try expandPlaceholders(a, state_root, line);
    defer a.free(expanded);
    try testing.expect(std.mem.indexOf(u8, expanded, "line A\nline B\nline C") != null);
    try testing.expect(std.mem.indexOf(u8, expanded, "before ") != null);
    try testing.expect(std.mem.indexOf(u8, expanded, " after") != null);
}

test "store placeholder count = lines - 1 (cc v2.1.172)" {
    const a = testing.allocator;
    var home_buf: [512]u8 = undefined;
    const state_root = @import("metacodes-internal").util.fs.testing.perPidDir(&home_buf, "cc-zig-paste-state_root");
    _ = pfs.mkdir(state_root.ptr, 0o700);
    defer @import("metacodes-internal").util.fs.testing.rmrfBestEffort(state_root);
    defer {
        var pz: [256]u8 = undefined;
        inline for (.{ 1, 2 }) |id| {
            const p = std.fmt.bufPrintZ(&pz, "{s}/pastes/{d}.txt", .{ state_root, id }) catch unreachable;
            pfs.unlinkPath(p.ptr) catch {};
        }
    }

    // 4 行 → "+3 lines"
    const four = "L0\nL1\nL2\nL3";
    const ph4 = (try store(a, state_root, four)).?;
    defer a.free(ph4);
    try testing.expect(std.mem.indexOf(u8, ph4, "+3 lines") != null);

    // 20 行 → "+19 lines"
    var buf: [200]u8 = undefined;
    var w: usize = 0;
    inline for (0..20) |i| {
        const seg = std.fmt.bufPrint(buf[w..], "R{d}\n", .{i}) catch unreachable;
        w += seg.len;
    }
    const ph20 = (try store(a, state_root, buf[0 .. w - 1])).?; // 去掉末尾 \n → 恰 20 行
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
    const r = try expandPlaceholders(a, "/tmp/cc-zig-nonexistent-state_root", "[Pasted text #999 +3 lines]");
    defer a.free(r);
    try testing.expectEqualStrings("[Pasted text #999 +3 lines]", r);
}

fn freshStateRoot(buf: []u8) [:0]const u8 {
    const root = @import("metacodes-internal").util.fs.testing.uniqueDir(buf, "cc-zig-paste-numbers");
    _ = pfs.mkdir(root.ptr, 0o700);
    return root;
}

fn writePasteFile(state_root: []const u8, name: []const u8, bytes: []const u8) !void {
    var dir_buf: [600]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "{s}/pastes", .{state_root});
    _ = pfs.mkdir(dir.ptr, 0o700);
    var path_buf: [700]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = bytes });
}

fn expectExpands(state_root: []const u8, line: []const u8, want: []const u8) !void {
    const got = try expandPlaceholders(testing.allocator, state_root, line);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "a paste stored while another one waits in the same state root gets the next number and leaves it whole (#764)" {
    const a = testing.allocator;
    var buf: [512]u8 = undefined;
    const state_root = freshStateRoot(&buf);
    defer @import("metacodes-internal").util.fs.testing.rmrfBestEffort(state_root);

    const waiting = (try store(a, state_root, "A0\nA1\nA2\nA3\nA4")).?;
    defer a.free(waiting);
    try testing.expectEqualStrings("[Pasted text #1 +4 lines]", waiting);

    const sent_first = (try store(a, state_root, "B0\nB1\nB2\nB3\nB4\nB5")).?;
    defer a.free(sent_first);
    try testing.expectEqualStrings("[Pasted text #2 +5 lines]", sent_first);

    try expectExpands(state_root, sent_first, "B0\nB1\nB2\nB3\nB4\nB5");
    try expectExpands(state_root, waiting, "A0\nA1\nA2\nA3\nA4");
}

test "a number another process takes between the scan and the create moves the paste on to the next free one" {
    const a = testing.allocator;
    var buf: [512]u8 = undefined;
    const state_root = freshStateRoot(&buf);
    defer @import("metacodes-internal").util.fs.testing.rmrfBestEffort(state_root);
    try writePasteFile(state_root, "1.txt", "TAKEN_ONE");
    try writePasteFile(state_root, "2.txt", "TAKEN_TWO");

    var dir_buf: [600]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "{s}/pastes", .{state_root});
    const file = (try claim(a, dir, 1)).?;
    defer a.free(file.path);
    pfs.close(file.fd);

    try testing.expectEqual(@as(usize, 3), file.id);
    try expectExpands(state_root, "[Pasted text #1 +0 lines]", "TAKEN_ONE");
    try expectExpands(state_root, "[Pasted text #2 +0 lines]", "TAKEN_TWO");
}

test "pastes an earlier version stored keep expanding and new pastes are numbered after the highest of them" {
    const a = testing.allocator;
    var buf: [512]u8 = undefined;
    const state_root = freshStateRoot(&buf);
    defer @import("metacodes-internal").util.fs.testing.rmrfBestEffort(state_root);
    try writePasteFile(state_root, "3.txt", "OLD_THREE\nOLD_THREE_B\nOLD_THREE_C");
    try writePasteFile(state_root, "7.txt", "OLD_SEVEN\nOLD_SEVEN_B\nOLD_SEVEN_C");
    for ([_][]const u8{ "notes.txt", "12.txt.bak", "x99.txt", "99x.txt", "1_00.txt", ".txt", "40" }) |name|
        try writePasteFile(state_root, name, "not a paste");

    const placeholder = (try store(a, state_root, "N0\nN1\nN2\nN3")).?;
    defer a.free(placeholder);

    try testing.expectEqualStrings("[Pasted text #8 +3 lines]", placeholder);
    try expectExpands(state_root, "[Pasted text #3 +2 lines]", "OLD_THREE\nOLD_THREE_B\nOLD_THREE_C");
    try expectExpands(state_root, "[Pasted text #7 +2 lines]", "OLD_SEVEN\nOLD_SEVEN_B\nOLD_SEVEN_C");
    try expectExpands(state_root, placeholder, "N0\nN1\nN2\nN3");
}
