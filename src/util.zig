const std = @import("std");

pub fn shortenIntToTwosComplementIntOfSetBits(comptime T: type, val: T, bit_size: u16) T {
    const uppermost: T = @as(T, 1) << @intCast(bit_size - 1);
    return (val & (uppermost - 1)) - (val & uppermost);
}

pub fn readTwosComplementIntegerOfSetBits(br: anytype, comptime T: type, bit_count: u16) !T {
    return shortenIntToTwosComplementIntOfSetBits(
        T,
        try br.readBitsNoEof(T, bit_count),
        bit_count,
    );
}
