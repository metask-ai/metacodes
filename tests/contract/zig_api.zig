const std = @import("std");
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

const Target = union(enum) {
    file: *File,
    container: struct { file: *File, node: Ast.Node.Index },
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
                const last = tree.lastToken(proto.ast.proto_node);
                try walker.out.print(walker.arena, "{s}.{s}: {s}\n", .{ path, name, try walker.tokens(file, proto.ast.fn_token, last) });
                continue;
            }
            if (tree.fullVarDecl(member)) |var_decl| {
                if (var_decl.visib_token == null) continue;
                try walker.listDecl(file, var_decl, path);
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

    fn listDecl(walker: *Walker, file: *File, var_decl: Ast.full.VarDecl, path: []const u8) !void {
        const tree = &file.tree;
        const name = tree.tokenSlice(var_decl.ast.mut_token + 1);
        const child = try std.fmt.allocPrint(walker.arena, "{s}.{s}", .{ path, name });
        const init = var_decl.ast.init_node.unwrap() orelse {
            try walker.out.print(walker.arena, "{s}: extern\n", .{child});
            return;
        };
        if (tree.tokenTag(var_decl.ast.mut_token) == .keyword_const and var_decl.ast.type_node == .none) {
            switch (try walker.resolve(file, init, 0)) {
                .file => |target| return walker.walkFile(target, child),
                .container => |target| return walker.walkContainer(target.file, target.node, child),
                .opaque_expr => {},
            }
        }
        var line: std.ArrayList(u8) = .empty;
        try line.print(walker.arena, "{s}: {s}", .{ child, tree.tokenSlice(var_decl.ast.mut_token) });
        if (var_decl.ast.type_node.unwrap()) |type_node| try line.print(walker.arena, " {s}", .{try walker.nodeText(file, type_node)});
        try line.print(walker.arena, " = {s}", .{try walker.valueText(file, init)});
        try walker.out.print(walker.arena, "{s}\n", .{line.items});
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
                if (!std.mem.endsWith(u8, target, ".zig")) return .opaque_expr;
                const dir = std.fs.path.dirname(file.path) orelse ".";
                const joined = try std.fs.path.resolvePosix(walker.arena, &.{ dir, target });
                return .{ .file = try walker.load(joined) };
            },
            .identifier => {
                const name = tree.tokenSlice(tree.nodeMainToken(node));
                const found = findDecl(tree, tree.rootDecls(), name) orelse return .opaque_expr;
                return walker.resolve(file, found, depth + 1);
            },
            .field_access => {
                const lhs, const name_token = tree.nodeData(node).node_and_token;
                const base = try walker.resolve(file, lhs, depth + 1);
                const name = tree.tokenSlice(name_token);
                switch (base) {
                    .file => |target| {
                        const found = findDecl(&target.tree, target.tree.rootDecls(), name) orelse return .opaque_expr;
                        return walker.resolve(target, found, depth + 1);
                    },
                    .container => |target| {
                        var buf: [2]Ast.Node.Index = undefined;
                        const members = target.file.tree.fullContainerDecl(&buf, target.node).?.ast.members;
                        const found = findDecl(&target.file.tree, members, name) orelse return .opaque_expr;
                        return walker.resolve(target.file, found, depth + 1);
                    },
                    .opaque_expr => return .opaque_expr,
                }
            },
            else => return .opaque_expr,
        }
    }

    fn findDecl(tree: *const Ast, members: []const Ast.Node.Index, name: []const u8) ?Ast.Node.Index {
        for (members) |member| {
            const var_decl = tree.fullVarDecl(member) orelse continue;
            if (tree.tokenTag(var_decl.ast.mut_token) != .keyword_const) continue;
            if (var_decl.ast.type_node != .none) continue;
            if (!std.mem.eql(u8, tree.tokenSlice(var_decl.ast.mut_token + 1), name)) continue;
            return var_decl.ast.init_node.unwrap();
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
        return stripImportDirs(walker.arena, out.items);
    }
};

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
    var mode: golden.Mode = .check;
    if (args.next()) |flag| {
        if (!std.mem.eql(u8, flag, "--update")) return usage();
        mode = .update;
    }
    var disk: DiskSource = .{ .io = init.io };
    const text = try snapshot(arena, .{ .ctx = &disk, .readFn = DiskSource.read }, root_path, root_name);
    const store: golden.Store = .{ .io = init.io, .root = contract_root, .mode = mode };
    store.expect(arena, snapshot_path, text) catch |err| switch (err) {
        error.ContractDrift, error.ContractSnapshotMissing => std.process.exit(1),
        else => return err,
    };
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: zig-api-snapshot <root.zig> <root name> <contract dir> <snapshot path> [--update]\n", .{});
    return error.InvalidArguments;
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

test "import paths in printed text keep only the file name, so moving a file keeps the snapshot" {
    try expectSnapshot(&.{
        .{ "src/lib.zig", "pub const VERSION = @import(\"core/version.zig\").semver;\npub const v = @import(\"core/version.zig\");\n" },
        .{ "src/core/version.zig", "pub const semver = \"1.0.0\";\n" },
    },
        \\lib: file
        \\lib.VERSION: const = @import("version.zig").semver
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
