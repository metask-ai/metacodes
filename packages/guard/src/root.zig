const std = @import("std");

pub const core = struct {
    pub const answer_queue = @import("core/answer_queue.zig");
    pub const execution_effect = @import("core/execution_effect.zig");
    pub const file_change = @import("core/file_change.zig");
    pub const goal = @import("core/goal.zig");
    pub const memory = struct {
        pub const memdir = @import("core/memory/memdir.zig");
    };
    pub const output_semantics = @import("core/output_semantics.zig");
    pub const project_rule_spec = @import("core/project_rule_spec.zig");
    pub const prompt_sections = @import("core/prompt_sections.zig");
    pub const protocol = struct {
        pub const permission_choice = @import("core/protocol/permission_choice.zig");
        pub const ui_event = @import("core/protocol/ui_event.zig");
        pub const ui_request = @import("core/protocol/ui_request.zig");
    };
    pub const rule_impact_aggregate_receipt = @import("core/rule_impact_aggregate_receipt.zig");
    pub const rule_impact_evidence = @import("core/rule_impact_evidence.zig");
    pub const rule_impact_receipt = @import("core/rule_impact_receipt.zig");
    pub const rule_impact_stats = @import("core/rule_impact_stats.zig");
    pub const run_recovery = @import("core/run_recovery.zig");
    pub const shell = @import("core/shell.zig");
    pub const shutdown = @import("core/shutdown.zig");
    pub const tool_observation_journal = @import("core/tool_observation_journal.zig");
    pub const tool_result_artifact = @import("core/tool_result_artifact.zig");
    pub const workspace_policy = @import("core/workspace_policy.zig");
};
pub const formal = struct {
    pub const artifact_store = @import("formal/artifact_store.zig");
    pub const artifact_verification = @import("formal/artifact_verification.zig");
    pub const kernel_test_fixtures = @import("formal/kernel_test_fixtures.zig");
    pub const memory_migration = @import("formal/memory_migration.zig");
    pub const project_harness_runtime = @import("formal/project_harness_runtime.zig");
    pub const project_provenance = @import("formal/project_provenance.zig");
    pub const provenance = @import("formal/provenance.zig");
    pub const runtime = @import("formal/runtime.zig");
    pub const test_kernel = @import("formal/test_kernel.zig");
};
pub const mcp = struct {
    pub const naming = @import("mcp/naming.zig");
};
pub const permission = struct {
    pub const bash_parser = @import("permission/bash_parser.zig");
    pub const bash_readonly = @import("permission/bash_readonly.zig");
    pub const category = @import("permission/category.zig");
    pub const confirm_gate = @import("permission/confirm_gate.zig");
    pub const credential_store = @import("permission/credential_store.zig");
    pub const decision = @import("permission/decision.zig");
    pub const hooks = @import("permission/hooks.zig");
    pub const lent = @import("permission/lent.zig");
    pub const loader = @import("permission/loader.zig");
    pub const mode = @import("permission/mode.zig");
    pub const prompt = @import("permission/prompt.zig");
    pub const rule = @import("permission/rule.zig");
    pub const rule_matcher = @import("permission/rule_matcher.zig");
    pub const rule_spec = @import("permission/rule_spec.zig");
    pub const session_rules = @import("permission/session_rules.zig");
    pub const settings = @import("permission/settings.zig");
    pub const settings_writer = @import("permission/settings_writer.zig");
};
pub const permission_root = @import("permission.zig");
pub const sandbox = struct {
    pub const bwrap = @import("sandbox/bwrap.zig");
    pub const config = @import("sandbox/config.zig");
    pub const exec = @import("sandbox/exec.zig");
    pub const filesystem_helper = @import("sandbox/filesystem_helper.zig");
    pub const profile = @import("sandbox/profile.zig");
    pub const seccomp = @import("sandbox/seccomp.zig");
    pub const worker = @import("sandbox/worker.zig");
};
pub const skills = struct {
    pub const active = @import("skills/active.zig");
    pub const runtime = struct {
        pub const policy_frame = @import("skills/runtime/policy_frame.zig");
    };
};
pub const tools = struct {
    pub const common = @import("tools/common.zig");
    pub const observation = @import("tools/observation.zig");
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(core);
    std.testing.refAllDecls(core.memory);
    std.testing.refAllDecls(core.protocol);
    std.testing.refAllDecls(formal);
    std.testing.refAllDecls(mcp);
    std.testing.refAllDecls(permission);
    std.testing.refAllDecls(sandbox);
    std.testing.refAllDecls(skills);
    std.testing.refAllDecls(skills.runtime);
    std.testing.refAllDecls(tools);
}
