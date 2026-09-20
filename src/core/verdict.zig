//! 原生裁决摄取(VerdictIngest):把任意权威检查的输出解析成结构化失败
//! 证据——名字、理由、调用现场、通过率——并合成 task-outcome 行。
//!
//! 内化动机(2026-08-20 review):etag 战役的反馈机制(理由通道/调用现场/
//! 工件锚)全部长在评测 adapter 里纯属历史偶然;解析器是纯函数,证据 schema
//! 本就是 binary 原生的(task-outcome-v1)。搬进 binary 后:
//! - 评测 adapter 退化为薄壳(沙箱搬运 + 调同一机器);
//! - 真实环境获得同一闭环(host-run 裁决 / 用户贴 CI 输出 / 仓库测试);
//! - 解析 bug 进 L2 测试网(战役里 5+ 次事故全在 adapter 侧)。
//!
//! 溯源分层(评测里不存在的新需求):自跑检查天然不可信(等价替代教训),
//! 行必须携带 provenance,选择策略偏好高层级——策略半边由 Lean 镜面证明
//! (control-plane/lean/MetaCodesControl/VerdictProvenance.lean)。
//!
//! **分层纪律(通用性的真正来源)**:
//! - 核心(证据 IR / 行合成 / 溯源策略 / host-run 门)**格式盲**;
//! - JUnit/pytest 是两个**内置 codec**(tree-sitter grammar registry 同款
//!   先例:打包≠耦合,加 TAP/go-test/jest = 加 codec,核心零改动);
//! - **raw 兜底永在**:codec 全不识 → exit≠0 + 输出尾原文入行。闭环在
//!   任何生态永不为零,codec 只是针派生质量的增强器。

const std = @import("std");
const util_json = @import("../util/json.zig");

/// 单条检查结果(kind 只区分裁决面需要的三类)。
pub const CheckResult = struct {
    /// 逻辑名:JUnit 为 "Class::name" 或裸 name;pytest 行为整个 node id。
    name: []const u8,
    class_name: []const u8 = "",
    kind: Kind,
    /// 理由(message 属性,已实体解码;可空)。
    message: []const u8 = "",
    /// 失败语句原文(pytest longrepr '>' 标记行;可空)。
    callsite: []const u8 = "",

    pub const Kind = enum { passed, failed, skipped };
};

pub const ParseOutcome = struct {
    arena: std.heap.ArenaAllocator,
    results: []CheckResult,
    passed: u32,
    total: u32,

    pub fn deinit(self: *ParseOutcome) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// 溯源层级(低→高)。缺省(旧行无 prov 字段)按 external_oracle 处理:
/// 存量行全部来自评测验证器,向后兼容即如实。
pub const Provenance = enum(u8) {
    self_claim = 0,
    host_run_tainted = 1,
    host_run = 2,
    external_oracle = 3,
    user = 4,

    pub fn parse(text: []const u8) Provenance {
        inline for (@typeInfo(Provenance).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name))
                return @enumFromInt(field.value);
        }
        return .external_oracle;
    }

    pub fn rank(self: Provenance) u8 {
        return @intFromEnum(self);
    }
};

// ── JUnit XML(极简提取器:不求全 XML,只认 testcase/skipped/failure/error
//    的属性与正文;实体解码只做五个标准实体 + 十进制数字实体)────────────

fn decodeEntities(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            const semi = std.mem.indexOfScalarPos(u8, s, i, ';');
            if (semi) |end| {
                const ent = s[i + 1 .. end];
                if (std.mem.eql(u8, ent, "quot")) {
                    try out.append(allocator, '"');
                    i = end + 1;
                    continue;
                } else if (std.mem.eql(u8, ent, "amp")) {
                    try out.append(allocator, '&');
                    i = end + 1;
                    continue;
                } else if (std.mem.eql(u8, ent, "lt")) {
                    try out.append(allocator, '<');
                    i = end + 1;
                    continue;
                } else if (std.mem.eql(u8, ent, "gt")) {
                    try out.append(allocator, '>');
                    i = end + 1;
                    continue;
                } else if (std.mem.eql(u8, ent, "apos")) {
                    try out.append(allocator, '\'');
                    i = end + 1;
                    continue;
                } else if (ent.len > 1 and ent[0] == '#') {
                    const code = std.fmt.parseInt(u21, ent[1..], 10) catch 0;
                    if (code > 0 and code < 0x110000) {
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(@intCast(code), &buf) catch 0;
                        if (n > 0) {
                            try out.appendSlice(allocator, buf[0..n]);
                            i = end + 1;
                            continue;
                        }
                    }
                }
            }
        }
        try out.append(allocator, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn attrValue(tag: []const u8, attr_name: []const u8, buffer: []u8) ?[]const u8 {
    var needle_buffer: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buffer, "{s}=\"", .{attr_name}) catch return null;
    // 属性名必须在边界上匹配:裸 indexOf("name=\"") 会先命中
    // classname=\" 里的子串(lib 门实抓:name 恒等于 classname)。
    var search: usize = 0;
    const start = while (std.mem.indexOfPos(u8, tag, search, needle)) |at| {
        if (at == 0 or tag[at - 1] == ' ' or tag[at - 1] == '\t') break at + needle.len;
        search = at + 1;
    } else return null;
    const end = std.mem.indexOfScalarPos(u8, tag, start, '"') orelse return null;
    const raw = tag[start..end];
    if (raw.len > buffer.len) return raw[0..0];
    @memcpy(buffer[0..raw.len], raw);
    return buffer[0..raw.len];
}

/// pytest longrepr:最后一个 '>' 标记行 = 失败语句原文。
fn lastCallsite(body: []const u8) []const u8 {
    var found: []const u8 = "";
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 1 and trimmed[0] == '>')
            found = std.mem.trim(u8, trimmed[1..], " \t");
    }
    return found;
}

/// 解析 JUnit results.xml 文本。容错:结构不识返回空集,绝不报错致死。
pub fn parseJunitXml(gpa: std.mem.Allocator, xml: []const u8) !ParseOutcome {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var results = std.array_list.Managed(CheckResult).init(a);
    var passed: u32 = 0;
    var total: u32 = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, xml, i, "<testcase")) |open| {
        const tag_end = std.mem.indexOfScalarPos(u8, xml, open, '>') orelse break;
        const tag = xml[open .. tag_end + 1];
        const self_closing = std.mem.endsWith(u8, std.mem.trimEnd(u8, tag, ">"), "/");
        var name_buffer: [256]u8 = undefined;
        var class_buffer: [256]u8 = undefined;
        const name_raw = attrValue(tag, "name", &name_buffer) orelse "";
        const class_raw = attrValue(tag, "classname", &class_buffer) orelse "";
        const name = try a.dupe(u8, name_raw);
        const class_name = try a.dupe(u8, class_raw);
        var kind: CheckResult.Kind = .passed;
        var message: []const u8 = "";
        var callsite: []const u8 = "";
        var next_i = tag_end + 1;
        if (!self_closing) {
            const close = std.mem.indexOfPos(u8, xml, tag_end, "</testcase>") orelse xml.len;
            const body = xml[tag_end + 1 .. close];
            next_i = @min(close + "</testcase>".len, xml.len);
            inline for (.{ "skipped", "failure", "error" }, .{ CheckResult.Kind.skipped, CheckResult.Kind.failed, CheckResult.Kind.failed }) |tag_name, mapped| {
                if (kind == .passed) {
                    var open_buffer: [24]u8 = undefined;
                    const child_open = std.fmt.bufPrint(&open_buffer, "<{s}", .{tag_name}) catch unreachable;
                    if (std.mem.indexOf(u8, body, child_open)) |child_at| {
                        kind = mapped;
                        const child_tag_end = std.mem.indexOfScalarPos(u8, body, child_at, '>') orelse body.len;
                        const child_tag = body[child_at..@min(child_tag_end + 1, body.len)];
                        var message_buffer: [1024]u8 = undefined;
                        if (attrValue(child_tag, "message", &message_buffer)) |raw|
                            message = try decodeEntities(a, raw);
                        // 子元素正文(到对应闭标签或 testcase 末尾)承载 longrepr。
                        var close_buffer: [24]u8 = undefined;
                        const child_close = std.fmt.bufPrint(&close_buffer, "</{s}>", .{tag_name}) catch unreachable;
                        const body_end = std.mem.indexOfPos(u8, body, child_tag_end, child_close) orelse body.len;
                        if (child_tag_end < body_end) {
                            const decoded = try decodeEntities(a, body[child_tag_end + 1 .. body_end]);
                            callsite = try a.dupe(u8, lastCallsite(decoded));
                        }
                    }
                }
            }
        }
        total += 1;
        if (kind == .passed) passed += 1;
        try results.append(.{
            .name = name,
            .class_name = class_name,
            .kind = kind,
            .message = message,
            .callsite = callsite,
        });
        i = next_i;
    }
    return .{ .arena = arena, .results = results.items, .passed = passed, .total = total };
}

/// pytest -v 行回退("FAILED node" / "node SKIPPED [..]")。无法给出总数,
/// total 只计解析到的失败/跳过(通过行不稳定,不猜)。
pub fn parsePytestLines(gpa: std.mem.Allocator, text: []const u8) !ParseOutcome {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var results = std.array_list.Managed(CheckResult).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "FAILED ")) {
            var name = line["FAILED ".len..];
            if (std.mem.indexOf(u8, name, " - ")) |cut| name = name[0..cut];
            try results.append(.{ .name = try a.dupe(u8, std.mem.trim(u8, name, " \r")), .kind = .failed });
        } else if (std.mem.indexOf(u8, line, "::") != null and std.mem.indexOf(u8, line, " SKIPPED") != null) {
            const name = std.mem.trim(u8, line[0..std.mem.indexOf(u8, line, " SKIPPED").?], " \r");
            try results.append(.{ .name = try a.dupe(u8, name), .kind = .skipped });
        }
    }
    return .{
        .arena = arena,
        .results = results.items,
        .passed = 0,
        .total = @intCast(results.items.len),
    };
}

/// codec 自动分发 + raw 兜底:任何命令的 (exit_code, 输出) 都能成为裁决。
/// 识别顺序:JUnit XML(含 <testcase)→ pytest 行(FAILED/SKIPPED)→ raw
/// (exit≠0 → 单条 failed 伪结果,message=输出尾部;exit=0 → 单条 passed)。
pub fn parseAuto(gpa: std.mem.Allocator, output: []const u8, exit_code: i64) !ParseOutcome {
    if (std.mem.indexOf(u8, output, "<testcase") != null) {
        var parsed = try parseJunitXml(gpa, output);
        if (parsed.total > 0) return parsed;
        parsed.deinit();
    }
    {
        var parsed = try parsePytestLines(gpa, output);
        if (parsed.results.len > 0) {
            // pytest 行回退给不出通过数;exit=0 且无失败行按全过处理。
            return parsed;
        }
        parsed.deinit();
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var results = std.array_list.Managed(CheckResult).init(a);
    if (exit_code == 0) {
        try results.append(.{ .name = try a.dupe(u8, "pinned check"), .kind = .passed });
        return .{ .arena = arena, .results = results.items, .passed = 1, .total = 1 };
    }
    const tail = if (output.len > 400) output[output.len - 400 ..] else output;
    try results.append(.{
        .name = try a.dupe(u8, "pinned check"),
        .kind = .failed,
        .message = try a.dupe(u8, tail),
    });
    return .{ .arena = arena, .results = results.items, .passed = 0, .total = 1 };
}

// ── 行合成(与 adapter 相同的清洗纪律,单一真理源在此)────────────────

/// 清洗进 failing=[...] 的文本:方括号→圆括号(括号定界)、逗号→分号
/// (", " 分割)、空白折叠、码点安全截断。
fn sanitizeInto(out: *std.array_list.Managed(u8), s: []const u8, cap: usize) !void {
    var written: usize = 0;
    var pending_space = false;
    for (s) |c| {
        if (written >= cap) break;
        const mapped: u8 = switch (c) {
            '[' => '(',
            ']' => ')',
            ',' => ';',
            '\n', '\r', '\t' => ' ',
            else => c,
        };
        if (mapped == ' ') {
            pending_space = written > 0;
            continue;
        }
        if (pending_space) {
            try out.append(' ');
            written += 1;
            pending_space = false;
            if (written >= cap) break;
        }
        try out.append(mapped);
        written += 1;
    }
    // 码点安全:若截在多字节序列内,回退。
    while (out.items.len > 0 and (out.items[out.items.len - 1] & 0xC0) == 0x80 and written >= cap)
        _ = out.pop();
}

pub const ComposeOptions = struct {
    task: []const u8,
    attempt_key: []const u8,
    provenance: Provenance,
    final_note: []const u8 = "",
    /// git 新文件工件(caller 提供,可空;截断责任在 caller 或此处 1600 帽)。
    best_artifact: []const u8 = "",
    max_entries: usize = 20,
};

/// 合成 task-outcomes JSON(单任务单行,schema=task-outcome-v1)。
/// caller free。reward = passed/total(total=0 → 0)。
pub fn composeOutcomesJson(gpa: std.mem.Allocator, parsed: *const ParseOutcome, opts: ComposeOptions) ![]u8 {
    var failing = std.array_list.Managed(u8).init(gpa);
    defer failing.deinit();
    var count: usize = 0;
    for (parsed.results) |r| {
        if (r.kind == .passed) continue;
        if (count >= opts.max_entries) break;
        if (count > 0) try failing.appendSlice(", ");
        try failing.append('"');
        // 名字:优先 Class::name 组合(JUnit),pytest 行本身已是 node id。
        var name = std.array_list.Managed(u8).init(gpa);
        defer name.deinit();
        if (r.class_name.len > 0 and std.mem.indexOf(u8, r.name, "::") == null) {
            try sanitizeInto(&name, r.class_name, 120);
            try name.appendSlice("::");
        }
        try sanitizeInto(&name, r.name, 160);
        try failing.appendSlice(name.items);
        const label: []const u8 = if (r.kind == .skipped) "skipped" else "failed";
        if (r.message.len > 0 or r.callsite.len > 0) {
            try failing.appendSlice(" (");
            try failing.appendSlice(label);
            try failing.appendSlice(": ");
            var msg = std.array_list.Managed(u8).init(gpa);
            defer msg.deinit();
            try sanitizeInto(&msg, r.message, 200);
            if (r.callsite.len > 0) {
                if (msg.items.len > 90) msg.shrinkRetainingCapacity(90);
                try msg.appendSlice(" AT test code: ");
                try sanitizeInto(&msg, r.callsite, 80);
            }
            try failing.appendSlice(msg.items);
            try failing.append(')');
        } else if (r.kind == .skipped) {
            try failing.appendSlice(" (skipped)");
        }
        try failing.append('"');
        count += 1;
    }
    const reward: f64 = if (parsed.total == 0)
        0
    else
        @as(f64, @floatFromInt(parsed.passed)) / @as(f64, @floatFromInt(parsed.total));
    var note = std.array_list.Managed(u8).init(gpa);
    defer note.deinit();
    try sanitizeInto(&note, opts.final_note, 300);
    // best_artifact 经 JSON 转义原样携带(截断标注是 caller/提取器责任)。
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.print(
        \\{{"schema_version":"task-outcome-v1","outcomes":[{{"task":
    , .{});
    try util_json.writeJsonString(&aw.writer, opts.task);
    try aw.writer.print(",\"attempt_key\":", .{});
    try util_json.writeJsonString(&aw.writer, opts.attempt_key);
    try aw.writer.print(",\"reward\":{d:.4},\"tests_passed\":{d},\"tests_total\":{d},\"provenance\":\"{s}\",\"failing_tests\":[{s}]", .{
        reward, parsed.passed, parsed.total, @tagName(opts.provenance), failing.items,
    });
    if (note.items.len > 0) {
        try aw.writer.print(",\"final_note\":", .{});
        try util_json.writeJsonString(&aw.writer, note.items);
    }
    if (opts.best_artifact.len > 0) {
        try aw.writer.print(",\"best_artifact\":", .{});
        try util_json.writeJsonString(&aw.writer, opts.best_artifact);
    }
    try aw.writer.print("}}]}}", .{});
    return aw.toOwnedSlice();
}

// ── 污染检测(host-run 裁决的诚实半边)───────────────────────────────

/// 检查涉及的文件在本次运行中被改动过 → 结果降级 host_run_tainted。
/// porcelain = `git status --porcelain` 输出;结果名的文件部分(`::` 前)
/// 出现在改动清单里即污染。纯函数,机械,无语义判断。
pub fn taintedByWorkspaceEdits(parsed: *const ParseOutcome, porcelain: []const u8) bool {
    var it = std.mem.splitScalar(u8, porcelain, '\n');
    while (it.next()) |line| {
        if (line.len < 4) continue;
        const path = std.mem.trim(u8, line[3..], " \r");
        if (path.len < 4) continue;
        for (parsed.results) |r| {
            const file_part = if (std.mem.indexOf(u8, r.name, "::")) |cut| r.name[0..cut] else r.name;
            if (file_part.len >= 4 and std.mem.indexOf(u8, path, file_part) != null) return true;
            if (std.mem.indexOf(u8, file_part, path) != null) return true;
        }
    }
    return false;
}

// ── git 新文件工件提取(_best_artifact 的 zig 版,输入 diff 文本)────────

pub const ARTIFACT_QUOTA: usize = 1600;

/// 从 `git diff` 文本提取新建非测试文件的原文(≤2 文件,总量 ARTIFACT_QUOTA;
/// 截断显式标注——半个文件配"逐字写入"指令是毒药)。caller free。
pub fn extractNewFileArtifact(gpa: std.mem.Allocator, diff_text: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(gpa);
    errdefer out.deinit();
    var pieces: usize = 0;
    var total: usize = 0;
    var chunks = std.mem.splitSequence(u8, diff_text, "diff --git ");
    _ = chunks.next(); // 首段前缀
    while (chunks.next()) |chunk| {
        if (pieces >= 2 or total >= ARTIFACT_QUOTA) break;
        if (std.mem.indexOf(u8, chunk, "\nnew file mode") == null) continue;
        const header_end = std.mem.indexOfScalar(u8, chunk, '\n') orelse continue;
        const header = chunk[0..header_end];
        const path_at = std.mem.lastIndexOf(u8, header, " b/") orelse continue;
        const path = std.mem.trim(u8, header[path_at + 3 ..], " \r");
        if (std.mem.startsWith(u8, path, "tests/") or std.mem.startsWith(u8, path, "test/")) continue;
        var content = std.array_list.Managed(u8).init(gpa);
        defer content.deinit();
        var lines = std.mem.splitScalar(u8, chunk, '\n');
        while (lines.next()) |line| {
            if (line.len > 0 and line[0] == '+' and !std.mem.startsWith(u8, line, "+++")) {
                try content.appendSlice(line[1..]);
                try content.append('\n');
            }
        }
        if (std.mem.trim(u8, content.items, " \n\r").len == 0) continue;
        const budget = ARTIFACT_QUOTA - total;
        var take: usize = @min(content.items.len, budget);
        while (take > 0 and take < content.items.len and (content.items[take] & 0xC0) == 0x80) take -= 1;
        if (pieces > 0) try out.append('\n');
        try out.appendSlice("--- ");
        try out.appendSlice(path);
        try out.appendSlice(" ---\n");
        try out.appendSlice(content.items[0..take]);
        if (take < content.items.len)
            try out.appendSlice("\n(HOST-TRUNCATED: file exceeds quota, do NOT copy verbatim)");
        total += take;
        pieces += 1;
    }
    return out.toOwnedSlice();
}

// ── 测试 ─────────────────────────────────────────────────────────────

test "junit: skip/failure messages, callsite, entities, counts" {
    const a = std.testing.allocator;
    const xml =
        \\<?xml version="1.0"?><testsuites><testsuite tests="3">
        \\<testcase classname="tests.test_x.TestC" name="test_ok" time="0.1"/>
        \\<testcase classname="tests.test_x.TestC" name="test_skip"><skipped type="pytest.skip" message="pkg._mod not available, create [it]"/></testcase>
        \\<testcase classname="tests.test_x.TestC" name="test_fail"><failure message="assert 66 == 18">self = x
        \\&gt;           etag = calc(Path(f.name))
        \\E TypeError</failure></testcase>
        \\</testsuite></testsuites>
    ;
    var parsed = try parseJunitXml(a, xml);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed.passed);
    try std.testing.expectEqual(@as(u32, 3), parsed.total);
    try std.testing.expectEqual(CheckResult.Kind.skipped, parsed.results[1].kind);
    try std.testing.expectEqualStrings("pkg._mod not available, create [it]", parsed.results[1].message);
    try std.testing.expectEqualStrings("etag = calc(Path(f.name))", parsed.results[2].callsite);

    const row = try composeOutcomesJson(a, &parsed, .{
        .task = "some-task",
        .attempt_key = "a1",
        .provenance = .host_run,
        .final_note = "done [ok], see\nsummary",
    });
    defer a.free(row);
    // 清洗纪律:括号→圆括号、逗号→分号;AT 子句;provenance;reward=1/3。
    try std.testing.expect(std.mem.indexOf(u8, row, "TestC::test_skip (skipped: pkg._mod not available; create (it))") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "assert 66 == 18 AT test code: etag = calc(Path(f.name))") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "\"provenance\":\"host_run\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "\"reward\":0.3333") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "done (ok); see summary") != null);
    // 合成行必须是合法 JSON。
    const parsed_json = try std.json.parseFromSlice(std.json.Value, a, row, .{});
    defer parsed_json.deinit();
}

test "pytest lines fallback" {
    const a = std.testing.allocator;
    var parsed = try parsePytestLines(a,
        \\collected 3 items
        \\FAILED tests/t.py::TestA::test_one - AssertionError: boom
        \\tests/t.py::TestA::test_two SKIPPED [ 33%]
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.results.len);
    try std.testing.expectEqualStrings("tests/t.py::TestA::test_one", parsed.results[0].name);
    try std.testing.expectEqual(CheckResult.Kind.skipped, parsed.results[1].kind);
}

test "tainted: edited check file downgrades" {
    const a = std.testing.allocator;
    var parsed = try parsePytestLines(a, "FAILED tests/t.py::TestA::test_one\n");
    defer parsed.deinit();
    try std.testing.expect(taintedByWorkspaceEdits(&parsed, " M tests/t.py\n"));
    try std.testing.expect(!taintedByWorkspaceEdits(&parsed, " M src/app.py\n?? notes.md\n"));
}

test "artifact extraction: new non-test files, quota marked" {
    const a = std.testing.allocator;
    var diff = std.array_list.Managed(u8).init(a);
    defer diff.deinit();
    try diff.appendSlice("diff --git a/pkg/_mod.py b/pkg/_mod.py\nnew file mode 100644\n+++ b/pkg/_mod.py\n+def f():\n+    return 1\n");
    try diff.appendSlice("diff --git a/tests/test_new.py b/tests/test_new.py\nnew file mode 100644\n+++ b/tests/test_new.py\n+def test():\n+    pass\n");
    try diff.appendSlice("diff --git a/pkg/big.py b/pkg/big.py\nnew file mode 100644\n+++ b/pkg/big.py\n");
    var i: usize = 0;
    while (i < 400) : (i += 1) try diff.appendSlice("+x = 1\n");
    const art = try extractNewFileArtifact(a, diff.items);
    defer a.free(art);
    try std.testing.expect(std.mem.indexOf(u8, art, "--- pkg/_mod.py ---") != null);
    try std.testing.expect(std.mem.indexOf(u8, art, "tests/test_new.py") == null);
    try std.testing.expect(std.mem.indexOf(u8, art, "HOST-TRUNCATED") != null);
    try std.testing.expect(art.len < ARTIFACT_QUOTA + 300);
}

test "parseAuto: raw fallback keeps the loop alive on any ecosystem" {
    const a = std.testing.allocator;
    var failed = try parseAuto(a, "error[E0433]: failed to resolve: use of undeclared crate `foo`\ncompile error", 101);
    defer failed.deinit();
    try std.testing.expectEqual(@as(u32, 0), failed.passed);
    try std.testing.expectEqual(CheckResult.Kind.failed, failed.results[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, failed.results[0].message, "undeclared crate") != null);
    var ok = try parseAuto(a, "All 42 checks green", 0);
    defer ok.deinit();
    try std.testing.expectEqual(@as(u32, 1), ok.passed);
}

test "provenance parse + rank order" {
    try std.testing.expectEqual(Provenance.host_run, Provenance.parse("host_run"));
    try std.testing.expectEqual(Provenance.external_oracle, Provenance.parse("unknown-legacy"));
    try std.testing.expect(Provenance.user.rank() > Provenance.external_oracle.rank());
    try std.testing.expect(Provenance.external_oracle.rank() > Provenance.host_run.rank());
    try std.testing.expect(Provenance.host_run.rank() > Provenance.host_run_tainted.rank());
    try std.testing.expect(Provenance.host_run_tainted.rank() > Provenance.self_claim.rank());
}
