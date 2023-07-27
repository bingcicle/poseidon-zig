const std = @import("std");
const parameters = @import("parameters.zig");

const testing = std.testing;
const ff = std.crypto.ff;
const Modulus = ff.Modulus;
const ROUND_CONSTANTS = parameters.ROUND_CONSTANTS;
const MDS_MATRIX = parameters.MDS_MATRIX;

/// Configurations for an instantiation of Poseidon.
pub const PoseidonConfig = struct {
    t: usize = 5,
    num_full_rounds: usize = 8,
    num_partial_rounds: usize = 60,
};

/// Poseidon hash function, as seen in https://eprint.iacr.org/2019/458.pdf
pub fn Poseidon(comptime M: type, comptime prime: u256) type {
    return struct {
        const Self = @This();

        config: PoseidonConfig,
        modulus: M,

        pub fn init(config: PoseidonConfig) !Self {
            return Self{
                .config = config,
                .modulus = try M.fromPrimitive(u256, prime),
            };
        }

        fn addRoundConstants(self: Self, words: []M.Fe, rc_counter: *usize) !void {
            for (0..self.config.t) |i| {
                var rc = try M.Fe.fromPrimitive(u256, self.modulus, ROUND_CONSTANTS[rc_counter.*]);

                words[i] = self.modulus.add(words[i], rc);
                rc_counter.* += 1;
            }
        }

        fn sbox(self: Self, words: []M.Fe, i: usize) !void {
            var t_f = try M.Fe.fromPrimitive(u256, self.modulus, self.config.t);
            words[i] = try self.modulus.pow(words[i], t_f);
        }

        fn mixLayer(self: Self, words: []M.Fe) !void {
            var new_words = [_]M.Fe{try M.Fe.fromPrimitive(u256, self.modulus, 0)} ** 5;
            var matrix = MDS_MATRIX;

            for (0..self.config.t) |i| {
                for (0..self.config.t) |j| {
                    var mij_mul_word_j = self.modulus.mul(
                        try M.Fe.fromPrimitive(u256, self.modulus, matrix[i][j]),
                        words[j],
                    );
                    matrix[i][j] = try mij_mul_word_j.toPrimitive(u256);

                    new_words[i] = self.modulus.add(new_words[i], mij_mul_word_j);
                }
            }

            std.mem.copyForwards(M.Fe, words, &new_words);
        }

        /// Carries out the actual Poseidon permutation.
        pub fn permute(self: Self, input_words: []M.Fe) ![]M.Fe {
            var R_f = self.config.num_full_rounds / 2;
            var round_constants_counter: usize = 0;
            var state_words = input_words;

            for (0..R_f) |_| {
                try self.addRoundConstants(state_words, &round_constants_counter);
                for (0..self.config.t) |i| {
                    try self.sbox(state_words, i);
                }
                try self.mixLayer(state_words);
            }

            for (0..self.config.num_partial_rounds) |_| {
                try self.addRoundConstants(state_words, &round_constants_counter);
                try self.sbox(state_words, 0);
                try self.mixLayer(state_words);
            }

            for (0..R_f) |_| {
                try self.addRoundConstants(state_words, &round_constants_counter);
                for (0..self.config.t) |i| {
                    try self.sbox(state_words, i);
                }
                try self.mixLayer(state_words);
            }

            return state_words;
        }
    };
}

test "basic poseidon - test vector(poseidonperm_x5_255_5)" {
    // Values from https://extgit.iaik.tugraz.at/krypto/hadeshash/-/blob/master/code/test_vectors.txt
    const prime = 0x73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001;

    const M = Modulus(256);
    const Fe = M.Fe;
    const m = try M.fromPrimitive(u256, prime);

    const expected = [5]M.Fe{
        try Fe.fromPrimitive(u256, m, 0x2a918b9c9f9bd7bb509331c81e297b5707f6fc7393dcee1b13901a0b22202e18),
        try Fe.fromPrimitive(u256, m, 0x65ebf8671739eeb11fb217f2d5c5bf4a0c3f210e3f3cd3b08b5db75675d797f7),
        try Fe.fromPrimitive(u256, m, 0x2cc176fc26bc70737a696a9dfd1b636ce360ee76926d182390cdb7459cf585ce),
        try Fe.fromPrimitive(u256, m, 0x4dc4e29d283afd2a491fe6aef122b9a968e74eff05341f3cc23fda1781dcb566),
        try Fe.fromPrimitive(u256, m, 0x03ff622da276830b9451b88b85e6184fd6ae15c8ab3ee25a5667be8592cce3b1),
    };

    var input_words = [_]M.Fe{try M.Fe.fromPrimitive(u256, m, 0)} ** 5;
    for (0..5) |i| {
        input_words[i] = try M.Fe.fromPrimitive(u256, m, i);
    }

    var poseidon = try Poseidon(M, prime).init(.{});
    var output = try poseidon.permute(&input_words);

    try std.testing.expectEqualSlices(M.Fe, output, &expected);
}
