//!

const std = @import("std");
const builtin = @import("builtin");

const enums = @import("enums.zig");
const set = @import("set.zig");

const SwissHashSet = set.SwissHashSet;
const LittleHash = enums.LittleHash;
const OperationMode = enums.OperationMode;

/// A key value pair
/// \tparam K key type
/// \tparam V value type
fn Pair(
    comptime K: type,
    comptime V: type,
) type {
    return struct {
        key: K,
        value: V,
    };
}

/// A swiss hash map where the context is automatically inferred
pub fn AutoHashMap(
    comptime K: type,
    comptime V: type,
) type {
    return SwissHashMap(K, V, AutoMapContext(K, V, null));
}

/// A swiss hash map where the context is automatically inferred but the caller
/// can supply an explicit operation mode
pub fn AutoHashMap_Mode(
    comptime K: type,
    comptime V: type,
    comptime M: OperationMode,
) type {
    return SwissHashMap(K, V, AutoMapContext(K, V, M));
}

/// Heckin' hash map mate
/// \tparam K the key type of the map, must be hashable and equal comparable
/// \tparam V the value type of the map
/// \tparam Ctx a set of utilities like hash/equal/grow/shrink/operation mode
pub fn SwissHashMap(
    comptime K: type,
    comptime V: type,
    comptime Ctx: type,
) type {
    return struct {
        const Self = @This();
        const SetType = Pair(K, V);

        /// the inner set the map is built upon
        set: SwissHashSet(SetType, Ctx),

        pub inline fn init(alloc: std.mem.Allocator) Self {
            return .{
                .set = SwissHashSet(SetType, Ctx).init(alloc),
            };
        }

        pub inline fn deinit(self: *Self) void {
            self.set.deinit();
        }

        /// add a value to the map
        /// \param k key
        /// \param v value
        /// \return true if added
        pub inline fn add(self: *Self, k: K, v: V) !bool {
            return self.set.add(.{
                .key = k,
                .value = v,
            });
        }

        /// find an existing value or add it if not present
        /// \param k the key
        /// \return a pointer to the value of key
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

        /// get a value from the map
        /// \param k the key
        /// \return a copy of the value for key
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

        /// get a value from the map as a pointer
        /// \param k the key
        /// \return a pointer to the value for key
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

        /// determine if the map contains the supplied key
        /// \param k the key
        /// \return true if key is present in the map
        pub inline fn contains(self: *const Self, k: K) bool {
            return self.set.contains(.{
                .key = k,
                .value = undefined,
            });
        }

        /// remove a pair from the map by key
        /// \param k the key
        /// \return true if the key was removed
        pub inline fn remove(self: *Self, k: K) bool {
            return self.set.remove(.{
                .key = k,
                .value = undefined,
            });
        }

        /// remove a pair from the map by key and shrink
        /// \param k the key
        /// \return true if the key was removed
        pub inline fn removeShrink(self: *Self, k: K) !bool {
            return self.set.removeShrink(.{
                .key = k,
                .value = undefined,
            });
        }

        /// attempt to shrink the map to fit the contents
        pub inline fn trim(self: *Self) !void {
            return self.set.trim();
        }
    };
}

pub fn AutoMapContext(comptime K: type, comptime V: type, comptime M: ?OperationMode) type {
    return struct {
        const Self = @This();
        const SetType = Pair(K, V);
        const key_hasher = std.hash_map.getAutoHashFn(K, Self);
        const key_eq = std.hash_map.getAutoEqlFn(K, Self);

        pub const Mode = M orelse detect: {
            const x86 = std.Target.x86;
            if (x86.featureSetHas(builtin.cpu.features, .avx512f))
                break :detect OperationMode.AVX_512;

            if (x86.featureSetHas(builtin.cpu.features, .avx2))
                break :detect OperationMode.AVX_2;

            if (x86.featureSetHas(builtin.cpu.features, .sse4_2))
                break :detect OperationMode.SSE_4_2;

            break :detect OperationMode.Unsupported;
        };

        pub inline fn hash(self: Self, v: SetType) u64 {
            return @call(.always_inline, key_hasher, .{ self, v.key });
        }

        pub inline fn eq(self: Self, lhs: SetType, rhs: SetType) bool {
            return @call(.always_inline, key_eq, .{ self, lhs.key, rhs.key });
        }

        pub const grow = set.getAutoGrowFn(Self);
        pub const shrink = set.getAutoShrinkFn(Self);
    };
}

test "SwissHashMap init" {
    var map = AutoHashMap(u32, f32).init(std.testing.allocator);
    defer map.deinit();
}

test "SwissHashMap add" {
    var map = AutoHashMap(u32, f32).init(std.testing.allocator);
    defer map.deinit();
    try std.testing.expect(try map.add(0xFFFF_FFFF, 0.1));
}

test "SwissHashMap findOrAdd" {
    var map = AutoHashMap(u32, f32).init(std.testing.allocator);
    defer map.deinit();

    try std.testing.expect(try map.add(0xFFFF_FFFF, 0.0));

    const spot = try map.findOrAdd(0xFFFF_FFFF);
    spot.* = 0.1;

    try std.testing.expect(map.contains(0xFFFF_FFFF));
    try std.testing.expectEqual(map.get(0xFFFF_FFFF) orelse 0.0, 0.1);
}

test "SwissHashMap get" {
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

test "SwissHashMap getPtr" {
    var map = AutoHashMap(u32, f32).init(std.testing.allocator);
    defer map.deinit();

    try std.testing.expect(try map.add(0xFFFF_FFFF, 0.1));
    try std.testing.expect(map.contains(0xFFFF_FFFF));

    try std.testing.expectEqual(
        map.get(0xFFFF_FFFF) orelse 0.0,
        0.1,
    );
}

test "SwissHashMap contains" {
    var map = AutoHashMap(u32, f32).init(std.testing.allocator);
    defer map.deinit();
    try std.testing.expect(try map.add(0xFFFF_FFFF, 0.1));
    try std.testing.expect(map.contains(0xFFFF_FFFF));
}

test "SwissHashMap remove" {
    var map = AutoHashMap(u32, f32).init(std.testing.allocator);
    defer map.deinit();

    try std.testing.expect(try map.add(0xFFFF_FFFF, 0.1));
    try std.testing.expect(map.contains(0xFFFF_FFFF));

    try std.testing.expect(map.remove(0xFFFF_FFFF));
    try std.testing.expect(!map.contains(0xFFFF_FFFF));
}

test "SwissHashMap random 1024*1024" {
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
