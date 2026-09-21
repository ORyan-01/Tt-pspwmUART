/*
 * ---------------------------------------------------------------------------
 * project.v  -  Modulador PS-PWM para un convertidor Flying Capacitor de 3
 *               niveles, en un tile 1x1 de Tiny Tapeout.
 *
 * IHP SG13G2.  Reloj de 27 MHz.
 *
 * Es el modulador del diseno de Nicolas Villegas
 * (github.com/nic0villegasc/LushayLabs-TangNano20K, carpeta 3LFCC), solo, con
 * los dos ciclos de trabajo expuestos directamente a pines.  Lazo abierto: el
 * duty se fija desde afuera.
 *
 * Instancia unicamente ps_pwm.v y sus modulos internos, sin cambios:
 *   ps_pwm.v  signal_generator_0phase.v  signal_generator_180phase.v
 *   comparator.v  dead_time_generator.v
 *
 * ---------------------------------------------------------------------------
 * MAPA DE PINES
 *
 *   ui[6:0]    D1  ciclo de trabajo de la rama 1, 7 bits (0 a 127)
 *   ui[7]      libre
 *
 *   uio[6:0]   D2  ciclo de trabajo de la rama 2, 7 bits (0 a 127), ENTRADAS
 *   uio[7]     libre, entrada
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
 *   1. Reloj de 27 MHz.  Con rst_n en bajo las cuatro puertas quedan en el
 *      estado seguro: los dos PMOS apagados (uo[0]=uo[1]=1) y los dos NMOS
 *      apagados (uo[2]=uo[3]=0).
 *   2. Se fija D1 en ui[6:0] y D2 en uio[6:0].  El valor es el duty en
 *      binario:  0000000 = 0 %,  1000000 = 50 %,  1111111 = 100 %.
 *   3. Para operacion simetrica, D1 = D2.  Para desbalancear las ramas a
 *      mano, valores distintos.
 *
 * Portadora: 254 ciclos de periodo, 106 kHz de conmutacion.
 * Tiempo muerto: 5 ciclos de reloj, 185 ns.  El flanco de apagado pasa
 * inmediato y el de encendido va retrasado, lo que garantiza que el PMOS y el
 * NMOS de una misma rama nunca conduzcan a la vez.
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
  // Modulador PS-PWM  (ps_pwm.v de Nicolas, sin cambios)
  // ---------------------------------------------------------------------------
  wire [3:0] pwm;
  wire       carrier_tick;

  ps_pwm u_modulator (
      .clk_i         (clk),
      .rst_ni        (rst_n),
      .duty_d1_i     (ui_in[6:0]),     // D1 directo desde los pines
      .duty_d2_i     (uio_in[6:0]),    // D2 directo desde los pines
      .adc_trigger_o (carrier_tick),
      .pwm_o         (pwm)
  );

  // ---------------------------------------------------------------------------
  // Salidas
  // ---------------------------------------------------------------------------
  assign uo_out[3:0] = pwm;            // las cuatro puertas
  assign uo_out[4]   = carrier_tick;   // disparo de fin de rampa
  assign uo_out[7:5] = 3'b000;

  // uio completo como entrada: uio[6:0] es D2, uio[7] sobra
  assign uio_out = 8'h00;
  assign uio_oe  = 8'h00;

  wire _unused = &{ena, ui_in[7], uio_in[7], 1'b0};

endmodule

`default_nettype wire
