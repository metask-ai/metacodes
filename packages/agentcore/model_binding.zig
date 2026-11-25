//! AgentCore owns the Session model binding. Skill activation may only inherit
//! that binding; an override here means the shared admission contract regressed.

const activation = @import("metacodes-core").skills_runtime.activation;

pub const Error = error{
    AgentCoreModelBindingViolation,
};

pub fn requireSessionModel(selection: activation.ModelSelection) Error!void {
    switch (selection) {
        .inherit_parent => {},
        .override => return error.AgentCoreModelBindingViolation,
    }
}

test "AgentCore model binding accepts inherit and rejects override" {
    try requireSessionModel(.inherit_parent);
    try @import("std").testing.expectError(
        error.AgentCoreModelBindingViolation,
        requireSessionModel(.{ .override = "forbidden-model" }),
    );
}
