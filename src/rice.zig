const std = @import("std");
const tracy = @import("tracy");
const util = @import("util.zig");

pub const ParameterSize = enum {
    @"4-bits",
    @"5-bits",
};

pub const CodedResidualParsingError = error{using_reserved_coding_method};

pub const CodedResidual = struct {
    // there will be 2 ^ (order) partitions in a coded residual
    order: u4,

    // the number of bits allocated to the Rice Parameter in each partition
    parameter_size: ParameterSize,

    pub fn readCodedResidual(br: anytype) !CodedResidual {
        var out: CodedResidual = undefined;
        const coding_method: u2 = try br.readBitsNoEof(u2, 2);
        out.parameter_size = switch (coding_method) {
            0b00 => .@"4-bits",
            0b01 => .@"5-bits",
            0b10...0b11 => {
                return CodedResidualParsingError.using_reserved_coding_method;
            },
        };

        out.order = try br.readBitsNoEof(u4, 4);

        return out;
    }
};

pub const Partition = struct {
    escaped: bool,
    parameter: u5,

    pub fn readPartition(br: anytype, residual: CodedResidual) !Partition {
        const partition_zone = tracy.Zone.begin(.{
            .name = "READ partition",
            .src = @src(),
            .color = .white,
        });
        const param: u5 = switch (residual.parameter_size) {
            .@"4-bits" => try br.readBitsNoEof(u5, 4),
            .@"5-bits" => try br.readBitsNoEof(u5, 5),
        };

        const escape = switch (residual.parameter_size) {
            .@"4-bits" => param == 0b1111,
            .@"5-bits" => param == 0b11111,
        };

        const ret = Partition{
            .parameter = if (escape) try br.readBitsNoEof(u5, 5) else param,
            .escaped = escape,
        };
        partition_zone.end();
        return ret;
    }

    pub fn readNextResidual(partition: Partition, br: anytype) !i32 {
        if (partition.escaped) {
            return try util.readTwosComplementIntegerOfSetBits(
                br,
                // std.meta.Int(.signed, partition.parameter),
                i32,
                partition.parameter,
            );
        } else {
            // TODO: determine the correct quotient and remainder size
            var quotient: u8 = 0;
            while (try br.readBitsNoEof(u1, 1) == 0) : (quotient += 1) {}
            const remainder = try br.readBitsNoEof(u32, partition.parameter);
            const folded_residual: u32 = (@as(u32, quotient) << partition.parameter) | remainder;
            // std.debug.print("quo: {}, rem: {} => Folded: {}\n", .{ quotient, remainder, folded_residual });
            if (folded_residual % 2 == 0) {
                return @bitCast(folded_residual >> 1);
            } else {
                return @bitCast(~(folded_residual >> 1));
            }
        }
    }
};
//
