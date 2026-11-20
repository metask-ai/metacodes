//! Frozen procedural instructions and their task-local ridge gates.
//! Training lives in scripts/eval/skill_rsi.py. This module never authors a
//! skill, calls a selector model, executes skill text, or changes tool authority.
const std = @import("std");
const pfs = @import("platform").fs;

pub const FEATURE_SCHEMA = "metacodes-skill-text-v1";
pub const FEATURE_COUNT = 5;
pub const MAX_INSTRUCTION_BYTES = 4096;
pub const MAX_POLICY_BYTES = 65536;
pub const PREFIX = "<procedural-skill>\n";
pub const SUFFIX = "\n</procedural-skill>";

pub const Features = [FEATURE_COUNT]f64;
/// Offline/research ablations. The product's single RSI switch enables both.
pub const Flags = struct {
    evolution: bool = false,
    routing: bool = false,

    pub fn enabled(self: Flags) bool {
        return self.evolution or self.routing;
    }
};

pub const Router = struct {
    instruction_sha256: []const u8,
    intercept: f64,
    weights: Features,
    threshold: f64,
    minimum: Features,
    maximum: Features,
};

pub const Candidate = struct {
    instruction: []const u8,
    sha256: []const u8,
    router: ?Router = null,
};

pub const Policy = struct {
    schema_version: u32,
    feature_schema: []const u8,
    model: []const u8,
    seed: Candidate,
    evolved: ?Candidate = null,

    pub fn validate(self: Policy) !void {
        if (self.schema_version != 1 or !std.mem.eql(u8, self.feature_schema, FEATURE_SCHEMA) or self.model.len == 0)
            return error.InvalidSkillPolicy;
        try validateCandidate(self.seed);
        if (self.evolved) |candidate| try validateCandidate(candidate);
    }

    pub fn decide(self: Policy, flags: Flags, model: []const u8, prompt: []const u8) Decision {
        if (!flags.enabled()) return .disabled;
        if (!std.mem.eql(u8, model, self.model)) return .model_mismatch;
        const candidate = if (flags.evolution) self.evolved orelse self.seed else self.seed;
        if (candidate.instruction.len == 0) return .empty;
        if (flags.routing) {
            const router = candidate.router orelse return .missing_router;
            const x = features(prompt);
            var score = router.intercept;
            for (x, 0..) |value, i| {
                if (value < router.minimum[i] or value > router.maximum[i]) return .out_of_support;
                score += router.weights[i] * value;
            }
            if (!std.math.isFinite(score) or
                (score < router.threshold and @abs(score - router.threshold) > 1e-12)) return .below_threshold;
        }
        return .{ .apply = candidate.instruction };
    }
};

pub const Decision = union(enum) {
    disabled,
    model_mismatch,
    empty,
    missing_router,
    out_of_support,
    below_threshold,
    apply: []const u8,
};

pub const Loaded = struct {
    parsed: std.json.Parsed(Policy),

    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Loaded {
        if (bytes.len > MAX_POLICY_BYTES) return error.SkillPolicyTooLarge;
        const parsed = try std.json.parseFromSlice(Policy, gpa, bytes, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        try parsed.value.validate();
        return .{ .parsed = parsed };
    }

    pub fn load(gpa: std.mem.Allocator, path: []const u8) !Loaded {
        const path_z = try gpa.dupeZ(u8, path);
        defer gpa.free(path_z);
        const fd = pfs.open(path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return error.SkillPolicyUnreadable;
        defer _ = pfs.close(fd);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = pfs.read(fd, &buf);
            if (n < 0) {
                if (pfs.lastErrnoIs(.INTR)) continue;
                return error.SkillPolicyUnreadable;
            }
            if (n == 0) break;
            const count: usize = @intCast(n);
            if (bytes.items.len + count > MAX_POLICY_BYTES) return error.SkillPolicyTooLarge;
            try bytes.appendSlice(gpa, buf[0..count]);
        }
        return parse(gpa, bytes.items);
    }

    pub fn deinit(self: *Loaded) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

fn validateCandidate(candidate: Candidate) !void {
    if (candidate.instruction.len > MAX_INSTRUCTION_BYTES or
        std.mem.indexOfScalar(u8, candidate.instruction, 0) != null or
        !std.unicode.utf8ValidateSlice(candidate.instruction) or
        std.mem.indexOf(u8, candidate.instruction, PREFIX) != null or
        std.mem.indexOf(u8, candidate.instruction, SUFFIX) != null)
        return error.InvalidSkillInstruction;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(candidate.instruction, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, candidate.sha256)) return error.SkillInstructionHashMismatch;
    if (candidate.router) |router| {
        if (!std.mem.eql(u8, router.instruction_sha256, candidate.sha256) or
            !std.math.isFinite(router.intercept) or !std.math.isFinite(router.threshold))
            return error.InvalidSkillRouter;
        for (router.weights, 0..) |weight, i| {
            if (!std.math.isFinite(weight) or !std.math.isFinite(router.minimum[i]) or
                !std.math.isFinite(router.maximum[i]) or router.minimum[i] < 0 or
                router.minimum[i] > router.maximum[i]) return error.InvalidSkillRouter;
        }
    }
}

fn wordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Portable feature contract shared byte-for-byte with the Python trainer:
/// UTF-8 bytes / 4096, ASCII words / 512, quotes, relation cues, number cues.
/// No task IDs, answers, scores, timestamps, paths or embeddings are inputs.
pub fn features(prompt: []const u8) Features {
    var words: usize = 0;
    var relation = false;
    var numeric = false;
    var i: usize = 0;
    while (i < prompt.len) {
        if (!wordByte(prompt[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < prompt.len and wordByte(prompt[i])) : (i += 1) {}
        words += 1;
        const word = prompt[start..i];
        for ([_][]const u8{ "before", "after", "between", "within", "left", "right", "above", "below" }) |cue|
            relation = relation or std.ascii.eqlIgnoreCase(word, cue);
        for ([_][]const u8{ "count", "calculate", "number", "total", "sum", "many", "much" }) |cue|
            numeric = numeric or std.ascii.eqlIgnoreCase(word, cue);
    }
    for ([_][]const u8{ "多少", "几个", "总数" }) |cue|
        numeric = numeric or std.mem.indexOf(u8, prompt, cue) != null;
    const quoted = std.mem.indexOfAny(u8, prompt, "\"'") != null or
        std.mem.indexOf(u8, prompt, "“") != null or std.mem.indexOf(u8, prompt, "”") != null;
    return .{
        @as(f64, @floatFromInt(prompt.len)) / 4096.0,
        @as(f64, @floatFromInt(words)) / 512.0,
        if (quoted) 1 else 0,
        if (relation) 1 else 0,
        if (numeric) 1 else 0,
    };
}

test "skill RSI independent switches select seed, evolved or baseline" {
    const router: Router = .{
        .instruction_sha256 = "unused in pure decision fixture",
        .intercept = 0,
        .weights = .{ 0, 0, 0, 0, 1 },
        .threshold = 0.5,
        .minimum = .{ 0, 0, 0, 0, 0 },
        .maximum = .{ 10, 10, 1, 1, 1 },
    };
    const policy: Policy = .{
        .schema_version = 1,
        .feature_schema = FEATURE_SCHEMA,
        .model = "test",
        .seed = .{ .instruction = "seed", .sha256 = "", .router = router },
        .evolved = .{ .instruction = "evolved", .sha256 = "", .router = router },
    };
    try std.testing.expect(policy.decide(.{}, "test", "count") == .disabled);
    try std.testing.expectEqualStrings("evolved", policy.decide(.{ .evolution = true }, "test", "read").apply);
    try std.testing.expectEqualStrings("seed", policy.decide(.{ .routing = true }, "test", "count").apply);
    try std.testing.expect(policy.decide(.{ .routing = true }, "test", "read") == .below_threshold);
    try std.testing.expectEqualStrings("evolved", policy.decide(.{ .evolution = true, .routing = true }, "test", "count").apply);
    try std.testing.expect(policy.decide(.{ .evolution = true }, "other", "count") == .model_mismatch);
    try std.testing.expect(policy.decide(.{ .routing = true }, "test", "count " ** 10000) == .out_of_support);
}

test "skill RSI portable multilingual features and stale router rejection" {
    try std.testing.expectEqual(Features{ 34.0 / 4096.0, 4.0 / 512.0, 1, 1, 1 }, features("Count 'items' before 总数 please"));
    try std.testing.expectEqual(@as(f64, 0), features("İ K")[1]);
    try std.testing.expectError(error.SkillInstructionHashMismatch, validateCandidate(.{
        .instruction = "changed",
        .sha256 = "wrong",
    }));
}
