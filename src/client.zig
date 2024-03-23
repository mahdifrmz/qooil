const std = @import("std");
const protocol = @import("protocol.zig");
const net = std.net;
const Header = protocol.Header;
const ServerError = protocol.ServerError;

pub const Error = error{
    Protocol,
    AlreadyConnected,
    NotConnected,
    ReadingEntry,
    NotReadingEntry,
} || ServerError;

pub const Client = struct {
    const Self = @This();
    pub const DEFAULT_PORT = 7070;

    is_reading_entries: bool,
    stream: ?net.Stream,
    server_error_arg1: u32,
    server_error_arg2: u32,

    fn send(self: *Self, header: Header) !void {
        try protocol.writeMessage(.{
            .header = header,
        }, self.stream.?.writer());
    }
    fn recv(self: *Self) !Header {
        const mes = try protocol.readMessage(self.stream.?.reader());
        try self.check(mes.header);
        return mes.header;
    }
    fn check(self: *Self, header: Header) !void {
        switch (header) {
            .Error => |hdr| {
                self.server_error_arg1 = hdr.arg1;
                self.server_error_arg2 = hdr.arg2;
                const err = protocol.decodeServerError(hdr.code);
                switch (err) {
                    error.Unrecognized => return error.Protocol,
                    else => return err,
                }
            },
            .Corrupt => return error.Protocol,
            else => {},
        }
    }
    fn checkConnected(self: *const Self) !void {
        if (self.stream == null) {
            return error.NotConnected;
        }
        if (self.is_reading_entries) {
            return error.ReadingEntry;
        }
    }
    fn checkReadingEntry(self: *const Self) !void {
        if (!self.is_reading_entries) {
            return error.NotReadingEntry;
        }
    }
    fn readToBuffer(self: *Self, buffer: []u8, length: usize) !usize {
        if (length > buffer.len) {
            return self.stream.?.readAll(buffer);
        } else {
            return self.stream.?.readAll(buffer[0..length]);
        }
    }
    fn writeBuffer(self: *Self, buffer: []const u8) !usize {
        return self.stream.?.writer().writeAll(buffer);
    }

    pub const Entry = struct {
        name: []u8,
        is_dir: bool,
    };

    pub fn init() Self {
        return .{
            .is_reading_entries = false,
            .stream = null,
            .server_error_arg1 = 0,
            .server_error_arg2 = 0,
        };
    }
    pub fn connect(self: *Self, host: []const u8, port: u16, allocator: std.mem.Allocator) !void {
        if (self.stream == null) {
            self.stream = try net.tcpConnectToHost(allocator, host, port);
        } else {
            return error.AlreadyConnected;
        }
    }
    pub fn ping(self: *Self) !void {
        try self.send(.{
            .Ping = .{},
        });
        switch (try self.recv()) {
            .PingReply => {},
            else => {},
        }
    }
    pub fn setCwd(self: *Self, path: []const u8) !void {
        try self.checkConnected();
        try self.send(
            .{
                .Cd = .{
                    .length = path.len,
                },
            },
        );
        _ = try self.writeBuffer(path);
        const resp = try self.recv();
        switch (resp) {
            .Ok => {},
            else => return error.Protocol,
        }
    }
    pub fn getCwd(self: *Self, buffer: []u8) !void {
        try self.checkConnected();
        try self.send(
            .{
                .Pwd = .{},
            },
        );
        const resp = try self.recv();
        switch (resp) {
            .Path => |hdr| {
                _ = try self.readToBuffer(buffer, hdr.length);
            },
            else => return error.Protocol,
        }
    }
    pub fn getCwdAlloc(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        try self.checkConnected();
        try self.send(
            .{
                .Pwd = .{},
            },
        );
        const resp = try self.recv();
        switch (resp) {
            .Path => |hdr| {
                var buffer = try allocator.alloc(u8, hdr.length);
                _ = try self.readToBuffer(buffer, hdr.length);
                return buffer;
            },
            else => return error.Protocol,
        }
    }
    pub fn getFile(self: *Self, path: []const u8, writer: anytype) !void {
        try self.checkConnected();
        try self.send(
            .{
                .Read = .{
                    .length = path.len,
                },
            },
        );
        _ = try self.writeBuffer(path);
        const resp = try self.recv();
        switch (resp) {
            .File => |hdr| {
                var buf = [_]u8{0} ** 1024;
                while (true) {
                    const count = try self.readToBuffer(buf, hdr.length);
                    _ = try writer.writeAll(buf);
                    if (count < buf.len) {
                        break;
                    }
                }
            },
            else => return error.Protocol,
        }
    }
    pub fn getEntriesAlloc(self: *Self, path: []const u8, allocator: std.mem.Allocator) !std.ArrayList(Entry) {
        try self.checkConnected();
        try self.send(.{
            .List = .{
                .length = path.len,
            },
        });
        _ = try self.writeBuffer(path);
        switch (try self.recv()) {
            .Ok => {},
            else => return error.Protocol,
        }
        var list = std.ArrayList(Entry).init(allocator);
        errdefer {
            for (list.items) |ele| {
                allocator.free(ele.name);
            }
            list.deinit();
        }
        while (true) {
            switch (try self.recv()) {
                .Entry => |hdr| {
                    var name = try allocator.alloc(u8, hdr.length);
                    _ = try self.readToBuffer(name, hdr.length);
                    try list.append(.{
                        .name = name,
                        .is_dir = hdr.is_dir,
                    });
                },
                .End => break,
                else => return error.Protocol,
            }
        }
        return list;
    }
    pub fn getEntries(self: *Self, path: []const u8) !void {
        try self.checkConnected();
        try self.send(.{
            .List = .{
                .length = path.len,
            },
        });
        _ = try self.writeBuffer(path);
        switch (try self.recv()) {
            .Ok => {},
            else => return error.Protocol,
        }
        self.is_reading_entries = true;
    }
    pub fn readEntry(self: *Self, entry: *Entry) !bool {
        try self.checkReadingEntry();
        switch (try self.recv()) {
            .Entry => |hdr| {
                entry.is_dir = hdr.is_dir;
                _ = try self.readToBuffer(entry.name, hdr.length);
            },
            .End => {
                self.is_reading_entries = false;
            },
            else => return error.Protocol,
        }
        return self.is_reading_entries;
    }
    pub fn abortReadingEntry(self: *Self) !void {
        try self.checkReadingEntry();
        var buf = [_]u8{0} ** 256;
        var entry = Entry{
            .name = buf[0..],
            .is_dir = false,
        };
        while (self.is_reading_entries)
            _ = try self.readEntry(&entry);
    }
    pub fn close(self: *Self) !void {
        if (self.is_reading_entries)
            try self.abortReadingEntry();
        try self.checkConnected();
        try self.send(.{
            .Quit = .{},
        });
        switch (try self.recv()) {
            .QuitReply => {},
            else => return error.Protocol,
        }
    }
};
