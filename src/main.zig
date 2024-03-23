const builtin = @import("builtin");
const std = @import("std");
const net = std.net;
const protocol = @import("protocol.zig");
const configure = @import("configure.zig");
const log = @import("log.zig");
const server_mod = @import("server.zig");
const client_mod = @import("client.zig");

const Server = server_mod.Server;
const Client = client_mod.Client;
const Message = protocol.Message;
const Header = protocol.Header;
const ServerErrors = protocol.ServerErrors;
const ArgParser = configure.ArgParser;
const Config = configure.Config;

var gpa: std.heap.GeneralPurposeAllocator(.{}) = undefined;

fn loadConfig() !Config {
    gpa = .{};
    var parser = ArgParser.init(std.process.args());
    const args = parser.parse() catch return log.showHelp();
    if (args.help) {
        return log.showHelp();
    }
    var conf = Config.init(gpa.allocator());
    try conf.parseCLI(args);
    return conf;
}

pub fn main() !void {
    const conf = try loadConfig();
    if (conf.is_server) {
        var server = Server.init(conf);
        try server.runServer();
    } else {
        var client = Client.init();
        try client.connect(conf.address, conf.port, conf.allocator);
        try client.ping();
        try client.close();
    }
}

test {
    std.testing.refAllDecls(@This());
}
