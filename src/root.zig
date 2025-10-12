const std = @import("std");

pub const metadata = @import("metadata/metadata.zig");
pub const frame = @import("frame/frame.zig");
pub const bit_reader = @import("bit_reader.zig");

pub const DecoderError = error{
    magic_bytes_mismatch,
} || frame.FrameParsingError;

pub const Decoder = struct {
    stream_info: ?metadata.block.StreamInfo = null,
    reader: std.Io.Reader,
    bit_reader: bit_reader.AnyBitReader,
    metadata_done: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(reader: std.Io.Reader, alloc: std.mem.Allocator) Decoder {
        return .{
            .reader = reader,
            .bit_reader = bit_reader.bitReader(.big, reader),
            .allocator = alloc,
        };
    }

    pub fn read_magic(self: *Decoder) !void {
        const sig: []u8 = try self.reader.take(4);
        std.debug.print("{s}\n", .{sig});

        if (!std.mem.eql(u8, sig, "fLaC")) {
            return DecoderError.magic_bytes_mismatch;
        }
    }

    pub fn read_metadata(self: *Decoder) !?metadata.MetadataBlock {
        if (self.metadata_done) {
            return null;
        }

        const block_header = try metadata.block.getBlockFromReader(
            metadata.block.Header,
            self.reader,
        );

        // std.debug.print("\n\nblock_header:{}", .{block_header});

        if (block_header.is_last_block) {
            self.metadata_done = true;
        }

        switch (block_header.metadata_block_type) {
            // streaminfo
            .streaminfo => {
                return .{ .streaminfo = try metadata.block.getBlockFromReader(
                    metadata.block.StreamInfo,
                    self.stream.reader().any(),
                ) };
            },
            .seek_table => {
                const seek_table = try metadata.block.SeekTable.createFromReader(
                    self.stream.reader().any(),
                    self.allocator,
                    block_header.size_of_metadata_block,
                );
                // std.debug.print("[{d}] SeekTable Block: {}\n", .{ seek_table.seek_points.len, seek_table });
                return .{ .seek_table = seek_table };
            },
            .vorbis_comment => {
                const vorbis_comment = try metadata.vorbis.VorbisComment.createFromReader(
                    self.stream.reader().any(),
                    self.allocator,
                );
                std.debug.print("Vorbis Comment Vendor String: {s}\n", .{vorbis_comment.vendor_string});
                for (vorbis_comment.user_comments) |x| {
                    std.debug.print("COMMENT: {s}\n", .{x});
                }
                return .{ .vorbis_comment = vorbis_comment };
            },
            .picture => {
                const picture = try metadata.block.Picture.createFromReader(
                    self.stream.reader().any(),
                    self.allocator,
                );
                std.debug.print("Image type: {s} | description: {s}\n", .{
                    picture.media_type_string,
                    picture.picture_description,
                });
                return .{ .picture = picture };
            },
            .application => {
                const app = try metadata.block.Application.createFromReader(
                    self.stream.reader().any(),
                    self.allocator,
                    block_header.size_of_metadata_block,
                );
                std.debug.print("{}", .{app});
                return .{ .application = app };
            },
            .padding => {
                try self.stream.reader().skipBytes(block_header.size_of_metadata_block, .{});
                return .{ .padding = {} };
            },
            .cuesheet => {
                const cue_sheet = try metadata.block.CueSheet.createFromReader(
                    self.stream.reader().any(),
                    self.allocator,
                );

                std.debug.print("CUE TRACKS:\n", .{});
                for (cue_sheet.tracks) |x| {
                    std.debug.print("{s} @ {d}\n", .{ x.ISRC, x.track_offset });
                }
                return .{ .cuesheet = cue_sheet };
            },
            else => {
                try self.stream.reader().skipBytes(block_header.size_of_metadata_block, .{});
                std.debug.print("Unhandled Block Type: {}\n", .{
                    block_header.metadata_block_type,
                });
                return null;
            },
        }
    }
};

test "read_magic" {
    const reader = std.Io.Reader.fixed("fLaC");
    var dec = Decoder.init(reader, std.testing.allocator);

    try dec.read_magic();
}
