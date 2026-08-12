const std = @import("std");
const builtin = @import("builtin");

/// Create a read-only file mapping without prefaulting pages on POSIX.
///
/// Zig 0.16 maps `populate=false` to an empty NtCreateSection
/// AllocationAttributes value, which Windows rejects with
/// INVALID_PARAMETER_6.  Windows therefore needs populate=true to request a
/// valid SEC_COMMIT section; on Linux the false value preserves lazy paging.
pub fn create(io: std.Io, file: std.Io.File, len: usize) !std.Io.File.MemoryMap {
    return std.Io.File.MemoryMap.create(io, file, .{
        .len = len,
        .protection = .{ .read = true, .write = false },
        .populate = builtin.os.tag == .windows,
    });
}
