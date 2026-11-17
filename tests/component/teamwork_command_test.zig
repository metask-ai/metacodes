//! Installed-product consumers; every provider response is a local cassette.
const std = @import("std");
const builtin = @import("builtin");
const cc = @import("cc");
const harness = @import("harness");
const pfs = @import("platform").fs;
const testing = std.testing;

const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    root: []const u8,
    repo: []const u8,
    state: []const u8,

    fn init(self: *Case) !void {
        if (builtin.os.tag == .windows) return error.SkipZigTest;
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.tmp = testing.tmpDir(.{});
        const a = self.arena.allocator();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        self.root = try a.dupe(u8, buf[0..try self.tmp.dir.realPath(testing.io, &buf)]);
        self.repo = try std.fmt.allocPrint(a, "{s}/repo", .{self.root});
        self.state = try std.fmt.allocPrint(a, "{s}/state", .{self.root});
        try self.tmp.dir.createDirPath(testing.io, "repo/.metacodes");
        try self.tmp.dir.createDirPath(testing.io, "state");
        try self.write("repo/README", "fixture\n");
        try self.write("request.md", "Add feature.txt containing feature.\n");
        const out = try self.spawn(&.{ "/bin/sh", "-c", "git init -q && git add README && git -c user.name=t -c user.email=t@example.invalid -c commit.gpgSign=false commit -qm init" });
        try testing.expectEqual(@as(i32, 0), out.exit_code);
    }

    fn deinit(self: *Case) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn write(self: *Case, path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
    }

    fn read(self: *Case, path: []const u8) ![]const u8 {
        return self.tmp.dir.readFileAlloc(testing.io, path, self.arena.allocator(), .limited(1 << 20));
    }

    fn exists(self: *Case, path: []const u8) !bool {
        const z = try std.fmt.allocPrintSentinel(self.arena.allocator(), "{s}/{s}", .{ self.root, path }, 0);
        return pfs.exists(z);
    }

    fn spawn(self: *Case, args: []const []const u8) !cc.tools_common.SpawnOut {
        const a = self.arena.allocator();
        var argv: std.ArrayList(?[*:0]const u8) = .empty;
        for (args) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
        try argv.append(a, null);
        return cc.tools_common.spawnCaptureWithStderrTimed(argv.items, a, null, 60_000, null, 2 << 20, self.repo);
    }

    fn cli(self: *Case, args: []const []const u8) !cc.tools_common.SpawnOut {
        return self.cliWithEnv(args, &.{});
    }

    fn cliWithEnv(self: *Case, args: []const []const u8, extra_env: []const []const u8) !cc.tools_common.SpawnOut {
        const raw = std.c.getenv("METACODES_TEST_CLI_BIN") orelse return error.SkipZigTest;
        const a = self.arena.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ "/usr/bin/env", "-u", "METACODES_PROVIDER", "-u", "METACODES_MODEL", "-u", "METACODES_CONFIG_FILE", "-u", "METASK_API_KEY", "-u", "METASK_GATEWAY_URL" });
        try argv.append(a, try std.fmt.allocPrint(a, "HOME={s}", .{self.root}));
        try argv.appendSlice(a, &.{ "METACODES_NO_PROBE=1", "METACODES_KG_AUTOSTART=0", "METACODES_JEV_URL=off" });
        try argv.appendSlice(a, extra_env);
        try argv.appendSlice(a, &.{ std.mem.span(raw), "--state-dir", self.state, "teamwork" });
        try argv.appendSlice(a, args);
        const out = try self.spawn(argv.items);
        if (out.exit_code != 0 and std.mem.indexOf(u8, out.stderr, "error:") == null)
            std.debug.print("teamwork CLI exit {d}: {s}\n", .{ out.exit_code, out.stderr });
        return out;
    }

    fn request(self: *Case) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}/request.md", .{self.root});
    }
};

test "teamwork command: approval and budget gates precede App, seats and worktrees" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    // Even broken secret/provider config is not read until explicit approval.
    try c.write("state/config.json", "not json -- secret marker");
    const refused = try c.cli(&.{ "run", "--request-file", try c.request(), "--budget-usd", "2", "--base-url", "http://127.0.0.1:1/v1/messages" });
    try testing.expectEqual(@as(i32, 2), refused.exit_code);
    try testing.expect(std.mem.indexOf(u8, refused.stderr, "ApprovalRequired") != null);
    try testing.expect(!try c.exists("state/teamwork"));
    const mcp = try c.cli(&.{ "mcp", "--request-file", try c.request(), "--budget-usd", "2" });
    try testing.expectEqual(@as(i32, 2), mcp.exit_code);
    try testing.expect(std.mem.indexOf(u8, mcp.stderr, "ApprovalRequired") != null);
    try testing.expect(!try c.exists("state/teamwork"));
    try testing.expect(!try c.exists("state/projects"));
    try c.write("state/config.json", "{}");
    const missing = try c.cli(&.{ "run", "--request-file", try c.request(), "--approve" });
    try testing.expectEqual(@as(i32, 2), missing.exit_code);
    try testing.expect(std.mem.indexOf(u8, missing.stderr, "BudgetMissing") != null);
    try testing.expect(!try c.exists("state/teamwork"));
    const unsupported = try c.cli(&.{ "run", "--request-file", try c.request(), "--approve", "--config-json", "{\"budget_usd\":2,\"seats\":{\"verifier\":{\"effort\":\"high\"}}}" });
    try testing.expectEqual(@as(i32, 2), unsupported.exit_code);
    try testing.expect(std.mem.indexOf(u8, unsupported.stderr, "VerifierEffortUnsupported") != null);
    try testing.expect(!try c.exists("state/teamwork"));
    const resume_override = try c.cli(&.{ "resume", "r1", "--approve", "--budget-usd", "5" });
    try testing.expectEqual(@as(i32, 2), resume_override.exit_code);
    try testing.expect(std.mem.indexOf(u8, resume_override.stderr, "ResumeOverridesForbidden") != null);
    const resume_model = try c.cli(&.{ "resume", "r1", "--approve", "--model", "changed" });
    try testing.expectEqual(@as(i32, 2), resume_model.exit_code);
    try testing.expect(std.mem.indexOf(u8, resume_model.stderr, "ResumeOverridesForbidden") != null);
    const raw = std.c.getenv("METACODES_TEST_CLI_BIN") orelse return error.SkipZigTest;
    const inside = try c.spawn(&.{ std.mem.span(raw), "--state-dir", c.repo, "teamwork", "run", "--request-file", try c.request(), "--approve", "--budget-usd", "2" });
    try testing.expectEqual(@as(i32, 2), inside.exit_code);
    try testing.expect(std.mem.indexOf(u8, inside.stderr, "StateRootInsideRepository") != null);
    try testing.expect(!try c.exists("repo/teamwork"));
    if (builtin.os.tag == .linux) {
        const sandbox = try c.cliWithEnv(&.{ "run", "--request-file", try c.request(), "--approve", "--budget-usd", "2", "--api-key", "fixture-key", "--base-url", "http://127.0.0.1:1/v1/messages" }, &.{"METACODES_BWRAP=/nonexistent-teamwork-backend"});
        try testing.expectEqual(@as(i32, 1), sandbox.exit_code);
        try testing.expect(std.mem.indexOf(u8, sandbox.stderr, "SandboxUnavailable") != null);
        try testing.expect(!try c.exists("state/teamwork"));
    }
}

const start = "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"fixture\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n";
const stop = "data: {\"type\":\"content_block_stop\",\"index\":0}\n\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\ndata: {\"type\":\"message_stop\"}\n\n";
const probe = start ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"probe\",\"name\":\"Bash\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"cat feature.txt\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\ndata: {\"type\":\"message_stop\"}\n\n";
const pass = start ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"REQUIREMENT: feature.txt contains feature\\nSUBSTITUTE: empty file\\nPROBE: cat feature.txt\\nOBSERVED: feature\\nVERDICT: PASS\"}}\n\n" ++ stop;

test "teamwork command: pre-seat status tolerates no ledger, surfaces reservation and never repairs disk" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    const a = c.arena.allocator();
    try c.tmp.dir.createDirPath(testing.io, "state/teamwork/approved1/seats");
    const saved = "{\"state\":\"approved\",\"detail\":null,\"repo\":\"fixture\",\"dispatched\":{},\"audits\":0,\"last_audit\":null,\"merge_conflicts\":0}";
    try c.write("state/teamwork/approved1/run.json", saved);
    try c.write("state/teamwork/approved1/approved-config.json", "{\"enabled\":true,\"budget_usd\":2}");
    try c.write("state/config.json", "malformed secret-marker");
    const before = try c.cli(&.{ "status", "approved1" });
    try testing.expectEqual(@as(i32, 0), before.exit_code);
    const first = try std.json.parseFromSliceLeaky(std.json.Value, a, before.stdout, .{});
    const budget = first.object.get("budget").?.object;
    try testing.expectEqual(@as(i64, 0), budget.get("charges").?.integer);
    try testing.expect(budget.get("pending").? == .null);
    try testing.expect(!try c.exists("state/teamwork/approved1/budget.jsonl"));
    const receipt = "{\"seat_id\":\"implementer-1\",\"harness\":\"metacodes\",\"usd\":2,\"wallclock_ms\":0,\"source\":\"reserved\"}\n";
    try c.write("state/teamwork/approved1/budget.jsonl.pending", receipt);
    const reserved = try c.cli(&.{ "status", "approved1", "--json" });
    try testing.expectEqual(@as(i32, 0), reserved.exit_code);
    const second = try std.json.parseFromSliceLeaky(std.json.Value, a, reserved.stdout, .{});
    try testing.expectEqualStrings("reserved", second.object.get("budget").?.object.get("pending").?.object.get("source").?.string);
    try testing.expectEqualStrings(receipt, try c.read("state/teamwork/approved1/budget.jsonl.pending"));
    try testing.expect(!try c.exists("state/teamwork/approved1/budget.jsonl"));
    const partial = "{\"seat_id\":\"interrupted";
    try c.write("state/teamwork/approved1/budget.jsonl", partial);
    const torn = try c.cli(&.{ "status", "approved1" });
    try testing.expectEqual(@as(i32, 0), torn.exit_code);
    const third = try std.json.parseFromSliceLeaky(std.json.Value, a, torn.stdout, .{});
    try testing.expect(third.object.get("budget").?.object.get("torn_tail").?.bool);
    try testing.expectEqualStrings(partial, try c.read("state/teamwork/approved1/budget.jsonl"));
    try testing.expectEqualStrings(saved, try c.read("state/teamwork/approved1/run.json"));
}

test "teamwork command: inherited native models are pinned on wire and retained for resume" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    const a = c.arena.allocator();
    const text = start ++ "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"No handoff in this fixture\"}}\n\n" ++ stop;
    var server = try harness.MockServer.startCassette(&.{text}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    const out = try c.cli(&.{ "run", "--request-file", try c.request(), "--id", "native1", "--approve", "--budget-usd", "2", "--max-rounds", "1", "--model", "fixture-original", "--api-key", "fixture-key", "--base-url", url });
    if (std.mem.indexOf(u8, out.stderr, "SandboxUnavailable") != null) {
        try testing.expectEqual(@as(i32, 1), out.exit_code);
        try testing.expect(!try c.exists("state/teamwork/native1"));
        return;
    }
    try testing.expectEqual(@as(i32, 1), out.exit_code);
    try testing.expectEqual(@as(usize, 1), server.requestCount());
    try testing.expectEqualStrings("\"fixture-original\"", server.requestAt(0).?.jsonField("model").?);
    const policy_text = try c.read("state/teamwork/native1/approved-config.json");
    const policy = try std.json.parseFromSliceLeaky(std.json.Value, a, policy_text, .{});
    const seats = policy.object.get("seats").?.object;
    for ([_][]const u8{ "implementer", "reviewer", "verifier" }) |role|
        try testing.expectEqualStrings("fixture-original", seats.get(role).?.object.get("model").?.string);
    try testing.expect(seats.get("manager").?.object.get("model") == null);
    try testing.expect(seats.get("interviewer").?.object.get("model") == null);
    try c.write("state/config.json", "{\"model\":\"changed-default\",\"teamwork\":{\"budget_usd\":99,\"seats\":{\"implementer\":{\"model\":\"changed-seat\"}}}}");
    const prepared = try cc.teamwork_command.prepare(a, .{ .action = .@"resume", .approve = true, .id = try cc.teamwork_command.RunId.parse("native1") }, c.state, c.repo);
    try testing.expectEqualStrings("fixture-original", prepared.cfg.seats.get(.implementer).model.?);
    try testing.expectEqual(@as(f64, 2), prepared.cfg.budget_usd);
    const resumed = try c.cli(&.{ "resume", "native1", "--approve", "--api-key", "fixture-key", "--base-url", url });
    try testing.expectEqual(@as(i32, 1), resumed.exit_code); // terminal failure stays terminal
    try testing.expectEqual(@as(usize, 1), server.requestCount());
}

test "teamwork command: approved external seats config reaches argv, verifier wire, merge and disk-only status" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    const a = c.arena.allocator();
    var server = try harness.MockServer.startCassette(&.{ probe, pass }, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    const script =
        \\#!/bin/sh
        \\case "$1" in
        \\--version) echo '2.1.323 (Claude Code)'; exit 0 ;;
        \\--help) echo '--print --output-format stream-json --verbose --add-dir --permission-mode acceptEdits dontAsk --permission-prompts host none --no-session-persistence --model --effort --max-budget-usd --append-system-prompt'; exit 0 ;;
        \\esac
        \\seat=''; prev=''
        \\for arg in "$@"; do
        \\  if [ "$prev" = '--add-dir' ]; then seat="$arg"; fi
        \\  prev="$arg"
        \\done
        \\printf '%s\n' "$@" > "$seat/argv.txt"
        \\cat > "$seat/handoff.md" <<'HANDOFF'
        \\## Observation
        \\o
        \\## Reasoning
        \\r
        \\## Caveats
        \\c
        \\## Conclusion
        \\k
        \\## Verification
        \\test -f feature.txt
        \\HANDOFF
        \\case "$seat" in
        \\*implementer-*) printf 'feature\n' > feature.txt ;;
        \\*reviewer-*) echo '{"verdict":"approve","evidence":[{"command":"test -f feature.txt","exit_code":0,"output_digest":"0000000000000000000000000000000000000000000000000000000000000000","output_excerpt":"passed"}],"issues":{"opened":[],"closed":[],"still_open":[]}}' > "$seat/review.json" ;;
        \\esac
        \\echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.1}'
        \\
    ;
    try c.write("claude-fixture", script);
    const binary = try std.fmt.allocPrintSentinel(a, "{s}/claude-fixture", .{c.root}, 0);
    try testing.expectEqual(@as(c_int, 0), pfs.chmod(binary, 0o755));
    const global = try std.fmt.allocPrint(a,
        \\{{"teamwork":{{"budget_usd":4,"max_rounds":3,"seats":{{"implementer":{{"harness":"claude_code","command":"{s}","model":"global-impl"}},"reviewer":{{"harness":"claude_code","command":"{s}","model":"global-review"}},"verifier":{{"model":"fixture-verifier"}}}},"check_command":"false"}}}}
    , .{ binary, binary });
    try c.write("state/config.json", global);
    try c.write("repo/.metacodes/teamwork.json", "{\"budget_usd\":3,\"check_command\":\"test -f feature.txt\",\"seats\":{\"implementer\":{\"model\":\"project-impl\"}}}");
    const out = try c.cli(&.{ "run", "--request-file", try c.request(), "--id", "r1", "--approve", "--budget-usd", "2", "--max-rounds", "1", "--config-json", "{\"seats\":{\"reviewer\":{\"model\":\"cli-review\",\"effort\":\"high\"}}}", "--api-key", "fixture-key", "--model", "fixture-host", "--base-url", url });
    if (std.mem.indexOf(u8, out.stderr, "SandboxUnavailable") != null) {
        try testing.expectEqual(@as(i32, 1), out.exit_code);
        try testing.expect(!try c.exists("state/teamwork/r1"));
        return;
    }
    if (out.exit_code != 0) std.debug.print("teamwork run: {s}\n{s}\n", .{ out.stdout, out.stderr });
    try testing.expectEqual(@as(i32, 0), out.exit_code);
    try testing.expectEqualStrings("feature\n", try c.read("repo/feature.txt"));
    const impl = try c.read("state/teamwork/r1/seats/implementer-1/argv.txt");
    const review = try c.read("state/teamwork/r1/seats/reviewer-1/argv.txt");
    try testing.expect(std.mem.indexOf(u8, impl, "--model\nproject-impl\n") != null);
    const cap_start = (std.mem.indexOf(u8, impl, "--max-budget-usd\n") orelse return error.MissingBudgetArg) + "--max-budget-usd\n".len;
    const cap_end = std.mem.indexOfScalarPos(u8, impl, cap_start, '\n') orelse return error.MissingBudgetArg;
    try testing.expectEqual(@as(f64, 2), try std.fmt.parseFloat(f64, impl[cap_start..cap_end]));
    try testing.expect(std.mem.indexOf(u8, review, "--model\ncli-review\n--effort\nhigh\n") != null);
    // The integration branch adds the immutable charter argv pair. Keep
    // this consumer compatible with the preceding driver while checking
    // the role-specific bytes whenever that pair is present.
    if (std.mem.indexOf(u8, impl, "--append-system-prompt\n")) |offset|
        try testing.expect(std.mem.indexOf(u8, impl[offset..], "You are the implementer of a teamwork run.") != null);
    if (std.mem.indexOf(u8, review, "--append-system-prompt\n")) |offset|
        try testing.expect(std.mem.indexOf(u8, review[offset..], "reviewer") != null);
    try testing.expectEqual(@as(usize, 2), server.requestCount());
    const wire = server.requestAt(0).?;
    try testing.expectEqualStrings("\"fixture-verifier\"", wire.jsonField("model").?);
    const original_state = try c.read("state/teamwork/r1/run.json");
    // Status reads none of the global/provider configuration, does not
    // reinitialize App, and does not rewrite the completed state.
    try c.write("state/config.json", "malformed secret-global-marker");
    const status = try c.cli(&.{ "status", "r1", "--json" });
    try testing.expectEqual(@as(i32, 0), status.exit_code);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, status.stdout, .{});
    try testing.expectEqualStrings("done", value.object.get("state").?.string);
    const cap = value.object.get("budget").?.object.get("cap_usd").?;
    try testing.expectEqual(@as(f64, 2), if (cap == .integer) @as(f64, @floatFromInt(cap.integer)) else cap.float);
    try testing.expect(std.mem.indexOf(u8, status.stdout, "fixture-key") == null);
    try testing.expect(std.mem.indexOf(u8, status.stdout, "secret-global-marker") == null);
    try testing.expectEqualStrings(original_state, try c.read("state/teamwork/r1/run.json"));
    try testing.expectEqual(@as(usize, 2), server.requestCount());
    try c.write("state/config.json", "{\"teamwork\":{\"budget_usd\":99,\"check_command\":\"false\"}}");
    const resumed = try c.cli(&.{ "resume", "r1", "--approve", "--api-key", "fixture-key", "--base-url", url });
    try testing.expectEqual(@as(i32, 0), resumed.exit_code);
    try testing.expectEqual(@as(usize, 2), server.requestCount());
}
