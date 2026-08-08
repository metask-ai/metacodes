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

pub const RuntimeGate = struct {
    mutex: sync.Mutex = .{},
    allocator: std.mem.Allocator,
    active: *const bundle_mod.LoadedActive,
    config: kernel.Config,
    abort: ?*const @import("../util/abort.zig").AbortSignal,
    evidence_dir: ?[]const u8 = null,
    observation_sink: ?observation.Sink = null,

    pub fn protocolGate(self: *RuntimeGate) protocol.Gate {
        return .{ .ctx = @ptrCast(self), .preFn = preThunk, .postFn = postThunk };
    }

    fn preThunk(raw: *anyopaque, signal: protocol.PreSignal) protocol.Result {
        const self: *RuntimeGate = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.decidePre(signal) catch .fault;
    }

    fn postThunk(raw: *anyopaque, signal: protocol.PostSignal) protocol.Result {
        const self: *RuntimeGate = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.decidePost(signal) catch .fault;
    }

    fn decidePre(self: *RuntimeGate, signal: protocol.PreSignal) !protocol.Result {
        const formal_signal = spec_mod.PreSignal{
            .tool = signal.tool,
            .input_bytes = signal.input_bytes,
            .agent_depth = signal.agent_depth,
            .authoritative = signal.authoritative,
        };
        const signal_json = try std.json.Stringify.valueAlloc(self.allocator, formal_signal, .{});
        defer self.allocator.free(signal_json);
        for (self.active.rules) |entry| {
            const candidate_id = parseHex(entry.candidate_id) orelse return error.InvalidCandidateId;
            const id = kernel.requestId(
                .pre_decision,
                candidate_id,
                self.active.bundle_sha256,
                self.active.revision,
                signal_json,
            );
            const request = kernel.Request{
                .request_id = id[0..],
                .operation = .pre_decision,
                .kernel_sha256 = self.active.kernel_sha256[0..],
                .candidate_id = candidate_id[0..],
                .project_sha256 = self.active.project_sha256[0..],
                .bundle_sha256 = self.active.bundle_sha256[0..],
                .bundle_revision = self.active.revision,
                .rule_spec = entry.rule_spec,
                .payload = .{ .pre = formal_signal },
            };
            var invocation = try kernel.invoke(self.allocator, self.config, request, .{
                .request_id = id,
                .operation = .pre_decision,
                .kernel_sha256 = self.active.kernel_sha256,
                .candidate_id = candidate_id,
                .project_sha256 = self.active.project_sha256,
                .bundle_sha256 = self.active.bundle_sha256,
                .bundle_revision = self.active.revision,
            }, self.abort);
            defer invocation.deinit(self.allocator);
            if (!self.recordInvocation(
                signal.dispatch_id,
                .pre,
                candidate_id,
                &invocation,
            )) return .fault;
            if (invocation.failure != .none or invocation.verdict == null)
                return .fault;
            if (!invocation.verdict.?.admitted) return .block;
        }
        return .admit;
    }

    fn decidePost(self: *RuntimeGate, signal: protocol.PostSignal) !protocol.Result {
        const formal_pre = spec_mod.PreSignal{
            .tool = signal.pre.tool,
            .input_bytes = signal.pre.input_bytes,
            .agent_depth = signal.pre.agent_depth,
            .authoritative = signal.pre.authoritative,
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
        for (self.active.rules) |entry| {
            const candidate_id = parseHex(entry.candidate_id) orelse return error.InvalidCandidateId;
            const id = kernel.requestId(
                .post_decision,
                candidate_id,
                self.active.bundle_sha256,
                self.active.revision,
                signal_json,
            );
            const request = kernel.Request{
                .request_id = id[0..],
                .operation = .post_decision,
                .kernel_sha256 = self.active.kernel_sha256[0..],
                .candidate_id = candidate_id[0..],
                .project_sha256 = self.active.project_sha256[0..],
                .bundle_sha256 = self.active.bundle_sha256[0..],
                .bundle_revision = self.active.revision,
                .rule_spec = entry.rule_spec,
                .payload = .{ .post = formal_signal },
            };
            var invocation = try kernel.invoke(self.allocator, self.config, request, .{
                .request_id = id,
                .operation = .post_decision,
                .kernel_sha256 = self.active.kernel_sha256,
                .candidate_id = candidate_id,
                .project_sha256 = self.active.project_sha256,
                .bundle_sha256 = self.active.bundle_sha256,
                .bundle_revision = self.active.revision,
            }, self.abort);
            defer invocation.deinit(self.allocator);
            if (!self.recordInvocation(
                signal.pre.dispatch_id,
                .post,
                candidate_id,
                &invocation,
            )) return .fault;
            if (invocation.failure != .none or invocation.verdict == null)
                return .fault;
            if (!invocation.verdict.?.admitted) return .block;
        }
        return .admit;
    }

    fn recordInvocation(
        self: *RuntimeGate,
        dispatch_id: []const u8,
        phase: observation.FormalPhase,
        candidate_id: [64]u8,
        invocation: *const kernel.Invocation,
    ) bool {
        // A production gate must publish both the payload and its journal
        // binding.  Test-only direct gates may deliberately configure neither.
        if ((self.evidence_dir != null) != (self.observation_sink != null)) return false;
        if (self.evidence_dir) |directory| {
            if (invocation.verdict_payload) |payload| {
                const verdict_sha = invocation.verdict_sha256 orelse return false;
                persistRuntimeVerdict(directory, verdict_sha, payload) catch return false;
            }
        }
        const sink = self.observation_sink orelse return true;
        const result: observation.FormalResult = if (invocation.failure != .none)
            .fault
        else if (invocation.verdict != null and invocation.verdict.?.admitted)
            .admit
        else
            .block;
        return sink.emit(.{ .formal_decision = .{
            .dispatch_id = dispatch_id,
            .phase = phase,
            .result = result,
            .candidate_id = candidate_id,
            .project_sha256 = self.active.project_sha256,
            .bundle_sha256 = self.active.bundle_sha256,
            .bundle_revision = self.active.revision,
            .kernel_sha256 = self.active.kernel_sha256,
            .request_sha256 = invocation.request_sha256,
            .verdict_sha256 = invocation.verdict_sha256,
            .checker_failure = if (invocation.failure == .none) null else @tagName(invocation.failure),
            .checker_elapsed_ns = invocation.checker_elapsed_ns,
            .checker_bytes = invocation.checker_bytes,
        } });
    }
};

fn persistRuntimeVerdict(
    directory: []const u8,
    verdict_sha256: [64]u8,
    payload: []const u8,
) !void {
    if (payload.len == 0 or payload.len > kernel.MAX_OUTPUT_BYTES or
        !std.mem.eql(u8, &observation.sha256Hex(payload), &verdict_sha256))
        return error.InvalidRuntimeVerdict;
    var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/{s}{s}.json\x00",
        .{ directory, RUNTIME_VERDICT_PREFIX, verdict_sha256[0..] },
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
    const existing = try readRuntimeVerdict(std.heap.c_allocator, directory, verdict_sha256);
    defer std.heap.c_allocator.free(existing);
    if (!std.mem.eql(u8, existing, payload)) return error.RuntimeVerdictCollision;
}

pub fn readRuntimeVerdict(
    allocator: std.mem.Allocator,
    directory: []const u8,
    verdict_sha256: [64]u8,
) ![]u8 {
    var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/{s}{s}.json\x00",
        .{ directory, RUNTIME_VERDICT_PREFIX, verdict_sha256[0..] },
    );
    const fd = pfs.open(@ptrCast(path.ptr), .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.RuntimeVerdictOpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.RuntimeVerdictStatFailed;
    if (!before.is_regular or before.link_count != 1 or before.size == 0 or before.size > kernel.MAX_OUTPUT_BYTES)
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
