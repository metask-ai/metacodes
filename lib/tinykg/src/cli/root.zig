const std = @import("std");
const version = @import("../version.zig");
const builtin = @import("builtin");
const agent = @import("../agent.zig");
const core = @import("../core.zig");
const dag = @import("../dag.zig");
const graph = @import("../graph.zig");
const query = @import("../query.zig");
const query_index = @import("../index.zig");
const ql = @import("../ql.zig");
const catalog_mod = @import("../catalog.zig");
const schema = @import("../schema.zig");
const schema_reconciliation = @import("../schema_reconciliation.zig");
const segment_mod = @import("../segment.zig");
const segment_bundle = @import("../segment_bundle.zig");
const segment_node_index = @import("../segment_node_index.zig");
const storage = @import("../storage.zig");
const task = @import("../task.zig");
const process_liveness = @import("../process_liveness.zig");
const text_search = @import("../text.zig");
const agent_write_command_mod = @import("agent_write_command.zig");
const apply_command_mod = @import("apply_command.zig");
const benchmark_contract_mod = @import("benchmark_contract.zig");
const benchmark_execution_mod = @import("benchmark_execution.zig");
const command_mod = @import("command.zig");
const contain_tree_migration_command_mod = @import("contain_tree_migration_command.zig");
const context_commands_mod = @import("context_commands.zig");
const database_arguments_mod = @import("database_arguments.zig");
const edge_mutation_commands_mod = @import("edge_mutation_commands.zig");
const edge_segment_commands_mod = @import("edge_segment_commands.zig");
const find_command_mod = @import("find_command.zig");
const graph_traversal_commands_mod = @import("graph_traversal_commands.zig");
const governance_command_mod = @import("governance_command.zig");
const help_mod = @import("help.zig");
const idempotent_node_commands_mod = @import("idempotent_node_commands.zig");
const markdown_import_commands_mod = @import("markdown_import_commands.zig");
const markdown_orphan_gc_command_mod = @import("markdown_orphan_gc_command.zig");
const markdown_render_command_mod = @import("markdown_render_command.zig");
const metaknow_replay_import_command_mod = @import("metaknow_replay_import_command.zig");
const metaknow_replay_workload_mod = @import("metaknow_replay_workload.zig");
const migrate_store_v2_command_mod = @import("migrate_store_v2_command.zig");
const store_migration_v2_data_plane_mod = @import("store_migration_v2_data_plane.zig");
const store_upgrade_command_mod = @import("store_upgrade_command.zig");
const node_mutation_commands_mod = @import("node_mutation_commands.zig");
const node_read_commands_mod = @import("node_read_commands.zig");
const node_text_run_gc_command_mod = @import("node_text_run_gc_command.zig");
const property_commands_mod = @import("property_commands.zig");
const query_command_mod = @import("query_command.zig");
const rebuild_text_command_mod = @import("rebuild_text_command.zig");
const recent_commands_mod = @import("recent_commands.zig");
const schema_commands_mod = @import("schema_commands.zig");
const schema_reconcile_command_mod = @import("schema_reconcile_command.zig");
const schema_scope_command_mod = @import("schema_scope_command.zig");
const search_command_mod = @import("search_command.zig");
const segment_commands_mod = @import("segment_commands.zig");
const store_copy_commands_mod = @import("store_copy_commands.zig");
const store_init_command_mod = @import("store_init_command.zig");
const store_inspection_commands_mod = @import("store_inspection_commands.zig");
const store_interchange_commands_mod = @import("store_interchange_commands.zig");
const store_interchange_data_plane_mod = @import("store_interchange_data_plane.zig");
const metaknow_replay_interchange_data_plane_mod = @import("metaknow_replay_interchange_data_plane.zig");
const markdown_projection_data_plane_mod = @import("markdown_projection_data_plane.zig");
const store_migration_foundation_mod = @import("store_migration_foundation.zig");
const schema_administration_data_plane_mod = @import("schema_administration_data_plane.zig");
const query_context_read_data_plane_mod = @import("query_context_read_data_plane.zig");
const task_read_metrics_data_plane_mod = @import("task_read_metrics_data_plane.zig");
const store_copy_snapshot_data_plane_mod = @import("store_copy_snapshot_data_plane.zig");
const task_close_command_mod = @import("task_close_command.zig");
const task_event_command_mod = @import("task_event_command.zig");
const task_lease_commands_mod = @import("task_lease_commands.zig");
const task_read_commands_mod = @import("task_read_commands.zig");
const task_mutation_arguments_mod = @import("task_mutation_arguments.zig");
const task_hierarchy_mod = @import("task_hierarchy.zig");
const schema_document_registry_loader_mod = @import("schema_document_registry_loader.zig");
const governed_node_write_admission_mod = @import("governed_node_write_admission.zig");
const root_command_dispatch_pipeline_mod = @import("root_command_dispatch_pipeline.zig");

const schema_document_registry_loader = schema_document_registry_loader_mod.SchemaDocumentRegistryLoader();
const rootParseNodeIdArg = parseNodeIdArg;
const rootLinkNodeToProjectParent = linkNodeToProjectParent;
const GovernedNodeWriteAdmissionOps = struct {
    pub fn parseNodeIdArg(value: []const u8) !core.NodeId {
        return rootParseNodeIdArg(value);
    }

    pub fn linkNodeToProjectParent(
        allocator: std.mem.Allocator,
        store: storage.Store,
        node_id: core.NodeId,
        parent_node_id: core.NodeId,
    ) !void {
        return rootLinkNodeToProjectParent(allocator, store, node_id, parent_node_id);
    }
};
const governed_node_write_admission = governed_node_write_admission_mod.GovernedNodeWriteAdmission(GovernedNodeWriteAdmissionOps);

var runtime_env_map: ?*const std.process.Environ.Map = null;
var export_temp_nonce: std.atomic.Value(u64) = .init(0);

pub fn setRuntimeEnvMap(map: ?*const std.process.Environ.Map) void {
    runtime_env_map = map;
    benchmark_execution.setRuntimeEnvMap(map);
}

fn envVar(name: []const u8) ?[]const u8 {
    if (runtime_env_map) |map| return map.get(name);
    if (!builtin.link_libc) return null;
    if (std.mem.eql(u8, name, "TINYKG_BENCH_TRACE")) {
        if (std.c.getenv("TINYKG_BENCH_TRACE")) |raw| return std.mem.span(raw);
    }
    if (std.mem.eql(u8, name, default_db_env_name)) {
        if (std.c.getenv(default_db_env_name)) |raw| return std.mem.span(raw);
    }
    return null;
}

pub const Command = command_mod.Command;
pub const parseCommand = command_mod.parseCommand;

const DatabaseArgumentOps = struct {
    pub fn defaultPath() []const u8 {
        return defaultDbPath();
    }

    pub fn literalDefaultPath() []const u8 {
        return default_db_path;
    }

    pub fn existingStorePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
        return existingTinyKgStorePath(allocator, io, path);
    }
};

const database_arguments = database_arguments_mod.DatabaseArguments(DatabaseArgumentOps);
const parseDbArgs = database_arguments.parse;
const parseFreeTextDbArgs = database_arguments.parseFreeText;
const benchmark_contract = benchmark_contract_mod.BenchmarkContract;
const benchmark_execution = benchmark_execution_mod.BenchmarkExecution;
const metaknow_replay_workload = metaknow_replay_workload_mod.MetaknowReplayWorkload;
const parseBenchArgs = benchmark_contract.parseArguments;

const BenchMetaknowReplay = metaknow_replay_workload.Replay;
const BenchMetaknowReplayEdgeStats = metaknow_replay_workload.EdgeStats;
const BenchTextDensityStats = metaknow_replay_workload.TextDensityStats;
const BenchNodeLoadTimings = metaknow_replay_workload.NodeLoadTimings;
const loadBenchMetaknowReplay = metaknow_replay_workload.load;

const MarkdownImportCommandOps = struct {
    pub const Result = struct {
        document_id: u64,
        nodes_imported: usize,
        edges_imported: usize,
        projection_edges_deleted: usize,
        markdown_bytes: u64,
        text_chunks: usize,
        marker_cleanup_pending: bool,
    };

    pub fn startTimer(io: std.Io) u128 {
        return monotonicNs(io);
    }

    pub fn elapsedSince(io: std.Io, start_ns: u128) u128 {
        return elapsedNs(io, start_ns);
    }

    pub fn execute(allocator: std.mem.Allocator, io: std.Io, request: anytype) !Result {
        const result = switch (request) {
            .document => |parsed| try executeMarkdownImport(allocator, io, .{ .document = .{
                .db_path = parsed.db_path,
                .file_path = parsed.file_path,
                .durability = switch (parsed.durability) {
                    .safe => .safe,
                    .fast => .fast,
                },
                .source_label = parsed.source_label,
            } }),
            .ast => |parsed| try executeMarkdownImport(allocator, io, .{ .ast = .{
                .db_path = parsed.db_path,
                .ast_path = parsed.ast_path,
                .format = parsed.format,
                .source_id = parsed.source_id,
                .durability = switch (parsed.durability) {
                    .safe => .safe,
                    .fast => .fast,
                },
            } }),
        };
        return .{
            .document_id = result.document_id.toInt(),
            .nodes_imported = result.nodes_imported,
            .edges_imported = result.edges_imported,
            .projection_edges_deleted = result.projection_edges_deleted,
            .markdown_bytes = result.markdown_bytes,
            .text_chunks = result.text_chunks,
            .marker_cleanup_pending = result.marker_cleanup_pending,
        };
    }
};

const markdown_import_commands = markdown_import_commands_mod.MarkdownImportCommands(MarkdownImportCommandOps);

const MarkdownRenderCommandOps = struct {
    pub fn parseDbArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !database_arguments.Parsed {
        return parseDbArgs(allocator, io, args, 2, 1, 13, true);
    }

    pub fn parseNodeId(value: []const u8) !u64 {
        return (try parseNodeIdArg(value)).toInt();
    }

    fn facadeArguments(args: anytype) ParsedRenderMarkdownDocumentArgs {
        return .{
            .document_id = core.NodeId.fromInt(args.document_id),
            .render_root_id = core.NodeId.fromInt(args.render_root_id),
            .format = switch (args.format) {
                .text => .text,
                .json => .json,
            },
            .meta = args.meta,
            .preview_lines = args.preview_lines,
            .page_size_bytes = args.page_size_bytes,
            .cursor = args.cursor,
        };
    }

    pub const Context = struct {
        allocator: std.mem.Allocator,
        cli_lock: CliStoreLock,
        store: storage.Store,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !Context {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{ .allocator = allocator, .cli_lock = cli_lock, .store = store };
        }

        pub fn deinit(self: *Context) void {
            self.store.deinit();
            self.cli_lock.deinit();
            self.* = undefined;
        }

        pub fn renderFull(self: *Context, render_root_id: u64) ![]u8 {
            return renderMarkdownDocument(self.allocator, self.store, core.NodeId.fromInt(render_root_id));
        }

        pub fn renderJson(self: *Context, args: anytype, rendered: []const u8) ![]u8 {
            return renderMarkdownDocumentJsonOutput(
                self.allocator,
                self.store,
                MarkdownRenderCommandOps.facadeArguments(args),
                rendered,
            );
        }

        pub fn renderPageJson(self: *Context, args: anytype) ![]u8 {
            return renderMarkdownDocumentPageJsonOutput(
                self.allocator,
                self.store,
                MarkdownRenderCommandOps.facadeArguments(args),
            );
        }
    };
};

const markdown_render_command = markdown_render_command_mod.MarkdownRenderCommand(MarkdownRenderCommandOps);

const MarkdownOrphanGcCommandOps = struct {
    pub const Result = struct {
        candidates: usize,
        deleted: usize,
        skipped_referenced: usize,
        skipped_unmanaged: usize,
        elapsed_ns: u128,
    };

    pub const Context = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        cli_lock: CliStoreLock,
        store: storage.Store,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !Context {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{
                .allocator = allocator,
                .io = io,
                .cli_lock = cli_lock,
                .store = store,
            };
        }

        pub fn deinit(self: *Context) void {
            self.store.deinit();
            self.cli_lock.deinit();
            self.* = undefined;
        }

        pub fn execute(self: *Context, apply: bool) !Result {
            const result = try gcMarkdownOrphanNodes(
                self.allocator,
                self.io,
                self.store,
                apply,
            );
            return .{
                .candidates = result.candidates,
                .deleted = result.deleted,
                .skipped_referenced = result.skipped_referenced,
                .skipped_unmanaged = result.skipped_unmanaged,
                .elapsed_ns = result.elapsed_ns,
            };
        }
    };
};

const markdown_orphan_gc_command =
    markdown_orphan_gc_command_mod.MarkdownOrphanGcCommand(MarkdownOrphanGcCommandOps);

const ApplyCommandOps = struct {
    pub const Parsed = struct {
        db_path: []const u8,
        batch_path: []const u8,
    };

    pub const Result = struct {
        version: u16,
        nodes_created: usize,
        nodes_existing: usize,
        edges_created: usize,
        edges_existing: usize,
    };

    pub fn parseDbArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !Parsed {
        const parsed = try parseDbArgs(allocator, io, args, 2, 1, 1, true);
        return .{
            .db_path = parsed.db_path,
            .batch_path = parsed.rest[0],
        };
    }

    pub const Context = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        cli_lock: CliStoreLock,
        store: storage.Store,
        effective_schema: EffectiveSchemaRegistry,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !Context {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            var store = try storage.Store.open(allocator, io, db_path);
            errdefer store.deinit();
            const effective_schema = try loadEffectiveSchemaRegistry(allocator, io, store, null);
            return .{
                .allocator = allocator,
                .io = io,
                .cli_lock = cli_lock,
                .store = store,
                .effective_schema = effective_schema,
            };
        }

        pub fn deinit(self: *Context) void {
            self.effective_schema.deinit();
            self.store.deinit();
            self.cli_lock.deinit();
            self.* = undefined;
        }

        pub fn execute(self: *Context, batch_path: []const u8) !Result {
            const result = try applyJsonlBatch(
                self.allocator,
                self.io,
                self.store,
                batch_path,
                self.effective_schema.registry,
                self.effective_schema.enforce_application_schema,
            );
            return .{
                .version = apply_batch_version,
                .nodes_created = result.nodes_created,
                .nodes_existing = result.nodes_existing,
                .edges_created = result.edges_created,
                .edges_existing = result.edges_existing,
            };
        }
    };
};

const apply_command = apply_command_mod.ApplyCommand(ApplyCommandOps);

const MetaknowReplayImportCommandOps = struct {
    pub const Result = struct {
        nodes_loaded: usize,
        nodes_imported: usize,
        edges_loaded: usize,
        edges_imported: usize,
        edges_skipped_missing_endpoint: usize,
        corpus_bytes: u64,
        text_warmed: bool,
        marker_cleanup_pending: bool,
    };

    pub fn defaultChunkSize() usize {
        return default_bench_chunk_size;
    }

    pub fn startTimer(io: std.Io) u128 {
        return monotonicNs(io);
    }

    pub fn elapsedSince(io: std.Io, start_ns: u128) u128 {
        return elapsedNs(io, start_ns);
    }

    pub fn execute(allocator: std.mem.Allocator, io: std.Io, request: anytype) !Result {
        const result = try importMetaknowReplayCorpus(
            allocator,
            io,
            request.db_path,
            request.corpus_dir_path,
            request.chunk_size,
            request.warm_text,
        );
        return .{
            .nodes_loaded = result.nodes_loaded,
            .nodes_imported = result.nodes_imported,
            .edges_loaded = result.edges_loaded,
            .edges_imported = result.edges_imported,
            .edges_skipped_missing_endpoint = result.edges_skipped_missing_endpoint,
            .corpus_bytes = result.corpus_bytes,
            .text_warmed = result.text_warmed,
            .marker_cleanup_pending = result.marker_cleanup_pending,
        };
    }
};

const metaknow_replay_import_command =
    metaknow_replay_import_command_mod.MetaknowReplayImportCommand(MetaknowReplayImportCommandOps);

const AgentWriteCommandOps = struct {
    const PreparedSingle = struct {
        src: core.NodeId,
        dst: core.NodeId,
        render_rel: core.RelKind,
    };

    pub fn parseDbArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !database_arguments.Parsed {
        return parseDbArgs(allocator, io, args, 2, 1, std.math.maxInt(usize), true);
    }

    pub fn validateNodeText(value: []const u8) !void {
        try validateNodeTextGranularity(value);
    }

    pub fn validateNodeMetadata(
        name: ?[]const u8,
        summary: ?[]const u8,
        retrieval_hints: ?[]const u8,
    ) !void {
        try validateNodeLlmMetadataGranularity(name, summary, retrieval_hints);
    }

    pub fn prepareSingle(parsed: anytype) !PreparedSingle {
        const src = try parseNodeIdArg(parsed.src_node_id);
        const dst = try parseNodeIdArg(parsed.dst_node_id);
        const render_rel = try parseRelKindWithLoadedSchema(parsed.render_rel_label, null);
        if (!agentWriteRenderRelSupported(render_rel)) return error.InvalidRelKind;
        return .{ .src = src, .dst = dst, .render_rel = render_rel };
    }

    pub const Context = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        cli_lock: CliStoreLock,
        store: storage.Store,
        effective_schema: EffectiveSchemaRegistry,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            db_path: []const u8,
            schema_path: ?[]const u8,
        ) !Context {
            var cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            var store = try storage.Store.open(allocator, io, db_path);
            errdefer store.deinit();
            var effective_schema = try loadEffectiveSchemaRegistry(allocator, io, store, schema_path);
            errdefer effective_schema.deinit();
            return .{
                .allocator = allocator,
                .io = io,
                .cli_lock = cli_lock,
                .store = store,
                .effective_schema = effective_schema,
            };
        }

        pub fn deinit(self: *Context) void {
            self.effective_schema.deinit();
            self.store.deinit();
            self.cli_lock.deinit();
            self.* = undefined;
        }

        pub fn writeSingle(self: *Context, parsed: anytype, prepared: PreparedSingle) !struct {
            src: u64,
            rel: u16,
            dst: u64,
            fact_edge: u64,
            fact_created: bool,
            projection_root: u64,
            projection_content: u64,
            projection_edge: u64,
            projection_nodes_imported: usize,
            projection_edge_created: bool,
            content_node_properties: usize,
            projection_links: usize,
            agent_inbox_created: bool,
        } {
            const fact_rel = try parseRelKindWithSchemaPolicy(
                parsed.rel_label,
                self.effective_schema.registry,
                self.effective_schema.enforce_application_schema,
            );
            if (self.effective_schema.enforce_application_schema) {
                try validateSchemaEdgeEndpoints(
                    self.store,
                    self.effective_schema.registry,
                    prepared.src,
                    fact_rel,
                    prepared.dst,
                );
            }
            const result = try agentWriteFactAndProjection(
                self.allocator,
                self.io,
                self.store,
                parsed,
                prepared.src,
                fact_rel,
                prepared.dst,
                prepared.render_rel,
            );
            return .{
                .src = prepared.src.toInt(),
                .rel = @intFromEnum(fact_rel),
                .dst = prepared.dst.toInt(),
                .fact_edge = result.fact_edge_id.toInt(),
                .fact_created = result.fact_created,
                .projection_root = result.projection_root_id.toInt(),
                .projection_content = result.projection_content_id.toInt(),
                .projection_edge = result.projection_edge_id.toInt(),
                .projection_nodes_imported = result.projection_nodes_imported,
                .projection_edge_created = result.projection_edge_created,
                .content_node_properties = result.content_node_properties,
                .projection_links = result.projection_links,
                .agent_inbox_created = result.agent_inbox_created,
            };
        }

        pub fn writeJson(self: *Context, parsed: anytype) !struct {
            items: usize,
            fact_created: usize,
            projection_nodes_imported: usize,
            projection_edge_created: usize,
            content_node_properties: usize,
            projection_links: usize,
            fact_properties: usize,
            projection_properties: usize,
            agent_inbox_created: usize,
        } {
            const result = try agentWriteJsonBatch(
                self.allocator,
                self.io,
                self.store,
                parsed,
                self.effective_schema.registry,
                self.effective_schema.enforce_application_schema,
            );
            defer result.deinit(self.allocator);
            return .{
                .items = result.items,
                .fact_created = result.fact_created,
                .projection_nodes_imported = result.projection_nodes_imported,
                .projection_edge_created = result.projection_edge_created,
                .content_node_properties = result.content_node_properties,
                .projection_links = result.projection_links,
                .fact_properties = result.fact_properties,
                .projection_properties = result.projection_properties,
                .agent_inbox_created = result.agent_inbox_created,
            };
        }
    };
};

const agent_write_command = agent_write_command_mod.AgentWriteCommand(AgentWriteCommandOps);

const SchemaScopeCommandOps = struct {
    pub fn parseDbArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !database_arguments.Parsed {
        return parseDbArgs(allocator, io, args, 2, 1, std.math.maxInt(usize), true);
    }

    pub const ViolationCursor = struct {
        allocator: std.mem.Allocator,
        store: storage.Store,
        scope_type: []const u8,
        allowed: std.AutoHashMap(u64, void),
        iterator: storage.Store.NodeRecordIterator,
        violations: u64 = 0,
        dangling_projects: u64,

        pub fn deinit(self: *ViolationCursor) void {
            self.iterator.deinit();
            self.allowed.deinit();
            self.* = undefined;
        }

        pub fn next(self: *ViolationCursor) !?u64 {
            while (try self.iterator.next(self.allocator)) |stored_node| {
                var node = stored_node;
                defer node.deinit(self.allocator);
                if (isDeletedNodeTombstone(node)) continue;
                if (node.kind == .project) continue;
                const node_schema_type = try self.store.getNodeStringProperty(
                    self.allocator,
                    node.id,
                    "schema_type",
                );
                defer if (node_schema_type) |value| self.allocator.free(value);
                if (node_schema_type == null or
                    !std.mem.eql(u8, node_schema_type.?, self.scope_type)) continue;
                if (self.allowed.contains(node.id.toInt())) continue;
                self.violations += 1;
                return node.id.toInt();
            }
            return null;
        }

        pub fn summary(self: *const ViolationCursor) struct {
            violations: u64,
            dangling_projects: u64,
        } {
            return .{
                .violations = self.violations,
                .dangling_projects = self.dangling_projects,
            };
        }
    };

    pub const Context = struct {
        cli_lock: CliStoreLock,
        store: storage.Store,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !Context {
            var cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{ .cli_lock = cli_lock, .store = store };
        }

        pub fn deinit(self: *Context) void {
            self.store.deinit();
            self.cli_lock.deinit();
            self.* = undefined;
        }

        pub fn findExistingPolicy(
            self: *Context,
            allocator: std.mem.Allocator,
            scope_type: []const u8,
        ) !?u64 {
            const policy_text = try std.fmt.allocPrint(
                allocator,
                "schema_scope:{s}",
                .{scope_type},
            );
            defer allocator.free(policy_text);
            var existing = try self.store.lookupNodesByTextLimited(
                allocator,
                .concept,
                policy_text,
                currentGenerationLookupCandidateLimit(1),
            );
            defer {
                for (existing.items) |*node| node.deinit(allocator);
                existing.deinit(allocator);
            }
            for (existing.items) |*node| {
                if (!try nodeIsCurrentGeneration(self.store, node.id)) continue;
                return node.id.toInt();
            }
            return null;
        }

        pub fn resolveProject(
            self: *Context,
            allocator: std.mem.Allocator,
            project_spec: []const u8,
        ) !u64 {
            return resolveProjectSpec(allocator, self.store, project_spec);
        }

        pub fn upsertPolicy(
            self: *Context,
            allocator: std.mem.Allocator,
            scope_type: []const u8,
            projects_json: []const u8,
            enforce_value: []const u8,
        ) !struct { policy_id: u64, created: bool } {
            const policy_text = try std.fmt.allocPrint(
                allocator,
                "schema_scope:{s}",
                .{scope_type},
            );
            defer allocator.free(policy_text);
            var matches = try self.store.lookupNodesByTextLimited(
                allocator,
                .concept,
                policy_text,
                currentGenerationLookupCandidateLimit(1),
            );
            defer {
                for (matches.items) |*node| node.deinit(allocator);
                matches.deinit(allocator);
            }
            var policy_id: ?core.NodeId = null;
            for (matches.items) |*node| {
                if (!try nodeIsCurrentGeneration(self.store, node.id)) continue;
                policy_id = node.id;
                break;
            }
            const created = policy_id == null;
            const owner_id = policy_id orelse try self.store.addNode(.concept, policy_text);
            const owner: storage.PropertyOwner = .{ .node = owner_id };
            try self.store.setStringProperty(allocator, owner, "schema_type", "schema_scope");
            try self.store.setStringProperty(allocator, owner, "name", scope_type);
            try self.store.setStringProperty(allocator, owner, "scope_projects", projects_json);
            try self.store.setStringProperty(allocator, owner, "enforce", enforce_value);
            return .{ .policy_id = owner_id.toInt(), .created = created };
        }

        pub fn beginViolationScan(
            self: *Context,
            allocator: std.mem.Allocator,
            scope_type: []const u8,
            project_ids: []const u64,
        ) !ViolationCursor {
            var dangling_projects: u64 = 0;
            var allowed = try schemaScopeAllowedSet(
                allocator,
                self.store,
                project_ids,
                &dangling_projects,
            );
            errdefer allowed.deinit();
            const iterator = try self.store.nodeRecordsIterator(null);
            return .{
                .allocator = allocator,
                .store = self.store,
                .scope_type = scope_type,
                .allowed = allowed,
                .iterator = iterator,
                .dangling_projects = dangling_projects,
            };
        }
    };
};

const schema_scope_command = schema_scope_command_mod.SchemaScopeCommand(SchemaScopeCommandOps);

const StoreCopyCommandOps = struct {
    pub fn parseDbArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
        start: usize,
        min_rest: usize,
        max_rest: usize,
        require_existing_db: bool,
    ) !database_arguments.Parsed {
        return parseDbArgs(allocator, io, args, start, min_rest, max_rest, require_existing_db);
    }

    pub fn startTimeNs(io: std.Io) u128 {
        return monotonicNs(io);
    }

    pub fn elapsedTimeNs(io: std.Io, start_ns: u128) u128 {
        return elapsedNs(io, start_ns);
    }

    pub const BackupContext = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        db_path: []const u8,
        cli_lock: CliStoreLock,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !BackupContext {
            return .{
                .allocator = allocator,
                .io = io,
                .db_path = db_path,
                .cli_lock = try CliStoreLock.acquire(allocator, io, db_path),
            };
        }

        pub fn deinit(self: *BackupContext) void {
            self.cli_lock.deinit();
        }

        pub fn execute(self: *BackupContext, target_path: []const u8) !BackupStoreResult {
            return backupStore(self.allocator, self.io, self.db_path, target_path);
        }
    };

    pub fn restore(
        allocator: std.mem.Allocator,
        io: std.Io,
        source_path: []const u8,
        target_path: []const u8,
    ) !BackupStoreResult {
        return restoreBackup(allocator, io, source_path, target_path);
    }
};

const store_copy_commands = store_copy_commands_mod.StoreCopyCommands(StoreCopyCommandOps);

const StoreInterchangeDataPlaneOps = struct {
    pub const OutputWriter = QueryOutputWriter;
    pub const JsonlLineFileType = JsonlLineFile;
    pub const PropertyBatch = MigrationPropertyBatch;
    pub const DeferredPairs = MetaknowDeferredBasedOnSidecarPairs;
    pub const ImportTransactionExpectationType = ImportTransactionExpectation;
    pub const ImportPublicationResultType = ImportPublicationResult;
    pub const PublishLock = CliStoreLock;

    pub const anyPathExistsFn = anyPathExists;
    pub const canonicalProspectivePathFn = canonicalProspectivePath;
    pub const createOwnedDirectoryFn = createOwnedDirectory;
    pub const exportBackupPathFn = exportBackupPath;
    pub const exportTemporaryPathFn = exportTemporaryPath;
    pub const fileExistsFn = fileExists;
    pub const finalizeContentDigestFn = finalizeContentDigest;
    pub const importPublicationMatchesSourceFn = importPublicationMatchesSource;
    pub const importStagingPathFn = importStagingPath;
    pub const isDeletedNodeTombstoneFn = isDeletedNodeTombstone;
    pub const listMarkdownFilesRecursiveSortedFn = listMarkdownFilesRecursiveSorted;
    pub const loadJsonlLineFileFn = loadJsonlLineFile;
    pub const nodeKindNameAllocFn = nodeKindNameAlloc;
    pub const normalizeDeferredPairsFn = normalizeMetaknowDeferredBasedOnPairs;
    pub const parseNodeKindFn = parseCliNodeKind;
    pub const parseRelKindFn = parseCliRelKind;
    pub const pathsOverlapFn = pathsOverlap;
    pub const persistentNowNsFn = persistentNowNs;
    pub const publishExportDirectoryFn = publishExportDirectory;
    pub const publishImportedStoreFn = publishImportedStore;
    pub const readDeferredPairsFn = readMetaknowDeferredBasedOnSidecarForwardPairs;
    pub const recoverCompletedImportFn = recoverCompletedImport;
    pub const recoverExportPublicationFn = recoverExportPublication;
    pub const recoverImportStagingFn = recoverImportStaging;
    pub const relKindNameAllocFn = relKindNameAlloc;
    pub const restoreDeferredPairsFn = restoreMetaknowDeferredBasedOnSidecar;
    pub const syncExportDirectoryTreeFn = syncExportDirectoryTree;
    pub const u128ToU64Fn = u128ToU64;
    pub const updateImportDigestFn = updateImportDigest;
    pub const validateMetadataTokenFn = validateGovernanceMetadataToken;
    pub const writeExportTransactionMarkerFn = writeExportTransactionMarker;
    pub const writeImportTransactionMarkerFn = writeImportTransactionMarker;
    pub const writeJsonStringFn = writeJsonString;
    pub const writeMarkdownInlineTextFn = writeMarkdownInlineText;
    pub const writeStoreManifestFn = writeStoreManifest;
};

const store_interchange_data_plane = store_interchange_data_plane_mod.StoreInterchangeDataPlane(StoreInterchangeDataPlaneOps);
const importNativeJsonlStore = store_interchange_data_plane.importNativeJsonlStore;
const exportNativeJsonlStore = store_interchange_data_plane.exportNativeJsonlStore;
const exportNativeJsonlStoreIntoDirectory = store_interchange_data_plane.exportNativeJsonlStoreIntoDirectory;
const importMarkdownStore = store_interchange_data_plane.importMarkdownStore;
const exportMarkdownStore = store_interchange_data_plane.exportMarkdownStore;
const exportMarkdownStoreIntoDirectory = store_interchange_data_plane.exportMarkdownStoreIntoDirectory;
const parseImportedTaskLifecycle = store_interchange_data_plane.parseImportedTaskLifecycle;

const StoreInterchangeCommandOps = struct {
    const ImportResult = struct {
        nodes_loaded: usize,
        nodes_imported: usize,
        edges_loaded: usize,
        edges_imported: usize,
        deferred_based_on_loaded: usize,
        deferred_based_on_imported: usize,
        source_bytes: u64,
        text_warmed: bool,
        marker_cleanup_pending: bool,
    };

    const ExportResult = struct {
        nodes_exported: usize,
        edges_exported: usize,
        deferred_based_on_exported: usize,
        output_bytes: u64,
        cleanup_pending: bool,
    };

    pub fn parseExportArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !struct { db_path: []const u8, dir_path: []const u8 } {
        const parsed = try parseDbArgs(allocator, io, args, 2, 1, 1, true);
        return .{ .db_path = parsed.db_path, .dir_path = parsed.rest[0] };
    }

    pub const ExportSourceExclusion = struct {
        cli_lock: CliStoreLock,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            db_path: []const u8,
        ) !ExportSourceExclusion {
            return .{ .cli_lock = try CliStoreLock.acquire(allocator, io, db_path) };
        }

        pub fn deinit(self: *ExportSourceExclusion) void {
            self.cli_lock.deinit();
        }
    };

    pub fn startTimer(io: std.Io) u128 {
        return monotonicNs(io);
    }

    pub const ExportContext = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        store: storage.Store,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            db_path: []const u8,
        ) !ExportContext {
            return .{
                .allocator = allocator,
                .io = io,
                .store = try storage.Store.open(allocator, io, db_path),
            };
        }

        pub fn deinit(self: *ExportContext) void {
            self.store.deinit();
        }

        pub fn exportJsonl(self: *ExportContext, dir_path: []const u8) !ExportResult {
            const result = try exportNativeJsonlStore(self.allocator, self.io, self.store, dir_path);
            return .{
                .nodes_exported = result.nodes_exported,
                .edges_exported = result.edges_exported,
                .deferred_based_on_exported = result.deferred_based_on_exported,
                .output_bytes = result.jsonl_bytes,
                .cleanup_pending = result.cleanup_pending,
            };
        }

        pub fn exportMarkdown(self: *ExportContext, dir_path: []const u8) !ExportResult {
            const result = try exportMarkdownStore(self.allocator, self.io, self.store, dir_path);
            return .{
                .nodes_exported = result.nodes_exported,
                .edges_exported = result.edges_exported,
                .deferred_based_on_exported = result.deferred_based_on_exported,
                .output_bytes = result.markdown_bytes,
                .cleanup_pending = result.cleanup_pending,
            };
        }
    };

    pub fn importJsonl(
        allocator: std.mem.Allocator,
        io: std.Io,
        db_path: []const u8,
        dir_path: []const u8,
        warm_text: bool,
    ) !ImportResult {
        const result = try importNativeJsonlStore(allocator, io, db_path, dir_path, warm_text);
        return .{
            .nodes_loaded = result.nodes_loaded,
            .nodes_imported = result.nodes_imported,
            .edges_loaded = result.edges_loaded,
            .edges_imported = result.edges_imported,
            .deferred_based_on_loaded = result.deferred_based_on_loaded,
            .deferred_based_on_imported = result.deferred_based_on_imported,
            .source_bytes = result.jsonl_bytes,
            .text_warmed = result.text_warmed,
            .marker_cleanup_pending = result.marker_cleanup_pending,
        };
    }

    pub fn importMarkdown(
        allocator: std.mem.Allocator,
        io: std.Io,
        db_path: []const u8,
        dir_path: []const u8,
        warm_text: bool,
    ) !ImportResult {
        const result = try importMarkdownStore(allocator, io, db_path, dir_path, warm_text);
        return .{
            .nodes_loaded = result.nodes_loaded,
            .nodes_imported = result.nodes_imported,
            .edges_loaded = result.edges_loaded,
            .edges_imported = result.edges_imported,
            .deferred_based_on_loaded = result.deferred_based_on_loaded,
            .deferred_based_on_imported = result.deferred_based_on_imported,
            .source_bytes = result.markdown_bytes,
            .text_warmed = result.text_warmed,
            .marker_cleanup_pending = result.marker_cleanup_pending,
        };
    }

    pub fn elapsedSince(io: std.Io, start_ns: u128) u128 {
        return elapsedNs(io, start_ns);
    }
};

const store_interchange_commands =
    store_interchange_commands_mod.StoreInterchangeCommands(StoreInterchangeCommandOps);

const StoreInitCommandOps = struct {
    pub fn defaultPath() []const u8 {
        return defaultDbPath();
    }

    pub const Context = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        db_path: []const u8,
        store: storage.Store,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !Context {
            return .{
                .allocator = allocator,
                .io = io,
                .db_path = db_path,
                .store = try storage.Store.init(allocator, io, db_path),
            };
        }

        pub fn deinit(self: *Context) void {
            self.store.deinit();
        }

        pub fn createEmpty(self: *Context) !void {
            try self.store.createEmpty();
        }

        pub fn writeManifest(self: *Context) !void {
            try writeStoreManifest(self.allocator, self.io, self.db_path, .{
                .profiles = "",
                .migration_name = "init",
            });
        }
    };
};

const store_init_command = store_init_command_mod.StoreInitCommand(StoreInitCommandOps);

const RebuildTextCommandOps = struct {
    pub const Result = struct {
        doc_count: u64,
        total_text_tokens: u64,
        term_count: u64,
        term_bytes: u64,
        posting_count: u64,
    };

    pub fn defaultPath() []const u8 {
        return defaultDbPath();
    }

    pub fn startTimer(io: std.Io) u128 {
        return monotonicNs(io);
    }

    pub fn elapsedSince(io: std.Io, start_ns: u128) u128 {
        return elapsedNs(io, start_ns);
    }

    pub const Context = struct {
        allocator: std.mem.Allocator,
        cli_lock: CliStoreLock,
        store: storage.Store,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !Context {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{
                .allocator = allocator,
                .cli_lock = cli_lock,
                .store = store,
            };
        }

        pub fn deinit(self: *Context) void {
            self.store.deinit();
            self.cli_lock.deinit();
        }

        pub fn rebuild(self: *Context) !Result {
            const meta = try text_search.rebuildPersistentTextCatalog(self.allocator, self.store);
            return .{
                .doc_count = meta.doc_count,
                .total_text_tokens = meta.total_text_tokens,
                .term_count = meta.term_count,
                .term_bytes = meta.term_bytes,
                .posting_count = meta.posting_count,
            };
        }
    };
};

const rebuild_text_command = rebuild_text_command_mod.RebuildTextCommand(RebuildTextCommandOps);

const MigrateStoreV2CommandOps = struct {
    pub fn validateRelationships(
        allocator: std.mem.Allocator,
        io: std.Io,
        parsed: ParsedMigrateStoreV2Args,
    ) !void {
        try store_migration_v2_data_plane.validateRelationships(allocator, io, parsed);
    }

    pub const CanonicalTargetPath = struct {
        allocator: std.mem.Allocator,
        path: []u8,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            target_path: []const u8,
        ) !CanonicalTargetPath {
            return .{
                .allocator = allocator,
                .path = try canonicalProspectivePath(allocator, io, target_path),
            };
        }

        pub fn value(self: *const CanonicalTargetPath) []const u8 {
            return self.path;
        }

        pub fn deinit(self: *CanonicalTargetPath) void {
            self.allocator.free(self.path);
        }
    };

    pub const SourceExclusion = struct {
        cli_lock: CliStoreLock,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            source_path: []const u8,
        ) !SourceExclusion {
            return .{ .cli_lock = try CliStoreLock.acquire(allocator, io, source_path) };
        }

        pub fn deinit(self: *SourceExclusion) void {
            self.cli_lock.deinit();
        }
    };

    pub const TargetExclusion = struct {
        cli_lock: CliStoreLock,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            canonical_target_path: []const u8,
        ) !TargetExclusion {
            return .{
                .cli_lock = try CliStoreLock.acquireAdjacent(
                    allocator,
                    io,
                    canonical_target_path,
                    store_migration_publish_lock_suffix,
                ),
            };
        }

        pub fn deinit(self: *TargetExclusion) void {
            self.cli_lock.deinit();
        }
    };

    pub fn startTimer(io: std.Io) u128 {
        return monotonicNs(io);
    }

    pub fn execute(
        allocator: std.mem.Allocator,
        io: std.Io,
        parsed: ParsedMigrateStoreV2Args,
    ) !StoreMigrationV2Result {
        return executeStoreMigrationV2DataPlane(allocator, io, parsed);
    }

    pub fn elapsedSince(io: std.Io, start_ns: u128) u128 {
        return elapsedNs(io, start_ns);
    }
};

const migrate_store_v2_command =
    migrate_store_v2_command_mod.MigrateStoreV2Command(MigrateStoreV2CommandOps);

const StoreUpgradeCommandOps = struct {
    pub const currentStoreManifestVersionValue = current_store_manifest_version;
    pub const currentStorageFormatVersionValue = current_storage_format_version;
    pub const currentSchemaVersionValue = current_schema_version;

    pub const Session = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        parsed: store_upgrade_command_mod.Arguments,
        canonical_target_path: ?[]u8,
        source_lock: CliStoreLock,
        source_store: ?storage.Store,

        fn migrationArguments(self: *const Session, options: anytype) !ParsedMigrateStoreV2Args {
            return .{
                .source_path = self.parsed.source_path,
                .target_path = self.parsed.target_path orelse return error.MissingArgument,
                .backup_path = self.parsed.backup_path,
                .warm_text = self.parsed.warm_text,
                .verify = options.verify,
                .dry_run = self.parsed.dry_run,
                .strict = options.strict,
                .task_status_v1 = options.task_status_v1,
            };
        }

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            parsed: store_upgrade_command_mod.Arguments,
        ) !Session {
            var canonical_target_path: ?[]u8 = null;
            errdefer if (canonical_target_path) |path| allocator.free(path);
            if (parsed.target_path != null) {
                const provisional = ParsedMigrateStoreV2Args{
                    .source_path = parsed.source_path,
                    .target_path = parsed.target_path.?,
                    .backup_path = parsed.backup_path,
                    .warm_text = parsed.warm_text,
                    .verify = true,
                    .dry_run = parsed.dry_run,
                    .strict = true,
                    .task_status_v1 = true,
                };
                try store_migration_v2_data_plane.validateRelationships(allocator, io, provisional);
                canonical_target_path = try canonicalProspectivePath(allocator, io, parsed.target_path.?);
            }

            const source_lock = try CliStoreLock.acquire(allocator, io, parsed.source_path);
            errdefer source_lock.deinit();
            const source_store = try storage.Store.open(allocator, io, parsed.source_path);
            return .{
                .allocator = allocator,
                .io = io,
                .parsed = parsed,
                .canonical_target_path = canonical_target_path,
                .source_lock = source_lock,
                .source_store = source_store,
            };
        }

        pub fn deinit(self: *Session) void {
            if (self.source_store) |*store_value| store_value.deinit();
            self.source_store = null;
            self.source_lock.deinit();
            if (self.canonical_target_path) |path| self.allocator.free(path);
            self.canonical_target_path = null;
        }

        pub fn detect(self: *Session) !store_upgrade_command_mod.DetectedVersion {
            const store_value = self.source_store orelse return error.InvalidRecord;
            var decoded_catalog = try store_value.readCatalog();
            defer if (decoded_catalog) |*catalog_value| catalog_value.deinit();
            var catalog_format_version: ?u16 = null;
            if (decoded_catalog) |catalog_value| catalog_format_version = catalog_value.format_version;
            const manifest = try readStoreManifestSummary(self.allocator, self.io, self.parsed.source_path);
            defer manifest.deinit(self.allocator);
            if (std.mem.eql(u8, manifest.status, "legacy")) return .{ .legacy = .{
                .catalog_format_version = catalog_format_version,
            } };
            if (!std.mem.eql(u8, manifest.status, "present")) return error.InvalidStoreManifest;
            const manifest_version = std.fmt.parseInt(u32, manifest.store_manifest_version, 10) catch return error.InvalidStoreManifest;
            const storage_version = std.fmt.parseInt(u32, manifest.storage_format_version, 10) catch return error.InvalidStoreManifest;
            const schema_version_value = std.fmt.parseInt(u32, manifest.schema_version, 10) catch return error.InvalidStoreManifest;
            const catalog_compatible = if (decoded_catalog) |catalog_value| compatible: {
                if (!catalogProfilesMatchCsv(catalog_value, manifest.enabled_profiles)) break :compatible false;
                if (schema_version_value >= 3 and
                    catalog_value.registry.nodeTypeNameById(@intFromEnum(core.NodeKind.task)) != null and
                    catalog_value.registry.nodePropertyByTypeId(@intFromEnum(core.NodeKind.task), task.status_property) == null)
                {
                    break :compatible false;
                }
                break :compatible true;
            } else false;
            return .{ .manifest = .{
                .store_manifest_version = manifest_version,
                .storage_format_version = storage_version,
                .schema_version = schema_version_value,
                .catalog_format_version = catalog_format_version,
                .catalog_compatible = catalog_compatible,
            } };
        }

        pub fn migrate(self: *Session, options: anytype) !StoreMigrationV2Result {
            const parsed = try self.migrationArguments(options);
            if (self.source_store) |*store_value| store_value.deinit();
            self.source_store = null;

            try store_migration_v2_data_plane.validateRelationships(self.allocator, self.io, parsed);
            const canonical_target_path = self.canonical_target_path orelse return error.InvalidRecord;
            const target_lock = try CliStoreLock.acquireAdjacent(
                self.allocator,
                self.io,
                canonical_target_path,
                store_migration_publish_lock_suffix,
            );
            defer target_lock.deinit();
            return executeStoreMigrationV2DataPlane(self.allocator, self.io, parsed);
        }
    };
};

const store_upgrade_command =
    store_upgrade_command_mod.StoreUpgradeCommand(StoreUpgradeCommandOps);

const StoreInspectionCommandOps = struct {
    pub fn parseDbPath(args: []const []const u8, index: usize) ![]const u8 {
        return parseOptionalDbPath(args, index);
    }

    pub const Context = struct {
        cli_lock: CliStoreLock,
        store: storage.Store,
        io: std.Io,
        db_path: []const u8,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !Context {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{
                .cli_lock = cli_lock,
                .store = store,
                .io = io,
                .db_path = db_path,
            };
        }

        pub fn deinit(self: *Context) void {
            self.store.deinit();
            self.cli_lock.deinit();
        }

        pub fn stats(self: *Context) !struct { nodes: u64, edges: u64 } {
            const value = try self.store.stats();
            return .{ .nodes = value.nodes, .edges = value.edges };
        }

        pub fn storeBytes(self: *Context, allocator: std.mem.Allocator) !u64 {
            return storeDirBytes(allocator, self.io, self.db_path);
        }

        pub fn textFileSize(
            self: *Context,
            allocator: std.mem.Allocator,
            file_name: []const u8,
        ) !?u64 {
            return storeFileSize(allocator, self.io, self.db_path, file_name);
        }

        pub fn textCatalogQuickStale(self: *Context, allocator: std.mem.Allocator) !bool {
            return text_search.persistentTextCatalogQuickStale(allocator, self.store);
        }

        pub fn readManifest(self: *Context, allocator: std.mem.Allocator) !StoreManifestSummary {
            return readStoreManifestSummary(allocator, self.io, self.db_path);
        }

        pub fn deinitManifest(
            _: *Context,
            allocator: std.mem.Allocator,
            manifest: *StoreManifestSummary,
        ) void {
            manifest.*.deinit(allocator);
        }
    };
};

const store_inspection_commands = store_inspection_commands_mod.StoreInspectionCommands(StoreInspectionCommandOps);

const ContextCommandOps = struct {
    pub const Arguments = ParsedContextArgs;

    pub fn parseArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !Arguments {
        return parseContextArgs(allocator, io, args);
    }

    pub fn deinitArguments(allocator: std.mem.Allocator, parsed: Arguments) void {
        parsed.deinit(allocator);
    }

    pub const PlanContext = struct {
        cli_lock: CliStoreLock,
        store: storage.Store,
        io: std.Io,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            db_path: []const u8,
        ) !PlanContext {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{ .cli_lock = cli_lock, .store = store, .io = io };
        }

        pub fn deinit(self: *PlanContext) void {
            self.store.deinit();
            self.cli_lock.deinit();
        }

        pub fn repair(self: *PlanContext) !void {
            try self.store.repairPersistentIndexesFromLog();
        }

        pub fn render(
            self: *PlanContext,
            allocator: std.mem.Allocator,
            parsed: Arguments,
        ) ![]u8 {
            return renderContextPlanJsonOutput(allocator, self.io, self.store, parsed);
        }
    };

    pub const PacketContext = struct {
        cli_lock: CliStoreLock,
        store: storage.Store,
        edge_retention_registry: storage.EdgeSegmentRetentionRegistry,
        io: std.Io,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            db_path: []const u8,
        ) !PacketContext {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{
                .cli_lock = cli_lock,
                .store = store,
                .edge_retention_registry = storage.EdgeSegmentRetentionRegistry.init(allocator),
                .io = io,
            };
        }

        pub fn deinit(self: *PacketContext) void {
            self.edge_retention_registry.deinit();
            self.store.deinit();
            self.cli_lock.deinit();
        }

        pub fn repair(self: *PacketContext) !void {
            try self.store.repairPersistentIndexesFromLog();
        }

        pub fn render(
            self: *PacketContext,
            allocator: std.mem.Allocator,
            parsed: Arguments,
        ) ![]u8 {
            return renderContextPacketJsonOutput(
                allocator,
                self.io,
                self.store,
                &self.edge_retention_registry,
                parsed,
            );
        }
    };
};

const context_commands = context_commands_mod.ContextCommands(ContextCommandOps);

const NodeReadCommandOps = struct {
    pub const NodeId = core.NodeId;

    pub fn maxResults() usize {
        return (core.QueryBudget{}).max_results;
    }

    pub fn parseDbArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
        min_rest: usize,
        max_rest: usize,
    ) !struct { db_path: []const u8, rest: []const []const u8 } {
        const parsed = try parseDbArgs(allocator, io, args, 2, min_rest, max_rest, true);
        return .{ .db_path = parsed.db_path, .rest = parsed.rest };
    }

    pub fn parseNodeId(value: []const u8) !NodeId {
        return parseNodeIdArg(value);
    }

    pub const Context = struct {
        cli_lock: CliStoreLock,
        store: storage.Store,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !Context {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{ .cli_lock = cli_lock, .store = store };
        }

        pub fn deinit(self: *Context) void {
            self.store.deinit();
            self.cli_lock.deinit();
        }

        pub fn repair(self: *Context) !void {
            try self.store.repairPersistentIndexesFromLog();
        }

        pub fn renderGet(
            self: *Context,
            allocator: std.mem.Allocator,
            node_id: NodeId,
            parsed: anytype,
        ) ![]u8 {
            return renderNodeByIdOutput(allocator, self.store, node_id, .{
                .format = switch (parsed.format) {
                    .text => .text,
                    .json => .json,
                },
                .meta = parsed.meta,
                .include_text = parsed.include_text,
            });
        }

        pub fn renderVersions(
            self: *Context,
            allocator: std.mem.Allocator,
            node_id: NodeId,
            limit: usize,
        ) ![]u8 {
            return renderNodeVersionsOutput(allocator, self.store, node_id, limit);
        }

        pub fn renderLatest(
            self: *Context,
            allocator: std.mem.Allocator,
            node_id: NodeId,
            limit: usize,
        ) ![]u8 {
            return renderNodeLatestOutput(allocator, self.store, node_id, limit);
        }
    };
};

const node_read_commands = node_read_commands_mod.NodeReadCommands(NodeReadCommandOps);

const RecentCommandOps = struct {
    pub const NodeKind = core.NodeKind;

    pub fn maxResults() usize {
        return (core.QueryBudget{}).max_results;
    }

    pub fn parseDbArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
        min_rest: usize,
        max_rest: usize,
    ) !struct { db_path: []const u8, rest: []const []const u8 } {
        const parsed = try parseDbArgs(allocator, io, args, 2, min_rest, max_rest, true);
        return .{ .db_path = parsed.db_path, .rest = parsed.rest };
    }

    pub fn parseNodeKind(value: []const u8) ?NodeKind {
        return parseCliNodeKind(value);
    }

    pub const Context = struct {
        cli_lock: CliStoreLock,
        store: storage.Store,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !Context {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{ .cli_lock = cli_lock, .store = store };
        }

        pub fn deinit(self: *Context) void {
            self.store.deinit();
            self.cli_lock.deinit();
            self.* = undefined;
        }

        pub fn repair(self: *Context) !void {
            try self.store.repairPersistentIndexesFromLog();
        }

        pub fn render(
            self: *Context,
            allocator: std.mem.Allocator,
            project: ?[]const u8,
            kind_filter: ?NodeKind,
            limit: usize,
            with_type: bool,
        ) ![]u8 {
            return renderListRecentOutput(allocator, self.store, project, kind_filter, limit, with_type);
        }
    };
};

const recent_commands = recent_commands_mod.RecentCommands(RecentCommandOps);

const FindCommandOps = struct {
    pub const NodeKind = core.NodeKind;
    pub const Match = storage.StoredNode;

    pub fn parseDbArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !struct { db_path: []const u8, rest: []const []const u8 } {
        const parsed = try parseDbArgs(allocator, io, args, 2, 2, 5, true);
        return .{ .db_path = parsed.db_path, .rest = parsed.rest };
    }

    pub const Context = struct {
        cli_lock: CliStoreLock,
        store: storage.Store,
        effective_schema: EffectiveSchemaRegistry,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            db_path: []const u8,
            schema_path: ?[]const u8,
        ) !Context {
            var cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            var store = try storage.Store.open(allocator, io, db_path);
            errdefer store.deinit();
            const effective_schema = try loadEffectiveSchemaRegistry(allocator, io, store, schema_path);
            return .{
                .cli_lock = cli_lock,
                .store = store,
                .effective_schema = effective_schema,
            };
        }

        pub fn deinit(self: *Context) void {
            self.effective_schema.deinit();
            self.store.deinit();
            self.cli_lock.deinit();
            self.* = undefined;
        }

        pub fn parseNodeKind(self: *Context, label: []const u8) !NodeKind {
            return parseNodeKindWithSchemaPolicy(
                label,
                self.effective_schema.registry,
                self.effective_schema.enforce_application_schema,
            );
        }

        pub fn lookup(
            self: *Context,
            allocator: std.mem.Allocator,
            kind: NodeKind,
            text: []const u8,
            include_history: bool,
        ) !?Match {
            const candidate_limit = if (include_history)
                @as(usize, 1)
            else
                currentGenerationLookupCandidateLimit(1);
            var matches = try self.store.lookupNodesByTextLimited(
                allocator,
                kind,
                text,
                candidate_limit,
            );
            defer {
                for (matches.items) |*node| node.deinit(allocator);
                matches.deinit(allocator);
            }
            var index: usize = 0;
            while (index < matches.items.len) : (index += 1) {
                const node = &matches.items[index];
                if (!include_history and !try nodeIsCurrentGeneration(self.store, node.id)) continue;
                return matches.orderedRemove(index);
            }
            return null;
        }

        pub fn repair(self: *Context) !void {
            try self.store.repairPersistentIndexesFromLog();
        }

        pub fn writeFound(self: *Context, writer: anytype, match: *const Match) !void {
            try writer.print("{}\t", .{match.id.toInt()});
            try writeNodeKindNameWithSchema(writer, self.effective_schema.registry, match.kind);
            try writer.writeAll("\t");
            try writeEscapedText(writer, match.text);
            try writer.writeAll("\n");
        }
    };
};

const find_command = find_command_mod.FindCommand(FindCommandOps);

const SearchCommandOps = struct {
    pub const NodeKind = core.NodeKind;
    pub const Profile = TextBudgetProfile;
    pub const OutputFormat = CliOutputFormat;

    pub fn parseFreeTextDbArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !database_arguments.ParsedFreeText {
        return parseFreeTextDbArgs(allocator, io, args, 2, 1);
    }

    pub fn joinArguments(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
        return joinArgs(allocator, parts);
    }

    pub fn parseNodeKind(value: []const u8) ?NodeKind {
        return parseCliNodeKind(value);
    }

    pub fn maxResultsDefault() usize {
        return 20;
    }

    pub fn maxResults() usize {
        return (core.QueryBudget{}).max_results;
    }

    pub fn defaultMaxPostings() usize {
        return (core.QueryBudget{}).max_text_postings_scanned;
    }

    pub fn defaultTimeoutMs() u64 {
        return (core.QueryBudget{}).timeout_ms;
    }

    pub fn maxCliPostings() usize {
        return max_cli_text_postings_scanned;
    }

    pub fn maxCliTimeoutMs() u64 {
        return max_cli_text_timeout_ms;
    }

    pub fn agentMemoryMaxPostings() usize {
        return agent_memory_text_postings_scanned;
    }

    pub fn agentMemoryTimeoutMs() u64 {
        return agent_memory_text_timeout_ms;
    }

    pub const Context = struct {
        cli_lock: CliStoreLock,
        store: storage.Store,
        member_set: ?std.AutoHashMap(u64, void) = null,
        filter_diag: MemberFilterDiag = .{},
        search_options: ?text_search.TextSearchOptions = null,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !Context {
            var cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{ .cli_lock = cli_lock, .store = store };
        }

        pub fn deinit(self: *Context) void {
            if (self.member_set) |*member_set| member_set.deinit();
            self.store.deinit();
            self.cli_lock.deinit();
            self.* = undefined;
        }

        pub fn prepare(
            self: *Context,
            allocator: std.mem.Allocator,
            io: std.Io,
            parsed: anytype,
        ) !void {
            self.member_set = try buildSearchMemberSet(
                allocator,
                self.store,
                parsed.project,
                parsed.schema_type,
                &self.filter_diag,
            );
            self.search_options = .{
                .kind_filter = parsed.kind_filter,
                .member_filter = if (self.member_set) |*member_set| member_set else null,
                .limit = searchCandidateLimit(
                    parsed.profile,
                    parsed.kind_filter,
                    parsed.limit,
                    parsed.include_history,
                ),
                .max_postings_scanned = parsed.max_postings_scanned,
                .deadline = core.QueryDeadline.fromIo(io, parsed.timeout_ms),
            };
        }

        pub fn render(
            self: *Context,
            allocator: std.mem.Allocator,
            parsed: anytype,
        ) ![]u8 {
            const search_options = self.search_options orelse return error.InvalidPlan;
            if (parsed.format == .json) {
                return renderSearchJsonOutput(
                    allocator,
                    self.store,
                    parsed.query,
                    search_options,
                    parsed.profile,
                    parsed.limit,
                    parsed.include_history,
                    parsed.include_text,
                    parsed.timeout_ms,
                    self.filter_diag,
                );
            }
            return renderSearchOutput(
                allocator,
                self.store,
                parsed.query,
                search_options,
                parsed.profile,
                parsed.limit,
                parsed.include_history,
                self.filter_diag,
            );
        }

        pub fn repair(self: *Context) !void {
            try self.store.repairPersistentIndexesFromLog();
        }
    };
};

const search_command = search_command_mod.SearchCommand(SearchCommandOps);
const parseSearchArgs = search_command.parseArguments;

const QueryCommandOps = struct {
    pub const Profile = TextBudgetProfile;
    pub const Syntax = ql.ast.Query;

    pub fn parseFreeTextDbArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !database_arguments.ParsedFreeText {
        return parseFreeTextDbArgs(allocator, io, args, 2, 1);
    }

    pub fn joinArguments(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
        return joinArgs(allocator, parts);
    }

    pub fn defaultMaxPostings() usize {
        return (core.QueryBudget{}).max_text_postings_scanned;
    }

    pub fn defaultTimeoutMs() u64 {
        return (core.QueryBudget{}).timeout_ms;
    }

    pub fn maxCliPostings() usize {
        return max_cli_text_postings_scanned;
    }

    pub fn maxCliTimeoutMs() u64 {
        return max_cli_text_timeout_ms;
    }

    pub fn agentMemoryMaxPostings() usize {
        return agent_memory_text_postings_scanned;
    }

    pub fn agentMemoryTimeoutMs() u64 {
        return agent_memory_text_timeout_ms;
    }

    pub fn parseSyntax(allocator: std.mem.Allocator, query_text: []const u8) !Syntax {
        return ql.parser.parse(allocator, query_text);
    }

    pub fn deinitSyntax(allocator: std.mem.Allocator, syntax: Syntax) void {
        ql.ast.freeQuery(allocator, syntax);
    }

    pub const Context = struct {
        allocator: std.mem.Allocator,
        cli_lock: CliStoreLock,
        store: storage.Store,
        loaded_schema: ?schema.Registry,
        embedded_catalog: ?catalog_mod.Catalog,
        type_env: ql.typecheck.TypeEnv,
        logical: ql.planner.LogicalPlan,
        physical: ql.optimizer.PhysicalPlan,
        edge_retention_registry: storage.EdgeSegmentRetentionRegistry,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            db_path: []const u8,
            schema_path: ?[]const u8,
            syntax: Syntax,
        ) !Context {
            var cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            var store = try storage.Store.open(allocator, io, db_path);
            errdefer store.deinit();

            var loaded_schema: ?schema.Registry = if (schema_path) |path|
                try loadSchemaRegistryFile(allocator, io, path)
            else
                null;
            errdefer if (loaded_schema) |*registry| registry.deinit();
            var embedded_catalog: ?catalog_mod.Catalog = if (loaded_schema == null)
                try store.readCatalog()
            else
                null;
            errdefer if (embedded_catalog) |*cat| cat.deinit();
            const query_registry: ?schema.Registry = if (loaded_schema) |registry|
                registry
            else if (embedded_catalog) |cat|
                if (queryCatalogCoversSchemaReferences(cat.registry, syntax)) cat.registry else null
            else
                null;

            var type_env = if (query_registry) |registry|
                try ql.typecheck.checkWithSchema(allocator, syntax, registry)
            else
                try ql.typecheck.check(allocator, syntax);
            errdefer type_env.deinit(allocator);
            var logical = if (query_registry) |registry|
                try ql.planner.planWithSchema(allocator, syntax, registry)
            else
                try ql.planner.plan(allocator, syntax);
            errdefer logical.deinit(allocator);
            var physical = try ql.optimizer.optimize(allocator, logical);
            errdefer physical.deinit(allocator);

            return .{
                .allocator = allocator,
                .cli_lock = cli_lock,
                .store = store,
                .loaded_schema = loaded_schema,
                .embedded_catalog = embedded_catalog,
                .type_env = type_env,
                .logical = logical,
                .physical = physical,
                .edge_retention_registry = storage.EdgeSegmentRetentionRegistry.init(allocator),
            };
        }

        pub fn deinit(self: *Context) void {
            self.edge_retention_registry.deinit();
            self.physical.deinit(self.allocator);
            self.logical.deinit(self.allocator);
            self.type_env.deinit(self.allocator);
            if (self.embedded_catalog) |*cat| cat.deinit();
            if (self.loaded_schema) |*registry| registry.deinit();
            self.store.deinit();
            self.cli_lock.deinit();
            self.* = undefined;
        }

        pub fn render(
            self: *Context,
            allocator: std.mem.Allocator,
            max_postings_scanned: usize,
            timeout_ms: u64,
            explain: bool,
        ) ![]u8 {
            return renderPersistentQueryOutputRetained(
                allocator,
                self.store.io,
                self.store,
                &self.edge_retention_registry,
                self.physical,
                explain,
                .{
                    .max_text_postings_scanned = max_postings_scanned,
                    .timeout_ms = timeout_ms,
                },
            );
        }

        pub fn repair(self: *Context) !void {
            try self.store.repairPersistentIndexesFromLog();
        }
    };
};

const query_command = query_command_mod.QueryCommand(QueryCommandOps);
const parseQueryArgs = query_command.parseArguments;

const IdempotentNodeCommandOps = struct {
    pub const Result = struct {
        node_id: u64,
        created: bool,
    };

    pub const PreparedEnsureNode = struct {
        db_path: []const u8,
        add_args: ParsedAddNodeArgs,
        governance_args: ParsedNodeTextGovernanceArgs,
        node_text: []const u8,
        owns_node_text: bool,

        pub fn deinit(self: *PreparedEnsureNode, allocator: std.mem.Allocator) void {
            if (self.owns_node_text) allocator.free(self.node_text);
        }
    };

    pub const PreparedEnsureAnchor = struct {
        db_path: []const u8,
        project_id: core.NodeId,
        anchor: AnchorType,

        pub fn deinit(_: *PreparedEnsureAnchor, _: std.mem.Allocator) void {}
    };

    pub fn prepareEnsureNode(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !PreparedEnsureNode {
        const parsed = try parseDbArgs(allocator, io, args, 2, 2, std.math.maxInt(usize), true);
        const add_args = try parseAddNodeArgs(parsed.rest);
        // The identity lookup uses the literal input text. Options which alter
        // visible text would make every retry create another node.
        if (add_args.name != null or add_args.summary != null or add_args.retrieval_hints != null) return error.Unsupported;
        const governance_args = ParsedNodeTextGovernanceArgs{
            .kind_label = add_args.kind_label,
            .text = add_args.text,
            .schema_type = add_args.schema_type,
            .recorded_ns = persistentNowNs(io),
        };
        try validateNodeWriteGranularity(governance_args);
        const node_text = try nodeVisibleTextFromGovernanceArgs(allocator, governance_args);
        return .{
            .db_path = parsed.db_path,
            .add_args = add_args,
            .governance_args = governance_args,
            .node_text = node_text,
            .owns_node_text = node_text.ptr != add_args.text.ptr,
        };
    }

    pub fn prepareEnsureAnchor(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !PreparedEnsureAnchor {
        const parsed = try parseDbArgs(allocator, io, args, 2, 2, 2, true);
        return .{
            .db_path = parsed.db_path,
            .project_id = try parseNodeIdArg(parsed.rest[0]),
            .anchor = parseAnchorType(parsed.rest[1]) orelse return error.InvalidArgument,
        };
    }

    pub const Context = struct {
        cli_lock: CliStoreLock,
        store: storage.Store,
        io: std.Io,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !Context {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{ .cli_lock = cli_lock, .store = store, .io = io };
        }

        pub fn deinit(self: *Context) void {
            self.store.deinit();
            self.cli_lock.deinit();
        }

        pub fn ensureNode(
            self: *Context,
            allocator: std.mem.Allocator,
            prepared: *const PreparedEnsureNode,
        ) !Result {
            var effective_schema = try loadEffectiveSchemaRegistry(
                allocator,
                self.io,
                self.store,
                prepared.add_args.schema_path,
            );
            defer effective_schema.deinit();
            const kind = try parseNodeKindWithSchemaPolicy(
                prepared.add_args.kind_label,
                effective_schema.registry,
                effective_schema.enforce_application_schema,
            );
            const candidate_limit = currentGenerationLookupCandidateLimit(1);
            var matches = self.store.lookupNodesByTextLimited(
                allocator,
                kind,
                prepared.add_args.text,
                candidate_limit,
            ) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => retry: {
                    try self.store.repairPersistentIndexesFromLog();
                    break :retry try self.store.lookupNodesByTextLimited(
                        allocator,
                        kind,
                        prepared.add_args.text,
                        candidate_limit,
                    );
                },
                else => |e| return e,
            };
            defer {
                for (matches.items) |*node| node.deinit(allocator);
                matches.deinit(allocator);
            }
            for (matches.items) |*node| {
                if (!try nodeIsCurrentGeneration(self.store, node.id)) continue;
                if (node.kind == .task) try ensureTaskStatusProperty(allocator, self.store, node.id);
                return .{ .node_id = node.id.toInt(), .created = false };
            }
            const id = try self.store.addNode(kind, prepared.node_text);
            try applyNodeGovernanceProperties(
                allocator,
                self.store,
                id,
                prepared.governance_args,
                null,
            );
            if (kind == .task) try ensureTaskStatusProperty(allocator, self.store, id);
            return .{ .node_id = id.toInt(), .created = true };
        }

        pub fn ensureAnchor(
            self: *Context,
            allocator: std.mem.Allocator,
            prepared: *const PreparedEnsureAnchor,
        ) !Result {
            var project = (try self.store.readNodeById(allocator, prepared.project_id)) orelse return core.Error.NotFound;
            defer project.deinit(allocator);
            if (project.kind != .project) return core.Error.InvalidId;

            var children = try collectContainChildIds(allocator, self.store, prepared.project_id);
            defer children.deinit(allocator);
            for (children.items) |child_id| {
                const id = core.NodeId.fromInt(child_id);
                const schema_type = try self.store.getNodeStringProperty(allocator, id, "schema_type");
                defer if (schema_type) |value| allocator.free(value);
                if (schema_type != null and std.mem.eql(u8, schema_type.?, prepared.anchor.schemaType())) {
                    if (prepared.anchor.nodeKind() == .task) try ensureTaskStatusProperty(allocator, self.store, id);
                    return .{ .node_id = child_id, .created = false };
                }
            }

            // This remains the established non-transactional crash window:
            // addNode -> schema_type/status properties -> contain edge.
            const id = try self.store.addNode(prepared.anchor.nodeKind(), prepared.anchor.defaultText());
            try self.store.setNodeStringProperty(allocator, id, "schema_type", prepared.anchor.schemaType());
            if (prepared.anchor.nodeKind() == .task) try ensureTaskStatusProperty(allocator, self.store, id);
            _ = try dag.addEdgeCheckedWithPersistentStore(
                allocator,
                self.store,
                prepared.project_id,
                .contain,
                id,
                .{},
            );
            return .{ .node_id = id.toInt(), .created = true };
        }
    };
};

const idempotent_node_commands = idempotent_node_commands_mod.IdempotentNodeCommands(IdempotentNodeCommandOps);

const NodeMutationCommandOps = struct {
    pub const PreparedAdd = struct {
        db_path: []const u8,
        add_args: ParsedAddNodeArgs,
        governance_args: ParsedNodeTextGovernanceArgs,
        node_text: []const u8,
        owns_node_text: bool,

        pub fn deinit(self: *PreparedAdd, allocator: std.mem.Allocator) void {
            if (self.owns_node_text) allocator.free(self.node_text);
        }
    };

    pub const PreparedUpdate = struct {
        db_path: []const u8,
        update_args: ParsedUpdateNodeArgs,
        node_id: core.NodeId,

        pub fn deinit(_: *PreparedUpdate, _: std.mem.Allocator) void {}
    };

    pub const PreparedAppendVersion = struct {
        db_path: []const u8,
        update_args: ParsedUpdateNodeArgs,
        old_node_id: core.NodeId,
        governance_args: ParsedNodeTextGovernanceArgs,
        node_text: []const u8,
        owns_node_text: bool,

        pub fn deinit(self: *PreparedAppendVersion, allocator: std.mem.Allocator) void {
            if (self.owns_node_text) allocator.free(self.node_text);
        }
    };

    pub const PreparedGovern = struct {
        db_path: []const u8,
        govern_args: ParsedGovernNodeArgs,
        node_id: core.NodeId,

        pub fn deinit(_: *PreparedGovern, _: std.mem.Allocator) void {}
    };

    pub const PreparedDelete = struct {
        db_path: []const u8,
        node_id: core.NodeId,

        pub fn deinit(_: *PreparedDelete, _: std.mem.Allocator) void {}
    };

    pub const UpdateResult = union(enum) {
        rewritten: struct {
            node_id: u64,
            store_bytes_before: u64,
            nodes_rewritten: usize,
            edges_rewritten: usize,
            edges_removed: usize,
        },
        versioned: struct {
            old_node_id: u64,
            new_node_id: u64,
            edge_id: u64,
            store_bytes_before: u64,
        },
    };

    pub const DeleteResult = union(enum) {
        rejected_children: u64,
        deleted: struct {
            node_id: u64,
            store_bytes_before: u64,
            nodes_rewritten: usize,
            edges_rewritten: usize,
            edges_removed: usize,
        },
    };

    pub fn prepareAdd(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !PreparedAdd {
        const parsed = try parseDbArgs(allocator, io, args, 2, 2, std.math.maxInt(usize), true);
        const add_args = try governed_node_write_admission.parseAddNodeArgs(parsed.rest);
        const governance_args = ParsedNodeTextGovernanceArgs{
            .kind_label = add_args.kind_label,
            .text = add_args.text,
            .schema_type = add_args.schema_type,
            .name = add_args.name,
            .summary = add_args.summary,
            .retrieval_hints = add_args.retrieval_hints,
            .recorded_ns = persistentNowNs(io),
        };
        try validateNodeWriteGranularity(governance_args);
        const node_text = try nodeVisibleTextFromGovernanceArgs(allocator, governance_args);
        return .{
            .db_path = parsed.db_path,
            .add_args = add_args,
            .governance_args = governance_args,
            .node_text = node_text,
            .owns_node_text = node_text.ptr != add_args.text.ptr,
        };
    }

    pub fn prepareUpdate(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !PreparedUpdate {
        const parsed = try parseDbArgs(allocator, io, args, 2, 3, std.math.maxInt(usize), true);
        const update_args = try parseUpdateNodeArgs(parsed.rest);
        return .{
            .db_path = parsed.db_path,
            .update_args = update_args,
            .node_id = try parseNodeIdArg(update_args.node_id),
        };
    }

    pub fn prepareAppendVersion(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !PreparedAppendVersion {
        const parsed = try parseDbArgs(allocator, io, args, 2, 3, std.math.maxInt(usize), true);
        const update_args = try parseUpdateNodeArgs(parsed.rest);
        const old_node_id = try parseNodeIdArg(update_args.node_id);
        const governance_args = ParsedNodeTextGovernanceArgs{
            .kind_label = update_args.kind_label,
            .text = update_args.text,
            .schema_type = update_args.schema_type,
            .name = update_args.name,
            .summary = update_args.summary,
            .retrieval_hints = update_args.retrieval_hints,
            .recorded_ns = persistentNowNs(io),
        };
        try validateNodeWriteGranularity(governance_args);
        const node_text = try nodeVisibleTextFromGovernanceArgs(allocator, governance_args);
        return .{
            .db_path = parsed.db_path,
            .update_args = update_args,
            .old_node_id = old_node_id,
            .governance_args = governance_args,
            .node_text = node_text,
            .owns_node_text = node_text.ptr != update_args.text.ptr,
        };
    }

    pub fn prepareGovern(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !PreparedGovern {
        const parsed = try parseDbArgs(allocator, io, args, 2, 1, std.math.maxInt(usize), true);
        const govern_args = try parseGovernNodeArgs(parsed.rest);
        return .{
            .db_path = parsed.db_path,
            .govern_args = govern_args,
            .node_id = try parseNodeIdArg(govern_args.node_id),
        };
    }

    pub fn prepareDelete(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !PreparedDelete {
        const parsed = try parseDbArgs(allocator, io, args, 2, 1, 1, true);
        return .{
            .db_path = parsed.db_path,
            .node_id = try parseNodeIdArg(parsed.rest[0]),
        };
    }

    pub const Context = struct {
        cli_lock: CliStoreLock,
        store: storage.Store,
        db_path: []const u8,
        io: std.Io,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            db_path: []const u8,
        ) !Context {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{ .cli_lock = cli_lock, .store = store, .db_path = db_path, .io = io };
        }

        pub fn deinit(self: *Context) void {
            self.store.deinit();
            self.cli_lock.deinit();
        }

        pub fn add(
            self: *Context,
            allocator: std.mem.Allocator,
            prepared: *const PreparedAdd,
        ) !struct { node_id: u64 } {
            var effective_schema = try loadEffectiveSchemaRegistry(allocator, self.io, self.store, prepared.add_args.schema_path);
            defer effective_schema.deinit();
            const kind = try parseNodeKindWithSchemaPolicy(
                prepared.add_args.kind_label,
                effective_schema.registry,
                effective_schema.enforce_application_schema,
            );
            const id = try self.store.addNode(kind, prepared.node_text);
            try applyNodeGovernanceProperties(allocator, self.store, id, prepared.governance_args, null);
            if (kind == .task) try ensureTaskStatusProperty(allocator, self.store, id);
            return .{ .node_id = id.toInt() };
        }

        pub fn update(
            self: *Context,
            allocator: std.mem.Allocator,
            prepared: *const PreparedUpdate,
        ) !UpdateResult {
            const update_args = prepared.update_args;
            const node_id = prepared.node_id;
            var effective_schema = try loadEffectiveSchemaRegistry(allocator, self.io, self.store, update_args.schema_path);
            defer effective_schema.deinit();
            const requested_kind = try parseNodeKindWithSchemaPolicy(
                update_args.kind_label,
                effective_schema.registry,
                effective_schema.enforce_application_schema,
            );
            var existing_node = (try self.store.readNodeById(allocator, node_id)) orelse return core.Error.NotFound;
            defer existing_node.deinit(allocator);
            const legacy_task_close = existing_node.kind == .task and (requested_kind == .verification or requested_kind == .fix);
            if (existing_node.kind == .task and requested_kind != .task and !legacy_task_close) return error.InvalidTaskTransition;
            const kind: core.NodeKind = if (legacy_task_close) .task else requested_kind;
            if (existing_node.kind != .task and kind != .task) {
                try validateImplicitSchemaRelation(
                    effective_schema.registry,
                    effective_schema.enforce_application_schema,
                    existing_node.kind,
                    .deprecated_by,
                    kind,
                );
            }
            const existing_schema_type = if (legacy_task_close) try self.store.getNodeStringProperty(allocator, node_id, "schema_type") else null;
            defer if (existing_schema_type) |value| allocator.free(value);
            const effective_schema_type: ?[]const u8 = if (legacy_task_close and update_args.schema_type != null and
                (std.mem.eql(u8, update_args.schema_type.?, "verification") or std.mem.eql(u8, update_args.schema_type.?, "fix")))
                existing_schema_type orelse "task"
            else
                update_args.schema_type;
            const recorded_ns = persistentNowNs(self.io);
            const recorded_ns_u64 = try u128ToU64(recorded_ns);
            if (legacy_task_close) {
                _ = try validateTaskCloseTransition(
                    allocator,
                    self.store,
                    existing_node,
                    .completed,
                    null,
                    false,
                    recorded_ns_u64,
                );
            } else if (kind == .task) {
                try validateTaskLifecycleFieldsForRewrite(allocator, self.store, node_id, recorded_ns_u64);
            }
            const lifecycle = try taskLifecycleMetadataForUpdate(allocator, self.store, existing_node, requested_kind, recorded_ns);
            const task_event_metadata = try taskEventMetadataForUpdate(allocator, self.store, existing_node, kind, update_args.schema_type, recorded_ns);
            defer if (task_event_metadata) |metadata| metadata.deinit(allocator);
            const governance_args = ParsedNodeTextGovernanceArgs{
                .kind_label = update_args.kind_label,
                .text = update_args.text,
                .schema_type = effective_schema_type,
                .name = update_args.name,
                .summary = update_args.summary,
                .retrieval_hints = update_args.retrieval_hints,
                .recorded_ns = recorded_ns,
                .task_created_ns = lifecycle.task_created_ns,
                .task_completed_ns = if (legacy_task_close) null else lifecycle.task_completed_ns,
                .task_event_metadata = task_event_metadata,
            };
            try validateNodeWriteGranularity(governance_args);
            const node_text = try nodeVisibleTextFromGovernanceArgs(allocator, governance_args);
            defer if (node_text.ptr != update_args.text.ptr) allocator.free(node_text);
            const store_bytes_before = try storeDirBytes(allocator, self.io, self.db_path);
            if (existing_node.kind == .task or kind == .task) {
                var deferred_based_on = try readMetaknowDeferredBasedOnSidecarForwardPairs(allocator, self.io, self.db_path);
                defer deferred_based_on.deinit(allocator);
                const result = try self.store.updateNode(node_id, kind, node_text);
                try applyNodeGovernanceProperties(allocator, self.store, node_id, governance_args, null);
                if (legacy_task_close) {
                    _ = try self.store.upsertPropertiesBatch(allocator, &.{
                        .{ .owner = .{ .node = node_id }, .key = "task_completed_ns", .value = .{ .uint = try u128ToU64(lifecycle.task_completed_ns orelse return error.InvalidTaskTransition) } },
                        .{ .owner = .{ .node = node_id }, .key = task.status_property, .value = .{ .string = @tagName(task.Status.completed) } },
                        .{ .owner = .{ .node = node_id }, .key = task.claim_expires_ns_property, .value = .{ .uint = 0 } },
                    });
                } else if (kind == .task) {
                    try ensureTaskStatusProperty(allocator, self.store, node_id);
                }
                try restoreMetaknowDeferredBasedOnSidecar(allocator, self.store, &deferred_based_on);
                return .{ .rewritten = .{
                    .node_id = node_id.toInt(),
                    .store_bytes_before = store_bytes_before,
                    .nodes_rewritten = result.nodes_rewritten,
                    .edges_rewritten = result.edges_rewritten,
                    .edges_removed = result.edges_removed,
                } };
            }

            const new_node_id = try self.store.addNode(kind, node_text);
            try applyNodeGovernanceProperties(allocator, self.store, new_node_id, governance_args, null);
            const edge_id = try dag.addEdgeCheckedWithPersistentStore(allocator, self.store, node_id, .deprecated_by, new_node_id, .{});
            return .{ .versioned = .{
                .old_node_id = node_id.toInt(),
                .new_node_id = new_node_id.toInt(),
                .edge_id = edge_id.toInt(),
                .store_bytes_before = store_bytes_before,
            } };
        }

        pub fn appendVersion(
            self: *Context,
            allocator: std.mem.Allocator,
            prepared: *const PreparedAppendVersion,
        ) !struct {
            old_node_id: u64,
            new_node_id: u64,
            edge_id: u64,
            store_bytes_before: u64,
        } {
            var effective_schema = try loadEffectiveSchemaRegistry(allocator, self.io, self.store, prepared.update_args.schema_path);
            defer effective_schema.deinit();
            const kind = try parseNodeKindWithSchemaPolicy(
                prepared.update_args.kind_label,
                effective_schema.registry,
                effective_schema.enforce_application_schema,
            );
            var existing_node = (try self.store.readNodeById(allocator, prepared.old_node_id)) orelse return core.Error.NotFound;
            defer existing_node.deinit(allocator);
            try validateImplicitSchemaRelation(
                effective_schema.registry,
                effective_schema.enforce_application_schema,
                existing_node.kind,
                .deprecated_by,
                kind,
            );
            const store_bytes_before = try storeDirBytes(allocator, self.io, self.db_path);
            const new_node_id = try self.store.addNode(kind, prepared.node_text);
            try applyNodeGovernanceProperties(allocator, self.store, new_node_id, prepared.governance_args, null);
            if (kind == .task) try ensureTaskStatusProperty(allocator, self.store, new_node_id);
            const edge_id = try dag.addEdgeCheckedWithPersistentStore(allocator, self.store, prepared.old_node_id, .deprecated_by, new_node_id, .{});
            return .{
                .old_node_id = prepared.old_node_id.toInt(),
                .new_node_id = new_node_id.toInt(),
                .edge_id = edge_id.toInt(),
                .store_bytes_before = store_bytes_before,
            };
        }

        pub fn govern(
            self: *Context,
            allocator: std.mem.Allocator,
            prepared: *const PreparedGovern,
        ) !struct { node_id: u64, parent_id: ?[]const u8 } {
            var existing_node = (try self.store.readNodeById(allocator, prepared.node_id)) orelse return core.Error.NotFound;
            defer existing_node.deinit(allocator);
            const kind_label = try nodeKindNameAlloc(allocator, existing_node.kind);
            defer allocator.free(kind_label);
            const governance_args = ParsedNodeTextGovernanceArgs{
                .kind_label = kind_label,
                .text = existing_node.text,
                .schema_type = prepared.govern_args.schema_type,
                .recorded_ns = persistentNowNs(self.io),
            };
            try validateNodeWriteGranularity(governance_args);
            _ = try nodeVisibleTextFromGovernanceArgs(allocator, governance_args);
            try applyNodeGovernanceProperties(
                allocator,
                self.store,
                prepared.node_id,
                governance_args,
                prepared.govern_args.parent_id,
            );
            return .{ .node_id = prepared.node_id.toInt(), .parent_id = prepared.govern_args.parent_id };
        }

        pub fn delete(
            self: *Context,
            allocator: std.mem.Allocator,
            prepared: *const PreparedDelete,
        ) !DeleteResult {
            var contain_children = try collectContainChildIds(allocator, self.store, prepared.node_id);
            defer contain_children.deinit(allocator);
            if (contain_children.items.len > 0) return .{ .rejected_children = prepared.node_id.toInt() };

            const store_bytes_before = try storeDirBytes(allocator, self.io, self.db_path);
            var deferred_based_on = try readMetaknowDeferredBasedOnSidecarForwardPairs(allocator, self.io, self.db_path);
            defer deferred_based_on.deinit(allocator);
            if (deferred_based_on.present) pruneMetaknowDeferredBasedOnPairsForNode(&deferred_based_on, prepared.node_id);
            const result = try self.store.deleteNode(prepared.node_id);
            try restoreMetaknowDeferredBasedOnSidecar(allocator, self.store, &deferred_based_on);
            return .{ .deleted = .{
                .node_id = prepared.node_id.toInt(),
                .store_bytes_before = store_bytes_before,
                .nodes_rewritten = result.nodes_rewritten,
                .edges_rewritten = result.edges_rewritten,
                .edges_removed = result.edges_removed,
            } };
        }
    };
};

const node_mutation_commands = node_mutation_commands_mod.NodeMutationCommands(NodeMutationCommandOps);

const GraphTraversalNeighborsArguments = struct {
    db_path: []const u8,
    schema_path: ?[]const u8,
    node_id: core.NodeId,
    options: ParsedNeighborsArgs,
};

const GraphTraversalIncomingArguments = struct {
    db_path: []const u8,
    schema_path: ?[]const u8,
    node_id: core.NodeId,
    options: ParsedIncomingArgs,
};

const GraphTraversalPathArguments = struct {
    db_path: []const u8,
    schema_path: ?[]const u8,
    from: core.NodeId,
    to: core.NodeId,
    rel_label: ?[]const u8,
};

const GraphTraversalCommandOps = struct {
    pub fn parseNeighborsArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !GraphTraversalNeighborsArguments {
        const parsed = try parseDbArgs(allocator, io, args, 2, 1, 21, true);
        const options = try parseNeighborsArgs(parsed.rest);
        return .{
            .db_path = parsed.db_path,
            .schema_path = options.schema_path,
            .node_id = try parseNodeIdArg(options.node_id),
            .options = options,
        };
    }

    pub fn parseIncomingArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !GraphTraversalIncomingArguments {
        const parsed = try parseDbArgs(allocator, io, args, 2, 1, 5, true);
        const options = try parseIncomingArgs(parsed.rest);
        return .{
            .db_path = parsed.db_path,
            .schema_path = options.schema_path,
            .node_id = try parseNodeIdArg(options.node_id),
            .options = options,
        };
    }

    pub fn parsePathArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !GraphTraversalPathArguments {
        const parsed = try parseDbArgs(allocator, io, args, 2, 2, 5, true);
        const schema_arg = try schema_arguments.parseOptionalTrailing(parsed.rest, 2, 3);
        return .{
            .db_path = parsed.db_path,
            .schema_path = schema_arg.schema_path,
            .from = try parseNodeIdArg(schema_arg.positionals[0]),
            .to = try parseNodeIdArg(schema_arg.positionals[1]),
            .rel_label = if (schema_arg.positionals.len > 2) schema_arg.positionals[2] else null,
        };
    }

    pub const Context = struct {
        cli_lock: CliStoreLock,
        store: storage.Store,
        effective_schema: EffectiveSchemaRegistry,
        edge_retention_registry: storage.EdgeSegmentRetentionRegistry,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            db_path: []const u8,
            schema_path: ?[]const u8,
        ) !Context {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            var store = try storage.Store.open(allocator, io, db_path);
            errdefer store.deinit();
            var effective_schema = try loadEffectiveSchemaRegistry(allocator, io, store, schema_path);
            errdefer effective_schema.deinit();
            return .{
                .cli_lock = cli_lock,
                .store = store,
                .effective_schema = effective_schema,
                .edge_retention_registry = storage.EdgeSegmentRetentionRegistry.init(allocator),
            };
        }

        pub fn deinit(self: *Context) void {
            self.edge_retention_registry.deinit();
            self.effective_schema.deinit();
            self.store.deinit();
            self.cli_lock.deinit();
        }

        pub fn repair(self: *Context) !void {
            try self.store.repairPersistentIndexesFromLog();
        }

        fn relFilter(self: *Context, label: ?[]const u8) !?core.RelKind {
            return if (label) |rel_label|
                try parseRelKindWithSchemaPolicy(
                    rel_label,
                    self.effective_schema.registry,
                    self.effective_schema.enforce_application_schema,
                )
            else
                null;
        }

        pub fn renderNeighbors(
            self: *Context,
            allocator: std.mem.Allocator,
            parsed: GraphTraversalNeighborsArguments,
        ) ![]u8 {
            const rel_filter = try self.relFilter(parsed.options.rel_label);
            return if (parsed.options.format == .json)
                renderNeighborsJsonOutputRetained(
                    allocator,
                    self.store,
                    &self.edge_retention_registry,
                    self.effective_schema.registry,
                    parsed.node_id,
                    rel_filter,
                    parsed.options,
                )
            else if (parsed.options.limit) |limit|
                renderNeighborsOutputMaybeRetained(
                    allocator,
                    self.store,
                    &self.edge_retention_registry,
                    self.effective_schema.registry,
                    parsed.node_id,
                    rel_filter,
                    .{
                        .max_results = limit + parsed.options.offset,
                        .max_visited_edges = limit + parsed.options.offset,
                    },
                    true,
                    parsed.options.offset,
                    parsed.options.include_history,
                )
            else
                renderNeighborsOutputMaybeRetained(
                    allocator,
                    self.store,
                    &self.edge_retention_registry,
                    self.effective_schema.registry,
                    parsed.node_id,
                    rel_filter,
                    .{},
                    false,
                    0,
                    parsed.options.include_history,
                );
        }

        pub fn renderIncoming(
            self: *Context,
            allocator: std.mem.Allocator,
            parsed: GraphTraversalIncomingArguments,
        ) ![]u8 {
            return renderIncomingOutput(
                allocator,
                self.store,
                self.effective_schema.registry,
                parsed.node_id,
                try self.relFilter(parsed.options.rel_label),
                .{},
                parsed.options.include_history,
            );
        }

        pub fn renderPath(
            self: *Context,
            allocator: std.mem.Allocator,
            parsed: GraphTraversalPathArguments,
        ) ![]u8 {
            var result = try query.pathWithPersistentStoreRetained(
                allocator,
                self.store,
                &self.edge_retention_registry,
                parsed.from,
                parsed.to,
                try self.relFilter(parsed.rel_label),
                .{},
            );
            defer result.deinit(allocator);
            if (result.nodes.items.len == 0) {
                if (result.stats.budget_exceeded) return core.Error.BudgetExceeded;
                return allocator.dupe(u8, "not found\n");
            }
            var out = QueryOutputWriter{
                .allocator = allocator,
                .max_bytes = std.math.maxInt(usize),
            };
            errdefer out.buffer.deinit(allocator);
            for (result.nodes.items, 0..) |node_id, index| {
                if (index > 0) try out.writeAll(" -> ");
                try out.print("{}", .{node_id.toInt()});
            }
            try out.writeAll("\n");
            return out.buffer.toOwnedSlice(allocator);
        }
    };
};

const graph_traversal_commands = graph_traversal_commands_mod.GraphTraversalCommands(GraphTraversalCommandOps);

const SegmentCommandOps = struct {
    pub fn joinArguments(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
        return joinArgs(allocator, parts);
    }

    pub fn renderQueryOutput(
        allocator: std.mem.Allocator,
        io: std.Io,
        root_dir: []const u8,
        physical: anytype,
        explain: bool,
    ) ![]u8 {
        return renderSegmentBundleQueryOutput(allocator, io, root_dir, physical, explain, .{});
    }

    pub fn parseExportArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !struct { db_path: []const u8, root_dir: []const u8 } {
        const parsed = try parseDbArgs(allocator, io, args, 2, 1, 1, true);
        return .{ .db_path = parsed.db_path, .root_dir = parsed.rest[0] };
    }

    pub const ExportContext = struct {
        cli_lock: CliStoreLock,
        store: storage.Store,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            db_path: []const u8,
        ) !ExportContext {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{ .cli_lock = cli_lock, .store = store };
        }

        pub fn deinit(self: *ExportContext) void {
            self.store.deinit();
            self.cli_lock.deinit();
        }

        pub fn publish(self: *ExportContext, root_dir: []const u8) !void {
            try self.store.publishSegmentBundle(root_dir);
        }

        pub fn readMeta(self: *ExportContext) !struct { nodes: u64, edges: u64 } {
            const meta = try self.store.readIndexMeta();
            return .{ .nodes = meta.nodes, .edges = meta.edges };
        }
    };

    pub fn gcUnpinned(
        allocator: std.mem.Allocator,
        io: std.Io,
        root_dir: []const u8,
    ) !segment_bundle.GcResult {
        return segment_bundle.gcUnpinned(allocator, io, root_dir, &.{});
    }
};

const segment_commands = segment_commands_mod.SegmentCommands(ql, SegmentCommandOps);

const TaskReadCommandOps = struct {
    pub fn parseReadyArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !struct { db_path: []const u8, task_id: []const u8 } {
        const parsed = try parseDbArgs(allocator, io, args, 2, 1, 1, true);
        return .{ .db_path = parsed.db_path, .task_id = parsed.rest[0] };
    }

    pub fn parsePacketArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !struct {
        db_path: []const u8,
        task_id: []const u8,
        options: ParsedTaskPacketArgs,
    } {
        const parsed = try parseDbArgs(allocator, io, args, 2, 1, 13, true);
        const options = try parseTaskPacketArgs(parsed.rest);
        return .{ .db_path = parsed.db_path, .task_id = options.task_id, .options = options };
    }

    pub fn parseFrontierArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !struct {
        db_path: []const u8,
        options: ParsedTaskFrontierArgs,
    } {
        const parsed = try parseDbArgs(allocator, io, args, 2, 1, 6, true);
        return .{ .db_path = parsed.db_path, .options = try parseTaskFrontierArgs(parsed.rest) };
    }

    pub fn parseAncestryArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !struct {
        db_path: []const u8,
        task_id: []const u8,
        depth: usize,
        limit: usize,
    } {
        const parsed = try parseDbArgs(allocator, io, args, 2, 1, 5, true);
        const options = try parseTaskAncestryArgs(parsed.rest);
        return .{
            .db_path = parsed.db_path,
            .task_id = options.task_id,
            .depth = options.depth,
            .limit = options.limit,
        };
    }

    pub fn parseMetricsArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !struct {
        db_path: []const u8,
        root_id: []const u8,
        limit: usize,
    } {
        const parsed = try parseDbArgs(allocator, io, args, 2, 1, 3, true);
        const options = try parseTaskMetricsArgs(parsed.rest);
        return .{ .db_path = parsed.db_path, .root_id = options.root_id, .limit = options.limit };
    }

    pub fn validateTaskReadAgentIdentity(identity: []const u8) ![]const u8 {
        return validateAgentIdentity(identity);
    }

    pub const ReadContext = struct {
        cli_lock: CliStoreLock,
        store: storage.Store,
        io: std.Io,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !ReadContext {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{ .cli_lock = cli_lock, .store = store, .io = io };
        }

        pub fn deinit(self: *ReadContext) void {
            self.store.deinit();
            self.cli_lock.deinit();
        }

        pub fn repair(self: *ReadContext) !void {
            try self.store.repairPersistentIndexesFromLog();
        }
    };

    pub fn readReady(self: *ReadContext, allocator: std.mem.Allocator, task_id: []const u8) ![]const u8 {
        return @tagName(try taskReadyForOpenTask(allocator, self.store, try parseNodeIdArg(task_id)));
    }

    pub fn renderPacket(
        self: *ReadContext,
        allocator: std.mem.Allocator,
        task_id: []const u8,
        options: ParsedTaskPacketArgs,
    ) ![]u8 {
        const node_id = try parseNodeIdArg(task_id);
        return if (options.format == .json)
            renderTaskPacketJsonOutput(allocator, self.store, node_id, options)
        else
            renderTaskPacketOutput(allocator, self.store, node_id, options.limit);
    }

    pub fn renderFrontier(
        self: *ReadContext,
        allocator: std.mem.Allocator,
        options: ParsedTaskFrontierArgs,
    ) ![]u8 {
        return renderTaskFrontierOutput(
            allocator,
            self.store,
            try parseNodeIdArg(options.root_id),
            options,
            try u128ToU64(persistentNowNs(self.io)),
        );
    }

    pub fn renderAncestry(
        self: *ReadContext,
        allocator: std.mem.Allocator,
        task_id: []const u8,
        depth: usize,
        limit: usize,
    ) ![]u8 {
        return renderTaskAncestryOutput(allocator, self.store, try parseNodeIdArg(task_id), depth, limit);
    }

    pub fn renderMetrics(
        self: *ReadContext,
        allocator: std.mem.Allocator,
        root_id: []const u8,
        limit: usize,
    ) ![]u8 {
        return renderTaskMetricsOutput(allocator, self.io, self.store, try parseNodeIdArg(root_id), limit);
    }
};

const task_read_commands = task_read_commands_mod.TaskReadCommands(TaskReadCommandOps);

const TaskLeaseCommandOps = struct {
    pub fn parseDbArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
        min_rest: usize,
        max_rest: usize,
    ) !struct { db_path: []const u8, rest: []const []const u8 } {
        const parsed = try parseDbArgs(allocator, io, args, 2, min_rest, max_rest, true);
        return .{ .db_path = parsed.db_path, .rest = parsed.rest };
    }

    pub fn defaultClaimTtlSeconds() u64 {
        return task_claim_default_ttl_s;
    }

    pub fn parseTaskId(value: []const u8) !core.NodeId {
        return parseNodeIdArg(value);
    }

    pub fn taskIdValue(task_id: core.NodeId) u64 {
        return task_id.toInt();
    }

    pub fn validateTaskLeaseAgentIdentity(identity: []const u8) ![]const u8 {
        return validateAgentIdentity(identity);
    }

    pub fn writeTaskLeaseEscapedText(writer: anytype, value: []const u8) !void {
        try writeEscapedText(writer, value);
    }

    pub const ClaimInspection = struct {
        lifecycle_snapshot: task.StatusSnapshot,
        holder: ?[]const u8,
        now_ns: u64,
        expires_ns: u64,

        pub fn deinit(self: *ClaimInspection, _: std.mem.Allocator) void {
            self.lifecycle_snapshot.deinit();
        }
    };

    pub const ReleaseInspection = struct {
        lifecycle_snapshot: task.StatusSnapshot,
        holder: ?[]const u8,
        now_ns: u64,
        expires_ns: u64,
        terminal: bool,
        status_is_open: bool,

        pub fn deinit(self: *ReleaseInspection, _: std.mem.Allocator) void {
            self.lifecycle_snapshot.deinit();
        }
    };

    pub const Context = struct {
        cli_lock: CliStoreLock,
        store: storage.Store,
        io: std.Io,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !Context {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{ .cli_lock = cli_lock, .store = store, .io = io };
        }

        pub fn deinit(self: *Context) void {
            self.store.deinit();
            self.cli_lock.deinit();
        }

        pub fn inspectClaim(
            self: *Context,
            allocator: std.mem.Allocator,
            task_id: core.NodeId,
        ) !ClaimInspection {
            var node = (try self.store.readNodeById(allocator, task_id)) orelse return core.Error.NotFound;
            defer node.deinit(allocator);
            if (node.kind != .task) return core.Error.InvalidId;

            const now_ns = try u128ToU64(persistentNowNs(self.io));
            var lifecycle_snapshot = try task.StatusSnapshot.initForNodeIds(allocator, self.store, &.{task_id});
            errdefer lifecycle_snapshot.deinit();
            const lifecycle = try lifecycle_snapshot.statusForStoredNode(node, now_ns);
            if (lifecycle.isTerminal()) return error.InvalidTaskTransition;
            if (try taskHasNonCompletedChildren(allocator, self.store, task_id, now_ns)) return error.TaskHasOpenChildren;
            if ((try task.readyStateWithPersistentStoreSnapshotAt(
                allocator,
                self.store,
                task_id,
                now_ns,
                &lifecycle_snapshot,
            )) != .ready) return error.TaskNotReady;

            const lifecycle_fields = lifecycle_snapshot.fields(task_id);
            return .{
                .lifecycle_snapshot = lifecycle_snapshot,
                .holder = lifecycle_fields.claimed_by,
                .now_ns = now_ns,
                .expires_ns = lifecycle_fields.claim_expires_ns orelse 0,
            };
        }

        pub fn publishClaim(
            self: *Context,
            allocator: std.mem.Allocator,
            task_id: core.NodeId,
            agent_name: []const u8,
            expires_ns: u64,
            claimed: bool,
        ) !void {
            _ = try self.store.upsertPropertiesBatch(allocator, &.{
                .{ .owner = .{ .node = task_id }, .key = task.claimed_by_property, .value = .{ .string = agent_name } },
                .{ .owner = .{ .node = task_id }, .key = task.claim_expires_ns_property, .value = .{ .uint = expires_ns } },
                .{ .owner = .{ .node = task_id }, .key = task.status_property, .value = .{ .string = @tagName(if (claimed) task.Status.claimed else task.Status.open) } },
            });
        }

        pub fn inspectRelease(
            self: *Context,
            allocator: std.mem.Allocator,
            task_id: core.NodeId,
        ) !ReleaseInspection {
            var node = (try self.store.readNodeById(allocator, task_id)) orelse return core.Error.NotFound;
            defer node.deinit(allocator);
            if (node.kind != .task) return core.Error.InvalidId;

            const now_ns = try u128ToU64(persistentNowNs(self.io));
            var lifecycle_snapshot = try task.StatusSnapshot.initForNodeIds(allocator, self.store, &.{task_id});
            errdefer lifecycle_snapshot.deinit();
            const lifecycle = try lifecycle_snapshot.statusForStoredNode(node, now_ns);
            const lifecycle_fields = lifecycle_snapshot.fields(task_id);
            return .{
                .lifecycle_snapshot = lifecycle_snapshot,
                .holder = lifecycle_fields.claimed_by,
                .now_ns = now_ns,
                .expires_ns = lifecycle_fields.claim_expires_ns orelse 0,
                .terminal = lifecycle.isTerminal(),
                .status_is_open = if (lifecycle_fields.stored_status_raw) |value|
                    std.mem.eql(u8, value, @tagName(task.Status.open))
                else
                    false,
            };
        }

        pub fn publishRelease(
            self: *Context,
            allocator: std.mem.Allocator,
            task_id: core.NodeId,
            expire_lease: bool,
            set_open: bool,
        ) !usize {
            if (expire_lease and set_open) {
                const result = try self.store.upsertPropertiesBatch(allocator, &.{
                    .{ .owner = .{ .node = task_id }, .key = task.claim_expires_ns_property, .value = .{ .uint = 0 } },
                    .{ .owner = .{ .node = task_id }, .key = task.status_property, .value = .{ .string = @tagName(task.Status.open) } },
                });
                return result.payload_publish_count;
            }
            if (expire_lease) {
                const result = try self.store.upsertPropertiesBatch(allocator, &.{.{
                    .owner = .{ .node = task_id },
                    .key = task.claim_expires_ns_property,
                    .value = .{ .uint = 0 },
                }});
                return result.payload_publish_count;
            }
            if (set_open) {
                const result = try self.store.upsertPropertiesBatch(allocator, &.{.{
                    .owner = .{ .node = task_id },
                    .key = task.status_property,
                    .value = .{ .string = @tagName(task.Status.open) },
                }});
                return result.payload_publish_count;
            }
            return 0;
        }
    };
};

const task_lease_commands = task_lease_commands_mod.TaskLeaseCommands(TaskLeaseCommandOps);

const TaskCloseCommandOps = struct {
    pub fn parseDbArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
        min_rest: usize,
        max_rest: usize,
    ) !struct { db_path: []const u8, rest: []const []const u8 } {
        const parsed = try parseDbArgs(allocator, io, args, 2, min_rest, max_rest, true);
        return .{ .db_path = parsed.db_path, .rest = parsed.rest };
    }

    pub fn parseTaskId(value: []const u8) !core.NodeId {
        return parseNodeIdArg(value);
    }

    pub fn taskIdValue(task_id: core.NodeId) u64 {
        return task_id.toInt();
    }

    fn taskStatus(status: TaskMutationArguments.CloseStatus) task.Status {
        return switch (status) {
            .completed => .completed,
            .failed => .failed,
        };
    }

    pub const Context = struct {
        cli_lock: CliStoreLock,
        store: storage.Store,
        io: std.Io,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !Context {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{ .cli_lock = cli_lock, .store = store, .io = io };
        }

        pub fn deinit(self: *Context) void {
            self.store.deinit();
            self.cli_lock.deinit();
        }

        pub fn validateTransition(
            self: *Context,
            allocator: std.mem.Allocator,
            task_id: core.NodeId,
            status: TaskMutationArguments.CloseStatus,
            by: ?[]const u8,
            force: bool,
        ) !struct { recorded_ns: u128, now_ns: u64, already_terminal: bool } {
            var node = (try self.store.readNodeById(allocator, task_id)) orelse return core.Error.NotFound;
            defer node.deinit(allocator);
            if (node.kind != .task) return core.Error.InvalidId;

            const recorded_ns = persistentNowNs(self.io);
            const now_ns = try u128ToU64(recorded_ns);
            const lifecycle = try validateTaskCloseTransition(
                allocator,
                self.store,
                node,
                taskStatus(status),
                by,
                force,
                now_ns,
            );
            return .{
                .recorded_ns = recorded_ns,
                .now_ns = now_ns,
                .already_terminal = lifecycle.isTerminal(),
            };
        }

        pub fn ensureInlineEvidence(
            self: *Context,
            allocator: std.mem.Allocator,
            text: []const u8,
            recorded_ns: u128,
        ) !core.NodeId {
            return ensureTaskEvidenceTextNode(allocator, self.store, text, recorded_ns);
        }

        pub fn ensureEvidenceEdge(
            self: *Context,
            allocator: std.mem.Allocator,
            task_id: core.NodeId,
            evidence_id: core.NodeId,
        ) !void {
            try ensureTaskEvidenceEdge(allocator, self.store, task_id, evidence_id);
        }

        pub fn publishClose(
            self: *Context,
            allocator: std.mem.Allocator,
            task_id: core.NodeId,
            status: TaskMutationArguments.CloseStatus,
            now_ns: u64,
            already_terminal: bool,
        ) !usize {
            if (!already_terminal) {
                const result = try self.store.upsertPropertiesBatch(allocator, &.{
                    .{ .owner = .{ .node = task_id }, .key = "task_completed_ns", .value = .{ .uint = now_ns } },
                    .{ .owner = .{ .node = task_id }, .key = task.status_property, .value = .{ .string = @tagName(taskStatus(status)) } },
                    .{ .owner = .{ .node = task_id }, .key = task.claim_expires_ns_property, .value = .{ .uint = 0 } },
                });
                return result.payload_publish_count;
            }
            if (((try self.store.getUintProperty(
                allocator,
                .{ .node = task_id },
                task.claim_expires_ns_property,
            )) orelse 0) != 0) {
                const result = try self.store.upsertPropertiesBatch(allocator, &.{.{
                    .owner = .{ .node = task_id },
                    .key = task.claim_expires_ns_property,
                    .value = .{ .uint = 0 },
                }});
                return result.payload_publish_count;
            }
            return 0;
        }
    };
};

const task_close_command = task_close_command_mod.TaskCloseCommand(TaskCloseCommandOps);

const TaskEventCommandOps = struct {
    pub fn parseDbArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
        min_rest: usize,
        max_rest: usize,
    ) !struct { db_path: []const u8, rest: []const []const u8 } {
        const parsed = try parseDbArgs(allocator, io, args, 2, min_rest, max_rest, true);
        return .{ .db_path = parsed.db_path, .rest = parsed.rest };
    }

    pub fn parseNodeId(value: []const u8) !core.NodeId {
        return parseNodeIdArg(value);
    }

    pub fn parseRelation(value: []const u8) !core.RelKind {
        return parseRelKindWithLoadedSchema(value, null);
    }

    pub fn nodeIdsEqual(a: core.NodeId, b: core.NodeId) bool {
        return a.toInt() == b.toInt();
    }

    pub fn nodeIdValue(id: core.NodeId) u64 {
        return id.toInt();
    }

    pub fn renderEventText(
        allocator: std.mem.Allocator,
        event_type: TaskEventType,
        note: ?[]const u8,
    ) ![]const u8 {
        return taskEventNodeText(allocator, event_type, note);
    }

    pub fn validateEventText(text: []const u8) !void {
        try validateNodeTextGranularity(text);
    }

    pub const Context = struct {
        cli_lock: CliStoreLock,
        store: storage.Store,
        io: std.Io,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !Context {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{ .cli_lock = cli_lock, .store = store, .io = io };
        }

        pub fn deinit(self: *Context) void {
            self.store.deinit();
            self.cli_lock.deinit();
        }

        pub fn validateTargets(
            self: *Context,
            allocator: std.mem.Allocator,
            root_id: core.NodeId,
            task_id: ?core.NodeId,
        ) !void {
            try validateTaskEventTargets(allocator, self.store, root_id, task_id);
        }

        pub fn eventNowNs(self: *Context) u128 {
            return persistentNowNs(self.io);
        }

        pub fn addEventNode(
            self: *Context,
            event_type: TaskEventType,
            event_text: []const u8,
        ) !core.NodeId {
            const event_kind: core.NodeKind = if (event_type == .write_error) .error_event else .command;
            return self.store.addNode(event_kind, event_text);
        }

        pub fn applyEventGovernance(
            self: *Context,
            allocator: std.mem.Allocator,
            event_id: core.NodeId,
            event_type: TaskEventType,
            event_text: []const u8,
            event_ns: u128,
            root_id: core.NodeId,
            task_id: ?core.NodeId,
            relation: ?core.RelKind,
        ) !void {
            const relation_text = if (relation) |rel| try relKindNameAlloc(allocator, rel) else null;
            defer if (relation_text) |value| allocator.free(value);
            try applyNodeGovernanceProperties(allocator, self.store, event_id, .{
                .kind_label = if (event_type == .write_error) "error_event" else "command",
                .text = event_text,
                .schema_type = "task_event",
                .task_event_metadata = .{
                    .event_type = TaskMutationArguments.eventTypeName(event_type),
                    .event_ns = event_ns,
                    .root_id = root_id.toInt(),
                    .task_id = if (task_id) |id| id.toInt() else null,
                    .dependency_relation = relation_text,
                },
            }, null);
        }

        pub fn addTaskEventEdge(
            self: *Context,
            allocator: std.mem.Allocator,
            event_id: core.NodeId,
            target_id: core.NodeId,
        ) !void {
            _ = try dag.addEdgeCheckedWithPersistentStore(
                allocator,
                self.store,
                event_id,
                .task_event,
                target_id,
                .{},
            );
        }
    };
};

const task_event_command = task_event_command_mod.TaskEventCommand(TaskEventCommandOps);

const schema_arguments = schema_commands_mod.SchemaArguments;

const SchemaCommandOps = struct {
    pub fn resolveDefaultDbPath() []const u8 {
        return defaultDbPath();
    }

    pub const InfoContext = struct {
        allocator: std.mem.Allocator,
        registry: schema.Registry,
        label: []u8,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            schema_path: ?[]const u8,
            profiles: ?[]const u8,
        ) !InfoContext {
            const parsed = ParsedSchemaArg{
                .positionals = &.{},
                .schema_path = schema_path,
                .profiles = profiles,
            };
            var registry = try loadSchemaRegistryFromSchemaArg(allocator, io, parsed);
            errdefer registry.deinit();
            const label = try schemaArgLabelAlloc(allocator, parsed);
            return .{ .allocator = allocator, .registry = registry, .label = label };
        }

        pub fn deinit(self: *InfoContext) void {
            self.allocator.free(self.label);
            self.registry.deinit();
            self.* = undefined;
        }

        pub fn render(self: *InfoContext, writer: anytype) !void {
            try renderSchemaInfo(writer, self.registry, self.label);
        }
    };

    pub const ListContext = struct {
        registry: schema.Registry,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            schema_path: ?[]const u8,
            profiles: ?[]const u8,
        ) !ListContext {
            const parsed = ParsedSchemaArg{
                .positionals = &.{},
                .schema_path = schema_path,
                .profiles = profiles,
            };
            return .{
                .registry = try loadSchemaRegistryFromSchemaArg(allocator, io, parsed),
            };
        }

        pub fn deinit(self: *ListContext) void {
            self.registry.deinit();
            self.* = undefined;
        }

        pub fn renderKinds(self: *ListContext, writer: anytype) !void {
            try renderKindListWithSchema(writer, self.registry);
        }

        pub fn renderRelations(self: *ListContext, writer: anytype) !void {
            try renderRelListWithSchema(writer, self.registry);
        }
    };

    pub const StoreContext = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        db_path: []const u8,
        cli_lock: CliStoreLock,
        store: storage.Store,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !StoreContext {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{ .allocator = allocator, .io = io, .db_path = db_path, .cli_lock = cli_lock, .store = store };
        }

        pub fn deinit(self: *StoreContext) void {
            self.store.deinit();
            self.cli_lock.deinit();
            self.* = undefined;
        }

        pub fn renderShow(self: *StoreContext, writer: anytype, want_json: bool) !void {
            try renderSchemaShow(self.allocator, self.io, writer, self.store, want_json);
        }

        pub fn apply(self: *StoreContext, writer: anytype, schema_path: []const u8, profiles: ?[]const u8) !void {
            try runSchemaApply(self.allocator, self.io, writer, self.store, .{
                .db_path = self.db_path,
                .schema_path = schema_path,
                .profiles = profiles,
            });
        }

        pub fn validate(self: *StoreContext, writer: anytype, schema_path: []const u8, profiles: ?[]const u8) !void {
            try runSchemaValidate(self.allocator, self.io, writer, self.store, .{
                .db_path = self.db_path,
                .schema_path = schema_path,
                .profiles = profiles,
            });
        }

        pub fn reconcile(self: *StoreContext, writer: anytype, schema_path: []const u8, plan_path: []const u8, profiles: ?[]const u8) !void {
            try runSchemaReconcile(self.allocator, self.io, writer, self.store, .{
                .db_path = self.db_path,
                .schema_path = schema_path,
                .plan_path = plan_path,
                .profiles = profiles,
            });
        }
    };

    pub fn runMigrate(
        allocator: std.mem.Allocator,
        io: std.Io,
        writer: anytype,
        old_db_path: []const u8,
        new_db_path: []const u8,
        from_schema_path: ?[]const u8,
        to_schema_path: ?[]const u8,
        profiles: ?[]const u8,
    ) !void {
        try runSchemaMigrate(allocator, io, writer, .{
            .old_db_path = old_db_path,
            .new_db_path = new_db_path,
            .from_schema_path = from_schema_path,
            .to_schema_path = to_schema_path,
            .profiles = profiles,
        });
    }
};

const schema_commands = schema_commands_mod.SchemaCommands(SchemaCommandOps);
const schema_reconcile_command = schema_reconcile_command_mod.SchemaReconcileCommand(struct {
    pub const Context = SchemaCommandOps.StoreContext;
});

const PropertyCommandOps = struct {
    pub const PropertyOwner = storage.PropertyOwner;

    pub fn parseDbArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
        min_rest: usize,
        max_rest: usize,
    ) !struct { db_path: []const u8, rest: []const []const u8 } {
        const parsed = try parseDbArgs(allocator, io, args, 2, min_rest, max_rest, true);
        return .{ .db_path = parsed.db_path, .rest = parsed.rest };
    }

    pub fn parseOptionalSchema(rest: []const []const u8, min_positionals: usize, max_positionals: usize) !schema_arguments.Selection {
        return schema_arguments.parseOptionalTrailing(rest, min_positionals, max_positionals);
    }

    pub fn parseNodeOwner(value: []const u8) !PropertyOwner {
        return .{ .node = try parseNodeIdArg(value) };
    }

    pub fn parseEdgeOwner(value: []const u8) !PropertyOwner {
        return .{ .edge = core.EdgeId.fromInt(std.fmt.parseInt(u64, value, 10) catch return error.InvalidEdgeId) };
    }

    pub fn normalizeNodeStringKey(key: []const u8) ![]const u8 {
        return normalizeNodeStringPropertyKey(key);
    }

    pub fn normalizeEdgeStringKey(key: []const u8) ![]const u8 {
        return normalizeEdgeStringPropertyKey(key);
    }

    pub fn normalizeNodeUintKey(key: []const u8) ![]const u8 {
        return normalizeNodeUintPropertyKey(key);
    }

    pub fn normalizeEdgeUintKey(key: []const u8) ![]const u8 {
        return normalizeEdgeUintPropertyKey(key);
    }

    pub fn validateString(owner: PropertyOwner, key: []const u8, value: []const u8) !void {
        try validateParsedStringProperty(owner, key, value);
    }

    pub fn ownerId(owner: PropertyOwner) u64 {
        return switch (owner) {
            .node => |node_id| node_id.toInt(),
            .edge => |edge_id| edge_id.toInt(),
        };
    }

    pub const Context = struct {
        allocator: std.mem.Allocator,
        cli_lock: CliStoreLock,
        store: storage.Store,
        effective_schema: EffectiveSchemaRegistry,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            db_path: []const u8,
            schema_path: ?[]const u8,
        ) !Context {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            var store = try storage.Store.open(allocator, io, db_path);
            errdefer store.deinit();
            const effective_schema = try loadEffectiveSchemaRegistry(allocator, io, store, schema_path);
            return .{
                .allocator = allocator,
                .cli_lock = cli_lock,
                .store = store,
                .effective_schema = effective_schema,
            };
        }

        pub fn deinit(self: *Context) void {
            self.effective_schema.deinit();
            self.store.deinit();
            self.cli_lock.deinit();
            self.* = undefined;
        }

        pub fn setString(self: *Context, owner: PropertyOwner, key: []const u8, value: []const u8) !void {
            try governed_node_write_admission.validateSchemaStringPropertyWrite(
                self.allocator,
                self.store,
                self.effective_schema.registry,
                owner,
                key,
                value,
                self.effective_schema.enforce_application_schema,
            );
            try self.store.setStringProperty(self.allocator, owner, key, value);
        }

        pub fn setUint(self: *Context, owner: PropertyOwner, key: []const u8, value: u64) !void {
            try governed_node_write_admission.validateSchemaUintPropertyWrite(
                self.allocator,
                self.store,
                self.effective_schema.registry,
                owner,
                key,
                self.effective_schema.enforce_application_schema,
            );
            try self.store.setUintProperty(self.allocator, owner, key, value);
        }
    };
};

const property_commands = property_commands_mod.PropertyCommands(PropertyCommandOps);

const ContainTreeMigrationCommandOps = struct {
    pub const NodeId = core.NodeId;

    pub const Plan = struct {
        allocator: std.mem.Allocator,
        from_id: NodeId,
        to_id: NodeId,
        old_edge_ids: std.ArrayList(core.EdgeId) = .empty,
        new_children: std.ArrayList(NodeId) = .empty,
        deduped: usize = 0,

        pub fn deinit(self: *Plan) void {
            self.new_children.deinit(self.allocator);
            self.old_edge_ids.deinit(self.allocator);
            self.* = undefined;
        }
    };

    pub const Inspection = union(enum) {
        scan_cap_exceeded: usize,
        cycle,
        project_violation: NodeId,
        ready: Plan,
    };

    pub const CommitResult = struct {
        moved: usize,
        deduped: usize,
        old_edges_removed: usize,
    };

    pub fn parseDbArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !struct { db_path: []const u8, rest: []const []const u8 } {
        const parsed = try parseDbArgs(allocator, io, args, 2, 2, 2, true);
        return .{ .db_path = parsed.db_path, .rest = parsed.rest };
    }

    pub fn parseNodeId(value: []const u8) !NodeId {
        return parseNodeIdArg(value);
    }

    pub fn nodeIdValue(node_id: NodeId) u64 {
        return node_id.toInt();
    }

    pub const Context = struct {
        allocator: std.mem.Allocator,
        cli_lock: CliStoreLock,
        store: storage.Store,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !Context {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{
                .allocator = allocator,
                .cli_lock = cli_lock,
                .store = store,
            };
        }

        pub fn deinit(self: *Context) void {
            self.store.deinit();
            self.cli_lock.deinit();
            self.* = undefined;
        }

        pub fn inspect(self: *Context, from_id: NodeId, to_id: NodeId) !Inspection {
            var node_view = try self.store.openNodeByIdIndexView();
            defer node_view.deinit();
            if (!try node_view.nodeExists(from_id) or !try node_view.nodeExists(to_id)) {
                return core.Error.NotFound;
            }

            var scan_truncated = false;
            var from_subtree = try collectProjectDescendantNodeIds(
                self.allocator,
                self.store,
                from_id,
                null,
                list_recent_project_scan_cap,
                &scan_truncated,
                .contain_only,
            );
            defer from_subtree.deinit(self.allocator);
            if (scan_truncated) {
                return .{ .scan_cap_exceeded = list_recent_project_scan_cap };
            }
            for (from_subtree.items) |node_id| {
                if (node_id.toInt() == to_id.toInt()) return .cycle;
            }

            var to_children = try collectContainChildIds(self.allocator, self.store, to_id);
            defer to_children.deinit(self.allocator);
            var to_set = std.AutoHashMap(u64, void).init(self.allocator);
            defer to_set.deinit();
            for (to_children.items) |child_id| try to_set.put(child_id, {});

            var from_records = try self.store.readVisibleEdgeIndexRecordsByNodeForOrderedTraversal(
                self.allocator,
                from_id,
            );
            defer from_records.deinit(self.allocator);

            // Validate every child, including a child that will be deduped,
            // before allocating a commit plan or mutating the store.
            for (from_records.items) |record| {
                if (record.rel != @intFromEnum(core.RelKind.contain)) continue;
                const child_id = NodeId.fromInt(record.dst);
                validateContainProjectTree(self.allocator, self.store, to_id, child_id) catch |err| switch (err) {
                    error.ProjectTreeViolation => return .{ .project_violation = child_id },
                    else => |other| return other,
                };
            }

            var plan = Plan{
                .allocator = self.allocator,
                .from_id = from_id,
                .to_id = to_id,
            };
            errdefer plan.deinit();
            try plan.old_edge_ids.ensureTotalCapacityPrecise(self.allocator, from_records.items.len);
            try plan.new_children.ensureTotalCapacityPrecise(self.allocator, from_records.items.len);
            for (from_records.items) |record| {
                if (record.rel != @intFromEnum(core.RelKind.contain)) continue;
                plan.old_edge_ids.appendAssumeCapacity(core.EdgeId.fromInt(record.edge_id));
                if (to_set.contains(record.dst)) {
                    plan.deduped += 1;
                    continue;
                }
                try to_set.put(record.dst, {});
                plan.new_children.appendAssumeCapacity(NodeId.fromInt(record.dst));
            }
            return .{ .ready = plan };
        }

        pub fn commit(self: *Context, plan: *Plan) !CommitResult {
            var moved: usize = 0;
            for (plan.new_children.items) |child_id| {
                const edge_id = try self.store.nextEdgeId();
                try self.store.appendEdge(.{
                    .id = edge_id,
                    .src = plan.to_id,
                    .rel = .contain,
                    .dst = child_id,
                });
                moved += 1;
            }
            try self.store.deleteEdgesBatch(plan.old_edge_ids.items);
            return .{
                .moved = moved,
                .deduped = plan.deduped,
                .old_edges_removed = plan.old_edge_ids.items.len,
            };
        }
    };
};

const contain_tree_migration_command = contain_tree_migration_command_mod.ContainTreeMigrationCommand(ContainTreeMigrationCommandOps);

const EdgeMutationCommandOps = struct {
    pub const NodeId = core.NodeId;
    pub const EdgeId = core.EdgeId;

    pub fn parseDbArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
        min_rest: usize,
        max_rest: usize,
    ) !struct { db_path: []const u8, rest: []const []const u8 } {
        const parsed = try parseDbArgs(allocator, io, args, 2, min_rest, max_rest, true);
        return .{ .db_path = parsed.db_path, .rest = parsed.rest };
    }

    pub fn parseTrailingSchema(rest: []const []const u8, positional_count: usize) !schema_arguments.Selection {
        return schema_arguments.parseTrailing(rest, positional_count);
    }

    pub fn parseNodeId(value: []const u8) !NodeId {
        return parseNodeIdArg(value);
    }

    pub fn parseEdgeId(value: []const u8) !EdgeId {
        return core.EdgeId.fromInt(std.fmt.parseInt(u64, value, 10) catch return error.InvalidEdgeId);
    }

    pub fn edgeIdValue(edge_id: EdgeId) u64 {
        return edge_id.toInt();
    }

    pub const Context = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        cli_lock: CliStoreLock,
        store: storage.Store,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !Context {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{
                .allocator = allocator,
                .io = io,
                .cli_lock = cli_lock,
                .store = store,
            };
        }

        pub fn deinit(self: *Context) void {
            self.store.deinit();
            self.cli_lock.deinit();
            self.* = undefined;
        }

        pub fn add(
            self: *Context,
            src: NodeId,
            rel_label: []const u8,
            dst: NodeId,
            schema_path: ?[]const u8,
        ) !EdgeId {
            var effective_schema = try loadEffectiveSchemaRegistry(
                self.allocator,
                self.io,
                self.store,
                schema_path,
            );
            defer effective_schema.deinit();
            const rel = try parseRelKindWithSchemaPolicy(
                rel_label,
                effective_schema.registry,
                effective_schema.enforce_application_schema,
            );
            if (effective_schema.enforce_application_schema) {
                try validateSchemaEdgeEndpoints(self.store, effective_schema.registry, src, rel, dst);
            }
            // Both canonical `contain` and legacy hierarchy/composition `contains` can
            // place a project inside a traversal tree. A project child must
            // therefore keep a project parent on either surface, otherwise
            // membership and task/document traversal disagree.
            if (rel == .contain or rel == .contains) {
                try validateContainProjectTree(self.allocator, self.store, src, dst);
            }
            if (try self.store.lookupFactEdgeByNodeExternalKeys(self.allocator, src, rel, dst)) |existing_id| {
                return existing_id;
            }
            const id = try dag.addEdgeCheckedWithPersistentStore(
                self.allocator,
                self.store,
                src,
                rel,
                dst,
                .{},
            );
            self.store.refreshFactEdgeExternalKeyIndexAfterAppend(.{
                .id = id,
                .src = src,
                .rel = rel,
                .dst = dst,
            }) catch {};
            return id;
        }

        pub fn delete(self: *Context, edge_id: EdgeId) !void {
            try self.store.deleteEdge(edge_id);
        }

        pub fn deleteBatch(self: *Context, edge_ids: []const EdgeId) !void {
            try self.store.deleteEdgesBatch(edge_ids);
        }
    };
};

const edge_mutation_commands = edge_mutation_commands_mod.EdgeMutationCommands(EdgeMutationCommandOps);

const EdgeSegmentCommandOps = struct {
    pub fn parseDbArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
        min_rest: usize,
        max_rest: usize,
    ) !database_arguments.Parsed {
        return parseDbArgs(allocator, io, args, 2, min_rest, max_rest, true);
    }

    pub fn targetPathExists(io: std.Io, target_path: []const u8) !bool {
        return pathExists(io, target_path);
    }

    pub fn isRecoverablePublishError(err: anyerror) bool {
        return err == error.FileNotFound or err == error.InvalidRecord;
    }

    pub fn startTimer(io: std.Io) u128 {
        return monotonicNs(io);
    }

    pub fn elapsedSince(io: std.Io, start_ns: u128) u128 {
        return elapsedNs(io, start_ns);
    }

    pub const Context = struct {
        cli_lock: CliStoreLock,
        store: storage.Store,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !Context {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{ .cli_lock = cli_lock, .store = store };
        }

        pub fn deinit(self: *Context) void {
            self.store.deinit();
            self.cli_lock.deinit();
            self.* = undefined;
        }

        pub fn publish(self: *Context, segment_dir_path: []const u8) !u64 {
            return self.store.publishEdgeAdjacencySegment(segment_dir_path);
        }

        pub fn repairPersistentIndexes(self: *Context) !void {
            try self.store.repairPersistentIndexesFromLog();
        }

        pub fn compact(self: *Context, segment_dir_path: []const u8) !u64 {
            return self.store.compactPublishedEdgeSegments(segment_dir_path);
        }

        pub fn gc(self: *Context) !storage.EdgeSegmentGcResult {
            return self.store.gcUnreferencedEdgeSegmentsWithProcessLeases();
        }
    };

    pub const MaintenanceContext = struct {
        cli_lock: CliStoreLock,
        store: storage.Store,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            db_path: []const u8,
            gc: bool,
        ) !MaintenanceContext {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.openWithOptions(allocator, io, db_path, .{
                .auto_gc_edge_segments = gc,
            });
            return .{ .cli_lock = cli_lock, .store = store };
        }

        pub fn deinit(self: *MaintenanceContext) void {
            self.store.deinit();
            self.cli_lock.deinit();
            self.* = undefined;
        }

        pub fn execute(
            self: *MaintenanceContext,
            max_segments: usize,
            max_edges: u64,
        ) !storage.EdgeSegmentMaintenanceResult {
            return self.store.compactEdgeSegmentsBudgetedWithProcessLeases(.{
                .max_segments = max_segments,
                .max_edges = max_edges,
            });
        }
    };
};

const edge_segment_commands = edge_segment_commands_mod.EdgeSegmentCommands(EdgeSegmentCommandOps);

const NodeTextRunGcCommandOps = struct {
    pub fn parseDbArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
        min_rest: usize,
        max_rest: usize,
    ) !database_arguments.Parsed {
        return parseDbArgs(allocator, io, args, 2, min_rest, max_rest, true);
    }

    pub const Context = struct {
        cli_lock: CliStoreLock,
        store: storage.Store,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !Context {
            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            const store = try storage.Store.open(allocator, io, db_path);
            return .{ .cli_lock = cli_lock, .store = store };
        }

        pub fn deinit(self: *Context) void {
            self.store.deinit();
            self.cli_lock.deinit();
            self.* = undefined;
        }

        pub fn gc(self: *Context) !storage.NodeTextRunGcResult {
            return self.store.gcUnreferencedNodeTextRunsWithProcessLeases();
        }
    };
};

const node_text_run_gc_command = node_text_run_gc_command_mod.NodeTextRunGcCommand(NodeTextRunGcCommandOps);

fn runBenchCommand(args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !void {
    const parsed = try benchmark_contract.parseArguments(args);
    if (try existingTinyKgStorePath(allocator, io, parsed.db_path)) return error.AlreadyExists;
    const output = try benchmark_execution.run(allocator, io, parsed);
    defer allocator.free(output);
    try writer.writeAll(output);
}

fn runMarkdownDocEditBenchCommand(args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !void {
    const parsed = try parseMarkdownDocEditBenchArgs(args);
    const output = try renderMarkdownDocEditBenchOutput(allocator, io, parsed);
    defer allocator.free(output);
    try writer.writeAll(output);
}

/// Concrete façade backend for the complete Governance command owner.
/// The owner controls admission, lifecycle sequencing, scanning and report
/// publication; this adapter retains only shared CLI/store/schema identities.
const cliStoreDirBytes = storeDirBytes;
const cliStoreFileSize = storeFileSize;
const cliIsDeletedNodeTombstone = isDeletedNodeTombstone;
const cliSchemaEdgeEndpointCheck = schemaEdgeEndpointCheck;

const GovernanceCommandOps = struct {
    pub fn parseDbArguments(
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !database_arguments.Parsed {
        return parseDbArgs(allocator, io, args, 2, 0, 4, true);
    }

    pub const Context = struct {
        loaded_schema: ?schema.Registry,
        cli_lock: CliStoreLock,
        store: storage.Store,
        embedded_catalog: ?catalog_mod.Catalog,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            db_path: []const u8,
            schema_path: ?[]const u8,
            profiles: ?[]const u8,
        ) !Context {
            var loaded_schema: ?schema.Registry = if (schema_path != null or profiles != null)
                try loadSchemaRegistryFromSchemaArg(allocator, io, .{
                    .positionals = &.{},
                    .schema_path = schema_path,
                    .profiles = profiles,
                })
            else
                null;
            errdefer if (loaded_schema) |*loaded_registry| loaded_registry.deinit();

            const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
            errdefer cli_lock.deinit();
            var store = try storage.Store.open(allocator, io, db_path);
            errdefer store.deinit();
            var embedded_catalog: ?catalog_mod.Catalog = if (loaded_schema == null) try store.readCatalog() else null;
            errdefer if (embedded_catalog) |*cat| cat.deinit();

            return .{
                .loaded_schema = loaded_schema,
                .cli_lock = cli_lock,
                .store = store,
                .embedded_catalog = embedded_catalog,
            };
        }

        pub fn deinit(self: *Context) void {
            if (self.embedded_catalog) |*cat| cat.deinit();
            self.store.deinit();
            self.cli_lock.deinit();
            if (self.loaded_schema) |*loaded_registry| loaded_registry.deinit();
            self.* = undefined;
        }

        pub fn storeHandle(self: *Context) storage.Store {
            return self.store;
        }

        pub fn schemaRegistry(self: *Context) ?schema.Registry {
            if (self.loaded_schema) |loaded_registry| return loaded_registry;
            if (self.embedded_catalog) |cat| {
                if (catalogHasApplicationSchema(cat)) return cat.registry;
            }
            return null;
        }
    };

    pub fn storeDirBytes(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !u64 {
        return cliStoreDirBytes(allocator, io, db_path);
    }

    pub fn storeFileSize(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8, file_name: []const u8) !?u64 {
        return cliStoreFileSize(allocator, io, db_path, file_name);
    }

    pub fn readDeferredBasedOnPairs(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !MetaknowDeferredBasedOnSidecarPairs {
        return readMetaknowDeferredBasedOnSidecarForwardPairs(allocator, io, db_path);
    }

    pub fn isDeletedNodeTombstone(node: storage.StoredNode) bool {
        return cliIsDeletedNodeTombstone(node);
    }

    pub fn visibleNodeText(text: []const u8) []const u8 {
        return markdownProjectionVisibleText(text);
    }

    pub fn nodeTextCharLimit() usize {
        return node_text_char_limit;
    }

    pub fn relationClassNamespace(name: []const u8) ?schema.RelationClass {
        return schemaRelationClassNamespace(name);
    }

    pub fn schemaEdgeEndpointCheck(
        node_view: *storage.Store.NodeRecordView,
        registry_value: schema.Registry,
        src: core.NodeId,
        rel: core.RelKind,
        dst: core.NodeId,
    ) !SchemaEdgeEndpointCheck {
        return cliSchemaEdgeEndpointCheck(node_view, registry_value, src, rel, dst);
    }
};

const governance_command = governance_command_mod.GovernanceCommand(GovernanceCommandOps);

const RootCommandDispatchPipelineOps = struct {
    pub const CommandValue = Command;
    pub const LifecycleMaintenanceSummaryValue = LifecycleMaintenanceSummary;
    pub const MaintenanceContextValue = RootLifecycleMaintenanceContext;
    pub const schemaCommandsValue = schema_commands;
    pub const schemaReconcileCommandValue = schema_reconcile_command;
    pub const propertyCommandsValue = property_commands;
    pub const containTreeMigrationCommandValue = contain_tree_migration_command;
    pub const edgeMutationCommandsValue = edge_mutation_commands;
    pub const edgeSegmentCommandsValue = edge_segment_commands;
    pub const nodeTextRunGcCommandValue = node_text_run_gc_command;
    pub const graphTraversalCommandsValue = graph_traversal_commands;
    pub const contextCommandsValue = context_commands;
    pub const nodeReadCommandsValue = node_read_commands;
    pub const nodeMutationCommandsValue = node_mutation_commands;
    pub const idempotentNodeCommandsValue = idempotent_node_commands;
    pub const storeCopyCommandsValue = store_copy_commands;
    pub const storeInterchangeCommandsValue = store_interchange_commands;
    pub const applyCommandValue = apply_command;
    pub const metaknowReplayImportCommandValue = metaknow_replay_import_command;
    pub const agentWriteCommandValue = agent_write_command;
    pub const schemaScopeCommandValue = schema_scope_command;
    pub const findCommandValue = find_command;
    pub const searchCommandValue = search_command;
    pub const queryCommandValue = query_command;
    pub const markdownImportCommandsValue = markdown_import_commands;
    pub const markdownRenderCommandValue = markdown_render_command;
    pub const markdownOrphanGcCommandValue = markdown_orphan_gc_command;
    pub const storeInitCommandValue = store_init_command;
    pub const rebuildTextCommandValue = rebuild_text_command;
    pub const storeUpgradeCommandValue = store_upgrade_command;
    pub const migrateStoreV2CommandValue = migrate_store_v2_command;
    pub const storeInspectionCommandsValue = store_inspection_commands;
    pub const recentCommandsValue = recent_commands;
    pub const taskReadCommandsValue = task_read_commands;
    pub const taskLeaseCommandsValue = task_lease_commands;
    pub const taskCloseCommandValue = task_close_command;
    pub const taskEventCommandValue = task_event_command;
    pub const governanceCommandValue = governance_command;
    pub const segmentCommandsValue = segment_commands;
    pub const versionCliValue = version.cli;
    pub const versionMetadataJsonValue = version.metadata_json;

    pub fn parseCommand(value: ?[]const u8) !Command {
        return command_mod.parseCommand(value);
    }

    pub fn writeHelp(writer: anytype) !void {
        return help_mod.writeHelp(writer);
    }

    pub fn runBench(args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !void {
        return runBenchCommand(args, writer, allocator, io);
    }

    pub fn runMarkdownDocEditBench(args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !void {
        return runMarkdownDocEditBenchCommand(args, writer, allocator, io);
    }

    pub fn parseMaintenanceArguments(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !ParsedLifecycleMaintenanceArgs {
        return parseLifecycleMaintenanceArgs(allocator, io, args);
    }

    pub fn startTimer(io: std.Io) u128 {
        return monotonicNs(io);
    }

    pub fn elapsedSince(io: std.Io, start_ns: u128) u128 {
        return elapsedNs(io, start_ns);
    }

    pub fn sleepForMillis(io: std.Io, millis: u64) !void {
        return sleepMillis(io, millis);
    }

    pub fn recordCycle(summary: *LifecycleMaintenanceSummary, made_progress: bool) !void {
        return summary.recordCycle(made_progress);
    }
};

const root_command_dispatch_pipeline = root_command_dispatch_pipeline_mod.RootCommandDispatchPipeline(RootCommandDispatchPipelineOps);

pub fn run(args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !void {
    return root_command_dispatch_pipeline.run(args, writer, allocator, io);
}
fn taskReadyForOpenTask(allocator: std.mem.Allocator, store: storage.Store, task_id: core.NodeId) !task.ReadyState {
    const now_ns = try u128ToU64(persistentNowNs(store.io));
    const lifecycle = try task.statusWithPersistentStoreAt(allocator, store, task_id, now_ns);
    if (lifecycle.isTerminal()) return error.InvalidTaskTransition;
    return try task.readyStateWithPersistentStoreAt(allocator, store, task_id, now_ns);
}

const NodeReadRenderOptions = struct {
    format: CliOutputFormat = .text,
    meta: bool = false,
    include_text: bool = false,
};

const CliOutputFormat = enum { text, json };

const ParsedContextArgs = struct {
    db_path: []const u8,
    query: []u8,
    owned_db_path: ?[]u8 = null,
    task_id: ?core.NodeId = null,
    root_node_id: ?core.NodeId = null,
    profile: TextBudgetProfile = .agent_memory,
    limit: usize = 5,
    include_history: bool = false,
    format: CliOutputFormat = .json,
    meta: bool = false,
    max_postings_scanned: usize = 20_000,
    timeout_ms: u64 = 250,
    neighbor_depth: usize = 1,
    max_nodes: usize = 12,
    max_edges: usize = 24,
    max_chars: usize = 200_000,
    markdown_preview_lines: usize = 8,

    pub fn deinit(self: ParsedContextArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.query);
        if (self.owned_db_path) |path| allocator.free(path);
    }
};

fn queryCatalogCoversSchemaReferences(registry: schema.Registry, ast_query: ql.ast.Query) bool {
    if (ast_query.text_pattern) |pattern| {
        if (pattern.type_label) |label| {
            if (registry.findNodeType(label) == null) return false;
        }
    }
    if (ast_query.pattern.start.type_label) |label| {
        if (registry.findNodeType(label) == null) return false;
    }
    for (ast_query.pattern.segments) |segment| {
        if (segment.edge.rel_label) |label| {
            if (registry.findRelationType(label) == null) return false;
        }
        if (segment.right.type_label) |label| {
            if (registry.findNodeType(label) == null) return false;
        }
    }

    // A pre-v3 embedded catalog can describe the task type without declaring
    // the v3 lifecycle properties.  Selecting schema-aware typechecking from
    // labels alone would then reject compatibility queries such as
    // `WHERE n.status = "open"`.  Only use the embedded catalog when it can
    // resolve every property reference whose variable has a concrete type.
    for (ast_query.where_predicates) |predicate| {
        if (queryNodeTypeId(registry, ast_query, predicate.var_name)) |type_id| {
            if (registry.nodePropertyByTypeId(type_id, predicate.property) == null) return false;
            continue;
        }
        if (queryRelationTypeId(registry, ast_query, predicate.var_name)) |type_id| {
            if (registry.relationPropertyByTypeId(type_id, predicate.property) == null) return false;
        }
    }
    for (ast_query.returns) |projection| switch (projection) {
        .property => |property| {
            if (queryNodeTypeId(registry, ast_query, property.var_name)) |type_id| {
                if (registry.nodePropertyByTypeId(type_id, property.property) == null) return false;
            }
        },
        else => {},
    };
    return true;
}

fn queryNodeTypeId(registry: schema.Registry, ast_query: ql.ast.Query, var_name: []const u8) ?u16 {
    if (ast_query.text_pattern) |pattern| {
        if (std.mem.eql(u8, pattern.var_name, var_name)) {
            if (pattern.type_label) |label| return registry.findNodeType(label);
            if (pattern.kind) |kind| return @intFromEnum(kind);
        }
    }
    if (std.mem.eql(u8, ast_query.pattern.start.var_name, var_name)) {
        if (ast_query.pattern.start.type_label) |label| return registry.findNodeType(label);
        if (ast_query.pattern.start.kind) |kind| return @intFromEnum(kind);
    }
    for (ast_query.pattern.segments) |segment| {
        if (!std.mem.eql(u8, segment.right.var_name, var_name)) continue;
        if (segment.right.type_label) |label| return registry.findNodeType(label);
        if (segment.right.kind) |kind| return @intFromEnum(kind);
    }
    return null;
}

fn queryRelationTypeId(registry: schema.Registry, ast_query: ql.ast.Query, var_name: []const u8) ?u16 {
    for (ast_query.pattern.segments) |segment| {
        const edge_var = segment.edge.var_name orelse continue;
        if (!std.mem.eql(u8, edge_var, var_name)) continue;
        if (segment.edge.rel_label) |label| return registry.findRelationType(label);
        if (segment.edge.rel) |rel| return @intFromEnum(rel);
    }
    return null;
}

fn catalogHasApplicationSchema(cat: catalog_mod.Catalog) bool {
    return cat.profiles.items.len != 0 or
        cat.registry.nodeTypeCount() != 2 or
        cat.registry.relationTypeCount() != 2;
}

test "embedded catalog selection requires property coverage" {
    var registry = schema.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.addDefaultTypes();
    try registry.addBuiltinProfileForSchemaVersion(.agent_dag, 2);

    const status_query = try ql.parser.parse(std.testing.allocator, "MATCH (n:task) WHERE n.status = \"open\" RETURN n.text");
    defer ql.ast.freeQuery(std.testing.allocator, status_query);
    try std.testing.expect(!queryCatalogCoversSchemaReferences(registry, status_query));

    const text_query = try ql.parser.parse(std.testing.allocator, "MATCH (n:task) WHERE n.text = \"open\" RETURN n.text");
    defer ql.ast.freeQuery(std.testing.allocator, text_query);
    try std.testing.expect(queryCatalogCoversSchemaReferences(registry, text_query));

    try registry.setTaskLifecycleProperties();
    try std.testing.expect(queryCatalogCoversSchemaReferences(registry, status_query));
}

test "migration property stream keeps the latest physical version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "store" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    const node_id = try store.addNode(.task, "property stream task");
    try store.appendPropertiesBatch(std.testing.allocator, &.{.{
        .owner = .{ .node = node_id },
        .key = "summary",
        .value = .{ .string = "base" },
    }});
    _ = try store.upsertPropertiesBatch(std.testing.allocator, &.{.{
        .owner = .{ .node = node_id },
        .key = "summary",
        .value = .{ .string = "delta-one" },
    }});
    _ = try store.upsertPropertiesBatch(std.testing.allocator, &.{.{
        .owner = .{ .node = node_id },
        .key = "summary",
        .value = .{ .string = "delta-two" },
    }});

    var registry = schema.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.addKernelTypes();
    try registry.addBuiltinProfile(.agent_dag);
    var node_keys = try MigrationPropertyKeys.init(std.testing.allocator, registry, registry, .node);
    defer node_keys.deinit();
    var edge_keys = try MigrationPropertyKeys.init(std.testing.allocator, registry, registry, .edge);
    defer edge_keys.deinit();
    var spool = try MigrationPropertySpool.build(
        std.testing.allocator,
        std.testing.io,
        root_path,
        store,
        &node_keys,
        &edge_keys,
    );
    defer spool.deinit();
    var stream = try MigrationPropertyStream.init(&spool);
    defer stream.deinit();
    var snapshot = try stream.snapshotForOwners(1, &.{node_id.toInt()});
    defer snapshot.deinit(std.testing.allocator);
    try stream.finish();

    var summary_count: usize = 0;
    for (snapshot.entries) |entry| {
        if (entry.key_hash != storage.propertyKeyHashForLookup("summary")) continue;
        summary_count += 1;
        try std.testing.expectEqual(storage.PropertySnapshotValueKind.string, entry.value_kind);
        try std.testing.expectEqualStrings("delta-two", entry.string_value);
    }
    try std.testing.expectEqual(@as(usize, 1), summary_count);
}

test "migration property spools preserve selected historical custom keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "store" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    const node_id = try store.addNode(.concept, "custom property owner");
    try store.setNodeStringProperty(std.testing.allocator, node_id, "historical_custom_key", "kept");

    var registry = schema.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.addKernelTypes();
    var node_keys = try MigrationPropertyKeys.init(std.testing.allocator, registry, registry, .node);
    defer node_keys.deinit();
    var edge_keys = try MigrationPropertyKeys.init(std.testing.allocator, registry, registry, .edge);
    defer edge_keys.deinit();

    var filtered = try MigrationPropertySpool.build(
        std.testing.allocator,
        std.testing.io,
        root_path,
        store,
        &node_keys,
        &edge_keys,
    );
    defer filtered.deinit();
    var filtered_stream = try MigrationPropertyStream.init(&filtered);
    defer filtered_stream.deinit();
    try std.testing.expect((try filtered_stream.nextEffectiveUncached()) == null);

    var all = try MigrationPropertySpool.buildAll(
        std.testing.allocator,
        std.testing.io,
        root_path,
        store,
        &node_keys,
        &edge_keys,
    );
    defer all.deinit();
    var all_stream = try MigrationPropertyStream.init(&all);
    defer all_stream.deinit();
    const maybe_custom = try all_stream.nextEffectiveUncached();
    try std.testing.expect(maybe_custom != null);
    var custom = maybe_custom.?;
    defer custom.deinit(std.testing.allocator);
    try std.testing.expectEqual(node_id.toInt(), custom.owner_id);
    try std.testing.expectEqual(storage.propertyKeyHashForLookup("historical_custom_key"), custom.key_hash);
    try std.testing.expectEqualStrings("kept", custom.string_value);
    try std.testing.expect((try all_stream.nextEffectiveUncached()) == null);

    var target_builder = try MigrationTargetPropertySpoolBuilder.init(
        std.testing.allocator,
        std.testing.io,
        root_path,
        &node_keys,
        &edge_keys,
    );
    defer target_builder.deinit();
    try target_builder.appendBatch(&.{.{
        .owner = .{ .node = node_id },
        .key = "historical_custom_key",
        .value = .{ .string = "kept" },
    }});
    var target_spool = try target_builder.finish();
    defer target_spool.deinit();
    try std.testing.expectEqual(@as(u64, 1), target_spool.record_count);
}

test "migration property runs use bounded fan-in merge" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];

    var paths = std.ArrayList([]u8).empty;
    var paths_transferred = false;
    defer if (!paths_transferred) {
        for (paths.items) |path| {
            std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
            std.testing.allocator.free(path);
        }
        paths.deinit(std.testing.allocator);
    };
    const run_count = migration_property_merge_fan_in + 6;
    try paths.ensureTotalCapacityPrecise(std.testing.allocator, run_count);
    for (0..run_count) |index| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/input-{d}.run", .{ root_path, index });
        errdefer std.testing.allocator.free(path);
        var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .read = true, .truncate = true, .exclusive = true });
        defer file.close(std.testing.io);
        const owner_id: u64 = @intCast(run_count - index);
        const record = MigrationPropertySpoolRecord{
            .owner_kind = 1,
            .value_kind = .uint,
            .owner_id = owner_id,
            .key_hash = storage.propertyKeyHashForLookup("task_recorded_ns"),
            .version = 1,
            .uint_value = owner_id * 10,
        };
        var encoded: [migration_property_spool_record_len]u8 = undefined;
        try record.encode(&encoded);
        try file.writePositionalAll(std.testing.io, &encoded, 0);
        paths.appendAssumeCapacity(path);
    }

    try coalesceMigrationPropertyRuns(std.testing.allocator, std.testing.io, root_path, 999, .effective_owner, &paths);
    try std.testing.expect(paths.items.len <= migration_property_merge_fan_in);
    try std.testing.expectEqual(@as(usize, 2), paths.items.len);

    const values_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "values" });
    var values_file = try std.Io.Dir.cwd().createFile(std.testing.io, values_path, .{ .read = true, .truncate = true, .exclusive = true });
    values_file.close(std.testing.io);
    var spool = MigrationPropertySpool{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .values_path = values_path,
        .run_paths = try paths.toOwnedSlice(std.testing.allocator),
        .sort_order = .effective_owner,
        .record_count = run_count,
    };
    paths_transferred = true;
    defer spool.deinit();
    var stream = try MigrationPropertyStream.init(&spool);
    defer stream.deinit();
    var owner_ids: [run_count]u64 = undefined;
    for (&owner_ids, 0..) |*owner_id, index| owner_id.* = index + 1;
    var snapshot = try stream.snapshotForOwners(1, &owner_ids);
    defer snapshot.deinit(std.testing.allocator);
    try stream.finish();
    try std.testing.expectEqual(@as(usize, run_count), snapshot.entries.len);
    for (snapshot.entries, 0..) |entry, index| {
        try std.testing.expectEqual(index + 1, entry.owner.node.toInt());
        try std.testing.expectEqual((index + 1) * 10, entry.uint_value);
    }
}

test "migration edge spool coalesces runs with bounded fan-in" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];

    var paths = std.ArrayList([]u8).empty;
    var paths_transferred = false;
    defer if (!paths_transferred) {
        for (paths.items) |path| {
            std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
            std.testing.allocator.free(path);
        }
        paths.deinit(std.testing.allocator);
    };
    const run_count = migration_edge_merge_fan_in + 6;
    try paths.ensureTotalCapacityPrecise(std.testing.allocator, run_count);
    for (0..run_count) |index| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/edge-{d}.run", .{ root_path, index });
        errdefer std.testing.allocator.free(path);
        var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .read = true, .truncate = true, .exclusive = true });
        defer file.close(std.testing.io);
        const edge_id: u64 = @intCast(run_count - index);
        var bytes: [migration_edge_spool_record_len]u8 = undefined;
        try encodeMigrationEdgeRecord(.{
            .src = 1,
            .dst = edge_id + 1,
            .edge_id = edge_id,
            .rel = @intFromEnum(core.RelKind.contain),
        }, &bytes);
        try file.writePositionalAll(std.testing.io, &bytes, 0);
        paths.appendAssumeCapacity(path);
    }

    try coalesceMigrationEdgeRuns(std.testing.allocator, std.testing.io, root_path, 777, &paths);
    try std.testing.expect(paths.items.len <= migration_edge_merge_fan_in);
    try std.testing.expectEqual(@as(usize, 2), paths.items.len);

    var spool = MigrationEdgeSpool{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .run_paths = try paths.toOwnedSlice(std.testing.allocator),
        .record_count = run_count,
    };
    paths_transferred = true;
    defer spool.deinit();
    var stream = try MigrationEdgeStream.init(&spool);
    defer stream.deinit();
    var expected_id: u64 = 1;
    while (try stream.next()) |record| : (expected_id += 1) {
        try std.testing.expectEqual(expected_id, record.edge_id);
    }
    try std.testing.expectEqual(@as(u64, run_count + 1), expected_id);
}

const default_db_path = ".tinykg";
const default_db_env_name = "TINYKG_STORE";
const cli_store_lock_suffix = ".tinykg-cli.lock";
const backup_publish_lock_suffix = ".tinykg-backup.lock";
const backup_staging_suffix = ".tinykg-backup.tmp";
const backup_manifest_file = "tinykg-backup-manifest.txt";
const backup_transaction_marker_file = ".tinykg-backup-transaction.json";
const backup_transaction_marker_format = "tinykg-backup-transaction-v3";
const backup_transaction_marker_legacy_format = "tinykg-backup-transaction-v2";
const restore_publish_lock_suffix = ".tinykg-restore.lock";
const restore_staging_suffix = ".tinykg-restore.tmp";
const restore_transaction_marker_file = ".tinykg-restore-transaction.json";
const restore_transaction_marker_format = "tinykg-restore-transaction-v2";
const restore_transaction_marker_legacy_format = "tinykg-restore-transaction-v1";
const import_publish_lock_suffix = ".tinykg-import.lock";
const import_staging_suffix = ".tinykg-import.tmp";
const import_transaction_marker_file = ".tinykg-import-transaction.json";
const import_transaction_marker_format = "tinykg-import-transaction-v2";
const import_transaction_marker_legacy_format = "tinykg-import-transaction-v1";
const export_publish_lock_suffix = ".tinykg-export.lock";
const export_backup_suffix = ".tinykg-export.backup";
const export_transaction_marker_file = ".tinykg-export-transaction";
const export_transaction_marker_magic = "tinykg-export-transaction-v1\n";
const store_migration_publish_lock_suffix = ".tinykg-migrate-store-v2.lock";
const store_migration_staging_suffix = ".tinykg-migrate-store-v2.tmp";
const store_migration_transaction_marker_file = ".tinykg-migrate-store-v2-transaction.json";
const store_migration_transaction_marker_format = "tinykg-migrate-store-v2-transaction-v3";
const store_migration_transaction_marker_legacy_format = "tinykg-migrate-store-v2-transaction-v2";
const schema_migration_publish_lock_suffix = ".tinykg-schema-migrate.lock";
const schema_migration_staging_suffix = ".tinykg-schema-migrate.tmp";
const schema_migration_transaction_marker_file = ".tinykg-schema-migrate-transaction";
const schema_migration_transaction_marker_format = "tinykg-schema-migrate-transaction-v3";
const schema_migration_transaction_marker_legacy_format = "tinykg-schema-migrate-transaction-v2";
const markdown_bootstrap_publish_lock_suffix = ".tinykg-markdown-bootstrap.lock";
const markdown_bootstrap_staging_suffix = ".tinykg-markdown-bootstrap.tmp";
const markdown_bootstrap_transaction_suffix = ".tinykg-markdown-bootstrap-transaction";
const markdown_bootstrap_transaction_format = "tinykg-markdown-bootstrap-transaction-v1";
const cli_store_lock_owner_file = "owner";
const cli_store_lock_poll_ms: u64 = 100;
const cli_store_lock_timeout_ms: u64 = 30_000;
const CliStoreLockProcessId = u64;

fn cliStoreLockPath(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) ![]u8 {
    if (try existingTinyKgStorePath(allocator, io, db_path)) {
        return try std.fs.path.join(allocator, &.{ db_path, cli_store_lock_suffix });
    }
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ db_path, cli_store_lock_suffix });
}

fn currentCliStoreLockProcessId() CliStoreLockProcessId {
    return process_liveness.currentId();
}

fn cliStoreLockProcessIsAlive(pid: CliStoreLockProcessId) bool {
    return process_liveness.isAlive(pid);
}

fn cliStoreLockOwnerPath(allocator: std.mem.Allocator, lock_path: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &.{ lock_path, cli_store_lock_owner_file });
}

fn writeCliStoreLockOwner(allocator: std.mem.Allocator, io: std.Io, lock_path: []const u8) !void {
    const owner_path = try cliStoreLockOwnerPath(allocator, lock_path);
    defer allocator.free(owner_path);
    const content = try std.fmt.allocPrint(
        allocator,
        "tinykg-cli-lock-v1\npid={d}\n",
        .{currentCliStoreLockProcessId()},
    );
    defer allocator.free(content);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = owner_path,
        .data = content,
        .flags = .{ .truncate = true },
    });
}

fn parseCliStoreLockOwner(content: []const u8) ?CliStoreLockProcessId {
    var lines = std.mem.splitScalar(u8, content, '\n');
    const magic = lines.next() orelse return null;
    const pid_line = lines.next() orelse return null;
    if (!std.mem.eql(u8, magic, "tinykg-cli-lock-v1")) return null;
    if (!std.mem.startsWith(u8, pid_line, "pid=")) return null;
    return std.fmt.parseInt(CliStoreLockProcessId, pid_line["pid=".len..], 10) catch null;
}

fn removeStaleCliStoreLockIfSafe(allocator: std.mem.Allocator, io: std.Io, lock_path: []const u8, allow_ownerless: bool) !bool {
    const owner_path = try cliStoreLockOwnerPath(allocator, lock_path);
    defer allocator.free(owner_path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, owner_path, allocator, .limited(1024)) catch |err| switch (err) {
        error.FileNotFound => {
            if (allow_ownerless) {
                try std.Io.Dir.cwd().deleteTree(io, lock_path);
                return true;
            }
            return false;
        },
        error.StreamTooLong => {
            try std.Io.Dir.cwd().deleteTree(io, lock_path);
            return true;
        },
        else => |e| return e,
    };
    defer allocator.free(content);
    const pid = parseCliStoreLockOwner(content) orelse {
        if (allow_ownerless) {
            try std.Io.Dir.cwd().deleteTree(io, lock_path);
            return true;
        }
        return false;
    };
    if (cliStoreLockProcessIsAlive(pid)) return false;
    try std.Io.Dir.cwd().deleteTree(io, lock_path);
    return true;
}

const CliStoreLock = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    lock_path: []u8,

    pub fn acquire(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !CliStoreLock {
        const lock_path = try cliStoreLockPath(allocator, io, db_path);
        return acquireOwnedPath(allocator, io, lock_path);
    }

    pub fn acquireAdjacent(allocator: std.mem.Allocator, io: std.Io, path: []const u8, suffix: []const u8) !CliStoreLock {
        const canonical_path = try canonicalProspectivePath(allocator, io, path);
        defer allocator.free(canonical_path);
        const parent_path = std.fs.path.dirname(canonical_path) orelse ".";
        try std.Io.Dir.cwd().createDirPath(io, parent_path);
        const lock_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ canonical_path, suffix });
        return acquireOwnedPath(allocator, io, lock_path);
    }

    fn acquireOwnedPath(allocator: std.mem.Allocator, io: std.Io, lock_path: []u8) !CliStoreLock {
        errdefer allocator.free(lock_path);

        var waited_ms: u64 = 0;
        while (true) {
            std.Io.Dir.cwd().createDir(io, lock_path, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    const allow_ownerless = waited_ms >= cli_store_lock_timeout_ms;
                    if (try removeStaleCliStoreLockIfSafe(allocator, io, lock_path, allow_ownerless)) {
                        waited_ms = 0;
                        continue;
                    }
                    if (waited_ms >= cli_store_lock_timeout_ms) return error.Timeout;
                    try sleepMillis(io, cli_store_lock_poll_ms);
                    waited_ms = std.math.add(u64, waited_ms, cli_store_lock_poll_ms) catch return error.RecordTooLarge;
                    continue;
                },
                else => |e| return e,
            };
            errdefer std.Io.Dir.cwd().deleteTree(io, lock_path) catch {};
            try writeCliStoreLockOwner(allocator, io, lock_path);
            return .{ .allocator = allocator, .io = io, .lock_path = lock_path };
        }
    }

    pub fn deinit(self: CliStoreLock) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.lock_path) catch {};
        self.allocator.free(self.lock_path);
    }

    /// A bootstrap store is locked while it still has its staging name.  Once
    /// the whole directory is atomically renamed, point cleanup at the lock's
    /// new location without releasing it in between.  This prevents ordinary
    /// store commands from observing the final path before publication and
    /// transaction-marker cleanup have completed.
    pub fn rebaseAfterParentRename(self: *CliStoreLock, final_lock_path: []u8) void {
        self.allocator.free(self.lock_path);
        self.lock_path = final_lock_path;
    }
};

test "cli store lock lives inside existing store directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    try store.createEmpty();

    const lock_path = try cliStoreLockPath(std.testing.allocator, std.testing.io, db_path);
    defer std.testing.allocator.free(lock_path);
    const expected = try std.fs.path.join(std.testing.allocator, &.{ db_path, cli_store_lock_suffix });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, lock_path);
}

test "cli store lock falls back beside missing store directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "new-kg" });
    defer std.testing.allocator.free(db_path);

    const lock_path = try cliStoreLockPath(std.testing.allocator, std.testing.io, db_path);
    defer std.testing.allocator.free(lock_path);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ db_path, cli_store_lock_suffix });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, lock_path);
}

test "cli store lock falls back beside non-store directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "plain-dir" });
    defer std.testing.allocator.free(db_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, db_path);

    const lock_path = try cliStoreLockPath(std.testing.allocator, std.testing.io, db_path);
    defer std.testing.allocator.free(lock_path);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ db_path, cli_store_lock_suffix });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, lock_path);
}

test "export publish lock remains adjacent across destination replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const destination = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "export" });
    defer std.testing.allocator.free(destination);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ destination, export_publish_lock_suffix });
    defer std.testing.allocator.free(expected);

    {
        const publish_lock = try CliStoreLock.acquireAdjacent(
            std.testing.allocator,
            std.testing.io,
            destination,
            export_publish_lock_suffix,
        );
        defer publish_lock.deinit();
        try std.testing.expectEqualStrings(expected, publish_lock.lock_path);
        try std.testing.expect(!try anyPathExists(std.testing.io, destination));
    }

    try std.Io.Dir.cwd().createDirPath(std.testing.io, destination);
    const sentinel_path = try std.fs.path.join(std.testing.allocator, &.{ destination, "sentinel" });
    defer std.testing.allocator.free(sentinel_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = sentinel_path,
        .data = "old export",
        .flags = .{ .truncate = true },
    });

    const publish_lock = try CliStoreLock.acquireAdjacent(
        std.testing.allocator,
        std.testing.io,
        destination,
        export_publish_lock_suffix,
    );
    defer publish_lock.deinit();
    try std.testing.expectEqualStrings(expected, publish_lock.lock_path);
    const sentinel = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, sentinel_path, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(sentinel);
    try std.testing.expectEqualStrings("old export", sentinel);
}

test "store migration publish lock remains adjacent after target creation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const target = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "target.kg" });
    defer std.testing.allocator.free(target);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ target, store_migration_publish_lock_suffix });
    defer std.testing.allocator.free(expected);

    {
        const publish_lock = try CliStoreLock.acquireAdjacent(
            std.testing.allocator,
            std.testing.io,
            target,
            store_migration_publish_lock_suffix,
        );
        defer publish_lock.deinit();
        try std.testing.expectEqualStrings(expected, publish_lock.lock_path);
    }
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, target);
    defer store.deinit();
    try store.createEmpty();
    const publish_lock = try CliStoreLock.acquireAdjacent(
        std.testing.allocator,
        std.testing.io,
        target,
        store_migration_publish_lock_suffix,
    );
    defer publish_lock.deinit();
    try std.testing.expectEqualStrings(expected, publish_lock.lock_path);
}

test "backup publish lock remains adjacent after target creation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const target = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "backup.kg" });
    defer std.testing.allocator.free(target);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ target, backup_publish_lock_suffix });
    defer std.testing.allocator.free(expected);

    {
        const publish_lock = try CliStoreLock.acquireAdjacent(
            std.testing.allocator,
            std.testing.io,
            target,
            backup_publish_lock_suffix,
        );
        defer publish_lock.deinit();
        try std.testing.expectEqualStrings(expected, publish_lock.lock_path);
    }
    try std.Io.Dir.cwd().createDir(std.testing.io, target, .default_dir);
    const publish_lock = try CliStoreLock.acquireAdjacent(
        std.testing.allocator,
        std.testing.io,
        target,
        backup_publish_lock_suffix,
    );
    defer publish_lock.deinit();
    try std.testing.expectEqualStrings(expected, publish_lock.lock_path);
}

test "import publish lock remains adjacent after target creation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const target = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "imported.kg" });
    defer std.testing.allocator.free(target);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ target, import_publish_lock_suffix });
    defer std.testing.allocator.free(expected);
    {
        const publish_lock = try CliStoreLock.acquireAdjacent(std.testing.allocator, std.testing.io, target, import_publish_lock_suffix);
        defer publish_lock.deinit();
        try std.testing.expectEqualStrings(expected, publish_lock.lock_path);
    }
    try std.Io.Dir.cwd().createDir(std.testing.io, target, .default_dir);
    const publish_lock = try CliStoreLock.acquireAdjacent(std.testing.allocator, std.testing.io, target, import_publish_lock_suffix);
    defer publish_lock.deinit();
    try std.testing.expectEqualStrings(expected, publish_lock.lock_path);
}

test "restore publish lock remains adjacent after target creation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const target = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "restored.kg" });
    defer std.testing.allocator.free(target);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ target, restore_publish_lock_suffix });
    defer std.testing.allocator.free(expected);
    {
        const publish_lock = try CliStoreLock.acquireAdjacent(std.testing.allocator, std.testing.io, target, restore_publish_lock_suffix);
        defer publish_lock.deinit();
        try std.testing.expectEqualStrings(expected, publish_lock.lock_path);
    }
    try std.Io.Dir.cwd().createDir(std.testing.io, target, .default_dir);
    const publish_lock = try CliStoreLock.acquireAdjacent(std.testing.allocator, std.testing.io, target, restore_publish_lock_suffix);
    defer publish_lock.deinit();
    try std.testing.expectEqualStrings(expected, publish_lock.lock_path);
}

test "export publication recovers durable backup without deleting foreign destination" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const destination = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "export" });
    defer std.testing.allocator.free(destination);
    const backup = try exportBackupPath(std.testing.allocator, destination);
    defer std.testing.allocator.free(backup);

    try std.Io.Dir.cwd().createDir(std.testing.io, destination, .default_dir);
    const old_sentinel = try std.fs.path.join(std.testing.allocator, &.{ destination, "old" });
    defer std.testing.allocator.free(old_sentinel);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = old_sentinel, .data = "old", .flags = .{ .truncate = true } });

    // Crash after old destination -> stable backup, before staging publish.
    try renamePath(std.testing.io, destination, backup);
    try std.testing.expectEqual(
        ExportPublicationRecovery.none,
        try recoverExportPublication(std.testing.allocator, std.testing.io, destination, backup),
    );
    try std.testing.expect(try fileExists(std.testing.io, old_sentinel));
    try std.testing.expect(!try anyPathExists(std.testing.io, backup));

    // Crash after marked staging was promoted, before old backup cleanup.
    const staging = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "staging" });
    defer std.testing.allocator.free(staging);
    try std.Io.Dir.cwd().createDir(std.testing.io, staging, .default_dir);
    const new_sentinel_staging = try std.fs.path.join(std.testing.allocator, &.{ staging, "new" });
    defer std.testing.allocator.free(new_sentinel_staging);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = new_sentinel_staging, .data = "new", .flags = .{ .truncate = true } });
    try writeExportTransactionMarker(std.testing.allocator, std.testing.io, staging);
    try renamePath(std.testing.io, destination, backup);
    try renamePath(std.testing.io, staging, destination);
    try std.testing.expectEqual(
        ExportPublicationRecovery.recovered,
        try recoverExportPublication(std.testing.allocator, std.testing.io, destination, backup),
    );
    const new_sentinel = try std.fs.path.join(std.testing.allocator, &.{ destination, "new" });
    defer std.testing.allocator.free(new_sentinel);
    try std.testing.expect(try fileExists(std.testing.io, new_sentinel));
    try std.testing.expect(!try anyPathExists(std.testing.io, backup));
    try std.testing.expect(!try exportTransactionMarkerPresent(std.testing.allocator, std.testing.io, destination));

    // A non-cooperating writer can occupy destination during the crash
    // window.  Without our marker it is foreign: retain both trees and fail.
    try renamePath(std.testing.io, destination, backup);
    try std.Io.Dir.cwd().createDir(std.testing.io, destination, .default_dir);
    const foreign_sentinel = try std.fs.path.join(std.testing.allocator, &.{ destination, "foreign" });
    defer std.testing.allocator.free(foreign_sentinel);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = foreign_sentinel, .data = "foreign", .flags = .{ .truncate = true } });
    try std.testing.expectError(
        error.ExportRestoreConflict,
        recoverExportPublication(std.testing.allocator, std.testing.io, destination, backup),
    );
    try std.testing.expect(try fileExists(std.testing.io, foreign_sentinel));
    const retained_new_sentinel = try std.fs.path.join(std.testing.allocator, &.{ backup, "new" });
    defer std.testing.allocator.free(retained_new_sentinel);
    try std.testing.expect(try fileExists(std.testing.io, retained_new_sentinel));
}

test "export post-commit cleanup reports state instead of propagating failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const destination = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "export" });
    defer std.testing.allocator.free(destination);
    try std.Io.Dir.cwd().createDir(std.testing.io, destination, .default_dir);
    try writeExportTransactionMarker(std.testing.allocator, std.testing.io, destination);

    // Inject the filesystem failure directly. Invalid-byte and missing-child
    // paths have different stdlib behavior across POSIX and Windows, while the
    // production contract here is simply that any post-commit delete failure
    // becomes cleanup_pending and leaves the durable marker intact.
    const FailingDelete = struct {
        fn deleteTree(io: std.Io, path: []const u8) error{AccessDenied}!void {
            _ = io;
            _ = path;
            return error.AccessDenied;
        }
    };
    try std.testing.expect(!cleanupExportPublicationAfterCommitWithDeleteTree(
        std.testing.allocator,
        std.testing.io,
        destination,
        "unused-backup-path",
        FailingDelete.deleteTree,
    ));
    try std.testing.expect(try exportTransactionMarkerPresent(std.testing.allocator, std.testing.io, destination));
    try std.testing.expect(cleanupExportPublicationAfterCommit(
        std.testing.allocator,
        std.testing.io,
        destination,
        null,
    ));
    try std.testing.expect(!try exportTransactionMarkerPresent(std.testing.allocator, std.testing.io, destination));
}

test "cli store lock removes dead owner lock inside existing store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    try store.createEmpty();

    const lock_path = try std.fs.path.join(std.testing.allocator, &.{ db_path, cli_store_lock_suffix });
    defer std.testing.allocator.free(lock_path);
    try std.Io.Dir.cwd().createDir(std.testing.io, lock_path, .default_dir);
    const owner_path = try cliStoreLockOwnerPath(std.testing.allocator, lock_path);
    defer std.testing.allocator.free(owner_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = owner_path,
        .data = "tinykg-cli-lock-v1\npid=2147483647\n",
        .flags = .{ .truncate = true },
    });

    const cli_lock = try CliStoreLock.acquire(std.testing.allocator, std.testing.io, db_path);
    defer cli_lock.deinit();
    try std.testing.expectEqualStrings(lock_path, cli_lock.lock_path);
}

test "cli store lock never reclaims the current process owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const lock_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "active.lock" });
    defer std.testing.allocator.free(lock_path);
    try std.Io.Dir.cwd().createDir(std.testing.io, lock_path, .default_dir);
    try writeCliStoreLockOwner(std.testing.allocator, std.testing.io, lock_path);

    try std.testing.expect(!try removeStaleCliStoreLockIfSafe(
        std.testing.allocator,
        std.testing.io,
        lock_path,
        true,
    ));
    try std.testing.expect(try anyPathExists(std.testing.io, lock_path));
}

fn defaultDbPathFromEnv(value: ?[]const u8) []const u8 {
    const path = value orelse return default_db_path;
    return if (path.len == 0) default_db_path else path;
}

fn defaultDbPath() []const u8 {
    return defaultDbPathFromEnv(envVar(default_db_env_name));
}

const ParsedMigrateStoreV2Args = migrate_store_v2_command_mod.Arguments;
const cli_deleted_node_tombstone_prefix = deleted_node_tombstone_prefix;

const StoreMigrationV2DataPlaneOps = struct {
    pub const Arguments = ParsedMigrateStoreV2Args;
    pub const Digest = ContentDigest;
    pub const OutputWriter = QueryOutputWriter;
    pub const PropertyBatch = MigrationPropertyBatch;
    pub const PropertyLookup = MigrationPropertyLookup;
    pub const PropertyKeys = MigrationPropertyKeys;
    pub const PropertySpool = MigrationPropertySpool;
    pub const PropertyStream = MigrationPropertyStream;
    pub const TargetPropertySpoolBuilder = MigrationTargetPropertySpoolBuilder;
    pub const RecoveryTargetLock = struct {
        inner: CliStoreLock,

        pub fn acquire(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !RecoveryTargetLock {
            return .{ .inner = try CliStoreLock.acquire(allocator, io, path) };
        }

        pub fn deinit(self: RecoveryTargetLock) void {
            self.inner.deinit();
        }
    };

    pub const schema_version_current = current_schema_version;
    pub const transaction_marker_file_name = store_migration_transaction_marker_file;
    pub const transaction_marker_format_name = store_migration_transaction_marker_format;
    pub const transaction_marker_legacy_format_name = store_migration_transaction_marker_legacy_format;
    pub const staging_suffix = store_migration_staging_suffix;
    pub const deleted_node_tombstone_prefix = cli_deleted_node_tombstone_prefix;

    pub const addBuiltinProfilesFn = addBuiltinProfilesFromCsvForSchemaVersion;
    pub const anyPathExistsFn = anyPathExists;
    pub const appendCatalogProfileLabelFn = appendCatalogProfileLabel;
    pub const appendSchemaDocumentProfilesToCatalogFn = appendSchemaDocumentProfilesToCatalog;
    pub const appendSchemaFileProfilesToCatalogFn = appendSchemaFileProfilesToCatalog;
    pub const backupStoreFn = backupStore;
    pub const canonicalPathsEqualFn = canonicalPathsEqual;
    pub const canonicalProspectivePathFn = canonicalProspectivePath;
    pub const catalogProfilesCsvAllocFn = catalogProfilesCsvAlloc;
    pub const catalogProfilesMatchCsvFn = catalogProfilesMatchCsv;
    pub const collectKnownEdgePropertiesFn = collectKnownEdgeProperties;
    pub const collectKnownNodePropertiesFn = collectKnownNodeProperties;
    pub const copyDeferredSidecarFn = copyMetaknowDeferredBasedOnSidecarForMigration;
    pub const createOwnedDirectoryFn = createOwnedDirectory;
    pub const existingTinyKgStorePathFn = existingTinyKgStorePath;
    pub const isDeletedNodeTombstoneFn = isDeletedNodeTombstone;
    pub const migrationPropertyKeyValidFn = migrationPropertyKeyValid;
    pub const migrationPropertySuppressedByTaskStatusV1Fn = migrationPropertySuppressedByTaskStatusV1;
    pub const pathsOverlapFn = pathsOverlap;
    pub const pathsOverlapForCopyTargetFn = pathsOverlapForCopyTarget;
    pub const persistentNowNsFn = persistentNowNs;
    pub const readStoreManifestSummaryFn = readStoreManifestSummary;
    pub const renamePathFn = renamePath;
    pub const storeContentIdentityFn = storeContentIdentity;
    pub const syncExportDirectoryTreeFn = syncExportDirectoryTree;
    pub const syncParentDirectoryFn = syncParentDirectory;
    pub const u128ToU64Fn = u128ToU64;
    pub const validateExistingBackupForSourceFn = validateExistingBackupForSource;
    pub const writeJsonStringFn = writeJsonString;
    pub const writeRecoverableTransactionMarkerFn = writeRecoverableTransactionMarker;
    pub const writeStoreManifestFn = writeStoreManifest;
};

const store_migration_v2_data_plane =
    store_migration_v2_data_plane_mod.StoreMigrationV2DataPlane(StoreMigrationV2DataPlaneOps);
const StoreMigrationV2Result = store_migration_v2_data_plane.Result;
const StoreMigrationV2TransactionExpectation = store_migration_v2_data_plane.TransactionExpectation;
const storeMigrationV2StagingPath = store_migration_v2_data_plane.stagingPath;
const storeMigrationV2TransactionMarkerPath = store_migration_v2_data_plane.transactionMarkerPath;
const writeStoreMigrationV2TransactionMarker = store_migration_v2_data_plane.writeTransactionMarker;
const recoverStoreMigrationV2Staging = store_migration_v2_data_plane.recoverStaging;
const migrationCatalog = store_migration_v2_data_plane.migrationCatalog;
const migrateStoreV2 = store_migration_v2_data_plane.execute;
const store_migration_node_batch_limit = store_migration_v2_data_plane.node_batch_limit;
const store_migration_edge_batch_limit = store_migration_v2_data_plane.edge_batch_limit;

fn executeStoreMigrationV2DataPlane(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: ParsedMigrateStoreV2Args,
) !StoreMigrationV2Result {
    return store_migration_v2_data_plane.execute(allocator, io, parsed);
}

const MigrationPropertyBatch = struct {
    allocator: std.mem.Allocator,
    writes: std.ArrayList(storage.PropertyPayloadWrite) = .empty,
    owned_keys: std.ArrayList([]u8) = .empty,
    owned_values: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) MigrationPropertyBatch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MigrationPropertyBatch) void {
        for (self.owned_keys.items) |key| self.allocator.free(key);
        for (self.owned_values.items) |value| self.allocator.free(value);
        self.owned_keys.deinit(self.allocator);
        self.owned_values.deinit(self.allocator);
        self.writes.deinit(self.allocator);
    }

    pub fn appendString(self: *MigrationPropertyBatch, owner: storage.PropertyOwner, key: []const u8, value: []const u8) !void {
        if (value.len == 0) return;
        try self.owned_keys.ensureUnusedCapacity(self.allocator, 1);
        try self.owned_values.ensureUnusedCapacity(self.allocator, 1);
        try self.writes.ensureUnusedCapacity(self.allocator, 1);
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        self.owned_keys.appendAssumeCapacity(owned_key);
        self.owned_values.appendAssumeCapacity(owned_value);
        self.writes.appendAssumeCapacity(.{
            .owner = owner,
            .key = owned_key,
            .value = .{ .string = owned_value },
        });
    }

    pub fn appendUint(self: *MigrationPropertyBatch, owner: storage.PropertyOwner, key: []const u8, value: u64) !void {
        try self.owned_keys.ensureUnusedCapacity(self.allocator, 1);
        try self.writes.ensureUnusedCapacity(self.allocator, 1);
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        self.owned_keys.appendAssumeCapacity(owned_key);
        self.writes.appendAssumeCapacity(.{
            .owner = owner,
            .key = owned_key,
            .value = .{ .uint = value },
        });
    }
};

fn exerciseMigrationPropertyBatchAllocationFailure(allocator: std.mem.Allocator) !void {
    var batch = MigrationPropertyBatch.init(allocator);
    defer batch.deinit();
    try batch.appendString(.{ .node = .fromInt(1) }, "status", "open");
    try batch.appendUint(.{ .node = .fromInt(1) }, "task_created_ns", 1);
}

test "migration property batch rolls back every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMigrationPropertyBatchAllocationFailure,
        .{},
    );
}

const MigrationPropertyLookupKey = struct {
    owner_kind: u8,
    owner_id: u64,
    key_hash: u64,
};

const MigrationPropertyLookup = struct {
    allocator: std.mem.Allocator,
    snapshot: storage.PropertySnapshot,
    positions: std.AutoHashMap(MigrationPropertyLookupKey, usize),

    pub fn initFromSnapshot(allocator: std.mem.Allocator, snapshot_input: storage.PropertySnapshot) !MigrationPropertyLookup {
        var snapshot = snapshot_input;
        errdefer snapshot.deinit(allocator);
        var positions = std.AutoHashMap(MigrationPropertyLookupKey, usize).init(allocator);
        errdefer positions.deinit();
        try positions.ensureTotalCapacity(std.math.cast(u32, snapshot.entries.len) orelse return error.RecordTooLarge);
        // The migration stream has already collapsed physical layers to one
        // latest-wins entry per owner/key. Index the bounded owner batch for
        // constant-time schema and lifecycle lookups.
        for (snapshot.entries, 0..) |entry, index| {
            const owner_kind: u8, const owner_id: u64 = switch (entry.owner) {
                .node => |id| .{ 1, id.toInt() },
                .edge => |id| .{ 2, id.toInt() },
            };
            try positions.put(.{
                .owner_kind = owner_kind,
                .owner_id = owner_id,
                .key_hash = entry.key_hash,
            }, index);
        }
        return .{ .allocator = allocator, .snapshot = snapshot, .positions = positions };
    }

    pub fn deinit(self: *MigrationPropertyLookup) void {
        self.positions.deinit();
        self.snapshot.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn get(self: *const MigrationPropertyLookup, owner: storage.PropertyOwner, key: []const u8) ?storage.PropertySnapshotEntry {
        const owner_kind: u8, const owner_id: u64 = switch (owner) {
            .node => |id| .{ 1, id.toInt() },
            .edge => |id| .{ 2, id.toInt() },
        };
        const index = self.positions.get(.{
            .owner_kind = owner_kind,
            .owner_id = owner_id,
            .key_hash = storage.propertyKeyHashForLookup(key),
        }) orelse return null;
        if (index >= self.snapshot.entries.len) return null;
        return self.snapshot.entries[index];
    }
};

const ParsedMarkdownDocEditBenchArgs = struct {
    db_path: []const u8,
    paragraphs: usize,
    edit_index: usize,
    repeat_local_edits: usize = 0,
    repeat_update_edits: usize = 0,
    agent_mixed_writes: usize = 0,
    max_edit_changed_records: ?usize = null,
    max_edit_elapsed_ns: ?u128 = null,
    max_edit_ns_per_paragraph: ?u128 = null,
    max_edit_to_initial_bps: ?u128 = null,
    max_repeat_edit_elapsed_ns: ?u128 = null,
    max_repeat_update_edit_elapsed_ns: ?u128 = null,
    max_render_local_subtree_elapsed_ns: ?u128 = null,
};

const ParsedSchemaArg = schema_arguments.Selection;

const ParsedNeighborsArgs = struct {
    node_id: []const u8,
    rel_label: ?[]const u8 = null,
    schema_path: ?[]const u8 = null,
    limit: ?usize = null,
    offset: usize = 0,
    include_history: bool = false,
    format: CliOutputFormat = .text,
    meta: bool = false,
    depth: usize = 1,
    max_nodes: ?usize = null,
    max_edges: ?usize = null,
    max_chars: ?usize = null,
};

const ParsedIncomingArgs = struct {
    node_id: []const u8,
    rel_label: ?[]const u8 = null,
    schema_path: ?[]const u8 = null,
    include_history: bool = false,
};

const ParsedTaskPacketArgs = struct {
    task_id: []const u8,
    limit: usize = 8,
    format: CliOutputFormat = .text,
    meta: bool = false,
    max_nodes: ?usize = null,
    max_edges: ?usize = null,
    max_chars: ?usize = null,
};

const ParsedTaskFrontierArgs = struct {
    root_id: []const u8,
    limit: usize = 8,
    mine: ?[]const u8 = null,
    unclaimed: bool = false,
};

const ParsedTaskAncestryArgs = struct {
    task_id: []const u8,
    depth: usize = 3,
    limit: usize = 16,
};

const ParsedTaskMetricsArgs = struct {
    root_id: []const u8,
    limit: usize = 64,
};

const TaskMutationArguments = task_mutation_arguments_mod.TaskMutationArguments;
const TaskEventType = TaskMutationArguments.EventType;

const MarkdownDocumentImportSpec = struct {
    db_path: []const u8,
    file_path: []const u8,
    durability: storage.DurabilityMode = .safe,
    source_label: ?[]const u8 = null,
};

const MarkdownAstImportSpec = struct {
    db_path: []const u8,
    ast_path: []const u8,
    format: []const u8 = "mdast",
    source_id: []const u8 = "stdin",
    durability: storage.DurabilityMode = .safe,
};

const ParsedRenderMarkdownDocumentArgs = struct {
    document_id: core.NodeId,
    render_root_id: core.NodeId,
    format: CliOutputFormat = .text,
    meta: bool = false,
    preview_lines: usize = 20,
    page_size_bytes: ?usize = null,
    cursor: usize = 0,
};

const ParsedAgentWriteArgs = agent_write_command.SingleArguments;
const ParsedAgentWriteJsonArgs = agent_write_command.JsonArguments;

const AgentWriteBatchJson = struct {
    items: []const AgentWriteBatchItemJson,
};

const AgentWriteBatchItemJson = struct {
    src: u64,
    rel: []const u8,
    dst: u64,
    document: ?u64 = null,
    section: ?u64 = null,
    agent_inbox: bool = false,
    text: []const u8,
    name: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    retrieval_hints: ?[]const u8 = null,
    render_rel: ?[]const u8 = null,
    fact_properties: ?AgentWriteEdgePropertiesJson = null,
    projection_properties: ?AgentWriteEdgePropertiesJson = null,
};

const AgentWriteEdgePropertiesJson = struct {
    markdown_attr: ?[]const u8 = null,
    render_flags: ?[]const u8 = null,
    source_span: ?[]const u8 = null,
    confidence: ?[]const u8 = null,
    created_by: ?[]const u8 = null,
    projection_edge_id: ?[]const u8 = null,
    fact_edge_id: ?[]const u8 = null,
};

const ParsedAddNodeArgs = governed_node_write_admission.ParsedAddNodeArgs;
const ParsedUpdateNodeArgs = governed_node_write_admission.ParsedUpdateNodeArgs;
const ParsedGovernNodeArgs = governed_node_write_admission.ParsedGovernNodeArgs;
const ParsedNodeTextGovernanceArgs = governed_node_write_admission.ParsedNodeTextGovernanceArgs;
const MetaknowReplayImportResult = struct {
    nodes_loaded: usize = 0,
    nodes_imported: usize = 0,
    edges_loaded: usize = 0,
    edges_imported: usize = 0,
    edges_skipped_missing_endpoint: usize = 0,
    corpus_bytes: u64 = 0,
    text_warmed: bool = false,
    marker_cleanup_pending: bool = false,
};

const BenchNoRegressionGateLimits = benchmark_contract.NoRegressionGateLimits;

const BenchWorkload = benchmark_contract.Workload;
const BenchEdgeIdPattern = benchmark_contract.EdgeIdPattern;

const max_cli_text_postings_scanned: usize = 10_000_000;
const max_cli_text_timeout_ms: u64 = 60_000;
const agent_memory_text_postings_scanned: usize = max_cli_text_postings_scanned;
const agent_memory_text_timeout_ms: u64 = max_cli_text_timeout_ms;

const TextBudgetProfile = enum {
    interactive,
    agent_memory,
};

const ParsedLifecycleMaintenanceArgs = struct {
    db_path: []const u8,
    edge_max_segments: usize = 0,
    edge_max_edges: u64 = 0,
    edge_gc: bool = false,
    node_text_max_records: u64 = 0,
    node_text_runs_max_records: u64 = 0,
    node_text_gc: bool = false,
    compact_property_payload: bool = false,
    max_passes: usize = 1,
    until_clean: bool = false,
    interval_ms: u64 = 0,
    watch: bool = false,
    max_cycles: usize = 1,
    stop_after_clean_cycles: usize = 0,
    poll_ms: u64 = 0,
};

const LifecycleMaintenancePass = struct {
    idle: agent.IdleMaintenanceResult,
    node_texts_compression: storage.NodeTextsCompressionResult = .{},
    node_texts_compression_ns: u128 = 0,
    node_text_gc_ran: bool = false,
    node_text_gc: storage.NodeTextRunGcResult = .{},
    property_payload: storage.PropertyPayloadCompactionResult = .{},

    fn madeProgress(self: LifecycleMaintenancePass) bool {
        return self.idle.edge_l0.compacted or
            self.idle.edge_gc.deleted_segments != 0 or
            self.idle.edge_gc.deleted_manifests != 0 or
            self.idle.node_text_delta.compacted or
            self.idle.node_text_runs.compacted or
            self.idle.node_text_runs.gc_deleted_runs != 0 or
            self.node_texts_compression.compressed or
            self.property_payload.compacted or
            self.node_text_gc.deleted_runs != 0 or
            self.node_text_gc.deleted_manifests != 0;
    }
};

const LifecycleMaintenanceCycle = struct {
    made_progress: bool = false,
    stopped_clean: bool = false,
};

const LifecycleMaintenanceSummary = struct {
    cycles: usize = 0,
    passes: usize = 0,
    stopped_clean: bool = false,
    clean_cycles: usize = 0,
    edge_l0_compactions: usize = 0,
    edge_l0_compacted_edges: u64 = 0,
    edge_l0_compacted_segments: usize = 0,
    edge_gc_passes: usize = 0,
    edge_gc_deleted_segments: u64 = 0,
    edge_gc_deleted_manifests: u64 = 0,
    node_text_delta_compactions: usize = 0,
    node_text_delta_records_compacted: u64 = 0,
    node_text_run_compactions: usize = 0,
    node_text_run_compacted_records: u64 = 0,
    node_text_run_gc_deleted_runs: u64 = 0,
    node_texts_compressions: usize = 0,
    node_texts_compress_ns: u128 = 0,
    node_texts_bytes_before_last: u64 = 0,
    node_texts_bytes_after_last: u64 = 0,
    node_texts_logical_bytes_last: u64 = 0,
    node_text_gc_passes: usize = 0,
    node_text_gc_deleted_runs: u64 = 0,
    node_text_gc_deleted_manifests: u64 = 0,
    property_payload_compactions: usize = 0,
    property_payload_delta_bytes_compacted: u64 = 0,
    property_payload_delta_frames_compacted: u64 = 0,
    last_property_payload_live_entries: u64 = 0,
    property_payload_cleanup_pending: bool = false,
    last_edge_l0_entries_before: usize = 0,
    last_edge_l0_entries_after: usize = 0,
    last_node_text_delta_records_before: u64 = 0,
    last_node_text_delta_records_after: u64 = 0,
    last_node_text_run_entries_before: usize = 0,
    last_node_text_run_entries_after: usize = 0,
    last_node_text_run_records_before: u64 = 0,
    last_node_text_run_records_after: u64 = 0,

    fn record(self: *LifecycleMaintenanceSummary, pass: LifecycleMaintenancePass) !void {
        self.passes = std.math.add(usize, self.passes, 1) catch return error.RecordTooLarge;

        self.last_edge_l0_entries_before = pass.idle.edge_l0.manifest_entries_before;
        self.last_edge_l0_entries_after = pass.idle.edge_l0.manifest_entries_after;
        if (pass.idle.edge_l0.compacted) {
            self.edge_l0_compactions = std.math.add(usize, self.edge_l0_compactions, 1) catch return error.RecordTooLarge;
            self.edge_l0_compacted_edges = std.math.add(u64, self.edge_l0_compacted_edges, pass.idle.edge_l0.compacted_edges) catch return error.RecordTooLarge;
            self.edge_l0_compacted_segments = std.math.add(usize, self.edge_l0_compacted_segments, pass.idle.edge_l0.compacted_segments) catch return error.RecordTooLarge;
        }
        if (pass.idle.edge_gc_ran) {
            self.edge_gc_passes = std.math.add(usize, self.edge_gc_passes, 1) catch return error.RecordTooLarge;
            self.edge_gc_deleted_segments = std.math.add(u64, self.edge_gc_deleted_segments, pass.idle.edge_gc.deleted_segments) catch return error.RecordTooLarge;
            self.edge_gc_deleted_manifests = std.math.add(u64, self.edge_gc_deleted_manifests, pass.idle.edge_gc.deleted_manifests) catch return error.RecordTooLarge;
        }

        self.last_node_text_delta_records_before = pass.idle.node_text_delta.delta_records_before;
        self.last_node_text_delta_records_after = pass.idle.node_text_delta.delta_records_after;
        if (pass.idle.node_text_delta.compacted) {
            self.node_text_delta_compactions = std.math.add(usize, self.node_text_delta_compactions, 1) catch return error.RecordTooLarge;
            self.node_text_delta_records_compacted = std.math.add(u64, self.node_text_delta_records_compacted, pass.idle.node_text_delta.delta_records_before) catch return error.RecordTooLarge;
        }

        self.last_node_text_run_entries_before = pass.idle.node_text_runs.run_entries_before;
        self.last_node_text_run_entries_after = pass.idle.node_text_runs.run_entries_after;
        self.last_node_text_run_records_before = pass.idle.node_text_runs.run_records_before;
        self.last_node_text_run_records_after = pass.idle.node_text_runs.run_records_after;
        if (pass.idle.node_text_runs.compacted) {
            self.node_text_run_compactions = std.math.add(usize, self.node_text_run_compactions, 1) catch return error.RecordTooLarge;
            self.node_text_run_compacted_records = std.math.add(u64, self.node_text_run_compacted_records, pass.idle.node_text_runs.compacted_run_records) catch return error.RecordTooLarge;
            self.node_text_run_gc_deleted_runs = std.math.add(u64, self.node_text_run_gc_deleted_runs, pass.idle.node_text_runs.gc_deleted_runs) catch return error.RecordTooLarge;
        }
        self.node_texts_compress_ns += pass.node_texts_compression_ns;
        if (pass.node_texts_compression.compressed) {
            self.node_texts_compressions = std.math.add(usize, self.node_texts_compressions, 1) catch return error.RecordTooLarge;
            self.node_texts_bytes_before_last = pass.node_texts_compression.before_bytes;
            self.node_texts_bytes_after_last = pass.node_texts_compression.after_bytes;
            self.node_texts_logical_bytes_last = pass.node_texts_compression.logical_bytes;
        } else if (self.node_texts_compressions == 0) {
            self.node_texts_bytes_before_last = pass.node_texts_compression.before_bytes;
            self.node_texts_bytes_after_last = pass.node_texts_compression.after_bytes;
            self.node_texts_logical_bytes_last = pass.node_texts_compression.logical_bytes;
        }
        if (pass.node_text_gc_ran) {
            self.node_text_gc_passes = std.math.add(usize, self.node_text_gc_passes, 1) catch return error.RecordTooLarge;
            self.node_text_gc_deleted_runs = std.math.add(u64, self.node_text_gc_deleted_runs, pass.node_text_gc.deleted_runs) catch return error.RecordTooLarge;
            self.node_text_gc_deleted_manifests = std.math.add(u64, self.node_text_gc_deleted_manifests, pass.node_text_gc.deleted_manifests) catch return error.RecordTooLarge;
        }
        if (pass.property_payload.compacted) {
            self.property_payload_compactions = std.math.add(usize, self.property_payload_compactions, 1) catch return error.RecordTooLarge;
            self.property_payload_delta_bytes_compacted = std.math.add(u64, self.property_payload_delta_bytes_compacted, pass.property_payload.delta_bytes) catch return error.RecordTooLarge;
            self.property_payload_delta_frames_compacted = std.math.add(u64, self.property_payload_delta_frames_compacted, pass.property_payload.delta_frames) catch return error.RecordTooLarge;
            self.last_property_payload_live_entries = pass.property_payload.live_entries;
            self.property_payload_cleanup_pending = self.property_payload_cleanup_pending or pass.property_payload.cleanup_pending;
        }
    }

    fn recordCycle(self: *LifecycleMaintenanceSummary, made_progress: bool) !void {
        self.cycles = std.math.add(usize, self.cycles, 1) catch return error.RecordTooLarge;
        if (!made_progress) {
            self.clean_cycles = std.math.add(usize, self.clean_cycles, 1) catch return error.RecordTooLarge;
        }
    }
};

const default_bench_chunk_size = benchmark_contract.default_chunk_size;
const default_bench_edge_compact_threshold_entries = benchmark_contract.default_edge_compact_threshold_entries;
const default_cli_output_byte_limit: usize = 8 * 1024 * 1024;

fn runLifecycleMaintenancePass(store: storage.Store, parsed: ParsedLifecycleMaintenanceArgs, io: std.Io) !LifecycleMaintenancePass {
    const idle = try agent.runIdleMaintenance(store, .{
        .edge_l0_every_ops = 1,
        .edge_l0_max_segments = parsed.edge_max_segments,
        .edge_l0_max_edges = parsed.edge_max_edges,
        .edge_gc_every_ops = if (parsed.edge_gc) 1 else 0,
        .node_text_delta_every_ops = 1,
        .node_text_delta_max_records = parsed.node_text_max_records,
        .node_text_run_every_ops = 1,
        .node_text_run_max_records = parsed.node_text_runs_max_records,
    }, 1);
    const compress_start = monotonicNs(io);
    const node_texts_compression = try store.finalizePrimaryTextStorageWithResult();
    const node_texts_compression_ns = elapsedNs(io, compress_start);
    const node_text_gc = if (parsed.node_text_gc)
        try store.gcUnreferencedNodeTextRunsWithProcessLeases()
    else
        storage.NodeTextRunGcResult{};
    const property_payload = if (parsed.compact_property_payload)
        try store.compactPropertyPayloadDelta(store.allocator)
    else
        storage.PropertyPayloadCompactionResult{};
    return .{
        .idle = idle,
        .node_texts_compression = node_texts_compression,
        .node_texts_compression_ns = node_texts_compression_ns,
        .node_text_gc_ran = parsed.node_text_gc,
        .node_text_gc = node_text_gc,
        .property_payload = property_payload,
    };
}

fn runLifecycleMaintenanceCycle(store: storage.Store, parsed: ParsedLifecycleMaintenanceArgs, summary: *LifecycleMaintenanceSummary, io: std.Io) !LifecycleMaintenanceCycle {
    var cycle = LifecycleMaintenanceCycle{};
    var pass_index: usize = 0;
    while (pass_index < parsed.max_passes) : (pass_index += 1) {
        const pass = try runLifecycleMaintenancePass(store, parsed, io);
        const pass_made_progress = pass.madeProgress();
        try summary.record(pass);
        cycle.made_progress = cycle.made_progress or pass_made_progress;
        if (parsed.until_clean and !pass_made_progress) {
            cycle.stopped_clean = true;
            break;
        }
        if (pass_index < parsed.max_passes - 1 and parsed.interval_ms != 0) {
            try sleepMillis(io, parsed.interval_ms);
        }
    }
    return cycle;
}

const RootLifecycleMaintenanceContext = struct {
    cli_lock: CliStoreLock,
    store: storage.Store,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !RootLifecycleMaintenanceContext {
        const cli_lock = try CliStoreLock.acquire(allocator, io, db_path);
        errdefer cli_lock.deinit();
        const store = try storage.Store.open(allocator, io, db_path);
        return .{ .cli_lock = cli_lock, .store = store };
    }

    pub fn deinit(self: *RootLifecycleMaintenanceContext) void {
        self.store.deinit();
        self.cli_lock.deinit();
        self.* = undefined;
    }

    pub fn runCycle(
        self: *RootLifecycleMaintenanceContext,
        parsed: ParsedLifecycleMaintenanceArgs,
        summary: *LifecycleMaintenanceSummary,
        io: std.Io,
    ) !LifecycleMaintenanceCycle {
        return runLifecycleMaintenanceCycle(self.store, parsed, summary, io);
    }
};

fn sleepMillis(io: std.Io, millis: u64) !void {
    const sleep_ns = std.math.mul(u64, millis, std.time.ns_per_ms) catch return error.RecordTooLarge;
    if (sleep_ns > std.math.maxInt(i64)) return error.RecordTooLarge;
    try std.Io.sleep(io, .fromNanoseconds(@intCast(sleep_ns)), .awake);
}

fn parseLifecycleMaintenanceArgs(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !ParsedLifecycleMaintenanceArgs {
    const parsed = try parseDbArgs(allocator, io, args, 2, 0, std.math.maxInt(usize), true);
    var edge_max_segments: usize = 0;
    var edge_max_edges: u64 = 0;
    var edge_gc = false;
    var node_text_max_records: u64 = 0;
    var node_text_runs_max_records: u64 = 0;
    var node_text_gc = false;
    var compact_property_payload = false;
    var max_passes: usize = 1;
    var until_clean = false;
    var interval_ms: u64 = 0;
    var watch = false;
    var max_cycles: usize = 1;
    var max_cycles_set = false;
    var stop_after_clean_cycles: usize = 0;
    var poll_ms: u64 = 0;
    var pos: usize = 0;
    while (pos < parsed.rest.len) {
        const option = parsed.rest[pos];
        if (std.mem.eql(u8, option, "--edge-max-segments")) {
            if (pos + 1 >= parsed.rest.len) return error.MissingArgument;
            edge_max_segments = try parseBenchCount(parsed.rest[pos + 1]);
            pos += 2;
        } else if (std.mem.eql(u8, option, "--edge-max-edges")) {
            if (pos + 1 >= parsed.rest.len) return error.MissingArgument;
            edge_max_edges = std.fmt.parseInt(u64, parsed.rest[pos + 1], 10) catch return error.InvalidLimit;
            if (edge_max_edges == 0) return error.InvalidLimit;
            pos += 2;
        } else if (std.mem.eql(u8, option, "--edge-gc")) {
            edge_gc = true;
            pos += 1;
        } else if (std.mem.eql(u8, option, "--node-text-max-records")) {
            if (pos + 1 >= parsed.rest.len) return error.MissingArgument;
            node_text_max_records = std.fmt.parseInt(u64, parsed.rest[pos + 1], 10) catch return error.InvalidLimit;
            if (node_text_max_records == 0) return error.InvalidLimit;
            pos += 2;
        } else if (std.mem.eql(u8, option, "--node-text-runs-max-records")) {
            if (pos + 1 >= parsed.rest.len) return error.MissingArgument;
            node_text_runs_max_records = std.fmt.parseInt(u64, parsed.rest[pos + 1], 10) catch return error.InvalidLimit;
            if (node_text_runs_max_records == 0) return error.InvalidLimit;
            pos += 2;
        } else if (std.mem.eql(u8, option, "--node-text-gc")) {
            node_text_gc = true;
            pos += 1;
        } else if (std.mem.eql(u8, option, "--compact-property-payload")) {
            compact_property_payload = true;
            pos += 1;
        } else if (std.mem.eql(u8, option, "--max-passes")) {
            if (pos + 1 >= parsed.rest.len) return error.MissingArgument;
            max_passes = try parseBenchCount(parsed.rest[pos + 1]);
            pos += 2;
        } else if (std.mem.eql(u8, option, "--until-clean")) {
            until_clean = true;
            pos += 1;
        } else if (std.mem.eql(u8, option, "--interval-ms")) {
            if (pos + 1 >= parsed.rest.len) return error.MissingArgument;
            interval_ms = std.fmt.parseInt(u64, parsed.rest[pos + 1], 10) catch return error.InvalidLimit;
            pos += 2;
        } else if (std.mem.eql(u8, option, "--watch")) {
            watch = true;
            pos += 1;
        } else if (std.mem.eql(u8, option, "--max-cycles")) {
            if (pos + 1 >= parsed.rest.len) return error.MissingArgument;
            max_cycles = try parseBenchCount(parsed.rest[pos + 1]);
            max_cycles_set = true;
            pos += 2;
        } else if (std.mem.eql(u8, option, "--stop-after-clean-cycles")) {
            if (pos + 1 >= parsed.rest.len) return error.MissingArgument;
            stop_after_clean_cycles = try parseBenchCount(parsed.rest[pos + 1]);
            pos += 2;
        } else if (std.mem.eql(u8, option, "--poll-ms")) {
            if (pos + 1 >= parsed.rest.len) return error.MissingArgument;
            poll_ms = std.fmt.parseInt(u64, parsed.rest[pos + 1], 10) catch return error.InvalidLimit;
            pos += 2;
        } else {
            return error.UnknownOption;
        }
    }
    if (watch and !max_cycles_set) {
        max_cycles = std.math.maxInt(usize);
    }
    return .{
        .db_path = parsed.db_path,
        .edge_max_segments = edge_max_segments,
        .edge_max_edges = edge_max_edges,
        .edge_gc = edge_gc,
        .node_text_max_records = node_text_max_records,
        .node_text_runs_max_records = node_text_runs_max_records,
        .node_text_gc = node_text_gc,
        .compact_property_payload = compact_property_payload,
        .max_passes = max_passes,
        .until_clean = until_clean,
        .interval_ms = interval_ms,
        .watch = watch,
        .max_cycles = max_cycles,
        .stop_after_clean_cycles = stop_after_clean_cycles,
        .poll_ms = poll_ms,
    };
}

fn parseMarkdownDocEditBenchArgs(args: []const []const u8) !ParsedMarkdownDocEditBenchArgs {
    if (args.len < 4) return error.MissingArgument;
    const paragraphs = try parseBenchCount(args[3]);
    var parsed = ParsedMarkdownDocEditBenchArgs{
        .db_path = args[2],
        .paragraphs = paragraphs,
        .edit_index = paragraphs / 2,
    };
    var pos: usize = 4;
    while (pos < args.len) {
        const option = args[pos];
        if (std.mem.eql(u8, option, "--edit-index")) {
            if (pos + 1 >= args.len) return error.MissingArgument;
            parsed.edit_index = std.fmt.parseInt(usize, args[pos + 1], 10) catch return error.InvalidLimit;
            pos += 2;
        } else if (std.mem.eql(u8, option, "--repeat-local-edits")) {
            if (pos + 1 >= args.len) return error.MissingArgument;
            parsed.repeat_local_edits = try parseBenchCount(args[pos + 1]);
            pos += 2;
        } else if (std.mem.eql(u8, option, "--repeat-update-edits")) {
            if (pos + 1 >= args.len) return error.MissingArgument;
            parsed.repeat_update_edits = try parseBenchCount(args[pos + 1]);
            pos += 2;
        } else if (std.mem.eql(u8, option, "--agent-mixed-writes")) {
            if (pos + 1 >= args.len) return error.MissingArgument;
            parsed.agent_mixed_writes = try parseBenchCount(args[pos + 1]);
            pos += 2;
        } else if (std.mem.eql(u8, option, "--max-edit-changed-records")) {
            if (pos + 1 >= args.len) return error.MissingArgument;
            parsed.max_edit_changed_records = std.fmt.parseInt(usize, args[pos + 1], 10) catch return error.InvalidLimit;
            pos += 2;
        } else if (std.mem.eql(u8, option, "--max-edit-elapsed-ns")) {
            if (pos + 1 >= args.len) return error.MissingArgument;
            parsed.max_edit_elapsed_ns = std.fmt.parseInt(u128, args[pos + 1], 10) catch return error.InvalidLimit;
            pos += 2;
        } else if (std.mem.eql(u8, option, "--max-edit-ns-per-paragraph")) {
            if (pos + 1 >= args.len) return error.MissingArgument;
            parsed.max_edit_ns_per_paragraph = std.fmt.parseInt(u128, args[pos + 1], 10) catch return error.InvalidLimit;
            pos += 2;
        } else if (std.mem.eql(u8, option, "--max-edit-to-initial-bps")) {
            if (pos + 1 >= args.len) return error.MissingArgument;
            parsed.max_edit_to_initial_bps = std.fmt.parseInt(u128, args[pos + 1], 10) catch return error.InvalidLimit;
            pos += 2;
        } else if (std.mem.eql(u8, option, "--max-repeat-edit-elapsed-ns")) {
            if (pos + 1 >= args.len) return error.MissingArgument;
            parsed.max_repeat_edit_elapsed_ns = std.fmt.parseInt(u128, args[pos + 1], 10) catch return error.InvalidLimit;
            pos += 2;
        } else if (std.mem.eql(u8, option, "--max-repeat-update-edit-elapsed-ns")) {
            if (pos + 1 >= args.len) return error.MissingArgument;
            parsed.max_repeat_update_edit_elapsed_ns = std.fmt.parseInt(u128, args[pos + 1], 10) catch return error.InvalidLimit;
            pos += 2;
        } else if (std.mem.eql(u8, option, "--max-render-local-subtree-elapsed-ns")) {
            if (pos + 1 >= args.len) return error.MissingArgument;
            parsed.max_render_local_subtree_elapsed_ns = std.fmt.parseInt(u128, args[pos + 1], 10) catch return error.InvalidLimit;
            pos += 2;
        } else if (std.mem.startsWith(u8, option, "--")) {
            return error.UnknownOption;
        } else {
            return error.TooManyArguments;
        }
    }
    if (parsed.edit_index >= parsed.paragraphs) return error.InvalidLimit;

    return parsed;
}

fn parseTextBudgetProfile(value: []const u8) !TextBudgetProfile {
    if (std.mem.eql(u8, value, "interactive")) return .interactive;
    if (std.mem.eql(u8, value, "agent-memory")) return .agent_memory;
    return error.InvalidLimit;
}

fn applyTextBudgetProfile(profile: TextBudgetProfile, max_postings_scanned: *usize, timeout_ms: *u64, max_postings_explicit: bool, timeout_explicit: bool) void {
    switch (profile) {
        .interactive => {},
        .agent_memory => {
            if (!max_postings_explicit) max_postings_scanned.* = agent_memory_text_postings_scanned;
            if (!timeout_explicit) timeout_ms.* = agent_memory_text_timeout_ms;
        },
    }
}

fn parseCliOutputFormat(value: []const u8) !CliOutputFormat {
    if (std.mem.eql(u8, value, "text")) return .text;
    if (std.mem.eql(u8, value, "json")) return .json;
    return error.InvalidFormat;
}

fn parseBenchCount(value: []const u8) !usize {
    const parsed = std.fmt.parseInt(usize, value, 10) catch return error.InvalidLimit;
    if (parsed == 0) return error.InvalidLimit;
    return parsed;
}

fn parseContextArgs(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !ParsedContextArgs {
    const parsed = try parseFreeTextDbArgs(allocator, io, args, 2, 1);
    errdefer parsed.deinit(allocator);

    var task_id: ?core.NodeId = null;
    var root_node_id: ?core.NodeId = null;
    var profile: TextBudgetProfile = .agent_memory;
    var limit: usize = 5;
    var include_history = false;
    var format: CliOutputFormat = .json;
    var meta = false;
    var max_postings_scanned: usize = 20_000;
    var timeout_ms: u64 = 250;
    var neighbor_depth: usize = 1;
    var max_nodes: usize = 12;
    var max_edges: usize = 24;
    var max_chars: usize = 200_000;
    var markdown_preview_lines: usize = 8;
    var query_end = parsed.rest.len;
    while (query_end > 0) {
        if (std.mem.eql(u8, parsed.rest[query_end - 1], "--include-history")) {
            include_history = true;
            query_end -= 1;
            continue;
        }
        if (std.mem.eql(u8, parsed.rest[query_end - 1], "--meta")) {
            meta = true;
            query_end -= 1;
            continue;
        }
        if (query_end < 2) break;
        const option = parsed.rest[query_end - 2];
        const value = parsed.rest[query_end - 1];
        if (std.mem.eql(u8, option, "--task")) {
            task_id = try parseNodeIdArg(value);
            query_end -= 2;
        } else if (std.mem.eql(u8, option, "--node")) {
            root_node_id = try parseNodeIdArg(value);
            query_end -= 2;
        } else if (std.mem.eql(u8, option, "--limit")) {
            limit = std.fmt.parseInt(usize, value, 10) catch return error.InvalidLimit;
            if (limit == 0 or limit > (core.QueryBudget{}).max_results) return error.InvalidLimit;
            query_end -= 2;
        } else if (std.mem.eql(u8, option, "--profile")) {
            profile = try parseTextBudgetProfile(value);
            query_end -= 2;
        } else if (std.mem.eql(u8, option, "--max-postings")) {
            max_postings_scanned = std.fmt.parseInt(usize, value, 10) catch return error.InvalidLimit;
            if (max_postings_scanned == 0 or max_postings_scanned > max_cli_text_postings_scanned) return error.InvalidLimit;
            query_end -= 2;
        } else if (std.mem.eql(u8, option, "--timeout-ms")) {
            timeout_ms = std.fmt.parseInt(u64, value, 10) catch return error.InvalidLimit;
            if (timeout_ms == 0 or timeout_ms > max_cli_text_timeout_ms) return error.InvalidLimit;
            query_end -= 2;
        } else if (std.mem.eql(u8, option, "--format")) {
            format = try parseCliOutputFormat(value);
            query_end -= 2;
        } else if (std.mem.eql(u8, option, "--neighbor-depth")) {
            neighbor_depth = std.fmt.parseInt(usize, value, 10) catch return error.InvalidLimit;
            if (neighbor_depth == 0 or neighbor_depth > 8) return error.InvalidLimit;
            query_end -= 2;
        } else if (std.mem.eql(u8, option, "--max-nodes")) {
            max_nodes = std.fmt.parseInt(usize, value, 10) catch return error.InvalidLimit;
            if (max_nodes == 0 or max_nodes > (core.QueryBudget{}).max_visited_nodes) return error.InvalidLimit;
            query_end -= 2;
        } else if (std.mem.eql(u8, option, "--max-edges")) {
            max_edges = std.fmt.parseInt(usize, value, 10) catch return error.InvalidLimit;
            if (max_edges == 0 or max_edges > (core.QueryBudget{}).max_visited_edges) return error.InvalidLimit;
            query_end -= 2;
        } else if (std.mem.eql(u8, option, "--max-chars")) {
            max_chars = std.fmt.parseInt(usize, value, 10) catch return error.InvalidLimit;
            if (max_chars == 0) return error.InvalidLimit;
            query_end -= 2;
        } else if (std.mem.eql(u8, option, "--markdown-preview-lines")) {
            markdown_preview_lines = std.fmt.parseInt(usize, value, 10) catch return error.InvalidLimit;
            if (markdown_preview_lines > 200) return error.InvalidLimit;
            query_end -= 2;
        } else if (std.mem.startsWith(u8, option, "--")) {
            return error.UnknownOption;
        } else {
            break;
        }
    }
    if (query_end == 0) return error.MissingArgument;
    if (format != .json) return error.Unsupported;
    return .{
        .db_path = parsed.db_path,
        .query = try joinArgs(allocator, parsed.rest[0..query_end]),
        .owned_db_path = parsed.owned_db_path,
        .task_id = task_id,
        .root_node_id = root_node_id,
        .profile = profile,
        .limit = limit,
        .include_history = include_history,
        .format = format,
        .meta = meta,
        .max_postings_scanned = max_postings_scanned,
        .timeout_ms = timeout_ms,
        .neighbor_depth = neighbor_depth,
        .max_nodes = max_nodes,
        .max_edges = max_edges,
        .max_chars = max_chars,
        .markdown_preview_lines = markdown_preview_lines,
    };
}

const parseAddNodeArgs = governed_node_write_admission.parseAddNodeArgs;
const parseUpdateNodeArgs = governed_node_write_admission.parseUpdateNodeArgs;
const normalizeNodeStringPropertyKey = governed_node_write_admission.normalizeNodeStringPropertyKey;
const normalizeNodeUintPropertyKey = governed_node_write_admission.normalizeNodeUintPropertyKey;
fn normalizeEdgeStringPropertyKey(key: []const u8) ![]const u8 {
    const normalized = if (std.mem.eql(u8, key, "markdown-attr"))
        "markdown_attr"
    else if (std.mem.eql(u8, key, "render-flags"))
        "render_flags"
    else if (std.mem.eql(u8, key, "source-span"))
        "source_span"
    else if (std.mem.eql(u8, key, "created-by"))
        "created_by"
    else
        key;
    if (!std.mem.eql(u8, normalized, "markdown_attr") and
        !std.mem.eql(u8, normalized, "render_flags") and
        !std.mem.eql(u8, normalized, "source_span") and
        !std.mem.eql(u8, normalized, "confidence") and
        !std.mem.eql(u8, normalized, "created_by") and
        // state = 分类两态位(tentative|confirmed):写入容忍模糊,闭合/纠正时结晶。
        // 值域校验在 setEdgeState 侧收口(此处只放行 key)。
        !std.mem.eql(u8, normalized, "state"))
    {
        return error.InvalidRecord;
    }
    return normalized;
}

fn normalizeEdgeUintPropertyKey(key: []const u8) ![]const u8 {
    const normalized = if (std.mem.eql(u8, key, "order-key"))
        "order_key"
    else if (std.mem.eql(u8, key, "tombstone-generation"))
        "tombstone_generation"
    else
        key;
    if (!std.mem.eql(u8, normalized, "order_key") and
        !std.mem.eql(u8, normalized, "generation") and
        !std.mem.eql(u8, normalized, "tombstone_generation"))
    {
        return error.InvalidRecord;
    }
    return normalized;
}

const parseGovernNodeArgs = governed_node_write_admission.parseGovernNodeArgs;
const nodeVisibleTextFromGovernanceArgs = governed_node_write_admission.nodeVisibleTextFromGovernanceArgs;
const applyNodeGovernanceProperties = governed_node_write_admission.applyNodeGovernanceProperties;
const u128ToU64 = governed_node_write_admission.u128ToU64;
fn writeGovernanceJsonStringField(writer: *QueryOutputWriter, field: []const u8, value: []const u8, first_field: *bool) !void {
    try writeGovernanceJsonFieldPrefix(writer, field, first_field);
    try writeJsonString(writer, value);
}

fn writeGovernanceJsonNumberField(writer: *QueryOutputWriter, field: []const u8, value: anytype, first_field: *bool) !void {
    try writeGovernanceJsonFieldPrefix(writer, field, first_field);
    try writer.print("{}", .{value});
}

fn writeGovernanceJsonFieldPrefix(writer: *QueryOutputWriter, field: []const u8, first_field: *bool) !void {
    if (first_field.*) {
        first_field.* = false;
    } else {
        try writer.writeAll(",");
    }
    try writeJsonString(writer, field);
    try writer.writeAll(":");
}

const nodeGovernanceNeedsTaskMetricTimestamp = governed_node_write_admission.nodeGovernanceNeedsTaskMetricTimestamp;
const nodeGovernanceIsOpenTask = governed_node_write_admission.nodeGovernanceIsOpenTask;

const TaskLifecycleMetadata = struct {
    task_created_ns: ?u128 = null,
    task_completed_ns: ?u128 = null,
};

const TaskEventMetadata = governed_node_write_admission.TaskEventMetadata;

fn taskEventNodeText(allocator: std.mem.Allocator, event_type_value: TaskEventType, note: ?[]const u8) ![]const u8 {
    const event_type = TaskMutationArguments.eventTypeName(event_type_value);
    var out = QueryOutputWriter{ .allocator = allocator };
    errdefer out.buffer.deinit(allocator);
    try out.print("task_event {s}", .{event_type});
    if (note) |value| try out.print(" note={s}", .{value});
    return out.buffer.toOwnedSlice(allocator);
}

fn validateTaskEventTargets(
    allocator: std.mem.Allocator,
    store: storage.Store,
    root_id: core.NodeId,
    task_id: ?core.NodeId,
) !void {
    var node_id_view = try store.openNodeByIdIndexView();
    defer node_id_view.deinit();
    if (!try node_id_view.nodeExists(root_id)) return core.Error.NotFound;
    if (task_id) |id| {
        var node = (try store.readNodeById(allocator, id)) orelse return core.Error.NotFound;
        defer node.deinit(allocator);
        if (!nodeKindCanAnchorTaskEvent(node.kind)) return core.Error.InvalidId;
    }
}

fn nodeKindCanAnchorTaskEvent(kind: core.NodeKind) bool {
    return switch (kind) {
        .task, .verification, .fix => true,
        else => false,
    };
}

fn taskLifecycleMetadataForUpdate(
    allocator: std.mem.Allocator,
    store: storage.Store,
    existing_node: storage.StoredNode,
    target_kind: core.NodeKind,
    completed_ns: u128,
) !TaskLifecycleMetadata {
    const existing_created_ns = taskMetricEpochNs(optionalU64ToU128(try store.getUintProperty(allocator, .{ .node = existing_node.id }, "task_created_ns"))) orelse
        taskMetricEpochNs(optionalU64ToU128(try store.getUintProperty(allocator, .{ .node = existing_node.id }, "task_recorded_ns"))) orelse
        completed_ns;
    const existing_completed_ns = taskMetricEpochNs(optionalU64ToU128(try store.getUintProperty(allocator, .{ .node = existing_node.id }, "task_completed_ns")));
    return switch (target_kind) {
        .task => .{ .task_created_ns = existing_created_ns },
        .verification, .fix => .{
            .task_created_ns = existing_created_ns,
            .task_completed_ns = existing_completed_ns orelse if (existing_node.kind == .task) completed_ns else null,
        },
        else => .{},
    };
}

fn taskEventMetadataForUpdate(
    allocator: std.mem.Allocator,
    store: storage.Store,
    existing_node: storage.StoredNode,
    target_kind: core.NodeKind,
    explicit_schema_type: ?[]const u8,
    fallback_event_ns: u128,
) !?TaskEventMetadata {
    if (!taskEventMetadataShouldBePreserved(target_kind, explicit_schema_type)) return null;
    return try taskEventMetadataFromProperties(allocator, store, existing_node.id, fallback_event_ns);
}

fn taskEventMetadataShouldBePreserved(target_kind: core.NodeKind, explicit_schema_type: ?[]const u8) bool {
    if (explicit_schema_type) |schema_type| return std.mem.eql(u8, schema_type, "task_event");
    return switch (target_kind) {
        .command, .error_event, .observation => true,
        else => false,
    };
}

fn taskEventMetadataFromProperties(allocator: std.mem.Allocator, store: storage.Store, node_id: core.NodeId, fallback_event_ns: u128) !?TaskEventMetadata {
    const schema_type = try store.getNodeStringProperty(allocator, node_id, "schema_type");
    defer if (schema_type) |value| allocator.free(value);
    const concrete_schema_type = schema_type orelse return null;
    if (!std.mem.eql(u8, concrete_schema_type, "task_event")) return null;

    const event_type = try store.getNodeStringProperty(allocator, node_id, "task_event_type");
    defer if (event_type) |value| allocator.free(value);
    const concrete_event_type = event_type orelse return null;
    const event_ns = taskMetricEpochNs(optionalU64ToU128(try store.getUintProperty(allocator, .{ .node = node_id }, "task_event_ns"))) orelse fallback_event_ns;
    const root_id = try store.getUintProperty(allocator, .{ .node = node_id }, "task_root_id") orelse return null;
    const task_id = try store.getUintProperty(allocator, .{ .node = node_id }, "task_id");

    var metadata = TaskEventMetadata{
        .event_type = try allocator.dupe(u8, concrete_event_type),
        .event_ns = event_ns,
        .root_id = root_id,
        .task_id = task_id,
    };
    errdefer metadata.deinit(allocator);
    metadata.dependency_relation = try store.getNodeStringProperty(allocator, node_id, "dependency_relation");
    return metadata;
}

fn exerciseTaskEventMetadataAllocationFailure(allocator: std.mem.Allocator, store: storage.Store) !void {
    const metadata = (try taskEventMetadataFromProperties(allocator, store, .fromInt(1), 7)) orelse return error.TestExpectedEqual;
    defer metadata.deinit(allocator);
    try std.testing.expectEqualStrings("write_error", metadata.event_type);
    try std.testing.expectEqual(@as(u64, 2), metadata.root_id);
    try std.testing.expectEqual(@as(?u64, 3), metadata.task_id);
    try std.testing.expectEqualStrings("depends_on", metadata.dependency_relation.?);
}

const validateGovernanceMetadataToken = governed_node_write_admission.validateGovernanceMetadataToken;

fn parseNeighborsArgs(rest: []const []const u8) !ParsedNeighborsArgs {
    var positionals: [2][]const u8 = undefined;
    var positional_count: usize = 0;
    var schema_path: ?[]const u8 = null;
    var limit: ?usize = null;
    var offset: usize = 0;
    var offset_explicit = false;
    var include_history = false;
    var format: CliOutputFormat = .text;
    var meta = false;
    var depth: usize = 1;
    var max_nodes: ?usize = null;
    var max_edges: ?usize = null;
    var max_chars: ?usize = null;

    var pos: usize = 0;
    while (pos < rest.len) {
        const arg = rest[pos];
        if (std.mem.eql(u8, arg, "--schema")) {
            if (pos + 1 >= rest.len) return error.MissingArgument;
            if (schema_path != null) return error.TooManyArguments;
            schema_path = rest[pos + 1];
            pos += 2;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            if (pos + 1 >= rest.len) return error.MissingArgument;
            if (limit != null) return error.TooManyArguments;
            const parsed_limit = std.fmt.parseInt(usize, rest[pos + 1], 10) catch return error.InvalidLimit;
            if (parsed_limit == 0 or parsed_limit > (core.QueryBudget{}).max_results) return error.InvalidLimit;
            limit = parsed_limit;
            pos += 2;
        } else if (std.mem.eql(u8, arg, "--offset")) {
            if (pos + 1 >= rest.len) return error.MissingArgument;
            if (offset_explicit) return error.TooManyArguments;
            offset = std.fmt.parseInt(usize, rest[pos + 1], 10) catch return error.InvalidLimit;
            if (offset > (core.QueryBudget{}).max_visited_edges) return error.InvalidLimit;
            offset_explicit = true;
            pos += 2;
        } else if (std.mem.eql(u8, arg, "--include-history")) {
            include_history = true;
            pos += 1;
        } else if (std.mem.eql(u8, arg, "--format")) {
            if (pos + 1 >= rest.len) return error.MissingArgument;
            format = try parseCliOutputFormat(rest[pos + 1]);
            pos += 2;
        } else if (std.mem.eql(u8, arg, "--meta")) {
            meta = true;
            pos += 1;
        } else if (std.mem.eql(u8, arg, "--depth")) {
            if (pos + 1 >= rest.len) return error.MissingArgument;
            const parsed_depth = std.fmt.parseInt(usize, rest[pos + 1], 10) catch return error.InvalidLimit;
            if (parsed_depth == 0 or parsed_depth > 8) return error.InvalidLimit;
            depth = parsed_depth;
            pos += 2;
        } else if (std.mem.eql(u8, arg, "--max-nodes")) {
            if (pos + 1 >= rest.len) return error.MissingArgument;
            if (max_nodes != null) return error.TooManyArguments;
            const parsed_max_nodes = std.fmt.parseInt(usize, rest[pos + 1], 10) catch return error.InvalidLimit;
            if (parsed_max_nodes == 0 or parsed_max_nodes > (core.QueryBudget{}).max_visited_nodes) return error.InvalidLimit;
            max_nodes = parsed_max_nodes;
            pos += 2;
        } else if (std.mem.eql(u8, arg, "--max-edges")) {
            if (pos + 1 >= rest.len) return error.MissingArgument;
            if (max_edges != null) return error.TooManyArguments;
            const parsed_max_edges = std.fmt.parseInt(usize, rest[pos + 1], 10) catch return error.InvalidLimit;
            if (parsed_max_edges == 0 or parsed_max_edges > (core.QueryBudget{}).max_visited_edges) return error.InvalidLimit;
            max_edges = parsed_max_edges;
            pos += 2;
        } else if (std.mem.eql(u8, arg, "--max-chars")) {
            if (pos + 1 >= rest.len) return error.MissingArgument;
            if (max_chars != null) return error.TooManyArguments;
            const parsed_max_chars = std.fmt.parseInt(usize, rest[pos + 1], 10) catch return error.InvalidLimit;
            if (parsed_max_chars == 0) return error.InvalidLimit;
            max_chars = parsed_max_chars;
            pos += 2;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownOption;
        } else {
            if (positional_count >= positionals.len) return error.TooManyArguments;
            positionals[positional_count] = arg;
            positional_count += 1;
            pos += 1;
        }
    }

    if (positional_count == 0) return error.MissingArgument;
    if (offset_explicit and limit == null) return error.MissingArgument;
    if (limit) |page_limit| {
        if (offset > (core.QueryBudget{}).max_visited_edges - page_limit) return error.InvalidLimit;
    }
    if (meta and format != .json) return error.Unsupported;
    if (format != .json and (depth != 1 or max_nodes != null or max_edges != null or max_chars != null)) return error.Unsupported;
    return .{
        .node_id = positionals[0],
        .rel_label = if (positional_count > 1) positionals[1] else null,
        .schema_path = schema_path,
        .limit = limit,
        .offset = offset,
        .include_history = include_history,
        .format = format,
        .meta = meta,
        .depth = depth,
        .max_nodes = max_nodes,
        .max_edges = max_edges,
        .max_chars = max_chars,
    };
}

fn parseIncomingArgs(rest: []const []const u8) !ParsedIncomingArgs {
    var positionals: [2][]const u8 = undefined;
    var positional_count: usize = 0;
    var schema_path: ?[]const u8 = null;
    var include_history = false;
    var pos: usize = 0;
    while (pos < rest.len) {
        const arg = rest[pos];
        if (std.mem.eql(u8, arg, "--schema")) {
            if (pos + 1 >= rest.len) return error.MissingArgument;
            if (schema_path != null) return error.TooManyArguments;
            schema_path = rest[pos + 1];
            pos += 2;
        } else if (std.mem.eql(u8, arg, "--include-history")) {
            include_history = true;
            pos += 1;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownOption;
        } else {
            if (positional_count >= positionals.len) return error.TooManyArguments;
            positionals[positional_count] = arg;
            positional_count += 1;
            pos += 1;
        }
    }
    if (positional_count == 0) return error.MissingArgument;
    return .{
        .node_id = positionals[0],
        .rel_label = if (positional_count > 1) positionals[1] else null,
        .schema_path = schema_path,
        .include_history = include_history,
    };
}

fn parseTaskPacketArgs(rest: []const []const u8) !ParsedTaskPacketArgs {
    var task_id: ?[]const u8 = null;
    var limit: usize = 8;
    var format: CliOutputFormat = .text;
    var meta = false;
    var max_nodes: ?usize = null;
    var max_edges: ?usize = null;
    var max_chars: ?usize = null;

    var pos: usize = 0;
    while (pos < rest.len) {
        const arg = rest[pos];
        if (std.mem.eql(u8, arg, "--limit")) {
            if (pos + 1 >= rest.len) return error.MissingArgument;
            const parsed_limit = std.fmt.parseInt(usize, rest[pos + 1], 10) catch return error.InvalidLimit;
            if (parsed_limit == 0 or parsed_limit > (core.QueryBudget{}).max_results) return error.InvalidLimit;
            limit = parsed_limit;
            pos += 2;
        } else if (std.mem.eql(u8, arg, "--format")) {
            if (pos + 1 >= rest.len) return error.MissingArgument;
            format = try parseCliOutputFormat(rest[pos + 1]);
            pos += 2;
        } else if (std.mem.eql(u8, arg, "--meta")) {
            meta = true;
            pos += 1;
        } else if (std.mem.eql(u8, arg, "--max-nodes")) {
            if (pos + 1 >= rest.len) return error.MissingArgument;
            if (max_nodes != null) return error.TooManyArguments;
            const parsed_max_nodes = std.fmt.parseInt(usize, rest[pos + 1], 10) catch return error.InvalidLimit;
            if (parsed_max_nodes == 0 or parsed_max_nodes > (core.QueryBudget{}).max_visited_nodes) return error.InvalidLimit;
            max_nodes = parsed_max_nodes;
            pos += 2;
        } else if (std.mem.eql(u8, arg, "--max-edges")) {
            if (pos + 1 >= rest.len) return error.MissingArgument;
            if (max_edges != null) return error.TooManyArguments;
            const parsed_max_edges = std.fmt.parseInt(usize, rest[pos + 1], 10) catch return error.InvalidLimit;
            if (parsed_max_edges == 0 or parsed_max_edges > (core.QueryBudget{}).max_visited_edges) return error.InvalidLimit;
            max_edges = parsed_max_edges;
            pos += 2;
        } else if (std.mem.eql(u8, arg, "--max-chars")) {
            if (pos + 1 >= rest.len) return error.MissingArgument;
            if (max_chars != null) return error.TooManyArguments;
            const parsed_max_chars = std.fmt.parseInt(usize, rest[pos + 1], 10) catch return error.InvalidLimit;
            if (parsed_max_chars == 0) return error.InvalidLimit;
            max_chars = parsed_max_chars;
            pos += 2;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownOption;
        } else {
            if (task_id != null) return error.TooManyArguments;
            task_id = arg;
            pos += 1;
        }
    }

    if (meta and format != .json) return error.Unsupported;
    if (format != .json and (max_nodes != null or max_edges != null or max_chars != null)) return error.Unsupported;
    return .{
        .task_id = task_id orelse return error.MissingArgument,
        .limit = limit,
        .format = format,
        .meta = meta,
        .max_nodes = max_nodes,
        .max_edges = max_edges,
        .max_chars = max_chars,
    };
}

fn parseTaskFrontierArgs(rest: []const []const u8) !ParsedTaskFrontierArgs {
    var root_id: ?[]const u8 = null;
    var limit: usize = 8;
    var mine: ?[]const u8 = null;
    var unclaimed = false;

    var pos: usize = 0;
    while (pos < rest.len) {
        const arg = rest[pos];
        if (std.mem.eql(u8, arg, "--limit")) {
            if (pos + 1 >= rest.len) return error.MissingArgument;
            const parsed_limit = std.fmt.parseInt(usize, rest[pos + 1], 10) catch return error.InvalidLimit;
            if (parsed_limit == 0 or parsed_limit > (core.QueryBudget{}).max_results) return error.InvalidLimit;
            limit = parsed_limit;
            pos += 2;
        } else if (std.mem.eql(u8, arg, "--mine")) {
            if (pos + 1 >= rest.len) return error.MissingArgument;
            mine = rest[pos + 1];
            pos += 2;
        } else if (std.mem.eql(u8, arg, "--unclaimed")) {
            unclaimed = true;
            pos += 1;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownOption;
        } else {
            if (root_id != null) return error.TooManyArguments;
            root_id = arg;
            pos += 1;
        }
    }
    if (mine != null and unclaimed) return error.TooManyArguments;

    return .{
        .root_id = root_id orelse return error.MissingArgument,
        .limit = limit,
        .mine = mine,
        .unclaimed = unclaimed,
    };
}

/// agent 身份校验。身份**必须由宿主程序注入**(如 metacodes 为每个 agent loop
/// 生成的全局唯一 session id,经 --by 显式传参):env 是进程级的,单进程多 agent
/// loop 会串;让 LLM 自己发明/记住 id 更是伪命题(编造、跨轮遗忘、互相撞)。
fn validateAgentIdentity(agent_name: []const u8) ![]const u8 {
    // 参数校验错误就报参数错误(Linus #3):InvalidRecord 是存储层"记录坏了",
    // 拿来报"身份太长"会诱导调用方去跑 repair。
    if (agent_name.len == 0 or agent_name.len > task.max_claim_holder_len) return error.InvalidArgument;
    return agent_name;
}

fn ensureTaskStatusProperty(
    allocator: std.mem.Allocator,
    store: storage.Store,
    task_id: core.NodeId,
) !void {
    const existing = try store.getNodeStringProperty(allocator, task_id, task.status_property);
    defer if (existing) |value| allocator.free(value);
    // Pre-status tasks may already carry a live legacy lease. Materializing
    // `open` unconditionally would create the contradictory state
    // `status=open + future claim_expires_ns`, poisoning all strict readers.
    // Evaluate the complete lifecycle first, including when status already
    // exists: merely parsing the enum would accept malformed terminal audit
    // fields or contradictory leases.
    const effective = try task.statusWithPersistentStore(allocator, store, task_id);
    if (existing != null) return;
    try store.setNodeStringProperty(allocator, task_id, task.status_property, @tagName(effective));
}

fn validateTaskLifecycleFieldsForRewrite(
    allocator: std.mem.Allocator,
    store: storage.Store,
    node_id: core.NodeId,
    now_ns: u64,
) !void {
    var snapshot = try task.StatusSnapshot.initForNodeIds(allocator, store, &.{node_id});
    defer snapshot.deinit();
    _ = try task.effectiveStatusForLifecycleFields(snapshot.fields(node_id), now_ns, .strict);
}

fn forEachVisibleEdgeRecordByNode(
    allocator: std.mem.Allocator,
    store: storage.Store,
    order: storage.EdgeIndexOrder,
    node_id: core.NodeId,
    rel_filter: ?core.RelKind,
    context: anytype,
    comptime callback: fn (@TypeOf(context), storage.EdgeIndexRecord) anyerror!bool,
) !bool {
    const Adapter = struct {
        inner: @TypeOf(context),

        fn visit(self: *@This(), edge: query_index.EdgeRef) !bool {
            return callback(self.inner, .{
                .src = edge.src.toInt(),
                .dst = edge.dst.toInt(),
                .edge_id = edge.edge_id.toInt(),
                .rel = @intFromEnum(edge.rel),
            });
        }
    };
    var adapter = Adapter{ .inner = context };
    const cursor = query.EdgeCursor{ .persistent_store = .{
        .allocator = allocator,
        .store = store,
    } };
    return switch (order) {
        .src => cursor.forEachOutgoingRelation(node_id, rel_filter, &adapter, Adapter.visit),
        .dst => cursor.forEachIncomingRelation(node_id, rel_filter, &adapter, Adapter.visit),
        .id => core.Error.Unsupported,
    };
}

const VisibleEdgeRecordCollection = struct {
    records: std.ArrayList(storage.EdgeIndexRecord),
    truncated: bool,
};

fn collectVisibleEdgeRecordsByNodeLimited(
    allocator: std.mem.Allocator,
    store: storage.Store,
    order: storage.EdgeIndexOrder,
    node_id: core.NodeId,
    rel_filter: ?core.RelKind,
    max_records: usize,
) !VisibleEdgeRecordCollection {
    const CollectContext = struct {
        allocator: std.mem.Allocator,
        records: *std.ArrayList(storage.EdgeIndexRecord),
        max_records: usize,

        fn visit(self: *@This(), record: storage.EdgeIndexRecord) !bool {
            if (self.records.items.len >= self.max_records) return true;
            try self.records.append(self.allocator, record);
            return false;
        }
    };
    var records = std.ArrayList(storage.EdgeIndexRecord).empty;
    errdefer records.deinit(allocator);
    var context = CollectContext{
        .allocator = allocator,
        .records = &records,
        .max_records = max_records,
    };
    const truncated = try forEachVisibleEdgeRecordByNode(allocator, store, order, node_id, rel_filter, &context, CollectContext.visit);
    return .{ .records = records, .truncated = truncated };
}

const TaskHierarchyOps = struct {
    pub const EdgeRecord = storage.EdgeIndexRecord;
    pub const NodeId = core.NodeId;
    pub const Order = storage.EdgeIndexOrder;
    pub const Context = struct {
        store: storage.Store,
        node_view: *storage.Store.NodeRecordView,
    };

    pub fn collectRelation(
        allocator: std.mem.Allocator,
        context: *Context,
        order: Order,
        owner_id: NodeId,
        relation: task_hierarchy_mod.RelationFlavor,
        max_records: usize,
    ) !VisibleEdgeRecordCollection {
        return collectVisibleEdgeRecordsByNodeLimited(
            allocator,
            context.store,
            order,
            owner_id,
            switch (relation) {
                .canonical => .contain,
                .legacy => .contains,
            },
            max_records,
        );
    }

    pub fn peerNodeId(order: Order, record: EdgeRecord) !NodeId {
        return switch (order) {
            .src => .fromInt(record.dst),
            .dst => .fromInt(record.src),
            .id => core.Error.Unsupported,
        };
    }

    pub fn isTaskPeer(context: *Context, peer_id: NodeId) !bool {
        const peer = (try context.node_view.readNodeRefById(peer_id)) orelse return error.InvalidRecord;
        return peer.kind == .task;
    }

    pub fn nodeIdValue(node_id: NodeId) u64 {
        return node_id.toInt();
    }
};

const task_hierarchy = task_hierarchy_mod.TaskHierarchy(TaskHierarchyOps);
const TaskHierarchyEdgeCollection = task_hierarchy.Collection;

fn collectVisibleTaskHierarchyEdgeRecordsLimited(
    allocator: std.mem.Allocator,
    store: storage.Store,
    order: storage.EdgeIndexOrder,
    task_id: core.NodeId,
    max_records: usize,
) !TaskHierarchyEdgeCollection {
    var node_view = try store.openNodeRecordView();
    defer node_view.deinit();
    var context = TaskHierarchyOps.Context{ .store = store, .node_view = &node_view };
    return task_hierarchy.collectLimited(allocator, &context, order, task_id, max_records);
}

fn readVisibleTaskHierarchyEdgeRecords(
    allocator: std.mem.Allocator,
    store: storage.Store,
    order: storage.EdgeIndexOrder,
    task_id: core.NodeId,
) !std.ArrayList(storage.EdgeIndexRecord) {
    var node_view = try store.openNodeRecordView();
    defer node_view.deinit();
    var context = TaskHierarchyOps.Context{ .store = store, .node_view = &node_view };
    return task_hierarchy.readComplete(
        allocator,
        &context,
        order,
        task_id,
        (core.QueryBudget{}).max_visited_edges,
    );
}

fn readVisibleTaskPacketChildEdgeRecords(
    allocator: std.mem.Allocator,
    store: storage.Store,
    order: storage.EdgeIndexOrder,
    task_id: core.NodeId,
) !std.ArrayList(storage.EdgeIndexRecord) {
    var node_view = try store.openNodeRecordView();
    defer node_view.deinit();
    var context = TaskHierarchyOps.Context{ .store = store, .node_view = &node_view };
    return task_hierarchy.readPacketHistory(
        allocator,
        &context,
        order,
        task_id,
        (core.QueryBudget{}).max_visited_edges,
    );
}

/// Deliberately returns a prefix when the adjacency exceeds `max_records`.
/// Callers must expose their own truncation semantics; correctness checks use
/// the complete variant below instead.
fn readVisibleEdgeRecordsByNodeLimited(
    allocator: std.mem.Allocator,
    store: storage.Store,
    order: storage.EdgeIndexOrder,
    node_id: core.NodeId,
    rel_filter: ?core.RelKind,
    max_records: usize,
) !std.ArrayList(storage.EdgeIndexRecord) {
    const collected = try collectVisibleEdgeRecordsByNodeLimited(allocator, store, order, node_id, rel_filter, max_records);
    return collected.records;
}

/// A bounded complete read: refuse to turn edge pressure into an incomplete
/// answer when callers use the result for lifecycle or graph invariants.
fn readVisibleEdgeRecordsByNodeCompleteLimited(
    allocator: std.mem.Allocator,
    store: storage.Store,
    order: storage.EdgeIndexOrder,
    node_id: core.NodeId,
    rel_filter: ?core.RelKind,
    max_records: usize,
) !std.ArrayList(storage.EdgeIndexRecord) {
    var collected = try collectVisibleEdgeRecordsByNodeLimited(allocator, store, order, node_id, rel_filter, max_records);
    if (collected.truncated) {
        collected.records.deinit(allocator);
        return core.Error.BudgetExceeded;
    }
    return collected.records;
}

fn readVisibleEdgeRecordsByNode(
    allocator: std.mem.Allocator,
    store: storage.Store,
    order: storage.EdgeIndexOrder,
    node_id: core.NodeId,
    rel_filter: ?core.RelKind,
) !std.ArrayList(storage.EdgeIndexRecord) {
    return try readVisibleEdgeRecordsByNodeCompleteLimited(
        allocator,
        store,
        order,
        node_id,
        rel_filter,
        (core.QueryBudget{}).max_visited_edges,
    );
}

fn taskEdgeLookaheadLimit(limit: usize) usize {
    const cursor_budget = (core.QueryBudget{}).max_visited_edges;
    if (cursor_budget == 0) return 0;
    // Reserve one cursor visit for the caller's truncation lookahead.  Asking
    // for the full cursor budget would fail before that extra edge reached the
    // callback, turning an intentionally bounded metric into BudgetExceeded.
    return @min(cursor_budget - 1, limit +| 1);
}

fn taskHasNonCompletedChildren(
    allocator: std.mem.Allocator,
    store: storage.Store,
    task_id: core.NodeId,
    now_ns: u64,
) !bool {
    var records = try readVisibleTaskHierarchyEdgeRecords(allocator, store, .src, task_id);
    defer records.deinit(allocator);
    var child_ids = std.ArrayList(core.NodeId).empty;
    defer child_ids.deinit(allocator);
    for (records.items) |record| {
        try child_ids.append(allocator, .fromInt(record.dst));
    }
    if (child_ids.items.len == 0) return false;
    var status_snapshot = try task.StatusSnapshot.initForNodeIds(allocator, store, child_ids.items);
    defer status_snapshot.deinit();
    var node_view = try store.openNodeRecordView();
    defer node_view.deinit();
    for (child_ids.items) |child_id| {
        var child = (try node_view.readNodeById(allocator, child_id)) orelse return error.InvalidRecord;
        defer child.deinit(allocator);
        if (child.kind == .task) {
            if ((try status_snapshot.statusForStoredNode(child, now_ns)) != .completed) return true;
        } else if (status_snapshot.isLegacyClosedTaskNode(child)) {
            continue;
        }
    }
    return false;
}

/// Validate a terminal transition without mutating the store. `force` is
/// intentionally limited to lease ownership: it never bypasses dependency or
/// child-completion invariants. Terminal same-status retries skip lease checks
/// so a crash after the status commit marker remains safely idempotent.
fn validateTaskCloseTransition(
    allocator: std.mem.Allocator,
    store: storage.Store,
    node: storage.StoredNode,
    requested_status: task.Status,
    by: ?[]const u8,
    force: bool,
    now_ns: u64,
) !task.Status {
    if (node.kind != .task or !requested_status.isTerminal()) return error.InvalidTaskTransition;
    const validated_by = if (by) |identity| try validateAgentIdentity(identity) else null;
    var lifecycle_snapshot = try task.StatusSnapshot.initForNodeIds(allocator, store, &.{node.id});
    defer lifecycle_snapshot.deinit();
    const lifecycle = try lifecycle_snapshot.statusForStoredNode(node, now_ns);
    if (lifecycle.isTerminal()) {
        if (lifecycle != requested_status) return error.InvalidTaskTransition;
        return lifecycle;
    }

    const lifecycle_fields = lifecycle_snapshot.fields(node.id);
    const holder = lifecycle_fields.claimed_by;
    const held_expires = lifecycle_fields.claim_expires_ns orelse 0;
    const lease_live = holder != null and holder.?.len != 0 and held_expires > now_ns;
    if (lease_live and !force) {
        const by_matches = if (validated_by) |identity| std.mem.eql(u8, identity, holder.?) else false;
        if (!by_matches) return error.ClaimHeld;
    }

    if (requested_status == .completed) {
        if (try taskHasNonCompletedChildren(allocator, store, node.id, now_ns)) return error.TaskHasOpenChildren;
        if ((try task.readyStateWithPersistentStoreSnapshotAt(allocator, store, node.id, now_ns, &lifecycle_snapshot)) != .ready) return error.TaskNotReady;
    }
    return lifecycle;
}

fn taskEvidenceKindAllowed(kind: core.NodeKind) bool {
    return switch (kind) {
        .verification, .evidence, .error_event, .fix, .observation => true,
        else => false,
    };
}

fn ensureTaskEvidenceEdge(
    allocator: std.mem.Allocator,
    store: storage.Store,
    task_id: core.NodeId,
    evidence_id: core.NodeId,
) !void {
    var evidence = (try store.readNodeById(allocator, evidence_id)) orelse return core.Error.NotFound;
    defer evidence.deinit(allocator);
    if (!taskEvidenceKindAllowed(evidence.kind)) return core.Error.InvalidId;

    var records = try readVisibleEdgeRecordsByNode(allocator, store, .src, task_id, .verified_by);
    defer records.deinit(allocator);
    for (records.items) |record| {
        if (record.dst == evidence_id.toInt()) return;
    }
    _ = try dag.addEdgeCheckedWithPersistentStore(allocator, store, task_id, .verified_by, evidence_id, .{});
}

/// Find-or-create verification evidence after task-close authorization has
/// succeeded and while the same CLI store lock is still held. This closes the
/// client-side race where an invalid lease holder could create an orphan
/// verification before task-close rejected the transition. The evidence node
/// and edge intentionally precede the terminal property batch: both writes are
/// idempotent, so a crash can be retried without duplicating evidence.
fn ensureTaskEvidenceTextNode(
    allocator: std.mem.Allocator,
    store: storage.Store,
    text: []const u8,
    recorded_ns: u128,
) !core.NodeId {
    const governance_args = ParsedNodeTextGovernanceArgs{
        .kind_label = "verification",
        .text = text,
        .schema_type = "verification",
        .recorded_ns = recorded_ns,
    };
    try validateNodeWriteGranularity(governance_args);
    const candidate_limit = currentGenerationLookupCandidateLimit(1);
    var matches = store.lookupNodesByTextLimited(allocator, .verification, text, candidate_limit) catch |err| switch (err) {
        error.FileNotFound, error.InvalidRecord => retry: {
            try store.repairPersistentIndexesFromLog();
            break :retry try store.lookupNodesByTextLimited(allocator, .verification, text, candidate_limit);
        },
        else => |e| return e,
    };
    defer {
        for (matches.items) |*node| node.deinit(allocator);
        matches.deinit(allocator);
    }
    for (matches.items) |*node| {
        if (try nodeIsCurrentGeneration(store, node.id)) return node.id;
    }
    const id = try store.addNode(.verification, text);
    try applyNodeGovernanceProperties(allocator, store, id, governance_args, null);
    return id;
}

fn parseTaskAncestryArgs(rest: []const []const u8) !ParsedTaskAncestryArgs {
    var task_id: ?[]const u8 = null;
    var depth: usize = 3;
    var limit: usize = 16;

    var pos: usize = 0;
    while (pos < rest.len) {
        const arg = rest[pos];
        if (std.mem.eql(u8, arg, "--depth")) {
            if (pos + 1 >= rest.len) return error.MissingArgument;
            const parsed_depth = std.fmt.parseInt(usize, rest[pos + 1], 10) catch return error.InvalidLimit;
            if (parsed_depth == 0 or parsed_depth > 8) return error.InvalidLimit;
            depth = parsed_depth;
            pos += 2;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            if (pos + 1 >= rest.len) return error.MissingArgument;
            const parsed_limit = std.fmt.parseInt(usize, rest[pos + 1], 10) catch return error.InvalidLimit;
            if (parsed_limit == 0 or parsed_limit > (core.QueryBudget{}).max_results) return error.InvalidLimit;
            limit = parsed_limit;
            pos += 2;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownOption;
        } else {
            if (task_id != null) return error.TooManyArguments;
            task_id = arg;
            pos += 1;
        }
    }

    return .{
        .task_id = task_id orelse return error.MissingArgument,
        .depth = depth,
        .limit = limit,
    };
}

fn parseTaskMetricsArgs(rest: []const []const u8) !ParsedTaskMetricsArgs {
    var root_id: ?[]const u8 = null;
    var limit: usize = 64;

    var pos: usize = 0;
    while (pos < rest.len) {
        const arg = rest[pos];
        if (std.mem.eql(u8, arg, "--limit")) {
            if (pos + 1 >= rest.len) return error.MissingArgument;
            const parsed_limit = std.fmt.parseInt(usize, rest[pos + 1], 10) catch return error.InvalidLimit;
            if (parsed_limit == 0 or parsed_limit > (core.QueryBudget{}).max_results) return error.InvalidLimit;
            limit = parsed_limit;
            pos += 2;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownOption;
        } else {
            if (root_id != null) return error.TooManyArguments;
            root_id = arg;
            pos += 1;
        }
    }

    return .{
        .root_id = root_id orelse return error.MissingArgument,
        .limit = limit,
    };
}

fn loadSchemaRegistryFromSchemaArg(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedSchemaArg) !schema.Registry {
    var registry = if (parsed.schema_path) |path| try schema_document_registry_loader.loadSchemaRegistryFile(allocator, io, path) else blk: {
        var base = schema.Registry.init(allocator);
        errdefer base.deinit();
        try base.addKernelTypes();
        break :blk base;
    };
    errdefer registry.deinit();
    if (parsed.profiles) |profiles| try addBuiltinProfilesFromCsv(&registry, profiles);
    return registry;
}

fn schemaArgLabelAlloc(allocator: std.mem.Allocator, parsed: ParsedSchemaArg) ![]u8 {
    if (parsed.schema_path) |path| {
        if (parsed.profiles) |profiles| return try std.fmt.allocPrint(allocator, "{s}+profiles:{s}", .{ path, profiles });
        return try allocator.dupe(u8, path);
    }
    if (parsed.profiles) |profiles| return try std.fmt.allocPrint(allocator, "kernel+profiles:{s}", .{profiles});
    return try allocator.dupe(u8, "kernel");
}

const EffectiveSchemaRegistry = struct {
    registry: schema.Registry,
    enforce_application_schema: bool,

    fn deinit(self: *EffectiveSchemaRegistry) void {
        self.registry.deinit();
        self.* = undefined;
    }
};

fn loadEffectiveSchemaRegistry(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    schema_path: ?[]const u8,
) !EffectiveSchemaRegistry {
    if (schema_path) |path| {
        return .{
            .registry = try loadSchemaRegistryFile(allocator, io, path),
            .enforce_application_schema = true,
        };
    }
    if (try store.readCatalog()) |catalog_value| {
        var source_catalog = catalog_value;
        defer source_catalog.deinit();
        const enforce_application_schema = catalogHasApplicationSchema(source_catalog);
        const registry = source_catalog.registry;
        // Transfer registry ownership out of the decoded catalog while still
        // letting its profile/retired metadata follow the normal deinit path.
        source_catalog.registry = schema.Registry.init(allocator);
        return .{
            .registry = registry,
            .enforce_application_schema = enforce_application_schema,
        };
    }
    var registry = schema.Registry.init(allocator);
    errdefer registry.deinit();
    try registry.addKernelTypes();
    return .{
        .registry = registry,
        .enforce_application_schema = false,
    };
}

fn parseNodeKindWithSchemaPolicy(label: []const u8, registry: schema.Registry, enforce_application_schema: bool) !core.NodeKind {
    if (registry.findNodeType(label)) |id| return @enumFromInt(id);
    const kind = parseCliNodeKind(label) orelse return error.UnknownNodeKind;
    if (enforce_application_schema and !registry.hasNodeTypeId(@intFromEnum(kind))) return error.UnknownNodeKind;
    return kind;
}

fn parseRelKindWithLoadedSchema(label: []const u8, registry: ?schema.Registry) !core.RelKind {
    if (registry) |loaded| {
        const id = loaded.findRelationType(label) orelse if (parseCliRelKind(label)) |rel| @intFromEnum(rel) else return error.UnknownRelationKind;
        return @enumFromInt(id);
    }
    return parseCliRelKind(label) orelse return error.InvalidRelKind;
}

fn parseRelKindWithSchemaPolicy(label: []const u8, registry: schema.Registry, enforce_application_schema: bool) !core.RelKind {
    if (registry.findRelationType(label)) |id| return @enumFromInt(id);
    const rel = parseCliRelKind(label) orelse return error.UnknownRelationKind;
    if (enforce_application_schema) try requireSchemaRelationIdentity(registry, rel);
    return rel;
}

fn requireSchemaRelationIdentity(registry: schema.Registry, rel: core.RelKind) !void {
    const id = @intFromEnum(rel);
    const expected_name = @tagName(rel);
    const actual_name = registry.relationTypeNameById(id) orelse return error.UnknownRelationKind;
    if (!std.mem.eql(u8, actual_name, expected_name)) return error.UnknownRelationKind;
    const name_id = registry.findRelationType(expected_name) orelse return error.UnknownRelationKind;
    if (name_id != id) return error.UnknownRelationKind;
}

fn validateImplicitSchemaRelation(
    registry: schema.Registry,
    enforce_application_schema: bool,
    src_kind: core.NodeKind,
    rel: core.RelKind,
    dst_kind: core.NodeKind,
) !void {
    if (!enforce_application_schema) return;
    try requireSchemaRelationIdentity(registry, rel);
    if (!registry.hasNodeTypeId(@intFromEnum(src_kind)) or !registry.hasNodeTypeId(@intFromEnum(dst_kind))) {
        return error.UnknownNodeKind;
    }
    const rule = registry.relationEndpointRuleById(@intFromEnum(rel)) orelse return error.UnknownRelationKind;
    const bad_src = if (rule.src) |src_set| !src_set.containsNodeKind(src_kind) else false;
    const bad_dst = if (rule.dst) |dst_set| !dst_set.containsNodeKind(dst_kind) else false;
    if (bad_src or bad_dst) return error.SchemaEndpointViolation;
}

fn parseCliNodeKind(label: []const u8) ?core.NodeKind {
    if (core.parseNodeKind(label)) |kind| return kind;
    if (std.ascii.eqlIgnoreCase(label, "note")) return .observation;
    if (std.mem.startsWith(u8, label, "type#")) {
        const id = std.fmt.parseInt(u16, label["type#".len..], 10) catch return null;
        return @enumFromInt(id);
    }
    return null;
}

fn parseCliRelKind(label: []const u8) ?core.RelKind {
    if (core.parseRelKind(label)) |rel| return rel;
    if (schema.markdownProjectionRelationIdByName(label)) |id| return @enumFromInt(id);
    if (std.ascii.eqlIgnoreCase(label, "supports")) return .evidences;
    if (std.mem.startsWith(u8, label, "rel#")) {
        const id = std.fmt.parseInt(u16, label["rel#".len..], 10) catch return null;
        return @enumFromInt(id);
    }
    return null;
}

fn pathExists(io: std.Io, path: []const u8) !bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    dir.close(io);
    return true;
}

fn anyPathExists(io: std.Io, path: []const u8) !bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch |dir_err| switch (dir_err) {
        error.FileNotFound, error.NotDir => {
            var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |file_err| switch (file_err) {
                error.FileNotFound, error.NotDir => return false,
                error.IsDir => return true,
                else => |e| return e,
            };
            defer file.close(io);
            return true;
        },
        else => |e| return e,
    };
    dir.close(io);
    return true;
}

fn existingTinyKgStorePath(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ db_path, "events.bin" });
    defer allocator.free(path);
    return fileExists(io, path);
}

fn fileExists(io: std.Io, path: []const u8) !bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.NotDir => return false,
        error.IsDir => return false,
        // Free-text commands probe their first token to distinguish an
        // optional database path from query text.  TinyQL labels contain ':';
        // that is valid query syntax but an invalid Windows filename.
        error.BadPathName, error.NameTooLong => return false,
        else => |e| return e,
    };
    defer file.close(io);
    return (try file.stat(io)).kind == .file;
}

fn storeFileSize(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8, file_name: []const u8) !?u64 {
    const path = try std.fs.path.join(allocator, &.{ db_path, file_name });
    defer allocator.free(path);
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => |e| return e,
    };
    if (stat.kind != .file) return null;
    return stat.size;
}

fn persistentTextCatalogFilesPresent(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !bool {
    const text_docs_exists = (try storeFileSize(allocator, io, db_path, "text_docs.idx")) != null;
    const text_terms_exists = (try storeFileSize(allocator, io, db_path, "text_terms.idx")) != null;
    const text_postings_exists = (try storeFileSize(allocator, io, db_path, "text_postings.dat")) != null;
    return text_docs_exists and text_terms_exists and text_postings_exists;
}

fn persistentTextCatalogWarm(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    db_path: []const u8,
) !bool {
    if (!try persistentTextCatalogFilesPresent(allocator, io, db_path)) return false;
    return !try text_search.persistentTextCatalogQuickStale(allocator, store);
}

const SchemaFileJson = schema_document_registry_loader.SchemaFileJson;
const parseSchemaFileDocument = schema_document_registry_loader.parseSchemaFileDocument;
const readSchemaFileBytesAlloc = schema_document_registry_loader.readSchemaFileBytesAlloc;
const parseSchemaFileBytes = schema_document_registry_loader.parseSchemaFileBytes;
const loadSchemaRegistryFile = schema_document_registry_loader.loadSchemaRegistryFile;
const loadSchemaRegistryBytes = schema_document_registry_loader.loadSchemaRegistryBytes;
const addBuiltinProfilesFromCsv = schema_document_registry_loader.addBuiltinProfilesFromCsv;
const addBuiltinProfilesFromCsvForSchemaVersion = schema_document_registry_loader.addBuiltinProfilesFromCsvForSchemaVersion;
const addBuiltinProfileFromLabel = schema_document_registry_loader.addBuiltinProfileFromLabel;
const addBuiltinProfileFromLabelForSchemaVersion = schema_document_registry_loader.addBuiltinProfileFromLabelForSchemaVersion;
const schemaRelationClassNamespace = schema_document_registry_loader.schemaRelationClassNamespace;
const node_text_char_limit = governed_node_write_admission.node_text_char_limit;
const node_llm_metadata_field_char_limit = governed_node_write_admission.node_llm_metadata_field_char_limit;
const node_llm_metadata_total_char_limit = governed_node_write_admission.node_llm_metadata_total_char_limit;
const validateNodeTextGranularity = governed_node_write_admission.validateNodeTextGranularity;
const validateNodeLlmMetadataGranularity = governed_node_write_admission.validateNodeLlmMetadataGranularity;

fn validateEdgeStringProperty(value: []const u8) !void {
    const chars = std.unicode.utf8CountCodepoints(value) catch return error.InvalidRecord;
    if (chars == 0 or chars > node_llm_metadata_field_char_limit) return error.NodePropertyTooLarge;
}

fn validateParsedStringProperty(owner: storage.PropertyOwner, key: []const u8, value: []const u8) !void {
    switch (owner) {
        .node => {
            if (std.mem.eql(u8, key, "summary")) {
                try validateNodeLlmMetadataGranularity(null, value, null);
            } else if (std.mem.eql(u8, key, "retrieval_hints")) {
                try validateNodeLlmMetadataGranularity(null, null, value);
            } else if (std.mem.eql(u8, key, "name")) {
                try validateNodeLlmMetadataGranularity(value, null, null);
            } else {
                return error.InvalidRecord;
            }
        },
        .edge => {
            // state 是**两态位**,不是连续置信度——严格只收 tentative|confirmed。
            // (设计铁律:禁止 0.67 之类编造的浮点置信度;一个 bit + 可溯源留痕更诚实。)
            if (std.mem.eql(u8, key, "state")) {
                if (!std.mem.eql(u8, value, "tentative") and !std.mem.eql(u8, value, "confirmed")) {
                    return error.InvalidRecord;
                }
            } else {
                try validateEdgeStringProperty(value);
            }
        },
    }
}

const validateSchemaStringPropertyWrite = governed_node_write_admission.validateSchemaStringPropertyWrite;
const validateSchemaUintPropertyWrite = governed_node_write_admission.validateSchemaUintPropertyWrite;
const validateNodeWriteGranularity = governed_node_write_admission.validateNodeWriteGranularity;

const JsonlLineFile = struct {
    bytes: []u8 = &.{},
    records: []const []const u8 = &.{},

    pub fn deinit(self: JsonlLineFile, allocator: std.mem.Allocator) void {
        if (self.records.len != 0) allocator.free(self.records);
        if (self.bytes.len != 0) allocator.free(self.bytes);
    }
};

fn loadJsonlLineFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max_bytes: u64) !JsonlLineFile {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind != .file or stat.size > max_bytes) return error.InvalidRecord;
    if (stat.size == 0) return .{};

    const size: usize = @intCast(stat.size);
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const read = try file.readPositionalAll(io, bytes, 0);
    if (read != bytes.len) return error.InvalidRecord;

    var records = std.ArrayList([]const u8).empty;
    errdefer records.deinit(allocator);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try records.append(allocator, trimmed);
    }

    return .{
        .bytes = bytes,
        .records = try records.toOwnedSlice(allocator),
    };
}

fn fileSize(io: std.Io, path: []const u8) !u64 {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind != .file) return error.InvalidRecord;
    return stat.size;
}

const MetaknowReplayInterchangeDataPlaneOps = struct {
    pub const BenchMetaknowReplayValue = BenchMetaknowReplay;
    pub const BenchMetaknowReplayEdgeStatsValue = BenchMetaknowReplayEdgeStats;
    pub const BenchNodeLoadTimingsValue = BenchNodeLoadTimings;
    pub const BenchTextDensityStatsValue = BenchTextDensityStats;
    pub const CliStoreLockValue = CliStoreLock;
    pub const ImportPublicationResultValue = ImportPublicationResult;
    pub const ImportTransactionExpectationValue = ImportTransactionExpectation;
    pub const MetaknowReplayImportResultValue = MetaknowReplayImportResult;
    pub const QueryOutputWriterValue = QueryOutputWriter;
    pub const StoreContentIdentityValue = StoreContentIdentity;
    pub const agentValue = agent;
    pub const anyPathExistsValue = anyPathExists;
    pub const builtinValue = builtin;
    pub const canonicalProspectivePathValue = canonicalProspectivePath;
    pub const coreValue = core;
    pub const createOwnedDirectoryValue = createOwnedDirectory;
    pub const dagValue = dag;
    pub const fileExistsValue = fileExists;
    pub const finalizeContentDigestValue = finalizeContentDigest;
    pub const graphValue = graph;
    pub const hashLengthPrefixedValue = hashLengthPrefixed;
    pub const hashStoreFileValue = hashStoreFile;
    pub const importPublicationMatchesSourceValue = importPublicationMatchesSource;
    pub const importStagingPathValue = importStagingPath;
    pub const importTransactionMarkerPathValue = importTransactionMarkerPath;
    pub const import_publish_lock_suffixValue = import_publish_lock_suffix;
    pub const import_transaction_marker_formatValue = import_transaction_marker_format;
    pub const import_transaction_marker_legacy_formatValue = import_transaction_marker_legacy_format;
    pub const loadBenchMetaknowReplayValue = loadBenchMetaknowReplay;
    pub const metaknow_replay_workloadValue = metaknow_replay_workload;
    pub const pathsOverlapValue = pathsOverlap;
    pub const publishImportedStoreValue = publishImportedStore;
    pub const queryValue = query;
    pub const recoverCompletedImportValue = recoverCompletedImport;
    pub const recoverImportStagingValue = recoverImportStaging;
    pub const rewriteTransactionMarkerFormatForTestValue = rewriteTransactionMarkerFormatForTest;
    pub const runValue = run;
    pub const schemaValue = schema;
    pub const stdValue = std;
    pub const storageValue = storage;
    pub const storeContentIdentityValue = storeContentIdentity;
    pub const syncExportDirectoryTreeValue = syncExportDirectoryTree;
    pub const syncParentDirectoryValue = syncParentDirectory;
    pub const taskValue = task;
    pub const text_searchValue = text_search;
    pub const transactionMarkerHasFormatForTestValue = transactionMarkerHasFormatForTest;
    pub const writeImportTransactionMarkerValue = writeImportTransactionMarker;
    pub const writeStoreManifestValue = writeStoreManifest;
};

const metaknow_replay_interchange_data_plane = metaknow_replay_interchange_data_plane_mod.MetaknowReplayInterchangeDataPlane(MetaknowReplayInterchangeDataPlaneOps);
const MetaknowDeferredBasedOnSidecarPairs = metaknow_replay_interchange_data_plane.MetaknowDeferredBasedOnSidecarPairs;
const copyMetaknowDeferredBasedOnSidecarForMigration = metaknow_replay_interchange_data_plane.copyMetaknowDeferredBasedOnSidecarForMigration;
const importMetaknowReplayCorpus = metaknow_replay_interchange_data_plane.importMetaknowReplayCorpus;
const metaknowDeferredBasedOnPath = metaknow_replay_interchange_data_plane.metaknowDeferredBasedOnPath;
const metaknowDeferredBasedOnPathForDb = metaknow_replay_interchange_data_plane.metaknowDeferredBasedOnPathForDb;
const metaknow_deferred_based_on_header_len = metaknow_replay_interchange_data_plane.metaknow_deferred_based_on_header_len;
const normalizeMetaknowDeferredBasedOnPairs = metaknow_replay_interchange_data_plane.normalizeMetaknowDeferredBasedOnPairs;
const pruneMetaknowDeferredBasedOnPairsForNode = metaknow_replay_interchange_data_plane.pruneMetaknowDeferredBasedOnPairsForNode;
const readMetaknowDeferredBasedOnSidecarForwardPairs = metaknow_replay_interchange_data_plane.readMetaknowDeferredBasedOnSidecarForwardPairs;
const restoreMetaknowDeferredBasedOnSidecar = metaknow_replay_interchange_data_plane.restoreMetaknowDeferredBasedOnSidecar;
const writeMetaknowDeferredBasedOnForwardPairsSidecar = metaknow_replay_interchange_data_plane.writeMetaknowDeferredBasedOnForwardPairsSidecar;

const native_jsonl_max_bytes: u64 = 256 * 1024 * 1024;
const native_jsonl_export_buffer_bytes: usize = 1024 * 1024;

const apply_batch_version: u32 = 1;
const apply_jsonl_max_bytes: u64 = 64 * 1024 * 1024;

const ApplyBatchResult = struct {
    nodes_created: usize = 0,
    nodes_existing: usize = 0,
    edges_created: usize = 0,
    edges_existing: usize = 0,
};

const ApplyHeaderJson = struct {
    version: u32,
};

const ApplyOpProbeJson = struct {
    op: ?[]const u8 = null,
    version: ?u32 = null,
};

const ApplyNodeJson = struct {
    op: []const u8,
    id: u64,
    kind: []const u8,
    name: []const u8,
};

const ApplyEdgeJson = struct {
    op: []const u8,
    id: u64,
    src: u64,
    rel: []const u8,
    dst: u64,
};

fn applyJsonlBatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    path: []const u8,
    registry: schema.Registry,
    enforce_application_schema: bool,
) !ApplyBatchResult {
    const lines = try loadJsonlLineFile(allocator, io, path, apply_jsonl_max_bytes);
    defer lines.deinit(allocator);
    if (lines.records.len == 0) return error.InvalidRecord;

    var header = try std.json.parseFromSlice(ApplyHeaderJson, allocator, lines.records[0], .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer header.deinit();
    if (header.value.version != apply_batch_version) return core.Error.Unsupported;

    var result = ApplyBatchResult{};
    for (lines.records[1..]) |line| {
        var probe = try std.json.parseFromSlice(ApplyOpProbeJson, allocator, line, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer probe.deinit();
        if (probe.value.version != null) return error.InvalidRecord;
        const op = probe.value.op orelse return error.InvalidRecord;
        if (std.mem.eql(u8, op, "node")) {
            var parsed = try std.json.parseFromSlice(ApplyNodeJson, allocator, line, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
            defer parsed.deinit();
            try applyNodeOp(allocator, store, registry, enforce_application_schema, parsed.value, &result);
        } else if (std.mem.eql(u8, op, "edge")) {
            var parsed = try std.json.parseFromSlice(ApplyEdgeJson, allocator, line, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
            defer parsed.deinit();
            try applyEdgeOp(store, registry, enforce_application_schema, parsed.value, &result);
        } else {
            return error.Unsupported;
        }
    }
    return result;
}

fn applyNodeOp(
    allocator: std.mem.Allocator,
    store: storage.Store,
    registry: schema.Registry,
    enforce_application_schema: bool,
    op: ApplyNodeJson,
    result: *ApplyBatchResult,
) !void {
    if (!std.mem.eql(u8, op.op, "node")) return error.InvalidRecord;
    const id = core.NodeId.fromInt(op.id);
    if (id == .none or id.toInt() == std.math.maxInt(u64)) return core.Error.InvalidId;
    // Resolve identity before application-schema enforcement so a byte-for-byte
    // replay of an existing historical/imported record remains idempotent.
    // The effective schema is still required below before any append.
    const kind = try parseNodeKindWithSchemaPolicy(op.kind, registry, false);
    if (try store.readNodeById(allocator, id)) |existing_node| {
        var existing = existing_node;
        defer existing.deinit(allocator);
        if (existing.kind != kind or !std.mem.eql(u8, existing.text, op.name)) return error.Conflict;
        result.nodes_existing += 1;
        return;
    }
    if (enforce_application_schema) {
        _ = try parseNodeKindWithSchemaPolicy(op.kind, registry, true);
    }
    try store.appendNode(.{
        .id = id,
        .kind = kind,
        .text = op.name,
    });
    result.nodes_created += 1;
}

fn applyEdgeOp(
    store: storage.Store,
    registry: schema.Registry,
    enforce_application_schema: bool,
    op: ApplyEdgeJson,
    result: *ApplyBatchResult,
) !void {
    if (!std.mem.eql(u8, op.op, "edge")) return error.InvalidRecord;
    const id = core.EdgeId.fromInt(op.id);
    if (id == .none or id.toInt() == std.math.maxInt(u64)) return core.Error.InvalidId;
    const src = core.NodeId.fromInt(op.src);
    const dst = core.NodeId.fromInt(op.dst);
    // Existing identical edges do not mutate the Store.  Resolve their stable
    // identity first, then enforce the catalog only on the append path.
    const rel = try parseRelKindWithSchemaPolicy(op.rel, registry, false);
    // `readEdgeById` returns `core.Error.InvalidId` for an absent edge id; treat that as
    // "not present" so the batch stays idempotent (existing identical edges are skipped).
    const existing_edge: ?graph.Edge = store.readEdgeById(id) catch |err| switch (err) {
        core.Error.InvalidId => null,
        else => |e| return e,
    };
    if (existing_edge) |existing| {
        if (existing.src != src or existing.dst != dst or existing.rel != rel) return error.Conflict;
        result.edges_existing += 1;
        return;
    }
    if (enforce_application_schema) {
        _ = try parseRelKindWithSchemaPolicy(op.rel, registry, true);
        try validateSchemaEdgeEndpoints(store, registry, src, rel, dst);
    }
    try store.appendEdge(.{
        .id = id,
        .src = src,
        .rel = rel,
        .dst = dst,
    });
    result.edges_created += 1;
}
const MarkdownProjectionDataPlaneOps = struct {
    pub const AgentWriteBatchJsonValue = AgentWriteBatchJson;
    pub const AgentWriteEdgePropertiesJsonValue = AgentWriteEdgePropertiesJson;
    pub const CliStoreLockValue = CliStoreLock;
    pub const ContentDigestValue = ContentDigest;
    pub const MarkdownAstImportSpecValue = MarkdownAstImportSpec;
    pub const MarkdownDocumentImportSpecValue = MarkdownDocumentImportSpec;
    pub const ParsedAgentWriteArgsValue = ParsedAgentWriteArgs;
    pub const ParsedAgentWriteJsonArgsValue = ParsedAgentWriteJsonArgs;
    pub const ParsedMarkdownDocEditBenchArgsValue = ParsedMarkdownDocEditBenchArgs;
    pub const ParsedRenderMarkdownDocumentArgsValue = ParsedRenderMarkdownDocumentArgs;
    pub const QueryOutputWriterValue = QueryOutputWriter;
    pub const StoreContentIdentityValue = StoreContentIdentity;
    pub const TextContextSizeValue = TextContextSize;
    pub const agentValue = agent;
    pub const anyPathExistsValue = anyPathExists;
    pub const canonicalPathsEqualValue = canonicalPathsEqual;
    pub const canonicalProspectivePathValue = canonicalProspectivePath;
    pub const cli_store_lock_suffixValue = cli_store_lock_suffix;
    pub const computeTextContextSizeValue = computeTextContextSize;
    pub const coreValue = core;
    pub const createOwnedDirectoryValue = createOwnedDirectory;
    pub const dagValue = dag;
    pub const elapsedNsValue = elapsedNs;
    pub const existingTinyKgStorePathValue = existingTinyKgStorePath;
    pub const fileExistsValue = fileExists;
    pub const graphValue = graph;
    pub const markdown_bootstrap_publish_lock_suffixValue = markdown_bootstrap_publish_lock_suffix;
    pub const markdown_bootstrap_staging_suffixValue = markdown_bootstrap_staging_suffix;
    pub const markdown_bootstrap_transaction_formatValue = markdown_bootstrap_transaction_format;
    pub const markdown_bootstrap_transaction_suffixValue = markdown_bootstrap_transaction_suffix;
    pub const monotonicNsValue = monotonicNs;
    pub const node_text_char_limitValue = node_text_char_limit;
    pub const parseNodeIdArgValue = parseNodeIdArg;
    pub const parseRelKindWithLoadedSchemaValue = parseRelKindWithLoadedSchema;
    pub const parseRelKindWithSchemaPolicyValue = parseRelKindWithSchemaPolicy;
    pub const pathsOverlapValue = pathsOverlap;
    pub const queryValue = query;
    pub const readStoreManifestSummaryValue = readStoreManifestSummary;
    pub const readVisibleEdgeRecordsByNodeValue = readVisibleEdgeRecordsByNode;
    pub const renamePathValue = renamePath;
    pub const renderNodeObjectJsonValue = renderNodeObjectJson;
    pub const renderTextContextSizeJsonValue = renderTextContextSizeJson;
    pub const runValue = run;
    pub const schemaValue = schema;
    pub const stdValue = std;
    pub const storageValue = storage;
    pub const storeContentIdentityValue = storeContentIdentity;
    pub const storeDirBytesValue = storeDirBytes;
    pub const syncExportDirectoryTreeValue = syncExportDirectoryTree;
    pub const syncParentDirectoryValue = syncParentDirectory;
    pub const validateGovernanceMetadataTokenValue = validateGovernanceMetadataToken;
    pub const validateNodeLlmMetadataGranularityValue = validateNodeLlmMetadataGranularity;
    pub const validateNodeTextGranularityValue = validateNodeTextGranularity;
    pub const validateParsedStringPropertyValue = validateParsedStringProperty;
    pub const validateSchemaEdgeEndpointsValue = validateSchemaEdgeEndpoints;
    pub const writeAtomicReplacementFileValue = writeAtomicReplacementFile;
    pub const writeJsonBoolFieldValue = writeJsonBoolField;
    pub const writeJsonFieldPrefixValue = writeJsonFieldPrefix;
    pub const writeJsonNullableStringFieldValue = writeJsonNullableStringField;
    pub const writeJsonNullableUsizeFieldValue = writeJsonNullableUsizeField;
    pub const writeJsonNumberFieldValue = writeJsonNumberField;
    pub const writeJsonObjectEndValue = writeJsonObjectEnd;
    pub const writeJsonObjectStartValue = writeJsonObjectStart;
    pub const writeJsonStringValue = writeJsonString;
    pub const writeJsonStringFieldValue = writeJsonStringField;
    pub const writeSearchContinuationValue = writeSearchContinuation;
    pub const writeStoreManifestValue = writeStoreManifest;
};

const markdown_projection_data_plane = markdown_projection_data_plane_mod.MarkdownProjectionDataPlane(MarkdownProjectionDataPlaneOps);
const MarkdownImportContext = markdown_projection_data_plane.MarkdownImportContext;
const agentWriteFactAndProjection = markdown_projection_data_plane.agentWriteFactAndProjection;
const agentWriteJsonBatch = markdown_projection_data_plane.agentWriteJsonBatch;
const agentWriteRenderRelSupported = markdown_projection_data_plane.agentWriteRenderRelSupported;
const appendMarkdownProjectionEdge = markdown_projection_data_plane.appendMarkdownProjectionEdge;
const evaluateMarkdownDocEditBenchGates = markdown_projection_data_plane.evaluateMarkdownDocEditBenchGates;
const executeMarkdownImport = markdown_projection_data_plane.executeMarkdownImport;
const gcMarkdownOrphanNodes = markdown_projection_data_plane.gcMarkdownOrphanNodes;
const lookupMarkdownProjectionEdgeByEndpoints = markdown_projection_data_plane.lookupMarkdownProjectionEdgeByEndpoints;
const markdownBootstrapStagingPath = markdown_projection_data_plane.markdownBootstrapStagingPath;
const markdownBootstrapTransactionPath = markdown_projection_data_plane.markdownBootstrapTransactionPath;
const markdownBootstrapTransactionTmpPath = markdown_projection_data_plane.markdownBootstrapTransactionTmpPath;
const markdownIncomingHeadingRel = markdown_projection_data_plane.markdownIncomingHeadingRel;
const markdownPreviewPrefixLen = markdown_projection_data_plane.markdownPreviewPrefixLen;
const markdownProjectionChildren = markdown_projection_data_plane.markdownProjectionChildren;
const markdownProjectionVisibleText = markdown_projection_data_plane.markdownProjectionVisibleText;
const markdownSubtreeSectionStats = markdown_projection_data_plane.markdownSubtreeSectionStats;
const markdownUtf8PrefixEndByChars = markdown_projection_data_plane.markdownUtf8PrefixEndByChars;
const markdown_nodes_dir = markdown_projection_data_plane.markdown_nodes_dir;
const markdown_readme_file = markdown_projection_data_plane.markdown_readme_file;
const md_rel_h1 = markdown_projection_data_plane.md_rel_h1;
const native_jsonl_deferred_based_on_file = markdown_projection_data_plane.native_jsonl_deferred_based_on_file;
const renderMarkdownDocEditBenchOutput = markdown_projection_data_plane.renderMarkdownDocEditBenchOutput;
const renderMarkdownDocument = markdown_projection_data_plane.renderMarkdownDocument;
const renderMarkdownDocumentJsonOutput = markdown_projection_data_plane.renderMarkdownDocumentJsonOutput;
const renderMarkdownDocumentPageJsonOutput = markdown_projection_data_plane.renderMarkdownDocumentPageJsonOutput;

const StoreMigrationFoundationOps = struct {
    pub const BackupTransactionExpectationValue = BackupTransactionExpectation;
    pub const CliStoreLockValue = CliStoreLock;
    pub const MigrationPropertyBatchValue = MigrationPropertyBatch;
    pub const MigrationPropertyLookupValue = MigrationPropertyLookup;
    pub const ParsedSchemaMigrateArgsValue = ParsedSchemaMigrateArgs;
    pub const QueryOutputWriterValue = QueryOutputWriter;
    pub const RestoreTransactionExpectationValue = RestoreTransactionExpectation;
    pub const SchemaFileJsonValue = SchemaFileJson;
    pub const SchemaMigrationTransactionExpectationValue = SchemaMigrationTransactionExpectation;
    pub const StoreMigrationV2TransactionExpectationValue = StoreMigrationV2TransactionExpectation;
    pub const agentValue = agent;
    pub const anyPathExistsValue = anyPathExists;
    pub const backupTransactionMarkerPathValue = backupTransactionMarkerPath;
    pub const builtinValue = builtin;
    pub const catalog_modValue = catalog_mod;
    pub const coreValue = core;
    pub const createOwnedDirectoryValue = createOwnedDirectory;
    pub const dagValue = dag;
    pub const existingTinyKgStorePathValue = existingTinyKgStorePath;
    pub const export_backup_suffixValue = export_backup_suffix;
    pub const export_temp_nonceValue = &export_temp_nonce;
    pub const export_transaction_marker_fileValue = export_transaction_marker_file;
    pub const export_transaction_marker_magicValue = export_transaction_marker_magic;
    pub const import_staging_suffixValue = import_staging_suffix;
    pub const import_transaction_marker_fileValue = import_transaction_marker_file;
    pub const import_transaction_marker_formatValue = import_transaction_marker_format;
    pub const import_transaction_marker_legacy_formatValue = import_transaction_marker_legacy_format;
    pub const parseSchemaFileDocumentValue = parseSchemaFileDocument;
    pub const pathsOverlapForCopyTargetValue = pathsOverlapForCopyTarget;
    pub const persistentNowNsValue = persistentNowNs;
    pub const recoverBackupStagingValue = recoverBackupStaging;
    pub const recoverRestoreStagingValue = recoverRestoreStaging;
    pub const recoverSchemaMigrationStagingValue = recoverSchemaMigrationStaging;
    pub const recoverStoreMigrationV2StagingValue = recoverStoreMigrationV2Staging;
    pub const restoreTransactionMarkerPathValue = restoreTransactionMarkerPath;
    pub const runValue = run;
    pub const schemaValue = schema;
    pub const schemaMigrationTransactionMarkerPathValue = schemaMigrationTransactionMarkerPath;
    pub const stdValue = std;
    pub const storageValue = storage;
    pub const storeContentIdentityValue = storeContentIdentity;
    pub const storeMigrationV2TransactionMarkerPathValue = storeMigrationV2TransactionMarkerPath;
    pub const taskValue = task;
    pub const text_searchValue = text_search;
    pub const versionValue = version;
    pub const writeBackupTransactionMarkerValue = writeBackupTransactionMarker;
    pub const writeJsonStringValue = writeJsonString;
    pub const writeRestoreTransactionMarkerValue = writeRestoreTransactionMarker;
    pub const writeSchemaMigrationTransactionMarkerValue = writeSchemaMigrationTransactionMarker;
    pub const writeStoreMigrationV2TransactionMarkerValue = writeStoreMigrationV2TransactionMarker;
};

const store_migration_foundation = store_migration_foundation_mod.StoreMigrationFoundation(StoreMigrationFoundationOps);
const ContentDigest = store_migration_foundation.ContentDigest;
const ExportPublicationRecovery = store_migration_foundation.ExportPublicationRecovery;
const ImportPublicationResult = store_migration_foundation.ImportPublicationResult;
const ImportTransactionExpectation = store_migration_foundation.ImportTransactionExpectation;
const MigrationEdgeSpool = store_migration_foundation.MigrationEdgeSpool;
const MigrationEdgeSpoolBuilder = store_migration_foundation.MigrationEdgeSpoolBuilder;
const MigrationEdgeStream = store_migration_foundation.MigrationEdgeStream;
const MigrationPropertyKeys = store_migration_foundation.MigrationPropertyKeys;
const MigrationPropertySpool = store_migration_foundation.MigrationPropertySpool;
const MigrationPropertySpoolRecord = store_migration_foundation.MigrationPropertySpoolRecord;
const MigrationPropertyStream = store_migration_foundation.MigrationPropertyStream;
const MigrationTargetPropertySpoolBuilder = store_migration_foundation.MigrationTargetPropertySpoolBuilder;
const StoreManifestSummary = store_migration_foundation.StoreManifestSummary;
const appendCatalogProfileLabel = store_migration_foundation.appendCatalogProfileLabel;
const appendSchemaDocumentProfilesToCatalog = store_migration_foundation.appendSchemaDocumentProfilesToCatalog;
const appendSchemaFileProfilesToCatalog = store_migration_foundation.appendSchemaFileProfilesToCatalog;
const catalogProfilesCsvAlloc = store_migration_foundation.catalogProfilesCsvAlloc;
const catalogProfilesMatchCsv = store_migration_foundation.catalogProfilesMatchCsv;
const cleanupExportPublicationAfterCommit = store_migration_foundation.cleanupExportPublicationAfterCommit;
const cleanupExportPublicationAfterCommitWithDeleteTree = store_migration_foundation.cleanupExportPublicationAfterCommitWithDeleteTree;
const coalesceMigrationEdgeRuns = store_migration_foundation.coalesceMigrationEdgeRuns;
const coalesceMigrationPropertyRuns = store_migration_foundation.coalesceMigrationPropertyRuns;
const collectKnownEdgeProperties = store_migration_foundation.collectKnownEdgeProperties;
const collectKnownNodeProperties = store_migration_foundation.collectKnownNodeProperties;
const contentDigestForBytes = store_migration_foundation.contentDigestForBytes;
const current_store_manifest_version = store_migration_foundation.current_store_manifest_version;
const current_storage_format_version = version.storage_format_version;
const current_schema_version = version.schema_version;
const encodeMigrationEdgeRecord = store_migration_foundation.encodeMigrationEdgeRecord;
const ensureDeclaredEdgePropertiesRetained = store_migration_foundation.ensureDeclaredEdgePropertiesRetained;
const ensureDeclaredNodePropertiesRetained = store_migration_foundation.ensureDeclaredNodePropertiesRetained;
const exportBackupPath = store_migration_foundation.exportBackupPath;
const exportTemporaryPath = store_migration_foundation.exportTemporaryPath;
const exportTransactionMarkerPresent = store_migration_foundation.exportTransactionMarkerPresent;
const finalizeContentDigest = store_migration_foundation.finalizeContentDigest;
const importPublicationMatchesSource = store_migration_foundation.importPublicationMatchesSource;
const importStagingPath = store_migration_foundation.importStagingPath;
const importTransactionMarkerPath = store_migration_foundation.importTransactionMarkerPath;
const initOwnedBulkImportStore = store_migration_foundation.initOwnedBulkImportStore;
const listMarkdownFilesRecursiveSorted = store_migration_foundation.listMarkdownFilesRecursiveSorted;
const markdownFileNameLessThan = store_migration_foundation.markdownFileNameLessThan;
const migrationPropertyKeyValid = store_migration_foundation.migrationPropertyKeyValid;
const migrationPropertySuppressedByTaskStatusV1 = store_migration_foundation.migrationPropertySuppressedByTaskStatusV1;
const migration_edge_merge_fan_in = store_migration_foundation.migration_edge_merge_fan_in;
const migration_edge_spool_record_len = store_migration_foundation.migration_edge_spool_record_len;
const migration_property_merge_fan_in = store_migration_foundation.migration_property_merge_fan_in;
const migration_property_spool_record_len = store_migration_foundation.migration_property_spool_record_len;
const publishExportDirectory = store_migration_foundation.publishExportDirectory;
const publishImportedStore = store_migration_foundation.publishImportedStore;
const readStoreManifestSummary = store_migration_foundation.readStoreManifestSummary;
const recoverCompletedImport = store_migration_foundation.recoverCompletedImport;
const recoverExportPublication = store_migration_foundation.recoverExportPublication;
const recoverImportStaging = store_migration_foundation.recoverImportStaging;
const renamePath = store_migration_foundation.renamePath;
const storeManifestPath = store_migration_foundation.storeManifestPath;
const syncExportDirectoryTree = store_migration_foundation.syncExportDirectoryTree;
const syncParentDirectory = store_migration_foundation.syncParentDirectory;
const updateImportDigest = store_migration_foundation.updateImportDigest;
const validateSchemaMigratePathRelationship = store_migration_foundation.validateSchemaMigratePathRelationship;
const validateSchemaMigratePaths = store_migration_foundation.validateSchemaMigratePaths;
const writeAtomicReplacementFile = store_migration_foundation.writeAtomicReplacementFile;
const writeExportTransactionMarker = store_migration_foundation.writeExportTransactionMarker;
const writeImportTransactionMarker = store_migration_foundation.writeImportTransactionMarker;
const writeRecoverableTransactionMarker = store_migration_foundation.writeRecoverableTransactionMarker;
const writeStoreManifest = store_migration_foundation.writeStoreManifest;

fn parseOptionalDbPath(args: []const []const u8, index: usize) ![]const u8 {
    if (args.len <= index) return defaultDbPath();
    if (args.len == index + 1) return args[index];
    return error.TooManyArguments;
}

const QueryOutputWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    max_bytes: usize = default_cli_output_byte_limit,

    pub fn writeAll(self: *QueryOutputWriter, bytes: []const u8) !void {
        const remaining = if (self.buffer.items.len <= self.max_bytes) self.max_bytes - self.buffer.items.len else 0;
        if (bytes.len > remaining) return error.RecordTooLarge;
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    pub fn print(self: *QueryOutputWriter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(text);
        try self.writeAll(text);
    }
};

fn writeEscapedText(writer: anytype, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            ':' => try writer.writeAll("\\:"),
            ',' => try writer.writeAll("\\,"),
            '\t' => try writer.writeAll("\\t"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            0x00...0x08, 0x0b...0x0c, 0x0e...0x1f, 0x7f => try writer.print("\\x{x:0>2}", .{byte}),
            else => try writer.writeAll(&.{byte}),
        }
    }
}

fn writeEscapedTextPrefix(writer: anytype, text: []const u8, max_bytes: usize) !void {
    if (text.len <= max_bytes) return writeEscapedText(writer, text);
    var end: usize = 0;
    while (end < text.len and end < max_bytes) {
        const width = std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
        if (end + width > text.len or end + width > max_bytes) break;
        end += width;
    }
    try writeEscapedText(writer, text[0..end]);
    try writer.writeAll("...");
}

fn writeNodeKindName(writer: anytype, kind: core.NodeKind) !void {
    inline for (@typeInfo(core.NodeKind).@"enum".fields) |field| {
        if (@intFromEnum(kind) == field.value) return writer.writeAll(field.name);
    }
    try writer.print("type#{}", .{@intFromEnum(kind)});
}

fn writeNodeKindNameWithSchema(writer: anytype, registry: ?schema.Registry, kind: core.NodeKind) !void {
    if (registry) |loaded| {
        if (loaded.nodeTypeNameById(@intFromEnum(kind))) |name| return writer.writeAll(name);
    }
    return writeNodeKindName(writer, kind);
}

fn nodeKindNameAlloc(allocator: std.mem.Allocator, kind: core.NodeKind) ![]u8 {
    var out = QueryOutputWriter{ .allocator = allocator };
    errdefer out.buffer.deinit(allocator);
    try writeNodeKindName(&out, kind);
    return out.buffer.toOwnedSlice(allocator);
}

fn nodeKindNameWithSchemaAlloc(allocator: std.mem.Allocator, registry: ?schema.Registry, kind: core.NodeKind) ![]u8 {
    var out = QueryOutputWriter{ .allocator = allocator };
    errdefer out.buffer.deinit(allocator);
    try writeNodeKindNameWithSchema(&out, registry, kind);
    return out.buffer.toOwnedSlice(allocator);
}

fn writeRelKindName(writer: anytype, rel: core.RelKind) !void {
    inline for (@typeInfo(core.RelKind).@"enum".fields) |field| {
        if (@intFromEnum(rel) == field.value) return writer.writeAll(field.name);
    }
    if (schema.markdownProjectionRelationNameById(@intFromEnum(rel))) |name| return writer.writeAll(name);
    try writer.print("rel#{}", .{@intFromEnum(rel)});
}

fn writeRelKindNameWithSchema(writer: anytype, registry: ?schema.Registry, rel: core.RelKind) !void {
    if (registry) |loaded| {
        if (loaded.relationTypeNameById(@intFromEnum(rel))) |name| return writer.writeAll(name);
    }
    return writeRelKindName(writer, rel);
}

fn relKindNameAlloc(allocator: std.mem.Allocator, rel: core.RelKind) ![]u8 {
    var out = QueryOutputWriter{ .allocator = allocator };
    errdefer out.buffer.deinit(allocator);
    try writeRelKindName(&out, rel);
    return out.buffer.toOwnedSlice(allocator);
}

fn relKindNameWithSchemaAlloc(allocator: std.mem.Allocator, registry: ?schema.Registry, rel: core.RelKind) ![]u8 {
    var out = QueryOutputWriter{ .allocator = allocator };
    errdefer out.buffer.deinit(allocator);
    try writeRelKindNameWithSchema(&out, registry, rel);
    return out.buffer.toOwnedSlice(allocator);
}

fn writeJsonString(writer: *QueryOutputWriter, text: []const u8) !void {
    try writer.writeAll("\"");
    const hex = "0123456789abcdef";
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...0x07, 0x0b, 0x0c, 0x0e...0x1f => {
                var escaped = [_]u8{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 0x0f] };
                try writer.writeAll(&escaped);
            },
            else => {
                const single = [_]u8{byte};
                try writer.writeAll(&single);
            },
        }
    }
    try writer.writeAll("\"");
}

fn writeJsonObjectStart(writer: *QueryOutputWriter) !void {
    try writer.writeAll("{");
}

fn writeJsonObjectEnd(writer: *QueryOutputWriter) !void {
    try writer.writeAll("}\n");
}

fn writeJsonFieldPrefix(writer: *QueryOutputWriter, field: []const u8, first_field: *bool) !void {
    if (first_field.*) {
        first_field.* = false;
    } else {
        try writer.writeAll(",");
    }
    try writeJsonString(writer, field);
    try writer.writeAll(":");
}

fn writeJsonStringField(writer: *QueryOutputWriter, field: []const u8, value: []const u8, first_field: *bool) !void {
    try writeJsonFieldPrefix(writer, field, first_field);
    try writeJsonString(writer, value);
}

fn writeJsonNullableStringField(writer: *QueryOutputWriter, field: []const u8, value: ?[]const u8, first_field: *bool) !void {
    try writeJsonFieldPrefix(writer, field, first_field);
    if (value) |text| {
        try writeJsonString(writer, text);
    } else {
        try writer.writeAll("null");
    }
}

fn writeJsonNumberField(writer: *QueryOutputWriter, field: []const u8, value: anytype, first_field: *bool) !void {
    try writeJsonFieldPrefix(writer, field, first_field);
    try writer.print("{}", .{value});
}

fn writeJsonNullableUsizeField(writer: *QueryOutputWriter, field: []const u8, value: ?usize, first_field: *bool) !void {
    try writeJsonFieldPrefix(writer, field, first_field);
    if (value) |number| {
        try writer.print("{}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

fn writeJsonBoolField(writer: *QueryOutputWriter, field: []const u8, value: bool, first_field: *bool) !void {
    try writeJsonFieldPrefix(writer, field, first_field);
    try writer.writeAll(if (value) "true" else "false");
}

const TextContextSize = struct {
    text_bytes: usize,
    text_chars: usize,
    text_lines: usize,
    size_version: u8 = 1,
};

fn computeTextContextSize(text: []const u8) !TextContextSize {
    const chars = std.unicode.utf8CountCodepoints(text) catch return error.InvalidRecord;
    var lines: usize = 0;
    if (text.len != 0) {
        lines = 1;
        for (text) |byte| {
            if (byte == '\n') lines = std.math.add(usize, lines, 1) catch return error.RecordTooLarge;
        }
    }
    return .{
        .text_bytes = text.len,
        .text_chars = chars,
        .text_lines = lines,
    };
}

fn renderTextContextSizeJson(writer: *QueryOutputWriter, size: TextContextSize) !void {
    try writer.writeAll("{");
    var first = true;
    try writeJsonNumberField(writer, "text_bytes", size.text_bytes, &first);
    try writeJsonNumberField(writer, "text_chars", size.text_chars, &first);
    try writeJsonNumberField(writer, "text_lines", size.text_lines, &first);
    try writeJsonNumberField(writer, "size_version", size.size_version, &first);
    try writer.writeAll("}");
}

const NodeLocalGraphStats = struct {
    in_degree: usize = 0,
    out_degree: usize = 0,
};

/// segment-aware 读某节点的 contain 出边 dst 集(committed 索引 + delta segment 合并)。
/// **必须用这条路**(Linus BLOCKER 实证):edgeIndexRecordsByNodeAndRelationIterator 只读
/// committed 索引,>1024 边 store 上新 contain 边落 delta segment 会被无视 → BFS 瞎(--project
/// 静默空)/ link 去重失效(重复边累积)/ delete-node 子节点保护失效。
fn collectContainChildIds(
    allocator: std.mem.Allocator,
    store: storage.Store,
    node_id: core.NodeId,
) !std.ArrayList(u64) {
    return collectChildIdsByRel(allocator, store, node_id, .contain_only);
}

/// membership 下钻档位:
/// - contain_only:纯治理树(reparent 环检查用——治理结构自身)。
/// - task_composition:contain + legacy contains(list-recent 用:锚下任务树可见,
///   但 **不含 md:*** —— section 碎片会淹没最近清单,文档以根代表)。
/// - full_composition:contain + contains + md:*(search membership 用:
///   section 正文命中必须穿过 --project 过滤)。
const MembershipDescent = enum { contain_only, task_composition, full_composition };

fn collectChildIdsByRel(
    allocator: std.mem.Allocator,
    store: storage.Store,
    node_id: core.NodeId,
    descent: MembershipDescent,
) !std.ArrayList(u64) {
    var records = try store.readVisibleEdgeIndexRecordsByNodeForOrderedTraversal(allocator, node_id);
    defer records.deinit(allocator);
    var out = std.ArrayList(u64).empty;
    errdefer out.deinit(allocator);
    for (records.items) |r| {
        const keep = r.rel == @intFromEnum(core.RelKind.contain) or switch (descent) {
            .contain_only => false,
            .task_composition => r.rel == @intFromEnum(core.RelKind.contains),
            .full_composition => isCompositionRel(r.rel),
        };
        if (keep) try out.append(allocator, r.dst);
    }
    return out;
}

/// composition/membership 关系判定:legacy contains(id=0,任务树/通用层级)+ md:* 投影段
/// (3000..3023,import-md-doc 的 document→heading→paragraph 结构边;实证 md:h1/md:h2/
/// md:paragraph——不是 contains,漏掉它们 section 正文就不在 search --project membership 里)。
fn isCompositionRel(rel: u16) bool {
    if (rel == @intFromEnum(core.RelKind.contains)) return true;
    return schema.isMdProjectionRelId(rel); // 精确集合(单一真理源在 schema.zig,挨常量定义)
}

test "isCompositionRel 覆盖全部注册 md:* 投影 rel(单一真理源锁)" {
    // 防复刻"markdown 召回全灭":每个 md_projection_rel_ids 成员必须被 membership 下钻覆盖;
    // 未注册的空隙(3006..3009)与界外(3024)必须不误染。
    for (schema.md_projection_rel_ids) |id| try std.testing.expect(isCompositionRel(id));
    try std.testing.expect(!isCompositionRel(3006));
    try std.testing.expect(!isCompositionRel(3024));
    try std.testing.expect(isCompositionRel(@intFromEnum(core.RelKind.contains)));
    try std.testing.expect(!isCompositionRel(@intFromEnum(core.RelKind.contain)));
}

/// Link a node to its project parent via a contain edge.
/// Silently skips if the parent node doesn't exist — regular nodes are allowed to be orphan,
/// and will be linked to a project via explicit contain edges when needed.
/// project 三锚类型(乙方案)。锚的身份 = schema_type 属性(task_anchor/docs_anchor/
/// memory_anchor);task 锚用 task kind(frontier 可直接以锚为查询根),docs/memory 锚
/// 用 concept kind(纯结构节点,不进任务/文档语义)。
const AnchorType = enum {
    task,
    docs,
    memory,

    fn schemaType(self: AnchorType) []const u8 {
        return switch (self) {
            .task => "task_anchor",
            .docs => "docs_anchor",
            .memory => "memory_anchor",
        };
    }

    fn nodeKind(self: AnchorType) core.NodeKind {
        return switch (self) {
            .task => .task,
            .docs, .memory => .concept,
        };
    }

    fn defaultText(self: AnchorType) []const u8 {
        return switch (self) {
            .task => "任务面(task anchor)",
            .docs => "文档面(docs anchor)",
            .memory => "记忆面(memory anchor)",
        };
    }
};

fn parseAnchorType(value: []const u8) ?AnchorType {
    if (std.ascii.eqlIgnoreCase(value, "task")) return .task;
    if (std.ascii.eqlIgnoreCase(value, "docs")) return .docs;
    if (std.ascii.eqlIgnoreCase(value, "memory")) return .memory;
    return null;
}

/// project 树目录不变量:project 节点的 contain 父只能是 project(嵌套项目=树目录,
/// 限域搜索的地基;锚/任务/记忆不得"收养"project)。只约束 dst 是 project 的边。
fn validateContainProjectTree(allocator: std.mem.Allocator, store: storage.Store, src: core.NodeId, dst: core.NodeId) !void {
    var dst_node = (try store.readNodeById(allocator, dst)) orelse return core.Error.NotFound;
    defer dst_node.deinit(allocator);
    if (dst_node.kind != .project) return;
    var src_node = (try store.readNodeById(allocator, src)) orelse return core.Error.NotFound;
    defer src_node.deinit(allocator);
    if (src_node.kind != .project) return error.ProjectTreeViolation;
}

fn linkNodeToProjectParent(
    allocator: std.mem.Allocator,
    store: storage.Store,
    node_id: core.NodeId,
    parent_node_id: core.NodeId,
) !void {
    var node_view = try store.openNodeByIdIndexView();
    defer node_view.deinit();
    if (!try node_view.nodeExists(parent_node_id)) return;
    // 去重:segment-aware 读(delta 上的已有 contain 边也可见,防重复边累积)。
    var children = try collectContainChildIds(allocator, store, parent_node_id);
    defer children.deinit(allocator);
    for (children.items) |dst| {
        if (dst == node_id.toInt()) return; // already linked
    }
    // 树目录约束 + DAG 防环(contain 已进 dag 关系集;此前裸 appendEdge 是防环盲区)。
    try validateContainProjectTree(allocator, store, parent_node_id, node_id);
    // 项目级 schema block 档:挂接前校验 scope,违规则拒绝(原子失败,不写边)。
    try enforceSchemaScopeAtWrite(allocator, store, node_id, parent_node_id);
    _ = try dag.addEdgeCheckedWithPersistentStore(allocator, store, parent_node_id, .contain, node_id, .{});
}

/// Collect all node ids that are descendants of a project node via contain edges (BFS).
/// Includes the project node itself and all nodes contained transitively.
fn collectProjectDescendantNodeIds(
    allocator: std.mem.Allocator,
    store: storage.Store,
    project_node_id: core.NodeId,
    kind_filter: ?core.NodeKind,
    cap: usize,
    truncated_out: ?*bool,
    descent: MembershipDescent,
) !std.ArrayList(core.NodeId) {
    var result = std.ArrayList(core.NodeId).empty;
    errdefer result.deinit(allocator);
    var visited = std.AutoHashMap(u64, void).init(allocator);
    defer visited.deinit();
    var queue = std.ArrayList(core.NodeId).empty;
    defer queue.deinit(allocator);

    try queue.append(allocator, project_node_id);
    try visited.put(project_node_id.toInt(), {});

    // 锚排除:三锚(task/docs/memory_anchor)是**结构基础设施不是内容**——
    // membership 遍历要**穿过**它们(成员经锚可达),但它们自身不进成员集
    // (否则 list-recent/search 面浮出"任务面(task anchor)"这类脚手架)。
    // 成本纪律(Linus A):锚判定挪到**出队时**且零额外读——project 访问时只把直接
    // contain 孩子 id 记进候选集(不读任何节点/属性);出队时 node 已在手,仅当
    // "在候选集 ∧ kind∈{task,concept}(锚仅有的两种 kind)"才读一次 schema_type。
    // 存量拍平店(project 直挂几百孩子)里 observation/document 孩子零属性读;
    // 锚化新店只有 3 个锚各读一次。
    var anchor_candidates = std.AutoHashMap(u64, void).init(allocator);
    defer anchor_candidates.deinit();

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const current = queue.items[head];
        // Add current node to result (unless it's the root project itself and kind filter doesn't match)
        var node = (try store.readNodeById(allocator, current)) orelse continue;
        defer node.deinit(allocator);
        if (node.kind == .project) {
            // 只记 id(锚候选),零读;孩子出队时按需判定。project 先于其孩子出队(FIFO)。
            var pchildren = try collectChildIdsByRel(allocator, store, current, .contain_only);
            defer pchildren.deinit(allocator);
            for (pchildren.items) |cid| try anchor_candidates.put(cid, {});
        }
        const is_anchor = blk: {
            // 排除只属于**内容面**(list-recent/search)。contain_only 是治理面
            // (reparent 环检查):藏锚会让"to 是 from 的锚"绕过环检查 → to→to 自环
            // (Linus 第三轮抓的 A 修法回归)。治理面要看见全部结构,零属性读。
            if (descent == .contain_only) break :blk false;
            if (!anchor_candidates.contains(current.toInt())) break :blk false;
            if (node.kind != .task and node.kind != .concept) break :blk false;
            const st = try store.getNodeStringProperty(allocator, current, "schema_type");
            defer if (st) |sv| allocator.free(sv);
            const sv = st orelse break :blk false;
            break :blk std.mem.eql(u8, sv, "task_anchor") or std.mem.eql(u8, sv, "docs_anchor") or std.mem.eql(u8, sv, "memory_anchor");
        };
        if (current.toInt() != project_node_id.toInt() and !is_anchor) {
            if (kind_filter == null or node.kind == kind_filter.?) {
                if (result.items.len >= cap) {
                    // cap 截断:成员集不全(子树内命中会被误过滤)。显式上报,不静默(Linus)。
                    if (truncated_out) |t| t.* = true;
                    break;
                }
                try result.append(allocator, current);
            }
        }
        // Find contain children(segment-aware:delta 边可见,Linus BLOCKER 修)
        var children = try collectChildIdsByRel(allocator, store, current, descent);
        defer children.deinit(allocator);
        for (children.items) |child_id| {
            if (visited.contains(child_id)) continue;
            try visited.put(child_id, {});
            try queue.append(allocator, core.NodeId.fromInt(child_id));
        }
    }
    return result;
}

/// 项目级 schema(applies_to)—— 从 project 下行 BFS,**遇子 project 边界即停**(子 project
/// 不收集、不递归),收集"最近 project = 该 project"的所有非 project 节点 id。
/// 与 collectProjectDescendantNodeIds 的差别:那个穿过子 project(要全子树);这个在子 project
/// 边界停下 = "严格精确无继承"语义的基石(子 project 里的节点最近 project 是子 project,不含本 project)。
/// 返回的 set 由调用方 deinit。cap 命中置 truncated_out 并停(不静默截断)。
fn collectProjectDirectMemberIds(
    allocator: std.mem.Allocator,
    store: storage.Store,
    project_node_id: core.NodeId,
    cap: usize,
    truncated_out: ?*bool,
) !std.AutoHashMap(u64, void) {
    var result = std.AutoHashMap(u64, void).init(allocator);
    errdefer result.deinit();
    var visited = std.AutoHashMap(u64, void).init(allocator);
    defer visited.deinit();
    var queue = std.ArrayList(core.NodeId).empty;
    defer queue.deinit(allocator);
    try queue.append(allocator, project_node_id);
    try visited.put(project_node_id.toInt(), {});

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const current = queue.items[head];
        var node = (try store.readNodeById(allocator, current)) orelse continue;
        defer node.deinit(allocator);
        const is_root = current.toInt() == project_node_id.toInt();
        // 子 project 边界:不收集、不递归进去(无继承)。
        if (!is_root and node.kind == .project) continue;
        if (!is_root) {
            if (result.count() >= cap) {
                if (truncated_out) |t| t.* = true;
                break;
            }
            try result.put(current.toInt(), {});
        }
        // 只在 root project 或非 project 节点上继续下行(子 project 已在上面 continue 掉)。
        var children = try collectContainChildIds(allocator, store, current);
        defer children.deinit(allocator);
        for (children.items) |child_id| {
            if (visited.contains(child_id)) continue;
            try visited.put(child_id, {});
            try queue.append(allocator, core.NodeId.fromInt(child_id));
        }
    }
    return result;
}

/// 一条 schema-scope 政策:某 schema_type 只在这些 project 下可用 + enforce 档。
const SchemaAdministrationDataPlaneOps = struct {
    pub const CliStoreLockValue = CliStoreLock;
    pub const ContentDigestValue = ContentDigest;
    pub const MigrationEdgeSpoolBuilderValue = MigrationEdgeSpoolBuilder;
    pub const MigrationEdgeStreamValue = MigrationEdgeStream;
    pub const MigrationPropertyBatchValue = MigrationPropertyBatch;
    pub const MigrationPropertyKeysValue = MigrationPropertyKeys;
    pub const MigrationPropertyLookupValue = MigrationPropertyLookup;
    pub const MigrationPropertySpoolValue = MigrationPropertySpool;
    pub const MigrationPropertyStreamValue = MigrationPropertyStream;
    pub const MigrationTargetPropertySpoolBuilderValue = MigrationTargetPropertySpoolBuilder;
    pub const NodeLocalGraphStatsValue = NodeLocalGraphStats;
    pub const QueryOutputWriterValue = QueryOutputWriter;
    pub const StoreManifestSummaryValue = StoreManifestSummary;
    pub const addBuiltinProfilesFromCsvValue = addBuiltinProfilesFromCsv;
    pub const agentValue = agent;
    pub const anyPathExistsValue = anyPathExists;
    pub const appendCatalogProfileLabelValue = appendCatalogProfileLabel;
    pub const appendSchemaDocumentProfilesToCatalogValue = appendSchemaDocumentProfilesToCatalog;
    pub const appendSchemaFileProfilesToCatalogValue = appendSchemaFileProfilesToCatalog;
    pub const builtinValue = builtin;
    pub const canonicalPathsEqualValue = canonicalPathsEqual;
    pub const canonicalProspectivePathValue = canonicalProspectivePath;
    pub const catalogProfilesCsvAllocValue = catalogProfilesCsvAlloc;
    pub const catalog_modValue = catalog_mod;
    pub const collectKnownEdgePropertiesValue = collectKnownEdgeProperties;
    pub const collectKnownNodePropertiesValue = collectKnownNodeProperties;
    pub const collectProjectDirectMemberIdsValue = collectProjectDirectMemberIds;
    pub const contentDigestForBytesValue = contentDigestForBytes;
    pub const copyMetaknowDeferredBasedOnSidecarForMigrationValue = copyMetaknowDeferredBasedOnSidecarForMigration;
    pub const coreValue = core;
    pub const createOwnedDirectoryValue = createOwnedDirectory;
    pub const currentGenerationLookupCandidateLimitValue = currentGenerationLookupCandidateLimit;
    pub const current_schema_versionValue = current_schema_version;
    pub const dagValue = dag;
    pub const ensureDeclaredEdgePropertiesRetainedValue = ensureDeclaredEdgePropertiesRetained;
    pub const ensureDeclaredNodePropertiesRetainedValue = ensureDeclaredNodePropertiesRetained;
    pub const existingTinyKgStorePathValue = existingTinyKgStorePath;
    pub const fileExistsValue = fileExists;
    pub const forEachVisibleEdgeRecordByNodeValue = forEachVisibleEdgeRecordByNode;
    pub const graphValue = graph;
    pub const isDeletedNodeTombstoneValue = isDeletedNodeTombstone;
    pub const loadSchemaRegistryBytesValue = loadSchemaRegistryBytes;
    pub const loadSchemaRegistryFileValue = loadSchemaRegistryFile;
    pub const metaknowDeferredBasedOnPathValue = metaknowDeferredBasedOnPath;
    pub const metaknowDeferredBasedOnPathForDbValue = metaknowDeferredBasedOnPathForDb;
    pub const metaknow_deferred_based_on_header_lenValue = metaknow_deferred_based_on_header_len;
    pub const nodeIsCurrentGenerationValue = nodeIsCurrentGeneration;
    pub const parseSchemaFileBytesValue = parseSchemaFileBytes;
    pub const queryValue = query;
    pub const readSchemaFileBytesAllocValue = readSchemaFileBytesAlloc;
    pub const readStoreManifestSummaryValue = readStoreManifestSummary;
    pub const renamePathValue = renamePath;
    pub const rewriteTransactionMarkerFormatForTestValue = rewriteTransactionMarkerFormatForTest;
    pub const runValue = run;
    pub const schemaValue = schema;
    pub const schemaEdgeEndpointCheckValue = schemaEdgeEndpointCheck;
    pub const schema_argumentsValue = schema_arguments;
    pub const schema_migration_publish_lock_suffixValue = schema_migration_publish_lock_suffix;
    pub const schema_migration_staging_suffixValue = schema_migration_staging_suffix;
    pub const schema_migration_transaction_marker_fileValue = schema_migration_transaction_marker_file;
    pub const schema_migration_transaction_marker_formatValue = schema_migration_transaction_marker_format;
    pub const schema_migration_transaction_marker_legacy_formatValue = schema_migration_transaction_marker_legacy_format;
    pub const schema_reconciliationValue = schema_reconciliation;
    pub const stdValue = std;
    pub const storageValue = storage;
    pub const storeContentIdentityValue = storeContentIdentity;
    pub const syncExportDirectoryTreeValue = syncExportDirectoryTree;
    pub const syncParentDirectoryValue = syncParentDirectory;
    pub const taskValue = task;
    pub const transactionMarkerHasFormatForTestValue = transactionMarkerHasFormatForTest;
    pub const validateSchemaMigratePathRelationshipValue = validateSchemaMigratePathRelationship;
    pub const validateSchemaMigratePathsValue = validateSchemaMigratePaths;
    pub const versionValue = version;
    pub const writeJsonStringValue = writeJsonString;
    pub const writeMetaknowDeferredBasedOnForwardPairsSidecarValue = writeMetaknowDeferredBasedOnForwardPairsSidecar;
    pub const writeNodeKindNameWithSchemaValue = writeNodeKindNameWithSchema;
    pub const writeRecoverableTransactionMarkerValue = writeRecoverableTransactionMarker;
    pub const writeRelKindNameWithSchemaValue = writeRelKindNameWithSchema;
    pub const writeStoreManifestValue = writeStoreManifest;
};

const schema_administration_data_plane = schema_administration_data_plane_mod.SchemaAdministrationDataPlane(SchemaAdministrationDataPlaneOps);
const ParsedSchemaMigrateArgs = schema_administration_data_plane.ParsedSchemaMigrateArgs;
const SchemaMigrationTransactionExpectation = schema_administration_data_plane.SchemaMigrationTransactionExpectation;
const catalogTestSchemaJsonAlloc = schema_administration_data_plane.catalogTestSchemaJsonAlloc;
const enforceSchemaScopeAtWrite = schema_administration_data_plane.enforceSchemaScopeAtWrite;
const nodeDeprecatedBy = schema_administration_data_plane.nodeDeprecatedBy;
const nodeLocalGraphStats = schema_administration_data_plane.nodeLocalGraphStats;
const recoverSchemaMigrationStaging = schema_administration_data_plane.recoverSchemaMigrationStaging;
const renderKindListWithSchema = schema_administration_data_plane.renderKindListWithSchema;
const renderRelListWithSchema = schema_administration_data_plane.renderRelListWithSchema;
const renderSchemaInfo = schema_administration_data_plane.renderSchemaInfo;
const renderSchemaShow = schema_administration_data_plane.renderSchemaShow;
const resolveProjectSpec = schema_administration_data_plane.resolveProjectSpec;
const runSchemaApply = schema_administration_data_plane.runSchemaApply;
const runSchemaMigrate = schema_administration_data_plane.runSchemaMigrate;
const runSchemaReconcile = schema_administration_data_plane.runSchemaReconcile;
const runSchemaValidate = schema_administration_data_plane.runSchemaValidate;
const schemaMigrationTransactionMarkerPath = schema_administration_data_plane.schemaMigrationTransactionMarkerPath;
const schemaScopeAllowedSet = schema_administration_data_plane.schemaScopeAllowedSet;
const writeMarkdownInlineText = schema_administration_data_plane.writeMarkdownInlineText;
const writeSchemaFile = schema_administration_data_plane.writeSchemaFile;
const writeSchemaMigrationTransactionMarker = schema_administration_data_plane.writeSchemaMigrationTransactionMarker;

const QueryContextReadDataPlaneOps = struct {
    pub const CliOutputFormatValue = CliOutputFormat;
    pub const MarkdownImportContextValue = MarkdownImportContext;
    pub const NodeReadRenderOptionsValue = NodeReadRenderOptions;
    pub const ParsedContextArgsValue = ParsedContextArgs;
    pub const ParsedNeighborsArgsValue = ParsedNeighborsArgs;
    pub const ParsedTaskPacketArgsValue = ParsedTaskPacketArgs;
    pub const QueryOutputWriterValue = QueryOutputWriter;
    pub const TextBudgetProfileValue = TextBudgetProfile;
    pub const TextContextSizeValue = TextContextSize;
    pub const agentValue = agent;
    pub const agent_memory_text_postings_scannedValue = agent_memory_text_postings_scanned;
    pub const agent_memory_text_timeout_msValue = agent_memory_text_timeout_ms;
    pub const appendMarkdownProjectionEdgeValue = appendMarkdownProjectionEdge;
    pub const collectContainChildIdsValue = collectContainChildIds;
    pub const collectProjectDescendantNodeIdsValue = collectProjectDescendantNodeIds;
    pub const computeTextContextSizeValue = computeTextContextSize;
    pub const coreValue = core;
    pub const dagValue = dag;
    pub const elapsedNsValue = elapsedNs;
    pub const ensureTaskEvidenceEdgeValue = ensureTaskEvidenceEdge;
    pub const existingTinyKgStorePathValue = existingTinyKgStorePath;
    pub const forEachVisibleEdgeRecordByNodeValue = forEachVisibleEdgeRecordByNode;
    pub const graphValue = graph;
    pub const linkNodeToProjectParentValue = linkNodeToProjectParent;
    pub const lookupMarkdownProjectionEdgeByEndpointsValue = lookupMarkdownProjectionEdgeByEndpoints;
    pub const markdownIncomingHeadingRelValue = markdownIncomingHeadingRel;
    pub const markdownPreviewPrefixLenValue = markdownPreviewPrefixLen;
    pub const markdownProjectionChildrenValue = markdownProjectionChildren;
    pub const markdownProjectionVisibleTextValue = markdownProjectionVisibleText;
    pub const markdownSubtreeSectionStatsValue = markdownSubtreeSectionStats;
    pub const markdownUtf8PrefixEndByCharsValue = markdownUtf8PrefixEndByChars;
    pub const max_cli_text_postings_scannedValue = max_cli_text_postings_scanned;
    pub const max_cli_text_timeout_msValue = max_cli_text_timeout_ms;
    pub const md_rel_h1Value = md_rel_h1;
    pub const monotonicNsValue = monotonicNs;
    pub const nodeDeprecatedByValue = nodeDeprecatedBy;
    pub const nodeHasTaskEventSchemaValue = nodeHasTaskEventSchema;
    pub const nodeKindNameAllocValue = nodeKindNameAlloc;
    pub const nodeKindNameWithSchemaAllocValue = nodeKindNameWithSchemaAlloc;
    pub const nodeLocalGraphStatsValue = nodeLocalGraphStats;
    pub const parseContextArgsValue = parseContextArgs;
    pub const parseDbArgsValue = parseDbArgs;
    pub const parseFreeTextDbArgsValue = parseFreeTextDbArgs;
    pub const parseNeighborsArgsValue = parseNeighborsArgs;
    pub const parseNodeIdArgValue = parseNodeIdArg;
    pub const parseOptionalDbPathValue = parseOptionalDbPath;
    pub const parseQueryArgsValue = parseQueryArgs;
    pub const parseSearchArgsValue = parseSearchArgs;
    pub const parseTaskAncestryArgsValue = parseTaskAncestryArgs;
    pub const parseTaskFrontierArgsValue = parseTaskFrontierArgs;
    pub const parseTaskMetricsArgsValue = parseTaskMetricsArgs;
    pub const parseTaskPacketArgsValue = parseTaskPacketArgs;
    pub const persistentNowNsValue = persistentNowNs;
    pub const persistentTextCatalogWarmValue = persistentTextCatalogWarm;
    pub const qlValue = ql;
    pub const queryValue = query;
    pub const query_indexValue = query_index;
    pub const readVisibleEdgeRecordsByNodeValue = readVisibleEdgeRecordsByNode;
    pub const readVisibleEdgeRecordsByNodeCompleteLimitedValue = readVisibleEdgeRecordsByNodeCompleteLimited;
    pub const readVisibleEdgeRecordsByNodeLimitedValue = readVisibleEdgeRecordsByNodeLimited;
    pub const readVisibleTaskHierarchyEdgeRecordsValue = readVisibleTaskHierarchyEdgeRecords;
    pub const readVisibleTaskPacketChildEdgeRecordsValue = readVisibleTaskPacketChildEdgeRecords;
    pub const relKindNameWithSchemaAllocValue = relKindNameWithSchemaAlloc;
    pub const renderMarkdownDocumentValue = renderMarkdownDocument;
    pub const renderTaskFrontierOutputValue = renderTaskFrontierOutput;
    pub const renderTextContextSizeJsonValue = renderTextContextSizeJson;
    pub const runValue = run;
    pub const schemaValue = schema;
    pub const segment_bundleValue = segment_bundle;
    pub const segment_node_indexValue = segment_node_index;
    pub const stdValue = std;
    pub const storageValue = storage;
    pub const taskValue = task;
    pub const taskHasNonCompletedChildrenValue = taskHasNonCompletedChildren;
    pub const taskPacketRoleIsGoalAnchorValue = taskPacketRoleIsGoalAnchor;
    pub const text_searchValue = text_search;
    pub const u128ToU64Value = u128ToU64;
    pub const versionValue = version;
    pub const writeEscapedTextValue = writeEscapedText;
    pub const writeJsonBoolFieldValue = writeJsonBoolField;
    pub const writeJsonFieldPrefixValue = writeJsonFieldPrefix;
    pub const writeJsonNullableStringFieldValue = writeJsonNullableStringField;
    pub const writeJsonNumberFieldValue = writeJsonNumberField;
    pub const writeJsonObjectEndValue = writeJsonObjectEnd;
    pub const writeJsonObjectStartValue = writeJsonObjectStart;
    pub const writeJsonStringValue = writeJsonString;
    pub const writeJsonStringFieldValue = writeJsonStringField;
    pub const writeNodeKindNameValue = writeNodeKindName;
    pub const writeNodeKindNameWithSchemaValue = writeNodeKindNameWithSchema;
    pub const writeProjectionPersistentValue = writeProjectionPersistent;
    pub const writeRelKindNameValue = writeRelKindName;
    pub const writeRelKindNameWithSchemaValue = writeRelKindNameWithSchema;
    pub const writeTaskPacketEdgeRowsValue = writeTaskPacketEdgeRows;
    pub const writeTaskPacketHierarchyEdgeRowsValue = writeTaskPacketHierarchyEdgeRows;
    pub const writeTaskPacketNodeRowValue = writeTaskPacketNodeRow;
    pub const writeTaskPacketRecentEdgeRowsValue = writeTaskPacketRecentEdgeRows;
    pub const writeTaskPacketRecentHistoryEdgeRowsValue = writeTaskPacketRecentHistoryEdgeRows;
};

const query_context_read_data_plane = query_context_read_data_plane_mod.QueryContextReadDataPlane(QueryContextReadDataPlaneOps);
const MemberFilterDiag = query_context_read_data_plane.MemberFilterDiag;
const buildSearchMemberSet = query_context_read_data_plane.buildSearchMemberSet;
const buildTaskPacketSubgraph = query_context_read_data_plane.buildTaskPacketSubgraph;
const currentGenerationLookupCandidateLimit = query_context_read_data_plane.currentGenerationLookupCandidateLimit;
const edgeRecordIdLessThan = query_context_read_data_plane.edgeRecordIdLessThan;
const list_recent_project_scan_cap = query_context_read_data_plane.list_recent_project_scan_cap;
const nodeIsCurrentGeneration = query_context_read_data_plane.nodeIsCurrentGeneration;
const renderContextPacketJsonOutput = query_context_read_data_plane.renderContextPacketJsonOutput;
const renderContextPlanJsonOutput = query_context_read_data_plane.renderContextPlanJsonOutput;
const renderIncomingOutput = query_context_read_data_plane.renderIncomingOutput;
const renderListRecentOutput = query_context_read_data_plane.renderListRecentOutput;
const renderNeighborsJsonOutputRetained = query_context_read_data_plane.renderNeighborsJsonOutputRetained;
const renderNeighborsOutputMaybeRetained = query_context_read_data_plane.renderNeighborsOutputMaybeRetained;
const renderNodeByIdOutput = query_context_read_data_plane.renderNodeByIdOutput;
const renderNodeLatestOutput = query_context_read_data_plane.renderNodeLatestOutput;
const renderNodeObjectJson = query_context_read_data_plane.renderNodeObjectJson;
const renderNodeVersionsOutput = query_context_read_data_plane.renderNodeVersionsOutput;
const renderPersistentQueryOutputRetained = query_context_read_data_plane.renderPersistentQueryOutputRetained;
const renderSearchJsonOutput = query_context_read_data_plane.renderSearchJsonOutput;
const renderSearchOutput = query_context_read_data_plane.renderSearchOutput;
const renderSegmentBundleQueryOutput = query_context_read_data_plane.renderSegmentBundleQueryOutput;
const renderSubgraphEdgeJson = query_context_read_data_plane.renderSubgraphEdgeJson;
const renderSubgraphOmittedJson = query_context_read_data_plane.renderSubgraphOmittedJson;
const renderTaskPacketOutput = query_context_read_data_plane.renderTaskPacketOutput;
const renderTextContextSizeAggregateJson = query_context_read_data_plane.renderTextContextSizeAggregateJson;
const searchCandidateLimit = query_context_read_data_plane.searchCandidateLimit;
const subgraphUsedEdgeRefs = query_context_read_data_plane.subgraphUsedEdgeRefs;
const taskPacketJsonBudget = query_context_read_data_plane.taskPacketJsonBudget;
const writeSearchContinuation = query_context_read_data_plane.writeSearchContinuation;

const TaskReadMetricsDataPlaneOps = struct {
    pub const ParsedTaskFrontierArgsValue = ParsedTaskFrontierArgs;
    pub const ParsedTaskPacketArgsValue = ParsedTaskPacketArgs;
    pub const QueryOutputWriterValue = QueryOutputWriter;
    pub const TaskHierarchyEdgeCollectionValue = TaskHierarchyEdgeCollection;
    pub const TaskMutationArgumentsValue = TaskMutationArguments;
    pub const agentValue = agent;
    pub const buildTaskPacketSubgraphValue = buildTaskPacketSubgraph;
    pub const collectVisibleTaskHierarchyEdgeRecordsLimitedValue = collectVisibleTaskHierarchyEdgeRecordsLimited;
    pub const coreValue = core;
    pub const edgeRecordIdLessThanValue = edgeRecordIdLessThan;
    pub const exerciseTaskEventMetadataAllocationFailureValue = exerciseTaskEventMetadataAllocationFailure;
    pub const graphValue = graph;
    pub const queryValue = query;
    pub const readVisibleEdgeRecordsByNodeValue = readVisibleEdgeRecordsByNode;
    pub const readVisibleEdgeRecordsByNodeLimitedValue = readVisibleEdgeRecordsByNodeLimited;
    pub const readVisibleTaskHierarchyEdgeRecordsValue = readVisibleTaskHierarchyEdgeRecords;
    pub const readVisibleTaskPacketChildEdgeRecordsValue = readVisibleTaskPacketChildEdgeRecords;
    pub const renderNodeObjectJsonValue = renderNodeObjectJson;
    pub const renderSubgraphEdgeJsonValue = renderSubgraphEdgeJson;
    pub const renderSubgraphOmittedJsonValue = renderSubgraphOmittedJson;
    pub const renderTextContextSizeAggregateJsonValue = renderTextContextSizeAggregateJson;
    pub const runValue = run;
    pub const schemaValue = schema;
    pub const stdValue = std;
    pub const storageValue = storage;
    pub const subgraphUsedEdgeRefsValue = subgraphUsedEdgeRefs;
    pub const taskValue = task;
    pub const taskEdgeLookaheadLimitValue = taskEdgeLookaheadLimit;
    pub const taskPacketJsonBudgetValue = taskPacketJsonBudget;
    pub const task_hierarchyValue = task_hierarchy;
    pub const u128ToU64Value = u128ToU64;
    pub const versionValue = version;
    pub const writeEscapedTextValue = writeEscapedText;
    pub const writeJsonBoolFieldValue = writeJsonBoolField;
    pub const writeJsonFieldPrefixValue = writeJsonFieldPrefix;
    pub const writeJsonNullableStringFieldValue = writeJsonNullableStringField;
    pub const writeJsonNumberFieldValue = writeJsonNumberField;
    pub const writeJsonObjectEndValue = writeJsonObjectEnd;
    pub const writeJsonObjectStartValue = writeJsonObjectStart;
    pub const writeJsonStringFieldValue = writeJsonStringField;
    pub const writeNodeKindNameValue = writeNodeKindName;
    pub const writeRelKindNameValue = writeRelKindName;
    pub const writeSearchContinuationValue = writeSearchContinuation;
};

const task_read_metrics_data_plane = task_read_metrics_data_plane_mod.TaskReadMetricsDataPlane(TaskReadMetricsDataPlaneOps);
const elapsedNs = task_read_metrics_data_plane.elapsedNs;
const monotonicNs = task_read_metrics_data_plane.monotonicNs;
const nodeHasTaskEventSchema = task_read_metrics_data_plane.nodeHasTaskEventSchema;
const optionalU64ToU128 = task_read_metrics_data_plane.optionalU64ToU128;
const persistentNowNs = task_read_metrics_data_plane.persistentNowNs;
const renderTaskAncestryOutput = task_read_metrics_data_plane.renderTaskAncestryOutput;
const renderTaskFrontierOutput = task_read_metrics_data_plane.renderTaskFrontierOutput;
const renderTaskMetricsOutput = task_read_metrics_data_plane.renderTaskMetricsOutput;
const renderTaskPacketJsonOutput = task_read_metrics_data_plane.renderTaskPacketJsonOutput;
const taskMetricEpochNs = task_read_metrics_data_plane.taskMetricEpochNs;
const taskPacketRoleIsGoalAnchor = task_read_metrics_data_plane.taskPacketRoleIsGoalAnchor;
const task_claim_default_ttl_s = task_read_metrics_data_plane.task_claim_default_ttl_s;
const writeTaskPacketEdgeRows = task_read_metrics_data_plane.writeTaskPacketEdgeRows;
const writeTaskPacketHierarchyEdgeRows = task_read_metrics_data_plane.writeTaskPacketHierarchyEdgeRows;
const writeTaskPacketNodeRow = task_read_metrics_data_plane.writeTaskPacketNodeRow;
const writeTaskPacketRecentEdgeRows = task_read_metrics_data_plane.writeTaskPacketRecentEdgeRows;
const writeTaskPacketRecentHistoryEdgeRows = task_read_metrics_data_plane.writeTaskPacketRecentHistoryEdgeRows;

const governance_sample_limit: usize = 8;
const governance_high_fanout_threshold: u64 = 128;
const governance_navigation_fanout_target_min: u64 = 5;
const governance_navigation_fanout_target_max: u64 = 32;
const governance_navigation_fanout_warn_threshold: u64 = 64;
const governance_high_fanout_name_sample_bytes: usize = 256;
const deleted_node_tombstone_prefix = "__tinykg_deleted_node__ ";

fn isDeletedNodeTombstone(node: storage.StoredNode) bool {
    return node.kind == .edit and std.mem.startsWith(u8, node.text, deleted_node_tombstone_prefix);
}

const StoreCopySnapshotDataPlaneOps = struct {
    pub const CliStoreLockValue = CliStoreLock;
    pub const ContentDigestValue = ContentDigest;
    pub const QueryOutputWriterValue = QueryOutputWriter;
    pub const anyPathExistsValue = anyPathExists;
    pub const backup_manifest_fileValue = backup_manifest_file;
    pub const backup_publish_lock_suffixValue = backup_publish_lock_suffix;
    pub const backup_staging_suffixValue = backup_staging_suffix;
    pub const backup_transaction_marker_fileValue = backup_transaction_marker_file;
    pub const backup_transaction_marker_formatValue = backup_transaction_marker_format;
    pub const backup_transaction_marker_legacy_formatValue = backup_transaction_marker_legacy_format;
    pub const builtinValue = builtin;
    pub const cli_store_lock_suffixValue = cli_store_lock_suffix;
    pub const coreValue = core;
    pub const existingTinyKgStorePathValue = existingTinyKgStorePath;
    pub const fileExistsValue = fileExists;
    pub const finalizeContentDigestValue = finalizeContentDigest;
    pub const import_transaction_marker_fileValue = import_transaction_marker_file;
    pub const markdownFileNameLessThanValue = markdownFileNameLessThan;
    pub const renamePathValue = renamePath;
    pub const restore_publish_lock_suffixValue = restore_publish_lock_suffix;
    pub const restore_staging_suffixValue = restore_staging_suffix;
    pub const restore_transaction_marker_fileValue = restore_transaction_marker_file;
    pub const restore_transaction_marker_formatValue = restore_transaction_marker_format;
    pub const restore_transaction_marker_legacy_formatValue = restore_transaction_marker_legacy_format;
    pub const schemaValue = schema;
    pub const schema_migration_transaction_marker_fileValue = schema_migration_transaction_marker_file;
    pub const stdValue = std;
    pub const storageValue = storage;
    pub const store_migration_transaction_marker_fileValue = store_migration_transaction_marker_file;
    pub const syncExportDirectoryTreeValue = syncExportDirectoryTree;
    pub const syncParentDirectoryValue = syncParentDirectory;
    pub const writeJsonStringValue = writeJsonString;
    pub const writeRecoverableTransactionMarkerValue = writeRecoverableTransactionMarker;
};

const store_copy_snapshot_data_plane = store_copy_snapshot_data_plane_mod.StoreCopySnapshotDataPlane(StoreCopySnapshotDataPlaneOps);
const BackupStoreResult = store_copy_snapshot_data_plane.BackupStoreResult;
const BackupTransactionExpectation = store_copy_snapshot_data_plane.BackupTransactionExpectation;
const RestoreTransactionExpectation = store_copy_snapshot_data_plane.RestoreTransactionExpectation;
const SchemaEdgeEndpointCheck = store_copy_snapshot_data_plane.SchemaEdgeEndpointCheck;
const StoreContentIdentity = store_copy_snapshot_data_plane.StoreContentIdentity;
const backupExpectationForSource = store_copy_snapshot_data_plane.backupExpectationForSource;
const backupStagingPath = store_copy_snapshot_data_plane.backupStagingPath;
const backupStore = store_copy_snapshot_data_plane.backupStore;
const backupTransactionMarkerPath = store_copy_snapshot_data_plane.backupTransactionMarkerPath;
const canonicalPathContains = store_copy_snapshot_data_plane.canonicalPathContains;
const canonicalPathsEqual = store_copy_snapshot_data_plane.canonicalPathsEqual;
const canonicalProspectivePath = store_copy_snapshot_data_plane.canonicalProspectivePath;
const copyDirectoryTree = store_copy_snapshot_data_plane.copyDirectoryTree;
const copyDirectoryTreeContents = store_copy_snapshot_data_plane.copyDirectoryTreeContents;
const createOwnedDirectory = store_copy_snapshot_data_plane.createOwnedDirectory;
const deleteBackupTransactionMarker = store_copy_snapshot_data_plane.deleteBackupTransactionMarker;
const hashLengthPrefixed = store_copy_snapshot_data_plane.hashLengthPrefixed;
const hashStoreFile = store_copy_snapshot_data_plane.hashStoreFile;
const pathsOverlap = store_copy_snapshot_data_plane.pathsOverlap;
const pathsOverlapForCopyTarget = store_copy_snapshot_data_plane.pathsOverlapForCopyTarget;
const recoverBackupStaging = store_copy_snapshot_data_plane.recoverBackupStaging;
const recoverRestoreStaging = store_copy_snapshot_data_plane.recoverRestoreStaging;
const restoreBackup = store_copy_snapshot_data_plane.restoreBackup;
const restoreExpectationForSource = store_copy_snapshot_data_plane.restoreExpectationForSource;
const restoreStagingPath = store_copy_snapshot_data_plane.restoreStagingPath;
const restoreTransactionMarkerPath = store_copy_snapshot_data_plane.restoreTransactionMarkerPath;
const schemaEdgeEndpointCheck = store_copy_snapshot_data_plane.schemaEdgeEndpointCheck;
const storeContentIdentity = store_copy_snapshot_data_plane.storeContentIdentity;
const storeDirBytes = store_copy_snapshot_data_plane.storeDirBytes;
const validateExistingBackupForSource = store_copy_snapshot_data_plane.validateExistingBackupForSource;
const validateSchemaEdgeEndpoints = store_copy_snapshot_data_plane.validateSchemaEdgeEndpoints;
const writeBackupTransactionMarker = store_copy_snapshot_data_plane.writeBackupTransactionMarker;
const writeRestoreTransactionMarker = store_copy_snapshot_data_plane.writeRestoreTransactionMarker;

fn writeProjectionPersistent(
    writer: anytype,
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    node_view: ?*storage.Store.NodeRecordView,
    status_snapshot: ?*const task.StatusSnapshot,
    read_timestamp_ns: u64,
    row: ql.executor.Row,
    projection: ql.ast.Projection,
    budget: core.QueryBudget,
    projection_stats: ?*query_index.QueryStats,
) !void {
    switch (projection) {
        .variable => |var_name| {
            const id = row.get(var_name) orelse {
                try writer.writeAll("null");
                return;
            };
            var node = (try readRenderNodeById(allocator, store, node_view, id)) orelse return error.InvalidRecord;
            defer node.deinit(allocator);
            try writer.print("{}:", .{node.id.toInt()});
            try writeNodeKindName(writer, node.kind);
            try writer.writeAll(":");
            try writeEscapedText(writer, markdownProjectionVisibleText(node.text));
        },
        .property => |property| {
            const id = row.get(property.var_name) orelse {
                try writer.writeAll("null");
                return;
            };
            var node = (try readRenderNodeById(allocator, store, node_view, id)) orelse return error.InvalidRecord;
            defer node.deinit(allocator);
            if (std.mem.eql(u8, property.property, "text")) {
                try writeEscapedText(writer, node.text);
            } else if (std.mem.eql(u8, property.property, task.status_property)) {
                if (node.kind == .task) {
                    const lifecycle = if (status_snapshot) |snapshot| lifecycle: {
                        if (!snapshot.covers(id)) return error.InvalidRecord;
                        break :lifecycle try snapshot.statusForStoredNode(node, read_timestamp_ns);
                    } else try task.statusForStoredNode(allocator, store, node, read_timestamp_ns);
                    try writer.writeAll(@tagName(lifecycle));
                } else {
                    const string_value = try store.getNodeStringProperty(allocator, id, property.property);
                    defer if (string_value) |owned| allocator.free(owned);
                    if (string_value) |owned| {
                        try writeEscapedText(writer, owned);
                    } else if (try store.getUintProperty(allocator, .{ .node = id }, property.property)) |uint_value| {
                        try writer.print("{}", .{uint_value});
                    } else {
                        try writer.writeAll("null");
                    }
                }
            } else if (std.mem.eql(u8, property.property, "name") or
                std.mem.eql(u8, property.property, "summary") or
                std.mem.eql(u8, property.property, "retrieval_hints") or
                std.mem.eql(u8, property.property, "schema_type") or
                std.mem.eql(u8, property.property, "claimed_by") or
                std.mem.eql(u8, property.property, "external_key") or
                std.mem.eql(u8, property.property, "content_hash") or
                std.mem.eql(u8, property.property, "task_event_type") or
                std.mem.eql(u8, property.property, "dependency_relation"))
            {
                const value = try store.getNodeStringProperty(allocator, id, property.property);
                defer if (value) |owned| allocator.free(owned);
                if (value) |owned| {
                    try writeEscapedText(writer, owned);
                } else if (std.mem.eql(u8, property.property, "name") or std.mem.eql(u8, property.property, "summary")) {
                    try writer.writeAll("");
                } else {
                    try writer.writeAll("null");
                }
            } else if (std.mem.eql(u8, property.property, "task_recorded_ns") or
                std.mem.eql(u8, property.property, "task_created_ns") or
                std.mem.eql(u8, property.property, "task_completed_ns") or
                std.mem.eql(u8, property.property, "claim_expires_ns") or
                std.mem.eql(u8, property.property, "task_event_ns") or
                std.mem.eql(u8, property.property, "task_root_id") or
                std.mem.eql(u8, property.property, "task_id"))
            {
                if (try store.getUintProperty(allocator, .{ .node = id }, property.property)) |value| {
                    try writer.print("{}", .{value});
                } else {
                    try writer.writeAll("null");
                }
            } else {
                const string_value = try store.getNodeStringProperty(allocator, id, property.property);
                defer if (string_value) |owned| allocator.free(owned);
                if (string_value) |owned| {
                    try writeEscapedText(writer, owned);
                } else if (try store.getUintProperty(allocator, .{ .node = id }, property.property)) |uint_value| {
                    try writer.print("{}", .{uint_value});
                } else {
                    try writer.writeAll("null");
                }
            }
        },
        .path => |path| {
            const nodes = row.getPath(path.from_var, path.to_var) orelse {
                try writer.writeAll("null");
                return;
            };
            for (nodes, 0..) |node_id, i| {
                var node = (try readRenderNodeById(allocator, store, node_view, node_id)) orelse return error.InvalidRecord;
                node.deinit(allocator);
                if (i > 0) try writer.writeAll(" -> ");
                try writer.print("{}", .{node_id.toInt()});
            }
        },
        .reachable => |reachable| {
            const from = row.get(reachable.from_var) orelse {
                try writer.writeAll("null");
                return;
            };
            const to = row.get(reachable.to_var) orelse {
                try writer.writeAll("null");
                return;
            };
            const value = if (projection_stats) |stats| blk: {
                if (edge_retention_registry) |registry| {
                    break :blk try dag.reachableWithPersistentStoreMeasuredRetained(allocator, store, registry, from, to, reachable.rel, budget, stats);
                }
                break :blk try dag.reachableWithPersistentStoreMeasured(allocator, store, from, to, reachable.rel, budget, stats);
            } else blk: {
                if (edge_retention_registry) |registry| {
                    break :blk try dag.reachableWithPersistentStoreRetained(allocator, store, registry, from, to, reachable.rel, budget);
                }
                break :blk try dag.reachableWithPersistentStore(allocator, store, from, to, reachable.rel, budget);
            };
            try writer.writeAll(if (value) "true" else "false");
        },
        .context => |context| {
            const focus = row.get(context.var_name) orelse {
                try writer.writeAll("null");
                return;
            };
            var packet = if (projection_stats) |stats| blk: {
                if (edge_retention_registry) |registry| {
                    break :blk try agent.contextPacketWithPersistentStoreMeasuredRetained(allocator, store, registry, focus, 8, budget, stats);
                }
                break :blk try agent.contextPacketWithPersistentStoreMeasured(allocator, store, focus, 8, budget, stats);
            } else blk: {
                if (edge_retention_registry) |registry| {
                    break :blk try agent.contextPacketWithPersistentStoreBudgetRetained(allocator, store, registry, focus, 8, budget);
                }
                break :blk try agent.contextPacketWithPersistentStoreBudget(allocator, store, focus, 8, budget);
            };
            defer packet.deinit(allocator);
            var emitted: usize = 0;
            for (packet.facts.items) |fact| {
                {
                    var node = (try readRenderNodeById(allocator, store, node_view, fact.node_id)) orelse return error.InvalidRecord;
                    defer node.deinit(allocator);
                    if (emitted > 0) try writer.writeAll(",");
                    try writeRelKindName(writer, fact.rel);
                    try writer.print(":{s}:{}:", .{ @tagName(fact.direction), fact.node_id.toInt() });
                    try writeEscapedText(writer, node.text);
                    try writer.print(":{}", .{
                        fact.score,
                    });
                    emitted += 1;
                }
            }
        },
        .score => |score| {
            if (row.getScore(score.var_name)) |value| {
                try writer.print("{d:.6}", .{value});
            } else {
                try writer.writeAll("null");
            }
        },
    }
}

fn readRenderNodeById(
    allocator: std.mem.Allocator,
    store: storage.Store,
    node_view: ?*storage.Store.NodeRecordView,
    id: core.NodeId,
) !?storage.StoredNode {
    if (node_view) |view| return try view.readNodeById(allocator, id);
    return try store.readNodeById(allocator, id);
}

fn parseNodeIdArg(value: []const u8) !core.NodeId {
    return core.NodeId.fromInt(std.fmt.parseInt(u64, value, 10) catch return error.InvalidNodeId);
}

fn joinArgs(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (parts) |part| {
        const with_separator = std.math.add(usize, part.len, 1) catch return error.RecordTooLarge;
        total = std.math.add(usize, total, with_separator) catch return error.RecordTooLarge;
    }
    if (total == 0) return allocator.dupe(u8, "");
    var out = try allocator.alloc(u8, total - 1);
    var pos: usize = 0;
    for (parts, 0..) |part, i| {
        if (i > 0) {
            out[pos] = ' ';
            pos += 1;
        }
        @memcpy(out[pos .. pos + part.len], part);
        pos += part.len;
    }
    return out;
}

test "CLI default dispatch delegates to help renderer" {
    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);

    try run(&.{"tinykg"}, &out, std.testing.allocator, std.testing.io);

    try std.testing.expect(std.mem.startsWith(u8, out.buffer.items, "tinykg commands:\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "  task-close [db]") != null);
    try std.testing.expect(std.mem.endsWith(u8, out.buffer.items, "inspect=get, health=governance\n"));
}

test "parse command defaults to help" {
    try std.testing.expectEqual(Command.help, try parseCommand(null));
    try std.testing.expectEqual(Command.version, try parseCommand("version"));
    try std.testing.expectEqual(Command.import_metaknow_replay, try parseCommand("import-metaknow-replay"));
    try std.testing.expectEqual(Command.store_info, try parseCommand("store-info"));
    try std.testing.expectEqual(Command.rebuild_text, try parseCommand("rebuild-text"));
    try std.testing.expectEqual(Command.backup, try parseCommand("backup"));
    try std.testing.expectEqual(Command.restore, try parseCommand("restore"));
    try std.testing.expectEqual(Command.schema_info, try parseCommand("schema-info"));
    try std.testing.expectEqual(Command.get, try parseCommand("get"));
    try std.testing.expectEqual(Command.get, try parseCommand("inspect"));
    try std.testing.expectEqual(Command.get_node, try parseCommand("node"));
    try std.testing.expectEqual(Command.add_node, try parseCommand("add-node"));
    try std.testing.expectEqual(Command.add_node, try parseCommand("remember"));
    try std.testing.expectEqual(Command.update_node, try parseCommand("update-node"));
    try std.testing.expectEqual(Command.update_node, try parseCommand("revise"));
    try std.testing.expectEqual(Command.append_node_version, try parseCommand("append-node-version"));
    try std.testing.expectEqual(Command.set_property, try parseCommand("set-property"));
    try std.testing.expectEqual(Command.set_uint_property, try parseCommand("set-uint-property"));
    try std.testing.expectEqual(Command.set_edge_property, try parseCommand("set-edge-property"));
    try std.testing.expectEqual(Command.node_versions, try parseCommand("node-versions"));
    try std.testing.expectEqual(Command.node_latest, try parseCommand("node-latest"));
    try std.testing.expectEqual(Command.govern_node, try parseCommand("govern-node"));
    try std.testing.expectEqual(Command.govern_node, try parseCommand("tag-node"));
    try std.testing.expectEqual(Command.delete_node, try parseCommand("delete-node"));
    try std.testing.expectEqual(Command.delete_node, try parseCommand("forget"));
    try std.testing.expectEqual(Command.list_kinds, try parseCommand("list-kinds"));
    try std.testing.expectEqual(Command.list_recent, try parseCommand("list-recent"));
    try std.testing.expectEqual(Command.agent_write, try parseCommand("agent-write"));
    try std.testing.expectEqual(Command.add_edge, try parseCommand("relate"));
    try std.testing.expectEqual(Command.delete_edge, try parseCommand("delete-edge"));
    try std.testing.expectEqual(Command.delete_edges, try parseCommand("delete-edges"));
    try std.testing.expectEqual(Command.list_rels, try parseCommand("list-rels"));
    try std.testing.expectEqual(Command.search, try parseCommand("search"));
    try std.testing.expectEqual(Command.search, try parseCommand("recall"));
    try std.testing.expectEqual(Command.context_plan, try parseCommand("context-plan"));
    try std.testing.expectEqual(Command.context_packet, try parseCommand("context-packet"));
    try std.testing.expectEqual(Command.query, try parseCommand("query"));
    try std.testing.expectEqual(Command.query_explain, try parseCommand("query-explain"));
    try std.testing.expectEqual(Command.task_event, try parseCommand("task-event"));
    try std.testing.expectEqual(Command.task_close, try parseCommand("task-close"));
    try std.testing.expectEqual(Command.governance, try parseCommand("governance"));
    try std.testing.expectEqual(Command.governance, try parseCommand("health"));
    try std.testing.expectEqual(Command.import_jsonl, try parseCommand("import-jsonl"));
    try std.testing.expectEqual(Command.export_jsonl, try parseCommand("export-jsonl"));
    try std.testing.expectEqual(Command.import_markdown, try parseCommand("import-markdown"));
    try std.testing.expectEqual(Command.export_markdown, try parseCommand("export-markdown"));
    try std.testing.expectEqual(Command.import_md_doc, try parseCommand("import-md-doc"));
    try std.testing.expectEqual(Command.render_md_doc, try parseCommand("render-md-doc"));
    try std.testing.expectEqual(Command.gc_md_orphans, try parseCommand("gc-md-orphans"));
    try std.testing.expectEqual(Command.segment_query, try parseCommand("segment-query"));
    try std.testing.expectEqual(Command.segment_query_explain, try parseCommand("segment-query-explain"));
    try std.testing.expectEqual(Command.export_segment_bundle, try parseCommand("export-segment-bundle"));
    try std.testing.expectEqual(Command.gc_segment_bundle, try parseCommand("gc-segment-bundle"));
    try std.testing.expectEqual(Command.bench, try parseCommand("bench"));
    try std.testing.expectEqual(Command.bench_md_doc_edit, try parseCommand("bench-md-doc-edit"));
    try std.testing.expectEqual(Command.maintain, try parseCommand("maintain"));
    try std.testing.expectEqual(Command.compact_edges, try parseCommand("compact-edges"));
    try std.testing.expectEqual(Command.compact_edge_segments, try parseCommand("compact-edge-segments"));
    try std.testing.expectEqual(Command.maintain_edge_segments, try parseCommand("maintain-edge-segments"));
    try std.testing.expectEqual(Command.gc_edge_segments, try parseCommand("gc-edge-segments"));
    try std.testing.expectEqual(Command.gc_node_text_runs, try parseCommand("gc-node-text-runs"));
    try std.testing.expectError(error.UnknownCommand, parseCommand("lookup-external-id"));
    try std.testing.expectError(error.UnknownCommand, parseCommand("statsu"));
}

test "native JSONL import validates before creating target store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const corpus_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "native-jsonl" });
    defer std.testing.allocator.free(corpus_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, corpus_path);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "native-jsonl/nodes.jsonl",
        .data =
        \\{"id":1,"kind":"concept","text":"valid node one"}
        \\{"id":2,"kind":"concept","text":"valid node two"}
        \\
        ,
        .flags = .{ .truncate = true },
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "native-jsonl/edges.jsonl",
        .data =
        \\{"id":1,"src":1,"rel":"not_a_relation","dst":2}
        \\
        ,
        .flags = .{ .truncate = true },
    });

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "invalid-import.kg" });
    defer std.testing.allocator.free(db_path);
    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidRelKind, run(&.{ "tinykg", "import-jsonl", db_path, corpus_path }, &out, std.testing.allocator, std.testing.io));
    try std.testing.expect(!try anyPathExists(std.testing.io, db_path));

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "native-jsonl/edges.jsonl",
        .data =
        \\{"id":1,"src":1,"rel":"related_to","dst":42}
        \\
        ,
        .flags = .{ .truncate = true },
    });
    const missing_endpoint_db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "missing-endpoint-import.kg" });
    defer std.testing.allocator.free(missing_endpoint_db_path);
    var missing_endpoint_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer missing_endpoint_out.buffer.deinit(std.testing.allocator);
    try std.testing.expectError(core.Error.NotFound, run(&.{ "tinykg", "import-jsonl", missing_endpoint_db_path, corpus_path }, &missing_endpoint_out, std.testing.allocator, std.testing.io));
    try std.testing.expect(!try anyPathExists(std.testing.io, missing_endpoint_db_path));

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "native-jsonl/edges.jsonl",
        .data =
        \\{"id":1,"src":1,"rel":"related_to","dst":2}
        \\{"id":1,"src":2,"rel":"related_to","dst":1}
        \\
        ,
        .flags = .{ .truncate = true },
    });
    const duplicate_edge_db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "duplicate-edge-import.kg" });
    defer std.testing.allocator.free(duplicate_edge_db_path);
    var duplicate_edge_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer duplicate_edge_out.buffer.deinit(std.testing.allocator);
    try std.testing.expectError(core.Error.InvalidId, run(&.{ "tinykg", "import-jsonl", duplicate_edge_db_path, corpus_path }, &duplicate_edge_out, std.testing.allocator, std.testing.io));
    try std.testing.expect(!try anyPathExists(std.testing.io, duplicate_edge_db_path));

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "native-jsonl/edges.jsonl",
        .data =
        \\{"id":0,"src":1,"rel":"related_to","dst":2}
        \\
        ,
        .flags = .{ .truncate = true },
    });
    const reserved_edge_db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "reserved-edge-import.kg" });
    defer std.testing.allocator.free(reserved_edge_db_path);
    var reserved_edge_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer reserved_edge_out.buffer.deinit(std.testing.allocator);
    try std.testing.expectError(core.Error.InvalidId, run(&.{ "tinykg", "import-jsonl", reserved_edge_db_path, corpus_path }, &reserved_edge_out, std.testing.allocator, std.testing.io));
    try std.testing.expect(!try anyPathExists(std.testing.io, reserved_edge_db_path));

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "native-jsonl/edges.jsonl",
        .data =
        \\{"id":1,"src":0,"rel":"related_to","dst":2}
        \\
        ,
        .flags = .{ .truncate = true },
    });
    const reserved_endpoint_db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "reserved-endpoint-import.kg" });
    defer std.testing.allocator.free(reserved_endpoint_db_path);
    var reserved_endpoint_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer reserved_endpoint_out.buffer.deinit(std.testing.allocator);
    try std.testing.expectError(core.Error.InvalidId, run(&.{ "tinykg", "import-jsonl", reserved_endpoint_db_path, corpus_path }, &reserved_endpoint_out, std.testing.allocator, std.testing.io));
    try std.testing.expect(!try anyPathExists(std.testing.io, reserved_endpoint_db_path));
}

test "imported task lifecycle validates terminal and lease invariants" {
    try std.testing.expectError(error.InvalidRecord, parseImportedTaskLifecycle(std.testing.allocator, .fromInt(1), .verification, .{ .status = "completed", .task_completed_ns = 10 }, 5));
    try std.testing.expectError(error.InvalidRecord, parseImportedTaskLifecycle(std.testing.allocator, .fromInt(1), .task, .{ .status = "completed" }, 5));
    try std.testing.expectError(error.InvalidRecord, parseImportedTaskLifecycle(std.testing.allocator, .fromInt(1), .task, .{ .status = "claimed", .claim_expires_ns = 10 }, 5));
    try std.testing.expectError(error.InvalidRecord, parseImportedTaskLifecycle(std.testing.allocator, .fromInt(1), .task, .{ .status = "open", .claimed_by = "agent", .claim_expires_ns = 10 }, 5));
    try std.testing.expectError(error.InvalidRecord, parseImportedTaskLifecycle(std.testing.allocator, .fromInt(1), .task, .{ .status = "open", .claim_expires_ns = 10 }, 5));
    try std.testing.expectError(error.InvalidRecord, parseImportedTaskLifecycle(std.testing.allocator, .fromInt(1), .task, .{ .status = "completed", .task_completed_ns = 0 }, 5));
    try std.testing.expectError(error.InvalidRecord, parseImportedTaskLifecycle(std.testing.allocator, .fromInt(1), .task, .{ .status = "open", .task_completed_ns = 6 }, 5));
    try std.testing.expectError(error.InvalidRecord, parseImportedTaskLifecycle(std.testing.allocator, .fromInt(1), .task, .{ .status = "claimed", .claimed_by = "agent", .claim_expires_ns = 10, .task_completed_ns = 6 }, 5));
    try std.testing.expectError(error.InvalidRecord, parseImportedTaskLifecycle(std.testing.allocator, .fromInt(1), .task, .{ .status = "open", .task_created_ns = 0 }, 5));
    try std.testing.expectError(error.InvalidRecord, parseImportedTaskLifecycle(std.testing.allocator, .fromInt(1), .task, .{ .status = "open", .task_recorded_ns = 0 }, 5));
    try std.testing.expectError(error.InvalidRecord, parseImportedTaskLifecycle(std.testing.allocator, .fromInt(1), .task, .{ .status = "completed", .task_created_ns = 9, .task_completed_ns = 8 }, 5));
    const oversized_holder = [_]u8{'x'} ** (task.max_claim_holder_len + 1);
    try std.testing.expectError(error.InvalidRecord, parseImportedTaskLifecycle(std.testing.allocator, .fromInt(1), .task, .{ .claimed_by = &oversized_holder, .claim_expires_ns = 10 }, 5));

    var legacy_live = (try parseImportedTaskLifecycle(std.testing.allocator, .fromInt(1), .task, .{ .claimed_by = "legacy-agent", .claim_expires_ns = 10 }, 5)).?;
    defer legacy_live.deinit(std.testing.allocator);
    try std.testing.expectEqual(task.Status.claimed, legacy_live.status);
    try std.testing.expectEqual(@as(?u64, 10), legacy_live.claim_expires_ns);

    var expired = (try parseImportedTaskLifecycle(std.testing.allocator, .fromInt(1), .task, .{ .status = "claimed", .claimed_by = "agent", .claim_expires_ns = 5 }, 5)).?;
    defer expired.deinit(std.testing.allocator);
    try std.testing.expectEqual(task.Status.open, expired.status);
    try std.testing.expectEqual(@as(?u64, 0), expired.claim_expires_ns);

    var terminal_crash_window = (try parseImportedTaskLifecycle(std.testing.allocator, .fromInt(2), .task, .{
        .status = "completed",
        .claimed_by = "agent",
        .claim_expires_ns = 100,
        .task_completed_ns = 4,
    }, 5)).?;
    defer terminal_crash_window.deinit(std.testing.allocator);
    try std.testing.expectEqual(task.Status.completed, terminal_crash_window.status);
    try std.testing.expectEqualStrings("agent", terminal_crash_window.claimed_by.?);
    try std.testing.expectEqual(@as(?u64, 0), terminal_crash_window.claim_expires_ns);
}

test "audit exports zero expired task leases for clock independent import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const jsonl_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "jsonl" });
    defer std.testing.allocator.free(jsonl_path);
    const markdown_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "markdown" });
    defer std.testing.allocator.free(markdown_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "expired claim" });
    _ = try store.upsertPropertiesBatch(std.testing.allocator, &.{
        .{ .owner = .{ .node = .fromInt(1) }, .key = task.status_property, .value = .{ .string = "claimed" } },
        .{ .owner = .{ .node = .fromInt(1) }, .key = task.claimed_by_property, .value = .{ .string = "agent-a" } },
        .{ .owner = .{ .node = .fromInt(1) }, .key = task.claim_expires_ns_property, .value = .{ .uint = 1 } },
    });

    _ = try exportNativeJsonlStore(std.testing.allocator, std.testing.io, store, jsonl_path);
    const nodes_path = try std.fs.path.join(std.testing.allocator, &.{ jsonl_path, "nodes.jsonl" });
    defer std.testing.allocator.free(nodes_path);
    const jsonl = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, nodes_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(jsonl);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"status\":\"open\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"claim_expires_ns\":0") != null);

    _ = try exportMarkdownStore(std.testing.allocator, std.testing.io, store, markdown_path);
    const markdown_nodes_path = try std.fs.path.join(std.testing.allocator, &.{ markdown_path, markdown_nodes_dir });
    defer std.testing.allocator.free(markdown_nodes_path);
    var node_files = try listMarkdownFilesRecursiveSorted(std.testing.allocator, std.testing.io, markdown_nodes_path);
    defer {
        for (node_files.items) |path| std.testing.allocator.free(path);
        node_files.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), node_files.items.len);
    const markdown_node_path = try std.fs.path.join(std.testing.allocator, &.{ markdown_nodes_path, node_files.items[0] });
    defer std.testing.allocator.free(markdown_node_path);
    const markdown = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, markdown_node_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(markdown);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "status: open\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "claim_expires_ns: 0\n") != null);
}

test "audit schema and governance scans include published edge overlays" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "base-segment" });
    defer std.testing.allocator.free(segment_path);
    const jsonl_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "jsonl" });
    defer std.testing.allocator.free(jsonl_path);
    const markdown_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "markdown" });
    defer std.testing.allocator.free(markdown_path);
    const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
    defer std.testing.allocator.free(schema_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .concept, .text = "root" },
        .{ .id = .fromInt(2), .kind = .concept, .text = "base child" },
        .{ .id = .fromInt(3), .kind = .concept, .text = "overlay child" },
    });
    try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .rel = .related_to, .dst = .fromInt(2) });
    try std.testing.expectEqual(@as(u64, 1), try store.publishEdgeAdjacencySegment(segment_path));
    try store.appendEdge(.{ .id = .fromInt(2), .src = .fromInt(1), .rel = @enumFromInt(100), .dst = .fromInt(3) });

    var consolidated_only = try store.visibleEdgeIndexRecordsIterator(.id);
    defer consolidated_only.deinit();
    try std.testing.expect((try consolidated_only.next()) != null);
    try std.testing.expect((try consolidated_only.next()) == null);

    const jsonl_result = try exportNativeJsonlStore(std.testing.allocator, std.testing.io, store, jsonl_path);
    try std.testing.expectEqual(@as(usize, 2), jsonl_result.edges_exported);
    const edges_path = try std.fs.path.join(std.testing.allocator, &.{ jsonl_path, "edges.jsonl" });
    defer std.testing.allocator.free(edges_path);
    const edges_jsonl = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, edges_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(edges_jsonl);
    try std.testing.expect(std.mem.indexOf(u8, edges_jsonl, "\"id\":2") != null);

    const markdown_result = try exportMarkdownStore(std.testing.allocator, std.testing.io, store, markdown_path);
    try std.testing.expectEqual(@as(usize, 2), markdown_result.edges_exported);

    var governance_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer governance_out.buffer.deinit(std.testing.allocator);
    try governance_command.render(std.testing.allocator, std.testing.io, db_path, store, null, &governance_out);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "max_outgoing_edges=2\n") != null);

    const schema_content = try catalogTestSchemaJsonAlloc(std.testing.allocator, "concept", 100);
    defer std.testing.allocator.free(schema_content);
    try writeSchemaFile(std.testing.io, schema_path, schema_content);
    var validate_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer validate_out.buffer.deinit(std.testing.allocator);
    try runSchemaValidate(std.testing.allocator, std.testing.io, &validate_out, store, .{
        .db_path = db_path,
        .schema_path = schema_path,
        .profiles = null,
    });
    try std.testing.expect(std.mem.indexOf(u8, validate_out.buffer.items, "SchemaUnknownKindInData domain=relation kind=100 count=1") != null);
}

test "audit exports normalize legacy closed task schema types" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const jsonl_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "jsonl" });
    defer std.testing.allocator.free(jsonl_path);
    const markdown_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "markdown" });
    defer std.testing.allocator.free(markdown_path);
    const imported_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "imported" });
    defer std.testing.allocator.free(imported_path);
    const markdown_imported_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "markdown-imported" });
    defer std.testing.allocator.free(markdown_imported_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .verification, .text = "legacy verification task" },
        .{ .id = .fromInt(2), .kind = .fix, .text = "legacy task without schema" },
        .{ .id = .fromInt(3), .kind = .fix, .text = "legacy custom task" },
    });
    inline for (&.{ core.NodeId.fromInt(1), core.NodeId.fromInt(2), core.NodeId.fromInt(3) }) |node_id| {
        try store.setUintProperty(std.testing.allocator, .{ .node = node_id }, "task_created_ns", 10);
        try store.setUintProperty(std.testing.allocator, .{ .node = node_id }, "task_completed_ns", 20);
    }
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), "schema_type", "verification");
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(3), "schema_type", "custom_review_task");

    _ = try exportNativeJsonlStore(std.testing.allocator, std.testing.io, store, jsonl_path);
    const nodes_path = try std.fs.path.join(std.testing.allocator, &.{ jsonl_path, "nodes.jsonl" });
    defer std.testing.allocator.free(nodes_path);
    const nodes_jsonl = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, nodes_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(nodes_jsonl);
    try std.testing.expect(std.mem.indexOf(u8, nodes_jsonl, "{\"id\":1,\"kind\":\"task\",\"text\":\"legacy verification task\",\"schema_type\":\"task\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, nodes_jsonl, "{\"id\":2,\"kind\":\"task\",\"text\":\"legacy task without schema\",\"schema_type\":\"task\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, nodes_jsonl, "{\"id\":3,\"kind\":\"task\",\"text\":\"legacy custom task\",\"schema_type\":\"custom_review_task\"") != null);

    _ = try importNativeJsonlStore(std.testing.allocator, std.testing.io, imported_path, jsonl_path, false);
    var imported = try storage.Store.open(std.testing.allocator, std.testing.io, imported_path);
    defer imported.deinit();
    inline for (&.{ core.NodeId.fromInt(1), core.NodeId.fromInt(2) }) |node_id| {
        var node = (try imported.readNodeById(std.testing.allocator, node_id)).?;
        defer node.deinit(std.testing.allocator);
        try std.testing.expectEqual(core.NodeKind.task, node.kind);
        const schema_type = (try imported.getNodeStringProperty(std.testing.allocator, node_id, "schema_type")).?;
        defer std.testing.allocator.free(schema_type);
        try std.testing.expectEqualStrings("task", schema_type);
    }

    _ = try exportMarkdownStore(std.testing.allocator, std.testing.io, store, markdown_path);
    const task_schema_dir = try std.fs.path.join(std.testing.allocator, &.{ markdown_path, markdown_nodes_dir, "_unmanaged", "task", "task" });
    defer std.testing.allocator.free(task_schema_dir);
    var task_files = try listMarkdownFilesRecursiveSorted(std.testing.allocator, std.testing.io, task_schema_dir);
    defer {
        for (task_files.items) |name| std.testing.allocator.free(name);
        task_files.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), task_files.items.len);
    for (task_files.items) |name| {
        const path = try std.fs.path.join(std.testing.allocator, &.{ task_schema_dir, name });
        defer std.testing.allocator.free(path);
        const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(4096));
        defer std.testing.allocator.free(content);
        try std.testing.expect(std.mem.indexOf(u8, content, "kind: task\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, content, "schema_type: task\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, content, "schema_type_json: \"task\"\n") != null);
    }
    const markdown_import = try importMarkdownStore(std.testing.allocator, std.testing.io, markdown_imported_path, markdown_path, false);
    try std.testing.expectEqual(@as(usize, 3), markdown_import.nodes_imported);
    try std.testing.expect(!markdown_import.marker_cleanup_pending);
    var markdown_imported = try storage.Store.open(std.testing.allocator, std.testing.io, markdown_imported_path);
    defer markdown_imported.deinit();
    const markdown_stats = try markdown_imported.stats();
    try std.testing.expectEqual(@as(u64, 3), markdown_stats.nodes);
}

test "failed exports preserve the previously published directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const jsonl_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "jsonl" });
    defer std.testing.allocator.free(jsonl_path);
    const markdown_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "markdown" });
    defer std.testing.allocator.free(markdown_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "malformed terminal task" });
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), task.status_property, "completed");

    try std.Io.Dir.cwd().createDirPath(std.testing.io, jsonl_path);
    const old_nodes_path = try std.fs.path.join(std.testing.allocator, &.{ jsonl_path, "nodes.jsonl" });
    defer std.testing.allocator.free(old_nodes_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = old_nodes_path, .data = "old-jsonl\n", .flags = .{ .truncate = true } });
    try std.testing.expectError(error.InvalidTaskLifecycle, exportNativeJsonlStore(std.testing.allocator, std.testing.io, store, jsonl_path));
    const old_nodes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, old_nodes_path, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(old_nodes);
    try std.testing.expectEqualStrings("old-jsonl\n", old_nodes);

    try std.Io.Dir.cwd().createDirPath(std.testing.io, markdown_path);
    const old_readme_path = try std.fs.path.join(std.testing.allocator, &.{ markdown_path, markdown_readme_file });
    defer std.testing.allocator.free(old_readme_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = old_readme_path, .data = "old-markdown\n", .flags = .{ .truncate = true } });
    try std.testing.expectError(error.InvalidTaskLifecycle, exportMarkdownStore(std.testing.allocator, std.testing.io, store, markdown_path));
    const old_readme = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, old_readme_path, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(old_readme);
    try std.testing.expectEqualStrings("old-markdown\n", old_readme);

    var root_dir = try std.Io.Dir.cwd().openDir(std.testing.io, root_path, .{ .iterate = true });
    defer root_dir.close(std.testing.io);
    var entries = root_dir.iterate();
    while (try entries.next(std.testing.io)) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.name, ".tinykg-export-") == null);
    }
}

test "export staging and import targets require exclusive directory ownership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "source.kg" });
    defer std.testing.allocator.free(db_path);
    const jsonl_staging = try std.fs.path.join(std.testing.allocator, &.{ root_path, "jsonl-staging" });
    defer std.testing.allocator.free(jsonl_staging);
    const markdown_staging = try std.fs.path.join(std.testing.allocator, &.{ root_path, "markdown-staging" });
    defer std.testing.allocator.free(markdown_staging);
    const import_target = try std.fs.path.join(std.testing.allocator, &.{ root_path, "import-target.kg" });
    defer std.testing.allocator.free(import_target);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "ownership source" });
    try ensureTaskStatusProperty(std.testing.allocator, store, .fromInt(1));

    for ([_][]const u8{ jsonl_staging, markdown_staging, import_target }) |target| {
        try std.Io.Dir.cwd().createDirPath(std.testing.io, target);
        const sentinel_path = try std.fs.path.join(std.testing.allocator, &.{ target, "sentinel" });
        defer std.testing.allocator.free(sentinel_path);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{
            .sub_path = sentinel_path,
            .data = "belongs-to-other-writer",
            .flags = .{ .truncate = true },
        });
    }

    try std.testing.expectError(error.AlreadyExists, exportNativeJsonlStoreIntoDirectory(
        std.testing.allocator,
        std.testing.io,
        store,
        jsonl_staging,
    ));
    try std.testing.expectError(error.AlreadyExists, exportMarkdownStoreIntoDirectory(
        std.testing.allocator,
        std.testing.io,
        store,
        markdown_staging,
    ));
    try std.testing.expectError(error.AlreadyExists, initOwnedBulkImportStore(
        std.testing.allocator,
        std.testing.io,
        import_target,
    ));

    for ([_][]const u8{ jsonl_staging, markdown_staging, import_target }) |target| {
        const sentinel_path = try std.fs.path.join(std.testing.allocator, &.{ target, "sentinel" });
        defer std.testing.allocator.free(sentinel_path);
        const sentinel = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, sentinel_path, std.testing.allocator, .limited(64));
        defer std.testing.allocator.free(sentinel);
        try std.testing.expectEqualStrings("belongs-to-other-writer", sentinel);
    }
}

test "native import never removes unmarked staging" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const corpus_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "jsonl" });
    defer std.testing.allocator.free(corpus_path);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "target.kg" });
    defer std.testing.allocator.free(target_path);
    const staging_path = try importStagingPath(std.testing.allocator, target_path);
    defer std.testing.allocator.free(staging_path);
    try createOwnedDirectory(std.testing.io, corpus_path);
    const nodes_path = try std.fs.path.join(std.testing.allocator, &.{ corpus_path, "nodes.jsonl" });
    defer std.testing.allocator.free(nodes_path);
    const edges_path = try std.fs.path.join(std.testing.allocator, &.{ corpus_path, "edges.jsonl" });
    defer std.testing.allocator.free(edges_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = nodes_path,
        .data = "{\"id\":1,\"kind\":\"concept\",\"text\":\"import source\"}\n",
        .flags = .{ .truncate = true },
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = edges_path,
        .data = "",
        .flags = .{ .truncate = true },
    });
    const nested_target = try std.fs.path.join(std.testing.allocator, &.{ corpus_path, "nested.kg" });
    defer std.testing.allocator.free(nested_target);
    try std.testing.expectError(error.InvalidFileName, importNativeJsonlStore(
        std.testing.allocator,
        std.testing.io,
        nested_target,
        corpus_path,
        false,
    ));
    try std.testing.expect(!try anyPathExists(std.testing.io, nested_target));
    try createOwnedDirectory(std.testing.io, staging_path);
    const sentinel_path = try std.fs.path.join(std.testing.allocator, &.{ staging_path, "foreign" });
    defer std.testing.allocator.free(sentinel_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = sentinel_path, .data = "foreign", .flags = .{ .truncate = true } });

    try std.testing.expectError(error.ImportRecoveryConflict, importNativeJsonlStore(
        std.testing.allocator,
        std.testing.io,
        target_path,
        corpus_path,
        false,
    ));
    try std.testing.expect(try fileExists(std.testing.io, sentinel_path));
    try std.testing.expect(!try anyPathExists(std.testing.io, target_path));
}

test "task status materialization preserves live legacy leases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .task, .text = "live legacy claim" },
        .{ .id = .fromInt(2), .kind = .task, .text = "malformed legacy claim" },
        .{ .id = .fromInt(3), .kind = .task, .text = "malformed explicit terminal" },
    });
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), task.claimed_by_property, "legacy-agent");
    try store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(1) }, task.claim_expires_ns_property, std.math.maxInt(u64));
    try store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(2) }, task.claim_expires_ns_property, std.math.maxInt(u64));
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(3), task.status_property, "completed");

    try ensureTaskStatusProperty(std.testing.allocator, store, .fromInt(1));
    const raw_status = (try store.getNodeStringProperty(std.testing.allocator, .fromInt(1), task.status_property)).?;
    defer std.testing.allocator.free(raw_status);
    try std.testing.expectEqualStrings("claimed", raw_status);
    try std.testing.expectEqual(task.Status.claimed, try task.statusWithPersistentStoreAt(std.testing.allocator, store, .fromInt(1), 1));

    try std.testing.expectError(error.InvalidTaskLifecycle, ensureTaskStatusProperty(std.testing.allocator, store, .fromInt(2)));
    try std.testing.expect((try store.getNodeStringProperty(std.testing.allocator, .fromInt(2), task.status_property)) == null);
    try std.testing.expectError(error.InvalidTaskLifecycle, ensureTaskStatusProperty(std.testing.allocator, store, .fromInt(3)));
}

test "update-node validates a prospective task lifecycle before rewriting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        try store.createEmpty();
        try store.appendNode(.{ .id = .fromInt(1), .kind = .verification, .text = "published evidence" });
        _ = try store.upsertPropertiesBatch(std.testing.allocator, &.{
            .{ .owner = .{ .node = .fromInt(1) }, .key = task.status_property, .value = .{ .string = "published" } },
            .{ .owner = .{ .node = .fromInt(1) }, .key = "task_created_ns", .value = .{ .uint = 10 } },
            .{ .owner = .{ .node = .fromInt(1) }, .key = "task_completed_ns", .value = .{ .uint = 20 } },
        });
    }

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidTaskLifecycle, run(
        &.{ "tinykg", "update-node", db_path, "1", "task", "silently converted task" },
        &out,
        std.testing.allocator,
        std.testing.io,
    ));

    var reopened = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
    defer reopened.deinit();
    var node = (try reopened.readNodeById(std.testing.allocator, .fromInt(1))).?;
    defer node.deinit(std.testing.allocator);
    try std.testing.expectEqual(core.NodeKind.verification, node.kind);
    try std.testing.expectEqualStrings("published evidence", node.text);
    const raw_status = (try reopened.getNodeStringProperty(std.testing.allocator, .fromInt(1), task.status_property)).?;
    defer std.testing.allocator.free(raw_status);
    try std.testing.expectEqualStrings("published", raw_status);
}

test "native JSONL roundtrip preserves deferred based_on sidecar" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const export_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "jsonl" });
    defer std.testing.allocator.free(export_path);
    const imported_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "imported" });
    defer std.testing.allocator.free(imported_path);

    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        try store.createEmpty();
        try store.appendNodesBatch(&.{
            .{ .id = .fromInt(1), .kind = .decision, .text = "source decision props_text=\"{\"domain_id\":\"tinykg\",\"schema_type\":\"decision\"}\"" },
            .{ .id = .fromInt(2), .kind = .evidence, .text = "visible evidence props_text=\"{\"domain_id\":\"tinykg\",\"schema_type\":\"evidence\"}\"" },
            .{ .id = .fromInt(3), .kind = .evidence, .text = "deferred evidence props_text=\"{\"domain_id\":\"tinykg\",\"schema_type\":\"evidence\"}\"" },
        });
        try store.appendEdgesBatch(&.{
            .{ .id = .fromInt(1), .src = .fromInt(1), .rel = .related_to, .dst = .fromInt(2) },
        });
        _ = try writeMetaknowDeferredBasedOnForwardPairsSidecar(std.testing.allocator, store, &.{
            .{ .src = 1, .dst = 3 },
        }, 3);
    }

    var export_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer export_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "export-jsonl", db_path, export_path }, &export_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, export_out.buffer.items, "nodes_exported=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, export_out.buffer.items, "edges_exported=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, export_out.buffer.items, "deferred_based_on_exported=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, export_out.buffer.items, "cleanup_pending=0") != null);

    const deferred_path = try std.fs.path.join(std.testing.allocator, &.{ export_path, native_jsonl_deferred_based_on_file });
    defer std.testing.allocator.free(deferred_path);
    const deferred_text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, deferred_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(deferred_text);
    try std.testing.expect(std.mem.indexOf(u8, deferred_text, "\"src\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, deferred_text, "\"dst\":3") != null);

    var import_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer import_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "import-jsonl", imported_path, export_path, "--warm-text" }, &import_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "nodes_imported=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "edges_imported=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "deferred_based_on_imported=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "marker_cleanup_pending=0") != null);

    // Reconstruct the exact request identity before exercising legacy receipt
    // upgrade and repeated acknowledgement.
    const exported_nodes_path = try std.fs.path.join(std.testing.allocator, &.{ export_path, "nodes.jsonl" });
    defer std.testing.allocator.free(exported_nodes_path);
    const exported_edges_path = try std.fs.path.join(std.testing.allocator, &.{ export_path, "edges.jsonl" });
    defer std.testing.allocator.free(exported_edges_path);
    const exported_nodes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, exported_nodes_path, std.testing.allocator, .limited(native_jsonl_max_bytes));
    defer std.testing.allocator.free(exported_nodes);
    const exported_edges = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, exported_edges_path, std.testing.allocator, .limited(native_jsonl_max_bytes));
    defer std.testing.allocator.free(exported_edges);
    var import_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    updateImportDigest(&import_hasher, "nodes.jsonl", exported_nodes);
    updateImportDigest(&import_hasher, "edges.jsonl", exported_edges);
    updateImportDigest(&import_hasher, native_jsonl_deferred_based_on_file, deferred_text);
    const canonical_export_path = try canonicalProspectivePath(std.testing.allocator, std.testing.io, export_path);
    defer std.testing.allocator.free(canonical_export_path);
    const import_expectation = ImportTransactionExpectation{
        .format = "jsonl",
        .canonical_source_path = canonical_export_path,
        .source_digest = finalizeContentDigest(&import_hasher),
        .warm_text = true,
    };
    const imported_bytes = @as(u64, @intCast(exported_nodes.len)) + @as(u64, @intCast(exported_edges.len)) + @as(u64, @intCast(deferred_text.len));
    const import_marker_path = try importTransactionMarkerPath(std.testing.allocator, imported_path);
    defer std.testing.allocator.free(import_marker_path);
    try std.testing.expect(try anyPathExists(std.testing.io, import_marker_path));
    try rewriteTransactionMarkerFormatForTest(
        std.testing.io,
        import_marker_path,
        import_transaction_marker_format,
        import_transaction_marker_legacy_format,
    );
    const recovered_import = try importNativeJsonlStore(std.testing.allocator, std.testing.io, imported_path, export_path, true);
    try std.testing.expectEqual(@as(usize, 3), recovered_import.nodes_imported);
    try std.testing.expectEqual(@as(usize, 1), recovered_import.deferred_based_on_imported);
    try std.testing.expect(!recovered_import.marker_cleanup_pending);
    try std.testing.expect(try anyPathExists(std.testing.io, import_marker_path));
    try std.testing.expect(try transactionMarkerHasFormatForTest(std.testing.io, import_marker_path, import_transaction_marker_format));

    var governance_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer governance_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "governance", imported_path }, &governance_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "edges=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "traversable_relation_count related_to=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "traversable_relation_count based_on=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "unattached_fact_edges=2\n") != null);

    // A same-count mutation after the rename must not be acknowledged as the
    // completed import.  The marker remains available for diagnosis instead
    // of being cleared before the conflict is reported.
    const pre_tamper_identity = try storeContentIdentity(std.testing.allocator, std.testing.io, imported_path);
    try writeImportTransactionMarker(std.testing.allocator, std.testing.io, imported_path, import_expectation, .{
        .nodes_loaded = 3,
        .nodes_imported = 3,
        .edges_loaded = 1,
        .edges_imported = 1,
        .deferred_based_on_loaded = 1,
        .deferred_based_on_imported = 1,
        .source_bytes = imported_bytes,
        .text_warmed = true,
        .published_store_bytes = pre_tamper_identity.bytes,
        .published_store_digest = pre_tamper_identity.digest,
    });
    const imported_manifest_path = try storeManifestPath(std.testing.allocator, imported_path);
    defer std.testing.allocator.free(imported_manifest_path);
    const imported_manifest = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, imported_manifest_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(imported_manifest);
    const migration_name_offset = std.mem.indexOf(u8, imported_manifest, "import-jsonl") orelse return error.InvalidRecord;
    imported_manifest[migration_name_offset + "import-json".len] = 'x';
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = imported_manifest_path,
        .data = imported_manifest,
        .flags = .{ .truncate = true },
    });
    try std.testing.expectError(error.ImportRecoveryConflict, importNativeJsonlStore(
        std.testing.allocator,
        std.testing.io,
        imported_path,
        export_path,
        true,
    ));
    try std.testing.expect(try anyPathExists(std.testing.io, import_marker_path));

    const no_sidecar_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg-no-sidecar" });
    defer std.testing.allocator.free(no_sidecar_path);
    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, no_sidecar_path);
        defer store.deinit();
        try store.createEmpty();
        try store.appendNodesBatch(&.{
            .{ .id = .fromInt(1), .kind = .concept, .text = "no sidecar source" },
        });
    }

    var export_without_sidecar_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer export_without_sidecar_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "export-jsonl", no_sidecar_path, export_path }, &export_without_sidecar_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, export_without_sidecar_out.buffer.items, "deferred_based_on_exported=0") != null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, deferred_path, .{}));
}

test "native JSONL import cleans target after allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const corpus_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "native-jsonl" });
    defer std.testing.allocator.free(corpus_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, corpus_path);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "native-jsonl/nodes.jsonl",
        .data =
        \\{"id":1,"kind":"concept","text":"allocation failure source"}
        \\{"id":2,"kind":"concept","text":"allocation failure target"}
        \\
        ,
        .flags = .{ .truncate = true },
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "native-jsonl/edges.jsonl",
        .data =
        \\{"id":1,"src":1,"rel":"related_to","dst":2}
        \\
        ,
        .flags = .{ .truncate = true },
    });

    var saw_allocation_failure = false;
    var reached_success = false;
    for (0..512) |fail_index| {
        const db_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/oom-import-{}.kg", .{ root_path, fail_index });
        defer std.testing.allocator.free(db_path);
        const staging_path = try importStagingPath(std.testing.allocator, db_path);
        defer std.testing.allocator.free(staging_path);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        _ = importNativeJsonlStore(failing.allocator(), std.testing.io, db_path, corpus_path, true) catch |err| switch (err) {
            error.OutOfMemory => {
                saw_allocation_failure = true;
                try std.testing.expect(!try anyPathExists(std.testing.io, db_path));
                try std.testing.expect(!try anyPathExists(std.testing.io, staging_path));
                continue;
            },
            else => return err,
        };
        reached_success = true;
        try std.Io.Dir.cwd().deleteTree(std.testing.io, db_path);
        break;
    }
    try std.testing.expect(saw_allocation_failure);
    try std.testing.expect(reached_success);
}

fn rewriteTransactionMarkerFormatForTest(
    io: std.Io,
    marker_path: []const u8,
    current_format: []const u8,
    replacement_format: []const u8,
) !void {
    if (current_format.len != replacement_format.len) return error.InvalidRecord;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, marker_path, std.testing.allocator, .limited(32 * 1024));
    defer std.testing.allocator.free(bytes);
    const offset = std.mem.indexOf(u8, bytes, current_format) orelse return error.InvalidRecord;
    @memcpy(bytes[offset .. offset + replacement_format.len], replacement_format);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = marker_path,
        .data = bytes,
        .flags = .{ .truncate = true },
    });
}

fn transactionMarkerHasFormatForTest(io: std.Io, marker_path: []const u8, format: []const u8) !bool {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, marker_path, std.testing.allocator, .limited(32 * 1024));
    defer std.testing.allocator.free(bytes);
    return std.mem.indexOf(u8, bytes, format) != null;
}

test "complete publication marker remains as retryable commit receipt for backup and restore" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const backup_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg-backup" });
    defer std.testing.allocator.free(backup_path);
    const restored_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg-restored" });
    defer std.testing.allocator.free(restored_path);

    var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer init_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);

    var add_a_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer add_a_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "task", "backup source task" }, &add_a_out, std.testing.allocator, std.testing.io);

    var add_b_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer add_b_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "note", "backup source note" }, &add_b_out, std.testing.allocator, std.testing.io);

    var edge_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer edge_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-edge", db_path, "1", "supports", "2" }, &edge_out, std.testing.allocator, std.testing.io);

    var backup_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer backup_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "backup", db_path, backup_path }, &backup_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, backup_out.buffer.items, "nodes=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, backup_out.buffer.items, "edges=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, backup_out.buffer.items, "backup_store_bytes=") != null);
    try std.testing.expect(std.mem.indexOf(u8, backup_out.buffer.items, "marker_cleanup_pending=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, backup_out.buffer.items, "elapsed_ns=") != null);

    var backup_store = try storage.Store.open(std.testing.allocator, std.testing.io, backup_path);
    defer backup_store.deinit();
    const backup_stats = try backup_store.stats();
    try std.testing.expectEqual(@as(u64, 2), backup_stats.nodes);
    try std.testing.expectEqual(@as(u64, 1), backup_stats.edges);

    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ backup_path, backup_manifest_file });
    defer std.testing.allocator.free(manifest_path);
    const manifest = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, manifest_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "format=tinykg-backup-v2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "nodes=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "edges=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "source_store_digest=") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "source_payload_digest=") != null);

    const backup_marker_path = try backupTransactionMarkerPath(std.testing.allocator, backup_path);
    defer std.testing.allocator.free(backup_marker_path);
    try std.testing.expect(try anyPathExists(std.testing.io, backup_marker_path));

    var retry_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer retry_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "backup", db_path, backup_path }, &retry_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, retry_out.buffer.items, "nodes=2") != null);
    try std.testing.expect(try anyPathExists(std.testing.io, backup_marker_path));

    var restore_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer restore_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "restore", backup_path, restored_path }, &restore_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, restore_out.buffer.items, "nodes=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, restore_out.buffer.items, "edges=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, restore_out.buffer.items, "marker_cleanup_pending=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, restore_out.buffer.items, "elapsed_ns=") != null);
    const restore_marker_path = try restoreTransactionMarkerPath(std.testing.allocator, restored_path);
    defer std.testing.allocator.free(restore_marker_path);
    try std.testing.expect(try anyPathExists(std.testing.io, restore_marker_path));

    restore_out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "restore", backup_path, restored_path }, &restore_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, restore_out.buffer.items, "nodes=2") != null);
    try std.testing.expect(try anyPathExists(std.testing.io, restore_marker_path));

    var restored_store = try storage.Store.open(std.testing.allocator, std.testing.io, restored_path);
    defer restored_store.deinit();
    const restored_stats = try restored_store.stats();
    try std.testing.expectEqual(@as(u64, 2), restored_stats.nodes);
    try std.testing.expectEqual(@as(u64, 1), restored_stats.edges);
}

test "backup atomically recovers matched staging and promoted target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "source.kg" });
    defer std.testing.allocator.free(source_path);
    const backup_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "backup.kg" });
    defer std.testing.allocator.free(backup_path);
    const staging_path = try backupStagingPath(std.testing.allocator, backup_path);
    defer std.testing.allocator.free(staging_path);
    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, source_path);
        defer store.deinit();
        try store.createEmpty();
        try store.appendNode(.{ .id = .fromInt(1), .kind = .concept, .text = "backup recovery source" });
    }
    const source_metadata_path = try std.fs.path.join(std.testing.allocator, &.{ source_path, "source-metadata" });
    defer std.testing.allocator.free(source_metadata_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = source_metadata_path,
        .data = "alpha",
        .flags = .{ .truncate = true },
    });
    const canonical_source = try canonicalProspectivePath(std.testing.allocator, std.testing.io, source_path);
    defer std.testing.allocator.free(canonical_source);
    const expected = try backupExpectationForSource(std.testing.allocator, std.testing.io, source_path, canonical_source);

    try createOwnedDirectory(std.testing.io, staging_path);
    try writeBackupTransactionMarker(std.testing.allocator, std.testing.io, staging_path, expected, false);
    const partial_path = try std.fs.path.join(std.testing.allocator, &.{ staging_path, "partial" });
    defer std.testing.allocator.free(partial_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = partial_path, .data = "partial", .flags = .{ .truncate = true } });
    const first = try backupStore(std.testing.allocator, std.testing.io, source_path, backup_path);
    try std.testing.expectEqual(@as(u64, 1), first.nodes);
    try std.testing.expect(!first.marker_cleanup_pending);
    try std.testing.expect(!try anyPathExists(std.testing.io, staging_path));

    const marker_path = try backupTransactionMarkerPath(std.testing.allocator, backup_path);
    defer std.testing.allocator.free(marker_path);
    try std.testing.expect(try anyPathExists(std.testing.io, marker_path));

    // A receipt created by the cleanup-era binary is accepted once, strictly
    // validated, and upgraded so that old binaries cannot delete it.
    try rewriteTransactionMarkerFormatForTest(
        std.testing.io,
        marker_path,
        backup_transaction_marker_format,
        backup_transaction_marker_legacy_format,
    );
    const recovered = try backupStore(std.testing.allocator, std.testing.io, source_path, backup_path);
    try std.testing.expectEqual(first.nodes, recovered.nodes);
    try std.testing.expectEqual(first.backup_store_bytes, recovered.backup_store_bytes);
    try std.testing.expect(!recovered.marker_cleanup_pending);
    try std.testing.expect(try anyPathExists(std.testing.io, marker_path));
    try std.testing.expect(try transactionMarkerHasFormatForTest(std.testing.io, marker_path, backup_transaction_marker_format));

    // Accept exactly one predecessor, not arbitrary future or corrupted
    // formats. Unknown receipts stay in place and fail closed.
    const unknown_format = "tinykg-backup-transaction-v9";
    try rewriteTransactionMarkerFormatForTest(std.testing.io, marker_path, backup_transaction_marker_format, unknown_format);
    try std.testing.expectError(
        error.BackupRecoveryConflict,
        backupStore(std.testing.allocator, std.testing.io, source_path, backup_path),
    );
    try std.testing.expect(try transactionMarkerHasFormatForTest(std.testing.io, marker_path, unknown_format));
    try rewriteTransactionMarkerFormatForTest(std.testing.io, marker_path, unknown_format, backup_transaction_marker_format);

    // A same-size source change is a different backup request even when graph
    // counts and aggregate bytes remain identical.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = source_metadata_path,
        .data = "bravo",
        .flags = .{ .truncate = true },
    });
    try std.testing.expectError(error.BackupRecoveryConflict, backupStore(
        std.testing.allocator,
        std.testing.io,
        source_path,
        backup_path,
    ));
    try std.testing.expect(try anyPathExists(std.testing.io, marker_path));

    // Restore the source identity, then mutate the published backup by the
    // same number of bytes. Exact manifest plus payload hashing must reject it.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = source_metadata_path,
        .data = "alpha",
        .flags = .{ .truncate = true },
    });
    const backup_metadata_path = try std.fs.path.join(std.testing.allocator, &.{ backup_path, "source-metadata" });
    defer std.testing.allocator.free(backup_metadata_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = backup_metadata_path,
        .data = "bravo",
        .flags = .{ .truncate = true },
    });
    try std.testing.expectError(error.BackupRecoveryConflict, backupStore(
        std.testing.allocator,
        std.testing.io,
        source_path,
        backup_path,
    ));
    try std.testing.expect(try anyPathExists(std.testing.io, marker_path));
    try deleteBackupTransactionMarker(std.testing.allocator, std.testing.io, backup_path);
    try std.testing.expectError(error.BackupRecoveryConflict, validateExistingBackupForSource(
        std.testing.allocator,
        std.testing.io,
        source_path,
        backup_path,
    ));
}

test "backup never removes unmarked staging" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "source.kg" });
    defer std.testing.allocator.free(source_path);
    const backup_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "backup.kg" });
    defer std.testing.allocator.free(backup_path);
    const staging_path = try backupStagingPath(std.testing.allocator, backup_path);
    defer std.testing.allocator.free(staging_path);
    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, source_path);
        defer store.deinit();
        try store.createEmpty();
    }
    try createOwnedDirectory(std.testing.io, staging_path);
    const sentinel_path = try std.fs.path.join(std.testing.allocator, &.{ staging_path, "foreign" });
    defer std.testing.allocator.free(sentinel_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = sentinel_path, .data = "foreign", .flags = .{ .truncate = true } });
    try std.testing.expectError(error.BackupRecoveryConflict, backupStore(std.testing.allocator, std.testing.io, source_path, backup_path));
    try std.testing.expect(try fileExists(std.testing.io, sentinel_path));
    try std.testing.expect(!try anyPathExists(std.testing.io, backup_path));
}

test "restore atomically recovers matched staging and promoted target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "source.kg" });
    defer std.testing.allocator.free(source_path);
    const backup_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "backup.kg" });
    defer std.testing.allocator.free(backup_path);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "restored.kg" });
    defer std.testing.allocator.free(target_path);
    const staging_path = try restoreStagingPath(std.testing.allocator, target_path);
    defer std.testing.allocator.free(staging_path);
    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, source_path);
        defer store.deinit();
        try store.createEmpty();
        try store.appendNode(.{ .id = .fromInt(1), .kind = .concept, .text = "restore recovery source" });
        try writeStoreManifest(std.testing.allocator, std.testing.io, source_path, .{ .migration_name = "init" });
    }
    _ = try backupStore(std.testing.allocator, std.testing.io, source_path, backup_path);
    const canonical_backup = try canonicalProspectivePath(std.testing.allocator, std.testing.io, backup_path);
    defer std.testing.allocator.free(canonical_backup);
    const expected = try restoreExpectationForSource(std.testing.allocator, std.testing.io, backup_path, canonical_backup);

    try createOwnedDirectory(std.testing.io, staging_path);
    try writeRestoreTransactionMarker(std.testing.allocator, std.testing.io, staging_path, expected, false);
    const partial_path = try std.fs.path.join(std.testing.allocator, &.{ staging_path, "partial" });
    defer std.testing.allocator.free(partial_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = partial_path, .data = "partial", .flags = .{ .truncate = true } });
    const first = try restoreBackup(std.testing.allocator, std.testing.io, backup_path, target_path);
    try std.testing.expectEqual(@as(u64, 1), first.nodes);
    try std.testing.expect(!first.marker_cleanup_pending);
    try std.testing.expect(!try anyPathExists(std.testing.io, staging_path));

    const marker_path = try restoreTransactionMarkerPath(std.testing.allocator, target_path);
    defer std.testing.allocator.free(marker_path);
    try std.testing.expect(try anyPathExists(std.testing.io, marker_path));

    // Upgrade an exact legacy receipt only after validating the source and
    // target under the current recovery protocol.
    try rewriteTransactionMarkerFormatForTest(
        std.testing.io,
        marker_path,
        restore_transaction_marker_format,
        restore_transaction_marker_legacy_format,
    );
    const recovered = try restoreBackup(std.testing.allocator, std.testing.io, backup_path, target_path);
    try std.testing.expectEqual(first.nodes, recovered.nodes);
    try std.testing.expectEqual(first.backup_store_bytes, recovered.backup_store_bytes);
    try std.testing.expect(!recovered.marker_cleanup_pending);
    try std.testing.expect(try anyPathExists(std.testing.io, marker_path));
    try std.testing.expect(try transactionMarkerHasFormatForTest(std.testing.io, marker_path, restore_transaction_marker_format));

    // A same-size target mutation cannot be mistaken for the completed copy.
    const manifest_path = try storeManifestPath(std.testing.allocator, target_path);
    defer std.testing.allocator.free(manifest_path);
    const manifest = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, manifest_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(manifest);
    const name_offset = std.mem.indexOf(u8, manifest, "\"name\": \"init\"") orelse return error.InvalidRecord;
    manifest[name_offset + "\"name\": \"ini".len] = 'x';
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = manifest_path, .data = manifest, .flags = .{ .truncate = true } });
    try std.testing.expectError(
        error.RestoreRecoveryConflict,
        restoreBackup(std.testing.allocator, std.testing.io, backup_path, target_path),
    );
    try std.testing.expect(try anyPathExists(std.testing.io, marker_path));
}

test "restore never removes unmarked staging or foreign final target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "source.kg" });
    defer std.testing.allocator.free(source_path);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "target.kg" });
    defer std.testing.allocator.free(target_path);
    const staging_path = try restoreStagingPath(std.testing.allocator, target_path);
    defer std.testing.allocator.free(staging_path);
    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, source_path);
        defer store.deinit();
        try store.createEmpty();
    }
    try createOwnedDirectory(std.testing.io, staging_path);
    const staging_sentinel = try std.fs.path.join(std.testing.allocator, &.{ staging_path, "foreign" });
    defer std.testing.allocator.free(staging_sentinel);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = staging_sentinel, .data = "foreign staging", .flags = .{ .truncate = true } });
    try std.testing.expectError(error.RestoreRecoveryConflict, restoreBackup(std.testing.allocator, std.testing.io, source_path, target_path));
    try std.testing.expect(try fileExists(std.testing.io, staging_sentinel));

    try std.Io.Dir.cwd().deleteTree(std.testing.io, staging_path);
    try createOwnedDirectory(std.testing.io, target_path);
    const final_sentinel = try std.fs.path.join(std.testing.allocator, &.{ target_path, "foreign" });
    defer std.testing.allocator.free(final_sentinel);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = final_sentinel, .data = "foreign final", .flags = .{ .truncate = true } });
    try std.testing.expectError(error.AlreadyExists, restoreBackup(std.testing.allocator, std.testing.io, source_path, target_path));
    try std.testing.expect(try fileExists(std.testing.io, final_sentinel));
}

test "migrate-store-v2 reuses an exact existing rollback backup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "source.kg" });
    defer std.testing.allocator.free(source_path);
    const backup_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "backup.kg" });
    defer std.testing.allocator.free(backup_path);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "target.kg" });
    defer std.testing.allocator.free(target_path);
    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, source_path);
        defer store.deinit();
        try store.createEmpty();
        try store.appendNode(.{ .id = .fromInt(1), .kind = .concept, .text = "backup reuse source" });
    }
    _ = try backupStore(std.testing.allocator, std.testing.io, source_path, backup_path);
    const migrated = try migrateStoreV2(std.testing.allocator, std.testing.io, .{
        .source_path = source_path,
        .target_path = target_path,
        .backup_path = backup_path,
    });
    try std.testing.expectEqual(@as(u64, 1), migrated.nodes_written);
    try std.testing.expect(try existingTinyKgStorePath(std.testing.allocator, std.testing.io, backup_path));
    try std.testing.expect(try existingTinyKgStorePath(std.testing.allocator, std.testing.io, target_path));
}

test "copy and migration targets reject normalized and symlink path overlap" {
    if (builtin.os.tag == .windows) {
        try std.testing.expect(canonicalPathContains("C:\\", "c:\\nested"));
    } else {
        try std.testing.expect(canonicalPathContains("/", "/nested"));
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "source.kg" });
    defer std.testing.allocator.free(db_path);
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "path overlap task" });

    const dotted_child = try std.fs.path.join(std.testing.allocator, &.{ root_path, ".", "source.kg", "nested-backup" });
    defer std.testing.allocator.free(dotted_child);
    try std.testing.expectError(error.InvalidFileName, backupStore(std.testing.allocator, std.testing.io, db_path, dotted_child));
    try std.testing.expect(!try anyPathExists(std.testing.io, dotted_child));
    var nested_schema_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer nested_schema_out.buffer.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidFileName, run(&.{
        "tinykg",
        "schema-migrate",
        db_path,
        dotted_child,
    }, &nested_schema_out, std.testing.allocator, std.testing.io));

    if (builtin.os.tag != .windows) {
        const alias_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "source-alias" });
        defer std.testing.allocator.free(alias_path);
        try std.Io.Dir.symLinkAbsolute(std.testing.io, db_path, alias_path, .{ .is_directory = true });
        const alias_child = try std.fs.path.join(std.testing.allocator, &.{ alias_path, "nested-backup" });
        defer std.testing.allocator.free(alias_child);
        try std.testing.expectError(error.InvalidFileName, backupStore(std.testing.allocator, std.testing.io, db_path, alias_child));
        try std.testing.expect(!try anyPathExists(std.testing.io, alias_child));

        // Dispatcher preflight must reject the alias before it recursively
        // acquires source/.tinykg-cli.lock through the target spelling.
        var alias_out = QueryOutputWriter{ .allocator = std.testing.allocator };
        defer alias_out.buffer.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidFileName, run(&.{
            "tinykg",
            "migrate-store-v2",
            db_path,
            alias_path,
            "--task-status-v1",
        }, &alias_out, std.testing.allocator, std.testing.io));
        var schema_alias_out = QueryOutputWriter{ .allocator = std.testing.allocator };
        defer schema_alias_out.buffer.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidFileName, run(&.{
            "tinykg",
            "schema-migrate",
            db_path,
            alias_path,
        }, &schema_alias_out, std.testing.allocator, std.testing.io));
    }

    const occupied_schema_target = try std.fs.path.join(std.testing.allocator, &.{ root_path, "occupied-schema-target" });
    defer std.testing.allocator.free(occupied_schema_target);
    try std.Io.Dir.cwd().createDir(std.testing.io, occupied_schema_target, .default_dir);
    const sentinel_path = try std.fs.path.join(std.testing.allocator, &.{ occupied_schema_target, "foreign.txt" });
    defer std.testing.allocator.free(sentinel_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = sentinel_path, .data = "foreign", .flags = .{ .truncate = true } });
    var occupied_schema_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer occupied_schema_out.buffer.deinit(std.testing.allocator);
    try std.testing.expectError(error.AlreadyExists, run(&.{
        "tinykg",
        "schema-migrate",
        db_path,
        occupied_schema_target,
    }, &occupied_schema_out, std.testing.allocator, std.testing.io));
    try std.testing.expect(try fileExists(std.testing.io, sentinel_path));

    const migration_target = try std.fs.path.join(std.testing.allocator, &.{ root_path, "migrated.kg" });
    defer std.testing.allocator.free(migration_target);
    try std.testing.expectError(error.InvalidFileName, migrateStoreV2(std.testing.allocator, std.testing.io, .{
        .source_path = db_path,
        .target_path = migration_target,
        .backup_path = migration_target,
        .task_status_v1 = true,
    }));
    try std.testing.expect(!try anyPathExists(std.testing.io, migration_target));

    const nested_backup = try std.fs.path.join(std.testing.allocator, &.{ migration_target, "backup.kg" });
    defer std.testing.allocator.free(nested_backup);
    try std.testing.expectError(error.InvalidFileName, migrateStoreV2(std.testing.allocator, std.testing.io, .{
        .source_path = db_path,
        .target_path = migration_target,
        .backup_path = nested_backup,
        .task_status_v1 = true,
    }));
    try std.testing.expect(!try anyPathExists(std.testing.io, migration_target));
}

test "copy target ownership race preserves a directory created after preflight" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "source" });
    defer std.testing.allocator.free(source_path);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "target" });
    defer std.testing.allocator.free(target_path);
    const source_file_path = try std.fs.path.join(std.testing.allocator, &.{ source_path, "source-file" });
    defer std.testing.allocator.free(source_file_path);
    const sentinel_path = try std.fs.path.join(std.testing.allocator, &.{ target_path, "sentinel" });
    defer std.testing.allocator.free(sentinel_path);

    try std.Io.Dir.cwd().createDirPath(std.testing.io, source_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = source_file_path,
        .data = "source",
        .flags = .{ .truncate = true },
    });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, target_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = sentinel_path,
        .data = "belongs-to-other-writer",
        .flags = .{ .truncate = true },
    });

    try std.testing.expectError(error.AlreadyExists, copyDirectoryTree(std.testing.allocator, std.testing.io, source_path, target_path));
    const sentinel = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, sentinel_path, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(sentinel);
    try std.testing.expectEqualStrings("belongs-to-other-writer", sentinel);
}

test "store snapshots exclude only root transaction controls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "source" });
    defer std.testing.allocator.free(source_path);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "target" });
    defer std.testing.allocator.free(target_path);
    const nested_path = try std.fs.path.join(std.testing.allocator, &.{ source_path, "nested" });
    defer std.testing.allocator.free(nested_path);
    const root_control_path = try std.fs.path.join(std.testing.allocator, &.{ source_path, backup_transaction_marker_file });
    defer std.testing.allocator.free(root_control_path);
    const nested_control_path = try std.fs.path.join(std.testing.allocator, &.{ nested_path, backup_transaction_marker_file });
    defer std.testing.allocator.free(nested_control_path);

    try createOwnedDirectory(std.testing.io, source_path);
    try createOwnedDirectory(std.testing.io, nested_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = root_control_path,
        .data = "root-control",
        .flags = .{ .truncate = true },
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = nested_control_path,
        .data = "alpha",
        .flags = .{ .truncate = true },
    });

    const before = try storeContentIdentity(std.testing.allocator, std.testing.io, source_path);
    try std.testing.expectEqual(@as(u64, 5), before.bytes);
    try std.testing.expectEqual(@as(u64, 5), try storeDirBytes(std.testing.allocator, std.testing.io, source_path));
    try createOwnedDirectory(std.testing.io, target_path);
    try copyDirectoryTreeContents(std.testing.allocator, std.testing.io, source_path, target_path);
    const copied_root_control = try std.fs.path.join(std.testing.allocator, &.{ target_path, backup_transaction_marker_file });
    defer std.testing.allocator.free(copied_root_control);
    const copied_nested_control = try std.fs.path.join(std.testing.allocator, &.{ target_path, "nested", backup_transaction_marker_file });
    defer std.testing.allocator.free(copied_nested_control);
    try std.testing.expect(!try anyPathExists(std.testing.io, copied_root_control));
    try std.testing.expect(try fileExists(std.testing.io, copied_nested_control));

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = nested_control_path,
        .data = "bravo",
        .flags = .{ .truncate = true },
    });
    const after = try storeContentIdentity(std.testing.allocator, std.testing.io, source_path);
    try std.testing.expectEqual(before.bytes, after.bytes);
    try std.testing.expect(!std.meta.eql(before.digest, after.digest));
}

test "migrate-store-v2 reclaims only request-matched staging state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "source.kg" });
    defer std.testing.allocator.free(source_path);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "target.kg" });
    defer std.testing.allocator.free(target_path);
    const staging_path = try storeMigrationV2StagingPath(std.testing.allocator, target_path);
    defer std.testing.allocator.free(staging_path);
    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, source_path);
        defer store.deinit();
        try store.createEmpty();
        try store.appendNode(.{ .id = .fromInt(1), .kind = .concept, .text = "migration staging source" });
    }

    var source = try storage.Store.open(std.testing.allocator, std.testing.io, source_path);
    defer source.deinit();
    var target_catalog = try migrationCatalog(std.testing.allocator, source, "agent-dag,markdown-document", false, false);
    defer target_catalog.deinit();
    const target_profiles = try catalogProfilesCsvAlloc(std.testing.allocator, target_catalog);
    defer std.testing.allocator.free(target_profiles);
    const canonical_source = try canonicalProspectivePath(std.testing.allocator, std.testing.io, source_path);
    defer std.testing.allocator.free(canonical_source);
    const source_identity = try storeContentIdentity(std.testing.allocator, std.testing.io, source_path);
    const expected = StoreMigrationV2TransactionExpectation{
        .canonical_source_path = canonical_source,
        .canonical_backup_path = "",
        .source_store_bytes = source_identity.bytes,
        .source_store_digest = source_identity.digest,
        .target_profiles = target_profiles,
        .target_catalog_revision = target_catalog.revision,
        .target_schema_version = 2,
        .strict = false,
        .warm_text = false,
        .verify = true,
        .task_status_v1 = false,
    };

    try createOwnedDirectory(std.testing.io, staging_path);
    try writeStoreMigrationV2TransactionMarker(std.testing.allocator, std.testing.io, staging_path, expected, null);
    const partial_path = try std.fs.path.join(std.testing.allocator, &.{ staging_path, "partial" });
    defer std.testing.allocator.free(partial_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = partial_path, .data = "partial", .flags = .{ .truncate = true } });

    const result = try migrateStoreV2(std.testing.allocator, std.testing.io, .{
        .source_path = source_path,
        .target_path = target_path,
    });
    try std.testing.expectEqual(@as(u64, 1), result.nodes_written);
    try std.testing.expect(!result.marker_cleanup_pending);
    try std.testing.expect(!try fileExists(std.testing.io, partial_path));
    try std.testing.expect(!try anyPathExists(std.testing.io, staging_path));
    const published_marker_path = try storeMigrationV2TransactionMarkerPath(std.testing.allocator, target_path);
    defer std.testing.allocator.free(published_marker_path);
    try std.testing.expect(try anyPathExists(std.testing.io, published_marker_path));
}

test "migrate-store-v2 never deletes unmarked staging or foreign final target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "source.kg" });
    defer std.testing.allocator.free(source_path);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "target.kg" });
    defer std.testing.allocator.free(target_path);
    const staging_path = try storeMigrationV2StagingPath(std.testing.allocator, target_path);
    defer std.testing.allocator.free(staging_path);
    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, source_path);
        defer store.deinit();
        try store.createEmpty();
        try store.appendNode(.{ .id = .fromInt(1), .kind = .concept, .text = "foreign state source" });
    }

    try createOwnedDirectory(std.testing.io, staging_path);
    const staging_sentinel = try std.fs.path.join(std.testing.allocator, &.{ staging_path, "foreign" });
    defer std.testing.allocator.free(staging_sentinel);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = staging_sentinel, .data = "foreign staging", .flags = .{ .truncate = true } });
    try std.testing.expectError(error.MigrationRecoveryConflict, migrateStoreV2(std.testing.allocator, std.testing.io, .{
        .source_path = source_path,
        .target_path = target_path,
    }));
    try std.testing.expect(try fileExists(std.testing.io, staging_sentinel));
    try std.Io.Dir.cwd().deleteTree(std.testing.io, staging_path);

    try createOwnedDirectory(std.testing.io, target_path);
    const final_sentinel = try std.fs.path.join(std.testing.allocator, &.{ target_path, "foreign" });
    defer std.testing.allocator.free(final_sentinel);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = final_sentinel, .data = "foreign final", .flags = .{ .truncate = true } });
    try std.testing.expectError(error.AlreadyExists, migrateStoreV2(std.testing.allocator, std.testing.io, .{
        .source_path = source_path,
        .target_path = target_path,
    }));
    try std.testing.expect(try fileExists(std.testing.io, final_sentinel));
}

test "migrate-store-v2 acknowledges a published request-matched target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "source.kg" });
    defer std.testing.allocator.free(source_path);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "target.kg" });
    defer std.testing.allocator.free(target_path);
    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, source_path);
        defer store.deinit();
        try store.createEmpty();
        try store.appendNode(.{ .id = .fromInt(1), .kind = .concept, .text = "published migration source" });
    }
    const source_metadata_path = try std.fs.path.join(std.testing.allocator, &.{ source_path, "source-metadata" });
    defer std.testing.allocator.free(source_metadata_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = source_metadata_path,
        .data = "alpha",
        .flags = .{ .truncate = true },
    });

    const first = try migrateStoreV2(std.testing.allocator, std.testing.io, .{
        .source_path = source_path,
        .target_path = target_path,
        .warm_text = true,
    });
    try std.testing.expect(!first.marker_cleanup_pending);

    const marker_path = try storeMigrationV2TransactionMarkerPath(std.testing.allocator, target_path);
    defer std.testing.allocator.free(marker_path);
    const marker_tmp_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.tmp", .{marker_path});
    defer std.testing.allocator.free(marker_tmp_path);
    try std.testing.expect(try anyPathExists(std.testing.io, marker_path));

    var source = try storage.Store.open(std.testing.allocator, std.testing.io, source_path);
    defer source.deinit();
    var target_catalog = try migrationCatalog(std.testing.allocator, source, "agent-dag,markdown-document", false, false);
    defer target_catalog.deinit();
    const target_profiles = try catalogProfilesCsvAlloc(std.testing.allocator, target_catalog);
    defer std.testing.allocator.free(target_profiles);
    const canonical_source = try canonicalProspectivePath(std.testing.allocator, std.testing.io, source_path);
    defer std.testing.allocator.free(canonical_source);
    const source_identity = try storeContentIdentity(std.testing.allocator, std.testing.io, source_path);
    const expected = StoreMigrationV2TransactionExpectation{
        .canonical_source_path = canonical_source,
        .canonical_backup_path = "",
        .source_store_bytes = source_identity.bytes,
        .source_store_digest = source_identity.digest,
        .target_profiles = target_profiles,
        .target_catalog_revision = target_catalog.revision,
        .target_schema_version = 2,
        .strict = false,
        .warm_text = true,
        .verify = true,
        .task_status_v1 = false,
    };
    const current_marker = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, marker_path, std.testing.allocator, .limited(32 * 1024));
    defer std.testing.allocator.free(current_marker);
    // Simulate death after writing the current-format upgrade temp but before
    // replacing the still-valid legacy receipt. The exact temp must be
    // promoted by the retry instead of permanently wedging this publication.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = marker_tmp_path,
        .data = current_marker,
        .flags = .{ .truncate = true },
    });
    try rewriteTransactionMarkerFormatForTest(
        std.testing.io,
        marker_path,
        store_migration_transaction_marker_format,
        store_migration_transaction_marker_legacy_format,
    );

    // The same path/options are not the same migration request after a
    // same-size source mutation.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = source_metadata_path,
        .data = "bravo",
        .flags = .{ .truncate = true },
    });
    try std.testing.expectError(error.MigrationRecoveryConflict, migrateStoreV2(std.testing.allocator, std.testing.io, .{
        .source_path = source_path,
        .target_path = target_path,
        .warm_text = true,
    }));
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = source_metadata_path,
        .data = "alpha",
        .flags = .{ .truncate = true },
    });

    const legacy_recovered = try migrateStoreV2(std.testing.allocator, std.testing.io, .{
        .source_path = source_path,
        .target_path = target_path,
        .warm_text = true,
    });
    try std.testing.expectEqual(first.nodes_written, legacy_recovered.nodes_written);
    try std.testing.expect(!try anyPathExists(std.testing.io, marker_tmp_path));
    try std.testing.expect(try transactionMarkerHasFormatForTest(std.testing.io, marker_path, store_migration_transaction_marker_format));

    // Byte equality is the ownership proof for an interrupted fixed-name
    // temp. A different temp must survive for diagnosis and block the legacy
    // upgrade rather than being overwritten or silently discarded.
    try rewriteTransactionMarkerFormatForTest(
        std.testing.io,
        marker_path,
        store_migration_transaction_marker_format,
        store_migration_transaction_marker_legacy_format,
    );
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = marker_tmp_path,
        .data = "foreign marker temp",
        .flags = .{ .truncate = true },
    });
    try std.testing.expectError(error.MigrationRecoveryConflict, migrateStoreV2(std.testing.allocator, std.testing.io, .{
        .source_path = source_path,
        .target_path = target_path,
        .warm_text = true,
    }));
    const preserved_tmp = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, marker_tmp_path, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(preserved_tmp);
    try std.testing.expectEqualStrings("foreign marker temp", preserved_tmp);
    try std.testing.expect(try transactionMarkerHasFormatForTest(std.testing.io, marker_path, store_migration_transaction_marker_legacy_format));
    try std.Io.Dir.cwd().deleteFile(std.testing.io, marker_tmp_path);
    _ = try migrateStoreV2(std.testing.allocator, std.testing.io, .{
        .source_path = source_path,
        .target_path = target_path,
        .warm_text = true,
    });

    // Bind a complete target containing an auxiliary file, then prove an
    // equal-length target mutation cannot pass counts/catalog/manifest checks.
    const target_metadata_path = try std.fs.path.join(std.testing.allocator, &.{ target_path, "target-metadata" });
    defer std.testing.allocator.free(target_metadata_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = target_metadata_path,
        .data = "alpha",
        .flags = .{ .truncate = true },
    });
    var committed = first;
    const committed_identity = try storeContentIdentity(std.testing.allocator, std.testing.io, target_path);
    committed.published_store_bytes = committed_identity.bytes;
    committed.published_store_digest = committed_identity.digest;
    try writeStoreMigrationV2TransactionMarker(std.testing.allocator, std.testing.io, target_path, expected, committed);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = target_metadata_path,
        .data = "bravo",
        .flags = .{ .truncate = true },
    });
    try std.testing.expectError(error.MigrationRecoveryConflict, migrateStoreV2(std.testing.allocator, std.testing.io, .{
        .source_path = source_path,
        .target_path = target_path,
        .warm_text = true,
    }));
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = target_metadata_path,
        .data = "alpha",
        .flags = .{ .truncate = true },
    });

    const recovered = try migrateStoreV2(std.testing.allocator, std.testing.io, .{
        .source_path = source_path,
        .target_path = target_path,
        .warm_text = true,
    });
    try std.testing.expectEqual(committed.nodes_written, recovered.nodes_written);
    try std.testing.expectEqual(committed.edges_written, recovered.edges_written);
    try std.testing.expect(!recovered.marker_cleanup_pending);
    try std.testing.expect(try anyPathExists(std.testing.io, marker_path));
    try std.testing.expect(try transactionMarkerHasFormatForTest(std.testing.io, marker_path, store_migration_transaction_marker_format));
}

fn writeUpgradeManifestFixture(io: std.Io, db_path: []const u8, document: []const u8) !void {
    const path = try storeManifestPath(std.testing.allocator, db_path);
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = document,
        .flags = .{ .truncate = true },
    });
}

test "upgrade current store is a read-only no-op and does not publish target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "current.kg" });
    defer std.testing.allocator.free(source_path);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "unused-target.kg" });
    defer std.testing.allocator.free(target_path);

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", source_path }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-node", source_path, "task", "current task" }, &out, std.testing.allocator, std.testing.io);
    const before = try storeContentIdentity(std.testing.allocator, std.testing.io, source_path);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "upgrade", source_path, target_path }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "result=current action=noop") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "detected_manifest=1 detected_storage=2 detected_schema=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "catalog=present detected_catalog=2") != null);
    try std.testing.expect(!try anyPathExists(std.testing.io, target_path));
    const after = try storeContentIdentity(std.testing.allocator, std.testing.io, source_path);
    try std.testing.expectEqual(before.bytes, after.bytes);
    try std.testing.expect(std.meta.eql(before.digest, after.digest));
}

test "upgrade legacy store preserves ids catalog properties sidecar and source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "legacy.kg" });
    defer std.testing.allocator.free(source_path);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "upgraded.kg" });
    defer std.testing.allocator.free(target_path);
    const backup_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "legacy-backup.kg" });
    defer std.testing.allocator.free(backup_path);

    {
        var source = try storage.Store.init(std.testing.allocator, std.testing.io, source_path);
        defer source.deinit();
        try source.createEmpty();

        var registry = schema.Registry.init(std.testing.allocator);
        try registry.addKernelTypes();
        try addBuiltinProfilesFromCsvForSchemaVersion(&registry, "agent-dag", 2);
        try registry.addNodeType("ticket", 100, &.{schema.kernel_node_type_id});
        try registry.setNodeProperty(100, .{ .name = "priority", .value_type = .string, .indexed = true });
        var catalog = try catalog_mod.Catalog.fromRegistry(std.testing.allocator, registry);
        defer catalog.deinit();
        catalog.revision = 7;
        try appendCatalogProfileLabel(std.testing.allocator, &catalog, "custom-v1");
        try source.writeCatalog(catalog);

        try source.appendNodesBatch(&.{
            .{ .id = .fromInt(1), .kind = @enumFromInt(@as(u16, 100)), .text = "stable ticket" },
            .{ .id = .fromInt(2), .kind = .evidence, .text = "stable evidence" },
        });
        try source.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .rel = .related_to, .dst = .fromInt(2) });
        try source.setNodeStringProperty(std.testing.allocator, .fromInt(1), "priority", "high");
        _ = try writeMetaknowDeferredBasedOnForwardPairsSidecar(
            std.testing.allocator,
            source,
            &.{.{ .src = 1, .dst = 2 }},
            2,
        );
    }
    const source_before = try storeContentIdentity(std.testing.allocator, std.testing.io, source_path);

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "upgrade", source_path, target_path, "--backup", backup_path }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "result=upgraded action=migrate-store-v2+task-status-v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "manifest=legacy detected_manifest=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "verified=1 nodes_scanned=2 nodes_written=2 edges_scanned=1 edges_written=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_warmed=0") != null);
    try std.testing.expect(try anyPathExists(std.testing.io, backup_path));

    const source_after = try storeContentIdentity(std.testing.allocator, std.testing.io, source_path);
    try std.testing.expectEqual(source_before.bytes, source_after.bytes);
    try std.testing.expect(std.meta.eql(source_before.digest, source_after.digest));

    var upgraded = try storage.Store.open(std.testing.allocator, std.testing.io, target_path);
    defer upgraded.deinit();
    const stats_out = try upgraded.stats();
    try std.testing.expectEqual(@as(u64, 2), stats_out.nodes);
    try std.testing.expectEqual(@as(u64, 1), stats_out.edges);
    var ticket = (try upgraded.readNodeById(std.testing.allocator, .fromInt(1))).?;
    defer ticket.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 100), @intFromEnum(ticket.kind));
    try std.testing.expectEqualStrings("stable ticket", ticket.text);
    const priority = (try upgraded.getNodeStringProperty(std.testing.allocator, .fromInt(1), "priority")).?;
    defer std.testing.allocator.free(priority);
    try std.testing.expectEqualStrings("high", priority);
    var upgraded_catalog = (try upgraded.readCatalog()).?;
    defer upgraded_catalog.deinit();
    try std.testing.expectEqualStrings("ticket", upgraded_catalog.registry.nodeTypeNameById(100).?);
    try std.testing.expect(upgraded_catalog.registry.nodePropertyByTypeId(100, "priority") != null);

    const deferred_path = try metaknowDeferredBasedOnPath(std.testing.allocator, upgraded);
    defer std.testing.allocator.free(deferred_path);
    var deferred_targets = try query.readMetaknowDeferredBasedOnTargets(
        std.testing.allocator,
        std.testing.io,
        deferred_path,
        .fromInt(1),
        4,
        .forward,
    );
    defer deferred_targets.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u64, &.{2}, deferred_targets.targets);

    const manifest = try readStoreManifestSummary(std.testing.allocator, std.testing.io, target_path);
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("1", manifest.store_manifest_version);
    try std.testing.expectEqualStrings("2", manifest.storage_format_version);
    try std.testing.expectEqualStrings("3", manifest.schema_version);
}

test "upgrade schema v2 manifest selects task lifecycle migration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema-v2.kg" });
    defer std.testing.allocator.free(source_path);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema-v3.kg" });
    defer std.testing.allocator.free(target_path);

    {
        var source = try storage.Store.init(std.testing.allocator, std.testing.io, source_path);
        defer source.deinit();
        try source.createEmpty();
        var registry = schema.Registry.init(std.testing.allocator);
        try registry.addKernelTypes();
        try addBuiltinProfilesFromCsvForSchemaVersion(&registry, "agent-dag", 2);
        var catalog = try catalog_mod.Catalog.fromRegistry(std.testing.allocator, registry);
        defer catalog.deinit();
        try appendCatalogProfileLabel(std.testing.allocator, &catalog, "agent-dag");
        try source.writeCatalog(catalog);
        try source.appendNode(.{ .id = .fromInt(9), .kind = .task, .text = "schema two task" });
        try writeStoreManifest(std.testing.allocator, std.testing.io, source_path, .{
            .profiles = "agent-dag",
            .migration_name = "fixture",
            .schema_version = 2,
        });
    }

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "upgrade", source_path, target_path, "--warm-text" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "detected_manifest=1 detected_storage=2 detected_schema=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "target_schema=3 verified=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_warmed=1") != null);

    var upgraded = try storage.Store.open(std.testing.allocator, std.testing.io, target_path);
    defer upgraded.deinit();
    var task_node = (try upgraded.readNodeById(std.testing.allocator, .fromInt(9))).?;
    defer task_node.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("schema two task", task_node.text);
    try std.testing.expectEqual(task.Status.open, try task.statusForStoredNode(
        std.testing.allocator,
        upgraded,
        task_node,
        try u128ToU64(persistentNowNs(std.testing.io)),
    ));
    const manifest = try readStoreManifestSummary(std.testing.allocator, std.testing.io, target_path);
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("3", manifest.schema_version);
}

test "upgrade rejects future malformed and incomplete current stores before target mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "source.kg" });
    defer std.testing.allocator.free(source_path);
    const corrupt_catalog_source = try std.fs.path.join(std.testing.allocator, &.{ root_path, "corrupt-catalog.kg" });
    defer std.testing.allocator.free(corrupt_catalog_source);

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", source_path }, &out, std.testing.allocator, std.testing.io);

    const cases = [_]struct {
        name: []const u8,
        manifest: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "future-manifest-target.kg",
            .manifest = "{\"store_manifest_version\":2,\"storage_format_version\":2,\"schema\":{\"schema_version\":3}}",
            .expected = error.NewerStoreManifest,
        },
        .{
            .name = "future-storage-target.kg",
            .manifest = "{\"store_manifest_version\":1,\"storage_format_version\":3,\"schema\":{\"schema_version\":3}}",
            .expected = error.NewerStorageFormat,
        },
        .{
            .name = "future-schema-target.kg",
            .manifest = "{\"store_manifest_version\":1,\"storage_format_version\":2,\"schema\":{\"schema_version\":4}}",
            .expected = error.NewerSchemaVersion,
        },
        .{
            .name = "missing-storage-target.kg",
            .manifest = "{\"store_manifest_version\":1,\"schema\":{\"schema_version\":3}}",
            .expected = error.InvalidStoreManifest,
        },
        .{
            .name = "catalog-schema-mismatch-target.kg",
            .manifest = "{\"store_manifest_version\":1,\"storage_format_version\":2,\"schema\":{\"schema_version\":3,\"enabled_profiles\":[\"agent-dag\"]}}",
            .expected = error.CatalogSchemaMismatch,
        },
    };
    for (cases) |case| {
        try writeUpgradeManifestFixture(std.testing.io, source_path, case.manifest);
        const target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, case.name });
        defer std.testing.allocator.free(target_path);
        out.buffer.clearRetainingCapacity();
        try std.testing.expectError(case.expected, run(
            &.{ "tinykg", "upgrade", source_path, target_path },
            &out,
            std.testing.allocator,
            std.testing.io,
        ));
        try std.testing.expectEqual(@as(usize, 0), out.buffer.items.len);
        try std.testing.expect(!try anyPathExists(std.testing.io, target_path));
    }

    try writeStoreManifest(std.testing.allocator, std.testing.io, source_path, .{ .migration_name = "restore-valid" });
    const catalog_path = try std.fs.path.join(std.testing.allocator, &.{ source_path, "catalog.bin" });
    defer std.testing.allocator.free(catalog_path);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, catalog_path);
    const missing_catalog_target = try std.fs.path.join(std.testing.allocator, &.{ root_path, "missing-catalog-target.kg" });
    defer std.testing.allocator.free(missing_catalog_target);
    try std.testing.expectError(error.MissingStoreCatalog, run(
        &.{ "tinykg", "upgrade", source_path, missing_catalog_target },
        &out,
        std.testing.allocator,
        std.testing.io,
    ));
    try std.testing.expect(!try anyPathExists(std.testing.io, missing_catalog_target));

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "init", corrupt_catalog_source }, &out, std.testing.allocator, std.testing.io);
    const corrupt_catalog_path = try std.fs.path.join(std.testing.allocator, &.{ corrupt_catalog_source, "catalog.bin" });
    defer std.testing.allocator.free(corrupt_catalog_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = corrupt_catalog_path,
        .data = "not-a-catalog",
        .flags = .{ .truncate = true },
    });
    const corrupt_catalog_target = try std.fs.path.join(std.testing.allocator, &.{ root_path, "corrupt-catalog-target.kg" });
    defer std.testing.allocator.free(corrupt_catalog_target);
    out.buffer.clearRetainingCapacity();
    try std.testing.expectError(error.InvalidRecord, run(
        &.{ "tinykg", "upgrade", corrupt_catalog_source, corrupt_catalog_target },
        &out,
        std.testing.allocator,
        std.testing.io,
    ));
    try std.testing.expect(!try anyPathExists(std.testing.io, corrupt_catalog_target));
}

test "upgrade dry run verifies migration and removes publication scratch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "legacy.kg" });
    defer std.testing.allocator.free(source_path);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "dry-target.kg" });
    defer std.testing.allocator.free(target_path);
    {
        var source = try storage.Store.init(std.testing.allocator, std.testing.io, source_path);
        defer source.deinit();
        try source.createEmpty();
        try source.appendNode(.{ .id = .fromInt(1), .kind = .concept, .text = "dry-run source" });
    }
    const before = try storeContentIdentity(std.testing.allocator, std.testing.io, source_path);

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "upgrade", source_path, target_path, "--dry-run" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "result=dry-run") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "verified=1 nodes_scanned=1 nodes_written=1") != null);
    try std.testing.expect(!try anyPathExists(std.testing.io, target_path));
    const staging_path = try storeMigrationV2StagingPath(std.testing.allocator, target_path);
    defer std.testing.allocator.free(staging_path);
    try std.testing.expect(!try anyPathExists(std.testing.io, staging_path));
    const after = try storeContentIdentity(std.testing.allocator, std.testing.io, source_path);
    try std.testing.expectEqual(before.bytes, after.bytes);
    try std.testing.expect(std.meta.eql(before.digest, after.digest));
}

test "migrate-store-v2 physically repairs legacy props text into new store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const old_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "old.kg" });
    defer std.testing.allocator.free(old_path);
    const new_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "new.kg" });
    defer std.testing.allocator.free(new_path);
    const backup_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "backup.kg" });
    defer std.testing.allocator.free(backup_path);

    var old_store = try storage.Store.init(std.testing.allocator, std.testing.io, old_path);
    defer old_store.deinit();
    try old_store.createEmpty();
    try old_store.appendNode(.{
        .id = .fromInt(1),
        .kind = .task,
        .text = "legacy task props_text=\"{\"domain_id\":\"tinykg\",\"schema_type\":\"task\",\"summary\":\"legacy summary\",\"task_recorded_ns\":1700000000000000000}\"",
    });
    try old_store.appendNode(.{ .id = .fromInt(2), .kind = .evidence, .text = "visible evidence" });
    try old_store.appendNode(.{ .id = .fromInt(3), .kind = .observation, .text = " props_text=\"{\"summary\":\"empty visible\"}\"" });
    try old_store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .rel = .evidences, .dst = .fromInt(2) });
    try old_store.setStringProperty(std.testing.allocator, .{ .edge = .fromInt(1) }, "created_by", "legacy-agent");
    _ = try writeMetaknowDeferredBasedOnForwardPairsSidecar(
        std.testing.allocator,
        old_store,
        &.{.{ .src = 2, .dst = 1 }},
        3,
    );

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{
        "tinykg",
        "migrate-store-v2",
        old_path,
        new_path,
        "--backup",
        backup_path,
        "--warm-text",
        "--verify",
    }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "verified=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "nodes_written=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edges_written=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "legacy_props_extracted=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "legacy_text_repaired=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "empty_text_physical_placeholders=0") != null);

    var migrated = try storage.Store.open(std.testing.allocator, std.testing.io, new_path);
    defer migrated.deinit();
    var migrated_node = (try migrated.readNodeById(std.testing.allocator, .fromInt(1))).?;
    defer migrated_node.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("legacy task", migrated_node.text);
    const summary = (try migrated.getStringProperty(std.testing.allocator, .{ .node = .fromInt(1) }, "summary")).?;
    defer std.testing.allocator.free(summary);
    try std.testing.expectEqualStrings("legacy summary", summary);
    try std.testing.expectEqual(@as(?u64, 1700000000000000000), try migrated.getUintProperty(std.testing.allocator, .{ .node = .fromInt(1) }, "task_recorded_ns"));
    const edge_created_by = (try migrated.getStringProperty(std.testing.allocator, .{ .edge = .fromInt(1) }, "created_by")).?;
    defer std.testing.allocator.free(edge_created_by);
    try std.testing.expectEqualStrings("legacy-agent", edge_created_by);
    var empty_visible_node = (try migrated.readNodeById(std.testing.allocator, .fromInt(3))).?;
    defer empty_visible_node.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", empty_visible_node.text);
    try std.testing.expect(std.mem.indexOf(u8, empty_visible_node.text, "props_text") == null);
    const migrated_deferred_path = try metaknowDeferredBasedOnPath(std.testing.allocator, migrated);
    defer std.testing.allocator.free(migrated_deferred_path);
    var migrated_deferred = try query.readMetaknowDeferredBasedOnTargets(
        std.testing.allocator,
        std.testing.io,
        migrated_deferred_path,
        .fromInt(2),
        4,
        .forward,
    );
    defer migrated_deferred.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u64, &.{1}, migrated_deferred.targets);

    const manifest_path = try storeManifestPath(std.testing.allocator, new_path);
    defer std.testing.allocator.free(manifest_path);
    const manifest = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, manifest_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"storage_format_version\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"schema_version\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"agent-dag\"") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", new_path, "MATCH (n:task) WHERE n.status = \"open\" RETURN n.text LIMIT 4" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("legacy task\n", out.buffer.items);
}

test "migrate-store-v2 task status migration preserves ids and only converts high confidence legacy tasks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const old_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "old-status.kg" });
    defer std.testing.allocator.free(old_path);
    const new_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "new-status.kg" });
    defer std.testing.allocator.free(new_path);
    const second_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "second-status.kg" });
    defer std.testing.allocator.free(second_path);

    {
        var old_store = try storage.Store.init(std.testing.allocator, std.testing.io, old_path);
        defer old_store.deinit();
        try old_store.createEmpty();
        try old_store.appendNodesBatch(&.{
            .{ .id = .fromInt(1), .kind = .task, .text = "legacy open task" },
            .{ .id = .fromInt(2), .kind = .verification, .text = "legacy completed verification task" },
            .{ .id = .fromInt(3), .kind = .fix, .text = "legacy completed fix task" },
            .{ .id = .fromInt(4), .kind = .verification, .text = "ordinary verification evidence" },
            .{ .id = .fromInt(5), .kind = .fix, .text = "legacy task with custom semantic type" },
            .{ .id = .fromInt(6), .kind = .verification, .text = "invalid legacy task holder" },
            .{ .id = .fromInt(7), .kind = .fix, .text = "invalid legacy task audit timestamp" },
            .{
                .id = .fromInt(8),
                .kind = .verification,
                .text = "legacy closed task in text props_text=\"{\"schema_type\":\"verification\",\"task_created_ns\":1700000000000000000,\"task_completed_ns\":1700000001000000000}\"",
            },
            .{
                .id = .fromInt(9),
                .kind = .task,
                .text = "legacy open task in text props_text=\"{\"schema_type\":\"task\",\"status\":\"open\",\"task_created_ns\":1700000000000000000}\"",
            },
        });
        try old_store.appendEdgesBatch(&.{
            .{ .id = .fromInt(7), .src = .fromInt(1), .rel = .contains, .dst = .fromInt(2) },
            .{ .id = .fromInt(9), .src = .fromInt(1), .rel = .verified_by, .dst = .fromInt(4) },
        });
        inline for (&.{ core.NodeId.fromInt(2), core.NodeId.fromInt(3), core.NodeId.fromInt(5) }) |node_id| {
            try old_store.setUintProperty(std.testing.allocator, .{ .node = node_id }, "task_created_ns", 1_700_000_000_000_000_000);
            try old_store.setUintProperty(std.testing.allocator, .{ .node = node_id }, "task_completed_ns", 1_700_000_001_000_000_000);
        }
        inline for (&.{ core.NodeId.fromInt(6), core.NodeId.fromInt(7) }) |node_id| {
            try old_store.setUintProperty(std.testing.allocator, .{ .node = node_id }, "task_created_ns", 1_700_000_000_000_000_000);
            try old_store.setUintProperty(std.testing.allocator, .{ .node = node_id }, "task_completed_ns", 1_700_000_001_000_000_000);
        }
        const oversized_holder = [_]u8{'x'} ** (task.max_claim_holder_len + 1);
        try old_store.setNodeStringProperty(std.testing.allocator, .fromInt(6), task.claimed_by_property, &oversized_holder);
        try old_store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(7) }, "task_recorded_ns", 0);
        try old_store.setNodeStringProperty(std.testing.allocator, .fromInt(2), "schema_type", "verification");
        try old_store.setNodeStringProperty(std.testing.allocator, .fromInt(4), "schema_type", "verification");
        try old_store.setNodeStringProperty(std.testing.allocator, .fromInt(5), "schema_type", "custom_review_task");
        try old_store.setNodeStringProperty(std.testing.allocator, .fromInt(2), "name", "stable-id-two");
        // Crash leftovers must not survive as contradictory schema-v3 state:
        // node 1's expired claim reads open and its stale completion timestamp
        // is discarded; node 2 is terminal and its old lease is zeroed.
        try old_store.setNodeStringProperty(std.testing.allocator, .fromInt(1), task.status_property, "claimed");
        try old_store.setNodeStringProperty(std.testing.allocator, .fromInt(1), task.claimed_by_property, "expired-agent");
        try old_store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(1) }, task.claim_expires_ns_property, 1);
        try old_store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(1) }, "task_completed_ns", 42);
        try old_store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(2) }, task.claim_expires_ns_property, std.math.maxInt(u64));
    }

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "migrate-store-v2", old_path, new_path, "--task-status-v1", "--verify" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "verified=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_statuses_written=6") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "legacy_closed_tasks_converted=4") != null);
    // Lifecycle fields normalized by task-status-v1 have exactly one writer:
    // the generic property copy must not first append stale values and rely
    // on a later duplicate delta record to hide them.
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_properties_written=31 ") != null);

    var migrated = try storage.Store.open(std.testing.allocator, std.testing.io, new_path);
    defer migrated.deinit();
    inline for (&.{
        .{ core.NodeId.fromInt(1), task.Status.open },
        .{ core.NodeId.fromInt(2), task.Status.completed },
        .{ core.NodeId.fromInt(3), task.Status.completed },
        .{ core.NodeId.fromInt(5), task.Status.completed },
        .{ core.NodeId.fromInt(8), task.Status.completed },
        .{ core.NodeId.fromInt(9), task.Status.open },
    }) |expected| {
        var node = (try migrated.readNodeById(std.testing.allocator, expected[0])).?;
        defer node.deinit(std.testing.allocator);
        try std.testing.expectEqual(core.NodeKind.task, node.kind);
        try std.testing.expectEqual(expected[1], try task.statusForStoredNode(std.testing.allocator, migrated, node, try u128ToU64(persistentNowNs(std.testing.io))));
    }
    var evidence = (try migrated.readNodeById(std.testing.allocator, .fromInt(4))).?;
    defer evidence.deinit(std.testing.allocator);
    try std.testing.expectEqual(core.NodeKind.verification, evidence.kind);
    try std.testing.expect((try migrated.getNodeStringProperty(std.testing.allocator, .fromInt(4), task.status_property)) == null);
    inline for (&.{
        .{ core.NodeId.fromInt(6), core.NodeKind.verification },
        .{ core.NodeId.fromInt(7), core.NodeKind.fix },
    }) |expected| {
        var invalid_legacy = (try migrated.readNodeById(std.testing.allocator, expected[0])).?;
        defer invalid_legacy.deinit(std.testing.allocator);
        try std.testing.expectEqual(expected[1], invalid_legacy.kind);
        try std.testing.expect((try migrated.getNodeStringProperty(std.testing.allocator, expected[0], task.status_property)) == null);
    }
    const migrated_name = (try migrated.getNodeStringProperty(std.testing.allocator, .fromInt(2), "name")).?;
    defer std.testing.allocator.free(migrated_name);
    try std.testing.expectEqualStrings("stable-id-two", migrated_name);
    const migrated_schema = (try migrated.getNodeStringProperty(std.testing.allocator, .fromInt(2), "schema_type")).?;
    defer std.testing.allocator.free(migrated_schema);
    try std.testing.expectEqualStrings("task", migrated_schema);
    const migrated_missing_schema = (try migrated.getNodeStringProperty(std.testing.allocator, .fromInt(3), "schema_type")).?;
    defer std.testing.allocator.free(migrated_missing_schema);
    try std.testing.expectEqualStrings("task", migrated_missing_schema);
    const migrated_custom_schema = (try migrated.getNodeStringProperty(std.testing.allocator, .fromInt(5), "schema_type")).?;
    defer std.testing.allocator.free(migrated_custom_schema);
    try std.testing.expectEqualStrings("custom_review_task", migrated_custom_schema);
    try std.testing.expectEqual(@as(?u64, 0), try migrated.getUintProperty(std.testing.allocator, .{ .node = .fromInt(1) }, task.claim_expires_ns_property));
    try std.testing.expectEqual(@as(?u64, null), try migrated.getUintProperty(std.testing.allocator, .{ .node = .fromInt(1) }, "task_completed_ns"));
    try std.testing.expectEqual(@as(?u64, 0), try migrated.getUintProperty(std.testing.allocator, .{ .node = .fromInt(2) }, task.claim_expires_ns_property));
    const migrated_stats = try migrated.stats();
    try std.testing.expectEqual(@as(u64, 9), migrated_stats.nodes);
    try std.testing.expectEqual(@as(u64, 2), migrated_stats.edges);
    const status_manifest_path = try storeManifestPath(std.testing.allocator, new_path);
    defer std.testing.allocator.free(status_manifest_path);
    const status_manifest = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, status_manifest_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(status_manifest);
    try std.testing.expect(std.mem.indexOf(u8, status_manifest, "\"schema_version\": 3") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "task-packet", new_path, "2", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.startsWith(u8, out.buffer.items, "task_packet\t2\tstatus=completed\treadiness=-"));

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "migrate-store-v2", new_path, second_path, "--task-status-v1", "--verify" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_statuses_written=6") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "legacy_closed_tasks_converted=0") != null);
}

test "migrate-store-v2 preserves embedded custom catalog and catalog properties" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const old_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "custom-old.kg" });
    defer std.testing.allocator.free(old_path);
    const new_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "custom-new.kg" });
    defer std.testing.allocator.free(new_path);
    const second_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "custom-second.kg" });
    defer std.testing.allocator.free(second_path);

    {
        var old_store = try storage.Store.init(std.testing.allocator, std.testing.io, old_path);
        defer old_store.deinit();
        try old_store.createEmpty();
        var registry = schema.Registry.init(std.testing.allocator);
        try registry.addKernelTypes();
        try registry.addNodeType("ticket", 100, &.{schema.kernel_node_type_id});
        try registry.setNodeProperty(100, .{ .name = "priority", .value_type = .string, .indexed = true });
        try registry.setNodeProperty(100, .{
            .name = "status",
            .value_type = .@"enum",
            .enum_values = &.{ "draft", "published" },
            .indexed = true,
        });
        var cat = try catalog_mod.Catalog.fromRegistry(std.testing.allocator, registry);
        defer cat.deinit();
        cat.revision = 7;
        try cat.profiles.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "custom-v1"));
        try old_store.writeCatalog(cat);
        try old_store.appendNodesBatch(&.{
            .{ .id = .fromInt(1), .kind = @enumFromInt(@as(u16, 100)), .text = "custom ticket" },
            .{ .id = .fromInt(2), .kind = .task, .text = "legacy task beside custom data" },
        });
        try old_store.setNodeStringProperty(std.testing.allocator, .fromInt(1), "priority", "high");
        try old_store.setNodeStringProperty(std.testing.allocator, .fromInt(1), "status", "published");
    }

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try std.testing.expectError(error.Unsupported, run(&.{ "tinykg", "migrate-store-v2", old_path, new_path, "--task-status-v1", "--profile", "agent-dag" }, &out, std.testing.allocator, std.testing.io));
    try std.testing.expect(!try anyPathExists(std.testing.io, new_path));
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "migrate-store-v2", old_path, new_path, "--task-status-v1", "--verify" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "verified=1") != null);

    var migrated = try storage.Store.open(std.testing.allocator, std.testing.io, new_path);
    defer migrated.deinit();
    var migrated_catalog = (try migrated.readCatalog()).?;
    defer migrated_catalog.deinit();
    try std.testing.expectEqualStrings("ticket", migrated_catalog.registry.nodeTypeNameById(100).?);
    try std.testing.expect(migrated_catalog.registry.nodePropertyByTypeId(100, "priority") != null);
    const custom_status = migrated_catalog.registry.nodePropertyByTypeId(100, "status").?;
    try std.testing.expect(custom_status.enumAllows("published"));
    try std.testing.expect(migrated_catalog.registry.nodePropertyByTypeId(@intFromEnum(core.NodeKind.task), task.status_property) != null);
    try std.testing.expectEqual(@as(u32, 8), migrated_catalog.revision);

    const priority = (try migrated.getNodeStringProperty(std.testing.allocator, .fromInt(1), "priority")).?;
    defer std.testing.allocator.free(priority);
    try std.testing.expectEqualStrings("high", priority);
    const custom_status_value = (try migrated.getNodeStringProperty(std.testing.allocator, .fromInt(1), "status")).?;
    defer std.testing.allocator.free(custom_status_value);
    try std.testing.expectEqualStrings("published", custom_status_value);
    try std.testing.expectEqual(task.Status.open, try task.statusWithPersistentStoreAt(std.testing.allocator, migrated, .fromInt(2), 0));

    // `status` is virtual only for physical task nodes.  A custom catalog
    // property with the same name must remain queryable and projectable after
    // task-status-v1 adds the task lifecycle vocabulary to the same store.
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", new_path, "MATCH (n:ticket) WHERE n.status = \"published\" RETURN n.status LIMIT 2" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("published\n", out.buffer.items);

    const manifest_path = try storeManifestPath(std.testing.allocator, new_path);
    defer std.testing.allocator.free(manifest_path);
    const manifest = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, manifest_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"custom-v1\"") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "migrate-store-v2", new_path, second_path, "--task-status-v1", "--verify" }, &out, std.testing.allocator, std.testing.io);
    var migrated_again = try storage.Store.open(std.testing.allocator, std.testing.io, second_path);
    defer migrated_again.deinit();
    var second_catalog = (try migrated_again.readCatalog()).?;
    defer second_catalog.deinit();
    try std.testing.expectEqual(@as(u32, 8), second_catalog.revision);

    out.buffer.clearRetainingCapacity();
    try std.testing.expectError(
        error.TooManyArguments,
        run(&.{
            "tinykg",
            "migrate-store-v2",
            old_path,
            new_path,
            "--profile",
            "agent-dag",
            "--profile",
            "markdown-document",
        }, &out, std.testing.allocator, std.testing.io),
    );
}

test "migrate-store-v2 preserves visible edges from published segments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const old_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "old.kg" });
    defer std.testing.allocator.free(old_path);
    const new_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "new.kg" });
    defer std.testing.allocator.free(new_path);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "edge-segments-compacted" });
    defer std.testing.allocator.free(segment_path);

    var old_store = try storage.Store.init(std.testing.allocator, std.testing.io, old_path);
    defer old_store.deinit();
    try old_store.createEmpty();
    try old_store.appendNode(.{ .id = .fromInt(1), .kind = .document, .text = "doc" });
    try old_store.appendNode(.{ .id = .fromInt(2), .kind = .document_section, .text = "base" });
    try old_store.appendNode(.{ .id = .fromInt(3), .kind = .document_section, .text = "delta-a" });
    try old_store.appendNode(.{ .id = .fromInt(4), .kind = .document_section, .text = "delta-b" });

    var base_edges = std.ArrayList(graph.Edge).empty;
    defer base_edges.deinit(std.testing.allocator);
    try base_edges.ensureTotalCapacity(std.testing.allocator, 1024);
    var edge_id: u64 = 1;
    while (edge_id <= 1024) : (edge_id += 1) {
        base_edges.appendAssumeCapacity(.{
            .id = .fromInt(edge_id),
            .src = .fromInt(1),
            .rel = .contains,
            .dst = .fromInt(2),
        });
    }
    try old_store.appendEdgesBatch(base_edges.items);
    try old_store.appendEdgesBatch(&.{
        .{ .id = .fromInt(1025), .src = .fromInt(1), .rel = .contains, .dst = .fromInt(3) },
        .{ .id = .fromInt(1026), .src = .fromInt(1), .rel = .contains, .dst = .fromInt(4) },
    });
    try std.testing.expectEqual(@as(u64, 1026), try old_store.compactPublishedEdgeSegments(segment_path));

    var indexed_only = try old_store.readEdgeIndexRecordsByNode(std.testing.allocator, .src, .fromInt(1));
    defer indexed_only.deinit(std.testing.allocator);
    try std.testing.expect(indexed_only.items.len < 1026);

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{
        "tinykg",
        "migrate-store-v2",
        old_path,
        new_path,
        "--verify",
    }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "verified=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edges_written=1026") != null);

    var migrated = try storage.Store.open(std.testing.allocator, std.testing.io, new_path);
    defer migrated.deinit();
    const stats_out = try migrated.stats();
    try std.testing.expectEqual(@as(u64, 1026), stats_out.edges);
    var migrated_edges = try migrated.readEdgeIndexRecordsByNode(std.testing.allocator, .src, .fromInt(1));
    defer migrated_edges.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1026), migrated_edges.items.len);
}

test "migrate-store-v2 crosses bounded entity batches and cleans dry-run scratch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const old_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "bounded-old.kg" });
    defer std.testing.allocator.free(old_path);
    const new_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "bounded-new.kg" });
    defer std.testing.allocator.free(new_path);

    const node_count = store_migration_node_batch_limit + 1;
    const edge_count = store_migration_edge_batch_limit + 1;
    {
        var source = try storage.Store.init(std.testing.allocator, std.testing.io, old_path);
        defer source.deinit();
        try source.createEmpty();
        const nodes = try std.testing.allocator.alloc(graph.Node, node_count);
        defer std.testing.allocator.free(nodes);
        for (nodes, 0..) |*node, index| node.* = .{
            .id = .fromInt(index + 1),
            .kind = .project,
            .text = "bounded store migration node",
        };
        try source.appendNodesBatch(nodes);

        const edges = try std.testing.allocator.alloc(graph.Edge, edge_count);
        defer std.testing.allocator.free(edges);
        for (edges, 0..) |*edge, index| edge.* = .{
            .id = .fromInt(index + 1),
            .src = .fromInt(1),
            .rel = .contains,
            .dst = .fromInt(2 + index % (node_count - 1)),
        };
        try source.appendEdgesBatch(edges);
        try source.setNodeStringProperty(std.testing.allocator, .fromInt(node_count), "summary", "tail node property");
        try source.setEdgeStringProperty(std.testing.allocator, .fromInt(edge_count), "created_by", "tail edge property");
    }

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "migrate-store-v2", old_path, new_path, "--dry-run" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "dry_run=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "nodes_written=4097") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edges_written=8193") != null);
    try std.testing.expect(!try anyPathExists(std.testing.io, new_path));
    const staging_path = try storeMigrationV2StagingPath(std.testing.allocator, new_path);
    defer std.testing.allocator.free(staging_path);
    try std.testing.expect(!try anyPathExists(std.testing.io, staging_path));

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "migrate-store-v2", old_path, new_path, "--verify" }, &out, std.testing.allocator, std.testing.io);
    var migrated = try storage.Store.open(std.testing.allocator, std.testing.io, new_path);
    defer migrated.deinit();
    const stats = try migrated.stats();
    try std.testing.expectEqual(@as(u64, node_count), stats.nodes);
    try std.testing.expectEqual(@as(u64, edge_count), stats.edges);
    const node_summary = (try migrated.getNodeStringProperty(std.testing.allocator, .fromInt(node_count), "summary")).?;
    defer std.testing.allocator.free(node_summary);
    try std.testing.expectEqualStrings("tail node property", node_summary);
    const edge_creator = (try migrated.getEdgeStringProperty(std.testing.allocator, .fromInt(edge_count), "created_by")).?;
    defer std.testing.allocator.free(edge_creator);
    try std.testing.expectEqualStrings("tail edge property", edge_creator);
}

test "set-property writes node and edge overlay sidecars without rewriting edge records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);

    try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-node", db_path, "document", "doc" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-node", db_path, "observation", "chunk" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-edge", db_path, "1", "mentions", "2" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge 1") != null);

    var store_before = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
    const before_stats = try store_before.stats();
    store_before.deinit();

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "set-property", db_path, "node", "2", "summary", "generic node summary" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "property owner=node id=2 key=summary") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "set-property", db_path, "edge", "1", "source-span", "12:3-12:19" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "property owner=edge id=1 key=source_span") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "set-uint-property", db_path, "node", "2", "generation", "7" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "uint_property owner=node id=2 key=generation value=7") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "set-uint-property", db_path, "edge", "1", "order-key", "2048" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "uint_property owner=edge id=1 key=order_key value=2048") != null);

    var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    const after_stats = try store.stats();
    try std.testing.expectEqual(before_stats.edges, after_stats.edges);
    const node_summary = (try store.getStringProperty(std.testing.allocator, .{ .node = .fromInt(2) }, "summary")).?;
    defer std.testing.allocator.free(node_summary);
    try std.testing.expectEqualStrings("generic node summary", node_summary);
    const source_span = (try store.getStringProperty(std.testing.allocator, .{ .edge = .fromInt(1) }, "source_span")).?;
    defer std.testing.allocator.free(source_span);
    try std.testing.expectEqualStrings("12:3-12:19", source_span);
    try std.testing.expectEqual(@as(?u64, 7), try store.getUintProperty(std.testing.allocator, .{ .node = .fromInt(2) }, "generation"));
    try std.testing.expectEqual(@as(?u64, 2048), try store.getUintProperty(std.testing.allocator, .{ .edge = .fromInt(1) }, "order_key"));

    out.buffer.clearRetainingCapacity();
    try std.testing.expectError(
        core.Error.InvalidId,
        run(&.{ "tinykg", "set-property", db_path, "edge", "99", "source-span", "missing" }, &out, std.testing.allocator, std.testing.io),
    );

    out.buffer.clearRetainingCapacity();
    try std.testing.expectError(
        error.InvalidRecord,
        run(&.{ "tinykg", "set-uint-property", db_path, "edge", "1", "line-start", "12" }, &out, std.testing.allocator, std.testing.io),
    );

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "set-edge-property", db_path, "1", "created-by", "legacy-compatible" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_property edge=1 key=created_by") != null);

    // 分类两态位 state:key 在 allowlist,value 只收 tentative|confirmed(禁连续置信度)。
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "set-edge-property", db_path, "1", "state", "tentative" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_property edge=1 key=state") != null);
    // 连续置信度(0.67)被拒:一个 bit + 可溯源留痕,不是编造的浮点。
    out.buffer.clearRetainingCapacity();
    try std.testing.expectError(
        error.InvalidRecord,
        run(&.{ "tinykg", "set-edge-property", db_path, "1", "state", "0.67" }, &out, std.testing.allocator, std.testing.io),
    );
}

test "generic uint setter cannot bypass task lifecycle timestamps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-node", db_path, "task", "state machine only" }, &out, std.testing.allocator, std.testing.io);

    inline for (.{ "task_recorded_ns", "task_created_ns", "task_completed_ns" }) |key| {
        out.buffer.clearRetainingCapacity();
        try std.testing.expectError(
            error.InvalidRecord,
            run(&.{ "tinykg", "set-uint-property", db_path, "node", "1", key, "42" }, &out, std.testing.allocator, std.testing.io),
        );
    }

    var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    var node = (try store.readNodeById(std.testing.allocator, .fromInt(1))).?;
    defer node.deinit(std.testing.allocator);
    try std.testing.expectEqual(task.Status.open, try task.statusForStoredNode(std.testing.allocator, store, node, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(?u64, null), try store.getUintProperty(std.testing.allocator, .{ .node = node.id }, "task_completed_ns"));
}

test "TinyQL filters expanded edges by governed edge property equality" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);

    try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-node", db_path, "document", "doc" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-node", db_path, "observation", "agent target" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-node", db_path, "observation", "human target" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-edge", db_path, "1", "references", "2" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-edge", db_path, "1", "references", "3" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "set-edge-property", db_path, "1", "created-by", "agent" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "set-edge-property", db_path, "2", "created-by", "human" }, &out, std.testing.allocator, std.testing.io);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", db_path, "MATCH (a:document)-[e:references]->(b:observation) WHERE e.created_by = \"agent\" RETURN b.text LIMIT 5" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "agent target") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "human target") == null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", db_path, "MATCH (a:document)-[e:references]->(b:observation) WHERE e.created_by = \"missing\" RETURN b.text LIMIT 5" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("", out.buffer.items);

    out.buffer.clearRetainingCapacity();
    try std.testing.expectError(
        error.UnsupportedPropertyPredicate,
        run(&.{ "tinykg", "query", db_path, "MATCH (a:document)-[e:references]->(b:observation) WHERE e.created_by >= \"agent\" RETURN b.text LIMIT 5" }, &out, std.testing.allocator, std.testing.io),
    );

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query-explain", db_path, "MATCH (a:document)-[e:references]->(b:observation) WHERE e.created_by = \"agent\" RETURN b.text LIMIT 5" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "expand(index=edge_by_src,dir=outgoing,from=a,edge=e,to=b,rel=references,hops=1..1,post_filter=edge_property,index=property_payload)") != null);
}

test "add-edge upserts domain fact edges when endpoints have external keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);

    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        try store.createEmpty();
        const src = try store.addNode(.concept, "claim");
        try store.setNodeStringProperty(std.testing.allocator, src, "external_key", "domain:claim:one");
        const dst = try store.addNode(.evidence, "source");
        try store.setNodeStringProperty(std.testing.allocator, dst, "external_key", "domain:evidence:one");
        try std.testing.expectEqual(@as(u64, 1), src.toInt());
        try std.testing.expectEqual(@as(u64, 2), dst.toInt());
    }

    var first_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer first_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-edge", db_path, "1", "references", "2" }, &first_out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("edge 1\n", first_out.buffer.items);

    var second_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer second_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-edge", db_path, "1", "references", "2" }, &second_out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("edge 1\n", second_out.buffer.items);

    {
        var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        const stats = try store.stats();
        try std.testing.expectEqual(@as(u64, 1), stats.edges);

        const fact_key = try storage.edgeFactExternalKeyAlloc(std.testing.allocator, "domain:claim:one", .references, "domain:evidence:one");
        defer std.testing.allocator.free(fact_key);
        try std.testing.expectEqual(core.EdgeId.fromInt(1), (try store.lookupEdgeByExternalKey(std.testing.allocator, fact_key)).?);
        std.Io.Dir.cwd().deleteFile(std.testing.io, store.edge_external_key_index_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    var repaired_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer repaired_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-edge", db_path, "1", "references", "2" }, &repaired_out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("edge 1\n", repaired_out.buffer.items);

    var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    const stats = try store.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.edges);
}

test "agent-write upserts domain fact and attaches markdown projection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const markdown_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "doc.md" });
    defer std.testing.allocator.free(markdown_path);

    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        try store.createEmpty();
        const src = try store.addNode(.concept, "claim");
        try store.setNodeStringProperty(std.testing.allocator, src, "external_key", "domain:claim:agent-write");
        const dst = try store.addNode(.evidence, "source");
        try store.setNodeStringProperty(std.testing.allocator, dst, "external_key", "domain:evidence:agent-write");
    }
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = markdown_path,
        .data =
        \\# Agent Doc
        \\
        ,
        .flags = .{ .truncate = true },
    });

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "import-md-doc", db_path, markdown_path }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "document=3") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "agent-write", db_path, "--src", "1", "--rel", "references", "--dst", "2", "--document", "3", "--text", "Agent visible fact." }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "fact_created=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "projection_root=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "projection_nodes_imported=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "projection_edge_created=1") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "agent-write", db_path, "--src", "1", "--rel", "references", "--dst", "2", "--document", "3", "--text", "Agent visible fact." }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "fact_created=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "projection_nodes_imported=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "projection_edge_created=0") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "render-md-doc", db_path, "3" }, &out, std.testing.allocator, std.testing.io);
    const first = std.mem.indexOf(u8, out.buffer.items, "Agent visible fact.") orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items[first + "Agent visible fact.".len ..], "Agent visible fact.") == null);

    var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    const stats = try store.stats();
    try std.testing.expectEqual(@as(u64, 3), stats.edges);
}

test "agent-write can attach to Agent Inbox fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);

    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        try store.createEmpty();
        const src = try store.addNode(.concept, "claim");
        try store.setNodeStringProperty(std.testing.allocator, src, "external_key", "domain:claim:inbox");
        const dst = try store.addNode(.evidence, "source");
        try store.setNodeStringProperty(std.testing.allocator, dst, "external_key", "domain:evidence:inbox");
    }

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "agent-write", db_path, "--src", "1", "--rel", "references", "--dst", "2", "--text", "Inbox visible fact.", "--summary", "Inbox fact summary", "--retrieval-hints", "agent fallback inbox" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "projection_root=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "agent_inbox_created=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "projection_edge_created=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "content_node_properties=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "projection_links=2") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "agent-write", db_path, "--src", "1", "--rel", "references", "--dst", "2", "--text", "Inbox visible fact.", "--summary", "Inbox fact summary", "--retrieval-hints", "agent fallback inbox" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "fact_created=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "agent_inbox_created=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "projection_edge_created=0") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "render-md-doc", db_path, "3" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "Inbox visible fact.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "Inbox fact summary") == null);

    var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    const content_summary = (try store.getStringProperty(std.testing.allocator, .{ .node = .fromInt(4) }, "summary")).?;
    defer std.testing.allocator.free(content_summary);
    try std.testing.expectEqualStrings("Inbox fact summary", content_summary);
    const fact_edge_id = (try store.lookupFactEdgeByNodeExternalKeys(std.testing.allocator, .fromInt(1), .references, .fromInt(2))).?;
    const projection_edge_id = (try store.getStringProperty(std.testing.allocator, .{ .edge = fact_edge_id }, "projection_edge_id")).?;
    defer std.testing.allocator.free(projection_edge_id);
    try std.testing.expectEqualStrings("2", projection_edge_id);
}

test "agent-write json batch writes fact and projection provenance properties" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const batch_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "agent-write.json" });
    defer std.testing.allocator.free(batch_path);

    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        try store.createEmpty();
        const src = try store.addNode(.concept, "claim");
        try store.setNodeStringProperty(std.testing.allocator, src, "external_key", "domain:claim:json");
        const dst = try store.addNode(.evidence, "source");
        try store.setNodeStringProperty(std.testing.allocator, dst, "external_key", "domain:evidence:json");
    }

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = batch_path,
        .data =
        \\{
        \\  "items": [
        \\    {
        \\      "src": 1,
        \\      "rel": "references",
        \\      "dst": 2,
        \\      "document": 1,
        \\      "section": 2,
        \\      "text": "Conflicting attachment."
        \\    }
        \\  ]
        \\}
        \\
        ,
        .flags = .{ .truncate = true },
    });

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.MissingArgument,
        run(&.{ "tinykg", "agent-write", db_path, "--json", batch_path }, &out, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 0), out.buffer.items.len);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = batch_path,
        .data =
        \\{
        \\  "items": [
        \\    {
        \\      "src": 1,
        \\      "rel": "references",
        \\      "dst": 2,
        \\      "text": "JSON visible fact.",
        \\      "summary": "JSON summary",
        \\      "retrieval_hints": "json agent write hint",
        \\      "fact_properties": {
        \\        "created_by": "agent-json",
        \\        "confidence": "0.8"
        \\      },
        \\      "projection_properties": {
        \\        "source_span": "batch:1",
        \\        "created_by": "agent-json"
        \\      }
        \\    }
        \\  ]
        \\}
        \\
        ,
        .flags = .{ .truncate = true },
    });

    try run(&.{ "tinykg", "agent-write", db_path, "--json", batch_path }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "agent_write_json items=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "fact_created=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "projection_edge_created=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "content_node_properties=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "projection_links=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "fact_properties=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "projection_properties=2") != null);

    var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    const fact_edge_id = (try store.lookupFactEdgeByNodeExternalKeys(std.testing.allocator, .fromInt(1), .references, .fromInt(2))).?;
    const fact_created_by = (try store.getStringProperty(std.testing.allocator, .{ .edge = fact_edge_id }, "created_by")).?;
    defer std.testing.allocator.free(fact_created_by);
    try std.testing.expectEqualStrings("agent-json", fact_created_by);
    const fact_confidence = (try store.getStringProperty(std.testing.allocator, .{ .edge = fact_edge_id }, "confidence")).?;
    defer std.testing.allocator.free(fact_confidence);
    try std.testing.expectEqualStrings("0.8", fact_confidence);
    const content_summary = (try store.getStringProperty(std.testing.allocator, .{ .node = .fromInt(4) }, "summary")).?;
    defer std.testing.allocator.free(content_summary);
    try std.testing.expectEqualStrings("JSON summary", content_summary);

    var projection_edges = try store.readEdgeIndexRecordsByNode(std.testing.allocator, .src, .fromInt(3));
    defer projection_edges.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), projection_edges.items.len);
    const projection_edge_id = core.EdgeId.fromInt(projection_edges.items[0].edge_id);
    const projection_source_span = (try store.getStringProperty(std.testing.allocator, .{ .edge = projection_edge_id }, "source_span")).?;
    defer std.testing.allocator.free(projection_source_span);
    try std.testing.expectEqualStrings("batch:1", projection_source_span);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "render-md-doc", db_path, "3" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "JSON visible fact.") != null);
}

test "governance reports raw facts missing human-visible projection attachment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);

    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        try store.createEmpty();
        const src = try store.addNode(.concept, "claim");
        try store.setNodeStringProperty(std.testing.allocator, src, "schema_type", "concept");
        try store.setNodeStringProperty(std.testing.allocator, src, "external_key", "domain:claim:raw");
        const dst = try store.addNode(.evidence, "source");
        try store.setNodeStringProperty(std.testing.allocator, dst, "schema_type", "evidence");
        try store.setNodeStringProperty(std.testing.allocator, dst, "external_key", "domain:evidence:raw");
    }

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-edge", db_path, "1", "references", "2" }, &out, std.testing.allocator, std.testing.io);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "governance", db_path }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "unattached_fact_edges=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "unattached_fact_edge_sample edge=1 src=1 rel=references dst=2\n") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "agent-write", db_path, "--src", "1", "--rel", "references", "--dst", "2", "--text", "Raw fact is now visible." }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "fact_created=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "projection_links=2") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "governance", db_path }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "unattached_fact_edges=0\n") != null);
}

test "add-edge upsert finds external-keyed fact edge in segment overlay" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);

    const base_edge_count: u64 = 1024;
    const dst_id = base_edge_count + 2;
    const overlay_edge_id = base_edge_count + 1;
    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        try store.createEmpty();

        var nodes = std.ArrayList(graph.Node).empty;
        defer {
            for (nodes.items) |node| std.testing.allocator.free(node.text);
            nodes.deinit(std.testing.allocator);
        }
        try nodes.ensureTotalCapacity(std.testing.allocator, @intCast(dst_id));
        var node_id: u64 = 1;
        while (node_id <= dst_id) : (node_id += 1) {
            const text = if (node_id == 1)
                try std.testing.allocator.dupe(u8, "src")
            else if (node_id == dst_id)
                try std.testing.allocator.dupe(u8, "dst")
            else
                try std.fmt.allocPrint(std.testing.allocator, "node-{d}", .{node_id});
            errdefer std.testing.allocator.free(text);
            nodes.appendAssumeCapacity(.{
                .id = core.NodeId.fromInt(node_id),
                .kind = .concept,
                .text = text,
            });
        }
        try store.appendNodesBatch(nodes.items);
        try store.setNodeStringProperty(std.testing.allocator, core.NodeId.fromInt(1), "external_key", "domain:overlay:src");
        try store.setNodeStringProperty(std.testing.allocator, core.NodeId.fromInt(dst_id), "external_key", "domain:overlay:dst");

        var base_edges = std.ArrayList(graph.Edge).empty;
        defer base_edges.deinit(std.testing.allocator);
        try base_edges.ensureTotalCapacity(std.testing.allocator, @intCast(base_edge_count));
        var edge_id: u64 = 1;
        while (edge_id <= base_edge_count) : (edge_id += 1) {
            base_edges.appendAssumeCapacity(.{
                .id = core.EdgeId.fromInt(edge_id),
                .src = core.NodeId.fromInt(1),
                .dst = core.NodeId.fromInt(edge_id + 1),
                .rel = .mentions,
            });
        }
        try store.appendEdgesBatch(base_edges.items);

        try store.appendEdge(.{
            .id = core.EdgeId.fromInt(overlay_edge_id),
            .src = core.NodeId.fromInt(1),
            .dst = core.NodeId.fromInt(dst_id),
            .rel = .references,
        });
        var primary_records = try store.readEdgeIndexRecordsByNode(std.testing.allocator, .src, core.NodeId.fromInt(1));
        defer primary_records.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, @intCast(base_edge_count)), primary_records.items.len);
        std.Io.Dir.cwd().deleteFile(std.testing.io, store.edge_external_key_index_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    const dst_arg = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{dst_id});
    defer std.testing.allocator.free(dst_arg);
    try run(&.{ "tinykg", "add-edge", db_path, "1", "references", dst_arg }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("edge 1025\n", out.buffer.items);

    var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    const stats = try store.stats();
    try std.testing.expectEqual(base_edge_count + 1, stats.edges);
}

test "backup and restore clean targets after allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const backup_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg-backup" });
    defer std.testing.allocator.free(backup_path);

    var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer init_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);

    var add_a_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer add_a_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "task", "backup failure source task" }, &add_a_out, std.testing.allocator, std.testing.io);

    var add_b_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer add_b_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "note", "backup failure source note" }, &add_b_out, std.testing.allocator, std.testing.io);

    var edge_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer edge_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-edge", db_path, "1", "supports", "2" }, &edge_out, std.testing.allocator, std.testing.io);

    var saw_backup_allocation_failure = false;
    var backup_reached_success = false;
    for (0..512) |fail_index| {
        const target_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/backup-oom-{}.kg", .{ root_path, fail_index });
        defer std.testing.allocator.free(target_path);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        _ = backupStore(failing.allocator(), std.testing.io, db_path, target_path) catch |err| switch (err) {
            error.OutOfMemory => {
                saw_backup_allocation_failure = true;
                try std.testing.expect(!try anyPathExists(std.testing.io, target_path));
                continue;
            },
            else => return err,
        };
        backup_reached_success = true;
        try std.Io.Dir.cwd().deleteTree(std.testing.io, target_path);
        break;
    }
    try std.testing.expect(saw_backup_allocation_failure);
    try std.testing.expect(backup_reached_success);

    _ = try backupStore(std.testing.allocator, std.testing.io, db_path, backup_path);

    var saw_restore_allocation_failure = false;
    var restore_reached_success = false;
    for (0..512) |fail_index| {
        const target_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/restore-oom-{}.kg", .{ root_path, fail_index });
        defer std.testing.allocator.free(target_path);
        const staging_path = try restoreStagingPath(std.testing.allocator, target_path);
        defer std.testing.allocator.free(staging_path);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        _ = restoreBackup(failing.allocator(), std.testing.io, backup_path, target_path) catch |err| switch (err) {
            error.OutOfMemory => {
                saw_restore_allocation_failure = true;
                try std.testing.expect(!try anyPathExists(std.testing.io, target_path));
                try std.testing.expect(!try anyPathExists(std.testing.io, staging_path));
                continue;
            },
            else => return err,
        };
        restore_reached_success = true;
        try std.Io.Dir.cwd().deleteTree(std.testing.io, target_path);
        break;
    }
    try std.testing.expect(saw_restore_allocation_failure);
    try std.testing.expect(restore_reached_success);
}

test "schema info and CLI inheritance queries use custom schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
    defer std.testing.allocator.free(schema_path);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = schema_path,
        .data =
        \\{
        \\  "profiles": ["markdown-document"],
        \\  "node_types": [
        \\    {"name": "Human", "id": 100},
        \\    {"name": "Man", "id": 101, "parents": ["Human"]},
        \\    {"name": "Woman", "id": 102, "parents": ["Human"]}
        \\  ],
        \\  "relation_types": [
        \\    {"name": "InteractsWith", "id": 100},
        \\    {"name": "Knows", "id": 101, "parents": ["InteractsWith"]},
        \\    {"name": "md:h1", "id": 3000, "class": "md", "src_types": ["document"], "dst_types": ["document_section"]}
        \\  ]
        \\}
        ,
        .flags = .{ .truncate = true },
    });

    var schema_info_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer schema_info_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "schema-info", "--schema", schema_path }, &schema_info_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, schema_info_out.buffer.items, "node_types=10\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_info_out.buffer.items, "relation_types=26\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_info_out.buffer.items, "max_node_types=4096\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_info_out.buffer.items, "max_relation_types=16384\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_info_out.buffer.items, "relation_class_count md=20\n") != null);

    var kinds_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer kinds_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "list-kinds", "--schema", schema_path }, &kinds_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, kinds_out.buffer.items, "type id=100 name=Human parents=- descendant_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, kinds_out.buffer.items, "type id=101 name=Man parents=Human descendant_count=1\n") != null);

    var rels_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer rels_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "list-rels", "--schema", schema_path }, &rels_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, rels_out.buffer.items, "type id=100 name=InteractsWith parents=- descendant_count=2 class=domain\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rels_out.buffer.items, "type id=101 name=Knows parents=InteractsWith descendant_count=1 class=domain\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rels_out.buffer.items, "type id=3000 name=md:h1 parents=edge descendant_count=1 class=md\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rels_out.buffer.items, "type id=3022 name=md:table_cell parents=edge descendant_count=1 class=md\n") != null);

    var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer init_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);

    var human_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer human_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "Human", "alex", "--schema", schema_path }, &human_out, std.testing.allocator, std.testing.io);
    var man_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer man_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "Man", "bob", "--schema", schema_path }, &man_out, std.testing.allocator, std.testing.io);
    var woman_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer woman_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "Woman", "cat", "--schema", schema_path }, &woman_out, std.testing.allocator, std.testing.io);
    var edge_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer edge_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-edge", db_path, "2", "Knows", "3", "--schema", schema_path }, &edge_out, std.testing.allocator, std.testing.io);

    var node_query_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer node_query_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "query", db_path, "MATCH (h:Human) RETURN h.text LIMIT 10", "--schema", schema_path }, &node_query_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, node_query_out.buffer.items, "alex\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, node_query_out.buffer.items, "bob\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, node_query_out.buffer.items, "cat\n") != null);

    var rel_query_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer rel_query_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "query", db_path, "MATCH (a:Human)-[:InteractsWith]->(b:Human) RETURN b.text LIMIT 10", "--schema", schema_path }, &rel_query_out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("cat\n", rel_query_out.buffer.items);
}

test "default schema stays kernel-only and official profiles are explicit" {
    var schema_info_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer schema_info_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "schema-info" }, &schema_info_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, schema_info_out.buffer.items, "schema=kernel\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_info_out.buffer.items, "node_types=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_info_out.buffer.items, "relation_types=2\n") != null);

    var default_kinds_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer default_kinds_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "list-kinds" }, &default_kinds_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, default_kinds_out.buffer.items, "name=node") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_kinds_out.buffer.items, "name=repo") == null);
    try std.testing.expect(std.mem.indexOf(u8, default_kinds_out.buffer.items, "name=file") == null);
    try std.testing.expect(std.mem.indexOf(u8, default_kinds_out.buffer.items, "name=function") == null);
    try std.testing.expect(std.mem.indexOf(u8, default_kinds_out.buffer.items, "name=concept") == null);
    try std.testing.expect(std.mem.indexOf(u8, default_kinds_out.buffer.items, "name=user_preference") == null);
    try std.testing.expect(std.mem.indexOf(u8, default_kinds_out.buffer.items, "alias note=observation") == null);

    var default_rels_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer default_rels_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "list-rels" }, &default_rels_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, default_rels_out.buffer.items, "name=edge") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_rels_out.buffer.items, "name=defines") == null);
    try std.testing.expect(std.mem.indexOf(u8, default_rels_out.buffer.items, "name=calls") == null);
    try std.testing.expect(std.mem.indexOf(u8, default_rels_out.buffer.items, "name=imports") == null);
    try std.testing.expect(std.mem.indexOf(u8, default_rels_out.buffer.items, "name=summarizes") == null);
    try std.testing.expect(std.mem.indexOf(u8, default_rels_out.buffer.items, "alias supports=evidences") == null);

    var profile_kinds_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer profile_kinds_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "list-kinds", "--profile", "agent-dag,markdown-document" }, &profile_kinds_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, profile_kinds_out.buffer.items, "name=task") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile_kinds_out.buffer.items, "name=document") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile_kinds_out.buffer.items, "name=repo") == null);
    try std.testing.expect(std.mem.indexOf(u8, profile_kinds_out.buffer.items, "name=symbol") == null);
    try std.testing.expect(std.mem.indexOf(u8, profile_kinds_out.buffer.items, "alias note=observation") == null);

    var profile_rels_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer profile_rels_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "list-rels", "--profile", "agent-dag,markdown-document" }, &profile_rels_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, profile_rels_out.buffer.items, "name=depends_on") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile_rels_out.buffer.items, "name=md:text_chunk") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile_rels_out.buffer.items, "name=defines") == null);
    try std.testing.expect(std.mem.indexOf(u8, profile_rels_out.buffer.items, "name=imports") == null);
    try std.testing.expect(std.mem.indexOf(u8, profile_rels_out.buffer.items, "alias supports=evidences") == null);
}

test "governance schema reports relation endpoint violations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
    defer std.testing.allocator.free(schema_path);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = schema_path,
        .data =
        \\{
        \\  "node_types": [
        \\    {"name": "AgentMemory", "id": 100},
        \\    {"name": "AgentDecision", "id": 101, "parents": ["AgentMemory"]},
        \\    {"name": "AgentEvidence", "id": 102}
        \\  ],
        \\  "relation_types": [
        \\    {"name": "AgentSupportedBy", "id": 100, "src_types": ["AgentMemory"], "dst_types": ["AgentEvidence"]}
        \\  ]
        \\}
        ,
        .flags = .{ .truncate = true },
    });

    var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer init_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);

    var decision_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer decision_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "AgentDecision", "decision", "--schema", schema_path }, &decision_out, std.testing.allocator, std.testing.io);

    var evidence_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer evidence_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "AgentEvidence", "evidence", "--schema", schema_path }, &evidence_out, std.testing.allocator, std.testing.io);

    var good_edge_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer good_edge_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-edge", db_path, "1", "AgentSupportedBy", "2", "--schema", schema_path }, &good_edge_out, std.testing.allocator, std.testing.io);

    {
        var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        try store.appendEdgeIndexed(.{
            .id = .fromInt(2),
            .src = .fromInt(2),
            .rel = @enumFromInt(@as(u16, 100)),
            .dst = .fromInt(1),
        });
    }

    var governance_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer governance_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "governance", db_path, "--schema", schema_path }, &governance_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "schema_edge_endpoint_violations=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "schema_unknown_node_type_nodes=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "schema_unknown_relation_type_edges=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "schema_edge_endpoint_violation_sample edge=2") != null);
}

test "governance reports unknown endpoint node kinds without aborting edge scan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
    defer std.testing.allocator.free(schema_path);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = schema_path,
        .data =
        \\{
        \\  "node_types": [
        \\    {"name": "Known", "id": 100}
        \\  ],
        \\  "relation_types": [
        \\    {"name": "KnownLink", "id": 100, "src_types": ["Known"]}
        \\  ]
        \\}
        ,
        .flags = .{ .truncate = true },
    });

    var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer init_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);

    {
        var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        const unknown = try store.addNode(.repo, "legacy repo");
        const known = try store.addNode(@enumFromInt(@as(u16, 100)), "known");
        try store.appendEdgeIndexed(.{
            .id = .fromInt(1),
            .src = unknown,
            .rel = @enumFromInt(@as(u16, 100)),
            .dst = known,
        });
    }

    var governance_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer governance_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "governance", db_path, "--schema", schema_path }, &governance_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "schema_unknown_node_type_nodes=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "schema_edge_endpoint_violations=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "phase=schema_edges status=end checked=1 total=1") != null);
}

test "schema v2 properties composition and workflow metadata stay static" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
    defer std.testing.allocator.free(schema_path);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = schema_path,
        .data =
        \\{
        \\  "schema_version": 2,
        \\  "node_types": [
        \\    {
        \\      "name": "AgentDoc",
        \\      "id": 100,
        \\      "properties": {
        \\        "review_state": {
        \\          "type": "string",
        \\          "required": false,
        \\          "nullable": true,
        \\          "agent_fillable": false,
        \\          "human_fillable": true,
        \\          "indexed": false,
        \\          "searchable": false,
        \\          "returned_by_default": true
        \\        }
        \\      }
        \\    },
        \\    {"name": "AgentSection", "id": 101}
        \\  ],
        \\  "relation_types": [
        \\    {
        \\      "name": "AgentContains",
        \\      "id": 100,
        \\      "src_types": ["AgentDoc"],
        \\      "dst_types": ["AgentSection"],
        \\      "properties": {
        \\        "order_key": {"type": "uint", "required": false, "nullable": true, "indexed": true}
        \\      },
        \\      "composition": {
        \\        "enabled": true,
        \\        "owner": true,
        \\        "cardinality": "many",
        \\        "ordered_by": "order_key"
        \\      }
        \\    }
        \\  ]
        \\}
        ,
        .flags = .{ .truncate = true },
    });

    var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer init_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);

    {
        var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        const doc = try store.addNode(@enumFromInt(@as(u16, 100)), "doc");
        try store.setStringProperty(std.testing.allocator, .{ .node = doc }, "review_state", "draft");
        const section = try store.addNode(@enumFromInt(@as(u16, 101)), "section");
        _ = try store.addNode(@enumFromInt(@as(u16, 101)), "orphan section");
        try store.appendEdgeIndexed(.{ .id = .fromInt(1), .src = doc, .rel = @enumFromInt(@as(u16, 100)), .dst = section });
    }

    var edge_prop_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer edge_prop_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "set-edge-property", db_path, "1", "created_by", "agent" }, &edge_prop_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, edge_prop_out.buffer.items, "edge_property edge=1 key=created_by") != null);

    var schema_info_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer schema_info_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "schema-info", "--schema", schema_path }, &schema_info_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, schema_info_out.buffer.items, "relation_properties=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_info_out.buffer.items, "relation_compositions=1\n") != null);

    var query_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer query_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "query", db_path, "MATCH (d:AgentDoc) RETURN d.review_state LIMIT 5", "--schema", schema_path }, &query_out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("draft\n", query_out.buffer.items);

    var governance_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer governance_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "governance", db_path, "--schema", schema_path }, &governance_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "schema_agent_fillable_missing_fields=6\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "schema_human_fillable_missing_fields=6\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "schema_unknown_edge_properties=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "schema_composition_orphans=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "schema_ordered_composition_missing_ordered_by=1\n") != null);

    var set_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer set_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "set-node-property", db_path, "1", "summary", "human approved summary", "--schema", schema_path }, &set_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, set_out.buffer.items, "node_property node=1 key=summary") != null);
}

test "markdown composition governance resolves edge_order sidecar and classifies legacy contains" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .document, .text = "modern document" },
        .{ .id = .fromInt(2), .kind = .document_section, .text = "modern occurrence" },
        .{ .id = .fromInt(3), .kind = .task, .text = "legacy task parent" },
        .{ .id = .fromInt(4), .kind = .task, .text = "legacy task child" },
        .{ .id = .fromInt(5), .kind = .project, .text = "legacy project" },
        .{ .id = .fromInt(6), .kind = .task, .text = "legacy project task" },
        .{ .id = .fromInt(7), .kind = .document, .text = "legacy document parent" },
        .{ .id = .fromInt(8), .kind = .document, .text = "legacy document child" },
        .{ .id = .fromInt(9), .kind = .document, .text = "legacy markdown owner" },
        .{ .id = .fromInt(10), .kind = .document_section, .text = "legacy markdown occurrence" },
        .{ .id = .fromInt(11), .kind = .document_section, .text = "true orphan" },
        .{ .id = .fromInt(12), .kind = .concept, .text = "unclassified parent" },
        .{ .id = .fromInt(13), .kind = .evidence, .text = "unclassified child" },
        .{ .id = .fromInt(14), .kind = .image, .text = "standalone referenced image" },
        .{ .id = .fromInt(15), .kind = .observation, .text = "standalone reusable content" },
    });
    try store.appendEdgeOrderedIndexed(.{
        .id = .fromInt(1),
        .src = .fromInt(1),
        .rel = @enumFromInt(@as(u16, schema.md_rel_paragraph_id)),
        .dst = .fromInt(2),
    }, 1024);
    try store.appendEdgesBatch(&.{
        .{ .id = .fromInt(2), .src = .fromInt(3), .rel = .contains, .dst = .fromInt(4) },
        .{ .id = .fromInt(3), .src = .fromInt(5), .rel = .contains, .dst = .fromInt(6) },
        .{ .id = .fromInt(4), .src = .fromInt(7), .rel = .contains, .dst = .fromInt(8) },
        .{ .id = .fromInt(5), .src = .fromInt(9), .rel = .contains, .dst = .fromInt(10) },
        .{ .id = .fromInt(6), .src = .fromInt(12), .rel = .contains, .dst = .fromInt(13) },
    });

    var registry = schema.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.addDefaultTypes();
    try registry.addBuiltinProfile(.agent_dag);
    try registry.addBuiltinProfile(.markdown_document);

    var governance_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer governance_out.buffer.deinit(std.testing.allocator);
    try governance_command.render(std.testing.allocator, std.testing.io, db_path, store, registry, &governance_out);
    const report = governance_out.buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_edge_endpoint_violations=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_composition_orphans=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_ordered_composition_missing_ordered_by=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_ordered_composition_order_source_conflicts=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_ordered_composition_invalid_order_bindings=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_legacy_contains_edges=5\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_legacy_contains_task_hierarchy_edges=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_legacy_contains_project_membership_edges=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_legacy_contains_document_hierarchy_edges=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_legacy_contains_markdown_occurrence_edges=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_legacy_contains_unclassified_edges=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_composition_orphan_sample node=11 kind=document_section") != null);
}

test "canonical markdown profile matches real importer node and order representation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const markdown_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "fixture.md" });
    defer std.testing.allocator.free(markdown_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = markdown_path,
        .data =
        \\# Heading
        \\
        \\paragraph text
        \\
        \\![alt](image.png)
        \\
        \\| A | B |
        \\| - | - |
        \\| one | two |
        ,
    });

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "import-md-doc", db_path, markdown_path }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "governance", db_path, "--profile", "markdown-document" }, &out, std.testing.allocator, std.testing.io);
    const report = out.buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_unknown_node_type_nodes=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_edge_endpoint_violations=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_composition_orphans=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_ordered_composition_missing_ordered_by=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_ordered_composition_order_source_conflicts=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_ordered_composition_invalid_order_bindings=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_legacy_contains_edges=0\n") != null);
}

test "markdown composition governance reports missing duplicate conflict and invalid sidecar bindings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .document, .text = "document" },
        .{ .id = .fromInt(2), .kind = .document_section, .text = "missing order" },
        .{ .id = .fromInt(3), .kind = .document_section, .text = "duplicate a" },
        .{ .id = .fromInt(4), .kind = .document_section, .text = "duplicate b" },
        .{ .id = .fromInt(5), .kind = .document_section, .text = "conflict" },
        .{ .id = .fromInt(6), .kind = .document_section, .text = "invalid binding" },
        .{ .id = .fromInt(7), .kind = .document, .text = "invalid endpoint" },
    });
    const paragraph: core.RelKind = @enumFromInt(@as(u16, schema.md_rel_paragraph_id));
    try store.appendEdgeIndexed(.{ .id = .fromInt(1), .src = .fromInt(1), .rel = paragraph, .dst = .fromInt(2) });
    try store.appendEdgeOrderedIndexed(.{ .id = .fromInt(2), .src = .fromInt(1), .rel = paragraph, .dst = .fromInt(3) }, 100);
    try store.appendEdgeOrderedIndexed(.{ .id = .fromInt(3), .src = .fromInt(1), .rel = paragraph, .dst = .fromInt(4) }, 100);
    try store.appendEdgeOrderedIndexed(.{ .id = .fromInt(4), .src = .fromInt(1), .rel = paragraph, .dst = .fromInt(5) }, 200);
    try store.setUintProperty(std.testing.allocator, .{ .edge = .fromInt(4) }, "order_key", 201);
    try store.appendEdgeIndexed(.{ .id = .fromInt(5), .src = .fromInt(1), .rel = paragraph, .dst = .fromInt(6) });
    try store.upsertEdgeOrderRecordsBatch(std.testing.allocator, &.{.{
        .src = 999,
        .rel = schema.md_rel_paragraph_id,
        .edge_id = 5,
        .order_key = 250,
    }});
    try store.appendEdgeOrderedIndexed(.{ .id = .fromInt(6), .src = .fromInt(2), .rel = paragraph, .dst = .fromInt(7) }, 300);

    var registry = schema.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.addDefaultTypes();
    try registry.addBuiltinProfile(.markdown_document);

    var governance_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer governance_out.buffer.deinit(std.testing.allocator);
    try governance_command.render(std.testing.allocator, std.testing.io, db_path, store, registry, &governance_out);
    const report = governance_out.buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_edge_endpoint_violations=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_edge_endpoint_violation_relation_count md:paragraph=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_ordered_composition_missing_ordered_by=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_ordered_composition_order_source_conflicts=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_ordered_composition_invalid_order_bindings=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_duplicate_order_key=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_ordered_composition_order_source_conflict_sample edge=4 sidecar=200 property=201") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "schema_ordered_composition_invalid_order_binding_sample edge=5") != null);
}

test "schema file profile contract pins legacy and current markdown semantics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const legacy_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "legacy.json" });
    defer std.testing.allocator.free(legacy_path);
    const current_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "current.json" });
    defer std.testing.allocator.free(current_path);
    const invalid_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "invalid.json" });
    defer std.testing.allocator.free(invalid_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = legacy_path, .data =
        \\{"schema_version":3,"profiles":["markdown-document"]}
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = current_path, .data =
        \\{"schema_version":3,"profiles":["markdown-document"],"profile_contracts":{"markdown_document":2}}
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = invalid_path, .data =
        \\{"schema_version":3,"profiles":["markdown-document"],"profile_contracts":{"markdown_document":99}}
    });

    var legacy = try loadSchemaRegistryFile(std.testing.allocator, std.testing.io, legacy_path);
    defer legacy.deinit();
    try std.testing.expect((legacy.relationCompositionById(@intFromEnum(core.RelKind.contains)) orelse unreachable).enabled);
    try std.testing.expect(legacy.relationCompositionById(schema.md_rel_paragraph_id) == null);
    const legacy_precedes_rule = legacy.relationEndpointRuleById(@intFromEnum(core.RelKind.precedes)) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 1), legacy_precedes_rule.src.?.count());
    try std.testing.expectEqual(@as(u16, 1), legacy_precedes_rule.dst.?.count());
    try std.testing.expect(legacy_precedes_rule.src.?.containsNodeKind(.document_section));
    try std.testing.expect(legacy_precedes_rule.dst.?.containsNodeKind(.document_section));

    var current = try loadSchemaRegistryFile(std.testing.allocator, std.testing.io, current_path);
    defer current.deinit();
    try std.testing.expect(current.relationCompositionById(@intFromEnum(core.RelKind.contains)) == null);
    try std.testing.expect((current.relationEndpointRuleById(@intFromEnum(core.RelKind.contains)) orelse unreachable).isEmpty());
    try std.testing.expect((current.relationEndpointRuleById(@intFromEnum(core.RelKind.precedes)) orelse unreachable).isEmpty());
    try std.testing.expect((current.relationCompositionById(schema.md_rel_paragraph_id) orelse unreachable).enabled);
    try std.testing.expectError(
        schema.Error.InvalidProfileContractVersion,
        loadSchemaRegistryFile(std.testing.allocator, std.testing.io, invalid_path),
    );
}

test "schema file markerless agent DAG stays v1 and explicit v2 governs shared provenance" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const legacy_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "legacy-agent.json" });
    defer std.testing.allocator.free(legacy_path);
    const current_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "current-agent.json" });
    defer std.testing.allocator.free(current_path);
    const invalid_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "invalid-agent.json" });
    defer std.testing.allocator.free(invalid_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = legacy_path, .data =
        \\{"schema_version":3,"profiles":["agent-dag"]}
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = current_path, .data =
        \\{"schema_version":3,"profiles":["agent-dag"],"profile_contracts":{"agent_dag":2}}
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = invalid_path, .data =
        \\{"schema_version":3,"profiles":["agent-dag"],"profile_contracts":{"agent_dag":99}}
    });

    var legacy = try loadSchemaRegistryFile(std.testing.allocator, std.testing.io, legacy_path);
    defer legacy.deinit();
    try std.testing.expect(legacy.findRelationType("references") == null);
    try std.testing.expect((legacy.relationEndpointRuleById(@intFromEnum(core.RelKind.based_on)) orelse unreachable).isEmpty());

    var current = try loadSchemaRegistryFile(std.testing.allocator, std.testing.io, current_path);
    defer current.deinit();
    try std.testing.expectEqual(
        try schema.sharedReferencesEndpointRule(),
        current.relationEndpointRuleById(@intFromEnum(core.RelKind.references)).?,
    );
    try std.testing.expectEqual(
        try schema.sharedBasedOnEndpointRule(),
        current.relationEndpointRuleById(@intFromEnum(core.RelKind.based_on)).?,
    );
    try std.testing.expectError(
        schema.Error.InvalidProfileContractVersion,
        loadSchemaRegistryFile(std.testing.allocator, std.testing.io, invalid_path),
    );
}

test "schema enum domains survive catalog persistence and governance rejects invalid values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
    defer std.testing.allocator.free(schema_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = schema_path,
        .data =
        \\{
        \\  "schema_version": 3,
        \\  "node_types": [{
        \\    "name": "Workflow",
        \\    "id": 100,
        \\    "parents": ["node"],
        \\    "properties": {
        \\      "state": {"type": "enum", "values": ["draft", "published"], "required": true, "nullable": false}
        \\    }
        \\  }]
        \\}
        ,
        .flags = .{ .truncate = true },
    });

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "schema-apply", db_path, "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "result=applied") != null);

    {
        var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        var cat = (try store.readCatalog()).?;
        defer cat.deinit();
        const state = cat.registry.nodePropertyByTypeId(100, "state").?;
        try std.testing.expect(state.enumAllows("draft"));
        try std.testing.expect(!state.enumAllows("done-ish"));

        try store.appendNode(.{ .id = .fromInt(1), .kind = @enumFromInt(@as(u16, 100)), .text = "workflow" });
        try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), "state", "done-ish");
    }

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "schema-show", db_path }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_property name=state type=enum") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "enum_values=draft,published") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "schema-show", db_path, "--json" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "\"properties\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "\"name\":\"state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "\"enum_values\":[\"draft\",\"published\"]") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "governance", db_path, "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_invalid_property_type=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_invalid_node_property_type_sample node=1 key=state expected=enum") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "governance", db_path }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_invalid_property_type=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_invalid_node_property_type_sample node=1 key=state expected=enum") != null);
}

test "schema v3 governance catches missing and invalid task status markers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
    {
        var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "missing status" });
        try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "invalid status" });
        try store.setNodeStringProperty(std.testing.allocator, .fromInt(2), task.status_property, "done-ish");
    }

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "governance", db_path, "--profile", "agent-dag" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_missing_required_node_properties=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_invalid_property_type=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_missing_required_node_property_sample node=1 key=status") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_invalid_node_property_type_sample node=2 key=status expected=enum") != null);
}

test "governance reports node health and fanout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/test.kg", .{path_buf[0..root_len]});
    defer std.testing.allocator.free(db_path);

    var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer init_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);

    var alpha_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer alpha_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "concept", "Alpha claim" }, &alpha_out, std.testing.allocator, std.testing.io);

    var beta_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer beta_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "concept", "Beta claim" }, &beta_out, std.testing.allocator, std.testing.io);

    var contains_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer contains_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "2" }, &contains_out, std.testing.allocator, std.testing.io);

    var references_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer references_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-edge", db_path, "2", "references", "1" }, &references_out, std.testing.allocator, std.testing.io);

    var governance_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer governance_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "governance", db_path }, &governance_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "unattached_fact_edges=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "max_outgoing_edges=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "high_fanout_nodes=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "high_fanout_threshold=128\n") != null);
}

test "governance reports navigation fanout separately from content fanout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{
        .id = .fromInt(1),
        .kind = .document,
        .text = "nav root props_text=\"{\\\"domain_id\\\":\\\"tinykg\\\",\\\"schema_type\\\":\\\"domain_root\\\"}\"",
    });
    try store.appendNode(.{
        .id = .fromInt(2),
        .kind = .decision,
        .text = "content hub props_text=\"{\\\"domain_id\\\":\\\"tinykg\\\",\\\"schema_type\\\":\\\"decision\\\"}\"",
    });

    var next_node_id: u64 = 3;
    var next_edge_id: u64 = 1;
    var i: usize = 0;
    while (i < governance_navigation_fanout_warn_threshold + 1) : (i += 1) {
        try store.appendNode(.{
            .id = .fromInt(next_node_id),
            .kind = .concept,
            .text = "nav child props_text=\"{\\\"domain_id\\\":\\\"tinykg\\\",\\\"schema_type\\\":\\\"concept\\\"}\"",
        });
        try store.appendEdge(.{ .id = .fromInt(next_edge_id), .src = .fromInt(1), .rel = .contains, .dst = .fromInt(next_node_id) });
        next_node_id += 1;
        next_edge_id += 1;
    }
    i = 0;
    while (i < governance_high_fanout_threshold + 1) : (i += 1) {
        try store.appendNode(.{
            .id = .fromInt(next_node_id),
            .kind = .evidence,
            .text = "content evidence props_text=\"{\\\"domain_id\\\":\\\"tinykg\\\",\\\"schema_type\\\":\\\"evidence\\\"}\"",
        });
        try store.appendEdge(.{ .id = .fromInt(next_edge_id), .src = .fromInt(2), .rel = .based_on, .dst = .fromInt(next_node_id) });
        next_node_id += 1;
        next_edge_id += 1;
    }

    var governance_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer governance_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "governance", db_path }, &governance_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "high_fanout_nodes=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "navigation_entry_nodes=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "navigation_fanout_violations=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "navigation_fanout_warn_threshold=64\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "navigation_fanout_violation_sample id=1 kind=document navigation_edges=65 outgoing_edges=65") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "navigation_fanout_violation_sample id=1 kind=document navigation_edges=65 outgoing_edges=65 relation_counts=contains:65") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "high_fanout_node_sample id=2 kind=decision outgoing_edges=129 relation_counts=based_on:129") != null);
}

test "governance fanout sample relation counts include published edge overlay" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "base-segment" });
    defer std.testing.allocator.free(segment_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .concept, .text = "fanout root" },
        .{ .id = .fromInt(2), .kind = .concept, .text = "base target" },
        .{ .id = .fromInt(3), .kind = .concept, .text = "overlay target" },
    });

    var base_edges = std.ArrayList(graph.Edge).empty;
    defer base_edges.deinit(std.testing.allocator);
    try base_edges.ensureTotalCapacityPrecise(std.testing.allocator, governance_high_fanout_threshold);
    for (0..governance_high_fanout_threshold) |index| {
        base_edges.appendAssumeCapacity(.{
            .id = .fromInt(index + 1),
            .src = .fromInt(1),
            .rel = .related_to,
            .dst = .fromInt(2),
        });
    }
    try store.appendEdgesBatch(base_edges.items);
    try std.testing.expectEqual(governance_high_fanout_threshold, try store.publishEdgeAdjacencySegment(segment_path));
    try store.appendEdge(.{
        .id = .fromInt(governance_high_fanout_threshold + 1),
        .src = .fromInt(1),
        .rel = .mentions,
        .dst = .fromInt(3),
    });

    var governance_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer governance_out.buffer.deinit(std.testing.allocator);
    try governance_command.render(std.testing.allocator, std.testing.io, db_path, store, null, &governance_out);
    try std.testing.expect(std.mem.indexOf(
        u8,
        governance_out.buffer.items,
        "high_fanout_node_sample id=1 kind=concept outgoing_edges=129 relation_counts=",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "mentions:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "related_to:128") != null);
}

test "add edge with schema rejects endpoint violations before append" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
    defer std.testing.allocator.free(schema_path);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = schema_path,
        .data =
        \\{
        \\  "node_types": [
        \\    {"name": "AgentMemory", "id": 100},
        \\    {"name": "AgentDecision", "id": 101, "parents": ["AgentMemory"]},
        \\    {"name": "AgentEvidence", "id": 102}
        \\  ],
        \\  "relation_types": [
        \\    {"name": "AgentSupportedBy", "id": 100, "src_types": ["AgentMemory"], "dst_types": ["AgentEvidence"]}
        \\  ]
        \\}
        ,
        .flags = .{ .truncate = true },
    });

    var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer init_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);

    var decision_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer decision_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "AgentDecision", "decision", "--schema", schema_path }, &decision_out, std.testing.allocator, std.testing.io);

    var evidence_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer evidence_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "AgentEvidence", "evidence", "--schema", schema_path }, &evidence_out, std.testing.allocator, std.testing.io);

    var bad_edge_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer bad_edge_out.buffer.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.SchemaEndpointViolation,
        run(&.{ "tinykg", "add-edge", db_path, "2", "AgentSupportedBy", "1", "--schema", schema_path }, &bad_edge_out, std.testing.allocator, std.testing.io),
    );

    var good_edge_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer good_edge_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-edge", db_path, "1", "AgentSupportedBy", "2", "--schema", schema_path }, &good_edge_out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("edge 1\n", good_edge_out.buffer.items);

    var governance_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer governance_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "governance", db_path, "--schema", schema_path }, &governance_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "edges=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "node_kind_count AgentDecision=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "node_kind_count AgentEvidence=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "traversable_relation_count AgentSupportedBy=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "schema_edge_endpoint_violations=0\n") != null);
}

test "governance schema can constrain built-in relations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
    defer std.testing.allocator.free(schema_path);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = schema_path,
        .data =
        \\{
        \\  "profiles": ["agent-dag"],
        \\  "relation_types": [
        \\    {"name": "based_on", "id": 9, "src_types": ["decision"], "dst_types": ["evidence"]}
        \\  ]
        \\}
        ,
        .flags = .{ .truncate = true },
    });

    var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer init_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);

    var decision_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer decision_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "decision", "claim" }, &decision_out, std.testing.allocator, std.testing.io);

    var evidence_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer evidence_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "evidence", "source" }, &evidence_out, std.testing.allocator, std.testing.io);

    var good_edge_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer good_edge_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-edge", db_path, "1", "based_on", "2" }, &good_edge_out, std.testing.allocator, std.testing.io);

    var rejected_edge_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer rejected_edge_out.buffer.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.SchemaEndpointViolation,
        run(&.{ "tinykg", "add-edge", db_path, "2", "based_on", "1", "--schema", schema_path }, &rejected_edge_out, std.testing.allocator, std.testing.io),
    );

    var bad_edge_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer bad_edge_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-edge", db_path, "2", "based_on", "1" }, &bad_edge_out, std.testing.allocator, std.testing.io);

    var governance_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer governance_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "governance", db_path, "--schema", schema_path }, &governance_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "schema_edge_endpoint_violations=1\n") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        governance_out.buffer.items,
        "schema_edge_endpoint_violation_pair_count rel=based_on src=evidence dst=decision count=1 first_edge=2 src_id=2 dst_id=1\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "schema_edge_endpoint_violation_sample edge=2") != null);
}

test "canonical shared provenance endpoints accept intended consumers and reject near misses" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
    defer std.testing.allocator.free(schema_path);
    const batch_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "invalid-apply.jsonl" });
    defer std.testing.allocator.free(batch_path);

    const legacy_schema =
        \\{"schema_version":3,"profiles":["agent-dag","markdown-document"],"profile_contracts":{"agent_dag":1,"markdown_document":2},"node_types":[{"name":"user_preference","id":20,"parents":["node"]}],"relation_types":[{"name":"references","id":8,"parents":["edge"],"class":"prov","src_types":["document","concept","decision","fix","verification","command","error_event","user_preference","task","observation"],"dst_types":["evidence","image"]},{"name":"based_on","id":9,"class":"prov","src_types":["concept","decision","fix","verification","command","error_event","user_preference","task","observation"],"dst_types":["evidence"]}]}
    ;
    const current_schema =
        \\{"schema_version":3,"profiles":["agent-dag","markdown-document"],"profile_contracts":{"agent_dag":2,"markdown_document":2},"node_types":[{"name":"user_preference","id":20,"parents":["node"]}]}
    ;

    try writeSchemaFile(std.testing.io, schema_path, legacy_schema);
    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "schema-apply", db_path, "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "result=applied") != null);

    try writeSchemaFile(std.testing.io, schema_path, current_schema);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "schema-apply", db_path, "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "result=applied") != null);

    inline for (.{
        .{
            "8",
            \\{"schema_version":3,"profiles":["agent-dag","markdown-document"],"profile_contracts":{"agent_dag":2,"markdown_document":2},"node_types":[{"name":"user_preference","id":20,"parents":["node"]}],"relation_types":[{"name":"references","id":8,"class":"prov","src_types":["node"],"dst_types":["node"]}]}
        },
        .{
            "9",
            \\{"schema_version":3,"profiles":["agent-dag","markdown-document"],"profile_contracts":{"agent_dag":2,"markdown_document":2},"node_types":[{"name":"user_preference","id":20,"parents":["node"]}],"relation_types":[{"name":"based_on","id":9,"class":"prov","src_types":["node"],"dst_types":["node"]}]}
        },
    }) |tampered| {
        try writeSchemaFile(std.testing.io, schema_path, tampered.@"1");
        out.buffer.clearRetainingCapacity();
        try run(&.{ "tinykg", "schema-apply", db_path, "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
        try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "result=rejected") != null);
        const expected = try std.fmt.allocPrint(std.testing.allocator, "conflict kind=endpoint_rule_changed domain=relation id={s}", .{tampered.@"0"});
        defer std.testing.allocator.free(expected);
        try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, expected) != null);
    }
    try writeSchemaFile(std.testing.io, schema_path, current_schema);

    inline for (.{
        .{ "task", "shared endpoint task" },
        .{ "decision", "shared endpoint decision" },
        .{ "verification", "shared endpoint verification" },
        .{ "fix", "shared endpoint rejected target" },
        .{ "project", "shared endpoint rejected source" },
        .{ "evidence", "shared endpoint evidence" },
        .{ "document", "shared endpoint document" },
    }) |fixture| {
        out.buffer.clearRetainingCapacity();
        try run(&.{ "tinykg", "add-node", db_path, fixture.@"0", fixture.@"1" }, &out, std.testing.allocator, std.testing.io);
    }

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "agent-write", db_path, "--src", "1", "--rel", "references", "--dst", "2", "--text", "task references its reviewed decision" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "agent_write src=1 rel=8 dst=2") != null);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-edge", db_path, "2", "based_on", "3" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-edge", db_path, "7", "references", "2" }, &out, std.testing.allocator, std.testing.io);

    var before_rejection: storage.IndexMeta = undefined;
    {
        var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        before_rejection = try store.readIndexMeta();
    }
    out.buffer.clearRetainingCapacity();
    try std.testing.expectError(
        error.SchemaEndpointViolation,
        run(&.{ "tinykg", "agent-write", db_path, "--src", "5", "--rel", "references", "--dst", "6", "--text", "must reject before projection" }, &out, std.testing.allocator, std.testing.io),
    );
    {
        var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        const after_rejection = try store.readIndexMeta();
        try std.testing.expectEqual(before_rejection.nodes, after_rejection.nodes);
        try std.testing.expectEqual(before_rejection.edges, after_rejection.edges);
    }

    inline for (.{
        .{ "1", "references", "4" },
        .{ "6", "based_on", "2" },
        .{ "7", "based_on", "5" },
    }) |edge| {
        out.buffer.clearRetainingCapacity();
        try std.testing.expectError(
            error.SchemaEndpointViolation,
            run(&.{ "tinykg", "add-edge", db_path, edge.@"0", edge.@"1", edge.@"2" }, &out, std.testing.allocator, std.testing.io),
        );
    }

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = batch_path,
        .data =
        \\{"version":1}
        \\{"op":"edge","id":100,"src":5,"rel":"references","dst":6}
        ,
        .flags = .{ .truncate = true },
    });
    out.buffer.clearRetainingCapacity();
    try std.testing.expectError(
        error.SchemaEndpointViolation,
        run(&.{ "tinykg", "apply", db_path, batch_path }, &out, std.testing.allocator, std.testing.io),
    );

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "governance", db_path, "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_edge_endpoint_violations=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_unknown_relation_type_edges=0\n") != null);
}

test "governance schema flags namespaced relation class and endpoint gaps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
    defer std.testing.allocator.free(schema_path);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = schema_path,
        .data =
        \\{
        \\  "relation_types": [
        \\    {"name": "md:h1", "id": 3000, "class": "domain"}
        \\  ]
        \\}
        ,
        .flags = .{ .truncate = true },
    });

    var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer init_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);

    var governance_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer governance_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "governance", db_path, "--schema", schema_path }, &governance_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "schema_relation_namespace_class_mismatches=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "schema_namespaced_relation_endpoint_gaps=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "schema_relation_namespace_class_mismatch_sample rel=md:h1 expected_class=md actual_class=domain\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "schema_namespaced_relation_endpoint_gap_sample rel=md:h1 class=domain\n") != null);
}

test "default markdown projection schema validates endpoints and reports misuse" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);
    const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
    defer std.testing.allocator.free(schema_path);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = schema_path,
        .data =
        \\{
        \\  "profiles": ["markdown-document"]
        \\}
        ,
        .flags = .{ .truncate = true },
    });

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-node", db_path, "document", "doc" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-node", db_path, "document_section", "Shared" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-node", db_path, "document_section", "row" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-node", db_path, "document", "doc2" }, &out, std.testing.allocator, std.testing.io);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-edge", db_path, "1", "md:h1", "2", "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-edge", db_path, "3", "md:table_cell", "2", "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-edge", db_path, "4", "md:paragraph", "2", "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);

    out.buffer.clearRetainingCapacity();
    try std.testing.expectError(
        error.SchemaEndpointViolation,
        run(&.{ "tinykg", "add-edge", db_path, "2", "md:h1", "1", "--schema", schema_path }, &out, std.testing.allocator, std.testing.io),
    );
    out.buffer.clearRetainingCapacity();
    try std.testing.expectError(
        error.SchemaEndpointViolation,
        run(&.{ "tinykg", "add-edge", db_path, "1", "md:table_cell", "2", "--schema", schema_path }, &out, std.testing.allocator, std.testing.io),
    );

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-edge", db_path, "2", "md:h1", "1" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "governance", db_path, "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_edge_endpoint_violations=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_edge_endpoint_violation_sample edge=4 rel=md:h1 src=2 src_kind=document_section dst=1 dst_kind=document\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_namespaced_relation_endpoint_gaps=0\n") != null);
}

test "CLI write commands reject oversized node text without splitting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);

    var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer init_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);

    const oversized = try std.testing.allocator.alloc(u8, node_text_char_limit + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');

    var add_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer add_out.buffer.deinit(std.testing.allocator);
    try std.testing.expectError(error.NodeTextTooLarge, run(&.{ "tinykg", "add-node", db_path, "document", oversized }, &add_out, std.testing.allocator, std.testing.io));

    var stats_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer stats_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "stats", db_path }, &stats_out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("nodes=0 edges=0\n", stats_out.buffer.items);
}

test "governed node metadata stays in formal properties" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-node", db_path, "document", "Visible content", "--schema-type", "content_text", "--summary", "LLM \"hint\"\nsecond line", "--retrieval-hints", "prefer when answering chunking questions" }, &out, std.testing.allocator, std.testing.io);

    {
        var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        var node = (try store.readNodeById(std.testing.allocator, .fromInt(1))) orelse return error.TestExpectedEqual;
        defer node.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("Visible content", node.text);
        const summary = (try store.getNodeStringProperty(std.testing.allocator, .fromInt(1), "summary")) orelse return error.TestExpectedEqual;
        defer std.testing.allocator.free(summary);
        const retrieval_hints = (try store.getNodeStringProperty(std.testing.allocator, .fromInt(1), "retrieval_hints")) orelse return error.TestExpectedEqual;
        defer std.testing.allocator.free(retrieval_hints);
        try std.testing.expectEqualStrings("LLM \"hint\"\nsecond line", summary);
        try std.testing.expectEqualStrings("prefer when answering chunking questions", retrieval_hints);
    }
    try std.testing.expectEqualStrings("Visible content props_text=\"{\"domain_id\":\"tinykg\",\"schema_type\":\"content_text\",\"summary\":\"LLM hint\"}\"", markdownProjectionVisibleText("Visible content props_text=\"{\"domain_id\":\"tinykg\",\"schema_type\":\"content_text\",\"summary\":\"LLM hint\"}\""));

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", db_path, "MATCH (n:document) WHERE n.retrieval_hints = \"prefer when answering chunking questions\" RETURN n.text LIMIT 5" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "Visible content") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "retrieval_hints") == null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-node", db_path, "command", "typed task event", "--schema-type", "task_event" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "set-uint-property", db_path, "node", "2", "task_event_ns", "456" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "set-uint-property", db_path, "node", "2", "task_root_id", "123" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-node", db_path, "command", "early task event", "--schema-type", "task_event" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "set-uint-property", db_path, "node", "3", "task_event_ns", "455" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "set-uint-property", db_path, "node", "3", "task_root_id", "124" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-node", db_path, "command", "late task event", "--schema-type", "task_event" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "set-uint-property", db_path, "node", "4", "task_event_ns", "457" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "set-uint-property", db_path, "node", "4", "task_root_id", "125" }, &out, std.testing.allocator, std.testing.io);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", db_path, "MATCH (n:command) WHERE n.task_root_id = \"123\" RETURN n.text LIMIT 5" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "typed task event") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", db_path, "MATCH (n:command) WHERE n.task_event_ns >= 456 RETURN n.text LIMIT 5" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "typed task event") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", db_path, "MATCH (n:command) WHERE n.task_event_ns >= 456 AND n.task_event_ns < 457 RETURN n.text LIMIT 5" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "typed task event") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", db_path, "MATCH (n:command) WHERE n.task_event_ns > 456 AND n.task_event_ns < 457 RETURN n.text LIMIT 5" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("", out.buffer.items);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", db_path, "MATCH (n:command) WHERE n.task_event_ns >= 455 AND n.task_event_ns < 458 RETURN n.text ORDER BY n.task_event_ns ASC LIMIT 2" }, &out, std.testing.allocator, std.testing.io);
    const early_pos = std.mem.indexOf(u8, out.buffer.items, "early task event") orelse return error.TestExpectedEqual;
    const typed_pos = std.mem.indexOf(u8, out.buffer.items, "typed task event") orelse return error.TestExpectedEqual;
    try std.testing.expect(early_pos < typed_pos);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "late task event") == null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", db_path, "MATCH (n:command) WHERE n.task_event_ns >= 455 RETURN n.text ORDER BY n.task_event_ns DESC LIMIT 2" }, &out, std.testing.allocator, std.testing.io);
    const desc_late_pos = std.mem.indexOf(u8, out.buffer.items, "late task event") orelse return error.TestExpectedEqual;
    const desc_typed_pos = std.mem.indexOf(u8, out.buffer.items, "typed task event") orelse return error.TestExpectedEqual;
    try std.testing.expect(desc_late_pos < desc_typed_pos);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "early task event") == null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-edge", db_path, "1", "references", "2" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-edge", db_path, "1", "references", "3" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-edge", db_path, "1", "references", "4" }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", db_path, "MATCH (d:document)-[:references]->(n:command) RETURN n.text ORDER BY n.task_event_ns DESC LIMIT 2" }, &out, std.testing.allocator, std.testing.io);
    const expand_late_pos = std.mem.indexOf(u8, out.buffer.items, "late task event") orelse return error.TestExpectedEqual;
    const expand_typed_pos = std.mem.indexOf(u8, out.buffer.items, "typed task event") orelse return error.TestExpectedEqual;
    try std.testing.expect(expand_late_pos < expand_typed_pos);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "early task event") == null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", db_path, "MATCH (n:command) WHERE n.task_event_ns < 455 RETURN n.text LIMIT 5" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("", out.buffer.items);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", db_path, "MATCH (n:command) WHERE n.task_root_id = \"not-a-number\" RETURN n.text LIMIT 5" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("", out.buffer.items);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "update-node", db_path, "1", "document", "Visible content revised", "--schema-type", "content_text", "--summary", "new summary", "--retrieval-hints", "prefer when answering chunking questions" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "new=5") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", db_path, "MATCH (n:document) WHERE n.retrieval_hints = \"prefer when answering chunking questions\" RETURN n.text LIMIT 5" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "Visible content revised") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "Visible content props_text") == null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "set-node-property", db_path, "5", "summary", "overlay generated summary" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_property node=5 key=summary") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", db_path, "MATCH (n:document) WHERE n.summary = \"overlay generated summary\" RETURN n.text LIMIT 5" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "Visible content revised") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", db_path, "MATCH (n:document) WHERE n.summary = \"new summary\" RETURN n.text LIMIT 5" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("", out.buffer.items);

    {
        var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        var latest = (try store.readNodeById(std.testing.allocator, .fromInt(5))) orelse return error.TestExpectedEqual;
        defer latest.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("Visible content revised", markdownProjectionVisibleText(latest.text));
    }

    const visible_limit_text = try std.testing.allocator.alloc(u8, node_text_char_limit);
    defer std.testing.allocator.free(visible_limit_text);
    @memset(visible_limit_text, 'v');

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-node", db_path, "document", visible_limit_text, "--schema-type", "content_text", "--summary", "short generated summary", "--retrieval-hints", "short generated hint" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node ") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "governance", db_path }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "oversized_text_nodes=0\n") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-node", db_path, "observation", "short", "--name", "Short label", "--summary", "agent summary", "--retrieval-hints", "needs domain later" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node ") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", db_path, "MATCH (n:observation) WHERE n.name = \"Short label\" RETURN n.name, n.summary, n.text LIMIT 5" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "Short label\tagent summary\tshort") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", db_path, "MATCH (n:observation) WHERE n.name = \"short\" RETURN n.text LIMIT 5" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("", out.buffer.items);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", db_path, "MATCH (n:observation) WHERE n.text = \"short\" RETURN n.name, n.text LIMIT 5" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "Short label\tshort") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "query", db_path, "MATCH (n:document) WHERE n.name = \"\" RETURN n.text LIMIT 1" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "Visible content") != null);

    const oversized_summary = try std.testing.allocator.alloc(u8, node_text_char_limit + 1);
    defer std.testing.allocator.free(oversized_summary);
    @memset(oversized_summary, 's');

    out.buffer.clearRetainingCapacity();
    try std.testing.expectError(
        error.NodePropertyTooLarge,
        run(&.{ "tinykg", "add-node", db_path, "observation", "short", "--summary", oversized_summary }, &out, std.testing.allocator, std.testing.io),
    );
}

test "Markdown bootstrap cleans every allocation failure before publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const markdown_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "doc.md" });
    defer std.testing.allocator.free(markdown_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = markdown_path,
        .data = "# Allocation\n\nNo partial store may escape.\n",
        .flags = .{ .truncate = true },
    });

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    var saw_allocation_failure = false;
    var reached_success = false;
    for (0..2048) |fail_index| {
        const db_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/oom-markdown-{}.kg", .{ root_path, fail_index });
        defer std.testing.allocator.free(db_path);
        const staging_path = try markdownBootstrapStagingPath(std.testing.allocator, db_path);
        defer std.testing.allocator.free(staging_path);
        const marker_path = try markdownBootstrapTransactionPath(std.testing.allocator, db_path);
        defer std.testing.allocator.free(marker_path);
        const marker_tmp_path = try markdownBootstrapTransactionTmpPath(std.testing.allocator, marker_path);
        defer std.testing.allocator.free(marker_tmp_path);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        out.buffer.clearRetainingCapacity();
        run(&.{ "tinykg", "import-md-doc", db_path, markdown_path }, &out, failing.allocator(), std.testing.io) catch |err| switch (err) {
            error.OutOfMemory => {
                saw_allocation_failure = true;
                try std.testing.expect(!try anyPathExists(std.testing.io, db_path));
                try std.testing.expect(!try anyPathExists(std.testing.io, staging_path));
                try std.testing.expect(!try anyPathExists(std.testing.io, marker_path));
                try std.testing.expect(!try anyPathExists(std.testing.io, marker_tmp_path));
                continue;
            },
            else => return err,
        };
        reached_success = true;
        try std.Io.Dir.cwd().deleteTree(std.testing.io, db_path);
        break;
    }
    try std.testing.expect(saw_allocation_failure);
    try std.testing.expect(reached_success);

    const ast_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "doc.ast.json" });
    defer std.testing.allocator.free(ast_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = ast_path,
        .data =
        \\{"type":"root","children":[
        \\  {"type":"heading","depth":1,"children":[{"type":"text","value":"Allocation AST"}]},
        \\  {"type":"paragraph","children":[{"type":"text","value":"No partial AST store may escape."}]}
        \\]}
        ,
        .flags = .{ .truncate = true },
    });
    saw_allocation_failure = false;
    reached_success = false;
    for (0..2048) |fail_index| {
        const db_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/oom-markdown-ast-{}.kg", .{ root_path, fail_index });
        defer std.testing.allocator.free(db_path);
        const staging_path = try markdownBootstrapStagingPath(std.testing.allocator, db_path);
        defer std.testing.allocator.free(staging_path);
        const marker_path = try markdownBootstrapTransactionPath(std.testing.allocator, db_path);
        defer std.testing.allocator.free(marker_path);
        const marker_tmp_path = try markdownBootstrapTransactionTmpPath(std.testing.allocator, marker_path);
        defer std.testing.allocator.free(marker_tmp_path);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        out.buffer.clearRetainingCapacity();
        run(&.{ "tinykg", "import-md-ast", db_path, ast_path }, &out, failing.allocator(), std.testing.io) catch |err| switch (err) {
            error.OutOfMemory => {
                saw_allocation_failure = true;
                try std.testing.expect(!try anyPathExists(std.testing.io, db_path));
                try std.testing.expect(!try anyPathExists(std.testing.io, staging_path));
                try std.testing.expect(!try anyPathExists(std.testing.io, marker_path));
                try std.testing.expect(!try anyPathExists(std.testing.io, marker_tmp_path));
                continue;
            },
            else => return err,
        };
        reached_success = true;
        try std.Io.Dir.cwd().deleteTree(std.testing.io, db_path);
        break;
    }
    try std.testing.expect(saw_allocation_failure);
    try std.testing.expect(reached_success);
}

test "agent memory write commands update delete and governance" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);

    var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer init_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);

    var add_a_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer add_a_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "note", "old task memory" }, &add_a_out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("node 1\n", add_a_out.buffer.items);

    var add_b_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer add_b_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "concept", "supporting note" }, &add_b_out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("node 2\n", add_b_out.buffer.items);

    var edge_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer edge_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-edge", db_path, "1", "supports", "2" }, &edge_out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("edge 1\n", edge_out.buffer.items);

    var support_neighbors_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer support_neighbors_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "neighbors", db_path, "1", "supports" }, &support_neighbors_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, support_neighbors_out.buffer.items, "1\tevidences\t2\t") != null);

    var update_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer update_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "update-node", db_path, "1", "decision", "updated decision memory" }, &update_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, update_out.buffer.items, "updated node=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, update_out.buffer.items, "new=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, update_out.buffer.items, "rel=deprecated_by") != null);
    try std.testing.expect(std.mem.indexOf(u8, update_out.buffer.items, "update_mode=append_only_version") != null);
    try std.testing.expect(std.mem.indexOf(u8, update_out.buffer.items, "store_bytes_before=") != null);
    try std.testing.expect(std.mem.indexOf(u8, update_out.buffer.items, "text_rewarmed=0") != null);

    var get_old_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer get_old_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "get", db_path, "1" }, &get_old_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, get_old_out.buffer.items, "1\tobservation\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_old_out.buffer.items, "old task memory") != null);

    var get_updated_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer get_updated_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "get", db_path, "3" }, &get_updated_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, get_updated_out.buffer.items, "3\tdecision\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_updated_out.buffer.items, "updated decision memory") != null);

    var latest_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer latest_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "node-latest", db_path, "1" }, &latest_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, latest_out.buffer.items, "latest\t2\tdeprecated_by\t1\t3\tdecision\tupdated decision memory") != null);

    var search_updated_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer search_updated_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "search", db_path, "updated decision", "--profile", "agent-memory", "--limit", "4" }, &search_updated_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, search_updated_out.buffer.items, "3\tdecision\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_updated_out.buffer.items, "updated decision memory") != null);

    var search_old_default_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer search_old_default_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "search", db_path, "old task memory", "--profile", "agent-memory", "--limit", "4" }, &search_old_default_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, search_old_default_out.buffer.items, "1\tobservation\t") == null);
    try std.testing.expect(std.mem.indexOf(u8, search_old_default_out.buffer.items, "old task memory") == null);

    var search_old_history_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer search_old_history_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "search", db_path, "old task memory", "--profile", "agent-memory", "--limit", "4", "--include-history" }, &search_old_history_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, search_old_history_out.buffer.items, "1\tobservation\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_old_history_out.buffer.items, "old task memory") != null);

    var query_old_default_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer query_old_default_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "query", db_path, "MATCH TEXT \"old task memory\" AS n RETURN n LIMIT 4", "--profile", "agent-memory" }, &query_old_default_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, query_old_default_out.buffer.items, "1:observation:") == null);
    try std.testing.expect(std.mem.indexOf(u8, query_old_default_out.buffer.items, "old task memory") == null);

    var find_old_default_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer find_old_default_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "find", db_path, "note", "old task memory" }, &find_old_default_out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("not found\n", find_old_default_out.buffer.items);

    var find_old_history_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer find_old_history_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "find", db_path, "note", "old task memory", "--include-history" }, &find_old_history_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, find_old_history_out.buffer.items, "1\tobservation\told task memory") != null);

    var old_neighbors_default_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer old_neighbors_default_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "neighbors", db_path, "1", "supports" }, &old_neighbors_default_out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("", old_neighbors_default_out.buffer.items);

    var old_neighbors_history_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer old_neighbors_history_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "neighbors", db_path, "1", "supports", "--include-history" }, &old_neighbors_history_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, old_neighbors_history_out.buffer.items, "1\tevidences\t2\t") != null);

    var incoming_default_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer incoming_default_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "incoming", db_path, "2", "supports" }, &incoming_default_out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("", incoming_default_out.buffer.items);

    var incoming_history_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer incoming_history_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "incoming", db_path, "2", "supports", "--include-history" }, &incoming_history_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, incoming_history_out.buffer.items, "1\tevidences\t1\told task memory") != null);

    var tinyql_name_default_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer tinyql_name_default_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "query", db_path, "MATCH (n:observation) WHERE n.text = \"old task memory\" RETURN n.text LIMIT 4" }, &tinyql_name_default_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, tinyql_name_default_out.buffer.items, "old task memory") == null);

    var tinyql_expand_default_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer tinyql_expand_default_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "query", db_path, "MATCH (n:observation)-[:evidences]->(m:concept) RETURN m.text LIMIT 4" }, &tinyql_expand_default_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, tinyql_expand_default_out.buffer.items, "supporting note") == null);

    var delete_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer delete_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "delete-node", db_path, "1" }, &delete_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, delete_out.buffer.items, "deleted node=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, delete_out.buffer.items, "rewrite_mode=copy_on_write_full_store") != null);
    try std.testing.expect(std.mem.indexOf(u8, delete_out.buffer.items, "edges_removed=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, delete_out.buffer.items, "text_rewarmed=0 text_index_current=0") != null);

    var get_deleted_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer get_deleted_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "get", db_path, "1" }, &get_deleted_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, get_deleted_out.buffer.items, "1\tedit\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_deleted_out.buffer.items, "__tinykg_deleted_node__ 1") != null);

    var search_deleted_tombstone_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer search_deleted_tombstone_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "search", db_path, "__tinykg_deleted_node__", "--profile", "agent-memory", "--limit", "4" }, &search_deleted_tombstone_out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("", search_deleted_tombstone_out.buffer.items);

    var neighbors_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer neighbors_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "neighbors", db_path, "1" }, &neighbors_out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("", neighbors_out.buffer.items);

    var governance_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer governance_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "governance", db_path }, &governance_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "nodes=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "active_nodes=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "edges=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "isolated_nodes=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "tombstone_nodes=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "tombstone_node_ratio_bps=3333\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "node_kind_count concept=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "node_kind_count decision=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "node_kind_count edit=1\n") != null);

    var kinds_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer kinds_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "list-kinds" }, &kinds_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, kinds_out.buffer.items, "alias note=observation\n") == null);

    var rels_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer rels_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "list-rels" }, &rels_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, rels_out.buffer.items, "alias supports=evidences\n") == null);
}

test "warm store add node is bounded and does not rebuild persistent text files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer init_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);

    var first_add_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer first_add_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "observation", "persistent base sentinel" }, &first_add_out, std.testing.allocator, std.testing.io);

    var rebuild_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer rebuild_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "rebuild-text", db_path }, &rebuild_out, std.testing.allocator, std.testing.io);

    const docs_bytes_before = (try storeFileSize(std.testing.allocator, std.testing.io, db_path, "text_docs.idx")).?;
    const terms_bytes_before = (try storeFileSize(std.testing.allocator, std.testing.io, db_path, "text_terms.idx")).?;
    const postings_bytes_before = (try storeFileSize(std.testing.allocator, std.testing.io, db_path, "text_postings.dat")).?;
    const meta_bytes_before = (try storeFileSize(std.testing.allocator, std.testing.io, db_path, "text_meta.idx")).?;

    var second_add_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer second_add_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "verification", "new node must use read only fallback" }, &second_add_out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("node 2\n", second_add_out.buffer.items);

    try std.testing.expectEqual(docs_bytes_before, (try storeFileSize(std.testing.allocator, std.testing.io, db_path, "text_docs.idx")).?);
    try std.testing.expectEqual(terms_bytes_before, (try storeFileSize(std.testing.allocator, std.testing.io, db_path, "text_terms.idx")).?);
    try std.testing.expectEqual(postings_bytes_before, (try storeFileSize(std.testing.allocator, std.testing.io, db_path, "text_postings.dat")).?);
    try std.testing.expectEqual(meta_bytes_before, (try storeFileSize(std.testing.allocator, std.testing.io, db_path, "text_meta.idx")).?);

    var info_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer info_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "store-info", db_path }, &info_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, info_out.buffer.items, "text_warm=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, info_out.buffer.items, "text_files_present=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, info_out.buffer.items, "text_current=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, info_out.buffer.items, "text_stale=1\n") != null);

    var search_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer search_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "search", db_path, "read only fallback", "--limit", "4" }, &search_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, search_out.buffer.items, "new node must use read only fallback") != null);

    try std.testing.expectEqual(docs_bytes_before, (try storeFileSize(std.testing.allocator, std.testing.io, db_path, "text_docs.idx")).?);
    try std.testing.expectEqual(terms_bytes_before, (try storeFileSize(std.testing.allocator, std.testing.io, db_path, "text_terms.idx")).?);
    try std.testing.expectEqual(postings_bytes_before, (try storeFileSize(std.testing.allocator, std.testing.io, db_path, "text_postings.dat")).?);
    try std.testing.expectEqual(meta_bytes_before, (try storeFileSize(std.testing.allocator, std.testing.io, db_path, "text_meta.idx")).?);
}

test "delete node leaves persistent text catalog stale and search remains correct" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(db_path);

    var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer init_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);

    var add_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer add_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "observation", "erase sentinel should disappear" }, &add_out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("node 1\n", add_out.buffer.items);

    var search_before_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer search_before_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "search", db_path, "erase sentinel", "--profile", "agent-memory", "--limit", "4" }, &search_before_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, search_before_out.buffer.items, "erase sentinel should disappear") != null);

    var delete_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer delete_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "delete-node", db_path, "1" }, &delete_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, delete_out.buffer.items, "deleted node=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, delete_out.buffer.items, "text_rewarmed=0 text_index_current=0") != null);

    var info_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer info_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "store-info", db_path }, &info_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, info_out.buffer.items, "nodes=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, info_out.buffer.items, "text_warm=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, info_out.buffer.items, "text_files_present=0\n") != null);

    var search_after_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer search_after_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "search", db_path, "__tinykg_deleted_node__", "--profile", "agent-memory", "--limit", "4" }, &search_after_out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("", search_after_out.buffer.items);
}

test "governance reports edge tombstone pressure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer init_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);

    var add_a_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer add_a_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "concept", "edge tombstone source" }, &add_a_out, std.testing.allocator, std.testing.io);

    var add_b_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer add_b_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "concept", "edge tombstone middle" }, &add_b_out, std.testing.allocator, std.testing.io);

    var add_c_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer add_c_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-node", db_path, "concept", "edge tombstone target" }, &add_c_out, std.testing.allocator, std.testing.io);

    var edge_one_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer edge_one_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-edge", db_path, "1", "related_to", "2" }, &edge_one_out, std.testing.allocator, std.testing.io);

    var edge_two_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer edge_two_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-edge", db_path, "2", "related_to", "3" }, &edge_two_out, std.testing.allocator, std.testing.io);

    var delete_edge_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer delete_edge_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "delete-edge", db_path, "1" }, &delete_edge_out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("deleted edge 1\n", delete_edge_out.buffer.items);

    var governance_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer governance_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "governance", db_path }, &governance_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "edges=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "physical_edges=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "tombstone_edges=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "tombstone_edge_ratio_bps=5000\n") != null);
}

test "CLI batch deletes edges through tombstone overlay" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer init_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);

    inline for (&.{ "batch delete source", "batch delete middle", "batch delete target" }) |name| {
        var node_out = QueryOutputWriter{ .allocator = std.testing.allocator };
        defer node_out.buffer.deinit(std.testing.allocator);
        try run(&.{ "tinykg", "add-node", db_path, "concept", name }, &node_out, std.testing.allocator, std.testing.io);
    }

    var edge_one_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer edge_one_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-edge", db_path, "1", "related_to", "2" }, &edge_one_out, std.testing.allocator, std.testing.io);

    var edge_two_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer edge_two_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "add-edge", db_path, "2", "related_to", "3" }, &edge_two_out, std.testing.allocator, std.testing.io);

    var delete_edges_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer delete_edges_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "delete-edges", db_path, "1", "2" }, &delete_edges_out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("deleted edges=2\n", delete_edges_out.buffer.items);

    var stats_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer stats_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "stats", db_path }, &stats_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, stats_out.buffer.items, "edges=0") != null);

    var governance_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer governance_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "governance", db_path }, &governance_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "physical_edges=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "tombstone_edges=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "tombstone_edge_ratio_bps=10000\n") != null);
}

test "CLI rejects unknown command without rendering help as success" {
    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.UnknownCommand,
        run(&.{ "tinykg", "statsu" }, &out, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 0), out.buffer.items.len);
}

test "join args rejects length overflow" {
    const huge_ptr: [*]const u8 = @ptrFromInt(1);
    const huge = huge_ptr[0..std.math.maxInt(usize)];
    try std.testing.expectError(error.RecordTooLarge, joinArgs(std.testing.allocator, &.{huge}));
}

test "query output writer enforces byte limit" {
    var out = QueryOutputWriter{ .allocator = std.testing.allocator, .max_bytes = 3 };
    defer out.buffer.deinit(std.testing.allocator);

    try out.writeAll("ab");
    try out.writeAll("c");
    try std.testing.expectEqualStrings("abc", out.buffer.items);
    try std.testing.expectError(error.RecordTooLarge, out.writeAll("d"));
    try std.testing.expectEqualStrings("abc", out.buffer.items);
}

test "bench args require explicit positive scale" {
    const parsed = try parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20" });
    try std.testing.expectEqualStrings("kg", parsed.db_path);
    try std.testing.expectEqual(@as(usize, 10), parsed.nodes);
    try std.testing.expectEqual(@as(usize, 20), parsed.edges);
    try std.testing.expectEqual(@as(usize, default_bench_chunk_size), parsed.chunk_size);
    try std.testing.expectEqual(BenchWorkload.synthetic_ring, parsed.workload);
    try std.testing.expectEqual(BenchEdgeIdPattern.sequential, parsed.edge_id_pattern);
    try std.testing.expect(!parsed.edge_delta_stats);
    try std.testing.expect(!parsed.edge_tombstone_probe);
    try std.testing.expect(!parsed.storage_only);
    try std.testing.expect(!parsed.agent_mixed);
    try std.testing.expect(parsed.corpus_file_path == null);

    const chunked = try parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--chunk", "7" });
    try std.testing.expectEqual(@as(usize, 7), chunked.chunk_size);
    try std.testing.expect(!chunked.storage_only);

    const realistic = try parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--workload", "realistic-agent-text" });
    try std.testing.expectEqual(BenchWorkload.realistic_agent_text, realistic.workload);
    const diverse = try parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--workload", "realistic-agent-diverse-text" });
    try std.testing.expectEqual(BenchWorkload.realistic_agent_diverse_text, diverse.workload);
    const corpus_args = try parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--corpus-file", "docs/sample.txt" });
    try std.testing.expectEqualStrings("docs/sample.txt", corpus_args.corpus_file_path.?);
    const replay_args = try parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--workload", "metaknow-replay", "--corpus-dir", "docs/bench-fixtures/metaknow-export" });
    try std.testing.expectEqual(BenchWorkload.metaknow_replay, replay_args.workload);
    try std.testing.expectEqualStrings("docs/bench-fixtures/metaknow-export", replay_args.corpus_dir_path.?);
    try std.testing.expectError(error.MissingArgument, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--workload", "metaknow-replay" }));
    try std.testing.expectError(core.Error.Unsupported, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--corpus-dir", "docs/bench-fixtures/metaknow-export" }));
    try std.testing.expectError(core.Error.Unsupported, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--workload", "metaknow-replay", "--corpus-dir", "docs/bench-fixtures/metaknow-export", "--agent-mixed" }));
    try std.testing.expectError(error.InvalidLimit, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--workload", "unknown" }));

    const gap_heavy = try parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--edge-id-pattern", "gap-heavy" });
    try std.testing.expectEqual(BenchEdgeIdPattern.gap_heavy, gap_heavy.edge_id_pattern);
    try std.testing.expectError(error.InvalidLimit, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--edge-id-pattern", "unknown" }));

    const edge_delta_stats = try parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--edge-delta-stats" });
    try std.testing.expect(edge_delta_stats.edge_delta_stats);

    const storage_only = try parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--storage-only" });
    try std.testing.expect(storage_only.storage_only);
    try std.testing.expect(!storage_only.agent_mixed);
    try std.testing.expect(!storage_only.edge_tombstone_probe);

    const edge_tombstone_probe = try parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--storage-only", "--edge-tombstone-probe" });
    try std.testing.expect(edge_tombstone_probe.storage_only);
    try std.testing.expect(edge_tombstone_probe.edge_tombstone_probe);
    try std.testing.expectError(core.Error.Unsupported, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--edge-tombstone-probe" }));
    try std.testing.expectError(core.Error.Unsupported, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--storage-only", "--edge-tombstone-probe", "--workload", "metaknow-replay", "--corpus-dir", "docs/bench-fixtures/metaknow-export" }));

    try std.testing.expectError(error.UnknownOption, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--storage-only", "--text-rebuild-runs" }));
    try std.testing.expectError(error.UnknownOption, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--text-rebuild-builder" }));

    const agent_mixed = try parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--agent-mixed" });
    try std.testing.expect(agent_mixed.agent_mixed);
    try std.testing.expect(!agent_mixed.storage_only);
    try std.testing.expectEqual(@as(u32, 0), agent_mixed.edge_compact_batch_entries);
    try std.testing.expectEqual(@as(usize, 0), agent_mixed.maintenance_every_ops);

    const compact_batch = try parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--edge-compact-batch", "32" });
    try std.testing.expectEqual(@as(u32, 32), compact_batch.edge_compact_batch_entries);
    try std.testing.expectEqual(default_bench_edge_compact_threshold_entries, compact_batch.edge_compact_threshold_entries);

    const compact_batch_zero = try parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--edge-compact-batch", "0" });
    try std.testing.expectEqual(@as(u32, 0), compact_batch_zero.edge_compact_batch_entries);

    const compact_threshold = try parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--edge-compact-threshold", "256" });
    try std.testing.expectEqual(@as(u32, 256), compact_threshold.edge_compact_threshold_entries);
    const no_regression = try parseBenchArgs(&.{
        "tinykg",
        "bench",
        "kg",
        "10",
        "20",
        "--max-search-ns",
        "1000",
        "--max-neighbors-ns",
        "2000",
        "--max-tinyql-expand-p95-ns",
        "3000",
        "--max-tinyql-context-render-p95-ns",
        "4000",
        "--max-path-ns",
        "5000",
        "--max-store-overhead-bps",
        "60000",
    });
    try std.testing.expect(no_regression.no_regression_gates.enabled());
    try std.testing.expectEqual(@as(u128, 1000), no_regression.no_regression_gates.max_search_ns.?);
    try std.testing.expectEqual(@as(u128, 2000), no_regression.no_regression_gates.max_neighbors_ns.?);
    try std.testing.expectEqual(@as(u128, 3000), no_regression.no_regression_gates.max_tinyql_expand_p95_ns.?);
    try std.testing.expectEqual(@as(u128, 4000), no_regression.no_regression_gates.max_tinyql_context_render_p95_ns.?);
    try std.testing.expectEqual(@as(u128, 5000), no_regression.no_regression_gates.max_path_ns.?);
    try std.testing.expectEqual(@as(u128, 60000), no_regression.no_regression_gates.max_store_overhead_bps.?);

    const cooperative = try parseBenchArgs(&.{
        "tinykg",
        "bench",
        "kg",
        "10",
        "20",
        "--agent-mixed",
        "--maintenance-every",
        "10",
        "--maintenance-max-segments",
        "8",
        "--maintenance-max-edges",
        "64",
        "--maintenance-gc",
        "--maintenance-node-text-every",
        "5",
        "--maintenance-node-text-max-records",
        "128",
        "--maintenance-node-text-runs-every",
        "6",
        "--maintenance-node-text-runs-max-records",
        "256",
    });
    try std.testing.expect(cooperative.agent_mixed);
    try std.testing.expectEqual(@as(usize, 10), cooperative.maintenance_every_ops);
    try std.testing.expectEqual(@as(usize, 8), cooperative.maintenance_max_segments);
    try std.testing.expectEqual(@as(u64, 64), cooperative.maintenance_max_edges);
    try std.testing.expect(cooperative.maintenance_gc);
    try std.testing.expectEqual(@as(usize, 5), cooperative.maintenance_node_text_every_ops);
    try std.testing.expectEqual(@as(u64, 128), cooperative.maintenance_node_text_max_records);
    try std.testing.expectEqual(@as(usize, 6), cooperative.maintenance_node_text_runs_every_ops);
    try std.testing.expectEqual(@as(u64, 256), cooperative.maintenance_node_text_runs_max_records);

    try std.testing.expectError(core.Error.Unsupported, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--storage-only", "--agent-mixed" }));
    try std.testing.expectError(core.Error.Unsupported, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--storage-only", "--max-search-ns", "1000" }));
    try std.testing.expectError(core.Error.Unsupported, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--agent-mixed", "--max-search-ns", "1000" }));
    try std.testing.expectError(core.Error.Unsupported, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--maintenance-every", "10" }));
    try std.testing.expectError(core.Error.Unsupported, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--agent-mixed", "--maintenance-max-segments", "8" }));
    try std.testing.expectError(core.Error.Unsupported, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--agent-mixed", "--maintenance-gc" }));
    try std.testing.expectError(core.Error.Unsupported, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--maintenance-node-text-every", "5" }));
    try std.testing.expectError(core.Error.Unsupported, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--agent-mixed", "--maintenance-node-text-max-records", "128" }));
    try std.testing.expectError(core.Error.Unsupported, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--maintenance-node-text-runs-every", "5" }));
    try std.testing.expectError(core.Error.Unsupported, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--agent-mixed", "--maintenance-node-text-runs-max-records", "128" }));

    try std.testing.expectError(error.MissingArgument, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10" }));
    try std.testing.expectError(error.UnknownOption, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "extra" }));
    try std.testing.expectError(error.UnknownOption, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--bad", "7" }));
    try std.testing.expectError(error.MissingArgument, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--chunk" }));
    try std.testing.expectError(error.MissingArgument, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--workload" }));
    try std.testing.expectError(error.MissingArgument, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--corpus-file" }));
    try std.testing.expectError(error.MissingArgument, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--edge-id-pattern" }));
    try std.testing.expectError(error.MissingArgument, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--edge-compact-batch" }));
    try std.testing.expectError(error.MissingArgument, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--edge-compact-threshold" }));
    try std.testing.expectError(error.MissingArgument, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--agent-mixed", "--maintenance-every" }));
    try std.testing.expectError(error.MissingArgument, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--agent-mixed", "--maintenance-node-text-every" }));
    try std.testing.expectError(error.MissingArgument, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--agent-mixed", "--maintenance-node-text-max-records" }));
    try std.testing.expectError(error.MissingArgument, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--agent-mixed", "--maintenance-node-text-runs-every" }));
    try std.testing.expectError(error.MissingArgument, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--agent-mixed", "--maintenance-node-text-runs-max-records" }));
    try std.testing.expectError(error.MissingArgument, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--max-search-ns" }));
    try std.testing.expectError(error.InvalidLimit, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--chunk", "0" }));
    try std.testing.expectError(error.InvalidLimit, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--edge-compact-batch", "nope" }));
    try std.testing.expectError(error.InvalidLimit, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--edge-compact-threshold", "nope" }));
    try std.testing.expectError(error.InvalidLimit, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--agent-mixed", "--maintenance-every", "0" }));
    try std.testing.expectError(error.InvalidLimit, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--agent-mixed", "--maintenance-every", "10", "--maintenance-max-edges", "0" }));
    try std.testing.expectError(error.InvalidLimit, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--agent-mixed", "--maintenance-node-text-runs-every", "0" }));
    try std.testing.expectError(error.InvalidLimit, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--agent-mixed", "--maintenance-node-text-runs-every", "5", "--maintenance-node-text-runs-max-records", "0" }));
    try std.testing.expectError(error.InvalidLimit, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--max-search-ns", "0" }));
    try std.testing.expectError(error.InvalidLimit, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "20", "--max-store-overhead-bps", "nope" }));
    try std.testing.expectError(error.InvalidLimit, parseBenchArgs(&.{ "tinykg", "bench", "kg", "0", "20" }));
    try std.testing.expectError(error.InvalidLimit, parseBenchArgs(&.{ "tinykg", "bench", "kg", "10", "nope" }));
}

test "Markdown doc edit benchmark parses and evaluates gates" {
    const parsed = try parseMarkdownDocEditBenchArgs(&.{
        "tinykg",
        "bench-md-doc-edit",
        "kg",
        "24",
        "--edit-index",
        "7",
        "--max-edit-changed-records",
        "3",
        "--max-edit-elapsed-ns",
        "1000",
        "--max-edit-ns-per-paragraph",
        "100",
        "--max-edit-to-initial-bps",
        "7500",
        "--repeat-local-edits",
        "3",
        "--repeat-update-edits",
        "4",
        "--max-repeat-edit-elapsed-ns",
        "4000",
        "--max-repeat-update-edit-elapsed-ns",
        "4500",
        "--agent-mixed-writes",
        "2",
        "--max-render-local-subtree-elapsed-ns",
        "5000",
    });
    try std.testing.expectEqualStrings("kg", parsed.db_path);
    try std.testing.expectEqual(@as(usize, 24), parsed.paragraphs);
    try std.testing.expectEqual(@as(usize, 7), parsed.edit_index);
    try std.testing.expectEqual(@as(usize, 3), parsed.max_edit_changed_records.?);
    try std.testing.expectEqual(@as(u128, 1000), parsed.max_edit_elapsed_ns.?);
    try std.testing.expectEqual(@as(u128, 100), parsed.max_edit_ns_per_paragraph.?);
    try std.testing.expectEqual(@as(u128, 7500), parsed.max_edit_to_initial_bps.?);
    try std.testing.expectEqual(@as(usize, 3), parsed.repeat_local_edits);
    try std.testing.expectEqual(@as(usize, 4), parsed.repeat_update_edits);
    try std.testing.expectEqual(@as(u128, 4000), parsed.max_repeat_edit_elapsed_ns.?);
    try std.testing.expectEqual(@as(u128, 4500), parsed.max_repeat_update_edit_elapsed_ns.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.agent_mixed_writes);
    try std.testing.expectEqual(@as(u128, 5000), parsed.max_render_local_subtree_elapsed_ns.?);

    const passing = evaluateMarkdownDocEditBenchGates(parsed, 20_000, 1_000, 3);
    try std.testing.expectEqual(@as(u128, 42), passing.edit_ns_per_paragraph);
    try std.testing.expectEqual(@as(u128, 500), passing.edit_to_initial_bps);
    try std.testing.expect(passing.passed());

    const too_many_records = evaluateMarkdownDocEditBenchGates(parsed, 20_000, 1_000, 4);
    try std.testing.expect(!too_many_records.changed_records_passed);
    try std.testing.expect(!too_many_records.passed());

    const too_slow = evaluateMarkdownDocEditBenchGates(parsed, 20_000, 20_000, 3);
    try std.testing.expect(!too_slow.elapsed_passed);
    try std.testing.expect(!too_slow.per_paragraph_passed);
    try std.testing.expect(!too_slow.ratio_passed);

    try std.testing.expectError(error.InvalidLimit, parseMarkdownDocEditBenchArgs(&.{ "tinykg", "bench-md-doc-edit", "kg", "24", "--edit-index", "24" }));
    try std.testing.expectError(error.InvalidLimit, parseMarkdownDocEditBenchArgs(&.{ "tinykg", "bench-md-doc-edit", "kg", "24", "--repeat-local-edits", "0" }));
    try std.testing.expectError(error.InvalidLimit, parseMarkdownDocEditBenchArgs(&.{ "tinykg", "bench-md-doc-edit", "kg", "24", "--repeat-update-edits", "0" }));
    try std.testing.expectError(error.InvalidLimit, parseMarkdownDocEditBenchArgs(&.{ "tinykg", "bench-md-doc-edit", "kg", "24", "--max-repeat-edit-elapsed-ns", "nope" }));
    try std.testing.expectError(error.InvalidLimit, parseMarkdownDocEditBenchArgs(&.{ "tinykg", "bench-md-doc-edit", "kg", "24", "--max-repeat-update-edit-elapsed-ns", "nope" }));
    try std.testing.expectError(error.InvalidLimit, parseMarkdownDocEditBenchArgs(&.{ "tinykg", "bench-md-doc-edit", "kg", "24", "--agent-mixed-writes", "0" }));
    try std.testing.expectError(error.InvalidLimit, parseMarkdownDocEditBenchArgs(&.{ "tinykg", "bench-md-doc-edit", "kg", "24", "--max-render-local-subtree-elapsed-ns", "nope" }));
    try std.testing.expectError(error.UnknownOption, parseMarkdownDocEditBenchArgs(&.{ "tinykg", "bench-md-doc-edit", "kg", "24", "--latency" }));
}

test "text context size counts bytes codepoints and newline bytes" {
    const text = "ASCII\n汉字🙂\r\nend";
    const size = try computeTextContextSize(text);
    try std.testing.expectEqual(@as(usize, 21), size.text_bytes);
    try std.testing.expectEqual(@as(usize, 14), size.text_chars);
    try std.testing.expectEqual(@as(usize, 3), size.text_lines);

    const empty = try computeTextContextSize("");
    try std.testing.expectEqual(@as(usize, 0), empty.text_bytes);
    try std.testing.expectEqual(@as(usize, 0), empty.text_chars);
    try std.testing.expectEqual(@as(usize, 0), empty.text_lines);
}

test "get json meta returns node metadata without text by default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        try store.createEmpty();
        try store.appendNodesBatch(&.{
            .{ .id = .fromInt(1), .kind = .task, .text = "ASCII\n汉字🙂\r\nend" },
            .{ .id = .fromInt(2), .kind = .evidence, .text = "child evidence" },
        });
        try store.appendEdgesBatch(&.{
            .{ .id = .fromInt(1), .src = .fromInt(1), .rel = .evidences, .dst = .fromInt(2) },
        });
    }

    var meta_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer meta_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "get", db_path, "1", "--format", "json", "--meta" }, &meta_out, std.testing.allocator, std.testing.io);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, meta_out.buffer.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("tinykg-agent-retrieval-v1", parsed.value.object.get("schema_version").?.string);
    try std.testing.expect(parsed.value.object.get("found").?.bool);
    const node = parsed.value.object.get("node").?.object;
    try std.testing.expectEqual(@as(i64, 1), node.get("id").?.integer);
    try std.testing.expectEqualStrings("task", node.get("kind").?.string);
    try std.testing.expect(node.get("text") == null);
    const context_size = node.get("context_size").?.object;
    try std.testing.expectEqual(@as(i64, 21), context_size.get("text_bytes").?.integer);
    try std.testing.expectEqual(@as(i64, 14), context_size.get("text_chars").?.integer);
    try std.testing.expectEqual(@as(i64, 3), context_size.get("text_lines").?.integer);
    try std.testing.expectEqual(@as(i64, 1), context_size.get("size_version").?.integer);
    try std.testing.expect(node.get("status").?.object.get("current_generation").?.bool);
    try std.testing.expectEqual(@as(i64, 1), node.get("local_graph").?.object.get("out_degree").?.integer);

    var include_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer include_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "node", db_path, "1", "--format", "json", "--meta", "--include-text" }, &include_out, std.testing.allocator, std.testing.io);
    var parsed_include = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, include_out.buffer.items, .{});
    defer parsed_include.deinit();
    try std.testing.expectEqualStrings("ASCII\n汉字🙂\r\nend", parsed_include.value.object.get("node").?.object.get("text").?.string);
}

test "search json meta returns explainable hits without changing text default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        try store.createEmpty();
        try store.appendNodesBatch(&.{
            .{ .id = .fromInt(1), .kind = .task, .text = "agent retrieval control plane alpha" },
            .{ .id = .fromInt(2), .kind = .evidence, .text = "retrieval evidence alpha" },
        });
        try store.appendEdgesBatch(&.{
            .{ .id = .fromInt(1), .src = .fromInt(1), .rel = .evidences, .dst = .fromInt(2) },
        });
    }

    var text_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer text_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "search", db_path, "retrieval alpha", "--profile", "agent-memory", "--limit", "1" }, &text_out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, text_out.buffer.items, "\ttask\t") != null);
    try std.testing.expect(!std.mem.startsWith(u8, text_out.buffer.items, "{"));

    var json_out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer json_out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "search", db_path, "retrieval alpha", "--profile", "agent-memory", "--limit", "1", "--format", "json", "--meta" }, &json_out, std.testing.allocator, std.testing.io);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_out.buffer.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("tinykg-agent-retrieval-v1", parsed.value.object.get("schema_version").?.string);
    try std.testing.expectEqualStrings("retrieval alpha", parsed.value.object.get("query").?.string);
    try std.testing.expectEqualStrings("bm25", parsed.value.object.get("plan").?.object.get("score_model").?.string);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("budget").?.object.get("max_nodes").?.integer);
    const hits = parsed.value.object.get("hits").?.array;
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    const hit = hits.items[0].object;
    try std.testing.expectEqual(@as(i64, 1), hit.get("rank").?.integer);
    try std.testing.expect(hit.get("score").?.float > 0);
    try std.testing.expectEqualStrings("task", hit.get("node").?.object.get("kind").?.string);
    try std.testing.expect(hit.get("node").?.object.get("text") == null);
    try std.testing.expectEqualStrings("bm25", hit.get("why").?.object.get("score_model").?.string);
    try std.testing.expectEqual(@as(usize, 2), hit.get("continuations").?.array.items.len);
    try std.testing.expect(parsed.value.object.get("summary").?.object.get("truncated").?.bool);
}

test "lifecycle maintenance args parse all budgets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    try store.createEmpty();

    const parsed = try parseLifecycleMaintenanceArgs(std.testing.allocator, std.testing.io, &.{
        "tinykg",
        "maintain",
        db_path,
        "--edge-max-segments",
        "8",
        "--edge-max-edges",
        "64",
        "--edge-gc",
        "--node-text-max-records",
        "128",
        "--node-text-runs-max-records",
        "256",
        "--node-text-gc",
        "--compact-property-payload",
        "--max-passes",
        "4",
        "--until-clean",
        "--interval-ms",
        "0",
        "--watch",
        "--max-cycles",
        "3",
        "--stop-after-clean-cycles",
        "2",
        "--poll-ms",
        "0",
    });
    try std.testing.expectEqualStrings(db_path, parsed.db_path);
    try std.testing.expectEqual(@as(usize, 8), parsed.edge_max_segments);
    try std.testing.expectEqual(@as(u64, 64), parsed.edge_max_edges);
    try std.testing.expect(parsed.edge_gc);
    try std.testing.expectEqual(@as(u64, 128), parsed.node_text_max_records);
    try std.testing.expectEqual(@as(u64, 256), parsed.node_text_runs_max_records);
    try std.testing.expect(parsed.node_text_gc);
    try std.testing.expect(parsed.compact_property_payload);
    try std.testing.expectEqual(@as(usize, 4), parsed.max_passes);
    try std.testing.expect(parsed.until_clean);
    try std.testing.expectEqual(@as(u64, 0), parsed.interval_ms);
    try std.testing.expect(parsed.watch);
    try std.testing.expectEqual(@as(usize, 3), parsed.max_cycles);
    try std.testing.expectEqual(@as(usize, 2), parsed.stop_after_clean_cycles);
    try std.testing.expectEqual(@as(u64, 0), parsed.poll_ms);

    try std.testing.expectError(error.MissingArgument, parseLifecycleMaintenanceArgs(std.testing.allocator, std.testing.io, &.{
        "tinykg",
        "maintain",
        db_path,
        "--node-text-max-records",
    }));
    try std.testing.expectError(error.InvalidLimit, parseLifecycleMaintenanceArgs(std.testing.allocator, std.testing.io, &.{
        "tinykg",
        "maintain",
        db_path,
        "--node-text-runs-max-records",
        "0",
    }));
    try std.testing.expectError(error.InvalidLimit, parseLifecycleMaintenanceArgs(std.testing.allocator, std.testing.io, &.{
        "tinykg",
        "maintain",
        db_path,
        "--max-passes",
        "0",
    }));
    try std.testing.expectError(error.InvalidLimit, parseLifecycleMaintenanceArgs(std.testing.allocator, std.testing.io, &.{
        "tinykg",
        "maintain",
        db_path,
        "--max-cycles",
        "0",
    }));
    try std.testing.expectError(error.UnknownOption, parseLifecycleMaintenanceArgs(std.testing.allocator, std.testing.io, &.{
        "tinykg",
        "maintain",
        db_path,
        "--bad",
        "1",
    }));
}

test "maintain command reports all lifecycle no-op on empty store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    try store.createEmpty();

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{
        "tinykg",
        "maintain",
        db_path,
        "--edge-max-segments",
        "8",
        "--edge-max-edges",
        "64",
        "--edge-gc",
        "--node-text-max-records",
        "128",
        "--node-text-runs-max-records",
        "256",
        "--node-text-gc",
        "--max-passes",
        "4",
        "--until-clean",
    }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "maintenance cycles=1 passes=1 stopped_clean=true clean_cycles=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_gc_passes=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_texts_compressions=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_text_gc_passes=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "property_payload_compactions=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "last_node_text_run_records_after=0 elapsed_ns=") != null);
}

test "maintain command explicitly compacts property payload delta" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    const task_id = blk: {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        try store.createEmpty();
        const id = try store.addNode(.task, "property maintenance task");
        try store.appendPropertiesBatch(std.testing.allocator, &.{.{
            .owner = .{ .node = id },
            .key = task.status_property,
            .value = .{ .string = "open" },
        }});
        _ = try store.upsertPropertiesBatch(std.testing.allocator, &.{.{
            .owner = .{ .node = id },
            .key = task.status_property,
            .value = .{ .string = "claimed" },
        }});
        _ = try store.upsertPropertiesBatch(std.testing.allocator, &.{.{
            .owner = .{ .node = id },
            .key = task.status_property,
            .value = .{ .string = "completed" },
        }});
        break :blk id;
    };

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{
        "tinykg",
        "maintain",
        db_path,
        "--compact-property-payload",
        "--max-passes",
        "2",
        "--until-clean",
    }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "passes=2 stopped_clean=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "property_payload_compactions=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "property_payload_delta_frames_compacted=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "last_property_payload_live_entries=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "property_payload_cleanup_pending=0") != null);

    var reopened = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
    defer reopened.deinit();
    const status = (try reopened.getNodeStringProperty(std.testing.allocator, task_id, task.status_property)).?;
    defer std.testing.allocator.free(status);
    try std.testing.expectEqualStrings("completed", status);
}

test "maintain command compresses raw node texts after fast ingest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    {
        var store = try storage.Store.initWithOptions(std.testing.allocator, std.testing.io, db_path, .{
            .primary_text_write_mode = .bulk_ingest,
        });
        defer store.deinit();
        try store.createEmpty();

        const text = try std.testing.allocator.alloc(u8, 4096);
        defer std.testing.allocator.free(text);
        @memset(text, 'a');

        var index: usize = 0;
        while (index < 80) : (index += 1) {
            _ = try store.addNode(.file, text);
        }
    }

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{
        "tinykg",
        "maintain",
        db_path,
        "--max-passes",
        "2",
        "--until-clean",
    }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "maintenance cycles=1 passes=2 stopped_clean=true clean_cycles=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_texts_compressions=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_texts_bytes_before_last=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_texts_bytes_after_last=") != null);
}

test "maintain command repeats to max passes without clean stop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    try store.createEmpty();

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{
        "tinykg",
        "maintain",
        db_path,
        "--max-passes",
        "2",
    }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "maintenance cycles=1 passes=2 stopped_clean=false clean_cycles=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_gc_passes=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_text_gc_passes=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "last_node_text_run_records_after=0 elapsed_ns=") != null);
}

test "maintain command watches until clean cycle threshold" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    try store.createEmpty();

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{
        "tinykg",
        "maintain",
        db_path,
        "--watch",
        "--max-cycles",
        "3",
        "--max-passes",
        "2",
        "--until-clean",
        "--stop-after-clean-cycles",
        "2",
    }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "maintenance cycles=2 passes=2 stopped_clean=true clean_cycles=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_gc_passes=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_text_gc_passes=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "last_node_text_run_records_after=0 elapsed_ns=") != null);
}

test "maintain edge segments command reports no-op on empty store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    try store.createEmpty();

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{
        "tinykg",
        "maintain-edge-segments",
        db_path,
        "--max-segments",
        "8",
        "--max-edges",
        "64",
    }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segments_maintenance compacted=false compacted_edges=0 compacted_segments=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "gc_deleted_segments=0 gc_deleted_manifests=0 entries_before=0 entries_after=0 elapsed_ns=") != null);
}

test "node id arguments report stable CLI error" {
    try std.testing.expectError(error.InvalidNodeId, parseNodeIdArg("not-a-node"));
    try std.testing.expectError(error.InvalidNodeId, parseNodeIdArg("18446744073709551616"));

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidNodeId,
        run(&.{ "tinykg", "neighbors", "not-a-node" }, &out, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 0), out.buffer.items.len);
}

test "node read command family preserves real store outputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
        defer store.deinit();
        try store.createEmpty();
        try store.appendNodesBatch(&.{
            .{ .id = .fromInt(1), .kind = .observation, .text = "old read value" },
            .{ .id = .fromInt(2), .kind = .decision, .text = "latest read value" },
        });
        try store.appendEdgesBatch(&.{.{
            .id = .fromInt(1),
            .src = .fromInt(1),
            .rel = .deprecated_by,
            .dst = .fromInt(2),
        }});
    }

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);

    try run(&.{ "tinykg", "get", db_path, "1" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("1\tobservation\told read value\n", out.buffer.items);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "node", db_path, "2" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("2\tdecision\tlatest read value\n", out.buffer.items);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "node-versions", db_path, "1", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_versions\t1\tlimit=8") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "version\t1\tdeprecated_by\t1\t2\tdecision\tlatest read value") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "node-latest", db_path, "1", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_latest\t1\tlimit=8") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "latest\t1\tdeprecated_by\t1\t2\tdecision\tlatest read value") != null);
}

test "init command publishes empty store and canonical manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "initialized.kg" });
    defer std.testing.allocator.free(db_path);
    const rejected_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "rejected.kg" });
    defer std.testing.allocator.free(rejected_path);

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
    const expected_output = try std.fmt.allocPrint(std.testing.allocator, "ready {s}\n", .{db_path});
    defer std.testing.allocator.free(expected_output);
    try std.testing.expectEqualStrings(expected_output, out.buffer.items);

    var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    const stats = try store.stats();
    try std.testing.expectEqual(@as(u64, 0), stats.nodes);
    try std.testing.expectEqual(@as(u64, 0), stats.edges);

    const manifest = try readStoreManifestSummary(std.testing.allocator, std.testing.io, db_path);
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("present", manifest.status);
    try std.testing.expectEqualStrings("2", manifest.storage_format_version);
    try std.testing.expectEqualStrings("3", manifest.schema_version);
    try std.testing.expectEqualStrings("", manifest.enabled_profiles);
    try std.testing.expectEqualStrings("init", manifest.migration_name);
    try std.testing.expectEqualStrings("", manifest.migration_source);

    out.buffer.clearRetainingCapacity();
    try std.testing.expectError(
        error.TooManyArguments,
        run(
            &.{ "tinykg", "init", rejected_path, "unexpected" },
            &out,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), out.buffer.items.len);
    try std.testing.expect(!try anyPathExists(std.testing.io, rejected_path));
}

test "rebuild-text command publishes canonical metrics and warms stale catalog" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "rebuild.kg" });
    defer std.testing.allocator.free(db_path);

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "add-node", db_path, "observation", "catalog warm sentinel" }, &out, std.testing.allocator, std.testing.io);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "store-info", db_path }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_warm=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_stale=1\n") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "rebuild-text", db_path }, &out, std.testing.allocator, std.testing.io);
    const prefix = try std.fmt.allocPrint(std.testing.allocator, "rebuild_text db={s} doc_count=1 ", .{db_path});
    defer std.testing.allocator.free(prefix);
    try std.testing.expect(std.mem.startsWith(u8, out.buffer.items, prefix));
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, " total_text_tokens=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, " term_count=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, " term_bytes=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, " posting_count=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, " elapsed_ns=") != null);

    out.buffer.clearRetainingCapacity();
    try run(&.{ "tinykg", "store-info", db_path }, &out, std.testing.allocator, std.testing.io);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_warm=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_current=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_stale=0\n") != null);

    out.buffer.clearRetainingCapacity();
    try std.testing.expectError(
        error.TooManyArguments,
        run(
            &.{ "tinykg", "rebuild-text", db_path, "unexpected" },
            &out,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), out.buffer.items.len);
}

test "default db path can come from TINYKG_STORE" {
    const custom: []const u8 = "/tmp/custom-tinykg.kg";
    const empty: []const u8 = "";

    try std.testing.expectEqualStrings(default_db_path, defaultDbPathFromEnv(null));
    try std.testing.expectEqualStrings(default_db_path, defaultDbPathFromEnv(empty));
    try std.testing.expectEqualStrings(custom, defaultDbPathFromEnv(custom));
}
