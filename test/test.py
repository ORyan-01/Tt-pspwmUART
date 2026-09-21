# SPDX-FileCopyrightText: © 2025 PUCV
# SPDX-License-Identifier: Apache-2.0
#
# Pruebas del modulador PS-PWM en 1x1, con UART opcional.
# Modulos originales de Nicolas Villegas (LushayLabs-TangNano20K, 3LFCC).
#
# Convenios:
#   ui[6:0]   D1, ciclo de trabajo de la rama 1
#   ui[7]     UART RX (en reposo a 1)
#   uio[6:0]  D2, ciclo de trabajo de la rama 2
#   uio[7]    fuente del duty: 0 = pines, 1 = UART
#
# El reloj se arranca UNA sola vez por prueba.  Los resets que haga falta se
# hacen con reset(), que no toca el reloj.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

CLK_NS = 37                # 27 MHz
CARRIER = 254              # periodo de la portadora, en ciclos
DEAD_TIME = 5              # ciclos de retardo en el flanco de encendido
BAUD = 234                 # 27e6 / 115200


def iniciar_reloj(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())


async def reset(dut, d1=0, d2=0, modo_uart=0):
    """Deja el chip en reset con los duty fijados, y lo suelta."""
    dut.ena.value = 1
    dut.ui_in.value = (d1 & 0x7F) | 0x80                  # UART en reposo
    dut.uio_in.value = (d2 & 0x7F) | ((modo_uart & 1) << 7)
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)


async def enviar_uart(dut, ch, d1=0):
    """Manda un caracter a 115200 8N1 por ui[7], sin tocar D1."""
    bits = [0] + [(ord(ch) >> i) & 1 for i in range(8)] + [1]
    for b in bits:
        dut.ui_in.value = (d1 & 0x7F) | (b << 7)
        await ClockCycles(dut.clk, BAUD)
    dut.ui_in.value = (d1 & 0x7F) | 0x80
    await ClockCycles(dut.clk, 300)


async def encendido(dut, ciclos):
    """Cuenta los ciclos en que cada PMOS (activo a bajo) conduce."""
    p1 = p2 = 0
    for _ in range(ciclos):
        await ClockCycles(dut.clk, 1)
        uo = int(dut.uo_out.value)
        if (uo & 1) == 0:
            p1 += 1
        if ((uo >> 1) & 1) == 0:
            p2 += 1
    return p1, p2


def cruzada(uo):
    """True si PMOS y NMOS de una misma rama conducen a la vez."""
    pmos1, pmos2 = uo & 1, (uo >> 1) & 1
    nmos1, nmos2 = (uo >> 2) & 1, (uo >> 3) & 1
    return (pmos1 == 0 and nmos2 == 1) or (pmos2 == 0 and nmos1 == 1)


# ===========================================================================
#  MODO PINES  (uio[7] = 0): el funcionamiento del modulador de Nicolas
# ===========================================================================

@cocotb.test()
async def test_estado_seguro(dut):
    """Con rst_n en bajo las cuatro llaves quedan apagadas."""
    iniciar_reloj(dut)
    dut.ena.value = 1
    dut.ui_in.value = 64 | 0x80
    dut.uio_in.value = 64
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)

    uo = int(dut.uo_out.value)
    assert (uo >> 0) & 1 == 1, "PMOS1 deberia estar apagado (uo[0] = 1)"
    assert (uo >> 1) & 1 == 1, "PMOS2 deberia estar apagado (uo[1] = 1)"
    assert (uo >> 2) & 1 == 0, "NMOS1 deberia estar apagado (uo[2] = 0)"
    assert (uo >> 3) & 1 == 0, "NMOS2 deberia estar apagado (uo[3] = 0)"
    assert int(dut.uio_oe.value) == 0, "uio deberia ser entrada completa"


@cocotb.test()
async def test_sin_conduccion_cruzada(dut):
    """PMOS y NMOS de la misma rama nunca conducen a la vez.
    Si esto falla, la etapa de potencia se destruye."""
    iniciar_reloj(dut)
    for d1, d2 in [(64, 64), (10, 120), (120, 10), (1, 126)]:
        await reset(dut, d1, d2)
        for c in range(3 * CARRIER):
            await ClockCycles(dut.clk, 1)
            assert not cruzada(int(dut.uo_out.value)), \
                f"conduccion cruzada con D1={d1} D2={d2}, ciclo {c}"


@cocotb.test()
async def test_frecuencia_portadora(dut):
    """El disparo de fin de rampa sale dos veces por periodo (cada 127 ciclos)."""
    iniciar_reloj(dut)
    await reset(dut, 64, 64)
    await ClockCycles(dut.clk, 50)

    flancos = []
    prev = (int(dut.uo_out.value) >> 4) & 1
    for c in range(4 * CARRIER):
        await ClockCycles(dut.clk, 1)
        cur = (int(dut.uo_out.value) >> 4) & 1
        if prev == 0 and cur == 1:
            flancos.append(c)
        prev = cur

    assert len(flancos) >= 3, "la portadora no esta corriendo"
    for p in [b - a for a, b in zip(flancos, flancos[1:])]:
        assert abs(p - CARRIER // 2) <= 2, \
            f"separacion entre disparos {p}, se esperaba ~{CARRIER // 2}"


@cocotb.test()
async def test_tiempo_muerto(dut):
    """Entre apagar el NMOS2 y encender el PMOS1 hay al menos 5 ciclos."""
    iniciar_reloj(dut)
    await reset(dut, 64, 64)
    await ClockCycles(dut.clk, 50)

    prev_n = (int(dut.uo_out.value) >> 3) & 1
    hueco = None
    espera = 0
    for _ in range(4 * CARRIER):
        await ClockCycles(dut.clk, 1)
        uo = int(dut.uo_out.value)
        n2 = (uo >> 3) & 1
        if espera:
            espera += 1
            if (uo & 1) == 0:
                hueco = espera
                break
        elif prev_n == 1 and n2 == 0:
            espera = 1
        prev_n = n2

    assert hueco is not None, "no se observo la transicion en la rama 1"
    assert hueco >= DEAD_TIME, f"tiempo muerto de {hueco} ciclos, se esperaba >= {DEAD_TIME}"


@cocotb.test()
async def test_d1_controla_rama1(dut):
    """A mas D1, mas tiempo encendido el PMOS1."""
    iniciar_reloj(dut)
    await reset(dut, 20, 64)
    await ClockCycles(dut.clk, CARRIER)
    bajo, _ = await encendido(dut, 2 * CARRIER)

    await reset(dut, 100, 64)
    await ClockCycles(dut.clk, CARRIER)
    alto, _ = await encendido(dut, 2 * CARRIER)

    assert alto > bajo, f"D1 no responde: {bajo} con 20, {alto} con 100"


@cocotb.test()
async def test_d2_controla_rama2(dut):
    """A mas D2, mas tiempo encendido el PMOS2, con D1 fijo."""
    iniciar_reloj(dut)
    await reset(dut, 64, 20)
    await ClockCycles(dut.clk, CARRIER)
    _, bajo = await encendido(dut, 2 * CARRIER)

    await reset(dut, 64, 100)
    await ClockCycles(dut.clk, CARRIER)
    _, alto = await encendido(dut, 2 * CARRIER)

    assert alto > bajo, f"D2 no responde: {bajo} con 20, {alto} con 100"


@cocotb.test()
async def test_desbalance(dut):
    """Con D1 distinto de D2, las dos ramas conmutan con anchos distintos."""
    iniciar_reloj(dut)
    await reset(dut, 20, 110)
    await ClockCycles(dut.clk, CARRIER)
    on1, on2 = await encendido(dut, 2 * CARRIER)
    assert on2 > on1, f"rama 2 ({on2}) deberia conducir mas que rama 1 ({on1})"


@cocotb.test()
async def test_pines_sin_uso(dut):
    """uio queda en entrada y uo[7:5] a cero."""
    iniciar_reloj(dut)
    await reset(dut, 64, 64)
    for _ in range(500):
        await ClockCycles(dut.clk, 1)
        assert int(dut.uio_oe.value) == 0, "uio no deberia conducir nunca"
        assert int(dut.uio_out.value) == 0, "uio_out deberia estar a 0"
        assert (int(dut.uo_out.value) >> 5) == 0, "uo[7:5] deberian estar a 0"


@cocotb.test()
async def test_modo_pines_ignora_uart(dut):
    """En modo pines, lo que entre por el UART no cambia NADA de la salida.
    Es la garantia de que agregar el UART no altero el modulador."""
    iniciar_reloj(dut)
    trama = [0] + [(ord('9') >> i) & 1 for i in range(8)] + [1]

    async def capturar(con_trafico):
        await reset(dut, 40, 90, modo_uart=0)
        salida = []
        for b in trama:
            dut.ui_in.value = 40 | ((b if con_trafico else 1) << 7)
            for _ in range(BAUD):
                await ClockCycles(dut.clk, 1)
                salida.append(int(dut.uo_out.value))
        return salida

    sin_uart = await capturar(False)
    con_uart = await capturar(True)
    distintos = sum(1 for a, b in zip(sin_uart, con_uart) if a != b)
    assert distintos == 0, f"el trafico UART altero la salida en {distintos} ciclos"


# ===========================================================================
#  MODO UART  (uio[7] = 1)
# ===========================================================================

@cocotb.test()
async def test_uart_fija_duty(dut):
    """Mandar '9' por UART deja mas duty que mandar '1'."""
    iniciar_reloj(dut)

    await reset(dut, 0, 0, modo_uart=1)
    await enviar_uart(dut, '1')
    bajo, _ = await encendido(dut, 3 * CARRIER)

    await reset(dut, 0, 0, modo_uart=1)
    await enviar_uart(dut, '9')
    alto, _ = await encendido(dut, 3 * CARRIER)

    assert alto > bajo, f"el UART no mueve el duty: '1' dio {bajo}, '9' dio {alto}"
    dut._log.info(f"PMOS1 encendido: {bajo} ciclos con '1', {alto} con '9'")


@cocotb.test()
async def test_uart_simetrico_y_seguro(dut):
    """En modo UART las dos ramas reciben el mismo duty y nunca hay
    conduccion cruzada."""
    iniciar_reloj(dut)
    await reset(dut, 0, 0, modo_uart=1)
    await enviar_uart(dut, '5')

    on1 = on2 = 0
    for c in range(3 * CARRIER):
        await ClockCycles(dut.clk, 1)
        uo = int(dut.uo_out.value)
        assert not cruzada(uo), f"conduccion cruzada en modo UART, ciclo {c}"
        if (uo & 1) == 0:
            on1 += 1
        if ((uo >> 1) & 1) == 0:
            on2 += 1

    assert on1 > 0, "en modo UART con '5' el PMOS1 deberia conmutar"
    assert on1 == on2, f"modo UART deberia ser simetrico: rama 1 {on1}, rama 2 {on2}"
