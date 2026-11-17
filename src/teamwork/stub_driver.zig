//! Test-only `SeatDriver`: plays a scripted harness. It honours the worker
//! contract the real drivers will (read the packet path, leave `handoff.md`
//! at the given path, report through `collectHandoff`), so the runtime can be
//! tested against it without a provider or a child process.

const std = @import("std");
const types = @import("types.zig");
const run_dir = @import("run_dir.zig");
const pfs = @import("platform").fs;

pub const Script = union(enum) {
    /// Write these bytes as `handoff.md`, then exit cleanly.
    write_handoff: []const u8,
    /// Exit cleanly without writing a handoff.
    no_handoff,
    /// Fail as the harness would.
    fail: types.SeatError,
    /// Stop because the seat's budget ran out.
    exhaust_budget,
};

pub const StubDriver = struct {
    script: Script,
    /// Calls made, and the last packet path seen.
    calls: usize = 0,
    last_packet: [std.fs.max_path_bytes]u8 = undefined,
    last_packet_len: usize = 0,

    pub fn driver(self: *StubDriver) types.SeatDriver {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn lastPacket(self: *const StubDriver) []const u8 {
        return self.last_packet[0..self.last_packet_len];
    }

    const vtable: types.SeatDriver.VTable = .{ .run = run };

    fn run(
        ptr: *anyopaque,
        gpa: std.mem.Allocator,
        spec: *const types.SeatSpec,
        paths: types.SeatPaths,
        abort: *const types.AbortSignal,
    ) types.SeatDriver.Error!types.SeatOutcome {
        _ = spec;
        const self: *StubDriver = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        const n = @min(paths.packet.len, self.last_packet.len);
        @memcpy(self.last_packet[0..n], paths.packet[0..n]);
        self.last_packet_len = n;

        if (abort.isAborted()) return .aborted;
        switch (self.script) {
            .write_handoff => |bytes| {
                writeFile(gpa, paths.handoff, bytes) catch return .{ .failed = .spawn_failed };
                return run_dir.collectHandoff(gpa, paths.handoff);
            },
            .no_handoff => return run_dir.collectHandoff(gpa, paths.handoff),
            .fail => |err| return .{ .failed = err },
            .exhaust_budget => return .budget_exhausted,
        }
    }

    fn writeFile(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
        const path_z = try gpa.dupeZ(u8, path);
        defer gpa.free(path_z);
        const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
        if (fd < 0) return error.OpenFailed;
        defer pfs.close(fd);
        if (!pfs.writeAll(fd, bytes)) return error.WriteFailed;
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const Fixture = struct {
    root: run_dir.test_support.TestRoot,
    run: run_dir.RunDir,
    seat: types.SeatId,
    packet: run_dir.PathBuf = undefined,
    handoff: run_dir.PathBuf = undefined,
    packet_len: usize = 0,
    handoff_len: usize = 0,

    fn init(self: *Fixture, tag: []const u8) !void {
        self.root = run_dir.test_support.TestRoot.init(tag);
        errdefer self.root.deinit();
        self.run = try run_dir.RunDir.create(testing.allocator, self.root.slice(), try types.RunId.parse("r1"));
        self.seat = types.seatIdFor(.implementer, 1);
        try self.run.createSeat(.{ .id = self.seat, .role = .implementer, .harness = .metacodes, .status = .queued });
        try self.run.writePacket(self.seat, "Implement the request in " ++ run_dir.seat_relative_original_request ++ ".\n");
        self.packet_len = (try self.run.seatPath(&self.packet, self.seat, .packet)).len;
        self.handoff_len = (try self.run.seatPath(&self.handoff, self.seat, .handoff)).len;
    }

    fn deinit(self: *Fixture) void {
        self.run.deinit(testing.allocator);
        self.root.deinit();
    }

    fn paths(self: *const Fixture) types.SeatPaths {
        return .{
            .packet = self.packet[0..self.packet_len],
            .handoff = self.handoff[0..self.handoff_len],
            .workspace = self.root.slice(),
        };
    }
};

const test_spec: types.SeatSpec = .{ .role = .implementer };

test "stub driver: a clean exit with a valid handoff is finished" {
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-stub-ok");
    defer fx.deinit();
    var stub: StubDriver = .{ .script = .{ .write_handoff = "## Observation\no\n## Reasoning\nr\n## Caveats\nc\n## Conclusion\ndone\n## Verification\nv\n" } };
    var abort = types.AbortSignal.init();
    var outcome = try stub.driver().run(testing.allocator, &test_spec, fx.paths(), &abort);
    defer outcome.deinit(testing.allocator);
    try testing.expectEqualStrings("done", outcome.finished.conclusion);
    try testing.expectEqualStrings(fx.paths().packet, stub.lastPacket());
    // The runtime reads the same handoff back from the run directory.
    var handoff = try fx.run.readHandoff(testing.allocator, fx.seat);
    defer handoff.deinit(testing.allocator);
    try testing.expectEqualStrings("done", handoff.conclusion);
}

test "stub driver: contract failures, budget and abort are outcomes, not errors" {
    var fx: Fixture = undefined;
    try fx.init("cc-zig-teamwork-stub-fail");
    defer fx.deinit();
    var abort = types.AbortSignal.init();

    var missing: StubDriver = .{ .script = .no_handoff };
    var outcome = try missing.driver().run(testing.allocator, &test_spec, fx.paths(), &abort);
    try testing.expect(outcome.failed == .handoff_missing);
    outcome.deinit(testing.allocator);

    var invalid: StubDriver = .{ .script = .{ .write_handoff = "## Observation\nonly this\n" } };
    outcome = try invalid.driver().run(testing.allocator, &test_spec, fx.paths(), &abort);
    try testing.expectEqual(error.MissingReasoning, outcome.failed.handoff_invalid);
    outcome.deinit(testing.allocator);

    var exited: StubDriver = .{ .script = .{ .fail = .{ .exited = 2 } } };
    outcome = try exited.driver().run(testing.allocator, &test_spec, fx.paths(), &abort);
    try testing.expectEqual(@as(u8, 2), outcome.failed.exited);
    outcome.deinit(testing.allocator);

    var broke: StubDriver = .{ .script = .exhaust_budget };
    outcome = try broke.driver().run(testing.allocator, &test_spec, fx.paths(), &abort);
    try testing.expect(outcome == .budget_exhausted);
    outcome.deinit(testing.allocator);

    abort.abort(.user_interrupt);
    outcome = try missing.driver().run(testing.allocator, &test_spec, fx.paths(), &abort);
    try testing.expect(outcome == .aborted);
    outcome.deinit(testing.allocator);
}
