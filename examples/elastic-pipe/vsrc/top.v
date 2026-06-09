module top #(
  parameter DW = 64
)(
  input rst, clk,

  input  [DW-1:0] t_0_dat,
  input           t_0_req,
  output          t_0_ack,

  output [DW-1:0] i_0_dat,
  output          i_0_req,
  input           i_0_ack
);

// data path
reg [DW-1:0] d1, d2, d3;
wire d1_en, d2_en, d3_en;
always @(posedge clk) if(d1_en) d1 <= t_0_dat;
always @(posedge clk) if(d2_en) d2 <= d1;
always @(posedge clk) if(d3_en) d3 <= d2;
assign i_0_dat = d3;

// elastic controller

// target alias
wire d0_req = t_0_req;
wire d0_ack;
assign t_0_ack = d0_ack;

// ${i}_en = ${t}_req & ${t}_ack;
// ${i}_req_next = ${t}_req | ~${t}_ack;
// ${t}_ack = ${i}_ack | ~${i}_req;

// d1 stage
assign d1_en = d0_req & d0_ack;
reg d1_req; always @(posedge clk or posedge rst)
    d1_req <= rst ? 1'b0 : (d0_req | ~d0_ack);
wire d1_ack;
assign d0_ack = d1_ack | ~d1_req;

// d2 stage
assign d2_en = d1_req & d1_ack;
reg d2_req; always @(posedge clk or posedge rst)
    d2_req <= rst ? 1'b0 : (d1_req | ~d1_ack);
wire d2_ack;
assign d1_ack = d2_ack | ~d2_req;

// d3 stage
assign d3_en = d2_req & d2_ack;
reg d3_req; always @(posedge clk or posedge rst)
    d3_req <= rst ? 1'b0 : (d2_req | ~d2_ack);
wire d3_ack;
assign d2_ack = d3_ack | ~d3_req;

// initiator alias
assign d3_ack = i_0_ack;
assign i_0_req = d3_req;

endmodule
