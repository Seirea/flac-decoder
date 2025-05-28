const std = @import("std");
const rice = @import("../rice.zig");
const util = @import("../util.zig");
const StreamInfo = @import("../metadata/block.zig").StreamInfo;
const tracy = @import("tracy");

const cbr = @import("../custom_bit_reader.zig");

const crc8 = std.hash.crc.Crc(u8, .{
    .polynomial = 0x07,
    .initial = 0x00,
    .reflect_input = false,
    .reflect_output = false,
    .xor_output = 0x0,
});

const crc16 = std.hash.crc.Crc(u16, .{
    .polynomial = 0x8005,
    .initial = 0,
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
    crc_frame_header_mismatch,
    crc_frame_footer_mismatch,
    forbidden_fixed_predictor_order,
    negative_lpc_shift,
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
    mono = 0b0000,
    stereo = 0b0001,
    three = 0b0010,
    four = 0b0011,
    five = 0b0100,
    six = 0b0101,
    seven = 0b0110,
    eight = 0b0111,
    left_side = 0b1000,
    side_right = 0b1001,
    mid_side = 0b1010,

    pub fn channelToNumberOfSubframesMinusOne(chan: Channel) u3 {
        return switch (chan) {
            .left_side, .side_right, .mid_side => 1,
            else => @truncate(@intFromEnum(chan)),
        };
    }
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
    footer: u16,

    pub fn parseFrame(reader: *cbr.AnyCustomBitReader, alloc: std.mem.Allocator, stream_info: ?StreamInfo) !Frame {
        var frame: Frame = undefined;

        var hasher8 = crc8.init();
        var hasher16 = crc16.init();
        const crc8_writer = CrcWriter(crc8){ .crc_obj = &hasher8 };
        const crc16_writer = CrcWriter(crc16){ .crc_obj = &hasher16 };

        var crc8_bw = std.io.bitWriter(.big, crc8_writer);
        var crc16_bw = std.io.bitWriter(.big, crc16_writer);

        var crc_reader = ReaderToCRCWriter{
            .cbr = reader,
            .bw8 = &crc8_bw,
            .bw16 = &crc16_bw,
        };

        frame.header = try FrameHeader.parseFrameHeader(crc_reader);
        const sub_count: u4 = frame.header.channel.channelToNumberOfSubframesMinusOne() + 1;

        // std.debug.print("Parsing frame with header: {}\n", .{frame.header});
        frame.sub_frames = try alloc.alloc(SubFrame, sub_count);
        for (0..sub_count) |channel_id| {
            frame.sub_frames[channel_id] = try SubFrame.parseSubframe(
                crc_reader,
                alloc,
                frame.header,
                stream_info,
                @intCast(channel_id),
            );
            // std.debug.print("channel {}\n", .{channel_id});
            // std.debug.print("Subblock {}: {any}\n", .{ channel_id, frame.sub_frames[channel_id] });
            // std.debug.print("Subframe parsed\n\n\n", .{});
        }

        // std.debug.print("checkpoint3\n", .{});

        crc_reader.cbr.alignToByte();

        try crc_reader.bw16.flushBits();
        const fin = crc_reader.bw16.writer.crc_obj.final();
        // read crc
        frame.footer = try crc_reader.cbr.readInt(u16);
        // std.debug.print("Footer says CRC should be: {} | What we got: {}\n", .{ frame.footer, fin });
        // CRC16 Check (return error if failed)
        if (fin != frame.footer) {
            return error.crc_frame_footer_mismatch;
        }

        // stereo decorrelation

        // TODO: check if the compiler auto vectorizes these, because it SHOULD
        switch (frame.header.channel) {
            .left_side => {
                const left = frame.sub_frames[0].subblock; // left
                var side = frame.sub_frames[1].subblock; // side

                for (0..frame.header.block_size) |i| {
                    side[i] = left[i] - side[i];
                }
            },
            .side_right => {
                var side = frame.sub_frames[0].subblock; // side
                const right = frame.sub_frames[1].subblock; // right

                for (0..frame.header.block_size) |i| {
                    side[i] = side[i] + right[i];
                }
            },
            .mid_side => {
                var mid = frame.sub_frames[0].subblock; // mid
                var side = frame.sub_frames[1].subblock; // side

                for (0..frame.header.block_size) |i| {
                    var mid_shifted = (mid[i] << 1);
                    const side_sample = side[i];

                    if (side_sample & 1 == 1) {
                        mid_shifted += 1;
                    }

                    const new_l = (mid_shifted + side_sample) >> 1;
                    const new_r = (mid_shifted - side_sample) >> 1;

                    mid[i] = new_l;
                    side[i] = new_r;
                }
            },
            else => {},
        }

        return frame;
    }
    pub fn calculateSamples(_: Frame) []i32 {
        @panic("TODO");
    }
};

pub fn readCustomIntToEnum(comptime Enum: type, bit_reader: ReaderToCRCWriter) !Enum {
    const int_representation = @typeInfo(Enum).@"enum".tag_type;

    return @enumFromInt(try bit_reader.readBitsNoEof(int_representation, @bitSizeOf(int_representation)));
}

pub fn CrcWriter(comptime T: type) type {
    return struct {
        crc_obj: *T,

        pub fn writeByte(self: *CrcWriter(T), bits: u8) !void {
            const out = [1]u8{bits};
            self.crc_obj.update(&out);

            // NOTE FROM STANLEY: KEEP THIS IN IT IS VERY USEFUL
            // std.debug.print("wrotebyte: {X} to {}\n", .{ out, self });
            // std.debug.print("wrotebyte: {X}\n", .{out});
        }

        pub fn write(self: *CrcWriter(T), bytes: []const u8) void {
            self.crc_obj.update(bytes);
            // std.debug.print("wrote: {X} to {}\n", .{ bytes, self });
        }
    };
}

pub const ReaderToCRCWriter = struct {
    // NOTE from Stanley: due to the nature of CustomBitReader, reader MUST NOT BE MIXED WITH cbr
    // reader: std.io.AnyReader,
    cbr: *cbr.AnyCustomBitReader,
    bw8: *std.io.BitWriter(.big, CrcWriter(crc8)),
    bw16: *std.io.BitWriter(.big, CrcWriter(crc16)),

    // pub fn init(cb: cbr.AnyCustomBitReader, bw: *std.io.BitWriter(.big, CrcWriter(T))) ReaderToCRCWriter(T) {
    //     return .{
    //         .cbr = cb,
    //         .bw = bw,

    //     };
    // }

    // pub fn any(self: *ReaderToCRCWriter(T)) std.io.AnyReader {
    //     return .{
    //         .context = self,
    //         .readFn = typeErasedReadFn,
    //     };
    // }

    // pub fn read(self: *ReaderToCRCWriter, buffer: []u8) !usize {
    //     // const res = try self.cbr.read(buffer);
    //     for (0..buffer.len) |i| {
    //         buffer[i] = try self.cbr.readBitsNoEof(u8, @bitSizeOf(u8));
    //     }

    //     self.bw8.writer.write(buffer[0..buffer.len]);
    //     self.bw16.writer.write(buffer[0..buffer.len]);

    //     return buffer.len;
    // }

    // pub fn readByte(self: *ReaderToCRCWriter) !u8 {
    //     // return self.any().readByte();

    //     const res = self.cbr.readInt(u8);
    //     self.bw8.writer.writeByte(res);
    //     self.bw16.writer.writeByte(res);

    //     return res;
    //     // var ans: [1]u8 = undefined;

    //     // const res = try self.br.readBits(u8, 8, out_bits: *u16)
    //     // if (res < 1) return error.EndOfStream;

    //     // self.bw.writer.write(ans);

    //     // return ans[0];
    // }

    // pub fn typeErasedReadFn(context: *const anyopaque, buffer: []u8) anyerror!usize {
    //     const ptr: *ReaderToCRCWriter(T) = @constCast(@ptrCast(@alignCast(context)));
    //     return read(ptr, buffer);
    // }

    // fn readBitsNoEof
    pub fn readBitsNoEof(self: ReaderToCRCWriter, comptime I: type, num: u16) !I {
        const tracy_zone = tracy.ZoneN(
            @src(),
            std.fmt.comptimePrint("readBits->{s}", .{@typeName(I)}),
        );
        defer tracy_zone.End();

        const readed = try self.cbr.readBitsNoEof(I, num);
        try self.bw8.writeBits(readed, num);
        try self.bw16.writeBits(readed, num);

        return readed;
    }

    pub fn readUnary(self: ReaderToCRCWriter) !u32 {
        const read = try self.cbr.readUnary();

        // std.debug.print("Writing {} unary bits\n", .{read + 1});

        const bytes_to_write = read >> 3;
        for (0..bytes_to_write) |_| {
            try self.bw8.writeBits(@as(u8, 0), 8);
            try self.bw16.writeBits(@as(u8, 0), 8);
        }

        const remaining_bits: u4 = @intCast(read - (bytes_to_write << 3));
        try self.bw8.writeBits(@as(u8, 1), remaining_bits + 1);
        try self.bw16.writeBits(@as(u8, 1), remaining_bits + 1);

        return read;
    }

    pub fn readInt(self: ReaderToCRCWriter, comptime I: type) !I {
        const readed = try self.cbr.readInt(I);
        try self.bw8.writeBits(readed, @bitSizeOf(I));
        try self.bw16.writeBits(readed, @bitSizeOf(I));

        return readed;
    }
};
pub const FrameHeader = struct {
    blocking_strategy: bool, // 0 is fixed block size, 1 is variable
    block_size: u16,
    sample_rate: ParsingSampleRate,
    unusual_sample_rate: ?u18 = null,
    channel: Channel,
    bit_depth: BitDepth,
    coded_number: u36,
    crc: u8,

    pub fn parseFrameHeader(crc_reader: ReaderToCRCWriter) !FrameHeader {
        var frame_header: FrameHeader = undefined;
        frame_header.unusual_sample_rate = null;

        if (try crc_reader.readBitsNoEof(u15, 15) != 0b111111111111100) {
            return error.incorrect_frame_sync;
        }

        frame_header.blocking_strategy = try crc_reader.readBitsNoEof(u1, @bitSizeOf(u1)) == 1;

        const bs = try readCustomIntToEnum(ParsingBlockSize, crc_reader);
        frame_header.sample_rate = try readCustomIntToEnum(ParsingSampleRate, crc_reader);
        frame_header.channel = try readCustomIntToEnum(Channel, crc_reader);
        frame_header.bit_depth = try readCustomIntToEnum(BitDepth, crc_reader);

        if (try crc_reader.readBitsNoEof(u1, 1) != 0) {
            return error.using_reserved_value;
        }

        frame_header.coded_number = try decodeNumber(crc_reader);

        // we should be aligned at this point
        frame_header.block_size = switch (bs) {
            .uncommon_8bit => (try crc_reader.readInt(u8)) + 1,
            .uncommon_16bit => (try crc_reader.readInt(u16)) + 1,
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
                frame_header.unusual_sample_rate = @as(u18, try crc_reader.readInt(u8)) * 1000;
            },
            .uncommon_16bit => {
                frame_header.unusual_sample_rate = try crc_reader.readInt(u16);
            },
            .uncommon_16bit_div_10 => {
                // TODO: Fix this to be more accurate to the RFC
                frame_header.unusual_sample_rate = @divFloor(try crc_reader.readInt(u16), 10);
            },
            .forbidden => {
                return error.forbidden_sample_rate;
            },
            else => {},
        }

        try crc_reader.bw8.flushBits();

        // std.debug.print("frame header: {}\n", .{frame_header});
        // std.debug.print("crc8: {}, {b}\n", .{ hasher.final(), crc_reader.bw.bits });
        const fin = crc_reader.bw8.writer.crc_obj.final();
        frame_header.crc = try crc_reader.readInt(u8);
        // std.debug.print("header crc8: {} | we got: {}\n", .{ frame_header.crc, fin });

        // CRC Check (return error if failed)
        if (fin != frame_header.crc) {
            return error.crc_frame_header_mismatch;
        }

        return frame_header;
    }
};

pub const SubFrameHeader = union(enum) {
    constant,
    verbatim,
    fixed_predictor: u3,

    /// THE ACTUAL ORDER OF THE LINEAR PREDICTOR IS THIS VALUE + 1
    linear_predictor_minus_one: u5,
};

pub const SubFrame = struct {
    header: SubFrameHeader,
    wasted_bits: u5,
    subblock: []i32,

    pub fn parseSubframe(br: ReaderToCRCWriter, alloc: std.mem.Allocator, frame: FrameHeader, stream_info: ?StreamInfo, channel_num: u3) !SubFrame {
        var subframe: SubFrame = undefined;
        // std.debug.print("BR start: {}\n", .{br});

        if (try br.readBitsNoEof(u1, 1) != 0) return error.missing_zero_bit;

        // std.debug.print("BR 1: {}\n", .{br});
        const header = try br.readBitsNoEof(u6, 6);
        // std.debug.print("BR 2: {}\n", .{br});
        subframe.header = switch (header) {
            0 => .constant,
            1 => .verbatim,
            0b000010...0b000111 => return error.using_reserved_value,
            0b001000...0b001100 => |x| SubFrameHeader{ .fixed_predictor = @as(u3, @truncate(x)) },
            0b001101...0b011111 => return error.using_reserved_value,
            0b100000...0b111111 => |x| SubFrameHeader{ .linear_predictor_minus_one = @as(u5, @truncate(x)) },
        };

        subframe.wasted_bits = 0;
        if (try br.readBitsNoEof(u1, 1) == 1) {
            subframe.wasted_bits = @intCast(try br.readUnary() + 1);
        }

        // std.debug.print("ended unary: {}\n", .{subframe.wasted_bits});

        // std.debug.print("BR 3: {}, {}\n", .{ br, br.reader.context });
        const bit_depth_minus_one = try frame.bit_depth.asIntMinusOne(stream_info);
        // std.debug.print("intercorrelation offset: {} | wasted bits: {}\n", .{ offset_if_is_side_subframe, wasted });
        var real_bit_depth: u16 = (bit_depth_minus_one - subframe.wasted_bits) + 1;

        switch (frame.channel) {
            .left_side, .mid_side => {
                if (channel_num == 1) {
                    real_bit_depth += 1;
                }
            },
            .side_right => {
                if (channel_num == 0) {
                    real_bit_depth += 1;
                }
            },
            else => {},
        }

        const wasted = subframe.wasted_bits;
        // std.debug.print("Subframe header: {} | wasted: {} | real bit depth: {}\n", .{ subframe.header, wasted, real_bit_depth });

        // const verbatim_int_type = std.meta.Int(.signed, real_bit_depth);
        const decoded_sample_type = i32;

        // std.debug.print("checkpoint0\n", .{});
        const subblock_zone = tracy.ZoneN(@src(), "Parse Subblock");
        subframe.subblock = switch (subframe.header) {
            .constant => blk: {
                const buf = try alloc.alloc(decoded_sample_type, frame.block_size);
                const target_val = (try util.readTwosComplementIntegerOfSetBits(
                    br,
                    decoded_sample_type,
                    real_bit_depth,
                )) << wasted;
                @memset(buf, target_val);
                break :blk buf;
            },
            .verbatim => blk: {
                var buf = try alloc.alloc(decoded_sample_type, frame.block_size);
                for (0..buf.len) |i| {
                    // i(var)

                    buf[i] = (try util.readTwosComplementIntegerOfSetBits(br, decoded_sample_type, real_bit_depth)) << wasted;
                }
                break :blk buf;
            },
            .fixed_predictor => |order| blk: {
                var buf = try alloc.alloc(decoded_sample_type, frame.block_size);

                //read warmup samples
                for (0..order) |i| {
                    buf[i] = (try util.readTwosComplementIntegerOfSetBits(br, decoded_sample_type, real_bit_depth)) << wasted;
                    // std.debug.print("Warmup sample: {}\n", .{buf[i]});
                }
                // std.debug.print("buf after warmup: {d}\n", .{buf});

                const coded_residual = try rice.CodedResidual.readCodedResidual(br);
                // std.debug.print("coded residual ->: {}\n", .{coded_residual});

                // std.debug.print("first partition: {}\n", .{current_partition});

                const partition_zone = tracy.ZoneN(@src(), "Read Rice Partitions (fixed)");
                try rice.readRicePartitionsIntoResidualBuffer(
                    br,
                    frame.block_size,
                    order,
                    coded_residual,
                    buf,
                );
                partition_zone.End();

                switch (order) {
                    0 => {},
                    1 => {
                        // read remaining samples
                        for (order..buf.len) |i| {
                            buf[i] = (buf[i - 1] + buf[i]) << wasted;
                        }
                    },
                    2 => {
                        // read remaining samples
                        for (order..buf.len) |i| {
                            buf[i] = @intCast((2 * @as(i64, buf[i - 1]) - @as(i64, buf[i - 2]) + buf[i]) << wasted);
                        }
                    },
                    3 => {
                        // read remaining samples
                        for (order..buf.len) |i| {
                            buf[i] = @intCast((3 * @as(i64, buf[i - 1]) - 3 * @as(i64, buf[i - 2]) + @as(i64, buf[i - 3]) + buf[i]) << wasted);
                        }
                    },
                    4 => {
                        // read remaining samples
                        for (order..buf.len) |i| {
                            buf[i] = @intCast((4 * @as(i64, buf[i - 1]) - 6 * @as(i64, buf[i - 2]) + 4 * @as(i64, buf[i - 3]) - @as(i64, buf[i - 4]) + buf[i]) << wasted);
                        }
                    },
                    else => {
                        return error.forbidden_fixed_predictor_order;
                    },
                }
                // partition_zone.end();
                // std.debug.print("buf: {d}\n", .{buf});

                break :blk buf;
            },
            .linear_predictor_minus_one => |order_minus_one| blk: {
                const order: u6 = order_minus_one + 1;

                var buf = try alloc.alloc(decoded_sample_type, frame.block_size);
                for (0..order) |i| {
                    buf[i] = (try util.readTwosComplementIntegerOfSetBits(br, decoded_sample_type, real_bit_depth)) << wasted;
                }

                const coefficient_precision: u4 = try br.readBitsNoEof(u4, 4) + 1;

                // TODO: Add a safe mode to the library so that this check can be turned off if needed
                // Defined under https://www.rfc-editor.org/rfc/rfc9639.html#appendix-B.4-1 to never be negative.
                const prediction_right_shift: i5 = try br.readBitsNoEof(i5, 5);
                if (prediction_right_shift < 0) {
                    return error.negative_lpc_shift;
                }
                const casted: u4 = @intCast(prediction_right_shift);

                var coefficients = try alloc.alloc(i16, order);
                for (0..order) |i| {
                    coefficients[i] = try util.readTwosComplementIntegerOfSetBits(br, i16, coefficient_precision);
                }
                // std.debug.print("coefficients: {d}\n", .{coefficients});
                const coded_residual = try rice.CodedResidual.readCodedResidual(br);

                const partition_zone = tracy.ZoneN(@src(), "Read Rice Partitions (linear)");
                try rice.readRicePartitionsIntoResidualBuffer(
                    br,
                    frame.block_size,
                    order,
                    coded_residual,
                    buf,
                );
                partition_zone.End();

                for (order..buf.len) |i| {
                    var predicted: i64 = 0;
                    for (0..order) |x| {
                        predicted += @as(i64, @intCast(coefficients[x])) * buf[i - x - 1];
                    }

                    buf[i] = @intCast(((predicted >> casted) + buf[i]) << wasted);
                }

                break :blk buf;
            },
        };
        subblock_zone.End();
        // std.debug.print("Created: {d}\n", .{subframe.subblock});

        return subframe;
    }
};

pub fn decodeNumber(reader: ReaderToCRCWriter) !u36 {
    var ret: u36 = 0;
    const first = try reader.readInt(u8);

    var N: u3 = undefined;
    if (first & 0b1000_0000 == 0) {
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
        ret |= (try reader.readInt(u8) & 0b0011_1111);
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

test "truncation check" {
    var cur: u6 = 0b001000;
    var exp: u3 = 0;
    while (cur <= 0b001100) : (cur += 1) {
        try std.testing.expectEqual(exp, @as(u3, @truncate(cur)));
        exp += 1;
    }
}
