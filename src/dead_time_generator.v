`default_nettype none

//////////////////////////////////////////////////////////////////////////////////
// Company: POWERLAB, DEPARTAMENTO DE ELECTRONICA, UTFSM
// Engineer: GONZALO CARRASCO REYES
//
// Create Date:    12:24:55 10/09/2007
// Design Name:
// Module Name:    Dead_Time_Geneartr
// Project Name:
// Target Devices:
// Tool versions:
// Description: El modulo recibe una senal digital de 1 bit, y entrega la misma
//                      senal de entrada con un retardo en el canto de subida. Este
//                      retardo llamado tiempo muerto, es configurable con una palabra
//                      de 10 bits, que permite fijar tiempos en pasos de un periodo del
//                      reloj del reloj de 150MHz, que tambien debe recibir.
//
// Dependencies:    Depende de una senal de reloj, la configuracion del tiempo
//                      muerto y de la senal de entrada.
//                          clk - Entrada de 150MHz
//                          dt      - Tiempo muerto
//                          gi      - Senal de entrada
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
// Revision 0.02 - Refactored and parameterized by Nicolás Villegas (AC3E Internship 2025)
//////////////////////////////////////////////////////////////////////////////////

module dead_time_generator #(
  parameter integer DeadTimeWidth = 5
) (
  input wire                     clk_i,            // Reloj principal
  input wire                     rst_ni,           // Reset asincrono activo bajo
  input wire [DeadTimeWidth-1:0] dt_i,             // Configuración de tiempos muertos
  input wire                     signal_i,         // Señal a retardar (gi)
  output reg                      signal_delayed_o  // Señal retardada (go)
);

  // Variables internas
  reg [DeadTimeWidth-1:0] counter_q;
  wire                    dead_time_finished;

  // Comparación asincrónica del contador
  assign dead_time_finished = (counter_q >= dt_i);

  // Lógica secuencial combinada
  // Nota: signal_i actúa como un reset síncrono funcional.
  // Si la entrada cae a 0, el retardo se reinicia y la salida cae inmediatamente.
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // Estado de arranque de la FPGA (registros a 0)
      counter_q        <= {DeadTimeWidth{1'b0}};
      signal_delayed_o <= 1'b0;
    end else if (signal_i == 1'b0) begin
      counter_q        <= {DeadTimeWidth{1'b0}};
      signal_delayed_o <= 1'b0;
    end else begin
      // Gestión del contador
      if (!dead_time_finished) begin
        counter_q <= counter_q + 1'b1;
      end

      // Gestión de la salida
      if (dead_time_finished) begin
        signal_delayed_o <= 1'b1;
      end else begin
        signal_delayed_o <= 1'b0;
      end
    end
  end

endmodule

`default_nettype wire
