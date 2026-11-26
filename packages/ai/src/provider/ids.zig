//! Provider identity primitives (issue #16, delivery slice P0).
//!
//! The kernel distinguishes several identities that were previously collapsed
//! into one `model` string:
//!
//! ```text
//! ProviderId   stable metacodes identity of a provider profile
//! ChannelId    provider-owned route identity (endpoint/region/plan/account)
//! OfferId      opaque durable identity of ONE concrete selectable route
//! ```
//!
//! Two rules drive the representation:
//!
//! 1. **Ids are values, never borrowed slices.** A `ProviderId` is stored in
//!    hash maps, config documents, and selection snapshots that outlive the
//!    catalog they were derived from. A fixed inline array cannot dangle when
//!    the owning list grows (see CLAUDE.md "Collection 里的 slice key 会随 grow
//!    悬挂").
//! 2. **`OfferId` is derived, not generated.** The requirement is explicit: an
//!    offer id must be stable across catalog refreshes and must not be derived
//!    from a model name alone. It is therefore a domain-separated digest over
//!    the *normalized stable route binding*, and metadata churn is tracked by
//!    `offer_revision`/`catalog_revision` instead.

const std = @import("std");

pub const MAX_SLUG_LEN: usize = 64;

pub const SlugError = error{InvalidSlug};

/// Lowercase, delimiter-free stable identifier used for `ProviderId`,
/// `ChannelId`, and `CredentialRefId`.
///
/// The character set is deliberately narrow. Ids are concatenated into
/// human-auditable config keys and into the offer digest, so allowing `/`,
/// whitespace, or case variants would make two different routes render (or
/// hash) identically. Free-form vendor strings — request/canonical/upstream
/// model ids — are NOT slugs; they keep their exact provider spelling.
pub const Slug = struct {
    bytes: [MAX_SLUG_LEN]u8 = @splat(0),
    len: u8 = 0,

    pub fn parse(text: []const u8) SlugError!Slug {
        if (text.len == 0 or text.len > MAX_SLUG_LEN) return error.InvalidSlug;
        if (!isSlugStart(text[0])) return error.InvalidSlug;
        for (text) |byte| if (!isSlugByte(byte)) return error.InvalidSlug;
        var out = Slug{ .len = @intCast(text.len) };
        @memcpy(out.bytes[0..text.len], text);
        return out;
    }

    /// Comptime construction for built-in profile tables: an invalid literal is
    /// a compile error rather than a startup failure.
    pub fn lit(comptime text: []const u8) Slug {
        return comptime blk: {
            break :blk parse(text) catch @compileError("invalid slug literal: " ++ text);
        };
    }

    pub fn slice(self: *const Slug) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: Slug, other: Slug) bool {
        return self.len == other.len and
            std.mem.eql(u8, self.bytes[0..self.len], other.bytes[0..other.len]);
    }

    pub fn eqlText(self: Slug, text: []const u8) bool {
        return std.mem.eql(u8, self.bytes[0..self.len], text);
    }

    pub fn format(self: Slug, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.bytes[0..self.len]);
    }
};

fn isSlugStart(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9');
}

fn isSlugByte(byte: u8) bool {
    return isSlugStart(byte) or byte == '-' or byte == '_' or byte == '.';
}

/// Monotonic revision counters. They are distinct types so a catalog revision
/// can never be compared against, or written into, a config revision slot.
pub const CatalogRevision = enum(u64) {
    initial = 1,
    _,

    pub fn value(self: CatalogRevision) u64 {
        return @intFromEnum(self);
    }
    pub fn next(self: CatalogRevision) CatalogRevision {
        return @enumFromInt(@intFromEnum(self) + 1);
    }
};

pub const ConfigRevision = enum(u64) {
    initial = 1,
    _,

    pub fn value(self: ConfigRevision) u64 {
        return @intFromEnum(self);
    }
    pub fn next(self: ConfigRevision) ConfigRevision {
        return @enumFromInt(@intFromEnum(self) + 1);
    }
};

/// Metadata generation of one offer. Bumped when a refresh changes limits,
/// pricing, capabilities, or health while the route binding is unchanged.
pub const OfferRevision = u32;

pub const OFFER_ID_TEXT_LEN: usize = "offer-".len + 32;

/// Opaque durable identity of a concrete model route.
///
/// Derived (never randomly generated) so that the same route produces the same
/// id on every process, machine, and catalog refresh. A provider that supplies
/// its own stable offer id can use `fromProviderSupplied`, which still hashes
/// into the same space with a different domain tag so the two namespaces can
/// never collide.
pub const OfferId = struct {
    digest: [16]u8,

    pub const DERIVATION_DOMAIN = "metacodes.offer.v1";
    pub const PROVIDER_SUPPLIED_DOMAIN = "metacodes.offer.supplied.v1";

    /// Normalized stable binding fields. Changing any of these is a *different
    /// route* and therefore a different offer; everything else (display name,
    /// price, limits, health) is metadata and only moves `offer_revision`.
    pub const Binding = struct {
        provider_id: Slug,
        channel_id: Slug,
        protocol: []const u8,
        endpoint_url: []const u8,
        request_model_id: []const u8,
        /// Credential binding, not credential material. Empty means "no
        /// credential bound yet", which is itself a distinct route identity
        /// from a bound one.
        credential_ref: []const u8 = "",
    };

    pub fn derive(binding: Binding) OfferId {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(DERIVATION_DOMAIN);
        // Length-prefix every field. Plain concatenation would make
        // (provider "a-b", channel "c") collide with (provider "a", channel "b-c").
        absorb(&hasher, binding.provider_id.slice());
        absorb(&hasher, binding.channel_id.slice());
        absorb(&hasher, binding.protocol);
        absorb(&hasher, binding.endpoint_url);
        absorb(&hasher, binding.request_model_id);
        absorb(&hasher, binding.credential_ref);
        var full: [32]u8 = undefined;
        hasher.final(&full);
        var out: OfferId = .{ .digest = undefined };
        @memcpy(&out.digest, full[0..16]);
        return out;
    }

    pub fn fromProviderSupplied(provider_id: Slug, supplied: []const u8) OfferId {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(PROVIDER_SUPPLIED_DOMAIN);
        absorb(&hasher, provider_id.slice());
        absorb(&hasher, supplied);
        var full: [32]u8 = undefined;
        hasher.final(&full);
        var out: OfferId = .{ .digest = undefined };
        @memcpy(&out.digest, full[0..16]);
        return out;
    }

    pub fn eql(self: OfferId, other: OfferId) bool {
        return std.mem.eql(u8, &self.digest, &other.digest);
    }

    /// Stable text form written into config documents and event payloads.
    pub fn render(self: OfferId) [OFFER_ID_TEXT_LEN]u8 {
        var out: [OFFER_ID_TEXT_LEN]u8 = undefined;
        @memcpy(out[0.."offer-".len], "offer-");
        _ = std.fmt.bufPrint(
            out["offer-".len..],
            "{x}",
            .{&self.digest},
        ) catch unreachable;
        return out;
    }

    pub fn parse(text: []const u8) error{InvalidOfferId}!OfferId {
        if (text.len != OFFER_ID_TEXT_LEN) return error.InvalidOfferId;
        if (!std.mem.startsWith(u8, text, "offer-")) return error.InvalidOfferId;
        var out: OfferId = .{ .digest = undefined };
        const hex = text["offer-".len..];
        var index: usize = 0;
        while (index < out.digest.len) : (index += 1) {
            const high = hexDigit(hex[index * 2]) orelse return error.InvalidOfferId;
            const low = hexDigit(hex[index * 2 + 1]) orelse return error.InvalidOfferId;
            out.digest[index] = (high << 4) | low;
        }
        return out;
    }
};

fn hexDigit(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        else => null,
    };
}

fn absorb(hasher: *std.crypto.hash.sha2.Sha256, field: []const u8) void {
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(field.len), .little);
    hasher.update(&header);
    hasher.update(field);
}

// ── tests ────────────────────────────────────────────────────────────────────

test "Slug rejects delimiters, case variants, and overlong ids" {
    try std.testing.expectError(error.InvalidSlug, Slug.parse(""));
    try std.testing.expectError(error.InvalidSlug, Slug.parse("zai/coding"));
    try std.testing.expectError(error.InvalidSlug, Slug.parse("ZAI"));
    try std.testing.expectError(error.InvalidSlug, Slug.parse("-leading"));
    try std.testing.expectError(error.InvalidSlug, Slug.parse("with space"));
    try std.testing.expectError(error.InvalidSlug, Slug.parse("a" ** (MAX_SLUG_LEN + 1)));
    const ok = try Slug.parse("zai-coding-plan");
    try std.testing.expectEqualStrings("zai-coding-plan", ok.slice());
}

test "Slug value semantics survive owner reallocation" {
    const a = std.testing.allocator;
    var owners: std.ArrayList([]u8) = .empty;
    defer {
        for (owners.items) |item| a.free(item);
        owners.deinit(a);
    }
    const first = try a.dupe(u8, "metask");
    try owners.append(a, first);
    const id = try Slug.parse(owners.items[0]);
    // Force the owning list to reallocate; a slice-based id would dangle here.
    var index: usize = 0;
    while (index < 64) : (index += 1) {
        try owners.append(a, try a.dupe(u8, "filler"));
    }
    try std.testing.expectEqualStrings("metask", id.slice());
}

test "OfferId is deterministic and route-sensitive" {
    const base = OfferId.Binding{
        .provider_id = Slug.lit("zai-coding-plan"),
        .channel_id = Slug.lit("cn-anthropic"),
        .protocol = "anthropic_messages",
        .endpoint_url = "https://open.bigmodel.cn/api/anthropic/v1/messages",
        .request_model_id = "glm-4.6",
    };
    const first = OfferId.derive(base);
    try std.testing.expect(first.eql(OfferId.derive(base)));

    var other = base;
    other.channel_id = Slug.lit("global-anthropic");
    try std.testing.expect(!first.eql(OfferId.derive(other)));

    other = base;
    other.request_model_id = "glm-4.5";
    try std.testing.expect(!first.eql(OfferId.derive(other)));

    other = base;
    other.credential_ref = "cred-zai-work";
    try std.testing.expect(!first.eql(OfferId.derive(other)));
}

test "OfferId length prefixing prevents field-boundary collisions" {
    const left = OfferId.derive(.{
        .provider_id = Slug.lit("relay"),
        .channel_id = Slug.lit("a-b"),
        .protocol = "openai_chat",
        .endpoint_url = "https://example.test/v1/chat/completions",
        .request_model_id = "m",
    });
    const right = OfferId.derive(.{
        .provider_id = Slug.lit("relay"),
        .channel_id = Slug.lit("a"),
        .protocol = "b.openai_chat",
        .endpoint_url = "https://example.test/v1/chat/completions",
        .request_model_id = "m",
    });
    try std.testing.expect(!left.eql(right));
}

test "OfferId text form round-trips and carries no secret" {
    const id = OfferId.derive(.{
        .provider_id = Slug.lit("metask"),
        .channel_id = Slug.lit("default"),
        .protocol = "anthropic_messages",
        .endpoint_url = "https://napi.metask-ai.com/v1/messages",
        .request_model_id = "claude-sonnet-4-6",
        .credential_ref = "cred-metask-oauth",
    });
    const text = id.render();
    try std.testing.expect(std.mem.startsWith(u8, &text, "offer-"));
    const parsed = try OfferId.parse(&text);
    try std.testing.expect(id.eql(parsed));
    try std.testing.expectError(error.InvalidOfferId, OfferId.parse("offer-nothex"));
}

test "provider-supplied offer ids live in a separate namespace" {
    const supplied = OfferId.fromProviderSupplied(Slug.lit("relay-a"), "channel-1:relay-glm-pro");
    const derived = OfferId.derive(.{
        .provider_id = Slug.lit("relay-a"),
        .channel_id = Slug.lit("channel-1"),
        .protocol = "openai_chat",
        .endpoint_url = "https://relay.test/v1/chat/completions",
        .request_model_id = "relay-glm-pro",
    });
    try std.testing.expect(!supplied.eql(derived));
}

test "revision counters are monotonic and type-separated" {
    const catalog = CatalogRevision.initial.next().next();
    try std.testing.expectEqual(@as(u64, 3), catalog.value());
    const config = ConfigRevision.initial.next();
    try std.testing.expectEqual(@as(u64, 2), config.value());
    try std.testing.expect(@TypeOf(catalog) != @TypeOf(config));
}
