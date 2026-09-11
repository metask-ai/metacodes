//! 进程级"最近一次 API 错误现场"记录。
//!
//! 病根:Zig error 无 payload,HTTP 400 的 body(如 "Failed to parse request body")
//! 在 client 层只进日志文件,TUI 用户面前塌缩成"重试耗尽/后端错误/上下文超限"三选一
//! 猜谜文案——排障被迫抓包(2026-07-12 NUL 字节 bug 实录,定位靠 --record)。
//! 此模块把最后一次错误现场带到 UI,错误路径的信息不许在层间蒸发。
//!
//! 写侧:client.logErrorBody(HTTP 状态错误)、client 重试耗尽出口(连接类错误)、
//!       stream error_event(SSE 错误帧)。后写覆盖先写(最后一次错误最接近用户看到的失败);
//!       请求成功(HTTP 200)即 clear,陈旧现场不许活过一次成功。
//! 读侧:repl/loop .api_error 分支 take() 消费——读后清空,旧错不跨轮陈述。
//! headless 不需要:log.errId 直接落 stderr,现场本来可见。
//!
//! 写侧还有:client.reportHeadStall / reportBodyStall(空闲监视 shutdown 连接,2026-09-11 起
//!       正文阶段 stall 也记,TUI 打"正文空闲超时: N ms 内无任何字节(上限 M ms)…")。
//!
//! 已知缺口(记录缺失时 UI 回退通用文案,不会错报):
//! - mid-stream 读错误(200 后半途断连,ReadFailed 类,**非** stall)不经此处,现场只在日志;
//! - 进程级单例:并发 subagent 的错误可能相互覆盖——此摘要是"进程最近一次 API 错误",
//!   不保证归属某个具体 run。
//!
//! web 模式多线程(HTTP 线程 + agent 线程)→ mutex 保护;buf 定长静态,零分配。

const std = @import("std");
const sync = @import("platform").sync;

const BODY_CAP = 512;
const KIND_CAP = 48;

/// take() 输出缓冲的保证够用长度:前缀("HTTP 65535(重试 N 次后放弃): "/kind)+ body。
/// 读侧用它声明栈 buf,别自己拍魔数。
pub const SUMMARY_BUF_LEN = KIND_CAP + BODY_CAP + 80;

var mutex: sync.Mutex = .{};

fn lock() void {
    _ = mutex.lock();
}
fn unlock() void {
    _ = mutex.unlock();
}
var has_value: bool = false;
var status_code: u16 = 0; // 0 = 非 HTTP 状态错误(连接失败/SSE 错误帧)
var attempts: u32 = 1;
var kind_buf: [KIND_CAP]u8 = undefined;
var kind_len: usize = 0;
var body_buf: [BODY_CAP]u8 = undefined;
var body_len: usize = 0;

/// 记录 HTTP 状态错误(带响应 body 摘要)。
pub fn recordHttp(status: u16, body: []const u8) void {
    lock();
    defer unlock();
    has_value = true;
    status_code = status;
    attempts = 1;
    kind_len = 0;
    body_len = copySanitized(&body_buf, body);
}

/// 记录非 HTTP 状态错误。kind 如 "连接失败"/"API 错误帧",detail 为错误名或错误 JSON。
pub fn recordNamed(kind: []const u8, detail: []const u8) void {
    lock();
    defer unlock();
    has_value = true;
    status_code = 0;
    attempts = 1;
    kind_len = @min(kind.len, KIND_CAP);
    @memcpy(kind_buf[0..kind_len], kind[0..kind_len]);
    body_len = copySanitized(&body_buf, detail);
}

/// 重试耗尽时补记尝试次数——不覆盖已有现场(HTTP body 比次数值钱)。
pub fn noteAttempts(n: u32) void {
    lock();
    defer unlock();
    if (has_value) attempts = n;
}

/// 请求成功时清除——陈旧错误不许活过一次成功,否则后续无记录的失败路径
/// (如 mid-stream 网络断)会把几轮前的无关现场当死因端给用户。
pub fn clear() void {
    lock();
    defer unlock();
    has_value = false;
}

/// 取出并清空。格式化单行摘要到 out,无记录返回 null。
/// out 定长指针:容量由类型系统担保,传小 buf 直接编译失败而非运行时截断。
/// catch unreachable 可证明:kind ≤ 48 + body ≤ 512 + 前缀(状态码/次数/文案)≤ 80。
pub fn take(out: *[SUMMARY_BUF_LEN]u8) ?[]const u8 {
    lock();
    defer unlock();
    if (!has_value) return null;
    has_value = false;
    const body = body_buf[0..body_len];
    if (status_code != 0) {
        if (attempts > 1) {
            return std.fmt.bufPrint(out, "HTTP {d}(重试 {d} 次后放弃): {s}", .{ status_code, attempts, body }) catch unreachable;
        }
        return std.fmt.bufPrint(out, "HTTP {d}: {s}", .{ status_code, body }) catch unreachable;
    }
    const kind = kind_buf[0..kind_len];
    if (attempts > 1) {
        return std.fmt.bufPrint(out, "{s}(重试 {d} 次后放弃): {s}", .{ kind, attempts, body }) catch unreachable;
    }
    return std.fmt.bufPrint(out, "{s}: {s}", .{ kind, body }) catch unreachable;
}

/// 拷贝并清洗:C0 控制字节/DEL/C1 码点(U+0080-U+009F)/非法 UTF-8 → 空格。
/// 摘要要打上终端——server 控制的 body 是注入面,0x9B(8-bit CSI)这类字节
/// 原样输出等于把终端交给对端;合法多字节 UTF-8(中文报错)原样保留。
fn copySanitized(dst: []u8, src: []const u8) usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len and out < dst.len) {
        const c = src[i];
        if (c < 0x80) {
            dst[out] = if (c < 0x20 or c == 0x7f) ' ' else c;
            out += 1;
            i += 1;
            continue;
        }
        const l = std.unicode.utf8ByteSequenceLength(c) catch {
            dst[out] = ' ';
            out += 1;
            i += 1;
            continue;
        };
        if (i + l > src.len) { // 源尾截断的半个序列
            dst[out] = ' ';
            out += 1;
            i += 1;
            continue;
        }
        if (out + l > dst.len) break; // dst 满,不塞半个序列
        const cp = std.unicode.utf8Decode(src[i .. i + l]) catch {
            dst[out] = ' ';
            out += 1;
            i += 1;
            continue;
        };
        if (cp >= 0x80 and cp <= 0x9f) { // C1 控制码
            dst[out] = ' ';
            out += 1;
            i += l;
            continue;
        }
        @memcpy(dst[out .. out + l], src[i .. i + l]);
        out += l;
        i += l;
    }
    return out;
}

test "recordHttp + take formats status and body" {
    recordHttp(400, "{\"error\":{\"message\":\"Failed to parse request body\"}}");
    var out: [SUMMARY_BUF_LEN]u8 = undefined;
    const s = take(&out).?;
    try std.testing.expectEqualStrings("HTTP 400: {\"error\":{\"message\":\"Failed to parse request body\"}}", s);
    // 读后清空
    try std.testing.expect(take(&out) == null);
}

test "recordNamed + noteAttempts formats retry exhaustion" {
    recordNamed("连接失败", "ConnectionRefused");
    noteAttempts(10);
    var out: [SUMMARY_BUF_LEN]u8 = undefined;
    const s = take(&out).?;
    try std.testing.expectEqualStrings("连接失败(重试 10 次后放弃): ConnectionRefused", s);
}

test "recordHttp + noteAttempts formats http retry exhaustion" {
    recordHttp(503, "overloaded");
    noteAttempts(10);
    var out: [SUMMARY_BUF_LEN]u8 = undefined;
    const s = take(&out).?;
    try std.testing.expectEqualStrings("HTTP 503(重试 10 次后放弃): overloaded", s);
}

test "recordNamed single attempt has no retry suffix" {
    recordNamed("连接失败", "RequestFailed");
    var out: [SUMMARY_BUF_LEN]u8 = undefined;
    const s = take(&out).?;
    try std.testing.expectEqualStrings("连接失败: RequestFailed", s);
}

test "noteAttempts without record is a no-op" {
    var out: [SUMMARY_BUF_LEN]u8 = undefined;
    _ = take(&out); // 清场
    noteAttempts(5);
    try std.testing.expect(take(&out) == null);
}

test "body control bytes are flattened to spaces" {
    recordHttp(500, "line1\nline2\x00tail");
    var out: [SUMMARY_BUF_LEN]u8 = undefined;
    const s = take(&out).?;
    try std.testing.expectEqualStrings("HTTP 500: line1 line2 tail", s);
}

test "clear wipes pending record" {
    recordHttp(500, "stale");
    clear();
    var out: [SUMMARY_BUF_LEN]u8 = undefined;
    try std.testing.expect(take(&out) == null);
}

test "terminal injection bytes are neutralized, valid utf8 kept" {
    // 裸 0x9B(8-bit CSI)+ UTF-8 编码的 C1(U+009B = 0xC2 0x9B)+ DEL + 非法序列 → 全空格;
    // 中文(合法多字节)必须原样保留。
    recordHttp(502, "网关\x9b错误\xc2\x9b压\x7f测\xe4\xbd");
    var out: [SUMMARY_BUF_LEN]u8 = undefined;
    const s = take(&out).?;
    try std.testing.expectEqualStrings("HTTP 502: 网关 错误 压 测  ", s);
}
