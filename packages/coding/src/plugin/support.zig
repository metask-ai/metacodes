//! Compile-time inventory of the plugin contract's implemented surfaces.
//!
//! A capability can exist in the frozen contract without being accepted by a
//! particular Host profile. Keeping that distinction typed prevents a future
//! caller from mistaking an existing Provider/UI/policy seam for an activated
//! plugin contribution.

const std = @import("std");
const contract = @import("contract.zig");

pub const HostProfile = enum {
    /// Standalone CLI data packages admitted by `--plugin-dir`.
    cli_data,
    /// UI-neutral embedding Runtime (`AgentRuntime`) static contributions.
    agent_core_static,
};

pub const Disposition = enum {
    /// Descriptor claim is accepted and has an end-to-end Runtime projection.
    active_runtime,
    /// The same flexibility already exists as an explicit Host-plane seam, but
    /// it is intentionally not activated by plugin descriptors in contract v1.
    host_plane_seam,
    /// Native governed subsystem exists; arbitrary plugin authority is not a
    /// target. Future support may submit inert inputs to that subsystem only.
    governed_native_only,
    /// Frozen for a later protocol revision and currently rejected.
    planned_fail_closed,
};

pub fn disposition(profile: HostProfile, form: contract.Form, capability: contract.Capability) Disposition {
    return switch (profile) {
        .cli_data => switch (form) {
            .data_package => switch (capability) {
                .skill_bundle, .agent_bundle => .active_runtime,
                .ontology_evidence, .eval_pack => .governed_native_only,
                .host_tool, .provider, .advisory_hook, .ui_backend, .service, .builtin_tool_bundle, .provider_dialect => .planned_fail_closed,
            },
            .out_of_process => if (capability == .host_tool)
                .active_runtime
            else
                .planned_fail_closed,
            .static_trusted => .planned_fail_closed,
        },
        .agent_core_static => switch (form) {
            .static_trusted => switch (capability) {
                .host_tool, .advisory_hook, .service, .builtin_tool_bundle, .provider_dialect => .active_runtime,
                .provider, .ui_backend => .host_plane_seam,
                .skill_bundle, .agent_bundle => .planned_fail_closed,
                .ontology_evidence, .eval_pack => .governed_native_only,
            },
            .out_of_process => if (capability == .host_tool)
                .active_runtime
            else
                .planned_fail_closed,
            .data_package => .planned_fail_closed,
        },
    };
}

pub fn acceptedCapabilities(profile: HostProfile) contract.CapabilitySet {
    return switch (profile) {
        .cli_data => contract.CapabilitySet.from(&.{ .skill_bundle, .agent_bundle, .host_tool }),
        .agent_core_static => contract.CapabilitySet.from(&.{ .host_tool, .advisory_hook, .service, .builtin_tool_bundle, .provider_dialect }),
    };
}

test "every contract capability has an explicit disposition in every Host profile" {
    inline for (std.meta.fields(HostProfile)) |profile_field| {
        const profile: HostProfile = @enumFromInt(profile_field.value);
        inline for (std.meta.fields(contract.Form)) |form_field| {
            const form: contract.Form = @enumFromInt(form_field.value);
            inline for (std.meta.fields(contract.Capability)) |capability_field| {
                const capability: contract.Capability = @enumFromInt(capability_field.value);
                _ = disposition(profile, form, capability);
            }
        }
    }
    try std.testing.expect(acceptedCapabilities(.cli_data).contains(.skill_bundle));
    try std.testing.expect(acceptedCapabilities(.cli_data).contains(.host_tool));
    try std.testing.expect(!acceptedCapabilities(.cli_data).contains(.ontology_evidence));
    try std.testing.expect(acceptedCapabilities(.agent_core_static).contains(.host_tool));
    try std.testing.expect(acceptedCapabilities(.agent_core_static).contains(.service));
    try std.testing.expect(acceptedCapabilities(.agent_core_static).contains(.advisory_hook));
    try std.testing.expect(acceptedCapabilities(.agent_core_static).contains(.builtin_tool_bundle));
    try std.testing.expect(acceptedCapabilities(.agent_core_static).contains(.provider_dialect));
    try std.testing.expectEqual(
        Disposition.host_plane_seam,
        disposition(.agent_core_static, .static_trusted, .provider),
    );
    try std.testing.expectEqual(
        Disposition.active_runtime,
        disposition(.agent_core_static, .out_of_process, .host_tool),
    );
}
