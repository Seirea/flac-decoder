const std = @import("std");
const lib = @import("flac_decoder_lib");

pub const Signature = extern struct {
    sig: [4]u8,
};

pub fn main() !void {
    const file = try std.fs.cwd().openFile("test/a.flac", .{});
    const file_reader = file.reader();

    const sig = try file_reader.readStruct(Signature);
    std.debug.print("{s}\n", sig);

    while (true) {
        const block_header = try lib.metadata.block.getBlockFromReader(
            lib.metadata.block.Header,
            file_reader.any(),
        );
        std.debug.print("Metadata Block Header: {}\n", .{block_header});

        switch (block_header.metadata_block_type) {
            // streaminfo
            0 => {
                const stream_info = try lib.metadata.block.getBlockFromReader(
                    lib.metadata.block.StreamInfo,
                    file_reader.any(),
                );
                std.debug.print("StreamInfo Block: {}\n", .{stream_info});
            },
            else => {
                @panic("Unhandled Block Type!");
            },
        }
    }

    file.close();
    // file_reader.readStruct(comptime T: type)
}
