//! AgentCore-owned lifetime kernel for immutable Skill catalog snapshots.
//!
//! Host handles and Session bindings are distinct references to one immutable
//! cell. Runtime destruction is fail-fast (`BUSY`) while any facade call or
//! catalog reference exists; no lower-layer lifetime is involved.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("platform").sync;
const rng = @import("platform").rng;
const core = @import("metacodes-core");
const catalog = core.skills_runtime.catalog;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const MAX_LIVE_SNAPSHOT_BYTES: usize = 256 * 1024 * 1024;
pub const BUNDLE_IDENTITY = "metask-agentcore/abi-v1/revision-5";
const SCOPE_DOMAIN = "metask.agentcore.skill-catalog.scope/v1";

pub const Error = error{
    OutOfMemory,
    RandomUnavailable,
    RuntimeUnavailable,
    RuntimeBusy,
    InvalidWorkspace,
    WrongRuntime,
    WrongWorkspace,
    ResourceLimit,
};

pub const CanonicalWorkspace = struct {
    allocator: std.mem.Allocator,
    root: []u8,
    home: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        root: []const u8,
        home: []const u8,
    ) Error!CanonicalWorkspace {
        var root_policy = core.workspace_policy.WorkspacePolicy.init(allocator, .{
            .root = root,
            .home = root,
        }) catch |err| return mapWorkspaceError(err);
        defer root_policy.deinit();

        const canonical_root = allocator.dupe(u8, root_policy.root) catch
            return error.OutOfMemory;
        errdefer allocator.free(canonical_root);
        const home_source = if (home.len == 0) root else home;
        var home_policy = core.workspace_policy.WorkspacePolicy.init(allocator, .{
            .root = home_source,
            .home = home_source,
        }) catch |err| return mapWorkspaceError(err);
        defer home_policy.deinit();
        const canonical_home = allocator.dupe(u8, home_policy.root) catch
            return error.OutOfMemory;
        return .{
            .allocator = allocator,
            .root = canonical_root,
            .home = canonical_home,
        };
    }

    pub fn deinit(self: *CanonicalWorkspace) void {
        self.allocator.free(self.home);
        self.allocator.free(self.root);
        self.* = undefined;
    }
};

fn mapWorkspaceError(err: anyerror) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidWorkspace;
}

pub const RuntimeCatalogs = struct {
    const State = enum { live, destroying, destroyed };

    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    state: State = .live,
    active_calls: usize = 0,
    reference_count: usize = 0,
    live_snapshot_bytes: usize = 0,
    max_live_snapshot_bytes: usize = MAX_LIVE_SNAPSHOT_BYTES,
    secret: [32]u8,

    pub fn init(allocator: std.mem.Allocator) Error!RuntimeCatalogs {
        var secret: [32]u8 = undefined;
        if (!rng.randomBytes(&secret)) {
            @memset(&secret, 0);
            return error.RandomUnavailable;
        }
        return initSecret(allocator, secret);
    }

    pub fn initWithSecret(
        allocator: std.mem.Allocator,
        secret: [32]u8,
    ) RuntimeCatalogs {
        if (comptime !builtin.is_test)
            @compileError("deterministic Runtime secrets are test-only");
        return initSecret(allocator, secret);
    }

    fn initSecret(
        allocator: std.mem.Allocator,
        secret: [32]u8,
    ) RuntimeCatalogs {
        return .{
            .allocator = allocator,
            .secret = secret,
        };
    }

    pub fn enterCall(self: *RuntimeCatalogs) Error!CallGuard {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .live) return error.RuntimeUnavailable;
        self.active_calls = std.math.add(usize, self.active_calls, 1) catch
            return error.ResourceLimit;
        return .{ .runtime = self };
    }

    pub fn tryBeginDestroy(self: *RuntimeCatalogs) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .live) return error.RuntimeUnavailable;
        if (self.active_calls != 0 or self.reference_count != 0)
            return error.RuntimeBusy;
        self.state = .destroying;
    }

    pub fn cancelDestroy(self: *RuntimeCatalogs) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.state == .destroying);
        self.state = .live;
    }

    /// Must be called immediately before the containing Runtime is freed.
    pub fn finishDestroy(self: *RuntimeCatalogs) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.state == .destroying);
        std.debug.assert(self.active_calls == 0);
        std.debug.assert(self.reference_count == 0);
        std.debug.assert(self.live_snapshot_bytes == 0);
        @memset(&self.secret, 0);
        self.state = .destroyed;
    }

    pub fn scopeId(
        self: *RuntimeCatalogs,
        workspace: *const CanonicalWorkspace,
    ) Error![64]u8 {
        var call = try self.enterCall();
        defer call.deinit();
        return self.scopeIdUnderGuard(workspace);
    }

    fn scopeIdUnderGuard(
        self: *RuntimeCatalogs,
        workspace: *const CanonicalWorkspace,
    ) [64]u8 {
        var hmac = HmacSha256.init(&self.secret);
        updateField(&hmac, SCOPE_DOMAIN);
        updateField(&hmac, BUNDLE_IDENTITY);
        updateField(&hmac, workspace.root);
        updateField(&hmac, workspace.home);
        var digest: [HmacSha256.mac_length]u8 = undefined;
        hmac.final(&digest);
        return std.fmt.bytesToHex(digest, .lower);
    }

    pub fn query(
        self: *RuntimeCatalogs,
        io: std.Io,
        workspace: *const CanonicalWorkspace,
        workspace_epoch: []const u8,
        sources: []const catalog.Source,
        limits: catalog.Limits,
    ) (Error || catalog.BuildError)!*HostCatalog {
        var call = try self.enterCall();
        defer call.deinit();
        return self.queryUnderGuard(
            io,
            workspace,
            workspace_epoch,
            sources,
            limits,
        );
    }

    fn queryUnderGuard(
        self: *RuntimeCatalogs,
        io: std.Io,
        workspace: *const CanonicalWorkspace,
        workspace_epoch: []const u8,
        sources: []const catalog.Source,
        limits: catalog.Limits,
    ) (Error || catalog.BuildError)!*HostCatalog {
        const scope_id = self.scopeIdUnderGuard(workspace);
        const snapshot = try catalog.build(
            self.allocator,
            io,
            &scope_id,
            workspace_epoch,
            sources,
            limits,
        );
        errdefer snapshot.deinit();

        const cell = self.allocator.create(CatalogCell) catch
            return error.OutOfMemory;
        errdefer self.allocator.destroy(cell);
        const host = self.allocator.create(HostCatalog) catch
            return error.OutOfMemory;
        errdefer self.allocator.destroy(host);

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .live) return error.RuntimeUnavailable;
        const cell_bytes = std.math.add(
            usize,
            snapshot.resident_bytes,
            @sizeOf(CatalogCell) + @sizeOf(HostCatalog),
        ) catch return error.ResourceLimit;
        const next_bytes = std.math.add(
            usize,
            self.live_snapshot_bytes,
            cell_bytes,
        ) catch return error.ResourceLimit;
        if (next_bytes > self.max_live_snapshot_bytes) return error.ResourceLimit;
        self.reference_count = std.math.add(usize, self.reference_count, 1) catch
            return error.ResourceLimit;
        self.live_snapshot_bytes = next_bytes;
        cell.* = .{
            .runtime = self,
            .snapshot = snapshot,
            .references = 1,
            .accounted_bytes = cell_bytes,
        };
        host.* = .{ .cell = cell };
        return host;
    }

    pub fn queryDefault(
        self: *RuntimeCatalogs,
        io: std.Io,
        workspace: *const CanonicalWorkspace,
        workspace_epoch: []const u8,
        limits: catalog.Limits,
    ) (Error || catalog.BuildError)!*HostCatalog {
        var call = try self.enterCall();
        defer call.deinit();
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const sources = try catalog.defaultSources(
            scratch.allocator(),
            workspace.root,
            workspace.home,
        );
        return self.queryUnderGuard(
            io,
            workspace,
            workspace_epoch,
            sources,
            limits,
        );
    }

    /// Retains the immutable cell for a Session create/update transaction.
    /// The Host handle itself remains independently releasable after success.
    pub fn retainForSession(
        self: *RuntimeCatalogs,
        host: *const HostCatalog,
        expected_scope_id: *const [64]u8,
    ) Error!*CatalogCell {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .live) return error.RuntimeUnavailable;
        const cell = host.cell;
        if (cell.runtime != self) return error.WrongRuntime;
        if (!std.mem.eql(u8, &cell.snapshot.scope_id, expected_scope_id))
            return error.WrongWorkspace;
        std.debug.assert(cell.references > 0);
        cell.references = std.math.add(usize, cell.references, 1) catch
            return error.ResourceLimit;
        self.reference_count = std.math.add(usize, self.reference_count, 1) catch {
            cell.references -= 1;
            return error.ResourceLimit;
        };
        return cell;
    }

    /// Releases a Session-owned reference. The caller must hold a Runtime
    /// active-call guard so final cell destruction cannot race Runtime free.
    pub fn releaseSession(self: *RuntimeCatalogs, cell: *CatalogCell) void {
        const final = self.releaseReference(cell);
        if (final) destroyCell(self, cell);
    }

    fn releaseReference(self: *RuntimeCatalogs, cell: *CatalogCell) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(cell.runtime == self);
        std.debug.assert(cell.references > 0);
        std.debug.assert(self.reference_count > 0);
        cell.references -= 1;
        self.reference_count -= 1;
        if (cell.references != 0) return false;
        std.debug.assert(self.live_snapshot_bytes >= cell.accounted_bytes);
        self.live_snapshot_bytes -= cell.accounted_bytes;
        return true;
    }

    fn leaveCall(self: *RuntimeCatalogs) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.active_calls > 0);
        self.active_calls -= 1;
    }
};

pub const CallGuard = struct {
    runtime: *RuntimeCatalogs,
    active: bool = true,

    pub fn deinit(self: *CallGuard) void {
        if (!self.active) return;
        self.runtime.leaveCall();
        self.active = false;
    }
};

pub const CatalogCell = struct {
    runtime: *RuntimeCatalogs,
    snapshot: *catalog.Snapshot,
    references: usize,
    accounted_bytes: usize,
};

pub const HostCatalog = struct {
    cell: *CatalogCell,

    pub fn snapshot(self: *const HostCatalog) *const catalog.Snapshot {
        return self.cell.snapshot;
    }

    /// Successful release invalidates this Host handle exactly once.
    pub fn release(self: *HostCatalog) Error!void {
        const runtime = self.cell.runtime;
        var call = try runtime.enterCall();
        defer call.deinit();
        const cell = self.cell;
        const final = runtime.releaseReference(cell);
        runtime.allocator.destroy(self);
        if (final) destroyCell(runtime, cell);
    }
};

fn destroyCell(runtime: *RuntimeCatalogs, cell: *CatalogCell) void {
    cell.snapshot.deinit();
    runtime.allocator.destroy(cell);
}

fn updateField(hmac: *HmacSha256, bytes: []const u8) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, bytes.len, .big);
    hmac.update(&encoded);
    hmac.update(bytes);
}

test "scope identity is Runtime-secret and canonical-workspace bound" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var workspace = try CanonicalWorkspace.init(
        std.testing.allocator,
        root_buffer[0..root_len],
        "",
    );
    defer workspace.deinit();
    var first = RuntimeCatalogs.initWithSecret(std.testing.allocator, [_]u8{1} ** 32);
    var second = RuntimeCatalogs.initWithSecret(std.testing.allocator, [_]u8{2} ** 32);
    const first_id = try first.scopeId(&workspace);
    const repeated_id = try first.scopeId(&workspace);
    const second_id = try second.scopeId(&workspace);
    try std.testing.expectEqualSlices(u8, &first_id, &repeated_id);
    try std.testing.expect(!std.mem.eql(u8, &first_id, &second_id));
}

test "Host and Session catalog references gate Runtime destruction" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const skill_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/review", .{root});
    defer std.testing.allocator.free(skill_dir);
    try std.Io.Dir.cwd().createDirPath(io, skill_dir);
    const md_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/SKILL.md", .{skill_dir});
    defer std.testing.allocator.free(md_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = md_path,
        .data = "---\nname: Review\n---\nbody",
    });

    var runtime = RuntimeCatalogs.initWithSecret(std.testing.allocator, [_]u8{7} ** 32);
    var workspace = try CanonicalWorkspace.init(std.testing.allocator, root, "");
    defer workspace.deinit();
    const sources = [_]catalog.Source{.{
        .root = root,
        .scope = .project,
        .priority = 1,
    }};
    const host = try runtime.query(io, &workspace, "epoch", &sources, .{});
    const scope_id = try runtime.scopeId(&workspace);
    const session_ref = try runtime.retainForSession(host, &scope_id);
    try std.testing.expectError(error.RuntimeBusy, runtime.tryBeginDestroy());

    try host.release();
    try std.testing.expectError(error.RuntimeBusy, runtime.tryBeginDestroy());
    var call = try runtime.enterCall();
    runtime.releaseSession(session_ref);
    try std.testing.expectError(error.RuntimeBusy, runtime.tryBeginDestroy());
    call.deinit();
    try runtime.tryBeginDestroy();
    runtime.finishDestroy();
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &runtime.secret);
}

test "catalog binding rejects cross-Runtime and cross-Workspace handles without mutation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var runtime = RuntimeCatalogs.initWithSecret(std.testing.allocator, [_]u8{3} ** 32);
    var other = RuntimeCatalogs.initWithSecret(std.testing.allocator, [_]u8{4} ** 32);
    var workspace = try CanonicalWorkspace.init(std.testing.allocator, root, "");
    defer workspace.deinit();
    const host = try runtime.query(io, &workspace, "epoch", &.{}, .{});
    defer host.release() catch unreachable;
    const scope_id = try runtime.scopeId(&workspace);
    try std.testing.expectError(error.WrongRuntime, other.retainForSession(host, &scope_id));
    var wrong_scope = scope_id;
    wrong_scope[0] = if (wrong_scope[0] == '0') '1' else '0';
    try std.testing.expectError(error.WrongWorkspace, runtime.retainForSession(host, &wrong_scope));
    try std.testing.expectEqual(@as(usize, 1), runtime.reference_count);
}

test "default query applies stable project precedence" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const claude_skill = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/.claude/skills/review",
        .{root},
    );
    defer std.testing.allocator.free(claude_skill);
    const metacodes_skill = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/.metacodes/skills/review",
        .{root},
    );
    defer std.testing.allocator.free(metacodes_skill);
    try std.Io.Dir.cwd().createDirPath(io, claude_skill);
    try std.Io.Dir.cwd().createDirPath(io, metacodes_skill);
    const claude_md = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/SKILL.md",
        .{claude_skill},
    );
    defer std.testing.allocator.free(claude_md);
    const metacodes_md = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/SKILL.md",
        .{metacodes_skill},
    );
    defer std.testing.allocator.free(metacodes_md);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = claude_md,
        .data = "---\nname: Claude\n---\nlow",
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = metacodes_md,
        .data = "---\nname: MetaCodes\n---\nhigh",
    });

    var runtime = RuntimeCatalogs.initWithSecret(std.testing.allocator, [_]u8{9} ** 32);
    var workspace = try CanonicalWorkspace.init(std.testing.allocator, root, root);
    defer workspace.deinit();
    const host = try runtime.queryDefault(io, &workspace, "epoch", .{});
    defer host.release() catch unreachable;
    try std.testing.expectEqual(@as(usize, 1), host.snapshot().skills.len);
    try std.testing.expectEqualStrings(
        "MetaCodes",
        host.snapshot().skills[0].definition.name,
    );
}

test "default query discovers personal and project .agents skills with compatible precedence" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const workspace_root = try std.fs.path.join(allocator, &.{ root, "workspace" });
    defer allocator.free(workspace_root);
    const workspace_home = try std.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(workspace_home);
    try std.Io.Dir.cwd().createDirPath(io, workspace_root);
    try std.Io.Dir.cwd().createDirPath(io, workspace_home);

    const Fixture = struct {
        fn write(
            fixture_io: std.Io,
            fixture_allocator: std.mem.Allocator,
            body: []const u8,
            relative_dir: []const []const u8,
            name: []const u8,
        ) !void {
            const skill_dir = try std.fs.path.join(fixture_allocator, relative_dir);
            defer fixture_allocator.free(skill_dir);
            try std.Io.Dir.cwd().createDirPath(fixture_io, skill_dir);
            const skill_md = try std.fs.path.join(fixture_allocator, &.{ skill_dir, "SKILL.md" });
            defer fixture_allocator.free(skill_md);
            const skill_md_contents = try std.fmt.allocPrint(
                fixture_allocator,
                "---\nname: {s}\n---\n{s}",
                .{ name, body },
            );
            defer fixture_allocator.free(skill_md_contents);
            try std.Io.Dir.cwd().writeFile(fixture_io, .{
                .sub_path = skill_md,
                .data = skill_md_contents,
            });
        }
    };

    try Fixture.write(
        io,
        allocator,
        "personal",
        &.{ workspace_home, ".agents", "skills", "personal-only" },
        "Personal Agents",
    );
    try Fixture.write(
        io,
        allocator,
        "project",
        &.{ workspace_root, ".agents", "skills", "project-only" },
        "Project Agents",
    );
    try Fixture.write(
        io,
        allocator,
        "legacy",
        &.{ workspace_root, ".metacodes", "skills", "review" },
        "Project Legacy",
    );
    try Fixture.write(
        io,
        allocator,
        "neutral",
        &.{ workspace_root, ".agents", "skills", "review" },
        "Project Neutral",
    );
    try Fixture.write(
        io,
        allocator,
        "personal neutral",
        &.{ workspace_home, ".agents", "skills", "scope-order" },
        "Personal Neutral",
    );
    try Fixture.write(
        io,
        allocator,
        "project legacy",
        &.{ workspace_root, ".metacodes", "skills", "scope-order" },
        "Project Legacy Scope",
    );

    var runtime = RuntimeCatalogs.initWithSecret(allocator, [_]u8{10} ** 32);
    var workspace = try CanonicalWorkspace.init(allocator, workspace_root, workspace_home);
    defer workspace.deinit();
    const host = try runtime.queryDefault(io, &workspace, "epoch", .{});
    defer host.release() catch unreachable;
    const snapshot = host.snapshot();

    try std.testing.expectEqual(@as(usize, 4), snapshot.skills.len);
    try std.testing.expectEqualStrings(
        "Personal Agents",
        snapshot.findByInvocation("personal-only").?.definition.name,
    );
    try std.testing.expectEqualStrings(
        "Project Agents",
        snapshot.findByInvocation("project-only").?.definition.name,
    );
    try std.testing.expectEqualStrings(
        "Project Neutral",
        snapshot.findByInvocation("review").?.definition.name,
    );
    try std.testing.expectEqualStrings(
        "Project Legacy Scope",
        snapshot.findByInvocation("scope-order").?.definition.name,
    );
}

test "live snapshot budget rejects publication without leaking a reference" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var workspace = try CanonicalWorkspace.init(
        std.testing.allocator,
        root_buffer[0..root_len],
        "",
    );
    defer workspace.deinit();
    var runtime = RuntimeCatalogs.initWithSecret(std.testing.allocator, [_]u8{5} ** 32);
    runtime.max_live_snapshot_bytes = 1;
    try std.testing.expectError(
        error.ResourceLimit,
        runtime.query(io, &workspace, "epoch", &.{}, .{}),
    );
    try std.testing.expectEqual(@as(usize, 0), runtime.reference_count);
    try std.testing.expectEqual(@as(usize, 0), runtime.live_snapshot_bytes);
}
