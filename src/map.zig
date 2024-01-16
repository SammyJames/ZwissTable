//!

const std = @import("std");
const builtin = @import("builtin");

const enums = @import("enums.zig");
const set = @import("set.zig");

const FlatHashSet = set.FlatHashSet;
const LittleHash = enums.LittleHash;
const OperationMode = enums.OperationMode;

fn Pair(comptime K: type, comptime V: type) type {
    return struct {
        key: K,
        value: V,
    };
}

pub fn AutoHashMap(comptime K: type, comptime V: type) type {
    return FlatHashMap(K, V, AutoMapContext(K, V));
}

pub fn FlatHashMap(comptime K: type, comptime V: type, comptime Ctx: type) type {
    return struct {
        const Self = @This();
        const SetType = Pair(K, V);

        set: FlatHashSet(SetType, Ctx),

        pub inline fn init(alloc: std.mem.Allocator) Self {
            return .{
                .set = FlatHashSet(SetType, Ctx).init(alloc),
            };
        }

        pub inline fn deinit(self: *Self) void {
            self.set.deinit();
        }

        pub inline fn add(self: *Self, k: K, v: V) !bool {
            return self.set.add(.{
                .key = k,
                .value = v,
            });
        }

        pub inline fn findOrAdd(self: *Self, k: K) !*V {
            const val: Pair(K, V) = .{
                .key = k,
                .value = undefined,
            };

            var opt_idx = self.set.indexOf(val);
            if (opt_idx == null) {
                if (try self.set.add(val)) {
                    opt_idx = self.set.indexOf(val);
                }
            }

            if (opt_idx) |idx| {
                return &self.set.big[idx].value;
            }

            return error.Whoops;
        }

        pub inline fn get(self: *const Self, k: K) ?V {
            const opt_idx = self.set.indexOf(.{
                .key = k,
                .value = undefined,
            });

            if (opt_idx) |idx| {
                return self.set.big[idx].value;
            }

            return null;
        }

        pub inline fn getPtr(self: *Self, k: K) ?*V {
            const opt_idx = self.set.indexOf(.{
                .key = k,
                .value = undefined,
            });

            if (opt_idx) |idx| {
                return &self.set.big[idx].value;
            }

            return null;
        }

        pub inline fn contains(self: *const Self, k: K) bool {
            return self.set.contains(.{
                .key = k,
                .value = undefined,
            });
        }

        pub inline fn remove(self: *Self, k: K) bool {
            return self.set.remove(.{
                .key = k,
                .value = undefined,
            });
        }

        pub inline fn removeShrink(self: *Self, k: K) !bool {
            return self.set.removeShrink(.{
                .key = k,
                .value = undefined,
            });
        }

        pub inline fn trim(self: *Self) !void {
            return self.set.trim();
        }
    };
}

pub fn AutoMapContext(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const SetType = Pair(K, V);

        pub const Mode = detect: {
            const x86 = std.Target.x86;
            if (x86.featureSetHas(builtin.cpu.features, .avx512f))
                break :detect OperationMode.AVX_512;

            if (x86.featureSetHas(builtin.cpu.features, .avx2))
                break :detect OperationMode.AVX_2;

            if (x86.featureSetHas(builtin.cpu.features, .sse4_2))
                break :detect OperationMode.SSE_4_2;

            break :detect OperationMode.Unsupported;
        };

        pub fn hash(self: Self, v: SetType) u64 {
            const key_hasher = std.hash_map.getAutoHashFn(K, Self);
            return key_hasher(self, v.key);
        }

        pub fn eq(self: Self, lhs: SetType, rhs: SetType) bool {
            const key_eq = std.hash_map.getAutoEqlFn(K, Self);
            return key_eq(self, lhs.key, rhs.key);
        }

        pub const grow = set.getAutoGrowFn(Self);
        pub const shrink = set.getAutoShrinkFn(Self);
    };
}

test "FlatHashMap init" {
    var map = AutoHashMap(u32, f32).init(std.testing.allocator);
    defer map.deinit();
}

test "FlatHashMap add" {
    var map = AutoHashMap(u32, f32).init(std.testing.allocator);
    defer map.deinit();
    try std.testing.expect(try map.add(0xFFFF_FFFF, 0.1));
}

test "FlatHashMap findOrAdd" {
    var map = AutoHashMap(u32, f32).init(std.testing.allocator);
    defer map.deinit();

    try std.testing.expect(try map.add(0xFFFF_FFFF, 0.0));

    const spot = try map.findOrAdd(0xFFFF_FFFF);
    spot.* = 0.1;

    try std.testing.expect(map.contains(0xFFFF_FFFF));
    try std.testing.expectEqual(map.get(0xFFFF_FFFF) orelse 0.0, 0.1);
}

test "FlatHashMap get" {
    var map = AutoHashMap(u32, f32).init(std.testing.allocator);
    defer map.deinit();

    try std.testing.expect(try map.add(0xFFFF_FFFF, 0.1));
    try std.testing.expect(map.contains(0xFFFF_FFFF));

    const found = map.getPtr(0xFFFF_FFFF);
    if (found) |f| {
        try std.testing.expectEqual(
            f.*,
            0.1,
        );
    }
}

test "FlatHashMap getPtr" {
    var map = AutoHashMap(u32, f32).init(std.testing.allocator);
    defer map.deinit();

    try std.testing.expect(try map.add(0xFFFF_FFFF, 0.1));
    try std.testing.expect(map.contains(0xFFFF_FFFF));

    try std.testing.expectEqual(
        map.get(0xFFFF_FFFF) orelse 0.0,
        0.1,
    );
}

test "FlatHashMap contains" {
    var map = AutoHashMap(u32, f32).init(std.testing.allocator);
    defer map.deinit();
    try std.testing.expect(try map.add(0xFFFF_FFFF, 0.1));
    try std.testing.expect(map.contains(0xFFFF_FFFF));
}

test "FlatHashMap remove" {
    var map = AutoHashMap(u32, f32).init(std.testing.allocator);
    defer map.deinit();

    try std.testing.expect(try map.add(0xFFFF_FFFF, 0.1));
    try std.testing.expect(map.contains(0xFFFF_FFFF));

    try std.testing.expect(map.remove(0xFFFF_FFFF));
    try std.testing.expect(!map.contains(0xFFFF_FFFF));
}

test "FlatHashMap random 1024*1024" {
    const RndGen = std.rand.DefaultPrng;

    var map = AutoHashMap(u32, f32).init(std.testing.allocator);
    defer map.deinit();

    var rnd = RndGen.init(0);

    var maybe_last: ?u32 = null;
    for (0..1024 * 1024) |i| {
        const generated = rnd.random().int(u32);
        const added = try map.add(generated, 0.0);

        if (maybe_last) |last| {
            //std.debug.print("removing {}\n", .{last});
            try std.testing.expect(map.remove(last));
            maybe_last = null;
        }

        if (i % 3 == 0 and added) {
            maybe_last = generated;
        }
    }
}
