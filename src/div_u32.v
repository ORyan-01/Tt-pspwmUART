// ---------------------------------------------------------------------------
// div_u32.v  -  division entera sin signo 32 / 16, secuencial (restoring)
//
// Sustituye a los dos  '/'  combinacionales del top original:
//     avg_fc_disp  <= (sum_fc  / sample_count) >> 4;
//     avg_out_disp <= (sum_out / sample_count) >> 4;
//
// El resultado es EXACTAMENTE el mismo numero (division entera truncada);
// lo unico que cambia es que tarda 33 ciclos en vez de ser combinacional.
// Se usa una sola instancia para las dos divisiones (66 ciclos = 2.4 us a
// 27 MHz), frente al segundo completo que hay entre refrescos.
//
// Motivo: en ASIC, un '/' de 32/16 bits genera un divisor combinacional de
// varios miles de celdas y un camino critico de cientos de niveles logicos:
// no cierra temporizado a ninguna frecuencia util.
// ---------------------------------------------------------------------------

`default_nettype none

module div_u32 (
    input  wire        clk_i,
    input  wire        rst_ni,
    input  wire        start_i,   // pulso de 1 ciclo
    input  wire [31:0] num_i,     // dividendo
    input  wire [15:0] den_i,     // divisor (nunca 0: el llamante lo garantiza)
    output reg  [31:0] quot_o,    // cociente, valido cuando done_o = 1
    output reg         done_o     // pulso de 1 ciclo
);

  reg [31:0] num_q;    // dividendo desplazandose
  reg [31:0] quot_q;   // cociente parcial
  reg [15:0] rem_q;    // resto parcial  (siempre < den_q)
  reg [15:0] den_q;    // divisor capturado
  reg [5:0]  cnt_q;
  reg        busy_q;

  // Un paso de division restoring
  wire [16:0] rem_shift = {rem_q, num_q[31]};
  wire [16:0] den_ext   = {1'b0, den_q};
  wire        ge        = (rem_shift >= den_ext);
  wire [16:0] rem_sub   = rem_shift - den_ext;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      num_q  <= 32'd0;
      quot_q <= 32'd0;
      rem_q  <= 16'd0;
      den_q  <= 16'd0;
      cnt_q  <= 6'd0;
      busy_q <= 1'b0;
      quot_o <= 32'd0;
      done_o <= 1'b0;
    end else begin
      done_o <= 1'b0;

      if (start_i && !busy_q) begin
        num_q  <= num_i;
        den_q  <= den_i;
        quot_q <= 32'd0;
        rem_q  <= 16'd0;
        cnt_q  <= 6'd0;
        busy_q <= 1'b1;
      end
      else if (busy_q) begin
        num_q  <= {num_q[30:0], 1'b0};
        quot_q <= {quot_q[30:0], ge};
        rem_q  <= ge ? rem_sub[15:0] : rem_shift[15:0];
        cnt_q  <= cnt_q + 6'd1;

        if (cnt_q == 6'd31) begin
          busy_q <= 1'b0;
          done_o <= 1'b1;
          quot_o <= {quot_q[30:0], ge};
        end
      end
    end
  end

  // quot_q[31] se desplaza fuera al formar quot_o, y rem_sub[16] es el acarreo
  // de la resta, que nunca se guarda.  Solo para el linter.
  wire _unused_div = &{quot_q[31], rem_sub[16], 1'b0};

endmodule

`default_nettype wire
