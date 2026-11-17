//! Bounded EDGs, persistent guarded reuse and native callback certificates.
//! This controller only supplies literal ToolUse values to AgentLoop's existing
//! dispatcher. It neither executes tools nor replaces any native admission.
const std = @import("std");
const pfs = @import("platform").fs;
const msg = @import("message.zig");
const json = @import("../json.zig");
const args = @import("../tools/common.zig");

pub const OPEN = "<HARNESSMM_PLAN>";
pub const CLOSE = "</HARNESSMM_PLAN>";
pub const AUTHOR_MARKER = "<harnessmm-authoring>";
pub const MAX_PLAN_BYTES = 16384;
pub const MAX_NODES = 8;
pub const MAX_ARGUMENT_BYTES = 4096;
pub const MAX_RECEIPT_BYTES = 128 * 1024;
pub const JOURNAL_NAME = "harnessmm.jsonl";
pub const AUTHOR_PROMPT = AUTHOR_MARKER ++
    "\nWhen the native Bash tool is available, you may author an episode-local executable decision graph " ++
    "before a SINGLE root Bash call. Only store useful future calls whose complete native arguments " ++
    "are already determined from the task and prior observations. Emit in assistant text: " ++
    OPEN ++ "{\"schema_version\":1,\"root\":{\"tool\":\"Bash\",\"arguments\":{\"command\":\"the exact root command\"}}," ++
    "\"nodes\":[{\"id\":\"A\",\"after\":\"root\",\"tool\":\"Bash\",\"arguments\":{\"command\":\"an already decided successor\"}," ++
    "\"guard\":{\"kind\":\"exit_zero\"}}]}" ++ CLOSE ++
    "\nThen issue the root through the ordinary native tool. Root arguments must match exactly, including " ++
    "all supplied fields and their order. Up to 8 nodes; after is root or an earlier node ID. " ++
    "Guards are exit_zero, stdout_equals or stdout_contains; the latter two require a nonempty literal. " ++
    "Every guard also requires a successful native exit. Do not execute future calls inside the root, " ++
    "predict receipts, add unresolved placeholders, request background execution or author unnecessary work. " ++
    "An empty nodes array is valid when new reasoning is needed. Native permissions and task limits still apply. " ++
    "Unsupported observations or ambiguous candidates return control to you.\n</harnessmm-authoring>";

const ActionWire = struct { tool: []const u8, arguments: std.json.Value };
const GuardWire = struct { kind: enum { exit_zero, stdout_equals, stdout_contains }, literal: ?[]const u8 = null };
const NodeWire = struct { id: []const u8, after: []const u8, tool: []const u8, arguments: std.json.Value, guard: GuardWire };
const GraphWire = struct { schema_version: u32, root: ActionWire, nodes: []const NodeWire };
const Parent = union(enum) { root, node: usize };
const Guard = union(enum) { exit_zero, stdout_equals: []const u8, stdout_contains: []const u8 };
const Readiness = enum { waiting, eligible, ineligible, dispatched };
const Node = struct {
    id: []const u8,
    after: Parent,
    arguments: []const u8,
    call_id: []const u8,
    guard: Guard,
    readiness: Readiness = .waiting,
    predecessor_receipt_sha256: [64]u8 = undefined,
    predecessor_call_id: []const u8 = "",
};
const Awaiting = union(enum) { root, node: usize, none };
const Graph = struct {
    sha256: [64]u8,
    root_call_id: []const u8,
    nodes: []Node,
    awaiting: Awaiting = .root,
    last_call_id: []const u8 = "",
    last_receipt_sha256: [64]u8 = undefined,
};

pub fn sha256(bytes: []const u8) [64]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}

pub const Certificate = struct {
    arena: std.heap.ArenaAllocator,
    value: struct {
        schema: []const u8 = "metacodes-harnessmm-substitution-v1",
        graph_sha256: []const u8,
        root_call_id: []const u8,
        decision_id: []const u8,
        predecessor_call_id: []const u8,
        predecessor_receipt_sha256: []const u8,
        tool: []const u8 = "Bash",
        arguments_json: []const u8,
        arguments_sha256: []const u8,
        native_call_id: []const u8,
        native_receipt_sha256: []const u8,
        native_receipt_is_error: bool,
        guard_kind: []const u8,
        guard_literal: ?[]const u8,
        omitted_callback_turn: u32,
    },

    pub fn deinit(self: *Certificate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Journal = struct {
    fd: c_int,

    pub fn open(gpa: std.mem.Allocator, root: []const u8) !Journal {
        if (root.len == 0 or !std.fs.path.isAbsolute(root)) return error.HarnessMMNeedsArtifactRoot;
        const path = try std.fs.path.join(gpa, &.{ root, JOURNAL_NAME });
        defer gpa.free(path);
        const path_z = try gpa.dupeZ(u8, path);
        defer gpa.free(path_z);
        const fd = pfs.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return error.HarnessMMJournalUnavailable;
        errdefer _ = pfs.close(fd);
        try pfs.fsyncChecked(fd);
        return .{ .fd = fd };
    }

    pub fn append(self: Journal, gpa: std.mem.Allocator, certificate: *const Certificate) !void {
        const bytes = try std.json.Stringify.valueAlloc(gpa, certificate.value, .{});
        defer gpa.free(bytes);
        if (!pfs.writeAll(self.fd, bytes) or !pfs.writeAll(self.fd, "\n")) return error.HarnessMMJournalWriteFailed;
        try pfs.fsyncChecked(self.fd);
    }

    pub fn deinit(self: *Journal) void {
        _ = pfs.close(self.fd);
        self.* = undefined;
    }
};

pub const State = struct {
    gpa: std.mem.Allocator,
    arena: ?std.heap.ArenaAllocator = null,
    graph: ?Graph = null,

    pub fn init(gpa: std.mem.Allocator) State {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *State) void {
        self.clear();
    }

    pub fn clear(self: *State) void {
        self.graph = null;
        if (self.arena) |*arena| arena.deinit();
        self.arena = null;
    }

    /// Only a freshly committed slow-actor response may author a graph.
    /// Tool outputs, host notes and historical plans are never authors.
    pub fn admit(self: *State, message: msg.Message) !void {
        self.clear();
        if (message.role != .assistant or message.origin != .participant) return;
        var root: ?msg.ToolUse = null;
        var text: ?[]const u8 = null;
        for (message.blocks) |block| switch (block) {
            .tool_use => |tool| {
                if (root != null) return;
                root = tool;
            },
            .text => |bytes| {
                if (std.mem.indexOf(u8, bytes, OPEN) != null) {
                    if (text != null) return;
                    text = bytes;
                }
            },
            else => {},
        };
        const tool = root orelse return;
        const body = planBody(text orelse return) orelse return;
        if (!std.mem.eql(u8, tool.name, "Bash") or tool.id.len == 0 or tool.id.len > 256) return;
        self.install(body, tool) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => self.clear(),
        };
    }

    fn install(self: *State, body: []const u8, root: msg.ToolUse) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const parsed = try std.json.parseFromSlice(GraphWire, a, body, .{ .allocate = .alloc_always });
        const wire = parsed.value;
        if (wire.schema_version != 1 or wire.nodes.len == 0 or wire.nodes.len > MAX_NODES or
            !std.mem.eql(u8, wire.root.tool, "Bash")) return error.InvalidEDG;
        const root_args = try literalArguments(a, wire.root.arguments);
        if (!try args.sameArgs(a, root_args, root.input)) return error.EDGRootMismatch;
        const nodes = try a.alloc(Node, wire.nodes.len);
        const root_id = try a.dupe(u8, root.id);
        const graph_sha = sha256(body);
        for (wire.nodes, 0..) |node, i| {
            if (!validId(node.id) or std.mem.eql(u8, node.id, "root") or !std.mem.eql(u8, node.tool, "Bash")) return error.InvalidEDG;
            var parent: Parent = .root;
            if (!std.mem.eql(u8, node.after, "root")) {
                var predecessor: ?usize = null;
                for (nodes[0..i], 0..) |previous, j| if (std.mem.eql(u8, previous.id, node.after)) {
                    predecessor = j;
                    break;
                };
                parent = .{ .node = predecessor orelse return error.InvalidEDGDependency };
            }
            for (nodes[0..i]) |previous| if (std.mem.eql(u8, previous.id, node.id)) return error.DuplicateEDGDecision;
            const guard: Guard = switch (node.guard.kind) {
                .exit_zero => if (node.guard.literal != null) return error.InvalidEDGGuard else .exit_zero,
                .stdout_equals, .stdout_contains => blk: {
                    const value = node.guard.literal orelse return error.InvalidEDGGuard;
                    if (value.len == 0 or value.len > 1024) return error.InvalidEDGGuard;
                    break :blk if (node.guard.kind == .stdout_equals) .{ .stdout_equals = value } else .{ .stdout_contains = value };
                },
            };
            const binding = try std.mem.concat(a, u8, &.{ root_id, "\x00", &graph_sha, "\x00", node.id });
            const call_hash = sha256(binding);
            nodes[i] = .{
                .id = node.id,
                .after = parent,
                .guard = guard,
                .arguments = try literalArguments(a, node.arguments),
                .call_id = try std.fmt.allocPrint(a, "hmm_{s}", .{call_hash[0..32]}),
            };
        }
        self.arena = arena;
        self.graph = .{ .sha256 = graph_sha, .root_call_id = root_id, .nodes = nodes };
    }

    /// The original dispatcher receives this exact literal ToolUse. Eligibility
    /// reads the last *actual* receipt, never a predicted return or rewritten history.
    pub fn next(self: *State, last: msg.Message, tools: []const json.ToolDefinition) ?msg.ToolUse {
        const graph = if (self.graph) |*value| value else return null;
        if (last.role != .user or last.blocks.len != 1 or last.blocks[0] != .tool_result or graph.awaiting != .none) {
            self.clear();
            return null;
        }
        const receipt = last.blocks[0].tool_result;
        if (!std.mem.eql(u8, receipt.tool_use_id, graph.last_call_id) or
            !std.mem.eql(u8, &sha256(receipt.content), &graph.last_receipt_sha256))
        {
            self.clear();
            return null;
        }
        var visible = false;
        for (tools) |tool| if (std.mem.eql(u8, tool.name, "Bash")) {
            visible = true;
            break;
        };
        if (!visible) {
            self.clear();
            return null;
        }
        var selected: ?usize = null;
        for (graph.nodes, 0..) |node, i| if (node.readiness == .eligible) {
            if (selected != null) {
                self.clear();
                return null;
            }
            selected = i;
        };
        const index = selected orelse {
            self.clear();
            return null;
        };
        graph.nodes[index].readiness = .dispatched;
        graph.awaiting = .{ .node = index };
        return .{ .id = graph.nodes[index].call_id, .name = "Bash", .input = graph.nodes[index].arguments };
    }

    /// One certificate per substituted native action, including native refusals
    /// and failed attempts. Unsupported receipts stop reuse but never erase a call.
    pub fn observe(self: *State, message: msg.Message, turn: u32) !?Certificate {
        const graph = if (self.graph) |*value| value else return null;
        const expected = switch (graph.awaiting) {
            .root => graph.root_call_id,
            .node => |i| graph.nodes[i].call_id,
            .none => return null,
        };
        var receipt: ?msg.ToolResult = null;
        for (message.blocks) |block| if (block == .tool_result and std.mem.eql(u8, block.tool_result.tool_use_id, expected)) {
            if (receipt != null) {
                self.clear();
                return null;
            }
            receipt = block.tool_result;
        };
        const actual = receipt orelse {
            self.clear();
            return null;
        };
        const parent = graph.awaiting;
        const receipt_hash = sha256(actual.content);
        var certificate: ?Certificate = if (parent == .node)
            try self.makeCertificate(parent.node, actual, receipt_hash, turn)
        else
            null;
        errdefer if (certificate) |*record| record.deinit();
        if (actual.is_error or actual.content.len > MAX_RECEIPT_BYTES or message.blocks.len != 1) {
            self.clear();
            return certificate;
        }
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const parsed = std.json.parseFromSlice(std.json.Value, scratch.allocator(), actual.content, .{}) catch {
            self.clear();
            return certificate;
        };
        if (parsed.value != .object) {
            self.clear();
            return certificate;
        }
        const fields = parsed.value.object;
        const schema = fields.get("schema_version") orelse {
            self.clear();
            return certificate;
        };
        const exit = fields.get("exit_code") orelse {
            self.clear();
            return certificate;
        };
        if (schema != .string or !std.mem.eql(u8, schema.string, "metacodes.bash-result.v2") or exit != .integer or exit.integer != 0) {
            self.clear();
            return certificate;
        }
        graph.awaiting = .none;
        graph.last_call_id = expected;
        graph.last_receipt_sha256 = receipt_hash;
        for (graph.nodes) |*node| {
            const follows = switch (node.after) {
                .root => parent == .root,
                .node => |i| parent == .node and parent.node == i,
            };
            if (!follows or node.readiness != .waiting) continue;
            const admitted = evaluateGuard(node.guard, fields) orelse {
                self.clear();
                return certificate;
            };
            node.readiness = if (admitted) .eligible else .ineligible;
            node.predecessor_receipt_sha256 = receipt_hash;
            node.predecessor_call_id = expected;
        }
        return certificate;
    }

    fn makeCertificate(self: *State, index: usize, receipt: msg.ToolResult, receipt_hash: [64]u8, turn: u32) !Certificate {
        const graph = &self.graph.?;
        const node = graph.nodes[index];
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const arg_hash = sha256(node.arguments);
        var certificate: Certificate = undefined;
        certificate.value = .{
            .graph_sha256 = try a.dupe(u8, &graph.sha256),
            .root_call_id = try a.dupe(u8, graph.root_call_id),
            .decision_id = try a.dupe(u8, node.id),
            .predecessor_call_id = try a.dupe(u8, node.predecessor_call_id),
            .predecessor_receipt_sha256 = try a.dupe(u8, &node.predecessor_receipt_sha256),
            .arguments_json = try a.dupe(u8, node.arguments),
            .arguments_sha256 = try a.dupe(u8, &arg_hash),
            .native_call_id = try a.dupe(u8, receipt.tool_use_id),
            .native_receipt_sha256 = try a.dupe(u8, &receipt_hash),
            .native_receipt_is_error = receipt.is_error,
            .guard_kind = @tagName(node.guard),
            .guard_literal = switch (node.guard) {
                .exit_zero => null,
                .stdout_equals, .stdout_contains => |value| try a.dupe(u8, value),
            },
            .omitted_callback_turn = turn,
        };
        certificate.arena = arena;
        return certificate;
    }
};

fn planBody(text: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, text, OPEN) orelse return null) + OPEN.len;
    const end = start + (std.mem.indexOf(u8, text[start..], CLOSE) orelse return null);
    if (end - start > MAX_PLAN_BYTES or std.mem.indexOf(u8, text[start..], OPEN) != null or
        std.mem.indexOf(u8, text[end + CLOSE.len ..], CLOSE) != null) return null;
    return text[start..end];
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 32) return false;
    for (id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn literalArguments(a: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    if (value != .object) return error.InvalidEDGArguments;
    const command = value.object.get("command") orelse return error.InvalidEDGArguments;
    if (command != .string or command.string.len == 0) return error.InvalidEDGArguments;
    if (value.object.get("run_in_background")) |background| {
        if (background != .bool or background.bool) return error.UnsupportedEDGBackground;
    }
    const encoded = try std.json.Stringify.valueAlloc(a, value, .{});
    if (encoded.len > MAX_ARGUMENT_BYTES) return error.InvalidEDGArguments;
    return try args.canonicalizeArgs(a, encoded);
}

fn evaluateGuard(guard: Guard, fields: std.json.ObjectMap) ?bool {
    if (guard == .exit_zero) return true;
    const stdout = fields.get("stdout") orelse return null;
    const encoding = fields.get("stdout_encoding") orelse return null;
    const truncated = fields.get("stdout_truncated") orelse return null;
    const complete = fields.get("stdout_capture_complete") orelse return null;
    if (stdout != .string or encoding != .string or !std.mem.eql(u8, encoding.string, "utf-8") or
        truncated != .bool or truncated.bool or complete != .bool or !complete.bool) return null;
    return switch (guard) {
        .exit_zero => unreachable,
        .stdout_equals => |literal| std.mem.eql(u8, stdout.string, literal),
        .stdout_contains => |literal| std.mem.indexOf(u8, stdout.string, literal) != null,
    };
}

const TEST_PLAN = OPEN ++
    "{\"schema_version\":1,\"root\":{\"tool\":\"Bash\",\"arguments\":{\"command\":\"printf root\"}},\"nodes\":[" ++
    "{\"id\":\"A\",\"after\":\"root\",\"tool\":\"Bash\",\"arguments\":{\"command\":\"printf one\"},\"guard\":{\"kind\":\"stdout_equals\",\"literal\":\"root\"}}," ++
    "{\"id\":\"B\",\"after\":\"A\",\"tool\":\"Bash\",\"arguments\":{\"command\":\"printf two\"},\"guard\":{\"kind\":\"exit_zero\"}}]}" ++ CLOSE;
const TEST_RECEIPT = "{\"schema_version\":\"metacodes.bash-result.v2\",\"exit_code\":0,\"stdout\":\"root\",\"stdout_encoding\":\"utf-8\",\"stdout_truncated\":false,\"stdout_capture_complete\":true}";

fn admitTestPlan(state: *State, plan: []const u8) !void {
    var blocks = [_]msg.Block{
        .{ .text = plan },
        .{ .tool_use = .{ .id = "root_call", .name = "Bash", .input = "{\"command\":\"printf root\"}" } },
    };
    try state.admit(.{ .role = .assistant, .blocks = &blocks });
}

test "HarnessMM reuses one EDG across native receipts and binds two omitted callbacks" {
    const a = std.testing.allocator;
    var state = State.init(a);
    defer state.deinit();
    try admitTestPlan(&state, TEST_PLAN);
    try std.testing.expect(state.graph != null);
    var root_blocks = [_]msg.Block{.{ .tool_result = .{ .tool_use_id = "root_call", .content = TEST_RECEIPT } }};
    const root_message = msg.Message{ .role = .user, .blocks = &root_blocks };
    try std.testing.expect(try state.observe(root_message, 1) == null);
    const tools = [_]json.ToolDefinition{.{ .name = "Bash", .description = "native", .input_schema = .{} }};
    const first = state.next(root_message, &tools) orelse return error.NoFirstReuse;
    try std.testing.expectEqualStrings("{\"command\":\"printf one\"}", first.input);
    var first_blocks = [_]msg.Block{.{ .tool_result = .{ .tool_use_id = first.id, .content = TEST_RECEIPT } }};
    const first_message = msg.Message{ .role = .user, .blocks = &first_blocks };
    var cert1 = (try state.observe(first_message, 2)) orelse return error.NoCertificate;
    defer cert1.deinit();
    try std.testing.expectEqualStrings("root_call", cert1.value.predecessor_call_id);
    try std.testing.expectEqualStrings(&sha256(TEST_RECEIPT), cert1.value.predecessor_receipt_sha256);
    try std.testing.expectEqual(@as(u32, 2), cert1.value.omitted_callback_turn);
    const second = state.next(first_message, &tools) orelse return error.NoPersistentReuse;
    try std.testing.expectEqualStrings("{\"command\":\"printf two\"}", second.input);
    var second_blocks = [_]msg.Block{.{ .tool_result = .{ .tool_use_id = second.id, .content = TEST_RECEIPT, .is_error = true } }};
    var cert2 = (try state.observe(.{ .role = .user, .blocks = &second_blocks }, 3)) orelse return error.NoCertificate;
    defer cert2.deinit();
    try std.testing.expect(cert2.value.native_receipt_is_error);
    try std.testing.expect(state.graph == null);
    // Certificates own their data even after the graph was rejected/freed.
    try std.testing.expectEqualStrings("A", cert1.value.decision_id);
    try std.testing.expectEqualStrings("B", cert2.value.decision_id);
    try std.testing.expectEqualStrings(cert1.value.native_call_id, cert2.value.predecessor_call_id);
}

test "HarnessMM new context, unsupported receipts and hidden native tools defer" {
    const a = std.testing.allocator;
    const tools = [_]json.ToolDefinition{.{ .name = "Bash", .description = "native", .input_schema = .{} }};
    var state = State.init(a);
    defer state.deinit();
    for ([_][]const u8{ "{}", "{\"schema_version\":\"metacodes.bash-result.v2\",\"exit_code\":1}" }) |bad| {
        try admitTestPlan(&state, TEST_PLAN);
        var blocks = [_]msg.Block{.{ .tool_result = .{ .tool_use_id = "root_call", .content = bad } }};
        try std.testing.expect(try state.observe(.{ .role = .user, .blocks = &blocks }, 1) == null);
        try std.testing.expect(state.graph == null);
    }
    try admitTestPlan(&state, TEST_PLAN);
    var root = [_]msg.Block{.{ .tool_result = .{ .tool_use_id = "root_call", .content = TEST_RECEIPT } }};
    const receipt = msg.Message{ .role = .user, .blocks = &root };
    _ = try state.observe(receipt, 1);
    try std.testing.expect(state.next(receipt, &.{}) == null);
    try admitTestPlan(&state, TEST_PLAN);
    _ = try state.observe(receipt, 1);
    var context = [_]msg.Block{.{ .text = "new user decision" }};
    try std.testing.expect(state.next(.{ .role = .user, .blocks = &context }, &tools) == null);
    try std.testing.expectError(error.HarnessMMNeedsArtifactRoot, Journal.open(a, ""));
}

test "HarnessMM rejects invalid graph dependencies, root mismatches and background actions" {
    const cases = [_][]const u8{
        OPEN ++ "{\"schema_version\":1,\"root\":{\"tool\":\"Bash\",\"arguments\":{\"command\":\"other\"}},\"nodes\":[{\"id\":\"A\",\"after\":\"root\",\"tool\":\"Bash\",\"arguments\":{\"command\":\"x\"},\"guard\":{\"kind\":\"exit_zero\"}}]}" ++ CLOSE,
        OPEN ++ "{\"schema_version\":1,\"root\":{\"tool\":\"Bash\",\"arguments\":{\"command\":\"printf root\"}},\"nodes\":[{\"id\":\"A\",\"after\":\"A\",\"tool\":\"Bash\",\"arguments\":{\"command\":\"x\"},\"guard\":{\"kind\":\"exit_zero\"}}]}" ++ CLOSE,
        OPEN ++ "{\"schema_version\":1,\"root\":{\"tool\":\"Bash\",\"arguments\":{\"command\":\"printf root\"}},\"nodes\":[{\"id\":\"A\",\"after\":\"root\",\"tool\":\"Bash\",\"arguments\":{\"command\":\"x\",\"run_in_background\":true},\"guard\":{\"kind\":\"exit_zero\"}}]}" ++ CLOSE,
    };
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    for (cases) |plan| {
        try admitTestPlan(&state, plan);
        try std.testing.expect(state.graph == null);
    }
}
