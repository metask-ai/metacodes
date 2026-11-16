//! Write isolation for a metacodes seat (#519), by mechanism: a seat may
//! write inside its workspace and its own seat directory, nowhere else; a
//! seat whose role does not change code (every role but the implementer)
//! may write its seat directory only.
//!
//! Three layers, each sufficient for the case it covers:
//!
//! 1. `Scope.executionPolicy()` is the seat's `ToolExecutionPolicy`, the final
//!    layer agent_loop and tool_exec consult before a tool runs, independent
//!    of the permission mode and of every allow rule. It offers only the
//!    role's tools (`toolsFor`); a Write/Edit target must lie in a write
//!    root *physically* (symlinks resolved, also through a not-yet-existing
//!    tail, and a dangling link is refused); a Bash command must be
//!    read-only or run inside the seat sandbox.
//! 2. The seat's permission context (metacodes.zig) runs in `acceptEdits`
//!    with exactly those two roots as its working directories and no prompt
//!    channel, so anything that would ask is refused.
//! 3. `seatSandbox` confines Bash: writes allowed only under the workspace,
//!    the seat directory and the platform temp roots (Seatbelt profile on
//!    macOS, bubblewrap mounts on Linux), so an implementer seat can build
//!    and run tests. On a host without a working backend (Windows; Linux
//!    without a bwrap that can create user namespaces) only read-only Bash
//!    commands run. The sandbox always lets Bash write the workspace
//!    (build caches), so for a non-implementer seat Bash is not a fence
//!    against workspace edits; the reviewer's tree check is (reviewer.zig).

const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const file_target = @import("../../tools/file_target.zig");
const tool_context = @import("../../tools/context.zig");
const bash_readonly = @import("../../permission/bash_readonly.zig");
const sandbox_config = @import("../../sandbox/config.zig");
const sandbox_exec = @import("../../sandbox/exec.zig");
const types = @import("../types.zig");
const reviewer = @import("../reviewer.zig");

const PathBuf = [std.fs.max_path_bytes]u8;

/// The implementer's tools.
pub const implementer_tools = [_][]const u8{ "Read", "Grep", "Glob", "Write", "Edit", "Bash" };
/// The reviewer's: `reviewer.tools` (read-only plus Bash for tests) and
/// Write, confined to the seat directory, for `handoff.md` and `review.json`.
pub const reviewer_tools = reviewer.tools ++ [_][]const u8{"Write"};
/// Every other role's: read, run read-only or sandboxed commands, and write
/// its own seat files.
pub const planner_tools = [_][]const u8{ "Read", "Grep", "Glob", "Bash", "Write" };

/// The tools a metacodes seat of `role` is offered. Anything else (Agent,
/// MCP, Skills, web, KG writes, ApplyPatch, NotebookEdit) is neither
/// advertised nor executable.
pub fn toolsFor(role: types.Role) []const []const u8 {
    return switch (role) {
        .implementer => &implementer_tools,
        .reviewer => &reviewer_tools,
        .interviewer, .manager, .verifier => &planner_tools,
    };
}

/// Only the implementer changes the workspace.
pub fn writesWorkspace(role: types.Role) bool {
    return role == .implementer;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |tool| if (std.mem.eql(u8, tool, name)) return true;
    return false;
}

/// The seat's Bash sandbox: on whenever the host has a backend, never
/// bypassed, and no extra write roots. The host's read restrictions and
/// network lists carry over; its `allow_write` and `excluded_commands` do
/// not (either would let a seat write outside its two roots). Without a
/// backend it is off, so read-only commands still run, and the execution
/// policy refuses every other command (`Scope.allows`).
pub fn seatSandbox(host: ?*const sandbox_config.SandboxSettings) sandbox_config.SandboxSettings {
    var settings: sandbox_config.SandboxSettings = .{};
    if (host) |h| {
        settings.allow_read = h.allow_read;
        settings.deny_read = h.deny_read;
        settings.deny_write = h.deny_write;
        settings.allowed_domains = h.allowed_domains;
        settings.denied_domains = h.denied_domains;
    }
    settings.enabled = sandbox_exec.hostSupported();
    settings.fail_if_unavailable = true;
    settings.allow_unsandboxed_commands = false;
    settings.auto_allow_bash_if_sandboxed = true;
    settings.allow_write = &.{};
    settings.excluded_commands = &.{};
    settings.allocator = null; // borrowed slices: never freed through this copy
    return settings;
}

pub const InitError = error{ PathTooLong, RootMissing };

pub const Scope = struct {
    /// Physical (symlink-resolved) roots.
    workspace_buf: PathBuf = undefined,
    workspace_len: usize = 0,
    seat_dir_buf: PathBuf = undefined,
    seat_dir_len: usize = 0,
    /// For `~/` in a Write/Edit path, as the tools expand it.
    home: []const u8,
    /// The workspace as the tools see it (relative paths resolve against it).
    workspace_logical: []const u8,
    sandbox: *const sandbox_config.SandboxSettings,
    tools: []const []const u8,
    /// Write/Edit may target the workspace (the implementer), not only the
    /// seat directory.
    workspace_writable: bool,

    /// Both roots must exist. `home` and `workspace` are borrowed for the
    /// scope's life, as is `sandbox`.
    pub fn init(
        self: *Scope,
        role: types.Role,
        workspace_dir: []const u8,
        seat_dir: []const u8,
        home: []const u8,
        sandbox: *const sandbox_config.SandboxSettings,
    ) InitError!void {
        self.* = .{
            .home = home,
            .workspace_logical = workspace_dir,
            .sandbox = sandbox,
            .tools = toolsFor(role),
            .workspace_writable = writesWorkspace(role),
        };
        self.workspace_len = (try physicalRoot(&self.workspace_buf, workspace_dir)).len;
        self.seat_dir_len = (try physicalRoot(&self.seat_dir_buf, seat_dir)).len;
    }

    pub fn workspace(self: *const Scope) []const u8 {
        return self.workspace_buf[0..self.workspace_len];
    }

    pub fn seatDir(self: *const Scope) []const u8 {
        return self.seat_dir_buf[0..self.seat_dir_len];
    }

    pub fn executionPolicy(self: *const Scope) tool_context.ToolExecutionPolicy {
        return .{
            .ctx = @ptrCast(self),
            .allowsToolFn = allowsToolAdapter,
            .allowsInvocationFn = allowsInvocationAdapter,
        };
    }

    /// Whether the seat may run tool `name` with `arguments_json`.
    pub fn allows(self: *const Scope, name: []const u8, arguments_json: []const u8) bool {
        if (!contains(self.tools, name)) return false;
        if (file_target.Tool.fromName(name)) |tool| return self.allowsFileWrite(tool, arguments_json);
        if (std.mem.eql(u8, name, "Bash")) return self.allowsBash(arguments_json);
        return true; // Read, Grep, Glob
    }

    /// The physical path a Write/Edit call targets, as the tool resolves it,
    /// must lie in a write root.
    pub fn allowsFileWrite(self: *const Scope, tool: file_target.Tool, arguments_json: []const u8) bool {
        var scratch_buf: [2 * std.fs.max_path_bytes + 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&scratch_buf);
        const target = (file_target.resolve(fba.allocator(), tool, arguments_json, .{
            .home = self.home,
            .base_dir = self.workspace_logical,
            .resolve_relative = true,
        }) catch return false) orelse return false;
        return self.containsPhysical(target);
    }

    /// Whether `path` (absolute, normalized) is physically inside a write root.
    pub fn containsPhysical(self: *const Scope, path: []const u8) bool {
        var buf: PathBuf = undefined;
        const physical = physicalTarget(&buf, path) orelse return false;
        if (within(self.seatDir(), physical)) return true;
        return self.workspace_writable and within(self.workspace(), physical);
    }

    fn allowsBash(self: *const Scope, arguments_json: []const u8) bool {
        var scratch_buf: [bash_readonly.MAX_COMMAND_BYTES + 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&scratch_buf);
        const command = bash_readonly.commandFromInput(fba.allocator(), arguments_json) orelse return false;
        if (bash_readonly.isReadonly(bash_readonly.hostDialect(), command)) return true;
        return sandbox_exec.plan(self.sandbox, command, sandbox_exec.escapeHatchHonored(self.sandbox, arguments_json)) == .sandboxed;
    }

    fn allowsToolAdapter(raw: *const anyopaque, name: []const u8) bool {
        const self: *const Scope = @ptrCast(@alignCast(raw));
        return contains(self.tools, name);
    }

    fn allowsInvocationAdapter(raw: *const anyopaque, name: []const u8, arguments_json: []const u8) bool {
        const self: *const Scope = @ptrCast(@alignCast(raw));
        return self.allows(name, arguments_json);
    }
};

fn physicalRoot(out: *PathBuf, path: []const u8) InitError![]const u8 {
    var zbuf: PathBuf = undefined;
    if (path.len >= zbuf.len) return error.PathTooLong;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const resolved = pfs.finalPath(@ptrCast(&zbuf), out) orelse return error.RootMissing;
    return std.mem.span(resolved);
}

/// The physical form of an absolute, lexically normalized `path` that may
/// not exist yet: its deepest existing ancestor resolved, the rest appended.
/// Null when a missing component is a symlink (a dangling link would let a
/// create land wherever it points) or the path is too long.
fn physicalTarget(out: *PathBuf, path: []const u8) ?[]const u8 {
    var end = path.len;
    while (true) {
        var zbuf: PathBuf = undefined;
        if (end >= zbuf.len) return null;
        @memcpy(zbuf[0..end], path[0..end]);
        zbuf[end] = 0;
        var rbuf: PathBuf = undefined;
        if (pfs.finalPath(@ptrCast(&zbuf), &rbuf)) |resolved| {
            const base = std.mem.span(resolved);
            const rest = path[end..];
            const joiner: []const u8 = if (rest.len > 0 and !isSep(rest[0]) and !(base.len > 0 and isSep(base[base.len - 1]))) "/" else "";
            if (base.len + joiner.len + rest.len >= out.len) return null;
            @memcpy(out[0..base.len], base);
            @memcpy(out[base.len..][0..joiner.len], joiner);
            @memcpy(out[base.len + joiner.len ..][0..rest.len], rest);
            return out[0 .. base.len + joiner.len + rest.len];
        }
        if (pfs.isSymlink(@ptrCast(&zbuf))) return null;
        if (end <= 1) return null;
        const slash = lastSep(path[0..end]) orelse return null;
        end = if (slash == 0) 1 else slash;
    }
}

fn isSep(c: u8) bool {
    return c == '/' or (builtin.os.tag == .windows and c == '\\');
}

fn lastSep(text: []const u8) ?usize {
    var i = text.len;
    while (i > 0) {
        i -= 1;
        if (isSep(text[i])) return i;
    }
    return null;
}

/// `path` is `root` or below it, on a separator boundary.
fn within(root: []const u8, path: []const u8) bool {
    if (root.len == 0 or !std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    if (isSep(root[root.len - 1])) return true;
    return isSep(path[root.len]);
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const util_fs = @import("../../util/fs.zig");

const Fixture = struct {
    root_buf: PathBuf = undefined,
    root_len: usize = 0,
    ws_logical: PathBuf = undefined,
    ws_logical_len: usize = 0,
    join_buf: PathBuf = undefined,
    sandbox: sandbox_config.SandboxSettings = undefined,
    scope: Scope = undefined,
    role: types.Role = .implementer,

    fn init(self: *Fixture, tag: []const u8) !void {
        self.root_len = util_fs.testing.uniqueDir(&self.root_buf, tag).len;
        try util_fs.mkdirParents(self.join("ws"));
        try util_fs.mkdirParents(self.join("run/seats/implementer-1"));
        try util_fs.mkdirParents(self.join("outside"));
        self.sandbox = seatSandbox(null);
        const ws = try std.fmt.bufPrint(&self.ws_logical, "{s}/ws", .{self.root()});
        self.ws_logical_len = ws.len;
        var seat_buf: PathBuf = undefined;
        const seat = try std.fmt.bufPrint(&seat_buf, "{s}/run/seats/implementer-1", .{self.root()});
        try self.scope.init(self.role, self.ws_logical[0..self.ws_logical_len], seat, "/nonexistent-home", &self.sandbox);
    }

    fn root(self: *const Fixture) []const u8 {
        return self.root_buf[0..self.root_len];
    }

    fn join(self: *Fixture, rel: []const u8) []const u8 {
        return std.fmt.bufPrint(&self.join_buf, "{s}/{s}", .{ self.root(), rel }) catch unreachable;
    }

    fn deinit(self: *Fixture) void {
        util_fs.testing.rmrfBestEffort(self.root());
    }

    fn writeArgs(self: *Fixture, buf: []u8, rel_or_abs: []const u8, absolute: bool) []const u8 {
        if (absolute) {
            return std.fmt.bufPrint(buf, "{{\"file_path\":\"{s}/{s}\",\"content\":\"x\"}}", .{ self.root(), rel_or_abs }) catch unreachable;
        }
        return std.fmt.bufPrint(buf, "{{\"file_path\":\"{s}\",\"content\":\"x\"}}", .{rel_or_abs}) catch unreachable;
    }
};

test "write scope: Write/Edit only inside the workspace or the seat directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = .{};
    try fx.init("cc-zig-teamwork-scope-write");
    defer fx.deinit();
    var buf: [8192]u8 = undefined;

    try testing.expect(fx.scope.allows("Write", fx.writeArgs(&buf, "ws/src/new.zig", true)));
    try testing.expect(fx.scope.allows("Write", fx.writeArgs(&buf, "src/relative.zig", false)));
    try testing.expect(fx.scope.allows("Write", fx.writeArgs(&buf, "run/seats/implementer-1/handoff.md", true)));
    try testing.expect(fx.scope.allows("Edit", "{\"file_path\":\"notes.md\",\"old_string\":\"a\",\"new_string\":\"b\"}"));

    try testing.expect(!fx.scope.allows("Write", fx.writeArgs(&buf, "outside/x", true)));
    try testing.expect(!fx.scope.allows("Write", fx.writeArgs(&buf, "run/ORIGINAL_REQUEST.md", true)));
    try testing.expect(!fx.scope.allows("Write", fx.writeArgs(&buf, "run/seats/reviewer-1/handoff.md", true)));
    try testing.expect(!fx.scope.allows("Write", fx.writeArgs(&buf, "../outside/escape", false)));
    try testing.expect(!fx.scope.allows("Write", fx.writeArgs(&buf, "ws/../outside/escape", true)));
    try testing.expect(!fx.scope.allows("Write", "{\"file_path\":\"~/x\",\"content\":\"x\"}"));
    try testing.expect(!fx.scope.allows("Write", "{\"content\":\"no path\"}"));
}

test "write scope: a symlink out of the workspace does not widen it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = .{};
    try fx.init("cc-zig-teamwork-scope-link");
    defer fx.deinit();
    var target_buf: PathBuf = undefined;
    const target = try std.fmt.bufPrintZ(&target_buf, "{s}/outside", .{fx.root()});
    var link_buf: PathBuf = undefined;
    const link = try std.fmt.bufPrintZ(&link_buf, "{s}/ws/escape", .{fx.root()});
    var dangling_buf: PathBuf = undefined;
    const dangling = try std.fmt.bufPrintZ(&dangling_buf, "{s}/ws/dangling", .{fx.root()});
    var dangling_target_buf: PathBuf = undefined;
    const dangling_target = try std.fmt.bufPrintZ(&dangling_target_buf, "{s}/outside/not-yet", .{fx.root()});
    if (std.c.symlink(target.ptr, link.ptr) != 0) return error.SkipZigTest;
    if (std.c.symlink(dangling_target.ptr, dangling.ptr) != 0) return error.SkipZigTest;

    var buf: [8192]u8 = undefined;
    try testing.expect(!fx.scope.allows("Write", fx.writeArgs(&buf, "escape/new-file", false)));
    try testing.expect(!fx.scope.allows("Write", fx.writeArgs(&buf, "escape/deeper/new-file", false)));
    try testing.expect(!fx.scope.allows("Write", fx.writeArgs(&buf, "dangling", false)));
}

test "write scope: only seat tools; Bash read-only or sandboxed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = .{};
    try fx.init("cc-zig-teamwork-scope-tools");
    defer fx.deinit();
    const policy = fx.scope.executionPolicy();

    for ([_][]const u8{ "Agent", "ApplyPatch", "NotebookEdit", "KgRemember", "WebFetch", "mcp__x__y" }) |name| {
        try testing.expect(!policy.allowsTool(name));
        try testing.expect(!policy.allowsInvocation(name, "{}"));
    }
    try testing.expect(policy.allowsInvocation("Read", "{\"file_path\":\"/etc/hosts\"}"));
    try testing.expect(policy.allowsInvocation("Bash", "{\"command\":\"ls -la\"}"));
    const writes_outside = "{\"command\":\"echo x > /tmp/escape\"}";
    try testing.expectEqual(sandbox_exec.hostSupported(), policy.allowsInvocation("Bash", writes_outside));
    // The escape hatch never applies to a seat.
    try testing.expectEqual(
        sandbox_exec.hostSupported(),
        policy.allowsInvocation("Bash", "{\"command\":\"touch x\",\"dangerouslyDisableSandbox\":true}"),
    );
}

test "write scope: seat sandbox drops host write widenings and escape hatches" {
    const extra_write = [_][]const u8{"/anywhere"};
    const excluded = [_][]const u8{"git"};
    const deny_read = [_][]const u8{"~/.ssh"};
    const host: sandbox_config.SandboxSettings = .{
        .enabled = false,
        .allow_write = &extra_write,
        .excluded_commands = &excluded,
        .deny_read = &deny_read,
    };
    const seat = seatSandbox(&host);
    try testing.expectEqual(sandbox_exec.hostSupported(), seat.enabled);
    try testing.expect(seat.fail_if_unavailable and !seat.allow_unsandboxed_commands);
    try testing.expectEqual(@as(usize, 0), seat.allow_write.len);
    try testing.expectEqual(@as(usize, 0), seat.excluded_commands.len);
    try testing.expectEqual(@as(usize, 1), seat.deny_read.len);
    const want: sandbox_exec.Plan = if (sandbox_exec.hostSupported()) .sandboxed else .passthrough;
    try testing.expectEqual(want, sandbox_exec.plan(&seat, "git commit -m x", false));
}

test "write scope: a non-implementer seat writes only its seat directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    for ([_]types.Role{ .reviewer, .interviewer, .manager, .verifier }) |role| {
        var fx: Fixture = .{ .role = role };
        try fx.init("cc-zig-teamwork-scope-role");
        defer fx.deinit();
        var buf: [8192]u8 = undefined;
        try testing.expect(fx.scope.allows("Write", fx.writeArgs(&buf, "run/seats/implementer-1/handoff.md", true)));
        try testing.expect(!fx.scope.allows("Write", fx.writeArgs(&buf, "src/relative.zig", false)));
        try testing.expect(!fx.scope.allows("Write", fx.writeArgs(&buf, "ws/new.zig", true)));
        try testing.expect(!fx.scope.allows("Edit", "{\"file_path\":\"notes.md\",\"old_string\":\"a\",\"new_string\":\"b\"}"));
        try testing.expect(fx.scope.allows("Bash", "{\"command\":\"ls\"}"));
    }
}

test "write scope: the reviewer's tools are reviewer.tools plus Write" {
    try testing.expectEqual(reviewer.tools.len + 1, toolsFor(.reviewer).len);
    for (reviewer.tools) |tool| try testing.expect(contains(toolsFor(.reviewer), tool));
    try testing.expect(contains(toolsFor(.reviewer), "Write"));
    try testing.expect(!contains(toolsFor(.reviewer), "Edit"));
    try testing.expect(contains(toolsFor(.implementer), "Edit"));
}
