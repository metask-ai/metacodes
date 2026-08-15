const std = @import("std");

pub const protocol_version: u32 = 1;
pub const implementation: []const u8 = "tinykg-daemon";
pub const transport: []const u8 = "versioned_ndjson_stdio";
pub const queue_capacity: usize = 128;
/// Upper bound on writes acknowledged at one group-commit sync boundary.
pub const group_commit_max_requests: usize = 64;
pub const max_request_bytes: usize = 1024 * 1024;
pub const max_args: usize = 256;
pub const maintenance_interval_ms: u64 = 30000;
pub const control_command: []const u8 = "_control";
pub const expire_sessions_control: []const u8 = "expire-sessions";
pub const maintenance_step_control: []const u8 = "maintenance-step";

pub const CommitState = enum {
    none,
    committed,
    ambiguous,
};

pub const Request = struct {
    protocolVersion: u32,
    requestId: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    sessionId: ?[]const u8 = null,
    /// Optional digest of request content that is intentionally not present in
    /// argv (for example Web-uploaded Markdown bytes staged behind a stable
    /// source path). StoreActor includes it in the same-id replay fingerprint.
    contentDigest: ?[]const u8 = null,
    injectStore: bool = true,
    timeoutMs: u64 = 180_000,

    pub fn validate(self: Request) !void {
        if (self.protocolVersion != protocol_version) return error.ProtocolVersionMismatch;
        if (self.requestId.len == 0) return error.MissingRequestId;
        if (self.requestId.len > 128 or !identifierValid(self.requestId)) return error.InvalidRequestId;
        if (self.command.len == 0 or self.command.len > 128) return error.InvalidCommand;
        if (self.args.len > max_args) return error.TooManyArguments;
        if (self.timeoutMs == 0 or self.timeoutMs > 3_600_000) return error.InvalidTimeout;
        if (self.sessionId) |session_id| {
            if (session_id.len == 0 or session_id.len > 128 or !identifierValid(session_id)) {
                return error.InvalidSessionId;
            }
        }
        if (self.contentDigest) |digest| {
            if (!sha256DigestValid(digest)) return error.InvalidContentDigest;
        }
    }
};

pub const SessionReceipt = struct {
    sessionId: []const u8,
    generation: u64,
    expiresAtMs: u64,
};

pub const Response = struct {
    protocolVersion: u32 = protocol_version,
    implementation: []const u8 = implementation,
    requestId: []const u8,
    ok: bool,
    code: i32,
    stdout: []const u8,
    stderr: []const u8,
    generation: u64,
    commitState: CommitState,
    replayed: bool = false,
    session: ?SessionReceipt = null,
};

fn identifierValid(value: []const u8) bool {
    for (value) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', ':' => {},
        else => return false,
    };
    return true;
}

fn sha256DigestValid(value: []const u8) bool {
    if (value.len != "sha256:".len + 64 or !std.mem.startsWith(u8, value, "sha256:")) return false;
    for (value["sha256:".len..]) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

pub fn writeResponse(writer: *std.Io.Writer, response: Response) !void {
    try std.json.Stringify.value(response, .{}, writer);
    try writer.writeByte('\n');
}

pub fn writeProtocolError(
    writer: *std.Io.Writer,
    request_id: []const u8,
    generation: u64,
    err: anyerror,
) !void {
    var stderr_buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&stderr_buffer, "tinykgd: error: {s}\n", .{@errorName(err)}) catch "tinykgd: error: ProtocolFailure\n";
    try writeResponse(writer, .{
        .requestId = request_id,
        .ok = false,
        .code = 2,
        .stdout = "",
        .stderr = message,
        .generation = generation,
        .commitState = .none,
    });
}

test "daemon protocol requires request identity and emits bound NDJSON" {
    try std.testing.expectError(error.MissingRequestId, (Request{
        .protocolVersion = protocol_version,
        .requestId = "",
        .command = "stats",
    }).validate());

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try writeResponse(&output.writer, .{
        .requestId = "req-1",
        .ok = true,
        .code = 0,
        .stdout = "ok\n",
        .stderr = "",
        .generation = 4,
        .commitState = .committed,
    });
    const bytes = try output.toOwnedSlice();
    defer std.testing.allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("req-1", parsed.value.object.get("requestId").?.string);
    try std.testing.expectEqualStrings("committed", parsed.value.object.get("commitState").?.string);
}

test "daemon protocol validates optional content digest" {
    try (Request{
        .protocolVersion = protocol_version,
        .requestId = "content-1",
        .command = "import-md-doc",
        .contentDigest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }).validate();
    try std.testing.expectError(error.InvalidContentDigest, (Request{
        .protocolVersion = protocol_version,
        .requestId = "content-2",
        .command = "import-md-doc",
        .contentDigest = "sha256:not-a-digest",
    }).validate());
}
