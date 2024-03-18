const std = @import("std");
const expect = @import("std").testing.expect;

const Header = union(enum) {
    Ping: packed struct { num: u32 },
    PingReply: packed struct { num: u32 },
};

const Message = struct {
    header: Header,
    body: ?[]u8,
};

fn writeHeader(header: *const Header, strm: anytype) !void {
    const fields = @typeInfo(Header).Union.fields;
    const options = @typeInfo(@typeInfo(Header).Union.tag_type orelse unreachable).Enum.fields;
    const idx = @intFromEnum(header.*);

    inline for (fields) |f| {
        inline for (options) |o| {
            if (std.mem.eql(u8, o.name, f.name)) {
                if (o.value == idx) {
                    return try strm.writeAll(std.mem.asBytes(&@field(header.*, f.name)));
                }
            }
        }
    }

    unreachable;
}

fn writeMessage(mes: Message, strm: anytype) !void {
    const idx = @intFromEnum(mes.header);
    try strm.writeAll(std.mem.asBytes(&idx));
    try writeHeader(&mes.header, strm);
    if (mes.body) |body| {
        try strm.writeAll(body);
    }
}

pub fn main() !void {
    var buffer = [_]u8{0} ** 32;
    var bufferStream = std.io.fixedBufferStream(buffer[0..]);
    var strm = bufferStream.writer();
    const mes = Message{
        .header = Header{ .Ping = .{ .num = 4 } },
        .body = undefined,
    };
    try writeMessage(mes, strm);
    // for (buffer) |e| {
    //     std.debug.print("-> {d}\n", .{e});
    // }
    std.debug.print("S = {d}", .{@sizeOf(?u64)});
}
