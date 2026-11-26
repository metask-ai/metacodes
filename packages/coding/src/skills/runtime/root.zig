//! Adapter-neutral Skill Runtime semantic core.

pub const definition = @import("definition.zig");
pub const catalog = @import("catalog.zig");
pub const availability = @import("availability.zig");
pub const materialization = @import("materialization.zig");
pub const policy_frame = @import("metacodes-guard").skills.runtime.policy_frame;
pub const activation = @import("activation.zig");
pub const model_tool = @import("model_tool.zig");
