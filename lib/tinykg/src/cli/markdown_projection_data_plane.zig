/// Markdown/AST projection import, stable identity, rendering, pagination and orphan reclamation.
pub fn MarkdownProjectionDataPlane(comptime Ops: type) type {
    return struct {
        const AgentWriteBatchJson = Ops.AgentWriteBatchJsonValue;
        const AgentWriteEdgePropertiesJson = Ops.AgentWriteEdgePropertiesJsonValue;
        const CliStoreLock = Ops.CliStoreLockValue;
        const ContentDigest = Ops.ContentDigestValue;
        const MarkdownAstImportSpec = Ops.MarkdownAstImportSpecValue;
        const MarkdownDocumentImportSpec = Ops.MarkdownDocumentImportSpecValue;
        const ParsedAgentWriteArgs = Ops.ParsedAgentWriteArgsValue;
        const ParsedAgentWriteJsonArgs = Ops.ParsedAgentWriteJsonArgsValue;
        const ParsedMarkdownDocEditBenchArgs = Ops.ParsedMarkdownDocEditBenchArgsValue;
        const ParsedRenderMarkdownDocumentArgs = Ops.ParsedRenderMarkdownDocumentArgsValue;
        const QueryOutputWriter = Ops.QueryOutputWriterValue;
        const StoreContentIdentity = Ops.StoreContentIdentityValue;
        const TextContextSize = Ops.TextContextSizeValue;
        const agent = Ops.agentValue;
        const anyPathExists = Ops.anyPathExistsValue;
        const canonicalPathsEqual = Ops.canonicalPathsEqualValue;
        const canonicalProspectivePath = Ops.canonicalProspectivePathValue;
        const cli_store_lock_suffix = Ops.cli_store_lock_suffixValue;
        const computeTextContextSize = Ops.computeTextContextSizeValue;
        const core = Ops.coreValue;
        const createOwnedDirectory = Ops.createOwnedDirectoryValue;
        const dag = Ops.dagValue;
        const elapsedNs = Ops.elapsedNsValue;
        const existingTinyKgStorePath = Ops.existingTinyKgStorePathValue;
        const fileExists = Ops.fileExistsValue;
        const graph = Ops.graphValue;
        const markdown_bootstrap_publish_lock_suffix = Ops.markdown_bootstrap_publish_lock_suffixValue;
        const markdown_bootstrap_staging_suffix = Ops.markdown_bootstrap_staging_suffixValue;
        const markdown_bootstrap_transaction_format = Ops.markdown_bootstrap_transaction_formatValue;
        const markdown_bootstrap_transaction_suffix = Ops.markdown_bootstrap_transaction_suffixValue;
        const monotonicNs = Ops.monotonicNsValue;
        const node_text_char_limit = Ops.node_text_char_limitValue;
        const parseNodeIdArg = Ops.parseNodeIdArgValue;
        const parseRelKindWithLoadedSchema = Ops.parseRelKindWithLoadedSchemaValue;
        const parseRelKindWithSchemaPolicy = Ops.parseRelKindWithSchemaPolicyValue;
        const pathsOverlap = Ops.pathsOverlapValue;
        const query = Ops.queryValue;
        const readStoreManifestSummary = Ops.readStoreManifestSummaryValue;
        const readVisibleEdgeRecordsByNode = Ops.readVisibleEdgeRecordsByNodeValue;
        const renamePath = Ops.renamePathValue;
        const renderNodeObjectJson = Ops.renderNodeObjectJsonValue;
        const renderTextContextSizeJson = Ops.renderTextContextSizeJsonValue;
        const run = Ops.runValue;
        const schema = Ops.schemaValue;
        const std = Ops.stdValue;
        const storage = Ops.storageValue;
        const storeContentIdentity = Ops.storeContentIdentityValue;
        const storeDirBytes = Ops.storeDirBytesValue;
        const syncExportDirectoryTree = Ops.syncExportDirectoryTreeValue;
        const syncParentDirectory = Ops.syncParentDirectoryValue;
        const validateGovernanceMetadataToken = Ops.validateGovernanceMetadataTokenValue;
        const validateNodeLlmMetadataGranularity = Ops.validateNodeLlmMetadataGranularityValue;
        const validateNodeTextGranularity = Ops.validateNodeTextGranularityValue;
        const validateParsedStringProperty = Ops.validateParsedStringPropertyValue;
        const validateSchemaEdgeEndpoints = Ops.validateSchemaEdgeEndpointsValue;
        const writeAtomicReplacementFile = Ops.writeAtomicReplacementFileValue;
        const writeJsonBoolField = Ops.writeJsonBoolFieldValue;
        const writeJsonFieldPrefix = Ops.writeJsonFieldPrefixValue;
        const writeJsonNullableStringField = Ops.writeJsonNullableStringFieldValue;
        const writeJsonNullableUsizeField = Ops.writeJsonNullableUsizeFieldValue;
        const writeJsonNumberField = Ops.writeJsonNumberFieldValue;
        const writeJsonObjectEnd = Ops.writeJsonObjectEndValue;
        const writeJsonObjectStart = Ops.writeJsonObjectStartValue;
        const writeJsonString = Ops.writeJsonStringValue;
        const writeJsonStringField = Ops.writeJsonStringFieldValue;
        const writeSearchContinuation = Ops.writeSearchContinuationValue;
        const writeStoreManifest = Ops.writeStoreManifestValue;

        pub const native_jsonl_deferred_based_on_file = "deferred_based_on.jsonl";
        const native_markdown_max_bytes: u64 = 512 * 1024 * 1024;
        const agent_write_json_max_bytes: u64 = 16 * 1024 * 1024;
        const markdown_ast_text_chunk_chars: usize = 5000;
        pub const markdown_nodes_dir = "nodes";
        const markdown_edges_file = "edges.md";
        const markdown_relations_dir = "relations";
        const markdown_deferred_based_on_file = "deferred_based_on.md";
        pub const markdown_readme_file = "README.md";

        pub const md_rel_h1: core.RelKind = @enumFromInt(schema.md_rel_h1_id);
        const md_rel_h2: core.RelKind = @enumFromInt(schema.md_rel_h2_id);
        const md_rel_h3: core.RelKind = @enumFromInt(schema.md_rel_h3_id);
        const md_rel_h4: core.RelKind = @enumFromInt(schema.md_rel_h4_id);
        const md_rel_h5: core.RelKind = @enumFromInt(schema.md_rel_h5_id);
        const md_rel_h6: core.RelKind = @enumFromInt(schema.md_rel_h6_id);
        const md_rel_paragraph: core.RelKind = @enumFromInt(schema.md_rel_paragraph_id);
        const md_rel_code_block: core.RelKind = @enumFromInt(schema.md_rel_code_block_id);
        const md_rel_image: core.RelKind = @enumFromInt(schema.md_rel_image_id);
        const md_rel_list: core.RelKind = @enumFromInt(schema.md_rel_list_id);
        const md_rel_blockquote: core.RelKind = @enumFromInt(schema.md_rel_blockquote_id);
        const md_rel_html_block: core.RelKind = @enumFromInt(schema.md_rel_html_block_id);
        const md_rel_footnote_def: core.RelKind = @enumFromInt(schema.md_rel_footnote_def_id);
        const md_rel_link_reference: core.RelKind = @enumFromInt(schema.md_rel_link_reference_id);
        const md_rel_thematic_break: core.RelKind = @enumFromInt(schema.md_rel_thematic_break_id);
        const md_rel_raw_block: core.RelKind = @enumFromInt(schema.md_rel_raw_block_id);
        const md_rel_table: core.RelKind = @enumFromInt(schema.md_rel_table_id);
        const md_rel_table_row: core.RelKind = @enumFromInt(schema.md_rel_table_row_id);
        const md_rel_table_cell: core.RelKind = @enumFromInt(schema.md_rel_table_cell_id);
        const md_rel_text_chunk: core.RelKind = @enumFromInt(schema.md_rel_text_chunk_id);

        const MarkdownDocumentImportResult = struct {
            document_id: core.NodeId,
            nodes_imported: usize = 0,
            edges_imported: usize = 0,
            projection_edges_deleted: usize = 0,
            markdown_bytes: u64 = 0,
            text_chunks: usize = 0,
            marker_cleanup_pending: bool = false,
        };

        const MarkdownImportRequest = union(enum) {
            ast: MarkdownAstImportSpec,
            document: MarkdownDocumentImportSpec,

            fn dbPath(self: MarkdownImportRequest) []const u8 {
                return switch (self) {
                    .ast => |parsed| parsed.db_path,
                    .document => |parsed| parsed.db_path,
                };
            }

            fn durability(self: MarkdownImportRequest) storage.DurabilityMode {
                return switch (self) {
                    .ast => |parsed| parsed.durability,
                    .document => |parsed| parsed.durability,
                };
            }

            fn inputPath(self: MarkdownImportRequest) ?[]const u8 {
                return switch (self) {
                    .ast => |parsed| if (std.mem.eql(u8, parsed.ast_path, "-")) null else parsed.ast_path,
                    .document => |parsed| parsed.file_path,
                };
            }

            fn migrationName(self: MarkdownImportRequest) []const u8 {
                return switch (self) {
                    .ast => "import-md-ast",
                    .document => "import-md-doc",
                };
            }
        };

        const MarkdownBootstrapMarkerJson = struct {
            format: []const u8,
            canonical_target_path: []const u8,
            migration_name: []const u8,
            complete: bool,
            published_store_bytes: u64,
            published_store_digest: ContentDigest,
        };

        const MarkdownBootstrapMigration = enum {
            ast,
            document,
        };

        const MarkdownBootstrapMarkerState = struct {
            migration: MarkdownBootstrapMigration,
            complete: bool,
            published_store_bytes: u64,
            published_store_digest: ContentDigest,

            fn migrationName(self: MarkdownBootstrapMarkerState) []const u8 {
                return switch (self.migration) {
                    .ast => "import-md-ast",
                    .document => "import-md-doc",
                };
            }
        };

        fn markdownBootstrapMarkerStatesEqual(lhs: MarkdownBootstrapMarkerState, rhs: MarkdownBootstrapMarkerState) bool {
            return lhs.migration == rhs.migration and
                lhs.complete == rhs.complete and
                lhs.published_store_bytes == rhs.published_store_bytes and
                std.meta.eql(lhs.published_store_digest, rhs.published_store_digest);
        }

        pub fn markdownBootstrapStagingPath(allocator: std.mem.Allocator, target_path: []const u8) ![]u8 {
            return try std.fmt.allocPrint(allocator, "{s}{s}", .{ target_path, markdown_bootstrap_staging_suffix });
        }

        pub fn markdownBootstrapTransactionPath(allocator: std.mem.Allocator, target_path: []const u8) ![]u8 {
            return try std.fmt.allocPrint(allocator, "{s}{s}", .{ target_path, markdown_bootstrap_transaction_suffix });
        }

        pub fn markdownBootstrapTransactionTmpPath(allocator: std.mem.Allocator, marker_path: []const u8) ![]u8 {
            return try std.fmt.allocPrint(allocator, "{s}.tmp", .{marker_path});
        }

        fn writeMarkdownBootstrapMarker(
            allocator: std.mem.Allocator,
            io: std.Io,
            marker_path: []const u8,
            marker_tmp_path: []const u8,
            canonical_target_path: []const u8,
            migration_name: []const u8,
            identity: ?StoreContentIdentity,
        ) !void {
            var out = QueryOutputWriter{ .allocator = allocator };
            defer out.buffer.deinit(allocator);
            try out.writeAll("{\"format\":");
            try writeJsonString(&out, markdown_bootstrap_transaction_format);
            try out.writeAll(",\"canonical_target_path\":");
            try writeJsonString(&out, canonical_target_path);
            try out.writeAll(",\"migration_name\":");
            try writeJsonString(&out, migration_name);
            const published = identity orelse StoreContentIdentity{ .digest = .{ 0, 0, 0, 0 } };
            try out.print(
                ",\"complete\":{},\"published_store_bytes\":{},\"published_store_digest\":[{},{},{},{}]}}\n",
                .{
                    identity != null,
                    published.bytes,
                    published.digest[0],
                    published.digest[1],
                    published.digest[2],
                    published.digest[3],
                },
            );
            try writeAtomicReplacementFile(io, marker_tmp_path, marker_path, out.buffer.items);
        }

        fn readMarkdownBootstrapMarkerAtPath(
            allocator: std.mem.Allocator,
            io: std.Io,
            marker_path: []const u8,
            canonical_target_path: []const u8,
        ) !?MarkdownBootstrapMarkerState {
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, marker_path, allocator, .limited(16 * 1024)) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return null,
                error.StreamTooLong => return error.MarkdownBootstrapRecoveryConflict,
                else => |e| return e,
            };
            defer allocator.free(bytes);
            var parsed = std.json.parseFromSlice(MarkdownBootstrapMarkerJson, allocator, bytes, .{
                .ignore_unknown_fields = false,
                .allocate = .alloc_always,
            }) catch return error.MarkdownBootstrapRecoveryConflict;
            defer parsed.deinit();
            const marker = parsed.value;
            if (!std.mem.eql(u8, marker.format, markdown_bootstrap_transaction_format) or
                !canonicalPathsEqual(marker.canonical_target_path, canonical_target_path))
            {
                return error.MarkdownBootstrapRecoveryConflict;
            }
            const parsed_migration: MarkdownBootstrapMigration = if (std.mem.eql(u8, marker.migration_name, "import-md-ast"))
                .ast
            else if (std.mem.eql(u8, marker.migration_name, "import-md-doc"))
                .document
            else
                return error.MarkdownBootstrapRecoveryConflict;
            const zero_digest = ContentDigest{ 0, 0, 0, 0 };
            if (marker.complete != (marker.published_store_bytes != 0) or
                marker.complete != !std.meta.eql(marker.published_store_digest, zero_digest))
            {
                return error.MarkdownBootstrapRecoveryConflict;
            }
            return .{
                .migration = parsed_migration,
                .complete = marker.complete,
                .published_store_bytes = marker.published_store_bytes,
                .published_store_digest = marker.published_store_digest,
            };
        }

        fn deleteMarkdownBootstrapMarker(io: std.Io, marker_path: []const u8) !void {
            try std.Io.Dir.cwd().deleteFile(io, marker_path);
            try syncParentDirectory(io, marker_path);
        }

        fn cleanupMarkdownBootstrapMarkerAfterCommit(io: std.Io, marker_path: []const u8) bool {
            deleteMarkdownBootstrapMarker(io, marker_path) catch return false;
            return true;
        }

        fn recoverMarkdownBootstrap(
            allocator: std.mem.Allocator,
            io: std.Io,
            canonical_target_path: []const u8,
            staging_path: []const u8,
            marker_path: []const u8,
            marker_tmp_path: []const u8,
        ) !void {
            var marker = try readMarkdownBootstrapMarkerAtPath(allocator, io, marker_path, canonical_target_path);
            const staging_exists = try anyPathExists(io, staging_path);
            const target_exists = try anyPathExists(io, canonical_target_path);
            if (try anyPathExists(io, marker_tmp_path)) {
                const tmp_marker = (try readMarkdownBootstrapMarkerAtPath(allocator, io, marker_tmp_path, canonical_target_path)) orelse
                    return error.MarkdownBootstrapRecoveryConflict;
                if (marker == null) {
                    try renamePath(io, marker_tmp_path, marker_path);
                    try syncParentDirectory(io, marker_path);
                    marker = tmp_marker;
                } else {
                    const final_marker = marker.?;
                    if (!markdownBootstrapMarkerStatesEqual(final_marker, tmp_marker)) {
                        // The only legitimate state-changing temp is the completed
                        // replacement of this transaction's incomplete marker. Bind
                        // it to the private staging bytes before discarding it; the
                        // source request is not persisted, so recovery still rebuilds
                        // from the caller's current input below instead of publishing
                        // the old stage.
                        if (final_marker.complete or !tmp_marker.complete or
                            final_marker.migration != tmp_marker.migration or
                            !staging_exists or target_exists)
                        {
                            return error.MarkdownBootstrapRecoveryConflict;
                        }
                        const stat = try std.Io.Dir.cwd().statFile(io, staging_path, .{ .follow_symlinks = false });
                        if (stat.kind != .directory) return error.MarkdownBootstrapRecoveryConflict;
                        const identity = try storeContentIdentity(allocator, io, staging_path);
                        if (identity.bytes != tmp_marker.published_store_bytes or
                            !std.meta.eql(identity.digest, tmp_marker.published_store_digest))
                        {
                            return error.MarkdownBootstrapRecoveryConflict;
                        }
                    }
                    try std.Io.Dir.cwd().deleteFile(io, marker_tmp_path);
                    try syncParentDirectory(io, marker_tmp_path);
                }
            }

            if (marker == null) {
                if (staging_exists) return error.MarkdownBootstrapRecoveryConflict;
                return;
            }
            const state = marker.?;
            if (staging_exists and target_exists) return error.MarkdownBootstrapRecoveryConflict;
            if (staging_exists) {
                const stat = try std.Io.Dir.cwd().statFile(io, staging_path, .{ .follow_symlinks = false });
                if (stat.kind != .directory) return error.MarkdownBootstrapRecoveryConflict;
                try std.Io.Dir.cwd().deleteTree(io, staging_path);
                try syncParentDirectory(io, staging_path);
                try deleteMarkdownBootstrapMarker(io, marker_path);
                return;
            }
            if (target_exists) {
                if (!state.complete or !try existingTinyKgStorePath(allocator, io, canonical_target_path))
                    return error.MarkdownBootstrapRecoveryConflict;
                const stat = try std.Io.Dir.cwd().statFile(io, canonical_target_path, .{ .follow_symlinks = false });
                if (stat.kind != .directory) return error.MarkdownBootstrapRecoveryConflict;
                const identity = try storeContentIdentity(allocator, io, canonical_target_path);
                if (identity.bytes != state.published_store_bytes or
                    !std.meta.eql(identity.digest, state.published_store_digest))
                {
                    return error.MarkdownBootstrapRecoveryConflict;
                }
                const manifest = try readStoreManifestSummary(allocator, io, canonical_target_path);
                defer manifest.deinit(allocator);
                if (!std.mem.eql(u8, manifest.status, "present") or
                    !std.mem.eql(u8, manifest.enabled_profiles, "markdown-document") or
                    !std.mem.eql(u8, manifest.migration_name, state.migrationName()))
                {
                    return error.MarkdownBootstrapRecoveryConflict;
                }
            }
            try deleteMarkdownBootstrapMarker(io, marker_path);
        }

        fn validateMarkdownBootstrapInputPath(
            allocator: std.mem.Allocator,
            io: std.Io,
            request: MarkdownImportRequest,
            staging_path: []const u8,
            marker_path: []const u8,
            marker_tmp_path: []const u8,
        ) !void {
            const input_path = request.inputPath() orelse return;
            if (try pathsOverlap(allocator, io, input_path, staging_path) or
                try pathsOverlap(allocator, io, input_path, marker_path) or
                try pathsOverlap(allocator, io, input_path, marker_tmp_path))
            {
                return error.InvalidFileName;
            }
        }

        fn importMarkdownIntoStore(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            request: MarkdownImportRequest,
        ) !MarkdownDocumentImportResult {
            return switch (request) {
                .ast => |parsed| try importMarkdownAst(allocator, io, store, parsed),
                .document => |parsed| result: {
                    const result = try importMarkdownDocument(allocator, io, store, parsed.file_path);
                    // 来源标注(PM P1,document 级):召回 hit / forget 可溯源到真实记忆文件。
                    // section 级不标(逐节点 property 代价高,已知局限)。
                    if (parsed.source_label) |label| {
                        try store.setNodeStringProperty(allocator, result.document_id, "source_label", label);
                    }
                    break :result result;
                },
            };
        }

        pub fn executeMarkdownImport(
            allocator: std.mem.Allocator,
            io: std.Io,
            request: MarkdownImportRequest,
        ) !MarkdownDocumentImportResult {
            const canonical_target_path = try canonicalProspectivePath(allocator, io, request.dbPath());
            defer allocator.free(canonical_target_path);
            const staging_path = try markdownBootstrapStagingPath(allocator, canonical_target_path);
            defer allocator.free(staging_path);
            const marker_path = try markdownBootstrapTransactionPath(allocator, canonical_target_path);
            defer allocator.free(marker_path);
            const marker_tmp_path = try markdownBootstrapTransactionTmpPath(allocator, marker_path);
            defer allocator.free(marker_tmp_path);
            try validateMarkdownBootstrapInputPath(allocator, io, request, staging_path, marker_path, marker_tmp_path);

            const publish_lock = try CliStoreLock.acquireAdjacent(
                allocator,
                io,
                canonical_target_path,
                markdown_bootstrap_publish_lock_suffix,
            );
            defer publish_lock.deinit();

            var existing_store_lock: ?CliStoreLock = null;
            defer if (existing_store_lock) |lock| lock.deinit();
            if (try existingTinyKgStorePath(allocator, io, canonical_target_path)) {
                existing_store_lock = try CliStoreLock.acquire(allocator, io, canonical_target_path);
            }
            try recoverMarkdownBootstrap(
                allocator,
                io,
                canonical_target_path,
                staging_path,
                marker_path,
                marker_tmp_path,
            );

            if (try existingTinyKgStorePath(allocator, io, canonical_target_path)) {
                if (existing_store_lock == null) {
                    existing_store_lock = try CliStoreLock.acquire(allocator, io, canonical_target_path);
                }
                var store = try storage.Store.openWithOptions(allocator, io, canonical_target_path, .{
                    .durability = request.durability(),
                });
                defer store.deinit();
                return try importMarkdownIntoStore(allocator, io, store, request);
            }
            if (try anyPathExists(io, canonical_target_path)) return error.AlreadyExists;
            if (try anyPathExists(io, marker_path) or try anyPathExists(io, marker_tmp_path) or try anyPathExists(io, staging_path))
                return error.MarkdownBootstrapRecoveryConflict;

            var marker_owned = false;
            var staging_owned = false;
            defer if (marker_owned) {
                if (staging_owned) {
                    std.Io.Dir.cwd().deleteTree(io, staging_path) catch {};
                }
                // Never strand an unmarked partial tree: if recursive cleanup failed,
                // retain the exact transaction proof so a later retry can recover it.
                if (!staging_owned or !(anyPathExists(io, staging_path) catch true)) {
                    std.Io.Dir.cwd().deleteFile(io, marker_path) catch {};
                }
            };
            try writeMarkdownBootstrapMarker(
                allocator,
                io,
                marker_path,
                marker_tmp_path,
                canonical_target_path,
                request.migrationName(),
                null,
            );
            marker_owned = true;

            try createOwnedDirectory(io, staging_path);
            staging_owned = true;

            var result: MarkdownDocumentImportResult = undefined;
            {
                var store = try storage.Store.initWithOptions(allocator, io, staging_path, .{
                    .durability = request.durability(),
                });
                defer store.deinit();
                try store.createEmpty();
                try writeStoreManifest(allocator, io, staging_path, .{
                    .profiles = "markdown-document",
                    .migration_name = request.migrationName(),
                });
                result = try importMarkdownIntoStore(allocator, io, store, request);
            }

            var staging_store_lock = try CliStoreLock.acquire(allocator, io, staging_path);
            defer staging_store_lock.deinit();
            const final_store_lock_path = try std.fs.path.join(allocator, &.{ canonical_target_path, cli_store_lock_suffix });
            var final_store_lock_path_owned = true;
            defer if (final_store_lock_path_owned) allocator.free(final_store_lock_path);

            try syncExportDirectoryTree(allocator, io, staging_path);
            const identity = try storeContentIdentity(allocator, io, staging_path);
            try writeMarkdownBootstrapMarker(
                allocator,
                io,
                marker_path,
                marker_tmp_path,
                canonical_target_path,
                request.migrationName(),
                identity,
            );
            if (try anyPathExists(io, canonical_target_path)) return error.AlreadyExists;
            try renamePath(io, staging_path, canonical_target_path);
            staging_owned = false;
            staging_store_lock.rebaseAfterParentRename(final_store_lock_path);
            final_store_lock_path_owned = false;
            marker_owned = false;
            try syncParentDirectory(io, canonical_target_path);
            result.marker_cleanup_pending = !cleanupMarkdownBootstrapMarkerAfterCommit(io, marker_path);
            return result;
        }

        const MarkdownOrphanGcResult = struct {
            candidates: usize = 0,
            deleted: usize = 0,
            skipped_referenced: usize = 0,
            skipped_unmanaged: usize = 0,
            elapsed_ns: u128 = 0,
        };

        const AgentWriteResult = struct {
            fact_edge_id: core.EdgeId,
            fact_created: bool,
            projection_root_id: core.NodeId,
            projection_content_id: core.NodeId,
            projection_edge_id: core.EdgeId = .none,
            projection_nodes_imported: usize = 0,
            projection_edge_created: bool = false,
            content_node_properties: usize = 0,
            projection_links: usize = 0,
            agent_inbox_created: bool = false,
        };

        const AgentWriteJsonBatchResult = struct {
            items: usize = 0,
            fact_created: usize = 0,
            projection_nodes_imported: usize = 0,
            projection_edge_created: usize = 0,
            content_node_properties: usize = 0,
            projection_links: usize = 0,
            fact_properties: usize = 0,
            projection_properties: usize = 0,
            agent_inbox_created: usize = 0,

            pub fn deinit(self: AgentWriteJsonBatchResult, allocator: std.mem.Allocator) void {
                _ = self;
                _ = allocator;
            }
        };

        const AgentWriteFactResult = struct {
            edge_id: core.EdgeId,
            created: bool,
        };

        const MarkdownProjectionBlock = struct {
            rel: core.RelKind,
            text: []const u8,
        };

        const MarkdownHeadingSection = struct {
            id: core.NodeId,
            edge_created: bool,
        };

        const MarkdownPendingProjectionEdge = struct {
            src: core.NodeId,
            rel: core.RelKind,
            dst: core.NodeId,
            order_key: u64,
        };

        const MarkdownPendingNodeProperties = struct {
            node_id: core.NodeId,
            schema_type: []u8,
            external_key: []u8,
            content_hash: ?[]u8 = null,

            fn deinit(self: *MarkdownPendingNodeProperties, allocator: std.mem.Allocator) void {
                allocator.free(self.schema_type);
                allocator.free(self.external_key);
                if (self.content_hash) |value| allocator.free(value);
            }
        };

        fn markdownPendingNodePropertiesAlloc(
            allocator: std.mem.Allocator,
            node_id: core.NodeId,
            schema_type: []const u8,
            external_key: []const u8,
            content_hash: ?[]const u8,
        ) !MarkdownPendingNodeProperties {
            const owned_schema_type = try allocator.dupe(u8, schema_type);
            errdefer allocator.free(owned_schema_type);
            const owned_external_key = try allocator.dupe(u8, external_key);
            errdefer allocator.free(owned_external_key);
            const owned_content_hash = if (content_hash) |value| try allocator.dupe(u8, value) else null;
            errdefer if (owned_content_hash) |value| allocator.free(value);
            return .{
                .node_id = node_id,
                .schema_type = owned_schema_type,
                .external_key = owned_external_key,
                .content_hash = owned_content_hash,
            };
        }

        pub const MarkdownImportContext = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            document_external_key: []const u8,
            lookup_view: storage.Store.NodeTextLookupView,
            session_node_ids: std.StringHashMap(core.NodeId),
            session_node_external_keys: std.AutoHashMap(u64, []u8),
            session_edge_counts: std.StringHashMap(usize),
            desired_projection_owners: std.AutoHashMap(u64, void),
            session_owner_order_counts: std.AutoHashMap(u64, usize),
            pending_nodes: std.ArrayList(graph.Node) = .empty,
            pending_node_properties: std.ArrayList(MarkdownPendingNodeProperties) = .empty,
            pending_edges: std.ArrayList(MarkdownPendingProjectionEdge) = .empty,
            next_pending_node_id: ?core.NodeId = null,
            node_lookup_cache: ?storage.NodeExternalKeyLookupCache = null,
            edge_lookup_cache: ?storage.EdgeExternalKeyLookupCache = null,
            use_cached_node_lookup: bool = false,
            reuse_existing_projection_edges: bool = true,
            session_chunked_block_count: usize = 0,
            edge_identity_index_dirty: bool = false,
            /// order_key 撞车修复:每个 (src,rel,dst) 位置键按**文档出现序**入队(所有路径,不只复用)。
            /// import 尾 assignProjectionOrderKeys 用与 reconcile **同一 ordered 读**遍历活边,逐边 pop
            /// 队首键,diff 才 upsert——与 reconcile 的保留选择天然一致(Linus 严重2:旧 claim 用索引序
            /// 选边、reconcile 用 order 序保留,两套顺序会把新键写给将被删的边,活边留陈旧键撞车没修)。
            /// key 含 dst → 分配不依赖遍历序(每 dst 队列独立);同 dst 重复段按遍历序 pop,相对序保持。
            /// agent-write 路径不 reconcile 不消费此表(其边 order 由 append 正确写,行为同旧版)。
            pending_position_keys: std.StringHashMap(std.ArrayList(u64)),

            pub fn deinit(self: *MarkdownImportContext) void {
                if (self.node_lookup_cache) |*cache| cache.deinit();
                if (self.edge_lookup_cache) |*cache| cache.deinit();
                for (self.pending_nodes.items) |node| self.allocator.free(node.text);
                self.pending_nodes.deinit(self.allocator);
                for (self.pending_node_properties.items) |*properties| properties.deinit(self.allocator);
                self.pending_node_properties.deinit(self.allocator);
                self.pending_edges.deinit(self.allocator);
                var node_iterator = self.session_node_ids.iterator();
                while (node_iterator.next()) |entry| self.allocator.free(entry.key_ptr.*);
                self.session_node_ids.deinit();
                var node_key_iterator = self.session_node_external_keys.iterator();
                while (node_key_iterator.next()) |entry| self.allocator.free(entry.value_ptr.*);
                self.session_node_external_keys.deinit();
                var edge_iterator = self.session_edge_counts.iterator();
                while (edge_iterator.next()) |entry| self.allocator.free(entry.key_ptr.*);
                self.session_edge_counts.deinit();
                self.desired_projection_owners.deinit();
                self.session_owner_order_counts.deinit();
                var pk_it = self.pending_position_keys.iterator();
                while (pk_it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(self.allocator);
                }
                self.pending_position_keys.deinit();
                self.lookup_view.deinit();
            }
        };

        fn importMarkdownDocument(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            file_path: []const u8,
        ) !MarkdownDocumentImportResult {
            const stat = try std.Io.Dir.cwd().statFile(io, file_path, .{});
            if (stat.kind != .file or stat.size > native_markdown_max_bytes) return error.InvalidRecord;
            const content = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(native_markdown_max_bytes));
            defer allocator.free(content);

            const title = markdownDocumentTitle(content) orelse std.fs.path.basename(file_path);
            const document_external_key = try std.fmt.allocPrint(allocator, "md-doc:{s}", .{file_path});
            defer allocator.free(document_external_key);
            const document_text = try std.fmt.allocPrint(allocator, "markdown_document title=\"{s}\" source=\"{s}\"", .{ title, file_path });
            defer allocator.free(document_text);
            const document_node_text = try markdownIdentityNodeText(allocator, .{
                .text = document_text,
                .schema_type = "document",
                .external_key = document_external_key,
            });
            defer allocator.free(document_node_text);

            var context = MarkdownImportContext{
                .allocator = allocator,
                .io = io,
                .store = store,
                .document_external_key = document_external_key,
                .lookup_view = try store.openNodeTextLookupView(allocator),
                .session_node_ids = std.StringHashMap(core.NodeId).init(allocator),
                .session_node_external_keys = std.AutoHashMap(u64, []u8).init(allocator),
                .session_edge_counts = std.StringHashMap(usize).init(allocator),
                .desired_projection_owners = std.AutoHashMap(u64, void).init(allocator),
                .session_owner_order_counts = std.AutoHashMap(u64, usize).init(allocator),
                .pending_position_keys = std.StringHashMap(std.ArrayList(u64)).init(allocator),
            };
            defer context.deinit();

            var result = MarkdownDocumentImportResult{
                .document_id = .none,
                .markdown_bytes = @intCast(content.len),
            };
            const nodes_before_document = result.nodes_imported;
            result.document_id = try markdownUpsertNode(&context, .document, document_node_text, document_external_key, "document", null, &result);
            const document_created = result.nodes_imported != nodes_before_document;
            context.use_cached_node_lookup = !document_created;
            context.reuse_existing_projection_edges = !document_created;
            const document_id = result.document_id;

            var lines = std.ArrayList([]const u8).empty;
            defer lines.deinit(allocator);
            var split = std.mem.splitScalar(u8, content, '\n');
            while (split.next()) |line_raw| {
                try lines.append(allocator, trimMarkdownLineRight(line_raw));
            }

            var paragraph = std.ArrayList(u8).empty;
            defer paragraph.deinit(allocator);

            var index: usize = 0;
            var table_index: usize = 0;
            var heading_index: usize = 0;
            var current_owner_id = document_id;
            while (index < lines.items.len) {
                const line = lines.items[index];
                if (std.mem.trim(u8, line, " \t").len == 0) {
                    try importMarkdownFlushParagraph(&context, current_owner_id, &paragraph, &result);
                    index += 1;
                    continue;
                }
                if (markdownHeading(line)) |heading| {
                    try importMarkdownFlushParagraph(&context, current_owner_id, &paragraph, &result);
                    const section = try importMarkdownHeadingSection(&context, document_id, heading_index, heading, &result);
                    if (section.edge_created) result.edges_imported += 1;
                    current_owner_id = section.id;
                    heading_index += 1;
                    index += 1;
                    continue;
                }
                if (markdownFenceMarker(line)) |marker| {
                    try importMarkdownFlushParagraph(&context, current_owner_id, &paragraph, &result);
                    var block = std.ArrayList(u8).empty;
                    defer block.deinit(allocator);
                    try block.appendSlice(allocator, line);
                    try block.append(allocator, '\n');
                    index += 1;
                    while (index < lines.items.len) : (index += 1) {
                        try block.appendSlice(allocator, lines.items[index]);
                        try block.append(allocator, '\n');
                        if (markdownFenceCloses(lines.items[index], marker)) {
                            index += 1;
                            break;
                        }
                    }
                    try importMarkdownProjectionBlock(&context, current_owner_id, .{ .rel = md_rel_code_block, .text = block.items }, &result);
                    continue;
                }
                if (markdownImageLine(line)) {
                    try importMarkdownFlushParagraph(&context, current_owner_id, &paragraph, &result);
                    try importMarkdownProjectionBlock(&context, current_owner_id, .{ .rel = md_rel_image, .text = std.mem.trim(u8, line, " \t") }, &result);
                    index += 1;
                    continue;
                }
                if (markdownListLine(line)) {
                    try importMarkdownFlushParagraph(&context, current_owner_id, &paragraph, &result);
                    const start = index;
                    index += 1;
                    while (index < lines.items.len and markdownListContinuationLine(lines.items[index])) : (index += 1) {}
                    try importMarkdownProjectionLines(&context, current_owner_id, md_rel_list, lines.items[start..index], &result);
                    continue;
                }
                if (markdownBlockquoteLine(line)) {
                    try importMarkdownFlushParagraph(&context, current_owner_id, &paragraph, &result);
                    const start = index;
                    while (index < lines.items.len and markdownBlockquoteLine(lines.items[index])) : (index += 1) {}
                    try importMarkdownProjectionLines(&context, current_owner_id, md_rel_blockquote, lines.items[start..index], &result);
                    continue;
                }
                if (markdownFootnoteDefinitionLine(line)) {
                    try importMarkdownFlushParagraph(&context, current_owner_id, &paragraph, &result);
                    const start = index;
                    index += 1;
                    while (index < lines.items.len and markdownIndentedContinuationLine(lines.items[index])) : (index += 1) {}
                    try importMarkdownProjectionLines(&context, current_owner_id, md_rel_footnote_def, lines.items[start..index], &result);
                    continue;
                }
                if (markdownLinkReferenceLine(line)) {
                    try importMarkdownFlushParagraph(&context, current_owner_id, &paragraph, &result);
                    try importMarkdownProjectionBlock(&context, current_owner_id, .{ .rel = md_rel_link_reference, .text = std.mem.trim(u8, line, " \t") }, &result);
                    index += 1;
                    continue;
                }
                if (markdownHtmlBlockLine(line)) {
                    try importMarkdownFlushParagraph(&context, current_owner_id, &paragraph, &result);
                    const start = index;
                    while (index < lines.items.len and std.mem.trim(u8, lines.items[index], " \t").len != 0) : (index += 1) {}
                    try importMarkdownProjectionLines(&context, current_owner_id, md_rel_html_block, lines.items[start..index], &result);
                    continue;
                }
                if (markdownThematicBreakLine(line)) {
                    try importMarkdownFlushParagraph(&context, current_owner_id, &paragraph, &result);
                    try importMarkdownProjectionBlock(&context, current_owner_id, .{ .rel = md_rel_thematic_break, .text = std.mem.trim(u8, line, " \t") }, &result);
                    index += 1;
                    continue;
                }
                if (markdownRawFallbackLine(line)) {
                    try importMarkdownFlushParagraph(&context, current_owner_id, &paragraph, &result);
                    const start = index;
                    index += 1;
                    while (index < lines.items.len and markdownRawFallbackContinuationLine(lines.items[index])) : (index += 1) {}
                    try importMarkdownProjectionLines(&context, current_owner_id, md_rel_raw_block, lines.items[start..index], &result);
                    continue;
                }
                if (markdownTableLine(line)) {
                    try importMarkdownFlushParagraph(&context, current_owner_id, &paragraph, &result);
                    const start = index;
                    while (index < lines.items.len and markdownTableLine(lines.items[index])) : (index += 1) {}
                    try importMarkdownTable(&context, current_owner_id, table_index, lines.items[start..index], &result);
                    table_index += 1;
                    continue;
                }
                if (markdownSetextHeadingStart(lines.items, index)) {
                    try importMarkdownFlushParagraph(&context, current_owner_id, &paragraph, &result);
                    try importMarkdownProjectionLines(&context, current_owner_id, md_rel_raw_block, lines.items[index .. index + 2], &result);
                    index += 2;
                    continue;
                }
                if (paragraph.items.len != 0) try paragraph.append(allocator, '\n');
                try paragraph.appendSlice(allocator, line);
                index += 1;
            }
            try importMarkdownFlushParagraph(&context, current_owner_id, &paragraph, &result);
            try flushMarkdownImportPendingWrites(&context);
            if (!document_created) {
                result.projection_edges_deleted = try reconcileMarkdownProjectionEdges(&context, document_id);
                try assignProjectionOrderKeys(&context, document_id);
            }
            if (context.edge_identity_index_dirty or result.projection_edges_deleted != 0) {
                try context.store.rebuildEdgeExternalKeyIndex();
            }
            return result;
        }

        fn importMarkdownAst(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            parsed: MarkdownAstImportSpec,
        ) !MarkdownDocumentImportResult {
            const bytes = try readMarkdownAstInputAlloc(allocator, io, parsed.ast_path);
            defer allocator.free(bytes);
            var parsed_json = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
            defer parsed_json.deinit();
            const root = try mdastRootValue(&parsed_json.value);
            return importMarkdownAstRoot(allocator, io, store, parsed.source_id, root, bytes.len);
        }

        fn mdastRootValue(value: *const std.json.Value) !*const std.json.Value {
            if (mdastStringField(value, "type")) |node_type| {
                if (std.mem.eql(u8, node_type, "root")) return value;
            }
            const tree = mdastObjectField(value, "tree") orelse return error.InvalidRecord;
            if (!std.mem.eql(u8, try mdastNodeType(tree), "root")) return error.InvalidRecord;
            return tree;
        }

        fn readMarkdownAstInputAlloc(allocator: std.mem.Allocator, io: std.Io, ast_path: []const u8) ![]u8 {
            if (std.mem.eql(u8, ast_path, "-")) {
                var buffer: [8192]u8 = undefined;
                var reader = std.Io.File.stdin().readerStreaming(io, &buffer);
                return try reader.interface.allocRemaining(allocator, .limited64(native_markdown_max_bytes));
            }
            const stat = try std.Io.Dir.cwd().statFile(io, ast_path, .{});
            if (stat.kind != .file or stat.size == 0 or stat.size > native_markdown_max_bytes) return error.InvalidRecord;
            return try std.Io.Dir.cwd().readFileAlloc(io, ast_path, allocator, .limited(native_markdown_max_bytes));
        }

        fn importMarkdownAstRoot(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            source_id: []const u8,
            root: *const std.json.Value,
            ast_bytes: usize,
        ) !MarkdownDocumentImportResult {
            const title = try mdastDocumentTitleAlloc(allocator, root, source_id);
            defer allocator.free(title);
            const safe_title = try markdownNodeLabelWithinMaxCharsAlloc(allocator, title, "document-title", 4096);
            defer allocator.free(safe_title);
            const document_external_key = try std.fmt.allocPrint(allocator, "md-ast:{s}", .{source_id});
            defer allocator.free(document_external_key);
            const document_text = try std.fmt.allocPrint(allocator, "markdown_ast_document title=\"{s}\" source=\"{s}\"", .{ safe_title, source_id });
            defer allocator.free(document_text);
            const document_node_text = try markdownIdentityNodeText(allocator, .{
                .text = document_text,
                .schema_type = "document",
                .external_key = document_external_key,
            });
            defer allocator.free(document_node_text);

            var context = MarkdownImportContext{
                .allocator = allocator,
                .io = io,
                .store = store,
                .document_external_key = document_external_key,
                .lookup_view = try store.openNodeTextLookupView(allocator),
                .session_node_ids = std.StringHashMap(core.NodeId).init(allocator),
                .session_node_external_keys = std.AutoHashMap(u64, []u8).init(allocator),
                .session_edge_counts = std.StringHashMap(usize).init(allocator),
                .desired_projection_owners = std.AutoHashMap(u64, void).init(allocator),
                .session_owner_order_counts = std.AutoHashMap(u64, usize).init(allocator),
                .pending_position_keys = std.StringHashMap(std.ArrayList(u64)).init(allocator),
            };
            defer context.deinit();

            var result = MarkdownDocumentImportResult{
                .document_id = .none,
                .markdown_bytes = @intCast(ast_bytes),
            };
            const nodes_before_document = result.nodes_imported;
            result.document_id = try markdownUpsertNode(&context, .document, document_node_text, document_external_key, "document", null, &result);
            const document_created = result.nodes_imported != nodes_before_document;
            context.use_cached_node_lookup = !document_created;
            context.reuse_existing_projection_edges = !document_created;
            try importMdastChildren(&context, result.document_id, mdastChildren(root), &result);
            try flushMarkdownImportPendingWrites(&context);
            if (!document_created) {
                result.projection_edges_deleted = try reconcileMarkdownProjectionEdges(&context, result.document_id);
                try assignProjectionOrderKeys(&context, result.document_id);
            }
            if (context.edge_identity_index_dirty or result.projection_edges_deleted != 0) {
                try context.store.rebuildEdgeExternalKeyIndex();
            }
            return result;
        }

        fn mdastObjectField(value: *const std.json.Value, name: []const u8) ?*const std.json.Value {
            if (value.* != .object) return null;
            return value.object.getPtr(name);
        }

        fn mdastNodeType(value: *const std.json.Value) ![]const u8 {
            const type_value = mdastObjectField(value, "type") orelse return error.InvalidRecord;
            if (type_value.* != .string) return error.InvalidRecord;
            return type_value.string;
        }

        fn mdastStringField(value: *const std.json.Value, name: []const u8) ?[]const u8 {
            const field = mdastObjectField(value, name) orelse return null;
            return if (field.* == .string) field.string else null;
        }

        fn mdastBoolField(value: *const std.json.Value, name: []const u8) ?bool {
            const field = mdastObjectField(value, name) orelse return null;
            return if (field.* == .bool) field.bool else null;
        }

        fn mdastIntegerField(value: *const std.json.Value, name: []const u8) ?i64 {
            const field = mdastObjectField(value, name) orelse return null;
            return switch (field.*) {
                .integer => |int| int,
                else => null,
            };
        }

        fn mdastChildren(value: *const std.json.Value) []const std.json.Value {
            const children = mdastObjectField(value, "children") orelse return &.{};
            return if (children.* == .array) children.array.items else &.{};
        }

        const MdastImportState = struct {
            heading_index: usize = 0,
            table_index: usize = 0,
        };

        fn importMdastChildren(
            context: *MarkdownImportContext,
            document_id: core.NodeId,
            children: []const std.json.Value,
            result: *MarkdownDocumentImportResult,
        ) !void {
            var state = MdastImportState{};
            var current_owner_id = document_id;
            for (children) |*child| {
                if (std.mem.eql(u8, try mdastNodeType(child), "heading")) {
                    const section = try importMdastHeading(context, document_id, child, &state, result);
                    if (section.edge_created) result.edges_imported += 1;
                    current_owner_id = section.id;
                } else {
                    try importMdastBlock(context, current_owner_id, child, &state, result);
                }
            }
        }

        fn importMdastHeading(
            context: *MarkdownImportContext,
            document_id: core.NodeId,
            node: *const std.json.Value,
            state: *MdastImportState,
            result: *MarkdownDocumentImportResult,
        ) !MarkdownHeadingSection {
            const depth_raw = mdastIntegerField(node, "depth") orelse 1;
            const depth: usize = @intCast(@max(1, @min(depth_raw, 6)));
            const text = try mdastInlineTextAlloc(context.allocator, node);
            defer context.allocator.free(text);
            const section = try importMarkdownHeadingSection(context, document_id, state.heading_index, .{
                .level = depth,
                .text = text,
            }, result);
            state.heading_index += 1;
            return section;
        }

        fn importMdastBlock(
            context: *MarkdownImportContext,
            owner_id: core.NodeId,
            node: *const std.json.Value,
            state: *MdastImportState,
            result: *MarkdownDocumentImportResult,
        ) !void {
            const node_type = try mdastNodeType(node);
            if (std.mem.eql(u8, node_type, "paragraph")) {
                const text = try mdastInlineTextAlloc(context.allocator, node);
                defer context.allocator.free(text);
                return importMarkdownProjectionBlock(context, owner_id, .{ .rel = md_rel_paragraph, .text = text }, result);
            }
            if (std.mem.eql(u8, node_type, "code")) {
                const text = try mdastCodeBlockTextAlloc(context.allocator, node);
                defer context.allocator.free(text);
                return importMarkdownProjectionBlock(context, owner_id, .{ .rel = md_rel_code_block, .text = text }, result);
            }
            if (std.mem.eql(u8, node_type, "html")) {
                const text = try context.allocator.dupe(u8, mdastStringField(node, "value") orelse "");
                defer context.allocator.free(text);
                return importMarkdownProjectionBlock(context, owner_id, .{ .rel = md_rel_html_block, .text = text }, result);
            }
            if (std.mem.eql(u8, node_type, "image")) {
                const text = try mdastImageTextAlloc(context.allocator, node);
                defer context.allocator.free(text);
                return importMarkdownProjectionBlock(context, owner_id, .{ .rel = md_rel_image, .text = text }, result);
            }
            if (std.mem.eql(u8, node_type, "list")) {
                const text = try mdastListTextAlloc(context.allocator, node);
                defer context.allocator.free(text);
                return importMarkdownProjectionBlock(context, owner_id, .{ .rel = md_rel_list, .text = text }, result);
            }
            if (std.mem.eql(u8, node_type, "blockquote")) {
                const text = try mdastBlockquoteTextAlloc(context.allocator, node);
                defer context.allocator.free(text);
                return importMarkdownProjectionBlock(context, owner_id, .{ .rel = md_rel_blockquote, .text = text }, result);
            }
            if (std.mem.eql(u8, node_type, "thematicBreak")) {
                return importMarkdownProjectionBlock(context, owner_id, .{ .rel = md_rel_thematic_break, .text = "---" }, result);
            }
            if (std.mem.eql(u8, node_type, "definition")) {
                const text = try mdastDefinitionTextAlloc(context.allocator, node, false);
                defer context.allocator.free(text);
                return importMarkdownProjectionBlock(context, owner_id, .{ .rel = md_rel_link_reference, .text = text }, result);
            }
            if (std.mem.eql(u8, node_type, "footnoteDefinition")) {
                const text = try mdastDefinitionTextAlloc(context.allocator, node, true);
                defer context.allocator.free(text);
                return importMarkdownProjectionBlock(context, owner_id, .{ .rel = md_rel_footnote_def, .text = text }, result);
            }
            if (std.mem.eql(u8, node_type, "table")) {
                return importMdastTable(context, owner_id, node, state, result);
            }
            const text = try mdastFallbackTextAlloc(context.allocator, node);
            defer context.allocator.free(text);
            if (text.len != 0) {
                try importMarkdownProjectionBlock(context, owner_id, .{ .rel = md_rel_raw_block, .text = text }, result);
            }
        }

        fn importMdastTable(
            context: *MarkdownImportContext,
            owner_id: core.NodeId,
            node: *const std.json.Value,
            state: *MdastImportState,
            result: *MarkdownDocumentImportResult,
        ) !void {
            const table_external_key = try std.fmt.allocPrint(context.allocator, "{s}#ast-table:{d}", .{ context.document_external_key, state.table_index });
            defer context.allocator.free(table_external_key);
            state.table_index += 1;
            const table_id = try importMarkdownOccurrenceNode(context, "markdown_table", "markdown_table", table_external_key, result);
            if (try appendMarkdownProjectionEdge(context, owner_id, md_rel_table, table_id)) result.edges_imported += 1;
            for (mdastChildren(node), 0..) |*row, row_index| {
                if (!std.mem.eql(u8, try mdastNodeType(row), "tableRow")) continue;
                const row_external_key = try std.fmt.allocPrint(context.allocator, "{s}#row:{d}", .{ table_external_key, row_index });
                defer context.allocator.free(row_external_key);
                const row_id = try importMarkdownOccurrenceNode(context, "markdown_table_row", "markdown_table_row", row_external_key, result);
                if (try appendMarkdownProjectionEdge(context, table_id, md_rel_table_row, row_id)) result.edges_imported += 1;
                for (mdastChildren(row)) |*cell| {
                    if (!std.mem.eql(u8, try mdastNodeType(cell), "tableCell")) continue;
                    const text = try mdastInlineTextAlloc(context.allocator, cell);
                    defer context.allocator.free(text);
                    try importMarkdownProjectionBlock(context, row_id, .{ .rel = md_rel_table_cell, .text = text }, result);
                }
            }
        }

        fn mdastDocumentTitleAlloc(allocator: std.mem.Allocator, root: *const std.json.Value, fallback: []const u8) ![]u8 {
            for (mdastChildren(root)) |*child| {
                if (std.mem.eql(u8, try mdastNodeType(child), "heading")) {
                    const depth = mdastIntegerField(child, "depth") orelse 1;
                    if (depth == 1) return mdastInlineTextAlloc(allocator, child);
                }
            }
            return try allocator.dupe(u8, fallback);
        }

        fn mdastInlineTextAlloc(allocator: std.mem.Allocator, node: *const std.json.Value) ![]u8 {
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);
            try appendMdastInlineText(&out, allocator, node);
            return out.buffer.toOwnedSlice(allocator);
        }

        fn appendMdastInlineText(out: *QueryOutputWriter, allocator: std.mem.Allocator, node: *const std.json.Value) !void {
            const node_type = try mdastNodeType(node);
            if (std.mem.eql(u8, node_type, "text")) return out.writeAll(mdastStringField(node, "value") orelse "");
            if (std.mem.eql(u8, node_type, "inlineCode")) {
                try out.writeAll("`");
                try out.writeAll(mdastStringField(node, "value") orelse "");
                return out.writeAll("`");
            }
            if (std.mem.eql(u8, node_type, "break")) return out.writeAll("\n");
            if (std.mem.eql(u8, node_type, "image")) {
                const image = try mdastImageTextAlloc(allocator, node);
                defer allocator.free(image);
                return out.writeAll(image);
            }
            if (std.mem.eql(u8, node_type, "link")) {
                try out.writeAll("[");
                for (mdastChildren(node)) |*child| try appendMdastInlineText(out, allocator, child);
                try out.writeAll("](");
                try out.writeAll(mdastStringField(node, "url") orelse "");
                return out.writeAll(")");
            }
            if (std.mem.eql(u8, node_type, "strong")) try out.writeAll("**");
            if (std.mem.eql(u8, node_type, "emphasis")) try out.writeAll("*");
            if (std.mem.eql(u8, node_type, "delete")) try out.writeAll("~~");
            if (mdastStringField(node, "value")) |value| try out.writeAll(value);
            for (mdastChildren(node)) |*child| try appendMdastInlineText(out, allocator, child);
            if (std.mem.eql(u8, node_type, "strong")) return out.writeAll("**");
            if (std.mem.eql(u8, node_type, "emphasis")) return out.writeAll("*");
            if (std.mem.eql(u8, node_type, "delete")) return out.writeAll("~~");
        }

        fn mdastCodeBlockTextAlloc(allocator: std.mem.Allocator, node: *const std.json.Value) ![]u8 {
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);
            try out.writeAll("```");
            if (mdastStringField(node, "lang")) |lang| try out.writeAll(lang);
            if (mdastStringField(node, "meta")) |meta| {
                try out.writeAll(" ");
                try out.writeAll(meta);
            }
            try out.writeAll("\n");
            try out.writeAll(mdastStringField(node, "value") orelse "");
            try out.writeAll("\n```");
            return out.buffer.toOwnedSlice(allocator);
        }

        fn mdastImageTextAlloc(allocator: std.mem.Allocator, node: *const std.json.Value) ![]u8 {
            return try std.fmt.allocPrint(allocator, "![{s}]({s})", .{ mdastStringField(node, "alt") orelse "", mdastStringField(node, "url") orelse "" });
        }

        fn mdastListTextAlloc(allocator: std.mem.Allocator, node: *const std.json.Value) ![]u8 {
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);
            const ordered = mdastBoolField(node, "ordered") orelse false;
            var ordinal: usize = @intCast(@max(1, mdastIntegerField(node, "start") orelse 1));
            for (mdastChildren(node)) |*item| {
                const marker = if (ordered) try std.fmt.allocPrint(allocator, "{}. ", .{ordinal}) else try allocator.dupe(u8, "- ");
                defer allocator.free(marker);
                const item_text = try mdastFallbackTextAlloc(allocator, item);
                defer allocator.free(item_text);
                try appendMarkdownPrefixedLines(&out, marker, item_text);
                ordinal += 1;
            }
            return out.buffer.toOwnedSlice(allocator);
        }

        fn mdastBlockquoteTextAlloc(allocator: std.mem.Allocator, node: *const std.json.Value) ![]u8 {
            const text = try mdastFallbackTextAlloc(allocator, node);
            defer allocator.free(text);
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);
            try appendMarkdownPrefixedLines(&out, "> ", text);
            return out.buffer.toOwnedSlice(allocator);
        }

        fn appendMarkdownPrefixedLines(out: *QueryOutputWriter, prefix: []const u8, text: []const u8) !void {
            var lines = std.mem.splitScalar(u8, text, '\n');
            var first = true;
            while (lines.next()) |line| {
                if (!first) try out.writeAll("\n");
                first = false;
                if (line.len != 0) try out.writeAll(prefix);
                try out.writeAll(line);
            }
            try out.writeAll("\n");
        }

        fn mdastDefinitionTextAlloc(allocator: std.mem.Allocator, node: *const std.json.Value, footnote: bool) ![]u8 {
            const id = mdastStringField(node, "identifier") orelse mdastStringField(node, "label") orelse "ref";
            if (footnote) {
                const text = try mdastFallbackTextAlloc(allocator, node);
                defer allocator.free(text);
                return try std.fmt.allocPrint(allocator, "[^{s}]: {s}", .{ id, text });
            }
            if (mdastStringField(node, "title")) |title| {
                return try std.fmt.allocPrint(allocator, "[{s}]: {s} \"{s}\"", .{ id, mdastStringField(node, "url") orelse "", title });
            }
            return try std.fmt.allocPrint(allocator, "[{s}]: {s}", .{ id, mdastStringField(node, "url") orelse "" });
        }

        fn mdastFallbackTextAlloc(allocator: std.mem.Allocator, node: *const std.json.Value) ![]u8 {
            if (mdastStringField(node, "value")) |value| return try allocator.dupe(u8, value);
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);
            for (mdastChildren(node), 0..) |*child, index| {
                if (index != 0) try out.writeAll("\n");
                const child_type = try mdastNodeType(child);
                if (std.mem.eql(u8, child_type, "paragraph") or
                    std.mem.eql(u8, child_type, "tableCell") or
                    std.mem.eql(u8, child_type, "listItem"))
                {
                    const text = try mdastInlineTextAlloc(allocator, child);
                    defer allocator.free(text);
                    try out.writeAll(text);
                } else if (std.mem.eql(u8, child_type, "code")) {
                    const text = try mdastCodeBlockTextAlloc(allocator, child);
                    defer allocator.free(text);
                    try out.writeAll(text);
                } else {
                    const text = try mdastFallbackTextAlloc(allocator, child);
                    defer allocator.free(text);
                    try out.writeAll(text);
                }
            }
            return out.buffer.toOwnedSlice(allocator);
        }

        pub fn gcMarkdownOrphanNodes(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            apply: bool,
        ) !MarkdownOrphanGcResult {
            const start_ns = monotonicNs(io);
            var graph_snapshot = try store.loadGraph();
            defer graph_snapshot.deinit();

            var incoming = std.AutoHashMap(u64, usize).init(allocator);
            defer incoming.deinit();
            for (graph_snapshot.edges.items) |edge| {
                if (edge.status != .active) continue;
                const entry = try incoming.getOrPut(edge.dst.toInt());
                if (!entry.found_existing) entry.value_ptr.* = 0;
                entry.value_ptr.* += 1;
            }

            var candidates = std.ArrayList(core.NodeId).empty;
            defer candidates.deinit(allocator);
            var result = MarkdownOrphanGcResult{};
            for (graph_snapshot.nodes.items) |node| {
                if (node.status != .active) continue;
                const gc_managed = markdownNodeIsGcManaged(allocator, store, node.id, node.text) catch false;
                if (!gc_managed) {
                    result.skipped_unmanaged += 1;
                    continue;
                }
                if ((incoming.get(node.id.toInt()) orelse 0) != 0) {
                    result.skipped_referenced += 1;
                    continue;
                }
                try candidates.append(allocator, node.id);
            }
            result.candidates = candidates.items.len;

            if (apply and candidates.items.len != 0) {
                for (candidates.items) |node_id| {
                    _ = try store.deleteNode(node_id);
                    result.deleted += 1;
                }
                try store.repairPersistentIndexesFromLog();
            }
            result.elapsed_ns = elapsedNs(io, start_ns);
            return result;
        }

        fn markdownNodeIsGcManaged(allocator: std.mem.Allocator, store: storage.Store, node_id: core.NodeId, text: []const u8) !bool {
            _ = text;
            const property_schema = try store.getNodeStringProperty(allocator, node_id, "schema_type");
            defer if (property_schema) |value| allocator.free(value);
            const property_external_key = try store.getNodeStringProperty(allocator, node_id, "external_key");
            defer if (property_external_key) |value| allocator.free(value);
            const schema_type = property_schema orelse return false;
            const external_key = property_external_key orelse return false;
            if (std.mem.eql(u8, schema_type, "content_text") or std.mem.eql(u8, schema_type, "content_image")) {
                return std.mem.startsWith(u8, external_key, "content:");
            }
            if (std.mem.eql(u8, schema_type, "document_section")) {
                return std.mem.startsWith(u8, external_key, "md-doc:") and std.mem.indexOf(u8, external_key, "#heading:") != null;
            }
            if (std.mem.eql(u8, schema_type, "markdown_table") or std.mem.eql(u8, schema_type, "markdown_table_row")) {
                return std.mem.startsWith(u8, external_key, "md-doc:") and std.mem.indexOf(u8, external_key, "#") != null;
            }
            return false;
        }

        pub fn agentWriteFactAndProjection(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            parsed: ParsedAgentWriteArgs,
            src: core.NodeId,
            fact_rel: core.RelKind,
            dst: core.NodeId,
            render_rel: core.RelKind,
        ) !AgentWriteResult {
            const fact = try agentWriteUpsertFactEdge(allocator, store, src, fact_rel, dst);
            var projection_result = MarkdownDocumentImportResult{ .document_id = .none };
            const root = try agentWriteProjectionRoot(allocator, io, store, parsed, &projection_result);
            defer allocator.free(root.external_key);

            var context = MarkdownImportContext{
                .allocator = allocator,
                .io = io,
                .store = store,
                .document_external_key = root.external_key,
                .lookup_view = try store.openNodeTextLookupView(allocator),
                .session_node_ids = std.StringHashMap(core.NodeId).init(allocator),
                .session_node_external_keys = std.AutoHashMap(u64, []u8).init(allocator),
                .session_edge_counts = std.StringHashMap(usize).init(allocator),
                .desired_projection_owners = std.AutoHashMap(u64, void).init(allocator),
                .session_owner_order_counts = std.AutoHashMap(u64, usize).init(allocator),
                .pending_position_keys = std.StringHashMap(std.ArrayList(u64)).init(allocator),
            };
            defer context.deinit();

            try markdownRememberSessionNodeExternalKey(&context, root.external_key, root.id);
            try seedMarkdownOwnerOrderCount(&context, root.id);

            const node_kind: core.NodeKind = if (render_rel == md_rel_image) .image else .observation;
            const schema_type = if (render_rel == md_rel_image) "content_image" else "content_text";
            const content_id = try importMarkdownContentNode(&context, node_kind, parsed.text, schema_type, &projection_result);
            const projection_edge_created = try appendMarkdownProjectionEdge(&context, root.id, render_rel, content_id);
            try flushMarkdownImportPendingWrites(&context);
            if (context.edge_identity_index_dirty or projection_edge_created) try context.store.rebuildEdgeExternalKeyIndex();
            const projection_edge_id = (try lookupMarkdownProjectionEdgeByEndpoints(allocator, store, root.id, render_rel, content_id)) orelse return error.InvalidRecord;
            const content_node_properties = try applyAgentWriteNodeProperties(allocator, store, content_id, parsed.name, parsed.summary, parsed.retrieval_hints);
            const projection_links = try linkAgentWriteFactAndProjection(allocator, store, fact.edge_id, projection_edge_id);

            return .{
                .fact_edge_id = fact.edge_id,
                .fact_created = fact.created,
                .projection_root_id = root.id,
                .projection_content_id = content_id,
                .projection_edge_id = projection_edge_id,
                .projection_nodes_imported = projection_result.nodes_imported,
                .projection_edge_created = projection_edge_created,
                .content_node_properties = content_node_properties,
                .projection_links = projection_links,
                .agent_inbox_created = root.created,
            };
        }

        pub fn agentWriteJsonBatch(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            parsed: ParsedAgentWriteJsonArgs,
            loaded_schema: schema.Registry,
            enforce_application_schema: bool,
        ) !AgentWriteJsonBatchResult {
            const stat = try std.Io.Dir.cwd().statFile(io, parsed.json_path, .{});
            if (stat.kind != .file or stat.size == 0 or stat.size > agent_write_json_max_bytes) return error.InvalidRecord;
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, parsed.json_path, allocator, .limited(agent_write_json_max_bytes));
            defer allocator.free(bytes);
            var batch = try std.json.parseFromSlice(AgentWriteBatchJson, allocator, bytes, .{
                .ignore_unknown_fields = true,
            });
            defer batch.deinit();

            if (batch.value.items.len == 0) return error.MissingArgument;
            var result = AgentWriteJsonBatchResult{};
            errdefer result.deinit(allocator);

            for (batch.value.items) |item| {
                try validateNodeTextGranularity(item.text);
                try validateNodeLlmMetadataGranularity(item.name, item.summary, item.retrieval_hints);
                const target_count: usize =
                    @as(usize, @intFromBool(item.document != null)) +
                    @as(usize, @intFromBool(item.section != null)) +
                    @as(usize, @intFromBool(item.agent_inbox));
                if (target_count > 1) return error.MissingArgument;

                const src_text = try std.fmt.allocPrint(allocator, "{}", .{item.src});
                defer allocator.free(src_text);
                const dst_text = try std.fmt.allocPrint(allocator, "{}", .{item.dst});
                defer allocator.free(dst_text);
                const document_text = if (item.document) |id| try std.fmt.allocPrint(allocator, "{}", .{id}) else null;
                defer if (document_text) |text| allocator.free(text);
                const section_text = if (item.section) |id| try std.fmt.allocPrint(allocator, "{}", .{id}) else null;
                defer if (section_text) |text| allocator.free(text);

                const src = core.NodeId.fromInt(item.src);
                const dst = core.NodeId.fromInt(item.dst);
                const fact_rel = try parseRelKindWithSchemaPolicy(item.rel, loaded_schema, enforce_application_schema);
                const render_rel = try parseRelKindWithLoadedSchema(item.render_rel orelse "md:paragraph", null);
                if (!agentWriteRenderRelSupported(render_rel)) return error.InvalidRelKind;
                if (enforce_application_schema) try validateSchemaEdgeEndpoints(store, loaded_schema, src, fact_rel, dst);

                const write_args = ParsedAgentWriteArgs{
                    .db_path = parsed.db_path,
                    .src_node_id = src_text,
                    .rel_label = item.rel,
                    .dst_node_id = dst_text,
                    .document_node_id = document_text,
                    .section_node_id = section_text,
                    .agent_inbox = item.agent_inbox or target_count == 0,
                    .text = item.text,
                    .name = item.name,
                    .summary = item.summary,
                    .retrieval_hints = item.retrieval_hints,
                    .render_rel_label = item.render_rel orelse "md:paragraph",
                    .schema_path = parsed.schema_path,
                };
                const item_result = try agentWriteFactAndProjection(allocator, io, store, write_args, src, fact_rel, dst, render_rel);
                result.items += 1;
                result.fact_created += @intFromBool(item_result.fact_created);
                result.projection_nodes_imported += item_result.projection_nodes_imported;
                result.projection_edge_created += @intFromBool(item_result.projection_edge_created);
                result.content_node_properties += item_result.content_node_properties;
                result.projection_links += item_result.projection_links;
                result.agent_inbox_created += @intFromBool(item_result.agent_inbox_created);
                if (item.fact_properties) |properties| {
                    result.fact_properties += try applyAgentWriteEdgeProperties(allocator, store, item_result.fact_edge_id, properties);
                }
                if (item.projection_properties) |properties| {
                    result.projection_properties += try applyAgentWriteEdgeProperties(allocator, store, item_result.projection_edge_id, properties);
                }
            }
            return result;
        }

        fn applyAgentWriteNodeProperties(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_id: core.NodeId,
            name: ?[]const u8,
            summary: ?[]const u8,
            retrieval_hints: ?[]const u8,
        ) !usize {
            try validateNodeLlmMetadataGranularity(name, summary, retrieval_hints);
            var count: usize = 0;
            const owner: storage.PropertyOwner = .{ .node = node_id };
            if (name) |value| {
                try store.setStringProperty(allocator, owner, "name", value);
                count += 1;
            }
            if (summary) |value| {
                try store.setStringProperty(allocator, owner, "summary", value);
                count += 1;
            }
            if (retrieval_hints) |value| {
                try store.setStringProperty(allocator, owner, "retrieval_hints", value);
                count += 1;
            }
            return count;
        }

        fn linkAgentWriteFactAndProjection(
            allocator: std.mem.Allocator,
            store: storage.Store,
            fact_edge_id: core.EdgeId,
            projection_edge_id: core.EdgeId,
        ) !usize {
            const projection_text = try std.fmt.allocPrint(allocator, "{}", .{projection_edge_id.toInt()});
            defer allocator.free(projection_text);
            const fact_text = try std.fmt.allocPrint(allocator, "{}", .{fact_edge_id.toInt()});
            defer allocator.free(fact_text);
            var count: usize = 0;
            count += try setAgentWriteEdgeProperty(allocator, store, fact_edge_id, "projection_edge_id", projection_text);
            count += try setAgentWriteEdgeProperty(allocator, store, projection_edge_id, "fact_edge_id", fact_text);
            return count;
        }

        fn applyAgentWriteEdgeProperties(
            allocator: std.mem.Allocator,
            store: storage.Store,
            edge_id: core.EdgeId,
            properties: AgentWriteEdgePropertiesJson,
        ) !usize {
            var count: usize = 0;
            if (properties.markdown_attr) |value| count += try setAgentWriteEdgeProperty(allocator, store, edge_id, "markdown_attr", value);
            if (properties.render_flags) |value| count += try setAgentWriteEdgeProperty(allocator, store, edge_id, "render_flags", value);
            if (properties.source_span) |value| count += try setAgentWriteEdgeProperty(allocator, store, edge_id, "source_span", value);
            if (properties.confidence) |value| count += try setAgentWriteEdgeProperty(allocator, store, edge_id, "confidence", value);
            if (properties.created_by) |value| count += try setAgentWriteEdgeProperty(allocator, store, edge_id, "created_by", value);
            if (properties.projection_edge_id) |value| count += try setAgentWriteEdgeProperty(allocator, store, edge_id, "projection_edge_id", value);
            if (properties.fact_edge_id) |value| count += try setAgentWriteEdgeProperty(allocator, store, edge_id, "fact_edge_id", value);
            return count;
        }

        fn setAgentWriteEdgeProperty(
            allocator: std.mem.Allocator,
            store: storage.Store,
            edge_id: core.EdgeId,
            key: []const u8,
            value: []const u8,
        ) !usize {
            const owner: storage.PropertyOwner = .{ .edge = edge_id };
            try validateParsedStringProperty(owner, key, value);
            try store.setStringProperty(allocator, owner, key, value);
            return 1;
        }

        pub fn lookupMarkdownProjectionEdgeByEndpoints(
            allocator: std.mem.Allocator,
            store: storage.Store,
            src: core.NodeId,
            rel: core.RelKind,
            dst: core.NodeId,
        ) !?core.EdgeId {
            var records = try readVisibleEdgeRecordsByNode(allocator, store, .src, src, rel);
            defer records.deinit(allocator);
            for (records.items) |record| {
                if (record.rel == @intFromEnum(rel) and record.dst == dst.toInt()) return .fromInt(record.edge_id);
            }
            return null;
        }

        fn agentWriteUpsertFactEdge(
            allocator: std.mem.Allocator,
            store: storage.Store,
            src: core.NodeId,
            rel: core.RelKind,
            dst: core.NodeId,
        ) !AgentWriteFactResult {
            if (try store.lookupFactEdgeByNodeExternalKeys(allocator, src, rel, dst)) |existing_id| {
                return .{ .edge_id = existing_id, .created = false };
            }
            const id = try dag.addEdgeCheckedWithPersistentStore(allocator, store, src, rel, dst, .{});
            store.refreshFactEdgeExternalKeyIndexAfterAppend(.{ .id = id, .src = src, .rel = rel, .dst = dst }) catch {};
            return .{ .edge_id = id, .created = true };
        }

        const AgentWriteProjectionRoot = struct {
            id: core.NodeId,
            external_key: []const u8,
            created: bool = false,
        };

        fn agentWriteProjectionRoot(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            parsed: ParsedAgentWriteArgs,
            import_result: *MarkdownDocumentImportResult,
        ) !AgentWriteProjectionRoot {
            if (parsed.agent_inbox) {
                const external_key = try std.fmt.allocPrint(allocator, "md-doc:agent-inbox:{s}", .{parsed.db_path});
                errdefer allocator.free(external_key);
                const text = "Agent Inbox";
                const node_text = try markdownIdentityNodeText(allocator, .{
                    .text = text,
                    .schema_type = "document",
                    .external_key = external_key,
                });
                defer allocator.free(node_text);
                var context = MarkdownImportContext{
                    .allocator = allocator,
                    .io = io,
                    .store = store,
                    .document_external_key = external_key,
                    .lookup_view = try store.openNodeTextLookupView(allocator),
                    .session_node_ids = std.StringHashMap(core.NodeId).init(allocator),
                    .session_node_external_keys = std.AutoHashMap(u64, []u8).init(allocator),
                    .session_edge_counts = std.StringHashMap(usize).init(allocator),
                    .desired_projection_owners = std.AutoHashMap(u64, void).init(allocator),
                    .session_owner_order_counts = std.AutoHashMap(u64, usize).init(allocator),
                    .pending_position_keys = std.StringHashMap(std.ArrayList(u64)).init(allocator),
                };
                defer context.deinit();
                const before = import_result.nodes_imported;
                const id = try markdownUpsertNode(&context, .document, node_text, external_key, "document", null, import_result);
                try flushMarkdownImportPendingWrites(&context);
                return .{ .id = id, .external_key = external_key, .created = import_result.nodes_imported > before };
            }

            const root_id = if (parsed.document_node_id) |id_text|
                try parseNodeIdArg(id_text)
            else if (parsed.section_node_id) |id_text|
                try parseNodeIdArg(id_text)
            else
                return error.MissingArgument;

            var node = (try store.readNodeById(allocator, root_id)) orelse return core.Error.NotFound;
            defer node.deinit(allocator);
            if (parsed.document_node_id != null and node.kind != .document) return core.Error.InvalidId;
            if (parsed.section_node_id != null and node.kind != .document_section and node.kind != .document) return core.Error.InvalidId;
            const external_key = (try markdownNodeExternalKeyForStoreAlloc(allocator, store, root_id, node.text)) orelse return error.InvalidRecord;
            return .{ .id = root_id, .external_key = external_key };
        }

        fn markdownNodeExternalKeyForStoreAlloc(allocator: std.mem.Allocator, store: storage.Store, node_id: core.NodeId, text: []const u8) !?[]const u8 {
            _ = text;
            const property_value = try store.getNodeStringProperty(allocator, node_id, "external_key");
            if (property_value) |value| return value;
            return null;
        }

        fn seedMarkdownOwnerOrderCount(context: *MarkdownImportContext, owner_id: core.NodeId) !void {
            var records = try markdownProjectionChildren(context.allocator, context.store, owner_id, null);
            defer records.deinit(context.allocator);
            if (records.items.len == 0) return;
            const entry = try context.session_owner_order_counts.getOrPut(owner_id.toInt());
            if (!entry.found_existing or entry.value_ptr.* < records.items.len) entry.value_ptr.* = records.items.len;
        }

        pub fn agentWriteRenderRelSupported(rel: core.RelKind) bool {
            return mdHeadingLevelFromRel(rel) != null or
                rel == md_rel_paragraph or
                rel == md_rel_image or
                rel == md_rel_code_block or
                isMarkdownRawTextProjectionRel(rel);
        }

        const MarkdownDocEditBenchGateResult = struct {
            edit_ns_per_paragraph: u128,
            edit_to_initial_bps: u128,
            changed_records_passed: bool,
            elapsed_passed: bool,
            per_paragraph_passed: bool,
            ratio_passed: bool,

            pub fn passed(self: MarkdownDocEditBenchGateResult) bool {
                return self.changed_records_passed and self.elapsed_passed and self.per_paragraph_passed and self.ratio_passed;
            }
        };

        const MarkdownDocEditMixedAgentBenchResult = struct {
            writes_requested: usize = 0,
            fact_created: usize = 0,
            projection_nodes_imported: usize = 0,
            projection_edge_created: usize = 0,
            agent_inbox_created: usize = 0,
            elapsed_ns: u128 = 0,
            render_local_subtree_elapsed_ns: u128 = 0,
            render_local_subtree_bytes: usize = 0,
            render_local_subtree_passed: bool = true,

            fn passed(self: MarkdownDocEditMixedAgentBenchResult) bool {
                return self.render_local_subtree_passed;
            }
        };

        const MarkdownDocEditRepeatedBenchResult = struct {
            edits_requested: usize = 0,
            insert_edits: usize = 0,
            delete_edits: usize = 0,
            nodes_imported: usize = 0,
            edges_imported: usize = 0,
            projection_edges_deleted: usize = 0,
            changed_records_total: usize = 0,
            changed_records_max: usize = 0,
            elapsed_ns: u128 = 0,
            elapsed_passed: bool = true,

            fn passed(self: MarkdownDocEditRepeatedBenchResult) bool {
                return self.elapsed_passed;
            }
        };

        const MarkdownDocEditRepeatedUpdateBenchResult = struct {
            edits_requested: usize = 0,
            update_edits: usize = 0,
            nodes_imported: usize = 0,
            edges_imported: usize = 0,
            projection_edges_deleted: usize = 0,
            changed_records_total: usize = 0,
            changed_records_max: usize = 0,
            elapsed_ns: u128 = 0,
            elapsed_passed: bool = true,

            fn passed(self: MarkdownDocEditRepeatedUpdateBenchResult) bool {
                return self.elapsed_passed;
            }
        };

        pub fn evaluateMarkdownDocEditBenchGates(
            parsed: ParsedMarkdownDocEditBenchArgs,
            initial_elapsed_ns: u128,
            edit_elapsed_ns: u128,
            edit_changed_records: usize,
        ) MarkdownDocEditBenchGateResult {
            const edit_ns_per_paragraph = ceilDivU128(edit_elapsed_ns, parsed.paragraphs);
            const edit_to_initial_bps = ratioBpsU128(edit_elapsed_ns, initial_elapsed_ns);
            return .{
                .edit_ns_per_paragraph = edit_ns_per_paragraph,
                .edit_to_initial_bps = edit_to_initial_bps,
                .changed_records_passed = if (parsed.max_edit_changed_records) |max_records| edit_changed_records <= max_records else true,
                .elapsed_passed = if (parsed.max_edit_elapsed_ns) |max_ns| edit_elapsed_ns <= max_ns else true,
                .per_paragraph_passed = if (parsed.max_edit_ns_per_paragraph) |max_ns| edit_ns_per_paragraph <= max_ns else true,
                .ratio_passed = if (parsed.max_edit_to_initial_bps) |max_bps| edit_to_initial_bps <= max_bps else true,
            };
        }

        fn ceilDivU128(numerator: u128, denominator: u128) u128 {
            if (denominator == 0) return std.math.maxInt(u128);
            return numerator / denominator + @intFromBool(numerator % denominator != 0);
        }

        fn ratioBpsU128(numerator: u128, denominator: u128) u128 {
            if (denominator == 0) return if (numerator == 0) 0 else std.math.maxInt(u128);
            const scaled = std.math.mul(u128, numerator, 10_000) catch return std.math.maxInt(u128);
            return ceilDivU128(scaled, denominator);
        }

        pub fn renderMarkdownDocEditBenchOutput(
            allocator: std.mem.Allocator,
            io: std.Io,
            parsed: ParsedMarkdownDocEditBenchArgs,
        ) ![]u8 {
            if (try anyPathExists(io, parsed.db_path)) return error.AlreadyExists;
            const markdown_path = try std.fmt.allocPrint(allocator, "{s}.mdbench.md", .{parsed.db_path});
            defer allocator.free(markdown_path);
            if (try anyPathExists(io, markdown_path)) return error.AlreadyExists;
            defer std.Io.Dir.cwd().deleteFile(io, markdown_path) catch {};

            const initial_markdown = try markdownDocEditBenchContent(allocator, parsed.paragraphs, parsed.edit_index, false);
            defer allocator.free(initial_markdown);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = markdown_path, .data = initial_markdown, .flags = .{ .truncate = true } });

            var store = try storage.Store.init(allocator, io, parsed.db_path);
            defer store.deinit();
            try store.createEmpty();
            const store_bytes_after_create = try storeDirBytes(allocator, io, parsed.db_path);

            const initial_start_ns = monotonicNs(io);
            const initial_result = try importMarkdownDocument(allocator, io, store, markdown_path);
            const initial_elapsed_ns = elapsedNs(io, initial_start_ns);
            const store_bytes_after_initial = try storeDirBytes(allocator, io, parsed.db_path);

            const edited_markdown = try markdownDocEditBenchContent(allocator, parsed.paragraphs, parsed.edit_index, true);
            defer allocator.free(edited_markdown);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = markdown_path, .data = edited_markdown, .flags = .{ .truncate = true } });

            const edit_start_ns = monotonicNs(io);
            const edit_result = try importMarkdownDocument(allocator, io, store, markdown_path);
            const edit_elapsed_ns = elapsedNs(io, edit_start_ns);
            const store_bytes_after_edit = try storeDirBytes(allocator, io, parsed.db_path);
            const edit_changed_records = edit_result.nodes_imported + edit_result.edges_imported + edit_result.projection_edges_deleted;
            const gate = evaluateMarkdownDocEditBenchGates(parsed, initial_elapsed_ns, edit_elapsed_ns, edit_changed_records);

            const rendered = try renderMarkdownDocument(allocator, store, initial_result.document_id);
            defer allocator.free(rendered);
            const expected_edit = try std.fmt.allocPrint(allocator, "Paragraph {d}: edited replacement", .{parsed.edit_index});
            defer allocator.free(expected_edit);
            if (std.mem.indexOf(u8, rendered, expected_edit) == null) return error.InvalidRecord;

            const local_render_root_id = try markdownDocEditBenchSectionId(allocator, store, markdown_path, markdown_doc_edit_bench_body_heading_index);
            const repeated_update_result = try runMarkdownDocEditRepeatedUpdateBench(allocator, io, store, parsed, markdown_path);
            const repeated_result = try runMarkdownDocEditRepeatedBench(allocator, io, store, parsed, markdown_path);
            const mixed_result = try runMarkdownDocEditMixedAgentBench(allocator, io, store, parsed, local_render_root_id);

            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);
            try out.print(
                "bench_workload=markdown-doc-edit paragraphs={} edit_index={}\n",
                .{ parsed.paragraphs, parsed.edit_index },
            );
            try out.print(
                "initial_document={} initial_nodes_imported={} initial_edges_imported={} initial_projection_edges_deleted={} initial_markdown_bytes={} initial_elapsed_ns={}\n",
                .{ initial_result.document_id.toInt(), initial_result.nodes_imported, initial_result.edges_imported, initial_result.projection_edges_deleted, initial_result.markdown_bytes, initial_elapsed_ns },
            );
            try out.print(
                "edit_document={} edit_nodes_imported={} edit_edges_imported={} edit_projection_edges_deleted={} edit_changed_records={} edit_markdown_bytes={} edit_elapsed_ns={} rendered_bytes={}\n",
                .{ edit_result.document_id.toInt(), edit_result.nodes_imported, edit_result.edges_imported, edit_result.projection_edges_deleted, edit_changed_records, edit_result.markdown_bytes, edit_elapsed_ns, rendered.len },
            );
            try out.print(
                "edit_latency_gate edit_ns_per_paragraph={} edit_to_initial_bps={} max_edit_changed_records_enabled={} max_edit_changed_records={} max_edit_elapsed_ns_enabled={} max_edit_elapsed_ns={} max_edit_ns_per_paragraph_enabled={} max_edit_ns_per_paragraph={} max_edit_to_initial_bps_enabled={} max_edit_to_initial_bps={} changed_records_passed={} elapsed_passed={} per_paragraph_passed={} ratio_passed={} passed={}\n",
                .{
                    gate.edit_ns_per_paragraph,
                    gate.edit_to_initial_bps,
                    @intFromBool(parsed.max_edit_changed_records != null),
                    parsed.max_edit_changed_records orelse 0,
                    @intFromBool(parsed.max_edit_elapsed_ns != null),
                    parsed.max_edit_elapsed_ns orelse 0,
                    @intFromBool(parsed.max_edit_ns_per_paragraph != null),
                    parsed.max_edit_ns_per_paragraph orelse 0,
                    @intFromBool(parsed.max_edit_to_initial_bps != null),
                    parsed.max_edit_to_initial_bps orelse 0,
                    @intFromBool(gate.changed_records_passed),
                    @intFromBool(gate.elapsed_passed),
                    @intFromBool(gate.per_paragraph_passed),
                    @intFromBool(gate.ratio_passed),
                    @intFromBool(gate.passed()),
                },
            );
            try out.print(
                "store_bytes_after_create={} store_bytes_after_initial={} store_bytes_after_edit={} initial_store_bytes_delta={} edit_store_bytes_delta={}\n",
                .{
                    store_bytes_after_create,
                    store_bytes_after_initial,
                    store_bytes_after_edit,
                    store_bytes_after_initial -| store_bytes_after_create,
                    store_bytes_after_edit -| store_bytes_after_initial,
                },
            );
            try out.print(
                "repeat_update_edit_gate enabled={} repeat_update_edits={} repeat_update_nodes_imported={} repeat_update_edges_imported={} repeat_update_projection_edges_deleted={} repeat_update_changed_records_total={} repeat_update_changed_records_max={} repeat_update_elapsed_ns={} max_repeat_update_edit_elapsed_ns_enabled={} max_repeat_update_edit_elapsed_ns={} elapsed_passed={} passed={}\n",
                .{
                    @intFromBool(parsed.repeat_update_edits != 0 or parsed.max_repeat_update_edit_elapsed_ns != null),
                    repeated_update_result.edits_requested,
                    repeated_update_result.nodes_imported,
                    repeated_update_result.edges_imported,
                    repeated_update_result.projection_edges_deleted,
                    repeated_update_result.changed_records_total,
                    repeated_update_result.changed_records_max,
                    repeated_update_result.elapsed_ns,
                    @intFromBool(parsed.max_repeat_update_edit_elapsed_ns != null),
                    parsed.max_repeat_update_edit_elapsed_ns orelse 0,
                    @intFromBool(repeated_update_result.elapsed_passed),
                    @intFromBool(repeated_update_result.passed()),
                },
            );
            try out.print(
                "repeat_local_edit_gate enabled={} repeat_local_edits={} repeat_insert_edits={} repeat_delete_edits={} repeat_nodes_imported={} repeat_edges_imported={} repeat_projection_edges_deleted={} repeat_changed_records_total={} repeat_changed_records_max={} repeat_elapsed_ns={} max_repeat_edit_elapsed_ns_enabled={} max_repeat_edit_elapsed_ns={} elapsed_passed={} passed={}\n",
                .{
                    @intFromBool(parsed.repeat_local_edits != 0 or parsed.max_repeat_edit_elapsed_ns != null),
                    repeated_result.edits_requested,
                    repeated_result.insert_edits,
                    repeated_result.delete_edits,
                    repeated_result.nodes_imported,
                    repeated_result.edges_imported,
                    repeated_result.projection_edges_deleted,
                    repeated_result.changed_records_total,
                    repeated_result.changed_records_max,
                    repeated_result.elapsed_ns,
                    @intFromBool(parsed.max_repeat_edit_elapsed_ns != null),
                    parsed.max_repeat_edit_elapsed_ns orelse 0,
                    @intFromBool(repeated_result.elapsed_passed),
                    @intFromBool(repeated_result.passed()),
                },
            );
            try out.print(
                "agent_mixed_gate enabled={} agent_mixed_writes={} agent_mixed_fact_created={} agent_mixed_projection_nodes_imported={} agent_mixed_projection_edge_created={} agent_mixed_agent_inbox_created={} agent_mixed_elapsed_ns={} render_local_subtree_root={} render_local_subtree_elapsed_ns={} render_local_subtree_bytes={} max_render_local_subtree_elapsed_ns_enabled={} max_render_local_subtree_elapsed_ns={} render_local_subtree_passed={} passed={}\n",
                .{
                    @intFromBool(parsed.agent_mixed_writes != 0 or parsed.max_render_local_subtree_elapsed_ns != null),
                    mixed_result.writes_requested,
                    mixed_result.fact_created,
                    mixed_result.projection_nodes_imported,
                    mixed_result.projection_edge_created,
                    mixed_result.agent_inbox_created,
                    mixed_result.elapsed_ns,
                    local_render_root_id.toInt(),
                    mixed_result.render_local_subtree_elapsed_ns,
                    mixed_result.render_local_subtree_bytes,
                    @intFromBool(parsed.max_render_local_subtree_elapsed_ns != null),
                    parsed.max_render_local_subtree_elapsed_ns orelse 0,
                    @intFromBool(mixed_result.render_local_subtree_passed),
                    @intFromBool(mixed_result.passed()),
                },
            );
            if (!gate.passed() or !repeated_update_result.passed() or !repeated_result.passed() or !mixed_result.passed()) return core.Error.BudgetExceeded;
            return out.buffer.toOwnedSlice(allocator);
        }

        fn runMarkdownDocEditRepeatedUpdateBench(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            parsed: ParsedMarkdownDocEditBenchArgs,
            markdown_path: []const u8,
        ) !MarkdownDocEditRepeatedUpdateBenchResult {
            var result = MarkdownDocEditRepeatedUpdateBenchResult{
                .edits_requested = parsed.repeat_update_edits,
            };
            if (parsed.repeat_update_edits == 0) {
                result.elapsed_passed = if (parsed.max_repeat_update_edit_elapsed_ns) |max_ns| result.elapsed_ns <= max_ns else true;
                return result;
            }

            const start_ns = monotonicNs(io);
            var iteration: usize = 0;
            while (iteration < parsed.repeat_update_edits) : (iteration += 1) {
                const content = try markdownDocEditBenchContentVariant(allocator, parsed.paragraphs, parsed.edit_index, .update, iteration);
                defer allocator.free(content);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = markdown_path, .data = content, .flags = .{ .truncate = true } });
                const edit_result = try importMarkdownDocument(allocator, io, store, markdown_path);
                const changed_records = edit_result.nodes_imported + edit_result.edges_imported + edit_result.projection_edges_deleted;
                result.nodes_imported += edit_result.nodes_imported;
                result.edges_imported += edit_result.edges_imported;
                result.projection_edges_deleted += edit_result.projection_edges_deleted;
                result.changed_records_total += changed_records;
                if (result.changed_records_max < changed_records) result.changed_records_max = changed_records;
                result.update_edits += 1;
            }
            result.elapsed_ns = elapsedNs(io, start_ns);
            result.elapsed_passed = if (parsed.max_repeat_update_edit_elapsed_ns) |max_ns| result.elapsed_ns <= max_ns else true;
            return result;
        }

        fn runMarkdownDocEditRepeatedBench(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            parsed: ParsedMarkdownDocEditBenchArgs,
            markdown_path: []const u8,
        ) !MarkdownDocEditRepeatedBenchResult {
            var result = MarkdownDocEditRepeatedBenchResult{
                .edits_requested = parsed.repeat_local_edits,
            };
            if (parsed.repeat_local_edits == 0) {
                result.elapsed_passed = if (parsed.max_repeat_edit_elapsed_ns) |max_ns| result.elapsed_ns <= max_ns else true;
                return result;
            }

            const start_ns = monotonicNs(io);
            var iteration: usize = 0;
            while (iteration < parsed.repeat_local_edits) : (iteration += 1) {
                const mode: MarkdownDocEditBenchContentMode = if (iteration % 2 == 0) .insert else .delete;
                const content = try markdownDocEditBenchContentVariant(allocator, parsed.paragraphs, parsed.edit_index, mode, iteration);
                defer allocator.free(content);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = markdown_path, .data = content, .flags = .{ .truncate = true } });
                const edit_result = try importMarkdownDocument(allocator, io, store, markdown_path);
                const changed_records = edit_result.nodes_imported + edit_result.edges_imported + edit_result.projection_edges_deleted;
                result.nodes_imported += edit_result.nodes_imported;
                result.edges_imported += edit_result.edges_imported;
                result.projection_edges_deleted += edit_result.projection_edges_deleted;
                result.changed_records_total += changed_records;
                if (result.changed_records_max < changed_records) result.changed_records_max = changed_records;
                switch (mode) {
                    .insert => result.insert_edits += 1,
                    .delete => result.delete_edits += 1,
                    else => unreachable,
                }
            }
            result.elapsed_ns = elapsedNs(io, start_ns);
            result.elapsed_passed = if (parsed.max_repeat_edit_elapsed_ns) |max_ns| result.elapsed_ns <= max_ns else true;
            return result;
        }

        fn runMarkdownDocEditMixedAgentBench(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            parsed: ParsedMarkdownDocEditBenchArgs,
            local_render_root_id: core.NodeId,
        ) !MarkdownDocEditMixedAgentBenchResult {
            var result = MarkdownDocEditMixedAgentBenchResult{
                .writes_requested = parsed.agent_mixed_writes,
            };
            if (parsed.agent_mixed_writes == 0) {
                const render_start_ns = monotonicNs(io);
                const rendered = try renderMarkdownDocument(allocator, store, local_render_root_id);
                defer allocator.free(rendered);
                result.render_local_subtree_elapsed_ns = elapsedNs(io, render_start_ns);
                result.render_local_subtree_bytes = rendered.len;
                result.render_local_subtree_passed = if (parsed.max_render_local_subtree_elapsed_ns) |max_ns| result.render_local_subtree_elapsed_ns <= max_ns else true;
                return result;
            }

            const src_id = try addMarkdownDocEditBenchNode(allocator, store, .concept, "Benchmark mixed source", "bench_claim", "mixed-src");
            const dst_ids = try allocator.alloc(core.NodeId, parsed.agent_mixed_writes);
            defer allocator.free(dst_ids);
            for (dst_ids, 0..) |*dst_id, i| {
                const label = try std.fmt.allocPrint(allocator, "Benchmark mixed evidence {d}", .{i});
                defer allocator.free(label);
                const suffix = try std.fmt.allocPrint(allocator, "mixed-dst-{d}", .{i});
                defer allocator.free(suffix);
                dst_id.* = try addMarkdownDocEditBenchNode(allocator, store, .evidence, label, "bench_evidence", suffix);
            }

            const src_text = try std.fmt.allocPrint(allocator, "{}", .{src_id.toInt()});
            defer allocator.free(src_text);
            const section_text = try std.fmt.allocPrint(allocator, "{}", .{local_render_root_id.toInt()});
            defer allocator.free(section_text);

            const mixed_start_ns = monotonicNs(io);
            for (dst_ids, 0..) |dst_id, i| {
                const dst_text = try std.fmt.allocPrint(allocator, "{}", .{dst_id.toInt()});
                defer allocator.free(dst_text);
                const text = try std.fmt.allocPrint(allocator, "Agent mixed write {d}: benchmark visible projection attachment.", .{i});
                defer allocator.free(text);
                const write_args = ParsedAgentWriteArgs{
                    .db_path = parsed.db_path,
                    .src_node_id = src_text,
                    .rel_label = "references",
                    .dst_node_id = dst_text,
                    .section_node_id = section_text,
                    .text = text,
                    .render_rel_label = "md:paragraph",
                };
                const write_result = try agentWriteFactAndProjection(allocator, io, store, write_args, src_id, .references, dst_id, md_rel_paragraph);
                result.fact_created += @intFromBool(write_result.fact_created);
                result.projection_nodes_imported += write_result.projection_nodes_imported;
                result.projection_edge_created += @intFromBool(write_result.projection_edge_created);
                result.agent_inbox_created += @intFromBool(write_result.agent_inbox_created);
            }
            result.elapsed_ns = elapsedNs(io, mixed_start_ns);

            const render_start_ns = monotonicNs(io);
            const rendered = try renderMarkdownDocument(allocator, store, local_render_root_id);
            defer allocator.free(rendered);
            result.render_local_subtree_elapsed_ns = elapsedNs(io, render_start_ns);
            result.render_local_subtree_bytes = rendered.len;
            result.render_local_subtree_passed = if (parsed.max_render_local_subtree_elapsed_ns) |max_ns| result.render_local_subtree_elapsed_ns <= max_ns else true;
            return result;
        }

        fn addMarkdownDocEditBenchNode(
            allocator: std.mem.Allocator,
            store: storage.Store,
            kind: core.NodeKind,
            label: []const u8,
            schema_type: []const u8,
            external_suffix: []const u8,
        ) !core.NodeId {
            const external_key = try std.fmt.allocPrint(allocator, "bench-md-doc-edit:{s}", .{external_suffix});
            defer allocator.free(external_key);
            const node_text = try markdownIdentityNodeText(allocator, .{
                .text = label,
                .schema_type = schema_type,
                .external_key = external_key,
            });
            defer allocator.free(node_text);
            return try store.addNode(kind, node_text);
        }

        const markdown_doc_edit_bench_body_heading_index: usize = 1;

        const MarkdownDocEditBenchContentMode = enum {
            initial,
            edited,
            update,
            insert,
            delete,
        };

        fn markdownDocEditBenchContent(allocator: std.mem.Allocator, paragraphs: usize, edit_index: usize, edited: bool) ![]u8 {
            return markdownDocEditBenchContentVariant(allocator, paragraphs, edit_index, if (edited) .edited else .initial, 0);
        }

        fn markdownDocEditBenchContentVariant(
            allocator: std.mem.Allocator,
            paragraphs: usize,
            edit_index: usize,
            mode: MarkdownDocEditBenchContentMode,
            iteration: usize,
        ) ![]u8 {
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);
            try out.writeAll("# Markdown Doc Edit Bench\n\n");
            try out.writeAll("## Local Edit Section\n\n");
            for (0..paragraphs) |i| {
                if (i == edit_index and mode == .delete) continue;
                if (i == edit_index and mode == .update) {
                    try out.print("Paragraph {d}: update-only replacement iteration {d} for markdown doc edit benchmark local update.\n\n", .{ i, iteration });
                } else if (i == edit_index and (mode == .edited or mode == .insert)) {
                    try out.print("Paragraph {d}: edited replacement for markdown doc edit benchmark local update.\n\n", .{i});
                } else {
                    try out.print("Paragraph {d}: stable markdown doc edit benchmark content token_{d} remains unchanged across imports.\n\n", .{ i, i });
                }
                if (i == edit_index and mode == .insert) {
                    try out.print("Repeated insert {d}: local inserted markdown doc edit benchmark paragraph.\n\n", .{iteration});
                }
            }
            return out.buffer.toOwnedSlice(allocator);
        }

        fn markdownDocEditBenchSectionId(
            allocator: std.mem.Allocator,
            store: storage.Store,
            markdown_path: []const u8,
            heading_index: usize,
        ) !core.NodeId {
            const heading_text = switch (heading_index) {
                0 => "Markdown Doc Edit Bench",
                1 => "Local Edit Section",
                else => return core.Error.NotFound,
            };
            const heading_hash = try markdownContentHashAlloc(allocator, heading_text);
            defer allocator.free(heading_hash);
            const external_key = try std.fmt.allocPrint(allocator, "md-doc:{s}#heading:{d}:{s}", .{ markdown_path, heading_index, heading_hash });
            defer allocator.free(external_key);
            var hits = try store.lookupNodeIdsByStringProperty(allocator, "external_key", external_key, .document_section, 1);
            defer hits.deinit(allocator);
            if (hits.items.len != 0) return hits.items[0];
            return (try store.lookupNodeByExternalKey(allocator, external_key, .document_section)) orelse core.Error.NotFound;
        }

        fn importMarkdownFlushParagraph(
            context: *MarkdownImportContext,
            document_id: core.NodeId,
            paragraph: *std.ArrayList(u8),
            result: *MarkdownDocumentImportResult,
        ) !void {
            const text = std.mem.trim(u8, paragraph.items, " \t\r\n");
            if (text.len != 0) {
                try importMarkdownProjectionBlock(context, document_id, .{ .rel = md_rel_paragraph, .text = text }, result);
            }
            paragraph.clearRetainingCapacity();
        }

        fn importMarkdownProjectionLines(
            context: *MarkdownImportContext,
            document_id: core.NodeId,
            rel: core.RelKind,
            lines: []const []const u8,
            result: *MarkdownDocumentImportResult,
        ) !void {
            var block = std.ArrayList(u8).empty;
            defer block.deinit(context.allocator);
            for (lines, 0..) |line, line_index| {
                if (line_index != 0) try block.append(context.allocator, '\n');
                try block.appendSlice(context.allocator, line);
            }
            try importMarkdownProjectionBlock(context, document_id, .{ .rel = rel, .text = block.items }, result);
        }

        fn importMarkdownProjectionBlock(
            context: *MarkdownImportContext,
            document_id: core.NodeId,
            block: MarkdownProjectionBlock,
            result: *MarkdownDocumentImportResult,
        ) !void {
            if (block.rel != md_rel_image and markdownTextExceedsChunkLimit(block.text)) {
                return importMarkdownChunkedProjectionBlock(context, document_id, block, result);
            }
            const node_kind: core.NodeKind = if (block.rel == md_rel_image) .image else .observation;
            const schema_type = if (block.rel == md_rel_image) "content_image" else "content_text";
            const content_id = try importMarkdownContentNode(context, node_kind, block.text, schema_type, result);
            if (try appendMarkdownProjectionEdge(context, document_id, block.rel, content_id)) result.edges_imported += 1;
        }

        fn importMarkdownChunkedProjectionBlock(
            context: *MarkdownImportContext,
            document_id: core.NodeId,
            block: MarkdownProjectionBlock,
            result: *MarkdownDocumentImportResult,
        ) !void {
            var chunks = try markdownHeuristicTextChunks(context.allocator, block.text, markdown_ast_text_chunk_chars);
            defer chunks.deinit(context.allocator);
            if (chunks.items.len <= 1) {
                const content_id = try importMarkdownContentNode(context, .observation, block.text, "content_text", result);
                if (try appendMarkdownProjectionEdge(context, document_id, block.rel, content_id)) result.edges_imported += 1;
                return;
            }
            const content_hash = try markdownContentHashAlloc(context.allocator, block.text);
            defer context.allocator.free(content_hash);
            const chunked_index = context.session_chunked_block_count;
            context.session_chunked_block_count += 1;
            const occurrence_external_key = try std.fmt.allocPrint(context.allocator, "{s}#chunked:{d}:{d}:{s}", .{ context.document_external_key, chunked_index, @intFromEnum(block.rel), content_hash });
            defer context.allocator.free(occurrence_external_key);
            const occurrence_text = try std.fmt.allocPrint(context.allocator, "markdown_chunked_block rel={s} chunks={}", .{ schema.markdownProjectionRelationNameById(@intFromEnum(block.rel)) orelse "md:unknown", chunks.items.len });
            defer context.allocator.free(occurrence_text);
            const occurrence_id = try importMarkdownOccurrenceNode(context, occurrence_text, "markdown_chunked_block", occurrence_external_key, result);
            if (try appendMarkdownProjectionEdge(context, document_id, block.rel, occurrence_id)) result.edges_imported += 1;
            for (chunks.items) |chunk| {
                const chunk_id = try importMarkdownContentNode(context, .observation, chunk, "content_text", result);
                if (try appendMarkdownProjectionEdge(context, occurrence_id, md_rel_text_chunk, chunk_id)) result.edges_imported += 1;
                result.text_chunks += 1;
            }
        }

        fn markdownTextExceedsChunkLimit(text: []const u8) bool {
            const chars = std.unicode.utf8CountCodepoints(text) catch return true;
            return chars > markdown_ast_text_chunk_chars;
        }

        fn markdownHeuristicTextChunks(allocator: std.mem.Allocator, text: []const u8, max_chars: usize) !std.ArrayList([]const u8) {
            var chunks = std.ArrayList([]const u8).empty;
            errdefer chunks.deinit(allocator);
            var start: usize = 0;
            while (start < text.len) {
                const remaining_chars = std.unicode.utf8CountCodepoints(text[start..]) catch return error.InvalidRecord;
                if (remaining_chars <= max_chars) {
                    try chunks.append(allocator, text[start..]);
                    break;
                }
                const hard_end = markdownUtf8PrefixEndByChars(text, start, max_chars);
                const end = markdownBestChunkBoundary(text, start, hard_end);
                try chunks.append(allocator, text[start..end]);
                start = end;
            }
            return chunks;
        }

        pub fn markdownUtf8PrefixEndByChars(text: []const u8, start: usize, max_chars: usize) usize {
            var index = start;
            var chars: usize = 0;
            while (index < text.len and chars < max_chars) : (chars += 1) {
                const len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
                if (index + len > text.len) break;
                index += len;
            }
            return if (index > start) index else @min(text.len, start + 1);
        }

        fn markdownBestChunkBoundary(text: []const u8, start: usize, hard_end: usize) usize {
            const min_end = start + (hard_end - start) / 2;
            if (markdownLastPatternBoundary(text, start, hard_end, min_end, "\n\n")) |end| return end;
            if (markdownLastStrongPunctuationBoundary(text, start, hard_end, min_end)) |end| return end;
            if (markdownLastWeakPunctuationBoundary(text, start, hard_end, min_end)) |end| return end;
            if (markdownLastWhitespaceBoundary(text, start, hard_end, min_end)) |end| return end;
            return hard_end;
        }

        fn markdownLastPatternBoundary(text: []const u8, start: usize, hard_end: usize, min_end: usize, pattern: []const u8) ?usize {
            if (pattern.len == 0 or hard_end <= start + pattern.len) return null;
            var index = hard_end - pattern.len;
            while (index >= start) : (index -= 1) {
                const end = index + pattern.len;
                if (end >= min_end and std.mem.eql(u8, text[index..end], pattern)) return end;
                if (index == start) break;
            }
            return null;
        }

        fn markdownLastStrongPunctuationBoundary(text: []const u8, start: usize, hard_end: usize, min_end: usize) ?usize {
            var index = hard_end;
            while (index > start) {
                index -= 1;
                if (index + 3 <= text.len and markdownChineseStrongPunctuation(text[index..@min(text.len, index + 3)])) {
                    const end = index + 3;
                    if (end >= min_end and end <= hard_end) return end;
                }
                if (text[index] == '.' or text[index] == '!' or text[index] == '?' or text[index] == ';' or text[index] == ':') {
                    const end = index + 1;
                    if (end >= min_end) return end;
                }
            }
            return null;
        }

        fn markdownLastWeakPunctuationBoundary(text: []const u8, start: usize, hard_end: usize, min_end: usize) ?usize {
            var index = hard_end;
            while (index > start) {
                index -= 1;
                if (index + 3 <= text.len and markdownChineseWeakPunctuation(text[index..@min(text.len, index + 3)])) {
                    const end = index + 3;
                    if (end >= min_end and end <= hard_end) return end;
                }
                if (text[index] == ',' or text[index] == ')') {
                    const end = index + 1;
                    if (end >= min_end) return end;
                }
            }
            return null;
        }

        fn markdownChineseStrongPunctuation(bytes: []const u8) bool {
            return std.mem.startsWith(u8, bytes, "。") or
                std.mem.startsWith(u8, bytes, "！") or
                std.mem.startsWith(u8, bytes, "？") or
                std.mem.startsWith(u8, bytes, "；");
        }

        fn markdownChineseWeakPunctuation(bytes: []const u8) bool {
            return std.mem.startsWith(u8, bytes, "，") or
                std.mem.startsWith(u8, bytes, "、") or
                std.mem.startsWith(u8, bytes, "）");
        }

        fn markdownLastWhitespaceBoundary(text: []const u8, start: usize, hard_end: usize, min_end: usize) ?usize {
            var index = hard_end;
            while (index > start) {
                index -= 1;
                if (std.ascii.isWhitespace(text[index])) {
                    const end = index + 1;
                    if (end >= min_end) return end;
                }
            }
            return null;
        }

        fn importMarkdownHeadingSection(
            context: *MarkdownImportContext,
            document_id: core.NodeId,
            heading_index: usize,
            heading: MarkdownHeading,
            result: *MarkdownDocumentImportResult,
        ) !MarkdownHeadingSection {
            const heading_hash = try markdownContentHashAlloc(context.allocator, heading.text);
            defer context.allocator.free(heading_hash);
            const external_key = try std.fmt.allocPrint(context.allocator, "{s}#heading:{d}:{s}", .{ context.document_external_key, heading_index, heading_hash });
            defer context.allocator.free(external_key);
            const safe_heading = try markdownNodeLabelWithinLimitAlloc(context.allocator, heading.text, "heading");
            defer context.allocator.free(safe_heading);
            const section_id = try importMarkdownOccurrenceNode(context, safe_heading, "document_section", external_key, result);
            return .{
                .id = section_id,
                .edge_created = try appendMarkdownProjectionEdge(context, document_id, mdHeadingRel(heading.level), section_id),
            };
        }

        fn importMarkdownContentNode(
            context: *MarkdownImportContext,
            kind: core.NodeKind,
            text: []const u8,
            schema_type: []const u8,
            result: *MarkdownDocumentImportResult,
        ) !core.NodeId {
            const content_hash = try markdownContentHashAlloc(context.allocator, text);
            defer context.allocator.free(content_hash);
            const external_key = try std.fmt.allocPrint(context.allocator, "content:{s}:{s}", .{ schema_type, content_hash });
            defer context.allocator.free(external_key);
            const node_text = try markdownIdentityNodeText(context.allocator, .{
                .text = text,
                .schema_type = schema_type,
                .external_key = external_key,
                .content_hash = content_hash,
            });
            defer context.allocator.free(node_text);
            return try markdownUpsertNode(context, kind, node_text, external_key, schema_type, content_hash, result);
        }

        fn importMarkdownOccurrenceNode(
            context: *MarkdownImportContext,
            text: []const u8,
            schema_type: []const u8,
            external_key: []const u8,
            result: *MarkdownDocumentImportResult,
        ) !core.NodeId {
            const node_text = try markdownIdentityNodeText(context.allocator, .{
                .text = text,
                .schema_type = schema_type,
                .external_key = external_key,
            });
            defer context.allocator.free(node_text);
            return try markdownUpsertNode(context, .document_section, node_text, external_key, schema_type, null, result);
        }

        const MarkdownIdentityNodeTextArgs = struct {
            text: []const u8,
            schema_type: []const u8,
            external_key: []const u8,
            content_hash: ?[]const u8 = null,
        };

        fn markdownIdentityNodeText(
            allocator: std.mem.Allocator,
            args: MarkdownIdentityNodeTextArgs,
        ) ![]const u8 {
            try validateGovernanceMetadataToken(args.schema_type);
            try validateNodeTextGranularity(args.text);
            _ = args.external_key;
            _ = args.content_hash;
            return try allocator.dupe(u8, args.text);
        }

        fn markdownUpsertNode(
            context: *MarkdownImportContext,
            kind: core.NodeKind,
            node_text: []const u8,
            external_key: []const u8,
            schema_type: []const u8,
            content_hash: ?[]const u8,
            result: *MarkdownDocumentImportResult,
        ) !core.NodeId {
            if (context.session_node_ids.get(external_key)) |id| return id;
            if (try markdownLookupExistingNode(context, external_key, kind)) |id| {
                try markdownRememberSessionNode(context, external_key, id);
                return id;
            }
            if (try context.lookup_view.lookupFirstId(kind, node_text)) |id| {
                try markdownRememberSessionNode(context, external_key, id);
                return id;
            }
            const id = try markdownNextPendingNodeId(context);
            {
                const owned_name = try context.allocator.dupe(u8, node_text);
                errdefer context.allocator.free(owned_name);
                try context.pending_nodes.append(context.allocator, .{
                    .id = id,
                    .kind = kind,
                    .text = owned_name,
                });
            }
            {
                var properties = try markdownPendingNodePropertiesAlloc(
                    context.allocator,
                    id,
                    schema_type,
                    external_key,
                    content_hash,
                );
                errdefer properties.deinit(context.allocator);
                try context.pending_node_properties.append(context.allocator, properties);
            }
            result.nodes_imported += 1;
            try markdownRememberSessionNode(context, external_key, id);
            return id;
        }

        fn markdownLookupExistingNode(context: *MarkdownImportContext, external_key: []const u8, kind: core.NodeKind) !?core.NodeId {
            var property_hits = try context.store.lookupNodeIdsByStringProperty(context.allocator, "external_key", external_key, kind, 1);
            defer property_hits.deinit(context.allocator);
            if (property_hits.items.len != 0) return property_hits.items[0];
            if (context.use_cached_node_lookup) {
                if (context.node_lookup_cache == null) {
                    context.node_lookup_cache = try context.store.buildNodeExternalKeyLookupCache(context.allocator);
                }
                return try context.store.lookupNodeByExternalKeyCached(context.allocator, external_key, kind, &context.node_lookup_cache.?);
            }
            return try context.store.lookupNodeByExternalKey(context.allocator, external_key, kind);
        }

        fn markdownNextPendingNodeId(context: *MarkdownImportContext) !core.NodeId {
            if (context.next_pending_node_id) |id| {
                if (id.toInt() == std.math.maxInt(u64)) return error.InvalidRecord;
                const next = core.NodeId.fromInt(id.toInt() + 1);
                context.next_pending_node_id = next;
                return next;
            }
            const id = try context.store.nextNodeId();
            context.next_pending_node_id = id;
            return id;
        }

        fn flushMarkdownImportPendingWrites(context: *MarkdownImportContext) !void {
            try flushMarkdownImportPendingNodes(context);
            try flushMarkdownImportPendingEdges(context);
        }

        fn flushMarkdownImportPendingNodes(context: *MarkdownImportContext) !void {
            if (context.pending_nodes.items.len == 0) return;
            try context.store.appendNodesBatch(context.pending_nodes.items);
            for (context.pending_node_properties.items) |properties| {
                const owner: storage.PropertyOwner = .{ .node = properties.node_id };
                try context.store.setStringProperty(context.allocator, owner, "schema_type", properties.schema_type);
                try context.store.setStringProperty(context.allocator, owner, "external_key", properties.external_key);
                if (properties.content_hash) |content_hash| try context.store.setStringProperty(context.allocator, owner, "content_hash", content_hash);
            }
            for (context.pending_nodes.items) |node| context.allocator.free(node.text);
            for (context.pending_node_properties.items) |*properties| properties.deinit(context.allocator);
            context.pending_nodes.clearRetainingCapacity();
            context.pending_node_properties.clearRetainingCapacity();
        }

        fn flushMarkdownImportPendingEdges(context: *MarkdownImportContext) !void {
            if (context.pending_edges.items.len == 0) return;
            var edges = try context.allocator.alloc(graph.Edge, context.pending_edges.items.len);
            defer context.allocator.free(edges);
            var order_keys = try context.allocator.alloc(u64, context.pending_edges.items.len);
            defer context.allocator.free(order_keys);

            const first_edge_id = try context.store.nextEdgeId();
            for (context.pending_edges.items, 0..) |edge, index| {
                const edge_id = std.math.add(u64, first_edge_id.toInt(), index) catch return error.InvalidRecord;
                edges[index] = .{
                    .id = core.EdgeId.fromInt(edge_id),
                    .src = edge.src,
                    .rel = edge.rel,
                    .dst = edge.dst,
                };
                order_keys[index] = edge.order_key;
            }
            try context.store.appendEdgesOrderedBatch(edges, order_keys);
            context.pending_edges.clearRetainingCapacity();
        }

        fn markdownRememberSessionNode(context: *MarkdownImportContext, external_key: []const u8, id: core.NodeId) !void {
            {
                const owned_key = try context.allocator.dupe(u8, external_key);
                errdefer context.allocator.free(owned_key);
                try context.session_node_ids.put(owned_key, id);
            }
            try markdownRememberSessionNodeExternalKey(context, external_key, id);
        }

        fn markdownRememberSessionNodeExternalKey(context: *MarkdownImportContext, external_key: []const u8, id: core.NodeId) !void {
            if (context.session_node_external_keys.contains(id.toInt())) return;
            const owned_key = try context.allocator.dupe(u8, external_key);
            errdefer context.allocator.free(owned_key);
            const entry = try context.session_node_external_keys.getOrPut(id.toInt());
            if (entry.found_existing) {
                context.allocator.free(owned_key);
                return;
            }
            entry.value_ptr.* = owned_key;
        }

        fn markdownContentHashAlloc(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
            return try std.fmt.allocPrint(allocator, "wyhash64:{x:0>16}", .{std.hash.Wyhash.hash(0, text)});
        }

        fn markdownNodeLabelWithinLimitAlloc(allocator: std.mem.Allocator, text: []const u8, label: []const u8) ![]u8 {
            return markdownNodeLabelWithinMaxCharsAlloc(allocator, text, label, node_text_char_limit);
        }

        fn markdownNodeLabelWithinMaxCharsAlloc(allocator: std.mem.Allocator, text: []const u8, label: []const u8, max_chars: usize) ![]u8 {
            const chars = std.unicode.utf8CountCodepoints(text) catch return error.InvalidRecord;
            if (chars <= max_chars) return try allocator.dupe(u8, text);
            const hash = try markdownContentHashAlloc(allocator, text);
            defer allocator.free(hash);
            const suffix = try std.fmt.allocPrint(allocator, " ... [truncated {s} {s}]", .{ label, hash });
            defer allocator.free(suffix);
            const suffix_chars = std.unicode.utf8CountCodepoints(suffix) catch return error.InvalidRecord;
            if (suffix_chars >= max_chars) return error.NodeTextTooLarge;
            const prefix_chars = max_chars - suffix_chars;
            const prefix_end = markdownUtf8PrefixEndByChars(text, 0, prefix_chars);
            return try std.fmt.allocPrint(allocator, "{s}{s}", .{ text[0..prefix_end], suffix });
        }

        fn importMarkdownTable(
            context: *MarkdownImportContext,
            document_id: core.NodeId,
            table_index: usize,
            rows: []const []const u8,
            result: *MarkdownDocumentImportResult,
        ) !void {
            const table_external_key = try std.fmt.allocPrint(context.allocator, "{s}#table:{d}", .{ context.document_external_key, table_index });
            defer context.allocator.free(table_external_key);
            const table_id = try importMarkdownOccurrenceNode(context, "markdown_table", "markdown_table", table_external_key, result);
            if (try appendMarkdownProjectionEdge(context, document_id, md_rel_table, table_id)) result.edges_imported += 1;
            for (rows, 0..) |row_line, row_index| {
                const row_external_key = try std.fmt.allocPrint(context.allocator, "{s}#row:{d}", .{ table_external_key, row_index });
                defer context.allocator.free(row_external_key);
                const row_id = try importMarkdownOccurrenceNode(context, "markdown_table_row", "markdown_table_row", row_external_key, result);
                if (try appendMarkdownProjectionEdge(context, table_id, md_rel_table_row, row_id)) result.edges_imported += 1;
                var cells = std.mem.splitScalar(u8, row_line, '|');
                while (cells.next()) |cell_raw| {
                    const cell = std.mem.trim(u8, cell_raw, " \t");
                    if (cell.len == 0) continue;
                    const cell_id = try importMarkdownContentNode(context, .observation, cell, "content_text", result);
                    if (try appendMarkdownProjectionEdge(context, row_id, md_rel_table_cell, cell_id)) result.edges_imported += 1;
                }
            }
        }

        pub fn appendMarkdownProjectionEdge(context: *MarkdownImportContext, src: core.NodeId, rel: core.RelKind, dst: core.NodeId) !bool {
            try context.desired_projection_owners.put(src.toInt(), {});
            const edge_key = try markdownProjectionEdgeKey(context.allocator, src, rel, dst);
            defer context.allocator.free(edge_key);
            const used_count = context.session_edge_counts.get(edge_key) orelse 0;
            const order_key = try markdownNextOwnerOrderKey(context, src);
            // 位置键入队(所有路径:新建/identity 复用/计数复用统一)——assign 阶段按活边消费。
            // **借用 key 永远不进 map**(Linus:getOrPut 借用 key 后 dupe OOM → map 持有将被 defer
            // free 的指针 → deinit double-free):先 get,miss 才 dupe 后 put。
            if (context.pending_position_keys.getPtr(edge_key)) |queue| {
                try queue.append(context.allocator, order_key);
            } else {
                {
                    const key_owned = try context.allocator.dupe(u8, edge_key);
                    errdefer context.allocator.free(key_owned);
                    var queue: std.ArrayList(u64) = .empty;
                    errdefer queue.deinit(context.allocator);
                    try queue.append(context.allocator, order_key);
                    try context.pending_position_keys.put(key_owned, queue);
                }
            }

            try markdownRememberSessionEdgeUse(context, edge_key, used_count + 1);
            var identity_edge: ?storage.EdgeIndexRecord = null;
            if (context.reuse_existing_projection_edges and !context.edge_identity_index_dirty) {
                if (context.session_node_external_keys.get(src.toInt())) |src_external_key| {
                    const external_key = try storage.orderedEdgeExternalKeyAlloc(context.allocator, src_external_key, rel, order_key);
                    defer context.allocator.free(external_key);
                    if (context.edge_lookup_cache == null) {
                        context.edge_lookup_cache = try context.store.buildEdgeExternalKeyLookupCache(context.allocator);
                    }
                    if (try context.store.lookupEdgeRecordByExternalKeyCached(context.allocator, external_key, &context.edge_lookup_cache.?)) |record| identity_edge = record;
                }
            }

            if (identity_edge) |record| {
                if (record.rel == @intFromEnum(rel) and record.dst == dst.toInt()) return false;
            }

            var existing_count: usize = 0;
            var identity_slot_conflict = false;
            // Markdown projection identity is defined only by persisted graph edges;
            // the metaknow deferred `based_on` sidecar is a query projection and must
            // not consume this bounded deduplication scan.
            var records = try context.store.readVisibleEdgeIndexRecordsByNodeForOrderedTraversal(context.allocator, src);
            defer records.deinit(context.allocator);
            for (records.items) |record| {
                if (identity_edge) |edge| {
                    if (record.edge_id == edge.edge_id) {
                        if (record.rel == @intFromEnum(rel) and record.dst == dst.toInt()) return false;
                        identity_slot_conflict = true;
                    }
                }
                if (record.rel == @intFromEnum(rel) and record.dst == dst.toInt()) existing_count += 1;
            }
            for (context.pending_edges.items) |edge| {
                if (edge.src == src and edge.rel == rel and edge.dst == dst) existing_count += 1;
            }

            if (!identity_slot_conflict and existing_count > used_count) return false;

            try context.pending_edges.append(context.allocator, .{
                .src = src,
                .rel = rel,
                .dst = dst,
                .order_key = order_key,
            });
            context.edge_identity_index_dirty = true;
            return true;
        }

        fn reconcileMarkdownProjectionEdges(context: *MarkdownImportContext, document_id: core.NodeId) !usize {
            var visited_owners = std.AutoHashMap(u64, void).init(context.allocator);
            defer visited_owners.deinit();
            var stack = std.ArrayList(core.NodeId).empty;
            defer stack.deinit(context.allocator);
            var seen_edge_counts = std.StringHashMap(usize).init(context.allocator);
            defer {
                var iterator = seen_edge_counts.iterator();
                while (iterator.next()) |entry| context.allocator.free(entry.key_ptr.*);
                seen_edge_counts.deinit();
            }
            var edge_ids_to_delete = std.ArrayList(core.EdgeId).empty;
            defer edge_ids_to_delete.deinit(context.allocator);
            var edge_order_map = try context.store.readEdgeOrderMap(context.allocator);
            defer edge_order_map.deinit();

            try stack.append(context.allocator, document_id);
            while (stack.pop()) |owner_id| {
                const visited = try visited_owners.getOrPut(owner_id.toInt());
                if (visited.found_existing) continue;

                var records = try markdownProjectionChildrenWithOrderMap(context.allocator, context.store, owner_id, null, &edge_order_map);
                defer records.deinit(context.allocator);
                for (records.items) |record| {
                    const rel: core.RelKind = @enumFromInt(record.rel);
                    const dst = core.NodeId.fromInt(record.dst);

                    const edge_key = try markdownProjectionEdgeKey(context.allocator, owner_id, rel, dst);
                    defer context.allocator.free(edge_key);
                    const seen_count = seen_edge_counts.get(edge_key) orelse 0;
                    const desired_count = context.session_edge_counts.get(edge_key) orelse 0;
                    if (seen_count >= desired_count) {
                        try edge_ids_to_delete.append(context.allocator, core.EdgeId.fromInt(record.edge_id));
                        try stack.append(context.allocator, dst);
                        continue;
                    }
                    try markdownRememberEdgeUse(context.allocator, &seen_edge_counts, edge_key, seen_count + 1);
                    if (markdownProjectionRelAlwaysHasChildren(rel) or context.desired_projection_owners.contains(dst.toInt())) {
                        try stack.append(context.allocator, dst);
                    }
                }
            }

            try context.store.deleteEdgesBatch(edge_ids_to_delete.items);
            return edge_ids_to_delete.items.len;
        }

        /// order_key 撞车修复的分配阶段:reconcile 之后,用与其**同一 ordered 读**遍历文档活投影边,
        /// 逐边 pop 该 (src,rel,dst) 的文档序位置键队列,与现 order 记录 diff 才 upsert。
        /// 只写活边(死边不碰);新建/identity 边 pop 到自己的键 = no-op。
        fn assignProjectionOrderKeys(context: *MarkdownImportContext, document_id: core.NodeId) !void {
            if (context.pending_position_keys.count() == 0) return;
            var edge_order_map = try context.store.readEdgeOrderMap(context.allocator);
            defer edge_order_map.deinit();
            var visited_owners = std.AutoHashMap(u64, void).init(context.allocator);
            defer visited_owners.deinit();
            var stack = std.ArrayList(core.NodeId).empty;
            defer stack.deinit(context.allocator);
            var rewrites = std.ArrayList(storage.EdgeOrderRecord).empty;
            defer rewrites.deinit(context.allocator);

            try stack.append(context.allocator, document_id);
            while (stack.pop()) |owner_id| {
                const visited = try visited_owners.getOrPut(owner_id.toInt());
                if (visited.found_existing) continue;
                var records = try markdownProjectionChildrenWithOrderMap(context.allocator, context.store, owner_id, null, &edge_order_map);
                defer records.deinit(context.allocator);
                for (records.items) |record| {
                    const rel: core.RelKind = @enumFromInt(record.rel);
                    const dst = core.NodeId.fromInt(record.dst);
                    const edge_key = try markdownProjectionEdgeKey(context.allocator, owner_id, rel, dst);
                    defer context.allocator.free(edge_key);
                    if (context.pending_position_keys.getPtr(edge_key)) |queue| {
                        if (queue.items.len > 0) {
                            const want = queue.orderedRemove(0);
                            const have = edge_order_map.get(record.edge_id);
                            if (have == null or have.? != want) {
                                try rewrites.append(context.allocator, .{
                                    .src = owner_id.toInt(),
                                    .rel = record.rel,
                                    .edge_id = record.edge_id,
                                    .order_key = want,
                                });
                            }
                        }
                    }
                    if (markdownProjectionRelAlwaysHasChildren(rel) or context.desired_projection_owners.contains(dst.toInt())) {
                        try stack.append(context.allocator, dst);
                    }
                }
            }
            try context.store.upsertEdgeOrderRecordsBatch(context.allocator, rewrites.items);
        }

        fn markdownProjectionEdgeKey(allocator: std.mem.Allocator, src: core.NodeId, rel: core.RelKind, dst: core.NodeId) ![]u8 {
            return std.fmt.allocPrint(allocator, "{}\x1f{}\x1f{}", .{ src.toInt(), @intFromEnum(rel), dst.toInt() });
        }

        fn markdownNextOwnerOrderKey(context: *MarkdownImportContext, src: core.NodeId) !u64 {
            const entry = try context.session_owner_order_counts.getOrPut(src.toInt());
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
            return @as(u64, @intCast(entry.value_ptr.*)) * 1024;
        }

        fn markdownRememberSessionEdgeUse(context: *MarkdownImportContext, edge_key: []const u8, count: usize) !void {
            return markdownRememberEdgeUse(context.allocator, &context.session_edge_counts, edge_key, count);
        }

        fn markdownRememberEdgeUse(allocator: std.mem.Allocator, counts: *std.StringHashMap(usize), edge_key: []const u8, count: usize) !void {
            if (counts.getEntry(edge_key)) |entry| {
                entry.value_ptr.* = count;
                return;
            }
            const owned_key = try allocator.dupe(u8, edge_key);
            errdefer allocator.free(owned_key);
            try counts.put(owned_key, count);
        }

        fn appendMarkdownProjectionEdgeRaw(store: storage.Store, src: core.NodeId, rel: core.RelKind, dst: core.NodeId) !void {
            try store.appendEdgeIndexed(.{
                .id = try store.nextEdgeId(),
                .src = src,
                .rel = rel,
                .dst = dst,
            });
        }

        pub fn renderMarkdownDocument(allocator: std.mem.Allocator, store: storage.Store, document_id: core.NodeId) ![]u8 {
            var document = (try store.readNodeById(allocator, document_id)) orelse return core.Error.NotFound;
            defer document.deinit(allocator);
            if (document.kind != .document and document.kind != .document_section) return core.Error.InvalidId;
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);
            try renderMarkdownSubtree(allocator, store, document_id, document.kind, &out);
            return out.buffer.toOwnedSlice(allocator);
        }

        const MarkdownSectionStats = struct {
            section_count: usize = 0,
            context_size: TextContextSize = .{ .text_bytes = 0, .text_chars = 0, .text_lines = 0 },
        };

        pub fn markdownPreviewPrefixLen(text: []const u8, max_lines: usize) struct { len: usize, lines: usize, truncated: bool } {
            if (max_lines == 0) return .{ .len = 0, .lines = 0, .truncated = text.len != 0 };
            if (text.len == 0) return .{ .len = 0, .lines = 0, .truncated = false };
            var lines: usize = 1;
            for (text, 0..) |byte, index| {
                if (byte == '\n') {
                    if (lines >= max_lines) {
                        return .{ .len = index + 1, .lines = lines, .truncated = index + 1 < text.len };
                    }
                    lines += 1;
                }
            }
            return .{ .len = text.len, .lines = lines, .truncated = false };
        }

        fn addTextContextSize(total: *TextContextSize, size: TextContextSize) !void {
            total.text_bytes = std.math.add(usize, total.text_bytes, size.text_bytes) catch return error.RecordTooLarge;
            total.text_chars = std.math.add(usize, total.text_chars, size.text_chars) catch return error.RecordTooLarge;
            total.text_lines = std.math.add(usize, total.text_lines, size.text_lines) catch return error.RecordTooLarge;
        }

        pub fn markdownSubtreeSectionStats(
            allocator: std.mem.Allocator,
            store: storage.Store,
            root_id: core.NodeId,
        ) !MarkdownSectionStats {
            var stats = MarkdownSectionStats{};
            var visited = std.AutoHashMap(u64, void).init(allocator);
            defer visited.deinit();
            try collectMarkdownSubtreeSectionStats(allocator, store, root_id, &visited, &stats);
            return stats;
        }

        fn collectMarkdownSubtreeSectionStats(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_id: core.NodeId,
            visited: *std.AutoHashMap(u64, void),
            stats: *MarkdownSectionStats,
        ) !void {
            if (visited.contains(node_id.toInt())) return;
            try visited.put(node_id.toInt(), {});

            var node = (try store.readNodeById(allocator, node_id)) orelse return core.Error.NotFound;
            defer node.deinit(allocator);
            if (node.kind == .document_section) {
                stats.section_count = std.math.add(usize, stats.section_count, 1) catch return error.RecordTooLarge;
                try addTextContextSize(&stats.context_size, try computeTextContextSize(node.text));
            }

            var records = try markdownProjectionChildren(allocator, store, node_id, null);
            defer records.deinit(allocator);
            for (records.items) |record| {
                try collectMarkdownSubtreeSectionStats(allocator, store, core.NodeId.fromInt(record.dst), visited, stats);
            }
        }

        pub fn renderMarkdownDocumentJsonOutput(
            allocator: std.mem.Allocator,
            store: storage.Store,
            args: ParsedRenderMarkdownDocumentArgs,
            rendered: []const u8,
        ) ![]u8 {
            var document = (try store.readNodeById(allocator, args.document_id)) orelse return core.Error.NotFound;
            defer document.deinit(allocator);
            if (document.kind != .document and document.kind != .document_section) return core.Error.InvalidId;
            var render_root = (try store.readNodeById(allocator, args.render_root_id)) orelse return core.Error.NotFound;
            defer render_root.deinit(allocator);
            if (render_root.kind != .document and render_root.kind != .document_section) return core.Error.InvalidId;

            const rendered_size = try computeTextContextSize(rendered);
            const preview = markdownPreviewPrefixLen(rendered, args.preview_lines);
            const section_stats = try markdownSubtreeSectionStats(allocator, store, args.render_root_id);

            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);
            try writeJsonObjectStart(&out);
            var first = true;
            try writeJsonStringField(&out, "schema_version", "tinykg-agent-retrieval-v1", &first);
            try writeJsonStringField(&out, "mode", "render-md-doc", &first);

            try writeJsonFieldPrefix(&out, "query", &first);
            try out.writeAll("{");
            var query_first = true;
            try writeJsonNumberField(&out, "document_id", args.document_id.toInt(), &query_first);
            try writeJsonNumberField(&out, "render_root_id", args.render_root_id.toInt(), &query_first);
            try writeJsonNumberField(&out, "preview_lines", args.preview_lines, &query_first);
            try out.writeAll("}");

            try writeJsonFieldPrefix(&out, "document", &first);
            try renderNodeObjectJson(&out, allocator, store, document, false);
            try writeJsonFieldPrefix(&out, "render_root", &first);
            try renderNodeObjectJson(&out, allocator, store, render_root, false);

            try writeJsonFieldPrefix(&out, "rendered_markdown", &first);
            try out.writeAll("{");
            var rendered_first = true;
            try writeJsonFieldPrefix(&out, "context_size", &rendered_first);
            try renderTextContextSizeJson(&out, rendered_size);
            try writeJsonNumberField(&out, "preview_lines", preview.lines, &rendered_first);
            try writeJsonBoolField(&out, "truncated", preview.truncated, &rendered_first);
            try writeJsonNullableStringField(&out, "truncate_reason", if (preview.truncated) "preview_lines" else null, &rendered_first);
            try writeJsonStringField(&out, "preview", rendered[0..preview.len], &rendered_first);
            try out.writeAll("}");

            try writeJsonFieldPrefix(&out, "sections", &first);
            try out.writeAll("{");
            var sections_first = true;
            try writeJsonNumberField(&out, "section_count", section_stats.section_count, &sections_first);
            try writeJsonFieldPrefix(&out, "context_size", &sections_first);
            try renderTextContextSizeJson(&out, section_stats.context_size);
            try out.writeAll("}");

            try writeJsonFieldPrefix(&out, "continuations", &first);
            try out.writeAll("[");
            try writeSearchContinuation(&out, "inspect_metadata", args.render_root_id, "inspect rendered markdown root metadata");
            try out.writeAll(",");
            try writeSearchContinuation(&out, "neighbors", args.render_root_id, "walk markdown projection graph around the rendered root");
            try out.writeAll("]");

            try writeJsonObjectEnd(&out);
            return out.buffer.toOwnedSlice(allocator);
        }

        const MarkdownRenderPage = struct {
            cursor: usize,
            markdown: []u8,
            context_size: TextContextSize,
            units_emitted: usize,
            next_cursor: ?usize,
            has_more: bool,

            fn deinit(self: MarkdownRenderPage, allocator: std.mem.Allocator) void {
                allocator.free(self.markdown);
            }
        };

        const MarkdownPageRenderState = struct {
            cursor: usize,
            page_size_bytes: usize,
            unit_index: usize = 0,
            units_emitted: usize = 0,
            stopped: bool = false,
            next_cursor: ?usize = null,
            out: *QueryOutputWriter,
        };

        pub fn renderMarkdownDocumentPageJsonOutput(
            allocator: std.mem.Allocator,
            store: storage.Store,
            args: ParsedRenderMarkdownDocumentArgs,
        ) ![]u8 {
            var document = (try store.readNodeById(allocator, args.document_id)) orelse return core.Error.NotFound;
            defer document.deinit(allocator);
            if (document.kind != .document and document.kind != .document_section) return core.Error.InvalidId;
            var render_root = (try store.readNodeById(allocator, args.render_root_id)) orelse return core.Error.NotFound;
            defer render_root.deinit(allocator);
            if (render_root.kind != .document and render_root.kind != .document_section) return core.Error.InvalidId;

            const page_size_bytes = args.page_size_bytes orelse return error.InvalidLimit;
            const page = try renderMarkdownDocumentPage(allocator, store, args.render_root_id, render_root.kind, args.cursor, page_size_bytes);
            defer page.deinit(allocator);

            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);
            try writeJsonObjectStart(&out);
            var first = true;
            try writeJsonStringField(&out, "schema_version", "tinykg-agent-retrieval-v1", &first);
            try writeJsonStringField(&out, "mode", "render-md-doc", &first);

            try writeJsonFieldPrefix(&out, "query", &first);
            try out.writeAll("{");
            var query_first = true;
            try writeJsonNumberField(&out, "document_id", args.document_id.toInt(), &query_first);
            try writeJsonNumberField(&out, "render_root_id", args.render_root_id.toInt(), &query_first);
            try writeJsonNumberField(&out, "page_size_bytes", page_size_bytes, &query_first);
            try writeJsonNumberField(&out, "cursor", args.cursor, &query_first);
            try out.writeAll("}");

            try writeJsonFieldPrefix(&out, "document", &first);
            try renderNodeObjectJson(&out, allocator, store, document, false);
            try writeJsonFieldPrefix(&out, "render_root", &first);
            try renderNodeObjectJson(&out, allocator, store, render_root, false);

            try writeJsonFieldPrefix(&out, "rendered_markdown", &first);
            try out.writeAll("{");
            var rendered_first = true;
            try writeJsonFieldPrefix(&out, "context_size", &rendered_first);
            try renderTextContextSizeJson(&out, page.context_size);
            try writeJsonNumberField(&out, "cursor", page.cursor, &rendered_first);
            try writeJsonNullableUsizeField(&out, "next_cursor", page.next_cursor, &rendered_first);
            try writeJsonBoolField(&out, "has_more", page.has_more, &rendered_first);
            try writeJsonBoolField(&out, "truncated", page.has_more, &rendered_first);
            try writeJsonNullableStringField(&out, "truncate_reason", if (page.has_more) "page_size_bytes" else null, &rendered_first);
            try writeJsonNumberField(&out, "page_size_bytes", page_size_bytes, &rendered_first);
            try writeJsonNumberField(&out, "units_emitted", page.units_emitted, &rendered_first);
            try writeJsonStringField(&out, "page", page.markdown, &rendered_first);
            try writeJsonStringField(&out, "preview", page.markdown, &rendered_first);
            try out.writeAll("}");

            try writeJsonFieldPrefix(&out, "continuations", &first);
            try out.writeAll("[");
            if (page.next_cursor) |next_cursor| {
                try out.writeAll("{");
                var cont_first = true;
                try writeJsonStringField(&out, "action", "render-md-doc", &cont_first);
                try writeJsonNumberField(&out, "node_id", args.render_root_id.toInt(), &cont_first);
                try writeJsonNumberField(&out, "cursor", next_cursor, &cont_first);
                try writeJsonStringField(&out, "reason", "fetch next markdown page", &cont_first);
                try out.writeAll("}");
            }
            try out.writeAll("]");

            try writeJsonObjectEnd(&out);
            return out.buffer.toOwnedSlice(allocator);
        }

        fn renderMarkdownDocumentPage(
            allocator: std.mem.Allocator,
            store: storage.Store,
            root_id: core.NodeId,
            root_kind: core.NodeKind,
            cursor: usize,
            page_size_bytes: usize,
        ) !MarkdownRenderPage {
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);
            var state = MarkdownPageRenderState{
                .cursor = cursor,
                .page_size_bytes = page_size_bytes,
                .out = &out,
            };
            try renderMarkdownSubtreePaged(allocator, store, root_id, root_kind, &state);
            const markdown = try out.buffer.toOwnedSlice(allocator);
            const context_size = try computeTextContextSize(markdown);
            return .{
                .cursor = cursor,
                .markdown = markdown,
                .context_size = context_size,
                .units_emitted = state.units_emitted,
                .next_cursor = state.next_cursor,
                .has_more = state.stopped,
            };
        }

        fn emitMarkdownPageUnit(state: *MarkdownPageRenderState, text: []const u8) !void {
            if (state.stopped) return;
            if (state.unit_index < state.cursor) {
                state.unit_index += 1;
                return;
            }
            const current_len = state.out.buffer.items.len;
            if (current_len != 0 and current_len + text.len > state.page_size_bytes) {
                state.stopped = true;
                state.next_cursor = state.unit_index;
                return;
            }
            try state.out.writeAll(text);
            state.units_emitted += 1;
            state.unit_index += 1;
        }

        fn emitMarkdownHeadingPageUnit(allocator: std.mem.Allocator, state: *MarkdownPageRenderState, level: usize, text: []const u8) !void {
            var temp = QueryOutputWriter{ .allocator = allocator };
            defer temp.buffer.deinit(allocator);
            var i: usize = 0;
            while (i < level) : (i += 1) try temp.writeAll("#");
            try temp.writeAll(" ");
            try temp.writeAll(text);
            try temp.writeAll("\n\n");
            try emitMarkdownPageUnit(state, temp.buffer.items);
        }

        fn emitMarkdownTextBlockPageUnit(allocator: std.mem.Allocator, state: *MarkdownPageRenderState, text: []const u8) !void {
            var temp = QueryOutputWriter{ .allocator = allocator };
            defer temp.buffer.deinit(allocator);
            try temp.writeAll(text);
            if (text.len == 0 or text[text.len - 1] != '\n') try temp.writeAll("\n");
            try temp.writeAll("\n");
            try emitMarkdownPageUnit(state, temp.buffer.items);
        }

        fn renderMarkdownSubtreePaged(allocator: std.mem.Allocator, store: storage.Store, root_id: core.NodeId, root_kind: core.NodeKind, state: *MarkdownPageRenderState) !void {
            if (state.stopped) return;
            if (root_kind == .document_section) {
                if (try markdownProjectionHasChild(allocator, store, root_id, md_rel_text_chunk)) {
                    return renderMarkdownChunkedTextBlockPaged(allocator, store, root_id, state);
                }
                if (try markdownProjectionHasChild(allocator, store, root_id, md_rel_table_row)) {
                    return renderMarkdownTablePaged(allocator, store, root_id, state);
                }
                if (try markdownProjectionHasChild(allocator, store, root_id, md_rel_table_cell)) {
                    try renderMarkdownTableRowPaged(allocator, store, root_id, state);
                    if (!state.stopped) try emitMarkdownPageUnit(state, "\n");
                    return;
                }
                if (try markdownIncomingHeadingRel(allocator, store, root_id)) |rel| {
                    var node = (try store.readNodeById(allocator, root_id)) orelse return core.Error.NotFound;
                    defer node.deinit(allocator);
                    return renderMarkdownSectionWithHeadingPaged(allocator, store, root_id, rel, markdownProjectionVisibleText(node.text), state);
                }
            }
            try renderMarkdownChildrenPaged(allocator, store, root_id, state);
        }

        fn renderMarkdownChildrenPaged(allocator: std.mem.Allocator, store: storage.Store, owner_id: core.NodeId, state: *MarkdownPageRenderState) !void {
            var records = try markdownProjectionChildren(allocator, store, owner_id, null);
            defer records.deinit(allocator);
            for (records.items) |record| {
                if (state.stopped) return;
                try renderMarkdownProjectionRecordPaged(allocator, store, record, state);
            }
        }

        fn renderMarkdownProjectionRecordPaged(allocator: std.mem.Allocator, store: storage.Store, record: storage.EdgeIndexRecord, state: *MarkdownPageRenderState) !void {
            const rel: core.RelKind = @enumFromInt(record.rel);
            if (rel == md_rel_table) return renderMarkdownTablePaged(allocator, store, core.NodeId.fromInt(record.dst), state);

            var node = (try store.readNodeById(allocator, core.NodeId.fromInt(record.dst))) orelse return core.Error.NotFound;
            defer node.deinit(allocator);
            const text_alloc = try renderMarkdownNodeVisibleTextAlloc(allocator, store, core.NodeId.fromInt(record.dst), node);
            defer allocator.free(text_alloc);
            const text = text_alloc;
            if (mdHeadingLevelFromRel(rel)) |level| {
                if (node.kind == .document_section) {
                    return renderMarkdownSectionWithHeadingPaged(allocator, store, core.NodeId.fromInt(record.dst), rel, text, state);
                }
                try emitMarkdownHeadingPageUnit(allocator, state, level, text);
            } else if (rel == md_rel_paragraph or rel == md_rel_image or rel == md_rel_code_block or isMarkdownRawTextProjectionRel(rel) or rel == md_rel_table_cell) {
                try emitMarkdownTextBlockPageUnit(allocator, state, text);
            } else if (rel == md_rel_text_chunk) {
                try emitMarkdownPageUnit(state, text);
            }
        }

        fn renderMarkdownSectionWithHeadingPaged(
            allocator: std.mem.Allocator,
            store: storage.Store,
            section_id: core.NodeId,
            rel: core.RelKind,
            text: []const u8,
            state: *MarkdownPageRenderState,
        ) !void {
            const level = mdHeadingLevelFromRel(rel) orelse return error.InvalidRelKind;
            try emitMarkdownHeadingPageUnit(allocator, state, level, text);
            if (state.stopped) return;
            try renderMarkdownChildrenPaged(allocator, store, section_id, state);
        }

        fn renderMarkdownTablePaged(allocator: std.mem.Allocator, store: storage.Store, table_id: core.NodeId, state: *MarkdownPageRenderState) !void {
            var rows = try markdownProjectionChildren(allocator, store, table_id, md_rel_table_row);
            defer rows.deinit(allocator);
            for (rows.items) |row_record| {
                if (state.stopped) return;
                try renderMarkdownTableRowPaged(allocator, store, core.NodeId.fromInt(row_record.dst), state);
            }
            if (!state.stopped) try emitMarkdownPageUnit(state, "\n");
        }

        fn renderMarkdownTableRowPaged(allocator: std.mem.Allocator, store: storage.Store, row_id: core.NodeId, state: *MarkdownPageRenderState) !void {
            var temp = QueryOutputWriter{ .allocator = allocator };
            defer temp.buffer.deinit(allocator);
            var cells = try markdownProjectionChildren(allocator, store, row_id, md_rel_table_cell);
            defer cells.deinit(allocator);
            try temp.writeAll("|");
            for (cells.items) |cell_record| {
                var cell = (try store.readNodeById(allocator, core.NodeId.fromInt(cell_record.dst))) orelse return core.Error.NotFound;
                defer cell.deinit(allocator);
                const cell_text = try renderMarkdownNodeVisibleTextAlloc(allocator, store, core.NodeId.fromInt(cell_record.dst), cell);
                defer allocator.free(cell_text);
                try temp.writeAll(" ");
                try temp.writeAll(cell_text);
                try temp.writeAll(" |");
            }
            try temp.writeAll("\n");
            try emitMarkdownPageUnit(state, temp.buffer.items);
        }

        fn renderMarkdownChunkedTextBlockPaged(allocator: std.mem.Allocator, store: storage.Store, node_id: core.NodeId, state: *MarkdownPageRenderState) !void {
            var records = try markdownProjectionChildren(allocator, store, node_id, md_rel_text_chunk);
            defer records.deinit(allocator);
            var text_len: usize = 0;
            var last_byte: u8 = 0;
            for (records.items) |record| {
                if (state.stopped) return;
                var chunk = (try store.readNodeById(allocator, core.NodeId.fromInt(record.dst))) orelse return core.Error.NotFound;
                defer chunk.deinit(allocator);
                const text = markdownProjectionVisibleText(chunk.text);
                if (text.len != 0) {
                    text_len += text.len;
                    last_byte = text[text.len - 1];
                }
                try emitMarkdownPageUnit(state, text);
            }
            if (state.stopped) return;
            if (text_len == 0 or last_byte != '\n') try emitMarkdownPageUnit(state, "\n");
            if (state.stopped) return;
            try emitMarkdownPageUnit(state, "\n");
        }

        fn renderMarkdownSubtree(allocator: std.mem.Allocator, store: storage.Store, root_id: core.NodeId, root_kind: core.NodeKind, out: *QueryOutputWriter) !void {
            if (root_kind == .document_section) {
                if (try markdownProjectionHasChild(allocator, store, root_id, md_rel_text_chunk)) {
                    const text = try renderMarkdownChunkedTextAlloc(allocator, store, root_id);
                    defer allocator.free(text);
                    try out.writeAll(text);
                    if (text.len == 0 or text[text.len - 1] != '\n') try out.writeAll("\n");
                    try out.writeAll("\n");
                    return;
                }
                if (try markdownProjectionHasChild(allocator, store, root_id, md_rel_table_row)) {
                    return renderMarkdownTable(allocator, store, root_id, out);
                }
                if (try markdownProjectionHasChild(allocator, store, root_id, md_rel_table_cell)) {
                    try renderMarkdownTableRow(allocator, store, root_id, out);
                    try out.writeAll("\n");
                    return;
                }
                if (try markdownIncomingHeadingRel(allocator, store, root_id)) |rel| {
                    var node = (try store.readNodeById(allocator, root_id)) orelse return core.Error.NotFound;
                    defer node.deinit(allocator);
                    return renderMarkdownSectionWithHeading(allocator, store, root_id, rel, markdownProjectionVisibleText(node.text), out);
                }
            }
            try renderMarkdownChildren(allocator, store, root_id, out);
        }

        fn renderMarkdownChildren(allocator: std.mem.Allocator, store: storage.Store, owner_id: core.NodeId, out: *QueryOutputWriter) !void {
            var records = try markdownProjectionChildren(allocator, store, owner_id, null);
            defer records.deinit(allocator);
            for (records.items) |record| {
                try renderMarkdownProjectionRecord(allocator, store, record, out);
            }
        }

        fn renderMarkdownProjectionRecord(allocator: std.mem.Allocator, store: storage.Store, record: storage.EdgeIndexRecord, out: *QueryOutputWriter) !void {
            const rel: core.RelKind = @enumFromInt(record.rel);
            if (rel == md_rel_table) return renderMarkdownTable(allocator, store, core.NodeId.fromInt(record.dst), out);

            var node = (try store.readNodeById(allocator, core.NodeId.fromInt(record.dst))) orelse return core.Error.NotFound;
            defer node.deinit(allocator);
            const text_alloc = try renderMarkdownNodeVisibleTextAlloc(allocator, store, core.NodeId.fromInt(record.dst), node);
            defer allocator.free(text_alloc);
            const text = text_alloc;
            if (mdHeadingLevelFromRel(rel)) |level| {
                if (node.kind == .document_section) {
                    return renderMarkdownSectionWithHeading(allocator, store, core.NodeId.fromInt(record.dst), rel, text, out);
                }
                var i: usize = 0;
                while (i < level) : (i += 1) try out.writeAll("#");
                try out.writeAll(" ");
                try out.writeAll(text);
                try out.writeAll("\n\n");
            } else if (rel == md_rel_paragraph or rel == md_rel_image or rel == md_rel_code_block or isMarkdownRawTextProjectionRel(rel) or rel == md_rel_table_cell) {
                try out.writeAll(text);
                if (text.len == 0 or text[text.len - 1] != '\n') try out.writeAll("\n");
                try out.writeAll("\n");
            } else if (rel == md_rel_text_chunk) {
                try out.writeAll(text);
            }
        }

        fn renderMarkdownSectionWithHeading(
            allocator: std.mem.Allocator,
            store: storage.Store,
            section_id: core.NodeId,
            rel: core.RelKind,
            text: []const u8,
            out: *QueryOutputWriter,
        ) !void {
            const level = mdHeadingLevelFromRel(rel) orelse return error.InvalidRelKind;
            var i: usize = 0;
            while (i < level) : (i += 1) try out.writeAll("#");
            try out.writeAll(" ");
            try out.writeAll(text);
            try out.writeAll("\n\n");
            try renderMarkdownChildren(allocator, store, section_id, out);
        }

        pub fn markdownIncomingHeadingRel(allocator: std.mem.Allocator, store: storage.Store, section_id: core.NodeId) !?core.RelKind {
            // This is a physical projection lookup. Keep deferred query edges out of
            // the scan while opening the reverse segment direction only once.
            var records = try store.readVisibleEdgeIndexRecordsByNode(allocator, .dst, section_id, null);
            defer records.deinit(allocator);
            for (records.items) |record| {
                const rel: core.RelKind = @enumFromInt(record.rel);
                if (mdHeadingLevelFromRel(rel) != null) return rel;
            }
            return null;
        }

        fn renderMarkdownTable(allocator: std.mem.Allocator, store: storage.Store, table_id: core.NodeId, out: *QueryOutputWriter) !void {
            var rows = try markdownProjectionChildren(allocator, store, table_id, md_rel_table_row);
            defer rows.deinit(allocator);
            for (rows.items) |row_record| {
                try renderMarkdownTableRow(allocator, store, core.NodeId.fromInt(row_record.dst), out);
            }
            try out.writeAll("\n");
        }

        fn renderMarkdownTableRow(allocator: std.mem.Allocator, store: storage.Store, row_id: core.NodeId, out: *QueryOutputWriter) !void {
            var cells = try markdownProjectionChildren(allocator, store, row_id, md_rel_table_cell);
            defer cells.deinit(allocator);
            try out.writeAll("|");
            for (cells.items) |cell_record| {
                var cell = (try store.readNodeById(allocator, core.NodeId.fromInt(cell_record.dst))) orelse return core.Error.NotFound;
                defer cell.deinit(allocator);
                const cell_text = try renderMarkdownNodeVisibleTextAlloc(allocator, store, core.NodeId.fromInt(cell_record.dst), cell);
                defer allocator.free(cell_text);
                try out.writeAll(" ");
                try out.writeAll(cell_text);
                try out.writeAll(" |");
            }
            try out.writeAll("\n");
        }

        fn renderMarkdownNodeVisibleTextAlloc(allocator: std.mem.Allocator, store: storage.Store, node_id: core.NodeId, node: storage.StoredNode) ![]u8 {
            if (node.kind == .document_section and try markdownProjectionHasChild(allocator, store, node_id, md_rel_text_chunk)) {
                return renderMarkdownChunkedTextAlloc(allocator, store, node_id);
            }
            return try allocator.dupe(u8, markdownProjectionVisibleText(node.text));
        }

        fn renderMarkdownChunkedTextAlloc(allocator: std.mem.Allocator, store: storage.Store, node_id: core.NodeId) ![]u8 {
            var records = try markdownProjectionChildren(allocator, store, node_id, md_rel_text_chunk);
            defer records.deinit(allocator);
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);
            for (records.items) |record| {
                var chunk = (try store.readNodeById(allocator, core.NodeId.fromInt(record.dst))) orelse return core.Error.NotFound;
                defer chunk.deinit(allocator);
                try out.writeAll(markdownProjectionVisibleText(chunk.text));
            }
            return out.buffer.toOwnedSlice(allocator);
        }

        fn markdownProjectionHasChild(allocator: std.mem.Allocator, store: storage.Store, owner_id: core.NodeId, rel: core.RelKind) !bool {
            var records = try markdownProjectionChildren(allocator, store, owner_id, rel);
            defer records.deinit(allocator);
            return records.items.len != 0;
        }

        pub fn markdownProjectionChildren(allocator: std.mem.Allocator, store: storage.Store, owner_id: core.NodeId, rel_filter: ?core.RelKind) !std.ArrayList(storage.EdgeIndexRecord) {
            const all = try store.readEdgeIndexRecordsByNodeOrdered(allocator, owner_id);
            return filterMarkdownProjectionChildren(allocator, all, rel_filter);
        }

        fn markdownProjectionChildrenWithOrderMap(allocator: std.mem.Allocator, store: storage.Store, owner_id: core.NodeId, rel_filter: ?core.RelKind, edge_order_map: *std.AutoHashMap(u64, u64)) !std.ArrayList(storage.EdgeIndexRecord) {
            const all = try store.readEdgeIndexRecordsByNodeOrderedWithOrderMap(allocator, owner_id, edge_order_map);
            return filterMarkdownProjectionChildren(allocator, all, rel_filter);
        }

        fn filterMarkdownProjectionChildren(allocator: std.mem.Allocator, all: std.ArrayList(storage.EdgeIndexRecord), rel_filter: ?core.RelKind) !std.ArrayList(storage.EdgeIndexRecord) {
            var mutable_all = all;
            defer mutable_all.deinit(allocator);
            var out = std.ArrayList(storage.EdgeIndexRecord).empty;
            errdefer out.deinit(allocator);
            for (mutable_all.items) |record| {
                const rel: core.RelKind = @enumFromInt(record.rel);
                if (rel_filter) |wanted| {
                    if (rel != wanted) continue;
                } else if (!isMarkdownProjectionRel(rel)) {
                    continue;
                }
                try out.append(allocator, record);
            }
            return out;
        }

        fn markdownDocumentTitle(content: []const u8) ?[]const u8 {
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line_raw| {
                const line = trimMarkdownLineRight(line_raw);
                if (markdownHeading(line)) |heading| return heading.text;
                if (std.mem.trim(u8, line, " \t").len != 0) return null;
            }
            return null;
        }

        fn trimMarkdownLineRight(line: []const u8) []const u8 {
            if (line.len != 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
            return line;
        }

        fn trimMarkdownLineLeft(line: []const u8) []const u8 {
            var index: usize = 0;
            while (index < line.len and (line[index] == ' ' or line[index] == '\t')) : (index += 1) {}
            return line[index..];
        }

        const MarkdownHeading = struct {
            level: usize,
            text: []const u8,
        };

        fn markdownHeading(line: []const u8) ?MarkdownHeading {
            var level: usize = 0;
            while (level < line.len and level < 6 and line[level] == '#') : (level += 1) {}
            if (level == 0 or level >= line.len or line[level] != ' ') return null;
            return .{ .level = level, .text = std.mem.trim(u8, line[level + 1 ..], " \t") };
        }

        fn mdHeadingRel(level: usize) core.RelKind {
            return switch (level) {
                1 => md_rel_h1,
                2 => md_rel_h2,
                3 => md_rel_h3,
                4 => md_rel_h4,
                5 => md_rel_h5,
                else => md_rel_h6,
            };
        }

        fn mdHeadingLevelFromRel(rel: core.RelKind) ?usize {
            if (rel == md_rel_h1) return 1;
            if (rel == md_rel_h2) return 2;
            if (rel == md_rel_h3) return 3;
            if (rel == md_rel_h4) return 4;
            if (rel == md_rel_h5) return 5;
            if (rel == md_rel_h6) return 6;
            return null;
        }

        fn isMarkdownProjectionRel(rel: core.RelKind) bool {
            return mdHeadingLevelFromRel(rel) != null or
                rel == md_rel_paragraph or
                rel == md_rel_code_block or
                rel == md_rel_image or
                rel == md_rel_table or
                rel == md_rel_table_row or
                rel == md_rel_table_cell or
                rel == md_rel_text_chunk or
                isMarkdownRawTextProjectionRel(rel);
        }

        fn markdownProjectionRelAlwaysHasChildren(rel: core.RelKind) bool {
            return mdHeadingLevelFromRel(rel) != null or
                rel == md_rel_table or
                rel == md_rel_table_row;
        }

        fn isMarkdownRawTextProjectionRel(rel: core.RelKind) bool {
            return rel == md_rel_list or
                rel == md_rel_blockquote or
                rel == md_rel_html_block or
                rel == md_rel_footnote_def or
                rel == md_rel_link_reference or
                rel == md_rel_thematic_break or
                rel == md_rel_raw_block;
        }

        fn markdownFenceMarker(line: []const u8) ?[]const u8 {
            const trimmed = trimMarkdownLineLeft(line);
            if (std.mem.startsWith(u8, trimmed, "```")) return "```";
            if (std.mem.startsWith(u8, trimmed, "~~~")) return "~~~";
            return null;
        }

        fn markdownFenceCloses(line: []const u8, marker: []const u8) bool {
            return std.mem.startsWith(u8, trimMarkdownLineLeft(line), marker);
        }

        fn markdownImageLine(line: []const u8) bool {
            return std.mem.startsWith(u8, trimMarkdownLineLeft(line), "![");
        }

        fn markdownTableLine(line: []const u8) bool {
            const trimmed = std.mem.trim(u8, line, " \t");
            return trimmed.len >= 3 and std.mem.indexOfScalar(u8, trimmed, '|') != null;
        }

        fn markdownListLine(line: []const u8) bool {
            const trimmed = trimMarkdownLineLeft(line);
            if (trimmed.len >= 2 and (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and trimmed[1] == ' ') return true;
            var index: usize = 0;
            while (index < trimmed.len and std.ascii.isDigit(trimmed[index])) : (index += 1) {}
            return index > 0 and index + 1 < trimmed.len and (trimmed[index] == '.' or trimmed[index] == ')') and trimmed[index + 1] == ' ';
        }

        fn markdownListContinuationLine(line: []const u8) bool {
            if (std.mem.trim(u8, line, " \t").len == 0) return false;
            return markdownListLine(line) or line[0] == ' ' or line[0] == '\t';
        }

        fn markdownBlockquoteLine(line: []const u8) bool {
            return std.mem.startsWith(u8, trimMarkdownLineLeft(line), ">");
        }

        fn markdownIndentedContinuationLine(line: []const u8) bool {
            if (std.mem.trim(u8, line, " \t").len == 0) return false;
            return std.mem.startsWith(u8, line, "    ") or std.mem.startsWith(u8, line, "\t");
        }

        fn markdownFootnoteDefinitionLine(line: []const u8) bool {
            const trimmed = trimMarkdownLineLeft(line);
            return std.mem.startsWith(u8, trimmed, "[^") and std.mem.indexOf(u8, trimmed, "]:") != null;
        }

        fn markdownLinkReferenceLine(line: []const u8) bool {
            const trimmed = trimMarkdownLineLeft(line);
            return std.mem.startsWith(u8, trimmed, "[") and !std.mem.startsWith(u8, trimmed, "[^") and std.mem.indexOf(u8, trimmed, "]:") != null;
        }

        fn markdownHtmlBlockLine(line: []const u8) bool {
            const trimmed = trimMarkdownLineLeft(line);
            if (trimmed.len < 3 or trimmed[0] != '<') return false;
            if (std.mem.startsWith(u8, trimmed, "<http://") or std.mem.startsWith(u8, trimmed, "<https://")) return false;
            return std.ascii.isAlphabetic(trimmed[1]) or trimmed[1] == '/' or trimmed[1] == '!' or trimmed[1] == '?';
        }

        fn markdownThematicBreakLine(line: []const u8) bool {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len < 3) return false;
            var marker: u8 = 0;
            var count: usize = 0;
            for (trimmed) |ch| {
                if (ch == ' ' or ch == '\t') continue;
                if (ch != '-' and ch != '*' and ch != '_') return false;
                if (marker == 0) {
                    marker = ch;
                } else if (marker != ch) {
                    return false;
                }
                count += 1;
            }
            return count >= 3;
        }

        fn markdownSetextHeadingStart(lines: []const []const u8, index: usize) bool {
            if (index + 1 >= lines.len) return false;
            if (std.mem.trim(u8, lines[index], " \t").len == 0) return false;
            return markdownSetextUnderlineLine(lines[index + 1]);
        }

        fn markdownSetextUnderlineLine(line: []const u8) bool {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) return false;
            for (trimmed) |ch| {
                if (ch != '=' and ch != '-') return false;
            }
            return true;
        }

        fn markdownRawFallbackLine(line: []const u8) bool {
            return markdownIndentedContinuationLine(line);
        }

        fn markdownRawFallbackContinuationLine(line: []const u8) bool {
            return markdownIndentedContinuationLine(line);
        }

        pub fn markdownProjectionVisibleText(text: []const u8) []const u8 {
            return text;
        }

        test "Markdown document projection imports and renders core block syntax" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const markdown_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "doc.md" });
            defer std.testing.allocator.free(markdown_path);

            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = markdown_path,
                .data =
                \\# Same
                \\
                \\Intro paragraph.
                \\
                \\```zig
                \\const x = 1;
                \\```
                \\
                \\![Alt](img.png)
                \\
                \\| A | B |
                \\|---|---|
                \\| 1 | 2 |
                \\
                ,
                .flags = .{ .truncate = true },
            });

            var import_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer import_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "import-md-doc", db_path, markdown_path }, &import_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "document=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "nodes_imported=14") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "edges_imported=14") != null);

            {
                var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
                defer store.deinit();
                try appendMarkdownProjectionEdgeRaw(store, .fromInt(1), md_rel_paragraph, .fromInt(2));
            }

            var render_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer render_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "render-md-doc", db_path, "1" }, &render_out, std.testing.allocator, std.testing.io);
            const expected_rendered =
                \\# Same
                \\
                \\Intro paragraph.
                \\
                \\```zig
                \\const x = 1;
                \\```
                \\
                \\![Alt](img.png)
                \\
                \\| A | B |
                \\| --- | --- |
                \\| 1 | 2 |
                \\
                \\Same
                \\
                \\
            ;
            try std.testing.expectEqualStrings(expected_rendered, render_out.buffer.items);

            render_out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "render-md-doc", db_path, "1", "--format", "json", "--meta", "--preview-lines", "3" }, &render_out, std.testing.allocator, std.testing.io);
            var parsed_render = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, render_out.buffer.items, .{});
            defer parsed_render.deinit();
            try std.testing.expectEqualStrings("tinykg-agent-retrieval-v1", parsed_render.value.object.get("schema_version").?.string);
            try std.testing.expectEqualStrings("render-md-doc", parsed_render.value.object.get("mode").?.string);
            try std.testing.expectEqual(@as(i64, 1), parsed_render.value.object.get("query").?.object.get("document_id").?.integer);
            try std.testing.expectEqual(@as(i64, 1), parsed_render.value.object.get("query").?.object.get("render_root_id").?.integer);
            const rendered_meta = parsed_render.value.object.get("rendered_markdown").?.object;
            try std.testing.expectEqual(@as(i64, @intCast(expected_rendered.len)), rendered_meta.get("context_size").?.object.get("text_bytes").?.integer);
            try std.testing.expectEqual(@as(i64, 3), rendered_meta.get("preview_lines").?.integer);
            try std.testing.expect(rendered_meta.get("truncated").?.bool);
            try std.testing.expectEqualStrings("preview_lines", rendered_meta.get("truncate_reason").?.string);
            try std.testing.expectEqualStrings("# Same\n\nIntro paragraph.\n", rendered_meta.get("preview").?.string);
            try std.testing.expect(parsed_render.value.object.get("document").?.object.get("text") == null);
            try std.testing.expect(parsed_render.value.object.get("render_root").?.object.get("text") == null);
            const sections_meta = parsed_render.value.object.get("sections").?.object;
            try std.testing.expectEqual(@as(i64, 5), sections_meta.get("section_count").?.integer);
            try std.testing.expect(sections_meta.get("context_size").?.object.get("text_chars").?.integer > 0);

            render_out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "render-md-doc", db_path, "1", "--format", "json", "--meta", "--page-size-bytes", "20" }, &render_out, std.testing.allocator, std.testing.io);
            var parsed_page = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, render_out.buffer.items, .{});
            defer parsed_page.deinit();
            const first_page = parsed_page.value.object.get("rendered_markdown").?.object;
            try std.testing.expectEqual(@as(i64, 0), first_page.get("cursor").?.integer);
            try std.testing.expectEqual(@as(i64, 1), first_page.get("next_cursor").?.integer);
            try std.testing.expect(first_page.get("has_more").?.bool);
            try std.testing.expectEqual(@as(i64, 1), first_page.get("units_emitted").?.integer);
            try std.testing.expectEqualStrings("# Same\n\n", first_page.get("page").?.string);

            render_out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "render-md-doc", db_path, "1", "--format", "json", "--meta", "--page-size-bytes", "20", "--cursor", "1" }, &render_out, std.testing.allocator, std.testing.io);
            var parsed_page_2 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, render_out.buffer.items, .{});
            defer parsed_page_2.deinit();
            const second_page = parsed_page_2.value.object.get("rendered_markdown").?.object;
            try std.testing.expectEqual(@as(i64, 1), second_page.get("cursor").?.integer);
            try std.testing.expectEqual(@as(i64, 2), second_page.get("next_cursor").?.integer);
            try std.testing.expect(second_page.get("has_more").?.bool);
            try std.testing.expectEqualStrings("Intro paragraph.\n\n", second_page.get("page").?.string);

            render_out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "render-md-doc", db_path, "1", "--section", "6" }, &render_out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings(
                \\| A | B |
                \\| --- | --- |
                \\| 1 | 2 |
                \\
                \\
            ,
                render_out.buffer.items,
            );

            render_out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "render-md-doc", db_path, "1", "--section", "7" }, &render_out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings(
                \\| A | B |
                \\
                \\
            ,
                render_out.buffer.items,
            );
        }

        test "Markdown AST import chunks oversized semantic text and keeps chunks searchable" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const ast_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "doc.ast.json" });
            defer std.testing.allocator.free(ast_path);

            var paragraph = QueryOutputWriter{ .allocator = std.testing.allocator, .max_bytes = 96 * 1024 };
            defer paragraph.buffer.deinit(std.testing.allocator);
            while (paragraph.buffer.items.len <= markdown_ast_text_chunk_chars + 1024) {
                try paragraph.writeAll("Sentence keeps the semantic importer chunk boundary natural. ");
            }
            try std.testing.expect(paragraph.buffer.items.len > markdown_ast_text_chunk_chars);
            try paragraph.writeAll("tail_unique_chunk_token.");
            const duplicate_chunk_text = try std.testing.allocator.alloc(u8, markdown_ast_text_chunk_chars * 2);
            defer std.testing.allocator.free(duplicate_chunk_text);
            @memset(duplicate_chunk_text, 'x');

            var ast = QueryOutputWriter{ .allocator = std.testing.allocator, .max_bytes = 128 * 1024 };
            defer ast.buffer.deinit(std.testing.allocator);
            try ast.writeAll(
                \\{"type":"root","children":[
                \\{"type":"heading","depth":1,"children":[{"type":"text","value":"AST Title"}]},
                \\{"type":"paragraph","children":[{"type":"text","value":"
            );
            try ast.writeAll(paragraph.buffer.items);
            try ast.writeAll(
                \\"}]},
                \\{"type":"paragraph","children":[{"type":"text","value":"
            );
            try ast.writeAll(duplicate_chunk_text);
            try ast.writeAll(
                \\"}]},
                \\{"type":"table","children":[{"type":"tableRow","children":[{"type":"tableCell","children":[{"type":"text","value":"A"}]},{"type":"tableCell","children":[{"type":"text","value":"B"}]}]}]}
                \\]}
            );
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = ast_path,
                .data = ast.buffer.items,
                .flags = .{ .truncate = true },
            });

            var import_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer import_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "import-md-ast", db_path, ast_path, "--source", "doc-1" }, &import_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "import_md_ast") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "text_chunks=") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "text_chunks=0") == null);

            var rels_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer rels_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "list-rels", "--profile", "markdown-document" }, &rels_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, rels_out.buffer.items, "name=md:text_chunk") != null);

            var render_out = QueryOutputWriter{ .allocator = std.testing.allocator, .max_bytes = 64 * 1024 };
            defer render_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "render-md-doc", db_path, "1" }, &render_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, render_out.buffer.items, "# AST Title") != null);
            try std.testing.expect(std.mem.indexOf(u8, render_out.buffer.items, "Sentence keeps") != null);
            try std.testing.expect(std.mem.indexOf(u8, render_out.buffer.items, "tail_unique_chunk_token") != null);
            try std.testing.expect(std.mem.indexOf(u8, render_out.buffer.items, duplicate_chunk_text) != null);
            try std.testing.expect(std.mem.indexOf(u8, render_out.buffer.items, "| A | B |") != null);

            var rebuild_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer rebuild_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "rebuild-text", db_path }, &rebuild_out, std.testing.allocator, std.testing.io);

            var search_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer search_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "search", db_path, "tail_unique_chunk_token", "--limit", "4", "--timeout-ms", "10000" }, &search_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, search_out.buffer.items, "tail_unique_chunk_token") != null);
        }

        test "Markdown AST import caps oversized heading labels" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const ast_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "long-heading.ast.json" });
            defer std.testing.allocator.free(ast_path);

            const long_heading = try std.testing.allocator.alloc(u8, node_text_char_limit + 1000);
            defer std.testing.allocator.free(long_heading);
            @memset(long_heading, 'H');

            var ast = QueryOutputWriter{ .allocator = std.testing.allocator, .max_bytes = 32 * 1024 };
            defer ast.buffer.deinit(std.testing.allocator);
            try ast.writeAll(
                \\{"format":"mdast","tree":{"type":"root","children":[{"type":"heading","depth":1,"children":[{"type":"text","value":"
            );
            try ast.writeAll(long_heading);
            try ast.writeAll(
                \\"}]},{"type":"paragraph","children":[{"type":"text","value":"body survives"}]}]}}
            );
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = ast_path,
                .data = ast.buffer.items,
                .flags = .{ .truncate = true },
            });

            var import_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer import_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "import-md-ast", db_path, ast_path, "--source", "long-heading" }, &import_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "import_md_ast") != null);

            var render_out = QueryOutputWriter{ .allocator = std.testing.allocator, .max_bytes = 32 * 1024 };
            defer render_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "render-md-doc", db_path, "1" }, &render_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, render_out.buffer.items, "truncated heading wyhash64:") != null);
            try std.testing.expect(std.mem.indexOf(u8, render_out.buffer.items, "body survives") != null);
        }

        test "Markdown AST root accepts direct root and tree envelope" {
            var direct = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
                \\{"type":"root","children":[]}
            , .{});
            defer direct.deinit();
            const direct_root = try mdastRootValue(&direct.value);
            try std.testing.expectEqualStrings("root", try mdastNodeType(direct_root));

            var envelope = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
                \\{"format":"mdast","tree":{"type":"root","children":[]}}
            , .{});
            defer envelope.deinit();
            const envelope_root = try mdastRootValue(&envelope.value);
            try std.testing.expectEqualStrings("root", try mdastNodeType(envelope_root));
        }

        test "Markdown bootstrap never publishes failed or foreign stores" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const markdown_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "doc.md" });
            defer std.testing.allocator.free(markdown_path);
            const invalid_ast_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "invalid.json" });
            defer std.testing.allocator.free(invalid_ast_path);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = markdown_path,
                .data = "# Bootstrap\n\nAtomic publication.\n",
                .flags = .{ .truncate = true },
            });
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = invalid_ast_path,
                .data = "{}",
                .flags = .{ .truncate = true },
            });

            const invalid_target = try std.fs.path.join(std.testing.allocator, &.{ root_path, "invalid.kg" });
            defer std.testing.allocator.free(invalid_target);
            const invalid_staging = try markdownBootstrapStagingPath(std.testing.allocator, invalid_target);
            defer std.testing.allocator.free(invalid_staging);
            const invalid_marker = try markdownBootstrapTransactionPath(std.testing.allocator, invalid_target);
            defer std.testing.allocator.free(invalid_marker);
            const invalid_marker_tmp = try markdownBootstrapTransactionTmpPath(std.testing.allocator, invalid_marker);
            defer std.testing.allocator.free(invalid_marker_tmp);
            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try std.testing.expectError(
                error.InvalidRecord,
                run(&.{ "tinykg", "import-md-ast", invalid_target, invalid_ast_path }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expect(!try anyPathExists(std.testing.io, invalid_target));
            try std.testing.expect(!try anyPathExists(std.testing.io, invalid_staging));
            try std.testing.expect(!try anyPathExists(std.testing.io, invalid_marker));
            try std.testing.expect(!try anyPathExists(std.testing.io, invalid_marker_tmp));

            const foreign_target = try std.fs.path.join(std.testing.allocator, &.{ root_path, "foreign.kg" });
            defer std.testing.allocator.free(foreign_target);
            try createOwnedDirectory(std.testing.io, foreign_target);
            const foreign_target_sentinel = try std.fs.path.join(std.testing.allocator, &.{ foreign_target, "sentinel" });
            defer std.testing.allocator.free(foreign_target_sentinel);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = foreign_target_sentinel,
                .data = "preserve foreign target",
                .flags = .{ .truncate = true },
            });
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.AlreadyExists,
                run(&.{ "tinykg", "import-md-doc", foreign_target, markdown_path }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expect(try fileExists(std.testing.io, foreign_target_sentinel));

            const foreign_staging_target = try std.fs.path.join(std.testing.allocator, &.{ root_path, "foreign-staging.kg" });
            defer std.testing.allocator.free(foreign_staging_target);
            const foreign_staging = try markdownBootstrapStagingPath(std.testing.allocator, foreign_staging_target);
            defer std.testing.allocator.free(foreign_staging);
            try createOwnedDirectory(std.testing.io, foreign_staging);
            const foreign_staging_sentinel = try std.fs.path.join(std.testing.allocator, &.{ foreign_staging, "sentinel" });
            defer std.testing.allocator.free(foreign_staging_sentinel);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = foreign_staging_sentinel,
                .data = "preserve unmarked staging",
                .flags = .{ .truncate = true },
            });
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.MarkdownBootstrapRecoveryConflict,
                run(&.{ "tinykg", "import-md-doc", foreign_staging_target, markdown_path }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expect(try fileExists(std.testing.io, foreign_staging_sentinel));
            try std.testing.expect(!try anyPathExists(std.testing.io, foreign_staging_target));

            const foreign_marker_target = try std.fs.path.join(std.testing.allocator, &.{ root_path, "foreign-marker.kg" });
            defer std.testing.allocator.free(foreign_marker_target);
            const foreign_marker_staging = try markdownBootstrapStagingPath(std.testing.allocator, foreign_marker_target);
            defer std.testing.allocator.free(foreign_marker_staging);
            const foreign_marker = try markdownBootstrapTransactionPath(std.testing.allocator, foreign_marker_target);
            defer std.testing.allocator.free(foreign_marker);
            try createOwnedDirectory(std.testing.io, foreign_marker_staging);
            const foreign_marker_sentinel = try std.fs.path.join(std.testing.allocator, &.{ foreign_marker_staging, "sentinel" });
            defer std.testing.allocator.free(foreign_marker_sentinel);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = foreign_marker_sentinel,
                .data = "preserve staging with foreign marker",
                .flags = .{ .truncate = true },
            });
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = foreign_marker,
                .data = "not a TinyKG bootstrap marker",
                .flags = .{ .truncate = true },
            });
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.MarkdownBootstrapRecoveryConflict,
                run(&.{ "tinykg", "import-md-doc", foreign_marker_target, markdown_path }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expect(try fileExists(std.testing.io, foreign_marker_sentinel));
            try std.testing.expect(try fileExists(std.testing.io, foreign_marker));

            const nested_input_target = try std.fs.path.join(std.testing.allocator, &.{ root_path, "nested-input.kg" });
            defer std.testing.allocator.free(nested_input_target);
            const nested_input_staging = try markdownBootstrapStagingPath(std.testing.allocator, nested_input_target);
            defer std.testing.allocator.free(nested_input_staging);
            try createOwnedDirectory(std.testing.io, nested_input_staging);
            const nested_input = try std.fs.path.join(std.testing.allocator, &.{ nested_input_staging, "source.md" });
            defer std.testing.allocator.free(nested_input);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = nested_input,
                .data = "# Must survive\n",
                .flags = .{ .truncate = true },
            });
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.InvalidFileName,
                run(&.{ "tinykg", "import-md-doc", nested_input_target, nested_input }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expect(try fileExists(std.testing.io, nested_input));
        }

        test "Markdown bootstrap recovers owned staging and completed publication" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const canonical_target = try canonicalProspectivePath(std.testing.allocator, std.testing.io, db_path);
            defer std.testing.allocator.free(canonical_target);
            const markdown_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "doc.md" });
            defer std.testing.allocator.free(markdown_path);
            const staging_path = try markdownBootstrapStagingPath(std.testing.allocator, canonical_target);
            defer std.testing.allocator.free(staging_path);
            const marker_path = try markdownBootstrapTransactionPath(std.testing.allocator, canonical_target);
            defer std.testing.allocator.free(marker_path);
            const marker_tmp_path = try markdownBootstrapTransactionTmpPath(std.testing.allocator, marker_path);
            defer std.testing.allocator.free(marker_tmp_path);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = markdown_path,
                .data = "# Recovery\n\nRetry is idempotent.\n",
                .flags = .{ .truncate = true },
            });

            try writeMarkdownBootstrapMarker(
                std.testing.allocator,
                std.testing.io,
                marker_path,
                marker_tmp_path,
                canonical_target,
                "import-md-doc",
                null,
            );
            try createOwnedDirectory(std.testing.io, staging_path);
            const interrupted_sentinel = try std.fs.path.join(std.testing.allocator, &.{ staging_path, "partial" });
            defer std.testing.allocator.free(interrupted_sentinel);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = interrupted_sentinel,
                .data = "interrupted",
                .flags = .{ .truncate = true },
            });

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "import-md-doc", db_path, markdown_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(try existingTinyKgStorePath(std.testing.allocator, std.testing.io, db_path));
            try std.testing.expect(!try anyPathExists(std.testing.io, staging_path));
            try std.testing.expect(!try anyPathExists(std.testing.io, marker_path));
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "marker_cleanup_pending=0") != null);

            const identity = try storeContentIdentity(std.testing.allocator, std.testing.io, canonical_target);
            try writeMarkdownBootstrapMarker(
                std.testing.allocator,
                std.testing.io,
                marker_path,
                marker_tmp_path,
                canonical_target,
                "import-md-doc",
                identity,
            );
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "import-md-doc", db_path, markdown_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "nodes_imported=0") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edges_imported=0") != null);
            try std.testing.expect(!try anyPathExists(std.testing.io, marker_path));
            try std.testing.expect(!try anyPathExists(std.testing.io, marker_tmp_path));
        }

        test "Markdown bootstrap removes only transaction-bound marker temps" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root = path_buf[0..root_len];

            const target = try std.fs.path.join(std.testing.allocator, &.{ root, "recover-temp.kg" });
            defer std.testing.allocator.free(target);
            const staging = try markdownBootstrapStagingPath(std.testing.allocator, target);
            defer std.testing.allocator.free(staging);
            const marker = try markdownBootstrapTransactionPath(std.testing.allocator, target);
            defer std.testing.allocator.free(marker);
            const marker_tmp = try markdownBootstrapTransactionTmpPath(std.testing.allocator, marker);
            defer std.testing.allocator.free(marker_tmp);
            const marker_tmp_build = try markdownBootstrapTransactionTmpPath(std.testing.allocator, marker_tmp);
            defer std.testing.allocator.free(marker_tmp_build);

            try writeMarkdownBootstrapMarker(
                std.testing.allocator,
                std.testing.io,
                marker,
                marker_tmp,
                target,
                "import-md-doc",
                null,
            );
            {
                var store = try storage.Store.init(std.testing.allocator, std.testing.io, staging);
                defer store.deinit();
                try store.createEmpty();
                try store.appendNode(.{ .id = .fromInt(1), .kind = .document, .text = "completed private stage" });
            }
            const identity = try storeContentIdentity(std.testing.allocator, std.testing.io, staging);
            try writeMarkdownBootstrapMarker(
                std.testing.allocator,
                std.testing.io,
                marker_tmp,
                marker_tmp_build,
                target,
                "import-md-doc",
                identity,
            );
            try recoverMarkdownBootstrap(std.testing.allocator, std.testing.io, target, staging, marker, marker_tmp);
            try std.testing.expect(!try anyPathExists(std.testing.io, staging));
            try std.testing.expect(!try anyPathExists(std.testing.io, marker));
            try std.testing.expect(!try anyPathExists(std.testing.io, marker_tmp));

            const foreign_target = try std.fs.path.join(std.testing.allocator, &.{ root, "foreign-temp.kg" });
            defer std.testing.allocator.free(foreign_target);
            const foreign_staging = try markdownBootstrapStagingPath(std.testing.allocator, foreign_target);
            defer std.testing.allocator.free(foreign_staging);
            const foreign_marker = try markdownBootstrapTransactionPath(std.testing.allocator, foreign_target);
            defer std.testing.allocator.free(foreign_marker);
            const foreign_marker_tmp = try markdownBootstrapTransactionTmpPath(std.testing.allocator, foreign_marker);
            defer std.testing.allocator.free(foreign_marker_tmp);
            const foreign_marker_tmp_build = try markdownBootstrapTransactionTmpPath(std.testing.allocator, foreign_marker_tmp);
            defer std.testing.allocator.free(foreign_marker_tmp_build);
            try writeMarkdownBootstrapMarker(
                std.testing.allocator,
                std.testing.io,
                foreign_marker,
                foreign_marker_tmp,
                foreign_target,
                "import-md-doc",
                null,
            );
            try createOwnedDirectory(std.testing.io, foreign_staging);
            const sentinel = try std.fs.path.join(std.testing.allocator, &.{ foreign_staging, "sentinel" });
            defer std.testing.allocator.free(sentinel);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = sentinel,
                .data = "preserve foreign state",
                .flags = .{ .truncate = true },
            });
            try writeMarkdownBootstrapMarker(
                std.testing.allocator,
                std.testing.io,
                foreign_marker_tmp,
                foreign_marker_tmp_build,
                foreign_target,
                "import-md-ast",
                null,
            );
            try std.testing.expectError(
                error.MarkdownBootstrapRecoveryConflict,
                recoverMarkdownBootstrap(std.testing.allocator, std.testing.io, foreign_target, foreign_staging, foreign_marker, foreign_marker_tmp),
            );
            try std.testing.expect(try fileExists(std.testing.io, sentinel));
            try std.testing.expect(try anyPathExists(std.testing.io, foreign_marker));
            try std.testing.expect(try anyPathExists(std.testing.io, foreign_marker_tmp));
        }

        test "Markdown render preserves no-sidecar projection order from compacted edge segments" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const compacted_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "edge-segments", "compacted" });
            defer std.testing.allocator.free(compacted_path);

            var store = try storage.Store.initWithOptions(std.testing.allocator, std.testing.io, db_path, .{
                .durability = .fast,
                .validate_indexes_on_read = false,
            });
            defer store.deinit();
            try store.createEmpty();

            try store.appendNode(.{ .id = .fromInt(1), .kind = .document, .text = "doc" });
            try store.appendNode(.{ .id = .fromInt(2), .kind = .observation, .text = "First" });
            try store.appendNode(.{ .id = .fromInt(3), .kind = .observation, .text = "Second" });
            try store.appendNode(.{ .id = .fromInt(4), .kind = .file, .text = "base" });
            try store.appendNode(.{ .id = .fromInt(5), .kind = .observation, .text = "base target" });

            var base_edges = std.ArrayList(graph.Edge).empty;
            defer base_edges.deinit(std.testing.allocator);
            try base_edges.ensureTotalCapacity(std.testing.allocator, 1024);
            var edge_id: u64 = 1;
            while (edge_id <= 1024) : (edge_id += 1) {
                base_edges.appendAssumeCapacity(.{
                    .id = .fromInt(edge_id),
                    .src = .fromInt(4),
                    .rel = .mentions,
                    .dst = .fromInt(5),
                });
            }
            try store.appendEdgesBatch(base_edges.items);
            try store.appendEdgesBatch(&.{
                .{ .id = .fromInt(1025), .src = .fromInt(1), .rel = md_rel_paragraph, .dst = .fromInt(2) },
                .{ .id = .fromInt(1026), .src = .fromInt(1), .rel = md_rel_paragraph, .dst = .fromInt(3) },
            });
            try std.testing.expectEqual(@as(u64, 1026), try store.compactPublishedEdgeSegments(compacted_path));

            const rendered = try renderMarkdownDocument(std.testing.allocator, store, .fromInt(1));
            defer std.testing.allocator.free(rendered);
            try std.testing.expectEqualStrings(
                \\First
                \\
                \\Second
                \\
                \\
            ,
                rendered,
            );
        }

        test "Markdown doc edit benchmark reports local changed records" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "bench-md-doc-edit", db_path, "24", "--edit-index", "7", "--repeat-local-edits", "2", "--repeat-update-edits", "2", "--agent-mixed-writes", "2", "--max-edit-changed-records", "3", "--max-repeat-edit-elapsed-ns", "999999999999", "--max-repeat-update-edit-elapsed-ns", "999999999999", "--max-render-local-subtree-elapsed-ns", "999999999999" }, &out, std.testing.allocator, std.testing.io);

            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "bench_workload=markdown-doc-edit paragraphs=24 edit_index=7\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "initial_nodes_imported=27") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "initial_edges_imported=26") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edit_document=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edit_nodes_imported=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edit_edges_imported=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edit_projection_edges_deleted=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edit_changed_records=3") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "max_edit_changed_records_enabled=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "max_edit_changed_records=3") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "changed_records_passed=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "passed=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "repeat_update_edit_gate enabled=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "repeat_update_edits=2") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "max_repeat_update_edit_elapsed_ns_enabled=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "repeat_local_edits=2") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "repeat_insert_edits=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "repeat_delete_edits=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "max_repeat_edit_elapsed_ns_enabled=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "agent_mixed_writes=2") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "agent_mixed_fact_created=2") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "agent_mixed_projection_edge_created=2") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "render_local_subtree_root=") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "max_render_local_subtree_elapsed_ns_enabled=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "render_local_subtree_passed=1") != null);
            const markdown_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.mdbench.md", .{db_path});
            defer std.testing.allocator.free(markdown_path);
            try std.testing.expect(!try anyPathExists(std.testing.io, markdown_path));

            const failing_db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg-failing-gate" });
            defer std.testing.allocator.free(failing_db_path);
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                core.Error.BudgetExceeded,
                run(&.{ "tinykg", "bench-md-doc-edit", failing_db_path, "24", "--edit-index", "7", "--max-edit-changed-records", "2" }, &out, std.testing.allocator, std.testing.io),
            );
        }

        test "Markdown document projection preserves explicit parser boundary syntax" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const markdown_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "doc.md" });
            defer std.testing.allocator.free(markdown_path);

            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = markdown_path,
                .data =
                \\# Boundary
                \\
                \\Paragraph with [link](https://example.com), **bold**, and `code`.
                \\
                \\- one
                \\  continuation
                \\- two
                \\
                \\> quote
                \\> **strong**
                \\
                \\<div>
                \\raw <span>x</span>
                \\</div>
                \\
                \\[^n]: Footnote text
                \\    continued
                \\
                \\[ref]: https://example.com "Title"
                \\
                \\Setext
                \\------
                \\
                \\    indented code fallback
                \\
                \\---
                \\
                ,
                .flags = .{ .truncate = true },
            });

            var import_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer import_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "import-md-doc", db_path, markdown_path }, &import_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "nodes_imported=11") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "edges_imported=10") != null);

            var rels_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer rels_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "list-rels", "--profile", "markdown-document" }, &rels_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, rels_out.buffer.items, "name=md:list") != null);
            try std.testing.expect(std.mem.indexOf(u8, rels_out.buffer.items, "name=md:blockquote") != null);
            try std.testing.expect(std.mem.indexOf(u8, rels_out.buffer.items, "name=md:html_block") != null);
            try std.testing.expect(std.mem.indexOf(u8, rels_out.buffer.items, "name=md:footnote_def") != null);
            try std.testing.expect(std.mem.indexOf(u8, rels_out.buffer.items, "name=md:link_reference") != null);
            try std.testing.expect(std.mem.indexOf(u8, rels_out.buffer.items, "name=md:raw_block") != null);

            var render_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer render_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "render-md-doc", db_path, "1" }, &render_out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings(
                \\# Boundary
                \\
                \\Paragraph with [link](https://example.com), **bold**, and `code`.
                \\
                \\- one
                \\  continuation
                \\- two
                \\
                \\> quote
                \\> **strong**
                \\
                \\<div>
                \\raw <span>x</span>
                \\</div>
                \\
                \\[^n]: Footnote text
                \\    continued
                \\
                \\[ref]: https://example.com "Title"
                \\
                \\Setext
                \\------
                \\
                \\    indented code fallback
                \\
                \\---
                \\
                \\
            ,
                render_out.buffer.items,
            );
        }

        test "Markdown document projection reimport reuses stable identities" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const markdown_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "doc.md" });
            defer std.testing.allocator.free(markdown_path);

            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = markdown_path,
                .data =
                \\# Stable
                \\
                \\Same paragraph.
                \\
                \\| A | A |
                \\
                ,
                .flags = .{ .truncate = true },
            });

            var import_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer import_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "import-md-doc", db_path, markdown_path }, &import_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "nodes_imported=6") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "edges_imported=6") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "projection_edges_deleted=0") != null);

            import_out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "import-md-doc", db_path, markdown_path }, &import_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "document=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "nodes_imported=0") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "edges_imported=0") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "projection_edges_deleted=0") != null);

            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = markdown_path,
                .data =
                \\# Retitled
                \\
                \\Changed paragraph.
                \\
                \\| A | A |
                \\
                ,
                .flags = .{ .truncate = true },
            });

            import_out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "import-md-doc", db_path, markdown_path }, &import_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "document=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "nodes_imported=2") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "edges_imported=3") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "projection_edges_deleted=3") != null);

            var render_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer render_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "render-md-doc", db_path, "1" }, &render_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, render_out.buffer.items, "# Retitled") != null);
            try std.testing.expect(std.mem.indexOf(u8, render_out.buffer.items, "Changed paragraph.") != null);
            try std.testing.expect(std.mem.indexOf(u8, render_out.buffer.items, "# Stable") == null);
            try std.testing.expect(std.mem.indexOf(u8, render_out.buffer.items, "Same paragraph.") == null);
        }

        test "Markdown projection upsert appends when ordered slot changes to reused content" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const markdown_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "doc.md" });
            defer std.testing.allocator.free(markdown_path);

            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = markdown_path,
                .data =
                \\# Slot Reuse
                \\
                \\Old first paragraph.
                \\
                \\Repeated paragraph.
                \\
                ,
                .flags = .{ .truncate = true },
            });

            var import_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer import_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "import-md-doc", db_path, markdown_path }, &import_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "nodes_imported=4") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "edges_imported=3") != null);

            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = markdown_path,
                .data =
                \\# Slot Reuse
                \\
                \\Repeated paragraph.
                \\
                \\Repeated paragraph.
                \\
                ,
                .flags = .{ .truncate = true },
            });

            import_out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "import-md-doc", db_path, markdown_path }, &import_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "nodes_imported=0") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "edges_imported=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "projection_edges_deleted=1") != null);

            var render_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer render_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "render-md-doc", db_path, "1" }, &render_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, render_out.buffer.items, "Old first paragraph.") == null);
            try std.testing.expect(std.mem.indexOf(u8, render_out.buffer.items, "Repeated paragraph.\n\nRepeated paragraph.") != null);
        }

        test "Markdown orphan GC previews and deletes superseded unreferenced content" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const markdown_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "doc.md" });
            defer std.testing.allocator.free(markdown_path);

            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = markdown_path,
                .data =
                \\# Old Title
                \\
                \\Old paragraph.
                \\
                ,
                .flags = .{ .truncate = true },
            });

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "import-md-doc", db_path, markdown_path }, &out, std.testing.allocator, std.testing.io);

            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = markdown_path,
                .data =
                \\# New Title
                \\
                \\New paragraph.
                \\
                ,
                .flags = .{ .truncate = true },
            });

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "import-md-doc", db_path, markdown_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "projection_edges_deleted=2") != null);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "gc-md-orphans", db_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "apply=0") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "candidates=2") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "deleted=0") != null);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "gc-md-orphans", db_path, "--apply" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "apply=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "candidates=2") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "deleted=2") != null);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "gc-md-orphans", db_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "candidates=0") != null);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "render-md-doc", db_path, "1" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "# New Title") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "New paragraph.") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "Old paragraph.") == null);
        }

        test "Markdown orphan GC preserves content still referenced by another document" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const first_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "one.md" });
            defer std.testing.allocator.free(first_path);
            const second_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "two.md" });
            defer std.testing.allocator.free(second_path);

            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = first_path,
                .data =
                \\# One
                \\
                \\Shared paragraph.
                \\
                ,
                .flags = .{ .truncate = true },
            });
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = second_path,
                .data =
                \\# Two
                \\
                \\Shared paragraph.
                \\
                ,
                .flags = .{ .truncate = true },
            });

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "import-md-doc", db_path, first_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "import-md-doc", db_path, second_path }, &out, std.testing.allocator, std.testing.io);

            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = first_path,
                .data =
                \\# One
                \\
                \\Changed paragraph.
                \\
                ,
                .flags = .{ .truncate = true },
            });

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "import-md-doc", db_path, first_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "projection_edges_deleted=1") != null);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "gc-md-orphans", db_path, "--apply" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "candidates=0") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "deleted=0") != null);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "render-md-doc", db_path, "4" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "Shared paragraph.") != null);
        }

        test "Markdown orphan GC rejects false parent scope before global two-document preflight" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const first_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "one.md" });
            defer std.testing.allocator.free(first_path);
            const second_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "two.md" });
            defer std.testing.allocator.free(second_path);

            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = first_path,
                .data =
                \\# Old One
                \\
                \\Old first paragraph.
                \\
                ,
                .flags = .{ .truncate = true },
            });
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = second_path,
                .data =
                \\# Old Two
                \\
                \\Old second paragraph.
                \\
                ,
                .flags = .{ .truncate = true },
            });

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "import-md-doc", db_path, first_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "import-md-doc", db_path, second_path }, &out, std.testing.allocator, std.testing.io);

            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = first_path,
                .data =
                \\# New One
                \\
                \\New first paragraph.
                \\
                ,
                .flags = .{ .truncate = true },
            });
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = second_path,
                .data =
                \\# New Two
                \\
                \\New second paragraph.
                \\
                ,
                .flags = .{ .truncate = true },
            });

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "import-md-doc", db_path, first_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "projection_edges_deleted=2") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "import-md-doc", db_path, second_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "projection_edges_deleted=2") != null);

            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.UnknownOption,
                run(&.{ "tinykg", "gc-md-orphans", db_path, "--parent", "1", "--apply" }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expectEqual(@as(usize, 0), out.buffer.items.len);

            try run(&.{ "tinykg", "gc-md-orphans", db_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "apply=0") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "candidates=4") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "deleted=0") != null);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "render-md-doc", db_path, "1" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "# New One") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "render-md-doc", db_path, "4" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "# New Two") != null);
        }
    };
}
