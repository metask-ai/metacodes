const std = @import("std");

const Manifest = struct {
    schema_version: u32,
    vendor: []const u8,
    name: []const u8,
    target: struct { zig_target: []const u8 },
    link: struct {
        requires_c_runtime: bool,
        system_libraries: []const []const u8,
        system_frameworks: []const []const u8,
    },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const package_root = b.pathResolve(&.{ b.build_root.path orelse ".", "../.." });
    const manifest_path = b.pathJoin(&.{ package_root, "manifest.json" });
    const manifest_bytes = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        manifest_path,
        b.allocator,
        .limited(1024 * 1024),
    ) catch @panic("cannot read AgentCore bundle manifest.json");
    const parsed = std.json.parseFromSlice(Manifest, b.allocator, manifest_bytes, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch @panic("invalid AgentCore bundle manifest.json");
    defer parsed.deinit();
    validateManifestIdentity(parsed.value.schema_version, parsed.value.vendor, parsed.value.name) catch
        @panic("unexpected AgentCore bundle manifest identity");

    const resolved_target = target.result.zigTriple(b.allocator) catch @panic("OOM");
    validateTarget(resolved_target, parsed.value.target.zig_target) catch
        std.debug.panic(
            "AgentCore bundle target mismatch: consumer={s}, bundle={s}",
            .{ resolved_target, parsed.value.target.zig_target },
        );

    const library_file = if (target.result.os.tag == .windows)
        "metask_agentcore.lib"
    else
        "libmetask_agentcore.a";
    const library_path = b.pathJoin(&.{ package_root, "lib", library_file });
    const types = b.createModule(.{
        .root_source_file = b.path("src/types.zig"),
        .target = target,
        .optimize = optimize,
    });
    const protocol = b.createModule(.{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const module = b.addModule("metask_agentcore", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("metask_agentcore_types", types);
    module.addImport("metask_agentcore_protocol", protocol);
    module.addObjectFile(.{ .cwd_relative = library_path });
    module.link_libc = parsed.value.link.requires_c_runtime;
    for (parsed.value.link.system_libraries) |library|
        module.linkSystemLibrary(library, .{ .use_pkg_config = .no });
    for (parsed.value.link.system_frameworks) |framework|
        module.linkFramework(framework, .{});

    const check_source = b.addWriteFiles().add("agentcore_package_check.zig",
        \\const agentcore = @import("metask_agentcore");
        \\pub fn main() !void {
        \\    _ = try agentcore.Api.discover();
        \\}
        \\
    );
    const check_module = b.createModule(.{
        .root_source_file = check_source,
        .target = target,
        .optimize = optimize,
    });
    check_module.addImport("metask_agentcore", module);
    const check_exe = b.addExecutable(.{ .name = "metask-agentcore-package-check", .root_module = check_module });
    const check_step = b.step("check", "Compile and link a source-free AgentCore Zig consumer");
    check_step.dependOn(&check_exe.step);
}

fn validateTarget(consumer: []const u8, bundle: []const u8) error{TargetMismatch}!void {
    if (!std.mem.eql(u8, consumer, bundle)) return error.TargetMismatch;
}

fn validateManifestIdentity(schema_version: u32, vendor: []const u8, name: []const u8) error{InvalidManifestIdentity}!void {
    if (schema_version != 1 or !std.mem.eql(u8, vendor, "metask") or !std.mem.eql(u8, name, "agentcore"))
        return error.InvalidManifestIdentity;
}

test "bundle target requires exact resolved Zig target" {
    try validateTarget("x86_64-windows-msvc", "x86_64-windows-msvc");
    try std.testing.expectError(
        error.TargetMismatch,
        validateTarget("x86_64-linux-gnu", "x86_64-windows-msvc"),
    );
}

test "Zig package rejects another manifest identity" {
    try validateManifestIdentity(1, "metask", "agentcore");
    try std.testing.expectError(
        error.InvalidManifestIdentity,
        validateManifestIdentity(1, "metask", "metacodes"),
    );
}
