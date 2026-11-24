const std = @import("std");
const normalize = @import("normalize.zig");
const golden = @import("golden.zig");
const sse = @import("sse.zig");

test {
    _ = @import("zig_api.zig");
}

fn expectApplied(input: []const u8, rules: normalize.Rules, expected: []const u8) !void {
    const got = try normalize.apply(std.testing.allocator, input, rules);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(expected, got);
}

test "timestamps become placeholders, a bare date does not" {
    try expectApplied("at 2026-11-23T10:11:12.345Z and 2026-01-02 03:04:05+08:00", .{}, "at <TIMESTAMP> and <TIMESTAMP>");
    try expectApplied("anthropic-version: 2023-06-01\n", .{}, "anthropic-version: 2023-06-01\n");
    try expectApplied("Today's date is 2026-11-23 (Monday).", .{ .literals = &.{.{ .needle = "2026-11-23 (Monday)", .placeholder = "<DATE>" }} }, "Today's date is <DATE>.");
}

test "runtime environment values are replaced only where they occur, keeping what follows" {
    try expectApplied(
        " - Platform: darwin (beta)\\n - OS Version: Darwin 27.2.0\\n",
        .{ .literals = &.{
            .{ .needle = "Platform: darwin", .placeholder = "Platform: <PLATFORM>" },
            .{ .needle = "OS Version: Darwin 27.2.0", .placeholder = "OS Version: <OS_VERSION>" },
        } },
        " - Platform: <PLATFORM> (beta)\\n - OS Version: <OS_VERSION>\\n",
    );
}

test "numbers under timing keys become <N>, also inside escaped JSON" {
    try expectApplied("{\"elapsed_ms\":17,\"turns\":2}", .{}, "{\"elapsed_ms\":<N>,\"turns\":2}");
    try expectApplied("\"{\\\"elapsed_ms\\\":3}\"", .{}, "\"{\\\"elapsed_ms\\\":<N>}\"");
    try expectApplied("{\"startTimeUnixNano\":\"1795\",\"last_modified_ns\":9}", .{}, "{\"startTimeUnixNano\":\"<N>\",\"last_modified_ns\":<N>}");
    try expectApplied("{\"bytes\":12,\"content_bytes\":145}", .{}, "{\"bytes\":12,\"content_bytes\":<N>}");
}

test "string values under identifier keys become <ID>, null stays" {
    try expectApplied("{\"trace_id\":\"db9832d00000\",\"x\":1},{\"trace_id\":null}", .{}, "{\"trace_id\":\"<ID>\",\"x\":1},{\"trace_id\":null}");
}

test "hex identifiers of 16 or more characters and UUIDs become placeholders" {
    try expectApplied("projects/54104febbb7b708c/000001a20c4ced0066a5c7b0", .{}, "projects/<HEX16>/<HEX24>");
    try expectApplied("id 123e4567-e89b-12d3-a456-426614174000.", .{}, "id <UUID>.");
    try expectApplied("deadbeefdeadbeefdeadbeef", .{}, "deadbeefdeadbeefdeadbeef");
    try expectApplied("toolu_1 abc123", .{}, "toolu_1 abc123");
    try expectApplied("offer-0123456789abcdef0123456789abcdef", .{}, "offer-0123456789abcdef0123456789abcdef");
}

test "literal rules apply longest needle first" {
    try expectApplied(
        "/private/tmp/r/state and /tmp/r",
        .{ .literals = &.{ .{ .needle = "/tmp/r", .placeholder = "<ROOT>" }, .{ .needle = "/private/tmp/r", .placeholder = "<ROOT>" } } },
        "<ROOT>/state and <ROOT>",
    );
}

test "split JSON is reversible and breaks after structure and escaped newlines" {
    const a = std.testing.allocator;
    const body = "{\"a\":[1,2],\"s\":\"x\\ny,{\\\"q\\\"}\"}";
    const split = try normalize.splitJson(a, body);
    defer a.free(split);
    try std.testing.expectEqualStrings("{\n\"a\":[\n1,\n2],\n\"s\":\"x\\n\ny,{\\\"q\\\"}\"}\n", split);
    const joined = try normalize.joinSplitJson(a, split);
    defer a.free(joined);
    try std.testing.expectEqualStrings(body, joined);
    try std.testing.expectError(error.BodyHasLiteralNewline, normalize.splitJson(a, "{\n}"));
}

test "describe names the file, the first differing line and column, and the update command" {
    const a = std.testing.allocator;
    const report = try golden.describe(a, "abi/agentcore_h.txt", "a\nb = 1\nc\n", "a\nb = 2\nc\n");
    defer a.free(report);
    try std.testing.expectEqualStrings(
        \\contract drift: tests/contract/abi/agentcore_h.txt
        \\first difference: line 2, column 5
        \\@@ -2,1 +2,1 @@
        \\ a
        \\-b = 1
        \\+b = 2
        \\ c
        \\if this change is intended, record it with: zig build test:contract -Dupdate-contract
        \\
    , report);
}

test "describe resynchronises after each change and reports every changed region" {
    const a = std.testing.allocator;
    const report = try golden.describe(a, "x", "a\nb\nc\nd\ne\nf\ng\nh\n", "a\nB\nc\nd\ne\nf\nG\nh\n");
    defer a.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "@@ -2,1 +2,1 @@\n a\n-b\n+B\n c\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "@@ -7,1 +7,1 @@\n f\n-g\n+G\n h\n") != null);
}

test "describe shows the part of a long line around the first difference" {
    const a = std.testing.allocator;
    const before = "x" ** 1000 ++ "old" ++ "y" ** 1000;
    const after = "x" ** 1000 ++ "new" ++ "y" ** 1000;
    const report = try golden.describe(a, "x", before, after);
    defer a.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "first difference: line 1, column 1001\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "old") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "new") != null);
}

test "describe shows a pure insertion and a pure deletion" {
    const a = std.testing.allocator;
    const inserted = try golden.describe(a, "x", "a\nc\n", "a\nb\nc\n");
    defer a.free(inserted);
    try std.testing.expect(std.mem.indexOf(u8, inserted, "@@ -2,0 +2,1 @@\n a\n+b\n c\n") != null);
    const deleted = try golden.describe(a, "x", "a\nb\nc\n", "a\nc\n");
    defer a.free(deleted);
    try std.testing.expect(std.mem.indexOf(u8, deleted, "@@ -2,1 +2,0 @@\n a\n-b\n c\n") != null);
}

test "a store in check mode fails on drift and on a missing snapshot; update mode writes it" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const check: golden.Store = .{ .io = io, .root = root, .mode = .check };
    try std.testing.expectError(error.ContractSnapshotMissing, check.expect(a, "s/one.txt", "x\n"));
    const update: golden.Store = .{ .io = io, .root = root, .mode = .update };
    try update.expect(a, "s/one.txt", "x\n");
    try check.expect(a, "s/one.txt", "x\n");
    try std.testing.expectError(error.ContractDrift, check.expect(a, "s/one.txt", "y\n"));
}

const sse_response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" ++
    "retry: 1000\n\n" ++
    ": keepalive\n\n" ++
    "id: e-0\ndata: {\"v\":1,\"type\":\"a\"}\n\n" ++
    "id: e-1\ndata: {\"v\":1,\"type\":\"b\"}\n\n";

test "SSE frames end at a blank line; comments are dropped and data lines give the journal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const response = try sse.parse(a, sse_response);
    try std.testing.expectEqual(@as(usize, 3), response.frames.len);
    try std.testing.expectEqualStrings("{\"v\":1,\"type\":\"a\"}\n{\"v\":1,\"type\":\"b\"}\n", try sse.journal(a, response));
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\nContent-Type: text/event-stream\n\nretry: 1000\n\nid: e-0\ndata: {\"v\":1,\"type\":\"a\"}\n\nid: e-1\ndata: {\"v\":1,\"type\":\"b\"}\n\n",
        try sse.render(a, response),
    );
}

test "a missing frame terminator is an error or changes both the journal and the rendered frames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try sse.parse(a, sse_response);
    try std.testing.expectError(error.UnterminatedFrame, sse.parse(a, sse_response[0 .. sse_response.len - 1]));
    const merged_text = try std.mem.replaceOwned(u8, a, sse_response, "\"a\"}\n\nid", "\"a\"}\nid");
    const merged = try sse.parse(a, merged_text);
    try std.testing.expectError(error.FrameCarriesSeveralLines, sse.journal(a, merged));
    try std.testing.expect(!std.mem.eql(u8, try sse.render(a, good), try sse.render(a, merged)));
    const bare_text = try std.mem.replaceOwned(u8, a, sse_response, "\n\n", "\n");
    try std.testing.expectError(error.UnterminatedFrame, sse.parse(a, bare_text[0 .. bare_text.len - 1]));
}
