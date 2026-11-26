//! Persistent, thread-confined QuickJS context. No operating-system bindings.
//! Only a pending Promise crosses into the host; host work runs between JS jobs.
const std = @import("std");
const c = @cImport({
    @cInclude("bridge.h");
});

pub const MAX_SOURCE_BYTES = 256 * 1024;
pub const Error = error{ OutOfMemory, HostToolFatal, Aborted, JavaScriptError, UnresolvedPromise, RuntimeInvalidated, SourceTooLarge };
pub const HostResult = struct { bytes: []const u8, is_error: bool };
pub const Host = struct {
    ctx: *anyopaque,
    callFn: *const fn (*anyopaque, []const u8, []const u8) error{ OutOfMemory, HostToolFatal, Aborted }!HostResult,
    interruptFn: *const fn (?*anyopaque) callconv(.c) c_int,
};
pub const Evaluation = union(enum) { ok: []u8, exception: []u8 };

pub const Runtime = struct {
    vm: *c.metacodes_js,
    healthy: bool = true,

    pub fn init() error{OutOfMemory}!Runtime {
        const bootstrap = @embedFile("bootstrap.js");
        return .{ .vm = c.metacodes_js_new(bootstrap.ptr, bootstrap.len) orelse return error.OutOfMemory };
    }

    pub fn deinit(self: *Runtime) void {
        c.metacodes_js_free(self.vm);
        self.* = undefined;
    }

    fn exception(self: *Runtime, gpa: std.mem.Allocator) error{OutOfMemory}!Evaluation {
        const bytes = std.mem.span(c.metacodes_js_error(self.vm));
        var end = @min(bytes.len, 8 * 1024);
        while (end > 0 and end < bytes.len and bytes[end] & 0xc0 == 0x80) end -= 1;
        return .{ .exception = try gpa.dupe(u8, bytes[0..end]) };
    }

    pub fn evaluate(self: *Runtime, gpa: std.mem.Allocator, source: []const u8, host: Host) Error!Evaluation {
        if (!self.healthy) return error.RuntimeInvalidated;
        if (source.len > MAX_SOURCE_BYTES) return error.SourceTooLarge;
        // QuickJS's parser requires a terminating zero beyond input_len.
        const code = try gpa.dupeZ(u8, source);
        defer gpa.free(code);
        self.healthy = false; // failures invalidate queued jobs and borrowed host capability
        defer c.metacodes_js_end(self.vm);
        if (c.metacodes_js_begin(self.vm, code.ptr, source.len, host.interruptFn, host.ctx) < 0)
            return self.exception(gpa);
        while (true) {
            if (host.interruptFn(host.ctx) != 0) return error.Aborted;
            switch (c.metacodes_js_poll(self.vm)) {
                0 => {
                    const bytes = try gpa.dupe(u8, std.mem.span(c.metacodes_js_result(self.vm)));
                    self.healthy = true;
                    return .{ .ok = bytes };
                },
                1 => {
                    const result = try host.callFn(host.ctx, std.mem.span(c.metacodes_js_name(self.vm)), std.mem.span(c.metacodes_js_args(self.vm)));
                    if (c.metacodes_js_complete(self.vm, result.bytes.ptr, result.bytes.len, @intFromBool(result.is_error)) < 0)
                        return self.exception(gpa);
                },
                -2 => return error.UnresolvedPromise,
                else => return self.exception(gpa),
            }
        }
    }
};
