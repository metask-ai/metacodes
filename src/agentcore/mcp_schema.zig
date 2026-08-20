//! MCP schema envelope admission and provider projection.
//!
//! Canonical MCP catalogs retain the complete wire schema in
//! `mcp_canonical.Tool`. AgentCore deliberately does not implement a local
//! multi-dialect JSON Schema validator: `$schema` is retained as provenance,
//! but never decides Tool availability. This module enforces bounded JSON
//! structure, the MCP input-object envelope, and the common provider
//! `type`/`properties`/`required` projection. The MCP server remains the
//! authority for JSON Schema semantics.

const std = @import("std");
const core = @import("metacodes-core");
const canonical = @import("mcp_canonical.zig");

pub const Limits = struct {
    max_schema_bytes: usize = (canonical.Limits{}).max_schema_bytes,
    max_instance_bytes: usize = (canonical.Limits{}).max_frame_bytes,
    max_depth: u16 = (canonical.Limits{}).max_json_depth,
    max_nodes: u32 = (canonical.Limits{}).max_json_nodes,
    max_container_entries: usize = 256,
    max_work_units: u32 = 65_536,
};

pub const IssueCode = enum(u16) {
    invalid_schema,
    schema_resource_limit,
    provider_critical_projection_loss,
};

pub const Issue = struct {
    code: IssueCode,
    keyword: ?[]const u8 = null,
};

pub const Admission = union(enum) {
    available: PreparedTool,
    unavailable: Issue,
};

pub const PreparedTool = struct {
    arena: std.heap.ArenaAllocator,
    definition: core.json.ToolDefinition,

    pub fn deinit(self: *PreparedTool) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ValidationIssue = enum(u8) {
    invalid_json,
    resource_limit,
    not_object,
};

pub const Validation = union(enum) {
    valid,
    invalid: ValidationIssue,
    out_of_memory,
};

const JsonAdmission = enum {
    valid,
    invalid_json,
    resource_limit,
    out_of_memory,
};

const ContainerKind = enum { object, array };

const ContainerState = struct {
    kind: ContainerKind,
    entries: usize = 0,
    /// Object keys and values alternate. Arrays ignore this field.
    expects_key: bool = true,
};

/// Enforce structural budgets before materializing a dynamic JSON tree. The
/// scanner uses only O(depth) memory, so the later parser is reached only after
/// depth, node, container, and work limits are known to hold.
fn admitJsonStructure(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    limits: Limits,
) JsonAdmission {
    var scanner = std.json.Scanner.initCompleteInput(allocator, encoded);
    defer scanner.deinit();
    var containers = std.ArrayList(ContainerState).empty;
    defer containers.deinit(allocator);
    var nodes: u32 = 0;
    var work: u32 = 0;
    var root_values: u8 = 0;

    while (true) {
        const token = scanner.next() catch |err| return switch (err) {
            error.OutOfMemory => .out_of_memory,
            else => .invalid_json,
        };
        if (work == limits.max_work_units) return .resource_limit;
        work += 1;

        switch (token) {
            .end_of_document => return if (root_values == 1 and containers.items.len == 0)
                .valid
            else
                .invalid_json,
            .object_begin, .array_begin => {
                if (!admitValue(&containers, &root_values, &nodes, limits))
                    return .resource_limit;
                if (containers.items.len == limits.max_depth)
                    return .resource_limit;
                containers.append(allocator, .{
                    .kind = if (token == .object_begin) .object else .array,
                }) catch return .out_of_memory;
            },
            .object_end => {
                if (containers.items.len == 0) return .invalid_json;
                const current = containers.items[containers.items.len - 1];
                if (current.kind != .object or !current.expects_key)
                    return .invalid_json;
                _ = containers.pop();
            },
            .array_end => {
                if (containers.items.len == 0 or
                    containers.items[containers.items.len - 1].kind != .array)
                    return .invalid_json;
                _ = containers.pop();
            },
            .string => {
                if (containers.items.len != 0) {
                    const current = &containers.items[containers.items.len - 1];
                    if (current.kind == .object and current.expects_key) {
                        if (current.entries == limits.max_container_entries)
                            return .resource_limit;
                        current.entries += 1;
                        current.expects_key = false;
                        continue;
                    }
                }
                if (!admitValue(&containers, &root_values, &nodes, limits))
                    return .resource_limit;
            },
            .number, .true, .false, .null => {
                if (!admitValue(&containers, &root_values, &nodes, limits))
                    return .resource_limit;
            },
            .partial_number,
            .allocated_number,
            .partial_string,
            .partial_string_escaped_1,
            .partial_string_escaped_2,
            .partial_string_escaped_3,
            .partial_string_escaped_4,
            .allocated_string,
            => return .invalid_json,
        }
    }
}

fn admitValue(
    containers: *std.ArrayList(ContainerState),
    root_values: *u8,
    nodes: *u32,
    limits: Limits,
) bool {
    if (nodes.* == limits.max_nodes) return false;
    nodes.* += 1;
    if (containers.items.len == 0) {
        if (root_values.* != 0) return false;
        root_values.* = 1;
        return true;
    }
    const current = &containers.items[containers.items.len - 1];
    switch (current.kind) {
        .array => {
            if (current.entries == limits.max_container_entries) return false;
            current.entries += 1;
        },
        .object => {
            if (current.expects_key) return false;
            current.expects_key = true;
        },
    }
    return true;
}

/// Build the provider-visible Tool definition from the canonical schema.
/// `$schema` and non-projected root keywords remain in the canonical record;
/// they do not gate availability and are not sent to model providers.
pub fn prepareTool(
    backing: std.mem.Allocator,
    model_name: []const u8,
    tool: *const canonical.Tool,
    limits: Limits,
) error{OutOfMemory}!Admission {
    if (tool.input_schema_json.len == 0 or
        tool.input_schema_json.len > limits.max_schema_bytes)
        return .{ .unavailable = .{ .code = .schema_resource_limit } };
    switch (admitJsonStructure(backing, tool.input_schema_json, limits)) {
        .valid => {},
        .invalid_json => return .{ .unavailable = .{ .code = .invalid_schema } },
        .resource_limit => return .{ .unavailable = .{ .code = .schema_resource_limit } },
        .out_of_memory => return error.OutOfMemory,
    }

    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const a = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, tool.input_schema_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| return if (err == error.OutOfMemory)
        error.OutOfMemory
    else
        finishUnavailable(&arena, .invalid_schema, null);

    if (validateSchemaEnvelope(root, true)) |issue|
        return finishUnavailable(&arena, issue.code, issue.keyword);

    if (tool.output_schema_json) |encoded_output| {
        if (encoded_output.len == 0 or encoded_output.len > limits.max_schema_bytes)
            return finishUnavailable(&arena, .schema_resource_limit, null);
        switch (admitJsonStructure(backing, encoded_output, limits)) {
            .valid => {},
            .invalid_json => return finishUnavailable(&arena, .invalid_schema, null),
            .resource_limit => return finishUnavailable(&arena, .schema_resource_limit, null),
            .out_of_memory => return error.OutOfMemory,
        }
        const output = std.json.parseFromSliceLeaky(std.json.Value, a, encoded_output, .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        }) catch |err| return if (err == error.OutOfMemory)
            error.OutOfMemory
        else
            finishUnavailable(&arena, .invalid_schema, null);
        if (validateSchemaEnvelope(output, false)) |issue|
            return finishUnavailable(&arena, issue.code, issue.keyword);
    }

    var required: []const []const u8 = &.{};
    if (root.object.get("required")) |value| {
        const names = a.alloc([]const u8, value.array.items.len) catch
            return error.OutOfMemory;
        for (value.array.items, names) |item, *name| name.* = item.string;
        required = names;
    }
    const properties: ?std.json.ObjectMap = if (root.object.get("properties")) |value|
        value.object
    else
        null;

    const description = tool.description orelse tool.title orelse tool.identity.name;
    return .{ .available = .{
        .arena = arena,
        .definition = .{
            .name = model_name,
            .description = description,
            .input_schema = .{
                .type = "object",
                .properties = properties,
                .required = required,
            },
        },
    } };
}

fn validateSchemaEnvelope(value: std.json.Value, input: bool) ?Issue {
    if (value != .object) return .{ .code = .invalid_schema };
    if (value.object.get("$schema")) |dialect|
        if (dialect != .string)
            return .{ .code = .invalid_schema, .keyword = "$schema" };
    if (input) {
        const root_type = value.object.get("type") orelse
            return .{ .code = .invalid_schema, .keyword = "type" };
        if (root_type != .string or !std.mem.eql(u8, root_type.string, "object"))
            return .{ .code = .provider_critical_projection_loss, .keyword = "type" };
    }
    const properties = value.object.get("properties");
    if (properties) |projected| {
        if (projected != .object)
            return .{ .code = .invalid_schema, .keyword = "properties" };
        if (input) {
            var iterator = projected.object.iterator();
            while (iterator.next()) |entry|
                if (findProjectedReference(entry.value_ptr.*)) |keyword|
                    return .{
                        .code = .provider_critical_projection_loss,
                        .keyword = keyword,
                    };
        }
    }
    if (value.object.get("required")) |required| {
        if (required != .array)
            return .{ .code = .invalid_schema, .keyword = "required" };
        for (required.array.items, 0..) |item, index| {
            if (item != .string)
                return .{ .code = .invalid_schema, .keyword = "required" };
            if (input) {
                for (required.array.items[0..index]) |prior|
                    if (std.mem.eql(u8, prior.string, item.string))
                        return .{ .code = .invalid_schema, .keyword = "required" };
                if (properties == null or properties.?.object.get(item.string) == null)
                    return .{
                        .code = .provider_critical_projection_loss,
                        .keyword = "required",
                    };
            }
        }
    }
    return null;
}

/// References inside the projected `properties` tree cannot be forwarded
/// intact because the common Provider Tool shape does not carry the canonical
/// root `$defs`. Reject that broken projection without interpreting any JSON
/// Schema constraint or resolving references locally.
/// The context-free fail-closed walk may also reject a nested property
/// literally named `$ref`; R9 accepts that rare conservative trade-off.
fn findProjectedReference(value: std.json.Value) ?[]const u8 {
    switch (value) {
        .object => |object| {
            if (object.get("$ref") != null) return "$ref";
            if (object.get("$dynamicRef") != null) return "$dynamicRef";
            var iterator = object.iterator();
            while (iterator.next()) |entry|
                if (findProjectedReference(entry.value_ptr.*)) |keyword|
                    return keyword;
        },
        .array => |array| for (array.items) |item|
            if (findProjectedReference(item)) |keyword| return keyword,
        else => {},
    }
    return null;
}

fn finishUnavailable(
    arena: *std.heap.ArenaAllocator,
    code: IssueCode,
    keyword: ?[]const u8,
) Admission {
    arena.deinit();
    return .{ .unavailable = .{ .code = code, .keyword = keyword } };
}

/// Validate only the MCP arguments envelope. JSON Schema semantics belong to
/// the MCP server and are deliberately not interpreted here.
pub fn validateArguments(
    allocator: std.mem.Allocator,
    arguments_json: []const u8,
    limits: Limits,
) Validation {
    if (arguments_json.len == 0 or arguments_json.len > limits.max_instance_bytes)
        return .{ .invalid = .resource_limit };
    switch (admitJsonStructure(allocator, arguments_json, limits)) {
        .valid => {},
        .invalid_json => return .{ .invalid = .invalid_json },
        .resource_limit => return .{ .invalid = .resource_limit },
        .out_of_memory => return .out_of_memory,
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), arguments_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    }) catch |err| return if (err == error.OutOfMemory)
        .out_of_memory
    else
        .{ .invalid = .invalid_json };
    return if (value == .object) .valid else .{ .invalid = .not_object };
}

fn testTool(input_schema: []const u8, output_schema: ?[]const u8) canonical.Tool {
    return .{
        .identity = .{
            .server_binding_identity = [_]u8{1} ** 32,
            .name = "weather",
            .schema_fingerprint = [_]u8{2} ** 32,
        },
        .title = null,
        .description = "Weather",
        .input_schema_json = input_schema,
        .output_schema_json = output_schema,
        .annotations_json = null,
        .icons_json = null,
        .meta_json = null,
        .execution_json = null,
        .raw_json = "{}",
    };
}

test "provider projection admits the three primary MCP schema forms" {
    const schemas = [_][]const u8{
        "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}",
        "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}",
        "{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}",
    };
    for (schemas) |encoded| {
        const tool = testTool(encoded, null);
        var admission = try prepareTool(std.testing.allocator, "mcp__weather", &tool, .{});
        defer if (admission == .available) admission.available.deinit();
        try std.testing.expect(admission == .available);
        try std.testing.expect(admission.available.definition.input_schema.properties.?.get("city") != null);
        try std.testing.expectEqualStrings("city", admission.available.definition.input_schema.required.?[0]);
    }
}

test "dialect and semantic keywords do not decide Tool availability" {
    const encoded =
        "{\"$schema\":\"https://example.invalid/custom-dialect\",\"type\":\"object\"," ++
        "\"properties\":{\"x\":{\"type\":\"string\",\"pattern\":\"^[a-z]+$\"}," ++
        "\"n\":{\"type\":\"number\",\"multipleOf\":0.1}," ++
        "\"tags\":{\"type\":\"array\",\"uniqueItems\":true}}," ++
        "\"additionalProperties\":false}";
    const tool = testTool(encoded, "{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\"}");
    var admission = try prepareTool(std.testing.allocator, "mcp__weather", &tool, .{});
    defer if (admission == .available) admission.available.deinit();
    try std.testing.expect(admission == .available);
}

test "provider projection rejects dangling references and incoherent required" {
    const referenced = testTool(
        "{\"type\":\"object\",\"$defs\":{\"name\":{\"type\":\"string\"}}," ++
            "\"properties\":{\"record\":{\"type\":\"object\",\"properties\":{" ++
            "\"name\":{\"$ref\":\"#/$defs/name\"}}}}}",
        null,
    );
    var reference_admission = try prepareTool(
        std.testing.allocator,
        "mcp__weather",
        &referenced,
        .{},
    );
    defer if (reference_admission == .available) reference_admission.available.deinit();
    try std.testing.expect(reference_admission == .unavailable);
    try std.testing.expectEqual(
        IssueCode.provider_critical_projection_loss,
        reference_admission.unavailable.code,
    );
    try std.testing.expectEqualStrings("$ref", reference_admission.unavailable.keyword.?);

    const missing_property = testTool(
        "{\"type\":\"object\",\"properties\":{},\"required\":[\"city\"]}",
        null,
    );
    var missing_admission = try prepareTool(
        std.testing.allocator,
        "mcp__weather",
        &missing_property,
        .{},
    );
    defer if (missing_admission == .available) missing_admission.available.deinit();
    try std.testing.expect(missing_admission == .unavailable);
    try std.testing.expectEqual(
        IssueCode.provider_critical_projection_loss,
        missing_admission.unavailable.code,
    );
    try std.testing.expectEqualStrings("required", missing_admission.unavailable.keyword.?);

    const duplicate_required = testTool(
        "{\"type\":\"object\",\"properties\":{\"city\":{}}," ++
            "\"required\":[\"city\",\"city\"]}",
        null,
    );
    var duplicate_admission = try prepareTool(
        std.testing.allocator,
        "mcp__weather",
        &duplicate_required,
        .{},
    );
    defer if (duplicate_admission == .available) duplicate_admission.available.deinit();
    try std.testing.expect(duplicate_admission == .unavailable);
    try std.testing.expectEqual(IssueCode.invalid_schema, duplicate_admission.unavailable.code);
    try std.testing.expectEqualStrings("required", duplicate_admission.unavailable.keyword.?);
}

test "invalid schema envelope and resource excess remain unavailable" {
    const invalid_dialect = testTool("{\"$schema\":7,\"type\":\"object\"}", null);
    var invalid = try prepareTool(std.testing.allocator, "mcp__weather", &invalid_dialect, .{});
    defer if (invalid == .available) invalid.available.deinit();
    try std.testing.expect(invalid == .unavailable);
    try std.testing.expectEqual(IssueCode.invalid_schema, invalid.unavailable.code);
    try std.testing.expectEqualStrings("$schema", invalid.unavailable.keyword.?);

    const oversized = testTool("{\"type\":\"object\",\"properties\":{\"a\":{},\"b\":{}}}", null);
    var limited = try prepareTool(std.testing.allocator, "mcp__weather", &oversized, .{
        .max_container_entries = 1,
    });
    defer if (limited == .available) limited.available.deinit();
    try std.testing.expect(limited == .unavailable);
    try std.testing.expectEqual(IssueCode.schema_resource_limit, limited.unavailable.code);
}

test "argument validation enforces only bounded JSON object envelope" {
    try std.testing.expect(validateArguments(std.testing.allocator, "{\"city\":7,\"extra\":true}", .{}) == .valid);
    const malformed = validateArguments(std.testing.allocator, "{\"city\":}", .{});
    try std.testing.expect(malformed == .invalid);
    try std.testing.expectEqual(ValidationIssue.invalid_json, malformed.invalid);
    const array = validateArguments(std.testing.allocator, "[]", .{});
    try std.testing.expect(array == .invalid);
    try std.testing.expectEqual(ValidationIssue.not_object, array.invalid);
    const limited = validateArguments(std.testing.allocator, "{\"a\":1,\"b\":2}", .{
        .max_container_entries = 1,
    });
    try std.testing.expect(limited == .invalid);
    try std.testing.expectEqual(ValidationIssue.resource_limit, limited.invalid);
}

test "argument validation reports allocation failure distinctly" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expect(validateArguments(
        failing.allocator(),
        "{}",
        .{},
    ) == .out_of_memory);
}

test "JSON structure is budgeted before dynamic tree allocation" {
    try std.testing.expectEqual(
        JsonAdmission.resource_limit,
        admitJsonStructure(std.testing.allocator, "[[[0]]]", .{ .max_depth = 2 }),
    );
    try std.testing.expectEqual(
        JsonAdmission.resource_limit,
        admitJsonStructure(std.testing.allocator, "[0,1]", .{ .max_nodes = 2 }),
    );
    try std.testing.expectEqual(
        JsonAdmission.resource_limit,
        admitJsonStructure(std.testing.allocator, "{\"a\":0,\"b\":1}", .{
            .max_container_entries = 1,
        }),
    );
    try std.testing.expectEqual(
        JsonAdmission.invalid_json,
        admitJsonStructure(std.testing.allocator, "{\"a\":}", .{}),
    );
}
