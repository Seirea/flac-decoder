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
            .bool => {
                @field(out, f.name) = (try br.readBitsNoEof(u1, @bitSizeOf(u1)) == 1);
            },
            .int => {
                @field(out, f.name) = try br.readBitsNoEof(f.type, @bitSizeOf(f.type));
            },
            else => {
                @compileError("Unimplemented");
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
    is_last_block: bool,
    metadata_block_type: Type,
    size_of_metadata_block: u24,

    test "check header struct size" {
        std.testing.expectEqual(@bitSizeOf(Header), 32);
    }
};

pub const StreamInfo = packed struct {
    minimum_block_size: u16,
    maximum_block_size: u16,
    minimum_frame_size: u24,
    maximum_frame_size: u24,
    sample_rate: u20,
    number_of_channels_minus_one: u3,
    bits_per_sample_minus_one: u5,
    number_of_interchannel_samples: u36,
    md5_checksum: u128,

    test "check streaminfo struct size" {
        std.testing.expectEqual(@sizeOf(StreamInfo), 34);
    }
};

pub const SeekTable = struct {
    seek_points: []SeekPoint,

    pub const SeekPoint = packed struct {
        sample_number_of_first_sample_in_target_frame: u64,
        offset_from_first_byte_of_first_frame_header: u64,
        number_of_samples: u16,
    };

    pub fn createFromReader(reader: std.io.AnyReader, alloc: std.mem.Allocator, block_size: u24) !SeekTable {
        const number_of_seekpoints = block_size / 18;

        var ret = SeekTable{
            .seek_points = try alloc.alloc(SeekPoint, number_of_seekpoints),
        };

        for (0..number_of_seekpoints) |i| {
            ret.seek_points[i] = try getBlockFromReader(SeekPoint, reader);
        }

        return ret;
    }
};

pub const Picture = struct {
    picture_type: u32,
    media_type_string: []u8,
    picture_description: []u8,
    data: PictureData,

    pub const PictureData = struct { width: u32, height: u32, color_depth: u32, number_of_colors_used: u32, data: []u8 };

    // TODO: add block size parameter for data validation
    pub fn createFromReader(reader: std.io.AnyReader, alloc: std.mem.Allocator) !Picture {
        var ret: Picture = undefined;

        ret.picture_type = try reader.readInt(u32, .big);

        const media_type_string_len = try reader.readInt(u32, .big);
        ret.media_type_string = try alloc.alloc(u8, media_type_string_len);
        _ = try reader.readAll(ret.media_type_string);

        const picture_description_len = try reader.readInt(u32, .big);
        ret.picture_description = try alloc.alloc(u8, picture_description_len);
        _ = try reader.readAll(ret.picture_description);

        ret.data = undefined;

        ret.data.width = try reader.readInt(u32, .big);
        ret.data.height = try reader.readInt(u32, .big);
        ret.data.color_depth = try reader.readInt(u32, .big);
        ret.data.number_of_colors_used = try reader.readInt(u32, .big);

        const picture_data_len = try reader.readInt(u32, .big);
        ret.data.data = try alloc.alloc(u8, picture_data_len);

        _ = try reader.readAll(ret.data.data);

        return ret;
    }
};

pub const Application = struct {
    application_id: u32,
    application_data: []u8,

    pub fn createFromReader(reader: std.io.AnyReader, alloc: std.mem.Allocator, block_size: u24) !Application {
        // Application data (n MUST be a multiple of 8, i.e., a whole number of
        // bytes). n is 8 times the size described in the metadata block header
        // minus the 32 bits already used for the application ID.
        var ret: Application = undefined;
        ret.application_id = try reader.readInt(u32, .big);

        const application_data_len = (block_size) - @sizeOf(u32);

        ret.application_data = try alloc.alloc(u8, application_data_len);
        _ = try reader.readAll(ret.application_data);

        return ret;
    }
};

pub const CueSheet = struct {
    media_catalog_num: [128]u8,
    lead_in_samples: u64,
    is_cd_da: bool,

    tracks: []CueTrack,

    pub const CueTrack = struct {
        track_offset: u64,
        track_num: u8,
        ISRC: [12]u8,
        is_audio: bool,
        pre_emphasis: bool,
        index_points: []IndexPoint,
    };
    pub const IndexPoint = struct {
        offset: u64,
        index_point: u8,
    };

    pub fn createFromReader(reader: std.io.AnyReader, alloc: std.mem.Allocator, _: u24) !CueSheet {
        var ret: CueSheet = undefined;
        var br = std.io.bitReader(.big, reader);

        _ = try reader.readAll(&ret.media_catalog_num);

        ret.lead_in_samples = try reader.readInt(u64, .big);

        ret.is_cd_da = try br.readBitsNoEof(u1, @bitSizeOf(u1)) == 1;
        // u(7+258*8) Reserved. All bits MUST be set to zero.
        _ = try br.readBitsNoEof(u1, 7 + 258 * 8);
        // try br.alignToByte();

        const track_count = try reader.readInt(u8, .big);

        ret.tracks = try alloc.alloc(CueTrack, track_count);

        for (0..track_count) |i| {
            ret.tracks[i].track_offset = try reader.readInt(u64, .big);
            ret.tracks[i].track_num = try reader.readInt(u8, .big);
            _ = try reader.readAll(&ret.tracks[i].ISRC);
            ret.tracks[i].is_audio = try br.readBitsNoEof(u1, @bitSizeOf(u1)) == 1;
            ret.tracks[i].pre_emphasis = try br.readBitsNoEof(u1, @bitSizeOf(u1)) == 1;

            //  u(6+13*8) Reserved. All bits MUST be set to zero.
            _ = try br.readBitsNoEof(u1, 6 + 13 * 8);

            // try reader.skipBytes(6 + 13 * 8, .{});
            const index_count = try reader.readInt(u8, .big);

            ret.tracks[i].index_points = try alloc.alloc(IndexPoint, index_count);

            for (0..index_count) |index_point_idx| {
                ret.tracks[i].index_points[index_point_idx].offset = try reader.readInt(u64, .big);
                ret.tracks[i].index_points[index_point_idx].index_point = try reader.readInt(u8, .big);
                try reader.skipBytes(3, .{});
            }
        }
        return ret;
    }
};
