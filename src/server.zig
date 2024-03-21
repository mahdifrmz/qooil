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
        cwd_original: std.fs.Dir,
        stream: *T,
        depth: usize,

        fn init(config: *const Config, stream: *T) Self {
            const cwd = std.fs.cwd();
            return .{
                .isExiting = false,
                .config = config,
                .cwd_original = cwd,
                .cwd = cwd.openDir(".", .{}) catch unreachable,
                .stream = stream,
                .depth = 0,
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
        fn changeCwd(self: *Self, path: []const u8) !void {
            var iter = std.mem.splitScalar(u8, path, '/');
            while (iter.next()) |seg| {
                const is_dotdot = std.mem.eql(u8, seg, "..");
                if (is_dotdot) {
                    if (self.depth > 0) {
                        self.depth -= 1;
                    } else {
                        continue;
                    }
                } else {
                    self.depth += 1;
                }

                const newCwd = self.cwd.openDir(seg, .{
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
            }
        }
        fn handleMessage(self: *Self, mes: Message) !void {
            switch (mes.header) {
                .Ping => {
                    return self.send(
                        .{
                            .PingReply = .{},
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
                    try self.changeCwd(path);
                    return self.send(
                        .{
                            .Ok = .{},
                        },
                    );
                },
                .Pwd => |_| {
                    var buf = [_]u8{0} ** std.os.PATH_MAX;
                    var root_buf = [_]u8{0} ** std.os.PATH_MAX;
                    const path = self.cwd.realpath(".", &buf) catch unreachable;
                    const root_path = self.cwd_original.realpath(".", &root_buf) catch unreachable;
                    try self.send(
                        .{
                            .Path = .{
                                .length = @intCast(@max(path.len - root_path.len, 1)),
                            },
                        },
                    );
                    if (path.len == root_path.len)
                        self.stream.writer().writeAll("/") catch unreachable;
                    self.stream.writer().writeAll(path[root_path.len..]) catch unreachable;
                    return;
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
    fn write(self: *Self, data: []const u8) !usize {
        return self.channel.writer().write(data);
    }
    fn read(self: *Self, data: []u8) !usize {
        return self.channel.reader().read(data);
    }
    fn expectPayload(self: *Self, data: []const u8) !void {
        var reader = self.channel.reader();
        for (data) |expected| {
            const actual = try reader.readByte();
            try std.testing.expectEqual(expected, actual);
        }
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

    fn sendCd(self: *Self, path: []const u8) !void {
        try self.send(
            .{
                .header = .{
                    .Cd = .{
                        .length = @intCast(path.len),
                    },
                },
            },
        );
        _ = try self.write(path);
    }
    fn sendPwd(self: *Self) !void {
        try self.send(
            .{
                .header = .{
                    .Pwd = .{},
                },
            },
        );
    }
    fn expectOk(self: *Self) !void {
        try std.testing.expectEqual(
            Header{
                .Ok = .{},
            },
            (try self.recv()).header,
        );
    }
    fn expectPath(self: *Self, length: u16) !void {
        try std.testing.expectEqual(
            Header{
                .Path = .{
                    .length = length,
                },
            },
            (try self.recv()).header,
        );
    }
};

const testdir = "testdir";

fn makeTestDir() ![]u8 {
    const uuid = std.crypto.random.int(u128);
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{d}",
        .{ testdir, uuid },
    );
    try std.fs.cwd().makeDir(path);
    return path;
}

fn removeTestDir(name: []const u8) void {
    std.fs.cwd().deleteDir(name) catch {};
    std.testing.allocator.free(name);
}

test "ping" {
    var server = try ServerTester.init(Config.init(std.testing.allocator));
    defer server.deinit();
    try server.send(.{
        .header = .{
            .Ping = .{},
        },
    });
    const mesg = try server.recv();
    switch (mesg.header) {
        .PingReply => {},
        else => unreachable,
    }
    try server.quit();
}

test "working directory" {
    const allocator = std.testing.allocator;
    const temp_dir = try makeTestDir();
    defer removeTestDir(temp_dir);
    var server = try ServerTester.init(Config.init(allocator));
    defer server.deinit();
    try server.sendCd(temp_dir);
    try server.expectOk();
    try server.sendPwd();
    try server.expectPath(@intCast(temp_dir.len + 1));
    try server.expectPayload("/");
    try server.expectPayload(temp_dir);
    try server.sendCd("../../..");
    try server.expectOk();
    try server.sendPwd();
    try server.expectPath(1);
    try server.expectPayload("/");
    try server.quit();
}
