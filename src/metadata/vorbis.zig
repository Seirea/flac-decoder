const std = @import("std");
const bit_reader = @import("../bit_reader.zig");

pub const VorbisComment = struct {
    vendor_string: []u8,
    user_comments: []Comment,

    pub const Comment = []u8;

    // TODO: add block size parameter for data validation
    pub fn createFromReader(reader: *std.Io.Reader, alloc: std.mem.Allocator) !VorbisComment {
        var ret: VorbisComment = undefined;

        const vendor_length = try reader.takeInt(u32, .little);
        ret.vendor_string = try alloc.alloc(u8, vendor_length);
        try reader.readSliceAll(ret.vendor_string);

        const user_comment_list_length = try reader.takeInt(u32, .little);
        ret.user_comments = try alloc.alloc(Comment, user_comment_list_length);

        for (0..user_comment_list_length) |i| {
            const comment_length = try reader.takeInt(u32, .little);
            ret.user_comments[i] = try alloc.alloc(u8, comment_length);
            try reader.readSliceAll(ret.user_comments[i]);
        }

        return ret;
    }
};
