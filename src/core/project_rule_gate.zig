//! Runtime adapter from a verified active bundle to the fixed Lean kernel.
//! No Zig decision function is used for authorization.

const std = @import("std");
const bundle_mod = @import("project_rule_bundle.zig");
const spec_mod = @import("project_rule_spec.zig");
const kernel = @import("../formal/project_harness_runtime.zig");
const protocol = @import("../tools/project_rule_gate.zig");
const observation = @import("../tools/observation.zig");
const pfs = @import("platform").fs;
const sync = @import("platform").sync;

pub const RUNTIME_VERDICT_PREFIX = "project-rule-runtime-verdict-";
pub const RUNTIME_BATCH_VERDICT_PREFIX = "project-rule-runtime-batch-verdict-";

const BatchDecision = struct {
    result: protocol.Result,
    recovery_action: protocol.RecoveryAction = .none,
};

pub const RuntimeGate = struct {
    mutex: sync.Mutex = .{},
    allocator: std.mem.Allocator,
    active: *const bundle_mod.LoadedActive,
    config: kernel.Config,
    abort: ?*const @import("../util/abort.zig").AbortSignal,
    /// Production construction leaves this at `enforced`.  Evaluation-only
    /// callers may select `shadow`: the same kernel call and durable verdict
    /// are produced, but the protocol result is projected to `admit` so the
    /// counterfactual decision cannot change the observed tool trajectory.
    actuation: observation.FormalActuation = .enforced,
    evidence_dir: ?[]const u8 = null,
    observation_sink: ?observation.Sink = null,

    pub fn protocolGate(self: *RuntimeGate) protocol.Gate {
        return .{ .ctx = @ptrCast(self), .preFn = preThunk, .postFn = postThunk };
    }

    fn preThunk(raw: *anyopaque, signal: protocol.PreSignal) protocol.PreResult {
        const self: *RuntimeGate = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        const decision = self.decidePre(signal) catch return .fault;
        return self.actuatePre(decision);
    }

    fn postThunk(raw: *anyopaque, signal: protocol.PostSignal) protocol.Result {
        const self: *RuntimeGate = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        const decision = self.decidePost(signal) catch return .fault;
        return self.actuateResult(decision.result);
    }

    fn actuateResult(self: *const RuntimeGate, decision: protocol.Result) protocol.Result {
        return if (self.actuation == .shadow) .admit else decision;
    }

    fn actuatePre(self: *const RuntimeGate, decision: BatchDecision) protocol.PreResult {
        if (self.actuation == .shadow) return .admit;
        return switch (decision.result) {
            .admit => .admit,
            .block => .{ .block = decision.recovery_action },
            .fault => .fault,
        };
    }

    fn decidePre(self: *RuntimeGate, signal: protocol.PreSignal) !BatchDecision {
        const formal_signal = spec_mod.PreSignal{
            .tool = signal.tool,
            .input_bytes = signal.input_bytes,
            .agent_depth = signal.agent_depth,
            .authoritative = signal.authoritative,
            .file_target_state = signal.file_target_state,
        };
        const signal_json = try std.json.Stringify.valueAlloc(self.allocator, formal_signal, .{});
        defer self.allocator.free(signal_json);
        const requests = try self.allocator.alloc(kernel.Request, self.active.rules.len);
        defer self.allocator.free(requests);
        const bindings = try self.allocator.alloc(kernel.Bindings, self.active.rules.len);
        defer self.allocator.free(bindings);
        const request_ids = try self.allocator.alloc([64]u8, self.active.rules.len);
        defer self.allocator.free(request_ids);
        for (self.active.rules, 0..) |entry, index| {
            const candidate_id = parseHex(entry.candidate_id) orelse return error.InvalidCandidateId;
            request_ids[index] = kernel.requestId(
                .pre_decision,
                candidate_id,
                self.active.bundle_sha256,
                self.active.revision,
                signal_json,
            );
            requests[index] = .{
                .request_id = request_ids[index][0..],
                .operation = .pre_decision,
                .kernel_sha256 = self.active.kernel_sha256[0..],
                .candidate_id = entry.candidate_id,
                .project_sha256 = self.active.project_sha256[0..],
                .bundle_sha256 = self.active.bundle_sha256[0..],
                .bundle_revision = self.active.revision,
                .rule_spec = entry.rule_spec,
                .payload = .{ .pre = formal_signal },
            };
            bindings[index] = .{
                .request_id = request_ids[index],
                .operation = .pre_decision,
                .kernel_sha256 = self.active.kernel_sha256,
                .candidate_id = candidate_id,
                .project_sha256 = self.active.project_sha256,
                .bundle_sha256 = self.active.bundle_sha256,
                .bundle_revision = self.active.revision,
            };
        }
        var batch = try kernel.invokeBatch(
            self.allocator,
            self.config,
            requests,
            bindings,
            self.abort,
        );
        defer batch.deinit(self.allocator);
        return self.recordBatch(
            signal.dispatch_id,
            .pre,
            signal.file_target_state,
            &batch,
        );
    }

    fn decidePost(self: *RuntimeGate, signal: protocol.PostSignal) !BatchDecision {
        const formal_pre = spec_mod.PreSignal{
            .tool = signal.pre.tool,
            .input_bytes = signal.pre.input_bytes,
            .agent_depth = signal.pre.agent_depth,
            .authoritative = signal.pre.authoritative,
            .file_target_state = signal.pre.file_target_state,
        };
        const formal_signal = spec_mod.PostSignal{
            .pre = formal_pre,
            .succeeded = signal.outcome == .succeeded,
            .effect_valid = signal.effect_valid,
            .has_file_mutation_v1 = hasFileMutation(signal.effect),
            .post_reobserved = postReobserved(signal.effect),
        };
        const signal_json = try std.json.Stringify.valueAlloc(self.allocator, formal_signal, .{});
        defer self.allocator.free(signal_json);
        const requests = try self.allocator.alloc(kernel.Request, self.active.rules.len);
        defer self.allocator.free(requests);
        const bindings = try self.allocator.alloc(kernel.Bindings, self.active.rules.len);
        defer self.allocator.free(bindings);
        const request_ids = try self.allocator.alloc([64]u8, self.active.rules.len);
        defer self.allocator.free(request_ids);
        for (self.active.rules, 0..) |entry, index| {
            const candidate_id = parseHex(entry.candidate_id) orelse return error.InvalidCandidateId;
            request_ids[index] = kernel.requestId(
                .post_decision,
                candidate_id,
                self.active.bundle_sha256,
                self.active.revision,
                signal_json,
            );
            requests[index] = .{
                .request_id = request_ids[index][0..],
                .operation = .post_decision,
                .kernel_sha256 = self.active.kernel_sha256[0..],
                .candidate_id = entry.candidate_id,
                .project_sha256 = self.active.project_sha256[0..],
                .bundle_sha256 = self.active.bundle_sha256[0..],
                .bundle_revision = self.active.revision,
                .rule_spec = entry.rule_spec,
                .payload = .{ .post = formal_signal },
            };
            bindings[index] = .{
                .request_id = request_ids[index],
                .operation = .post_decision,
                .kernel_sha256 = self.active.kernel_sha256,
                .candidate_id = candidate_id,
                .project_sha256 = self.active.project_sha256,
                .bundle_sha256 = self.active.bundle_sha256,
                .bundle_revision = self.active.revision,
            };
        }
        var batch = try kernel.invokeBatch(
            self.allocator,
            self.config,
            requests,
            bindings,
            self.abort,
        );
        defer batch.deinit(self.allocator);
        return self.recordBatch(
            signal.pre.dispatch_id,
            .post,
            signal.pre.file_target_state,
            &batch,
        );
    }

    fn recordBatch(
        self: *RuntimeGate,
        dispatch_id: []const u8,
        phase: observation.FormalPhase,
        file_target_state: observation.FileTargetState,
        batch: *const kernel.BatchInvocation,
    ) BatchDecision {
        // A production gate must publish both the payload and its journal
        // binding.  Test-only direct gates may deliberately configure neither.
        if ((self.evidence_dir != null) != (self.observation_sink != null))
            return .{ .result = .fault };
        var decision_count: usize = 0;
        var result = protocol.Result.admit;
        var recovery_action = protocol.RecoveryAction.none;
        for (batch.invocations) |invocation| {
            decision_count += 1;
            if (invocation.failure != .none or invocation.verdict == null) {
                result = .fault;
                break;
            }
            if (!invocation.verdict.?.admitted) {
                result = .block;
                recovery_action = switch (invocation.verdict.?.recovery_action) {
                    .none => .none,
                    .edit_existing_file_exact => .edit_existing_file_exact,
                };
                break;
            }
        }
        if (decision_count == 0) return .{ .result = .fault };
        if (self.evidence_dir) |directory| {
            if (batch.verdict_payload) |payload| {
                const verdict_sha = batch.verdict_sha256 orelse return .{ .result = .fault };
                persistRuntimeBatchVerdict(directory, verdict_sha, payload) catch
                    return .{ .result = .fault };
            }
        }
        const sink = self.observation_sink orelse return .{
            .result = result,
            .recovery_action = recovery_action,
        };
        const decisions = self.allocator.alloc(observation.FormalCandidateDecision, decision_count) catch
            return .{ .result = .fault };
        defer self.allocator.free(decisions);
        for (batch.invocations[0..decision_count], decisions) |invocation, *decision| {
            decision.* = .{
                .result = if (invocation.failure != .none)
                    .fault
                else if (invocation.verdict != null and invocation.verdict.?.admitted)
                    .admit
                else
                    .block,
                .recovery_action = if (invocation.verdict) |verdict| switch (verdict.recovery_action) {
                    .none => .none,
                    .edit_existing_file_exact => .edit_existing_file_exact,
                } else .none,
                .candidate_id = invocation.bindings.?.candidate_id,
                .request_sha256 = invocation.request_sha256,
                .verdict_sha256 = invocation.verdict_sha256,
                .checker_failure = if (invocation.failure == .none)
                    null
                else
                    @tagName(invocation.failure),
            };
        }
        const first = &batch.invocations[0];
        if (!sink.emit(.{ .formal_decision_batch = .{
            .dispatch_id = dispatch_id,
            .phase = phase,
            .actuation = self.actuation,
            .file_target_state = file_target_state,
            .project_sha256 = self.active.project_sha256,
            .bundle_sha256 = self.active.bundle_sha256,
            .bundle_revision = self.active.revision,
            .kernel_sha256 = self.active.kernel_sha256,
            .checker_call_sha256 = first.checker_call_sha256 orelse return .{ .result = .fault },
            .checker_verdict_sha256 = batch.verdict_sha256,
            .checker_batch_size = first.checker_batch_size,
            .checker_elapsed_ns = first.checker_elapsed_ns,
            .checker_bytes = first.checker_bytes,
            .decisions = decisions,
        } })) return .{ .result = .fault };
        return .{ .result = result, .recovery_action = recovery_action };
    }
};

fn persistRuntimeBatchVerdict(
    directory: []const u8,
    verdict_sha256: [64]u8,
    payload: []const u8,
) !void {
    return persistRuntimeArtifact(
        directory,
        RUNTIME_BATCH_VERDICT_PREFIX,
        verdict_sha256,
        payload,
        kernel.MAX_BATCH_BYTES,
    );
}

fn persistRuntimeArtifact(
    directory: []const u8,
    prefix: []const u8,
    verdict_sha256: [64]u8,
    payload: []const u8,
    max_payload_bytes: usize,
) !void {
    if (payload.len == 0 or payload.len > max_payload_bytes or
        !std.mem.eql(u8, &observation.sha256Hex(payload), &verdict_sha256))
        return error.InvalidRuntimeVerdict;
    var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/{s}{s}.json\x00",
        .{ directory, prefix, verdict_sha256[0..] },
    );
    const fd = pfs.open(@ptrCast(path.ptr), .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
    }, @as(std.c.mode_t, 0o600));
    if (fd >= 0) {
        var write_fd = fd;
        errdefer {
            if (write_fd >= 0) _ = pfs.close(write_fd);
        }
        try pfs.makeCloseOnExec(write_fd);
        try writeAll(write_fd, payload);
        try pfs.fsyncChecked(write_fd);
        _ = pfs.close(write_fd);
        write_fd = -1;
        try fsyncDirectory(directory);
        return;
    }
    const existing = try readRuntimeArtifact(
        std.heap.c_allocator,
        directory,
        prefix,
        verdict_sha256,
        max_payload_bytes,
    );
    defer std.heap.c_allocator.free(existing);
    if (!std.mem.eql(u8, existing, payload)) return error.RuntimeVerdictCollision;
}

pub fn readRuntimeVerdict(
    allocator: std.mem.Allocator,
    directory: []const u8,
    verdict_sha256: [64]u8,
) ![]u8 {
    return readRuntimeArtifact(
        allocator,
        directory,
        RUNTIME_VERDICT_PREFIX,
        verdict_sha256,
        kernel.MAX_OUTPUT_BYTES,
    );
}

pub fn readRuntimeBatchVerdict(
    allocator: std.mem.Allocator,
    directory: []const u8,
    verdict_sha256: [64]u8,
) ![]u8 {
    return readRuntimeArtifact(
        allocator,
        directory,
        RUNTIME_BATCH_VERDICT_PREFIX,
        verdict_sha256,
        kernel.MAX_BATCH_BYTES,
    );
}

fn readRuntimeArtifact(
    allocator: std.mem.Allocator,
    directory: []const u8,
    prefix: []const u8,
    verdict_sha256: [64]u8,
    max_payload_bytes: usize,
) ![]u8 {
    var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/{s}{s}.json\x00",
        .{ directory, prefix, verdict_sha256[0..] },
    );
    const fd = pfs.open(@ptrCast(path.ptr), .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.RuntimeVerdictOpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.RuntimeVerdictStatFailed;
    if (!before.is_regular or before.link_count != 1 or before.size == 0 or before.size > max_payload_bytes)
        return error.InvalidRuntimeVerdict;
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.read(fd, bytes[offset..]);
        if (count <= 0) return error.RuntimeVerdictReadFailed;
        offset += @intCast(count);
    }
    const after = pfs.fileInfo(fd) catch return error.RuntimeVerdictStatFailed;
    if (!after.is_regular or after.link_count != 1 or after.size != before.size or
        !std.mem.eql(u8, &observation.sha256Hex(bytes), &verdict_sha256))
        return error.InvalidRuntimeVerdict;
    return bytes;
}

fn writeAll(fd: pfs.Fd, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.write(fd, bytes[offset..]);
        if (count <= 0) return error.RuntimeVerdictWriteFailed;
        offset += @intCast(count);
    }
}

fn fsyncDirectory(directory: []const u8) !void {
    if (@import("builtin").os.tag == .windows) return;
    var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, "{s}\x00", .{directory});
    const fd = pfs.open(@ptrCast(path.ptr), .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.DirectoryOpenFailed;
    defer _ = pfs.close(fd);
    try pfs.fsyncChecked(fd);
}

fn hasFileMutation(effect: ?observation.Effect) bool {
    const value = effect orelse return false;
    return switch (value) {
        .file_mutation_v1, .file_mutation_v2 => true,
    };
}

fn postReobserved(effect: ?observation.Effect) bool {
    const value = effect orelse return false;
    return switch (value) {
        .file_mutation_v1 => false,
        .file_mutation_v2 => |mutation| mutation.reobservation.state == .matched,
    };
}

fn parseHex(value: []const u8) ?[64]u8 {
    if (value.len != 64) return null;
    var result: [64]u8 = undefined;
    for (value, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
        result[index] = byte;
    }
    return result;
}

test "runtime post signal recognizes only matched host re-observation" {
    const mutation = observation.FileMutationV1{
        .path_sha256 = .{'a'} ** 64,
        .before_state = .missing,
        .before_sha256 = .{'0'} ** 64,
        .after_sha256 = .{'b'} ** 64,
        .before_bytes = 0,
        .after_bytes = 1,
        .change = .changed,
    };
    try std.testing.expect(!postReobserved(.{ .file_mutation_v1 = mutation }));
    try std.testing.expect(postReobserved(.{ .file_mutation_v2 = .{
        .mutation = mutation,
        .reobservation = .{
            .state = .matched,
            .observed_sha256 = .{'b'} ** 64,
            .observed_bytes = 1,
        },
    } }));
}

test "runtime batch verdict artifact exceeds the legacy single-verdict ceiling" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const payload = try allocator.alloc(u8, kernel.MAX_OUTPUT_BYTES + 1);
    defer allocator.free(payload);
    @memset(payload, 'x');
    const sha256 = observation.sha256Hex(payload);

    try persistRuntimeBatchVerdict(root, sha256, payload);
    const reopened = try readRuntimeBatchVerdict(allocator, root, sha256);
    defer allocator.free(reopened);
    try std.testing.expectEqualSlices(u8, payload, reopened);
    try std.testing.expectError(
        error.InvalidRuntimeVerdict,
        persistRuntimeArtifact(
            root,
            RUNTIME_VERDICT_PREFIX,
            sha256,
            payload,
            kernel.MAX_OUTPUT_BYTES,
        ),
    );
}
