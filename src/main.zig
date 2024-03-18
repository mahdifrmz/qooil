const builtin = @import("builtin");
const std = @import("std");
const expect = std.testing.expect;

const TagType = u16;

const Header = union(enum(TagType)) {
    None: packed struct {},
    Ping: packed struct { num: u32 },
    PingReply: packed struct { num: u32 },
};

const Message = struct {
    header: Header,
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

fn readHeader(idx: TagType, strm: anytype) !Header {
    const fields = @typeInfo(Header).Union.fields;
    const options = @typeInfo(@typeInfo(Header).Union.tag_type orelse unreachable).Enum.fields;

    inline for (fields) |f| {
        inline for (options) |o| {
            if (std.mem.eql(u8, o.name, f.name)) {
                if (o.value == idx) {
                    var header: Header = .{ .None = {} };
                    return try strm.readAll(std.mem.asBytes(&@field(header.*, f.name)));
                }
            }
        }
    }

    unreachable;
}

const SYSTEM_ENDIANNESS = builtin.target.cpu.arch.endian();

fn toProtoclEndianness(comptime T: type, num: T) T {
    if (SYSTEM_ENDIANNESS == std.builtin.Endian.Little) {
        return num;
    } else {
        return @byteSwap(num);
    }
}

fn writeMessage(mes: Message, strm: anytype) !void {
    const idx = toProtoclEndianness(TagType, @intFromEnum(mes.header));
    try strm.writeAll(std.mem.asBytes(&idx));
    try writeHeader(&mes.header, strm);
}

fn readMessage(strm: anytype) !Message {
    const idx = try strm.readIntLittle(TagType);
    const header = try readHeader(idx, strm);
    return Message{
        .header = header,
    };
}

pub fn main() !void {
    var buffer = [_]u8{0} ** 32;
    var bufferStream = std.io.fixedBufferStream(buffer[0..]);
    var strm = bufferStream.writer();
    const mes = Message{
        .header = Header{ .Ping = .{ .num = 4 } },
    };
    try writeMessage(mes, strm);
}
