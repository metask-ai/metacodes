//! Durable audit ledger for sealed Skill runs (doc/SEALED_SKILL_PROTOCOL.md
//! §6.6, §9 "Ledger").
//!
//! `<state root>/ledger/sealed.ndjson`, one JSON object per line:
//!
//! - `step`: every Step the gateway returned — its usage, the hash-chain
//!   link (`digest`, `prev_digest`), the issuer, and the id and name of every
//!   call it carried (`tool_calls`);
//! - `results`: every `runs.continue` the client sent — for each result its
//!   `tool_use_id`, the SHA-256 of the content as sent, its size and the
//!   `is_error` / `truncated` / `refusal` / `redactions` it carried;
//! - `charge`: the receipt on `final` and `failed`.
//!
//! Together they let the subscriber show, after the fact, what the gateway
//! asked for and what this machine answered (§8.3), without keeping the
//! contents themselves. The gateway's `cost_micros` is recorded as served;
//! the client never recomputes it.

const std = @import("std");
const pfs = @import("platform").fs;
const fs_util = @import("metacodes-base").util.fs;
const protocol = @import("protocol.zig");

pub const FILE_NAME = "sealed.ndjson";

pub const Kind = enum { step, results, charge };

/// A call the Step carried (§6.6 "the call ids and names").
pub const CallRef = struct {
    id: []const u8,
    name: []const u8,
};

/// What the client sent for one call (§6.6 "a digest of each result").
pub const ResultRef = struct {
    tool_use_id: []const u8,
    /// `sha256:<hex>` over the content exactly as sent (after redaction and
    /// truncation).
    sha256: []const u8,
    bytes: u64,
    is_error: bool = false,
    truncated: bool = false,
    /// `@tagName` of the refusal, "" when none.
    refusal: []const u8 = "",
    redactions: []const []const u8 = &.{},
};

pub const Record = struct {
    kind: Kind,
    ts: i64,
    session_id: []const u8,
    gateway: []const u8,
    skill_id: []const u8,
    run_id: []const u8,
    seq: u64,
    step_kind: []const u8 = "",
    model: []const u8 = "",
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_creation_tokens: u64 = 0,
    cost_micros: i64 = 0,
    cumulative_cost_micros: i64 = 0,
    currency: []const u8 = "",
    digest: []const u8 = "",
    prev_digest: []const u8 = "",
    issuer_skill_host: []const u8 = "",
    issuer_inference_gateway: []const u8 = "",
    /// Number of tool calls the Step carried (`charge`: the receipt's steps).
    calls: u64 = 0,
    /// `step`: the calls, by id and name.
    tool_calls: []const CallRef = &.{},
    /// `results`: what was sent for each call of the answered Step.
    results: []const ResultRef = &.{},
    /// `results`: the digest of the whole array as sent; `step`: the digest
    /// the gateway bound into the Step (§8.3). Equal on a healthy chain.
    results_digest: []const u8 = "",
    /// `step`: passages of the Skill's sealed content the gateway replaced
    /// with its marker in this Step (§8.5).
    disclosure_redactions: u64 = 0,
};

/// `METACODES_LEDGER_DIR/sealed.ndjson`, else `<state_root>/ledger/sealed.ndjson`.
pub fn ledgerPath(allocator: std.mem.Allocator, state_root: []const u8) ![]u8 {
    if (std.c.getenv("METACODES_LEDGER_DIR")) |raw|
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, std.mem.span(raw), "/"), FILE_NAME });
    if (state_root.len == 0) return error.NoHome;
    return std.fs.path.join(allocator, &.{ state_root, "ledger", FILE_NAME });
}

pub fn render(allocator: std.mem.Allocator, record: Record) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"schema\":\"metacodes.sealed-ledger/v1\",\"kind\":");
    try protocol.writeString(w, @tagName(record.kind));
    try w.print(",\"ts\":{d},\"session_id\":", .{record.ts});
    try protocol.writeString(w, record.session_id);
    try w.writeAll(",\"gateway\":");
    try protocol.writeString(w, record.gateway);
    try w.writeAll(",\"skill_id\":");
    try protocol.writeString(w, record.skill_id);
    try w.writeAll(",\"run_id\":");
    try protocol.writeString(w, record.run_id);
    try w.print(",\"seq\":{d},\"step_kind\":", .{record.seq});
    try protocol.writeString(w, record.step_kind);
    try w.writeAll(",\"model\":");
    try protocol.writeString(w, record.model);
    try w.print(
        ",\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_creation_tokens\":{d},\"cost_micros\":{d},\"cumulative_cost_micros\":{d},\"currency\":",
        .{ record.input_tokens, record.output_tokens, record.cache_read_tokens, record.cache_creation_tokens, record.cost_micros, record.cumulative_cost_micros },
    );
    try protocol.writeString(w, record.currency);
    try w.writeAll(",\"digest\":");
    try protocol.writeString(w, record.digest);
    try w.writeAll(",\"prev_digest\":");
    try protocol.writeString(w, record.prev_digest);
    try w.writeAll(",\"issuer\":{\"skill_host\":");
    try protocol.writeString(w, record.issuer_skill_host);
    try w.writeAll(",\"inference_gateway\":");
    try protocol.writeString(w, record.issuer_inference_gateway);
    try w.print("}},\"calls\":{d},\"tool_calls\":[", .{record.calls});
    for (record.tool_calls, 0..) |call, index| {
        if (index != 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try protocol.writeString(w, call.id);
        try w.writeAll(",\"name\":");
        try protocol.writeString(w, call.name);
        try w.writeByte('}');
    }
    try w.writeAll("],\"results\":[");
    for (record.results, 0..) |result, index| {
        if (index != 0) try w.writeByte(',');
        try w.writeAll("{\"tool_use_id\":");
        try protocol.writeString(w, result.tool_use_id);
        try w.writeAll(",\"sha256\":");
        try protocol.writeString(w, result.sha256);
        try w.print(",\"bytes\":{d},\"is_error\":{},\"truncated\":{}", .{ result.bytes, result.is_error, result.truncated });
        if (result.refusal.len != 0) {
            try w.writeAll(",\"refusal\":");
            try protocol.writeString(w, result.refusal);
        }
        try w.writeAll(",\"redactions\":[");
        for (result.redactions, 0..) |ref, ref_index| {
            if (ref_index != 0) try w.writeByte(',');
            try protocol.writeString(w, ref);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("],\"results_digest\":");
    try protocol.writeString(w, record.results_digest);
    try w.print(",\"disclosure_redactions\":{d}}}\n", .{record.disclosure_redactions});
    return out.toOwnedSlice();
}

pub fn append(allocator: std.mem.Allocator, state_root: []const u8, record: Record) !void {
    const path = try ledgerPath(allocator, state_root);
    defer allocator.free(path);
    const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try fs_util.mkdirParents(dir);
    const line = try render(allocator, record);
    defer allocator.free(line);
    const z = try allocator.dupeZ(u8, path);
    defer allocator.free(z);
    const fd = pfs.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .NOFOLLOW = true }, 0o600);
    if (fd < 0) return error.WriteFailed;
    defer pfs.close(fd);
    var written: usize = 0;
    while (written < line.len) {
        const n = pfs.write(fd, line[written..]);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

/// Whole ledger, or `error.NotFound`.
pub fn read(allocator: std.mem.Allocator, state_root: []const u8) ![]u8 {
    const path = try ledgerPath(allocator, state_root);
    defer allocator.free(path);
    const z = try allocator.dupeZ(u8, path);
    defer allocator.free(z);
    const fd = pfs.open(z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.NotFound;
    defer pfs.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &chunk);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(allocator, chunk[0..@intCast(n)]);
    }
    return out.toOwnedSlice(allocator);
}

test "ledger line carries the gateway's charge verbatim" {
    const a = std.testing.allocator;
    const line = try render(a, .{
        .kind = .charge,
        .ts = 1,
        .session_id = "s",
        .gateway = "http://g/ssp",
        .skill_id = "ssk",
        .run_id = "run_1",
        .seq = 3,
        .step_kind = "final",
        .cost_micros = 24400,
        .cumulative_cost_micros = 24400,
        .currency = "USD",
        .digest = "sha256:ab",
    });
    defer a.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"kind\":\"charge\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"cost_micros\":24400") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"tool_calls\":[],\"results\":[],\"results_digest\":\"\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, line, "}\n"));
}

test "step and results records name the calls and digest what was sent (§6.6)" {
    const a = std.testing.allocator;
    const step = try render(a, .{
        .kind = .step,
        .ts = 1,
        .session_id = "s",
        .gateway = "http://g/ssp",
        .skill_id = "ssk",
        .run_id = "run_1",
        .seq = 1,
        .step_kind = "tool_calls",
        .calls = 2,
        .tool_calls = &.{ .{ .id = "c1", .name = "Read" }, .{ .id = "c2", .name = "Bash" } },
    });
    defer a.free(step);
    try std.testing.expect(std.mem.indexOf(u8, step, "\"tool_calls\":[{\"id\":\"c1\",\"name\":\"Read\"},{\"id\":\"c2\",\"name\":\"Bash\"}]") != null);
    const results = try render(a, .{
        .kind = .results,
        .ts = 2,
        .session_id = "s",
        .gateway = "http://g/ssp",
        .skill_id = "ssk",
        .run_id = "run_1",
        .seq = 1,
        .results = &.{
            .{ .tool_use_id = "c1", .sha256 = "sha256:aa", .bytes = 12, .redactions = &.{"erp-main"} },
            .{ .tool_use_id = "c2", .sha256 = "sha256:bb", .bytes = 0, .is_error = true, .refusal = "policy_violation" },
        },
    });
    defer a.free(results);
    try std.testing.expect(std.mem.indexOf(u8, results, "\"kind\":\"results\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, results, "{\"tool_use_id\":\"c1\",\"sha256\":\"sha256:aa\",\"bytes\":12,\"is_error\":false,\"truncated\":false,\"redactions\":[\"erp-main\"]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, results, "{\"tool_use_id\":\"c2\",\"sha256\":\"sha256:bb\",\"bytes\":0,\"is_error\":true,\"truncated\":false,\"refusal\":\"policy_violation\",\"redactions\":[]}") != null);
}
