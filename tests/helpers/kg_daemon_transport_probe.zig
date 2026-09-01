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

    if (std.mem.eql(u8, action, "client-config") or std.mem.eql(u8, action, "client-config-degraded")) {
        var client = try cc.kg_client.KgClient.init(init.gpa, .{
            .home = "/unused-because-config-is-explicit",
            .domain = "daemon-config-probe",
            .io = init.io,
        });
        defer client.deinit();
        client.ensureReady();
        if (std.mem.eql(u8, action, "client-config")) {
            try std.testing.expect(client.ready);
            const stdout_file = std.Io.File.stdout();
            var config_buffer: [512]u8 = undefined;
            var config_writer = stdout_file.writer(init.io, &config_buffer);
            try config_writer.interface.writeAll("metacodes_local_daemon_config=ready\n");
            try config_writer.interface.flush();
        } else {
            try std.testing.expect(!client.ready);
            const stdout_file = std.Io.File.stdout();
            var config_buffer: [512]u8 = undefined;
            var config_writer = stdout_file.writer(init.io, &config_buffer);
            try config_writer.interface.writeAll("unsafe_local_daemon_config=degraded\n");
            try config_writer.interface.flush();
        }
        return;
    }

    // issue #30:不拥有 Store 的 client,克隆到工作线程后也不许凭空拥有一个。
    // 这条断言的执行形态很关键——原先规则只 grep 三个函数的字符串标记,而 bug 住在
    // 第四个函数(cloneForThread)里,于是"禁止共享 store 回落 CLI"这条规则一直是绿的。
    if (std.mem.eql(u8, action, "unconfigured-clone-no-store")) {
        var parent = try cc.kg_client.KgClient.init(init.gpa, .{
            .home = "/unused-because-unconfigured",
            .domain = "unconfigured-clone-probe",
            .io = init.io,
        });
        defer parent.deinit();
        try std.testing.expect(parent.transport == .unconfigured);
        try std.testing.expect(parent.store.fsPath() == null);

        var child = try parent.cloneForThread(init.gpa, "/unused-because-unconfigured");
        defer child.deinit();
        // 既不许被提升成 CLI-exclusive,也不许解析出 bin,更不许拥有 Store。
        try std.testing.expect(child.transport == .unconfigured);
        try std.testing.expect(child.bin_path == null);
        try std.testing.expect(child.store.fsPath() == null);
        // ensureReady 必须 degraded 而不是去建库。调用方据此走降级路径。
        child.ensureReady();
        try std.testing.expect(!child.ready);

        const stdout_file = std.Io.File.stdout();
        var clone_buffer: [256]u8 = undefined;
        var clone_writer = stdout_file.writer(init.io, &clone_buffer);
        try clone_writer.interface.writeAll("unconfigured_clone_owns_no_store=pass\n");
        try clone_writer.interface.flush();
        return;
    }

    const timeout_ms: u64 = if (std.mem.eql(u8, action, "timeout")) 100 else 2_000;
    const effective_api_key = if (std.mem.eql(u8, action, "unauthorized-write")) "wrong-test-key" else api_key;
    const effective_schema_digest = if (std.mem.eql(u8, action, "schema-drift-across-clone")) "" else schema_digest;
    var transport = try cc.kg_transport.WebTransport.init(init.gpa, .{
        .io = init.io,
        .url = url,
        .api_key = effective_api_key,
        .expected_build_id = build_id,
        .expected_schema_digest = effective_schema_digest,
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
    } else if (std.mem.eql(u8, action, "ambiguous-blocks-writes")) {
        // Clone before the uncertain attempt: subagent/teammate sessions must
        // share the process-local write fence rather than receiving a fresh
        // ambiguity latch that can bypass the lead's recovery stop.
        var cloned = try transport.cloneForSession(init.gpa);
        defer cloned.deinit();
        try std.testing.expectError(
            cc.kg_transport.Error.AmbiguousCommit,
            transport.run("add-node", &.{ "observation", "one-attempt" }, true),
        );
        const request_id = transport.ambiguousRequestId() orelse return error.MissingAmbiguousRequestId;
        // Reads through another session remain available for application-level
        // re-observation, while writes through either handle are fenced.
        const observed = try cloned.run("store-info", &.{}, false);
        observed.deinit(init.gpa);
        try std.testing.expectError(
            cc.kg_transport.Error.AmbiguousCommit,
            cloned.run("add-node", &.{ "observation", "clone-must-not-send" }, true),
        );
        try std.testing.expectError(
            cc.kg_transport.Error.AmbiguousCommit,
            transport.run("add-node", &.{ "observation", "lead-must-not-send" }, true),
        );
        try std.testing.expectEqualStrings(request_id, transport.ambiguousRequestId().?);
        try std.testing.expectEqualStrings(request_id, cloned.ambiguousRequestId().?);
        try out.print("ambiguous_write_blocked=observed\nrequest_id={s}\n", .{request_id});
    } else if (std.mem.eql(u8, action, "schema-drift-across-clone")) {
        var cloned = try transport.cloneForSession(init.gpa);
        defer cloned.deinit();
        const pinned = try transport.run("stats", &.{}, false);
        pinned.deinit(init.gpa);
        try std.testing.expectError(
            cc.kg_transport.Error.IncompatibleDaemon,
            cloned.run("schema-drift", &.{}, false),
        );
        try out.writeAll("shared_schema_pin=observed\n");
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
    } else if (std.mem.eql(u8, action, "unavailable-write") or
        std.mem.eql(u8, action, "service-unavailable-write"))
    {
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
