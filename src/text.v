// ---------------------------------------------------------------------------
// text.v  -  motor de texto (antes 3LFCC/src/text.v)
//
// Cambios respecto al original (ninguno altera la funcion):
//
//  1) El `$readmemh("./binaries/font.hex", fontBuffer)` se sustituye por el
//     modulo font_rom, con la tabla embebida.  En el flujo de Tiny Tapeout
//     no existe ese fichero en tiempo de sintesis.
//
//  2) La direccion se construye de forma explicita.  En el original era
//         fontBuffer[((chosenChar-8'd32) << 4) + (columnAddress << 1) + (topRow ? 0 : 1)]
//     que solo funciona porque el literal entero de 32 bits ensancha toda la
//     expresion.  Aqui es  {glifo, offset}  con  offset = {columna, ~topRow},
//     aritmeticamente identico pero sin depender de las reglas de ancho.
//
//  3) Se anade rst_ni al registro de salida.
// ---------------------------------------------------------------------------

`default_nettype none

module textEngine (
    input  wire       clk_i,
    input  wire       rst_ni,
    input  wire [9:0] pixel_address_i,
    output wire [7:0] pixel_data_o,
    output wire [5:0] char_address_o,
    input  wire [7:0] char_data_i
);

  wire [2:0] columnAddress = pixel_address_i[2:0];
  wire       topRow        = !pixel_address_i[7];

  // Igual que el original: fuera del rango imprimible -> espacio
  wire [7:0] chosenChar = (char_data_i >= 8'd32 && char_data_i <= 8'd126) ? char_data_i : 8'd32;

  // (columnAddress << 1) + (topRow ? 0 : 1)
  wire [3:0] byteOffset = {columnAddress, topRow ? 1'b0 : 1'b1};

  wire [7:0] rom_data;

  font_rom u_font (
      .char_i   (chosenChar),
      .offset_i (byteOffset),
      .data_o   (rom_data)
  );

  reg [7:0] outputBuffer;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) outputBuffer <= 8'd0;
    else         outputBuffer <= rom_data;
  end

  assign char_address_o = {pixel_address_i[9:8], pixel_address_i[6:3]};
  assign pixel_data_o   = outputBuffer;

endmodule

`default_nettype wire
