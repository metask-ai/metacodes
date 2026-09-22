//! The identity a Metacodes-owned TinyKG supervisor serves.
//!
//! `metacodes kg install` writes `expected_build_id` into `daemon.json`, and
//! `metacodes kgd` reports a build id on every response; the client refuses to
//! talk to a daemon whose build id differs from the one it was configured for
//! (`src/kg/transport.zig`). Both sides therefore derive it here, from the same
//! bytes: the staged TinyKG CLI and daemon executables plus the metadata the
//! CLI declares about itself. Nothing in it depends on the Metacodes build, so
//! rebuilding Metacodes does not invalidate a configuration; changing the
//! TinyKG bundle does, which is the point.

const std = @import("std");
const common = @import("../../tools/common.zig");
const pfs = @import("platform").fs;

pub const SERVICE_IMPLEMENTATION = "metacodes-kgd";
pub const ENGINE_IMPLEMENTATION = "tinykg-cli";
pub const TASK_HIERARCHY_CAPABILITY = "task-hierarchy-canonical-read-v1";

/// Bump when the envelope this supervisor serves changes in a way a client can
/// observe. It is part of the build id, so a change re-pins every daemon.json
/// instead of silently serving a different contract under the same identity.
pub const SERVICE_CONTRACT = "metacodes-kgd/1";

/// The same ceiling the TinyKG daemon protocol puts on a capability list.
pub const MAX_CAPABILITIES = 32;
const VERSION_PROBE_TIMEOUT_MS = 5_000;

pub const Error = error{
    BinaryUnreadable,
    VersionProbeFailed,
    EngineMetadataInvalid,
    OutOfMemory,
};

/// Owned. `deinit` frees everything, including the capability list.
pub const Identity = struct {
    allocator: std.mem.Allocator,
    engine_implementation: []u8,
    engine_version: []u8,
    /// Sorted and duplicate-free, exactly as served to clients.
    capabilities: [][]u8,
    cli_sha256: [64]u8,
    daemon_sha256: [64]u8,
    /// `sha256:<64 hex>` as the client's `buildIdValid` requires.
    build_id: [71]u8,

    pub fn deinit(self: *Identity) void {
        for (self.capabilities) |capability| self.allocator.free(capability);
        self.allocator.free(self.capabilities);
        self.allocator.free(self.engine_implementation);
        self.allocator.free(self.engine_version);
    }

    pub fn buildId(self: *const Identity) []const u8 {
        return self.build_id[0..];
    }

    pub fn declares(self: *const Identity, capability: []const u8) bool {
        for (self.capabilities) |declared| {
            if (std.mem.eql(u8, declared, capability)) return true;
        }
        return false;
    }

    /// A stable 64-hex identity of the contract this supervisor serves for one
    /// store. It is deliberately **not** the upstream canonical schema file's
    /// digest: Metacodes ships the executables, not TinyKG's schema document.
    /// The client only requires a well-formed digest that stays constant for
    /// the life of its connection and matches `expected_schema_digest` when the
    /// configuration pins one, so this binds the engine version to the store
    /// contract it reported and changes when either moves.
    pub fn schemaDigest(
        self: *const Identity,
        storage_format_version: []const u8,
        store_schema_version: []const u8,
    ) [64]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("metacodes-kgd-schema-v1");
        for ([_][]const u8{
            self.engine_version,
            storage_format_version,
            store_schema_version,
        }) |field| {
            hash.update("\x00");
            hash.update(field);
        }
        return hexDigest(hash.finalResult());
    }
};

/// Read both executables and ask the CLI what it is. Every failure is terminal:
/// a supervisor that cannot establish its own identity must not serve requests
/// under a guessed one.
pub fn discover(
    allocator: std.mem.Allocator,
    cli_path: []const u8,
    daemon_path: []const u8,
) Error!Identity {
    const cli_sha256 = try fileSha256(allocator, cli_path);
    const daemon_sha256 = try fileSha256(allocator, daemon_path);

    const argv = [_]?[*:0]const u8{
        (allocator.dupeZ(u8, cli_path) catch return Error.OutOfMemory).ptr,
        "version",
        "--format",
        "json",
        null,
    };
    defer allocator.free(std.mem.span(argv[0].?));
    const stdout = common.spawnCaptureStdoutAbortableTimed(&argv, allocator, null, VERSION_PROBE_TIMEOUT_MS) catch
        return Error.VersionProbeFailed;
    defer allocator.free(stdout);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, std.mem.trim(u8, stdout, " \t\r\n"), .{}) catch
        return Error.EngineMetadataInvalid;
    defer parsed.deinit();
    if (parsed.value != .object) return Error.EngineMetadataInvalid;
    const root = parsed.value.object;

    const implementation = stringField(root, "implementation") orelse return Error.EngineMetadataInvalid;
    if (!std.mem.eql(u8, implementation, ENGINE_IMPLEMENTATION)) return Error.EngineMetadataInvalid;
    const version = stringField(root, "version") orelse return Error.EngineMetadataInvalid;
    if (version.len == 0) return Error.EngineMetadataInvalid;

    const capabilities = try collectCapabilities(allocator, root);
    errdefer {
        for (capabilities) |capability| allocator.free(capability);
        allocator.free(capabilities);
    }
    // The canonical task-hierarchy capability is what makes an engine usable at
    // all; serving a list without it would advertise a daemon no client accepts.
    var found_task_hierarchy = false;
    for (capabilities) |capability| {
        if (std.mem.eql(u8, capability, TASK_HIERARCHY_CAPABILITY)) found_task_hierarchy = true;
    }
    if (!found_task_hierarchy) return Error.EngineMetadataInvalid;

    const owned_implementation = allocator.dupe(u8, implementation) catch return Error.OutOfMemory;
    errdefer allocator.free(owned_implementation);
    const owned_version = allocator.dupe(u8, version) catch return Error.OutOfMemory;
    errdefer allocator.free(owned_version);

    var identity = Identity{
        .allocator = allocator,
        .engine_implementation = owned_implementation,
        .engine_version = owned_version,
        .capabilities = capabilities,
        .cli_sha256 = cli_sha256,
        .daemon_sha256 = daemon_sha256,
        .build_id = undefined,
    };
    identity.build_id = computeBuildId(&identity);
    return identity;
}

/// Field order and separators are the contract: `kg install` and `kgd` must
/// agree byte for byte, so this never depends on map iteration order.
fn computeBuildId(identity: *const Identity) [71]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(SERVICE_CONTRACT);
    for ([_][]const u8{
        SERVICE_IMPLEMENTATION,
        identity.engine_implementation,
        identity.engine_version,
        identity.cli_sha256[0..],
        identity.daemon_sha256[0..],
    }) |field| {
        hash.update("\x00");
        hash.update(field);
    }
    for (identity.capabilities) |capability| {
        hash.update("\x00");
        hash.update(capability);
    }
    var out: [71]u8 = undefined;
    @memcpy(out[0..7], "sha256:");
    @memcpy(out[7..], &hexDigest(hash.finalResult()));
    return out;
}

fn collectCapabilities(allocator: std.mem.Allocator, root: std.json.ObjectMap) Error![][]u8 {
    const raw = root.get("capabilities") orelse return Error.EngineMetadataInvalid;
    if (raw != .array or raw.array.items.len > MAX_CAPABILITIES) return Error.EngineMetadataInvalid;
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }
    for (raw.array.items) |item| {
        if (item != .string or item.string.len == 0) return Error.EngineMetadataInvalid;
        // The build id is a NUL-separated concatenation, so a capability that
        // contains a separator byte could make two different metadata sets hash
        // to the same identity. Capability names are identifiers; anything with
        // a control byte in it is not one.
        for (item.string) |byte| {
            if (byte < 0x20 or byte == 0x7f) return Error.EngineMetadataInvalid;
        }
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, item.string)) return Error.EngineMetadataInvalid;
        }
        const owned = allocator.dupe(u8, item.string) catch return Error.OutOfMemory;
        list.append(allocator, owned) catch {
            allocator.free(owned);
            return Error.OutOfMemory;
        };
    }
    const owned = list.toOwnedSlice(allocator) catch return Error.OutOfMemory;
    std.mem.sort([]u8, owned, {}, lessThanSlice);
    return owned;
}

fn lessThanSlice(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn stringField(root: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = root.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

/// Streamed so a 16 MB executable never lands in memory twice.
fn fileSha256(allocator: std.mem.Allocator, path: []const u8) Error![64]u8 {
    const path_z = allocator.dupeZ(u8, path) catch return Error.OutOfMemory;
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (fd < 0) return Error.BinaryUnreadable;
    defer _ = pfs.close(fd);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const read = pfs.read(fd, &buffer);
        if (read < 0) return Error.BinaryUnreadable;
        if (read == 0) break;
        hash.update(buffer[0..@intCast(read)]);
    }
    return hexDigest(hash.finalResult());
}

fn hexDigest(bytes: [32]u8) [64]u8 {
    var out: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{&bytes}) catch unreachable;
    return out;
}

const testing = std.testing;

test "KgdIdentity: the build id is stable, prefixed and capability-ordered" {
    const a = testing.allocator;
    var first = Identity{
        .allocator = a,
        .engine_implementation = try a.dupe(u8, ENGINE_IMPLEMENTATION),
        .engine_version = try a.dupe(u8, "0.3.0"),
        .capabilities = try dupeCapabilities(a, &.{ TASK_HIERARCHY_CAPABILITY, "z-capability" }),
        .cli_sha256 = ("a" ** 64).*,
        .daemon_sha256 = ("b" ** 64).*,
        .build_id = undefined,
    };
    defer first.deinit();
    first.build_id = computeBuildId(&first);
    try testing.expect(std.mem.startsWith(u8, first.buildId(), "sha256:"));
    try testing.expectEqual(@as(usize, 71), first.buildId().len);
    for (first.buildId()[7..]) |byte| try testing.expect(std.ascii.isHex(byte) and !std.ascii.isUpper(byte));

    // Same inputs, same id: `kg install` and `kgd` are separate processes.
    var again = Identity{
        .allocator = a,
        .engine_implementation = try a.dupe(u8, ENGINE_IMPLEMENTATION),
        .engine_version = try a.dupe(u8, "0.3.0"),
        .capabilities = try dupeCapabilities(a, &.{ TASK_HIERARCHY_CAPABILITY, "z-capability" }),
        .cli_sha256 = ("a" ** 64).*,
        .daemon_sha256 = ("b" ** 64).*,
        .build_id = undefined,
    };
    defer again.deinit();
    again.build_id = computeBuildId(&again);
    try testing.expectEqualStrings(first.buildId(), again.buildId());
}

test "KgdIdentity: every input the client trusts moves the build id" {
    const a = testing.allocator;
    const base = try buildIdOf(a, "0.3.0", ("a" ** 64).*, ("b" ** 64).*, &.{TASK_HIERARCHY_CAPABILITY});
    const other_version = try buildIdOf(a, "0.3.1", ("a" ** 64).*, ("b" ** 64).*, &.{TASK_HIERARCHY_CAPABILITY});
    const other_cli = try buildIdOf(a, "0.3.0", ("c" ** 64).*, ("b" ** 64).*, &.{TASK_HIERARCHY_CAPABILITY});
    const other_daemon = try buildIdOf(a, "0.3.0", ("a" ** 64).*, ("d" ** 64).*, &.{TASK_HIERARCHY_CAPABILITY});
    const other_caps = try buildIdOf(a, "0.3.0", ("a" ** 64).*, ("b" ** 64).*, &.{ TASK_HIERARCHY_CAPABILITY, "extra" });
    for ([_][71]u8{ other_version, other_cli, other_daemon, other_caps }) |variant| {
        try testing.expect(!std.mem.eql(u8, &base, &variant));
    }
}

test "KgdIdentity: the schema digest binds the engine version to the store contract" {
    const a = testing.allocator;
    var identity = Identity{
        .allocator = a,
        .engine_implementation = try a.dupe(u8, ENGINE_IMPLEMENTATION),
        .engine_version = try a.dupe(u8, "0.3.0"),
        .capabilities = try dupeCapabilities(a, &.{TASK_HIERARCHY_CAPABILITY}),
        .cli_sha256 = ("a" ** 64).*,
        .daemon_sha256 = ("b" ** 64).*,
        .build_id = undefined,
    };
    defer identity.deinit();
    const digest = identity.schemaDigest("3", "3");
    for (digest) |byte| try testing.expect(std.ascii.isHex(byte) and !std.ascii.isUpper(byte));
    try testing.expectEqualSlices(u8, &digest, &identity.schemaDigest("3", "3"));
    try testing.expect(!std.mem.eql(u8, &digest, &identity.schemaDigest("4", "3")));
    try testing.expect(!std.mem.eql(u8, &digest, &identity.schemaDigest("3", "4")));
}

fn dupeCapabilities(allocator: std.mem.Allocator, values: []const []const u8) ![][]u8 {
    const owned = try allocator.alloc([]u8, values.len);
    for (values, 0..) |value, index| owned[index] = try allocator.dupe(u8, value);
    return owned;
}

fn buildIdOf(
    allocator: std.mem.Allocator,
    version: []const u8,
    cli: [64]u8,
    daemon: [64]u8,
    capabilities: []const []const u8,
) ![71]u8 {
    var identity = Identity{
        .allocator = allocator,
        .engine_implementation = try allocator.dupe(u8, ENGINE_IMPLEMENTATION),
        .engine_version = try allocator.dupe(u8, version),
        .capabilities = try dupeCapabilities(allocator, capabilities),
        .cli_sha256 = cli,
        .daemon_sha256 = daemon,
        .build_id = undefined,
    };
    defer identity.deinit();
    return computeBuildId(&identity);
}

test "KgdIdentity: discovery reads the staged TinyKG bundle" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    const cli = std.c.getenv("METACODES_TEST_TINYKG_BIN") orelse return error.SkipZigTest;
    const daemon = std.c.getenv("METACODES_TEST_TINYKGD_BIN") orelse return error.SkipZigTest;
    var identity = try discover(a, std.mem.span(cli), std.mem.span(daemon));
    defer identity.deinit();
    try testing.expectEqualStrings(ENGINE_IMPLEMENTATION, identity.engine_implementation);
    try testing.expect(identity.engine_version.len > 0);
    try testing.expect(identity.declares(TASK_HIERARCHY_CAPABILITY));
    try testing.expect(std.mem.startsWith(u8, identity.buildId(), "sha256:"));
    // The two executables are different files, so their digests must differ.
    try testing.expect(!std.mem.eql(u8, &identity.cli_sha256, &identity.daemon_sha256));
}
