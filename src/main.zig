const builtin = @import("builtin");
const std = @import("std");
const net = std.net;
const protocol = @import("protocol.zig");
const configure = @import("configure.zig");
const log = @import("log.zig");
const server_mod = @import("server.zig");

const Server = server_mod.Server;
const Message = protocol.Message;
const Header = protocol.Header;
const ClientErrors = protocol.ClientErrors;
const ArgParser = configure.ArgParser;
const Config = configure.Config;

fn loadConfig() !Config {
    var parser = ArgParser.init(std.process.args());
    const args = parser.parse() catch return log.showHelp();
    if (args.help) {
        return log.showHelp();
    }
    var conf = Config.init();
    try conf.parseCLI(args);
    return conf;
}

fn runClient(config: Config, allocator: std.mem.Allocator) !void {
    var stream = try net.tcpConnectToHost(allocator, config.address, config.port);
    const mes = Message{
        .header = .{
            .Ping = .{
                .num = 7,
            },
        },
    };
    try protocol.writeMessage(mes, stream.writer());
    const resp = try protocol.readMessage(stream.reader());
    log.showLog("Server response: {d}\n", .{resp.header.PingReply.num});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    const conf = try loadConfig();
    if (conf.is_server) {
        var server = Server.init(conf);
        try server.runServer();
    } else {
        try runClient(conf, allocator);
    }
}

test {
    std.testing.refAllDecls(@This());
}
