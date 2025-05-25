const std = @import("std");

pub fn shortenIntToTwosComplementIntOfSetBits(comptime T: type, val: T, bit_size: u16) T {
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

pub fn readTwosComplementIntegerOfSetBits(br: anytype, comptime T: type, bit_count: u16) !T {
    return shortenIntToTwosComplementIntOfSetBits(
        T,
        try br.readBitsNoEof(T, bit_count),
        bit_count,
    );
}
