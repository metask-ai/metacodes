//! Zero-provider microbenchmark for the immutable plugin composition boundary.
//!
//! This measures Runtime snapshot publication, not model quality. It is a
//! release regression gate for the cost paid once per Runtime generation;
//! AgentLoop's per-turn hot path is deliberately absent from this benchmark.

const std = @import("std");
const mc = @import("metacodes-core");

const SAMPLE_COUNT: usize = 128;
const OPERATIONS_PER_SAMPLE: usize = 200;
const WARMUP_OPERATIONS: usize = 200;
const MAX_STATIC_PLUGIN_P95_OVERHEAD_NS: u64 = 50_000;
const MAX_INVENTORY_AVG_NS: u64 = 100_000;

const Host = struct {
    fn execute(
        raw: *anyopaque,
        _: mc.agent_session.HostRunIdentity,
        _: []const u8,
    ) error{OutOfMemory}!mc.agent_session.HostToolOutcome {
        return .{ .ok = .{
            .bytes = "ok",
            .release_ctx = raw,
            .releaseFn = release,
        } };
    }

    fn release(_: *anyopaque, _: []const u8) void {}

    fn tool(self: *Host) mc.agent_session.HostSyncTool {
        return .{
            .definition = .{
                .name = "Probe",
                .description = "Benchmark-only trusted Host tool",
                .input_schema = .{ .type = "object" },
            },
            .ctx = self,
            .execute = execute,
            .category = .read,
        };
    }
};

fn lessThan(_: void, lhs: u64, rhs: u64) bool {
    return lhs < rhs;
}

fn snapshotOnce(
    allocator: std.mem.Allocator,
    plugins: []const mc.agent_session.StaticPlugin,
) !void {
    const snapshot = try mc.plugin.runtime.Snapshot.create(allocator, .{
        .generation = @enumFromInt(1),
        .supported_capabilities = mc.plugin.contract.CapabilitySet.from(&.{.host_tool}),
        .static_plugins = plugins,
    });
    snapshot.destroy();
}

fn measureBlock(
    io: std.Io,
    allocator: std.mem.Allocator,
    plugins: []const mc.agent_session.StaticPlugin,
) !u64 {
    const started = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..OPERATIONS_PER_SAMPLE) |_| try snapshotOnce(allocator, plugins);
    const finished = std.Io.Clock.awake.now(io).nanoseconds;
    return @intCast(finished - started);
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var host = Host{};
    const plugins = [_]mc.agent_session.StaticPlugin{.{
        .descriptor = .{
            .id = try mc.plugin.contract.PluginId.parse("bench.static"),
            .version = try mc.plugin.contract.Version.parse("1.0.0"),
            .form = .static_trusted,
            .capabilities = mc.plugin.contract.CapabilitySet.from(&.{.host_tool}),
        },
        .tools = &.{host.tool()},
    }};

    for (0..WARMUP_OPERATIONS) |index| {
        try snapshotOnce(allocator, if (index % 2 == 0) &.{} else &plugins);
    }

    var baseline_samples: [SAMPLE_COUNT]u64 = undefined;
    var plugin_samples: [SAMPLE_COUNT]u64 = undefined;
    var baseline_total: u64 = 0;
    var plugin_total: u64 = 0;
    for (0..SAMPLE_COUNT) |index| {
        // Alternate order to avoid assigning thermal/frequency drift to one arm.
        if (index % 2 == 0) {
            baseline_samples[index] = try measureBlock(init.io, allocator, &.{});
            plugin_samples[index] = try measureBlock(init.io, allocator, &plugins);
        } else {
            plugin_samples[index] = try measureBlock(init.io, allocator, &plugins);
            baseline_samples[index] = try measureBlock(init.io, allocator, &.{});
        }
        baseline_total += baseline_samples[index];
        plugin_total += plugin_samples[index];
    }
    std.mem.sort(u64, &baseline_samples, {}, lessThan);
    std.mem.sort(u64, &plugin_samples, {}, lessThan);
    const p95_index = (SAMPLE_COUNT * 95 + 99) / 100 - 1;
    const baseline_avg_ns = baseline_total / (SAMPLE_COUNT * OPERATIONS_PER_SAMPLE);
    const plugin_avg_ns = plugin_total / (SAMPLE_COUNT * OPERATIONS_PER_SAMPLE);
    const baseline_p95_ns = baseline_samples[p95_index] / OPERATIONS_PER_SAMPLE;
    const plugin_p95_ns = plugin_samples[p95_index] / OPERATIONS_PER_SAMPLE;
    const overhead_p95_ns = plugin_p95_ns -| baseline_p95_ns;

    const snapshot = try mc.plugin.runtime.Snapshot.create(allocator, .{
        .generation = @enumFromInt(1),
        .supported_capabilities = mc.plugin.contract.CapabilitySet.from(&.{.host_tool}),
        .static_plugins = &plugins,
    });
    defer snapshot.destroy();
    const inventory_started = std.Io.Clock.awake.now(init.io).nanoseconds;
    var inventory_bytes: usize = 0;
    for (0..SAMPLE_COUNT * OPERATIONS_PER_SAMPLE) |_| {
        const inventory = try snapshot.describe(allocator);
        inventory_bytes = inventory.len;
        allocator.free(inventory);
    }
    const inventory_finished = std.Io.Clock.awake.now(init.io).nanoseconds;
    const inventory_avg_ns: u64 = @intCast(
        @divTrunc(
            inventory_finished - inventory_started,
            SAMPLE_COUNT * OPERATIONS_PER_SAMPLE,
        ),
    );

    const passed = overhead_p95_ns <= MAX_STATIC_PLUGIN_P95_OVERHEAD_NS and
        inventory_avg_ns <= MAX_INVENTORY_AVG_NS;
    std.debug.print(
        "{{\"schema\":\"metacodes.plugin-benchmark/v1\",\"quality_evidence\":false," ++
            "\"samples\":{d},\"operations_per_sample\":{d}," ++
            "\"baseline_avg_ns\":{d},\"baseline_p95_ns\":{d}," ++
            "\"static_plugin_avg_ns\":{d},\"static_plugin_p95_ns\":{d}," ++
            "\"static_plugin_p95_overhead_ns\":{d}," ++
            "\"inventory_avg_ns\":{d},\"inventory_bytes\":{d}," ++
            "\"thresholds\":{{\"max_static_plugin_p95_overhead_ns\":{d}," ++
            "\"max_inventory_avg_ns\":{d}}},\"passed\":{}}}\n",
        .{
            SAMPLE_COUNT,
            OPERATIONS_PER_SAMPLE,
            baseline_avg_ns,
            baseline_p95_ns,
            plugin_avg_ns,
            plugin_p95_ns,
            overhead_p95_ns,
            inventory_avg_ns,
            inventory_bytes,
            MAX_STATIC_PLUGIN_P95_OVERHEAD_NS,
            MAX_INVENTORY_AVG_NS,
            passed,
        },
    );
    if (!passed) return error.PluginPerformanceRegression;
}
