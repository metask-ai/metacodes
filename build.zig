const std = @import("std");

// 包清单是版本声明的仓库层权威;代码侧唯一拷贝在 src/version.zig。两者一致性由
// runtime_arm_smoke 的 --expected-version 在 `zig build test` 中用真实二进制强制。
const manifest = @import("build.zig.zon");

// highlight-zig 轻量高亮库(Y2:已取代 tree-sitter 做 diff 高亮)。纯 Zig + 嵌入 rules_blob.zlib,
// 零 C 依赖,200+ 语言。作为 git submodule 位于 lib/highlight-zig(独立 repo
// github.com/shuzuan-org/highlight-zig),纯 Zig 模块方式消费其源(每个 root 各按自身
// optimize 编译;未用的 import 零成本)。tree-sitter 已于 2026-07-13 整体移除。
var g_hl_mod: ?*std.Build.Module = null;
fn addHl(b: *std.Build, mod: *std.Build.Module) void {
    addHlWithProjectHarnessActuation(b, mod, false);
}

/// Project-Harness actuation is an artifact property, never a runtime switch.
/// Every ordinary product/test/library root is compiled enforced.  The sole
/// shadow artifact is wired explicitly below and is not part of `install`.
fn addHlWithProjectHarnessActuation(
    b: *std.Build,
    mod: *std.Build.Module,
    evaluation_shadow: bool,
) void {
    if (g_hl_mod == null) {
        g_hl_mod = b.createModule(.{ .root_source_file = b.path("lib/highlight-zig/src/lib.zig") });
    }
    mod.addImport("hl", g_hl_mod.?);
    addPlatform(b, mod); // platform 底座与 hl 同套模块（凡编译 app 代码者都需要）
    const project_harness_options = b.addOptions();
    project_harness_options.addOption(bool, "evaluation_shadow", evaluation_shadow);
    mod.addOptions("project_harness_build_options", project_harness_options);
}

// platform —— 可移植系统抽象层(sync/process/fs/signal/rng/paths)。作为命名模块暴露,
// 让 test:lsp 隔离模块(根在 src/lsp/,无法相对 import 上层 ../platform/)也能用。
var g_platform_mod: ?*std.Build.Module = null;
fn addPlatform(b: *std.Build, mod: *std.Build.Module) void {
    if (g_platform_mod == null) {
        g_platform_mod = b.createModule(.{ .root_source_file = b.path("src/platform/platform.zig") });
    }
    mod.addImport("platform", g_platform_mod.?);
}

/// Every Zig test executable that can run on Windows shares the same legacy
/// `/tmp` compatibility prerequisite. Keep that policy at test-run creation so
/// new isolated suites cannot silently forget it.
fn addTestRunArtifact(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    windows_prelude: ?*std.Build.Step.Run,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(artifact);
    // A test gate must execute on every invocation; a warm build cache may
    // skip recompilation but never test execution. Zig 0.16 re-runs .zig_test
    // steps regardless, but state the doctrine here so a future caching change
    // cannot silently turn cached test binaries into stale green evidence.
    run.has_side_effects = true;
    if (windows_prelude) |prelude| run.step.dependOn(&prelude.step);
    return run;
}

/// A nested `zig build` is part of the caller's build graph, so it must honor
/// the caller-selected local and global caches instead of creating an implicit
/// second cache under the consumer fixture.
fn addNestedBuildCacheArgs(b: *std.Build, run: *std.Build.Step.Run) void {
    run.addArgs(&.{
        "--cache-dir",
        b.cache_root.path orelse ".",
        "--global-cache-dir",
        b.graph.global_cache_root.path orelse ".",
    });
}

const TinyKgBinaryInput = union(enum) {
    disabled,
    unavailable,
    bundled: BundledTinyKg,
    explicit: struct {
        path: []const u8,
        sha256: []const u8,
    },
};

const BundledTinyKg = struct {
    key: []const u8,
    path: []const u8,
    sha256: []const u8,
    target_family: []const u8,
};

fn bundledTinyKgForTarget(target: std.Target) ?BundledTinyKg {
    return switch (target.os.tag) {
        .macos => switch (target.cpu.arch) {
            .aarch64 => .{
                .key = "macos-universal",
                .path = "vendor/tinykg/bin/tinykg-macos-universal",
                .sha256 = "b42b2ba239f161be53dc1cfa49106004f91474be92e6f52e0f02bbd1f53d63af",
                .target_family = "aarch64-macos",
            },
            .x86_64 => .{
                .key = "macos-universal",
                .path = "vendor/tinykg/bin/tinykg-macos-universal",
                .sha256 = "b42b2ba239f161be53dc1cfa49106004f91474be92e6f52e0f02bbd1f53d63af",
                .target_family = "x86_64-macos",
            },
            else => null,
        },
        .linux => switch (target.cpu.arch) {
            .aarch64 => .{
                .key = "linux-aarch64",
                .path = "vendor/tinykg/bin/tinykg-linux-aarch64",
                .sha256 = "9cfe7bf551463068c1bcaa49dea69dce53be6fdf5b9428f39081fcad67e461aa",
                .target_family = "aarch64-linux",
            },
            .x86_64 => .{
                .key = "linux-x86_64",
                .path = "vendor/tinykg/bin/tinykg-linux-x86_64",
                .sha256 = "5288e81890f23abc12b796abf7188202c369c9e4be66df30d3509f740a8424ba",
                .target_family = "x86_64-linux",
            },
            else => null,
        },
        .windows => switch (target.cpu.arch) {
            .x86_64 => .{
                .key = "windows-x86_64",
                .path = "vendor/tinykg/bin/tinykg-windows-x86_64.exe",
                .sha256 = "27f72f74babdcc60c327228673f9eb042092b6c82b156e241c66c0acea081e1b",
                .target_family = "x86_64-windows",
            },
            else => null,
        },
        else => null,
    };
}

fn isLowerSha256(value: []const u8) bool {
    return isLowerHex(value, 64);
}

fn isLowerHex(value: []const u8, len: usize) bool {
    if (value.len != len) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

/// The build identity `metacodes --version` reports (#78): the `build_info`
/// module of the two app modules (not of the library module). Every value is
/// fixed here at configure time from its own source — git, the compiler,
/// `sdk/zig/types.zig`, the vendored manifests, the selected TinyKG input — so
/// the executable never reads the repository at run time to describe itself.
fn buildInfoOptions(
    b: *std.Build,
    target: std.Target,
    /// The optimize mode of the module that receives these options — the
    /// executable's own, not the -Doptimize default (the release app is always
    /// ReleaseSmall, the debug app always Debug).
    optimize: std.builtin.OptimizeMode,
    release_layout: bool,
    tinykg_input: TinyKgBinaryInput,
    identity: GitIdentity,
) *std.Build.Step.Options {
    const sdk_types = @import("sdk/zig/types.zig");
    const ripgrep = ripgrepBundleInfo(b, target);
    const tinykg = tinyKgContractInfo(b);
    const options = b.addOptions();
    options.addOption([]const u8, "commit", identity.commit);
    options.addOption(bool, "dirty", identity.dirty);
    options.addOption([]const u8, "zig_version", @import("builtin").zig_version_string);
    options.addOption([]const u8, "target_triple", b.fmt("{s}-{s}-{s}", .{
        @tagName(target.cpu.arch),
        @tagName(target.os.tag),
        @tagName(target.abi),
    }));
    options.addOption([]const u8, "optimize", @tagName(optimize));
    options.addOption(bool, "release_layout", release_layout);
    options.addOption(u32, "abi_version", sdk_types.ABI_VERSION_V1);
    options.addOption(u32, "abi_revision", sdk_types.ABI_REVISION);
    options.addOption([]const u8, "ripgrep_version", ripgrep.version);
    options.addOption([]const u8, "ripgrep_revision", ripgrep.revision);
    options.addOption(?[]const u8, "ripgrep_expected_sha256", ripgrep.sha256);
    options.addOption([]const u8, "tinykg_version", tinykg.version);
    options.addOption([]const u8, "tinykg_source_commit", tinykg.source_commit);
    options.addOption(?[]const u8, "tinykg_expected_sha256", switch (tinykg_input) {
        .bundled => |input| input.sha256,
        .explicit => |input| input.sha256,
        .disabled, .unavailable => null,
    });
    return options;
}

const GitIdentity = struct { commit: []const u8, dirty: bool };

/// `-Dbuild-commit` names the commit when no repository is available (an
/// exported tree); otherwise git answers for the build root, and a tree
/// without git reports "unknown" rather than failing the build.
fn gitIdentity(b: *std.Build) GitIdentity {
    if (b.option([]const u8, "build-commit", "Commit hash recorded in --version when the tree has no git repository")) |commit| {
        if (!isLowerHex(commit, 40)) @panic("-Dbuild-commit must be 40 lowercase hex characters");
        return .{ .commit = commit, .dirty = false };
    }
    const root = b.pathFromRoot(".");
    const commit = gitStdout(b, &.{ "git", "-C", root, "rev-parse", "HEAD" }) orelse
        return .{ .commit = "unknown", .dirty = false };
    if (!isLowerHex(commit, 40)) return .{ .commit = "unknown", .dirty = false };
    const status = gitStdout(b, &.{ "git", "-C", root, "status", "--porcelain", "--untracked-files=no" }) orelse
        return .{ .commit = commit, .dirty = false };
    return .{ .commit = commit, .dirty = status.len != 0 };
}

fn gitStdout(b: *std.Build, argv: []const []const u8) ?[]const u8 {
    var code: u8 = undefined;
    const raw = b.runAllowFail(argv, &code, .ignore) catch return null;
    return std.mem.trim(u8, raw, " \t\r\n");
}

const RipgrepBundleInfo = struct { version: []const u8, revision: []const u8, sha256: ?[]const u8 };

/// `vendor/ripgrep/manifest.json` names the upstream release and, per target,
/// the vendored binary's digest; a target without one resolves rg from the
/// environment and carries no expectation.
fn ripgrepBundleInfo(b: *std.Build, target: std.Target) RipgrepBundleInfo {
    const Manifest = struct {
        artifacts: []const struct { sha256: []const u8, targets: []const []const u8 },
        upstream_release: []const u8,
        upstream_revision: []const u8,
    };
    const parsed = parseJsonFile(b, Manifest, "vendor/ripgrep/manifest.json");
    const family = b.fmt("{s}-{s}", .{ @tagName(target.cpu.arch), @tagName(target.os.tag) });
    var sha256: ?[]const u8 = null;
    for (parsed.artifacts) |artifact| {
        for (artifact.targets) |candidate| {
            if (std.mem.eql(u8, candidate, family)) sha256 = artifact.sha256;
        }
    }
    return .{ .version = parsed.upstream_release, .revision = parsed.upstream_revision, .sha256 = sha256 };
}

const TinyKgContractInfo = struct { version: []const u8, source_commit: []const u8 };

fn tinyKgContractInfo(b: *std.Build) TinyKgContractInfo {
    const contract = parseJsonFile(b, struct { tinykg_version: []const u8 }, "deps/tinykg.json");
    const bundle = parseJsonFile(b, struct { source_commit: []const u8 }, "vendor/tinykg/manifest.json");
    return .{ .version = contract.tinykg_version, .source_commit = bundle.source_commit };
}

/// Configure-time read of a repository JSON document into `T`; the strings
/// stay alive in the build allocator. Unknown fields are ignored so a manifest
/// can grow without touching the build identity.
fn parseJsonFile(b: *std.Build, comptime T: type, path: []const u8) T {
    const bytes = b.build_root.handle.readFileAlloc(b.graph.io, path, b.allocator, .limited(1024 * 1024)) catch |err|
        std.debug.panic("cannot read {s}: {t}", .{ path, err });
    return std.json.parseFromSliceLeaky(T, b.allocator, bytes, .{ .ignore_unknown_fields = true }) catch |err|
        std.debug.panic("invalid {s}: {t}", .{ path, err });
}

/// TinyKG is an external, manually maintained native artifact. Normal builds
/// select one manifest-pinned repository asset; an explicit override still
/// requires path and operator-observed digest together. Ambient binaries and
/// stale checkouts remain unrepresentable in the build graph.
fn tinyKgBinaryInput(b: *std.Build, target: std.Target) TinyKgBinaryInput {
    const legacy = b.option(bool, "tinykg", "Deprecated compatibility flag; only false is accepted");
    if (legacy == true) @panic("-Dtinykg=true was removed; use -Dtinykg-bin=<absolute path> and -Dtinykg-sha256=<digest>");

    const bundled_option = b.option(bool, "tinykg-bundled", "Install the checked-in target-specific TinyKG binary (default true)");
    if (legacy != null and bundled_option != null) @panic("-Dtinykg and -Dtinykg-bundled cannot be combined");

    const path = b.option([]const u8, "tinykg-bin", "Absolute path to a maintainer-supplied TinyKG override");
    const sha256 = b.option([]const u8, "tinykg-sha256", "Observed SHA-256 of the TinyKG override");
    if (path == null and sha256 == null) {
        const enabled = bundled_option orelse if (legacy) |value| value else true;
        if (!enabled) return .disabled;
        return if (bundledTinyKgForTarget(target)) |bundle| .{ .bundled = bundle } else .unavailable;
    }
    const resolved_path = path orelse @panic("-Dtinykg-bin and -Dtinykg-sha256 must be supplied together");
    const resolved_sha256 = sha256 orelse @panic("-Dtinykg-bin and -Dtinykg-sha256 must be supplied together");
    if (!std.fs.path.isAbsolute(resolved_path)) @panic("-Dtinykg-bin must be an absolute path");
    if (!isLowerSha256(resolved_sha256)) @panic("-Dtinykg-sha256 must be 64 lowercase hex characters");
    return .{ .explicit = .{ .path = resolved_path, .sha256 = resolved_sha256 } };
}

const StagedTinyKg = struct {
    install_step: *std.Build.Step,
    artifact: std.Build.LazyPath,
    installed_path: []const u8,
    source_sha256: []const u8,
};

fn wireTinyKgTestInput(run: *std.Build.Step.Run, staged: ?StagedTinyKg) void {
    const tinykg = staged orelse return;
    run.step.dependOn(tinykg.install_step);
    run.setEnvironmentVariable("METACODES_TEST_TINYKG_BIN", tinykg.installed_path);
}

const aggregate_test_exclusions = [_][]const u8{
    // Has a dedicated ABI artifact/consumer gate with a different module graph.
    "component/agentcore_abi_test.zig",
    // Consumes AgentCore wrapper modules (session_budget/mcp_session/
    // model_skill_tool) through metacodes-core (lib.zig root). The aggregate
    // suite imports cc (main.zig root); one compilation cannot own the same
    // src files under both roots, so this file gets its own module graph.
    "component/tool_dispatcher_metadata_test.zig",
};

fn isAggregateTestExclusion(path: []const u8) bool {
    for (aggregate_test_exclusions) |excluded| {
        if (std.mem.eql(u8, path, excluded)) return true;
    }
    return false;
}

fn countAggregateImport(source: []const u8, expected_line: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), expected_line)) {
            count = std.math.add(usize, count, 1) catch @panic("integration inventory count overflow");
        }
    }
    return count;
}

/// Fail during build-graph construction if a new component/integration test
/// is not wired into the aggregate suite. The old one-artifact-per-file graph
/// discovered new files implicitly; aggregation is much faster, but needs this
/// explicit guard so the speedup can never silently reduce coverage.
fn validateAggregateTestInventory(b: *std.Build) void {
    const suite = b.build_root.handle.readFileAlloc(
        b.graph.io,
        "tests/integration_suite.zig",
        b.allocator,
        .limited(1024 * 1024),
    ) catch |err| std.debug.panic("cannot read aggregate test inventory: {t}", .{err});

    const roots = [_]struct { dir: []const u8, prefix: []const u8 }{
        .{ .dir = "tests/component", .prefix = "component" },
        .{ .dir = "tests/integration", .prefix = "integration" },
    };
    for (roots) |root| {
        var dir = b.build_root.handle.openDir(b.graph.io, root.dir, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| std.debug.panic("cannot scan {s}: {t}", .{ root.dir, err });
        defer dir.close(b.graph.io);
        var walker = dir.walk(b.allocator) catch |err|
            std.debug.panic("cannot walk {s}: {t}", .{ root.dir, err });
        defer walker.deinit();

        while (walker.next(b.graph.io) catch |err|
            std.debug.panic("cannot enumerate {s}: {t}", .{ root.dir, err })) |entry|
        {
            const kind = if (entry.kind == .unknown)
                (entry.dir.statFile(b.graph.io, entry.basename, .{ .follow_symlinks = false }) catch |err|
                    std.debug.panic("cannot stat {s}/{s}: {t}", .{ root.dir, entry.path, err })).kind
            else
                entry.kind;
            if (kind != .file or !std.mem.endsWith(u8, entry.basename, "_test.zig")) continue;
            const path = b.fmt("{s}/{s}", .{ root.prefix, entry.path });
            std.mem.replaceScalar(u8, path, '\\', '/');
            const expected_line = b.fmt("_ = @import(\"{s}\");", .{path});
            const occurrences = countAggregateImport(suite, expected_line);
            if (isAggregateTestExclusion(path)) {
                if (occurrences != 0) std.debug.panic(
                    "dedicated test {s} must not also appear in tests/integration_suite.zig",
                    .{path},
                );
            } else if (occurrences != 1) {
                std.debug.panic(
                    "aggregate test inventory requires exactly one @import for {s}; found {}",
                    .{ path, occurrences },
                );
            }
        }
    }
    for (aggregate_test_exclusions) |excluded| {
        const path = b.fmt("tests/{s}", .{excluded});
        const stat = b.build_root.handle.statFile(b.graph.io, path, .{
            .follow_symlinks = false,
        }) catch |err| std.debug.panic("dedicated test exclusion is missing: {s}: {t}", .{ path, err });
        if (stat.kind != .file) std.debug.panic("dedicated test exclusion is not a regular file: {s}", .{path});
    }
}

fn agentcoreRustTarget(target: std.Target) ?[]const u8 {
    if (target.os.tag == .windows) {
        if (target.cpu.arch == .x86_64) return switch (target.abi) {
            .msvc => "x86_64-pc-windows-msvc",
            .gnu => "x86_64-pc-windows-gnu",
            else => null,
        };
        if (target.cpu.arch == .aarch64) return switch (target.abi) {
            .msvc => "aarch64-pc-windows-msvc",
            .gnu => "aarch64-pc-windows-gnullvm",
            else => null,
        };
    }
    if (target.cpu.arch == .x86_64 and target.os.tag == .linux and target.abi == .gnu)
        return "x86_64-unknown-linux-gnu";
    if (target.cpu.arch == .x86_64 and target.os.tag == .macos) return "x86_64-apple-darwin";
    if (target.cpu.arch == .aarch64 and target.os.tag == .macos) return "aarch64-apple-darwin";
    return null;
}

const AgentCoreAbiModuleOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
    core_mod: *std.Build.Module,
    types_mod: *std.Build.Module,
    protocol_mod: *std.Build.Module,
};

/// Create a fresh AgentCore ABI module for one artifact policy. Tests and the
/// distributable library deliberately use distinct module instances: strip is
/// a delivery concern and must never leak into in-tree test executables.
fn createAgentCoreAbiModule(b: *std.Build, options: AgentCoreAbiModuleOptions) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/agentcore/abi_v1.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .strip = options.strip,
        .link_libc = true,
    });
    addHl(b, mod);
    mod.addImport("metacodes-core", options.core_mod);
    mod.addImport("metask_agentcore_types", options.types_mod);
    mod.addImport("metask_agentcore_protocol", options.protocol_mod);
    if (options.target.result.os.tag == .windows)
        mod.linkSystemLibrary("advapi32", .{ .use_pkg_config = .no });
    if (options.target.result.os.tag == .windows and options.target.result.abi == .msvc)
        mod.addCSourceFile(.{ .file = b.path("src/agentcore/windows_msvc_crt_shims.c"), .flags = &.{"-std=c11"} });
    return mod;
}

pub fn build(b: *std.Build) void {
    validateAggregateTestInventory(b);
    const target = b.standardTargetOptions(.{});
    const target_was_explicit = b.user_input_options.contains("target");
    const optimize = b.standardOptimizeOption(.{});
    // TinyKG source remains outside the Metacodes graph. Normal builds select a
    // checked-in, manifest-pinned target binary. A maintainer may override it
    // with an absolute path plus digest. Native staging validates version and a
    // fresh store; cross staging validates digest, format, arch, and version bytes.
    const tinykg_input = tinyKgBinaryInput(b, target.result);
    const release_layout = b.option(
        bool,
        "release-layout",
        "Record the release runtime layout in the build identity (#47; the layout's asset resolution lands in a later stage)",
    ) orelse false;
    // One options module per app module, because each reports its own
    // optimize mode; git is asked once.
    const build_identity = gitIdentity(b);
    const build_info = buildInfoOptions(b, target.result, .ReleaseSmall, release_layout, tinykg_input, build_identity);
    const debug_build_info = buildInfoOptions(b, target.result, .Debug, release_layout, tinykg_input, build_identity);
    const tfilter = b.option([]const u8, "tfilter", "test filter");
    const lib_test_shards = b.option(u8, "lib-test-shards", "Parallel metacodes-core test shards (1-64)") orelse 4;
    if (lib_test_shards == 0 or lib_test_shards > 64) @panic("-Dlib-test-shards must be between 1 and 64");
    const integration_test_shards = b.option(u8, "integration-test-shards", "Parallel component/integration test shards (1-64)") orelse 8;
    if (integration_test_shards == 0 or integration_test_shards > 64) @panic("-Dintegration-test-shards must be between 1 and 64");
    const agentcore_strip = b.option(bool, "agentcore-strip", "Strip AgentCore library debug information") orelse (optimize != .Debug);

    // Compatibility prelude for the remaining tests that spell temporary
    // paths as `/tmp/...`. On Windows that means `\tmp` at the current drive
    // root. Every Windows test run depends on this host-native step so a fresh
    // machine cannot fail merely because the legacy directory is absent.
    const windows_test_prelude = if (target.result.os.tag == .windows) blk: {
        const prelude_mod = b.createModule(.{
            .root_source_file = b.path("scripts/windows_test_prelude.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        });
        const prelude_exe = b.addExecutable(.{
            .name = "windows-test-prelude",
            .root_module = prelude_mod,
        });
        break :blk b.addRunArtifact(prelude_exe);
    } else null;

    // 固定产出两个二进制：metacodes (ReleaseSmall) 和 metacodes-debug (Debug)。
    // 不受 -Doptimize 影响，一次 build 同时得到发布版和调试版。
    const release_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .link_libc = true,
    });
    addHl(b, release_mod);
    release_mod.addOptions("build_info", build_info);
    const exe = b.addExecutable(.{
        .name = "metacodes",
        .root_module = release_mod,
    });
    b.installArtifact(exe);

    // E3 causal evaluation only: same product root/provider/agent/tool path,
    // but formal blocks are observed rather than actuated.  There is no env or
    // CLI switch and this artifact is deliberately absent from default install.
    const project_harness_shadow_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .link_libc = true,
    });
    addHlWithProjectHarnessActuation(b, project_harness_shadow_mod, true);
    const project_harness_shadow_exe = b.addExecutable(.{
        .name = "metacodes-project-harness-shadow",
        .root_module = project_harness_shadow_mod,
    });
    const install_project_harness_shadow = b.addInstallArtifact(
        project_harness_shadow_exe,
        .{ .dest_dir = .{ .override = .{ .custom = "eval/bin" } } },
    );
    const project_harness_shadow_step = b.step(
        "eval:project-harness-shadow",
        "Build the compile-time-bound E3 shadow app (not a production install artifact)",
    );
    project_harness_shadow_step.dependOn(&install_project_harness_shadow.step);

    var staged_tinykg: ?StagedTinyKg = null;
    const tinykg_stage_step = b.step("tinykg:stage", "Validate and install the selected TinyKG binary");
    switch (tinykg_input) {
        .disabled => tinykg_stage_step.dependOn(&b.addFail(
            "tinykg:stage is disabled by -Dtinykg-bundled=false or legacy -Dtinykg=false",
        ).step),
        .unavailable => tinykg_stage_step.dependOn(&b.addFail(
            "the checked-in TinyKG bundle does not support this target; use a native explicit -Dtinykg-bin/-Dtinykg-sha256 override",
        ).step),
        .bundled => |input| {
            const python = if (@import("builtin").os.tag == .windows) "python" else "python3";
            const stage = b.addSystemCommand(&.{ python, "scripts/stage_tinykg_binary.py", "bundled", "--binary" });
            stage.addFileArg(b.path(input.path));
            stage.addArgs(&.{"--manifest"});
            stage.addFileArg(b.path("vendor/tinykg/manifest.json"));
            stage.addArgs(&.{
                "--bundle-key",
                input.key,
                "--expected-sha256",
                input.sha256,
                "--target-family",
                input.target_family,
            });
            const host_bundle = bundledTinyKgForTarget(b.graph.host.result);
            if (host_bundle != null and std.mem.eql(u8, host_bundle.?.key, input.key)) {
                stage.addArg("--runtime-probe");
            }
            stage.addArgs(&.{"--contract"});
            stage.addFileArg(b.path("deps/tinykg.json"));
            stage.addArgs(&.{
                "--target",
                target.result.zigTriple(b.allocator) catch @panic("OOM"),
                "--output",
            });
            const bin_name = if (target.result.os.tag == .windows) "tinykg.exe" else "tinykg";
            const staged_binary = stage.addOutputFileArg(bin_name);
            stage.addArg("--receipt");
            const staged_receipt = stage.addOutputFileArg("tinykg.provenance.json");
            const install_binary = b.addInstallFileWithDir(
                staged_binary,
                .{ .custom = "vendor/tinykg" },
                bin_name,
            );
            const install_receipt = b.addInstallFileWithDir(
                staged_receipt,
                .{ .custom = "vendor/tinykg" },
                "tinykg.provenance.json",
            );
            b.getInstallStep().dependOn(&install_binary.step);
            b.getInstallStep().dependOn(&install_receipt.step);
            tinykg_stage_step.dependOn(&install_binary.step);
            tinykg_stage_step.dependOn(&install_receipt.step);
            staged_tinykg = .{
                .install_step = &install_binary.step,
                .artifact = staged_binary,
                .installed_path = b.getInstallPath(.{ .custom = "vendor/tinykg" }, bin_name),
                .source_sha256 = input.sha256,
            };
        },
        .explicit => |input| {
            if (target.result.os.tag != b.graph.host.result.os.tag or
                target.result.cpu.arch != b.graph.host.result.cpu.arch or
                target.result.abi != b.graph.host.result.abi)
            {
                @panic("a TinyKG binary can only be staged on its native target runner");
            }
            const python = if (@import("builtin").os.tag == .windows) "python" else "python3";
            const stage = b.addSystemCommand(&.{ python, "scripts/stage_tinykg_binary.py", "explicit", "--binary" });
            stage.addFileArg(.{ .cwd_relative = input.path });
            stage.addArgs(&.{ "--expected-sha256", input.sha256, "--contract" });
            stage.addFileArg(b.path("deps/tinykg.json"));
            stage.addArgs(&.{
                "--target",
                target.result.zigTriple(b.allocator) catch @panic("OOM"),
                "--output",
            });
            const bin_name = if (target.result.os.tag == .windows) "tinykg.exe" else "tinykg";
            const staged_binary = stage.addOutputFileArg(bin_name);
            stage.addArg("--receipt");
            const staged_receipt = stage.addOutputFileArg("tinykg.provenance.json");
            const install_binary = b.addInstallFileWithDir(
                staged_binary,
                .{ .custom = "vendor/tinykg" },
                bin_name,
            );
            const install_receipt = b.addInstallFileWithDir(
                staged_receipt,
                .{ .custom = "vendor/tinykg" },
                "tinykg.provenance.json",
            );
            b.getInstallStep().dependOn(&install_binary.step);
            b.getInstallStep().dependOn(&install_receipt.step);
            tinykg_stage_step.dependOn(&install_binary.step);
            tinykg_stage_step.dependOn(&install_receipt.step);
            staged_tinykg = .{
                .install_step = &install_binary.step,
                .artifact = staged_binary,
                .installed_path = b.getInstallPath(.{ .custom = "vendor/tinykg" }, bin_name),
                .source_sha256 = input.sha256,
            };
        },
    }

    // ── ripgrep for the product install (#79, #47 stage 4) ─────────────────
    // Glob/Grep need rg at run time. The default install and the release
    // layout stage the vendored, manifest-pinned binary beside the executable
    // as bin/rg[.exe] (the script the AgentCore bundle already uses) and ship
    // its MIT notice under share/licenses. A target without a vendored rg
    // (aarch64-linux until #86) still builds for development — rg then comes
    // from PATH — but cannot be released: `release:stage` fails closed rather
    // than shipping an executable whose Grep cannot run.
    const ripgrep_bundle = ripgrepBundleInfo(b, target.result);
    const release_stage_step = b.step(
        "release:stage",
        "Install the release layout (bin/metacodes, bin/rg, vendor/tinykg, share/licenses); requires -Drelease-layout=true and fails closed for a target without vendored runtime assets",
    );
    release_stage_step.dependOn(b.getInstallStep());
    if (!release_layout) {
        release_stage_step.dependOn(&b.addFail(
            "release:stage requires -Drelease-layout=true so the executable resolves rg beside itself",
        ).step);
    }
    if (staged_tinykg == null) {
        release_stage_step.dependOn(&b.addFail(
            "release:stage needs the vendored TinyKG binary for this target (it is disabled or unavailable)",
        ).step);
    }
    const target_family = b.fmt("{s}-{s}", .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag) });
    if (ripgrep_bundle.sha256 != null) {
        const stage_python = if (@import("builtin").os.tag == .windows) "python" else "python3";
        const stage_ripgrep = b.addSystemCommand(&.{
            stage_python,
            "scripts/stage_ripgrep_binary.py",
            @tagName(target.result.cpu.arch),
            @tagName(target.result.os.tag),
            b.getInstallPath(.bin, ""),
        });
        stage_ripgrep.setCwd(b.path("."));
        const install_ripgrep_license = b.addInstallFileWithDir(
            b.path("vendor/ripgrep/LICENSE-MIT"),
            .{ .custom = "share/licenses" },
            "ripgrep-LICENSE-MIT",
        );
        b.getInstallStep().dependOn(&stage_ripgrep.step);
        b.getInstallStep().dependOn(&install_ripgrep_license.step);
        // The release unit also carries its own licence, TinyKG's, the
        // rendered notices and the operator docs (release/LAYOUT.md, #80);
        // a development install does not.
        const release_extras = [_]struct { source: []const u8, dir: []const u8, name: []const u8 }{
            .{ .source = "LICENSE", .dir = "share/licenses", .name = "metacodes-LICENSE" },
            .{ .source = "vendor/tinykg/LICENSE", .dir = "share/licenses", .name = "tinykg-LICENSE" },
            .{ .source = "THIRD_PARTY_NOTICES.md", .dir = "share/licenses", .name = "THIRD_PARTY_NOTICES.md" },
            .{ .source = "README.md", .dir = "share/doc", .name = "README.md" },
            .{ .source = "CHANGELOG.md", .dir = "share/doc", .name = b.fmt("CHANGELOG-{s}.md", .{manifest.version}) },
        };
        for (release_extras) |extra| {
            const install_extra = b.addInstallFileWithDir(b.path(extra.source), .{ .custom = extra.dir }, extra.name);
            release_stage_step.dependOn(&install_extra.step);
        }
    } else {
        std.log.warn(
            "no vendored ripgrep for {s}: the install carries no bin/rg and Grep/Glob resolve it from PATH (#86)",
            .{target_family},
        );
        release_stage_step.dependOn(&b.addFail(b.fmt(
            "no vendored ripgrep for {s}; this target is outside the release matrix until #86",
            .{target_family},
        )).step);
    }

    const debug_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    addHl(b, debug_mod);
    debug_mod.addOptions("build_info", debug_build_info);
    const debug_exe = b.addExecutable(.{
        .name = "metacodes-debug",
        .root_module = debug_mod,
    });
    const install_debug = b.addInstallArtifact(debug_exe, .{});
    const dev_step = b.step("dev", "Install only the runnable Debug app (fast edit loop)");
    dev_step.dependOn(&install_debug.step);
    const dev_full_step = b.step("dev:full", "Install the Debug app and selected TinyKG binary");
    dev_full_step.dependOn(&install_debug.step);
    dev_full_step.dependOn(tinykg_stage_step);

    // ── 共享测试模块────────────────────────────────────────────────────────
    // cc(全 src 树)与 harness(mock SSE server)被单测/spike/integ/new/mem/agentcore/
    // replay 多处消费,收敛为单例(platform/hl 全局单例是既有同款)。诚实注解(review-2
    // F10):共享的是模块**描述**而非编译产物——每个测试二进制仍各自分析/编译整棵依赖树,
    // 收益是砍掉模块图重复节点与配置漂移面;并发内存压力靠 -j 上限控制(满核 28 路 LLVM
    // 链接在 32GB 上实测 OOM,win_verify.sh 用 -j12,全量 ≈200s)。optimize==Debug 时 cc
    // 复用 debug_mod(少一个模块实例,非少一次编译)。
    const test_cc_mod = if (optimize == .Debug) debug_mod else blk: {
        const m2 = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        addHl(b, m2);
        m2.addOptions("build_info", buildInfoOptions(b, target.result, optimize, release_layout, tinykg_input, build_identity));
        break :blk m2;
    };
    const test_harness_mod = b.createModule(.{
        .root_source_file = b.path("tests/_harness/mock_sse_server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addPlatform(b, test_harness_mod); // harness socket 层走 platform/net(POSIX+Winsock 双后端)

    // mock MCP server 二进制：测试专用，只装这个 artifact 即可运行 aggregate
    // integration；测试不应依赖全局 install step，否则会顺带冷编译 release/debug/replay。
    const mock_mcp_mod = b.createModule(.{
        .root_source_file = b.path("tests/_harness/mock_mcp_server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addPlatform(b, mock_mcp_mod); // stdin/stdout 走可移植 pfs
    const mock_mcp_exe = b.addExecutable(.{
        .name = "mock_mcp_server",
        .root_module = mock_mcp_mod,
    });
    const install_mock_mcp = b.addInstallArtifact(mock_mcp_exe, .{});

    // replay_server 二进制(Stage 7):从 cassette 起 mock,供 e2e replay。测试专用。
    // 三端可编:曾经的三个 Windows blocker 已清(socket server→platform/net、
    // args→iterateAllocator、cassette 文件 IO→pfs)。TTY ui_tools 用例依赖它。
    const replay_mod = b.createModule(.{
        .root_source_file = b.path("tests/_harness/replay_server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    replay_mod.addImport("harness", test_harness_mod); // 共享模块(perf,见上)
    const replay_cassette_mod = b.createModule(.{
        .root_source_file = b.path("tests/_harness/cassette.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addPlatform(b, replay_cassette_mod); // 文件 IO 走 pfs
    replay_mod.addImport("cassette", replay_cassette_mod);
    addPlatform(b, replay_mod); // stdout/stderr 走可移植 pfs
    const replay_exe = b.addExecutable(.{
        .name = "replay_server",
        .root_module = replay_mod,
    });
    const install_replay = b.addInstallArtifact(replay_exe, .{});
    const test_harness_step = b.step("test:harness", "Install the test harness binaries: mock_mcp_server and replay_server");
    test_harness_step.dependOn(&install_mock_mcp.step);
    test_harness_step.dependOn(&install_replay.step);

    // ── metacodes-core 可复用库 module(root=src/lib.zig,UI 图不可达)──────────
    // 供其他 Zig 项目经 build.zig.zon 依赖 `@import("metacodes-core")`。
    // 经 tools/* 用 highlight-zig 高亮 module → 必须 addHl。
    const core_mod = b.addModule("metacodes-core", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addHl(b, core_mod);

    // HTTP status is an open wire value. This host-native syntax gate keeps the
    // std.http.Status interpretation authority in src/api/http_status.zig.
    const http_status_gate_mod = b.createModule(.{
        .root_source_file = b.path("scripts/http_status_boundary_gate.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const http_status_gate_exe = b.addExecutable(.{
        .name = "http-status-boundary-gate",
        .root_module = http_status_gate_mod,
    });
    const http_status_gate_run = b.addRunArtifact(http_status_gate_exe);
    http_status_gate_run.setCwd(b.path("."));
    http_status_gate_run.addArg(".");
    const http_status_gate_unit = b.addTest(.{
        .name = "http-status-boundary-gate-unit",
        .root_module = http_status_gate_mod,
    });
    const http_status_gate_step = b.step(
        "http-status:gate",
        "Enforce the unique HTTP response status boundary",
    );
    http_status_gate_step.dependOn(&http_status_gate_run.step);
    http_status_gate_step.dependOn(&addTestRunArtifact(b, http_status_gate_unit, windows_test_prelude).step);

    // One-shot paid feasibility probe for the isolated rule-author adapter.
    // It is intentionally absent from the default install graph; the Python
    // budget runner builds it before acquiring durable request authorization.
    const rule_author_trial_mod = b.createModule(.{
        .root_source_file = b.path("scripts/eval/rule_author_feasibility.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    rule_author_trial_mod.addImport("metacodes-core", core_mod);
    addPlatform(b, rule_author_trial_mod);
    const rule_author_trial_exe = b.addExecutable(.{
        .name = "rule-author-feasibility",
        .root_module = rule_author_trial_mod,
    });
    const install_rule_author_trial = b.addInstallArtifact(rule_author_trial_exe, .{});
    const rule_author_trial_step = b.step(
        "eval:rule-author-build",
        "Build the isolated rule-author feasibility probe (no provider call)",
    );
    rule_author_trial_step.dependOn(&install_rule_author_trial.step);

    // Host-native, zero-paid vertical slice. The Python parent supplies only
    // loopback services; the Zig child starts at the production KgClient
    // daemon-config boundary and completes ontology snapshot -> rule author ->
    // source re-observation -> candidate binding verification.
    const project_rule_mac_pilot_mod = b.createModule(.{
        .root_source_file = b.path("scripts/eval/project_rule_evolution_mac_pilot.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    project_rule_mac_pilot_mod.addImport("metacodes-core", core_mod);
    addPlatform(b, project_rule_mac_pilot_mod);
    const project_rule_mac_pilot_exe = b.addExecutable(.{
        .name = "metacodes-project-rule-evolution-mac-pilot",
        .root_module = project_rule_mac_pilot_mod,
    });
    const project_rule_mac_pilot_run = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "scripts/eval/run_project_rule_evolution_mac_pilot.py",
        "--probe",
    });
    project_rule_mac_pilot_run.addArtifactArg(project_rule_mac_pilot_exe);
    const project_rule_mac_pilot_step = b.step(
        "eval:project-rule-mac-pilot",
        "Run the zero-paid Mac TinyKG-daemon to governed-rule host chain",
    );
    project_rule_mac_pilot_step.dependOn(&project_rule_mac_pilot_run.step);

    const agentcore_types_mod = b.createModule(.{
        .root_source_file = b.path("sdk/zig/types.zig"),
        .target = target,
        .optimize = optimize,
    });
    const agentcore_protocol_mod = b.createModule(.{
        .root_source_file = b.path("sdk/zig/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const agentcore_sdk_mod = b.createModule(.{
        .root_source_file = b.path("sdk/zig/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    agentcore_sdk_mod.addImport("metask_agentcore_types", agentcore_types_mod);
    agentcore_sdk_mod.addImport("metask_agentcore_protocol", agentcore_protocol_mod);
    const agentcore_abi_test_mod = createAgentCoreAbiModule(b, .{
        .target = target,
        .optimize = optimize,
        .strip = false,
        .core_mod = core_mod,
        .types_mod = agentcore_types_mod,
        .protocol_mod = agentcore_protocol_mod,
    });
    const agentcore_abi_bundle_mod = createAgentCoreAbiModule(b, .{
        .target = target,
        .optimize = optimize,
        .strip = agentcore_strip,
        .core_mod = core_mod,
        .types_mod = agentcore_types_mod,
        .protocol_mod = agentcore_protocol_mod,
    });

    const agentcore_test_step = b.step("agentcore:test", "Run AgentCore binary ABI v1 tests");
    agentcore_test_step.dependOn(http_status_gate_step);
    const agentcore_abi_test = b.addTest(.{
        .name = "agentcore-abi-unit",
        .root_module = agentcore_abi_test_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    agentcore_test_step.dependOn(&addTestRunArtifact(b, agentcore_abi_test, windows_test_prelude).step);
    const agentcore_types_test = b.addTest(.{
        .name = "agentcore-types-unit",
        .root_module = agentcore_types_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    agentcore_test_step.dependOn(&addTestRunArtifact(b, agentcore_types_test, windows_test_prelude).step);
    const agentcore_protocol_test = b.addTest(.{
        .name = "agentcore-protocol-unit",
        .root_module = agentcore_protocol_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    agentcore_test_step.dependOn(&addTestRunArtifact(b, agentcore_protocol_test, windows_test_prelude).step);
    const agentcore_sdk_test = b.addTest(.{
        .name = "agentcore-sdk-unit",
        .root_module = agentcore_sdk_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    agentcore_test_step.dependOn(&addTestRunArtifact(b, agentcore_sdk_test, windows_test_prelude).step);
    const agentcore_zig_package_build_test_mod = b.createModule(.{
        .root_source_file = b.path("sdk/zig/build.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const agentcore_zig_package_build_test = b.addTest(.{
        .name = "agentcore-zig-package-build-unit",
        .root_module = agentcore_zig_package_build_test_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    agentcore_test_step.dependOn(&addTestRunArtifact(b, agentcore_zig_package_build_test, windows_test_prelude).step);
    const agentcore_manifest_contract_mod = b.createModule(.{
        .root_source_file = b.path("tests/agentcore_artifact_consumer/manifest_contract.zig"),
        .target = target,
        .optimize = optimize,
    });
    const agentcore_manifest_contract_test = b.addTest(.{
        .name = "agentcore-manifest-contract",
        .root_module = agentcore_manifest_contract_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    agentcore_test_step.dependOn(&addTestRunArtifact(b, agentcore_manifest_contract_test, windows_test_prelude).step);
    const agentcore_manifest_tool_mod = b.createModule(.{
        .root_source_file = b.path("scripts/agentcore_manifest.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const agentcore_manifest_types_mod = b.createModule(.{
        .root_source_file = b.path("sdk/zig/types.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    agentcore_manifest_tool_mod.addImport("metask_agentcore_types", agentcore_manifest_types_mod);
    const agentcore_manifest_tool = b.addExecutable(.{
        .name = "agentcore-manifest",
        .root_module = agentcore_manifest_tool_mod,
    });
    const agentcore_manifest_tool_test = b.addTest(.{
        .name = "agentcore-manifest-unit",
        .root_module = agentcore_manifest_tool_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    agentcore_test_step.dependOn(&addTestRunArtifact(b, agentcore_manifest_tool_test, windows_test_prelude).step);

    // ── release:manifest / release:check / release:verify (#80, #47 stage 5) ──
    // The CLI release unit is the staged prefix sealed with manifest.json
    // (release/LAYOUT.md). The generator is a host tool beside the AgentCore
    // one; release/manifest_contract.zig is the reader's side of the contract;
    // scripts/verify_release_bundle.py runs the fail-closed checks, the
    // executable-running ones only on the native target.
    const release_contract_mod = b.createModule(.{
        .root_source_file = b.path("src/release_contract.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const release_manifest_tool_mod = b.createModule(.{
        .root_source_file = b.path("scripts/release_manifest.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    release_manifest_tool_mod.addImport("metask_agentcore_types", agentcore_manifest_types_mod);
    release_manifest_tool_mod.addImport("metacodes_release_contract", release_contract_mod);
    const release_manifest_tool = b.addExecutable(.{
        .name = "release-manifest",
        .root_module = release_manifest_tool_mod,
    });
    const release_manifest_tool_test = b.addTest(.{
        .name = "release-manifest-unit",
        .root_module = release_manifest_tool_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    const manifest_common_test = b.addTest(.{
        .name = "manifest-common-unit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/manifest_common.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    const release_contract_test = b.addTest(.{
        .name = "release-manifest-contract",
        .root_module = b.createModule(.{
            .root_source_file = b.path("release/manifest_contract.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    const release_test_step = b.step("release:test", "Unit tests of the release manifest generator and contract");
    release_test_step.dependOn(&addTestRunArtifact(b, release_manifest_tool_test, windows_test_prelude).step);
    release_test_step.dependOn(&addTestRunArtifact(b, manifest_common_test, windows_test_prelude).step);
    release_test_step.dependOn(&addTestRunArtifact(b, release_contract_test, windows_test_prelude).step);

    const release_manifest_cmd = b.addRunArtifact(release_manifest_tool);
    release_manifest_cmd.addArgs(&.{
        b.install_path,
        b.fmt("{s}-{s}-{s}", .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag), @tagName(target.result.abi) }),
        @tagName(target.result.cpu.arch),
        @tagName(target.result.os.tag),
        @tagName(target.result.abi),
        @tagName(release_mod.optimize orelse optimize),
        if (release_mod.strip orelse false) "true" else "false",
        manifest.version,
    });
    release_manifest_cmd.setCwd(b.path("."));
    release_manifest_cmd.has_side_effects = true;
    release_manifest_cmd.step.dependOn(release_stage_step);
    const release_manifest_step = b.step("release:manifest", "Write manifest.json for the staged release prefix (after release:stage)");
    release_manifest_step.dependOn(&release_manifest_cmd.step);

    const release_python = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const release_check_cmd = b.addSystemCommand(&.{ release_python, "scripts/verify_release_bundle.py", b.install_path });
    release_check_cmd.setCwd(b.path("."));
    release_check_cmd.has_side_effects = true;
    release_check_cmd.step.dependOn(&release_manifest_cmd.step);
    const release_check_step = b.step("release:check", "Static release checks: schema, digests, whitelist, licences (any target)");
    release_check_step.dependOn(&release_check_cmd.step);

    const release_verify_step = b.step("release:verify", "release:check plus the executable-running checks (native target only)");
    const release_target_is_native = target.result.os.tag == b.graph.host.result.os.tag and
        target.result.cpu.arch == b.graph.host.result.cpu.arch and
        target.result.abi == b.graph.host.result.abi;
    if (release_target_is_native) {
        const release_verify_cmd = b.addSystemCommand(&.{ release_python, "scripts/verify_release_bundle.py", b.install_path, "--native" });
        release_verify_cmd.setCwd(b.path("."));
        release_verify_cmd.has_side_effects = true;
        release_verify_cmd.step.dependOn(&release_manifest_cmd.step);
        release_verify_step.dependOn(&release_verify_cmd.step);
    } else {
        release_verify_step.dependOn(&b.addFail("use release:check for cross-target validation").step);
    }
    const agentcore_symbol_gate_mod = b.createModule(.{
        .root_source_file = b.path("scripts/agentcore_symbol_gate.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const agentcore_symbol_gate_tool = b.addExecutable(.{
        .name = "agentcore-symbol-gate",
        .root_module = agentcore_symbol_gate_mod,
    });
    const agentcore_symbol_gate_test = b.addTest(.{
        .name = "agentcore-symbol-gate-unit",
        .root_module = agentcore_symbol_gate_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    agentcore_test_step.dependOn(&addTestRunArtifact(b, agentcore_symbol_gate_test, windows_test_prelude).step);
    // header 可编译性检查:走 zig 构建系统原生 C 对象(不 install,只编译)。
    // 不用系统 cc(Windows 没有),也不用 `zig cc -fsyntax-only`(zig 0.16 Windows 实测
    // 对任何输入报 FileNotFound;`-c` 正常)。对象编译 = 语法+类型检查,跨平台等价。
    const agentcore_header_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agentcore_header_mod.addCSourceFile(.{
        .file = b.path("tests/agentcore_header_compile.c"),
        .flags = &.{"-std=c11"},
    });
    agentcore_header_mod.addIncludePath(b.path("sdk"));
    const agentcore_header_obj = b.addObject(.{ .name = "agentcore-header-compile", .root_module = agentcore_header_mod });
    agentcore_test_step.dependOn(&agentcore_header_obj.step);
    const agentcore_cpp_header_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agentcore_cpp_header_mod.addCSourceFile(.{
        .file = b.path("tests/agentcore_artifact_consumer/link_probe.cpp"),
        .flags = &.{"-std=c++17"},
    });
    agentcore_cpp_header_mod.addIncludePath(b.path("sdk"));
    const agentcore_cpp_header_obj = b.addObject(.{ .name = "agentcore-cpp-header-compile", .root_module = agentcore_cpp_header_mod });
    agentcore_test_step.dependOn(&agentcore_cpp_header_obj.step);
    const agentcore_contract_mod = b.createModule(.{
        .root_source_file = b.path("tests/component/agentcore_abi_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agentcore_contract_mod.addImport("harness", test_harness_mod); // 共享模块(perf,见 debug exe 后注释)
    agentcore_contract_mod.addImport("agentcore-abi", agentcore_abi_test_mod);
    agentcore_contract_mod.addImport("agentcore-sdk", agentcore_sdk_mod);
    agentcore_contract_mod.addImport("metacodes-core", core_mod);
    addPlatform(b, agentcore_contract_mod);
    const agentcore_contract_test = b.addTest(.{
        .name = "agentcore-abi-contract",
        .root_module = agentcore_contract_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    agentcore_test_step.dependOn(&addTestRunArtifact(b, agentcore_contract_test, windows_test_prelude).step);

    const agentcore_lib = b.addLibrary(.{
        .name = "metask_agentcore",
        .linkage = .static,
        .root_module = agentcore_abi_bundle_mod,
    });
    // Non-Zig consumers do not implicitly link Zig's compiler_rt builtins.
    agentcore_lib.bundle_compiler_rt = true;
    const agentcore_symbol_gate_cmd = b.addRunArtifact(agentcore_symbol_gate_tool);
    agentcore_symbol_gate_cmd.addFileArg(agentcore_lib.getEmittedBin());
    agentcore_test_step.dependOn(&agentcore_symbol_gate_cmd.step);
    const resolved_agentcore_target = target.result.zigTriple(b.allocator) catch @panic("OOM");
    const agentcore_architecture = @tagName(target.result.cpu.arch);
    const agentcore_os = @tagName(target.result.os.tag);
    const agentcore_abi = @tagName(target.result.abi);
    const agentcore_library_file = agentcore_lib.out_filename;
    const agentcore_bundle_rel = b.fmt("agentcore/{s}", .{resolved_agentcore_target});
    const agentcore_lib_rel = b.fmt("{s}/lib", .{agentcore_bundle_rel});
    const agentcore_install_root = b.getInstallPath(.prefix, agentcore_bundle_rel);
    const agentcore_install_root_abs = b.pathFromRoot(agentcore_install_root);
    const install_agentcore_lib = b.addInstallArtifact(agentcore_lib, .{
        .dest_dir = .{ .override = .{ .custom = agentcore_lib_rel } },
    });
    const installed_agentcore_library = b.fmt(
        "{s}/lib/{s}",
        .{ agentcore_install_root, agentcore_library_file },
    );
    var installed_agentcore_lib_ready: *std.Build.Step = &install_agentcore_lib.step;
    if (target.result.os.tag == .macos) {
        if (b.graph.host.result.os.tag != .macos) {
            installed_agentcore_lib_ready = &b.addFail(
                "AgentCore macOS archives require Apple ar/libtool repacking on a macOS build host",
            ).step;
        } else {
            const repack_agentcore_archive = b.addSystemCommand(&.{
                "sh",
                "scripts/repack_agentcore_macos_archive.sh",
                installed_agentcore_library,
            });
            repack_agentcore_archive.setCwd(b.path("."));
            repack_agentcore_archive.step.dependOn(&install_agentcore_lib.step);
            const installed_symbol_gate = b.addRunArtifact(agentcore_symbol_gate_tool);
            installed_symbol_gate.addArg(installed_agentcore_library);
            installed_symbol_gate.step.dependOn(&repack_agentcore_archive.step);
            installed_agentcore_lib_ready = &installed_symbol_gate.step;
        }
    }
    const install_agentcore_header = b.addInstallFileWithDir(
        b.path("sdk/metask/agentcore.h"),
        .prefix,
        b.fmt("{s}/include/metask/agentcore.h", .{agentcore_bundle_rel}),
    );
    const install_agentcore_sdk = b.addInstallFileWithDir(
        b.path("sdk/zig/root.zig"),
        .prefix,
        b.fmt("{s}/bindings/zig/src/root.zig", .{agentcore_bundle_rel}),
    );
    const install_agentcore_protocol = b.addInstallFileWithDir(
        b.path("sdk/zig/protocol.zig"),
        .prefix,
        b.fmt("{s}/bindings/zig/src/protocol.zig", .{agentcore_bundle_rel}),
    );
    const install_agentcore_types = b.addInstallFileWithDir(
        b.path("sdk/zig/types.zig"),
        .prefix,
        b.fmt("{s}/bindings/zig/src/types.zig", .{agentcore_bundle_rel}),
    );
    const install_agentcore_zig_build = b.addInstallFileWithDir(
        b.path("sdk/zig/build.zig"),
        .prefix,
        b.fmt("{s}/bindings/zig/build.zig", .{agentcore_bundle_rel}),
    );
    const install_agentcore_rust_build = b.addInstallFileWithDir(
        b.path("sdk/rust/build.rs"),
        .prefix,
        b.fmt("{s}/bindings/rust/build.rs", .{agentcore_bundle_rel}),
    );
    const install_agentcore_rust_lib = b.addInstallFileWithDir(
        b.path("sdk/rust/src/lib.rs"),
        .prefix,
        b.fmt("{s}/bindings/rust/src/lib.rs", .{agentcore_bundle_rel}),
    );
    const install_agentcore_rust_raw = b.addInstallFileWithDir(
        b.path("sdk/rust/src/raw.rs"),
        .prefix,
        b.fmt("{s}/bindings/rust/src/raw.rs", .{agentcore_bundle_rel}),
    );
    const install_agentcore_rust_link_probe = b.addInstallFileWithDir(
        b.path("sdk/rust/examples/link_probe.rs"),
        .prefix,
        b.fmt("{s}/bindings/rust/examples/link_probe.rs", .{agentcore_bundle_rel}),
    );
    // rg 是再分发的 MIT OR Unlicense 上游二进制:许可文本随资产同行。
    const install_agentcore_ripgrep_license = b.addInstallFileWithDir(
        b.path("vendor/ripgrep/LICENSE-MIT"),
        .prefix,
        b.fmt("{s}/bin/ripgrep-LICENSE-MIT", .{agentcore_bundle_rel}),
    );
    // Glob/Grep 的运行期依赖随包分发:按 target 从 vendor/ripgrep manifest 选
    // 二进制,SHA-256 校验后 staging 为 bundle 内 bin/rg[.exe],再进 manifest
    // 的 files allowlist 与 runtime_assets 声明。无对应 vendored 二进制的
    // target 在此 fail-closed,而不是发一个 Glob/Grep 无法执行的 bundle。
    const agentcore_stage_python = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const stage_agentcore_ripgrep = b.addSystemCommand(&.{
        agentcore_stage_python,
        "scripts/stage_ripgrep_binary.py",
        agentcore_architecture,
        agentcore_os,
        b.getInstallPath(.prefix, b.fmt("{s}/bin", .{agentcore_bundle_rel})),
    });
    stage_agentcore_ripgrep.setCwd(b.path("."));
    const missing_agentcore_target = if (target_was_explicit)
        null
    else
        b.addFail("AgentCore bundle requires explicit -Dtarget=<triple>");
    const manifest_cmd = b.addRunArtifact(agentcore_manifest_tool);
    manifest_cmd.addArgs(&.{
        agentcore_install_root,
        resolved_agentcore_target,
        agentcore_architecture,
        agentcore_os,
        agentcore_abi,
        @tagName(optimize),
        if (agentcore_strip) "true" else "false",
        agentcore_library_file,
    });
    manifest_cmd.setCwd(b.path("."));
    if (missing_agentcore_target) |failure| manifest_cmd.step.dependOn(&failure.step);
    manifest_cmd.step.dependOn(&agentcore_symbol_gate_cmd.step);
    manifest_cmd.step.dependOn(installed_agentcore_lib_ready);
    manifest_cmd.step.dependOn(&install_agentcore_header.step);
    manifest_cmd.step.dependOn(&install_agentcore_sdk.step);
    manifest_cmd.step.dependOn(&install_agentcore_protocol.step);
    manifest_cmd.step.dependOn(&install_agentcore_types.step);
    manifest_cmd.step.dependOn(&install_agentcore_zig_build.step);
    manifest_cmd.step.dependOn(&install_agentcore_rust_build.step);
    manifest_cmd.step.dependOn(&install_agentcore_rust_lib.step);
    manifest_cmd.step.dependOn(&install_agentcore_rust_raw.step);
    manifest_cmd.step.dependOn(&install_agentcore_rust_link_probe.step);
    manifest_cmd.step.dependOn(&stage_agentcore_ripgrep.step);
    manifest_cmd.step.dependOn(&install_agentcore_ripgrep_license.step);
    const consumer_link_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    addNestedBuildCacheArgs(b, consumer_link_cmd);
    consumer_link_cmd.addArgs(&.{
        "--build-file",
        "tests/agentcore_artifact_consumer/build.zig",
        "link",
        b.fmt("-Doptimize={s}", .{@tagName(optimize)}),
        b.fmt("-Dtarget={s}", .{resolved_agentcore_target}),
        b.fmt("-Dbundle-root={s}", .{agentcore_install_root}),
        b.fmt("-Dlibrary-file={s}", .{agentcore_library_file}),
        b.fmt("-Dexpected-strip={s}", .{if (agentcore_strip) "true" else "false"}),
    });
    consumer_link_cmd.setCwd(b.path("."));
    consumer_link_cmd.step.dependOn(&manifest_cmd.step);
    const zig_package_check_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    addNestedBuildCacheArgs(b, zig_package_check_cmd);
    zig_package_check_cmd.addArgs(&.{
        "--build-file",
        b.fmt("{s}/bindings/zig/build.zig", .{agentcore_install_root}),
        "check",
        b.fmt("-Doptimize={s}", .{@tagName(optimize)}),
        b.fmt("-Dtarget={s}", .{resolved_agentcore_target}),
    });
    zig_package_check_cmd.setCwd(b.path("."));
    zig_package_check_cmd.step.dependOn(&manifest_cmd.step);
    const agentcore_rust_step = b.step("agentcore:rust", "Build the bundled metask-agentcore-sys crate for the selected target");
    if (agentcoreRustTarget(target.result)) |rust_target| {
        const rust_manifest_path = b.fmt("{s}/bindings/rust/Cargo.toml", .{agentcore_install_root});
        const rust_target_dir = b.getInstallPath(.prefix, b.fmt(".cargo-agentcore/{s}", .{resolved_agentcore_target}));
        const rust_check_cmd = b.addSystemCommand(&.{ "cargo", "build", "--locked", "--example", "link_probe" });
        rust_check_cmd.addArgs(&.{
            "--manifest-path",
            rust_manifest_path,
            "--target",
            rust_target,
            "--target-dir",
            rust_target_dir,
        });
        rust_check_cmd.setEnvironmentVariable("METASK_AGENTCORE_BUNDLE_DIR", agentcore_install_root_abs);
        rust_check_cmd.setCwd(b.path("."));
        rust_check_cmd.step.dependOn(&manifest_cmd.step);
        agentcore_rust_step.dependOn(&rust_check_cmd.step);
    } else {
        agentcore_rust_step.dependOn(&b.addFail("selected target has no supported AgentCore Rust triple").step);
    }

    const bindgen_path = b.option([]const u8, "agentcore-bindgen", "bindgen 0.72.1 executable for the AgentCore Rust regen gate") orelse "bindgen";
    const rust_bindgen_cmd = if (b.graph.host.result.os.tag == .windows) blk: {
        const command = b.addSystemCommand(&.{ "powershell", "-NoProfile", "-File", "scripts/check_agentcore_rust_bindings.ps1" });
        command.addArgs(&.{ "-Bindgen", bindgen_path });
        break :blk command;
    } else blk: {
        const command = b.addSystemCommand(&.{ "sh", "scripts/check_agentcore_rust_bindings.sh" });
        command.setEnvironmentVariable("BINDGEN", bindgen_path);
        break :blk command;
    };
    rust_bindgen_cmd.setCwd(b.path("."));
    const agentcore_rust_bindgen_step = b.step("agentcore:rust-bindgen-check", "Regenerate Rust raw bindings with bindgen 0.72.1 and require no diff");
    agentcore_rust_bindgen_step.dependOn(&rust_bindgen_cmd.step);
    const agentcore_bundle_step = b.step("agentcore:bundle", "Build and link-check an AgentCore static bundle for an explicit target");
    agentcore_bundle_step.dependOn(&consumer_link_cmd.step);
    agentcore_bundle_step.dependOn(&zig_package_check_cmd.step);

    const agentcore_python = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const agentcore_archive_dir = b.option(
        []const u8,
        "agentcore-archive-dir",
        "Output directory for immutable AgentCore archives",
    ) orelse b.getInstallPath(.prefix, "agentcore-archives");
    const agentcore_archive_test_cmd = b.addSystemCommand(&.{
        agentcore_python,
        "scripts/package_agentcore.py",
        "--self-test",
    });
    agentcore_archive_test_cmd.setCwd(b.path("."));
    const agentcore_archive_cmd = b.addSystemCommand(&.{
        agentcore_python,
        "scripts/package_agentcore.py",
        agentcore_install_root,
        agentcore_archive_dir,
    });
    agentcore_archive_cmd.setCwd(b.path("."));
    agentcore_archive_cmd.step.dependOn(&consumer_link_cmd.step);
    agentcore_archive_cmd.step.dependOn(&zig_package_check_cmd.step);
    agentcore_archive_cmd.step.dependOn(&agentcore_archive_test_cmd.step);
    const agentcore_archive_step = b.step("agentcore:archive", "Create an immutable AgentCore zip or tar.gz plus SHA-256");
    agentcore_archive_step.dependOn(&agentcore_archive_cmd.step);

    const consumer_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    addNestedBuildCacheArgs(b, consumer_cmd);
    consumer_cmd.addArgs(&.{
        "--build-file",
        "tests/agentcore_artifact_consumer/build.zig",
        "test",
        b.fmt("-Doptimize={s}", .{@tagName(optimize)}),
        b.fmt("-Dtarget={s}", .{resolved_agentcore_target}),
        b.fmt("-Dbundle-root={s}", .{agentcore_install_root}),
        b.fmt("-Dlibrary-file={s}", .{agentcore_library_file}),
        b.fmt("-Dexpected-strip={s}", .{if (agentcore_strip) "true" else "false"}),
    });
    consumer_cmd.setCwd(b.path("."));
    consumer_cmd.step.dependOn(&manifest_cmd.step);
    const agentcore_consumer_step = b.step("agentcore:consumer", "Run the AgentCore bundle consumer (source-free linking proven by agentcore:bundle's link probes)");
    const host_agentcore_target = b.graph.host.result;
    const agentcore_cpu_is_native = switch (target.query.cpu_model) {
        .baseline, .determined_by_arch_os, .native => true,
        .explicit => host_agentcore_target.cpu.features.isSuperSetOf(target.result.cpu.features),
    } and host_agentcore_target.cpu.features.isSuperSetOf(target.query.cpu_features_add);
    const agentcore_target_is_native = target.result.cpu.arch == host_agentcore_target.cpu.arch and
        target.result.os.tag == host_agentcore_target.os.tag and
        target.result.abi == host_agentcore_target.abi and
        agentcore_cpu_is_native;
    const agentcore_bundle_target_is_native = agentcore_target_is_native or
        (target.result.cpu.arch == host_agentcore_target.cpu.arch and
            target.result.os.tag == .windows and host_agentcore_target.os.tag == .windows and
            agentcore_cpu_is_native);
    const host_agentcore_triple = host_agentcore_target.zigTriple(b.allocator) catch @panic("OOM");
    const native_agentcore_failure = if (!target_was_explicit)
        b.addFail("AgentCore native execution requires explicit -Dtarget=<triple>")
    else if (!agentcore_bundle_target_is_native)
        b.addFail(b.fmt(
            "AgentCore native gate cannot run target {s} on host {s}; use agentcore:bundle for cross-target validation",
            .{ resolved_agentcore_target, host_agentcore_triple },
        ))
    else
        null;
    if (native_agentcore_failure) |failure|
        agentcore_consumer_step.dependOn(&failure.step)
    else {
        agentcore_consumer_step.dependOn(&consumer_cmd.step);
        agentcore_consumer_step.dependOn(&zig_package_check_cmd.step);
    }

    const agentcore_gate_step = b.step("agentcore:gate", "Build, link and run the native source-free AgentCore delivery gate");
    if (native_agentcore_failure) |failure| {
        agentcore_gate_step.dependOn(&failure.step);
    } else {
        agentcore_gate_step.dependOn(agentcore_test_step);
        agentcore_gate_step.dependOn(&consumer_cmd.step);
        agentcore_gate_step.dependOn(&zig_package_check_cmd.step);
        if (agentcoreRustTarget(target.result)) |rust_target| {
            const rust_native_cmd = b.addSystemCommand(&.{ "cargo", "run", "--locked", "--example", "link_probe" });
            rust_native_cmd.addArgs(&.{
                "--manifest-path",
                b.fmt("{s}/bindings/rust/Cargo.toml", .{agentcore_install_root}),
                "--target",
                rust_target,
                "--target-dir",
                b.getInstallPath(.prefix, b.fmt(".cargo-agentcore-native/{s}", .{resolved_agentcore_target})),
            });
            rust_native_cmd.setEnvironmentVariable("METASK_AGENTCORE_BUNDLE_DIR", agentcore_install_root_abs);
            rust_native_cmd.setCwd(b.path("."));
            rust_native_cmd.step.dependOn(&manifest_cmd.step);
            agentcore_gate_step.dependOn(&rust_native_cmd.step);
            const rust_test_cmd = b.addSystemCommand(&.{ "cargo", "test", "--locked" });
            rust_test_cmd.addArgs(&.{
                "--manifest-path",
                b.fmt("{s}/bindings/rust/Cargo.toml", .{agentcore_install_root}),
                "--target",
                rust_target,
                "--target-dir",
                b.getInstallPath(.prefix, b.fmt(".cargo-agentcore-test/{s}", .{resolved_agentcore_target})),
            });
            rust_test_cmd.setEnvironmentVariable("METASK_AGENTCORE_BUNDLE_DIR", agentcore_install_root_abs);
            rust_test_cmd.setCwd(b.path("."));
            rust_test_cmd.step.dependOn(&manifest_cmd.step);
            agentcore_gate_step.dependOn(&rust_test_cmd.step);
        } else {
            agentcore_gate_step.dependOn(&b.addFail("selected target has no supported AgentCore Rust triple").step);
        }
    }
    if (tfilter != null) agentcore_gate_step.dependOn(&b.addFail(
        "agentcore:gate does not accept -Dtfilter; use agentcore:test for filtered diagnostics",
    ).step);

    // test:lib —— 编译库全图(refAllDeclsRecursive),绿即证库与 UI 物理隔离。
    const core_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addHl(b, core_test_mod);
    const project_harness_eval_driver_mod = b.createModule(.{
        .root_source_file = b.path("scripts/project_harness_eval_driver.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    project_harness_eval_driver_mod.addImport("cc", core_test_mod);
    const project_harness_eval_driver = b.addExecutable(.{
        .name = "metacodes-project-harness-eval",
        .root_module = project_harness_eval_driver_mod,
    });
    const install_project_harness_eval_driver = b.addInstallArtifact(
        project_harness_eval_driver,
        .{},
    );
    const project_harness_eval_driver_step = b.step(
        "eval:project-harness-driver",
        "Build the zero-provider project-Harness causal calibration driver",
    );
    project_harness_eval_driver_step.dependOn(&install_project_harness_eval_driver.step);
    const project_harness_lifecycle_driver_mod = b.createModule(.{
        .root_source_file = b.path("scripts/project_harness_lifecycle_driver.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    project_harness_lifecycle_driver_mod.addImport("cc", core_test_mod);
    const project_harness_lifecycle_driver = b.addExecutable(.{
        .name = "metacodes-project-harness-lifecycle",
        .root_module = project_harness_lifecycle_driver_mod,
    });
    const install_project_harness_lifecycle_driver = b.addInstallArtifact(
        project_harness_lifecycle_driver,
        .{},
    );
    const project_harness_lifecycle_driver_step = b.step(
        "eval:project-harness-lifecycle-driver",
        "Build the zero-provider real correction-to-promotion lifecycle driver",
    );
    project_harness_lifecycle_driver_step.dependOn(
        &install_project_harness_lifecycle_driver.step,
    );
    const rule_impact_driver_mod = b.createModule(.{
        .root_source_file = b.path("scripts/rule_impact_driver.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    rule_impact_driver_mod.addImport("cc", core_test_mod);
    const rule_impact_driver = b.addExecutable(.{
        .name = "metacodes-rule-impact-driver",
        .root_module = rule_impact_driver_mod,
    });
    const install_rule_impact_driver = b.addInstallArtifact(rule_impact_driver, .{});
    const rule_impact_driver_step = b.step(
        "eval:rule-impact-driver",
        "Build the zero-provider authenticated RuleImpact evaluation bridge",
    );
    rule_impact_driver_step.dependOn(&install_rule_impact_driver.step);
    // Explicit, expensive native L2: it builds a real promoted rule, starts a
    // loopback provider, and runs both full CLI artifacts. Keep it out of the
    // default aggregate so routine CI health does not pay Lean-build latency.
    const project_harness_kernel_cmd = b.addSystemCommand(&.{
        "bash",
        "scripts/build-project-harness-kernel.sh",
    });
    const project_harness_python = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const project_harness_binary_boundary_cmd = b.addSystemCommand(&.{
        project_harness_python,
    });
    // The Python entrypoint and its local imports are evidence-producing build
    // inputs.  Passing only string paths lets Zig reuse a cached command after
    // an assertion changes, which can make a stale report look freshly green.
    project_harness_binary_boundary_cmd.addFileArg(
        b.path("scripts/eval/project_harness_binary_boundary.py"),
    );
    project_harness_binary_boundary_cmd.addFileInput(
        b.path("scripts/eval/project_harness_evolution.py"),
    );
    project_harness_binary_boundary_cmd.addFileInput(
        b.path("scripts/eval/memory_agent_runtime.py"),
    );
    project_harness_binary_boundary_cmd.addFileInput(
        b.path("scripts/build_project_rule.py"),
    );
    project_harness_binary_boundary_cmd.addArgs(&.{
        "--repo",
        b.build_root.path orelse ".",
        "--production",
    });
    project_harness_binary_boundary_cmd.addArtifactArg(exe);
    project_harness_binary_boundary_cmd.addArg("--shadow");
    project_harness_binary_boundary_cmd.addArtifactArg(project_harness_shadow_exe);
    project_harness_binary_boundary_cmd.addArg("--driver");
    project_harness_binary_boundary_cmd.addArtifactArg(project_harness_lifecycle_driver);
    project_harness_binary_boundary_cmd.addArgs(&.{
        "--kernel",
        b.pathFromRoot("zig-out/libexec/metacodes/metacodes-project-kernel"),
        "--builder",
        b.pathFromRoot("scripts/build_project_rule.py"),
        "--output",
        b.pathFromRoot("zig-out/reports/project-harness-binary-boundary.json"),
    });
    project_harness_binary_boundary_cmd.step.dependOn(&project_harness_kernel_cmd.step);
    const project_harness_binary_boundary_step = b.step(
        "test:project-harness-binary-boundary",
        "Run the real production/enforced vs eval/shadow loopback-provider L2",
    );
    project_harness_binary_boundary_step.dependOn(&project_harness_binary_boundary_cmd.step);
    const rule_impact_driver_l2_cmd = b.addSystemCommand(&.{project_harness_python});
    rule_impact_driver_l2_cmd.addFileArg(b.path("scripts/eval/rule_impact_driver_l2.py"));
    rule_impact_driver_l2_cmd.addArg("--eval-driver");
    rule_impact_driver_l2_cmd.addArtifactArg(project_harness_eval_driver);
    rule_impact_driver_l2_cmd.addArg("--impact-driver");
    rule_impact_driver_l2_cmd.addArtifactArg(rule_impact_driver);
    rule_impact_driver_l2_cmd.addArgs(&.{
        "--kernel",
        b.pathFromRoot("zig-out/libexec/metacodes/metacodes-project-kernel"),
    });
    rule_impact_driver_l2_cmd.step.dependOn(&project_harness_kernel_cmd.step);
    const rule_impact_driver_l2_step = b.step(
        "test:rule-impact-driver-l2",
        "Run the zero-provider journal-to-receipt-to-Lean RuleImpact L2",
    );
    rule_impact_driver_l2_step.dependOn(&rule_impact_driver_l2_cmd.step);
    const core_test = b.addTest(.{
        .name = "metacodes-core-test",
        .root_module = core_test_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
        .test_runner = .{
            .path = b.path("scripts/sharded_test_runner.zig"),
            .mode = .simple,
        },
    });
    const core_test_step = b.step("test:lib", "Run the complete metacodes-core suite in checked deterministic shards");
    const core_shard_reports = b.allocator.alloc(std.Build.LazyPath, lib_test_shards) catch @panic("OOM");
    for (0..lib_test_shards) |shard_index| {
        const run_shard = addTestRunArtifact(b, core_test, windows_test_prelude);
        // captureStdOut would otherwise make the Run step cacheable. A test
        // gate must execute on every invocation; cached reports are evidence
        // from an earlier repository/environment state, not current feedback.
        run_shard.has_side_effects = true;
        run_shard.setEnvironmentVariable("METACODES_TEST_SHARD_COUNT", b.fmt("{}", .{lib_test_shards}));
        run_shard.setEnvironmentVariable("METACODES_TEST_SHARD_INDEX", b.fmt("{}", .{shard_index}));
        run_shard.expectExitCode(0);
        core_shard_reports[shard_index] = run_shard.captureStdOut(.{
            .basename = b.fmt("metacodes-core-test-shard-{}.txt", .{shard_index}),
        });
    }
    const core_shard_reporter = b.addExecutable(.{
        .name = "metacodes-core-shard-reporter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/sharded_test_reporter.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run_core_shard_reporter = b.addRunArtifact(core_shard_reporter);
    for (core_shard_reports) |report| run_core_shard_reporter.addFileArg(report);
    core_test_step.dependOn(&run_core_shard_reporter.step);

    const core_monolithic_run = addTestRunArtifact(b, core_test, windows_test_prelude);
    core_monolithic_run.setEnvironmentVariable("METACODES_TEST_SHARD_COUNT", "1");
    core_monolithic_run.setEnvironmentVariable("METACODES_TEST_SHARD_INDEX", "0");
    const core_test_monolithic_step = b.step("test:lib-monolithic", "Run the complete metacodes-core suite in one diagnostic process");
    core_test_monolithic_step.dependOn(&core_monolithic_run.step);

    const shard_runner_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/sharded_test_runner.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const shard_reporter_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/sharded_test_reporter.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const core_shard_harness_step = b.step("test:lib-shard-harness", "Test core shard partition and aggregate fail-closed checks");
    core_shard_harness_step.dependOn(&b.addRunArtifact(shard_runner_tests).step);
    core_shard_harness_step.dependOn(&b.addRunArtifact(shard_reporter_tests).step);

    // Diagnostic companion to test:lib. It runs the identical test graph and
    // semantics, but emits per-test timings plus slow-test buckets/top-N so
    // performance work is driven by evidence instead of guessed timeouts.
    const core_timed_test = b.addTest(.{
        .name = "metacodes-core-test-times",
        .root_module = core_test_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
        .test_runner = .{
            .path = b.path("scripts/time_test_runner.zig"),
            .mode = .simple,
        },
    });
    const core_test_times_step = b.step("test:lib-times", "Run metacodes-core tests with per-test timing diagnostics");
    core_test_times_step.dependOn(&addTestRunArtifact(b, core_timed_test, windows_test_prelude).step);
    core_test_step.dependOn(http_status_gate_step);

    // test:lsp —— LSP 子系统(Y2 Step2:被动诊断)隔离测试。
    // 根在 src/ 层(而非 src/lsp/lsp.zig):service.zig 相对引 ../util/time.zig,
    // 根在 src/lsp/ 会越出 module path(见 src/lsp_test_root.zig 顶部说明)。
    const lsp_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lsp_test_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addPlatform(b, lsp_test_mod); // lsp/ 依赖 platform（sync/process），隔离测试也需
    const lsp_test = b.addTest(.{ .name = "lsp-test", .root_module = lsp_test_mod });
    const lsp_test_step = b.step("test:lsp", "Test the LSP subsystem in isolation (Y2 Step2)");
    lsp_test_step.dependOn(&addTestRunArtifact(b, lsp_test, windows_test_prelude).step);

    // test:provider —— issue #16 provider offer kernel, in isolation.
    // Compiles the subsystem from a narrow root, which proves it *builds*
    // standalone. It does not enforce the import boundary — the module root is
    // `src/`, so any file under it is importable — that is
    // `subsystem:boundary`'s job. Its tests also run inside the aggregate
    // `test` gate; this step exists for the standalone-build proof, not for
    // extra coverage.
    const provider_test_mod = b.createModule(.{
        .root_source_file = b.path("src/provider_test_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addPlatform(b, provider_test_mod); // control_plane guards its state with platform/sync
    const provider_test = b.addTest(.{ .name = "provider-test", .root_module = provider_test_mod });
    const provider_test_step = b.step("test:provider", "Test the provider offer kernel in isolation (issue #16)");
    provider_test_step.dependOn(&addTestRunArtifact(b, provider_test, windows_test_prelude).step);

    // subsystem:boundary —— the provider kernel and the picker may import only
    // what their doc comments say. The compile-from-a-narrow-root gates below
    // cannot enforce it: their module root is `src/`, so any file under it is
    // importable. This checks the rule where the rule lives, in the source.
    const subsystem_boundary_mod = b.createModule(.{
        .root_source_file = b.path("scripts/subsystem_boundary_gate.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const subsystem_boundary_exe = b.addExecutable(.{
        .name = "subsystem-boundary-gate",
        .root_module = subsystem_boundary_mod,
    });
    const subsystem_boundary_run = b.addRunArtifact(subsystem_boundary_exe);
    subsystem_boundary_run.setCwd(b.path("."));
    subsystem_boundary_run.addArg(".");
    const subsystem_boundary_unit = b.addTest(.{
        .name = "subsystem-boundary-gate-unit",
        .root_module = subsystem_boundary_mod,
    });
    const subsystem_boundary_step = b.step(
        "subsystem:boundary",
        "Enforce the provider and picker import boundaries (issue #16)",
    );
    subsystem_boundary_step.dependOn(&subsystem_boundary_run.step);
    subsystem_boundary_step.dependOn(&addTestRunArtifact(b, subsystem_boundary_unit, windows_test_prelude).step);

    // test:picker —— issue #16 cross-UI model picker, in isolation.
    // Same shape as `test:provider`: it proves the picker builds standalone.
    // The rule that it may reach only the provider kernel and the terminal
    // theme is enforced by `subsystem:boundary`.
    const picker_test_mod = b.createModule(.{
        .root_source_file = b.path("src/picker_test_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addPlatform(b, picker_test_mod);
    const picker_test = b.addTest(.{ .name = "picker-test", .root_module = picker_test_mod });
    const picker_test_step = b.step("test:picker", "Test the cross-UI model picker in isolation (issue #16)");
    picker_test_step.dependOn(&addTestRunArtifact(b, picker_test, windows_test_prelude).step);

    // test:platform —— 可移植抽象层(sync/process/fs/signal/rng/paths)。platform 成独立命名模块后
    // 其测试不再聚合进 cc-test，故独立入口。process fork 真子进程测试需 METACODES_PROC_TEST=1 启用。
    const platform_test_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/platform.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const platform_test = b.addTest(.{ .name = "platform-test", .root_module = platform_test_mod });
    const platform_test_step = b.step("test:platform", "Test the portable platform abstraction layer");
    const platform_test_run = addTestRunArtifact(b, platform_test, windows_test_prelude);
    platform_test_step.dependOn(&platform_test_run.step);

    // example —— 独立消费者,经 module 用库跑一轮 agent loop(见 example/main.zig)。
    const example_mod = b.createModule(.{
        .root_source_file = b.path("example/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addImport("metacodes-core", core_mod);
    // 注:不在 example_mod 上 addHl —— hl module 随 core_mod 传入,无需重复接。
    const example_exe = b.addExecutable(.{ .name = "example", .root_module = example_mod });
    const example_step = b.step("example", "Build & run the metacodes-core example");
    example_step.dependOn(&b.addRunArtifact(example_exe).step);

    // Zero-provider paired microbenchmark for the once-per-generation plugin
    // snapshot/inventory cost. This is a performance regression gate, not
    // coding-quality evidence (see doc/PLUGIN_EVALUATION.md).
    const plugin_bench_mod = b.createModule(.{
        .root_source_file = b.path("scripts/plugin_snapshot_bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    plugin_bench_mod.addImport("metacodes-core", core_mod);
    const plugin_bench_exe = b.addExecutable(.{
        .name = "plugin-snapshot-bench",
        .root_module = plugin_bench_mod,
    });
    const plugin_bench_step = b.step(
        "plugin:bench",
        "Run the zero-provider immutable plugin snapshot regression benchmark",
    );
    plugin_bench_step.dependOn(&b.addRunArtifact(plugin_bench_exe).step);

    const run_step = b.step("run", "Run the release app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_debug_step = b.step("run-debug", "Run the debug app");
    const run_debug_cmd = b.addRunArtifact(debug_exe);
    run_debug_step.dependOn(&run_debug_cmd.step);
    if (b.args) |args| {
        run_debug_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(release_test_step);
    test_step.dependOn(http_status_gate_step);
    test_step.dependOn(subsystem_boundary_step);
    const tinykg_contract_test_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "-m",
        "unittest",
        "scripts.tests.test_stage_tinykg_binary",
        "-v",
    });
    const tinykg_contract_test_step = b.step(
        "test:tinykg-binary",
        "Test the bundled and explicit manually maintained TinyKG boundary",
    );
    tinykg_contract_test_step.dependOn(&tinykg_contract_test_cmd.step);
    test_step.dependOn(&tinykg_contract_test_cmd.step);

    // The trajectory audit itself only runs against a real ~/.metacodes, which
    // CI does not have - but its parsing does not need one, and two defects in
    // it were caught by these tests rather than by the real data (which
    // happened not to exercise them).
    const audit_test_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "-m",
        "unittest",
        "scripts.tests.test_audit_trajectories",
        "-v",
    });
    const audit_test_step = b.step(
        "test:trajectory-audit",
        "Test the session-transcript audit (parsing, pairing, privacy)",
    );
    audit_test_step.dependOn(&audit_test_cmd.step);
    test_step.dependOn(&audit_test_cmd.step);
    const doc_check_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "scripts/check_doc_links.py",
    });
    const doc_facts_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "scripts/check_doc_facts.py",
    });
    const doc_check_step = b.step("doc:check", "Check documentation links and facts");
    doc_check_step.dependOn(&doc_check_cmd.step);
    doc_check_step.dependOn(&doc_facts_cmd.step);
    const notices_cmd = b.addSystemCommand(&.{ if (@import("builtin").os.tag == .windows) "python" else "python3", "scripts/gen_third_party_notices.py", "--check" });
    const notices_step = b.step("release:notices", "Check generated third-party notices");
    notices_step.dependOn(&notices_cmd.step);
    doc_check_step.dependOn(notices_step);
    const doc_facts_test_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "-m",
        "unittest",
        "scripts.tests.test_check_doc_facts",
        "-v",
    });
    const doc_facts_test_step = b.step("test:doc-facts", "Test documentation fact checks");
    doc_facts_test_step.dependOn(&doc_facts_test_cmd.step);
    test_step.dependOn(&doc_facts_test_cmd.step);
    const gate_manifest_test_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "-m",
        "unittest",
        "scripts.tests.test_gate_manifest",
        "-v",
    });
    const gate_manifest_test_step = b.step("test:gate-manifest", "Test the AGENTS.md and CI gate manifest");
    gate_manifest_test_step.dependOn(&gate_manifest_test_cmd.step);
    test_step.dependOn(&gate_manifest_test_cmd.step);
    const gate_fmt = b.addFmt(.{ .paths = &.{ "build.zig", "src", "tests" }, .check = true });
    const gate_coverage = if (@import("builtin").os.tag == .windows)
        b.addSystemCommand(&.{ "cmd", "/C", "echo scripts/test_coverage_audit.sh is bash-only; skipped on Windows" })
    else
        b.addSystemCommand(&.{"scripts/test_coverage_audit.sh"});
    // The checklist ends with `git diff --check`; the aggregate gate runs it too,
    // so the one advertised command really is the whole list.
    const gate_diff_check = b.addSystemCommand(&.{ "git", "diff", "--check" });
    const gate_pr_step = b.step("gate:pr", "Run the AGENTS.md pre-submit checklist");
    gate_pr_step.dependOn(&gate_fmt.step);
    gate_pr_step.dependOn(test_step);
    gate_pr_step.dependOn(core_test_step);
    gate_pr_step.dependOn(&gate_coverage.step);
    gate_pr_step.dependOn(doc_check_step);
    gate_pr_step.dependOn(&gate_diff_check.step);
    const test_obj = b.addTest(.{
        .name = "cc-test",
        .root_module = test_cc_mod, // 共享模块(perf,见 debug exe 后注释)
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    const test_run = addTestRunArtifact(b, test_obj, windows_test_prelude);
    wireTinyKgTestInput(test_run, staged_tinykg);
    test_step.dependOn(&test_run.step);

    // Two independent Metacodes processes share one authenticated StoreActor.
    // This is the runtime actuator for the daemon transport control plane.
    const kg_transport_probe_mod = b.createModule(.{
        .root_source_file = b.path("tests/helpers/kg_daemon_transport_probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    kg_transport_probe_mod.addImport("cc", test_cc_mod);
    addPlatform(b, kg_transport_probe_mod);
    const kg_transport_probe = b.addExecutable(.{
        .name = "kg-daemon-transport-probe",
        .root_module = kg_transport_probe_mod,
    });
    const kg_transport_runtime = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "scripts/test_kg_daemon_transport.py",
        "--probe",
    });
    kg_transport_runtime.addArtifactArg(kg_transport_probe);
    const kg_transport_step = b.step("test:kg-daemon-transport", "Run authenticated shared-Store daemon transport L2");
    kg_transport_step.dependOn(&kg_transport_runtime.step);
    test_step.dependOn(&kg_transport_runtime.step);

    // test:eval —— harness 评估控制面（suite/readiness/rollout/judgement/
    // compare/gate）。Python 合同测试 + 同宿主原生零付费 smoke；不访问真实模型，
    // 默认 test 也执行，避免评估器或 native 接线漂移后继续给出看似可信的分数。
    const eval_test_step = b.step("test:eval", "Test the harness evaluation framework");
    const eval_python_exe = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const eval_test_cmd = b.addSystemCommand(&.{
        eval_python_exe,
        "-m",
        "unittest",
        "discover",
        "-s",
        "scripts/eval/tests",
        "-v",
    });
    eval_test_step.dependOn(&eval_test_cmd.step);
    test_step.dependOn(&eval_test_cmd.step);
    const runtime_tests_can_execute_target =
        target.result.os.tag == @import("builtin").os.tag and
        target.result.cpu.arch == @import("builtin").cpu.arch;
    if (runtime_tests_can_execute_target) {
        if (staged_tinykg) |tinykg| {
            // Native Python cases discover the installed TinyKG by path.  On
            // a clean checkout they must wait for installation; otherwise
            // test discovery races the build and silently turns coverage into
            // machine-state-dependent skips.
            eval_test_cmd.step.dependOn(tinykg.install_step);
            eval_test_cmd.setEnvironmentVariable("METACODES_TEST_TINYKG_BIN", tinykg.installed_path);
            eval_test_cmd.setEnvironmentVariable("METACODES_TEST_TINYKG_SHA256", tinykg.source_sha256);
            const arm_smoke = b.addSystemCommand(&.{
                eval_python_exe,
                "scripts/eval/runtime_arm_smoke.py",
                "--binary",
            });
            arm_smoke.addArtifactArg(exe);
            arm_smoke.addArg("--tinykg-binary");
            arm_smoke.addFileArg(tinykg.artifact);
            arm_smoke.addArgs(&.{ "--expected-version", manifest.version });
            eval_test_step.dependOn(&arm_smoke.step);
            test_step.dependOn(&arm_smoke.step);

            // A replay fixture cannot prove that memory adapters cross the
            // real agent-loop/tool/runtime boundary.  Run all three adapters
            // against the native binary and hash-pinned local TinyKG with a
            // deterministic loopback provider (paid=0, external network=0).
            // The native rollout hands the runtime its metadata as an anonymous
            // inherited descriptor: open, unlink, pass the fd number through
            // METACODES_EVAL_METADATA_FD via pass_fds (memory_agent_runtime.py,
            // evaluation_backend.zig). Windows has no pass_fds, refuses to unlink
            // an open file (sharing violation), and the runtime parses a POSIX fd
            // number, so the smoke is POSIX-only until that hand-off gets a
            // Windows handle design (the Python suite marks the same mechanism
            // "anonymous inherited descriptor requires POSIX").
            if (@import("builtin").os.tag != .windows) {
                const memory_runtime_smoke = b.addSystemCommand(&.{
                    eval_python_exe,
                    "scripts/eval/memory_agent_runtime_smoke.py",
                    "--binary",
                });
                memory_runtime_smoke.addArtifactArg(exe);
                memory_runtime_smoke.addArg("--tinykg-binary");
                memory_runtime_smoke.addFileArg(tinykg.artifact);
                eval_test_step.dependOn(&memory_runtime_smoke.step);
                test_step.dependOn(&memory_runtime_smoke.step);
            }
        }
    }

    // ------------------------------------------------------------------
    // Extra test step: spike / standalone harness files under tests/
    // Each file is compiled as an independent test artifact so main src
    // stays clean. Add new files here as they land.
    // ------------------------------------------------------------------
    const spike_step = b.step("test:spike", "Run spike / harness tests");
    const spike_files = [_][]const u8{
        "tests/unit/stream_reader_spike.zig",
        "tests/unit/termios_spike.zig", // POSIX-only(termios)——Windows 目标下面跳过
        "tests/_harness/mock_sse_server.zig",
    };
    for (spike_files) |f| {
        if (target.result.os.tag == .windows and std.mem.endsWith(u8, f, "termios_spike.zig")) continue;
        // mock_sse_server 复用共享 harness 模块做 root(它就是同一份编译);其余 spike 各自建。
        const shared_harness = std.mem.endsWith(u8, f, "mock_sse_server.zig");
        const m = if (shared_harness) test_harness_mod else b.createModule(.{
            .root_source_file = b.path(f),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        if (!shared_harness) addPlatform(b, m);
        const t = b.addTest(.{
            .name = "spike",
            .root_module = m,
            .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
        });
        const run_t = addTestRunArtifact(b, t, windows_test_prelude);
        spike_step.dependOn(&run_t.step);
    }

    // Integration / Component tests share one compilation root. The old graph
    // built 67 near-identical binaries (409 CPU-seconds in the 2026-08-06
    // baseline). tests/integration_suite.zig is now the inventory source of
    // truth; individual test names are partitioned only after one compilation.
    const integration_suite_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration_suite.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    integration_suite_mod.addImport("harness", test_harness_mod);
    integration_suite_mod.addImport("cc", test_cc_mod);
    addPlatform(b, integration_suite_mod);
    const integration_suite_test = b.addTest(.{
        .name = "integration-suite",
        .root_module = integration_suite_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
        .test_runner = .{
            .path = b.path("scripts/sharded_test_runner.zig"),
            .mode = .simple,
        },
    });
    const integration_reports = b.allocator.alloc(std.Build.LazyPath, integration_test_shards) catch @panic("OOM");
    for (0..integration_test_shards) |shard_index| {
        const run_shard = addTestRunArtifact(b, integration_suite_test, windows_test_prelude);
        run_shard.has_side_effects = true;
        run_shard.setEnvironmentVariable("METACODES_TEST_SHARD_COUNT", b.fmt("{}", .{integration_test_shards}));
        run_shard.setEnvironmentVariable("METACODES_TEST_SHARD_INDEX", b.fmt("{}", .{shard_index}));
        run_shard.expectExitCode(0);
        run_shard.step.dependOn(&install_mock_mcp.step);
        wireTinyKgTestInput(run_shard, staged_tinykg);
        integration_reports[shard_index] = run_shard.captureStdOut(.{
            .basename = b.fmt("integration-test-shard-{}.txt", .{shard_index}),
        });
    }
    const run_integration_reporter = b.addRunArtifact(core_shard_reporter);
    for (integration_reports) |report| run_integration_reporter.addFileArg(report);
    spike_step.dependOn(&run_integration_reporter.step);

    const integration_monolithic_run = addTestRunArtifact(b, integration_suite_test, windows_test_prelude);
    integration_monolithic_run.setEnvironmentVariable("METACODES_TEST_SHARD_COUNT", "1");
    integration_monolithic_run.setEnvironmentVariable("METACODES_TEST_SHARD_INDEX", "0");
    integration_monolithic_run.step.dependOn(&install_mock_mcp.step);
    wireTinyKgTestInput(integration_monolithic_run, staged_tinykg);
    const integration_monolithic_step = b.step("test:integration-monolithic", "Run the aggregate component/integration suite in one process");
    integration_monolithic_step.dependOn(&integration_monolithic_run.step);

    const integration_timed_test = b.addTest(.{
        .name = "integration-suite-times",
        .root_module = integration_suite_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
        .test_runner = .{
            .path = b.path("scripts/time_test_runner.zig"),
            .mode = .simple,
        },
    });
    const integration_timed_run = addTestRunArtifact(b, integration_timed_test, windows_test_prelude);
    integration_timed_run.step.dependOn(&install_mock_mcp.step);
    wireTinyKgTestInput(integration_timed_run, staged_tinykg);
    const integration_times_step = b.step("test:integration-times", "Run aggregate component/integration tests with per-test timings");
    integration_times_step.dependOn(&integration_timed_run.step);

    // ToolDispatcher metadata 验收(issue #5):直接消费 AgentCore 包装层
    // (session_budget/mcp_session/model_skill_tool)与 metacodes-core 目录的
    // 组合。cc(main.zig 根)与 metacodes-core(lib.zig 根)不能共存于同一个
    // 编译图,故此文件从 aggregate 套件排除(见 aggregate_test_exclusions),
    // 走独立 artifact 并挂进主 test gate。
    const dispatcher_metadata_mod = b.createModule(.{
        .root_source_file = b.path("tests/component/tool_dispatcher_metadata_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dispatcher_metadata_mod.addImport("harness", test_harness_mod);
    dispatcher_metadata_mod.addImport("metacodes-core", core_mod);
    dispatcher_metadata_mod.addImport("agentcore-abi", agentcore_abi_test_mod);
    const dispatcher_metadata_test = b.addTest(.{
        .name = "tool-dispatcher-metadata",
        .root_module = dispatcher_metadata_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    const dispatcher_metadata_run = addTestRunArtifact(b, dispatcher_metadata_test, windows_test_prelude);
    const dispatcher_metadata_step = b.step("test:dispatcher-metadata", "Run the ToolDispatcher metadata acceptance suite");
    dispatcher_metadata_step.dependOn(&dispatcher_metadata_run.step);
    test_step.dependOn(&dispatcher_metadata_run.step);

    // Focused Skill Runtime gate. Keep this work independently
    // runnable instead of forcing every unrelated spike/component artifact
    // through the broad `test` graph.
    const skill_runtime_step = b.step(
        "test:skill-runtime",
        "Run the shared Skill Runtime and CLI adapter integration tests",
    );
    const skill_runtime_files = [_][]const u8{
        "tests/integration/skills_e2e_test.zig",
        "tests/component/skill_fork_test.zig",
    };
    for (skill_runtime_files) |f| {
        const m = b.createModule(.{
            .root_source_file = b.path(f),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        m.addImport("harness", test_harness_mod);
        m.addImport("cc", test_cc_mod);
        addPlatform(b, m);
        const t = b.addTest(.{
            .name = "skill-runtime",
            .root_module = m,
            .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
        });
        const run_t = addTestRunArtifact(b, t, windows_test_prelude);
        skill_runtime_step.dependOn(&run_t.step);
    }
    const skill_runtime_unit_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addHl(b, skill_runtime_unit_mod);
    const skill_runtime_unit = b.addTest(.{
        .name = "skill-runtime-unit",
        .root_module = skill_runtime_unit_mod,
        .filters = &.{
            "skills.runtime",
            "skills.active",
            "skills.skill",
            "skills.tool_pool_filter",
        },
    });
    skill_runtime_step.dependOn(
        &addTestRunArtifact(
            b,
            skill_runtime_unit,
            windows_test_prelude,
        ).step,
    );

    test_step.dependOn(spike_step);

    // test:new —— 只跑本次 e2e 框架新增的 L2 component 测试(隔离运行,绕开主套件已知
    // 的 integration 挂起)。每个文件独立 artifact,带 cc + harness imports。
    const new_step = b.step("test:new", "Run only the new e2e-framework L2 component tests");
    const new_files = [_][]const u8{
        "tests/component/user_context_inject_test.zig",
        "tests/component/subagent_agentdef_fields_test.zig",
        "tests/component/agent_session_tools_test.zig",
        "tests/component/sealed_publication_test.zig",
        "tests/component/recovery_allowance_test.zig",
        "tests/component/agent_session_host_tools_test.zig",
        "tests/component/plugin_runtime_test.zig",
        "tests/component/plugin_process_test.zig",
        "tests/component/agent_session_ui_test.zig",
        "tests/component/http_error_test.zig",
        "tests/component/answer_queue_test.zig",
        "tests/component/base_url_flag_test.zig",
        "tests/component/task_error_test.zig",
        "tests/component/tool_loop_breaker_test.zig",
        "tests/component/rule_author_test.zig",
        "tests/component/self_evolution_test.zig",
        "tests/component/plan_mode_inject_test.zig",
        "tests/component/agent_background_test.zig",
        "tests/component/skill_fileref_test.zig",
        "tests/component/transcript_roundtrip_test.zig",
        "tests/component/headless_json_test.zig",
        "tests/component/compound_perm_test.zig",
        "tests/component/protected_skill_inject_test.zig",
        "tests/component/read_state_test.zig",
        "tests/component/tool_concurrency_test.zig",
        "tests/component/tool_result_storage_test.zig",
        "tests/component/cache_break_test.zig",
        "tests/component/microcompact_test.zig",
        "tests/component/kg_task_projection_test.zig",
        "tests/component/goal_state_test.zig",
        "tests/component/auth_test.zig",
        "tests/component/schema_validation_test.zig",
        "tests/component/tool_schema_coverage_test.zig",
        "tests/component/tool_smoke_test.zig",
        "tests/component/compact_summary_test.zig",
        "tests/component/auto_compact_request_test.zig",
        "tests/component/render_region_test.zig",
        "tests/component/stream_retry_test.zig",
        "tests/component/ui_state_test.zig",
        "tests/component/ui_render_test.zig",
        "tests/component/ui_backend_test.zig",
        "tests/component/ui_multifrontend_test.zig",
        "tests/component/diagnostics_test.zig",
        "tests/component/provider_vtable_test.zig",
        "tests/component/capability_gate_test.zig",
        "tests/component/openai_provider_test.zig",
        "tests/component/gemini_provider_test.zig",
        "tests/component/background_main_test.zig",
        "tests/component/suspend_resume_test.zig",
        "tests/component/diff_highlight_test.zig",
        "tests/component/prompt_override_test.zig",
        "tests/component/weak_model_test.zig",
        "tests/component/task_batch_test.zig",
        "tests/component/teammate_runtime_test.zig",
        "tests/component/swarm_tools_test.zig",
        "tests/component/swarm_dag_test.zig",
        "tests/component/swarm_security_test.zig",
        "tests/component/swarm_process_test.zig",
        "tests/component/add_dir_test.zig",
        "tests/component/dialect_matrix_test.zig",
    };
    for (new_files) |f| {
        const m = b.createModule(.{
            .root_source_file = b.path(f),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        m.addImport("harness", test_harness_mod); // 共享模块(见 integ 循环前注释:perf)
        m.addImport("cc", test_cc_mod);
        addPlatform(b, m); // 测试文件用 platform 的可移植 env/net 封装(setEnv、clientRoundtrip)
        const t = b.addTest(.{
            .name = "new-l2",
            .root_module = m,
            .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
        });
        new_step.dependOn(&addTestRunArtifact(b, t, windows_test_prelude).step);
    }

    // 五个 AgentDef 运行字段的聚焦门；开发时无需编译整套 component artifacts。
    const agentdef_fields_step = b.step("test:agentdef-fields", "Run AgentDef runtime field L2/L3 tests");
    {
        const m = b.createModule(.{
            .root_source_file = b.path("tests/component/subagent_agentdef_fields_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        m.addImport("harness", test_harness_mod);
        m.addImport("cc", test_cc_mod);
        addPlatform(b, m);
        const t = b.addTest(.{
            .name = "agentdef-fields",
            .root_module = m,
            .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
        });
        agentdef_fields_step.dependOn(&addTestRunArtifact(b, t, windows_test_prelude).step);
    }

    // test:mem —— 记忆系统 L2 组件测试(隔离 artifact,绕开主套件 integration 挂起)。
    // 通道 A:user_context_inject;通道 B:memdir_inject。MockServer 断言端到端进请求体。
    const mem_step = b.step("test:mem", "Run memory-system L2 component tests (isolated)");
    {
        const mem_files = [_][]const u8{
            "tests/component/user_context_inject_test.zig",
            "tests/component/memdir_inject_test.zig",
        };
        for (mem_files) |f| {
            const m = b.createModule(.{
                .root_source_file = b.path(f),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            m.addImport("harness", test_harness_mod); // 共享模块(见 integ 循环前注释:perf)
            m.addImport("cc", test_cc_mod);
            addPlatform(b, m); // 测试文件用 platform 的可移植 env/net 封装
            const t = b.addTest(.{
                .name = "mem-l2",
                .root_module = m,
                .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
            });
            mem_step.dependOn(&addTestRunArtifact(b, t, windows_test_prelude).step);
        }
    }

    // 专用的知识治理闭环反馈门：只编译 Kg 自动召回、真实 API prompt 和真 TinyKG
    // KgContext 纵切，避免 rule-control 为三个测试冷编译整个 test:spike 图。
    const kg_governance_step = b.step("test:kg-governance", "Run TinyKG evidence/freshness governance L2 tests");
    {
        const m = b.createModule(.{
            .root_source_file = b.path("tests/component/kg_integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        m.addImport("harness", test_harness_mod);
        m.addImport("cc", test_cc_mod);
        addPlatform(b, m);
        const t = b.addTest(.{
            .name = "kg-governance-l2",
            .root_module = m,
            .filters = if (tfilter) |filter_text| &.{filter_text} else &.{"L2 KG governance:"},
        });
        const run_t = addTestRunArtifact(b, t, windows_test_prelude);
        wireTinyKgTestInput(run_t, staged_tinykg);
        kg_governance_step.dependOn(&run_t.step);
    }

    // Focused feedback actuator for the execution-grounded ontology loop. The
    // rule controller observes this exact production L2 instead of accepting a
    // manifest or prompt claim as proof of runtime wiring.
    const kg_ontology_feedback_step = b.step("test:kg-ontology-feedback", "Run host-execution to TinyKG ontology feedback L2");
    {
        const m = b.createModule(.{
            .root_source_file = b.path("tests/component/kg_integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        m.addImport("harness", test_harness_mod);
        m.addImport("cc", test_cc_mod);
        addPlatform(b, m);
        const t = b.addTest(.{
            .name = "kg-ontology-feedback-l2",
            .root_module = m,
            .filters = if (tfilter) |filter_text| &.{filter_text} else &.{"L2 KG ontology feedback:"},
        });
        const run_t = addTestRunArtifact(b, t, windows_test_prelude);
        wireTinyKgTestInput(run_t, staged_tinykg);
        kg_ontology_feedback_step.dependOn(&run_t.step);
    }

    // Focused feedback actuator for the read side of the ontology loop: a new
    // task claim must receive verified, execution-grounded history before the
    // next model request can perform work.
    const kg_experience_feedback_step = b.step("test:kg-experience-feedback", "Run TinyKG prior-execution decision feedback L2");
    {
        const m = b.createModule(.{
            .root_source_file = b.path("tests/component/kg_integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        m.addImport("harness", test_harness_mod);
        m.addImport("cc", test_cc_mod);
        addPlatform(b, m);
        const t = b.addTest(.{
            .name = "kg-experience-feedback-l2",
            .root_module = m,
            .filters = if (tfilter) |filter_text| &.{filter_text} else &.{"L2 KG experience feedback:"},
        });
        const run_t = addTestRunArtifact(b, t, windows_test_prelude);
        wireTinyKgTestInput(run_t, staged_tinykg);
        kg_experience_feedback_step.dependOn(&run_t.step);
    }

    // 注:TTY 渲染测试(tests/tty/)用独立 python runner 跑,**不接 zig build**——
    // PTY(pty.fork)在 zig build-runner 的进程/stdio 监管下时序不稳(直接跑 12/12 全过,
    // 经 build SystemCommand 跑会大面积假失败)。跑法:
    //   zig build && python3 tests/tty/run_tty_tests.py --bin zig-out/bin/metacodes-debug
    // 这与 e2e(走 shell 而非 zig build)同理。

    // test:e2e-tty —— tty 真模型工具 e2e(cases/test_e2e_*.py)。与渲染测试不同:这些用例
    // 自建 PTY、断言靠落盘的 transcript.jsonl(非 build-runner 捕获的屏幕字节),所以经
    // SystemCommand 跑不受 PTY 时序假失败影响(已实测 stdin=/dev/null 下通过)。
    // 打真模型(凭证来自 ~/.metacodes/auth.json 或 METASK_API_KEY,无硬编码)→ 默认应设 TTY_SKIP_MODEL=1
    // 跳过(CI/离线);显式 `TTY_SKIP_MODEL= zig build test:e2e-tty` 才真打模型、真副作用
    // (真联网/真排程/真发通知/真改 git)。先 build debug 二进制 + mock_mcp_server。
    const e2e_tty_step = b.step("test:e2e-tty", "Run tty real-model tool e2e (打真模型, 设 TTY_SKIP_MODEL=1 跳过)");
    // python 命令名:Windows 官方发行版只有 python(无 python3 别名);POSIX 惯例 python3。
    const python_exe = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const tty_bin = if (@import("builtin").os.tag == .windows) "zig-out/bin/metacodes-debug.exe" else "zig-out/bin/metacodes-debug";
    const e2e_tty_cmd = b.addSystemCommand(&.{
        python_exe, "tests/tty/run_tty_tests.py",
        "--bin",    tty_bin,
        "-k",       "e2e_",
    });
    e2e_tty_cmd.step.dependOn(&install_debug.step);
    e2e_tty_cmd.step.dependOn(&install_mock_mcp.step);
    e2e_tty_cmd.step.dependOn(&install_replay.step);
    e2e_tty_step.dependOn(&e2e_tty_cmd.step);

    const windows_gate_failure = if (!target_was_explicit)
        b.addFail("windows:gate and windows:tty require explicit -Dtarget=x86_64-windows-gnu")
    else if (target.result.os.tag != .windows or !agentcore_target_is_native)
        b.addFail(b.fmt(
            "Windows native gate cannot run target {s} on host {s}",
            .{ resolved_agentcore_target, host_agentcore_triple },
        ))
    else
        null;
    const windows_gate_step = b.step(
        "windows:gate",
        "Run native Windows platform keystones + CLI smoke (full suite: zig build test)",
    );
    const windows_tty_step = b.step("windows:tty", "Run optional offline Windows ConPTY tests (requires python + pywinpty)");
    if (windows_gate_failure) |failure| {
        windows_gate_step.dependOn(&failure.step);
        windows_tty_step.dependOn(&failure.step);
    } else {
        const windows_help_cmd = b.addRunArtifact(exe);
        windows_help_cmd.addArg("--help");
        windows_help_cmd.step.dependOn(b.getInstallStep());
        // This gate proves the Windows portability layer and installed CLI can
        // execute natively. The repository-wide suite is a separate gate: the
        // "Full offline test suite" step of ci.yml's windows-gates job runs
        // `zig build test -j6` on the native Windows runner (#53 wired it; before
        // that no workflow ran it and Windows regressions accumulated silently).
        // Keep the two decoupled: do not couple the full suite's unrelated
        // subsystem timing/concurrency failures to this platform gate.
        windows_gate_step.dependOn(platform_test_step);
        // The LSP subsystem's server lookup is native-platform logic (PATH
        // separator, path joiner, PATHEXT probing), so its suite belongs on the
        // native Windows gate rather than only on POSIX hosts. It is a leaf
        // subsystem with no timing/concurrency coupling to the rest of the
        // repository suite, so it does not reintroduce the flakiness the
        // comment above is guarding against.
        windows_gate_step.dependOn(lsp_test_step);
        windows_gate_step.dependOn(&windows_help_cmd.step);

        const windows_tty_cmd = b.addSystemCommand(&.{
            "python", "tests/tty/run_tty_tests.py",
            "--bin",  "zig-out/bin/metacodes-debug.exe",
        });
        windows_tty_cmd.setEnvironmentVariable("TTY_SKIP_MODEL", "1");
        windows_tty_cmd.step.dependOn(&install_debug.step);
        windows_tty_cmd.step.dependOn(&install_mock_mcp.step);
        windows_tty_cmd.step.dependOn(&install_replay.step);
        if (windows_test_prelude) |prelude| windows_tty_cmd.step.dependOn(&prelude.step);
        windows_tty_step.dependOn(&windows_tty_cmd.step);
    }

    _ = b.addFmt(.{
        .paths = &.{"src/"},
        .exclude_paths = &.{},
    });
}
