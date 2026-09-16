## How it works

Controlador digital completo para un **convertidor Flying Capacitor de 3 niveles (3LFCC)**.
Es el port a ASIC del diseno FPGA de Nicolas Villegas para la Tang Nano 20K
(`github.com/nic0villegasc/LushayLabs-TangNano20K`, carpeta `3LFCC`), sin perder
ninguna funcion.

El chip contiene cinco bloques:

1. **Adquisicion**: dos maestros I2C independientes leen dos ADS1115 (ambos en la
   direccion `0x49`, por eso hacen falta dos lineas SDA separadas). Uno mide la
   tension del condensador flotante en modo diferencial, el otro la tension de
   salida en modo single-ended. Configuracion: PGA +-4.096 V, 860 SPS, conversion
   continua.

2. **Lazo de control**: `fcc_fixpt`, un PI en punto fijo generado con MATLAB HDL
   Coder, que entrega dos ciclos de trabajo de 7 bits (D1, D2). Se dispara con un
   `timer_control` que espera al fin de conversion de **ambos** ADC.

3. **Modulador PS-PWM**: dos portadoras triangulares de 7 bits desfasadas 180 grados,
   dos comparadores y cuatro generadores de tiempo muerto (4 ciclos de reloj).
   Produce las cuatro senales de puerta. Con reset activo las salidas quedan en el
   estado seguro (PMOS apagados, NMOS apagados).

4. **Referencia por UART**: receptor 115200 8N1. `u`/`d` suben o bajan la referencia,
   `0`-`9` fijan consignas absolutas.

5. **Telemetria en OLED**: driver SPI de un SSD1306 de 128x64 con motor de texto y
   ROM de fuente. Muestra tension del flying cap, tension de salida, frecuencia de
   muestreo real (promediada cada segundo) y la referencia de tension.

### Que cambio respecto a la FPGA

Tiny Tapeout ofrece 8 salidas dedicadas mas 8 bidireccionales = 16 pines de salida,
y el diseno original necesitaba 15 salidas + 2 bidireccionales = 17. Faltaba uno.

La solucion: **los dos buses I2C comparten la linea SCL**. Los dos maestros I2C son
maquinas de estado identicas, con el mismo reloj y el mismo reset, y se habilitan en
el mismo ciclo; dentro de `i2c.v` ninguna transicion depende de SDA, solo del divisor
de reloj interno. Por tanto `scl_1_o` y `scl_2_o` son bit a bit identicos en todo
instante y se fusionan con un AND (el mismo wired-AND que harian sobre una linea
fisica comun). Los datos siguen separados, que es lo unico que necesitaban los dos
ADS1115 para no colisionar de direccion.

Ademas: los `$readmemh` de la fuente pasan a ROM embebida, las dos divisiones de
32/16 bits pasan a un divisor secuencial (mismo resultado exacto, 33 ciclos), y se
anaden resets a los modulos que en FPGA dependian del valor inicial del bitstream.

## How to test

Alimenta el chip a 3.3 V y dale un reloj de **27 MHz**.

1. Pon `ui[1] = 0` (SCL push-pull, como la FPGA) o `ui[1] = 1` si prefieres
   open-drain estricto con pull-ups.
2. Deja `ui[0]` (UART RX) en alto si no vas a usar la consola.
3. Suelta el reset. Los pines `uo[0..3]` empiezan a conmutar a la frecuencia de
   portadora (27 MHz / 254 ~ 106 kHz) y `uo[5]` parpadea a 0.5 Hz: esa es la senal
   de vida mas rapida de comprobar con un LED.
4. Con el OLED conectado, tras ~1.1 s de secuencia de reset del panel aparecen las
   cuatro filas de telemetria.
5. Por UART a 115200 8N1, envia `5` y observa como cambia la fila `Vref:` y el ciclo
   de trabajo de las salidas PWM.

Sin los ADS1115 conectados el chip sigue funcionando: los maestros I2C completan sus
tramas igual (no hay clock stretching ni dependencia del ACK), las lecturas salen
todo unos y el lazo trabaja con esos valores.

## External hardware

- 2 x **ADS1115** (ADC I2C 16 bits), ambos en direccion `0x49`.
  **SCL comun a los dos**; SDA separado por chip. Pull-ups de 4.7 kohm en SDA1,
  SDA2 y SCL.
- 1 x **OLED SSD1306 128x64** en modo SPI de 4 hilos (SCLK, SDIN, CS, DC, RES).
- Adaptador **USB-serie** 3.3 V a 115200 baudios en `ui[0]`.
- Etapa de potencia del convertidor flying capacitor de 3 niveles con drivers de
  puerta en `uo[0..3]`.
