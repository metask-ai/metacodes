//! L2 组件测试:Bash 复合命令(&& || ; | |& & 换行)的权限规则匹配。
//!
//! 规则只描述**单条**命令。rule_spec.matchesMode 把复合命令拆段(splitCompound + 逐段
//! stripWrappers)后按规则种类聚合:
//!   - allow:**每段**都匹中才命中——`git add . && npm publish` 不被 Bash(git *) 放行;
//!   - deny/ask:**任一段**匹中即命中——`ls && rm x` 的 rm 段触发 Bash(rm *),无害前缀
//!     稀释不了用户的 deny(与 path 规则 deny/ask 的"任一路径匹配"对称)。
//! 拆的是 shell 真正收到的字节(与 Bash 工具同一取字段 + JSON unescape):args 里的 `\n`、
//! `\u0026\u0026` 是真分隔符,`\"…\"` 内的分隔符不拆。
//! 修复前 deny/ask 也要求"每段都匹中",`ls && rm x` 在 bypass_permissions(兜底 allow)与
//! default(首词 ls 走 readonly 免询问)下都绕过了用户的 deny 规则;下方经
//! cc.permission.checkPermission 端到端锁定两种模式下 deny 都赢。
//! 注:`rm -rf /` 这类硬危险命令另由 shell_lex.validate(扫所有段)兜底,不依赖规则系统。

const std = @import("std");
const cc = @import("cc");

const rs = cc.permission_rule_spec;
const Decision = cc.permission.PermissionResult;

/// `command` 是 JSON 字符串原文,原样拼进 args(`\\n` 即 JSON 转义的换行,shell 收到真换行)。
fn ruleMatch(rule: []const u8, command: []const u8, mode: rs.RuleMode) !bool {
    const spec = try rs.parseRule(rule);
    const mctx = rs.MatchContext{ .cwd = "/x", .project_root = "/x", .home = "/h" };
    var abuf: [512]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"command\":\"{s}\"}}", .{command});
    return rs.matchesMode(&spec, &mctx, "Bash", args, mode);
}

fn denyMatch(rule: []const u8, command: []const u8) !bool {
    return ruleMatch(rule, command, .deny);
}

fn askMatch(rule: []const u8, command: []const u8) !bool {
    return ruleMatch(rule, command, .ask);
}

fn allowMatch(rule: []const u8, command: []const u8) !bool {
    return ruleMatch(rule, command, .allow);
}

/// 同一条 `rm x` 跟在无害的 `ls` 之后的各种分隔写法(JSON 字符串原文)。
const rm_after_ls = [_][]const u8{
    "ls && rm x",
    "ls; rm x",
    "ls | rm x",
    "ls\\nrm x",
    "ls || rm x",
    "ls & rm x",
    "ls |& rm x",
    "ls \\u0026\\u0026 rm x",
};

test "L2 复合命令: 单段 rm foo 命中 Bash(rm *)" {
    try std.testing.expect(try denyMatch("Bash(rm *)", "rm foo"));
}

test "L2 复合命令: 每段都 rm 时 allow 与 deny 都命中" {
    try std.testing.expect(try denyMatch("Bash(rm *)", "rm a && rm b"));
    try std.testing.expect(try allowMatch("Bash(rm *)", "rm a; rm b"));
}

test "L2 复合命令: allow Bash(git *) 要求每段都 git(npm 段使整体不放行)" {
    try std.testing.expect(try allowMatch("Bash(git *)", "git add . && git commit -m x"));
    // 混入非 git 段 → allow 不命中(更严,正确)
    try std.testing.expect(!try allowMatch("Bash(git *)", "git add . && npm publish"));
}

test "L2 复合命令: deny/ask Bash(rm *) 任一段命中即命中(无害前缀不稀释)" {
    for (rm_after_ls) |command| {
        errdefer std.debug.print("command: {s}\n", .{command});
        try std.testing.expect(try denyMatch("Bash(rm *)", command));
        try std.testing.expect(try askMatch("Bash(rm *)", command));
        // 同一 pattern 作 allow 仍要每段都匹中:ls 段不是 rm → 不放行
        try std.testing.expect(!try allowMatch("Bash(rm *)", command));
    }
    // 没有 rm 段:拆段不放大命中面
    try std.testing.expect(!try denyMatch("Bash(rm *)", "ls && echo rm"));
    try std.testing.expect(!try denyMatch("Bash(rm *)", "echo 'ls && rm x'")); // 引号内不拆
}

test "L2 复合命令: 按 shell 收到的字节拆段(JSON 转义的分隔符与引号)" {
    // `\u003b` = `;`、`\u007c` = `|`、`\r\n`:unescape 后才是分隔符
    try std.testing.expect(try denyMatch("Bash(rm *)", "ls\\u003b rm x"));
    try std.testing.expect(try denyMatch("Bash(rm *)", "ls \\u007c rm x"));
    try std.testing.expect(try denyMatch("Bash(rm *)", "ls\\r\\nrm x"));
    // allow 不再被转义换行骗过:第二段 rm -rf x 不是 echo
    try std.testing.expect(!try allowMatch("Bash(echo *)", "echo hi\\nrm -rf x"));
    try std.testing.expect(try allowMatch("Bash(echo *)", "echo hi\\necho there"));
    // `\"` 是真引号:引号内的 `;` 不拆——deny 不误伤,allow 不误拒
    try std.testing.expect(!try denyMatch("Bash(rm *)", "echo \\\"a; rm x\\\""));
    try std.testing.expect(try allowMatch("Bash(echo *)", "echo \\\"a; rm x\\\""));
}

test "L2 复合命令: wrapper 剥离后再匹配(timeout/nohup)" {
    // stripWrappers 去掉 timeout/nohup 等前缀再比对 pattern;复合命令逐段剥。
    try std.testing.expect(try denyMatch("Bash(rm *)", "timeout 5 rm foo"));
    try std.testing.expect(try denyMatch("Bash(rm *)", "nohup rm foo"));
    try std.testing.expect(try denyMatch("Bash(rm *)", "ls && timeout 5 rm foo"));
    try std.testing.expect(try denyMatch("Bash(rm *)", "ls; nohup rm foo"));
}

// ---------------------------------------------------------------------------
// 端到端:settings.json permissions 段 → parseLayer → settings.evaluate →
// decision → cc.permission.checkPermission
// ---------------------------------------------------------------------------

/// 一层 settings.json(loader 对每个文件走的同一个 parseLayer)。caller deinit。
fn loadSettings(gpa: std.mem.Allocator, json: []const u8) !cc.permission.MergedSettings {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const layers = try gpa.alloc(cc.permission_settings.Layer, 1);
    errdefer gpa.free(layers);
    layers[0] = try cc.permission_settings.parseLayer(gpa, .user, parsed.value);
    return .{ .layers = layers, .allocator = gpa };
}

fn checkBash(ctx: *const cc.permission.PermissionContext, command: []const u8) !Decision {
    var abuf: [512]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"command\":\"{s}\"}}", .{command});
    return cc.permission.checkPermission(ctx, "Bash", args);
}

const deny_rm_settings =
    \\{"permissions":{"allow":["Bash(ls *)"],"deny":["Bash(rm *)"]}}
;

test "L2 checkPermission: bypass_permissions 下 deny Bash(rm *) 对各种复合写法都赢" {
    const gpa = std.testing.allocator;
    var settings = try loadSettings(gpa, deny_rm_settings);
    defer settings.deinit();
    const ctx = cc.permission.PermissionContext{
        .mode = .init(.bypass_permissions),
        .allocator = gpa,
        .settings = &settings,
    };
    for (rm_after_ls) |command| {
        errdefer std.debug.print("command: {s}\n", .{command});
        try std.testing.expectEqual(Decision.deny, try checkBash(&ctx, command));
    }
    // 对照:没有 rm 段 → bypass 兜底放行(deny 只因 rm 段生效)
    try std.testing.expectEqual(Decision.allow, try checkBash(&ctx, "ls && echo ok"));
}

test "L2 checkPermission: default 模式下 deny Bash(rm *) 对各种复合写法都赢" {
    const gpa = std.testing.allocator;
    var settings = try loadSettings(gpa, deny_rm_settings);
    defer settings.deinit();
    const ctx = cc.permission.PermissionContext{
        .mode = .init(.default),
        .allocator = gpa,
        .settings = &settings,
    };
    for (rm_after_ls) |command| {
        errdefer std.debug.print("command: {s}\n", .{command});
        try std.testing.expectEqual(Decision.deny, try checkBash(&ctx, command));
    }
    // 对照:没有 rm 段 → 不是 deny(allow 或 ask 由只读判定/模式兜底决定)
    try std.testing.expect(try checkBash(&ctx, "ls && echo ok") != .deny);
}

test "L2 checkPermission: ask Bash(rm *) 任一段命中 → bypass_permissions 下也 ask" {
    const gpa = std.testing.allocator;
    var settings = try loadSettings(gpa,
        \\{"permissions":{"ask":["Bash(rm *)"]}}
    );
    defer settings.deinit();
    const ctx = cc.permission.PermissionContext{
        .mode = .init(.bypass_permissions),
        .allocator = gpa,
        .settings = &settings,
    };
    for (rm_after_ls) |command| {
        errdefer std.debug.print("command: {s}\n", .{command});
        try std.testing.expectEqual(Decision.ask, try checkBash(&ctx, command));
    }
    try std.testing.expectEqual(Decision.allow, try checkBash(&ctx, "ls && echo ok"));
}

test "L2 checkPermission: allow Bash(npm *) 仍要每段都是 npm(转义换行骗不过 allow)" {
    const gpa = std.testing.allocator;
    var settings = try loadSettings(gpa,
        \\{"permissions":{"allow":["Bash(npm *)"]}}
    );
    defer settings.deinit();
    const ctx = cc.permission.PermissionContext{
        .mode = .init(.default),
        .allocator = gpa,
        .settings = &settings,
    };
    try std.testing.expectEqual(Decision.allow, try checkBash(&ctx, "npm test && npm run build"));
    // 混入 rm 段 → allow 不命中 → default 模式兜底 ask
    try std.testing.expectEqual(Decision.ask, try checkBash(&ctx, "npm test && rm x"));
    // JSON 转义的换行也是分隔符:修复前整串当一段,`npm *` 前缀匹中 → 放行了 rm
    try std.testing.expectEqual(Decision.ask, try checkBash(&ctx, "npm test\\nrm x"));
}
