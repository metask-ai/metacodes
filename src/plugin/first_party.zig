//! First-party capability packs shipped with metacodes.
//!
//! These are ordinary immutable static plugins for lifecycle, dependency and
//! inventory purposes. Their tool executors remain compiled `ToolEntry`
//! pointers: pluginization must not add a callback/process hop to the native
//! hot path. Profiles are Host policy, not package-controlled precedence.

const std = @import("std");
const contract = @import("contract.zig");
const runtime = @import("runtime.zig");

pub const Profile = enum {
    /// No optional first-party capability pack. The kernel can still create a
    /// Session with Host/process tools, but contributes no model-facing tool.
    none,
    /// Read-only workspace inspection for constrained embedding Hosts.
    minimal,
    /// Backward-compatible AgentRuntime default.
    coding,
    /// Coding profile plus the typed UI-request interaction tool.
    coding_interactive,
    /// Coding without the network-facing WebSearch/WebFetch pair.
    offline_coding,

    pub fn parse(raw: []const u8) ?Profile {
        inline for (std.meta.fields(Profile)) |field| {
            const value: Profile = @enumFromInt(field.value);
            if (std.mem.eql(u8, raw, value.canonical())) return value;
        }
        return null;
    }

    pub fn canonical(self: Profile) []const u8 {
        return switch (self) {
            .none => "none",
            .minimal => "minimal",
            .coding => "coding",
            .coding_interactive => "coding-interactive",
            .offline_coding => "offline-coding",
        };
    }
};

pub const CODING_TOOLS = [_][]const u8{
    "Read",
    "Write",
    "Edit",
    "Glob",
    "Grep",
    "Bash",
    "BashOutput",
    "KillShell",
    "WebSearch",
    "WebFetch",
};

pub const MINIMAL_TOOLS = [_][]const u8{
    "Read",
    "Glob",
    "Grep",
};

pub const OFFLINE_CODING_TOOLS = [_][]const u8{
    "Read",
    "Write",
    "Edit",
    "Glob",
    "Grep",
    "Bash",
    "BashOutput",
    "KillShell",
};

pub const INTERACTION_TOOLS = [_][]const u8{"AskUserQuestion"};
/// Mandatory recovery plane. Unlike profile tools, this capability is part of
/// the Tool Result kernel and remains available in text-only/Host-only/
/// process-plugin Runtimes. Sessions advertise it only when artifact storage
/// is enabled.
pub const ARTIFACT_TOOLS = [_][]const u8{"ReadArtifact"};

const builtin_caps = contract.CapabilitySet.from(&.{.builtin_tool_bundle});
const version = contract.Version{ .major = 1, .minor = 0, .patch = 0 };
const coding_id = contract.PluginId{ .bytes = "metacodes.core.coding" };
const minimal_id = contract.PluginId{ .bytes = "metacodes.core.minimal" };
const offline_id = contract.PluginId{ .bytes = "metacodes.core.offline-coding" };
const interaction_id = contract.PluginId{ .bytes = "metacodes.core.interaction" };
const artifact_id = contract.PluginId{ .bytes = "metacodes.kernel.tool-result-artifact" };

const artifact_plugin = runtime.StaticPlugin{
    .descriptor = .{
        .id = artifact_id,
        .version = version,
        .form = .static_trusted,
        .capabilities = builtin_caps,
    },
    .builtin_tools = &ARTIFACT_TOOLS,
};

const coding_plugin = runtime.StaticPlugin{
    .descriptor = .{
        .id = coding_id,
        .version = version,
        .form = .static_trusted,
        .capabilities = builtin_caps,
    },
    .builtin_tools = &CODING_TOOLS,
};

const minimal_plugin = runtime.StaticPlugin{
    .descriptor = .{
        .id = minimal_id,
        .version = version,
        .form = .static_trusted,
        .capabilities = builtin_caps,
    },
    .builtin_tools = &MINIMAL_TOOLS,
};

const offline_plugin = runtime.StaticPlugin{
    .descriptor = .{
        .id = offline_id,
        .version = version,
        .form = .static_trusted,
        .capabilities = builtin_caps,
    },
    .builtin_tools = &OFFLINE_CODING_TOOLS,
};

const interaction_dependencies = [_]contract.Dependency{.{
    .id = coding_id,
    .minimum = version,
}};

const interaction_plugin = runtime.StaticPlugin{
    .descriptor = .{
        .id = interaction_id,
        .version = version,
        .form = .static_trusted,
        .capabilities = builtin_caps,
        .dependencies = &interaction_dependencies,
    },
    .builtin_tools = &INTERACTION_TOOLS,
};

const coding_plugins = [_]runtime.StaticPlugin{coding_plugin};
const minimal_plugins = [_]runtime.StaticPlugin{minimal_plugin};
const offline_plugins = [_]runtime.StaticPlugin{offline_plugin};
const interactive_plugins = [_]runtime.StaticPlugin{ coding_plugin, interaction_plugin };
const kernel_plugins = [_]runtime.StaticPlugin{artifact_plugin};

pub fn kernelPlugins() []const runtime.StaticPlugin {
    return &kernel_plugins;
}

pub fn isKernelTool(name: []const u8) bool {
    for (ARTIFACT_TOOLS) |tool_name| {
        if (std.mem.eql(u8, tool_name, name)) return true;
    }
    return false;
}

pub fn plugins(profile: Profile) []const runtime.StaticPlugin {
    return switch (profile) {
        .none => &.{},
        .minimal => &minimal_plugins,
        .coding => &coding_plugins,
        .coding_interactive => &interactive_plugins,
        .offline_coding => &offline_plugins,
    };
}

test "first-party profiles are stable valid static plugins" {
    inline for (std.meta.fields(Profile)) |field| {
        const profile: Profile = @enumFromInt(field.value);
        for (plugins(profile)) |plugin| {
            try plugin.descriptor.validate();
            try std.testing.expect(plugin.descriptor.id.bytes.len != 0);
            try std.testing.expect(plugin.descriptor.capabilities.contains(.builtin_tool_bundle));
            try std.testing.expect(plugin.builtin_tools.len != 0);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), plugins(.none).len);
    try std.testing.expectEqual(@as(usize, 1), plugins(.coding).len);
    try std.testing.expectEqual(@as(usize, 2), plugins(.coding_interactive).len);
    try std.testing.expectEqualStrings("Read", CODING_TOOLS[0]);
    try std.testing.expectEqualStrings("WebFetch", CODING_TOOLS[CODING_TOOLS.len - 1]);
    try std.testing.expectEqualStrings("ReadArtifact", kernelPlugins()[0].builtin_tools[0]);
}

test "first-party plugin ids remain valid contract identities" {
    inline for (.{
        "metacodes.core.coding",
        "metacodes.core.minimal",
        "metacodes.core.offline-coding",
        "metacodes.core.interaction",
        "metacodes.kernel.tool-result-artifact",
    }) |raw| {
        _ = try contract.PluginId.parse(raw);
    }
}

test "first-party profile names are stable Host configuration values" {
    inline for (std.meta.fields(Profile)) |field| {
        const profile: Profile = @enumFromInt(field.value);
        try std.testing.expectEqual(profile, Profile.parse(profile.canonical()).?);
    }
    try std.testing.expect(Profile.parse("offline_coding") == null);
    try std.testing.expect(Profile.parse("unknown") == null);
}
