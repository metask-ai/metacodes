const std = @import("std");

/// Owns one read-only node-text lookup snapshot across the base, delta, and
/// immutable run catalog. The concrete Store supplies persisted formats,
/// decoders, retention registration, caches, and clocks through `Context`;
/// this owner controls snapshot admission, lazy run opening, hash/range and
/// minimum-id pruning, exact-record validation, and bounded result ordering.
pub fn NodeTextLookupViewDataPlane(comptime Context: type) type {
    return struct {
        const Self = @This();
        const Meta = Context.MetaType;
        const Header = Context.HeaderType;
        const Record = Context.RecordType;
        const Manifest = Context.ManifestType;
        const ManifestEntry = Context.ManifestEntryType;
        const NodeId = Context.NodeIdType;
        const NodeKind = Context.NodeKindType;
        const NodeView = Context.NodeViewType;
        const TextsView = Context.TextsViewType;
        const File = Context.FileType;
        const MemoryMap = Context.MemoryMapType;
        const RetentionRegistry = Context.RetentionRegistryType;
        const RetentionWindow = Context.RetentionWindowType;

        pub const Run = struct {
            file: File,
            map: ?*const MemoryMap = null,
            header: Header,
            min_node_id: u64 = 0,
            hash_filter: []const u8 = &.{},
        };

        pub const OpenRun = struct {
            context: Context,
            file: File,
            map: ?MemoryMap = null,
            header: Header,
            min_node_id: u64 = 0,
            hash_filter: []const u8 = &.{},
            owned_hash_filter: []u8 = &.{},

            pub fn open(
                context: Context,
                path: []const u8,
                expected_header: ?Header,
                min_node_id: u64,
                hash_filter: []const u8,
            ) !OpenRun {
                return Self.openPhysicalRun(
                    context,
                    path,
                    expected_header,
                    min_node_id,
                    hash_filter,
                    true,
                );
            }

            pub fn openBorrowedHashFilter(
                context: Context,
                path: []const u8,
                expected_header: ?Header,
                min_node_id: u64,
                hash_filter: []const u8,
            ) !OpenRun {
                return Self.openPhysicalRun(
                    context,
                    path,
                    expected_header,
                    min_node_id,
                    hash_filter,
                    false,
                );
            }

            pub fn deinit(self: *OpenRun) void {
                if (self.map) |*map| Context.destroyMemoryMap(self.context, map);
                Context.closeFile(self.context, self.file);
                Context.freeHashFilter(self.context, self.owned_hash_filter);
                self.owned_hash_filter = &.{};
            }

            pub fn borrowed(self: *const OpenRun) Run {
                return .{
                    .file = self.file,
                    .map = if (self.map) |*mapped| mapped else null,
                    .header = self.header,
                    .min_node_id = self.min_node_id,
                    .hash_filter = self.hash_filter,
                };
            }
        };

        pub const DeltaRunCache = struct {
            run: ?OpenRun = null,

            pub fn clear(self: *DeltaRunCache) void {
                if (self.run) |*run| run.deinit();
                self.* = .{};
            }
        };

        const ViewRun = struct {
            opened: ?OpenRun = null,

            fn deinit(self: *ViewRun) void {
                if (self.opened) |*run| run.deinit();
                self.* = .{};
            }
        };

        pub const LookupTimings = struct {
            lazy_open_meta_ns: u128 = 0,
            lazy_open_delta_header_ns: u128 = 0,
            lazy_open_manifest_ns: u128 = 0,
            lazy_open_base_ns: u128 = 0,
            lazy_open_validate_ns: u128 = 0,
            lazy_open_delta_ns: u128 = 0,
            lazy_open_runs_ns: u128 = 0,
            search_texts_view_ns: u128 = 0,
            search_node_view_ns: u128 = 0,
            hash_ns: u128 = 0,
            lower_bound_ns: u128 = 0,
            lower_bound_probe_count: u64 = 0,
            lower_bound_max_run_ns: u128 = 0,
            lower_bound_max_run_records: u64 = 0,
            lower_bound_max_run_record_len: u16 = 0,
            lower_bound_max_run_flags: u16 = 0,
            lower_bound_max_run_filter_bytes: u64 = 0,
            lower_bound_max_run_min_node_id: u64 = 0,
            scan_ns: u128 = 0,
            scan_record_count: u64 = 0,
            span_view_ns: u128 = 0,
            record_decode_ns: u128 = 0,
            text_view_ns: u128 = 0,
            text_match_ns: u128 = 0,
            text_compare_ns: u128 = 0,
            by_id_validate_ns: u128 = 0,
            materialize_ns: u128 = 0,
            cleanup_ns: u128 = 0,
            run_count: u64 = 0,
            range_skip_count: u64 = 0,
            first_base_probe_count: u64 = 0,
            first_delta_probe_count: u64 = 0,
            first_run_probe_count: u64 = 0,
            first_base_hit_count: u64 = 0,
            first_delta_hit_count: u64 = 0,
            first_run_hit_count: u64 = 0,
            first_base_miss_before_later_hit_count: u64 = 0,
            first_base_filter_skip_count: u64 = 0,

            fn recordLowerBoundRun(self: *LookupTimings, elapsed_ns: u128, run: Run) void {
                self.lower_bound_ns += elapsed_ns;
                if (elapsed_ns > self.lower_bound_max_run_ns) {
                    self.lower_bound_max_run_ns = elapsed_ns;
                    self.lower_bound_max_run_records = run.header.node_count;
                    self.lower_bound_max_run_record_len = run.header.record_len;
                    self.lower_bound_max_run_flags = run.header.flags;
                    self.lower_bound_max_run_filter_bytes = @intCast(run.hash_filter.len);
                    self.lower_bound_max_run_min_node_id = run.min_node_id;
                }
            }
        };

        pub const OpenTimings = struct {
            meta_ns: u128 = 0,
            delta_header_ns: u128 = 0,
            manifest_ns: u128 = 0,
            base_open_ns: u128 = 0,
            validate_ns: u128 = 0,
            delta_open_ns: u128 = 0,
            runs_open_ns: u128 = 0,
            run_entries: u64 = 0,
            runs_open_count: u64 = 0,
        };

        pub const LazyFirst = struct {
            context: Context,
            id: ?NodeId = null,
            meta: Meta,
            node_view: ?NodeView = null,
            texts_view: ?TextsView = null,

            pub fn deinit(self: *LazyFirst) void {
                if (self.texts_view) |*view| Context.deinitTextsView(self.context, view);
                if (self.node_view) |*view| Context.deinitNodeView(self.context, view);
            }
        };

        pub const View = struct {
            context: Context,
            allocator: std.mem.Allocator,
            meta: Meta,
            base: OpenRun,
            delta: ?OpenRun = null,
            runs: std.ArrayList(ViewRun) = .empty,
            run_manifest: Manifest = .{},
            overlay_record_count: u64 = 0,
            node_view: ?NodeView = null,
            texts_view: ?TextsView = null,
            retention_window: ?RetentionWindow = null,

            pub fn deinit(self: *View) void {
                if (self.texts_view) |*view| Context.deinitTextsView(self.context, view);
                if (self.node_view) |*view| Context.deinitNodeView(self.context, view);
                for (self.runs.items) |*run| run.deinit();
                self.runs.deinit(self.allocator);
                if (self.delta) |*run| run.deinit();
                self.base.deinit();
                Context.deinitManifest(self.context, self.allocator, &self.run_manifest);
                if (self.retention_window) |*window| Context.deinitRetentionWindow(window);
                self.retention_window = null;
            }

            pub fn lookupIds(
                self: *View,
                allocator: std.mem.Allocator,
                kind_filter: ?NodeKind,
                text: []const u8,
                max_nodes: usize,
            ) !std.ArrayList(NodeId) {
                const out = std.ArrayList(NodeId).empty;
                if (max_nodes == 0) return out;
                return Self.lookupIdsInView(self, allocator, kind_filter, text, max_nodes, out, null);
            }

            pub fn lookupIdsWithTimings(
                self: *View,
                allocator: std.mem.Allocator,
                kind_filter: ?NodeKind,
                text: []const u8,
                max_nodes: usize,
                timings: *LookupTimings,
            ) !std.ArrayList(NodeId) {
                const out = std.ArrayList(NodeId).empty;
                if (max_nodes == 0) return out;
                return Self.lookupIdsInView(self, allocator, kind_filter, text, max_nodes, out, timings);
            }

            pub fn lookupIdsInto(
                self: *View,
                allocator: std.mem.Allocator,
                kind_filter: ?NodeKind,
                text: []const u8,
                max_nodes: usize,
                out: std.ArrayList(NodeId),
            ) !std.ArrayList(NodeId) {
                return Self.lookupIdsInView(self, allocator, kind_filter, text, max_nodes, out, null);
            }

            pub fn lookupIdsIntoWithTimings(
                self: *View,
                allocator: std.mem.Allocator,
                kind_filter: ?NodeKind,
                text: []const u8,
                max_nodes: usize,
                out: std.ArrayList(NodeId),
                timings: ?*LookupTimings,
            ) !std.ArrayList(NodeId) {
                return Self.lookupIdsInView(self, allocator, kind_filter, text, max_nodes, out, timings);
            }

            pub fn lookupFirstId(self: *View, kind_filter: ?NodeKind, text: []const u8) !?NodeId {
                return Self.lookupFirstInView(self, kind_filter, text, null);
            }

            pub fn lookupFirstIdWithTimings(
                self: *View,
                kind_filter: ?NodeKind,
                text: []const u8,
                timings: *LookupTimings,
            ) !?NodeId {
                return Self.lookupFirstInView(self, kind_filter, text, timings);
            }
        };

        pub fn openPhysicalRun(
            context: Context,
            path: []const u8,
            expected_header: ?Header,
            min_node_id: u64,
            hash_filter: []const u8,
            copy_hash_filter: bool,
        ) !OpenRun {
            const file = try Context.openFile(context, path);
            errdefer Context.closeFile(context, file);
            const header = try Context.readHeader(context, file);
            if (expected_header) |expected| {
                if (!Context.headersIdentifySameRun(expected, header)) return error.InvalidRecord;
            }
            const expected_size = try Context.fileSizeForHeader(header);
            if (try Context.regularFileSize(context, file) != expected_size) return error.InvalidRecord;
            var map = Context.openReadOnlyMemoryMap(context, file, expected_size) catch null;
            errdefer if (map) |*mapped| Context.destroyMemoryMap(context, mapped);
            var owned_hash_filter: []u8 = &.{};
            const run_hash_filter = if (copy_hash_filter and hash_filter.len != 0) blk: {
                owned_hash_filter = try Context.dupeHashFilter(context, hash_filter);
                break :blk owned_hash_filter;
            } else hash_filter;
            errdefer Context.freeHashFilter(context, owned_hash_filter);
            return .{
                .context = context,
                .file = file,
                .map = map,
                .header = header,
                .min_node_id = min_node_id,
                .hash_filter = run_hash_filter,
                .owned_hash_filter = owned_hash_filter,
            };
        }

        pub fn openView(
            context: Context,
            allocator: std.mem.Allocator,
            retention_registry: ?*RetentionRegistry,
            timings: ?*OpenTimings,
        ) !View {
            const meta_start = if (timings != null) Context.monotonicNs(context) else 0;
            const meta = try Context.readCurrentMeta(context);
            if (timings) |t| t.meta_ns += Context.elapsedNs(context, meta_start);

            const base_open_start = if (timings != null) Context.monotonicNs(context) else 0;
            var base = try OpenRun.open(context, Context.basePath(context), null, 0, &.{});
            if (timings) |t| t.base_open_ns += Context.elapsedNs(context, base_open_start);
            errdefer base.deinit();

            if (Context.baseHeaderCoversMeta(base.header, meta)) {
                const validate_start = if (timings != null) Context.monotonicNs(context) else 0;
                if (Context.validateIndexesOnRead(context) and !try Context.nodeIndexValid(context, meta.nodes)) return error.InvalidRecord;
                if (timings) |t| t.validate_ns += Context.elapsedNs(context, validate_start);
                return .{
                    .context = context,
                    .allocator = allocator,
                    .meta = meta,
                    .base = base,
                    .overlay_record_count = 0,
                };
            }

            const delta_header_start = if (timings != null) Context.monotonicNs(context) else 0;
            const delta_header = try Context.readDeltaHeader(context);
            if (timings) |t| t.delta_header_ns += Context.elapsedNs(context, delta_header_start);

            var retention_window: ?RetentionWindow = null;
            errdefer if (retention_window) |*window| Context.deinitRetentionWindow(window);
            const manifest_start = if (timings != null) Context.monotonicNs(context) else 0;
            var manifest = if (retention_registry) |registry| blk: {
                retention_window = try Context.openRetentionWindow(context, registry);
                if (Context.retentionManifestPath(&retention_window.?)) |manifest_path| {
                    break :blk try Context.readManifestFile(context, allocator, manifest_path);
                }
                break :blk Context.emptyManifest();
            } else try Context.readManifest(context, allocator);
            if (timings) |t| t.manifest_ns += Context.elapsedNs(context, manifest_start);
            errdefer Context.deinitManifest(context, allocator, &manifest);
            const run_count = Context.manifestTotalNodeCount(&manifest);
            if (run_count == std.math.maxInt(u64)) return error.InvalidRecord;
            const entries = Context.manifestEntries(&manifest);
            if (timings) |t| t.run_entries = @intCast(entries.len);

            const validate_start = if (timings != null) Context.monotonicNs(context) else 0;
            try validateSnapshot(meta, base.header, delta_header, &manifest, run_count);
            if (Context.validateIndexesOnRead(context) and !try Context.nodeIndexValid(context, meta.nodes)) return error.InvalidRecord;
            if (timings) |t| t.validate_ns += Context.elapsedNs(context, validate_start);

            var delta: ?OpenRun = null;
            errdefer if (delta) |*run| run.deinit();
            if (delta_header.node_count != 0) {
                const delta_open_start = if (timings != null) Context.monotonicNs(context) else 0;
                delta = try OpenRun.open(context, Context.deltaPath(context), delta_header, 0, &.{});
                if (timings) |t| t.delta_open_ns += Context.elapsedNs(context, delta_open_start);
            }

            var runs = std.ArrayList(ViewRun).empty;
            errdefer {
                for (runs.items) |*run| run.deinit();
                runs.deinit(allocator);
            }
            const runs_open_start = if (timings != null) Context.monotonicNs(context) else 0;
            try runs.ensureTotalCapacity(allocator, entries.len);
            var runs_open_count: u64 = 0;
            for (entries) |entry| {
                var run = ViewRun{};
                if (Context.validateIndexesOnRead(context)) {
                    run.opened = try OpenRun.open(
                        context,
                        Context.entryPath(entry),
                        Context.entryHeader(entry),
                        Context.entryMinNodeId(entry),
                        Context.entryHashFilter(entry),
                    );
                    runs_open_count += 1;
                }
                runs.appendAssumeCapacity(run);
            }
            if (timings) |t| {
                t.runs_open_ns += Context.elapsedNs(context, runs_open_start);
                t.runs_open_count = runs_open_count;
            }

            return .{
                .context = context,
                .allocator = allocator,
                .meta = meta,
                .base = base,
                .delta = delta,
                .runs = runs,
                .run_manifest = manifest,
                .overlay_record_count = try std.math.add(u64, delta_header.node_count, run_count),
                .retention_window = retention_window,
            };
        }

        pub fn lookupFirstLazy(
            context: Context,
            allocator: std.mem.Allocator,
            kind_filter: ?NodeKind,
            text: []const u8,
            timings: ?*LookupTimings,
        ) !LazyFirst {
            _ = allocator;
            const meta_start = if (timings != null) Context.monotonicNs(context) else 0;
            const meta = try Context.readCurrentMeta(context);
            if (timings) |t| t.lazy_open_meta_ns += Context.elapsedNs(context, meta_start);
            const hash_start = if (timings != null) Context.monotonicNs(context) else 0;
            const hash = Context.hashText(text);
            if (timings) |t| t.hash_ns += Context.elapsedNs(context, hash_start);

            if (!Context.validateIndexesOnRead(context)) {
                const base_filter_opt = try Context.cachedBaseHashFilter(context);
                if (base_filter_opt) |base_filter| {
                    if (try Context.baseFilterMatchesCurrentBase(context, Context.baseFilterHeader(base_filter)) and
                        !Context.hashFilterMayContain(Context.baseFilterBytes(base_filter), hash))
                    {
                        if (timings) |t| t.first_base_filter_skip_count += 1;
                        return lookupFirstLazyAfterBaseMiss(
                            context,
                            kind_filter,
                            text,
                            hash,
                            meta,
                            Context.baseFilterHeader(base_filter),
                            timings,
                        );
                    }
                }
            }

            const base_open_start = if (timings != null) Context.monotonicNs(context) else 0;
            var base = try OpenRun.open(context, Context.basePath(context), null, 0, &.{});
            if (timings) |t| t.lazy_open_base_ns += Context.elapsedNs(context, base_open_start);
            defer base.deinit();

            if (Context.baseHeaderCoversMeta(base.header, meta)) {
                const validate_start = if (timings != null) Context.monotonicNs(context) else 0;
                if (Context.validateIndexesOnRead(context) and !try Context.nodeIndexValid(context, meta.nodes)) return error.InvalidRecord;
                if (timings) |t| t.lazy_open_validate_ns += Context.elapsedNs(context, validate_start);

                var lookup = LazyFirst{ .context = context, .meta = meta };
                errdefer lookup.deinit();
                if (timings) |t| t.first_base_probe_count += 1;
                try collectFirstRun(
                    context,
                    base.borrowed(),
                    meta,
                    hash,
                    kind_filter,
                    text,
                    &lookup.id,
                    &lookup.node_view,
                    &lookup.texts_view,
                    timings,
                );
                if (lookup.id != null) {
                    if (timings) |t| t.first_base_hit_count += 1;
                }
                return lookup;
            }

            const delta_header_start = if (timings != null) Context.monotonicNs(context) else 0;
            const delta_header = try Context.readDeltaHeader(context);
            if (timings) |t| t.lazy_open_delta_header_ns += Context.elapsedNs(context, delta_header_start);

            const manifest_start = if (timings != null) Context.monotonicNs(context) else 0;
            var empty_manifest = Context.emptyManifest();
            const manifest = (try Context.cachedManifestForMeta(context, meta)) orelse &empty_manifest;
            if (timings) |t| t.lazy_open_manifest_ns += Context.elapsedNs(context, manifest_start);
            const run_count = Context.manifestTotalNodeCount(manifest);
            if (run_count == std.math.maxInt(u64)) return error.InvalidRecord;

            const validate_start = if (timings != null) Context.monotonicNs(context) else 0;
            try validateSnapshot(meta, base.header, delta_header, manifest, run_count);
            if (Context.validateIndexesOnRead(context) and !try Context.nodeIndexValid(context, meta.nodes)) return error.InvalidRecord;
            if (timings) |t| t.lazy_open_validate_ns += Context.elapsedNs(context, validate_start);

            var lookup = LazyFirst{ .context = context, .meta = meta };
            errdefer lookup.deinit();
            if (timings) |t| t.first_base_probe_count += 1;
            try collectFirstRun(
                context,
                base.borrowed(),
                meta,
                hash,
                kind_filter,
                text,
                &lookup.id,
                &lookup.node_view,
                &lookup.texts_view,
                timings,
            );
            const base_missed = lookup.id == null;
            if (!base_missed) {
                if (timings) |t| t.first_base_hit_count += 1;
            }

            if (delta_header.node_count != 0 and
                (lookup.id == null or Context.validateIndexesOnRead(context) or Context.nodeIdToInt(lookup.id.?) != 1))
            {
                const delta_open_start = if (timings != null) Context.monotonicNs(context) else 0;
                var owned_delta: ?OpenRun = null;
                const delta = (try cachedDeltaRun(context, delta_header, Context.deltaRunCache(context))) orelse blk: {
                    owned_delta = try OpenRun.open(context, Context.deltaPath(context), delta_header, 0, &.{});
                    break :blk owned_delta.?.borrowed();
                };
                if (timings) |t| t.lazy_open_delta_ns += Context.elapsedNs(context, delta_open_start);
                defer if (owned_delta) |*run| run.deinit();
                const before_delta = lookup.id;
                if (timings) |t| t.first_delta_probe_count += 1;
                try collectFirstRun(
                    context,
                    delta,
                    meta,
                    hash,
                    kind_filter,
                    text,
                    &lookup.id,
                    &lookup.node_view,
                    &lookup.texts_view,
                    timings,
                );
                if (lookup.id != before_delta) {
                    if (timings) |t| {
                        t.first_delta_hit_count += 1;
                        if (base_missed) t.first_base_miss_before_later_hit_count += 1;
                    }
                }
            }

            const entries = Context.manifestEntries(manifest);
            for (entries, 0..) |entry, entry_index| {
                if (!Context.validateIndexesOnRead(context) and !Context.entryMayContainHash(entry, hash)) {
                    if (timings) |t| t.range_skip_count += 1;
                    continue;
                }
                if (lookup.id) |current| {
                    if (!Context.validateIndexesOnRead(context)) {
                        if (Context.nodeIdToInt(current) == 1) {
                            if (timings) |t| t.range_skip_count += remainingRuns(entries.len, entry_index);
                            break;
                        }
                        if (Context.nodeIdToInt(current) <= Context.entryMinNodeId(entry)) {
                            if (timings) |t| t.range_skip_count += 1;
                            continue;
                        }
                    }
                }
                const run_open_start = if (timings != null) Context.monotonicNs(context) else 0;
                var run = try OpenRun.openBorrowedHashFilter(
                    context,
                    Context.entryPath(entry),
                    Context.entryHeader(entry),
                    Context.entryMinNodeId(entry),
                    Context.entryHashFilter(entry),
                );
                if (timings) |t| t.lazy_open_runs_ns += Context.elapsedNs(context, run_open_start);
                defer run.deinit();
                const before_run = lookup.id;
                if (timings) |t| t.first_run_probe_count += 1;
                try collectFirstRun(
                    context,
                    run.borrowed(),
                    meta,
                    hash,
                    kind_filter,
                    text,
                    &lookup.id,
                    &lookup.node_view,
                    &lookup.texts_view,
                    timings,
                );
                if (lookup.id != before_run) {
                    if (timings) |t| {
                        t.first_run_hit_count += 1;
                        if (base_missed) t.first_base_miss_before_later_hit_count += 1;
                    }
                }
            }
            return lookup;
        }

        pub fn lookupFirstLazyAfterBaseMiss(
            context: Context,
            kind_filter: ?NodeKind,
            text: []const u8,
            hash: u64,
            meta: Meta,
            base_header: Header,
            timings: ?*LookupTimings,
        ) !LazyFirst {
            if (Context.baseHeaderCoversMeta(base_header, meta)) {
                return .{ .context = context, .meta = meta };
            }

            const delta_header_start = if (timings != null) Context.monotonicNs(context) else 0;
            const delta_header = try Context.readDeltaHeader(context);
            if (timings) |t| t.lazy_open_delta_header_ns += Context.elapsedNs(context, delta_header_start);

            const manifest_start = if (timings != null) Context.monotonicNs(context) else 0;
            var empty_manifest = Context.emptyManifest();
            const manifest = (try Context.cachedManifestForMeta(context, meta)) orelse &empty_manifest;
            if (timings) |t| t.lazy_open_manifest_ns += Context.elapsedNs(context, manifest_start);
            const run_count = Context.manifestTotalNodeCount(manifest);
            if (run_count == std.math.maxInt(u64)) return error.InvalidRecord;

            const validate_start = if (timings != null) Context.monotonicNs(context) else 0;
            try validateSnapshot(meta, base_header, delta_header, manifest, run_count);
            if (timings) |t| t.lazy_open_validate_ns += Context.elapsedNs(context, validate_start);

            var lookup = LazyFirst{ .context = context, .meta = meta };
            errdefer lookup.deinit();
            const base_missed = true;

            if (delta_header.node_count != 0) {
                const delta_open_start = if (timings != null) Context.monotonicNs(context) else 0;
                var owned_delta: ?OpenRun = null;
                const delta = (try cachedDeltaRun(context, delta_header, Context.deltaRunCache(context))) orelse blk: {
                    owned_delta = try OpenRun.open(context, Context.deltaPath(context), delta_header, 0, &.{});
                    break :blk owned_delta.?.borrowed();
                };
                if (timings) |t| t.lazy_open_delta_ns += Context.elapsedNs(context, delta_open_start);
                defer if (owned_delta) |*run| run.deinit();
                const before_delta = lookup.id;
                if (timings) |t| t.first_delta_probe_count += 1;
                try collectFirstRun(
                    context,
                    delta,
                    meta,
                    hash,
                    kind_filter,
                    text,
                    &lookup.id,
                    &lookup.node_view,
                    &lookup.texts_view,
                    timings,
                );
                if (lookup.id != before_delta) {
                    if (timings) |t| {
                        t.first_delta_hit_count += 1;
                        if (base_missed) t.first_base_miss_before_later_hit_count += 1;
                    }
                }
            }

            const entries = Context.manifestEntries(manifest);
            for (entries, 0..) |entry, entry_index| {
                if (!Context.entryMayContainHash(entry, hash)) {
                    if (timings) |t| t.range_skip_count += 1;
                    continue;
                }
                if (lookup.id) |current| {
                    if (Context.nodeIdToInt(current) == 1) {
                        if (timings) |t| t.range_skip_count += remainingRuns(entries.len, entry_index);
                        break;
                    }
                    if (Context.nodeIdToInt(current) <= Context.entryMinNodeId(entry)) {
                        if (timings) |t| t.range_skip_count += 1;
                        continue;
                    }
                }
                const run_open_start = if (timings != null) Context.monotonicNs(context) else 0;
                var run = try OpenRun.openBorrowedHashFilter(
                    context,
                    Context.entryPath(entry),
                    Context.entryHeader(entry),
                    Context.entryMinNodeId(entry),
                    Context.entryHashFilter(entry),
                );
                if (timings) |t| t.lazy_open_runs_ns += Context.elapsedNs(context, run_open_start);
                defer run.deinit();
                const before_run = lookup.id;
                if (timings) |t| t.first_run_probe_count += 1;
                try collectFirstRun(
                    context,
                    run.borrowed(),
                    meta,
                    hash,
                    kind_filter,
                    text,
                    &lookup.id,
                    &lookup.node_view,
                    &lookup.texts_view,
                    timings,
                );
                if (lookup.id != before_run) {
                    if (timings) |t| {
                        t.first_run_hit_count += 1;
                        if (base_missed) t.first_base_miss_before_later_hit_count += 1;
                    }
                }
            }
            return lookup;
        }

        pub fn lookupFirstInView(
            view: *View,
            kind_filter: ?NodeKind,
            text: []const u8,
            timings: ?*LookupTimings,
        ) !?NodeId {
            const hash_start = if (timings != null) Context.monotonicNs(view.context) else 0;
            const hash = Context.hashText(text);
            if (timings) |t| t.hash_ns += Context.elapsedNs(view.context, hash_start);
            var best: ?NodeId = null;
            try collectFirstRun(
                view.context,
                view.base.borrowed(),
                view.meta,
                hash,
                kind_filter,
                text,
                &best,
                &view.node_view,
                &view.texts_view,
                timings,
            );
            if (view.delta) |*delta_run| {
                if (best == null or Context.nodeIdToInt(best.?) != 1) {
                    try collectFirstRun(
                        view.context,
                        delta_run.borrowed(),
                        view.meta,
                        hash,
                        kind_filter,
                        text,
                        &best,
                        &view.node_view,
                        &view.texts_view,
                        timings,
                    );
                }
            }
            const entries = Context.manifestEntries(&view.run_manifest);
            for (view.runs.items, 0..) |_, run_index| {
                const entry = entries[run_index];
                if (best) |current| {
                    if (Context.nodeIdToInt(current) == 1) {
                        if (timings) |t| t.range_skip_count += remainingRuns(view.runs.items.len, run_index);
                        break;
                    }
                    if (Context.nodeIdToInt(current) <= Context.entryMinNodeId(entry)) {
                        if (timings) |t| t.range_skip_count += 1;
                        continue;
                    }
                }
                if (!Context.validateIndexesOnRead(view.context) and !Context.entryMayContainHash(entry, hash)) {
                    if (timings) |t| t.range_skip_count += 1;
                    continue;
                }
                const run = try openViewRun(view, run_index, timings);
                try collectFirstRun(
                    view.context,
                    run,
                    view.meta,
                    hash,
                    kind_filter,
                    text,
                    &best,
                    &view.node_view,
                    &view.texts_view,
                    timings,
                );
            }
            return best;
        }

        pub fn lookupIdsInView(
            view: *View,
            allocator: std.mem.Allocator,
            kind_filter: ?NodeKind,
            text: []const u8,
            max_nodes: usize,
            out_init: std.ArrayList(NodeId),
            timings: ?*LookupTimings,
        ) !std.ArrayList(NodeId) {
            var out = out_init;
            errdefer out.deinit(allocator);
            if (max_nodes == 1) {
                if (try lookupFirstInView(view, kind_filter, text, timings)) |id| {
                    try out.append(allocator, id);
                }
                return out;
            }
            const hash_start = if (timings != null) Context.monotonicNs(view.context) else 0;
            const hash = Context.hashText(text);
            if (timings) |t| t.hash_ns += Context.elapsedNs(view.context, hash_start);
            const collect_cap = try overlayCollectCap(max_nodes, view.overlay_record_count);
            try collectRun(
                view.context,
                allocator,
                view.base.borrowed(),
                view.meta,
                hash,
                kind_filter,
                text,
                max_nodes,
                &out,
                &view.node_view,
                &view.texts_view,
                timings,
            );
            if (view.delta) |*delta_run| {
                try collectRun(
                    view.context,
                    allocator,
                    delta_run.borrowed(),
                    view.meta,
                    hash,
                    kind_filter,
                    text,
                    collect_cap,
                    &out,
                    &view.node_view,
                    &view.texts_view,
                    timings,
                );
            }
            const entries = Context.manifestEntries(&view.run_manifest);
            for (view.runs.items, 0..) |_, run_index| {
                const entry = entries[run_index];
                if (!Context.validateIndexesOnRead(view.context) and !Context.entryMayContainHash(entry, hash)) {
                    if (timings) |t| t.range_skip_count += 1;
                    continue;
                }
                const run = try openViewRun(view, run_index, timings);
                try collectRun(
                    view.context,
                    allocator,
                    run,
                    view.meta,
                    hash,
                    kind_filter,
                    text,
                    collect_cap,
                    &out,
                    &view.node_view,
                    &view.texts_view,
                    timings,
                );
            }
            Context.sortNodeIds(out.items);
            if (out.items.len > max_nodes) out.shrinkRetainingCapacity(max_nodes);
            return out;
        }

        pub fn openViewRun(view: *View, run_index: usize, timings: ?*LookupTimings) !Run {
            if (view.runs.items[run_index].opened == null) {
                const entry = Context.manifestEntries(&view.run_manifest)[run_index];
                const run_open_start = if (timings != null) Context.monotonicNs(view.context) else 0;
                view.runs.items[run_index].opened = try OpenRun.openBorrowedHashFilter(
                    view.context,
                    Context.entryPath(entry),
                    Context.entryHeader(entry),
                    Context.entryMinNodeId(entry),
                    Context.entryHashFilter(entry),
                );
                if (timings) |t| t.lazy_open_runs_ns += Context.elapsedNs(view.context, run_open_start);
            }
            return view.runs.items[run_index].opened.?.borrowed();
        }

        pub fn cachedDeltaRun(context: Context, expected_header: Header, cache: *DeltaRunCache) !?Run {
            if (Context.validateIndexesOnRead(context) or expected_header.node_count == 0) return null;
            if (cache.run) |*run| {
                if (Context.headersMatchCache(expected_header, run.header)) return run.borrowed();
                cache.clear();
            }
            cache.run = try OpenRun.open(context, Context.deltaPath(context), expected_header, 0, &.{});
            return cache.run.?.borrowed();
        }

        pub fn refreshDeltaRunCache(context: Context, expected_header: Header, cache: *DeltaRunCache) void {
            cache.clear();
            if (Context.validateIndexesOnRead(context) or expected_header.node_count == 0) return;
            cache.run = OpenRun.open(context, Context.deltaPath(context), expected_header, 0, &.{}) catch null;
        }

        pub fn collectRun(
            context: Context,
            allocator: std.mem.Allocator,
            run: Run,
            meta: Meta,
            hash: u64,
            kind_filter: ?NodeKind,
            text: []const u8,
            max_collect: usize,
            out: *std.ArrayList(NodeId),
            node_view: *?NodeView,
            texts_view: *?TextsView,
            timings: ?*LookupTimings,
        ) !void {
            if (max_collect == 0 or out.items.len >= max_collect) return;
            if (!Context.validateIndexesOnRead(context) and !Context.runMayContainHash(run, hash)) {
                if (timings) |t| t.range_skip_count += 1;
                return;
            }
            if (timings) |t| t.run_count += 1;
            const texts_view_start = if (timings != null) Context.monotonicNs(context) else 0;
            const texts_for_hash = if (Context.headerHasDerivedHash(run.header)) try Context.ensureTextsView(context, texts_view) else null;
            if (timings) |t| t.search_texts_view_ns += Context.elapsedNs(context, texts_view_start);
            const need_full_search_decode = Context.validateIndexesOnRead(context) or Context.headerHasDerivedHash(run.header);
            const node_view_start = if (timings != null) Context.monotonicNs(context) else 0;
            const nodes_for_search = if (need_full_search_decode and Context.headerHasDerivedTextSpan(run.header))
                try Context.ensureNodeView(context, meta, node_view)
            else
                null;
            if (timings) |t| t.search_node_view_ns += Context.elapsedNs(context, node_view_start);
            const lower_bound_start = if (timings != null) Context.monotonicNs(context) else 0;
            var pos = try findHashLowerBound(context, run, hash, texts_for_hash, nodes_for_search, timings);
            if (timings) |t| t.recordLowerBoundRun(Context.elapsedNs(context, lower_bound_start), run);
            const scan_start = if (timings != null) Context.monotonicNs(context) else 0;
            while (pos < run.header.node_count and out.items.len < max_collect) : (pos += 1) {
                if (timings) |t| t.scan_record_count += 1;
                const span_view_start = if (timings != null) Context.monotonicNs(context) else 0;
                const nodes_for_span = if (Context.headerHasDerivedTextSpan(run.header))
                    try Context.ensureNodeView(context, meta, node_view)
                else
                    null;
                if (timings) |t| t.span_view_ns += Context.elapsedNs(context, span_view_start);
                const record_decode_start = if (timings != null) Context.monotonicNs(context) else 0;
                const record = try Context.readRecord(context, run, pos, texts_for_hash, nodes_for_span);
                if (timings) |t| t.record_decode_ns += Context.elapsedNs(context, record_decode_start);
                if (record.hash != hash) break;
                const kind = try Context.recordNodeKind(record);
                if (kind_filter) |filter| {
                    if (kind != filter) continue;
                }
                if (record.text_len != text.len) continue;
                if (!try exactRecordMatches(context, run, meta, record, kind, text, node_view, texts_view, timings)) continue;
                try out.append(allocator, Context.nodeIdFromInt(record.id));
            }
            if (timings) |t| t.scan_ns += Context.elapsedNs(context, scan_start);
        }

        pub fn collectFirstRun(
            context: Context,
            run: Run,
            meta: Meta,
            hash: u64,
            kind_filter: ?NodeKind,
            text: []const u8,
            best: *?NodeId,
            node_view: *?NodeView,
            texts_view: *?TextsView,
            timings: ?*LookupTimings,
        ) !void {
            if (best.*) |current| {
                if (run.min_node_id != 0 and Context.nodeIdToInt(current) <= run.min_node_id) return;
            }
            if (!Context.validateIndexesOnRead(context) and !Context.runMayContainHash(run, hash)) {
                if (timings) |t| t.range_skip_count += 1;
                return;
            }
            if (timings) |t| t.run_count += 1;
            const texts_view_start = if (timings != null) Context.monotonicNs(context) else 0;
            const texts_for_hash = if (Context.headerHasDerivedHash(run.header)) try Context.ensureTextsView(context, texts_view) else null;
            if (timings) |t| t.search_texts_view_ns += Context.elapsedNs(context, texts_view_start);
            const need_full_search_decode = Context.validateIndexesOnRead(context) or Context.headerHasDerivedHash(run.header);
            const node_view_start = if (timings != null) Context.monotonicNs(context) else 0;
            const nodes_for_search = if (need_full_search_decode and Context.headerHasDerivedTextSpan(run.header))
                try Context.ensureNodeView(context, meta, node_view)
            else
                null;
            if (timings) |t| t.search_node_view_ns += Context.elapsedNs(context, node_view_start);
            const lower_bound_start = if (timings != null) Context.monotonicNs(context) else 0;
            var pos = try findHashLowerBound(context, run, hash, texts_for_hash, nodes_for_search, timings);
            if (timings) |t| t.recordLowerBoundRun(Context.elapsedNs(context, lower_bound_start), run);
            const scan_start = if (timings != null) Context.monotonicNs(context) else 0;
            while (pos < run.header.node_count) : (pos += 1) {
                if (timings) |t| t.scan_record_count += 1;
                const span_view_start = if (timings != null) Context.monotonicNs(context) else 0;
                const nodes_for_span = if (Context.headerHasDerivedTextSpan(run.header))
                    try Context.ensureNodeView(context, meta, node_view)
                else
                    null;
                if (timings) |t| t.span_view_ns += Context.elapsedNs(context, span_view_start);
                const record_decode_start = if (timings != null) Context.monotonicNs(context) else 0;
                const record = try Context.readRecord(context, run, pos, texts_for_hash, nodes_for_span);
                if (timings) |t| t.record_decode_ns += Context.elapsedNs(context, record_decode_start);
                if (record.hash != hash) break;
                if (best.*) |current| {
                    if (record.id >= Context.nodeIdToInt(current)) break;
                }
                const kind = try Context.recordNodeKind(record);
                if (kind_filter) |filter| {
                    if (kind != filter) continue;
                }
                if (record.text_len != text.len) continue;
                if (!try exactRecordMatches(context, run, meta, record, kind, text, node_view, texts_view, timings)) continue;
                best.* = Context.nodeIdFromInt(record.id);
            }
            if (timings) |t| t.scan_ns += Context.elapsedNs(context, scan_start);
        }

        pub fn findHashLowerBound(
            context: Context,
            run: Run,
            hash: u64,
            texts_view: ?*const TextsView,
            node_view: ?*const NodeView,
            timings: ?*LookupTimings,
        ) !u64 {
            var lo: u64 = 0;
            var hi: u64 = run.header.node_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (timings) |t| t.lower_bound_probe_count += 1;
                const record_hash = try Context.readRecordHash(context, run, mid, texts_view, node_view);
                if (record_hash < hash) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return lo;
        }

        fn validateSnapshot(meta: Meta, base: Header, delta: Header, manifest: *const Manifest, run_count: u64) !void {
            if (base.node_count + delta.node_count + run_count != meta.nodes) return error.InvalidRecord;
            if ((base.node_digest ^ delta.node_digest ^ Context.manifestNodeDigest(manifest)) != meta.node_digest) return error.InvalidRecord;
            if (Context.manifestCombinedOrderDigest(manifest, base, delta) != meta.node_by_text_order_digest) return error.InvalidRecord;
        }

        fn exactRecordMatches(
            context: Context,
            run: Run,
            meta: Meta,
            record: Record,
            kind: NodeKind,
            text: []const u8,
            node_view: *?NodeView,
            texts_view: *?TextsView,
            timings: ?*LookupTimings,
        ) !bool {
            const text_view_start = if (timings != null) Context.monotonicNs(context) else 0;
            if (!Context.headerHasTextHashUnique(run.header) or Context.validateIndexesOnRead(context)) {
                const texts = try Context.ensureTextsView(context, texts_view);
                if (timings) |t| t.text_view_ns += Context.elapsedNs(context, text_view_start);
                const text_match_start = if (timings != null) Context.monotonicNs(context) else 0;
                const text_compare_start = if (timings != null) Context.monotonicNs(context) else 0;
                const matches = try Context.textsMatch(texts, record.text_offset, record.text_len, text);
                if (timings) |t| t.text_compare_ns += Context.elapsedNs(context, text_compare_start);
                if (timings) |t| t.text_match_ns += Context.elapsedNs(context, text_match_start);
                if (!matches) return false;
            } else if (timings) |t| {
                t.text_view_ns += Context.elapsedNs(context, text_view_start);
            }
            if (Context.headerHasDerivedTextSpan(run.header)) {
                const expected_len = std.math.cast(u32, text.len) orelse return error.InvalidRecord;
                if (record.text_len != expected_len) return error.InvalidRecord;
            } else {
                const by_id_validate_start = if (timings != null) Context.monotonicNs(context) else 0;
                const nodes = try Context.ensureNodeView(context, meta, node_view);
                const by_id = try Context.nodeViewReadRecord(nodes, record.id);
                try Context.validateLookupRecord(record, by_id, kind, text.len);
                if (timings) |t| t.by_id_validate_ns += Context.elapsedNs(context, by_id_validate_start);
            }
            return true;
        }

        fn overlayCollectCap(max_nodes: usize, overlay_record_count: u64) !usize {
            const overlay_collect_cap = std.math.cast(usize, overlay_record_count) orelse return error.BudgetExceeded;
            return std.math.add(usize, max_nodes, overlay_collect_cap) catch return error.BudgetExceeded;
        }

        fn remainingRuns(runs_len: usize, run_index: usize) u64 {
            return @intCast(runs_len - run_index);
        }
    };
}

const TestKind = enum { document, file };

const TestHeader = struct {
    node_count: u64 = 0,
    node_digest: u64 = 0,
    order_digest: u64 = 0,
    record_len: u16 = 32,
    flags: u16 = 0,
    derived_hash: bool = false,
    derived_span: bool = true,
    unique_hash: bool = true,
    may_contain: bool = true,
};

const TestMeta = struct {
    nodes: u64 = 0,
    node_digest: u64 = 0,
    node_by_text_order_digest: u64 = 0,
};

const TestRecord = struct {
    hash: u64 = 0,
    id: u64 = 0,
    text_offset: u64 = 0,
    text_len: u32 = 0,
    kind: TestKind = .document,
};

const TestEntry = struct {
    path: []const u8 = "run0",
    header: TestHeader = .{},
    min_node_id: u64 = 0,
    hash_filter: []const u8 = &.{},
    may_contain: bool = true,
};

const TestManifest = struct {
    entries: [3]TestEntry = .{ .{}, .{}, .{} },
    entry_count: usize = 0,
    total_nodes: u64 = 0,
    node_digest: u64 = 0,
    order_digest: u64 = 0,
};

const TestRunData = struct {
    header: TestHeader = .{},
    records: [4]TestRecord = .{ .{}, .{}, .{}, .{} },
    record_count: usize = 0,
};

const TestNodeView = struct {};
const TestTextsView = struct {};
const TestMemoryMap = struct {};
const TestRetentionRegistry = struct {};
const TestBaseFilter = struct {
    header: TestHeader = .{},
    filter: []const u8 = &.{},
};

const TestFailure = enum {
    none,
    read_meta,
    open_base,
    read_delta,
    open_retention,
    read_manifest,
    validate_index,
};

const TestState = struct {
    allocator: std.mem.Allocator,
    validate: bool = false,
    failure: TestFailure = .none,
    meta: TestMeta = .{},
    delta_header: TestHeader = .{},
    manifest: TestManifest = .{},
    runs: [5]TestRunData = .{ .{}, .{}, .{}, .{}, .{} },
    open_count: usize = 0,
    close_count: usize = 0,
    record_read_count: usize = 0,
    manifest_read_count: usize = 0,
    retention_open_count: usize = 0,
    retention_deinit_count: usize = 0,
    manifest_deinit_count: usize = 0,
    node_view: TestNodeView = .{},
    texts_view: TestTextsView = .{},

    fn setRun(self: *TestState, index: usize, ids: []const u64, text: []const u8) void {
        const hash = TestContext.hashText(text);
        self.runs[index].record_count = ids.len;
        self.runs[index].header = .{
            .node_count = @intCast(ids.len),
            .node_digest = @as(u64, @intCast(index + 1)) * 17,
            .order_digest = @as(u64, @intCast(index + 1)) * 19,
        };
        for (ids, 0..) |id, record_index| {
            self.runs[index].records[record_index] = .{
                .hash = hash,
                .id = id,
                .text_len = @intCast(text.len),
            };
        }
    }

    fn addManifestRun(self: *TestState, file_index: usize, may_contain: bool) void {
        const entry_index = self.manifest.entry_count;
        const path = switch (file_index) {
            2 => "run0",
            3 => "run1",
            4 => "run2",
            else => unreachable,
        };
        self.manifest.entries[entry_index] = .{
            .path = path,
            .header = self.runs[file_index].header,
            .min_node_id = if (self.runs[file_index].record_count == 0) 0 else self.runs[file_index].records[0].id,
            .may_contain = may_contain,
        };
        self.manifest.entry_count += 1;
    }

    fn sealSnapshot(self: *TestState) void {
        var nodes = self.runs[0].header.node_count + self.delta_header.node_count;
        var digest = self.runs[0].header.node_digest ^ self.delta_header.node_digest;
        var run_nodes: u64 = 0;
        var run_digest: u64 = 0;
        for (self.manifest.entries[0..self.manifest.entry_count]) |entry| {
            nodes += entry.header.node_count;
            digest ^= entry.header.node_digest;
            run_nodes += entry.header.node_count;
            run_digest ^= entry.header.node_digest;
        }
        self.manifest.total_nodes = run_nodes;
        self.manifest.node_digest = run_digest;
        self.manifest.order_digest = 777;
        self.meta = .{
            .nodes = nodes,
            .node_digest = digest,
            .node_by_text_order_digest = self.manifest.order_digest,
        };
    }
};

const TestRetentionWindow = struct {
    state: *TestState,
    manifest_path: ?[]const u8 = "retained-manifest",
    active: bool = true,
};

const TestContext = struct {
    pub const MetaType = TestMeta;
    pub const HeaderType = TestHeader;
    pub const RecordType = TestRecord;
    pub const ManifestType = TestManifest;
    pub const ManifestEntryType = TestEntry;
    pub const NodeIdType = u64;
    pub const NodeKindType = TestKind;
    pub const NodeViewType = TestNodeView;
    pub const TextsViewType = TestTextsView;
    pub const FileType = usize;
    pub const MemoryMapType = TestMemoryMap;
    pub const RetentionRegistryType = TestRetentionRegistry;
    pub const RetentionWindowType = TestRetentionWindow;
    pub const BaseFilterType = TestBaseFilter;

    state: *TestState,

    pub fn basePath(_: TestContext) []const u8 {
        return "base";
    }

    pub fn deltaPath(_: TestContext) []const u8 {
        return "delta";
    }

    pub fn validateIndexesOnRead(context: TestContext) bool {
        return context.state.validate;
    }

    pub fn monotonicNs(_: TestContext) u128 {
        return 1;
    }

    pub fn elapsedNs(_: TestContext, _: u128) u128 {
        return 1;
    }

    pub fn openFile(context: TestContext, path: []const u8) !usize {
        if (context.state.failure == .open_base and std.mem.eql(u8, path, "base")) return error.InjectedFailure;
        context.state.open_count += 1;
        if (std.mem.eql(u8, path, "base")) return 0;
        if (std.mem.eql(u8, path, "delta")) return 1;
        if (std.mem.eql(u8, path, "run0")) return 2;
        if (std.mem.eql(u8, path, "run1")) return 3;
        if (std.mem.eql(u8, path, "run2")) return 4;
        return error.FileNotFound;
    }

    pub fn closeFile(context: TestContext, _: usize) void {
        context.state.close_count += 1;
    }

    pub fn readHeader(context: TestContext, file: usize) !TestHeader {
        return context.state.runs[file].header;
    }

    pub fn headersIdentifySameRun(expected: TestHeader, actual: TestHeader) bool {
        return expected.node_count == actual.node_count and
            expected.node_digest == actual.node_digest and
            expected.order_digest == actual.order_digest;
    }

    pub fn headersMatchCache(expected: TestHeader, actual: TestHeader) bool {
        return headersIdentifySameRun(expected, actual);
    }

    pub fn fileSizeForHeader(header: TestHeader) !u64 {
        return header.node_count;
    }

    pub fn regularFileSize(context: TestContext, file: usize) !u64 {
        return context.state.runs[file].header.node_count;
    }

    pub fn openReadOnlyMemoryMap(_: TestContext, _: usize, _: u64) !TestMemoryMap {
        return error.Unsupported;
    }

    pub fn destroyMemoryMap(_: TestContext, _: *TestMemoryMap) void {}

    pub fn dupeHashFilter(context: TestContext, filter: []const u8) ![]u8 {
        return context.state.allocator.dupe(u8, filter);
    }

    pub fn freeHashFilter(context: TestContext, filter: []u8) void {
        context.state.allocator.free(filter);
    }

    pub fn readCurrentMeta(context: TestContext) !TestMeta {
        if (context.state.failure == .read_meta) return error.InjectedFailure;
        return context.state.meta;
    }

    pub fn readDeltaHeader(context: TestContext) !TestHeader {
        if (context.state.failure == .read_delta) return error.InjectedFailure;
        return context.state.delta_header;
    }

    pub fn baseHeaderCoversMeta(header: TestHeader, meta: TestMeta) bool {
        return header.node_count == meta.nodes and
            header.node_digest == meta.node_digest and
            header.order_digest == meta.node_by_text_order_digest;
    }

    pub fn nodeIndexValid(context: TestContext, _: u64) !bool {
        if (context.state.failure == .validate_index) return error.InjectedFailure;
        return true;
    }

    pub fn openRetentionWindow(context: TestContext, _: *TestRetentionRegistry) !TestRetentionWindow {
        if (context.state.failure == .open_retention) return error.InjectedFailure;
        context.state.retention_open_count += 1;
        return .{ .state = context.state };
    }

    pub fn retentionManifestPath(window: *const TestRetentionWindow) ?[]const u8 {
        return window.manifest_path;
    }

    pub fn deinitRetentionWindow(window: *TestRetentionWindow) void {
        if (!window.active) return;
        window.active = false;
        window.state.retention_deinit_count += 1;
    }

    pub fn readManifest(context: TestContext, _: std.mem.Allocator) !TestManifest {
        return readManifestCommon(context);
    }

    pub fn readManifestFile(context: TestContext, _: std.mem.Allocator, _: []const u8) !TestManifest {
        return readManifestCommon(context);
    }

    fn readManifestCommon(context: TestContext) !TestManifest {
        context.state.manifest_read_count += 1;
        if (context.state.failure == .read_manifest) return error.InjectedFailure;
        return context.state.manifest;
    }

    pub fn deinitManifest(context: TestContext, _: std.mem.Allocator, _: *TestManifest) void {
        context.state.manifest_deinit_count += 1;
    }

    pub fn emptyManifest() TestManifest {
        return .{};
    }

    pub fn manifestEntries(manifest: *const TestManifest) []const TestEntry {
        return manifest.entries[0..manifest.entry_count];
    }

    pub fn manifestTotalNodeCount(manifest: *const TestManifest) u64 {
        return manifest.total_nodes;
    }

    pub fn manifestNodeDigest(manifest: *const TestManifest) u64 {
        return manifest.node_digest;
    }

    pub fn manifestCombinedOrderDigest(manifest: *const TestManifest, _: TestHeader, _: TestHeader) u64 {
        return manifest.order_digest;
    }

    pub fn entryPath(entry: TestEntry) []const u8 {
        return entry.path;
    }

    pub fn entryHeader(entry: TestEntry) TestHeader {
        return entry.header;
    }

    pub fn entryMinNodeId(entry: TestEntry) u64 {
        return entry.min_node_id;
    }

    pub fn entryHashFilter(entry: TestEntry) []const u8 {
        return entry.hash_filter;
    }

    pub fn entryMayContainHash(entry: TestEntry, _: u64) bool {
        return entry.may_contain;
    }

    pub fn cachedManifestForMeta(_: TestContext, _: TestMeta) !?*const TestManifest {
        return null;
    }

    pub fn cachedBaseHashFilter(_: TestContext) !?*const TestBaseFilter {
        return null;
    }

    pub fn baseFilterHeader(filter: *const TestBaseFilter) TestHeader {
        return filter.header;
    }

    pub fn baseFilterBytes(filter: *const TestBaseFilter) []const u8 {
        return filter.filter;
    }

    pub fn baseFilterMatchesCurrentBase(_: TestContext, _: TestHeader) !bool {
        return true;
    }

    pub fn hashFilterMayContain(_: []const u8, _: u64) bool {
        return true;
    }

    pub fn hashText(text: []const u8) u64 {
        return std.hash.Wyhash.hash(19, text);
    }

    pub fn deltaRunCache(_: TestContext) *test_plane.DeltaRunCache {
        unreachable;
    }

    pub fn runMayContainHash(run: test_plane.Run, _: u64) bool {
        return run.header.may_contain;
    }

    pub fn headerHasDerivedHash(header: TestHeader) bool {
        return header.derived_hash;
    }

    pub fn headerHasDerivedTextSpan(header: TestHeader) bool {
        return header.derived_span;
    }

    pub fn headerHasTextHashUnique(header: TestHeader) bool {
        return header.unique_hash;
    }

    pub fn ensureTextsView(context: TestContext, view: *?TestTextsView) !*TestTextsView {
        if (view.* == null) view.* = context.state.texts_view;
        return &view.*.?;
    }

    pub fn ensureNodeView(context: TestContext, _: TestMeta, view: *?TestNodeView) !*TestNodeView {
        if (view.* == null) view.* = context.state.node_view;
        return &view.*.?;
    }

    pub fn deinitTextsView(_: TestContext, _: *TestTextsView) void {}
    pub fn deinitNodeView(_: TestContext, _: *TestNodeView) void {}

    pub fn readRecord(
        context: TestContext,
        run: test_plane.Run,
        index: u64,
        _: ?*const TestTextsView,
        _: ?*const TestNodeView,
    ) !TestRecord {
        context.state.record_read_count += 1;
        const run_data = context.state.runs[run.file];
        if (index >= run_data.record_count) return error.InvalidRecord;
        return run_data.records[@intCast(index)];
    }

    pub fn readRecordHash(
        context: TestContext,
        run: test_plane.Run,
        index: u64,
        texts: ?*const TestTextsView,
        nodes: ?*const TestNodeView,
    ) !u64 {
        return (try readRecord(context, run, index, texts, nodes)).hash;
    }

    pub fn recordNodeKind(record: TestRecord) !TestKind {
        return record.kind;
    }

    pub fn textsMatch(_: *const TestTextsView, _: u64, _: u32, _: []const u8) !bool {
        return true;
    }

    pub fn nodeViewReadRecord(_: *const TestNodeView, id: u64) !TestRecord {
        return .{ .id = id };
    }

    pub fn validateLookupRecord(_: TestRecord, _: TestRecord, _: TestKind, _: usize) !void {}

    pub fn nodeIdFromInt(id: u64) u64 {
        return id;
    }

    pub fn nodeIdToInt(id: u64) u64 {
        return id;
    }

    pub fn sortNodeIds(ids: []u64) void {
        std.mem.sort(u64, ids, {}, std.sort.asc(u64));
    }
};

const test_plane = NodeTextLookupViewDataPlane(TestContext);

fn initTestState() TestState {
    return .{ .allocator = std.testing.allocator };
}

fn prepareOverlayState(state: *TestState, base_ids: []const u64, delta_ids: []const u64, run_ids: []const []const u64, text: []const u8) void {
    state.setRun(0, base_ids, text);
    state.setRun(1, delta_ids, text);
    state.delta_header = state.runs[1].header;
    for (run_ids, 0..) |ids, index| {
        const file_index = index + 2;
        state.setRun(file_index, ids, text);
        state.addManifestRun(file_index, true);
    }
    state.sealSnapshot();
}

test "node text lookup data plane opens a base-only snapshot without overlays" {
    var state = initTestState();
    state.setRun(0, &.{ 1, 2 }, "base");
    state.meta = .{
        .nodes = state.runs[0].header.node_count,
        .node_digest = state.runs[0].header.node_digest,
        .node_by_text_order_digest = state.runs[0].header.order_digest,
    };
    var view = try test_plane.openView(.{ .state = &state }, std.testing.allocator, null, null);
    defer view.deinit();
    try std.testing.expectEqual(@as(u64, 0), view.overlay_record_count);
    try std.testing.expectEqual(@as(usize, 0), view.runs.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.manifest_read_count);
}

test "node text lookup data plane transfers retained manifest lifetime only on success" {
    var state = initTestState();
    prepareOverlayState(&state, &.{1}, &.{}, &.{&.{2}}, "retained");
    var registry = TestRetentionRegistry{};
    var view = try test_plane.openView(.{ .state = &state }, std.testing.allocator, &registry, null);
    try std.testing.expectEqual(@as(usize, 1), state.retention_open_count);
    try std.testing.expectEqual(@as(usize, 0), state.retention_deinit_count);
    view.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.retention_deinit_count);
}

test "node text lookup data plane cleans snapshot resources at every open failure" {
    for ([_]TestFailure{ .read_delta, .read_manifest }) |failure| {
        var state = initTestState();
        prepareOverlayState(&state, &.{1}, &.{}, &.{&.{2}}, "failure");
        state.failure = failure;
        var registry = TestRetentionRegistry{};
        const result = test_plane.openView(.{ .state = &state }, std.testing.allocator, &registry, null);
        try std.testing.expectError(error.InjectedFailure, result);
        try std.testing.expectEqual(state.open_count, state.close_count);
        if (failure == .read_manifest) {
            try std.testing.expectEqual(@as(usize, 1), state.retention_deinit_count);
        }
    }
}

test "node text lookup data plane lazily opens only admitted hash ranges" {
    var state = initTestState();
    prepareOverlayState(&state, &.{9}, &.{}, &.{ &.{7}, &.{3} }, "target");
    state.runs[0].records[0].hash = 1;
    state.manifest.entries[0].may_contain = false;
    var view = try test_plane.openView(.{ .state = &state }, std.testing.allocator, null, null);
    defer view.deinit();
    const id = try view.lookupFirstId(null, "target");
    try std.testing.expectEqual(@as(?u64, 3), id);
    try std.testing.expectEqual(@as(usize, 2), state.open_count);
}

test "node text lookup data plane stops after the minimum possible node id" {
    var state = initTestState();
    prepareOverlayState(&state, &.{1}, &.{}, &.{ &.{4}, &.{8} }, "minimum");
    var view = try test_plane.openView(.{ .state = &state }, std.testing.allocator, null, null);
    defer view.deinit();
    const id = try view.lookupFirstId(null, "minimum");
    try std.testing.expectEqual(@as(?u64, 1), id);
    try std.testing.expectEqual(@as(usize, 1), state.open_count);
}

test "node text lookup data plane eagerly opens every run under strict validation" {
    var state = initTestState();
    prepareOverlayState(&state, &.{9}, &.{}, &.{ &.{7}, &.{3} }, "strict");
    state.validate = true;
    var timings = test_plane.OpenTimings{};
    var view = try test_plane.openView(.{ .state = &state }, std.testing.allocator, null, &timings);
    defer view.deinit();
    try std.testing.expectEqual(@as(u64, 2), timings.runs_open_count);
    try std.testing.expectEqual(@as(usize, 3), state.open_count);
}

test "node text lookup data plane keeps the minimum id across base delta and runs" {
    var state = initTestState();
    prepareOverlayState(&state, &.{9}, &.{5}, &.{&.{3}}, "minimum-all");
    var view = try test_plane.openView(.{ .state = &state }, std.testing.allocator, null, null);
    defer view.deinit();
    try std.testing.expectEqual(@as(?u64, 3), try view.lookupFirstId(null, "minimum-all"));
}

test "node text lookup data plane bounds overlays before sorting and truncation" {
    var state = initTestState();
    prepareOverlayState(&state, &.{9}, &.{5}, &.{&.{ 3, 7 }}, "bounded");
    var view = try test_plane.openView(.{ .state = &state }, std.testing.allocator, null, null);
    defer view.deinit();
    var ids = try view.lookupIds(std.testing.allocator, null, "bounded", 2);
    defer ids.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u64, &.{ 3, 5 }, ids.items);
}

test "node text lookup data plane rejects overlay capacity overflow before collection" {
    var state = initTestState();
    state.setRun(0, &.{1}, "overflow");
    state.meta = .{
        .nodes = 1,
        .node_digest = state.runs[0].header.node_digest,
        .node_by_text_order_digest = state.runs[0].header.order_digest,
    };
    var view = try test_plane.openView(.{ .state = &state }, std.testing.allocator, null, null);
    defer view.deinit();
    view.overlay_record_count = std.math.maxInt(u64);
    const reads_before = state.record_read_count;
    try std.testing.expectError(error.BudgetExceeded, view.lookupIds(std.testing.allocator, null, "overflow", 2));
    try std.testing.expectEqual(reads_before, state.record_read_count);
}
