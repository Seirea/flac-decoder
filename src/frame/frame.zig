const std = @import("std");

const ParsingBlockSize = enum(u4) {
    _reserved = 0,
    @"192" = 1,
    @"576" = 2,
    @"1152" = 3,
    @"2304" = 4,
    @"4608" = 5,
    uncommon_8bit = 6,
    uncommon_16bit = 7,
    @"256" = 8,
    @"512" = 9,
    @"1024" = 10,
    @"2048" = 11,
    @"4096" = 12,
    @"8192" = 13,
    @"16384" = 14,
    @"32768" = 15,
};

// in kHz
const ParsingSampleRate = enum(u4) {
    in_streaminfo = 0,
    @"88.2" = 1,
    @"176.4" = 2,
    @"192" = 3,
    @"8" = 4,
    @"16" = 5,
    @"22.05" = 6,
    @"24" = 7,
    @"32" = 8,
    @"44.1" = 9,
    @"48" = 10,
    @"96" = 11,
    uncommon_8bit = 12,
    uncommon_16bit = 13,
    uncommon_16bit_div_10 = 14,
    forbidden = 15,
};

const ParsingChannel = enum(u4) {
    mono = 0,
    stero,
    three,
    four,
    five,
    six,
    seven,
    eight,
    left_side,
    side_right,
    mid_side,
};

const ParsingBitDepth = enum(u3) {
    in_streaminfo = 0b000,
    @"8-bit" = 0b001,
    @"12-bit" = 0b010,
    reserved = 0b011,
    @"16-bit" = 0b100,
    @"20-bit" = 0b101,
    @"24-bit" = 0b110,
    @"32-bit" = 0b111,
};

const ParsingFrameHeader = packed struct {
    _sync_code: u15 = 0b111111111111100,
    blocking_strategy: bool, // 0 is fixed block size, 1 is variable
    block_size_1: ParsingBlockSize, // wtf
    sample_rate: ParsingSampleRate,
    channel: ParsingChannel,
    bit_depth: ParsingBitDepth,
};

const SubFrame = struct {};
