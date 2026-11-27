//! Exporter configuration from the standard OpenTelemetry environment
//! variables (opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables
//! and .../protocol/exporter). Metacodes reads no tracing setting of its own:
//! an operator who already runs an OTLP collector sets the same variables they
//! set for every other instrumented process.
//!
//! | Variable | Effect |
//! |---|---|
//! | `OTEL_SDK_DISABLED=true` | No export. |
//! | `OTEL_TRACES_EXPORTER` | `otlp` exports, `none` does not. Unset: export when an endpoint is set. Other exporters are refused with a warning. |
//! | `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | The traces URL, used as is. |
//! | `OTEL_EXPORTER_OTLP_ENDPOINT` | Base URL; `/v1/traces` is appended. Default `http://localhost:4318` when `OTEL_TRACES_EXPORTER=otlp`. |
//! | `OTEL_EXPORTER_OTLP[_TRACES]_PROTOCOL` | `http/protobuf` (default) or `http/json`. `grpc` is refused. |
//! | `OTEL_EXPORTER_OTLP[_TRACES]_HEADERS` | `k=v,k2=v2`, values percent-decoded. |
//! | `OTEL_EXPORTER_OTLP[_TRACES]_TIMEOUT` | Per-export timeout in ms (default 10000). |
//! | `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES` | Resource attributes. |
//! | `OTEL_BSP_SCHEDULE_DELAY`, `OTEL_BSP_MAX_QUEUE_SIZE`, `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` | Batch processor. |
//! | `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true` | Export prompts, model output and tool arguments/results. Off by default. |
//!
//! The signal-specific variable wins over the general one. Parsing is a pure
//! function of a lookup, so tests do not touch the process environment.

const std = @import("std");
const otlp = @import("otlp.zig");
const span_mod = @import("span.zig");

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Exporter = struct {
    /// The full traces URL.
    endpoint: []const u8,
    protocol: otlp.Protocol = .http_protobuf,
    headers: []const Header = &.{},
    timeout_ms: u32 = DEFAULT_TIMEOUT_MS,
    schedule_delay_ms: u32 = DEFAULT_SCHEDULE_DELAY_MS,
    max_queue_size: u32 = DEFAULT_MAX_QUEUE_SIZE,
    max_export_batch_size: u32 = DEFAULT_MAX_EXPORT_BATCH_SIZE,
    capture_content: bool = false,
    /// `service.name` first, then `OTEL_RESOURCE_ATTRIBUTES` in order.
    resource: []const span_mod.Attribute,
};

pub const DEFAULT_TIMEOUT_MS: u32 = 10_000;
pub const DEFAULT_SCHEDULE_DELAY_MS: u32 = 5_000;
pub const DEFAULT_MAX_QUEUE_SIZE: u32 = 2048;
pub const DEFAULT_MAX_EXPORT_BATCH_SIZE: u32 = 512;
pub const DEFAULT_SERVICE_NAME = "metacodes";
pub const DEFAULT_ENDPOINT = "http://localhost:4318";
pub const TRACES_PATH = "/v1/traces";

/// Why nothing is exported. `.not_configured` is the silent default; every
/// other reason is something the operator asked for and is logged.
pub const Off = enum {
    not_configured,
    sdk_disabled,
    exporter_none,
    unsupported_exporter,
    unsupported_protocol,
    invalid_endpoint,
};

pub const Decision = union(enum) {
    off: Off,
    export_to: Exporter,
};

pub const Lookup = struct {
    ctx: *const anyopaque,
    getFn: *const fn (ctx: *const anyopaque, name: []const u8) ?[]const u8,

    fn get(self: Lookup, name: []const u8) ?[]const u8 {
        const v = self.getFn(self.ctx, name) orelse return null;
        const trimmed = std.mem.trim(u8, v, " \t\r\n");
        return if (trimmed.len == 0) null else trimmed;
    }

    fn signal(self: Lookup, traces_name: []const u8, general_name: []const u8) ?[]const u8 {
        return self.get(traces_name) orelse self.get(general_name);
    }

    /// A lookup over `KEY=VALUE` strings (`platform.paths.environment`).
    pub fn fromPairs(pairs: *const []const [:0]const u8) Lookup {
        return .{ .ctx = @ptrCast(pairs), .getFn = pairsGet };
    }

    fn pairsGet(ctx: *const anyopaque, name: []const u8) ?[]const u8 {
        const pairs: *const []const [:0]const u8 = @ptrCast(@alignCast(ctx));
        for (pairs.*) |pair| {
            if (pair.len > name.len and pair[name.len] == '=' and std.mem.eql(u8, pair[0..name.len], name))
                return pair[name.len + 1 ..];
        }
        return null;
    }
};

/// Every slice in the result is allocated from `arena`.
pub fn decide(arena: std.mem.Allocator, env: Lookup, service_version: []const u8) error{OutOfMemory}!Decision {
    if (env.get("OTEL_SDK_DISABLED")) |v| if (std.ascii.eqlIgnoreCase(v, "true")) return .{ .off = .sdk_disabled };

    const explicit_endpoint = env.get("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT") != null or
        env.get("OTEL_EXPORTER_OTLP_ENDPOINT") != null;
    if (env.get("OTEL_TRACES_EXPORTER")) |list| {
        var wants_otlp = false;
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t");
            if (std.ascii.eqlIgnoreCase(name, "otlp")) wants_otlp = true;
        }
        if (!wants_otlp) {
            return .{ .off = if (std.ascii.eqlIgnoreCase(list, "none")) .exporter_none else .unsupported_exporter };
        }
    } else if (!explicit_endpoint) return .{ .off = .not_configured };

    const protocol: otlp.Protocol = if (env.signal("OTEL_EXPORTER_OTLP_TRACES_PROTOCOL", "OTEL_EXPORTER_OTLP_PROTOCOL")) |p|
        if (std.mem.eql(u8, p, "http/protobuf"))
            .http_protobuf
        else if (std.mem.eql(u8, p, "http/json"))
            .http_json
        else
            return .{ .off = .unsupported_protocol }
    else
        .http_protobuf;

    const endpoint = if (env.get("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")) |url|
        try arena.dupe(u8, url)
    else
        try std.mem.concat(arena, u8, &.{
            std.mem.trimEnd(u8, env.get("OTEL_EXPORTER_OTLP_ENDPOINT") orelse DEFAULT_ENDPOINT, "/"),
            TRACES_PATH,
        });
    if (!validEndpoint(endpoint)) return .{ .off = .invalid_endpoint };

    var resource: std.ArrayList(span_mod.Attribute) = .empty;
    const service_name = env.get("OTEL_SERVICE_NAME");
    try resource.append(arena, span_mod.Attribute.str("service.name", try arena.dupe(u8, service_name orelse DEFAULT_SERVICE_NAME)));
    if (service_version.len > 0) try resource.append(arena, span_mod.Attribute.str("service.version", try arena.dupe(u8, service_version)));
    try resource.append(arena, span_mod.Attribute.str("telemetry.sdk.name", "metacodes"));
    try resource.append(arena, span_mod.Attribute.str("telemetry.sdk.language", "zig"));
    if (env.get("OTEL_RESOURCE_ATTRIBUTES")) |list| {
        const pairs = try parsePairs(arena, list);
        for (pairs) |p| {
            // OTEL_SERVICE_NAME wins; a resource-attribute service.name is used only without it.
            if (std.mem.eql(u8, p.name, "service.name")) {
                if (service_name == null) resource.items[0] = span_mod.Attribute.str("service.name", p.value);
                continue;
            }
            if (std.mem.eql(u8, p.name, "service.version") or std.mem.startsWith(u8, p.name, "telemetry.sdk.")) continue;
            try resource.append(arena, span_mod.Attribute.str(p.name, p.value));
        }
    }

    return .{ .export_to = .{
        .endpoint = endpoint,
        .protocol = protocol,
        .headers = if (env.signal("OTEL_EXPORTER_OTLP_TRACES_HEADERS", "OTEL_EXPORTER_OTLP_HEADERS")) |h| try parsePairs(arena, h) else &.{},
        .timeout_ms = positive(env.signal("OTEL_EXPORTER_OTLP_TRACES_TIMEOUT", "OTEL_EXPORTER_OTLP_TIMEOUT"), DEFAULT_TIMEOUT_MS),
        .schedule_delay_ms = positive(env.get("OTEL_BSP_SCHEDULE_DELAY"), DEFAULT_SCHEDULE_DELAY_MS),
        .max_queue_size = positive(env.get("OTEL_BSP_MAX_QUEUE_SIZE"), DEFAULT_MAX_QUEUE_SIZE),
        .max_export_batch_size = positive(env.get("OTEL_BSP_MAX_EXPORT_BATCH_SIZE"), DEFAULT_MAX_EXPORT_BATCH_SIZE),
        .capture_content = if (env.get("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT")) |v| std.ascii.eqlIgnoreCase(v, "true") else false,
        .resource = try resource.toOwnedSlice(arena),
    } };
}

fn positive(raw: ?[]const u8, default: u32) u32 {
    const v = std.fmt.parseInt(u32, raw orelse return default, 10) catch return default;
    return if (v == 0) default else v;
}

pub fn validEndpoint(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return false;
    return uri.host != null;
}

/// `k=v,k2=v2` (W3C baggage-like, as the spec defines for headers and
/// resource attributes). Keys and values are trimmed; values are
/// percent-decoded. Entries without `=` or with an empty key are skipped.
pub fn parsePairs(arena: std.mem.Allocator, list: []const u8) error{OutOfMemory}![]const Header {
    var out: std.ArrayList(Header) = .empty;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const eq = std.mem.indexOfScalar(u8, raw, '=') orelse continue;
        const key = std.mem.trim(u8, raw[0..eq], " \t");
        if (key.len == 0) continue;
        const value = std.mem.trim(u8, raw[eq + 1 ..], " \t");
        try out.append(arena, .{ .name = try arena.dupe(u8, key), .value = try percentDecode(arena, value) });
    }
    return out.toOwnedSlice(arena);
}

fn percentDecode(arena: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    var out = try arena.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                out[n] = b;
                i += 3;
                continue;
            } else |_| {}
        }
        out[n] = s[i];
        i += 1;
    }
    return out[0..n];
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

const MapEnv = struct {
    pairs: []const [2][]const u8,

    fn lookup(self: *const MapEnv) Lookup {
        return .{ .ctx = @ptrCast(self), .getFn = get };
    }
    fn get(ctx: *const anyopaque, name: []const u8) ?[]const u8 {
        const self: *const MapEnv = @ptrCast(@alignCast(ctx));
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
        return null;
    }
};

fn decideFor(arena: std.mem.Allocator, pairs: []const [2][]const u8) !Decision {
    const env: MapEnv = .{ .pairs = pairs };
    return decide(arena, env.lookup(), "1.2.3");
}

test "otel: nothing set exports nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(Decision{ .off = .not_configured }, try decideFor(arena.allocator(), &.{}));
}

test "otel: general endpoint gets /v1/traces; signal endpoint is used as is" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const general = (try decideFor(a, &.{.{ "OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318/" }})).export_to;
    try testing.expectEqualStrings("http://collector:4318/v1/traces", general.endpoint);
    try testing.expectEqual(otlp.Protocol.http_protobuf, general.protocol);
    try testing.expect(!general.capture_content);

    const specific = (try decideFor(a, &.{
        .{ "OTEL_EXPORTER_OTLP_ENDPOINT", "http://ignored:1" },
        .{ "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "https://x.example/api/traces" },
    })).export_to;
    try testing.expectEqualStrings("https://x.example/api/traces", specific.endpoint);
}

test "otel: OTEL_TRACES_EXPORTER=otlp alone uses the localhost default; none and others are off" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("http://localhost:4318/v1/traces", (try decideFor(a, &.{.{ "OTEL_TRACES_EXPORTER", "otlp" }})).export_to.endpoint);
    try testing.expectEqual(Decision{ .off = .exporter_none }, try decideFor(a, &.{ .{ "OTEL_TRACES_EXPORTER", "none" }, .{ "OTEL_EXPORTER_OTLP_ENDPOINT", "http://c:1" } }));
    try testing.expectEqual(Decision{ .off = .unsupported_exporter }, try decideFor(a, &.{.{ "OTEL_TRACES_EXPORTER", "zipkin" }}));
    try testing.expectEqual(Decision{ .off = .sdk_disabled }, try decideFor(a, &.{ .{ "OTEL_SDK_DISABLED", "TRUE" }, .{ "OTEL_EXPORTER_OTLP_ENDPOINT", "http://c:1" } }));
}

test "otel: protocol, headers, timeouts, batch and content flags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = (try decideFor(a, &.{
        .{ "OTEL_EXPORTER_OTLP_ENDPOINT", "http://c:4318" },
        .{ "OTEL_EXPORTER_OTLP_PROTOCOL", "http/protobuf" },
        .{ "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL", "http/json" },
        .{ "OTEL_EXPORTER_OTLP_HEADERS", "authorization=Basic%20abc, x-team = core ,broken" },
        .{ "OTEL_EXPORTER_OTLP_TIMEOUT", "2500" },
        .{ "OTEL_BSP_SCHEDULE_DELAY", "100" },
        .{ "OTEL_BSP_MAX_EXPORT_BATCH_SIZE", "0" },
        .{ "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT", "true" },
    })).export_to;
    try testing.expectEqual(otlp.Protocol.http_json, cfg.protocol);
    try testing.expectEqual(@as(usize, 2), cfg.headers.len);
    try testing.expectEqualStrings("authorization", cfg.headers[0].name);
    try testing.expectEqualStrings("Basic abc", cfg.headers[0].value);
    try testing.expectEqualStrings("x-team", cfg.headers[1].name);
    try testing.expectEqualStrings("core", cfg.headers[1].value);
    try testing.expectEqual(@as(u32, 2500), cfg.timeout_ms);
    try testing.expectEqual(@as(u32, 100), cfg.schedule_delay_ms);
    try testing.expectEqual(DEFAULT_MAX_EXPORT_BATCH_SIZE, cfg.max_export_batch_size);
    try testing.expect(cfg.capture_content);

    try testing.expectEqual(Decision{ .off = .unsupported_protocol }, try decideFor(a, &.{
        .{ "OTEL_EXPORTER_OTLP_ENDPOINT", "http://c:4317" },
        .{ "OTEL_EXPORTER_OTLP_PROTOCOL", "grpc" },
    }));
    try testing.expectEqual(Decision{ .off = .invalid_endpoint }, try decideFor(a, &.{.{ "OTEL_EXPORTER_OTLP_ENDPOINT", "collector:4318" }}));
}

test "otel: resource attributes: OTEL_SERVICE_NAME wins, reserved keys are ours" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = (try decideFor(a, &.{
        .{ "OTEL_EXPORTER_OTLP_ENDPOINT", "http://c:4318" },
        .{ "OTEL_RESOURCE_ATTRIBUTES", "service.name=from-attrs,deployment.environment=dev,telemetry.sdk.name=x" },
    })).export_to;
    try testing.expectEqualStrings("from-attrs", cfg.resource[0].value.string);
    try testing.expectEqualStrings("service.version", cfg.resource[1].key);
    try testing.expectEqualStrings("deployment.environment", cfg.resource[cfg.resource.len - 1].key);
    for (cfg.resource) |r| if (std.mem.eql(u8, r.key, "telemetry.sdk.name")) try testing.expectEqualStrings("metacodes", r.value.string);

    const named = (try decideFor(a, &.{
        .{ "OTEL_EXPORTER_OTLP_ENDPOINT", "http://c:4318" },
        .{ "OTEL_SERVICE_NAME", "my-agent" },
        .{ "OTEL_RESOURCE_ATTRIBUTES", "service.name=from-attrs" },
    })).export_to;
    try testing.expectEqualStrings("my-agent", named.resource[0].value.string);
}
