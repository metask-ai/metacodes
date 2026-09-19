//! `metacodes doctor` (#78, #47 stage 3): where the runtime binaries this
//! build depends on resolve from, and whether they are the ones the build
//! expected. ripgrep goes through `toolchain.ripgrepResolution` and TinyKG
//! through `KgClient.resolveTinykgBinary` — the same decisions the tools make
//! at run time, taken without side effects (no Store is created, no daemon
//! contacted, nothing written). The expectations are the digests `build.zig`
//! pinned into `build_info` for the target; a target without a vendored
//! binary has none, and the check then only reports where the binary came
//! from. `--strict` turns an unresolved binary or a digest mismatch into exit
//! code 1 so an install step can fail closed on it.
const std = @import("std");
const pfs = @import("platform").fs;
const toolchain = @import("../util/toolchain.zig");
const kg_client = @import("../kg/client.zig");
const formal_runtime = @import("../formal/runtime.zig");
const project_runtime = @import("../formal/project_harness_runtime.zig");
const provenance = @import("../formal/provenance.zig");

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
    /// The digest `build_info` pinned for this target; null when it pinned none.
    expected_sha256: ?[]const u8,
    /// null when there is no expectation; otherwise digest equality (false
    /// also when the file could not be hashed).
    match: ?bool,
    source: ?Source,
    /// Kernel-only provenance result; null for unresolved kernels and legacy tools.
    provenance: ?bool,

    pub fn deinit(self: *Check, allocator: std.mem.Allocator) void {
        if (self.resolved_path) |path| allocator.free(path);
        self.resolved_path = null;
    }

    fn init(allocator: std.mem.Allocator, name: []const u8, resolved: ?Resolved, expected: ?[]const u8) !Check {
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
        check.resolved_path = try allocator.dupe(u8, found.path);
        errdefer check.deinit(allocator);
        check.source = found.source;
        check.sha256 = hashFile(found.path) catch null;
        if (expected) |want| {
            if (check.sha256) |*digest| check.match = std.mem.eql(u8, digest, want);
        }
        return check;
    }
};

const Resolved = struct { path: []const u8, source: Source };

/// What `build_info` pinned for the target (`main.zig` fills this from the
/// module; the library never imports it).
pub const Expectations = struct {
    ripgrep_sha256: ?[]const u8,
    tinykg_sha256: ?[]const u8,
    formal_kernel_sha256: ?[]const u8 = null,
    project_kernel_sha256: ?[]const u8 = null,
    exe_path_override: ?[]const u8 = null,
};

pub const Report = struct {
    /// `[0]` ripgrep, `[1]` TinyKG, `[2]` formal kernel, `[3]` project kernel.
    checks: [4]Check,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (&self.checks) |*check| check.deinit(allocator);
    }

    /// Every binary resolved, and every one with an expectation matches it.
    pub fn healthy(self: *const Report) bool {
        for (&self.checks) |*check| {
            const is_kernel = std.mem.eql(u8, check.name, "formal_kernel") or std.mem.eql(u8, check.name, "project_kernel");
            if (check.resolved_path == null) {
                if (!is_kernel or check.expected_sha256 != null) return false;
                continue;
            }
            if (check.match) |matched| if (!matched) return false;
            if (is_kernel and check.provenance != true) return false;
        }
        return true;
    }
};

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
    var checks: [4]Check = undefined;
    checks[0] = try Check.init(allocator, "ripgrep", ripgrep, expected.ripgrep_sha256);
    errdefer checks[0].deinit(allocator);

    // `exe_dir = null` resolves the adjacent layout from the real executable
    // directory; `config_bin = null` mirrors app.zig, where config.json carries
    // no `kg_bin` yet. `home` and `domain` only shape the Store path, which
    // this pure resolution never touches.
    var tinykg = try kg_client.KgClient.resolveTinykgBinary(allocator, .{ .home = "", .domain = "" });
    defer if (tinykg) |*found| found.deinit(allocator);
    const tinykg_resolved: ?Resolved = if (tinykg) |found| .{
        .path = found.path,
        .source = switch (found.source) {
            .env => .env,
            .config => .config,
            .adjacent => .adjacent,
        },
    } else null;
    checks[1] = try Check.init(allocator, "tinykg", tinykg_resolved, expected.tinykg_sha256);

    var formal_override_buf: [std.fs.max_path_bytes]u8 = undefined;
    const formal = resolveKernel(.formal, expected.formal_kernel_sha256, expected.exe_path_override, &formal_override_buf);
    checks[2] = try Check.init(allocator, "formal_kernel", formal, expected.formal_kernel_sha256);
    errdefer checks[2].deinit(allocator);
    checks[2].provenance = try kernelProvenance(allocator, checks[2].resolved_path, checks[2].sha256);

    var project_override_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project = resolveKernel(.project, expected.project_kernel_sha256, expected.exe_path_override, &project_override_buf);
    checks[3] = try Check.init(allocator, "project_kernel", project, expected.project_kernel_sha256);
    checks[3].provenance = try kernelProvenance(allocator, checks[3].resolved_path, checks[3].sha256);
    return .{ .checks = checks };
}

fn resolveKernel(name: toolchain.KernelName, expected: ?[]const u8, exe_override: ?[]const u8, override_buf: []u8) ?Resolved {
    const env_present = switch (name) {
        .formal => std.c.getenv("METACODES_FORMAL_KERNEL_PATH") != null or std.c.getenv("METACODES_FORMAL_KERNEL_SHA256") != null,
        .project => std.c.getenv("METACODES_PROJECT_KERNEL_PATH") != null or std.c.getenv("METACODES_PROJECT_KERNEL_SHA256") != null,
    };
    if (env_present) {
        return switch (name) {
            .formal => switch (formal_runtime.loadConfigFromEnv()) {
                .configured => |config| .{ .path = config.checker_path, .source = .env },
                else => null,
            },
            .project => switch (project_runtime.loadConfigFromEnv()) {
                .configured => |config| .{ .path = config.checker_path, .source = .env },
                else => null,
            },
        };
    }
    if (expected == null) return null;
    if (exe_override) |exe| {
        return if (toolchain.kernelPathBeside(exe, name, override_buf)) |path| .{ .path = path, .source = .adjacent } else null;
    }
    const path = toolchain.kernelAdjacentPath(name) orelse return null;
    return .{ .path = path, .source = .adjacent };
}

fn kernelProvenance(allocator: std.mem.Allocator, path: ?[]u8, digest: ?[64]u8) !?bool {
    const checker_path = path orelse return null;
    const actual_sha256 = digest orelse return false;
    const actual_bytes = fileBytes(checker_path) orelse return false;
    var loaded = provenance.loadAdjacent(allocator, checker_path, actual_sha256, actual_bytes) catch return false;
    loaded.deinit();
    return true;
}

fn fileBytes(path: []const u8) ?u64 {
    var path_z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= path_z.len) return null;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const fd = pfs.open(path_z[0..path.len :0], .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = pfs.close(fd);
    const info = pfs.fileInfo(fd) catch return null;
    if (!info.is_regular or info.size < 0) return null;
    return @intCast(info.size);
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
            check.expected_sha256 orelse "none",
            if (check.match) |matched| (if (matched) "true" else "false") else "n/a",
            if (check.provenance) |valid| (if (valid) "true" else "false") else "n/a",
        });
    }
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
    var entries: [4]Entry = undefined;
    for (&report.checks, &entries) |*check, *entry| {
        entry.* = .{
            .name = check.name,
            .resolved_path = check.resolved_path,
            .sha256 = if (check.sha256) |*digest| digest[0..] else null,
            .expected_sha256 = check.expected_sha256,
            .match = check.match,
            .source = if (check.source) |source| @tagName(source) else null,
            .provenance = check.provenance,
        };
    }
    try std.json.Stringify.value(.{ .checks = entries }, .{}, w);
    try w.writeByte('\n');
}

const test_digest: [64]u8 = ("0123456789abcdef" ** 4).*;

fn testReport(allocator: std.mem.Allocator) !Report {
    return .{ .checks = .{
        .{
            .name = "ripgrep",
            .resolved_path = try allocator.dupe(u8, "/opt/tools/rg"),
            .sha256 = test_digest,
            .expected_sha256 = &test_digest,
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
    } };
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
            "{\"name\":\"project_kernel\",\"resolved_path\":null,\"sha256\":null,\"expected_sha256\":null,\"match\":null,\"source\":null,\"provenance\":null}]}\n",
        out.written(),
    );
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
            "project_kernel unresolved source=- sha256=- expected=none match=n/a provenance=n/a\n",
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
    var check = try Check.init(allocator, "tinykg", .{ .path = "/definitely/absent/tinykg", .source = .env }, &test_digest);
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

test "doctor Kernel accepts bound provenance sidecars" {
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
    var kernel_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const kernel_path = try std.fmt.bufPrint(&kernel_path_buf, "{s}/{s}", .{ root, kernel_rel });
    var binary_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("kernel", &binary_digest, .{});
    const binary_sha = std.fmt.bytesToHex(binary_digest, .lower);
    const zeros = "0" ** 64;
    const host_os = switch (@import("builtin").os.tag) {
        .macos => "Darwin",
        .linux => "Linux",
        .windows => "Windows",
        else => return error.SkipZigTest,
    };
    const host_arch = switch (@import("builtin").cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => if (@import("builtin").os.tag == .macos) "arm64" else "aarch64",
        else => return error.SkipZigTest,
    };
    var report = try run(allocator, .{
        .ripgrep_sha256 = null,
        .tinykg_sha256 = null,
        .formal_kernel_sha256 = &binary_sha,
        .exe_path_override = exe,
    });
    for (report.checks[0..2]) |*check| {
        if (check.resolved_path == null) check.resolved_path = try allocator.dupe(u8, "/test/legacy-tool");
    }
    try std.testing.expectEqualStrings(kernel_path, report.checks[2].resolved_path.?);
    try std.testing.expectEqual(@as(?bool, true), report.checks[2].match);
    try std.testing.expectEqual(@as(?bool, false), report.checks[2].provenance);
    try std.testing.expect(!report.healthy());
    report.deinit(allocator);

    const manifest = try std.fmt.allocPrint(allocator, "{{\"schema_version\":\"metacodes-formal-artifact-v4\",\"checker_version\":\"{s}\",\"request_schema\":\"{s}\",\"memory_request_schema\":\"{s}\",\"artifact_request_schema\":\"{s}\",\"verdict_schema\":\"{s}\",\"binary_sha256\":\"{s}\",\"binary_bytes\":6,\"kernel_source_sha256\":\"{s}\",\"memory_kernel_source_sha256\":\"{s}\",\"artifact_kernel_source_sha256\":\"{s}\",\"main_source_sha256\":\"{s}\",\"axiom_audit_source_sha256\":\"{s}\",\"axiom_policy\":\"propext,Quot.sound\",\"axiom_audit\":\"passed\",\"host_os\":\"{s}\",\"host_arch\":\"{s}\",\"linker\":\"zig\",\"lean_version\":\"4\",\"native_smoke\":\"passed\"}}", .{ formal_runtime.CHECKER_VERSION, formal_runtime.REQUEST_SCHEMA, formal_runtime.MEMORY_REQUEST_SCHEMA, formal_runtime.ARTIFACT_REQUEST_SCHEMA, formal_runtime.VERDICT_SCHEMA, binary_sha, zeros, zeros, zeros, zeros, zeros, host_os, host_arch });
    defer allocator.free(manifest);
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(manifest, &manifest_digest, .{});
    const manifest_sha = std.fmt.bytesToHex(manifest_digest, .lower);
    const receipt = try std.fmt.allocPrint(allocator, "{{\"schema_version\":\"metacodes-formal-build-receipt-v1\",\"artifact_manifest_sha256\":\"{s}\",\"binary_sha256\":\"{s}\",\"built_at_utc\":\"2026-01-01T00:00:00Z\"}}", .{ manifest_sha, binary_sha });
    defer allocator.free(receipt);
    var manifest_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(&manifest_path_buf, "{s}.provenance.json", .{kernel_rel});
    var receipt_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const receipt_path = try std.fmt.bufPrint(&receipt_path_buf, "{s}.build-receipt.json", .{kernel_rel});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = manifest_path, .data = manifest });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = receipt_path, .data = receipt });

    report = try run(allocator, .{
        .ripgrep_sha256 = null,
        .tinykg_sha256 = null,
        .formal_kernel_sha256 = &binary_sha,
        .exe_path_override = exe,
    });
    defer report.deinit(allocator);
    for (report.checks[0..2]) |*check| {
        if (check.resolved_path == null) check.resolved_path = try allocator.dupe(u8, "/test/legacy-tool");
    }
    try std.testing.expectEqualStrings(kernel_path, report.checks[2].resolved_path.?);
    try std.testing.expectEqual(@as(?bool, true), report.checks[2].match);
    try std.testing.expectEqual(@as(?bool, true), report.checks[2].provenance);
    try std.testing.expect(report.healthy());
}
