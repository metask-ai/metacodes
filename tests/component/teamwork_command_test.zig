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
        return self.spawnInput(args, null);
    }

    fn spawnInput(self: *Case, args: []const []const u8, input: ?[]const u8) !cc.tools_common.SpawnOut {
        const a = self.arena.allocator();
        var argv: std.ArrayList(?[*:0]const u8) = .empty;
        for (args) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
        try argv.append(a, null);
        const out = try @import("platform").process.capture(argv.items, a, .{ .cwd = self.repo, .stdin_data = input, .timeout_ms = 60_000, .max_bytes = 2 << 20 });
        return .{ .exit_code = out.exit_code, .stdout = out.stdout, .stderr = out.stderr };
    }

    fn cli(self: *Case, args: []const []const u8) !cc.tools_common.SpawnOut {
        return self.cliWithEnv(args, &.{});
    }

    fn cliEnabled(self: *Case, args: []const []const u8) !cc.tools_common.SpawnOut {
        return self.cliEnabledWithEnv(args, &.{});
    }

    fn cliEnabledWithEnv(self: *Case, args: []const []const u8, env: []const []const u8) !cc.tools_common.SpawnOut {
        return self.cliEnabledInput(args, env, null);
    }

    fn cliEnabledInput(self: *Case, args: []const []const u8, env: []const []const u8, input: ?[]const u8) !cc.tools_common.SpawnOut {
        const opted_in = try self.arena.allocator().alloc([]const u8, args.len + 1);
        @memcpy(opted_in[0..args.len], args);
        opted_in[args.len] = "--preview";
        return self.cliInput(opted_in, env, input);
    }

    fn cliWithEnv(self: *Case, args: []const []const u8, extra_env: []const []const u8) !cc.tools_common.SpawnOut {
        return self.cliInput(args, extra_env, null);
    }

    fn cliInput(self: *Case, args: []const []const u8, extra_env: []const []const u8, input: ?[]const u8) !cc.tools_common.SpawnOut {
        return self.cliLeadingInput(args, extra_env, input, &.{});
    }

    fn cliLeadingInput(self: *Case, args: []const []const u8, extra_env: []const []const u8, input: ?[]const u8, leading: []const []const u8) !cc.tools_common.SpawnOut {
        const raw = std.c.getenv("METACODES_TEST_CLI_BIN") orelse return error.SkipZigTest;
        const a = self.arena.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ "/usr/bin/env", "-u", "METACODES_PROVIDER", "-u", "METACODES_MODEL", "-u", "METACODES_CONFIG_FILE", "-u", "METASK_API_KEY", "-u", "METASK_GATEWAY_URL" });
        try argv.append(a, try std.fmt.allocPrint(a, "HOME={s}", .{self.root}));
        try argv.appendSlice(a, &.{ "METACODES_NO_PROBE=1", "METACODES_KG_AUTOSTART=0", "METACODES_JEV_URL=off" });
        try argv.appendSlice(a, extra_env);
        try argv.appendSlice(a, &.{ std.mem.span(raw), "--state-dir", self.state });
        try argv.appendSlice(a, leading);
        try argv.append(a, "teamwork");
        try argv.appendSlice(a, args);
        const out = try self.spawnInput(argv.items, input);
        if (out.exit_code != 0 and std.mem.indexOf(u8, out.stderr, "error:") == null)
            std.debug.print("teamwork CLI exit {d}: {s}\n", .{ out.exit_code, out.stderr });
        return out;
    }

    fn request(self: *Case) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}/request.md", .{self.root});
    }

    fn configuredMcp(self: *Case, file: []const u8) !void {
        const a = self.arena.allocator();
        const script = try std.fmt.allocPrint(a, "printf started > '{s}/outbound-mcp-started'", .{self.root});
        const json = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(.{ .mcpServers = .{ .teamwork = .{ .command = "/bin/sh", .args = .{ "-c", script } } } }, .{})});
        try self.write(file, json);
    }
};

test "teamwork command preview L2: default off and final opt-out precede App, MCP, providers and worktrees" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    const a = c.arena.allocator();
    try c.configuredMcp(".claude.json");
    var server = try harness.MockServer.startCassette(&.{}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    for ([_][]const u8{ "run", "mcp" }) |action| {
        const args = [_][]const u8{ action, "--request-file", try c.request(), "--approve", "--budget-usd", "2", "--model", "fixture", "--api-key", "fixture-key", "--base-url", url };
        const out = try c.cli(&args);
        try testing.expectEqual(@as(i32, 2), out.exit_code);
        try testing.expect(std.mem.indexOf(u8, out.stderr, "PreviewDisabled") != null);
    }
    try c.write("state/config.json", "{\"preview\":true,\"teamwork\":{\"enabled\":true,\"budget_usd\":2}}");
    const out = try c.cli(&.{ "run", "--request-file", try c.request(), "--approve", "--preview", "--no-preview", "--api-key", "fixture-key", "--base-url", url });
    try testing.expectEqual(@as(i32, 2), out.exit_code);
    try testing.expect(std.mem.indexOf(u8, out.stderr, "PreviewDisabled") != null);
    const leading_out = try c.cliLeadingInput(&.{ "run", "--request-file", try c.request(), "--approve", "--no-preview" }, &.{}, null, &.{"--preview"});
    try testing.expectEqual(@as(i32, 2), leading_out.exit_code);
    try testing.expect(std.mem.indexOf(u8, leading_out.stderr, "PreviewDisabled") != null);
    const resumed_off = try c.cli(&.{ "resume", "old-checkpoint", "--approve", "--no-preview", "--api-key", "fixture-key", "--base-url", url });
    try testing.expectEqual(@as(i32, 2), resumed_off.exit_code);
    try testing.expect(std.mem.indexOf(u8, resumed_off.stderr, "PreviewDisabled") != null);
    const feature_off = try c.cli(&.{ "run", "--request-file", try c.request(), "--approve", "--no-preview=teamwork", "--api-key", "fixture-key", "--base-url", url });
    try testing.expectEqual(@as(i32, 2), feature_off.exit_code);
    try testing.expect(std.mem.indexOf(u8, feature_off.stderr, "PreviewDisabled") != null);
    const leading_feature_off = try c.cliLeadingInput(&.{ "run", "--request-file", try c.request(), "--approve" }, &.{}, null, &.{"--no-preview=teamwork"});
    try testing.expectEqual(@as(i32, 2), leading_feature_off.exit_code);
    try testing.expect(std.mem.indexOf(u8, leading_feature_off.stderr, "PreviewDisabled") != null);
    try c.write("state/config.json", "{\"preview\":false,\"teamwork\":{\"enabled\":true,\"budget_usd\":2}}");
    const other_feature = try c.cli(&.{ "run", "--request-file", try c.request(), "--approve", "--preview=execute_code,comment_guard", "--api-key", "fixture-key", "--base-url", url });
    try testing.expectEqual(@as(i32, 2), other_feature.exit_code);
    try testing.expect(std.mem.indexOf(u8, other_feature.stderr, "PreviewDisabled") != null);
    try testing.expectEqual(@as(usize, 0), server.requestCount());
    try testing.expect(!try c.exists("state/teamwork"));
    try testing.expect(!try c.exists("state/projects"));
    try testing.expect(!try c.exists("repo/.git/worktrees"));
    try testing.expect(!try c.exists("outbound-mcp-started"));
}

test "teamwork command: approval and budget gates precede App, seats and worktrees" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    // Even broken secret/provider config is not read until explicit approval.
    try c.write("state/config.json", "not json -- secret marker");
    const refused = try c.cliEnabled(&.{ "run", "--request-file", try c.request(), "--budget-usd", "2", "--base-url", "http://127.0.0.1:1/v1/messages" });
    try testing.expectEqual(@as(i32, 2), refused.exit_code);
    try testing.expect(std.mem.indexOf(u8, refused.stderr, "ApprovalRequired") != null);
    try testing.expect(!try c.exists("state/teamwork"));
    const mcp = try c.cliEnabled(&.{ "mcp", "--request-file", try c.request(), "--budget-usd", "2" });
    try testing.expectEqual(@as(i32, 2), mcp.exit_code);
    try testing.expect(std.mem.indexOf(u8, mcp.stderr, "ApprovalRequired") != null);
    try testing.expect(!try c.exists("state/teamwork"));
    try testing.expect(!try c.exists("state/projects"));
    try c.write("state/config.json", "{}");
    const missing = try c.cliEnabled(&.{ "run", "--request-file", try c.request(), "--approve" });
    try testing.expectEqual(@as(i32, 2), missing.exit_code);
    try testing.expect(std.mem.indexOf(u8, missing.stderr, "BudgetMissing") != null);
    try testing.expect(!try c.exists("state/teamwork"));
    const unsupported = try c.cliEnabled(&.{ "run", "--request-file", try c.request(), "--approve", "--config-json", "{\"budget_usd\":2,\"seats\":{\"verifier\":{\"effort\":\"high\"}}}" });
    try testing.expectEqual(@as(i32, 2), unsupported.exit_code);
    try testing.expect(std.mem.indexOf(u8, unsupported.stderr, "VerifierEffortUnsupported") != null);
    try testing.expect(!try c.exists("state/teamwork"));
    const resume_override = try c.cliEnabled(&.{ "resume", "r1", "--approve", "--budget-usd", "5" });
    try testing.expectEqual(@as(i32, 2), resume_override.exit_code);
    try testing.expect(std.mem.indexOf(u8, resume_override.stderr, "ResumeOverridesForbidden") != null);
    const resume_model = try c.cliEnabled(&.{ "resume", "r1", "--approve", "--model", "changed" });
    try testing.expectEqual(@as(i32, 2), resume_model.exit_code);
    try testing.expect(std.mem.indexOf(u8, resume_model.stderr, "ResumeOverridesForbidden") != null);
    const raw = std.c.getenv("METACODES_TEST_CLI_BIN") orelse return error.SkipZigTest;
    const inside = try c.spawn(&.{ std.mem.span(raw), "--state-dir", c.repo, "teamwork", "run", "--preview", "--request-file", try c.request(), "--approve", "--budget-usd", "2" });
    try testing.expectEqual(@as(i32, 2), inside.exit_code);
    try testing.expect(std.mem.indexOf(u8, inside.stderr, "StateRootInsideRepository") != null);
    try testing.expect(!try c.exists("repo/teamwork"));
    if (builtin.os.tag == .linux) {
        const sandbox = try c.cliEnabledWithEnv(&.{ "run", "--request-file", try c.request(), "--approve", "--budget-usd", "2", "--api-key", "fixture-key", "--base-url", "http://127.0.0.1:1/v1/messages" }, &.{"METACODES_BWRAP=/nonexistent-teamwork-backend"});
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
    try c.configuredMcp("repo/.mcp.json");
    const text = start ++ "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"No handoff in this fixture\"}}\n\n" ++ stop;
    var server = try harness.MockServer.startCassette(&.{text}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    const out = try c.cliEnabled(&.{ "run", "--request-file", try c.request(), "--id", "native1", "--approve", "--budget-usd", "2", "--max-rounds", "1", "--model", "fixture-original", "--api-key", "fixture-key", "--base-url", url });
    if (std.mem.indexOf(u8, out.stderr, "SandboxUnavailable") != null) {
        try testing.expectEqual(@as(i32, 1), out.exit_code);
        try testing.expect(!try c.exists("state/teamwork/native1"));
        return;
    }
    try testing.expectEqual(@as(i32, 1), out.exit_code);
    try testing.expectEqual(@as(usize, 1), server.requestCount());
    try testing.expectEqualStrings("\"fixture-original\"", server.requestAt(0).?.jsonField("model").?);
    const tools = try std.json.parseFromSliceLeaky(std.json.Value, a, server.requestAt(0).?.jsonField("tools").?, .{});
    try testing.expect(tools == .array and tools.array.items.len > 0);
    inline for (.{ "Read", "Write", "Bash" }) |name| {
        var found = false;
        for (tools.array.items) |tool| if (std.mem.eql(u8, tool.object.get("name").?.string, name)) {
            found = true;
        };
        try testing.expect(found);
    }
    try testing.expect(!try c.exists("outbound-mcp-started"));
    const saved = try std.json.parseFromSliceLeaky(std.json.Value, a, try c.read("state/teamwork/native1/run.json"), .{});
    const policy = try std.json.parseFromSliceLeaky(std.json.Value, a, saved.object.get("approved_config_json").?.string, .{});
    const seats = policy.object.get("seats").?.object;
    for ([_][]const u8{ "implementer", "reviewer", "verifier" }) |role|
        try testing.expectEqualStrings("fixture-original", seats.get(role).?.object.get("model").?.string);
    try testing.expect(seats.get("manager").?.object.get("model") == null);
    try testing.expect(seats.get("interviewer").?.object.get("model") == null);
    try c.write("state/config.json", "{\"model\":\"changed-default\",\"teamwork\":{\"budget_usd\":99,\"seats\":{\"implementer\":{\"model\":\"changed-seat\"}}}}");
    const prepared = try cc.teamwork_command.prepare(a, .{ .action = .@"resume", .host_config = .{ .preview = .enabled }, .approve = true, .id = try cc.teamwork_command.RunId.parse("native1") }, c.state, c.repo);
    try testing.expectEqualStrings("fixture-original", prepared.cfg.seats.get(.implementer).model.?);
    try testing.expectEqual(@as(f64, 2), prepared.cfg.budget_usd);
    const resumed = try c.cliEnabled(&.{ "resume", "native1", "--approve", "--api-key", "fixture-key", "--base-url", url });
    try testing.expectEqual(@as(i32, 1), resumed.exit_code); // terminal failure stays terminal
    try testing.expectEqual(@as(usize, 1), server.requestCount());
}

test "teamwork command: approved external seats config reaches argv, verifier wire, merge and disk-only status" {
    try externalSeatsCase(false);
    try externalSeatsCase(true);
}

fn externalSeatsCase(saved_preview: bool) !void {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    const a = c.arena.allocator();
    var server = try harness.MockServer.startCassette(&.{ probe, pass }, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    const guard = try std.fmt.allocPrint(a,
        \\for path in '{s}/README' '{s}/teamwork/r1/ORIGINAL_REQUEST.md' '{s}/teamwork/r1/budget.jsonl' '{s}/teamwork/r1/runtime.lock'; do
        \\  if (printf changed > "$path") 2>/dev/null; then exit 91; fi
        \\done
        \\scratch=$(mktemp "$TMPDIR/teamwork-check.XXXXXX") || exit 92
        \\rm "$scratch"
        \\
    , .{ c.repo, c.state, c.state, c.state });
    try c.write("repo/check-fixture.sh", guard);
    const script =
        \\#!/bin/sh
        \\case "$1" in
        \\--version) echo '2.1.323 (Claude Code)'; exit 0 ;;
        \\--help) echo '--print --output-format stream-json --verbose --add-dir --permission-mode acceptEdits dontAsk --permission-prompts host none --no-session-persistence --model --effort --max-budget-usd --append-system-prompt --strict-mcp-config --mcp-config'; exit 0 ;;
        \\esac
        \\/bin/sh check-fixture.sh || exit $?
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
        \\/bin/sh check-fixture.sh && test -f feature.txt
        \\HANDOFF
        \\case "$seat" in
        \\*implementer-*) printf 'feature\n' > feature.txt ;;
        \\*reviewer-*)
        \\  echo '{"verdict":"approve","evidence":[{"command":"/bin/sh check-fixture.sh && test -f feature.txt","exit_code":0,"output_digest":"0000000000000000000000000000000000000000000000000000000000000000","output_excerpt":"passed"}],"issues":{"opened":[],"closed":[],"still_open":[]}}' > "$seat/review.json"
        \\  ln -s "$TEAMWORK_FIXTURE_SENTINEL" "$seat/status.json.tmp" || exit 93
        \\  ;;
        \\esac
        \\echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.1}'
        \\
    ;
    const sentinel = try std.fmt.allocPrint(a, "TEAMWORK_FIXTURE_SENTINEL='{s}/README'\n", .{c.repo});
    // Preserve the shebang as the first line of the installed fixture.
    try c.write("claude-fixture", try std.mem.concat(a, u8, &.{ "#!/bin/sh\n", sentinel, script["#!/bin/sh\n".len..] }));
    const binary = try std.fmt.allocPrintSentinel(a, "{s}/claude-fixture", .{c.root}, 0);
    try testing.expectEqual(@as(c_int, 0), pfs.chmod(binary, 0o755));
    const global = try std.fmt.allocPrint(a,
        \\{{"preview":{s},"teamwork":{{"budget_usd":4,"max_rounds":3,"seats":{{"implementer":{{"harness":"claude_code","command":"{s}","model":"global-impl"}},"reviewer":{{"harness":"claude_code","command":"{s}","model":"global-review"}},"verifier":{{"model":"fixture-verifier"}}}},"check_command":"false"}}}}
    , .{ if (saved_preview) "true" else "false", binary, binary });
    try c.write("state/config.json", global);
    try c.write("repo/.metacodes/teamwork.json", "{\"budget_usd\":3,\"check_command\":\"/bin/sh check-fixture.sh && test -f feature.txt\",\"seats\":{\"implementer\":{\"model\":\"project-impl\"}}}");
    const shared_temp = try std.fmt.allocPrint(a, "TMPDIR={s}", .{c.root});
    const args = [_][]const u8{ "run", "--request-file", try c.request(), "--id", "r1", "--approve", "--budget-usd", "2", "--max-rounds", "1", "--config-json", "{\"seats\":{\"reviewer\":{\"model\":\"cli-review\",\"effort\":\"high\"}}}", "--api-key", "fixture-key", "--model", "fixture-host", "--base-url", url };
    const out = if (saved_preview) try c.cliWithEnv(&args, &.{shared_temp}) else try c.cliLeadingInput(&args, &.{shared_temp}, null, &.{ "--no-preview", "--preview=teamwork" });
    if (std.mem.indexOf(u8, out.stderr, "SandboxUnavailable") != null) {
        try testing.expectEqual(@as(i32, 1), out.exit_code);
        try testing.expect(!try c.exists("state/teamwork/r1"));
        return;
    }
    if (out.exit_code != 0) std.debug.print("teamwork run: {s}\n{s}\n", .{ out.stdout, out.stderr });
    try testing.expectEqual(@as(i32, 0), out.exit_code);
    try testing.expectEqualStrings("feature\n", try c.read("repo/feature.txt"));
    try testing.expectEqualStrings("fixture\n", try c.read("repo/README"));
    try testing.expectEqualStrings("Add feature.txt containing feature.\n", try c.read("state/teamwork/r1/ORIGINAL_REQUEST.md"));
    try testing.expectEqualStrings("", try c.read("state/teamwork/r1/runtime.lock"));
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
    try c.write("state/config.json", "{\"preview\":false}");
    const denied_resume = try c.cli(&.{ "resume", "r1", "--approve", "--api-key", "fixture-key", "--base-url", url });
    try testing.expectEqual(@as(i32, 2), denied_resume.exit_code);
    try testing.expect(std.mem.indexOf(u8, denied_resume.stderr, "PreviewDisabled") != null);
    try testing.expectEqualStrings(original_state, try c.read("state/teamwork/r1/run.json"));
    try testing.expectEqual(@as(usize, 2), server.requestCount());
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
    const resumed = try c.cliEnabled(&.{ "resume", "r1", "--approve", "--api-key", "fixture-key", "--base-url", url });
    try testing.expectEqual(@as(i32, 0), resumed.exit_code);
    try testing.expectEqual(@as(usize, 2), server.requestCount());
}

test "teamwork command: installed MCP endpoint negotiates on stdio and never self-approves completion" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    const a = c.arena.allocator();
    // Claude Code's own config may contain this same teamwork endpoint.
    // Its subprocess host must not discover and recursively launch it.
    try c.configuredMcp(".claude.json");
    var provider = try harness.MockServer.startCassette(&.{}, 0);
    defer provider.stop();
    const frames =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"fixture-manager","version":"1"}}}
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"teamwork_status"}}
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"teamwork_request_completion"}}
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"teamwork_cancel"}}
        \\
    ;
    const out = try c.cliEnabledInput(&.{ "mcp", "--request-file", try c.request(), "--id", "mcp1", "--approve", "--budget-usd", "2", "--model", "fixture-model", "--api-key", "fixture-key", "--base-url", try provider.urlOwned(a) }, &.{}, frames);
    if (out.exit_code != 0) std.debug.print("MCP stderr: {s}\nstdout: {s}\n", .{ out.stderr, out.stdout });
    try testing.expectEqual(@as(i32, 0), out.exit_code);
    var replies: [5]std.json.Value = undefined;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, out.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try testing.expect(count < replies.len);
        replies[count] = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
        try testing.expectEqualStrings("2.0", replies[count].object.get("jsonrpc").?.string);
        try testing.expectEqual(@as(i64, @intCast(count + 1)), replies[count].object.get("id").?.integer);
        count += 1;
    }
    try testing.expectEqual(replies.len, count);
    try testing.expectEqual(@as(usize, 4), replies[1].object.get("result").?.object.get("tools").?.array.items.len);
    const initial = replies[2].object.get("result").?.object.get("structuredContent").?.object.get("snapshot").?;
    try testing.expectEqualStrings("approved", initial.object.get("state").?.object.get("kind").?.string);
    try testing.expectEqual(@as(usize, 0), initial.object.get("seats").?.array.items.len);
    const refused = replies[3].object.get("result").?;
    try testing.expect(refused.object.get("isError").?.bool);
    try testing.expectEqualStrings("NotApproved", refused.object.get("structuredContent").?.object.get("error").?.string);
    const final = replies[4].object.get("result").?.object.get("structuredContent").?.object.get("snapshot").?;
    try testing.expectEqualStrings("cancelled", final.object.get("state").?.object.get("kind").?.string);
    try testing.expectEqual(@as(usize, 0), provider.requestCount());
    try testing.expect(!try c.exists("outbound-mcp-started"));
    try testing.expect(!try c.exists("repo/feature.txt"));
    try testing.expectEqualStrings("Add feature.txt containing feature.\n", try c.read("state/teamwork/mcp1/ORIGINAL_REQUEST.md"));
    // No seat ran: the ledger is empty. Missing-ledger status is also
    // read-only, even when the current provider configuration is broken.
    try testing.expectEqualStrings("", try c.read("state/teamwork/mcp1/budget.jsonl"));
    const budget_path = try std.fmt.allocPrintSentinel(a, "{s}/teamwork/mcp1/budget.jsonl", .{c.state}, 0);
    try pfs.unlinkPath(budget_path.ptr);
    try c.write("state/config.json", "broken configuration");
    const status = try c.cli(&.{ "status", "mcp1" });
    try testing.expectEqual(@as(i32, 0), status.exit_code);
    try testing.expectEqual(@as(usize, 0), provider.requestCount());
}

test "teamwork command: resume refuses a weaker host sandbox policy" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    const a = c.arena.allocator();
    try c.tmp.dir.createDirPath(testing.io, "repo/.claude");
    const denied = try std.fs.path.join(a, &.{ c.root, "host-private" });
    try c.write("host-private", "fixture data\n");
    const settings = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(.{
        .sandbox = .{ .enabled = true, .filesystem = .{ .denyRead = .{denied} } },
    }, .{})});
    try c.write("repo/.claude/settings.json", settings);
    var provider = try harness.MockServer.startCassette(&.{}, 0);
    defer provider.stop();
    const url = try provider.urlOwned(a);
    const started = try c.cliEnabledInput(&.{ "mcp", "--request-file", try c.request(), "--id", "policy1", "--approve", "--budget-usd", "2", "--model", "fixture-model", "--api-key", "fixture-key", "--base-url", url }, &.{}, "");
    if (std.mem.indexOf(u8, started.stderr, "SandboxUnavailable") != null) return error.SkipZigTest;
    try testing.expectEqual(@as(i32, 0), started.exit_code);
    const saved = try c.read("state/teamwork/policy1/run.json");
    // Keep the same run and restore its approved phase to exercise the
    // installed resume entry before it can start another worker.
    const live = try std.mem.replaceOwned(u8, a, saved, "\"state\":\"cancelled\"", "\"state\":\"approved\"");
    try testing.expect(!std.mem.eql(u8, saved, live));
    try c.write("state/teamwork/policy1/run.json", live);
    try c.write("repo/.claude/settings.json", "{\"sandbox\":{\"enabled\":true}}");
    const resumed = try c.cliEnabled(&.{ "resume", "policy1", "--approve", "--api-key", "fixture-key", "--base-url", url });
    try testing.expect(resumed.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, resumed.stderr, "ConfigurationChanged") != null);
    try testing.expectEqual(@as(usize, 0), provider.requestCount());
    try testing.expectEqualStrings(live, try c.read("state/teamwork/policy1/run.json"));
}

test "teamwork command: request segments skip the interview and override seats for one headless run" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    const a = c.arena.allocator();
    const text = start ++ "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"No handoff in this fixture\"}}\n\n" ++ stop;
    var server = try harness.MockServer.startCassette(&.{text}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    try c.write("request.md", "[skip-interviews] Add feature.txt.\n");
    const unknown = try c.cliEnabled(&.{ "run", "--request-file", try c.request(), "--approve", "--budget-usd", "2", "--api-key", "fixture-key", "--base-url", url });
    try testing.expectEqual(@as(i32, 2), unknown.exit_code);
    try testing.expect(std.mem.indexOf(u8, unknown.stderr, "UnknownTeamworkSegment") != null);
    try testing.expect(!try c.exists("state/teamwork"));
    try c.write("request.md", "[skip-interview] [seats=reviewer:metacodes:segment-review]\nAdd feature.txt containing feature.\n");
    const out = try c.cliEnabled(&.{ "run", "--request-file", try c.request(), "--id", "seg1", "--approve", "--budget-usd", "2", "--max-rounds", "1", "--model", "fixture-original", "--api-key", "fixture-key", "--base-url", url });
    if (std.mem.indexOf(u8, out.stderr, "SandboxUnavailable") != null) return;
    try testing.expectEqual(@as(i32, 1), out.exit_code);
    try testing.expectEqualStrings("Add feature.txt containing feature.\n", try c.read("state/teamwork/seg1/ORIGINAL_REQUEST.md"));
    const saved = try std.json.parseFromSliceLeaky(std.json.Value, a, try c.read("state/teamwork/seg1/run.json"), .{});
    try testing.expectEqualStrings("skip_interview", saved.object.get("request_source").?.string);
    const policy = try std.json.parseFromSliceLeaky(std.json.Value, a, saved.object.get("approved_config_json").?.string, .{});
    const seats = policy.object.get("seats").?.object;
    try testing.expectEqualStrings("segment-review", seats.get("reviewer").?.object.get("model").?.string);
    try testing.expectEqualStrings("fixture-original", seats.get("implementer").?.object.get("model").?.string);
    const status = try c.cli(&.{ "status", "seg1" });
    try testing.expectEqual(@as(i32, 0), status.exit_code);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, status.stdout, .{});
    try testing.expectEqualStrings("skip_interview", value.object.get("request_source").?.string);
}

test "teamwork command: --events streams the snapshot, then every seat and phase change, as wire lines" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    const a = c.arena.allocator();
    const text = start ++ "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"No handoff in this fixture\"}}\n\n" ++ stop;
    var server = try harness.MockServer.startCassette(&.{text}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    const refused = try c.cliEnabled(&.{ "status", "ev1", "--events" });
    try testing.expectEqual(@as(i32, 2), refused.exit_code);
    try c.write("request.md", "[skip-interview] Add feature.txt containing feature.\n");
    const out = try c.cliEnabled(&.{ "run", "--request-file", try c.request(), "--id", "ev1", "--events", "--approve", "--budget-usd", "2", "--max-rounds", "1", "--model", "fixture", "--api-key", "fixture-key", "--base-url", url });
    if (std.mem.indexOf(u8, out.stderr, "SandboxUnavailable") != null) return;
    try testing.expectEqual(@as(i32, 1), out.exit_code);
    var transcript: std.Io.Writer.Allocating = .init(a);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out.stdout, "\n"), '\n');
    while (lines.next()) |line| {
        const value = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
        const version = value.object.get("v") orelse {
            try testing.expectEqualStrings("ev1", value.object.get("run_id").?.string);
            try testing.expect(lines.next() == null);
            break;
        };
        try testing.expectEqual(@as(i64, 1), version.integer);
        const data = value.object.get("data").?.object;
        const snapshot = if (data.get("snapshot")) |inner| inner.object else data;
        try testing.expectEqualStrings("ev1", snapshot.get("run_id").?.string);
        try testing.expectEqualStrings("Add feature.txt containing feature.", snapshot.get("goal").?.string);
        const w = &transcript.writer;
        try w.print("{s}", .{value.object.get("type").?.string});
        if (data.get("change")) |change| {
            const from = change.object.get("from").?;
            try w.print(" {s} {s}>{s}", .{ if (change.object.get("seat")) |seat| seat.string else "phase", if (from == .string) from.string else "-", change.object.get("to").?.string });
        }
        try w.print(" @{s} {d}/{d}\n", .{ snapshot.get("phase").?.string, snapshot.get("done").?.integer, snapshot.get("total").?.integer });
    }
    try testing.expectEqualStrings(
        \\teamwork.snapshot @approved 0/0
        \\teamwork.event implementer-1 ->queued @approved 0/1
        \\teamwork.event phase approved>implementing @implementing 0/1
        \\teamwork.event implementer-1 queued>working @implementing 0/1
        \\teamwork.event implementer-1 working>failed @implementing 0/1
        \\teamwork.event phase implementing>failed @failed 0/1
        \\
    , transcript.written());
}

const fake_claude =
    \\#!/bin/sh
    \\case "$1" in
    \\--version) echo '2.1.323 (Claude Code)'; exit 0 ;;
    \\--help) echo '--print --output-format stream-json --verbose --add-dir --permission-mode acceptEdits dontAsk --permission-prompts host none --no-session-persistence --model --effort --max-budget-usd --append-system-prompt --strict-mcp-config --mcp-config'; exit 0 ;;
    \\esac
    \\seat=''; prev=''
    \\for arg in "$@"; do
    \\  if [ "$prev" = '--add-dir' ]; then seat="$arg"; fi
    \\  prev="$arg"
    \\done
    \\case "$seat" in
    \\*interviewer-*)
    \\  printf 'interview workspace\n' > interview-scratch.txt
    \\  if [ -f slow-interview ]; then
    \\    : > "$seat/started"
    \\    sleep 30
    \\    : > "$seat/finished"
    \\  fi
    \\  cat > "$seat/handoff.md" <<'HANDOFF'
    \\## Observation
    \\o
    \\## Reasoning
    \\r
    \\## Caveats
    \\c
    \\## Conclusion
    \\Create feature.txt.
    \\## Verification
    \\test -f feature.txt
    \\HANDOFF
    \\  ;;
    \\esac
    \\echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.1}'
    \\
;

fn replSession(c: *Case, url: []const u8, input: []const u8) !cc.tools_common.SpawnOut {
    const raw = std.c.getenv("METACODES_TEST_CLI_BIN") orelse return error.SkipZigTest;
    const a = c.arena.allocator();
    const home = try std.fmt.allocPrint(a, "HOME={s}", .{c.root});
    const tmp = try std.fmt.allocPrint(a, "TMPDIR={s}", .{c.root});
    return c.spawnInput(&.{ "/usr/bin/env", "-u", "METACODES_PROVIDER", "-u", "METACODES_MODEL", "-u", "METACODES_CONFIG_FILE", "-u", "METASK_API_KEY", "-u", "METASK_GATEWAY_URL", home, tmp, "METACODES_NO_PROBE=1", "METACODES_KG_AUTOSTART=0", "METACODES_JEV_URL=off", std.mem.span(raw), "--state-dir", c.state, "--api-key", "fixture-key", "--model", "fixture", "--base-url", url }, input);
}

fn onlyRun(c: *Case) ![]const u8 {
    var dir = try c.tmp.dir.openDir(testing.io, "state/teamwork", .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    const entry = (try it.next(testing.io)) orelse return error.NoRun;
    const name = try c.arena.allocator().dupe(u8, entry.name);
    try testing.expect((try it.next(testing.io)) == null);
    return std.fmt.allocPrint(c.arena.allocator(), "state/teamwork/{s}", .{name});
}

fn replCase(c: *Case) ![]const u8 {
    const a = c.arena.allocator();
    try c.write("claude-fixture", fake_claude);
    const binary = try std.fmt.allocPrintSentinel(a, "{s}/claude-fixture", .{c.root}, 0);
    try testing.expectEqual(@as(c_int, 0), pfs.chmod(binary, 0o755));
    const global = try std.fmt.allocPrint(a,
        \\{{"preview":{{"teamwork":true}},"teamwork":{{"budget_usd":2,"max_rounds":1,"seats":{{"interviewer":{{"harness":"claude_code","command":"{s}"}},"implementer":{{"harness":"claude_code","command":"{s}"}}}}}}}}
    , .{ binary, binary });
    try c.write("state/config.json", global);
    return binary;
}

test "teamwork REPL L2: a rejected interview starts nothing; an edited approval is ORIGINAL_REQUEST byte for byte" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    const a = c.arena.allocator();
    var server = try harness.MockServer.startCassette(&.{}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    _ = try replCase(&c);

    const rejected = try replSession(&c, url, "/teamwork Add feature.txt\nn\n");
    if (std.mem.indexOf(u8, rejected.stderr, "SandboxUnavailable") != null) return;
    try testing.expect(std.mem.indexOf(u8, rejected.stderr, "Create feature.txt.\n\n## Acceptance checks\n\ntest -f feature.txt") != null);
    try testing.expect(std.mem.indexOf(u8, rejected.stderr, "Rejected. Nothing was started") != null);
    const run = try onlyRun(&c);
    const packet = try c.read(try std.fmt.allocPrint(a, "{s}/seats/interviewer-1/packet.md", .{run}));
    try testing.expect(std.mem.endsWith(u8, packet, "## Request\n\nAdd feature.txt"));
    try testing.expect(std.mem.indexOf(u8, packet, c.root) == null);
    for ([_][]const u8{ "ORIGINAL_REQUEST.md", "run.json", "worktree", "interview", "seats/implementer-1", "seats/reviewer-1" }) |rel|
        try testing.expect(!try c.exists(try std.fmt.allocPrint(a, "{s}/{s}", .{ run, rel })));
    try testing.expect(!try c.exists("repo/interview-scratch.txt"));
    try testing.expectEqual(@as(usize, 0), server.requestCount());
    try c.tmp.dir.deleteTree(testing.io, "state/teamwork");

    const edited = "Ship feature.txt holding the word \"feature\".  ";
    const approved = try replSession(&c, url, "/teamwork Add feature.txt\nmaybe\ne\n" ++ edited ++ "\ny\n");
    try testing.expect(std.mem.indexOf(u8, approved.stderr, "has started in the background") != null);
    const started = try onlyRun(&c);
    try testing.expectEqualStrings(edited, try c.read(try std.fmt.allocPrint(a, "{s}/ORIGINAL_REQUEST.md", .{started})));
    const saved = try std.json.parseFromSliceLeaky(std.json.Value, a, try c.read(try std.fmt.allocPrint(a, "{s}/run.json", .{started})), .{});
    try testing.expectEqualStrings("user_edited", saved.object.get("request_source").?.string);
    try testing.expect(!try c.exists("repo/interview-scratch.txt"));
    try c.tmp.dir.deleteTree(testing.io, "state/teamwork");

    const skipped = try replSession(&c, url, "/teamwork [skip-interview] Add feature.txt\ny\n");
    try testing.expect(std.mem.indexOf(u8, skipped.stderr, "Approving also authorizes spend up to $2") != null);
    try testing.expect(std.mem.indexOf(u8, skipped.stderr, "has started in the background") != null);
    const direct = try onlyRun(&c);
    try testing.expectEqualStrings("Add feature.txt", try c.read(try std.fmt.allocPrint(a, "{s}/ORIGINAL_REQUEST.md", .{direct})));
    try testing.expect(!try c.exists(try std.fmt.allocPrint(a, "{s}/seats/interviewer-1", .{direct})));
    const direct_state = try std.json.parseFromSliceLeaky(std.json.Value, a, try c.read(try std.fmt.allocPrint(a, "{s}/run.json", .{direct})), .{});
    try testing.expectEqualStrings("skip_interview", direct_state.object.get("request_source").?.string);
}

test "teamwork REPL L2: with the teamwork preview feature off /teamwork is refused and never becomes a model turn" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    var server = try harness.MockServer.startCassette(&.{}, 0);
    defer server.stop();
    const url = try server.urlOwned(c.arena.allocator());
    try c.write("state/config.json", "{\"preview\":{\"execute_code\":true,\"comment_guard\":true},\"teamwork\":{\"budget_usd\":2}}");
    const out = try replSession(&c, url, "/teamwork Add feature.txt\n");
    try testing.expect(std.mem.indexOf(u8, out.stderr, "/teamwork is a preview feature and it is off. Start metacodes with --preview=teamwork") != null);
    try testing.expectEqual(@as(usize, 0), server.requestCount());
    try testing.expect(!try c.exists("state/teamwork"));
}

test "teamwork REPL L2: Ctrl+C cancels a running interview and the next message still runs" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    const a = c.arena.allocator();
    const raw = std.c.getenv("METACODES_TEST_CLI_BIN") orelse return error.SkipZigTest;
    const reply = start ++ "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"hello back\"}}\n\n" ++ stop;
    var server = try harness.MockServer.startCassette(&.{reply}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    _ = try replCase(&c);
    try c.write("repo/slow-interview", "");
    const err_file = try c.tmp.dir.createFile(testing.io, "repl.err", .{});
    const home = try std.fmt.allocPrint(a, "HOME={s}", .{c.root});
    const tmp = try std.fmt.allocPrint(a, "TMPDIR={s}", .{c.root});
    var child = try std.process.spawn(testing.io, .{
        .argv = &.{ "/usr/bin/env", "-u", "METACODES_PROVIDER", "-u", "METACODES_MODEL", "-u", "METACODES_CONFIG_FILE", "-u", "METASK_API_KEY", "-u", "METASK_GATEWAY_URL", home, tmp, "METACODES_NO_PROBE=1", "METACODES_KG_AUTOSTART=0", "METACODES_JEV_URL=off", std.mem.span(raw), "--state-dir", c.state, "--api-key", "fixture-key", "--model", "fixture", "--base-url", url },
        .cwd = .{ .path = c.repo },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .{ .file = err_file },
    });
    defer child.kill(testing.io);
    err_file.close(testing.io);
    try child.stdin.?.writeStreamingAll(testing.io, "/teamwork Add feature.txt\n");
    const run = waitForRun: {
        var waited: usize = 0;
        while (waited < 600) : (waited += 1) {
            if (c.exists("state/teamwork") catch false) {
                const found = onlyRun(&c) catch null;
                if (found) |dir| if (try c.exists(try std.fmt.allocPrint(a, "{s}/seats/interviewer-1/started", .{dir}))) break :waitForRun dir;
            }
            if (try outputHas(&c, "SandboxUnavailable")) return;
            try std.Io.sleep(testing.io, .fromMilliseconds(50), .awake);
        }
        return error.InterviewNeverStarted;
    };
    try std.posix.kill(child.id.?, std.posix.SIG.INT);
    var waited: usize = 0;
    while (!try outputHas(&c, "The interview was cancelled.")) : (waited += 1) {
        if (waited > 600) return error.InterviewNotCancelled;
        try std.Io.sleep(testing.io, .fromMilliseconds(50), .awake);
    }
    try child.stdin.?.writeStreamingAll(testing.io, "hello\n");
    child.stdin.?.close(testing.io);
    child.stdin = null;
    _ = try child.wait(testing.io);
    try testing.expectEqual(@as(usize, 1), server.requestCount());
    for ([_][]const u8{ "ORIGINAL_REQUEST.md", "run.json", "interview", "seats/implementer-1", "seats/interviewer-1/finished" }) |rel|
        try testing.expect(!try c.exists(try std.fmt.allocPrint(a, "{s}/{s}", .{ run, rel })));
}

fn outputHas(c: *Case, needle: []const u8) !bool {
    const text = c.read("repl.err") catch return false;
    return std.mem.indexOf(u8, text, needle) != null;
}
