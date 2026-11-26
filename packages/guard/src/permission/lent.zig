//! The permission state one Session lends to the decisions of other Sessions
//! (#445): a swarm member opened under its lead's permissions
//! (`AgentSession.inheritPermissions`) decides every tool call with the
//! lead's imported rules and additional working directories as they are at
//! that call, not as they were when the member opened, as the bundled
//! daemon's in-process teammates read their lead's rules through borrowed
//! pointers.
//!
//! Locking rule. The owner (the lead) writes `settings` and
//! `additional_dirs` only while it holds `mutex`, and frees what it replaced
//! only after it has released `mutex`. A borrower (a member, on its own
//! driver thread) reads both only while it holds `mutex`, for one whole
//! permission decision (`permission.checkPermissionClassified`,
//! `PermissionContext.modeAllowed`, `effectiveMode`), so a set it read
//! cannot be freed under it and a decision never mixes two sets. A decision
//! made under `mutex` waits for nothing that could take it: no prompt (a
//! decision only says `.ask`; the prompt comes after `mutex` is released)
//! and no other lender's lock. Lock order: the owner's own Session lock,
//! then `mutex`, then a `SessionRules.mutex`; nothing takes them the other
//! way round. Lifetime is the owner's (`AgentSession`): it outlives every
//! borrower, which `AgentSession.destroy` enforces.

const std = @import("std");
const sync = @import("platform").sync;
const settings_mod = @import("settings.zig");

pub const LentPermissions = struct {
    mutex: sync.Mutex = .{},
    /// A borrowed view of the owner's immutable rule allocations. Keep the
    /// header here: the owner's optional header can be replaced before publish
    /// acquires our lock. The owner alone frees the allocations after publish.
    settings: ?settings_mod.MergedSettings = null,
    /// The owner's additional working directories (resolved real paths).
    additional_dirs: []const []const u8 = &.{},

    /// Replaces what is lent; the caller frees what it replaced afterwards.
    pub fn publish(self: *LentPermissions, settings: ?*const settings_mod.MergedSettings, additional_dirs: []const []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.settings = if (settings) |merged| merged.* else null;
        self.additional_dirs = additional_dirs;
    }

    /// Only while holding mutex; the view never owns the rule allocations.
    pub fn borrowedSettings(self: *const LentPermissions) ?*const settings_mod.MergedSettings {
        return if (self.settings) |*merged| merged else null;
    }
};

test "LentPermissions.publish replaces both under the lock" {
    var lent: LentPermissions = .{};
    var merged: settings_mod.MergedSettings = .{ .layers = &.{}, .allocator = std.testing.allocator };
    const dirs = [_][]const u8{"/extra"};
    lent.publish(&merged, &dirs);
    try std.testing.expect(lent.borrowedSettings().?.layers.ptr == merged.layers.ptr);
    try std.testing.expectEqualStrings("/extra", lent.additional_dirs[0]);
    lent.publish(null, &.{});
    try std.testing.expect(lent.settings == null);
    try std.testing.expectEqual(@as(usize, 0), lent.additional_dirs.len);
}
