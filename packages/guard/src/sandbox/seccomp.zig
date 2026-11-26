//! Linux syscall hardening, installed by bubblewrap AFTER namespace setup.
//! Never install a filter in the agent: only the sandbox and its descendants
//! inherit it. The default-allow policy preserves toolchains while removing
//! kernel interfaces that bypass the mount/process/network boundaries.
const std = @import("std");
const builtin = @import("builtin");

pub const Network = enum { shared, isolated };

// Linux UAPI sock_filter and seccomp_data offsets. The supported ABIs are
// little endian; the pipe contains native sock_filter records, not bytecode
// for a userspace interpreter. No libseccomp/runtime dependency is needed.
const Instruction = extern struct { code: u16, jt: u8 = 0, jf: u8 = 0, k: u32 };
const load: u16 = 0x20; // BPF_LD | BPF_W | BPF_ABS
const equal: u16 = 0x15; // BPF_JMP | BPF_JEQ | BPF_K
const greater_equal: u16 = 0x35;
const bits_set: u16 = 0x45;
const bit_and: u16 = 0x54; // BPF_ALU | BPF_AND | BPF_K
const ret: u16 = 0x06;
const kill: u32 = 0x80000000; // SECCOMP_RET_KILL_PROCESS
const allow: u32 = 0x7fff0000;
const eperm: u32 = 0x00050001; // SECCOMP_RET_ERRNO | EPERM
const enosys: u32 = 0x00050026; // clone3 must fall back to inspectable clone
const namespace_mask: u32 = 0x7e020080; // all CLONE_NEW*, including NEWTIME

pub const Program = struct {
    instructions: [256]Instruction = undefined,
    len: usize = 0,

    pub fn bytes(self: *const Program) []const u8 {
        return std.mem.sliceAsBytes(self.instructions[0..self.len]);
    }

    fn add(self: *Program, instruction: Instruction) void {
        std.debug.assert(self.len < self.instructions.len);
        self.instructions[self.len] = instruction;
        self.len += 1;
    }

    fn deny(self: *Program, nr: u32, verdict: u32) void {
        self.add(.{ .code = equal, .k = nr, .jf = 1 });
        self.add(.{ .code = ret, .k = verdict });
    }
};

pub fn supported() bool {
    return builtin.os.tag == .linux and
        (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64);
}

pub fn generate(arch: std.Target.Cpu.Arch, network: Network) error{UnsupportedArchitecture}!Program {
    return switch (arch) {
        .x86_64 => generateFor(std.os.linux.syscalls.X64, 0xc000003e, network),
        .aarch64 => generateFor(std.os.linux.syscalls.Arm64, 0xc00000b7, network),
        else => error.UnsupportedArchitecture,
    };
}

fn generateFor(comptime Sys: type, audit_arch: u32, network: Network) Program {
    var p: Program = .{};
    p.add(.{ .code = load, .k = 4 }); // seccomp_data.arch
    p.add(.{ .code = equal, .k = audit_arch, .jt = 1 });
    p.add(.{ .code = ret, .k = kill }); // compat/int 0x80 is not our ABI
    p.add(.{ .code = load, .k = 0 }); // seccomp_data.nr
    // All reviewed native syscall numbers are below 512. On x86_64 this
    // rejects x32's bit 30 AND the untagged 512..547 x32 confusion on kernels
    // before 5.4. Future syscalls at/above 512 require a policy review.
    p.add(.{ .code = greater_equal, .k = 512, .jf = 1 });
    p.add(.{ .code = ret, .k = kill });
    inline for (.{
        "io_uring_setup",    "io_uring_enter",    "io_uring_register",
        "ptrace",            "process_vm_readv",  "process_vm_writev",
        "kcmp",              "bpf",               "perf_event_open",
        "userfaultfd",       "pidfd_getfd",       "setns",
        "unshare",           "mount",             "umount2",
        "pivot_root",        "chroot",            "open_tree",
        "move_mount",        "fsopen",            "fsconfig",
        "fsmount",           "fspick",            "mount_setattr",
        "open_by_handle_at", "name_to_handle_at", "init_module",
        "finit_module",      "delete_module",     "kexec_load",
        "kexec_file_load",   "reboot",            "swapon",
        "swapoff",           "syslog",            "acct",
        "quotactl",          "quotactl_fd",       "add_key",
        "request_key",       "keyctl",            "lookup_dcookie",
        "iopl",              "ioperm",            "modify_ldt",
        "uselib",            "fanotify_init",     "fanotify_mark",
    }) |name| {
        if (@hasField(Sys, name)) p.deny(@intFromEnum(@field(Sys, name)), eperm);
    }
    p.deny(@intFromEnum(Sys.clone3), enosys); // pointer arguments cannot be inspected
    p.add(.{ .code = equal, .k = @intFromEnum(Sys.clone), .jf = 3 });
    p.add(.{ .code = load, .k = 16 }); // args[0], flags on both supported ABIs
    p.add(.{ .code = bits_set, .k = namespace_mask, .jf = 1 });
    p.add(.{ .code = ret, .k = eperm });
    p.add(.{ .code = load, .k = 0 });

    // --new-session also disconnects the controlling terminal. Deny terminal
    // input injection explicitly even if a caller supplies an inherited tty.
    p.add(.{ .code = equal, .k = @intFromEnum(Sys.ioctl), .jf = 5 });
    p.add(.{ .code = load, .k = 24 }); // args[1], ioctl request (low 32 bits)
    p.deny(0x5412, eperm); // TIOCSTI
    p.deny(0x541c, eperm); // TIOCLINUX
    p.add(.{ .code = load, .k = 0 });

    // A read-only bind does NOT protect a host AF_UNIX listener (Docker,
    // ssh-agent, build daemons). Never create named Unix sockets, even with
    // shared networking. Keep connected socketpairs and sendmsg/recvmsg for
    // descendants and explicitly inherited SCM_RIGHTS helper channels. The
    // caller must pass only intended descriptors; bwrap passes them through.
    if (network == .shared) {
        p.add(.{ .code = equal, .k = @intFromEnum(Sys.socket), .jf = 5 });
        p.add(.{ .code = load, .k = 16 });
        p.add(.{ .code = equal, .k = 2, .jt = 2 }); // AF_INET
        p.add(.{ .code = equal, .k = 10, .jt = 1 }); // AF_INET6
        p.add(.{ .code = ret, .k = eperm });
        p.add(.{ .code = ret, .k = allow });
    } else p.deny(@intFromEnum(Sys.socket), eperm);
    // Datagram pairs can be retargeted with connect/sendto/sendmsg to a host
    // pathname, so only connected STREAM/SEQPACKET pairs are safe here.
    p.add(.{ .code = equal, .k = @intFromEnum(Sys.socketpair), .jf = 8 });
    p.add(.{ .code = load, .k = 16 });
    p.add(.{ .code = equal, .k = 1, .jt = 1 }); // AF_UNIX socketpair only
    p.add(.{ .code = ret, .k = eperm });
    p.add(.{ .code = load, .k = 24 }); // args[1], socket type + CLOEXEC/NONBLOCK
    p.add(.{ .code = bit_and, .k = 0xf }); // SOCK_TYPE_MASK
    p.add(.{ .code = equal, .k = 1, .jt = 2 }); // SOCK_STREAM
    p.add(.{ .code = equal, .k = 5, .jt = 1 }); // SOCK_SEQPACKET
    p.add(.{ .code = ret, .k = eperm });
    p.add(.{ .code = ret, .k = allow });
    return p;
}

// No mutable temporary file, parent-owned fd or asynchronous cleanup. Preserve
// the caller's stdin on fd 8, pipe builtin printf's decoded BPF to fd 9, restore
// stdin, then exec bwrap in the final pipeline stage. The shell waits for that
// stage and returns its status. A failed/truncated printf cannot produce a
// valid program: ALLOW is the final instruction, and earlier jumps target it.
// command bypasses shell functions; no PATH lookup or eval handles the BPF.
const launcher =
    \\if command test -e /proc/self/fd/8 || command test -e /proc/self/fd/9; then
    \\    command printf '%s\n' 'sandbox: descriptors 8 and 9 are reserved for seccomp delivery' >&2
    \\    exit 125
    \\fi
    \\exec 8<&0 || exit 125
    \\command printf '%b' "$1" 8<&- | {
    \\    exec 9<&0 0<&8 8<&- || exit 125
    \\    shift
    \\    exec "$@"
    \\}
;

/// Fully owned argv; no fd has to survive the caller's process-spawn API.
/// All arguments are positional, never interpolated into launcher shell code.
/// The encoded filter is ordinary argv memory, so ShellWrap detachment needs
/// no resource transfer, and any number of independent launches may reuse it.
/// Fds 8/9 are reserved in the launcher; callers passing an explicit channel
/// must use another fd. A collision refuses execution rather than clobbering it.
pub fn launchArgv(allocator: std.mem.Allocator, network: Network, argv: []const []const u8) error{ OutOfMemory, UnsupportedArchitecture }![]const []const u8 {
    const program = try generate(builtin.cpu.arch, network);
    const encoded = try allocator.alloc(u8, program.bytes().len * 5);
    defer allocator.free(encoded);
    for (program.bytes(), 0..) |byte, i| {
        encoded[i * 5 ..][0..5].* = .{ '\\', '0', '0' + (byte >> 6), '0' + ((byte >> 3) & 7), '0' + (byte & 7) };
    }
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |arg| allocator.free(arg);
        result.deinit(allocator);
    }
    for ([_][]const []const u8{ &.{ "/bin/sh", "-c", launcher, "metacodes-seccomp", encoded }, argv }) |part| {
        for (part) |arg| {
            const owned = try allocator.dupe(u8, arg);
            errdefer allocator.free(owned);
            try result.append(allocator, owned);
        }
    }
    return result.toOwnedSlice(allocator);
}

test "seccomp: unsupported architectures fail closed" {
    try std.testing.expectError(error.UnsupportedArchitecture, generate(.x86, .shared));
    try std.testing.expectError(error.UnsupportedArchitecture, generate(.riscv64, .isolated));
    try std.testing.expectError(error.UnsupportedArchitecture, generate(.aarch64_be, .shared));
}
