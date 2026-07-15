//! L2 组件测试:--add-dir / additionalDirectories 消费链路端到端贯穿。
//!
//! 修复对象(2026-07-15 U1):additional_directories 此前**存储链完整但消费链为空**
//! (settings.evaluate 与 decision.check 都不读它,唯一消费点是状态打印)——
//! `/add-dir` 的授权承诺落空。本测试锁定两条真实消费链:
//!
//!   链 A(权限):--add-dir NUL 串 → buildInlineLayer → Layer.additional_directories
//!     → collectAdditionalDirs → resolveAdditionalDirs(App.rebuildAdditionalDirs seam)
//!     → match_ctx.additional_dirs → checkPermission:accept_edits 模式下
//!     集内 Write=allow / 集外 Write=ask(对齐 cc:acceptEdits 只自动接受工作目录集内编辑)。
//!
//!   链 B(沙箱):additional_dirs → sandbox profile generate → SBPL
//!     `(allow file-write* (subpath <add-dir>))`。
//!
//! 跨 ≥3 模块(settings/rule_spec/decision/permission shim + sandbox/profile),
//! 符合 doc/E2E_TESTING.md §3.2 L2 必要条件。

const std = @import("std");
const cc = @import("cc");

const settings_mod = cc.permission_settings;

/// 搭一条 CLI 层链:--add-dir a\x00b → MergedSettings + 解析后的绝对目录列表。
fn buildCliChain(
    a: std.mem.Allocator,
    dirs_nul: []const u8,
    cwd: []const u8,
    home: []const u8,
) !struct {
    layers: []settings_mod.Layer,
    resolved: []const []const u8,
    fn deinitAll(self: *@This(), alloc: std.mem.Allocator) void {
        for (self.resolved) |d| alloc.free(d);
        alloc.free(self.resolved);
        for (self.layers) |L| {
            for (L.allow) |r| alloc.free(r.raw);
            for (L.ask) |r| alloc.free(r.raw);
            for (L.deny) |r| alloc.free(r.raw);
            alloc.free(L.allow);
            alloc.free(L.ask);
            alloc.free(L.deny);
            for (L.additional_directories) |d| alloc.free(d);
            alloc.free(L.additional_directories);
        }
        alloc.free(self.layers);
    }
} {
    const cli_layer = try settings_mod.buildInlineLayer(a, .cli, null, null, null, dirs_nul);
    const layers = try a.alloc(settings_mod.Layer, 1);
    layers[0] = cli_layer;
    var ms = settings_mod.MergedSettings{ .layers = layers, .allocator = a };
    // 只借 collect(元素 borrow layer),再走 resolve seam(与 App.rebuildAdditionalDirs 同路)
    const raw = try ms.collectAdditionalDirs(a);
    defer a.free(raw);
    const resolved = try settings_mod.resolveAdditionalDirs(a, raw, cwd, home);
    return .{ .layers = layers, .resolved = resolved };
}

test "L2 链A: --add-dir 目录内 Write 在 accept_edits 自动放行,集外 ask" {
    const a = std.testing.allocator;
    var chain = try buildCliChain(a, "/extra/lib\x00rel/sub\x00~/notes", "/proj", "/home/u");
    defer chain.deinitAll(a);

    // 解析结果:绝对原样 / 相对锚 cwd / ~ 锚 home
    try std.testing.expectEqual(@as(usize, 3), chain.resolved.len);
    try std.testing.expectEqualStrings("/extra/lib", chain.resolved[0]);
    try std.testing.expectEqualStrings("/proj/rel/sub", chain.resolved[1]);
    try std.testing.expectEqualStrings("/home/u/notes", chain.resolved[2]);

    const perm_ctx = cc.permission.PermissionContext{
        .mode = .init(.accept_edits),
        .allocator = a,
        .match_ctx = .{
            .cwd = "/proj",
            .project_root = "/proj",
            .home = "/home/u",
            .additional_dirs = chain.resolved,
        },
    };

    // cwd 内:自动放行(原有语义)
    try std.testing.expect(cc.permission.checkPermission(&perm_ctx, "Write", "{\"file_path\":\"/proj/src/a.zig\",\"content\":\"x\"}") == .allow);
    // --add-dir 绝对目录内:自动放行(本修复的核心承诺)
    try std.testing.expect(cc.permission.checkPermission(&perm_ctx, "Write", "{\"file_path\":\"/extra/lib/gen.md\",\"content\":\"x\"}") == .allow);
    // --add-dir 相对目录(锚 cwd)内:自动放行
    try std.testing.expect(cc.permission.checkPermission(&perm_ctx, "Edit", "{\"file_path\":\"/proj/rel/sub/f.txt\",\"old_string\":\"a\",\"new_string\":\"b\"}") == .allow);
    // --add-dir ~ 目录内:自动放行
    try std.testing.expect(cc.permission.checkPermission(&perm_ctx, "Write", "{\"file_path\":\"/home/u/notes/n.md\",\"content\":\"x\"}") == .allow);
    // 工作目录集外:ask(不再无条件放行——收窄对齐 cc)
    try std.testing.expect(cc.permission.checkPermission(&perm_ctx, "Write", "{\"file_path\":\"/somewhere/else.txt\",\"content\":\"x\"}") == .ask);
    // `..` 词法逃逸出 add-dir → ask
    try std.testing.expect(cc.permission.checkPermission(&perm_ctx, "Write", "{\"file_path\":\"/extra/lib/../../etc/x\",\"content\":\"x\"}") == .ask);
}

test "L2 链A(B1 绕过): JSON 转义 .. 逃逸 add-dir 集被 unescape 拦成 ask(经公共 checkPermission)" {
    const a = std.testing.allocator;
    var chain = try buildCliChain(a, "/extra/lib", "/proj", "/home/u");
    defer chain.deinitAll(a);

    // 经公共入口 checkPermission(它填 path_check_allocator=ctx.allocator,与工具层落盘等价)
    const perm_ctx = cc.permission.PermissionContext{
        .mode = .init(.accept_edits),
        .allocator = a,
        .match_ctx = .{ .cwd = "/proj", .project_root = "/proj", .home = "/home/u", .additional_dirs = chain.resolved },
    };
    // `..` = ".." 转义:未 unescape 时 startsWith /extra/lib/ 骗过 scope→allow;
    // unescape 后折叠逃出集 → 必须 ask(这是修复前会 FAIL 的红灯)。
    try std.testing.expect(cc.permission.checkPermission(&perm_ctx, "Write", "{\"file_path\":\"/extra/lib/\\u002e\\u002e/\\u002e\\u002e/etc/pwn\",\"content\":\"x\"}") == .ask);
    // 明文 .. 逃逸同样 ask
    try std.testing.expect(cc.permission.checkPermission(&perm_ctx, "Edit", "{\"file_path\":\"/extra/lib/../../etc/pwn\",\"old_string\":\"a\",\"new_string\":\"b\"}") == .ask);
    // 集内合法路径(含转义字符)仍 allow,不误伤
    try std.testing.expect(cc.permission.checkPermission(&perm_ctx, "Write", "{\"file_path\":\"/extra/lib/\\u0067en.md\",\"content\":\"x\"}") == .allow);
}

test "L2 链A: 未配 add-dir 时 accept_edits 集外 ask(基线);default 模式 add-dir 不放宽(仍 ask)" {
    const a = std.testing.allocator;
    // 基线:无 additional_dirs,只有 cwd
    const perm_base = cc.permission.PermissionContext{
        .mode = .init(.accept_edits),
        .allocator = a,
        .match_ctx = .{ .cwd = "/proj", .project_root = "/proj", .home = "/home/u" },
    };
    try std.testing.expect(cc.permission.checkPermission(&perm_base, "Write", "{\"file_path\":\"/extra/lib/gen.md\",\"content\":\"x\"}") == .ask);

    // default 模式:add-dir 不改变 Write 的 ask(对齐 cc:default 编辑总是询问)
    var chain = try buildCliChain(a, "/extra/lib", "/proj", "/home/u");
    defer chain.deinitAll(a);
    const perm_default = cc.permission.PermissionContext{
        .mode = .init(.default),
        .allocator = a,
        .match_ctx = .{ .cwd = "/proj", .project_root = "/proj", .home = "/home/u", .additional_dirs = chain.resolved },
    };
    try std.testing.expect(cc.permission.checkPermission(&perm_default, "Write", "{\"file_path\":\"/extra/lib/gen.md\",\"content\":\"x\"}") == .ask);
}

test "L2 链A: settings JSON additionalDirectories 同链生效(parseLayer 路径)" {
    const a = std.testing.allocator;
    const src = "{\"permissions\":{\"additionalDirectories\":[\"/extra/from-settings\"]}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, a, src, .{});
    defer parsed.deinit();
    const L = try settings_mod.parseLayer(a, .user, parsed.value);
    const layers = try a.alloc(settings_mod.Layer, 1);
    layers[0] = L;
    var ms = settings_mod.MergedSettings{ .layers = layers, .allocator = a };
    defer ms.deinit();

    const raw = try ms.collectAdditionalDirs(a);
    defer a.free(raw);
    const resolved = try settings_mod.resolveAdditionalDirs(a, raw, "/proj", "/home/u");
    defer {
        for (resolved) |d| a.free(d);
        a.free(resolved);
    }

    const perm_ctx = cc.permission.PermissionContext{
        .mode = .init(.accept_edits),
        .allocator = a,
        .match_ctx = .{ .cwd = "/proj", .project_root = "/proj", .home = "/home/u", .additional_dirs = resolved },
    };
    try std.testing.expect(cc.permission.checkPermission(&perm_ctx, "Edit", "{\"file_path\":\"/extra/from-settings/x.zig\",\"old_string\":\"a\",\"new_string\":\"b\"}") == .allow);
}

test "L2(B1 第4镜像点): settings allow 规则 Write(/**) 不放行 .. 逃逸(经公共 checkPermission)" {
    const a = std.testing.allocator;
    // 用户常见配置:allow 放行整个项目源码树。
    const src = "{\"permissions\":{\"allow\":[\"Write(/**)\"]}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, a, src, .{});
    defer parsed.deinit();
    const L = try settings_mod.parseLayer(a, .user, parsed.value);
    const layers = try a.alloc(settings_mod.Layer, 1);
    layers[0] = L;
    var ms = settings_mod.MergedSettings{ .layers = layers, .allocator = a };
    defer ms.deinit(); // 释放 layers slice + 各 rule.raw + additional_directories(勿再 a.free(layers))

    // 经公共入口:PermissionContext.allocator 非可选,match_ctx.alloc 必须由 App 填;
    // 这里显式填以复现生产(App.loadSettings 填 .alloc = app.allocator)。
    const perm_ctx = cc.permission.PermissionContext{
        .mode = .init(.default),
        .allocator = a,
        .settings = &ms,
        .match_ctx = .{ .cwd = "/proj", .project_root = "/proj", .alloc = a },
    };
    // sanity:圈内 allow(规则生效)
    try std.testing.expect(cc.permission.checkPermission(&perm_ctx, "Write", "{\"file_path\":\"/proj/src/a.zig\"}") == .allow);
    // .. 逃逸:折叠成 /etc/passwd 出圈 → 规则不命中 → 落 default → ask(修复前静默 allow 落盘 /etc/passwd)
    try std.testing.expect(cc.permission.checkPermission(&perm_ctx, "Write", "{\"file_path\":\"/proj/../../etc/passwd\"}") == .ask);
    // 转义 .. 同样 ask
    try std.testing.expect(cc.permission.checkPermission(&perm_ctx, "Write", "{\"file_path\":\"/proj/\\u002e\\u002e/\\u002e\\u002e/etc/passwd\"}") == .ask);
}

test "L2 链B: additional_dirs 进 sandbox SBPL 可写白名单" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var chain = try buildCliChain(a, "/private/tmp/cczig_adddir_sb", "/proj", "/home/u");
    defer chain.deinitAll(a);

    const prof = try cc.sandbox_profile.generate(a, .{
        .cwd = "/private/tmp",
        .home = "/home/u",
        .additional_dirs = chain.resolved,
    });
    defer a.free(prof);

    // add-dir 出现在 allow file-write* 段
    try std.testing.expect(std.mem.indexOf(u8, prof, "(subpath \"/private/tmp/cczig_adddir_sb\")") != null);
    const allow_at = std.mem.indexOf(u8, prof, "(allow file-write*").?;
    const dir_at = std.mem.indexOf(u8, prof, "cczig_adddir_sb").?;
    try std.testing.expect(dir_at > allow_at);
}
