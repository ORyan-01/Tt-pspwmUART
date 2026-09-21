/*
 * ---------------------------------------------------------------------------
 * project.v  -  Modulador PS-PWM para un convertidor Flying Capacitor de 3
 *               niveles, en un tile 1x1 de Tiny Tapeout.
 *
 * IHP SG13G2.  Reloj de 27 MHz.
 *
 * Es el modulador del diseno de Nicolas Villegas
 * (github.com/nic0villegasc/LushayLabs-TangNano20K, carpeta 3LFCC), con los
 * dos ciclos de trabajo expuestos a pines, y el receptor UART de Nicolas como
 * segunda forma de fijarlos.  Lazo abierto: el duty se fija desde afuera.
 *
 * Modulos de Nicolas que se instancian, sin cambios de logica:
 *   ps_pwm.v  signal_generator_0phase.v  signal_generator_180phase.v
 *   comparator.v  dead_time_generator.v  uart.v
 *
 * ---------------------------------------------------------------------------
 * MAPA DE PINES
 *
 *   ui[6:0]    D1  ciclo de trabajo de la rama 1, 7 bits (0 a 127)
 *   ui[7]      UART RX, 115200 8N1
 *
 *   uio[6:0]   D2  ciclo de trabajo de la rama 2, 7 bits (0 a 127), ENTRADAS
 *   uio[7]     fuente del duty:  0 = pines (D1 y D2 por separado)
 *                                1 = UART  (D1 = D2 = valor recibido)
 *
 *   uo[0]      PWM0  puerta PMOS1, activa a BAJO
 *   uo[1]      PWM1  puerta PMOS2, activa a BAJO
 *   uo[2]      PWM2  puerta NMOS1, activa a ALTO
 *   uo[3]      PWM3  puerta NMOS2, activa a ALTO
 *   uo[4]      disparo de fin de rampa (los dos extremos de la portadora)
 *   uo[7:5]    a 0
 *
 * ---------------------------------------------------------------------------
 * COMO USARLO
 *
 *   Modo pines (uio[7] = 0) -- el funcionamiento de siempre
 *     D1 en ui[6:0] y D2 en uio[6:0], en binario:
 *     0000000 = 0 %,  1000000 = 50 %,  1111111 = 100 %.
 *     En este modo el UART no interviene: el chip se comporta exactamente
 *     igual que sin el.
 *
 *   Modo UART (uio[7] = 1)
 *     ui[7] es uno de los dos pines que alcanza el puente USB-serie de la
 *     placa de demostracion de Tiny Tapeout.  Se enchufa la placa al PC, se
 *     abre un terminal a 115200 8N1 y se teclea:
 *       '0' a '9'  consignas fijas ('0' = 0 %,  '9' = 59 %)
 *       'u' / 'd'  sube o baja unos 2 puntos
 *     El mismo valor va a las dos ramas (operacion simetrica).
 *
 *   Nota: ese puente usa uo[0] como TX del chip, y por uo[0] sale el PMOS1.
 *   El terminal mostrara caracteres sin sentido mientras conmuta el PWM.  Es
 *   inofensivo: el UART de este chip solo recibe.
 *
 * Portadora: 254 ciclos de periodo, 106 kHz de conmutacion.
 * Tiempo muerto: 5 ciclos de reloj, 185 ns.
 * ---------------------------------------------------------------------------
 */

`default_nettype none

module tt_um_pucv_pspwm (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (1 = salida)
    input  wire       ena,      // vale 1 cuando el diseno esta alimentado
    input  wire       clk,      // reloj de 27 MHz
    input  wire       rst_n     // reset activo bajo
);

  // ---------------------------------------------------------------------------
  // Sincronizador de la linea UART
  // ---------------------------------------------------------------------------
  // La linea serie es asincrona y alimenta la maquina de estados del receptor.
  // Dos biestables evitan la metaestabilidad.  Cuesta 2 ciclos (74 ns) sobre
  // un bit de 234: el muestreo sigue cayendo en el centro del bit.
  // No toca el camino del duty, asi que el modo pines no cambia en nada.
  reg [1:0] sync_rx;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) sync_rx <= 2'b11;          // linea UART en reposo = 1
    else        sync_rx <= {sync_rx[0], ui_in[7]};
  end

  // ---------------------------------------------------------------------------
  // Receptor UART  (uart.v de Nicolas)
  // ---------------------------------------------------------------------------
  wire [15:0] uart_value;

  uart u_uart (
      .clk_i     (clk),
      .rst_ni    (rst_n),
      .rx_i      (sync_rx[1]),
      .counter_o (uart_value)
  );

  // 16 bits -> 7: los altos, que es dividir por 512.
  // '9' -> 38825 >> 9 = 75 de 127 (59 %).  Cada 'u' o 'd' mueve 3 pasos.
  wire [6:0] duty_uart = uart_value[15:9];

  // ---------------------------------------------------------------------------
  // Fuente del duty
  // ---------------------------------------------------------------------------
  // Selector combinacional: sin registros ni retardo.  Con uio[7] = 0 los
  // pines llegan al modulador exactamente igual que antes de agregar el UART.
  wire       modo_uart = uio_in[7];
  wire [6:0] duty_d1   = modo_uart ? duty_uart : ui_in[6:0];
  wire [6:0] duty_d2   = modo_uart ? duty_uart : uio_in[6:0];

  // ---------------------------------------------------------------------------
  // Modulador PS-PWM  (ps_pwm.v de Nicolas)
  // ---------------------------------------------------------------------------
  wire [3:0] pwm;
  wire       carrier_tick;

  ps_pwm u_modulator (
      .clk_i         (clk),
      .rst_ni        (rst_n),
      .duty_d1_i     (duty_d1),
      .duty_d2_i     (duty_d2),
      .adc_trigger_o (carrier_tick),
      .pwm_o         (pwm)
  );

  // ---------------------------------------------------------------------------
  // Salidas
  // ---------------------------------------------------------------------------
  assign uo_out[3:0] = pwm;            // las cuatro puertas
  assign uo_out[4]   = carrier_tick;   // disparo de fin de rampa
  assign uo_out[7:5] = 3'b000;

  // uio completo como entrada: uio[6:0] es D2 y uio[7] el selector de modo
  assign uio_out = 8'h00;
  assign uio_oe  = 8'h00;

  wire _unused = &{ena, uart_value[8:0], 1'b0};

endmodule

`default_nettype wire
