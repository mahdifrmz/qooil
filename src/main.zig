const builtin = @import("builtin");
const std = @import("std");
const net = std.net;
const expect = std.testing.expect;

const TagType = u16;

const Header = union(enum(TagType)) {
    None: void,
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
                    var opt: f.type = undefined;
                    _ = try strm.readAll(std.mem.asBytes(&opt));
                    return @unionInit(Header, f.name, opt);
                }
            }
        }
    }

    unreachable;
}

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
        while (self.peek()) |_| {
            if (self.is_flag()) {
                try self.nextFlag();
            } else {
                _ = self.next();
            }
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
            if (net.isValidHostName(addr)) {
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

fn showError(comptime fmt: []const u8, args: anytype) noreturn {
    var writer = std.io.getStdErr().writer();
    std.fmt.format(writer, fmt, args) catch {};
    _ = writer.write("\n") catch {};
    std.process.exit(1);
}

fn showLog(comptime fmt: []const u8, args: anytype) void {
    var writer = std.io.getStdOut().writer();
    std.fmt.format(writer, fmt, args) catch {};
    _ = writer.write("\n") catch {};
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

fn serverHandleMessage(mes: Message, stream: net.Stream) !Message {
    _ = stream;
    switch (mes.header) {
        .Ping => |pl| {
            var num = std.mem.littleToNative(@TypeOf(pl.num), pl.num);
            num *= 2;
            return Message{
                .header = .{
                    .PingReply = .{
                        .num = num,
                    },
                },
            };
        },
        .PingReply, .None => unreachable,
    }
}

fn run_server(config: Config) !void {
    const addr = net.Address.resolveIp(config.address, config.port) catch showError(
        "Invalid bind IP address",
        .{},
    );
    var server = net.StreamServer.init(.{});
    server.listen(addr) catch showError(
        "Could not listen on {s}:{d}",
        .{
            config.address,
            config.port,
        },
    );
    showLog(
        "Server listening on {s}:{d}",
        .{
            config.address,
            config.port,
        },
    );
    while (server.accept()) |client| {
        var stream = client.stream;
        const mes = try readMessage(stream.reader());
        const resp = try serverHandleMessage(mes, client.stream);
        try writeMessage(resp, stream.writer());
    } else |_| {
        showError("Connection failure", .{});
    }
}
fn run_client(config: Config, allocator: std.mem.Allocator) !void {
    var stream = try net.tcpConnectToHost(allocator, config.address, config.port);
    const mes = Message{
        .header = .{
            .Ping = .{
                .num = 7,
            },
        },
    };
    try writeMessage(mes, stream.writer());
    const resp = try readMessage(stream.reader());
    showLog("Server response: {d}\n", .{resp.header.PingReply.num});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    const conf = try loadConfig();
    if (conf.is_server) {
        try run_server(conf);
    } else {
        try run_client(conf, allocator);
    }
}
