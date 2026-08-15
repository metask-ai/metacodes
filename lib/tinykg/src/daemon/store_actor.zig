const std = @import("std");
const tinykg = @import("../tinykg.zig");
const ownership_lock = @import("../storage/daemon_ownership_lock.zig");
const host_maintenance_lock = @import("../storage/host_maintenance_lock.zig");
const compact_commands = @import("compact_commands.zig");
const command_policy = @import("command_policy.zig");
const protocol = @import("protocol.zig");

pub const execution_model: []const u8 = "single_thread_store_actor";
pub const store_owner_count: u8 = 1;
pub const durable_writer_route_count: u8 = 1;
pub const session_ttl_ms: u64 = 300000;
const replay_capacity: usize = protocol.queue_capacity;
const default_session_id = "web-default";

const Session = struct {
    id: []u8,
    generation: u64,
    expires_at_ms: u64,
    query: ?tinykg.ql.executor.PersistentStoreQuerySession,
    /// One catalog read and parse per store generation instead of per query;
    /// destroyed with the session on every commit.
    catalog_cache: tinykg.cli.QueryCatalogCache = .{},

    fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        self.catalog_cache.deinit();
        if (self.query) |*query| query.deinit();
        allocator.free(self.id);
        self.* = undefined;
    }
};

const OwnedResponse = struct {
    value: protocol.Response,

    fn deinit(self: *OwnedResponse, allocator: std.mem.Allocator) void {
        allocator.free(@constCast(self.value.requestId));
        allocator.free(@constCast(self.value.stdout));
        allocator.free(@constCast(self.value.stderr));
        if (self.value.session) |session| allocator.free(@constCast(session.sessionId));
        self.* = undefined;
    }
};

const ReplayEntry = struct {
    fingerprint: u64,
    response: OwnedResponse,

    fn deinit(self: *ReplayEntry, allocator: std.mem.Allocator) void {
        self.response.deinit(allocator);
        self.* = undefined;
    }
};

pub const StoreActor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store_path: []u8,
    ownership_lock: ?ownership_lock.OwnershipLock,
    invocation_environment: std.process.Environ.Map,
    /// Read-only actors serve concurrent readers beside the exclusive writer
    /// daemon: no ownership lock, every durable mutation rejected, and reader
    /// sessions invalidated whenever the event log has grown.
    read_only: bool = false,
    read_only_seen_event_bytes: u64 = 0,
    /// A write-path failure left index maintenance owing; the scheduler
    /// control runs the repair between requests instead of inside them.
    pending_maintenance: bool = false,
    store: ?tinykg.storage.Store,
    compact_runtime: ?tinykg.checkpoint.Runtime,
    generation: u64 = 0,
    sessions: std.ArrayList(Session) = .empty,
    replay: std.ArrayList(ReplayEntry) = .empty,
    control_response: protocol.Response = .{
        .requestId = "",
        .ok = true,
        .code = 0,
        .stdout = "",
        .stderr = "",
        .generation = 0,
        .commitState = .none,
    },

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        store_path: []const u8,
    ) !StoreActor {
        const owned_path = try allocator.dupe(u8, store_path);
        errdefer allocator.free(owned_path);
        var acquired_ownership_lock = ownership_lock.OwnershipLock.acquire(
            allocator,
            io,
            owned_path,
        ) catch |err| switch (err) {
            error.DaemonAlreadyOwnsStore => return error.DaemonAlreadyOwnsStore,
            else => |e| return e,
        };
        errdefer acquired_ownership_lock.deinit();

        var invocation_environment = std.process.Environ.Map.init(allocator);
        errdefer invocation_environment.deinit();
        try invocation_environment.put("TINYKG_STORE", owned_path);
        try invocation_environment.put("TINYKG_DAEMON_INTERNAL", "1");

        const compact = try compactRepositoryPresent(allocator, io, owned_path);
        var compact_runtime: ?tinykg.checkpoint.Runtime = if (compact)
            try tinykg.checkpoint.Runtime.open(allocator, io, owned_path, true)
        else
            null;
        errdefer if (compact_runtime) |*runtime| runtime.deinit();
        const store: ?tinykg.storage.Store = if (compact)
            null
        else
            tinykg.storage.Store.openWithOptions(allocator, io, owned_path, writer_store_options) catch |err| switch (err) {
                error.FileNotFound => null,
                else => |e| return e,
            };
        // Writer warmup: publishing the node-text base hash filter here moves
        // an O(store) first-write stall (6s at gb1, 7s+ at gb10 after a
        // rebuild or repair dropped the filter) into daemon startup, before
        // the service accepts writes. Failure is not fatal — the write path
        // re-ensures on demand.
        if (store) |warm_store| warm_store.ensureCurrentNodeTextBaseHashFilter() catch {};
        return .{
            .allocator = allocator,
            .io = io,
            .store_path = owned_path,
            .ownership_lock = acquired_ownership_lock,
            .invocation_environment = invocation_environment,
            .store = store,
            .compact_runtime = compact_runtime,
            .generation = if (compact_runtime) |runtime| runtime.generation() else 0,
        };
    }

    pub fn initReadOnly(
        allocator: std.mem.Allocator,
        io: std.Io,
        store_path: []const u8,
    ) !StoreActor {
        const owned_path = try allocator.dupe(u8, store_path);
        errdefer allocator.free(owned_path);
        var invocation_environment = std.process.Environ.Map.init(allocator);
        errdefer invocation_environment.deinit();
        try invocation_environment.put("TINYKG_STORE", owned_path);
        try invocation_environment.put("TINYKG_DAEMON_INTERNAL", "1");
        tinykg.storage.Store.process_default_crash_recovery.* = false;
        tinykg.storage.Store.process_default_reader_posture.* = true;
        const store = try tinykg.storage.Store.openWithOptions(allocator, io, owned_path, .{
            .crash_recovery = false,
            .allow_stale_full_scan = false,
            .allow_inline_repair = false,
            .serve_stale_snapshot = true,
        });
        return .{
            .allocator = allocator,
            .io = io,
            .store_path = owned_path,
            .ownership_lock = null,
            .invocation_environment = invocation_environment,
            .store = store,
            .compact_runtime = null,
            .read_only = true,
        };
    }

    pub fn deinit(self: *StoreActor) void {
        self.invalidateSessionsAfterCommit();
        self.sessions.deinit(self.allocator);
        for (self.replay.items) |*entry| entry.deinit(self.allocator);
        self.replay.deinit(self.allocator);
        if (self.store) |*store| store.deinit();
        if (self.compact_runtime) |*runtime| runtime.deinit();
        self.invocation_environment.deinit();
        if (self.ownership_lock) |*lock| lock.deinit();
        self.allocator.free(self.store_path);
        self.* = undefined;
    }

    pub fn currentGeneration(self: StoreActor) u64 {
        return self.generation;
    }

    pub fn sessionCount(self: StoreActor) usize {
        return self.sessions.items.len;
    }

    /// Public lifecycle hook for daemon event loops and deterministic tests.
    /// Expiry always deinitializes retained registries before removing entry.
    pub fn expireSessionsAt(self: *StoreActor, now_ms: u64) void {
        self.expireSessions(now_ms);
    }

    /// Self-healing for maintenance debt. The web layer's maintenance tick is
    /// the preferred healer, but a daemon driven by a bare NDJSON client must
    /// not wedge into permanent write failure when the incremental index
    /// refresh falls behind: with inline repair banned from the write path,
    /// nobody else would ever repair. The transport loop calls this after
    /// responses are flushed — the clients that just saw failures are backing
    /// off, and reader processes keep serving their published snapshot while
    /// the repair runs.
    pub fn maintenanceStepIfPending(self: *StoreActor) void {
        if (!self.pending_maintenance or self.read_only) return;
        const store = self.store orelse return;
        // Host-level maintenance gate (opt-in): if another store's O(store)
        // job holds the host lock, keep the debt pending and stay
        // responsive; the next flushed batch retries.
        var host_gate: ?host_maintenance_lock.HostMaintenanceLock = null;
        if (host_maintenance_lock.lockPathFromEnvironment()) |path| {
            host_gate = host_maintenance_lock.HostMaintenanceLock.tryAcquire(self.io, path) catch null;
            if (host_gate == null) return;
        }
        defer if (host_gate) |*gate| gate.deinit();
        store.repairPersistentIndexesFromLog() catch |err| {
            std.log.warn("deferred maintenance step failed: {s}", .{@errorName(err)});
            return;
        };
        // Republish the base hash filter now so the next write does not pay
        // its O(store) rebuild inline.
        store.ensureCurrentNodeTextBaseHashFilter() catch {};
        self.pending_maintenance = false;
        self.generation += 1;
        self.invalidateSessionsAfterCommit();
    }

    pub fn process(self: *StoreActor, request: protocol.Request) !*const protocol.Response {
        try request.validate();
        if (std.mem.eql(u8, request.command, protocol.control_command)) {
            if (request.injectStore or request.args.len != 1) return error.InvalidDaemonControlRequest;
            if (std.mem.eql(u8, request.args[0], protocol.maintenance_step_control)) {
                if (self.pending_maintenance and !self.read_only) {
                    if (self.store) |store| {
                        store.repairPersistentIndexesFromLog() catch |err| {
                            const stderr = try std.fmt.allocPrint(self.allocator, "tinykgd: maintenance step failed: {s}\n", .{@errorName(err)});
                            defer self.allocator.free(stderr);
                            self.control_response = .{
                                .requestId = request.requestId,
                                .ok = false,
                                .code = 1,
                                .stdout = "",
                                .stderr = "",
                                .generation = self.generation,
                                .commitState = .none,
                            };
                            return &self.control_response;
                        };
                        self.pending_maintenance = false;
                        self.generation += 1;
                        self.invalidateSessionsAfterCommit();
                    }
                }
                self.control_response = .{
                    .requestId = request.requestId,
                    .ok = true,
                    .code = 0,
                    .stdout = "",
                    .stderr = "",
                    .generation = self.generation,
                    .commitState = .none,
                };
                return &self.control_response;
            }
            if (!std.mem.eql(u8, request.args[0], protocol.expire_sessions_control)) {
                return error.InvalidDaemonControlRequest;
            }
            self.expireSessions(self.nowMs());
            self.control_response = .{
                .requestId = request.requestId,
                .ok = true,
                .code = 0,
                .stdout = "",
                .stderr = "",
                .generation = self.generation,
                .commitState = .none,
            };
            return &self.control_response;
        }
        const fingerprint = requestFingerprint(request);
        for (self.replay.items) |*entry| {
            if (!std.mem.eql(u8, entry.response.value.requestId, request.requestId)) continue;
            if (entry.fingerprint != fingerprint) return error.RequestIdConflict;
            entry.response.value.replayed = true;
            return &entry.response.value;
        }

        self.expireSessions(self.nowMs());
        const command = try tinykg.cli.parseCommand(request.command);
        // Legacy `store-info --refresh-size` atomically publishes cached size
        // metadata. Compact Runtime already owns an exact in-memory logical
        // denominator, so its refresh is a read-only recursive byte scan.
        const mutates = if (self.compact_runtime != null)
            command != .store_info and command_policy.mutatesDurableState(command, request.args)
        else
            command_policy.mutatesDurableState(command, request.args);
        if (self.read_only) {
            if (mutates) {
                const stderr = try std.fmt.allocPrint(self.allocator, "tinykgd: error: ReadOnlyDaemon\n", .{});
                return self.rememberResponse(fingerprint, .{
                    .requestId = try self.allocator.dupe(u8, request.requestId),
                    .ok = false,
                    .code = 1,
                    .stdout = try self.allocator.dupe(u8, ""),
                    .stderr = stderr,
                    .generation = self.generation,
                    .commitState = .none,
                });
            }
            self.refreshReadOnlyFreshness();
        }
        const execution = self.execute(request, command) catch |err| {
            const stderr = try std.fmt.allocPrint(self.allocator, "tinykgd: error: {s}\n", .{@errorName(err)});
            return self.rememberResponse(fingerprint, .{
                .requestId = try self.allocator.dupe(u8, request.requestId),
                .ok = false,
                .code = 1,
                .stdout = try self.allocator.dupe(u8, ""),
                .stderr = stderr,
                .generation = self.generation,
                .commitState = .none,
            });
        };

        var commitState: protocol.CommitState = .none;
        var post_commit_error: ?anyerror = null;
        if (mutates) {
            self.generation += 1;
            commitState = .committed;
            self.invalidateSessionsAfterCommit();
            if (!execution.direct_mutation) {
                self.refreshStoreAfterWrite() catch |err| {
                    post_commit_error = err;
                };
            }
        }

        const stderr = if (post_commit_error) |err|
            try std.fmt.allocPrint(self.allocator, "tinykgd: post-commit refresh failed: {s}\n", .{@errorName(err)})
        else
            try self.allocator.dupe(u8, "");
        const session_receipt: ?protocol.SessionReceipt = if (!mutates)
            if (execution.session) |session|
                .{
                    .sessionId = try self.allocator.dupe(u8, session.id),
                    .generation = session.generation,
                    .expiresAtMs = session.expires_at_ms,
                }
            else
                null
        else
            null;
        return self.rememberResponse(fingerprint, .{
            .requestId = try self.allocator.dupe(u8, request.requestId),
            .ok = post_commit_error == null,
            .code = if (post_commit_error == null) 0 else 1,
            .stdout = execution.output,
            .stderr = stderr,
            .generation = self.generation,
            .commitState = commitState,
            .session = session_receipt,
        });
    }

    const Execution = struct {
        output: []u8,
        session: ?*const Session = null,
        /// The mutation ran on the resident store handle; the handle stays
        /// current after append, so the post-commit whole-store reopen is
        /// unnecessary (sessions are still invalidated by the caller).
        direct_mutation: bool = false,
    };

    fn execute(self: *StoreActor, request: protocol.Request, command: tinykg.cli.Command) !Execution {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, "tinykgd");
        try argv.append(self.allocator, request.command);
        if (request.injectStore) try argv.append(self.allocator, self.store_path);
        try argv.appendSlice(self.allocator, request.args);

        if (request.injectStore and (command == .query or command == .query_explain)) {
            if (self.compact_runtime) |*runtime| {
                const session = try self.sessionFor(request.sessionId orelse default_session_id, self.nowMs(), null);
                const output = try tinykg.cli.invokeCheckpointQueryAlloc(
                    self.allocator,
                    self.io,
                    runtime,
                    argv.items,
                    command == .query_explain,
                );
                return .{ .output = output, .session = session };
            }
            try self.ensureStoreOpen();
            const session = try self.sessionFor(request.sessionId orelse default_session_id, self.nowMs(), self.store);
            const output = tinykg.cli.invokePersistentQueryCachedAlloc(
                self.allocator,
                self.io,
                self.store.?,
                &session.query.?,
                &session.catalog_cache,
                argv.items,
                command == .query_explain,
            ) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => retry: {
                    session.query.?.deinit();
                    session.query = tinykg.ql.executor.PersistentStoreQuerySession.init(self.allocator, self.store.?);
                    session.catalog_cache.deinit();
                    // Repair writes belong to the single writer; a read-only
                    // actor retries against a fresh snapshot instead.
                    if (!self.read_only) try self.store.?.repairPersistentIndexesFromLog();
                    break :retry try tinykg.cli.invokePersistentQueryCachedAlloc(
                        self.allocator,
                        self.io,
                        self.store.?,
                        &session.query.?,
                        &session.catalog_cache,
                        argv.items,
                        command == .query_explain,
                    );
                },
                else => |e| return e,
            };
            return .{ .output = output, .session = session };
        }

        if (request.injectStore and command == .store_info) {
            if (self.compact_runtime) |*runtime| {
                var refresh = false;
                for (request.args) |arg| {
                    if (std.mem.eql(u8, arg, "--refresh-size")) {
                        if (refresh) return error.InvalidArgument;
                        refresh = true;
                    } else {
                        return error.InvalidArgument;
                    }
                }
                const footprint = if (refresh)
                    try runtime.refreshFootprint()
                else
                    runtime.cachedFootprint();
                return .{ .output = try renderCompactStoreInfo(
                    self.allocator,
                    self.store_path,
                    runtime,
                    footprint,
                    refresh,
                ) };
            }
        }

        if (self.compact_runtime != null) return self.executeCompact(request, command);

        // Point reads run on the resident store handle for the same reason
        // writes do: a per-request whole-store open dominates latency at GB
        // scale. Reads never mutate, so no generation or session concerns.
        if (request.injectStore and (command == .get or command == .get_node)) {
            try self.ensureStoreOpen();
            // A concurrent writer updates several index files non-atomically;
            // a reader can catch the microsecond window between them. Each
            // retry re-reads the index metadata, so a fresh snapshot resolves
            // the transient without any repair write.
            var attempt: usize = 0;
            const read_result = while (true) : (attempt += 1) {
                break tinykg.cli.invokeStoreReadAlloc(
                    self.allocator,
                    self.io,
                    self.store.?,
                    command,
                    argv.items,
                ) catch |err| switch (err) {
                    error.UnsupportedStoreRead => break null,
                    error.InvalidRecord, error.FileNotFound => {
                        if (self.read_only and attempt < 8) continue;
                        return err;
                    },
                    else => |other| return other,
                };
            };
            if (read_result) |value| return .{ .output = value };
        }

        // Concurrency hot path (roadmap P0.5): route the write family through
        // the resident store handle instead of a per-command CLI re-entry
        // that reopens and closes the whole store around every append.
        if (request.injectStore and directMutationSupported(command)) {
            try self.ensureStoreOpen();
            const output = tinykg.cli.invokeStoreMutationAlloc(
                self.allocator,
                self.io,
                self.store.?,
                command,
                argv.items,
            ) catch |err| switch (err) {
                error.UnsupportedStoreMutation => return .{ .output = try tinykg.cli.invokeAlloc(.{
                    .argv = argv.items,
                    .environment = &self.invocation_environment,
                }, self.allocator, self.io) },
                error.InvalidRecord, error.FileNotFound => {
                    self.pending_maintenance = true;
                    return err;
                },
                else => |other| return other,
            };
            return .{ .output = output, .direct_mutation = true };
        }

        return .{ .output = try tinykg.cli.invokeAlloc(.{
            .argv = argv.items,
            .environment = &self.invocation_environment,
        }, self.allocator, self.io) };
    }

    fn directMutationSupported(command: tinykg.cli.Command) bool {
        return switch (command) {
            .add_node,
            .set_property,
            .set_uint_property,
            .set_node_property,
            .set_edge_property,
            .ensure_node,
            .add_edge,
            .task_claim,
            .task_release,
            .task_close,
            .task_event,
            => true,
            else => false,
        };
    }

    /// The reader's sessions must not serve caches from before the writer's
    /// latest commit: any event-log growth invalidates them through the same
    /// generation mechanism a local commit uses. Failure to stat the log is
    /// treated as growth so staleness always fails closed.
    fn refreshReadOnlyFreshness(self: *StoreActor) void {
        const store = self.store orelse return;
        const event_bytes = store.eventByteCount() catch {
            self.generation += 1;
            self.invalidateSessionsAfterCommit();
            return;
        };
        if (event_bytes != self.read_only_seen_event_bytes) {
            self.read_only_seen_event_bytes = event_bytes;
            self.generation += 1;
            self.invalidateSessionsAfterCommit();
        }
    }

    /// True when this request may join a group commit: a direct-mutation
    /// write executed against the resident store. The transport batches runs
    /// of such requests; the group is durable at one shared sync boundary.
    pub fn groupableWrite(self: *StoreActor, request: protocol.Request) bool {
        if (self.read_only) return false;
        if (self.compact_runtime != null) return false;
        if (!request.injectStore) return false;
        request.validate() catch return false;
        if (std.mem.eql(u8, request.command, protocol.control_command)) return false;
        const command = tinykg.cli.parseCommand(request.command) catch return false;
        return directMutationSupported(command);
    }

    /// Group commit: execute a run of groupable writes with buffered
    /// durability, then one shared sync boundary, then acknowledge each in
    /// arrival order. Acknowledged writes are durable at the group boundary;
    /// a sync failure fails every acknowledgement in the group. Replayed
    /// request ids return their remembered responses without re-executing.
    pub fn processGroup(
        self: *StoreActor,
        requests: []const protocol.Request,
        out: *std.Io.Writer,
    ) !void {
        std.debug.assert(requests.len > 0);
        if (requests.len == 1) {
            // remembered responses may be evicted or moved by later inserts,
            // so every response is serialized immediately after creation
            try protocol.writeResponse(out, (try self.process(requests[0])).*);
            return;
        }

        const Pending = struct {
            fingerprint: u64,
            output: ?[]u8,
            err: ?anyerror,
            replayed: ?*const protocol.Response,
        };
        var pending = std.ArrayList(Pending).empty;
        defer pending.deinit(self.allocator);
        try pending.ensureTotalCapacityPrecise(self.allocator, requests.len);

        self.expireSessions(self.nowMs());
        try self.ensureStoreOpen();
        var fast_store = self.store.?;
        fast_store.options.durability = .fast;

        var executed_any = false;
        var argv_storage = std.ArrayList(std.ArrayList([]const u8)).empty;
        defer {
            for (argv_storage.items) |*argv| argv.deinit(self.allocator);
            argv_storage.deinit(self.allocator);
        }
        var batch_request_index = std.ArrayList(usize).empty;
        defer batch_request_index.deinit(self.allocator);

        for (requests, 0..) |request, request_index| {
            try request.validate();
            const fingerprint = requestFingerprint(request);
            var replayed: ?*const protocol.Response = null;
            for (self.replay.items) |*entry| {
                if (!std.mem.eql(u8, entry.response.value.requestId, request.requestId)) continue;
                if (entry.fingerprint != fingerprint) return error.RequestIdConflict;
                entry.response.value.replayed = true;
                replayed = &entry.response.value;
                break;
            }
            if (replayed != null) {
                pending.appendAssumeCapacity(.{ .fingerprint = fingerprint, .output = null, .err = null, .replayed = replayed });
                continue;
            }
            pending.appendAssumeCapacity(.{ .fingerprint = fingerprint, .output = null, .err = null, .replayed = null });
            const command = tinykg.cli.parseCommand(request.command) catch |err| {
                pending.items[pending.items.len - 1].err = err;
                continue;
            };
            var argv: std.ArrayList([]const u8) = .empty;
            errdefer argv.deinit(self.allocator);
            try argv.append(self.allocator, "tinykgd");
            try argv.append(self.allocator, request.command);
            try argv.append(self.allocator, self.store_path);
            try argv.appendSlice(self.allocator, request.args);
            if (command == .add_node) {
                try argv_storage.append(self.allocator, argv);
                try batch_request_index.append(self.allocator, request_index);
            } else {
                defer argv.deinit(self.allocator);
                if (tinykg.cli.invokeStoreMutationAlloc(self.allocator, self.io, fast_store, command, argv.items)) |output| {
                    executed_any = true;
                    pending.items[pending.items.len - 1].output = output;
                } else |err| {
                    if (err == error.InvalidRecord or err == error.FileNotFound) self.pending_maintenance = true;
                    pending.items[pending.items.len - 1].err = err;
                }
            }
        }

        if (batch_request_index.items.len != 0) {
            var batch_args = std.ArrayList([]const []const u8).empty;
            defer batch_args.deinit(self.allocator);
            try batch_args.ensureTotalCapacityPrecise(self.allocator, argv_storage.items.len);
            for (argv_storage.items) |argv| batch_args.appendAssumeCapacity(argv.items);

            var outputs = std.ArrayList(?[]u8).empty;
            defer outputs.deinit(self.allocator);
            var batch_failures = std.ArrayList(?anyerror).empty;
            defer batch_failures.deinit(self.allocator);
            if (tinykg.cli.invokeAddNodeGroupAlloc(self.allocator, self.io, fast_store, batch_args.items, &outputs, &batch_failures)) {
                for (batch_request_index.items, 0..) |request_index, batch_slot| {
                    if (outputs.items[batch_slot]) |output| {
                        executed_any = true;
                        pending.items[request_index].output = output;
                    } else {
                        pending.items[request_index].err = batch_failures.items[batch_slot] orelse error.InvalidRecord;
                    }
                }
            } else |err| {
                self.pending_maintenance = true;
                // The group failure reason drives the deferred repair; keep
                // its origin visible for operators (release builds print the
                // name, debug builds add the return trace).
                std.log.warn("add-node group failed, deferring maintenance: {s}", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
                for (batch_request_index.items) |request_index| {
                    pending.items[request_index].err = err;
                }
            }
        }

        var sync_error: ?anyerror = null;
        if (executed_any) {
            self.store.?.syncDurableAppendSurfaces() catch |err| {
                sync_error = err;
            };
            self.generation += 1;
            self.invalidateSessionsAfterCommit();
        }

        for (requests, pending.items) |request, entry| {
            if (entry.replayed) |response| {
                try protocol.writeResponse(out, response.*);
                continue;
            }
            const entry_failure: ?anyerror = entry.err orelse sync_error;
            if (entry_failure) |err| {
                if (entry.output) |output| self.allocator.free(output);
                const stderr = try std.fmt.allocPrint(self.allocator, "tinykgd: error: {s}\n", .{@errorName(err)});
                const failed = try self.rememberResponse(entry.fingerprint, .{
                    .requestId = try self.allocator.dupe(u8, request.requestId),
                    .ok = false,
                    .code = 1,
                    .stdout = try self.allocator.dupe(u8, ""),
                    .stderr = stderr,
                    .generation = self.generation,
                    .commitState = if (entry.err == null) .ambiguous else .none,
                });
                try protocol.writeResponse(out, failed.*);
                continue;
            }
            const committed = try self.rememberResponse(entry.fingerprint, .{
                .requestId = try self.allocator.dupe(u8, request.requestId),
                .ok = true,
                .code = 0,
                .stdout = entry.output.?,
                .stderr = try self.allocator.dupe(u8, ""),
                .generation = self.generation,
                .commitState = .committed,
            });
            try protocol.writeResponse(out, committed.*);
        }
    }

    fn executeCompact(self: *StoreActor, request: protocol.Request, command: tinykg.cli.Command) !Execution {
        if (compact_commands.supports(command)) {
            const result = try compact_commands.execute(
                self.allocator,
                self.io,
                &self.compact_runtime.?,
                command,
                request.args,
            );
            if (result.mutated != command_policy.mutatesDurableState(command, request.args)) {
                self.allocator.free(result.output);
                return error.CompactMutationPolicyMismatch;
            }
            return .{ .output = result.output };
        }
        if (command_policy.mutatesDurableState(command, request.args)) return error.UnsupportedCompactMutation;
        return error.UnsupportedCompactCommand;
    }

    /// Write-path opens keep crash recovery (the writer owns it) but defer
    /// full repairs to the maintenance scheduler.
    const writer_store_options = tinykg.storage.StorageOptions{ .allow_inline_repair = false };

    fn ensureStoreOpen(self: *StoreActor) !void {
        if (self.store == null) self.store = try tinykg.storage.Store.openWithOptions(self.allocator, self.io, self.store_path, writer_store_options);
    }

    fn refreshStoreAfterWrite(self: *StoreActor) !void {
        if (self.compact_runtime != null) return;
        if (self.store) |*store| store.deinit();
        self.store = null;
        self.store = tinykg.storage.Store.openWithOptions(self.allocator, self.io, self.store_path, writer_store_options) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| return e,
        };
    }

    fn sessionFor(self: *StoreActor, id: []const u8, now_ms: u64, store: ?tinykg.storage.Store) !*Session {
        for (self.sessions.items) |*session| {
            if (!std.mem.eql(u8, session.id, id)) continue;
            if (session.generation != self.generation) {
                if (session.query) |*query| query.deinit();
                session.query = if (store) |value| tinykg.ql.executor.PersistentStoreQuerySession.init(self.allocator, value) else null;
                session.generation = self.generation;
            }
            session.expires_at_ms = std.math.add(u64, now_ms, session_ttl_ms) catch std.math.maxInt(u64);
            return session;
        }
        if (self.sessions.items.len >= protocol.queue_capacity) return error.DaemonQueueFull;
        try self.sessions.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, id),
            .generation = self.generation,
            .expires_at_ms = std.math.add(u64, now_ms, session_ttl_ms) catch std.math.maxInt(u64),
            .query = if (store) |value| tinykg.ql.executor.PersistentStoreQuerySession.init(self.allocator, value) else null,
        });
        return &self.sessions.items[self.sessions.items.len - 1];
    }

    fn expireSessions(self: *StoreActor, now_ms: u64) void {
        var index = self.sessions.items.len;
        while (index > 0) {
            index -= 1;
            if (self.sessions.items[index].expires_at_ms > now_ms) continue;
            var session = self.sessions.orderedRemove(index);
            session.deinit(self.allocator);
        }
    }

    fn invalidateSessionsAfterCommit(self: *StoreActor) void {
        for (self.sessions.items) |*session| session.deinit(self.allocator);
        self.sessions.clearRetainingCapacity();
    }

    fn rememberResponse(
        self: *StoreActor,
        fingerprint: u64,
        value: protocol.Response,
    ) !*const protocol.Response {
        if (self.replay.items.len >= replay_capacity) {
            var oldest = self.replay.orderedRemove(0);
            oldest.deinit(self.allocator);
        }
        errdefer {
            var owned = OwnedResponse{ .value = value };
            owned.deinit(self.allocator);
        }
        try self.replay.append(self.allocator, .{
            .fingerprint = fingerprint,
            .response = .{ .value = value },
        });
        return &self.replay.items[self.replay.items.len - 1].response.value;
    }

    fn nowMs(self: StoreActor) u64 {
        const timestamp = std.Io.Clock.awake.now(self.io).nanoseconds;
        const ns: u128 = if (timestamp < 0) 0 else @intCast(timestamp);
        return @intCast(@min(ns / std.time.ns_per_ms, std.math.maxInt(u64)));
    }
};

fn renderCompactStoreInfo(
    allocator: std.mem.Allocator,
    store_path: []const u8,
    runtime: *const tinykg.checkpoint.Runtime,
    footprint: tinykg.checkpoint.Footprint,
    refreshed: bool,
) ![]u8 {
    const snapshot = runtime.loaded.checkpoint.snapshot;
    const logical = runtime.cachedLogicalBreakdown();
    const recovery = runtime.startupRecovery();
    const ratio_scale: u128 = 1_000_000;
    const ratio_scaled = (@as(u128, footprint.logical_content_bytes) * ratio_scale) /
        footprint.total_operational_bytes;
    const amplification_scaled = (@as(u128, footprint.total_operational_bytes) * ratio_scale) /
        footprint.logical_content_bytes;
    return std.fmt.allocPrint(
        allocator,
        "db={s}\nnodes={}\nedges={}\nlogical_content_bytes={}\nlogical_node_text_bytes={}\nlogical_property_value_bytes={}\nlogical_edge_bytes={}\nlogical_property_count={}\nlogical_accounting_version=1\nphysical_bytes={}\nstore_dir_bytes={}\nstore_size_state={s}\nstore_regular_files={}\nstore_size_generation={}\nstore_size_refreshed_ns=0\ncompression_ratio={d}.{d:0>6}\nstorage_amplification={d}.{d:0>6}\ntext_warm=1\ntext_files_present=0\ntext_current=1\ntext_stale=0\nstore_manifest=ready\nstorage_format_version=checkpoint-{}\nschema_version=3\nenabled_profiles=checkpoint-canonical\ntext_docs_exists=0\ntext_terms_exists=0\ntext_postings_exists=0\ntext_docs_bytes=0\ntext_terms_bytes=0\ntext_postings_bytes=0\ncompact_repository=1\ncompact_under_twenty_percent={}\ncompact_current_checkpoint_bytes={}\ncompact_current_wal_bytes={}\ncompact_current_pointer_bytes={}\ncompact_obsolete_checkpoint_bytes={}\ncompact_obsolete_wal_bytes={}\ncompact_temporary_bytes={}\ncompact_derived_disk_cache_bytes={}\ncompact_unknown_regular_bytes={}\ncompact_startup_wal_truncated_bytes={}\ncompact_startup_gc_checkpoint_files={}\ncompact_startup_gc_wal_files={}\ncompact_startup_gc_temporary_files={}\ncompact_startup_gc_bytes={}\n",
        .{
            store_path,
            snapshot.nodes.len,
            snapshot.edges.len,
            footprint.logical_content_bytes,
            logical.node_text_bytes,
            logical.property_value_bytes,
            logical.edge_bytes,
            logical.property_count,
            footprint.total_operational_bytes,
            footprint.total_operational_bytes,
            if (refreshed) "refreshed" else "cached",
            footprint.regular_files,
            runtime.generation(),
            ratio_scaled / ratio_scale,
            ratio_scaled % ratio_scale,
            amplification_scaled / ratio_scale,
            amplification_scaled % ratio_scale,
            tinykg.checkpoint.current_format_version,
            @intFromBool(footprint.underTwentyPercent()),
            footprint.current_checkpoint_bytes,
            footprint.current_wal_bytes,
            footprint.current_pointer_bytes,
            footprint.obsolete_checkpoint_bytes,
            footprint.obsolete_wal_bytes,
            footprint.temporary_bytes,
            footprint.derived_disk_cache_bytes,
            footprint.unknown_regular_bytes,
            runtime.startupWalTruncatedBytes(),
            recovery.deleted_checkpoint_files,
            recovery.deleted_wal_files,
            recovery.deleted_temporary_files,
            recovery.deleted_bytes,
        },
    );
}

fn compactRepositoryPresent(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ directory, tinykg.checkpoint.current_leaf });
    defer allocator.free(path);
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |other| return other,
    };
    if (stat.kind != .file) return error.InvalidRecord;
    return true;
}

fn requestFingerprint(request: protocol.Request) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(request.command);
    hash.update(&.{@intFromBool(request.injectStore)});
    if (request.sessionId) |session_id| hash.update(session_id);
    if (request.contentDigest) |content_digest| {
        hash.update(&.{1});
        hash.update(content_digest);
    }
    for (request.args) |arg| {
        hash.update(&.{0});
        hash.update(arg);
    }
    return hash.final();
}

test "daemon request fingerprint binds identity to command and arguments" {
    const left = protocol.Request{
        .protocolVersion = protocol.protocol_version,
        .requestId = "same",
        .command = "stats",
    };
    const right = protocol.Request{
        .protocolVersion = protocol.protocol_version,
        .requestId = "same",
        .command = "get",
        .args = &.{"1"},
    };
    try std.testing.expect(requestFingerprint(left) != requestFingerprint(right));
}

test "daemon request fingerprint binds non-argv uploaded content" {
    const left = protocol.Request{
        .protocolVersion = protocol.protocol_version,
        .requestId = "same",
        .command = "import-md-doc",
        .args = &.{"stable.md"},
        .contentDigest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
    const right = protocol.Request{
        .protocolVersion = protocol.protocol_version,
        .requestId = "same",
        .command = "import-md-doc",
        .args = &.{"stable.md"},
        .contentDigest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    };
    try std.testing.expect(requestFingerprint(left) != requestFingerprint(right));
}

// The actor owns the adjacent `.tinykg-daemon.lock`; all CLI work re-enters
// with TINYKG_DAEMON_INTERNAL=1, while external commands fail with
// error.DaemonAlreadyOwnsStore before acquiring their ordinary CLI lock.
