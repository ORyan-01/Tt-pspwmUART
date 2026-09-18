`timescale 1ns / 1ps

module comparator #(
  parameter integer Width = 7
) (
  input  wire [Width-1:0] in1_i,  // Signal 1 (e.g. Duty Cycle)
  input  wire [Width-1:0] in2_i,  // Signal 2 (e.g. Triangular Wave)
  output reg              cmp_o   // Comparison Output (1 if in1 >= in2)
);

  // Combinational comparison logic
  always @* begin
    cmp_o = (in1_i >= in2_i);
  end

endmodule
