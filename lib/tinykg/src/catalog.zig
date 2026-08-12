const std = @import("std");
const schema = @import("schema.zig");
const core = @import("core.zig");

pub const catalog_magic = [_]u8{ 'T', 'K', 'G', 'C' };
pub const catalog_version: u16 = 3;
pub const catalog_legacy_version: u16 = 2;
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
    return encodeCatalogVersion(allocator, cat, catalog_version);
}

fn encodeCatalogVersion(allocator: std.mem.Allocator, cat: Catalog, version: u16) ![]u8 {
    if (version != catalog_version and version != catalog_legacy_version) return Error.InvalidVersion;
    if (cat.format_version != catalog_format_version_legacy and cat.format_version != catalog_format_version_embedded) return Error.InvalidVersion;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var record_count: u32 = 0;

    var node_type_index: usize = 0;
    while (cat.registry.nodeTypeInfo(node_type_index)) |info| : (node_type_index += 1) {
        try encodeNodeTypeRecord(allocator, &out, info.id, info.name, info.parents);
        record_count += 1;
        var prop_index: usize = 0;
        while (cat.registry.nodePropertyInfo(info.id, prop_index)) |prop| : (prop_index += 1) {
            try encodePropertyRecord(allocator, &out, .node_property, info.id, prop, version);
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
            try encodePropertyRecord(allocator, &out, .relation_property, info.id, prop, version);
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
    std.mem.writeInt(u16, result[4..6], version, .little);
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
    if (version != catalog_version and version != catalog_legacy_version) return Error.InvalidVersion;
    const format_version = std.mem.readInt(u16, bytes[6..8], .little);
    if (format_version != catalog_format_version_legacy and format_version != catalog_format_version_embedded) return Error.InvalidVersion;
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
            .node_property => offset = try decodePropertyRecord(&cat, .node_property, body, offset, version),
            .relation_property => offset = try decodePropertyRecord(&cat, .relation_property, body, offset, version),
            .composition => offset = try decodeCompositionRecord(&cat, body, offset),
            .profile => offset = try decodeProfileRecord(&cat, body, offset),
            .retired_type => offset = try decodeRetiredTypeRecord(&cat, body, offset),
        }
        count += 1;
    }
    if (count != record_count or offset != body.len) return Error.InvalidRecord;
    try validateDecodedCatalog(&cat);

    // The catalog is a control-plane schema, not an append log.  Accepting
    // multiple encodings for the same in-memory state makes duplicate
    // property/composition records silently become "last writer wins" and
    // lets record order affect governance.  Re-encoding is cheap at catalog
    // scale and gives the decoder one fail-closed canonicality rule.
    const canonical = try encodeCatalogVersion(allocator, cat, version);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, bytes, canonical)) return Error.InvalidRecord;
    return cat;
}

fn validateDecodedCatalog(cat: *const Catalog) !void {
    var profiles = std.StringHashMap(void).init(cat.allocator);
    defer profiles.deinit();
    for (cat.profiles.items) |profile| {
        if (profile.len == 0) return Error.InvalidRecord;
        const entry = try profiles.getOrPut(profile);
        if (entry.found_existing) return Error.InvalidRecord;
    }

    const RetiredKey = struct {
        domain: TypeDomain,
        id: u16,
    };
    var retired_ids = std.AutoHashMap(RetiredKey, void).init(cat.allocator);
    defer retired_ids.deinit();
    for (cat.retired.items) |retired| {
        if (retired.name.len == 0 or retired.retired_at_revision == 0 or retired.retired_at_revision > cat.revision) {
            return Error.InvalidRecord;
        }
        const entry = try retired_ids.getOrPut(.{ .domain = retired.domain, .id = retired.id });
        if (entry.found_existing) return Error.InvalidRecord;
        const active = switch (retired.domain) {
            .node => cat.registry.hasNodeTypeId(retired.id),
            .relation => cat.registry.hasRelationTypeId(retired.id),
        };
        if (active) return Error.InvalidRecord;
    }
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
    if ((try readU8(body, &offset)) != 0) return Error.InvalidRecord;
    const id = try readU16(body, &offset);
    const name_len = try readU8(body, &offset);
    if (offset > body.len or name_len > body.len - offset) return Error.InvalidRecord;
    const name = body[offset .. offset + name_len];
    offset += name_len;
    const parent_count = try readU8(body, &offset);
    if (parent_count > max_parents) return Error.InvalidRecord;
    if (@as(usize, parent_count) * 2 > body.len - offset) return Error.InvalidRecord;
    var parents_buf: [max_parents]u16 = [_]u16{0} ** max_parents;
    var i: u8 = 0;
    while (i < parent_count) : (i += 1) {
        parents_buf[i] = try readU16(body, &offset);
    }
    if (cat.registry.hasNodeTypeId(id)) return Error.InvalidRecord;
    try cat.registry.addNodeType(name, id, parents_buf[0..parent_count]);
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
    if (offset > body.len or name_len > body.len - offset) return Error.InvalidRecord;
    const name = body[offset .. offset + name_len];
    offset += name_len;
    const parent_count = try readU8(body, &offset);
    if (parent_count > max_parents) return Error.InvalidRecord;
    if (@as(usize, parent_count) * 2 > body.len - offset) return Error.InvalidRecord;
    var parents_buf: [max_parents]u16 = [_]u16{0} ** max_parents;
    var i: u8 = 0;
    while (i < parent_count) : (i += 1) {
        parents_buf[i] = try readU16(body, &offset);
    }
    var endpoint: schema.RelationEndpointRule = .{};
    const has_src = try readU8(body, &offset);
    if (has_src > 1) return Error.InvalidRecord;
    if (has_src == 1) {
        endpoint.src = try decodeTypeSet(body, &offset);
    }
    const has_dst = try readU8(body, &offset);
    if (has_dst > 1) return Error.InvalidRecord;
    if (has_dst == 1) {
        endpoint.dst = try decodeTypeSet(body, &offset);
    }
    if (cat.registry.hasRelationTypeId(id)) return Error.InvalidRecord;
    try cat.registry.addRelationTypeWithMetadata(name, id, parents_buf[0..parent_count], endpoint, class);
    return offset;
}

fn encodePropertyRecord(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tag: RecordTag,
    type_id: u16,
    prop: schema.PropertyMeta,
    version: u16,
) !void {
    if (prop.name.len > max_name_len) return Error.NameTooLong;
    try out.append(allocator, @intFromEnum(tag));
    try appendU16(allocator, out, type_id);
    try out.append(allocator, @intCast(prop.name.len));
    try out.appendSlice(allocator, prop.name);
    try out.append(allocator, @intFromEnum(prop.value_type));
    const flags = PropertyFlags.fromPropertyMeta(prop);
    try out.append(allocator, @bitCast(flags));
    if (version < 3) return;
    if (prop.value_type == .@"enum" and prop.enum_values.len == 0) return Error.InvalidRecord;
    if (prop.value_type != .@"enum" and prop.enum_values.len != 0) return Error.InvalidRecord;
    if (prop.enum_values.len > schema.max_enum_values) return Error.RecordTooLarge;
    try out.append(allocator, @intCast(prop.enum_values.len));
    for (prop.enum_values) |value| {
        if (value.len == 0 or value.len > schema.max_enum_value_bytes) return Error.RecordTooLarge;
        try out.append(allocator, @intCast(value.len));
        try out.appendSlice(allocator, value);
    }
}

fn decodePropertyRecord(
    cat: *Catalog,
    tag: RecordTag,
    body: []const u8,
    start: usize,
    version: u16,
) !usize {
    var offset = start;
    const type_id = try readU16(body, &offset);
    const name_len = try readU8(body, &offset);
    if (offset > body.len or name_len > body.len - offset) return Error.InvalidRecord;
    const name = body[offset .. offset + name_len];
    offset += name_len;
    if (offset >= body.len) return Error.InvalidRecord;
    const value_type = std.enums.fromInt(schema.PropertyType, body[offset]) orelse return Error.InvalidRecord;
    offset += 1;
    if (offset >= body.len) return Error.InvalidRecord;
    const flags: PropertyFlags = @bitCast(body[offset]);
    if (flags._reserved != 0) return Error.InvalidRecord;
    offset += 1;

    var enum_values_buf: [schema.max_enum_values][]const u8 = undefined;
    var enum_value_count: u8 = 0;
    if (version >= 3) {
        enum_value_count = try readU8(body, &offset);
        if (enum_value_count > schema.max_enum_values) return Error.InvalidRecord;
        if (value_type == .@"enum" and enum_value_count == 0) return Error.InvalidRecord;
        if (value_type != .@"enum" and enum_value_count != 0) return Error.InvalidRecord;
        var enum_index: u8 = 0;
        while (enum_index < enum_value_count) : (enum_index += 1) {
            const value_len = try readU8(body, &offset);
            if (value_len == 0 or value_len > schema.max_enum_value_bytes) return Error.InvalidRecord;
            if (offset > body.len or value_len > body.len - offset) return Error.InvalidRecord;
            enum_values_buf[enum_index] = body[offset .. offset + value_len];
            offset += value_len;
        }
    } else if (value_type == .@"enum" and tag == .node_property and type_id == @intFromEnum(core.NodeKind.task) and std.mem.eql(u8, name, "status")) {
        enum_value_count = schema.task_status_enum_values.len;
        for (&schema.task_status_enum_values, 0..) |value, index| enum_values_buf[index] = value;
    }

    const meta = schema.PropertyMeta{
        .name = name,
        .value_type = value_type,
        .enum_values = enum_values_buf[0..enum_value_count],
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
    const enabled_raw = try readU8(body, &offset);
    const owner_raw = try readU8(body, &offset);
    if (enabled_raw > 1 or owner_raw > 1) return Error.InvalidRecord;
    const enabled = enabled_raw == 1;
    const owner = owner_raw == 1;
    if (offset >= body.len) return Error.InvalidRecord;
    const cardinality = std.enums.fromInt(schema.CompositionCardinality, body[offset]) orelse return Error.InvalidRecord;
    offset += 1;
    const ordered_by_len = try readU8(body, &offset);
    var ordered_by: ?[]const u8 = null;
    if (ordered_by_len > 0) {
        if (offset > body.len or ordered_by_len > body.len - offset) return Error.InvalidRecord;
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
    if (offset > body.len or label_len > body.len - offset) return Error.InvalidRecord;
    const label = try cat.allocator.dupe(u8, body[offset .. offset + label_len]);
    errdefer cat.allocator.free(label);
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
    if (offset > body.len or name_len > body.len - offset) return Error.InvalidRecord;
    const name = try cat.allocator.dupe(u8, body[offset .. offset + name_len]);
    errdefer cat.allocator.free(name);
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
    if (@as(usize, word_count) * 8 > body.len - offset.*) return Error.InvalidRecord;
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
    if (offset.* > body.len or 2 > body.len - offset.*) return Error.InvalidRecord;
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
    if (offset.* > body.len or 4 > body.len - offset.*) return Error.InvalidRecord;
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
    if (offset.* > body.len or 8 > body.len - offset.*) return Error.InvalidRecord;
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

fn wrapRawCatalogBodyForTest(
    allocator: std.mem.Allocator,
    body: []const u8,
    record_count: u32,
) ![]u8 {
    const encoded = try allocator.alloc(u8, header_len + body.len);
    @memcpy(encoded[0..4], &catalog_magic);
    std.mem.writeInt(u16, encoded[4..6], catalog_version, .little);
    std.mem.writeInt(u16, encoded[6..8], catalog_format_version_embedded, .little);
    std.mem.writeInt(u32, encoded[8..12], 0, .little);
    std.mem.writeInt(u32, encoded[12..16], record_count, .little);
    std.mem.writeInt(u64, encoded[16..24], fnv1a64(body), .little);
    @memcpy(encoded[header_len..], body);
    return encoded;
}

fn decodeCatalogAllocationFailure(allocator: std.mem.Allocator, encoded: []const u8) !void {
    var decoded = try decodeCatalog(allocator, encoded);
    defer decoded.deinit();
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
    const status = decoded.registry.nodePropertyByTypeId(@intFromEnum(core.NodeKind.task), "status").?;
    try std.testing.expect(status.enumAllows("completed"));
    try std.testing.expect(!status.enumAllows("done-ish"));
}

test "catalog v2 status enum gains the canonical compatibility domain" {
    var cat = try Catalog.kernelOnly(std.testing.allocator);
    defer cat.deinit();
    try cat.registry.addBuiltinProfile(.agent_dag);

    const encoded = try encodeCatalogVersion(std.testing.allocator, cat, catalog_legacy_version);
    defer std.testing.allocator.free(encoded);
    var decoded = try decodeCatalog(std.testing.allocator, encoded);
    defer decoded.deinit();

    const status = decoded.registry.nodePropertyByTypeId(@intFromEnum(core.NodeKind.task), "status").?;
    try std.testing.expectEqual(schema.task_status_enum_values.len, status.enum_values.len);
    try std.testing.expect(status.enumAllows("claimed"));
    try std.testing.expect(!status.enumAllows("done-ish"));
}

test "catalog v2 task status string property remains readable" {
    var cat = try Catalog.kernelOnly(std.testing.allocator);
    defer cat.deinit();
    try cat.registry.addNodeType("task", @intFromEnum(core.NodeKind.task), &.{schema.kernel_node_type_id});
    try cat.registry.setNodeProperty(@intFromEnum(core.NodeKind.task), .{
        .name = "status",
        .value_type = .string,
    });

    const encoded = try encodeCatalogVersion(std.testing.allocator, cat, catalog_legacy_version);
    defer std.testing.allocator.free(encoded);
    var decoded = try decodeCatalog(std.testing.allocator, encoded);
    defer decoded.deinit();

    const status = decoded.registry.nodePropertyByTypeId(@intFromEnum(core.NodeKind.task), "status").?;
    try std.testing.expectEqual(schema.PropertyType.string, status.value_type);
    try std.testing.expectEqual(@as(usize, 0), status.enum_values.len);
}

test "catalog v3 rejects open ended enum domains while v2 stays readable" {
    var cat = try Catalog.kernelOnly(std.testing.allocator);
    defer cat.deinit();
    try cat.registry.addNodeType("LegacyEnumOwner", 100, &.{});
    try cat.registry.setNodeProperty(100, .{
        .name = "legacy_state",
        .value_type = .@"enum",
    });

    try std.testing.expectError(Error.InvalidRecord, encodeCatalog(std.testing.allocator, cat));
    const encoded_v2 = try encodeCatalogVersion(std.testing.allocator, cat, catalog_legacy_version);
    defer std.testing.allocator.free(encoded_v2);
    var decoded_v2 = try decodeCatalog(std.testing.allocator, encoded_v2);
    defer decoded_v2.deinit();
    try std.testing.expect(decoded_v2.registry.nodePropertyByTypeId(100, "legacy_state").?.enumAllows("legacy-value"));
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

    cat.revision = 5;
    const retired_id: u16 = 101;
    try cat.retired.append(cat.allocator, .{
        .id = retired_id,
        .domain = .node,
        .name = try cat.allocator.dupe(u8, "old_task"),
        .retired_at_revision = 5,
    });

    const encoded = try encodeCatalog(std.testing.allocator, cat);
    defer std.testing.allocator.free(encoded);

    var decoded = try decodeCatalog(std.testing.allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(usize, 1), decoded.retired.items.len);
    try std.testing.expectEqual(retired_id, decoded.retired.items[0].id);
    try std.testing.expectEqualStrings("old_task", decoded.retired.items[0].name);
    try std.testing.expectEqual(@as(u32, 5), decoded.retired.items[0].retired_at_revision);
}

test "catalog decode releases partial profile and retired allocations" {
    var cat = try Catalog.kernelOnly(std.testing.allocator);
    defer cat.deinit();
    cat.revision = 7;
    try cat.profiles.append(cat.allocator, try cat.allocator.dupe(u8, "agent-memory"));
    try cat.retired.append(cat.allocator, .{
        .id = 101,
        .domain = .node,
        .name = try cat.allocator.dupe(u8, "old-task"),
        .retired_at_revision = 7,
    });
    const encoded = try encodeCatalog(std.testing.allocator, cat);
    defer std.testing.allocator.free(encoded);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decodeCatalogAllocationFailure, .{encoded});
}

test "catalog rejects duplicate profiles and inconsistent retired ids" {
    {
        var cat = try Catalog.kernelOnly(std.testing.allocator);
        defer cat.deinit();
        try cat.profiles.append(cat.allocator, try cat.allocator.dupe(u8, "agent-memory"));
        try cat.profiles.append(cat.allocator, try cat.allocator.dupe(u8, "agent-memory"));
        const encoded = try encodeCatalog(std.testing.allocator, cat);
        defer std.testing.allocator.free(encoded);
        try std.testing.expectError(Error.InvalidRecord, decodeCatalog(std.testing.allocator, encoded));
    }

    {
        var cat = try Catalog.kernelOnly(std.testing.allocator);
        defer cat.deinit();
        cat.revision = 3;
        try cat.retired.append(cat.allocator, .{
            .id = schema.kernel_node_type_id,
            .domain = .node,
            .name = try cat.allocator.dupe(u8, "old-node"),
            .retired_at_revision = 2,
        });
        const encoded = try encodeCatalog(std.testing.allocator, cat);
        defer std.testing.allocator.free(encoded);
        try std.testing.expectError(Error.InvalidRecord, decodeCatalog(std.testing.allocator, encoded));
    }

    {
        var cat = try Catalog.kernelOnly(std.testing.allocator);
        defer cat.deinit();
        cat.revision = 3;
        inline for (.{ "old-a", "old-b" }) |name| {
            try cat.retired.append(cat.allocator, .{
                .id = 101,
                .domain = .node,
                .name = try cat.allocator.dupe(u8, name),
                .retired_at_revision = 3,
            });
        }
        const encoded = try encodeCatalog(std.testing.allocator, cat);
        defer std.testing.allocator.free(encoded);
        try std.testing.expectError(Error.InvalidRecord, decodeCatalog(std.testing.allocator, encoded));
    }

    {
        var cat = try Catalog.kernelOnly(std.testing.allocator);
        defer cat.deinit();
        cat.revision = 3;
        try cat.retired.append(cat.allocator, .{
            .id = 101,
            .domain = .node,
            .name = try cat.allocator.dupe(u8, "future-retirement"),
            .retired_at_revision = 4,
        });
        const encoded = try encodeCatalog(std.testing.allocator, cat);
        defer std.testing.allocator.free(encoded);
        try std.testing.expectError(Error.InvalidRecord, decodeCatalog(std.testing.allocator, encoded));
    }
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

test "catalog rejects noncanonical format and reserved node byte" {
    var cat = try Catalog.kernelOnly(std.testing.allocator);
    defer cat.deinit();
    const encoded = try encodeCatalog(std.testing.allocator, cat);
    defer std.testing.allocator.free(encoded);
    var bad_format = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(bad_format);
    std.mem.writeInt(u16, bad_format[6..8], 99, .little);
    try std.testing.expectError(Error.InvalidVersion, decodeCatalog(std.testing.allocator, bad_format));

    var bad_reserved = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(bad_reserved);
    bad_reserved[header_len + 1] = 1;
    std.mem.writeInt(u64, bad_reserved[16..24], fnv1a64(bad_reserved[header_len..]), .little);
    try std.testing.expectError(Error.InvalidRecord, decodeCatalog(std.testing.allocator, bad_reserved));
}

test "catalog rejects node type parent count beyond fixed decoder capacity" {
    var body = std.ArrayList(u8).empty;
    defer body.deinit(std.testing.allocator);
    try body.append(std.testing.allocator, @intFromEnum(RecordTag.node_type));
    try body.append(std.testing.allocator, 0);
    try appendU16(std.testing.allocator, &body, 100);
    try body.append(std.testing.allocator, 1);
    try body.append(std.testing.allocator, 'n');
    const invalid_parent_count = max_parents + 1;
    try body.append(std.testing.allocator, invalid_parent_count);
    var i: u8 = 0;
    while (i < invalid_parent_count) : (i += 1) {
        try appendU16(std.testing.allocator, &body, 0);
    }

    const encoded = try wrapRawCatalogBodyForTest(std.testing.allocator, body.items, 1);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(Error.InvalidRecord, decodeCatalog(std.testing.allocator, encoded));
}

test "catalog rejects relation type parent count beyond fixed decoder capacity" {
    var body = std.ArrayList(u8).empty;
    defer body.deinit(std.testing.allocator);
    try body.append(std.testing.allocator, @intFromEnum(RecordTag.relation_type));
    try body.append(std.testing.allocator, @intFromEnum(schema.RelationClass.domain));
    try appendU16(std.testing.allocator, &body, 100);
    try body.append(std.testing.allocator, 1);
    try body.append(std.testing.allocator, 'r');
    const invalid_parent_count = max_parents + 1;
    try body.append(std.testing.allocator, invalid_parent_count);
    var i: u8 = 0;
    while (i < invalid_parent_count) : (i += 1) {
        try appendU16(std.testing.allocator, &body, 0);
    }
    try body.append(std.testing.allocator, 0);
    try body.append(std.testing.allocator, 0);

    const encoded = try wrapRawCatalogBodyForTest(std.testing.allocator, body.items, 1);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(Error.InvalidRecord, decodeCatalog(std.testing.allocator, encoded));
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
