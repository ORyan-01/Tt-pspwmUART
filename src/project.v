/*
 * ---------------------------------------------------------------------------
 * Tiny Tapeout - IHP SG13G2  (shuttle ttihp26b, cierre 21-sep)
 *
 * Controlador digital 3LFCC (Three Level Flying Capacitor Converter)
 * Port del proyecto FPGA de Nicolas Villegas:
 *     github.com/nic0villegasc/LushayLabs-TangNano20K  (carpeta 3LFCC)
 *
 * SPDX-License-Identifier: Apache-2.0
 * ---------------------------------------------------------------------------
 *
 * MAPA DE PINES
 * -------------
 *   ui_in[0]   UART_RX          (entrada, era uart_rx_i)
 *   ui_in[1]   SCL_OD           strap estatico:
 *                                 0 = SCL push-pull  (identico a la FPGA)  <-- por defecto
 *                                 1 = SCL open-drain (I2C estricto, necesita pull-up)
 *   ui_in[7:2] sin uso
 *
 *   uo_out[7:0]  pwm_o[7:0]     los 8 pines PWM, mismo orden que el .cst original
 *
 *   uio[0]     SDA1   bidireccional open-drain  (era sda_1_io)
 *   uio[1]     SDA2   bidireccional open-drain  (era sda_2_io)
 *   uio[2]     SCL    reloj I2C COMPARTIDO por los dos buses (era scl_1_o + scl_2_o)
 *   uio[3]     OLED_SCLK        (era ioSclk)
 *   uio[4]     OLED_SDIN        (era ioSdin)
 *   uio[5]     OLED_CS          (era ioCs)
 *   uio[6]     OLED_DC          (era ioDc)
 *   uio[7]     OLED_RES         (era ioReset)
 *
 * POR QUE SE PUEDE COMPARTIR SCL (y por que no se pierde nada)
 * -----------------------------------------------------------
 * Los dos maestros I2C (instancias c y c2 de i2c.v) son maquinas de estado
 * IDENTICAS, con el mismo clk, el mismo rst_ni, y sus enables (adc1_enable_i /
 * adc2_enable_i) se ponen a 1 en el MISMO ciclo dentro de fcc_core.  Dentro de
 * i2c.v ninguna transicion de estado depende de sda_i: el avance lo gobierna
 * solo clockDivider.  Y dentro de adc.v la espera depende solo de
 * i2c_complete_i.  Lo unico que difiere entre los dos canales es MUX_CONFIG,
 * que cambia el DATO enviado por SDA, nunca el temporizado de SCL.
 *
 * Conclusion: scl_1_o y scl_2_o son bit a bit identicos en todo instante.
 * Se fusionan con un AND (que es exactamente el wired-AND que harian sobre una
 * misma linea fisica), liberando el pin que faltaba.  En la placa: una sola
 * linea SCL a los dos ADS1115, y SDA separado para cada uno -- que es la razon
 * original de tener dos buses (ambos ADS1115 comparten direccion 0x49).
 * ---------------------------------------------------------------------------
 */

`default_nettype none

module tt_um_pucv_3lfcc (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // ---------------------------------------------------------------------------
  // Sincronizadores de entrada (obligatorio en ASIC, no cambia la funcion)
  // ---------------------------------------------------------------------------
  // En la FPGA estas lineas se muestreaban directamente.  En silicio hay que
  // protegerse de la metaestabilidad.  El retardo es de 2 ciclos de 27 MHz
  // (74 ns): el bit UART dura 234 ciclos y el muestreo de SDA ocurre 32 ciclos
  // despues del flanco de subida de SCL, asi que el valor leido es el mismo.
  reg [1:0] sync_uart_rx;
  reg [1:0] sync_sda_1;
  reg [1:0] sync_sda_2;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sync_uart_rx <= 2'b11;   // linea UART en reposo = 1
      sync_sda_1   <= 2'b11;   // SDA en reposo = 1 (pull-up)
      sync_sda_2   <= 2'b11;
    end else begin
      sync_uart_rx <= {sync_uart_rx[0], ui_in[0]};
      sync_sda_1   <= {sync_sda_1[0],   uio_in[0]};
      sync_sda_2   <= {sync_sda_2[0],   uio_in[1]};
    end
  end

  wire uart_rx = sync_uart_rx[1];
  wire sda_1_i = sync_sda_1[1];
  wire sda_2_i = sync_sda_2[1];

  // Strap estatico, no necesita sincronizar
  wire scl_od_en = ui_in[1];

  // ---------------------------------------------------------------------------
  // Nucleo (el top.v original, sin inouts)
  // ---------------------------------------------------------------------------
  wire [7:0] pwm;
  wire       scl_1, scl_2;
  wire       sda_1_pd, sda_2_pd;      // 1 => tirar la linea a 0
  wire       oled_sclk, oled_sdin, oled_cs, oled_dc, oled_res;

  fcc_core u_core (
      .clk_i       (clk),
      .rst_ni      (rst_n),
      .scl_1_o     (scl_1),
      .sda_1_i     (sda_1_i),
      .sda_1_pd_o  (sda_1_pd),
      .scl_2_o     (scl_2),
      .sda_2_i     (sda_2_i),
      .sda_2_pd_o  (sda_2_pd),
      .pwm_o       (pwm),
      .oled_sclk_o (oled_sclk),
      .oled_sdin_o (oled_sdin),
      .oled_cs_o   (oled_cs),
      .oled_dc_o   (oled_dc),
      .oled_res_o  (oled_res),
      .uart_rx_i   (uart_rx)
  );

  // ---------------------------------------------------------------------------
  // Salidas dedicadas: los 8 PWM, mismo orden de bits que en la Tang Nano
  // ---------------------------------------------------------------------------
  assign uo_out = pwm;

  // ---------------------------------------------------------------------------
  // SCL compartido (wired-AND de los dos maestros; ver cabecera)
  // ---------------------------------------------------------------------------
  wire scl_merged = scl_1 & scl_2;

  // ---------------------------------------------------------------------------
  // Banco bidireccional
  // ---------------------------------------------------------------------------
  // SDA open-drain: NUNCA se fuerza un 1.  Equivale exactamente a
  //     assign sda_x_io = (isSending & ~sdaOut) ? 1'b0 : 1'bz;
  assign uio_out[0] = 1'b0;
  assign uio_oe [0] = sda_1_pd;

  assign uio_out[1] = 1'b0;
  assign uio_oe [1] = sda_2_pd;

  // SCL: push-pull (como la FPGA) o open-drain segun el strap
  assign uio_out[2] = scl_od_en ? 1'b0      : scl_merged;
  assign uio_oe [2] = scl_od_en ? ~scl_merged : 1'b1;

  // OLED SPI: salidas puras
  assign uio_out[3] = oled_sclk;
  assign uio_out[4] = oled_sdin;
  assign uio_out[5] = oled_cs;
  assign uio_out[6] = oled_dc;
  assign uio_out[7] = oled_res;
  assign uio_oe[7:3] = 5'b11111;

  // Entradas no usadas (evita warnings del linter)
  wire _unused = &{ena, ui_in[7:2], uio_in[7:2], 1'b0};

endmodule

`default_nettype wire
