//! Process-lifetime provider runtime (issue #16, delivery slice P1).
//!
//! `startup.zig` resolves one route and throws its registry away, which is all
//! a bootstrap needs. A picker needs the opposite: a registry, catalog, and
//! kernel that live as long as the session, so a client can list offers,
//! validate a candidate, and commit — repeatedly, against stable ids.
//!
//! Heap-allocated on purpose. `Kernel` borrows `*const OfferCatalog`, so the
//! catalog must not move after the kernel has seen it; a by-value `Host` copied
//! into a struct field would leave the kernel pointing at the old address.

const std = @import("std");
const ids = @import("ids.zig");
const registry_mod = @import("registry.zig");
const control_plane = @import("control_plane.zig");
const config_store = @import("config_store.zig");

pub const ProviderRegistry = registry_mod.ProviderRegistry;
pub const OfferCatalog = registry_mod.OfferCatalog;
pub const Kernel = control_plane.Kernel;

pub const HostError = error{OutOfMemory} || registry_mod.RegisterError;

pub const Host = struct {
    allocator: std.mem.Allocator,
    registry: ProviderRegistry,
    catalog: OfferCatalog,
    /// Catalog the kernel handed out before the most recent refresh. Kept alive
    /// until the next refresh because `adoptCatalog` documents that a previous
    /// catalog must outlive in-flight readers.
    retired: ?OfferCatalog = null,
    kernel: Kernel,

    pub fn create(allocator: std.mem.Allocator) HostError!*Host {
        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .registry = try ProviderRegistry.initWithBuiltins(allocator),
            .catalog = undefined,
            .kernel = undefined,
        };
        errdefer self.registry.deinit();

        self.catalog = self.registry.buildCatalog(allocator, .{ .revision = .initial }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A built-in profile that cannot produce a catalog is a programming
            // error, not a runtime condition; an empty catalog would silently
            // become "no providers exist".
            else => return error.OutOfMemory,
        };
        self.kernel = Kernel.init(allocator, &self.catalog);
        self.kernel.registry = &self.registry;
        return self;
    }

    pub fn destroy(self: *Host) void {
        const allocator = self.allocator;
        self.kernel.deinit();
        if (self.retired) |*old| old.deinit();
        self.catalog.deinit();
        self.registry.deinit();
        allocator.destroy(self);
    }

    /// Rebuild the catalog and hand it to the kernel. The previous catalog is
    /// retired rather than freed, so a reader that snapshotted the old pointer
    /// finishes against valid memory.
    pub fn refresh(self: *Host) HostError!void {
        // The revision has to move, or a client cannot tell that its snapshot
        // went stale — which is the whole reason a refresh is observable.
        const next = self.catalog.revision.next();
        var rebuilt = self.registry.buildCatalog(self.allocator, .{ .revision = next }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.OutOfMemory,
        };
        errdefer rebuilt.deinit();

        if (self.retired) |*old| old.deinit();
        self.retired = self.catalog;
        self.catalog = rebuilt;
        self.kernel.adoptCatalog(&self.catalog);
    }

    /// Load the durable document and seed the kernel with what it holds: the
    /// config revision `selection.commit` compares against, and the global
    /// selection a previous run committed.
    ///
    /// Best effort by design — a session must still start when `config.json`
    /// is missing or unreadable. What must not happen is inventing a revision:
    /// the store is the sole authority, so a failed read leaves the kernel at
    /// its initial revision and a later commit conflicts loudly.
    pub fn adoptDurableState(self: *Host, store: *const config_store.Store) void {
        var document = store.load() catch return;
        defer document.deinit();
        self.kernel.adoptConfigRevision(document.config_revision);
        if (document.global_selection) |selection| {
            self.kernel.seedGlobalSelection(selection);
        }
    }
};

test "the kernel sees the host's catalog and survives a refresh" {
    const a = std.testing.allocator;
    const host = try Host.create(a);
    defer host.destroy();

    const before = host.kernel.catalogSnapshot();
    try std.testing.expect(before.items().len > 0);
    const revision_before = host.kernel.catalogRevision();

    try host.refresh();
    const after = host.kernel.catalogSnapshot();
    try std.testing.expect(after.items().len == before.items().len);
    // A refresh must move the revision, or a client cannot tell its snapshot
    // went stale.
    try std.testing.expect(@intFromEnum(host.kernel.catalogRevision()) != @intFromEnum(revision_before));

    // Offer ids are derived from the stable binding, so a rebuild reproduces
    // them exactly — that is what makes a pin survive a refresh.
    for (before.items(), after.items()) |old, new| {
        try std.testing.expect(old.offer_id.eql(new.offer_id));
    }
}

test "two refreshes keep the retired catalog alive for one generation" {
    const a = std.testing.allocator;
    const host = try Host.create(a);
    defer host.destroy();
    try host.refresh();
    try std.testing.expect(host.retired != null);
    try host.refresh();
    try std.testing.expect(host.retired != null);
}
