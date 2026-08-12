//! Machine-observable contract for TinyKG's vector-free lexical probes.
//!
//! The model still chooses aliases, paraphrases, mechanisms, and nearby
//! concepts. The host only makes that choice bounded and replayable: one seed
//! probe, or one selected member of a fixed 2-4 variant expansion plan.

const std = @import("std");
const platform = @import("platform");

pub const SCHEMA_VERSION = "lexical-query-plan-v1";
pub const MAX_QUERY_BYTES: usize = 400;
pub const MAX_VARIANTS: usize = 4;
pub const MAX_SEEN_NODE_IDS: usize = 32;
pub const MAX_TRACKED_PLANS: usize = 32;

pub const Intent = enum {
    fact_lookup,
    procedure_reuse,
    task_recovery,
    enumeration,
    temporal,
    causal,
    entity,
    other,
};

pub const Stage = enum {
    seed,
    semantic_expansion,
    focused_refinement,
};

pub const VariantKind = enum {
    exact,
    alias,
    paraphrase,
    mechanism,
    symptom,
    outcome,
    broader,
    narrower,
    relation,
    type,
    time,
};

pub const Variant = struct {
    kind: VariantKind,
    text: []u8,

    fn deinit(self: *Variant, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const Plan = struct {
    intent: Intent,
    stage: Stage,
    variants: []Variant,
    variant_index: usize,
    seen_node_ids: []u64,
    fingerprint: [64]u8,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        for (self.variants) |*variant| variant.deinit(allocator);
        allocator.free(self.variants);
        allocator.free(self.seen_node_ids);
        self.* = undefined;
    }

    pub fn selected(self: Plan) Variant {
        return self.variants[self.variant_index];
    }

    pub fn hasSeen(self: Plan, node_id: u64) bool {
        return containsU64(self.seen_node_ids, node_id);
    }
};

pub const Error = error{
    OutOfMemory,
    InvalidPlanObject,
    InvalidSchemaVersion,
    InvalidIntent,
    InvalidStage,
    InvalidVariants,
    TooManyVariants,
    InvalidVariant,
    DuplicateVariant,
    InvalidVariantIndex,
    QueryVariantMismatch,
    InvalidStageShape,
    SeedTypeFilterForbidden,
    InvalidSeenNodeIds,
    TooManySeenNodeIds,
    DuplicateSeenNodeId,
};

pub const LedgerError = error{
    SeenStateMismatch,
    PlanCapacityExceeded,
    HitCapacityExceeded,
};

const LedgerEntry = struct {
    fingerprint: [64]u8 = [_]u8{0} ** 64,
    node_ids: [MAX_SEEN_NODE_IDS]u64 = [_]u64{0} ** MAX_SEEN_NODE_IDS,
    node_count: usize = 0,

    fn nodes(self: *const LedgerEntry) []const u64 {
        return self.node_ids[0..self.node_count];
    }
};

/// Run-scoped host truth for the node ids actually returned by each fixed
/// lexical plan. The caller keeps a Guard across the TinyKG read and response
/// construction, so two concurrent calls for the same plan cannot both count
/// the same candidates as new information.
///
/// This is deliberately fixed-size: governed retrieval fails closed instead
/// of turning a long agent run into an unbounded model-controlled allocation.
pub const Ledger = struct {
    mutex: platform.sync.Mutex = .{},
    entries: [MAX_TRACKED_PLANS]LedgerEntry = [_]LedgerEntry{.{}} ** MAX_TRACKED_PLANS,
    entry_count: usize = 0,

    pub fn lockPlan(self: *Ledger, plan: Plan) LedgerError!Guard {
        self.mutex.lock();
        errdefer self.mutex.unlock();

        for (self.entries[0..self.entry_count], 0..) |*entry, index| {
            if (!std.mem.eql(u8, &entry.fingerprint, &plan.fingerprint)) continue;
            if (!sameSet(entry.nodes(), plan.seen_node_ids)) return error.SeenStateMismatch;
            return .{ .ledger = self, .entry_index = index };
        }

        // A new fixed plan has no host history. Letting the model seed it with
        // arbitrary ids would recreate the exact forged-metric bug this ledger
        // exists to prevent.
        if (plan.seen_node_ids.len != 0) return error.SeenStateMismatch;
        if (self.entry_count == MAX_TRACKED_PLANS) return error.PlanCapacityExceeded;

        const index = self.entry_count;
        self.entries[index] = .{ .fingerprint = plan.fingerprint };
        self.entry_count += 1;
        return .{ .ledger = self, .entry_index = index, .created = true };
    }

    pub const Guard = struct {
        ledger: *Ledger,
        entry_index: usize,
        created: bool = false,
        active: bool = true,

        /// Abort the in-flight observation. Existing history is untouched; a
        /// newly-created empty entry is rolled back so failed TinyKG reads do
        /// not consume the bounded plan budget.
        pub fn deinit(self: *Guard) void {
            if (!self.active) return;
            if (self.created) {
                std.debug.assert(self.entry_index + 1 == self.ledger.entry_count);
                self.ledger.entry_count -= 1;
                self.ledger.entries[self.entry_index] = .{};
            }
            self.active = false;
            self.ledger.mutex.unlock();
        }

        pub fn wasSeen(self: *const Guard, node_id: u64) bool {
            std.debug.assert(self.active);
            return containsU64(self.ledger.entries[self.entry_index].nodes(), node_id);
        }

        /// Atomically extend host history with the ids that will be returned
        /// to the model. Capacity is preflighted before mutation. `hit_ids`
        /// may contain duplicates; the ledger stores each positive id once.
        pub fn commit(self: *Guard, hit_ids: []const u64) LedgerError!void {
            std.debug.assert(self.active);
            var entry = &self.ledger.entries[self.entry_index];
            var new_count: usize = 0;
            for (hit_ids, 0..) |node_id, index| {
                if (node_id == 0 or containsU64(entry.nodes(), node_id) or
                    containsU64(hit_ids[0..index], node_id)) continue;
                new_count += 1;
            }
            if (entry.node_count + new_count > MAX_SEEN_NODE_IDS) return error.HitCapacityExceeded;
            for (hit_ids, 0..) |node_id, index| {
                if (node_id == 0 or containsU64(entry.nodes(), node_id) or
                    containsU64(hit_ids[0..index], node_id)) continue;
                entry.node_ids[entry.node_count] = node_id;
                entry.node_count += 1;
            }
            self.active = false;
            self.ledger.mutex.unlock();
        }
    };
};

/// Parse an optional `lexical_plan` from one KgRecall input object. The plan
/// owns all returned slices. Absence preserves the legacy query-only API.
pub fn parse(
    allocator: std.mem.Allocator,
    args: std.json.ObjectMap,
    query: []const u8,
    type_filter: ?[]const u8,
) Error!?Plan {
    const raw_plan = args.get("lexical_plan") orelse return null;
    if (raw_plan != .object) return error.InvalidPlanObject;
    const object = raw_plan.object;

    const version = stringField(object, "schema_version") orelse return error.InvalidSchemaVersion;
    if (!std.mem.eql(u8, version, SCHEMA_VERSION)) return error.InvalidSchemaVersion;
    const intent_text = stringField(object, "intent") orelse return error.InvalidIntent;
    const intent = std.meta.stringToEnum(Intent, intent_text) orelse return error.InvalidIntent;
    const stage_text = stringField(object, "stage") orelse return error.InvalidStage;
    const stage = std.meta.stringToEnum(Stage, stage_text) orelse return error.InvalidStage;

    const raw_variants = object.get("variants") orelse return error.InvalidVariants;
    if (raw_variants != .array or raw_variants.array.items.len == 0) return error.InvalidVariants;
    if (raw_variants.array.items.len > MAX_VARIANTS) return error.TooManyVariants;

    var variants: std.ArrayList(Variant) = .empty;
    var variants_transferred = false;
    defer if (!variants_transferred) {
        for (variants.items) |*variant| variant.deinit(allocator);
        variants.deinit(allocator);
    };
    for (raw_variants.array.items) |raw_variant| {
        if (raw_variant != .object) return error.InvalidVariant;
        const kind_text = stringField(raw_variant.object, "kind") orelse return error.InvalidVariant;
        const kind = std.meta.stringToEnum(VariantKind, kind_text) orelse return error.InvalidVariant;
        const raw_text = stringField(raw_variant.object, "text") orelse return error.InvalidVariant;
        const text = std.mem.trim(u8, raw_text, " \t\r\n");
        if (!validCompactText(text)) return error.InvalidVariant;
        for (variants.items) |prior| {
            if (std.mem.eql(u8, prior.text, text)) return error.DuplicateVariant;
        }
        const owned_text = try allocator.dupe(u8, text);
        variants.append(allocator, .{ .kind = kind, .text = owned_text }) catch {
            allocator.free(owned_text);
            return error.OutOfMemory;
        };
    }

    const index_value = object.get("variant_index") orelse return error.InvalidVariantIndex;
    if (index_value != .integer or index_value.integer < 0) return error.InvalidVariantIndex;
    const variant_index = std.math.cast(usize, index_value.integer) orelse return error.InvalidVariantIndex;
    if (variant_index >= variants.items.len) return error.InvalidVariantIndex;
    const normalized_query = std.mem.trim(u8, query, " \t\r\n");
    if (!validCompactText(normalized_query) or
        !std.mem.eql(u8, normalized_query, variants.items[variant_index].text))
        return error.QueryVariantMismatch;

    switch (stage) {
        .seed => {
            if (variants.items.len != 1 or variant_index != 0 or
                (variants.items[0].kind != .exact and variants.items[0].kind != .alias))
                return error.InvalidStageShape;
            if (type_filter != null) return error.SeedTypeFilterForbidden;
        },
        .semantic_expansion => {
            if (variants.items.len < 2) return error.InvalidStageShape;
            for (variants.items) |variant| {
                if (variant.kind == .exact) return error.InvalidStageShape;
            }
        },
        .focused_refinement => {},
    }

    var seen_ids: std.ArrayList(u64) = .empty;
    var seen_transferred = false;
    defer if (!seen_transferred) seen_ids.deinit(allocator);
    const raw_seen = object.get("seen_node_ids") orelse return error.InvalidSeenNodeIds;
    if (raw_seen != .array) return error.InvalidSeenNodeIds;
    if (raw_seen.array.items.len > MAX_SEEN_NODE_IDS) return error.TooManySeenNodeIds;
    for (raw_seen.array.items) |value| {
        if (value != .integer or value.integer < 1) return error.InvalidSeenNodeIds;
        const node_id = std.math.cast(u64, value.integer) orelse return error.InvalidSeenNodeIds;
        if (containsU64(seen_ids.items, node_id)) return error.DuplicateSeenNodeId;
        try seen_ids.append(allocator, node_id);
    }

    const owned_variants = try variants.toOwnedSlice(allocator);
    variants_transferred = true;
    errdefer {
        for (owned_variants) |*variant| variant.deinit(allocator);
        allocator.free(owned_variants);
    }
    const owned_seen = try seen_ids.toOwnedSlice(allocator);
    seen_transferred = true;
    return .{
        .intent = intent,
        .stage = stage,
        .variants = owned_variants,
        .variant_index = variant_index,
        .seen_node_ids = owned_seen,
        .fingerprint = fingerprint(intent, stage, owned_variants, type_filter),
    };
}

pub fn diagnostic(err: Error) []const u8 {
    return switch (err) {
        error.OutOfMemory => "lexical_plan allocation failed",
        error.InvalidPlanObject => "lexical_plan must be an object",
        error.InvalidSchemaVersion => "lexical_plan.schema_version must be lexical-query-plan-v1",
        error.InvalidIntent => "lexical_plan.intent is missing or unsupported",
        error.InvalidStage => "lexical_plan.stage is missing or unsupported",
        error.InvalidVariants => "lexical_plan.variants must contain 1-4 typed variants",
        error.TooManyVariants => "lexical_plan.variants exceeds the four-probe budget",
        error.InvalidVariant => "each lexical_plan variant needs a supported kind and compact text <=400 bytes",
        error.DuplicateVariant => "lexical_plan variants must have distinct text",
        error.InvalidVariantIndex => "lexical_plan.variant_index is outside variants",
        error.QueryVariantMismatch => "KgRecall query must exactly match lexical_plan.variants[variant_index].text",
        error.InvalidStageShape => "seed requires one exact/alias variant; semantic_expansion requires 2-4 non-exact variants",
        error.SeedTypeFilterForbidden => "the seed stage must omit KgRecall type",
        error.InvalidSeenNodeIds => "lexical_plan.seen_node_ids must contain positive integer ids",
        error.TooManySeenNodeIds => "lexical_plan.seen_node_ids exceeds 32 ids",
        error.DuplicateSeenNodeId => "lexical_plan.seen_node_ids must be unique",
    };
}

pub fn ledgerDiagnostic(err: LedgerError) []const u8 {
    return switch (err) {
        error.SeenStateMismatch => "lexical_plan.seen_node_ids does not exactly match the host ledger for this plan",
        error.PlanCapacityExceeded => "the agent run exceeded 32 distinct governed lexical plans",
        error.HitCapacityExceeded => "this lexical plan would exceed the 32-node host ledger; stop or begin a new plan",
    };
}

fn validCompactText(value: []const u8) bool {
    if (value.len == 0 or value.len > MAX_QUERY_BYTES or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn fingerprint(intent: Intent, stage: Stage, variants: []const Variant, type_filter: ?[]const u8) [64]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var hash = Sha256.init(.{});
    hashField(&hash, SCHEMA_VERSION);
    hashField(&hash, @tagName(intent));
    hashField(&hash, @tagName(stage));
    hashField(&hash, type_filter orelse "");
    for (variants) |variant| {
        hashField(&hash, @tagName(variant.kind));
        hashField(&hash, variant.text);
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn hashField(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length_buffer: [32]u8 = undefined;
    const length = std.fmt.bufPrint(&length_buffer, "{d}:", .{value.len}) catch unreachable;
    hash.update(length);
    hash.update(value);
}

fn containsU64(values: []const u64, expected: u64) bool {
    for (values) |value| if (value == expected) return true;
    return false;
}

fn sameSet(expected: []const u64, declared: []const u64) bool {
    if (expected.len != declared.len) return false;
    for (expected) |node_id| if (!containsU64(declared, node_id)) return false;
    return true;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

const valid_expansion =
    \\{"query":"checkpoint replay","lexical_plan":{"schema_version":"lexical-query-plan-v1","intent":"procedure_reuse","stage":"semantic_expansion","variants":[{"kind":"paraphrase","text":"parser recovery"},{"kind":"mechanism","text":"checkpoint replay"}],"variant_index":1,"seen_node_ids":[7,9]}}
;

test "lexical query plan parses bounded expansion and fingerprints the fixed list" {
    const a = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, valid_expansion, .{});
    defer parsed.deinit();
    var plan = (try parse(a, parsed.value.object, "checkpoint replay", null)) orelse return error.TestUnexpectedResult;
    defer plan.deinit(a);
    try std.testing.expectEqual(Intent.procedure_reuse, plan.intent);
    try std.testing.expectEqual(Stage.semantic_expansion, plan.stage);
    try std.testing.expectEqual(@as(usize, 2), plan.variants.len);
    try std.testing.expectEqualStrings("checkpoint replay", plan.selected().text);
    try std.testing.expect(plan.hasSeen(7));
    try std.testing.expectEqual(@as(usize, 64), plan.fingerprint.len);

    const first =
        \\{"query":"parser recovery","lexical_plan":{"schema_version":"lexical-query-plan-v1","intent":"procedure_reuse","stage":"semantic_expansion","variants":[{"kind":"paraphrase","text":"parser recovery"},{"kind":"mechanism","text":"checkpoint replay"}],"variant_index":0,"seen_node_ids":[]}}
    ;
    var first_parsed = try std.json.parseFromSlice(std.json.Value, a, first, .{});
    defer first_parsed.deinit();
    var first_plan = (try parse(a, first_parsed.value.object, "parser recovery", null)) orelse return error.TestUnexpectedResult;
    defer first_plan.deinit(a);
    try std.testing.expectEqualSlices(u8, &plan.fingerprint, &first_plan.fingerprint);
}

test "lexical query plan rejects mismatch, duplicate state, and typed seed" {
    const a = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, valid_expansion, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.QueryVariantMismatch, parse(a, parsed.value.object, "different query", null));

    const duplicate_seen =
        \\{"lexical_plan":{"schema_version":"lexical-query-plan-v1","intent":"fact_lookup","stage":"seed","variants":[{"kind":"exact","text":"needle"}],"variant_index":0,"seen_node_ids":[3,3]}}
    ;
    var duplicate_parsed = try std.json.parseFromSlice(std.json.Value, a, duplicate_seen, .{});
    defer duplicate_parsed.deinit();
    try std.testing.expectError(error.DuplicateSeenNodeId, parse(a, duplicate_parsed.value.object, "needle", null));

    const typed_seed =
        \\{"lexical_plan":{"schema_version":"lexical-query-plan-v1","intent":"fact_lookup","stage":"seed","variants":[{"kind":"exact","text":"needle"}],"variant_index":0,"seen_node_ids":[]}}
    ;
    var seed_parsed = try std.json.parseFromSlice(std.json.Value, a, typed_seed, .{});
    defer seed_parsed.deinit();
    try std.testing.expectError(error.SeedTypeFilterForbidden, parse(a, seed_parsed.value.object, "needle", "decision"));

    const missing_seen =
        \\{"lexical_plan":{"schema_version":"lexical-query-plan-v1","intent":"fact_lookup","stage":"seed","variants":[{"kind":"exact","text":"needle"}],"variant_index":0}}
    ;
    var missing_seen_parsed = try std.json.parseFromSlice(std.json.Value, a, missing_seen, .{});
    defer missing_seen_parsed.deinit();
    try std.testing.expectError(error.InvalidSeenNodeIds, parse(a, missing_seen_parsed.value.object, "needle", null));
}

test "lexical query ledger rejects forged or omitted seen ids" {
    const a = std.testing.allocator;
    const first =
        \\{"lexical_plan":{"schema_version":"lexical-query-plan-v1","intent":"fact_lookup","stage":"semantic_expansion","variants":[{"kind":"paraphrase","text":"needle alias"},{"kind":"mechanism","text":"needle mechanism"}],"variant_index":0,"seen_node_ids":[]}}
    ;
    var parsed_first = try std.json.parseFromSlice(std.json.Value, a, first, .{});
    defer parsed_first.deinit();
    var first_plan = (try parse(a, parsed_first.value.object, "needle alias", null)) orelse return error.TestUnexpectedResult;
    defer first_plan.deinit(a);

    var ledger = Ledger{};
    var guard = try ledger.lockPlan(first_plan);
    defer guard.deinit();
    try std.testing.expect(!guard.wasSeen(41));
    try guard.commit(&.{ 41, 43, 41 });

    try std.testing.expectError(error.SeenStateMismatch, ledger.lockPlan(first_plan));

    const forged =
        \\{"lexical_plan":{"schema_version":"lexical-query-plan-v1","intent":"fact_lookup","stage":"semantic_expansion","variants":[{"kind":"paraphrase","text":"needle alias"},{"kind":"mechanism","text":"needle mechanism"}],"variant_index":1,"seen_node_ids":[41,43,99]}}
    ;
    var parsed_forged = try std.json.parseFromSlice(std.json.Value, a, forged, .{});
    defer parsed_forged.deinit();
    var forged_plan = (try parse(a, parsed_forged.value.object, "needle mechanism", null)) orelse return error.TestUnexpectedResult;
    defer forged_plan.deinit(a);
    try std.testing.expectError(error.SeenStateMismatch, ledger.lockPlan(forged_plan));

    const exact =
        \\{"lexical_plan":{"schema_version":"lexical-query-plan-v1","intent":"fact_lookup","stage":"semantic_expansion","variants":[{"kind":"paraphrase","text":"needle alias"},{"kind":"mechanism","text":"needle mechanism"}],"variant_index":1,"seen_node_ids":[43,41]}}
    ;
    var parsed_exact = try std.json.parseFromSlice(std.json.Value, a, exact, .{});
    defer parsed_exact.deinit();
    var exact_plan = (try parse(a, parsed_exact.value.object, "needle mechanism", null)) orelse return error.TestUnexpectedResult;
    defer exact_plan.deinit(a);
    var exact_guard = try ledger.lockPlan(exact_plan);
    defer exact_guard.deinit();
    try std.testing.expect(exact_guard.wasSeen(41));
    try exact_guard.commit(&.{43});
}

test "lexical query ledger serializes concurrent declarations" {
    const a = std.testing.allocator;
    const first =
        \\{"lexical_plan":{"schema_version":"lexical-query-plan-v1","intent":"fact_lookup","stage":"seed","variants":[{"kind":"exact","text":"needle"}],"variant_index":0,"seen_node_ids":[]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, first, .{});
    defer parsed.deinit();
    var plan = (try parse(a, parsed.value.object, "needle", null)) orelse return error.TestUnexpectedResult;
    defer plan.deinit(a);

    const Shared = struct {
        ledger: Ledger = .{},
        plan: *const Plan,
        count_mutex: platform.sync.Mutex = .{},
        succeeded: usize = 0,
        rejected: usize = 0,

        fn run(self: *@This()) void {
            var guard = self.ledger.lockPlan(self.plan.*) catch {
                self.count_mutex.lock();
                self.rejected += 1;
                self.count_mutex.unlock();
                return;
            };
            defer guard.deinit();
            guard.commit(&.{7}) catch return;
            self.count_mutex.lock();
            self.succeeded += 1;
            self.count_mutex.unlock();
        }
    };
    var shared = Shared{ .plan = &plan };
    var first_thread = try std.Thread.spawn(.{}, Shared.run, .{&shared});
    var second_thread = try std.Thread.spawn(.{}, Shared.run, .{&shared});
    first_thread.join();
    second_thread.join();
    try std.testing.expectEqual(@as(usize, 1), shared.succeeded);
    try std.testing.expectEqual(@as(usize, 1), shared.rejected);
}

fn allocationPath(allocator: std.mem.Allocator) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, valid_expansion, .{});
    defer parsed.deinit();
    var plan = (try parse(allocator, parsed.value.object, "checkpoint replay", null)) orelse return error.TestUnexpectedResult;
    defer plan.deinit(allocator);
}

test "lexical query plan allocation failures do not leak" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationPath, .{});
}
