#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vtop.h"

#ifndef DW
#  error "DW must be defined at build time (e.g. -DDW=32)"
#endif

// Pin element type for *_dat. Matches Verilator's natural storage exactly so
// the consumer touches one scalar word for DW <= 64:
//   DW <= 8   -> CData (uint8_t)
//   DW <= 16  -> SData (uint16_t)
//   DW <= 32  -> IData (uint32_t)
//   DW <= 64  -> QData (uint64_t)
//   DW >  64  -> WData[] (uint32_t[]), consumer reads/writes ceil(DW/32) words.
// On little-endian hosts a reinterpret_cast of the storage address to DatT* is
// layout-correct for every tier.
#if DW <= 8
typedef uint8_t  DatT;
#elif DW <= 16
typedef uint16_t DatT;
#elif DW <= 32
typedef uint32_t DatT;
#elif DW <= 64
typedef uint64_t DatT;
#else
typedef uint32_t DatT;
#endif

// Singleton sim state. Zig drives via the C ABI below; pin pointers
// are returned once via sim_get_pins() so per-cycle access stays
// pure Zig pointer load/store (no FFI hop).

static Vtop*           top  = nullptr;
static VerilatedVcdC*  tfp  = nullptr;
static vluint64_t      main_time = 0;

double sc_time_stamp() {
    return main_time;
}

extern "C" {

struct VtopPins {
    uint8_t *clk;
    uint8_t *rst;
    DatT    *t_0_dat;
    uint8_t *t_0_req;
    uint8_t *t_0_ack;
    DatT    *i_0_dat;
    uint8_t *i_0_req;
    uint8_t *i_0_ack;
};

void sim_init(const char* vcd_filename) {
    VerilatedContext* contextp = Verilated::threadContextp();
    contextp->timeunit(-11);
    contextp->timeprecision(-11);

    top = new Vtop;

    if (vcd_filename) {
        Verilated::traceEverOn(true);
        tfp = new VerilatedVcdC;
        top->trace(tfp, 99);
        tfp->open(vcd_filename);
    }
}

void sim_cleanup() {
    top->final();
    if (tfp) {
        tfp->close();
        delete tfp;
        tfp = nullptr;
    }
    delete top;
    top = nullptr;
}

void sim_get_pins(VtopPins *out) {
    out->clk     = &top->clk;
    out->rst     = &top->rst;
    out->t_0_dat = reinterpret_cast<DatT*>(&top->t_0_dat);
    out->t_0_req = &top->t_0_req;
    out->t_0_ack = &top->t_0_ack;
    out->i_0_dat = reinterpret_cast<DatT*>(&top->i_0_dat);
    out->i_0_req = &top->i_0_req;
    out->i_0_ack = &top->i_0_ack;
}

void sim_eval() {
    top->eval();
}

void sim_trace_dump(uint64_t t) {
    main_time = (vluint64_t)t;
    if (tfp) tfp->dump(main_time);
}

double get_time_stamp() {
    return main_time;
}

} // extern "C"
