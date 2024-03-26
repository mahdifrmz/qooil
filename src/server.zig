const std = @import("std");
const net = std.net;
const config_mod = @import("config.zig");
const protocol = @import("protocol.zig");
const log = @import("log.zig");

const Header = protocol.Header;
const Config = config_mod.Config;
const Message = protocol.Message;
const ServerError = protocol.ServerError;
const CdHeader = protocol.CdHeader;
const ListHeader = protocol.ListHeader;
const ReadHeader = protocol.ReadHeader;
const WriteHeader = protocol.WriteHeader;

/// Created per client.
/// File/stream agnostic.
/// Works on anything that implements reader() & writer().
pub fn ServerHandler(comptime T: type) type {
    return struct {
        const MAX_NAME = std.fs.MAX_NAME_BYTES;
        const MAX_PATH = std.fs.MAX_PATH_BYTES;
        const READ_BUFFER_SIZE = 0x1000;
        const Self = @This();

        isExiting: bool,
        config: *const Config,
        cwd: std.fs.Dir,
        cwd_original: std.fs.Dir,
        stream: *T,
        depth: usize,
        error_arg1: u32,
        error_arg2: u32,

        pub fn init(config: *const Config, stream: *T) Self {
            const cwd = std.fs.cwd();
            return .{
                .isExiting = false,
                .config = config,
                .cwd_original = cwd,
                .cwd = copyDir(cwd),
                .stream = stream,
                .depth = 0,
                .error_arg1 = 0,
                .error_arg2 = 0,
            };
        }

        fn deinit(self: *Self) void {
            self.cwd.close();
        }

        fn sendError(self: *Self, err: ServerError) !void {
            try self.send(
                .{
                    .Error = .{
                        .code = protocol.encodeServerError(err),
                        .arg1 = self.error_arg1,
                        .arg2 = self.error_arg2,
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
        fn openDir(self: *Self, path: []const u8, dir_depth: ?*usize) !std.fs.Dir {
            var iter = try std.fs.path.componentIterator(path);
            var depth = self.depth;
            var dir = blk: {
                if (std.fs.path.isAbsolute(path)) {
                    depth = 0;
                    break :blk copyDir(self.cwd_original);
                } else {
                    break :blk copyDir(self.cwd);
                }
            };
            errdefer dir.close();
            while (iter.next()) |seg| {
                if (seg.name.len == 0)
                    continue;
                const is_dotdot = std.mem.eql(u8, seg.name, "..");
                if (is_dotdot) {
                    if (depth > 0) {
                        depth -= 1;
                    } else {
                        continue;
                    }
                } else {
                    depth += 1;
                }

                const new_dir = dir.openDir(seg.name, .{
                    .no_follow = true,
                }) catch |err| {
                    return switch (err) {
                        error.FileNotFound => ServerError.NonExisting,
                        error.NotDir => ServerError.IsNotDir,
                        error.AccessDenied => ServerError.AccessDenied,
                        else => ServerError.CantOpen,
                    };
                };
                dir = new_dir;
            }

            if (dir_depth) |dd| {
                dd.* = depth;
            }
            return dir;
        }
        fn readPath(self: *Self, length: u16, buffer: []u8) ![]u8 {
            if (length > MAX_NAME) {
                try self.stream.reader().skipBytes(length, .{});
                self.error_arg1 = length;
                return ServerError.InvalidFileName;
            }
            const count: usize = try self.stream.reader().readAll(buffer[0..length]);
            if (count < length)
                return ServerError.UnexpectedEndOfConnection;
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
            var buf = [_]u8{0} ** MAX_NAME;
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
            var buf = [_]u8{0} ** MAX_PATH;
            var root_buf = [_]u8{0} ** MAX_PATH;
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
            var buf = [_]u8{0} ** MAX_NAME;
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
        fn handleGetInfo(self: *Self) !void {
            try self.send(
                .{
                    .Info = .{
                        .max_name = MAX_NAME,
                        .max_path = MAX_PATH,
                    },
                },
            );
        }
        fn copyDir(dir: std.fs.Dir) std.fs.Dir {
            return dir.openDir(".", .{}) catch unreachable;
        }
        fn openFile(
            self: *Self,
            path: []const u8,
            open_write: bool,
        ) !std.fs.File {
            var dir = if (std.fs.path.dirname(path)) |dir_path|
                try self.openDir(dir_path, null)
            else
                copyDir(self.cwd);
            defer dir.close();
            const file_name = std.fs.path.basename(path);
            if (file_name.len == 0)
                return ServerError.InvalidFileName;
            const file = (if (open_write)
                dir.createFile(file_name, .{})
            else
                dir.openFile(file_name, .{})) catch |err| {
                return switch (err) {
                    error.FileNotFound => ServerError.NonExisting,
                    error.AccessDenied => ServerError.AccessDenied,
                    error.IsDir => ServerError.IsNotFile,
                    else => err,
                };
            };
            const stat = try file.stat();
            switch (stat.kind) {
                .file => return file,
                else => return ServerError.IsNotFile,
            }
        }
        fn handleRead(self: *Self, hdr: ReadHeader) !void {
            var buf = [_]u8{0} ** @max(MAX_NAME, READ_BUFFER_SIZE);
            const path = try self.readPath(hdr.length, buf[0..]);
            const file = try self.openFile(
                path,
                false,
            );
            defer file.close();
            const stat = try file.stat();
            try self.send(
                .{
                    .File = .{
                        .size = stat.size,
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
        fn handleWrite(self: *Self, hdr: WriteHeader) !void {
            var buf = [_]u8{0} ** @max(MAX_NAME, READ_BUFFER_SIZE);
            const path = try self.readPath(hdr.length, buf[0..]);
            const file = try self.openFile(
                path,
                true,
            );
            defer file.close();
            try self.send(.{ .Ok = .{} });
            const next_msg = try self.recv();
            const fhdr = switch (next_msg.header) {
                .File => |fhdr| fhdr,
                else => {
                    self.error_arg1 = @intFromEnum(next_msg.header);
                    return ServerError.UnexpectedMessage;
                },
            };
            var rem = fhdr.size;
            while (rem > 0) {
                const count = try self.stream.reader().readAll(buf[0..@min(READ_BUFFER_SIZE, rem)]);
                rem -= count;
                _ = try file.write(buf[0..count]);
            }
            try self.send(.{ .Ok = .{} });
        }
        fn handleMessage(self: *Self, mes: Message) !void {
            switch (mes.header) {
                .Ping => try self.handlePing(),
                .Quit => try self.handleQuit(),
                .Cd => |hdr| try self.handleCd(hdr),
                .Pwd => try self.handlePwd(),
                .List => |hdr| try self.handleList(hdr),
                .Read => |hdr| try self.handleRead(hdr),
                .Write => |hdr| try self.handleWrite(hdr),
                .GetInfo => try self.handleGetInfo(),
                .Corrupt => |hdr| {
                    self.error_arg1 = hdr.tag;
                    return ServerError.CorruptMessageTag;
                },
                else => {
                    self.error_arg1 = @intFromEnum(mes.header);
                    return ServerError.UnexpectedMessage;
                },
            }
        }

        pub fn handleClient(self: *Self) !void {
            while (!self.isExiting) {
                const mes = try self.recv();
                self.handleMessage(mes) catch |err| {
                    switch (err) {
                        error.UnexpectedMessage,
                        error.CorruptMessageTag,
                        error.InvalidFileName,
                        error.UnexpectedEndOfConnection,
                        error.NonExisting,
                        error.IsNotFile,
                        error.IsNotDir,
                        error.AccessDenied,
                        error.CantOpen,
                        => try self.sendError(
                            @errSetCast(err),
                        ),
                        else => {
                            return err;
                        },
                    }
                    self.error_arg1 = 0;
                    self.error_arg2 = 0;
                };
            }
        }
    };
}

pub const Server = struct {
    const Self = @This();
    const Handler = ServerHandler(net.Stream);

    config: Config,
    pool: std.Thread.Pool,

    pub fn init(config: Config) Self {
        return .{
            .config = config,
            .pool = undefined,
        };
    }

    fn handlerThread(stream: net.Stream, config: Config) void {
        var stream_mut = stream;
        var handler = Handler.init(&config, &stream_mut);
        handler.handleClient() catch {};
    }

    pub fn runServer(self: *Self) !void {
        try self.pool.init(
            .{
                .allocator = self.config.allocator,
                .n_jobs = self.config.thread_pool_size,
            },
        );
        defer self.pool.deinit();
        const addr = net.Address.resolveIp(self.config.address, self.config.port) catch {
            log.eprintln(
                "Invalid bind IP address",
            );
            std.process.exit(1);
        };
        var stream_server = net.StreamServer.init(.{});
        stream_server.listen(addr) catch {
            log.errPrintFmt(
                "Could not listen on {s}:{d}\n",
                .{
                    self.config.address,
                    self.config.port,
                },
            );
            std.process.exit(1);
        };
        log.printFmt(
            "Server listening on {s}:{d}\n",
            .{
                self.config.address,
                self.config.port,
            },
        );
        while (stream_server.accept()) |client| {
            try self.pool.spawn(handlerThread, .{ client.stream, self.config });
        } else |_| {
            log.eprintln("Connection failure");
        }
    }
};

fn isServerError(err: anyerror) ?ServerError {
    const info = @typeInfo(ServerError);
    inline for (info.ErrorSet orelse .{}) |opt| {
        if (err == @field(ServerError, opt.name)) {
            return @errSetCast(err);
        }
    }
    return null;
}
