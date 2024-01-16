//!

const std = @import("std");
const builtin = @import("builtin");
const enums = @import("enums.zig");
const Group = @import("group.zig").Group;
const Probe = @import("probe.zig").Probe;

const LittleHash = enums.LittleHash;
pub const OperationMode = enums.OperationMode;

/// A swiss table set where the context is automatically inferred
pub fn AutoHashSet(comptime T: type) type {
    return SwissHashSet(T, AutoContext(T, null));
}

pub fn AutoHashSet_Mode(comptime T: type, comptime M: OperationMode) type {
    return SwissHashSet(T, AutoContext(T, M));
}

pub fn getAutoGrowFn(comptime Ctx: type) (fn (Ctx, usize, usize) usize) {
    return struct {
        fn grow(self: Ctx, count: usize, capacity: usize) usize {
            _ = self; // autofix
            return @max(
                capacity + (capacity >> 1),
                count,
            );
        }
    }.grow;
}

pub fn getAutoShrinkFn(comptime Ctx: type) (fn (Ctx, usize, usize) usize) {
    return struct {
        fn shrink(self: Ctx, count: usize, capacity: usize) usize {
            _ = self; // autofix
            return @max(
                @as(
                    usize,
                    (capacity >> 3) * 5,
                ),
                count,
            );
        }
    }.shrink;
}

pub fn AutoContext(comptime T: type, comptime M: ?OperationMode) type {
    return struct {
        const Self = @This();
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
        pub const hash = std.hash_map.getAutoHashFn(T, Self);
        pub const eq = std.hash_map.getAutoEqlFn(T, Self);
        pub const grow = getAutoGrowFn(Self);
        pub const shrink = getAutoShrinkFn(Self);
    };
}

/// Heckin' hash set mate
/// \tparam T the type of thing in the hash set
/// \tparam Ctx configuration values for the hash set
pub fn SwissHashSet(comptime T: type, comptime Ctx: type) type {
    return struct {
        const Self = @This();
        const TableGroup = Group(Ctx.Mode);
        const TableProbe = Probe(Ctx.Mode);
        const Width = Ctx.Mode.vectorWidth();
        const Empty = Ctx.Mode.generate(enums.LittleHash.Empty);
        const LayoutHelp = LayoutHelper(Ctx.Mode, T).init();

        /// this is only done this way because of how the std does it and I want
        /// to use their hash functions
        ctx: Ctx,
        alloc: std.mem.Allocator,
        lil: [*]LittleHash,
        big: [*]T = undefined,
        len: usize = 0,
        mask: usize = 0,
        left: usize = 0,

        /// construct the hash set
        pub inline fn init(alloc: std.mem.Allocator) Self {
            return .{
                .ctx = undefined,
                .alloc = alloc,
                .lil = @constCast(&Empty),
            };
        }

        pub inline fn deinit(self: *Self) void {
            if (self.mask > 0) {
                const full_cap = self.mask + 1;
                const old_info = LayoutHelp.forBuckets(full_cap);
                self.alloc.free(
                    @as([*]align(LayoutHelp.alignment) u8, @ptrCast(self.big))[0..old_info.len],
                );

                self.lil = @constCast(&Empty);
                self.big = undefined;
                self.len = 0;
                self.mask = 0;
                self.left = 0;
            }
        }

        /// add a value to the hash set
        /// \param v the value to add
        /// \return true / false depending on if the value was added to the set or error
        pub inline fn add(self: *Self, v: T) !bool {
            const result = try self.findOrAddSlot(v);
            // new slot reserved!
            if (result.is_new)
                self.big[result.index] = v;

            return result.is_new;
        }

        /// determine if a value is in the hash set
        /// \param v the value to determine the presence of
        /// \return true if the value is contained in the set
        pub inline fn contains(self: *const Self, v: T) bool {
            return self.indexOf(v) != null;
        }

        /// remove a value from the hash set
        /// \param v the value to remove
        /// \return true if the value was present and was removed
        pub inline fn remove(self: *Self, v: T) bool {
            const maybe_idx = self.indexOf(v);
            if (maybe_idx) |idx| {
                std.debug.assert(self.lil[idx].isFull());

                self.len -= 1;

                const idx_before = (idx -% Width) & self.mask;
                const empty_after = TableGroup.init(self.lil[idx .. idx + Width]).matchEmpty();
                const empty_before = TableGroup.init(self.lil[idx_before .. idx_before + Width]).matchEmpty();

                const was_never_full = empty_before.isValid() and
                    empty_after.isValid() and (empty_before.trailingZeros() + empty_after.trailingZeros() < Width);

                self.left += if (was_never_full) 1 else 0;
                _ = self.setLil(
                    idx,
                    if (was_never_full)
                        LittleHash.Empty
                    else
                        LittleHash.Deleted,
                );

                return true;
            }
            return false;
        }

        /// remove a value from the hash set and shrink
        /// \param v the value to remove
        /// \return true if the value was present and was removed
        pub inline fn removeShrink(self: *Self, v: T) !bool {
            const removed = self.remove(v);
            if (removed) try self.trim();
            return removed;
        }

        /// resize the set to better fit the contents of the set
        pub inline fn trim(self: *Self) !void {
            const full_cap = bucketsToCapacity(self.mask);
            const shrink_cap = self.ctx.shrink(self.len, full_cap);
            const shrink_buckets = capacityToBuckets(shrink_cap);

            if (shrink_buckets < full_cap) {
                //std.debug.print("shrinking!\n", .{});
                try self.resize(shrink_cap);
            }
        }

        /// find the index of a value
        /// \param v the value to find
        /// \return the index of the value or null
        pub inline fn indexOf(self: *const Self, v: T) ?usize {
            const hashed = self.ctx.hash(v);
            const lil_hash = LittleHash.from(hashed);
            var prober = TableProbe.init(hashed & self.mask, 0);

            while (prober.next(self.mask)) |position| {
                const group = TableGroup.init(self.lil[position .. position + Width]);
                var mask = group.match(lil_hash);

                while (mask.next()) |i| {
                    const real_position = position + i & self.mask;
                    if (self.ctx.eq(self.big[real_position], v)) {
                        return real_position;
                    }
                }

                if (group.matchEmpty().isValid()) break;
            }

            return null;
        }

        inline fn findOrAddSlot(self: *Self, v: T) !FoundSlot {
            const hashed = self.ctx.hash(v);

            const lil_hash = LittleHash.from(hashed);
            var prober = TableProbe.init(hashed & self.mask, 0);

            while (prober.next(self.mask)) |position| {
                const group = TableGroup.init(self.lil[position .. position + Width]);
                var mask = group.match(lil_hash);

                while (mask.next()) |i| {
                    const real_position = position + i & self.mask;
                    if (self.ctx.eq(self.big[real_position], v)) {
                        return .{
                            .index = real_position,
                            .is_new = false,
                        };
                    }
                }

                if (group.matchEmpty().isValid()) break;
            }

            return .{
                .index = try self.reserveSlot(hashed),
                .is_new = true,
            };
        }

        inline fn reserveSlot(self: *Self, h: u64) !usize {
            var found = self.findNotFull(h);
            if (found == null or (self.left == 0 and self.lil[found.?].isEmpty())) {
                try self.resizeIfNeeded(1);
                found = self.findNotFull(h);
            }

            if (found) |f| {
                self.len += 1;
                self.left -= if (self.lil[f].isEmpty()) 1 else 0;
                _ = self.setLil(f, LittleHash.from(h));
            }

            return found orelse error.NoRoom;
        }

        inline fn findNotFull(self: *Self, h: u64) ?usize {
            var prober = TableProbe.init(h & self.mask, 0);
            while (prober.next(self.mask)) |position| {
                const group = TableGroup.init(self.lil[position .. position + Width]);
                const mask = group.matchEmptyOrDeleted();
                if (mask.isValid()) {
                    const result = (position + mask.trailingZeros()) & self.mask;
                    if (self.lil[result].isFull()) {
                        // try wrapping around the table and checking the first bucket
                        return TableGroup.init(self.lil[0..Width]).matchEmptyOrDeleted().trailingZeros();
                    }

                    return result;
                }
            }

            return null;
        }

        inline fn resizeIfNeeded(self: *Self, num_to_add: usize) !void {
            if (num_to_add > self.left) {
                const full_cap = bucketsToCapacity(self.mask);
                const new_len = self.len + num_to_add;
                if (bucketsToCapacity(new_len) <= (full_cap >> 1)) {
                    try self.rehash();
                } else {
                    const new_cap = self.ctx.grow(new_len, full_cap);
                    if (new_cap != full_cap) {
                        try self.resize(new_cap);
                    }
                }
            }
        }

        fn rehash(self: *Self) !void {
            //std.debug.print("rehashing\n", .{});

            const full_cap = self.mask + 1;
            {
                var idx: usize = 0;
                while (idx < full_cap) : (idx += Width) {
                    const group = TableGroup.init(self.lil[idx .. idx + Width]);
                    const new_group = group.convertForRehash();
                    new_group.store(@as(*[Width]u8, @ptrCast(self.lil + idx)));
                }
            }

            // fix up cloned little
            if (full_cap < Width) {
                @memcpy(self.lil + Width, self.lil[0..full_cap]);
            } else {
                @memcpy(self.lil + full_cap, self.lil[Width .. Width + Width]);
            }

            {
                var idx: usize = 0;
                while (idx < full_cap) : (idx += 1) {
                    if (!self.lil[idx].isDeleted()) continue;

                    const hashed = self.ctx.hash(self.big[idx]);
                    const found = self.findNotFull(hashed);
                    const lil = LittleHash.from(hashed);

                    if (found) |new_pos| {
                        const prober = TableProbe.init(hashed & self.mask, 0);
                        const same_group = (((new_pos - prober.position) & self.mask) / Width) == (((idx - prober.position) & self.mask) / Width);

                        if (same_group) {
                            _ = self.setLil(idx, lil);
                            continue;
                        }

                        if (self.lil[new_pos].isEmpty()) {
                            _ = self.setLil(new_pos, lil);
                            self.big[new_pos] = self.big[idx];
                            _ = self.setLil(idx, LittleHash.Empty);
                        } else {
                            _ = self.setLil(new_pos, lil);
                            std.mem.swap(T, &self.big[new_pos], &self.big[idx]);
                            idx -= 1;
                        }
                    }
                }
            }
        }

        fn resize(self: *Self, new_capacity: usize) !void {
            const buckets = capacityToBuckets(new_capacity);

            //std.debug.print("resizing {}. {}\n", .{
            //    buckets,
            //    self.len,
            //});

            const layout_info = LayoutHelp.forBuckets(buckets);
            const alloc_align: u29 = @intCast(LayoutHelp.alignment);

            const buffer = try self.alloc.allocWithOptions(
                u8,
                layout_info.len,
                alloc_align,
                null,
            );

            @memset(buffer, undefined);

            var new_lil: [*]LittleHash = @ptrCast(buffer.ptr + layout_info.lil_offset);
            var new_big: [*]T = @ptrCast(buffer.ptr);
            var new_mask = buckets - 1;

            std.mem.swap([*]LittleHash, &self.lil, &new_lil);
            std.mem.swap([*]T, &self.big, &new_big);
            std.mem.swap(usize, &self.mask, &new_mask);

            self.left = bucketsToCapacity(buckets - 1);
            @memset(
                self.lil[0..self.numLil()],
                LittleHash.Empty,
            );

            if (new_mask > 0) {
                const full_cap = new_mask + 1;
                for (0..full_cap) |idx| {
                    if (!new_lil[idx].isFull()) continue;

                    const hashed = self.ctx.hash(new_big[idx]);
                    const found = self.findNotFull(hashed);

                    if (found) |new_idx| {
                        self.left -= 1;
                        _ = self.setLil(new_idx, LittleHash.from(hashed));
                        self.big[new_idx] = new_big[idx];
                    }
                }

                const old_info = LayoutHelp.forBuckets(full_cap);
                const to_free = @as([*]align(LayoutHelp.alignment) u8, @ptrCast(new_big))[0..old_info.len];
                self.alloc.free(to_free);
            }
        }

        inline fn setLil(self: *Self, idx: usize, val: LittleHash) LittleHash {
            const idx2 = ((idx -% Width) & self.mask) +% Width;
            std.debug.assert(idx < self.numLil() and idx2 < self.numLil());
            const prev_val = self.lil[idx];
            self.lil[idx] = val;
            self.lil[idx2] = val;
            return prev_val;
        }

        inline fn numLil(self: *const Self) usize {
            return self.mask + 1 + Width;
        }

        inline fn capacityToBuckets(cap: usize) usize {
            // 87.5% load target
            const adjusted: usize = (cap * 8) / 7;
            // don't bother below 4 since 2 can only hold one element
            return if (cap < 8)
                if (cap < 4)
                    4
                else
                    8
            else
                std.math.ceilPowerOfTwo(usize, adjusted) catch 0;
        }

        inline fn bucketsToCapacity(buckets: usize) usize {
            // small tables always have an empty bucket
            // large tables have 12.5% empty
            return if (buckets < 8)
                buckets
            else
                ((buckets + 1) / 8) * 7;
        }
    };
}

const FoundSlot = struct {
    index: usize,
    is_new: bool,
};

const Layout = struct {
    len: usize,
    lil_offset: usize,
};

fn LayoutHelper(comptime M: OperationMode, comptime T: type) type {
    return struct {
        const Self = @This();
        const Width = M.vectorWidth();

        size: usize,
        alignment: usize,

        pub inline fn init() Self {
            return .{
                .size = @sizeOf(T),
                .alignment = @min(@alignOf(T), Width),
            };
        }

        pub inline fn forBuckets(self: Self, buckets: usize) Layout {
            const lil_offset = (self.size * buckets) + (self.alignment - 1) & ~(self.alignment - 1);
            const len = lil_offset + buckets + Width;

            return .{
                .len = len,
                .lil_offset = lil_offset,
            };
        }
    };
}

test "SwissHashSet init" {
    var set = AutoHashSet(u32).init(std.testing.allocator);
    defer set.deinit();
}

test "SwissHashSet add" {
    var set = AutoHashSet(u32).init(std.testing.allocator);
    defer set.deinit();
    try std.testing.expect(try set.add(0xFFFF_FFFF));
}

test "SwissHashSet contains" {
    var set = AutoHashSet(u32).init(std.testing.allocator);
    defer set.deinit();
    try std.testing.expect(try set.add(0xFFFF_FFFF));
    try std.testing.expect(set.contains(0xFFFF_FFFF));
}

test "SwissHashSet remove" {
    var set = AutoHashSet(u32).init(std.testing.allocator);
    defer set.deinit();

    try std.testing.expect(try set.add(0xFFFF_FFFF));
    try std.testing.expect(set.contains(0xFFFF_FFFF));

    try std.testing.expect(set.remove(0xFFFF_FFFF));
    try std.testing.expect(!set.contains(0xFFFF_FFFF));
}

test "SwissHashSet random 1024*1024" {
    const RndGen = std.rand.DefaultPrng;

    var set = AutoHashSet(u32).init(std.testing.allocator);
    defer set.deinit();

    var rnd = RndGen.init(0);

    var maybe_last: ?u32 = null;
    for (0..1024 * 1024) |i| {
        const generated = rnd.random().int(u32);
        const added = try set.add(generated);

        if (maybe_last) |last| {
            //std.debug.print("removing {}\n", .{last});
            try std.testing.expect(set.remove(last));
            maybe_last = null;
        }

        if (i % 3 == 0 and added) {
            maybe_last = generated;
        }
    }
}

test "LayoutHelper" {
    const BUCKETS = 1024;
    const layout = LayoutHelper(OperationMode.AVX_2, u32).init();
    const bucket_layout = layout.forBuckets(BUCKETS);
    try std.testing.expect(bucket_layout.len > @sizeOf(u32) * BUCKETS);
}
