`default_nettype none

module toDec(
    input wire clk,
    input wire rst_ni,
    input wire [15:0] value,               // Expanded to 16 bits
    output reg [7:0] ten_thousands, // reset: "0"
    output reg [7:0] thousands,     // reset: "0"
    output reg [7:0] hundreds,      // reset: "0"
    output reg [7:0] tens,          // reset: "0"
    output reg [7:0] units          // reset: "0"
);

    reg [19:0] digits;                // 20 bits (5 nibbles).  reset: 0
    reg [15:0] cachedValue;           // 16 bits, igual que la entrada.  reset: 0
    reg [4:0] stepCounter;            // 5 bits para contar hasta 16.  reset: 0
    reg [3:0] state;                  // reset: START_STATE

    localparam START_STATE = 0;
    localparam ADD3_STATE = 1;
    localparam SHIFT_STATE = 2;
    localparam DONE_STATE = 3;

    always @(posedge clk or negedge rst_ni) begin
      if (!rst_ni) begin
          state <= START_STATE;
          ten_thousands <= "0";       // Reset new output
          thousands <= "0";
          hundreds <= "0";
          tens <= "0";
          units <= "0";
          digits <= 0;
          // Anadido: mismos valores que los inicializadores del original
          cachedValue <= 16'd0;
          stepCounter <= 5'd0;
      end else begin
        case (state)
            START_STATE: begin
                cachedValue <= value;
                stepCounter <= 0;
                digits <= 0;
                state <= ADD3_STATE;
            end
            ADD3_STATE: begin
                // Added check for 5th nibble (digits[19:16])
                // Constant 196608 is (3 << 16)
                digits <= digits + 
                    ((digits[7:4]   >= 5) ? 20'd48 : 20'd0) + 
                    ((digits[3:0]   >= 5) ? 20'd3 : 20'd0) + 
                    ((digits[11:8]  >= 5) ? 20'd768 : 20'd0) + 
                    ((digits[15:12] >= 5) ? 20'd12288 : 20'd0) +
                    ((digits[19:16] >= 5) ? 20'd196608 : 20'd0); 
                state <= SHIFT_STATE;
            end
            SHIFT_STATE: begin
                // Shift in the MSB of the 16-bit cachedValue
                digits <= {digits[18:0], cachedValue[15] ? 1'b1 : 1'b0}; 
                cachedValue <= {cachedValue[14:0], 1'b0};
                
                // Loop runs 16 times (0 to 15)
                if (stepCounter == 15) 
                    state <= DONE_STATE;
                else begin
                    state <= ADD3_STATE;
                    stepCounter <= stepCounter + 1;
                end
            end
            DONE_STATE: begin
                // ASCII conversion for the 5th digit
                ten_thousands <= 8'd48 + {4'd0, digits[19:16]};
                thousands <= 8'd48 + {4'd0, digits[15:12]};
                hundreds <= 8'd48 + {4'd0, digits[11:8]};
                tens <= 8'd48 + {4'd0, digits[7:4]};
                units <= 8'd48 + {4'd0, digits[3:0]};
                state <= START_STATE;
            end
        endcase
      end
    end
endmodule

`default_nettype wire
