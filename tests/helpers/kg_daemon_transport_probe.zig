const std = @import("std");
const cc = @import("cc");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const url = args.next() orelse return error.MissingUrl;
    const api_key = args.next() orelse return error.MissingApiKey;
    const build_id = args.next() orelse return error.MissingBuildId;
    const schema_digest = args.next() orelse return error.MissingSchemaDigest;
    const action = args.next() orelse return error.MissingAction;

    const timeout_ms: u64 = if (std.mem.eql(u8, action, "timeout")) 100 else 2_000;
    const effective_api_key = if (std.mem.eql(u8, action, "unauthorized-write")) "wrong-test-key" else api_key;
    var transport = try cc.kg_transport.WebTransport.init(init.gpa, .{
        .io = init.io,
        .url = url,
        .api_key = effective_api_key,
        .expected_build_id = build_id,
        .expected_schema_digest = schema_digest,
        .timeout_ms = timeout_ms,
    });
    defer transport.deinit();

    const stdout_file = std.Io.File.stdout();
    var buffer: [4096]u8 = undefined;
    var writer = stdout_file.writer(init.io, &buffer);
    const out = &writer.interface;
    if (std.mem.eql(u8, action, "write")) {
        const response = try transport.run("add-node", &.{ "observation", "shared actor" }, true);
        defer response.deinit(init.gpa);
        try out.print("generation={d}\nreplayed={}\ncommit={s}\n", .{
            response.generation,
            response.replayed,
            @tagName(response.commit_state),
        });
    } else if (std.mem.eql(u8, action, "query")) {
        const response = try transport.run("query", &.{"MATCH (n) RETURN n LIMIT 1"}, false);
        defer response.deinit(init.gpa);
        try out.print("generation={d}\ncommit={s}\n", .{ response.generation, @tagName(response.commit_state) });
    } else if (std.mem.eql(u8, action, "markdown")) {
        const response = try transport.importMarkdown("# Uploaded\n\nprivate bytes\n", 42, "memory.md");
        defer response.deinit(init.gpa);
        try std.testing.expect(response.exit_code == 0);
        try std.testing.expect(std.mem.indexOf(u8, response.stdout, "document=42") != null);
        try out.writeAll("markdown_upload=observed\n");
    } else if (std.mem.eql(u8, action, "backpressure")) {
        try std.testing.expectError(
            cc.kg_transport.Error.Backpressure,
            transport.run("stats", &.{}, false),
        );
        try out.writeAll("backpressure=observed\n");
    } else if (std.mem.eql(u8, action, "backpressure-write")) {
        try std.testing.expectError(
            cc.kg_transport.Error.Backpressure,
            transport.run("add-node", &.{ "observation", "queue-full" }, true),
        );
        try std.testing.expect(transport.ambiguousRequestId() == null);
        try out.writeAll("backpressure_write_no_commit=observed\n");
    } else if (std.mem.eql(u8, action, "unauthorized-write")) {
        try std.testing.expectError(
            cc.kg_transport.Error.AuthenticationFailed,
            transport.run("add-node", &.{ "observation", "unauthorized" }, true),
        );
        try std.testing.expect(transport.ambiguousRequestId() == null);
        try out.writeAll("unauthorized_write_no_commit=observed\n");
    } else if (std.mem.eql(u8, action, "conflict")) {
        try std.testing.expectError(
            cc.kg_transport.Error.RequestIdConflict,
            transport.run("stats", &.{}, false),
        );
        try out.writeAll("conflict=observed\n");
    } else if (std.mem.eql(u8, action, "unavailable-read")) {
        try std.testing.expectError(
            cc.kg_transport.Error.DaemonUnavailable,
            transport.run("stats", &.{}, false),
        );
        try out.writeAll("unavailable_read=observed\n");
    } else if (std.mem.eql(u8, action, "unavailable-write")) {
        try std.testing.expectError(
            cc.kg_transport.Error.AmbiguousCommit,
            transport.run("add-node", &.{ "observation", "unavailable" }, true),
        );
        const request_id = transport.ambiguousRequestId() orelse return error.MissingAmbiguousRequestId;
        try out.print("ambiguous_write=observed\nrequest_id={s}\n", .{request_id});
    } else if (std.mem.eql(u8, action, "timeout")) {
        try std.testing.expectError(
            cc.kg_transport.Error.RequestTimedOut,
            transport.run("slow", &.{}, false),
        );
        try out.writeAll("wall_clock_timeout=observed\n");
    } else {
        return error.UnknownAction;
    }
    try out.flush();
}
