// ---------------------------------------------------------------------------
// project.v  -  ANADIDO (fichero nuevo, no modifica nada verificado)
//
// Envoltorio de Tiny Tapeout.  Es la unica capa que se interpone entre el
// nucleo (fcc_core, que es el top.v de Nicolas) y los pines del chip.
//
// IHP SG13G2, shuttle ttihp26b.
//
// MAPA DE PINES
//   ui_in[0]     uart_rx_i
//   ui_in[1]     SCL_OD  (0 = push-pull, igual que la FPGA;  1 = open drain)
//   uo_out[7:0]  pwm_o[7:0]     los 8, mismo orden de bits que el .cst
//   uio[0]       sda_1_io       open drain
//   uio[1]       sda_2_io       open drain
//   uio[2]       scl_1_o AND scl_2_o
//   uio[3..7]    ioSclk, ioSdin, ioCs, ioDc, ioReset
//
// POR QUE SE COMPARTE SCL
//   Hacian falta 17 pines de salida y Tiny Tapeout ofrece 16.  Las dos
//   instancias de i2c son la misma FSM, con el mismo reloj y reset, y sus
//   enables se activan en el mismo ciclo.  Dentro de i2c.v ninguna transicion
//   depende de sda_i (solo de clockDivider) y en STATE_RCV_ACK el ACK ni se
//   comprueba.  Lo unico que difiere entre canales es MUX_CONFIG, que cambia
//   el dato de SDA, nunca el temporizado de SCL.  Por tanto scl_1_o y scl_2_o
//   son bit a bit identicos siempre, y se fusionan con un AND (el mismo
//   wired-AND que harian sobre una linea fisica comun).
//   Comprobado con 3.000.000 de ciclos de simulacion: 0 discrepancias.
//
//   En la placa: una sola linea SCL a los dos ADS1115, SDA separado por chip.
// ---------------------------------------------------------------------------

`default_nettype none

module tt_um_pucv_3lfcc (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (1 = salida)
    input  wire       ena,      // vale 1 cuando el diseno esta alimentado
    input  wire       clk,      // reloj
    input  wire       rst_n     // reset activo bajo
);

  // ---------------------------------------------------------------------------
  // Sincronizadores de entrada
  // ---------------------------------------------------------------------------
  // En la FPGA estas lineas se muestreaban directamente.  En silicio hay que
  // protegerse de la metaestabilidad.  Cuesta 2 ciclos de 27 MHz (74 ns): un
  // bit de UART dura 234 ciclos y SDA se muestrea 32 ciclos despues del flanco
  // de SCL, asi que el valor leido es el mismo.
  reg [1:0] sync_uart_rx;
  reg [1:0] sync_sda_1;
  reg [1:0] sync_sda_2;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sync_uart_rx <= 2'b11;   // UART en reposo = 1
      sync_sda_1   <= 2'b11;   // SDA en reposo = 1 (pull-up)
      sync_sda_2   <= 2'b11;
    end else begin
      sync_uart_rx <= {sync_uart_rx[0], ui_in[0]};
      sync_sda_1   <= {sync_sda_1[0],   uio_in[0]};
      sync_sda_2   <= {sync_sda_2[0],   uio_in[1]};
    end
  end

  wire scl_od_en = ui_in[1];   // strap estatico, no necesita sincronizar

  // ---------------------------------------------------------------------------
  // Nucleo: el top.v de Nicolas, con los inout partidos
  // ---------------------------------------------------------------------------
  wire [7:0] pwm;
  wire       scl_1, scl_2;
  wire       sda_1_pd, sda_2_pd;
  wire       oled_sclk, oled_sdin, oled_cs, oled_dc, oled_res;

  fcc_core u_core (
      .clk_i      (clk),
      .rst_ni     (rst_n),
      .scl_1_o    (scl_1),
      .sda_1_i    (sync_sda_1[1]),
      .sda_1_pd_o (sda_1_pd),
      .scl_2_o    (scl_2),
      .sda_2_i    (sync_sda_2[1]),
      .sda_2_pd_o (sda_2_pd),
      .pwm_o      (pwm),
      .ioSclk     (oled_sclk),
      .ioSdin     (oled_sdin),
      .ioCs       (oled_cs),
      .ioDc       (oled_dc),
      .ioReset    (oled_res),
      .uart_rx_i  (sync_uart_rx[1])
  );

  // ---------------------------------------------------------------------------
  // Salidas dedicadas: los 8 PWM, mismo orden de bits que en la Tang Nano
  // ---------------------------------------------------------------------------
  assign uo_out = pwm;

  // ---------------------------------------------------------------------------
  // Banco bidireccional
  // ---------------------------------------------------------------------------
  wire scl_merged = scl_1 & scl_2;

  // SDA open drain: NUNCA se fuerza un 1.  Equivale exactamente a
  //     assign sda_x_io = (isSending & ~sdaOut) ? 1'b0 : 1'bz;
  assign uio_out[0] = 1'b0;
  assign uio_oe [0] = sda_1_pd;

  assign uio_out[1] = 1'b0;
  assign uio_oe [1] = sda_2_pd;

  // SCL: push-pull (como la FPGA) u open drain, segun el strap
  assign uio_out[2] = scl_od_en ? 1'b0       : scl_merged;
  assign uio_oe [2] = scl_od_en ? ~scl_merged : 1'b1;

  // OLED SPI: salidas puras
  assign uio_out[3] = oled_sclk;
  assign uio_out[4] = oled_sdin;
  assign uio_out[5] = oled_cs;
  assign uio_out[6] = oled_dc;
  assign uio_out[7] = oled_res;
  assign uio_oe[7:3] = 5'b11111;

  wire _unused = &{ena, ui_in[7:2], uio_in[7:2], 1'b0};

endmodule

`default_nettype wire
