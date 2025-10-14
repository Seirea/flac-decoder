const std = @import("std");
const flac = @import("flac_decoder_lib");
// var tracy_allocator = tracy.TracyAllocator.init(std.heap.smp_allocator);

const allocator = std.heap.smp_allocator;
pub fn main() !void {
    var args = try std.process.ArgIterator.initWithAllocator(allocator);
    _ = args.next(); // skip the executable
    const path = args.next() orelse "test/test.flac";
    std.debug.print("Opening: {s}\n", .{path});
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // read metadata

    var buf: [16384]u8 = undefined;
    var lol = file.reader(&buf);
    const reader: *std.Io.Reader = &lol.interface;

    var decoder = flac.Decoder.init(reader);

    try decoder.read_magic();

    var metadata_arena = std.heap.ArenaAllocator.init(allocator);
    while (try decoder.read_metadata(metadata_arena.allocator())) |x| {
        // std.debug.print("Captured {}!\n", .{x});
        _ = x;
    }

    std.debug.print("Metadata read\n", .{});
    metadata_arena.deinit();

    const out_wav = try std.fs.cwd().createFile("out.wav", .{});
    defer out_wav.close();

    var writer_buf: [16384]u8 = undefined;
    var writer = out_wav.writer(&writer_buf);

    var frame_arena = std.heap.ArenaAllocator.init(allocator);
    try decoder.write_wav_data(&frame_arena, &writer.interface);

    std.debug.print("Done\n", .{});
}
