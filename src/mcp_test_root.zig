//! test:mcp isolated entry: the shared MCP client and its protocol, catalog and
//! transport modules, built and run with no CLI, no AgentCore and no AgentLoop
//! (#405). `subsystem:boundary` enforces the import closure; this proves it
//! builds and passes alone.
//!
//! The root sits one level above src/mcp/ because these files import
//! ../util/ and ../core/, and a module may not import outside its root's directory.
test {
    _ = @import("mcp/canonical.zig");
    _ = @import("mcp/json_admission.zig");
    _ = @import("mcp/wire.zig");
    _ = @import("mcp/era_modern.zig");
    _ = @import("mcp/era_classic.zig");
    _ = @import("mcp/negotiation.zig");
    _ = @import("mcp/schema.zig");
    _ = @import("mcp/result_stream.zig");
    _ = @import("mcp/protocol.zig");
    _ = @import("mcp/client.zig");
    _ = @import("mcp/host_transport.zig");
    _ = @import("mcp/runtime.zig");
    _ = @import("mcp/instance_pool.zig");
    _ = @import("mcp/catalog.zig");
    _ = @import("mcp/conformance.zig");
}
