//! Deterministic, content-addressed aggregation of authenticated RuleImpact runs.
//!
//! An aggregate is not a caller-authored summary. Every member is reopened
//! through the single-run receipt boundary, folded again from its completed
//! journal interval, sorted, checked for duplication/overlap, and summed with
//! overflow checks. The persisted receipt retains the member paths needed to
//! repeat that authentication before any Lean-governed lifecycle transition.

const std = @import("std");
const pfs = @import("platform").fs;
const observation = @import("../tools/observation.zig");
const impact = @import("rule_impact_stats.zig");
const receipt = @import("rule_impact_receipt.zig");
const session_id_mod = @import("session_id.zig");

pub const SCHEMA_VERSION = "metacodes-rule-impact-aggregate-receipt-v1";
pub const FILE_PREFIX = "rule-impact-aggregate-receipt-";
pub const MAX_MEMBERS: usize = 64;
pub const MAX_RECORD_BYTES: usize = 1024 * 1024;

pub const RuleIdentity = impact.RuleIdentity;

pub const Facts = struct {
    completed_run: bool,
    evidence_authenticated: bool,
    window_occurrences: u64,
    formal_decisions: u64,
    formal_faults: u64,
    exposures: u64,
    admits: u64,
    blocks: u64,
    faults: u64,
    shadow_divergences: u64,
    task_success: bool,
    trustworthy_success: bool,
    drift_detected: bool,
    false_interventions: u64,
    regressions: u64,
    physical_checker_calls: u64,
    checker_elapsed_ns: u64,
    provider_requests: u64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    metered_tokens: u64,
    cost_microusd: u64,
    wall_elapsed_ns: u64,
};

pub const MemberRef = struct {
    session_dir: []const u8,
    receipt_id: [64]u8,
};

pub const Input = struct {
    policy_epoch: u64,
    expected_issuer_sha256: [64]u8,
    identity: RuleIdentity,
    members: []const MemberRef,
};

pub const Member = struct {
    session_dir: []const u8,
    project_sha256: [64]u8,
    issuer_sha256: [64]u8,
    candidate_id: [64]u8,
    bundle_sha256: [64]u8,
    bundle_revision: u64,
    session_id: session_id_mod.SessionId,
    run_id: session_id_mod.SessionId,
    first_sequence: u64,
    last_sequence: u64,
    source_interval_sha256: [64]u8,
    label_receipt_sha256: [64]u8,
    outcome_evidence_sha256: [64]u8,
    usage_evidence_sha256: [64]u8,
    facts: Facts,
};

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    aggregate_receipt_id: [64]u8,
    policy_epoch: u64,
    identity: RuleIdentity,
    issuer_sha256: [64]u8,
    members_sha256: [64]u8,
    source_intervals_sha256: [64]u8,
    outcome_evidence_sha256: [64]u8,
    usage_evidence_sha256: [64]u8,
    facts: Facts,
    members: []Member,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const PersistResult = struct {
    receipt_id: [64]u8,
    created: bool,
    member_count: u64,
};

const WireMember = struct {
    session_dir: []const u8,
    project_sha256: []const u8,
    issuer_sha256: []const u8,
    candidate_id: []const u8,
    bundle_sha256: []const u8,
    bundle_revision: u64,
    session_id: []const u8,
    run_id: []const u8,
    first_sequence: u64,
    last_sequence: u64,
    source_interval_sha256: []const u8,
    label_receipt_sha256: []const u8,
    outcome_evidence_sha256: []const u8,
    usage_evidence_sha256: []const u8,
    facts: Facts,
};

const WireBody = struct {
    schema_version: []const u8 = SCHEMA_VERSION,
    policy_epoch: u64,
    project_sha256: []const u8,
    issuer_sha256: []const u8,
    candidate_id: []const u8,
    bundle_sha256: []const u8,
    bundle_revision: u64,
    members_sha256: []const u8,
    source_intervals_sha256: []const u8,
    outcome_evidence_sha256: []const u8,
    usage_evidence_sha256: []const u8,
    facts: Facts,
    members: []const WireMember,
};

const WireRecord = struct {
    receipt_id: []const u8,
    body: WireBody,
};

pub fn persist(
    allocator: std.mem.Allocator,
    aggregate_dir: []const u8,
    input: Input,
) !PersistResult {
    if (!std.fs.path.isAbsolute(aggregate_dir)) return error.InvalidAggregateDirectory;
    var built = try build(allocator, input);
    defer built.deinit();
    const body_json = try renderBody(allocator, &built);
    defer allocator.free(body_json);
    const receipt_id = observation.sha256Hex(body_json);
    const record_json = try renderRecord(allocator, receipt_id, body_json);
    defer allocator.free(record_json);
    if (record_json.len + 1 > MAX_RECORD_BYTES) return error.RecordTooLarge;
    const created = try persistRecord(aggregate_dir, receipt_id, record_json);
    return .{
        .receipt_id = receipt_id,
        .created = created,
        .member_count = @intCast(built.members.len),
    };
}

/// Reopen the aggregate receipt and then reauthenticate every single-run
/// member. The returned sums are therefore observations, not trusted JSON.
pub fn loadBound(
    allocator: std.mem.Allocator,
    aggregate_dir: []const u8,
    receipt_id: [64]u8,
) !Loaded {
    if (!std.fs.path.isAbsolute(aggregate_dir) or !validNonzeroHex(receipt_id))
        return error.InvalidAggregateInput;
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const a = parse_arena.allocator();
    const path = try std.fmt.allocPrint(a, "{s}/{s}{s}.json", .{
        aggregate_dir, FILE_PREFIX, receipt_id[0..],
    });
    const raw = try readBounded(a, path, MAX_RECORD_BYTES);
    if (raw.len < 2 or raw[raw.len - 1] != '\n') return error.InvalidAggregateReceipt;
    const parsed = std.json.parseFromSliceLeaky(WireRecord, a, raw[0 .. raw.len - 1], .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAggregateReceipt,
    };
    const parsed_id = parseHex64(parsed.receipt_id) orelse return error.InvalidAggregateReceipt;
    if (!std.mem.eql(u8, &parsed_id, &receipt_id) or
        !std.mem.eql(u8, parsed.body.schema_version, SCHEMA_VERSION) or
        parsed.body.policy_epoch == 0 or parsed.body.members.len == 0 or
        parsed.body.members.len > MAX_MEMBERS)
        return error.InvalidAggregateReceipt;
    const canonical_record = try std.json.Stringify.valueAlloc(a, parsed, .{});
    if (!std.mem.eql(u8, canonical_record, raw[0 .. raw.len - 1]))
        return error.NonCanonicalAggregateReceipt;

    const identity = RuleIdentity{
        .project_sha256 = parseHex64(parsed.body.project_sha256) orelse
            return error.InvalidAggregateReceipt,
        .candidate_id = parseHex64(parsed.body.candidate_id) orelse
            return error.InvalidAggregateReceipt,
        .bundle_sha256 = parseHex64(parsed.body.bundle_sha256) orelse
            return error.InvalidAggregateReceipt,
        .bundle_revision = parsed.body.bundle_revision,
    };
    const issuer = parseHex64(parsed.body.issuer_sha256) orelse
        return error.InvalidAggregateReceipt;
    const refs = try a.alloc(MemberRef, parsed.body.members.len);
    for (parsed.body.members, refs) |member, *ref| {
        ref.* = .{
            .session_dir = member.session_dir,
            .receipt_id = parseHex64(member.label_receipt_sha256) orelse
                return error.InvalidAggregateReceipt,
        };
    }
    var rebuilt = try build(allocator, .{
        .policy_epoch = parsed.body.policy_epoch,
        .expected_issuer_sha256 = issuer,
        .identity = identity,
        .members = refs,
    });
    errdefer rebuilt.deinit();
    const rebuilt_body = try renderBody(allocator, &rebuilt);
    defer allocator.free(rebuilt_body);
    const parsed_body = try std.json.Stringify.valueAlloc(a, parsed.body, .{});
    if (!std.mem.eql(u8, rebuilt_body, parsed_body) or
        !std.mem.eql(u8, &observation.sha256Hex(rebuilt_body), &receipt_id))
        return error.AggregateEvidenceChanged;
    rebuilt.aggregate_receipt_id = receipt_id;
    return rebuilt;
}

fn build(allocator: std.mem.Allocator, input: Input) !Loaded {
    if (input.policy_epoch == 0 or input.members.len == 0 or input.members.len > MAX_MEMBERS or
        !validIdentity(input.identity) or !validNonzeroHex(input.expected_issuer_sha256))
        return error.InvalidAggregateInput;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const members = try a.alloc(Member, input.members.len);
    for (input.members, members) |ref, *member| {
        if (!std.fs.path.isAbsolute(ref.session_dir) or !validNonzeroHex(ref.receipt_id))
            return error.InvalidAggregateInput;
        var authenticated = receipt.deriveImpact(allocator, ref.session_dir, ref.receipt_id) catch
            return error.InvalidMemberEvidence;
        defer authenticated.deinit(allocator);
        if (!std.mem.eql(u8, &authenticated.issuer_sha256, &input.expected_issuer_sha256) or
            !std.mem.eql(u8, &authenticated.project_sha256, &input.identity.project_sha256))
            return error.MixedMemberIdentity;
        const rule = findRule(authenticated.snapshot.rules, input.identity) orelse
            return error.MixedMemberIdentity;
        member.* = .{
            .session_dir = try a.dupe(u8, ref.session_dir),
            .project_sha256 = rule.identity.project_sha256,
            .issuer_sha256 = authenticated.issuer_sha256,
            .candidate_id = rule.identity.candidate_id,
            .bundle_sha256 = rule.identity.bundle_sha256,
            .bundle_revision = rule.identity.bundle_revision,
            .session_id = authenticated.observation.session_id,
            .run_id = authenticated.observation.run_id,
            .first_sequence = authenticated.observation.first_sequence,
            .last_sequence = authenticated.observation.last_sequence,
            .source_interval_sha256 = authenticated.snapshot.source_interval_sha256,
            .label_receipt_sha256 = authenticated.snapshot.evidence.label_receipt_sha256,
            .outcome_evidence_sha256 = authenticated.snapshot.evidence.outcome_evidence_sha256,
            .usage_evidence_sha256 = authenticated.snapshot.evidence.usage_evidence_sha256,
            .facts = try factsFrom(&authenticated.snapshot, rule),
        };
    }
    std.mem.sort(Member, members, {}, memberLessThan);
    try validateWindows(members);
    const facts = try aggregateFacts(members);
    const wire_members = try makeWireMembers(a, members);
    const members_json = try std.json.Stringify.valueAlloc(a, wire_members, .{});
    return .{
        .arena = arena,
        .aggregate_receipt_id = [_]u8{'0'} ** 64,
        .policy_epoch = input.policy_epoch,
        .identity = input.identity,
        .issuer_sha256 = input.expected_issuer_sha256,
        .members_sha256 = observation.sha256Hex(members_json),
        .source_intervals_sha256 = try hashMemberField(a, "source-intervals-v1", members, .source),
        .outcome_evidence_sha256 = try hashMemberField(a, "outcome-evidence-v1", members, .outcome),
        .usage_evidence_sha256 = try hashMemberField(a, "usage-evidence-v1", members, .usage),
        .facts = facts,
        .members = members,
    };
}

fn factsFrom(snapshot: *const impact.Snapshot, rule: impact.RuleStats) !Facts {
    if (!snapshot.evidence.authenticated) return error.InvalidMemberEvidence;
    const labels = snapshot.labels;
    const task_success = labels.task_success orelse return error.IncompleteMemberLabels;
    const trustworthy_success = labels.trustworthy_success orelse return error.IncompleteMemberLabels;
    const drift_detected = labels.drift_detected orelse return error.IncompleteMemberLabels;
    const shadow_divergences = std.math.add(
        u64,
        rule.shadow_pre_blocks_followed_by_dispatch,
        rule.shadow_pre_faults_followed_by_dispatch,
    ) catch return error.AggregateOverflow;
    return .{
        .completed_run = true,
        .evidence_authenticated = true,
        .window_occurrences = 1,
        .formal_decisions = snapshot.formal_decisions,
        .formal_faults = snapshot.formal_faults,
        .exposures = rule.exposures,
        .admits = rule.admits,
        .blocks = rule.blocks,
        .faults = rule.faults,
        .shadow_divergences = shadow_divergences,
        .task_success = task_success,
        .trustworthy_success = trustworthy_success,
        .drift_detected = drift_detected,
        .false_interventions = labels.false_interventions orelse return error.IncompleteMemberLabels,
        .regressions = labels.regressions orelse return error.IncompleteMemberLabels,
        .physical_checker_calls = snapshot.physical_checker_calls,
        .checker_elapsed_ns = snapshot.checker_elapsed_ns,
        .provider_requests = labels.provider_requests orelse return error.IncompleteMemberLabels,
        .input_tokens = labels.input_tokens orelse return error.IncompleteMemberLabels,
        .output_tokens = labels.output_tokens orelse return error.IncompleteMemberLabels,
        .cache_read_tokens = labels.cache_read_tokens orelse return error.IncompleteMemberLabels,
        .cache_write_tokens = labels.cache_write_tokens orelse return error.IncompleteMemberLabels,
        .metered_tokens = labels.metered_tokens orelse return error.IncompleteMemberLabels,
        .cost_microusd = labels.cost_microusd orelse return error.IncompleteMemberLabels,
        .wall_elapsed_ns = labels.wall_elapsed_ns orelse return error.IncompleteMemberLabels,
    };
}

fn aggregateFacts(members: []const Member) !Facts {
    var result = std.mem.zeroes(Facts);
    result.completed_run = true;
    result.evidence_authenticated = true;
    result.task_success = true;
    result.trustworthy_success = true;
    for (members) |member| {
        const facts = member.facts;
        if (!facts.completed_run or !facts.evidence_authenticated or facts.window_occurrences != 1)
            return error.InvalidMemberFacts;
        result.window_occurrences = try checkedAdd(result.window_occurrences, 1);
        result.formal_decisions = try checkedAdd(result.formal_decisions, facts.formal_decisions);
        result.formal_faults = try checkedAdd(result.formal_faults, facts.formal_faults);
        result.exposures = try checkedAdd(result.exposures, facts.exposures);
        result.admits = try checkedAdd(result.admits, facts.admits);
        result.blocks = try checkedAdd(result.blocks, facts.blocks);
        result.faults = try checkedAdd(result.faults, facts.faults);
        result.shadow_divergences = try checkedAdd(result.shadow_divergences, facts.shadow_divergences);
        result.false_interventions = try checkedAdd(result.false_interventions, facts.false_interventions);
        result.regressions = try checkedAdd(result.regressions, facts.regressions);
        result.physical_checker_calls = try checkedAdd(result.physical_checker_calls, facts.physical_checker_calls);
        result.checker_elapsed_ns = try checkedAdd(result.checker_elapsed_ns, facts.checker_elapsed_ns);
        result.provider_requests = try checkedAdd(result.provider_requests, facts.provider_requests);
        result.input_tokens = try checkedAdd(result.input_tokens, facts.input_tokens);
        result.output_tokens = try checkedAdd(result.output_tokens, facts.output_tokens);
        result.cache_read_tokens = try checkedAdd(result.cache_read_tokens, facts.cache_read_tokens);
        result.cache_write_tokens = try checkedAdd(result.cache_write_tokens, facts.cache_write_tokens);
        result.metered_tokens = try checkedAdd(result.metered_tokens, facts.metered_tokens);
        result.cost_microusd = try checkedAdd(result.cost_microusd, facts.cost_microusd);
        result.wall_elapsed_ns = try checkedAdd(result.wall_elapsed_ns, facts.wall_elapsed_ns);
        result.task_success = result.task_success and facts.task_success;
        result.trustworthy_success = result.trustworthy_success and facts.trustworthy_success;
        result.drift_detected = result.drift_detected or facts.drift_detected;
    }
    return result;
}

fn validateWindows(members: []const Member) !void {
    for (members, 0..) |member, index| {
        if (member.first_sequence > member.last_sequence) return error.InvalidWindow;
        for (members[index + 1 ..]) |other| {
            if (std.mem.eql(u8, &member.label_receipt_sha256, &other.label_receipt_sha256))
                return error.DuplicateMemberReceipt;
            if (std.mem.eql(u8, &member.source_interval_sha256, &other.source_interval_sha256))
                return error.DuplicateMemberWindow;
            if (std.mem.eql(u8, member.session_id.asSlice(), other.session_id.asSlice()) and
                member.first_sequence <= other.last_sequence and
                other.first_sequence <= member.last_sequence)
                return error.OverlappingMemberWindow;
        }
    }
}

fn memberLessThan(_: void, left: Member, right: Member) bool {
    const identity = [_]struct { a: []const u8, b: []const u8 }{
        .{ .a = &left.project_sha256, .b = &right.project_sha256 },
        .{ .a = &left.candidate_id, .b = &right.candidate_id },
        .{ .a = &left.bundle_sha256, .b = &right.bundle_sha256 },
    };
    for (identity) |pair| switch (std.mem.order(u8, pair.a, pair.b)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    };
    if (left.bundle_revision != right.bundle_revision)
        return left.bundle_revision < right.bundle_revision;
    const window = [_]struct { a: []const u8, b: []const u8 }{
        .{ .a = left.session_id.asSlice(), .b = right.session_id.asSlice() },
        .{ .a = left.run_id.asSlice(), .b = right.run_id.asSlice() },
    };
    for (window) |pair| switch (std.mem.order(u8, pair.a, pair.b)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    };
    if (left.first_sequence != right.first_sequence)
        return left.first_sequence < right.first_sequence;
    if (left.last_sequence != right.last_sequence)
        return left.last_sequence < right.last_sequence;
    const interval_order = std.mem.order(u8, &left.source_interval_sha256, &right.source_interval_sha256);
    if (interval_order != .eq) return interval_order == .lt;
    return std.mem.lessThan(u8, &left.label_receipt_sha256, &right.label_receipt_sha256);
}

fn findRule(rules: []const impact.RuleStats, expected: RuleIdentity) ?impact.RuleStats {
    for (rules) |rule| if (std.meta.eql(rule.identity, expected)) return rule;
    return null;
}

fn validIdentity(identity: RuleIdentity) bool {
    return identity.bundle_revision > 0 and validNonzeroHex(identity.project_sha256) and
        validNonzeroHex(identity.candidate_id) and validNonzeroHex(identity.bundle_sha256);
}

fn checkedAdd(left: u64, right: u64) !u64 {
    return std.math.add(u64, left, right) catch return error.AggregateOverflow;
}

const HashField = enum { source, outcome, usage };

fn hashMemberField(
    allocator: std.mem.Allocator,
    domain: []const u8,
    members: []const Member,
    field: HashField,
) ![64]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, domain);
    try bytes.append(allocator, 0);
    for (members) |member| {
        const digest = switch (field) {
            .source => member.source_interval_sha256,
            .outcome => member.outcome_evidence_sha256,
            .usage => member.usage_evidence_sha256,
        };
        try bytes.appendSlice(allocator, &digest);
        try bytes.append(allocator, '\n');
    }
    return observation.sha256Hex(bytes.items);
}

fn makeWireMembers(allocator: std.mem.Allocator, members: []const Member) ![]WireMember {
    const wire = try allocator.alloc(WireMember, members.len);
    for (members, wire) |*member, *item| item.* = .{
        .session_dir = member.session_dir,
        .project_sha256 = &member.project_sha256,
        .issuer_sha256 = &member.issuer_sha256,
        .candidate_id = &member.candidate_id,
        .bundle_sha256 = &member.bundle_sha256,
        .bundle_revision = member.bundle_revision,
        .session_id = member.session_id.asSlice(),
        .run_id = member.run_id.asSlice(),
        .first_sequence = member.first_sequence,
        .last_sequence = member.last_sequence,
        .source_interval_sha256 = &member.source_interval_sha256,
        .label_receipt_sha256 = &member.label_receipt_sha256,
        .outcome_evidence_sha256 = &member.outcome_evidence_sha256,
        .usage_evidence_sha256 = &member.usage_evidence_sha256,
        .facts = member.facts,
    };
    return wire;
}

fn renderBody(allocator: std.mem.Allocator, loaded: *const Loaded) ![]u8 {
    const members = try makeWireMembers(allocator, loaded.members);
    defer allocator.free(members);
    return std.json.Stringify.valueAlloc(allocator, WireBody{
        .policy_epoch = loaded.policy_epoch,
        .project_sha256 = &loaded.identity.project_sha256,
        .issuer_sha256 = &loaded.issuer_sha256,
        .candidate_id = &loaded.identity.candidate_id,
        .bundle_sha256 = &loaded.identity.bundle_sha256,
        .bundle_revision = loaded.identity.bundle_revision,
        .members_sha256 = &loaded.members_sha256,
        .source_intervals_sha256 = &loaded.source_intervals_sha256,
        .outcome_evidence_sha256 = &loaded.outcome_evidence_sha256,
        .usage_evidence_sha256 = &loaded.usage_evidence_sha256,
        .facts = loaded.facts,
        .members = members,
    }, .{});
}

fn renderRecord(allocator: std.mem.Allocator, receipt_id: [64]u8, body_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(WireBody, allocator, body_json, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    return std.json.Stringify.valueAlloc(allocator, WireRecord{
        .receipt_id = &receipt_id,
        .body = parsed.value,
    }, .{});
}

fn persistRecord(directory: []const u8, receipt_id: [64]u8, record_json: []const u8) !bool {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}{s}.json\x00", .{
        directory, FILE_PREFIX, receipt_id[0..],
    });
    const fd = pfs.open(@ptrCast(path.ptr), .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
    }, @as(std.c.mode_t, 0o600));
    if (fd >= 0) {
        var write_fd = fd;
        errdefer {
            if (write_fd >= 0) _ = pfs.close(write_fd);
        }
        try pfs.makeCloseOnExec(write_fd);
        try writeAll(write_fd, record_json);
        try writeAll(write_fd, "\n");
        try pfs.fsyncChecked(write_fd);
        _ = pfs.close(write_fd);
        write_fd = -1;
        try fsyncDirectory(directory);
        return true;
    }
    const existing = try readBounded(std.heap.c_allocator, path[0 .. path.len - 1], MAX_RECORD_BYTES);
    defer std.heap.c_allocator.free(existing);
    if (existing.len != record_json.len + 1 or
        !std.mem.eql(u8, existing[0..record_json.len], record_json) or
        existing[record_json.len] != '\n') return error.AggregateReceiptCollision;
    return false;
}

fn readBounded(allocator: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.StatFailed;
    if (!before.is_regular or before.link_count != 1 or before.size == 0 or before.size > max)
        return error.InvalidFile;
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.read(fd, bytes[offset..]);
        if (count <= 0) return error.ReadFailed;
        offset += @intCast(count);
    }
    // Size-only checks miss an in-place rewrite. Verify the same opened inode
    // byte-for-byte before accepting its content-addressed identity.
    if (pfs.lseek(fd, 0, .set) != 0) return error.SeekFailed;
    var verified: usize = 0;
    var verify_buffer: [4096]u8 = undefined;
    while (verified < bytes.len) {
        const wanted = @min(verify_buffer.len, bytes.len - verified);
        const count = pfs.read(fd, verify_buffer[0..wanted]);
        if (count <= 0) return error.ReadFailed;
        const got: usize = @intCast(count);
        if (!std.mem.eql(u8, bytes[verified .. verified + got], verify_buffer[0..got]))
            return error.ChangedDuringRead;
        verified += got;
    }
    const after = pfs.fileInfo(fd) catch return error.StatFailed;
    if (!after.is_regular or after.link_count != 1 or after.size != before.size)
        return error.ChangedDuringRead;
    return bytes;
}

fn parseHex64(value: []const u8) ?[64]u8 {
    if (value.len != 64) return null;
    var result: [64]u8 = undefined;
    for (value, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
        result[index] = byte;
    }
    return result;
}

fn validNonzeroHex(value: [64]u8) bool {
    _ = parseHex64(&value) orelse return false;
    for (value) |byte| if (byte != '0') return true;
    return false;
}

fn writeAll(fd: pfs.Fd, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.write(fd, bytes[offset..]);
        if (count <= 0) return error.WriteFailed;
        offset += @intCast(count);
    }
}

fn fsyncDirectory(directory: []const u8) !void {
    if (@import("builtin").os.tag == .windows) return;
    const path_z = try std.heap.c_allocator.dupeZ(u8, directory);
    defer std.heap.c_allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.DirectoryOpenFailed;
    defer _ = pfs.close(fd);
    try pfs.fsyncChecked(fd);
}
