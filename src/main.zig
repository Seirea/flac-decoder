const std = @import("std");
const lib = @import("flac_decoder_lib");

pub const Signature = extern struct {
    sig: [4]u8,
};

const allocator = std.heap.smp_allocator;

pub fn main() !void {
    const file = try std.fs.cwd().openFile("test/a.flac", .{});
    const file_reader = file.reader();

    const sig: Signature = try file_reader.readStruct(Signature);
    std.debug.print("{s}\n", sig);

    if (!std.mem.eql(u8, &sig.sig, "fLaC")) {
        @panic("FLAC Magic Bytes mismatch! Is this a FLAC File?");
    }

    var metadata_arena = std.heap.ArenaAllocator.init(allocator);

    var stream_info: ?lib.metadata.block.StreamInfo = null;

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
                stream_info = try lib.metadata.block.getBlockFromReader(
                    lib.metadata.block.StreamInfo,
                    file_reader.any(),
                );

                std.debug.print("StreamInfo Block: {}\n", .{stream_info});
            },
            .seek_table => {
                const seek_table = try lib.metadata.block.SeekTable.createFromReader(
                    file_reader.any(),
                    metadata_arena.allocator(),
                    block_header.size_of_metadata_block,
                );

                std.debug.print("[{d}] SeekTable Block: {}\n", .{ seek_table.seek_points.len, seek_table });
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
    var frame_arena = std.heap.ArenaAllocator.init(allocator);

    while (lib.frame.Frame.parseFrame(file_reader.any(), frame_arena.allocator(), stream_info) catch null) |x| {
        std.debug.print("READ FRAME {}\n", .{x});
    }
    frame_arena.deinit();

    // std.debug.print("Reading frame 1\n", .{});

    // const frame = try lib.frame.FrameHeader.parseFrameHeader(file_reader.any());
    // std.debug.print("PARSED FRAME: {}\n", .{frame});

    file.close();
    // file_reader.readStruct(comptime T: type)
}
