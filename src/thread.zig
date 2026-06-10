// Thread = state-machine helper. User struct holds `step: u32` and provides
// `pub fn run(self: *@This()) void`. Wheel/Event use `trampoline(T)` to
// produce type-erased fn pointer at comptime. No protothreads, no async.

const event_mod = @import("event.zig");

pub const ThreadFn = event_mod.ThreadFn;
pub const trampoline = event_mod.trampoline;
