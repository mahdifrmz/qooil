const std = @import("std");
const configure = @import("configure.zig");
const client_mod = @import("client.zig");

const Config = configure.Config;
const Client = client_mod.Client;

const CliError = error{
    NotEnoughArgs,
    UnknownCommand,
};

fn split(line: []const u8, config: Config) !std.ArrayList([]const u8) {
    var list = std.ArrayList([]const u8).init(config.allocator);
    errdefer list.deinit();
    var iter = std.mem.splitAny(u8, line, " \t\n");
    while (iter.next()) |word| {
        if (word.len > 0) {
            try list.append(word);
        }
    }
    return list;
}

fn next(params: *std.ArrayList([]const u8)) ![]const u8 {
    if (params.items.len == 0)
        return error.NotEnoughArgs;
    return params.orderedRemove(0);
}

pub fn runloop(client: *Client, config: Config) !bool {
    const cwd = try client.getCwdAlloc(config.allocator);
    defer config.allocator.free(cwd);
    const prompt = try std.fmt.allocPrint(config.allocator, "{s}> ", .{cwd});
    defer config.allocator.free(prompt);
    var line_buffer = [_]u8{0} ** 0x1000;
    _ = try std.io.getStdOut().write(prompt);
    const len = try std.io.getStdIn().read(line_buffer[0..]);
    if (len == 0)
        return true;
    var params = try split(line_buffer[0..len], config);
    defer params.deinit();
    if (params.items.len == 0)
        return false;
    const command = try next(&params);
    if (std.mem.eql(u8, command, "cd")) {
        const path = try next(&params);
        try client.setCwd(path);
    } else if (std.mem.eql(u8, command, "pwd")) {
        const path = try client.getCwdAlloc(config.allocator);
        defer config.allocator.free(path);
        try std.io.getStdOut().writeAll(path);
        try std.io.getStdOut().writeAll("\n");
    } else if (std.mem.eql(u8, command, "quit")) {
        return true;
    } else if (std.mem.eql(u8, command, "ping")) {
        try client.ping();
        try std.io.getStdOut().writeAll("the server is up\n");
    } else if (std.mem.eql(u8, command, "ls")) {
        var entries = try client.getEntriesAlloc(next(&params) catch ".", config.allocator);
        defer entries.deinit();
        for (entries.items) |entry| {
            try std.io.getStdOut().writeAll(entry.name);
            try std.io.getStdOut().writeAll("\n");
        }
    } else {
        return error.UnknownCommand;
    }
    return false;
}

pub fn mainloop(config: Config) !void {
    var client = Client.init();
    try client.connect(config.address, config.port, config.allocator);
    while (true) {
        const will_exit = runloop(&client, config) catch |err| {
            try std.fmt.format(std.io.getStdOut().writer(), "Error: {s}\n", .{@errorName(err)});
            continue;
        };
        if (will_exit) {
            break;
        }
    }
    try client.close();
}
