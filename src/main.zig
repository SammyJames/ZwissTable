const std = @import("std");
const lib = @import("lib.zig");

const RndGen = std.rand.DefaultPrng;

fn test_swiss(alloc: std.mem.Allocator, rnd: *RndGen) !void {
    var test_set = lib.AutoHashMap(u64, f64).init(alloc);

    var maybe_last: ?u64 = null;
    for (0..1024 * 1024 * 8) |i| {
        const generated = rnd.random().int(u64);
        const added = try test_set.add(generated, 0.1);

        if (maybe_last) |last| {
            const removed = test_set.remove(last);
            std.debug.assert(removed);
            maybe_last = null;
        }

        if (i % 3 == 0 and added) {
            maybe_last = generated;
        }
    }
}

fn test_std(alloc: std.mem.Allocator, rnd: *RndGen) !void {
    var test_set = std.AutoHashMap(u64, f64).init(alloc);

    var maybe_last: ?u64 = null;
    for (0..1024 * 1024 * 8) |i| {
        const generated = rnd.random().int(u64);
        try test_set.put(generated, 0.1);

        if (maybe_last) |last| {
            const removed = test_set.remove(last);
            std.debug.assert(removed);
            maybe_last = null;
        }

        if (i % 3 == 0) {
            maybe_last = generated;
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    var rnd = RndGen.init(0);
    {
        const start = try std.time.Instant.now();
        try test_swiss(arena.allocator(), &rnd);
        const end = try std.time.Instant.now();
        std.debug.print(
            "swiss: {}ms\n",
            .{end.since(start) / 1_000_000},
        );
    }

    {
        const start = try std.time.Instant.now();
        try test_std(arena.allocator(), &rnd);
        const end = try std.time.Instant.now();
        std.debug.print(
            "std: {}ms\n",
            .{end.since(start) / 1_000_000},
        );
    }
}
