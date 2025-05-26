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
