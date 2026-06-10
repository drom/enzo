const std = @import("std");
const Io = std.Io;
const enzo = @import("enzo");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| std.log.info("arg: {s}", .{arg});

    const io = init.io;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const w = &stdout_file_writer.interface;

    const W = enzo.Wheel(.{});
    var wheel: W = undefined;
    wheel.init();

    try w.print("enzo kernel: pool_cap={d} max_delay={d} levels={d} slots/level={d}\n", .{
        wheel.poolCapacity(), W.MAX_DELAY, W.LEVELS, W.SLOTS_PER_LEVEL,
    });
    try w.flush();
}
