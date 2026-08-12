const std = @import("std");
const core = @import("../core.zig");
const graph = @import("../graph.zig");
const storage = @import("../storage.zig");
const task = @import("../task.zig");
const text_search = @import("../text.zig");

const NativeJsonlImportResult = struct {
    nodes_loaded: usize = 0,
    nodes_imported: usize = 0,
    edges_loaded: usize = 0,
    edges_imported: usize = 0,
    deferred_based_on_loaded: usize = 0,
    deferred_based_on_imported: usize = 0,
    jsonl_bytes: u64 = 0,
    text_warmed: bool = false,
    marker_cleanup_pending: bool = false,
};

const NativeJsonlExportResult = struct {
    nodes_exported: usize = 0,
    edges_exported: usize = 0,
    deferred_based_on_exported: usize = 0,
    jsonl_bytes: u64 = 0,
    cleanup_pending: bool = false,
};

const MarkdownImportResult = struct {
    nodes_loaded: usize = 0,
    nodes_imported: usize = 0,
    edges_loaded: usize = 0,
    edges_imported: usize = 0,
    deferred_based_on_loaded: usize = 0,
    deferred_based_on_imported: usize = 0,
    markdown_bytes: u64 = 0,
    text_warmed: bool = false,
    marker_cleanup_pending: bool = false,
};

const MarkdownExportResult = struct {
    nodes_exported: usize = 0,
    edges_exported: usize = 0,
    deferred_based_on_exported: usize = 0,
    markdown_bytes: u64 = 0,
    cleanup_pending: bool = false,
};

const NativeJsonlNodeJson = struct {
    id: u64,
    kind: []const u8,
    text: []const u8,
    schema_type: ?[]const u8 = null,
    status: ?[]const u8 = null,
    claimed_by: ?[]const u8 = null,
    claim_expires_ns: ?u64 = null,
    task_recorded_ns: ?u64 = null,
    task_created_ns: ?u64 = null,
    task_completed_ns: ?u64 = null,
};

const NativeJsonlEdgeJson = struct {
    id: u64,
    src: u64,
    rel: []const u8,
    dst: u64,
};

const NativeJsonlDeferredBasedOnJson = struct {
    src: u64,
    dst: u64,
};

const ImportPublicationResultView = struct {
    nodes_loaded: u64 = 0,
    nodes_imported: u64 = 0,
    edges_loaded: u64 = 0,
    edges_imported: u64 = 0,
    edges_skipped_missing_endpoint: u64 = 0,
    deferred_based_on_loaded: u64 = 0,
    deferred_based_on_imported: u64 = 0,
    source_bytes: u64 = 0,
    text_warmed: bool = false,
};

fn importPublicationMatchesSourceView(actual: ImportPublicationResultView, expected: ImportPublicationResultView) bool {
    return std.meta.eql(actual, expected);
}

fn updateSourceDigest(hasher: *std.crypto.hash.sha2.Sha256, label: []const u8, bytes: []const u8) void {
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, @intCast(label.len), .little);
    hasher.update(&len_buf);
    hasher.update(label);
    std.mem.writeInt(u64, &len_buf, @intCast(bytes.len), .little);
    hasher.update(&len_buf);
    hasher.update(bytes);
}

fn exportedClaimExpiry(status: task.Status, stored_expiry: u64) u64 {
    return if (status == .claimed) stored_expiry else 0;
}

fn normalizedAuditSchemaType(legacy_closed_task: bool, schema_type: ?[]const u8) ?[]const u8 {
    if (!legacy_closed_task) return schema_type;
    const value = schema_type orelse return "task";
    if (std.mem.eql(u8, value, "verification") or std.mem.eql(u8, value, "fix")) return "task";
    return value;
}

/// Native JSONL and Markdown whole-Store interchange data plane. Command
/// syntax and result rendering stay in store_interchange_commands; shared
/// locking, durable filesystem primitives and reusable codecs enter through
/// grouped Ops capabilities owned by the CLI root.
pub fn StoreInterchangeDataPlane(comptime Ops: type) type {
    return struct {
        const QueryOutputWriter = Ops.OutputWriter;
        const JsonlLineFile = Ops.JsonlLineFileType;
        const MigrationPropertyBatch = Ops.PropertyBatch;
        const MetaknowDeferredBasedOnSidecarPairs = Ops.DeferredPairs;
        const ImportTransactionExpectation = Ops.ImportTransactionExpectationType;
        const ImportPublicationResult = Ops.ImportPublicationResultType;
        const CliStoreLock = Ops.PublishLock;

        const anyPathExists = Ops.anyPathExistsFn;
        const canonicalProspectivePath = Ops.canonicalProspectivePathFn;
        const createOwnedDirectory = Ops.createOwnedDirectoryFn;
        const exportBackupPath = Ops.exportBackupPathFn;
        const exportTemporaryPath = Ops.exportTemporaryPathFn;
        const fileExists = Ops.fileExistsFn;
        const finalizeContentDigest = Ops.finalizeContentDigestFn;
        const importPublicationMatchesSource = Ops.importPublicationMatchesSourceFn;
        const importStagingPath = Ops.importStagingPathFn;
        const isDeletedNodeTombstone = Ops.isDeletedNodeTombstoneFn;
        const listMarkdownFilesRecursiveSorted = Ops.listMarkdownFilesRecursiveSortedFn;
        const loadJsonlLineFile = Ops.loadJsonlLineFileFn;
        const nodeKindNameAlloc = Ops.nodeKindNameAllocFn;
        const normalizeMetaknowDeferredBasedOnPairs = Ops.normalizeDeferredPairsFn;
        const parseCliNodeKind = Ops.parseNodeKindFn;
        const parseCliRelKind = Ops.parseRelKindFn;
        const pathsOverlap = Ops.pathsOverlapFn;
        const persistentNowNs = Ops.persistentNowNsFn;
        const publishExportDirectory = Ops.publishExportDirectoryFn;
        const publishImportedStore = Ops.publishImportedStoreFn;
        const readMetaknowDeferredBasedOnSidecarForwardPairs = Ops.readDeferredPairsFn;
        const recoverCompletedImport = Ops.recoverCompletedImportFn;
        const recoverExportPublication = Ops.recoverExportPublicationFn;
        const recoverImportStaging = Ops.recoverImportStagingFn;
        const relKindNameAlloc = Ops.relKindNameAllocFn;
        const restoreMetaknowDeferredBasedOnSidecar = Ops.restoreDeferredPairsFn;
        const syncExportDirectoryTree = Ops.syncExportDirectoryTreeFn;
        const u128ToU64 = Ops.u128ToU64Fn;
        const updateImportDigest = Ops.updateImportDigestFn;
        const validateGovernanceMetadataToken = Ops.validateMetadataTokenFn;
        const writeExportTransactionMarker = Ops.writeExportTransactionMarkerFn;
        const writeImportTransactionMarker = Ops.writeImportTransactionMarkerFn;
        const writeJsonString = Ops.writeJsonStringFn;
        const writeMarkdownInlineText = Ops.writeMarkdownInlineTextFn;
        const writeStoreManifest = Ops.writeStoreManifestFn;

        const import_publish_lock_suffix = ".tinykg-import.lock";
        const export_publish_lock_suffix = ".tinykg-export.lock";
        const native_jsonl_max_bytes: u64 = 256 * 1024 * 1024;
        const native_jsonl_export_buffer_bytes: usize = 1024 * 1024;
        const native_jsonl_deferred_based_on_file = "deferred_based_on.jsonl";
        const native_markdown_max_bytes: u64 = 512 * 1024 * 1024;
        const markdown_nodes_dir = "nodes";
        const markdown_edges_file = "edges.md";
        const markdown_relations_dir = "relations";
        const markdown_deferred_based_on_file = "deferred_based_on.md";
        const markdown_readme_file = "README.md";

        const RawTaskLifecycleFields = struct {
            status: ?[]const u8 = null,
            claimed_by: ?[]const u8 = null,
            claim_expires_ns: ?u64 = null,
            task_recorded_ns: ?u64 = null,
            task_created_ns: ?u64 = null,
            task_completed_ns: ?u64 = null,

            fn anyPresent(self: RawTaskLifecycleFields) bool {
                return self.status != null or self.claimed_by != null or self.claim_expires_ns != null or
                    self.task_recorded_ns != null or self.task_created_ns != null or self.task_completed_ns != null;
            }
        };

        const ImportedTaskLifecycle = struct {
            node_id: core.NodeId,
            status: task.Status,
            claimed_by: ?[]u8 = null,
            claim_expires_ns: ?u64 = null,
            task_recorded_ns: ?u64 = null,
            task_created_ns: ?u64 = null,
            task_completed_ns: ?u64 = null,

            pub fn deinit(self: *ImportedTaskLifecycle, allocator: std.mem.Allocator) void {
                if (self.claimed_by) |value| allocator.free(value);
                self.* = undefined;
            }
        };

        pub fn parseImportedTaskLifecycle(
            allocator: std.mem.Allocator,
            node_id: core.NodeId,
            kind: core.NodeKind,
            raw: RawTaskLifecycleFields,
            now_ns: u64,
        ) !?ImportedTaskLifecycle {
            if (kind != .task) {
                if (raw.anyPresent()) return error.InvalidRecord;
                return null;
            }

            const lifecycle_fields: task.StatusSnapshot.LifecycleFields = .{
                .stored_status_raw = raw.status,
                .claimed_by = raw.claimed_by,
                .claim_expires_ns = raw.claim_expires_ns,
                .task_recorded_ns = raw.task_recorded_ns,
                .task_created_ns = raw.task_created_ns,
                .task_completed_ns = raw.task_completed_ns,
            };
            const lifecycle = task.effectiveStatusForLifecycleFields(lifecycle_fields, now_ns, .strict) catch
                return error.InvalidRecord;
            var normalized_claim_expires_ns = raw.claim_expires_ns;
            if (lifecycle.isTerminal()) {
                // Terminal status is the commit marker. A crash may leave a formerly
                // live lease behind, but that lease is semantically inactive and must
                // not make a valid exported task impossible to import.
                if (normalized_claim_expires_ns != null) normalized_claim_expires_ns = 0;
            } else if (lifecycle == .open) {
                if (normalized_claim_expires_ns != null) normalized_claim_expires_ns = 0;
            }

            return .{
                .node_id = node_id,
                .status = lifecycle,
                .claimed_by = if (raw.claimed_by) |value| try allocator.dupe(u8, value) else null,
                .claim_expires_ns = normalized_claim_expires_ns,
                .task_recorded_ns = raw.task_recorded_ns,
                .task_created_ns = raw.task_created_ns,
                .task_completed_ns = raw.task_completed_ns,
            };
        }

        fn appendImportedTaskLifecycle(batch: *MigrationPropertyBatch, lifecycle: ImportedTaskLifecycle) !void {
            const owner: storage.PropertyOwner = .{ .node = lifecycle.node_id };
            try batch.appendString(owner, task.status_property, @tagName(lifecycle.status));
            if (lifecycle.claimed_by) |value| try batch.appendString(owner, task.claimed_by_property, value);
            if (lifecycle.claim_expires_ns) |value| try batch.appendUint(owner, task.claim_expires_ns_property, value);
            if (lifecycle.task_recorded_ns) |value| try batch.appendUint(owner, "task_recorded_ns", value);
            if (lifecycle.task_created_ns) |value| try batch.appendUint(owner, "task_created_ns", value);
            if (lifecycle.task_completed_ns) |value| try batch.appendUint(owner, "task_completed_ns", value);
        }

        const MarkdownNodeAuditPath = struct {
            scope: []u8,
            schema_type: []u8,
            kind: []u8,
            title: []u8,
            file_name: []u8,

            pub fn deinit(self: MarkdownNodeAuditPath, allocator: std.mem.Allocator) void {
                allocator.free(self.scope);
                allocator.free(self.schema_type);
                allocator.free(self.kind);
                allocator.free(self.title);
                allocator.free(self.file_name);
            }
        };

        fn markdownNodeAuditPath(allocator: std.mem.Allocator, node: storage.StoredNode, kind_label: []const u8, schema_type_override: ?[]const u8) !MarkdownNodeAuditPath {
            const scope_label: []const u8 = "_unmanaged";
            const schema_label: []const u8 = schema_type_override orelse "_unspecified";

            const scope = try sanitizeMarkdownPathComponent(allocator, scope_label);
            errdefer allocator.free(scope);
            const schema_type = try sanitizeMarkdownPathComponent(allocator, schema_label);
            errdefer allocator.free(schema_type);
            const kind = try sanitizeMarkdownPathComponent(allocator, kind_label);
            errdefer allocator.free(kind);
            const title = try markdownNodeTitleAlloc(allocator, node.text);
            errdefer allocator.free(title);
            const slug = try markdownSlugAlloc(allocator, title);
            defer allocator.free(slug);
            const file_name = try std.fmt.allocPrint(allocator, "{d:0>20}-{s}.md", .{ node.id.toInt(), slug });
            errdefer allocator.free(file_name);
            return .{
                .scope = scope,
                .schema_type = schema_type,
                .kind = kind,
                .title = title,
                .file_name = file_name,
            };
        }

        fn sanitizeMarkdownPathComponent(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
            const slug = try markdownSlugAlloc(allocator, value);
            if (std.mem.eql(u8, slug, "node")) {
                allocator.free(slug);
                return allocator.dupe(u8, "_");
            }
            return slug;
        }

        fn markdownNodeTitleAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
            if (try markdownQuotedFieldAlloc(allocator, text, "title=\"")) |title| {
                if (std.mem.trim(u8, title, " \t\r\n").len != 0) return title;
                allocator.free(title);
            }
            const line_end = std.mem.indexOfAny(u8, text, "\r\n") orelse text.len;
            const base = std.mem.trim(u8, text[0..line_end], " \t\r\n");
            if (base.len == 0) return allocator.dupe(u8, "node");
            const end = utf8PrefixLen(base, 96);
            return allocator.dupe(u8, base[0..end]);
        }

        fn markdownSlugAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(allocator);
            var previous_dash = false;
            var index: usize = 0;
            while (index < value.len) {
                const start = index;
                const width = std.unicode.utf8ByteSequenceLength(value[index]) catch 1;
                if (index + width > value.len) break;
                index += width;
                const bytes = value[start..index];
                if (width > 1) {
                    if (out.items.len + bytes.len > 72) break;
                    try out.appendSlice(allocator, bytes);
                    previous_dash = false;
                    continue;
                }
                const byte = bytes[0];
                const append_byte: ?u8 = switch (byte) {
                    'a'...'z', 'A'...'Z', '0'...'9' => std.ascii.toLower(byte),
                    '.', '_' => byte,
                    else => '-',
                };
                if (append_byte) |candidate| {
                    if (candidate == '-') {
                        if (previous_dash) continue;
                        previous_dash = true;
                    } else {
                        previous_dash = false;
                    }
                    try out.append(allocator, candidate);
                    if (out.items.len >= 72) break;
                }
            }
            while (out.items.len != 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
            while (out.items.len != 0 and out.items[0] == '-') _ = out.orderedRemove(0);
            if (out.items.len == 0) try out.appendSlice(allocator, "node");
            return out.toOwnedSlice(allocator);
        }

        fn markdownQuotedFieldAlloc(allocator: std.mem.Allocator, text: []const u8, marker: []const u8) !?[]u8 {
            const marker_start = std.mem.indexOf(u8, text, marker) orelse return null;
            var index = marker_start + marker.len;
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(allocator);
            while (index < text.len) {
                const byte = text[index];
                index += 1;
                if (byte == '"') return try out.toOwnedSlice(allocator);
                if (byte == '\\' and index < text.len) {
                    const escaped = text[index];
                    index += 1;
                    try out.append(allocator, escaped);
                    continue;
                }
                try out.append(allocator, byte);
            }
            return null;
        }

        fn utf8PrefixLen(text: []const u8, max_bytes: usize) usize {
            var end: usize = 0;
            while (end < text.len and end < max_bytes) {
                const width = std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
                if (end + width > text.len or end + width > max_bytes) break;
                end += width;
            }
            return end;
        }

        const MarkdownRelationExportGroup = struct {
            rel_label: []u8,
            safe_rel: []u8,
            text: QueryOutputWriter,
            count: usize = 0,

            pub fn deinit(self: *MarkdownRelationExportGroup, allocator: std.mem.Allocator) void {
                allocator.free(self.rel_label);
                allocator.free(self.safe_rel);
                self.text.buffer.deinit(allocator);
            }
        };

        fn markdownRelationExportGroup(
            allocator: std.mem.Allocator,
            groups: *std.ArrayList(MarkdownRelationExportGroup),
            rel_label: []const u8,
        ) !*MarkdownRelationExportGroup {
            for (groups.items) |*group| {
                if (std.mem.eql(u8, group.rel_label, rel_label)) return group;
            }
            const owned_rel = try allocator.dupe(u8, rel_label);
            errdefer allocator.free(owned_rel);
            const safe_rel = try sanitizeMarkdownPathComponent(allocator, rel_label);
            errdefer allocator.free(safe_rel);
            var group = MarkdownRelationExportGroup{
                .rel_label = owned_rel,
                .safe_rel = safe_rel,
                .text = QueryOutputWriter{ .allocator = allocator },
            };
            errdefer group.text.buffer.deinit(allocator);
            try group.text.print("# Relation `{s}`\n\n", .{rel_label});
            try group.text.writeAll("Each edge is stored in the preceding `tinykg-edge` HTML comment.\n\n");
            try groups.append(allocator, group);
            return &groups.items[groups.items.len - 1];
        }

        fn isMarkdownNodeContent(content: []const u8) bool {
            const tinykg = markdownFrontmatterField(content, "tinykg") orelse return false;
            return std.mem.eql(u8, tinykg, "node");
        }

        const ParsedMarkdownNode = struct {
            node: graph.Node,
            schema_type: ?[]u8 = null,
            lifecycle: ?ImportedTaskLifecycle = null,
            owns_text: bool = true,

            pub fn deinit(self: *ParsedMarkdownNode, allocator: std.mem.Allocator) void {
                if (self.owns_text) allocator.free(self.node.text);
                if (self.schema_type) |value| allocator.free(value);
                if (self.lifecycle) |*lifecycle| lifecycle.deinit(allocator);
                self.* = undefined;
            }
        };

        fn parseMarkdownOptionalUint(content: []const u8, field: []const u8) !?u64 {
            const raw = markdownFrontmatterField(content, field) orelse return null;
            return std.fmt.parseInt(u64, raw, 10) catch return error.InvalidRecord;
        }

        fn parseMarkdownNode(allocator: std.mem.Allocator, content: []const u8, now_ns: u64) !ParsedMarkdownNode {
            if (!isMarkdownNodeContent(content)) return error.InvalidRecord;
            const id_text = markdownFrontmatterField(content, "id") orelse return error.InvalidRecord;
            const kind_text = markdownFrontmatterField(content, "kind") orelse return error.InvalidRecord;
            const text_json = markdownFrontmatterField(content, "text_json") orelse
                markdownFrontmatterField(content, "name_json") orelse
                return error.InvalidRecord;
            const id = try std.fmt.parseInt(u64, id_text, 10);
            if (id == 0 or id == std.math.maxInt(u64)) return core.Error.InvalidId;
            const kind = parseCliNodeKind(kind_text) orelse return error.InvalidNodeKind;
            const text_value = try parseMarkdownJsonStringAlloc(allocator, text_json);
            errdefer allocator.free(text_value);
            const schema_type = if (markdownFrontmatterField(content, "schema_type_json")) |raw|
                try parseMarkdownJsonStringAlloc(allocator, raw)
            else
                null;
            errdefer if (schema_type) |value| allocator.free(value);
            if (schema_type) |value| try validateGovernanceMetadataToken(value);
            const claimed_by = if (markdownFrontmatterField(content, "claimed_by_json")) |raw|
                try parseMarkdownJsonStringAlloc(allocator, raw)
            else
                null;
            defer if (claimed_by) |value| allocator.free(value);
            const node_id = core.NodeId.fromInt(id);
            const lifecycle = try parseImportedTaskLifecycle(allocator, node_id, kind, .{
                .status = markdownFrontmatterField(content, "status"),
                .claimed_by = claimed_by,
                .claim_expires_ns = try parseMarkdownOptionalUint(content, "claim_expires_ns"),
                .task_recorded_ns = try parseMarkdownOptionalUint(content, "task_recorded_ns"),
                .task_created_ns = try parseMarkdownOptionalUint(content, "task_created_ns"),
                .task_completed_ns = try parseMarkdownOptionalUint(content, "task_completed_ns"),
            }, now_ns);
            errdefer if (lifecycle) |value| {
                var owned = value;
                owned.deinit(allocator);
            };
            return .{
                .node = .{
                    .id = core.NodeId.fromInt(id),
                    .kind = kind,
                    .text = text_value,
                },
                .schema_type = schema_type,
                .lifecycle = lifecycle,
            };
        }

        fn markdownFrontmatterField(content: []const u8, field: []const u8) ?[]const u8 {
            if (!std.mem.startsWith(u8, content, "---\n")) return null;
            const body_start = "---\n".len;
            const end_rel = std.mem.indexOf(u8, content[body_start..], "\n---\n") orelse return null;
            const frontmatter = content[body_start .. body_start + end_rel];
            var lines = std.mem.splitScalar(u8, frontmatter, '\n');
            while (lines.next()) |line_raw| {
                const line = std.mem.trim(u8, line_raw, " \t\r");
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const key = std.mem.trim(u8, line[0..colon], " \t");
                if (!std.mem.eql(u8, key, field)) continue;
                return std.mem.trim(u8, line[colon + 1 ..], " \t");
            }
            return null;
        }

        fn parseMarkdownJsonStringAlloc(allocator: std.mem.Allocator, value_raw: []const u8) ![]u8 {
            const value = std.mem.trim(u8, value_raw, " \t\r\n");
            if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.InvalidRecord;
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(allocator);
            var index: usize = 1;
            while (index < value.len - 1) {
                const byte = value[index];
                index += 1;
                if (byte != '\\') {
                    if (byte < 0x20) return error.InvalidRecord;
                    try out.append(allocator, byte);
                    continue;
                }
                if (index >= value.len - 1) return error.InvalidRecord;
                const escaped = value[index];
                index += 1;
                switch (escaped) {
                    '"' => try out.append(allocator, '"'),
                    '\\' => try out.append(allocator, '\\'),
                    '/' => try out.append(allocator, '/'),
                    'b' => try out.append(allocator, 0x08),
                    'f' => try out.append(allocator, 0x0c),
                    'n' => try out.append(allocator, '\n'),
                    'r' => try out.append(allocator, '\r'),
                    't' => try out.append(allocator, '\t'),
                    'u' => {
                        if (index + 4 > value.len - 1) return error.InvalidRecord;
                        const codepoint = try parseJsonUnicodeEscape(value[index .. index + 4]);
                        index += 4;
                        if (codepoint >= 0xd800 and codepoint <= 0xdfff) return error.InvalidRecord;
                        var utf8_buf: [4]u8 = undefined;
                        const encoded = try std.unicode.utf8Encode(@intCast(codepoint), &utf8_buf);
                        try out.appendSlice(allocator, utf8_buf[0..encoded]);
                    },
                    else => return error.InvalidRecord,
                }
            }
            return out.toOwnedSlice(allocator);
        }

        fn parseJsonUnicodeEscape(hex: []const u8) !u21 {
            if (hex.len != 4) return error.InvalidRecord;
            var value: u21 = 0;
            for (hex) |byte| {
                const digit: u21 = switch (byte) {
                    '0'...'9' => byte - '0',
                    'a'...'f' => byte - 'a' + 10,
                    'A'...'F' => byte - 'A' + 10,
                    else => return error.InvalidRecord,
                };
                value = value * 16 + digit;
            }
            return value;
        }

        fn parseMarkdownEdges(allocator: std.mem.Allocator, content: []const u8, edges: *std.ArrayList(graph.Edge), loaded: *usize) !void {
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line_raw| {
                const json = markdownCommentJson(line_raw, "tinykg-edge") orelse continue;
                loaded.* += 1;
                var parsed = try std.json.parseFromSlice(NativeJsonlEdgeJson, allocator, json, .{
                    .ignore_unknown_fields = true,
                    .allocate = .alloc_always,
                });
                defer parsed.deinit();
                const rel = parseCliRelKind(parsed.value.rel) orelse return error.InvalidRelKind;
                try edges.append(allocator, .{
                    .id = core.EdgeId.fromInt(parsed.value.id),
                    .src = core.NodeId.fromInt(parsed.value.src),
                    .rel = rel,
                    .dst = core.NodeId.fromInt(parsed.value.dst),
                });
            }
        }

        fn parseMarkdownDeferredBasedOn(allocator: std.mem.Allocator, content: []const u8, deferred: *MetaknowDeferredBasedOnSidecarPairs, loaded: *usize) !void {
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line_raw| {
                const json = markdownCommentJson(line_raw, "tinykg-deferred-based-on") orelse continue;
                loaded.* += 1;
                var parsed = try std.json.parseFromSlice(NativeJsonlDeferredBasedOnJson, allocator, json, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                try deferred.pairs.append(allocator, .{ .src = parsed.value.src, .dst = parsed.value.dst });
            }
        }

        fn markdownCommentJson(line_raw: []const u8, tag: []const u8) ?[]const u8 {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (!std.mem.startsWith(u8, line, "<!-- ")) return null;
            if (!std.mem.endsWith(u8, line, " -->")) return null;
            var inner = line["<!-- ".len .. line.len - " -->".len];
            if (!std.mem.startsWith(u8, inner, tag)) return null;
            inner = inner[tag.len..];
            if (inner.len == 0 or inner[0] != ' ') return null;
            return std.mem.trim(u8, inner[1..], " \t");
        }

        fn appendJsonlBuffered(
            io: std.Io,
            file: *std.Io.File,
            buffer: *std.ArrayList(u8),
            allocator: std.mem.Allocator,
            offset: *u64,
            bytes: []const u8,
        ) !void {
            try buffer.appendSlice(allocator, bytes);
            if (buffer.items.len >= native_jsonl_export_buffer_bytes) {
                try flushJsonlBuffer(io, file, buffer, offset);
            }
        }

        fn flushJsonlBuffer(io: std.Io, file: *std.Io.File, buffer: *std.ArrayList(u8), offset: *u64) !void {
            if (buffer.items.len == 0) return;
            try file.writePositionalAll(io, buffer.items, offset.*);
            offset.* = std.math.add(u64, offset.*, buffer.items.len) catch return error.RecordTooLarge;
            buffer.clearRetainingCapacity();
        }

        pub fn importNativeJsonlStore(
            allocator: std.mem.Allocator,
            io: std.Io,
            db_path: []const u8,
            dir_path: []const u8,
            warm_text: bool,
        ) !NativeJsonlImportResult {
            if (try pathsOverlap(allocator, io, db_path, dir_path)) return error.InvalidFileName;
            const nodes_path = try std.fs.path.join(allocator, &.{ dir_path, "nodes.jsonl" });
            defer allocator.free(nodes_path);
            const edges_path = try std.fs.path.join(allocator, &.{ dir_path, "edges.jsonl" });
            defer allocator.free(edges_path);
            const deferred_based_on_path = try std.fs.path.join(allocator, &.{ dir_path, native_jsonl_deferred_based_on_file });
            defer allocator.free(deferred_based_on_path);

            const node_lines = try loadJsonlLineFile(allocator, io, nodes_path, native_jsonl_max_bytes);
            defer node_lines.deinit(allocator);
            const edge_lines = try loadJsonlLineFile(allocator, io, edges_path, native_jsonl_max_bytes);
            defer edge_lines.deinit(allocator);
            var deferred_lines = if (try fileExists(io, deferred_based_on_path))
                try loadJsonlLineFile(allocator, io, deferred_based_on_path, native_jsonl_max_bytes)
            else
                JsonlLineFile{};
            defer deferred_lines.deinit(allocator);

            var result = NativeJsonlImportResult{
                .nodes_loaded = node_lines.records.len,
                .edges_loaded = edge_lines.records.len,
                .deferred_based_on_loaded = deferred_lines.records.len,
                .jsonl_bytes = @as(u64, @intCast(node_lines.bytes.len)) + @as(u64, @intCast(edge_lines.bytes.len)) + @as(u64, @intCast(deferred_lines.bytes.len)),
                .text_warmed = warm_text,
            };
            var source_hasher = std.crypto.hash.sha2.Sha256.init(.{});
            updateImportDigest(&source_hasher, "nodes.jsonl", node_lines.bytes);
            updateImportDigest(&source_hasher, "edges.jsonl", edge_lines.bytes);
            updateImportDigest(&source_hasher, native_jsonl_deferred_based_on_file, deferred_lines.bytes);
            const canonical_source_path = try canonicalProspectivePath(allocator, io, dir_path);
            defer allocator.free(canonical_source_path);
            const import_expectation = ImportTransactionExpectation{
                .format = "jsonl",
                .canonical_source_path = canonical_source_path,
                .source_digest = finalizeContentDigest(&source_hasher),
                .warm_text = warm_text,
            };

            var nodes = std.ArrayList(graph.Node).empty;
            defer {
                for (nodes.items) |node| allocator.free(node.text);
                nodes.deinit(allocator);
            }
            try nodes.ensureTotalCapacityPrecise(allocator, node_lines.records.len);
            var task_lifecycles = std.ArrayList(ImportedTaskLifecycle).empty;
            defer {
                for (task_lifecycles.items) |*lifecycle| lifecycle.deinit(allocator);
                task_lifecycles.deinit(allocator);
            }
            try task_lifecycles.ensureTotalCapacity(allocator, node_lines.records.len);
            var imported_properties = MigrationPropertyBatch.init(allocator);
            defer imported_properties.deinit();
            const import_now_ns = try u128ToU64(persistentNowNs(io));
            var node_ids = std.AutoHashMap(u64, void).init(allocator);
            defer node_ids.deinit();
            try node_ids.ensureTotalCapacity(@intCast(node_lines.records.len));
            for (node_lines.records) |line| {
                var parsed = try std.json.parseFromSlice(NativeJsonlNodeJson, allocator, line, .{
                    .ignore_unknown_fields = true,
                    .allocate = .alloc_always,
                });
                defer parsed.deinit();
                const kind = parseCliNodeKind(parsed.value.kind) orelse return error.InvalidNodeKind;
                if (parsed.value.id == 0 or parsed.value.id == std.math.maxInt(u64)) return core.Error.InvalidId;
                const node_entry = try node_ids.getOrPut(parsed.value.id);
                if (node_entry.found_existing) return core.Error.InvalidId;
                const text = try allocator.dupe(u8, parsed.value.text);
                errdefer allocator.free(text);
                nodes.appendAssumeCapacity(.{
                    .id = core.NodeId.fromInt(parsed.value.id),
                    .kind = kind,
                    .text = text,
                });
                if (parsed.value.schema_type) |schema_type| {
                    try validateGovernanceMetadataToken(schema_type);
                    try imported_properties.appendString(.{ .node = .fromInt(parsed.value.id) }, "schema_type", schema_type);
                }
                const lifecycle = try parseImportedTaskLifecycle(allocator, core.NodeId.fromInt(parsed.value.id), kind, .{
                    .status = parsed.value.status,
                    .claimed_by = parsed.value.claimed_by,
                    .claim_expires_ns = parsed.value.claim_expires_ns,
                    .task_recorded_ns = parsed.value.task_recorded_ns,
                    .task_created_ns = parsed.value.task_created_ns,
                    .task_completed_ns = parsed.value.task_completed_ns,
                }, import_now_ns);
                if (lifecycle) |value| {
                    var owned = value;
                    errdefer owned.deinit(allocator);
                    try task_lifecycles.append(allocator, owned);
                }
            }

            var edges = std.ArrayList(graph.Edge).empty;
            defer edges.deinit(allocator);
            try edges.ensureTotalCapacityPrecise(allocator, edge_lines.records.len);
            var edge_ids = std.AutoHashMap(u64, void).init(allocator);
            defer edge_ids.deinit();
            try edge_ids.ensureTotalCapacity(@intCast(edge_lines.records.len));
            for (edge_lines.records) |line| {
                var parsed = try std.json.parseFromSlice(NativeJsonlEdgeJson, allocator, line, .{
                    .ignore_unknown_fields = true,
                    .allocate = .alloc_always,
                });
                defer parsed.deinit();
                const rel = parseCliRelKind(parsed.value.rel) orelse return error.InvalidRelKind;
                if (parsed.value.id == 0 or parsed.value.id == std.math.maxInt(u64)) return core.Error.InvalidId;
                if (parsed.value.src == 0 or parsed.value.dst == 0 or parsed.value.src == std.math.maxInt(u64) or parsed.value.dst == std.math.maxInt(u64)) return core.Error.InvalidId;
                const edge_entry = try edge_ids.getOrPut(parsed.value.id);
                if (edge_entry.found_existing) return core.Error.InvalidId;
                if (!node_ids.contains(parsed.value.src) or !node_ids.contains(parsed.value.dst)) return core.Error.NotFound;
                edges.appendAssumeCapacity(.{
                    .id = core.EdgeId.fromInt(parsed.value.id),
                    .src = core.NodeId.fromInt(parsed.value.src),
                    .rel = rel,
                    .dst = core.NodeId.fromInt(parsed.value.dst),
                });
            }

            var deferred_based_on = MetaknowDeferredBasedOnSidecarPairs{ .present = deferred_lines.records.len != 0 };
            defer deferred_based_on.deinit(allocator);
            try deferred_based_on.pairs.ensureTotalCapacity(allocator, deferred_lines.records.len);
            for (deferred_lines.records) |line| {
                var parsed = try std.json.parseFromSlice(NativeJsonlDeferredBasedOnJson, allocator, line, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                if (parsed.value.src == 0 or parsed.value.dst == 0 or parsed.value.src == std.math.maxInt(u64) or parsed.value.dst == std.math.maxInt(u64)) return core.Error.InvalidId;
                if (!node_ids.contains(parsed.value.src) or !node_ids.contains(parsed.value.dst)) return core.Error.NotFound;
                deferred_based_on.pairs.appendAssumeCapacity(.{
                    .src = parsed.value.src,
                    .dst = parsed.value.dst,
                });
            }
            normalizeMetaknowDeferredBasedOnPairs(&deferred_based_on);

            const expected_publication_result = ImportPublicationResult{
                .nodes_loaded = @intCast(result.nodes_loaded),
                .nodes_imported = @intCast(nodes.items.len),
                .edges_loaded = @intCast(result.edges_loaded),
                .edges_imported = @intCast(edges.items.len),
                .deferred_based_on_loaded = @intCast(result.deferred_based_on_loaded),
                .deferred_based_on_imported = @intCast(deferred_based_on.pairs.items.len),
                .source_bytes = result.jsonl_bytes,
                .text_warmed = result.text_warmed,
            };

            const publish_lock = try CliStoreLock.acquireAdjacent(allocator, io, db_path, import_publish_lock_suffix);
            defer publish_lock.deinit();
            const staging_path = try importStagingPath(allocator, db_path);
            defer allocator.free(staging_path);
            try recoverImportStaging(allocator, io, staging_path, import_expectation, expected_publication_result);
            if (try recoverCompletedImport(allocator, io, db_path, import_expectation, expected_publication_result)) |recovered| {
                return .{
                    .nodes_loaded = std.math.cast(usize, recovered.nodes_loaded) orelse return error.InvalidRecord,
                    .nodes_imported = std.math.cast(usize, recovered.nodes_imported) orelse return error.InvalidRecord,
                    .edges_loaded = std.math.cast(usize, recovered.edges_loaded) orelse return error.InvalidRecord,
                    .edges_imported = std.math.cast(usize, recovered.edges_imported) orelse return error.InvalidRecord,
                    .deferred_based_on_loaded = std.math.cast(usize, recovered.deferred_based_on_loaded) orelse return error.InvalidRecord,
                    .deferred_based_on_imported = std.math.cast(usize, recovered.deferred_based_on_imported) orelse return error.InvalidRecord,
                    .jsonl_bytes = recovered.source_bytes,
                    .text_warmed = recovered.text_warmed,
                    .marker_cleanup_pending = recovered.marker_cleanup_pending,
                };
            }
            if (try anyPathExists(io, db_path)) return error.AlreadyExists;
            try createOwnedDirectory(io, staging_path);
            var staging_owned = true;
            defer if (staging_owned) std.Io.Dir.cwd().deleteTree(io, staging_path) catch {};
            try writeImportTransactionMarker(allocator, io, staging_path, import_expectation, null);
            try syncExportDirectoryTree(allocator, io, staging_path);
            var store = try storage.Store.initWithOptions(allocator, io, staging_path, .{
                .primary_text_write_mode = .bulk_ingest,
            });
            var store_open = true;
            defer {
                if (store_open) store.deinit();
            }
            try store.createEmpty();
            try store.appendNodesBatch(nodes.items);
            try store.finalizePrimaryTextStorage();
            result.nodes_imported = nodes.items.len;
            for (task_lifecycles.items) |lifecycle| try appendImportedTaskLifecycle(&imported_properties, lifecycle);
            if (imported_properties.writes.items.len != 0) try store.appendPropertiesBatch(allocator, imported_properties.writes.items);
            try store.appendEdgesBatch(edges.items);
            result.edges_imported = edges.items.len;
            if (deferred_based_on.present) {
                try restoreMetaknowDeferredBasedOnSidecar(allocator, store, &deferred_based_on);
                result.deferred_based_on_imported = deferred_based_on.pairs.items.len;
            }

            if (warm_text) {
                _ = try text_search.rebuildPersistentTextCatalog(allocator, store);
            }
            try writeStoreManifest(allocator, io, staging_path, .{
                .profiles = "",
                .migration_name = "import-jsonl",
            });
            store.deinit();
            store_open = false;
            var publication_result = ImportPublicationResult{
                .nodes_loaded = @intCast(result.nodes_loaded),
                .nodes_imported = @intCast(result.nodes_imported),
                .edges_loaded = @intCast(result.edges_loaded),
                .edges_imported = @intCast(result.edges_imported),
                .deferred_based_on_loaded = @intCast(result.deferred_based_on_loaded),
                .deferred_based_on_imported = @intCast(result.deferred_based_on_imported),
                .source_bytes = result.jsonl_bytes,
                .text_warmed = result.text_warmed,
            };
            if (!importPublicationMatchesSource(publication_result, expected_publication_result)) return error.InvalidRecord;
            try publishImportedStore(allocator, io, staging_path, db_path, import_expectation, &publication_result);
            staging_owned = false;
            result.marker_cleanup_pending = publication_result.marker_cleanup_pending;
            return result;
        }

        pub fn exportNativeJsonlStore(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            dir_path: []const u8,
        ) !NativeJsonlExportResult {
            if (try pathsOverlap(allocator, io, store.dir_path, dir_path)) return error.InvalidFileName;
            const publish_lock = try CliStoreLock.acquireAdjacent(allocator, io, dir_path, export_publish_lock_suffix);
            defer publish_lock.deinit();
            const staging_path = try exportTemporaryPath(allocator, io, dir_path, "tmp");
            defer allocator.free(staging_path);
            const backup_path = try exportBackupPath(allocator, dir_path);
            defer allocator.free(backup_path);
            const recovery = try recoverExportPublication(allocator, io, dir_path, backup_path);
            if (try anyPathExists(io, backup_path)) {
                if (recovery == .recovered_cleanup_pending) return error.ExportCleanupPending;
                return error.AlreadyExists;
            }
            if (try anyPathExists(io, staging_path)) return error.AlreadyExists;

            var result = try exportNativeJsonlStoreIntoDirectory(allocator, io, store, staging_path);
            // The helper transfers ownership only after the exclusive create and a
            // complete export.  Installing cleanup any earlier could delete a
            // directory created by another process after our preflight.
            errdefer std.Io.Dir.cwd().deleteTree(io, staging_path) catch {};
            try writeExportTransactionMarker(allocator, io, staging_path);
            try syncExportDirectoryTree(allocator, io, staging_path);
            result.cleanup_pending = try publishExportDirectory(allocator, io, staging_path, dir_path, backup_path);
            return result;
        }

        pub fn exportNativeJsonlStoreIntoDirectory(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            dir_path: []const u8,
        ) !NativeJsonlExportResult {
            try createOwnedDirectory(io, dir_path);
            var export_complete = false;
            defer if (!export_complete) std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};
            const nodes_path = try std.fs.path.join(allocator, &.{ dir_path, "nodes.jsonl" });
            defer allocator.free(nodes_path);
            const edges_path = try std.fs.path.join(allocator, &.{ dir_path, "edges.jsonl" });
            defer allocator.free(edges_path);
            const deferred_based_on_path = try std.fs.path.join(allocator, &.{ dir_path, native_jsonl_deferred_based_on_file });
            defer allocator.free(deferred_based_on_path);

            var node_file = try std.Io.Dir.cwd().createFile(io, nodes_path, .{ .truncate = true });
            defer node_file.close(io);
            var edge_file = try std.Io.Dir.cwd().createFile(io, edges_path, .{ .truncate = true });
            defer edge_file.close(io);
            var deferred_file: ?std.Io.File = null;
            defer if (deferred_file) |file| file.close(io);

            var result = NativeJsonlExportResult{};
            var line = QueryOutputWriter{ .allocator = allocator };
            defer line.buffer.deinit(allocator);
            var node_buffer = std.ArrayList(u8).empty;
            defer node_buffer.deinit(allocator);
            var edge_buffer = std.ArrayList(u8).empty;
            defer edge_buffer.deinit(allocator);
            var deferred_buffer = std.ArrayList(u8).empty;
            defer deferred_buffer.deinit(allocator);
            var node_file_offset: u64 = 0;
            var edge_file_offset: u64 = 0;
            var deferred_file_offset: u64 = 0;
            const export_now_ns = try u128ToU64(persistentNowNs(io));
            var status_snapshot = try task.StatusSnapshot.init(allocator, store);
            defer status_snapshot.deinit();

            var node_iter = try store.nodeRecordsIterator(null);
            defer node_iter.deinit();
            while (try node_iter.next(allocator)) |stored_node| {
                var node = stored_node;
                defer node.deinit(allocator);
                if (isDeletedNodeTombstone(node)) continue;
                const legacy_closed_task = status_snapshot.isLegacyClosedTaskNode(node);
                const export_kind: core.NodeKind = if (legacy_closed_task) .task else node.kind;
                line.buffer.clearRetainingCapacity();
                try line.print("{{\"id\":{},\"kind\":", .{node.id.toInt()});
                const kind_label = try nodeKindNameAlloc(allocator, export_kind);
                defer allocator.free(kind_label);
                try writeJsonString(&line, kind_label);
                try line.writeAll(",\"text\":");
                try writeJsonString(&line, node.text);
                const schema_type = try store.getNodeStringProperty(allocator, node.id, "schema_type");
                defer if (schema_type) |value| allocator.free(value);
                if (normalizedAuditSchemaType(legacy_closed_task, schema_type)) |value| {
                    try line.writeAll(",\"schema_type\":");
                    try writeJsonString(&line, value);
                }
                if (export_kind == .task) {
                    const lifecycle = try status_snapshot.statusForStoredNode(node, export_now_ns);
                    const lifecycle_fields = status_snapshot.fields(node.id);
                    try line.writeAll(",\"status\":");
                    try writeJsonString(&line, @tagName(lifecycle));
                    if (lifecycle_fields.claimed_by) |value| {
                        try line.writeAll(",\"claimed_by\":");
                        try writeJsonString(&line, value);
                    }
                    if (lifecycle_fields.claim_expires_ns) |value| {
                        try line.print(",\"claim_expires_ns\":{}", .{exportedClaimExpiry(lifecycle, value)});
                    }
                    if (lifecycle_fields.task_recorded_ns) |value| try line.print(",\"task_recorded_ns\":{}", .{value});
                    if (lifecycle_fields.task_created_ns) |value| try line.print(",\"task_created_ns\":{}", .{value});
                    if (lifecycle_fields.task_completed_ns) |value| try line.print(",\"task_completed_ns\":{}", .{value});
                }
                try line.writeAll("}\n");
                try appendJsonlBuffered(io, &node_file, &node_buffer, allocator, &node_file_offset, line.buffer.items);
                result.jsonl_bytes += @intCast(line.buffer.items.len);
                result.nodes_exported += 1;
            }
            try flushJsonlBuffer(io, &node_file, &node_buffer, &node_file_offset);

            const EdgeExportContext = struct {
                allocator: std.mem.Allocator,
                io: std.Io,
                file: *std.Io.File,
                buffer: *std.ArrayList(u8),
                file_offset: *u64,
                line: *QueryOutputWriter,
                result: *NativeJsonlExportResult,

                fn visit(raw_context: *anyopaque, edge: storage.EdgeIndexRecord) anyerror!void {
                    const context: *@This() = @ptrCast(@alignCast(raw_context));
                    context.line.buffer.clearRetainingCapacity();
                    try context.line.print("{{\"id\":{},\"src\":{},\"rel\":", .{ edge.edge_id, edge.src });
                    const rel_label = try relKindNameAlloc(context.allocator, try edge.relKind());
                    defer context.allocator.free(rel_label);
                    try writeJsonString(context.line, rel_label);
                    try context.line.print(",\"dst\":{}}}\n", .{edge.dst});
                    try appendJsonlBuffered(context.io, context.file, context.buffer, context.allocator, context.file_offset, context.line.buffer.items);
                    context.result.jsonl_bytes = std.math.add(u64, context.result.jsonl_bytes, context.line.buffer.items.len) catch return error.RecordTooLarge;
                    context.result.edges_exported = std.math.add(usize, context.result.edges_exported, 1) catch return error.RecordTooLarge;
                }
            };
            var edge_export_context = EdgeExportContext{
                .allocator = allocator,
                .io = io,
                .file = &edge_file,
                .buffer = &edge_buffer,
                .file_offset = &edge_file_offset,
                .line = &line,
                .result = &result,
            };
            _ = try store.scanVisibleEdgeIndexRecords(allocator, &edge_export_context, EdgeExportContext.visit);
            try flushJsonlBuffer(io, &edge_file, &edge_buffer, &edge_file_offset);

            var deferred_based_on = try readMetaknowDeferredBasedOnSidecarForwardPairs(allocator, io, store.dir_path);
            defer deferred_based_on.deinit(allocator);
            if (deferred_based_on.present and deferred_based_on.pairs.items.len != 0) {
                deferred_file = try std.Io.Dir.cwd().createFile(io, deferred_based_on_path, .{ .truncate = true });
                for (deferred_based_on.pairs.items) |pair| {
                    line.buffer.clearRetainingCapacity();
                    try line.print("{{\"src\":{},\"dst\":{}}}\n", .{ pair.src, pair.dst });
                    try appendJsonlBuffered(io, &deferred_file.?, &deferred_buffer, allocator, &deferred_file_offset, line.buffer.items);
                    result.jsonl_bytes += @intCast(line.buffer.items.len);
                    result.deferred_based_on_exported += 1;
                }
                try flushJsonlBuffer(io, &deferred_file.?, &deferred_buffer, &deferred_file_offset);
            } else {
                std.Io.Dir.cwd().deleteFile(io, deferred_based_on_path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
            }

            export_complete = true;
            return result;
        }

        pub fn importMarkdownStore(
            allocator: std.mem.Allocator,
            io: std.Io,
            db_path: []const u8,
            dir_path: []const u8,
            warm_text: bool,
        ) !MarkdownImportResult {
            if (try pathsOverlap(allocator, io, db_path, dir_path)) return error.InvalidFileName;
            const nodes_dir_path = try std.fs.path.join(allocator, &.{ dir_path, markdown_nodes_dir });
            defer allocator.free(nodes_dir_path);
            const edges_path = try std.fs.path.join(allocator, &.{ dir_path, markdown_edges_file });
            defer allocator.free(edges_path);
            const deferred_based_on_path = try std.fs.path.join(allocator, &.{ dir_path, markdown_deferred_based_on_file });
            defer allocator.free(deferred_based_on_path);

            var result = MarkdownImportResult{ .text_warmed = warm_text };
            var source_hasher = std.crypto.hash.sha2.Sha256.init(.{});

            var node_file_names = try listMarkdownFilesRecursiveSorted(allocator, io, nodes_dir_path);
            defer {
                for (node_file_names.items) |name| allocator.free(name);
                node_file_names.deinit(allocator);
            }

            var nodes = std.ArrayList(graph.Node).empty;
            defer {
                for (nodes.items) |node| allocator.free(node.text);
                nodes.deinit(allocator);
            }
            try nodes.ensureTotalCapacityPrecise(allocator, node_file_names.items.len);
            var task_lifecycles = std.ArrayList(ImportedTaskLifecycle).empty;
            defer {
                for (task_lifecycles.items) |*lifecycle| lifecycle.deinit(allocator);
                task_lifecycles.deinit(allocator);
            }
            try task_lifecycles.ensureTotalCapacity(allocator, node_file_names.items.len);
            var imported_properties = MigrationPropertyBatch.init(allocator);
            defer imported_properties.deinit();
            const import_now_ns = try u128ToU64(persistentNowNs(io));
            var node_ids = std.AutoHashMap(u64, void).init(allocator);
            defer node_ids.deinit();
            try node_ids.ensureTotalCapacity(@intCast(node_file_names.items.len));

            for (node_file_names.items) |file_name| {
                const node_path = try std.fs.path.join(allocator, &.{ nodes_dir_path, file_name });
                defer allocator.free(node_path);
                const content = try std.Io.Dir.cwd().readFileAlloc(io, node_path, allocator, .limited(native_markdown_max_bytes));
                defer allocator.free(content);
                result.markdown_bytes = std.math.add(u64, result.markdown_bytes, content.len) catch return error.RecordTooLarge;
                updateImportDigest(&source_hasher, file_name, content);
                if (!isMarkdownNodeContent(content)) continue;
                var parsed_node = try parseMarkdownNode(allocator, content, import_now_ns);
                errdefer parsed_node.deinit(allocator);
                const node_entry = try node_ids.getOrPut(parsed_node.node.id.toInt());
                if (node_entry.found_existing) {
                    return core.Error.InvalidId;
                }
                nodes.appendAssumeCapacity(parsed_node.node);
                parsed_node.owns_text = false;
                if (parsed_node.schema_type) |schema_type| {
                    try imported_properties.appendString(.{ .node = parsed_node.node.id }, "schema_type", schema_type);
                    allocator.free(schema_type);
                    parsed_node.schema_type = null;
                }
                if (parsed_node.lifecycle) |lifecycle| {
                    try task_lifecycles.append(allocator, lifecycle);
                    parsed_node.lifecycle = null;
                }
                result.nodes_loaded += 1;
            }

            var edges = std.ArrayList(graph.Edge).empty;
            defer edges.deinit(allocator);
            if (try fileExists(io, edges_path)) {
                const edges_text = try std.Io.Dir.cwd().readFileAlloc(io, edges_path, allocator, .limited(native_markdown_max_bytes));
                defer allocator.free(edges_text);
                result.markdown_bytes = std.math.add(u64, result.markdown_bytes, edges_text.len) catch return error.RecordTooLarge;
                updateImportDigest(&source_hasher, markdown_edges_file, edges_text);
                try parseMarkdownEdges(allocator, edges_text, &edges, &result.edges_loaded);
            } else {
                updateImportDigest(&source_hasher, markdown_edges_file, "");
            }
            const relations_dir_path = try std.fs.path.join(allocator, &.{ dir_path, markdown_relations_dir });
            defer allocator.free(relations_dir_path);
            if (try anyPathExists(io, relations_dir_path)) {
                var relation_file_names = try listMarkdownFilesRecursiveSorted(allocator, io, relations_dir_path);
                defer {
                    for (relation_file_names.items) |name| allocator.free(name);
                    relation_file_names.deinit(allocator);
                }
                for (relation_file_names.items) |file_name| {
                    const relation_path = try std.fs.path.join(allocator, &.{ relations_dir_path, file_name });
                    defer allocator.free(relation_path);
                    const relation_text = try std.Io.Dir.cwd().readFileAlloc(io, relation_path, allocator, .limited(native_markdown_max_bytes));
                    defer allocator.free(relation_text);
                    result.markdown_bytes = std.math.add(u64, result.markdown_bytes, relation_text.len) catch return error.RecordTooLarge;
                    updateImportDigest(&source_hasher, file_name, relation_text);
                    try parseMarkdownEdges(allocator, relation_text, &edges, &result.edges_loaded);
                }
            }
            var edge_ids = std.AutoHashMap(u64, void).init(allocator);
            defer edge_ids.deinit();
            try edge_ids.ensureTotalCapacity(@intCast(edges.items.len));
            for (edges.items) |edge| {
                const edge_id = edge.id.toInt();
                if (edge_id == 0 or edge_id == std.math.maxInt(u64)) return core.Error.InvalidId;
                if (edge.src.toInt() == 0 or edge.dst.toInt() == 0 or edge.src.toInt() == std.math.maxInt(u64) or edge.dst.toInt() == std.math.maxInt(u64)) return core.Error.InvalidId;
                const edge_entry = try edge_ids.getOrPut(edge_id);
                if (edge_entry.found_existing) return core.Error.InvalidId;
                if (!node_ids.contains(edge.src.toInt()) or !node_ids.contains(edge.dst.toInt())) return core.Error.NotFound;
            }

            var deferred_based_on = MetaknowDeferredBasedOnSidecarPairs{ .present = false };
            defer deferred_based_on.deinit(allocator);
            if (try fileExists(io, deferred_based_on_path)) {
                const deferred_text = try std.Io.Dir.cwd().readFileAlloc(io, deferred_based_on_path, allocator, .limited(native_markdown_max_bytes));
                defer allocator.free(deferred_text);
                result.markdown_bytes = std.math.add(u64, result.markdown_bytes, deferred_text.len) catch return error.RecordTooLarge;
                updateImportDigest(&source_hasher, markdown_deferred_based_on_file, deferred_text);
                try parseMarkdownDeferredBasedOn(allocator, deferred_text, &deferred_based_on, &result.deferred_based_on_loaded);
                deferred_based_on.present = result.deferred_based_on_loaded != 0;
                for (deferred_based_on.pairs.items) |pair| {
                    if (pair.src == 0 or pair.dst == 0 or pair.src == std.math.maxInt(u64) or pair.dst == std.math.maxInt(u64)) return core.Error.InvalidId;
                    if (!node_ids.contains(pair.src) or !node_ids.contains(pair.dst)) return core.Error.NotFound;
                }
                normalizeMetaknowDeferredBasedOnPairs(&deferred_based_on);
            } else {
                updateImportDigest(&source_hasher, markdown_deferred_based_on_file, "");
            }

            const canonical_source_path = try canonicalProspectivePath(allocator, io, dir_path);
            defer allocator.free(canonical_source_path);
            const import_expectation = ImportTransactionExpectation{
                .format = "markdown",
                .canonical_source_path = canonical_source_path,
                .source_digest = finalizeContentDigest(&source_hasher),
                .warm_text = warm_text,
            };
            const expected_publication_result = ImportPublicationResult{
                .nodes_loaded = @intCast(result.nodes_loaded),
                .nodes_imported = @intCast(nodes.items.len),
                .edges_loaded = @intCast(result.edges_loaded),
                .edges_imported = @intCast(edges.items.len),
                .deferred_based_on_loaded = @intCast(result.deferred_based_on_loaded),
                .deferred_based_on_imported = @intCast(deferred_based_on.pairs.items.len),
                .source_bytes = result.markdown_bytes,
                .text_warmed = result.text_warmed,
            };
            const publish_lock = try CliStoreLock.acquireAdjacent(allocator, io, db_path, import_publish_lock_suffix);
            defer publish_lock.deinit();
            const staging_path = try importStagingPath(allocator, db_path);
            defer allocator.free(staging_path);
            try recoverImportStaging(allocator, io, staging_path, import_expectation, expected_publication_result);
            if (try recoverCompletedImport(allocator, io, db_path, import_expectation, expected_publication_result)) |recovered| {
                return .{
                    .nodes_loaded = std.math.cast(usize, recovered.nodes_loaded) orelse return error.InvalidRecord,
                    .nodes_imported = std.math.cast(usize, recovered.nodes_imported) orelse return error.InvalidRecord,
                    .edges_loaded = std.math.cast(usize, recovered.edges_loaded) orelse return error.InvalidRecord,
                    .edges_imported = std.math.cast(usize, recovered.edges_imported) orelse return error.InvalidRecord,
                    .deferred_based_on_loaded = std.math.cast(usize, recovered.deferred_based_on_loaded) orelse return error.InvalidRecord,
                    .deferred_based_on_imported = std.math.cast(usize, recovered.deferred_based_on_imported) orelse return error.InvalidRecord,
                    .markdown_bytes = recovered.source_bytes,
                    .text_warmed = recovered.text_warmed,
                    .marker_cleanup_pending = recovered.marker_cleanup_pending,
                };
            }
            if (try anyPathExists(io, db_path)) return error.AlreadyExists;
            try createOwnedDirectory(io, staging_path);
            var staging_owned = true;
            defer if (staging_owned) std.Io.Dir.cwd().deleteTree(io, staging_path) catch {};
            try writeImportTransactionMarker(allocator, io, staging_path, import_expectation, null);
            try syncExportDirectoryTree(allocator, io, staging_path);
            var store = try storage.Store.initWithOptions(allocator, io, staging_path, .{
                .primary_text_write_mode = .bulk_ingest,
            });
            var store_open = true;
            defer {
                if (store_open) store.deinit();
            }
            try store.createEmpty();
            try store.appendNodesBatch(nodes.items);
            try store.finalizePrimaryTextStorage();
            result.nodes_imported = nodes.items.len;
            for (task_lifecycles.items) |lifecycle| try appendImportedTaskLifecycle(&imported_properties, lifecycle);
            if (imported_properties.writes.items.len != 0) try store.appendPropertiesBatch(allocator, imported_properties.writes.items);
            try store.appendEdgesBatch(edges.items);
            result.edges_imported = edges.items.len;
            if (deferred_based_on.present) {
                try restoreMetaknowDeferredBasedOnSidecar(allocator, store, &deferred_based_on);
                result.deferred_based_on_imported = deferred_based_on.pairs.items.len;
            }
            if (warm_text) {
                _ = try text_search.rebuildPersistentTextCatalog(allocator, store);
            }
            try writeStoreManifest(allocator, io, staging_path, .{
                .profiles = "",
                .migration_name = "import-markdown",
            });
            store.deinit();
            store_open = false;
            var publication_result = ImportPublicationResult{
                .nodes_loaded = @intCast(result.nodes_loaded),
                .nodes_imported = @intCast(result.nodes_imported),
                .edges_loaded = @intCast(result.edges_loaded),
                .edges_imported = @intCast(result.edges_imported),
                .deferred_based_on_loaded = @intCast(result.deferred_based_on_loaded),
                .deferred_based_on_imported = @intCast(result.deferred_based_on_imported),
                .source_bytes = result.markdown_bytes,
                .text_warmed = result.text_warmed,
            };
            if (!importPublicationMatchesSource(publication_result, expected_publication_result)) return error.InvalidRecord;
            try publishImportedStore(allocator, io, staging_path, db_path, import_expectation, &publication_result);
            staging_owned = false;
            result.marker_cleanup_pending = publication_result.marker_cleanup_pending;
            return result;
        }

        pub fn exportMarkdownStore(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            dir_path: []const u8,
        ) !MarkdownExportResult {
            if (try pathsOverlap(allocator, io, store.dir_path, dir_path)) return error.InvalidFileName;
            const publish_lock = try CliStoreLock.acquireAdjacent(allocator, io, dir_path, export_publish_lock_suffix);
            defer publish_lock.deinit();
            const staging_path = try exportTemporaryPath(allocator, io, dir_path, "tmp");
            defer allocator.free(staging_path);
            const backup_path = try exportBackupPath(allocator, dir_path);
            defer allocator.free(backup_path);
            const recovery = try recoverExportPublication(allocator, io, dir_path, backup_path);
            if (try anyPathExists(io, backup_path)) {
                if (recovery == .recovered_cleanup_pending) return error.ExportCleanupPending;
                return error.AlreadyExists;
            }
            if (try anyPathExists(io, staging_path)) return error.AlreadyExists;

            var result = try exportMarkdownStoreIntoDirectory(allocator, io, store, staging_path);
            // See the JSONL path above: cleanup begins only after this process owns a
            // fully materialized staging directory.
            errdefer std.Io.Dir.cwd().deleteTree(io, staging_path) catch {};
            try writeExportTransactionMarker(allocator, io, staging_path);
            try syncExportDirectoryTree(allocator, io, staging_path);
            result.cleanup_pending = try publishExportDirectory(allocator, io, staging_path, dir_path, backup_path);
            return result;
        }

        pub fn exportMarkdownStoreIntoDirectory(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            dir_path: []const u8,
        ) !MarkdownExportResult {
            try createOwnedDirectory(io, dir_path);
            var export_complete = false;
            defer if (!export_complete) std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};
            const nodes_dir_path = try std.fs.path.join(allocator, &.{ dir_path, markdown_nodes_dir });
            defer allocator.free(nodes_dir_path);
            try std.Io.Dir.cwd().deleteTree(io, nodes_dir_path);
            try std.Io.Dir.cwd().createDirPath(io, nodes_dir_path);
            const relations_dir_path = try std.fs.path.join(allocator, &.{ dir_path, markdown_relations_dir });
            defer allocator.free(relations_dir_path);
            try std.Io.Dir.cwd().deleteTree(io, relations_dir_path);
            try std.Io.Dir.cwd().createDirPath(io, relations_dir_path);
            const edges_path = try std.fs.path.join(allocator, &.{ dir_path, markdown_edges_file });
            defer allocator.free(edges_path);
            std.Io.Dir.cwd().deleteFile(io, edges_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            const deferred_based_on_path = try std.fs.path.join(allocator, &.{ dir_path, markdown_deferred_based_on_file });
            defer allocator.free(deferred_based_on_path);
            const readme_path = try std.fs.path.join(allocator, &.{ dir_path, markdown_readme_file });
            defer allocator.free(readme_path);

            var result = MarkdownExportResult{};
            var text = QueryOutputWriter{ .allocator = allocator };
            defer text.buffer.deinit(allocator);

            text.buffer.clearRetainingCapacity();
            try text.writeAll(
                \\# TinyKG Markdown Export
                \\
                \\This directory is a reversible TinyKG audit export.
                \\
                \\- `nodes/<scope>/<schema_type>/<kind>/*.md` stores one active node per file.
                \\- `relations/<rel>/edges.md` stores active graph edges grouped by relation.
                \\- `deferred_based_on.md` stores deferred evidence links when present.
                \\- Machine-readable frontmatter/comments preserve exact TinyKG ids and text.
                \\
                \\Import with `tinykg import-markdown <db> <dir> [--warm-text]`.
                \\
            );
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = readme_path, .data = text.buffer.items, .flags = .{ .truncate = true } });
            result.markdown_bytes += @intCast(text.buffer.items.len);

            var node_titles = std.AutoHashMap(u64, []u8).init(allocator);
            defer {
                var title_iter = node_titles.valueIterator();
                while (title_iter.next()) |title| allocator.free(title.*);
                node_titles.deinit();
            }

            var node_iter = try store.nodeRecordsIterator(null);
            defer node_iter.deinit();
            const export_now_ns = try u128ToU64(persistentNowNs(io));
            var status_snapshot = try task.StatusSnapshot.init(allocator, store);
            defer status_snapshot.deinit();
            while (try node_iter.next(allocator)) |stored_node| {
                var node = stored_node;
                defer node.deinit(allocator);
                if (isDeletedNodeTombstone(node)) continue;
                const legacy_closed_task = status_snapshot.isLegacyClosedTaskNode(node);
                const export_kind: core.NodeKind = if (legacy_closed_task) .task else node.kind;
                const kind_label = try nodeKindNameAlloc(allocator, export_kind);
                defer allocator.free(kind_label);

                const schema_type = try store.getNodeStringProperty(allocator, node.id, "schema_type");
                defer if (schema_type) |value| allocator.free(value);
                const export_schema_type = normalizedAuditSchemaType(legacy_closed_task, schema_type);

                var audit_path = try markdownNodeAuditPath(allocator, node, kind_label, export_schema_type);
                defer audit_path.deinit(allocator);
                const node_dir_path = try std.fs.path.join(allocator, &.{ nodes_dir_path, audit_path.scope, audit_path.schema_type, audit_path.kind });
                defer allocator.free(node_dir_path);
                try std.Io.Dir.cwd().createDirPath(io, node_dir_path);
                const node_path = try std.fs.path.join(allocator, &.{ node_dir_path, audit_path.file_name });
                defer allocator.free(node_path);
                try node_titles.put(node.id.toInt(), try allocator.dupe(u8, audit_path.title));

                text.buffer.clearRetainingCapacity();
                try text.writeAll("---\n");
                try text.writeAll("tinykg: node\n");
                try text.print("id: {}\n", .{node.id.toInt()});
                try text.print("kind: {s}\n", .{kind_label});
                try text.print("scope: {s}\n", .{audit_path.scope});
                try text.print("schema_type: {s}\n", .{audit_path.schema_type});
                if (export_schema_type) |value| {
                    try text.writeAll("schema_type_json: ");
                    try writeJsonString(&text, value);
                    try text.writeAll("\n");
                }
                if (export_kind == .task) {
                    const lifecycle = try status_snapshot.statusForStoredNode(node, export_now_ns);
                    const lifecycle_fields = status_snapshot.fields(node.id);
                    try text.print("status: {s}\n", .{@tagName(lifecycle)});
                    if (lifecycle_fields.claimed_by) |value| {
                        try text.writeAll("claimed_by_json: ");
                        try writeJsonString(&text, value);
                        try text.writeAll("\n");
                    }
                    if (lifecycle_fields.claim_expires_ns) |value| {
                        try text.print("claim_expires_ns: {}\n", .{exportedClaimExpiry(lifecycle, value)});
                    }
                    if (lifecycle_fields.task_recorded_ns) |value| try text.print("task_recorded_ns: {}\n", .{value});
                    if (lifecycle_fields.task_created_ns) |value| try text.print("task_created_ns: {}\n", .{value});
                    if (lifecycle_fields.task_completed_ns) |value| try text.print("task_completed_ns: {}\n", .{value});
                }
                try text.writeAll("title_json: ");
                try writeJsonString(&text, audit_path.title);
                try text.writeAll("\n");
                try text.writeAll("text_json: ");
                try writeJsonString(&text, node.text);
                try text.writeAll("\n---\n\n");
                try text.writeAll("# ");
                try writeMarkdownInlineText(&text, audit_path.title);
                try text.writeAll("\n\n");
                try text.print("- id: `{}`\n", .{node.id.toInt()});
                try text.print("- scope: `{s}`\n", .{audit_path.scope});
                try text.print("- schema_type: `{s}`\n", .{audit_path.schema_type});
                try text.print("- kind: `{s}`\n", .{kind_label});
                try text.print("- text_bytes: `{}`\n\n", .{node.text.len});
                try text.writeAll("## Text\n\n```text\n");
                try text.writeAll(node.text);
                if (node.text.len == 0 or node.text[node.text.len - 1] != '\n') try text.writeAll("\n");
                try text.writeAll("```\n");
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = node_path, .data = text.buffer.items, .flags = .{ .truncate = true } });
                result.markdown_bytes += @intCast(text.buffer.items.len);
                result.nodes_exported += 1;
            }

            var relation_groups = std.ArrayList(MarkdownRelationExportGroup).empty;
            defer {
                for (relation_groups.items) |*group| group.deinit(allocator);
                relation_groups.deinit(allocator);
            }

            const MarkdownEdgeExportContext = struct {
                allocator: std.mem.Allocator,
                groups: *std.ArrayList(MarkdownRelationExportGroup),
                node_titles: *std.AutoHashMap(u64, []u8),
                result: *MarkdownExportResult,

                fn visit(raw_context: *anyopaque, edge: storage.EdgeIndexRecord) anyerror!void {
                    const context: *@This() = @ptrCast(@alignCast(raw_context));
                    const rel_label = try relKindNameAlloc(context.allocator, try edge.relKind());
                    defer context.allocator.free(rel_label);
                    const group = try markdownRelationExportGroup(context.allocator, context.groups, rel_label);
                    try group.text.print("<!-- tinykg-edge {{\"id\":{},\"src\":{},\"rel\":", .{ edge.edge_id, edge.src });
                    try writeJsonString(&group.text, rel_label);
                    try group.text.print(",\"dst\":{}}} -->\n", .{edge.dst});
                    try group.text.print("- `{}` ", .{edge.src});
                    if (context.node_titles.get(edge.src)) |src_title| try writeMarkdownInlineText(&group.text, src_title);
                    try group.text.print(" --`{s}`--> `{}` ", .{ rel_label, edge.dst });
                    if (context.node_titles.get(edge.dst)) |dst_title| try writeMarkdownInlineText(&group.text, dst_title);
                    try group.text.writeAll("\n\n");
                    group.count = std.math.add(usize, group.count, 1) catch return error.RecordTooLarge;
                    context.result.edges_exported = std.math.add(usize, context.result.edges_exported, 1) catch return error.RecordTooLarge;
                }
            };
            var markdown_edge_context = MarkdownEdgeExportContext{
                .allocator = allocator,
                .groups = &relation_groups,
                .node_titles = &node_titles,
                .result = &result,
            };
            _ = try store.scanVisibleEdgeIndexRecords(allocator, &markdown_edge_context, MarkdownEdgeExportContext.visit);
            for (relation_groups.items) |*group| {
                const rel_dir = try std.fs.path.join(allocator, &.{ relations_dir_path, group.safe_rel });
                defer allocator.free(rel_dir);
                try std.Io.Dir.cwd().createDirPath(io, rel_dir);
                const rel_path = try std.fs.path.join(allocator, &.{ rel_dir, markdown_edges_file });
                defer allocator.free(rel_path);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = rel_path, .data = group.text.buffer.items, .flags = .{ .truncate = true } });
                result.markdown_bytes += @intCast(group.text.buffer.items.len);
            }

            var deferred_based_on = try readMetaknowDeferredBasedOnSidecarForwardPairs(allocator, io, store.dir_path);
            defer deferred_based_on.deinit(allocator);
            if (deferred_based_on.present and deferred_based_on.pairs.items.len != 0) {
                text.buffer.clearRetainingCapacity();
                try text.writeAll("# TinyKG Deferred Based-On Links\n\n");
                for (deferred_based_on.pairs.items) |pair| {
                    try text.print("<!-- tinykg-deferred-based-on {{\"src\":{},\"dst\":{}}} -->\n", .{ pair.src, pair.dst });
                    try text.print("- `{}` --`based_on`--> `{}`\n\n", .{ pair.src, pair.dst });
                    result.deferred_based_on_exported += 1;
                }
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = deferred_based_on_path, .data = text.buffer.items, .flags = .{ .truncate = true } });
                result.markdown_bytes += @intCast(text.buffer.items.len);
            } else {
                std.Io.Dir.cwd().deleteFile(io, deferred_based_on_path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
            }

            export_complete = true;
            return result;
        }
    };
}

test "store interchange source digest separates framing from payload" {
    var first = std.crypto.hash.sha2.Sha256.init(.{});
    updateSourceDigest(&first, "ab", "c");
    var first_bytes: [32]u8 = undefined;
    first.final(&first_bytes);

    var second = std.crypto.hash.sha2.Sha256.init(.{});
    updateSourceDigest(&second, "a", "bc");
    var second_bytes: [32]u8 = undefined;
    second.final(&second_bytes);
    try std.testing.expect(!std.mem.eql(u8, &first_bytes, &second_bytes));
}

test "store interchange import receipt matches only complete source publication" {
    const expected = ImportPublicationResultView{
        .nodes_loaded = 2,
        .nodes_imported = 2,
        .source_bytes = 64,
        .text_warmed = true,
    };
    try std.testing.expect(importPublicationMatchesSourceView(expected, expected));
}

test "store interchange import receipt rejects mismatched source counters" {
    const expected = ImportPublicationResultView{ .nodes_loaded = 2, .nodes_imported = 2, .source_bytes = 64 };
    var actual = expected;
    actual.nodes_imported = 1;
    try std.testing.expect(!importPublicationMatchesSourceView(actual, expected));
}

test "store interchange native result preserves source and publication counters" {
    const result = NativeJsonlImportResult{
        .nodes_loaded = 3,
        .nodes_imported = 2,
        .edges_loaded = 4,
        .edges_imported = 4,
        .jsonl_bytes = 99,
    };
    try std.testing.expectEqual(@as(usize, 3), result.nodes_loaded);
    try std.testing.expectEqual(@as(usize, 2), result.nodes_imported);
    try std.testing.expectEqual(@as(u64, 99), result.jsonl_bytes);
}

test "store interchange native export result keeps cleanup separate from bytes" {
    const result = NativeJsonlExportResult{ .jsonl_bytes = 42, .cleanup_pending = true };
    try std.testing.expectEqual(@as(u64, 42), result.jsonl_bytes);
    try std.testing.expect(result.cleanup_pending);
}

test "store interchange markdown result preserves lifecycle and sidecar counters" {
    const imported = MarkdownImportResult{
        .nodes_loaded = 2,
        .nodes_imported = 2,
        .deferred_based_on_loaded = 1,
        .deferred_based_on_imported = 1,
        .markdown_bytes = 128,
    };
    const exported = MarkdownExportResult{
        .nodes_exported = 2,
        .deferred_based_on_exported = 1,
        .markdown_bytes = 128,
    };
    try std.testing.expectEqual(imported.deferred_based_on_imported, exported.deferred_based_on_exported);
    try std.testing.expectEqual(imported.markdown_bytes, exported.markdown_bytes);
}

test "store interchange audit schema normalization repairs only legacy closed tasks" {
    try std.testing.expectEqualStrings("task", normalizedAuditSchemaType(true, "verification").?);
    try std.testing.expectEqualStrings("custom", normalizedAuditSchemaType(false, "custom").?);
    try std.testing.expect(normalizedAuditSchemaType(false, null) == null);
}

test "store interchange exported claim expiry clears non claimed leases" {
    try std.testing.expectEqual(@as(u64, 7), exportedClaimExpiry(.claimed, 7));
    try std.testing.expectEqual(@as(u64, 0), exportedClaimExpiry(.open, 7));
    try std.testing.expectEqual(@as(u64, 0), exportedClaimExpiry(.completed, 7));
}
