const std = @import("std");
const net = std.net;
const configure = @import("configure.zig");
const protocol = @import("protocol.zig");
const log = @import("log.zig");

const Config = configure.Config;
const Message = protocol.Message;
const ClientErrors = protocol.ClientErrors;

/// Created per client.
/// File/stream agnostic.
/// Works on anything that implements reader() & writer().
const ServerHandler = struct {
    const Self = @This();

    isExiting: bool,
    config: *const Config,

    fn init(config: *const Config) Self {
        return .{
            .isExiting = false,
            .config = config,
        };
    }

    fn handleMessage(self: *Self, mes: Message, stream: anytype) !Message {
        _ = stream;
        switch (mes.header) {
            .Ping => |pl| {
                var num = std.mem.littleToNative(@TypeOf(pl.num), pl.num);
                num *= 2;
                return Message{
                    .header = .{
                        .PingReply = .{
                            .num = num,
                        },
                    },
                };
            },
            .Quit => {
                self.isExiting = true;
                return Message{
                    .header = .{
                        .QuitReply = .{},
                    },
                };
            },
            else => {
                return Message{
                    .header = .{
                        .Error = .{
                            .code = @intFromEnum(ClientErrors.InvalidMessageType),
                            .arg1 = @intFromEnum(mes.header),
                            .arg2 = 0,
                        },
                    },
                };
            },
        }
    }

    fn handleClient(self: *Self, stream: anytype) !void {
        var stream_mut = stream;
        while (!self.isExiting) {
            const mes = try protocol.readMessage(stream_mut.reader());
            const resp = try self.handleMessage(mes, stream_mut);
            try protocol.writeMessage(resp, stream_mut.writer());
        }
    }
};

pub const Server = struct {
    const Self = @This();

    config: Config,

    pub fn init(config: Config) Self {
        return .{ .config = config };
    }

    pub fn runServer(self: *Self) !void {
        const addr = net.Address.resolveIp(self.config.address, self.config.port) catch log.showError(
            "Invalid bind IP address",
            .{},
        );
        var stream_server = net.StreamServer.init(.{});
        stream_server.listen(addr) catch log.showError(
            "Could not listen on {s}:{d}",
            .{
                self.config.address,
                self.config.port,
            },
        );
        log.showLog(
            "Server listening on {s}:{d}",
            .{
                self.config.address,
                self.config.port,
            },
        );
        while (stream_server.accept()) |client| {
            var handler = ServerHandler.init(&self.config);
            try handler.handleClient(client.stream);
        } else |_| {
            log.showError("Connection failure", .{});
        }
    }
};

const Channel = struct {
    const Self = @This();
    const Reader = std.io.Reader(*Self, std.os.ReadError, read);
    const Writer = std.io.Writer(*Self, std.os.WriteError, write);

    pipe: [2]std.os.fd_t,

    pub fn init() ![2]Self {
        const p1 = try std.os.pipe();
        const p2 = try std.os.pipe();

        return .{ .{
            .pipe = .{ p2[0], p1[1] },
        }, .{
            .pipe = .{ p1[0], p2[1] },
        } };
    }
    pub fn deinit(self: *Self) void {
        std.os.close(self.pipe[0]);
        std.os.close(self.pipe[1]);
    }
    pub fn read(self: *Self, buf: []u8) std.os.ReadError!usize {
        return std.os.read(self.pipe[0], buf);
    }
    pub fn write(self: *Self, buf: []const u8) std.os.WriteError!usize {
        return std.os.write(self.pipe[1], buf);
    }
    pub fn reader(self: *Self) Reader {
        return .{ .context = self };
    }
    pub fn writer(self: *Self) Writer {
        return .{ .context = self };
    }
};

const ServerTester = struct {
    thread: std.Thread,
    channel: Channel,

    const Self = @This();

    fn runServer(config: Config, channel: Channel) void {
        var channel_mut = channel;
        var handler = ServerHandler.init(&config);
        handler.handleClient(channel_mut) catch {};
        channel_mut.deinit();
    }

    fn init(config: Config) !Self {
        const channels = try Channel.init();
        const thread = try std.Thread.spawn(.{}, runServer, .{ config, channels[0] });
        return .{
            .thread = thread,
            .channel = channels[1],
        };
    }
    fn deinit(self: *Self) void {
        self.channel.deinit();
    }
    fn send(self: *Self, mes: Message) !void {
        try protocol.writeMessage(mes, self.channel.writer());
    }
    fn recv(self: *Self) !Message {
        return try protocol.readMessage(self.channel.reader());
    }
    fn quit(self: *Self) !void {
        try self.send(.{ .header = .{ .Quit = .{} } });
        switch ((try self.recv()).header) {
            .QuitReply => return,
            else => unreachable,
        }
        self.thread.join();
    }
};

test "ping" {
    const num: u32 = 4;
    var server = try ServerTester.init(Config.init());
    defer server.deinit();
    try server.send(.{
        .header = .{
            .Ping = .{
                .num = num,
            },
        },
    });
    const mesg = try server.recv();
    switch (mesg.header) {
        .PingReply => |hdr| try std.testing.expectEqual(num * 2, hdr.num),
        else => try std.testing.expectEqual(@intFromEnum(mesg.header), 3),
    }
    try server.quit();
}
