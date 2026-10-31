//! Structured detail about the model request that ended a Run (issue #408).
//!
//! `StopReason.api_error` says a Run failed on the model; a host also needs to
//! know why, to tell "add funds" from "sign in again" from "retry later". This
//! module carries that fact from the provider clients to whoever started the
//! Run, without interpreting it: an upstream code such as `insufficient_balance`
//! passes through as bytes, and nothing here knows what it means for a business.
//!
//! **Ownership and attribution.** `agent_loop.run` owns one `Capture` on its
//! stack and publishes it through a thread-local `Scope` for the provider calls
//! it makes, all of which run on its own thread (the idle monitor only shuts a
//! socket down; the reader on this thread reports the stall). A concurrent Run
//! on another thread has another Capture, a nested Run on this thread shadows
//! this one and restores it on exit, and a write outside any Run is a no-op.
//! `last_error.zig` remains the TUI's process-wide "latest failure" text; this
//! module has no process-wide state.
//!
//! **Staleness.** A response the provider accepted clears the recorded failure,
//! so a retry that succeeds leaves nothing behind. `agent_loop.run` reads the
//! Capture only when the Run's stop reason is a model failure.
//!
//! **Text is hostile.** Every string came from the server. Fields are stored in
//! fixed buffers with control bytes flattened, known secret shapes masked, and
//! the credential the request carried masked. The Capture keeps only that
//! credential's length and hash, never its bytes: a Session's update must leave
//! no copy of the old key behind (doc/AGENTCORE_BINARY_ABI.md, "Credential
//! updates"). Nothing here allocates from the heap, because failure paths must
//! not fail for memory.

const std = @import("std");
const error_class = @import("error_class.zig");
const last_error = @import("last_error.zig");
const http_status = @import("http_status.zig");
const util_json = @import("../util/json.zig");

/// What kind of failure this was, from transport facts (HTTP status, stream
/// shape) and the provider's technical error types. It never encodes billing:
/// `payment_required` is HTTP 402, whatever the provider means by it.
pub const Category = enum {
    authentication,
    permission,
    payment_required,
    not_found,
    invalid_request,
    context_window,
    rate_limited,
    overloaded,
    server_error,
    timeout,
    connection,
    stream_interrupted,
    output_limit,
    unknown,
};

/// Whether sending the same request again can be expected to help. `unknown`
/// is the honest answer when an upstream code this module does not recognize
/// qualifies an otherwise retryable status: a 429 can be a burst limit or an
/// exhausted quota, and only the provider's code tells them apart.
pub const Retry = enum { retryable, not_retryable, unknown };

pub const CODE_CAP = 128;
pub const TYPE_CAP = 128;
pub const REQUEST_ID_CAP = 128;
pub const MESSAGE_CAP = 1024;

const REDACTED = "[REDACTED]";

fn Text(comptime cap: usize) type {
    return struct {
        const Self = @This();
        buf: [cap]u8 = undefined,
        len: usize = 0,
        truncated: bool = false,

        fn set(self: *Self, raw: []const u8, secret: ?SecretPrint) void {
            // Flatten first: a control byte inside a key must not hide it from
            // the masking below. The scratch bound is the longest input any
            // caller can have read (client error bodies are at most 4 KiB).
            var clean_buf: [8 * 1024]u8 = undefined;
            const clean = clean_buf[0..last_error.copySanitized(&clean_buf, raw)];
            const written = redactInto(&self.buf, clean, secret);
            self.len = written.len;
            self.truncated = written.truncated or clean.len < raw.len;
        }

        fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        fn optional(self: *const Self) ?[]const u8 {
            return if (self.len == 0) null else self.slice();
        }
    };
}

/// One failure, by value. Hosts read it through `view`, whose slices borrow
/// this struct.
pub const Detail = struct {
    category: Category = .unknown,
    retry: Retry = .unknown,
    http_status: ?u16 = null,
    retry_after_ms: ?u64 = null,
    attempts: u32 = 1,
    code: Text(CODE_CAP) = .{},
    type: Text(TYPE_CAP) = .{},
    request_id: Text(REQUEST_ID_CAP) = .{},
    message: Text(MESSAGE_CAP) = .{},

    /// JSON shape of one failure on every host surface. Never empty `message`.
    pub const View = struct {
        category: Category,
        code: ?[]const u8,
        type: ?[]const u8,
        message: []const u8,
        http_status: ?u16,
        request_id: ?[]const u8,
        retry: Retry,
        retry_after_ms: ?u64,
        attempts: u32,
        truncated: bool,
    };

    pub fn view(self: *const Detail) View {
        return .{
            .category = self.category,
            .code = self.code.optional(),
            .type = self.type.optional(),
            .message = self.message.slice(),
            .http_status = self.http_status,
            .request_id = self.request_id.optional(),
            .retry = self.retry,
            .retry_after_ms = self.retry_after_ms,
            .attempts = self.attempts,
            .truncated = self.code.truncated or self.type.truncated or
                self.request_id.truncated or self.message.truncated,
        };
    }

    /// For a model failure no provider call described (the request never left,
    /// or a host boundary refused it). `unknown` says so instead of guessing.
    pub fn unknownFailure(out: *Detail) void {
        out.* = .{};
        out.message.set("The model request failed without further detail.", null);
    }

    /// `StopReason.max_tokens_exhausted`: a complete response, repeatedly cut at
    /// the output limit. No request failed, so no status or code applies.
    pub fn outputLimit(out: *Detail) void {
        out.* = .{ .category = .output_limit, .retry = .not_retryable };
        out.message.set("The model kept reaching its output token limit without completing an answer.", null);
    }
};

const ResponseHead = struct {
    status_code: ?u16 = null,
    retry_after_ms: ?u64 = null,
    request_id: Text(REQUEST_ID_CAP) = .{},
};

/// The state one Run's provider calls write to. Owned by `agent_loop.run`.
pub const Capture = struct {
    has_failure: bool = false,
    failure: Detail = .{},
    head: ResponseHead = .{},
    attempts: u32 = 0,
    /// The credential of the latest request, to recognize it in what comes back.
    credential: ?SecretPrint = null,

    /// The Run's failure into `out`; `unknownFailure` when none was recorded.
    pub fn finish(self: *const Capture, out: *Detail) void {
        if (self.has_failure) out.* = self.failure else Detail.unknownFailure(out);
        out.attempts = @max(self.attempts, 1);
    }

    fn fresh(self: *Capture) *Detail {
        self.has_failure = true;
        self.failure = .{};
        return &self.failure;
    }

    /// A failure answered after the response head: it belongs to that response.
    fn withHead(self: *Capture, detail: *Detail) void {
        detail.http_status = self.head.status_code;
        detail.request_id = self.head.request_id;
    }
};

threadlocal var active: ?*Capture = null;

/// Publishes a Capture for this thread until `exit`, restoring what it shadowed.
pub const Scope = struct {
    previous: ?*Capture,

    pub fn enter(capture: *Capture) Scope {
        const previous = active;
        active = capture;
        return .{ .previous = previous };
    }

    pub fn exit(self: Scope) void {
        active = self.previous;
    }
};

/// One logical model request starts; its physical attempts count from here.
pub fn beginRequest() void {
    const capture = active orelse return;
    capture.attempts = 0;
}

/// One physical attempt of the current request starts.
pub fn noteAttempt() void {
    const capture = active orelse return;
    capture.attempts +|= 1;
}

/// The provider answered a response head. Remembered for whatever fails next
/// on this response; the status is not yet a failure. `credential` is the
/// secret the request carried.
pub fn noteResponseHead(status: u16, request_id: ?[]const u8, retry_after_ms: ?u64, credential: []const u8) void {
    const capture = active orelse return;
    capture.head = .{ .status_code = status, .retry_after_ms = retry_after_ms };
    capture.credential = SecretPrint.of(credential);
    if (request_id) |id| capture.head.request_id.set(id, capture.credential);
}

/// The provider accepted the request: earlier attempts' failures are over.
pub fn clearFailure() void {
    const capture = active orelse return;
    capture.has_failure = false;
}

/// A non-2xx answer whose head `noteResponseHead` has seen.
pub fn noteHttpFailure(status: u16, body: []const u8) void {
    const capture = active orelse return;
    const secret = capture.credential;
    var scratch: [PARSE_SCRATCH_BYTES]u8 = undefined;
    const parsed = parseErrorPayload(&scratch, body);
    const detail = capture.fresh();
    capture.withHead(detail);
    detail.http_status = status;
    detail.retry_after_ms = capture.head.retry_after_ms;
    fillUpstream(detail, parsed, secret);
    if (detail.request_id.len == 0) if (parsed.request_id) |id| detail.request_id.set(id, secret);
    const window = error_class.isContextWindowExceeded(body);
    detail.category = if (window) .context_window else categoryForStatus(status);
    detail.retry = if (window) .not_retryable else retryForStatus(status, detail.retry_after_ms != null, parsed);
    if (detail.message.len == 0) {
        var buf: [96]u8 = undefined;
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        // A bare-text body is often the only explanation. Markup is a proxy's
        // error page, and JSON without a message is noise to a person.
        if (trimmed.len > 0 and parsed.payload == .none and trimmed[0] != '<' and trimmed[0] != '{' and trimmed[0] != '[') {
            detail.message.set(trimmed, secret);
        } else {
            detail.message.set(std.fmt.bufPrint(&buf, "HTTP {d} response without a readable message.", .{status}) catch "HTTP failure.", null);
        }
    }
}

/// A 3xx to a request that carries a key is an answer, not a hop. The fix is to
/// use that URL as the endpoint, so the message says where it points.
pub fn noteRedirect(status: u16, location: []const u8) void {
    const capture = active orelse return;
    const detail = capture.fresh();
    capture.withHead(detail);
    detail.http_status = status;
    detail.category = .invalid_request;
    detail.retry = .not_retryable;
    // A Location at the clients' bound may have been cut, and a credential cut
    // in two no longer matches its print. Naming no URL is the safe answer.
    var buf: [512]u8 = undefined;
    const message = if (location.len >= http_status.REDIRECT_LOCATION_BYTES)
        std.fmt.bufPrint(&buf, "The endpoint redirected (HTTP {d}) to a URL too long to report; requests that carry a key do not follow redirects, so use that URL as the endpoint.", .{status})
    else
        std.fmt.bufPrint(&buf, "The endpoint redirected (HTTP {d}) to {s}; requests that carry a key do not follow redirects, so use that URL as the endpoint.", .{ status, location });
    detail.message.set(message catch "The endpoint redirected; use the target URL as the endpoint.", capture.credential);
}

/// A failure declared inside an accepted stream: an Anthropic error frame, a
/// top-level OpenAI/Gemini `error` object, or a Responses `response.failed`.
pub fn noteStreamError(payload: []const u8) void {
    const capture = active orelse return;
    var scratch: [PARSE_SCRATCH_BYTES]u8 = undefined;
    const parsed = parseErrorPayload(&scratch, payload);
    const detail = capture.fresh();
    capture.withHead(detail);
    fillUpstream(detail, parsed, capture.credential);
    if (detail.request_id.len == 0) if (parsed.request_id) |id| detail.request_id.set(id, capture.credential);
    if (error_class.isContextWindowExceeded(payload)) {
        detail.category = .context_window;
        detail.retry = .not_retryable;
    } else {
        const known = technicalCategory(parsed.type_name) orelse technicalCategory(parsed.code);
        detail.category = if (known) |value| value else .unknown;
        detail.retry = if (known != null and upstreamIsTechnical(parsed)) retryForCategory(detail.category) else .unknown;
    }
    if (detail.message.len == 0) detail.message.set("The provider reported an error inside the response stream.", null);
}

/// A failure before any response head: connecting, sending or waiting for one.
pub fn noteTransportFailure(category: Category, retry: Retry, message: []const u8) void {
    const capture = active orelse return;
    const detail = capture.fresh();
    detail.category = category;
    detail.retry = retry;
    detail.message.set(message, capture.credential);
}

/// A failure after the response head that is not the server's own statement:
/// a stalled, dead or incomplete stream.
pub fn noteStreamFailure(category: Category, retry: Retry, message: []const u8) void {
    const capture = active orelse return;
    const detail = capture.fresh();
    capture.withHead(detail);
    detail.category = category;
    detail.retry = retry;
    detail.message.set(message, capture.credential);
}

/// `agent_loop`'s net under the clients: a failed send nobody described.
pub fn noteRequestError(err: anyerror) void {
    const capture = active orelse return;
    if (capture.has_failure) return;
    const detail = capture.fresh();
    const classified = classifyError(err);
    detail.category = classified.category;
    detail.retry = classified.retry;
    var buf: [128]u8 = undefined;
    detail.message.set(std.fmt.bufPrint(&buf, "The model request failed: {s}.", .{@errorName(err)}) catch "The model request failed.", null);
}

/// `agent_loop`'s net under the stream readers: a failed read nobody described.
/// `RequestFailed` is the name the three clients reserve for a mid-stream
/// disconnect; any other name is a local decode failure that a resend repeats.
pub fn noteStreamReadError(err: anyerror) void {
    const capture = active orelse return;
    if (capture.has_failure) return;
    var buf: [128]u8 = undefined;
    if (err == error.RequestFailed) {
        noteStreamFailure(.stream_interrupted, .retryable, "The connection dropped while the response was streaming.");
    } else {
        noteStreamFailure(.unknown, .unknown, std.fmt.bufPrint(&buf, "The response stream could not be read: {s}.", .{@errorName(err)}) catch "The response stream could not be read.");
    }
}

const ErrorClass = struct { category: Category, retry: Retry };

fn classifyError(err: anyerror) ErrorClass {
    return switch (err) {
        error.Unauthorized, error.TokenExpired, error.InvalidCredential => .{ .category = .authentication, .retry = .not_retryable },
        error.RateLimited => .{ .category = .rate_limited, .retry = .retryable },
        error.ServiceUnavailable => .{ .category = .overloaded, .retry = .retryable },
        error.ServerError, error.BadGateway => .{ .category = .server_error, .retry = .retryable },
        error.ContextWindowExceeded => .{ .category = .context_window, .retry = .not_retryable },
        error.InvalidUrl => .{ .category = .invalid_request, .retry = .not_retryable },
        error.TransientNetwork,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.ConnectFailed,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.UnknownHostName,
        error.NameServerFailure,
        error.TemporaryNameServerFailure,
        error.WriteFailed,
        error.ReadFailed,
        error.BrokenPipe,
        => .{ .category = .connection, .retry = .retryable },
        error.TlsInitializationFailed => .{ .category = .connection, .retry = .unknown },
        else => .{ .category = .unknown, .retry = .unknown },
    };
}

fn categoryForStatus(status: u16) Category {
    return switch (status) {
        401 => .authentication,
        402 => .payment_required,
        403 => .permission,
        404 => .not_found,
        408, 504 => .timeout,
        429 => .rate_limited,
        503, 529 => .overloaded,
        300...399 => .invalid_request,
        400, 405...407, 409...428, 430...499 => .invalid_request,
        500...502, 505...528, 530...599 => .server_error,
        else => .unknown,
    };
}

fn retryForStatus(status: u16, has_retry_after: bool, parsed: Parsed) Retry {
    // A server that names a time to come back has answered the question.
    if (has_retry_after and status >= 400) return .retryable;
    return switch (status) {
        408, 429, 500...599 => if (upstreamIsTechnical(parsed)) .retryable else .unknown,
        409, 425 => .unknown,
        300...399, 400...407, 410...424, 426...428, 430...499 => .not_retryable,
        else => .unknown,
    };
}

fn retryForCategory(category: Category) Retry {
    return switch (category) {
        .rate_limited, .overloaded, .server_error, .timeout, .connection, .stream_interrupted => .retryable,
        .authentication, .permission, .payment_required, .not_found, .invalid_request, .context_window, .output_limit => .not_retryable,
        .unknown => .unknown,
    };
}

/// Absent, or an error type that names a technical condition rather than a
/// provider's account state. Everything else stays opaque, and opaque makes
/// retry guidance `unknown`: this list is the whole of what is recognized.
fn upstreamIsTechnical(parsed: Parsed) bool {
    return (parsed.code == null or technicalCategory(parsed.code) != null) and
        (parsed.type_name == null or technicalCategory(parsed.type_name) != null);
}

fn technicalCategory(name: ?[]const u8) ?Category {
    const value = name orelse return null;
    const table = [_]struct { []const u8, Category }{
        .{ "overloaded_error", .overloaded },
        .{ "overloaded", .overloaded },
        .{ "service_unavailable", .overloaded },
        .{ "UNAVAILABLE", .overloaded },
        .{ "rate_limit_error", .rate_limited },
        .{ "rate_limit_exceeded", .rate_limited },
        .{ "authentication_error", .authentication },
        .{ "UNAUTHENTICATED", .authentication },
        .{ "permission_error", .permission },
        .{ "PERMISSION_DENIED", .permission },
        .{ "invalid_request_error", .invalid_request },
        .{ "INVALID_ARGUMENT", .invalid_request },
        .{ "not_found_error", .not_found },
        .{ "NOT_FOUND", .not_found },
        .{ "api_error", .server_error },
        .{ "server_error", .server_error },
        .{ "internal_error", .server_error },
        .{ "internal_server_error", .server_error },
        .{ "INTERNAL", .server_error },
        .{ "timeout_error", .timeout },
        .{ "request_timeout", .timeout },
        .{ "DEADLINE_EXCEEDED", .timeout },
    };
    for (table) |entry| if (std.mem.eql(u8, entry[0], value)) return entry[1];
    return null;
}

fn fillUpstream(detail: *Detail, parsed: Parsed, secret: ?SecretPrint) void {
    if (parsed.code orelse parsed.type_name) |value| detail.code.set(value, secret);
    if (parsed.type_name) |value| detail.type.set(value, secret);
    if (parsed.message) |value| detail.message.set(value, secret);
}

// --- error payload parsing ---------------------------------------------------

/// Parsing runs on the failure path of a thread that may be short of heap, so
/// it uses a stack arena. A body larger than this falls back to field scanning.
const PARSE_SCRATCH_BYTES = 32 * 1024;

const Parsed = struct {
    code: ?[]const u8 = null,
    type_name: ?[]const u8 = null,
    message: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    payload: enum { none, json, partial_json } = .none,
};

/// The error object out of every dialect seen in practice:
/// `{"error":{"type","code","message"}}` (Anthropic, OpenAI, compatibles),
/// `[{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message"}}]` (Gemini),
/// `{"response":{"error":{...}}}` (Responses `response.failed`),
/// `{"type":"error","code","message"}` (Responses `error`),
/// `{"code":1113,"msg":"..."}` and `{"error":"...","message":"..."}` (gateways).
/// The slices borrow `scratch` or `body`.
fn parseErrorPayload(scratch: []u8, body: []const u8) Parsed {
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    const a = fba.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return scanPartialJson(body);
    var object = objectOf(root) orelse return .{};
    var out: Parsed = .{ .payload = .json };
    if (object.get("response")) |response| if (objectOf(response)) |inner| {
        if (inner.get("error") != null) object = inner;
    };
    out.request_id = stringField(object, "request_id") orelse stringField(object, "requestId");

    var fields = object;
    var nested = false;
    if (object.get("error")) |value| switch (value) {
        .object => |inner| {
            fields = inner;
            nested = true;
        },
        .string => |text| {
            // `{"error":"insufficient_balance"}` is a code; `{"error":"Key is
            // not valid"}` is a sentence. An identifier has no spaces.
            if (std.mem.indexOfScalar(u8, text, ' ') == null) out.code = text else out.message = text;
        },
        else => {},
    };
    if (out.request_id == null) out.request_id = stringField(fields, "request_id") orelse stringField(fields, "requestId");

    out.type_name = stringField(fields, "type");
    // The event discriminator of a flat frame, not an error type.
    if (out.type_name) |name| if (std.mem.eql(u8, name, "error")) {
        out.type_name = null;
    };
    // A flat envelope's `status` is usually "error" or "fail"; inside an error
    // object it is Gemini's canonical code.
    if (out.code == null) out.code = stringField(fields, "code") orelse
        (if (nested) stringField(fields, "status") else null) orelse
        stringField(fields, "error_code") orelse
        stringField(fields, "errorCode") orelse
        numberField(a, fields, "code") orelse
        numberField(a, fields, "error_code");
    if (out.message == null) out.message = stringField(fields, "message") orelse
        stringField(fields, "msg") orelse
        stringField(fields, "error_description") orelse
        stringField(fields, "detail");
    return out;
}

/// Client error bodies are read with a bound, so a long JSON body arrives cut
/// and does not parse; its leading fields are still the useful ones.
fn scanPartialJson(body: []const u8) Parsed {
    const trimmed = std.mem.trimStart(u8, body, " \t\r\n");
    if (trimmed.len == 0 or (trimmed[0] != '{' and trimmed[0] != '[')) return .{};
    return .{
        .code = util_json.extractStringField(trimmed, "code"),
        .type_name = util_json.extractStringField(trimmed, "type"),
        .message = util_json.extractStringField(trimmed, "message"),
        .request_id = util_json.extractStringField(trimmed, "request_id"),
        .payload = .partial_json,
    };
}

fn objectOf(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        .array => |array| if (array.items.len > 0) objectOf(array.items[0]) else null,
        else => null,
    };
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| if (text.len == 0) null else text,
        else => null,
    };
}

fn numberField(a: std.mem.Allocator, object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |number| std.fmt.allocPrint(a, "{d}", .{number}) catch null,
        else => null,
    };
}

// --- redaction ---------------------------------------------------------------

const Written = struct { len: usize, truncated: bool };

/// A credential's length and hash: enough to recognize it, not to recover it.
const SecretPrint = struct {
    len: usize,
    hash: u64,

    /// Null below the length where a match could be an ordinary word.
    fn of(secret: []const u8) ?SecretPrint {
        if (secret.len < SECRET_MIN_BYTES) return null;
        return .{ .len = secret.len, .hash = std.hash.Wyhash.hash(0, secret) };
    }

    fn matches(self: SecretPrint, candidate: []const u8) bool {
        return candidate.len >= self.len and std.hash.Wyhash.hash(0, candidate[0..self.len]) == self.hash;
    }
};

fn isTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '*' or byte == '~' or byte == '+' or byte == '/' or byte == '=';
}

/// Keys and tokens carry recognizable prefixes; 8 bytes keeps an English word
/// that happens to start with one out of the match.
const SECRET_PREFIXES = [_][]const u8{ "sk-", "sk_", "rk-", "pk-", "ak-", "AIza", "ya29.", "eyJ", "ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-", "AKIA", "ASIA" };
const SECRET_MIN_BYTES = 8;

/// A word followed by `:` or `=` whose value is a secret, whatever it looks like.
const SECRET_KEYS = [_][]const u8{ "x-api-key", "api_key", "api-key", "apikey", "access_token", "refresh_token", "auth_token", "id_token", "token", "secret", "client_secret", "password", "passwd", "authorization", "key", "x-goog-api-key" };

/// Copies `src` to `out`, masking the credential and secret shapes, and stops
/// short of a split code point. Masking runs before the cap applies, so the cap
/// cannot cut a secret into something the patterns no longer see.
fn redactInto(out: []u8, src: []const u8, secret: ?SecretPrint) Written {
    var written: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        const piece = nextPiece(src, i, secret);
        i += piece.consumed;
        for ([_][]const u8{ piece.keep, piece.mask }) |part| {
            if (part.len == 0) continue;
            if (written + part.len > out.len) {
                return .{ .len = utf8Prefix(out, written, part), .truncated = true };
            }
            @memcpy(out[written..][0..part.len], part);
            written += part.len;
        }
    }
    return .{ .len = written, .truncated = false };
}

const Piece = struct { keep: []const u8, mask: []const u8, consumed: usize };

fn nextPiece(src: []const u8, i: usize, secret: ?SecretPrint) Piece {
    if (secret) |print| if (print.matches(src[i..]))
        return .{ .keep = "", .mask = REDACTED, .consumed = print.len };

    const at_boundary = i == 0 or !isTokenByte(src[i - 1]);
    if (at_boundary) {
        for (SECRET_PREFIXES) |prefix| {
            if (!std.mem.startsWith(u8, src[i..], prefix)) continue;
            const token = tokenEnd(src, i) - i;
            if (token >= SECRET_MIN_BYTES) return .{ .keep = "", .mask = REDACTED, .consumed = token };
        }
        if (startsWithIgnoreCase(src[i..], "bearer ")) {
            const value_at = skipSpaces(src, i + "bearer ".len);
            const end = tokenEnd(src, value_at);
            if (end > value_at) return .{ .keep = src[i .. i + "bearer ".len], .mask = REDACTED, .consumed = end - i };
        }
        for (SECRET_KEYS) |key| {
            if (!startsWithIgnoreCase(src[i..], key)) continue;
            const value_at = secretValueAt(src, i + key.len) orelse continue;
            const end = valueEnd(src, value_at);
            if (end == value_at) continue;
            // `authorization: Bearer x`: the scheme is not the secret; the
            // bearer rule above masks what follows when the scan reaches it.
            if (isAuthScheme(src[value_at..end])) continue;
            return .{ .keep = src[i..value_at], .mask = REDACTED, .consumed = end - i };
        }
    }
    return .{ .keep = src[i .. i + 1], .mask = "", .consumed = 1 };
}

fn isAuthScheme(word: []const u8) bool {
    return std.ascii.eqlIgnoreCase(word, "bearer") or std.ascii.eqlIgnoreCase(word, "basic");
}

fn tokenEnd(src: []const u8, from: usize) usize {
    var end = from;
    while (end < src.len and isTokenByte(src[end])) : (end += 1) {}
    return end;
}

fn skipSpaces(src: []const u8, from: usize) usize {
    var at = from;
    while (at < src.len and src[at] == ' ') : (at += 1) {}
    return at;
}

/// Past `key`: an optional closing quote, spaces, then `:` or `=` and an
/// optional opening quote. Null when no separator follows, so the word alone
/// ("invalid token provided") is prose.
fn secretValueAt(src: []const u8, after_key: usize) ?usize {
    var at = after_key;
    if (at < src.len and (src[at] == '"' or src[at] == '\'')) at += 1;
    at = skipSpaces(src, at);
    if (at >= src.len or (src[at] != ':' and src[at] != '=')) return null;
    at = skipSpaces(src, at + 1);
    if (at < src.len and (src[at] == '"' or src[at] == '\'')) at += 1;
    return at;
}

fn valueEnd(src: []const u8, from: usize) usize {
    var end = from;
    while (end < src.len) : (end += 1) {
        switch (src[end]) {
            ' ', '"', '\'', ',', '&', '}', ']', ')', ';' => break,
            else => {},
        }
    }
    return end;
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    return haystack.len >= prefix.len and std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

/// `part` does not fit: fill what does, then give back a code point the cap
/// split (the scan copies byte by byte, so it can end inside one anywhere).
fn utf8Prefix(out: []u8, written: usize, part: []const u8) usize {
    const room = @min(out.len - written, part.len);
    @memcpy(out[written..][0..room], part[0..room]);
    var end = written + room;
    var back: usize = 0;
    while (back < 4 and back < end) : (back += 1) {
        const byte = out[end - 1 - back];
        if ((byte & 0xC0) == 0x80) continue;
        const need = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        if (need > back + 1) end -= back + 1;
        break;
    }
    return end;
}

// --- unit tests --------------------------------------------------------------

const testing = std.testing;

fn finishFor(capture: *const Capture) Detail {
    var detail: Detail = undefined;
    capture.finish(&detail);
    return detail;
}

test "nothing recorded is unknown and says so" {
    var capture = Capture{};
    const detail = finishFor(&capture);
    const view = detail.view();
    try testing.expectEqual(Category.unknown, view.category);
    try testing.expectEqual(Retry.unknown, view.retry);
    try testing.expect(view.message.len > 0);
    try testing.expect(view.code == null and view.http_status == null);
}

test "writes outside a Scope are no-ops and a nested Scope restores the outer one" {
    noteHttpFailure(500, "{}");
    var outer = Capture{};
    const outer_scope = Scope.enter(&outer);
    defer outer_scope.exit();
    noteTransportFailure(.connection, .retryable, "outer");
    {
        var inner = Capture{};
        const inner_scope = Scope.enter(&inner);
        defer inner_scope.exit();
        noteTransportFailure(.timeout, .retryable, "inner");
        try testing.expectEqualStrings("inner", inner.failure.message.slice());
    }
    try testing.expectEqualStrings("outer", outer.failure.message.slice());
    clearFailure();
    try testing.expect(!outer.has_failure);
}

fn httpDetail(status: u16, retry_after: ?u64, body: []const u8) Detail {
    var capture = Capture{};
    const scope = Scope.enter(&capture);
    defer scope.exit();
    noteResponseHead(status, "req-head", retry_after, "");
    noteHttpFailure(status, body);
    return finishFor(&capture);
}

test "a business code on a retryable status leaves retry guidance unknown" {
    const quota = httpDetail(429, null, "{\"error\":{\"type\":\"insufficient_quota\",\"code\":\"insufficient_quota\",\"message\":\"You exceeded your quota\"}}");
    try testing.expectEqual(Category.rate_limited, quota.category);
    try testing.expectEqual(Retry.unknown, quota.retry);
    try testing.expectEqualStrings("insufficient_quota", quota.code.slice());
    try testing.expectEqualStrings("You exceeded your quota", quota.message.slice());
    try testing.expectEqualStrings("req-head", quota.request_id.slice());

    const burst = httpDetail(429, null, "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}");
    try testing.expectEqual(Retry.retryable, burst.retry);
    const told = httpDetail(429, 1500, "{\"error\":{\"code\":\"whatever\",\"message\":\"later\"}}");
    try testing.expectEqual(Retry.retryable, told.retry);
    try testing.expectEqual(@as(?u64, 1500), told.retry_after_ms);
}

test "every dialect's error shape yields its code and message" {
    const cases = [_]struct { body: []const u8, code: ?[]const u8, message: []const u8 }{
        .{ .body = "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"busy\"},\"request_id\":\"r\"}", .code = "overloaded_error", .message = "busy" },
        .{ .body = "[{\"error\":{\"code\":429,\"message\":\"quota\",\"status\":\"RESOURCE_EXHAUSTED\"}}]", .code = "RESOURCE_EXHAUSTED", .message = "quota" },
        .{ .body = "{\"code\":1113,\"msg\":\"余额不足\"}", .code = "1113", .message = "余额不足" },
        .{ .body = "{\"error\":\"insufficient_balance\",\"message\":\"Top up\"}", .code = "insufficient_balance", .message = "Top up" },
        .{ .body = "{\"error\":\"Key is not valid\"}", .code = null, .message = "Key is not valid" },
        .{ .body = "{\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"server_error\",\"message\":\"boom\"}}}", .code = "server_error", .message = "boom" },
        .{ .body = "{\"type\":\"error\",\"code\":\"weird\",\"message\":\"flat\"}", .code = "weird", .message = "flat" },
    };
    for (cases) |case| {
        const detail = httpDetail(400, null, case.body);
        if (case.code) |code| {
            try testing.expectEqualStrings(code, detail.code.slice());
        } else {
            try testing.expectEqual(@as(usize, 0), detail.code.len);
        }
        try testing.expectEqualStrings(case.message, detail.message.slice());
    }
}

test "a body cut by the read bound still yields its leading fields" {
    const detail = httpDetail(400, null, "{\"error\":{\"code\":\"cut_code\",\"message\":\"cut message\",\"extra\":\"aaaaa");
    try testing.expectEqualStrings("cut_code", detail.code.slice());
    try testing.expectEqualStrings("cut message", detail.message.slice());
}

test "markup and empty bodies get a status message, plain text is kept" {
    const html = httpDetail(502, null, "<html><body>Bad gateway</body></html>");
    try testing.expectEqualStrings("HTTP 502 response without a readable message.", html.message.slice());
    try testing.expectEqual(Retry.retryable, html.retry);
    const empty = httpDetail(500, null, "");
    try testing.expectEqualStrings("HTTP 500 response without a readable message.", empty.message.slice());
    const text = httpDetail(500, null, "upstream connect error");
    try testing.expectEqualStrings("upstream connect error", text.message.slice());
}

test "secrets are masked in every field, the credential exactly" {
    var capture = Capture{};
    const scope = Scope.enter(&capture);
    defer scope.exit();
    noteResponseHead(401, null, null, "plainsecretvalue");
    noteHttpFailure(401, "{\"error\":{\"code\":\"bad-key\",\"message\":\"Incorrect key plainsecretvalue provided: sk-abc123***xyz, Authorization: Bearer tok_123456, api_key=abc123&x=1, \\\"password\\\": \\\"hunter2\\\" for token expired\"}}");
    const message = capture.failure.message.slice();
    for ([_][]const u8{ "plainsecretvalue", "sk-abc123", "tok_123456", "abc123&", "hunter2" }) |leak| {
        if (std.mem.indexOf(u8, message, leak) != null) {
            std.debug.print("leaked {s} in {s}\n", .{ leak, message });
            return error.SecretLeaked;
        }
    }
    try testing.expect(std.mem.indexOf(u8, message, "token expired") != null);
    try testing.expect(std.mem.indexOf(u8, message, "Authorization: Bearer [REDACTED]") != null);
}

test "the credential is masked in a stream frame too, from its print alone" {
    var capture = Capture{};
    const scope = Scope.enter(&capture);
    defer scope.exit();
    noteResponseHead(200, null, null, "plainsecretvalue");
    noteStreamError("{\"type\":\"x\",\"message\":\"bad key plainsecretvalue here\"}");
    try testing.expectEqualStrings("bad key [REDACTED] here", capture.failure.message.slice());
}

test "the credential is masked in caller-supplied failure text and the request id" {
    var capture = Capture{};
    const scope = Scope.enter(&capture);
    defer scope.exit();
    noteResponseHead(200, "rid-plainsecretvalue", null, "plainsecretvalue");
    try testing.expectEqualStrings("rid-[REDACTED]", capture.head.request_id.slice());
    noteTransportFailure(.connection, .retryable, "dial http://h/plainsecretvalue/x failed");
    try testing.expectEqualStrings("dial http://h/[REDACTED]/x failed", capture.failure.message.slice());
    noteStreamFailure(.timeout, .retryable, "read http://h/plainsecretvalue/x failed");
    try testing.expectEqualStrings("read http://h/[REDACTED]/x failed", capture.failure.message.slice());
}

test "control bytes are flattened and fields are bounded without splitting UTF-8" {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, "{\"error\":{\"code\":\"");
    try body.appendNTimes(testing.allocator, 'c', CODE_CAP + 40);
    try body.appendSlice(testing.allocator, "\",\"message\":\"a\\u001b[31m");
    for (0..1000) |_| try body.appendSlice(testing.allocator, "错");
    try body.appendSlice(testing.allocator, "\"}}");
    const detail = httpDetail(400, null, body.items);
    const view = detail.view();
    try testing.expectEqual(@as(usize, CODE_CAP), view.code.?.len);
    try testing.expect(view.message.len <= MESSAGE_CAP);
    try testing.expect(std.unicode.utf8ValidateSlice(view.message));
    try testing.expect(std.mem.indexOfScalar(u8, view.message, 0x1b) == null);
    try testing.expect(view.truncated);
}

test "a stream frame is classified by its technical type; an unknown one stays opaque" {
    var capture = Capture{};
    const scope = Scope.enter(&capture);
    defer scope.exit();
    noteResponseHead(200, "req-stream", null, "");
    noteStreamError("{\"type\":\"overloaded_error\",\"message\":\"busy\"}");
    try testing.expectEqual(Category.overloaded, capture.failure.category);
    try testing.expectEqual(Retry.retryable, capture.failure.retry);
    try testing.expectEqual(@as(?u16, 200), capture.failure.http_status);
    try testing.expectEqualStrings("req-stream", capture.failure.request_id.slice());
    noteStreamError("{\"type\":\"billing_error\",\"message\":\"no credit\"}");
    try testing.expectEqual(Category.unknown, capture.failure.category);
    try testing.expectEqual(Retry.unknown, capture.failure.retry);
    try testing.expectEqualStrings("billing_error", capture.failure.code.slice());
}

test "the nets under the clients never overwrite a described failure" {
    var capture = Capture{};
    const scope = Scope.enter(&capture);
    defer scope.exit();
    noteRequestError(error.RateLimited);
    try testing.expectEqual(Category.rate_limited, capture.failure.category);
    noteRequestError(error.ConnectionRefused);
    try testing.expectEqual(Category.rate_limited, capture.failure.category);
    clearFailure();
    noteStreamReadError(error.RequestFailed);
    try testing.expectEqual(Category.stream_interrupted, capture.failure.category);
    clearFailure();
    noteStreamReadError(error.InvalidJson);
    try testing.expectEqual(Category.unknown, capture.failure.category);
    try testing.expect(std.mem.indexOf(u8, capture.failure.message.slice(), "InvalidJson") != null);
}

test "attempts count the current request only" {
    var capture = Capture{};
    const scope = Scope.enter(&capture);
    defer scope.exit();
    noteAttempt();
    noteAttempt();
    beginRequest();
    noteAttempt();
    noteTransportFailure(.connection, .retryable, "x");
    try testing.expectEqual(@as(u32, 1), finishFor(&capture).attempts);
}
