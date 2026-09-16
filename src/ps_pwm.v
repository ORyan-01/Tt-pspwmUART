`default_nettype none

`timescale 1ns / 1ps

module ps_pwm (
  input wire       clk_i,          // Main System Clock
  input wire       rst_ni,         // Active-Low Asynchronous Reset

  input wire [6:0] duty_d1_i,      // Duty Cycle 1 (from controller)
  input wire [6:0] duty_d2_i,      // Duty Cycle 2 (from controller)

  output wire       adc_trigger_o,  // Trigger for ADC (was XADC_Event)
  output wire [3:0] pwm_o           // PWM Outputs (JE)
);

  // Configuration
  localparam [4:0] DeadTime = 5'd4;

  // ---------------------------------------------------------------------------
  // 1. Triangular Carrier Generation
  // ---------------------------------------------------------------------------
  wire [6:0] triangular_0;

  signal_generator_0phase u_sig_gen_0 (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .trigger_o     (adc_trigger_o),
    .count_o       (triangular_0)
  );

  wire [6:0] triangular_180;

  signal_generator_180phase u_sig_gen_180 (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .count_o       (triangular_180)
  );

  // ---------------------------------------------------------------------------
  // 2. Comparison Stage
  // ---------------------------------------------------------------------------
  wire cmp_out_1;

  comparator u_cmp_1 (
    .in1_i         (duty_d1_i),
    .in2_i         (triangular_0),
    .cmp_o         (cmp_out_1)
  );

  wire cmp_out_2;

  comparator u_cmp_2 (
    .in1_i         (duty_d2_i),
    .in2_i         (triangular_180),
    .cmp_o         (cmp_out_2)
  );

  // ---------------------------------------------------------------------------
  // 3. Dead-Time Generation
  // ---------------------------------------------------------------------------
  // Channel 1 Logic
  wire pmos1_delayed;

  dead_time_generator #(
    .DeadTimeWidth (5)
  ) u_dt_gen_1 (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .dt_i          (DeadTime),
    .signal_i      (cmp_out_1),
    .signal_delayed_o (pmos1_delayed)
  );

  wire not_cmp_out_1;
  wire nmos2_delayed;

  assign not_cmp_out_1 = ~cmp_out_1;

  dead_time_generator #(
    .DeadTimeWidth (5)
  ) u_dt_gen_2 (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .dt_i          (DeadTime),
    .signal_i      (not_cmp_out_1),
    .signal_delayed_o (nmos2_delayed)
  );

  // Channel 2 Logic
  wire pmos2_delayed;

  dead_time_generator #(
    .DeadTimeWidth (5)
  ) u_dt_gen_3 (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .dt_i          (DeadTime),
    .signal_i      (cmp_out_2),
    .signal_delayed_o (pmos2_delayed)
  );

  wire not_cmp_out_2;
  wire nmos1_delayed;

  assign not_cmp_out_2 = ~cmp_out_2;

  dead_time_generator #(
    .DeadTimeWidth (5)
  ) u_dt_gen_4 (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .dt_i          (DeadTime),
    .signal_i      (not_cmp_out_2),
    .signal_delayed_o (nmos1_delayed)
  );

  // ---------------------------------------------------------------------------
  // 4. Output Stage (Safe State Logic)
  // ---------------------------------------------------------------------------
  // If Reset is active (0), force safe states.
  // Original logic: JE[0,1] = 1, JE[2,3] = 0 on Reset.

  assign pwm_o[0] = (!rst_ni) ? 1'b1 : ~pmos1_delayed;
  assign pwm_o[1] = (!rst_ni) ? 1'b1 : ~pmos2_delayed;
  assign pwm_o[2] = (!rst_ni) ? 1'b0 : nmos1_delayed;
  assign pwm_o[3] = (!rst_ni) ? 1'b0 : nmos2_delayed;

endmodule

`default_nettype wire
