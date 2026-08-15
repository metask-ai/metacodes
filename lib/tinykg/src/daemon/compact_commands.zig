const std = @import("std");
const tinykg = @import("../tinykg.zig");
const schema_document_registry_loader = @import("../schema_document_registry_loader.zig").SchemaDocumentRegistryLoader();

/// Native command surface for the daemon-resident compact repository.
///
/// This owner never opens a legacy Store. Reads use the Runtime's resident
/// graph/index/property view; every durable write is expressed as one
/// checkpoint.Operation batch and committed only through Runtime.applyMutation.
/// Commands whose legacy semantics cannot yet be preserved remain absent from
/// `execute`, so StoreActor keeps rejecting them fail-closed.
pub const Result = struct {
    output: []u8,
    mutated: bool = false,
};

pub fn supports(command: tinykg.cli.Command) bool {
    return switch (command) {
        .get,
        .get_node,
        .find,
        .add_node,
        .set_node_property,
        .set_edge_property,
        .add_edge,
        => true,
        else => false,
    };
}

pub fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: *tinykg.checkpoint.Runtime,
    command: tinykg.cli.Command,
    args: []const []const u8,
) !Result {
    return switch (command) {
        .get, .get_node => .{ .output = try renderNode(allocator, runtime, args) },
        .find => .{ .output = try renderFind(allocator, io, runtime, args) },
        .add_node => .{
            .output = try addNode(allocator, io, runtime, args),
            .mutated = true,
        },
        .set_node_property => .{
            .output = try setStringProperty(allocator, io, runtime, args, 1),
            .mutated = true,
        },
        .set_edge_property => .{
            .output = try setStringProperty(allocator, io, runtime, args, 2),
            .mutated = true,
        },
        .add_edge => .{
            .output = try addEdge(allocator, io, runtime, args),
            .mutated = true,
        },
        else => error.UnsupportedCompactCommand,
    };
}

const EffectiveSchema = struct {
    catalog: tinykg.catalog.Catalog,
    enforce_application_schema: bool,

    fn deinit(self: *EffectiveSchema) void {
        self.catalog.deinit();
        self.* = undefined;
    }
};

fn loadEffectiveSchema(allocator: std.mem.Allocator, runtime: *const tinykg.checkpoint.Runtime) !EffectiveSchema {
    const bytes = runtime.loaded.checkpoint.snapshot.catalog;
    if (bytes.len == 0) return error.MissingCanonicalSchema;
    const catalog = try tinykg.catalog.decodeCatalog(allocator, bytes);
    return .{
        .enforce_application_schema = catalog.profiles.items.len != 0 or
            catalog.registry.nodeTypeCount() != 2 or
            catalog.registry.relationTypeCount() != 2,
        .catalog = catalog,
    };
}

fn rejectClientSchema(args: []const []const u8) !void {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--schema")) return error.ClientSchemaForbidden;
    }
}

fn parseNodeId(value: []const u8) !u64 {
    return std.fmt.parseInt(u64, value, 10) catch return error.InvalidNodeId;
}

fn parseEdgeId(value: []const u8) !u64 {
    return std.fmt.parseInt(u64, value, 10) catch return error.InvalidEdgeId;
}

fn validateCanonicalSchemaPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    effective: EffectiveSchema,
    schema_path: ?[]const u8,
) !void {
    const path = schema_path orelse return;
    var candidate = try schema_document_registry_loader.loadSchemaRegistryFile(allocator, io, path);
    defer candidate.deinit();
    const candidate_view = tinykg.catalog.Catalog{
        .allocator = allocator,
        .registry = candidate,
    };
    const candidate_bytes = try tinykg.catalog.encodeCatalog(allocator, candidate_view);
    defer allocator.free(candidate_bytes);
    const embedded_view = tinykg.catalog.Catalog{
        .allocator = allocator,
        .registry = effective.catalog.registry,
    };
    const embedded_bytes = try tinykg.catalog.encodeCatalog(allocator, embedded_view);
    defer allocator.free(embedded_bytes);
    if (!std.mem.eql(u8, candidate_bytes, embedded_bytes)) return error.CanonicalSchemaMismatch;
}

fn nextNodeId(runtime: *const tinykg.checkpoint.Runtime) !u64 {
    var maximum: u64 = 0;
    for (runtime.loaded.checkpoint.snapshot.nodes) |node| maximum = @max(maximum, node.id);
    if (maximum == std.math.maxInt(u64) - 1) return error.InvalidNodeId;
    return maximum + 1;
}

fn nextEdgeId(runtime: *const tinykg.checkpoint.Runtime) !u64 {
    var maximum: u64 = 0;
    for (runtime.loaded.checkpoint.snapshot.edges) |edge| maximum = @max(maximum, edge.id);
    if (maximum == std.math.maxInt(u64) - 1) return error.InvalidEdgeId;
    return maximum + 1;
}

fn parseNodeKind(label: []const u8, effective: EffectiveSchema) !tinykg.NodeKind {
    if (effective.catalog.registry.findNodeType(label)) |id| return @enumFromInt(id);
    const kind = tinykg.core.parseNodeKind(label) orelse return error.UnknownNodeKind;
    if (effective.enforce_application_schema and
        !effective.catalog.registry.hasNodeTypeId(@intFromEnum(kind)))
    {
        return error.UnknownNodeKind;
    }
    return kind;
}

fn parseRelKind(label: []const u8, effective: EffectiveSchema) !tinykg.RelKind {
    if (effective.catalog.registry.findRelationType(label)) |id| return @enumFromInt(id);
    const rel = tinykg.core.parseRelKind(label) orelse return error.UnknownRelationKind;
    if (effective.enforce_application_schema) {
        const id = @intFromEnum(rel);
        const actual = effective.catalog.registry.relationTypeNameById(id) orelse return error.UnknownRelationKind;
        if (!std.mem.eql(u8, actual, @tagName(rel))) return error.UnknownRelationKind;
    }
    return rel;
}

fn writeEscaped(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '\t' => try writer.writeAll("\\t"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        0x00...0x08, 0x0b...0x0c, 0x0e...0x1f, 0x7f => try writer.print("\\x{x:0>2}", .{byte}),
        else => try writer.writeByte(byte),
    };
}

fn writeKind(writer: *std.Io.Writer, registry: tinykg.schema.Registry, kind: tinykg.NodeKind) !void {
    if (registry.nodeTypeNameById(@intFromEnum(kind))) |name| return writer.writeAll(name);
    inline for (@typeInfo(tinykg.NodeKind).@"enum".fields) |field| {
        if (@intFromEnum(kind) == field.value) return writer.writeAll(field.name);
    }
    try writer.print("type#{}", .{@intFromEnum(kind)});
}

const NodeArguments = struct {
    id: u64,
    json: bool = false,
    meta: bool = false,
    include_text: bool = false,
};

fn parseNodeArguments(args: []const []const u8) !NodeArguments {
    if (args.len == 0) return error.MissingArgument;
    var parsed = NodeArguments{ .id = try parseNodeId(args[0]) };
    var pos: usize = 1;
    while (pos < args.len) {
        if (std.mem.eql(u8, args[pos], "--format")) {
            if (pos + 1 >= args.len) return error.MissingArgument;
            if (std.mem.eql(u8, args[pos + 1], "json")) {
                parsed.json = true;
            } else if (!std.mem.eql(u8, args[pos + 1], "text")) {
                return error.InvalidFormat;
            }
            pos += 2;
        } else if (std.mem.eql(u8, args[pos], "--include-text")) {
            parsed.include_text = true;
            pos += 1;
        } else if (std.mem.eql(u8, args[pos], "--meta")) {
            parsed.meta = true;
            pos += 1;
        } else if (std.mem.startsWith(u8, args[pos], "--")) {
            return error.UnknownOption;
        } else {
            return error.TooManyArguments;
        }
    }
    if (parsed.include_text and !parsed.json) return error.Unsupported;
    if (parsed.meta and !parsed.json) return error.Unsupported;
    return parsed;
}

fn renderNode(
    allocator: std.mem.Allocator,
    runtime: *tinykg.checkpoint.Runtime,
    args: []const []const u8,
) ![]u8 {
    try rejectClientSchema(args);
    const parsed = try parseNodeArguments(args);
    var effective = try loadEffectiveSchema(allocator, runtime);
    defer effective.deinit();
    const node = runtime.graph.getNode(.fromInt(parsed.id));

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    if (node == null) {
        if (parsed.json) {
            try writer.print("{{\"schema_version\":\"tinykg-agent-retrieval-v1\",\"id\":{},\"found\":false}}\n", .{parsed.id});
        } else {
            try writer.writeAll("not found\n");
        }
        return output.toOwnedSlice();
    }
    const value = node.?;
    if (!parsed.json) {
        try writer.print("{}\t", .{parsed.id});
        try writeKind(writer, effective.catalog.registry, value.kind);
        try writer.writeByte('\t');
        try writeEscaped(writer, value.text);
        try writer.writeByte('\n');
        return output.toOwnedSlice();
    }

    const name = stringProperty(runtime, 1, parsed.id, "name");
    const summary = stringProperty(runtime, 1, parsed.id, "summary");
    const schema_type = stringProperty(runtime, 1, parsed.id, "schema_type");
    const source_label = stringProperty(runtime, 1, parsed.id, "source_label");
    const external_key = stringProperty(runtime, 1, parsed.id, "external_key");
    const deprecated_by = nodeDeprecatedBy(runtime, parsed.id);
    var in_degree: usize = 0;
    var out_degree: usize = 0;
    for (runtime.graph.edges.items) |edge| {
        if (edge.status != .active) continue;
        if (edge.src.toInt() == parsed.id) out_degree += 1;
        if (edge.dst.toInt() == parsed.id) in_degree += 1;
    }

    try writer.writeAll("{\"schema_version\":\"tinykg-agent-retrieval-v1\",\"found\":true,\"node\":{");
    try writer.print("\"id\":{},\"kind\":", .{parsed.id});
    if (effective.catalog.registry.nodeTypeNameById(@intFromEnum(value.kind))) |kind_name| {
        try std.json.Stringify.encodeJsonString(kind_name, .{}, writer);
    } else {
        try std.json.Stringify.encodeJsonString(@tagName(value.kind), .{}, writer);
    }
    try writer.writeAll(",\"name\":");
    try std.json.Stringify.encodeJsonString(name orelse "", .{}, writer);
    try writer.writeAll(",\"summary\":{\"text\":");
    if (summary) |text| try std.json.Stringify.encodeJsonString(text, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"source\":");
    try std.json.Stringify.encodeJsonString(if (summary == null) "none" else "node_property", .{}, writer);
    try writer.writeAll(",\"node_id\":null,\"stale\":false},\"schema\":{\"schema_type\":");
    try writeNullableJsonString(writer, schema_type);
    try writer.writeAll(",\"external_key\":");
    try writeNullableJsonString(writer, external_key);
    try writer.writeAll(",\"source_label\":");
    try writeNullableJsonString(writer, source_label);
    try writer.print("}},\"context_size\":{{\"text_bytes\":{},\"text_chars\":{},\"text_lines\":{},\"size_version\":1}}", .{
        value.text.len,
        std.unicode.utf8CountCodepoints(value.text) catch return error.InvalidRecord,
        textLineCount(value.text),
    });
    try writer.print(",\"status\":{{\"current_generation\":{},\"deprecated_by\":", .{deprecated_by == null});
    if (deprecated_by) |replacement| try writer.print("{}", .{replacement}) else try writer.writeAll("null");
    try writer.print("}},\"expand\":{{\"has_text\":{},\"has_summary\":{},\"has_children\":{},\"recommended\":", .{
        value.text.len != 0,
        summary != null and summary.?.len != 0,
        out_degree != 0,
    });
    try std.json.Stringify.encodeJsonString(if (out_degree != 0) "children_first" else "raw_text", .{}, writer);
    try writer.print("}},\"local_graph\":{{\"in_degree\":{},\"out_degree\":{}}}", .{ in_degree, out_degree });
    if (parsed.include_text) {
        try writer.writeAll(",\"text\":");
        try std.json.Stringify.encodeJsonString(value.text, .{}, writer);
    }
    try writer.writeAll("}}\n");
    return output.toOwnedSlice();
}

fn writeNullableJsonString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| return std.json.Stringify.encodeJsonString(text, .{}, writer);
    try writer.writeAll("null");
}

fn textLineCount(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count: usize = 1;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn renderFind(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: *tinykg.checkpoint.Runtime,
    args: []const []const u8,
) ![]u8 {
    var positionals: [2][]const u8 = undefined;
    var positional_count: usize = 0;
    var schema_path: ?[]const u8 = null;
    var include_history = false;
    var pos: usize = 0;
    while (pos < args.len) {
        if (std.mem.eql(u8, args[pos], "--schema")) {
            if (pos + 1 >= args.len) return error.MissingArgument;
            if (schema_path != null) return error.TooManyArguments;
            schema_path = args[pos + 1];
            pos += 2;
        } else if (std.mem.eql(u8, args[pos], "--include-history")) {
            include_history = true;
            pos += 1;
        } else if (std.mem.startsWith(u8, args[pos], "--")) {
            return error.UnknownOption;
        } else {
            if (positional_count >= positionals.len) return error.TooManyArguments;
            positionals[positional_count] = args[pos];
            positional_count += 1;
            pos += 1;
        }
    }
    if (positional_count < 2) return error.MissingArgument;
    var effective = try loadEffectiveSchema(allocator, runtime);
    defer effective.deinit();
    try validateCanonicalSchemaPath(allocator, io, effective, schema_path);
    const kind = try parseNodeKind(positionals[0], effective);
    const candidates = try runtime.graph_index.lookupByText(kind, positionals[1]);
    var match: ?tinykg.NodeId = null;
    for (candidates) |candidate| {
        if (!include_history and nodeDeprecatedBy(runtime, candidate.toInt()) != null) continue;
        match = candidate;
        break;
    }

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    if (match) |id| {
        const node = runtime.graph.getNode(id) orelse return error.InvalidRecord;
        try output.writer.print("{}\t", .{id.toInt()});
        try writeKind(&output.writer, effective.catalog.registry, node.kind);
        try output.writer.writeByte('\t');
        try writeEscaped(&output.writer, node.text);
        try output.writer.writeByte('\n');
    } else {
        try output.writer.writeAll("not found\n");
    }
    return output.toOwnedSlice();
}

const AddNodeArguments = struct {
    kind_label: []const u8,
    text: []const u8,
    schema_type: ?[]const u8 = null,
    name: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    retrieval_hints: ?[]const u8 = null,
    schema_path: ?[]const u8 = null,
};

fn parseAddNodeArguments(args: []const []const u8) !AddNodeArguments {
    if (args.len < 2) return error.MissingArgument;
    var parsed = AddNodeArguments{ .kind_label = args[0], .text = args[1] };
    var pos: usize = 2;
    while (pos < args.len) {
        const option = args[pos];
        if (pos + 1 >= args.len) return error.MissingArgument;
        if (std.mem.eql(u8, option, "--schema")) {
            parsed.schema_path = args[pos + 1];
        } else if (std.mem.eql(u8, option, "--schema-type")) {
            parsed.schema_type = args[pos + 1];
        } else if (std.mem.eql(u8, option, "--name")) {
            parsed.name = args[pos + 1];
        } else if (std.mem.eql(u8, option, "--summary")) {
            parsed.summary = args[pos + 1];
        } else if (std.mem.eql(u8, option, "--retrieval-hints") or std.mem.eql(u8, option, "--retrieval-hint")) {
            parsed.retrieval_hints = args[pos + 1];
        } else if (std.mem.startsWith(u8, option, "--")) {
            return error.UnknownOption;
        } else {
            return error.TooManyArguments;
        }
        pos += 2;
    }
    return parsed;
}

fn addNode(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: *tinykg.checkpoint.Runtime,
    args: []const []const u8,
) ![]u8 {
    const parsed = try parseAddNodeArguments(args);
    try validateNodeText(parsed.text);
    try validateMetadata(parsed.name, parsed.summary, parsed.retrieval_hints);
    var effective = try loadEffectiveSchema(allocator, runtime);
    defer effective.deinit();
    try validateCanonicalSchemaPath(allocator, io, effective, parsed.schema_path);
    const kind = try parseNodeKind(parsed.kind_label, effective);
    const node_id = try nextNodeId(runtime);
    const recorded_ns = persistentNowNs(io);

    var operations: [9]tinykg.checkpoint.Operation = undefined;
    var count: usize = 0;
    operations[count] = .{ .node_upsert = .{
        .id = node_id,
        .kind = @intFromEnum(kind),
        .text = parsed.text,
    } };
    count += 1;
    if (parsed.name) |value| appendStringProperty(&operations, &count, 1, node_id, "name", value);
    if (parsed.summary) |value| appendStringProperty(&operations, &count, 1, node_id, "summary", value);
    if (parsed.retrieval_hints) |value| appendStringProperty(&operations, &count, 1, node_id, "retrieval_hints", value);
    if (parsed.schema_type) |value| appendStringProperty(&operations, &count, 1, node_id, "schema_type", value);
    if (kind == .task) {
        appendStringProperty(&operations, &count, 1, node_id, "status", "open");
        appendUintProperty(&operations, &count, 1, node_id, "task_recorded_ns", recorded_ns);
        appendUintProperty(&operations, &count, 1, node_id, "task_created_ns", recorded_ns);
    }
    if (effective.enforce_application_schema) {
        for (operations[1..count]) |operation| switch (operation) {
            .property_upsert => |property| try validatePropertyForType(
                effective.catalog.registry,
                1,
                @intFromEnum(kind),
                property,
            ),
            else => {},
        };
    }
    _ = try runtime.applyMutation(operations[0..count]);
    return std.fmt.allocPrint(allocator, "node {}\n", .{node_id});
}

fn validateNodeText(text: []const u8) !void {
    const chars = std.unicode.utf8CountCodepoints(text) catch return error.InvalidRecord;
    if (chars > 8 * 1024 + 512) return error.NodeTextTooLarge;
}

fn validateMetadata(name: ?[]const u8, summary: ?[]const u8, hints: ?[]const u8) !void {
    var total: usize = 0;
    inline for (.{ name, summary, hints }) |value| if (value) |text| {
        const chars = std.unicode.utf8CountCodepoints(text) catch return error.InvalidRecord;
        if (chars > 6000) return error.NodePropertyTooLarge;
        total = std.math.add(usize, total, chars) catch return error.NodePropertyTooLarge;
    };
    if (total > 12000) return error.NodePropertyTooLarge;
}

fn persistentNowNs(io: std.Io) u64 {
    const timestamp = std.Io.Clock.real.now(io).nanoseconds;
    return if (timestamp <= 0) 1 else @intCast(@min(@as(u128, @intCast(timestamp)), std.math.maxInt(u64)));
}

fn appendStringProperty(
    operations: []tinykg.checkpoint.Operation,
    count: *usize,
    owner_type: u8,
    owner_id: u64,
    key: []const u8,
    value: []const u8,
) void {
    operations[count.*] = .{ .property_upsert = .{
        .owner_type = owner_type,
        .owner_id = owner_id,
        .key_hash = tinykg.storage.propertyKeyHashForLookup(key),
        .value_kind = .string,
        .string_value = value,
    } };
    count.* += 1;
}

fn appendUintProperty(
    operations: []tinykg.checkpoint.Operation,
    count: *usize,
    owner_type: u8,
    owner_id: u64,
    key: []const u8,
    value: u64,
) void {
    operations[count.*] = .{ .property_upsert = .{
        .owner_type = owner_type,
        .owner_id = owner_id,
        .key_hash = tinykg.storage.propertyKeyHashForLookup(key),
        .value_kind = .uint,
        .uint_value = value,
    } };
    count.* += 1;
}

fn validatePropertyOperations(
    runtime: *const tinykg.checkpoint.Runtime,
    effective: EffectiveSchema,
    operations: []const tinykg.checkpoint.Operation,
) !void {
    if (!effective.enforce_application_schema) return;
    for (operations) |operation| switch (operation) {
        .property_upsert => |property| try validateProperty(runtime, effective, property),
        else => {},
    };
}

fn validateProperty(
    runtime: *const tinykg.checkpoint.Runtime,
    effective: EffectiveSchema,
    property: tinykg.checkpoint.Property,
) !void {
    const type_id: u16 = switch (property.owner_type) {
        1 => @intFromEnum((runtime.graph.getNode(.fromInt(property.owner_id)) orelse return tinykg.core.Error.NotFound).kind),
        2 => blk: {
            const edge = edgeById(runtime, property.owner_id) orelse return tinykg.core.Error.NotFound;
            break :blk @intFromEnum(edge.rel);
        },
        else => return error.InvalidRecord,
    };
    return validatePropertyForType(
        effective.catalog.registry,
        property.owner_type,
        type_id,
        property,
    );
}

fn validatePropertyForType(
    registry: tinykg.schema.Registry,
    owner_type: u8,
    type_id: u16,
    property: tinykg.checkpoint.Property,
) !void {
    const metadata = propertyMetadataByHash(registry, owner_type, type_id, property.key_hash) orelse return error.UnknownProperty;
    switch (property.value_kind) {
        .string => switch (metadata.value_type) {
            .string, .json => {},
            .@"enum" => if (!metadata.enumAllows(property.string_value)) return error.InvalidRecord,
            else => return error.InvalidRecord,
        },
        .uint => if (metadata.value_type != .uint) return error.InvalidRecord,
    }
}

fn propertyMetadataByHash(
    registry: tinykg.schema.Registry,
    owner_type: u8,
    type_id: u16,
    key_hash: u64,
) ?tinykg.schema.PropertyMeta {
    var index: usize = 0;
    while (true) : (index += 1) {
        const metadata = if (owner_type == 1)
            registry.nodePropertyInfo(type_id, index)
        else
            registry.relationPropertyInfo(type_id, index);
        const value = metadata orelse return null;
        if (tinykg.storage.propertyKeyHashForLookup(value.name) == key_hash) return value;
    }
}

fn setStringProperty(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: *tinykg.checkpoint.Runtime,
    args: []const []const u8,
    owner_type: u8,
) ![]u8 {
    if (args.len < 3) return error.MissingArgument;
    const schema_path: ?[]const u8 = if (args.len == 5 and std.mem.eql(u8, args[3], "--schema"))
        args[4]
    else if (args.len == 3)
        null
    else if (args.len > 3 and std.mem.startsWith(u8, args[3], "--"))
        return error.UnknownOption
    else
        return error.TooManyArguments;
    const key = try normalizeStringPropertyKey(owner_type, args[1]);
    const owner_id = if (owner_type == 1) try parseNodeId(args[0]) else try parseEdgeId(args[0]);
    try validateStringPropertyValue(owner_type, key, args[2]);
    if (owner_type == 1) {
        _ = runtime.graph.getNode(.fromInt(owner_id)) orelse return tinykg.core.Error.NotFound;
    } else if (edgeById(runtime, owner_id) == null) {
        return tinykg.core.Error.NotFound;
    }
    var effective = try loadEffectiveSchema(allocator, runtime);
    defer effective.deinit();
    try validateCanonicalSchemaPath(allocator, io, effective, schema_path);
    const property = tinykg.checkpoint.Property{
        .owner_type = owner_type,
        .owner_id = owner_id,
        .key_hash = tinykg.storage.propertyKeyHashForLookup(key),
        .value_kind = .string,
        .string_value = args[2],
    };
    if (effective.enforce_application_schema) try validateProperty(runtime, effective, property);
    _ = try runtime.applyMutation(&.{.{ .property_upsert = property }});
    return if (owner_type == 1)
        std.fmt.allocPrint(allocator, "node_property node={} key={s} bytes={}\n", .{ owner_id, key, args[2].len })
    else
        std.fmt.allocPrint(allocator, "edge_property edge={} key={s} bytes={}\n", .{ owner_id, key, args[2].len });
}

fn normalizeStringPropertyKey(owner_type: u8, raw: []const u8) ![]const u8 {
    if (owner_type == 1) {
        const key = if (std.mem.eql(u8, raw, "retrieval-hints")) "retrieval_hints" else raw;
        if (std.mem.eql(u8, key, "name") or
            std.mem.eql(u8, key, "summary") or
            std.mem.eql(u8, key, "retrieval_hints")) return key;
        return error.InvalidRecord;
    }
    const key = if (std.mem.eql(u8, raw, "markdown-attr"))
        "markdown_attr"
    else if (std.mem.eql(u8, raw, "render-flags"))
        "render_flags"
    else if (std.mem.eql(u8, raw, "source-span"))
        "source_span"
    else if (std.mem.eql(u8, raw, "created-by"))
        "created_by"
    else
        raw;
    if (std.mem.eql(u8, key, "markdown_attr") or
        std.mem.eql(u8, key, "render_flags") or
        std.mem.eql(u8, key, "source_span") or
        std.mem.eql(u8, key, "confidence") or
        std.mem.eql(u8, key, "created_by") or
        std.mem.eql(u8, key, "state")) return key;
    return error.InvalidRecord;
}

fn validateStringPropertyValue(owner_type: u8, key: []const u8, value: []const u8) !void {
    if (owner_type == 1) {
        if (std.mem.eql(u8, key, "name")) return validateMetadata(value, null, null);
        if (std.mem.eql(u8, key, "summary")) return validateMetadata(null, value, null);
        if (std.mem.eql(u8, key, "retrieval_hints")) return validateMetadata(null, null, value);
        return;
    }
    if (std.mem.eql(u8, key, "state")) {
        if (!std.mem.eql(u8, value, "tentative") and !std.mem.eql(u8, value, "confirmed")) return error.InvalidRecord;
        return;
    }
    const chars = std.unicode.utf8CountCodepoints(value) catch return error.InvalidRecord;
    if (chars == 0 or chars > 6000) return error.NodePropertyTooLarge;
}

fn addEdge(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: *tinykg.checkpoint.Runtime,
    args: []const []const u8,
) ![]u8 {
    if (args.len < 3) return error.MissingArgument;
    const schema_path: ?[]const u8 = if (args.len == 5 and std.mem.eql(u8, args[3], "--schema"))
        args[4]
    else if (args.len == 3)
        null
    else if (args.len > 3 and std.mem.startsWith(u8, args[3], "--"))
        return error.UnknownOption
    else
        return error.TooManyArguments;
    const src = try parseNodeId(args[0]);
    const dst = try parseNodeId(args[2]);
    const src_node = runtime.graph.getNode(.fromInt(src)) orelse return tinykg.core.Error.NotFound;
    const dst_node = runtime.graph.getNode(.fromInt(dst)) orelse return tinykg.core.Error.NotFound;
    var effective = try loadEffectiveSchema(allocator, runtime);
    defer effective.deinit();
    try validateCanonicalSchemaPath(allocator, io, effective, schema_path);
    const rel = try parseRelKind(args[1], effective);
    if (effective.enforce_application_schema) try validateEndpoints(effective.catalog.registry, src_node.kind, rel, dst_node.kind);
    if ((rel == .contain or rel == .contains) and dst_node.kind == .project and src_node.kind != .project) {
        return error.ProjectTreeViolation;
    }
    if (try tinykg.dag.wouldCreateCycleWithIndex(
        &runtime.graph,
        &runtime.graph_index,
        .fromInt(src),
        .fromInt(dst),
        rel,
        .{},
    )) return tinykg.core.Error.CycleDetected;
    for (runtime.graph.edges.items) |edge| {
        if (edge.status == .active and edge.src.toInt() == src and edge.dst.toInt() == dst and edge.rel == rel) {
            return std.fmt.allocPrint(allocator, "edge {}\n", .{edge.id.toInt()});
        }
    }
    const edge_id = try nextEdgeId(runtime);
    _ = try runtime.applyMutation(&.{.{ .edge_upsert = .{
        .id = edge_id,
        .src = src,
        .rel = @intFromEnum(rel),
        .dst = dst,
    } }});
    return std.fmt.allocPrint(allocator, "edge {}\n", .{edge_id});
}

fn validateEndpoints(
    registry: tinykg.schema.Registry,
    src_kind: tinykg.NodeKind,
    rel: tinykg.RelKind,
    dst_kind: tinykg.NodeKind,
) !void {
    const rule = registry.relationEndpointRuleById(@intFromEnum(rel)) orelse return error.UnknownRelationKind;
    if (!registry.hasNodeTypeId(@intFromEnum(src_kind)) or !registry.hasNodeTypeId(@intFromEnum(dst_kind))) {
        return error.UnknownNodeKind;
    }
    if (rule.src) |allowed| if (!allowed.containsNodeKind(src_kind)) return error.SchemaEndpointViolation;
    if (rule.dst) |allowed| if (!allowed.containsNodeKind(dst_kind)) return error.SchemaEndpointViolation;
}

fn edgeById(runtime: *const tinykg.checkpoint.Runtime, id: u64) ?tinykg.graph.Edge {
    for (runtime.graph.edges.items) |edge| {
        if (edge.status == .active and edge.id.toInt() == id) return edge;
    }
    return null;
}

fn nodeDeprecatedBy(runtime: *const tinykg.checkpoint.Runtime, id: u64) ?u64 {
    for (runtime.graph.edges.items) |edge| {
        if (edge.status == .active and edge.src.toInt() == id and edge.rel == .deprecated_by) return edge.dst.toInt();
    }
    return null;
}

fn stringProperty(
    runtime: *const tinykg.checkpoint.Runtime,
    owner_type: u8,
    owner_id: u64,
    key: []const u8,
) ?[]const u8 {
    const property = runtime.query_view.property(
        owner_type,
        owner_id,
        tinykg.storage.propertyKeyHashForLookup(key),
    ) orelse return null;
    return if (property.value_kind == .string) property.string_value else null;
}

test "compact command catalog is explicit and fail closed" {
    try std.testing.expect(supports(.get));
    try std.testing.expect(supports(.add_node));
    try std.testing.expect(!supports(.task_close));
    try std.testing.expect(!supports(.governance));
}
