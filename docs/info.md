## How it works

Modulador **PS-PWM** (*Phase-Shift PWM*) para un convertidor Flying Capacitor de 3
niveles. Es el modulador del diseño FPGA de Nicolás Villegas para la Tang Nano 20K
(`github.com/nic0villegasc/LushayLabs-TangNano20K`, carpeta `3LFCC`), llevado a
silicio con los dos ciclos de trabajo expuestos a pines y el receptor UART de Nicolás
como segunda forma de fijarlos.

Funciona en **lazo abierto**: no mide ni corrige, genera el PWM que se le pide.

El chip compara cada ciclo de trabajo contra una portadora triangular de 7 bits. Las
dos ramas usan dos portadoras **desfasadas 180 grados**, lo que hace que conmuten
alternadas y reduce el rizado de la salida. La portadora cuenta de 0 a 127 y vuelve,
con un período de 254 ciclos de reloj: **106 kHz** de frecuencia de conmutación a
27 MHz.

Cada rama tiene un PMOS y un NMOS que trabajan de forma complementaria. Para que nunca
conduzcan a la vez, cada señal pasa por un generador de **tiempo muerto**: el flanco de
apagado es inmediato y el de encendido va retrasado **5 ciclos de reloj (185 ns)**.

Con el reset activo, las cuatro llaves quedan apagadas.

### Dos formas de fijar el ciclo de trabajo

`uio[7]` elige de dónde sale:

| `uio[7]` | Modo | D1 | D2 |
|---|---|---|---|
| 0 | pines | `ui[6:0]` | `uio[6:0]` |
| 1 | UART | valor recibido | el mismo valor |

En modo pines el UART no interviene: la salida es exactamente la misma que sin él.

### Parejas de cada rama

| Rama | PMOS (activo a bajo) | NMOS (activo a alto) |
|---|---|---|
| 1 | `uo[0]` | `uo[3]` |
| 2 | `uo[1]` | `uo[2]` |

## How to test

Reloj de **27 MHz**.

### Modo pines (`uio[7] = 0`)

1. Fijá **D1** en `ui[6:0]` y **D2** en `uio[6:0]`. El valor es el ciclo de trabajo en
   binario, de 0 a 127:

   | Valor | Ciclo de trabajo |
   |---|---|
   | `0000000` | 0 % |
   | `1000000` | 50 % |
   | `1111111` | 100 % |

2. Soltá el reset. En `uo[0..3]` aparecen las cuatro señales de puerta.
3. Para operación simétrica, D1 = D2. Para desbalancear las ramas, valores distintos.

### Modo UART (`uio[7] = 1`)

`ui[7]` es uno de los pines que alcanza el puente USB-serie de la placa de
demostración, así que no hace falta adaptador:

1. Enchufá la placa al PC y abrí un terminal a **115200 baudios, 8N1**.
2. Tecleá:

   | Tecla | Efecto |
   |---|---|
   | `0` a `9` | consignas fijas: `0` = 0 %, `9` = 59 % |
   | `u` / `d` | sube o baja unos 2 puntos |

3. El mismo valor va a las dos ramas.

**Nota:** ese puente usa `uo[0]` como línea de vuelta, y por `uo[0]` sale el PMOS1. El
terminal va a mostrar caracteres sin sentido mientras conmuta el PWM. Es inofensivo: el
UART de este chip solo recibe.

### Con el osciloscopio

- `uo[4]` da un pulso en cada extremo de la portadora: sirve de disparo.
- Para comprobar el tiempo muerto, mirá a la vez `uo[3]` y `uo[0]`: entre que el NMOS2
  se apaga y el PMOS1 se enciende tiene que haber al menos 185 ns.

**Ojo con duty 0:** con ciclo de trabajo cero los PMOS no llegan a encender y `uo[0]`
y `uo[1]` se quedan en alto. Es correcto, no un fallo.

## External hardware

- Etapa de potencia de un convertidor Flying Capacitor de 3 niveles, con drivers de
  puerta en `uo[0..3]`. **Respetar la polaridad:** los PMOS son activos a bajo y los
  NMOS activos a alto.
- Interruptores o el RP2040 de la placa de demostración para fijar D1, D2 y el modo.
- Osciloscopio para observar las salidas.
