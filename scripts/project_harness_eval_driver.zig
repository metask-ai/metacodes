//! Zero-provider causal calibration driver for project-specific Harness rules.
//!
//! One process executes one arm/case in a fresh caller-owned directory.  It
//! uses the real `tool_exec.executeOne` seam, the real fixed Lean kernel for
//! governed arms, and the durable observation journal.  It deliberately does
//! not call an LLM and marks its result as mechanism-only evidence.

const std = @import("std");
const cc = @import("cc");

const Arm = enum {
    signal_only,
    static_enforced,
    evolved_shadow,
    evolved_enforced,
};

const Case = enum {
    existing_overwrite,
    existing_recovery,
    new_file,
    edit_existing,
    directory_target,
};

const Options = struct {
    root: []const u8,
    arm: Arm,
    case: Case,
    kernel_path: []const u8,
    kernel_sha256: [64]u8,
};

const ToolOutcome = struct {
    is_error: bool,
    host_fatal: bool,
};

const Result = struct {
    schema_version: []const u8 = "metacodes-project-harness-zero-paid-rollout-v2",
    quality_evidence: bool = false,
    provider_requests: u64 = 0,
    paid_cost_usd: f64 = 0,
    arm: Arm,
    case: Case,
    oracle_class: []const u8,
    project_sha256: []const u8,
    candidate_sha256: ?[]const u8,
    rule_spec_sha256: ?[]const u8,
    bundle_sha256: ?[]const u8,
    kernel_sha256: []const u8,
    session_id: []const u8,
    run_id: []const u8,
    first_sequence: u64,
    last_sequence: u64,
    journal_sha256: []const u8,
    first_tool_error: bool,
    host_fatal: bool,
    recovery_attempted: bool,
    task_success: bool,
    artifact_paths: struct {
        journal: []const u8,
        result: []const u8,
    },
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const options = try parseOptions(args);
    if (!std.fs.path.isAbsolute(options.root) or
        !std.fs.path.isAbsolute(options.kernel_path))
        return error.AbsolutePathRequired;

    try cc.util_fs.mkdirParents(options.root);
    const result_path = try std.fmt.allocPrint(
        allocator,
        "{s}/driver-result.json",
        .{options.root},
    );
    if (try pathExists(init.io, result_path)) return error.ResultAlreadyExists;
    const session_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/0123456789abcdef01234567",
        .{options.root},
    );
    try cc.util_fs.mkdirParents(session_dir);

    const config = cc.project_harness_runtime.Config{
        .checker_path = options.kernel_path,
        .expected_sha256 = options.kernel_sha256,
    };
    var active: ?cc.project_rule_bundle.LoadedActive = null;
    defer if (active) |*value| value.deinit();
    var runtime: ?cc.project_rule_gate.RuntimeGate = null;

    const sid = cc.session_id.SessionId.fromSlice("0123456789abcdef01234567").?;
    var journal = try cc.tool_observation_journal.Journal.init(session_dir, sid);
    var journal_live = true;
    defer if (journal_live) journal.deinit();
    const sink = journal.sink();

    if (options.arm != .signal_only) {
        active = try syntheticActive(allocator, options.root, options.arm, config);
        runtime = .{
            .allocator = allocator,
            .active = &active.?,
            .config = config,
            .abort = null,
            .actuation = if (options.arm == .evolved_shadow) .shadow else .enforced,
            .evidence_dir = session_dir,
            .observation_sink = sink,
        };
    }

    var ctx = cc.tool_context.ToolContext.simple(allocator);
    ctx.cwd_abs = options.root;
    ctx.home_dir = options.root;
    ctx.tool_observer = sink;
    if (runtime) |*gate| ctx.project_rule_gate = gate.protocolGate();

    const target_path = switch (options.case) {
        .directory_target => options.root,
        else => try std.fmt.allocPrint(allocator, "{s}/target.txt", .{options.root}),
    };
    switch (options.case) {
        .existing_overwrite, .existing_recovery, .edit_existing => try std.Io.Dir.cwd().writeFile(init.io, .{
            .sub_path = target_path,
            .data = "old",
        }),
        .new_file, .directory_target => {},
    }

    var first: ToolOutcome = undefined;
    var recovery_attempted = false;
    switch (options.case) {
        .existing_overwrite, .existing_recovery, .new_file, .directory_target => {
            const input = try std.json.Stringify.valueAlloc(allocator, .{
                .file_path = target_path,
                .content = "new",
            }, .{});
            first = try execute(&ctx, "Write", input, "attempt-1", allocator);
            if (options.case == .existing_recovery and first.is_error and !first.host_fatal) {
                recovery_attempted = true;
                const edit_input = try std.json.Stringify.valueAlloc(allocator, .{
                    .file_path = target_path,
                    .old_string = "old",
                    .new_string = "new",
                }, .{});
                const recovered = try execute(
                    &ctx,
                    "Edit",
                    edit_input,
                    "recovery-edit",
                    allocator,
                );
                first.host_fatal = first.host_fatal or recovered.host_fatal;
            }
        },
        .edit_existing => {
            const input = try std.json.Stringify.valueAlloc(allocator, .{
                .file_path = target_path,
                .old_string = "old",
                .new_string = "new",
            }, .{});
            first = try execute(&ctx, "Edit", input, "attempt-1", allocator);
        },
    }

    const task_success = if (options.case == .directory_target)
        first.is_error and !first.host_fatal
    else
        try fileEquals(init.io, allocator, target_path, "new");
    try journal.finishRun(if (first.host_fatal) "host_fatal" else "end_turn");
    const binding = try journal.runBinding();
    journal.deinit();
    journal_live = false;
    const validated = try cc.tool_observation_journal.validate(session_dir, sid);

    var candidate_sha: ?[64]u8 = null;
    var spec_sha: ?[64]u8 = null;
    var bundle_sha: ?[64]u8 = null;
    if (active) |*value| {
        candidate_sha = parseHex(value.rules[0].candidate_id) orelse
            return error.InvalidCandidateIdentity;
        const spec = try cc.project_rule_spec.fromWire(value.rules[0].rule_spec);
        const canonical = try cc.project_rule_spec.renderCanonical(allocator, spec);
        spec_sha = cc.tools.tool_observation.sha256Hex(canonical);
        bundle_sha = value.bundle_sha256;
    }
    const project = cc.project_rule_bundle.projectIdentity(options.root);
    const journal_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ session_dir, cc.tool_observation_journal.FILE_NAME },
    );
    const result = Result{
        .arm = options.arm,
        .case = options.case,
        .oracle_class = switch (options.case) {
            .existing_overwrite, .existing_recovery, .directory_target => "hazard",
            .new_file, .edit_existing => "safe",
        },
        .project_sha256 = project[0..],
        .candidate_sha256 = if (candidate_sha) |*value| value[0..] else null,
        .rule_spec_sha256 = if (spec_sha) |*value| value[0..] else null,
        .bundle_sha256 = if (bundle_sha) |*value| value[0..] else null,
        .kernel_sha256 = options.kernel_sha256[0..],
        .session_id = binding.session_id.asSlice(),
        .run_id = binding.run_id.asSlice(),
        .first_sequence = binding.first_sequence,
        .last_sequence = binding.last_sequence,
        .journal_sha256 = validated.artifact_sha256[0..],
        .first_tool_error = first.is_error,
        .host_fatal = first.host_fatal,
        .recovery_attempted = recovery_attempted,
        .task_success = task_success,
        .artifact_paths = .{
            .journal = journal_path,
            .result = result_path,
        },
    };
    const result_json = try std.json.Stringify.valueAlloc(allocator, result, .{});
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = result_path,
        .data = result_json,
    });
}

fn parseOptions(args: []const []const u8) !Options {
    if (args.len != 11) return error.InvalidArguments;
    var root: ?[]const u8 = null;
    var arm: ?Arm = null;
    var case: ?Case = null;
    var kernel_path: ?[]const u8 = null;
    var kernel_sha: ?[64]u8 = null;
    var index: usize = 1;
    while (index + 1 < args.len) : (index += 2) {
        const key = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, key, "--root")) {
            if (root != null) return error.DuplicateArgument;
            root = value;
        } else if (std.mem.eql(u8, key, "--arm")) {
            if (arm != null) return error.DuplicateArgument;
            arm = std.meta.stringToEnum(Arm, value) orelse return error.InvalidArm;
        } else if (std.mem.eql(u8, key, "--case")) {
            if (case != null) return error.DuplicateArgument;
            case = std.meta.stringToEnum(Case, value) orelse return error.InvalidCase;
        } else if (std.mem.eql(u8, key, "--kernel")) {
            if (kernel_path != null) return error.DuplicateArgument;
            kernel_path = value;
        } else if (std.mem.eql(u8, key, "--kernel-sha256")) {
            if (kernel_sha != null) return error.DuplicateArgument;
            kernel_sha = parseHex(value) orelse return error.InvalidKernelSha256;
        } else return error.UnknownArgument;
    }
    return .{
        .root = root orelse return error.MissingRoot,
        .arm = arm orelse return error.MissingArm,
        .case = case orelse return error.MissingCase,
        .kernel_path = kernel_path orelse return error.MissingKernel,
        .kernel_sha256 = kernel_sha orelse return error.MissingKernelSha256,
    };
}

fn syntheticActive(
    allocator: std.mem.Allocator,
    root: []const u8,
    arm: Arm,
    config: cc.project_harness_runtime.Config,
) !cc.project_rule_bundle.LoadedActive {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const spec: cc.project_rule_spec.Spec = switch (arm) {
        .static_enforced => .{
            .target = .{ .tool = "Write" },
            .deny_target = false,
            .max_input_bytes = 8192,
            .max_agent_depth = 4,
            .authoritative_only = true,
            .effect_requirement = .file_mutation_v1_reobserved,
        },
        .evolved_shadow, .evolved_enforced => .{
            .target = .{ .tool = "Write" },
            .target_scope = .existing_file,
            .deny_target = true,
            .max_input_bytes = 8192,
            .max_agent_depth = 4,
            .authoritative_only = true,
            .effect_requirement = .none,
        },
        .signal_only => return error.SignalOnlyHasNoActiveBundle,
    };
    const canonical = try cc.project_rule_spec.renderCanonical(a, spec);
    const candidate = cc.tools.tool_observation.sha256Hex(canonical);
    const bundle = cc.tools.tool_observation.sha256Hex(if (arm == .static_enforced)
        "metacodes-static-project-rule-bundle-v1"
    else
        "metacodes-evolved-project-rule-bundle-v1");
    const rules = try a.alloc(cc.project_rule_bundle.RuleEntry, 1);
    rules[0] = .{
        .candidate_id = try a.dupe(u8, &candidate),
        .rule_spec = cc.project_rule_spec.toWire(spec),
    };
    return .{
        .arena = arena,
        .project_sha256 = cc.project_rule_bundle.projectIdentity(root),
        .bundle_sha256 = bundle,
        .revision = 1,
        .kernel_sha256 = config.expected_sha256,
        .promotion_receipt_id = cc.tools.tool_observation.sha256Hex("eval-promotion"),
        .promotion_request_sha256 = cc.tools.tool_observation.sha256Hex("eval-request"),
        .promotion_verdict_sha256 = cc.tools.tool_observation.sha256Hex("eval-verdict"),
        .active_pointer_sha256 = cc.tools.tool_observation.sha256Hex("eval-active"),
        .rules = rules,
    };
}

fn execute(
    ctx: *cc.tool_context.ToolContext,
    tool: []const u8,
    input: []const u8,
    id: []const u8,
    allocator: std.mem.Allocator,
) !ToolOutcome {
    const outcome = try cc.tool_exec.executeOne(
        ctx,
        tool,
        input,
        id,
        allocator,
        cc.util_log.RequestId{ .bytes = [_]u8{'e'} ** 12 },
    );
    return switch (outcome) {
        .done => |done| blk: {
            defer if (done.content) |bytes| allocator.free(bytes);
            break :blk .{ .is_error = done.is_error, .host_fatal = false };
        },
        .host_fatal => .{ .is_error = true, .host_fatal = true },
        else => .{ .is_error = true, .host_fatal = false },
    };
}

fn fileEquals(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    expected: []const u8,
) !bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(1024 * 1024),
    ) catch return false;
    return std.mem.eql(u8, bytes, expected);
}

fn pathExists(io: std.Io, path: []const u8) !bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close(io);
    return true;
}

fn parseHex(value: []const u8) ?[64]u8 {
    if (value.len != 64) return null;
    var out: [64]u8 = undefined;
    for (value, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f'))
            return null;
        out[index] = byte;
    }
    return out;
}
