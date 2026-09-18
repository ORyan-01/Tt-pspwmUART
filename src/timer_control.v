`timescale 1ns / 1ps

module timer_control #(
  parameter counter_width = 16,
  parameter [counter_width-1:0] CountMax = 750 // 7.5us @ 100MHz (or 6us @ 125MHz)
) (
  input  wire clk_i,      // System Clock
  input  wire rst_ni,     // Active-Low Asynchronous Reset
  input  wire eoc_i,      // End of Conversion (EOC) pulse
  output reg  trigger_o   // Trigger pulse output
);

  reg [counter_width-1:0] counter_q;
  reg       timer_done_q;
  reg       wait_eoc_q;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      counter_q    <= {counter_width{1'b0}};
      timer_done_q <= 1'b0;
      wait_eoc_q   <= 1'b0;
      trigger_o    <= 1'b0;
    end else begin
      // Default: Pulse is low unless set high specifically in this cycle
      trigger_o <= 1'b0;

      // 1. Timer Logic
      if (!timer_done_q) begin
        if (counter_q < CountMax) begin
          counter_q <= counter_q + 1'b1;
        end else begin
          timer_done_q <= 1'b1;
          wait_eoc_q   <= 1'b1; // Start waiting for EOC
        end
      end

      // 2. Synchronization Logic
      // Wait for EOC pulse after timer has expired
      if (wait_eoc_q && eoc_i) begin
        trigger_o    <= 1'b1;   // Generate single-cycle pulse
        counter_q    <= {counter_width{1'b0}};  // Reset counter
        timer_done_q <= 1'b0;
        wait_eoc_q   <= 1'b0;
      end
    end
  end

endmodule
