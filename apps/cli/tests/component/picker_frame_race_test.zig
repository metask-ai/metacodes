//! L2: the model picker is written by one thread while frames drawn on other
//! threads read it (#328 review). During a reply the keyboard watcher is the
//! picker's writer; the agent thread's text frames and the merge window's
//! timer draw the open picker under the region lock. picker_host takes that
//! lock (its `Guard`) for every in-memory write and for nothing else.
//!
//! Contracts:
//!   - a catalog refresh racing frames that draw the open picker never shows
//!     a frame half a snapshot old: before the guard, `adopt` cleared and
//!     refilled the offer list while the view indexed it by the previous
//!     list's rows (an out-of-bounds panic in a safe build);
//!   - a picker write waits for a frame being drawn (the region lock is held)
//!     and lands after it.

const std = @import("std");
const cc = @import("cc");
const harness = @import("region_harness.zig");

const testing = std.testing;
const gpa = testing.allocator;
const picker_host = cc.repl_picker_host;
const App = cc.app_module.App;

/// The kernel's listing, and the same listing cut to its first offer: adopting
/// them in turn shrinks and grows the picker's offer list.
const Listings = struct {
    full: App.ModelListing,
    one: App.ModelListing,

    fn init(app: *App) !Listings {
        var full = try app.listModelOffers();
        errdefer full.deinit(app.allocator);
        const page = full.listed orelse return error.CatalogNotListed;
        if (page.offers.len < 2) return error.CatalogTooSmall;
        var cut = page;
        cut.offers = page.offers[0..1];
        // `one` borrows `full`'s buffer: only `full` owns it.
        return .{ .full = full, .one = .{ .listed = cut, .current = full.current } };
    }

    fn deinit(self: *Listings, allocator: std.mem.Allocator) void {
        self.full.deinit(allocator);
    }
};

test "picker: a catalog refresh racing frames that draw the open picker" {
    const fx = try harness.AppFixture.create(gpa);
    defer fx.destroy();
    const t = try harness.Term.create(gpa, .{ .rows = 30, .cols = 100 });
    defer t.destroy();
    const r = &t.region;
    const guard = picker_host.Guard.of(r);

    r.enterGenerating(fx.app, null);
    picker_host.open(fx.app, &r.ui, guard);
    try testing.expect(r.pickerOpen());
    var listings = try Listings.init(fx.app);
    defer listings.deinit(fx.app.allocator);

    const Writer = struct {
        fn run(app: *App, l: *Listings, g: picker_host.Guard, done: *std.atomic.Value(bool)) void {
            var i: usize = 0;
            while (!done.load(.acquire)) : (i += 1) {
                picker_host.publishListing(app, if (i % 2 == 0) &l.one else &l.full, g);
            }
        }
    };
    var done = std.atomic.Value(bool).init(false);
    const writer = try std.Thread.spawn(.{}, Writer.run, .{ fx.app, &listings, guard, &done });
    // The frames a reply draws while the watcher refreshes the catalog.
    for (0..400) |_| r.tickSpinner(fx.app);
    done.store(true, .release);
    writer.join();

    // Settle on the full list: the last frame shows it, with nothing torn.
    picker_host.publishListing(fx.app, &listings.full, guard);
    r.tickSpinner(fx.app);
    try t.sync();
    try testing.expect(r.pickerOpen());
    try testing.expectEqual(listings.full.listed.?.offers.len, fx.app.model_picker.offers.items.len);
    r.leaveGenerating(fx.app);
}

test "picker: a write waits for the frame being drawn" {
    const fx = try harness.AppFixture.create(gpa);
    defer fx.destroy();
    const t = try harness.Term.create(gpa, .{ .rows = 30, .cols = 100 });
    defer t.destroy();
    const r = &t.region;
    const guard = picker_host.Guard.of(r);

    r.enterGenerating(fx.app, null);
    picker_host.open(fx.app, &r.ui, guard);
    const cursor_before = fx.app.model_picker.cursor;

    const Key = struct {
        fn run(app: *App, region: *harness.RenderRegion, g: picker_host.Guard, landed: *std.atomic.Value(bool)) void {
            _ = picker_host.onKey(app, &region.ui, .down, g);
            landed.store(true, .release);
        }
    };
    var landed = std.atomic.Value(bool).init(false);
    // Another thread is mid-frame: it holds the region lock.
    r.lockUi();
    const key = std.Thread.spawn(.{}, Key.run, .{ fx.app, r, guard, &landed }) catch |err| {
        r.unlockUi();
        return err;
    };
    @import("platform").sync.sleepMs(50);
    const early = landed.load(.acquire);
    const cursor_during = fx.app.model_picker.cursor;
    r.unlockUi();
    key.join();

    try testing.expect(!early); // the key did not land while the frame held the lock
    try testing.expectEqual(cursor_before, cursor_during);
    try testing.expect(landed.load(.acquire));
    try testing.expect(fx.app.model_picker.cursor != cursor_before); // and moved the cursor after it
    r.leaveGenerating(fx.app);
}
