const std = @import("std");
const core = @import("core.zig");

pub const max_node_types: u16 = 4096;
pub const max_relation_types: u16 = 16384;
pub const max_inheritance_depth: u8 = 8;
pub const max_direct_parents: u8 = 4;
pub const node_descendant_fast_cap: u16 = 128;
pub const relation_descendant_fast_cap: u16 = 64;
pub const max_traits: u16 = 64;
pub const max_traits_per_node: u8 = 8;
pub const max_enum_values: u8 = 32;
pub const max_enum_value_bytes: u8 = 63;

pub const task_status_enum_values = [_][]const u8{
    "open",
    "claimed",
    "completed",
    "failed",
};

pub const md_rel_h1_id: u16 = 3000;
pub const md_rel_h2_id: u16 = 3001;
pub const md_rel_h3_id: u16 = 3002;
pub const md_rel_h4_id: u16 = 3003;
pub const md_rel_h5_id: u16 = 3004;
pub const md_rel_h6_id: u16 = 3005;
pub const md_rel_paragraph_id: u16 = 3010;
pub const md_rel_code_block_id: u16 = 3011;
pub const md_rel_image_id: u16 = 3012;
pub const md_rel_list_id: u16 = 3013;
pub const md_rel_blockquote_id: u16 = 3014;
pub const md_rel_html_block_id: u16 = 3015;
pub const md_rel_footnote_def_id: u16 = 3016;
pub const md_rel_link_reference_id: u16 = 3017;
pub const md_rel_thematic_break_id: u16 = 3018;
pub const md_rel_raw_block_id: u16 = 3019;
pub const md_rel_table_id: u16 = 3020;
pub const md_rel_table_row_id: u16 = 3021;
pub const md_rel_table_cell_id: u16 = 3022;
pub const md_rel_text_chunk_id: u16 = 3023;

/// md:* 投影关系 id 全集(**单一真理源**,挨常量定义放)。加新 md rel 常量必须同步进此表,
/// 否则 comptime 单测(cli composition membership)红——防"新 md rel 静默漏出 search --project
/// membership"(markdown 召回全灭 bug 的复刻)。精确集合而非区间:3006..3009 空隙不误染。
pub const md_projection_rel_ids = [_]u16{
    md_rel_h1_id,           md_rel_h2_id,             md_rel_h3_id,             md_rel_h4_id,
    md_rel_h5_id,           md_rel_h6_id,             md_rel_paragraph_id,      md_rel_code_block_id,
    md_rel_image_id,        md_rel_list_id,           md_rel_blockquote_id,     md_rel_html_block_id,
    md_rel_footnote_def_id, md_rel_link_reference_id, md_rel_thematic_break_id, md_rel_raw_block_id,
    md_rel_table_id,        md_rel_table_row_id,      md_rel_table_cell_id,     md_rel_text_chunk_id,
};

/// rel 是否 md:* 投影关系(document→heading→paragraph 结构边)。
pub fn isMdProjectionRelId(rel: u16) bool {
    inline for (md_projection_rel_ids) |id| {
        if (rel == id) return true;
    }
    return false;
}
pub const kernel_node_type_id: u16 = max_node_types - 1;
pub const kernel_edge_type_id: u16 = max_relation_types - 1;

pub const Error = error{
    TypeIdOutOfRange,
    DuplicateTypeId,
    DuplicateTypeName,
    DuplicatePropertyName,
    InvalidPropertyName,
    UnknownParentType,
    TooManyParents,
    InheritanceTooDeep,
    DescendantSetTooBroad,
    InvalidEnumValues,
};

pub const BuiltinProfile = enum {
    agent_dag,
    markdown_document,

    pub fn fromLabel(raw_label: []const u8) ?BuiltinProfile {
        if (std.ascii.eqlIgnoreCase(raw_label, "agent-dag")) return .agent_dag;
        if (std.ascii.eqlIgnoreCase(raw_label, "agent_dag")) return .agent_dag;
        if (std.ascii.eqlIgnoreCase(raw_label, "markdown-document")) return .markdown_document;
        if (std.ascii.eqlIgnoreCase(raw_label, "markdown_document")) return .markdown_document;
        return null;
    }

    pub fn label(self: BuiltinProfile) []const u8 {
        return switch (self) {
            .agent_dag => "agent-dag",
            .markdown_document => "markdown-document",
        };
    }
};

pub fn FixedTypeSet(comptime max_types: u16) type {
    const word_count = (@as(usize, max_types) + 63) / 64;
    return struct {
        const Self = @This();

        words: [word_count]u64 = [_]u64{0} ** word_count,

        pub fn empty() Self {
            return .{};
        }

        pub fn singleton(id: u16) !Self {
            var out = Self.empty();
            try out.insert(id);
            return out;
        }

        pub fn insert(self: *Self, id: u16) !void {
            if (id >= max_types) return Error.TypeIdOutOfRange;
            self.words[@as(usize, id) / 64] |= @as(u64, 1) << @intCast(id % 64);
        }

        pub fn containsId(self: Self, id: u16) bool {
            if (id >= max_types) return false;
            return (self.words[@as(usize, id) / 64] & (@as(u64, 1) << @intCast(id % 64))) != 0;
        }

        pub fn containsNodeKind(self: Self, kind: core.NodeKind) bool {
            return self.containsId(@intFromEnum(kind));
        }

        pub fn containsRelKind(self: Self, rel: core.RelKind) bool {
            return self.containsId(@intFromEnum(rel));
        }

        pub fn merge(self: *Self, other: Self) void {
            for (&self.words, other.words) |*word, other_word| {
                word.* |= other_word;
            }
        }

        pub fn count(self: Self) u16 {
            var total: u16 = 0;
            for (self.words) |word| {
                total += @intCast(@popCount(word));
            }
            return total;
        }
    };
}

pub const NodeTypeSet = FixedTypeSet(max_node_types);
pub const RelationTypeSet = FixedTypeSet(max_relation_types);

pub const NodeTypeFilter = union(enum) {
    any,
    single: core.NodeKind,
    set: NodeTypeSet,

    pub fn fromOptionalKind(kind: ?core.NodeKind) NodeTypeFilter {
        return if (kind) |value| .{ .single = value } else .any;
    }

    pub fn fromDescendants(set: NodeTypeSet) NodeTypeFilter {
        return if (set.count() == 0) .any else .{ .set = set };
    }

    pub fn matches(self: NodeTypeFilter, kind: core.NodeKind) bool {
        return switch (self) {
            .any => true,
            .single => |single| single == kind,
            .set => |set| set.containsNodeKind(kind),
        };
    }

    pub fn asSingle(self: NodeTypeFilter) ?core.NodeKind {
        return switch (self) {
            .single => |kind| kind,
            else => null,
        };
    }
};

pub const RelationTypeFilter = union(enum) {
    any,
    single: core.RelKind,
    set: RelationTypeSet,

    pub fn fromOptionalRel(rel: ?core.RelKind) RelationTypeFilter {
        return if (rel) |value| .{ .single = value } else .any;
    }

    pub fn fromDescendants(set: RelationTypeSet) RelationTypeFilter {
        return if (set.count() == 0) .any else .{ .set = set };
    }

    pub fn matches(self: RelationTypeFilter, rel: core.RelKind) bool {
        return switch (self) {
            .any => true,
            .single => |single| single == rel,
            .set => |set| set.containsRelKind(rel),
        };
    }

    pub fn asSingle(self: RelationTypeFilter) ?core.RelKind {
        return switch (self) {
            .single => |rel| rel,
            else => null,
        };
    }
};

const TypeDef = struct {
    id: u16,
    name: []u8,
    parents: [max_direct_parents]u16 = [_]u16{0} ** max_direct_parents,
    parent_count: u8 = 0,
    endpoint_rule: RelationEndpointRule = .{},
    relation_class: RelationClass = .domain,
    properties: std.ArrayList(PropertyMeta) = .empty,

    fn deinit(self: *TypeDef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.properties.items) |property| deinitPropertyMeta(allocator, property);
        self.properties.deinit(allocator);
    }

    fn hasParent(self: TypeDef, parent_id: u16) bool {
        for (self.parents[0..self.parent_count]) |id| {
            if (id == parent_id) return true;
        }
        return false;
    }
};

pub const TypeInfo = struct {
    id: u16,
    name: []const u8,
    parents: []const u16,
};

pub const RelationTypeInfo = struct {
    id: u16,
    name: []const u8,
    parents: []const u16,
    class: RelationClass,
};

pub const RelationClass = enum(u8) {
    domain,
    md,
    prov,
    task,
    sys,
    ref, // 跨模块引用(acts_on/uses/produces/about):任务闭合投影,连任务面↔对象/方法/产物

    pub fn label(self: RelationClass) []const u8 {
        return switch (self) {
            .domain => "domain",
            .md => "md",
            .prov => "prov",
            .task => "task",
            .sys => "sys",
            .ref => "ref",
        };
    }

    pub fn fromLabel(raw_label: []const u8) ?RelationClass {
        if (std.ascii.eqlIgnoreCase(raw_label, "domain")) return .domain;
        if (std.ascii.eqlIgnoreCase(raw_label, "md")) return .md;
        if (std.ascii.eqlIgnoreCase(raw_label, "markdown")) return .md;
        if (std.ascii.eqlIgnoreCase(raw_label, "prov")) return .prov;
        if (std.ascii.eqlIgnoreCase(raw_label, "provenance")) return .prov;
        if (std.ascii.eqlIgnoreCase(raw_label, "task")) return .task;
        if (std.ascii.eqlIgnoreCase(raw_label, "sys")) return .sys;
        if (std.ascii.eqlIgnoreCase(raw_label, "system")) return .sys;
        if (std.ascii.eqlIgnoreCase(raw_label, "ref")) return .ref;
        return null;
    }
};

pub const RelationEndpointRule = struct {
    src: ?NodeTypeSet = null,
    dst: ?NodeTypeSet = null,

    pub fn isEmpty(self: RelationEndpointRule) bool {
        return self.src == null and self.dst == null;
    }
};

pub const PropertyType = enum(u8) {
    string,
    uint,
    int,
    bool,
    @"enum",
    json,

    pub fn fromLabel(raw_label: []const u8) ?PropertyType {
        if (std.ascii.eqlIgnoreCase(raw_label, "string")) return .string;
        if (std.ascii.eqlIgnoreCase(raw_label, "uint")) return .uint;
        if (std.ascii.eqlIgnoreCase(raw_label, "int")) return .int;
        if (std.ascii.eqlIgnoreCase(raw_label, "bool")) return .bool;
        if (std.ascii.eqlIgnoreCase(raw_label, "enum")) return .@"enum";
        if (std.ascii.eqlIgnoreCase(raw_label, "json")) return .json;
        return null;
    }

    pub fn label(self: PropertyType) []const u8 {
        return switch (self) {
            .string => "string",
            .uint => "uint",
            .int => "int",
            .bool => "bool",
            .@"enum" => "enum",
            .json => "json",
        };
    }
};

pub const PropertyMeta = struct {
    name: []const u8,
    value_type: PropertyType = .string,
    /// Closed string domain for enum properties. Empty is accepted only for
    /// catalogs written before enum domains were persisted.
    enum_values: []const []const u8 = &.{},
    required: bool = false,
    nullable: bool = true,
    agent_fillable: bool = false,
    human_fillable: bool = false,
    indexed: bool = false,
    searchable: bool = false,
    returned_by_default: bool = false,

    pub fn enumAllows(self: PropertyMeta, value: []const u8) bool {
        if (self.value_type != .@"enum") return false;
        // Legacy v2 catalogs had an enum tag but no persisted domain. Keep
        // those readable; newly parsed schemas require a non-empty domain.
        if (self.enum_values.len == 0) return true;
        for (self.enum_values) |candidate| {
            if (std.mem.eql(u8, candidate, value)) return true;
        }
        return false;
    }
};

pub const CompositionCardinality = enum(u8) {
    one,
    optional_one,
    many,

    pub fn fromLabel(raw_label: []const u8) ?CompositionCardinality {
        if (std.ascii.eqlIgnoreCase(raw_label, "one")) return .one;
        if (std.ascii.eqlIgnoreCase(raw_label, "optional_one")) return .optional_one;
        if (std.ascii.eqlIgnoreCase(raw_label, "many")) return .many;
        return null;
    }

    pub fn label(self: CompositionCardinality) []const u8 {
        return switch (self) {
            .one => "one",
            .optional_one => "optional_one",
            .many => "many",
        };
    }
};

pub const CompositionMeta = struct {
    enabled: bool = false,
    owner: bool = false,
    cardinality: CompositionCardinality = .many,
    ordered_by: ?[]const u8 = null,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    node_types: std.ArrayList(TypeDef) = .empty,
    relation_types: std.ArrayList(TypeDef) = .empty,
    node_property_lookup: std.StringHashMap(PropertyMeta),
    relation_property_lookup: std.StringHashMap(PropertyMeta),
    relation_composition_lookup: std.AutoHashMap(u16, CompositionMeta),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .node_property_lookup = std.StringHashMap(PropertyMeta).init(allocator),
            .relation_property_lookup = std.StringHashMap(PropertyMeta).init(allocator),
            .relation_composition_lookup = std.AutoHashMap(u16, CompositionMeta).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        {
            var it = self.node_property_lookup.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        }
        self.node_property_lookup.deinit();
        {
            var it = self.relation_property_lookup.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        }
        self.relation_property_lookup.deinit();
        {
            var it = self.relation_composition_lookup.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.ordered_by) |ordered_by| self.allocator.free(ordered_by);
            }
        }
        self.relation_composition_lookup.deinit();
        for (self.node_types.items) |*type_def| type_def.deinit(self.allocator);
        self.node_types.deinit(self.allocator);
        for (self.relation_types.items) |*type_def| type_def.deinit(self.allocator);
        self.relation_types.deinit(self.allocator);
    }

    pub fn addNodeType(self: *Registry, name: []const u8, id: u16, parents: []const u16) !void {
        try self.addType(&self.node_types, max_node_types, name, id, parents, .{}, .domain);
        try self.inheritCompiledProperties(&self.node_types, &self.node_property_lookup, "n", id);
        try self.addDefaultNodeProperties(id);
    }

    pub fn addRelationType(self: *Registry, name: []const u8, id: u16, parents: []const u16) !void {
        try self.addRelationTypeWithEndpointRule(name, id, parents, .{});
    }

    pub fn addRelationTypeWithEndpointRule(self: *Registry, name: []const u8, id: u16, parents: []const u16, endpoint_rule: RelationEndpointRule) !void {
        try self.addRelationTypeWithMetadata(name, id, parents, endpoint_rule, .domain);
    }

    pub fn addRelationTypeWithMetadata(self: *Registry, name: []const u8, id: u16, parents: []const u16, endpoint_rule: RelationEndpointRule, relation_class: RelationClass) !void {
        try self.addType(&self.relation_types, max_relation_types, name, id, parents, endpoint_rule, relation_class);
        try self.inheritCompiledProperties(&self.relation_types, &self.relation_property_lookup, "r", id);
    }

    pub fn setRelationEndpointRule(self: *Registry, id: u16, endpoint_rule: RelationEndpointRule) !void {
        for (self.relation_types.items) |*type_def| {
            if (type_def.id == id) {
                type_def.endpoint_rule = endpoint_rule;
                return;
            }
        }
        return Error.UnknownParentType;
    }

    pub fn setRelationClass(self: *Registry, id: u16, relation_class: RelationClass) !void {
        for (self.relation_types.items) |*type_def| {
            if (type_def.id == id) {
                type_def.relation_class = relation_class;
                return;
            }
        }
        return Error.UnknownParentType;
    }

    pub fn findNodeType(self: Registry, name: []const u8) ?u16 {
        return findType(self.node_types.items, name);
    }

    pub fn findRelationType(self: Registry, name: []const u8) ?u16 {
        return findType(self.relation_types.items, name);
    }

    pub fn nodeTypeCount(self: Registry) usize {
        return self.node_types.items.len;
    }

    pub fn relationTypeCount(self: Registry) usize {
        return self.relation_types.items.len;
    }

    pub fn relationCompositionCount(self: Registry) usize {
        return self.relation_composition_lookup.count();
    }

    pub fn nodeTypeInfo(self: Registry, index: usize) ?TypeInfo {
        if (index >= self.node_types.items.len) return null;
        return typeInfo(&self.node_types.items[index]);
    }

    pub fn relationTypeInfo(self: Registry, index: usize) ?RelationTypeInfo {
        if (index >= self.relation_types.items.len) return null;
        return relationInfoFromTypeDef(&self.relation_types.items[index]);
    }

    pub fn nodeTypeNameById(self: Registry, id: u16) ?[]const u8 {
        const type_def = findTypeById(self.node_types.items, id) orelse return null;
        return type_def.name;
    }

    pub fn hasNodeTypeId(self: Registry, id: u16) bool {
        return findTypeById(self.node_types.items, id) != null;
    }

    pub fn relationTypeNameById(self: Registry, id: u16) ?[]const u8 {
        const type_def = findTypeById(self.relation_types.items, id) orelse return null;
        return type_def.name;
    }

    pub fn hasRelationTypeId(self: Registry, id: u16) bool {
        return findTypeById(self.relation_types.items, id) != null;
    }

    pub fn relationEndpointRuleById(self: Registry, id: u16) ?RelationEndpointRule {
        const type_def = findTypeById(self.relation_types.items, id) orelse return null;
        return type_def.endpoint_rule;
    }

    pub fn relationClassById(self: Registry, id: u16) ?RelationClass {
        const type_def = findTypeById(self.relation_types.items, id) orelse return null;
        return type_def.relation_class;
    }

    pub fn setNodeProperty(self: *Registry, id: u16, property: PropertyMeta) !void {
        try self.setTypeProperty(&self.node_types, &self.node_property_lookup, "n", id, property);
    }

    pub fn setRelationProperty(self: *Registry, id: u16, property: PropertyMeta) !void {
        try self.setTypeProperty(&self.relation_types, &self.relation_property_lookup, "r", id, property);
    }

    pub fn nodePropertyByTypeId(self: Registry, id: u16, name: []const u8) ?PropertyMeta {
        return self.propertyByTypeId(self.node_property_lookup, "n", id, name);
    }

    pub fn relationPropertyByTypeId(self: Registry, id: u16, name: []const u8) ?PropertyMeta {
        return self.propertyByTypeId(self.relation_property_lookup, "r", id, name);
    }

    pub fn nodePropertyAllowed(self: Registry, kind: core.NodeKind, name: []const u8) bool {
        return self.nodePropertyByTypeId(@intFromEnum(kind), name) != null;
    }

    pub fn relationPropertyAllowed(self: Registry, rel: core.RelKind, name: []const u8) bool {
        return self.relationPropertyByTypeId(@intFromEnum(rel), name) != null;
    }

    pub fn nodePropertyCount(self: Registry, id: u16) usize {
        const type_def = findTypeById(self.node_types.items, id) orelse return 0;
        return type_def.properties.items.len;
    }

    pub fn relationPropertyCount(self: Registry, id: u16) usize {
        const type_def = findTypeById(self.relation_types.items, id) orelse return 0;
        return type_def.properties.items.len;
    }

    pub fn nodePropertyInfo(self: Registry, id: u16, index: usize) ?PropertyMeta {
        const type_def = findTypeById(self.node_types.items, id) orelse return null;
        if (index >= type_def.properties.items.len) return null;
        return type_def.properties.items[index];
    }

    pub fn relationPropertyInfo(self: Registry, id: u16, index: usize) ?PropertyMeta {
        const type_def = findTypeById(self.relation_types.items, id) orelse return null;
        if (index >= type_def.properties.items.len) return null;
        return type_def.properties.items[index];
    }

    pub fn setRelationComposition(self: *Registry, id: u16, composition: CompositionMeta) !void {
        if (findTypeById(self.relation_types.items, id) == null) return Error.UnknownParentType;
        var owned = composition;
        if (composition.ordered_by) |ordered_by| {
            owned.ordered_by = try self.allocator.dupe(u8, ordered_by);
        }
        errdefer if (owned.ordered_by) |ordered_by| self.allocator.free(ordered_by);
        const entry = try self.relation_composition_lookup.getOrPut(id);
        if (entry.found_existing) {
            if (entry.value_ptr.ordered_by) |old| self.allocator.free(old);
        }
        entry.value_ptr.* = owned;
    }

    pub fn relationCompositionById(self: Registry, id: u16) ?CompositionMeta {
        return self.relation_composition_lookup.get(id);
    }

    pub fn resolveNodeFilter(self: Registry, name: []const u8) !NodeTypeFilter {
        const id = self.findNodeType(name) orelse return Error.UnknownParentType;
        return NodeTypeFilter.fromDescendants(try self.nodeDescendants(id));
    }

    pub fn resolveRelationFilter(self: Registry, name: []const u8) !RelationTypeFilter {
        const id = self.findRelationType(name) orelse return Error.UnknownParentType;
        return RelationTypeFilter.fromDescendants(try self.relationDescendants(id));
    }

    pub fn nodeDescendants(self: Registry, id: u16) !NodeTypeSet {
        var out = try descendantSet(NodeTypeSet, self.node_types.items, max_node_types, id);
        if (out.count() > node_descendant_fast_cap) return Error.DescendantSetTooBroad;
        return out;
    }

    pub fn relationDescendants(self: Registry, id: u16) !RelationTypeSet {
        var out = try descendantSet(RelationTypeSet, self.relation_types.items, max_relation_types, id);
        if (out.count() > relation_descendant_fast_cap) return Error.DescendantSetTooBroad;
        return out;
    }

    pub fn addDefaultTypes(self: *Registry) !void {
        try self.addKernelTypes();
    }

    pub fn addKernelTypes(self: *Registry) !void {
        try self.addNodeType("node", kernel_node_type_id, &.{});
        try self.addRelationTypeWithMetadata("edge", kernel_edge_type_id, &.{}, .{}, .sys);
        // Project containment: every node lives under a project node via contain edge.
        try self.addNodeType("project", @intFromEnum(core.NodeKind.project), &.{kernel_node_type_id});
        try self.addRelationTypeWithMetadata("contain", @intFromEnum(core.RelKind.contain), &.{kernel_edge_type_id}, .{}, .sys);
    }

    pub fn addBuiltinProfile(self: *Registry, profile: BuiltinProfile) !void {
        return try self.addBuiltinProfileForSchemaVersion(profile, 3);
    }

    /// Build the profile contract promised by a store manifest. Schema v2
    /// predates durable task lifecycle properties; schema v3 makes `status`
    /// required and adds lease/timestamp fields. Storage-only compatibility
    /// migrations must not publish the v3 contract under a v2 manifest.
    pub fn addBuiltinProfileForSchemaVersion(self: *Registry, profile: BuiltinProfile, schema_version: u32) !void {
        if (schema_version < 1 or schema_version > 3) return error.InvalidSchemaVersion;
        return switch (profile) {
            .agent_dag => self.addAgentDagProfile(schema_version >= 3),
            .markdown_document => self.addMarkdownDocumentProfile(),
        };
    }

    /// Install the canonical task lifecycle properties on an already
    /// registered task type.  Store migrations use this narrower operation
    /// to upgrade an embedded catalog without re-adding every agent-dag type
    /// and relation (which may include project-specific extensions).
    pub fn setTaskLifecycleProperties(self: *Registry) !void {
        const task_type = @intFromEnum(core.NodeKind.task);
        if (!self.hasNodeTypeId(task_type)) return Error.UnknownParentType;
        try self.setNodeProperty(task_type, .{
            .name = "status",
            .value_type = .@"enum",
            .enum_values = &task_status_enum_values,
            .required = true,
            .nullable = false,
            .indexed = true,
            .returned_by_default = true,
        });
        try self.setNodeProperty(task_type, .{
            .name = "claimed_by",
            .value_type = .string,
            .required = false,
            .nullable = true,
            .indexed = true,
            .returned_by_default = true,
        });
        try self.setNodeProperty(task_type, .{
            .name = "claim_expires_ns",
            .value_type = .uint,
            .required = false,
            .nullable = true,
            .indexed = false,
        });
        inline for (.{ "task_recorded_ns", "task_created_ns", "task_completed_ns" }) |property_name| {
            try self.setNodeProperty(task_type, .{
                .name = property_name,
                .value_type = .uint,
                .required = false,
                .nullable = true,
                .indexed = true,
            });
        }
    }

    fn addAgentDagProfile(self: *Registry, include_task_lifecycle: bool) !void {
        try self.addNodeType("task", @intFromEnum(core.NodeKind.task), &.{kernel_node_type_id});
        // Lifecycle is a property, never a node-kind transition. The v3
        // schema requires `status`; pre-v3 stores remain readable through the
        // task compatibility path until an explicit migration materializes it.
        if (include_task_lifecycle) try self.setTaskLifecycleProperties();
        try self.addNodeType("decision", @intFromEnum(core.NodeKind.decision), &.{kernel_node_type_id});
        try self.addNodeType("evidence", @intFromEnum(core.NodeKind.evidence), &.{kernel_node_type_id});
        try self.addNodeType("verification", @intFromEnum(core.NodeKind.verification), &.{kernel_node_type_id});
        try self.addNodeType("observation", @intFromEnum(core.NodeKind.observation), &.{kernel_node_type_id});
        try self.addNodeType("command", @intFromEnum(core.NodeKind.command), &.{kernel_node_type_id});
        try self.addNodeType("error_event", @intFromEnum(core.NodeKind.error_event), &.{kernel_node_type_id});
        try self.addNodeType("edit", @intFromEnum(core.NodeKind.edit), &.{kernel_node_type_id});
        try self.addNodeType("fix", @intFromEnum(core.NodeKind.fix), &.{kernel_node_type_id});
        // concept:acts_on/uses/produces 投影目标(对象/方法/概念/产物)的节点类型。注册它,
        // 让 ref 边的 dst 在 schema-aware/governance 路径下是合法已注册类型(否则 UnknownNodeKind)。
        try self.addNodeType("concept", @intFromEnum(core.NodeKind.concept), &.{kernel_node_type_id});

        try self.addRelationTypeWithMetadata("depends_on", @intFromEnum(core.RelKind.depends_on), &.{kernel_edge_type_id}, .{}, .task);
        try self.addRelationTypeWithMetadata("blocks", @intFromEnum(core.RelKind.blocks), &.{kernel_edge_type_id}, .{}, .task);
        try self.addRelationTypeWithMetadata("evidences", @intFromEnum(core.RelKind.evidences), &.{kernel_edge_type_id}, .{}, .prov);
        try self.addRelationTypeWithMetadata("verified_by", @intFromEnum(core.RelKind.verified_by), &.{kernel_edge_type_id}, .{}, .prov);
        try self.addRelationTypeWithMetadata("based_on", @intFromEnum(core.RelKind.based_on), &.{kernel_edge_type_id}, .{}, .prov);
        // derived_from:溯源关系(记忆/分类纠正的 error_event derived_from 任务)。与 resolved_by
        // 对称注册,免得 schema-aware 校验收 resolved_by 却拒 derived_from(Linus #6)。
        try self.addRelationTypeWithMetadata("derived_from", @intFromEnum(core.RelKind.derived_from), &.{kernel_edge_type_id}, .{}, .prov);
        try self.addRelationTypeWithMetadata("resolved_by", @intFromEnum(core.RelKind.resolved_by), &.{kernel_edge_type_id}, .{}, .task);
        try self.addRelationTypeWithMetadata("task_event", @intFromEnum(core.RelKind.task_event), &.{kernel_edge_type_id}, .{}, .task);

        // 跨模块引用关系(RelationClass .ref):任务闭合投影。src 限 task,dst 松(不约束——
        // 目标可以是 concept/observation/file/symbol 等多种,宁松不错拒;裸库 add-edge 本就不校验)。
        var task_src = NodeTypeSet.empty();
        try task_src.insert(@intFromEnum(core.NodeKind.task));
        try self.addRelationTypeWithMetadata("acts_on", @intFromEnum(core.RelKind.acts_on), &.{kernel_edge_type_id}, .{ .src = task_src }, .ref);
        try self.addRelationTypeWithMetadata("uses", @intFromEnum(core.RelKind.uses), &.{kernel_edge_type_id}, .{ .src = task_src }, .ref);
        try self.addRelationTypeWithMetadata("produces", @intFromEnum(core.RelKind.produces), &.{kernel_edge_type_id}, .{ .src = task_src }, .ref);
        try self.addRelationTypeWithMetadata("about", @intFromEnum(core.RelKind.about), &.{kernel_edge_type_id}, .{ .src = task_src }, .ref);
    }

    fn addMarkdownDocumentProfile(self: *Registry) !void {
        try self.addNodeType("document", @intFromEnum(core.NodeKind.document), &.{kernel_node_type_id});
        try self.addNodeType("document_section", @intFromEnum(core.NodeKind.document_section), &.{kernel_node_type_id});
        try self.addNodeType("image", @intFromEnum(core.NodeKind.image), &.{kernel_node_type_id});
        try self.addNodeType("media", @intFromEnum(core.NodeKind.media), &.{kernel_node_type_id});
        try self.addMarkdownDocumentRelationTypes();
    }

    fn addMarkdownDocumentRelationTypes(self: *Registry) !void {
        const document_src = try markdownProjectionDocumentSourceTypes();
        const image_dst = try NodeTypeSet.singleton(@intFromEnum(core.NodeKind.image));
        const occurrence_dst = try NodeTypeSet.singleton(@intFromEnum(core.NodeKind.document_section));
        const occurrence_src = try NodeTypeSet.singleton(@intFromEnum(core.NodeKind.document_section));
        const text_or_occurrence_dst = occurrence_dst;

        try self.addRelationTypeWithMetadata("contains", @intFromEnum(core.RelKind.contains), &.{kernel_edge_type_id}, .{ .src = document_src, .dst = occurrence_dst }, .sys);
        try self.setRelationProperty(@intFromEnum(core.RelKind.contains), .{ .name = "order_key", .value_type = .uint, .required = false, .nullable = true, .indexed = true });
        try self.setRelationComposition(@intFromEnum(core.RelKind.contains), .{ .enabled = true, .owner = true, .cardinality = .many, .ordered_by = "order_key" });
        try self.addRelationTypeWithMetadata("precedes", @intFromEnum(core.RelKind.precedes), &.{kernel_edge_type_id}, .{ .src = occurrence_src, .dst = occurrence_dst }, .sys);

        try self.addRelationTypeWithMetadata("md:h1", md_rel_h1_id, &.{kernel_edge_type_id}, .{ .src = document_src, .dst = text_or_occurrence_dst }, .md);
        try self.addRelationTypeWithMetadata("md:h2", md_rel_h2_id, &.{kernel_edge_type_id}, .{ .src = document_src, .dst = text_or_occurrence_dst }, .md);
        try self.addRelationTypeWithMetadata("md:h3", md_rel_h3_id, &.{kernel_edge_type_id}, .{ .src = document_src, .dst = text_or_occurrence_dst }, .md);
        try self.addRelationTypeWithMetadata("md:h4", md_rel_h4_id, &.{kernel_edge_type_id}, .{ .src = document_src, .dst = text_or_occurrence_dst }, .md);
        try self.addRelationTypeWithMetadata("md:h5", md_rel_h5_id, &.{kernel_edge_type_id}, .{ .src = document_src, .dst = text_or_occurrence_dst }, .md);
        try self.addRelationTypeWithMetadata("md:h6", md_rel_h6_id, &.{kernel_edge_type_id}, .{ .src = document_src, .dst = text_or_occurrence_dst }, .md);
        try self.addRelationTypeWithMetadata("md:paragraph", md_rel_paragraph_id, &.{kernel_edge_type_id}, .{ .src = document_src, .dst = text_or_occurrence_dst }, .md);
        try self.addRelationTypeWithMetadata("md:code_block", md_rel_code_block_id, &.{kernel_edge_type_id}, .{ .src = document_src, .dst = text_or_occurrence_dst }, .md);
        try self.addRelationTypeWithMetadata("md:image", md_rel_image_id, &.{kernel_edge_type_id}, .{ .src = document_src, .dst = image_dst }, .md);
        try self.addRelationTypeWithMetadata("md:list", md_rel_list_id, &.{kernel_edge_type_id}, .{ .src = document_src, .dst = text_or_occurrence_dst }, .md);
        try self.addRelationTypeWithMetadata("md:blockquote", md_rel_blockquote_id, &.{kernel_edge_type_id}, .{ .src = document_src, .dst = text_or_occurrence_dst }, .md);
        try self.addRelationTypeWithMetadata("md:html_block", md_rel_html_block_id, &.{kernel_edge_type_id}, .{ .src = document_src, .dst = text_or_occurrence_dst }, .md);
        try self.addRelationTypeWithMetadata("md:footnote_def", md_rel_footnote_def_id, &.{kernel_edge_type_id}, .{ .src = document_src, .dst = text_or_occurrence_dst }, .md);
        try self.addRelationTypeWithMetadata("md:link_reference", md_rel_link_reference_id, &.{kernel_edge_type_id}, .{ .src = document_src, .dst = text_or_occurrence_dst }, .md);
        try self.addRelationTypeWithMetadata("md:thematic_break", md_rel_thematic_break_id, &.{kernel_edge_type_id}, .{ .src = document_src, .dst = text_or_occurrence_dst }, .md);
        try self.addRelationTypeWithMetadata("md:raw_block", md_rel_raw_block_id, &.{kernel_edge_type_id}, .{ .src = document_src, .dst = text_or_occurrence_dst }, .md);
        try self.addRelationTypeWithMetadata("md:table", md_rel_table_id, &.{kernel_edge_type_id}, .{ .src = document_src, .dst = occurrence_dst }, .md);
        try self.addRelationTypeWithMetadata("md:table_row", md_rel_table_row_id, &.{kernel_edge_type_id}, .{ .src = occurrence_src, .dst = occurrence_dst }, .md);
        try self.addRelationTypeWithMetadata("md:table_cell", md_rel_table_cell_id, &.{kernel_edge_type_id}, .{ .src = occurrence_src, .dst = text_or_occurrence_dst }, .md);
        try self.addRelationTypeWithMetadata("md:text_chunk", md_rel_text_chunk_id, &.{kernel_edge_type_id}, .{ .src = occurrence_src, .dst = text_or_occurrence_dst }, .md);
    }

    fn addType(self: *Registry, types: *std.ArrayList(TypeDef), comptime max_types: u16, name: []const u8, id: u16, parents: []const u16, endpoint_rule: RelationEndpointRule, relation_class: RelationClass) !void {
        if (id >= max_types) return Error.TypeIdOutOfRange;
        if (parents.len > max_direct_parents) return Error.TooManyParents;
        if (findType(types.items, name) != null) return Error.DuplicateTypeName;
        for (types.items) |type_def| {
            if (type_def.id == id) return Error.DuplicateTypeId;
        }
        var parent_storage = [_]u16{0} ** max_direct_parents;
        for (parents, 0..) |parent_id, i| {
            if (findTypeById(types.items, parent_id) == null) return Error.UnknownParentType;
            parent_storage[i] = parent_id;
            if (try inheritanceDepth(types.items, parent_id) + 1 > max_inheritance_depth) return Error.InheritanceTooDeep;
        }
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try types.append(self.allocator, .{
            .id = id,
            .name = owned_name,
            .parents = parent_storage,
            .parent_count = @intCast(parents.len),
            .endpoint_rule = endpoint_rule,
            .relation_class = relation_class,
        });
    }

    fn addDefaultNodeProperties(self: *Registry, id: u16) !void {
        try self.setNodeProperty(id, .{
            .name = "name",
            .value_type = .string,
            .required = false,
            .nullable = true,
            .agent_fillable = true,
            .human_fillable = true,
            .indexed = true,
            .searchable = false,
            .returned_by_default = true,
        });
        try self.setNodeProperty(id, .{
            .name = "summary",
            .value_type = .string,
            .required = false,
            .nullable = true,
            .agent_fillable = true,
            .human_fillable = true,
            .indexed = true,
            .searchable = true,
            .returned_by_default = true,
        });
        try self.setNodeProperty(id, .{
            .name = "text",
            .value_type = .string,
            .required = true,
            .nullable = false,
            .agent_fillable = false,
            .human_fillable = false,
            .indexed = false,
            .searchable = true,
            .returned_by_default = false,
        });
    }

    fn inheritCompiledProperties(self: *Registry, types: *std.ArrayList(TypeDef), lookup: *std.StringHashMap(PropertyMeta), comptime prefix: []const u8, id: u16) !void {
        const type_def = findTypePtrById(types.items, id) orelse return Error.UnknownParentType;
        for (type_def.parents[0..type_def.parent_count]) |parent_id| {
            try self.inheritCompiledPropertiesFrom(lookup, prefix, types, parent_id, id);
        }
    }

    fn inheritCompiledPropertiesFrom(self: *Registry, lookup: *std.StringHashMap(PropertyMeta), comptime prefix: []const u8, types: *std.ArrayList(TypeDef), parent_id: u16, child_id: u16) !void {
        const parent = findTypeById(types.items, parent_id) orelse return Error.UnknownParentType;
        for (parent.parents[0..parent.parent_count]) |grandparent_id| {
            try self.inheritCompiledPropertiesFrom(lookup, prefix, types, grandparent_id, child_id);
        }
        for (parent.properties.items) |property| {
            try self.setTypeProperty(types, lookup, prefix, child_id, property);
        }
    }

    fn setTypeProperty(self: *Registry, types: *std.ArrayList(TypeDef), lookup: *std.StringHashMap(PropertyMeta), comptime prefix: []const u8, id: u16, property: PropertyMeta) !void {
        try validatePropertyName(property.name);
        try validatePropertyEnumValues(property);
        const type_def = findTypePtrById(types.items, id) orelse return Error.UnknownParentType;
        for (type_def.properties.items) |*existing| {
            if (!std.ascii.eqlIgnoreCase(existing.name, property.name)) continue;
            var canonical_property = property;
            canonical_property.name = existing.name;
            const owned = try clonePropertyMeta(self.allocator, canonical_property);
            errdefer deinitPropertyMeta(self.allocator, owned);
            const old = existing.*;
            existing.* = owned;
            self.putCompiledProperty(lookup, prefix, id, existing.*) catch |err| {
                existing.* = old;
                return err;
            };
            deinitPropertyMeta(self.allocator, old);
            return;
        }
        const owned = try clonePropertyMeta(self.allocator, property);
        errdefer deinitPropertyMeta(self.allocator, owned);
        try type_def.properties.append(self.allocator, owned);
        self.putCompiledProperty(lookup, prefix, id, owned) catch |err| {
            _ = type_def.properties.pop();
            return err;
        };
    }

    fn putCompiledProperty(self: *Registry, lookup: *std.StringHashMap(PropertyMeta), comptime prefix: []const u8, type_id: u16, property: PropertyMeta) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{}:{s}", .{ prefix, type_id, property.name });
        errdefer self.allocator.free(key);
        const entry = try lookup.getOrPut(key);
        if (entry.found_existing) {
            self.allocator.free(key);
        }
        entry.value_ptr.* = property;
    }

    fn propertyByTypeId(self: Registry, lookup: std.StringHashMap(PropertyMeta), comptime prefix: []const u8, type_id: u16, name: []const u8) ?PropertyMeta {
        _ = self;
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{}:{s}", .{ prefix, type_id, name }) catch return null;
        return lookup.get(key);
    }
};

const max_property_name_bytes = 128;

fn validatePropertyName(name: []const u8) !void {
    if (name.len == 0 or name.len > max_property_name_bytes) return Error.InvalidPropertyName;
}

fn validatePropertyEnumValues(property: PropertyMeta) !void {
    if (property.value_type != .@"enum") {
        if (property.enum_values.len != 0) return Error.InvalidEnumValues;
        return;
    }
    if (property.enum_values.len > max_enum_values) return Error.InvalidEnumValues;
    for (property.enum_values, 0..) |value, index| {
        if (value.len == 0 or value.len > max_enum_value_bytes) return Error.InvalidEnumValues;
        for (property.enum_values[0..index]) |previous| {
            if (std.mem.eql(u8, previous, value)) return Error.InvalidEnumValues;
        }
    }
}

fn clonePropertyMeta(allocator: std.mem.Allocator, property: PropertyMeta) !PropertyMeta {
    var owned = property;
    owned.name = try allocator.dupe(u8, property.name);
    errdefer allocator.free(owned.name);
    if (property.enum_values.len == 0) {
        owned.enum_values = &.{};
        return owned;
    }
    const values = try allocator.alloc([]const u8, property.enum_values.len);
    errdefer allocator.free(values);
    var cloned: usize = 0;
    errdefer for (values[0..cloned]) |value| allocator.free(value);
    for (property.enum_values, 0..) |value, index| {
        values[index] = try allocator.dupe(u8, value);
        cloned += 1;
    }
    owned.enum_values = values;
    return owned;
}

fn deinitPropertyMeta(allocator: std.mem.Allocator, property: PropertyMeta) void {
    allocator.free(property.name);
    if (property.enum_values.len == 0) return;
    for (property.enum_values) |value| allocator.free(value);
    allocator.free(property.enum_values);
}

fn typeInfo(type_def: *const TypeDef) TypeInfo {
    return .{
        .id = type_def.id,
        .name = type_def.name,
        .parents = type_def.parents[0..type_def.parent_count],
    };
}

fn relationInfoFromTypeDef(type_def: *const TypeDef) RelationTypeInfo {
    return .{
        .id = type_def.id,
        .name = type_def.name,
        .parents = type_def.parents[0..type_def.parent_count],
        .class = type_def.relation_class,
    };
}

fn markdownProjectionDocumentSourceTypes() !NodeTypeSet {
    var out = NodeTypeSet.empty();
    try out.insert(@intFromEnum(core.NodeKind.document));
    try out.insert(@intFromEnum(core.NodeKind.document_section));
    return out;
}

pub fn markdownProjectionRelationNameById(id: u16) ?[]const u8 {
    return switch (id) {
        md_rel_h1_id => "md:h1",
        md_rel_h2_id => "md:h2",
        md_rel_h3_id => "md:h3",
        md_rel_h4_id => "md:h4",
        md_rel_h5_id => "md:h5",
        md_rel_h6_id => "md:h6",
        md_rel_paragraph_id => "md:paragraph",
        md_rel_code_block_id => "md:code_block",
        md_rel_image_id => "md:image",
        md_rel_list_id => "md:list",
        md_rel_blockquote_id => "md:blockquote",
        md_rel_html_block_id => "md:html_block",
        md_rel_footnote_def_id => "md:footnote_def",
        md_rel_link_reference_id => "md:link_reference",
        md_rel_thematic_break_id => "md:thematic_break",
        md_rel_raw_block_id => "md:raw_block",
        md_rel_table_id => "md:table",
        md_rel_table_row_id => "md:table_row",
        md_rel_table_cell_id => "md:table_cell",
        md_rel_text_chunk_id => "md:text_chunk",
        else => null,
    };
}

pub fn markdownProjectionRelationIdByName(name: []const u8) ?u16 {
    inline for (.{
        .{ "md:h1", md_rel_h1_id },
        .{ "md:h2", md_rel_h2_id },
        .{ "md:h3", md_rel_h3_id },
        .{ "md:h4", md_rel_h4_id },
        .{ "md:h5", md_rel_h5_id },
        .{ "md:h6", md_rel_h6_id },
        .{ "md:paragraph", md_rel_paragraph_id },
        .{ "md:code_block", md_rel_code_block_id },
        .{ "md:image", md_rel_image_id },
        .{ "md:list", md_rel_list_id },
        .{ "md:blockquote", md_rel_blockquote_id },
        .{ "md:html_block", md_rel_html_block_id },
        .{ "md:footnote_def", md_rel_footnote_def_id },
        .{ "md:link_reference", md_rel_link_reference_id },
        .{ "md:thematic_break", md_rel_thematic_break_id },
        .{ "md:raw_block", md_rel_raw_block_id },
        .{ "md:table", md_rel_table_id },
        .{ "md:table_row", md_rel_table_row_id },
        .{ "md:table_cell", md_rel_table_cell_id },
        .{ "md:text_chunk", md_rel_text_chunk_id },
    }) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry.@"0")) return entry.@"1";
    }
    return null;
}

fn defaultRelationClass(rel: core.RelKind) RelationClass {
    return switch (rel) {
        .contains,
        .precedes,
        .modified,
        .resolved_by,
        .related_to,
        .deprecated_by,
        .merged_into,
        => .sys,
        .depends_on,
        .blocks,
        .task_event,
        => .task,
        .based_on,
        .evidences,
        .verified_by,
        .derived_from,
        .references,
        => .prov,
        .acts_on,
        .uses,
        .produces,
        .about,
        => .ref,
        else => .domain,
    };
}

fn findType(types: []const TypeDef, name: []const u8) ?u16 {
    for (types) |type_def| {
        if (std.ascii.eqlIgnoreCase(type_def.name, name)) return type_def.id;
    }
    return null;
}

fn findTypeById(types: []const TypeDef, id: u16) ?TypeDef {
    for (types) |type_def| {
        if (type_def.id == id) return type_def;
    }
    return null;
}

fn findTypePtrById(types: []TypeDef, id: u16) ?*TypeDef {
    for (types) |*type_def| {
        if (type_def.id == id) return type_def;
    }
    return null;
}

fn inheritanceDepth(types: []const TypeDef, id: u16) !u8 {
    const type_def = findTypeById(types, id) orelse return Error.UnknownParentType;
    var max_depth: u8 = 1;
    for (type_def.parents[0..type_def.parent_count]) |parent_id| {
        max_depth = @max(max_depth, try inheritanceDepth(types, parent_id) + 1);
    }
    return max_depth;
}

fn descendantSet(comptime Set: type, types: []const TypeDef, comptime max_types: u16, id: u16) !Set {
    if (id >= max_types) return Error.TypeIdOutOfRange;
    if (findTypeById(types, id) == null) return Error.UnknownParentType;
    var out = Set.empty();
    try out.insert(id);
    var changed = true;
    while (changed) {
        changed = false;
        for (types) |type_def| {
            if (out.containsId(type_def.id)) continue;
            for (type_def.parents[0..type_def.parent_count]) |parent_id| {
                if (!out.containsId(parent_id)) continue;
                try out.insert(type_def.id);
                changed = true;
                break;
            }
        }
    }
    return out;
}

test "schema node descendants include child and grandchild types" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.addNodeType("Human", 100, &.{});
    try registry.addNodeType("Man", 101, &.{100});
    try registry.addNodeType("Woman", 102, &.{100});
    try registry.addNodeType("Engineer", 103, &.{101});

    const descendants = try registry.nodeDescendants(100);
    try std.testing.expect(descendants.containsId(100));
    try std.testing.expect(descendants.containsId(101));
    try std.testing.expect(descendants.containsId(102));
    try std.testing.expect(descendants.containsId(103));
    try std.testing.expectEqual(@as(u16, 4), descendants.count());
}

test "schema inherited properties are visible in child property tables" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.addNodeType("AgentDoc", 100, &.{});
    try registry.setNodeProperty(100, .{
        .name = "review_state",
        .value_type = .string,
        .human_fillable = true,
        .returned_by_default = true,
    });
    try registry.addNodeType("AgentSection", 101, &.{100});

    try std.testing.expect(registry.nodePropertyByTypeId(101, "review_state") != null);
    var found = false;
    var index: usize = 0;
    while (index < registry.nodePropertyCount(101)) : (index += 1) {
        const property = registry.nodePropertyInfo(101, index).?;
        if (std.mem.eql(u8, property.name, "review_state")) {
            found = true;
            try std.testing.expect(property.human_fillable);
        }
    }
    try std.testing.expect(found);
}

test "schema relation descendants keep parent relation queries compact" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.addRelationType("InteractsWith", 400, &.{});
    try registry.addRelationType("Mentions", 401, &.{400});
    try registry.addRelationType("Blocks", 402, &.{400});

    const descendants = try registry.relationDescendants(400);
    try std.testing.expect(descendants.containsRelKind(@enumFromInt(401)));
    try std.testing.expect(descendants.containsRelKind(@enumFromInt(402)));
    try std.testing.expectEqual(@as(u16, 3), descendants.count());
}

test "schema relation types support high ids while keeping descendant cap bounded" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.addRelationType("MarkdownProjection", 3000, &.{});
    try registry.addRelationType("MarkdownHeading", 3001, &.{3000});

    const descendants = try registry.relationDescendants(3000);
    try std.testing.expect(descendants.containsRelKind(@enumFromInt(@as(u16, 3001))));
    try std.testing.expectEqual(@as(u16, 2), descendants.count());
}

test "schema relation endpoint rules use node descendant sets" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.addNodeType("Memory", 10, &.{});
    try registry.addNodeType("Decision", 11, &.{10});
    try registry.addNodeType("Evidence", 12, &.{});

    var src = NodeTypeSet.empty();
    src.merge(try registry.nodeDescendants(10));
    var dst = NodeTypeSet.empty();
    dst.merge(try registry.nodeDescendants(12));
    try registry.addRelationTypeWithEndpointRule("SupportedBy", 20, &.{}, .{ .src = src, .dst = dst });

    const rule = registry.relationEndpointRuleById(20).?;
    try std.testing.expect(rule.src.?.containsId(10));
    try std.testing.expect(rule.src.?.containsId(11));
    try std.testing.expect(!rule.src.?.containsId(12));
    try std.testing.expect(rule.dst.?.containsId(12));
}

test "schema can attach endpoint rules to existing relation types" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.addDefaultTypes();
    try registry.addBuiltinProfile(.agent_dag);
    var src = NodeTypeSet.empty();
    try src.insert(@intFromEnum(core.NodeKind.decision));
    var dst = NodeTypeSet.empty();
    try dst.insert(@intFromEnum(core.NodeKind.evidence));
    try registry.setRelationEndpointRule(@intFromEnum(core.RelKind.based_on), .{ .src = src, .dst = dst });

    const rule = registry.relationEndpointRuleById(@intFromEnum(core.RelKind.based_on)).?;
    try std.testing.expect(rule.src.?.containsNodeKind(.decision));
    try std.testing.expect(!rule.src.?.containsNodeKind(.evidence));
    try std.testing.expect(rule.dst.?.containsNodeKind(.evidence));
}

test "schema kernel is clean and builtin profiles are explicit" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.addDefaultTypes();
    try std.testing.expect(registry.findNodeType("node") != null);
    try std.testing.expect(registry.findRelationType("edge") != null);
    try std.testing.expect(registry.findNodeType("file") == null);
    try std.testing.expect(registry.findNodeType("concept") == null);
    try std.testing.expect(registry.findRelationType("defines") == null);
    try std.testing.expect(registry.findRelationType("calls") == null);

    try registry.addBuiltinProfile(.agent_dag);
    try std.testing.expectEqual(RelationClass.prov, registry.relationClassById(@intFromEnum(core.RelKind.based_on)).?);
    try std.testing.expectEqual(RelationClass.task, registry.relationClassById(@intFromEnum(core.RelKind.depends_on)).?);
    try std.testing.expect(registry.findNodeType("task") != null);
    try std.testing.expect(registry.findNodeType("user_preference") == null);
    try std.testing.expect(registry.findRelationType("governs") == null);
    // 跨模块引用关系(.ref):acts_on/uses/produces/about 注册 + 归 .ref 类。
    try std.testing.expect(registry.findRelationType("acts_on") != null);
    try std.testing.expect(registry.findRelationType("uses") != null);
    try std.testing.expect(registry.findRelationType("produces") != null);
    try std.testing.expect(registry.findRelationType("about") != null);
    try std.testing.expectEqual(RelationClass.ref, registry.relationClassById(@intFromEnum(core.RelKind.acts_on)).?);
    try std.testing.expectEqual(RelationClass.ref, registry.relationClassById(@intFromEnum(core.RelKind.produces)).?);
    // concept 现在随 agent-dag 注册(ref 边的 dst 目标类型)。
    try std.testing.expect(registry.findNodeType("concept") != null);
    // acts_on endpoint:src 限 task(dst 松 = null 不约束)。
    const acts_on_rule = registry.relationEndpointRuleById(@intFromEnum(core.RelKind.acts_on)).?;
    try std.testing.expect(acts_on_rule.src != null);
    try std.testing.expect(acts_on_rule.src.?.containsNodeKind(.task));
    try std.testing.expect(acts_on_rule.dst == null);

    try registry.addBuiltinProfile(.markdown_document);
    try std.testing.expectEqual(RelationClass.sys, registry.relationClassById(@intFromEnum(core.RelKind.contains)).?);
    try std.testing.expect(registry.findNodeType("document") != null);
    try std.testing.expect(registry.findNodeType("repo") == null);
    try std.testing.expect(registry.findRelationType("imports") == null);
    try registry.addRelationTypeWithMetadata("md:custom", 3500, &.{}, .{}, .md);
    const info = registry.relationTypeInfo(registry.relationTypeCount() - 1).?;
    try std.testing.expectEqual(@as(u16, 3500), info.id);
    try std.testing.expectEqual(RelationClass.md, info.class);
}

test "agent dag task schema exposes lifecycle properties without changing kind" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.addDefaultTypes();
    try registry.addBuiltinProfile(.agent_dag);

    const task_type = @intFromEnum(core.NodeKind.task);
    const status = registry.nodePropertyByTypeId(task_type, "status").?;
    try std.testing.expectEqual(PropertyType.@"enum", status.value_type);
    try std.testing.expect(status.indexed);
    try std.testing.expect(status.returned_by_default);
    try std.testing.expect(status.required);
    try std.testing.expectEqual(task_status_enum_values.len, status.enum_values.len);
    for (&task_status_enum_values, status.enum_values) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    try std.testing.expect(status.enumAllows("open"));
    try std.testing.expect(status.enumAllows("failed"));
    try std.testing.expect(!status.enumAllows("done-ish"));
    try std.testing.expectEqual(PropertyType.string, registry.nodePropertyByTypeId(task_type, "claimed_by").?.value_type);
    try std.testing.expectEqual(PropertyType.uint, registry.nodePropertyByTypeId(task_type, "claim_expires_ns").?.value_type);
    try std.testing.expectEqual(PropertyType.uint, registry.nodePropertyByTypeId(task_type, "task_completed_ns").?.value_type);
}

test "schema enum domains are owned inherited and validated" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.addNodeType("Workflow", 100, &.{});
    try registry.setNodeProperty(100, .{
        .name = "state",
        .value_type = .@"enum",
        .enum_values = &.{ "draft", "published" },
    });
    try registry.addNodeType("Article", 101, &.{100});

    const inherited = registry.nodePropertyByTypeId(101, "state").?;
    try std.testing.expect(inherited.enumAllows("draft"));
    try std.testing.expect(!inherited.enumAllows("deleted"));
    try std.testing.expectError(Error.InvalidEnumValues, registry.setNodeProperty(100, .{
        .name = "bad",
        .value_type = .string,
        .enum_values = &.{"unexpected"},
    }));
    try std.testing.expectError(Error.InvalidEnumValues, registry.setNodeProperty(100, .{
        .name = "duplicate",
        .value_type = .@"enum",
        .enum_values = &.{ "same", "same" },
    }));
}

test "case-insensitive property replacement preserves canonical lookup ownership" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.addNodeType("Workflow", 100, &.{});
    try registry.setNodeProperty(100, .{
        .name = "State",
        .value_type = .@"enum",
        .enum_values = &.{"draft"},
    });
    const property_count = registry.nodePropertyCount(100);
    try registry.setNodeProperty(100, .{
        .name = "state",
        .value_type = .@"enum",
        .enum_values = &.{"published"},
    });

    try std.testing.expectEqual(property_count, registry.nodePropertyCount(100));
    const state = registry.nodePropertyByTypeId(100, "State").?;
    try std.testing.expectEqualStrings("State", state.name);
    try std.testing.expect(state.enumAllows("published"));
    try std.testing.expect(!state.enumAllows("draft"));
    try std.testing.expect(registry.nodePropertyByTypeId(100, "state") == null);
}

test "schema filters preserve single-type fast path and support descendant sets" {
    const single_node = NodeTypeFilter.fromOptionalKind(.task);
    try std.testing.expect(single_node.matches(.task));
    try std.testing.expect(!single_node.matches(.file));
    try std.testing.expectEqual(core.NodeKind.task, single_node.asSingle().?);

    var node_set = NodeTypeSet.empty();
    try node_set.insert(@intFromEnum(core.NodeKind.observation));
    try node_set.insert(@intFromEnum(core.NodeKind.error_event));
    const node_filter = NodeTypeFilter.fromDescendants(node_set);
    try std.testing.expect(node_filter.matches(.observation));
    try std.testing.expect(node_filter.matches(.error_event));
    try std.testing.expect(!node_filter.matches(.task));
    try std.testing.expect(node_filter.asSingle() == null);

    var rel_set = RelationTypeSet.empty();
    try rel_set.insert(@intFromEnum(core.RelKind.depends_on));
    try rel_set.insert(@intFromEnum(core.RelKind.blocks));
    const rel_filter = RelationTypeFilter.fromDescendants(rel_set);
    try std.testing.expect(rel_filter.matches(.depends_on));
    try std.testing.expect(rel_filter.matches(.blocks));
    try std.testing.expect(!rel_filter.matches(.mentions));
}

test "schema type info exposes stable parent ids" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.addNodeType("Human", 100, &.{});
    try registry.addNodeType("Man", 101, &.{100});
    const node_info = registry.nodeTypeInfo(1).?;
    try std.testing.expectEqual(@as(u16, 101), node_info.id);
    try std.testing.expectEqual(@as(usize, 1), node_info.parents.len);
    try std.testing.expectEqual(@as(u16, 100), node_info.parents[0]);

    try registry.addRelationType("InteractsWith", 40, &.{});
    try registry.addRelationType("Knows", 41, &.{40});
    const rel_info = registry.relationTypeInfo(1).?;
    try std.testing.expectEqual(@as(u16, 41), rel_info.id);
    try std.testing.expectEqual(@as(usize, 1), rel_info.parents.len);
    try std.testing.expectEqual(@as(u16, 40), rel_info.parents[0]);
}

test "schema resolves TinyQL-style labels into descendant filters" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.addDefaultTypes();
    try registry.addNodeType("Human", 100, &.{});
    try registry.addNodeType("Man", 101, &.{100});
    try registry.addNodeType("Woman", 102, &.{100});
    try registry.addRelationType("InteractsWith", 80, &.{});
    try registry.addRelationType("Knows", 81, &.{80});

    const human_filter = try registry.resolveNodeFilter("Human");
    try std.testing.expect(human_filter.matches(@enumFromInt(100)));
    try std.testing.expect(human_filter.matches(@enumFromInt(101)));
    try std.testing.expect(human_filter.matches(@enumFromInt(102)));
    try std.testing.expect(!human_filter.matches(.task));

    const interaction_filter = try registry.resolveRelationFilter("InteractsWith");
    try std.testing.expect(interaction_filter.matches(@enumFromInt(80)));
    try std.testing.expect(interaction_filter.matches(@enumFromInt(81)));
    try std.testing.expect(!interaction_filter.matches(.depends_on));
}

test "schema rejects overly broad relation descendant fast sets" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.addRelationType("AnyAction", 1, &.{});
    var id: u16 = 2;
    while (id < 2 + relation_descendant_fast_cap + 1) : (id += 1) {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "Action{}", .{id});
        try registry.addRelationType(name, id, &.{1});
    }
    try std.testing.expectError(Error.DescendantSetTooBroad, registry.relationDescendants(1));
}
