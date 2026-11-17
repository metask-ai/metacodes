//! Typed submissions (#447): what a Host can say about a submission besides
//! its text, and the rules that keep each part well formed.
//!
//! - `source`: where it came from (`im:lark`, `device:hr-01`).
//! - `kind`: what it is (`message`, `telemetry`), a name a frontend can
//!   switch on.
//! - `idempotency_key`: the delivery's identity. A Session runs one Run per
//!   key however often the key is delivered (core/idempotency_ledger.zig);
//!   `digest` tells a retry, which repeats the submission, from a different
//!   submission that reuses the key.
//! - `attributes`: structured name/value pairs.
//!
//! Provider-visible bytes are a cache contract (AGENTS.md): none of these
//! reaches a provider unless the Session's submission template renders it
//! (`checkTemplate`, `render`). Without a template a Run's user message is
//! the submitted text, byte for byte.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const max_source_bytes: usize = 128;
pub const max_kind_bytes: usize = 64;
pub const max_idempotency_key_bytes: usize = 256;
pub const max_attributes: usize = 32;
pub const max_attribute_name_bytes: usize = 64;
pub const max_attribute_value_bytes: usize = 4096;
pub const max_template_bytes: usize = 64 * 1024;

/// One structured attribute. Names are unique within a submission.
pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

/// A submission's typed fields, borrowed.
pub const Fields = struct {
    text: []const u8,
    source: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    idempotency_key: ?[]const u8 = null,
    attributes: []const Attribute = &.{},
    /// The 1-based position of the user message the text replaces
    /// (edit-and-rerun), if any.
    replaces: ?usize = null,
};

pub const Invalid = error{
    /// Empty, over `max_source_bytes`, not UTF-8, or holding a control
    /// character.
    InvalidSource,
    /// Not `[a-z0-9][a-z0-9_.-]*` of at most `max_kind_bytes`.
    InvalidKind,
    /// Empty, over `max_idempotency_key_bytes`, or holding a byte outside
    /// printable ASCII (`!` to `~`).
    InvalidIdempotencyKey,
    /// More than `max_attributes`; a name that is not
    /// `[A-Za-z0-9_.:-]` of 1 to `max_attribute_name_bytes` bytes, or that
    /// repeats; or a value over `max_attribute_value_bytes` or not UTF-8.
    InvalidAttributes,
};

/// The first rule `fields` breaks, by field: source, kind, key, attributes.
pub fn validate(fields: Fields) Invalid!void {
    if (fields.source) |source| {
        if (!validSource(source)) return error.InvalidSource;
    }
    if (fields.kind) |kind| {
        if (!validKind(kind)) return error.InvalidKind;
    }
    if (fields.idempotency_key) |key| {
        if (!validKey(key)) return error.InvalidIdempotencyKey;
    }
    if (fields.attributes.len > max_attributes) return error.InvalidAttributes;
    for (fields.attributes, 0..) |attribute, index| {
        if (!validAttributeName(attribute.name)) return error.InvalidAttributes;
        if (attribute.value.len > max_attribute_value_bytes or !std.unicode.utf8ValidateSlice(attribute.value))
            return error.InvalidAttributes;
        for (fields.attributes[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, attribute.name)) return error.InvalidAttributes;
        }
    }
}

fn validSource(source: []const u8) bool {
    if (source.len == 0 or source.len > max_source_bytes) return false;
    if (!std.unicode.utf8ValidateSlice(source)) return false;
    for (source) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn validKind(kind: []const u8) bool {
    if (kind.len == 0 or kind.len > max_kind_bytes) return false;
    if (!std.ascii.isLower(kind[0]) and !std.ascii.isDigit(kind[0])) return false;
    for (kind) |byte| {
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '_' and byte != '.' and byte != '-')
            return false;
    }
    return true;
}

fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_idempotency_key_bytes) return false;
    for (key) |byte| {
        if (byte < '!' or byte > '~') return false;
    }
    return true;
}

fn validAttributeName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_attribute_name_bytes) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '.' and byte != ':' and byte != '-')
            return false;
    }
    return true;
}

pub const Digest = [Sha256.digest_length]u8;

/// SHA-256 over what a retry repeats: the text, source, kind, the
/// attributes in name order, and `replaces`. The key is what is looked up,
/// and a `trace_id` is not covered: each delivery may trace itself.
/// `fields` must be valid (`validate`).
pub fn digest(fields: Fields) Digest {
    std.debug.assert(fields.attributes.len <= max_attributes);
    var hash = Sha256.init(.{});
    hash.update("metacodes.submission.v1");
    updateBytes(&hash, fields.text);
    updateOptional(&hash, fields.source);
    updateOptional(&hash, fields.kind);
    var order_buf: [max_attributes]u8 = undefined;
    const order = order_buf[0..fields.attributes.len];
    for (order, 0..) |*slot, index| slot.* = @intCast(index);
    std.mem.sort(u8, order, fields.attributes, nameLessThan);
    updateCount(&hash, order.len);
    for (order) |index| {
        updateBytes(&hash, fields.attributes[index].name);
        updateBytes(&hash, fields.attributes[index].value);
    }
    if (fields.replaces) |position| {
        hash.update(&[_]u8{1});
        updateCount(&hash, position);
    } else hash.update(&[_]u8{0});
    var out: Digest = undefined;
    hash.final(&out);
    return out;
}

fn nameLessThan(attributes: []const Attribute, a: u8, b: u8) bool {
    return std.mem.lessThan(u8, attributes[a].name, attributes[b].name);
}

fn updateCount(hash: *Sha256, value: usize) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    hash.update(&buf);
}

fn updateBytes(hash: *Sha256, bytes: []const u8) void {
    updateCount(hash, bytes.len);
    hash.update(bytes);
}

fn updateOptional(hash: *Sha256, value: ?[]const u8) void {
    if (value) |bytes| {
        hash.update(&[_]u8{1});
        updateBytes(hash, bytes);
    } else hash.update(&[_]u8{0});
}

/// A deep copy of `attributes` owned by `allocator` (an arena: nothing is
/// freed on error).
pub fn dupeAttributes(allocator: std.mem.Allocator, attributes: []const Attribute) error{OutOfMemory}![]const Attribute {
    const copy = try allocator.alloc(Attribute, attributes.len);
    for (attributes, copy) |attribute, *slot| slot.* = .{
        .name = try allocator.dupe(u8, attribute.name),
        .value = try allocator.dupe(u8, attribute.value),
    };
    return copy;
}

/// The attributes as one JSON object, in submission order: what
/// `{{attributes}}` renders and what `user_message` echoes.
pub fn writeAttributes(json: *std.json.Stringify, attributes: []const Attribute) std.json.Stringify.Error!void {
    try json.beginObject();
    for (attributes) |attribute| {
        try json.objectField(attribute.name);
        try json.write(attribute.value);
    }
    try json.endObject();
}

// ── Submission templates ─────────────────────────────────────────────────

/// What a submission template may name, as `{{text}}`, `{{source}}`,
/// `{{kind}}` and `{{attributes}}`.
pub const Variable = enum { text, source, kind, attributes };

pub const TemplateError = error{
    /// Over `max_template_bytes`, not UTF-8, or holding a `{{` that does not
    /// open one of the four variables (`{{name}}`, nothing else inside).
    InvalidSubmissionTemplate,
};

/// Refuses a template `render` could not render.
pub fn checkTemplate(template: []const u8) TemplateError!void {
    if (template.len > max_template_bytes or !std.unicode.utf8ValidateSlice(template))
        return error.InvalidSubmissionTemplate;
    var cursor: usize = 0;
    while (try nextVariable(template, cursor)) |found| cursor = found.end;
}

const Found = struct { start: usize, end: usize, variable: Variable };

/// The next variable at or after `cursor`. A `}}` outside a variable is
/// plain text.
fn nextVariable(template: []const u8, cursor: usize) TemplateError!?Found {
    const open = std.mem.indexOfPos(u8, template, cursor, "{{") orelse return null;
    const close = std.mem.indexOfPos(u8, template, open + 2, "}}") orelse return error.InvalidSubmissionTemplate;
    const variable = std.meta.stringToEnum(Variable, template[open + 2 .. close]) orelse
        return error.InvalidSubmissionTemplate;
    return .{ .start = open, .end = close + 2, .variable = variable };
}

/// `template` with each variable replaced, caller-owned: `{{text}}` by the
/// text, `{{source}}` and `{{kind}}` by theirs (empty when absent),
/// `{{attributes}}` by `writeAttributes`' object (`{}` when there are none).
pub fn render(allocator: std.mem.Allocator, template: []const u8, fields: Fields) (TemplateError || error{OutOfMemory})![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var cursor: usize = 0;
    while (try nextVariable(template, cursor)) |found| {
        out.writer.writeAll(template[cursor..found.start]) catch return error.OutOfMemory;
        switch (found.variable) {
            .text => out.writer.writeAll(fields.text) catch return error.OutOfMemory,
            .source => out.writer.writeAll(fields.source orelse "") catch return error.OutOfMemory,
            .kind => out.writer.writeAll(fields.kind orelse "") catch return error.OutOfMemory,
            .attributes => {
                var json: std.json.Stringify = .{ .writer = &out.writer };
                writeAttributes(&json, fields.attributes) catch return error.OutOfMemory;
            },
        }
        cursor = found.end;
    }
    out.writer.writeAll(template[cursor..]) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "validate: each field's rule, in field order" {
    try validate(.{ .text = "hi" });
    try validate(.{
        .text = "",
        .source = "im:lark/chat 7",
        .kind = "telemetry.v2",
        .idempotency_key = "im:evt-0001",
        .attributes = &.{ .{ .name = "device", .value = "hr-01" }, .{ .name = "chat_id", .value = "C1\n" } },
    });
    try testing.expectError(error.InvalidSource, validate(.{ .text = "", .source = "" }));
    try testing.expectError(error.InvalidSource, validate(.{ .text = "", .source = "a\tb" }));
    try testing.expectError(error.InvalidSource, validate(.{ .text = "", .source = "\xff" }));
    try testing.expectError(error.InvalidSource, validate(.{ .text = "", .source = "x" ** (max_source_bytes + 1) }));
    try testing.expectError(error.InvalidKind, validate(.{ .text = "", .kind = "Message" }));
    try testing.expectError(error.InvalidKind, validate(.{ .text = "", .kind = "-x" }));
    try testing.expectError(error.InvalidKind, validate(.{ .text = "", .kind = "" }));
    try testing.expectError(error.InvalidIdempotencyKey, validate(.{ .text = "", .idempotency_key = "" }));
    try testing.expectError(error.InvalidIdempotencyKey, validate(.{ .text = "", .idempotency_key = "a b" }));
    try testing.expectError(error.InvalidIdempotencyKey, validate(.{ .text = "", .idempotency_key = "é" }));
    try testing.expectError(error.InvalidIdempotencyKey, validate(.{ .text = "", .idempotency_key = "k" ** (max_idempotency_key_bytes + 1) }));
    try testing.expectError(error.InvalidAttributes, validate(.{ .text = "", .attributes = &.{.{ .name = "", .value = "v" }} }));
    try testing.expectError(error.InvalidAttributes, validate(.{ .text = "", .attributes = &.{.{ .name = "a b", .value = "v" }} }));
    try testing.expectError(error.InvalidAttributes, validate(.{ .text = "", .attributes = &.{.{ .name = "a", .value = "\xc3" }} }));
    try testing.expectError(error.InvalidAttributes, validate(.{ .text = "", .attributes = &.{ .{ .name = "a", .value = "1" }, .{ .name = "a", .value = "2" } } }));
    const many = [_]Attribute{.{ .name = "a", .value = "" }} ** (max_attributes + 1);
    try testing.expectError(error.InvalidAttributes, validate(.{ .text = "", .attributes = &many }));
    // The first broken rule wins.
    try testing.expectError(error.InvalidSource, validate(.{ .text = "", .source = "", .kind = "" }));
}

test "digest: a retry matches whatever its trace and attribute order; any other change does not" {
    const base = Fields{
        .text = "fix the build",
        .source = "im:lark",
        .kind = "message",
        .idempotency_key = "im:evt-0001",
        .attributes = &.{ .{ .name = "chat", .value = "C1" }, .{ .name = "sender", .value = "alice" } },
    };
    const same = digest(base);
    var reordered = base;
    reordered.attributes = &.{ .{ .name = "sender", .value = "alice" }, .{ .name = "chat", .value = "C1" } };
    try testing.expectEqualSlices(u8, &same, &digest(reordered));
    var other_key = base;
    other_key.idempotency_key = "im:evt-0002";
    try testing.expectEqualSlices(u8, &same, &digest(other_key));

    var changed = [_]Fields{ base, base, base, base, base, base, base };
    changed[0].text = "fix the build!";
    changed[1].source = null;
    changed[2].kind = "alert";
    changed[3].attributes = &.{.{ .name = "chat", .value = "C1" }};
    changed[4].attributes = &.{ .{ .name = "chat", .value = "C2" }, .{ .name = "sender", .value = "alice" } };
    changed[5].replaces = 3;
    // Length-prefixed fields: moving bytes across a boundary is a change.
    changed[6].attributes = &.{ .{ .name = "chat", .value = "C1s" }, .{ .name = "ender", .value = "alice" } };
    for (changed) |fields| {
        try testing.expect(!std.mem.eql(u8, &same, &digest(fields)));
    }
    // Absent and empty differ.
    try testing.expect(!std.mem.eql(u8, &digest(.{ .text = "t" }), &digest(.{ .text = "t", .source = "" })));
}

test "checkTemplate and render: four variables, absent values empty, attributes as one JSON object" {
    const fields = Fields{
        .text = "rate high",
        .source = "device:hr-01",
        .attributes = &.{ .{ .name = "bpm", .value = "132" }, .{ .name = "note", .value = "say \"hi\"" } },
    };
    const template = "[{{source}}|{{kind}}] {{text}} }} {{attributes}}";
    try checkTemplate(template);
    const out = try render(testing.allocator, template, fields);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[device:hr-01|] rate high }} {\"bpm\":\"132\",\"note\":\"say \\\"hi\\\"\"}", out);

    const bare = try render(testing.allocator, "{{attributes}}{{text}}", .{ .text = "t" });
    defer testing.allocator.free(bare);
    try testing.expectEqualStrings("{}t", bare);

    for ([_][]const u8{ "{{", "{{ text }}", "{{Text}}", "{{trace_id}}", "{{idempotency_key}}", "a {{text", "{{{text}}}", "\xff" }) |bad| {
        try testing.expectError(error.InvalidSubmissionTemplate, checkTemplate(bad));
    }
    const huge = try testing.allocator.alloc(u8, max_template_bytes + 1);
    defer testing.allocator.free(huge);
    @memset(huge, 'x');
    try testing.expectError(error.InvalidSubmissionTemplate, checkTemplate(huge));
}
