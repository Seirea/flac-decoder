const std = @import("std");
const lib = @import("flac_decoder_lib");
const builtin = @import("builtin");

pub const cbr = lib.custom_bit_reader;

const tracy = @import("tracy");

pub const Signature = extern struct {
    sig: [4]u8,
};

var tracy_allocator = tracy.TracyAllocator.init(std.heap.smp_allocator);

pub fn parseFrameWithBitDepth(
    reader: *cbr.AnyCustomBitReader,
    alloc: *std.heap.ArenaAllocator,
    stream_info: lib.metadata.block.StreamInfo,
    out: std.io.AnyWriter,
    write_type: type,
) !void {
    while (lib.frame.Frame.parseFrame(reader, alloc.allocator(), stream_info) catch |err| switch (err) {
        error.EndOfStream => null,
        else => |er| return er,
    }) |x| {
        for (0..x.header.block_size) |sample| {
            for (x.sub_frames) |subframe| {
                const val = subframe.subblock[sample];
                try out.writeInt(write_type, @intCast(val), std.builtin.Endian.little);
            }
        }
        _ = alloc.reset(.retain_capacity);
    }
}

pub fn main() !void {
    var allocator = tracy_allocator.allocator();

    const file = try std.fs.cwd().openFile("test/test2.flac", .{});
    var breader = std.io.bufferedReader(file.reader());
    const file_reader = breader.reader();

    const sig: Signature = try file_reader.readStruct(Signature);
    std.debug.print("{s}\n", sig);

    if (!std.mem.eql(u8, &sig.sig, "fLaC")) {
        @panic("FLAC Magic Bytes mismatch! Is this a FLAC File?");
    }

    var metadata_arena = std.heap.ArenaAllocator.init(allocator);
    var streaminfo_saved: ?lib.metadata.block.StreamInfo = null;
    // read metadata
    while (true) {
        const block_header = try lib.metadata.block.getBlockFromReader(
            lib.metadata.block.Header,
            file_reader.any(),
        );
        std.debug.print("Metadata Block Header: {}\n", .{block_header});

        switch (block_header.metadata_block_type) {
            // streaminfo
            .streaminfo => {
                streaminfo_saved = try lib.metadata.block.getBlockFromReader(
                    lib.metadata.block.StreamInfo,
                    file_reader.any(),
                );

                std.debug.print("StreamInfo Block: {}\n", .{streaminfo_saved.?});
            },
            .seek_table => {
                const seek_table = try lib.metadata.block.SeekTable.createFromReader(
                    file_reader.any(),
                    metadata_arena.allocator(),
                    block_header.size_of_metadata_block,
                );
                _ = seek_table;

                // std.debug.print("[{d}] SeekTable Block: {}\n", .{ seek_table.seek_points.len, seek_table });
            },
            .vorbis_comment => {
                const vorbis_comment = try lib.metadata.vorbis.VorbisComment.createFromReader(
                    file_reader.any(),
                    metadata_arena.allocator(),
                );
                std.debug.print("Vorbis Comment Vendor String: {s}\n", .{vorbis_comment.vendor_string});
                for (vorbis_comment.user_comments) |x| {
                    std.debug.print("COMMENT: {s}\n", .{x});
                }
            },
            .picture => {
                const picture = try lib.metadata.block.Picture.createFromReader(
                    file_reader.any(),
                    metadata_arena.allocator(),
                );
                std.debug.print("Image type: {s} | description: {s}\n", .{
                    picture.media_type_string,
                    picture.picture_description,
                });
            },
            .application => {
                const app = try lib.metadata.block.Application.createFromReader(
                    file_reader.any(),
                    metadata_arena.allocator(),
                    block_header.size_of_metadata_block,
                );
                std.debug.print("{}", .{app});
            },
            .padding => {
                try file_reader.skipBytes(block_header.size_of_metadata_block, .{});
            },
            .cuesheet => {
                const cue_sheet = try lib.metadata.block.CueSheet.createFromReader(
                    file_reader.any(),
                    metadata_arena.allocator(),
                    block_header.size_of_metadata_block,
                );

                std.debug.print("CUE TRACKS:\n", .{});
                for (cue_sheet.tracks) |x| {
                    std.debug.print("{s} @ {d}\n", .{ x.ISRC, x.track_offset });
                }
            },
            else => {
                const buf = try allocator.alloc(u8, block_header.size_of_metadata_block);
                _ = try file_reader.read(buf);
                std.debug.print("Unhandled Block Type: {b}\n", .{
                    buf,
                });
            },
        }

        if (block_header.is_last_block) {
            break;
        }
    }

    std.debug.print("Metadata read\n", .{});

    metadata_arena.deinit();

    const out_wav = try std.fs.cwd().createFile("out.wav", .{});
    var bw = std.io.bufferedWriter(out_wav.writer());
    const wav_writer = bw.writer();

    const bit_depth = @as(u6, streaminfo_saved.?.bits_per_sample_minus_one) + 1;

    const nchannels = streaminfo_saved.?.number_of_channels_minus_one + 1;
    const num_of_samples: u32 = @intCast(streaminfo_saved.?.number_of_interchannel_samples);
    const samplerate = streaminfo_saved.?.sample_rate;
    // const duration = num_of_samples / samplerate;

    try wav_writer.writeAll("RIFF");
    const header_size = 36;
    try wav_writer.writeInt(
        u32,
        header_size + num_of_samples * nchannels * (bit_depth >> 3),
        std.builtin.Endian.little,
    );
    try wav_writer.writeAll("WAVE");

    try wav_writer.writeAll("fmt ");
    try wav_writer.writeInt(u32, 16, std.builtin.Endian.little);
    try wav_writer.writeInt(u16, 1, std.builtin.Endian.little);
    try wav_writer.writeInt(u16, nchannels, std.builtin.Endian.little);
    try wav_writer.writeInt(u32, samplerate, std.builtin.Endian.little);
    const blockAlign = nchannels * (bit_depth / 8);
    try wav_writer.writeInt(u32, @as(u32, blockAlign) * samplerate, std.builtin.Endian.little);
    try wav_writer.writeInt(u16, blockAlign, std.builtin.Endian.little);
    try wav_writer.writeInt(u16, bit_depth, std.builtin.Endian.little);
    try wav_writer.writeAll("data");
    try wav_writer.writeInt(
        u32,
        num_of_samples * nchannels * (bit_depth >> 3),
        std.builtin.Endian.little,
    );

    var frame_arena = std.heap.ArenaAllocator.init(allocator);

    var custom_bit_reader = cbr.customBitReader(.big, lib.custom_bit_reader.WordType, file_reader.any());

    switch (bit_depth) {
        8 => {
            try parseFrameWithBitDepth(&custom_bit_reader, &frame_arena, streaminfo_saved.?, wav_writer.any(), i8);
        },
        16 => {
            try parseFrameWithBitDepth(&custom_bit_reader, &frame_arena, streaminfo_saved.?, wav_writer.any(), i16);
        },
        24 => {
            try parseFrameWithBitDepth(&custom_bit_reader, &frame_arena, streaminfo_saved.?, wav_writer.any(), i24);
        },
        32 => {
            try parseFrameWithBitDepth(&custom_bit_reader, &frame_arena, streaminfo_saved.?, wav_writer.any(), i32);
        },
        else => @panic("Unsupported bit depth"),
    }

    frame_arena.deinit();

    // write audio
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

    try bw.flush();

    file.close();
}
