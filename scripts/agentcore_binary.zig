//! Reads what the dynamic loader sees in an AgentCore shared library: the
//! symbols it exports and the libraries it needs. ELF64, Mach-O 64 and PE32+
//! little-endian images only (the ABI requires a 64-bit pointer ABI). Every
//! read is bounds-checked; a malformed image is an error, never a guess.

const std = @import("std");

pub const Format = enum { elf, macho, pe };

pub const Error = error{ OutOfMemory, InvalidImage, UnsupportedImage };

/// Names borrow `bytes` or come from `allocator` (Mach-O trie names); callers
/// pass an arena and keep `bytes` alive while they use the result.
pub const Image = struct {
    format: Format,
    /// Exported symbol names, Mach-O's leading underscore removed.
    exports: []const []const u8,
    /// Needed libraries as the loader names them (ELF DT_NEEDED sonames,
    /// Mach-O install names, PE DLL names), in image order.
    needed: []const []const u8,
    /// The library's own load name: ELF DT_SONAME, Mach-O LC_ID_DYLIB; null
    /// on PE, where the file name is the identity.
    install_name: ?[]const u8 = null,
};

pub fn read(allocator: std.mem.Allocator, bytes: []const u8) Error!Image {
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "\x7fELF")) return readElf(allocator, bytes);
    if (bytes.len >= 4 and std.mem.readInt(u32, bytes[0..4], .little) == 0xfeedfacf) return readMachO(allocator, bytes);
    if (bytes.len >= 2 and std.mem.eql(u8, bytes[0..2], "MZ")) return readPe(allocator, bytes);
    return error.UnsupportedImage;
}

/// The system libraries a clean installation of each OS carries; the same
/// sets as scripts/check_kernel_self_contained.py.
pub fn isSystemLibrary(format: Format, name: []const u8) bool {
    switch (format) {
        .macho => return std.mem.startsWith(u8, name, "/usr/lib/") or
            std.mem.startsWith(u8, name, "/System/Library/"),
        .elf => {
            for ([_][]const u8{ "libc.so.6", "libm.so.6", "libpthread.so.0", "libdl.so.2", "librt.so.1" }) |allowed|
                if (std.mem.eql(u8, name, allowed)) return true;
            return std.mem.startsWith(u8, name, "ld-linux") or std.mem.startsWith(u8, name, "ld64.so");
        },
        .pe => {
            var lower_buffer: [256]u8 = undefined;
            if (name.len > lower_buffer.len) return false;
            const lower = std.ascii.lowerString(&lower_buffer, name);
            for ([_][]const u8{
                "kernel32.dll", "ntdll.dll",   "advapi32.dll", "user32.dll",
                "ws2_32.dll",   "bcrypt.dll",  "msvcrt.dll",   "ucrtbase.dll",
                "shell32.dll",  "ole32.dll",   "iphlpapi.dll", "psapi.dll",
                "userenv.dll",  "dbghelp.dll", "secur32.dll",  "crypt32.dll",
                "shlwapi.dll",
            }) |allowed| if (std.mem.eql(u8, lower, allowed)) return true;
            return std.mem.startsWith(u8, lower, "api-ms-win-");
        },
    }
}

fn slice(bytes: []const u8, offset: u64, len: u64) Error![]const u8 {
    const start = std.math.cast(usize, offset) orelse return error.InvalidImage;
    const count = std.math.cast(usize, len) orelse return error.InvalidImage;
    const end = std.math.add(usize, start, count) catch return error.InvalidImage;
    if (end > bytes.len) return error.InvalidImage;
    return bytes[start..end];
}

fn int(comptime T: type, bytes: []const u8, offset: u64) Error!T {
    const raw = try slice(bytes, offset, @sizeOf(T));
    return std.mem.readInt(T, raw[0..@sizeOf(T)], .little);
}

fn cString(bytes: []const u8, offset: u64) Error![]const u8 {
    const start = std.math.cast(usize, offset) orelse return error.InvalidImage;
    if (start >= bytes.len) return error.InvalidImage;
    const end = std.mem.indexOfScalarPos(u8, bytes, start, 0) orelse return error.InvalidImage;
    return bytes[start..end];
}

// ---------------------------------------------------------------- ELF64

fn readElf(allocator: std.mem.Allocator, bytes: []const u8) Error!Image {
    if (bytes.len < 64) return error.InvalidImage;
    if (bytes[4] != 2 or bytes[5] != 1) return error.UnsupportedImage; // ELFCLASS64, little-endian
    const shoff = try int(u64, bytes, 0x28);
    const shentsize = try int(u16, bytes, 0x3a);
    const shnum = try int(u16, bytes, 0x3c);
    if (shoff == 0 or shentsize < 64) return error.InvalidImage;

    var exports: std.ArrayList([]const u8) = .empty;
    var needed: std.ArrayList([]const u8) = .empty;
    var install_name: ?[]const u8 = null;
    var saw_dynsym = false;
    var index: u64 = 0;
    while (index < shnum) : (index += 1) {
        const header = shoff + index * shentsize;
        const kind = try int(u32, bytes, header + 4);
        if (kind != 11 and kind != 6) continue; // SHT_DYNSYM, SHT_DYNAMIC
        const offset = try int(u64, bytes, header + 0x18);
        const size = try int(u64, bytes, header + 0x20);
        const link = try int(u32, bytes, header + 0x28);
        const entsize = try int(u64, bytes, header + 0x38);
        const strtab_header = shoff + @as(u64, link) * shentsize;
        if (link >= shnum) return error.InvalidImage;
        const strtab = try slice(bytes, try int(u64, bytes, strtab_header + 0x18), try int(u64, bytes, strtab_header + 0x20));
        if (kind == 11) {
            saw_dynsym = true;
            if (entsize < 24) return error.InvalidImage;
            var symbol: u64 = 0;
            while (symbol + entsize <= size) : (symbol += entsize) {
                const entry = offset + symbol;
                const name_offset = try int(u32, bytes, entry);
                const info = (try slice(bytes, entry + 4, 1))[0];
                const other = (try slice(bytes, entry + 5, 1))[0];
                const section = try int(u16, bytes, entry + 6);
                const binding = info >> 4;
                const symbol_type = info & 0xf;
                const visibility = other & 0x3;
                if (section == 0 or name_offset == 0) continue; // undefined or unnamed
                if (binding != 1 and binding != 2) continue; // GLOBAL, WEAK
                if (visibility != 0 and visibility != 3) continue; // DEFAULT, PROTECTED
                if (symbol_type == 3 or symbol_type == 4) continue; // SECTION, FILE
                exports.append(allocator, try cString(strtab, name_offset)) catch return error.OutOfMemory;
            }
        } else {
            if (entsize < 16) return error.InvalidImage;
            var entry: u64 = 0;
            while (entry + entsize <= size) : (entry += entsize) {
                const tag = try int(i64, bytes, offset + entry);
                if (tag == 0) break; // DT_NULL
                const value = try int(u64, bytes, offset + entry + 8);
                if (tag == 1) { // DT_NEEDED
                    needed.append(allocator, try cString(strtab, value)) catch return error.OutOfMemory;
                } else if (tag == 14) { // DT_SONAME
                    install_name = try cString(strtab, value);
                }
            }
        }
    }
    if (!saw_dynsym) return error.InvalidImage;
    return .{
        .format = .elf,
        .exports = exports.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .needed = needed.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .install_name = install_name,
    };
}

// ---------------------------------------------------------------- Mach-O 64

const LC_SYMTAB = 0x2;
const LC_DYSYMTAB = 0xb;
const LC_LOAD_DYLIB = 0xc;
const LC_ID_DYLIB = 0xd;
const LC_LAZY_LOAD_DYLIB = 0x20;
const LC_DYLD_INFO = 0x22;
const LC_DYLD_INFO_ONLY = 0x80000022;
const LC_LOAD_WEAK_DYLIB = 0x80000018;
const LC_REEXPORT_DYLIB = 0x8000001f;
const LC_LOAD_UPWARD_DYLIB = 0x80000023;
const LC_DYLD_EXPORTS_TRIE = 0x80000033;

fn readMachO(allocator: std.mem.Allocator, bytes: []const u8) Error!Image {
    if (bytes.len < 32) return error.InvalidImage;
    const ncmds = try int(u32, bytes, 16);
    var cursor: u64 = 32;
    var needed: std.ArrayList([]const u8) = .empty;
    var trie: ?[]const u8 = null;
    var install_name: ?[]const u8 = null;
    var symtab: ?struct { symoff: u32, nsyms: u32, stroff: u32, strsize: u32 } = null;
    var extdef: ?struct { first: u32, count: u32 } = null;
    var command: u32 = 0;
    while (command < ncmds) : (command += 1) {
        const cmd = try int(u32, bytes, cursor);
        const cmdsize = try int(u32, bytes, cursor + 4);
        if (cmdsize < 8) return error.InvalidImage;
        const body = try slice(bytes, cursor, cmdsize);
        switch (cmd) {
            LC_LOAD_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB => {
                const name_offset = try int(u32, body, 8);
                needed.append(allocator, try cString(body, name_offset)) catch return error.OutOfMemory;
            },
            LC_ID_DYLIB => install_name = try cString(body, try int(u32, body, 8)),
            LC_DYLD_EXPORTS_TRIE => trie = try slice(bytes, try int(u32, body, 8), try int(u32, body, 12)),
            LC_DYLD_INFO, LC_DYLD_INFO_ONLY => {
                const export_size = try int(u32, body, 44);
                if (export_size != 0) trie = try slice(bytes, try int(u32, body, 40), export_size);
            },
            LC_SYMTAB => symtab = .{
                .symoff = try int(u32, body, 8),
                .nsyms = try int(u32, body, 12),
                .stroff = try int(u32, body, 16),
                .strsize = try int(u32, body, 20),
            },
            LC_DYSYMTAB => extdef = .{ .first = try int(u32, body, 16), .count = try int(u32, body, 20) },
            else => {},
        }
        cursor += cmdsize;
    }

    var exports: std.ArrayList([]const u8) = .empty;
    if (trie) |data| {
        var prefix: std.ArrayList(u8) = .empty;
        try walkExportTrie(allocator, data, 0, &prefix, &exports, 0);
    } else {
        // Without an export trie the externally defined symtab range is what
        // dyld binds against.
        const table = symtab orelse return error.InvalidImage;
        const range = extdef orelse return error.InvalidImage;
        const strings = try slice(bytes, table.stroff, table.strsize);
        if (@as(u64, range.first) + range.count > table.nsyms) return error.InvalidImage;
        var symbol: u32 = 0;
        while (symbol < range.count) : (symbol += 1) {
            const entry = @as(u64, table.symoff) + (@as(u64, range.first) + symbol) * 16;
            const name_offset = try int(u32, bytes, entry);
            const n_type = (try slice(bytes, entry + 4, 1))[0];
            if (n_type & 0x10 != 0) continue; // N_PEXT: private extern
            exports.append(allocator, try cString(strings, name_offset)) catch return error.OutOfMemory;
        }
    }
    for (exports.items) |*name| {
        if (std.mem.startsWith(u8, name.*, "_")) name.* = name.*[1..];
    }
    return .{
        .format = .macho,
        .exports = exports.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .needed = needed.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .install_name = install_name,
    };
}

fn uleb(data: []const u8, cursor: *usize) Error!u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (cursor.* >= data.len) return error.InvalidImage;
        const byte = data[cursor.*];
        cursor.* += 1;
        result |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        if (shift >= 63) return error.InvalidImage;
        shift += 7;
    }
}

fn walkExportTrie(
    allocator: std.mem.Allocator,
    data: []const u8,
    node: usize,
    prefix: *std.ArrayList(u8),
    exports: *std.ArrayList([]const u8),
    depth: u32,
) Error!void {
    if (depth > 128 or node >= data.len) return error.InvalidImage;
    var cursor = node;
    const terminal_size = try uleb(data, &cursor);
    if (terminal_size != 0) {
        const name = allocator.dupe(u8, prefix.items) catch return error.OutOfMemory;
        exports.append(allocator, name) catch return error.OutOfMemory;
    }
    cursor = std.math.add(usize, cursor, std.math.cast(usize, terminal_size) orelse return error.InvalidImage) catch
        return error.InvalidImage;
    if (cursor >= data.len) return error.InvalidImage;
    const children = data[cursor];
    cursor += 1;
    var child: u8 = 0;
    while (child < children) : (child += 1) {
        const edge = try cString(data, cursor);
        cursor += edge.len + 1;
        const child_node = std.math.cast(usize, try uleb(data, &cursor)) orelse return error.InvalidImage;
        const restore = prefix.items.len;
        prefix.appendSlice(allocator, edge) catch return error.OutOfMemory;
        try walkExportTrie(allocator, data, child_node, prefix, exports, depth + 1);
        prefix.shrinkRetainingCapacity(restore);
    }
}

// ---------------------------------------------------------------- PE32+

const Section = struct { va: u32, size: u32, raw: u32, raw_size: u32 };

fn rvaToOffset(sections: []const Section, rva: u32) Error!u64 {
    for (sections) |section| {
        const span = @max(section.size, section.raw_size);
        if (rva >= section.va and rva - section.va < span) {
            const delta = rva - section.va;
            if (delta >= section.raw_size) return error.InvalidImage;
            return @as(u64, section.raw) + delta;
        }
    }
    return error.InvalidImage;
}

fn readPe(allocator: std.mem.Allocator, bytes: []const u8) Error!Image {
    const pe = try int(u32, bytes, 0x3c);
    if (!std.mem.eql(u8, try slice(bytes, pe, 4), "PE\x00\x00")) return error.InvalidImage;
    const coff = @as(u64, pe) + 4;
    const section_count = try int(u16, bytes, coff + 2);
    const optional_size = try int(u16, bytes, coff + 16);
    const optional = coff + 20;
    if (try int(u16, bytes, optional) != 0x20b) return error.UnsupportedImage; // PE32+
    const directory_count = try int(u32, bytes, optional + 108);
    const directories = optional + 112;

    var sections_buffer: [96]Section = undefined;
    if (section_count > sections_buffer.len) return error.InvalidImage;
    const section_table = optional + optional_size;
    for (sections_buffer[0..section_count], 0..) |*section, index| {
        const header = section_table + index * 40;
        section.* = .{
            .size = try int(u32, bytes, header + 8),
            .va = try int(u32, bytes, header + 12),
            .raw_size = try int(u32, bytes, header + 16),
            .raw = try int(u32, bytes, header + 20),
        };
    }
    const sections = sections_buffer[0..section_count];

    var exports: std.ArrayList([]const u8) = .empty;
    if (directory_count > 0) {
        const export_rva = try int(u32, bytes, directories);
        if (export_rva != 0) {
            const directory = try rvaToOffset(sections, export_rva);
            const name_count = try int(u32, bytes, directory + 24);
            const names = try rvaToOffset(sections, try int(u32, bytes, directory + 32));
            var index: u32 = 0;
            while (index < name_count) : (index += 1) {
                const name_rva = try int(u32, bytes, names + @as(u64, index) * 4);
                exports.append(allocator, try cString(bytes, try rvaToOffset(sections, name_rva))) catch
                    return error.OutOfMemory;
            }
        }
    }

    var needed: std.ArrayList([]const u8) = .empty;
    if (directory_count > 1) {
        const import_rva = try int(u32, bytes, directories + 8);
        if (import_rva != 0) {
            var descriptor = try rvaToOffset(sections, import_rva);
            while (true) : (descriptor += 20) {
                const name_rva = try int(u32, bytes, descriptor + 12);
                if (name_rva == 0) break;
                needed.append(allocator, try cString(bytes, try rvaToOffset(sections, name_rva))) catch
                    return error.OutOfMemory;
            }
        }
    }
    if (directory_count > 13) {
        const delay_rva = try int(u32, bytes, directories + 13 * 8);
        if (delay_rva != 0) {
            var descriptor = try rvaToOffset(sections, delay_rva);
            while (true) : (descriptor += 32) {
                const name_rva = try int(u32, bytes, descriptor + 4);
                if (name_rva == 0) break;
                needed.append(allocator, try cString(bytes, try rvaToOffset(sections, name_rva))) catch
                    return error.OutOfMemory;
            }
        }
    }
    return .{
        .format = .pe,
        .exports = exports.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .needed = needed.toOwnedSlice(allocator) catch return error.OutOfMemory,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "system library sets match the kernel self-containment check" {
    try testing.expect(isSystemLibrary(.elf, "libc.so.6"));
    try testing.expect(isSystemLibrary(.elf, "ld-linux-x86-64.so.2"));
    try testing.expect(!isSystemLibrary(.elf, "libstdc++.so.6"));
    try testing.expect(isSystemLibrary(.macho, "/usr/lib/libSystem.B.dylib"));
    try testing.expect(!isSystemLibrary(.macho, "/opt/homebrew/lib/libuv.1.dylib"));
    try testing.expect(isSystemLibrary(.pe, "KERNEL32.dll"));
    try testing.expect(isSystemLibrary(.pe, "api-ms-win-crt-runtime-l1-1-0.dll"));
    try testing.expect(!isSystemLibrary(.pe, "VCRUNTIME140.dll"));
}

test "unknown and truncated images are refused" {
    try testing.expectError(error.UnsupportedImage, read(testing.allocator, "not an image"));
    try testing.expectError(error.InvalidImage, read(testing.allocator, "\x7fELF\x02\x01\x01\x00"));
    try testing.expectError(error.InvalidImage, read(testing.allocator, "MZ"));
}

test "Mach-O export trie walk names every terminal" {
    // Root (0): no terminal, two children: "_a" -> node A at 12, "_bc" -> node
    // B at 16. Each node: terminal size 2, two terminal bytes, no children.
    const trie = [_]u8{
        0, 2, '_', 'a', 0, 12, '_', 'b', 'c', 0, 16, 0,
        2, 0, 0,   0,   2, 0,  0,   0,
    };
    var exports: std.ArrayList([]const u8) = .empty;
    defer {
        for (exports.items) |name| testing.allocator.free(name);
        exports.deinit(testing.allocator);
    }
    var prefix: std.ArrayList(u8) = .empty;
    defer prefix.deinit(testing.allocator);
    try walkExportTrie(testing.allocator, &trie, 0, &prefix, &exports, 0);
    try testing.expectEqual(@as(usize, 2), exports.items.len);
    try testing.expectEqualStrings("_a", exports.items[0]);
    try testing.expectEqualStrings("_bc", exports.items[1]);
}

pub const TestSymbol = struct {
    name: []const u8,
    /// 1 GLOBAL, 2 WEAK, 0 LOCAL
    binding: u8 = 1,
    /// 0 DEFAULT, 2 HIDDEN, 3 PROTECTED
    visibility: u8 = 0,
    defined: bool = true,
};

/// A minimal ELF64 shared object with the given dynamic symbols, DT_NEEDED
/// entries and soname, for exercising the reader and the symbol gate.
pub fn testElf(
    allocator: std.mem.Allocator,
    symbols: []const TestSymbol,
    needed: []const []const u8,
    soname: ?[]const u8,
) ![]u8 {
    var strings: std.ArrayList(u8) = .empty;
    defer strings.deinit(allocator);
    try strings.append(allocator, 0);
    var symbol_names = try allocator.alloc(u32, symbols.len);
    defer allocator.free(symbol_names);
    for (symbols, 0..) |symbol, index| {
        symbol_names[index] = @intCast(strings.items.len);
        try strings.appendSlice(allocator, symbol.name);
        try strings.append(allocator, 0);
    }
    var needed_names = try allocator.alloc(u32, needed.len);
    defer allocator.free(needed_names);
    for (needed, 0..) |name, index| {
        needed_names[index] = @intCast(strings.items.len);
        try strings.appendSlice(allocator, name);
        try strings.append(allocator, 0);
    }
    var soname_offset: u32 = 0;
    if (soname) |name| {
        soname_offset = @intCast(strings.items.len);
        try strings.appendSlice(allocator, name);
        try strings.append(allocator, 0);
    }

    const dynstr_offset: u64 = 64;
    const dynsym_offset: u64 = std.mem.alignForward(u64, dynstr_offset + strings.items.len, 8);
    const dynsym_size: u64 = (symbols.len + 1) * 24;
    const dynamic_offset = dynsym_offset + dynsym_size;
    const dynamic_count = needed.len + @intFromBool(soname != null) + 1;
    const dynamic_size: u64 = dynamic_count * 16;
    const section_offset = dynamic_offset + dynamic_size;
    const image = try allocator.alloc(u8, @intCast(section_offset + 4 * 64));
    @memset(image, 0);

    @memcpy(image[0..4], "\x7fELF");
    image[4] = 2;
    image[5] = 1;
    image[6] = 1;
    std.mem.writeInt(u16, image[16..18], 3, .little); // ET_DYN
    std.mem.writeInt(u16, image[18..20], 62, .little); // EM_X86_64
    std.mem.writeInt(u32, image[20..24], 1, .little);
    std.mem.writeInt(u64, image[0x28..0x30], section_offset, .little);
    std.mem.writeInt(u16, image[0x34..0x36], 64, .little);
    std.mem.writeInt(u16, image[0x3a..0x3c], 64, .little);
    std.mem.writeInt(u16, image[0x3c..0x3e], 4, .little);

    @memcpy(image[@intCast(dynstr_offset)..][0..strings.items.len], strings.items);
    for (symbols, 0..) |symbol, index| {
        const entry: usize = @intCast(dynsym_offset + (index + 1) * 24);
        std.mem.writeInt(u32, image[entry..][0..4], symbol_names[index], .little);
        image[entry + 4] = (symbol.binding << 4) | 2; // STT_FUNC
        image[entry + 5] = symbol.visibility;
        std.mem.writeInt(u16, image[entry + 6 ..][0..2], if (symbol.defined) 1 else 0, .little);
    }
    var dynamic: usize = @intCast(dynamic_offset);
    for (needed_names) |name| {
        std.mem.writeInt(i64, image[dynamic..][0..8], 1, .little); // DT_NEEDED
        std.mem.writeInt(u64, image[dynamic + 8 ..][0..8], name, .little);
        dynamic += 16;
    }
    if (soname != null) {
        std.mem.writeInt(i64, image[dynamic..][0..8], 14, .little); // DT_SONAME
        std.mem.writeInt(u64, image[dynamic + 8 ..][0..8], soname_offset, .little);
    }

    const Header = struct { kind: u32, offset: u64, size: u64, link: u32, entsize: u64 };
    const headers = [_]Header{
        .{ .kind = 0, .offset = 0, .size = 0, .link = 0, .entsize = 0 },
        .{ .kind = 3, .offset = dynstr_offset, .size = strings.items.len, .link = 0, .entsize = 0 },
        .{ .kind = 11, .offset = dynsym_offset, .size = dynsym_size, .link = 1, .entsize = 24 },
        .{ .kind = 6, .offset = dynamic_offset, .size = dynamic_size, .link = 1, .entsize = 16 },
    };
    for (headers, 0..) |header, index| {
        const base: usize = @intCast(section_offset + index * 64);
        std.mem.writeInt(u32, image[base + 4 ..][0..4], header.kind, .little);
        std.mem.writeInt(u64, image[base + 0x18 ..][0..8], header.offset, .little);
        std.mem.writeInt(u64, image[base + 0x20 ..][0..8], header.size, .little);
        std.mem.writeInt(u32, image[base + 0x28 ..][0..4], header.link, .little);
        std.mem.writeInt(u64, image[base + 0x38 ..][0..8], header.entsize, .little);
    }
    return image;
}

test "ELF reader reports default-visibility definitions, DT_NEEDED and DT_SONAME" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const image = try testElf(arena.allocator(), &.{
        .{ .name = "metask_agentcore_get_api" },
        .{ .name = "weak_export", .binding = 2 },
        .{ .name = "protected_export", .visibility = 3 },
        .{ .name = "hidden_symbol", .visibility = 2 },
        .{ .name = "local_symbol", .binding = 0 },
        .{ .name = "malloc", .defined = false },
    }, &.{ "libc.so.6", "libpthread.so.0" }, "libmetask_agentcore.so");
    const read_image = try read(arena.allocator(), image);
    try testing.expectEqual(Format.elf, read_image.format);
    try testing.expectEqual(@as(usize, 3), read_image.exports.len);
    try testing.expectEqualStrings("metask_agentcore_get_api", read_image.exports[0]);
    try testing.expectEqualStrings("weak_export", read_image.exports[1]);
    try testing.expectEqualStrings("protected_export", read_image.exports[2]);
    try testing.expectEqual(@as(usize, 2), read_image.needed.len);
    try testing.expectEqualStrings("libpthread.so.0", read_image.needed[1]);
    try testing.expectEqualStrings("libmetask_agentcore.so", read_image.install_name.?);
}
