//! L2: a real Write followed by a real successful test produces one late
//! progress checkpoint in the next provider request. The stable first request
//! remains identical across the opt-in treatment and disabled control.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

/// 让 fixture 脚本可执行。
///
/// Windows 上 `_chmod` 只切换只读位,`#!/bin/sh` 脚本照样跑不起来,原来的
/// `chmod != 0` 守卫因此不触发:脚本静默不执行,断言退化成假绿(断言"没出现某
/// 文本"的用例会无条件通过)。所以在那里直接跳过,让结果诚实。
fn makeExecutable(path_z: [:0]const u8) !void {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    if (std.c.chmod(path_z.ptr, 0o700) != 0) return error.SkipZigTest;
}

const END_TURN =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"done\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn toolSse(allocator: std.mem.Allocator, id: []const u8, name: []const u8, input: []const u8) ![]u8 {
    var escaped: std.Io.Writer.Allocating = .init(allocator);
    defer escaped.deinit();
    try std.json.Stringify.encodeJsonString(input, .{}, &escaped.writer);
    const encoded = try escaped.toOwnedSlice();
    defer allocator.free(encoded);
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_{s}\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{ id, id, name, encoded },
    );
}

const RunCapture = struct {
    first: []u8,
    after_test: []u8,
    requests: usize,
    final_file: []u8,

    fn deinit(self: *RunCapture, allocator: std.mem.Allocator) void {
        allocator.free(self.first);
        allocator.free(self.after_test);
        allocator.free(self.final_file);
    }
};

fn successfulTestCommand(
    allocator: std.mem.Allocator,
    root: []const u8,
) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/pytest", .{root});
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = "#!/bin/sh\nprintf '1 passed in 0.01s\\n'\n",
    });
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    try makeExecutable(path_z);
    return allocator.dupe(u8, path);
}

test "CLI verification checkpoint flag is explicit and defaults off" {
    const a = std.testing.allocator;
    const disabled_argv = [_][*:0]const u8{"metacodes"};
    try std.testing.expect(!cc.parseArgsForTest(&disabled_argv, a).verification_checkpoint);
    const enabled_argv = [_][*:0]const u8{ "metacodes", "--verification-checkpoint" };
    try std.testing.expect(cc.parseArgsForTest(&enabled_argv, a).verification_checkpoint);
}

fn runScenario(
    allocator: std.mem.Allocator,
    root: []const u8,
    enabled: bool,
    test_command: []const u8,
    extra_edit_after_green: bool,
) !RunCapture {
    const path = try std.fmt.allocPrint(allocator, "{s}/checkpoint.zig", .{root});
    defer allocator.free(path);
    const write_input = try std.fmt.allocPrint(allocator, "{{\"file_path\":\"{s}\",\"content\":\"test \\\"one\\\" {{}}\\n\"}}", .{path});
    defer allocator.free(write_input);
    const bash_input = try std.fmt.allocPrint(allocator, "{{\"command\":\"{s}\"}}", .{test_command});
    defer allocator.free(bash_input);
    const edit_input = try std.fmt.allocPrint(allocator, "{{\"file_path\":\"{s}\",\"old_string\":\"one\",\"new_string\":\"two\"}}", .{path});
    defer allocator.free(edit_input);
    const write_sse = try toolSse(allocator, "write_1", "Write", write_input);
    defer allocator.free(write_sse);
    const bash_sse = try toolSse(allocator, "test_1", "Bash", bash_input);
    defer allocator.free(bash_sse);
    const edit_sse = if (extra_edit_after_green)
        try toolSse(allocator, "edit_1", "Edit", edit_input)
    else
        null;
    defer if (edit_sse) |bytes| allocator.free(bytes);
    const cassette = if (edit_sse) |bytes|
        [_][]const u8{ write_sse, bash_sse, bytes, END_TURN }
    else
        [_][]const u8{ write_sse, bash_sse, END_TURN, END_TURN };
    const responses = if (extra_edit_after_green) cassette[0..4] else cassette[0..3];

    var server = try harness.MockServer.startCassette(responses, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);
    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(allocator, io_runtime.io(), "key", "model", url);
    defer client.deinit();
    var conversation = cc.conversation.Conversation.init(allocator);
    defer conversation.deinit();
    try conversation.appendText(.user, "repair the repository");
    var permission = cc.permission.createContext(.bypass_permissions, allocator);
    permission.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(allocator);
    defer allocator.free(defs);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        defs,
        &permission,
        .{
            .max_turns = 8,
            .system_prompt = "STABLE-PREFIX",
            .verification_checkpoint = enabled,
            .cwd_abs = root,
            .home_dir = root,
            .auto_compact_threshold = std.math.maxInt(usize),
        },
        &backend,
        allocator,
    );
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    const first = try allocator.dupe(u8, server.requestAt(0).?.body());
    errdefer allocator.free(first);
    const after_test = try allocator.dupe(u8, server.requestAt(2).?.body());
    errdefer allocator.free(after_test);
    const final_file = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(64),
    );
    return .{
        .first = first,
        .after_test = after_test,
        .requests = server.requestCount(),
        .final_file = final_file,
    };
}

test "L2 post-mutation green test injects one checkpoint without first-request drift" {
    const a = std.testing.allocator;
    var control_tmp = std.testing.tmpDir(.{});
    defer control_tmp.cleanup();
    var treatment_tmp = std.testing.tmpDir(.{});
    defer treatment_tmp.cleanup();
    var control_buf: [std.fs.max_path_bytes]u8 = undefined;
    var treatment_buf: [std.fs.max_path_bytes]u8 = undefined;
    const control_root = harness.normalizeSlashes(control_buf[0..try control_tmp.dir.realPath(std.testing.io, &control_buf)]);
    const treatment_root = harness.normalizeSlashes(treatment_buf[0..try treatment_tmp.dir.realPath(std.testing.io, &treatment_buf)]);

    const control_command = try successfulTestCommand(a, control_root);
    defer a.free(control_command);
    const treatment_command = try successfulTestCommand(a, treatment_root);
    defer a.free(treatment_command);
    var control = try runScenario(a, control_root, false, control_command, false);
    defer control.deinit(a);
    var treatment = try runScenario(a, treatment_root, true, treatment_command, false);
    defer treatment.deinit(a);
    try std.testing.expectEqualStrings(control.first, treatment.first);
    try std.testing.expect(std.mem.indexOf(u8, treatment.first, "verification checkpoint") == null);
    try std.testing.expect(std.mem.indexOf(u8, control.after_test, "verification checkpoint") == null);
    try std.testing.expect(std.mem.indexOf(u8, treatment.after_test, "verification checkpoint") != null);
}

test "L2 checkpoint recognizes pytest stderr redirect before display-only tail" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)]);
    const pytest_path = try std.fmt.allocPrint(a, "{s}/pytest", .{root});
    defer a.free(pytest_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = pytest_path,
        .data = "#!/bin/sh\nprintf '1 passed in 0.01s\\n'\n",
    });
    const pytest_z = try a.dupeZ(u8, pytest_path);
    defer a.free(pytest_z);
    try makeExecutable(pytest_z);
    const command = try std.fmt.allocPrint(a, "{s} 2>&1 | tail -20", .{pytest_path});
    defer a.free(command);

    var run = try runScenario(a, root, true, command, false);
    defer run.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, run.after_test, "verification checkpoint") != null);
}

test "L2 display-only tail cannot turn a failed pytest summary into progress" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)]);
    const pytest_path = try std.fmt.allocPrint(a, "{s}/pytest", .{root});
    defer a.free(pytest_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = pytest_path,
        .data = "#!/bin/sh\nprintf '1 failed in 0.01s\\n'\nexit 1\n",
    });
    const pytest_z = try a.dupeZ(u8, pytest_path);
    defer a.free(pytest_z);
    try makeExecutable(pytest_z);
    const command = try std.fmt.allocPrint(a, "{s} 2>&1 | tail -20", .{pytest_path});
    defer a.free(command);

    var run = try runScenario(a, root, true, command, false);
    defer run.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, run.after_test, "verification checkpoint") == null);
}

test "L2 failed or ordinary Bash does not trigger checkpoint" {
    const a = std.testing.allocator;
    var failed_tmp = std.testing.tmpDir(.{});
    defer failed_tmp.cleanup();
    var ordinary_tmp = std.testing.tmpDir(.{});
    defer ordinary_tmp.cleanup();
    var failed_buf: [std.fs.max_path_bytes]u8 = undefined;
    var ordinary_buf: [std.fs.max_path_bytes]u8 = undefined;
    const failed_root = harness.normalizeSlashes(failed_buf[0..try failed_tmp.dir.realPath(std.testing.io, &failed_buf)]);
    const ordinary_root = harness.normalizeSlashes(ordinary_buf[0..try ordinary_tmp.dir.realPath(std.testing.io, &ordinary_buf)]);
    var failed = try runScenario(a, failed_root, true, "python3 -m pytest /definitely/missing", false);
    defer failed.deinit(a);
    var ordinary = try runScenario(a, ordinary_root, true, "git status", false);
    defer ordinary.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, failed.after_test, "verification checkpoint") == null);
    try std.testing.expect(std.mem.indexOf(u8, ordinary.after_test, "verification checkpoint") == null);
}

test "L2 checkpoint is steering not a hard stop; a later justified Edit executes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)]);
    const command = try successfulTestCommand(a, root);
    defer a.free(command);
    var run = try runScenario(a, root, true, command, true);
    defer run.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, run.after_test, "verification checkpoint") != null);
    try std.testing.expectEqualStrings("test \"two\" {}\n", run.final_file);
    try std.testing.expectEqual(@as(usize, 4), run.requests);
}
