const std = @import("std");

/// Process-owned view of an HTTP response status.
///
/// `std.http.Status` models a protocol value with an open wire domain as a
/// non-exhaustive enum. It must not escape this boundary: unnamed values are
/// valid HTTP responses, but operations such as `@tagName` can panic on them.
pub const ResponseStatus = struct {
    code: u16,
    name: []const u8,

    /// The only production conversion from std's wire-facing response type.
    pub fn capture(response: *const std.http.Client.Response) ResponseStatus {
        return fromStd(response.head.status);
    }

    pub fn isOk(self: ResponseStatus) bool {
        return self.code == 200;
    }

    fn fromStd(status: std.http.Status) ResponseStatus {
        return .{
            .code = @intFromEnum(status),
            .name = std.enums.tagName(std.http.Status, status) orelse "unknown",
        };
    }
};

test "ResponseStatus captures named and unnamed wire values without panic" {
    const ok = ResponseStatus.fromStd(.ok);
    try std.testing.expectEqual(@as(u16, 200), ok.code);
    try std.testing.expectEqualStrings("ok", ok.name);
    try std.testing.expect(ok.isOk());

    const unauthorized = ResponseStatus.fromStd(.unauthorized);
    try std.testing.expectEqual(@as(u16, 401), unauthorized.code);
    try std.testing.expectEqualStrings("unauthorized", unauthorized.name);
    try std.testing.expect(!unauthorized.isOk());

    const unnamed = ResponseStatus.fromStd(@enumFromInt(529));
    try std.testing.expectEqual(@as(u16, 529), unnamed.code);
    try std.testing.expectEqualStrings("unknown", unnamed.name);
    try std.testing.expect(!unnamed.isOk());
}

test "ResponseStatus conversion is total across the HTTP response range" {
    var code: u16 = 100;
    while (code <= 599) : (code += 1) {
        const status = ResponseStatus.fromStd(@enumFromInt(code));
        try std.testing.expectEqual(code, status.code);
        try std.testing.expect(status.name.len > 0);
    }
}
