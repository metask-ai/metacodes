const std = @import("std");

const tier_ratio: u64 = 4;
const stack_queue_entries: usize = 64;

/// A contiguous edge-segment window selected for one compaction operation.
/// This is an internal policy result; the storage facade retains public
/// maintenance results and all compaction data-plane ownership.
pub const Window = struct {
    start: usize,
    count: usize,
    edge_count: u64,
    min_segment_edges: u64,
    max_segment_edges: u64,
};

/// Selects the best contiguous segment window within both budgets.
/// Entries need only expose an `edge_count: u64` field, keeping persisted
/// manifest representation outside this policy module.
///
/// The policy prefers a same-tier window, then more edges, then more segments,
/// and finally the newest window. `max_edges == 0` means unbounded. Small
/// segment budgets use fixed stack queues so routine maintenance does not add
/// allocator failure points.
pub fn select(
    allocator: std.mem.Allocator,
    entries: anytype,
    max_segments: usize,
    max_edges: u64,
) !?Window {
    if (entries.len <= 1 or max_segments <= 1) return null;

    var min_queue = std.ArrayList(usize).empty;
    var max_queue = std.ArrayList(usize).empty;
    const queue_capacity = if (max_segments >= entries.len) entries.len else max_segments + 1;
    var stack_queue_storage: [stack_queue_entries * 2]usize = undefined;
    var fixed_queue_allocator = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(stack_queue_storage[0..]));
    const queue_allocator = if (queue_capacity <= stack_queue_entries)
        fixed_queue_allocator.allocator()
    else
        allocator;
    defer min_queue.deinit(queue_allocator);
    defer max_queue.deinit(queue_allocator);
    try min_queue.ensureTotalCapacity(queue_allocator, queue_capacity);
    try max_queue.ensureTotalCapacity(queue_allocator, queue_capacity);
    var min_head: usize = 0;
    var max_head: usize = 0;

    var best: ?Window = null;
    var start: usize = 0;
    var edge_count: u64 = 0;
    for (entries, 0..) |entry, end| {
        edge_count = std.math.add(u64, edge_count, entry.edge_count) catch return error.RecordTooLarge;
        while (min_queue.items.len > min_head and entries[min_queue.items[min_queue.items.len - 1]].edge_count >= entry.edge_count) {
            _ = min_queue.pop();
        }
        compactSlidingIndexQueueIfFull(&min_queue, &min_head);
        min_queue.appendAssumeCapacity(end);
        while (max_queue.items.len > max_head and entries[max_queue.items[max_queue.items.len - 1]].edge_count <= entry.edge_count) {
            _ = max_queue.pop();
        }
        compactSlidingIndexQueueIfFull(&max_queue, &max_head);
        max_queue.appendAssumeCapacity(end);

        while (start <= end and (end - start + 1 > max_segments or (max_edges != 0 and edge_count > max_edges))) {
            if (min_queue.items[min_head] == start) min_head += 1;
            if (max_queue.items[max_head] == start) max_head += 1;
            edge_count -= entries[start].edge_count;
            start += 1;
        }

        const candidate_count = if (start <= end) end - start + 1 else 0;
        if (candidate_count <= 1) continue;
        const candidate = Window{
            .start = start,
            .count = candidate_count,
            .edge_count = edge_count,
            .min_segment_edges = entries[min_queue.items[min_head]].edge_count,
            .max_segment_edges = entries[max_queue.items[max_head]].edge_count,
        };
        if (best == null or better(candidate, best.?)) best = candidate;
    }
    return best;
}

fn compactSlidingIndexQueueIfFull(queue: *std.ArrayList(usize), head: *usize) void {
    if (queue.items.len < queue.capacity or head.* == 0) return;
    const live = queue.items[head.*..];
    std.mem.copyForwards(usize, queue.items[0..live.len], live);
    queue.shrinkRetainingCapacity(live.len);
    head.* = 0;
}

fn isSameTier(window: Window) bool {
    if (window.min_segment_edges == 0) return false;
    const max_same_tier = std.math.mul(u64, window.min_segment_edges, tier_ratio) catch std.math.maxInt(u64);
    return window.max_segment_edges <= max_same_tier;
}

fn better(candidate: Window, current: Window) bool {
    const candidate_same_tier = isSameTier(candidate);
    const current_same_tier = isSameTier(current);
    if (candidate_same_tier != current_same_tier) return candidate_same_tier;
    if (candidate.edge_count != current.edge_count) return candidate.edge_count > current.edge_count;
    if (candidate.count != current.count) return candidate.count > current.count;
    return candidate.start > current.start;
}

const TestEntry = struct {
    edge_count: u64,
};

test "edge segment compaction policy prefers same-tier window over big-small fill" {
    const entries = [_]TestEntry{
        .{ .edge_count = 3 },
        .{ .edge_count = 3 },
        .{ .edge_count = 1 },
        .{ .edge_count = 20 },
    };

    const selected = (try select(std.testing.allocator, &entries, 2, 21)).?;
    try std.testing.expectEqual(@as(usize, 0), selected.start);
    try std.testing.expectEqual(@as(usize, 2), selected.count);
    try std.testing.expectEqual(@as(u64, 6), selected.edge_count);
}

test "edge segment compaction policy maintains tier after window shrink" {
    const entries = [_]TestEntry{
        .{ .edge_count = 50 },
        .{ .edge_count = 2 },
        .{ .edge_count = 2 },
        .{ .edge_count = 20 },
        .{ .edge_count = 20 },
    };

    const selected = (try select(std.testing.allocator, &entries, 2, 40)).?;
    try std.testing.expectEqual(@as(usize, 3), selected.start);
    try std.testing.expectEqual(@as(usize, 2), selected.count);
    try std.testing.expectEqual(@as(u64, 40), selected.edge_count);
    try std.testing.expectEqual(@as(u64, 20), selected.min_segment_edges);
    try std.testing.expectEqual(@as(u64, 20), selected.max_segment_edges);
}

test "edge segment compaction policy keeps the newest tied window" {
    var entries: [64]TestEntry = undefined;
    for (&entries) |*entry| entry.* = .{ .edge_count = 1 };

    const selected = (try select(std.testing.allocator, &entries, 2, 2)).?;
    try std.testing.expectEqual(@as(usize, entries.len - 2), selected.start);
    try std.testing.expectEqual(@as(usize, 2), selected.count);
    try std.testing.expectEqual(@as(u64, 2), selected.edge_count);
}

test "edge segment compaction policy treats zero edge budget as unbounded" {
    const entries = [_]TestEntry{
        .{ .edge_count = 3 },
        .{ .edge_count = 4 },
        .{ .edge_count = 5 },
    };

    const selected = (try select(std.testing.allocator, &entries, 3, 0)).?;
    try std.testing.expectEqual(@as(usize, 0), selected.start);
    try std.testing.expectEqual(@as(usize, 3), selected.count);
    try std.testing.expectEqual(@as(u64, 12), selected.edge_count);
}

test "edge segment compaction policy enforces segment cap" {
    const entries = [_]TestEntry{
        .{ .edge_count = 1 },
        .{ .edge_count = 1 },
        .{ .edge_count = 1 },
        .{ .edge_count = 1 },
    };

    const selected = (try select(std.testing.allocator, &entries, 3, 0)).?;
    try std.testing.expectEqual(@as(usize, 1), selected.start);
    try std.testing.expectEqual(@as(usize, 3), selected.count);
    try std.testing.expectEqual(@as(u64, 3), selected.edge_count);
}

test "edge segment compaction policy uses stack queues for small windows" {
    var entries: [128]TestEntry = undefined;
    for (&entries) |*entry| entry.* = .{ .edge_count = 1 };

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const selected = (try select(failing.allocator(), &entries, 2, 2)).?;
    try std.testing.expectEqual(@as(usize, entries.len - 2), selected.start);
    try std.testing.expectEqual(@as(usize, 2), selected.count);
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "edge segment compaction policy rejects edge-count overflow" {
    const entries = [_]TestEntry{
        .{ .edge_count = std.math.maxInt(u64) },
        .{ .edge_count = 1 },
    };
    try std.testing.expectError(
        error.RecordTooLarge,
        select(std.testing.allocator, &entries, 2, 0),
    );
}
