//! L2 evidence: a request that carries a credential never follows a redirect.
//!
//! std's HTTP client re-sends `extra_headers` on every hop to whatever host
//! `Location` names, and turns a POST answered 301/302/303 into a body-less
//! GET; in Zig 0.16 the `privileged_headers` it would strip are never sent at
//! all. Before this, the Anthropic Messages client, the `/v1/models` probe,
//! the account key list, the KG and sealed-skill transports and MCP over HTTP
//! all followed up to three hops with their key attached.
//!
//! Every case answers the first request with a redirect to a second server on
//! another host name (`localhost` is not `127.0.0.1` to std) and checks that
//! the second server never hears from the client.
//!
//! The "L2 echoed credential" cases are the same concern on the way back: a
//! server that repeats the key in an error answer does not get it into the log
//! or onto the screen.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const pfs = @import("platform").fs;
const ppaths = @import("platform").paths;

const SECRET = "redirect-test-secret-7f3a";

const REDIRECTS = [_][]const u8{
    "HTTP/1.1 301 Moved Permanently",
    "HTTP/1.1 302 Found",
    "HTTP/1.1 303 See Other",
    "HTTP/1.1 307 Temporary Redirect",
    "HTTP/1.1 308 Permanent Redirect",
};

/// A server that answers every request with `status_line` and a `Location`
/// on another host, and the server it points at.
const Hop = struct {
    target: *harness.MockServer,
    redirect: *harness.MockServer,
    /// The redirecting server's `/v1/messages` URL.
    url: []const u8,

    fn start(arena: std.mem.Allocator, status_line: []const u8) !Hop {
        const target = try harness.MockServer.start("{\"data\":[]}", 0);
        errdefer target.stop();
        const location = try std.fmt.allocPrint(arena, "location: http://localhost:{d}/elsewhere\r\n", .{target.port});
        const redirect = try harness.MockServer.startRepeatingStatus("", status_line, location);
        return .{ .target = target, .redirect = redirect, .url = try redirect.urlOwned(arena) };
    }

    fn stop(self: *Hop) void {
        self.redirect.stop();
        self.target.stop();
    }

    /// The key reached the server it was sent to, and nothing reached the
    /// one the redirect named.
    fn expectHeld(self: *Hop) !void {
        const first = self.redirect.lastRequest() orelse return error.NoRequestCaptured;
        try std.testing.expect(std.mem.indexOf(u8, first.raw, SECRET) != null);
        try std.testing.expectEqual(@as(usize, 0), self.target.requestCount());
    }
};

/// A stream that opened means the redirect was followed; report it as such
/// instead of letting `expectError` print a half-read response.
fn expectRefused(result: anyerror!cc.api_provider.StreamHandle) !void {
    if (result) |handle| {
        var opened = handle;
        opened.deinit();
        return error.RedirectFollowed;
    } else |err| try std.testing.expectEqual(error.RequestFailed, err);
}

fn takeLastError(buffer: *[cc.api_last_error.SUMMARY_BUF_LEN]u8) []const u8 {
    return cc.api_last_error.take(buffer) orelse "";
}

const MESSAGES = [_]cc.types_mod.ApiMessage{
    .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
};

test "L2 redirect: the Messages client reports a redirect instead of taking its key there" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var io_runtime = @import("platform").signal.threadedIo(arena, .{});
    defer io_runtime.deinit();

    for (REDIRECTS) |status_line| {
        var hop = try Hop.start(arena, status_line);
        defer hop.stop();
        var client = cc.client_mod.Client.initWithBaseUrl(std.testing.allocator, io_runtime.io(), SECRET, "claude-sonnet-4-20250514", hop.url);
        defer client.deinit();
        var summary: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;
        _ = takeLastError(&summary);

        if (client.sendMessageStream(&MESSAGES, null, null)) |response| {
            var followed = response;
            followed.deinit();
            return error.RedirectFollowed;
        } else |err| try std.testing.expectEqual(error.HttpError, err);
        try hop.expectHeld();
        // The user is told where it pointed: that URL is the fix.
        const said = takeLastError(&summary);
        try std.testing.expect(std.mem.indexOf(u8, said, "端点重定向") != null);
        try std.testing.expect(std.mem.indexOf(u8, said, "/elsewhere") != null);
    }
}

test "L2 redirect: the /v1/models probe does not follow a redirect with its key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var io_runtime = @import("platform").signal.threadedIo(arena, .{});
    defer io_runtime.deinit();

    var hop = try Hop.start(arena, "HTTP/1.1 302 Found");
    defer hop.stop();
    var http_client = std.http.Client{ .allocator = std.testing.allocator, .io = io_runtime.io() };
    defer http_client.deinit();
    var status: u16 = 0;
    try std.testing.expectError(error.HttpError, cc.client_mod.getModelsList(
        std.testing.allocator,
        &http_client,
        hop.url,
        .{ .header = .{ .name = "x-api-key", .value = SECRET } },
        &status,
    ));
    try std.testing.expectEqual(@as(u16, 302), status);
    try hop.expectHeld();
}

test "L2 redirect: the OpenAI and Gemini clients name the redirect and keep their keys" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var io_runtime = @import("platform").signal.threadedIo(arena, .{});
    defer io_runtime.deinit();
    var summary: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;

    {
        var hop = try Hop.start(arena, "HTTP/1.1 302 Found");
        defer hop.stop();
        var client = cc.api_openai.OpenAIClient.init(std.testing.allocator, io_runtime.io(), SECRET, "gpt-4o", hop.url);
        defer client.deinit();
        _ = takeLastError(&summary);
        try expectRefused(client.provider().sendStream(&MESSAGES, null, null, null, null, null, ""));
        try hop.expectHeld();
        try std.testing.expect(std.mem.indexOf(u8, takeLastError(&summary), "端点重定向") != null);
    }
    {
        var hop = try Hop.start(arena, "HTTP/1.1 307 Temporary Redirect");
        defer hop.stop();
        const base = hop.url[0 .. hop.url.len - "/v1/messages".len];
        var client = cc.api_gemini.GeminiClient.init(std.testing.allocator, io_runtime.io(), SECRET, "gemini-2.5-flash", base);
        defer client.deinit();
        _ = takeLastError(&summary);
        try expectRefused(client.provider().sendStream(&MESSAGES, null, null, null, null, null, ""));
        try hop.expectHeld();
        try std.testing.expect(std.mem.indexOf(u8, takeLastError(&summary), "端点重定向") != null);
    }
}

const Provider = enum { messages, openai, gemini };

/// Sends one request with `SECRET` to the redirecting `server` and expects it
/// refused.
fn sendRefused(provider: Provider, io: std.Io, server: *harness.MockServer, arena: std.mem.Allocator) !void {
    const url = try server.urlOwned(arena);
    switch (provider) {
        .messages => {
            var client = cc.client_mod.Client.initWithBaseUrl(std.testing.allocator, io, SECRET, "claude-sonnet-4-20250514", url);
            defer client.deinit();
            if (client.sendMessageStream(&MESSAGES, null, null)) |response| {
                var followed = response;
                followed.deinit();
                return error.RedirectFollowed;
            } else |err| try std.testing.expectEqual(error.HttpError, err);
        },
        .openai => {
            var client = cc.api_openai.OpenAIClient.init(std.testing.allocator, io, SECRET, "gpt-4o", url);
            defer client.deinit();
            try expectRefused(client.provider().sendStream(&MESSAGES, null, null, null, null, null, ""));
        },
        .gemini => {
            const base = url[0 .. url.len - "/v1/messages".len];
            var client = cc.api_gemini.GeminiClient.init(std.testing.allocator, io, SECRET, "gemini-2.5-flash", base);
            defer client.deinit();
            try expectRefused(client.provider().sendStream(&MESSAGES, null, null, null, null, null, ""));
        },
    }
}

/// Reads a stream that must end in a failure, as the agent loop would.
fn drainToFailure(provider: anytype) !void {
    var handle = try provider.sendStream(&MESSAGES, null, null, null, null, null, "");
    defer handle.deinit();
    while (true) {
        const event = handle.next() catch return;
        if (event == null) return error.StreamFailureMissed;
    }
}

/// Sends one request with `SECRET` to `server`, outside any Run, and reads the
/// accepted stream to the failure it declares.
fn sendDrained(provider: Provider, io: std.Io, server: *harness.MockServer, arena: std.mem.Allocator) !void {
    const url = try server.urlOwned(arena);
    switch (provider) {
        .messages => {
            var client = cc.client_mod.Client.initWithBaseUrl(std.testing.allocator, io, SECRET, "claude-sonnet-4-20250514", url);
            defer client.deinit();
            try drainToFailure(client.provider());
        },
        .openai => {
            var client = cc.api_openai.OpenAIClient.init(std.testing.allocator, io, SECRET, "gpt-4o", url);
            defer client.deinit();
            try drainToFailure(client.provider());
        },
        .gemini => {
            var client = cc.api_gemini.GeminiClient.init(std.testing.allocator, io, SECRET, "gemini-2.5-flash", url[0 .. url.len - "/v1/messages".len]);
            defer client.deinit();
            try drainToFailure(client.provider());
        },
    }
}

/// What one refused request left in the log file and in the TUI's error text.
const Reported = struct {
    log_buf: [8192]u8 = undefined,
    log_len: usize = 0,
    summary_buf: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined,
    summary_len: usize = 0,

    fn logged(self: *const Reported) []const u8 {
        return self.log_buf[0..self.log_len];
    }

    fn summary(self: *const Reported) []const u8 {
        return self.summary_buf[0..self.summary_len];
    }

    fn collect(self: *Reported, provider: Provider, status_line: []const u8, headers: []const u8, body: []const u8) !void {
        return self.collectFrom(sendRefused, provider, status_line, headers, body);
    }

    fn collectFrom(self: *Reported, comptime send: anytype, provider: Provider, status_line: []const u8, headers: []const u8, body: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        var io_runtime = @import("platform").signal.threadedIo(arena_state.allocator(), .{});
        defer io_runtime.deinit();

        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buf, "{s}/cc-zig-redirect-credential-test.log", .{ppaths.tempDir()});
        const fd = pfs.open(path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
        try std.testing.expect(fd >= 0);
        defer pfs.close(fd);
        defer pfs.unlinkPath(path.ptr) catch {};
        const previous_log_state = cc.util_log.setLogFileFdForTest(fd);
        defer cc.util_log.restoreForTest(previous_log_state);
        // A failing run must not print the secret to the test output either.
        cc.util_log.setStderrEnabled(false);
        // Stream error frames are logged at warn.
        cc.util_log.setLevel(.warn);

        var server = try harness.MockServer.startRepeatingStatus(body, status_line, headers);
        defer server.stop();
        _ = cc.api_last_error.take(&self.summary_buf);
        try send(provider, io_runtime.io(), server, arena_state.allocator());
        // The request did carry the secret: there was something to echo.
        const first = server.lastRequest() orelse return error.NoRequestCaptured;
        try std.testing.expect(std.mem.indexOf(u8, first.raw, SECRET) != null);

        self.summary_len = takeLastError(&self.summary_buf).len;
        _ = pfs.lseek(fd, 0, .set);
        const n = pfs.read(fd, &self.log_buf);
        try std.testing.expect(n > 0);
        self.log_len = @intCast(n);
    }
};

fn expectAbsent(where: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, where, needle) == null) return;
    std.debug.print("found {s} in: {s}\n", .{ needle, where });
    return error.SecretLeaked;
}

fn expectPresent(where: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, where, needle) != null) return;
    std.debug.print("missing {s} in: {s}\n", .{ needle, where });
    return error.ReportIncomplete;
}

test "L2 redirect: a Location that echoes the credential reaches neither the log nor the error text" {
    // SECRET has no known prefix, and neither a path segment nor the query name
    // `tenant_ref` is a pattern the masking knows: only the credential itself
    // can catch it. A 3xx body usually repeats the URL, so this one does too.
    const location = "http://gateway.example/tenant/" ++ SECRET ++ "/v1?tenant_ref=" ++ SECRET ++ "&x=1";
    const masked = "http://gateway.example/tenant/[REDACTED]/v1?tenant_ref=[REDACTED]&x=1";
    for (std.enums.values(Provider)) |provider| {
        var reported: Reported = .{};
        try reported.collect(provider, "HTTP/1.1 302 Found", "location: " ++ location ++ "\r\n", "<a href=\"" ++ location ++ "\">Found</a>");
        try expectAbsent(reported.logged(), SECRET);
        try expectAbsent(reported.summary(), SECRET);
        // The URL is still there to act on.
        try expectPresent(reported.logged(), "redirect to " ++ masked ++ " not followed");
        try expectPresent(reported.summary(), masked);
    }
}

test "L2 redirect: a Location cut at the bound is quoted in neither the log nor the error text" {
    // Placed across the bound the clients keep, the credential arrives cut, and
    // a cut credential no longer matches.
    const lead = "http://gateway.example/";
    const padding = "p" ** (256 - lead.len - 10);
    comptime std.debug.assert(lead.len + padding.len + 1 + 9 == 256);
    const location = lead ++ padding ++ "/" ++ SECRET ++ "/x";
    for (std.enums.values(Provider)) |provider| {
        var reported: Reported = .{};
        try reported.collect(provider, "HTTP/1.1 302 Found", "location: " ++ location ++ "\r\n", "");
        const fragment = SECRET[0..9];
        try expectAbsent(reported.logged(), fragment);
        try expectAbsent(reported.summary(), fragment);
        try expectAbsent(reported.logged(), lead);
        try expectAbsent(reported.summary(), lead);
        try expectPresent(reported.logged(), "too long to report");
        try expectPresent(reported.summary(), "地址过长");
    }
}

test "L2 echoed credential: an error frame reaches neither the log nor the error text" {
    // No Run is active here, so the structured detail's Capture cannot be what
    // knows the credential: the stream itself has to.
    const said = "bad tenant " ++ SECRET ++ " rejected";
    const frames = [_]struct { Provider, []const u8 }{
        .{ .messages, "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"" ++ said ++ "\"}}\n\n" },
        .{ .openai, "data: {\"error\":{\"message\":\"" ++ said ++ "\",\"code\":401}}\n\n" },
        .{ .gemini, "data: {\"error\":{\"code\":401,\"message\":\"" ++ said ++ "\",\"status\":\"UNAUTHENTICATED\"}}\n\n" },
    };
    for (frames) |frame| {
        var reported: Reported = .{};
        try reported.collectFrom(sendDrained, frame[0], "HTTP/1.1 200 OK", "", frame[1]);
        try expectAbsent(reported.logged(), SECRET);
        try expectAbsent(reported.summary(), SECRET);
        // The rest of what the server said is still there to act on.
        try expectPresent(reported.logged(), "bad tenant [REDACTED] rejected");
        try expectPresent(reported.summary(), "API 错误帧");
        try expectPresent(reported.summary(), "bad tenant [REDACTED] rejected");
    }
}

test "L2 echoed credential: an HTTP error body reaches neither the log nor the error text" {
    const body = "{\"error\":{\"message\":\"bad tenant " ++ SECRET ++ " rejected\"}}";
    for (std.enums.values(Provider)) |provider| {
        var reported: Reported = .{};
        try reported.collect(provider, "HTTP/1.1 400 Bad Request", "", body);
        try expectAbsent(reported.logged(), SECRET);
        try expectAbsent(reported.summary(), SECRET);
        try expectPresent(reported.logged(), "bad tenant [REDACTED] rejected");
        try expectPresent(reported.summary(), "HTTP 400: ");
        try expectPresent(reported.summary(), "bad tenant [REDACTED] rejected");
    }
}

test "L2 echoed credential: a body cut at the read bound does not leave part of it in the log" {
    // Across the bound of the buffer each client reads an error body into, the
    // credential arrives cut, and a cut credential no longer matches.
    const fragment = SECRET[0..9];
    const bounds = [_]struct { Provider, []const u8 }{
        .{ .messages, "x" ** (2048 - fragment.len) ++ SECRET },
        .{ .openai, "x" ** (4096 - fragment.len) ++ SECRET },
        .{ .gemini, "x" ** (4096 - fragment.len) ++ SECRET },
    };
    for (bounds) |bound| {
        var reported: Reported = .{};
        try reported.collect(bound[0], "HTTP/1.1 400 Bad Request", "", bound[1]);
        try expectPresent(reported.logged(), "xxxx");
        try expectAbsent(reported.logged(), fragment);
        try expectAbsent(reported.summary(), fragment);
    }
}

test "L2 redirect: the account key list does not follow a redirect with its bearer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var io_runtime = @import("platform").signal.threadedIo(arena, .{});
    defer io_runtime.deinit();

    var hop = try Hop.start(arena, "HTTP/1.1 301 Moved Permanently");
    defer hop.stop();
    var catalog = cc.api_api_keys.Catalog.init(std.testing.allocator);
    defer catalog.deinit();
    try std.testing.expectError(error.HttpError, cc.api_api_keys.fetchInto(&catalog, std.testing.allocator, io_runtime.io(), hop.url, SECRET));
    try hop.expectHeld();
}

test "L2 redirect: a token endpoint that redirects is a failed refresh, not a grant answered elsewhere" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var io_runtime = @import("platform").signal.threadedIo(arena, .{});
    defer io_runtime.deinit();

    // 302 and 303 used to turn the POST into a GET to the other host, whose
    // answer was then parsed as the token response.
    for ([_][]const u8{ "HTTP/1.1 302 Found", "HTTP/1.1 303 See Other" }) |status_line| {
        var hop = try Hop.start(arena, status_line);
        defer hop.stop();
        var exchange = cc.api_oauth_exchange.HttpExchange{
            .allocator = std.testing.allocator,
            .io = io_runtime.io(),
            .endpoint = .{ .token_url = hop.url, .client_id = "metacodes-test" },
        };
        const run = exchange.exchange();
        var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer scratch.deinit();
        try std.testing.expect(std.meta.isError(run.run(run.ctx, cc.provider_ids.Slug.lit("openai"), SECRET, scratch.allocator())));
        try hop.expectHeld();
    }
}

test "L2 redirect: MCP over HTTP reports a redirecting server URL and keeps its headers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var io_runtime = @import("platform").signal.threadedIo(arena, .{});
    defer io_runtime.deinit();

    for ([_][]const u8{ "HTTP/1.1 302 Found", "HTTP/1.1 308 Permanent Redirect" }) |status_line| {
        var hop = try Hop.start(arena, status_line);
        defer hop.stop();
        const transport = try cc.mcp_transport_http.HttpTransport.create(std.testing.allocator, io_runtime.io(), hop.url, &.{
            .{ .name = "authorization", .value = "Bearer " ++ SECRET },
        });
        defer transport.close();
        const initialize = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}";
        try std.testing.expectError(error.McpRedirected, transport.send(initialize, .{ .method = "initialize" }));
        try hop.expectHeld();
    }
}

// The source guard: every std.http request in `src/` names its redirect
// policy. The default follows three hops with every header attached, so a
// new call site that forgets the option silently reopens this hole.
test "L2 redirect: every HTTP request in src names its redirect policy" {
    const allocator = std.testing.allocator;
    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |path| allocator.free(path);
        files.deinit(allocator);
    }
    try collectZigFiles(allocator, "src", &files);
    try std.testing.expect(files.items.len > 100);

    var sites: usize = 0;
    var missing: std.ArrayList(u8) = .empty;
    defer missing.deinit(allocator);
    for (files.items) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8 * 1024 * 1024));
        defer allocator.free(text);
        var from: usize = 0;
        while (requestCall(text, from)) |call| {
            from = call.end;
            sites += 1;
            if (std.mem.indexOf(u8, text[call.options_start..call.end], ".redirect_behavior") == null) {
                const line = 1 + std.mem.count(u8, text[0..call.options_start], "\n");
                try missing.print(allocator, "{s}:{d}\n", .{ path, line });
            }
        }
    }
    if (missing.items.len > 0) {
        std.debug.print("HTTP requests without an explicit redirect_behavior:\n{s}", .{missing.items});
        return error.RedirectPolicyMissing;
    }
    // Moves with the inventory: fewer means the scan stopped seeing them.
    try std.testing.expect(sites >= 17);
}

const RequestCall = struct { options_start: usize, end: usize };

/// The next `<client>.request(.METHOD, <uri>, .{ ... })` from `from`: where
/// its options literal starts and ends.
fn requestCall(text: []const u8, from: usize) ?RequestCall {
    var at = from;
    while (std.mem.indexOfPos(u8, text, at, ".request(.")) |hit| {
        at = hit + ".request(.".len;
        var method_end = at;
        while (method_end < text.len and std.ascii.isUpper(text[method_end])) method_end += 1;
        if (method_end == at or method_end >= text.len or text[method_end] != ',') continue;
        // The options are the call's last argument, a struct literal.
        const options = std.mem.indexOfPos(u8, text, method_end, ".{") orelse return null;
        var depth: usize = 0;
        var i = options + 1;
        while (i < text.len) : (i += 1) switch (text[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return .{ .options_start = options, .end = i + 1 };
            },
            else => {},
        };
        return null;
    }
    return null;
}

fn collectZigFiles(allocator: std.mem.Allocator, root: []const u8, out: *std.ArrayList([]u8)) !void {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        try out.append(allocator, try std.fs.path.join(allocator, &.{ root, entry.path }));
    }
}

test "L2 redirect: the source guard finds a request whose options omit the policy" {
    const sample =
        \\    var req = client.request(.GET, uri, .{
        \\        .extra_headers = &.{.{ .name = "a", .value = "b" }},
        \\    }) catch return;
        \\    var ok = client.request(.POST, uri, .{ .redirect_behavior = .unhandled, .extra_headers = &.{} });
        \\    // self.request(.{}) is not an HTTP call
    ;
    const first = requestCall(sample, 0).?;
    try std.testing.expect(std.mem.indexOf(u8, sample[first.options_start..first.end], ".redirect_behavior") == null);
    const second = requestCall(sample, first.end).?;
    try std.testing.expect(std.mem.indexOf(u8, sample[second.options_start..second.end], ".redirect_behavior") != null);
    try std.testing.expect(requestCall(sample, second.end) == null);
}
