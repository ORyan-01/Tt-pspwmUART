`timescale 1ns / 1ps

module fcc_core (   // MODIFICADO: antes 'top'
  // Clock and Reset
  input  wire        clk_i,           // 27 MHz Tang Nano Clock
  input  wire        rst_ni,           // External Reset (Active-Low: asserted when pulled to 0)

  // ADC 1 Interface (Differential - Flying Cap)
  output wire       scl_1_o,
  input  wire       sda_1_i,      // MODIFICADO: el inout se parte en entrada
  output wire       sda_1_pd_o,   // MODIFICADO: + senal de "tirar a 0" (open drain)

  // ADC 2 Interface (Single Ended - Vout)
  output wire       scl_2_o,
  input  wire       sda_2_i,      // MODIFICADO
  output wire       sda_2_pd_o,   // MODIFICADO

  // PWM Outputs
  output wire [7:0]  pwm_o,

  // Screen
  output wire ioSclk,
  output wire ioSdin,
  output wire ioCs,
  output wire ioDc,
  output wire ioReset,

  // UART
  input wire uart_rx_i
);

  // ---------------------------------------------------------------------------
  // 3. Control System Signals
  // ---------------------------------------------------------------------------
  // Controller Outputs
  wire [6:0]  duty_d1_o;
  wire [6:0]  duty_d2_o;

  wire [15:0] duty_counter_o;

  reg heartbeat_led;

  // Constants
  localparam [15:0] V_FC_REF = 16'h6990;

  // --- Averaging Logic ---
  reg [31:0] sum_fc;       // Accumulator for Flying Cap Voltage
  reg [31:0] sum_out;      // Accumulator for Output Voltage
  reg [11:0] avg_fc_disp;  // Final averaged value for Display
  reg [11:0] avg_out_disp; // Final averaged value for Display

  // --- I2C BUS 1 (ADC 1) ---
    wire [1:0] i2c1_instruction_i;
    wire [7:0] i2c1_byte_to_send_i, i2c1_byte_received_o;
    wire i2c1_complete_o, i2c1_enable_i;
    wire sdaIn_1, sdaOut_1, isSending_1;

    // MODIFICADO: equivalente exacto del tri-state, sobre uio_oe en project.v
    assign sda_1_pd_o = isSending_1 & ~sdaOut_1;
    assign sdaIn_1    = sda_1_i;

    i2c c(
        clk_i, rst_ni, sdaIn_1, sdaOut_1, isSending_1, scl_1_o,
        i2c1_instruction_i, i2c1_enable_i, i2c1_byte_to_send_i, i2c1_byte_received_o, i2c1_complete_o
    );

    // --- I2C BUS 2 (ADC 2) ---
    wire [1:0] i2c2_instruction_i;
    wire [7:0] i2c2_byte_to_send_i, i2c2_byte_received_o;
    wire i2c2_complete_o, i2c2_enable_i;
    wire sdaIn_2, sdaOut_2, isSending_2;

    // Tristate logic for Bus 2
    // MODIFICADO
    assign sda_2_pd_o = isSending_2 & ~sdaOut_2;
    assign sdaIn_2    = sda_2_i;

    i2c c2(
        clk_i, rst_ni, sdaIn_2, sdaOut_2, isSending_2, scl_2_o,
        i2c2_instruction_i, i2c2_enable_i, i2c2_byte_to_send_i, i2c2_byte_received_o, i2c2_complete_o
    );

    // --- ADC INSTANCES ---

    // ADC 1 Control Signals
    reg adc1_enable_i;
    wire [15:0] adc1_data_o;
    wire adc1_ready_o;
    
    // ADC 2 Control Signals
    reg adc2_enable_i;
    wire [15:0] adc2_data_o;
    wire adc2_ready_o;

    // ADC 1 Instance
    adc #(.address(7'b1001001), .MUX_CONFIG(3'b000)) u_adc_1(
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .data_o(adc1_data_o),
        .data_ready_o(adc1_ready_o),
        .enable_i(adc1_enable_i),
        .i2c_instruction_o(i2c1_instruction_i),
        .i2c_enable_o(i2c1_enable_i),
        .i2c_byte_to_send_o(i2c1_byte_to_send_i),
        .i2c_byte_received_i(i2c1_byte_received_o),
        .i2c_complete_i(i2c1_complete_o)
    );

    // ADC 2 Instance (Same address, distinct I2C bus and Mux config)
    adc #(.address(7'b1001001), .MUX_CONFIG(3'b100)) u_adc_2(
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .data_o(adc2_data_o),
        .data_ready_o(adc2_ready_o),
        .enable_i(adc2_enable_i),
        .i2c_instruction_o(i2c2_instruction_i),
        .i2c_enable_o(i2c2_enable_i),
        .i2c_byte_to_send_o(i2c2_byte_to_send_i),
        .i2c_byte_received_i(i2c2_byte_received_o),
        .i2c_complete_i(i2c2_complete_o)
    );

    // --- DATA BUFFERS ---
    reg [15:0] adc_voltage_fc_o;
    reg [15:0] adc_voltage_out_o;

    // --- FSM STATE MACHINE ---
    localparam STATE_TRIGGER_CONV = 0;
    localparam STATE_WAIT_FOR_START = 1;
    localparam STATE_SAVE_VALUE_WHEN_READY = 2;

    reg [2:0] drawState;
    
    // Flags to ensure we capture both channels before resetting
    reg adc1_done_o;
    reg adc2_done_o;
    reg adc_eoc_o;
    wire adc_start_i;

    // fsm_adc: Main ADC Control FSM
    always @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        drawState <= STATE_TRIGGER_CONV;
        adc_eoc_o <= 0;
        adc1_enable_i <= 0;
        adc2_enable_i <= 0;
        adc_voltage_fc_o <= 0;
        adc_voltage_out_o <= 0;
        adc1_done_o <= 0;
        adc2_done_o <= 0;
      end else begin
        case (drawState)
            STATE_TRIGGER_CONV: begin
              adc_eoc_o <= 0;
              if(adc_start_i) begin
                // Trigger both ADCs
                adc1_enable_i <= 1;
                adc2_enable_i <= 1;
                adc1_done_o <= 0;
                adc2_done_o <= 0;
                drawState <= STATE_WAIT_FOR_START;
              end
            end
            STATE_WAIT_FOR_START: begin
                // Wait for both to acknowledge (DataReady goes LOW when busy)
                // We proceed only when both are busy to ensure we don't catch a stale "Ready"
                if (~adc1_ready_o && ~adc2_ready_o) begin
                    drawState <= STATE_SAVE_VALUE_WHEN_READY;
                end
            end
            STATE_SAVE_VALUE_WHEN_READY: begin
                // Capture Channel 1
                if (adc1_ready_o && !adc1_done_o) begin
                    adc_voltage_fc_o <= adc1_data_o[15] ? 16'd0 : {adc1_data_o[14:0], 1'b0};
                    adc1_enable_i <= 0; // Stop ADC 1
                    adc1_done_o <= 1;
                end

                // Capture Channel 2
                if (adc2_ready_o && !adc2_done_o) begin
                    adc_voltage_out_o <= adc2_data_o[15] ? 16'd0 : {adc2_data_o[14:0], 1'b0};
                    adc2_enable_i <= 0; // Stop ADC 2
                    adc2_done_o <= 1;
                end

                // Go back only when both are done
                if (adc1_done_o && adc2_done_o) begin
                    adc_eoc_o <= 1;
                    drawState <= STATE_TRIGGER_CONV;
                end
            end
            default: begin
                drawState <= STATE_TRIGGER_CONV;
            end
        endcase
      end
    end

    wire enable_control_i;

  // ---------------------------------------------------------------------------
  // Synchronization Logic
  // ---------------------------------------------------------------------------
  // Only run the controller when BOTH ADCs have finished

  // Timer Control
  timer_control #(
    .CountMax (43200)
  ) u_timer_ctrl (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .eoc_i     (adc_eoc_o),
    .trigger_o (enable_control_i)
  );

  /// --------------------------------------------------------------------------
  // Control Algorithm
  // ---------------------------------------------------------------------------
  fcc_fixpt u_controller (
    .clk        (clk_i),
    .reset      (~rst_ni),
    .clk_enable (enable_control_i), // Waits for both ADCs
    .Voutref    (duty_counter_o),
    .Vout       (adc_voltage_out_o),     // Direct connection from ADC 2
    .Vfcref     (V_FC_REF),
    .Vfc        (adc_voltage_fc_o),      // Direct connection from ADC 1
    .D1         (duty_d1_o),
    .D2         (duty_d2_o)
  );

  /// ---------------------------------------------------------------------------
  // Average Sampling Time Calculation
  /// ---------------------------------------------------------------------------

  reg [24:0] clk_counter;
  reg [15:0] sample_count;       // Increased to 16-bit to prevent overflow > 4095Hz
  reg [15:0] freq_display_hold;  // NEW: Holds the value to show on screen

  // --- ANADIDO: division secuencial -----------------------------------------
  // El '/' combinacional de 32/16 bits genera un divisor enorme y con un camino
  // critico de cientos de niveles logicos: no cierra temporizado en ASIC.
  // div_u32 entrega EXACTAMENTE el mismo cociente entero, en 33 ciclos.
  wire second_tick = (clk_counter == 25'd27000000);

  localparam AVG_IDLE = 2'd0, AVG_FC = 2'd1, AVG_OUT = 2'd2;
  reg  [1:0]  avg_state;
  reg  [31:0] pend_sum_out;
  reg  [31:0] div_num;
  reg  [15:0] div_den;
  reg         div_start;
  wire [31:0] div_quot;
  wire        div_done;

  div_u32 u_div (
      .clk_i   (clk_i),
      .rst_ni  (rst_ni),
      .start_i (div_start),
      .num_i   (div_num),
      .den_i   (div_den),
      .quot_o  (div_quot),
      .done_o  (div_done)
  );

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      avg_state    <= AVG_IDLE;
      pend_sum_out <= 0;
      div_num      <= 0;
      div_den      <= 0;
      div_start    <= 1'b0;
    end else begin
      div_start <= 1'b0;
      case (avg_state)
        AVG_IDLE: if (second_tick && (sample_count != 0)) begin
                    div_num      <= sum_fc;
                    div_den      <= sample_count;
                    pend_sum_out <= sum_out;
                    div_start    <= 1'b1;
                    avg_state    <= AVG_FC;
                  end
        AVG_FC:   if (div_done) begin
                    div_num   <= pend_sum_out;
                    div_start <= 1'b1;
                    avg_state <= AVG_OUT;
                  end
        AVG_OUT:  if (div_done) avg_state <= AVG_IDLE;
        default:  avg_state <= AVG_IDLE;
      endcase
    end
  end
  // --------------------------------------------------------------------------

  always @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
      clk_counter <= 0;
      heartbeat_led <= 1;
      sample_count <= 0;
      freq_display_hold <= 0;

      // Reset Averaging
      sum_fc <= 0;
      sum_out <= 0;
      avg_fc_disp <= 0;
      avg_out_disp <= 0;

    end else begin
      // 1. Accumulate Samples
      if (adc1_done_o && adc2_done_o) begin
        sample_count <= sample_count + 1;
        sum_fc <= sum_fc + adc_voltage_fc_o;   // Add current FC sample
        sum_out <= sum_out + adc_voltage_out_o; // Add current Out sample
      end

      // ANADIDO: los promedios llegan desde div_u32 (mismo valor que el '/')
      if (div_done && (avg_state == AVG_FC))  avg_fc_disp  <= div_quot[15:4];
      if (div_done && (avg_state == AVG_OUT)) avg_out_disp <= div_quot[15:4];

      // 2. One Second Timer (27 MHz)
      if(clk_counter == 25'd27000000) begin
        clk_counter <= 0;

        // LATCH: Save Frequency
        freq_display_hold <= sample_count;

        // LATCH: Calculate Average for Display
        // Avoid divide-by-zero if system is paused
        // MODIFICADO: el calculo lo hace div_u32 (arranca en este mismo flanco)
        if (sample_count == 0) begin
            avg_fc_disp <= 0;
            avg_out_disp <= 0;
        end

        // RESET: Clear counters for the new second
        sample_count <= 0;
        sum_fc <= 0;
        sum_out <= 0;

        // Toggle Heartbeat
        heartbeat_led <= ~heartbeat_led;
        
      end else begin
        clk_counter <= clk_counter + 1;
      end
    end
  end

  assign pwm_o[5] = heartbeat_led;

  wire [7:0] thousands_counter, hundreds_counter, tens_counter, units_counter;

  // 3. Connect the HOLD register (Static Value) to the display, not the counter
  toDec dec3(
    clk_i,
    rst_ni,
    freq_display_hold[11:0],
    ,
    thousands_counter, 
    hundreds_counter, 
    tens_counter, 
    units_counter
  );

  // --- DISPLAY CONVERSION ---

  wire [7:0] voltage_fc_thousands_o, voltage_fc_hundreds_o, voltage_fc_tens_o, voltage_fc_units_o;
  wire [7:0] voltage_out_thousands_o, voltage_out_hundreds_o, voltage_out_tens_o, voltage_out_units_o;

  // Wires for Decimal Converter Outputs
  wire [7:0] d1_tth, d1_th, d1_hu, d1_te, d1_un;

  toDec dec(
      clk_i, rst_ni, avg_fc_disp, , voltage_fc_thousands_o, voltage_fc_hundreds_o, voltage_fc_tens_o, voltage_fc_units_o
  );
  toDec dec2(
      clk_i, rst_ni, avg_out_disp, , voltage_out_thousands_o, voltage_out_hundreds_o, voltage_out_tens_o, voltage_out_units_o
  );

  // --- TRANSFORMATION LOGIC ---
  // Scale by 4099/65536 to approx 0.06254, then add 2 (approx 1.9 rounded)
  wire [31:0] v_calc_temp;
  wire [15:0] v_ref_display;
  
  // High-performance fixed-point multiplication
  assign v_calc_temp = duty_counter_o * 32'd4099;
  
  // Right shift by 16 (divide by 65536) and add offset
  assign v_ref_display = v_calc_temp[31:16] + 16'd2;

  toDec dec_vout_ref(
      clk_i, rst_ni, 
      v_ref_display, // CHANGED: Pass the transformed value here
      d1_tth,
      d1_th, d1_hu, d1_te, d1_un
  );

  // --- SCREEN & TEXT ENGINE ---
  wire [9:0] pixel_address;
  wire [7:0] pixel_data;
  wire [5:0] text_char_address_i;
  reg [7:0] text_char_o;

  screen #(32'd10000000) u_scr(
      .clk_i(clk_i),
      .rst_ni(rst_ni),      // ANADIDO
      .sclk_o(ioSclk),
      .sdin_o(ioSdin),
      .cs_o(ioCs),
      .dc_o(ioDc),
      .reset_o(ioReset),
      .pixel_address_o(pixel_address),
      .pixel_data_i(pixel_data)
  );
  textEngine u_text(
      .clk_i(clk_i),
      .pixel_address_i(pixel_address),
      .pixel_data_o(pixel_data),
      .char_address_o(text_char_address_i),
      .char_data_i(text_char_o)
  );

  // --- TEXT RENDERING ---
  wire [1:0] row_number;
  assign row_number = text_char_address_i[5:4];
  
  always @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
      text_char_o <= 8'd0;
    end
    else
      if (row_number == 2'd0) begin
          // Row 0: Ch1 Volts
          case (text_char_address_i[3:0])
              0: text_char_o <= "D";
              1: text_char_o <= "i";
              2: text_char_o <= "f";
              4: text_char_o <= voltage_fc_thousands_o;
              5: text_char_o <= ".";
              6: text_char_o <= voltage_fc_hundreds_o;
              7: text_char_o <= voltage_fc_tens_o;
              8: text_char_o <= voltage_fc_units_o;
              10: text_char_o <= "V";
              11: text_char_o <= "o";
              12: text_char_o <= "l";
              13: text_char_o <= "t";
              14: text_char_o <= "s";
              default: text_char_o <= " ";
          endcase
      end
      else if (row_number == 2'd1) begin
          // Row 1: Ch2 Volts
          case (text_char_address_i[3:0])
              0: text_char_o <= "O"; // Ch2
              1: text_char_o <= "u";
              2: text_char_o <= "t";
              4: text_char_o <= voltage_out_thousands_o;
              5: text_char_o <= ".";
              6: text_char_o <= voltage_out_hundreds_o;
              7: text_char_o <= voltage_out_tens_o;
              8: text_char_o <= voltage_out_units_o;
              10: text_char_o <= "V";
              11: text_char_o <= "o";
              12: text_char_o <= "l";
              13: text_char_o <= "t";
              14: text_char_o <= "s";
              default: text_char_o <= " ";
          endcase
      end
      else if (row_number == 2'd2) begin
          // Row 3: Sampling Frequency
          case (text_char_address_i[3:0])
              0: text_char_o <= "F"; // Ch2
              1: text_char_o <= "s";
              //4: text_char_o <= thousands_counter;
              //5: text_char_o <= ".";
              6: text_char_o <= hundreds_counter;
              7: text_char_o <= tens_counter;
              8: text_char_o <= units_counter;
              10: text_char_o <= "H";
              11: text_char_o <= "z";
              default: text_char_o <= " ";
          endcase
      end
      else if (row_number == 2'd3) begin
          // Row 3: Duty Cycles
          case (text_char_address_i[3:0])
              // Label "Vref:"
              0: text_char_o <= "V";
              1: text_char_o <= "r";
              2: text_char_o <= "e";
              3: text_char_o <= "f";
              4: text_char_o <= ":";
              
              // Value Display: #.### format
              6: text_char_o <= d1_th;  // Integer part (Thousands place of 1234 -> 1)
              7: text_char_o <= ".";    // Decimal Point
              8: text_char_o <= d1_hu;  // Tenths
              9: text_char_o <= d1_te;  // Hundredths
              10: text_char_o <= d1_un; // Thousandths
              
              // Unit "V"
              11: text_char_o <= " ";   // Spacer
              12: text_char_o <= "V";
              
              default: text_char_o <= " ";
          endcase
      end
  end

  /// ---------------------------------------------------------------------------
  // UART
  /// ---------------------------------------------------------------------------

  uart u_uart (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),    // ANADIDO
    .rx_i      (uart_rx_i),
    .counter_o (duty_counter_o)
  );

  /// ---------------------------------------------------------------------------
  // PS-PWM MODULATOR
  /// ---------------------------------------------------------------------------

  // PS-PWM Modulator
  wire [3:0] pwm_signals_o;

  ps_pwm u_modulator (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .duty_d1_i     (duty_d1_o),
    .duty_d2_i     (duty_d2_o),
    .adc_trigger_o (adc_start_i),
    .pwm_o         (pwm_signals_o)
  );

  // ---------------------------------------------------------------------------
  // 7. Output Assignments
  // ---------------------------------------------------------------------------
  // Bits 0-3: PWM Signals
  assign pwm_o[3:0] = pwm_signals_o;

  // Bits 4-7: Debug / Static outputs (Keep original behavior)
  assign pwm_o[4]   = 1'b1;
  assign pwm_o[6]   = 1'b0;
  assign pwm_o[7]   = 1'b0;

endmodule
