/*
 * ---------------------------------------------------------------------------
 * project.v  -  Modulador PS-PWM para un convertidor Flying Capacitor de 3
 *               niveles, en un tile 1x1 de Tiny Tapeout.
 *
 * IHP SG13G2.  Reloj de 27 MHz.
 *
 * Es el subconjunto del diseno de Nicolas Villegas
 * (github.com/nic0villegasc/LushayLabs-TangNano20K, carpeta 3LFCC) que entra
 * en un tile: el modulador completo con tiempo muerto, mas el receptor UART
 * para fijar el ciclo de trabajo.  Queda en lazo abierto: el lazo PI
 * (fcc_fixpt) tiene unos 500 biestables el solo y no cabe.
 *
 * Los cinco modulos que se instancian por debajo son los originales de
 * Nicolas, sin ningun cambio salvo el reset que ya se les habia anadido:
 *   ps_pwm.v  signal_generator_0phase.v  signal_generator_180phase.v
 *   comparator.v  dead_time_generator.v  uart.v
 *
 * ---------------------------------------------------------------------------
 * MAPA DE PINES
 *
 *   ui[0]      UART RX, 115200 8N1
 *   ui[2:1]    de donde sale el ciclo de trabajo:
 *                00  D1 = D2 = UART            <- normal, simetrico
 *                01  D1 = D2 = uio[6:0]        <- paralelo (respaldo del UART)
 *                10  D1 = UART,  D2 = uio[6:0] <- desbalance manual
 *                11  D1 = uio[6:0], D2 = UART
 *   ui[7:3]    libres
 *
 *   uo[0]      PWM0  puerta PMOS1, activa a BAJO
 *   uo[1]      PWM1  puerta PMOS2, activa a BAJO
 *   uo[2]      PWM2  puerta NMOS1, activa a ALTO
 *   uo[3]      PWM3  puerta NMOS2, activa a ALTO
 *   uo[4]      disparo de fin de rampa (los dos extremos de la portadora)
 *   uo[5]      heartbeat, 0,5 Hz.  Si parpadea, el chip esta vivo
 *   uo[6:7]    a 0
 *
 *   uio[6:0]   ciclo de trabajo paralelo, 7 bits, ENTRADAS
 *   uio[7]     libre, entrada
 *
 * ---------------------------------------------------------------------------
 * COMO USARLO
 *
 *   1. Reloj de 27 MHz y reset.  Con rst_n en bajo las cuatro puertas quedan
 *      en el estado seguro, los dos PMOS apagados (uo[0]=uo[1]=1) y los dos
 *      NMOS apagados (uo[2]=uo[3]=0).
 *   2. ui[2:1] = 00 y se manda por UART:
 *        '0' a '9'  consignas fijas ('0' = 0 %,  '9' = 59 %)
 *        'u' / 'd'  sube o baja unos 2 puntos por pulsacion
 *   3. Si el UART no responde, ui[2:1] = 01 y el duty entra por uio[6:0].
 *      Es el camino de respaldo, no depende de temporizados.
 *   4. Para probar el balance del condensador flotante, ui[2:1] = 10 y se
 *      desbalancean D1 y D2 a mano.
 *
 * El tiempo muerto son 5 ciclos de reloj, 185 ns a 27 MHz.  El flanco de
 * apagado pasa inmediato y el de encendido va retrasado, que es lo que
 * garantiza que el PMOS y el NMOS de una misma rama nunca conduzcan a la vez.
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
  // Sincronizadores de entrada
  // ---------------------------------------------------------------------------
  // El UART y los interruptores del duty paralelo son asincronos respecto al
  // reloj del chip.  Dos biestables antes de usarlos evitan la metaestabilidad.
  reg [1:0] sync_rx;
  reg [6:0] sync_par_0, sync_par_1;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sync_rx    <= 2'b11;      // linea UART en reposo = 1
      sync_par_0 <= 7'd0;
      sync_par_1 <= 7'd0;
    end else begin
      sync_rx    <= {sync_rx[0], ui_in[0]};
      sync_par_0 <= uio_in[6:0];
      sync_par_1 <= sync_par_0;
    end
  end

  wire       uart_rx  = sync_rx[1];
  wire [6:0] duty_par = sync_par_1;

  // ---------------------------------------------------------------------------
  // Receptor UART  (uart.v de Nicolas, sin cambios)
  // ---------------------------------------------------------------------------
  wire [15:0] uart_value;

  uart u_uart (
      .clk_i     (clk),
      .rst_ni    (rst_n),
      .rx_i      (uart_rx),
      .counter_o (uart_value)
  );

  // El UART entrega 16 bits, el modulador quiere 7.  Se toman los altos, que
  // es lo mismo que dividir por 512:  '9' -> 38825 >> 9 = 75 de 127 (59 %),
  // y cada pulsacion de 'u' o 'd' mueve unos 3 pasos.
  wire [6:0] duty_uart = uart_value[15:9];

  // ---------------------------------------------------------------------------
  // Seleccion de la fuente del ciclo de trabajo
  // ---------------------------------------------------------------------------
  wire [1:0] modo = ui_in[2:1];

  reg [6:0] duty_d1_next, duty_d2_next;

  always @* begin
    case (modo)
      2'b00: begin duty_d1_next = duty_uart; duty_d2_next = duty_uart; end
      2'b01: begin duty_d1_next = duty_par;  duty_d2_next = duty_par;  end
      2'b10: begin duty_d1_next = duty_uart; duty_d2_next = duty_par;  end
      2'b11: begin duty_d1_next = duty_par;  duty_d2_next = duty_uart; end
    endcase
  end

  // ---------------------------------------------------------------------------
  // Los dos duty se actualizan a la vez, en un extremo de la portadora
  // ---------------------------------------------------------------------------
  // Si cambiaran en mitad de una rampa, un flanco podria salir recortado.
  // Cargandolos en el disparo de fin de rampa, cada periodo sale entero.
  wire       carrier_tick;
  reg  [6:0] duty_d1, duty_d2;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      duty_d1 <= 7'd0;          // arranca sin conmutar
      duty_d2 <= 7'd0;
    end else if (carrier_tick) begin
      duty_d1 <= duty_d1_next;
      duty_d2 <= duty_d2_next;
    end
  end

  // ---------------------------------------------------------------------------
  // Modulador PS-PWM  (ps_pwm.v de Nicolas, sin cambios)
  // ---------------------------------------------------------------------------
  wire [3:0] pwm;

  ps_pwm u_modulator (
      .clk_i         (clk),
      .rst_ni        (rst_n),
      .duty_d1_i     (duty_d1),
      .duty_d2_i     (duty_d2),
      .adc_trigger_o (carrier_tick),
      .pwm_o         (pwm)
  );

  // ---------------------------------------------------------------------------
  // Heartbeat: un parpadeo de 0,5 Hz para ver de un vistazo que el chip corre
  // ---------------------------------------------------------------------------
  reg [24:0] hb_counter;
  reg        heartbeat;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hb_counter <= 25'd0;
      heartbeat  <= 1'b1;
    end else if (hb_counter == 25'd27000000) begin
      hb_counter <= 25'd0;
      heartbeat  <= ~heartbeat;
    end else begin
      hb_counter <= hb_counter + 25'd1;
    end
  end

  // ---------------------------------------------------------------------------
  // Salidas
  // ---------------------------------------------------------------------------
  assign uo_out[3:0] = pwm;            // las cuatro puertas
  assign uo_out[4]   = carrier_tick;   // disparo de fin de rampa
  assign uo_out[5]   = heartbeat;
  assign uo_out[6]   = 1'b0;
  assign uo_out[7]   = 1'b0;

  // uio completo como entrada: uio[6:0] es el duty paralelo, uio[7] sobra
  assign uio_out = 8'h00;
  assign uio_oe  = 8'h00;

  wire _unused = &{ena, ui_in[7:3], uio_in[7], 1'b0};

endmodule

`default_nettype wire
