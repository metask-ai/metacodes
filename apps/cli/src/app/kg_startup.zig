const std = @import("std");
const kg_client = @import("metacodes-internal").kg.client;
const inject = @import("metacodes-internal").kg.inject;
const AbortSignal = @import("metacodes-internal").util.abort.AbortSignal;

const KgClient = kg_client.KgClient;
const FrontierRow = kg_client.FrontierRow;

pub const INBOX_MIRROR_LIMIT: usize = 50;

pub const Outcome = struct {
    summary: []u8 = &.{},
    inbox_rows: []FrontierRow = &.{},

    pub fn deinit(self: *Outcome, gpa: std.mem.Allocator, kg: *KgClient) void {
        if (self.summary.len > 0) gpa.free(self.summary);
        freeRows(kg, self.inbox_rows);
        self.* = .{};
    }
};

pub fn freeRows(kg: *KgClient, rows: []FrontierRow) void {
    if (rows.len == 0) return;
    for (rows) |*row| row.deinit(kg.allocator);
    kg.allocator.free(rows);
}

pub fn prepare(gpa: std.mem.Allocator, client: *KgClient, projects_dir: []const u8, identity: []const u8) Outcome {
    client.ensureReady();
    if (!client.ready) return .{};
    return .{
        .summary = inject.buildSummaryForAgent(gpa, client, projects_dir, identity) orelse &.{},
        .inbox_rows = readInboxFrontier(gpa, client, projects_dir),
    };
}

pub fn readInboxFrontier(gpa: std.mem.Allocator, kg: *KgClient, projects_dir: []const u8) []FrontierRow {
    const inbox = inject.readIdPointer(gpa, projects_dir, "kg_inbox") orelse return &.{};
    return kg.frontier(inbox, INBOX_MIRROR_LIMIT) catch &.{};
}

pub const Startup = struct {
    gpa: std.mem.Allocator,
    client: KgClient,
    projects_dir: []u8,
    identity: []u8,
    cancel: AbortSignal = AbortSignal.init(),
    outcome: Outcome = .{},
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub const Result = struct { client: KgClient, outcome: Outcome };

    pub fn begin(gpa: std.mem.Allocator, client: KgClient, projects_dir: []const u8, identity: []const u8) !*Startup {
        const self = try gpa.create(Startup);
        errdefer gpa.destroy(self);
        const dir = try gpa.dupe(u8, projects_dir);
        errdefer gpa.free(dir);
        const id = try gpa.dupe(u8, identity);
        errdefer gpa.free(id);
        self.* = .{ .gpa = gpa, .client = client, .projects_dir = dir, .identity = id };
        self.thread = try @import("metacodes-internal").platform.thread.spawn(.full, run, .{self});
        return self;
    }

    fn run(self: *Startup) void {
        self.client.setAbort(&self.cancel);
        self.outcome = prepare(self.gpa, &self.client, self.projects_dir, self.identity);
        self.client.setAbort(null);
        self.done.store(true, .release);
    }

    pub fn settled(self: *const Startup) bool {
        return self.done.load(.acquire);
    }

    pub fn finish(self: *Startup) Result {
        self.join();
        const result: Result = .{ .client = self.client, .outcome = self.outcome };
        self.release();
        return result;
    }

    pub fn cancelAndDestroy(self: *Startup) void {
        self.cancel.abort(.user_interrupt);
        self.join();
        self.outcome.deinit(self.gpa, &self.client);
        self.client.deinit();
        self.release();
    }

    fn join(self: *Startup) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn release(self: *Startup) void {
        const gpa = self.gpa;
        gpa.free(self.projects_dir);
        gpa.free(self.identity);
        gpa.destroy(self);
    }
};
