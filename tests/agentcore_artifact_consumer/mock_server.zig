const std = @import("std");

pub const Server = struct {
    listen_fd: std.c.fd_t,
    port: u16,
    bodies: []const []const u8,
    thread: std.Thread,

    pub fn start(bodies: []const []const u8) !*Server {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = std.c.close(fd);
        const yes: c_int = 1;
        _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &yes, @sizeOf(c_int));
        var addr = std.c.sockaddr.in{
            .family = std.c.AF.INET,
            .port = 0,
            .addr = 0x0100007f,
            .zero = [_]u8{0} ** 8,
        };
        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) return error.BindFailed;
        if (std.c.listen(fd, 4) < 0) return error.ListenFailed;
        var bound: std.c.sockaddr.in = undefined;
        var len: std.c.socklen_t = @sizeOf(@TypeOf(bound));
        if (std.c.getsockname(fd, @ptrCast(&bound), &len) < 0) return error.GetSocknameFailed;
        const self = try std.heap.page_allocator.create(Server);
        self.* = .{
            .listen_fd = fd,
            .port = std.mem.bigToNative(u16, bound.port),
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
        _ = std.c.close(self.listen_fd);
        self.thread.join();
        std.heap.page_allocator.destroy(self);
    }

    fn serve(self: *Server) void {
        for (self.bodies) |body| {
            var client_addr: std.c.sockaddr = undefined;
            var addr_len: std.c.socklen_t = @sizeOf(@TypeOf(client_addr));
            const connection = std.c.accept(self.listen_fd, &client_addr, &addr_len);
            if (connection < 0) return;
            readRequest(connection);
            writeResponse(connection, body);
            _ = std.c.close(connection);
        }
    }
};

fn readRequest(connection: std.c.fd_t) void {
    var request: [64 * 1024]u8 = undefined;
    var total: usize = 0;
    var header_end: ?usize = null;
    var content_length: usize = 0;
    while (total < request.len and header_end == null) {
        const count = std.c.read(connection, request[total..].ptr, request.len - total);
        if (count <= 0) return;
        total += @intCast(count);
        if (std.mem.indexOf(u8, request[0..total], "\r\n\r\n")) |index| {
            header_end = index + 4;
            content_length = parseContentLength(request[0..index]);
        }
    }
    if (header_end) |end| while (total - end < content_length and total < request.len) {
        const count = std.c.read(connection, request[total..].ptr, request.len - total);
        if (count <= 0) return;
        total += @intCast(count);
    };
}

fn writeResponse(connection: std.c.fd_t, body: []const u8) void {
    writeAll(connection, "HTTP/1.1 200 OK\r\n" ++
        "content-type: text/event-stream\r\n" ++
        "transfer-encoding: chunked\r\n" ++
        "connection: close\r\n\r\n");
    var chunk_header: [32]u8 = undefined;
    const encoded = std.fmt.bufPrint(&chunk_header, "{x}\r\n", .{body.len}) catch return;
    writeAll(connection, encoded);
    writeAll(connection, body);
    writeAll(connection, "\r\n0\r\n\r\n");
}

fn parseContentLength(headers: []const u8) usize {
    const marker = "content-length:";
    var lower: [4096]u8 = undefined;
    const length = @min(headers.len, lower.len);
    for (headers[0..length], 0..) |byte, index| lower[index] = std.ascii.toLower(byte);
    const start = std.mem.indexOf(u8, lower[0..length], marker) orelse return 0;
    var cursor = start + marker.len;
    while (cursor < length and (lower[cursor] == ' ' or lower[cursor] == '\t')) : (cursor += 1) {}
    var end = cursor;
    while (end < length and std.ascii.isDigit(lower[end])) : (end += 1) {}
    return std.fmt.parseInt(usize, lower[cursor..end], 10) catch 0;
}

fn writeAll(fd: std.c.fd_t, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (count <= 0) return;
        offset += @intCast(count);
    }
}
