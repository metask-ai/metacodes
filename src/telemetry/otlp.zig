//! OTLP encodings of `span.Span`: the JSON mapping (OTLP/HTTP `http/json`,
//! also the line format of a session's `spans.jsonl`) and the protobuf wire
//! format (OTLP/HTTP `http/protobuf`, the specification's default).
//!
//! Both are written against `opentelemetry/proto/trace/v1/trace.proto` and
//! `collector/trace/v1/trace_service.proto`; field numbers are listed next to
//! each writer. Encoding is two-step so a batch exporter can encode a span the
//! moment it ends and keep only bytes: `encodeSpan*` produces one `Span`
//! message, `writeRequest*` wraps a batch of them in an
//! `ExportTraceServiceRequest` with the resource and scope.
//!
//! Message content (`Attribute.content`) is dropped unless the policy includes
//! it, and is cut to `max_content_bytes` (on a UTF-8 boundary) when it is.
//! Every string is written as valid UTF-8: OTLP receivers reject a protobuf
//! string field that is not.

const std = @import("std");
const span_mod = @import("span.zig");
const json_util = @import("../util/json.zig");

const Span = span_mod.Span;
const Attribute = span_mod.Attribute;
const Event = span_mod.Event;

pub const Protocol = enum {
    http_protobuf,
    http_json,

    pub fn contentType(self: Protocol) []const u8 {
        return switch (self) {
            .http_protobuf => "application/x-protobuf",
            .http_json => "application/json",
        };
    }
};

pub const ContentPolicy = struct {
    include: bool,
    max_content_bytes: usize = DEFAULT_MAX_CONTENT_BYTES,
};

/// A tool result or a model answer can be megabytes; a span attribute that
/// large is refused by most backends and useless in a waterfall.
pub const DEFAULT_MAX_CONTENT_BYTES: usize = 16 * 1024;
/// Non-content strings (names, ids, error descriptions) are short by
/// construction; the bound only protects the encoder from a pathological one.
pub const MAX_PLAIN_STRING_BYTES: usize = 4 * 1024;
const TRUNCATION_MARK = "…[truncated]";

pub const Scope = struct {
    name: []const u8 = "metacodes",
    version: []const u8 = "",
};

pub const Resource = struct {
    attributes: []const Attribute,
};

fn shown(attr: Attribute, policy: ContentPolicy) bool {
    return !attr.content or policy.include;
}

/// The string as it will be exported: bounded, and marked when cut.
const Bounded = struct {
    head: []const u8,
    truncated: bool,

    fn of(attr: Attribute, s: []const u8, policy: ContentPolicy) Bounded {
        const max = if (attr.content) policy.max_content_bytes else MAX_PLAIN_STRING_BYTES;
        const head = span_mod.truncateUtf8(s, max);
        return .{ .head = head, .truncated = head.len < s.len };
    }
};

// ── JSON ────────────────────────────────────────────────────────────────

/// One OTLP/JSON `Span` object (no trailing newline).
pub fn encodeSpanJson(allocator: std.mem.Allocator, s: *const Span, policy: ContentPolicy) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    writeSpanJson(&out.writer, s, policy) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeSpanJson(w: *std.Io.Writer, s: *const Span, policy: ContentPolicy) std.Io.Writer.Error!void {
    try w.print("{{\"traceId\":\"{s}\",\"spanId\":\"{s}\"", .{ &s.trace_id.hex(), &s.span_id.hex() });
    if (s.parent_span_id) |parent| try w.print(",\"parentSpanId\":\"{s}\"", .{&parent.hex()});
    try w.writeAll(",\"name\":");
    try json_util.writeJsonString(w, span_mod.truncateUtf8(s.name, MAX_PLAIN_STRING_BYTES));
    try w.print(",\"kind\":{d},\"startTimeUnixNano\":\"{d}\",\"endTimeUnixNano\":\"{d}\"", .{
        @intFromEnum(s.kind), s.start_unix_nano, s.end_unix_nano,
    });
    try w.writeAll(",\"attributes\":");
    try writeAttributesJson(w, s.attributes, policy);
    if (s.events.len > 0) {
        try w.writeAll(",\"events\":[");
        for (s.events, 0..) |e, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{{\"timeUnixNano\":\"{d}\",\"name\":", .{e.time_unix_nano});
            try json_util.writeJsonString(w, e.name);
            try w.writeAll(",\"attributes\":");
            try writeAttributesJson(w, e.attributes, policy);
            try w.writeByte('}');
        }
        try w.writeByte(']');
    }
    try w.print(",\"status\":{{\"code\":{d}", .{s.status.code()});
    switch (s.status) {
        .@"error" => |message| {
            try w.writeAll(",\"message\":");
            try json_util.writeJsonString(w, span_mod.truncateUtf8(message, MAX_PLAIN_STRING_BYTES));
        },
        .unset, .ok => {},
    }
    try w.writeAll("}}");
}

fn writeAttributesJson(w: *std.Io.Writer, attrs: []const Attribute, policy: ContentPolicy) std.Io.Writer.Error!void {
    try w.writeByte('[');
    var first = true;
    for (attrs) |a| {
        if (!shown(a, policy)) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"key\":");
        try json_util.writeJsonString(w, a.key);
        try w.writeAll(",\"value\":{");
        switch (a.value) {
            .string => |s| {
                const b = Bounded.of(a, s, policy);
                try w.writeAll("\"stringValue\":\"");
                try json_util.writeJsonStringContents(w, b.head);
                if (b.truncated) try w.writeAll(TRUNCATION_MARK);
                try w.writeByte('"');
            },
            // proto3 JSON writes int64 as a string.
            .int => |v| try w.print("\"intValue\":\"{d}\"", .{v}),
            .double => |v| if (std.math.isFinite(v))
                try w.print("\"doubleValue\":{d}", .{v})
            else
                try w.writeAll("\"doubleValue\":0"),
            .boolean => |v| try w.print("\"boolValue\":{}", .{v}),
        }
        try w.writeAll("}}");
    }
    try w.writeByte(']');
}

/// `ExportTraceServiceRequest` in OTLP/JSON around already-encoded span
/// objects (`encodeSpanJson`).
pub fn writeRequestJson(w: *std.Io.Writer, resource: Resource, scope: Scope, spans: []const []const u8) std.Io.Writer.Error!void {
    try w.writeAll("{\"resourceSpans\":[{\"resource\":{\"attributes\":");
    try writeAttributesJson(w, resource.attributes, .{ .include = true });
    try w.writeAll("},\"scopeSpans\":[{\"scope\":{\"name\":");
    try json_util.writeJsonString(w, scope.name);
    try w.writeAll(",\"version\":");
    try json_util.writeJsonString(w, scope.version);
    try w.writeAll("},\"spans\":[");
    for (spans, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll(s);
    }
    try w.writeAll("]}]}]}");
}

// ── Protobuf ────────────────────────────────────────────────────────────

const WireType = enum(u3) { varint = 0, fixed64 = 1, len = 2, fixed32 = 5 };

const Pb = struct {
    list: *std.ArrayList(u8),
    gpa: std.mem.Allocator,

    fn varint(self: Pb, value: u64) !void {
        var v = value;
        while (v >= 0x80) : (v >>= 7) try self.list.append(self.gpa, @as(u8, @truncate(v)) | 0x80);
        try self.list.append(self.gpa, @truncate(v));
    }
    fn tag(self: Pb, field: u32, wire: WireType) !void {
        try self.varint((@as(u64, field) << 3) | @intFromEnum(wire));
    }
    fn bytes(self: Pb, field: u32, value: []const u8) !void {
        try self.tag(field, .len);
        try self.varint(value.len);
        try self.list.appendSlice(self.gpa, value);
    }
    /// A string field, repaired to valid UTF-8 and optionally marked as cut.
    fn string(self: Pb, field: u32, value: []const u8, truncated: bool) !void {
        if (value.len == 0 and !truncated) return;
        var tmp: std.Io.Writer.Allocating = .init(self.gpa);
        defer tmp.deinit();
        json_util.writeUtf8Repaired(&tmp.writer, value) catch return error.OutOfMemory;
        if (truncated) tmp.writer.writeAll(TRUNCATION_MARK) catch return error.OutOfMemory;
        try self.bytes(field, tmp.written());
    }
    fn fixed64(self: Pb, field: u32, value: u64) !void {
        try self.tag(field, .fixed64);
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, value, .little);
        try self.list.appendSlice(self.gpa, &buf);
    }
    fn uint(self: Pb, field: u32, value: u64) !void {
        if (value == 0) return;
        try self.tag(field, .varint);
        try self.varint(value);
    }
    /// A nested message: encode it on its own, then write it length-delimited.
    fn message(self: Pb, field: u32, ctx: anytype, comptime writeFn: anytype) !void {
        var inner: std.ArrayList(u8) = .empty;
        defer inner.deinit(self.gpa);
        try writeFn(Pb{ .list = &inner, .gpa = self.gpa }, ctx);
        try self.bytes(field, inner.items);
    }
};

const AttrCtx = struct { attr: Attribute, policy: ContentPolicy };

/// KeyValue { string key = 1; AnyValue value = 2; }
/// AnyValue { string_value = 1; bool_value = 2; int_value = 3; double_value = 4; }
fn pbKeyValue(pb: Pb, ctx: AttrCtx) error{OutOfMemory}!void {
    try pb.string(1, ctx.attr.key, false);
    try pb.message(2, ctx, pbAnyValue);
}

fn pbAnyValue(pb: Pb, ctx: AttrCtx) error{OutOfMemory}!void {
    switch (ctx.attr.value) {
        .string => |s| {
            const b = Bounded.of(ctx.attr, s, ctx.policy);
            // An empty string must still select the oneof member.
            if (b.head.len == 0 and !b.truncated) {
                try pb.bytes(1, "");
            } else try pb.string(1, b.head, b.truncated);
        },
        .boolean => |v| {
            try pb.tag(2, .varint);
            try pb.varint(@intFromBool(v));
        },
        .int => |v| {
            try pb.tag(3, .varint);
            try pb.varint(@bitCast(v));
        },
        .double => |v| {
            try pb.tag(4, .fixed64);
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, @bitCast(if (std.math.isFinite(v)) v else 0), .little);
            try pb.list.appendSlice(pb.gpa, &buf);
        },
    }
}

fn pbAttributes(pb: Pb, field: u32, attrs: []const Attribute, policy: ContentPolicy) error{OutOfMemory}!void {
    for (attrs) |a| {
        if (!shown(a, policy)) continue;
        try pb.message(field, AttrCtx{ .attr = a, .policy = policy }, pbKeyValue);
    }
}

const SpanCtx = struct { span: *const Span, policy: ContentPolicy };
const EventCtx = struct { event: Event, policy: ContentPolicy };

/// Event { fixed64 time_unix_nano = 1; string name = 2; repeated KeyValue attributes = 3; }
fn pbEvent(pb: Pb, ctx: EventCtx) error{OutOfMemory}!void {
    try pb.fixed64(1, ctx.event.time_unix_nano);
    try pb.string(2, ctx.event.name, false);
    try pbAttributes(pb, 3, ctx.event.attributes, ctx.policy);
}

/// Status { string message = 2; StatusCode code = 3; }
fn pbStatus(pb: Pb, status: span_mod.Status) error{OutOfMemory}!void {
    switch (status) {
        .@"error" => |message| {
            const head = span_mod.truncateUtf8(message, MAX_PLAIN_STRING_BYTES);
            try pb.string(2, head, head.len < message.len);
        },
        .unset, .ok => {},
    }
    try pb.uint(3, status.code());
}

/// Span { bytes trace_id = 1; bytes span_id = 2; bytes parent_span_id = 4;
///        string name = 5; SpanKind kind = 6; fixed64 start_time_unix_nano = 7;
///        fixed64 end_time_unix_nano = 8; repeated KeyValue attributes = 9;
///        repeated Event events = 11; Status status = 15; }
fn pbSpan(pb: Pb, ctx: SpanCtx) error{OutOfMemory}!void {
    const s = ctx.span;
    try pb.bytes(1, &s.trace_id.bytes);
    try pb.bytes(2, &s.span_id.bytes);
    if (s.parent_span_id) |parent| try pb.bytes(4, &parent.bytes);
    const name = span_mod.truncateUtf8(s.name, MAX_PLAIN_STRING_BYTES);
    try pb.string(5, name, name.len < s.name.len);
    try pb.uint(6, @intFromEnum(s.kind));
    try pb.fixed64(7, s.start_unix_nano);
    try pb.fixed64(8, s.end_unix_nano);
    try pbAttributes(pb, 9, s.attributes, ctx.policy);
    for (s.events) |e| try pb.message(11, EventCtx{ .event = e, .policy = ctx.policy }, pbEvent);
    try pb.message(15, s.status, pbStatus);
}

/// One protobuf `Span` message body (without its field tag).
pub fn encodeSpanProto(allocator: std.mem.Allocator, s: *const Span, policy: ContentPolicy) error{OutOfMemory}![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try pbSpan(.{ .list = &list, .gpa = allocator }, .{ .span = s, .policy = policy });
    return list.toOwnedSlice(allocator);
}

const RequestCtx = struct { resource: Resource, scope: Scope, spans: []const []const u8 };

/// ExportTraceServiceRequest { repeated ResourceSpans resource_spans = 1; }
/// ResourceSpans { Resource resource = 1; repeated ScopeSpans scope_spans = 2; }
/// Resource { repeated KeyValue attributes = 1; }
/// ScopeSpans { InstrumentationScope scope = 1; repeated Span spans = 2; }
/// InstrumentationScope { string name = 1; string version = 2; }
pub fn encodeRequestProto(allocator: std.mem.Allocator, resource: Resource, scope: Scope, spans: []const []const u8) error{OutOfMemory}![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    const pb: Pb = .{ .list = &list, .gpa = allocator };
    try pb.message(1, RequestCtx{ .resource = resource, .scope = scope, .spans = spans }, pbResourceSpans);
    return list.toOwnedSlice(allocator);
}

fn pbResourceSpans(pb: Pb, ctx: RequestCtx) error{OutOfMemory}!void {
    try pb.message(1, ctx.resource, pbResource);
    try pb.message(2, ctx, pbScopeSpans);
}

fn pbResource(pb: Pb, resource: Resource) error{OutOfMemory}!void {
    try pbAttributes(pb, 1, resource.attributes, .{ .include = true });
}

fn pbScopeSpans(pb: Pb, ctx: RequestCtx) error{OutOfMemory}!void {
    try pb.message(1, ctx.scope, pbScope);
    for (ctx.spans) |s| try pb.bytes(2, s);
}

fn pbScope(pb: Pb, scope: Scope) error{OutOfMemory}!void {
    try pb.string(1, scope.name, false);
    try pb.string(2, scope.version, false);
}

/// Encode one span in `protocol`'s form.
pub fn encodeSpan(allocator: std.mem.Allocator, protocol: Protocol, s: *const Span, policy: ContentPolicy) error{OutOfMemory}![]u8 {
    return switch (protocol) {
        .http_json => encodeSpanJson(allocator, s, policy),
        .http_protobuf => encodeSpanProto(allocator, s, policy),
    };
}

/// Encode a request body in `protocol`'s form around spans `encodeSpan` made.
pub fn encodeRequest(allocator: std.mem.Allocator, protocol: Protocol, resource: Resource, scope: Scope, spans: []const []const u8) error{OutOfMemory}![]u8 {
    switch (protocol) {
        .http_protobuf => return encodeRequestProto(allocator, resource, scope, spans),
        .http_json => {
            var out: std.Io.Writer.Allocating = .init(allocator);
            errdefer out.deinit();
            writeRequestJson(&out.writer, resource, scope, spans) catch return error.OutOfMemory;
            return out.toOwnedSlice() catch return error.OutOfMemory;
        },
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn fixtureSpan(attrs: []const Attribute, events: []const Event, status: span_mod.Status) Span {
    return .{
        .trace_id = .{ .bytes = .{ 0x4b, 0xf9, 0x2f, 0x35, 0x77, 0xb3, 0x4d, 0xa6, 0xa3, 0xce, 0x92, 0x9d, 0x0e, 0x0e, 0x47, 0x36 } },
        .span_id = .{ .bytes = .{ 0x00, 0xf0, 0x67, 0xaa, 0x0b, 0xa9, 0x02, 0xb7 } },
        .parent_span_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8 } },
        .name = "chat claude",
        .kind = .client,
        .start_unix_nano = 1_700_000_000_000_000_000,
        .end_unix_nano = 1_700_000_001_000_000_000,
        .attributes = attrs,
        .events = events,
        .status = status,
    };
}

test "otel: JSON span follows the OTLP/JSON mapping and drops content by policy" {
    const attrs = [_]Attribute{
        Attribute.str("gen_ai.operation.name", "chat"),
        Attribute.int("gen_ai.usage.input_tokens", 12),
        Attribute.boolean("metacodes.flag", true),
        Attribute.text("gen_ai.output.messages", "secret answer"),
    };
    const events = [_]Event{.{ .name = "cache_break", .time_unix_nano = 5, .attributes = &.{Attribute.int("cache_read", 1)} }};
    const s = fixtureSpan(&attrs, &events, .{ .@"error" = "boom" });

    const without = try encodeSpanJson(testing.allocator, &s, .{ .include = false });
    defer testing.allocator.free(without);
    try testing.expect(std.mem.indexOf(u8, without, "secret answer") == null);
    try testing.expect(std.mem.indexOf(u8, without, "\"traceId\":\"4bf92f3577b34da6a3ce929d0e0e4736\"") != null);
    try testing.expect(std.mem.indexOf(u8, without, "\"parentSpanId\":\"0102030405060708\"") != null);
    try testing.expect(std.mem.indexOf(u8, without, "\"intValue\":\"12\"") != null);
    try testing.expect(std.mem.indexOf(u8, without, "\"startTimeUnixNano\":\"1700000000000000000\"") != null);
    try testing.expect(std.mem.indexOf(u8, without, "\"status\":{\"code\":2,\"message\":\"boom\"}") != null);

    const with = try encodeSpanJson(testing.allocator, &s, .{ .include = true });
    defer testing.allocator.free(with);
    try testing.expect(std.mem.indexOf(u8, with, "secret answer") != null);
    // Parses as JSON.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, with, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("chat claude", parsed.value.object.get("name").?.string);
}

test "otel: content is cut on a UTF-8 boundary and marked" {
    const long = "中" ** 10; // 30 bytes
    const attrs = [_]Attribute{Attribute.text("gen_ai.tool.call.result", long)};
    const s = fixtureSpan(&attrs, &.{}, .unset);
    const out = try encodeSpanJson(testing.allocator, &s, .{ .include = true, .max_content_bytes = 7 });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"stringValue\":\"中中" ++ TRUNCATION_MARK ++ "\"") != null);
}

/// A minimal protobuf reader for the tests: walks one message's fields.
const PbReader = struct {
    buf: []const u8,
    pos: usize = 0,

    const Field = struct { number: u64, wire: u3, varint: u64 = 0, bytes: []const u8 = &.{} };

    fn readVarint(self: *PbReader) !u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (self.pos >= self.buf.len) return error.Truncated;
            const b = self.buf[self.pos];
            self.pos += 1;
            result |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) return result;
            shift += 7;
        }
    }

    fn next(self: *PbReader) !?Field {
        if (self.pos >= self.buf.len) return null;
        const key = try self.readVarint();
        var f: Field = .{ .number = key >> 3, .wire = @truncate(key & 7) };
        switch (f.wire) {
            0 => f.varint = try self.readVarint(),
            1 => {
                f.varint = std.mem.readInt(u64, self.buf[self.pos..][0..8], .little);
                self.pos += 8;
            },
            2 => {
                const n: usize = @intCast(try self.readVarint());
                f.bytes = self.buf[self.pos .. self.pos + n];
                self.pos += n;
            },
            else => return error.UnexpectedWireType,
        }
        return f;
    }

    fn find(buf: []const u8, number: u64) !?Field {
        var r: PbReader = .{ .buf = buf };
        while (try r.next()) |f| if (f.number == number) return f;
        return null;
    }
};

test "otel: protobuf request decodes back to the trace.proto field layout" {
    const a = testing.allocator;
    const attrs = [_]Attribute{
        Attribute.str("gen_ai.operation.name", "chat"),
        Attribute.int("gen_ai.usage.output_tokens", 300),
        Attribute.text("gen_ai.output.messages", "hidden"),
    };
    const s = fixtureSpan(&attrs, &.{}, .{ .@"error" = "x" });
    const span_bytes = try encodeSpanProto(a, &s, .{ .include = false });
    defer a.free(span_bytes);
    const resource_attrs = [_]Attribute{Attribute.str("service.name", "metacodes")};
    const body = try encodeRequestProto(a, .{ .attributes = &resource_attrs }, .{ .version = "1.0" }, &.{span_bytes});
    defer a.free(body);

    const rs = (try PbReader.find(body, 1)).?; // resource_spans
    const resource = (try PbReader.find(rs.bytes, 1)).?;
    const service_kv = (try PbReader.find(resource.bytes, 1)).?;
    try testing.expectEqualStrings("service.name", (try PbReader.find(service_kv.bytes, 1)).?.bytes);
    const ss = (try PbReader.find(rs.bytes, 2)).?; // scope_spans
    try testing.expectEqualStrings("metacodes", (try PbReader.find((try PbReader.find(ss.bytes, 1)).?.bytes, 1)).?.bytes);
    const sp = (try PbReader.find(ss.bytes, 2)).?.bytes; // span
    try testing.expectEqualSlices(u8, &s.trace_id.bytes, (try PbReader.find(sp, 1)).?.bytes);
    try testing.expectEqualSlices(u8, &s.span_id.bytes, (try PbReader.find(sp, 2)).?.bytes);
    try testing.expectEqualSlices(u8, &s.parent_span_id.?.bytes, (try PbReader.find(sp, 4)).?.bytes);
    try testing.expectEqualStrings("chat claude", (try PbReader.find(sp, 5)).?.bytes);
    try testing.expectEqual(@as(u64, 3), (try PbReader.find(sp, 6)).?.varint); // CLIENT
    try testing.expectEqual(s.start_unix_nano, (try PbReader.find(sp, 7)).?.varint);
    try testing.expectEqual(s.end_unix_nano, (try PbReader.find(sp, 8)).?.varint);
    const status = (try PbReader.find(sp, 15)).?.bytes;
    try testing.expectEqual(@as(u64, 2), (try PbReader.find(status, 3)).?.varint);

    // Attributes: content dropped, int kept as varint.
    var r: PbReader = .{ .buf = sp };
    var keys: usize = 0;
    while (try r.next()) |f| {
        if (f.number != 9) continue;
        keys += 1;
        const key = (try PbReader.find(f.bytes, 1)).?.bytes;
        try testing.expect(!std.mem.eql(u8, key, "gen_ai.output.messages"));
        if (std.mem.eql(u8, key, "gen_ai.usage.output_tokens")) {
            const any = (try PbReader.find(f.bytes, 2)).?.bytes;
            try testing.expectEqual(@as(u64, 300), (try PbReader.find(any, 3)).?.varint);
        }
    }
    try testing.expectEqual(@as(usize, 2), keys);
}

test "otel: protobuf strings are repaired to valid UTF-8" {
    const a = testing.allocator;
    const attrs = [_]Attribute{Attribute.str("k", "ok\xffbad")};
    const s = fixtureSpan(&attrs, &.{}, .unset);
    const bytes = try encodeSpanProto(a, &s, .{ .include = false });
    defer a.free(bytes);
    const kv = (try PbReader.find(bytes, 9)).?.bytes;
    const any = (try PbReader.find(kv, 2)).?.bytes;
    const value = (try PbReader.find(any, 1)).?.bytes;
    try testing.expect(std.unicode.utf8ValidateSlice(value));
    try testing.expectEqualStrings("ok\u{FFFD}bad", value);
}
