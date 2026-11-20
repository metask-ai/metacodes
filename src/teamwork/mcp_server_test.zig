//! Real runtime consumer tests: protocol input -> durable run / git workspace.
//! Scripted seats only replace harness calls; review and merge are real.
const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const util_fs = @import("../util/fs.zig");
const tools_common = @import("../tools/common.zig");
const util_time = @import("../util/time.zig");
const swarm_team = @import("../swarm/team.zig");
const runtime = @import("runtime.zig");
const config = @import("config.zig");
const types = @import("types.zig");
const run_dir = @import("run_dir.zig");
const common = @import("drivers/common.zig");
const audit = @import("audit.zig");
const mcp = @import("mcp_server.zig");
const testing = std.testing;
const gpa = testing.allocator;
const PathBuf = [std.fs.max_path_bytes]u8;
const request = "Add feature.txt containing feature.\n";
const check = "test -f feature.txt";
const handoff = "## Observation\no\n## Reasoning\nr\n## Caveats\nc\n## Conclusion\nk\n## Verification\nv\n";
const review = "{\"verdict\":\"approve\",\"evidence\":[{\"command\":\"" ++ check ++ "\",\"exit_code\":0,\"output_digest\":\"" ++ "a" ** 64 ++ "\",\"output_excerpt\":\"\"}],\"issues\":{\"opened\":[],\"closed\":[],\"still_open\":[]}}";
const initialize = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"fixture\",\"version\":\"1\"}}}";
const initialized = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}";
const implement = "{\"jsonrpc\":\"2.0\",\"id\":\"impl\",\"method\":\"tools/call\",\"params\":{\"name\":\"teamwork_dispatch\",\"arguments\":{\"role\":\"implementer\",\"instructions\":\"Keep the feature small.\"}}}";
const review_call = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"teamwork_dispatch\",\"arguments\":{\"role\":\"reviewer\"}}}";
const complete = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"teamwork_request_completion\"}}";
const status_call = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"teamwork_status\"}}";
const cancel = "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"teamwork_cancel\"}}";

fn writeFile(dir: []const u8, rel: []const u8, text: []const u8) !void {
    var buf: PathBuf = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, rel });
    const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (fd < 0) return error.OpenFailed;
    defer pfs.close(fd);
    if (!pfs.writeAll(fd, text)) return error.WriteFailed;
}

fn readFile(dir: []const u8, rel: []const u8) ![]u8 {
    var buf: PathBuf = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, rel });
    return swarm_team.readFileAlloc(gpa, path) orelse error.ReadFailed;
}

fn expectFile(dir: []const u8, rel: []const u8, want: []const u8) !void {
    const got = try readFile(dir, rel);
    defer gpa.free(got);
    try testing.expectEqualStrings(want, got);
}

fn sh(cwd: []const u8, script: [:0]const u8) ![]u8 {
    const argv = [_]?[*:0]const u8{ "/bin/sh", "-c", script, null };
    const out = try tools_common.spawnCaptureWithStderrTimed(&argv, gpa, null, 60_000, null, 1 << 20, cwd);
    defer gpa.free(out.stderr);
    errdefer gpa.free(out.stdout);
    try testing.expectEqual(@as(u8, 0), out.exit_code);
    return out.stdout;
}

const Fixture = struct {
    root: run_dir.test_support.TestRoot,
    arena: std.heap.ArenaAllocator,
    repo: []const u8,
    state: []const u8,

    fn init(self: *Fixture) !void {
        if (builtin.os.tag == .windows) return error.SkipZigTest;
        self.* = .{ .root = run_dir.test_support.TestRoot.init("cc-zig-teamwork-mcp"), .arena = .init(gpa), .repo = undefined, .state = undefined };
        errdefer self.deinit();
        const arena = self.arena.allocator();
        self.repo = try std.fmt.allocPrint(arena, "{s}/repo", .{self.root.slice()});
        self.state = try std.fmt.allocPrint(arena, "{s}/state", .{self.root.slice()});
        try util_fs.mkdirParents(self.repo);
        try util_fs.mkdirParents(self.state);
        try writeFile(self.repo, "README.md", "user workspace\n");
        const argv = [_]?[*:0]const u8{ "/bin/sh", "-c", "git init -q && git add -A && git -c user.name=t -c user.email=t@example.invalid -c commit.gpgSign=false commit -qm init", null };
        const out = try tools_common.spawnCaptureWithStderrTimed(&argv, gpa, null, 60_000, null, 1 << 20, self.repo);
        defer gpa.free(out.stdout);
        defer gpa.free(out.stderr);
        try testing.expectEqual(@as(u8, 0), out.exit_code);
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.root.deinit();
    }

    fn start(self: *Fixture, seats: *Seats, auditor: audit.CompletionAuditor) !*runtime.Run {
        const cfg = (try config.validate(try config.parse(self.arena.allocator(), "{\"enabled\":true,\"budget_usd\":5,\"check_command\":\"" ++ check ++ "\"}", null), null)).enabled;
        return runtime.Run.start(gpa, .{ .preview = true, .seats = .{ .custom = .{ .ctx = seats, .driverFn = Seats.driver } }, .auditor = auditor }, .{ .text = request }, cfg, .{
            .workspace = self.repo,
            .state_root = self.state,
            .run_id = try types.RunId.parse("run-mcp-test"),
        });
    }
};

const Seats = struct {
    binding: common.Binding = undefined,
    packet: ?[]u8 = null,
    calls: u32 = 0,
    abort_during_call: bool = false,

    fn deinit(self: *Seats) void {
        if (self.packet) |p| gpa.free(p);
    }

    fn driver(ptr: *anyopaque, _: *const types.SeatSpec, binding: common.Binding) types.SeatDriver {
        const self: *Seats = @ptrCast(@alignCast(ptr));
        self.binding = binding;
        return .{ .ptr = self, .vtable = &.{ .run = run } };
    }

    fn run(ptr: *anyopaque, allocator: std.mem.Allocator, spec: *const types.SeatSpec, paths: types.SeatPaths, abort: *const types.AbortSignal) types.SeatDriver.Error!types.SeatOutcome {
        const self: *Seats = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        _ = common.charge(self.binding, .metacodes, self.calls, .{ .provider_estimate = 0.1 });
        if (self.abort_during_call) @constCast(abort).abort(.user_interrupt);
        if (abort.isAborted()) return .aborted;
        if (self.packet) |p| gpa.free(p);
        self.packet = swarm_team.readFileAlloc(gpa, paths.packet);
        if (spec.role == .implementer) {
            writeFile(paths.workspace, "feature.txt", "feature\n") catch return .{ .failed = .spawn_failed };
        } else {
            writeFile(common.seatDir(paths), "review.json", review) catch return .{ .failed = .spawn_failed };
        }
        writeFile(common.seatDir(paths), "handoff.md", handoff) catch return .{ .failed = .spawn_failed };
        return run_dir.collectHandoff(allocator, paths.handoff);
    }
};

fn call(server: *mcp.Server, line: []const u8) !std.json.Parsed(std.json.Value) {
    const bytes = (try server.handle(gpa, line)) orelse return error.MissingResponse;
    defer gpa.free(bytes);
    try testing.expect(std.mem.indexOfScalar(u8, bytes, '\n') == null);
    return std.json.parseFromSlice(std.json.Value, gpa, bytes, .{ .allocate = .alloc_always });
}

fn ready(server: *mcp.Server) !void {
    var response = try call(server, initialize);
    defer response.deinit();
    try testing.expectEqualStrings(mcp.protocol_version, response.value.object.get("result").?.object.get("protocolVersion").?.string);
    const capabilities = response.value.object.get("result").?.object.get("capabilities").?.object;
    try testing.expectEqual(@as(usize, 1), capabilities.count());
    try testing.expect(!capabilities.get("tools").?.object.get("listChanged").?.bool);
    try testing.expect((try server.handle(gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":[]}")) == null);
    try expectRpcError(server, status_call, -32000);
    try testing.expect((try server.handle(gpa, initialized)) == null);
}

test "teamwork preview L2: MCP cannot dispatch or complete after host opt-out; status and cancel remain usable" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var seats: Seats = .{};
    defer seats.deinit();
    var auditor: audit.UnavailableAuditor = .{};
    const run = try fx.start(&seats, auditor.auditor());
    defer run.destroy();
    run.deps.preview = false;
    var server = mcp.Server.init(gpa, run);
    try ready(&server);
    const saved = try readFile(run.dir.root, "run.json");
    defer gpa.free(saved);
    for ([_][]const u8{ implement, complete }) |request_line| {
        var response = try call(&server, request_line);
        defer response.deinit();
        try testing.expect(response.value.object.get("result").?.object.get("isError").?.bool);
        try testing.expectEqualStrings("PreviewDisabled", payload(response.value).object.get("error").?.string);
    }
    try expectRpcError(&server, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"teamwork_dispatch\",\"arguments\":{\"role\":\"implementer\",\"preview\":true}}}", -32602);
    try expectFile(run.dir.root, "run.json", saved);
    try testing.expectEqual(@as(u32, 0), seats.calls);
    try testing.expectEqual(@as(f64, 0), run.status().budget.spent_usd);
    var response = try call(&server, status_call);
    response.deinit();
    response = try call(&server, cancel);
    defer response.deinit();
    try testing.expectEqual(runtime.Phase.cancelled, run.status().state.phase());
    try testing.expectEqual(@as(u32, 0), seats.calls);
}

fn payload(response: std.json.Value) std.json.Value {
    return response.object.get("result").?.object.get("structuredContent").?;
}

fn expectPhase(response: std.json.Value, want: []const u8) !void {
    const body = payload(response);
    try testing.expectEqualStrings(want, body.object.get("snapshot").?.object.get("state").?.object.get("kind").?.string);
    const text = response.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;
    var text_json = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer text_json.deinit();
    try testing.expectEqualStrings(want, text_json.value.object.get("snapshot").?.object.get("state").?.object.get("kind").?.string);
}

fn expectRpcError(server: *mcp.Server, line: []const u8, code: i64) !void {
    var out = try call(server, line);
    defer out.deinit();
    try testing.expectEqual(code, out.value.object.get("error").?.object.get("code").?.integer);
}

test "teamwork MCP L2: consumer drives real review, charged ledger, audit and uncommitted merge" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var seats: Seats = .{};
    defer seats.deinit();
    var auditor: audit.StubAuditor = .{ .gpa = gpa, .script = &.{.pass} };
    defer auditor.deinit();
    const run = try fx.start(&seats, auditor.auditor());
    defer run.destroy();
    const head_before = try sh(fx.repo, "git rev-parse HEAD");
    defer gpa.free(head_before);
    var server = mcp.Server.init(gpa, run);
    try ready(&server);
    var status = try call(&server, status_call);
    defer status.deinit();
    try expectPhase(status.value, "approved");
    var implementation = try call(&server, implement);
    defer implementation.deinit();
    try expectPhase(implementation.value, "reviewing");
    try testing.expectEqualStrings("impl", implementation.value.object.get("id").?.string);
    try testing.expect(std.mem.indexOf(u8, seats.packet.?, "Keep the feature small.") != null);
    try expectFile(run.worktree, "feature.txt", "feature\n");
    try testing.expectError(error.ReadFailed, readFile(fx.repo, "feature.txt"));
    var reviewed = try call(&server, review_call);
    defer reviewed.deinit();
    try expectPhase(reviewed.value, "review_approved");
    const approved_tree = payload(reviewed.value).object.get("snapshot").?.object.get("state").?.object.get("detail").?.string;
    try testing.expect(approved_tree.len == 40 or approved_tree.len == 64);
    var completion = try call(&server, complete);
    defer completion.deinit();
    try expectPhase(completion.value, "done");
    try testing.expect(!completion.value.object.get("result").?.object.get("isError").?.bool);
    try testing.expectEqual(@as(u32, 1), auditor.calls);
    try testing.expectEqualStrings(request, auditor.last_request.?);
    try testing.expectApproxEqAbs(@as(f64, 0.2), run.status().budget.spent_usd, 0.000001);
    try testing.expectEqual(@as(usize, 2), run.status().budget.charges);
    try expectFile(fx.repo, "feature.txt", "feature\n");
    try expectFile(fx.repo, "README.md", "user workspace\n");
    const head_after = try sh(fx.repo, "git rev-parse HEAD");
    defer gpa.free(head_after);
    try testing.expectEqualStrings(head_before, head_after);
    const changed = try sh(fx.repo, "git status --porcelain");
    defer gpa.free(changed);
    try testing.expectEqualStrings("?? feature.txt\n", changed);
    try expectFile(run.dir.root, "ORIGINAL_REQUEST.md", request);
    const durable = try readFile(run.dir.root, "run.json");
    defer gpa.free(durable);
    var saved = try std.json.parseFromSlice(std.json.Value, gpa, durable, .{});
    defer saved.deinit();
    try testing.expectEqualStrings("done", saved.value.object.get("state").?.string);
}

test "teamwork MCP L2: no manager approval, config changes, path selection or notification dispatch" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var seats: Seats = .{};
    defer seats.deinit();
    var auditor: audit.UnavailableAuditor = .{};
    const run = try fx.start(&seats, auditor.auditor());
    defer run.destroy();
    var server = mcp.Server.init(gpa, run);
    try ready(&server);
    var denied = try call(&server, complete);
    defer denied.deinit();
    try testing.expect(denied.value.object.get("result").?.object.get("isError").?.bool);
    try testing.expectEqualStrings("NotApproved", payload(denied.value).object.get("error").?.string);
    const invalid = [_][]const u8{
        "{\"name\":\"teamwork_start\",\"arguments\":{\"approved\":true}}",
        "{\"name\":\"teamwork_request_completion\",\"arguments\":{\"approved\":true}}",
        "{\"name\":\"teamwork_dispatch\",\"arguments\":{\"role\":\"manager\"}}",
        "{\"name\":\"teamwork_dispatch\",\"arguments\":{\"role\":\"implementer\",\"budget_usd\":100}}",
        "{\"name\":\"teamwork_dispatch\",\"arguments\":{\"role\":\"reviewer\",\"check_command\":\"true\"}}",
        "{\"name\":\"teamwork_dispatch\",\"arguments\":{\"role\":\"implementer\",\"workspace\":\"/tmp/elsewhere\"}}",
        "{\"name\":\"teamwork_status\",\"arguments\":{\"config\":{}}}",
    };
    for (invalid) |params| {
        const line = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{s}}}", .{params});
        defer gpa.free(line);
        try expectRpcError(&server, line, -32602);
    }
    try testing.expect((try server.handle(gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"teamwork_dispatch\",\"arguments\":{\"role\":\"implementer\"}}}")) == null);
    try testing.expect((try server.handle(gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":[]}")) == null);
    try testing.expect((try server.handle(gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"teamwork_cancel\",\"arguments\":false}}")) == null);
    try testing.expectEqual(@as(u32, 0), seats.calls);
    try testing.expectEqual(runtime.Phase.approved, run.status().state.phase());
    try testing.expectEqual(@as(f64, 5), run.status().budget.cap_usd);
    try expectFile(run.dir.root, "ORIGINAL_REQUEST.md", request);
}

test "teamwork MCP L2: unavailable audit is a real failure and never merges" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var seats: Seats = .{};
    defer seats.deinit();
    var auditor: audit.UnavailableAuditor = .{};
    const run = try fx.start(&seats, auditor.auditor());
    defer run.destroy();
    var server = mcp.Server.init(gpa, run);
    try ready(&server);
    var a = try call(&server, implement);
    defer a.deinit();
    var b = try call(&server, review_call);
    defer b.deinit();
    try expectPhase(b.value, "review_approved");
    var c = try call(&server, complete);
    defer c.deinit();
    try expectPhase(c.value, "failed");
    try testing.expect(c.value.object.get("result").?.object.get("isError").?.bool);
    try testing.expectEqual(runtime.State{ .failed = .audit_unavailable }, run.state);
    try testing.expectError(error.ReadFailed, readFile(fx.repo, "feature.txt"));
    try expectFile(run.worktree, "feature.txt", "feature\n");
}

test "teamwork MCP L2: cancel between calls and shared abort during dispatch retain worktree" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var seats: Seats = .{};
    defer seats.deinit();
    var auditor: audit.UnavailableAuditor = .{};
    const run = try fx.start(&seats, auditor.auditor());
    defer run.destroy();
    var server = mcp.Server.init(gpa, run);
    try ready(&server);
    seats.abort_during_call = true;
    var a = try call(&server, implement);
    defer a.deinit();
    try expectPhase(a.value, "cancelled");
    var b = try call(&server, cancel);
    defer b.deinit();
    try expectPhase(b.value, "cancelled");
    try testing.expectEqual(@as(u32, 1), seats.calls);
    try testing.expect(run.status().worktree != null);
    var c = try call(&server, implement);
    defer c.deinit();
    try testing.expect(c.value.object.get("result").?.object.get("isError").?.bool);
    try testing.expectEqual(@as(u32, 1), seats.calls);
}

test "teamwork MCP L2: lifecycle, discovery, ids and malformed input recover without side effects" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var seats: Seats = .{};
    defer seats.deinit();
    var auditor: audit.UnavailableAuditor = .{};
    const run = try fx.start(&seats, auditor.auditor());
    defer run.destroy();
    var server = mcp.Server.init(gpa, run);
    try expectRpcError(&server, status_call, -32000);
    try expectRpcError(&server, "{broken", -32700);
    try expectRpcError(&server, "[]", -32600);
    try expectRpcError(&server, "{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"ping\"}", -32600);
    try expectRpcError(&server, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}", -32602);
    var ping = try call(&server, "{\"jsonrpc\":\"2.0\",\"id\":-7,\"method\":\"ping\"}");
    defer ping.deinit();
    try testing.expectEqual(@as(i64, -7), ping.value.object.get("id").?.integer);
    try testing.expect(ping.value.object.get("result").? == .object);
    try ready(&server);
    try expectRpcError(&server, initialize, -32600);
    try expectRpcError(&server, "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"other\"}", -32601);
    var listing = try call(&server, "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/list\"}");
    defer listing.deinit();
    const tools = listing.value.object.get("result").?.object.get("tools").?.array.items;
    try testing.expectEqual(@as(usize, 4), tools.len);
    for (tools) |tool| {
        const schema = tool.object.get("inputSchema").?.object;
        try testing.expect(!schema.get("additionalProperties").?.bool);
        try testing.expect(schema.get("properties").? == .object);
    }
    try testing.expect((try server.handle(gpa, "{\"jsonrpc\":\"2.0\",\"id\":17,\"result\":{}}")) == null);
    const oversized = try gpa.alloc(u8, mcp.max_message_bytes + 1);
    defer gpa.free(oversized);
    @memset(oversized, ' ');
    try expectRpcError(&server, oversized, -32600);
    try testing.expectEqual(@as(u32, 0), seats.calls);
    // Protocol errors do not poison cancellation or leave a run stuck live.
    var cancelled = try call(&server, cancel);
    defer cancelled.deinit();
    try expectPhase(cancelled.value, "cancelled");
}

test "teamwork MCP L2: NDJSON descriptor transport bounds frames, recovers and cancels at EOF" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var seats: Seats = .{};
    defer seats.deinit();
    var auditor: audit.UnavailableAuditor = .{};
    const run = try fx.start(&seats, auditor.auditor());
    defer run.destroy();
    var server = mcp.Server.init(gpa, run);
    var input_path: PathBuf = undefined;
    var output_path: PathBuf = undefined;
    const input = try pfs.openZ(try std.fmt.bufPrint(&input_path, "{s}/input", .{fx.root.slice()}), .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o600);
    defer pfs.close(input);
    const output = try pfs.openZ(try std.fmt.bufPrint(&output_path, "{s}/output", .{fx.root.slice()}), .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o600);
    defer pfs.close(output);
    try testing.expect(pfs.writeAll(input, initialize ++ "\r\n" ++ initialized ++ "\n{broken\n"));
    const oversized = try gpa.alloc(u8, mcp.max_message_bytes + 1);
    defer gpa.free(oversized);
    @memset(oversized, 'x');
    try testing.expect(pfs.writeAll(input, oversized));
    try testing.expect(pfs.writeAll(input, "\n" ++ status_call ++ "\n" ++ implement));
    try testing.expectEqual(@as(i64, 0), pfs.lseek(input, 0, .set));
    try server.serveFds(input, output);
    const bytes = try readFile(fx.root.slice(), "output");
    defer gpa.free(bytes);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, bytes, "\n"), '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        defer parsed.deinit();
        if (count == 3) try expectPhase(parsed.value, "approved");
        count += 1;
    }
    // initialize, parse error, oversized error, status, unterminated error.
    try testing.expectEqual(@as(usize, 5), count);
    try testing.expectEqual(@as(u32, 0), seats.calls);
    try testing.expectEqual(runtime.Phase.cancelled, run.state.phase());
}

const TransportWorker = struct {
    server: *mcp.Server,
    input: pfs.Fd,
    output: pfs.Fd,
    started: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    result: anyerror!void = {},

    fn serve(self: *TransportWorker) void {
        self.started.store(true, .release);
        self.result = self.server.serveFds(self.input, self.output);
        self.done.store(true, .release);
    }
};

fn waitFor(flag: *const std.atomic.Value(bool), timeout_ms: i64) bool {
    const deadline = util_time.nowMs() + timeout_ms;
    while (!flag.load(.acquire)) {
        if (util_time.nowMs() >= deadline) return false;
        util_time.sleepMs(5);
    }
    return true;
}

fn expectIdleCancellation(input_bytes: []const u8) !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var seats: Seats = .{};
    defer seats.deinit();
    var auditor: audit.UnavailableAuditor = .{};
    const run = try fx.start(&seats, auditor.auditor());
    defer run.destroy();
    var server = mcp.Server.init(gpa, run);
    var input: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&input));
    defer pfs.close(input[0]);
    const input_flags = std.c.fcntl(input[0], std.c.F.GETFL);
    var input_writer = input[1];
    defer if (input_writer != pfs.invalid_fd) pfs.close(input_writer);
    var output: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&output));
    defer pfs.close(output[0]);
    var output_writer = output[1];
    defer if (output_writer != pfs.invalid_fd) pfs.close(output_writer);
    // These small fixtures fit in one pipe write, including the partial frame.
    try testing.expect(pfs.writeAll(input_writer, input_bytes));
    var worker: TransportWorker = .{ .server = &server, .input = input[0], .output = output_writer };
    const thread = try @import("platform").thread.spawn(.full, TransportWorker.serve, .{&worker});
    defer {
        // A regression must fail within the deadline, then unblock on EOF so
        // cleanup can join the server instead of hanging the test process.
        pfs.close(input_writer);
        input_writer = pfs.invalid_fd;
        thread.join();
    }
    try testing.expect(waitFor(&worker.started, 1_000));
    // Let the server consume available bytes and enter its idle read wait.
    util_time.sleepMs(150);
    try testing.expect(!worker.done.load(.acquire));
    run.abort.abort(.user_interrupt);
    // The writer remains open throughout this assertion: EOF cannot help.
    try testing.expect(waitFor(&worker.done, 1_000));
    try worker.result;
    try testing.expectEqual(runtime.Phase.cancelled, run.state.phase());
    try testing.expectEqual(pfs.invalid_fd, run.lease_fd);
    try testing.expectEqual(@as(u32, 0), seats.calls);
    const durable = try readFile(run.dir.root, "run.json");
    defer gpa.free(durable);
    var saved = try std.json.parseFromSlice(std.json.Value, gpa, durable, .{});
    defer saved.deinit();
    try testing.expectEqualStrings("cancelled", saved.value.object.get("state").?.string);
    // Both borrowed endpoints are still owned by the host, with no flag churn.
    try testing.expect(std.c.fcntl(input[0], std.c.F.GETFD) >= 0);
    try testing.expect(std.c.fcntl(output_writer, std.c.F.GETFD) >= 0);
    try testing.expectEqual(input_flags, std.c.fcntl(input[0], std.c.F.GETFL));
    pfs.close(output_writer);
    output_writer = pfs.invalid_fd;
    var bytes: [4096]u8 = undefined;
    const n = pfs.read(output[0], &bytes);
    try testing.expect(n >= 0);
    if (std.mem.startsWith(u8, input_bytes, initialize ++ "\n")) {
        // Exactly the initialize response, without cancellation progress or an
        // unterminated-frame error when abort discards the pending bytes.
        const line = std.mem.trimEnd(u8, bytes[0..@intCast(n)], "\n");
        try testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
        var reply = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        defer reply.deinit();
        try testing.expect(reply.value.object.get("result") != null);
        try testing.expectEqual(@as(i64, 1), reply.value.object.get("id").?.integer);
    } else {
        try testing.expectEqual(@as(isize, 0), n);
    }
    try testing.expectEqual(@as(isize, 0), pfs.read(output[0], &bytes));
}

test "teamwork MCP L2: shared abort cancels an idle open input pipe before initialize" {
    try expectIdleCancellation("");
}

test "teamwork MCP L2: shared abort cancels an idle open input pipe after initialize" {
    try expectIdleCancellation(initialize ++ "\n" ++ initialized ++ "\n");
}

test "teamwork MCP L2: shared abort discards a partial frame on an open input pipe" {
    try expectIdleCancellation(initialize ++ "\n" ++ initialized ++ "\n" ++ implement);
}
