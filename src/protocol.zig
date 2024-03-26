const std = @import("std");
/// **The Protocol**
///
/// The communication between the server and client starts by the client opening
/// a TCP connection to the server and terminates by either of the peers closing
/// the connection or the client sending the `quit` message.
/// Multiple messages can be sent in a single TCP connection. For each message
/// that the client sends the server MUST send back the `Error` message, or the
/// corresponding message types as a response, with that being just a simple `OK`
/// message, or even multiple messages each one carrying a payload.
///
/// **General format**
///
/// The format of a message, which is the same for both server and client is
/// as follows. The sender of the message writes these sections of the message
/// on the stream (the TCP connection) sequentially form left to right:
///
///  `<tag: u16>[header: fixed size per tag][payload: variable]`
///
/// The tag is a two-byte little-endian word which indicates the message type.
/// Each type of message (that we in this document refer to as `type`, e.g.
/// `List` for the List message) has it's own header.
/// The message might not have a payload, e.g. `Error` which only has a header
/// or it might just be a sinletag with no header and payload, e.g. `Ping` or `Pwd`
/// The size of the header is fixed per the tag, meaning any `File` message header
/// has a fixed size of `@sizeOf(FileHeader)`.
/// All numbers must be litte-endian.
///
/// **Sending payloads**
///
/// The convention for sending payload which has a variable size is to specify the
/// length in the header of the message (look as `CdHeader`). If the payload
/// consists of two variable-size data (like file path & file content) then both
/// pathes must be mentioned in the header and the data.
/// In case of having to send may variable-size elements (like an array of strings)
/// the convention is that the sender should send messages sequentially each
/// containing a single payload, and then sending the `end` message to indicate the
/// end of elements
pub const Message = struct {
    header: Header,
};

const TagType = u16;

/// All headers must be packed structs {} as it's standardized
/// by the language that packed structs have a guaranteed layout.
/// Some of these messages are only expected to be sent from the
/// client and others are responses sent from the server.
pub const Header = union(enum(TagType)) {
    Read: ReadHeader = 1,
    File: FileHeader = 2,
    List: ListHeader = 3,
    Entry: EntryHeader = 4,
    /// indictaes that the last element has been sent
    End: EmptyHeader = 5,
    Cd: CdHeader = 6,
    Pwd: EmptyHeader = 7,
    Path: PathHeader = 8,
    /// sent by the server as a success response.
    Ok: EmptyHeader = 9,
    GetInfo: EmptyHeader = 10,
    /// parameter negotiation message
    Info: InfoHeader = 11,
    Ping: EmptyHeader = 12,
    PingReply: EmptyHeader = 13,
    /// can be sent from the client to terminate the connection
    Quit: EmptyHeader = 14,
    QuitReply: EmptyHeader = 15,
    Write: WriteHeader = 16,
    Delete: DeleteHeader = 17,
    /// This is only returned by the message parser
    /// to indicate that the peer has returned a
    /// message with an unknown type tag. This message
    /// type should not be sent by neither the client
    /// nor the server.
    Corrupt: CorruptHeader = 18,
    Error: ErrorHeader = 19,
};
pub const EmptyHeader = packed struct {};
pub const ReadHeader = packed struct {
    length: u16,
};
pub const WriteHeader = packed struct {
    length: u16,
};
pub const DeleteHeader = packed struct {
    length: u16,
};
pub const ListHeader = packed struct {
    length: u16,
};
pub const CdHeader = packed struct {
    /// length of the path payload
    length: u16,
};
pub const FileHeader = packed struct {
    size: u64,
};
pub const EntryHeader = packed struct {
    length: u8,
    is_dir: bool,
};
pub const PathHeader = packed struct {
    length: u16,
};
pub const CorruptHeader = packed struct {
    tag: TagType,
};
pub const ErrorHeader = packed struct {
    code: u16,
    arg1: u32,
    arg2: u32,
};
pub const InfoHeader = struct {
    max_name: usize,
    max_path: usize,
};

/// These errors are returned by the server to indicate
/// an error on the side of client.
pub const ServerError = error{
    UnexpectedMessage,
    CorruptMessageTag,
    InvalidFileName,
    UnexpectedEndOfConnection,
    NonExisting,
    IsNotFile,
    IsNotDir,
    AccessDenied,
    CantOpen,
    /// Just to indicate failure to decode error.
    /// must never be returned from the server.
    Unrecognized,
};

pub fn encodeServerError(err: ServerError) u16 {
    return switch (err) {
        error.UnexpectedMessage => 1,
        error.CorruptMessageTag => 2,
        error.InvalidFileName => 3,
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
        1 => error.UnexpectedMessage,
        2 => error.CorruptMessageTag,
        3 => error.InvalidFileName,
        4 => error.UnexpectedEndOfConnection,
        5 => error.NonExisting,
        6 => error.IsNotFile,
        7 => error.IsNotDir,
        8 => error.AccessDenied,
        9 => error.CantOpen,
        else => error.Unrecognized,
    };
}

/// `hdr` must be a pointer to a struct instance.
/// Converts every integer field to little-endian.
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
