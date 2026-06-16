const std = @import("std");
const Io = std.Io;
const enzo = @import("enzo");
const vtop = @import("vtop.zig");

const DatT = vtop.DatT;
const dat_bits = vtop.dat_bits;
const dat_words = vtop.dat_words;
const DW = vtop.DW;

// ---------------------------------------------------------------- kernel cfg

const W = enzo.Wheel(.{
    .pool_size = 1024,
    .event_max_subs = 16,
    .postponed_size = 64,
});

// ---------------------------------------------------------------- components

const ResetGen = struct {
    wheel: *W,
    sig_rst: *u8,
    duration: u32,
    step: u32 = 0,

    pub fn run(self: *@This()) void {
        switch (self.step) {
            0 => {
                self.sig_rst.* = 1;
                self.step = 1;
                _ = self.wheel.schedule(self.duration, self);
            },
            1 => {
                self.sig_rst.* = 0;
                self.step = 2;
            },
            else => {},
        }
    }
};

fn lfsrStep(s: u32) u32 {
    var x = s;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return x;
}

const AxiSource = struct {
    sig_rst: *u8,
    sig_vld: *u8,
    sig_rdy: *u8,
    sig_dat: [*]DatT,
    bubble_prob: u32,
    bubble_lfsr: u32,
    curr_state: u32,

    pub fn run(self: *@This()) void {
        if (self.sig_rst.* == 1) {
            self.sig_vld.* = 0;
            return;
        }
        // AXI rule: once VLD asserted, VLD/DAT hold until READY sampled high.
        // Generate new beat only when idle (vld=0) or handshake just completed.
        if (self.sig_vld.* == 0 or self.sig_rdy.* == 1) {
            self.bubble_lfsr = lfsrStep(self.bubble_lfsr);
            if ((self.bubble_lfsr & 0xFF) < self.bubble_prob) {
                self.sig_vld.* = 0;
            } else {
                // dat_words is comptime: this fully unrolls. For DW<=64 it
                // collapses to a single scalar store (no loop, no index math).
                inline for (0..dat_words) |k| {
                    self.sig_dat[k] = @truncate(self.curr_state);
                    self.curr_state +%= 1;
                }
                self.sig_vld.* = 1;
            }
        }
    }
};

const AxiSink = struct {
    sig_rst: *u8,
    sig_vld: *u8,
    sig_rdy: *u8,
    sig_dat: [*]DatT,
    bubble_prob: u32,
    bubble_lfsr: u32,
    last_data: u32 = 0,
    received_count: u32 = 0,

    pub fn run(self: *@This()) void {
        if (self.sig_rst.* == 1) {
            self.sig_rdy.* = 0;
            return;
        }
        self.bubble_lfsr = lfsrStep(self.bubble_lfsr);
        if ((self.bubble_lfsr & 0xFF) < self.bubble_prob) {
            self.sig_rdy.* = 0;
        } else {
            self.sig_rdy.* = 1;
        }
        if (self.sig_vld.* == 1 and self.sig_rdy.* == 1) {
            self.last_data = @truncate(self.sig_dat[0]);
            self.received_count +%= 1;
        }
    }
};

fn monotonicNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

// ---------------------------------------------------------------- main

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var vcd_path: ?[*:0]const u8 = "waveform.vcd";
    var max_cycles: u64 = 10_000;
    var verbose: bool = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--vcd") and i + 1 < args.len) {
            i += 1;
            vcd_path = args[i].ptr;
        } else if (std.mem.eql(u8, a, "--no-vcd")) {
            vcd_path = null;
        } else if (std.mem.eql(u8, a, "--cycles") and i + 1 < args.len) {
            i += 1;
            max_cycles = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        }
    }

    const io = init.io;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    var dut = vtop.Vtop.init(vcd_path);
    defer dut.deinit();

    var wheel: W = undefined;
    wheel.init();

    var clk: enzo.Clock(W) = undefined;
    clk.init(&wheel, dut.io.clk, 1);

    var reset_gen = ResetGen{
        .wheel = &wheel,
        .sig_rst = dut.io.rst,
        .duration = 11,
    };

    var src = AxiSource{
        .sig_rst = dut.io.rst,
        .sig_vld = dut.io.t_0_req,
        .sig_rdy = dut.io.t_0_ack,
        .sig_dat = dut.io.t_0_dat,
        .bubble_prob = 127,
        .bubble_lfsr = 0x87654321,
        .curr_state = 0x12345678,
    };

    var snk = AxiSink{
        .sig_rst = dut.io.rst,
        .sig_vld = dut.io.i_0_req,
        .sig_rdy = dut.io.i_0_ack,
        .sig_dat = dut.io.i_0_dat,
        .bubble_prob = 129,
        .bubble_lfsr = 0x87654321,
    };

    if (!clk.posedge.subscribe(&src)) return error.SubscribeFailed;
    if (!clk.posedge.subscribe(&snk)) return error.SubscribeFailed;

    if (!clk.start()) return error.ScheduleFailed;
    if (!wheel.schedule(0, &reset_gen)) return error.ScheduleFailed;

    const start_ns = monotonicNs();
    wheel.run(max_cycles, &dut);
    const elapsed_ns = monotonicNs() - start_ns;

    const elapsed_us: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1000.0;
    const ticks_per_us: f64 = if (elapsed_us > 0) @as(f64, @floatFromInt(wheel.time())) / elapsed_us else 0;

    try out.print("Sim done: DW={d} ({d}x{d}b)  t={d} ticks  rx={d}  pool_peak={d}/{d}  speed={d:.1} ticks/us\n", .{
        DW,                   dat_words,          dat_bits,
        wheel.time(),         snk.received_count, wheel.poolPeak(),
        wheel.poolCapacity(), ticks_per_us,
    });
    if (verbose) {
        try out.print("  last_rx_data=0x{x}  src_curr=0x{x}\n", .{ snk.last_data, src.curr_state });
    }
    try out.flush();
}
