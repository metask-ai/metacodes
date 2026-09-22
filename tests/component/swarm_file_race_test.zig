//! Regression coverage for the swarm config/mailbox replace/read race.

const std = @import("std");
const cc = @import("cc");

const team = cc.swarm_team;

const WRITE_COUNT: usize = 512;
const BODY_A = "{\"name\":\"proj-a\",\"leadAgentId\":\"team-lead@proj\",\"members\":[]}";
const BODY_B = "{\"name\":\"proj-b\",\"leadAgentId\":\"team-lead@proj\",\"members\":[]}";

const Writer = struct {
    path: []const u8,
    writes: *std.atomic.Value(usize),
    failed: *std.atomic.Value(bool),

    fn run(self: *Writer) void {
        for (0..WRITE_COUNT) |i| {
            team.atomicWrite(self.path, if ((i & 1) == 0) BODY_A else BODY_B) catch {
                self.failed.store(true, .release);
                return;
            };
            _ = self.writes.fetchAdd(1, .monotonic);
        }
    }
};

test "swarm file protocol race: atomicWrite and load stay valid during replacement" {
    const a = std.testing.allocator;
    var home_buf: [256]u8 = undefined;
    const home = cc.util_fs.testing.uniqueDir(&home_buf, "cc-zig-swarm-file-race");
    defer cc.util_fs.testing.rmrfBestEffort(home);
    try cc.util_fs.mkdirParents(home);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/config.json", .{home});
    try team.atomicWrite(path, BODY_A);

    var writes = std.atomic.Value(usize).init(0);
    var write_failed = std.atomic.Value(bool).init(false);
    var read_failed = std.atomic.Value(bool).init(false);
    var worker = Writer{ .path = path, .writes = &writes, .failed = &write_failed };
    var thread = try std.Thread.spawn(.{}, Writer.run, .{&worker});

    for (0..WRITE_COUNT) |_| {
        var tf = team.load(a, path) orelse {
            read_failed.store(true, .release);
            continue;
        };
        if (!std.mem.eql(u8, tf.lead_agent_id, "team-lead@proj") or
            (std.mem.eql(u8, tf.name, "proj-a") == false and std.mem.eql(u8, tf.name, "proj-b") == false))
        {
            read_failed.store(true, .release);
        }
        tf.deinit();
    }

    thread.join();
    try std.testing.expect(!write_failed.load(.acquire));
    try std.testing.expect(!read_failed.load(.acquire));
    try std.testing.expectEqual(WRITE_COUNT, writes.load(.acquire));
}
