const std = @import("std");

const net = std.Io.net;

pub const Server = struct {
    io: std.Io,
    listener: net.Server,
    port: u16,
    bodies: []const []const u8,
    thread: std.Thread,

    pub fn start(io: std.Io, bodies: []const []const u8) !*Server {
        const address = net.IpAddress{ .ip4 = .loopback(0) };
        var listener = try address.listen(io, .{ .reuse_address = true });
        errdefer listener.deinit(io);
        const self = try std.heap.page_allocator.create(Server);
        errdefer std.heap.page_allocator.destroy(self);
        self.* = .{
            .io = io,
            .port = listener.socket.address.getPort(),
            .listener = listener,
            .bodies = bodies,
            .thread = undefined,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    pub fn url(self: *const Server, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1/messages", .{self.port});
    }

    pub fn stop(self: *Server) void {
        self.listener.deinit(self.io);
        self.thread.join();
        std.heap.page_allocator.destroy(self);
    }

    fn serve(self: *Server) void {
        for (self.bodies) |body| {
            var stream = self.listener.accept(self.io) catch return;
            serveResponse(self.io, stream, body);
            stream.close(self.io);
        }
    }
};

fn serveResponse(io: std.Io, stream: net.Stream, body: []const u8) void {
    var recv_buffer: [4096]u8 = undefined;
    var send_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &recv_buffer);
    var writer = stream.writer(io, &send_buffer);
    var server: std.http.Server = .init(&reader.interface, &writer.interface);
    var request = server.receiveHead() catch return;
    request.respond(body, .{
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
    }) catch return;
}
