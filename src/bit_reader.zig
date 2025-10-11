const std = @import("std");

pub const WordType = usize;
pub const AnyBitReader = BitReader(.big, std.io.Reader);

// BIG ENDIAN FORMAT
// stream: 0xab, 0xcd, 0xef =>  0xabcdef

pub fn BitReader(endian: std.builtin.Endian) type {
    return struct {
        const CountType = std.meta.Int(.unsigned, std.math.log2(WordSizeInBits) + 1);
        const WordSizeInBits = @bitSizeOf(WordType);
        const Mask: WordType = ~@as(WordType, 0);

        reader: std.Io.Reader,
        buffer: WordType,
        consumed_bits: CountType = 0, // 0 <= consumed_bits < WordSizeInBits should hold!
        remaining_bits: CountType = 0,

        pub fn readBits(self: *@This(), T: type, bits: CountType) !T {
            const BitSize = @bitSizeOf(T);
            std.debug.assert(bits <= BitSize and BitSize <= WordSizeInBits);
            // check if we have ran out of words
            // if (self.reader.seek)
            if (self.reader.bufferedLen() < 2 * @sizeOf(WordType)) {
                @branchHint(.cold);
                // less than remaining bytes
                if (self.consumed_bits + bits > self.remaining_bits + self.reader.bufferedLen() * 8) {
                    return error.endOfStream;
                }
                var bit = bits;
                var res: T = 0;
                while (bit > 0) {
                    // read all remaining bits
                    if (bit >= 8) {
                        res <<= 8;
                        res |= try self.reader.takeInt(u8, endian);
                        bit -= 8;
                    } else {
                        res <<= bit;
                        const read = try self.reader.takeInt(u8, endian);
                        res |= read >> (8 - bit);

                        // self.remaining_bits =

                        // bit = 0;
                    }
                }
                return res;
            }
            if (self.consumed_bits > 0) {
                @branchHint(.likely);
                std.debug.assert(self.consumed_bits < WordSizeInBits);
                const remaining_bits: u6 = @intCast(WordSizeInBits - self.consumed_bits);
                const available_bits_mask = Mask >> @intCast(self.consumed_bits);
                if (bits < remaining_bits) {
                    @branchHint(.likely);
                    const res = (self.buffer & available_bits_mask) >> @intCast(remaining_bits - bits);
                    self.consumed_bits += bits;
                    return @intCast(res);
                } else {
                    // use up all of our remaining bits
                    var res = self.buffer & available_bits_mask;
                    const bits_after_remainder_used_up = bits - remaining_bits;

                    // load in our new Word
                    self.buffer = try self.reader.takeInt(WordType, endian);
                    self.consumed_bits = 0;

                    // check if there are still bits remaining
                    if (bits_after_remainder_used_up > 0) {
                        // there must be less than WordSize bits left
                        std.debug.assert(bits_after_remainder_used_up < WordSizeInBits);
                        // move all the old ones up
                        res <<= @intCast(bits_after_remainder_used_up);
                        res |= self.buffer >> @intCast(WordSizeInBits - bits_after_remainder_used_up);
                        self.consumed_bits = bits_after_remainder_used_up;
                    }
                    return @intCast(res);
                }
            } else {
                std.debug.assert(self.consumed_bits == 0);
                if (bits == 0) {
                    return 0;
                }
                // no bits consumed yet. fresh buffer
                if (bits < WordSizeInBits) {
                    const res: WordType = try self.reader.takeInt(WordType, endian);
                    self.buffer = res;
                    self.consumed_bits = bits;
                    return @intCast(res >> @intCast(WordSizeInBits - bits));
                } else {
                    std.debug.assert(bits == BitSize and BitSize == WordSizeInBits);

                    const res: WordType = try self.reader.takeInt(WordType, endian);
                    return @intCast(res);
                }
            }
        }
    };
}

pub fn bitReader(comptime endian: std.builtin.Endian, reader: std.Io.Reader) BitReader(endian) {
    return BitReader(endian){
        .reader = reader,
        .buffer = undefined,
    };
}
// pub fn customBitReader(comptime endian: std.builtin.Endian, comptime Word: type, reader: anytype) BitReader(endian, Word, @TypeOf(reader)) {
//     return .{ .reader = reader };
// }

///////////////////////////////

test "api coverage" {
    const mem_be = [_]u8{ 0b11001101, 0b00001011 };
    const mem_le = [_]u8{ 0b00011101, 0b10010101 };

    var mem_in_be = std.Io.Reader.fixed(&mem_be);
    var bit_stream_be = bitReader(.big, mem_in_be);

    // const expect = std.testing.expect;
    const eq = std.testing.expectEqual;
    const expectError = std.testing.expectError;

    try eq(1, try bit_stream_be.readBits(u2, 1));
    try eq(2, try bit_stream_be.readBits(u5, 2));
    try eq(3, try bit_stream_be.readBits(u128, 3));
    try eq(4, try bit_stream_be.readBits(u8, 4));
    try eq(5, try bit_stream_be.readBits(u9, 5));
    try eq(1, try bit_stream_be.readBits(u1, 1));

    mem_in_be.seek = 0;
    try eq(0b110011010000101, try bit_stream_be.readBits(u15, 15));

    mem_in_be.seek = 0;
    try eq(0b1100110100001011, try bit_stream_be.readBits(u16, 16));

    _ = try bit_stream_be.readBits(u0, 0);

    try eq(0, try bit_stream_be.readBits(u1, 1));
    try expectError(error.EndOfStream, bit_stream_be.readBits(u1, 1));

    var mem_in_le = std.Io.Reader.fixed(&mem_le);
    var bit_stream_le = bitReader(.little, mem_in_le);

    try eq(1, try bit_stream_le.readBits(u2, 1));
    try eq(2, try bit_stream_le.readBits(u5, 2));
    try eq(3, try bit_stream_le.readBits(u128, 3));
    try eq(4, try bit_stream_le.readBits(u8, 4));
    try eq(5, try bit_stream_le.readBits(u9, 5));
    try eq(1, try bit_stream_le.readBits(u1, 1));

    mem_in_le.seek = 0;
    try eq(0b001010100011101, try bit_stream_le.readBits(u15, 15));

    mem_in_le.seek = 0;
    try eq(0b1001010100011101, try bit_stream_le.readBits(u16, 16));

    _ = try bit_stream_le.readBits(u0, 0);

    try eq(0, try bit_stream_le.readBits(u1, 1));
    try expectError(error.EndOfStream, bit_stream_le.readBits(u1, 1));
}
