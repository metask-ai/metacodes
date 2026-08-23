//! Stable value types for the metacodes plugin contract.
//!
//! This module intentionally contains no AgentLoop replacement capability.
//! Plugins contribute bounded capabilities to an immutable Runtime snapshot;
//! the kernel remains the sole owner of orchestration, authorization, formal
//! verdicts, TinyKG mutation/CAS, durable history and cancellation semantics.

const std = @import("std");

pub const SCHEMA_VERSION: u32 = 1;
pub const CONTRACT_VERSION: u32 = 1;
pub const MAX_PLUGIN_ID_BYTES: usize = 48;
pub const MAX_VERSION_BYTES: usize = 64;
pub const MAX_TOOL_NAME_BYTES: usize = 64;
pub const MAX_LOCAL_NAME_BYTES: usize = 32;
pub const MAX_QUALIFIED_NAME_BYTES: usize = 128;

pub const ContractError = error{
    InvalidPluginId,
    InvalidVersion,
    InvalidLocalName,
    InvalidNamespace,
    ToolNameTooLong,
    QualifiedNameTooLong,
    EmptyCapabilities,
    UnsupportedCapabilityForForm,
    DuplicateCapability,
    DuplicateDependency,
    SelfDependency,
    IncompatibleDependency,
};

/// Borrowed, validated reverse-DNS-like identity. The byte grammar is kept
/// narrower than a filesystem path or tool name so it can be encoded into all
/// downstream namespaces without traversal or Unicode-normalization hazards.
pub const PluginId = struct {
    bytes: []const u8,

    pub fn parse(raw: []const u8) ContractError!PluginId {
        if (raw.len < 3 or raw.len > MAX_PLUGIN_ID_BYTES) return error.InvalidPluginId;
        var segment_len: usize = 0;
        var segment_first: u8 = 0;
        var previous: u8 = 0;
        for (raw) |c| {
            if (c == '.') {
                if (segment_len == 0 or segment_len > 63 or !isLowerAlnum(segment_first) or !isLowerAlnum(previous))
                    return error.InvalidPluginId;
                segment_len = 0;
                segment_first = 0;
                previous = c;
                continue;
            }
            if (!isLowerAlnum(c) and c != '-') return error.InvalidPluginId;
            if (segment_len == 0) segment_first = c;
            segment_len += 1;
            previous = c;
        }
        if (segment_len == 0 or segment_len > 63 or !isLowerAlnum(segment_first) or !isLowerAlnum(previous))
            return error.InvalidPluginId;
        return .{ .bytes = raw };
    }

    pub fn eql(a: PluginId, b: PluginId) bool {
        return std.mem.eql(u8, a.bytes, b.bytes);
    }
};

/// Parsed SemVer 2.0 value. Slices borrow from the input string.
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    prerelease: []const u8 = "",
    build: []const u8 = "",

    pub fn parse(raw: []const u8) ContractError!Version {
        if (raw.len == 0 or raw.len > MAX_VERSION_BYTES) return error.InvalidVersion;

        const plus = std.mem.indexOfScalar(u8, raw, '+');
        const before_build = if (plus) |index| raw[0..index] else raw;
        const build = if (plus) |index| raw[index + 1 ..] else "";
        if (plus != null and !validIdentifiers(build, false)) return error.InvalidVersion;

        const dash = std.mem.indexOfScalar(u8, before_build, '-');
        const core = if (dash) |index| before_build[0..index] else before_build;
        const prerelease = if (dash) |index| before_build[index + 1 ..] else "";
        if (dash != null and !validIdentifiers(prerelease, true)) return error.InvalidVersion;

        var parts = std.mem.splitScalar(u8, core, '.');
        const major_raw = parts.next() orelse return error.InvalidVersion;
        const minor_raw = parts.next() orelse return error.InvalidVersion;
        const patch_raw = parts.next() orelse return error.InvalidVersion;
        if (parts.next() != null) return error.InvalidVersion;

        return .{
            .major = try parseCoreNumber(major_raw),
            .minor = try parseCoreNumber(minor_raw),
            .patch = try parseCoreNumber(patch_raw),
            .prerelease = prerelease,
            .build = build,
        };
    }

    /// Conservative SemVer-compatible dependency rule used by manifest v1:
    /// installed must be >= minimum and remain in the same compatibility line.
    /// For 1.x that is the major line; for 0.2.x the minor line; 0.0.x is exact.
    pub fn satisfies(installed: Version, minimum: Version) bool {
        if (installed.major != minimum.major) return false;
        if (minimum.major == 0 and installed.minor != minimum.minor) return false;
        if (minimum.major == 0 and minimum.minor == 0 and installed.patch != minimum.patch) return false;
        return order(installed, minimum) != .lt;
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        if (a.patch != b.patch) return std.math.order(a.patch, b.patch);
        return comparePrerelease(a.prerelease, b.prerelease);
    }
};

/// A plugin form is a trust boundary, not a performance hint.
pub const Form = enum {
    /// Compiled into or explicitly supplied by the embedding Host. It may use
    /// typed in-process callbacks and its callback contexts outlive Runtime.
    static_trusted,
    /// Filesystem data only. Conventional skill/agent/eval/evidence directories
    /// are parsed by kernel-owned readers; no package code is executed.
    data_package,
    /// Executable package behind a versioned process protocol. A worker or VM
    /// is never treated as the security boundary; native policy remains final.
    out_of_process,
};

/// Known extension categories. Activation additionally intersects this set
/// with Host support and the restrictions of `Form`.
pub const Capability = enum(u8) {
    host_tool,
    skill_bundle,
    agent_bundle,
    provider,
    advisory_hook,
    ui_backend,
    ontology_evidence,
    eval_pack,
    /// Activation-time typed dependency injection between static plugins.
    /// It never exposes kernel services or a live mutable registry.
    service,
    /// First-party compiled tool bundle. The implementation remains a native
    /// `ToolEntry` fast path, but admission, inventory and lifecycle are owned
    /// by the immutable plugin generation. Filesystem/process packages can
    /// never claim this capability.
    builtin_tool_bundle,
    /// Trusted, Runtime-scoped model dialect projection below an existing
    /// Provider transport. It may adapt request fields/system modifiers,
    /// response reasoning extraction and ModelProfile for selected model
    /// prefixes, but does not own credentials, HTTP or the agent loop.
    provider_dialect,

    pub fn parse(raw: []const u8) ?Capability {
        inline for (std.meta.fields(Capability)) |field| {
            if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn allowedIn(self: Capability, form: Form) bool {
        return switch (form) {
            .static_trusted => true,
            .data_package => switch (self) {
                .skill_bundle, .agent_bundle, .ontology_evidence, .eval_pack => true,
                else => false,
            },
            .out_of_process => switch (self) {
                .host_tool, .provider, .advisory_hook, .ui_backend, .ontology_evidence, .eval_pack => true,
                .skill_bundle, .agent_bundle, .service, .builtin_tool_bundle, .provider_dialect => false,
            },
        };
    }
};

pub const CapabilitySet = struct {
    bits: u16 = 0,

    pub fn insert(self: *CapabilitySet, capability: Capability) ContractError!void {
        const bit = @as(u16, 1) << @intCast(@intFromEnum(capability));
        if ((self.bits & bit) != 0) return error.DuplicateCapability;
        self.bits |= bit;
    }

    pub fn contains(self: CapabilitySet, capability: Capability) bool {
        const bit = @as(u16, 1) << @intCast(@intFromEnum(capability));
        return (self.bits & bit) != 0;
    }

    pub fn validateFor(self: CapabilitySet, form: Form) ContractError!void {
        if (self.bits == 0) return error.EmptyCapabilities;
        inline for (std.meta.fields(Capability)) |field| {
            const capability: Capability = @enumFromInt(field.value);
            if (self.contains(capability) and !capability.allowedIn(form))
                return error.UnsupportedCapabilityForForm;
        }
    }

    pub fn isSubsetOf(self: CapabilitySet, supported: CapabilitySet) bool {
        return (self.bits & ~supported.bits) == 0;
    }

    pub fn from(comptime values: []const Capability) CapabilitySet {
        var result: CapabilitySet = .{};
        inline for (values) |capability| {
            result.bits |= @as(u16, 1) << @intCast(@intFromEnum(capability));
        }
        return result;
    }
};

pub const Dependency = struct {
    id: PluginId,
    minimum: Version,
};

/// Validated descriptor shared by programmatic and filesystem plugin forms.
/// Layer priority is Host-owned and deliberately absent: a package cannot
/// elevate itself above managed/project/session policy in its own manifest.
pub const Descriptor = struct {
    id: PluginId,
    version: Version,
    form: Form,
    capabilities: CapabilitySet,
    dependencies: []const Dependency = &.{},

    pub fn validate(self: Descriptor) ContractError!void {
        try self.capabilities.validateFor(self.form);
        for (self.dependencies, 0..) |dependency, index| {
            if (self.id.eql(dependency.id)) return error.SelfDependency;
            for (self.dependencies[0..index]) |previous| {
                if (previous.id.eql(dependency.id)) return error.DuplicateDependency;
            }
        }
    }
};

/// Snapshot generations are monotonic Runtime identities. Active Sessions
/// retain the generation admitted at creation; reload publishes a new one.
pub const GenerationId = enum(u64) { _ };

pub const LifecycleState = enum {
    staged,
    active,
    draining,
    stopped,
    failed,
};

/// Collision-free ASCII encoding of a PluginId for provider tool namespaces.
/// `.` -> `_d`, `-` -> `_h`; `_` is forbidden in PluginId, so the mapping is
/// reversible. Returned storage belongs to `allocator`.
pub fn toolNamespace(allocator: std.mem.Allocator, id: PluginId) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (id.bytes) |c| switch (c) {
        '.' => try out.appendSlice(allocator, "_d"),
        '-' => try out.appendSlice(allocator, "_h"),
        else => try out.append(allocator, c),
    };
    return out.toOwnedSlice(allocator);
}

pub fn toolName(allocator: std.mem.Allocator, id: PluginId, local: []const u8) (ContractError || std.mem.Allocator.Error)![]u8 {
    if (!validLocalName(local)) return error.InvalidLocalName;
    const namespace = try toolNamespace(allocator, id);
    defer allocator.free(namespace);
    const required = namespace.len + 2 + local.len;
    if (required > MAX_TOOL_NAME_BYTES) return error.ToolNameTooLong;
    return std.fmt.allocPrint(allocator, "{s}__{s}", .{ namespace, local });
}

/// Human/model-facing plugin contribution identity (Skill and Agent):
/// `<collision-free-namespace>:<local>`. The namespace is generated by
/// `toolNamespace`; validating it again keeps this public helper safe when
/// called by another Host adapter.
pub fn qualifiedName(
    allocator: std.mem.Allocator,
    namespace: []const u8,
    local: []const u8,
) (ContractError || std.mem.Allocator.Error)![]u8 {
    if (namespace.len == 0 or namespace.len > MAX_QUALIFIED_NAME_BYTES) return error.InvalidNamespace;
    for (namespace) |c| {
        if (!isLowerAlnum(c) and c != '_') return error.InvalidNamespace;
    }
    if (!validLocalName(local)) return error.InvalidLocalName;
    const required = namespace.len + 1 + local.len;
    if (required > MAX_QUALIFIED_NAME_BYTES) return error.QualifiedNameTooLong;
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ namespace, local });
}

fn isLowerAlnum(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
}

fn parseCoreNumber(raw: []const u8) ContractError!u32 {
    if (raw.len == 0 or (raw.len > 1 and raw[0] == '0')) return error.InvalidVersion;
    for (raw) |c| if (c < '0' or c > '9') return error.InvalidVersion;
    return std.fmt.parseInt(u32, raw, 10) catch return error.InvalidVersion;
}

fn validIdentifiers(raw: []const u8, reject_numeric_leading_zero: bool) bool {
    if (raw.len == 0) return false;
    var it = std.mem.splitScalar(u8, raw, '.');
    while (it.next()) |part| {
        if (part.len == 0) return false;
        var numeric = true;
        for (part) |c| {
            if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-'))
                return false;
            if (c < '0' or c > '9') numeric = false;
        }
        if (reject_numeric_leading_zero and numeric and part.len > 1 and part[0] == '0') return false;
    }
    return true;
}

fn comparePrerelease(a: []const u8, b: []const u8) std.math.Order {
    if (a.len == 0 and b.len == 0) return .eq;
    if (a.len == 0) return .gt;
    if (b.len == 0) return .lt;
    var a_it = std.mem.splitScalar(u8, a, '.');
    var b_it = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const a_part = a_it.next();
        const b_part = b_it.next();
        if (a_part == null and b_part == null) return .eq;
        if (a_part == null) return .lt;
        if (b_part == null) return .gt;
        const a_numeric = allDigits(a_part.?);
        const b_numeric = allDigits(b_part.?);
        if (a_numeric and b_numeric) {
            if (a_part.?.len != b_part.?.len) return std.math.order(a_part.?.len, b_part.?.len);
            const numeric_order = lexicalOrder(a_part.?, b_part.?);
            if (numeric_order != .eq) return numeric_order;
        } else if (a_numeric != b_numeric) {
            return if (a_numeric) .lt else .gt;
        } else {
            const order_value = lexicalOrder(a_part.?, b_part.?);
            if (order_value != .eq) return order_value;
        }
    }
}

fn allDigits(raw: []const u8) bool {
    for (raw) |c| if (c < '0' or c > '9') return false;
    return raw.len != 0;
}

fn lexicalOrder(a: []const u8, b: []const u8) std.math.Order {
    const result = std.mem.order(u8, a, b);
    return switch (result) {
        .lt => .lt,
        .eq => .eq,
        .gt => .gt,
    };
}

fn validLocalName(raw: []const u8) bool {
    if (raw.len == 0 or raw.len > MAX_LOCAL_NAME_BYTES) return false;
    if (!((raw[0] >= 'A' and raw[0] <= 'Z') or (raw[0] >= 'a' and raw[0] <= 'z'))) return false;
    for (raw[1..]) |c| {
        if (!((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-'))
            return false;
    }
    return true;
}

test "PluginId rejects traversal, ambiguous and non-canonical identities" {
    try std.testing.expectEqualStrings("deepseek.harness", (try PluginId.parse("deepseek.harness")).bytes);
    inline for (.{ "../evil", "DeepSeek.harness", "deepseek_harness", ".deepseek", "deepseek.", "deepseek..harness", "deepseek.-harness", "de" }) |raw| {
        try std.testing.expectError(error.InvalidPluginId, PluginId.parse(raw));
    }
}

test "Version implements conservative SemVer compatibility lines" {
    const stable = try Version.parse("1.4.2+build.7");
    const minimum = try Version.parse("1.3.0");
    try std.testing.expect(stable.satisfies(minimum));
    try std.testing.expect(!(try Version.parse("2.0.0")).satisfies(minimum));
    try std.testing.expect((try Version.parse("0.2.9")).satisfies(try Version.parse("0.2.1")));
    try std.testing.expect(!(try Version.parse("0.3.0")).satisfies(try Version.parse("0.2.1")));
    try std.testing.expectEqual(std.math.Order.lt, Version.order(try Version.parse("1.0.0-rc.2"), try Version.parse("1.0.0")));
    inline for (.{ "1", "1.2", "01.2.3", "1.2.3-01", "1.2.3+", "1.2.3..4" }) |raw| {
        try std.testing.expectError(error.InvalidVersion, Version.parse(raw));
    }
}

test "data packages cannot claim executable or kernel capabilities" {
    var caps: CapabilitySet = .{};
    try caps.insert(.skill_bundle);
    try caps.insert(.agent_bundle);
    try caps.validateFor(.data_package);
    try std.testing.expect(Capability.parse("agent_loop") == null);
    try std.testing.expect(Capability.parse("permission_guard") == null);
    try std.testing.expect(Capability.parse("tinykg_writer") == null);
    try std.testing.expectEqual(Capability.service, Capability.parse("service").?);
    try std.testing.expectEqual(Capability.builtin_tool_bundle, Capability.parse("builtin_tool_bundle").?);
    try std.testing.expectEqual(Capability.provider_dialect, Capability.parse("provider_dialect").?);

    var executable: CapabilitySet = .{};
    try executable.insert(.host_tool);
    try std.testing.expectError(error.UnsupportedCapabilityForForm, executable.validateFor(.data_package));
    try std.testing.expectError(error.DuplicateCapability, executable.insert(.host_tool));
    var service: CapabilitySet = .{};
    try service.insert(.service);
    try std.testing.expectError(error.UnsupportedCapabilityForForm, service.validateFor(.data_package));
    var builtin_bundle: CapabilitySet = .{};
    try builtin_bundle.insert(.builtin_tool_bundle);
    try builtin_bundle.validateFor(.static_trusted);
    try std.testing.expectError(error.UnsupportedCapabilityForForm, builtin_bundle.validateFor(.data_package));
}

test "Descriptor rejects self and duplicate dependencies" {
    const id = try PluginId.parse("acme.review");
    var caps: CapabilitySet = .{};
    try caps.insert(.skill_bundle);
    const version = try Version.parse("1.0.0");
    const self_dependencies = [_]Dependency{.{ .id = id, .minimum = version }};
    try std.testing.expectError(error.SelfDependency, (Descriptor{
        .id = id,
        .version = version,
        .form = .data_package,
        .capabilities = caps,
        .dependencies = &self_dependencies,
    }).validate());

    const dependency = try PluginId.parse("acme.base");
    const duplicate_dependencies = [_]Dependency{
        .{ .id = dependency, .minimum = version },
        .{ .id = dependency, .minimum = version },
    };
    try std.testing.expectError(error.DuplicateDependency, (Descriptor{
        .id = id,
        .version = version,
        .form = .data_package,
        .capabilities = caps,
        .dependencies = &duplicate_dependencies,
    }).validate());
}

test "provider tool namespace is reversible and collision-free for legal ids" {
    const first = try toolName(std.testing.allocator, try PluginId.parse("acme.review-tools"), "lint");
    defer std.testing.allocator.free(first);
    const second = try toolName(std.testing.allocator, try PluginId.parse("acme-review.tools"), "lint");
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("acme_dreview_htools__lint", first);
    try std.testing.expectEqualStrings("acme_hreview_dtools__lint", second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expectError(error.InvalidLocalName, toolName(std.testing.allocator, try PluginId.parse("acme.review"), "../lint"));
}
