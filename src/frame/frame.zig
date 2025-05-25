const std = @import("std");
const rice = @import("../rice.zig");
const util = @import("../util.zig");
const StreamInfo = @import("../metadata/block.zig").StreamInfo;
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

    pub fn parseFrame(reader: std.io.AnyReader, alloc: std.mem.Allocator, stream_info: ?StreamInfo) !Frame {
        var frame: Frame = undefined;

        var hasher = crc16.init();
        const crc_writer = CrcWriter(crc16){ .crc_obj = &hasher };
        var bw = std.io.bitWriter(.big, crc_writer);
        var crc_reader = ReaderToCRCWriter(crc16).init(reader, &bw);

        frame.header = try FrameHeader.parseFrameHeader(crc_reader.any());
        const sub_count: u4 = frame.header.channel.channelToNumberOfSubframesMinusOne() + 1;

        frame.sub_frames = try alloc.alloc(SubFrame, sub_count);
        for (0..sub_count) |channel_id| {
            frame.sub_frames[channel_id] = try SubFrame.parseSubframe(
                &crc_reader,
                alloc,
                frame.header,
                stream_info,
                @intCast(channel_id),
            );
        }

        crc_reader.br.alignToByte();

        // read crc
        frame.footer = try reader.readInt(u16, .big);
        try crc_reader.bw.flushBits();

        const fin = hasher.final();
        // std.debug.print("footer: {} | fin: {}\n", .{ frame.footer, fin });
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

pub fn readCustomIntToEnum(comptime Enum: type, bit_reader: anytype) !Enum {
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
            // std.debug.print("wrote: {X} to \n{}\n", .{ out, self });
        }
    };
}

pub fn ReaderToCRCWriter(comptime T: type) type {
    return struct {
        reader: std.io.AnyReader,
        br: std.io.BitReader(.big, std.io.AnyReader),
        bw: *std.io.BitWriter(.big, CrcWriter(T)),

        pub fn init(reader: std.io.AnyReader, bw: *std.io.BitWriter(.big, CrcWriter(T))) ReaderToCRCWriter(T) {
            const br = std.io.bitReader(.big, reader);
            return .{
                .reader = reader,
                .br = br,
                .bw = bw,
            };
        }

        pub fn any(self: *ReaderToCRCWriter(T)) std.io.AnyReader {
            return .{
                .context = self,
                .readFn = typeErasedReadFn,
            };
        }

        pub fn read(self: *ReaderToCRCWriter(T), buffer: []u8) !usize {
            const res = try self.reader.read(buffer);
            for (buffer[0..res]) |byte| {
                try self.bw.writeBits(byte, 8);
            }
            return res;
        }
        pub fn readByte(self: *ReaderToCRCWriter(T)) !u8 {
            return self.any().readByte();
        }
        pub fn typeErasedReadFn(context: *const anyopaque, buffer: []u8) anyerror!usize {
            const ptr: *ReaderToCRCWriter(T) = @constCast(@ptrCast(@alignCast(context)));
            return read(ptr, buffer);
        }

        // fn readBitsNoEof
        pub fn readBitsNoEof(self: *ReaderToCRCWriter(T), comptime I: type, num: u16) !I {
            const readed = try self.br.readBitsNoEof(I, num);
            try self.bw.writeBits(readed, num);

            return readed;
        }

        pub fn readInt(self: *ReaderToCRCWriter(T), comptime I: type, endian: std.builtin.Endian) !I {
            const readed = try self.reader.readInt(I, endian);
            try self.bw.writeBits(readed, @bitSizeOf(I));

            return readed;
        }
    };
}
pub const FrameHeader = struct {
    blocking_strategy: bool, // 0 is fixed block size, 1 is variable
    block_size: u16,
    sample_rate: ParsingSampleRate,
    unusual_sample_rate: ?u18 = null,
    channel: Channel,
    bit_depth: BitDepth,
    coded_number: u36,
    crc: u8,

    pub fn parseFrameHeader(reader: std.io.AnyReader) !FrameHeader {
        var hasher = crc8.init();
        const crc_writer = CrcWriter(crc8){ .crc_obj = &hasher };

        var bw = std.io.bitWriter(.big, crc_writer);

        var crc_reader = ReaderToCRCWriter(crc8).init(reader, &bw);

        var frame_header: FrameHeader = undefined;
        frame_header.unusual_sample_rate = null;

        if (try crc_reader.readBitsNoEof(u15, 15) != 0b111111111111100) {
            return error.incorrect_frame_sync;
        }

        frame_header.blocking_strategy = try crc_reader.readBitsNoEof(u1, @bitSizeOf(u1)) == 1;

        const bs = try readCustomIntToEnum(ParsingBlockSize, &crc_reader);
        frame_header.sample_rate = try readCustomIntToEnum(ParsingSampleRate, &crc_reader);
        frame_header.channel = try readCustomIntToEnum(Channel, &crc_reader);
        frame_header.bit_depth = try readCustomIntToEnum(BitDepth, &crc_reader);

        if (try crc_reader.readBitsNoEof(u1, 1) != 0) {
            return error.using_reserved_value;
        }

        frame_header.coded_number = try decodeNumber(&crc_reader);

        frame_header.block_size = switch (bs) {
            .uncommon_8bit => (try crc_reader.readInt(u8, .big)) + 1,
            .uncommon_16bit => (try crc_reader.readInt(u16, .big)) + 1,
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
                frame_header.unusual_sample_rate = @as(u18, try crc_reader.readInt(u8, .big)) * 1000;
            },
            .uncommon_16bit => {
                frame_header.unusual_sample_rate = try crc_reader.readInt(u16, .big);
            },
            .uncommon_16bit_div_10 => {
                // TODO: Fix this to be more accurate to the RFC
                frame_header.unusual_sample_rate = @divFloor(try crc_reader.readInt(u16, .big), 10);
            },
            .forbidden => {
                return error.forbidden_sample_rate;
            },
            else => {},
        }

        try crc_reader.bw.flushBits();

        // std.debug.print("crc8: {}, {b}\n", .{ hasher.final(), crc_reader.bw.bits });
        frame_header.crc = try reader.readInt(u8, .big);

        // CRC Check (return error if failed)
        if (hasher.final() != frame_header.crc) {
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
    subblock: []i64,

    pub fn parseSubframe(br: anytype, alloc: std.mem.Allocator, frame: FrameHeader, stream_info: ?StreamInfo, channel_num: u3) !SubFrame {
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
            var num: u5 = 1;
            while (try br.readBitsNoEof(u1, 1) == 0) : (num += 1) {}
            subframe.wasted_bits = num;
        }

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

        // std.debug.print("Real bit depth for subframe: {d}\n", .{real_bit_depth});

        // const verbatim_int_type = std.meta.Int(.signed, real_bit_depth);
        const wasted = subframe.wasted_bits;
        const verbatim_int_type = i64;
        subframe.subblock = switch (subframe.header) {
            .constant => blk: {
                const buf = try alloc.alloc(verbatim_int_type, frame.block_size);
                const target_val = (try util.readTwosComplementIntegerOfSetBits(
                    br,
                    verbatim_int_type,
                    real_bit_depth,
                )) << wasted;
                @memset(buf, target_val);
                break :blk buf;
            },
            .verbatim => blk: {
                var buf = try alloc.alloc(verbatim_int_type, frame.block_size);
                for (0..buf.len) |i| {
                    // i(var)

                    buf[i] = (try util.readTwosComplementIntegerOfSetBits(br, verbatim_int_type, real_bit_depth)) << wasted;
                }
                break :blk buf;
            },
            .fixed_predictor => |order| blk: {
                var buf = try alloc.alloc(verbatim_int_type, frame.block_size);

                //read warmup samples
                for (0..order) |i| {
                    buf[i] = (try util.readTwosComplementIntegerOfSetBits(br, verbatim_int_type, real_bit_depth)) << wasted;
                }
                // std.debug.print("buf after warmup: {d}\n", .{buf});

                const coded_residual = try rice.CodedResidual.readCodedResidual(br);
                // std.debug.print("coded residual: {}\n", .{coded_residual});
                const number_of_samples_in_each_partition = frame.block_size >> coded_residual.order;
                var current_partition = try rice.Partition.readPartition(br, coded_residual);

                // std.debug.print("PARTITION: {}\n", .{p1});

                switch (order) {
                    0 => {
                        // read remaining samples
                        for (order..buf.len) |i| {
                            if (i % number_of_samples_in_each_partition == 0) {
                                current_partition = try rice.Partition.readPartition(br, coded_residual);
                            }
                            buf[i] = (try current_partition.readNextResidual(br)) << wasted;
                        }
                    },
                    1 => {
                        // read remaining samples
                        for (order..buf.len) |i| {
                            if (i % number_of_samples_in_each_partition == 0) {
                                current_partition = try rice.Partition.readPartition(br, coded_residual);
                            }
                            buf[i] = (buf[i - 1] + try current_partition.readNextResidual(br)) << wasted;
                        }
                    },
                    2 => {
                        // read remaining samples
                        for (order..buf.len) |i| {
                            if (i % number_of_samples_in_each_partition == 0) {
                                current_partition = try rice.Partition.readPartition(br, coded_residual);
                            }
                            buf[i] = (2 * buf[i - 1] - buf[i - 2] + try current_partition.readNextResidual(br)) << wasted;
                        }
                    },
                    3 => {
                        // read remaining samples
                        for (order..buf.len) |i| {
                            if (i % number_of_samples_in_each_partition == 0) {
                                current_partition = try rice.Partition.readPartition(br, coded_residual);
                            }
                            buf[i] = (3 * buf[i - 1] - 3 * buf[i - 2] + buf[i - 3] + try current_partition.readNextResidual(br)) << wasted;
                        }
                    },
                    4 => {
                        // read remaining samples
                        for (order..buf.len) |i| {
                            if (i % number_of_samples_in_each_partition == 0) {
                                current_partition = try rice.Partition.readPartition(br, coded_residual);
                            }
                            buf[i] = (4 * buf[i - 1] - 6 * buf[i - 2] + 4 * buf[i - 3] - buf[i - 4] + try current_partition.readNextResidual(br)) << wasted;
                        }
                    },
                    else => {
                        return error.forbidden_fixed_predictor_order;
                    },
                }

                // std.debug.print("buf: {d}\n", .{buf});

                break :blk buf;
            },
            .linear_predictor_minus_one => |order_minus_one| blk: {
                const order: u6 = order_minus_one + 1;

                var buf = try alloc.alloc(verbatim_int_type, frame.block_size);
                for (0..order) |i| {
                    buf[i] = (try util.readTwosComplementIntegerOfSetBits(br, verbatim_int_type, real_bit_depth)) << wasted;
                }

                const coefficient_precision: u4 = try br.readBitsNoEof(u4, 4) + 1;

                // TODO: Add a safe mode to the library so that this check can be turned off if needed
                // Defined under https://www.rfc-editor.org/rfc/rfc9639.html#appendix-B.4-1 to never be negative.
                const prediction_right_shift: i5 = try br.readBitsNoEof(i5, 5);
                if (prediction_right_shift < 0) {
                    return error.negative_lpc_shift;
                }

                var coefficients = try alloc.alloc(i16, order);
                for (0..order) |i| {
                    coefficients[i] = try util.readTwosComplementIntegerOfSetBits(br, i16, coefficient_precision);
                }

                const coded_residual = try rice.CodedResidual.readCodedResidual(br);
                const number_of_samples_in_each_partition = frame.block_size >> coded_residual.order;

                var current_partition = try rice.Partition.readPartition(br, coded_residual);

                for (order..buf.len) |i| {
                    if (i % number_of_samples_in_each_partition == 0) {
                        current_partition = try rice.Partition.readPartition(br, coded_residual);
                    }
                    var predicted: i64 = 0;
                    for (0..order) |x| {
                        predicted += @as(verbatim_int_type, @intCast(coefficients[x])) * buf[i - x - 1];
                    }

                    buf[i] = ((predicted >> @intCast(prediction_right_shift)) + try current_partition.readNextResidual(br)) << wasted;
                }

                break :blk buf;
            },
        };

        // std.debug.print("Created: {d}\n", .{subframe.subblock});

        return subframe;
    }
};

pub fn decodeNumber(reader: anytype) !u36 {
    var ret: u36 = 0;
    const first = try reader.readInt(u8, .big);

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
