const std = @import("std");
const catalog = @import("catalog.zig");
const schema = @import("schema.zig");

pub const max_plan_bytes: usize = 1024 * 1024;
pub const max_approved_changes: usize = 128;
pub const sha256_hex_len: usize = 64;

pub const Error = error{
    InvalidReconciliationPlan,
    UnapprovedCatalogChange,
    ReconciliationInputChanged,
};

pub const Inputs = struct {
    existing_catalog_sha256: []const u8,
    candidate_catalog_sha256: []const u8,
    candidate_schema_sha256: []const u8,
    schema_validation_sha256: []const u8,
};

pub const UnknownKind = struct {
    domain: []const u8,
    id: u16,
    count: u64,
};

pub const Validation = struct {
    result: []const u8,
    endpoint_violations: u64,
    unknown_kinds_in_data: u64,
    orphaned_types: u64,
    unknown_kinds: []const UnknownKind,
};

pub const ApprovedChange = struct {
    domain: []const u8,
    id: u16,
    name: []const u8,
    kind: []const u8,
};

pub const Summary = struct {
    changes: usize,
    by_kind: std.json.Value,
};

pub const Document = struct {
    schema_version: u32,
    contract_id: []const u8,
    status: []const u8,
    inputs: Inputs,
    existing_revision: u32,
    candidate_revision: u32,
    validation: Validation,
    approved_changes: []const ApprovedChange,
    summary: Summary,
};

pub const Plan = struct {
    parsed: std.json.Parsed(Document),
    digest: [32]u8,

    pub fn deinit(self: *Plan) void {
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn document(self: *const Plan) *const Document {
        return &self.parsed.value;
    }
};

const ChangeKind = enum {
    endpoint_rule_widened,
    endpoint_rule_narrowed,
    composition_added,
    composition_removed,
    property_added,

    fn parse(value: []const u8) ?ChangeKind {
        inline for (std.meta.tags(ChangeKind)) |kind| {
            if (std.mem.eql(u8, value, @tagName(kind))) return kind;
        }
        return null;
    }
};

const ChangeIdentity = struct {
    kind: ChangeKind,
    relation_id: u16,
};

pub fn parsePlan(allocator: std.mem.Allocator, bytes: []const u8) !Plan {
    if (bytes.len == 0 or bytes.len > max_plan_bytes) return Error.InvalidReconciliationPlan;
    var parsed = std.json.parseFromSlice(Document, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch return Error.InvalidReconciliationPlan;
    errdefer parsed.deinit();
    try validateDocument(&parsed.value);
    return .{ .parsed = parsed, .digest = sha256(bytes) };
}

pub fn sha256(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

pub fn digestMatchesHex(bytes: []const u8, expected: []const u8) bool {
    const digest = sha256(bytes);
    return digestEqualsHex(digest, expected);
}

pub fn digestEqualsHex(digest: [32]u8, expected: []const u8) bool {
    if (expected.len != sha256_hex_len) return false;
    var decoded: [32]u8 = undefined;
    for (0..decoded.len) |index| {
        const high = lowerHexNibble(expected[index * 2]) orelse return false;
        const low = lowerHexNibble(expected[index * 2 + 1]) orelse return false;
        decoded[index] = (high << 4) | low;
    }
    return std.crypto.timing_safe.eql([32]u8, digest, decoded);
}

pub fn digestHex(digest: [32]u8) [sha256_hex_len]u8 {
    const alphabet = "0123456789abcdef";
    var result: [sha256_hex_len]u8 = undefined;
    for (digest, 0..) |byte, index| {
        result[index * 2] = alphabet[byte >> 4];
        result[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return result;
}

fn lowerHexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        else => null,
    };
}

fn validateDocument(document: *const Document) !void {
    if (document.schema_version != 1 or
        !std.mem.eql(u8, document.contract_id, "repository.catalog.reconciliation.plan.v1") or
        !std.mem.eql(u8, document.status, "approved"))
    {
        return Error.InvalidReconciliationPlan;
    }
    if (document.candidate_revision != std.math.add(u32, document.existing_revision, 1) catch return Error.InvalidReconciliationPlan) {
        return Error.InvalidReconciliationPlan;
    }
    inline for (.{
        document.inputs.existing_catalog_sha256,
        document.inputs.candidate_catalog_sha256,
        document.inputs.candidate_schema_sha256,
        document.inputs.schema_validation_sha256,
    }) |value| {
        if (!isLowerSha256(value)) return Error.InvalidReconciliationPlan;
    }
    if (document.validation.endpoint_violations != 0 or document.validation.orphaned_types != 0) {
        return Error.InvalidReconciliationPlan;
    }
    if (document.validation.unknown_kinds_in_data != document.validation.unknown_kinds.len) {
        return Error.InvalidReconciliationPlan;
    }
    const expected_result = if (document.validation.unknown_kinds.len == 0) "ok" else "invalid";
    if (!std.mem.eql(u8, document.validation.result, expected_result)) return Error.InvalidReconciliationPlan;
    var previous_domain: ?[]const u8 = null;
    var previous_id: u16 = 0;
    for (document.validation.unknown_kinds) |unknown| {
        if ((!std.mem.eql(u8, unknown.domain, "node") and !std.mem.eql(u8, unknown.domain, "relation")) or unknown.count == 0) {
            return Error.InvalidReconciliationPlan;
        }
        if (previous_domain) |domain| {
            const order = std.mem.order(u8, domain, unknown.domain);
            if (order == .gt or (order == .eq and previous_id >= unknown.id)) return Error.InvalidReconciliationPlan;
        }
        previous_domain = unknown.domain;
        previous_id = unknown.id;
    }
    if (document.approved_changes.len == 0 or document.approved_changes.len > max_approved_changes or
        document.summary.changes != document.approved_changes.len)
    {
        return Error.InvalidReconciliationPlan;
    }

    var expected_counts = [_]usize{0} ** std.meta.tags(ChangeKind).len;
    for (document.approved_changes, 0..) |change, index| {
        if (!std.mem.eql(u8, change.domain, "relation")) return Error.InvalidReconciliationPlan;
        const kind = ChangeKind.parse(change.kind) orelse return Error.InvalidReconciliationPlan;
        if (!changePolicyAllows(kind, change.id, change.name)) return Error.InvalidReconciliationPlan;
        expected_counts[@intFromEnum(kind)] += 1;
        for (document.approved_changes[0..index]) |previous| {
            if (previous.id == change.id and std.mem.eql(u8, previous.kind, change.kind)) return Error.InvalidReconciliationPlan;
        }
    }
    try validateSummary(document.summary.by_kind, expected_counts);
}

fn isLowerSha256(value: []const u8) bool {
    if (value.len != sha256_hex_len) return false;
    for (value) |byte| _ = lowerHexNibble(byte) orelse return false;
    return true;
}

fn validateSummary(value: std.json.Value, expected: [std.meta.tags(ChangeKind).len]usize) !void {
    const object = switch (value) {
        .object => |object| object,
        else => return Error.InvalidReconciliationPlan,
    };
    var nonzero: usize = 0;
    for (std.meta.tags(ChangeKind), 0..) |kind, index| {
        const expected_count = expected[index];
        if (expected_count != 0) nonzero += 1;
        const actual = object.get(@tagName(kind));
        if (expected_count == 0) {
            if (actual != null) return Error.InvalidReconciliationPlan;
            continue;
        }
        const integer = switch (actual orelse return Error.InvalidReconciliationPlan) {
            .integer => |integer| integer,
            else => return Error.InvalidReconciliationPlan,
        };
        if (integer < 0 or @as(u64, @intCast(integer)) != expected_count) return Error.InvalidReconciliationPlan;
    }
    if (object.count() != nonzero) return Error.InvalidReconciliationPlan;
}

fn changePolicyAllows(kind: ChangeKind, relation_id: u16, name: []const u8) bool {
    const expected_name = expectedRelationName(relation_id) orelse return false;
    if (!std.mem.eql(u8, name, expected_name)) return false;
    return switch (kind) {
        .endpoint_rule_widened => relation_id == 0 or relation_id == 8 or relation_id == 13 or isMarkdownEndpointWidening(relation_id),
        .endpoint_rule_narrowed => relation_id == 9,
        .composition_added, .property_added => schema.isMdProjectionRelId(relation_id),
        .composition_removed => relation_id == 0,
    };
}

fn expectedRelationName(relation_id: u16) ?[]const u8 {
    return switch (relation_id) {
        0 => "contains",
        8 => "references",
        9 => "based_on",
        13 => "precedes",
        schema.md_rel_h1_id => "md:h1",
        schema.md_rel_h2_id => "md:h2",
        schema.md_rel_h3_id => "md:h3",
        schema.md_rel_h4_id => "md:h4",
        schema.md_rel_h5_id => "md:h5",
        schema.md_rel_h6_id => "md:h6",
        schema.md_rel_paragraph_id => "md:paragraph",
        schema.md_rel_code_block_id => "md:code_block",
        schema.md_rel_image_id => "md:image",
        schema.md_rel_list_id => "md:list",
        schema.md_rel_blockquote_id => "md:blockquote",
        schema.md_rel_html_block_id => "md:html_block",
        schema.md_rel_footnote_def_id => "md:footnote_def",
        schema.md_rel_link_reference_id => "md:link_reference",
        schema.md_rel_thematic_break_id => "md:thematic_break",
        schema.md_rel_raw_block_id => "md:raw_block",
        schema.md_rel_table_id => "md:table",
        schema.md_rel_table_row_id => "md:table_row",
        schema.md_rel_table_cell_id => "md:table_cell",
        schema.md_rel_text_chunk_id => "md:text_chunk",
        else => null,
    };
}

fn isMarkdownEndpointWidening(relation_id: u16) bool {
    return switch (relation_id) {
        schema.md_rel_paragraph_id,
        schema.md_rel_code_block_id,
        schema.md_rel_list_id,
        schema.md_rel_blockquote_id,
        schema.md_rel_html_block_id,
        schema.md_rel_footnote_def_id,
        schema.md_rel_link_reference_id,
        schema.md_rel_thematic_break_id,
        schema.md_rel_raw_block_id,
        schema.md_rel_table_cell_id,
        schema.md_rel_text_chunk_id,
        => true,
        else => false,
    };
}

pub fn verifyBoundInputs(
    plan: *const Plan,
    existing_catalog_json: []const u8,
    candidate_catalog_json: []const u8,
    candidate_schema_bytes: []const u8,
    schema_validation_bytes: []const u8,
) !void {
    const inputs = plan.document().inputs;
    if (!digestMatchesHex(existing_catalog_json, inputs.existing_catalog_sha256) or
        !digestMatchesHex(candidate_catalog_json, inputs.candidate_catalog_sha256) or
        !digestMatchesHex(candidate_schema_bytes, inputs.candidate_schema_sha256) or
        !digestMatchesHex(schema_validation_bytes, inputs.schema_validation_sha256))
    {
        return Error.ReconciliationInputChanged;
    }
}

/// Recheck the runtime observer receipt against the exact unknown-debt
/// baseline carried by the reviewed plan.  Input SHA binding alone is not a
/// semantic check: this parser also rejects missing, reordered, duplicated or
/// newly introduced unknown rows and any endpoint/orphan sample.
pub fn verifyValidationOutput(plan: *const Plan, bytes: []const u8) !void {
    const validation = plan.document().validation;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var unknown_index: usize = 0;
    var saw_summary = false;
    while (lines.next()) |line| {
        if (line.len == 0) {
            if (lines.peek() != null) return Error.ReconciliationInputChanged;
            continue;
        }
        if (saw_summary) return Error.ReconciliationInputChanged;
        if (std.mem.startsWith(u8, line, "SchemaUnknownKindInData ")) {
            if (unknown_index >= validation.unknown_kinds.len) return Error.ReconciliationInputChanged;
            const expected = validation.unknown_kinds[unknown_index];
            var buffer: [160]u8 = undefined;
            const rendered = std.fmt.bufPrint(&buffer, "SchemaUnknownKindInData domain={s} kind={} count={}", .{
                expected.domain,
                expected.id,
                expected.count,
            }) catch return Error.ReconciliationInputChanged;
            if (!std.mem.eql(u8, line, rendered)) return Error.ReconciliationInputChanged;
            unknown_index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "node_type ") or std.mem.startsWith(u8, line, "relation_type ")) continue;
        if (std.mem.startsWith(u8, line, "SchemaEndpointViolation ") or
            std.mem.startsWith(u8, line, "SchemaOrphanedTypeInUse "))
        {
            return Error.ReconciliationInputChanged;
        }
        if (std.mem.startsWith(u8, line, "schema_validate result=")) {
            var buffer: [192]u8 = undefined;
            const rendered = std.fmt.bufPrint(
                &buffer,
                "schema_validate result={s} endpoint_violations={} unknown_kinds_in_data={} orphaned_types={}",
                .{
                    validation.result,
                    validation.endpoint_violations,
                    validation.unknown_kinds_in_data,
                    validation.orphaned_types,
                },
            ) catch return Error.ReconciliationInputChanged;
            if (!std.mem.eql(u8, line, rendered)) return Error.ReconciliationInputChanged;
            saw_summary = true;
            continue;
        }
        return Error.ReconciliationInputChanged;
    }
    if (!saw_summary or unknown_index != validation.unknown_kinds.len) return Error.ReconciliationInputChanged;
}

pub fn validateCatalogTransition(plan: *const Plan, existing: catalog.Catalog, candidate: catalog.Catalog) !void {
    const document = plan.document();
    if (existing.revision != document.existing_revision or candidate.revision != document.candidate_revision or
        existing.format_version != candidate.format_version or
        !sameProfiles(existing.profiles.items, candidate.profiles.items) or
        !sameRetired(existing.retired.items, candidate.retired.items))
    {
        return Error.UnapprovedCatalogChange;
    }
    var observed: [max_approved_changes]ChangeIdentity = undefined;
    var observed_len: usize = 0;
    try compareNodeTypes(existing.registry, candidate.registry);
    try compareRelationTypes(existing.registry, candidate.registry, &observed, &observed_len);
    if (observed_len != document.approved_changes.len) return Error.UnapprovedCatalogChange;
    for (observed[0..observed_len]) |change| {
        if (!planContains(document, change)) return Error.UnapprovedCatalogChange;
    }
}

fn sameProfiles(existing: []const []u8, candidate: []const []u8) bool {
    if (existing.len != candidate.len) return false;
    for (existing, candidate) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    return true;
}

fn sameRetired(existing: []const catalog.RetiredType, candidate: []const catalog.RetiredType) bool {
    if (existing.len != candidate.len) return false;
    for (existing, candidate) |left, right| {
        if (left.id != right.id or left.domain != right.domain or left.retired_at_revision != right.retired_at_revision or
            !std.mem.eql(u8, left.name, right.name)) return false;
    }
    return true;
}

fn compareNodeTypes(existing: schema.Registry, candidate: schema.Registry) !void {
    if (existing.nodeTypeCount() != candidate.nodeTypeCount()) return Error.UnapprovedCatalogChange;
    var index: usize = 0;
    while (existing.nodeTypeInfo(index)) |old| : (index += 1) {
        const new = findNodeType(candidate, old.id) orelse return Error.UnapprovedCatalogChange;
        if (!std.mem.eql(u8, old.name, new.name) or !sameU16Set(old.parents, new.parents) or
            !sameProperties(existing, candidate, .node, old.id)) return Error.UnapprovedCatalogChange;
    }
}

fn compareRelationTypes(
    existing: schema.Registry,
    candidate: schema.Registry,
    observed: *[max_approved_changes]ChangeIdentity,
    observed_len: *usize,
) !void {
    if (existing.relationTypeCount() != candidate.relationTypeCount()) return Error.UnapprovedCatalogChange;
    var index: usize = 0;
    while (existing.relationTypeInfo(index)) |old| : (index += 1) {
        const new = findRelationType(candidate, old.id) orelse return Error.UnapprovedCatalogChange;
        if (!std.mem.eql(u8, old.name, new.name) or !sameU16Set(old.parents, new.parents) or old.class != new.class) {
            return Error.UnapprovedCatalogChange;
        }
        try compareRelationProperties(existing, candidate, old.id, observed, observed_len);
        const old_endpoint = existing.relationEndpointRuleById(old.id) orelse return Error.UnapprovedCatalogChange;
        const new_endpoint = candidate.relationEndpointRuleById(old.id) orelse return Error.UnapprovedCatalogChange;
        if (!std.meta.eql(old_endpoint, new_endpoint)) {
            const kind = classifyEndpointChange(old_endpoint, new_endpoint) orelse return Error.UnapprovedCatalogChange;
            if (!endpointPolicyMatches(kind, old.id, new_endpoint)) return Error.UnapprovedCatalogChange;
            try appendObserved(observed, observed_len, .{ .kind = kind, .relation_id = old.id });
        }
        const old_composition = existing.relationCompositionById(old.id);
        const new_composition = candidate.relationCompositionById(old.id);
        if (!sameComposition(old_composition, new_composition)) {
            const kind: ChangeKind = if (old_composition == null and new_composition != null)
                .composition_added
            else if (old_composition != null and new_composition == null)
                .composition_removed
            else
                return Error.UnapprovedCatalogChange;
            if (!compositionPolicyMatches(kind, old.id, old_composition, new_composition)) return Error.UnapprovedCatalogChange;
            try appendObserved(observed, observed_len, .{ .kind = kind, .relation_id = old.id });
        }
    }
}

const TypeDomain = enum { node, relation };

fn sameProperties(existing: schema.Registry, candidate: schema.Registry, domain: TypeDomain, type_id: u16) bool {
    const old_count = switch (domain) {
        .node => existing.nodePropertyCount(type_id),
        .relation => existing.relationPropertyCount(type_id),
    };
    const new_count = switch (domain) {
        .node => candidate.nodePropertyCount(type_id),
        .relation => candidate.relationPropertyCount(type_id),
    };
    if (old_count != new_count) return false;
    var index: usize = 0;
    while (index < old_count) : (index += 1) {
        const old = propertyInfo(existing, domain, type_id, index) orelse return false;
        const new = propertyByName(candidate, domain, type_id, old.name) orelse return false;
        if (!sameProperty(old, new)) return false;
    }
    return true;
}

fn compareRelationProperties(
    existing: schema.Registry,
    candidate: schema.Registry,
    relation_id: u16,
    observed: *[max_approved_changes]ChangeIdentity,
    observed_len: *usize,
) !void {
    var old_index: usize = 0;
    while (existing.relationPropertyInfo(relation_id, old_index)) |old| : (old_index += 1) {
        const new = candidate.relationPropertyByTypeId(relation_id, old.name) orelse return Error.UnapprovedCatalogChange;
        if (!sameProperty(old, new)) return Error.UnapprovedCatalogChange;
    }
    var new_index: usize = 0;
    while (candidate.relationPropertyInfo(relation_id, new_index)) |new| : (new_index += 1) {
        if (existing.relationPropertyByTypeId(relation_id, new.name) != null) continue;
        if (!schema.isMdProjectionRelId(relation_id) or !isExpectedOrderKey(new)) return Error.UnapprovedCatalogChange;
        try appendObserved(observed, observed_len, .{ .kind = .property_added, .relation_id = relation_id });
    }
}

fn propertyInfo(registry: schema.Registry, domain: TypeDomain, id: u16, index: usize) ?schema.PropertyMeta {
    return switch (domain) {
        .node => registry.nodePropertyInfo(id, index),
        .relation => registry.relationPropertyInfo(id, index),
    };
}

fn propertyByName(registry: schema.Registry, domain: TypeDomain, id: u16, name: []const u8) ?schema.PropertyMeta {
    return switch (domain) {
        .node => registry.nodePropertyByTypeId(id, name),
        .relation => registry.relationPropertyByTypeId(id, name),
    };
}

fn sameProperty(left: schema.PropertyMeta, right: schema.PropertyMeta) bool {
    if (!std.mem.eql(u8, left.name, right.name) or left.value_type != right.value_type or
        left.required != right.required or left.nullable != right.nullable or
        left.agent_fillable != right.agent_fillable or left.human_fillable != right.human_fillable or
        left.indexed != right.indexed or left.searchable != right.searchable or
        left.returned_by_default != right.returned_by_default or left.enum_values.len != right.enum_values.len)
    {
        return false;
    }
    for (left.enum_values, right.enum_values) |left_value, right_value| {
        if (!std.mem.eql(u8, left_value, right_value)) return false;
    }
    return true;
}

fn isExpectedOrderKey(property: schema.PropertyMeta) bool {
    return std.mem.eql(u8, property.name, "order_key") and property.value_type == .uint and
        !property.required and property.nullable and !property.agent_fillable and !property.human_fillable and
        property.indexed and !property.searchable and !property.returned_by_default and property.enum_values.len == 0;
}

fn classifyEndpointChange(existing: schema.RelationEndpointRule, candidate: schema.RelationEndpointRule) ?ChangeKind {
    var widened = true;
    var narrowed = true;
    inline for (.{ .{ existing.src, candidate.src }, .{ existing.dst, candidate.dst } }) |axes| {
        const old = axes[0];
        const new = axes[1];
        const equal = std.meta.eql(old, new);
        const axis_widened = old != null and (new == null or old.?.isSubsetOf(new.?));
        const axis_narrowed = new != null and (old == null or new.?.isSubsetOf(old.?));
        widened = widened and (equal or axis_widened);
        narrowed = narrowed and (equal or axis_narrowed);
    }
    if (widened and !narrowed) return .endpoint_rule_widened;
    if (narrowed and !widened) return .endpoint_rule_narrowed;
    return null;
}

fn endpointPolicyMatches(kind: ChangeKind, relation_id: u16, endpoint: schema.RelationEndpointRule) bool {
    return switch (kind) {
        .endpoint_rule_widened => switch (relation_id) {
            0, 13 => endpoint.src == null and endpoint.dst == null,
            8 => std.meta.eql(endpoint, schema.sharedReferencesEndpointRule() catch return false),
            schema.md_rel_paragraph_id,
            schema.md_rel_code_block_id,
            schema.md_rel_list_id,
            schema.md_rel_blockquote_id,
            schema.md_rel_html_block_id,
            schema.md_rel_footnote_def_id,
            schema.md_rel_link_reference_id,
            schema.md_rel_thematic_break_id,
            schema.md_rel_raw_block_id,
            => endpointMatchesIds(endpoint, &.{ 6, 7 }, &.{ 7, 14 }),
            schema.md_rel_table_cell_id, schema.md_rel_text_chunk_id => endpointMatchesIds(endpoint, &.{7}, &.{ 7, 14 }),
            else => false,
        },
        .endpoint_rule_narrowed => relation_id == 9 and std.meta.eql(endpoint, schema.sharedBasedOnEndpointRule() catch return false),
        else => false,
    };
}

fn endpointMatchesIds(endpoint: schema.RelationEndpointRule, src_ids: []const u16, dst_ids: []const u16) bool {
    return typeSetMatchesIds(endpoint.src, src_ids) and typeSetMatchesIds(endpoint.dst, dst_ids);
}

fn typeSetMatchesIds(maybe_set: ?schema.NodeTypeSet, ids: []const u16) bool {
    const set = maybe_set orelse return false;
    if (set.count() != ids.len) return false;
    for (ids) |id| if (!set.containsId(id)) return false;
    return true;
}

fn compositionPolicyMatches(
    kind: ChangeKind,
    relation_id: u16,
    existing: ?schema.CompositionMeta,
    candidate: ?schema.CompositionMeta,
) bool {
    return switch (kind) {
        .composition_added => existing == null and schema.isMdProjectionRelId(relation_id) and
            isExpectedMarkdownComposition(relation_id, candidate orelse return false),
        .composition_removed => relation_id == 0 and candidate == null and isLegacyContainsComposition(existing orelse return false),
        else => false,
    };
}

fn isExpectedMarkdownComposition(relation_id: u16, value: schema.CompositionMeta) bool {
    return value.enabled and value.owner == schema.isMdOwnerProjectionRelId(relation_id) and value.cardinality == .many and
        if (value.ordered_by) |ordered_by| std.mem.eql(u8, ordered_by, "order_key") else false;
}

fn isLegacyContainsComposition(value: schema.CompositionMeta) bool {
    return value.enabled and value.owner and value.cardinality == .many and
        if (value.ordered_by) |ordered_by| std.mem.eql(u8, ordered_by, "order_key") else false;
}

fn sameComposition(left: ?schema.CompositionMeta, right: ?schema.CompositionMeta) bool {
    if (left == null or right == null) return left == null and right == null;
    const a = left.?;
    const b = right.?;
    if (a.enabled != b.enabled or a.owner != b.owner or a.cardinality != b.cardinality) return false;
    if (a.ordered_by == null or b.ordered_by == null) return a.ordered_by == null and b.ordered_by == null;
    return std.mem.eql(u8, a.ordered_by.?, b.ordered_by.?);
}

fn sameU16Set(left: []const u16, right: []const u16) bool {
    if (left.len != right.len) return false;
    for (left) |value| if (std.mem.indexOfScalar(u16, right, value) == null) return false;
    return true;
}

fn findNodeType(registry: schema.Registry, id: u16) ?schema.TypeInfo {
    var index: usize = 0;
    while (registry.nodeTypeInfo(index)) |info| : (index += 1) if (info.id == id) return info;
    return null;
}

fn findRelationType(registry: schema.Registry, id: u16) ?schema.RelationTypeInfo {
    var index: usize = 0;
    while (registry.relationTypeInfo(index)) |info| : (index += 1) if (info.id == id) return info;
    return null;
}

fn appendObserved(observed: *[max_approved_changes]ChangeIdentity, len: *usize, value: ChangeIdentity) !void {
    if (len.* >= observed.len) return Error.UnapprovedCatalogChange;
    observed[len.*] = value;
    len.* += 1;
}

fn planContains(document: *const Document, observed: ChangeIdentity) bool {
    for (document.approved_changes) |change| {
        const kind = ChangeKind.parse(change.kind) orelse return false;
        if (kind == observed.kind and change.id == observed.relation_id) return true;
    }
    return false;
}

fn testPlanJson(allocator: std.mem.Allocator, existing_sha: []const u8, candidate_sha: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"schema_version":1,"contract_id":"repository.catalog.reconciliation.plan.v1","status":"approved","inputs":{{"existing_catalog_sha256":"{s}","candidate_catalog_sha256":"{s}","candidate_schema_sha256":"{s}","schema_validation_sha256":"{s}"}},"existing_revision":1,"candidate_revision":2,"validation":{{"result":"ok","endpoint_violations":0,"unknown_kinds_in_data":0,"orphaned_types":0,"unknown_kinds":[]}},"approved_changes":[{{"domain":"relation","id":0,"name":"contains","kind":"endpoint_rule_widened"}},{{"domain":"relation","id":0,"name":"contains","kind":"composition_removed"}}],"summary":{{"changes":2,"by_kind":{{"composition_removed":1,"endpoint_rule_widened":1}}}}}}
    , .{ existing_sha, candidate_sha, "0" ** sha256_hex_len, "1" ** sha256_hex_len });
}

fn testCatalog(allocator: std.mem.Allocator, candidate: bool) !catalog.Catalog {
    var result = catalog.Catalog.init(allocator);
    errdefer result.deinit();
    try result.registry.addKernelTypes();
    const kernel_node = schema.kernel_node_type_id;
    try result.registry.addNodeType("document", 6, &.{kernel_node});
    try result.registry.addNodeType("document_section", 7, &.{kernel_node});
    var src = try schema.NodeTypeSet.singleton(6);
    var dst = try schema.NodeTypeSet.singleton(7);
    _ = &src;
    _ = &dst;
    try result.registry.addRelationTypeWithMetadata(
        "contains",
        0,
        &.{schema.kernel_edge_type_id},
        if (candidate) .{} else .{ .src = src, .dst = dst },
        .sys,
    );
    try result.registry.setRelationProperty(0, .{ .name = "order_key", .value_type = .uint, .indexed = true });
    if (!candidate) try result.registry.setRelationComposition(0, .{
        .enabled = true,
        .owner = true,
        .cardinality = .many,
        .ordered_by = "order_key",
    });
    result.revision = if (candidate) 2 else 1;
    return result;
}

test "plan parser rejects unapproved identities and non-canonical hashes" {
    const zero = "0" ** sha256_hex_len;
    const json = try testPlanJson(std.testing.allocator, zero, zero);
    defer std.testing.allocator.free(json);
    var plan = try parsePlan(std.testing.allocator, json);
    plan.deinit();

    const bad_id = try std.mem.replaceOwned(u8, std.testing.allocator, json, "\"id\":0", "\"id\":77");
    defer std.testing.allocator.free(bad_id);
    try std.testing.expectError(Error.InvalidReconciliationPlan, parsePlan(std.testing.allocator, bad_id));

    const upper_hash = try std.mem.replaceOwned(u8, std.testing.allocator, json, zero, "A" ** sha256_hex_len);
    defer std.testing.allocator.free(upper_hash);
    try std.testing.expectError(Error.InvalidReconciliationPlan, parsePlan(std.testing.allocator, upper_hash));
}

test "bound inputs use exact SHA-256 bytes" {
    const existing = "existing\n";
    const candidate = "candidate\n";
    const existing_hex = digestHex(sha256(existing));
    const candidate_hex = digestHex(sha256(candidate));
    const json = try testPlanJson(std.testing.allocator, &existing_hex, &candidate_hex);
    defer std.testing.allocator.free(json);
    var plan = try parsePlan(std.testing.allocator, json);
    defer plan.deinit();
    try std.testing.expect(digestMatchesHex(existing, plan.document().inputs.existing_catalog_sha256));
    try std.testing.expectError(Error.ReconciliationInputChanged, verifyBoundInputs(&plan, "changed\n", candidate, "", ""));
}

test "catalog transition accepts only the exact approved semantic changes" {
    var existing = try testCatalog(std.testing.allocator, false);
    defer existing.deinit();
    var candidate = try testCatalog(std.testing.allocator, true);
    defer candidate.deinit();
    const zero = "0" ** sha256_hex_len;
    const json = try testPlanJson(std.testing.allocator, zero, zero);
    defer std.testing.allocator.free(json);
    var plan = try parsePlan(std.testing.allocator, json);
    defer plan.deinit();
    try validateCatalogTransition(&plan, existing, candidate);

    try candidate.registry.setRelationProperty(0, .{ .name = "unexpected", .value_type = .string });
    try std.testing.expectError(Error.UnapprovedCatalogChange, validateCatalogTransition(&plan, existing, candidate));
}

test "validation output must reproduce the exact approved unknown baseline" {
    const zero = "0" ** sha256_hex_len;
    const base = try testPlanJson(std.testing.allocator, zero, zero);
    defer std.testing.allocator.free(base);
    const with_unknown = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        base,
        "\"result\":\"ok\",\"endpoint_violations\":0,\"unknown_kinds_in_data\":0,\"orphaned_types\":0,\"unknown_kinds\":[]",
        "\"result\":\"invalid\",\"endpoint_violations\":0,\"unknown_kinds_in_data\":1,\"orphaned_types\":0,\"unknown_kinds\":[{\"domain\":\"relation\",\"id\":7,\"count\":1}]",
    );
    defer std.testing.allocator.free(with_unknown);
    var plan = try parsePlan(std.testing.allocator, with_unknown);
    defer plan.deinit();
    const valid =
        "relation_type id=0 name=contains data_count=9\n" ++
        "SchemaUnknownKindInData domain=relation kind=7 count=1\n" ++
        "schema_validate result=invalid endpoint_violations=0 unknown_kinds_in_data=1 orphaned_types=0\n";
    try verifyValidationOutput(&plan, valid);
    try std.testing.expectError(
        Error.ReconciliationInputChanged,
        verifyValidationOutput(&plan, "SchemaUnknownKindInData domain=relation kind=7 count=2\n" ++
            "schema_validate result=invalid endpoint_violations=0 unknown_kinds_in_data=1 orphaned_types=0\n"),
    );
}
