`timescale 1ns / 1ps

module signal_generator_180phase #(
  parameter integer Width = 7
) (
  input  wire             clk_i,    // Input Clock
  input  wire             rst_ni,   // Active-Low Asynchronous Reset
  output reg  [Width-1:0] count_o   // Triangular Wave Output
);

  reg direction_q; // 1 = Up, 0 = Down

  // Calculate Max/Min constants based on Width parameter
  // This ensures the module works for any bit width (e.g. 12-bit ADC range)
  localparam [Width-1:0] MaxVal = {Width{1'b1}};
  localparam [Width-1:0] MinVal = {Width{1'b0}};

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // 180 phase shift: Start at the PEAK (Max Value)
      count_o     <= MaxVal;
      // Initialize direction to UP (1) so that in the very next cycle,
      // the "MaxVal" check catches it and flips it to DOWN.
      direction_q <= 1'b1;
    end else begin
      if (direction_q) begin
        // ---------------------------------------------------------------------
        // Counting Up
        // ---------------------------------------------------------------------
        if (count_o == MaxVal) begin
          direction_q <= 1'b0;
          count_o     <= MaxVal - 1'b1; // Turn around -> Down
        end else begin
          count_o <= count_o + 1'b1;
        end
      end else begin
        // ---------------------------------------------------------------------
        // Counting Down
        // ---------------------------------------------------------------------
        if (count_o == MinVal) begin
          direction_q <= 1'b1;
          count_o     <= MinVal + 1'b1; // Turn around -> Up
        end else begin
          count_o <= count_o - 1'b1;
        end
      end
    end
  end

endmodule
