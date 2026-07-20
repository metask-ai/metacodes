const std = @import("std");
const builtin = @import("builtin");
const manifest_contract = @import("manifest_contract.zig");

const Manifest = manifest_contract.Manifest;

fn verifySha256(b: *std.Build, path: []const u8, expected: []const u8) void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .limited(128 * 1024 * 1024)) catch
        @panic("cannot read AgentCore bundle file");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, expected)) @panic("AgentCore bundle SHA-256 mismatch");
}

fn verifyBundleEntries(b: *std.Build, bundle_root: []const u8, library_path: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(b.graph.io, bundle_root, .{ .iterate = true }) catch
        @panic("cannot open AgentCore bundle root");
    defer dir.close(b.graph.io);
    var walker = dir.walk(b.allocator) catch @panic("cannot walk AgentCore bundle root");
    defer walker.deinit();
    var entries = std.ArrayList(manifest_contract.BundleEntry).empty;
    while (walker.next(b.graph.io) catch @panic("cannot walk AgentCore bundle root")) |entry| {
        const kind: manifest_contract.EntryKind = switch (entry.kind) {
            .file => .file,
            .directory => .directory,
            else => .other,
        };
        const path = b.allocator.dupe(u8, entry.path) catch @panic("OOM");
        manifest_contract.normalizePathSeparators(path);
        entries.append(b.allocator, .{ .path = path, .kind = kind }) catch @panic("OOM");
    }
    manifest_contract.validateBundleEntries(entries.items, library_path) catch |err|
        std.debug.panic("invalid AgentCore bundle entry set: {s}", .{@errorName(err)});
}

fn applySystemLinkInputs(module: *std.Build.Module, inputs: []const []const u8) void {
    for (inputs) |input| {
        if (std.mem.eql(u8, input, "libc")) {
            module.link_libc = true;
        } else {
            module.linkSystemLibrary(input, .{ .use_pkg_config = .no });
        }
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bundle_root = b.option([]const u8, "bundle-root", "Installed AgentCore bundle root") orelse
        @panic("-Dbundle-root is required");
    const library_file = b.option([]const u8, "library-file", "Target AgentCore static library filename") orelse
        @panic("-Dlibrary-file is required");
    const require_clean = b.option(bool, "require-clean-bundle", "Require a clean bundle with the expected commit") orelse false;
    const expected_commit = b.option([]const u8, "expected-commit", "Expected full metacodes commit for a clean bundle");
    const expected_strip = b.option(bool, "expected-strip", "Expected AgentCore strip setting") orelse
        @panic("-Dexpected-strip is required");
    const library_rel_path = b.fmt("lib/{s}", .{library_file});
    const lib_path = b.pathJoin(&.{ bundle_root, "lib", library_file });
    const header_path = b.pathJoin(&.{ bundle_root, "include", "metask_agentcore.h" });
    const sdk_path = b.pathJoin(&.{ bundle_root, "sdk", "metask_agentcore.zig" });
    const protocol_path = b.pathJoin(&.{ bundle_root, "sdk", "metask_agentcore_protocol.zig" });
    const types_path = b.pathJoin(&.{ bundle_root, "sdk", "metask_agentcore_types.zig" });
    const manifest_path = b.pathJoin(&.{ bundle_root, "manifest.json" });
    const manifest_bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, manifest_path, b.allocator, .limited(1024 * 1024)) catch
        @panic("cannot read AgentCore manifest.json");
    const manifest = std.json.parseFromSlice(Manifest, b.allocator, manifest_bytes, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch
        @panic("invalid AgentCore manifest.json");
    defer manifest.deinit();
    const resolved_target = target.result.zigTriple(b.allocator) catch @panic("OOM");
    manifest_contract.validateManifest(manifest.value, .{
        .resolved_target = resolved_target,
        .architecture = @tagName(target.result.cpu.arch),
        .os = @tagName(target.result.os.tag),
        .abi = @tagName(target.result.abi),
        .optimize = @tagName(optimize),
        .strip = expected_strip,
        .zig_version = builtin.zig_version_string,
        .require_clean = require_clean,
        .commit = expected_commit,
    }) catch |err| std.debug.panic("invalid AgentCore manifest identity: {s}", .{@errorName(err)});
    manifest_contract.validateManifestFiles(manifest.value.files, library_rel_path) catch |err|
        std.debug.panic("invalid AgentCore manifest file set: {s}", .{@errorName(err)});
    verifyBundleEntries(b, bundle_root, library_rel_path);

    verifySha256(b, lib_path, manifest_contract.fileSha256(manifest.value.files, library_rel_path).?);
    verifySha256(b, header_path, manifest_contract.fileSha256(manifest.value.files, "include/metask_agentcore.h").?);
    verifySha256(b, sdk_path, manifest_contract.fileSha256(manifest.value.files, "sdk/metask_agentcore.zig").?);
    verifySha256(b, protocol_path, manifest_contract.fileSha256(manifest.value.files, "sdk/metask_agentcore_protocol.zig").?);
    verifySha256(b, types_path, manifest_contract.fileSha256(manifest.value.files, "sdk/metask_agentcore_types.zig").?);

    const types = b.createModule(.{ .root_source_file = .{ .cwd_relative = types_path }, .target = target, .optimize = optimize });
    const protocol = b.createModule(.{ .root_source_file = .{ .cwd_relative = protocol_path }, .target = target, .optimize = optimize });
    const sdk = b.createModule(.{ .root_source_file = .{ .cwd_relative = sdk_path }, .target = target, .optimize = optimize });
    sdk.addImport("metask_agentcore_types", types);
    sdk.addImport("metask_agentcore_protocol", protocol);

    const zig_link_probe = b.createModule(.{
        .root_source_file = b.path("link_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    zig_link_probe.addImport("metask_agentcore", sdk);
    zig_link_probe.addObjectFile(.{ .cwd_relative = lib_path });
    applySystemLinkInputs(zig_link_probe, manifest.value.contract.required_system_link_inputs);
    const zig_link_exe = b.addExecutable(.{ .name = "agentcore-artifact-zig-link-probe", .root_module = zig_link_probe });

    const c_link_probe = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    c_link_probe.addCSourceFile(.{ .file = b.path("link_probe.c"), .flags = &.{"-std=c11"} });
    c_link_probe.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ bundle_root, "include" }) });
    c_link_probe.addObjectFile(.{ .cwd_relative = lib_path });
    applySystemLinkInputs(c_link_probe, manifest.value.contract.required_system_link_inputs);
    const c_link_exe = b.addExecutable(.{ .name = "agentcore-artifact-c-link-probe", .root_module = c_link_probe });

    const cpp_link_probe = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    cpp_link_probe.addCSourceFile(.{ .file = b.path("link_probe.cpp"), .flags = &.{"-std=c++17"} });
    cpp_link_probe.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ bundle_root, "include" }) });
    cpp_link_probe.addObjectFile(.{ .cwd_relative = lib_path });
    applySystemLinkInputs(cpp_link_probe, manifest.value.contract.required_system_link_inputs);
    const cpp_link_exe = b.addExecutable(.{ .name = "agentcore-artifact-cpp-link-probe", .root_module = cpp_link_probe });
    const cpp_run = b.addRunArtifact(cpp_link_exe);

    const app = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    app.addImport("metask_agentcore", sdk);
    app.addObjectFile(.{ .cwd_relative = lib_path });
    applySystemLinkInputs(app, manifest.value.contract.required_system_link_inputs);
    const exe = b.addExecutable(.{ .name = "agentcore-artifact-consumer", .root_module = app });
    const run = b.addRunArtifact(exe);

    const c_app = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    c_app.addCSourceFile(.{ .file = b.path("consumer.c"), .flags = &.{"-std=c11"} });
    c_app.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ bundle_root, "include" }) });
    c_app.addObjectFile(.{ .cwd_relative = lib_path });
    applySystemLinkInputs(c_app, manifest.value.contract.required_system_link_inputs);
    // The C test's loopback mock server uses Winsock directly. This is a test
    // dependency, not an AgentCore library link input recorded in the manifest.
    if (target.result.os.tag == .windows)
        c_app.linkSystemLibrary("ws2_32", .{ .use_pkg_config = .no });
    const c_exe = b.addExecutable(.{ .name = "agentcore-artifact-c-consumer", .root_module = c_app });
    const c_run = b.addRunArtifact(c_exe);

    const link_step = b.step("link", "Link source-free Zig, C and C++ consumers");
    link_step.dependOn(&zig_link_exe.step);
    link_step.dependOn(&c_link_exe.step);
    link_step.dependOn(&cpp_link_exe.step);

    const test_step = b.step("test", "Link and run using only the installed AgentCore bundle");
    test_step.dependOn(&run.step);
    test_step.dependOn(&c_run.step);
    test_step.dependOn(&cpp_run.step);
}
