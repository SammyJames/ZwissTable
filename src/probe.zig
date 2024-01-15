//!

const std = @import("std");
const enums = @import("enums.zig");

const OperationMode = enums.OperationMode;

pub fn Probe(comptime M: OperationMode) type {
    return struct {
        const Self = @This();
        const Width = M.vectorWidth();

        position: usize,
        stride: usize,

        pub inline fn init(position: usize, stride: usize) Self {
            return .{
                .position = position,
                .stride = stride,
            };
        }

        pub inline fn next(self: *Self, mask: usize) ?usize {
            if (self.stride > mask) return null;

            const result = self.position;

            self.stride += Width;
            self.position += self.stride;
            self.position &= mask;

            return result;
        }
    };
}
