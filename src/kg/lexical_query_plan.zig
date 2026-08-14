//! Machine-observable contract for TinyKG's vector-free lexical probes.
//!
//! The model still chooses aliases, paraphrases, mechanisms, and nearby
//! concepts. The host only makes that choice bounded and replayable: one seed
//! probe, or one selected member of a fixed 1-4 variant expansion plan.

const std = @import("std");
const platform = @import("platform");

pub const SCHEMA_VERSION = "lexical-query-plan-v2";
pub const LEGACY_SCHEMA_VERSION = "lexical-query-plan-v1";
pub const MAX_QUERY_BYTES: usize = 400;
pub const MAX_VARIANTS: usize = 4;
pub const MAX_SEEN_NODE_IDS: usize = 32;
pub const MAX_TRACKED_PLANS: usize = 32;
pub const MAX_RUN_SEEN_NODE_IDS: usize = MAX_SEEN_NODE_IDS * MAX_TRACKED_PLANS;
pub const MAX_V2_SEMANTIC_EXPANSION_CALLS: usize = 4;

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

pub const SchemaVersion = enum {
    legacy_v1,
    host_managed_v2,

    pub fn text(self: SchemaVersion) []const u8 {
        return switch (self) {
            .legacy_v1 => LEGACY_SCHEMA_VERSION,
            .host_managed_v2 => SCHEMA_VERSION,
        };
    }
};

pub const VariantKind = enum {
    exact,
    alias,
    synonym,
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
    schema_version: SchemaVersion,
    intent: Intent,
    stage: Stage,
    variants: []Variant,
    variant_index: usize,
    declared_seen_node_ids: ?[]u64,
    fingerprint: [64]u8,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        for (self.variants) |*variant| variant.deinit(allocator);
        allocator.free(self.variants);
        if (self.declared_seen_node_ids) |ids| allocator.free(ids);
        self.* = undefined;
    }

    pub fn selected(self: Plan) Variant {
        return self.variants[self.variant_index];
    }

    pub fn hasSeen(self: Plan, node_id: u64) bool {
        return if (self.declared_seen_node_ids) |ids| containsU64(ids, node_id) else false;
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
    UnexpectedSeenNodeIds,
};

pub const LedgerError = error{
    SeenStateMismatch,
    PlanCapacityExceeded,
    HitCapacityExceeded,
    SemanticExpansionBudgetExceeded,
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
    run_node_ids: [MAX_RUN_SEEN_NODE_IDS]u64 = [_]u64{0} ** MAX_RUN_SEEN_NODE_IDS,
    run_node_count: usize = 0,
    v2_semantic_expansion_calls: usize = 0,

    fn runNodes(self: *const Ledger) []const u64 {
        return self.run_node_ids[0..self.run_node_count];
    }

    pub fn lockPlan(self: *Ledger, plan: Plan) LedgerError!Guard {
        self.mutex.lock();
        errdefer self.mutex.unlock();

        const counts_v2_semantic_expansion = plan.schema_version == .host_managed_v2 and
            plan.stage == .semantic_expansion;
        if (counts_v2_semantic_expansion and
            self.v2_semantic_expansion_calls == MAX_V2_SEMANTIC_EXPANSION_CALLS)
            return error.SemanticExpansionBudgetExceeded;

        for (self.entries[0..self.entry_count], 0..) |*entry, index| {
            if (!std.mem.eql(u8, &entry.fingerprint, &plan.fingerprint)) continue;
            if (plan.declared_seen_node_ids) |declared| {
                if (!sameSet(entry.nodes(), declared)) return error.SeenStateMismatch;
            }
            return .{
                .ledger = self,
                .entry_index = index,
                .schema_version = plan.schema_version,
                .counts_v2_semantic_expansion = counts_v2_semantic_expansion,
            };
        }

        // A new fixed plan has no host history. Legacy v1 declarations must
        // therefore be empty; v2 carries no caller-owned seen state at all.
        if (plan.declared_seen_node_ids) |declared| {
            if (declared.len != 0) return error.SeenStateMismatch;
        }
        if (self.entry_count == MAX_TRACKED_PLANS) return error.PlanCapacityExceeded;

        const index = self.entry_count;
        self.entries[index] = .{ .fingerprint = plan.fingerprint };
        self.entry_count += 1;
        return .{
            .ledger = self,
            .entry_index = index,
            .schema_version = plan.schema_version,
            .created = true,
            .counts_v2_semantic_expansion = counts_v2_semantic_expansion,
        };
    }

    pub const Guard = struct {
        ledger: *Ledger,
        entry_index: usize,
        schema_version: SchemaVersion,
        created: bool = false,
        counts_v2_semantic_expansion: bool = false,
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
            return containsU64(self.seenNodes(), node_id);
        }

        pub fn seenCount(self: *const Guard) usize {
            std.debug.assert(self.active);
            return self.seenNodes().len;
        }

        pub fn scope(self: *const Guard) []const u8 {
            return switch (self.schema_version) {
                .legacy_v1 => "agent_run_plan",
                .host_managed_v2 => "agent_run_explicit",
            };
        }

        fn seenNodes(self: *const Guard) []const u64 {
            return switch (self.schema_version) {
                .legacy_v1 => self.ledger.entries[self.entry_index].nodes(),
                .host_managed_v2 => self.ledger.runNodes(),
            };
        }

        /// Atomically extend host history with the ids that will be returned
        /// to the model. Capacity is preflighted before mutation. `hit_ids`
        /// may contain duplicates; the ledger stores each positive id once.
        pub fn commit(self: *Guard, hit_ids: []const u64) LedgerError!void {
            std.debug.assert(self.active);
            const existing = self.seenNodes();
            var new_count: usize = 0;
            for (hit_ids, 0..) |node_id, index| {
                if (node_id == 0 or containsU64(existing, node_id) or
                    containsU64(hit_ids[0..index], node_id)) continue;
                new_count += 1;
            }
            switch (self.schema_version) {
                .legacy_v1 => {
                    var entry = &self.ledger.entries[self.entry_index];
                    if (entry.node_count + new_count > MAX_SEEN_NODE_IDS) return error.HitCapacityExceeded;
                    for (hit_ids, 0..) |node_id, index| {
                        if (node_id == 0 or containsU64(entry.nodes(), node_id) or
                            containsU64(hit_ids[0..index], node_id)) continue;
                        entry.node_ids[entry.node_count] = node_id;
                        entry.node_count += 1;
                    }
                },
                .host_managed_v2 => {
                    if (self.ledger.run_node_count + new_count > MAX_RUN_SEEN_NODE_IDS) return error.HitCapacityExceeded;
                    for (hit_ids, 0..) |node_id, index| {
                        if (node_id == 0 or containsU64(self.ledger.runNodes(), node_id) or
                            containsU64(hit_ids[0..index], node_id)) continue;
                        self.ledger.run_node_ids[self.ledger.run_node_count] = node_id;
                        self.ledger.run_node_count += 1;
                    }
                },
            }
            if (self.counts_v2_semantic_expansion) {
                std.debug.assert(self.ledger.v2_semantic_expansion_calls < MAX_V2_SEMANTIC_EXPANSION_CALLS);
                self.ledger.v2_semantic_expansion_calls += 1;
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

    const version_text = stringField(object, "schema_version") orelse return error.InvalidSchemaVersion;
    const schema_version: SchemaVersion = if (std.mem.eql(u8, version_text, SCHEMA_VERSION))
        .host_managed_v2
    else if (std.mem.eql(u8, version_text, LEGACY_SCHEMA_VERSION))
        .legacy_v1
    else
        return error.InvalidSchemaVersion;
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
        if (schema_version == .legacy_v1 and kind == .synonym) return error.InvalidVariant;
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
            if (schema_version == .legacy_v1 and variants.items.len < 2) return error.InvalidStageShape;
            for (variants.items) |variant| {
                if (variant.kind == .exact) return error.InvalidStageShape;
            }
        },
        .focused_refinement => {},
    }

    var declared_seen_node_ids: ?[]u64 = null;
    errdefer if (declared_seen_node_ids) |ids| allocator.free(ids);
    if (schema_version == .legacy_v1) {
        var seen_ids: std.ArrayList(u64) = .empty;
        errdefer seen_ids.deinit(allocator);
        const raw_seen = object.get("seen_node_ids") orelse return error.InvalidSeenNodeIds;
        if (raw_seen != .array) return error.InvalidSeenNodeIds;
        if (raw_seen.array.items.len > MAX_SEEN_NODE_IDS) return error.TooManySeenNodeIds;
        for (raw_seen.array.items) |value| {
            if (value != .integer or value.integer < 1) return error.InvalidSeenNodeIds;
            const node_id = std.math.cast(u64, value.integer) orelse return error.InvalidSeenNodeIds;
            if (containsU64(seen_ids.items, node_id)) return error.DuplicateSeenNodeId;
            try seen_ids.append(allocator, node_id);
        }
        declared_seen_node_ids = try seen_ids.toOwnedSlice(allocator);
    } else if (object.get("seen_node_ids") != null) {
        return error.UnexpectedSeenNodeIds;
    }

    const owned_variants = try variants.toOwnedSlice(allocator);
    variants_transferred = true;
    errdefer {
        for (owned_variants) |*variant| variant.deinit(allocator);
        allocator.free(owned_variants);
    }
    return .{
        .schema_version = schema_version,
        .intent = intent,
        .stage = stage,
        .variants = owned_variants,
        .variant_index = variant_index,
        .declared_seen_node_ids = declared_seen_node_ids,
        .fingerprint = fingerprint(schema_version, intent, stage, owned_variants, type_filter),
    };
}

pub fn diagnostic(err: Error) []const u8 {
    return switch (err) {
        error.OutOfMemory => "lexical_plan allocation failed",
        error.InvalidPlanObject => "lexical_plan must be an object",
        error.InvalidSchemaVersion => "lexical_plan.schema_version must be lexical-query-plan-v2 (v1 remains a compatibility path)",
        error.InvalidIntent => "lexical_plan.intent is missing or unsupported",
        error.InvalidStage => "lexical_plan.stage is missing or unsupported",
        error.InvalidVariants => "lexical_plan.variants must contain 1-4 typed variants",
        error.TooManyVariants => "lexical_plan.variants exceeds the four-probe budget",
        error.InvalidVariant => "each lexical_plan variant needs a supported kind and compact text <=400 bytes",
        error.DuplicateVariant => "lexical_plan variants must have distinct text",
        error.InvalidVariantIndex => "lexical_plan.variant_index is outside variants",
        error.QueryVariantMismatch => "KgRecall query must exactly match lexical_plan.variants[variant_index].text",
        error.InvalidStageShape => "seed requires one exact/alias variant; v1 semantic_expansion requires 2-4 non-exact variants; v2 allows 1-4",
        error.SeedTypeFilterForbidden => "the seed stage must omit KgRecall type",
        error.InvalidSeenNodeIds => "lexical_plan.seen_node_ids must contain positive integer ids",
        error.TooManySeenNodeIds => "lexical_plan.seen_node_ids exceeds 32 ids",
        error.DuplicateSeenNodeId => "lexical_plan.seen_node_ids must be unique",
        error.UnexpectedSeenNodeIds => "lexical-query-plan-v2 host-manages seen state; omit seen_node_ids",
    };
}

pub fn ledgerDiagnostic(err: LedgerError) []const u8 {
    return switch (err) {
        error.SeenStateMismatch => "lexical_plan.seen_node_ids does not exactly match the host ledger for this plan",
        error.PlanCapacityExceeded => "the agent run exceeded 32 distinct governed lexical plans",
        error.HitCapacityExceeded => "the bounded host seen ledger is full; stop retrieval",
        error.SemanticExpansionBudgetExceeded => "the agent run already used all four v2 semantic-expansion calls; stop retrieval",
    };
}

fn validCompactText(value: []const u8) bool {
    if (value.len == 0 or value.len > MAX_QUERY_BYTES or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn fingerprint(schema_version: SchemaVersion, intent: Intent, stage: Stage, variants: []const Variant, type_filter: ?[]const u8) [64]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var hash = Sha256.init(.{});
    hashField(&hash, schema_version.text());
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

test "lexical query plan v2 host owns seen state and accepts one synonym expansion" {
    const a = std.testing.allocator;
    const raw =
        \\{"lexical_plan":{"schema_version":"lexical-query-plan-v2","intent":"fact_lookup","stage":"semantic_expansion","variants":[{"kind":"synonym","text":"commencement"}],"variant_index":0}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
    defer parsed.deinit();
    var plan = (try parse(a, parsed.value.object, "commencement", null)) orelse return error.TestUnexpectedResult;
    defer plan.deinit(a);
    try std.testing.expectEqual(SchemaVersion.host_managed_v2, plan.schema_version);
    try std.testing.expectEqual(VariantKind.synonym, plan.selected().kind);
    try std.testing.expect(plan.declared_seen_node_ids == null);

    var ledger = Ledger{};
    var first = try ledger.lockPlan(plan);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 0), first.seenCount());
    try std.testing.expectEqualStrings("agent_run_explicit", first.scope());
    try first.commit(&.{ 41, 43 });

    var second = try ledger.lockPlan(plan);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 2), second.seenCount());
    try std.testing.expect(second.wasSeen(41));
    try second.commit(&.{ 43, 47 });

    const different_plan_raw =
        \\{"lexical_plan":{"schema_version":"lexical-query-plan-v2","intent":"fact_lookup","stage":"semantic_expansion","variants":[{"kind":"paraphrase","text":"graduation event"}],"variant_index":0}}
    ;
    var different_plan_parsed = try std.json.parseFromSlice(std.json.Value, a, different_plan_raw, .{});
    defer different_plan_parsed.deinit();
    var different_plan = (try parse(a, different_plan_parsed.value.object, "graduation event", null)) orelse return error.TestUnexpectedResult;
    defer different_plan.deinit(a);
    var cross_plan = try ledger.lockPlan(different_plan);
    defer cross_plan.deinit();
    try std.testing.expectEqual(@as(usize, 3), cross_plan.seenCount());
    try std.testing.expect(cross_plan.wasSeen(41));
    try cross_plan.commit(&.{41});

    var fourth = try ledger.lockPlan(plan);
    defer fourth.deinit();
    try fourth.commit(&.{49});
    try std.testing.expectError(error.SemanticExpansionBudgetExceeded, ledger.lockPlan(different_plan));

    const caller_seen =
        \\{"lexical_plan":{"schema_version":"lexical-query-plan-v2","intent":"fact_lookup","stage":"semantic_expansion","variants":[{"kind":"synonym","text":"commencement"}],"variant_index":0,"seen_node_ids":[41]}}
    ;
    var caller_seen_parsed = try std.json.parseFromSlice(std.json.Value, a, caller_seen, .{});
    defer caller_seen_parsed.deinit();
    try std.testing.expectError(error.UnexpectedSeenNodeIds, parse(a, caller_seen_parsed.value.object, "commencement", null));
}

test "lexical query ledger capacity failure has no partial write" {
    const a = std.testing.allocator;
    const raw =
        \\{"lexical_plan":{"schema_version":"lexical-query-plan-v2","intent":"fact_lookup","stage":"seed","variants":[{"kind":"exact","text":"needle"}],"variant_index":0}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
    defer parsed.deinit();
    var plan = (try parse(a, parsed.value.object, "needle", null)) orelse return error.TestUnexpectedResult;
    defer plan.deinit(a);

    var ledger = Ledger{};
    ledger.run_node_count = MAX_RUN_SEEN_NODE_IDS - 1;
    const count_before = ledger.run_node_count;
    {
        var guard = try ledger.lockPlan(plan);
        defer guard.deinit();
        try std.testing.expectError(error.HitCapacityExceeded, guard.commit(&.{ 9001, 9002 }));
    }
    try std.testing.expectEqual(count_before, ledger.run_node_count);
    try std.testing.expectEqual(@as(usize, 0), ledger.entry_count);
    try std.testing.expectEqual(@as(u64, 0), ledger.run_node_ids[count_before]);

    var retry = try ledger.lockPlan(plan);
    defer retry.deinit();
    try retry.commit(&.{9001});
    try std.testing.expectEqual(MAX_RUN_SEEN_NODE_IDS, ledger.run_node_count);
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
