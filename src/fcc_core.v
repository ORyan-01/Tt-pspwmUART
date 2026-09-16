// ---------------------------------------------------------------------------
// fcc_core.v  -  antes 3LFCC/src/top.v
//
// Cambios respecto al original y motivo (ninguno altera la funcion):
//
//  1) Los inout sda_1_io / sda_2_io se parten en sda_x_i + sda_x_pd_o.
//     El tri-state vive ahora en project.v sobre uio_oe.  Es la traduccion
//     literal de   sda = (isSending & ~sdaOut) ? 1'b0 : 1'bz;
//
//  2) Las divisiones  (sum / sample_count)  se hacen con un divisor
//     secuencial compartido (div_u32).  Resultado BIT A BIT IDENTICO
//     (division entera sin signo, truncada), solo que disponible ~66 ciclos
//     despues.  El display se refresca 1 vez por segundo: 2.4 us de retardo
//     no se ven.  Motivo: en ASIC un '/' de 32/16 bits sintetiza un divisor
//     combinacional enorme que jamas cerraria temporizado.
//
//  3) duty_counter_o * 4099 se escribe como (x<<12)+(x<<1)+x.  Identico bit
//     a bit, pero sin instanciar un multiplicador.
//
//  4) Conexiones por nombre en vez de por posicion (mismos puertos).
// ---------------------------------------------------------------------------

`default_nettype none

module fcc_core (
    // Clock and Reset
    input  wire        clk_i,        // 27 MHz
    input  wire        rst_ni,       // Reset externo activo en bajo

    // ADC 1 (diferencial - Flying Cap)
    output wire        scl_1_o,
    input  wire        sda_1_i,      // valor leido del pad
    output wire        sda_1_pd_o,   // 1 => tirar el pad a 0 (open drain)

    // ADC 2 (single ended - Vout)
    output wire        scl_2_o,
    input  wire        sda_2_i,
    output wire        sda_2_pd_o,

    // PWM
    output wire [7:0]  pwm_o,

    // OLED
    output wire        oled_sclk_o,
    output wire        oled_sdin_o,
    output wire        oled_cs_o,
    output wire        oled_dc_o,
    output wire        oled_res_o,

    // UART
    input  wire        uart_rx_i
);

  // ---------------------------------------------------------------------------
  // Señales del sistema de control
  // ---------------------------------------------------------------------------
  wire [6:0]  duty_d1_o;
  wire [6:0]  duty_d2_o;
  wire [15:0] duty_counter_o;

  reg heartbeat_led;

  localparam [15:0] V_FC_REF = 16'h6990;

  // --- Promediado ---
  reg [31:0] sum_fc;
  reg [31:0] sum_out;
  reg [11:0] avg_fc_disp;
  reg [11:0] avg_out_disp;

  // ---------------------------------------------------------------------------
  // I2C BUS 1 (ADC 1)
  // ---------------------------------------------------------------------------
  wire [1:0] i2c1_instruction_i;
  wire [7:0] i2c1_byte_to_send_i, i2c1_byte_received_o;
  wire       i2c1_complete_o, i2c1_enable_i;
  wire       sdaIn_1, sdaOut_1, isSending_1;

  // Original: assign sda_1_io = (isSending_1 & ~sdaOut_1) ? 1'b0 : 1'bz;
  assign sda_1_pd_o = isSending_1 & ~sdaOut_1;
  assign sdaIn_1    = sda_1_i;

  i2c c (
      .clk_i           (clk_i),
      .rst_ni          (rst_ni),
      .sda_i           (sdaIn_1),
      .sda_o           (sdaOut_1),
      .is_sending_o    (isSending_1),
      .scl_o           (scl_1_o),
      .instruction_i   (i2c1_instruction_i),
      .enable_i        (i2c1_enable_i),
      .byte_to_send_i  (i2c1_byte_to_send_i),
      .byte_received_o (i2c1_byte_received_o),
      .complete_o      (i2c1_complete_o)
  );

  // ---------------------------------------------------------------------------
  // I2C BUS 2 (ADC 2)
  // ---------------------------------------------------------------------------
  wire [1:0] i2c2_instruction_i;
  wire [7:0] i2c2_byte_to_send_i, i2c2_byte_received_o;
  wire       i2c2_complete_o, i2c2_enable_i;
  wire       sdaIn_2, sdaOut_2, isSending_2;

  assign sda_2_pd_o = isSending_2 & ~sdaOut_2;
  assign sdaIn_2    = sda_2_i;

  i2c c2 (
      .clk_i           (clk_i),
      .rst_ni          (rst_ni),
      .sda_i           (sdaIn_2),
      .sda_o           (sdaOut_2),
      .is_sending_o    (isSending_2),
      .scl_o           (scl_2_o),
      .instruction_i   (i2c2_instruction_i),
      .enable_i        (i2c2_enable_i),
      .byte_to_send_i  (i2c2_byte_to_send_i),
      .byte_received_o (i2c2_byte_received_o),
      .complete_o      (i2c2_complete_o)
  );

  // ---------------------------------------------------------------------------
  // ADCs
  // ---------------------------------------------------------------------------
  reg         adc1_enable_i;
  wire [15:0] adc1_data_o;
  wire        adc1_ready_o;

  reg         adc2_enable_i;
  wire [15:0] adc2_data_o;
  wire        adc2_ready_o;

  adc #(.address(7'b1001001), .MUX_CONFIG(3'b000)) u_adc_1 (
      .clk_i               (clk_i),
      .rst_ni              (rst_ni),
      .data_o              (adc1_data_o),
      .data_ready_o        (adc1_ready_o),
      .enable_i            (adc1_enable_i),
      .i2c_instruction_o   (i2c1_instruction_i),
      .i2c_enable_o        (i2c1_enable_i),
      .i2c_byte_to_send_o  (i2c1_byte_to_send_i),
      .i2c_byte_received_i (i2c1_byte_received_o),
      .i2c_complete_i      (i2c1_complete_o)
  );

  adc #(.address(7'b1001001), .MUX_CONFIG(3'b100)) u_adc_2 (
      .clk_i               (clk_i),
      .rst_ni              (rst_ni),
      .data_o              (adc2_data_o),
      .data_ready_o        (adc2_ready_o),
      .enable_i            (adc2_enable_i),
      .i2c_instruction_o   (i2c2_instruction_i),
      .i2c_enable_o        (i2c2_enable_i),
      .i2c_byte_to_send_o  (i2c2_byte_to_send_i),
      .i2c_byte_received_i (i2c2_byte_received_o),
      .i2c_complete_i      (i2c2_complete_o)
  );

  // --- Buffers de datos ---
  reg [15:0] adc_voltage_fc_o;
  reg [15:0] adc_voltage_out_o;

  // --- FSM de adquisicion ---
  localparam STATE_TRIGGER_CONV          = 0;
  localparam STATE_WAIT_FOR_START        = 1;
  localparam STATE_SAVE_VALUE_WHEN_READY = 2;

  reg [2:0] drawState;

  reg  adc1_done_o;
  reg  adc2_done_o;
  reg  adc_eoc_o;
  wire adc_start_i;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      drawState         <= STATE_TRIGGER_CONV;
      adc_eoc_o         <= 0;
      adc1_enable_i     <= 0;
      adc2_enable_i     <= 0;
      adc_voltage_fc_o  <= 0;
      adc_voltage_out_o <= 0;
      adc1_done_o       <= 0;
      adc2_done_o       <= 0;
    end else begin
      case (drawState)
        STATE_TRIGGER_CONV: begin
          adc_eoc_o <= 0;
          if (adc_start_i) begin
            adc1_enable_i <= 1;
            adc2_enable_i <= 1;
            adc1_done_o   <= 0;
            adc2_done_o   <= 0;
            drawState     <= STATE_WAIT_FOR_START;
          end
        end
        STATE_WAIT_FOR_START: begin
          if (~adc1_ready_o && ~adc2_ready_o) begin
            drawState <= STATE_SAVE_VALUE_WHEN_READY;
          end
        end
        STATE_SAVE_VALUE_WHEN_READY: begin
          if (adc1_ready_o && !adc1_done_o) begin
            adc_voltage_fc_o <= adc1_data_o[15] ? 16'd0 : {adc1_data_o[14:0], 1'b0};
            adc1_enable_i    <= 0;
            adc1_done_o      <= 1;
          end

          if (adc2_ready_o && !adc2_done_o) begin
            adc_voltage_out_o <= adc2_data_o[15] ? 16'd0 : {adc2_data_o[14:0], 1'b0};
            adc2_enable_i     <= 0;
            adc2_done_o       <= 1;
          end

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
  // Timer de control
  // ---------------------------------------------------------------------------
  timer_control #(
      .CountMax (43200)
  ) u_timer_ctrl (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .eoc_i     (adc_eoc_o),
      .trigger_o (enable_control_i)
  );

  // ---------------------------------------------------------------------------
  // Algoritmo de control
  // ---------------------------------------------------------------------------
  wire               fcc_ce_out;   // salidas de fcc_fixpt que el diseno
  wire [20:0]        fcc_ui;       // original nunca conectaba
  wire signed [10:0] fcc_uv;

  fcc_fixpt u_controller (
      .clk        (clk_i),
      .reset      (~rst_ni),
      .clk_enable (enable_control_i),
      .Voutref    (duty_counter_o),
      .Vout       (adc_voltage_out_o),
      .Vfcref     (V_FC_REF),
      .Vfc        (adc_voltage_fc_o),
      .D1         (duty_d1_o),
      .D2         (duty_d2_o),
      .ce_out     (fcc_ce_out),
      .ui         (fcc_ui),
      .uv         (fcc_uv)
  );

  // ---------------------------------------------------------------------------
  // Frecuencia de muestreo + promedio
  // ---------------------------------------------------------------------------
  reg [24:0] clk_counter;
  reg [15:0] sample_count;
  reg [15:0] freq_display_hold;

  wire second_tick = (clk_counter == 25'd27000000);

  // --- divisor secuencial compartido ---
  localparam AVG_IDLE = 2'd0;
  localparam AVG_FC   = 2'd1;
  localparam AVG_OUT  = 2'd2;

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
      pend_sum_out <= 32'd0;
      div_num      <= 32'd0;
      div_den      <= 16'd0;
      div_start    <= 1'b0;
    end else begin
      div_start <= 1'b0;
      case (avg_state)
        AVG_IDLE: begin
          // Se capturan sum_* y sample_count en el mismo flanco en que el
          // original hacia la division, antes de que se pongan a cero.
          if (second_tick && (sample_count != 16'd0)) begin
            div_num      <= sum_fc;
            div_den      <= sample_count;
            pend_sum_out <= sum_out;
            div_start    <= 1'b1;
            avg_state    <= AVG_FC;
          end
        end
        AVG_FC: begin
          if (div_done) begin
            div_num   <= pend_sum_out;   // div_den se mantiene
            div_start <= 1'b1;
            avg_state <= AVG_OUT;
          end
        end
        AVG_OUT: begin
          if (div_done) avg_state <= AVG_IDLE;
        end
        default: avg_state <= AVG_IDLE;
      endcase
    end
  end

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      clk_counter       <= 0;
      heartbeat_led     <= 1;
      sample_count      <= 0;
      freq_display_hold <= 0;

      sum_fc       <= 0;
      sum_out      <= 0;
      avg_fc_disp  <= 0;
      avg_out_disp <= 0;

    end else begin
      // 1. Acumulacion de muestras
      if (adc1_done_o && adc2_done_o) begin
        sample_count <= sample_count + 1;
        sum_fc       <= sum_fc  + {16'd0, adc_voltage_fc_o};
        sum_out      <= sum_out + {16'd0, adc_voltage_out_o};
      end

      // 2. Resultado de la division (mismo valor que (sum/count)>>4)
      if (div_done && (avg_state == AVG_FC))  avg_fc_disp  <= div_quot[15:4];
      if (div_done && (avg_state == AVG_OUT)) avg_out_disp <= div_quot[15:4];

      // 3. Temporizador de 1 segundo (27 MHz)
      if (second_tick) begin
        clk_counter <= 0;

        // LATCH: frecuencia
        freq_display_hold <= sample_count;

        // Sin muestras -> 0 directo, igual que el original
        if (sample_count == 16'd0) begin
          avg_fc_disp  <= 0;
          avg_out_disp <= 0;
        end

        // RESET de acumuladores
        sample_count <= 0;
        sum_fc       <= 0;
        sum_out      <= 0;

        // Heartbeat
        heartbeat_led <= ~heartbeat_led;

      end else begin
        clk_counter <= clk_counter + 1;
      end
    end
  end

  wire [7:0] thousands_counter, hundreds_counter, tens_counter, units_counter;

  // Decenas de millar de los toDec: el diseno original no las pinta.
  wire [7:0] freq_tth_unused, fc_tth_unused, out_tth_unused;

  toDec dec3 (
      .clk           (clk_i),
      .rst_ni        (rst_ni),
      .value         ({4'd0, freq_display_hold[11:0]}),
      .ten_thousands (freq_tth_unused),
      .thousands     (thousands_counter),
      .hundreds      (hundreds_counter),
      .tens          (tens_counter),
      .units         (units_counter)
  );

  // ---------------------------------------------------------------------------
  // Conversion para el display
  // ---------------------------------------------------------------------------
  wire [7:0] voltage_fc_thousands_o,  voltage_fc_hundreds_o,  voltage_fc_tens_o,  voltage_fc_units_o;
  wire [7:0] voltage_out_thousands_o, voltage_out_hundreds_o, voltage_out_tens_o, voltage_out_units_o;

  wire [7:0] d1_tth, d1_th, d1_hu, d1_te, d1_un;

  toDec dec (
      .clk           (clk_i),
      .rst_ni        (rst_ni),
      .value         ({4'd0, avg_fc_disp}),
      .ten_thousands (fc_tth_unused),
      .thousands     (voltage_fc_thousands_o),
      .hundreds      (voltage_fc_hundreds_o),
      .tens          (voltage_fc_tens_o),
      .units         (voltage_fc_units_o)
  );

  toDec dec2 (
      .clk           (clk_i),
      .rst_ni        (rst_ni),
      .value         ({4'd0, avg_out_disp}),
      .ten_thousands (out_tth_unused),
      .thousands     (voltage_out_thousands_o),
      .hundreds      (voltage_out_hundreds_o),
      .tens          (voltage_out_tens_o),
      .units         (voltage_out_units_o)
  );

  // --- Escalado 4099/65536 + offset 2 ---
  // Original: v_calc_temp = duty_counter_o * 32'd4099;
  // 4099 = 4096 + 2 + 1  ->  (x<<12) + (x<<1) + x   (identico bit a bit)
  wire [31:0] duty_ext = {16'd0, duty_counter_o};
  wire [31:0] v_calc_temp = (duty_ext << 12) + (duty_ext << 1) + duty_ext;
  wire [15:0] v_ref_display = v_calc_temp[31:16] + 16'd2;

  toDec dec_vout_ref (
      .clk           (clk_i),
      .rst_ni        (rst_ni),
      .value         (v_ref_display),
      .ten_thousands (d1_tth),
      .thousands     (d1_th),
      .hundreds      (d1_hu),
      .tens          (d1_te),
      .units         (d1_un)
  );

  // ---------------------------------------------------------------------------
  // Pantalla y motor de texto
  // ---------------------------------------------------------------------------
  wire [9:0] pixel_address;
  wire [7:0] pixel_data;
  wire [5:0] text_char_address_i;
  reg  [7:0] text_char_o;

  screen #(.STARTUP_WAIT(32'd10000000)) u_scr (
      .clk_i           (clk_i),
      .rst_ni          (rst_ni),
      .sclk_o          (oled_sclk_o),
      .sdin_o          (oled_sdin_o),
      .cs_o            (oled_cs_o),
      .dc_o            (oled_dc_o),
      .reset_o         (oled_res_o),
      .pixel_address_o (pixel_address),
      .pixel_data_i    (pixel_data)
  );

  textEngine u_text (
      .clk_i           (clk_i),
      .rst_ni          (rst_ni),
      .pixel_address_i (pixel_address),
      .pixel_data_o    (pixel_data),
      .char_address_o  (text_char_address_i),
      .char_data_i     (text_char_o)
  );

  // ---------------------------------------------------------------------------
  // Render de texto
  // ---------------------------------------------------------------------------
  wire [1:0] row_number;
  assign row_number = text_char_address_i[5:4];

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      text_char_o <= 8'd0;
    end
    else
      if (row_number == 2'd0) begin
        // Fila 0: Ch1 Volts
        case (text_char_address_i[3:0])
          0:  text_char_o <= "D";
          1:  text_char_o <= "i";
          2:  text_char_o <= "f";
          4:  text_char_o <= voltage_fc_thousands_o;
          5:  text_char_o <= ".";
          6:  text_char_o <= voltage_fc_hundreds_o;
          7:  text_char_o <= voltage_fc_tens_o;
          8:  text_char_o <= voltage_fc_units_o;
          10: text_char_o <= "V";
          11: text_char_o <= "o";
          12: text_char_o <= "l";
          13: text_char_o <= "t";
          14: text_char_o <= "s";
          default: text_char_o <= " ";
        endcase
      end
      else if (row_number == 2'd1) begin
        // Fila 1: Ch2 Volts
        case (text_char_address_i[3:0])
          0:  text_char_o <= "O";
          1:  text_char_o <= "u";
          2:  text_char_o <= "t";
          4:  text_char_o <= voltage_out_thousands_o;
          5:  text_char_o <= ".";
          6:  text_char_o <= voltage_out_hundreds_o;
          7:  text_char_o <= voltage_out_tens_o;
          8:  text_char_o <= voltage_out_units_o;
          10: text_char_o <= "V";
          11: text_char_o <= "o";
          12: text_char_o <= "l";
          13: text_char_o <= "t";
          14: text_char_o <= "s";
          default: text_char_o <= " ";
        endcase
      end
      else if (row_number == 2'd2) begin
        // Fila 2: frecuencia de muestreo
        case (text_char_address_i[3:0])
          0:  text_char_o <= "F";
          1:  text_char_o <= "s";
          //4: text_char_o <= thousands_counter;
          //5: text_char_o <= ".";
          6:  text_char_o <= hundreds_counter;
          7:  text_char_o <= tens_counter;
          8:  text_char_o <= units_counter;
          10: text_char_o <= "H";
          11: text_char_o <= "z";
          default: text_char_o <= " ";
        endcase
      end
      else if (row_number == 2'd3) begin
        // Fila 3: Vref
        case (text_char_address_i[3:0])
          0:  text_char_o <= "V";
          1:  text_char_o <= "r";
          2:  text_char_o <= "e";
          3:  text_char_o <= "f";
          4:  text_char_o <= ":";

          6:  text_char_o <= d1_th;
          7:  text_char_o <= ".";
          8:  text_char_o <= d1_hu;
          9:  text_char_o <= d1_te;
          10: text_char_o <= d1_un;

          11: text_char_o <= " ";
          12: text_char_o <= "V";

          default: text_char_o <= " ";
        endcase
      end
  end

  // ---------------------------------------------------------------------------
  // UART
  // ---------------------------------------------------------------------------
  uart u_uart (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .rx_i      (uart_rx_i),
      .counter_o (duty_counter_o)
  );

  // ---------------------------------------------------------------------------
  // Modulador PS-PWM
  // ---------------------------------------------------------------------------
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
  // Asignacion de salidas (identica al original)
  // ---------------------------------------------------------------------------
  assign pwm_o[3:0] = pwm_signals_o;
  assign pwm_o[4]   = 1'b1;
  assign pwm_o[5]   = heartbeat_led;
  assign pwm_o[6]   = 1'b0;
  assign pwm_o[7]   = 1'b0;

  // thousands_counter y d1_tth existen en el original pero no se pintan
  wire _unused_core = &{1'b0,
      thousands_counter, d1_tth, v_calc_temp[15:0],
      freq_tth_unused, fc_tth_unused, out_tth_unused,
      freq_display_hold[15:12], div_quot[31:16], div_quot[3:0],
      fcc_ce_out, fcc_ui, fcc_uv};

endmodule

`default_nettype wire
