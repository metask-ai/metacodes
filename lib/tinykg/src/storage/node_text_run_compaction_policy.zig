const std = @import("std");

const tier_ratio: u64 = 4;
const stack_queue_entries: usize = 64;

/// A contiguous node-text run window selected for one compaction operation.
/// This is an internal policy result; the storage facade retains public
/// maintenance result types and all compaction data-plane ownership.
pub const Window = struct {
    start: usize,
    count: usize,
    records: u64,
    min_run_records: u64,
    max_run_records: u64,
};

/// Selects the best contiguous run window within `selected_limit` records.
/// Entries need only expose a `node_count: u64` field, keeping persisted
/// manifest representation outside this policy module.
///
/// The policy prefers a same-tier window, then more records, then more runs,
/// and finally the oldest window. Zero-sized and over-budget runs split the
/// candidate stream. Small budgets use fixed stack queues so normal
/// maintenance does not add allocator failure points.
pub fn select(allocator: std.mem.Allocator, entries: anytype, selected_limit: u64) !?Window {
    if (entries.len < 2 or selected_limit == 0) return null;

    var min_queue = std.ArrayList(usize).empty;
    var max_queue = std.ArrayList(usize).empty;
    const max_window_entries = if (selected_limit >= entries.len)
        entries.len
    else
        @as(usize, @intCast(selected_limit)) + 1;
    var stack_queue_storage: [stack_queue_entries * 2]usize = undefined;
    var fixed_queue_allocator = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(stack_queue_storage[0..]));
    const queue_allocator = if (max_window_entries <= stack_queue_entries)
        fixed_queue_allocator.allocator()
    else
        allocator;
    defer min_queue.deinit(queue_allocator);
    defer max_queue.deinit(queue_allocator);
    try min_queue.ensureTotalCapacity(queue_allocator, max_window_entries);
    try max_queue.ensureTotalCapacity(queue_allocator, max_window_entries);
    var min_head: usize = 0;
    var max_head: usize = 0;

    var best: ?Window = null;
    var start: usize = 0;
    var records: u64 = 0;
    for (entries, 0..) |entry, end| {
        const entry_records = entry.node_count;
        if (entry_records == 0 or entry_records > selected_limit) {
            min_queue.clearRetainingCapacity();
            max_queue.clearRetainingCapacity();
            min_head = 0;
            max_head = 0;
            start = end + 1;
            records = 0;
            continue;
        }

        records = std.math.add(u64, records, entry_records) catch return error.RecordTooLarge;
        while (min_queue.items.len > min_head and entries[min_queue.items[min_queue.items.len - 1]].node_count >= entry_records) {
            _ = min_queue.pop();
        }
        compactSlidingIndexQueueIfFull(&min_queue, &min_head);
        min_queue.appendAssumeCapacity(end);
        while (max_queue.items.len > max_head and entries[max_queue.items[max_queue.items.len - 1]].node_count <= entry_records) {
            _ = max_queue.pop();
        }
        compactSlidingIndexQueueIfFull(&max_queue, &max_head);
        max_queue.appendAssumeCapacity(end);

        while (start <= end and records > selected_limit) {
            if (min_queue.items[min_head] == start) min_head += 1;
            if (max_queue.items[max_head] == start) max_head += 1;
            records -= entries[start].node_count;
            start += 1;
        }

        const candidate_count = if (start <= end) end - start + 1 else 0;
        if (candidate_count < 2) continue;
        const candidate = Window{
            .start = start,
            .count = candidate_count,
            .records = records,
            .min_run_records = entries[min_queue.items[min_head]].node_count,
            .max_run_records = entries[max_queue.items[max_head]].node_count,
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
    if (window.min_run_records == 0) return false;
    const max_same_tier = std.math.mul(u64, window.min_run_records, tier_ratio) catch std.math.maxInt(u64);
    return window.max_run_records <= max_same_tier;
}

fn better(candidate: Window, current: Window) bool {
    const candidate_same_tier = isSameTier(candidate);
    const current_same_tier = isSameTier(current);
    if (candidate_same_tier != current_same_tier) return candidate_same_tier;
    if (candidate.records != current.records) return candidate.records > current.records;
    if (candidate.count != current.count) return candidate.count > current.count;
    return candidate.start < current.start;
}

const TestEntry = struct {
    node_count: u64,
};

test "node text run compaction policy prefers same-tier window over big-small fill" {
    const entries = [_]TestEntry{
        .{ .node_count = 5 },
        .{ .node_count = 5 },
        .{ .node_count = 1 },
        .{ .node_count = 20 },
    };

    const selected = (try select(std.testing.allocator, &entries, 21)).?;
    try std.testing.expectEqual(@as(usize, 0), selected.start);
    try std.testing.expectEqual(@as(usize, 2), selected.count);
    try std.testing.expectEqual(@as(u64, 10), selected.records);
    try std.testing.expectEqual(@as(u64, 5), selected.min_run_records);
    try std.testing.expectEqual(@as(u64, 5), selected.max_run_records);
}

test "node text run compaction policy maintains tier after window shrink" {
    const entries = [_]TestEntry{
        .{ .node_count = 50 },
        .{ .node_count = 2 },
        .{ .node_count = 2 },
        .{ .node_count = 20 },
        .{ .node_count = 20 },
    };

    const selected = (try select(std.testing.allocator, &entries, 40)).?;
    try std.testing.expectEqual(@as(usize, 3), selected.start);
    try std.testing.expectEqual(@as(usize, 2), selected.count);
    try std.testing.expectEqual(@as(u64, 40), selected.records);
    try std.testing.expectEqual(@as(u64, 20), selected.min_run_records);
    try std.testing.expectEqual(@as(u64, 20), selected.max_run_records);
}

test "node text run compaction policy keeps the oldest tied window" {
    var entries: [64]TestEntry = undefined;
    for (&entries) |*entry| entry.* = .{ .node_count = 1 };

    const selected = (try select(std.testing.allocator, &entries, 2)).?;
    try std.testing.expectEqual(@as(usize, 0), selected.start);
    try std.testing.expectEqual(@as(usize, 2), selected.count);
    try std.testing.expectEqual(@as(u64, 2), selected.records);
}

test "node text run compaction policy uses stack queues for small windows" {
    var entries: [128]TestEntry = undefined;
    for (&entries) |*entry| entry.* = .{ .node_count = 1 };

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const selected = (try select(failing.allocator(), &entries, 2)).?;
    try std.testing.expectEqual(@as(usize, 0), selected.start);
    try std.testing.expectEqual(@as(usize, 2), selected.count);
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "node text run compaction policy resets at invalid and over-limit runs" {
    const entries = [_]TestEntry{
        .{ .node_count = 2 },
        .{ .node_count = 0 },
        .{ .node_count = 2 },
        .{ .node_count = 2 },
        .{ .node_count = 9 },
        .{ .node_count = 2 },
        .{ .node_count = 2 },
    };

    const selected = (try select(std.testing.allocator, &entries, 4)).?;
    try std.testing.expectEqual(@as(usize, 2), selected.start);
    try std.testing.expectEqual(@as(usize, 2), selected.count);
    try std.testing.expectEqual(@as(u64, 4), selected.records);
}

test "node text run compaction policy rejects record-count overflow" {
    const entries = [_]TestEntry{
        .{ .node_count = std.math.maxInt(u64) },
        .{ .node_count = 1 },
    };
    try std.testing.expectError(error.RecordTooLarge, select(std.testing.allocator, &entries, std.math.maxInt(u64)));
}
