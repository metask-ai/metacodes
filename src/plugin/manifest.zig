//! Strict `.metacodes-plugin/plugin.json` parser.
//!
//! The Host supplies the plugin form through the loading channel. A manifest
//! can never promote a data source into executable authority by adding a field.

const std = @import("std");
const contract = @import("contract.zig");

pub const MAX_MANIFEST_BYTES: usize = 64 * 1024;
pub const MAX_CAPABILITIES: usize = 16;
pub const MAX_DEPENDENCIES: usize = 64;

pub const ParseError = std.mem.Allocator.Error || error{
    InvalidManifest,
    UnsupportedSchema,
    UnsupportedCapability,
};

const RawDependency = struct {
    id: []const u8,
    minimum_version: []const u8,
};

const RawManifest = struct {
    schema_version: u32,
    id: []const u8,
    version: []const u8,
    capabilities: []const []const u8,
    requires: []const RawDependency = &.{},
};

/// All slices are owned by `arena`. Requiring the concrete ArenaAllocator makes
/// the transactional lifetime explicit: parse failures and later stage failures
/// are reclaimed by the caller's single arena deinit, with no partial frees.
pub fn parse(arena: *std.heap.ArenaAllocator, bytes: []const u8) ParseError!contract.Descriptor {
    return parseForForm(arena, bytes, .data_package);
}

pub fn parseForForm(
    arena: *std.heap.ArenaAllocator,
    bytes: []const u8,
    form: contract.Form,
) ParseError!contract.Descriptor {
    const allocator = arena.allocator();
    if (bytes.len == 0 or bytes.len > MAX_MANIFEST_BYTES) return error.InvalidManifest;
    var parsed = std.json.parseFromSlice(RawManifest, allocator, bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidManifest,
    };
    defer parsed.deinit();
    const raw = parsed.value;
    if (raw.schema_version != contract.SCHEMA_VERSION) return error.UnsupportedSchema;
    if (raw.capabilities.len == 0 or raw.capabilities.len > MAX_CAPABILITIES or
        raw.requires.len > MAX_DEPENDENCIES) return error.InvalidManifest;

    const id_bytes = try allocator.dupe(u8, raw.id);
    const id = contract.PluginId.parse(id_bytes) catch return error.InvalidManifest;
    const version_bytes = try allocator.dupe(u8, raw.version);
    const version = contract.Version.parse(version_bytes) catch return error.InvalidManifest;

    var capabilities: contract.CapabilitySet = .{};
    for (raw.capabilities) |name| {
        const capability = contract.Capability.parse(name) orelse return error.UnsupportedCapability;
        capabilities.insert(capability) catch return error.InvalidManifest;
    }

    const dependencies = try allocator.alloc(contract.Dependency, raw.requires.len);
    for (raw.requires, 0..) |dependency, index| {
        const dependency_id_bytes = try allocator.dupe(u8, dependency.id);
        const dependency_version_bytes = try allocator.dupe(u8, dependency.minimum_version);
        dependencies[index] = .{
            .id = contract.PluginId.parse(dependency_id_bytes) catch return error.InvalidManifest,
            .minimum = contract.Version.parse(dependency_version_bytes) catch return error.InvalidManifest,
        };
    }

    const descriptor = contract.Descriptor{
        .id = id,
        .version = version,
        .form = form,
        .capabilities = capabilities,
        .dependencies = dependencies,
    };
    descriptor.validate() catch return error.InvalidManifest;
    return descriptor;
}

test "loading channel fixes manifest form and capability boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes =
        "{\"schema_version\":1,\"id\":\"acme.review\",\"version\":\"1.0.0\",\"capabilities\":[\"host_tool\"]}";
    const descriptor = try parseForForm(&arena, bytes, .out_of_process);
    try std.testing.expectEqual(contract.Form.out_of_process, descriptor.form);
    try std.testing.expect(descriptor.capabilities.contains(.host_tool));

    var data_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer data_arena.deinit();
    try std.testing.expectError(error.InvalidManifest, parse(&data_arena, bytes));
}

test "strict manifest parses data capabilities and dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const descriptor = try parse(&arena,
        \\{
        \\  "schema_version": 1,
        \\  "id": "acme.review",
        \\  "version": "1.2.0",
        \\  "capabilities": ["skill_bundle", "agent_bundle"],
        \\  "requires": [{"id":"acme.base","minimum_version":"1.0.0"}]
        \\}
    );
    try std.testing.expectEqualStrings("acme.review", descriptor.id.bytes);
    try std.testing.expectEqual(@as(u32, 1), descriptor.version.major);
    try std.testing.expect(descriptor.capabilities.contains(.skill_bundle));
    try std.testing.expect(descriptor.capabilities.contains(.agent_bundle));
    try std.testing.expectEqual(@as(usize, 1), descriptor.dependencies.len);
    try std.testing.expectEqualStrings("acme.base", descriptor.dependencies[0].id.bytes);
}

test "manifest rejects unknown fields duplicate claims executable data and unsupported schema" {
    const cases = [_]struct { bytes: []const u8, expected: ParseError }{
        .{
            .bytes = "{\"schema_version\":1,\"id\":\"acme.review\",\"version\":\"1.0.0\",\"capabilities\":[\"skill_bundle\"],\"priority\":999}",
            .expected = error.InvalidManifest,
        },
        .{
            .bytes = "{\"schema_version\":1,\"id\":\"acme.review\",\"version\":\"1.0.0\",\"capabilities\":[\"skill_bundle\",\"skill_bundle\"]}",
            .expected = error.InvalidManifest,
        },
        .{
            .bytes = "{\"schema_version\":1,\"id\":\"acme.review\",\"version\":\"1.0.0\",\"capabilities\":[\"host_tool\"]}",
            .expected = error.InvalidManifest,
        },
        .{
            .bytes = "{\"schema_version\":1,\"id\":\"acme.review\",\"version\":\"1.0.0\",\"capabilities\":[\"agent_loop\"]}",
            .expected = error.UnsupportedCapability,
        },
        .{
            .bytes = "{\"schema_version\":2,\"id\":\"acme.review\",\"version\":\"1.0.0\",\"capabilities\":[\"skill_bundle\"]}",
            .expected = error.UnsupportedSchema,
        },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(case.expected, parse(&arena, case.bytes));
    }
}
