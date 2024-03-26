const std = @import("std");
const net = std.net;
const config_mod = @import("config.zig");
const protocol = @import("protocol.zig");
const log = @import("log.zig");
const client_mod = @import("client.zig");
const server_mod = @import("server.zig");

const Header = protocol.Header;
const Config = config_mod.Config;
const Message = protocol.Message;
const ServerError = protocol.ServerError;
const CdHeader = protocol.CdHeader;
const ListHeader = protocol.ListHeader;
const ReadHeader = protocol.ReadHeader;
const Client = client_mod.Client;
const Server = server_mod.Server;
const ServerHandler = server_mod.ServerHandler;

// The tests for both the server and the client.

/// A naive implementation of a single-producer single-consumer inter-thread communication.
/// This is just for the purpose of testing and thus no real performance is required.
const Channel = struct {
    const Self = @This();
    const DEFAULT_SIZE = 0x1000;

    /// notifies the reader for incoming bytes
    read_sem: std.Thread.Semaphore,
    /// notifies the writer for free-space
    write_sem: std.Thread.Semaphore,
    /// control access to underlying ring buffer
    mtx: std.Thread.Mutex,
    buffer: std.RingBuffer,

    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .mtx = std.Thread.Mutex{},
            .read_sem = std.Thread.Semaphore{},
            .write_sem = std.Thread.Semaphore{
                .permits = DEFAULT_SIZE,
            },
            .buffer = try std.RingBuffer.init(allocator, DEFAULT_SIZE),
        };
    }
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
    }
    pub fn readByte(self: *Self) u8 {
        self.read_sem.wait();
        self.mtx.lock();
        const byte = self.buffer.read().?;
        self.mtx.unlock();
        self.write_sem.post();
        return byte;
    }
    pub fn writeByte(self: *Self, byte: u8) void {
        self.write_sem.wait();
        self.mtx.lock();
        self.buffer.write(byte) catch unreachable;
        self.mtx.unlock();
        self.read_sem.post();
    }
};

/// holds references to two channels.
/// Uses one for sending & the other for recieving data.
const ChannelStream = struct {
    const Self = @This();
    const Reader = std.io.Reader(*Self, std.os.ReadError, read);
    const Writer = std.io.Writer(*Self, std.os.WriteError, write);

    sender: *Channel,
    reciever: *Channel,

    pub fn read(self: *Self, buf: []u8) std.os.ReadError!usize {
        for (buf) |*byte| {
            byte.* = self.reciever.readByte();
        }
        return buf.len;
    }
    pub fn write(self: *Self, buf: []const u8) std.os.WriteError!usize {
        for (buf) |byte| {
            self.sender.writeByte(byte);
        }
        return buf.len;
    }
    pub fn reader(self: *Self) Reader {
        return .{ .context = self };
    }
    pub fn writer(self: *Self) Writer {
        return .{ .context = self };
    }
};
/// Upon initialization, creates a thread which runs a single ServerHandler.
/// The server and client communicate over channels.
/// Call deinit to `join` the thread.
const ServerTester = struct {
    thread: std.Thread,
    // server to client
    inner_cts: *Channel,
    // client to server
    inner_stc: *Channel,
    stream: ChannelStream,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// this runs in another thread
    fn runServer(config: Config, channel: ChannelStream) !void {
        var channel_mut = channel;
        // create a handler instance that operates on a channel
        var handler = ServerHandler(ChannelStream).init(&config, &channel_mut);
        try handler.handleClient();
    }

    fn init(config: Config) !Self {
        const stc = try config.allocator.create(Channel);
        const cts = try config.allocator.create(Channel);
        stc.* = try Channel.init(config.allocator);
        cts.* = try Channel.init(config.allocator);
        const server = ChannelStream{
            .sender = stc,
            .reciever = cts,
        };
        const client = ChannelStream{
            .sender = cts,
            .reciever = stc,
        };
        const thread = try std.Thread.spawn(.{}, runServer, .{ config, server });
        return .{
            .thread = thread,
            .inner_stc = stc,
            .inner_cts = cts,
            .stream = client,
            .allocator = config.allocator,
        };
    }
    fn deinit(self: *Self) void {
        self.inner_cts.deinit(self.allocator);
        self.inner_stc.deinit(self.allocator);
        self.allocator.destroy(self.inner_cts);
        self.allocator.destroy(self.inner_stc);
    }
    fn recv(self: *Self) !Message {
        return try protocol.readMessage(self.stream.reader());
    }
    fn send(self: *Self, mes: Message) !void {
        try protocol.writeMessage(mes, self.stream.writer());
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

fn expectCwd(client: *Client(ChannelStream), exp: []const u8) !void {
    const pwd = try client.getCwdAlloc(std.testing.allocator);
    defer std.testing.allocator.free(pwd);
    try std.testing.expectEqualSlices(u8, exp, pwd);
}
fn expectFile(path: []const u8, data: []const u8) !void {
    try std.testing.expect(data.len < 256);
    var buf = [_]u8{0} ** 256;
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const count = try file.readAll(buf[0..data.len]);
    try std.testing.expectEqualSlices(u8, data, buf[0..count]);
}

// this simple test shows how to test the server & client
test "ping" {
    // run the server in a new thread
    var server = try ServerTester.init(Config.init(std.testing.allocator));
    // join the thread
    defer server.deinit();

    // create the client instance that operates on a channel
    var client = Client(ChannelStream).init();
    try client.connect(server.stream);

    // use client as usual
    try client.ping();

    // send the <quit>
    try client.close();
}

test "corrupt tag" {
    var server = try ServerTester.init(Config.init(std.testing.allocator));
    defer server.deinit();
    const corrupt_tag = std.mem.nativeToLittle(u16, 0xeeee);
    _ = try server.stream.write(std.mem.asBytes(&corrupt_tag));
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

test "info" {
    var server = try ServerTester.init(Config.init(std.testing.allocator));
    defer server.deinit();

    var client = Client(ChannelStream).init();
    try client.connect(server.stream);

    const info = try client.info();
    try std.testing.expectEqual(protocol.InfoHeader{
        .max_name = std.fs.MAX_NAME_BYTES,
        .max_path = std.fs.MAX_PATH_BYTES,
    }, info);

    try client.close();
}

test "working directory" {
    const allocator = std.testing.allocator;
    const temp_dir = try makeTestDir();
    defer removeTestDir(temp_dir);
    var server = try ServerTester.init(Config.init(allocator));
    defer server.deinit();

    var client = Client(ChannelStream).init();
    try client.connect(server.stream);

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

    var client = Client(ChannelStream).init();
    try client.connect(server.stream);
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

test "write file" {
    const allocator = std.testing.allocator;
    const temp_dir = try makeTestDir();
    defer removeTestDir(temp_dir);
    const file_name = "test-file";
    const file_content: []const u8 = "some data";
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ temp_dir, file_name });
    defer allocator.free(file_path);

    var server = try ServerTester.init(Config.init(allocator));
    defer server.deinit();
    var buf_stream = std.io.fixedBufferStream(file_content[0..]);

    var client = Client(ChannelStream).init();
    try client.connect(server.stream);
    try client.putFile(
        file_path,
        buf_stream.reader(),
        file_content.len,
    );
    try client.close();
    try expectFile(file_path, file_content);
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

    var client = Client(ChannelStream).init();
    try client.connect(server.stream);
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
