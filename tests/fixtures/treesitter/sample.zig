const std = @import("std");

pub const Point = struct {
    x: i32,
    y: i32,

    pub fn add(self: Point, other: Point) Point {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }
};

pub const Color = enum { red, green, blue };

pub fn distance(a: Point, b: Point) f64 {
    const dx: f64 = @floatFromInt(a.x - b.x);
    const dy: f64 = @floatFromInt(a.y - b.y);
    return @sqrt(dx * dx + dy * dy);
}
