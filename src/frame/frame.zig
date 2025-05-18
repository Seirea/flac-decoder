const std = @import("std");
const StreamInfo = @import("../metadata/block.zig").StreamInfo;
const crc8 = std.hash.crc.Crc(u8, .{
    .polynomial = 0x07,
    .initial = 0x00,
    .reflect_input = false,
    .reflect_output = false,
    .xor_output = 0x0,
});

const FrameParsingError = error{
    incorrect_frame_sync,
    missing_zero_bit, // subframe
    forbidden_sample_rate,
    using_reserved_value,
    stream_info_does_not_exist,
    crc_mismatch,
};

pub const ParsingBlockSize = enum(u4) {
    _reserved = 0,
    @"192" = 1,
    @"576" = 2,
    @"1152" = 3,
    @"2304" = 4,
    @"4608" = 5,
    uncommon_8bit = 6,
    uncommon_16bit = 7,
    @"256" = 8,
    @"512" = 9,
    @"1024" = 10,
    @"2048" = 11,
    @"4096" = 12,
    @"8192" = 13,
    @"16384" = 14,
    @"32768" = 15,
};

// in kHz
pub const ParsingSampleRate = enum(u4) {
    in_streaminfo = 0,
    @"88.2" = 1,
    @"176.4" = 2,
    @"192" = 3,
    @"8" = 4,
    @"16" = 5,
    @"22.05" = 6,
    @"24" = 7,
    @"32" = 8,
    @"44.1" = 9,
    @"48" = 10,
    @"96" = 11,
    uncommon_8bit = 12,
    uncommon_16bit = 13,
    uncommon_16bit_div_10 = 14,
    forbidden = 15,
};

pub const Channel = enum(u4) {
    mono = 0,
    stereo,
    three,
    four,
    five,
    six,
    seven,
    eight,
    left_side,
    side_right,
    mid_side,
};

pub const BitDepth = enum(u3) {
    in_streaminfo = 0b000,
    @"8-bit" = 0b001,
    @"12-bit" = 0b010,
    reserved = 0b011,
    @"16-bit" = 0b100,
    @"20-bit" = 0b101,
    @"24-bit" = 0b110,
    @"32-bit" = 0b111,

    /// Returns bitdepth-1 aka [0 ... 31] => [1 ... 32] :)
    pub fn asIntMinusOne(self: BitDepth, stream_info: ?StreamInfo) FrameParsingError!u5 {
        return switch (self) {
            .in_streaminfo => blk: {
                if (stream_info) |si| {
                    break :blk si.bits_per_sample_minus_one;
                } else {
                    break :blk error.stream_info_does_not_exist;
                }
            },
            .@"8-bit" => 7,
            .@"12-bit" => 11,
            .reserved => error.using_reserved_value,
            .@"16-bit" => 15,
            .@"20-bit" => 19,
            .@"24-bit" => 23,
            .@"32-bit" => 31,
        };
    }
};

pub const Frame = struct {
    header: FrameHeader,
    sub_frames: []SubFrame,
};

pub fn readCustomIntToEnum(comptime Enum: type, bit_reader: anytype) !Enum {
    const int_representation = @typeInfo(Enum).@"enum".tag_type;

    return @enumFromInt(try bit_reader.readBitsNoEof(int_representation, @bitSizeOf(int_representation)));
}

pub fn CrcWriter(comptime T: type) type {
    return struct {
        crc_obj: *T,

        pub fn writeByte(self: *CrcWriter(T), bits: u8) !void {
            const out = [1]u8{bits};
            self.crc_obj.update(&out);
            // std.debug.print("wrote: {X}\n", .{out});
        }
    };
}

pub fn ReaderToCRCWriter(comptime T: type) type {
    return struct {
        reader: std.io.AnyReader,
        br: std.io.BitReader(.big, std.io.AnyReader),
        bw: *std.io.BitWriter(.big, CrcWriter(T)),

        fn init(reader: std.io.AnyReader, bw: *std.io.BitWriter(.big, CrcWriter(T))) ReaderToCRCWriter(T) {
            return .{
                .reader = reader,
                .br = std.io.bitReader(.big, reader),
                .bw = bw,
            };
        }

        // fn readBitsNoEof
        fn readBitsNoEof(self: *ReaderToCRCWriter(T), comptime I: type, num: u16) !I {
            const read = try self.br.readBitsNoEof(I, num);
            try self.bw.writeBits(read, num);

            return read;
        }

        fn readInt(self: *ReaderToCRCWriter(T), comptime I: type, endian: std.builtin.Endian) !I {
            const read = try self.reader.readInt(I, endian);
            try self.bw.writeBits(read, @bitSizeOf(I));

            return read;
        }
    };
}
pub const FrameHeader = struct {
    blocking_strategy: bool, // 0 is fixed block size, 1 is variable
    block_size: u16,
    sample_rate: ParsingSampleRate,
    unusual_sample_rate: ?u18 = null,
    channel: Channel,
    bit_depth: BitDepth,
    coded_number: u36,
    crc: u8,

    pub fn parseFrameHeader(reader: std.io.AnyReader) !FrameHeader {
        var hasher = crc8.init();
        const crc_writer = CrcWriter(crc8){ .crc_obj = &hasher };

        var bw = std.io.bitWriter(.big, crc_writer);

        var crc_reader = ReaderToCRCWriter(crc8).init(reader, &bw);

        var frame_header: FrameHeader = undefined;
        frame_header.unusual_sample_rate = null;

        if (try crc_reader.readBitsNoEof(u15, 15) != 0b111111111111100) {
            return error.incorrect_frame_sync;
        }

        frame_header.blocking_strategy = try crc_reader.readBitsNoEof(u1, @bitSizeOf(u1)) == 1;

        const bs = try readCustomIntToEnum(ParsingBlockSize, &crc_reader);
        frame_header.sample_rate = try readCustomIntToEnum(ParsingSampleRate, &crc_reader);
        frame_header.channel = try readCustomIntToEnum(Channel, &crc_reader);
        frame_header.bit_depth = try readCustomIntToEnum(BitDepth, &crc_reader);

        if (try crc_reader.readBitsNoEof(u1, 1) != 0) {
            return error.using_reserved_value;
        }

        frame_header.coded_number = try decodeNumber(&crc_reader);

        frame_header.block_size = switch (bs) {
            .uncommon_8bit => try crc_reader.readInt(u8, .big),
            .uncommon_16bit => try crc_reader.readInt(u16, .big),
            .@"192" => 192,
            .@"576" => 576,
            .@"1152" => 1152,
            .@"2304" => 2304,
            .@"4608" => 4608,
            .@"256" => 256,
            .@"512" => 512,
            .@"1024" => 1024,
            .@"2048" => 2048,
            .@"4096" => 4096,
            .@"8192" => 8192,
            .@"16384" => 16384,
            .@"32768" => 32768,
            ._reserved => {
                return error.using_reserved_value;
            },
        };

        switch (frame_header.sample_rate) {
            .uncommon_8bit => {
                frame_header.unusual_sample_rate = @as(u18, try crc_reader.readInt(u8, .big)) * 1000;
            },
            .uncommon_16bit => {
                frame_header.unusual_sample_rate = try crc_reader.readInt(u16, .big);
            },
            .uncommon_16bit_div_10 => {
                // TODO: Fix this to be more accurate to the RFC
                frame_header.unusual_sample_rate = @divFloor(try crc_reader.readInt(u16, .big), 10);
            },
            .forbidden => {
                return error.forbidden_sample_rate;
            },
            else => {},
        }

        try crc_reader.bw.flushBits();

        // std.debug.print("crc8: {}, {b}\n", .{ hasher.final(), crc_reader.bw.bits });
        frame_header.crc = try reader.readInt(u8, .big);

        // CRC Check (return error if failed)
        if (hasher.final() != frame_header.crc) {
            return error.crc_mismatch;
        }

        return frame_header;
    }
};

pub const SubFrameHeader = union(enum) {
    constant,
    verbatim,
    fixed_predictor: u3,
    linear_predictor: u5,
};

pub const SubFrame = struct {
    header: SubFrameHeader,
    wasted_bits: u8,
    subblock: []i32,

    pub fn parseSubframe(br: *std.io.BitReader(.big, std.io.AnyReader), alloc: std.mem.Allocator, frame: FrameHeader, stream_info: ?StreamInfo) !SubFrame {
        var subframe: SubFrame = undefined;

        if (try br.readBitsNoEof(u1, 1) != 0) return error.missing_zero_bit;

        const header = try br.readBitsNoEof(u6, 6);
        subframe.header = switch (header) {
            0 => .constant,
            1 => .verbatim,
            0b000010...0b000111 => return error.using_reserved_value,
            0b001000...0b001100 => |x| SubFrameHeader{ .fixed_predictor = x - 8 },
            0b001101...0b011111 => return error.using_reserved_value,
            0b100000...0b111111 => |x| SubFrameHeader{ .linear_predictor = x - 31 },
        };

        subframe.wasted_bits = 0;
        if (try br.readBitsNoEof(u1, 1) == 1) {
            var num: u8 = 1;
            while (try br.readBitsNoEof(u1, 1) == 0) : (num += 1) {}
            subframe.wasted_bits = num;
        }

        const bit_depth = try frame.bit_depth.asIntMinusOne(stream_info);
        const offset_if_is_side_subframe: u1 = switch (frame.channel) {
            .left_side, .side_right, .mid_side => 1,
            else => 0,
        };
        const wasted = subframe.wasted_bits;

        const real_bit_depth: u16 = (bit_depth - wasted) + offset_if_is_side_subframe;

        subframe.subblock = switch (subframe.header) {
            .constant => [1]i32{try br.readBitsNoEof(i32, real_bit_depth)},
            .verbatim => blk: {
                var buf = try alloc.alloc(i32, frame.block_size);
                for (0..buf.len) |i| {
                    buf[i] = try br.readBitsNoEof(i32, real_bit_depth);
                }
                break :blk buf;
            },
            .fixed_predictor => |order| blk: {
                var buf = try alloc.alloc(i32, frame.block_size);

                //read warmup samples
                for (0..order) |i| {
                    buf[i] = try br.readBitsNoEof(i32, real_bit_depth);
                }

                break :blk buf;
            },
            // TODO: implement the rest
            else => @panic("TODO: impl others :)"),
        };

        return subframe;
    }
};

pub fn decodeNumber(reader: anytype) !u36 {
    var ret: u36 = 0;
    const first = try reader.readInt(u8, .big);

    var N: u3 = undefined;
    if (first & 0b1000_000 == 0) {
        // number with only one byte
        return first & 0b0111_1111;
    }

    var i: u3 = 2;
    while (i <= 7) : (i += 1) {
        // 2 shifts 5
        // 7 shifts 0
        const amt = 7 - i;

        // N=2 bytes
        // 0b0000_110 desired
        // N = 7 bytes
        // 0b1111_1110 desired
        const first_wanted: u8 = first >> amt;
        const desired: u8 = (@as(u8, 0b1111_1111) >> amt) - 1;
        if (first_wanted == desired) {
            N = i;
            break;
        }
    }

    // N = 3
    // byte 0 (we already know), byte 1, byte 2

    if (N != 7) {
        ret = first & (@as(u8, 0b1111_1111) >> (N + 1));
    }

    for (0..N - 1) |_| {
        ret <<= 6;
        ret |= (try reader.readInt(u8, .big) & 0b0011_1111);
    }

    return ret;
}

test "decodeNumber" {
    {
        var reader = std.io.fixedBufferStream(&[_]u8{
            0b11111110, 0b10111011, 0b10111110, 0b10111111, 0b10101111, 0b10111111, 0b10011111,
        });
        try std.testing.expectEqual(64407666655, try decodeNumber(reader.reader().any()));
    }

    {
        var reader = std.io.fixedBufferStream(&[_]u8{ 0xF0, 0x9F, 0xD2, 0xA9 });
        try std.testing.expectEqual(0x1_F4A9, try decodeNumber(reader.reader().any()));
    }

    {
        var reader = std.io.fixedBufferStream(&[_]u8{ 0xD0, 0x94 });
        try std.testing.expectEqual(0x414, try decodeNumber(reader.reader().any()));
    }

    {
        var reader = std.io.fixedBufferStream(&[_]u8{ 0b11111101, 0b10111011, 0b10101110, 0b10111011, 0b10101110, 0b10111111 });
        try std.testing.expectEqual(2075900863, try decodeNumber(reader.reader().any()));
    }
}

test "check crc" {
    try std.testing.expectEqual(0xe9, crc8.hash(&[_]u8{
        0xff,
        0xf8,
        0x68,
        0x02,
        0x00,
        0x17,
    }));
}
