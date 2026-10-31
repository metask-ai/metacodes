//! **daemon serve-multi(U10-C,#254)** —— `metacodes serve --sessions N [--max-sessions M] [port]`:
//! 常驻进程宿主多个独立 session,经 WebServer resolver 按路径 `/s/<id>/*` 路由到对应 session,
//! 并在顶层提供动态生命周期(`GET /sessions`、`POST /sessions/create`、`POST /sessions/<id>/resume`、
//! `POST /sessions/<id>/destroy`)。N 个 session 在 transport 起来之前建好(N 可为 0);之后按需创建
//! 与销毁,活跃 session 数以 M 为上限。
//!
//! **Leases, not borrowed snapshots.** A session is a heap `SessionSlot` with
//! an atomic `refs` and a `state` (live / closing / closed). The table maps
//! the ids of live slots to them under `mutex`; `resolve` takes a lease there
//! (`refs += 1`) and the transport gives it back exactly once (`Lease.release`),
//! after the request — after the whole SSE stream, after a whole UDS attach.
//! `destroy` takes the slot out of the table, marks it closing and puts it on
//! the retired list under the mutex: it can no longer be resolved, and its id
//! is refused to a create (409 "session is still closing") until it is reaped,
//! because its App still owns the session directory. Then, outside the mutex,
//! it stops and joins the driver (abort interrupts an in-flight run, see
//! app_driver.abortFn) and the session's background work (agent jobs,
//! teammates, background shells: `App.stopBackgroundWork`), appends
//! `session_lifecycle.closed` and closes the journal, which ends every SSE
//! stream and attachment so their leases come back, and marks it closed.
//! Destroy stops the work at once and never waits for leases (a lease API that
//! blocks close on user refs once turned a failed assertion into a ten-minute
//! hang). The memory a lease holder may still touch — journal, backend,
//! queues, the App behind `/state`, its abort signal — is freed by `reap`, on
//! the daemon's main loop, once a closed slot's `refs` is 0; releasing never
//! tears anything down itself.
//!
//! **每 App 独立 io_runtime,分配走通用分配器**(设计 §5):
//! - 分配器:新建 session 的 App 用 c_allocator(线程安全)。不用 arena:arena 什么都不释放,一个
//!   session 每次请求、每个工具结果都留在内存里直到关停,常驻 daemon 会无限增长。
//! - io_runtime:对齐 agent_job_registry「每 job 独立 Client + 独立 std.Io.Threaded」的**已证并发模式**
//!   (共享 App io_runtime 跨线程是 agent_job_registry:401 标注的未证风险)。
//! - App construction and teardown are serialized (`build_mutex`): App.init
//!   and App.deinit read and write process state (cwd, environment, child
//!   processes), and an HTTP create may run beside the reaper.
//!
//! **The App main built.** With N ≥ 1 the first session adopts it (its io is
//! main's; it is freed like any other session, when destroyed or at
//! shutdown). With N = 0 nothing adopts it and `start` frees it at once, so
//! its MCP/LSP children do not outlive their use; every session created later
//! builds its own App. Either way SIGINT no longer points at its abort signal
//! (`App.detachSigintAbort`): SIGINT only requests shutdown, and shutdown
//! aborts every session itself.
//!
//! **关停顺序**:① 置 shutting_down(不再创建)并把所有 live slot 移出表 ② 每个 slot 停 driver 并 join,
//! 写 closed、close journal ③ srv.stop / uds.stop:drain 所有连接 → 所有 lease 归还 ④ reap 全部。
//! App.deinit join 后台 subagent/swarm/LSP/MCP + 关 api_client,故必在 driver join 之后、io_runtime.deinit
//! 之前(freeSlot 的顺序)。

const std = @import("std");
const sync = @import("platform").sync;
const pfs = @import("platform").fs;
const app_mod = @import("../app.zig");
const types = @import("../types.zig");
const time = @import("../util/time.zig");
const log = @import("../util/log.zig");
const util_fs = @import("../util/fs.zig");
const abort_mod = @import("../util/abort.zig");
const registry = @import("registry.zig");
const app_driver = @import("app_driver.zig");
const shutdown = @import("../core/shutdown.zig");
const transcript = @import("../core/transcript.zig");
const session_id_mod = @import("../core/session_id.zig");
const EventJournal = @import("../core/event_journal.zig").EventJournal;
const SubmissionQueue = @import("../web/submission.zig").SubmissionQueue;
const web_session = @import("../web/session.zig");
const server_mod = @import("../web/server.zig");
const WebBackend = @import("../web/backend.zig").WebBackend;
const WebServer = server_mod.WebServer;
const SessionView = server_mod.SessionView;
const UdsServer = @import("uds.zig").UdsServer;

const SessionHost = registry.SessionHost;
const SessionId = session_id_mod.SessionId;
const CreateError = server_mod.CreateError;

/// `--max-sessions` when not given. Each live session holds a driver thread,
/// an io runtime with its own worker threads, its App (MCP servers, language
/// servers, the TinyKG client) and a bounded journal; the HTTP server serves
/// at most `server.MAX_CONNS` (64) connections, so 32 sessions with one SSE
/// stream each leave half of them for requests.
pub const DEFAULT_MAX_SESSIONS: usize = 32;

pub const Options = struct {
    /// Sessions created before the transports start (`--sessions N`).
    initial: usize,
    /// Live sessions at most (`--max-sessions M`); a create beyond it is
    /// refused (429). At least 1 and at least `initial`.
    max_sessions: usize = DEFAULT_MAX_SESSIONS,
    surface: server_mod.Surface,
    /// An additional UDS + NDJSON binding (U10-B).
    uds_path: ?[]const u8 = null,
};

/// 一个 session 的全部宿主资源。堆分配 → 地址稳:&slot.wb / &slot.dctx / &slot.state_src 被
/// WebServer/host 跨线程引用。
const SessionSlot = struct {
    id: SessionId,
    /// What App.init reads as `config.session_id`; the App keeps the slice.
    id_text: [24]u8,
    /// null = the App main built (adopted at startup): its io is main's.
    io_rt: ?*std.Io.Threaded,
    app: *app_mod.App,
    /// host/wb/hooks are set up (`wire`); teardown skips them otherwise.
    wired: bool = false,
    host: *SessionHost = undefined,
    wb: WebBackend = undefined,
    config_sink: web_session.WebConfigSink = undefined,
    dctx: app_driver.DriverCtx = undefined,
    /// U11:per-session rich /state + /command 数据源。
    state_src: web_session.StateSource = undefined,
    /// Leases out. Taken only from the table under `MultiDaemon.mutex`, so a
    /// slot that has left the table never gains one; `reap` frees it at 0.
    refs: std.atomic.Value(usize) = .init(0),
    /// Guarded by `MultiDaemon.mutex`. A live slot is in the table; a closing
    /// or closed one is on the retired list (and its id is refused to a
    /// create) until it is reaped.
    state: State = .live,
    /// The retired list's link (guarded by `MultiDaemon.mutex`).
    next_retired: ?*SessionSlot = null,
    /// `stop`'s own list of the slots it took from the table (only `stop`'s
    /// thread touches it).
    next_stopping: ?*SessionSlot = null,

    const State = enum {
        /// In the table; leases can be taken.
        live,
        /// Out of the table; the destroying thread is stopping its driver
        /// and background work. Not reapable.
        closing,
        /// Stopped and its journal closed; freed by `reap` at `refs == 0`.
        closed,
    };

    fn view(slot: *SessionSlot) SessionView {
        return .{
            .journal = &slot.host.journal,
            .web_backend = &slot.wb,
            .inbox = &slot.host.inbox,
            .abort = &slot.app.abort,
            .generating = &slot.host.generating, // S1:/interrupt 生成期门(driver 维护)
            // U11:rich /state + /command(与 --web 同一份实现;命令 HTTP 线程只入 host.cmdbox)。
            .state_ctx = @ptrCast(&slot.state_src),
            .state_fn = &web_session.StateSource.snapshot,
            .command_fn = &web_session.StateSource.command,
            .spans_fn = &web_session.StateSource.spans,
        };
    }
};

/// What `server.Deps` requires for its single-session fields. Never read:
/// with a resolver every session path is leased (`WebServer.singleView`
/// asserts it). Real objects all the same, so a mistake cannot read garbage.
const Placeholder = struct {
    journal: EventJournal,
    wb: WebBackend,
    inbox: SubmissionQueue,
    abort: abort_mod.AbortSignal,
};

/// Counters a test reads to tell "not freed while leased" from "freed after
/// the last release" without relying on a crash.
pub const Stats = struct {
    /// Live sessions (what `GET /health` reports).
    live: usize,
    /// Drivers stopped and joined by a destroy or the shutdown.
    drivers_joined: usize,
    /// Destroyed sessions whose memory has been freed.
    reaped: usize,
    /// Destroyed sessions not reaped yet: being stopped, or waiting for
    /// their last lease.
    retired: usize,
};

pub const MultiDaemon = struct {
    gpa: std.mem.Allocator,
    /// Every session's App is built from this (`session_id` set per slot).
    config: types.Config,
    api_key: []const u8,
    max_sessions: usize,
    /// The state root sessions persist under (owned): the one main's App
    /// resolved, so a transcript check looks where the App will write.
    state_root: []const u8,

    /// Guards `table`, `reserved`, `retired`, `shutting_down` and every
    /// slot's `state` and `next_retired`. Never held across a join, an
    /// App.init or an App.deinit.
    mutex: sync.Mutex = .{},
    table: std.AutoHashMapUnmanaged([24]u8, *SessionSlot) = .empty,
    /// Ids of creates in progress: counted against the cap, refused as
    /// duplicates.
    reserved: std.AutoHashMapUnmanaged([24]u8, void) = .empty,
    retired: ?*SessionSlot = null,
    shutting_down: bool = false,
    /// Serializes App construction (create) with App teardown (reap).
    build_mutex: sync.Mutex = .{},

    /// Live sessions: `GET /health` reads it without resolving anything.
    live: std.atomic.Value(usize) = .init(0),
    drivers_joined: std.atomic.Value(usize) = .init(0),
    reaped: std.atomic.Value(usize) = .init(0),

    placeholder: Placeholder = undefined,
    srv: ?*WebServer = null,
    uds: ?*UdsServer = null,
    /// False once a transport's stop left a connection thread running.
    transports_drained: bool = true,

    /// Build the daemon: the first `options.initial` sessions (the first one
    /// adopting `app0`), then the HTTP server and the optional UDS binding.
    /// Takes ownership of `app0` in every case, success or error. `gpa` must
    /// be thread-safe. `config`'s strings must outlive the daemon.
    pub fn start(gpa: std.mem.Allocator, app0: ?*app_mod.App, config: types.Config, api_key: []const u8, options: Options) !*MultiDaemon {
        std.debug.assert(options.max_sessions >= 1 and options.initial <= options.max_sessions);
        // Long before the App can be freed: a handler that loaded the pointer
        // must never write into a freed App.
        if (app0) |app| app.detachSigintAbort();
        var unowned_app0 = app0;
        errdefer if (unowned_app0) |app| releaseMainApp(app);

        const md = try gpa.create(MultiDaemon);
        const state_root = gpa.dupe(u8, if (app0) |app| app.stateRoot() else config.state_root) catch |err| {
            gpa.destroy(md);
            return err;
        };
        md.* = .{
            .gpa = gpa,
            .config = config,
            .api_key = api_key,
            .max_sessions = options.max_sessions,
            .state_root = state_root,
        };
        md.config.state_root = md.state_root;
        md.config.session_id = null;
        md.placeholder = .{
            .journal = EventJournal.init(gpa),
            .wb = undefined,
            .inbox = SubmissionQueue.init(gpa),
            .abort = abort_mod.AbortSignal.init(),
        };
        md.placeholder.wb = WebBackend.init(gpa, &md.placeholder.journal);
        md.placeholder.journal.close();
        // From here `stop` + `destroy` undo everything, whatever was built.
        errdefer {
            md.stop();
            md.destroy();
        }

        if (unowned_app0) |app| {
            unowned_app0 = null;
            if (options.initial > 0) {
                try md.adopt(app);
            } else {
                releaseMainApp(app); // --sessions 0: no session adopts it
            }
        }
        while (md.live.load(.acquire) < options.initial) _ = try md.createSession(.{ .fresh = null });

        md.srv = try WebServer.start(gpa, options.surface, .{
            .journal = &md.placeholder.journal,
            .web_backend = &md.placeholder.wb,
            .inbox = &md.placeholder.inbox,
            .abort = &md.placeholder.abort,
            .state_ctx = @ptrCast(md),
            .state_fn = &placeholderState,
            .resolver = .{ .resolve = &resolveLease, .ctx = @ptrCast(md), .sessions = &md.live },
            .lifecycle = .{
                .ctx = @ptrCast(md),
                .max_sessions = md.max_sessions,
                .create = &createThunk,
                .is_live = &isLiveThunk,
                .destroy = &destroyThunk,
                .list = &listThunk,
            },
            .root_fn = &rootPage, // GET / → 诚实落地页(列 session id + API),非死 SPA(PM M1)
            .root_ctx = @ptrCast(md),
        });

        if (options.uds_path) |path| {
            md.uds = UdsServer.start(gpa, path, .{
                .allocator = gpa,
                .resolver = &resolveLease,
                .resolver_ctx = @ptrCast(md),
                .list_fn = &udsList,
                .list_ctx = @ptrCast(md),
            }) catch |err| blk: {
                // UDS 起不来(路径太长/权限)不致命:web 仍服务,记 warn 继续。
                log.warn("daemon", "UDS bind {s} failed: {s}; web-only", .{ path, @errorName(err) });
                break :blk null;
            };
            if (md.uds != null) {
                std.debug.print("metacodes daemon UDS: {s}\n", .{path});
                log.info("daemon", "serve-multi UDS listening on {s}", .{path});
            }
        }
        return md;
    }

    /// The port the HTTP server bound.
    pub fn port(md: *const MultiDaemon) u16 {
        return md.srv.?.port;
    }

    /// Lease a live session by id, exactly as the transports do; null when
    /// unknown or being destroyed. The caller releases it.
    pub fn resolve(md: *MultiDaemon, id_text: []const u8) ?server_mod.Lease {
        return resolveLease(@ptrCast(md), id_text);
    }

    /// Leases out on the session `id`, live or destroyed but not yet reaped;
    /// null once it is gone (or never existed).
    pub fn leasesOf(md: *MultiDaemon, id: SessionId) ?usize {
        md.mutex.lock();
        defer md.mutex.unlock();
        if (md.table.get(id.bytes)) |slot| return slot.refs.load(.acquire);
        var slot = md.retired;
        while (slot) |s| : (slot = s.next_retired) {
            if (std.mem.eql(u8, &s.id.bytes, &id.bytes)) return s.refs.load(.acquire);
        }
        return null;
    }

    pub fn stats(md: *MultiDaemon) Stats {
        md.mutex.lock();
        defer md.mutex.unlock();
        var retired: usize = 0;
        var slot = md.retired;
        while (slot) |s| : (slot = s.next_retired) retired += 1;
        return .{
            .live = md.live.load(.acquire),
            .drivers_joined = md.drivers_joined.load(.acquire),
            .reaped = md.reaped.load(.acquire),
            .retired = retired,
        };
    }

    /// Free every destroyed session whose last lease is back. The daemon's
    /// main loop calls this every tick; it never waits for a lease.
    pub fn reap(md: *MultiDaemon) void {
        {
            md.mutex.lock();
            defer md.mutex.unlock();
            if (md.retired == null) return;
        }
        md.build_mutex.lock();
        defer md.build_mutex.unlock();
        var ready: ?*SessionSlot = null;
        {
            md.mutex.lock();
            defer md.mutex.unlock();
            var link: *?*SessionSlot = &md.retired;
            while (link.*) |slot| {
                std.debug.assert(slot.state != .live);
                // A closing slot still belongs to the thread stopping it.
                if (slot.state == .closed and slot.refs.load(.acquire) == 0) {
                    link.* = slot.next_retired;
                    slot.next_retired = ready;
                    ready = slot;
                } else {
                    link = &slot.next_retired;
                }
            }
        }
        while (ready) |slot| {
            ready = slot.next_retired;
            log.info("daemon", "session {s} reaped", .{slot.id.asSlice()});
            md.freeSlot(slot);
            _ = md.reaped.fetchAdd(1, .acq_rel);
        }
    }

    /// Shut down: no session is created from here on; every live session is
    /// stopped and closed, the transports drain every connection (so every
    /// lease comes back), and everything is reaped. Idempotent.
    pub fn stop(md: *MultiDaemon) void {
        var stopping: ?*SessionSlot = null;
        {
            md.mutex.lock();
            defer md.mutex.unlock();
            md.shutting_down = true;
            var it = md.table.valueIterator();
            while (it.next()) |entry| {
                const slot = entry.*;
                md.unpublishLocked(slot);
                slot.next_stopping = stopping;
                stopping = slot;
            }
            md.table.clearRetainingCapacity();
        }
        // Every driver winds down at once; each join below is then short.
        var slot = stopping;
        while (slot) |s| : (slot = s.next_stopping) s.host.signalStop();
        while (stopping) |s| {
            stopping = s.next_stopping;
            md.retire(s);
        }
        if (md.srv) |srv| {
            if (!srv.stopDrained()) md.transports_drained = false;
        }
        md.srv = null;
        if (md.uds) |uds| {
            if (!uds.stopDrained()) md.transports_drained = false;
        }
        md.uds = null;
        md.reap();
        if (md.stats().retired > 0) {
            // Only when a transport left a connection thread running: it may still
            // hold a lease, so that session's memory is left alone.
            log.warn("daemon", "stop: a destroyed session is still leased after the transports stopped; leaking it", .{});
        }
    }

    /// Free the daemon itself, after `stop`. When a transport left a
    /// connection thread running (a hung peer, or a create still inside a
    /// slow App.init after the 12 s drain), the daemon is leaked instead: that
    /// thread may still call into it.
    pub fn destroy(md: *MultiDaemon) void {
        std.debug.assert(md.srv == null and md.uds == null and md.table.count() == 0);
        if (!md.transports_drained or md.retired != null) return;
        const gpa = md.gpa;
        md.table.deinit(gpa);
        md.reserved.deinit(gpa);
        md.placeholder.wb.deinit();
        md.placeholder.inbox.deinit();
        md.placeholder.journal.deinit();
        gpa.free(md.state_root);
        gpa.destroy(md);
    }

    // ── lifecycle ────────────────────────────────────────────────────────────

    /// Create a session (`POST /sessions/create`, and the startup sessions).
    /// A refused request leaves nothing behind: no App, no session directory.
    fn createSession(md: *MultiDaemon, request: server_mod.CreateRequest) CreateError!server_mod.Created {
        const id: SessionId, const restore: bool = switch (request) {
            .fresh => |wanted| .{ wanted orelse session_id_mod.gen(), false },
            .restore => |wanted| .{ wanted, true },
        };
        try md.reserve(id);
        defer md.unreserve(id);

        md.build_mutex.lock();
        defer md.build_mutex.unlock();
        const persisted = md.hasTranscript(id);
        if (restore and !persisted) return error.TranscriptNotFound;
        // A fresh conversation would be appended to, or overwrite, the
        // persisted one: restoring it is the caller's explicit choice.
        if (!restore and persisted) return error.TranscriptExists;

        const slot = md.buildSlot(id) catch |err| {
            log.err("daemon", "session {s}: App construction failed: {s}", .{ id.asSlice(), @errorName(err) });
            return error.CreateFailed;
        };
        var messages: usize = 0;
        if (restore) {
            const resumed = slot.app.resumePersistedConversation() catch |err| {
                log.err("daemon", "session {s}: restoring the transcript failed: {s}", .{ id.asSlice(), @errorName(err) });
                md.freeSlot(slot);
                return if (err == error.TranscriptNotFound) error.TranscriptNotFound else error.RestoreFailed;
            };
            messages = resumed.messages;
        }
        md.wire(slot) catch |err| {
            log.err("daemon", "session {s}: driver start failed: {s}", .{ id.asSlice(), @errorName(err) });
            md.freeSlot(slot);
            return error.CreateFailed;
        };
        md.publish(slot) catch |err| {
            md.freeSlot(slot);
            return err;
        };
        if (restore) {
            std.debug.print("session {s} ready ({d} messages restored)\n", .{ id.asSlice(), messages });
        } else {
            std.debug.print("session {s} ready\n", .{id.asSlice()});
        }
        log.info("daemon", "session {s} ready ({d} messages restored)", .{ id.asSlice(), messages });
        return .{ .id = id, .messages = messages };
    }

    /// The first startup session runs on the App main built. Consumes `app`:
    /// on error it is released here.
    fn adopt(md: *MultiDaemon, app: *app_mod.App) CreateError!void {
        const id = app.session_id;
        md.reserve(id) catch |err| {
            releaseMainApp(app);
            return err;
        };
        defer md.unreserve(id);
        md.build_mutex.lock();
        defer md.build_mutex.unlock();
        const slot = md.gpa.create(SessionSlot) catch {
            releaseMainApp(app);
            return error.CreateFailed;
        };
        slot.* = .{ .id = id, .id_text = id.bytes, .io_rt = null, .app = app };
        md.wire(slot) catch {
            md.freeSlot(slot);
            return error.CreateFailed;
        };
        md.publish(slot) catch |err| {
            md.freeSlot(slot);
            return err;
        };
        std.debug.print("session {s} ready\n", .{id.asSlice()});
        log.info("daemon", "session {s} ready", .{id.asSlice()});
    }

    /// Destroy a live session (`POST /sessions/<id>/destroy`). Returns once
    /// its driver has been joined; never waits for a lease.
    fn destroySession(md: *MultiDaemon, id: SessionId) server_mod.DestroyError!void {
        const slot = slot: {
            md.mutex.lock();
            defer md.mutex.unlock();
            const entry = md.table.fetchRemove(id.bytes) orelse return error.UnknownSession;
            md.unpublishLocked(entry.value);
            break :slot entry.value;
        };
        md.retire(slot);
    }

    /// A slot leaves the live set (the caller takes it out of the table):
    /// closing, on the retired list at once, so its id is refused to a create
    /// for the whole stop and until it is reaped. Caller holds `mutex`.
    fn unpublishLocked(md: *MultiDaemon, slot: *SessionSlot) void {
        std.debug.assert(slot.state == .live);
        slot.state = .closing;
        slot.next_retired = md.retired;
        md.retired = slot;
        _ = md.live.fetchSub(1, .acq_rel);
    }

    /// A closing slot: stop and join its driver and its background work,
    /// close its journal (after `session_lifecycle.closed`, so a stream sees
    /// the run end and then the session close), and hand it to the reaper.
    fn retire(md: *MultiDaemon, slot: *SessionSlot) void {
        slot.host.stopDriver();
        // Then the work the driver started beside itself: background agent
        // jobs, teammates, background shells. They write into the session
        // directory, and a destroy stops the session's work at once; only its
        // memory waits for the last lease.
        slot.app.stopBackgroundWork();
        _ = md.drivers_joined.fetchAdd(1, .acq_rel);
        web_session.journalSessionLifecycle(&slot.host.journal, md.gpa, .{ .closed = slot.id.asSlice() });
        slot.host.journal.close(); // every SSE stream and UDS attach ends; their leases come back
        std.debug.print("session {s} closed\n", .{slot.id.asSlice()});
        log.info("daemon", "session {s} closed", .{slot.id.asSlice()});
        md.mutex.lock();
        defer md.mutex.unlock();
        std.debug.assert(slot.state == .closing);
        slot.state = .closed; // the reaper's from here
    }

    fn reserve(md: *MultiDaemon, id: SessionId) CreateError!void {
        md.mutex.lock();
        defer md.mutex.unlock();
        if (md.shutting_down) return error.ShuttingDown;
        if (md.table.contains(id.bytes) or md.reserved.contains(id.bytes)) return error.SessionLive;
        // A destroyed session keeps its id until it is reaped: its App still
        // owns the session directory (transcript writer, records) until then.
        var retired = md.retired;
        while (retired) |slot| : (retired = slot.next_retired) {
            if (std.mem.eql(u8, &slot.id.bytes, &id.bytes)) return error.SessionClosing;
        }
        if (md.table.count() + md.reserved.count() >= md.max_sessions) return error.SessionLimit;
        md.reserved.put(md.gpa, id.bytes, {}) catch return error.CreateFailed;
    }

    fn unreserve(md: *MultiDaemon, id: SessionId) void {
        md.mutex.lock();
        defer md.mutex.unlock();
        _ = md.reserved.remove(id.bytes);
    }

    /// Make a wired slot resolvable. Refused once shutdown has begun.
    fn publish(md: *MultiDaemon, slot: *SessionSlot) CreateError!void {
        md.mutex.lock();
        defer md.mutex.unlock();
        if (md.shutting_down) return error.ShuttingDown;
        md.table.put(md.gpa, slot.id.bytes, slot) catch return error.CreateFailed;
        _ = md.reserved.remove(slot.id.bytes);
        _ = md.live.fetchAdd(1, .acq_rel);
    }

    /// Take a lease on a live session (`refs += 1`), or null.
    fn acquire(md: *MultiDaemon, id: SessionId) ?*SessionSlot {
        md.mutex.lock();
        defer md.mutex.unlock();
        const slot = md.table.get(id.bytes) orelse return null;
        // The table holds live slots only: a destroy takes a slot out of it and
        // marks it closing under this mutex, so a closing slot is never leased.
        std.debug.assert(slot.state == .live);
        _ = slot.refs.fetchAdd(1, .monotonic);
        return slot;
    }

    fn isLive(md: *MultiDaemon, id: SessionId) bool {
        md.mutex.lock();
        defer md.mutex.unlock();
        return md.table.contains(id.bytes);
    }

    /// Whether `id` has a transcript under the state root, where its App's
    /// writer will look (`transcript.sessionDir` of the process cwd).
    fn hasTranscript(md: *MultiDaemon, id: SessionId) bool {
        if (md.state_root.len == 0) return false;
        const cwd = util_fs.getCwd(md.gpa) catch return false;
        defer md.gpa.free(cwd);
        const dir = transcript.sessionDir(md.gpa, .{ .path = md.state_root }, cwd, id) catch return false;
        defer md.gpa.free(dir);
        var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buffer, "{s}/transcript.jsonl", .{dir}) catch return false;
        return pfs.exists(path.ptr);
    }

    // ── slots ────────────────────────────────────────────────────────────────

    /// A new App (c_allocator, own io runtime) under `id`.
    fn buildSlot(md: *MultiDaemon, id: SessionId) !*SessionSlot {
        const slot = try md.gpa.create(SessionSlot);
        errdefer md.gpa.destroy(slot);
        const io_rt = try md.gpa.create(std.Io.Threaded);
        errdefer md.gpa.destroy(io_rt);
        io_rt.* = @import("platform").signal.threadedIo(md.gpa, .{});
        errdefer io_rt.deinit();
        slot.* = .{ .id = id, .id_text = id.bytes, .io_rt = io_rt, .app = undefined };
        var config = md.config;
        config.session_id = &slot.id_text;
        slot.app = try app_mod.App.init(md.gpa, io_rt.io(), config, md.api_key);
        std.debug.assert(std.mem.eql(u8, slot.app.session_id.asSlice(), id.asSlice()));
        return slot;
    }

    /// Host, backend, hooks and driver for a slot whose App is set. On error
    /// `freeSlot` undoes whatever was done.
    fn wire(md: *MultiDaemon, slot: *SessionSlot) !void {
        const host = try SessionHost.create(md.gpa, slot.id, @ptrCast(&slot.dctx), app_driver.driverFn, null, app_driver.abortFn);
        slot.host = host;
        slot.wb = WebBackend.init(md.gpa, &host.journal);
        slot.wb.abort = &slot.app.abort;
        slot.wb.usage_totals = &slot.app.usage;
        slot.dctx = .{ .app = slot.app, .wb = &slot.wb };
        slot.config_sink = .{ .journal = &host.journal, .alloc = md.gpa };
        slot.state_src = .{ .app = slot.app, .wb = &slot.wb, .cmdbox = &host.cmdbox, .journal = &host.journal, .generating = &host.generating };
        slot.app.setConfigEventSink(slot.config_sink.sink());
        slot.app.permission_ctx.ui_requester = slot.wb.requester();
        slot.wired = true;
        web_session.journalSessionLifecycle(&host.journal, md.gpa, .{ .created = slot.id.asSlice() });
        try host.start();
    }

    /// Free a slot no lease can reach: an unpublished one, or a retired one
    /// whose `refs` is 0. Joins the driver if it still runs, then App.deinit
    /// (after the join: it closes the client the driver uses) and the io
    /// runtime (after App.deinit). Caller holds `build_mutex`.
    fn freeSlot(md: *MultiDaemon, slot: *SessionSlot) void {
        std.debug.assert(slot.refs.load(.acquire) == 0);
        if (slot.wired) {
            slot.host.destroy(); // join (if still running) + journal/inbox/cmdbox
            slot.app.permission_ctx.ui_requester = null;
            slot.app.setConfigEventSink(null);
            slot.wb.deinit();
        }
        slot.app.deinit();
        if (slot.io_rt) |rt| {
            rt.deinit();
            md.gpa.destroy(rt);
        }
        md.gpa.destroy(slot);
    }

    /// Lease every live session, in id order (ids sort by creation time).
    /// The caller releases each.
    fn leaseAll(md: *MultiDaemon, allocator: std.mem.Allocator) ![]*SessionSlot {
        const slots = blk: {
            md.mutex.lock();
            defer md.mutex.unlock();
            const slots = try allocator.alloc(*SessionSlot, md.table.count());
            var it = md.table.valueIterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                slots[i] = entry.*;
                _ = entry.*.refs.fetchAdd(1, .monotonic);
            }
            break :blk slots;
        };
        std.mem.sort(*SessionSlot, slots, {}, slotLessThan);
        return slots;
    }

    /// Live session ids in order, copied (no lease needed).
    fn liveIds(md: *MultiDaemon, allocator: std.mem.Allocator) ![]SessionId {
        const ids = blk: {
            md.mutex.lock();
            defer md.mutex.unlock();
            const ids = try allocator.alloc(SessionId, md.table.count());
            var it = md.table.valueIterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) ids[i] = entry.*.id;
            break :blk ids;
        };
        std.mem.sort(SessionId, ids, {}, idLessThan);
        return ids;
    }
};

fn slotLessThan(_: void, a: *SessionSlot, b: *SessionSlot) bool {
    return std.mem.lessThan(u8, &a.id.bytes, &b.id.bytes);
}

fn idLessThan(_: void, a: SessionId, b: SessionId) bool {
    return std.mem.lessThan(u8, &a.bytes, &b.bytes);
}

/// Free the App main built when no session adopts it (SIGINT no longer
/// points at it: `start` detached it first).
fn releaseMainApp(app: *app_mod.App) void {
    app.deinit();
}

fn daemonOf(ctx: *anyopaque) *MultiDaemon {
    return @ptrCast(@alignCast(ctx));
}

// ── transport callbacks ─────────────────────────────────────────────────────

fn resolveLease(ctx: *anyopaque, text: []const u8) ?server_mod.Lease {
    const id = SessionId.fromSlice(text) orelse return null;
    const slot = daemonOf(ctx).acquire(id) orelse return null;
    return .{ .view = slot.view(), .ctx = @ptrCast(slot), .release_fn = &releaseLease };
}

fn releaseLease(ctx: *anyopaque) void {
    const slot: *SessionSlot = @ptrCast(@alignCast(ctx));
    const before = slot.refs.fetchSub(1, .acq_rel);
    std.debug.assert(before > 0);
}

fn createThunk(ctx: *anyopaque, request: server_mod.CreateRequest) CreateError!server_mod.Created {
    return daemonOf(ctx).createSession(request);
}

fn isLiveThunk(ctx: *anyopaque, id: SessionId) bool {
    return daemonOf(ctx).isLive(id);
}

fn destroyThunk(ctx: *anyopaque, id: SessionId) server_mod.DestroyError!void {
    return daemonOf(ctx).destroySession(id);
}

/// `GET /sessions`: per live session the fields `/state` reads the same
/// way — `model` through the App's locked snapshot, the rest scalars and the
/// backend's locked pending id (0 = none) — under a lease each.
fn listThunk(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const md = daemonOf(ctx);
    const slots = try md.leaseAll(allocator);
    defer {
        for (slots) |slot| releaseLease(@ptrCast(slot));
        allocator.free(slots);
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"sessions\":[");
    for (slots, 0..) |slot, i| {
        if (i > 0) try out.writer.writeAll(",");
        const slices = try slot.app.snapshotSlices(allocator);
        defer {
            allocator.free(slices.model);
            for (slices.dirs) |dir| allocator.free(dir);
            allocator.free(slices.dirs);
        }
        try std.json.Stringify.value(.{
            .session_id = slot.id.asSlice(),
            .generating = slot.host.generating.load(.acquire),
            .model = slices.model,
            .permission_mode = @tagName(slot.app.permMode()),
            .pending_request_id = slot.wb.pendingId(),
        }, .{}, &out.writer);
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

/// Deps.state_fn placeholder (never called: every session path is leased).
fn placeholderState(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    return allocator.dupe(u8, "{}");
}

/// **诚实落地页(PM M1)**:多 session 下内嵌单 session SPA 的无前缀 fetch 全 404,故 `GET /` 不返 SPA,
/// 而返一张列出活跃 session id + API 端点的说明页。失败(OOM)返 null → route 兜底返 SPA(至少不炸)。
fn rootPage(ctx: *anyopaque, allocator: std.mem.Allocator) ?[]u8 {
    const md = daemonOf(ctx);
    const ids = md.liveIds(allocator) catch return null;
    defer allocator.free(ids);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    buf.appendSlice(allocator, "<!doctype html><meta charset=utf-8><title>metacodes daemon</title>" ++
        "<body style=\"font-family:system-ui;max-width:52rem;margin:2rem auto;padding:0 1rem\">" ++
        "<h1>metacodes daemon — multi-session</h1>" ++
        "<p><b>注意</b>:内嵌浏览器 SPA 仅在单 session <code>--web</code> 模式可用。此处为多 session " ++
        "<b>API 级路由</b>,浏览器 SPA(<code>/events</code>、<code>/message</code> 等无前缀端点)在本模式不工作。</p>" ++
        "<h2>Live sessions</h2><ul>") catch return null;
    for (ids) |id| {
        buf.appendSlice(allocator, "<li><code>") catch return null;
        buf.appendSlice(allocator, id.asSlice()) catch return null; // 24 hex,无需转义
        // The trace view works per session under /s/<id>/ (it reads ./spans).
        buf.appendSlice(allocator, "</code> · <a href=\"/s/") catch return null;
        buf.appendSlice(allocator, id.asSlice()) catch return null;
        buf.appendSlice(allocator, "/trace\">trace</a></li>") catch return null;
    }
    if (ids.len == 0) buf.appendSlice(allocator, "<li>(none; create one with POST /sessions/create)</li>") catch return null;
    buf.appendSlice(allocator, "</ul><h2>API</h2><pre>" ++
        "GET  /health                 (liveness; no session, no token)\n" ++
        "GET  /sessions               {\"sessions\":[{\"session_id\",\"generating\",\"model\",\"permission_mode\",\"pending_request_id\"}]}\n" ++
        "POST /sessions/create        {\"session_id\"?:\"&lt;24 hex&gt;\",\"resume\"?:true} → 201 {\"session_id\",\"messages\"}\n" ++
        "POST /sessions/&lt;id&gt;/resume   200 if live, 404 if not (loads nothing)\n" ++
        "POST /sessions/&lt;id&gt;/destroy  200 once its run and background work are stopped\n" ++
        "POST /s/&lt;id&gt;/message       {\"text\":\"...\"}\n" ++
        "GET  /s/&lt;id&gt;/events        (SSE)\n" ++
        "POST /s/&lt;id&gt;/respond       {\"id\":N,...}\n" ++
        "POST /s/&lt;id&gt;/command       {\"cmd\":\"/verb ...\"}\n" ++
        "POST /s/&lt;id&gt;/interrupt\n" ++
        "GET  /s/&lt;id&gt;/state\n" ++
        "GET  /s/&lt;id&gt;/spans         (OTLP/JSON of the session's spans)\n" ++
        "GET  /s/&lt;id&gt;/trace         (the session's trace view)\n" ++
        "</pre></body>") catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

/// **UDS `list` op**:NDJSON `{"sessions":["<id>",...]}`(活跃 session id,按创建时间排序)。OOM 返 null。
fn udsList(ctx: *anyopaque, allocator: std.mem.Allocator) ?[]u8 {
    const md = daemonOf(ctx);
    const ids = md.liveIds(allocator) catch return null;
    defer allocator.free(ids);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    buf.appendSlice(allocator, "{\"sessions\":[") catch return null;
    for (ids, 0..) |id, i| {
        if (i > 0) buf.appendSlice(allocator, ",") catch return null;
        buf.appendSlice(allocator, "\"") catch return null;
        buf.appendSlice(allocator, id.asSlice()) catch return null; // 24 hex,无需转义
        buf.appendSlice(allocator, "\"") catch return null;
    }
    buf.appendSlice(allocator, "]}") catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

/// 跑 daemon 直到 SIGINT。返回进程退出码。app0 = main 预建 app(N ≥ 1 时作首个 session,N = 0 时立即
/// 释放)。`surface`:HTTP 面的 bind/token/版本(#251-#253;UDS 不受影响,仍是 0600 文件权限)。
pub fn serveMulti(app0: *app_mod.App, config: types.Config, api_key: []const u8, surface: server_mod.Surface, initial: usize, max_sessions: usize, uds_path: ?[]const u8) !u8 {
    // SIGINT handler 已在 main 装:shutdown.request()(+ 不再戳 app0.abort,见 detachSigintAbort)。
    // 主循环 poll shutdown.requested(),并在每个 tick 回收已销毁且 lease 已全部归还的 session。
    const md = try MultiDaemon.start(std.heap.c_allocator, app0, config, api_key, .{
        .initial = initial,
        .max_sessions = max_sessions,
        .surface = surface,
        .uds_path = uds_path,
    });
    var label_buffer: [64]u8 = undefined;
    md.srv.?.announce(std.fmt.bufPrint(&label_buffer, "metacodes daemon ({d} sessions)", .{initial}) catch "metacodes daemon");

    while (!shutdown.requested()) {
        md.reap();
        time.sleepMs(50);
    }

    md.stop();
    md.destroy();
    std.debug.print("\ndaemon closed.\n", .{});
    return 0;
}
