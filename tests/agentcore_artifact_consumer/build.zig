const std = @import("std");

const Manifest = struct {
    build: struct {
        architecture: []const u8,
        macos_deployment_target: []const u8,
    },
    contract: struct {
        required_system_link_inputs: []const []const u8,
    },
    files: struct {
        @"lib/libmetacodes_agentcore.a": struct { sha256: []const u8 },
        @"include/metacodes_agentcore.h": struct { sha256: []const u8 },
        @"sdk/metacodes_agentcore.zig": struct { sha256: []const u8 },
        @"sdk/metacodes_agentcore_types.zig": struct { sha256: []const u8 },
    },
};

fn verifySha256(b: *std.Build, path: []const u8, expected: []const u8) void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .limited(128 * 1024 * 1024)) catch
        @panic("cannot read AgentCore bundle file");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, expected)) @panic("AgentCore bundle SHA-256 mismatch");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bundle_root = b.option([]const u8, "bundle-root", "Installed AgentCore bundle root") orelse
        @panic("-Dbundle-root is required");
    const lib_path = b.pathJoin(&.{ bundle_root, "lib", "libmetacodes_agentcore.a" });
    const header_path = b.pathJoin(&.{ bundle_root, "include", "metacodes_agentcore.h" });
    const sdk_path = b.pathJoin(&.{ bundle_root, "sdk", "metacodes_agentcore.zig" });
    const types_path = b.pathJoin(&.{ bundle_root, "sdk", "metacodes_agentcore_types.zig" });
    const manifest_path = b.pathJoin(&.{ bundle_root, "manifest.json" });
    const manifest_bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, manifest_path, b.allocator, .limited(1024 * 1024)) catch
        @panic("cannot read AgentCore manifest.json");
    const manifest = std.json.parseFromSlice(Manifest, b.allocator, manifest_bytes, .{ .ignore_unknown_fields = true }) catch
        @panic("invalid AgentCore manifest.json");
    const resolved_target = target.result.zigTriple(b.allocator) catch @panic("OOM");
    const expected_prefix = b.fmt("{s}-macos.{s}", .{ manifest.value.build.architecture, manifest.value.build.macos_deployment_target });
    if (!std.mem.startsWith(u8, resolved_target, expected_prefix)) @panic("consumer target does not match bundle target");

    verifySha256(b, lib_path, manifest.value.files.@"lib/libmetacodes_agentcore.a".sha256);
    verifySha256(b, header_path, manifest.value.files.@"include/metacodes_agentcore.h".sha256);
    verifySha256(b, sdk_path, manifest.value.files.@"sdk/metacodes_agentcore.zig".sha256);
    verifySha256(b, types_path, manifest.value.files.@"sdk/metacodes_agentcore_types.zig".sha256);
    var link_libc = false;
    for (manifest.value.contract.required_system_link_inputs) |input| {
        if (std.mem.eql(u8, input, "libc")) link_libc = true else @panic("unsupported system link input");
    }

    const types = b.createModule(.{ .root_source_file = .{ .cwd_relative = types_path }, .target = target, .optimize = optimize });
    const sdk = b.createModule(.{ .root_source_file = .{ .cwd_relative = sdk_path }, .target = target, .optimize = optimize });
    sdk.addImport("metacodes_agentcore_types", types);
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
    const test_step = b.step("test", "Link and run using only the installed AgentCore bundle");
    test_step.dependOn(&run.step);
}
