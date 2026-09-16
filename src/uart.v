// ---------------------------------------------------------------------------
// uart.v  -  receptor UART 115200 8N1 (antes 3LFCC/src/uart.v)
//
// Unico cambio: se anade rst_ni.  En FPGA los `reg x = 0` se cargan con el
// bitstream; en ASIC arrancan indeterminados y la FSM podria quedarse colgada
// o cargar un valueCounter basura en el lazo de control.  Los valores de
// reset son exactamente los inicializadores del codigo original.
// ---------------------------------------------------------------------------

`default_nettype none

module uart
#(
    parameter DELAY_FRAMES = 234 // 27,000,000 (27Mhz) / 115200 Baud rate
)
(
    input wire clk_i,
    input wire rst_ni,
    input wire rx_i,
    output wire [15:0] counter_o
);
    localparam HALF_DELAY_WAIT = (DELAY_FRAMES / 2);

    // RX State Machine
    localparam RX_STATE_IDLE = 0;
    localparam RX_STATE_START_BIT = 1;
    localparam RX_STATE_READ_WAIT = 2;
    localparam RX_STATE_READ = 3;
    localparam RX_STATE_STOP_BIT = 5;

    reg [3:0] rxState = 0;
    reg [12:0] rxCounter = 0;
    reg [2:0] rxBitNumber = 0;
    reg [7:0] dataIn = 0;
    reg byteReady = 0;

    reg [15:0] valueCounter = 0;
    assign counter_o = valueCounter;

    always @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        // Mismos valores que los inicializadores del codigo original
        rxState      <= RX_STATE_IDLE;
        rxCounter    <= 13'd0;
        rxBitNumber  <= 3'd0;
        dataIn       <= 8'd0;
        byteReady    <= 1'b0;
        valueCounter <= 16'd0;
      end else begin
        case (rxState)
            RX_STATE_IDLE: begin
                if (rx_i == 0) begin
                    rxState <= RX_STATE_START_BIT;
                    rxCounter <= 1;
                    rxBitNumber <= 0;
                    byteReady <= 0;
                end
            end 
            RX_STATE_START_BIT: begin
                if (rxCounter == HALF_DELAY_WAIT) begin
                    rxState <= RX_STATE_READ_WAIT;
                    rxCounter <= 1;
                end else 
                    rxCounter <= rxCounter + 1;
            end
            RX_STATE_READ_WAIT: begin
                rxCounter <= rxCounter + 1;
                if ((rxCounter + 1) == DELAY_FRAMES) begin
                    rxState <= RX_STATE_READ;
                end
            end
            RX_STATE_READ: begin
                rxCounter <= 1;
                dataIn <= {rx_i, dataIn[7:1]};
                rxBitNumber <= rxBitNumber + 1;
                if (rxBitNumber == 3'b111)
                    rxState <= RX_STATE_STOP_BIT;
                else
                    rxState <= RX_STATE_READ_WAIT;
            end
            RX_STATE_STOP_BIT: begin
                rxCounter <= rxCounter + 1;
                if ((rxCounter + 1) == DELAY_FRAMES) begin
                    rxState <= RX_STATE_IDLE;
                    rxCounter <= 0;
                    byteReady <= 1;

                    // Expanded Control Map
                    case (dataIn)
                        // Relative Adjustments
                        "u", "U": valueCounter <= valueCounter + 16'd1569;
                        "d", "D": valueCounter <= valueCounter - 16'd1569;

                        // Absolute Setpoints
                        "0": valueCounter <= 16'd0;
                        "1": valueCounter <= 16'd4287;
                        "2": valueCounter <= 16'd8604;
                        "3": valueCounter <= 16'd12921;
                        "4": valueCounter <= 16'd17239;
                        "5": valueCounter <= 16'd21556;
                        "6": valueCounter <= 16'd25873;
                        "7": valueCounter <= 16'd30190;
                        "8": valueCounter <= 16'd34508;
                        "9": valueCounter <= 16'd38825;
                        
                        // Safety: Do nothing for undefined keys
                        default:  valueCounter <= valueCounter; 
                    endcase
                end
            end
        endcase
      end
    end

    wire _unused_uart = &{byteReady, 1'b0};

endmodule

`default_nettype wire
