//! L2 组件测试:符号能力缺失必须自证(issue #17)。
//!
//! 病灶:决策谓词只查静态注册表(扩展名),使用谓词查运行期(which → spawn → broken-set)。
//! 两者的差额——"注册了但没装"——以**裸空结果**的形式泄漏给模型,被读成"这个符号不存在"。
//!
//! 本文件走 `tools.dispatch` 整链(与 agent_loop 同一条路径),对三个共用 symbol_provider 的
//! 工具各钉一条:FindSymbol 不得返裸 `[]`,CodeMap 不得把能力缺失写成 "(no symbols)",
//! Read(outline) 不得静默回退。
//!
//! **测试必须两侧都跑到**:issue 指出老测试全都 `if (which("zls") == null) return SkipZigTest`,
//! 于是恰好跳过了 bug 所在的那一侧。这里的用例在装/没装 language server 的机器上都执行,
//! 断言取两种情形的公共不变量(必有限定语 + 原因具体),原因本身允许因机器而异。
//!
//! 文件末尾另一组用例钉 issue #17 的 follow-on:**LSP 默认开 + `--no-lsp` 逃生口**。
//! 声明=接线=证据——不只验 `Config.lsp_enabled` 解析出什么,还验它真的决定了 `App.lsp_service`
//! 是否存在(否则又是一个"parse 了但没接线"的静默 no-op)。

const std = @import("std");
const cc = @import("cc");
const pfs = @import("platform").fs;
const ppaths = @import("platform").paths;

const tools = cc.tools;
const ToolContext = cc.tool_context.ToolContext;
const Service = cc.lsp.service.Service;
const capability = cc.lsp.capability;
const symbol_provider = cc.symbol_provider;

fn dispatchOk(ctx: *const ToolContext, name: []const u8, args: []const u8) ![]u8 {
    var outcome = try tools.dispatch(ctx, name, args);
    return switch (outcome) {
        .ok => |*body| (try body.takeModelBytes(ctx.allocator)).bytes,
        else => {
            outcome.deinit(ctx.allocator);
            return error.UnexpectedDispatchOutcome;
        },
    };
}

fn mkdirAt(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    _ = std.c.mkdir(z.ptr, 0o755);
}

fn rmAt(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    _ = std.c.unlink(z.ptr);
}

fn rmdirAt(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    _ = std.c.rmdir(z.ptr);
}

fn writeAt(path: []const u8, content: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    const fd = pfs.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return;
    defer pfs.close(fd);
    _ = pfs.write(fd, content);
}

/// `/tmp/<tag>-<pid>/` 沙盒 + 一个源文件。**刻意不建 `.git`**:workspace 门因此必然关闭,
/// 于是装了 language server 的机器也会走到"能力缺失",两类机器上用例都真的执行到断言。
const Sandbox = struct {
    a: std.mem.Allocator,
    dir: []u8,
    file: []u8,
    svc: *Service,

    fn init(a: std.mem.Allocator, tag: []const u8, basename: []const u8, content: []const u8) !Sandbox {
        // 每进程唯一目录,根按平台选(util/fs.zig testing.tmpRoot);路径要嵌进 JSON 参数,已归一正斜杠。
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = try a.dupe(u8, cc.util_fs.testing.perPidDir(&dir_buf, tag));
        errdefer a.free(dir);
        mkdirAt(dir);
        const file = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, basename });
        errdefer a.free(file);
        writeAt(file, content);
        const svc = try Service.create(a, dir, null);
        return .{ .a = a, .dir = dir, .file = file, .svc = svc };
    }

    fn ctx(self: *const Sandbox) ToolContext {
        var c = ToolContext.simple(self.a);
        c.lsp = self.svc; // LSP **在位**:老代码的唯一限定分支在这里就被跳过了
        c.cwd_abs = self.dir;
        return c;
    }

    fn deinit(self: *Sandbox) void {
        self.svc.shutdown();
        rmAt(self.file);
        rmdirAt(self.dir);
        self.a.free(self.file);
        self.a.free(self.dir);
    }
};

/// 两类机器的公共不变量:结果里必须有一句点名了**具体**原因的限定语。
fn expectNamesAConcreteReason(text: []const u8) !void {
    const not_installed = std.mem.indexOf(u8, text, "not installed") != null;
    const outside_repo = std.mem.indexOf(u8, text, "outside a git workspace") != null;
    const not_started = std.mem.indexOf(u8, text, "could not be started") != null;
    const not_registered = std.mem.indexOf(u8, text, "not registered") != null;
    if (!(not_installed or outside_repo or not_started or not_registered)) {
        std.debug.print("no concrete capability reason in:\n{s}\n", .{text});
        return error.NoConcreteReason;
    }
}

// ============================================================================
// FindSymbol —— issue #17 的报告对象
// ============================================================================

test "L2 issue #17: FindSymbol 在 LSP 在位、符号能力缺失时不返裸 []" {
    const a = std.testing.allocator;
    var sb = try Sandbox.init(a, "cc-capgap-fs", "probe.zig", "pub fn CapGapProbeSymbol() void {}\n");
    defer sb.deinit();
    const ctx = sb.ctx();

    var abuf: [640]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"name\":\"CapGapProbeSymbol\",\"path\":\"{s}\"}}", .{sb.dir});
    const r = try dispatchOk(&ctx, "FindSymbol", args);
    defer a.free(r);

    try std.testing.expect(std.mem.startsWith(u8, r, "[]")); // 一个定义都没解析出来
    try std.testing.expect(!std.mem.eql(u8, r, "[]")); // 但**绝不是**裸 []
    try std.testing.expect(std.mem.indexOf(u8, r, "does NOT mean") != null);
    try expectNamesAConcreteReason(r);
}

test "L2 issue #17: FindSymbol 无 LSP 服务 → 同一套限定语(措辞不因分支而漂移)" {
    const a = std.testing.allocator;
    const ctx = ToolContext.simple(a); // 没装配 Service
    const r = try dispatchOk(&ctx, "FindSymbol", "{\"name\":\"CapGapProbeSymbol\"}");
    defer a.free(r);
    try std.testing.expect(!std.mem.eql(u8, r, "[]"));
    try std.testing.expect(std.mem.indexOf(u8, r, "does NOT mean") != null);
    // LSP 默认开之后,引导必须是"别关它",不能再劝用户加一个已经默认开的 --lsp。
    try std.testing.expect(std.mem.indexOf(u8, r, "--no-lsp") != null);
}

test "L2 issue #17: 候选文件混语言时,报最可操作的原因(别被 README 盖掉)" {
    // 一个顺带提到该名字的 .md 若"先到先得",结论就会变成"这种文件类型没注册 server",
    // 真正要说的那句(某个 server 没装 / 起不来)被盖掉,等于没修。
    // **合并规则本身由 capability.zig 的 moreActionable 单测确定性地钉死**;rg 的并行遍历
    // 不保证输出顺序,所以这里不假装能控制顺序——它验的是那条规则真的接进了 FindSymbol
    // 这条路:混语言候选下,结论必须落在可操作的那一侧,与 rg 先吐哪个无关。
    const a = std.testing.allocator;
    var sb = try Sandbox.init(a, "cc-capgap-mix", "aaa_readme.md", "mentions MixProbeSymbol in prose\n");
    defer sb.deinit();
    const src = try std.fmt.allocPrint(a, "{s}/zzz_probe.py", .{sb.dir});
    defer a.free(src);
    writeAt(src, "def MixProbeSymbol():\n    pass\n");
    defer rmAt(src);

    const ctx = sb.ctx();
    var abuf: [640]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"name\":\"MixProbeSymbol\",\"path\":\"{s}\"}}", .{sb.dir});
    const r = try dispatchOk(&ctx, "FindSymbol", args);
    defer a.free(r);

    try std.testing.expect(std.mem.startsWith(u8, r, "[]"));
    try std.testing.expect(std.mem.indexOf(u8, r, "does NOT mean") != null);
    // 核心断言:.md 那条"没注册 server"不得成为最终结论。
    // 没装 pyright → "not installed";装了 → /tmp 非 git 仓 → "outside a git workspace"。两者都比它可操作。
    try std.testing.expect(std.mem.indexOf(u8, r, "no language server is registered") == null);
    try expectNamesAConcreteReason(r);
}

// ============================================================================
// CodeMap / Read(outline) —— 共用 symbol_provider,同一个病根
// ============================================================================

test "L2 issue #17: CodeMap 报具体原因,不把能力缺失写成 (no symbols)" {
    const a = std.testing.allocator;
    var sb = try Sandbox.init(a, "cc-capgap-cm", "probe.zig", "pub const Probe = struct { x: u8 };\n");
    defer sb.deinit();
    const ctx = sb.ctx();

    var abuf: [640]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"path\":\"{s}\"}}", .{sb.file});
    const r = try dispatchOk(&ctx, "CodeMap", args);
    defer a.free(r);

    try std.testing.expect(std.mem.indexOf(u8, r, "no outline:") != null);
    // "(no symbols)" 专指"能力在位、文件真的没符号",不得被能力缺失借用。
    try std.testing.expect(std.mem.indexOf(u8, r, "(no symbols)") == null);
    try expectNamesAConcreteReason(r);
}

test "L2 issue #17: Read(outline) 回退正常读取时必须交代原因,不静默降级" {
    const a = std.testing.allocator;
    var sb = try Sandbox.init(a, "cc-capgap-rd", "probe.zig", "pub fn probe() void {}\n");
    defer sb.deinit();
    const ctx = sb.ctx();

    var abuf: [640]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"file_path\":\"{s}\",\"outline\":true}}", .{sb.file});
    const r = try dispatchOk(&ctx, "Read", args);
    defer a.free(r);

    try std.testing.expect(std.mem.indexOf(u8, r, "pub fn probe") != null); // 内容照给
    try std.testing.expect(std.mem.indexOf(u8, r, "Outline was requested but is unavailable") != null);
    try expectNamesAConcreteReason(r);
}

test "L2 issue #17: Read(outline) 对无注册 server 的文件类型给确定原因(不依赖装了什么)" {
    const a = std.testing.allocator;
    var sb = try Sandbox.init(a, "cc-capgap-md", "notes.md", "# Heading\n\ntext\n");
    defer sb.deinit();
    const ctx = sb.ctx();

    var abuf: [640]u8 = undefined;
    const args = try std.fmt.bufPrint(&abuf, "{{\"file_path\":\"{s}\",\"outline\":true}}", .{sb.file});
    const r = try dispatchOk(&ctx, "Read", args);
    defer a.free(r);

    try std.testing.expect(std.mem.indexOf(u8, r, "Heading") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "no language server is registered for this file type") != null);
}

// ============================================================================
// 谓词一致性 —— issue 里 REPRO_CAPGAP 探针的断言化
// ============================================================================

test "L2 issue #17: 决策谓词恒等于安装谓词(注册表不再单独说了算)" {
    const servers = cc.lsp.servers;
    const cases = [_][]const u8{ "/p/a.py", "/p/a.ts", "/p/a.go", "/p/a.zig", "/p/a.rs", "/p/a.c" };
    for (cases) |f| {
        const def = servers.findServerForFile(f) orelse return error.MissingRegistryEntry;
        const decided = switch (symbol_provider.capabilityForDef(def)) {
            .available => true,
            .unavailable => false,
        };
        try std.testing.expectEqual(servers.binaryAvailable(def), decided);
    }
}

test "L2 issue #17: 缺失说明点名二进制(用户知道下一步装什么)" {
    var buf: [capability.WHY_BUF]u8 = undefined;
    const u = capability.Unavailable{ .reason = .server_not_installed, .detail = "pyright-langserver" };
    try std.testing.expect(std.mem.indexOf(u8, u.why(&buf), "pyright-langserver") != null);
}

// ============================================================================
// follow-on:LSP 默认开 + --no-lsp 逃生口
// ============================================================================
//
// 为什么翻默认:`1515b34` 砍 tree-sitter 后,CodeMap / FindSymbol / Read-outline / Edit 写后
// 诊断四项能力只剩 LSP 一个来源,opt-in 等于默认降级。真正的启用门(注册 server + 二进制已装
// + git workspace + root marker + 惰性 spawn)本来就都在,`--lsp` 只是多余的第二重门。

const EnvGuard = struct {
    allocator: std.mem.Allocator,
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(allocator: std.mem.Allocator, name: [*:0]const u8, value: [*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try allocator.dupeZ(u8, std.mem.span(raw)) else null;
        ppaths.setEnv(name, value);
        return .{ .allocator = allocator, .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            self.allocator.free(previous);
        } else {
            ppaths.unsetEnv(self.name);
        }
        self.* = undefined;
    }
};

test "L2 follow-on: LSP 默认开,--no-lsp 关,--lsp 覆盖(最后一个赢)" {
    const a = std.testing.allocator;

    const Case = struct { argv: []const [*:0]const u8, want: bool, why: []const u8 };
    const cases = [_]Case{
        .{ .argv = &.{"metacodes"}, .want = true, .why = "裸启动 = 开(本次 follow-on 的核心翻转)" },
        .{ .argv = &.{ "metacodes", "--lsp" }, .want = true, .why = "显式开(向后兼容旧命令行)" },
        .{ .argv = &.{ "metacodes", "--no-lsp" }, .want = false, .why = "逃生口" },
        .{ .argv = &.{ "metacodes", "--no-lsp", "--lsp" }, .want = true, .why = "后写覆盖先写" },
        .{ .argv = &.{ "metacodes", "--lsp", "--no-lsp" }, .want = false, .why = "后写覆盖先写(反向)" },
    };
    // arena:parseArgs 对值型 flag 会 dupe 字符串。这些用例目前只有布尔 flag,但用 arena
    // 收口,免得后来加一条带值的用例就静默漏内存。
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for (cases) |c| {
        const config = cc.parseArgsForTest(c.argv, arena.allocator());
        try std.testing.expect(config.parse_error == null); // --no-lsp 必须是已知 flag
        if (config.lsp_enabled != c.want) {
            std.debug.print("lsp_enabled={} want={} ({s})\n", .{ config.lsp_enabled, c.want, c.why });
            return error.WrongLspDefault;
        }
    }
}

/// 真 App fixture(对齐 plugin_runtime_test / session_api_parity_test 惯例):tmp HOME + NO_PROBE。
/// **in-place** 初始化:arena.allocator()/io_rt.io() 捕获 &self 的字段地址,按值返回会悬垂。
const AppFixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    home_guard: EnvGuard,
    probe_guard: EnvGuard,
    app: *cc.app_module.App,

    fn setup(self: *AppFixture, argv: []const [*:0]const u8) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try self.tmp.dir.realPath(std.testing.io, &root_buffer);
        const root = root_buffer[0..len];

        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer self.arena.deinit();
        const allocator = self.arena.allocator();

        const home_z = try allocator.dupeZ(u8, root);
        self.home_guard = try EnvGuard.set(std.testing.allocator, "HOME", home_z.ptr);
        errdefer self.home_guard.restore();
        self.probe_guard = try EnvGuard.set(std.testing.allocator, "METACODES_NO_PROBE", "1");
        errdefer self.probe_guard.restore();

        const config = cc.parseArgsForTest(argv, allocator);
        try std.testing.expect(config.parse_error == null);

        self.io_rt = std.Io.Threaded.init(allocator, .{});
        errdefer self.io_rt.deinit();
        self.app = try cc.app_module.App.init(allocator, self.io_rt.io(), config, "test-key");
    }

    fn deinit(self: *AppFixture) void {
        self.app.deinit();
        self.io_rt.deinit();
        self.probe_guard.restore();
        self.home_guard.restore();
        self.arena.deinit();
        self.tmp.cleanup();
    }
};

test "L2 follow-on: 声明=接线 —— 默认装配 LSP Service,--no-lsp 真的不装配" {
    // 只验"Service 在不在",不验"language server 起没起"——后者由运行期的注册/安装/workspace
    // 门决定,与本 flag 无关(也正因为那些门都在,默认开在没装 server 的机器上是零成本)。
    {
        var fx: AppFixture = undefined;
        try fx.setup(&.{ "metacodes", "--permission", "bypassPermissions" });
        defer fx.deinit();
        try std.testing.expect(fx.app.lsp_service != null);
    }
    {
        var fx: AppFixture = undefined;
        try fx.setup(&.{ "metacodes", "--permission", "bypassPermissions", "--no-lsp" });
        defer fx.deinit();
        try std.testing.expect(fx.app.lsp_service == null);
    }
}
