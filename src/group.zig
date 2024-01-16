//!

const std = @import("std");
const enums = @import("enums.zig");

const OperationMode = enums.OperationMode;
const LittleHash = enums.LittleHash;

pub fn Group(comptime M: OperationMode) type {
    return struct {
        const Self = @This();
        const VecType = M.vectorType();
        const MaskType = M.maskType();

        value: VecType,

        pub inline fn init(lil: []const LittleHash) Self {
            return .{
                .value = M.load(lil),
            };
        }

        pub inline fn match(self: *const Self, lil: LittleHash) MaskType {
            const to_match: VecType = @splat(lil.value);
            return MaskType.init(@bitCast(self.value == to_match));
        }

        pub inline fn matchEmpty(self: *const Self) MaskType {
            const to_match: VecType = @splat(LittleHash.Empty.value);
            return MaskType.init(@bitCast(self.value == to_match));
        }

        pub inline fn matchEmptyOrDeleted(self: *const Self) MaskType {
            const deleted: VecType = @splat(LittleHash.Deleted.value);
            const result = self.value >= deleted;
            return MaskType.init(@bitCast(result));
        }

        pub inline fn convertForRehash(self: *const Self) Self {
            const zero: VecType = @splat(0);
            const special: @Vector(M.vectorWidth(), bool) = zero > self.value;
            const tester: VecType = @splat('\x80');
            return .{ .value = @select(u8, special, tester, zero) };
        }

        pub inline fn store(self: *const Self, dest: *[M.vectorWidth()]u8) void {
            dest.* = self.value;
        }
    };
}

test "Group Match" {
    const Mode = OperationMode.SSE_4_2;

    const empties = Mode.generate(LittleHash.Empty);
    const test_group = Group(Mode).init(&empties);

    var mask = test_group.match(LittleHash.Empty);

    var count: usize = 0;
    while (mask.next()) |i| {
        _ = i; // autofix
        count += 1;
    }

    try std.testing.expectEqual(count, Mode.vectorWidth());
}

test "Group Match Empty" {
    const Mode = OperationMode.SSE_4_2;
    const empties = Mode.generate(LittleHash.Empty);
    const test_group = Group(Mode).init(&empties);

    var mask = test_group.matchEmpty();

    var count: usize = 0;
    while (mask.next()) |i| {
        _ = i; // autofix
        count += 1;
    }

    try std.testing.expectEqual(count, Mode.vectorWidth());
}
