const std = @import("std");
const protocol = @import("protocol.zig");
const net = std.net;
const Header = protocol.Header;
pub const ServerError = protocol.ServerError;

pub const Error = error{
    Protocol,
    AlreadyConnected,
    NotConnected,
    ReadingEntry,
    NotReadingEntry,
} || ServerError;

pub const Entry = struct {
    name_buffer: []u8,
    name: []u8,
    is_dir: bool,
};

pub fn Client(comptime T: type) type {
    return struct {
        const Self = @This();
        const DATA_BUFFER_SIZE = 0x1000;

        is_reading_entries: bool,
        stream: ?T,
        server_error_arg1: u32,
        server_error_arg2: u32,
        server_info: ?protocol.InfoHeader,

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
        fn recvOk(self: *Self) !void {
            switch (try self.recv()) {
                .Ok => {},
                else => return error.Protocol,
            }
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
        fn readPayload(self: *Self, buffer: ?[]u8, length: usize) !usize {
            if (buffer) |buf| {
                if (length > buf.len) {
                    return self.stream.?.reader().readAll(buf);
                } else {
                    return self.stream.?.reader().readAll(buf[0..length]);
                }
            } else {
                try self.stream.?.reader().skipBytes(length, .{});
                return 0;
            }
        }
        fn writeBuffer(self: *Self, buffer: []const u8) !void {
            return self.stream.?.writer().writeAll(buffer);
        }

        pub fn init() Self {
            return .{
                .is_reading_entries = false,
                .stream = null,
                .server_error_arg1 = 0,
                .server_error_arg2 = 0,
                .server_info = null,
            };
        }
        pub fn connect(self: *Self, stream: T) !void {
            if (self.stream == null) {
                self.stream = stream;
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
        pub fn info(self: *Self) !protocol.InfoHeader {
            if (self.server_info) |inf| {
                return inf;
            }
            try self.send(
                .{
                    .GetInfo = .{},
                },
            );
            self.server_info = switch (try self.recv()) {
                .Info => |hdr| hdr,
                else => return error.Protocol,
            };
            return self.info();
        }
        pub fn setCwd(self: *Self, path: []const u8) !void {
            try self.checkConnected();
            try self.send(
                .{
                    .Cd = .{
                        .length = @intCast(path.len),
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
                    _ = try self.readPayload(buffer, hdr.length);
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
                    _ = try self.readPayload(buffer, hdr.length);
                    return buffer;
                },
                else => return error.Protocol,
            }
        }
        pub fn getFile(self: *Self, path: []const u8, writer: anytype) !usize {
            try self.checkConnected();
            try self.send(
                .{
                    .Read = .{
                        .length = @intCast(path.len),
                    },
                },
            );
            _ = try self.writeBuffer(path);
            const resp = try self.recv();
            switch (resp) {
                .File => |hdr| {
                    var buf = [_]u8{0} ** DATA_BUFFER_SIZE;
                    var rem = hdr.size;
                    while (rem > 0) {
                        const expected = @min(rem, buf.len);
                        const count = try self.readPayload(buf[0..expected], expected);
                        _ = try writer.writeAll(buf[0..count]);
                        if (count != expected) {
                            return error.Protocol;
                        }
                        rem -= expected;
                    }
                    return hdr.size;
                },
                else => return error.Protocol,
            }
        }
        pub fn putFile(self: *Self, path: []const u8, reader: anytype, size: u64) !void {
            try self.checkConnected();
            try self.send(
                .{
                    .Write = .{
                        .length = @intCast(path.len),
                    },
                },
            );
            _ = try self.writeBuffer(path);
            try self.recvOk();
            try self.send(.{ .File = .{ .size = size } });
            var buf = [_]u8{0} ** DATA_BUFFER_SIZE;
            var rem = size;
            while (rem > 0) {
                const expected = @min(rem, buf.len);
                const count = try reader.readAll(buf[0..expected]);
                try self.writeBuffer(buf[0..count]);
                rem -= expected;
            }
            try self.recvOk();
        }
        pub fn deleteFile(self: *Self, path: []const u8) !void {
            try self.checkConnected();
            try self.send(
                .{
                    .Delete = .{
                        .length = @intCast(path.len),
                    },
                },
            );
            _ = try self.writeBuffer(path);
            try self.recvOk();
        }
        pub fn getEntriesAlloc(self: *Self, path: []const u8, allocator: std.mem.Allocator) !std.ArrayList(Entry) {
            try self.checkConnected();
            try self.send(.{
                .List = .{
                    .length = @intCast(path.len),
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
                        _ = try self.readPayload(name, hdr.length);
                        try list.append(.{
                            .name_buffer = name,
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
                    .length = @intCast(path.len),
                },
            });
            _ = try self.writeBuffer(path);
            switch (try self.recv()) {
                .Ok => {},
                else => return error.Protocol,
            }
            self.is_reading_entries = true;
        }
        pub fn readEntry(self: *Self, entry: ?*Entry) !bool {
            try self.checkReadingEntry();
            switch (try self.recv()) {
                .Entry => |hdr| {
                    if (entry) |ent| {
                        ent.is_dir = hdr.is_dir;
                        const len = try self.readPayload(ent.name_buffer, hdr.length);
                        ent.name = ent.name_buffer[0..len];
                    } else {
                        _ = try self.readPayload(null, hdr.length);
                    }
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
            while (self.is_reading_entries)
                _ = try self.readEntry(null);
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
            self.stream = null;
        }
    };
}
