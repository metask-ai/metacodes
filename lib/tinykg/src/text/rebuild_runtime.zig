const std = @import("std");
const builtin = @import("builtin");
const catalog_format_mod = @import("catalog_format.zig");

/// Rebuild control-plane types and publication primitives. Detailed document,
/// posting-run, and catalog construction stays with the owning text façade.
pub fn RebuildRuntime(comptime core: type) type {
    return struct {
        const catalog_format = catalog_format_mod.CatalogFormat(core);
        const PersistentTextMeta = catalog_format.PersistentTextMeta;

        pub const PersistentTextRebuildTimings = struct {
            docs_ns: u128 = 0,
            docs_layout_ns: u128 = 0,
            docs_node_iter_ns: u128 = 0,
            docs_text_read_ns: u128 = 0,
            docs_tokenize_ns: u128 = 0,
            docs_posting_append_ns: u128 = 0,
            docs_posting_append_materialize_ns: u128 = 0,
            docs_posting_append_sweep_ns: u128 = 0,
            docs_posting_append_regular_sampled_ns: u128 = 0,
            docs_posting_append_candidate_lookup_sampled_ns: u128 = 0,
            docs_posting_append_candidate_hit_sampled_ns: u128 = 0,
            docs_posting_append_virtual_hit_sampled_ns: u128 = 0,
            docs_posting_append_variable_hit_sampled_ns: u128 = 0,
            docs_posting_append_variable_freq_sampled_ns: u128 = 0,
            docs_write_ns: u128 = 0,
            docs_node_count: u64 = 0,
            docs_text_bytes: u64 = 0,
            docs_text_inline_count: u64 = 0,
            docs_text_inline_bytes: u64 = 0,
            docs_text_borrowed_count: u64 = 0,
            docs_text_borrowed_bytes: u64 = 0,
            docs_text_alloc_count: u64 = 0,
            docs_text_alloc_bytes: u64 = 0,
            docs_token_count: u64 = 0,
            docs_freq_cache_lookup_count: u64 = 0,
            docs_freq_cache_hit_count: u64 = 0,
            docs_freq_cache_miss_count: u64 = 0,
            docs_freq_cache_entry_count: u64 = 0,
            docs_freq_cache_text_bytes: u64 = 0,
            docs_freq_cache_term_count: u64 = 0,
            docs_freq_cache_term_bytes: u64 = 0,
            docs_posting_append_term_count: u64 = 0,
            docs_posting_append_regular_record_count: u64 = 0,
            docs_posting_append_virtual_candidate_put_count: u64 = 0,
            docs_posting_append_virtual_candidate_hit_count: u64 = 0,
            docs_posting_append_variable_candidate_hit_count: u64 = 0,
            docs_posting_append_variable_freq_append_count: u64 = 0,
            docs_posting_append_candidate_filter_skip_count: u64 = 0,
            docs_posting_append_candidate_lookup_count: u64 = 0,
            docs_posting_append_candidate_cache_hit_count: u64 = 0,
            docs_posting_append_candidate_miss_count: u64 = 0,
            docs_posting_append_candidate_regularized_hit_count: u64 = 0,
            docs_posting_append_materialize_call_count: u64 = 0,
            docs_posting_append_sweep_count: u64 = 0,
            docs_posting_append_regular_sample_count: u64 = 0,
            docs_posting_append_candidate_lookup_sample_count: u64 = 0,
            docs_posting_append_candidate_hit_sample_count: u64 = 0,
            docs_posting_append_virtual_hit_sample_count: u64 = 0,
            docs_posting_append_variable_hit_sample_count: u64 = 0,
            docs_posting_append_variable_freq_sample_count: u64 = 0,
            term_builder_trim_ns: u128 = 0,
            run_finish_ns: u128 = 0,
            run_chunk_sort_ns: u128 = 0,
            run_chunk_write_ns: u128 = 0,
            run_chunk_count: u64 = 0,
            run_chunk_records: u64 = 0,
            run_chunk_peak_record_bytes: u64 = 0,
            run_chunk_peak_term_bytes: u64 = 0,
            run_chunk_peak_scratch_bytes: u64 = 0,
            run_chunk_peak_record_capacity_bytes: u64 = 0,
            run_chunk_peak_term_capacity_bytes: u64 = 0,
            run_chunk_peak_scratch_capacity_bytes: u64 = 0,
            run_record_term_bytes: u64 = 0,
            run_record_inline_capacity_bytes: u64 = 0,
            run_record_term_slack_bytes: u64 = 0,
            run_record_term_cache_hits: u64 = 0,
            run_record_term_cache_saved_bytes: u64 = 0,
            run_record_long_term_count: u64 = 0,
            run_record_max_term_len: u64 = 0,
            run_tmp_regular_file_count: u64 = 0,
            run_tmp_summary_file_count: u64 = 0,
            run_tmp_synthetic_source_count: u64 = 0,
            run_tmp_regular_bytes: u64 = 0,
            run_tmp_summary_bytes: u64 = 0,
            run_tmp_total_bytes: u64 = 0,
            run_derived_tmp_postings_bytes: u64 = 0,
            run_derived_tmp_terms_bytes: u64 = 0,
            run_derived_tmp_blocks_bytes: u64 = 0,
            run_derived_tmp_impacts_bytes: u64 = 0,
            run_derived_tmp_top_hits_bytes: u64 = 0,
            run_derived_tmp_total_bytes: u64 = 0,
            run_inline_singleton_materialized_terms: u64 = 0,
            run_inline_singleton_materialized_records: u64 = 0,
            run_inline_singleton_materialized_bytes: u64 = 0,
            run_term_count: u64 = 0,
            run_block_count: u64 = 0,
            run_top_hit_term_count: u64 = 0,
            run_top_hit_candidate_records: u64 = 0,
            run_top_hit_side_stream_candidate_records: u64 = 0,
            run_top_hit_local_side_stream_candidate_records: u64 = 0,
            run_virtual_all_docs_term_count: u64 = 0,
            run_virtual_all_docs_candidate_records: u64 = 0,
            run_virtual_all_docs_top_hit_cache_doc_scans: u64 = 0,
            run_virtual_all_docs_synthetic_records: u64 = 0,
            run_dense_all_docs_freq_stream_term_count: u64 = 0,
            run_dense_all_docs_freq_stream_candidate_records: u64 = 0,
            run_variable_all_docs_synthetic_records: u64 = 0,
            run_variable_all_docs_freq_stream_cells: u64 = 0,
            run_variable_all_docs_freq_stream_packed_bytes: u64 = 0,
            run_variable_all_docs_freq_stream_rle_bytes: u64 = 0,
            run_variable_all_docs_freq_stream_bitpacked_bytes: u64 = 0,
            run_variable_all_docs_freq_stream_rle_run_count: u64 = 0,
            run_variable_all_docs_freq_stream_max_freq: u32 = 0,
            open_docs_ns: u128 = 0,
            catalog_ns: u128 = 0,
            run_summary_ns: u128 = 0,
            run_derived_ns: u128 = 0,
            run_derived_regular_ns: u128 = 0,
            run_derived_next_sampled_ns: u128 = 0,
            run_derived_next_reader_sampled_ns: u128 = 0,
            run_derived_next_queue_sampled_ns: u128 = 0,
            run_derived_next_child_probe_count: u64 = 0,
            run_derived_next_queue_compare_count: u64 = 0,
            run_derived_inline_singleton_next_sampled_ns: u128 = 0,
            run_derived_inline_singleton_publish_sampled_ns: u128 = 0,
            run_derived_encode_sampled_ns: u128 = 0,
            run_derived_write_sampled_ns: u128 = 0,
            run_derived_block_stats_sampled_ns: u128 = 0,
            run_derived_top_hit_sampled_ns: u128 = 0,
            run_derived_block_flush_sampled_ns: u128 = 0,
            run_derived_global_doc_rank_ns: u128 = 0,
            run_derived_virtual_top_docs_ns: u128 = 0,
            run_derived_virtual_ns: u128 = 0,
            run_derived_dense_ns: u128 = 0,
            run_derived_flush_ns: u128 = 0,
            run_derived_rename_ns: u128 = 0,
            run_derived_virtual_source_terms: u64 = 0,
            run_derived_dense_source_terms: u64 = 0,
            run_derived_inline_singleton_terms: u64 = 0,
            run_derived_virtual_terms: u64 = 0,
            run_derived_dense_terms: u64 = 0,
            run_derived_block_terms: u64 = 0,
            run_derived_inline_singleton_records: u64 = 0,
            run_derived_virtual_records: u64 = 0,
            run_derived_dense_records: u64 = 0,
            run_derived_block_records: u64 = 0,
            run_derived_top_hit_block_evals: u64 = 0,
            run_derived_top_hit_block_skips: u64 = 0,
            run_derived_top_hit_block_not_full_evals: u64 = 0,
            run_derived_top_hit_block_ready_evals: u64 = 0,
            run_derived_top_hit_block_upper_lt_2x_worst: u64 = 0,
            run_derived_top_hit_block_upper_lt_4x_worst: u64 = 0,
            run_derived_top_hit_block_upper_gte_4x_worst: u64 = 0,
            run_derived_top_hit_candidate_evals: u64 = 0,
            run_derived_top_hit_doc_reads: u64 = 0,
            run_derived_top_hit_regular_candidate_evals: u64 = 0,
            run_derived_top_hit_regular_doc_reads: u64 = 0,
            run_derived_top_hit_virtual_candidate_evals: u64 = 0,
            run_derived_top_hit_virtual_doc_reads: u64 = 0,
            run_derived_top_hit_dense_candidate_evals: u64 = 0,
            run_derived_top_hit_dense_doc_reads: u64 = 0,
            run_derived_top_hit_dense_scan_records: u64 = 0,
            run_derived_top_hit_dense_freq_bound_skips: u64 = 0,
            run_derived_top_hit_dense_freq_bound_skip_runs: u64 = 0,
            run_derived_top_hit_regular_term_count: u64 = 0,
            run_derived_top_hit_regular_doc_read_term_count: u64 = 0,
            run_derived_top_hit_regular_top1_doc_reads: u64 = 0,
            run_derived_top_hit_regular_top4_doc_reads: u64 = 0,
            run_derived_top_hit_regular_top8_doc_reads: u64 = 0,
            run_derived_top_hit_regular_top1_candidate_evals: u64 = 0,
            run_derived_top_hit_regular_top4_candidate_evals: u64 = 0,
            run_derived_top_hit_regular_top8_candidate_evals: u64 = 0,
            run_derived_top_hit_regular_heaviest_doc_read_term_postings: u64 = 0,
            run_derived_top_hit_regular_heaviest_doc_read_term_block_evals: u64 = 0,
            run_derived_top_hit_regular_heaviest_doc_read_term_candidate_evals: u64 = 0,
            run_derived_top_hit_regular_constant_terms: u64 = 0,
            run_derived_top_hit_regular_constant_resolved_terms: u64 = 0,
            run_derived_top_hit_regular_constant_unresolved_terms: u64 = 0,
            run_derived_top_hit_regular_constant_candidate_evals: u64 = 0,
            run_derived_top_hit_regular_constant_doc_reads: u64 = 0,
            run_derived_top_hit_regular_nonconstant_candidate_evals: u64 = 0,
            run_derived_top_hit_regular_nonconstant_doc_reads: u64 = 0,
            run_derived_top_hit_regular_constant_resolved_candidate_skips: u64 = 0,
            run_terms_ns: u128 = 0,
            meta_write_ns: u128 = 0,
        };

        pub const PersistentTextRebuildPhase = enum {
            docs_progress,
            docs,
            run_finish,
            scratch_release,
            open_docs,
            catalog,
            meta,
        };

        pub const PersistentTextRebuildObserver = struct {
            context: *anyopaque,
            observe: *const fn (*anyopaque, PersistentTextRebuildPhase) anyerror!void,
        };

        pub const PersistentTextRebuildBenchResult = struct {
            meta: PersistentTextMeta,
            timings: PersistentTextRebuildTimings,
        };

        pub const Internal = struct {
            pub const Lock = struct {
                io: std.Io,
                file: std.Io.File,
                allocator: std.mem.Allocator,
                path: []u8,

                pub fn deinit(self: *Lock) void {
                    self.file.unlock(self.io);
                    self.file.close(self.io);
                    self.allocator.free(self.path);
                    self.path = &.{};
                }
            };

            const rebuild_lock_poll_duration = std.Io.Duration.fromMilliseconds(1);
            var temp_nonce: std.atomic.Value(u64) = .init(0);

            pub fn monotonicNs(io: std.Io) u128 {
                const timestamp = std.Io.Clock.awake.now(io).nanoseconds;
                return if (timestamp < 0) 0 else @intCast(timestamp);
            }

            pub fn elapsedNs(io: std.Io, start: u128) u128 {
                const now = monotonicNs(io);
                return if (now >= start) now - start else 0;
            }

            pub fn recordObserver(
                observer: PersistentTextRebuildObserver,
                phase: PersistentTextRebuildPhase,
            ) !void {
                try observer.observe(observer.context, phase);
            }

            pub fn cleanupPostingRunScratchFiles(
                allocator: std.mem.Allocator,
                io: std.Io,
                runs_base_path: []const u8,
            ) !void {
                const dir_path = std.fs.path.dirname(runs_base_path) orelse ".";
                const base_leaf = std.fs.path.basename(runs_base_path);
                if (base_leaf.len == 0) return error.InvalidRecord;
                const posting_prefix = try std.fmt.allocPrint(allocator, "{s}.posting_run.", .{base_leaf});
                defer allocator.free(posting_prefix);
                const virtual_prefix = try std.fmt.allocPrint(allocator, "{s}.virtual_all_docs.", .{base_leaf});
                defer allocator.free(virtual_prefix);

                var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
                    error.FileNotFound => return,
                    else => |e| return e,
                };
                defer dir.close(io);
                var iter = dir.iterate();
                while (try iter.next(io)) |entry| {
                    if (entry.kind != .file) continue;
                    if (!std.mem.endsWith(u8, entry.name, ".tmp")) continue;
                    const stale =
                        std.mem.startsWith(u8, entry.name, posting_prefix) or
                        std.mem.startsWith(u8, entry.name, virtual_prefix);
                    if (!stale) continue;
                    const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                    defer allocator.free(full_path);
                    try std.Io.Dir.cwd().deleteFile(io, full_path);
                }
            }

            pub fn rebuildLockPath(
                allocator: std.mem.Allocator,
                store_dir_path: []const u8,
            ) ![]u8 {
                return std.fs.path.join(allocator, &.{ store_dir_path, "text_rebuild.lock" });
            }

            pub fn acquireRebuildLockDeadline(
                allocator: std.mem.Allocator,
                io: std.Io,
                store_dir_path: []const u8,
                deadline: anytype,
            ) !Lock {
                const path = try rebuildLockPath(allocator, store_dir_path);
                errdefer allocator.free(path);
                const nonblocking = deadline != .none;
                var file: std.Io.File = undefined;
                while (true) {
                    if (deadline.expired()) return error.BudgetExceeded;
                    file = std.Io.Dir.cwd().createFile(io, path, .{
                        .read = true,
                        .truncate = false,
                        .lock = .exclusive,
                        .lock_nonblocking = nonblocking,
                    }) catch |err| switch (err) {
                        error.WouldBlock => {
                            try std.Io.sleep(io, rebuild_lock_poll_duration, .awake);
                            continue;
                        },
                        else => |e| return e,
                    };
                    break;
                }
                return .{
                    .io = io,
                    .file = file,
                    .allocator = allocator,
                    .path = path,
                };
            }

            pub fn tmpPathFor(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
                const pid = currentProcessIdForTempPath();
                const nonce = temp_nonce.fetchAdd(1, .monotonic);
                return std.fmt.allocPrint(allocator, "{s}.tmp.{d}.{x}", .{ path, pid, nonce });
            }

            fn currentProcessIdForTempPath() u64 {
                return switch (builtin.os.tag) {
                    .windows => 1,
                    .linux => @intCast(std.os.linux.getpid()),
                    else => if (builtin.link_libc) @intCast(std.c.getpid()) else 1,
                };
            }
        };
    };
}

const TestCore = struct {
    pub const NodeKind = enum(u16) {
        file,
        function,
        document,
    };
};

const test_catalog_format = catalog_format_mod.CatalogFormat(TestCore);
const test_runtime = RebuildRuntime(TestCore);

const TestDeadline = union(enum) {
    none,
    immediate,

    fn expired(self: TestDeadline) bool {
        return self == .immediate;
    }
};

const ObserverProbe = struct {
    phases: [7]test_runtime.PersistentTextRebuildPhase = undefined,
    count: usize = 0,
    fail_on: ?test_runtime.PersistentTextRebuildPhase = null,

    fn observe(
        context: *anyopaque,
        phase: test_runtime.PersistentTextRebuildPhase,
    ) anyerror!void {
        const self: *ObserverProbe = @ptrCast(@alignCast(context));
        if (self.fail_on == phase) return error.ObserverFailed;
        self.phases[self.count] = phase;
        self.count += 1;
    }
};

test "rebuild timings and bench result preserve zeroed public contract" {
    const timings = test_runtime.PersistentTextRebuildTimings{};
    inline for (std.meta.fields(test_runtime.PersistentTextRebuildTimings)) |field| {
        try std.testing.expectEqual(@as(field.type, 0), @field(timings, field.name));
    }

    const result = test_runtime.PersistentTextRebuildBenchResult{
        .meta = .{ .doc_count = 7 },
        .timings = timings,
    };
    const catalog_meta: test_catalog_format.PersistentTextMeta = result.meta;
    try std.testing.expectEqual(@as(u64, 7), catalog_meta.doc_count);
    try std.testing.expect(result.timings.meta_write_ns == 0);
}

test "rebuild observer preserves phase order and propagates errors" {
    const Phase = test_runtime.PersistentTextRebuildPhase;
    const expected = [_]Phase{
        .docs_progress,
        .docs,
        .run_finish,
        .scratch_release,
        .open_docs,
        .catalog,
        .meta,
    };
    var probe = ObserverProbe{};
    const observer = test_runtime.PersistentTextRebuildObserver{
        .context = &probe,
        .observe = ObserverProbe.observe,
    };
    for (expected) |phase| try test_runtime.Internal.recordObserver(observer, phase);
    try std.testing.expectEqualSlices(Phase, &expected, probe.phases[0..probe.count]);

    probe.fail_on = .catalog;
    try std.testing.expectError(
        error.ObserverFailed,
        test_runtime.Internal.recordObserver(observer, .catalog),
    );
    try std.testing.expectEqual(expected.len, probe.count);
}

test "persistent text temp paths are unique per writer" {
    const first = try test_runtime.Internal.tmpPathFor(std.testing.allocator, "/tmp/tinykg-text.idx");
    defer std.testing.allocator.free(first);
    const second = try test_runtime.Internal.tmpPathFor(std.testing.allocator, "/tmp/tinykg-text.idx");
    defer std.testing.allocator.free(second);

    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expect(std.mem.startsWith(u8, first, "/tmp/tinykg-text.idx.tmp."));
    try std.testing.expect(std.mem.startsWith(u8, second, "/tmp/tinykg-text.idx.tmp."));
}

test "text posting run scratch cleanup removes only current base files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg.text_posting_runs" });
    defer std.testing.allocator.free(base_path);

    const stale_run = try std.fmt.allocPrint(std.testing.allocator, "{s}.posting_run.0.tmp", .{base_path});
    defer std.testing.allocator.free(stale_run);
    const stale_summary = try std.fmt.allocPrint(std.testing.allocator, "{s}.posting_run.final.summary.tmp", .{base_path});
    defer std.testing.allocator.free(stale_summary);
    const stale_virtual = try std.fmt.allocPrint(std.testing.allocator, "{s}.virtual_all_docs.summary.tmp", .{base_path});
    defer std.testing.allocator.free(stale_virtual);
    const unrelated = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "other.text_posting_runs.posting_run.0.tmp" });
    defer std.testing.allocator.free(unrelated);
    const same_base_non_tmp = try std.fmt.allocPrint(std.testing.allocator, "{s}.posting_run.1.dat", .{base_path});
    defer std.testing.allocator.free(same_base_non_tmp);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = stale_run, .data = "run", .flags = .{ .truncate = true } });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = stale_summary, .data = "summary", .flags = .{ .truncate = true } });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = stale_virtual, .data = "virtual", .flags = .{ .truncate = true } });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = unrelated, .data = "other", .flags = .{ .truncate = true } });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = same_base_non_tmp, .data = "keep", .flags = .{ .truncate = true } });

    try test_runtime.Internal.cleanupPostingRunScratchFiles(std.testing.allocator, std.testing.io, base_path);

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, stale_run, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, stale_summary, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, stale_virtual, .{}));
    try std.Io.Dir.cwd().access(std.testing.io, unrelated, .{});
    try std.Io.Dir.cwd().access(std.testing.io, same_base_non_tmp, .{});
}

test "persistent text rebuild lock rejects expired deadline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg-expired" });
    defer std.testing.allocator.free(store_path);
    try std.Io.Dir.cwd().createDir(std.testing.io, store_path, .default_dir);

    try std.testing.expectError(
        error.BudgetExceeded,
        test_runtime.Internal.acquireRebuildLockDeadline(
            std.testing.allocator,
            std.testing.io,
            store_path,
            @as(TestDeadline, .immediate),
        ),
    );
}

test "persistent text rebuild lock is store local and reusable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);
    try std.Io.Dir.cwd().createDir(std.testing.io, store_path, .default_dir);

    const expected_lock_path = try test_runtime.Internal.rebuildLockPath(std.testing.allocator, store_path);
    defer std.testing.allocator.free(expected_lock_path);

    {
        var rebuild_lock = try test_runtime.Internal.acquireRebuildLockDeadline(
            std.testing.allocator,
            std.testing.io,
            store_path,
            @as(TestDeadline, .none),
        );
        defer rebuild_lock.deinit();
        try std.testing.expectEqualStrings(expected_lock_path, rebuild_lock.path);
    }
    {
        var rebuild_lock = try test_runtime.Internal.acquireRebuildLockDeadline(
            std.testing.allocator,
            std.testing.io,
            store_path,
            @as(TestDeadline, .none),
        );
        defer rebuild_lock.deinit();
        try std.testing.expectEqualStrings(expected_lock_path, rebuild_lock.path);
    }

    var lock_file = try std.Io.Dir.cwd().openFile(std.testing.io, expected_lock_path, .{});
    lock_file.close(std.testing.io);
}
