const std = @import("std");

/// Owns the complete create/open admission and crash-recovery protocol after
/// a Store has acquired all of its resources. `Ops` keeps concrete directory
/// and recovery mechanics private to the storage facade.
pub fn StoreOpening(comptime Ops: type) type {
    return struct {
        pub fn open(request: Ops.Request, create: bool) !Ops.StoreType {
            if (create) {
                try Ops.createDirectory(request);
            } else {
                try Ops.requireDirectory(request);
            }

            var store = try Ops.allocateOwned(request);
            errdefer Ops.deinitStore(&store);

            const store_marker_exists = try Ops.storeMarkerExists(store);
            if (!create) {
                try Ops.ensureStoreMarkerExists(store);
            }
            if (!create or store_marker_exists) {
                // Format admission must precede every recovery routine because
                // recovery is allowed to mutate durable bytes.
                const read_only_older_format = try Ops.admitStoreFormat(store);
                if (read_only_older_format) return store;
                // Recovery writes belong to the single writer; a concurrent
                // read-only open must never repair files the writer owns.
                if (!Ops.crashRecoveryAllowed(request)) return store;
                const committed = try Ops.recoverNodeTextsAppendJournal(store);
                if (committed) {
                    try Ops.repairPersistentIndexesFromLog(store);
                }
            } else if (!Ops.crashRecoveryAllowed(request)) {
                return store;
            }

            // Both create-or-open and strict open must finish interrupted
            // property publication before returning a usable Store.
            try Ops.recoverPropertyPayloadRedoJournal(store);
            try Ops.recoverPropertyPayloadDeltaJournal(store);
            return store;
        }
    };
}

const TestPhase = enum {
    create_directory,
    require_directory,
    allocate_store,
    marker_probe,
    ensure_marker,
    admit_format,
    recover_node_texts,
    repair_indexes,
    recover_property_redo,
    recover_property_delta,
    deinit_store,
};

const TestContext = struct {
    phases: [16]TestPhase = undefined,
    phase_count: usize = 0,
    fail_at: ?TestPhase = null,
    marker_exists: bool = false,
    node_text_recovery_committed: bool = false,
    read_only_older_format: bool = false,
    store_owned: bool = false,
    deinit_count: usize = 0,

    fn record(self: *TestContext, phase: TestPhase) !void {
        self.phases[self.phase_count] = phase;
        self.phase_count += 1;
        if (self.fail_at == phase) return error.InjectedFailure;
    }

    fn recorded(self: *const TestContext) []const TestPhase {
        return self.phases[0..self.phase_count];
    }
};

const TestStore = struct {
    context: *TestContext,
};

const TestOps = struct {
    pub const Request = *TestContext;
    pub const StoreType = TestStore;

    pub fn crashRecoveryAllowed(_: Request) bool {
        return true;
    }

    pub fn createDirectory(context: Request) !void {
        try context.record(.create_directory);
    }

    pub fn requireDirectory(context: Request) !void {
        try context.record(.require_directory);
    }

    pub fn allocateOwned(context: Request) !StoreType {
        try context.record(.allocate_store);
        context.store_owned = true;
        return .{ .context = context };
    }

    pub fn deinitStore(store: *StoreType) void {
        const context = store.context;
        context.phases[context.phase_count] = .deinit_store;
        context.phase_count += 1;
        std.debug.assert(context.store_owned);
        context.store_owned = false;
        context.deinit_count += 1;
    }

    pub fn storeMarkerExists(store: StoreType) !bool {
        try store.context.record(.marker_probe);
        return store.context.marker_exists;
    }

    pub fn ensureStoreMarkerExists(store: StoreType) !void {
        try store.context.record(.ensure_marker);
        if (!store.context.marker_exists) return error.FileNotFound;
    }

    pub fn recoverNodeTextsAppendJournal(store: StoreType) !bool {
        try store.context.record(.recover_node_texts);
        return store.context.node_text_recovery_committed;
    }

    pub fn admitStoreFormat(store: StoreType) !bool {
        try store.context.record(.admit_format);
        return store.context.read_only_older_format;
    }

    pub fn repairPersistentIndexesFromLog(store: StoreType) !void {
        try store.context.record(.repair_indexes);
    }

    pub fn recoverPropertyPayloadRedoJournal(store: StoreType) !void {
        try store.context.record(.recover_property_redo);
    }

    pub fn recoverPropertyPayloadDeltaJournal(store: StoreType) !void {
        try store.context.record(.recover_property_delta);
    }
};

const test_opening = StoreOpening(TestOps);

test "store opening create without marker skips node text recovery" {
    var context = TestContext{};
    var store = try test_opening.open(&context, true);
    defer TestOps.deinitStore(&store);

    try std.testing.expect(context.store_owned);
    try std.testing.expectEqualSlices(TestPhase, &.{
        .create_directory,
        .allocate_store,
        .marker_probe,
        .recover_property_redo,
        .recover_property_delta,
    }, context.recorded());
}

test "store opening create repairs only a committed node text recovery" {
    var context = TestContext{
        .marker_exists = true,
        .node_text_recovery_committed = true,
    };
    var store = try test_opening.open(&context, true);
    defer TestOps.deinitStore(&store);

    try std.testing.expectEqualSlices(TestPhase, &.{
        .create_directory,
        .allocate_store,
        .marker_probe,
        .admit_format,
        .recover_node_texts,
        .repair_indexes,
        .recover_property_redo,
        .recover_property_delta,
    }, context.recorded());
}

test "store opening strict open admits marker and preserves recovery order" {
    var context = TestContext{ .marker_exists = true };
    var store = try test_opening.open(&context, false);
    defer TestOps.deinitStore(&store);

    try std.testing.expectEqualSlices(TestPhase, &.{
        .require_directory,
        .allocate_store,
        .marker_probe,
        .ensure_marker,
        .admit_format,
        .recover_node_texts,
        .recover_property_redo,
        .recover_property_delta,
    }, context.recorded());
}

test "store opening skips every mutating recovery only for an admitted older format" {
    var context = TestContext{
        .marker_exists = true,
        .node_text_recovery_committed = true,
        .read_only_older_format = true,
    };
    var store = try test_opening.open(&context, false);
    defer TestOps.deinitStore(&store);

    try std.testing.expectEqualSlices(TestPhase, &.{
        .require_directory,
        .allocate_store,
        .marker_probe,
        .ensure_marker,
        .admit_format,
    }, context.recorded());
}

test "store opening strict open rejects a missing marker and cleans once" {
    var context = TestContext{};
    try std.testing.expectError(error.FileNotFound, test_opening.open(&context, false));
    try std.testing.expect(!context.store_owned);
    try std.testing.expectEqual(@as(usize, 1), context.deinit_count);
    try std.testing.expectEqualSlices(TestPhase, &.{
        .require_directory,
        .allocate_store,
        .marker_probe,
        .ensure_marker,
        .deinit_store,
    }, context.recorded());
}

test "store opening cleans exactly once at every failure boundary" {
    const open_failures = [_]TestPhase{
        .require_directory,
        .allocate_store,
        .marker_probe,
        .ensure_marker,
        .admit_format,
        .recover_node_texts,
        .repair_indexes,
        .recover_property_redo,
        .recover_property_delta,
    };
    for (open_failures) |failure| {
        var context = TestContext{
            .fail_at = failure,
            .marker_exists = true,
            .node_text_recovery_committed = true,
        };
        try std.testing.expectError(error.InjectedFailure, test_opening.open(&context, false));
        const expected_deinit_count: usize = if (failure == .require_directory or failure == .allocate_store) 0 else 1;
        try std.testing.expectEqual(expected_deinit_count, context.deinit_count);
        try std.testing.expect(!context.store_owned);
    }

    var create_context = TestContext{ .fail_at = .create_directory };
    try std.testing.expectError(error.InjectedFailure, test_opening.open(&create_context, true));
    try std.testing.expectEqual(@as(usize, 0), create_context.deinit_count);
    try std.testing.expect(!create_context.store_owned);
}
