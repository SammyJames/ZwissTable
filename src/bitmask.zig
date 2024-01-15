//!

const std = @import("std");

pub fn Bitmask(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,

        pub inline fn init(value: T) Self {
            return .{
                .value = value,
            };
        }

        pub inline fn leadingZeros(self: Self) T {
            return @clz(self.value);
        }

        pub inline fn trailingZeros(self: Self) T {
            return @ctz(self.value);
        }

        pub inline fn next(self: *Self) ?T {
            if (self.value == 0) return null;

            const next_index = @ctz(self.value);
            self.value &= self.value - 1;
            return next_index;
        }

        pub inline fn isValid(self: Self) bool {
            return self.value != 0;
        }
    };
}
