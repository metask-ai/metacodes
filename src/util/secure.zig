//! Optimizer-resistant handling for allocator-owned sensitive byte buffers.

const std = @import("std");

pub fn zero(bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
}

/// `Allocator.free` writes `undefined` into the slice before invoking the
/// allocator vtable. Use rawFree after secureZero so the allocator receives
/// erased bytes rather than a debug poison pattern.
pub fn free(allocator: std.mem.Allocator, bytes: []u8) void {
    if (bytes.len == 0) return;
    zero(bytes);
    allocator.rawFree(bytes, .fromByteUnits(@alignOf(u8)), @returnAddress());
}
