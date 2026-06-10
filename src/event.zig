// Event = subscriber list. Fixed comptime size.
// Mirrors SystemC sc_event / Verilog named event.

const pool = @import("pool.zig");

pub const ThreadFn = pool.ThreadFn;

pub fn Event(comptime max_subs: u32) type {
    return struct {
        const Self = @This();

        funcs: [max_subs]ThreadFn,
        ctxs:  [max_subs]*anyopaque,
        count: u32,
        triggered: bool,
        prev_state: bool,

        pub fn init(self: *Self) void {
            self.count = 0;
            self.triggered = false;
            self.prev_state = false;
        }

        pub fn set(self: *Self) void {
            self.triggered = true;
        }

        pub fn clear(self: *Self) void {
            self.triggered = false;
        }

        pub fn check(self: *const Self) bool {
            return self.triggered;
        }

        pub fn updatePosedge(self: *Self, new_state: bool) void {
            if (new_state and !self.prev_state) self.set();
            self.prev_state = new_state;
        }

        pub fn updateNegedge(self: *Self, new_state: bool) void {
            if (!new_state and self.prev_state) self.set();
            self.prev_state = new_state;
        }

        pub fn subscribeRaw(self: *Self, fn_ptr: ThreadFn, ctx: *anyopaque) bool {
            if (self.count >= max_subs) return false;
            self.funcs[self.count] = fn_ptr;
            self.ctxs[self.count] = ctx;
            self.count += 1;
            return true;
        }

        // Type-safe subscribe: derives trampoline from ctx type at comptime.
        // ctx must be `*T` where T has `pub fn run(self: *T) void`.
        pub fn subscribe(self: *Self, ctx: anytype) bool {
            const T = @typeInfo(@TypeOf(ctx)).pointer.child;
            return self.subscribeRaw(trampoline(T), @ptrCast(ctx));
        }

        // Schedule subscribers in active region (delta queue).
        pub fn notify(self: *Self, w: anytype) bool {
            self.triggered = true;
            var i: u32 = 0;
            while (i < self.count) : (i += 1) {
                if (!w.deltaScheduleRaw(self.funcs[i], self.ctxs[i])) return false;
            }
            return true;
        }

        // Queue subscribers for postponed (post-eval) drain.
        pub fn notifyPost(self: *Self, w: anytype) bool {
            self.triggered = true;
            var i: u32 = 0;
            while (i < self.count) : (i += 1) {
                if (!w.postponedPush(self.funcs[i], self.ctxs[i])) return false;
            }
            return true;
        }
    };
}

pub fn trampoline(comptime T: type) ThreadFn {
    return &struct {
        fn call(ctx: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(ctx));
            T.run(self);
        }
    }.call;
}
