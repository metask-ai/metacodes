const std = @import("std");
const c = @import("agentcore_h");
const binary = @import("agentcore_binary");

const prefixes = [_][]const u8{ "metask_agentcore_", "METASK_AGENTCORE_" };

fn listed(comptime name: []const u8) bool {
    for (prefixes) |prefix| if (std.mem.startsWith(u8, name, prefix)) return true;
    return false;
}

const decls = @typeInfo(c).@"struct".decls;

const NamedType = struct { name: []const u8, T: type };

const named_types: []const NamedType = blk: {
    @setEvalBranchQuota(10_000_000);
    var list: []const NamedType = &.{};
    for (decls) |decl| {
        if (listed(decl.name) and @TypeOf(@field(c, decl.name)) == type) list = list ++ [_]NamedType{.{ .name = decl.name, .T = @field(c, decl.name) }};
    }
    break :blk list;
};

fn typedefName(comptime T: type) ?[]const u8 {
    @setEvalBranchQuota(10_000_000);
    inline for (named_types) |named| {
        if (named.T == T) return named.name;
    }
    return null;
}

fn typeText(comptime T: type) []const u8 {
    if (comptime typedefName(T)) |name| return name;
    return expand(T);
}

fn expand(comptime T: type) []const u8 {
    return comptime switch (@typeInfo(T)) {
        .pointer => |pointer| (switch (pointer.size) {
            .one => "*",
            .many => "[*]",
            .slice => "[]",
            .c => "[*c]",
        }) ++ (if (pointer.is_const) "const " else "") ++ typeText(pointer.child),
        .optional => |optional| "?" ++ typeText(optional.child),
        .array => |array| std.fmt.comptimePrint("[{d}]", .{array.len}) ++ typeText(array.child),
        .@"fn" => |function| blk: {
            var text: []const u8 = "fn (";
            for (function.params, 0..) |param, index| {
                if (index > 0) text = text ++ ", ";
                text = text ++ if (param.type) |P| typeText(P) else "anytype";
            }
            break :blk text ++ ") " ++ if (function.return_type) |R| typeText(R) else "anytype";
        },
        else => @typeName(T),
    };
}

pub fn layout(a: std.mem.Allocator, header: []const u8) ![]const u8 {
    @setEvalBranchQuota(10_000_000);
    var out: std.ArrayList(u8) = .empty;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(header, &digest, .{});
    try out.print(a, "agentcore.h sha256 {x}\n", .{&digest});
    inline for (decls) |decl| {
        if (comptime !listed(decl.name)) continue;
        const V = @TypeOf(@field(c, decl.name));
        if (V == type) {
            const value = @field(c, decl.name);
            switch (@typeInfo(value)) {
                .@"struct" => |info| {
                    try out.print(a, "\nstruct {s} size {d} align {d}\n", .{ decl.name, @sizeOf(value), @alignOf(value) });
                    inline for (info.fields) |field| {
                        try out.print(a, "  {d:>4} {d:>3} {s}: {s}\n", .{ @offsetOf(value, field.name), @sizeOf(field.type), field.name, comptime typeText(field.type) });
                    }
                },
                .@"opaque" => try out.print(a, "\nopaque {s}\n", .{decl.name}),
                else => try out.print(a, "\ntypedef {s} = {s}\n", .{ decl.name, comptime expand(value) }),
            }
        } else switch (@typeInfo(V)) {
            .@"fn" => try out.print(a, "\nfn {s}: {s}\n", .{ decl.name, comptime expand(V) }),
            .int, .comptime_int => try out.print(a, "const {s} = {d}\n", .{ decl.name, @field(c, decl.name) }),
            else => try out.print(a, "const {s}: {s}\n", .{ decl.name, comptime typeText(V) }),
        }
    }
    return out.items;
}

fn inertToolchainExport(format: binary.Format, name: []const u8) bool {
    return switch (format) {
        .pe => std.mem.eql(u8, name, "_DllMainCRTStartup"),
        .macho => std.mem.eql(u8, name, "_mh_dylib_header") or std.mem.eql(u8, name, "__dso_handle"),
        .elf => false,
    };
}

pub fn exports(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const image = try binary.read(a, bytes);
    var names: std.ArrayList([]const u8) = .empty;
    for (image.exports) |name| if (!inertToolchainExport(image.format, name)) try names.append(a, name);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    for (names.items) |name| try out.print(a, "{s}\n", .{name});
    return out.items;
}
