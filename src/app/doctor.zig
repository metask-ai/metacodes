//! `metacodes doctor` (#78, #47 stage 3): where the runtime binaries this
//! build depends on resolve from, and whether they are the ones the build
//! expected. ripgrep goes through `toolchain.ripgrepResolution` and TinyKG
//! through `KgClient.resolveTinykgBinary` and `resolveTinykgdBinary` — the same decisions the tools make
//! at run time, taken without side effects (no Store is created, no daemon
//! contacted, nothing written). The expectations are the digests `build.zig`
//! pinned into `build_info` for the target; a target without a vendored
//! binary has none, and the check then only reports where the binary came
//! from. `--strict` turns an unresolved binary or a digest mismatch into exit
//! code 1 so an install step can fail closed on it.
//!
//! The two Lean kernels additionally carry provenance sidecars, and each one
//! is validated by its own loader: the formal kernel's v4 manifest plus build
//! receipt by `formal/provenance.zig`, the project kernel's v6 manifest by
//! `formal/project_provenance.zig`. The schemas are different documents, so a
//! sidecar read through the other kernel's loader is rejected, not tolerated.
//! A kernel named by its environment pair (`METACODES_<KIND>_KERNEL_PATH` +
//! `_SHA256`) is held to the pair's digest instead of the compiled pin — the
//! same digest the runtime enforces before it executes the kernel — and a
//! pair the runtime would reject (incomplete, malformed digest, relative
//! path, an out-of-range `_TIMEOUT_MS` even beside a pinned kernel) is
//! reported as `source=env` with nothing resolved, which is never healthy.
//! A kernel is hashed through one descriptor opened the way the runtime opens
//! it (no symlink, regular, non-empty, within the runtime's size bound, the
//! size unchanged after the read), so a symlinked, empty, oversized or
//! truncated/grown-during-read kernel has no digest and no provenance — the
//! same admission the runtime applies, including the same-size in-place
//! rewrite window it accepts; the legacy tools keep the plain hash, where a
//! symlinked `rg` on PATH is legitimate.
const std = @import("std");
const pfs = @import("platform").fs;
const toolchain = @import("../util/toolchain.zig");
const kg_client = @import("../kg/client.zig");
const formal_runtime = @import("../formal/runtime.zig");
const project_runtime = @import("../formal/project_harness_runtime.zig");
const provenance = @import("../formal/provenance.zig");
const project_provenance = @import("../formal/project_provenance.zig");
const kernel_fixtures = @import("../formal/kernel_test_fixtures.zig");

/// Where a binary was found. `config` is TinyKG-only (config.json `kg_bin`);
/// `path` and `fallback` are ripgrep-only (PATH scan, the fixed system
/// locations and the repository-relative vendored copy of a development
/// checkout). A `vendored` source arrives with the release layout in a later
/// #47 stage.
pub const Source = enum { env, config, adjacent, path, fallback };

pub const Check = struct {
    name: []const u8,
    /// Owned; null when the binary could not be resolved.
    resolved_path: ?[]u8,
    /// Lowercase hex SHA-256 of the resolved file; null when unresolved or
    /// unreadable.
    sha256: ?[64]u8,
    /// The digest the resolved file is held to: what `build_info` pinned for
    /// this target, or, for a kernel named by its environment pair, the pair's
    /// digest (the runtime enforces that one, so doctor reports against it).
    /// Null when nothing pins the binary.
    expected_sha256: ?[64]u8,
    /// null when there is no expectation; otherwise digest equality (false
    /// also when the file could not be hashed).
    match: ?bool,
    /// Where the binary came from. `env` with a null `resolved_path` means an
    /// environment override was present but rejected (an incomplete pair, a
    /// malformed digest, a relative path): configured, resolving nothing,
    /// never healthy.
    source: ?Source,
    /// Kernel-only: whether the sidecar beside the resolved kernel is a valid
    /// manifest *for that kernel* (see `kernelProvenance`); null for
    /// unresolved kernels and legacy tools.
    provenance: ?bool,
    /// Kernel-only, not rendered: the byte count of the file `sha256` was
    /// computed over, taken on the same descriptor, for the sidecar binding.
    kernel_bytes: ?u64 = null,
    /// A short account of a valid provenance (`tinykg 0.3.0 @0b04014`), shown
    /// by the human report; empty when there is nothing to say.
    note_buf: [64]u8 = undefined,
    note_len: u8 = 0,

    pub fn note(self: *const Check) []const u8 {
        return self.note_buf[0..self.note_len];
    }

    fn setNote(self: *Check, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.note_buf, fmt, args) catch self.note_buf[0..0];
        self.note_len = @intCast(text.len);
    }

    pub fn deinit(self: *Check, allocator: std.mem.Allocator) void {
        if (self.resolved_path) |path| allocator.free(path);
        self.resolved_path = null;
    }

    fn init(allocator: std.mem.Allocator, name: []const u8, resolved: ?Resolved, expected: ?[64]u8) !Check {
        var check: Check = .{
            .name = name,
            .resolved_path = null,
            .sha256 = null,
            .expected_sha256 = expected,
            .match = if (expected == null) null else false,
            .source = null,
            .provenance = null,
        };
        const found = resolved orelse return check;
        // An environment pair names both the file and the digest the runtime
        // will hold it to; that digest supersedes the compiled pin.
        if (found.expected_override) |override| {
            check.expected_sha256 = override;
            check.match = false;
        }
        check.resolved_path = try allocator.dupe(u8, found.path);
        errdefer check.deinit(allocator);
        check.source = found.source;
        if (found.kernel) |kernel| {
            if (hashKernel(kernel, found.path)) |hashed| {
                check.sha256 = hashed.sha256;
                check.kernel_bytes = hashed.bytes;
            }
        } else {
            check.sha256 = hashFile(found.path) catch null;
        }
        if (check.expected_sha256) |*want| {
            if (check.sha256) |*digest| check.match = std.mem.eql(u8, digest, want);
        }
        return check;
    }
};

const Resolved = struct {
    path: []const u8,
    source: Source,
    /// The digest an environment pair named; null for every other source.
    expected_override: ?[64]u8 = null,
    /// Set for the Lean kernels: the file is hashed under that runtime's
    /// admission rules instead of the plain `hashFile`.
    kernel: ?toolchain.KernelName = null,
};

/// What resolving a kernel found. `invalid_env` is an environment pair the
/// runtime rejects (`loadConfigFromEnv` → `.invalid`): the kernel is
/// configured, nothing is resolved, and the check must say so.
const KernelResolution = union(enum) {
    absent,
    invalid_env,
    found: Resolved,

    fn resolved(self: KernelResolution) ?Resolved {
        return switch (self) {
            .found => |found| found,
            else => null,
        };
    }
};

/// What `build_info` pinned for the target (`main.zig` fills this from the
/// module; the library never imports it).
pub const Expectations = struct {
    ripgrep_sha256: ?[]const u8,
    tinykg_sha256: ?[]const u8,
    tinykgd_sha256: ?[]const u8 = null,
    formal_kernel_sha256: ?[]const u8 = null,
    project_kernel_sha256: ?[]const u8 = null,
    exe_path_override: ?[]const u8 = null,
};

/// Where this process keeps its state (util/state_root.zig). Borrowed,
/// static strings: the resolver's cached buffer and literal labels.
pub const StateRootDiagnosis = struct {
    path: ?[]const u8,
    /// `flag` / `env` / `install` / `home`; null when unresolved.
    source: ?[]const u8,
    /// The resolution error name; null when resolved.
    err: ?[]const u8,
};

pub const Report = struct {
    /// `[0]` ripgrep, `[1]` TinyKG CLI, `[2]` formal kernel, `[3]` project kernel, `[4]` tinykgd.
    checks: [5]Check,
    kg: ?KgDiagnosis = null,
    state_root: ?StateRootDiagnosis = null,
    /// Borrowed, for the human report only: this build's full version and
    /// the install prefix around the executable.
    version: ?[]const u8 = null,
    install_prefix: ?[]const u8 = null,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (&self.checks) |*check| check.deinit(allocator);
        if (self.kg) |diagnosis| diagnosis.deinit(allocator);
    }

    /// Every binary resolved, and every one with an expectation matches it.
    pub fn healthy(self: *const Report) bool {
        // A configured root that does not resolve (broken install.json,
        // relative METACODES_HOME) is a broken install, not a degraded one.
        // No root at all (no $HOME, nothing configured) degrades as before.
        if (self.state_root) |root| if (root.err) |name| {
            if (!std.mem.eql(u8, name, "NoStateRoot")) return false;
        };
        for (&self.checks) |*check| {
            if (checkStatus(check) == .fail) return false;
        }
        return true;
    }
};

/// One verdict per check, shared by `healthy` (and so `--strict`) and the
/// human report, so the two can never disagree.
pub const CheckStatus = enum { ok, skipped, fail };

pub fn checkStatus(check: *const Check) CheckStatus {
    if (check.resolved_path == null) {
        // An override that resolved nothing is a configuration the runtime
        // rejects, whatever the build pinned.
        if (check.source != null) return .fail;
        // A binary this build never pinned may legitimately be absent
        // (kernels are built by the release, the daemon ships with a v2
        // bundle). A pinned one that cannot be found is unhealthy.
        if (!optionalWhenUnpinned(check.name) or check.expected_sha256 != null) return .fail;
        return .skipped;
    }
    if (check.match) |matched| if (!matched) return .fail;
    // A receipt or sidecar that is present but does not vouch for this file.
    if (check.provenance) |valid| if (!valid) return .fail;
    // The Lean kernels must carry a valid sidecar; without one a resolved
    // kernel is not trusted.
    if (isKernel(check.name) and check.provenance != true) return .fail;
    return .ok;
}

pub const KgDiagnosis = struct {
    state: []u8,
    transport: []u8,
    config: []u8,
    hint: []u8,
    /// Set by the host when a session would start the service itself, so
    /// the human report shows a stopped service as the normal state it is.
    autostarts: bool = false,

    pub fn deinit(self: KgDiagnosis, allocator: std.mem.Allocator) void {
        allocator.free(self.state);
        allocator.free(self.transport);
        allocator.free(self.config);
        allocator.free(self.hint);
    }
};

fn isKernel(name: []const u8) bool {
    return std.mem.eql(u8, name, "formal_kernel") or std.mem.eql(u8, name, "project_kernel");
}

/// Checks whose binary is absent in a normal build until a release stages it.
fn optionalWhenUnpinned(name: []const u8) bool {
    for ([_][]const u8{ "formal_kernel", "project_kernel", "tinykgd" }) |optional| {
        if (std.mem.eql(u8, name, optional)) return true;
    }
    return false;
}

pub fn run(allocator: std.mem.Allocator, expected: Expectations) !Report {
    const ripgrep: ?Resolved = if (toolchain.ripgrepResolution()) |found| .{
        .path = found.path,
        .source = switch (found.source) {
            .env => .env,
            .path => .path,
            .adjacent => .adjacent,
            .fallback => .fallback,
        },
    } else |_| null;
    var checks: [5]Check = undefined;
    checks[0] = try Check.init(allocator, "ripgrep", ripgrep, try pinDigest(expected.ripgrep_sha256));
    errdefer checks[0].deinit(allocator);

    // `exe_dir = null` resolves the adjacent layout from the real executable
    // directory; `config_bin = null` mirrors app.zig, where config.json carries
    // no `kg_bin` yet. `state_root` and `domain` only shape the Store path, which
    // this pure resolution never touches.
    var tinykg = try kg_client.KgClient.resolveTinykgBinary(allocator, .{ .state_root = "", .domain = "" });
    defer if (tinykg) |*found| found.deinit(allocator);
    const tinykg_resolved: ?Resolved = if (tinykg) |found| .{
        .path = found.path,
        .source = switch (found.source) {
            .env => .env,
            .config => .config,
            .adjacent => .adjacent,
        },
    } else null;
    checks[1] = try Check.init(allocator, "tinykg", tinykg_resolved, try pinDigest(expected.tinykg_sha256));
    errdefer checks[1].deinit(allocator);
    checks[1].provenance = try receiptProvenance(allocator, &checks[1], .cli);

    var formal_override_buf: [std.fs.max_path_bytes]u8 = undefined;
    const formal = resolveKernel(.formal, expected.formal_kernel_sha256, expected.exe_path_override, &formal_override_buf);
    checks[2] = try Check.init(allocator, "formal_kernel", formal.resolved(), try pinDigest(expected.formal_kernel_sha256));
    errdefer checks[2].deinit(allocator);
    if (formal == .invalid_env) checks[2].source = .env;
    checks[2].provenance = try kernelProvenance(allocator, .formal, &checks[2]);

    var project_override_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project = resolveKernel(.project, expected.project_kernel_sha256, expected.exe_path_override, &project_override_buf);
    checks[3] = try Check.init(allocator, "project_kernel", project.resolved(), try pinDigest(expected.project_kernel_sha256));
    errdefer checks[3].deinit(allocator);
    if (project == .invalid_env) checks[3].source = .env;
    checks[3].provenance = try kernelProvenance(allocator, .project, &checks[3]);
    var tinykgd = try kg_client.KgClient.resolveTinykgdBinary(allocator, .{ .state_root = "", .domain = "" });
    defer if (tinykgd) |*found| found.deinit(allocator);
    const tinykgd_resolved: ?Resolved = if (tinykgd) |found| .{
        .path = found.path,
        .source = switch (found.source) {
            .env => .env,
            .config => .config,
            .adjacent => .adjacent,
        },
    } else null;
    checks[4] = try Check.init(allocator, "tinykgd", tinykgd_resolved, try pinDigest(expected.tinykgd_sha256));
    errdefer checks[4].deinit(allocator);
    checks[4].provenance = try receiptProvenance(allocator, &checks[4], .daemon);
    return .{ .checks = checks, .kg = null };
}

/// A `build_info` pin as the fixed-width digest a check compares against.
/// `build.zig` refuses anything but 64 lowercase hex characters, so a pin of
/// another length is a corrupted build identity, not a missing one.
fn pinDigest(pin: ?[]const u8) error{InvalidPin}!?[64]u8 {
    const text = pin orelse return null;
    if (text.len != 64) return error.InvalidPin;
    var digest: [64]u8 = undefined;
    @memcpy(&digest, text);
    return digest;
}

fn resolveKernel(name: toolchain.KernelName, expected: ?[]const u8, exe_override: ?[]const u8, override_buf: []u8) KernelResolution {
    const env_present = switch (name) {
        .formal => std.c.getenv("METACODES_FORMAL_KERNEL_PATH") != null or std.c.getenv("METACODES_FORMAL_KERNEL_SHA256") != null,
        .project => std.c.getenv("METACODES_PROJECT_KERNEL_PATH") != null or std.c.getenv("METACODES_PROJECT_KERNEL_SHA256") != null,
    };
    if (env_present) {
        // The runtime's own parser decides what the pair means; doctor only
        // reports its decision (and, for a usable pair, holds the file to the
        // pair's digest exactly as the runtime will).
        return switch (name) {
            .formal => switch (formal_runtime.loadConfigFromEnv()) {
                .configured => |config| .{ .found = .{ .path = config.checker_path, .source = .env, .expected_override = config.expected_sha256, .kernel = name } },
                else => .invalid_env,
            },
            .project => switch (project_runtime.loadConfigFromEnv()) {
                .configured => |config| .{ .found = .{ .path = config.checker_path, .source = .env, .expected_override = config.expected_sha256, .kernel = name } },
                else => .invalid_env,
            },
        };
    }
    if (expected == null) return .absent;
    const path = if (exe_override) |exe|
        toolchain.kernelPathBeside(exe, name, override_buf) orelse return .absent
    else
        toolchain.kernelAdjacentPath(name) orelse return .absent;
    // The runtime's `loadConfig` parses the timeout after it has the pinned
    // adjacent path, and refuses the kernel on an out-of-range value; doctor
    // reports that refusal rather than a healthy kernel nothing will run.
    const timeout_ok = switch (name) {
        .formal => formal_runtime.timeoutMsFromEnv() != null,
        .project => project_runtime.timeoutMsFromEnv() != null,
    };
    if (!timeout_ok) return .invalid_env;
    return .{ .found = .{ .path = path, .source = .adjacent, .kernel = name } };
}

pub const RECEIPT_SCHEMA = "metacodes.tinykg-binary-receipt/v2";
pub const TINYKG_CONTRACT_SCHEMA = "metacodes.tinykg-binary/v1";
const MAX_RECEIPT_BYTES: usize = 64 * 1024;

const ReceiptRole = enum { cli, daemon };

/// The staging receipt beside a TinyKG binary (`tinykg.provenance.json`,
/// written by scripts/stage_tinykg_binary.py) must describe that very file:
/// receipt and contract schema, role, a version line of the right program,
/// the storage contract this client speaks, and the recorded digest equal to
/// the file's. A bundled binary also names its bundle key and source commit.
/// No receipt is `null` (nothing to judge, as for a developer's own binary);
/// a receipt that does not vouch for the file is `false`.
fn receiptProvenance(allocator: std.mem.Allocator, check: *Check, role: ReceiptRole) error{OutOfMemory}!?bool {
    const path = check.resolved_path orelse return null;
    const receipt_path = try receiptPathFor(allocator, path);
    defer allocator.free(receipt_path);
    const bytes = readBounded(allocator, receipt_path, MAX_RECEIPT_BYTES) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return null,
        else => return false,
    };
    defer allocator.free(bytes);
    const actual = check.sha256 orelse return false;
    const Receipt = struct {
        receipt_schema: []const u8,
        contract_schema: []const u8,
        binary_sha256: []const u8,
        binary_version: []const u8,
        distribution: []const u8,
        source_repository: []const u8,
        storage_format_version: []const u8,
        store_schema_version: []const u8,
        role: ?[]const u8 = null,
        source_commit: ?[]const u8 = null,
        bundle_key: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(Receipt, allocator, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    const receipt = parsed.value;
    if (!std.mem.eql(u8, receipt.receipt_schema, RECEIPT_SCHEMA)) return false;
    if (!std.mem.eql(u8, receipt.contract_schema, TINYKG_CONTRACT_SCHEMA)) return false;
    if (!std.mem.eql(u8, receipt.binary_sha256, &actual)) return false;
    const program = switch (role) {
        .cli => "tinykg ",
        .daemon => "tinykgd ",
    };
    if (!std.mem.startsWith(u8, receipt.binary_version, program)) return false;
    switch (role) {
        .daemon => if (receipt.role == null or !std.mem.eql(u8, receipt.role.?, "daemon")) return false,
        .cli => if (receipt.role) |declared| if (!std.mem.eql(u8, declared, "cli")) return false,
    }
    if (!std.mem.eql(u8, receipt.storage_format_version, kg_client.EXPECTED_STORAGE_FORMAT_VERSION) or
        !std.mem.eql(u8, receipt.store_schema_version, kg_client.EXPECTED_SCHEMA_VERSION)) return false;
    if (receipt.source_repository.len == 0) return false;
    if (std.mem.eql(u8, receipt.distribution, "bundled")) {
        const commit = receipt.source_commit orelse return false;
        if (commit.len != 40 or !isLowerHex(commit)) return false;
        const bundle_key = receipt.bundle_key orelse return false;
        if (bundle_key.len == 0) return false;
        check.setNote("{s} @{s}", .{ receipt.binary_version, commit[0..7] });
    } else if (std.mem.eql(u8, receipt.distribution, "explicit")) {
        check.setNote("{s}, explicitly staged", .{receipt.binary_version});
    } else return false;
    return true;
}

/// `vendor/tinykg/tinykg[.exe]` → `vendor/tinykg/tinykg.provenance.json`.
fn receiptPathFor(allocator: std.mem.Allocator, binary: []const u8) error{OutOfMemory}![]u8 {
    const dir = std.fs.path.dirname(binary) orelse ".";
    var base = std.fs.path.basename(binary);
    if (std.ascii.endsWithIgnoreCase(base, ".exe")) base = base[0 .. base.len - 4];
    return std.fmt.allocPrint(allocator, "{s}{c}{s}.provenance.json", .{ dir, std.fs.path.sep, base });
}

fn isLowerHex(text: []const u8) bool {
    for (text) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

/// A small file read whole, refusing anything over `max` bytes.
fn readBounded(allocator: std.mem.Allocator, path: []const u8, max: usize) error{ OutOfMemory, FileNotFound, Unreadable, TooLarge }![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return if (pfs.lastErrnoIs(.NOENT)) error.FileNotFound else error.Unreadable;
    defer _ = pfs.close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &buffer);
        if (n < 0) return error.Unreadable;
        if (n == 0) break;
        if (list.items.len + @as(usize, @intCast(n)) > max) return error.TooLarge;
        try list.appendSlice(allocator, buffer[0..@intCast(n)]);
    }
    return list.toOwnedSlice(allocator);
}

/// Validates the provenance sidecar beside a resolved kernel with the loader
/// that owns that kernel's manifest schema. Every rejection (missing sidecar,
/// other kernel's schema, unbound binary digest, foreign host) is `false`;
/// only allocation failure propagates.
fn kernelProvenance(allocator: std.mem.Allocator, kernel: toolchain.KernelName, check: *const Check) error{OutOfMemory}!?bool {
    const checker_path = check.resolved_path orelse return null;
    // Both come from the one admission-checked read in `hashKernel`; a kernel
    // that read refused has neither, and no sidecar can vouch for it.
    const actual_sha256 = check.sha256 orelse return false;
    const actual_bytes = check.kernel_bytes orelse return false;
    switch (kernel) {
        .formal => {
            var loaded = provenance.loadAdjacent(allocator, checker_path, actual_sha256, actual_bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return false,
            };
            loaded.deinit();
        },
        .project => {
            var loaded = project_provenance.loadAdjacent(allocator, checker_path, actual_sha256, actual_bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return false,
            };
            loaded.deinit();
        },
    }
    return true;
}

const KernelHash = struct { sha256: [64]u8, bytes: u64 };

/// SHA-256 and size of a kernel under the runtime's own admission rules for
/// the file it executes (`formal/runtime.zig` `readChecker`): one descriptor
/// opened without following a symlink, a regular non-empty file within the
/// runtime's byte bound, hashed in full, and its size re-read afterwards so a
/// swap during the read is not vouched for. Null means the runtime would
/// refuse this path.
fn hashKernel(kernel: toolchain.KernelName, path: []const u8) ?KernelHash {
    var path_z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= path_z.len) return null;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const fd = pfs.open(path_z[0..path.len :0], .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return null;
    const bound: u64 = switch (kernel) {
        .formal => formal_runtime.MAX_CHECKER_BYTES,
        .project => project_runtime.MAX_CHECKER_BYTES,
    };
    if (!before.is_regular or before.size <= 0) return null;
    const size: u64 = @intCast(before.size);
    if (size > bound) return null;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const n = pfs.read(fd, &buffer);
        if (n < 0) return null;
        if (n == 0) break;
        total += @intCast(n);
        if (total > size) return null;
        hasher.update(buffer[0..@intCast(n)]);
    }
    const after = pfs.fileInfo(fd) catch return null;
    if (total != size or !after.is_regular or after.size != before.size) return null;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return .{ .sha256 = std.fmt.bytesToHex(digest, .lower), .bytes = size };
}

/// SHA-256 of a file streamed in 64 KiB chunks; a binary is never loaded whole.
fn hashFile(path: []const u8) error{Unreadable}![64]u8 {
    var path_z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= path_z.len) return error.Unreadable;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const fd = pfs.open(path_z[0..path.len :0], .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.Unreadable;
    defer _ = pfs.close(fd);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &buffer);
        if (n < 0) return error.Unreadable;
        if (n == 0) break;
        hasher.update(buffer[0..@intCast(n)]);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// One line per check:
/// `<name> ... match=<true|false|n/a> provenance=<true|false|n/a>`.
pub fn writeText(w: *std.Io.Writer, report: *const Report) std.Io.Writer.Error!void {
    for (&report.checks) |*check| {
        try w.print("{s} {s} source={s} sha256={s} expected={s} match={s} provenance={s}\n", .{
            check.name,
            check.resolved_path orelse "unresolved",
            if (check.source) |source| @tagName(source) else "-",
            if (check.sha256) |*digest| digest[0..] else "-",
            if (check.expected_sha256) |*want| want[0..] else "none",
            if (check.match) |matched| (if (matched) "true" else "false") else "n/a",
            if (check.provenance) |valid| (if (valid) "true" else "false") else "n/a",
        });
    }
    if (report.kg) |kg| try w.print("tinykg_daemon {s} transport={s} config={s} hint={s}\n", .{ kg.state, kg.transport, kg.config, kg.hint });
    if (report.state_root) |root| try w.print("state_root {s} source={s} error={s}\n", .{
        root.path orelse "unresolved",
        root.source orelse "-",
        root.err orelse "-",
    });
}

pub const HumanOptions = struct {
    /// ANSI colour (a terminal without NO_COLOR).
    color: bool = false,
    /// `$HOME`, shown as `~`.
    home: ?[]const u8 = null,
};

const Style = struct {
    color: bool,
    fn on(self: Style, code: []const u8) []const u8 {
        return if (self.color) code else "";
    }
    fn off(self: Style) []const u8 {
        return if (self.color) "\x1b[0m" else "";
    }
};

const GREEN = "\x1b[32m";
const RED = "\x1b[31m";
const YELLOW = "\x1b[33m";
const DIM = "\x1b[2m";
const BOLD = "\x1b[1m";

const Mark = enum {
    ok,
    warn,
    fail,
    skip,
    fn glyph(self: Mark) []const u8 {
        return switch (self) {
            .ok => "\u{2713}",
            .warn => "!",
            .fail => "\u{2717}",
            .skip => "-",
        };
    }
    fn colour(self: Mark) []const u8 {
        return switch (self) {
            .ok => GREEN,
            .warn => YELLOW,
            .fail => RED,
            .skip => DIM,
        };
    }
};

fn writeMark(w: *std.Io.Writer, style: Style, mark: Mark) std.Io.Writer.Error!void {
    try w.print("  {s}{s}{s} ", .{ style.on(mark.colour()), mark.glyph(), style.off() });
}

fn writePadded(w: *std.Io.Writer, text: []const u8, width: usize) std.Io.Writer.Error!void {
    try w.writeAll(text);
    var n = std.unicode.utf8CountCodepoints(text) catch text.len;
    while (n < width) : (n += 1) try w.writeByte(' ');
}

/// `path` as a reader wants it: relative to the install prefix when inside
/// it, else with the home directory as `~`.
fn displayPath(path: []const u8, prefix: ?[]const u8, home: ?[]const u8, buf: []u8) []const u8 {
    if (prefix) |root| if (root.len > 0 and path.len > root.len + 1 and std.mem.startsWith(u8, path, root) and
        (path[root.len] == '/' or path[root.len] == '\\'))
    {
        return path[root.len + 1 ..];
    };
    return homeRelative(path, home, buf);
}

fn homeRelative(path: []const u8, home: ?[]const u8, buf: []u8) []const u8 {
    const h = home orelse return path;
    if (h.len == 0 or !std.mem.startsWith(u8, path, h)) return path;
    if (path.len != h.len and path[h.len] != '/' and path[h.len] != '\\') return path;
    return std.fmt.bufPrint(buf, "~{s}", .{path[h.len..]}) catch path;
}

fn componentLabel(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "formal_kernel")) return "formal kernel";
    if (std.mem.eql(u8, name, "project_kernel")) return "project kernel";
    return name;
}

fn sourceNote(source: ?Source) ?[]const u8 {
    const value = source orelse return null;
    return switch (value) {
        .adjacent => null,
        .env => "from the environment",
        .config => "from config.json",
        .path => "from PATH",
        .fallback => "fallback location",
    };
}

/// The report for a person at a terminal: what is installed where, whether
/// each runtime component is the one this build expects, and what to do about
/// anything that is not. `--plain` and any non-terminal output keep the
/// one-line-per-check form (`writeText`), which scripts parse.
pub fn writeHuman(w: *std.Io.Writer, report: *const Report, options: HumanOptions) std.Io.Writer.Error!void {
    const style = Style{ .color = options.color };
    var buf: [std.fs.max_path_bytes + 2]u8 = undefined;
    var fails: usize = 0;
    var warns: usize = 0;

    try w.print("{s}metacodes {s}{s}\n", .{ style.on(BOLD), report.version orelse "(unknown version)", style.off() });
    if (report.install_prefix) |prefix| try w.print("  install     {s}\n", .{homeRelative(prefix, options.home, &buf)});
    if (report.state_root) |root| {
        if (root.path) |path| {
            const how = if (root.source) |source| stateSourceNote(source) else "";
            try w.print("  state root  {s}{s}{s}{s}\n", .{ homeRelative(path, options.home, &buf), style.on(DIM), how, style.off() });
        } else {
            const no_root = std.mem.eql(u8, root.err orelse "", "NoStateRoot");
            if (no_root) warns += 1 else fails += 1;
            try w.print("  state root  {s}unresolved ({s}){s}\n", .{ style.on(if (no_root) YELLOW else RED), root.err orelse "unknown", style.off() });
        }
    }

    // Order a reader expects: tools, then the KG pair, then the kernels.
    const order = [_]usize{ 0, 1, 4, 2, 3 };
    var path_width: usize = 0;
    for (order) |index| {
        const check = &report.checks[index];
        const shown = if (check.resolved_path) |path| displayPath(path, report.install_prefix, options.home, &buf) else "not found";
        path_width = @max(path_width, @min(std.unicode.utf8CountCodepoints(shown) catch shown.len, 48));
    }

    try w.print("\n{s}Runtime components{s}\n", .{ style.on(BOLD), style.off() });
    for (order) |index| {
        const check = &report.checks[index];
        const status = checkStatus(check);
        const mark: Mark = switch (status) {
            .ok => .ok,
            .skipped => .skip,
            .fail => .fail,
        };
        if (status == .fail) fails += 1;
        try writeMark(w, style, mark);
        try writePadded(w, componentLabel(check.name), 15);
        const shown = if (check.resolved_path) |path| displayPath(path, report.install_prefix, options.home, &buf) else "not found";
        try w.print("{s}", .{style.on(DIM)});
        try writePadded(w, shown, path_width);
        try w.print("{s}  ", .{style.off()});
        try writeCheckDetail(w, style, check, status);
        try w.writeByte('\n');
    }

    if (report.kg) |kg| {
        try w.print("\n{s}TinyKG service{s}\n", .{ style.on(BOLD), style.off() });
        const ready = std.mem.eql(u8, kg.state, "ready");
        if (ready) {
            try writeMark(w, style, .ok);
            try w.print("ready  {s}({s}, config {s}){s}\n", .{ style.on(DIM), kg.transport, homeRelative(kg.config, options.home, &buf), style.off() });
        } else if (kg.autostarts) {
            try writeMark(w, style, .skip);
            try w.print("not running {s}\u{00b7} starts with the next session (`metacodes kgd` starts it now){s}\n", .{ style.on(DIM), style.off() });
        } else {
            warns += 1;
            try writeMark(w, style, .warn);
            try w.print("{s}  {s}{s}{s}\n", .{ kg.state, style.on(DIM), kg.hint, style.off() });
        }
    }

    try w.writeByte('\n');
    if (fails == 0 and warns == 0) {
        try w.print("{s}All checks passed.{s}\n", .{ style.on(GREEN), style.off() });
    } else {
        if (fails > 0) try w.print("{s}{d} problem{s}{s}", .{ style.on(RED), fails, if (fails == 1) "" else "s", style.off() });
        if (fails > 0 and warns > 0) try w.writeAll(", ");
        if (warns > 0) try w.print("{s}{d} warning{s}{s}", .{ style.on(YELLOW), warns, if (warns == 1) "" else "s", style.off() });
        try w.writeAll(". `metacodes doctor --plain` shows full digests and sources.\n");
    }
}

fn stateSourceNote(source: []const u8) []const u8 {
    if (std.mem.eql(u8, source, "install")) return "  (from the install record)";
    if (std.mem.eql(u8, source, "flag")) return "  (from --state-dir)";
    if (std.mem.eql(u8, source, "env")) return "  (from METACODES_HOME)";
    if (std.mem.eql(u8, source, "home")) return "  (default)";
    return "";
}

fn writeCheckDetail(w: *std.Io.Writer, style: Style, check: *const Check, status: CheckStatus) std.Io.Writer.Error!void {
    if (check.resolved_path == null) {
        if (check.source != null) {
            try w.print("{s}configured by the environment, but unusable{s}", .{ style.on(RED), style.off() });
        } else if (status == .fail) {
            try w.print("{s}missing (this build expects it){s}", .{ style.on(RED), style.off() });
        } else {
            try w.print("{s}not built (optional in a development build){s}", .{ style.on(DIM), style.off() });
        }
        return;
    }
    if (check.match) |matched| {
        if (matched) {
            try w.writeAll("digest ok");
        } else if (check.sha256) |*found| {
            const want: []const u8 = if (check.expected_sha256) |*e| e[0..12] else "-";
            try w.print("{s}digest MISMATCH (expected {s}, found {s}){s}", .{ style.on(RED), want, found[0..12], style.off() });
        } else {
            try w.print("{s}unreadable{s}", .{ style.on(RED), style.off() });
        }
    } else {
        try w.writeAll("digest not pinned by this build");
    }
    const kernel = isKernel(check.name);
    if (check.provenance) |valid| {
        if (valid) {
            if (kernel) {
                try w.writeAll(" \u{00b7} provenance verified");
            } else if (check.note().len > 0) {
                try w.print(" \u{00b7} receipt ok {s}({s}){s}", .{ style.on(DIM), check.note(), style.off() });
            } else {
                try w.writeAll(" \u{00b7} receipt ok");
            }
        } else {
            try w.print(" \u{00b7} {s}{s} INVALID{s}", .{ style.on(RED), if (kernel) "provenance" else "receipt", style.off() });
        }
    } else if (kernel) {
        try w.print(" \u{00b7} {s}provenance missing{s}", .{ style.on(RED), style.off() });
    }
    if (sourceNote(check.source)) |where| try w.print(" {s}[{s}]{s}", .{ style.on(DIM), where, style.off() });
}

/// The `doctor --json` document: `{"checks":[{name, resolved_path, sha256,
/// expected_sha256, match, source, provenance}, ...]}`, nulls where a value is absent.
pub fn writeJson(w: *std.Io.Writer, report: *const Report) std.Io.Writer.Error!void {
    const Entry = struct {
        name: []const u8,
        resolved_path: ?[]const u8,
        sha256: ?[]const u8,
        expected_sha256: ?[]const u8,
        match: ?bool,
        source: ?[]const u8,
        provenance: ?bool,
    };
    var entries: [5]Entry = undefined;
    for (&report.checks, &entries) |*check, *entry| {
        entry.* = .{
            .name = check.name,
            .resolved_path = check.resolved_path,
            .sha256 = if (check.sha256) |*digest| digest[0..] else null,
            .expected_sha256 = if (check.expected_sha256) |*want| want[0..] else null,
            .match = check.match,
            .source = if (check.source) |source| @tagName(source) else null,
            .provenance = check.provenance,
        };
    }
    // `kg` and `state_root` appear only when diagnosed; inside each object an
    // absent value is `null`, as for the checks.
    const KgJson = struct { state: []const u8, transport: []const u8, config: []const u8, hint: []const u8 };
    const StateRootJson = struct { path: ?[]const u8, source: ?[]const u8, @"error": ?[]const u8 };
    const kg: ?KgJson = if (report.kg) |d| .{ .state = d.state, .transport = d.transport, .config = d.config, .hint = d.hint } else null;
    const state_root: ?StateRootJson = if (report.state_root) |root| .{ .path = root.path, .source = root.source, .@"error" = root.err } else null;
    try w.writeAll("{\"checks\":");
    try std.json.Stringify.value(entries, .{}, w);
    if (kg) |value| {
        try w.writeAll(",\"kg\":");
        try std.json.Stringify.value(value, .{}, w);
    }
    if (state_root) |value| {
        try w.writeAll(",\"state_root\":");
        try std.json.Stringify.value(value, .{}, w);
    }
    try w.writeByte('}');
    try w.writeByte('\n');
}

const test_digest: [64]u8 = ("0123456789abcdef" ** 4).*;

fn testReport(allocator: std.mem.Allocator) !Report {
    return .{ .checks = .{
        .{
            .name = "ripgrep",
            .resolved_path = try allocator.dupe(u8, "/opt/tools/rg"),
            .sha256 = test_digest,
            .expected_sha256 = test_digest,
            .match = true,
            .source = .path,
            .provenance = null,
        },
        .{
            .name = "tinykg",
            .resolved_path = null,
            .sha256 = null,
            .expected_sha256 = null,
            .match = null,
            .source = null,
            .provenance = null,
        },
        .{ .name = "formal_kernel", .resolved_path = null, .sha256 = null, .expected_sha256 = null, .match = null, .source = null, .provenance = null },
        .{ .name = "project_kernel", .resolved_path = null, .sha256 = null, .expected_sha256 = null, .match = null, .source = null, .provenance = null },
        .{ .name = "tinykgd", .resolved_path = null, .sha256 = null, .expected_sha256 = null, .match = null, .source = null, .provenance = null },
    } };
}

/// A release-shaped report: every component adjacent under `/opt/mc`.
fn testInstalledReport(allocator: std.mem.Allocator) !Report {
    const names = [_][]const u8{ "ripgrep", "tinykg", "formal_kernel", "project_kernel", "tinykgd" };
    const paths = [_][]const u8{
        "/opt/mc/bin/rg",
        "/opt/mc/vendor/tinykg/tinykg",
        "/opt/mc/libexec/metacodes/metacodes-formal-kernel",
        "/opt/mc/libexec/metacodes/metacodes-project-kernel",
        "/opt/mc/vendor/tinykg/tinykgd",
    };
    var report: Report = .{ .checks = undefined };
    for (&report.checks, names, paths, 0..) |*check, name, path, i| {
        check.* = .{
            .name = name,
            .resolved_path = try allocator.dupe(u8, path),
            .sha256 = test_digest,
            .expected_sha256 = test_digest,
            .match = true,
            .source = .adjacent,
            .provenance = if (i == 0) null else true,
        };
    }
    report.checks[1].setNote("tinykg 0.3.0 @0b04014", .{});
    report.checks[4].setNote("tinykgd 0.3.0 @0b04014", .{});
    report.version = "0.3.0";
    report.install_prefix = "/opt/mc";
    report.state_root = .{ .path = "/home/u/.metacodes", .source = "install", .err = null };
    return report;
}

test "doctor human report: a healthy install reads as one line per component" {
    const allocator = std.testing.allocator;
    var report = try testInstalledReport(allocator);
    defer report.deinit(allocator);
    report.kg = .{
        .state = try allocator.dupe(u8, "ready"),
        .transport = try allocator.dupe(u8, "daemon"),
        .config = try allocator.dupe(u8, "/home/u/.metacodes/kg/daemon.json"),
        .hint = try allocator.dupe(u8, "-"),
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeHuman(&out.writer, &report, .{ .home = "/home/u" });
    try std.testing.expectEqualStrings(
        "metacodes 0.3.0\n" ++
            "  install     /opt/mc\n" ++
            "  state root  ~/.metacodes  (from the install record)\n" ++
            "\n" ++
            "Runtime components\n" ++
            "  \u{2713} ripgrep        bin/rg                                      digest ok\n" ++
            "  \u{2713} tinykg         vendor/tinykg/tinykg                        digest ok \u{00b7} receipt ok (tinykg 0.3.0 @0b04014)\n" ++
            "  \u{2713} tinykgd        vendor/tinykg/tinykgd                       digest ok \u{00b7} receipt ok (tinykgd 0.3.0 @0b04014)\n" ++
            "  \u{2713} formal kernel  libexec/metacodes/metacodes-formal-kernel   digest ok \u{00b7} provenance verified\n" ++
            "  \u{2713} project kernel libexec/metacodes/metacodes-project-kernel  digest ok \u{00b7} provenance verified\n" ++
            "\n" ++
            "TinyKG service\n" ++
            "  \u{2713} ready  (daemon, config ~/.metacodes/kg/daemon.json)\n" ++
            "\n" ++
            "All checks passed.\n",
        out.written(),
    );
    try std.testing.expect(report.healthy());
}

test "doctor human report: problems name the cause and agree with --strict" {
    const allocator = std.testing.allocator;
    var report = try testInstalledReport(allocator);
    defer report.deinit(allocator);
    var other = test_digest;
    other[0] = 'f';
    report.checks[1].sha256 = other; // tinykg replaced
    report.checks[1].match = false;
    report.checks[4].provenance = false; // tinykgd receipt does not vouch for it
    allocator.free(report.checks[3].resolved_path.?); // pinned project kernel gone
    report.checks[3].resolved_path = null;
    report.checks[3].source = null;
    report.checks[3].provenance = null;
    report.kg = .{
        .state = try allocator.dupe(u8, "daemon_unreachable"),
        .transport = try allocator.dupe(u8, "daemon"),
        .config = try allocator.dupe(u8, "/home/u/.metacodes/kg/daemon.json"),
        .hint = try allocator.dupe(u8, "a CLI session starts it when it begins"),
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeHuman(&out.writer, &report, .{ .home = "/home/u" });
    const text = out.written();
    const line = struct {
        fn of(haystack: []const u8, start: []const u8) ![]const u8 {
            var lines = std.mem.splitScalar(u8, haystack, '\n');
            while (lines.next()) |l| if (std.mem.startsWith(u8, l, start)) return l;
            return error.TestLineMissing;
        }
    }.of;
    try std.testing.expect(std.mem.indexOf(u8, try line(text, "  \u{2717} tinykg "), "digest MISMATCH (expected 0123456789ab, found f123456789ab)") != null);
    try std.testing.expect(std.mem.endsWith(u8, try line(text, "  \u{2717} tinykgd "), "digest ok \u{00b7} receipt INVALID"));
    try std.testing.expect(std.mem.endsWith(u8, try line(text, "  \u{2717} project kernel not found "), "missing (this build expects it)"));
    try std.testing.expectEqualStrings("  ! daemon_unreachable  a CLI session starts it when it begins", try line(text, "  ! "));
    try std.testing.expect(std.mem.endsWith(u8, text, "3 problems, 1 warning. `metacodes doctor --plain` shows full digests and sources.\n"));
    // Every ✗ above is a failure of the health verdict too.
    try std.testing.expect(!report.healthy());
    try std.testing.expectEqual(CheckStatus.fail, checkStatus(&report.checks[1]));
    try std.testing.expectEqual(CheckStatus.fail, checkStatus(&report.checks[4]));
    try std.testing.expectEqual(CheckStatus.fail, checkStatus(&report.checks[3]));
}

test "doctor human report: a stopped service a session will start is not a warning" {
    const allocator = std.testing.allocator;
    var report = try testInstalledReport(allocator);
    defer report.deinit(allocator);
    report.kg = .{
        .state = try allocator.dupe(u8, "unconfigured"),
        .transport = try allocator.dupe(u8, "unconfigured"),
        .config = try allocator.dupe(u8, "/home/u/.metacodes/kg/daemon.json"),
        .hint = try allocator.dupe(u8, "a CLI session provisions and starts it by itself"),
        .autostarts = true,
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeHuman(&out.writer, &report, .{ .home = "/home/u" });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "  - not running \u{00b7} starts with the next session (`metacodes kgd` starts it now)\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "All checks passed.\n"));

    // Without autostart (METACODES_KG_AUTOSTART=0, a remote service) it is one.
    report.kg.?.autostarts = false;
    var off: std.Io.Writer.Allocating = .init(allocator);
    defer off.deinit();
    try writeHuman(&off.writer, &report, .{ .home = "/home/u" });
    try std.testing.expect(std.mem.indexOf(u8, off.written(), "  ! unconfigured  a CLI session provisions and starts it by itself\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, off.written(), "1 warning. `metacodes doctor --plain` shows full digests and sources.\n"));
}

test "doctor human report: colour only when asked" {
    const allocator = std.testing.allocator;
    var report = try testInstalledReport(allocator);
    defer report.deinit(allocator);
    var plain: std.Io.Writer.Allocating = .init(allocator);
    defer plain.deinit();
    try writeHuman(&plain.writer, &report, .{});
    try std.testing.expect(std.mem.indexOfScalar(u8, plain.written(), 0x1b) == null);
    var coloured: std.Io.Writer.Allocating = .init(allocator);
    defer coloured.deinit();
    try writeHuman(&coloured.writer, &report, .{ .color = true });
    try std.testing.expect(std.mem.indexOf(u8, coloured.written(), "\x1b[32m\u{2713}\x1b[0m") != null);
}

test "doctor receipt path drops .exe and sits beside the binary" {
    const allocator = std.testing.allocator;
    const posix = try receiptPathFor(allocator, "/opt/mc/vendor/tinykg/tinykgd");
    defer allocator.free(posix);
    try std.testing.expect(std.mem.endsWith(u8, posix, "tinykg" ++ [_]u8{std.fs.path.sep} ++ "tinykgd.provenance.json"));
    const windows = try receiptPathFor(allocator, "/opt/mc/vendor/tinykg/tinykg.exe");
    defer allocator.free(windows);
    try std.testing.expect(std.mem.endsWith(u8, windows, "tinykg.provenance.json"));
}

test "doctor receipt: vouches only for the file it describes" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tinykgd", .data = "daemon bytes" });
    const binary = try std.fmt.allocPrint(allocator, "{s}/tinykgd", .{root});
    defer allocator.free(binary);
    const digest = try hashFile(binary);

    const Case = struct { receipt: ?[]const u8, want: ?bool };
    const good_fmt = "{{\"receipt_schema\":\"{s}\",\"contract_schema\":\"{s}\",\"binary_sha256\":\"{s}\",\"binary_version\":\"tinykgd 0.3.0\",\"distribution\":\"bundled\",\"source_repository\":\"https://github.com/metask-ai/tinykg\",\"storage_format_version\":\"3\",\"store_schema_version\":\"3\",\"role\":\"{s}\",\"source_commit\":\"{s}\",\"bundle_key\":\"macos-universal-daemon\",\"license\":\"Apache-2.0\",\"target\":\"aarch64-macos\"}}";
    const commit = "0b04014ba8d0bcb1f9f73c63c12e49f3c2ee1ece";
    const good = try std.fmt.allocPrint(allocator, good_fmt, .{ RECEIPT_SCHEMA, TINYKG_CONTRACT_SCHEMA, digest, "daemon", commit });
    defer allocator.free(good);
    const other_binary = try std.fmt.allocPrint(allocator, good_fmt, .{ RECEIPT_SCHEMA, TINYKG_CONTRACT_SCHEMA, "f" ** 64, "daemon", commit });
    defer allocator.free(other_binary);
    const cli_role = try std.fmt.allocPrint(allocator, good_fmt, .{ RECEIPT_SCHEMA, TINYKG_CONTRACT_SCHEMA, digest, "cli", commit });
    defer allocator.free(cli_role);
    const old_schema = try std.fmt.allocPrint(allocator, good_fmt, .{ "metacodes.tinykg-binary-receipt/v1", TINYKG_CONTRACT_SCHEMA, digest, "daemon", commit });
    defer allocator.free(old_schema);
    const short_commit = try std.fmt.allocPrint(allocator, good_fmt, .{ RECEIPT_SCHEMA, TINYKG_CONTRACT_SCHEMA, digest, "daemon", "0b04014" });
    defer allocator.free(short_commit);
    const cases = [_]Case{
        .{ .receipt = null, .want = null }, // no receipt: nothing to judge
        .{ .receipt = good, .want = true },
        .{ .receipt = other_binary, .want = false }, // a receipt for another build (the cross-build case)
        .{ .receipt = cli_role, .want = false },
        .{ .receipt = old_schema, .want = false },
        .{ .receipt = short_commit, .want = false },
        .{ .receipt = "not json", .want = false },
    };
    for (cases) |case| {
        tmp.dir.deleteFile(std.testing.io, "tinykgd.provenance.json") catch {};
        if (case.receipt) |body| try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tinykgd.provenance.json", .data = body });
        var check = try Check.init(allocator, "tinykgd", .{ .path = binary, .source = .adjacent }, null);
        defer check.deinit(allocator);
        try std.testing.expectEqual(case.want, try receiptProvenance(allocator, &check, .daemon));
        if (case.want == true) try std.testing.expectEqualStrings("tinykgd 0.3.0 @0b04014", check.note());
        check.provenance = case.want;
        try std.testing.expectEqual(case.want != false, checkStatus(&check) != .fail);
    }
}

test "doctor json names every field and uses null for what is absent" {
    const allocator = std.testing.allocator;
    var report = try testReport(allocator);
    defer report.deinit(allocator);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeJson(&out.writer, &report);
    try std.testing.expectEqualStrings(
        "{\"checks\":[{\"name\":\"ripgrep\",\"resolved_path\":\"/opt/tools/rg\",\"sha256\":\"" ++ ("0123456789abcdef" ** 4) ++
            "\",\"expected_sha256\":\"" ++ ("0123456789abcdef" ** 4) ++ "\",\"match\":true,\"source\":\"path\",\"provenance\":null}," ++
            "{\"name\":\"tinykg\",\"resolved_path\":null,\"sha256\":null,\"expected_sha256\":null,\"match\":null,\"source\":null,\"provenance\":null}," ++
            "{\"name\":\"formal_kernel\",\"resolved_path\":null,\"sha256\":null,\"expected_sha256\":null,\"match\":null,\"source\":null,\"provenance\":null}," ++
            "{\"name\":\"project_kernel\",\"resolved_path\":null,\"sha256\":null,\"expected_sha256\":null,\"match\":null,\"source\":null,\"provenance\":null}," ++
            "{\"name\":\"tinykgd\",\"resolved_path\":null,\"sha256\":null,\"expected_sha256\":null,\"match\":null,\"source\":null,\"provenance\":null}]}\n",
        out.written(),
    );
}

test "doctor health: an unpinned daemon may be absent, a pinned one may not" {
    const a = std.testing.allocator;
    var report = try testReport(a);
    defer report.deinit(a);
    // The CLI is required; the daemon and the kernels are not until this build
    // pins a digest for them (a v1 bundle carries no tinykgd at all).
    report.checks[1].resolved_path = try a.dupe(u8, "/opt/tools/tinykg");
    report.checks[1].sha256 = test_digest;
    report.checks[1].expected_sha256 = test_digest;
    report.checks[1].match = true;
    try std.testing.expect(report.healthy());

    report.checks[4].expected_sha256 = test_digest;
    try std.testing.expect(!report.healthy());
}

test "doctor health: an override that resolved nothing is never healthy" {
    const a = std.testing.allocator;
    var report = try testReport(a);
    defer report.deinit(a);
    report.checks[1].resolved_path = try a.dupe(u8, "/opt/tools/tinykg");
    try std.testing.expect(report.healthy());
    // Unpinned and absent the project kernel is optional; an environment pair
    // that the runtime rejected is a configuration, and it resolved nothing.
    report.checks[3].source = .env;
    try std.testing.expect(!report.healthy());
}

test "doctor health: a configured state root that does not resolve is unhealthy, no root is not" {
    const a = std.testing.allocator;
    var report = try testReport(a);
    defer report.deinit(a);
    report.checks[1].resolved_path = try a.dupe(u8, "/opt/tools/tinykg");
    report.state_root = .{ .path = "/opt/mc/state", .source = "install", .err = null };
    try std.testing.expect(report.healthy());
    // No $HOME and nothing configured: the subsystems degrade, as they always did.
    report.state_root = .{ .path = null, .source = null, .err = "NoStateRoot" };
    try std.testing.expect(report.healthy());
    // A broken install record is a broken install.
    report.state_root = .{ .path = null, .source = null, .err = "InstallManifestInvalid" };
    try std.testing.expect(!report.healthy());
}

test "doctor text is one line per check" {
    const allocator = std.testing.allocator;
    var report = try testReport(allocator);
    defer report.deinit(allocator);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeText(&out.writer, &report);
    try std.testing.expectEqualStrings(
        "ripgrep /opt/tools/rg source=path sha256=" ++ ("0123456789abcdef" ** 4) ++ " expected=" ++ ("0123456789abcdef" ** 4) ++ " match=true provenance=n/a\n" ++
            "tinykg unresolved source=- sha256=- expected=none match=n/a provenance=n/a\n" ++
            "formal_kernel unresolved source=- sha256=- expected=none match=n/a provenance=n/a\n" ++
            "project_kernel unresolved source=- sha256=- expected=none match=n/a provenance=n/a\n" ++
            "tinykgd unresolved source=- sha256=- expected=none match=n/a provenance=n/a\n",
        out.written(),
    );
}

test "doctor health: unresolved fails, a mismatch fails, no expectation passes" {
    const allocator = std.testing.allocator;
    var unresolved = try testReport(allocator);
    defer unresolved.deinit(allocator);
    try std.testing.expect(!unresolved.healthy());

    unresolved.checks[1].resolved_path = try allocator.dupe(u8, "/opt/tools/tinykg");
    try std.testing.expect(unresolved.healthy());

    unresolved.checks[0].match = false;
    try std.testing.expect(!unresolved.healthy());
}

test "doctor hashes a file in chunks and matches the one-shot digest" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try allocator.alloc(u8, 200_000);
    defer allocator.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i * 7 + i / 251);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blob.bin", .data = bytes });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const path = try std.fmt.allocPrint(allocator, "{s}/blob.bin", .{root});
    defer allocator.free(path);

    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &expected, .{});
    const hex = std.fmt.bytesToHex(expected, .lower);
    const hashed = try hashFile(path);
    try std.testing.expectEqualStrings(&hex, &hashed);

    const missing = try std.fmt.allocPrint(allocator, "{s}/absent.bin", .{root});
    defer allocator.free(missing);
    try std.testing.expectError(error.Unreadable, hashFile(missing));
}

test "doctor check with an expectation but an unreadable file is a mismatch, not a crash" {
    const allocator = std.testing.allocator;
    var check = try Check.init(allocator, "tinykg", .{ .path = "/definitely/absent/tinykg", .source = .env }, test_digest);
    defer check.deinit(allocator);
    try std.testing.expect(check.sha256 == null);
    try std.testing.expectEqual(@as(?bool, false), check.match);
    try std.testing.expectEqual(@as(?Source, .env), check.source);
}

test "doctor Kernel adjacent resolution reports mismatch and missing provenance" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "bin");
    try tmp.dir.createDirPath(std.testing.io, "libexec/metacodes");
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = try std.fmt.bufPrint(&exe_buf, "{s}/bin/metacodes", .{root});
    const kernel_name = if (@import("builtin").os.tag == .windows) "metacodes-formal-kernel.exe" else "metacodes-formal-kernel";
    var kernel_rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const kernel_rel = try std.fmt.bufPrint(&kernel_rel_buf, "libexec/metacodes/{s}", .{kernel_name});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = kernel_rel, .data = "kernel" });

    const digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    var report = try run(allocator, .{
        .ripgrep_sha256 = null,
        .tinykg_sha256 = null,
        .formal_kernel_sha256 = digest,
        .exe_path_override = exe,
    });
    defer report.deinit(allocator);
    try std.testing.expectEqual(Source.adjacent, report.checks[2].source.?);
    try std.testing.expectEqual(@as(?bool, false), report.checks[2].match);
    try std.testing.expectEqual(@as(?bool, false), report.checks[2].provenance);
}

test "doctor Kernel absent without expectation is unresolved and healthy for the kernel check" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "bin");
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = try std.fmt.bufPrint(&exe_buf, "{s}/bin/metacodes", .{root});
    var report = try run(allocator, .{
        .ripgrep_sha256 = null,
        .tinykg_sha256 = null,
        .exe_path_override = exe,
    });
    defer report.deinit(allocator);
    try std.testing.expect(report.checks[2].resolved_path == null);
    try std.testing.expectEqual(@as(?bool, null), report.checks[2].provenance);
}

/// A staged `bin/metacodes` next to `libexec/metacodes/<kernel>` whose bytes
/// are `"kernel"`; the sidecars are written per test.
const KernelStage = struct {
    tmp: std.testing.TmpDir,
    exe: []u8,
    kernel_path: []u8,
    kernel_rel: []u8,
    binary_sha256: [64]u8,

    fn init(allocator: std.mem.Allocator, kernel: toolchain.KernelName) !KernelStage {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(std.testing.io, "bin");
        try tmp.dir.createDirPath(std.testing.io, "libexec/metacodes");
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
        const exe = try std.fmt.allocPrint(allocator, "{s}/bin/metacodes", .{root});
        errdefer allocator.free(exe);
        const base = switch (kernel) {
            .formal => "metacodes-formal-kernel",
            .project => "metacodes-project-kernel",
        };
        const suffix = if (@import("builtin").os.tag == .windows) ".exe" else "";
        const kernel_rel = try std.fmt.allocPrint(allocator, "libexec/metacodes/{s}{s}", .{ base, suffix });
        errdefer allocator.free(kernel_rel);
        const kernel_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, kernel_rel });
        errdefer allocator.free(kernel_path);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = kernel_rel, .data = "kernel" });
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash("kernel", &digest, .{});
        return .{ .tmp = tmp, .exe = exe, .kernel_path = kernel_path, .kernel_rel = kernel_rel, .binary_sha256 = std.fmt.bytesToHex(digest, .lower) };
    }

    fn deinit(self: *KernelStage, allocator: std.mem.Allocator) void {
        allocator.free(self.kernel_path);
        allocator.free(self.kernel_rel);
        allocator.free(self.exe);
        self.tmp.cleanup();
    }

    fn writeSidecar(self: *KernelStage, allocator: std.mem.Allocator, suffix: []const u8, bytes: []const u8) !void {
        const rel = try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.kernel_rel, suffix });
        defer allocator.free(rel);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = rel, .data = bytes });
    }

    /// The formal kernel's sidecars: v4 manifest plus its hash-bound receipt.
    fn writeFormalSidecars(self: *KernelStage, allocator: std.mem.Allocator) !void {
        const manifest = try kernel_fixtures.formalManifest(allocator, &self.binary_sha256, "kernel".len);
        defer allocator.free(manifest);
        const receipt = try kernel_fixtures.formalBuildReceipt(allocator, manifest, &self.binary_sha256);
        defer allocator.free(receipt);
        try self.writeSidecar(allocator, ".provenance.json", manifest);
        try self.writeSidecar(allocator, ".build-receipt.json", receipt);
    }

    /// The project kernel's sidecar: the v6 manifest alone (no receipt).
    fn writeProjectSidecar(self: *KernelStage, allocator: std.mem.Allocator) !void {
        const manifest = try kernel_fixtures.projectManifest(allocator, &self.binary_sha256, "kernel".len);
        defer allocator.free(manifest);
        try self.writeSidecar(allocator, ".provenance.json", manifest);
    }

    fn report(self: *KernelStage, allocator: std.mem.Allocator, kernel: toolchain.KernelName) !Report {
        var built = try run(allocator, .{
            .ripgrep_sha256 = null,
            .tinykg_sha256 = null,
            .formal_kernel_sha256 = if (kernel == .formal) &self.binary_sha256 else null,
            .project_kernel_sha256 = if (kernel == .project) &self.binary_sha256 else null,
            .exe_path_override = self.exe,
        });
        errdefer built.deinit(allocator);
        // The legacy tools are outside these tests' interest; `healthy()`
        // must not fail on a runner without rg or a staged TinyKG.
        for (built.checks[0..2]) |*check| {
            if (check.resolved_path == null) check.resolved_path = try allocator.dupe(u8, "/test/legacy-tool");
        }
        return built;
    }
};

/// Paths name the same file when they differ only in separators on Windows,
/// which accepts both: the adjacent-kernel probe joins `<prefix>`, the literal
/// `libexec/metacodes` and the file name with `\` there.
fn expectSamePath(expected: []const u8, actual: []const u8) !void {
    const same = expected.len == actual.len and for (expected, actual) |e, a| {
        if (e != a and !(@import("builtin").os.tag == .windows and
            std.fs.path.isSep(e) and std.fs.path.isSep(a))) break false;
    } else true;
    if (!same) try std.testing.expectEqualStrings(expected, actual);
}

test "doctor Kernel accepts bound provenance sidecars" {
    const allocator = std.testing.allocator;
    var stage = try KernelStage.init(allocator, .formal);
    defer stage.deinit(allocator);

    {
        var without = try stage.report(allocator, .formal);
        defer without.deinit(allocator);
        try expectSamePath(stage.kernel_path, without.checks[2].resolved_path.?);
        try std.testing.expectEqual(@as(?bool, true), without.checks[2].match);
        try std.testing.expectEqual(@as(?bool, false), without.checks[2].provenance);
        try std.testing.expect(!without.healthy());
    }

    try stage.writeFormalSidecars(allocator);
    var with = try stage.report(allocator, .formal);
    defer with.deinit(allocator);
    try expectSamePath(stage.kernel_path, with.checks[2].resolved_path.?);
    try std.testing.expectEqual(@as(?bool, true), with.checks[2].match);
    try std.testing.expectEqual(@as(?bool, true), with.checks[2].provenance);
    try std.testing.expect(with.healthy());
}

test "doctor project Kernel accepts its v6 provenance sidecar" {
    const allocator = std.testing.allocator;
    var stage = try KernelStage.init(allocator, .project);
    defer stage.deinit(allocator);

    {
        var without = try stage.report(allocator, .project);
        defer without.deinit(allocator);
        try expectSamePath(stage.kernel_path, without.checks[3].resolved_path.?);
        try std.testing.expectEqual(Source.adjacent, without.checks[3].source.?);
        try std.testing.expectEqual(@as(?bool, true), without.checks[3].match);
        try std.testing.expectEqual(@as(?bool, false), without.checks[3].provenance);
        try std.testing.expect(!without.healthy());
    }

    try stage.writeProjectSidecar(allocator);
    var with = try stage.report(allocator, .project);
    defer with.deinit(allocator);
    try std.testing.expectEqual(@as(?bool, true), with.checks[3].match);
    try std.testing.expectEqual(@as(?bool, true), with.checks[3].provenance);
    // The formal kernel is neither pinned nor staged here: unresolved, no verdict.
    try std.testing.expect(with.checks[2].resolved_path == null);
    try std.testing.expectEqual(@as(?bool, null), with.checks[2].provenance);
    try std.testing.expect(with.healthy());
}

test "doctor project Kernel rejects a formal-schema sidecar" {
    const allocator = std.testing.allocator;
    var stage = try KernelStage.init(allocator, .project);
    defer stage.deinit(allocator);
    // A complete, internally consistent formal v4 manifest and receipt, bound
    // to this very binary: valid for the formal kernel, wrong document here.
    try stage.writeFormalSidecars(allocator);
    var report = try stage.report(allocator, .project);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(?bool, true), report.checks[3].match);
    try std.testing.expectEqual(@as(?bool, false), report.checks[3].provenance);
    try std.testing.expect(!report.healthy());
}

test "doctor formal Kernel rejects a project-schema sidecar" {
    const allocator = std.testing.allocator;
    var stage = try KernelStage.init(allocator, .formal);
    defer stage.deinit(allocator);
    try stage.writeProjectSidecar(allocator);
    var report = try stage.report(allocator, .formal);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(?bool, true), report.checks[2].match);
    try std.testing.expectEqual(@as(?bool, false), report.checks[2].provenance);
    try std.testing.expect(!report.healthy());

    // Adding the receipt the formal loader wants does not rescue a manifest
    // of the wrong schema.
    const manifest = try kernel_fixtures.projectManifest(allocator, &stage.binary_sha256, "kernel".len);
    defer allocator.free(manifest);
    const receipt = try kernel_fixtures.formalBuildReceipt(allocator, manifest, &stage.binary_sha256);
    defer allocator.free(receipt);
    try stage.writeSidecar(allocator, ".build-receipt.json", receipt);
    var still = try stage.report(allocator, .formal);
    defer still.deinit(allocator);
    try std.testing.expectEqual(@as(?bool, false), still.checks[2].provenance);
}

const env_paths = @import("platform").paths;

fn clearKernelEnv() void {
    env_paths.unsetEnv("METACODES_PROJECT_KERNEL_PATH");
    env_paths.unsetEnv("METACODES_PROJECT_KERNEL_SHA256");
    env_paths.unsetEnv("METACODES_PROJECT_KERNEL_TIMEOUT_MS");
}

test "doctor env pair holds the kernel to the pair's digest, not the pin" {
    const allocator = std.testing.allocator;
    var stage = try KernelStage.init(allocator, .project);
    defer stage.deinit(allocator);
    try stage.writeProjectSidecar(allocator);
    clearKernelEnv();
    defer clearKernelEnv();
    const path_z = try allocator.dupeZ(u8, stage.kernel_path);
    defer allocator.free(path_z);
    env_paths.setEnv("METACODES_PROJECT_KERNEL_PATH", path_z);

    // A compiled pin that would match the file, so that a doctor consulting
    // the pin instead of the pair is caught below.
    const pin: []const u8 = &stage.binary_sha256;

    // The pair names a digest the file does not have: the runtime would
    // refuse to execute it, so doctor must not call it a match — even though
    // the compiled pin does match.
    env_paths.setEnv("METACODES_PROJECT_KERNEL_SHA256", "b" ** 64);
    var wrong = try run(allocator, .{ .ripgrep_sha256 = null, .tinykg_sha256 = null, .project_kernel_sha256 = pin, .exe_path_override = stage.exe });
    for (wrong.checks[0..2]) |*check| {
        if (check.resolved_path == null) check.resolved_path = try allocator.dupe(u8, "/test/legacy-tool");
    }
    try std.testing.expectEqualStrings(stage.kernel_path, wrong.checks[3].resolved_path.?);
    try std.testing.expectEqual(Source.env, wrong.checks[3].source.?);
    try std.testing.expectEqualStrings("b" ** 64, &wrong.checks[3].expected_sha256.?);
    try std.testing.expectEqual(@as(?bool, false), wrong.checks[3].match);
    try std.testing.expectEqual(@as(?bool, true), wrong.checks[3].provenance);
    try std.testing.expect(!wrong.healthy());
    wrong.deinit(allocator);

    // The pair's digest is the file's: healthy, and a compiled pin that does
    // NOT match plays no part.
    const digest_z = try allocator.dupeZ(u8, &stage.binary_sha256);
    defer allocator.free(digest_z);
    env_paths.setEnv("METACODES_PROJECT_KERNEL_SHA256", digest_z);
    var right = try run(allocator, .{ .ripgrep_sha256 = null, .tinykg_sha256 = null, .project_kernel_sha256 = "c" ** 64, .exe_path_override = stage.exe });
    defer right.deinit(allocator);
    for (right.checks[0..2]) |*check| {
        if (check.resolved_path == null) check.resolved_path = try allocator.dupe(u8, "/test/legacy-tool");
    }
    try std.testing.expectEqualStrings(&stage.binary_sha256, &right.checks[3].expected_sha256.?);
    try std.testing.expectEqual(@as(?bool, true), right.checks[3].match);
    try std.testing.expectEqual(@as(?bool, true), right.checks[3].provenance);
    try std.testing.expect(right.healthy());
}

test "doctor env pair the runtime rejects is reported as env with nothing resolved" {
    const allocator = std.testing.allocator;
    var stage = try KernelStage.init(allocator, .project);
    defer stage.deinit(allocator);
    try stage.writeProjectSidecar(allocator);
    clearKernelEnv();
    defer clearKernelEnv();
    const path_z = try allocator.dupeZ(u8, stage.kernel_path);
    defer allocator.free(path_z);
    // Half a pair: the runtime's loadConfigFromEnv says `.invalid`.
    env_paths.setEnv("METACODES_PROJECT_KERNEL_PATH", path_z);
    var report = try run(allocator, .{ .ripgrep_sha256 = null, .tinykg_sha256 = null, .exe_path_override = stage.exe });
    defer report.deinit(allocator);
    for (report.checks[0..2]) |*check| {
        if (check.resolved_path == null) check.resolved_path = try allocator.dupe(u8, "/test/legacy-tool");
    }
    try std.testing.expect(report.checks[3].resolved_path == null);
    try std.testing.expectEqual(Source.env, report.checks[3].source.?);
    try std.testing.expectEqual(@as(?bool, null), report.checks[3].provenance);
    try std.testing.expect(!report.healthy());
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeText(&out.writer, &report);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "project_kernel unresolved source=env ") != null);
}

test "doctor Kernel reached through a symlink is not trusted" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var stage = try KernelStage.init(allocator, .project);
    defer stage.deinit(allocator);
    try stage.writeProjectSidecar(allocator);
    // Move the real bytes aside and leave a symlink at the kernel's path; the
    // sidecar beside the symlink is valid for those bytes.
    try stage.tmp.dir.rename(stage.kernel_rel, stage.tmp.dir, "libexec/metacodes/real-kernel", std.testing.io);
    try stage.tmp.dir.symLink(std.testing.io, "real-kernel", stage.kernel_rel, .{});
    var report = try stage.report(allocator, .project);
    defer report.deinit(allocator);
    try std.testing.expectEqualStrings(stage.kernel_path, report.checks[3].resolved_path.?);
    // The runtime opens the path NOFOLLOW and would refuse it; doctor hashes
    // the same way, so the link has no digest, no match and no provenance.
    try std.testing.expect(report.checks[3].sha256 == null);
    try std.testing.expectEqual(@as(?bool, false), report.checks[3].match);
    try std.testing.expectEqual(@as(?bool, false), report.checks[3].provenance);
    try std.testing.expect(!report.healthy());
}

test "doctor timeout override the runtime rejects makes a pinned adjacent kernel unhealthy" {
    const allocator = std.testing.allocator;
    var stage = try KernelStage.init(allocator, .project);
    defer stage.deinit(allocator);
    try stage.writeProjectSidecar(allocator);
    clearKernelEnv();
    defer clearKernelEnv();

    // Only the timeout is set, out of range: `loadConfig` answers `.invalid`
    // for the pinned adjacent kernel, so nothing will execute it.
    env_paths.setEnv("METACODES_PROJECT_KERNEL_TIMEOUT_MS", "50");
    var rejected = try stage.report(allocator, .project);
    try std.testing.expect(rejected.checks[3].resolved_path == null);
    try std.testing.expectEqual(Source.env, rejected.checks[3].source.?);
    try std.testing.expect(!rejected.healthy());
    rejected.deinit(allocator);

    // In range: the adjacent kernel is used as pinned.
    env_paths.setEnv("METACODES_PROJECT_KERNEL_TIMEOUT_MS", "250");
    var accepted = try stage.report(allocator, .project);
    defer accepted.deinit(allocator);
    try std.testing.expectEqual(Source.adjacent, accepted.checks[3].source.?);
    try std.testing.expectEqual(@as(?bool, true), accepted.checks[3].match);
    try std.testing.expectEqual(@as(?bool, true), accepted.checks[3].provenance);
    try std.testing.expect(accepted.healthy());
}

test "doctor empty Kernel is refused by the admission read" {
    const allocator = std.testing.allocator;
    var stage = try KernelStage.init(allocator, .project);
    defer stage.deinit(allocator);
    try stage.writeProjectSidecar(allocator);
    // The runtime's `readChecker` refuses an empty file before reading it;
    // doctor's admission read must agree (the post-read size check has no
    // deterministic seam here and is not what this test exercises).
    try stage.tmp.dir.writeFile(std.testing.io, .{ .sub_path = stage.kernel_rel, .data = "" });
    var report = try stage.report(allocator, .project);
    defer report.deinit(allocator);
    try std.testing.expect(report.checks[3].sha256 == null);
    try std.testing.expectEqual(@as(?bool, false), report.checks[3].match);
    try std.testing.expectEqual(@as(?bool, false), report.checks[3].provenance);
    try std.testing.expect(!report.healthy());
}
