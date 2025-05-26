const std = @import("std");

pub const WordType = usize;
pub const AnyCustomBitReader = CustomBitReader(.big, WordType, std.io.AnyReader);

/// Bit Reader with custom word (buffer) size
/// Not tested with Little Endian
pub fn CustomBitReader(comptime endian: std.builtin.Endian, comptime Word: type, comptime Reader: type) type {
    return struct {
        const CountType = std.meta.Int(.unsigned, std.math.log2(WordSizeInBits) + 1);
        const WordSizeInBits = @bitSizeOf(Word);
        reader: Reader,
        bits: Word = 0,
        count: CountType = 0,

        // generate a low_bit_mask at comptime based on our custom Word size
        const low_bit_mask = blk: {
            var x: [WordSizeInBits + 1]Word = undefined;
            for (0..WordSizeInBits) |i| {
                x[i] = (@as(Word, 1) << i) - 1;
            }
            x[WordSizeInBits] = ~@as(Word, 0);

            // @compileLog(std.fmt.comptimePrint("{b}\n", .{x}));
            break :blk x;
        };

        fn Bits(comptime T: type) type {
            return struct {
                T,
                u16,
            };
        }

        fn initBits(comptime T: type, out: anytype, num: u16) Bits(T) {
            const UT = std.meta.Int(.unsigned, @bitSizeOf(T));
            return .{
                @bitCast(@as(UT, @intCast(out))),
                num,
            };
        }

        /// Reads `bits` bits from the reader and returns a specified type
        ///  containing them in the least significant end, returning an error if the
        ///  specified number of bits could not be read.
        pub fn readBitsNoEof(self: *@This(), comptime T: type, num: u16) !T {
            const b, const c = try self.readBitsTuple(T, num);
            // if (num != c) {
            //     std.debug.print("\n\nstate before:{}\n", .{self});
            // std.debug.print("wanted: {} | got: {} \nstate:{}\n\n", .{ num, c, self });
            // }
            if (c < num) return error.EndOfStream;

            // std.debug.print("read bits: {X}\n", .{b});
            return b;
        }

        /// Reads `bits` bits from the reader and returns a specified type
        ///  containing them in the least significant end. The number of bits successfully
        ///  read is placed in `out_bits`, as reaching the end of the stream is not an error.
        pub fn readBits(self: *@This(), comptime T: type, num: u16, out_bits: *u16) !T {
            const b, const c = try self.readBitsTuple(T, num);
            out_bits.* = c;
            return b;
        }

        pub fn readInt(self: *@This(), comptime T: type) anyerror!T {
            // std.debug.print("reading int\n", .{});
            return self.readBitsNoEof(T, @bitSizeOf(T));
        }

        pub fn readUnary(self: *@This()) !u32 {
            // check if what we have in the buffer already is unary
            const extraneous_bits = WordSizeInBits - self.count;
            var leading_zeroes = if (self.count != 0) @clz(self.bits << @intCast(extraneous_bits)) else self.count;

            if (leading_zeroes < self.count) {
                // inspected unary already in buffer
                _ = self.removeBits(leading_zeroes + 1);
                return leading_zeroes;
            } else {
                // inspected more than in buffer, so we need to continue looking
                leading_zeroes = self.count;

                // clean out our internal buffer
                self.bits = 0;
                self.count = 0;

                var ob: [@sizeOf(Word)]u8 = undefined;
                while (true) {
                    // const next = try self.readBitsTuple(Word, @bitSizeOf(Word));

                    // get next Word from stream
                    const read_from_stream = try self.reader.readAll(&ob);

                    // there is nothing left in the stream
                    if (read_from_stream == 0) {
                        return leading_zeroes;
                    }

                    const new_count = read_from_stream * 8;
                    const extraneous_bits_from_reader: u6 = @intCast(WordSizeInBits - new_count);
                    const final_bits = std.mem.readInt(Word, &ob, .big) >> @intCast(extraneous_bits_from_reader);
                    const leading_zeroes_now = @clz(final_bits << extraneous_bits_from_reader);

                    leading_zeroes += leading_zeroes_now;
                    // leading_zeroes += leading_zeroes_in_fresh;
                    if (leading_zeroes_now < new_count) {
                        // we stopped
                        self.count = @intCast(new_count - (leading_zeroes_now + 1));
                        self.bits = final_bits & low_bit_mask[self.count];
                        return leading_zeroes;
                    }
                }
            }
        }

        // pub fn read(self: *@This(), buf: []u8) !usize {
        //     for (0..buf.len) |i| {
        //         buf[i] = try self.readByte();
        //         std.debug.print("CBR read => buf[{}]={X} | self={}\n", .{ i, buf[i], self });
        //     }
        //     return buf.len;
        //     // const number_of_bits_to_get: CountType = @intCast(buf.len << 3); // buf.len * 8;
        //     // if (number_of_bits_to_get <= self.count) {
        //     //     const removed = self.removeBits(number_of_bits_to_get);
        //     //     for (0..buf.len) |i| {
        //     //         buf[i] = @truncate((removed >> @intCast(8 * (buf.len - i - 1))) & (0b1111_1111));
        //     //     }
        //     //     return buf.len;
        //     // } else {
        //     //     // @panic("not implemented");
        //     //     // remove everything we can, then keep adding
        //     //     const clean_bytes_extracted = self.count >> 3;
        //     //     const number_of_dirty_bits = self.count - (clean_bytes_extracted << 3);
        //     //     const removed = self.removeBits(self.count);

        //     //     const removed_clean = removed >> number_of_dirty_bits;
        //     //     const removed_dirty = removed & low_bit_mask[number_of_dirty_bits];

        //     //     for (0..clean_bytes_extracted) |i| {
        //     //         buf[i] = (removed_clean >> 8 * (clean_bytes_extracted - i - 1)) & (0b1111_1111);
        //     //     }

        //     //     const bytes_remaining = buf.len - clean_bytes_extracted;

        //     //     // do the next byte (will be dirty)
        //     //     const dirty_final: u8 = (removed_dirty << (8 - number_of_dirty_bits)) | self.readBitsNoEof(u8, 8 - number_of_dirty_bits);
        //     //     buf[clean_bytes_extracted] = dirty_final;

        //     //     const remaining_bytes = clean_bytes_extracted - 1;
        //     //     for (clean_bytes_extract + 1..buf.len) |_| {}

        //     //     // put in the rest of the bytes we have
        //     //     const left_over = self.count;
        //     //     const remaining = self.count; // we removed number_of_bits_to_get

        //     // }
        // }

        /// Reads `bits` bits from the reader and returns a tuple of the specified type
        ///  containing them in the least significant end, and the number of bits successfully
        ///  read. Reaching the end of the stream is not an error.
        pub fn readBitsTuple(self: *@This(), comptime T: type, num: u16) !Bits(T) {
            const UT = std.meta.Int(.unsigned, @bitSizeOf(T));
            const U = if (@bitSizeOf(T) < WordSizeInBits) Word else UT; //it is a pain to work with <u8

            //dump any bits in our buffer first
            if (num <= self.count) return initBits(T, self.removeBits(@intCast(num)), num);

            var out_count: u16 = self.count;
            var out: U = self.removeBits(self.count);

            //grab all the full bytes we need and put their
            //bits where they belong

            const full_words_left = (num - out_count) / WordSizeInBits;

            for (0..full_words_left) |_| {
                const word = self.reader.readInt(Word, .big) catch |err| switch (err) {
                    error.EndOfStream => return initBits(T, out, out_count),
                    else => |e| return e,
                };

                switch (endian) {
                    .big => {
                        // TODO: revise this
                        if (U == Word) out = 0 else out <<= WordSizeInBits; //shifting u8 by 8 is illegal in Zig
                        out |= word;
                    },
                    .little => {
                        const pos = @as(U, word) << @intCast(out_count);
                        out |= pos;
                    },
                }
                out_count += WordSizeInBits;
            }

            const bits_left = num - out_count;

            if (bits_left == 0) return initBits(T, out, out_count);

            // the remainder will be some integer smaller than Word
            var ob: [@sizeOf(Word)]u8 = undefined;

            // the bytes in the stream are now in ob
            // try self.reader.readNoEof(&ob);
            const read_from_stream = try self.reader.readAll(&ob);

            // no more bytes left in the stream
            if (read_from_stream == 0) {
                return initBits(T, out, out_count);
            }

            // std.debug.print("bits_left: {} | read: {}\n", .{ bits_left, read_from_stream });
            const keep = WordSizeInBits - bits_left;

            // std.debug.print("read from stream: {}\n", .{read_from_stream});

            const final_word = std.mem.readInt(Word, &ob, .big);
            // std.debug.print("final word: {X}\n", .{final_word});
            // const final_word = std.mem.readInt(Word, @ptrCast(ob[0..read_from_stream]), .big);

            // const final_word = self.reader.readInt(Word, .big) catch |err| switch (err) {
            //     error.EndOfStream => return initBits(T, out, out_count),
            //     else => |e| return e,
            // };

            const extraneous_bits = WordSizeInBits - 8 * read_from_stream;

            switch (endian) {
                .big => {
                    // put the uppermost bits_left bits of final_word into out
                    out <<= @intCast(bits_left);
                    out |= final_word >> @intCast(keep);
                    //
                    self.bits = (final_word & low_bit_mask[keep]) >> @intCast(extraneous_bits);
                },
                .little => {
                    @compileError("Little endian CustomBitReader is not implemented");
                    // const pos = @as(U, final_word & low_bit_mask[bits_left]) << @intCast(out_count);
                    // out |= pos;
                    // self.bits = final_word >> @intCast(bits_left);
                },
            }

            self.count = @intCast(keep - extraneous_bits);
            return initBits(T, out, num);
        }

        //convenience function for removing bits from
        //the appropriate part of the buffer based on
        //endianess.
        fn removeBits(self: *@This(), num: CountType) Word {
            if (num == WordSizeInBits) {
                self.count = 0;
                return self.bits;
            }

            const keep = self.count - num;
            const bits = switch (endian) {
                .big => self.bits >> @intCast(keep),
                .little => self.bits & low_bit_mask[num],
            };
            switch (endian) {
                .big => self.bits &= low_bit_mask[keep],
                .little => self.bits >>= @intCast(num),
            }

            self.count = keep;
            return bits;
        }

        pub fn alignToByte(self: *@This()) void {
            // std.debug.print("{}\n", .{self});
            // self.bits = 0;
            // self.count = 0;
            const byte_amount = self.count >> 3;
            const destroy_bits = self.count - (byte_amount << 3);
            // std.debug.print("destroy_bits: {}\n", .{destroy_bits});
            _ = self.removeBits(destroy_bits);
            // self.bits = self.bits << @intCast(destroy_bits);
            // self.count = self.count - destroy_bits;
        }
    };
}

pub fn customBitReader(comptime endian: std.builtin.Endian, comptime Word: type, reader: anytype) CustomBitReader(endian, Word, @TypeOf(reader)) {
    return .{ .reader = reader };
}

///////////////////////////////

test "api coverage" {
    const mem_be = [_]u8{ 0b11001101, 0b00001011 };
    const mem_le = [_]u8{ 0b00011101, 0b10010101 };

    var mem_in_be = std.io.fixedBufferStream(&mem_be);
    var bit_stream_be = customBitReader(.big, u8, mem_in_be.reader());

    var out_bits: u16 = undefined;

    const expect = std.testing.expect;
    const expectError = std.testing.expectError;

    try expect(1 == try bit_stream_be.readBits(u2, 1, &out_bits));
    try expect(out_bits == 1);
    try expect(2 == try bit_stream_be.readBits(u5, 2, &out_bits));
    try expect(out_bits == 2);
    try expect(3 == try bit_stream_be.readBits(u128, 3, &out_bits));
    try expect(out_bits == 3);
    try expect(4 == try bit_stream_be.readBits(u8, 4, &out_bits));
    try expect(out_bits == 4);
    try expect(5 == try bit_stream_be.readBits(u9, 5, &out_bits));
    try expect(out_bits == 5);
    try expect(1 == try bit_stream_be.readBits(u1, 1, &out_bits));
    try expect(out_bits == 1);

    mem_in_be.pos = 0;
    bit_stream_be.count = 0;
    try expect(0b110011010000101 == try bit_stream_be.readBits(u15, 15, &out_bits));
    try expect(out_bits == 15);

    mem_in_be.pos = 0;
    bit_stream_be.count = 0;
    try expect(0b1100110100001011 == try bit_stream_be.readBits(u16, 16, &out_bits));
    try expect(out_bits == 16);

    _ = try bit_stream_be.readBits(u0, 0, &out_bits);

    try expect(0 == try bit_stream_be.readBits(u1, 1, &out_bits));
    try expect(out_bits == 0);
    try expectError(error.EndOfStream, bit_stream_be.readBitsNoEof(u1, 1));

    var mem_in_le = std.io.fixedBufferStream(&mem_le);
    var bit_stream_le = customBitReader(.little, u8, mem_in_le.reader());

    try expect(1 == try bit_stream_le.readBits(u2, 1, &out_bits));
    try expect(out_bits == 1);
    try expect(2 == try bit_stream_le.readBits(u5, 2, &out_bits));
    try expect(out_bits == 2);
    try expect(3 == try bit_stream_le.readBits(u128, 3, &out_bits));
    try expect(out_bits == 3);
    try expect(4 == try bit_stream_le.readBits(u8, 4, &out_bits));
    try expect(out_bits == 4);
    try expect(5 == try bit_stream_le.readBits(u9, 5, &out_bits));
    try expect(out_bits == 5);
    try expect(1 == try bit_stream_le.readBits(u1, 1, &out_bits));
    try expect(out_bits == 1);

    mem_in_le.pos = 0;
    bit_stream_le.count = 0;
    try expect(0b001010100011101 == try bit_stream_le.readBits(u15, 15, &out_bits));
    try expect(out_bits == 15);

    mem_in_le.pos = 0;
    bit_stream_le.count = 0;
    try expect(0b1001010100011101 == try bit_stream_le.readBits(u16, 16, &out_bits));
    try expect(out_bits == 16);

    _ = try bit_stream_le.readBits(u0, 0, &out_bits);

    try expect(0 == try bit_stream_le.readBits(u1, 1, &out_bits));
    try expect(out_bits == 0);
    try expectError(error.EndOfStream, bit_stream_le.readBitsNoEof(u1, 1));
}
