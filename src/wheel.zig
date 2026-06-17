// Hierarchical time wheel scheduler. Comptime-generic over Options.
// Owns: SoA entry pool, hierarchical wheel slots, delta queue,
// postponed queue, lifecycle (finished + at_finish event).
//
// Region split per tick (driver loop in user code):
//   1. ACTIVE     w.runActive()
//   2. EVAL       top.eval()
//   3. UPDATE     w.runPostponed()
//   4. SETTLE     top.eval()
//   5. POSTPONED  tfp.dump(w.time())
//   6. ADVANCE    w.advance()

const std = @import("std");
const pool_mod = @import("pool.zig");
const event_mod = @import("event.zig");

pub const Options = struct {
    pool_size: u32 = 1024,
    event_max_subs: u32 = 64,
    postponed_size: u32 = 256,
    levels: u32 = 4,
    bits_per_level: u32 = 8,
    delta_limit_default: u32 = 100,
};

pub fn Wheel(comptime opts: Options) type {
    const slots_per_level: u32 = @as(u32, 1) << @intCast(opts.bits_per_level);
    const level_mask: u64 = @as(u64, slots_per_level) - 1;
    const max_delay: u64 = (@as(u64, 1) << @intCast(opts.bits_per_level * opts.levels)) - 1;

    return struct {
        const Self = @This();
        pub const Pool = pool_mod.Pool(opts.pool_size);
        pub const Event = event_mod.Event(opts.event_max_subs);
        pub const ThreadFn = pool_mod.ThreadFn;
        pub const NULL_INDEX = pool_mod.NULL_INDEX;
        pub const MAX_DELAY = max_delay;
        pub const SLOTS_PER_LEVEL = slots_per_level;
        pub const LEVELS = opts.levels;
        pub const BITS_PER_LEVEL = opts.bits_per_level;

        pool: Pool,
        wheels: [opts.levels][slots_per_level]u32,
        current_time: u64,

        delta_head: u32,
        delta_tail: u32,
        current_delta: u32,
        delta_limit: u32,

        postponed_funcs: [opts.postponed_size]ThreadFn,
        postponed_ctxs: [opts.postponed_size]*anyopaque,
        postponed_count: u32,

        finished: bool,
        at_finish: Event,

        pub fn init(self: *Self) void {
            self.pool.init();
            for (&self.wheels) |*level| {
                for (level) |*slot| slot.* = NULL_INDEX;
            }
            self.current_time = 0;
            self.delta_head = NULL_INDEX;
            self.delta_tail = NULL_INDEX;
            self.current_delta = 0;
            self.delta_limit = opts.delta_limit_default;
            self.postponed_count = 0;
            self.finished = false;
            self.at_finish.init();
        }

        pub fn time(self: *const Self) u64 {
            return self.current_time;
        }

        pub fn poolUsed(self: *const Self) u32 {
            return self.pool.used;
        }
        pub fn poolPeak(self: *const Self) u32 {
            return self.pool.peak;
        }
        pub fn poolCapacity(_: *const Self) u32 {
            return opts.pool_size;
        }

        // ---------------------------------------------------------------- bucketing

        fn levelForDelay(delay: u64) u32 {
            var level: u32 = 0;
            while (level < opts.levels - 1) : (level += 1) {
                const next_shift: u6 = @intCast((level + 1) * opts.bits_per_level);
                if (delay < (@as(u64, 1) << next_shift)) return level;
            }
            return opts.levels - 1;
        }

        fn slotAt(target: u64, level: u32) u32 {
            const shift: u6 = @intCast(level * opts.bits_per_level);
            return @intCast((target >> shift) & level_mask);
        }

        // ---------------------------------------------------------------- scheduling

        pub fn scheduleRaw(self: *Self, delay: u64, fn_ptr: ThreadFn, ctx: *anyopaque) bool {
            if (delay > max_delay) return false;
            const idx = self.pool.alloc();
            if (idx == NULL_INDEX) return false;
            const target = self.current_time + delay;
            const level = levelForDelay(delay);
            const slot = slotAt(target, level);
            self.pool.fns[idx] = fn_ptr;
            self.pool.ctxs[idx] = ctx;
            self.pool.targets[idx] = target;
            self.pool.next[idx] = self.wheels[level][slot];
            self.wheels[level][slot] = idx;
            return true;
        }

        // Type-erased convenience: derives trampoline from ctx pointer type.
        // ctx must be `*T` with `pub fn run(self: *T) void`.
        pub fn schedule(self: *Self, delay: u64, ctx: anytype) bool {
            const T = @typeInfo(@TypeOf(ctx)).pointer.child;
            return self.scheduleRaw(delay, event_mod.trampoline(T), @ptrCast(ctx));
        }

        pub fn deltaScheduleRaw(self: *Self, fn_ptr: ThreadFn, ctx: *anyopaque) bool {
            const idx = self.pool.alloc();
            if (idx == NULL_INDEX) return false;
            self.pool.fns[idx] = fn_ptr;
            self.pool.ctxs[idx] = ctx;
            self.pool.targets[idx] = self.current_time;
            self.pool.next[idx] = NULL_INDEX;
            if (self.delta_tail == NULL_INDEX) {
                self.delta_head = idx;
            } else {
                self.pool.next[self.delta_tail] = idx;
            }
            self.delta_tail = idx;
            return true;
        }

        pub fn deltaSchedule(self: *Self, ctx: anytype) bool {
            const T = @typeInfo(@TypeOf(ctx)).pointer.child;
            return self.deltaScheduleRaw(event_mod.trampoline(T), @ptrCast(ctx));
        }

        // ---------------------------------------------------------------- postponed

        pub fn postponedPush(self: *Self, fn_ptr: ThreadFn, ctx: *anyopaque) bool {
            if (self.postponed_count >= opts.postponed_size) return false;
            self.postponed_funcs[self.postponed_count] = fn_ptr;
            self.postponed_ctxs[self.postponed_count] = ctx;
            self.postponed_count += 1;
            return true;
        }

        // ---------------------------------------------------------------- cascade

        fn cascadeLevel(self: *Self, next_time: u64, level: u32) void {
            const slot = slotAt(next_time, level);
            var idx = self.wheels[level][slot];
            self.wheels[level][slot] = NULL_INDEX;
            while (idx != NULL_INDEX) {
                const next_idx = self.pool.next[idx];
                const target = self.pool.targets[idx];
                const remaining: u64 = if (target > next_time) target - next_time else 0;
                const new_level = levelForDelay(remaining);
                const new_slot = slotAt(target, new_level);
                self.pool.next[idx] = self.wheels[new_level][new_slot];
                self.wheels[new_level][new_slot] = idx;
                idx = next_idx;
            }
        }

        fn cascadeCheck(self: *Self, next_time: u64) void {
            var level: u32 = 1;
            while (level < opts.levels) : (level += 1) {
                const shift: u6 = @intCast(level * opts.bits_per_level);
                const mask = (@as(u64, 1) << shift) - 1;
                if ((next_time & mask) == 0) {
                    self.cascadeLevel(next_time, level);
                } else break;
            }
        }

        // ---------------------------------------------------------------- regions

        // ACTIVE: drain level-0 slot[T] into delta queue, iterate
        // snapshot-and-swap deltas. Returns count of entries fired.
        pub fn runActive(self: *Self) u32 {
            var event_count: u32 = 0;
            const slot: u32 = @intCast(self.current_time & level_mask);

            // splice slot list onto delta tail
            if (self.wheels[0][slot] != NULL_INDEX) {
                const head = self.wheels[0][slot];
                var tail = head;
                while (self.pool.next[tail] != NULL_INDEX) tail = self.pool.next[tail];
                if (self.delta_tail == NULL_INDEX) {
                    self.delta_head = head;
                } else {
                    self.pool.next[self.delta_tail] = head;
                }
                self.delta_tail = tail;
                self.wheels[0][slot] = NULL_INDEX;
            }

            self.current_delta = 0;
            while (self.delta_head != NULL_INDEX and self.current_delta < self.delta_limit) {
                var active = self.delta_head;
                self.delta_head = NULL_INDEX;
                self.delta_tail = NULL_INDEX;
                while (active != NULL_INDEX) {
                    const idx = active;
                    active = self.pool.next[idx];
                    const fn_ptr = self.pool.fns[idx];
                    const ctx = self.pool.ctxs[idx];
                    self.pool.free(idx);
                    fn_ptr(ctx);
                    event_count += 1;
                }
                self.current_delta += 1;
            }
            return event_count;
        }

        // UPDATE: invoke postponed callbacks directly (post-eval).
        pub fn runPostponed(self: *Self) u32 {
            const n = self.postponed_count;
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                self.postponed_funcs[i](self.postponed_ctxs[i]);
            }
            self.postponed_count = 0;
            return n;
        }

        // ADVANCE: current_time++, run cascades on level boundaries.
        pub fn advance(self: *Self) void {
            const next = self.current_time + 1;
            self.cascadeCheck(next);
            self.current_time = next;
        }

        // Legacy single-step: runActive + advance (no eval split).
        pub fn tick(self: *Self) u32 {
            const n = self.runActive();
            self.advance();
            return n;
        }

        // 6-step driver loop. Runs until finished or current_time >= max_cycles.
        // `dut` is duck-typed; must expose `eval(self: *D) void` and
        // `dump(self: *D, t: u64) void`. Eval+dump are skipped on idle ticks
        // (no scheduled events) — RTL state would not change anyway.
        pub fn run(self: *Self, max_cycles: u64, dut: anytype) void {
            while (!self.finished and self.current_time < max_cycles) {
                const n = self.runActive(); // 1. ACTIVE
                if (n > 0) {
                    dut.eval(); // 2. EVAL
                    const p = self.runPostponed(); // 3. UPDATE
                    // SETTLE only when UPDATE mutated DUT inputs; eval() already
                    // settled combinational logic to convergence in step 2, so a
                    // second eval with unchanged inputs recomputes identical state.
                    if (p > 0) dut.eval(); // 4. SETTLE
                    dut.dump(self.current_time); // 5. POSTPONED
                }
                self.advance(); // 6. ADVANCE
            }
            self.runFinish();
        }

        // ---------------------------------------------------------------- lifecycle

        pub fn finish(self: *Self) void {
            self.finished = true;
        }

        pub fn isFinished(self: *const Self) bool {
            return self.finished;
        }

        pub fn atFinish(self: *Self, ctx: anytype) bool {
            return self.at_finish.subscribe(ctx);
        }

        pub fn runFinish(self: *Self) void {
            _ = self.at_finish.notifyPost(self);
            _ = self.runPostponed();
        }
    };
}

// ---------------------------------------------------------------- tests

test "wheel init zero state" {
    const W = Wheel(.{});
    var w: W = undefined;
    w.init();
    try std.testing.expectEqual(@as(u64, 0), w.time());
    try std.testing.expectEqual(@as(u32, 0), w.poolUsed());
    try std.testing.expect(!w.isFinished());
}

const TickProbe = struct {
    fired: u32 = 0,
    pub fn run(self: *@This()) void {
        self.fired += 1;
    }
};

test "schedule + tick fires at correct time" {
    const W = Wheel(.{});
    var w: W = undefined;
    w.init();
    var probe = TickProbe{};
    try std.testing.expect(w.schedule(5, &probe));
    var t: u64 = 0;
    while (t < 10) : (t += 1) {
        _ = w.tick();
    }
    try std.testing.expectEqual(@as(u32, 1), probe.fired);
    try std.testing.expectEqual(@as(u32, 0), w.poolUsed());
}

test "cascade across level boundary" {
    const W = Wheel(.{ .pool_size = 32 });
    var w: W = undefined;
    w.init();
    var probe = TickProbe{};
    // delay = 1500 crosses level-0/1 boundary (256)
    try std.testing.expect(w.schedule(1500, &probe));
    var t: u64 = 0;
    while (t < 1600) : (t += 1) _ = w.tick();
    try std.testing.expectEqual(@as(u32, 1), probe.fired);
}

test "schedule rejects out-of-range delay" {
    const W = Wheel(.{});
    var w: W = undefined;
    w.init();
    var probe = TickProbe{};
    try std.testing.expect(!w.schedule(W.MAX_DELAY + 1, &probe));
}
