const std = @import("std");
const Io = std.Io;

const z2v = @import("z2v.zig").z2v;

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);
    const input_file_path = args[1];
    const output_file_path = args[2];
    std.log.info("input file path: {s}", .{input_file_path});
    std.log.info("output file path: {s}", .{output_file_path});

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    // read input Zig file
    const input_file_string = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        input_file_path,
        init.gpa,
        .unlimited,
        .of(u8),
        0,
    );
    defer init.gpa.free(input_file_string);
    std.log.info("input file str: {s}", .{input_file_string});

    // parse the AST
    var ast = try std.zig.Ast.parse(init.gpa, input_file_string, .zig);
    defer ast.deinit(init.gpa);

    const out_file = try std.Io.Dir.cwd().createFile(io, output_file_path, .{});
    defer out_file.close(io);
    var out_buffer: [4096]u8 = undefined;
    var file_writer = out_file.writer(io, &out_buffer);
    const writer = &file_writer.interface;
    try z2v(init.gpa, ast, writer);
    try writer.flush(); // Don't forget to flush!
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
