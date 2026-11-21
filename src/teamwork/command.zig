//! CLI host for the approved, deterministic SWE loop. Status is disk-only;
//! preparation never creates a run or starts a provider. See TEAMWORK_DESIGN.
const std = @import("std");
const platform = @import("platform");
const pfs = platform.fs;
const App = @import("../app.zig").App;
const app_types = @import("../types.zig");
const config = @import("config.zig");
const types = @import("types.zig");
const runtime = @import("runtime.zig");
const run_dir = @import("run_dir.zig");
const reviewer = @import("reviewer.zig");
const verifier = @import("verifier_auditor.zig");
const scope = @import("drivers/write_scope.zig");
const sandbox_exec = @import("../sandbox/exec.zig");
const util_fs = @import("../util/fs.zig");
const interview = @import("interview.zig");
const merge_back = @import("merge_back.zig");
const provider_factory = @import("../api/provider_factory.zig");
const progress = @import("progress.zig");
const lesson = @import("../kg/lesson.zig");

pub const RunId = types.RunId;

pub const help =
    \\usage: metacodes [--state-dir <dir>] teamwork run --request-file <file> --approve [options]
    \\       metacodes [--state-dir <dir>] teamwork status <id> [--json]
    \\       metacodes [--state-dir <dir>] teamwork resume <id> --approve [provider options]
    \\       metacodes [--state-dir <dir>] teamwork mcp --request-file <file> --approve [options]
    \\
    \\Run options: --id <id> --budget-usd <dollars> --max-rounds <n>
    \\             --events (run/resume: teamwork.snapshot and teamwork.event lines on stdout)
    \\             --preview | --no-preview | --preview=teamwork,... | --no-preview=...
    \\             (last flag wins per feature; overrides saved preview)
    \\             --check-command <command> --config-json <teamwork-object>
    \\Provider options: --provider <profile> --model <model> --base-url <url>
    \\                  --api-key <key> --verbose
    \\Configuration: state/config.json teamwork < project/.metacodes/teamwork.json < CLI.
    \\The request may start with [skip-interview] and [seats=<role>:<harness>[:<model>],...]
    \\segments; seats apply to this run only. The rest of the request is approved as is.
    \\A positive dollar cap and explicit --approve are required. Approval covers
    \\the request, configured harnesses/check, spend up to the cap and merge-back.
    \\Teamwork requires the teamwork preview feature (off by default).
    \\--preview does not approve a task.
    \\Status and cancellation of an existing handle remain available with preview off.
    \\Runs are synchronous. Resume uses the saved approved policy, never new overrides.
    \\Status always emits JSON and starts no provider. Exit: 0 done/status/help,
    \\1 terminal failure, 2 invalid input/refusal. Required sandbox; no fallback.
    \\
;

pub const Action = enum { run, @"resume", status, mcp, help };
pub const Options = struct {
    action: Action,
    id: ?types.RunId = null,
    request_file: ?[]const u8 = null,
    approve: bool = false,
    events: bool = false,
    overrides: config.Layer = .{},
    has_overrides: bool = false,
    host_config: app_types.Config = .{ .prompt = "", .mcp_connect = .disabled },
};

/// `args` starts after the word `teamwork`. All strings live in `arena`.
pub fn parse(arena: std.mem.Allocator, args: anytype) !Options {
    const name = args.next() orelse return .{ .action = .help };
    if (eq(name, "--help") or eq(name, "-h")) return .{ .action = .help };
    var out: Options = .{ .action = std.meta.stringToEnum(Action, name) orelse return error.UnknownCommand };
    if (out.action == .status or out.action == .@"resume") {
        out.id = try types.RunId.parse(args.next() orelse return error.RunIdMissing);
    }
    while (args.next()) |arg| {
        if (try out.host_config.preview.applyArg(arg)) {} else if (eq(arg, "--approve")) {
            out.approve = true;
        } else if (eq(arg, "--events")) {
            if (out.action != .run and out.action != .@"resume") return error.UnknownOption;
            out.events = true;
        } else if (eq(arg, "--json")) {
            if (out.action != .status) return error.UnknownOption;
        } else if (eq(arg, "--verbose")) {
            if (out.action == .status) return error.UnknownOption;
            out.host_config.verbose = true;
        } else if (eq(arg, "--help") or eq(arg, "-h")) {
            out.action = .help;
            return out;
        } else {
            if (out.action == .status) return error.UnknownOption;
            const value = try arena.dupe(u8, args.next() orelse return error.OptionValueMissing);
            if (eq(arg, "--provider")) {
                out.host_config.provider_profile = value;
            } else if (eq(arg, "--model")) {
                if (out.action == .@"resume") return error.ResumeOverridesForbidden;
                out.host_config.model = value;
                out.host_config.model_explicit = true;
            } else if (eq(arg, "--base-url")) {
                out.host_config.base_url = value;
            } else if (eq(arg, "--api-key")) {
                out.host_config.api_key = value;
            } else {
                if (out.action != .run and out.action != .mcp) return error.ResumeOverridesForbidden;
                if (eq(arg, "--request-file")) {
                    out.request_file = value;
                } else if (eq(arg, "--id")) {
                    out.id = try types.RunId.parse(value);
                } else {
                    out.has_overrides = true;
                    if (eq(arg, "--budget-usd")) {
                        out.overrides.budget_usd = try std.fmt.parseFloat(f64, value);
                    } else if (eq(arg, "--max-rounds")) {
                        out.overrides.max_rounds = try std.fmt.parseInt(u32, value, 10);
                    } else if (eq(arg, "--check-command")) {
                        out.overrides.check_command = value;
                    } else if (eq(arg, "--config-json")) {
                        out.overrides = config.merge(out.overrides, try config.parse(arena, value, null));
                    } else return error.UnknownOption;
                }
            }
        }
    }
    if (out.action == .status and out.approve) return error.UnknownOption;
    if ((out.action == .run or out.action == .mcp) and out.request_file == null) return error.RequestFileMissing;
    return out;
}

pub const Prepared = struct {
    action: Action,
    id: types.RunId,
    cfg: config.Config.Enabled,
    request: []const u8,
    source: runtime.RequestSource,
    workspace: []const u8,
    events: bool = false,
};

/// Approval is checked before file reads, git, App startup or run creation.
pub fn prepare(arena: std.mem.Allocator, options: Options, state_root: []const u8, workspace: []const u8) !Prepared {
    if (!options.approve) return error.ApprovalRequired;
    const preview = try @import("../app/config.zig").resolvePreview(arena, state_root, options.host_config.preview);
    if (!preview.features().teamwork) return error.PreviewDisabled;
    if (options.action != .run and options.action != .@"resume" and options.action != .mcp) return error.UnknownCommand;
    const generated = @import("../core/session_id.zig").gen();
    const id = options.id orelse try types.RunId.parse(generated.asSlice());
    var request: []const u8 = "";
    var source: runtime.RequestSource = .request_file;
    var repo: []const u8 = undefined;
    var layer: config.Layer = .{};
    if (options.action == .@"resume") {
        if (options.has_overrides) return error.ResumeOverridesForbidden;
        var dir = try run_dir.RunDir.open(arena, state_root, id);
        defer dir.deinit(arena);
        var buf: run_dir.PathBuf = undefined;
        const saved = try std.json.parseFromSliceLeaky(std.json.Value, arena, try readRequired(arena, try dir.path(&buf, .state)), .{});
        if (saved != .object) return error.StateCorrupt;
        const policy = saved.object.get("approved_config_json") orelse return error.ConfigurationChanged;
        if (policy != .string) return error.StateCorrupt;
        layer = try config.parse(arena, policy.string, null);
        const saved_repo = saved.object.get("repo") orelse return error.StateCorrupt;
        if (saved_repo != .string) return error.StateCorrupt;
        repo = try @import("merge_back.zig").toplevel(arena, saved_repo.string, null);
        if (!eq(repo, saved_repo.string)) return error.StateCorrupt;
    } else {
        repo = try merge_back.toplevel(arena, workspace, null);
        const raw = try readRequired(arena, options.request_file.?);
        if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return error.EmptyRequest;
        const segments = try interview.parseSegments(arena, raw);
        request = segments.request;
        if (segments.skip_interview) source = .skip_interview;
        layer = config.merge(config.merge(try configuredLayer(arena, state_root, repo), segments.seats), options.overrides);
    }
    const cfg = try validated(layer);
    // Git's toplevel is read-only. Do not let run state become an untracked
    // input of the workspace snapshot or a writable part of the worker tree.
    try requireExternalState(arena, state_root, repo);
    return .{ .action = options.action, .id = id, .cfg = cfg, .request = request, .source = source, .workspace = repo, .events = options.events };
}

fn configuredLayer(arena: std.mem.Allocator, state_root: []const u8, repo: []const u8) !config.Layer {
    var layer: config.Layer = .{};
    const global_path = try std.fmt.allocPrint(arena, "{s}/config.json", .{state_root});
    if (try readOptional(arena, global_path)) |text| {
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
        if (value != .object) return error.InvalidJson;
        if (value.object.get("teamwork")) |teamwork| layer = try config.parseValue(arena, teamwork, null);
    }
    const project_path = try std.fmt.allocPrint(arena, "{s}/.metacodes/teamwork.json", .{repo});
    if (try readOptional(arena, project_path)) |text| layer = config.merge(layer, try config.parse(arena, text, null));
    return layer;
}

fn validated(merged: config.Layer) !config.Config.Enabled {
    var layer = merged;
    if (layer.enabled == null) layer.enabled = true;
    const cfg = switch (try config.validate(layer, null)) {
        .disabled => return error.TeamworkDisabled,
        .enabled => |c| c,
    };
    try supported(cfg);
    return cfg;
}

fn supported(cfg: config.Config.Enabled) !void {
    const manager = cfg.seats.get(.manager);
    if (manager.harnessKind() != .metacodes or manager.model != null or manager.effort != null)
        return error.UnsupportedManager;
    const seat = cfg.seats.get(.verifier);
    if (seat.harnessKind() != .metacodes) return error.ExternalVerifierUnsupported;
    if (seat.effort != null) return error.VerifierEffortUnsupported;
    // VerifierAuditor currently resolves tiers (and their effort) itself.
    // Reject tier aliases here so no implicit effort escapes this contract.
    if (seat.model) |m| {
        if (eq(m, "low") or eq(m, "mid") or eq(m, "high")) return error.VerifierTierUnsupported;
    }
}

fn policyJson(arena: std.mem.Allocator, cfg: config.Config.Enabled) ![]const u8 {
    var layer: config.Layer = .{ .enabled = true, .budget_usd = cfg.budget_usd, .max_rounds = cfg.max_rounds };
    if (cfg.check_command) |check| layer.check_command = check.text;
    for (std.enums.values(types.Role)) |role| layer.seats.set(role, seatLayerOf(cfg.seats.get(role)));
    // EnumArray's JSON is an implementation detail; serialize the public
    // object schema explicitly, with absent optionals omitted.
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("enabled");
    try s.write(true);
    try s.objectField("budget_usd");
    try s.write(cfg.budget_usd);
    try s.objectField("max_rounds");
    try s.write(cfg.max_rounds);
    if (cfg.candidate_estimate_usd) |estimate| {
        try s.objectField("candidates");
        try s.beginArray();
        for (cfg.candidates.slice()) |spec| try s.write(seatLayerOf(spec));
        try s.endArray();
        try s.objectField("candidate_estimate_usd");
        try s.write(estimate);
    }
    if (layer.check_command) |check| {
        try s.objectField("check_command");
        try s.write(check);
    }
    try s.objectField("seats");
    try s.beginObject();
    for (std.enums.values(types.Role)) |role| {
        try s.objectField(role.name());
        try s.write(layer.seats.get(role));
    }
    try s.endObject();
    try s.endObject();
    return out.toOwnedSlice();
}

fn seatLayerOf(spec: types.SeatSpec) config.SeatLayer {
    var seat: config.SeatLayer = .{ .harness = spec.harnessKind(), .model = spec.model, .effort = spec.effort };
    switch (spec.harness) {
        .metacodes => {},
        .claude_code => |external| {
            seat.command = external.command.bytes;
            switch (external.budget) {
                .cost => seat.budget_enforcement = .cost,
                .wallclock_only => |limit| {
                    seat.budget_enforcement = .wallclock_only;
                    seat.wallclock_seconds = limit.seconds;
                },
            }
            if (external.demote_only) seat.demote_only = true;
        },
    }
    return seat;
}

/// Stable host seam for CLI and the incoming MCP server. Heap allocated:
/// runtime dependencies borrow `sandbox` and `auditor` at stable addresses.
pub const Host = struct {
    app: *App,
    sandbox: @import("../sandbox/config.zig").SandboxSettings,
    auditor: verifier.VerifierAuditor,
    parent_env: []const [:0]const u8,
    provider: @import("../api/provider.zig").Provider,
    anthropic_client: ?*@import("../client.zig").Client,

    pub fn create(arena: std.mem.Allocator, app: *App, cfg: config.Config.Enabled) !*Host {
        return createWith(arena, app, cfg, app.provider(), app.anthropicClientOrNull());
    }

    pub fn createOwned(arena: std.mem.Allocator, app: *App, cfg: config.Config.Enabled, owned: *provider_factory.OwnedProvider) !*Host {
        return createWith(arena, app, cfg, owned.provider(), owned.anthropicClient());
    }

    fn createWith(
        arena: std.mem.Allocator,
        app: *App,
        cfg: config.Config.Enabled,
        provider: @import("../api/provider.zig").Provider,
        anthropic_client: ?*@import("../client.zig").Client,
    ) !*Host {
        if (!app.config.preview.features().teamwork) return error.PreviewDisabled;
        try supported(cfg);
        if (!sandbox_exec.hostSupported()) return error.SandboxUnavailable;
        // Other embedders can supply an App with deferred MCP publication.
        // Never snapshot empty tool definitions into a paid seat's deps.
        try app.publishMcpServers();
        const self = try arena.create(Host);
        self.* = .{
            .app = app,
            .sandbox = scope.seatSandbox(app.sandboxPtr()),
            .auditor = undefined,
            .parent_env = try platform.paths.environment(arena),
            .provider = provider,
            .anthropic_client = anthropic_client,
        };
        const check: reviewer.CheckRunner = .{ .sandbox = &self.sandbox, .home = app.homeDir() };
        self.auditor = .{
            .deps = .{
                .provider = provider,
                .anthropic_client = anthropic_client,
                .tool_defs = app.tool_defs,
                .permission_ctx = &app.permission_ctx,
                .session = app.session_id,
                .state_root = app.stateRoot(),
                .home_dir = app.homeDir(),
                .sandbox = &self.sandbox,
                .artifact_root = app.sessionDir() orelse "",
            },
            .check_runner = check,
            .model = cfg.seats.get(.verifier).model,
        };
        return self;
    }

    pub fn deps(self: *Host) runtime.Deps {
        const app = self.app;
        return .{
            .preview = app.config.preview.features(),
            .seats = .{ .harness = .{
                .metacodes = .{
                    .preview = app.config.preview.features(),
                    .provider = self.provider,
                    .anthropic_client = self.anthropic_client,
                    .tool_defs = app.tool_defs,
                    .permission_ctx = &app.permission_ctx,
                    .host_sandbox = &self.sandbox,
                    .home_dir = app.homeDir(),
                    .state_root = app.stateRoot(),
                    .artifact_root = app.sessionDir() orelse "",
                    .session = app.session_id,
                },
                .claude_code = .{ .parent_env = self.parent_env, .home_dir = app.homeDir(), .sandbox = true, .host_sandbox = &self.sandbox },
            } },
            .auditor = self.auditor.auditor(),
            .check_runner = self.auditor.check_runner,
            .pitfalls = .{ .ctx = app, .rememberFn = rememberPitfall },
        };
    }

    fn rememberPitfall(ctx: *anyopaque, text: []const u8) bool {
        const app: *App = @ptrCast(@alignCast(ctx));
        const kg = if (app.kg) |*client| client else return false;
        _ = kg.remember(.observation, text, lesson.SCHEMA_TYPE, false) catch return false;
        return true;
    }

    /// Pin the effective inputs consulted by child tools and pinned checks.
    /// Hash data only, never allocator addresses, session IDs or live handles.
    fn policyFingerprint(self: *const Host, arena: std.mem.Allocator) ![32]u8 {
        const permission = &self.app.permission_ctx;
        var out: std.Io.Writer.Allocating = .init(arena);
        defer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer };
        try s.beginObject();
        try s.objectField("sandbox");
        try s.write(.{
            .home = self.app.homeDir(),
            .allow_read = self.sandbox.allow_read,
            .deny_read = self.sandbox.deny_read,
            .deny_write = self.sandbox.deny_write,
            .allowed_domains = self.sandbox.allowed_domains,
            .denied_domains = self.sandbox.denied_domains,
        });
        try s.objectField("mode");
        try s.write(permission.effectiveMode());
        try s.objectField("rules");
        if (permission.rules) |rules| try s.write(rules.rules.items) else try s.write(null);
        try s.objectField("settings");
        if (permission.settings) |settings| try s.write(settings.layers) else try s.write(null);
        try s.objectField("hooks");
        if (permission.hooks) |hooks| {
            try s.write(.{
                .pre_tool_use = hooks.pre_tool_use,
                .post_tool_use = hooks.post_tool_use,
                .stop = hooks.stop,
                .pre_compact = hooks.pre_compact,
                .post_compact = hooks.post_compact,
            });
        } else try s.write(null);
        try s.endObject();
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(out.written(), &digest, .{});
        return digest;
    }
};

/// The coordinator binds this to mcp_server.Server.init(gpa, run).serve().
/// The server borrows the approved run and host until this call returns.
pub const McpHost = struct {
    serveFn: *const fn (gpa: std.mem.Allocator, run: *runtime.Run) anyerror!void,
};

pub fn execute(arena: std.mem.Allocator, app: *App, prepared: Prepared) !u8 {
    return executeWithMcp(arena, app, prepared, null);
}

pub fn executeWithMcp(arena: std.mem.Allocator, app: *App, prepared: Prepared, mcp: ?McpHost) !u8 {
    if (!app.config.preview.features().teamwork) return error.PreviewDisabled;
    if (prepared.action == .mcp and mcp == null) return error.McpHostUnavailable;
    var cfg = prepared.cfg;
    if (prepared.action != .@"resume") pinInheritedModels(&cfg, app.activeModel());
    const host = try Host.create(arena, app, cfg);
    try checkClaudeState(arena, app, cfg, prepared.workspace);
    var deps = host.deps();
    deps.cli_approval = .{ .config_json = try policyJson(arena, cfg), .host_sha256 = try host.policyFingerprint(arena) };
    var lines: LineObserver = .{};
    if (prepared.events) deps.observer = lines.observer();
    // Run owns the OS lifetime lease, shared by CLI and MCP callers.
    const run = if (prepared.action != .@"resume")
        try runtime.Run.start(app.allocator, deps, .{ .text = prepared.request, .source = prepared.source }, cfg, .{ .state_root = app.stateRoot(), .run_id = prepared.id, .workspace = prepared.workspace })
    else
        try runtime.Run.reopen(app.allocator, deps, cfg, app.stateRoot(), prepared.id);
    defer run.destroy();
    std.debug.print("teamwork run {s}; status: metacodes teamwork status {s}\n", .{ prepared.id.slice(), prepared.id.slice() });
    if (prepared.events) try lines.snapshot(arena, run.status());
    var stopped = std.atomic.Value(bool).init(false);
    const watcher = try platform.thread.spawn(.waiter, forwardAbort, .{ &app.abort, &run.abort, &stopped });
    defer {
        stopped.store(true, .release);
        watcher.join();
    }
    if (prepared.action == .mcp) {
        try mcp.?.serveFn(app.allocator, run);
        return 0;
    }
    const state = try @import("swe_loop.zig").drive(run);
    try status(arena, app.stateRoot(), prepared.id);
    return if (state == .done) 0 else 1;
}

const LineObserver = struct {
    fn observer(self: *LineObserver) progress.Observer {
        return .{ .ctx = self, .notifyFn = notify };
    }

    fn snapshot(_: *LineObserver, arena: std.mem.Allocator, run: runtime.RunSnapshot) !void {
        var out: std.Io.Writer.Allocating = .init(arena);
        try progress.writeSnapshotLine(&out.writer, .ofRun(run));
        if (!pfs.writeAll(1, out.written())) return error.WriteFailed;
    }

    fn notify(_: *anyopaque, event: *const progress.Event) void {
        var out: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
        defer out.deinit();
        progress.writeEventLine(&out.writer, event) catch return;
        _ = pfs.writeAll(1, out.written());
    }
};

fn pinInheritedModels(cfg: *config.Config.Enabled, model: []const u8) void {
    for ([_]types.Role{ .implementer, .reviewer, .verifier, .judge }) |role| pinModel(cfg.seats.getPtr(role), model);
    for (cfg.candidates.specs[0..cfg.candidates.len]) |*seat| pinModel(seat, model);
}

fn pinModel(seat: *types.SeatSpec, model: []const u8) void {
    if (seat.harnessKind() == .metacodes and seat.model == null) seat.model = model;
}

fn checkClaudeState(arena: std.mem.Allocator, app: *App, cfg: config.Config.Enabled, workspace: []const u8) !void {
    for ([_]types.Role{ .interviewer, .implementer, .reviewer, .judge }) |role| {
        if (cfg.seats.get(role).harnessKind() == .claude_code)
            return requireSeparateClaudeState(arena, app.homeDir(), app.stateRoot(), workspace);
    }
    for (cfg.candidates.slice()) |spec| {
        if (spec.harnessKind() == .claude_code)
            return requireSeparateClaudeState(arena, app.homeDir(), app.stateRoot(), workspace);
    }
}

pub const Interactive = union(enum) {
    started: *Background,
    rejected: RunId,
    interview_failed: RunId,
    budget_exhausted: RunId,
    aborted: RunId,
};

pub const Background = struct {
    arena_state: std.heap.ArenaAllocator,
    owned: ?provider_factory.OwnedProvider = null,
    id: RunId,
    interview_abort: types.AbortSignal = types.AbortSignal.init(),
    run: ?*runtime.Run = null,
    thread: ?std.Thread = null,
    ended: std.atomic.Value(bool) = .init(false),

    fn create(id: RunId) !*Background {
        const self = try std.heap.c_allocator.create(Background);
        self.* = .{ .arena_state = .init(std.heap.c_allocator), .id = id };
        return self;
    }

    pub fn finished(self: *const Background) bool {
        return self.ended.load(.acquire);
    }

    pub fn stop(self: *Background) void {
        if (self.run) |run| {
            if (self.thread) |thread| {
                run.abort.abort(.user_ctrl_c);
                thread.join();
            }
            run.destroy();
        }
        if (self.owned) |*owned| owned.deinit();
        self.arena_state.deinit();
        std.heap.c_allocator.destroy(self);
    }

    fn drive(self: *Background) void {
        _ = @import("swe_loop.zig").drive(self.run.?) catch |err|
            @import("../util/log.zig").warn("teamwork", "run {s} stopped: {s}", .{ self.id.slice(), @errorName(err) });
        self.ended.store(true, .release);
    }
};

pub fn startInteractive(app: *App, workspace: []const u8, text: []const u8, prompter: interview.Prompter, board: *progress.Board) !Interactive {
    if (!app.config.preview.features().teamwork) return error.PreviewDisabled;
    const generated = @import("../core/session_id.zig").gen();
    const job = try Background.create(try types.RunId.parse(generated.asSlice()));
    var started = false;
    defer if (!started) job.stop();
    const arena = job.arena_state.allocator();
    const gpa = std.heap.c_allocator;

    const segments = try interview.parseSegments(arena, text);
    const repo = try merge_back.toplevel(arena, workspace, null);
    var cfg = try validated(config.merge(try configuredLayer(arena, app.stateRoot(), repo), segments.seats));
    try requireExternalState(arena, app.stateRoot(), repo);
    pinInheritedModels(&cfg, app.activeModel());
    const jobs = if (app.agent_jobs) |*registry| registry else return error.TeamworkBackgroundUnavailable;
    job.owned = try jobs.makeProvider();
    const host = try Host.createOwned(arena, app, cfg, &job.owned.?);
    try checkClaudeState(arena, app, cfg, repo);
    var deps = host.deps();
    deps.cli_approval = .{ .config_json = try policyJson(arena, cfg), .host_sha256 = try host.policyFingerprint(arena) };
    deps.observer = board.observer();
    const options: runtime.StartOptions = .{ .state_root = app.stateRoot(), .run_id = job.id, .workspace = repo };

    const terms = try approvalTerms(arena, cfg, repo);
    const verdict: ?interview.Approved = if (segments.skip_interview)
        try interview.approve(segments.request, .skip_interview, terms, prompter)
    else blk: {
        var drafted = try draftInterruptibly(app, job, deps, cfg, options, segments.request);
        defer drafted.deinit(gpa);
        switch (drafted) {
            .text => |proposal| {
                const decision = interview.approve(proposal, .interview, terms, prompter);
                try interview.finishApproval(gpa, deps, cfg, options, segments.request);
                const decided = try decision orelse break :blk null;
                break :blk interview.Approved{ .text = try arena.dupe(u8, decided.text), .source = decided.source };
            },
            .failed => return .{ .interview_failed = job.id },
            .budget_exhausted => return .{ .budget_exhausted = job.id },
            .aborted => return .{ .aborted = job.id },
        }
    };
    const approved = verdict orelse return .{ .rejected = job.id };
    job.run = try runtime.Run.start(gpa, deps, .{ .text = approved.text, .source = approved.source }, cfg, options);
    try board.publish(.ofRun(job.run.?.status()));
    job.thread = try platform.thread.spawn(.full, Background.drive, .{job});
    started = true;
    return .{ .started = job };
}

fn draftInterruptibly(app: *App, job: *Background, deps: runtime.Deps, cfg: config.Config.Enabled, options: runtime.StartOptions, request: []const u8) !interview.Draft {
    var stopped = std.atomic.Value(bool).init(false);
    const watcher = try platform.thread.spawn(.waiter, forwardAbort, .{ &app.abort, &job.interview_abort, &stopped });
    defer {
        stopped.store(true, .release);
        watcher.join();
        app.abort.reset();
    }
    return interview.draft(std.heap.c_allocator, deps, cfg, options, request, &job.interview_abort);
}

fn approvalTerms(arena: std.mem.Allocator, cfg: config.Config.Enabled, repo: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("Approving also authorizes spend up to ${d} (at most {d} seats per role), these seats:", .{ cfg.budget_usd, cfg.max_rounds });
    for ([_]types.Role{ .interviewer, .implementer, .reviewer, .verifier }) |role| {
        const seat = cfg.seats.get(role);
        try w.print(" {s}={s}", .{ role.name(), seat.harnessKind().name() });
        if (seat.model) |model| try w.print("/{s}", .{model});
    }
    if (cfg.check_command) |check| try w.print(", the check `{s}`", .{check.text}) else try w.writeAll(", no pinned check");
    try w.print(", and merging the result into {s} as uncommitted changes.", .{repo});
    return out.toOwnedSlice();
}

fn forwardAbort(source: *const types.AbortSignal, dest: *types.AbortSignal, stopped: *std.atomic.Value(bool)) void {
    while (!stopped.load(.acquire)) {
        if (source.isAborted()) {
            dest.abort(source.reason());
            return;
        }
        @import("../util/time.zig").sleepMs(20);
    }
}

/// Read-only status: no App, global config, credentials, reopening/recovery
/// mutations, git operations, ledger repair or provider startup.
pub fn status(arena: std.mem.Allocator, state_root: []const u8, id: types.RunId) !void {
    var dir = try run_dir.RunDir.open(arena, state_root, id);
    defer dir.deinit(arena);
    var buf: run_dir.PathBuf = undefined;
    const saved = try std.json.parseFromSliceLeaky(std.json.Value, arena, try readRequired(arena, try dir.path(&buf, .state)), .{});
    if (saved != .object) return error.StateCorrupt;
    const phase = saved.object.get("state") orelse return error.StateCorrupt;
    if (phase != .string or runtime.Phase.parse(phase.string) == null) return error.StateCorrupt;
    const policy = if (saved.object.get("approved_config_json")) |value|
        if (value == .string) value.string else return error.StateCorrupt
    else
        try readRequired(arena, try std.fmt.allocPrint(arena, "{s}/approved-config.json", .{dir.root}));
    const cfg = try config.validate(try config.parse(arena, policy, null), null);
    if (cfg != .enabled) return error.StateCorrupt;
    const budget_path = try dir.path(&buf, .budget);
    const budget = try readOptional(arena, budget_path) orelse "";
    const Pending = struct { seat_id: []const u8, harness: types.Harness, usd: f64, source: []const u8 };
    const pending: ?Pending = if (try readOptional(arena, try std.fmt.allocPrint(arena, "{s}.pending", .{budget_path}))) |text| blk: {
        const receipt = try std.json.parseFromSliceLeaky(Pending, arena, text, .{ .ignore_unknown_fields = true });
        _ = try types.SeatId.parse(receipt.seat_id);
        if (!eq(receipt.source, "reserved") or !std.math.isFinite(receipt.usd) or receipt.usd < 0) return error.CorruptLedger;
        break :blk receipt;
    } else null;
    var spent: f64 = 0;
    var charges: usize = 0;
    var torn_tail = false;
    var lines = std.mem.splitScalar(u8, budget, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (lines.peek() == null) { // no newline: a crash tail, never repair it here
            torn_tail = true;
            break;
        }
        const entry = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
        if (entry != .object) return error.CorruptLedger;
        const usd = entry.object.get("usd") orelse return error.CorruptLedger;
        const amount: f64 = switch (usd) {
            .null => 0,
            .integer => |n| @floatFromInt(n),
            .float => |n| n,
            else => return error.CorruptLedger,
        };
        if (!std.math.isFinite(amount) or amount < 0) return error.CorruptLedger;
        spent += amount;
        charges += 1;
    }
    var recovery = try dir.recover(arena);
    defer recovery.deinit(arena);
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("run_id");
    try s.write(id.slice());
    // Allowlist durable runtime fields; never serialize the approved config
    // (external commands/model names may themselves carry sensitive text).
    for ([_][]const u8{ "state", "detail", "repo", "dispatched", "audits", "last_audit", "merge_conflicts" }) |key| {
        try s.objectField(key);
        try s.write(saved.object.get(key) orelse return error.StateCorrupt);
    }
    try s.objectField("request_source");
    try s.write(saved.object.get("request_source") orelse std.json.Value{ .string = @tagName(runtime.RequestSource.request_file) });
    try s.objectField("budget");
    try s.write(.{ .cap_usd = cfg.enabled.budget_usd, .spent_usd = spent, .remaining_usd = @max(0, cfg.enabled.budget_usd - spent), .charges = charges, .torn_tail = torn_tail, .pending = pending });
    try s.objectField("seats");
    try s.beginArray();
    for (recovery.seats) |seat| {
        switch (seat) {
            .recorded => |recorded| {
                try s.beginObject();
                try s.objectField("id");
                try s.write(recorded.record.id.slice());
                try s.objectField("role");
                try s.write(recorded.record.role);
                try s.objectField("harness");
                try s.write(recorded.record.harness);
                try s.objectField("status");
                try s.write(recorded.record.status);
                try s.objectField("charter_sha256");
                if (@hasField(@TypeOf(recorded.record), "charter_sha256")) {
                    if (recorded.record.charter_sha256) |digest| try s.write(@as([]const u8, &digest)) else try s.write(null);
                } else try s.write(null);
                try s.endObject();
            },
            .damaged => |damaged| try s.write(.{ .id = damaged.slice(), .status = "damaged" }),
        }
    }
    try s.endArray();
    try s.endObject();
    try out.writer.writeByte('\n');
    if (!pfs.writeAll(1, out.written())) return error.WriteFailed;
}

fn readOptional(arena: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const z = try arena.dupeZ(u8, path);
    const fd = pfs.openReadShared(z);
    if (fd < 0) return if (pfs.lastErrnoIs(.NOENT)) null else error.ReadFailed;
    defer pfs.close(fd);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(arena);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &buf);
        if (n < 0) {
            if (pfs.lastErrnoIs(.INTR)) continue;
            return error.ReadFailed;
        }
        if (n == 0) break;
        if (out.items.len + @as(usize, @intCast(n)) > 4 * 1024 * 1024) return error.InputTooLarge;
        try out.appendSlice(arena, buf[0..@intCast(n)]);
    }
    return try out.toOwnedSlice(arena);
}

fn readRequired(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try readOptional(arena, path) orelse error.FileNotFound;
}

/// Keep the external harness's writable login and metadata grants separate
/// from the original checkout and the run controller's state.
fn requireSeparateClaudeState(arena: std.mem.Allocator, home: []const u8, state_root: []const u8, repo: []const u8) !void {
    if (!std.fs.path.isAbsolute(home)) return error.InvalidClaudeHome;
    const physical_home = try physicalExisting(arena, home);
    const state = try physicalExisting(arena, state_root);
    const workspace = try physicalExisting(arena, repo);
    for (@import("drivers/claude_code.zig").claude_state_roots) |root| {
        const path = try std.fs.path.join(arena, &.{ physical_home, root[2..] });
        const physical = try physicalExisting(arena, path);
        if (within(state, physical) or within(physical, state) or within(workspace, physical) or within(physical, workspace))
            return error.ClaudeStateOverlapsRun;
    }
}

fn within(path: []const u8, root: []const u8) bool {
    if (eq(path, root)) return true;
    return root.len > 0 and path.len > root.len and std.mem.startsWith(u8, path, root) and
        (std.fs.path.isSep(root[root.len - 1]) or std.fs.path.isSep(path[root.len]));
}

fn physicalExisting(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const z = try arena.dupeZ(u8, path);
    var buf: run_dir.PathBuf = undefined;
    if (pfs.finalPath(z, &buf)) |physical| return arena.dupe(u8, std.mem.span(physical));
    return path;
}

fn requireExternalState(arena: std.mem.Allocator, state_root: []const u8, repo: []const u8) !void {
    if (!std.fs.path.isAbsolute(state_root)) return error.StateRootNotAbsolute;
    const normalized = try std.fs.path.resolve(arena, &.{state_root});
    // Resolve the deepest existing ancestor, including symlinks, before
    // comparing. App may create the missing suffix only after approval.
    var end = normalized.len;
    while (true) {
        const z = try arena.dupeZ(u8, normalized[0..end]);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (pfs.finalPath(z, &buf)) |physical| {
            const joined = try std.fmt.allocPrint(arena, "{s}{s}", .{ std.mem.span(physical), normalized[end..] });
            if (eq(joined, repo) or (std.mem.startsWith(u8, joined, repo) and joined.len > repo.len and (joined[repo.len] == '/' or joined[repo.len] == '\\')))
                return error.StateRootInsideRepository;
            return;
        }
        if (pfs.isSymlink(z)) return error.StateRootUnresolvable;
        const parent = std.fs.path.dirname(normalized[0..end]) orelse return error.StateRootUnresolvable;
        if (parent.len == end) return error.StateRootUnresolvable;
        end = parent.len;
    }
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "teamwork command: the approved policy keeps parallel candidates and the judge for resume" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const claude = if (@import("builtin").os.tag == .windows) "C:/tools/claude.exe" else "/opt/claude/bin/claude";
    for ([_][]const u8{
        "{\"enabled\":true,\"budget_usd\":5,\"candidates\":[{\"model\":\"m\"},{\"harness\":\"claude_code\",\"command\":\"" ++ claude ++ "\",\"budget_enforcement\":\"wallclock_only\",\"wallclock_seconds\":60}],\"candidate_estimate_usd\":0.5,\"seats\":{\"judge\":{\"model\":\"j\",\"effort\":\"high\"}}}",
        "{\"enabled\":true,\"budget_usd\":5,\"candidates\":3,\"candidate_estimate_usd\":1,\"check_command\":\"zig build test\"}",
        "{\"enabled\":true,\"budget_usd\":5}",
    }) |text| {
        const cfg = (try config.validate(try config.parse(a, text, null), null)).enabled;
        const restored = (try config.validate(try config.parse(a, try policyJson(a, cfg), null), null)).enabled;
        try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, cfg, .{}), try std.json.Stringify.valueAlloc(a, restored, .{}));
    }
}
