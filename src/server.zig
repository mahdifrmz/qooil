const std = @import("std");
const net = std.net;
const configure = @import("configure.zig");
const protocol = @import("protocol.zig");
const log = @import("log.zig");

const Header = protocol.Header;
const Config = configure.Config;
const Message = protocol.Message;
const ClientError = protocol.ClientError;

/// Created per client.
/// File/stream agnostic.
/// Works on anything that implements reader() & writer().
fn ServerHandler(comptime T: type) type {
    return struct {
        const Self = @This();

        isExiting: bool,
        config: *const Config,
        cwd: std.fs.Dir,
        stream: *T,

        fn init(config: *const Config, stream: *T) Self {
            return .{
                .isExiting = false,
                .config = config,
                .cwd = std.fs.cwd(),
                .stream = stream,
            };
        }

        fn deinit(self: *Self) void {
            self.cwd.close();
        }

        fn sendError(self: *Self, err: ClientError, arg1: u32, arg2: u32) !void {
            return self.send(
                .{
                    .Error = .{
                        .code = @intFromEnum(err),
                        .arg1 = arg1,
                        .arg2 = arg2,
                    },
                },
            );
        }

        fn send(self: *Self, header: Header) !void {
            try protocol.writeMessage(.{
                .header = header,
            }, self.stream.writer());
        }

        fn recv(self: *Self) !Message {
            return protocol.readMessage(self.stream.reader());
        }

        fn handleMessage(self: *Self, mes: Message) !void {
            switch (mes.header) {
                .Ping => |pl| {
                    var num = std.mem.littleToNative(@TypeOf(pl.num), pl.num);
                    num *= 2;
                    return self.send(
                        .{
                            .PingReply = .{
                                .num = num,
                            },
                        },
                    );
                },
                .Quit => {
                    self.isExiting = true;
                    return self.send(
                        .{
                            .QuitReply = .{},
                        },
                    );
                },
                .Cd => |hdr| {
                    var buf = [_]u8{0} ** std.os.NAME_MAX;
                    if (hdr.length > std.os.NAME_MAX)
                        return self.sendError(ClientError.MaxPathLengthExceeded, hdr.lenght, 0);
                    const count: usize = try self.stream.reader().readAll(buf[0..hdr.length]);
                    if (count < hdr.length) {
                        return self.sendError(
                            ClientError.UnexpectedEndOfConnection,
                            0,
                            0,
                        );
                    }
                    const path = buf[0..count];
                    const newCwd = self.cwd.openDir(path, .{
                        .no_follow = true,
                    }) catch |err| {
                        const cerr = switch (err) {
                            error.FileNotFound => ClientError.NonExisting,
                            error.NotDir => ClientError.IsNotDir,
                            error.AccessDenied => ClientError.AccessDenied,
                            else => ClientError.CantOpen,
                        };
                        return self.sendError(cerr, 0, 0);
                    };
                    self.cwd.close();
                    self.cwd = newCwd;
                    return self.send(
                        .{
                            .Ok = .{},
                        },
                    );
                },
                .Pwd => |_| {
                    var buf = [_]u8{0} ** std.os.PATH_MAX;
                    const path = self.cwd.realpath(".", &buf) catch unreachable;
                    try self.send(
                        .{
                            .Pwd = .{},
                        },
                    );
                    self.stream.writer().writeAll(path) catch unreachable;
                },
                else => return self.sendError(
                    ClientError.InvalidMessageType,
                    @intFromEnum(mes.header),
                    0,
                ),
            }

            unreachable;
        }

        fn handleClient(self: *Self) !void {
            while (!self.isExiting) {
                const mes = try self.recv();
                try self.handleMessage(mes);
            }
        }
    };
}

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
            var client_mut = client;
            var handler = ServerHandler(std.net.Stream).init(&self.config, &client_mut.stream);
            try handler.handleClient();
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
        var handler = ServerHandler(Channel).init(&config, &channel_mut);
        handler.handleClient() catch {};
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
    var server = try ServerTester.init(Config.init(std.testing.allocator));
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
