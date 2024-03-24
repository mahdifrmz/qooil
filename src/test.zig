const std = @import("std");
const net = std.net;
const configure = @import("configure.zig");
const protocol = @import("protocol.zig");
const log = @import("log.zig");
const client_mod = @import("client.zig");
const server_mod = @import("server.zig");

const Header = protocol.Header;
const Config = configure.Config;
const Message = protocol.Message;
const ServerError = protocol.ServerError;
const CdHeader = protocol.CdHeader;
const ListHeader = protocol.ListHeader;
const ReadHeader = protocol.ReadHeader;
const Client = client_mod.Client;
const Server = server_mod.Server;
const ServerHandler = server_mod.ServerHandler;

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
    fn recv(self: *Self) !Message {
        return try protocol.readMessage(self.channel.reader());
    }
    fn send(self: *Self, mes: Message) !void {
        try protocol.writeMessage(mes, self.channel.writer());
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
    try std.fs.cwd().makePath(path);
    return path;
}

fn makeTestFile(dir_path: []const u8, file_path: []const u8, content: []const u8) !void {
    const dir = try std.fs.cwd().openDir(dir_path, .{});
    const file = try dir.createFile(file_path, .{});
    _ = try file.write(content);
}

fn removeTestDir(name: []const u8) void {
    std.fs.cwd().deleteTree(name) catch {};
    std.testing.allocator.free(name);
}

fn expectCwd(client: *Client(Channel), exp: []const u8) !void {
    const pwd = try client.getCwdAlloc(std.testing.allocator);
    defer std.testing.allocator.free(pwd);
    try std.testing.expectEqualSlices(u8, exp, pwd);
}

test "corrupt tag" {
    var server = try ServerTester.init(Config.init(std.testing.allocator));
    defer server.deinit();
    const corrupt_tag = std.mem.nativeToLittle(u16, 0xeeee);
    _ = try server.channel.write(std.mem.asBytes(&corrupt_tag));
    const resp = try server.recv();
    try std.testing.expectEqual(Message{
        .header = .{
            .Error = .{
                .code = protocol.encodeServerError(ServerError.CorruptMessageTag),
                .arg1 = corrupt_tag,
                .arg2 = 0,
            },
        },
    }, resp);
}

test "invalid commands" {
    var server = try ServerTester.init(Config.init(std.testing.allocator));
    defer server.deinit();
    const mes = Message{
        .header = .{
            .Ok = .{},
        },
    };
    try server.send(mes);
    const resp = try server.recv();
    try std.testing.expectEqual(Message{
        .header = .{
            .Error = .{
                .code = protocol.encodeServerError(ServerError.UnexpectedMessage),
                .arg1 = @intFromEnum(mes.header),
                .arg2 = 0,
            },
        },
    }, resp);
}

test "ping" {
    var server = try ServerTester.init(Config.init(std.testing.allocator));
    defer server.deinit();

    var client = Client(Channel).init();
    try client.connect(server.channel);

    try client.ping();

    try client.close();
}

test "working directory" {
    const allocator = std.testing.allocator;
    const temp_dir = try makeTestDir();
    defer removeTestDir(temp_dir);
    var server = try ServerTester.init(Config.init(allocator));
    defer server.deinit();

    var client = Client(Channel).init();
    try client.connect(server.channel);

    try client.setCwd(temp_dir);
    const exp_pwd = try std.fmt.allocPrint(std.testing.allocator, "/{s}", .{temp_dir});
    defer std.testing.allocator.free(exp_pwd);
    try expectCwd(&client, exp_pwd);
    try client.setCwd("../../..");
    try expectCwd(&client, "/");
    client.setCwd(testdir ++ "/non-existing") catch |err| {
        switch (err) {
            error.NonExisting => {},
            else => unreachable,
        }
    };
    try expectCwd(&client, "/");
    try client.setCwd(temp_dir);
    try client.setCwd("/");
    try expectCwd(&client, "/");

    try client.close();
}

test "read file" {
    const allocator = std.testing.allocator;
    const temp_dir = try makeTestDir();
    defer removeTestDir(temp_dir);
    const file_name = "test-file";
    const file_content: []const u8 = "some data";
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ temp_dir, file_name });
    defer allocator.free(file_path);
    try makeTestFile(temp_dir, file_name, file_content);

    var server = try ServerTester.init(Config.init(allocator));
    defer server.deinit();
    var buf = [_]u8{0} ** 64;
    var buf_stream = std.io.fixedBufferStream(buf[0..]);

    var client = Client(Channel).init();
    try client.connect(server.channel);
    _ = client.getFile(
        temp_dir,
        buf_stream.writer(),
    ) catch |err| {
        switch (err) {
            error.IsNotFile => {},
            else => unreachable,
        }
    };
    const size = try client.getFile(
        file_path,
        buf_stream.writer(),
    );
    try client.close();
    try std.testing.expectEqualSlices(u8, "some data", buf[0..size]);
}

test "list of files" {
    const allocator = std.testing.allocator;
    const temp_dir = try makeTestDir();
    defer removeTestDir(temp_dir);
    var files = [_]struct {
        path: []const u8,
        recieved: bool,
    }{
        .{ .path = "file1", .recieved = false },
        .{ .path = "file2", .recieved = false },
        .{ .path = "file3", .recieved = false },
    };
    for (files) |file| {
        try makeTestFile(temp_dir, file.path, "");
    }
    var server = try ServerTester.init(Config.init(allocator));
    defer server.deinit();

    var client = Client(Channel).init();
    try client.connect(server.channel);
    var entries = try client.getEntriesAlloc(temp_dir, std.testing.allocator);
    defer {
        for (entries.items) |entry| {
            std.testing.allocator.free(entry.name);
        }
        entries.deinit();
    }

    for (entries.items) |entry| {
        var found = false;
        for (&files) |*file| {
            if (std.mem.eql(u8, file.path, entry.name)) {
                if (file.recieved)
                    unreachable;
                file.recieved = true;
                found = true;
                break;
            }
            // std.debug.print("no one: {s}\n", )
        }
        if (!found)
            unreachable;
    }
    for (files) |file| {
        if (!file.recieved) {
            unreachable;
        }
    }
    try client.close();
}
