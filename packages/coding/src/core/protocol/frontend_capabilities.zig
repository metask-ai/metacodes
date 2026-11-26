//! What a cross-process frontend can render, as its capability frame declared
//! it (doc/WIRE_PROTOCOL.md §2), and the routing that follows from it: a UI
//! request the declaration excludes is answered `unavailable` at once instead
//! of being announced to a frontend that would fail it.
//!
//! wire.zig reads and writes the frame; this module holds the decoded value,
//! the custom-kind grammar and the routing rule. A Host keeps one `Slot` per
//! Session. An empty Slot (nothing declared) routes every request, which is
//! how every frontend was routed before the exchange existed; in-process
//! backends never fill one.

const std = @import("std");
const sync = @import("platform").sync;
const ui_event = @import("metacodes-guard").core.protocol.ui_event;
const ui_request = @import("metacodes-guard").core.protocol.ui_request;

const UiRequest = ui_request.UiRequest;

/// The named UiRequest kinds, in UiRequest's order. `custom` is not one:
/// custom kinds are declared one by one, with their version.
pub const NamedKind = enum { ask_question, permission };

pub const EventTag = std.meta.Tag(ui_event.CoreEvent);

comptime {
    var named: usize = 0;
    for (std.meta.fields(UiRequest)) |field| {
        if (std.mem.eql(u8, field.name, "custom")) continue;
        if (named >= std.meta.fields(NamedKind).len or !std.mem.eql(u8, std.meta.fields(NamedKind)[named].name, field.name))
            @compileError("NamedKind is out of step with UiRequest at ." ++ field.name);
        named += 1;
    }
    if (named != std.meta.fields(NamedKind).len) @compileError("NamedKind names a kind UiRequest does not have");
}

/// Bounds of a frame, so a declaration cannot grow the journal without limit.
pub const MAX_FRAME_BYTES: usize = 64 * 1024;
pub const MAX_UI_REQUESTS: usize = 32;
pub const MAX_CUSTOM_KINDS: usize = 64;
pub const MAX_EVENTS: usize = 256;
/// Longest name accepted in `ui_requests` or `events`, known or not.
pub const MAX_NAME_BYTES: usize = 128;
/// Longest `<name>` of a versioned custom kind.
pub const MAX_CUSTOM_NAME_BYTES: usize = 64;

/// A frontend's declaration. Slices belong to the `Declaration` holding it.
pub const Capabilities = struct {
    named: std.EnumSet(NamedKind),
    /// Versioned custom kinds (`isVersionedKind`), distinct, in frame order.
    custom: []const []const u8,
    /// CoreEvent tags the frontend consumes; null when the frame did not say.
    /// Diagnostics only: it never filters the journal or changes routing.
    events: ?std.EnumSet(EventTag),
};

/// A parsed capability frame: the capabilities and the names this core did
/// not know, all owned by `arena`.
pub const Declaration = struct {
    arena: std.heap.ArenaAllocator,
    capabilities: Capabilities,
    ignored_ui_requests: []const []const u8,
    ignored_events: []const []const u8,

    pub fn deinit(self: *Declaration) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Why a request was not announced (`ui_request_unavailable.reason`).
pub const Unavailable = enum {
    /// A named kind the declaration does not list.
    kind_not_declared,
    /// A versioned custom kind the declaration does not list.
    custom_kind_not_declared,
    /// A custom kind without `@<major>`, which no declaration can list.
    custom_kind_unversioned,
};

pub const Route = union(enum) {
    /// Announce the request and wait for the frontend's answer.
    deliver,
    /// Answer `RequestOutcome.unavailable` now; the frontend never sees it.
    unavailable: Unavailable,
};

/// How a request is routed to a frontend that declared `capabilities`, or to
/// one that declared nothing (null), which receives everything.
pub fn route(capabilities: ?*const Capabilities, request: *const UiRequest) Route {
    const declared = capabilities orelse return .deliver;
    switch (request.*) {
        .custom => |custom| {
            if (!isVersionedKind(custom.kind)) return .{ .unavailable = .custom_kind_unversioned };
            for (declared.custom) |kind| {
                if (std.mem.eql(u8, kind, custom.kind)) return .deliver;
            }
            return .{ .unavailable = .custom_kind_not_declared };
        },
        else => {
            // Every non-custom tag is a NamedKind (checked above).
            const kind = std.meta.stringToEnum(NamedKind, @tagName(request.*)).?;
            return if (declared.named.contains(kind)) .deliver else .{ .unavailable = .kind_not_declared };
        },
    }
}

/// `<name>@<major>`: name `[a-z0-9][a-z0-9_.-]*` of at most
/// MAX_CUSTOM_NAME_BYTES, major a decimal u32 >= 1 without a leading zero.
pub fn isVersionedKind(kind: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, kind, '@') orelse return false;
    const name = kind[0..at];
    const major = kind[at + 1 ..];
    if (name.len == 0 or name.len > MAX_CUSTOM_NAME_BYTES) return false;
    if (!isLowerAlnum(name[0])) return false;
    for (name) |c| {
        if (!(isLowerAlnum(c) or c == '_' or c == '.' or c == '-')) return false;
    }
    if (major.len == 0 or major[0] == '0') return false;
    for (major) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    _ = std.fmt.parseInt(u32, major, 10) catch return false;
    return true;
}

fn isLowerAlnum(c: u8) bool {
    return std.ascii.isDigit(c) or (c >= 'a' and c <= 'z');
}

/// The declaration in force for one Session, shared between the thread that
/// installs a frame and the threads that route requests.
pub const Slot = struct {
    mutex: sync.Mutex = .{},
    /// Null until the first accepted frame.
    current: ?*Installed = null,

    const Installed = struct {
        declaration: Declaration,
        /// The `capabilities_accepted` line, reported by `acceptedLine`.
        accepted_line: []u8,
    };

    pub fn deinit(self: *Slot, gpa: std.mem.Allocator) void {
        if (self.current) |installed| destroy(gpa, installed);
        self.current = null;
    }

    /// Replaces the declaration in force. Takes `declaration` and
    /// `accepted_line` (owned by `gpa`) on success; on error the caller
    /// still owns both.
    pub fn install(self: *Slot, gpa: std.mem.Allocator, declaration: Declaration, accepted_line: []u8) error{OutOfMemory}!void {
        const installed = try gpa.create(Installed);
        installed.* = .{ .declaration = declaration, .accepted_line = accepted_line };
        self.mutex.lock();
        const previous = self.current;
        self.current = installed;
        self.mutex.unlock();
        if (previous) |old| destroy(gpa, old);
    }

    pub fn route(self: *Slot, request: *const UiRequest) Route {
        self.mutex.lock();
        defer self.mutex.unlock();
        const installed = self.current orelse return .deliver;
        return routeDeclared(&installed.declaration.capabilities, request);
    }

    /// A copy of the `capabilities_accepted` line in force, owned by
    /// `allocator`, or null while nothing was declared.
    pub fn acceptedLine(self: *Slot, allocator: std.mem.Allocator) error{OutOfMemory}!?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const installed = self.current orelse return null;
        return try allocator.dupe(u8, installed.accepted_line);
    }

    fn destroy(gpa: std.mem.Allocator, installed: *Installed) void {
        installed.declaration.deinit();
        gpa.free(installed.accepted_line);
        gpa.destroy(installed);
    }
};

/// The module's `route`, which `Slot.route` shadows inside `Slot`.
const routeDeclared = route;

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "isVersionedKind: name@major, lowercase name, major from 1 without a leading zero" {
    const good = [_][]const u8{ "video_timeline@1", "diff-review.v@42", "a@4294967295", "0x@7" };
    for (good) |kind| try testing.expect(isVersionedKind(kind));
    const bad = [_][]const u8{
        "video_timeline", "video_timeline@", "@1",      "Video@1",  "video@0", "video@01",
        "video@+1",       "video@1.2",       "video@x", "_video@1", "a b@1",   "video@4294967296",
        "a@1@2",
    };
    for (bad) |kind| try testing.expect(!isVersionedKind(kind));
    try testing.expect(isVersionedKind("a" ** MAX_CUSTOM_NAME_BYTES ++ "@1"));
    try testing.expect(!isVersionedKind("a" ** (MAX_CUSTOM_NAME_BYTES + 1) ++ "@1"));
}

test "route: an undeclared frontend receives every request, a declared one only what it lists" {
    const options = [_]ui_request.AskOption{.{ .label = "Yes", .description = "" }};
    const questions = [_]ui_request.AskQuestion{.{ .question = "Q?", .header = "q", .multi = false, .options = &options }};
    const ask = UiRequest{ .ask_question = &questions };
    const permission = UiRequest{ .permission = .{ .tool = "Bash", .args = "{}" } };
    const timeline_v1 = UiRequest{ .custom = .{ .kind = "video_timeline@1", .payload_json = "{}" } };
    const timeline_v2 = UiRequest{ .custom = .{ .kind = "video_timeline@2", .payload_json = "{}" } };
    const unversioned = UiRequest{ .custom = .{ .kind = "video_timeline", .payload_json = "{}" } };

    for ([_]*const UiRequest{ &ask, &permission, &timeline_v1, &timeline_v2, &unversioned }) |request| {
        try testing.expectEqual(Route.deliver, route(null, request));
    }

    var named = std.EnumSet(NamedKind).initEmpty();
    named.insert(.permission);
    const declared = Capabilities{ .named = named, .custom = &.{"video_timeline@1"}, .events = null };
    try testing.expectEqual(Route.deliver, route(&declared, &permission));
    try testing.expectEqual(Route{ .unavailable = .kind_not_declared }, route(&declared, &ask));
    try testing.expectEqual(Route.deliver, route(&declared, &timeline_v1));
    try testing.expectEqual(Route{ .unavailable = .custom_kind_not_declared }, route(&declared, &timeline_v2));
    try testing.expectEqual(Route{ .unavailable = .custom_kind_unversioned }, route(&declared, &unversioned));

    const nothing = Capabilities{ .named = std.EnumSet(NamedKind).initEmpty(), .custom = &.{}, .events = null };
    try testing.expectEqual(Route{ .unavailable = .kind_not_declared }, route(&nothing, &permission));
}

test "Slot: empty routes everything; install replaces the declaration and frees the previous one" {
    const gpa = testing.allocator;
    var slot = Slot{};
    defer slot.deinit(gpa);
    const custom = UiRequest{ .custom = .{ .kind = "form@1", .payload_json = "{}" } };
    try testing.expectEqual(Route.deliver, slot.route(&custom));
    try testing.expectEqual(@as(?[]u8, null), try slot.acceptedLine(gpa));

    for ([_][]const []const u8{ &.{}, &.{"form@1"} }, 0..) |kinds, round| {
        var declaration = Declaration{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .capabilities = undefined,
            .ignored_ui_requests = &.{},
            .ignored_events = &.{},
        };
        const owned = try declaration.arena.allocator().alloc([]const u8, kinds.len);
        for (kinds, owned) |kind, *copy| copy.* = try declaration.arena.allocator().dupe(u8, kind);
        declaration.capabilities = .{ .named = std.EnumSet(NamedKind).initEmpty(), .custom = owned, .events = null };
        const line = try std.fmt.allocPrint(gpa, "accepted {d}", .{round});
        try slot.install(gpa, declaration, line);
    }
    try testing.expectEqual(Route.deliver, slot.route(&custom));
    const line = (try slot.acceptedLine(gpa)).?;
    defer gpa.free(line);
    try testing.expectEqualStrings("accepted 1", line);
}
