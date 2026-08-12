//! Bounded, execution-grounded knowledge facts for one `KgClient`.
//!
//! The ledger is deliberately not a transcript. It stores only a stable task
//! id, a small ontology relation and a sanitized label selected by a fixed
//! adapter. Raw tool input, Bash commands, search queries and tool output are
//! never retained. Facts remain candidates until task closure projects them as
//! tentative TinyKG ref edges and a human confirms/corrects them.

const std = @import("std");
const util_json = @import("../util/json.zig");

pub const MAX_FACTS_PER_TASK: usize = 64;
pub const MAX_TOTAL_FACTS: usize = 256;
pub const MAX_LABEL_BYTES: usize = 512;
const MAX_DROP_TASKS: usize = 256;

pub const Relation = enum(u8) {
    acts_on,
    uses,
    produces,

    pub fn label(self: Relation) []const u8 {
        return @tagName(self);
    }
};

pub const RecordResult = enum {
    stored,
    duplicate,
    rejected,
    task_limit,
    total_limit,
    out_of_memory,
};

pub const Fact = struct {
    task_id: u64,
    relation: Relation,
    value: []u8,
};

const DropCount = struct {
    task_id: u64,
    count: usize,
};

pub const Snapshot = struct {
    facts: []Fact,
    dropped: usize,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        for (self.facts) |fact| allocator.free(fact.value);
        allocator.free(self.facts);
        self.* = undefined;
    }
};

pub const Ledger = struct {
    allocator: std.mem.Allocator,
    facts: std.ArrayList(Fact) = .empty,
    drops: std.ArrayList(DropCount) = .empty,

    pub fn init(allocator: std.mem.Allocator) Ledger {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Ledger) void {
        for (self.facts.items) |fact| self.allocator.free(fact.value);
        self.facts.deinit(self.allocator);
        self.drops.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn record(self: *Ledger, task_id: u64, relation: Relation, raw_value: []const u8) RecordResult {
        const value = std.mem.trim(u8, raw_value, " \t\r\n");
        if (task_id == 0 or !validLabel(value)) return .rejected;

        var task_count: usize = 0;
        for (self.facts.items) |fact| {
            if (fact.task_id != task_id) continue;
            task_count += 1;
            if (fact.relation == relation and std.mem.eql(u8, fact.value, value)) return .duplicate;
        }
        if (task_count >= MAX_FACTS_PER_TASK) {
            self.noteDrop(task_id);
            return .task_limit;
        }
        if (self.facts.items.len >= MAX_TOTAL_FACTS) {
            self.noteDrop(task_id);
            return .total_limit;
        }

        const owned = self.allocator.dupe(u8, value) catch {
            self.noteDrop(task_id);
            return .out_of_memory;
        };
        self.facts.append(self.allocator, .{
            .task_id = task_id,
            .relation = relation,
            .value = owned,
        }) catch {
            self.allocator.free(owned);
            self.noteDrop(task_id);
            return .out_of_memory;
        };
        return .stored;
    }

    /// Observe one successful tool invocation. The caller is responsible for
    /// calling this only after authorization and successful execution.
    pub fn observeSuccessfulTool(
        self: *Ledger,
        task_id: u64,
        tool_name: []const u8,
        input_json: []const u8,
        project_dir: []const u8,
    ) void {
        if (methodConcept(tool_name)) |concept| _ = self.record(task_id, .uses, concept);

        const resource = resourceSpec(tool_name) orelse return;
        const raw = util_json.extractStringField(input_json, resource.field) orelse return;
        const unescaped = util_json.unescapeString(raw, self.allocator) catch {
            self.noteDrop(task_id);
            return;
        };
        defer self.allocator.free(unescaped);
        const normalized = normalizeProjectPath(self.allocator, unescaped, project_dir) orelse return;
        defer self.allocator.free(normalized);

        if (resource.acts_on) _ = self.record(task_id, .acts_on, normalized);
        if (resource.produces) _ = self.record(task_id, .produces, normalized);
    }

    pub fn snapshot(self: *const Ledger, allocator: std.mem.Allocator, task_id: u64) !Snapshot {
        var count: usize = 0;
        for (self.facts.items) |fact| if (fact.task_id == task_id) {
            count += 1;
        };
        const out = try allocator.alloc(Fact, count);
        errdefer allocator.free(out);
        var initialized: usize = 0;
        errdefer for (out[0..initialized]) |fact| allocator.free(fact.value);
        for (self.facts.items) |fact| {
            if (fact.task_id != task_id) continue;
            out[initialized] = .{
                .task_id = fact.task_id,
                .relation = fact.relation,
                .value = try allocator.dupe(u8, fact.value),
            };
            initialized += 1;
        }
        return .{ .facts = out, .dropped = self.droppedForTask(task_id) };
    }

    /// Acknowledge one fact only after the graph projection succeeded (or an
    /// identical explicit fact already projected). Failed facts remain for an
    /// idempotent TaskUpdate retry in the same agent session.
    pub fn acknowledge(self: *Ledger, task_id: u64, relation: Relation, value: []const u8) bool {
        for (self.facts.items, 0..) |fact, i| {
            if (fact.task_id != task_id or fact.relation != relation or
                !std.mem.eql(u8, fact.value, value)) continue;
            const removed = self.facts.swapRemove(i);
            self.allocator.free(removed.value);
            return true;
        }
        return false;
    }

    pub fn pendingForTask(self: *const Ledger, task_id: u64) usize {
        var count: usize = 0;
        for (self.facts.items) |fact| if (fact.task_id == task_id) {
            count += 1;
        };
        return count;
    }

    fn noteDrop(self: *Ledger, task_id: u64) void {
        for (self.drops.items) |*entry| {
            if (entry.task_id != task_id) continue;
            entry.count +|= 1;
            return;
        }
        if (self.drops.items.len >= MAX_DROP_TASKS) return;
        self.drops.append(self.allocator, .{ .task_id = task_id, .count = 1 }) catch {};
    }

    fn droppedForTask(self: *const Ledger, task_id: u64) usize {
        for (self.drops.items) |entry| if (entry.task_id == task_id) return entry.count;
        return 0;
    }
};

const ResourceSpec = struct {
    field: []const u8,
    acts_on: bool,
    produces: bool,
};

fn resourceSpec(tool_name: []const u8) ?ResourceSpec {
    if (std.mem.eql(u8, tool_name, "Read"))
        return .{ .field = "file_path", .acts_on = true, .produces = false };
    if (std.mem.eql(u8, tool_name, "Write") or std.mem.eql(u8, tool_name, "Edit"))
        return .{ .field = "file_path", .acts_on = true, .produces = true };
    if (std.mem.eql(u8, tool_name, "NotebookEdit"))
        return .{ .field = "notebook_path", .acts_on = true, .produces = true };
    return null;
}

/// High-signal methods only. Generic Read/Edit/Bash calls would create giant
/// low-information hubs, so their value is represented by sanitized resources
/// rather than a `tool:*` concept. Dynamic/MCP names are not accepted here.
fn methodConcept(tool_name: []const u8) ?[]const u8 {
    const Method = struct { tool: []const u8, concept: []const u8 };
    const methods = [_]Method{
        .{ .tool = "CodeMap", .concept = "tool:CodeMap" },
        .{ .tool = "FindSymbol", .concept = "tool:FindSymbol" },
        .{ .tool = "WebSearch", .concept = "tool:WebSearch" },
        .{ .tool = "WebFetch", .concept = "tool:WebFetch" },
        .{ .tool = "KgRecall", .concept = "tool:KgRecall" },
        .{ .tool = "KgContext", .concept = "tool:KgContext" },
        .{ .tool = "Task", .concept = "tool:Task" },
        .{ .tool = "Agent", .concept = "tool:Agent" },
        .{ .tool = "TaskBatch", .concept = "tool:TaskBatch" },
        .{ .tool = "Skill", .concept = "tool:Skill" },
    };
    for (methods) |method| {
        if (std.mem.eql(u8, tool_name, method.tool)) return method.concept;
    }
    return null;
}

fn validLabel(value: []const u8) bool {
    if (value.len == 0 or value.len > MAX_LABEL_BYTES) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return std.unicode.utf8ValidateSlice(value);
}

fn normalizeProjectPath(
    allocator: std.mem.Allocator,
    raw_path: []const u8,
    project_dir: []const u8,
) ?[]u8 {
    const trimmed = std.mem.trim(u8, raw_path, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > MAX_LABEL_BYTES or !validLabel(trimmed)) return null;

    const path = slashCopy(allocator, trimmed) catch return null;
    defer allocator.free(path);
    const project_copy = slashCopy(allocator, project_dir) catch return null;
    defer allocator.free(project_copy);
    var project = std.mem.trimEnd(u8, project_copy, "/");
    // Preserve filesystem roots: trimming `/` or `C:/` to an empty/non-absolute
    // string would reject every otherwise valid project resource.
    if (project.len == 0 and std.mem.startsWith(u8, project_copy, "/")) {
        project = project_copy[0..1];
    } else if (project.len == 2 and project_copy.len >= 3 and
        std.ascii.isAlphabetic(project[0]) and project[1] == ':' and project_copy[2] == '/')
    {
        project = project_copy[0..3];
    }

    var relative: []const u8 = path;
    if (isAbsolutePortable(path)) {
        if (project.len == 0 or !hasPathPrefix(path, project)) return null;
        relative = path[project.len..];
        while (relative.len > 0 and relative[0] == '/') relative = relative[1..];
    } else {
        while (std.mem.startsWith(u8, relative, "./")) relative = relative[2..];
    }
    if (relative.len == 0 or hasParentSegment(relative)) return null;
    return allocator.dupe(u8, relative) catch null;
}

fn slashCopy(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, value);
    for (out) |*byte| if (byte.* == '\\') {
        byte.* = '/';
    };
    return out;
}

fn isAbsolutePortable(path: []const u8) bool {
    return (path.len > 0 and path[0] == '/') or
        (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and path[2] == '/');
}

fn hasPathPrefix(path: []const u8, root: []const u8) bool {
    if (path.len < root.len) return false;
    const windows_style =
        (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and path[2] == '/') or
        std.mem.startsWith(u8, path, "//");
    const prefix_matches = if (windows_style)
        std.ascii.eqlIgnoreCase(path[0..root.len], root)
    else
        std.mem.eql(u8, path[0..root.len], root);
    if (!prefix_matches) return false;
    return path.len == root.len or root[root.len - 1] == '/' or path[root.len] == '/';
}

fn hasParentSegment(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return true;
    return false;
}

test "execution knowledge records only bounded sanitized facts per task" {
    const a = std.testing.allocator;
    var ledger = Ledger.init(a);
    defer ledger.deinit();

    ledger.observeSuccessfulTool(7, "Read", "{\"file_path\":\"/repo/src/main.zig\",\"secret\":\"never-store-me\"}", "/repo");
    ledger.observeSuccessfulTool(7, "Edit", "{\"file_path\":\"./src/main.zig\",\"new_string\":\"also-secret\"}", "/repo");
    ledger.observeSuccessfulTool(7, "KgContext", "{\"node_id\":42}", "/repo");
    ledger.observeSuccessfulTool(8, "Read", "{\"file_path\":\"/repo/src/other.zig\"}", "/repo");
    ledger.observeSuccessfulTool(7, "Read", "{\"file_path\":\"/outside/private.txt\"}", "/repo");

    var seven = try ledger.snapshot(a, 7);
    defer seven.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), seven.facts.len);
    for (seven.facts) |fact| {
        try std.testing.expect(std.mem.indexOf(u8, fact.value, "secret") == null);
        try std.testing.expect(std.mem.indexOf(u8, fact.value, "outside") == null);
    }
    try std.testing.expectEqual(@as(usize, 1), ledger.pendingForTask(8));

    ledger.observeSuccessfulTool(10, "Read", "{\"file_path\":\"D:\\\\REPO\\\\src\\\\win.zig\"}", "d:\\repo\\");
    var windows = try ledger.snapshot(a, 10);
    defer windows.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), windows.facts.len);
    try std.testing.expectEqualStrings("src/win.zig", windows.facts[0].value);
}

test "execution knowledge deduplicates and acknowledges one task without touching siblings" {
    const a = std.testing.allocator;
    var ledger = Ledger.init(a);
    defer ledger.deinit();

    try std.testing.expectEqual(RecordResult.stored, ledger.record(1, .uses, "tool:CodeMap"));
    try std.testing.expectEqual(RecordResult.duplicate, ledger.record(1, .uses, "tool:CodeMap"));
    try std.testing.expectEqual(RecordResult.stored, ledger.record(2, .uses, "tool:CodeMap"));
    try std.testing.expect(ledger.acknowledge(1, .uses, "tool:CodeMap"));
    try std.testing.expectEqual(@as(usize, 0), ledger.pendingForTask(1));
    try std.testing.expectEqual(@as(usize, 1), ledger.pendingForTask(2));
}

test "execution knowledge snapshot remains owned after ledger acknowledgement" {
    const a = std.testing.allocator;
    var ledger = Ledger.init(a);
    defer ledger.deinit();
    try std.testing.expectEqual(RecordResult.stored, ledger.record(9, .acts_on, "src/kg/client.zig"));
    var snapshot = try ledger.snapshot(a, 9);
    defer snapshot.deinit(a);
    try std.testing.expect(ledger.acknowledge(9, .acts_on, "src/kg/client.zig"));
    try std.testing.expectEqualStrings("src/kg/client.zig", snapshot.facts[0].value);
}

test "execution knowledge bounds one task and reports overflow" {
    const a = std.testing.allocator;
    var ledger = Ledger.init(a);
    defer ledger.deinit();
    var buf: [64]u8 = undefined;
    for (0..MAX_FACTS_PER_TASK) |index| {
        const label = try std.fmt.bufPrint(&buf, "artifact-{d}", .{index});
        try std.testing.expectEqual(RecordResult.stored, ledger.record(77, .produces, label));
    }
    try std.testing.expectEqual(RecordResult.task_limit, ledger.record(77, .produces, "overflow"));
    var snapshot = try ledger.snapshot(a, 77);
    defer snapshot.deinit(a);
    try std.testing.expectEqual(MAX_FACTS_PER_TASK, snapshot.facts.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.dropped);
}
