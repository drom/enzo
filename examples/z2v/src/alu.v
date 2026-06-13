module Alu #(
  parameter DW = 8
) (
  input  [2:0] op,
  input  [DW-1:0] a,
  input  [DW-1:0] b,
  output reg [DW-1:0] y
);
  localparam [2:0] ADD=0, SUB=1, BIT_AND=2, BIT_OR=3, BIT_XOR=4, PASS_A=5;
  always @(*) begin
    case (op)
      ADD: y = a + b;
      SUB: y = a - b;
      BIT_AND: y = a & b;
      BIT_OR: y = a | b;
      BIT_XOR: y = a ^ b;
      PASS_A: y = a;
      default: y = 0;
    endcase
  end
endmodule

