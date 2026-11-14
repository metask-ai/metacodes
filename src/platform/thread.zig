//! Thread creation with a stated stack (#503).
//!
//! `std.Thread.spawn` defaults to a 16 MiB stack. On POSIX that is only an
//! address-space reservation, but on Windows Zig 0.16 passes the size to
//! `NtCreateThreadEx` as the stack *commit* (the reserve is the executable's
//! default, raised to the commit when smaller): every such thread charges its
//! whole 16 MiB against the process's private commit for as long as it lives,
//! touched or not. An AgentCore Session that had streamed one Run kept three of
//! them (its provider's two `std.Io.Threaded` pool workers and the stream
//! liveness monitor), about 50 MB per idle Session on Windows.
//!
//! So no production thread takes the default: every spawn names a `Stack`
//! class, and `std.Io.Threaded` pool workers get `Stack.io_worker` through
//! `signal.threadedIo`. On Windows a thread's stack can grow no further than
//! its commit unless the host executable reserves more, so a class's size is
//! the depth its threads can rely on everywhere: the sizes below come from
//! measuring what the threads of each class run (see each class). The rule is
//! enforced by `zig build test:thread-stack`
//! (scripts/tests/test_thread_stack_discipline.py): outside this file and test
//! blocks, `std.Thread.spawn` is not called directly.

const std = @import("std");
const builtin = @import("builtin");

pub const Stack = enum {
    /// Threads that wait, poll and run short, non-recursive callbacks: liveness
    /// monitors and similar watchdogs. A complete HTTPS fetch (DNS, connect,
    /// TLS 1.3 handshake with certificate verification, body) peaks below
    /// 160 KiB in ReleaseSafe on macOS; a waiter does strictly less.
    waiter,
    /// `std.Io.Threaded` pool workers. They run the tasks that `Io.async` /
    /// `Io.concurrent` hand them: std's `HostName.connect` (DNS lookup and
    /// connection attempts, below 48 KiB) and this repository's racing request
    /// tasks (telemetry export, TinyKG transport, JEV client), each a whole
    /// HTTP(S) exchange. Measured peak for a complete HTTPS fetch on a worker:
    /// 160 KiB in ReleaseSafe, 544 KiB in Debug (macOS, aarch64); 2 MiB keeps
    /// almost 4x the Debug peak. Pool workers live as long as their
    /// `std.Io.Threaded`, which for a provider is the Session's lifetime.
    io_worker,
    /// Threads that run the agent loop, tools, plugins, parsers or any other
    /// code whose recursion depth follows its input. Keeps std's default.
    full,

    /// The stack size to ask for: the depth the class's threads rely on, plus
    /// `static_tls_allowance` where the thread library takes static TLS out of
    /// the stack. `full` stays exactly std's default.
    pub fn bytes(stack: Stack) usize {
        return switch (stack) {
            .waiter => 256 * 1024 + static_tls_allowance,
            .io_worker => 2 * 1024 * 1024 + static_tls_allowance,
            .full => std.Thread.SpawnConfig.default_stack_size,
        };
    }
};

/// glibc places a new thread's static TLS inside the stack it is given and
/// refuses the thread (`pthread_create` returns EINVAL, which std treats as
/// unreachable) when the TLS does not fit. Zig 0.16's std puts a per-thread
/// alternate signal stack of `std.options.signal_stack_size` (256 KiB by
/// default) in that TLS, so a 256 KiB stack cannot even start there, and every
/// other stack loses that much depth. On Linux each class asks for that much
/// more, plus 256 KiB for the TLS of the executable and the other libraries it
/// loaded (this repository's own thread-locals are a few hundred bytes). A
/// Linux stack is an address-space reservation, not a commit, so the allowance
/// costs no memory. macOS and Windows keep TLS outside the stack.
pub const static_tls_allowance: usize = if (builtin.os.tag == .linux)
    @as(usize, @intCast(std.options.signal_stack_size orelse 0)) + 256 * 1024
else
    0;

comptime {
    // `full` must stay what std gives an unconfigured thread: moving a site to
    // `spawn(.full, ...)` is then a no-op, and `signal.threadedIo` recognises
    // an unconfigured `stack_size` by this value.
    std.debug.assert(Stack.full.bytes() == std.Thread.SpawnConfig.default_stack_size);
    std.debug.assert(Stack.waiter.bytes() < Stack.io_worker.bytes());
    std.debug.assert(Stack.io_worker.bytes() < Stack.full.bytes());
}

/// `std.Thread.spawn` with the stack of `stack`.
pub fn spawn(stack: Stack, comptime function: anytype, args: anytype) std.Thread.SpawnError!std.Thread {
    return std.Thread.spawn(.{ .stack_size = stack.bytes() }, function, args);
}

// --- Test support -----------------------------------------------------------

/// What the calling thread's stack costs: on Windows the committed bytes of its
/// stack reservation (what private commit counts), elsewhere the stack size the
/// thread was created with. Null where this file cannot ask.
pub fn currentStackBytes() ?usize {
    switch (builtin.os.tag) {
        .windows => {
            // MEMORY_BASIC_INFORMATION's layout below is the 64-bit one.
            if (@sizeOf(usize) != 8) return null;
            var low: usize = 0;
            var high: usize = 0;
            win32.GetCurrentThreadStackLimits(&low, &high);
            var committed: usize = 0;
            var address = low;
            while (address < high) {
                var info: win32.MemoryBasicInformation = undefined;
                if (win32.VirtualQuery(@ptrFromInt(address), &info, @sizeOf(win32.MemoryBasicInformation)) == 0) return null;
                const region_end = @min(@intFromPtr(info.BaseAddress) + info.RegionSize, high);
                if (info.State == win32.MEM_COMMIT) committed += region_end - address;
                address = region_end;
            }
            return committed;
        },
        .macos => return posix_stack.pthread_get_stacksize_np(std.c.pthread_self()),
        .linux => {
            if (!builtin.link_libc) return null;
            var attr: std.c.pthread_attr_t = undefined;
            if (posix_stack.pthread_getattr_np(std.c.pthread_self(), &attr) != 0) return null;
            defer _ = std.c.pthread_attr_destroy(&attr);
            var size: usize = 0;
            if (posix_stack.pthread_attr_getstacksize(&attr, &size) != 0) return null;
            return size;
        },
        else => return null,
    }
}

const win32 = struct {
    const MEM_COMMIT: u32 = 0x1000;
    const MemoryBasicInformation = extern struct {
        BaseAddress: ?*anyopaque,
        AllocationBase: ?*anyopaque,
        AllocationProtect: u32,
        PartitionId: u16,
        RegionSize: usize,
        State: u32,
        Protect: u32,
        Type: u32,
    };
    extern "kernel32" fn GetCurrentThreadStackLimits(low: *usize, high: *usize) callconv(.winapi) void;
    extern "kernel32" fn VirtualQuery(address: ?*const anyopaque, buffer: *MemoryBasicInformation, length: usize) callconv(.winapi) usize;
};

const posix_stack = struct {
    extern "c" fn pthread_get_stacksize_np(thread: std.c.pthread_t) usize;
    extern "c" fn pthread_getattr_np(thread: std.c.pthread_t, attr: *std.c.pthread_attr_t) c_int;
    extern "c" fn pthread_attr_getstacksize(attr: *const std.c.pthread_attr_t, size: *usize) c_int;
};

const Probe = struct {
    bytes: ?usize = null,
    fn run(probe: *Probe) void {
        probe.bytes = currentStackBytes();
    }
};

fn spawnedStackBytes(stack: Stack) !usize {
    var probe: Probe = .{};
    const thread = try spawn(stack, Probe.run, .{&probe});
    thread.join();
    return probe.bytes orelse error.SkipZigTest;
}

/// A thread of `expected` bytes costs that much: the commit on Windows can carry
/// a guard page or two beyond it, glibc's stack size the same.
fn expectStackOf(expected: usize, actual: usize) !void {
    if (actual < expected or actual > expected + 64 * 1024) {
        std.debug.print("stack: expected {d} bytes (+64 KiB), got {d}\n", .{ expected, actual });
        return error.TestUnexpectedResult;
    }
}

test "each Stack class gives its threads that stack, and on Windows that commit" {
    inline for (.{ Stack.waiter, Stack.io_worker }) |stack| {
        try expectStackOf(stack.bytes(), try spawnedStackBytes(stack));
    }
}

test "control: a thread with std's default stack costs 16 MiB, which on Windows is commit" {
    // The cost #503 measured: three of these per idle Session on Windows.
    try expectStackOf(std.Thread.SpawnConfig.default_stack_size, try spawnedStackBytes(.full));
}

test "signal.threadedIo gives its pool workers the io_worker stack" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var threaded = @import("signal.zig").threadedIo(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Task = struct {
        fn run() ?usize {
            return currentStackBytes();
        }
    };
    // `concurrent` always runs the task on a pool worker, never inline.
    var future = try io.concurrent(Task.run, .{});
    const bytes = future.await(io) orelse return error.SkipZigTest;
    try expectStackOf(Stack.io_worker.bytes(), bytes);
}

test "signal.threadedIo keeps a stack size its caller states" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var threaded = @import("signal.zig").threadedIo(std.testing.allocator, .{ .stack_size = Stack.waiter.bytes() });
    defer threaded.deinit();
    try std.testing.expectEqual(Stack.waiter.bytes(), threaded.stack_size);
}
