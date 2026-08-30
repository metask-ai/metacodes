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

const std = @import("std");
const cc = @import("cc");
const pfs = @import("platform").fs;
const pprocess = @import("platform").process;

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
        const dir = try std.fmt.allocPrint(a, "/tmp/{s}-{d}", .{ tag, pprocess.currentPid() });
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
        c.lsp = self.svc; // --lsp **开着**:老代码的唯一限定分支在这里就被跳过了
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

test "L2 issue #17: FindSymbol 在 --lsp 开、符号能力缺失时不返裸 []" {
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

test "L2 issue #17: FindSymbol 无 --lsp → 同一套限定语(措辞不因分支而漂移)" {
    const a = std.testing.allocator;
    const ctx = ToolContext.simple(a); // 没开 --lsp
    const r = try dispatchOk(&ctx, "FindSymbol", "{\"name\":\"CapGapProbeSymbol\"}");
    defer a.free(r);
    try std.testing.expect(!std.mem.eql(u8, r, "[]"));
    try std.testing.expect(std.mem.indexOf(u8, r, "does NOT mean") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "--lsp") != null);
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
