const std = @import("std");
const lib = @import("flac_decoder_lib");
const builtin = @import("builtin");

pub const cbr = lib.custom_bit_reader;

// const tracy = @import("tracy");

// var tracy_allocator = tracy.TracyAllocator.init(std.heap.smp_allocator);

pub fn parseFrameWithBitDepth(
    reader: *cbr.AnyCustomBitReader,
    alloc: *std.heap.ArenaAllocator,
    stream_info: lib.metadata.block.StreamInfo,
    out: std.io.AnyWriter,
    comptime write_type: type,
) !void {
    while (lib.frame.Frame.parseFrame(reader, alloc.allocator(), stream_info) catch |err| switch (err) {
        error.EndOfStream => null,
        else => |er| return er,
    }) |x| {
        for (0..x.header.block_size) |sample| {
            for (x.sub_frames) |subframe| {
                const val = subframe.subblock[sample];
                if (@typeInfo(write_type).int.signedness == .signed) {
                    // signed
                    try out.writeInt(write_type, @intCast(val), std.builtin.Endian.little);
                } else {
                    // unsigned
                    try out.writeInt(write_type, @intCast(((std.math.maxInt(write_type) >> 1) + 1) + val), std.builtin.Endian.little);
                }
            }
        }
        _ = alloc.reset(.retain_capacity);
    }
}

const allocator = std.heap.smp_allocator;

pub fn main() !void {
    var args = try std.process.ArgIterator.initWithAllocator(allocator);
    _ = args.next(); // skip the executable
    const path = args.next() orelse "test/test.flac";
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var metadata_arena = std.heap.ArenaAllocator.init(allocator);
    // read metadata

    var decoder = lib.Decoder.init(
        std.io.StreamSource{ .file = file },
        metadata_arena.allocator(),
    );

    try decoder.read_magic();

    while (try decoder.read_metadata()) |x| {
        std.debug.print("{}\n", .{x});
    }

    //     std.debug.print("Metadata read\n", .{});

    //     metadata_arena.deinit();

    //     const out_wav = try std.fs.cwd().createFile("out.wav", .{});
    //     defer out_wav.close();
    //     var bw = std.io.bufferedWriter(out_wav.writer());
    //     const wav_writer = bw.writer();

    //     const bit_depth = @as(u6, streaminfo_saved.?.bits_per_sample_minus_one) + 1;

    //     const nchannels = streaminfo_saved.?.number_of_channels_minus_one + 1;
    //     const num_of_samples: u32 = @intCast(streaminfo_saved.?.number_of_interchannel_samples);
    //     const samplerate = streaminfo_saved.?.sample_rate;
    //     // const duration = num_of_samples / samplerate;

    //     try wav_writer.writeAll("RIFF");
    //     const header_size = 36;
    //     try wav_writer.writeInt(
    //         u32,
    //         header_size + num_of_samples * nchannels * (bit_depth >> 3),
    //         std.builtin.Endian.little,
    //     );
    //     try wav_writer.writeAll("WAVE");

    //     try wav_writer.writeAll("fmt ");
    //     try wav_writer.writeInt(u32, 16, std.builtin.Endian.little);
    //     try wav_writer.writeInt(u16, 1, std.builtin.Endian.little);
    //     try wav_writer.writeInt(u16, nchannels, std.builtin.Endian.little);
    //     try wav_writer.writeInt(u32, samplerate, std.builtin.Endian.little);
    //     const blockAlign = nchannels * (bit_depth / 8);
    //     try wav_writer.writeInt(u32, @as(u32, blockAlign) * samplerate, std.builtin.Endian.little);
    //     try wav_writer.writeInt(u16, blockAlign, std.builtin.Endian.little);
    //     try wav_writer.writeInt(u16, bit_depth, std.builtin.Endian.little);
    //     try wav_writer.writeAll("data");
    //     try wav_writer.writeInt(
    //         u32,
    //         num_of_samples * nchannels * (bit_depth >> 3),
    //         std.builtin.Endian.little,
    //     );

    //     var frame_arena = std.heap.ArenaAllocator.init(allocator);

    //     var custom_bit_reader = cbr.customBitReader(.big, lib.custom_bit_reader.WordType, file_reader.any());

    //     switch (bit_depth) {
    //         8 => {
    // <<<<<<< HEAD
    //             try parseFrameWithBitDepth(&custom_bit_reader, &frame_arena, streaminfo_saved.?, wav_writer.any(), u8);
    // =======
    //             try parseFrameWithBitDepth(file_reader.any(), &frame_arena, streaminfo_saved.?, wav_writer.any(), u8);
    // >>>>>>> main
    //         },
    //         16 => {
    //             try parseFrameWithBitDepth(&custom_bit_reader, &frame_arena, streaminfo_saved.?, wav_writer.any(), i16);
    //         },
    //         24 => {
    //             try parseFrameWithBitDepth(&custom_bit_reader, &frame_arena, streaminfo_saved.?, wav_writer.any(), i24);
    //         },
    //         32 => {
    //             try parseFrameWithBitDepth(&custom_bit_reader, &frame_arena, streaminfo_saved.?, wav_writer.any(), i32);
    //         },
    //         else => @panic("Unsupported bit depth"),
    //     }

    //     frame_arena.deinit();

    //     // write audio
    //     for (0..frame.channel.channelToNumberOfSubframesMinusOne() + 1) |i| {
    //         const subframe = try lib.frame.SubFrame.parseSubframe(
    //             &br,
    //             allocator,
    //             frame,
    //             null,
    //             @truncate(i),
    //         );
    //         // std.debug.print("Subframe: {}\n", .{subframe});
    //         if (i == 0) {
    //             read_samples += subframe.subblock.len;
    //         }
    //     }
    //     br.alignToByte();

    //     // FIXME: this must be added to the library
    //     _ = try file_reader.readInt(u16, .big);
    //     // std.debug.print("Frame CRC16: {}\n", .{crc});
    // }

    //     try bw.flush();
}
