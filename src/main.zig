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

const HELP_MESSAGE =
    \\Qooil - An FTP-like file transportation utility
    \\ -s               run server
    \\ -c               run client (default)
    \\ -a               host/address to bind/connect
    \\ -p               port to listen/connect (default is 7070)
    \\ -h               show this help
    \\ -j               server thread count
    \\Examples:
    \\      qooil
    \\      # connect to server running on localhost on port 7070
    \\
    \\      qooil -s -p 7777 -a 127.0.0.1 -j 100
    \\      # run server on port 7777 and loopback interface
    \\      # with thread pool size of 100 threads
    \\
;

fn loadConfig() !Config {
    gpa = .{};
    var parser = ArgParser.init(std.process.args());
    const args = parser.parse() catch {
        log.eprint(HELP_MESSAGE);
        std.process.exit(1);
    };
    if (args.help) {
        log.print(HELP_MESSAGE);
        std.process.exit(0);
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
