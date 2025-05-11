pub const Frame = packed struct {
    frame_sync: u15,
    blocking_strategy: u1,
    block_size: u4,
    sample_rate: u4,
    channels_bits: u4,
    bit_depth: u3,
    reserved_bit_must_be_zero: u1,
};
