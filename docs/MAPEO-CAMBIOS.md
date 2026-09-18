# Mapeo de cambios: FPGA → Tiny Tapeout

**Origen:** `nic0villegasc/LushayLabs-TangNano20K`, carpeta `3LFCC/src`
**Destino:** `ORyan-01/tt-profejorgemarin`, carpeta `src`

Criterio: **cambiar lo mínimo necesario**. Solo se modifica lo que impide que el
diseño llegue a silicio. Todo lo que era limpieza de avisos del linter quedó fuera.

El diff completo de cada fichero está en `docs/diffs/<fichero>.diff`.

---

## Resumen

| Original | En el repo TT | Líneas + | Líneas − | Motivo |
|---|---|---:|---:|---|
| `Comparator.v` | `comparator.v` | 0 | 0 | copia textual |
| `Signal_Generator_0phase.v` | `signal_generator_0phase.v` | 0 | 0 | copia textual |
| `Signal_Generator_180phase.v` | `signal_generator_180phase.v` | 0 | 0 | copia textual |
| `timer_control.v` | `timer_control.v` | 0 | 0 | copia textual |
| `toDec.v` | `toDec.v` | 0 | 0 | copia textual |
| `i2c.v` | `i2c.v` | 2 | 0 | directiva de compilación |
| `adc.v` | `adc.v` | 3 | 0 | directiva de compilación |
| `PS_PWM.v` | `ps_pwm.v` | 4 | 0 | propagar `rst_ni` |
| `Dead_Time_Generator.v` | `dead_time_generator.v` | 7 | 2 | **reset** |
| `text.v` | `text.v` | 11 | 3 | **memoria de la fuente** |
| `uart.v` | `uart.v` | 14 | 1 | **reset** |
| `screen.v` | `screen.v` | 18 | 1 | **reset** |
| `fcc_fixpt.v` | `fcc_fixpt.v` | 20 | 14 | **reuso de variables** |
| `top.v` | `fcc_core.v` | 73 | 11 | pines + división |
| | **TOTAL** | **152** | **32** | |

**Ficheros nuevos** (no modifican nada verificado): `project.v`, `font_rom.v`, `div_u32.v`
**No portado:** `toHex.v` — no estaba instanciado en `top.v`

---

## 1. Reuso de variables — `fcc_fixpt.v`

**Síntoma:** el GDS abortaba a los 3 minutos.

```
Warning: multiple conflicting drivers for fcc_fixpt.\xUik_reg_t_0_0 [31]:
    port Q[31] of cell $procdff$1715 ($dff)
    port Q[31] of cell $procdff$1693 ($dff)
...
Found and reported 64 problems.
ERROR  64 Yosys check errors found.
```

**Causa:** MATLAB HDL Coder reutilizó la misma variable de bucle en dos procesos con
reloj distintos:

- `xXik_reg_t_0_0` → `xXik_reg_process` (línea 212) y `xXik_reg_1_process` (línea 374)
- `xUik_reg_t_0_0` → `xUik_reg_process` (línea 260) y `xUik_reg_1_process` (línea 420)

Al ser `reg` de módulo asignados con `=` dentro de un `always @(posedge ...)`, Yosys
infiere un biestable por proceso y acaba con dos drivers sobre la misma red. 32 bits ×
2 variables = los 64 errores exactos.

**Cambio:** los cuatro bucles tienen límites constantes `0..1`, así que se desenrollaron
a mano y las dos variables desaparecen.

```verilog
// antes
for(xXik_reg_t_0_0 = 32'sd0; xXik_reg_t_0_0 <= 32'sd1; ...) begin
  xXik[xXik_reg_t_0_0] <= tmp_5[xXik_reg_t_0_0];
end
// ahora
xXik[0] <= tmp_5[0];
xXik[1] <= tmp_5[1];
```

Es exactamente lo que hacen el simulador y el sintetizador al desenrollar. La variable
no se lee nunca fuera del bucle y se reinicia a 0 en cada ejecución: el valor que
retenía era estado muerto.

---

## 2. Reset que en FPGA entregaba el bitstream

**Ficheros:** `screen.v` (11 registros), `uart.v` (6), `Dead_Time_Generator.v` (2),
y `PS_PWM.v` solo para propagar la señal.

En FPGA, `reg x = 0;` lo carga el bitstream al configurar el dispositivo. En silicio
**los biestables arrancan en un valor desconocido**. Sin reset:

- la FSM de `screen.v` puede despertar en un estado inválido y no inicializar nunca el panel
- `uart.v` puede cargar un `valueCounter` basura directamente en el lazo de control
- los generadores de tiempo muerto arrancan con el contador indeterminado

**Cambio:** se añade el puerto `rst_ni` y una rama de reset con **exactamente los mismos
valores** que tenían los inicializadores de la declaración. Los inicializadores se
dejaron donde estaban.

Ejemplo de `screen.v`:

| Registro | Inicializador original | Valor de reset |
|---|---|---|
| `counter` | `0` | `0` |
| `state` | `0` (`STATE_INIT_POWER`) | `STATE_INIT_POWER` |
| `dc` | `1` | `1` |
| `sclk` | `1` | `1` |
| `sdin` | `0` | `0` |
| `reset` | `1` | `1` |
| `cs` | `0` | `0` |
| `dataToSend` | `0` | `0` |
| `bitNumber` | `0` | `0` |
| `pixelCounter` | `0` | `0` |
| `commandIndex` | `SETUP_INSTRUCTIONS * 8` | `SETUP_INSTRUCTIONS * 8` |

`text.v` **no** lleva reset: su único registro (`outputBuffer`) no tenía inicializador
en el original, se escribe cada ciclo y se autocorrige solo.

---

## 3. Data en memoria para el texto del OLED — `text.v` + `font_rom.v`

**Causa:** `text.v` leía la fuente con

```verilog
reg [7:0] fontBuffer [0:1519];
initial $readmemh("./binaries/font.hex", fontBuffer);
```

Ese fichero no existe en el flujo de Tiny Tapeout en tiempo de síntesis.

**Cambio:** la tabla va embebida en `font_rom.v`, un fichero nuevo, con **los 1520 bytes
completos** (los 95 glifos ASCII 32-126). La expresión de dirección de `text.v` se dejó
**escrita igual que en el original**:

```verilog
assign font_addr = ((chosenChar-8'd32) << 4) + (columnAddress << 1) + (topRow ? 0 : 1);
```

Verificado: los 95 glifos coinciden byte a byte con `font.hex`, y la dirección nunca
excede 1519 en las 95 × 1024 combinaciones posibles.

`font_rom.v` trae además un `` `define FONT_MIN `` que instancia solo los 28 glifos
alcanzables, por si hiciera falta recortar área. **Va desactivado.**

---

## 4. División combinacional — `fcc_core.v` + `div_u32.v`

> Este punto **no estaba en la lista** del profesor. Se incluye por el motivo de abajo
> y se revierte tocando un solo fichero.

```verilog
avg_fc_disp  <= (sum_fc / sample_count) >> 4;
avg_out_disp <= (sum_out / sample_count) >> 4;
```

Son dos divisiones de 32/16 bits **combinacionales**. En ASIC eso sintetiza un divisor
de varios miles de celdas con un camino crítico de del orden de 16 restas de 17 bits en
serie. A 27 MHz (37 ns) el camino viola setup por un margen muy amplio, así que el
promedio mostrado en pantalla saldría corrupto. Además el área crece bastante, y el
diseño ya va al 57 % de un 6×2.

**Cambio:** un divisor secuencial compartido (`div_u32.v`) que hace las dos divisiones
en 66 ciclos. El resultado numérico es **idéntico**: división entera truncada.
Verificado contra la división entera en 120.007 casos, incluidos los límites
(`0/1`, `0xFFFFFFFF/1`, `0xFFFFFFFF/65535`).

El display se refresca una vez por segundo, así que 2,4 µs de latencia no se ven.

**Para revertirlo:** restaurar el bloque original en `fcc_core.v` y borrar `div_u32.v`
de `src/`, de `info.yaml` y del `Makefile`.

---

## 5. Pines y bidireccionales — `fcc_core.v` + `project.v`

Tiny Tapeout ofrece 8 salidas dedicadas, 8 bidireccionales y 8 entradas.

| | El chip necesita | Hay |
|---|---|---|
| Salidas | `scl_1_o`, `scl_2_o`, `pwm_o[7:0]`, 5 del OLED → **15** | 8 |
| Bidireccionales | `sda_1_io`, `sda_2_io` → **2** | 8 |
| **Total que sale** | **17** | **16** |

Falta un pin.

**Solución: los dos buses I2C comparten SCL.** Las dos instancias de `i2c` son la misma
máquina de estados, con el mismo reloj y el mismo reset, y sus habilitaciones se ponen a
1 en el mismo ciclo. Dentro de `i2c.v` ninguna transición depende de `sda_i` (solo de
`clockDivider`) y en `STATE_RCV_ACK` el ACK ni se comprueba. Lo único que difiere entre
canales es `MUX_CONFIG`, que cambia el **dato** de SDA, nunca el temporizado de SCL.

Por tanto `scl_1_o` y `scl_2_o` son bit a bit idénticos en todo instante, y se fusionan
con un AND: el mismo wired-AND que harían sobre una línea física común.

Comprobado con un modelo ciclo a ciclo de los dos `adc` + dos `i2c` + la FSM de
adquisición, 3.000.000 de ciclos con datos de esclavo distintos y aleatorios:

```
ciclos con scl_1 != scl_2         : 0
ciclos con is_sending_1 != is_s_2 : 0
ciclos en que SDA1 y SDA2 difieren: 128   <- correcto, son los bits de MUX
```

**Los tri-states.** Tiny Tapeout no admite `1'bz` dentro del diseño. En `fcc_core.v` el
`inout` se parte en dos señales y el tri-state se reconstruye en `project.v` sobre
`uio_oe`:

```verilog
// original (top.v)
assign sda_1_io = (isSending_1 & ~sdaOut_1) ? 1'b0 : 1'bz;
assign sdaIn_1  = sda_1_io ? 1'b1 : 1'b0;

// fcc_core.v
assign sda_1_pd_o = isSending_1 & ~sdaOut_1;
assign sdaIn_1    = sda_1_i;

// project.v
assign uio_out[0] = 1'b0;        // nunca se fuerza un 1
assign uio_oe [0] = sda_1_pd;
```

Mismo comportamiento eléctrico.

**Mapa final:**

| Señal original | Pin de Tiny Tapeout |
|---|---|
| `uart_rx_i` | `ui[0]` |
| *(strap SCL: 0 = push-pull, 1 = open drain)* | `ui[1]` |
| `pwm_o[7:0]` | `uo[7:0]`, mismo orden de bits |
| `sda_1_io` | `uio[0]` open drain |
| `sda_2_io` | `uio[1]` open drain |
| `scl_1_o` **AND** `scl_2_o` | `uio[2]` |
| `ioSclk`, `ioSdin`, `ioCs`, `ioDc`, `ioReset` | `uio[3..7]` |

**Otros cambios en `fcc_core.v`:** el módulo se renombra de `top` a `fcc_core` para no
tener un módulo llamado `top` dentro del flujo endurecido. El multiplicador
`duty_counter_o * 32'd4099` se dejó **tal cual**.

---

## 6. Directiva de compilación — `adc.v`, `i2c.v`, `text.v`, `uart.v`

Esos cuatro ficheros empiezan con `` `default_nettype none ``. Esa directiva **se filtra
a los ficheros que se compilan después**, y `screen.v`, `toDec.v` y `fcc_fixpt.v` no la
declaran.

**Cambio:** una línea al final de cada uno restaurando `` `default_nettype wire ``. Es
el valor por defecto del lenguaje y no altera ninguna lógica.

---

## 7. Verificación de esta versión

| Comprobación | Casos | Resultado |
|---|---|---|
| `font_rom` vs `font.hex` | 95 glifos × 16 bytes | 0 diferencias |
| Dirección de la ROM de texto | 95 × 1024 | 0 fuera de rango |
| `div_u32` vs división entera | 120.007 con límites | 0 cocientes erróneos |
| Reset de `screen.v` | 11 registros | valores == inicializadores |
| Reset de `uart.v` | 6 registros | valores == inicializadores |
| SCL compartido | 3.000.000 de ciclos | 0 desincronizaciones |
| Ficheros sin ningún cambio | 5 | idénticos byte a byte |

Banco de pruebas: 9 tests en `test/test.py`. Los dos más relevantes son
`test_no_shoot_through`, que comprueba que PMOS y NMOS de la misma rama nunca conducen a
la vez, y `test_i2c_config_sequence`, que decodifica las tramas reales de los dos buses
y exige `[0x92, 0x01, 0x82, 0xE3]` en SDA1 y `[0x92, 0x01, 0xC2, 0xE3]` en SDA2, lo que
valida la decisión del SCL compartido sobre el netlist con retardos.

---

## 8. Qué cambia en la placa

1. **Las dos líneas SCL van puenteadas** a un único pin. Pull-ups de 4,7 kΩ en SDA1,
   SDA2 y SCL. SDA sigue separado por ADS1115.
2. **`ui[1]` cableado a 0**, que deja SCL en push-pull igual que la FPGA.
