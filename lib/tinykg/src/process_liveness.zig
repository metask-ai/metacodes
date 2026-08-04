const std = @import("std");
const builtin = @import("builtin");

const WindowsProcessApi = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;

    extern "kernel32" fn OpenProcess(
        desired_access: windows.DWORD,
        inherit_handle: windows.BOOL,
        process_id: windows.DWORD,
    ) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn WaitForSingleObject(
        handle: windows.HANDLE,
        milliseconds: windows.DWORD,
    ) callconv(.winapi) windows.DWORD;
} else struct {};

const windows_process_synchronize: u32 = 0x0010_0000;
const windows_wait_object_0: u32 = 0x0000_0000;
const windows_wait_timeout: u32 = 0x0000_0102;

fn posixKillErrorMeansAlive(err: std.posix.KillError) bool {
    return switch (err) {
        error.ProcessNotFound => false,
        // Permission failures and undocumented OS errors do not prove that
        // the process exited. Reclamation must fail safe in both cases.
        else => true,
    };
}

pub fn currentId() u64 {
    return switch (builtin.os.tag) {
        .windows => @intCast(std.os.windows.GetCurrentProcessId()),
        .linux => @intCast(std.os.linux.getpid()),
        else => if (builtin.link_libc) @intCast(std.c.getpid()) else 1,
    };
}

pub fn isAlive(pid: u64) bool {
    if (pid == 0) return false;
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const process_id = std.math.cast(windows.DWORD, pid) orelse return false;
        const handle = WindowsProcessApi.OpenProcess(windows_process_synchronize, .FALSE, process_id) orelse {
            return switch (windows.GetLastError()) {
                .INVALID_PARAMETER => false,
                // Protected processes may deny SYNCHRONIZE even while alive.
                // Reclamation must fail safe: stale state costs space, while
                // deleting state owned by a live process breaks correctness.
                else => true,
            };
        };
        defer windows.CloseHandle(handle);
        return switch (WindowsProcessApi.WaitForSingleObject(handle, 0)) {
            windows_wait_object_0 => false,
            windows_wait_timeout => true,
            else => true,
        };
    }

    const native_pid = std.math.cast(std.posix.pid_t, pid) orelse return false;
    std.posix.kill(native_pid, @enumFromInt(0)) catch |err| return posixKillErrorMeansAlive(err);
    return true;
}

test "current process is alive" {
    try std.testing.expect(isAlive(currentId()));
}

test "ambiguous POSIX liveness errors fail safe" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    try std.testing.expect(!posixKillErrorMeansAlive(error.ProcessNotFound));
    try std.testing.expect(posixKillErrorMeansAlive(error.PermissionDenied));
    try std.testing.expect(posixKillErrorMeansAlive(error.Unexpected));
}
