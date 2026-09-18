// MODIFICADO: se elimina aqui la directiva de estrictez de compilacion.
// No afecta a ninguna logica, y se filtraba a los ficheros compilados
// despues (screen.v, toDec.v, fcc_fixpt.v), que no la declaran.

module i2c (
    input clk_i,
    input rst_ni,

    input sda_i,
    output reg sda_o = 1,
    output reg is_sending_o = 0,

    output reg scl_o = 1,

    input [1:0] instruction_i, // 00 = start, 01 = stop, 10 = read + ACK, 11 = write + ACK

    input enable_i,

    input [7:0] byte_to_send_i,
    output reg [7:0] byte_received_o = 0,

    output reg complete_o
);

    localparam INST_START_TX = 0;
    localparam INST_STOP_TX = 1;
    localparam INST_READ_BYTE = 2;
    localparam INST_WRITE_BYTE = 3;
    localparam STATE_IDLE = 4;
    localparam STATE_DONE = 5;
    localparam STATE_SEND_ACK = 6;
    localparam STATE_RCV_ACK = 7;

    reg [6:0] clockDivider = 0;

    reg [2:0] state = STATE_IDLE;
    reg [2:0] bitToSend = 0;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state <= STATE_IDLE;
            scl_o <= 1;
            sda_o <= 1;
            is_sending_o <= 0;
            complete_o <= 0;
            clockDivider <= 0;
            bitToSend <= 0;
            byte_received_o <= 0;
        end else begin
          case (state)
              STATE_IDLE: begin
                  if (enable_i) begin
                      complete_o <= 0;
                      clockDivider <= 0;
                      bitToSend <= 0;
                      state <= {1'b0,instruction_i};
                  end
              end
              INST_START_TX: begin
                  is_sending_o <= 1;
                  clockDivider <= clockDivider + 1;
                  if (clockDivider[6:5] == 2'b00) begin
                      scl_o <= 1;
                      sda_o <= 1;
                  end else if (clockDivider[6:5] == 2'b01) begin
                      sda_o <= 0;
                  end else if (clockDivider[6:5] == 2'b10) begin
                      scl_o <= 0;
                  end else if (clockDivider[6:5] == 2'b11) begin
                      state <= STATE_DONE;
                  end
              end
              INST_STOP_TX: begin
                  is_sending_o <= 1;
                  clockDivider <= clockDivider + 1;
                  if (clockDivider[6:5] == 2'b00) begin // Clock low period
                      scl_o <= 0;
                      sda_o <= 0;
                  end else if (clockDivider[6:5] == 2'b01) begin // Clock rising edge
                      scl_o <= 1;
                  end else if (clockDivider[6:5] == 2'b10) begin // Clock high period
                      sda_o <= 1;
                  end else if (clockDivider[6:5] == 2'b11) begin // Clock falling edge
                      state <= STATE_DONE;
                  end
              end
              INST_READ_BYTE: begin
                  is_sending_o <= 0;
                  clockDivider <= clockDivider + 1;
                  if (clockDivider[6:5] == 2'b00) begin // Clock low period
                      scl_o <= 0;

                  end else if (clockDivider[6:5] == 2'b01) begin // Clock rising edge
                      scl_o <= 1;

                  end else if (clockDivider == 7'b1000000) begin // Mid clock high period
                      byte_received_o <= {byte_received_o[6:0], sda_i ? 1'b1 : 1'b0};

                  end else if (clockDivider == 7'b1111111) begin // Mid clock low period
                      bitToSend <= bitToSend + 1;
                      if (bitToSend == 3'b111) begin
                          state <= STATE_SEND_ACK;
                      end

                  end else if (clockDivider[6:5] == 2'b11) begin // Clock falling edge
                      scl_o <= 0;
                  end
              end
              STATE_SEND_ACK: begin
                  is_sending_o <= 1;
                  sda_o <= 0;
                  clockDivider <= clockDivider + 1;
                  if (clockDivider[6:5] == 2'b01) begin
                      scl_o <= 1;
                  end else if (clockDivider == 7'b1111111) begin
                      state <= STATE_DONE;
                  end else if (clockDivider[6:5] == 2'b11) begin
                      scl_o <= 0;
                  end
              end
              INST_WRITE_BYTE: begin
                  is_sending_o <= 1;
                  clockDivider <= clockDivider + 1;
                  sda_o <= byte_to_send_i[3'd7-bitToSend] ? 1'b1 : 1'b0;

                  if (clockDivider[6:5] == 2'b00) begin
                      scl_o <= 0;
                  end else if (clockDivider[6:5] == 2'b01) begin
                      scl_o <= 1;
                  end else if (clockDivider == 7'b1111111) begin
                      bitToSend <= bitToSend + 1;
                      if (bitToSend == 3'b111) begin
                          state <= STATE_RCV_ACK;
                      end
                  end else if (clockDivider[6:5] == 2'b11) begin
                      scl_o <= 0;
                  end
              end
              STATE_RCV_ACK: begin
                  is_sending_o <= 0;
                  clockDivider <= clockDivider + 1;

                  if (clockDivider[6:5] == 2'b01) begin
                      scl_o <= 1;
                  end else if (clockDivider == 7'b1111111) begin
                      state <= STATE_DONE;
                  end else if (clockDivider[6:5] == 2'b11) begin
                      scl_o <= 0;
                  end
                  // else if (clockDivider == 7'b1000000) begin
                  //     sda_i should be 0
                  // end
              end
              STATE_DONE: begin
                  complete_o <= 1;
                  if (~enable_i)
                      state <= STATE_IDLE;
              end
          endcase
        end
    end

endmodule
