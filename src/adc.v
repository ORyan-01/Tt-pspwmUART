`default_nettype none

module adc #(
    parameter address = 7'd0,
    parameter [2:0] MUX_CONFIG = 3'd000
) (
    input wire clk_i,
    input wire rst_ni,

    output reg [15:0] data_o = 0,
    output reg data_ready_o = 1,
    input wire enable_i,

    // I2C Interface
    output reg [1:0] i2c_instruction_o = 0,
    output reg i2c_enable_o = 0,
    output reg [7:0] i2c_byte_to_send_o = 0,
    input wire [7:0] i2c_byte_received_i,
    input wire i2c_complete_i
);

    // --- CONFIGURATION ---
    // bit 8 is now '0' for CONTINUOUS MODE
    reg [15:0] setupRegister = {
        1'b1,           // OS (Start)
        MUX_CONFIG,     // MUX (From Parameter)
        3'b001,         // PGA (+-4.096V)
        1'b0,           // MODE: 0 = Continuous Conversion! (Speed Boost)
        3'b111,         // DR: 860 SPS
        1'b0, 1'b0, 1'b0, 2'b11 // Defaults
    };

    localparam CONFIG_REGISTER = 8'b00000001;
    localparam CONVERSION_REGISTER = 8'b00000000;

    // Simplified Tasks
    localparam TASK_SETUP       = 0;
    localparam TASK_CHANGE_REG  = 2; // Keep index 2 to match your flow
    localparam TASK_READ_VALUE  = 3; // Keep index 3

    localparam INST_START_TX  = 0;
    localparam INST_STOP_TX   = 1;
    localparam INST_READ_BYTE = 2;
    localparam INST_WRITE_BYTE= 3;

    localparam STATE_IDLE         = 0;
    localparam STATE_RUN_TASK     = 1;
    localparam STATE_WAIT_FOR_I2C = 2;
    localparam STATE_INC_SUB_TASK = 3;
    localparam STATE_DONE         = 4;

    reg [1:0] taskIndex = 0;
    reg [2:0] subTaskIndex = 0;
    reg [4:0] state = STATE_IDLE;
    reg processStarted = 0;

    // NEW: Flag to remember if we have configured the ADC yet
    reg config_done = 0;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state <= STATE_IDLE;
            data_ready_o <= 1;
            taskIndex <= 0;
            subTaskIndex <= 0;
            processStarted <= 0;
            i2c_enable_o <= 0;
            config_done <= 0;
            // Anadido: mismos valores que los inicializadores del original,
            // para no arrancar con X en silicio / gate-level sim.
            data_o <= 16'd0;
            i2c_instruction_o <= 2'd0;
            i2c_byte_to_send_o <= 8'd0;
        end else begin
          case (state)
              // -----------------------------------------------------------------
              // 1. IDLE STATE (Smart Logic)
              // -----------------------------------------------------------------
              STATE_IDLE: begin
                  if (enable_i) begin
                      state <= STATE_RUN_TASK;
                      data_ready_o <= 0;
                      subTaskIndex <= 0;

                      if (config_done == 0) begin
                          taskIndex <= TASK_SETUP;
                      end else begin
                          taskIndex <= TASK_READ_VALUE;
                      end
                  end
              end

              // -----------------------------------------------------------------
              // 2. RUN TASK (Simplified Case)
              // -----------------------------------------------------------------
              STATE_RUN_TASK: begin
                  case ({taskIndex,subTaskIndex})
                      // --- I2C START CONDITION ---
                      {TASK_SETUP,3'd0},
                      {TASK_CHANGE_REG,3'd1},
                      {TASK_READ_VALUE,3'd0}: begin
                          i2c_instruction_o <= INST_START_TX;
                          i2c_enable_o <= 1;
                          state <= STATE_WAIT_FOR_I2C;
                      end

                      // --- I2C ADDRESS WRITE ---
                      {TASK_SETUP,3'd1},
                      {TASK_CHANGE_REG,3'd2},
                      {TASK_READ_VALUE,3'd1}: begin
                          i2c_instruction_o <= INST_WRITE_BYTE;
                          // If Reading, bit 0 is '1' (Read), else '0' (Write)
                          i2c_byte_to_send_o <= {address, (taskIndex == TASK_READ_VALUE) ? 1'b1 : 1'b0};
                          i2c_enable_o <= 1;
                          state <= STATE_WAIT_FOR_I2C;
                      end

                      // --- I2C STOP CONDITION ---
                      {TASK_SETUP,3'd5},
                      {TASK_CHANGE_REG,3'd4},
                      {TASK_READ_VALUE,3'd5}: begin
                          i2c_instruction_o <= INST_STOP_TX;
                          i2c_enable_o <= 1;
                          state <= STATE_WAIT_FOR_I2C;
                      end

                      // --- TASK_SETUP SPECIFIC STEPS ---
                      {TASK_SETUP,3'd2}: begin // Target Config Reg
                          i2c_instruction_o <= INST_WRITE_BYTE;
                          i2c_byte_to_send_o <= CONFIG_REGISTER;
                          i2c_enable_o <= 1;
                          state <= STATE_WAIT_FOR_I2C;
                      end
                      {TASK_SETUP,3'd3}: begin // Write MSB
                          i2c_instruction_o <= INST_WRITE_BYTE;
                          i2c_byte_to_send_o <= setupRegister[15:8];
                          i2c_enable_o <= 1;
                          state <= STATE_WAIT_FOR_I2C;
                      end
                      {TASK_SETUP,3'd4}: begin // Write LSB
                          i2c_instruction_o <= INST_WRITE_BYTE;
                          i2c_byte_to_send_o <= setupRegister[7:0];
                          i2c_enable_o <= 1;
                          state <= STATE_WAIT_FOR_I2C;
                      end

                      // --- TASK_CHANGE_REG SPECIFIC STEPS ---
                      // This points the internal pointer back to the Conversion (Data) Register
                      {TASK_CHANGE_REG,3'd3}: begin
                          i2c_instruction_o <= INST_WRITE_BYTE;
                          i2c_byte_to_send_o <= CONVERSION_REGISTER;
                          i2c_enable_o <= 1;
                          state <= STATE_WAIT_FOR_I2C;
                      end
                      {TASK_CHANGE_REG,3'd0}: state <= STATE_INC_SUB_TASK;

                      // --- TASK_READ_VALUE SPECIFIC STEPS ---
                      {TASK_READ_VALUE,3'd2}: begin // Read MSB
                          i2c_instruction_o <= INST_READ_BYTE;
                          i2c_enable_o <= 1;
                          state <= STATE_WAIT_FOR_I2C;
                      end
                      {TASK_READ_VALUE,3'd3}: begin // Save MSB
                          i2c_instruction_o <= INST_READ_BYTE; // Read LSB now
                          data_o[15:8] <= i2c_byte_received_i; // Store MSB
                          i2c_enable_o <= 1;
                          state <= STATE_WAIT_FOR_I2C;
                      end
                      {TASK_READ_VALUE,3'd4}: begin // Save LSB
                          data_o[7:0] <= i2c_byte_received_i;
                          state <= STATE_INC_SUB_TASK;
                      end

                      default: state <= STATE_INC_SUB_TASK;
                  endcase
              end

              // -----------------------------------------------------------------
              // 3. I2C WAIT HELPER
              // -----------------------------------------------------------------
              STATE_WAIT_FOR_I2C: begin
                  if (~processStarted && ~i2c_complete_i)
                      processStarted <= 1;
                  else if (i2c_complete_i && processStarted) begin
                      state <= STATE_INC_SUB_TASK;
                      processStarted <= 0;
                      i2c_enable_o <= 0;
                  end
              end

              // -----------------------------------------------------------------
              // 4. TASK FLOW CONTROLLER (The Logic Fix)
              // -----------------------------------------------------------------
              STATE_INC_SUB_TASK: begin
                  state <= STATE_RUN_TASK;
                  
                  // If sub-task chain is finished (reached 5)
                  if (subTaskIndex == 3'd5) begin 
                      subTaskIndex <= 0;

                      // FLOW CONTROL
                      if (taskIndex == TASK_SETUP) begin
                          // Setup done -> Now reset pointer
                          taskIndex <= TASK_CHANGE_REG; 
                      end
                      else if (taskIndex == TASK_CHANGE_REG) begin
                          // Pointer reset done -> Now Read
                          taskIndex <= TASK_READ_VALUE; 
                          config_done <= 1; // Mark as initialized!
                      end
                      else if (taskIndex == TASK_READ_VALUE) begin
                          // Reading done -> Finish
                          state <= STATE_DONE;
                      end
                  end 
                  else begin
                      subTaskIndex <= subTaskIndex + 1;
                  end
              end

              STATE_DONE: begin
                  data_ready_o <= 1;
                  if (~enable_i) state <= STATE_IDLE;
              end
          endcase
        end
    end
endmodule

`default_nettype wire
