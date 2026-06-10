// enzo — Zig HDL simulation kernel. Index module.

const wheel_mod = @import("wheel.zig");
const event_mod = @import("event.zig");
const clock_mod = @import("clock.zig");
const pool_mod  = @import("pool.zig");
const thread_mod = @import("thread.zig");

pub const Wheel    = wheel_mod.Wheel;
pub const Options  = wheel_mod.Options;
pub const Event    = event_mod.Event;
pub const Clock    = clock_mod.Clock;
pub const Pool     = pool_mod.Pool;
pub const ThreadFn = thread_mod.ThreadFn;
pub const trampoline = thread_mod.trampoline;
pub const NULL_INDEX = pool_mod.NULL_INDEX;

test {
    @import("std").testing.refAllDecls(@This());
    _ = wheel_mod;
    _ = event_mod;
    _ = clock_mod;
    _ = pool_mod;
    _ = thread_mod;
}
