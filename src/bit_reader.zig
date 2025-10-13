const std = @import("std");

pub const WordType = usize;
pub const AnyBitReader = BitReader(.big);

// BIG ENDIAN FORMAT
// stream: 0xab, 0xcd, 0xef =>  0xabcdef

// this is slow, but should not be used often
// BIG ENDIAN ONLY
fn intFromSlice(T: type, s: []u8) T {
    var res: T = 0;

    var bytes_used: usize = 0;
    for (s) |byte| {
        res <<= 8;
        res |= byte;
        bytes_used += 1;
    }

    for (0..(@sizeOf(T) - bytes_used)) |_| {
        res <<= 8;
    }

    return res;
}

pub fn BitReader(endian: std.builtin.Endian) type {
    return struct {
        const CountType = std.meta.Int(.unsigned, std.math.log2(WordSizeInBits) + 1);
        const WordSizeInBits = @bitSizeOf(WordType);
        const Mask: WordType = ~@as(WordType, 0);

        reader: *std.Io.Reader,
        consumed_bits: CountType = 0, // 0 <= consumed_bits < WordSizeInBits should hold!

        pub fn discardBits(self: *@This(), n: WordType) !void {
            if (n < WordSizeInBits - self.consumed_bits) {
                self.consumed_bits += @intCast(n);
            } else {
                const remaining = n - (WordSizeInBits - self.consumed_bits);

                const remaining_bytes = remaining / 8;
                const leftover_bits: u3 = @intCast(remaining - remaining_bytes * 8);

                try self.reader.discardAll(1 + remaining_bytes);
                self.consumed_bits = leftover_bits;
            }
        }

        pub fn readUnary(self: *@This()) !WordType {
            std.debug.assert(0 <= self.consumed_bits and self.consumed_bits < WordSizeInBits);
            if (self.reader.bufferedLen() < @sizeOf(WordType)) {
                @branchHint(.cold);

                const remaining: WordType = intFromSlice(WordType, try self.reader.peek(self.reader.bufferedLen()));
                // const remaining: WordType = @intCast(try self.reader.peekArray(self.reader.bufferedLen()));
                const res = @clz(remaining << @intCast(self.consumed_bits));
                if (res == WordSizeInBits) {
                    return error.EndOfStream;
                }

                self.consumed_bits += res + 1;
                return res;
            }

            const next = try self.reader.peekInt(WordType, endian) << @intCast(self.consumed_bits);
            const lz = @clz(next);

            if (lz < WordSizeInBits) {
                @branchHint(.likely);
                // we found a 1
                self.consumed_bits += lz + 1;
                if (self.consumed_bits == WordSizeInBits) {
                    self.reader.toss(@sizeOf(WordType));
                    self.consumed_bits = 0;
                }

                return lz;
            } else {
                // no 1's
                self.reader.toss(@sizeOf(WordType));
                var res: WordType = WordSizeInBits - self.consumed_bits;
                while (true) {
                    const leading = @clz(try self.reader.peekInt(WordType, endian));
                    if (leading < WordSizeInBits) {
                        res += leading;
                        self.consumed_bits = leading + 1;

                        if (self.consumed_bits == WordSizeInBits) {
                            self.reader.toss(@sizeOf(WordType));
                            self.consumed_bits = 0;
                        }

                        return res;
                    } else {
                        res += WordSizeInBits;
                        self.reader.toss(@sizeOf(WordType));
                    }
                }
            }
        }

        pub fn readBigBits(self: *@This(), T: type, bits: WordType) !T {
            const ResultSize = @bitSizeOf(T);
            std.debug.assert(WordSizeInBits <= bits and bits <= ResultSize);

            var res: T = 0;
            var bit_tracker = bits;
            while (bit_tracker > 0) {
                res <<= @bitSizeOf(WordType);
                res |= try self.readBits(WordType, if (bits >= WordSizeInBits) WordSizeInBits else @intCast(bits));
                bit_tracker -= @min(WordSizeInBits, bit_tracker);
            }
            return res;
        }

        // TODO: this should be inlineable/comptimable
        pub fn readBits(self: *@This(), T: type, bits: CountType) !T {
            const ResultSize = @bitSizeOf(T);
            std.debug.assert(bits <= ResultSize and ResultSize <= WordSizeInBits);

            if (bits == 0) {
                @branchHint(.cold);
                return 0;
            }

            std.debug.assert(bits > 0);

            if (self.reader.bufferedLen() < @sizeOf(WordType)) {
                @branchHint(.cold);
                if (self.consumed_bits + bits > self.reader.bufferedLen() * 8) {
                    return error.EndOfStream;
                }

                const remaining: WordType = intFromSlice(WordType, try self.reader.peek(self.reader.bufferedLen()));
                // const remaining: WordType = @intCast(try self.reader.peekArray(self.reader.bufferedLen()));
                const res = (remaining & (Mask >> @intCast(self.consumed_bits))) >> @intCast(WordSizeInBits - self.consumed_bits - bits);
                self.consumed_bits += bits;
                return @intCast(res);
            }

            // check if we have ran out of words
            // if (self.reader.seek)
            if (self.consumed_bits > 0) {
                @branchHint(.likely);
                std.debug.assert(self.consumed_bits < WordSizeInBits);

                const remaining_bits: u6 = @intCast(WordSizeInBits - self.consumed_bits);
                const available_bits_mask = Mask >> @intCast(self.consumed_bits);
                if (bits < remaining_bits) {
                    @branchHint(.likely);
                    const res = (try self.reader.peekInt(WordType, endian) & available_bits_mask) >> @intCast(remaining_bits - bits);
                    self.consumed_bits += bits;
                    return @intCast(res);
                } else {
                    // use up all of our remaining bits, discarding the old word in the process
                    var res = try self.reader.takeInt(WordType, endian) & available_bits_mask;
                    self.consumed_bits = 0;

                    // bits left over
                    const bits_after_remainder_used_up = bits - remaining_bits;

                    // check if there are still bits remaining
                    if (bits_after_remainder_used_up > 0) {
                        // there must be less than WordSize bits left
                        std.debug.assert(bits_after_remainder_used_up < WordSizeInBits);
                        // move all the old ones up
                        res <<= @intCast(bits_after_remainder_used_up);
                        // from the new word, read it up
                        res |= try self.reader.peekInt(WordType, endian) >> @intCast(WordSizeInBits - bits_after_remainder_used_up);
                        self.consumed_bits = bits_after_remainder_used_up;
                    }
                    return @intCast(res);
                }
            } else {
                // no bits consumed yet. fresh buffer
                std.debug.assert(self.consumed_bits == 0);

                if (bits < WordSizeInBits) {
                    const res: WordType = try self.reader.peekInt(WordType, endian);
                    self.consumed_bits = bits;
                    return @intCast(res >> @intCast(WordSizeInBits - bits));
                } else {
                    std.debug.assert(bits == ResultSize and ResultSize == WordSizeInBits);

                    const res: WordType = try self.reader.takeInt(WordType, endian);
                    return @intCast(res);
                }
            }
        }
    };
}

pub fn bitReader(comptime endian: std.builtin.Endian, reader: *std.Io.Reader) BitReader(endian) {
    return BitReader(endian){
        .reader = reader,
    };
}
// pub fn customBitReader(comptime endian: std.builtin.Endian, comptime Word: type, reader: anytype) BitReader(endian, Word, @TypeOf(reader)) {
//     return .{ .reader = reader };
// }

///////////////////////////////

test "api coverage" {
    const mem_be = [_]u8{ 0b11001101, 0b00001011 };

    var mem_in_be = std.Io.Reader.fixed(&mem_be);
    var bit_stream_be = bitReader(.big, mem_in_be);

    // const expect = std.testing.expect;
    const eq = std.testing.expectEqual;
    const expectError = std.testing.expectError;

    try eq(1, try bit_stream_be.readBits(u2, 1));
    try eq(2, try bit_stream_be.readBits(u5, 2));
    try eq(3, try bit_stream_be.readBits(u3, 3));
    try eq(4, try bit_stream_be.readBits(u8, 4));
    try eq(5, try bit_stream_be.readBits(u9, 5));
    try eq(1, try bit_stream_be.readBits(u1, 1));

    mem_in_be.seek = 0;
    bit_stream_be.consumed_bits = 0;
    try eq(0b110011010000101, try bit_stream_be.readBits(u15, 15));

    mem_in_be.seek = 0;
    bit_stream_be.consumed_bits = 0;
    try eq(0b1100110100001011, try bit_stream_be.readBits(u16, 16));

    _ = try bit_stream_be.readBits(u0, 0);

    try expectError(error.EndOfStream, bit_stream_be.readBits(u1, 1));
}

test "bitreader" {
    var mem_be: [16384]u8 = undefined;

    var rand = std.Random.DefaultPrng.init(12345);
    rand.fill(&mem_be);

    const reader = std.Io.Reader.fixed(&mem_be);
    var br = bitReader(.big, reader);

    var cur: usize = 0;
    while (br.readBits(u8, 8)) |x| {
        try std.testing.expectEqual(mem_be[cur], x);
        cur += 1;
    } else |_| {}
}

test "bitreader2" {
    var mem_be: [67]u8 = undefined;

    var rand = std.Random.DefaultPrng.init(12345);
    rand.fill(&mem_be);

    const reader = std.Io.Reader.fixed(&mem_be);
    var br = bitReader(.big, reader);

    var cur: usize = 0;
    while (br.readBits(u8, 8)) |x| {
        try std.testing.expectEqual(mem_be[cur], x);
        cur += 1;
    } else |_| {}
}

test "read_unary" {
    const mem_be = [_]u8{ 0b1010_0100, 0b1000_0000, 0b0010_0000, 0b0000_0000, 0b0000_1010 };

    const mem_in_be = std.Io.Reader.fixed(&mem_be);
    var bit_stream_be = bitReader(.big, mem_in_be);

    const eq = std.testing.expectEqual;

    try eq(0, try bit_stream_be.readUnary());
    try eq(1, try bit_stream_be.readUnary());
    try eq(2, bit_stream_be.readUnary());

    // The ending one is after the first byte boundary.
    try eq(2, try bit_stream_be.readUnary());

    try eq(9, try bit_stream_be.readUnary());

    // This one skips a full byte of zeros.
    try eq(17, try bit_stream_be.readUnary());

    // Verify that the ending position is still correct.
    try eq(0b010, try bit_stream_be.readBits(u3, 3));
    try std.testing.expectError(error.EndOfStream, bit_stream_be.readBits(u1, 1));
}

test "read_unary_2" {
    var mem_be: [64]u8 = undefined;

    @memset(mem_be[0..64], 0);
    mem_be[63] = 1;

    const mem_in_be = std.Io.Reader.fixed(&mem_be);
    var bit_stream_be = bitReader(.big, mem_in_be);

    try std.testing.expectEqual(8 * 63 + 7, try bit_stream_be.readUnary());
}

test "read_unary_3" {
    var mem_be: [8192]u8 = undefined;

    @memset(mem_be[0..8192], 0);
    mem_be[8191] = 1;

    const mem_in_be = std.Io.Reader.fixed(&mem_be);
    var bit_stream_be = bitReader(.big, mem_in_be);

    try std.testing.expectEqual(8 * 8191 + 7, try bit_stream_be.readUnary());
}

test "read_unary_4" {
    var mem_be: [8192]u8 = undefined;

    @memset(mem_be[0..8192], 0);
    mem_be[8191] = 0b10010001;

    const mem_in_be = std.Io.Reader.fixed(&mem_be);
    var bit_stream_be = bitReader(.big, mem_in_be);

    try std.testing.expectEqual(8 * 8191, try bit_stream_be.readUnary());
    try std.testing.expectEqual(2, try bit_stream_be.readUnary());
    try std.testing.expectEqual(3, try bit_stream_be.readUnary());
}
