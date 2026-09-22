//! Strict one-shot process-plugin transport.
//!
//! The executable is a bounded contribution adapter, never an AgentLoop. Each
//! handshake/call gets a fresh process group and one Content-Length frame in
//! each direction. Native catalog admission and permission remain upstream.

const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const child_process = @import("platform").process;
const contract = @import("contract.zig");
const tool_catalog = @import("../core/tool_catalog.zig");
const json = @import("../json.zig");
const tools = @import("../tools.zig");
const artifact_store = @import("../core/tool_result_artifact.zig");
const tool_result = @import("../core/tool_result.zig");
const util_json = @import("../util/json.zig");

pub const PROTOCOL_SCHEMA = "metacodes.plugin-process/v1";
pub const PROTOCOL_MAJOR: u32 = 1;
pub const MAX_PROCESS_CONFIG_BYTES: usize = 64 * 1024;
pub const MAX_REQUEST_FRAME_BYTES: usize = 2048;
pub const MAX_HANDSHAKE_RESPONSE_BYTES: usize = 256 * 1024;
pub const MAX_CALL_RESPONSE_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_EXECUTABLE_BYTES: u64 = 256 * 1024 * 1024;
pub const MAX_TOOLS: usize = 64;
pub const MAX_DESCRIPTION_BYTES: usize = 4096;
pub const MAX_SCHEMA_DEPTH: u32 = 8;
pub const MAX_SCHEMA_NODES: usize = 512;
pub const MAX_SCHEMA_PROPERTIES: usize = 64;

pub const Error = std.mem.Allocator.Error || error{
    ProcessPluginsUnsupported,
    ProcessConfigMissing,
    ProcessConfigUntrusted,
    ProcessConfigTooLarge,
    InvalidProcessConfig,
    UnsupportedProtocol,
    UnsupportedProcessCapability,
    InvalidEntrypoint,
    EntrypointOutsidePackage,
    EntrypointSymlink,
    EntrypointNotExecutable,
    EntrypointTooLarge,
    EntrypointHashMismatch,
    HandshakeSpawnFailed,
    HandshakeTimeout,
    HandshakeOutputTooLarge,
    HandshakeFailed,
    InvalidFrame,
    InvalidHandshake,
    InvalidToolDefinition,
    DuplicateToolName,
    WriteFailed,
};

const RawProcessConfig = struct {
    schema_version: u32,
    protocol_major: u32,
    entrypoint: []const u8,
    sha256: []const u8,
    handshake_timeout_ms: u64 = 2000,
    call_timeout_ms: u64 = 30_000,
    max_response_bytes: usize = 1024 * 1024,
};

const PackageContext = struct {
    root: []const u8,
    entrypoint: [:0]const u8,
    expected_sha256: [32]u8,
    plugin_id: []const u8,
    plugin_version: []const u8,
    handshake_timeout_ms: u64,
    call_timeout_ms: u64,
    max_response_bytes: usize,
    supports_artifact_spool: bool = false,
};

const ProcessToolContext = struct {
    package: *const PackageContext,
    local_name: []const u8,
};

pub const Staged = struct {
    tools: []tool_catalog.IsolatedTool,
};

const RawHandshake = struct {
    schema: []const u8,
    operation: []const u8,
    protocol_major: u32,
    plugin_id: []const u8,
    plugin_version: []const u8,
    capabilities: []const []const u8,
    limits: RawLimits,
    cancellation: []const u8,
    tools: []const RawTool,
};

const RawLimits = struct {
    max_request_frame_bytes: usize,
    max_response_bytes: usize,
};

const RawTool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: std.json.Value,
};

const RawCallResponse = struct {
    schema: []const u8,
    operation: []const u8,
    protocol_major: u32,
    plugin_id: []const u8,
    plugin_version: []const u8,
    tool: []const u8,
    status: []const u8,
    content: ?[]const u8 = null,
    media_type: ?[]const u8 = null,
};

pub fn stage(
    arena: *std.heap.ArenaAllocator,
    root: []const u8,
    descriptor: contract.Descriptor,
) Error!Staged {
    // Empty custom environment is not implemented by the Windows capture
    // backend. Do not silently inherit credentials into executable plugins.
    if (builtin.os.tag == .windows) return error.ProcessPluginsUnsupported;
    const host_tool_only = contract.CapabilitySet.from(&.{.host_tool});
    if (descriptor.form != .out_of_process or
        descriptor.capabilities.bits != host_tool_only.bits)
        return error.UnsupportedProcessCapability;

    const allocator = arena.allocator();
    const config_bytes = try readProcessConfig(allocator, root);
    const raw = std.json.parseFromSliceLeaky(RawProcessConfig, allocator, config_bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| return if (err == error.OutOfMemory)
        error.OutOfMemory
    else
        error.InvalidProcessConfig;
    if (raw.schema_version != contract.SCHEMA_VERSION or
        raw.protocol_major != PROTOCOL_MAJOR)
        return error.UnsupportedProtocol;
    if (raw.handshake_timeout_ms < 100 or raw.handshake_timeout_ms > 10_000 or
        raw.call_timeout_ms < 100 or raw.call_timeout_ms > 300_000 or
        raw.max_response_bytes < 1024 or raw.max_response_bytes > MAX_CALL_RESPONSE_BYTES)
        return error.InvalidProcessConfig;
    const expected_hash = parseSha256(raw.sha256) orelse return error.InvalidProcessConfig;
    const entrypoint = try resolveEntrypoint(allocator, root, raw.entrypoint);
    try verifyEntrypoint(entrypoint, expected_hash);
    const package = try allocator.create(PackageContext);
    package.* = .{
        .root = try allocator.dupe(u8, root),
        .entrypoint = entrypoint,
        .expected_sha256 = expected_hash,
        .plugin_id = try allocator.dupe(u8, descriptor.id.bytes),
        .plugin_version = try formatVersion(allocator, descriptor.version),
        .handshake_timeout_ms = raw.handshake_timeout_ms,
        .call_timeout_ms = raw.call_timeout_ms,
        .max_response_bytes = raw.max_response_bytes,
    };

    const request_body = try buildHandshakeRequest(allocator, package);
    const request_frame = try frame(allocator, request_body);
    if (request_frame.len > MAX_REQUEST_FRAME_BYTES) return error.InvalidProcessConfig;
    const argv = [_]?[*:0]const u8{ package.entrypoint.ptr, "handshake", null };
    const captured = child_process.capture(&argv, allocator, .{
        .timeout_ms = package.handshake_timeout_ms,
        .max_bytes = MAX_HANDSHAKE_RESPONSE_BYTES + 128,
        .want_stderr = true,
        .stdin_data = request_frame,
        .inherit_env = false,
        .cwd = package.root,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Timeout => error.HandshakeTimeout,
        else => error.HandshakeSpawnFailed,
    };
    if (!captured.capture_complete) return error.HandshakeOutputTooLarge;
    if (captured.exit_code != 0) return error.HandshakeFailed;
    try verifyEntrypoint(package.entrypoint, package.expected_sha256);
    const body = parseFrame(captured.stdout, MAX_HANDSHAKE_RESPONSE_BYTES) catch
        return error.InvalidFrame;
    const response = std.json.parseFromSliceLeaky(RawHandshake, allocator, body, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| return if (err == error.OutOfMemory)
        error.OutOfMemory
    else
        error.InvalidHandshake;
    package.supports_artifact_spool = try validateHandshake(response, package);

    const staged_tools = try allocator.alloc(tool_catalog.IsolatedTool, response.tools.len);
    for (response.tools, 0..) |raw_tool, index| {
        for (response.tools[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, raw_tool.name)) return error.DuplicateToolName;
        }
        const global_name = contract.toolName(allocator, descriptor.id, raw_tool.name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidToolDefinition,
        };
        if (raw_tool.description.len == 0 or raw_tool.description.len > MAX_DESCRIPTION_BYTES)
            return error.InvalidToolDefinition;
        const input_schema = try projectInputSchema(allocator, raw_tool.input_schema);
        const tool_ctx = try allocator.create(ProcessToolContext);
        tool_ctx.* = .{ .package = package, .local_name = try allocator.dupe(u8, raw_tool.name) };
        staged_tools[index] = .{
            .definition = .{
                .name = global_name,
                .description = try allocator.dupe(u8, raw_tool.description),
                .input_schema = input_schema,
            },
            .ctx = @ptrCast(tool_ctx),
            .execute = executeTool,
            .authority_binding = try deriveAuthorityBinding(
                allocator,
                package,
                global_name,
                raw_tool.input_schema,
            ),
        };
    }
    return .{ .tools = staged_tools };
}

fn deriveAuthorityBinding(
    allocator: std.mem.Allocator,
    package: *const PackageContext,
    global_name: []const u8,
    input_schema: std.json.Value,
) std.mem.Allocator.Error![32]u8 {
    const schema_json = try std.json.Stringify.valueAlloc(allocator, input_schema, .{});
    defer allocator.free(schema_json);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("metacodes-process-tool-authority-v1\x00");
    hashBindingBytes(&hasher, package.plugin_id);
    hashBindingBytes(&hasher, package.plugin_version);
    hasher.update(&package.expected_sha256);
    hashBindingBytes(&hasher, global_name);
    hashBindingBytes(&hasher, schema_json);
    var binding: [32]u8 = undefined;
    hasher.final(&binding);
    if (std.mem.allEqual(u8, &binding, 0)) binding[0] = 1;
    return binding;
}

fn hashBindingBytes(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, bytes.len, .big);
    hasher.update(&length);
    hasher.update(bytes);
}

fn executeTool(
    raw_ctx: *anyopaque,
    tool_ctx: *const tools.ToolContext,
    args: []const u8,
) anyerror!tools.ToolDispatchOutcome {
    const self: *const ProcessToolContext = @ptrCast(@alignCast(raw_ctx));
    const package = self.package;
    if (verifyEntrypoint(package.entrypoint, package.expected_sha256)) |_| {} else |_| {
        return failed(tool_ctx.allocator, "plugin_entrypoint_hash_mismatch");
    }
    if (args.len == 0) return failed(tool_ctx.allocator, "plugin_arguments_invalid");
    var parse_arena = std.heap.ArenaAllocator.init(tool_ctx.allocator);
    defer parse_arena.deinit();
    const arguments = std.json.parseFromSliceLeaky(std.json.Value, parse_arena.allocator(), args, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| return if (err == error.OutOfMemory)
        error.OutOfMemory
    else
        failed(tool_ctx.allocator, "plugin_arguments_invalid");
    if (arguments != .object) return failed(tool_ctx.allocator, "plugin_arguments_invalid");

    var external_spool: ?artifact_store.ExternalSpool = if (package.supports_artifact_spool and tool_ctx.artifact_root.len != 0) artifact_store.ExternalSpool.begin(
        tool_ctx.allocator,
        tool_ctx.artifact_root,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return failed(tool_ctx.allocator, "plugin_spool_unavailable");
    } else null;
    defer if (external_spool) |*spool| spool.deinit();
    const body = try buildCallRequest(
        tool_ctx.allocator,
        package,
        self.local_name,
        args,
        if (external_spool) |*spool| spool.path() else null,
    );
    defer tool_ctx.allocator.free(body);
    const request_frame = try frame(tool_ctx.allocator, body);
    defer tool_ctx.allocator.free(request_frame);
    if (request_frame.len > MAX_REQUEST_FRAME_BYTES)
        return failed(tool_ctx.allocator, "plugin_request_too_large");
    const argv = [_]?[*:0]const u8{ package.entrypoint.ptr, "call", null };
    const AbortBridge = struct {
        fn poll(ctx: ?*const anyopaque) bool {
            const signal: *const @import("../util/abort.zig").AbortSignal = @ptrCast(@alignCast(ctx.?));
            return signal.isAborted();
        }
    };
    const captured = child_process.capture(&argv, tool_ctx.allocator, .{
        .timeout_ms = package.call_timeout_ms,
        .max_bytes = package.max_response_bytes + 128,
        .want_stderr = true,
        .stdin_data = request_frame,
        .inherit_env = false,
        .abort_ctx = @ptrCast(tool_ctx.abort),
        .abort_poll = if (tool_ctx.abort != null) AbortBridge.poll else null,
        .cwd = package.root,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Aborted => error.Aborted,
        error.Timeout => failed(tool_ctx.allocator, "plugin_timeout"),
        else => failed(tool_ctx.allocator, "plugin_spawn_failed"),
    };
    defer tool_ctx.allocator.free(captured.stdout);
    defer tool_ctx.allocator.free(captured.stderr);
    if (verifyEntrypoint(package.entrypoint, package.expected_sha256)) |_| {} else |_| {
        return failed(tool_ctx.allocator, "plugin_entrypoint_hash_mismatch");
    }
    if (!captured.capture_complete)
        return failed(tool_ctx.allocator, "plugin_response_too_large");
    if (captured.exit_code != 0)
        return failed(tool_ctx.allocator, "plugin_nonzero_exit");
    const response_body = parseFrame(captured.stdout, package.max_response_bytes) catch
        return failed(tool_ctx.allocator, "plugin_invalid_frame");

    var response_arena = std.heap.ArenaAllocator.init(tool_ctx.allocator);
    defer response_arena.deinit();
    const response = std.json.parseFromSliceLeaky(RawCallResponse, response_arena.allocator(), response_body, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| return if (err == error.OutOfMemory)
        error.OutOfMemory
    else
        failed(tool_ctx.allocator, "plugin_invalid_response");
    if (!std.mem.eql(u8, response.schema, PROTOCOL_SCHEMA) or
        !std.mem.eql(u8, response.operation, "call_result") or
        response.protocol_major != PROTOCOL_MAJOR or
        !std.mem.eql(u8, response.plugin_id, package.plugin_id) or
        !std.mem.eql(u8, response.plugin_version, package.plugin_version) or
        !std.mem.eql(u8, response.tool, self.local_name))
        return failed(tool_ctx.allocator, "plugin_invalid_response");
    if (std.mem.eql(u8, response.status, "ok")) {
        const content = response.content orelse
            return failed(tool_ctx.allocator, "plugin_invalid_response");
        return .{ .ok = tools.ToolResultBody.initInline(try tool_ctx.allocator.dupe(u8, content)) };
    }
    if (std.mem.eql(u8, response.status, "artifact")) {
        if (response.content != null) return failed(tool_ctx.allocator, "plugin_invalid_response");
        const spool = if (external_spool) |*value| value else return failed(tool_ctx.allocator, "plugin_artifact_spool_not_offered");
        const media_type: tool_result.MediaType = if (response.media_type) |value|
            if (std.mem.eql(u8, value, "application/json"))
                .json
            else if (std.mem.eql(u8, value, "text/plain; charset=utf-8"))
                .text_utf8
            else if (std.mem.eql(u8, value, "application/octet-stream"))
                .binary
            else
                return failed(tool_ctx.allocator, "plugin_invalid_media_type")
        else
            .text_utf8;
        // Sealed, not published: the loop publishes at the batch commit
        // boundary, so a fatal sibling in the same batch leaves no blob (#65).
        const sealed = spool.seal() catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return failed(tool_ctx.allocator, "plugin_artifact_spool_invalid");
        };
        return .{ .ok = .{ .sealed = .{ .spool = sealed, .media_type = media_type, .capture_complete = true } } };
    }
    if (std.mem.eql(u8, response.status, "failed")) {
        return .{ .host_failed = if (response.content) |content|
            try tool_ctx.allocator.dupe(u8, content)
        else
            null };
    }
    if (std.mem.eql(u8, response.status, "rejected")) {
        return .{ .host_rejected = if (response.content) |content|
            try tool_ctx.allocator.dupe(u8, content)
        else
            null };
    }
    return failed(tool_ctx.allocator, "plugin_invalid_response");
}

fn failed(allocator: std.mem.Allocator, code: []const u8) std.mem.Allocator.Error!tools.ToolDispatchOutcome {
    return .{ .host_failed = try std.fmt.allocPrint(
        allocator,
        "{{\"error\":{{\"code\":\"{s}\",\"category\":\"process_plugin\",\"recoverable\":true}}}}",
        .{code},
    ) };
}

fn validateHandshake(response: RawHandshake, package: *const PackageContext) Error!bool {
    if (!std.mem.eql(u8, response.schema, PROTOCOL_SCHEMA) or
        !std.mem.eql(u8, response.operation, "handshake") or
        response.protocol_major != PROTOCOL_MAJOR or
        !std.mem.eql(u8, response.plugin_id, package.plugin_id) or
        !std.mem.eql(u8, response.plugin_version, package.plugin_version) or
        response.capabilities.len == 0 or response.capabilities.len > 2 or
        response.limits.max_request_frame_bytes != MAX_REQUEST_FRAME_BYTES or
        response.limits.max_response_bytes != package.max_response_bytes or
        !std.mem.eql(u8, response.cancellation, "terminate_process_group") or
        response.tools.len == 0 or response.tools.len > MAX_TOOLS)
        return error.InvalidHandshake;
    var host_tool = false;
    var artifact_spool = false;
    for (response.capabilities) |capability| {
        if (std.mem.eql(u8, capability, "host_tool")) {
            if (host_tool) return error.InvalidHandshake;
            host_tool = true;
        } else if (std.mem.eql(u8, capability, "artifact_spool_v1")) {
            if (artifact_spool) return error.InvalidHandshake;
            artifact_spool = true;
        } else {
            return error.InvalidHandshake;
        }
    }
    if (!host_tool) return error.InvalidHandshake;
    return artifact_spool;
}

fn projectInputSchema(allocator: std.mem.Allocator, value: std.json.Value) Error!json.InputSchema {
    var nodes: usize = 0;
    try validateSchemaValue(value, 1, &nodes);
    if (value != .object) return error.InvalidToolDefinition;
    var fields = value.object.iterator();
    while (fields.next()) |field| {
        if (!std.mem.eql(u8, field.key_ptr.*, "type") and
            !std.mem.eql(u8, field.key_ptr.*, "properties") and
            !std.mem.eql(u8, field.key_ptr.*, "required") and
            !std.mem.eql(u8, field.key_ptr.*, "additionalProperties"))
            return error.InvalidToolDefinition;
    }
    const type_value = value.object.get("type") orelse return error.InvalidToolDefinition;
    if (type_value != .string or !std.mem.eql(u8, type_value.string, "object"))
        return error.InvalidToolDefinition;
    const properties: ?std.json.ObjectMap = if (value.object.get("properties")) |raw| blk: {
        if (raw != .object or raw.object.count() > MAX_SCHEMA_PROPERTIES)
            return error.InvalidToolDefinition;
        var property_it = raw.object.iterator();
        while (property_it.next()) |property| {
            if (property.key_ptr.*.len == 0 or property.key_ptr.*.len > 128)
                return error.InvalidToolDefinition;
        }
        break :blk raw.object;
    } else null;
    var required: ?[]const []const u8 = null;
    if (value.object.get("required")) |raw| {
        if (raw != .array or raw.array.items.len > MAX_SCHEMA_PROPERTIES)
            return error.InvalidToolDefinition;
        const names = try allocator.alloc([]const u8, raw.array.items.len);
        for (raw.array.items, 0..) |item, index| {
            if (item != .string or properties == null or properties.?.get(item.string) == null)
                return error.InvalidToolDefinition;
            for (names[0..index]) |previous| {
                if (std.mem.eql(u8, previous, item.string)) return error.InvalidToolDefinition;
            }
            names[index] = item.string;
        }
        required = names;
    }
    // Boolean only, exactly as the AgentCore Host boundary admits it
    // (issue #35): `InputSchema` can carry that form losslessly, and the
    // schema-valued form still has no representation. Both boundaries reject
    // what they cannot preserve rather than accepting and dropping it.
    var additional_properties: ?bool = null;
    if (value.object.get("additionalProperties")) |raw| {
        if (raw != .bool) return error.InvalidToolDefinition;
        additional_properties = raw.bool;
    }
    return .{
        .type = "object",
        .properties = properties,
        .required = required,
        .additional_properties = additional_properties,
    };
}

fn validateSchemaValue(value: std.json.Value, depth: u32, nodes: *usize) Error!void {
    nodes.* += 1;
    if (depth > MAX_SCHEMA_DEPTH or nodes.* > MAX_SCHEMA_NODES)
        return error.InvalidToolDefinition;
    switch (value) {
        .string, .number_string => |text| if (text.len > MAX_DESCRIPTION_BYTES)
            return error.InvalidToolDefinition,
        .array => |array| {
            if (array.items.len > MAX_SCHEMA_NODES) return error.InvalidToolDefinition;
            for (array.items) |child| try validateSchemaValue(child, depth + 1, nodes);
        },
        .object => |object| {
            if (object.count() > MAX_SCHEMA_NODES) return error.InvalidToolDefinition;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (entry.key_ptr.*.len == 0 or entry.key_ptr.*.len > 128)
                    return error.InvalidToolDefinition;
                try validateSchemaValue(entry.value_ptr.*, depth + 1, nodes);
            }
        },
        else => {},
    }
}

fn buildHandshakeRequest(allocator: std.mem.Allocator, package: *const PackageContext) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"schema\":");
    try util_json.writeJsonString(&out.writer, PROTOCOL_SCHEMA);
    try out.writer.writeAll(",\"operation\":\"handshake\",\"protocol_major\":1,\"contract_major\":1,\"plugin_id\":");
    try util_json.writeJsonString(&out.writer, package.plugin_id);
    try out.writer.writeAll(",\"plugin_version\":");
    try util_json.writeJsonString(&out.writer, package.plugin_version);
    try out.writer.print(
        ",\"requested_capabilities\":[\"host_tool\",\"artifact_spool_v1\"],\"limits\":{{\"max_request_frame_bytes\":{d},\"max_response_bytes\":{d},\"max_artifact_bytes\":{d}}},\"cancellation\":\"terminate_process_group\"}}",
        .{ MAX_REQUEST_FRAME_BYTES, package.max_response_bytes, artifact_store.MAX_ARTIFACT_BYTES },
    );
    return out.toOwnedSlice();
}

fn buildCallRequest(
    allocator: std.mem.Allocator,
    package: *const PackageContext,
    local_name: []const u8,
    args: []const u8,
    spool_path: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"schema\":");
    try util_json.writeJsonString(&out.writer, PROTOCOL_SCHEMA);
    try out.writer.writeAll(",\"operation\":\"call\",\"protocol_major\":1,\"plugin_id\":");
    try util_json.writeJsonString(&out.writer, package.plugin_id);
    try out.writer.writeAll(",\"plugin_version\":");
    try util_json.writeJsonString(&out.writer, package.plugin_version);
    try out.writer.writeAll(",\"tool\":");
    try util_json.writeJsonString(&out.writer, local_name);
    try out.writer.writeAll(",\"arguments\":");
    try out.writer.writeAll(args);
    if (spool_path) |path| {
        try out.writer.writeAll(",\"result_spool\":{\"schema_version\":1,\"path\":");
        try util_json.writeJsonString(&out.writer, path);
        try out.writer.print(",\"max_bytes\":{d}}}", .{artifact_store.MAX_ARTIFACT_BYTES});
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn frame(allocator: std.mem.Allocator, body: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

pub fn parseFrame(bytes: []const u8, max_body_bytes: usize) error{InvalidFrame}![]const u8 {
    const prefix = "Content-Length: ";
    if (!std.mem.startsWith(u8, bytes, prefix)) return error.InvalidFrame;
    const header_end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return error.InvalidFrame;
    const raw_length = bytes[prefix.len..header_end];
    if (raw_length.len == 0 or raw_length.len > 20) return error.InvalidFrame;
    for (raw_length) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidFrame;
    const length = std.fmt.parseInt(usize, raw_length, 10) catch return error.InvalidFrame;
    if (length == 0 or length > max_body_bytes) return error.InvalidFrame;
    const body_start = header_end + 4;
    if (body_start > bytes.len or bytes.len - body_start != length) return error.InvalidFrame;
    return bytes[body_start..];
}

fn readProcessConfig(allocator: std.mem.Allocator, root: []const u8) Error![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/.metacodes-plugin/process.json", .{root});
    const path_z = try allocator.dupeZ(u8, path);
    if (pfs.isSymlink(path_z.ptr)) return error.ProcessConfigUntrusted;
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ProcessConfigMissing;
    defer pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.ProcessConfigUntrusted;
    if (!before.is_regular or before.size == 0 or before.size > MAX_PROCESS_CONFIG_BYTES)
        return error.ProcessConfigTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.readZ(fd, bytes[offset..]) catch return error.ProcessConfigUntrusted;
        if (count == 0) return error.ProcessConfigUntrusted;
        offset += count;
    }
    var probe: [1]u8 = undefined;
    if ((pfs.readZ(fd, &probe) catch return error.ProcessConfigUntrusted) != 0)
        return error.ProcessConfigUntrusted;
    const after = pfs.fileInfo(fd) catch return error.ProcessConfigUntrusted;
    if (after.device != before.device or after.inode != before.inode or after.size != before.size)
        return error.ProcessConfigUntrusted;
    return bytes;
}

fn resolveEntrypoint(allocator: std.mem.Allocator, root: []const u8, raw: []const u8) Error![:0]const u8 {
    if (raw.len == 0 or raw.len > 512 or std.fs.path.isAbsolute(raw) or
        std.mem.indexOfScalar(u8, raw, 0) != null)
        return error.InvalidEntrypoint;
    var components = std.mem.splitScalar(u8, raw, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..")) return error.InvalidEntrypoint;
    }
    const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, raw });
    const joined_z = try allocator.dupeZ(u8, joined);
    if (pfs.isSymlink(joined_z.ptr)) return error.EntrypointSymlink;
    var resolved_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_ptr = pfs.realpath(joined_z.ptr, &resolved_buffer) orelse return error.InvalidEntrypoint;
    const resolved = std.mem.span(resolved_ptr);
    if (!pathInside(root, resolved)) return error.EntrypointOutsidePackage;
    return allocator.dupeZ(u8, resolved);
}

fn pathInside(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len > root.len and path[root.len] == std.fs.path.sep;
}

fn verifyEntrypoint(path: [:0]const u8, expected: [32]u8) Error!void {
    if (pfs.isSymlink(path.ptr)) return error.EntrypointSymlink;
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.InvalidEntrypoint;
    defer pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.InvalidEntrypoint;
    if (!before.is_regular) return error.InvalidEntrypoint;
    if (before.size == 0 or before.size > MAX_EXECUTABLE_BYTES) return error.EntrypointTooLarge;
    if (builtin.os.tag != .windows and (before.mode & 0o111) == 0)
        return error.EntrypointNotExecutable;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [16 * 1024]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const count = pfs.readZ(fd, &buffer) catch return error.InvalidEntrypoint;
        if (count == 0) break;
        total += count;
        if (total > MAX_EXECUTABLE_BYTES) return error.EntrypointTooLarge;
        hasher.update(buffer[0..count]);
    }
    const after = pfs.fileInfo(fd) catch return error.InvalidEntrypoint;
    if (after.device != before.device or after.inode != before.inode or
        after.size != before.size or total != before.size)
        return error.InvalidEntrypoint;
    var actual: [32]u8 = undefined;
    hasher.final(&actual);
    if (!std.mem.eql(u8, &actual, &expected)) return error.EntrypointHashMismatch;
}

fn parseSha256(raw: []const u8) ?[32]u8 {
    if (raw.len != 64) return null;
    var out: [32]u8 = undefined;
    for (0..32) |index| {
        const high = hexNibble(raw[index * 2]) orelse return null;
        const low = hexNibble(raw[index * 2 + 1]) orelse return null;
        out[index] = (high << 4) | low;
    }
    return out;
}

fn hexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        else => null,
    };
}

fn formatVersion(allocator: std.mem.Allocator, version: contract.Version) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("{d}.{d}.{d}", .{ version.major, version.minor, version.patch });
    if (version.prerelease.len != 0) try out.writer.print("-{s}", .{version.prerelease});
    if (version.build.len != 0) try out.writer.print("+{s}", .{version.build});
    return out.toOwnedSlice();
}

test "a process tool's root additionalProperties is preserved, boolean only" {
    // The same representation gap issue #35 reports on the AgentCore Host
    // boundary reaches Core through this second declaration surface too: a
    // plugin declaring a closed argument object used to fail to load.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const closed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        a,
        "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}}," ++
            "\"required\":[\"text\"],\"additionalProperties\":false}",
        .{},
    );
    const projected = try projectInputSchema(a, closed);
    try std.testing.expectEqual(@as(?bool, false), projected.additional_properties);

    const silent = try std.json.parseFromSliceLeaky(
        std.json.Value,
        a,
        "{\"type\":\"object\"}",
        .{},
    );
    try std.testing.expectEqual(
        @as(?bool, null),
        (try projectInputSchema(a, silent)).additional_properties,
    );

    // Schema-valued has no internal representation; accepting it would drop
    // the constraint silently, which is the failure mode being fixed.
    const valued = try std.json.parseFromSliceLeaky(
        std.json.Value,
        a,
        "{\"type\":\"object\",\"additionalProperties\":{\"type\":\"string\"}}",
        .{},
    );
    try std.testing.expectError(error.InvalidToolDefinition, projectInputSchema(a, valued));
}

test "Content-Length frame is exact and rejects trailing or oversized bodies" {
    const encoded = try frame(std.testing.allocator, "{\"ok\":true}");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("{\"ok\":true}", try parseFrame(encoded, 64));
    try std.testing.expectError(error.InvalidFrame, parseFrame("Content-Length: 2\r\n\r\n{}x", 64));
    try std.testing.expectError(error.InvalidFrame, parseFrame("Content-Length: 99\r\n\r\n{}", 64));
    try std.testing.expectError(error.InvalidFrame, parseFrame("content-length: 2\r\n\r\n{}", 64));
}

test "sha256 parser accepts canonical lower-case only" {
    const valid = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expect(parseSha256(valid) != null);
    try std.testing.expect(parseSha256("A123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef") == null);
    try std.testing.expect(parseSha256(valid[0..63]) == null);
}
