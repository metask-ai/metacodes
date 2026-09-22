//! L2 组件测试:**会话根目录跟着改名走**(App.refreshWorkspaceRoot)。
//!
//! 事故 2026-09-22:agent 把自己的 cwd 改名,App 里启动时拍的 cwd_abs 字符串失效,之后每次
//! Bash 都在子进程 chdir 失败(exit 127、双空流),模型空转到 400 轮上限。子进程报告通道
//! (#1)让失败会说话;本测试锁定的是 #2:根目录字符串有了唯一 owner——每轮 run 装配前
//! 校验,改名了就整体切换,并且每个捕获过旧字符串的消费者都跟着换:
//!
//!   cwd_abs → buildRunOptions().cwd_abs → ToolContext.cwd_abs(Bash chdir / 文件工具 base_dir)
//!   permission_ctx.match_ctx.cwd(accept_edits 的工作目录集)
//!   system_prompt 的环境段(模型看到的 Primary working directory)
//!
//! 跨模块:app + session_service + permission + system_prompt(≥3,合 L2)。
//! 真 App fixture(对齐 session_api_parity_test 惯例):tmp HOME + NO_PROBE,arena 生命周期。
//!
//! 改名本身用"字符串指向一个刚删掉的目录"模拟:在 App 眼里,"记录的路径不存在而进程 cwd
//! 解析成另一个路径"就是改名——真正 rename 进程 cwd 需要 chdir,而 chdir 是进程全局的,
//! 会污染同一测试进程里的其它用例。

const std = @import("std");
const cc = @import("cc");
const ppaths = @import("platform").paths;

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

const AppFixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    home_guard: EnvGuard,
    probe_guard: EnvGuard,
    app: *cc.app_module.App,
    /// tmp 根的真实路径(owned by arena),供造"曾经存在、现在没了"的目录。
    root: []const u8,

    /// **in-place** 初始化(self 必须是 caller 栈上的最终地址):arena.allocator()/io_rt.io()
    /// 捕获 &self.arena/&self.io_rt——按值返回会悬垂。
    fn setup(self: *AppFixture) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try self.tmp.dir.realPath(std.testing.io, &root_buffer);

        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer self.arena.deinit();
        const allocator = self.arena.allocator();
        self.root = try allocator.dupe(u8, root_buffer[0..len]);

        const home_z = try allocator.dupeZ(u8, self.root);
        self.home_guard = try EnvGuard.set(std.testing.allocator, "HOME", home_z.ptr);
        errdefer self.home_guard.restore();
        self.probe_guard = try EnvGuard.set(std.testing.allocator, "METACODES_NO_PROBE", "1");
        errdefer self.probe_guard.restore();

        const argv = [_][*:0]const u8{ "metacodes", "--permission", "bypassPermissions" };
        const config = cc.parseArgsForTest(&argv, allocator);
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

/// 一个真实存在过、然后消失了的目录:`<tmp root>/<name>`(NUL 结尾,写进 buf)。
fn vanishedDir(root: []const u8, buf: []u8, name: []const u8) ![:0]const u8 {
    const path = try std.fmt.bufPrintZ(buf, "{s}/{s}", .{ root, name });
    _ = std.c.mkdir(path.ptr, 0o700);
    if (std.c.rmdir(path.ptr) != 0) return error.TestScratchDirNotRemovable;
    return path;
}

/// 把 App 的会话根"倒回"到启动时拍的那个字符串(测试替 init 拍这一下):cwd_abs、权限
/// match_ctx、以及系统提示词的环境段——init 写进去的正是这个根。不种进 prompt 的话,
/// "prompt 含新路径"的断言在 init 时就已成立,删掉重建逻辑测试照样绿。
fn plantRoot(app: *cc.app_module.App, path: []const u8) !void {
    const owned = try app.allocator.dupe(u8, path);
    if (app.cwd_abs) |old| app.allocator.free(old);
    app.cwd_abs = owned;
    app.permission_ctx.match_ctx.cwd = owned;
    const planted_prompt = try std.fmt.allocPrint(app.allocator, "# Environment\n - Primary working directory: {s}\n", .{path});
    if (app.system_prompt) |old| app.allocator.free(old);
    app.system_prompt = planted_prompt;
}

test "workspace root: 记录的目录不存在而进程 cwd 解析成新名字 → 整体切换,消费者跟着换" {
    var fx: AppFixture = undefined;
    try fx.setup();
    defer fx.deinit();
    const app = fx.app;
    const a = std.testing.allocator;

    var gone_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const gone = try vanishedDir(fx.root, &gone_buf, "renamed-away");
    try plantRoot(app, gone);

    const outcome = app.refreshWorkspaceRoot();
    try std.testing.expect(outcome == .renamed);

    // 新根 = 进程 cwd(内核句柄的现名)。
    const process_cwd = try cc.util_fs.getCwd(a);
    defer a.free(process_cwd);
    try std.testing.expectEqualStrings(process_cwd, outcome.renamed);
    try std.testing.expectEqualStrings(process_cwd, app.cwdAbs());

    // 每个捕获过旧字符串的消费者都换了:权限工作目录集、系统提示词、run 装配。
    try std.testing.expectEqualStrings(process_cwd, app.permission_ctx.match_ctx.cwd);
    const prompt = app.system_prompt orelse return error.TestExpectedSystemPrompt;
    try std.testing.expect(std.mem.indexOf(u8, prompt, process_cwd) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, gone) == null);
    const opts = cc.session_service.buildRunOptions(app, null);
    try std.testing.expectEqualStrings(process_cwd, opts.cwd_abs);

    // 切换过后目录存在,再校验就是 no-op(REPL 与 buildRunOptions 各调一次不会重复告知)。
    try std.testing.expect(app.refreshWorkspaceRoot() == .unchanged);
}

test "workspace root: 目录还在 → 不动任何东西(字符串指针、system prompt 都不变)" {
    var fx: AppFixture = undefined;
    try fx.setup();
    defer fx.deinit();
    const app = fx.app;

    const before_ptr = app.cwdAbs().ptr;
    const prompt_before = app.system_prompt;
    try std.testing.expect(app.refreshWorkspaceRoot() == .unchanged);
    try std.testing.expect(app.cwdAbs().ptr == before_ptr);
    try std.testing.expect(app.system_prompt.?.ptr == prompt_before.?.ptr);
}
