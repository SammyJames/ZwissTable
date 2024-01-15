const std = @import("std");
const set = @import("set.zig");

const RndGen = std.rand.DefaultPrng;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    var test_set = set.AutoHashSet(u32).init(gpa.allocator());
    defer test_set.deinit();

    var rnd = RndGen.init(0);

    var maybe_last: ?u32 = null;
    for (0..1024 * 1024 * 8) |i| {
        const generated = rnd.random().int(u32);
        //std.debug.print("adding {}\n", .{generated});
        const added = try test_set.add(generated);

        if (maybe_last) |last| {
            //std.debug.print("removing {}\n", .{last});
            const removed = test_set.remove(last);
            std.debug.assert(removed);
            maybe_last = null;
        }

        if (i % 3 == 0 and added) {
            maybe_last = generated;
        }
    }

    std.debug.print("total: {}\n", .{test_set.len});
}
