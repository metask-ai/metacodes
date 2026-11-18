//! User opt-in for preview features. Only configuration may inherit a value;
//! execution receives a resolved boolean and defaults to disabled.
pub const Setting = enum {
    inherit,
    disabled,
    enabled,

    pub fn resolve(self: Setting, persisted: ?bool) Setting {
        return if (self != .inherit) self else if (persisted orelse false) .enabled else .disabled;
    }

    pub fn isEnabled(self: Setting) bool {
        return self == .enabled;
    }
};
