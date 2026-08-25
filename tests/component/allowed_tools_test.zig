//! L2 组件测试:--allowedTools/--disallowedTools CLI flag 端到端贯穿。
//!
//! 设计目标(tests/README.md L2 组件层):
//!   `metacodes --allowedTools "Bash(git *),Read"` →
//!   permission.decision.check(Bash, "git status") = .allow(命中 CLI 层 allow)
//!   `--disallowedTools "Bash(rm *)"` →
//!   permission.decision.check(Bash, "rm foo") = .deny(命中 CLI 层 deny)
//!
//! 本测试不发 HTTP — 它是"跨模块字段贯穿"型 L2:CLI parseArgs → Config →
//! permission/loader buildInlineLayer → settings.evaluate → decision.check。
//!
//! 跨 ≥3 模块,符合 tests/README.md 的 L2 必要条件。

const std = @import("std");
const cc = @import("cc");

test "L2: --allowedTools 'Bash(git *)' → Bash(git status) 在 default 模式 allow" {
    const a = std.testing.allocator;

    // 模拟 parseArgs 的产物:--allowedTools 累加到 Config.allowed_tools
    // 然后 loader 把这 CSV 串包装成 CLI 层 allow rules
    const settings_mod = @import("cc").permission.MergedSettings;
    _ = settings_mod;

    const builder = @import("cc").permission_settings;
    const cli_layer = try builder.buildInlineLayer(
        a,
        .cli,
        "Bash(git *),Read",
        null,
        null,
        null,
    );
    defer {
        for (cli_layer.allow) |r| a.free(r.raw);
        for (cli_layer.ask) |r| a.free(r.raw);
        for (cli_layer.deny) |r| a.free(r.raw);
        a.free(cli_layer.allow);
        a.free(cli_layer.ask);
        a.free(cli_layer.deny);
        a.free(cli_layer.additional_directories);
    }

    const layers = try a.alloc(builder.Layer, 1);
    defer a.free(layers);
    layers[0] = cli_layer;

    var ms = cc.permission.MergedSettings{ .layers = layers, .allocator = a };

    const perm_ctx = cc.permission.PermissionContext{
        .mode = .init(.default),
        .allocator = a,
        .settings = &ms,
    };

    // git status 命中 Bash(git *) allow → .allow(不用 ask)
    try std.testing.expect(
        cc.permission.checkPermission(&perm_ctx, "Bash", "{\"command\":\"git status\"}") == .allow,
    );
    // npm test 不在 allow → default 模式 → .ask
    try std.testing.expect(
        cc.permission.checkPermission(&perm_ctx, "Bash", "{\"command\":\"npm test\"}") == .ask,
    );
    // Read 整工具 allow → .allow
    try std.testing.expect(
        cc.permission.checkPermission(&perm_ctx, "Read", "{\"file_path\":\"/x\"}") == .allow,
    );
}

test "L2: --disallowedTools 'Bash(rm *)' → Bash(rm foo) deny" {
    const a = std.testing.allocator;

    const builder = @import("cc").permission_settings;
    const cli_layer = try builder.buildInlineLayer(
        a,
        .cli,
        null,
        null,
        "Bash(rm *)",
        null,
    );
    defer {
        for (cli_layer.allow) |r| a.free(r.raw);
        for (cli_layer.ask) |r| a.free(r.raw);
        for (cli_layer.deny) |r| a.free(r.raw);
        a.free(cli_layer.allow);
        a.free(cli_layer.ask);
        a.free(cli_layer.deny);
        a.free(cli_layer.additional_directories);
    }

    const layers = try a.alloc(builder.Layer, 1);
    defer a.free(layers);
    layers[0] = cli_layer;

    var ms = cc.permission.MergedSettings{ .layers = layers, .allocator = a };

    const perm_ctx = cc.permission.PermissionContext{
        .mode = .init(.default),
        .allocator = a,
        .settings = &ms,
    };

    // rm foo 命中 deny → .deny
    try std.testing.expect(
        cc.permission.checkPermission(&perm_ctx, "Bash", "{\"command\":\"rm foo\"}") == .deny,
    );
    // ls 不命中 deny,readonly auto-allow
    try std.testing.expect(
        cc.permission.checkPermission(&perm_ctx, "Bash", "{\"command\":\"ls\"}") == .allow,
    );
}

test "L2: --allowedTools + --disallowedTools 同时 → deny 优先" {
    const a = std.testing.allocator;

    const builder = @import("cc").permission_settings;
    const cli_layer = try builder.buildInlineLayer(
        a,
        .cli,
        "Bash(git *)", // allow git *
        null,
        "Bash(git push)", // deny git push 具体
        null,
    );
    defer {
        for (cli_layer.allow) |r| a.free(r.raw);
        for (cli_layer.ask) |r| a.free(r.raw);
        for (cli_layer.deny) |r| a.free(r.raw);
        a.free(cli_layer.allow);
        a.free(cli_layer.ask);
        a.free(cli_layer.deny);
        a.free(cli_layer.additional_directories);
    }

    const layers = try a.alloc(builder.Layer, 1);
    defer a.free(layers);
    layers[0] = cli_layer;

    var ms = cc.permission.MergedSettings{ .layers = layers, .allocator = a };

    const perm_ctx = cc.permission.PermissionContext{
        .mode = .init(.default),
        .allocator = a,
        .settings = &ms,
    };

    // git status:allow 命中(deny 没命中)
    try std.testing.expect(
        cc.permission.checkPermission(&perm_ctx, "Bash", "{\"command\":\"git status\"}") == .allow,
    );
    // git push:虽 allow Bash(git *) 命中,但 deny Bash(git push) 也命中 → deny 优先
    try std.testing.expect(
        cc.permission.checkPermission(&perm_ctx, "Bash", "{\"command\":\"git push\"}") == .deny,
    );
}
