const std = @import("std");

const zstd_c = @cImport({
    @cInclude("zstd.h");
});

pub const compression_level: c_int = 22;
pub const window_log: c_int = 23; // 8 MiB: one large domain for real agent-memory redundancy.
pub const window_bytes: usize = 1 << window_log;
pub const decoder_scratch_bytes: usize = window_bytes + std.compress.zstd.block_size_max;

pub const Error = error{
    CompressionFailed,
    DecompressionFailed,
    InvalidRecord,
    RecordTooLarge,
};

fn checkZstd(code: usize) Error!usize {
    if (zstd_c.ZSTD_isError(code) != 0) return error.CompressionFailed;
    return code;
}

/// Compress one canonical checkpoint payload as one checksum-bearing frame.
/// Structural sections are compacted before this layer; this owner only owns
/// the portable compression boundary and its resource limits.
pub fn compressAlloc(allocator: std.mem.Allocator, payload: []const u8) (std.mem.Allocator.Error || Error)![]u8 {
    const bound = try checkZstd(zstd_c.ZSTD_compressBound(payload.len));
    const compressed = try allocator.alloc(u8, bound);
    errdefer allocator.free(compressed);

    const context = zstd_c.ZSTD_createCCtx() orelse return error.CompressionFailed;
    defer _ = zstd_c.ZSTD_freeCCtx(context);
    _ = try checkZstd(zstd_c.ZSTD_CCtx_setParameter(context, zstd_c.ZSTD_c_compressionLevel, compression_level));
    _ = try checkZstd(zstd_c.ZSTD_CCtx_setParameter(context, zstd_c.ZSTD_c_windowLog, window_log));
    _ = try checkZstd(zstd_c.ZSTD_CCtx_setParameter(context, zstd_c.ZSTD_c_checksumFlag, 1));
    _ = try checkZstd(zstd_c.ZSTD_CCtx_setParameter(context, zstd_c.ZSTD_c_contentSizeFlag, 1));

    const written = try checkZstd(zstd_c.ZSTD_compress2(
        context,
        compressed.ptr,
        compressed.len,
        payload.ptr,
        payload.len,
    ));
    return allocator.realloc(compressed, written);
}

/// Decode through Zig's standard-library implementation so the persisted
/// frame is not coupled to the bundled C decoder. `expected_size` comes from
/// the authenticated checkpoint header and bounds allocation before decoding.
pub fn decompressAlloc(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    expected_size: usize,
) (std.mem.Allocator.Error || Error)![]u8 {
    if (expected_size == 0 or compressed.len == 0) return error.InvalidRecord;
    const output = try allocator.alloc(u8, expected_size);
    errdefer allocator.free(output);
    var writer: std.Io.Writer = .fixed(output);
    var input: std.Io.Reader = .fixed(compressed);
    const scratch = try allocator.alloc(u8, decoder_scratch_bytes);
    defer allocator.free(scratch);
    var decoder: std.compress.zstd.Decompress = .init(&input, scratch, .{
        .window_len = window_bytes,
    });
    const written = decoder.reader.streamRemaining(&writer) catch return error.DecompressionFailed;
    if (decoder.err != null or written != expected_size or writer.end != expected_size) {
        return error.InvalidRecord;
    }
    return output;
}

test "checkpoint zstd C encoder interoperates with Zig decoder" {
    const allocator = std.testing.allocator;
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(allocator);
    for (0..32_768) |index| {
        try payload.print(allocator, "kind=verification relation=verified_by node={d} repeated-agent-memory-payload\n", .{index % 257});
    }

    const compressed = try compressAlloc(allocator, payload.items);
    defer allocator.free(compressed);
    try std.testing.expect(compressed.len < payload.items.len / 8);
    const restored = try decompressAlloc(allocator, compressed, payload.items.len);
    defer allocator.free(restored);
    try std.testing.expectEqualSlices(u8, payload.items, restored);
}

test "checkpoint zstd decoder fails closed for truncation and wrong size" {
    const allocator = std.testing.allocator;
    const payload = "canonical checkpoint payload canonical checkpoint payload" ** 128;
    const compressed = try compressAlloc(allocator, payload);
    defer allocator.free(compressed);
    try std.testing.expectError(
        error.DecompressionFailed,
        decompressAlloc(allocator, compressed[0 .. compressed.len - 1], payload.len),
    );
    try std.testing.expectError(
        error.InvalidRecord,
        decompressAlloc(allocator, compressed, payload.len + 1),
    );
}
