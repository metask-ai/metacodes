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

fn verifyManifestFileSet(b: *std.Build, manifest_bytes: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, b.allocator, manifest_bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch @panic("invalid AgentCore manifest JSON");
    defer parsed.deinit();
    if (parsed.value != .object) @panic("AgentCore manifest root must be an object");
    const files = parsed.value.object.get("files") orelse @panic("AgentCore manifest files object is required");
    if (files != .object) @panic("AgentCore manifest files must be an object");
    var paths = std.ArrayList([]const u8).empty;
    var iterator = files.object.iterator();
    while (iterator.next()) |entry| paths.append(b.allocator, entry.key_ptr.*) catch @panic("OOM");
    manifest_contract.validateManifestFiles(paths.items) catch |err|
        std.debug.panic("invalid AgentCore manifest file set: {s}", .{@errorName(err)});
}

fn verifyBundleEntries(b: *std.Build, bundle_root: []const u8) void {
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
        entries.append(b.allocator, .{ .path = path, .kind = kind }) catch @panic("OOM");
    }
    manifest_contract.validateBundleEntries(entries.items) catch |err|
        std.debug.panic("invalid AgentCore bundle entry set: {s}", .{@errorName(err)});
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bundle_root = b.option([]const u8, "bundle-root", "Installed AgentCore bundle root") orelse
        @panic("-Dbundle-root is required");
    const require_clean = b.option(bool, "require-clean-bundle", "Require a clean bundle with the expected commit") orelse false;
    const expected_commit = b.option([]const u8, "expected-commit", "Expected full metacodes commit for a clean bundle");
    const expected_strip = b.option(bool, "expected-strip", "Expected AgentCore strip setting") orelse
        @panic("-Dexpected-strip is required");
    const lib_path = b.pathJoin(&.{ bundle_root, "lib", "libmetacodes_agentcore.a" });
    const header_path = b.pathJoin(&.{ bundle_root, "include", "metacodes_agentcore.h" });
    const sdk_path = b.pathJoin(&.{ bundle_root, "sdk", "metacodes_agentcore.zig" });
    const protocol_path = b.pathJoin(&.{ bundle_root, "sdk", "metacodes_agentcore_protocol.zig" });
    const types_path = b.pathJoin(&.{ bundle_root, "sdk", "metacodes_agentcore_types.zig" });
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
        .optimize = @tagName(optimize),
        .strip = expected_strip,
        .zig_version = builtin.zig_version_string,
        .require_clean = require_clean,
        .commit = expected_commit,
    }) catch |err| std.debug.panic("invalid AgentCore manifest identity: {s}", .{@errorName(err)});
    verifyManifestFileSet(b, manifest_bytes);
    verifyBundleEntries(b, bundle_root);

    verifySha256(b, lib_path, manifest.value.files.@"lib/libmetacodes_agentcore.a".sha256);
    verifySha256(b, header_path, manifest.value.files.@"include/metacodes_agentcore.h".sha256);
    verifySha256(b, sdk_path, manifest.value.files.@"sdk/metacodes_agentcore.zig".sha256);
    verifySha256(b, protocol_path, manifest.value.files.@"sdk/metacodes_agentcore_protocol.zig".sha256);
    verifySha256(b, types_path, manifest.value.files.@"sdk/metacodes_agentcore_types.zig".sha256);
    const link_libc = true;

    const types = b.createModule(.{ .root_source_file = .{ .cwd_relative = types_path }, .target = target, .optimize = optimize });
    const protocol = b.createModule(.{ .root_source_file = .{ .cwd_relative = protocol_path }, .target = target, .optimize = optimize });
    const sdk = b.createModule(.{ .root_source_file = .{ .cwd_relative = sdk_path }, .target = target, .optimize = optimize });
    sdk.addImport("metacodes_agentcore_types", types);
    sdk.addImport("metacodes_agentcore_protocol", protocol);
    const app = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    app.addImport("metacodes_agentcore", sdk);
    app.addObjectFile(.{ .cwd_relative = lib_path });
    const exe = b.addExecutable(.{ .name = "agentcore-artifact-consumer", .root_module = app });
    const run = b.addRunArtifact(exe);

    const c_app = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    c_app.addCSourceFile(.{ .file = b.path("consumer.c"), .flags = &.{"-std=c11"} });
    c_app.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ bundle_root, "include" }) });
    c_app.addObjectFile(.{ .cwd_relative = lib_path });
    const c_exe = b.addExecutable(.{ .name = "agentcore-artifact-c-consumer", .root_module = c_app });
    const c_run = b.addRunArtifact(c_exe);

    const test_step = b.step("test", "Link and run using only the installed AgentCore bundle");
    test_step.dependOn(&run.step);
    test_step.dependOn(&c_run.step);
}
