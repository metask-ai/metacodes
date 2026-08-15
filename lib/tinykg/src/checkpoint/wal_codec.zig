const std = @import("std");

const zstd_c = @cImport({
    @cInclude("zstd.h");
});

/// WAL records are independently decodable and physically capped at 64 KiB.
/// A 1 MiB window captures repeated mutation keys/values without paying the
/// checkpoint codec's 8 MiB decoder scratch on every replayed record.
pub const compression_level: c_int = 19;
pub const window_log: c_int = 20;
pub const window_bytes: usize = 1 << window_log;
pub const decoder_scratch_bytes: usize = window_bytes + std.compress.zstd.block_size_max;
pub const max_uncompressed_bytes: usize = 16 * 1024 * 1024;

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

pub fn compressAlloc(
    allocator: std.mem.Allocator,
    payload: []const u8,
) (std.mem.Allocator.Error || Error)![]u8 {
    if (payload.len == 0) return error.InvalidRecord;
    if (payload.len > max_uncompressed_bytes) return error.RecordTooLarge;
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

pub fn decompressAlloc(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    expected_size: usize,
) (std.mem.Allocator.Error || Error)![]u8 {
    if (compressed.len == 0 or expected_size == 0) return error.InvalidRecord;
    if (expected_size > max_uncompressed_bytes) return error.RecordTooLarge;
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

test "checkpoint WAL codec round trips a mutation-shaped payload" {
    const allocator = std.testing.allocator;
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(allocator);
    for (0..4096) |index| {
        try payload.print(allocator, "property_upsert owner={} key=status value=claimed\n", .{index % 257});
    }
    const compressed = try compressAlloc(allocator, payload.items);
    defer allocator.free(compressed);
    try std.testing.expect(compressed.len < payload.items.len / 4);
    const restored = try decompressAlloc(allocator, compressed, payload.items.len);
    defer allocator.free(restored);
    try std.testing.expectEqualSlices(u8, payload.items, restored);
}
