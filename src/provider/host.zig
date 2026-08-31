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
const selection_mod = @import("selection.zig");
const config_store = @import("config_store.zig");
const custom_provider = @import("custom_provider.zig");
const config_doc = @import("config_doc.zig");
const openrouter = @import("openrouter.zig");
const offer_mod = @import("offer.zig");
const profile_mod = @import("profile.zig");

pub const ProviderRegistry = registry_mod.ProviderRegistry;
pub const OfferCatalog = registry_mod.OfferCatalog;
pub const Kernel = control_plane.Kernel;
pub const Slug = ids.Slug;

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
    /// Owns the strings of a provider catalog ingested at runtime.
    catalog_arena: ?std.heap.ArenaAllocator = null,
    /// The configuration currently applied to the catalog, owned here.
    ///
    /// Catalog options are *host state*, not a per-call argument: a rebuild
    /// that forgot them would quietly resurrect a disabled provider and
    /// collapse a multi-account pool back to one offer, which is exactly what
    /// `/providers refresh` used to do.
    config_bindings: std.ArrayList(registry_mod.CredentialBinding) = .empty,
    config_exclusions: std.ArrayList(Slug) = .empty,
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
        if (self.catalog_arena) |*arena| arena.deinit();
        self.config_bindings.deinit(allocator);
        self.config_exclusions.deinit(allocator);
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

    pub const IngestError = openrouter.AdapterError || registry_mod.RegisterError;

    /// Ingest a provider catalog: one `GET /models` document plus one
    /// `GET /models/{id}/endpoints` document per model the caller cares about.
    ///
    /// The two are parsed separately and stay separate — a model with three
    /// endpoints becomes three offers, because a model name is not a route.
    /// Registering replaces any previous ingest for `provider_id`, and the
    /// catalog revision moves, so a client can tell its snapshot went stale.
    ///
    /// The kernel does not fetch. The caller supplies the bytes, which is what
    /// keeps this subsystem free of a transport dependency.
    pub fn ingestOpenRouter(
        self: *Host,
        provider_id: Slug,
        models_json: []const u8,
        endpoint_documents: []const []const u8,
    ) IngestError!void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const scratch = arena.allocator();

        var models = try openrouter.parseModels(self.allocator, models_json);
        defer models.deinit();

        var channels: std.ArrayList(profile_mod.ChannelDescriptor) = .empty;
        var worst = offer_mod.HealthStatus.healthy;
        for (endpoint_documents) |document| {
            var endpoints = try openrouter.parseEndpoints(self.allocator, document);
            defer endpoints.deinit();
            const model = models.find(endpoints.canonical_model_id) orelse continue;
            for (endpoints.endpoints.items) |endpoint| {
                if (endpoint.health.status == .degraded) worst = .degraded;
                if (endpoint.health.status == .unavailable) worst = .unavailable;
            }
            const built = try openrouter.buildChannels(scratch, model.*, endpoints.endpoints.items);
            channels.appendSlice(scratch, built) catch return error.OutOfMemory;
        }
        if (channels.items.len == 0) return error.InvalidDocument;

        const kinds = try scratch.alloc(profile_mod.CredentialKind, 1);
        kinds[0] = .api_key;
        const aliases = try scratch.alloc(profile_mod.EnvAlias, 1);
        aliases[0] = .{ .name = "OPENROUTER_API_KEY", .kind = .api_key, .canonical = true };

        try self.registry.register(.{
            .id = provider_id,
            .implementation_id = Slug.lit("openrouter"),
            .display_name = "OpenRouter",
            .channels = channels.items,
            .accepted_credential_kinds = kinds,
            .env_aliases = aliases,
            .default_channel = channels.items[0].id,
        });

        if (self.catalog_arena) |*previous| previous.deinit();
        self.catalog_arena = arena;
        self.refresh() catch return error.OutOfMemory;
        // Prices and health arrived with the catalog, so the events that
        // describe them are emitted here — the kernel does not fetch and cannot
        // notice on its own.
        self.kernel.notePricingUpdated(provider_id);
        self.kernel.noteProviderHealth(provider_id, worst);
    }

    /// Rebuild the catalog and hand it to the kernel. The previous catalog is
    /// retired rather than freed, so a reader that snapshotted the old pointer
    /// finishes against valid memory.
    pub fn refresh(self: *Host) HostError!void {
        return self.rebuild();
    }

    /// The single catalog swap. Every rebuild goes through it: two copies of
    /// "retire, replace, adopt" would eventually disagree about which one
    /// bumps the revision or which one keeps the previous generation alive.
    fn rebuild(self: *Host) HostError!void {
        // The revision has to move, or a client cannot tell that its snapshot
        // went stale — which is the whole reason a refresh is observable. The
        // applied configuration always rides along: it is host state, and a
        // rebuild that dropped it would resurrect a disabled provider.
        const effective = registry_mod.CatalogOptions{
            .revision = self.catalog.revision.next(),
            .credential_bindings = self.config_bindings.items,
            .excluded_providers = self.config_exclusions.items,
        };

        var rebuilt = self.registry.buildCatalog(self.allocator, effective) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.OutOfMemory,
        };
        errdefer rebuilt.deinit();

        if (self.retired) |*old| old.deinit();
        self.retired = self.catalog;
        self.catalog = rebuilt;
        self.kernel.adoptCatalog(&self.catalog);
    }

    /// Ingest provider catalogs named by the configuration.
    ///
    /// The documents are read from disk rather than fetched, on purpose: this
    /// subsystem must not depend on a transport, and a catalog saved by
    /// `curl > file` refreshes exactly the same way a live fetch would. The
    /// parsing, the offer construction, and the events are identical either
    /// way, so wiring a fetcher later changes only where the bytes come from.
    ///
    /// Shape:
    /// ```json
    /// "provider_catalogs": {
    ///   "openrouter": {"models_file": "…/models.json",
    ///                  "endpoint_files": ["…/deepseek.json"]}
    /// }
    /// ```
    pub fn ingestConfiguredCatalogs(self: *Host, text: []const u8) IngestError!void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();

        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch
            return error.InvalidDocument;
        if (root != .object) return error.InvalidDocument;
        const section = root.object.get("provider_catalogs") orelse return;
        if (section != .object) return error.InvalidDocument;

        var it = section.object.iterator();
        while (it.next()) |pair| {
            const provider_id = Slug.parse(pair.key_ptr.*) catch return error.InvalidSlug;
            const entry = pair.value_ptr.*;
            if (entry != .object) return error.InvalidDocument;
            const models_path = stringField(entry.object.get("models_file")) orelse return error.InvalidDocument;
            const models_json = readFile(arena, models_path) catch return error.InvalidDocument;

            var documents: std.ArrayList([]const u8) = .empty;
            if (entry.object.get("endpoint_files")) |list| {
                if (list != .array) return error.InvalidDocument;
                for (list.array.items) |item| {
                    const path = stringField(item) orelse return error.InvalidDocument;
                    const document = readFile(arena, path) catch return error.InvalidDocument;
                    documents.append(arena, document) catch return error.OutOfMemory;
                }
            }
            try self.ingestOpenRouter(provider_id, models_json, documents.items);
        }
    }

    /// Expiry warning window. A day is enough notice to rotate a credential
    /// without being so early the warning becomes background noise.
    pub const CREDENTIAL_EXPIRY_WARNING_SECONDS: i64 = 24 * 60 * 60;

    /// Apply the configuration document to the catalog: credential pools and
    /// disabled providers.
    ///
    /// A credential participates in the offer id, so two accounts on the same
    /// route are two offers rather than one route that quietly changes identity
    /// depending on which key resolution happened to pick. That is what makes
    /// "switch to my work account" a selectable route instead of an invisible
    /// side effect — and it is why the picker needs no separate credential
    /// stage: the accounts *are* offers.
    ///
    /// A disabled provider is excluded here rather than at resolution, so
    /// "disabled" is visible in every UI at once: the picker, `model.list`, and
    /// `--provider` all read the catalog.
    pub fn applyProviderConfiguration(self: *Host, document: *const config_doc.Document) HostError!void {
        var bindings: std.ArrayList(registry_mod.CredentialBinding) = .empty;
        errdefer bindings.deinit(self.allocator);
        for (document.providers.items) |entry| {
            if (!entry.enabled) continue;
            for (entry.credentials.items()) |credential| {
                bindings.append(self.allocator, .{
                    .provider_id = entry.id,
                    .credential_ref = credential.id,
                }) catch return error.OutOfMemory;
            }
        }
        // A disabled provider stays configured but is not routable. Doing this
        // in the catalog rather than at resolution keeps "disabled" visible
        // everywhere at once: the picker, `model.list`, and `--provider` all
        // read the catalog.
        var disabled: std.ArrayList(Slug) = .empty;
        errdefer disabled.deinit(self.allocator);
        for (document.providers.items) |entry| {
            if (entry.enabled) continue;
            disabled.append(self.allocator, entry.id) catch return error.OutOfMemory;
        }

        // Installed before the rebuild, and only after both lists are complete:
        // a partially applied configuration would be worse than the previous
        // one, and every element is a value type, so nothing borrows the
        // document.
        self.config_bindings.deinit(self.allocator);
        self.config_bindings = bindings;
        self.config_exclusions.deinit(self.allocator);
        self.config_exclusions = disabled;

        // No early return when both lists are empty: the configuration can also
        // transition *back* to "nothing configured", and skipping the rebuild
        // then would leave the previous exclusions in force.

        try self.rebuild();
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
            self.ingestConfiguredCatalogs(text) catch {};
        } else |_| {}

        var document = store.load() catch return;
        defer document.deinit();
        self.kernel.adoptConfigRevision(document.config_revision);
        self.applyProviderConfiguration(&document) catch {};
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

test "an ingested catalog becomes offers, and its prices and health become events" {
    const a = std.testing.allocator;
    const host = try Host.create(a);
    defer host.destroy();
    const before = host.kernel.catalogSnapshot().items().len;
    // `since` returns events *after* the cursor, so the last already-emitted
    // sequence is the right starting point.
    const cursor = host.kernel.journal.next_sequence - 1;

    try host.ingestOpenRouter(
        Slug.lit("openrouter"),
        \\{"data": [{"id": "deepseek/deepseek-v4", "name": "DeepSeek V4", "context_length": 163840,
        \\  "supported_parameters": ["tools"],
        \\  "pricing": {"prompt": "0.0000004", "completion": "0.0000016"}}]}
    ,
        &.{
            \\{"data": {"id": "deepseek/deepseek-v4", "endpoints": [
            \\  {"provider_name": "DeepInfra", "context_length": 131072, "status": 0,
            \\   "pricing": {"prompt": "0.0000005", "completion": "0.0000018"}},
            \\  {"provider_name": "Together AI", "status": -1}
            \\]}}
        },
    );

    // One model, two endpoints, two offers.
    const items = host.kernel.catalogSnapshot().items();
    try std.testing.expectEqual(before + 2, items.len);
    var priced: usize = 0;
    var inherited: usize = 0;
    for (items) |item| {
        if (!item.provider_id.eqlText("openrouter")) continue;
        try std.testing.expectEqualStrings("deepseek/deepseek-v4", item.canonical_model_id.?);
        if (item.quote.priced()) |price| {
            priced += 1;
            if (price.provenance.freshness == .inherited) inherited += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), priced);
    // Together AI declared no price of its own, so it inherits the model's —
    // and says so rather than claiming the endpoint confirmed it.
    try std.testing.expectEqual(@as(usize, 1), inherited);

    var buffer: std.ArrayList(control_plane.ControlPlaneEvent) = .empty;
    defer buffer.deinit(a);
    const replay = try host.kernel.replayEvents(cursor, a, &buffer);
    var saw_catalog = false;
    var saw_pricing = false;
    var saw_degraded = false;
    for (replay.events) |event| switch (event.event_type) {
        .catalog_updated => saw_catalog = true,
        .pricing_updated => saw_pricing = true,
        .provider_degraded => saw_degraded = true,
        else => {},
    };
    // These three event types had no producer before a catalog could be
    // ingested; a declared type nothing emits is decoration.
    try std.testing.expect(saw_catalog);
    try std.testing.expect(saw_pricing);
    try std.testing.expect(saw_degraded);
}

test "a pinned offer survives an unrelated catalog ingest" {
    const a = std.testing.allocator;
    const host = try Host.create(a);
    defer host.destroy();

    const pinned = host.kernel.catalogSnapshot().items()[0];
    const committed = host.kernel.selectionCommit(
        .{},
        selection_mod.RuntimeSelection.pinned(pinned.offer_id, pinned.offer_revision, .session),
        .session,
    );
    try std.testing.expect(committed == .committed);

    try host.ingestOpenRouter(
        Slug.lit("openrouter"),
        \\{"data": [{"id": "x/y", "context_length": 1000}]}
    ,
        &.{
            \\{"data": {"id": "x/y", "endpoints": [{"provider_name": "Alpha"}]}}
        },
    );

    // The pin is derived from a stable binding, so a refresh reproduces the id
    // and the selection still resolves — that is what makes a pin durable.
    const resolved = host.kernel.selectionResolve().?;
    try std.testing.expect(resolved == .ok);
    try std.testing.expect(resolved.ok.offer_id.eql(pinned.offer_id));
}

fn stringField(value: ?std.json.Value) ?[]const u8 {
    const found = value orelse return null;
    return switch (found) {
        .string => |text| text,
        else => null,
    };
}

fn readFile(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const pfs = @import("platform").fs;
    const path_z = try arena.dupeZ(u8, path);
    const fd = try pfs.openZ(path_z, .{ .ACCMODE = .RDONLY }, 0);
    defer pfs.close(fd);
    const info = try pfs.fileInfo(fd);
    // Bounded: a catalog is user-pointed input, and an unbounded read of a path
    // from a config file is a memory-exhaustion vector.
    if (info.size > 8 * 1024 * 1024) return error.CatalogTooLarge;
    const buffer = try arena.alloc(u8, @intCast(info.size));
    var filled: usize = 0;
    while (filled < buffer.len) {
        const n = try pfs.readZ(fd, buffer[filled..]);
        if (n == 0) break;
        filled += n;
    }
    return buffer[0..filled];
}

test "two accounts on one provider are two selectable routes" {
    const a = std.testing.allocator;
    const host = try Host.create(a);
    defer host.destroy();
    const before = host.kernel.catalogSnapshot().items().len;

    var document = config_doc.Document.init(a);
    defer document.deinit();
    var entry = config_doc.ProviderEntry{ .id = Slug.lit("openai") };
    try entry.credentials.append(.{
        .id = Slug.lit("work"),
        .env = try config_doc.AliasName.parse("OPENAI_API_KEY_WORK"),
        .kind = try @import("controls.zig").Bounded(32).parse("api_key"),
        .priority = 0,
    });
    try entry.credentials.append(.{
        .id = Slug.lit("personal"),
        .env = try config_doc.AliasName.parse("OPENAI_API_KEY_PERSONAL"),
        .kind = try @import("controls.zig").Bounded(32).parse("api_key"),
        .priority = 1,
    });
    try document.upsertProvider(entry);

    try host.applyProviderConfiguration(&document);
    const items = host.kernel.catalogSnapshot().items();

    var work: usize = 0;
    var personal: usize = 0;
    var seen_ids: std.ArrayList(ids.OfferId) = .empty;
    defer seen_ids.deinit(a);
    for (items) |item| {
        if (!item.provider_id.eqlText("openai")) continue;
        const ref = item.credential_ref orelse continue;
        if (ref.eqlText("work")) work += 1;
        if (ref.eqlText("personal")) personal += 1;
        for (seen_ids.items) |existing| try std.testing.expect(!existing.eql(item.offer_id));
        try seen_ids.append(a, item.offer_id);
    }
    // Each account is its own route identity, so "switch to my work account" is
    // a selectable offer rather than an invisible side effect of resolution.
    try std.testing.expect(work > 0);
    try std.testing.expectEqual(work, personal);
    try std.testing.expect(host.kernel.catalogSnapshot().items().len > before);
}

test "a provider with no configured pool keeps exactly its previous offers" {
    const a = std.testing.allocator;
    const host = try Host.create(a);
    defer host.destroy();
    const before = host.kernel.catalogSnapshot().items().len;

    var document = config_doc.Document.init(a);
    defer document.deinit();
    try document.upsertProvider(.{ .id = Slug.lit("openai") });
    // No credentials declared: an existing single-account setup must not gain
    // or lose a single route.
    try host.applyProviderConfiguration(&document);
    try std.testing.expectEqual(before, host.kernel.catalogSnapshot().items().len);
}

test "a disabled provider keeps its configuration and produces no routes" {
    const a = std.testing.allocator;
    const host = try Host.create(a);
    defer host.destroy();

    var before: usize = 0;
    for (host.kernel.catalogSnapshot().items()) |item| {
        if (item.provider_id.eqlText("openai")) before += 1;
    }
    try std.testing.expect(before > 0);

    var document = config_doc.Document.init(a);
    defer document.deinit();
    try document.upsertProvider(.{
        .id = Slug.lit("openai"),
        .enabled = false,
        .credential_ref = Slug.lit("cred-openai"),
    });
    try host.applyProviderConfiguration(&document);

    var after: usize = 0;
    for (host.kernel.catalogSnapshot().items()) |item| {
        if (item.provider_id.eqlText("openai")) after += 1;
    }
    // Nothing can route to it, in every UI at once, because they all read the
    // catalog.
    try std.testing.expectEqual(@as(usize, 0), after);
    // And the configuration survives — that is the difference between
    // disabling and removing.
    try std.testing.expect(document.provider(Slug.lit("openai")).?.credential_ref != null);

    // Re-enabling restores exactly the routes it had.
    try document.upsertProvider(.{ .id = Slug.lit("openai"), .enabled = true });
    try host.applyProviderConfiguration(&document);
    var restored: usize = 0;
    for (host.kernel.catalogSnapshot().items()) |item| {
        if (item.provider_id.eqlText("openai")) restored += 1;
    }
    try std.testing.expectEqual(before, restored);
}

test "a catalog ingest keeps the applied configuration" {
    const a = std.testing.allocator;
    const host = try Host.create(a);
    defer host.destroy();

    var document = config_doc.Document.init(a);
    defer document.deinit();
    try document.upsertProvider(.{ .id = Slug.lit("gemini"), .enabled = false });
    var entry = config_doc.ProviderEntry{ .id = Slug.lit("openai") };
    try entry.credentials.append(.{
        .id = Slug.lit("work"),
        .env = try config_doc.AliasName.parse("OPENAI_KEY_WORK"),
        .kind = try @import("controls.zig").Bounded(32).parse("api_key"),
    });
    try entry.credentials.append(.{
        .id = Slug.lit("personal"),
        .env = try config_doc.AliasName.parse("OPENAI_KEY_PERSONAL"),
        .kind = try @import("controls.zig").Bounded(32).parse("api_key"),
    });
    try document.upsertProvider(entry);
    try host.applyProviderConfiguration(&document);

    const Counts = struct {
        fn of(catalog: *const OfferCatalog, provider: []const u8) usize {
            var n: usize = 0;
            for (catalog.items()) |item| {
                if (item.provider_id.eqlText(provider)) n += 1;
            }
            return n;
        }
    };
    const openai_before = Counts.of(host.kernel.catalogSnapshot(), "openai");
    try std.testing.expect(openai_before > 0);
    try std.testing.expectEqual(@as(usize, 0), Counts.of(host.kernel.catalogSnapshot(), "gemini"));

    // A later ingest — or a plain refresh — must not resurrect the disabled
    // provider or collapse the two accounts back into one offer. Catalog
    // options are host state, not a per-call argument.
    try host.ingestOpenRouter(
        Slug.lit("openrouter"),
        \\{"data": [{"id": "x/y", "context_length": 1000}]}
    ,
        &.{
            \\{"data": {"id": "x/y", "endpoints": [{"provider_name": "Alpha"}]}}
        },
    );
    try std.testing.expectEqual(openai_before, Counts.of(host.kernel.catalogSnapshot(), "openai"));
    try std.testing.expectEqual(@as(usize, 0), Counts.of(host.kernel.catalogSnapshot(), "gemini"));

    try host.refresh();
    try std.testing.expectEqual(openai_before, Counts.of(host.kernel.catalogSnapshot(), "openai"));
    try std.testing.expectEqual(@as(usize, 0), Counts.of(host.kernel.catalogSnapshot(), "gemini"));
}
