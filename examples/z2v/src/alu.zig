const std = @import("std");

// Module parameters — emitted as Verilog `parameter`s.
pub const parameters = struct {
    DW: u32 = 8,
};

// Parametrized module: `Alu(.{})` uses defaults, `Alu(.{ .DW = 16 })` overrides.
// Returns a struct type whose port widths derive from the parameters.
pub fn Alu(comptime p: parameters) type {
    return struct {
        // non-exhaustive: u3 has 8 codes, only 6 are defined; the rest hit `else`
        const Opcode = enum(u3) { add, sub, bit_and, bit_or, bit_xor, pass_a, _ };

        // parametrized data-width type
        const DWT = std.meta.Int(.unsigned, p.DW);

        inputs: struct { op: Opcode, a: DWT, b: DWT }, // input ports section
        outputs: struct { y: DWT }, // output ports section

        always: struct {
            pub fn a0(op: Opcode, a: DWT, b: DWT) DWT { // always block scope
                return switch (op) {
                    .add => a +% b,
                    .sub => a -% b,
                    .bit_and => a & b,
                    .bit_or => a | b,
                    .bit_xor => a ^ b,
                    .pass_a => a,
                    else => 0, // undefined opcode -> default
                };
            }
        },
    };
}
