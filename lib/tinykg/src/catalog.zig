const std = @import("std");
const schema = @import("schema.zig");
const core = @import("core.zig");

pub const catalog_magic = [_]u8{ 'T', 'K', 'G', 'C' };
pub const catalog_version: u16 = 2;
pub const catalog_format_version_legacy: u16 = 1;
pub const catalog_format_version_embedded: u16 = 2;

pub const header_len: usize = 24;
pub const max_name_len: u8 = 63;
pub const max_parents: u8 = schema.max_direct_parents;
pub const node_type_set_word_count: usize = (@as(usize, schema.max_node_types) + 63) / 64;

pub const Error = error{
    InvalidMagic,
    InvalidVersion,
    InvalidChecksum,
    InvalidRecord,
    RecordTooLarge,
    NameTooLong,
    TooManyParents,
    TypeIdOutOfRange,
    InvalidFlags,
};

pub const RecordTag = enum(u8) {
    node_type = 0x01,
    relation_type = 0x02,
    node_property = 0x03,
    relation_property = 0x04,
    composition = 0x05,
    profile = 0x06,
    retired_type = 0x07,
};

pub const PropertyFlags = packed struct(u8) {
    required: bool = false,
    nullable: bool = true,
    agent_fillable: bool = false,
    human_fillable: bool = false,
    indexed: bool = false,
    searchable: bool = false,
    returned_by_default: bool = false,
    _reserved: u1 = 0,

    pub fn fromPropertyMeta(meta: schema.PropertyMeta) PropertyFlags {
        return .{
            .required = meta.required,
            .nullable = meta.nullable,
            .agent_fillable = meta.agent_fillable,
            .human_fillable = meta.human_fillable,
            .indexed = meta.indexed,
            .searchable = meta.searchable,
            .returned_by_default = meta.returned_by_default,
        };
    }

    pub fn toPropertyMetaFlags(self: PropertyFlags) struct {
        required: bool,
        nullable: bool,
        agent_fillable: bool,
        human_fillable: bool,
        indexed: bool,
        searchable: bool,
        returned_by_default: bool,
    } {
        return .{
            .required = self.required,
            .nullable = self.nullable,
            .agent_fillable = self.agent_fillable,
            .human_fillable = self.human_fillable,
            .indexed = self.indexed,
            .searchable = self.searchable,
            .returned_by_default = self.returned_by_default,
        };
    }
};

pub const TypeDomain = enum(u8) {
    node = 0,
    relation = 1,
};

pub const RetiredType = struct {
    id: u16,
    domain: TypeDomain,
    name: []const u8,
    retired_at_revision: u32,
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    registry: schema.Registry,
    profiles: std.ArrayList([]u8) = .empty,
    retired: std.ArrayList(RetiredType) = .empty,
    format_version: u16 = catalog_format_version_embedded,
    revision: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{
            .allocator = allocator,
            .registry = schema.Registry.init(allocator),
        };
    }

    pub fn deinit(self: *Catalog) void {
        for (self.profiles.items) |p| self.allocator.free(p);
        self.profiles.deinit(self.allocator);
        for (self.retired.items) |r| self.allocator.free(r.name);
        self.retired.deinit(self.allocator);
        self.registry.deinit();
    }

    pub fn fromRegistry(allocator: std.mem.Allocator, registry: schema.Registry) !Catalog {
        var cat = Catalog.init(allocator);
        errdefer cat.deinit();
        cat.registry = registry;
        return cat;
    }

    pub fn kernelOnly(allocator: std.mem.Allocator) !Catalog {
        var cat = Catalog.init(allocator);
        try cat.registry.addKernelTypes();
        return cat;
    }
};

pub fn encodeCatalog(allocator: std.mem.Allocator, cat: Catalog) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var record_count: u32 = 0;

    var node_type_index: usize = 0;
    while (cat.registry.nodeTypeInfo(node_type_index)) |info| : (node_type_index += 1) {
        try encodeNodeTypeRecord(allocator, &out, info.id, info.name, info.parents);
        record_count += 1;
        var prop_index: usize = 0;
        while (cat.registry.nodePropertyInfo(info.id, prop_index)) |prop| : (prop_index += 1) {
            try encodePropertyRecord(allocator, &out, .node_property, info.id, prop);
            record_count += 1;
        }
    }

    var rel_type_index: usize = 0;
    while (cat.registry.relationTypeInfo(rel_type_index)) |info| : (rel_type_index += 1) {
        const endpoint = cat.registry.relationEndpointRuleById(info.id) orelse schema.RelationEndpointRule{};
        try encodeRelationTypeRecord(allocator, &out, info.id, info.name, info.parents, info.class, endpoint);
        record_count += 1;
        var prop_index: usize = 0;
        while (cat.registry.relationPropertyInfo(info.id, prop_index)) |prop| : (prop_index += 1) {
            try encodePropertyRecord(allocator, &out, .relation_property, info.id, prop);
            record_count += 1;
        }
        if (cat.registry.relationCompositionById(info.id)) |comp| {
            try encodeCompositionRecord(allocator, &out, info.id, comp);
            record_count += 1;
        }
    }

    for (cat.profiles.items) |label| {
        try encodeProfileRecord(allocator, &out, label);
        record_count += 1;
    }

    for (cat.retired.items) |r| {
        try encodeRetiredTypeRecord(allocator, &out, r);
        record_count += 1;
    }

    const body_len = out.items.len;
    const total_len = header_len + body_len;
    const result = try allocator.alloc(u8, total_len);

    @memcpy(result[0..4], &catalog_magic);
    std.mem.writeInt(u16, result[4..6], catalog_version, .little);
    std.mem.writeInt(u16, result[6..8], cat.format_version, .little);
    std.mem.writeInt(u32, result[8..12], cat.revision, .little);
    std.mem.writeInt(u32, result[12..16], record_count, .little);

    const checksum = fnv1a64(out.items);
    std.mem.writeInt(u64, result[16..24], checksum, .little);

    @memcpy(result[header_len..], out.items);
    return result;
}

pub fn decodeCatalog(allocator: std.mem.Allocator, bytes: []const u8) !Catalog {
    if (bytes.len < header_len) return Error.InvalidRecord;
    if (!std.mem.eql(u8, bytes[0..4], &catalog_magic)) return Error.InvalidMagic;
    const version = std.mem.readInt(u16, bytes[4..6], .little);
    if (version != catalog_version) return Error.InvalidVersion;
    const format_version = std.mem.readInt(u16, bytes[6..8], .little);
    const revision = std.mem.readInt(u32, bytes[8..12], .little);
    const record_count = std.mem.readInt(u32, bytes[12..16], .little);
    const stored_checksum = std.mem.readInt(u64, bytes[16..24], .little);

    const body = bytes[header_len..];
    const computed = fnv1a64(body);
    if (computed != stored_checksum) return Error.InvalidChecksum;

    var cat = Catalog.init(allocator);
    errdefer cat.deinit();
    cat.format_version = format_version;
    cat.revision = revision;

    var offset: usize = 0;
    var count: u32 = 0;
    while (count < record_count and offset < body.len) {
        const tag = std.enums.fromInt(RecordTag, body[offset]) orelse return Error.InvalidRecord;
        offset += 1;
        switch (tag) {
            .node_type => offset = try decodeNodeTypeRecord(&cat, body, offset),
            .relation_type => offset = try decodeRelationTypeRecord(&cat, body, offset),
            .node_property => offset = try decodePropertyRecord(&cat, .node_property, body, offset),
            .relation_property => offset = try decodePropertyRecord(&cat, .relation_property, body, offset),
            .composition => offset = try decodeCompositionRecord(&cat, body, offset),
            .profile => offset = try decodeProfileRecord(&cat, body, offset),
            .retired_type => offset = try decodeRetiredTypeRecord(&cat, body, offset),
        }
        count += 1;
    }
    if (count != record_count) return Error.InvalidRecord;
    return cat;
}

fn encodeNodeTypeRecord(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    id: u16,
    name: []const u8,
    parents: []const u16,
) !void {
    if (name.len > max_name_len) return Error.NameTooLong;
    if (parents.len > max_parents) return Error.TooManyParents;
    try out.append(allocator, @intFromEnum(RecordTag.node_type));
    try out.append(allocator, 0); // reserved/domain byte for future use
    try appendU16(allocator, out, id);
    try out.append(allocator, @intCast(name.len));
    try out.appendSlice(allocator, name);
    try out.append(allocator, @intCast(parents.len));
    for (parents) |p| try appendU16(allocator, out, p);
}

fn decodeNodeTypeRecord(
    cat: *Catalog,
    body: []const u8,
    start: usize,
) !usize {
    var offset = start;
    offset += 1; // reserved/domain byte
    const id = try readU16(body, &offset);
    const name_len = try readU8(body, &offset);
    if (offset + name_len > body.len) return Error.InvalidRecord;
    const name = body[offset .. offset + name_len];
    offset += name_len;
    const parent_count = try readU8(body, &offset);
    if (offset + @as(usize, parent_count) * 2 > body.len) return Error.InvalidRecord;
    var parents_buf: [max_parents]u16 = [_]u16{0} ** max_parents;
    var i: u8 = 0;
    while (i < parent_count) : (i += 1) {
        parents_buf[i] = try readU16(body, &offset);
    }
    if (!cat.registry.hasNodeTypeId(id)) {
        try cat.registry.addNodeType(name, id, parents_buf[0..parent_count]);
    }
    return offset;
}

fn encodeRelationTypeRecord(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    id: u16,
    name: []const u8,
    parents: []const u16,
    class: schema.RelationClass,
    endpoint: schema.RelationEndpointRule,
) !void {
    if (name.len > max_name_len) return Error.NameTooLong;
    if (parents.len > max_parents) return Error.TooManyParents;
    try out.append(allocator, @intFromEnum(RecordTag.relation_type));
    try out.append(allocator, @intFromEnum(class));
    try appendU16(allocator, out, id);
    try out.append(allocator, @intCast(name.len));
    try out.appendSlice(allocator, name);
    try out.append(allocator, @intCast(parents.len));
    for (parents) |p| try appendU16(allocator, out, p);
    try out.append(allocator, if (endpoint.src != null) 1 else 0);
    if (endpoint.src) |src| try encodeTypeSet(allocator, out, src);
    try out.append(allocator, if (endpoint.dst != null) 1 else 0);
    if (endpoint.dst) |dst| try encodeTypeSet(allocator, out, dst);
}

fn decodeRelationTypeRecord(
    cat: *Catalog,
    body: []const u8,
    start: usize,
) !usize {
    var offset = start;
    if (offset >= body.len) return Error.InvalidRecord;
    const class = std.enums.fromInt(schema.RelationClass, body[offset]) orelse return Error.InvalidRecord;
    offset += 1;
    const id = try readU16(body, &offset);
    const name_len = try readU8(body, &offset);
    if (offset + name_len > body.len) return Error.InvalidRecord;
    const name = body[offset .. offset + name_len];
    offset += name_len;
    const parent_count = try readU8(body, &offset);
    if (offset + @as(usize, parent_count) * 2 > body.len) return Error.InvalidRecord;
    var parents_buf: [max_parents]u16 = [_]u16{0} ** max_parents;
    var i: u8 = 0;
    while (i < parent_count) : (i += 1) {
        parents_buf[i] = try readU16(body, &offset);
    }
    var endpoint: schema.RelationEndpointRule = .{};
    const has_src = try readU8(body, &offset);
    if (has_src != 0) {
        endpoint.src = try decodeTypeSet(body, &offset);
    }
    const has_dst = try readU8(body, &offset);
    if (has_dst != 0) {
        endpoint.dst = try decodeTypeSet(body, &offset);
    }
    if (!cat.registry.hasRelationTypeId(id)) {
        try cat.registry.addRelationTypeWithMetadata(name, id, parents_buf[0..parent_count], endpoint, class);
    }
    return offset;
}

fn encodePropertyRecord(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tag: RecordTag,
    type_id: u16,
    prop: schema.PropertyMeta,
) !void {
    if (prop.name.len > max_name_len) return Error.NameTooLong;
    try out.append(allocator, @intFromEnum(tag));
    try appendU16(allocator, out, type_id);
    try out.append(allocator, @intCast(prop.name.len));
    try out.appendSlice(allocator, prop.name);
    try out.append(allocator, @intFromEnum(prop.value_type));
    const flags = PropertyFlags.fromPropertyMeta(prop);
    try out.append(allocator, @bitCast(flags));
}

fn decodePropertyRecord(
    cat: *Catalog,
    tag: RecordTag,
    body: []const u8,
    start: usize,
) !usize {
    var offset = start;
    const type_id = try readU16(body, &offset);
    const name_len = try readU8(body, &offset);
    if (offset + name_len > body.len) return Error.InvalidRecord;
    const name = body[offset .. offset + name_len];
    offset += name_len;
    if (offset >= body.len) return Error.InvalidRecord;
    const value_type = std.enums.fromInt(schema.PropertyType, body[offset]) orelse return Error.InvalidRecord;
    offset += 1;
    if (offset >= body.len) return Error.InvalidRecord;
    const flags: PropertyFlags = @bitCast(body[offset]);
    offset += 1;

    const meta = schema.PropertyMeta{
        .name = name,
        .value_type = value_type,
        .required = flags.required,
        .nullable = flags.nullable,
        .agent_fillable = flags.agent_fillable,
        .human_fillable = flags.human_fillable,
        .indexed = flags.indexed,
        .searchable = flags.searchable,
        .returned_by_default = flags.returned_by_default,
    };
    switch (tag) {
        .node_property => try cat.registry.setNodeProperty(type_id, meta),
        .relation_property => try cat.registry.setRelationProperty(type_id, meta),
        else => return Error.InvalidRecord,
    }
    return offset;
}

fn encodeCompositionRecord(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    type_id: u16,
    comp: schema.CompositionMeta,
) !void {
    try out.append(allocator, @intFromEnum(RecordTag.composition));
    try appendU16(allocator, out, type_id);
    try out.append(allocator, if (comp.enabled) 1 else 0);
    try out.append(allocator, if (comp.owner) 1 else 0);
    try out.append(allocator, @intFromEnum(comp.cardinality));
    const ordered_by_len: u8 = if (comp.ordered_by) |ob| blk: {
        if (ob.len > max_name_len) return Error.NameTooLong;
        break :blk @intCast(ob.len);
    } else 0;
    try out.append(allocator, ordered_by_len);
    if (comp.ordered_by) |ob| try out.appendSlice(allocator, ob);
}

fn decodeCompositionRecord(
    cat: *Catalog,
    body: []const u8,
    start: usize,
) !usize {
    var offset = start;
    const type_id = try readU16(body, &offset);
    const enabled = (try readU8(body, &offset)) != 0;
    const owner = (try readU8(body, &offset)) != 0;
    if (offset >= body.len) return Error.InvalidRecord;
    const cardinality = std.enums.fromInt(schema.CompositionCardinality, body[offset]) orelse return Error.InvalidRecord;
    offset += 1;
    const ordered_by_len = try readU8(body, &offset);
    var ordered_by: ?[]const u8 = null;
    if (ordered_by_len > 0) {
        if (offset + ordered_by_len > body.len) return Error.InvalidRecord;
        ordered_by = body[offset .. offset + ordered_by_len];
        offset += ordered_by_len;
    }
    try cat.registry.setRelationComposition(type_id, .{
        .enabled = enabled,
        .owner = owner,
        .cardinality = cardinality,
        .ordered_by = ordered_by,
    });
    return offset;
}

fn encodeProfileRecord(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    label: []const u8,
) !void {
    if (label.len > max_name_len) return Error.NameTooLong;
    try out.append(allocator, @intFromEnum(RecordTag.profile));
    try out.append(allocator, @intCast(label.len));
    try out.appendSlice(allocator, label);
}

fn decodeProfileRecord(
    cat: *Catalog,
    body: []const u8,
    start: usize,
) !usize {
    var offset = start;
    const label_len = try readU8(body, &offset);
    if (offset + label_len > body.len) return Error.InvalidRecord;
    const label = try cat.allocator.dupe(u8, body[offset .. offset + label_len]);
    offset += label_len;
    try cat.profiles.append(cat.allocator, label);
    return offset;
}

fn encodeRetiredTypeRecord(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    r: RetiredType,
) !void {
    if (r.name.len > max_name_len) return Error.NameTooLong;
    try out.append(allocator, @intFromEnum(RecordTag.retired_type));
    try out.append(allocator, @intFromEnum(r.domain));
    try appendU16(allocator, out, r.id);
    try out.append(allocator, @intCast(r.name.len));
    try out.appendSlice(allocator, r.name);
    try appendU32(allocator, out, r.retired_at_revision);
}

fn decodeRetiredTypeRecord(
    cat: *Catalog,
    body: []const u8,
    start: usize,
) !usize {
    var offset = start;
    if (offset >= body.len) return Error.InvalidRecord;
    const domain = std.enums.fromInt(TypeDomain, body[offset]) orelse return Error.InvalidRecord;
    offset += 1;
    const id = try readU16(body, &offset);
    const name_len = try readU8(body, &offset);
    if (offset + name_len > body.len) return Error.InvalidRecord;
    const name = try cat.allocator.dupe(u8, body[offset .. offset + name_len]);
    offset += name_len;
    const retired_at = try readU32(body, &offset);
    try cat.retired.append(cat.allocator, .{
        .id = id,
        .domain = domain,
        .name = name,
        .retired_at_revision = retired_at,
    });
    return offset;
}

fn encodeTypeSet(allocator: std.mem.Allocator, out: *std.ArrayList(u8), set: schema.NodeTypeSet) !void {
    const word_count: u8 = @intCast(node_type_set_word_count);
    try out.append(allocator, word_count);
    for (set.words) |word| try appendU64(allocator, out, word);
}

fn decodeTypeSet(body: []const u8, offset: *usize) !schema.NodeTypeSet {
    if (offset.* >= body.len) return Error.InvalidRecord;
    const word_count = body[offset.*];
    offset.* += 1;
    if (word_count > node_type_set_word_count) return Error.RecordTooLarge;
    if (offset.* + @as(usize, word_count) * 8 > body.len) return Error.InvalidRecord;
    var set = schema.NodeTypeSet.empty();
    var i: usize = 0;
    while (i < word_count) : (i += 1) {
        set.words[i] = try readU64(body, offset);
    }
    return set;
}

fn appendU16(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, value, .little);
    try out.appendSlice(allocator, &buf);
}

fn readU8(body: []const u8, offset: *usize) !u8 {
    if (offset.* >= body.len) return Error.InvalidRecord;
    const v = body[offset.*];
    offset.* += 1;
    return v;
}

fn readU16(body: []const u8, offset: *usize) !u16 {
    if (offset.* + 2 > body.len) return Error.InvalidRecord;
    const v = std.mem.readInt(u16, body[offset.*..][0..2], .little);
    offset.* += 2;
    return v;
}

fn appendU32(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try out.appendSlice(allocator, &buf);
}

fn readU32(body: []const u8, offset: *usize) !u32 {
    if (offset.* + 4 > body.len) return Error.InvalidRecord;
    const v = std.mem.readInt(u32, body[offset.*..][0..4], .little);
    offset.* += 4;
    return v;
}

fn appendU64(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    try out.appendSlice(allocator, &buf);
}

fn readU64(body: []const u8, offset: *usize) !u64 {
    if (offset.* + 8 > body.len) return Error.InvalidRecord;
    const v = std.mem.readInt(u64, body[offset.*..][0..8], .little);
    offset.* += 8;
    return v;
}

fn fnv1a64(data: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (data) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    return hash;
}

test "catalog round-trip kernel-only" {
    var cat = try Catalog.kernelOnly(std.testing.allocator);
    defer cat.deinit();

    const encoded = try encodeCatalog(std.testing.allocator, cat);
    defer std.testing.allocator.free(encoded);

    var decoded = try decodeCatalog(std.testing.allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u16, catalog_format_version_embedded), decoded.format_version);
    try std.testing.expect(decoded.registry.hasNodeTypeId(schema.kernel_node_type_id));
    try std.testing.expect(decoded.registry.hasRelationTypeId(schema.kernel_edge_type_id));
    try std.testing.expectEqualStrings("node", decoded.registry.nodeTypeNameById(schema.kernel_node_type_id).?);
    try std.testing.expectEqualStrings("edge", decoded.registry.relationTypeNameById(schema.kernel_edge_type_id).?);
}

test "catalog round-trip with agent-dag profile" {
    var cat = try Catalog.kernelOnly(std.testing.allocator);
    defer cat.deinit();
    try cat.registry.addBuiltinProfile(.agent_dag);

    const encoded = try encodeCatalog(std.testing.allocator, cat);
    defer std.testing.allocator.free(encoded);

    var decoded = try decodeCatalog(std.testing.allocator, encoded);
    defer decoded.deinit();

    try std.testing.expect(decoded.registry.hasNodeTypeId(@intFromEnum(core.NodeKind.task)));
    try std.testing.expectEqualStrings("task", decoded.registry.nodeTypeNameById(@intFromEnum(core.NodeKind.task)).?);
    try std.testing.expect(decoded.registry.hasRelationTypeId(@intFromEnum(core.RelKind.depends_on)));
    try std.testing.expectEqualStrings("depends_on", decoded.registry.relationTypeNameById(@intFromEnum(core.RelKind.depends_on)).?);
}

test "catalog round-trip with properties and composition" {
    var cat = try Catalog.kernelOnly(std.testing.allocator);
    defer cat.deinit();
    try cat.registry.addBuiltinProfile(.agent_dag);
    try cat.registry.addBuiltinProfile(.markdown_document);

    const task_id = @intFromEnum(core.NodeKind.task);
    try cat.registry.setNodeProperty(task_id, .{
        .name = "priority",
        .value_type = .uint,
        .required = true,
        .nullable = false,
        .agent_fillable = true,
        .indexed = true,
    });

    const contains_id = @intFromEnum(core.RelKind.contains);
    try cat.registry.setRelationComposition(contains_id, .{
        .enabled = true,
        .owner = true,
        .cardinality = .many,
        .ordered_by = "order_key",
    });

    const encoded = try encodeCatalog(std.testing.allocator, cat);
    defer std.testing.allocator.free(encoded);

    var decoded = try decodeCatalog(std.testing.allocator, encoded);
    defer decoded.deinit();

    const prop = decoded.registry.nodePropertyByTypeId(task_id, "priority").?;
    try std.testing.expectEqual(schema.PropertyType.uint, prop.value_type);
    try std.testing.expect(prop.required);
    try std.testing.expect(!prop.nullable);
    try std.testing.expect(prop.agent_fillable);
    try std.testing.expect(prop.indexed);

    const comp = decoded.registry.relationCompositionById(contains_id).?;
    try std.testing.expect(comp.enabled);
    try std.testing.expect(comp.owner);
    try std.testing.expectEqual(schema.CompositionCardinality.many, comp.cardinality);
    try std.testing.expectEqualStrings("order_key", comp.ordered_by.?);
}

test "catalog round-trip with retired type" {
    var cat = try Catalog.kernelOnly(std.testing.allocator);
    defer cat.deinit();
    try cat.registry.addBuiltinProfile(.agent_dag);

    const task_id = @intFromEnum(core.NodeKind.task);
    try cat.retired.append(cat.allocator, .{
        .id = task_id,
        .domain = .node,
        .name = try cat.allocator.dupe(u8, "old_task"),
        .retired_at_revision = 5,
    });

    const encoded = try encodeCatalog(std.testing.allocator, cat);
    defer std.testing.allocator.free(encoded);

    var decoded = try decodeCatalog(std.testing.allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(usize, 1), decoded.retired.items.len);
    try std.testing.expectEqual(task_id, decoded.retired.items[0].id);
    try std.testing.expectEqualStrings("old_task", decoded.retired.items[0].name);
    try std.testing.expectEqual(@as(u32, 5), decoded.retired.items[0].retired_at_revision);
}

test "catalog rejects bad magic" {
    const bad = [_]u8{ 'X', 'X', 'X', 'X' } ++ [_]u8{0} ** 20;
    try std.testing.expectError(Error.InvalidMagic, decodeCatalog(std.testing.allocator, &bad));
}

test "catalog rejects unknown record tag" {
    var cat = try Catalog.kernelOnly(std.testing.allocator);
    defer cat.deinit();
    const encoded = try encodeCatalog(std.testing.allocator, cat);
    defer std.testing.allocator.free(encoded);
    var corrupted = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(corrupted);
    corrupted[header_len] = 0xFF;
    // Recompute checksum so we get past the checksum check to hit the tag validation
    const new_checksum = fnv1a64(corrupted[header_len..]);
    std.mem.writeInt(u64, corrupted[16..24], new_checksum, .little);
    try std.testing.expectError(Error.InvalidRecord, decodeCatalog(std.testing.allocator, corrupted));
}

test "catalog rejects truncated record" {
    var cat = try Catalog.kernelOnly(std.testing.allocator);
    defer cat.deinit();
    const encoded = try encodeCatalog(std.testing.allocator, cat);
    defer std.testing.allocator.free(encoded);
    var truncated = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(truncated);
    // Truncate the body but keep the header intact with original record_count
    const trunc_len = header_len + 2;
    // Recompute checksum for the truncated body
    const new_checksum = fnv1a64(truncated[header_len..trunc_len]);
    std.mem.writeInt(u64, truncated[16..24], new_checksum, .little);
    try std.testing.expectError(Error.InvalidRecord, decodeCatalog(std.testing.allocator, truncated[0..trunc_len]));
}

test "catalog rejects bad checksum" {
    var cat = try Catalog.kernelOnly(std.testing.allocator);
    defer cat.deinit();
    const encoded = try encodeCatalog(std.testing.allocator, cat);
    defer std.testing.allocator.free(encoded);
    var corrupted = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(corrupted);
    corrupted[16] ^= 0xFF;
    try std.testing.expectError(Error.InvalidChecksum, decodeCatalog(std.testing.allocator, corrupted));
}
