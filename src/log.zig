const std = @import("std");

pub fn printFmt(comptime fmt: []const u8, args: anytype) void {
    const writer = std.io.getStdOut().writer();
    std.fmt.format(writer, fmt, args) catch {};
}

pub fn errPrintFmt(comptime fmt: []const u8, args: anytype) void {
    const writer = std.io.getStdErr().writer();
    std.fmt.format(writer, fmt, args) catch {};
}

pub fn print(text: []const u8) void {
    std.io.getStdOut().writeAll(text) catch {};
}

pub fn println(text: []const u8) void {
    printFmt("{s}\n", .{text});
}

pub fn eprint(text: []const u8) void {
    std.io.getStdErr().writeAll(text) catch {};
}

pub fn eprintln(text: []const u8) void {
    errPrintFmt("{s}\n", .{text});
}
