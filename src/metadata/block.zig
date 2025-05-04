const std = @import("std");

// all fields of S must be integer types
pub fn getBlockFromReader(comptime S: type, reader: std.io.AnyReader) !S {
    var br = std.io.bitReader(.big, reader);

    var out: S = undefined;
    inline for (std.meta.fields(S)) |f| {
        switch (@typeInfo(f.type)) {
            .@"enum" => {
                const int_representation = @typeInfo(f.type).@"enum".tag_type;
                @field(out, f.name) = @enumFromInt(try br.readBitsNoEof(
                    int_representation,
                    @bitSizeOf(int_representation),
                ));
            },
            .array => {},
            else => {
                @field(out, f.name) = try br.readBitsNoEof(f.type, @bitSizeOf(f.type));
            },
        }
    }

    return out;
}

pub const Type = enum(u7) {
    streaminfo = 0,
    padding = 1,
    application = 2,
    seek_table = 3,
    vorbis_comment = 4,
    cuesheet = 5,
    picture = 6,
    // reserved 7-126 (as of today)
    forbidden = 127,
};

pub const Header = packed struct {
    is_last_block: u1,
    metadata_block_type: Type,
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

pub const SeekTable = packed struct {
    seek_points: []SeekPoint,

    pub const SeekPoint = packed struct {
        sample_number_of_first_sample_in_target_frame: u64,
        offset_from_first_byte_of_first_frame_header: u64,
        number_of_samples: u16,
    };
};
