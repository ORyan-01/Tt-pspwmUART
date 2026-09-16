// ---------------------------------------------------------------------------
// screen.v  -  driver SPI del OLED SSD1306
//
// Cambios respecto al original (ninguno altera la funcion):
//
//  1) Se anade rst_ni.  En FPGA los registros arrancan con el valor del
//     bitstream (`reg x = 0`), en ASIC arrancan en un valor DESCONOCIDO.
//     Sin reset, la FSM puede despertar en un estado invalido y el OLED no
//     se inicializa nunca.  Los valores de reset son EXACTAMENTE los mismos
//     valores iniciales del codigo original.
//
//  2) startupCommands (184 bits) pasa de ser un `reg` con part-select
//     variable a un case constante: garantiza que sintetice como ROM y no
//     como 184 biestables, y elimina el part-select fuera de rango cuando
//     commandIndex vale 0.  La secuencia de 23 comandos es identica.
// ---------------------------------------------------------------------------

`default_nettype none

module screen #(
    parameter STARTUP_WAIT = 32'd10000000
) (
    input  wire       clk_i,
    input  wire       rst_ni,
    output wire       sclk_o,
    output wire       sdin_o,
    output wire       cs_o,
    output wire       dc_o,
    output wire       reset_o,
    output wire [9:0] pixel_address_o,
    input  wire [7:0] pixel_data_i
);
  localparam STATE_INIT_POWER          = 3'd0;
  localparam STATE_LOAD_INIT_CMD       = 3'd1;
  localparam STATE_SEND                = 3'd2;
  localparam STATE_CHECK_FINISHED_INIT = 3'd3;
  localparam STATE_LOAD_DATA           = 3'd4;

  localparam SETUP_INSTRUCTIONS = 23;

  // Mismos valores (10M, 20M, 30M), pero ya a 33 bits para comparar con
  // counter sin extension implicita.
  localparam [32:0] WAIT_1X = {1'b0, STARTUP_WAIT};
  localparam [32:0] WAIT_2X = WAIT_1X + WAIT_1X;
  localparam [32:0] WAIT_3X = WAIT_2X + WAIT_1X;

  reg [32:0] counter;
  reg [2:0]  state;

  reg dc;
  reg sclk;
  reg sdin;
  reg reset;
  reg cs;

  assign sclk_o  = sclk;
  assign sdin_o  = sdin;
  assign dc_o    = dc;
  assign reset_o = reset;
  assign cs_o    = cs;

  reg [7:0] dataToSend;
  reg [3:0] bitNumber;
  reg [9:0] pixelCounter;

  assign pixel_address_o = pixelCounter;

  reg [7:0] commandIndex;

  // ---------------------------------------------------------------------------
  // Tabla de inicializacion (misma secuencia y mismo orden que el original)
  // commandIndex vale 184, 176, ... 8.  cmd_sel = commandIndex/8 - 1 = 22 .. 0
  // ---------------------------------------------------------------------------
  wire [4:0] cmd_sel = commandIndex[7:3] - 5'd1;
  reg  [7:0] next_cmd;

  always @* begin
    case (cmd_sel)
      5'd22: next_cmd = 8'hAE;  // display off
      5'd21: next_cmd = 8'h81;  // contrast
      5'd20: next_cmd = 8'h7F;
      5'd19: next_cmd = 8'hA6;  // normal (no inverted)
      5'd18: next_cmd = 8'h20;  // horizontal addressing mode
      5'd17: next_cmd = 8'h00;
      5'd16: next_cmd = 8'hC8;  // normal scan direction
      5'd15: next_cmd = 8'h40;  // start line
      5'd14: next_cmd = 8'hA1;  // segment remap
      5'd13: next_cmd = 8'hA8;  // mux ratio
      5'd12: next_cmd = 8'h3F;  // 63
      5'd11: next_cmd = 8'hD3;  // display offset
      5'd10: next_cmd = 8'h00;
      5'd9:  next_cmd = 8'hD5;  // clock divide ratio
      5'd8:  next_cmd = 8'h80;
      5'd7:  next_cmd = 8'hD9;  // precharge
      5'd6:  next_cmd = 8'h22;
      5'd5:  next_cmd = 8'hDB;  // vcom deselect
      5'd4:  next_cmd = 8'h20;
      5'd3:  next_cmd = 8'h8D;  // charge pump
      5'd2:  next_cmd = 8'h14;
      5'd1:  next_cmd = 8'hA4;  // resume RAM content
      5'd0:  next_cmd = 8'hAF;  // display on
      default: next_cmd = 8'h00;
    endcase
  end

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // Mismos valores que los inicializadores del codigo original
      counter      <= 33'd0;
      state        <= STATE_INIT_POWER;
      dc           <= 1'b1;
      sclk         <= 1'b1;
      sdin         <= 1'b0;
      reset        <= 1'b1;
      cs           <= 1'b0;
      dataToSend   <= 8'd0;
      bitNumber    <= 4'd0;
      pixelCounter <= 10'd0;
      commandIndex <= SETUP_INSTRUCTIONS * 8;   // 184
    end else begin
      case (state)
        STATE_INIT_POWER: begin
          counter <= counter + 1;
          if (counter < WAIT_1X)
            reset <= 1;
          else if (counter < WAIT_2X)
            reset <= 0;
          else if (counter < WAIT_3X)
            reset <= 1;
          else begin
            state   <= STATE_LOAD_INIT_CMD;
            counter <= 33'b0;
          end
        end
        STATE_LOAD_INIT_CMD: begin
          dc           <= 0;
          dataToSend   <= next_cmd;
          state        <= STATE_SEND;
          bitNumber    <= 4'd7;
          cs           <= 0;
          commandIndex <= commandIndex - 8'd8;
        end
        STATE_SEND: begin
          if (counter == 33'd0) begin
            sclk    <= 0;
            sdin    <= dataToSend[bitNumber[2:0]];  // bitNumber solo vale 0..7
            counter <= 33'd1;
          end
          else begin
            counter <= 33'd0;
            sclk    <= 1;
            if (bitNumber == 0)
              state <= STATE_CHECK_FINISHED_INIT;
            else
              bitNumber <= bitNumber - 1;
          end
        end
        STATE_CHECK_FINISHED_INIT: begin
          cs <= 1;
          if (commandIndex == 0)
            state <= STATE_LOAD_DATA;
          else
            state <= STATE_LOAD_INIT_CMD;
        end
        STATE_LOAD_DATA: begin
          pixelCounter <= pixelCounter + 1;
          cs           <= 0;
          dc           <= 1;
          bitNumber    <= 4'd7;
          state        <= STATE_SEND;
          dataToSend   <= pixel_data_i;
        end
        default: state <= STATE_INIT_POWER;
      endcase
    end
  end

endmodule

`default_nettype wire
