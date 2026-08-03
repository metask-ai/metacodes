//! Revision 6 MCP schema admission and provider projection.
//!
//! Canonical MCP catalogs retain the complete wire schema in
//! `mcp_canonical.Tool`. This module deliberately exposes a narrower,
//! versioned local validation profile. A tool whose constraints cannot be
//! validated locally is excluded from the Run view with a typed issue; the
//! profile must never be described as complete JSON Schema 2020-12 support.

const std = @import("std");
const core = @import("metacodes-core");
const canonical = @import("mcp_canonical.zig");

pub const PROFILE_ID = "agentcore-json-schema-2020-12-local-v1";
pub const PROVIDER_PROJECTION_ID = "metacodes-tool-object-v1";
pub const DIALECT_2020_12 = "https://json-schema.org/draft/2020-12/schema";

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
    unsupported_dialect,
    unsupported_keyword,
    unsupported_reference,
    remote_reference_forbidden,
    http_header_projection_unavailable,
    provider_critical_projection_loss,
};

pub const Issue = struct {
    code: IssueCode,
    keyword: ?[]const u8 = null,
};

pub const ProjectionDiagnostic = enum(u8) {
    runtime_enforces_additional_properties,
    runtime_enforces_object_limits,
    runtime_enforces_dependent_required,
};

pub const Admission = union(enum) {
    available: PreparedTool,
    unavailable: Issue,
};

pub const PreparedTool = struct {
    arena: std.heap.ArenaAllocator,
    definition: core.json.ToolDefinition,
    diagnostics: []const ProjectionDiagnostic,

    pub fn deinit(self: *PreparedTool) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ValidationIssue = enum(u8) {
    invalid_json,
    resource_limit,
    schema_violation,
};

pub const Validation = union(enum) {
    valid,
    invalid: ValidationIssue,
    out_of_memory,
};

const Scan = struct {
    allocator: std.mem.Allocator,
    nodes: u32 = 0,
    work_units: u32 = 0,
    out_of_memory: bool = false,
    diagnostics: std.ArrayList(ProjectionDiagnostic) = .empty,
};

const ValidationWork = struct {
    units: u32 = 0,
    exhausted: bool = false,

    fn spend(self: *ValidationWork, amount: usize, limits: Limits) bool {
        const amount_u32 = std.math.cast(u32, amount) orelse {
            self.exhausted = true;
            return false;
        };
        if (amount_u32 > limits.max_work_units or
            self.units > limits.max_work_units - amount_u32)
        {
            self.exhausted = true;
            return false;
        }
        self.units += amount_u32;
        return true;
    }
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

/// Enforce the profile's structural budget before materializing a dynamic
/// JSON tree. The std scanner uses only O(depth) memory; the later parser is
/// therefore reached only after depth, node, container and work limits are
/// known to hold.
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

/// Build the provider-visible definition only after the complete canonical
/// schema passes the declared local profile. The returned definition borrows
/// `model_name` and canonical title/description, while all parsed schema
/// storage is owned by the returned arena.
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

    var scan = Scan{ .allocator = a };
    defer scan.diagnostics.deinit(a);
    if (inspectSchema(root, true, 1, &scan, limits)) |issue| {
        if (scan.out_of_memory) return error.OutOfMemory;
        return finishUnavailable(&arena, issue.code, issue.keyword);
    }
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
        if (inspectSchema(output, false, 1, &scan, limits)) |issue| {
            if (scan.out_of_memory) return error.OutOfMemory;
            return finishUnavailable(&arena, issue.code, issue.keyword);
        }
    }

    if (root != .object)
        return finishUnavailable(&arena, .invalid_schema, "type");
    const root_type = root.object.get("type") orelse
        return finishUnavailable(&arena, .invalid_schema, "type");
    if (root_type != .string or !std.mem.eql(u8, root_type.string, "object"))
        return finishUnavailable(&arena, .provider_critical_projection_loss, "type");

    var required: []const []const u8 = &.{};
    if (root.object.get("required")) |value| {
        if (value != .array)
            return finishUnavailable(&arena, .invalid_schema, "required");
        const names = a.alloc([]const u8, value.array.items.len) catch
            return error.OutOfMemory;
        for (value.array.items, names) |item, *name| {
            if (item != .string)
                return finishUnavailable(&arena, .invalid_schema, "required");
            name.* = item.string;
        }
        required = names;
    }
    const properties: ?std.json.ObjectMap = if (root.object.get("properties")) |value|
        if (value == .object) value.object else return finishUnavailable(&arena, .invalid_schema, "properties")
    else
        null;

    const diagnostics = scan.diagnostics.toOwnedSlice(a) catch
        return error.OutOfMemory;
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
        .diagnostics = diagnostics,
    } };
}

fn finishUnavailable(
    arena: *std.heap.ArenaAllocator,
    code: IssueCode,
    keyword: ?[]const u8,
) Admission {
    arena.deinit();
    return .{ .unavailable = .{ .code = code, .keyword = keyword } };
}

/// Validate one invocation against the same schema profile used for
/// admission. This is called before AgentCore constructs a Permission request
/// and again at dispatch, so malformed or out-of-profile arguments never
/// reach an MCP server.
pub fn validateArguments(
    allocator: std.mem.Allocator,
    schema_json: []const u8,
    arguments_json: []const u8,
    limits: Limits,
) Validation {
    return validateInstance(allocator, schema_json, arguments_json, limits);
}

pub fn validateInstance(
    allocator: std.mem.Allocator,
    schema_json: []const u8,
    instance_json: []const u8,
    limits: Limits,
) Validation {
    if (schema_json.len == 0 or schema_json.len > limits.max_schema_bytes or
        instance_json.len == 0 or instance_json.len > limits.max_instance_bytes)
        return .{ .invalid = .resource_limit };
    switch (admitJsonStructure(allocator, schema_json, limits)) {
        .valid => {},
        .invalid_json => return .{ .invalid = .invalid_json },
        .resource_limit => return .{ .invalid = .resource_limit },
        .out_of_memory => return .out_of_memory,
    }
    switch (admitJsonStructure(allocator, instance_json, limits)) {
        .valid => {},
        .invalid_json => return .{ .invalid = .invalid_json },
        .resource_limit => return .{ .invalid = .resource_limit },
        .out_of_memory => return .out_of_memory,
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const schema = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), schema_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| return if (err == error.OutOfMemory)
        .out_of_memory
    else
        .{ .invalid = .invalid_json };
    const instance = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), instance_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    }) catch |err| return if (err == error.OutOfMemory)
        .out_of_memory
    else
        .{ .invalid = .invalid_json };
    var scan = Scan{ .allocator = arena.allocator() };
    defer scan.diagnostics.deinit(arena.allocator());
    if (inspectSchema(schema, false, 1, &scan, limits)) |issue| {
        if (scan.out_of_memory) return .out_of_memory;
        return .{ .invalid = if (issue.code == .schema_resource_limit)
            .resource_limit
        else
            .schema_violation };
    }
    var work = ValidationWork{};
    if (!matches(schema, instance, 1, &work, limits))
        return .{ .invalid = if (work.exhausted)
            .resource_limit
        else
            .schema_violation };
    return .valid;
}

fn inspectSchema(
    schema: std.json.Value,
    root: bool,
    depth: u16,
    scan: *Scan,
    limits: Limits,
) ?Issue {
    if (depth > limits.max_depth or scan.nodes == limits.max_nodes)
        return .{ .code = .schema_resource_limit };
    scan.nodes += 1;
    if (schema == .bool) return null;
    if (schema != .object) return .{ .code = .invalid_schema };
    if (schema.object.count() > limits.max_container_entries or
        !spendScan(scan, schema.object.count(), limits))
        return .{ .code = .schema_resource_limit };

    if (schema.object.get("$schema")) |dialect| {
        if (dialect != .string)
            return .{ .code = .invalid_schema, .keyword = "$schema" };
        if (!std.mem.eql(u8, dialect.string, DIALECT_2020_12) and
            !std.mem.eql(u8, dialect.string, DIALECT_2020_12 ++ "#"))
            return .{ .code = .unsupported_dialect, .keyword = "$schema" };
    }
    if (schema.object.get("$ref")) |reference| {
        if (reference != .string)
            return .{ .code = .invalid_schema, .keyword = "$ref" };
        return .{ .code = if (reference.string.len != 0 and reference.string[0] == '#')
            .unsupported_reference
        else
            .remote_reference_forbidden, .keyword = "$ref" };
    }
    if (schema.object.get("$dynamicRef") != null)
        return .{ .code = .unsupported_reference, .keyword = "$dynamicRef" };
    if (schema.object.get("x-mcp-header") != null)
        return .{ .code = .http_header_projection_unavailable, .keyword = "x-mcp-header" };

    var iterator = schema.object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!knownKeyword(key) and !std.mem.startsWith(u8, key, "x-"))
            // `key` is owned by the temporary parse arena. Keep the public
            // issue self-contained instead of returning a dangling slice.
            return .{ .code = .unsupported_keyword };
    }
    if (validateTypeKeyword(schema.object.get("type"))) |issue| return issue;
    if (schema.object.get("const")) |value|
        if (!supportedLiteral(value))
            return .{ .code = .unsupported_keyword, .keyword = "const" };
    if (schema.object.get("enum")) |value| {
        if (value != .array or value.array.items.len == 0)
            return .{ .code = .invalid_schema, .keyword = "enum" };
        if (value.array.items.len > limits.max_container_entries or
            !spendScan(scan, value.array.items.len, limits))
            return .{ .code = .schema_resource_limit, .keyword = "enum" };
        for (value.array.items) |item| if (!supportedLiteral(item))
            return .{ .code = .unsupported_keyword, .keyword = "enum" };
    }

    if (schema.object.get("properties")) |properties| {
        if (properties != .object)
            return .{ .code = .invalid_schema, .keyword = "properties" };
        if (properties.object.count() > limits.max_container_entries)
            return .{ .code = .schema_resource_limit, .keyword = "properties" };
        var properties_iterator = properties.object.iterator();
        while (properties_iterator.next()) |entry| {
            if (inspectSchema(entry.value_ptr.*, false, depth + 1, scan, limits)) |issue|
                return issue;
        }
    }
    if (schema.object.get("required")) |required| {
        if (required != .array)
            return .{ .code = .invalid_schema, .keyword = "required" };
        if (required.array.items.len > limits.max_container_entries)
            return .{ .code = .schema_resource_limit, .keyword = "required" };
        for (required.array.items, 0..) |item, index| {
            if (item != .string)
                return .{ .code = .invalid_schema, .keyword = "required" };
            for (required.array.items[0..index]) |prior| {
                if (!spendScan(scan, 1, limits))
                    return .{ .code = .schema_resource_limit, .keyword = "required" };
                if (prior == .string and std.mem.eql(u8, prior.string, item.string))
                    return .{ .code = .invalid_schema, .keyword = "required" };
            }
            if (root) {
                const properties = schema.object.get("properties") orelse
                    return .{ .code = .provider_critical_projection_loss, .keyword = "required" };
                if (properties != .object or properties.object.get(item.string) == null)
                    return .{ .code = .provider_critical_projection_loss, .keyword = "required" };
            }
        }
    }
    if (schema.object.get("additionalProperties")) |value| {
        if (value != .bool and value != .object)
            return .{ .code = .invalid_schema, .keyword = "additionalProperties" };
        if (value == .object)
            if (inspectSchema(value, false, depth + 1, scan, limits)) |issue| return issue;
        if (root) appendDiagnostic(scan, .runtime_enforces_additional_properties) catch {
            scan.out_of_memory = true;
            return .{ .code = .schema_resource_limit };
        };
    }
    if (schema.object.get("items")) |value| {
        if (inspectSchema(value, false, depth + 1, scan, limits)) |issue| return issue;
    }
    if (schema.object.get("prefixItems")) |value| {
        if (value != .array)
            return .{ .code = .invalid_schema, .keyword = "prefixItems" };
        if (value.array.items.len > limits.max_container_entries)
            return .{ .code = .schema_resource_limit, .keyword = "prefixItems" };
        for (value.array.items) |child|
            if (inspectSchema(child, false, depth + 1, scan, limits)) |issue| return issue;
    }
    if (schema.object.get("dependentRequired")) |value| {
        if (value != .object)
            return .{ .code = .invalid_schema, .keyword = "dependentRequired" };
        if (value.object.count() > limits.max_container_entries)
            return .{ .code = .schema_resource_limit, .keyword = "dependentRequired" };
        var dependencies = value.object.iterator();
        while (dependencies.next()) |entry| {
            if (entry.value_ptr.* != .array)
                return .{ .code = .invalid_schema, .keyword = "dependentRequired" };
            if (entry.value_ptr.array.items.len > limits.max_container_entries or
                !spendScan(scan, entry.value_ptr.array.items.len, limits))
                return .{ .code = .schema_resource_limit, .keyword = "dependentRequired" };
            for (entry.value_ptr.array.items) |name|
                if (name != .string)
                    return .{ .code = .invalid_schema, .keyword = "dependentRequired" };
        }
        if (root) appendDiagnostic(scan, .runtime_enforces_dependent_required) catch {
            scan.out_of_memory = true;
            return .{ .code = .schema_resource_limit };
        };
    }
    if (root and (schema.object.get("minProperties") != null or
        schema.object.get("maxProperties") != null))
        appendDiagnostic(scan, .runtime_enforces_object_limits) catch {
            scan.out_of_memory = true;
            return .{ .code = .schema_resource_limit };
        };
    if (validateNumericKeywords(schema.object)) |issue| return issue;
    return null;
}

fn spendScan(scan: *Scan, amount: usize, limits: Limits) bool {
    const amount_u32 = std.math.cast(u32, amount) orelse return false;
    if (amount_u32 > limits.max_work_units or
        scan.work_units > limits.max_work_units - amount_u32)
        return false;
    scan.work_units += amount_u32;
    return true;
}

/// Revision 6 admits exact scalar literals only. Structural and numeric
/// enum/const equality needs a larger canonical-number and budget contract;
/// accepting it here would advertise validation semantics the Core lacks.
fn supportedLiteral(value: std.json.Value) bool {
    return value == .null or value == .bool or value == .string;
}

fn appendDiagnostic(scan: *Scan, value: ProjectionDiagnostic) !void {
    for (scan.diagnostics.items) |existing| if (existing == value) return;
    try scan.diagnostics.append(scan.allocator, value);
}

fn knownKeyword(key: []const u8) bool {
    const known = [_][]const u8{
        "$schema",       "$id",           "$anchor",           "$comment",         "title",            "description",
        "default",       "examples",      "deprecated",        "readOnly",         "writeOnly",        "format",
        "type",          "enum",          "const",             "properties",       "required",         "additionalProperties",
        "items",         "prefixItems",   "minItems",          "maxItems",         "uniqueItems",      "minLength",
        "maxLength",     "minimum",       "maximum",           "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
        "minProperties", "maxProperties", "dependentRequired", "$ref",             "$dynamicRef",      "x-mcp-header",
    };
    for (known) |candidate| if (std.mem.eql(u8, key, candidate)) return true;
    return false;
}

fn validateTypeKeyword(optional: ?std.json.Value) ?Issue {
    const value = optional orelse return null;
    if (value == .string)
        return if (validType(value.string)) null else .{ .code = .invalid_schema, .keyword = "type" };
    if (value != .array or value.array.items.len == 0)
        return .{ .code = .invalid_schema, .keyword = "type" };
    for (value.array.items, 0..) |item, index| {
        if (item != .string or !validType(item.string))
            return .{ .code = .invalid_schema, .keyword = "type" };
        for (value.array.items[0..index]) |prior|
            if (prior == .string and std.mem.eql(u8, prior.string, item.string))
                return .{ .code = .invalid_schema, .keyword = "type" };
    }
    return null;
}

fn validType(value: []const u8) bool {
    const names = [_][]const u8{ "null", "boolean", "object", "array", "number", "integer", "string" };
    for (names) |name| if (std.mem.eql(u8, value, name)) return true;
    return false;
}

fn validateNumericKeywords(object: std.json.ObjectMap) ?Issue {
    const non_negative_integer = [_][]const u8{
        "minItems", "maxItems", "minLength", "maxLength", "minProperties", "maxProperties",
    };
    for (non_negative_integer) |key| if (object.get(key)) |value| {
        if (value != .integer or value.integer < 0)
            return .{ .code = .invalid_schema, .keyword = key };
    };
    const numeric = [_][]const u8{
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
    };
    for (numeric) |key| if (object.get(key)) |value| {
        if (value != .integer and value != .float and value != .number_string)
            return .{ .code = .invalid_schema, .keyword = key };
        return .{ .code = .unsupported_keyword, .keyword = key };
    };
    if (object.get("uniqueItems")) |value| {
        if (value != .bool)
            return .{ .code = .invalid_schema, .keyword = "uniqueItems" };
        if (value.bool)
            return .{ .code = .unsupported_keyword, .keyword = "uniqueItems" };
    }
    return null;
}

fn matches(
    schema: std.json.Value,
    instance: std.json.Value,
    depth: u16,
    work: *ValidationWork,
    limits: Limits,
) bool {
    if (depth > limits.max_depth or !work.spend(1, limits)) {
        work.exhausted = true;
        return false;
    }
    if (schema == .bool) return schema.bool;
    if (schema != .object) return false;
    if (!matchesType(schema.object.get("type"), instance)) return false;
    if (schema.object.get("const")) |expected| if (!literalEqual(expected, instance)) return false;
    if (schema.object.get("enum")) |values| {
        var found = false;
        if (values != .array) return false;
        for (values.array.items) |expected| {
            if (!work.spend(1, limits)) return false;
            if (!literalEqual(expected, instance)) continue;
            found = true;
            break;
        }
        if (!found) return false;
    }
    switch (instance) {
        .object => |object| if (!matchesObject(schema.object, object, depth, work, limits)) return false,
        .array => |array| if (!matchesArray(schema.object, array, depth, work, limits)) return false,
        .string => |value| if (!matchesString(schema.object, value)) return false,
        else => {},
    }
    return true;
}

fn matchesObject(
    schema: std.json.ObjectMap,
    object: std.json.ObjectMap,
    depth: u16,
    work: *ValidationWork,
    limits: Limits,
) bool {
    if (schema.get("minProperties")) |value| if (object.count() < @as(usize, @intCast(value.integer))) return false;
    if (schema.get("maxProperties")) |value| if (object.count() > @as(usize, @intCast(value.integer))) return false;
    if (schema.get("required")) |required| for (required.array.items) |name| {
        if (!work.spend(1, limits)) return false;
        if (object.get(name.string) == null) return false;
    };
    const properties = schema.get("properties");
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!work.spend(1, limits)) return false;
        if (properties) |property_map| {
            if (property_map.object.get(entry.key_ptr.*)) |property_schema| {
                if (!matches(property_schema, entry.value_ptr.*, depth + 1, work, limits)) return false;
                continue;
            }
        }
        if (schema.get("additionalProperties")) |additional| {
            if (additional == .bool and !additional.bool) return false;
            if (additional == .object and !matches(additional, entry.value_ptr.*, depth + 1, work, limits)) return false;
        }
    }
    if (schema.get("dependentRequired")) |dependencies| {
        var dependency_iterator = dependencies.object.iterator();
        while (dependency_iterator.next()) |entry| {
            if (!work.spend(1, limits)) return false;
            if (object.get(entry.key_ptr.*) == null) continue;
            for (entry.value_ptr.array.items) |name| {
                if (!work.spend(1, limits)) return false;
                if (object.get(name.string) == null) return false;
            }
        }
    }
    return true;
}

fn matchesArray(
    schema: std.json.ObjectMap,
    array: std.json.Array,
    depth: u16,
    work: *ValidationWork,
    limits: Limits,
) bool {
    if (schema.get("minItems")) |value| if (array.items.len < @as(usize, @intCast(value.integer))) return false;
    if (schema.get("maxItems")) |value| if (array.items.len > @as(usize, @intCast(value.integer))) return false;
    if (schema.get("prefixItems")) |prefix| {
        const count = @min(prefix.array.items.len, array.items.len);
        for (prefix.array.items[0..count], array.items[0..count]) |item_schema, item|
            if (!matches(item_schema, item, depth + 1, work, limits)) return false;
    }
    if (schema.get("items")) |item_schema| {
        const start = if (schema.get("prefixItems")) |prefix| @min(prefix.array.items.len, array.items.len) else 0;
        for (array.items[start..]) |item|
            if (!matches(item_schema, item, depth + 1, work, limits)) return false;
    }
    return true;
}

fn matchesString(schema: std.json.ObjectMap, value: []const u8) bool {
    const count = std.unicode.utf8CountCodepoints(value) catch return false;
    if (schema.get("minLength")) |minimum| if (count < @as(usize, @intCast(minimum.integer))) return false;
    if (schema.get("maxLength")) |maximum| if (count > @as(usize, @intCast(maximum.integer))) return false;
    return true;
}

fn matchesType(optional: ?std.json.Value, instance: std.json.Value) bool {
    const value = optional orelse return true;
    if (value == .string) return matchesTypeName(value.string, instance);
    if (value != .array) return false;
    for (value.array.items) |item| if (matchesTypeName(item.string, instance)) return true;
    return false;
}

fn matchesTypeName(name: []const u8, value: std.json.Value) bool {
    if (std.mem.eql(u8, name, "null")) return value == .null;
    if (std.mem.eql(u8, name, "boolean")) return value == .bool;
    if (std.mem.eql(u8, name, "object")) return value == .object;
    if (std.mem.eql(u8, name, "array")) return value == .array;
    if (std.mem.eql(u8, name, "string")) return value == .string;
    if (std.mem.eql(u8, name, "integer")) return switch (value) {
        .integer => true,
        .number_string => |lexeme| numberLexemeIsInteger(lexeme),
        else => false,
    };
    if (std.mem.eql(u8, name, "number")) return value == .integer or value == .float or value == .number_string;
    return false;
}

/// JSON Schema's `integer` is a mathematical category, not a lexical or i64
/// category. Determine whether the decimal point lies strictly after the last
/// non-zero digit without converting the number to a bounded machine type.
fn numberLexemeIsInteger(lexeme: []const u8) bool {
    if (lexeme.len == 0) return false;
    var index: usize = if (lexeme[0] == '-') 1 else 0;
    const integer_start = index;
    var digit_index: usize = 0;
    var last_nonzero: ?usize = null;
    while (index < lexeme.len and lexeme[index] >= '0' and lexeme[index] <= '9') : (index += 1) {
        if (lexeme[index] != '0') last_nonzero = digit_index;
        digit_index += 1;
    }
    const integer_digits = index - integer_start;
    if (integer_digits == 0) return false;
    if (index < lexeme.len and lexeme[index] == '.') {
        index += 1;
        const fraction_start = index;
        while (index < lexeme.len and lexeme[index] >= '0' and lexeme[index] <= '9') : (index += 1) {
            if (lexeme[index] != '0') last_nonzero = digit_index;
            digit_index += 1;
        }
        if (index == fraction_start) return false;
    }
    if (last_nonzero == null) return true;

    var exponent_negative = false;
    var exponent: usize = 0;
    if (index < lexeme.len and (lexeme[index] == 'e' or lexeme[index] == 'E')) {
        index += 1;
        if (index < lexeme.len and (lexeme[index] == '+' or lexeme[index] == '-')) {
            exponent_negative = lexeme[index] == '-';
            index += 1;
        }
        const exponent_start = index;
        while (index < lexeme.len and lexeme[index] >= '0' and lexeme[index] <= '9') : (index += 1) {
            exponent = std.math.mul(usize, exponent, 10) catch std.math.maxInt(usize);
            exponent = std.math.add(usize, exponent, lexeme[index] - '0') catch std.math.maxInt(usize);
        }
        if (index == exponent_start) return false;
    }
    if (index != lexeme.len) return false;

    if (!exponent_negative) {
        const decimal_position = std.math.add(usize, integer_digits, exponent) catch
            std.math.maxInt(usize);
        return last_nonzero.? < decimal_position;
    }
    if (exponent >= integer_digits) return false;
    return last_nonzero.? < integer_digits - exponent;
}

fn literalEqual(left: std.json.Value, right: std.json.Value) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .null => true,
        .bool => |value| value == right.bool,
        .string => |value| std.mem.eql(u8, value, right.string),
        else => false,
    };
}

test "provider projection preserves properties and records runtime-only root constraints" {
    const tool = canonical.Tool{
        .identity = .{
            .server_binding_identity = [_]u8{1} ** 32,
            .name = "weather",
            .schema_fingerprint = [_]u8{2} ** 32,
        },
        .title = null,
        .description = "Weather",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\",\"minLength\":2}}," ++
            "\"required\":[\"city\"],\"additionalProperties\":false}",
        .output_schema_json = null,
        .annotations_json = null,
        .icons_json = null,
        .meta_json = null,
        .execution_json = null,
        .raw_json = "{}",
    };
    var admission = try prepareTool(std.testing.allocator, "mcp__weather", &tool, .{});
    defer if (admission == .available) admission.available.deinit();
    try std.testing.expect(admission == .available);
    try std.testing.expect(admission.available.definition.input_schema.properties.?.get("city") != null);
    try std.testing.expectEqual(@as(usize, 1), admission.available.diagnostics.len);
    try std.testing.expectEqual(
        ProjectionDiagnostic.runtime_enforces_additional_properties,
        admission.available.diagnostics[0],
    );
}

test "schema profile rejects unsupported dialect references and header projection" {
    const cases = [_]struct { schema: []const u8, code: IssueCode }{
        .{ .schema = "{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\"}", .code = .unsupported_dialect },
        .{ .schema = "{\"type\":\"object\",\"properties\":{\"x\":{\"$ref\":\"https://example/schema\"}}}", .code = .remote_reference_forbidden },
        .{ .schema = "{\"type\":\"object\",\"x-mcp-header\":\"authorization\"}", .code = .http_header_projection_unavailable },
    };
    for (cases) |case| {
        const tool = canonical.Tool{
            .identity = .{ .server_binding_identity = [_]u8{1} ** 32, .name = "x", .schema_fingerprint = [_]u8{2} ** 32 },
            .title = null,
            .description = null,
            .input_schema_json = case.schema,
            .output_schema_json = null,
            .annotations_json = null,
            .icons_json = null,
            .meta_json = null,
            .execution_json = null,
            .raw_json = "{}",
        };
        const admission = try prepareTool(std.testing.allocator, "mcp__x", &tool, .{});
        try std.testing.expect(admission == .unavailable);
        try std.testing.expectEqual(case.code, admission.unavailable.code);
    }
}

test "argument validation enforces nested constraints before dispatch" {
    const schema =
        "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\",\"minLength\":2}," ++
        "\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"maxItems\":2}}," ++
        "\"required\":[\"city\"],\"additionalProperties\":false}";
    try std.testing.expect(validateArguments(std.testing.allocator, schema, "{\"city\":\"Paris\",\"tags\":[\"sun\"]}", .{}) == .valid);
    try std.testing.expect(validateArguments(std.testing.allocator, schema, "{\"city\":\"P\"}", .{}) == .invalid);
    try std.testing.expect(validateArguments(std.testing.allocator, schema, "{\"city\":\"Paris\",\"secret\":true}", .{}) == .invalid);
    try std.testing.expect(validateArguments(std.testing.allocator, schema, "{\"city\":\"Paris\",\"tags\":[\"a\",\"b\",\"c\"]}", .{}) == .invalid);
}

test "format is an admitted annotation and is not asserted locally" {
    const schema =
        "{\"type\":\"object\",\"properties\":{" ++
        "\"when\":{\"type\":\"string\",\"format\":\"date-time\"}," ++
        "\"target\":{\"type\":\"string\",\"format\":\"uri\"}}}";
    try std.testing.expect(validateArguments(
        std.testing.allocator,
        schema,
        "{\"when\":\"not-asserted\",\"target\":\"relative\"}",
        .{},
    ) == .valid);
}

test "argument validation reports allocation failure distinctly" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expect(validateArguments(
        failing.allocator(),
        "{\"type\":\"object\"}",
        "{}",
        .{},
    ) == .out_of_memory);
}

test "integer validation uses mathematical JSON Schema semantics" {
    const integer_schema =
        "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"integer\"}},\"required\":[\"x\"]}";
    const accepted = [_][]const u8{
        "{\"x\":1}",
        "{\"x\":1.0}",
        "{\"x\":1e3}",
        "{\"x\":1.20e1}",
        "{\"x\":9007199254740993}",
        "{\"x\":0e-100000}",
    };
    for (accepted) |instance|
        try std.testing.expect(validateArguments(
            std.testing.allocator,
            integer_schema,
            instance,
            .{},
        ) == .valid);

    const rejected = [_][]const u8{
        "{\"x\":1.5}",
        "{\"x\":1e-1}",
        "{\"x\":120e-2}",
    };
    for (rejected) |instance|
        try std.testing.expect(validateArguments(
            std.testing.allocator,
            integer_schema,
            instance,
            .{},
        ) == .invalid);

    const number_schema =
        "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"number\"}},\"required\":[\"x\"]}";
    try std.testing.expect(validateArguments(
        std.testing.allocator,
        number_schema,
        "{\"x\":1.5}",
        .{},
    ) == .valid);
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

test "schema profile refuses semantics without exact bounded validation" {
    const cases = [_]struct { schema: []const u8, keyword: []const u8 }{
        .{ .schema = "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"array\",\"uniqueItems\":true}}}", .keyword = "uniqueItems" },
        .{ .schema = "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"number\",\"multipleOf\":0.1}}}", .keyword = "multipleOf" },
        .{ .schema = "{\"type\":\"object\",\"properties\":{\"x\":{\"enum\":[9007199254740993]}}}", .keyword = "enum" },
        .{ .schema = "{\"type\":\"object\",\"properties\":{\"x\":{\"const\":1}}}", .keyword = "const" },
    };
    for (cases) |case| {
        const tool = canonical.Tool{
            .identity = .{ .server_binding_identity = [_]u8{1} ** 32, .name = "x", .schema_fingerprint = [_]u8{2} ** 32 },
            .title = null,
            .description = null,
            .input_schema_json = case.schema,
            .output_schema_json = null,
            .annotations_json = null,
            .icons_json = null,
            .meta_json = null,
            .execution_json = null,
            .raw_json = "{}",
        };
        const admission = try prepareTool(std.testing.allocator, "mcp__x", &tool, .{});
        try std.testing.expect(admission == .unavailable);
        try std.testing.expectEqual(IssueCode.unsupported_keyword, admission.unavailable.code);
        try std.testing.expectEqualStrings(case.keyword, admission.unavailable.keyword.?);
    }
}

test "schema and invocation work are independently budgeted" {
    const tool = canonical.Tool{
        .identity = .{ .server_binding_identity = [_]u8{1} ** 32, .name = "x", .schema_fingerprint = [_]u8{2} ** 32 },
        .title = null,
        .description = null,
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"a\":{},\"b\":{}}}",
        .output_schema_json = null,
        .annotations_json = null,
        .icons_json = null,
        .meta_json = null,
        .execution_json = null,
        .raw_json = "{}",
    };
    const admission = try prepareTool(std.testing.allocator, "mcp__x", &tool, .{
        .max_container_entries = 1,
    });
    try std.testing.expect(admission == .unavailable);
    try std.testing.expectEqual(IssueCode.schema_resource_limit, admission.unavailable.code);

    const validation = validateInstance(
        std.testing.allocator,
        "{}",
        "{\"a\":1,\"b\":2,\"c\":3}",
        .{ .max_work_units = 2 },
    );
    try std.testing.expect(validation == .invalid);
    try std.testing.expectEqual(ValidationIssue.resource_limit, validation.invalid);
}
