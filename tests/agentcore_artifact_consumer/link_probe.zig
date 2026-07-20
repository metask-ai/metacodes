const sdk = @import("metask_agentcore");

pub fn main() !void {
    _ = try sdk.Api.discover();
}
