// SoA static entry pool. u32 free-list indices.
// No allocator. Comptime-sized. Cache-friendly columns.

pub const NULL_INDEX: u32 = 0xFFFF_FFFF;

pub const ThreadFn = *const fn (ctx: *anyopaque) void;

pub fn Pool(comptime size: u32) type {
    return struct {
        const Self = @This();

        fns:     [size]ThreadFn,
        ctxs:    [size]*anyopaque,
        targets: [size]u64,
        next:    [size]u32,
        free_head: u32,
        used: u32,
        peak: u32,

        pub fn init(self: *Self) void {
            var i: u32 = 0;
            while (i + 1 < size) : (i += 1) self.next[i] = i + 1;
            self.next[size - 1] = NULL_INDEX;
            self.free_head = 0;
            self.used = 0;
            self.peak = 0;
        }

        pub fn alloc(self: *Self) u32 {
            const idx = self.free_head;
            if (idx == NULL_INDEX) return NULL_INDEX;
            self.free_head = self.next[idx];
            self.used += 1;
            if (self.used > self.peak) self.peak = self.used;
            return idx;
        }

        pub fn free(self: *Self, idx: u32) void {
            self.next[idx] = self.free_head;
            self.free_head = idx;
            self.used -= 1;
        }

        pub fn capacity(_: *const Self) u32 {
            return size;
        }
    };
}

const std = @import("std");

test "pool alloc/free roundtrip" {
    var p: Pool(16) = undefined;
    p.init();
    try std.testing.expectEqual(@as(u32, 0), p.used);
    const a = p.alloc();
    const b = p.alloc();
    try std.testing.expect(a != NULL_INDEX);
    try std.testing.expect(b != NULL_INDEX);
    try std.testing.expectEqual(@as(u32, 2), p.used);
    try std.testing.expectEqual(@as(u32, 2), p.peak);
    p.free(a);
    p.free(b);
    try std.testing.expectEqual(@as(u32, 0), p.used);
    try std.testing.expectEqual(@as(u32, 2), p.peak);
}

test "pool exhaustion returns NULL_INDEX" {
    var p: Pool(4) = undefined;
    p.init();
    _ = p.alloc();
    _ = p.alloc();
    _ = p.alloc();
    _ = p.alloc();
    try std.testing.expectEqual(NULL_INDEX, p.alloc());
}
