//! Revision 7 MCP protocol-era negotiation and disposable-probe ownership.
//!
//! Transport implementations live in the later Runtime integration task.
//! This module freezes the policy and lifecycle contract without importing the
//! product MCP transport or process code.

const std = @import("std");
const canonical = @import("mcp_canonical.zig");

pub const Policy = enum(u8) {
    auto,
    modern_only,
    legacy_only,
    legacy_2025_06_only,
};

pub const Transport = enum(u8) {
    stdio,
    streamable_http,
};

/// Observations are emitted only after the modern probe response has passed
/// its transport framing and JSON-RPC shape checks. `method_not_found` is
/// therefore distinct from arbitrary malformed bytes containing -32601.
pub const ProbeObservation = union(enum) {
    discovered_versions: []const []const u8,
    method_not_found,
    timeout,
    child_exit,
    network_error,
    auth_error,
    server_error,
    malformed_response,
    cancelled,
};

pub const RevalidatedProtocol = union(enum) {
    known: canonical.Era,
    unsupported_revision,
};

pub const DriverError = error{
    TransportFailure,
    ResourceLimit,
    OutOfMemory,
};

/// `connect` must either establish one actual connection or leave no live
/// resource. On successful `negotiate`, that connection remains owned by the
/// caller/Runtime. On revalidation failure this module invokes `disconnect`.
pub const Driver = struct {
    ctx: ?*anyopaque,
    start_probe_fn: *const fn (?*anyopaque, Transport) DriverError!void,
    observe_probe_fn: *const fn (?*anyopaque) DriverError!ProbeObservation,
    finish_probe_fn: *const fn (?*anyopaque) void,
    connect_fn: *const fn (?*anyopaque, canonical.Era) DriverError!void,
    revalidate_fn: *const fn (?*anyopaque, canonical.Era) DriverError!RevalidatedProtocol,
    disconnect_fn: *const fn (?*anyopaque) void,
};

pub fn selectFromProbe(
    policy: Policy,
    transport: Transport,
    observation: ProbeObservation,
) canonical.Outcome(canonical.Era) {
    if (policy == .legacy_only)
        return .{ .value = .classic_2025_11_25 };
    if (policy == .legacy_2025_06_only)
        return .{ .value = .classic_2025_06_18 };

    return switch (observation) {
        .discovered_versions => |versions| selectFromVersions(policy, versions),
        .method_not_found => if (policy == .auto)
            .{ .value = .classic_2025_11_25 }
        else
            .{ .diagnostic = canonical.Diagnostic.init(.unsupported_protocol_version, .negotiation) },
        .timeout => if (policy == .auto and transport == .stdio)
            .{ .value = .classic_2025_11_25 }
        else
            .{ .diagnostic = canonical.Diagnostic.init(
                if (transport == .streamable_http) .downgrade_refused else .probe_failed,
                .negotiation,
            ) },
        .child_exit => if (policy == .auto and transport == .stdio)
            .{ .value = .classic_2025_11_25 }
        else
            .{ .diagnostic = canonical.Diagnostic.init(.probe_failed, .negotiation) },
        .network_error, .auth_error, .server_error => .{
            .diagnostic = canonical.Diagnostic.init(
                if (transport == .streamable_http) .downgrade_refused else .probe_failed,
                .negotiation,
            ),
        },
        .malformed_response, .cancelled => .{
            .diagnostic = canonical.Diagnostic.init(.probe_failed, .negotiation),
        },
    };
}

pub fn selectFromVersions(
    policy: Policy,
    versions: []const []const u8,
) canonical.Outcome(canonical.Era) {
    var has_modern = false;
    var has_classic_11 = false;
    var has_classic_06 = false;
    for (versions) |version| {
        switch (canonical.Era.parseExact(version) orelse continue) {
            .modern_2026_07_28 => has_modern = true,
            .classic_2025_11_25 => has_classic_11 = true,
            .classic_2025_06_18 => has_classic_06 = true,
        }
    }
    return switch (policy) {
        .modern_only => if (has_modern)
            .{ .value = .modern_2026_07_28 }
        else
            .{ .diagnostic = canonical.Diagnostic.init(.unsupported_protocol_version, .negotiation) },
        .legacy_only => if (has_classic_11)
            .{ .value = .classic_2025_11_25 }
        else
            .{ .diagnostic = canonical.Diagnostic.init(.unsupported_protocol_version, .negotiation) },
        .legacy_2025_06_only => if (has_classic_06)
            .{ .value = .classic_2025_06_18 }
        else
            .{ .diagnostic = canonical.Diagnostic.init(.unsupported_protocol_version, .negotiation) },
        .auto => if (has_modern)
            .{ .value = .modern_2026_07_28 }
        else if (has_classic_11)
            .{ .value = .classic_2025_11_25 }
        else if (has_classic_06)
            .{ .value = .classic_2025_06_18 }
        else
            .{ .diagnostic = canonical.Diagnostic.init(.unsupported_protocol_version, .negotiation) },
    };
}

pub fn negotiate(
    driver: Driver,
    policy: Policy,
    transport: Transport,
) error{OutOfMemory}!canonical.Outcome(canonical.Era) {
    const selected: canonical.Era = switch (policy) {
        .modern_only => .modern_2026_07_28,
        .legacy_only => .classic_2025_11_25,
        .legacy_2025_06_only => .classic_2025_06_18,
        .auto => blk: {
            driver.start_probe_fn(driver.ctx, transport) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .{ .diagnostic = canonical.Diagnostic.init(.probe_failed, .negotiation) };
            };
            var probe_open = true;
            defer if (probe_open) driver.finish_probe_fn(driver.ctx);
            const observation = driver.observe_probe_fn(driver.ctx) catch |err| {
                driver.finish_probe_fn(driver.ctx);
                probe_open = false;
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .{ .diagnostic = canonical.Diagnostic.init(.probe_failed, .negotiation) };
            };
            const selection = selectFromProbe(.auto, transport, observation);
            // The disposable stdio child (or bounded HTTP probe context) is
            // always gone before the real connection starts.
            driver.finish_probe_fn(driver.ctx);
            probe_open = false;
            break :blk switch (selection) {
                .value => |era| era,
                .diagnostic => |diagnostic| return .{ .diagnostic = diagnostic },
            };
        },
    };

    driver.connect_fn(driver.ctx, selected) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .diagnostic = canonical.Diagnostic.init(.connection_failed, .negotiation) };
    };
    const actual = driver.revalidate_fn(driver.ctx, selected) catch |err| {
        driver.disconnect_fn(driver.ctx);
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .diagnostic = canonical.Diagnostic.init(.connection_failed, .revalidation) };
    };
    const actual_era = switch (actual) {
        .known => |era| era,
        .unsupported_revision => {
            driver.disconnect_fn(driver.ctx);
            return .{ .diagnostic = canonical.Diagnostic.init(.unsupported_protocol_version, .revalidation) };
        },
    };
    if (actual_era == selected) return .{ .value = selected };

    // AUTO's Classic probe starts with the newest Classic era. A server may
    // legally select 2025-06-18 from that initialize request. The first
    // connection is never promoted: close it, reopen exact 2025-06-18 once,
    // and accept only the second exact handshake.
    if (policy == .auto and selected == .classic_2025_11_25 and
        actual_era == .classic_2025_06_18)
    {
        driver.disconnect_fn(driver.ctx);
        driver.connect_fn(driver.ctx, .classic_2025_06_18) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .diagnostic = canonical.Diagnostic.init(.connection_failed, .negotiation) };
        };
        const reopened = driver.revalidate_fn(driver.ctx, .classic_2025_06_18) catch |err| {
            driver.disconnect_fn(driver.ctx);
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .diagnostic = canonical.Diagnostic.init(.connection_failed, .revalidation) };
        };
        switch (reopened) {
            .known => |era| if (era == .classic_2025_06_18)
                return .{ .value = .classic_2025_06_18 },
            .unsupported_revision => {},
        }
        driver.disconnect_fn(driver.ctx);
        return .{ .diagnostic = canonical.Diagnostic.init(.era_revalidation_mismatch, .revalidation) };
    }
    driver.disconnect_fn(driver.ctx);
    return .{ .diagnostic = canonical.Diagnostic.init(.era_revalidation_mismatch, .revalidation) };
}

const FakeDriver = struct {
    observation: ProbeObservation,
    actual: RevalidatedProtocol,
    revalidate_sequence: []const RevalidatedProtocol = &.{},
    revalidate_index: usize = 0,
    fail_start: bool = false,
    fail_observe: bool = false,
    fail_connect: bool = false,
    fail_revalidate: bool = false,
    probe_open: bool = false,
    actual_open: bool = false,
    probe_starts: u8 = 0,
    probe_finishes: u8 = 0,
    connects: u8 = 0,
    disconnects: u8 = 0,
    connect_saw_probe_open: bool = false,
    target: ?canonical.Era = null,

    fn interface(self: *FakeDriver) Driver {
        return .{
            .ctx = self,
            .start_probe_fn = startProbe,
            .observe_probe_fn = observeProbe,
            .finish_probe_fn = finishProbe,
            .connect_fn = connect,
            .revalidate_fn = revalidate,
            .disconnect_fn = disconnect,
        };
    }

    fn cast(raw: ?*anyopaque) *FakeDriver {
        return @ptrCast(@alignCast(raw.?));
    }

    fn startProbe(raw: ?*anyopaque, _: Transport) DriverError!void {
        const self = cast(raw);
        if (self.fail_start or self.probe_open) return error.TransportFailure;
        self.probe_open = true;
        self.probe_starts += 1;
    }

    fn observeProbe(raw: ?*anyopaque) DriverError!ProbeObservation {
        const self = cast(raw);
        if (self.fail_observe or !self.probe_open) return error.TransportFailure;
        return self.observation;
    }

    fn finishProbe(raw: ?*anyopaque) void {
        const self = cast(raw);
        if (!self.probe_open) return;
        self.probe_open = false;
        self.probe_finishes += 1;
    }

    fn connect(raw: ?*anyopaque, era: canonical.Era) DriverError!void {
        const self = cast(raw);
        self.connect_saw_probe_open = self.probe_open;
        if (self.fail_connect or self.actual_open) return error.TransportFailure;
        self.actual_open = true;
        self.connects += 1;
        self.target = era;
    }

    fn revalidate(raw: ?*anyopaque, _: canonical.Era) DriverError!RevalidatedProtocol {
        const self = cast(raw);
        if (self.fail_revalidate or !self.actual_open) return error.TransportFailure;
        if (self.revalidate_index < self.revalidate_sequence.len) {
            const result = self.revalidate_sequence[self.revalidate_index];
            self.revalidate_index += 1;
            return result;
        }
        return self.actual;
    }

    fn disconnect(raw: ?*anyopaque) void {
        const self = cast(raw);
        if (!self.actual_open) return;
        self.actual_open = false;
        self.disconnects += 1;
    }
};

test "auto stdio uses disposable probe before opening a legacy connection" {
    var fake = FakeDriver{
        .observation = .timeout,
        .actual = .{ .known = .classic_2025_11_25 },
    };
    const result = try negotiate(fake.interface(), .auto, .stdio);
    try std.testing.expectEqual(canonical.Era.classic_2025_11_25, result.value);
    try std.testing.expectEqual(@as(u8, 1), fake.probe_starts);
    try std.testing.expectEqual(@as(u8, 1), fake.probe_finishes);
    try std.testing.expectEqual(@as(u8, 1), fake.connects);
    try std.testing.expect(!fake.connect_saw_probe_open);
    try std.testing.expect(fake.actual_open);
}

test "HTTP timeout cannot trigger legacy downgrade" {
    var fake = FakeDriver{
        .observation = .timeout,
        .actual = .{ .known = .classic_2025_11_25 },
    };
    const result = try negotiate(fake.interface(), .auto, .streamable_http);
    try std.testing.expectEqual(canonical.DiagnosticCode.downgrade_refused, result.diagnostic.code);
    try std.testing.expectEqual(@as(u8, 1), fake.probe_finishes);
    try std.testing.expectEqual(@as(u8, 0), fake.connects);
    try std.testing.expect(!fake.actual_open);
}

test "well formed MethodNotFound may select the one legacy era" {
    var fake = FakeDriver{
        .observation = .method_not_found,
        .actual = .{ .known = .classic_2025_11_25 },
    };
    const result = try negotiate(fake.interface(), .auto, .streamable_http);
    try std.testing.expectEqual(canonical.Era.classic_2025_11_25, result.value);
    try std.testing.expectEqual(canonical.Era.classic_2025_11_25, fake.target.?);
}

test "AUTO closes 2025-11 selection and reopens exact 2025-06 once" {
    var fake = FakeDriver{
        .observation = .method_not_found,
        .actual = .{ .known = .classic_2025_06_18 },
    };
    const result = try negotiate(fake.interface(), .auto, .stdio);
    try std.testing.expectEqual(canonical.Era.classic_2025_06_18, result.value);
    try std.testing.expectEqual(@as(u8, 2), fake.connects);
    try std.testing.expectEqual(@as(u8, 1), fake.disconnects);
    try std.testing.expectEqual(canonical.Era.classic_2025_06_18, fake.target.?);
    try std.testing.expect(fake.actual_open);
}

test "AUTO rejects a reopened connection that does not revalidate as exact 2025-06" {
    const revalidations = [_]RevalidatedProtocol{
        .{ .known = .classic_2025_06_18 },
        .{ .known = .classic_2025_11_25 },
    };
    var fake = FakeDriver{
        .observation = .method_not_found,
        .actual = .unsupported_revision,
        .revalidate_sequence = &revalidations,
    };
    const result = try negotiate(fake.interface(), .auto, .stdio);
    try std.testing.expectEqual(
        canonical.DiagnosticCode.era_revalidation_mismatch,
        result.diagnostic.code,
    );
    try std.testing.expectEqual(@as(usize, 2), fake.revalidate_index);
    try std.testing.expectEqual(@as(u8, 2), fake.connects);
    try std.testing.expectEqual(@as(u8, 2), fake.disconnects);
    try std.testing.expect(!fake.actual_open);
}

test "AUTO rejects an unsupported revision from the reopened 2025-06 connection" {
    const revalidations = [_]RevalidatedProtocol{
        .{ .known = .classic_2025_06_18 },
        .unsupported_revision,
    };
    var fake = FakeDriver{
        .observation = .method_not_found,
        .actual = .{ .known = .classic_2025_06_18 },
        .revalidate_sequence = &revalidations,
    };
    const result = try negotiate(fake.interface(), .auto, .stdio);
    try std.testing.expectEqual(
        canonical.DiagnosticCode.era_revalidation_mismatch,
        result.diagnostic.code,
    );
    try std.testing.expectEqual(@as(usize, 2), fake.revalidate_index);
    try std.testing.expectEqual(@as(u8, 2), fake.disconnects);
    try std.testing.expect(!fake.actual_open);
}

test "exact 2025-06 policy skips probe and rejects a different selected era" {
    var exact = FakeDriver{
        .observation = .malformed_response,
        .actual = .{ .known = .classic_2025_06_18 },
    };
    try std.testing.expectEqual(
        canonical.Era.classic_2025_06_18,
        (try negotiate(exact.interface(), .legacy_2025_06_only, .stdio)).value,
    );
    try std.testing.expectEqual(@as(u8, 0), exact.probe_starts);

    var mismatch = FakeDriver{
        .observation = .malformed_response,
        .actual = .{ .known = .classic_2025_11_25 },
    };
    const failed = try negotiate(mismatch.interface(), .legacy_2025_06_only, .stdio);
    try std.testing.expectEqual(
        canonical.DiagnosticCode.era_revalidation_mismatch,
        failed.diagnostic.code,
    );
    try std.testing.expectEqual(@as(u8, 0), mismatch.probe_starts);
    try std.testing.expectEqual(@as(u8, 1), mismatch.connects);
    try std.testing.expectEqual(@as(u8, 1), mismatch.disconnects);
}

test "real connection era mismatch fails without silent renegotiation" {
    const versions = [_][]const u8{canonical.MODERN_VERSION};
    var fake = FakeDriver{
        .observation = .{ .discovered_versions = &versions },
        .actual = .{ .known = .classic_2025_11_25 },
    };
    const result = try negotiate(fake.interface(), .auto, .stdio);
    try std.testing.expectEqual(
        canonical.DiagnosticCode.era_revalidation_mismatch,
        result.diagnostic.code,
    );
    try std.testing.expectEqual(@as(u8, 1), fake.probe_starts);
    try std.testing.expectEqual(@as(u8, 1), fake.connects);
    try std.testing.expectEqual(@as(u8, 1), fake.disconnects);
    try std.testing.expect(!fake.actual_open);
}

test "version selection prefers modern and rejects all older revisions" {
    const both = [_][]const u8{ canonical.CLASSIC_2025_06_VERSION, canonical.CLASSIC_2025_11_VERSION, canonical.MODERN_VERSION };
    try std.testing.expectEqual(
        canonical.Era.modern_2026_07_28,
        selectFromVersions(.auto, &both).value,
    );
    const old = [_][]const u8{"2024-11-05"};
    try std.testing.expectEqual(
        canonical.DiagnosticCode.unsupported_protocol_version,
        selectFromVersions(.auto, &old).diagnostic.code,
    );
    try std.testing.expectEqual(
        canonical.DiagnosticCode.unsupported_protocol_version,
        selectFromVersions(.modern_only, &[_][]const u8{canonical.CLASSIC_2025_11_VERSION}).diagnostic.code,
    );
}

test "explicit policies skip probing and still revalidate actual era" {
    var modern = FakeDriver{
        .observation = .malformed_response,
        .actual = .{ .known = .modern_2026_07_28 },
    };
    try std.testing.expectEqual(
        canonical.Era.modern_2026_07_28,
        (try negotiate(modern.interface(), .modern_only, .stdio)).value,
    );
    try std.testing.expectEqual(@as(u8, 0), modern.probe_starts);
    var legacy = FakeDriver{
        .observation = .malformed_response,
        .actual = .{ .known = .classic_2025_11_25 },
    };
    try std.testing.expectEqual(
        canonical.Era.classic_2025_11_25,
        (try negotiate(legacy.interface(), .legacy_only, .streamable_http)).value,
    );
    try std.testing.expectEqual(@as(u8, 0), legacy.probe_starts);
}

test "stdio child exit may select legacy and always closes the disposable probe" {
    var fake = FakeDriver{
        .observation = .child_exit,
        .actual = .{ .known = .classic_2025_11_25 },
    };
    const result = try negotiate(fake.interface(), .auto, .stdio);
    try std.testing.expectEqual(canonical.Era.classic_2025_11_25, result.value);
    try std.testing.expectEqual(@as(u8, 1), fake.probe_starts);
    try std.testing.expectEqual(@as(u8, 1), fake.probe_finishes);
    try std.testing.expectEqual(@as(u8, 1), fake.connects);
    try std.testing.expect(!fake.connect_saw_probe_open);
}

test "probe allocation failure is not mislabeled as a transport failure" {
    var fake = FakeDriver{
        .observation = .malformed_response,
        .actual = .{ .known = .modern_2026_07_28 },
        .fail_observe = true,
    };
    const OomDriver = struct {
        fn observe(raw: ?*anyopaque) DriverError!ProbeObservation {
            _ = raw;
            return error.OutOfMemory;
        }
    };
    var driver = fake.interface();
    driver.observe_probe_fn = OomDriver.observe;
    try std.testing.expectError(
        error.OutOfMemory,
        negotiate(driver, .auto, .stdio),
    );
    try std.testing.expectEqual(@as(u8, 1), fake.probe_finishes);
    try std.testing.expectEqual(@as(u8, 0), fake.connects);
}
