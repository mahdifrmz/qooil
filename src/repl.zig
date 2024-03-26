const std = @import("std");
const net = std.net;
const config_mod = @import("config.zig");
const client_mod = @import("client.zig");
const log = @import("log.zig");

const Config = config_mod.Config;
const Client = client_mod.Client;
const ServerError = client_mod.ServerError;
const Entry = client_mod.Entry;

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
        log.println(path);
    } else if (std.mem.eql(u8, command, "quit")) {
        return true;
    } else if (std.mem.eql(u8, command, "ping")) {
        try self.client.ping();
        log.println("the server is up");
    } else if (std.mem.eql(u8, command, "cat")) {
        _ = try self.client.getFile(try self.next(), std.io.getStdOut().writer());
    } else if (std.mem.eql(u8, command, "get")) {
        const remote_path = try self.next();
        const local_path = try self.next();
        const local_file = std.fs.cwd().createFile(local_path, .{}) catch {
            log.errPrintFmt("failed to open local file: {s}\n", .{local_path});
            return false;
        };
        defer local_file.close();
        _ = try self.client.getFile(remote_path, local_file.writer());
    } else if (std.mem.eql(u8, command, "put")) {
        const remote_path = try self.next();
        const local_path = try self.next();
        const local_file = std.fs.cwd().openFile(local_path, .{}) catch {
            log.errPrintFmt("failed to open local file: {s}\n", .{local_path});
            return false;
        };
        const local_file_stat = try local_file.stat();
        defer local_file.close();
        _ = try self.client.putFile(remote_path, local_file.reader(), local_file_stat.size);
    } else if (std.mem.eql(u8, command, "ls")) {
        try self.client.getEntries(self.next() catch ".");
        var buf = [_]u8{0} ** 256;
        var entry = Entry{
            .name_buffer = buf[0..],
            .name = undefined,
            .is_dir = undefined,
        };
        while (try self.client.readEntry(&entry)) {
            log.println(entry.name);
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
    log.print(prompt);
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
            log.printFmt("Error: {s}\n", .{error_text});
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
