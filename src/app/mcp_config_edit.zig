const std = @import("std");
const pfs = @import("platform").fs;
const mcp_config = @import("metacodes-internal").mcp.config;
const json_merge = @import("metacodes-internal").util.json_merge;
const file_lock = @import("metacodes-internal").util.file_lock;

pub const SERVERS_KEY = "mcpServers";
const LEGACY_KEY = "mcp_servers";

pub const Entry = union(enum) {
    url: struct {
        url: []const u8,
        wire: mcp_config.HttpWire,
        headers: []const mcp_config.KeyValue = &.{},
        bearer_token_env_var: ?[]const u8 = null,
        oauth_client_id: ?[]const u8 = null,
        oauth_callback_port: ?u16 = null,
    },
    command: struct {
        command: []const u8,
        args: []const []const u8,
        env: []const mcp_config.KeyValue = &.{},
    },

    pub fn toJson(self: Entry, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        self.write(&out.writer) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    fn write(self: Entry, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var js: std.json.Stringify = .{ .writer = w };
        try js.beginObject();
        switch (self) {
            .url => |url| {
                try js.objectField("type");
                try js.write(switch (url.wire) {
                    .streamable => "http",
                    .legacy_sse => "sse",
                });
                try js.objectField("url");
                try js.write(url.url);
                try writePairs(&js, "headers", url.headers);
                if (url.bearer_token_env_var) |variable| {
                    try js.objectField("bearerTokenEnvVar");
                    try js.write(variable);
                }
                if (url.oauth_client_id != null or url.oauth_callback_port != null) {
                    try js.objectField("oauth");
                    try js.beginObject();
                    if (url.oauth_client_id) |client_id| {
                        try js.objectField("clientId");
                        try js.write(client_id);
                    }
                    if (url.oauth_callback_port) |port| {
                        try js.objectField("callbackPort");
                        try js.write(port);
                    }
                    try js.endObject();
                }
            },
            .command => |command| {
                try js.objectField("type");
                try js.write("stdio");
                try js.objectField("command");
                try js.write(command.command);
                if (command.args.len != 0) {
                    try js.objectField("args");
                    try js.write(command.args);
                }
                try writePairs(&js, "env", command.env);
            },
        }
        try js.endObject();
    }

    fn writePairs(js: *std.json.Stringify, key: []const u8, pairs: []const mcp_config.KeyValue) std.Io.Writer.Error!void {
        if (pairs.len == 0) return;
        try js.objectField(key);
        try js.beginObject();
        for (pairs) |pair| {
            try js.objectField(pair.name);
            try js.write(pair.value);
        }
        try js.endObject();
    }
};

pub const Existing = struct {
    servers: bool = false,
    legacy: bool = false,
};

pub const DocumentError = error{
    InvalidJson,
    NotAnObject,
    OutOfMemory,
};

pub fn existing(scratch: std.mem.Allocator, text: []const u8, name: []const u8) DocumentError!Existing {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return .{};
    const root = std.json.parseFromSliceLeaky(std.json.Value, scratch, trimmed, .{}) catch |err|
        return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidJson;
    if (root != .object) return error.NotAnObject;
    var found: Existing = .{};
    if (root.object.get(SERVERS_KEY)) |servers| {
        if (servers != .object) return error.NotAnObject;
        found.servers = servers.object.contains(name);
    }
    if (root.object.get(LEGACY_KEY)) |legacy| if (legacy == .array) {
        for (legacy.array.items) |item| {
            if (item != .object) continue;
            const item_name = item.object.get("name") orelse continue;
            if (item_name == .string and std.mem.eql(u8, item_name.string, name)) found.legacy = true;
        }
    };
    return found;
}

pub fn apply(gpa: std.mem.Allocator, text: []const u8, name: []const u8, entry_json: ?[]const u8) DocumentError![]u8 {
    return json_merge.mergeFields(gpa, text, &.{}, &.{.{
        .object_key = SERVERS_KEY,
        .member_key = name,
        .json = entry_json,
    }}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotAnObject => error.NotAnObject,
        error.InvalidJson, error.InvalidFieldJson => error.InvalidJson,
    };
}

pub const EditError = DocumentError || error{
    LockBusy,
    PathTooLong,
    ReadFailed,
    WriteFailed,
};

pub const Change = union(enum) {
    put: struct { entry_json: []const u8, replace: bool },
    remove,
};

pub const Outcome = struct {
    before: Existing,
    written: bool,
};

pub fn change(gpa: std.mem.Allocator, path: []const u8, name: []const u8, request: Change) EditError!Outcome {
    var lock = file_lock.acquire(path, .{}) catch |err| switch (err) {
        error.LockBusy => return error.LockBusy,
        error.PathTooLong => return error.PathTooLong,
        error.NoParentDir => blk: {
            const parent = std.fs.path.dirname(path) orelse return error.WriteFailed;
            @import("metacodes-internal").util.fs.mkdirParents(parent) catch return error.WriteFailed;
            break :blk file_lock.acquire(path, .{}) catch |retry| switch (retry) {
                error.PathTooLong => return error.PathTooLong,
                error.LockBusy, error.NoParentDir => return error.LockBusy,
            };
        },
    };
    defer lock.release();

    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const original = try readDocument(scratch, path);
    const before = try existing(scratch, original, name);
    const entry_json: ?[]const u8 = switch (request) {
        .put => |put| if ((before.servers or before.legacy) and !put.replace)
            return .{ .before = before, .written = false }
        else
            put.entry_json,
        .remove => if (!before.servers) return .{ .before = before, .written = false } else null,
    };
    const updated = try apply(scratch, original, name, entry_json);
    const document = try std.mem.concat(scratch, u8, &.{ updated, "\n" });
    @import("metacodes-internal").provider.oauth.writeAtomicPrivate(gpa, path, document) catch return error.WriteFailed;
    return .{ .before = before, .written = true };
}

fn readDocument(scratch: std.mem.Allocator, path: []const u8) EditError![]const u8 {
    const path_z = try scratch.dupeZ(u8, path);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) {
        if (pfs.lastErrnoIs(.NOENT)) return "";
        return error.ReadFailed;
    }
    defer _ = pfs.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const count = pfs.read(fd, &buffer);
        if (count < 0) return error.ReadFailed;
        if (count == 0) break;
        try out.appendSlice(scratch, buffer[0..@intCast(count)]);
    }
    return out.items;
}

const testing = std.testing;

test "an http entry is Claude Code's shape, headers kept in order" {
    const json = try (Entry{ .url = .{
        .url = "https://mcp.example.com/mcp",
        .wire = .streamable,
        .headers = &.{ .{ .name = "Authorization", .value = "Bearer ${TOKEN}" }, .{ .name = "X-Org", .value = "a\"b" } },
    } }).toJson(testing.allocator);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        \\{"type":"http","url":"https://mcp.example.com/mcp","headers":{"Authorization":"Bearer ${TOKEN}","X-Org":"a\"b"}}
    , json);
}

test "Codex's bearer variable and Claude Code's OAuth client settings use the keys the loader reads" {
    const json = try (Entry{ .url = .{
        .url = "https://x.example/mcp",
        .wire = .streamable,
        .bearer_token_env_var = "X_TOKEN",
        .oauth_client_id = "cli",
        .oauth_callback_port = 8765,
    } }).toJson(testing.allocator);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        \\{"type":"http","url":"https://x.example/mcp","bearerTokenEnvVar":"X_TOKEN","oauth":{"clientId":"cli","callbackPort":8765}}
    , json);
}

test "an sse entry without headers and a stdio entry without args or env leave the empty keys out" {
    const sse = try (Entry{ .url = .{ .url = "http://127.0.0.1:9/sse", .wire = .legacy_sse, .headers = &.{} } }).toJson(testing.allocator);
    defer testing.allocator.free(sse);
    try testing.expectEqualStrings("{\"type\":\"sse\",\"url\":\"http://127.0.0.1:9/sse\"}", sse);
    const bare = try (Entry{ .command = .{ .command = "npx", .args = &.{}, .env = &.{} } }).toJson(testing.allocator);
    defer testing.allocator.free(bare);
    try testing.expectEqualStrings("{\"type\":\"stdio\",\"command\":\"npx\"}", bare);
    const full = try (Entry{ .command = .{
        .command = "npx",
        .args = &.{ "-y", "@scope/server" },
        .env = &.{.{ .name = "API_KEY", .value = "k" }},
    } }).toJson(testing.allocator);
    defer testing.allocator.free(full);
    try testing.expectEqualStrings("{\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"-y\",\"@scope/server\"],\"env\":{\"API_KEY\":\"k\"}}", full);
}

test "a member is added and removed without touching any other key" {
    const a = testing.allocator;
    const original =
        \\{"jev":{"url":"https://jev.example"},"mcp_servers":[{"name":"kg","command":["/bin/kg"]}],
        \\ "mcpServers":{"first":{"command":"one"}},"theme":"dark"}
    ;
    const added = try apply(a, original, "suno", "{\"type\":\"http\",\"url\":\"https://suno.example/mcp\"}");
    defer a.free(added);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, added, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings("https://jev.example", root.get("jev").?.object.get("url").?.string);
    try testing.expectEqualStrings("kg", root.get("mcp_servers").?.array.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("dark", root.get("theme").?.string);
    const servers = root.get("mcpServers").?.object;
    try testing.expectEqualStrings("first", servers.keys()[0]);
    try testing.expectEqualStrings("suno", servers.keys()[1]);
    try testing.expectEqualStrings("https://suno.example/mcp", servers.get("suno").?.object.get("url").?.string);
    try testing.expect(std.mem.indexOf(u8, added, "\"jev\"").? < std.mem.indexOf(u8, added, "\"mcp_servers\"").?);
    try testing.expect(std.mem.indexOf(u8, added, "\"mcpServers\"").? < std.mem.indexOf(u8, added, "\"theme\"").?);

    const removed = try apply(a, added, "suno", null);
    defer a.free(removed);
    try testing.expect(std.mem.indexOf(u8, removed, "suno") == null);
    try testing.expect(std.mem.indexOf(u8, removed, "\"first\"") != null);
    try testing.expect(std.mem.indexOf(u8, removed, "\"kg\"") != null);
}

test "an empty document gets mcpServers; a broken one is refused" {
    const a = testing.allocator;
    const created = try apply(a, "", "x", "{\"type\":\"stdio\",\"command\":\"x\"}");
    defer a.free(created);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, created, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("mcpServers").?.object.contains("x"));
    try testing.expectError(error.InvalidJson, apply(a, "{not json", "x", "{}"));
    try testing.expectError(error.NotAnObject, apply(a, "[]", "x", "{}"));
    try testing.expectError(error.NotAnObject, apply(a, "{\"mcpServers\":[]}", "x", "{}"));
}

test "existing names both the mcpServers member and a legacy entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\{"mcpServers":{"off":{"enabled":false}},"mcp_servers":[{"name":"old","command":["/bin/old"]},3]}
    ;
    try testing.expectEqual(Existing{ .servers = true }, try existing(a, text, "off"));
    try testing.expectEqual(Existing{ .legacy = true }, try existing(a, text, "old"));
    try testing.expectEqual(Existing{}, try existing(a, text, "new"));
    try testing.expectEqual(Existing{}, try existing(a, "  \n", "new"));
    try testing.expectError(error.InvalidJson, existing(a, "{", "x"));
    try testing.expectError(error.NotAnObject, existing(a, "{\"mcpServers\":1}", "x"));
}

fn tmpConfigPath(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrint(buffer, "{s}/state/config.json", .{root[0..len]});
}

fn readBack(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    return (try readDocument(a, path));
}

test "change: creates the document 0600, refuses a known name unless replacing, removes only its own member" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpConfigPath(&tmp, &path_buffer);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try change(testing.allocator, path, "suno", .{ .put = .{ .entry_json = "{\"type\":\"http\",\"url\":\"https://a/mcp\"}", .replace = false } });
    try testing.expect(first.written);
    try testing.expectEqual(Existing{}, first.before);
    const path_z = try a.dupeZ(u8, path);
    try testing.expectEqual(@as(u32, 0o600), (pfs.statMode(path_z.ptr, false) orelse return error.NoMode) & 0o777);
    const lock_z = try std.fmt.allocPrintSentinel(a, "{s}.lock", .{path}, 0);
    try testing.expect(!pfs.exists(lock_z));

    const again = try change(testing.allocator, path, "suno", .{ .put = .{ .entry_json = "{\"type\":\"http\",\"url\":\"https://b/mcp\"}", .replace = false } });
    try testing.expect(!again.written);
    try testing.expect(again.before.servers);
    try testing.expect(std.mem.indexOf(u8, try readBack(a, path), "https://a/mcp") != null);
    const replaced = try change(testing.allocator, path, "suno", .{ .put = .{ .entry_json = "{\"type\":\"http\",\"url\":\"https://b/mcp\"}", .replace = true } });
    try testing.expect(replaced.written);
    try testing.expect(std.mem.indexOf(u8, try readBack(a, path), "https://b/mcp") != null);

    try testing.expect(!(try change(testing.allocator, path, "other", .remove)).written);
    const removed = try change(testing.allocator, path, "suno", .remove);
    try testing.expect(removed.written and removed.before.servers);
    try testing.expect(std.mem.indexOf(u8, try readBack(a, path), "suno") == null);
}

test "change: a document that is not JSON is left as it was" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "state");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "state/config.json", .data = "{\"jev\": tru" });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpConfigPath(&tmp, &path_buffer);
    try testing.expectError(error.InvalidJson, change(testing.allocator, path, "x", .{ .put = .{ .entry_json = "{}", .replace = true } }));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("{\"jev\": tru", try readBack(arena.allocator(), path));
}
