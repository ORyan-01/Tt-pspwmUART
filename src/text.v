// MODIFICADO: se elimina aqui la directiva de estrictez de compilacion.
// No afecta a ninguna logica, y se filtraba a los ficheros compilados
// despues (screen.v, toDec.v, fcc_fixpt.v), que no la declaran.

module textEngine (
    input clk_i,
    input [9:0] pixel_address_i,
    output [7:0] pixel_data_o,
    output [5:0] char_address_o,
    input [7:0] char_data_i
);
    // MODIFICADO: en el flujo de Tiny Tapeout no existe el fichero font.hex,
    // asi que la tabla va embebida en font_rom.v (mismos 1520 bytes).
    wire [10:0] font_addr;
    wire [7:0]  font_data;
    font_rom u_font (.addr_i(font_addr), .data_o(font_data));

    wire [2:0] columnAddress;
    wire topRow;

    reg [7:0] outputBuffer;
    wire [7:0] chosenChar;

    assign font_addr = ((chosenChar-8'd32) << 4) + (columnAddress << 1) + (topRow ? 0 : 1);

    always @(posedge clk_i) begin
        outputBuffer <= font_data;
    end

    assign char_address_o = {pixel_address_i[9:8],pixel_address_i[6:3]};
    assign columnAddress = pixel_address_i[2:0];
    assign topRow = !pixel_address_i[7];

    assign chosenChar = (char_data_i >= 32 && char_data_i <= 126) ? char_data_i : 32;
    assign pixel_data_o = outputBuffer;
endmodule
