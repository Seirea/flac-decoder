const std = @import("std");
const cbr = @import("custom_bit_reader.zig");
const frame = @import("frame/frame.zig");

pub fn signExtendFromDynamicBitWidth(comptime T: type, val: T, bit_size: u16) T {
    const uppermost: T = @as(T, 1) << @intCast(bit_size - 1);
    // 0000101
    // -4 + 1 => -3
    // 1111101
    // -16 + 8 + 4 + 1 = -3

    // uppermost
    // 100
    // (1 << bs) - 1 111
    // 00101 ^ 100 - 100 => 00001

    // 0000 1101 (-3)
    // 1111 1101

    // uppermost = 0000 1000
    // val ^ uppermost = 0000 0101
    // - uppermost = 0101
    // 1111 0111
    // 1111 1000

    // uppermost =
    return (val ^ uppermost) - uppermost;
}

pub fn readTwosComplementIntegerOfSetBits(br: frame.ReaderToCRCWriter, comptime T: type, bit_count: u16) !T {
    return signExtendFromDynamicBitWidth(
        T,
        try br.readBitsNoEof(T, bit_count),
        bit_count,
    );
}

// Bitreader remove bits (big endian)
// bits => 00101010
// count = 6
// remove(5)
// keep = 1
// bits -> 00010101 &= [1]
// -> 1
// self.count = 1
// return 1
pub const AnyBitReader = std.io.BitReader(.big, std.io.AnyReader);

pub inline fn getLowerNBits(x: u8, n: u3) u8 {
    return x & ((@as(u8, 1) << n) - 1);
}

pub fn removeBits(self: *AnyBitReader, num: u4) u8 {
    if (num == 8) {
        self.count = 0;
        return self.bits;
    }

    // std.debug.print("keep = {} - {}\n", .{ self.count, num });
    const keep = self.count - num;
    // force big endian
    const bits = self.bits >> @intCast(keep);
    // self.bits &= low_bit_mask[keep];
    // self.bits &= (@as(u8, 1) << @intCast(keep)) - 1;
    self.bits = getLowerNBits(self.bits, @intCast(keep));

    self.count = keep;
    return bits;
}

pub fn readUnary(br: *AnyBitReader) !u32 {
    // check our internal first
    var n: u32 = @clz(br.bits << @truncate(8 - br.count));

    // std.debug.print("{} < {}\n", .{ n, br.count });
    if (n < br.count) {
        // we can just use what we already have
        _ = removeBits(br, @as(u4, @intCast(n + 1)));
    } else {
        n = br.count;

        while (true) {
            const fresh_byte = try br.reader.readByte();
            const zeroes = @clz(fresh_byte);
            n += zeroes;
            if (zeroes < 8) {
                // We consumed the zeros, plus the one following it.
                br.count = 8 - (zeroes + 1);
                // 0 < br.count < 7
                br.bits = getLowerNBits(fresh_byte, @intCast(br.count));
                break;
            }
        }
    }

    return n;
}

// pub fn readUnary(br: *cbr.CustomBitReader(.big, frame.Word, std.io.AnyReader)) !frame.Word {
//     var ret: frame.Word = 0;
//     while (true) {
//         const bits_read = try br.readBitsTuple(frame.Word, @bitSizeOf(frame.Word));
//         const lz = @clz(bits_read.@"0");
//         if (bits_read.@"0" > 0) {
//             // we read something
//             //
//             ret += lz;
//             return ret;
//         } else {
//             // we must keep reading
//             ret += @bitSizeOf(frame.Word);
//         }
//     }
// }
