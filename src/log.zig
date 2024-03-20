const std = @import("std");

pub fn showHelp() noreturn {
    std.io.getStdOut().writer().writeAll("HELP\n") catch {};
    std.process.exit(0);
}

pub fn showError(comptime fmt: []const u8, args: anytype) noreturn {
    var writer = std.io.getStdErr().writer();
    std.fmt.format(writer, fmt, args) catch {};
    _ = writer.write("\n") catch {};
    std.process.exit(1);
}

pub fn showLog(comptime fmt: []const u8, args: anytype) void {
    var writer = std.io.getStdOut().writer();
    std.fmt.format(writer, fmt, args) catch {};
    _ = writer.write("\n") catch {};
}
