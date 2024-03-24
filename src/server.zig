const std = @import("std");
const net = std.net;
const configure = @import("configure.zig");
const protocol = @import("protocol.zig");
const log = @import("log.zig");

const Header = protocol.Header;
const Config = configure.Config;
const Message = protocol.Message;
const ServerError = protocol.ServerError;
const CdHeader = protocol.CdHeader;
const ListHeader = protocol.ListHeader;
const ReadHeader = protocol.ReadHeader;

const Errors = error{
    Client,
};

/// Created per client.
/// File/stream agnostic.
/// Works on anything that implements reader() & writer().
pub fn ServerHandler(comptime T: type) type {
    return struct {
        const Self = @This();

        isExiting: bool,
        config: *const Config,
        cwd: std.fs.Dir,
        cwd_original: std.fs.Dir,
        stream: *T,
        depth: usize,

        pub fn init(config: *const Config, stream: *T) Self {
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

        fn sendError(self: *Self, err: ServerError, arg1: u32, arg2: u32) !void {
            try self.send(
                .{
                    .Error = .{
                        .code = protocol.encodeServerError(err),
                        .arg1 = arg1,
                        .arg2 = arg2,
                    },
                },
            );
            return err;
        }

        fn send(self: *Self, header: Header) !void {
            try protocol.writeMessage(.{
                .header = header,
            }, self.stream.writer());
        }

        fn recv(self: *Self) !Message {
            return protocol.readMessage(self.stream.reader());
        }
        fn openDir(self: *Self, path: []const u8, dir_depth: ?*usize) !std.fs.Dir {
            var iter = std.mem.splitScalar(u8, path, '/');
            var depth = self.depth;
            var cwd = blk: {
                if (path.len > 0 and path[0] == '/') {
                    depth = 0;
                    break :blk try self.cwd_original.openDir(".", .{});
                } else {
                    break :blk try self.cwd.openDir(".", .{});
                }
            };
            while (iter.next()) |seg| {
                if (seg.len == 0)
                    continue;
                const is_dotdot = std.mem.eql(u8, seg, "..");
                if (is_dotdot) {
                    if (depth > 0) {
                        depth -= 1;
                    } else {
                        continue;
                    }
                } else {
                    depth += 1;
                }

                const new_cwd = cwd.openDir(seg, .{
                    .no_follow = true,
                }) catch |err| {
                    const cerr = switch (err) {
                        error.FileNotFound => ServerError.NonExisting,
                        error.NotDir => ServerError.IsNotDir,
                        error.AccessDenied => ServerError.AccessDenied,
                        else => ServerError.CantOpen,
                    };
                    cwd.close();
                    try self.sendError(cerr, 0, 0);
                    return error.Client;
                };
                cwd.close();
                cwd = new_cwd;
            }

            if (dir_depth) |dd| {
                dd.* = depth;
            }
            return cwd;
        }
        fn readPath(self: *Self, length: u16, buffer: []u8) ![]u8 {
            if (length > std.os.NAME_MAX)
                try self.sendError(ServerError.MaxPathLengthExceeded, length, 0);
            const count: usize = try self.stream.reader().readAll(buffer[0..length]);
            if (count < length) {
                try self.sendError(
                    ServerError.UnexpectedEndOfConnection,
                    0,
                    0,
                );
            }
            return buffer[0..count];
        }
        fn write(self: *Self, buffer: []const u8) !void {
            try self.stream.writer().writeAll(buffer);
        }
        fn endOfList(self: *Self) !void {
            try self.send(
                .{
                    .End = .{},
                },
            );
        }
        fn handlePing(self: *Self) !void {
            try self.send(
                .{
                    .PingReply = .{},
                },
            );
        }
        fn handleQuit(self: *Self) !void {
            self.isExiting = true;
            try self.send(
                .{
                    .QuitReply = .{},
                },
            );
        }
        fn handleCd(self: *Self, hdr: CdHeader) !void {
            var buf = [_]u8{0} ** std.os.NAME_MAX;
            const path = try self.readPath(hdr.length, buf[0..]);
            var depth: usize = 0;
            const dir = try self.openDir(path, &depth);
            self.cwd.close();
            self.cwd = dir;
            self.depth = depth;
            try self.send(
                .{
                    .Ok = .{},
                },
            );
        }
        fn handlePwd(self: *Self) !void {
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
                try self.write("/");
            try self.write(path[root_path.len..]);
        }
        fn handleList(self: *Self, hdr: ListHeader) !void {
            var buf = [_]u8{0} ** std.os.NAME_MAX;
            const path = try self.readPath(hdr.length, buf[0..]);
            var depth: usize = 0;
            var dir = try self.openDir(path, &depth);
            defer dir.close();
            try self.send(.{
                .Ok = .{},
            });
            var iterable = try dir.openIterableDir(".", .{});
            defer iterable.close();
            var iter = iterable.iterate();
            while (try iter.next()) |entry| {
                switch (entry.kind) {
                    .file, .directory => {
                        try self.send(
                            .{
                                .Entry = .{
                                    .length = @intCast(entry.name.len),
                                    .is_dir = entry.kind == std.fs.File.Kind.directory,
                                },
                            },
                        );
                        try self.write(entry.name);
                    },
                    else => continue,
                }
            }
            try self.endOfList();
        }
        fn handleRead(self: *Self, hdr: ReadHeader) !void {
            var buf = [_]u8{0} ** @max(std.os.NAME_MAX, 0x1000);
            const path = try self.readPath(hdr.length, buf[0..]);
            var dir = if (std.fs.path.dirname(path)) |dir_path|
                try self.openDir(dir_path, null)
            else
                try self.cwd.openDir(".", .{});

            defer dir.close();
            const file_name = std.fs.path.basename(path);
            if (file_name.len == 0) {
                try self.sendError(ServerError.IsNotFile, 0, 0);
                return error.Client;
            }
            const file = dir.openFile(file_name, .{}) catch |err| {
                switch (err) {
                    error.FileNotFound => {
                        try self.sendError(ServerError.NonExisting, 0, 0);
                        return error.Client;
                    },
                    error.AccessDenied => {
                        try self.sendError(ServerError.AccessDenied, 0, 0);
                        return error.Client;
                    },
                    else => {
                        return err;
                    },
                }
            };
            defer file.close();
            const file_stat = try file.stat();
            try self.send(
                .{
                    .File = .{
                        .size = file_stat.size,
                    },
                },
            );
            while (true) {
                const count = try file.readAll(buf[0..]);
                try self.write(buf[0..count]);
                if (count < buf.len) {
                    break;
                }
            }
        }
        fn handleMessage(self: *Self, mes: Message) !void {
            switch (mes.header) {
                .Ping => try self.handlePing(),
                .Quit => try self.handleQuit(),
                .Cd => |hdr| try self.handleCd(hdr),
                .Pwd => try self.handlePwd(),
                .List => |hdr| try self.handleList(hdr),
                .Read => |hdr| try self.handleRead(hdr),
                .Corrupt => |hdr| try self.sendError(
                    ServerError.CorruptMessageTag,
                    hdr.tag,
                    0,
                ),
                else => try self.sendError(
                    ServerError.UnexpectedMessage,
                    @intFromEnum(mes.header),
                    0,
                ),
            }
        }

        pub fn handleClient(self: *Self) !void {
            while (!self.isExiting) {
                const mes = try self.recv();
                self.handleMessage(mes) catch {};
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
            handler.handleClient() catch {};
        } else |_| {
            log.showError("Connection failure", .{});
        }
    }
};
