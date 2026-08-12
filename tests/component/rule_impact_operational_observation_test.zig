//! L2 for the normal Run -> operational RuleImpact observer boundary.

const std = @import("std");
const builtin = @import("builtin");
const cc = @import("cc");
const pfs = @import("platform").fs;

const active = cc.rule_impact_operational_observation.ActiveIdentity{
    .project_sha256 = .{'b'} ** 64,
    .bundle_sha256 = .{'c'} ** 64,
    .bundle_revision = 1,
};

const Fixture = struct {
    root: []const u8,
    binding: cc.tool_observation_journal.RunBinding,
};

fn completedFixture(tmp: *std.testing.TmpDir, root_buffer: []u8) !Fixture {
    const root_len = try tmp.dir.realPath(std.testing.io, root_buffer);
    const root = root_buffer[0..root_len];
    const sid = cc.session_id.SessionId.fromSlice("0123456789abcdef01234567").?;
    var journal = try cc.tool_observation_journal.Journal.init(root, sid);
    const sink = journal.sink();
    try std.testing.expect(sink.emit(.{ .formal_decision = .{
        .dispatch_id = "read-one",
        .phase = .pre,
        .actuation = .shadow,
        .result = .admit,
        .candidate_id = .{'a'} ** 64,
        .project_sha256 = active.project_sha256,
        .bundle_sha256 = active.bundle_sha256,
        .bundle_revision = active.bundle_revision,
        .kernel_sha256 = .{'d'} ** 64,
        .request_sha256 = .{'e'} ** 64,
        .checker_call_sha256 = .{'1'} ** 64,
        .checker_verdict_sha256 = .{'2'} ** 64,
        .verdict_sha256 = .{'f'} ** 64,
        .checker_failure = null,
        .checker_elapsed_ns = 17,
        .checker_bytes = 123,
    } }));
    try std.testing.expect(sink.emit(.{ .dispatch_started = .{
        .id = "read-one",
        .requested_name = "Read",
        .dispatched_name = "Read",
        .origin = .authoritative,
        .agent_depth = 0,
        .input_bytes = 2,
        .input_sha256 = cc.tools.tool_observation.sha256Hex("{}"),
    } }));
    try std.testing.expect(sink.emit(.{ .formal_decision = .{
        .dispatch_id = "read-one",
        .phase = .post,
        .actuation = .shadow,
        .result = .admit,
        .candidate_id = .{'a'} ** 64,
        .project_sha256 = active.project_sha256,
        .bundle_sha256 = active.bundle_sha256,
        .bundle_revision = active.bundle_revision,
        .kernel_sha256 = .{'d'} ** 64,
        .request_sha256 = .{'4'} ** 64,
        .checker_call_sha256 = .{'3'} ** 64,
        .checker_verdict_sha256 = .{'4'} ** 64,
        .verdict_sha256 = .{'5'} ** 64,
        .checker_failure = null,
        .checker_elapsed_ns = 19,
        .checker_bytes = 125,
    } }));
    try std.testing.expect(sink.emit(.{ .dispatch_finished = .{
        .id = "read-one",
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
    return .{ .root = root, .binding = binding };
}

fn observationPath(
    allocator: std.mem.Allocator,
    root: []const u8,
    id: [64]u8,
) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}/{s}{s}.json", .{
        root,
        cc.rule_impact_operational_observation.FILE_PREFIX,
        id[0..],
    }, 0);
}

fn readFile(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    const info = try pfs.fileInfo(fd);
    const bytes = try allocator.alloc(u8, @intCast(info.size));
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.read(fd, bytes[offset..]);
        if (count <= 0) return error.ReadFailed;
        offset += @intCast(count);
    }
    return bytes;
}

fn overwrite(path: [:0]const u8, bytes: []const u8) !void {
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .TRUNC = true, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    if (pfs.write(fd, bytes) != bytes.len) return error.WriteFailed;
}

test "L2 operational observer is content-addressed idempotent and cannot become promotion evidence" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const fixture = try completedFixture(&tmp, &root_buffer);

    const first = try cc.rule_impact_operational_observation.persist(.{
        .session_dir = fixture.root,
        .observation = fixture.binding,
        .active = active,
    });
    try std.testing.expect(first.created);
    const second = try cc.rule_impact_operational_observation.persist(.{
        .session_dir = fixture.root,
        .observation = fixture.binding,
        .active = active,
    });
    try std.testing.expect(!second.created);
    try std.testing.expectEqualSlices(u8, &first.observation_id, &second.observation_id);

    var loaded = try cc.rule_impact_operational_observation.loadBound(
        allocator,
        fixture.root,
        first.observation_id,
        active,
    );
    defer loaded.deinit();
    try std.testing.expectEqualStrings("end_turn", loaded.stop_reason);
    try std.testing.expectEqual(@as(u64, 2), loaded.snapshot.formal_decisions);
    try std.testing.expectEqual(@as(u64, 2), loaded.snapshot.physical_checker_calls);
    try std.testing.expectEqual(@as(u64, 36), loaded.snapshot.checker_elapsed_ns);
    try std.testing.expectEqual(@as(u64, 1), loaded.snapshot.authoritative_successes);
    try std.testing.expect(loaded.snapshot.labels.task_success == null);
    try std.testing.expect(!loaded.snapshot.evidence.authenticated);
    try std.testing.expect(loaded.record_bytes < cc.rule_impact_operational_observation.MAX_RECORD_BYTES);

    var snapshot = try cc.rule_impact_operational_observation.deriveOperationalSnapshot(
        allocator,
        fixture.root,
        first.observation_id,
        active,
    );
    defer snapshot.deinit(allocator);
    try std.testing.expectError(
        error.UnauthenticatedRuleImpact,
        cc.ontology_rule_projection.renderRuleImpactSummary(allocator, snapshot),
    );
    try std.testing.expectError(
        error.InvalidImpactEvidence,
        cc.project_harness_runtime.invokeImpact(
            allocator,
            .{ .checker_path = "/must-not-run", .expected_sha256 = .{'8'} ** 64 },
            .{
                .session_dir = fixture.root,
                .receipt_id = first.observation_id,
                .expected_issuer_sha256 = .{'7'} ** 64,
                .rule_index = 0,
                .operation = .promote,
                .current_state = .shadowed,
                .policy = .{
                    .min_exposures = 1,
                    .max_formal_faults = 0,
                    .max_shadow_divergences = 0,
                    .max_false_interventions = 0,
                    .max_regressions = 0,
                    .max_provider_requests = 1,
                    .max_metered_tokens = 1,
                    .max_cost_microusd = 1,
                    .max_wall_elapsed_ns = 1,
                },
            },
            null,
        ),
    );
}

test "L2 operational observer rejects identity drift tamper symlink and hardlink" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const fixture = try completedFixture(&tmp, &root_buffer);
    const published = try cc.rule_impact_operational_observation.persist(.{
        .session_dir = fixture.root,
        .observation = fixture.binding,
        .active = active,
    });
    var drift = active;
    drift.bundle_revision += 1;
    try std.testing.expectError(
        error.ActiveIdentityMismatch,
        cc.rule_impact_operational_observation.loadBound(
            allocator,
            fixture.root,
            published.observation_id,
            drift,
        ),
    );
    const path = try observationPath(allocator, fixture.root, published.observation_id);
    defer allocator.free(path);
    const artifact_fd = pfs.open(path.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (artifact_fd < 0) return error.OpenFailed;
    const artifact_info = try pfs.fileInfo(artifact_fd);
    _ = pfs.close(artifact_fd);
    try std.testing.expectEqual(@as(u32, 0), artifact_info.mode & 0o077);
    const original = try readFile(allocator, path);
    defer allocator.free(original);
    const alias = try std.fmt.allocPrintSentinel(allocator, "{s}/observer-hardlink.json", .{fixture.root}, 0);
    defer allocator.free(alias);
    if (std.c.link(path.ptr, alias.ptr) != 0) return error.SkipZigTest;
    defer _ = std.c.unlink(alias.ptr);
    try std.testing.expectError(
        error.InvalidFile,
        cc.rule_impact_operational_observation.loadBound(
            allocator,
            fixture.root,
            published.observation_id,
            active,
        ),
    );
    try std.testing.expectEqual(@as(c_int, 0), std.c.unlink(alias.ptr));
    try overwrite(path, "{}\n");
    try std.testing.expectError(
        error.InvalidObservation,
        cc.rule_impact_operational_observation.loadBound(
            allocator,
            fixture.root,
            published.observation_id,
            active,
        ),
    );
    try overwrite(path, original);
    try std.testing.expectEqual(@as(c_int, 0), std.c.unlink(path.ptr));
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink("tool-observations.jsonl", path.ptr));
    try std.testing.expectError(
        error.OpenFailed,
        cc.rule_impact_operational_observation.loadBound(
            allocator,
            fixture.root,
            published.observation_id,
            active,
        ),
    );
}

test "L2 operational observer rejects foreign formal bundle and unfinished journal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const fixture = try completedFixture(&tmp, &root_buffer);
    var foreign = active;
    foreign.bundle_sha256 = .{'9'} ** 64;
    try std.testing.expectError(
        error.FormalDecisionBundleMismatch,
        cc.rule_impact_operational_observation.persist(.{
            .session_dir = fixture.root,
            .observation = fixture.binding,
            .active = foreign,
        }),
    );

    const unfinished_root = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/unfinished",
        .{fixture.root},
    );
    defer std.testing.allocator.free(unfinished_root);
    try cc.util_fs.mkdirParents(unfinished_root);
    const unfinished_sid = cc.session_id.SessionId.fromSlice("abcdef0123456789abcdef01").?;
    var unfinished = try cc.tool_observation_journal.Journal.init(unfinished_root, unfinished_sid);
    defer unfinished.deinit();
    try std.testing.expectError(error.RunNotFinished, unfinished.runBinding());
}

test "L2 RunControl with no active bundle has zero operational observer artifact" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const session_dir = try std.fmt.allocPrint(allocator, "{s}/session", .{root});
    defer allocator.free(session_dir);
    try cc.util_fs.mkdirParents(session_dir);
    const sid = cc.session_id.SessionId.fromSlice("1123456789abcdef01234567").?;
    const control = try cc.project_rule_activation.RunControl.init(
        allocator,
        session_dir,
        sid,
        root,
        null,
    );
    defer control.deinit();
    try control.finishRun("end_turn");
    try std.testing.expect(control.operationalObservationId() == null);
}
