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

const CommandCallback = *const fn (self: *Self) anyerror!void;

const Command = struct {
    name: []const u8,
    description: []const u8,
    callback: CommandCallback,
};

fn commandlessThan(ctx: void, lhs: Command, rhs: Command) bool {
    _ = ctx;
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

const Self = @This();
const CommandMap = std.StringArrayHashMap(Command);

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
    const entry = self.command_table.get(command) orelse return error.UnknownCommand;
    try entry.callback(self);
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
fn command_stat(self: *Self) !void {
    const remote_path = try self.next();
    const stt = try self.client.stat(remote_path);
    switch (stt) {
        .File => |hdr| {
            log.printFmt("type: file\nsize: {d}\n", .{hdr.size});
        },
        .Dir => {
            log.printFmt("type: directory\n", .{});
        },
    }
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
fn command_delete(self: *Self) !void {
    const remote_path = try self.next();
    try self.client.deleteFile(remote_path);
}
fn command_help(self: *Self) !void {
    var iter = self.command_table.iterator();
    log.println("");
    while (iter.next()) |entry| {
        log.printFmt("{s}\t\t\t{s}\n", .{
            entry.key_ptr.*,
            entry.value_ptr.*.description,
        });
    }
    log.println("");
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

fn connect(self: *Self, config: Config) !void {
    const stream = try net.tcpConnectToHost(config.allocator, config.address, config.port);
    self.client = Client(net.Stream).init();
    try self.client.connect(stream);
}

pub fn mainloop(self: *Self, config: Config) !void {
    try self.installCommands();
    try self.connect(config);
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
                error.InvalidFileName,
                => @errorName(err),
                error.EndOfStream,
                error.connectionResetByPeer,
                => {
                    while (true) {
                        self.connect(config) catch {
                            log.println("trying to reconnect...");
                            std.time.sleep(3 * 1000 * 1000 * 1000);
                            continue;
                        };
                        break;
                    }
                    continue;
                },
                else => return err,
            };
            log.printFmt("Error: {s}\n", .{error_text});
            continue;
        };
    }
    try self.client.close();
}

var commands_list = [_]Command{
    .{
        .name = "put",
        .description = "put <remote-path> <local-path> | upload file to server",
        .callback = command_put,
    },
    .{
        .name = "get",
        .description = "get <remote-path> <local-path> | download file from server",
        .callback = command_get,
    },
    .{
        .name = "ls",
        .description = "ls [dir] | shows entries in CWD or dir",
        .callback = command_ls,
    },
    .{
        .name = "quit",
        .description = "close connection",
        .callback = command_quit,
    },
    .{
        .name = "ping",
        .description = "check whether server is up or not",
        .callback = command_ping,
    },
    .{
        .name = "cat",
        .description = "cat <file> | print file content to terminal",
        .callback = command_cat,
    },
    .{
        .name = "pwd",
        .description = "show CWD",
        .callback = command_pwd,
    },
    .{
        .name = "cd",
        .description = "cd <dir> | change CWD to dir",
        .callback = command_cd,
    },
    .{
        .name = "delete",
        .description = "delete <file> | delete file",
        .callback = command_delete,
    },
    .{
        .name = "stat",
        .description = "stat <file|dir> | get stat of inode",
        .callback = command_stat,
    },
    .{
        .name = "help",
        .description = "print this help",
        .callback = command_help,
    },
};

fn installCommands(self: *Self) !void {
    std.mem.sort(
        Command,
        commands_list[0..],
        {},
        commandlessThan,
    );
    for (commands_list) |cmd| {
        try self.command_table.put(cmd.name, cmd);
    }
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
