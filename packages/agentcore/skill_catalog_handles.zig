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
/// Scope-identity domain introduced in Revision 5. This is a persisted
/// identity marker, not the current public ABI revision; changing it would
/// invalidate otherwise compatible checkpoint Workspace bindings.
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
    InvalidSource,
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
    /// Filesystem discovery is synchronous and may transiently hold both the
    /// candidate arena and the immutable clone. Serialize only that work per
    /// Runtime so concurrent Host queries cannot multiply the bounded build
    /// peak. Lifecycle/refcount operations continue to use `mutex` and never
    /// hold it across filesystem I/O.
    build_mutex: sync.Mutex = .{},
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
        self.build_mutex.lock();
        defer self.build_mutex.unlock();

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
        const sources = try agentCoreSources(scratch.allocator(), workspace, .{}, &.{});
        return self.queryUnderGuard(
            io,
            workspace,
            workspace_epoch,
            sources,
            limits,
        );
    }

    pub fn queryWorkspace(
        self: *RuntimeCatalogs,
        io: std.Io,
        workspace: *const CanonicalWorkspace,
        workspace_epoch: []const u8,
        default_priorities: DefaultSourcePriorities,
        additional_sources: []const AdditionalSource,
        limits: catalog.Limits,
    ) (Error || catalog.BuildError)!*HostCatalog {
        var call = try self.enterCall();
        defer call.deinit();
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const sources = try agentCoreSources(
            scratch.allocator(),
            workspace,
            default_priorities,
            additional_sources,
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

pub const DEFAULT_USER_SOURCE_ID = "agents.user.default";
pub const DEFAULT_WORKSPACE_SOURCE_ID = "agents.workspace.default";
pub const MAX_ADDITIONAL_SOURCES: usize = 64;
/// The source priority of every source the Host leaves unconfigured. A zeroed
/// query therefore resolves exactly as before source priorities existed.
pub const DEFAULT_SOURCE_PRIORITY: i32 = 0;

pub const AuthorityScope = enum {
    user,
    workspace,
};

/// Source priorities of the two default `.agents/skills` sources. The User one
/// is unused when the canonical home and root are equal.
pub const DefaultSourcePriorities = struct {
    user: i32 = DEFAULT_SOURCE_PRIORITY,
    workspace: i32 = DEFAULT_SOURCE_PRIORITY,
};

pub const AdditionalSource = struct {
    root: []const u8,
    scope: AuthorityScope,
    source_instance_id: []const u8,
    priority: i32 = DEFAULT_SOURCE_PRIORITY,
};

/// Maps a scope and a source priority onto the shared catalog's single
/// priority. Scope takes the high word, so every Workspace candidate outranks
/// every User candidate whatever their source priorities; the low word orders
/// source priorities within one scope (the sign bit flipped keeps i32 order
/// in u32). Equal results stay a `source_conflict`, so registration order,
/// root paths, and source ids never pick a winner.
fn catalogPriority(scope: AuthorityScope, priority: i32) u64 {
    const band: u64 = switch (scope) {
        .user => 1,
        .workspace => 2,
    };
    const ordered: u32 = @as(u32, @bitCast(priority)) ^ 0x8000_0000;
    return band << 32 | ordered;
}

/// AgentCore owns only the cross-Agent neutral discovery convention. Product
/// adapters may opt into additional roots through the shared catalog engine,
/// but those roots must never become implicit AgentCore filesystem authority.
fn agentCoreSources(
    arena: std.mem.Allocator,
    workspace: *const CanonicalWorkspace,
    defaults: DefaultSourcePriorities,
    additional: []const AdditionalSource,
) Error![]const catalog.Source {
    if (additional.len > MAX_ADDITIONAL_SOURCES) return error.ResourceLimit;
    const shared_root = std.mem.eql(u8, workspace.home, workspace.root);
    const default_count: usize = if (shared_root) 1 else 2;
    const sources = try arena.alloc(catalog.Source, default_count + additional.len);
    var next: usize = 0;
    if (!shared_root) {
        sources[next] = .{
            .root = try std.fs.path.join(arena, &.{ workspace.home, ".agents", "skills" }),
            .scope = .personal,
            .priority = catalogPriority(.user, defaults.user),
            .source_instance_id = DEFAULT_USER_SOURCE_ID,
        };
        next += 1;
    }
    sources[next] = .{
        .root = try std.fs.path.join(arena, &.{ workspace.root, ".agents", "skills" }),
        .scope = .project,
        .priority = catalogPriority(.workspace, defaults.workspace),
        .source_instance_id = DEFAULT_WORKSPACE_SOURCE_ID,
    };
    next += 1;

    for (additional) |source| {
        if (source.root.len == 0 or !std.fs.path.isAbsolute(source.root) or
            !validSourceInstanceId(source.source_instance_id))
            return error.InvalidSource;
        for (sources[0..next]) |existing| {
            if (std.mem.eql(u8, existing.root, source.root) or
                std.mem.eql(u8, existing.source_instance_id, source.source_instance_id))
                return error.InvalidSource;
        }
        sources[next] = .{
            .root = source.root,
            .scope = switch (source.scope) {
                .user => .personal,
                .workspace => .project,
            },
            .priority = catalogPriority(source.scope, source.priority),
            .source_instance_id = source.source_instance_id,
        };
        next += 1;
    }
    return sources[0..next];
}

pub fn validSourceInstanceId(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and
            byte != ':' and byte != '-') return false;
    }
    return true;
}

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

test "Runtime serializes catalog builds without holding the lifecycle lock" {
    const Worker = struct {
        runtime: *RuntimeCatalogs,
        workspace: *const CanonicalWorkspace,
        completed: *std.atomic.Value(bool),
        failed: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            const host = self.runtime.query(
                std.testing.io,
                self.workspace,
                "epoch",
                &.{},
                .{},
            ) catch {
                self.failed.store(true, .release);
                self.completed.store(true, .release);
                return;
            };
            host.release() catch self.failed.store(true, .release);
            self.completed.store(true, .release);
        }
    };

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
    var runtime = RuntimeCatalogs.initWithSecret(std.testing.allocator, [_]u8{8} ** 32);
    var completed = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);
    var worker = Worker{
        .runtime = &runtime,
        .workspace = &workspace,
        .completed = &completed,
        .failed = &failed,
    };

    runtime.build_mutex.lock();
    var gate_locked = true;
    defer if (gate_locked) runtime.build_mutex.unlock();
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    var joined = false;
    defer if (!joined) thread.join();

    var observed_waiting_call = false;
    for (0..10_000) |_| {
        runtime.mutex.lock();
        const active_calls = runtime.active_calls;
        runtime.mutex.unlock();
        if (active_calls == 1) {
            observed_waiting_call = true;
            break;
        }
        sync.sleepMs(1);
    }
    try std.testing.expect(observed_waiting_call);
    try std.testing.expect(!completed.load(.acquire));
    try std.testing.expectError(error.RuntimeBusy, runtime.tryBeginDestroy());

    runtime.build_mutex.unlock();
    gate_locked = false;
    thread.join();
    joined = true;
    try std.testing.expect(completed.load(.acquire));
    try std.testing.expect(!failed.load(.acquire));
    try runtime.tryBeginDestroy();
    runtime.finishDestroy();
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

test "AgentCore default sources collapse identical canonical home and root" {
    try std.testing.expectEqualStrings(
        "metask-agentcore/abi-v1/revision-5",
        BUNDLE_IDENTITY,
    );
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var workspace = try CanonicalWorkspace.init(
        allocator,
        root_buffer[0..root_len],
        "",
    );
    defer workspace.deinit();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    const sources = try agentCoreSources(
        scratch.allocator(),
        &workspace,
        .{},
        &.{},
    );
    try std.testing.expectEqual(@as(usize, 1), sources.len);
    try std.testing.expectEqual(catalog.SourceScope.project, sources[0].scope);
    try std.testing.expectEqual(
        catalogPriority(.workspace, DEFAULT_SOURCE_PRIORITY),
        sources[0].priority,
    );
    const expected = try std.fs.path.join(
        scratch.allocator(),
        &.{ workspace.root, ".agents", "skills" },
    );
    try std.testing.expectEqualStrings(expected, sources[0].root);
}

test "AgentCore authority does not reinterpret shared home as a user-only Catalog" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var workspace = try CanonicalWorkspace.init(
        allocator,
        root_buffer[0..root_len],
        "",
    );
    defer workspace.deinit();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    const sources = try agentCoreSources(
        scratch.allocator(),
        &workspace,
        .{},
        &.{},
    );
    try std.testing.expectEqual(@as(usize, 1), sources.len);
    try std.testing.expectEqual(catalog.SourceScope.project, sources[0].scope);
    try std.testing.expectEqual(
        catalogPriority(.workspace, DEFAULT_SOURCE_PRIORITY),
        sources[0].priority,
    );
    const expected = try std.fs.path.join(
        scratch.allocator(),
        &.{ workspace.root, ".agents", "skills" },
    );
    try std.testing.expectEqualStrings(expected, sources[0].root);
}

test "AgentCore default query ignores product-specific Skill roots" {
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
    try std.testing.expectEqual(@as(usize, 0), host.snapshot().skills.len);
}

test "AgentCore default query discovers only personal and project .agents Skills" {
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
        "project neutral",
        &.{ workspace_root, ".agents", "skills", "scope-order" },
        "Project Agents Scope",
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
        "Project Agents Scope",
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

test "failed catalog build preserves an existing Host snapshot" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const skill_dir = try std.fs.path.join(allocator, &.{ root, "review" });
    defer allocator.free(skill_dir);
    try std.Io.Dir.cwd().createDirPath(io, skill_dir);
    const skill_md = try std.fs.path.join(allocator, &.{ skill_dir, "SKILL.md" });
    defer allocator.free(skill_md);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = skill_md,
        .data = "---\nname: Review\n---\nbody",
    });

    var runtime = RuntimeCatalogs.initWithSecret(allocator, [_]u8{6} ** 32);
    var workspace = try CanonicalWorkspace.init(allocator, root, "");
    defer workspace.deinit();
    const sources = [_]catalog.Source{.{
        .root = root,
        .scope = .project,
        .priority = 1,
    }};
    var host: ?*HostCatalog = try runtime.query(io, &workspace, "epoch", &sources, .{});
    defer if (host) |value| value.release() catch unreachable;
    const resident_before = runtime.live_snapshot_bytes;

    try std.testing.expectError(
        error.ResourceLimit,
        runtime.query(io, &workspace, "epoch", &sources, .{
            .max_catalog_content_bytes = 1,
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), runtime.reference_count);
    try std.testing.expectEqual(resident_before, runtime.live_snapshot_bytes);
    try std.testing.expectEqualStrings(
        "Review",
        host.?.snapshot().findByInvocation("review").?.definition.name,
    );

    try host.?.release();
    host = null;
    try runtime.tryBeginDestroy();
    runtime.finishDestroy();
}

/// A Workspace `<tmp>/workspace` and home `<tmp>/home` whose Skills sit below
/// arbitrary roots, for the source-priority tests (#390). Initialized in place:
/// the arena's allocator points into the fixture.
const PriorityFixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    workspace: CanonicalWorkspace,
    runtime: RuntimeCatalogs,

    fn init(self: *PriorityFixture) !void {
        const allocator = std.testing.allocator;
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        var base_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const base_len = try self.tmp.dir.realPath(std.testing.io, &base_buffer);
        const root = try std.fs.path.join(arena, &.{ base_buffer[0..base_len], "workspace" });
        const home = try std.fs.path.join(arena, &.{ base_buffer[0..base_len], "home" });
        try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
        try std.Io.Dir.cwd().createDirPath(std.testing.io, home);
        self.workspace = try CanonicalWorkspace.init(allocator, root, home);
        self.runtime = RuntimeCatalogs.initWithSecret(allocator, [_]u8{39} ** 32);
    }

    fn deinit(self: *PriorityFixture) void {
        self.workspace.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
    }

    /// `<workspace root>/<dir>/skills`.
    fn workspaceRoot(self: *PriorityFixture, dir: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.workspace.root, dir, "skills" });
    }

    /// `<workspace home>/<dir>/skills`.
    fn homeRoot(self: *PriorityFixture, dir: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.workspace.home, dir, "skills" });
    }

    /// Writes `<skills_root>/<name>/SKILL.md` naming the Skill `display`, with
    /// `display` as its body too, so a winner is visible in both.
    fn writeSkill(
        self: *PriorityFixture,
        skills_root: []const u8,
        name: []const u8,
        display: []const u8,
    ) !void {
        try self.writeRaw(skills_root, name, try std.fmt.allocPrint(
            self.arena.allocator(),
            "---\nname: {s}\n---\n{s}",
            .{ display, display },
        ));
    }

    fn writeRaw(
        self: *PriorityFixture,
        skills_root: []const u8,
        name: []const u8,
        contents: []const u8,
    ) !void {
        const arena = self.arena.allocator();
        const dir = try std.fs.path.join(arena, &.{ skills_root, name });
        try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{
            .sub_path = try std.fs.path.join(arena, &.{ dir, "SKILL.md" }),
            .data = contents,
        });
    }

    fn query(
        self: *PriorityFixture,
        defaults: DefaultSourcePriorities,
        additional: []const AdditionalSource,
    ) !*HostCatalog {
        return self.queryLimited(defaults, additional, .{});
    }

    fn queryLimited(
        self: *PriorityFixture,
        defaults: DefaultSourcePriorities,
        additional: []const AdditionalSource,
        limits: catalog.Limits,
    ) !*HostCatalog {
        return self.runtime.queryWorkspace(
            std.testing.io,
            &self.workspace,
            "epoch",
            defaults,
            additional,
            limits,
        );
    }
};

fn expectWinner(
    host: *const HostCatalog,
    name: []const u8,
    source_instance_id: []const u8,
    display: []const u8,
) !void {
    const skill = host.snapshot().findByInvocation(name) orelse {
        std.debug.print("Skill '{s}' is not in the catalog\n", .{name});
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings(source_instance_id, skill.source_instance_id);
    try std.testing.expectEqualStrings(display, skill.definition.name);
}

fn expectHealthy(host: *const HostCatalog) !void {
    try std.testing.expectEqual(catalog.Health.healthy, host.snapshot().health);
    try std.testing.expectEqual(@as(usize, 0), host.snapshot().issues.len);
}

fn expectConflict(host: *const HostCatalog, name: []const u8) !void {
    const snapshot = host.snapshot();
    try std.testing.expect(snapshot.findByInvocation(name) == null);
    try std.testing.expectEqual(catalog.Health.degraded, snapshot.health);
    for (snapshot.issues) |issue| {
        if (issue.code == .source_conflict and
            std.mem.eql(u8, issue.invocation_name orelse "", name)) return;
    }
    std.debug.print("no source_conflict for '{s}'\n", .{name});
    return error.TestUnexpectedResult;
}

test "source priority orders by scope first, then by priority within a scope" {
    const values = [_]i32{ std.math.minInt(i32), -1, 0, 1, std.math.maxInt(i32) };
    for (values) |user| {
        for (values) |workspace| {
            try std.testing.expect(
                catalogPriority(.workspace, workspace) > catalogPriority(.user, user),
            );
        }
    }
    for (values[0 .. values.len - 1], values[1..]) |lower, higher| {
        for ([_]AuthorityScope{ .user, .workspace }) |scope| {
            try std.testing.expect(catalogPriority(scope, lower) < catalogPriority(scope, higher));
        }
    }
}

test "a Workspace candidate beats a User candidate of higher source priority (#390)" {
    var fixture: PriorityFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const user_claude = try fixture.homeRoot(".claude");
    try fixture.writeSkill(try fixture.homeRoot(".agents"), "review", "User Default");
    try fixture.writeSkill(user_claude, "review", "User Claude");
    try fixture.writeSkill(try fixture.workspaceRoot(".agents"), "review", "Workspace Default");
    try fixture.writeSkill(try fixture.homeRoot(".agents"), "personal", "User Default Personal");
    try fixture.writeSkill(user_claude, "personal", "User Claude Personal");

    // Scope first: the lowest Workspace priority beats the highest User one.
    const sources = [_]AdditionalSource{.{
        .root = user_claude,
        .scope = .user,
        .source_instance_id = "user.claude",
        .priority = std.math.maxInt(i32) - 1,
    }};
    const host = try fixture.query(.{
        .user = std.math.maxInt(i32),
        .workspace = std.math.minInt(i32),
    }, &sources);
    defer host.release() catch unreachable;
    try expectHealthy(host);
    try expectWinner(host, "review", DEFAULT_WORKSPACE_SOURCE_ID, "Workspace Default");
    // Within the User scope the source priority still ranks.
    try expectWinner(host, "personal", DEFAULT_USER_SOURCE_ID, "User Default Personal");

    var raised = sources;
    raised[0].priority = std.math.maxInt(i32);
    const reranked = try fixture.query(.{ .user = 0, .workspace = 0 }, &raised);
    defer reranked.release() catch unreachable;
    try expectHealthy(reranked);
    try expectWinner(reranked, "review", DEFAULT_WORKSPACE_SOURCE_ID, "Workspace Default");
    try expectWinner(reranked, "personal", "user.claude", "User Claude Personal");
}

test "within one scope the higher source priority wins without a conflict (#390)" {
    var fixture: PriorityFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const claude = try fixture.workspaceRoot(".claude");
    const codex = try fixture.workspaceRoot(".codex");
    try fixture.writeSkill(claude, "review", "Claude Review");
    try fixture.writeSkill(codex, "review", "Codex Review");

    var sources = [_]AdditionalSource{
        .{ .root = codex, .scope = .workspace, .source_instance_id = "consumer.codex", .priority = 0 },
        .{ .root = claude, .scope = .workspace, .source_instance_id = "consumer.claude", .priority = 10 },
    };
    const claude_wins = try fixture.query(.{}, &sources);
    defer claude_wins.release() catch unreachable;
    try expectHealthy(claude_wins);
    try expectWinner(claude_wins, "review", "consumer.claude", "Claude Review");

    // The priority, not the path or the id, decides: lower it below Codex.
    sources[1].priority = -1;
    const codex_wins = try fixture.query(.{}, &sources);
    defer codex_wins.release() catch unreachable;
    try expectHealthy(codex_wins);
    try expectWinner(codex_wins, "review", "consumer.codex", "Codex Review");
}

test "a tie at the highest source priority is still a conflict (#390)" {
    var fixture: PriorityFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const claude = try fixture.workspaceRoot(".claude");
    const codex = try fixture.workspaceRoot(".codex");
    try fixture.writeSkill(claude, "review", "Claude Review");
    try fixture.writeSkill(codex, "review", "Codex Review");
    try fixture.writeSkill(try fixture.workspaceRoot(".agents"), "review", "Default Review");

    var sources = [_]AdditionalSource{
        .{ .root = claude, .scope = .workspace, .source_instance_id = "consumer.claude", .priority = 10 },
        .{ .root = codex, .scope = .workspace, .source_instance_id = "consumer.codex", .priority = 10 },
    };
    const tied = try fixture.query(.{}, &sources);
    defer tied.release() catch unreachable;
    try expectConflict(tied, "review");
    try std.testing.expectEqual(@as(usize, 1), tied.snapshot().issues.len);

    // Unconfigured sources tie at the default too.
    const all_default = [_]AdditionalSource{
        .{ .root = claude, .scope = .workspace, .source_instance_id = "consumer.claude" },
        .{ .root = codex, .scope = .workspace, .source_instance_id = "consumer.codex" },
    };
    const defaults_tied = try fixture.query(.{}, &all_default);
    defer defaults_tied.release() catch unreachable;
    try expectConflict(defaults_tied, "review");

    sources[1].priority = 9;
    const broken_tie = try fixture.query(.{}, &sources);
    defer broken_tie.release() catch unreachable;
    try expectHealthy(broken_tie);
    try expectWinner(broken_tie, "review", "consumer.claude", "Claude Review");
}

test "a unique highest candidate wins over tied lower candidates (#390)" {
    var fixture: PriorityFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const claude = try fixture.workspaceRoot(".claude");
    const codex = try fixture.workspaceRoot(".codex");
    try fixture.writeSkill(claude, "review", "Claude Review");
    try fixture.writeSkill(codex, "review", "Codex Review");
    try fixture.writeSkill(try fixture.workspaceRoot(".agents"), "review", "Default Review");

    // Codex and the default Workspace source tie at 0, below Claude.
    var sources = [_]AdditionalSource{
        .{ .root = claude, .scope = .workspace, .source_instance_id = "consumer.claude", .priority = 10 },
        .{ .root = codex, .scope = .workspace, .source_instance_id = "consumer.codex" },
    };
    const unique = try fixture.query(.{}, &sources);
    defer unique.release() catch unreachable;
    try expectHealthy(unique);
    try expectWinner(unique, "review", "consumer.claude", "Claude Review");

    sources[0].priority = 0;
    const three_way = try fixture.query(.{}, &sources);
    defer three_way.release() catch unreachable;
    try expectConflict(three_way, "review");
}

test "Skills unique to lower-priority sources stay available (#390)" {
    var fixture: PriorityFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    // The issue's example: `.codex/skills` and `.claude/skills` as Workspace
    // sources, both defining `review`.
    const claude = try fixture.workspaceRoot(".claude");
    const codex = try fixture.workspaceRoot(".codex");
    try fixture.writeSkill(codex, "review", "Codex Review");
    try fixture.writeSkill(codex, "zig", "Codex Zig");
    try fixture.writeSkill(claude, "review", "Claude Review");
    try fixture.writeSkill(claude, "release", "Claude Release");

    var sources = [_]AdditionalSource{
        .{ .root = codex, .scope = .workspace, .source_instance_id = "consumer.codex" },
        .{ .root = claude, .scope = .workspace, .source_instance_id = "consumer.claude" },
    };
    const unranked = try fixture.query(.{}, &sources);
    defer unranked.release() catch unreachable;
    try expectConflict(unranked, "review");
    try expectWinner(unranked, "zig", "consumer.codex", "Codex Zig");
    try expectWinner(unranked, "release", "consumer.claude", "Claude Release");

    sources[1].priority = 10;
    const ranked = try fixture.query(.{}, &sources);
    defer ranked.release() catch unreachable;
    try expectHealthy(ranked);
    try std.testing.expectEqual(@as(usize, 3), ranked.snapshot().skills.len);
    try expectWinner(ranked, "review", "consumer.claude", "Claude Review");
    try expectWinner(ranked, "zig", "consumer.codex", "Codex Zig");
    try expectWinner(ranked, "release", "consumer.claude", "Claude Release");
}

test "a broken selected candidate reports its error and never falls back (#390)" {
    var fixture: PriorityFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const claude = try fixture.workspaceRoot(".claude");
    const codex = try fixture.workspaceRoot(".codex");
    try fixture.writeRaw(claude, "review", "---\nname: Claude Review\ncontext: surprise\n---\nbody");
    try fixture.writeSkill(codex, "review", "Codex Review");
    // A second file makes Claude's `lint` too large under max_skill_files = 1;
    // Codex's single-file `lint` would fit.
    try fixture.writeSkill(claude, "lint", "Claude Lint");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = try std.fs.path.join(fixture.arena.allocator(), &.{ claude, "lint", "extra.md" }),
        .data = "extra",
    });
    try fixture.writeSkill(codex, "lint", "Codex Lint");

    var sources = [_]AdditionalSource{
        .{ .root = claude, .scope = .workspace, .source_instance_id = "consumer.claude", .priority = 10 },
        .{ .root = codex, .scope = .workspace, .source_instance_id = "consumer.codex" },
    };
    const broken = try fixture.queryLimited(.{}, &sources, .{ .max_skill_files = 1 });
    defer broken.release() catch unreachable;
    const snapshot = broken.snapshot();
    try std.testing.expectEqual(catalog.Health.degraded, snapshot.health);
    try std.testing.expectEqual(@as(usize, 0), snapshot.skills.len);
    try std.testing.expectEqual(@as(usize, 2), snapshot.issues.len);
    for (snapshot.issues) |issue| {
        try std.testing.expectEqualStrings("consumer.claude", issue.source_instance_id);
        const name = issue.invocation_name.?;
        if (std.mem.eql(u8, name, "review")) {
            try std.testing.expectEqual(catalog.IssueCode.invalid_definition, issue.code);
        } else {
            try std.testing.expectEqualStrings("lint", name);
            try std.testing.expectEqual(catalog.IssueCode.invalid_resource, issue.code);
            try std.testing.expectEqual(catalog.ResourceReason.too_many_files, issue.reason.?);
        }
    }

    // Below the valid candidate, the broken one is never selected or reported.
    sources[0].priority = -1;
    const shadowed = try fixture.queryLimited(.{}, &sources, .{ .max_skill_files = 1 });
    defer shadowed.release() catch unreachable;
    try expectHealthy(shadowed);
    try expectWinner(shadowed, "review", "consumer.codex", "Codex Review");
    try expectWinner(shadowed, "lint", "consumer.codex", "Codex Lint");
}

test "omitted source priorities resolve exactly as before they existed (#390)" {
    var fixture: PriorityFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const claude = try fixture.workspaceRoot(".claude");
    const codex = try fixture.workspaceRoot(".codex");
    const user_claude = try fixture.homeRoot(".claude");
    try fixture.writeSkill(try fixture.homeRoot(".agents"), "review", "User Review");
    try fixture.writeSkill(try fixture.homeRoot(".agents"), "personal", "User Personal");
    try fixture.writeSkill(user_claude, "personal", "User Claude Personal");
    try fixture.writeSkill(try fixture.workspaceRoot(".agents"), "review", "Workspace Review");
    try fixture.writeSkill(claude, "shared", "Claude Shared");
    try fixture.writeSkill(codex, "shared", "Codex Shared");
    try fixture.writeSkill(codex, "zig", "Codex Zig");

    const unconfigured = [_]AdditionalSource{
        .{ .root = claude, .scope = .workspace, .source_instance_id = "consumer.claude" },
        .{ .root = codex, .scope = .workspace, .source_instance_id = "consumer.codex" },
        .{ .root = user_claude, .scope = .user, .source_instance_id = "user.claude" },
    };
    const omitted = try fixture.query(.{}, &unconfigured);
    defer omitted.release() catch unreachable;
    try expectConflict(omitted, "shared");
    try expectConflict(omitted, "personal");
    try expectWinner(omitted, "review", DEFAULT_WORKSPACE_SOURCE_ID, "Workspace Review");
    try expectWinner(omitted, "zig", "consumer.codex", "Codex Zig");

    // Explicit zeros are the same configuration as no configuration.
    var zeros = unconfigured;
    for (&zeros) |*source| source.priority = 0;
    const explicit = try fixture.query(.{ .user = 0, .workspace = 0 }, &zeros);
    defer explicit.release() catch unreachable;
    try std.testing.expectEqualStrings(
        omitted.snapshot().descriptor_json,
        explicit.snapshot().descriptor_json,
    );

    // The mapping before #390: every User source 1, every Workspace source 2.
    const legacy = [_]catalog.Source{
        .{ .root = try fixture.homeRoot(".agents"), .scope = .personal, .priority = 1, .source_instance_id = DEFAULT_USER_SOURCE_ID },
        .{ .root = try fixture.workspaceRoot(".agents"), .scope = .project, .priority = 2, .source_instance_id = DEFAULT_WORKSPACE_SOURCE_ID },
        .{ .root = claude, .scope = .project, .priority = 2, .source_instance_id = "consumer.claude" },
        .{ .root = codex, .scope = .project, .priority = 2, .source_instance_id = "consumer.codex" },
        .{ .root = user_claude, .scope = .personal, .priority = 1, .source_instance_id = "user.claude" },
    };
    const before = try fixture.runtime.query(std.testing.io, &fixture.workspace, "epoch", &legacy, .{});
    defer before.release() catch unreachable;
    try std.testing.expectEqualSlices(u8, &before.snapshot().revision, &omitted.snapshot().revision);
    try std.testing.expectEqualStrings(
        before.snapshot().descriptor_json,
        omitted.snapshot().descriptor_json,
    );
}

/// Rearranges `values` into the next lexicographic permutation; false after
/// the last one.
fn nextPermutation(values: []usize) bool {
    if (values.len < 2) return false;
    var pivot = values.len - 1;
    while (pivot > 0 and values[pivot - 1] >= values[pivot]) pivot -= 1;
    if (pivot == 0) return false;
    var successor = values.len - 1;
    while (values[successor] <= values[pivot - 1]) successor -= 1;
    std.mem.swap(usize, &values[pivot - 1], &values[successor]);
    std.mem.reverse(usize, values[pivot..]);
    return true;
}

test "registration order, root paths, and source ids never pick a winner (#390)" {
    var fixture: PriorityFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    // Source ids run against path order, so neither order can stand in for
    // the priority.
    const alpha = try fixture.workspaceRoot(".alpha");
    const beta = try fixture.workspaceRoot(".beta");
    const gamma = try fixture.workspaceRoot(".gamma");
    const delta = try fixture.workspaceRoot(".delta");
    try fixture.writeSkill(alpha, "review", "Alpha Review");
    try fixture.writeSkill(beta, "review", "Beta Review");
    try fixture.writeSkill(delta, "review", "Delta Review");
    try fixture.writeSkill(alpha, "tie", "Alpha Tie");
    try fixture.writeSkill(beta, "tie", "Beta Tie");
    try fixture.writeSkill(gamma, "tie", "Gamma Tie");
    try fixture.writeSkill(alpha, "low", "Alpha Low");
    try fixture.writeSkill(delta, "low", "Delta Low");

    for ([_][2]i32{ .{ 1, 2 }, .{ 2, 1 } }) |alpha_delta| {
        const registered = [_]AdditionalSource{
            .{ .root = alpha, .scope = .workspace, .source_instance_id = "z.alpha", .priority = alpha_delta[0] },
            .{ .root = beta, .scope = .workspace, .source_instance_id = "m.beta", .priority = 5 },
            .{ .root = gamma, .scope = .workspace, .source_instance_id = "a.gamma", .priority = 5 },
            .{ .root = delta, .scope = .workspace, .source_instance_id = "q.delta", .priority = alpha_delta[1] },
        };
        var order = [_]usize{ 0, 1, 2, 3 };
        var reference: ?[]const u8 = null;
        var permutations: usize = 0;
        while (true) {
            var sources: [registered.len]AdditionalSource = undefined;
            for (&sources, order) |*source, index| source.* = registered[index];
            const host = try fixture.query(.{}, &sources);
            defer host.release() catch unreachable;
            try expectWinner(host, "review", "m.beta", "Beta Review");
            try expectConflict(host, "tie");
            if (alpha_delta[0] > alpha_delta[1])
                try expectWinner(host, "low", "z.alpha", "Alpha Low")
            else
                try expectWinner(host, "low", "q.delta", "Delta Low");
            const descriptor = host.snapshot().descriptor_json;
            if (reference) |expected| {
                try std.testing.expectEqualStrings(expected, descriptor);
            } else {
                reference = try fixture.arena.allocator().dupe(u8, descriptor);
            }
            permutations += 1;
            if (!nextPermutation(&order)) break;
        }
        try std.testing.expectEqual(@as(usize, 24), permutations);
    }
}

test "the selected Skill and its source identity name the winner (#390)" {
    var fixture: PriorityFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const claude = try fixture.workspaceRoot(".claude");
    const codex = try fixture.workspaceRoot(".codex");
    try fixture.writeSkill(claude, "review", "CLAUDE_REVIEW_SENTINEL");
    try fixture.writeSkill(codex, "review", "CODEX_REVIEW_SENTINEL");

    var sources = [_]AdditionalSource{
        .{ .root = claude, .scope = .workspace, .source_instance_id = "consumer.claude", .priority = 10 },
        .{ .root = codex, .scope = .workspace, .source_instance_id = "consumer.codex" },
    };
    const Round = struct {
        priority: i32,
        root: []const u8,
        id: []const u8,
        body: []const u8,
        loser_id: []const u8,
        loser_body: []const u8,
    };
    const rounds = [_]Round{
        .{
            .priority = 10,
            .root = claude,
            .id = "consumer.claude",
            .body = "CLAUDE_REVIEW_SENTINEL",
            .loser_id = "consumer.codex",
            .loser_body = "CODEX_REVIEW_SENTINEL",
        },
        .{
            .priority = -10,
            .root = codex,
            .id = "consumer.codex",
            .body = "CODEX_REVIEW_SENTINEL",
            .loser_id = "consumer.claude",
            .loser_body = "CLAUDE_REVIEW_SENTINEL",
        },
    };
    var execution_ids: [rounds.len][64]u8 = undefined;
    for (rounds, &execution_ids) |round, *execution_id| {
        sources[0].priority = round.priority;
        const host = try fixture.query(.{}, &sources);
        defer host.release() catch unreachable;
        try expectHealthy(host);
        const snapshot = host.snapshot();
        const skill = snapshot.findByInvocation("review").?;
        try std.testing.expectEqualStrings(round.id, skill.source_instance_id);
        try std.testing.expectEqualStrings(round.root, skill.source_root);
        try std.testing.expectEqual(catalog.SourceScope.project, skill.source_scope);
        try std.testing.expectEqualStrings(round.body, skill.definition.body);
        try std.testing.expectEqual(skill, snapshot.findByExecutionId(&skill.execution_id).?);
        try std.testing.expectEqual(skill, snapshot.findById(&skill.skill_id).?);
        for (skill.files) |file| {
            try std.testing.expect(std.mem.indexOf(u8, file.bytes, round.loser_body) == null);
        }
        try std.testing.expect(std.mem.indexOf(u8, snapshot.descriptor_json, round.id) != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot.descriptor_json, round.loser_id) == null);
        execution_id.* = skill.execution_id;
    }
    try std.testing.expect(!std.mem.eql(u8, &execution_ids[0], &execution_ids[1]));
}
