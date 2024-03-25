const builtin = @import("builtin");
const std = @import("std");
const net = std.net;
const protocol = @import("protocol.zig");
const config_mod = @import("config.zig");
const log = @import("log.zig");
const server_mod = @import("server.zig");
const Repl = @import("repl.zig");
const tests = @import("test.zig");

const Server = server_mod.Server;
const Message = protocol.Message;
const Header = protocol.Header;
const ServerErrors = protocol.ServerErrors;
const ArgParser = config_mod.ArgParser;
const Config = config_mod.Config;

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
        var repl = Repl.init(conf);
        try repl.mainloop(conf);
    }
}

test {
    std.testing.refAllDecls(tests);
}
