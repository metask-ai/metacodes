//! **U11:中立输入意图(issue #3)** —— 所有前端的 raw input 在此归一为 typed
//! InputIntent。纯解析:无 *App、无 IO、无分配;canonical 管线的第一段:
//!
//!   raw input → parse → InputIntent → SessionService.dispatch(validate→
//!   prepare→commit→run 计划)→ 宿主提交 run / 渲染 outcome
//!
//! 解析优先级 = loop.zig 既有顺序契约:**内建命令先于同名 Skill**(因而 Skill
//! 不能劫持 /review、/commit 等产品路由);`!` 前缀 = shell;其余 = prompt。
//! 前端(TUI/web/daemon)不得各自另写一份 slash 解析——本表是唯一动词面。

const std = @import("std");

/// 内建动词表(与 loop.zig 派发链一一对应;新增命令必须先登记于此)。
/// 分类只描述"谁负责":`.service` 走 SessionService.dispatch(全前端等价),
/// `.local` 是纯展示/终端专属(渲染归各 UI;web/daemon 对 .local 报 unsupported)。
pub const VerbClass = enum { service, local };

pub const VerbSpec = struct {
    name: []const u8,
    class: VerbClass,
    /// `verb:payload` 冒号形式(仅离线测试钩子用;普通命令禁用,否则会劫持
    /// `pkg:skill` 的 Skill 调用语法)。
    colon_payload: bool = false,
};

/// 完整动词表。**次序无关**(精确匹配);展示类动词的渲染留在各 UI,但解析归一。
pub const BUILTIN_VERBS = [_]VerbSpec{
    // ── service:config/会话 mutation 与 run 计划(全前端等价) ──
    .{ .name = "model", .class = .service },
    .{ .name = "mode", .class = .service },
    .{ .name = "compact", .class = .service },
    .{ .name = "add-dir", .class = .service },
    .{ .name = "theme", .class = .service },
    .{ .name = "vim", .class = .service },
    .{ .name = "effort", .class = .service },
    .{ .name = "retry", .class = .service },
    .{ .name = "commit", .class = .service },
    .{ .name = "review", .class = .service },
    .{ .name = "init", .class = .service },
    // ── local:纯展示 / 终端专属(TUI 渲染;web/daemon → unsupported) ──
    .{ .name = "exit", .class = .local },
    .{ .name = "help", .class = .local },
    .{ .name = "clear", .class = .local },
    .{ .name = "tools", .class = .local },
    .{ .name = "skills", .class = .local },
    .{ .name = "history", .class = .local },
    .{ .name = "goal", .class = .local }, // 状态迁移 + 调度耦合,迁移列 deferred(issue #3 回复)
    .{ .name = "loop", .class = .local },
    .{ .name = "kg", .class = .local },
    .{ .name = "cost", .class = .local },
    .{ .name = "models", .class = .local },
    .{ .name = "overrides", .class = .local }, // 方言覆盖含 per-provider 校验展示,deferred
    .{ .name = "resume", .class = .local }, // 会话轴(U5/U8),显式排除见 U2 §1.5
    .{ .name = "doctor", .class = .local },
    .{ .name = "config", .class = .local },
    .{ .name = "mcp", .class = .local },
    .{ .name = "btw", .class = .local },
    .{ .name = "recap", .class = .local },
    .{ .name = "agents", .class = .local },
    .{ .name = "permissions", .class = .local },
    .{ .name = "memory", .class = .local }, // edit 走 $EDITOR(tty),终端宏
    // 离线渲染测试钩子(终端专属)
    .{ .name = "task-test", .class = .local, .colon_payload = true },
    .{ .name = "task-test-done", .class = .local, .colon_payload = true },
    .{ .name = "agent-test", .class = .local, .colon_payload = true },
    .{ .name = "agent-test-multi", .class = .local },
    .{ .name = "agent-churn-test", .class = .local },
    .{ .name = "md-test", .class = .local },
    .{ .name = "compact-stress-test", .class = .local },
};

/// typed 输入意图。所有 slice 均**借 caller 的 raw 输入**(零拷贝;宿主在
/// dispatch/append 完成前保持 raw 存活——三个前端的输入缓冲都满足)。
pub const InputIntent = union(enum) {
    /// 空提交(纯空白)→ 无操作。
    empty,
    /// 普通用户消息(append → run)。
    prompt: []const u8,
    /// `!cmd` shell 直执行(输出进入对话上下文)。
    shell: []const u8,
    /// `/verb [args]`,verb 在 BUILTIN_VERBS 表内。
    command: Command,
    /// `/head [rest]`,head 不是内建动词 → Skill 候选(宿主经 skill runtime
    /// 解析;不可用时按现契约回落 unknown/文本)。
    skill: Skill,

    pub const Command = struct { verb: []const u8, args: []const u8, class: VerbClass };
    pub const Skill = struct { head: []const u8, rest: []const u8 };
};

fn lookupVerb(name: []const u8) ?VerbClass {
    for (BUILTIN_VERBS) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec.class;
    }
    return null;
}

/// 解析一条 raw 输入(caller 已/未 trim 均可)。总函数:任何输入恰好落一个意图。
/// 特例对齐 loop.zig:裸 `exit` 与 `/exit` 等价;整行 `?` = shortcuts 帮助(local)。
/// `/task-test:label` 这类 `verb:payload` 形式:冒号前缀匹配表内动词时归 command,
/// args = 冒号后原文(与 loop.zig startsWith 派发一致)。
pub fn parse(raw: []const u8) InputIntent {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .empty;
    if (std.mem.eql(u8, trimmed, "exit"))
        return .{ .command = .{ .verb = "exit", .args = "", .class = .local } };
    if (std.mem.eql(u8, trimmed, "?"))
        return .{ .command = .{ .verb = "help", .args = "shortcuts", .class = .local } };
    if (trimmed[0] == '!') {
        return .{ .shell = std.mem.trim(u8, trimmed[1..], " \t") };
    }
    if (trimmed[0] != '/') return .{ .prompt = trimmed };

    const body = trimmed[1..];
    if (body.len == 0) return .{ .prompt = trimmed }; // 裸 "/" 不是命令
    // `verb:payload` 测试钩子形式(/task-test:my label):冒号后整段(含空格)是
    // payload,须在空格切分**之前**识别——对齐 loop.zig 的 startsWith 派发。
    // 仅 colon_payload 动词参与:普通动词的 `x:y` 形式留给 Skill 语法(pkg:skill)。
    for (BUILTIN_VERBS) |spec| {
        if (spec.colon_payload and
            body.len > spec.name.len and
            std.mem.startsWith(u8, body, spec.name) and
            body[spec.name.len] == ':')
        {
            return .{ .command = .{
                .verb = spec.name,
                .args = body[spec.name.len + 1 ..],
                .class = spec.class,
            } };
        }
    }
    var head_end: usize = 0;
    while (head_end < body.len and body[head_end] != ' ' and body[head_end] != '\t') : (head_end += 1) {}
    const head = body[0..head_end];
    const args = std.mem.trim(u8, body[head_end..], " \t");
    if (lookupVerb(head)) |class| {
        return .{ .command = .{ .verb = head, .args = args, .class = class } };
    }
    return .{ .skill = .{ .head = head, .rest = args } };
}

// ============================================================================
// Tests(纯解析,零依赖)
// ============================================================================
const testing = std.testing;

test "parse: 空/纯空白 → empty" {
    try testing.expect(parse("") == .empty);
    try testing.expect(parse("  \t\r\n") == .empty);
}

test "parse: 普通文本与裸 / → prompt" {
    try testing.expectEqualStrings("hello world", parse("  hello world \n").prompt);
    try testing.expect(parse("/") == .prompt);
    try testing.expect(parse("what is 1/2?") == .prompt);
}

test "parse: shell 前缀" {
    try testing.expectEqualStrings("ls -la", parse("!ls -la").shell);
    try testing.expectEqualStrings("", parse("!").shell);
}

test "parse: 内建命令与参数切分" {
    const c = parse("/model use claude-x").command;
    try testing.expectEqualStrings("model", c.verb);
    try testing.expectEqualStrings("use claude-x", c.args);
    try testing.expect(c.class == .service);

    const m = parse("/mode plan").command;
    try testing.expectEqualStrings("mode", m.verb);
    try testing.expectEqualStrings("plan", m.args);

    const h = parse("/help").command;
    try testing.expect(h.class == .local);
}

test "parse: 裸 exit 与 ? 特例" {
    try testing.expectEqualStrings("exit", parse("exit").command.verb);
    const q = parse("?").command;
    try testing.expectEqualStrings("help", q.verb);
    try testing.expectEqualStrings("shortcuts", q.args);
}

test "parse: 非内建 slash → skill 候选(内建优先契约)" {
    const s = parse("/mypkg:deploy prod --fast").skill;
    try testing.expectEqualStrings("mypkg:deploy", s.head);
    try testing.expectEqualStrings("prod --fast", s.rest);
    // 内建同名不会落 skill:
    try testing.expect(parse("/review") == .command);
    // 但 `内建名:skill` 是合法 Skill 语法,不被冒号钩子劫持:
    const hijack = parse("/model:deploy prod").skill;
    try testing.expectEqualStrings("model:deploy", hijack.head);
}

test "parse: task-test 冒号 payload 形式" {
    const t = parse("/task-test:my label").command;
    try testing.expectEqualStrings("task-test", t.verb);
    try testing.expectEqualStrings("my label", t.args);
    // 普通空格形式不受影响
    const t2 = parse("/task-test running").command;
    try testing.expectEqualStrings("running", t2.args);
}
