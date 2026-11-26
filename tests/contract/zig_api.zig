const std = @import("std");
const builtin = @import("builtin");
const Ast = std.zig.Ast;
const golden = @import("golden.zig");

const max_inline_value_bytes = 600;
const max_alias_depth = 8;

pub const Source = struct {
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![:0]u8,

    fn read(source: Source, gpa: std.mem.Allocator, path: []const u8) ![:0]u8 {
        return source.readFn(source.ctx, gpa, path);
    }
};

const File = struct {
    path: []const u8,
    text: [:0]const u8,
    tree: Ast,
};

const Located = struct { file: *File, node: Ast.Node.Index };

const Target = union(enum) {
    file: *File,
    container: Located,
    function: Located,
    decl: Located,
    opaque_expr,
};

pub const Walker = struct {
    arena: std.mem.Allocator,
    source: Source,
    files: std.StringHashMapUnmanaged(*File) = .empty,
    seen_files: std.StringHashMapUnmanaged([]const u8) = .empty,
    seen_containers: std.StringHashMapUnmanaged([]const u8) = .empty,
    out: std.ArrayList(u8) = .empty,

    pub fn run(walker: *Walker, root_path: []const u8, root_name: []const u8) ![]const u8 {
        const file = try walker.load(root_path);
        try walker.walkFile(file, root_name);
        return walker.out.items;
    }

    fn load(walker: *Walker, path: []const u8) !*File {
        if (walker.files.get(path)) |file| return file;
        const text = try walker.source.read(walker.arena, path);
        const file = try walker.arena.create(File);
        file.* = .{ .path = path, .text = text, .tree = try Ast.parse(walker.arena, text, .zig) };
        if (file.tree.errors.len != 0) {
            std.debug.print("zig api snapshot: {s} does not parse\n", .{path});
            return error.ParseFailed;
        }
        try walker.files.put(walker.arena, path, file);
        return file;
    }

    fn walkFile(walker: *Walker, file: *File, path: []const u8) !void {
        if (walker.seen_files.get(file.path)) |first| {
            try walker.out.print(walker.arena, "{s} = {s}\n", .{ path, first });
            return;
        }
        try walker.seen_files.put(walker.arena, file.path, path);
        try walker.out.print(walker.arena, "{s}: file\n", .{path});
        try walker.walkMembers(file, file.tree.rootDecls(), path);
    }

    fn walkContainer(walker: *Walker, file: *File, node: Ast.Node.Index, path: []const u8) !void {
        const key = try std.fmt.allocPrint(walker.arena, "{s}#{d}", .{ file.path, @intFromEnum(node) });
        if (walker.seen_containers.get(key)) |first| {
            try walker.out.print(walker.arena, "{s} = {s}\n", .{ path, first });
            return;
        }
        try walker.seen_containers.put(walker.arena, key, path);
        var buf: [2]Ast.Node.Index = undefined;
        const decl = file.tree.fullContainerDecl(&buf, node).?;
        const tree = &file.tree;
        const lbrace = blk: {
            var tok = decl.ast.main_token;
            while (tree.tokenTag(tok) != .l_brace) tok += 1;
            break :blk tok;
        };
        try walker.out.print(walker.arena, "{s}: {s}\n", .{ path, try walker.tokens(file, decl.ast.main_token, lbrace - 1) });
        try walker.walkMembers(file, decl.ast.members, path);
    }

    fn walkMembers(walker: *Walker, file: *File, members: []const Ast.Node.Index, path: []const u8) anyerror!void {
        const tree = &file.tree;
        for (members) |member| {
            if (tree.fullContainerField(member)) |container_field| {
                try walker.listField(file, container_field, path);
                continue;
            }
            var proto_buf: [1]Ast.Node.Index = undefined;
            if (tree.fullFnProto(&proto_buf, member)) |proto| {
                if (proto.visib_token == null) continue;
                const name = tree.tokenSlice(proto.name_token orelse continue);
                try walker.out.print(walker.arena, "{s}.{s}: {s}\n", .{ path, name, try walker.protoText(file, member) });
                continue;
            }
            if (tree.fullVarDecl(member)) |var_decl| {
                if (var_decl.visib_token == null) continue;
                try walker.listDecl(file, member, path);
            }
        }
    }

    fn listField(walker: *Walker, file: *File, container_field: Ast.full.ContainerField, path: []const u8) !void {
        const tree = &file.tree;
        var field_decl = container_field;
        field_decl.convertToNonTupleLike(tree);
        var line: std.ArrayList(u8) = .empty;
        try line.print(walker.arena, "{s}.{s}", .{ path, tree.tokenSlice(field_decl.ast.main_token) });
        if (field_decl.ast.type_expr.unwrap()) |type_expr| try line.print(walker.arena, ": {s}", .{try walker.nodeText(file, type_expr)});
        if (field_decl.ast.value_expr.unwrap()) |value| try line.print(walker.arena, " = {s}", .{try walker.valueText(file, value)});
        try walker.out.print(walker.arena, "{s}\n", .{line.items});
    }

    fn protoText(walker: *Walker, file: *File, member: Ast.Node.Index) ![]const u8 {
        var buf: [1]Ast.Node.Index = undefined;
        const proto = file.tree.fullFnProto(&buf, member).?;
        return walker.tokens(file, proto.ast.fn_token, file.tree.lastToken(proto.ast.proto_node));
    }

    fn declText(walker: *Walker, file: *File, member: Ast.Node.Index) ![]const u8 {
        const tree = &file.tree;
        const var_decl = tree.fullVarDecl(member).?;
        var line: std.ArrayList(u8) = .empty;
        try line.appendSlice(walker.arena, tree.tokenSlice(var_decl.ast.mut_token));
        if (var_decl.ast.type_node.unwrap()) |type_node| try line.print(walker.arena, " {s}", .{try walker.nodeText(file, type_node)});
        if (var_decl.ast.init_node.unwrap()) |init| try line.print(walker.arena, " = {s}", .{try walker.valueText(file, init)});
        return line.items;
    }

    fn listDecl(walker: *Walker, file: *File, member: Ast.Node.Index, path: []const u8) !void {
        const tree = &file.tree;
        const var_decl = tree.fullVarDecl(member).?;
        const name = tree.tokenSlice(var_decl.ast.mut_token + 1);
        const child = try std.fmt.allocPrint(walker.arena, "{s}.{s}", .{ path, name });
        if (var_decl.ast.init_node == .none) {
            try walker.out.print(walker.arena, "{s}: extern\n", .{child});
            return;
        }
        const text = switch (try walker.resolveMember(file, member, 0)) {
            .file => |target| return walker.walkFile(target, child),
            .container => |target| return walker.walkContainer(target.file, target.node, child),
            .function => |target| try walker.protoText(target.file, target.node),
            .decl => |target| try walker.declText(target.file, target.node),
            .opaque_expr => unreachable,
        };
        try walker.out.print(walker.arena, "{s}: {s}\n", .{ child, text });
    }

    fn resolveMember(walker: *Walker, file: *File, member: Ast.Node.Index, depth: usize) anyerror!Target {
        const tree = &file.tree;
        var buf: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buf, member) != null) return .{ .function = .{ .file = file, .node = member } };
        const var_decl = tree.fullVarDecl(member).?;
        if (tree.tokenTag(var_decl.ast.mut_token) == .keyword_const and var_decl.ast.type_node == .none) {
            if (var_decl.ast.init_node.unwrap()) |init| {
                const target = try walker.resolve(file, init, depth);
                if (target != .opaque_expr) return target;
            }
        }
        return .{ .decl = .{ .file = file, .node = member } };
    }

    fn resolve(walker: *Walker, file: *File, node: Ast.Node.Index, depth: usize) anyerror!Target {
        if (depth > max_alias_depth) return .opaque_expr;
        const tree = &file.tree;
        var container_buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&container_buf, node) != null) return .{ .container = .{ .file = file, .node = node } };
        switch (tree.nodeTag(node)) {
            .builtin_call_two, .builtin_call_two_comma => {
                if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) return .opaque_expr;
                const arg = tree.nodeData(node).opt_node_and_opt_node[0].unwrap() orelse return .opaque_expr;
                if (tree.nodeTag(arg) != .string_literal) return .opaque_expr;
                const literal = tree.tokenSlice(tree.nodeMainToken(arg));
                const target = literal[1 .. literal.len - 1];
                if (packageName(target)) |package| {
                    return .{ .file = try walker.loadPackageRoot(package) orelse return .opaque_expr };
                }
                if (!std.mem.endsWith(u8, target, ".zig")) return .opaque_expr;
                const dir = std.fs.path.dirname(file.path) orelse ".";
                const joined = try std.fs.path.resolvePosix(walker.arena, &.{ dir, target });
                return .{ .file = try walker.load(joined) };
            },
            .identifier => {
                const name = tree.tokenSlice(tree.nodeMainToken(node));
                const found = findDecl(tree, tree.rootDecls(), name) orelse return .opaque_expr;
                return walker.resolveMember(file, found, depth + 1);
            },
            .field_access => {
                const lhs, const name_token = tree.nodeData(node).node_and_token;
                const base = try walker.resolve(file, lhs, depth + 1);
                const name = tree.tokenSlice(name_token);
                const scope: Located = switch (base) {
                    .file => |target| .{ .file = target, .node = .root },
                    .container => |target| target,
                    else => return .opaque_expr,
                };
                const members = if (scope.node == .root) scope.file.tree.rootDecls() else blk: {
                    var buf: [2]Ast.Node.Index = undefined;
                    break :blk scope.file.tree.fullContainerDecl(&buf, scope.node).?.ast.members;
                };
                const found = findDecl(&scope.file.tree, members, name) orelse return .opaque_expr;
                return walker.resolveMember(scope.file, found, depth + 1);
            },
            else => return .opaque_expr,
        }
    }

    fn loadPackageRoot(walker: *Walker, package: []const u8) !?*File {
        const path = try std.fmt.allocPrint(walker.arena, "packages/{s}/src/root.zig", .{package});
        return walker.load(path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    fn packageImportsAsFiles(walker: *Walker, text: []const u8) ![]const u8 {
        const needle = "@import(\"" ++ package_module_prefix;
        var out: std.ArrayList(u8) = .empty;
        var rest = text;
        while (std.mem.indexOf(u8, rest, needle)) |at| {
            const name_start = at + needle.len;
            const quote = std.mem.indexOfScalarPos(u8, rest, name_start, '"') orelse break;
            const package = rest[name_start..quote];
            const root = (if (quote + 1 < rest.len and rest[quote + 1] == ')') try walker.loadPackageRoot(package) else null) orelse {
                try out.appendSlice(walker.arena, rest[0..quote]);
                rest = rest[quote..];
                continue;
            };
            const named = try walker.fileNamedBy(root, rest[quote + 2 ..]);
            try out.appendSlice(walker.arena, rest[0..at]);
            if (named.file) |file| {
                try out.print(walker.arena, "@import(\"{s}\")", .{std.fs.path.basenamePosix(file.path)});
            } else {
                try out.print(walker.arena, "@import(\"{s}.zig\")", .{package});
            }
            rest = rest[quote + 2 + named.consumed ..];
        }
        try out.appendSlice(walker.arena, rest);
        return out.items;
    }

    const Named = struct { file: ?*File, consumed: usize };

    fn fileNamedBy(walker: *Walker, root: *File, chain: []const u8) !Named {
        var scope: Located = .{ .file = root, .node = .root };
        var cursor: usize = 0;
        while (true) {
            var next = cursor;
            while (next < chain.len and chain[next] == ' ') next += 1;
            if (next >= chain.len or chain[next] != '.') break;
            next += 1;
            while (next < chain.len and chain[next] == ' ') next += 1;
            const start = next;
            while (next < chain.len and (std.ascii.isAlphanumeric(chain[next]) or chain[next] == '_')) next += 1;
            if (next == start) break;
            const members = if (scope.node == .root) scope.file.tree.rootDecls() else blk: {
                var buf: [2]Ast.Node.Index = undefined;
                break :blk scope.file.tree.fullContainerDecl(&buf, scope.node).?.ast.members;
            };
            const found = findDecl(&scope.file.tree, members, chain[start..next]) orelse break;
            switch (try walker.resolveMember(scope.file, found, 0)) {
                .file => |file| return .{ .file = file, .consumed = next },
                .container => |container| scope = container,
                else => break,
            }
            cursor = next;
        }
        return .{ .file = null, .consumed = 0 };
    }

    fn findDecl(tree: *const Ast, members: []const Ast.Node.Index, name: []const u8) ?Ast.Node.Index {
        for (members) |member| {
            var buf: [1]Ast.Node.Index = undefined;
            if (tree.fullFnProto(&buf, member)) |proto| {
                const name_token = proto.name_token orelse continue;
                if (std.mem.eql(u8, tree.tokenSlice(name_token), name)) return member;
                continue;
            }
            const var_decl = tree.fullVarDecl(member) orelse continue;
            if (std.mem.eql(u8, tree.tokenSlice(var_decl.ast.mut_token + 1), name)) return member;
        }
        return null;
    }

    fn nodeText(walker: *Walker, file: *File, node: Ast.Node.Index) ![]const u8 {
        return walker.tokens(file, file.tree.firstToken(node), file.tree.lastToken(node));
    }

    fn valueText(walker: *Walker, file: *File, node: Ast.Node.Index) ![]const u8 {
        const text = try walker.nodeText(file, node);
        if (text.len <= max_inline_value_bytes) return text;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
        return std.fmt.allocPrint(walker.arena, "<{d} bytes, sha256 {x}>", .{ text.len, digest[0..6] });
    }

    fn tokens(walker: *Walker, file: *File, first: Ast.TokenIndex, last: Ast.TokenIndex) ![]const u8 {
        const tree = &file.tree;
        var out: std.ArrayList(u8) = .empty;
        var previous_end: ?usize = null;
        var tok = first;
        while (tok <= last) : (tok += 1) {
            switch (tree.tokenTag(tok)) {
                .doc_comment, .container_doc_comment => continue,
                else => {},
            }
            const start = tree.tokenStart(tok);
            const slice = tree.tokenSlice(tok);
            if (previous_end) |end| if (start > end) try out.append(walker.arena, ' ');
            try out.appendSlice(walker.arena, slice);
            previous_end = start + slice.len;
        }
        return stripImportDirs(walker.arena, try walker.packageImportsAsFiles(out.items));
    }
};

const package_module_prefix = "metacodes-";

fn packageName(module: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, module, package_module_prefix)) return null;
    return module[package_module_prefix.len..];
}

fn stripImportDirs(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const needle = "@import(\"";
    var out: std.ArrayList(u8) = .empty;
    var rest = text;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        const start = at + needle.len;
        const close = std.mem.indexOfScalarPos(u8, rest, start, '"') orelse break;
        try out.appendSlice(arena, rest[0..start]);
        try out.appendSlice(arena, std.fs.path.basenamePosix(rest[start..close]));
        rest = rest[close..];
    }
    try out.appendSlice(arena, rest);
    return out.items;
}

pub fn snapshot(arena: std.mem.Allocator, source: Source, root_path: []const u8, root_name: []const u8) ![]const u8 {
    var walker: Walker = .{ .arena = arena, .source = source };
    return walker.run(root_path, root_name);
}

const DiskSource = struct {
    io: std.Io,

    fn read(ctx: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![:0]u8 {
        const self: *DiskSource = @ptrCast(@alignCast(ctx));
        return std.Io.Dir.cwd().readFileAllocOptions(self.io, path, gpa, .limited(16 << 20), .of(u8), 0);
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var args = try std.process.Args.iterateAllocator(init.minimal.args, arena);
    defer args.deinit();
    _ = args.next();
    const root_path = args.next() orelse return usage();
    const root_name = args.next() orelse return usage();
    const contract_root = args.next() orelse return usage();
    const snapshot_path = args.next() orelse return usage();
    const version = args.next() orelse return usage();
    const declared_zig = args.next() orelse return usage();
    var mode: golden.Mode = .check;
    if (args.next()) |flag| {
        if (!std.mem.eql(u8, flag, "--update")) return usage();
        mode = .update;
    }
    const full_path = try std.fs.path.join(arena, &.{ contract_root, snapshot_path });
    const recorded = if (mode == .check) recordedZig(std.Io.Dir.cwd().readFileAlloc(init.io, full_path, arena, .limited(64 << 20)) catch null) else null;
    if (try toolchainProblem(arena, snapshot_path, builtin.zig_version_string, declared_zig, recorded)) |problem| {
        std.debug.print("{s}", .{problem});
        std.process.exit(1);
    }
    var disk: DiskSource = .{ .io = init.io };
    const raw = try snapshot(arena, .{ .ctx = &disk, .readFn = DiskSource.read }, root_path, root_name);
    const quoted_version = try std.fmt.allocPrint(arena, "\"{s}\"", .{version});
    const api = try std.mem.replaceOwned(u8, arena, raw, quoted_version, "\"<VERSION>\"");
    const text = try std.fmt.allocPrint(arena, "{s}{s}\n{s}", .{ zig_header, builtin.zig_version_string, api });
    const store: golden.Store = .{ .io = init.io, .root = contract_root, .mode = mode };
    store.expect(arena, snapshot_path, text) catch |err| switch (err) {
        error.ContractDrift, error.ContractSnapshotMissing => std.process.exit(1),
        else => return err,
    };
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: zig-api-snapshot <root.zig> <root name> <contract dir> <snapshot path> <version> <declared zig version> [--update]\n", .{});
    return error.InvalidArguments;
}

const zig_header = "zig: ";

const toolchain_upgrade_hint = "a Zig toolchain upgrade goes in its own PR, with build.zig.zon's minimum_zig_version raised and the snapshot regenerated with: " ++ golden.update_hint ++ "\n";

pub fn recordedZig(snapshot_text: ?[]const u8) ?[]const u8 {
    const text = snapshot_text orelse return null;
    const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    if (!std.mem.startsWith(u8, line, zig_header)) return "";
    return line[zig_header.len..];
}

pub fn toolchainProblem(gpa: std.mem.Allocator, snapshot_path: []const u8, toolchain: []const u8, declared: []const u8, recorded: ?[]const u8) !?[]u8 {
    if (!std.mem.eql(u8, toolchain, declared)) {
        return try std.fmt.allocPrint(gpa, "zig api snapshot: this build runs Zig {s}, but build.zig.zon declares {s}\n" ++ toolchain_upgrade_hint, .{ toolchain, declared });
    }
    const snapshot_zig = recorded orelse return null;
    if (std.mem.eql(u8, toolchain, snapshot_zig)) return null;
    return try std.fmt.allocPrint(gpa, "zig api snapshot: tests/contract/{s} was recorded with Zig {s}, this build runs Zig {s}\n" ++ toolchain_upgrade_hint, .{ snapshot_path, if (snapshot_zig.len == 0) "<unrecorded>" else snapshot_zig, toolchain });
}

const MemorySource = struct {
    files: []const [2][]const u8,

    fn read(ctx: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![:0]u8 {
        const self: *MemorySource = @ptrCast(@alignCast(ctx));
        for (self.files) |entry| if (std.mem.eql(u8, entry[0], path)) return gpa.dupeZ(u8, entry[1]);
        return error.FileNotFound;
    }
};

fn expectSnapshot(files: []const [2][]const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var memory: MemorySource = .{ .files = files };
    const text = try snapshot(arena_state.allocator(), .{ .ctx = &memory, .readFn = MemorySource.read }, "src/lib.zig", "lib");
    try std.testing.expectEqualStrings(expected, text);
}

test "pub functions, constants, variables and containers are listed with their signatures" {
    try expectSnapshot(&.{.{
        "src/lib.zig",
        \\const std = @import("std");
        \\/// docs are not part of the signature
        \\pub fn run(
        \\    gpa: std.mem.Allocator, // nor are comments
        \\    opts: Options,
        \\) !void {}
        \\fn private() void {}
        \\pub const LIMIT: usize = 4;
        \\pub var counter = 0;
        \\pub const Options = struct {
        \\    max_turns: u32 = 8,
        \\    name: []const u8,
        \\    pub const default: Options = .{ .name = "x" };
        \\    const hidden = 1;
        \\};
        \\pub const Kind = enum(u8) { a, b = 3 };
        \\
    }},
        \\lib: file
        \\lib.run: fn run( gpa: std.mem.Allocator, opts: Options, ) !void
        \\lib.LIMIT: const usize = 4
        \\lib.counter: var = 0
        \\lib.Options: struct
        \\lib.Options.max_turns: u32 = 8
        \\lib.Options.name: []const u8
        \\lib.Options.default: const Options = .{ .name = "x" }
        \\lib.Kind: enum(u8)
        \\lib.Kind.a
        \\lib.Kind.b = 3
        \\
    );
}

test "imports are followed, a second path to the same file or container is an alias" {
    try expectSnapshot(&.{
        .{
            "src/lib.zig",
            \\pub const core = @import("core/a.zig");
            \\pub const again = @import("core/a.zig");
            \\pub const Thing = @import("core/a.zig").Thing;
            \\pub const Other = local.Thing;
            \\const local = @import("core/a.zig");
            \\pub const std_alias = @import("std");
            \\
        },
        .{
            "src/core/a.zig",
            \\pub const Thing = struct { x: u8 };
            \\pub fn make() Thing { return .{ .x = 1 }; }
            \\pub const b = @import("../b.zig");
            \\
        },
        .{ "src/b.zig", "pub const ONE = 1;\n" },
    },
        \\lib: file
        \\lib.core: file
        \\lib.core.Thing: struct
        \\lib.core.Thing.x: u8
        \\lib.core.make: fn make() Thing
        \\lib.core.b: file
        \\lib.core.b.ONE: const = 1
        \\lib.again = lib.core
        \\lib.Thing = lib.core.Thing
        \\lib.Other = lib.core.Thing
        \\lib.std_alias: const = @import("std")
        \\
    );
}

test "an import of a package module reads as the file its root re-exports, so splitting a package keeps the snapshot" {
    try expectSnapshot(&.{
        .{
            "src/lib.zig",
            \\pub const log = @import("metacodes-base").util.log;
            \\pub const Level = @import("metacodes-base").util.log.Level;
            \\pub const RequestId = @import("metacodes-base").RequestId;
            \\pub fn write(level: @import("metacodes-base").util.log.Level, id: @import("metacodes-base").RequestId) void {}
            \\pub const tools = @import("metacodes-base").tools_root;
            \\pub const outside = @import("metacodes-absent").x;
            \\
        },
        .{
            "packages/base/src/root.zig",
            \\pub const util = struct {
            \\    pub const log = @import("util/log.zig");
            \\};
            \\pub const tools_root = @import("tools.zig");
            \\pub const RequestId = util.log.RequestId;
            \\
        },
        .{ "packages/base/src/util/log.zig", "pub const Level = enum { info };\npub const RequestId = u64;\n" },
        .{ "packages/base/src/tools.zig", "pub const count = 2;\n" },
    },
        \\lib: file
        \\lib.log: file
        \\lib.log.Level: enum
        \\lib.log.Level.info
        \\lib.log.RequestId: const = u64
        \\lib.Level = lib.log.Level
        \\lib.RequestId: const = u64
        \\lib.write: fn write(level: @import("log.zig").Level, id: @import("base.zig").RequestId) void
        \\lib.tools: file
        \\lib.tools.count: const = 2
        \\lib.outside: const = @import("metacodes-absent").x
        \\
    );
}

test "import paths in printed text keep only the file name, so moving a file keeps the snapshot" {
    try expectSnapshot(&.{
        .{ "src/lib.zig", "pub const VERSION = @import(\"core/version.zig\").semver;\npub const v = @import(\"core/version.zig\");\n" },
        .{ "src/core/version.zig", "pub const semver = \"1.0.0\";\n" },
    },
        \\lib: file
        \\lib.VERSION: const = "1.0.0"
        \\lib.v: file
        \\lib.v.semver: const = "1.0.0"
        \\
    );
}

test "long values are summarised by length and digest" {
    const long = "pub const TEXT = \"" ++ "a" ** 700 ++ "\";\n";
    try expectSnapshot(&.{.{ "src/lib.zig", long }},
        \\lib: file
        \\lib.TEXT: const = <702 bytes, sha256 157cc2e33bed>
        \\
    );
}

test "an alias of a function or a typed constant in another file records the target's signature and value" {
    try expectSnapshot(&.{
        .{ "src/lib.zig", "pub const tool = @import(\"skills/tool.zig\");\n" },
        .{ "src/skills/tool.zig", "pub const registerSkillTool = @import(\"cli_adapter.zig\").registerModelTool;\npub const LIMIT = @import(\"cli_adapter.zig\").limit;\n" },
        .{ "src/skills/cli_adapter.zig", "pub fn registerModelTool(registry: *Registry, max: u32) !void {}\npub const limit: usize = 8;\n" },
    },
        \\lib: file
        \\lib.tool: file
        \\lib.tool.registerSkillTool: fn registerModelTool(registry: *Registry, max: u32) !void
        \\lib.tool.LIMIT: const usize = 8
        \\
    );
}

test "the snapshot's first line records the Zig version; another toolchain or another declared version fails with the upgrade rule" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("0.16.0", recordedZig("zig: 0.16.0\nlib: file\n").?);
    try std.testing.expectEqualStrings("", recordedZig("lib: file\n").?);
    try std.testing.expectEqual(@as(?[]const u8, null), recordedZig(null));

    try std.testing.expectEqual(@as(?[]u8, null), try toolchainProblem(a, "zig_api/x.txt", "0.16.0", "0.16.0", "0.16.0"));
    try std.testing.expectEqual(@as(?[]u8, null), try toolchainProblem(a, "zig_api/x.txt", "0.16.0", "0.16.0", null));

    const recorded_other = (try toolchainProblem(a, "zig_api/x.txt", "0.16.0", "0.16.0", "0.15.2")).?;
    defer a.free(recorded_other);
    try std.testing.expect(std.mem.indexOf(u8, recorded_other, "tests/contract/zig_api/x.txt was recorded with Zig 0.15.2, this build runs Zig 0.16.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, recorded_other, "its own PR") != null);
    try std.testing.expect(std.mem.indexOf(u8, recorded_other, "-Dupdate-contract") != null);

    const unrecorded = (try toolchainProblem(a, "zig_api/x.txt", "0.16.0", "0.16.0", "")).?;
    defer a.free(unrecorded);
    try std.testing.expect(std.mem.indexOf(u8, unrecorded, "recorded with Zig <unrecorded>") != null);

    const undeclared = (try toolchainProblem(a, "zig_api/x.txt", "0.17.0", "0.16.0", "0.17.0")).?;
    defer a.free(undeclared);
    try std.testing.expect(std.mem.indexOf(u8, undeclared, "runs Zig 0.17.0, but build.zig.zon declares 0.16.0") != null);
}
