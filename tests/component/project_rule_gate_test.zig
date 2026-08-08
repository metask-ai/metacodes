//! L2: candidate lifecycle -> fixed Lean promotion -> hash-pinned active
//! bundle -> actual executeOne pre gate. No provider request is involved.

const std = @import("std");
const builtin = @import("builtin");
const cc = @import("cc");
const pfs = @import("platform").fs;

const GovernedGateProbe = struct {
    pre_calls: usize = 0,
    post_calls: usize = 0,
    last_outcome: ?cc.tools.tool_observation.Outcome = null,

    fn pre(raw: *anyopaque, _: cc.project_rule_gate_protocol.PreSignal) cc.project_rule_gate_protocol.Result {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.pre_calls += 1;
        return .admit;
    }

    fn post(raw: *anyopaque, signal: cc.project_rule_gate_protocol.PostSignal) cc.project_rule_gate_protocol.Result {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.post_calls += 1;
        self.last_outcome = signal.outcome;
        return .admit;
    }

    fn gate(self: *@This()) cc.project_rule_gate_protocol.Gate {
        return .{ .ctx = @ptrCast(self), .preFn = pre, .postFn = post };
    }
};

fn parseHex(value: []const u8) ?[64]u8 {
    if (value.len != 64) return null;
    var result: [64]u8 = undefined;
    for (value, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
        result[index] = byte;
    }
    return result;
}

fn testKernel() ?cc.project_harness_runtime.Config {
    if (builtin.os.tag == .windows) return null;
    const path_raw = std.c.getenv("METACODES_TEST_PROJECT_KERNEL_PATH") orelse return null;
    const hash_raw = std.c.getenv("METACODES_TEST_PROJECT_KERNEL_SHA256") orelse return null;
    const path = std.mem.span(path_raw);
    const hash = parseHex(std.mem.span(hash_raw)) orelse return null;
    if (!std.fs.path.isAbsolute(path)) return null;
    return .{ .checker_path = path, .expected_sha256 = hash };
}

const Probe = struct {
    calls: usize = 0,

    fn dispatch(
        raw: *const anyopaque,
        tool_ctx: *const cc.tool_context.ToolContext,
        _: []const u8,
        args: []const u8,
    ) anyerror!cc.tools.ToolDispatchOutcome {
        const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
        self.calls += 1;
        return .{ .ok = try tool_ctx.allocator.dupe(u8, args) };
    }
    fn prefetchSafe(_: *const anyopaque, _: []const u8) bool {
        return false;
    }
    fn nameAt(_: *const anyopaque, _: usize) ?[]const u8 {
        return null;
    }
    fn hostSync(_: *const anyopaque, _: []const u8) bool {
        return false;
    }
    fn dispatcher(self: *Probe) cc.tools.ToolDispatcher {
        return .{
            .ctx = @ptrCast(self),
            .dispatchFn = dispatch,
            .prefetchSafeFn = prefetchSafe,
            .nameAtFn = nameAt,
            .hostSyncFn = hostSync,
        };
    }
};

fn readArtifact(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ArtifactOpenFailed;
    defer _ = pfs.close(fd);
    const info = try pfs.fileInfo(fd);
    if (!info.is_regular or info.size == 0 or info.size > 8 * 1024 * 1024)
        return error.InvalidArtifact;
    const bytes = try allocator.alloc(u8, @intCast(info.size));
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.read(fd, bytes[offset..]);
        if (count <= 0) return error.ArtifactReadFailed;
        offset += @intCast(count);
    }
    return bytes;
}

fn overwriteArtifact(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .NOFOLLOW = true,
    }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.ArtifactOpenFailed;
    defer _ = pfs.close(fd);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.write(fd, bytes[offset..]);
        if (count <= 0) return error.ArtifactWriteFailed;
        offset += @intCast(count);
    }
    try pfs.fsyncChecked(fd);
}

test "L2 governed executeOne rejects detached Bash and Monitor before process creation" {
    const allocator = std.testing.allocator;
    var jobs = try cc.job_registry.JobRegistry.init(allocator);
    defer jobs.deinit();
    var probe = GovernedGateProbe{};
    var ctx = cc.tool_context.ToolContext.simple(allocator);
    ctx.jobs = &jobs;
    ctx.project_rule_gate = probe.gate();

    const explicit = try cc.tool_exec.executeOne(
        &ctx,
        "Bash",
        "{\"command\":\"echo must-not-spawn\",\"run_in_background\":true}",
        "governed-bash-explicit",
        allocator,
        .{ .bytes = [_]u8{'0'} ** 12 },
    );
    switch (explicit) {
        .done => |done| {
            defer if (done.content) |bytes| allocator.free(bytes);
            try std.testing.expect(done.is_error);
            try std.testing.expect(std.mem.indexOf(
                u8,
                done.content orelse return error.MissingToolError,
                "project_rule_blocked",
            ) != null);
        },
        else => return error.UnexpectedToolResult,
    }
    try std.testing.expectEqual(@as(usize, 0), jobs.jobs.items.len);
    try std.testing.expectEqual(@as(usize, 0), jobs.runningCount());

    // A normal Bash remains usable, but the governed path must bypass
    // JobRegistry entirely so it cannot auto-background after 15 seconds.
    const foreground = try cc.tool_exec.executeOne(
        &ctx,
        "Bash",
        "{\"command\":\"echo governed-sync\"}",
        "governed-bash-foreground",
        allocator,
        .{ .bytes = [_]u8{'0'} ** 12 },
    );
    switch (foreground) {
        .done => |done| {
            defer if (done.content) |bytes| allocator.free(bytes);
            try std.testing.expect(!done.is_error);
            try std.testing.expect(std.mem.indexOf(
                u8,
                done.content orelse return error.MissingToolResult,
                "governed-sync",
            ) != null);
        },
        else => return error.UnexpectedToolResult,
    }
    try std.testing.expectEqual(@as(usize, 0), jobs.jobs.items.len);

    const monitor = try cc.tool_exec.executeOne(
        &ctx,
        "Monitor",
        "{\"command\":\"echo must-not-monitor\",\"description\":\"blocked monitor\"}",
        "governed-monitor",
        allocator,
        .{ .bytes = [_]u8{'0'} ** 12 },
    );
    switch (monitor) {
        .done => |done| {
            defer if (done.content) |bytes| allocator.free(bytes);
            try std.testing.expect(done.is_error);
            try std.testing.expect(std.mem.indexOf(
                u8,
                done.content orelse return error.MissingToolError,
                "project_rule_blocked",
            ) != null);
        },
        else => return error.UnexpectedToolResult,
    }
    try std.testing.expectEqual(@as(usize, 0), jobs.jobs.items.len);
    try std.testing.expectEqual(@as(usize, 3), probe.pre_calls);
    try std.testing.expectEqual(@as(usize, 3), probe.post_calls);
    try std.testing.expectEqual(
        cc.tools.tool_observation.Outcome.tool_error,
        probe.last_outcome orelse return error.MissingPostVerdict,
    );
}

const VerifiedBuildFixture = struct {
    recorded: cc.rule_build_bundle.Recorded,
    trusted: cc.rule_build_bundle.TrustedFiles,
    owned_paths: [3][]u8,

    fn deinit(self: *VerifiedBuildFixture, allocator: std.mem.Allocator) void {
        for (self.owned_paths) |path| allocator.free(path);
        self.* = undefined;
    }
};

/// Construct actual on-disk build artifacts, then let the production host
/// verifier persist and reopen the content-addressed evidence before it emits
/// build/axiom receipts.  The compiled bytes are fixture data; the separate
/// isolated-builder test proves that the producer emits a real Lean `.olean`.
fn recordVerifiedBuild(
    allocator: std.mem.Allocator,
    evidence_dir: []const u8,
    candidate_id: [64]u8,
    project: [64]u8,
) !VerifiedBuildFixture {
    const source_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/build-source-{s}",
        .{ evidence_dir, candidate_id[0..] },
    );
    defer allocator.free(source_dir);
    try cc.util_fs.mkdirParents(source_dir);

    var candidate = try cc.rule_candidate.load(allocator, evidence_dir, candidate_id);
    defer candidate.deinit();
    const spec = try cc.project_rule_spec.renderCanonical(allocator, candidate.rule_spec);
    defer allocator.free(spec);
    const export_output = try std.fmt.allocPrint(allocator, "{s}\n", .{spec});
    defer allocator.free(export_output);
    const audit = "'CandidateRule.spec_valid' does not depend on any axioms\n";

    var result: VerifiedBuildFixture = .{
        .recorded = undefined,
        .trusted = undefined,
        .owned_paths = undefined,
    };
    var owned_count: usize = 0;
    errdefer for (result.owned_paths[0..owned_count]) |path| allocator.free(path);
    const trusted_names = [_][]const u8{ "trusted-lake", "trusted-sdk.lean", "trusted-sdk.olean" };
    const trusted_contents = [_][]const u8{ "lake-binary", "sdk-source", "sdk-olean" };
    for (trusted_names, trusted_contents, 0..) |name, bytes, index| {
        result.owned_paths[index] = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}-{s}",
            .{ evidence_dir, name, candidate_id[0..] },
        );
        owned_count += 1;
        try overwriteArtifact(allocator, result.owned_paths[index], bytes);
    }
    result.trusted = .{
        .toolchain_path = result.owned_paths[0],
        .sdk_source_path = result.owned_paths[1],
        .sdk_olean_path = result.owned_paths[2],
    };

    const authoritative_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}{s}.json",
        .{ evidence_dir, cc.rule_candidate.FILE_PREFIX, candidate_id[0..] },
    );
    defer allocator.free(authoritative_path);
    const authoritative = try readArtifact(allocator, authoritative_path);
    defer allocator.free(authoritative);
    const artifact_contents = [_][]const u8{
        authoritative,
        spec,
        "olean-evidence",
        "",
        "",
        export_output,
        "",
        audit,
        "",
    };
    var artifact_hashes: [cc.rule_build_bundle.ARTIFACT_NAMES.len][64]u8 = undefined;
    var records: [cc.rule_build_bundle.ARTIFACT_NAMES.len]cc.rule_build_bundle.FileRecord = undefined;
    for (cc.rule_build_bundle.ARTIFACT_NAMES, artifact_contents, 0..) |name, bytes, index| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ source_dir, name });
        defer allocator.free(path);
        try overwriteArtifact(allocator, path, bytes);
        artifact_hashes[index] = cc.tools.tool_observation.sha256Hex(bytes);
        records[index] = .{ .name = name, .bytes = bytes.len, .sha256 = artifact_hashes[index][0..] };
    }
    const source_sha = candidate.lean_source_sha256;
    const spec_sha = cc.tools.tool_observation.sha256Hex(spec);
    const compiled_sha = cc.tools.tool_observation.sha256Hex(artifact_contents[2]);
    const toolchain_sha = cc.tools.tool_observation.sha256Hex(trusted_contents[0]);
    const sdk_sha = cc.tools.tool_observation.sha256Hex(trusted_contents[1]);
    const sdk_olean_sha = cc.tools.tool_observation.sha256Hex(trusted_contents[2]);
    const manifest = cc.rule_build_bundle.Manifest{
        .schema_version = cc.rule_build_bundle.MANIFEST_SCHEMA,
        .candidate_id = candidate_id[0..],
        .project_sha256 = project[0..],
        .lean_source_sha256 = source_sha[0..],
        .rule_spec_sha256 = spec_sha[0..],
        .compiled_artifact_sha256 = compiled_sha[0..],
        .compiled_artifact_bytes = artifact_contents[2].len,
        .toolchain_sha256 = toolchain_sha[0..],
        .toolchain_bytes = trusted_contents[0].len,
        .sdk_sha256 = sdk_sha[0..],
        .sdk_bytes = trusted_contents[1].len,
        .sdk_olean_sha256 = sdk_olean_sha[0..],
        .sdk_olean_bytes = trusted_contents[2].len,
        .axiom_policy = "empty",
        .forbidden_declaration_count = 0,
        .unexpected_axiom_count = 0,
        .network_disabled = true,
        .secrets_absent = true,
        .source_bounded = true,
        .output_bounded = true,
        .isolation_backend = "macos-seatbelt-v1",
        .compile_elapsed_ns = 1,
        .export_elapsed_ns = 1,
        .axiom_elapsed_ns = 1,
        .files = &records,
        .completion_marker = true,
    };
    const manifest_bytes = try std.json.Stringify.valueAlloc(allocator, manifest, .{});
    defer allocator.free(manifest_bytes);
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{source_dir});
    defer allocator.free(manifest_path);
    try overwriteArtifact(allocator, manifest_path, manifest_bytes);
    result.recorded = try cc.rule_build_bundle.verifyAndRecord(
        allocator,
        evidence_dir,
        source_dir,
        candidate_id,
        project,
        result.trusted,
        .{
            .builder_sha256 = .{'c'} ** 64,
            .build_checker_sha256 = .{'1'} ** 64,
            .auditor_sha256 = .{'d'} ** 64,
            .axiom_checker_sha256 = .{'2'} ** 64,
        },
    );
    return result;
}

fn loadAndDispatchProbe(
    allocator: std.mem.Allocator,
    rules_dir: []const u8,
    project: [64]u8,
    config: cc.project_harness_runtime.Config,
    probe: *Probe,
) !void {
    var active = (try cc.project_rule_bundle.loadVerifiedActive(
        allocator,
        rules_dir,
        project,
        config,
        null,
    )) orelse return error.MissingActiveBundle;
    defer active.deinit();
    var runtime = cc.project_rule_gate.RuntimeGate{
        .allocator = allocator,
        .active = &active,
        .config = config,
        .abort = null,
    };
    var ctx = cc.tool_context.ToolContext.simple(allocator);
    ctx.tool_dispatcher = probe.dispatcher();
    ctx.project_rule_gate = runtime.protocolGate();
    const result = try cc.tool_exec.executeOne(
        &ctx,
        "Read",
        "{}",
        "tamper-probe",
        allocator,
        .{ .bytes = [_]u8{'0'} ** 12 },
    );
    switch (result) {
        .done => |done| {
            if (done.content) |bytes| allocator.free(bytes);
            if (done.is_error) return error.UnexpectedToolError;
        },
        else => return error.UnexpectedToolResult,
    }
}

test "L2 promoted Lean deny rule blocks the real dispatcher before side effects" {
    const config = testKernel() orelse return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const evidence_dir = try std.fmt.allocPrint(allocator, "{s}/evidence", .{root});
    defer allocator.free(evidence_dir);
    const rules_dir = try std.fmt.allocPrint(allocator, "{s}/project-rules", .{root});
    defer allocator.free(rules_dir);
    try cc.util_fs.mkdirParents(evidence_dir);
    const project = cc.project_rule_bundle.projectIdentity(root);

    const sid = cc.session_id.SessionId.fromSlice("0123456789abcdef01234567").?;
    var journal = try cc.tool_observation_journal.Journal.init(evidence_dir, sid);
    const sink = journal.sink();
    try std.testing.expect(sink.emit(.{ .dispatch_started = .{
        .id = "shadow-read",
        .requested_name = "Read",
        .dispatched_name = "Read",
        .origin = .authoritative,
        .agent_depth = 0,
        .input_bytes = 2,
        .input_sha256 = cc.tools.tool_observation.sha256Hex("{}"),
    } }));
    try std.testing.expect(sink.emit(.{ .dispatch_finished = .{
        .id = "shadow-read",
        .requested_name = "Read",
        .dispatched_name = "Read",
        .origin = .authoritative,
        .agent_depth = 0,
        .outcome = .succeeded,
        .error_code = null,
        .elapsed_ms = 1,
        .result_present = true,
        .result_bytes = 2,
        .result_sha256 = cc.tools.tool_observation.sha256Hex("ok"),
        .effect = null,
        .effect_valid = true,
    } }));
    try journal.finishRun("end_turn");
    const binding = try journal.runBinding();
    journal.deinit();
    const proposer = [_]u8{'b'} ** 64;
    const candidate = try cc.rule_candidate.persist(evidence_dir, .{
        .project_sha256 = project,
        .proposer_sha256 = proposer,
        .invariant = "Project policy denies Write before dispatch.",
        .rule_spec = .{
            .target_tool = "Write",
            .deny_target = true,
            .max_input_bytes = 8192,
            .max_agent_depth = 4,
            .authoritative_only = true,
            .effect_requirement = .none,
        },
        .lean_source = "def spec : RuleSpec := { targetTool := \"Write\", denyTarget := true, maxInputBytes := 8192, maxAgentDepth := 4, authoritativeOnly := true, effectRequirement := .none }; theorem spec_valid : valid spec = true := by rfl",
        .source = .{ .agent_reflection = .{
            .observation = binding,
            .reflector_sha256 = proposer,
            .falsifier = "A Write reaches the dispatcher while this bundle is active.",
        } },
    });
    var build = try recordVerifiedBuild(allocator, evidence_dir, candidate.candidate_id, project);
    defer build.deinit(allocator);
    const replay_cases = [_]cc.rule_evaluation.ReplayCase{
        .{
            .case_id = "read-is-admitted",
            .expected_admit = true,
            .signal = .{ .pre = .{
                .tool = "Read",
                .input_bytes = 2,
                .agent_depth = 0,
                .authoritative = true,
            } },
        },
        .{
            .case_id = "write-is-denied",
            .expected_admit = false,
            .signal = .{ .pre = .{
                .tool = "Write",
                .input_bytes = 2,
                .agent_depth = 0,
                .authoritative = true,
            } },
        },
    };
    const replay = try cc.rule_evaluation.evaluateAndRecordReplay(
        allocator,
        evidence_dir,
        evidence_dir,
        candidate.candidate_id,
        project,
        build.recorded.axiom_receipt_id,
        .{'e'} ** 64,
        config,
        &replay_cases,
    );
    const shadow_decisions = [_]cc.rule_evaluation.ShadowDecision{.{
        .decision_id = "shadow-read-pre",
        .dispatch_id = "shadow-read",
        .observed_admit = true,
        .signal = .{ .pre = .{
            .tool = "Read",
            .input_bytes = 2,
            .agent_depth = 0,
            .authoritative = true,
        } },
    }};
    const shadow = try cc.rule_evaluation.evaluateAndRecordShadow(
        allocator,
        evidence_dir,
        evidence_dir,
        candidate.candidate_id,
        project,
        replay.receipt_id,
        .{'f'} ** 64,
        config,
        binding,
        &shadow_decisions,
    );
    const stored_olean = try cc.rule_build_bundle.storedArtifactPath(
        allocator,
        evidence_dir,
        build.recorded.verified.manifest_sha256,
        "candidate.olean",
    );
    defer allocator.free(stored_olean);
    try overwriteArtifact(allocator, stored_olean, "tampered-build-evidence");
    try std.testing.expectError(error.BuildArtifactHashMismatch, cc.project_rule_bundle.promote(allocator, .{
        .evidence_dir = evidence_dir,
        .project_rules_dir = rules_dir,
        .candidate_id = candidate.candidate_id,
        .project_sha256 = project,
        .shadow_receipt_id = shadow.receipt_id,
        .promoter_sha256 = .{'7'} ** 64,
        .trusted_build_files = build.trusted,
        .config = config,
    }));
    try overwriteArtifact(allocator, stored_olean, "olean-evidence");
    const promoted = try cc.project_rule_bundle.promote(allocator, .{
        .evidence_dir = evidence_dir,
        .project_rules_dir = rules_dir,
        .candidate_id = candidate.candidate_id,
        .project_sha256 = project,
        .shadow_receipt_id = shadow.receipt_id,
        .promoter_sha256 = .{'7'} ** 64,
        .trusted_build_files = build.trusted,
        .config = config,
    });
    try std.testing.expectEqual(@as(u64, 1), promoted.revision);
    var active = (try cc.project_rule_bundle.loadVerifiedActive(
        allocator,
        rules_dir,
        project,
        config,
        null,
    )) orelse return error.MissingActiveBundle;
    defer active.deinit();
    var runtime = cc.project_rule_gate.RuntimeGate{
        .allocator = allocator,
        .active = &active,
        .config = config,
        .abort = null,
    };
    var probe = Probe{};
    var ctx = cc.tool_context.ToolContext.simple(allocator);
    ctx.tool_dispatcher = probe.dispatcher();
    ctx.project_rule_gate = runtime.protocolGate();
    const result = try cc.tool_exec.executeOne(
        &ctx,
        "Write",
        "{\"file_path\":\"never-created\",\"content\":\"blocked\"}",
        "formal-deny",
        allocator,
        .{ .bytes = [_]u8{'0'} ** 12 },
    );
    switch (result) {
        .done => |done| {
            defer if (done.content) |bytes| allocator.free(bytes);
            try std.testing.expect(done.is_error);
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, done.content.?, .{});
            defer parsed.deinit();
            const envelope = parsed.value.object.get("error") orelse return error.MissingErrorEnvelope;
            const code = envelope.object.get("code") orelse return error.MissingErrorCode;
            try std.testing.expectEqualStrings("project_rule_blocked", code.string);
        },
        else => return error.UnexpectedToolResult,
    }
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
}

fn promoteFixture(
    allocator: std.mem.Allocator,
    evidence_dir: []const u8,
    rules_dir: []const u8,
    project: [64]u8,
    config: cc.project_harness_runtime.Config,
    spec: cc.project_rule_spec.Spec,
    lean_source: []const u8,
) !cc.project_rule_bundle.PromoteResult {
    try cc.util_fs.mkdirParents(evidence_dir);
    const sid = cc.session_id.SessionId.fromSlice("fedcba9876543210fedcba98").?;
    var journal = try cc.tool_observation_journal.Journal.init(evidence_dir, sid);
    const sink = journal.sink();
    try std.testing.expect(sink.emit(.{ .dispatch_started = .{
        .id = "fixture-read",
        .requested_name = "Read",
        .dispatched_name = "Read",
        .origin = .authoritative,
        .agent_depth = 0,
        .input_bytes = 2,
        .input_sha256 = cc.tools.tool_observation.sha256Hex("{}"),
    } }));
    try std.testing.expect(sink.emit(.{ .dispatch_finished = .{
        .id = "fixture-read",
        .requested_name = "Read",
        .dispatched_name = "Read",
        .origin = .authoritative,
        .agent_depth = 0,
        .outcome = .succeeded,
        .error_code = null,
        .elapsed_ms = 1,
        .result_present = true,
        .result_bytes = 2,
        .result_sha256 = cc.tools.tool_observation.sha256Hex("ok"),
        .effect = null,
        .effect_valid = true,
    } }));
    try journal.finishRun("end_turn");
    const binding = try journal.runBinding();
    journal.deinit();

    const proposer = [_]u8{'b'} ** 64;
    const candidate = try cc.rule_candidate.persist(evidence_dir, .{
        .project_sha256 = project,
        .proposer_sha256 = proposer,
        .invariant = "Successful target effects satisfy the project rule.",
        .rule_spec = spec,
        .lean_source = lean_source,
        .source = .{ .agent_reflection = .{
            .observation = binding,
            .reflector_sha256 = proposer,
            .falsifier = "A concrete dispatch violates the promoted rule.",
        } },
    });
    var build = try recordVerifiedBuild(allocator, evidence_dir, candidate.candidate_id, project);
    defer build.deinit(allocator);
    const negative_bytes: usize = if (spec.deny_target)
        2
    else
        @intCast(spec.max_input_bytes + 1);
    const replay_cases = [_]cc.rule_evaluation.ReplayCase{
        .{
            .case_id = "unrelated-read-admitted",
            .expected_admit = true,
            .signal = .{ .pre = .{
                .tool = "Read",
                .input_bytes = 2,
                .agent_depth = 0,
                .authoritative = true,
            } },
        },
        .{
            .case_id = "target-negative",
            .expected_admit = false,
            .signal = .{ .pre = .{
                .tool = spec.target_tool,
                .input_bytes = negative_bytes,
                .agent_depth = 0,
                .authoritative = true,
            } },
        },
    };
    const replay = try cc.rule_evaluation.evaluateAndRecordReplay(
        allocator,
        evidence_dir,
        evidence_dir,
        candidate.candidate_id,
        project,
        build.recorded.axiom_receipt_id,
        .{'e'} ** 64,
        config,
        &replay_cases,
    );
    const shadow_decisions = [_]cc.rule_evaluation.ShadowDecision{.{
        .decision_id = "fixture-read-pre",
        .dispatch_id = "fixture-read",
        .observed_admit = true,
        .signal = .{ .pre = .{
            .tool = "Read",
            .input_bytes = 2,
            .agent_depth = 0,
            .authoritative = true,
        } },
    }};
    const shadow = try cc.rule_evaluation.evaluateAndRecordShadow(
        allocator,
        evidence_dir,
        evidence_dir,
        candidate.candidate_id,
        project,
        replay.receipt_id,
        .{'f'} ** 64,
        config,
        binding,
        &shadow_decisions,
    );
    return cc.project_rule_bundle.promote(allocator, .{
        .evidence_dir = evidence_dir,
        .project_rules_dir = rules_dir,
        .candidate_id = candidate.candidate_id,
        .project_sha256 = project,
        .shadow_receipt_id = shadow.receipt_id,
        .promoter_sha256 = .{'7'} ** 64,
        .trusted_build_files = build.trusted,
        .config = config,
    });
}

test "L2 active project rules fail closed before dispatch on artifact or kernel drift" {
    const config = testKernel() orelse return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const evidence_dir = try std.fmt.allocPrint(allocator, "{s}/evidence", .{root});
    defer allocator.free(evidence_dir);
    const rules_dir = try std.fmt.allocPrint(allocator, "{s}/project-rules", .{root});
    defer allocator.free(rules_dir);
    const project = cc.project_rule_bundle.projectIdentity(root);
    const promoted = try promoteFixture(
        allocator,
        evidence_dir,
        rules_dir,
        project,
        config,
        .{
            .target_tool = "Write",
            .deny_target = true,
            .max_input_bytes = 8192,
            .max_agent_depth = 4,
            .authoritative_only = true,
            .effect_requirement = .none,
        },
        "def spec : RuleSpec := { targetTool := \"Write\", denyTarget := true, maxInputBytes := 8192, maxAgentDepth := 4, authoritativeOnly := true, effectRequirement := .none }; theorem spec_valid : valid spec = true := by rfl",
    );
    const session_dir = try std.fmt.allocPrint(allocator, "{s}/session", .{root});
    defer allocator.free(session_dir);
    try cc.util_fs.mkdirParents(session_dir);
    try std.testing.expectError(
        error.ProjectObservationSinkMissing,
        cc.project_rule_activation.RunGate.load(
            allocator,
            session_dir,
            root,
            null,
            null,
        ),
    );

    const paths = [_][]u8{
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rules_dir, cc.project_rule_bundle.ACTIVE_FILE }),
        try std.fmt.allocPrint(allocator, "{s}/{s}{s}.json", .{ rules_dir, cc.project_rule_bundle.BUNDLE_PREFIX, promoted.bundle_sha256[0..] }),
        try std.fmt.allocPrint(allocator, "{s}/{s}{s}.json", .{ rules_dir, cc.rule_lifecycle.FILE_PREFIX, promoted.promotion_receipt_id[0..] }),
        try std.fmt.allocPrint(allocator, "{s}/{s}{s}.json", .{ rules_dir, cc.project_rule_bundle.REQUEST_PREFIX, promoted.request_sha256[0..] }),
        try std.fmt.allocPrint(allocator, "{s}/{s}{s}.json", .{ rules_dir, cc.project_rule_bundle.VERDICT_PREFIX, promoted.verdict_sha256[0..] }),
    };
    defer for (paths) |path| allocator.free(path);

    for (paths) |path| {
        const original = try readArtifact(allocator, path);
        defer allocator.free(original);
        try overwriteArtifact(allocator, path, "{}");
        var probe = Probe{};
        var rejected = false;
        loadAndDispatchProbe(allocator, rules_dir, project, config, &probe) catch {
            rejected = true;
        };
        try std.testing.expect(rejected);
        try std.testing.expectEqual(@as(usize, 0), probe.calls);
        try overwriteArtifact(allocator, path, original);
    }

    const incomplete_markers = [_][]const u8{
        cc.project_rule_bundle.ACTIVE_LOCK,
        cc.project_rule_bundle.ACTIVE_TEMP,
    };
    for (incomplete_markers) |marker| {
        const marker_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rules_dir, marker });
        defer allocator.free(marker_path);
        try overwriteArtifact(allocator, marker_path, "incomplete");
        var marker_probe = Probe{};
        var marker_rejected = false;
        loadAndDispatchProbe(allocator, rules_dir, project, config, &marker_probe) catch {
            marker_rejected = true;
        };
        try std.testing.expect(marker_rejected);
        try std.testing.expectEqual(@as(usize, 0), marker_probe.calls);
        const marker_z = try allocator.dupeZ(u8, marker_path);
        defer allocator.free(marker_z);
        try pfs.unlinkPath(marker_z.ptr);
    }

    if (builtin.os.tag != .windows) {
        const active_path = paths[0];
        const original = try readArtifact(allocator, active_path);
        defer allocator.free(original);
        const alias_path = try std.fmt.allocPrint(allocator, "{s}/active-hardlink-source.json", .{rules_dir});
        defer allocator.free(alias_path);
        try overwriteArtifact(allocator, alias_path, original);
        const active_z = try allocator.dupeZ(u8, active_path);
        defer allocator.free(active_z);
        const alias_z = try allocator.dupeZ(u8, alias_path);
        defer allocator.free(alias_z);
        try pfs.unlinkPath(active_z.ptr);
        if (std.c.link(alias_z.ptr, active_z.ptr) != 0) return error.SkipZigTest;
        var hardlink_probe = Probe{};
        var hardlink_rejected = false;
        loadAndDispatchProbe(allocator, rules_dir, project, config, &hardlink_probe) catch {
            hardlink_rejected = true;
        };
        try std.testing.expect(hardlink_rejected);
        try std.testing.expectEqual(@as(usize, 0), hardlink_probe.calls);
        try pfs.unlinkPath(active_z.ptr);
        try overwriteArtifact(allocator, active_path, original);
        try pfs.unlinkPath(alias_z.ptr);

        const missing_target = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/missing-active-target.json",
            .{rules_dir},
            0,
        );
        defer allocator.free(missing_target);
        try pfs.unlinkPath(active_z.ptr);
        if (std.c.symlink(missing_target.ptr, active_z.ptr) != 0) return error.SkipZigTest;
        var dangling_probe = Probe{};
        var dangling_rejected = false;
        loadAndDispatchProbe(allocator, rules_dir, project, config, &dangling_probe) catch {
            dangling_rejected = true;
        };
        try std.testing.expect(dangling_rejected);
        try std.testing.expectEqual(@as(usize, 0), dangling_probe.calls);
        try pfs.unlinkPath(active_z.ptr);
        try overwriteArtifact(allocator, active_path, original);
    }

    var wrong_hash = config.expected_sha256;
    wrong_hash[0] = if (wrong_hash[0] == '0') '1' else '0';
    var mismatch_probe = Probe{};
    var mismatch_rejected = false;
    loadAndDispatchProbe(allocator, rules_dir, project, .{
        .checker_path = config.checker_path,
        .expected_sha256 = wrong_hash,
        .timeout_ms = config.timeout_ms,
    }, &mismatch_probe) catch {
        mismatch_rejected = true;
    };
    try std.testing.expect(mismatch_rejected);
    try std.testing.expectEqual(@as(usize, 0), mismatch_probe.calls);

    // Restoring every artifact makes the exact same production loader and
    // executeOne path reach the dispatcher, proving the zero-call assertions
    // above are caused by fail-closed attestation rather than a dead fixture.
    var healthy_probe = Probe{};
    try loadAndDispatchProbe(allocator, rules_dir, project, config, &healthy_probe);
    try std.testing.expectEqual(@as(usize, 1), healthy_probe.calls);
}

test "L2 extending an active bundle reattests the prior promotion before mutation" {
    const config = testKernel() orelse return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const evidence_dir = try std.fmt.allocPrint(allocator, "{s}/evidence", .{root});
    defer allocator.free(evidence_dir);
    const rules_dir = try std.fmt.allocPrint(allocator, "{s}/project-rules", .{root});
    defer allocator.free(rules_dir);
    const project = cc.project_rule_bundle.projectIdentity(root);

    const first = try promoteFixture(
        allocator,
        evidence_dir,
        rules_dir,
        project,
        config,
        .{
            .target_tool = "Write",
            .deny_target = true,
            .max_input_bytes = 8192,
            .max_agent_depth = 4,
            .authoritative_only = true,
            .effect_requirement = .none,
        },
        "def spec : RuleSpec := { targetTool := \"Write\", denyTarget := true, maxInputBytes := 8192, maxAgentDepth := 4, authoritativeOnly := true, effectRequirement := .none }; theorem spec_valid : valid spec = true := by rfl",
    );
    try std.testing.expectEqual(@as(u64, 1), first.revision);

    const active_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ rules_dir, cc.project_rule_bundle.ACTIVE_FILE },
    );
    defer allocator.free(active_path);
    const active_before = try readArtifact(allocator, active_path);
    defer allocator.free(active_before);
    const verdict_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}{s}.json",
        .{ rules_dir, cc.project_rule_bundle.VERDICT_PREFIX, first.verdict_sha256[0..] },
    );
    defer allocator.free(verdict_path);
    const verdict_before = try readArtifact(allocator, verdict_path);
    defer allocator.free(verdict_before);
    try overwriteArtifact(allocator, verdict_path, "{}");

    try std.testing.expectError(
        error.PromotionVerdictHashMismatch,
        promoteFixture(
            allocator,
            evidence_dir,
            rules_dir,
            project,
            config,
            .{
                .target_tool = "Edit",
                .deny_target = true,
                .max_input_bytes = 4096,
                .max_agent_depth = 3,
                .authoritative_only = true,
                .effect_requirement = .none,
            },
            "def spec : RuleSpec := { targetTool := \"Edit\", denyTarget := true, maxInputBytes := 4096, maxAgentDepth := 3, authoritativeOnly := true, effectRequirement := .none }; theorem spec_valid : valid spec = true := by rfl",
        ),
    );
    const active_after = try readArtifact(allocator, active_path);
    defer allocator.free(active_after);
    try std.testing.expectEqualSlices(u8, active_before, active_after);
    const lock_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/{s}",
        .{ rules_dir, cc.project_rule_bundle.ACTIVE_LOCK },
        0,
    );
    defer allocator.free(lock_path);
    try std.testing.expect(!pfs.exists(lock_path.ptr));

    try overwriteArtifact(allocator, verdict_path, verdict_before);
    var restored = (try cc.project_rule_bundle.loadVerifiedActive(
        allocator,
        rules_dir,
        project,
        config,
        null,
    )) orelse return error.MissingActiveBundle;
    defer restored.deinit();
    try std.testing.expectEqual(@as(u64, 1), restored.revision);
    try std.testing.expectEqualSlices(u8, &first.bundle_sha256, &restored.bundle_sha256);
}

const VanishingWrite = struct {
    path: [:0]const u8,
    calls: usize = 0,

    fn dispatch(
        raw: *const anyopaque,
        tool_ctx: *const cc.tool_context.ToolContext,
        _: []const u8,
        _: []const u8,
    ) anyerror!cc.tools.ToolDispatchOutcome {
        const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
        self.calls += 1;
        const bytes = "vanished";
        const fd = pfs.open(self.path.ptr, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
            .NOFOLLOW = true,
        }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return .{ .host_failed = null };
        defer _ = pfs.close(fd);
        if (pfs.write(fd, bytes) != bytes.len) return .{ .host_failed = null };
        const effect = cc.tools.tool_observation.fileMutation(self.path, .missing, bytes).file_mutation_v1;
        tool_ctx.effect_slot.?.recordFileMutation(self.path, effect);
        try pfs.unlinkPath(self.path.ptr);
        return .{ .ok = try tool_ctx.allocator.dupe(u8, "claimed-success") };
    }
    fn prefetchSafe(_: *const anyopaque, _: []const u8) bool {
        return false;
    }
    fn nameAt(_: *const anyopaque, _: usize) ?[]const u8 {
        return null;
    }
    fn hostSync(_: *const anyopaque, _: []const u8) bool {
        return false;
    }
    fn dispatcher(self: *@This()) cc.tools.ToolDispatcher {
        return .{
            .ctx = @ptrCast(self),
            .dispatchFn = dispatch,
            .prefetchSafeFn = prefetchSafe,
            .nameAtFn = nameAt,
            .hostSyncFn = hostSync,
        };
    }
};

fn syntheticActive(
    allocator: std.mem.Allocator,
    rule_count: usize,
    config: cc.project_harness_runtime.Config,
) !cc.project_rule_bundle.LoadedActive {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const rules = try a.alloc(cc.project_rule_bundle.RuleEntry, rule_count);
    for (rules, 0..) |*rule, index| {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "batch-rule-{d}", .{index});
        const candidate = cc.tools.tool_observation.sha256Hex(name);
        rule.* = .{
            .candidate_id = try a.dupe(u8, &candidate),
            // The real dispatch below is Read. Every rule must therefore
            // admit independently in both phases while still producing one
            // candidate-bound verdict per entry.
            .rule_spec = cc.project_rule_spec.toWire(.{
                .target_tool = "Write",
                .deny_target = false,
                .max_input_bytes = 8192,
                .max_agent_depth = 4,
                .authoritative_only = true,
                .effect_requirement = .file_mutation_v1_reobserved,
            }),
        };
    }
    return .{
        .arena = arena,
        .project_sha256 = .{'a'} ** 64,
        .bundle_sha256 = .{'b'} ** 64,
        .revision = 7,
        .kernel_sha256 = config.expected_sha256,
        .promotion_receipt_id = .{'c'} ** 64,
        .promotion_request_sha256 = .{'d'} ** 64,
        .promotion_verdict_sha256 = .{'e'} ** 64,
        .active_pointer_sha256 = .{'f'} ** 64,
        .rules = rules,
    };
}

const BatchRuntimeStats = struct {
    elapsed_ns: u64,
    checker_elapsed_ns: u64,
};

fn runBatchRuntimeFixture(rule_count: usize) !BatchRuntimeStats {
    const config = testKernel() orelse return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const evidence_dir = try std.fmt.allocPrint(allocator, "{s}/evidence", .{root});
    defer allocator.free(evidence_dir);
    try cc.util_fs.mkdirParents(evidence_dir);

    var active = try syntheticActive(allocator, rule_count, config);
    defer active.deinit();
    var runtime = cc.project_rule_gate.RuntimeGate{
        .allocator = allocator,
        .active = &active,
        .config = config,
        .abort = null,
    };
    const sid = cc.session_id.SessionId.fromSlice("0123456789abcdef01234567").?;
    var journal = try cc.tool_observation_journal.Journal.init(evidence_dir, sid);
    const sink = journal.sink();
    runtime.evidence_dir = evidence_dir;
    runtime.observation_sink = sink;
    var probe = Probe{};
    var ctx = cc.tool_context.ToolContext.simple(allocator);
    ctx.tool_dispatcher = probe.dispatcher();
    ctx.project_rule_gate = runtime.protocolGate();
    ctx.tool_observer = sink;
    const dispatch_id = try std.fmt.allocPrint(allocator, "batch-runtime-{d}", .{rule_count});
    defer allocator.free(dispatch_id);
    const started = cc.util_time.nowNs();
    const result = try cc.tool_exec.executeOne(
        &ctx,
        "Read",
        "{}",
        dispatch_id,
        allocator,
        .{ .bytes = [_]u8{'0'} ** 12 },
    );
    const elapsed = cc.util_time.nowNs() - started;
    switch (result) {
        .done => |done| {
            if (done.content) |bytes| allocator.free(bytes);
            try std.testing.expect(!done.is_error);
        },
        else => return error.UnexpectedToolResult,
    }
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try journal.finishRun("end_turn");
    const binding = try journal.runBinding();
    journal.deinit();

    var observed = try cc.tool_observation_journal.loadRunDispatches(
        allocator,
        evidence_dir,
        binding,
    );
    defer observed.deinit();
    try std.testing.expectEqual(rule_count * 2, observed.formal_decisions.len);
    var pre_call: ?[64]u8 = null;
    var post_call: ?[64]u8 = null;
    var pre_count: usize = 0;
    var post_count: usize = 0;
    var pre_elapsed: u64 = 0;
    var post_elapsed: u64 = 0;
    for (observed.formal_decisions) |formal| {
        try std.testing.expectEqual(cc.tools.tool_observation.FormalResult.admit, formal.result);
        try std.testing.expectEqual(@as(u32, @intCast(rule_count)), formal.checker_batch_size);
        const call = formal.checker_call_sha256 orelse return error.MissingCheckerCallIdentity;
        switch (formal.phase) {
            .pre => {
                pre_count += 1;
                if (pre_call) |expected| {
                    try std.testing.expectEqualSlices(u8, &expected, &call);
                    try std.testing.expectEqual(pre_elapsed, formal.checker_elapsed_ns);
                } else {
                    pre_call = call;
                    pre_elapsed = formal.checker_elapsed_ns;
                }
            },
            .post => {
                post_count += 1;
                if (post_call) |expected| {
                    try std.testing.expectEqualSlices(u8, &expected, &call);
                    try std.testing.expectEqual(post_elapsed, formal.checker_elapsed_ns);
                } else {
                    post_call = call;
                    post_elapsed = formal.checker_elapsed_ns;
                }
            },
        }
    }
    try std.testing.expectEqual(rule_count, pre_count);
    try std.testing.expectEqual(rule_count, post_count);
    try std.testing.expect(!std.mem.eql(u8, &(pre_call orelse unreachable), &(post_call orelse unreachable)));
    const stats = BatchRuntimeStats{
        .elapsed_ns = @intCast(@max(elapsed, 0)),
        .checker_elapsed_ns = pre_elapsed + post_elapsed,
    };
    if (std.c.getenv("METACODES_BENCH_REPORT") != null) {
        std.debug.print("batch-runtime-metric rules={d} execute_ms={d:.3} checker_ms={d:.3}\n", .{
            rule_count,
            @as(f64, @floatFromInt(stats.elapsed_ns)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(stats.checker_elapsed_ns)) / std.time.ns_per_ms,
        });
    }
    return stats;
}

test "L2 project rule batch runtime uses two checker calls for 1 rule" {
    _ = try runBatchRuntimeFixture(1);
}

test "L2 project rule batch runtime uses two checker calls for 4 rules" {
    _ = try runBatchRuntimeFixture(4);
}

test "L2 project rule batch runtime uses two checker calls for 16 rules" {
    _ = try runBatchRuntimeFixture(16);
}

test "L2 project rule batch runtime uses two checker calls for 64 rules" {
    const stats = try runBatchRuntimeFixture(64);
    // A generous regression ceiling catches accidental reintroduction of 128
    // process spawns without turning a correctness test into a microbenchmark.
    try std.testing.expect(stats.elapsed_ns < 750 * std.time.ns_per_ms);
}

test "L2 malformed Lean batch verdict fails before the real dispatcher" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const evidence_dir = try std.fmt.allocPrint(allocator, "{s}/evidence", .{root});
    defer allocator.free(evidence_dir);
    try cc.util_fs.mkdirParents(evidence_dir);
    const checker_path = try std.fmt.allocPrint(allocator, "{s}/partial-batch-checker", .{root});
    defer allocator.free(checker_path);
    const checker_script =
        "#!/bin/sh\n" ++
        "printf '%s\\n' '{\"schema_version\":\"metacodes-project-harness-batch-verdict-v1\",\"checker_version\":\"metacodes-project-harness-kernel-v1\",\"verdicts\":[]}'\n";
    try overwriteArtifact(allocator, checker_path, checker_script);
    const checker_z = try allocator.dupeZ(u8, checker_path);
    defer allocator.free(checker_z);
    if (std.c.chmod(checker_z.ptr, 0o700) != 0) return error.SkipZigTest;
    const config = cc.project_harness_runtime.Config{
        .checker_path = checker_path,
        .expected_sha256 = cc.tools.tool_observation.sha256Hex(checker_script),
    };
    var active = try syntheticActive(allocator, 4, config);
    defer active.deinit();
    var runtime = cc.project_rule_gate.RuntimeGate{
        .allocator = allocator,
        .active = &active,
        .config = config,
        .abort = null,
    };
    const sid = cc.session_id.SessionId.fromSlice("0123456789abcdef01234567").?;
    var journal = try cc.tool_observation_journal.Journal.init(evidence_dir, sid);
    const sink = journal.sink();
    runtime.evidence_dir = evidence_dir;
    runtime.observation_sink = sink;
    var probe = Probe{};
    var ctx = cc.tool_context.ToolContext.simple(allocator);
    ctx.tool_dispatcher = probe.dispatcher();
    ctx.project_rule_gate = runtime.protocolGate();
    ctx.tool_observer = sink;
    const result = try cc.tool_exec.executeOne(
        &ctx,
        "Read",
        "{}",
        "malformed-batch",
        allocator,
        .{ .bytes = [_]u8{'0'} ** 12 },
    );
    try std.testing.expect(result == .host_fatal);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try journal.finishRun("HostToolFatal");
    const binding = try journal.runBinding();
    journal.deinit();
    var observed = try cc.tool_observation_journal.loadRunDispatches(
        allocator,
        evidence_dir,
        binding,
    );
    defer observed.deinit();
    try std.testing.expectEqual(@as(usize, 0), observed.dispatches.len);
    try std.testing.expectEqual(@as(usize, 1), observed.formal_decisions.len);
    try std.testing.expectEqual(
        cc.tools.tool_observation.FormalResult.fault,
        observed.formal_decisions[0].result,
    );
    try std.testing.expectEqualStrings(
        "verdict_binding_mismatch",
        observed.formal_decisions[0].checker_failure orelse return error.MissingCheckerFailure,
    );
}

test "L2 same-cardinality batch binding drift has no durable verdict and no dispatch" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const real_kernel = testKernel() orelse return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const evidence_dir = try std.fmt.allocPrint(allocator, "{s}/evidence", .{root});
    defer allocator.free(evidence_dir);
    try cc.util_fs.mkdirParents(evidence_dir);
    const checker_path = try std.fmt.allocPrint(allocator, "{s}/binding-drift-checker", .{root});
    defer allocator.free(checker_path);
    const checker_script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\n\"{s}\" | sed 's/\"candidate_id\":\"[0-9a-f]*\"/\"candidate_id\":\"{s}\"/'\n",
        .{ real_kernel.checker_path, &([_]u8{'f'} ** 64) },
    );
    defer allocator.free(checker_script);
    try overwriteArtifact(allocator, checker_path, checker_script);
    const checker_z = try allocator.dupeZ(u8, checker_path);
    defer allocator.free(checker_z);
    if (std.c.chmod(checker_z.ptr, 0o700) != 0) return error.SkipZigTest;
    const config = cc.project_harness_runtime.Config{
        .checker_path = checker_path,
        .expected_sha256 = cc.tools.tool_observation.sha256Hex(checker_script),
    };
    var active = try syntheticActive(allocator, 4, config);
    defer active.deinit();
    var runtime = cc.project_rule_gate.RuntimeGate{
        .allocator = allocator,
        .active = &active,
        .config = config,
        .abort = null,
    };
    const sid = cc.session_id.SessionId.fromSlice("0123456789abcdef01234567").?;
    var journal = try cc.tool_observation_journal.Journal.init(evidence_dir, sid);
    const sink = journal.sink();
    runtime.evidence_dir = evidence_dir;
    runtime.observation_sink = sink;
    var probe = Probe{};
    var ctx = cc.tool_context.ToolContext.simple(allocator);
    ctx.tool_dispatcher = probe.dispatcher();
    ctx.project_rule_gate = runtime.protocolGate();
    ctx.tool_observer = sink;
    const result = try cc.tool_exec.executeOne(
        &ctx,
        "Read",
        "{}",
        "binding-drift-batch",
        allocator,
        .{ .bytes = [_]u8{'0'} ** 12 },
    );
    try std.testing.expect(result == .host_fatal);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try journal.finishRun("HostToolFatal");
    const binding = try journal.runBinding();
    journal.deinit();
    var observed = try cc.tool_observation_journal.loadRunDispatches(
        allocator,
        evidence_dir,
        binding,
    );
    defer observed.deinit();
    try std.testing.expectEqual(@as(usize, 1), observed.formal_decisions.len);
    const formal = observed.formal_decisions[0];
    try std.testing.expectEqual(cc.tools.tool_observation.FormalResult.fault, formal.result);
    try std.testing.expectEqual(@as(?[64]u8, null), formal.checker_verdict_sha256);
    try std.testing.expectEqualStrings(
        "verdict_binding_mismatch",
        formal.checker_failure orelse return error.MissingCheckerFailure,
    );
}

test "L2 promoted Lean post rule admits matched Write and poisons unavailable reobservation" {
    const config = testKernel() orelse return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const evidence_dir = try std.fmt.allocPrint(allocator, "{s}/evidence", .{root});
    defer allocator.free(evidence_dir);
    const rules_dir = try std.fmt.allocPrint(allocator, "{s}/project-rules", .{root});
    defer allocator.free(rules_dir);
    const project = cc.project_rule_bundle.projectIdentity(root);
    const promoted = try promoteFixture(
        allocator,
        evidence_dir,
        rules_dir,
        project,
        config,
        .{
            .target_tool = "Write",
            .deny_target = false,
            .max_input_bytes = 8192,
            .max_agent_depth = 4,
            .authoritative_only = true,
            .effect_requirement = .file_mutation_v1_reobserved,
        },
        "def spec : RuleSpec := { targetTool := \"Write\", denyTarget := false, maxInputBytes := 8192, maxAgentDepth := 4, authoritativeOnly := true, effectRequirement := .fileMutationV1Reobserved }; theorem spec_valid : valid spec = true := by rfl",
    );
    try std.testing.expectEqual(@as(u64, 1), promoted.revision);
    var active = (try cc.project_rule_bundle.loadVerifiedActive(
        allocator,
        rules_dir,
        project,
        config,
        null,
    )) orelse return error.MissingActiveBundle;
    defer active.deinit();
    var runtime = cc.project_rule_gate.RuntimeGate{
        .allocator = allocator,
        .active = &active,
        .config = config,
        .abort = null,
    };
    const runtime_sid = cc.session_id.SessionId.fromSlice("fedcba9876543210fedcba98").?;
    var runtime_journal = try cc.tool_observation_journal.Journal.init(evidence_dir, runtime_sid);
    const runtime_sink = runtime_journal.sink();
    runtime.evidence_dir = evidence_dir;
    runtime.observation_sink = runtime_sink;

    const matched_path = try std.fmt.allocPrintSentinel(allocator, "{s}/matched.txt", .{root}, 0);
    defer allocator.free(matched_path);
    const matched_args = try std.fmt.allocPrint(
        allocator,
        "{{\"file_path\":\"{s}\",\"content\":\"grounded\"}}",
        .{matched_path},
    );
    defer allocator.free(matched_args);
    var matched_ctx = cc.tool_context.ToolContext.simple(allocator);
    matched_ctx.project_rule_gate = runtime.protocolGate();
    matched_ctx.tool_observer = runtime_sink;
    const matched = try cc.tool_exec.executeOne(
        &matched_ctx,
        "Write",
        matched_args,
        "matched-write",
        allocator,
        .{ .bytes = [_]u8{'0'} ** 12 },
    );
    switch (matched) {
        .done => |done| {
            defer if (done.content) |bytes| allocator.free(bytes);
            try std.testing.expect(!done.is_error);
        },
        else => return error.UnexpectedToolResult,
    }
    try std.testing.expect(pfs.exists(matched_path.ptr));

    const vanished_path = try std.fmt.allocPrintSentinel(allocator, "{s}/vanished.txt", .{root}, 0);
    defer allocator.free(vanished_path);
    var vanishing = VanishingWrite{ .path = vanished_path };
    var vanished_ctx = cc.tool_context.ToolContext.simple(allocator);
    vanished_ctx.tool_dispatcher = vanishing.dispatcher();
    vanished_ctx.project_rule_gate = runtime.protocolGate();
    vanished_ctx.tool_observer = runtime_sink;
    const vanished = try cc.tool_exec.executeOne(
        &vanished_ctx,
        "Write",
        "{}",
        "vanished-write",
        allocator,
        .{ .bytes = [_]u8{'0'} ** 12 },
    );
    try std.testing.expect(vanished == .host_fatal);
    try std.testing.expectEqual(@as(usize, 1), vanishing.calls);
    try std.testing.expect(!pfs.exists(vanished_path.ptr));
    try runtime_journal.finishRun("HostToolFatal");
    const runtime_binding = try runtime_journal.runBinding();
    runtime_journal.deinit();

    var observed = try cc.tool_observation_journal.loadRunDispatches(
        allocator,
        evidence_dir,
        runtime_binding,
    );
    defer observed.deinit();
    try std.testing.expectEqual(@as(usize, 2), observed.dispatches.len);
    try std.testing.expectEqual(@as(usize, 4), observed.formal_decisions.len);
    var matched_count: usize = 0;
    var unavailable_count: usize = 0;
    for (observed.dispatches) |dispatch| {
        if (dispatch.effect) |effect| switch (effect) {
            .file_mutation_v1 => {},
            .file_mutation_v2 => |value| switch (value.reobservation.state) {
                .matched => matched_count += 1,
                .unavailable => unavailable_count += 1,
                .mismatched => {},
            },
        };
    }
    try std.testing.expectEqual(@as(usize, 1), matched_count);
    try std.testing.expectEqual(@as(usize, 1), unavailable_count);
    var blocked_verdict: ?[64]u8 = null;
    var blocked_batch_verdict: ?[64]u8 = null;
    for (observed.formal_decisions) |formal| {
        if (formal.phase == .post and formal.result == .block) {
            blocked_verdict = formal.verdict_sha256;
            blocked_batch_verdict = formal.checker_verdict_sha256;
        }
    }
    const verdict_sha256 = blocked_verdict orelse return error.MissingBlockedPostVerdict;
    const batch_verdict_sha256 = blocked_batch_verdict orelse return error.MissingBlockedBatchVerdict;
    const verdict_payload = try cc.project_rule_gate.readRuntimeBatchVerdict(
        allocator,
        evidence_dir,
        batch_verdict_sha256,
    );
    defer allocator.free(verdict_payload);
    try std.testing.expect(std.mem.indexOf(u8, verdict_payload, "\"decision\":\"block\"") != null);
    const verdict_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}{s}.json",
        .{ evidence_dir, cc.project_rule_gate.RUNTIME_BATCH_VERDICT_PREFIX, batch_verdict_sha256[0..] },
    );
    defer allocator.free(verdict_path);
    try overwriteArtifact(allocator, verdict_path, "{}");
    try std.testing.expectError(
        error.InvalidRuntimeVerdict,
        cc.project_rule_gate.readRuntimeBatchVerdict(allocator, evidence_dir, batch_verdict_sha256),
    );
    try overwriteArtifact(allocator, verdict_path, verdict_payload);
    const individual_verdict_payload = try cc.project_harness_runtime.extractBatchVerdict(
        allocator,
        verdict_payload,
        verdict_sha256,
    );
    defer allocator.free(individual_verdict_payload);
    var wrong_project = project;
    wrong_project[0] = if (wrong_project[0] == '0') '1' else '0';
    try std.testing.expectError(
        error.ProjectIdentityMismatch,
        cc.rule_source_receipt.persistRuntimeCounterexample(evidence_dir, .{
            .project_sha256 = wrong_project,
            .issuer_sha256 = .{'8'} ** 64,
            .observation = runtime_binding,
            .checker_sha256 = config.expected_sha256,
            .verdict_payload = individual_verdict_payload,
        }),
    );
    const source = try cc.rule_source_receipt.persistRuntimeCounterexample(evidence_dir, .{
        .project_sha256 = project,
        .issuer_sha256 = .{'8'} ** 64,
        .observation = runtime_binding,
        .checker_sha256 = config.expected_sha256,
        .verdict_payload = individual_verdict_payload,
    });
    const next = try cc.rule_candidate.persist(evidence_dir, .{
        .project_sha256 = project,
        .proposer_sha256 = .{'9'} ** 64,
        .invariant = "A successful Write must retain a matched host re-observation.",
        .rule_spec = .{
            .target_tool = "Write",
            .deny_target = false,
            .max_input_bytes = 8192,
            .max_agent_depth = 4,
            .authoritative_only = true,
            .effect_requirement = .file_mutation_v1_reobserved,
        },
        .lean_source = "def spec : RuleSpec := { targetTool := \"Write\", denyTarget := false, maxInputBytes := 8192, maxAgentDepth := 4, authoritativeOnly := true, effectRequirement := .fileMutationV1Reobserved }; theorem spec_valid : valid spec = true := by rfl",
        .source = .{ .runtime_counterexample = .{
            .receipt_id = source.receipt_id,
            .observation = runtime_binding,
            .verdict_sha256 = verdict_sha256,
        } },
    });
    var next_loaded = try cc.rule_candidate.load(allocator, evidence_dir, next.candidate_id);
    defer next_loaded.deinit();
    try std.testing.expectEqual(cc.rule_candidate.SourceKind.runtime_counterexample, next_loaded.source_kind);
}
