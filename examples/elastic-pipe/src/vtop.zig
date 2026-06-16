// Vtop wrapper. All extern C calls and Verilator pin layout live here.
// Comptime DW from build_options decides DatT and dat_words.

const build_options = @import("build_options");

pub const DW: u32 = build_options.DW;

// Pin element type. Mirrors Verilator/zim_wrapper choice exactly so DW<=64 is a
// single scalar word (dat_words==1):
//   DW<=8: CData(u8)  DW<=16: SData(u16)  DW<=32: IData(u32)
//   DW<=64: QData(u64)  DW>64: WData[] (u32 array, ceil(DW/32) words).
// MUST stay in lockstep with the #if ladder in zim_wrapper.cpp.
pub const DatT: type = blk: {
    if (DW <= 8) break :blk u8;
    if (DW <= 16) break :blk u16;
    if (DW <= 32) break :blk u32;
    if (DW <= 64) break :blk u64;
    break :blk u32;
};
pub const dat_bits: u32 = @bitSizeOf(DatT);
pub const dat_words: u32 = (DW + dat_bits - 1) / dat_bits;

pub const Io = extern struct {
    clk: *u8,
    rst: *u8,
    t_0_dat: [*]DatT,
    t_0_req: *u8,
    t_0_ack: *u8,
    i_0_dat: [*]DatT,
    i_0_req: *u8,
    i_0_ack: *u8,
};

extern fn sim_init(vcd_filename: ?[*:0]const u8) void;
extern fn sim_cleanup() void;
extern fn sim_get_pins(out: *Io) void;
extern fn sim_eval() void;
extern fn sim_trace_dump(t: u64) void;

// DUT wrapper. Provides eval()/dump(t) methods consumed by Wheel.run.
pub const Vtop = struct {
    io: Io,

    pub fn init(vcd: ?[*:0]const u8) Vtop {
        sim_init(vcd);
        var self: Vtop = .{ .io = undefined };
        sim_get_pins(&self.io);
        return self;
    }

    pub fn deinit(_: *Vtop) void {
        sim_cleanup();
    }

    pub fn eval(_: *Vtop) void {
        sim_eval();
    }

    pub fn dump(_: *Vtop, t: u64) void {
        sim_trace_dump(t);
    }
};
