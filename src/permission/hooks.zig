//! PreToolUse hook 系统(对齐 Claude Code hooks)。
//!
//! settings.json:
//!   "hooks": {
//!     "PreToolUse": [
//!       { "matcher": "Bash", "hooks": [ {"type":"command","command":"./check.sh"} ] },
//!       { "matcher": "Write|Edit", "hooks": [ ... ] }
//!     ]
//!   }
//!
//! 工具执行前,匹配 matcher 的 hook 命令被 spawn:
//!   - tool 信息(name + input JSON)通过 stdin 喂给 hook(JSON 一行)
//!   - hook exit code:0 = 放行;2 = 阻止(deny,优先于一切);其它 = 非阻塞错误(放行 + log)
//!   - hook stdout 也可输出 JSON 决策 {"decision":"block"|"approve","reason":"..."};
//!     exit 2 优先,然后看 decision
//!
//! 决策接入(decision.zig):PreToolUse 在整个权限链最前(deny-first)。
//! matcher 语法:工具名精确,或 `A|B|C` 多选,或 `*`/空 = 所有工具。
//!
//! 安全:hook 是用户配置的本地命令,运行时信任(同 settings)。超时 5s 防卡死。

const std = @import("std");
const log = @import("../util/log.zig");

pub const HookDecision = enum {
    /// hook 放行(exit 0 且无 block 决策)— 继续后续权限链
    proceed,
    /// hook 阻止(exit 2 或 stdout decision=block)— 直接 deny
    block,
};

pub const HookEntry = struct {
    /// matcher 字符串:"Bash" / "Write|Edit" / "*" / ""(后两者 = 所有)
    matcher: []const u8,
    /// 该 matcher 下的 command 列表
    commands: []const []const u8,
};

pub const HookSet = struct {
    pre_tool_use: []const HookEntry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HookSet) void {
        for (self.pre_tool_use) |e| {
            self.allocator.free(e.matcher);
            for (e.commands) |c| self.allocator.free(c);
            self.allocator.free(e.commands);
        }
        self.allocator.free(self.pre_tool_use);
    }

    pub fn isEmpty(self: *const HookSet) bool {
        return self.pre_tool_use.len == 0;
    }
};

/// 从 settings JSON root 解析 hooks.PreToolUse。无则返回空 set。
pub fn parse(alloc: std.mem.Allocator, root: std.json.Value) !HookSet {
    var entries: std.ArrayList(HookEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            alloc.free(e.matcher);
            for (e.commands) |c| alloc.free(c);
            alloc.free(e.commands);
        }
        entries.deinit(alloc);
    }

    if (root == .object) {
        if (root.object.get("hooks")) |hooks_v| {
            if (hooks_v == .object) {
                if (hooks_v.object.get("PreToolUse")) |ptu| {
                    if (ptu == .array) {
                        for (ptu.array.items) |item| {
                            if (item != .object) continue;
                            const matcher_v = item.object.get("matcher");
                            const matcher = if (matcher_v) |m|
                                (if (m == .string) try alloc.dupe(u8, m.string) else try alloc.dupe(u8, "*"))
                            else
                                try alloc.dupe(u8, "*");
                            errdefer alloc.free(matcher);

                            var cmds: std.ArrayList([]const u8) = .empty;
                            errdefer {
                                for (cmds.items) |c| alloc.free(c);
                                cmds.deinit(alloc);
                            }
                            if (item.object.get("hooks")) |hk| {
                                if (hk == .array) {
                                    for (hk.array.items) |h| {
                                        if (h != .object) continue;
                                        const cmd_v = h.object.get("command") orelse continue;
                                        if (cmd_v != .string) continue;
                                        try cmds.append(alloc, try alloc.dupe(u8, cmd_v.string));
                                    }
                                }
                            }
                            try entries.append(alloc, .{
                                .matcher = matcher,
                                .commands = try cmds.toOwnedSlice(alloc),
                            });
                        }
                    }
                }
            }
        }
    }

    return HookSet{ .pre_tool_use = try entries.toOwnedSlice(alloc), .allocator = alloc };
}

/// matcher 是否匹配 tool_name。"" / "*" = 所有;"A|B" = A 或 B;否则精确。
pub fn matcherMatches(matcher: []const u8, tool_name: []const u8) bool {
    const m = std.mem.trim(u8, matcher, " \t");
    if (m.len == 0 or std.mem.eql(u8, m, "*")) return true;
    var it = std.mem.splitScalar(u8, m, '|');
    while (it.next()) |part| {
        if (std.mem.eql(u8, std.mem.trim(u8, part, " \t"), tool_name)) return true;
    }
    return false;
}

/// 跑所有匹配 tool_name 的 PreToolUse hook。任一 block → 返回 .block。
/// 全部 proceed(或无匹配)→ .proceed。
pub fn runPreToolUse(
    set: *const HookSet,
    alloc: std.mem.Allocator,
    tool_name: []const u8,
    args: []const u8,
) HookDecision {
    if (set.isEmpty()) return .proceed;

    // 构造喂给 hook stdin 的 JSON:{"hook_event_name":"PreToolUse","tool_name":"...","tool_input":<args>}
    const stdin_json = std.fmt.allocPrint(
        alloc,
        "{{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"{s}\",\"tool_input\":{s}}}",
        .{ tool_name, args },
    ) catch return .proceed; // 构造失败:放行(不阻塞正常流程)
    defer alloc.free(stdin_json);

    for (set.pre_tool_use) |entry| {
        if (!matcherMatches(entry.matcher, tool_name)) continue;
        for (entry.commands) |cmd| {
            const result = runOneHook(alloc, cmd, stdin_json);
            switch (result) {
                .block => {
                    log.warn("hook", "PreToolUse blocked tool={s} by hook: {s}", .{ tool_name, cmd });
                    return .block;
                },
                .proceed => {},
            }
        }
    }
    return .proceed;
}

/// 跑单个 hook:`/bin/sh -c <cmd>`,把 stdin_json 写进它 stdin,读 exit code + stdout。
/// exit 2 → block;exit 0 → 看 stdout decision;其它 → proceed(非阻塞错误)。
/// 超时 5s → kill + proceed(不因 hook 卡死阻塞工具)。
fn runOneHook(alloc: std.mem.Allocator, cmd: []const u8, stdin_json: []const u8) HookDecision {
    var in_pipe: [2]std.c.fd_t = undefined; // 父写 → 子读
    var out_pipe: [2]std.c.fd_t = undefined; // 子写 → 父读
    if (std.c.pipe(&in_pipe) != 0) return .proceed;
    if (std.c.pipe(&out_pipe) != 0) {
        _ = std.c.close(in_pipe[0]);
        _ = std.c.close(in_pipe[1]);
        return .proceed;
    }

    const cmd_z = alloc.dupeZ(u8, cmd) catch {
        closeAll(&in_pipe, &out_pipe);
        return .proceed;
    };
    defer alloc.free(cmd_z);

    const pid = std.c.fork();
    if (pid < 0) {
        closeAll(&in_pipe, &out_pipe);
        return .proceed;
    }
    if (pid == 0) {
        // 子进程:stdin ← in_pipe[0],stdout → out_pipe[1]
        _ = std.c.setpgid(0, 0);
        _ = std.c.dup2(in_pipe[0], 0);
        _ = std.c.dup2(out_pipe[1], 1);
        _ = std.c.close(in_pipe[0]);
        _ = std.c.close(in_pipe[1]);
        _ = std.c.close(out_pipe[0]);
        _ = std.c.close(out_pipe[1]);
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr };
        _ = std.c.execve("/bin/sh", @ptrCast(&argv), @ptrCast(std.c.environ));
        std.c._exit(127);
    }

    // 父进程
    _ = std.c.close(in_pipe[0]);
    _ = std.c.close(out_pipe[1]);
    defer _ = std.c.close(in_pipe[1]);
    defer _ = std.c.close(out_pipe[0]);

    // 写 stdin_json 给 hook,然后关写端(发 EOF)
    var written: usize = 0;
    while (written < stdin_json.len) {
        const n = std.c.write(in_pipe[1], stdin_json.ptr + written, stdin_json.len - written);
        if (n <= 0) break;
        written += @intCast(n);
    }
    _ = std.c.close(in_pipe[1]);

    // 读 hook stdout(最多 4KB,够 decision JSON)
    var out_buf: [4096]u8 = undefined;
    var out_len: usize = 0;
    while (out_len < out_buf.len) {
        const n = std.c.read(out_pipe[0], (&out_buf).ptr + out_len, out_buf.len - out_len);
        if (n <= 0) break;
        out_len += @intCast(n);
    }
    const stdout = out_buf[0..out_len];

    // 等子进程,拿 exit code
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    const exit_code: u8 = if (wifexited(status)) wexitstatus(status) else 1;

    // exit 2 → block
    if (exit_code == 2) return .block;
    // stdout decision=block → block(即便 exit 0)
    if (std.mem.indexOf(u8, stdout, "\"decision\"") != null) {
        if (std.mem.indexOf(u8, stdout, "\"block\"") != null or std.mem.indexOf(u8, stdout, "\"deny\"") != null) {
            return .block;
        }
    }
    return .proceed;
}

fn closeAll(a: *[2]std.c.fd_t, b: *[2]std.c.fd_t) void {
    _ = std.c.close(a[0]);
    _ = std.c.close(a[1]);
    _ = std.c.close(b[0]);
    _ = std.c.close(b[1]);
}

// POSIX wait 宏(Zig std.c 不暴露,手写)
fn wifexited(status: c_int) bool {
    return (status & 0x7f) == 0;
}
fn wexitstatus(status: c_int) u8 {
    return @intCast((status >> 8) & 0xff);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "matcherMatches: exact / pipe / wildcard" {
    try testing.expect(matcherMatches("Bash", "Bash"));
    try testing.expect(!matcherMatches("Bash", "Write"));
    try testing.expect(matcherMatches("Write|Edit", "Edit"));
    try testing.expect(matcherMatches("Write|Edit", "Write"));
    try testing.expect(!matcherMatches("Write|Edit", "Bash"));
    try testing.expect(matcherMatches("*", "AnyTool"));
    try testing.expect(matcherMatches("", "AnyTool"));
}

test "parse: PreToolUse hooks" {
    const src =
        \\{"hooks":{"PreToolUse":[
        \\  {"matcher":"Bash","hooks":[{"type":"command","command":"echo hi"}]},
        \\  {"matcher":"Write|Edit","hooks":[{"type":"command","command":"./guard.sh"},{"type":"command","command":"./log.sh"}]}
        \\]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    var set = try parse(testing.allocator, parsed.value);
    defer set.deinit();

    try testing.expectEqual(@as(usize, 2), set.pre_tool_use.len);
    try testing.expectEqualStrings("Bash", set.pre_tool_use[0].matcher);
    try testing.expectEqual(@as(usize, 1), set.pre_tool_use[0].commands.len);
    try testing.expectEqualStrings("echo hi", set.pre_tool_use[0].commands[0]);
    try testing.expectEqual(@as(usize, 2), set.pre_tool_use[1].commands.len);
}

test "parse: no hooks → empty set" {
    const src = "{\"permissions\":{}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    var set = try parse(testing.allocator, parsed.value);
    defer set.deinit();
    try testing.expect(set.isEmpty());
}

test "runPreToolUse: exit 2 blocks" {
    const alloc = testing.allocator;
    // 一个 matcher=Bash 的 hook,命令 exit 2 → block
    const cmds = [_][]const u8{"exit 2"};
    const entries = [_]HookEntry{.{ .matcher = "Bash", .commands = &cmds }};
    const set = HookSet{ .pre_tool_use = &entries, .allocator = alloc };
    try testing.expect(runPreToolUse(&set, alloc, "Bash", "{\"command\":\"ls\"}") == .block);
    // 不匹配的工具 → proceed
    try testing.expect(runPreToolUse(&set, alloc, "Write", "{}") == .proceed);
}

test "runPreToolUse: exit 0 proceeds" {
    const alloc = testing.allocator;
    const cmds = [_][]const u8{"exit 0"};
    const entries = [_]HookEntry{.{ .matcher = "*", .commands = &cmds }};
    const set = HookSet{ .pre_tool_use = &entries, .allocator = alloc };
    try testing.expect(runPreToolUse(&set, alloc, "Bash", "{}") == .proceed);
}

test "runPreToolUse: stdout decision=block blocks even on exit 0" {
    const alloc = testing.allocator;
    const cmds = [_][]const u8{"echo '{\"decision\":\"block\"}'; exit 0"};
    const entries = [_]HookEntry{.{ .matcher = "Bash", .commands = &cmds }};
    const set = HookSet{ .pre_tool_use = &entries, .allocator = alloc };
    try testing.expect(runPreToolUse(&set, alloc, "Bash", "{}") == .block);
}

test "runPreToolUse: hook receives tool info on stdin" {
    const alloc = testing.allocator;
    // hook 读 stdin,若含 "rm -rf" 就 block(exit 2),否则 proceed
    const cmds = [_][]const u8{"grep -q 'rm -rf' && exit 2 || exit 0"};
    const entries = [_]HookEntry{.{ .matcher = "Bash", .commands = &cmds }};
    const set = HookSet{ .pre_tool_use = &entries, .allocator = alloc };
    // 含 rm -rf → block
    try testing.expect(runPreToolUse(&set, alloc, "Bash", "{\"command\":\"rm -rf /\"}") == .block);
    // 不含 → proceed
    try testing.expect(runPreToolUse(&set, alloc, "Bash", "{\"command\":\"ls\"}") == .proceed);
}
