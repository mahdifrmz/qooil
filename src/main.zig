const builtin = @import("builtin");
const std = @import("std");
const expect = std.testing.expect;

const TagType = u16;

const Header = union(enum(TagType)) {
    None: packed struct {},
    Ping: packed struct { num: u32 },
    PingReply: packed struct { num: u32 },
};

const Message = struct {
    header: Header,
};

fn writeHeader(header: *const Header, strm: anytype) !void {
    const fields = @typeInfo(Header).Union.fields;
    const options = @typeInfo(@typeInfo(Header).Union.tag_type orelse unreachable).Enum.fields;
    const idx = @intFromEnum(header.*);

    inline for (fields) |f| {
        inline for (options) |o| {
            if (std.mem.eql(u8, o.name, f.name)) {
                if (o.value == idx) {
                    return try strm.writeAll(std.mem.asBytes(&@field(header.*, f.name)));
                }
            }
        }
    }

    unreachable;
}

fn readHeader(idx: TagType, strm: anytype) !Header {
    const fields = @typeInfo(Header).Union.fields;
    const options = @typeInfo(@typeInfo(Header).Union.tag_type orelse unreachable).Enum.fields;

    inline for (fields) |f| {
        inline for (options) |o| {
            if (std.mem.eql(u8, o.name, f.name)) {
                if (o.value == idx) {
                    var header: Header = .{ .None = {} };
                    return try strm.readAll(std.mem.asBytes(&@field(header.*, f.name)));
                }
            }
        }
    }

    unreachable;
}

const SYSTEM_ENDIANNESS = builtin.target.cpu.arch.endian();

fn writeMessage(mes: Message, strm: anytype) !void {
    const idx = std.mem.nativeToLittle(TagType, @intFromEnum(mes.header));
    try strm.writeAll(std.mem.asBytes(&idx));
    try writeHeader(&mes.header, strm);
}

fn readMessage(strm: anytype) !Message {
    const idx = try strm.readIntLittle(TagType);
    const header = try readHeader(idx, strm);
    return Message{
        .header = header,
    };
}

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

const ArgParser = struct {
    const Self = @This();

    current: ?[:0]const u8,
    iterator: std.process.ArgIterator,
    arguments: Arguments,
    fault: ?[]const u8,

    fn init(iterator: std.process.ArgIterator) Self {
        return .{
            .iterator = iterator,
            .arguments = .{
                .port = undefined,
                .mode = undefined,
                .address = undefined,
                .help = false,
            },
            .fault = undefined,
            .current = undefined,
        };
    }

    fn peek(self: *Self) ?[:0]const u8 {
        if (self.current) |_| {} else {
            self.current = self.iterator.next();
        }
        return self.current;
    }

    fn next(self: *Self) ?[:0]const u8 {
        if (self.current) |token| {
            self.current = undefined;
            return token;
        }
        return self.iterator.next();
    }

    fn is_flag(self: *Self) bool {
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
        while (self.is_flag()) {
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
        while (self.is_flag()) {
            try self.nextFlag();
        }
    }

    fn parse(self: *Self) !Arguments {
        try self.parseAllFlags();
        return self.arguments;
    }
};

const DEFAULT_PORT = 7070;

const Config = struct {
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
            if (std.net.isValidHostName(addr)) {
                self.address = addr;
            }
        }
    }

    fn parseCLI(self: *Self, args: Arguments) !void {
        try self.parsePort(args);
        try self.parseAddress(args);
        if (args.mode) |m| {
            self.is_server = m == ExecMode.Server;
        }
    }

    fn init() Self {
        return .{
            .is_server = false,
            .address = "0.0.0.0",
            .port = DEFAULT_PORT,
        };
    }
};

fn showHelp() noreturn {
    std.io.getStdOut().writer().writeAll("HELP\n") catch {};
    std.process.exit(0);
}

fn loadConfig() !Config {
    var parser = ArgParser.init(std.process.args());
    const args = parser.parse() catch return showHelp();
    if (args.help) {
        return showHelp();
    }
    var conf = Config.init();
    try conf.parseCLI(args);
    return conf;
}

pub fn main() !void {
    const conf = try loadConfig();
    _ = conf;
}
