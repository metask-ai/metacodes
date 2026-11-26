//! Image-input capability with its provenance (issue #273).
//!
//! Whether a request may carry an image is decided before serialization, and
//! "no" has two different meanings that a Host must be able to tell apart:
//! the model is known not to accept images, or nothing on hand says either
//! way. Both refuse locally (an unknown route can drop an image without an
//! error, so the request is never sent on a guess), but only the second is
//! fixed by a declaration rather than by choosing another model.
//!
//! Sources, strongest first:
//!   1. `host`         - the embedding Host declared it for this model;
//!   2. `catalog`      - the provider's `/v1/models` catalog declared it;
//!   3. `model_family` - the built-in family table knows this name;
//!   4. `unknown`      - none of the above: not supported, by default.
//! `Dialect.profileFor` is the one place a declaration is applied, so the
//! serializer's gate, `Provider.supports(.image_input)` and the AgentCore
//! preflight read the same answer.

const std = @import("std");
const model_name = @import("metacodes-base").api.model_name;

pub const Source = enum {
    unknown,
    model_family,
    catalog,
    host,

    pub fn name(self: Source) []const u8 {
        return @tagName(self);
    }
};

pub const Resolution = struct {
    supported: bool,
    source: Source,

    /// Refused because nothing said the model takes images, as opposed to
    /// a source saying it does not.
    pub fn isUnknown(self: Resolution) bool {
        return !self.supported and self.source == .unknown;
    }
};

/// One Host statement about one model, matched case-insensitively against
/// the model a request names.
pub const Declaration = struct {
    model: []const u8,
    image_input: bool,
};

/// An owned, immutable set of Host declarations. The empty value owns
/// nothing and needs no deinit; any value made by `init` or `clone` must be
/// released with `deinit`.
pub const Declarations = struct {
    allocator: ?std.mem.Allocator = null,
    items: []const Declaration = &.{},

    pub const Error = error{ DuplicateModel, EmptyModel } || std.mem.Allocator.Error;

    /// Copies `source`. Two entries naming the same model (ignoring case)
    /// are refused rather than resolved by order.
    pub fn init(allocator: std.mem.Allocator, source: []const Declaration) Error!Declarations {
        if (source.len == 0) return .{};
        for (source, 0..) |entry, i| {
            if (entry.model.len == 0) return error.EmptyModel;
            for (source[0..i]) |earlier| {
                if (model_name.eqlIgnoreCase(earlier.model, entry.model)) return error.DuplicateModel;
            }
        }
        const items = try allocator.alloc(Declaration, source.len);
        var copied: usize = 0;
        errdefer {
            for (items[0..copied]) |item| allocator.free(item.model);
            allocator.free(items);
        }
        for (source, items) |entry, *slot| {
            slot.* = .{ .model = try allocator.dupe(u8, entry.model), .image_input = entry.image_input };
            copied += 1;
        }
        return .{ .allocator = allocator, .items = items };
    }

    /// Copies an already validated set; only allocation can fail.
    pub fn clone(self: Declarations, allocator: std.mem.Allocator) std.mem.Allocator.Error!Declarations {
        if (self.items.len == 0) return .{};
        const items = try allocator.alloc(Declaration, self.items.len);
        var copied: usize = 0;
        errdefer {
            for (items[0..copied]) |item| allocator.free(item.model);
            allocator.free(items);
        }
        for (self.items, items) |entry, *slot| {
            slot.* = .{ .model = try allocator.dupe(u8, entry.model), .image_input = entry.image_input };
            copied += 1;
        }
        return .{ .allocator = allocator, .items = items };
    }

    pub fn deinit(self: *Declarations) void {
        const allocator = self.allocator orelse return;
        for (self.items) |item| allocator.free(item.model);
        allocator.free(self.items);
        self.* = .{};
    }

    /// The Host's statement about `model`, or null when it made none.
    pub fn imageInputFor(self: Declarations, model: []const u8) ?bool {
        for (self.items) |item| {
            if (model_name.eqlIgnoreCase(item.model, model)) return item.image_input;
        }
        return null;
    }
};

test "Declarations: copy, case-insensitive lookup, and refusal of ambiguous sets" {
    const a = std.testing.allocator;
    var model_buf = "Vendor-Vision-1".*;
    var decls = try Declarations.init(a, &.{
        .{ .model = &model_buf, .image_input = true },
        .{ .model = "text-only-2", .image_input = false },
    });
    defer decls.deinit();
    // The set owns its bytes: the caller's buffer may change afterwards.
    model_buf[0] = 'X';
    try std.testing.expectEqual(@as(?bool, true), decls.imageInputFor("vendor-vision-1"));
    try std.testing.expectEqual(@as(?bool, false), decls.imageInputFor("TEXT-ONLY-2"));
    try std.testing.expectEqual(@as(?bool, null), decls.imageInputFor("other"));

    var copy = try decls.clone(a);
    defer copy.deinit();
    try std.testing.expectEqual(@as(?bool, true), copy.imageInputFor("VENDOR-VISION-1"));

    try std.testing.expectError(error.DuplicateModel, Declarations.init(a, &.{
        .{ .model = "m", .image_input = true },
        .{ .model = "M", .image_input = false },
    }));
    try std.testing.expectError(error.EmptyModel, Declarations.init(a, &.{.{ .model = "", .image_input = true }}));

    var empty: Declarations = .{};
    empty.deinit();
    try std.testing.expectEqual(@as(?bool, null), empty.imageInputFor("m"));
}

test "Declarations.init frees partial copies when an allocation fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    try std.testing.expectError(error.OutOfMemory, Declarations.init(failing.allocator(), &.{
        .{ .model = "a", .image_input = true },
        .{ .model = "b", .image_input = true },
        .{ .model = "c", .image_input = true },
    }));
}
