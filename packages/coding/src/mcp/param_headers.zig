//! 2026-07-28 `x-mcp-header`: a tool's `inputSchema` may mark primitive
//! parameters whose values the client mirrors into `Mcp-Param-{name}` HTTP
//! headers (basic/transports/streamable-http.mdx, "Schema Extension").
//!
//! An annotation is valid only on a property reachable from the schema root
//! through `properties` keys alone, of type string, integer or boolean, with a
//! non-empty RFC 9110 token name unique case-insensitively within the schema.
//! A Streamable HTTP client MUST drop a tool with any invalid annotation.

const std = @import("std");

pub const ParamHeader = struct {
    /// Property path from the arguments root.
    path: []const []const u8,
    /// Value of `x-mcp-header` (the `{name}` in `Mcp-Param-{name}`).
    name: []const u8,
};

pub const Error = error{ OutOfMemory, InvalidParamHeader };

/// Every annotation in `schema`, or `error.InvalidParamHeader` when any one
/// violates the constraints. All slices live in `arena`.
pub fn collect(arena: std.mem.Allocator, schema: ?std.json.Value) Error![]const ParamHeader {
    const root = schema orelse return &.{};
    var out: std.ArrayList(ParamHeader) = .empty;
    try walkProperties(arena, root, &.{}, &out);
    // An annotation anywhere a `properties` chain does not reach (items,
    // oneOf, $defs, ...) invalidates the tool.
    if (countAnnotations(root) != out.items.len) return error.InvalidParamHeader;
    for (out.items, 0..) |header, index| {
        for (out.items[0..index]) |earlier| {
            if (std.ascii.eqlIgnoreCase(earlier.name, header.name)) return error.InvalidParamHeader;
        }
    }
    return out.toOwnedSlice(arena);
}

fn walkProperties(
    arena: std.mem.Allocator,
    schema: std.json.Value,
    prefix: []const []const u8,
    out: *std.ArrayList(ParamHeader),
) Error!void {
    if (schema != .object) return;
    const properties = schema.object.get("properties") orelse return;
    if (properties != .object) return;
    var iterator = properties.object.iterator();
    while (iterator.next()) |entry| {
        const property = entry.value_ptr.*;
        const path = try arena.alloc([]const u8, prefix.len + 1);
        @memcpy(path[0..prefix.len], prefix);
        path[prefix.len] = entry.key_ptr.*;
        if (property == .object) {
            if (property.object.get("x-mcp-header")) |annotation| {
                const name = switch (annotation) {
                    .string => |value| value,
                    else => return error.InvalidParamHeader,
                };
                if (!validToken(name)) return error.InvalidParamHeader;
                const type_value = property.object.get("type") orelse return error.InvalidParamHeader;
                if (type_value != .string) return error.InvalidParamHeader;
                const kind = type_value.string;
                if (!std.mem.eql(u8, kind, "string") and !std.mem.eql(u8, kind, "integer") and !std.mem.eql(u8, kind, "boolean"))
                    return error.InvalidParamHeader;
                try out.append(arena, .{ .path = path, .name = name });
            }
        }
        try walkProperties(arena, property, path, out);
    }
}

fn countAnnotations(value: std.json.Value) usize {
    return switch (value) {
        .object => |object| blk: {
            var count: usize = 0;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "x-mcp-header")) count += 1;
                count += countAnnotations(entry.value_ptr.*);
            }
            break :blk count;
        },
        .array => |array| blk: {
            var count: usize = 0;
            for (array.items) |item| count += countAnnotations(item);
            break :blk count;
        },
        else => 0,
    };
}

/// RFC 9110 `token = 1*tchar`.
fn validToken(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        if (std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null) return false;
    }
    return true;
}

pub const Header = @import("transport_http.zig").Header;

/// `Mcp-Param-*` headers for one call. A parameter absent (or null) in the
/// arguments contributes no header; an integer outside JavaScript's safe range
/// or a value of the wrong type is an error rather than a silent mismatch.
pub fn headersForCall(arena: std.mem.Allocator, params: []const ParamHeader, arguments_json: []const u8) ![]const Header {
    if (params.len == 0) return &.{};
    const arguments = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments_json, .{ .parse_numbers = false }) catch
        return error.InvalidArguments;
    var out: std.ArrayList(Header) = .empty;
    for (params) |param| {
        var value = arguments;
        for (param.path) |key| {
            if (value != .object) break;
            value = value.object.get(key) orelse break;
        } else {
            const text: ?[]const u8 = switch (value) {
                .string => |string| string,
                .bool => |flag| if (flag) "true" else "false",
                .number_string => |number| blk: {
                    const integer = std.fmt.parseInt(i64, number, 10) catch return error.InvalidArguments;
                    const safe: i64 = (1 << 53) - 1;
                    if (integer > safe or integer < -safe) return error.InvalidArguments;
                    break :blk number;
                },
                .integer => |integer| try std.fmt.allocPrint(arena, "{d}", .{integer}),
                .null => null,
                else => return error.InvalidArguments,
            };
            if (text) |header_value| {
                try out.append(arena, .{
                    .name = try std.fmt.allocPrint(arena, "Mcp-Param-{s}", .{param.name}),
                    .value = header_value,
                });
            }
        }
    }
    return out.toOwnedSlice(arena);
}

const testing = std.testing;

fn parse(arena: std.mem.Allocator, text: []const u8) std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch unreachable;
}

test "valid annotations, including nested properties chains, are collected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const params = try collect(a, parse(a,
        \\{"type":"object","properties":{
        \\  "region":{"type":"string","x-mcp-header":"Region"},
        \\  "opts":{"type":"object","properties":{"dry":{"type":"boolean","x-mcp-header":"Dry-Run"}}},
        \\  "query":{"type":"string"}}}
    ));
    try testing.expectEqual(@as(usize, 2), params.len);
    const headers = try headersForCall(a, params, "{\"region\":\"us-east\",\"opts\":{\"dry\":true},\"query\":\"x\"}");
    try testing.expectEqual(@as(usize, 2), headers.len);
    var seen_region = false;
    for (headers) |header| {
        if (std.mem.eql(u8, header.name, "Mcp-Param-Region")) {
            try testing.expectEqualStrings("us-east", header.value);
            seen_region = true;
        }
    }
    try testing.expect(seen_region);
    const omitted = try headersForCall(a, params, "{\"query\":\"x\"}");
    try testing.expectEqual(@as(usize, 0), omitted.len);
}

test "invalid annotations reject the tool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = [_][]const u8{
        "{\"properties\":{\"x\":{\"type\":\"number\",\"x-mcp-header\":\"X\"}}}",
        "{\"properties\":{\"x\":{\"type\":\"string\",\"x-mcp-header\":\"\"}}}",
        "{\"properties\":{\"x\":{\"type\":\"string\",\"x-mcp-header\":\"bad name\"}}}",
        "{\"properties\":{\"x\":{\"type\":\"string\",\"x-mcp-header\":\"A\"},\"y\":{\"type\":\"string\",\"x-mcp-header\":\"a\"}}}",
        "{\"properties\":{\"x\":{\"type\":\"array\",\"items\":{\"type\":\"string\",\"x-mcp-header\":\"X\"}}}}",
        "{\"properties\":{\"x\":{\"oneOf\":[{\"type\":\"string\",\"x-mcp-header\":\"X\"}]}}}",
    };
    for (bad) |schema| try testing.expectError(error.InvalidParamHeader, collect(a, parse(a, schema)));
}

test "integers outside the JavaScript safe range are refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const params = try collect(a, parse(a, "{\"properties\":{\"n\":{\"type\":\"integer\",\"x-mcp-header\":\"N\"}}}"));
    const ok = try headersForCall(a, params, "{\"n\":42}");
    try testing.expectEqualStrings("42", ok[0].value);
    try testing.expectError(error.InvalidArguments, headersForCall(a, params, "{\"n\":9007199254740993}"));
}
