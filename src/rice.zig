const std = @import("std");
const tracy = @import("tracy");
const frame = @import("frame/frame.zig");
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
        return ret;
    }
};
//

pub inline fn unfold_residual(res: u32) i32 {
    // for more information: https://docs.rs/residua-zigzag/latest/zigzag/
    return @as(i32, @intCast(res >> 1)) ^ -@as(i32, @intCast(res & 1));
}

test "check fold residual" {
    const expecteq = std.testing.expectEqual;

    try expecteq(0, unfold_residual(0));
    try expecteq(-1, unfold_residual(1));
    try expecteq(1, unfold_residual(2));
    try expecteq(-2, unfold_residual(3));
    try expecteq(2, unfold_residual(4));

    try expecteq(unfold_residual(6388), 3194);
    try expecteq(unfold_residual(2593), -1297);
    try expecteq(unfold_residual(2456), 1228);
    try expecteq(unfold_residual(1885), -943);
    try expecteq(unfold_residual(1904), 952);
    try expecteq(unfold_residual(1391), -696);
    try expecteq(unfold_residual(1536), 768);
    try expecteq(unfold_residual(1047), -524);
    try expecteq(unfold_residual(1198), 599);
    try expecteq(unfold_residual(801), -401);
    try expecteq(unfold_residual(26343), -13172);
    try expecteq(unfold_residual(631), -316);
    try expecteq(unfold_residual(548), 274);
    try expecteq(unfold_residual(533), -267);
    try expecteq(unfold_residual(268), 134);
}

pub fn readRiceSignedBlock(br: frame.ReaderToCRCWriter, vals: []i32, partition_parameter: u5) !void {
    const partition_zone = tracy.ZoneN(@src(), "Read Rice Signed Block/Partition");
    defer partition_zone.End();
    if (partition_parameter == 0) {
        //
        for (0..vals.len) |i| {
            const quotient = try br.readUnary();
            vals[i] = unfold_residual(quotient);
        }
        return;
    }

    for (0..vals.len) |i| {
        const quotient = try br.readUnary();
        const remainder = try br.readBitsNoEof(u32, partition_parameter);
        vals[i] = unfold_residual((quotient << partition_parameter) | remainder);
    }
    return;
}

pub fn readRicePartitionsIntoResidualBuffer(br: frame.ReaderToCRCWriter, block_size: u16, predictor_order: u6, coded_residual: CodedResidual, residuals: []i32) !void {
    const num_partitions: u16 = @as(u16, 1) << coded_residual.order;
    const number_of_samples_per_partition = block_size >> coded_residual.order;

    var current_sample: u16 = predictor_order;

    for (0..num_partitions) |partition_idx| {
        const current_partition = try Partition.readPartition(br, coded_residual);
        const number_of_samples_in_this_partition = if (partition_idx == 0) number_of_samples_per_partition - predictor_order else number_of_samples_per_partition;

        if (!current_partition.escaped) {
            // not escaped partition
            // process the next N samples
            try readRiceSignedBlock(
                br,
                residuals[current_sample..(current_sample + number_of_samples_in_this_partition)],
                current_partition.parameter,
            );

            current_sample += number_of_samples_in_this_partition;
        } else {
            // escaped partition

            if (current_partition.parameter == 0) {
                // all zeroes
                @memset(residuals[current_sample..(current_sample + number_of_samples_in_this_partition)], 0);

                current_sample += number_of_samples_in_this_partition;
            } else {
                // read the escaped values as twos complement into residual
                for (0..number_of_samples_in_this_partition) |_| {
                    residuals[current_sample] = try util.readTwosComplementIntegerOfSetBits(
                        br,
                        i32,
                        current_partition.parameter,
                    );

                    current_sample += 1;
                }
            }
        }
    }
}
