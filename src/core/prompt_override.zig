//! 提示词运行时覆盖旁路(A/B 实验机制 + 可复用产品能力)。
//!
//! 每个可调提示词片段有一个**命名 slot**(大写,如 "USING_TOOLS" / "TOOL_DESC_CODEMAP")。
//! 运行时若设了环境变量 `METACODES_PROMPT_OVERRIDE_<SLOT>`,就用其内容(base64 编码)
//! 覆盖编译进二进制的默认文本。这样调提示词无需重编译——Python A/B 框架把 N 个 variant
//! 当 env 喂进同一个二进制,秒级切换。
//!
//! 为什么 base64:提示词含换行、引号、反引号,裸塞进 shell env 会被撕裂或需复杂转义。
//! base64 让任意字节安全过 env 边界。
//!
//! 安全/边界:
//! - 仅当 env 存在才覆盖,**默认行为完全不变**(零回归风险)。
//! - 返回的 slice 挂在传入的 allocator(调用方用 session arena,生命周期同其它 section)。
//! - env 未设 / base64 解码失败 / 空 → 一律返回 null(视作未覆盖,绝不崩)。

const std = @import("std");

// std.c 在本 Zig 版本只导出 getenv,没导出 setenv/unsetenv(测试设环境用)。
// 直接 extern 声明 POSIX 原型。
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// env 变量名前缀。完整名 = PREFIX ++ <SLOT>。
const PREFIX = "METACODES_PROMPT_OVERRIDE_";

/// slot 名上限(env 后缀);够长覆盖所有现实 slot 名。
const MAX_SLOT_LEN = 64;

/// 查 slot 的覆盖文本。命中返回 base64 解码后的 owned slice(调用方负责释放/由 arena 管),
/// 否则返回 null。
///
/// slot:大写 slot 名(不含前缀),如 "USING_TOOLS"。调用方传字面量即可。
pub fn lookup(allocator: std.mem.Allocator, slot: []const u8) ?[]u8 {
    if (slot.len == 0 or slot.len > MAX_SLOT_LEN) return null;

    // 拼 env 变量名(栈缓冲 + NUL 结尾,供 std.c.getenv)。
    var name_buf: [PREFIX.len + MAX_SLOT_LEN + 1]u8 = undefined;
    const name = std.fmt.bufPrintZ(&name_buf, "{s}{s}", .{ PREFIX, slot }) catch return null;

    const raw_c = std.c.getenv(name.ptr) orelse return null;
    const b64 = std.mem.span(raw_c);
    if (b64.len == 0) return null;

    const dec = std.base64.standard.Decoder;
    const out_len = dec.calcSizeForSlice(b64) catch return null;
    const out = allocator.alloc(u8, out_len) catch return null;
    dec.decode(out, b64) catch {
        allocator.free(out);
        return null;
    };
    if (out.len == 0) {
        allocator.free(out);
        return null;
    }
    return out;
}

// ============================================================================
// Tests
// ============================================================================
const testing = std.testing;

test "lookup returns null when env unset" {
    // 用一个几乎不可能被设的 slot 名。
    const r = lookup(testing.allocator, "DEFINITELY_UNSET_SLOT_XYZ");
    try testing.expect(r == null);
}

test "lookup rejects oversized / empty slot" {
    try testing.expect(lookup(testing.allocator, "") == null);
    const big = "X" ** (MAX_SLOT_LEN + 1);
    try testing.expect(lookup(testing.allocator, big) == null);
}

test "lookup decodes base64 env when set" {
    // setenv 真改进程环境;用独特 slot 名避免污染其它测试。
    const slot = "UNIT_TEST_SLOT";
    const plain = "hello\nworld \"quoted\" `tick`";
    // base64 编码 plain
    const enc = std.base64.standard.Encoder;
    var b64_buf: [128]u8 = undefined;
    const b64 = b64_buf[0..enc.calcSize(plain.len)];
    _ = enc.encode(b64, plain);
    // NUL 结尾给 setenv
    var name_buf: [128]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "{s}{s}", .{ PREFIX, slot });
    var val_buf: [160]u8 = undefined;
    const val = try std.fmt.bufPrintZ(&val_buf, "{s}", .{b64});

    _ = setenv(name.ptr, val.ptr, 1);
    defer _ = unsetenv(name.ptr);

    const got = lookup(testing.allocator, slot) orelse return error.ExpectedOverride;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(plain, got);
}

test "lookup returns null on invalid base64" {
    const slot = "UNIT_TEST_BADB64";
    var name_buf: [128]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "{s}{s}", .{ PREFIX, slot });
    _ = setenv(name.ptr, "!!!not-base64!!!", 1);
    defer _ = unsetenv(name.ptr);
    try testing.expect(lookup(testing.allocator, slot) == null);
}
