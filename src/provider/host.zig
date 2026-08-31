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
const custom_provider = @import("custom_provider.zig");

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
    /// Owns every string the configured profiles point at. It must outlive the
    /// registry, which borrows them.
    custom: ?custom_provider.Definitions = null,
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
        // The registry borrows the configured profiles' strings, so it goes
        // first.
        self.registry.deinit();
        if (self.custom) |*definitions| definitions.deinit();
        allocator.destroy(self);
    }

    /// Register the providers the user configured.
    ///
    /// Best effort by design: a malformed `custom_providers` section must not
    /// stop a session that also has working built-in providers. It is reported
    /// rather than swallowed — the caller decides how loudly.
    pub fn adoptCustomProviders(self: *Host, text: []const u8) custom_provider.DefinitionError!void {
        var definitions = try custom_provider.parse(self.allocator, text);
        errdefer definitions.deinit();
        for (definitions.profiles()) |built| {
            self.registry.register(built) catch return error.DuplicateProviderId;
        }
        if (self.custom) |*previous| previous.deinit();
        self.custom = definitions;
        try self.refreshCatalog();
    }

    fn refreshCatalog(self: *Host) custom_provider.DefinitionError!void {
        self.refresh() catch return error.OutOfMemory;
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
        if (store.readText()) |text| {
            defer self.allocator.free(text);
            self.adoptCustomProviders(text) catch {};
        } else |_| {}

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

test "a configured provider joins the catalog beside the built-in ones" {
    const a = std.testing.allocator;
    const host = try Host.create(a);
    defer host.destroy();
    const builtin_count = host.kernel.catalogSnapshot().items().len;

    try host.adoptCustomProviders(
        \\{"custom_providers": {"house-relay": {
        \\  "display_name": "House relay",
        \\  "channels": [{"id":"primary","base_url":"https://relay.example.com/v1","protocol":"openai_chat"}],
        \\  "models": [{"request_model_id":"relay-pro","canonical_model_id":"zai/glm-4.6"}]}}}
    );

    const items = host.kernel.catalogSnapshot().items();
    try std.testing.expectEqual(builtin_count + 1, items.len);

    var found = false;
    for (items) |candidate| {
        if (!candidate.provider_id.eqlText("house-relay")) continue;
        found = true;
        // The relay's canonical mapping is display identity; the wire carries
        // its own id, which is the property a relay exists to have.
        try std.testing.expectEqualStrings("relay-pro", candidate.request_model_id);
        try std.testing.expectEqualStrings("zai/glm-4.6", candidate.canonical_model_id.?);
        try std.testing.expectEqualStrings("https://relay.example.com/v1/chat/completions", candidate.endpoint_ref);
    }
    try std.testing.expect(found);

    // And it is selectable through the same kernel API as any built-in offer.
    var page: std.ArrayList(control_plane.OfferSummary) = .empty;
    defer page.deinit(a);
    const listed = try host.kernel.modelList(.{}, .{ .provider_id = ids.Slug.lit("house-relay") }, a, &page);
    try std.testing.expectEqual(@as(usize, 1), listed.offers.len);
}

test "a malformed custom section leaves the built-in providers working" {
    const a = std.testing.allocator;
    const host = try Host.create(a);
    defer host.destroy();
    const before = host.kernel.catalogSnapshot().items().len;

    try std.testing.expectError(
        error.NoModels,
        host.adoptCustomProviders(
            \\{"custom_providers": {"broken": {
            \\  "channels": [{"id":"c","base_url":"https://x.example.com/v1","protocol":"openai_chat"}]}}}
        ),
    );
    // A bad definition must not take the session's working providers with it.
    try std.testing.expectEqual(before, host.kernel.catalogSnapshot().items().len);
}

test "durable state adoption survives a config file that does not exist" {
    const a = std.testing.allocator;
    const host = try Host.create(a);
    defer host.destroy();
    var store = try config_store.Store.initPath(a, "/tmp/metacodes-provider-host-absent.json");
    defer store.deinit();
    // Absent is not an error: a fresh installation has no control-plane state.
    host.adoptDurableState(&store);
    try std.testing.expect(host.kernel.catalogSnapshot().items().len > 0);
}
