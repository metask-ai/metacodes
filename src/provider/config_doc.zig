//! Versioned control-plane configuration document (issue #16, "Persistence,
//! ownership, and read timing").
//!
//! This module owns the *document*: its schema version, monotonic revision,
//! provider map, aliases, and global selection, plus the exact bytes written to
//! and read from `~/.metacodes/config.json`. It performs no I/O, so the
//! contract — round-trip fidelity, migration, rejection of newer schemas — is
//! testable without a filesystem. `config_store.zig` owns the atomic write.
//!
//! Two invariants shape the design:
//!
//! 1. **The document is a provider map, not a singleton.** Several providers,
//!    accounts, regions, and relays coexist; disabling one preserves its entry.
//! 2. **Serialization is a merge, not a rewrite.** Other writers own `theme`,
//!    `mcp_servers`, `permission_rules`, and `model_tiers` in the same file, so
//!    the control plane replaces only its own keys (`util/json_merge.zig`).
//!
//! Secrets never appear here: a provider entry stores a `CredentialRef` id and
//! nothing else, which is what makes redacted export/import safe by default.

const std = @import("std");
const ids = @import("ids.zig");
const controls_mod = @import("controls.zig");
const selection_mod = @import("selection.zig");
const offer_mod = @import("offer.zig");
const json_merge = @import("../util/json_merge.zig");

pub const Slug = ids.Slug;
pub const OfferId = ids.OfferId;
pub const OfferRevision = ids.OfferRevision;
pub const ConfigRevision = ids.ConfigRevision;
pub const CatalogRevision = ids.CatalogRevision;
pub const RuntimeSelection = selection_mod.RuntimeSelection;
pub const RoutePolicy = selection_mod.RoutePolicy;
pub const ChannelList = selection_mod.ChannelList;

pub const SCHEMA_VERSION: u16 = 1;

pub const RegionText = controls_mod.Bounded(32);
pub const UrlText = controls_mod.Bounded(256);
pub const ProtocolText = controls_mod.Bounded(48);
pub const AliasName = controls_mod.Bounded(48);
pub const OperationId = controls_mod.Bounded(64);

pub const MAX_PROTOCOL_DEFAULTS: usize = 4;

/// Retained idempotency keys. A single "last key" only recognizes a retry that
/// immediately follows its original, which is not what a retrying client does:
/// it retries after other traffic has landed. A small ring makes the guarantee
/// match the wording.
pub const MAX_RECENT_OPERATIONS: usize = 8;

pub const ProtocolList = struct {
    entries: [MAX_PROTOCOL_DEFAULTS]ProtocolText = undefined,
    len: u8 = 0,

    pub fn items(self: *const ProtocolList) []const ProtocolText {
        return self.entries[0..self.len];
    }

    pub fn append(self: *ProtocolList, text: []const u8) error{ TooManyProtocols, ControlTextTooLong }!void {
        if (self.len == MAX_PROTOCOL_DEFAULTS) return error.TooManyProtocols;
        self.entries[self.len] = try ProtocolText.parse(text);
        self.len += 1;
    }
};

/// One configured provider instance. Independent credentials, channels, and
/// endpoint policy; disabling preserves everything.
pub const ProviderEntry = struct {
    id: Slug,
    enabled: bool = true,
    credential_ref: ?Slug = null,
    region: ?RegionText = null,
    /// Channel allowlist for this instance. Empty = every channel the profile
    /// declares.
    channels: ChannelList = .{},
    protocol_defaults: ProtocolList = .{},
    base_url: ?UrlText = null,
};

pub const AliasPolicy = enum { pinned, floating };

/// A local alias is an explicit record, never a string heuristic. A pinned
/// alias stores the resolved offer and its revision; a floating alias stores
/// the selector and resolves again against a newer catalog.
pub const AliasEntry = struct {
    name: AliasName,
    policy: AliasPolicy,
    offer_id: ?OfferId = null,
    offer_revision: ?OfferRevision = null,
    selector: ?selection_mod.Selector = null,
    catalog_revision: ?CatalogRevision = null,
};

pub const DocumentError = error{
    UnsupportedSchemaVersion,
    InvalidDocument,
    DuplicateProviderId,
    DuplicateAliasName,
    InvalidSlug,
    ControlTextTooLong,
    TooManyChannels,
    TooManyProtocols,
    TooManyControls,
    OutOfMemory,
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    schema_version: u16 = SCHEMA_VERSION,
    config_revision: ConfigRevision = .initial,
    providers: std.ArrayList(ProviderEntry) = .empty,
    aliases: std.ArrayList(AliasEntry) = .empty,
    global_selection: ?RuntimeSelection = null,
    /// Selection scoped to one session, written to a session-local document
    /// rather than to `config.json`. Two sessions that shared one key would
    /// overwrite each other's choice, which is exactly what session scope
    /// promises not to do.
    session_selection: ?RuntimeSelection = null,
    /// Idempotency keys of the most recent commits, oldest first. A retry
    /// carrying any retained key is a no-op instead of a second revision bump.
    recent_operations: [MAX_RECENT_OPERATIONS]OperationId = undefined,
    recent_operation_len: u8 = 0,

    pub fn init(allocator: std.mem.Allocator) Document {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Document) void {
        self.providers.deinit(self.allocator);
        self.aliases.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn recentOperations(self: *const Document) []const OperationId {
        return self.recent_operations[0..self.recent_operation_len];
    }

    /// True when this key was used by one of the retained recent commits.
    pub fn hasOperation(self: *const Document, operation_id: []const u8) bool {
        for (self.recentOperations()) |entry| {
            if (entry.eqlText(operation_id)) return true;
        }
        return false;
    }

    pub fn recordOperation(self: *Document, operation_id: []const u8) DocumentError!void {
        const key = try OperationId.parse(operation_id);
        if (self.recent_operation_len == MAX_RECENT_OPERATIONS) {
            var index: usize = 0;
            while (index + 1 < MAX_RECENT_OPERATIONS) : (index += 1) {
                self.recent_operations[index] = self.recent_operations[index + 1];
            }
            self.recent_operation_len -= 1;
        }
        self.recent_operations[self.recent_operation_len] = key;
        self.recent_operation_len += 1;
    }

    pub fn provider(self: *const Document, id: Slug) ?ProviderEntry {
        for (self.providers.items) |entry| if (entry.id.eql(id)) return entry;
        return null;
    }

    /// Insert or replace one provider entry, leaving every other provider's
    /// configuration untouched.
    pub fn upsertProvider(self: *Document, entry: ProviderEntry) DocumentError!void {
        for (self.providers.items) |*existing| {
            if (existing.id.eql(entry.id)) {
                existing.* = entry;
                return;
            }
        }
        try self.providers.append(self.allocator, entry);
    }

    pub fn alias(self: *const Document, name: []const u8) ?AliasEntry {
        for (self.aliases.items) |entry| if (entry.name.eqlText(name)) return entry;
        return null;
    }

    pub fn upsertAlias(self: *Document, entry: AliasEntry) DocumentError!void {
        for (self.aliases.items) |*existing| {
            if (existing.name.eqlText(entry.name.slice())) {
                existing.* = entry;
                return;
            }
        }
        try self.aliases.append(self.allocator, entry);
    }

    pub fn removeAlias(self: *Document, name: []const u8) bool {
        for (self.aliases.items, 0..) |entry, index| {
            if (!entry.name.eqlText(name)) continue;
            _ = self.aliases.orderedRemove(index);
            return true;
        }
        return false;
    }

    /// Serialize the control-plane keys into `original`, preserving every key
    /// this module does not own.
    pub fn merge(self: *const Document, original: []const u8) DocumentError![]u8 {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();

        const schema = try std.fmt.allocPrint(arena, "{d}", .{self.schema_version});
        const revision = try std.fmt.allocPrint(arena, "{d}", .{self.config_revision.value()});
        const providers = try self.renderProviders(arena);
        const aliases = try self.renderAliases(arena);
        const selection = if (self.global_selection) |value|
            try renderSelection(arena, value)
        else
            null;
        const session = if (self.session_selection) |value|
            try renderSelection(arena, value)
        else
            null;
        var operations: ?[]u8 = null;
        if (self.recent_operation_len > 0) {
            var buffer: std.ArrayList(u8) = .empty;
            try buffer.append(arena, '[');
            for (self.recentOperations(), 0..) |operation_id, index| {
                if (index > 0) try buffer.append(arena, ',');
                try writeJsonString(arena, &buffer, operation_id.slice());
            }
            try buffer.append(arena, ']');
            operations = buffer.items;
        }

        return json_merge.mergeObjectFields(self.allocator, original, &.{
            .{ .key = "schema_version", .json = schema },
            .{ .key = "config_revision", .json = revision },
            .{ .key = "providers", .json = providers },
            .{ .key = "aliases", .json = aliases },
            .{ .key = "global_selection", .json = selection },
            .{ .key = "session_selection", .json = session },
            .{ .key = "recent_operation_ids", .json = operations },
        }) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidDocument,
        };
    }

    fn renderProviders(self: *const Document, arena: std.mem.Allocator) DocumentError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.append(arena, '{');
        for (self.providers.items, 0..) |entry, index| {
            if (index > 0) try out.append(arena, ',');
            try writeJsonString(arena, &out, entry.id.slice());
            try out.appendSlice(arena, ":{\"enabled\":");
            try out.appendSlice(arena, if (entry.enabled) "true" else "false");
            if (entry.credential_ref) |ref| {
                try out.appendSlice(arena, ",\"credential_ref\":");
                try writeJsonString(arena, &out, ref.slice());
            }
            if (entry.region) |region| {
                try out.appendSlice(arena, ",\"region\":");
                try writeJsonString(arena, &out, region.slice());
            }
            if (entry.base_url) |url| {
                try out.appendSlice(arena, ",\"base_url\":");
                try writeJsonString(arena, &out, url.slice());
            }
            if (entry.channels.len > 0) {
                try out.appendSlice(arena, ",\"channels\":");
                try writeSlugArray(arena, &out, entry.channels.items());
            }
            if (entry.protocol_defaults.len > 0) {
                try out.appendSlice(arena, ",\"protocol_defaults\":[");
                for (entry.protocol_defaults.items(), 0..) |protocol, position| {
                    if (position > 0) try out.append(arena, ',');
                    try writeJsonString(arena, &out, protocol.slice());
                }
                try out.append(arena, ']');
            }
            try out.append(arena, '}');
        }
        try out.append(arena, '}');
        return out.items;
    }

    fn renderAliases(self: *const Document, arena: std.mem.Allocator) DocumentError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.append(arena, '{');
        for (self.aliases.items, 0..) |entry, index| {
            if (index > 0) try out.append(arena, ',');
            try writeJsonString(arena, &out, entry.name.slice());
            try out.appendSlice(arena, ":{\"policy\":");
            try writeJsonString(arena, &out, @tagName(entry.policy));
            if (entry.offer_id) |offer_id| {
                try out.appendSlice(arena, ",\"offer_id\":");
                const text = offer_id.render();
                try writeJsonString(arena, &out, &text);
            }
            if (entry.offer_revision) |revision| {
                try out.appendSlice(arena, try std.fmt.allocPrint(arena, ",\"offer_revision\":{d}", .{revision}));
            }
            if (entry.selector) |selector| {
                try out.appendSlice(arena, ",\"selector\":");
                try writeJsonString(arena, &out, selector.slice());
            }
            if (entry.catalog_revision) |revision| {
                try out.appendSlice(arena, try std.fmt.allocPrint(
                    arena,
                    ",\"catalog_revision\":{d}",
                    .{revision.value()},
                ));
            }
            try out.append(arena, '}');
        }
        try out.append(arena, '}');
        return out.items;
    }
};

// ── selection serialization ──────────────────────────────────────────────────

pub fn renderSelection(arena: std.mem.Allocator, value: RuntimeSelection) DocumentError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"target\":");
    switch (value.target) {
        .pinned_offer => |pin| {
            try out.appendSlice(arena, "{\"kind\":\"pinned_offer\",\"offer_id\":");
            const text = pin.offer_id.render();
            try writeJsonString(arena, &out, &text);
            try out.appendSlice(arena, try std.fmt.allocPrint(
                arena,
                ",\"offer_revision\":{d}}}",
                .{pin.offer_revision},
            ));
        },
        .auto_route => |route| {
            try out.appendSlice(arena, "{\"kind\":\"auto_route\",\"selector\":");
            try writeJsonString(arena, &out, route.selector.slice());
            try out.appendSlice(arena, ",\"policy\":");
            try renderPolicy(arena, &out, route.policy);
            try out.append(arena, '}');
        },
    }
    try out.appendSlice(arena, ",\"scope\":");
    try writeJsonString(arena, &out, @tagName(value.scope));
    try out.appendSlice(arena, ",\"controls\":");
    try renderControls(arena, &out, value.controls);
    if (value.resolved_offer_id) |offer_id| {
        try out.appendSlice(arena, ",\"resolved_offer_id\":");
        const text = offer_id.render();
        try writeJsonString(arena, &out, &text);
    }
    if (value.resolved_offer_revision) |revision| {
        try out.appendSlice(arena, try std.fmt.allocPrint(
            arena,
            ",\"resolved_offer_revision\":{d}",
            .{revision},
        ));
    }
    try out.appendSlice(arena, try std.fmt.allocPrint(
        arena,
        ",\"catalog_revision\":{d}}}",
        .{value.catalog_revision.value()},
    ));
    return out.items;
}

fn renderPolicy(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    policy: RoutePolicy,
) DocumentError!void {
    try out.appendSlice(arena, "{\"fallback_allowed\":");
    try out.appendSlice(arena, if (policy.fallback_allowed) "true" else "false");
    try out.appendSlice(arena, ",\"require_parameters\":");
    try out.appendSlice(arena, if (policy.require_parameters) "true" else "false");
    try out.appendSlice(arena, ",\"sort_preference\":");
    try writeJsonString(arena, out, @tagName(policy.sort_preference));
    try out.appendSlice(arena, ",\"data_collection\":");
    try writeJsonString(arena, out, @tagName(policy.data_collection));
    if (policy.only_channels.len > 0) {
        try out.appendSlice(arena, ",\"only\":");
        try writeSlugArray(arena, out, policy.only_channels.items());
    }
    if (policy.ignore_channels.len > 0) {
        try out.appendSlice(arena, ",\"ignore\":");
        try writeSlugArray(arena, out, policy.ignore_channels.items());
    }
    if (policy.preferred_order.len > 0) {
        try out.appendSlice(arena, ",\"order\":");
        try writeSlugArray(arena, out, policy.preferred_order.items());
    }
    if (policy.hard_min_context_window) |value| {
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, ",\"hard_min_context_window\":{d}", .{value}));
    }
    if (policy.hard_max_latency_ms) |value| {
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, ",\"hard_max_latency_ms\":{d}", .{value}));
    }
    if (policy.hard_min_throughput_tps) |value| {
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, ",\"hard_min_throughput_tps\":{d}", .{value}));
    }
    if (policy.hard_max_price) |price| {
        try out.appendSlice(arena, ",\"hard_max_price\":{\"currency\":");
        try writeJsonString(arena, out, price.currency.slice());
        try out.appendSlice(arena, ",\"billing_unit\":");
        try writeJsonString(arena, out, @tagName(price.billing_unit));
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, ",\"max_micros\":{d}}}", .{price.max_micros}));
    }
    if (policy.zdr) |value| {
        try out.appendSlice(arena, ",\"zdr\":");
        try out.appendSlice(arena, if (value) "true" else "false");
    }
    if (policy.region) |value| {
        try out.appendSlice(arena, ",\"region\":");
        try writeJsonString(arena, out, value.slice());
    }
    if (policy.quantization) |value| {
        try out.appendSlice(arena, ",\"quantization\":");
        try writeJsonString(arena, out, value.slice());
    }
    try out.append(arena, '}');
}

fn renderControls(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    values: controls_mod.ControlValues,
) DocumentError!void {
    try out.append(arena, '{');
    for (values.items(), 0..) |entry, index| {
        if (index > 0) try out.append(arena, ',');
        try writeJsonString(arena, out, entry.id.slice());
        try out.append(arena, ':');
        // The value is tagged so a text control holding "true" round-trips as
        // text rather than being reinterpreted as a boolean.
        switch (entry.value) {
            .text => |text| {
                try out.appendSlice(arena, "{\"text\":");
                try writeJsonString(arena, out, text.slice());
                try out.append(arena, '}');
            },
            .object => |text| {
                try out.appendSlice(arena, "{\"object\":");
                try writeJsonString(arena, out, text.slice());
                try out.append(arena, '}');
            },
            .number => |number| try out.appendSlice(arena, try std.fmt.allocPrint(
                arena,
                "{{\"number\":{d}}}",
                .{number},
            )),
            .boolean => |flag| {
                try out.appendSlice(arena, "{\"boolean\":");
                try out.appendSlice(arena, if (flag) "true" else "false");
                try out.append(arena, '}');
            },
        }
    }
    try out.append(arena, '}');
}

fn writeSlugArray(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    list: []const Slug,
) DocumentError!void {
    try out.append(arena, '[');
    for (list, 0..) |entry, index| {
        if (index > 0) try out.append(arena, ',');
        try writeJsonString(arena, out, entry.slice());
    }
    try out.append(arena, ']');
}

fn writeJsonString(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
) DocumentError!void {
    try out.append(arena, '"');
    for (text) |byte| switch (byte) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        '\t' => try out.appendSlice(arena, "\\t"),
        else => {
            if (byte < 0x20) {
                try out.appendSlice(arena, try std.fmt.allocPrint(arena, "\\u{x:0>4}", .{byte}));
            } else try out.append(arena, byte);
        },
    };
    try out.append(arena, '"');
}

// ── parsing ──────────────────────────────────────────────────────────────────

/// Parse a configuration document.
///
/// A document with no `schema_version` is legacy state that predates the
/// control plane: it parses as an empty provider map at revision 1 rather than
/// failing, so an existing installation keeps working. A *newer* schema version
/// is rejected: silently merging a document this build does not understand
/// would drop the parts it cannot represent.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) DocumentError!Document {
    var document = Document.init(allocator);
    errdefer document.deinit();

    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return document;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const root = std.json.parseFromSliceLeaky(std.json.Value, scratch, trimmed, .{}) catch
        return error.InvalidDocument;
    if (root != .object) return error.InvalidDocument;

    if (root.object.get("schema_version")) |value| {
        const version = intOf(value) orelse return error.InvalidDocument;
        if (version > SCHEMA_VERSION) return error.UnsupportedSchemaVersion;
        document.schema_version = @intCast(version);
    } else {
        document.schema_version = SCHEMA_VERSION;
    }

    if (root.object.get("config_revision")) |value| {
        const revision = intOf(value) orelse return error.InvalidDocument;
        if (revision == 0) return error.InvalidDocument;
        document.config_revision = @enumFromInt(@as(u64, @intCast(revision)));
    }

    if (root.object.get("providers")) |value| {
        if (value != .object) return error.InvalidDocument;
        var it = value.object.iterator();
        while (it.next()) |pair| {
            const entry = try parseProvider(pair.key_ptr.*, pair.value_ptr.*);
            if (document.provider(entry.id) != null) return error.DuplicateProviderId;
            try document.providers.append(allocator, entry);
        }
    }

    if (root.object.get("aliases")) |value| {
        if (value != .object) return error.InvalidDocument;
        var it = value.object.iterator();
        while (it.next()) |pair| {
            const entry = try parseAlias(pair.key_ptr.*, pair.value_ptr.*);
            if (document.alias(entry.name.slice()) != null) return error.DuplicateAliasName;
            try document.aliases.append(allocator, entry);
        }
    }

    if (root.object.get("global_selection")) |value| {
        if (value != .null) document.global_selection = try parseSelection(value);
    }

    if (root.object.get("session_selection")) |value| {
        if (value != .null) document.session_selection = try parseSelection(value);
    }

    if (root.object.get("recent_operation_ids")) |list| {
        if (list != .array) return error.InvalidDocument;
        for (list.array.items) |item| {
            const operation_text = stringOf(item) orelse return error.InvalidDocument;
            try document.recordOperation(operation_text);
        }
    } else if (stringOf(root.object.get("last_operation_id"))) |operation_text| {
        // Documents written before the ring existed carry a single key.
        try document.recordOperation(operation_text);
    }

    return document;
}

fn parseProvider(key: []const u8, value: std.json.Value) DocumentError!ProviderEntry {
    if (value != .object) return error.InvalidDocument;
    var entry = ProviderEntry{ .id = Slug.parse(key) catch return error.InvalidSlug };
    if (value.object.get("enabled")) |flag| {
        if (flag != .bool) return error.InvalidDocument;
        entry.enabled = flag.bool;
    }
    if (stringOf(value.object.get("credential_ref"))) |text| {
        entry.credential_ref = Slug.parse(text) catch return error.InvalidSlug;
    }
    if (stringOf(value.object.get("region"))) |text| {
        entry.region = try RegionText.parse(text);
    }
    if (stringOf(value.object.get("base_url"))) |text| {
        entry.base_url = try UrlText.parse(text);
    }
    if (value.object.get("channels")) |list| {
        if (list != .array) return error.InvalidDocument;
        for (list.array.items) |item| {
            const text = stringOf(item) orelse return error.InvalidDocument;
            try entry.channels.append(Slug.parse(text) catch return error.InvalidSlug);
        }
    }
    if (value.object.get("protocol_defaults")) |list| {
        if (list != .array) return error.InvalidDocument;
        for (list.array.items) |item| {
            const text = stringOf(item) orelse return error.InvalidDocument;
            try entry.protocol_defaults.append(text);
        }
    }
    return entry;
}

fn parseAlias(key: []const u8, value: std.json.Value) DocumentError!AliasEntry {
    if (value != .object) return error.InvalidDocument;
    const policy_text = stringOf(value.object.get("policy")) orelse return error.InvalidDocument;
    const policy: AliasPolicy = if (std.mem.eql(u8, policy_text, "pinned"))
        .pinned
    else if (std.mem.eql(u8, policy_text, "floating"))
        .floating
    else
        return error.InvalidDocument;

    var entry = AliasEntry{ .name = try AliasName.parse(key), .policy = policy };
    if (stringOf(value.object.get("offer_id"))) |text| {
        entry.offer_id = OfferId.parse(text) catch return error.InvalidDocument;
    }
    if (value.object.get("offer_revision")) |number| {
        entry.offer_revision = @intCast(intOf(number) orelse return error.InvalidDocument);
    }
    if (stringOf(value.object.get("selector"))) |text| {
        entry.selector = try selection_mod.Selector.parse(text);
    }
    if (value.object.get("catalog_revision")) |number| {
        const revision = intOf(number) orelse return error.InvalidDocument;
        entry.catalog_revision = @enumFromInt(@as(u64, @intCast(revision)));
    }
    // A pinned alias without a resolved offer is not reproducible, and a
    // floating alias without a selector cannot resolve at all.
    switch (policy) {
        .pinned => if (entry.offer_id == null) return error.InvalidDocument,
        .floating => if (entry.selector == null) return error.InvalidDocument,
    }
    return entry;
}

pub fn parseSelection(value: std.json.Value) DocumentError!RuntimeSelection {
    if (value != .object) return error.InvalidDocument;
    const target_value = value.object.get("target") orelse return error.InvalidDocument;
    if (target_value != .object) return error.InvalidDocument;
    const kind = stringOf(target_value.object.get("kind")) orelse return error.InvalidDocument;

    var out = RuntimeSelection{ .target = undefined };
    if (std.mem.eql(u8, kind, "pinned_offer")) {
        const offer_text = stringOf(target_value.object.get("offer_id")) orelse return error.InvalidDocument;
        const revision: OfferRevision = if (target_value.object.get("offer_revision")) |number|
            @intCast(intOf(number) orelse return error.InvalidDocument)
        else
            1;
        out.target = .{ .pinned_offer = .{
            .offer_id = OfferId.parse(offer_text) catch return error.InvalidDocument,
            .offer_revision = revision,
        } };
    } else if (std.mem.eql(u8, kind, "auto_route")) {
        const selector = stringOf(target_value.object.get("selector")) orelse return error.InvalidDocument;
        const policy = if (target_value.object.get("policy")) |policy_value|
            try parsePolicy(policy_value)
        else
            RoutePolicy{};
        out.target = .{ .auto_route = .{
            .selector = try selection_mod.Selector.parse(selector),
            .policy = policy,
        } };
    } else return error.InvalidDocument;

    if (stringOf(value.object.get("scope"))) |scope_text| {
        out.scope = if (std.mem.eql(u8, scope_text, "once"))
            .once
        else if (std.mem.eql(u8, scope_text, "session"))
            .session
        else if (std.mem.eql(u8, scope_text, "global"))
            .global
        else
            return error.InvalidDocument;
    }
    if (value.object.get("controls")) |controls_value| {
        out.controls = try parseControls(controls_value);
    }
    if (stringOf(value.object.get("resolved_offer_id"))) |text| {
        out.resolved_offer_id = OfferId.parse(text) catch return error.InvalidDocument;
    }
    if (value.object.get("resolved_offer_revision")) |number| {
        out.resolved_offer_revision = @intCast(intOf(number) orelse return error.InvalidDocument);
    }
    if (value.object.get("catalog_revision")) |number| {
        const revision = intOf(number) orelse return error.InvalidDocument;
        if (revision == 0) return error.InvalidDocument;
        out.catalog_revision = @enumFromInt(@as(u64, @intCast(revision)));
    }
    return out;
}

fn parsePolicy(value: std.json.Value) DocumentError!RoutePolicy {
    if (value != .object) return error.InvalidDocument;
    var policy = RoutePolicy{};
    if (value.object.get("fallback_allowed")) |flag| {
        if (flag != .bool) return error.InvalidDocument;
        policy.fallback_allowed = flag.bool;
    }
    if (value.object.get("require_parameters")) |flag| {
        if (flag != .bool) return error.InvalidDocument;
        policy.require_parameters = flag.bool;
    }
    if (stringOf(value.object.get("sort_preference"))) |text| {
        policy.sort_preference = std.meta.stringToEnum(selection_mod.SortPreference, text) orelse
            return error.InvalidDocument;
    }
    if (stringOf(value.object.get("data_collection"))) |text| {
        policy.data_collection = std.meta.stringToEnum(selection_mod.DataCollection, text) orelse
            return error.InvalidDocument;
    }
    policy.only_channels = try parseSlugList(value.object.get("only"));
    policy.ignore_channels = try parseSlugList(value.object.get("ignore"));
    policy.preferred_order = try parseSlugList(value.object.get("order"));
    if (value.object.get("hard_min_context_window")) |number| {
        policy.hard_min_context_window = @intCast(intOf(number) orelse return error.InvalidDocument);
    }
    if (value.object.get("hard_max_latency_ms")) |number| {
        policy.hard_max_latency_ms = @intCast(intOf(number) orelse return error.InvalidDocument);
    }
    if (value.object.get("hard_min_throughput_tps")) |number| {
        policy.hard_min_throughput_tps = @intCast(intOf(number) orelse return error.InvalidDocument);
    }
    if (value.object.get("hard_max_price")) |price_value| {
        if (price_value != .object) return error.InvalidDocument;
        const currency_text = stringOf(price_value.object.get("currency")) orelse return error.InvalidDocument;
        const unit_text = stringOf(price_value.object.get("billing_unit")) orelse return error.InvalidDocument;
        const max_value = intOf(price_value.object.get("max_micros") orelse return error.InvalidDocument) orelse
            return error.InvalidDocument;
        policy.hard_max_price = .{
            .currency = offer_mod.Currency.parse(currency_text) catch return error.InvalidDocument,
            .billing_unit = std.meta.stringToEnum(offer_mod.BillingUnit, unit_text) orelse
                return error.InvalidDocument,
            .max_micros = @intCast(max_value),
        };
    }
    if (value.object.get("zdr")) |flag| {
        if (flag != .bool) return error.InvalidDocument;
        policy.zdr = flag.bool;
    }
    if (stringOf(value.object.get("region"))) |text| {
        policy.region = try selection_mod.RegionText.parse(text);
    }
    if (stringOf(value.object.get("quantization"))) |text| {
        policy.quantization = try selection_mod.QuantizationText.parse(text);
    }
    return policy;
}

fn parseSlugList(maybe: ?std.json.Value) DocumentError!ChannelList {
    var list = ChannelList{};
    const value = maybe orelse return list;
    if (value != .array) return error.InvalidDocument;
    for (value.array.items) |item| {
        const text = stringOf(item) orelse return error.InvalidDocument;
        try list.append(Slug.parse(text) catch return error.InvalidSlug);
    }
    return list;
}

fn parseControls(value: std.json.Value) DocumentError!controls_mod.ControlValues {
    var out = controls_mod.ControlValues{};
    if (value != .object) return error.InvalidDocument;
    var it = value.object.iterator();
    while (it.next()) |pair| {
        const wrapper = pair.value_ptr.*;
        if (wrapper != .object) return error.InvalidDocument;
        const control_value: controls_mod.Value = blk: {
            if (stringOf(wrapper.object.get("text"))) |text|
                break :blk try controls_mod.Value.fromText(text);
            if (stringOf(wrapper.object.get("object"))) |text|
                break :blk try controls_mod.Value.fromObject(text);
            if (wrapper.object.get("number")) |number|
                break :blk .{ .number = intOf(number) orelse return error.InvalidDocument };
            if (wrapper.object.get("boolean")) |flag| {
                if (flag != .bool) return error.InvalidDocument;
                break :blk .{ .boolean = flag.bool };
            }
            return error.InvalidDocument;
        };
        try out.set(pair.key_ptr.*, control_value);
    }
    return out;
}

fn stringOf(maybe: ?std.json.Value) ?[]const u8 {
    const value = maybe orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn intOf(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |number| number,
        else => null,
    };
}

// ── tests ────────────────────────────────────────────────────────────────────

test "several providers coexist and disabling one preserves the others" {
    const a = std.testing.allocator;
    var document = Document.init(a);
    defer document.deinit();
    document.config_revision = @enumFromInt(42);

    try document.upsertProvider(.{
        .id = Slug.lit("metask"),
        .credential_ref = Slug.lit("cred-metask-oauth"),
    });
    var openai = ProviderEntry{ .id = Slug.lit("openai"), .credential_ref = Slug.lit("cred-openai-oauth") };
    try openai.protocol_defaults.append("openai_responses");
    try document.upsertProvider(openai);
    try document.upsertProvider(.{
        .id = Slug.lit("zai-coding-plan"),
        .credential_ref = Slug.lit("cred-zai-1"),
        .region = try RegionText.parse("cn"),
    });
    var relay = ProviderEntry{ .id = Slug.lit("relay-a"), .credential_ref = Slug.lit("cred-relay-a") };
    try relay.channels.append(Slug.lit("channel-1"));
    try relay.channels.append(Slug.lit("channel-2"));
    try document.upsertProvider(relay);

    const text = try document.merge("{}");
    defer a.free(text);

    var reloaded = try parse(a, text);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 4), reloaded.providers.items.len);
    try std.testing.expectEqual(@as(u64, 42), reloaded.config_revision.value());
    try std.testing.expect(reloaded.provider(Slug.lit("zai-coding-plan")).?.region.?.eqlText("cn"));
    try std.testing.expect(reloaded.provider(Slug.lit("relay-a")).?.channels.len == 2);
    try std.testing.expect(
        reloaded.provider(Slug.lit("openai")).?.protocol_defaults.items()[0].eqlText("openai_responses"),
    );

    // Disabling one provider preserves its configuration and the others.
    var disabled = reloaded.provider(Slug.lit("openai")).?;
    disabled.enabled = false;
    try reloaded.upsertProvider(disabled);
    const after = try reloaded.merge(text);
    defer a.free(after);
    var again = try parse(a, after);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 4), again.providers.items.len);
    try std.testing.expect(!again.provider(Slug.lit("openai")).?.enabled);
    try std.testing.expect(again.provider(Slug.lit("openai")).?.credential_ref.?.eqlText("cred-openai-oauth"));
    try std.testing.expect(again.provider(Slug.lit("metask")).?.enabled);
}

test "the control plane never clobbers another writer's keys" {
    const a = std.testing.allocator;
    var document = Document.init(a);
    defer document.deinit();
    try document.upsertProvider(.{ .id = Slug.lit("metask") });

    const original =
        \\{"model":"claude-sonnet-4-6","theme":"dark","mcp_servers":[{"name":"kg","command":"tinykg"}],
        \\ "permission_rules":[{"tool":"Bash"}],"model_tiers":{"fast":"haiku"}}
    ;
    const merged = try document.merge(original);
    defer a.free(merged);
    for ([_][]const u8{ "theme", "mcp_servers", "permission_rules", "model_tiers", "claude-sonnet-4-6", "tinykg" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, merged, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, merged, "\"providers\"") != null);
}

test "pinned and floating aliases are explicit records" {
    const a = std.testing.allocator;
    var document = Document.init(a);
    defer document.deinit();

    const offer_id = OfferId.derive(.{
        .provider_id = Slug.lit("zai-coding-plan"),
        .channel_id = Slug.lit("cn-anthropic"),
        .protocol = "anthropic_messages",
        .endpoint_url = "https://open.bigmodel.cn/api/anthropic/v1/messages",
        .request_model_id = "glm-4.6",
    });
    try document.upsertAlias(.{
        .name = try AliasName.parse("work"),
        .policy = .pinned,
        .offer_id = offer_id,
        .offer_revision = 7,
    });
    try document.upsertAlias(.{
        .name = try AliasName.parse("latest"),
        .policy = .floating,
        .selector = try selection_mod.Selector.parse("zai/glm-4.6"),
        .catalog_revision = @enumFromInt(11),
    });

    const text = try document.merge("{}");
    defer a.free(text);
    var reloaded = try parse(a, text);
    defer reloaded.deinit();

    const work = reloaded.alias("work").?;
    try std.testing.expectEqual(AliasPolicy.pinned, work.policy);
    try std.testing.expect(work.offer_id.?.eql(offer_id));
    try std.testing.expectEqual(@as(?OfferRevision, 7), work.offer_revision);

    const latest = reloaded.alias("latest").?;
    try std.testing.expectEqual(AliasPolicy.floating, latest.policy);
    try std.testing.expect(latest.selector.?.eqlText("zai/glm-4.6"));
    try std.testing.expectEqual(@as(u64, 11), latest.catalog_revision.?.value());

    try std.testing.expect(reloaded.removeAlias("work"));
    try std.testing.expect(reloaded.alias("work") == null);
}

test "an alias that cannot resolve is rejected at parse time" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidDocument, parse(a,
        \\{"schema_version":1,"aliases":{"work":{"policy":"pinned"}}}
    ));
    try std.testing.expectError(error.InvalidDocument, parse(a,
        \\{"schema_version":1,"aliases":{"work":{"policy":"floating"}}}
    ));
}

test "a full runtime selection round-trips including its route policy" {
    const a = std.testing.allocator;
    var document = Document.init(a);
    defer document.deinit();

    var policy = RoutePolicy{
        .fallback_allowed = true,
        .require_parameters = true,
        .sort_preference = .price,
        .data_collection = .deny,
        .hard_min_context_window = 128_000,
        .hard_max_latency_ms = 2_500,
        .hard_min_throughput_tps = 40,
        .zdr = true,
        .hard_max_price = .{
            .currency = offer_mod.Currency.lit("USD"),
            .billing_unit = .per_million_tokens,
            .max_micros = 5_000_000,
        },
        .region = try selection_mod.RegionText.parse("cn"),
        .quantization = try selection_mod.QuantizationText.parse("bf16"),
    };
    policy.only_channels = try ChannelList.of(&.{Slug.lit("cn-anthropic")});
    policy.ignore_channels = try ChannelList.of(&.{Slug.lit("global-openai")});
    policy.preferred_order = try ChannelList.of(&.{ Slug.lit("cn-anthropic"), Slug.lit("cn-openai") });

    var value = try RuntimeSelection.auto("zai/glm-4.6", policy, .global);
    try value.controls.set("reasoning_effort", try controls_mod.Value.fromText("high"));
    try value.controls.set("max_output_tokens", .{ .number = 8_000 });
    try value.controls.set("verbose_stream", .{ .boolean = true });
    try value.controls.set("vendor_knob", try controls_mod.Value.fromObject("{\"depth\":2}"));
    value.catalog_revision = @enumFromInt(9);
    document.global_selection = value;

    const text = try document.merge("{}");
    defer a.free(text);
    var reloaded = try parse(a, text);
    defer reloaded.deinit();

    const restored = reloaded.global_selection.?;
    try std.testing.expect(restored.target == .auto_route);
    try std.testing.expect(restored.target.auto_route.selector.eqlText("zai/glm-4.6"));
    const restored_policy = restored.target.auto_route.policy;
    try std.testing.expect(restored_policy.fallback_allowed);
    try std.testing.expect(restored_policy.require_parameters);
    try std.testing.expectEqual(selection_mod.SortPreference.price, restored_policy.sort_preference);
    try std.testing.expectEqual(selection_mod.DataCollection.deny, restored_policy.data_collection);
    try std.testing.expectEqual(@as(?u32, 128_000), restored_policy.hard_min_context_window);
    try std.testing.expectEqual(@as(?u32, 2_500), restored_policy.hard_max_latency_ms);
    try std.testing.expectEqual(@as(?u32, 40), restored_policy.hard_min_throughput_tps);
    try std.testing.expectEqual(@as(?bool, true), restored_policy.zdr);
    try std.testing.expect(restored_policy.hard_max_price.?.currency.eql(offer_mod.Currency.lit("USD")));
    try std.testing.expectEqual(@as(u64, 5_000_000), restored_policy.hard_max_price.?.max_micros);
    try std.testing.expect(restored_policy.region.?.eqlText("cn"));
    try std.testing.expect(restored_policy.quantization.?.eqlText("bf16"));
    try std.testing.expectEqual(@as(u8, 1), restored_policy.only_channels.len);
    try std.testing.expectEqual(@as(u8, 2), restored_policy.preferred_order.len);
    try std.testing.expectEqual(selection_mod.Scope.global, restored.scope);
    try std.testing.expectEqual(@as(u64, 9), restored.catalog_revision.value());
    try std.testing.expect(restored.controls.eql(value.controls));
}

test "control values keep their declared type across a round trip" {
    const a = std.testing.allocator;
    var document = Document.init(a);
    defer document.deinit();
    var value = try RuntimeSelection.auto("m", .{}, .session);
    // A text control whose content looks like a boolean must not come back as
    // one; the tagged encoding is what prevents that.
    try value.controls.set("mode", try controls_mod.Value.fromText("true"));
    document.global_selection = value;

    const text = try document.merge("{}");
    defer a.free(text);
    var reloaded = try parse(a, text);
    defer reloaded.deinit();
    const restored = reloaded.global_selection.?.controls.get("mode").?;
    try std.testing.expect(restored == .text);
    try std.testing.expect(restored.text.eqlText("true"));
}

test "a pinned global selection round-trips with its resolved offer" {
    const a = std.testing.allocator;
    var document = Document.init(a);
    defer document.deinit();
    const offer_id = OfferId.derive(.{
        .provider_id = Slug.lit("metask"),
        .channel_id = Slug.lit("default"),
        .protocol = "anthropic_messages",
        .endpoint_url = "https://napi.metask-ai.com/v1/messages",
        .request_model_id = "claude-sonnet-4-6",
    });
    var value = RuntimeSelection.pinned(offer_id, 3, .global);
    value.resolved_offer_id = offer_id;
    value.resolved_offer_revision = 3;
    document.global_selection = value;

    const text = try document.merge("{}");
    defer a.free(text);
    var reloaded = try parse(a, text);
    defer reloaded.deinit();
    const restored = reloaded.global_selection.?;
    try std.testing.expect(restored.target.pinned_offer.offer_id.eql(offer_id));
    try std.testing.expectEqual(@as(OfferRevision, 3), restored.target.pinned_offer.offer_revision);
    try std.testing.expect(restored.resolved_offer_id.?.eql(offer_id));
}

test "legacy documents without a control plane load as empty, not as an error" {
    const a = std.testing.allocator;
    var document = try parse(a,
        \\{"model":"claude-sonnet-4-6","permission_mode":"prompt","max_turns":50}
    );
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 0), document.providers.items.len);
    try std.testing.expectEqual(@as(u64, 1), document.config_revision.value());
    try std.testing.expect(document.global_selection == null);
}

test "a newer schema version is rejected rather than silently merged" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedSchemaVersion, parse(a,
        \\{"schema_version":2,"providers":{}}
    ));
}

test "malformed documents fail closed" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidDocument, parse(a, "{"));
    try std.testing.expectError(error.InvalidDocument, parse(a, "[1,2]"));
    try std.testing.expectError(error.InvalidDocument, parse(a,
        \\{"schema_version":1,"providers":[]}
    ));
    try std.testing.expectError(error.InvalidSlug, parse(a,
        \\{"schema_version":1,"providers":{"Bad/Id":{"enabled":true}}}
    ));
    try std.testing.expectError(error.InvalidDocument, parse(a,
        \\{"schema_version":1,"config_revision":0}
    ));
}

test "an exported document carries references but no secret material" {
    const a = std.testing.allocator;
    var document = Document.init(a);
    defer document.deinit();
    try document.upsertProvider(.{
        .id = Slug.lit("zai-coding-plan"),
        .credential_ref = Slug.lit("cred-zai-1"),
        .base_url = try UrlText.parse("https://relay.internal/api/coding/paas/v4"),
    });
    const text = try document.merge("{}");
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "cred-zai-1") != null);
    for ([_][]const u8{ "api_key", "access_token", "refresh_token", "Bearer", "sk-" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, text, needle) == null);
    }
}

test "idempotency keys survive intervening commits" {
    const a = std.testing.allocator;
    var document = Document.init(a);
    defer document.deinit();

    try document.recordOperation("op-1");
    try document.recordOperation("op-2");
    try std.testing.expect(document.hasOperation("op-1"));
    try std.testing.expect(!document.hasOperation("op-3"));

    const text = try document.merge("{}");
    defer a.free(text);
    var reloaded = try parse(a, text);
    defer reloaded.deinit();
    // A retry of the *earlier* key is still recognized after later traffic —
    // the single-key form could only ever recognize the immediately previous
    // commit.
    try std.testing.expect(reloaded.hasOperation("op-1"));
    try std.testing.expect(reloaded.hasOperation("op-2"));

    // The ring evicts oldest-first and stays bounded.
    var index: usize = 0;
    while (index < MAX_RECENT_OPERATIONS) : (index += 1) {
        var name: [16]u8 = undefined;
        try reloaded.recordOperation(try std.fmt.bufPrint(&name, "fill-{d}", .{index}));
    }
    try std.testing.expectEqual(@as(u8, MAX_RECENT_OPERATIONS), reloaded.recent_operation_len);
    try std.testing.expect(!reloaded.hasOperation("op-1"));
    try std.testing.expect(reloaded.hasOperation("fill-0"));
}

test "a legacy single-key document upgrades to the ring" {
    const a = std.testing.allocator;
    var document = try parse(a,
        \\{"schema_version":1,"config_revision":4,"last_operation_id":"op-legacy"}
    );
    defer document.deinit();
    try std.testing.expect(document.hasOperation("op-legacy"));

    const text = try document.merge("{}");
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "recent_operation_ids") != null);
}

test "session and global selections are separate keys, not one shared slot" {
    const a = std.testing.allocator;
    var document = Document.init(a);
    defer document.deinit();

    const global_offer = OfferId.derive(.{
        .provider_id = Slug.lit("metask"),
        .channel_id = Slug.lit("default"),
        .protocol = "anthropic_messages",
        .endpoint_url = "https://napi.metask-ai.com/v1/messages",
        .request_model_id = "claude-sonnet-4-6",
    });
    const session_offer = OfferId.derive(.{
        .provider_id = Slug.lit("zai-coding-plan"),
        .channel_id = Slug.lit("cn-anthropic"),
        .protocol = "anthropic_messages",
        .endpoint_url = "https://open.bigmodel.cn/api/anthropic/v1/messages",
        .request_model_id = "glm-4.6",
    });
    document.global_selection = RuntimeSelection.pinned(global_offer, 1, .global);
    document.session_selection = RuntimeSelection.pinned(session_offer, 2, .session);

    const text = try document.merge("{}");
    defer a.free(text);
    var reloaded = try parse(a, text);
    defer reloaded.deinit();

    // A session choice that overwrote the global one would silently change
    // every other session on the machine.
    try std.testing.expect(reloaded.global_selection.?.target.pinned_offer.offer_id.eql(global_offer));
    try std.testing.expect(reloaded.session_selection.?.target.pinned_offer.offer_id.eql(session_offer));
    try std.testing.expectEqual(selection_mod.Scope.session, reloaded.session_selection.?.scope);
}

test "a document with only a session selection leaves the global slot empty" {
    const a = std.testing.allocator;
    var document = try parse(a,
        \\{"schema_version":1,"session_selection":{"target":{"kind":"auto_route","selector":"glm-4.6"},"scope":"session"}}
    );
    defer document.deinit();
    try std.testing.expect(document.global_selection == null);
    try std.testing.expectEqualStrings("glm-4.6", document.session_selection.?.target.auto_route.selector.slice());
}
