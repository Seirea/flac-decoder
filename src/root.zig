const std = @import("std");

pub const metadata = @import("metadata/metadata.zig");
pub const frame = @import("frame/frame.zig");
pub const bit_reader = @import("bit_reader.zig");

pub const DecoderError = error{
    magic_bytes_mismatch,
    unhandled_metadata_block_type,
    forbidden,
} || frame.FrameParsingError;

pub const Decoder = struct {
    stream_info: ?metadata.block.StreamInfo = null,
    bit_reader: bit_reader.AnyBitReader,
    metadata_done: bool = false,

    pub fn init(reader: *std.Io.Reader) Decoder {
        return .{
            .bit_reader = bit_reader.bitReader(.big, reader),
        };
    }

    pub fn read_magic(self: *Decoder) !void {
        const sig: []u8 = try self.bit_reader.reader.take(4);
        std.debug.print("{s}\n", .{sig});

        if (!std.mem.eql(u8, sig, "fLaC")) {
            return DecoderError.magic_bytes_mismatch;
        }
    }

    pub fn write_wav_data(
        self: *Decoder,
        alloc: *std.heap.ArenaAllocator,
        out: *std.Io.Writer,
    ) !void {
        const bit_depth = @as(u6, self.stream_info.?.bits_per_sample_minus_one) + 1;

        const nchannels = self.stream_info.?.number_of_channels_minus_one + 1;
        const num_of_samples: u32 = @intCast(self.stream_info.?.number_of_interchannel_samples);
        const samplerate = self.stream_info.?.sample_rate;
        // const duration = num_of_samples / samplerate;

        try out.writeAll("RIFF");
        const header_size = 36;
        try out.writeInt(
            u32,
            header_size + num_of_samples * nchannels * (bit_depth >> 3),
            std.builtin.Endian.little,
        );
        try out.writeAll("WAVE");

        try out.writeAll("fmt ");
        try out.writeInt(u32, 16, std.builtin.Endian.little);
        try out.writeInt(u16, 1, std.builtin.Endian.little);
        try out.writeInt(u16, nchannels, std.builtin.Endian.little);
        try out.writeInt(u32, samplerate, std.builtin.Endian.little);
        const blockAlign = nchannels * (bit_depth / 8);
        try out.writeInt(u32, @as(u32, blockAlign) * samplerate, std.builtin.Endian.little);
        try out.writeInt(u16, blockAlign, std.builtin.Endian.little);
        try out.writeInt(u16, bit_depth, std.builtin.Endian.little);
        try out.writeAll("data");
        try out.writeInt(
            u32,
            num_of_samples * nchannels * (bit_depth >> 3),
            std.builtin.Endian.little,
        );

        switch (bit_depth) {
            8 => {
                try self.pump_frames_to_writer(alloc, out, u8);
            },
            16 => {
                try self.pump_frames_to_writer(alloc, out, i16);
            },
            24 => {
                try self.pump_frames_to_writer(alloc, out, i24);
            },
            32 => {
                try self.pump_frames_to_writer(alloc, out, i32);
            },
            else => @panic("Unsupported bit depth"),
        }
        try out.flush();
    }

    /// Precondition: metadata must already be read.
    pub fn pump_frames_to_writer(
        self: *Decoder,
        alloc: *std.heap.ArenaAllocator,
        out: *std.Io.Writer,
        comptime write_type: type,
    ) !void {
        while (self.read_frame(alloc.allocator()) catch |err| switch (err) {
            error.EndOfStream => null,
            else => |er| return er,
        }) |audio_frame| {
            // std.debug.print("caught frame: {}\n", .{audio_frame});
            for (0..audio_frame.header.block_size) |sample| {
                for (audio_frame.sub_frames) |subframe| {
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
        try out.flush();
    }

    pub fn read_frame(self: *Decoder, alloc: std.mem.Allocator) !frame.Frame {
        return try frame.Frame.decodeFrame(&self.bit_reader, alloc, self.stream_info);
    }

    pub fn read_metadata(self: *Decoder, alloc: std.mem.Allocator) !?metadata.MetadataBlock {
        if (self.metadata_done) {
            return null;
        }

        const block_header = try metadata.block.getBlockFromReader(
            metadata.block.Header,
            &self.bit_reader,
        );

        // std.debug.print("block_header:{}\n", .{block_header});

        if (block_header.is_last_block) {
            self.metadata_done = true;
        }

        switch (block_header.metadata_block_type) {
            // streaminfo
            .streaminfo => {
                const streaminfo = try metadata.block.StreamInfo.createFromReader(
                    &self.bit_reader,
                );
                self.stream_info = streaminfo;
                return .{ .streaminfo = streaminfo };
            },
            .seek_table => {
                const seek_table = try metadata.block.SeekTable.createFromReader(
                    &self.bit_reader,
                    alloc,
                    block_header.size_of_metadata_block,
                );
                // std.debug.print("[{d}] SeekTable Block: {}\n", .{ seek_table.seek_points.len, seek_table });
                return .{ .seek_table = seek_table };
            },
            .vorbis_comment => {
                try self.bit_reader.alignReader();
                const vorbis_comment = try metadata.vorbis.VorbisComment.createFromReader(
                    self.bit_reader.reader,
                    alloc,
                );
                std.debug.print("Vorbis Comment Vendor String: {s}\n", .{vorbis_comment.vendor_string});
                for (vorbis_comment.user_comments) |x| {
                    std.debug.print("COMMENT: {s}\n", .{x});
                }
                return .{ .vorbis_comment = vorbis_comment };
            },
            .picture => {
                try self.bit_reader.alignReader();
                const picture = try metadata.block.Picture.createFromReader(
                    self.bit_reader.reader,
                    alloc,
                );
                std.debug.print("Image type: {s} | description: {s}\n", .{
                    picture.media_type_string,
                    picture.picture_description,
                });
                return .{ .picture = picture };
            },
            .application => {
                try self.bit_reader.alignReader();
                const app = try metadata.block.Application.createFromReader(
                    self.bit_reader.reader,
                    alloc,
                    block_header.size_of_metadata_block,
                );
                return .{ .application = app };
            },
            .padding => {
                try self.bit_reader.reader.discardAll(block_header.size_of_metadata_block);
                return .{ .padding = {} };
            },
            .cuesheet => {
                const cue_sheet = try metadata.block.CueSheet.createFromReader(
                    &self.bit_reader,
                    alloc,
                );

                std.debug.print("CUE TRACKS:\n", .{});
                for (cue_sheet.tracks) |x| {
                    std.debug.print("{s} @ {d}\n", .{ x.ISRC, x.track_offset });
                }

                return .{ .cuesheet = cue_sheet };
            },
            .forbidden => {
                return DecoderError.forbidden;
            },
            // else => {
            //     try self.bit_reader.reader.discardAll(block_header.size_of_metadata_block);
            //     std.debug.print("Unhandled Block Type: {}\n", .{
            //         block_header.metadata_block_type,
            //     });
            //     return DecoderError.unhandled_metadata_block_type;
            // },
        }
    }
};

test "read_magic" {
    const reader = std.Io.Reader.fixed("fLaC");
    var dec = Decoder.init(reader, std.testing.allocator);

    try dec.read_magic();
}
