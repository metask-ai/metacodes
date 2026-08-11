const std = @import("std");
const catalog_format_mod = @import("catalog_format.zig");
const rebuild_runtime_mod = @import("rebuild_runtime.zig");

/// Rebuild entry points and phase sequencing. `Ops.ExternalContext` is the
/// data-plane adapter owned by the text façade; this module owns coordination
/// without importing storage or posting-builder implementation details.
pub fn RebuildSession(comptime core: type, comptime storage: type, comptime Ops: type) type {
    return struct {
        const catalog_format = catalog_format_mod.CatalogFormat(core);
        const rebuild_runtime = rebuild_runtime_mod.RebuildRuntime(core);
        const Store = storage.Store;

        pub const PersistentTextMeta = catalog_format.PersistentTextMeta;
        pub const PersistentTextRebuildTimings = rebuild_runtime.PersistentTextRebuildTimings;
        pub const PersistentTextRebuildObserver = rebuild_runtime.PersistentTextRebuildObserver;

        pub fn rebuildPersistentTextCatalog(
            allocator: std.mem.Allocator,
            store: Store,
        ) !PersistentTextMeta {
            var graph_index_repaired = false;
            return Internal.rebuildPersistentTextCatalogWithGraphRepair(
                allocator,
                store,
                &graph_index_repaired,
                .none,
            );
        }

        /// Benchmark hook for the external posting-run rebuild path. Production
        /// rebuild uses the same path, while callers can choose an explicit run
        /// base to compare publication strategies.
        pub fn rebuildPersistentTextCatalogFromRunsForBench(
            allocator: std.mem.Allocator,
            store: Store,
            runs_base_path: []const u8,
        ) !PersistentTextMeta {
            var graph_index_repaired = false;
            return Internal.rebuildPersistentTextCatalogFromRunsWithGraphRepair(
                allocator,
                store,
                runs_base_path,
                &graph_index_repaired,
                .none,
            );
        }

        pub fn rebuildPersistentTextCatalogWithTimingsForBench(
            allocator: std.mem.Allocator,
            store: Store,
            runs_base_path: []const u8,
        ) !rebuild_runtime.PersistentTextRebuildBenchResult {
            return rebuildPersistentTextCatalogWithTimingsAndObserverForBench(
                allocator,
                store,
                runs_base_path,
                null,
            );
        }

        pub fn rebuildPersistentTextCatalogWithTimingsAndObserverForBench(
            allocator: std.mem.Allocator,
            store: Store,
            runs_base_path: []const u8,
            observer: ?PersistentTextRebuildObserver,
        ) !rebuild_runtime.PersistentTextRebuildBenchResult {
            var timings = PersistentTextRebuildTimings{};
            const meta = try Internal.rebuildPersistentTextCatalogFromRunsOnceDeadlineTimed(
                allocator,
                store,
                runs_base_path,
                .none,
                &timings,
                observer,
            );
            return .{ .meta = meta, .timings = timings };
        }

        pub const Internal = struct {
            pub fn rebuildPersistentTextCatalogWithGraphRepair(
                allocator: std.mem.Allocator,
                store: Store,
                graph_index_repaired: *bool,
                deadline: core.QueryDeadline,
            ) !PersistentTextMeta {
                var rebuild_lock = try rebuild_runtime.Internal.acquireRebuildLockDeadline(
                    allocator,
                    store.io,
                    store.dir_path,
                    deadline,
                );
                defer rebuild_lock.deinit();

                const runs_base_path = try postingRunsBasePath(allocator, store);
                defer allocator.free(runs_base_path);
                return rebuildPersistentTextCatalogFromRunsWithGraphRepair(
                    allocator,
                    store,
                    runs_base_path,
                    graph_index_repaired,
                    deadline,
                );
            }

            pub fn postingRunsBasePath(
                allocator: std.mem.Allocator,
                store: Store,
            ) ![]u8 {
                return std.fmt.allocPrint(
                    allocator,
                    "{s}.text_posting_runs",
                    .{store.dir_path},
                );
            }

            pub fn rebuildPersistentTextCatalogFromRunsWithGraphRepair(
                allocator: std.mem.Allocator,
                store: Store,
                runs_base_path: []const u8,
                graph_index_repaired: *bool,
                deadline: core.QueryDeadline,
            ) !PersistentTextMeta {
                return rebuildPersistentTextCatalogFromRunsOnceDeadline(
                    allocator,
                    store,
                    runs_base_path,
                    deadline,
                ) catch |err| switch (err) {
                    error.FileNotFound, error.InvalidRecord => {
                        if (graph_index_repaired.*) return err;
                        graph_index_repaired.* = true;
                        try store.repairPersistentIndexesFromLog();
                        return rebuildPersistentTextCatalogFromRunsOnceDeadline(
                            allocator,
                            store,
                            runs_base_path,
                            deadline,
                        );
                    },
                    else => |other| return other,
                };
            }

            pub fn rebuildPersistentTextCatalogFromRunsOnceDeadline(
                allocator: std.mem.Allocator,
                store: Store,
                runs_base_path: []const u8,
                deadline: core.QueryDeadline,
            ) !PersistentTextMeta {
                return rebuildPersistentTextCatalogFromRunsOnceDeadlineTimed(
                    allocator,
                    store,
                    runs_base_path,
                    deadline,
                    null,
                    null,
                );
            }

            pub fn rebuildPersistentTextCatalogFromRunsOnceDeadlineTimed(
                allocator: std.mem.Allocator,
                store: Store,
                runs_base_path: []const u8,
                deadline: core.QueryDeadline,
                timings: ?*PersistentTextRebuildTimings,
                observer: ?PersistentTextRebuildObserver,
            ) !PersistentTextMeta {
                var context = try Ops.ExternalContext.init(
                    allocator,
                    store,
                    runs_base_path,
                    deadline,
                    timings != null,
                );
                defer context.deinit();
                return runExternalPhases(&context, deadline, timings, observer);
            }

            /// Executes the observable phase protocol against a façade-owned
            /// context. The context exposes phase operations, never its posting
            /// builder or persistent view representation.
            pub fn runExternalPhases(
                context: anytype,
                deadline: core.QueryDeadline,
                timings: ?*PersistentTextRebuildTimings,
                observer: ?PersistentTextRebuildObserver,
            ) !PersistentTextMeta {
                const io = context.clockIo();

                const docs_start = rebuild_runtime.Internal.monotonicNs(io);
                try context.buildDocs(timings, observer);
                if (timings) |value| {
                    value.docs_ns = rebuild_runtime.Internal.elapsedNs(io, docs_start);
                }
                try observe(observer, .docs);

                const finish_start = rebuild_runtime.Internal.monotonicNs(io);
                try context.finishRuns();
                if (timings) |value| {
                    value.run_finish_ns = rebuild_runtime.Internal.elapsedNs(io, finish_start);
                }
                try observe(observer, .run_finish);
                if (timings) |value| try context.captureRunTimings(value);

                if (deadline.expired()) return core.Error.BudgetExceeded;
                context.releaseScratch();
                try observe(observer, .scratch_release);

                const open_docs_start = rebuild_runtime.Internal.monotonicNs(io);
                try context.openDocs();
                if (timings) |value| {
                    value.open_docs_ns = rebuild_runtime.Internal.elapsedNs(io, open_docs_start);
                }
                try observe(observer, .open_docs);

                const catalog_start = rebuild_runtime.Internal.monotonicNs(io);
                const catalog_stats = try context.writeCatalog(timings);
                if (timings) |value| {
                    value.catalog_ns = rebuild_runtime.Internal.elapsedNs(io, catalog_start);
                }
                try observe(observer, .catalog);
                context.applyCatalogStats(catalog_stats);

                if (deadline.expired()) return core.Error.BudgetExceeded;
                const meta_start = rebuild_runtime.Internal.monotonicNs(io);
                try context.writeMeta();
                if (timings) |value| {
                    value.meta_write_ns = rebuild_runtime.Internal.elapsedNs(io, meta_start);
                }
                try observe(observer, .meta);
                context.finishMeta();
                return context.finalMeta();
            }

            fn observe(
                observer: ?PersistentTextRebuildObserver,
                phase: rebuild_runtime.PersistentTextRebuildPhase,
            ) !void {
                if (observer) |value| {
                    try rebuild_runtime.Internal.recordObserver(value, phase);
                }
            }
        };
    };
}

const TestCore = struct {
    pub const Error = error{BudgetExceeded};

    pub const NodeKind = enum(u16) {
        file,
        function,
        document,
    };

    pub const QueryDeadline = union(enum) {
        none,
        flag: *const bool,

        pub fn expired(self: QueryDeadline) bool {
            return switch (self) {
                .none => false,
                .flag => |value| value.*,
            };
        }
    };
};

const TestPhase = rebuild_runtime_mod.RebuildRuntime(TestCore).PersistentTextRebuildPhase;

const TestTrace = struct {
    const Operation = enum {
        docs,
        finish,
        capture,
        scratch,
        open_docs,
        catalog,
        apply_catalog,
        meta,
        deinit,
    };

    operations: [24]Operation = undefined,
    operation_count: usize = 0,
    phases: [16]TestPhase = undefined,
    phase_count: usize = 0,

    fn append(self: *TestTrace, operation: Operation) void {
        self.operations[self.operation_count] = operation;
        self.operation_count += 1;
    }

    fn observe(context: *anyopaque, phase: TestPhase) anyerror!void {
        const self: *TestTrace = @ptrCast(@alignCast(context));
        self.phases[self.phase_count] = phase;
        self.phase_count += 1;
    }
};

const TestStore = struct {
    io: std.Io,
    dir_path: []const u8,
    trace: *TestTrace,
    attempts: *u32,
    repairs: *u32,
    fail_first_attempt: bool = false,

    fn repairPersistentIndexesFromLog(self: TestStore) !void {
        self.repairs.* += 1;
    }
};

const TestStorage = struct {
    pub const Store = TestStore;
};

const TestCatalogStats = struct {
    term_count: u64,
    term_bytes: u64,
    posting_count: u64,
};

const TestExternalContext = struct {
    store: TestStore,
    attempt: u32,
    expired_after_finish: ?*bool = null,
    fail_catalog: bool = false,
    meta: catalog_format_mod.CatalogFormat(TestCore).PersistentTextMeta = .{},

    fn init(
        _: std.mem.Allocator,
        store: TestStore,
        _: []const u8,
        _: TestCore.QueryDeadline,
        _: bool,
    ) !TestExternalContext {
        store.attempts.* += 1;
        return .{ .store = store, .attempt = store.attempts.* };
    }

    fn deinit(self: *TestExternalContext) void {
        self.store.trace.append(.deinit);
    }

    fn clockIo(self: *const TestExternalContext) std.Io {
        return self.store.io;
    }

    fn buildDocs(self: *TestExternalContext, _: anytype, _: anytype) !void {
        self.store.trace.append(.docs);
        if (self.store.fail_first_attempt and self.attempt == 1) return error.InvalidRecord;
        self.meta.doc_count = self.attempt;
    }

    fn finishRuns(self: *TestExternalContext) !void {
        self.store.trace.append(.finish);
        if (self.expired_after_finish) |flag| flag.* = true;
    }

    fn captureRunTimings(self: *TestExternalContext, timings: anytype) !void {
        self.store.trace.append(.capture);
        timings.run_chunk_count = 3;
    }

    fn releaseScratch(self: *TestExternalContext) void {
        self.store.trace.append(.scratch);
    }

    fn openDocs(self: *TestExternalContext) !void {
        self.store.trace.append(.open_docs);
    }

    fn writeCatalog(self: *TestExternalContext, _: anytype) !TestCatalogStats {
        self.store.trace.append(.catalog);
        if (self.fail_catalog) return error.CatalogFailed;
        return .{ .term_count = 5, .term_bytes = 13, .posting_count = 8 };
    }

    fn applyCatalogStats(self: *TestExternalContext, stats: TestCatalogStats) void {
        self.store.trace.append(.apply_catalog);
        self.meta.term_count = stats.term_count;
        self.meta.term_bytes = stats.term_bytes;
        self.meta.posting_count = stats.posting_count;
    }

    fn writeMeta(self: *TestExternalContext) !void {
        self.store.trace.append(.meta);
    }

    fn finishMeta(_: *TestExternalContext) void {}

    fn finalMeta(self: *const TestExternalContext) @TypeOf(self.meta) {
        return self.meta;
    }
};

const TestOps = struct {
    pub const ExternalContext = TestExternalContext;
};

const test_session = RebuildSession(TestCore, TestStorage, TestOps);
const TestTimings = test_session.PersistentTextRebuildTimings;

fn testStore(tmp: *std.testing.TmpDir, trace: *TestTrace, attempts: *u32, repairs: *u32) !struct {
    store: TestStore,
    path: []u8,
} {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fs.path.join(std.testing.allocator, &.{ path_buffer[0..root_len], "store" });
    try std.Io.Dir.cwd().createDir(std.testing.io, path, .default_dir);
    return .{
        .store = .{
            .io = std.testing.io,
            .dir_path = path,
            .trace = trace,
            .attempts = attempts,
            .repairs = repairs,
        },
        .path = path,
    };
}

test "rebuild session preserves phase order and publishes final meta" {
    var trace = TestTrace{};
    var attempts: u32 = 0;
    var repairs: u32 = 0;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try testStore(&tmp, &trace, &attempts, &repairs);
    defer std.testing.allocator.free(fixture.path);

    var context = try TestExternalContext.init(
        std.testing.allocator,
        fixture.store,
        "unused",
        .none,
        true,
    );
    var timings = TestTimings{};
    const observer = test_session.PersistentTextRebuildObserver{
        .context = &trace,
        .observe = TestTrace.observe,
    };
    const meta = try test_session.Internal.runExternalPhases(
        &context,
        .none,
        &timings,
        observer,
    );

    const expected_operations = [_]TestTrace.Operation{
        .docs,
        .finish,
        .capture,
        .scratch,
        .open_docs,
        .catalog,
        .apply_catalog,
        .meta,
    };
    const expected_phases = [_]TestPhase{
        .docs,
        .run_finish,
        .scratch_release,
        .open_docs,
        .catalog,
        .meta,
    };
    try std.testing.expectEqualSlices(TestTrace.Operation, &expected_operations, trace.operations[0..trace.operation_count]);
    try std.testing.expectEqualSlices(TestPhase, &expected_phases, trace.phases[0..trace.phase_count]);
    try std.testing.expectEqual(@as(u64, 1), meta.doc_count);
    try std.testing.expectEqual(@as(u64, 5), meta.term_count);
    try std.testing.expectEqual(@as(u64, 13), meta.term_bytes);
    try std.testing.expectEqual(@as(u64, 8), meta.posting_count);
    try std.testing.expectEqual(@as(u64, 3), timings.run_chunk_count);
}

test "rebuild session deadline stops before scratch release" {
    var trace = TestTrace{};
    var attempts: u32 = 0;
    var repairs: u32 = 0;
    var expired = false;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try testStore(&tmp, &trace, &attempts, &repairs);
    defer std.testing.allocator.free(fixture.path);

    var context = try TestExternalContext.init(
        std.testing.allocator,
        fixture.store,
        "unused",
        .{ .flag = &expired },
        true,
    );
    context.expired_after_finish = &expired;
    var timings = TestTimings{};
    try std.testing.expectError(
        error.BudgetExceeded,
        test_session.Internal.runExternalPhases(
            &context,
            .{ .flag = &expired },
            &timings,
            null,
        ),
    );

    const expected = [_]TestTrace.Operation{ .docs, .finish, .capture };
    try std.testing.expectEqualSlices(TestTrace.Operation, &expected, trace.operations[0..trace.operation_count]);
}

test "rebuild session propagates catalog failure without meta publication" {
    var trace = TestTrace{};
    var attempts: u32 = 0;
    var repairs: u32 = 0;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try testStore(&tmp, &trace, &attempts, &repairs);
    defer std.testing.allocator.free(fixture.path);

    var context = try TestExternalContext.init(
        std.testing.allocator,
        fixture.store,
        "unused",
        .none,
        false,
    );
    context.fail_catalog = true;
    try std.testing.expectError(
        error.CatalogFailed,
        test_session.Internal.runExternalPhases(&context, .none, null, null),
    );
    try std.testing.expectEqual(TestTrace.Operation.catalog, trace.operations[trace.operation_count - 1]);
}

test "rebuild session repairs graph indexes exactly once before retry" {
    var trace = TestTrace{};
    var attempts: u32 = 0;
    var repairs: u32 = 0;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try testStore(&tmp, &trace, &attempts, &repairs);
    defer std.testing.allocator.free(fixture.path);
    fixture.store.fail_first_attempt = true;

    const meta = try test_session.rebuildPersistentTextCatalog(
        std.testing.allocator,
        fixture.store,
    );
    try std.testing.expectEqual(@as(u32, 2), attempts);
    try std.testing.expectEqual(@as(u32, 1), repairs);
    try std.testing.expectEqual(@as(u64, 2), meta.doc_count);
}
