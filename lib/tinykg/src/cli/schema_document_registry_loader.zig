const std = @import("std");
const schema = @import("../schema.zig");

/// Owns the bounded, strict external schema document format and its complete
/// conversion into an owned Registry. Command orchestration, Store catalog
/// mutation, reconciliation, and migration remain outside this owner.
pub fn SchemaDocumentRegistryLoader() type {
    return struct {
        const Self = @This();
        const schema_file_max_bytes: u64 = 1024 * 1024;

        pub const SchemaFileJson = struct {
            schema_version: ?u8 = null,
            profiles: ?[]const []const u8 = null,
            profile_contracts: ?SchemaProfileContractsJson = null,
            node_types: ?[]SchemaTypeJson = null,
            relation_types: ?[]SchemaTypeJson = null,
        };

        const SchemaProfileContractsJson = struct {
            agent_dag: ?u16 = null,
            markdown_document: ?u16 = null,
        };

        const SchemaTypeJson = struct {
            name: []const u8,
            id: u16,
            parents: ?[]const []const u8 = null,
            class: ?[]const u8 = null,
            relation_class: ?[]const u8 = null,
            src_types: ?[]const []const u8 = null,
            dst_types: ?[]const []const u8 = null,
            properties: ?std.json.Value = null,
            composition: ?SchemaCompositionJson = null,
        };

        const SchemaCompositionJson = struct {
            enabled: ?bool = null,
            owner: ?bool = null,
            cardinality: ?[]const u8 = null,
            ordered_by: ?[]const u8 = null,
        };

        const schema_property_metadata_fields = [_][]const u8{
            "type",
            "values",
            "required",
            "nullable",
            "agent_fillable",
            "human_fillable",
            "indexed",
            "searchable",
            "returned_by_default",
        };

        pub fn parseSchemaFileDocument(
            allocator: std.mem.Allocator,
            io: std.Io,
            path: []const u8,
        ) !std.json.Parsed(SchemaFileJson) {
            const bytes = try readSchemaFileBytesAlloc(allocator, io, path);
            defer allocator.free(bytes);
            return parseSchemaFileBytes(allocator, bytes);
        }

        pub fn readSchemaFileBytesAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
            var file = try std.Io.Dir.cwd().openFile(io, path, .{});
            defer file.close(io);
            const stat = try file.stat(io);
            if (stat.kind != .file or stat.size == 0 or stat.size > schema_file_max_bytes) return error.InvalidRecord;
            const size: usize = @intCast(stat.size);
            const bytes = try allocator.alloc(u8, size);
            errdefer allocator.free(bytes);
            const read = try file.readPositionalAll(io, bytes, 0);
            if (read != bytes.len) return error.InvalidRecord;
            return bytes;
        }

        pub fn parseSchemaFileBytes(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(SchemaFileJson) {
            return try std.json.parseFromSlice(SchemaFileJson, allocator, bytes, .{
                .ignore_unknown_fields = false,
                .allocate = .alloc_always,
            });
        }

        pub fn loadSchemaRegistryFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !schema.Registry {
            var parsed = try parseSchemaFileDocument(allocator, io, path);
            defer parsed.deinit();
            return loadSchemaRegistryDocument(allocator, parsed.value);
        }

        pub fn loadSchemaRegistryBytes(allocator: std.mem.Allocator, bytes: []const u8) !schema.Registry {
            var parsed = try parseSchemaFileBytes(allocator, bytes);
            defer parsed.deinit();
            return loadSchemaRegistryDocument(allocator, parsed.value);
        }

        pub fn loadSchemaRegistryDocument(allocator: std.mem.Allocator, document: SchemaFileJson) !schema.Registry {
            var registry = schema.Registry.init(allocator);
            errdefer registry.deinit();
            try registry.addKernelTypes();
            const schema_version = document.schema_version orelse 1;
            if (schema_version != 1 and schema_version != 2 and schema_version != 3) return error.InvalidRecord;
            if (document.profiles) |profiles| {
                for (profiles) |profile_label| {
                    const profile = schema.BuiltinProfile.fromLabel(profile_label) orelse return error.InvalidRecord;
                    const contract_version = schemaProfileContractVersionFromJson(profile, document.profile_contracts);
                    try registry.addBuiltinProfileForSchemaVersionAndContractVersion(profile, schema_version, contract_version);
                }
            }

            if (document.node_types) |types| {
                for (types) |type_def| {
                    var parents = std.ArrayList(u16).empty;
                    defer parents.deinit(allocator);
                    if (type_def.parents) |parent_names| {
                        try parents.ensureTotalCapacity(allocator, parent_names.len);
                        for (parent_names) |parent_name| {
                            const parent_id = registry.findNodeType(parent_name) orelse return error.UnknownNodeKind;
                            parents.appendAssumeCapacity(parent_id);
                        }
                    }
                    if (registry.findNodeType(type_def.name)) |existing_id| {
                        if (existing_id != type_def.id or parents.items.len != 0) return error.DuplicateTypeName;
                        try applySchemaNodePropertiesFromJson(&registry, existing_id, type_def.properties);
                        continue;
                    }
                    try registry.addNodeType(type_def.name, type_def.id, parents.items);
                    try applySchemaNodePropertiesFromJson(&registry, type_def.id, type_def.properties);
                }
            }
            if (document.relation_types) |types| {
                for (types) |type_def| {
                    var parents = std.ArrayList(u16).empty;
                    defer parents.deinit(allocator);
                    if (type_def.parents) |parent_names| {
                        try parents.ensureTotalCapacity(allocator, parent_names.len);
                        for (parent_names) |parent_name| {
                            const parent_id = registry.findRelationType(parent_name) orelse return error.UnknownRelationKind;
                            parents.appendAssumeCapacity(parent_id);
                        }
                    }
                    const endpoint_rule = try schemaEndpointRuleFromJson(registry, type_def);
                    const relation_class = try schemaRelationClassFromJson(type_def);
                    if (registry.findRelationType(type_def.name)) |existing_id| {
                        if (existing_id != type_def.id or parents.items.len != 0) return error.DuplicateTypeName;
                        try registry.setRelationEndpointRule(existing_id, endpoint_rule);
                        if (schemaRelationClassLabelFromJson(type_def) != null) try registry.setRelationClass(existing_id, relation_class);
                        try applySchemaRelationPropertiesFromJson(&registry, existing_id, type_def.properties);
                        try applySchemaRelationCompositionFromJson(&registry, existing_id, type_def.composition);
                        continue;
                    }
                    try registry.addRelationTypeWithMetadata(type_def.name, type_def.id, parents.items, endpoint_rule, relation_class);
                    try applySchemaRelationPropertiesFromJson(&registry, type_def.id, type_def.properties);
                    try applySchemaRelationCompositionFromJson(&registry, type_def.id, type_def.composition);
                }
            }
            return registry;
        }

        pub fn addBuiltinProfilesFromCsv(registry: *schema.Registry, raw_profiles: []const u8) !void {
            return addBuiltinProfilesFromCsvForSchemaVersion(registry, raw_profiles, 3);
        }

        pub fn addBuiltinProfilesFromCsvForSchemaVersion(registry: *schema.Registry, raw_profiles: []const u8, schema_version: u32) !void {
            var it = std.mem.splitScalar(u8, raw_profiles, ',');
            var count: usize = 0;
            while (it.next()) |raw_profile| {
                const profile = std.mem.trim(u8, raw_profile, " \t\r\n");
                if (profile.len == 0) continue;
                try addBuiltinProfileFromLabelForSchemaVersion(registry, profile, schema_version);
                count += 1;
            }
            if (count == 0) return error.InvalidRecord;
        }

        pub fn addBuiltinProfileFromLabel(registry: *schema.Registry, raw_profile: []const u8) !void {
            return addBuiltinProfileFromLabelForSchemaVersion(registry, raw_profile, 3);
        }

        pub fn addBuiltinProfileFromLabelForSchemaVersion(registry: *schema.Registry, raw_profile: []const u8, schema_version: u32) !void {
            const profile = schema.BuiltinProfile.fromLabel(raw_profile) orelse return error.InvalidRecord;
            try registry.addBuiltinProfileForSchemaVersion(profile, schema_version);
        }

        pub fn schemaRelationClassNamespace(name: []const u8) ?schema.RelationClass {
            if (std.mem.startsWith(u8, name, "md:")) return .md;
            if (std.mem.startsWith(u8, name, "markdown:")) return .md;
            if (std.mem.startsWith(u8, name, "prov:")) return .prov;
            if (std.mem.startsWith(u8, name, "provenance:")) return .prov;
            if (std.mem.startsWith(u8, name, "task:")) return .task;
            if (std.mem.startsWith(u8, name, "sys:")) return .sys;
            if (std.mem.startsWith(u8, name, "system:")) return .sys;
            if (std.mem.startsWith(u8, name, "domain:")) return .domain;
            return null;
        }

        fn schemaProfileContractVersionFromJson(profile: schema.BuiltinProfile, contracts: ?SchemaProfileContractsJson) u16 {
            const configured = contracts orelse return switch (profile) {
                .agent_dag => schema.agent_dag_profile_contract_version_legacy,
                .markdown_document => schema.markdown_document_profile_contract_version_legacy,
            };
            return switch (profile) {
                .agent_dag => configured.agent_dag orelse schema.agent_dag_profile_contract_version_legacy,
                .markdown_document => configured.markdown_document orelse schema.markdown_document_profile_contract_version_legacy,
            };
        }

        fn applySchemaNodePropertiesFromJson(registry: *schema.Registry, type_id: u16, properties: ?std.json.Value) !void {
            const value = properties orelse return;
            if (value != .object) return error.InvalidRecord;
            var it = value.object.iterator();
            while (it.next()) |entry| {
                const property = try schemaPropertyMetaFromJson(registry.allocator, entry.key_ptr.*, entry.value_ptr.*);
                defer if (property.enum_values.len != 0) registry.allocator.free(property.enum_values);
                try registry.setNodeProperty(type_id, property);
            }
        }

        fn applySchemaRelationPropertiesFromJson(registry: *schema.Registry, type_id: u16, properties: ?std.json.Value) !void {
            const value = properties orelse return;
            if (value != .object) return error.InvalidRecord;
            var it = value.object.iterator();
            while (it.next()) |entry| {
                const property = try schemaPropertyMetaFromJson(registry.allocator, entry.key_ptr.*, entry.value_ptr.*);
                defer if (property.enum_values.len != 0) registry.allocator.free(property.enum_values);
                try registry.setRelationProperty(type_id, property);
            }
        }

        fn schemaPropertyMetaFromJson(allocator: std.mem.Allocator, name: []const u8, value: std.json.Value) !schema.PropertyMeta {
            if (value != .object) return error.InvalidRecord;
            var fields = value.object.iterator();
            while (fields.next()) |entry| {
                if (!schemaPropertyMetadataFieldAllowed(entry.key_ptr.*)) return error.UnknownField;
            }
            const value_type = if (value.object.get("type")) |type_value| try schemaPropertyTypeFromJson(type_value) else .string;
            const enum_values = if (value.object.get("values")) |values_value|
                try schemaPropertyEnumValuesFromJson(allocator, values_value)
            else
                &.{};
            errdefer if (enum_values.len != 0) allocator.free(enum_values);
            if (value_type == .@"enum" and enum_values.len == 0) return error.InvalidRecord;
            if (value_type != .@"enum" and enum_values.len != 0) return error.InvalidRecord;
            return .{
                .name = name,
                .value_type = value_type,
                .enum_values = enum_values,
                .required = if (value.object.get("required")) |field| try schemaBoolFromJson(field) else false,
                .nullable = if (value.object.get("nullable")) |field| try schemaBoolFromJson(field) else true,
                .agent_fillable = if (value.object.get("agent_fillable")) |field| try schemaBoolFromJson(field) else false,
                .human_fillable = if (value.object.get("human_fillable")) |field| try schemaBoolFromJson(field) else false,
                .indexed = if (value.object.get("indexed")) |field| try schemaBoolFromJson(field) else false,
                .searchable = if (value.object.get("searchable")) |field| try schemaBoolFromJson(field) else false,
                .returned_by_default = if (value.object.get("returned_by_default")) |field| try schemaBoolFromJson(field) else false,
            };
        }

        fn schemaPropertyMetadataFieldAllowed(name: []const u8) bool {
            inline for (schema_property_metadata_fields) |field| {
                if (std.mem.eql(u8, name, field)) return true;
            }
            return false;
        }

        fn schemaPropertyEnumValuesFromJson(allocator: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
            if (value != .array or value.array.items.len == 0 or value.array.items.len > schema.max_enum_values) return error.InvalidRecord;
            const string_values = try allocator.alloc([]const u8, value.array.items.len);
            errdefer allocator.free(string_values);
            for (value.array.items, 0..) |item, index| {
                if (item != .string or item.string.len == 0 or item.string.len > schema.max_enum_value_bytes) return error.InvalidRecord;
                for (string_values[0..index]) |previous| {
                    if (std.mem.eql(u8, previous, item.string)) return error.InvalidRecord;
                }
                string_values[index] = item.string;
            }
            return string_values;
        }

        fn schemaPropertyTypeFromJson(value: std.json.Value) !schema.PropertyType {
            if (value != .string) return error.InvalidRecord;
            return schema.PropertyType.fromLabel(value.string) orelse return error.InvalidRecord;
        }

        fn schemaBoolFromJson(value: std.json.Value) !bool {
            if (value != .bool) return error.InvalidRecord;
            return value.bool;
        }

        fn applySchemaRelationCompositionFromJson(registry: *schema.Registry, type_id: u16, composition: ?SchemaCompositionJson) !void {
            const raw = composition orelse return;
            try registry.setRelationComposition(type_id, .{
                .enabled = raw.enabled orelse true,
                .owner = raw.owner orelse false,
                .cardinality = if (raw.cardinality) |label| schema.CompositionCardinality.fromLabel(label) orelse return error.InvalidRecord else .many,
                .ordered_by = raw.ordered_by,
            });
        }

        fn schemaEndpointRuleFromJson(registry: schema.Registry, type_def: SchemaTypeJson) !schema.RelationEndpointRule {
            return .{
                .src = if (type_def.src_types) |labels| try schemaNodeTypeSetFromLabels(registry, labels) else null,
                .dst = if (type_def.dst_types) |labels| try schemaNodeTypeSetFromLabels(registry, labels) else null,
            };
        }

        fn schemaRelationClassLabelFromJson(type_def: SchemaTypeJson) ?[]const u8 {
            return type_def.relation_class orelse type_def.class;
        }

        fn schemaRelationClassFromJson(type_def: SchemaTypeJson) !schema.RelationClass {
            if (schemaRelationClassLabelFromJson(type_def)) |label| {
                return schema.RelationClass.fromLabel(label) orelse return error.InvalidRecord;
            }
            return schemaRelationClassNamespace(type_def.name) orelse .domain;
        }

        fn schemaNodeTypeSetFromLabels(registry: schema.Registry, labels: []const []const u8) !schema.NodeTypeSet {
            if (labels.len == 0) return error.InvalidRecord;
            var out = schema.NodeTypeSet.empty();
            for (labels) |label| {
                const id = registry.findNodeType(label) orelse return error.UnknownNodeKind;
                out.merge(try registry.nodeDescendants(id));
            }
            return out;
        }
    };
}

const loader = SchemaDocumentRegistryLoader();

test "schema registry loader rejects unknown top-level fields" {
    try std.testing.expectError(error.UnknownField, loader.parseSchemaFileBytes(
        std.testing.allocator,
        "{\"schema_version\":3,\"surprise\":true}",
    ));
}

test "schema registry loader rejects unknown property metadata fields" {
    try std.testing.expectError(error.UnknownField, loader.loadSchemaRegistryBytes(
        std.testing.allocator,
        "{\"schema_version\":3,\"node_types\":[{\"name\":\"Workflow\",\"id\":100,\"parents\":[\"node\"],\"properties\":{\"state\":{\"type\":\"string\",\"surprise\":true}}}]}",
    ));
}

test "schema registry loader preserves explicit profile contract versions" {
    var registry = try loader.loadSchemaRegistryBytes(
        std.testing.allocator,
        "{\"schema_version\":3,\"profiles\":[\"agent-dag\"],\"profile_contracts\":{\"agent_dag\":2}}",
    );
    defer registry.deinit();
    const references_id = registry.findRelationType("references") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(
        try schema.sharedReferencesEndpointRule(),
        registry.relationEndpointRuleById(references_id).?,
    );
}

test "schema registry loader infers relation classes only from governed namespaces" {
    try std.testing.expectEqual(schema.RelationClass.md, loader.schemaRelationClassNamespace("md:h1").?);
    try std.testing.expectEqual(schema.RelationClass.prov, loader.schemaRelationClassNamespace("provenance:derived").?);
    try std.testing.expect(loader.schemaRelationClassNamespace("related_to") == null);
}
