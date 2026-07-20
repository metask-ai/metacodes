const std = @import("std");

const archive_magic = "!<arch>\n";
const header_size = 60;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = std.process.Args.iterateAllocator(init.minimal.args, allocator) catch
        return error.InvalidArguments;
    defer args.deinit();
    _ = args.next();
    const archive_path = args.next() orelse return usage();
    if (args.next() != null) return usage();

    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        archive_path,
        allocator,
        .limited(1024 * 1024 * 1024),
    );
    try validateArchiveSymbols(bytes);
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: agentcore-symbol-gate <static-archive>\n", .{});
    return error.InvalidArguments;
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
        try validateGnuLinkerMember(data);
    } else if (std.mem.startsWith(u8, logical_name, "__.SYMDEF")) {
        try validateBsdLinkerMember(data);
    } else {
        return error.MissingLinkerMember;
    }
}

fn validateGnuLinkerMember(data: []const u8) !void {
    if (data.len < 4) return error.InvalidArchive;
    const symbol_count = std.mem.readInt(u32, data[0..4], .big);
    const offsets_size = std.math.mul(usize, symbol_count, 4) catch return error.InvalidArchive;
    const names_start = std.math.add(usize, 4, offsets_size) catch return error.InvalidArchive;
    if (names_start > data.len) return error.InvalidArchive;

    var names = data[names_start..];
    var found_discovery = false;
    var index: u32 = 0;
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
    try validateGnuLinkerMember(&data);
}

test "archive symbol gate rejects old and duplicate namespaces" {
    const legacy = "metacodes_agentcore_get_api\x00";
    var legacy_data: [4 + 4 + legacy.len]u8 = undefined;
    std.mem.writeInt(u32, legacy_data[0..4], 1, .big);
    @memset(legacy_data[4..8], 0);
    @memcpy(legacy_data[8..], legacy);
    try std.testing.expectError(error.ForbiddenLegacySymbol, validateGnuLinkerMember(&legacy_data));

    const duplicate = "metask_agentcore_agentcore_get_api\x00";
    var duplicate_data: [4 + 4 + duplicate.len]u8 = undefined;
    std.mem.writeInt(u32, duplicate_data[0..4], 1, .big);
    @memset(duplicate_data[4..8], 0);
    @memcpy(duplicate_data[8..], duplicate);
    try std.testing.expectError(error.ForbiddenLegacySymbol, validateGnuLinkerMember(&duplicate_data));
}

test "archive symbol gate rejects missing discovery symbol" {
    const symbols = "another_global\x00";
    var data: [4 + 4 + symbols.len]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 1, .big);
    @memset(data[4..8], 0);
    @memcpy(data[8..], symbols);
    try std.testing.expectError(error.MissingDiscoverySymbol, validateGnuLinkerMember(&data));
}

test "archive symbol gate rejects COFF import-library symbols" {
    const symbols = "metask_agentcore_get_api\x00__imp_metask_agentcore_get_api\x00";
    var data: [4 + 2 * 4 + symbols.len]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 2, .big);
    @memset(data[4..12], 0);
    @memcpy(data[12..], symbols);
    try std.testing.expectError(error.ImportLibrarySymbol, validateGnuLinkerMember(&data));
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
