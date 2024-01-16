//!

const std = @import("std");
const Bitmask = @import("bitmask.zig").Bitmask;

/// A strongly typed wrapper around a u8 used to represent the state of an
/// element in the tightly packed little hash used for lookup
pub const LittleHash = packed struct {
    const Self = @This();
    pub const Empty: Self = .{
        .value = 0b1111_1111,
    };
    pub const Deleted: Self = .{
        .value = 0b1000_0000,
    };

    value: u8,

    pub fn init(v: u8) Self {
        return .{
            .value = v,
        };
    }

    pub inline fn from(v: u64) Self {
        return .{
            .value = @as(u8, @truncate(v)) & 0x7f,
        };
    }

    pub inline fn isSpecial(self: Self) bool {
        return (self.value & 0x80) != 0;
    }

    pub inline fn isFull(self: Self) bool {
        return (self.value & 0x80) == 0;
    }

    pub inline fn isEmpty(self: Self) bool {
        return isSpecial(self) and (self.value & 0x01) != 0;
    }

    pub inline fn isDeleted(self: Self) bool {
        return self.value == Self.Deleted.value;
    }
};

/// Determines the width of vectors
pub const OperationMode = enum {
    const Self = @This();

    /// you're fugged
    Unsupported,
    /// 16 byte wide buckets
    SSE_4_2,
    /// 32 byte wide buckets
    AVX_2,
    /// 64 byte wide buckets
    AVX_512,

    pub inline fn vectorWidth(comptime self: Self) comptime_int {
        return switch (self) {
            .Unsupported => 8,
            .SSE_4_2 => 16,
            .AVX_2 => 32,
            .AVX_512 => 64,
        };
    }

    pub inline fn maskType(comptime self: Self) type {
        return switch (self) {
            .Unsupported => Bitmask(u8),
            .SSE_4_2 => Bitmask(u16),
            .AVX_2 => Bitmask(u32),
            .AVX_512 => Bitmask(u64),
        };
    }

    pub inline fn vectorType(comptime self: Self) type {
        return @Vector(vectorWidth(self), u8);
    }

    pub inline fn load(comptime self: Self, vals: []const LittleHash) vectorType(self) {
        const result: vectorType(self) = @bitCast(vals[0..][0..vectorWidth(self)].*);
        return result;
    }

    pub inline fn generate(comptime self: Self, val: LittleHash) [vectorWidth(self)]LittleHash {
        var res: [vectorWidth(self)]LittleHash = undefined;
        inline for (&res) |*v| {
            v.* = val;
        }
        return res;
    }
};

test "Load SSE4.2" {
    const keys: [16]LittleHash = [_]LittleHash{
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
    };
    const res = OperationMode.SSE_4_2.load(
        &keys,
    );
    const cond: OperationMode.SSE_4_2.vectorType() = @splat(
        @bitCast(LittleHash.from(0)),
    );
    const eql = res == cond;
    try std.testing.expectEqual(@reduce(.And, eql), false);
}

test "Load AVX2" {
    const keys: [32]LittleHash = [_]LittleHash{
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
    };
    const res = OperationMode.AVX_2.load(
        &keys,
    );
    const cond: OperationMode.AVX_2.vectorType() = @splat(
        @bitCast(LittleHash.from(0)),
    );

    const eql = res == cond;
    try std.testing.expectEqual(@reduce(.And, eql), false);
}

test "Load AVX512" {
    const keys: [64]LittleHash = [_]LittleHash{
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
    };
    const res = OperationMode.AVX_512.load(
        &keys,
    );
    const cond: OperationMode.AVX_512.vectorType() = @splat(
        @bitCast(LittleHash.from(0)),
    );

    const eql = res == cond;
    try std.testing.expectEqual(@reduce(.And, eql), false);
}

test "Generate" {
    const generated = OperationMode.SSE_4_2.generate(LittleHash.Empty);
    try std.testing.expectEqual(generated.len, OperationMode.SSE_4_2.vectorWidth());

    const generated_loaded = OperationMode.SSE_4_2.load(&generated);

    const keys: [16]LittleHash = [_]LittleHash{
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
        LittleHash.Empty, LittleHash.Empty, LittleHash.Empty, LittleHash.Empty,
    };
    const keys_loaded = OperationMode.SSE_4_2.load(
        &keys,
    );
    const eql = generated_loaded == keys_loaded;
    try std.testing.expect(@reduce(.And, eql));
}
