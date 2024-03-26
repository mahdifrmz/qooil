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
const CommandMap = std.StringHashMap(*const fn (self: *Self) anyerror!void);

config: Config,
client: Client(net.Stream),
params: std.ArrayList([]const u8),
is_exiting: bool,
command_table: CommandMap,

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

fn exec(self: *Self) !void {
    if (self.params.items.len == 0)
        return;
    const command = try self.next();
    const cb = self.command_table.get(command) orelse return error.UnknownCommand;
    try cb(self);
}

fn command_cd(self: *Self) !void {
    const path = try self.next();
    try self.client.setCwd(path);
}
fn command_pwd(self: *Self) !void {
    const path = try self.client.getCwdAlloc(self.config.allocator);
    defer self.config.allocator.free(path);
    log.println(path);
}
fn command_quit(self: *Self) !void {
    self.is_exiting = true;
}
fn command_ping(self: *Self) !void {
    try self.client.ping();
    log.println("the server is up");
}
fn command_cat(self: *Self) !void {
    _ = try self.client.getFile(try self.next(), std.io.getStdOut().writer());
}
fn command_get(self: *Self) !void {
    const remote_path = try self.next();
    const local_path = try self.next();
    const local_file = std.fs.cwd().createFile(local_path, .{}) catch {
        log.errPrintFmt("failed to open local file: {s}\n", .{local_path});
        return;
    };
    defer local_file.close();
    _ = try self.client.getFile(remote_path, local_file.writer());
}
fn command_put(self: *Self) !void {
    const remote_path = try self.next();
    const local_path = try self.next();
    const local_file = std.fs.cwd().openFile(local_path, .{}) catch {
        log.errPrintFmt("failed to open local file: {s}\n", .{local_path});
        return;
    };
    const local_file_stat = try local_file.stat();
    defer local_file.close();
    _ = try self.client.putFile(remote_path, local_file.reader(), local_file_stat.size);
}
fn command_ls(self: *Self) !void {
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
}

fn runloop(self: *Self) !void {
    // print prompt
    const prompt = try self.makePrompt();
    defer self.config.allocator.free(prompt);
    log.print(prompt);
    // read line
    var line_buffer = [_]u8{0} ** 0x1000;
    const len = try std.io.getStdIn().read(line_buffer[0..]);
    // exit on ^D
    if (len == 0) {
        self.is_exiting = true;
        return;
    }
    // execute
    try self.split(line_buffer[0..len]);
    defer self.params.clearAndFree();
    try self.exec();
}

pub fn mainloop(self: *Self, config: Config) !void {
    self.client = Client(net.Stream).init();
    try self.install_commands();
    const stream = try net.tcpConnectToHost(config.allocator, config.address, config.port);
    try self.client.connect(stream);
    while (!self.is_exiting) {
        self.runloop() catch |err| {
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
    }
    try self.client.close();
    stream.close();
}

fn install_commands(self: *Self) !void {
    try self.command_table.put("put", command_put);
    try self.command_table.put("get", command_get);
    try self.command_table.put("ls", command_ls);
    try self.command_table.put("quit", command_quit);
    try self.command_table.put("ping", command_ping);
    try self.command_table.put("cat", command_cat);
    try self.command_table.put("pwd", command_pwd);
    try self.command_table.put("cd", command_cd);
}

pub fn init(config: Config) Self {
    return .{
        .config = config,
        .is_exiting = false,
        .client = undefined,
        .params = std.ArrayList([]const u8).init(config.allocator),
        .command_table = CommandMap.init(config.allocator),
    };
}
