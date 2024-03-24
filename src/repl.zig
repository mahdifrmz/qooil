const std = @import("std");
const net = std.net;
const configure = @import("configure.zig");
const client_mod = @import("client.zig");

const Config = configure.Config;
const Client = client_mod.Client;
const ServerError = client_mod.ServerError;

const CliError = error{
    NotEnoughArgs,
    UnknownCommand,
};

const Self = @This();

config: Config,
client: Client(net.Stream),
params: std.ArrayList([]const u8),
is_exiting: bool,

fn split(self: *Self, line: []const u8) !void {
    errdefer self.params.clearAndFree();
    var iter = std.mem.splitAny(u8, line, " \t\n");
    while (iter.next()) |word| {
        if (word.len > 0) {
            try self.params.append(word);
        }
    }
}

fn next(self: *Self) ![]const u8 {
    if (self.params.items.len == 0)
        return error.NotEnoughArgs;
    return self.params.orderedRemove(0);
}

fn makePrompt(self: *Self) ![]const u8 {
    const cwd = try self.client.getCwdAlloc(self.config.allocator);
    defer self.config.allocator.free(cwd);
    const prompt = try std.fmt.allocPrint(self.config.allocator, "{s}> ", .{cwd});
    errdefer self.config.allocator.free(prompt);
    return prompt;
}

fn printFmt(comptime fmt: []const u8, args: anytype) !void {
    const writer = std.io.getStdOut().writer();
    try std.fmt.format(writer, fmt, args);
}
fn print(text: []const u8) void {
    std.io.getStdOut().writeAll(text) catch {};
}
fn println(text: []const u8) void {
    printFmt("{s}\n", .{text}) catch {};
}

fn exec(self: *Self) !bool {
    if (self.params.items.len == 0)
        return false;
    const command = try self.next();
    if (std.mem.eql(u8, command, "cd")) {
        const path = try self.next();
        try self.client.setCwd(path);
    } else if (std.mem.eql(u8, command, "pwd")) {
        const path = try self.client.getCwdAlloc(self.config.allocator);
        defer self.config.allocator.free(path);
        println(path);
    } else if (std.mem.eql(u8, command, "quit")) {
        return true;
    } else if (std.mem.eql(u8, command, "ping")) {
        try self.client.ping();
        println("the server is up");
    } else if (std.mem.eql(u8, command, "ls")) {
        var entries = try self.client.getEntriesAlloc(self.next() catch ".", self.config.allocator);
        defer entries.deinit();
        for (entries.items) |entry| {
            println(entry.name);
        }
    } else {
        return error.UnknownCommand;
    }
    return false;
}

fn runloop(self: *Self) !bool {
    // print prompt
    const prompt = try self.makePrompt();
    defer self.config.allocator.free(prompt);
    print(prompt);
    // read line
    var line_buffer = [_]u8{0} ** 0x1000;
    const len = try std.io.getStdIn().read(line_buffer[0..]);
    // exit on ^D
    if (len == 0)
        return true;
    // execute
    try self.split(line_buffer[0..len]);
    defer self.params.clearAndFree();
    return self.exec();
}

pub fn mainloop(self: *Self, config: Config) !void {
    self.client = Client(net.Stream).init();
    const stream = try net.tcpConnectToHost(config.allocator, config.address, config.port);
    try self.client.connect(stream);
    while (true) {
        const will_exit = self.runloop() catch |err| {
            const error_text = switch (err) {
                error.UnknownCommand,
                error.NotEnoughArgs,
                error.NonExisting,
                error.IsNotFile,
                error.IsNotDir,
                error.AccessDenied,
                error.CantOpen,
                => @errorName(err),
                else => return err,
            };
            try printFmt("Error: {s}\n", .{error_text});
            continue;
        };
        if (will_exit) {
            break;
        }
    }
    try self.client.close();
    stream.close();
}

pub fn init(config: Config) Self {
    return .{
        .config = config,
        .is_exiting = false,
        .client = undefined,
        .params = std.ArrayList([]const u8).init(config.allocator),
    };
}
