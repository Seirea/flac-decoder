pub const block = @import("block.zig");
pub const vorbis = @import("vorbis.zig");

pub const MetadataBlock = union(block.Type) {
    streaminfo: block.StreamInfo,
    padding: void,
    application: block.Application,
    seek_table: block.SeekTable,
    vorbis_comment: vorbis.VorbisComment,
    cuesheet: block.CueSheet,
    picture: block.Picture,

    forbidden: void,
};
