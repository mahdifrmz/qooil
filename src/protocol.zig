const std = @import("std");

pub const ServerError = error{
    InvalidMessageType,
    CorruptMessageTag,
    MaxPathLengthExceeded,
    UnexpectedEndOfConnection,
    NonExisting,
    IsNotFile,
    IsNotDir,
    AccessDenied,
    CantOpen,

    Unrecognized,
};

pub fn encodeServerError(err: ServerError) u16 {
    return switch (err) {
        error.InvalidMessageType => 1,
        error.CorruptMessageTag => 2,
        error.MaxPathLengthExceeded => 3,
        error.UnexpectedEndOfConnection => 4,
        error.NonExisting => 5,
        error.IsNotFile => 6,
        error.IsNotDir => 7,
        error.AccessDenied => 8,
        error.CantOpen => 9,
        error.Unrecognized => 0xffff,
    };
}

pub fn decodeServerError(code: u16) ServerError {
    return switch (code) {
        1 => error.InvalidMessageType,
        2 => error.CorruptMessageTag,
        3 => error.MaxPathLengthExceeded,
        4 => error.UnexpectedEndOfConnection,
        5 => error.NonExisting,
        6 => error.IsNotFile,
        7 => error.IsNotDir,
        8 => error.AccessDenied,
        9 => error.CantOpen,
        else => error.Unrecognized,
    };
}

const TagType = u16;

pub const Header = union(enum(TagType)) {
    Read: packed struct { length: u8 },
    File: packed struct { size: u64 },
    List: packed struct { length: u8 },
    Entry: packed struct {
        length: u8,
        is_dir: bool,
    },
    End: packed struct {},
    Cd: packed struct { length: u8 },
    Pwd: packed struct {},
    Path: packed struct { length: u16 },
    Ok: packed struct {},
    Ping: packed struct {},
    PingReply: packed struct {},
    Quit: packed struct {},
    QuitReply: packed struct {},
    Corrupt: packed struct { tag: TagType },
    Error: packed struct { code: u16, arg1: u32, arg2: u32 },
};

pub const Message = struct {
    header: Header,
};

fn headerToLittle(hdr: anytype) void {
    var data = hdr;
    switch (@typeInfo(@TypeOf(data))) {
        .Pointer => |ptr| {
            switch (@typeInfo(ptr.child)) {
                .Struct => |strct| {
                    inline for (strct.fields) |field| {
                        switch (@typeInfo(field.type)) {
                            .Int => {
                                @field(data.*, field.name) = std.mem.nativeToLittle(
                                    field.type,
                                    @field(data.*, field.name),
                                );
                            },
                            else => {},
                        }
                    }
                },
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

fn writeHeader(header: Header, strm: anytype) !void {
    var header_mut = header;
    const fields = @typeInfo(Header).Union.fields;
    const options = @typeInfo(@typeInfo(Header).Union.tag_type orelse unreachable).Enum.fields;
    const idx = @intFromEnum(header_mut);

    inline for (fields) |f| {
        inline for (options) |o| {
            if (std.mem.eql(u8, o.name, f.name)) {
                if (o.value == idx) {
                    var data = &@field(header_mut, f.name);
                    headerToLittle(data);
                    try strm.writeAll(std.mem.asBytes(data));
                    return;
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
                    var opt: f.type = undefined;
                    _ = try strm.readAll(std.mem.asBytes(&opt));
                    return @unionInit(Header, f.name, opt);
                }
            }
        }
    }

    return .{
        .Corrupt = .{
            .tag = idx,
        },
    };
}

pub fn writeMessage(mes: Message, strm: anytype) !void {
    const idx = std.mem.nativeToLittle(TagType, @intFromEnum(mes.header));
    try strm.writeAll(std.mem.asBytes(&idx));
    try writeHeader(mes.header, strm);
}

pub fn readMessage(strm: anytype) !Message {
    const idx = try strm.readIntLittle(TagType);
    const header = try readHeader(idx, strm);
    return Message{
        .header = header,
    };
}
