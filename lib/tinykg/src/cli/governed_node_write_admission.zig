const std = @import("std");
const core = @import("../core.zig");
const schema = @import("../schema.zig");
const storage = @import("../storage.zig");

/// Owns CLI node-write syntax and the fail-closed admission checks which run
/// before Store mutation. Cross-owner project linking is injected explicitly;
/// transaction orchestration and command rendering remain outside.
pub fn GovernedNodeWriteAdmission(comptime Ops: type) type {
    return struct {
        const Self = @This();

        pub const node_text_char_limit: usize = 8 * 1024 + 512;
        pub const node_llm_metadata_field_char_limit: usize = 6000;
        pub const node_llm_metadata_total_char_limit: usize = 12000;

        pub const ParsedAddNodeArgs = struct {
            kind_label: []const u8,
            text: []const u8,
            schema_path: ?[]const u8 = null,
            schema_type: ?[]const u8 = null,
            name: ?[]const u8 = null,
            summary: ?[]const u8 = null,
            retrieval_hints: ?[]const u8 = null,
        };

        pub const ParsedUpdateNodeArgs = struct {
            node_id: []const u8,
            kind_label: []const u8,
            text: []const u8,
            schema_path: ?[]const u8 = null,
            schema_type: ?[]const u8 = null,
            name: ?[]const u8 = null,
            summary: ?[]const u8 = null,
            retrieval_hints: ?[]const u8 = null,
        };

        pub const ParsedGovernNodeArgs = struct {
            node_id: []const u8,
            parent_id: ?[]const u8 = null,
            schema_type: ?[]const u8 = null,
        };

        pub const TaskEventMetadata = struct {
            event_type: []const u8,
            event_ns: u128,
            root_id: u64,
            task_id: ?u64 = null,
            dependency_relation: ?[]const u8 = null,

            pub fn deinit(self: TaskEventMetadata, allocator: std.mem.Allocator) void {
                allocator.free(self.event_type);
                if (self.dependency_relation) |relation| allocator.free(relation);
            }
        };

        pub const ParsedNodeTextGovernanceArgs = struct {
            kind_label: []const u8,
            text: []const u8,
            schema_type: ?[]const u8 = null,
            name: ?[]const u8 = null,
            summary: ?[]const u8 = null,
            retrieval_hints: ?[]const u8 = null,
            recorded_ns: ?u128 = null,
            task_created_ns: ?u128 = null,
            task_completed_ns: ?u128 = null,
            task_event_metadata: ?TaskEventMetadata = null,
        };

        pub fn parseAddNodeArgs(rest: []const []const u8) !ParsedAddNodeArgs {
            if (rest.len < 2) return error.MissingArgument;
            var parsed = ParsedAddNodeArgs{
                .kind_label = rest[0],
                .text = rest[1],
            };
            var pos: usize = 2;
            while (pos < rest.len) {
                const option = rest[pos];
                if (std.mem.eql(u8, option, "--schema")) {
                    if (pos + 1 >= rest.len) return error.MissingArgument;
                    parsed.schema_path = rest[pos + 1];
                    pos += 2;
                } else if (std.mem.eql(u8, option, "--schema-type")) {
                    if (pos + 1 >= rest.len) return error.MissingArgument;
                    parsed.schema_type = rest[pos + 1];
                    pos += 2;
                } else if (std.mem.eql(u8, option, "--name")) {
                    if (pos + 1 >= rest.len) return error.MissingArgument;
                    parsed.name = rest[pos + 1];
                    pos += 2;
                } else if (std.mem.eql(u8, option, "--summary")) {
                    if (pos + 1 >= rest.len) return error.MissingArgument;
                    parsed.summary = rest[pos + 1];
                    pos += 2;
                } else if (std.mem.eql(u8, option, "--retrieval-hints") or std.mem.eql(u8, option, "--retrieval-hint")) {
                    if (pos + 1 >= rest.len) return error.MissingArgument;
                    parsed.retrieval_hints = rest[pos + 1];
                    pos += 2;
                } else if (std.mem.startsWith(u8, option, "--")) {
                    return error.UnknownOption;
                } else {
                    return error.TooManyArguments;
                }
            }
            return parsed;
        }

        pub fn parseUpdateNodeArgs(rest: []const []const u8) !ParsedUpdateNodeArgs {
            if (rest.len < 3) return error.MissingArgument;
            var parsed = ParsedUpdateNodeArgs{
                .node_id = rest[0],
                .kind_label = rest[1],
                .text = rest[2],
            };
            var pos: usize = 3;
            while (pos < rest.len) {
                const option = rest[pos];
                if (std.mem.eql(u8, option, "--schema")) {
                    if (pos + 1 >= rest.len) return error.MissingArgument;
                    parsed.schema_path = rest[pos + 1];
                    pos += 2;
                } else if (std.mem.eql(u8, option, "--schema-type")) {
                    if (pos + 1 >= rest.len) return error.MissingArgument;
                    parsed.schema_type = rest[pos + 1];
                    pos += 2;
                } else if (std.mem.eql(u8, option, "--name")) {
                    if (pos + 1 >= rest.len) return error.MissingArgument;
                    parsed.name = rest[pos + 1];
                    pos += 2;
                } else if (std.mem.eql(u8, option, "--summary")) {
                    if (pos + 1 >= rest.len) return error.MissingArgument;
                    parsed.summary = rest[pos + 1];
                    pos += 2;
                } else if (std.mem.eql(u8, option, "--retrieval-hints") or std.mem.eql(u8, option, "--retrieval-hint")) {
                    if (pos + 1 >= rest.len) return error.MissingArgument;
                    parsed.retrieval_hints = rest[pos + 1];
                    pos += 2;
                } else if (std.mem.startsWith(u8, option, "--")) {
                    return error.UnknownOption;
                } else {
                    return error.TooManyArguments;
                }
            }
            return parsed;
        }

        pub fn parseGovernNodeArgs(rest: []const []const u8) !ParsedGovernNodeArgs {
            if (rest.len < 3) return error.MissingArgument;
            var node_id: ?[]const u8 = rest[0];
            var parent_id: ?[]const u8 = null;
            var schema_type: ?[]const u8 = null;
            var pos: usize = 1;
            while (pos < rest.len) {
                const option = rest[pos];
                if (std.mem.eql(u8, option, "--parent")) {
                    if (pos + 1 >= rest.len) return error.MissingArgument;
                    parent_id = rest[pos + 1];
                    pos += 2;
                } else if (std.mem.eql(u8, option, "--schema-type")) {
                    if (pos + 1 >= rest.len) return error.MissingArgument;
                    schema_type = rest[pos + 1];
                    pos += 2;
                } else if (std.mem.startsWith(u8, option, "--")) {
                    return error.UnknownOption;
                } else {
                    if (node_id != null) return error.TooManyArguments;
                    node_id = option;
                    pos += 1;
                }
            }
            return .{
                .node_id = node_id orelse return error.MissingArgument,
                .parent_id = parent_id,
                .schema_type = schema_type,
            };
        }

        pub fn normalizeNodeStringPropertyKey(key: []const u8) ![]const u8 {
            const normalized = if (std.mem.eql(u8, key, "retrieval-hints")) "retrieval_hints" else key;
            if (!std.mem.eql(u8, normalized, "name") and
                !std.mem.eql(u8, normalized, "summary") and
                !std.mem.eql(u8, normalized, "retrieval_hints") and
                !std.mem.eql(u8, normalized, "schema_type") and
                !std.mem.eql(u8, normalized, "external_key") and
                !std.mem.eql(u8, normalized, "content_hash") and
                !std.mem.eql(u8, normalized, "source_label") and
                !std.mem.eql(u8, normalized, "task_event_type") and
                !std.mem.eql(u8, normalized, "dependency_relation"))
            {
                return error.InvalidRecord;
            }
            return normalized;
        }

        pub fn normalizeNodeUintPropertyKey(key: []const u8) ![]const u8 {
            const normalized = if (std.mem.eql(u8, key, "created-at"))
                "created_at"
            else if (std.mem.eql(u8, key, "updated-at"))
                "updated_at"
            else if (std.mem.eql(u8, key, "byte-start"))
                "byte_start"
            else if (std.mem.eql(u8, key, "byte-end"))
                "byte_end"
            else if (std.mem.eql(u8, key, "line-start"))
                "line_start"
            else if (std.mem.eql(u8, key, "line-end"))
                "line_end"
            else
                key;
            // Task lifecycle timestamps are state-machine output, not generic
            // CLI properties and therefore remain fail-closed here.
            if (!std.mem.eql(u8, normalized, "task_event_ns") and
                !std.mem.eql(u8, normalized, "task_root_id") and
                !std.mem.eql(u8, normalized, "task_id") and
                !std.mem.eql(u8, normalized, "generation") and
                !std.mem.eql(u8, normalized, "created_at") and
                !std.mem.eql(u8, normalized, "updated_at") and
                !std.mem.eql(u8, normalized, "byte_start") and
                !std.mem.eql(u8, normalized, "byte_end") and
                !std.mem.eql(u8, normalized, "line_start") and
                !std.mem.eql(u8, normalized, "line_end"))
            {
                return error.InvalidRecord;
            }
            return normalized;
        }

        pub fn nodeVisibleTextFromGovernanceArgs(allocator: std.mem.Allocator, parsed: ParsedNodeTextGovernanceArgs) ![]const u8 {
            _ = allocator;
            if (parsed.task_event_metadata) |metadata| {
                try validateGovernanceMetadataToken("task_event");
                try validateGovernanceMetadataToken(metadata.event_type);
                if (metadata.dependency_relation) |relation| try validateGovernanceMetadataToken(relation);
            }
            return parsed.text;
        }

        pub fn applyNodeGovernanceProperties(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_id: core.NodeId,
            parsed: ParsedNodeTextGovernanceArgs,
            parent_id: ?[]const u8,
        ) !void {
            const owner: storage.PropertyOwner = .{ .node = node_id };
            const schema_type = if (parsed.task_event_metadata != null) "task_event" else parsed.schema_type orelse parsed.kind_label;
            const parent_node_id = if (parent_id) |pid| try Ops.parseNodeIdArg(pid) else null;
            var writes: [12]storage.PropertyPayloadWrite = undefined;
            var write_count: usize = 0;
            if (parsed.name) |name| {
                writes[write_count] = .{ .owner = owner, .key = "name", .value = .{ .string = name } };
                write_count += 1;
            }
            if (parsed.summary) |summary| {
                writes[write_count] = .{ .owner = owner, .key = "summary", .value = .{ .string = summary } };
                write_count += 1;
            }
            if (parsed.retrieval_hints) |retrieval_hints| {
                writes[write_count] = .{ .owner = owner, .key = "retrieval_hints", .value = .{ .string = retrieval_hints } };
                write_count += 1;
            }
            if (parent_node_id != null or parsed.schema_type != null or parsed.task_event_metadata != null) {
                writes[write_count] = .{ .owner = owner, .key = "schema_type", .value = .{ .string = schema_type } };
                write_count += 1;
            }
            if (parsed.task_event_metadata) |metadata| {
                writes[write_count] = .{ .owner = owner, .key = "task_event_type", .value = .{ .string = metadata.event_type } };
                write_count += 1;
                writes[write_count] = .{ .owner = owner, .key = "task_event_ns", .value = .{ .uint = try u128ToU64(metadata.event_ns) } };
                write_count += 1;
                writes[write_count] = .{ .owner = owner, .key = "task_root_id", .value = .{ .uint = metadata.root_id } };
                write_count += 1;
                if (metadata.task_id) |task_id| {
                    writes[write_count] = .{ .owner = owner, .key = "task_id", .value = .{ .uint = task_id } };
                    write_count += 1;
                }
                if (metadata.dependency_relation) |relation| {
                    writes[write_count] = .{ .owner = owner, .key = "dependency_relation", .value = .{ .string = relation } };
                    write_count += 1;
                }
            }
            if (parsed.recorded_ns) |recorded_ns| {
                if (nodeGovernanceNeedsTaskMetricTimestamp(parsed.kind_label, schema_type)) {
                    const created_ns = parsed.task_created_ns orelse if (nodeGovernanceIsOpenTask(parsed.kind_label, schema_type)) recorded_ns else null;
                    writes[write_count] = .{ .owner = owner, .key = "task_recorded_ns", .value = .{ .uint = try u128ToU64(recorded_ns) } };
                    write_count += 1;
                    if (created_ns) |created| {
                        writes[write_count] = .{ .owner = owner, .key = "task_created_ns", .value = .{ .uint = try u128ToU64(created) } };
                        write_count += 1;
                    }
                    if (parsed.task_completed_ns) |completed| {
                        writes[write_count] = .{ .owner = owner, .key = "task_completed_ns", .value = .{ .uint = try u128ToU64(completed) } };
                        write_count += 1;
                    }
                }
            }
            if (write_count != 0) _ = try store.upsertPropertiesBatch(allocator, writes[0..write_count]);
            if (parent_node_id) |parent| try Ops.linkNodeToProjectParent(allocator, store, node_id, parent);
        }

        pub fn validateNodeTextGranularity(text: []const u8) !void {
            const chars = std.unicode.utf8CountCodepoints(text) catch return error.InvalidRecord;
            if (chars > node_text_char_limit) return error.NodeTextTooLarge;
        }

        pub fn validateNodeLlmMetadataGranularity(name: ?[]const u8, summary: ?[]const u8, retrieval_hints: ?[]const u8) !void {
            var total_chars: usize = 0;
            inline for (.{ name, summary, retrieval_hints }) |maybe_value| {
                if (maybe_value) |value| {
                    const chars = std.unicode.utf8CountCodepoints(value) catch return error.InvalidRecord;
                    if (chars > node_llm_metadata_field_char_limit) return error.NodePropertyTooLarge;
                    total_chars = std.math.add(usize, total_chars, chars) catch return error.NodePropertyTooLarge;
                }
            }
            if (total_chars > node_llm_metadata_total_char_limit) return error.NodePropertyTooLarge;
        }

        pub fn validateNodeWriteGranularity(parsed: ParsedNodeTextGovernanceArgs) !void {
            try validateNodeTextGranularity(parsed.text);
            try validateNodeLlmMetadataGranularity(parsed.name, parsed.summary, parsed.retrieval_hints);
        }

        pub fn validateSchemaStringPropertyWrite(
            allocator: std.mem.Allocator,
            store: storage.Store,
            registry: schema.Registry,
            owner: storage.PropertyOwner,
            key: []const u8,
            value: []const u8,
            require_declared: bool,
        ) !void {
            const maybe_property = switch (owner) {
                .node => |node_id| blk: {
                    var node = (try store.readNodeById(allocator, node_id)) orelse return core.Error.NotFound;
                    defer node.deinit(allocator);
                    break :blk registry.nodePropertyByTypeId(@intFromEnum(node.kind), key);
                },
                .edge => |edge_id| blk: {
                    const edge = try store.readEdgeById(edge_id);
                    break :blk registry.relationPropertyByTypeId(@intFromEnum(edge.rel), key);
                },
            };
            const property = maybe_property orelse {
                if (require_declared) return error.UnknownProperty;
                return;
            };
            switch (property.value_type) {
                .string, .json => {},
                .@"enum" => if (!property.enumAllows(value)) return error.InvalidRecord,
                else => return error.InvalidRecord,
            }
        }

        pub fn validateSchemaUintPropertyWrite(
            allocator: std.mem.Allocator,
            store: storage.Store,
            registry: schema.Registry,
            owner: storage.PropertyOwner,
            key: []const u8,
            require_declared: bool,
        ) !void {
            const maybe_property = switch (owner) {
                .node => |node_id| blk: {
                    var node = (try store.readNodeById(allocator, node_id)) orelse return core.Error.NotFound;
                    defer node.deinit(allocator);
                    break :blk registry.nodePropertyByTypeId(@intFromEnum(node.kind), key);
                },
                .edge => |edge_id| blk: {
                    const edge = try store.readEdgeById(edge_id);
                    break :blk registry.relationPropertyByTypeId(@intFromEnum(edge.rel), key);
                },
            };
            const property = maybe_property orelse {
                if (require_declared) return error.UnknownProperty;
                return;
            };
            if (property.value_type != .uint) return error.InvalidRecord;
        }

        pub fn validateGovernanceMetadataToken(value: []const u8) !void {
            if (value.len == 0 or value.len > 128) return error.InvalidRecord;
            for (value) |byte| {
                const ok = std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.' or byte == ':' or byte == '/';
                if (!ok) return error.InvalidRecord;
            }
        }

        pub fn nodeGovernanceNeedsTaskMetricTimestamp(kind_label: []const u8, schema_type: []const u8) bool {
            return std.mem.eql(u8, kind_label, "task") or
                std.mem.eql(u8, kind_label, "verification") or
                std.mem.eql(u8, kind_label, "fix") or
                std.mem.eql(u8, schema_type, "task") or
                std.mem.eql(u8, schema_type, "verification") or
                std.mem.eql(u8, schema_type, "fix");
        }

        pub fn nodeGovernanceIsOpenTask(kind_label: []const u8, schema_type: []const u8) bool {
            return std.mem.eql(u8, kind_label, "task") or std.mem.eql(u8, schema_type, "task");
        }

        pub fn u128ToU64(value: u128) !u64 {
            return std.math.cast(u64, value) orelse error.RecordTooLarge;
        }
    };
}

const admission = GovernedNodeWriteAdmission(struct {});

test "governed node admission parses aliases and metadata" {
    const parsed = try admission.parseAddNodeArgs(&.{
        "task", "body", "--schema-type", "task", "--name", "Work", "--summary", "Summary", "--retrieval-hint", "next",
    });
    try std.testing.expectEqualStrings("task", parsed.kind_label);
    try std.testing.expectEqualStrings("task", parsed.schema_type.?);
    try std.testing.expectEqualStrings("Work", parsed.name.?);
    try std.testing.expectEqualStrings("Summary", parsed.summary.?);
    try std.testing.expectEqualStrings("next", parsed.retrieval_hints.?);
}

test "governed node admission rejects generic lifecycle timestamp keys" {
    try std.testing.expectError(error.InvalidRecord, admission.normalizeNodeUintPropertyKey("task_created_ns"));
    try std.testing.expectError(error.InvalidRecord, admission.normalizeNodeUintPropertyKey("task_completed_ns"));
}

test "governed node admission bounds text and aggregate metadata" {
    const too_long_text = "x" ** (admission.node_text_char_limit + 1);
    try std.testing.expectError(error.NodeTextTooLarge, admission.validateNodeTextGranularity(too_long_text));
    const metadata_field = "x" ** 5000;
    try std.testing.expectError(error.NodePropertyTooLarge, admission.validateNodeLlmMetadataGranularity(
        metadata_field,
        metadata_field,
        metadata_field,
    ));
}

test "governed node admission recognizes task metric ownership" {
    try std.testing.expect(admission.nodeGovernanceNeedsTaskMetricTimestamp("task", "task"));
    try std.testing.expect(admission.nodeGovernanceNeedsTaskMetricTimestamp("observation", "verification"));
    try std.testing.expect(!admission.nodeGovernanceNeedsTaskMetricTimestamp("observation", "observation"));
}
