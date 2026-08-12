const root = @import("cli/root.zig");

pub const Command = root.Command;
pub const parseCommand = root.parseCommand;
pub const setRuntimeEnvMap = root.setRuntimeEnvMap;
pub const run = root.run;

test {
    _ = root.run;
}
