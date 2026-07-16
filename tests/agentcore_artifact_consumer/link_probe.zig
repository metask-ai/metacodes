const sdk = @import("metacodes_agentcore");

pub fn main() !void {
    _ = try sdk.Api.discover();
}
