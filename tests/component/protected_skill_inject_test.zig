//! L2 组件测试:protected paths 覆盖 allow 规则 + Skill !cmd bash 注入(原弱/零 L2)。
//!
//! 两块原先只有模块内单元测(在主 cc-test 套件——已知 integration 挂起,不可靠跑),
//! 这里经 cc 模块重导出,放进 test:new 隔离套件可靠运行。

const std = @import("std");
const cc = @import("cc");

const decision = cc.permission_decision;
const settings_mod = cc.permission_settings;
const rule_spec = cc.permission_rule_spec;
const render = cc.skills_render;

test "L2 protected paths: allow Write(./**) 下 .env/.git 仍 ask" {
    const a = std.testing.allocator;
    const src = "{\"permissions\":{\"allow\":[\"Write(./**)\"]}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, a, src, .{});
    defer parsed.deinit();
    const L = try settings_mod.parseLayer(a, .user, parsed.value);
    const layers = try a.alloc(settings_mod.Layer, 1);
    layers[0] = L;
    var ms = settings_mod.MergedSettings{ .layers = layers, .allocator = a };
    defer ms.deinit();

    const mctx = rule_spec.MatchContext{ .cwd = "/proj" };
    const ctx = decision.Context{ .mode = .default, .settings = &ms, .match_ctx = mctx };

    // 普通文件:allow 命中
    try std.testing.expect(decision.check(&ctx, "Write", "{\"file_path\":\"/proj/src/foo.zig\"}") == .allow);
    // protected 覆盖 → ask
    try std.testing.expect(decision.check(&ctx, "Write", "{\"file_path\":\"/proj/.env\"}") == .ask);
    try std.testing.expect(decision.check(&ctx, "Edit", "{\"file_path\":\"/proj/.git/config\"}") == .ask);
    try std.testing.expect(decision.check(&ctx, "Write", "{\"file_path\":\"/proj/.ssh/id_rsa\"}") == .ask);
}

test "L2 skill !cmd: 行首 inline 注入运行并替换为 stdout" {
    const a = std.testing.allocator;
    const out = try render.renderBody(a, "Output: !`echo INJECTED`", .{});
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Output: INJECTED") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "echo INJECTED") == null); // 占位被替换,不留命令
}

test "L2 skill !cmd: 紧跟非空白(KEY=!`cmd`)不识别(保留字面)" {
    const a = std.testing.allocator;
    const out = try render.renderBody(a, "KEY=!`echo X`", .{});
    defer a.free(out);
    try std.testing.expectEqualStrings("KEY=!`echo X`", out);
}

test "L2 skill !cmd: disable_shell_execution 占位替成 policy 文案,不执行" {
    const a = std.testing.allocator;
    const out = try render.renderBody(a, "x !`echo SHOULD_NOT_RUN` y", .{ .disable_shell_execution = true });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "disabled by policy") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SHOULD_NOT_RUN") == null);
}

test "L2 skill !cmd: 失败命令产占位 + 不中止渲染(前后文保留)" {
    const a = std.testing.allocator;
    const out = try render.renderBody(a, "pre !`/no-such-bin-xyz-99` post", .{ .inject_timeout_ms = 2000 });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "pre ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " post") != null);
}
