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
const metask_profile = @import("profiles/metask.zig");
const metask_catalog = @import("metask_catalog.zig");

pub const ProviderRegistry = registry_mod.ProviderRegistry;
pub const OfferCatalog = registry_mod.OfferCatalog;
pub const Kernel = control_plane.Kernel;
pub const Slug = ids.Slug;

pub const HostError = error{OutOfMemory} || registry_mod.RegisterError;

/// One `providers.<id>.oauth_client_id` entry as the host keeps it (#87).
pub const ConfiguredClientId = struct { provider_id: Slug, client_id: []const u8 };

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
    /// Why a stage of `adoptDurableState` did not apply, if one did not.
    ///
    /// This subsystem must not print — it has no UI and no business owning one
    /// — but swallowing the reason entirely means a broken `custom_providers`
    /// section shows up much later as "unknown provider", with nothing to
    /// connect the two. The caller reports it.
    startup_warning: ?[]const u8 = null,
    /// The configuration currently applied to the catalog, owned here.
    ///
    /// Catalog options are *host state*, not a per-call argument: a rebuild
    /// that forgot them would quietly resurrect a disabled provider and
    /// collapse a multi-account pool back to one offer, which is exactly what
    /// `/providers refresh` used to do.
    config_bindings: std.ArrayList(registry_mod.CredentialBinding) = .empty,
    config_exclusions: std.ArrayList(Slug) = .empty,
    /// `providers.<id>.oauth_client_id` (#87): the client an installation
    /// registered for a profile that declares none. The strings live in
    /// `config_client_arena`, which only the host's end frees: a login that
    /// is presenting one of them may still be in flight when the
    /// configuration is applied again, so a swap appends rather than frees.
    config_client_ids: std.ArrayList(ConfiguredClientId) = .empty,
    config_client_arena: ?std.heap.ArenaAllocator = null,
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
        self.config_client_ids.deinit(allocator);
        if (self.config_client_arena) |*arena| arena.deinit();
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

        // Everything is validated and capacity reserved *before* anything is
        // mutated. A failure halfway through would otherwise leave the registry
        // holding profiles that borrow this arena while the errdefer releases
        // it — and re-adopting the same configuration would fail outright,
        // which is what a second `/providers refresh` does.
        for (definitions.profiles()) |built| {
            self.registry.checkUpsert(built) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.DuplicateProviderId => error.DuplicateProviderId,
                else => error.InvalidDocument,
            };
        }
        self.registry.reserve(definitions.profiles().len) catch return error.OutOfMemory;

        // From here nothing fails, so the swap is atomic.
        for (definitions.profiles()) |built| self.registry.upsertAssumeCapacity(built);
        if (self.custom) |*previous| {
            // A provider the configuration no longer declares must be dropped
            // before its arena is released, or the registry keeps a profile
            // pointing into freed memory.
            for (previous.profiles()) |old| {
                if (definitions.find(old.id.slice()) == null) _ = self.registry.removeRuntime(old.id);
            }
            previous.deinit();
        }
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
        // Disarmed once the host owns it; releasing it afterwards would leave
        // the registry holding a profile that borrows from it.
        var moved = false;
        errdefer if (!moved) arena.deinit();
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

        const built = profile_mod.ProviderProfile{
            .id = provider_id,
            .implementation_id = Slug.lit("openrouter"),
            .display_name = "OpenRouter",
            .channels = channels.items,
            .accepted_credential_kinds = kinds,
            .env_aliases = aliases,
            .default_channel = channels.items[0].id,
        };
        // Validate and reserve before mutating: a refresh replaces its own
        // previous registration, and a half-applied one would leave the
        // registry pointing into an arena about to be released.
        try self.registry.checkUpsert(built);
        try self.registry.reserve(1);

        // Infallible from here, so the registry and the arena that backs it
        // change together.
        self.registry.upsertAssumeCapacity(built);
        if (self.catalog_arena) |*previous| previous.deinit();
        self.catalog_arena = arena;
        moved = true;
        self.refresh() catch return error.OutOfMemory;
        // Prices and health arrived with the catalog, so the events that
        // describe them are emitted here — the kernel does not fetch and cannot
        // notice on its own.
        self.kernel.notePricingUpdated(provider_id);
        self.kernel.noteProviderHealth(provider_id, worst);
    }

    /// Replace Metask's compiled inventory with the authenticated gateway's
    /// `/v1/models` document. The gateway origin is kept separate from either
    /// protocol path; both Anthropic Messages and OpenAI Chat offers are then
    /// materialized for every returned model.
    pub fn ingestMetask(self: *Host, gateway_origin: []const u8, models_json: []const u8) IngestError!void {
        var parsed = metask_catalog.parseModels(self.allocator, models_json) catch return error.InvalidDocument;
        defer parsed.deinit();
        if (parsed.models.items.len == 0) return error.InvalidDocument;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        var moved = false;
        errdefer if (!moved) arena.deinit();
        const scratch = arena.allocator();

        const models = try scratch.alloc(profile_mod.ModelEntry, parsed.models.items.len);
        for (parsed.models.items, 0..) |model, i| {
            var capabilities = offer_mod.CapabilityMatrix{
                // The provider kernel deliberately has no wall-clock
                // dependency. The catalog source is known; freshness is
                // represented by the host's catalog revision rather than an
                // import of the application time utility.
                .provenance = offer_mod.Provenance.known(.provider_catalog, null),
            };
            capabilities = capabilities.with(.reasoning, model.reasoning);
            capabilities = capabilities.with(.vision, model.vision);
            models[i] = .{
                .request_model_id = try scratch.dupe(u8, model.id),
                .display_name = try scratch.dupe(u8, model.display_name),
                .canonical_model_id = null,
                .limits = .{
                    .context_window = model.max_input_tokens,
                    .max_input_tokens = model.max_input_tokens,
                    .max_output_tokens = model.max_tokens,
                    .token_counting = .{ .mode = .provider_reported, .unit = .tokens },
                    .provenance = offer_mod.Provenance.known(.provider_catalog, null),
                },
                .capabilities = capabilities,
                .quote = .unknown,
            };
        }

        const channel = try scratch.create(profile_mod.ChannelDescriptor);
        channel.* = metask_profile.PROFILE.channels[0];
        channel.base_url = try scratch.dupe(u8, std.mem.trimEnd(u8, gateway_origin, "/"));
        // The compiled profile intentionally retains only the historical
        // Messages route so model-only legacy selections stay unambiguous.
        // An authenticated gateway catalog opts into both wire protocols.
        const routes = try scratch.alloc(profile_mod.ProtocolRoute, 2);
        routes[0] = .{ .protocol = .anthropic_messages };
        routes[1] = .{ .protocol = .openai_chat, .path_suffix = "/v1/chat/completions" };
        channel.routes = routes;
        channel.models = models;
        const channels = try scratch.alloc(profile_mod.ChannelDescriptor, 1);
        channels[0] = channel.*;
        const built = profile_mod.ProviderProfile{
            .id = metask_profile.PROFILE.id,
            .implementation_id = metask_profile.PROFILE.implementation_id,
            .display_name = metask_profile.PROFILE.display_name,
            .aliases = metask_profile.PROFILE.aliases,
            .channels = channels,
            .accepted_credential_kinds = metask_profile.PROFILE.accepted_credential_kinds,
            .env_aliases = metask_profile.PROFILE.env_aliases,
            .auth = metask_profile.PROFILE.auth,
            .default_channel = channel.id,
            .endpoint_policy = metask_profile.PROFILE.endpoint_policy,
            .oauth_token_url = metask_profile.PROFILE.oauth_token_url,
            .oauth_device_authorization_url = metask_profile.PROFILE.oauth_device_authorization_url,
            .oauth_client_id = metask_profile.PROFILE.oauth_client_id,
        };
        try self.registry.checkReplace(built);
        try self.registry.reserve(0);
        self.registry.replaceAssumeCapacity(built);
        if (self.catalog_arena) |*previous| previous.deinit();
        self.catalog_arena = arena;
        moved = true;
        self.refresh() catch return error.OutOfMemory;
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
        // Owned by these locals until `moved` flips. After that the host owns
        // them, and letting these errdefers still fire would free memory the
        // restore path below has already released — a double free, not a wrong
        // answer.
        var moved = false;
        var bindings: std.ArrayList(registry_mod.CredentialBinding) = .empty;
        errdefer if (!moved) bindings.deinit(self.allocator);
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
        errdefer if (!moved) disabled.deinit(self.allocator);
        for (document.providers.items) |entry| {
            if (entry.enabled) continue;
            disabled.append(self.allocator, entry.id) catch return error.OutOfMemory;
        }
        // The installation's OAuth clients (#87). Copied into the arena the
        // host keeps for them: a `Prepared` login holds the slice for the
        // whole grant, so the previous strings must outlive this swap.
        var client_ids: std.ArrayList(ConfiguredClientId) = .empty;
        errdefer if (!moved) client_ids.deinit(self.allocator);
        for (document.providers.items) |entry| {
            const configured = entry.oauth_client_id orelse continue;
            if (self.config_client_arena == null) {
                self.config_client_arena = std.heap.ArenaAllocator.init(self.allocator);
            }
            const owned = self.config_client_arena.?.allocator().dupe(u8, configured.slice()) catch
                return error.OutOfMemory;
            client_ids.append(self.allocator, .{ .provider_id = entry.id, .client_id = owned }) catch
                return error.OutOfMemory;
        }

        // The new configuration is *swapped in*, and the old lists are kept
        // until the rebuild succeeds: a failed rebuild would otherwise leave
        // the host claiming a configuration its catalog does not reflect.
        //
        // No early return when both lists are empty: the configuration can also
        // transition *back* to "nothing configured", and skipping the rebuild
        // then would leave the previous exclusions in force.
        const previous_bindings = self.config_bindings;
        const previous_exclusions = self.config_exclusions;
        const previous_client_ids = self.config_client_ids;
        moved = true;
        self.config_bindings = bindings;
        self.config_exclusions = disabled;
        self.config_client_ids = client_ids;
        errdefer {
            self.config_bindings.deinit(self.allocator);
            self.config_exclusions.deinit(self.allocator);
            self.config_client_ids.deinit(self.allocator);
            self.config_bindings = previous_bindings;
            self.config_exclusions = previous_exclusions;
            self.config_client_ids = previous_client_ids;
        }

        try self.rebuild();

        var retired_bindings = previous_bindings;
        var retired_exclusions = previous_exclusions;
        var retired_client_ids = previous_client_ids;
        retired_bindings.deinit(self.allocator);
        retired_exclusions.deinit(self.allocator);
        retired_client_ids.deinit(self.allocator);
    }

    /// The OAuth client the installation configured for `id`
    /// (`providers.<id>.oauth_client_id`), or null when it relies on the
    /// profile's own declaration or on `--client-id`. The slice stays valid
    /// for the host's lifetime (see `config_client_arena`).
    pub fn oauthClientIdFor(self: *const Host, id: Slug) ?[]const u8 {
        for (self.config_client_ids.items) |entry| {
            if (entry.provider_id.eql(id)) return entry.client_id;
        }
        return null;
    }

    /// Record the first reason a startup stage did not apply. The first is the
    /// most useful: later stages often fail *because* of it.
    fn noteStartupWarning(self: *Host, err: anyerror) void {
        if (self.startup_warning != null) return;
        self.startup_warning = @errorName(err);
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
            self.adoptCustomProviders(text) catch |err| self.noteStartupWarning(err);
            self.ingestConfiguredCatalogs(text) catch |err| self.noteStartupWarning(err);
        } else |err| self.noteStartupWarning(err);

        var document = store.load() catch |err| return self.noteStartupWarning(err);
        defer document.deinit();
        self.kernel.adoptConfigRevision(document.config_revision);
        self.applyProviderConfiguration(&document) catch |err| self.noteStartupWarning(err);
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

test "authenticated Metask catalog exposes both protocol routes" {
    const a = std.testing.allocator;
    const host = try Host.create(a);
    defer host.destroy();
    try host.ingestMetask("http://localhost:9000", "{\"object\":\"list\",\"data\":[{\"id\":\"metask-model\",\"display_name\":\"Gateway Model\",\"max_input_tokens\":32000,\"max_tokens\":2048,\"capabilities\":{\"thinking\":{\"supported\":true},\"image_input\":{\"supported\":false}}}]}");
    const profile = host.registry.find("metask").?;
    const channel = profile.channel(Slug.lit("default")).?;
    try std.testing.expectEqual(@as(usize, 1), channel.models.len);
    try std.testing.expectEqualStrings("Gateway Model", channel.models[0].display_name);
    try std.testing.expect(channel.route(.anthropic_messages) != null);
    try std.testing.expect(channel.route(.openai_chat) != null);
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

test "the installation's OAuth client id is looked up per provider and follows the configuration" {
    const a = std.testing.allocator;
    const host = try Host.create(a);
    defer host.destroy();
    try std.testing.expect(host.oauthClientIdFor(Slug.lit("openai")) == null);

    var document = config_doc.Document.init(a);
    defer document.deinit();
    try document.upsertProvider(.{
        .id = Slug.lit("openai"),
        .oauth_client_id = try config_doc.ClientIdText.parse("app_example_client"),
    });
    try host.applyProviderConfiguration(&document);
    const configured = host.oauthClientIdFor(Slug.lit("openai")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("app_example_client", configured);
    try std.testing.expect(host.oauthClientIdFor(Slug.lit("metask")) == null);

    // Removing the key removes the lookup; the string a login in flight may
    // still hold stays readable until the host goes away.
    var without = config_doc.Document.init(a);
    defer without.deinit();
    try without.upsertProvider(.{ .id = Slug.lit("openai") });
    try host.applyProviderConfiguration(&without);
    try std.testing.expect(host.oauthClientIdFor(Slug.lit("openai")) == null);
    try std.testing.expectEqualStrings("app_example_client", configured);
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

test "a failed rebuild restores the previous configuration exactly" {
    const a = std.testing.allocator;
    const host = try Host.create(a);
    defer host.destroy();

    var first = config_doc.Document.init(a);
    defer first.deinit();
    try first.upsertProvider(.{ .id = Slug.lit("gemini"), .enabled = false });
    try host.applyProviderConfiguration(&first);
    try std.testing.expectEqual(@as(usize, 1), host.config_exclusions.items.len);

    var second = config_doc.Document.init(a);
    defer second.deinit();
    try second.upsertProvider(.{ .id = Slug.lit("openai"), .enabled = false });

    // Fail after both new lists exist and the swap has happened, so the restore
    // path runs while the host owns them. Getting that handoff wrong is a
    // double free, not a wrong answer — the testing allocator is the detector.
    // (Verified non-vacuous: asserting the success branch is unreachable makes
    // this test fail.)
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 3 });
    host.allocator = failing.allocator();
    const result = host.applyProviderConfiguration(&second);
    host.allocator = a;
    try std.testing.expectError(error.OutOfMemory, result);

    // The previous configuration is intact, not a freed shell of it, and the
    // catalog still reflects it.
    try std.testing.expectEqual(@as(usize, 1), host.config_exclusions.items.len);
    try std.testing.expect(host.config_exclusions.items[0].eqlText("gemini"));
    for (host.kernel.catalogSnapshot().items()) |item| {
        try std.testing.expect(!item.provider_id.eqlText("gemini"));
    }
}

test "refreshing the same catalog twice replaces it instead of failing" {
    const a = std.testing.allocator;
    const host = try Host.create(a);
    defer host.destroy();
    const before = host.kernel.catalogSnapshot().items().len;

    const first_models =
        \\{"data": [{"id": "x/y", "name": "First", "context_length": 1000}]}
    ;
    const first_endpoints =
        \\{"data": {"id": "x/y", "endpoints": [{"provider_name": "Alpha"}]}}
    ;
    try host.ingestOpenRouter(Slug.lit("openrouter"), first_models, &.{first_endpoints});
    try std.testing.expectEqual(before + 1, host.kernel.catalogSnapshot().items().len);

    // `/providers refresh` runs this again. A second registration used to fail
    // with `DuplicateProviderId`, so refreshing simply did not work.
    const second_models =
        \\{"data": [{"id": "x/y", "name": "Second", "context_length": 2000}]}
    ;
    const second_endpoints =
        \\{"data": {"id": "x/y", "endpoints": [
        \\  {"provider_name": "Alpha"}, {"provider_name": "Beta"}]}}
    ;
    try host.ingestOpenRouter(Slug.lit("openrouter"), second_models, &.{second_endpoints});

    // The catalog reflects the *new* document, not a merge of both.
    try std.testing.expectEqual(before + 2, host.kernel.catalogSnapshot().items().len);
    var alpha: usize = 0;
    var beta: usize = 0;
    for (host.kernel.catalogSnapshot().items()) |item| {
        if (!item.provider_id.eqlText("openrouter")) continue;
        try std.testing.expectEqual(@as(?u32, 2000), item.limits.context_window);
        if (item.channel_id.eqlText("alpha")) alpha += 1;
        if (item.channel_id.eqlText("beta")) beta += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), alpha);
    try std.testing.expectEqual(@as(usize, 1), beta);
}

test "re-adopting custom providers replaces them and drops the ones removed" {
    const a = std.testing.allocator;
    const host = try Host.create(a);
    defer host.destroy();

    try host.adoptCustomProviders(
        \\{"custom_providers": {
        \\  "relay-a": {"channels":[{"id":"c","base_url":"https://a.example.com/v1","protocol":"openai_chat"}],
        \\              "models":[{"request_model_id":"m-a"}]},
        \\  "relay-b": {"channels":[{"id":"c","base_url":"https://b.example.com/v1","protocol":"openai_chat"}],
        \\              "models":[{"request_model_id":"m-b"}]}}}
    );
    try std.testing.expect(host.registry.find("relay-a") != null);
    try std.testing.expect(host.registry.find("relay-b") != null);

    // The user edits the config: `relay-b` is gone and `relay-a` changed. A
    // stale `relay-b` would keep pointing into the arena this call releases.
    try host.adoptCustomProviders(
        \\{"custom_providers": {
        \\  "relay-a": {"channels":[{"id":"c","base_url":"https://a2.example.com/v1","protocol":"openai_chat"}],
        \\              "models":[{"request_model_id":"m-a2"}]}}}
    );
    try std.testing.expect(host.registry.find("relay-b") == null);
    const updated = host.registry.find("relay-a").?;
    try std.testing.expectEqualStrings("https://a2.example.com/v1", updated.channels[0].base_url);

    var seen: usize = 0;
    for (host.kernel.catalogSnapshot().items()) |item| {
        if (item.provider_id.eqlText("relay-b")) return error.StaleProviderStillRouted;
        if (item.provider_id.eqlText("relay-a")) {
            seen += 1;
            try std.testing.expectEqualStrings("m-a2", item.request_model_id);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), seen);
}

test "a configured provider may not take over a built-in vendor's id" {
    const a = std.testing.allocator;
    const host = try Host.create(a);
    defer host.destroy();
    // Replacement is for a source's *own* registrations. Letting a config file
    // silently redefine `openai` would change where an existing session's
    // credentials go.
    try std.testing.expectError(error.DuplicateProviderId, host.adoptCustomProviders(
        \\{"custom_providers": {"openai": {
        \\  "channels":[{"id":"c","base_url":"https://evil.example.com/v1","protocol":"openai_chat"}],
        \\  "models":[{"request_model_id":"m"}]}}}
    ));
    try std.testing.expectEqualStrings(
        "https://api.openai.com/v1",
        host.registry.find("openai").?.channels[0].base_url,
    );
}

test "a startup stage that does not apply records why" {
    const a = std.testing.allocator;
    const host = try Host.create(a);
    defer host.destroy();
    try std.testing.expect(host.startup_warning == null);

    // A broken section otherwise disappears, and surfaces much later as
    // "unknown provider 'my-relay'" with nothing connecting the two.
    host.adoptCustomProviders(
        \\{"custom_providers": {"broken": {
        \\  "channels": [{"id":"c","base_url":"https://x.example.com/v1","protocol":"openai_chat"}]}}}
    ) catch |err| host.noteStartupWarning(err);
    try std.testing.expectEqualStrings("NoModels", host.startup_warning.?);

    // The first reason is kept: later stages often fail *because* of it, so the
    // last one is the least useful to report.
    host.noteStartupWarning(error.SomethingLater);
    try std.testing.expectEqualStrings("NoModels", host.startup_warning.?);

    // And the built-in providers still work.
    try std.testing.expect(host.kernel.catalogSnapshot().items().len > 0);
}
