const std = @import("std");
const net = std.net;

fn ArrayListFromIterator(
    comptime T: type,
    iter: anytype,
    allocator: std.mem.Allocator,
) !std.ArrayList(T) {
    var list = std.ArrayList(T).init(allocator);
    var iter_mut = iter;
    while (iter_mut.next()) |n| {
        try list.append(n);
    }
    return list;
}

const ExecMode = enum {
    Client,
    Server,
};

const Arguments = struct {
    mode: ?ExecMode,
    address: ?[]const u8,
    port: ?[]const u8,
    help: bool,
};

const ConfigError = error{
    MissingOption,
    InvalidPort,
    UnknownFlag,
};

pub const ArgParser = struct {
    const Self = @This();

    current: ?[:0]const u8,
    iterator: std.process.ArgIterator,
    arguments: Arguments,
    fault: ?[]const u8,

    pub fn init(iterator: std.process.ArgIterator) Self {
        var iter_mut = iterator;
        _ = iter_mut.next();
        return .{
            .iterator = iter_mut,
            .arguments = .{
                .port = null,
                .mode = null,
                .address = null,
                .help = false,
            },
            .fault = null,
            .current = null,
        };
    }

    fn read(self: *Self) ?[:0]const u8 {
        return self.iterator.next();
    }

    fn peek(self: *Self) ?[:0]const u8 {
        if (self.current) |_| {} else {
            self.current = self.read();
        }
        return self.current;
    }

    fn next(self: *Self) ?[:0]const u8 {
        if (self.current) |token| {
            self.current = null;
            return token;
        }
        return self.read();
    }

    fn isFlag(self: *Self) bool {
        const token = self.peek();
        if (token) |tkn| {
            return tkn.len == 2 and tkn[0] == '-';
        }
        return false;
    }

    fn expect(self: *Self, name: []const u8) ![:0]const u8 {
        if (self.next()) |token| {
            return token;
        } else {
            self.fault = name;
            return ConfigError.MissingOption;
        }
    }

    fn nextFlag(self: *Self) !void {
        const token = self.next() orelse unreachable;
        const flag = token[1];
        switch (flag) {
            'c' => {
                self.arguments.mode = ExecMode.Client;
            },
            'h' => {
                self.arguments.help = true;
            },
            's' => {
                self.arguments.mode = ExecMode.Server;
            },
            'a' => {
                self.arguments.address = try self.expect("address");
            },
            'p' => {
                self.arguments.port = try self.expect("port");
            },
            else => {
                self.fault = token;
                return ConfigError.UnknownFlag;
            },
        }
    }

    fn nextPositional(self: *Self, name: []const u8) ![:0]const u8 {
        while (self.isFlag()) {
            try self.nextFlag();
        }
        if (self.next()) |value| {
            return value;
        } else {
            self.fault = name;
            return ConfigError.MissingOption;
        }
    }

    fn parseAllFlags(self: *Self) !void {
        while (self.peek()) |_| {
            if (self.isFlag()) {
                try self.nextFlag();
            } else {
                _ = self.next();
            }
        }
    }

    pub fn parse(self: *Self) !Arguments {
        try self.parseAllFlags();
        return self.arguments;
    }
};

const DEFAULT_PORT = 7070;

pub const Config = struct {
    const Self = @This();

    address: []const u8,
    port: u16,
    is_server: bool,

    fn parsePort(self: *Self, args: Arguments) !void {
        if (args.port) |p| {
            self.port = switch (std.zig.parseNumberLiteral(p)) {
                .failure, .float, .big_int => return ConfigError.InvalidPort,
                .int => |num| blk: {
                    if (num < 1 or num > 0xffff) {
                        return ConfigError.InvalidPort;
                    } else {
                        break :blk @intCast(num);
                    }
                },
            };
        }
    }

    fn parseAddress(self: *Self, args: Arguments) !void {
        if (args.address) |addr| {
            if (net.isValidHostName(addr)) {
                self.address = addr;
            }
        }
    }

    pub fn parseCLI(self: *Self, args: Arguments) !void {
        try self.parsePort(args);
        try self.parseAddress(args);
        if (args.mode) |m| {
            self.is_server = m == ExecMode.Server;
        }
    }

    pub fn init() Self {
        return .{
            .is_server = false,
            .address = "0.0.0.0",
            .port = DEFAULT_PORT,
        };
    }
};
