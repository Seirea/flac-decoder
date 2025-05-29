// const std = @import("std");

// pub const WordType = usize;
// pub const MachineWBR = WordBitReader(WordType);

// pub fn WordBitReader(comptime WT: type) type {
//     return struct {
//         const BitWordSize = @bitSizeOf(WT);
//         const ByteWordSize = @sizeOf(WT);

//         const CountSize = std.meta.Int(.unsigned, std.math.log2(BitWordSize) + 1);

//         buf: WT,
//         count: CountSize,

//         reader: std.io.AnyReader,

//         // 0b0000000000
//         // Bytes fill in from the left
//         // Leaves from the right

//         pub fn init(reader: std.io.AnyReader) WordBitReader(WT) {
//             return .{
//                 .buf = 0,
//                 .count = 0,
//                 .reader = reader,
//             };
//         }

//         fn refillBits(self: *@This()) !void {
//             std.debug.print("{}->{X}\n", .{ self.count, self.buf });
//             const read = try self.reader.readByte();
//             self.buf <<= 8;
//             self.buf |= read;

//             self.count += 8;
//             std.debug.print("{}->{X}\n\n", .{ self.count, self.buf });
//         }

//         pub fn peekBits(self: *@This(), N: CountSize) !WT {
//             if (N > BitWordSize) {
//                 @panic("Cannot peek more than the word size");
//             }

//             while (self.count < N) {
//                 try self.refillBits();
//             }

//             // if (N == BitWordSize) {
//             //     return self.buf;
//             // } else {
//             // 0b1110_0000
//             // n = 3
//             //
//             std.debug.print("{X} >> {}\n", .{ self.buf, (self.count - N) });
//             return self.buf >> @intCast(self.count - N);
//             // }
//         }

//         pub fn alignToByte(self: *@This()) void {
//             const extraneous = self.count - ((self.count >> 3) << 3);
//             self.consumeBits(extraneous);
//         }

//         pub fn readBits(self: *@This(), N: CountSize) !WT {
//             const value = try self.peekBits(N);
//             self.consumeBits(N);

//             return value;
//         }

//         pub fn readUnary(self: *@This()) !u16 {
//             var out: u16 = 0;
//             while (true) {
//                 const next = try self.peekBits(64);

//                 const bits = if (next > 0) (@clz(next) + 1) else @bitSizeOf(WT);
//                 out += bits;
//                 self.consumeBits(bits);
//                 if (next > 0) {
//                     return out;
//                 }
//             }
//         }

//         pub fn consumeBits(self: *@This(), N: CountSize) void {
//             if (N > self.count) {
//                 @panic("Consumed more bits than was available");
//             }

//             // remove from main first

//             self.buf &= ((@as(WT, 1) << @intCast(self.count - N)) - 1);
//             self.count -= N;
//         }
//     };
// }

// // pub fn WordBitReader(comptime WT: type) type {
// //     return struct {
// //         const BitWordSize = @bitSizeOf(WT);
// //         const ByteWordSize = @sizeOf(WT);

// //         const CountSize = std.meta.Int(.unsigned, std.math.log2(BitWordSize) + 1);

// //         buf: WT,
// //         count: CountSize,

// //         reader: std.io.AnyReader,

// //         // 0b0000000000
// //         // Bytes fill in from the left
// //         // Leaves from the right

// //         pub fn init(reader: std.io.AnyReader) WordBitReader(WT) {
// //             return .{
// //                 .buf = 0,
// //                 .count = 0,
// //                 .reader = reader,
// //             };
// //         }

// //         fn refillBits(self: *@This()) !void {
// //             std.debug.print("{}->{X}\n", .{ self.count, self.buf });
// //             const read = try self.reader.readByte();
// //             self.buf <<= 8;
// //             self.buf |= read;

// //             self.count += 8;
// //             std.debug.print("{}->{X}\n\n", .{ self.count, self.buf });
// //         }

// //         pub fn peekBits(self: *@This(), N: CountSize) !WT {
// //             if (N > BitWordSize) {
// //                 @panic("Cannot peek more than the word size");
// //             }

// //             while (self.count < N) {
// //                 try self.refillBits();
// //             }

// //             // if (N == BitWordSize) {
// //             //     return self.buf;
// //             // } else {
// //             // 0b1110_0000
// //             // n = 3
// //             //
// //             std.debug.print("{X} >> {}\n", .{ self.buf, (self.count - N) });
// //             return self.buf >> @intCast(self.count - N);
// //             // }
// //         }

// //         pub fn alignToByte(self: *@This()) void {
// //             const extraneous = self.count - ((self.count >> 3) << 3);
// //             self.consumeBits(extraneous);
// //         }

// //         pub fn readBits(self: *@This(), N: CountSize) !WT {
// //             const value = try self.peekBits(N);
// //             self.consumeBits(N);

// //             return value;
// //         }

// //         pub fn readUnary(self: *@This()) !u16 {
// //             var out: u16 = 0;
// //             while (true) {
// //                 const next = try self.peekBits(64);

// //                 const bits = if (next > 0) (@clz(next) + 1) else @bitSizeOf(WT);
// //                 out += bits;
// //                 self.consumeBits(bits);
// //                 if (next > 0) {
// //                     return out;
// //                 }
// //             }
// //         }

// //         pub fn consumeBits(self: *@This(), N: CountSize) void {
// //             if (N > self.count) {
// //                 @panic("Consumed more bits than was available");
// //             }

// //             // remove from main first

// //             self.buf &= ((@as(WT, 1) << @intCast(self.count - N)) - 1);
// //             self.count -= N;
// //         }
// //     };
// // }

// // inline fn getLowerNBits(T: type, x: T, n: std.meta.Int(.unsigned, std.math.log2(@bitSizeOf(T)) + 1)) T {
// //     return x & ((@as(T, 1) << n) - 1);
// // }

// // pub fn WordBitReader(comptime WT: type) type {
// //     return struct {
// //         const BitWordSize = @bitSizeOf(WT);
// //         const ByteWordSize = @sizeOf(WT);

// //         const CountSize = std.meta.Int(.unsigned, std.math.log2(BitWordSize) + 1);

// //         buf: WT,
// //         count: CountSize,

// //         reader: std.io.AnyReader,
// //         spillover: u8,
// //         spillover_count: u4,

// //         // 0b0000000000
// //         // Bytes fill in from the left
// //         // Leaves from the right

// //         pub fn init(reader: std.io.AnyReader) WordBitReader(WT) {
// //             return .{
// //                 .buf = 0,
// //                 .count = 0,

// //                 .spillover = 0,
// //                 .spillover_count = 0,

// //                 .reader = reader,
// //             };
// //         }

// //         fn refillBits(self: *@This()) !void {
// //             const remaining_space_in_bits: u7 = BitWordSize - self.count;
// //             if (remaining_space_in_bits < 8) {
// //                 const rem_space: u3 = @truncate(remaining_space_in_bits);
// //                 const lower_mask: u8 = (@as(u8, 1) << rem_space) - 1;
// //                 const val = try self.reader.readByte();

// //                 self.buf |= (val & lower_mask) << @intCast(self.count);
// //                 self.spillover_count = @as(u4, 8) - rem_space;
// //                 self.spillover = (val & ~lower_mask) >> rem_space;
// //             } else {
// //                 self.buf |= (try self.reader.readByte()) << @intCast(self.count);
// //             }
// //         }

// //         pub fn peekBits(self: *@This(), N: CountSize) !WT {
// //             if (N > BitWordSize) {
// //                 @panic("Cannot peek more than the word size");
// //             }

// //             while (self.count < N) {
// //                 try self.refillBits();
// //             }

// //             if (N == BitWordSize) {
// //                 return self.buf;
// //             } else {
// //                 return self.buf & ((@as(WT, 1) << @intCast(N)) - 1);
// //             }
// //         }

// //         pub fn alignToByte(self: @This()) void {
// //             const extraneous = self.count - ((self.count >> 3) << 3);
// //             self.consumeBits(extraneous);
// //         }

// //         pub fn readBits(self: *@This(), N: CountSize) !WT {
// //             const value = try self.peekBits(N);
// //             self.consumeBits(N);

// //             return value;
// //         }

// //         pub fn consumeBits(self: *@This(), N: CountSize) void {
// //             if (N > self.count + self.spillover_count) {
// //                 @panic("Consumed more bits than was available");
// //             }

// //             // remove from main first

// //             const amount_to_remove_from_main = @min(self.count, N);
// //             const original_in_main = self.count;
// //             if (amount_to_remove_from_main == self.count) {
// //                 self.buf = 0;
// //                 self.count = 0;
// //             } else {
// //                 self.buf >>= @intCast(amount_to_remove_from_main);
// //                 self.count -= amount_to_remove_from_main;
// //             }

// //             self.buf |= (self.spillover & (@as(u8, 1) << N) - 1) << self.count;

// //             self.spillover >>=
// //             self.spillover_count -= (N - original_in_main);
// //         }
// //     };
// // }
