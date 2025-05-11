const std = @import("std");

const ParsingBlockSize = enum(u4) {
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
const ParsingSampleRate = enum(u4) {
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

const ParsingChannel = enum(u4) {
    mono = 0,
    stero,
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

const ParsingBitDepth = enum(u3) {
    in_streaminfo = 0b000,
    @"8-bit" = 0b001,
    @"12-bit" = 0b010,
    reserved = 0b011,
    @"16-bit" = 0b100,
    @"20-bit" = 0b101,
    @"24-bit" = 0b110,
    @"32-bit" = 0b111,
};

const ParsingFrameHeader = packed struct {
    _sync_code: u15 = 0b111111111111100,
    blocking_strategy: bool, // 0 is fixed block size, 1 is variable
    block_size_1: ParsingBlockSize, // wtf
    sample_rate: ParsingSampleRate,
    channel: ParsingChannel,
    bit_depth: ParsingBitDepth,
    _reserved_bit: u1 = 0,
};

pub fn decodeNumber(reader: std.io.AnyReader) !u36 {
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

const SubFrame = struct {};
