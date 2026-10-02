const std = @import("std");
const binary = @import("agentcore_binary.zig");

const archive_magic = "!<arch>\n";
const header_size = 60;
const discovery_symbol = "metask_agentcore_get_api";

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = std.process.Args.iterateAllocator(init.minimal.args, allocator) catch
        return error.InvalidArguments;
    defer args.deinit();
    _ = args.next();
    const first = args.next() orelse return usage();
    const shared = std.mem.eql(u8, first, "--shared");
    const path = if (shared) args.next() orelse return usage() else first;
    var msvc_runtime = false;
    if (shared) if (args.next()) |flag| {
        if (!std.mem.eql(u8, flag, "--msvc-runtime")) return usage();
        msvc_runtime = true;
    };
    if (args.next() != null) return usage();

    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        allocator,
        .limited(1024 * 1024 * 1024),
    );
    if (shared) {
        const image = try validateSharedLibrary(allocator, bytes, msvc_runtime);
        std.debug.print("AgentCore shared library ({t}, load name {s}): exports {s}; needs", .{
            image.format,
            image.install_name orelse "-",
            discovery_symbol,
        });
        for (image.needed) |name| std.debug.print(" {s}", .{name});
        std.debug.print("\n", .{});
    } else try validateArchiveSymbols(bytes);
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: agentcore-symbol-gate <static-archive>\n" ++
        "       agentcore-symbol-gate --shared <shared-library> [--msvc-runtime]\n", .{});
    return error.InvalidArguments;
}

/// Names the toolchain itself exports and no Host can call or collide with:
/// Zig's standard library exports its DLL entry point from every Windows DLL
/// (the loader enters through the PE header, and PE exports do not
/// interpose), and Zig's Mach-O linker exports the image markers it
/// synthesizes, `__mh_dylib_header` and `___dso_handle` (addresses inside
/// this image; Mach-O's two-level namespace binds every reference per
/// library). None is an ABI entry. Names are listed without Mach-O's leading
/// underscore, as `agentcore_binary.read` reports them.
fn isInertToolchainExport(format: binary.Format, name: []const u8) bool {
    return switch (format) {
        .pe => std.mem.eql(u8, name, "_DllMainCRTStartup"),
        .macho => std.mem.eql(u8, name, "_mh_dylib_header") or std.mem.eql(u8, name, "__dso_handle"),
        .elf => false,
    };
}

/// A shared library exports exactly the discovery entry point (plus the
/// inert toolchain names above) and needs only libraries every installation
/// of its OS carries, so an FFI Host can load it from the bundle alone (#182).
/// `msvc_runtime` (MSVC-ABI targets only) also admits the Visual C++
/// runtime, `vcruntime140.dll`, which every MSVC-built DLL links; the
/// manifest lists it for the Host to provide.
fn validateSharedLibrary(allocator: std.mem.Allocator, bytes: []const u8, msvc_runtime: bool) !binary.Image {
    const image = try binary.read(allocator, bytes);
    var found_discovery = false;
    var unexpected: usize = 0;
    for (image.exports) |name| {
        if (std.mem.eql(u8, name, discovery_symbol)) {
            found_discovery = true;
            continue;
        }
        if (isInertToolchainExport(image.format, name)) continue;
        std.debug.print("AgentCore shared library exports {s}\n", .{name});
        unexpected += 1;
    }
    if (unexpected != 0) return error.UnexpectedExport;
    if (!found_discovery) return error.MissingDiscoverySymbol;
    for (image.needed) |name| {
        if (binary.isSystemLibrary(image.format, name)) continue;
        if (msvc_runtime and image.format == .pe and std.ascii.eqlIgnoreCase(name, "vcruntime140.dll")) continue;
        std.debug.print("AgentCore shared library needs {s}, which a clean host may lack\n", .{name});
        return error.NonSystemDependency;
    }
    return image;
}

fn validateArchiveSymbols(archive: []const u8) !void {
    if (archive.len < archive_magic.len + header_size or
        !std.mem.eql(u8, archive[0..archive_magic.len], archive_magic))
        return error.InvalidArchive;

    const header = archive[archive_magic.len..][0..header_size];
    const member_name = std.mem.trim(u8, header[0..16], " ");
    if (!std.mem.eql(u8, header[58..60], "`\n")) return error.InvalidArchive;

    const size_text = std.mem.trim(u8, header[48..58], " ");
    const member_size = std.fmt.parseInt(usize, size_text, 10) catch return error.InvalidArchive;
    const data_start = archive_magic.len + header_size;
    const data_end = std.math.add(usize, data_start, member_size) catch return error.InvalidArchive;
    if (data_end > archive.len) return error.InvalidArchive;
    var data = archive[data_start..data_end];
    var logical_name = member_name;
    if (std.mem.startsWith(u8, member_name, "#1/")) {
        const name_size = std.fmt.parseInt(usize, member_name[3..], 10) catch return error.InvalidArchive;
        if (name_size > data.len) return error.InvalidArchive;
        logical_name = std.mem.trim(u8, data[0..name_size], "\x00");
        data = data[name_size..];
    }
    if (std.mem.eql(u8, logical_name, "/")) {
        try validateGnuLinkerMember(u32, data);
    } else if (std.mem.eql(u8, logical_name, "/SYM64/")) {
        try validateGnuLinkerMember(u64, data);
    } else if (std.mem.startsWith(u8, logical_name, "__.SYMDEF")) {
        try validateBsdLinkerMember(data);
    } else {
        return error.MissingLinkerMember;
    }
}

fn validateGnuLinkerMember(comptime Offset: type, data: []const u8) !void {
    comptime {
        if (Offset != u32 and Offset != u64)
            @compileError("GNU archive offsets must be u32 or u64");
    }
    const word_size = @sizeOf(Offset);
    if (data.len < word_size) return error.InvalidArchive;
    const raw_symbol_count = std.mem.readInt(Offset, data[0..word_size], .big);
    const symbol_count = std.math.cast(usize, raw_symbol_count) orelse
        return error.InvalidArchive;
    const offsets_size = std.math.mul(usize, symbol_count, word_size) catch
        return error.InvalidArchive;
    const names_start = std.math.add(usize, word_size, offsets_size) catch
        return error.InvalidArchive;
    if (names_start > data.len) return error.InvalidArchive;

    var names = data[names_start..];
    var found_discovery = false;
    var index: usize = 0;
    while (index < symbol_count) : (index += 1) {
        const end = std.mem.indexOfScalar(u8, names, 0) orelse return error.InvalidArchive;
        try checkSymbol(names[0..end], &found_discovery);
        names = names[end + 1 ..];
    }
    if (!found_discovery) return error.MissingDiscoverySymbol;
}

fn validateBsdLinkerMember(data: []const u8) !void {
    if (data.len < 8) return error.InvalidArchive;
    const ranlib_bytes = std.mem.readInt(u32, data[0..4], .little);
    if (ranlib_bytes % 8 != 0) return error.InvalidArchive;
    const string_size_offset = std.math.add(usize, 4, ranlib_bytes) catch return error.InvalidArchive;
    const strings_start = std.math.add(usize, string_size_offset, 4) catch return error.InvalidArchive;
    if (strings_start > data.len) return error.InvalidArchive;
    const string_size = std.mem.readInt(u32, data[string_size_offset..][0..4], .little);
    const strings_end = std.math.add(usize, strings_start, string_size) catch return error.InvalidArchive;
    if (strings_end > data.len) return error.InvalidArchive;
    const strings = data[strings_start..strings_end];

    var found_discovery = false;
    var entry_offset: usize = 4;
    while (entry_offset < string_size_offset) : (entry_offset += 8) {
        const string_offset = std.mem.readInt(u32, data[entry_offset..][0..4], .little);
        if (string_offset >= strings.len) return error.InvalidArchive;
        const tail = strings[string_offset..];
        const end = std.mem.indexOfScalar(u8, tail, 0) orelse return error.InvalidArchive;
        try checkSymbol(tail[0..end], &found_discovery);
    }
    if (!found_discovery) return error.MissingDiscoverySymbol;
}

fn checkSymbol(raw_symbol: []const u8, found_discovery: *bool) !void {
    if (std.mem.startsWith(u8, raw_symbol, "__imp_")) return error.ImportLibrarySymbol;
    const symbol = if (std.mem.startsWith(u8, raw_symbol, "_")) raw_symbol[1..] else raw_symbol;
    if (std.mem.eql(u8, symbol, "metask_agentcore_get_api")) found_discovery.* = true;
    if (std.mem.startsWith(u8, symbol, "metacodes_agentcore_") or
        std.mem.startsWith(u8, symbol, "mc_") or
        std.mem.startsWith(u8, symbol, "MC_") or
        std.mem.startsWith(u8, symbol, "metask_agentcore_agentcore_"))
        return error.ForbiddenLegacySymbol;
}

test "archive symbol gate accepts only the new discovery namespace" {
    const symbols = "metask_agentcore_get_api\x00another_global\x00";
    var data: [4 + 2 * 4 + symbols.len]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 2, .big);
    @memset(data[4..12], 0);
    @memcpy(data[12..], symbols);
    try validateGnuLinkerMember(u32, &data);
}

test "archive symbol gate rejects old and duplicate namespaces" {
    const legacy = "metacodes_agentcore_get_api\x00";
    var legacy_data: [4 + 4 + legacy.len]u8 = undefined;
    std.mem.writeInt(u32, legacy_data[0..4], 1, .big);
    @memset(legacy_data[4..8], 0);
    @memcpy(legacy_data[8..], legacy);
    try std.testing.expectError(error.ForbiddenLegacySymbol, validateGnuLinkerMember(u32, &legacy_data));

    const duplicate = "metask_agentcore_agentcore_get_api\x00";
    var duplicate_data: [4 + 4 + duplicate.len]u8 = undefined;
    std.mem.writeInt(u32, duplicate_data[0..4], 1, .big);
    @memset(duplicate_data[4..8], 0);
    @memcpy(duplicate_data[8..], duplicate);
    try std.testing.expectError(error.ForbiddenLegacySymbol, validateGnuLinkerMember(u32, &duplicate_data));
}

test "archive symbol gate rejects missing discovery symbol" {
    const symbols = "another_global\x00";
    var data: [4 + 4 + symbols.len]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 1, .big);
    @memset(data[4..8], 0);
    @memcpy(data[8..], symbols);
    try std.testing.expectError(error.MissingDiscoverySymbol, validateGnuLinkerMember(u32, &data));
}

test "archive symbol gate rejects COFF import-library symbols" {
    const symbols = "metask_agentcore_get_api\x00__imp_metask_agentcore_get_api\x00";
    var data: [4 + 2 * 4 + symbols.len]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 2, .big);
    @memset(data[4..12], 0);
    @memcpy(data[12..], symbols);
    try std.testing.expectError(error.ImportLibrarySymbol, validateGnuLinkerMember(u32, &data));
}

test "GNU64 archive dispatch accepts discovery and rejects truncated offsets" {
    const symbols = "metask_agentcore_get_api\x00another_global\x00";
    var data: [8 + 2 * 8 + symbols.len]u8 = undefined;
    std.mem.writeInt(u64, data[0..8], 2, .big);
    @memset(data[8..24], 0);
    @memcpy(data[24..], symbols);

    var archive: [archive_magic.len + header_size + data.len]u8 = undefined;
    @memcpy(archive[0..archive_magic.len], archive_magic);
    const header = archive[archive_magic.len..][0..header_size];
    @memset(header, ' ');
    @memcpy(header[0.."/SYM64/".len], "/SYM64/");
    const size_text = try std.fmt.bufPrint(header[48..58], "{d}", .{data.len});
    @memset(header[48 + size_text.len .. 58], ' ');
    @memcpy(header[58..60], "`\n");
    @memcpy(archive[archive_magic.len + header_size ..], &data);
    try validateArchiveSymbols(&archive);

    var truncated: [8]u8 = undefined;
    std.mem.writeInt(u64, &truncated, std.math.maxInt(u64), .big);
    try std.testing.expectError(
        error.InvalidArchive,
        validateGnuLinkerMember(u64, &truncated),
    );
}

test "BSD archive symbol gate accepts Mach-O leading underscore" {
    const symbols = "\x00_metask_agentcore_get_api\x00";
    var data: [4 + 8 + 4 + symbols.len]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 8, .little);
    std.mem.writeInt(u32, data[4..8], 1, .little);
    @memset(data[8..12], 0);
    std.mem.writeInt(u32, data[12..16], symbols.len, .little);
    @memcpy(data[16..], symbols);
    try validateBsdLinkerMember(&data);
}

test "shared library gate accepts only the discovery export and system dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try binary.testElf(a, &.{
        .{ .name = discovery_symbol },
        .{ .name = "internal_helper", .visibility = 2 },
        .{ .name = "free", .defined = false },
    }, &.{ "libc.so.6", "libpthread.so.0" }, "libmetask_agentcore.so");
    const image = try validateSharedLibrary(a, good, false);
    try std.testing.expectEqual(@as(usize, 2), image.needed.len);

    const extra_export = try binary.testElf(a, &.{
        .{ .name = discovery_symbol },
        .{ .name = "__ubsan_handle_mul_overflow" },
    }, &.{"libc.so.6"}, null);
    try std.testing.expectError(error.UnexpectedExport, validateSharedLibrary(a, extra_export, false));

    const missing_entry = try binary.testElf(a, &.{
        .{ .name = "metacodes_agentcore_get_api", .visibility = 2 },
    }, &.{"libc.so.6"}, null);
    try std.testing.expectError(error.MissingDiscoverySymbol, validateSharedLibrary(a, missing_entry, false));

    const foreign_dependency = try binary.testElf(a, &.{
        .{ .name = discovery_symbol },
    }, &.{ "libc.so.6", "libstdc++.so.6" }, null);
    try std.testing.expectError(error.NonSystemDependency, validateSharedLibrary(a, foreign_dependency, false));
}

test "inert toolchain exports are format-specific" {
    try std.testing.expect(isInertToolchainExport(.pe, "_DllMainCRTStartup"));
    try std.testing.expect(isInertToolchainExport(.macho, "_mh_dylib_header"));
    try std.testing.expect(isInertToolchainExport(.macho, "__dso_handle"));
    try std.testing.expect(!isInertToolchainExport(.elf, "_DllMainCRTStartup"));
    try std.testing.expect(!isInertToolchainExport(.pe, "__dso_handle"));
    try std.testing.expect(!isInertToolchainExport(.macho, "roundq"));
}

test "the Visual C++ runtime is admitted only for MSVC-ABI DLLs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The flag never admits it on another format, nor anything else on PE.
    const elf = try binary.testElf(a, &.{.{ .name = discovery_symbol }}, &.{"VCRUNTIME140.dll"}, null);
    try std.testing.expectError(error.NonSystemDependency, validateSharedLibrary(a, elf, true));
    try std.testing.expectError(error.NonSystemDependency, validateSharedLibrary(a, elf, false));
}
