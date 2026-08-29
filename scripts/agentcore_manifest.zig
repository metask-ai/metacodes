const std = @import("std");
const builtin = @import("builtin");
const abi_types = @import("metask_agentcore_types");

const Sha256 = std.crypto.hash.sha2.Sha256;

const FileEntry = struct {
    path: []const u8,
    sha256: []const u8,
};

/// An executable the bundled tools spawn at run time. Shipping it as a
/// manifest asset closes the Glob/Grep dependency loop: the Host that
/// redistributes the bundle also receives the executable and its pin,
/// instead of relying on ambient rg installations.
const RuntimeAsset = struct {
    name: []const u8,
    version: []const u8,
    revision: []const u8,
    path: []const u8,
    upstream: []const u8,
    license: []const u8,
    role: []const u8,
};

/// Upstream identity of the vendored ripgrep set, read from the repository's
/// pin authority (vendor/ripgrep/manifest.json) so the bundle manifest cannot
/// drift from the staged binary's provenance.
const RipgrepPin = struct {
    upstream_release: []const u8,
    upstream_revision: []const u8,
    source_repository: []const u8,
    license: []const u8,
};

const Manifest = struct {
    schema_version: u32 = 1,
    vendor: []const u8 = "metask",
    name: []const u8 = "agentcore",
    version: []const u8,
    source: struct {
        commit: []const u8,
        dirty: bool,
    },
    toolchain: struct { zig_version: []const u8 },
    target: struct {
        id: []const u8,
        architecture: []const u8,
        os: []const u8,
        abi: []const u8,
        zig_target: []const u8,
        rust_target: []const u8,
    },
    build: struct {
        optimize: []const u8,
        strip: bool,
    },
    link: struct {
        requires_c_runtime: bool = true,
        system_libraries: []const []const u8,
        system_frameworks: []const []const u8,
    },
    contract: struct {
        binary_abi_status: []const u8 = "experimental",
        binary_abi_version: u32 = abi_types.ABI_VERSION_V1,
        binary_abi_revision: u32 = abi_types.ABI_REVISION,
        binary_abi_table_size: u32 = @sizeOf(abi_types.ApiV1),
    },
    runtime_assets: []const RuntimeAsset,
    files: []const FileEntry,
};

const SourceIdentity = struct {
    commit: []const u8,
    dirty: bool,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = std.process.Args.iterateAllocator(init.minimal.args, allocator) catch
        return error.InvalidArguments;
    defer args.deinit();
    _ = args.next();

    const bundle_root = args.next() orelse return usage();
    const resolved_target = args.next() orelse return usage();
    const architecture = args.next() orelse return usage();
    const os = args.next() orelse return usage();
    const abi = args.next() orelse return usage();
    const optimize = args.next() orelse return usage();
    const strip_text = args.next() orelse return usage();
    const library_file = args.next() orelse return usage();
    if (args.next() != null) return usage();

    if (bundle_root.len == 0 or resolved_target.len == 0 or architecture.len == 0 or
        os.len == 0 or abi.len == 0 or optimize.len == 0 or library_file.len == 0)
        return error.EmptyMetadata;
    const strip = parseBool(strip_text) orelse return error.InvalidBoolean;

    const source = try sourceIdentity(allocator, init.io);
    const sdk_version_bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        "sdk/VERSION",
        allocator,
        .limited(256),
    );
    const sdk_version = std.mem.trim(u8, sdk_version_bytes, " \r\n\t");
    const version = try packageVersion(allocator, sdk_version, source);
    if (version.len > 32) return error.PackageVersionTooLong;
    const target_id = try packageTargetId(allocator, architecture, os, abi);
    const rust_target = try rustTarget(architecture, os, abi);
    const no_link_inputs = [_][]const u8{};
    const windows_libraries = [_][]const u8{ "advapi32", "crypt32" };
    const system_libraries: []const []const u8 = if (std.mem.eql(u8, os, "windows"))
        &windows_libraries
    else
        &no_link_inputs;
    const system_frameworks: []const []const u8 = &no_link_inputs;
    const ripgrep_rel: []const u8 = if (std.mem.eql(u8, os, "windows")) "bin/rg.exe" else "bin/rg";
    const ripgrep_pin = try loadRipgrepPin(allocator, init.io);
    const readme = try renderReadme(
        allocator,
        version,
        target_id,
        resolved_target,
        rust_target,
        source.commit,
        ripgrep_rel,
        ripgrep_pin.upstream_release,
    );
    const zon = try renderZon(allocator, version);
    const cargo = try renderCargoToml(allocator, version);
    const cargo_lock = try renderCargoLock(allocator, version);
    const rust_link_config = try renderRustLinkConfig(allocator, rust_target, system_libraries, system_frameworks);
    try writeBundleFile(allocator, init.io, bundle_root, "README.md", readme);
    try writeBundleFile(allocator, init.io, bundle_root, "bindings/zig/build.zig.zon", zon);
    try writeBundleFile(allocator, init.io, bundle_root, "bindings/rust/Cargo.toml", cargo);
    try writeBundleFile(allocator, init.io, bundle_root, "bindings/rust/Cargo.lock", cargo_lock);
    try writeBundleFile(allocator, init.io, bundle_root, "bindings/rust/link.cfg", rust_link_config);

    const library_rel = try std.fmt.allocPrint(allocator, "lib/{s}", .{library_file});
    const relative_paths = [_][]const u8{
        library_rel,
        ripgrep_rel,
        "bin/ripgrep-LICENSE-MIT",
        "include/metask/agentcore.h",
        "bindings/zig/build.zig",
        "bindings/zig/build.zig.zon",
        "bindings/zig/src/root.zig",
        "bindings/zig/src/protocol.zig",
        "bindings/zig/src/types.zig",
        "bindings/rust/Cargo.toml",
        "bindings/rust/Cargo.lock",
        "bindings/rust/link.cfg",
        "bindings/rust/build.rs",
        "bindings/rust/src/lib.rs",
        "bindings/rust/src/raw.rs",
        "bindings/rust/examples/link_probe.rs",
        "README.md",
    };

    var digests: [relative_paths.len][64]u8 = undefined;
    var files: [relative_paths.len]FileEntry = undefined;
    for (relative_paths, 0..) |relative_path, index| {
        const installed_path = try std.fs.path.join(allocator, &.{ bundle_root, relative_path });
        digests[index] = std.fmt.bytesToHex(try fileSha256(init.io, installed_path), .lower);
        files[index] = .{ .path = relative_path, .sha256 = &digests[index] };
    }

    const manifest = Manifest{
        .version = version,
        .source = .{
            .commit = source.commit,
            .dirty = source.dirty,
        },
        .toolchain = .{ .zig_version = builtin.zig_version_string },
        .target = .{
            .id = target_id,
            .architecture = architecture,
            .os = os,
            .abi = abi,
            .zig_target = resolved_target,
            .rust_target = rust_target,
        },
        .build = .{
            .optimize = optimize,
            .strip = strip,
        },
        .link = .{
            .system_libraries = system_libraries,
            .system_frameworks = system_frameworks,
        },
        .contract = .{},
        .runtime_assets = &.{.{
            .name = "ripgrep",
            .version = ripgrep_pin.upstream_release,
            .revision = ripgrep_pin.upstream_revision,
            .path = ripgrep_rel,
            .upstream = ripgrep_pin.source_repository,
            .license = ripgrep_pin.license,
            .role = "Glob/Grep execution dependency",
        }},
        .files = &files,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, manifest, .{ .whitespace = .indent_2 });
    const json_with_newline = try std.fmt.allocPrint(allocator, "{s}\n", .{json});
    const manifest_path = try std.fs.path.join(allocator, &.{ bundle_root, "manifest.json" });
    try writeAtomic(init.io, manifest_path, json_with_newline);
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        "usage: agentcore-manifest <bundle-root> <target> <arch> <os> <abi> <optimize> <strip> <library-file>\n",
        .{},
    );
    return error.InvalidArguments;
}

fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

fn loadRipgrepPin(allocator: std.mem.Allocator, io: std.Io) !RipgrepPin {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "vendor/ripgrep/manifest.json",
        allocator,
        .limited(64 * 1024),
    );
    return parseRipgrepPin(allocator, bytes);
}

fn parseRipgrepPin(allocator: std.mem.Allocator, bytes: []const u8) !RipgrepPin {
    const parsed = try std.json.parseFromSliceLeaky(RipgrepPin, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
    if (parsed.upstream_release.len == 0 or parsed.upstream_revision.len == 0 or
        parsed.source_repository.len == 0 or parsed.license.len == 0)
        return error.InvalidRipgrepPin;
    return parsed;
}

fn packageVersion(allocator: std.mem.Allocator, sdk_version: []const u8, source: SourceIdentity) ![]const u8 {
    if (sdk_version.len == 0) return error.InvalidSdkVersion;
    const parsed = std.SemanticVersion.parse(sdk_version) catch return error.InvalidSdkVersion;
    if (parsed.build != null) return error.InvalidSdkVersion;

    if (parsed.pre == null) return allocator.dupe(u8, sdk_version);

    const commit_short = source.commit[0..12];
    return if (source.dirty)
        std.fmt.allocPrint(allocator, "{s}+{s}.dirty", .{ sdk_version, commit_short })
    else
        std.fmt.allocPrint(allocator, "{s}+{s}", .{ sdk_version, commit_short });
}

fn packageTargetId(allocator: std.mem.Allocator, architecture: []const u8, os: []const u8, abi: []const u8) ![]const u8 {
    return if (std.mem.eql(u8, os, "macos"))
        std.fmt.allocPrint(allocator, "{s}-macos", .{architecture})
    else
        std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ architecture, os, abi });
}

fn rustTarget(architecture: []const u8, os: []const u8, abi: []const u8) ![]const u8 {
    if (std.mem.eql(u8, architecture, "x86_64") and std.mem.eql(u8, os, "windows")) {
        if (std.mem.eql(u8, abi, "msvc")) return "x86_64-pc-windows-msvc";
        if (std.mem.eql(u8, abi, "gnu")) return "x86_64-pc-windows-gnu";
    }
    if (std.mem.eql(u8, architecture, "aarch64") and std.mem.eql(u8, os, "windows")) {
        if (std.mem.eql(u8, abi, "msvc")) return "aarch64-pc-windows-msvc";
        if (std.mem.eql(u8, abi, "gnu")) return "aarch64-pc-windows-gnullvm";
    }
    if (std.mem.eql(u8, architecture, "x86_64") and std.mem.eql(u8, os, "linux") and std.mem.eql(u8, abi, "gnu"))
        return "x86_64-unknown-linux-gnu";
    if (std.mem.eql(u8, architecture, "x86_64") and std.mem.eql(u8, os, "macos"))
        return "x86_64-apple-darwin";
    if (std.mem.eql(u8, architecture, "aarch64") and std.mem.eql(u8, os, "macos"))
        return "aarch64-apple-darwin";
    return error.UnsupportedAgentCoreTarget;
}

fn renderReadme(
    allocator: std.mem.Allocator,
    version: []const u8,
    target: []const u8,
    zig_target: []const u8,
    rust_target: []const u8,
    commit: []const u8,
    ripgrep_rel: []const u8,
    ripgrep_version: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\# metask-agentcore {s}
        \\
        \\Target: `{s}`
        \\Producer Zig target: `{s}`
        \\Required Cargo target: `{s}`
        \\Source commit: `{s}`
        \\
        \\C and C++ consumers include `<metask/agentcore.h>` and link the static library in `lib/`.
        \\Zig consumers use the package in `bindings/zig` and import `metask_agentcore`.
        \\Rust consumers use the raw `metask-agentcore-sys` crate in `bindings/rust`.
        \\
        \\`{s}` is the manifest-pinned ripgrep {s} runtime asset (upstream official release
        \\binary, MIT OR Unlicense; MIT text at `bin/ripgrep-LICENSE-MIT`, declaration in
        \\`runtime_assets` in `manifest.json`). The built-in `Glob`/`Grep` tools execute
        \\through it, and Runtime creation refuses to advertise them when no ripgrep
        \\resolves. Deploy it next to your Host executable — that location is probed
        \\automatically — or point the `RG_BIN` environment variable at it; installations
        \\on `PATH` also resolve.
        \\
        \\The ABI is experimental and requires an exact revision match. Ownership, lifetime, concurrency,
        \\and failure contracts are defined by `doc/AGENTCORE_BINARY_ABI.md` at the source commit above.
        \\Revision 14 exposes one 64-byte root plus mandatory Runtime, Session, Session Control, Skill,
        \\and MCP tables. It has no capability negotiation and no independent public Completion client.
        \\The public header and bindings expose the complete Skill catalog resource contract: 16 MiB per
        \\file, 32 MiB/1024 files/4096 entries per Skill, 64 MiB/16384 files/1024 slots per catalog,
        \\65536 traversal entries, depth 64, 4096-byte relative paths, a 4 MiB descriptor, and
        \\256 MiB of retained catalog snapshots per Runtime. `invalid_resource` issues carry a typed
        \\reason; a single invalid Skill degrades the catalog without removing valid siblings.
        \\
    , .{ version, target, zig_target, rust_target, commit, ripgrep_rel, ripgrep_version });
}

fn renderZon(allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\.{{
        \\    .name = .metask_agentcore,
        \\    .version = "{s}",
        \\    .fingerprint = 0xd94cf2aa2005a43c,
        \\    .minimum_zig_version = "0.16.0",
        \\    .paths = .{{ "build.zig", "build.zig.zon", "src" }},
        \\    .dependencies = .{{}},
        \\}}
        \\
    , .{version});
}

fn renderCargoToml(allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\[package]
        \\name = "metask-agentcore-sys"
        \\version = "{s}"
        \\edition = "2021"
        \\links = "metask_agentcore"
        \\build = "build.rs"
        \\publish = false
        \\
        \\[lib]
        \\path = "src/lib.rs"
        \\
    , .{version});
}

fn renderCargoLock(allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\# This file is automatically @generated by Cargo.
        \\# It is not intended for manual editing.
        \\version = 4
        \\
        \\[[package]]
        \\name = "metask-agentcore-sys"
        \\version = "{s}"
        \\
    , .{version});
}

fn renderRustLinkConfig(
    allocator: std.mem.Allocator,
    rust_target: []const u8,
    system_libraries: []const []const u8,
    system_frameworks: []const []const u8,
) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.print("target={s}\n", .{rust_target});
    for (system_libraries) |library|
        try output.writer.print("library={s}\n", .{library});
    for (system_frameworks) |framework|
        try output.writer.print("framework={s}\n", .{framework});
    return output.toOwnedSlice();
}

fn writeBundleFile(allocator: std.mem.Allocator, io: std.Io, bundle_root: []const u8, relative_path: []const u8, bytes: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ bundle_root, relative_path });
    try writeAtomic(io, path, bytes);
}

fn fileSha256(io: std.Io, path: []const u8) ![32]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var hash = Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = try file.readPositional(io, &.{&buffer}, offset);
        if (count == 0) break;
        hash.update(buffer[0..count]);
        offset += count;
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn sourceIdentity(allocator: std.mem.Allocator, io: std.Io) !SourceIdentity {
    const commit_output = try runGit(allocator, io, &.{ "git", "rev-parse", "HEAD" });
    const commit = std.mem.trim(u8, commit_output, " \r\n\t");
    if (commit.len != 40 or !isLowerHex(commit)) return error.InvalidGitCommit;
    const status = try runGit(allocator, io, &.{
        "git", "status", "--porcelain=v1", "-z", "--untracked-files=normal", "--", ".",
    });
    return .{ .commit = commit, .dirty = status.len != 0 };
}

fn runGit(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(512 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    std.debug.print("AgentCore manifest: git command failed: {s}\n", .{result.stderr});
    return error.GitCommandFailed;
}

fn writeAtomic(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .replace = true,
        .make_path = true,
    });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, bytes);
    try atomic_file.replace(io);
}

fn isLowerHex(bytes: []const u8) bool {
    for (bytes) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

test "ripgrep pin parses the vendor manifest identity and rejects empty fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pin = try parseRipgrepPin(arena.allocator(),
        \\{"artifacts":[],"bundle_schema":"metacodes.ripgrep-bundle/v1",
        \\ "license":"MIT OR Unlicense","source_repository":"https://github.com/BurntSushi/ripgrep",
        \\ "upstream_release":"14.1.1","upstream_revision":"4649aa9700"}
    );
    try std.testing.expectEqualStrings("14.1.1", pin.upstream_release);
    try std.testing.expectEqualStrings("4649aa9700", pin.upstream_revision);
    try std.testing.expectError(error.InvalidRipgrepPin, parseRipgrepPin(
        arena.allocator(),
        \\{"license":"","source_repository":"x","upstream_release":"y","upstream_revision":"z"}
        ,
    ));
}

test "strict boolean parser" {
    try std.testing.expectEqual(true, parseBool("true").?);
    try std.testing.expectEqual(false, parseBool("false").?);
    try std.testing.expect(parseBool("TRUE") == null);
}

test "package version is derived from sdk version and source identity" {
    const allocator = std.testing.allocator;
    const clean = SourceIdentity{
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .dirty = false,
    };
    const clean_version = try packageVersion(allocator, "0.1.0-dev", clean);
    defer allocator.free(clean_version);
    try std.testing.expectEqualStrings("0.1.0-dev+0123456789ab", clean_version);

    const stable_version = try packageVersion(allocator, "0.1.0", clean);
    defer allocator.free(stable_version);
    try std.testing.expectEqualStrings("0.1.0", stable_version);

    var dirty = clean;
    dirty.dirty = true;
    const dirty_version = try packageVersion(allocator, "0.1.0-dev", dirty);
    defer allocator.free(dirty_version);
    try std.testing.expectEqualStrings("0.1.0-dev+0123456789ab.dirty", dirty_version);
    const dirty_stable_version = try packageVersion(allocator, "0.1.0", dirty);
    defer allocator.free(dirty_stable_version);
    try std.testing.expectEqualStrings("0.1.0", dirty_stable_version);
    try std.testing.expectError(error.InvalidSdkVersion, packageVersion(allocator, "0.1.0+local", clean));
}

test "generated development versions fit the Zig package limit" {
    const allocator = std.testing.allocator;
    const source = SourceIdentity{
        .commit = "0123456789abcdef0123456789abcdef01234567",
        .dirty = true,
    };
    const version = try packageVersion(allocator, "0.1.0-dev", source);
    defer allocator.free(version);
    try std.testing.expect(version.len <= 32);
}

test "Windows ARM64 targets project to supported Rust targets" {
    try std.testing.expectEqualStrings(
        "aarch64-pc-windows-msvc",
        try rustTarget("aarch64", "windows", "msvc"),
    );
    try std.testing.expectEqualStrings(
        "aarch64-pc-windows-gnullvm",
        try rustTarget("aarch64", "windows", "gnu"),
    );
    try std.testing.expectError(
        error.UnsupportedAgentCoreTarget,
        rustTarget("aarch64", "windows", "itanium"),
    );
}
