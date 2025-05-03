const std = @import("std");

// all fields of S must be integer types
pub fn getBlockFromReader(comptime S: type, reader: std.io.AnyReader) !S {
    var br = std.io.bitReader(.big, reader);

    var out: S = undefined;
    inline for (std.meta.fields(S)) |f| {
        @field(out, f.name) = try br.readBitsNoEof(f.type, @bitSizeOf(f.type));
    }

    return out;
}

pub const Header = packed struct {
    is_last_block: u1,
    metadata_block_type: u7,
    size_of_metadata_block: u24,

    test "check_size" {
        std.testing.expectEqual(@bitSizeOf(@This()), 32);
    }
};

pub const StreamInfo = packed struct {
    minimum_block_size: u16,
    maximum_block_size: u16,
    minimum_frame_size: u24,
    maximum_frame_size: u24,
    sample_rate: u20,
    number_of_channels: u3,
    bits_per_sample: u5,
    number_of_interchannel_samples: u36,
    md5_checksum: u128,

    test "check_size" {
        std.testing.expectEqual(@bitSizeOf(@This()), 32);
    }
};
