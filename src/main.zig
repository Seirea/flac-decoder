const std = @import("std");
const lib = @import("flac_decoder_lib");

pub const Signature = extern struct {
    sig: [4]u8,
};

const allocator = std.heap.smp_allocator;

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
            lib.metadata.block.Type.streaminfo => {
                const stream_info = try lib.metadata.block.getBlockFromReader(
                    lib.metadata.block.StreamInfo,
                    file_reader.any(),
                );
                std.debug.print("StreamInfo Block: {}\n", .{stream_info});
            },
            else => {
                const buf = try allocator.alloc(u8, block_header.size_of_metadata_block);
                _ = try file_reader.read(buf);
                std.debug.print("Unhandled Block Type: {b}\n", .{
                    buf,
                });
            },
        }

        if (block_header.is_last_block == 1) {
            break;
        }
    }

    file.close();
    // file_reader.readStruct(comptime T: type)
}
