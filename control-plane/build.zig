const std = @import("std");

pub fn build(b: *std.Build) void {
    const python = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const repo = b.path("..");

    const unit = b.addSystemCommand(&.{ python, "-m", "unittest", "scripts.tests.test_rule_control", "-v" });
    unit.setCwd(repo);
    const unit_step = b.step("test", "Test the rule-control sensors and fail-closed topology audit");
    unit_step.dependOn(&unit.step);

    const check = b.addSystemCommand(&.{ python, "scripts/rule_control.py", "check" });
    check.setCwd(repo);
    const rule_step = b.step("rule-check", "Run Lean decision, Zig feedback, re-observation, and release gate");
    rule_step.dependOn(&check.step);
}
