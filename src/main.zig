const std = @import("std");
const net = std.net;

const Queue = std.atomic.Queue;
const ArenaAllocator = std.heap.ArenaAllocator;

// THIS _MUST_ be placed in your main.zig file
pub const io_mode = .evented;

pub fn main() anyerror!void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = general_purpose_allocator.allocator();

    var server = net.StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();

    // TODO handle concurrent accesses to this hash map
    var room = Room{ .clients = std.AutoHashMap(*Client, void).init(allocator) };

    try server.listen(net.Address.parseIp("127.0.0.1", 0) catch unreachable);
    std.log.info("listening at {}\n", .{server.listen_address});

    var cleanup = &Queue(*ArenaAllocator).init();
    _ = async cleaner(cleanup);

    while (true) {
        var client_arena = ArenaAllocator.init(allocator);
        const client = try client_arena.allocator().create(Client);
        client.* = Client{
            .stream = (try server.accept()).stream,
            .handle_frame = async client.handle(&room, cleanup, &client_arena),
        };
        try room.clients.putNoClobber(client, {});
    }
}

const Client = struct {
    stream: net.Stream,
    handle_frame: @Frame(handle),

    fn handle(self: *Client, room: *Room, cleanup: *Queue(*ArenaAllocator), arena: *ArenaAllocator) !void {
        const stream = self.stream;
        defer {
            stream.close();
            var node = Queue(*ArenaAllocator).Node{ .data = arena, .next = undefined, .prev = undefined };
            cleanup.put(&node);
        }

        _ = try stream.write("server: welcome to the chat server\n");
        while (true) {
            var buf: [100]u8 = undefined;
            const n = try stream.read(&buf);
            if (n == 0) {
                return;
            }
            room.broadcast(buf[0..n], self);
        }
    }
};


const Room = struct {
    clients: std.AutoHashMap(*Client, void),

    fn broadcast(room: *Room, msg: []const u8, sender: *Client) void {
        var it = room.clients.keyIterator();
        while (it.next()) |key_ptr| {
            const client = key_ptr.*;
            if (client == sender) continue;
            _ = client.stream.write(msg) catch |e| std.log.warn("unable to send: {}\n", .{e});
        }
    }
};

fn cleaner(cleanup: *Queue(*ArenaAllocator)) !void {
    while (true) {
        while (cleanup.get()) |node| {
            node.data.deinit(); // the client arena allocator
        }
        // 5 seconds (in nano seconds)
        std.time.sleep(5000000000);
    }
}
