# SPDX-FileCopyrightText: © 2025 PUCV
# SPDX-License-Identifier: Apache-2.0
#
# Pruebas del modulador PS-PWM en 1x1.
# Modulos originales de Nicolas Villegas (LushayLabs-TangNano20K, 3LFCC).
#
# Convenios:
#   ui[0]    UART RX, en reposo a 1
#   ui[2:1]  modo: 00 = UART, 01 = paralelo, 10 y 11 = mixtos
#   uio[6:0] duty paralelo (entradas)

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

CLK_NS = 37                # 27 MHz
CARRIER = 254              # periodo de la portadora, en ciclos
BAUD = 234                 # 27e6 / 115200
DEAD_TIME = 5              # ciclos de retardo en el flanco de encendido


def ui(modo=0, rx=1):
    return (rx & 1) | ((modo & 3) << 1)


async def arrancar(dut, modo=0, duty_par=0):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = ui(modo)
    dut.uio_in.value = duty_par & 0x7F
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)


async def soltar_reset(dut):
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)


async def enviar_uart(dut, ch, modo=0):
    """Manda un caracter a 115200 8N1 por ui[0]."""
    bits = [0] + [(ord(ch) >> i) & 1 for i in range(8)] + [1]
    for b in bits:
        dut.ui_in.value = ui(modo, b)
        await ClockCycles(dut.clk, BAUD)
    dut.ui_in.value = ui(modo, 1)


# ---------------------------------------------------------------------------
# 1. Estado seguro con reset activo
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_estado_seguro(dut):
    """Con rst_n en bajo las cuatro llaves quedan apagadas."""
    await arrancar(dut)

    uo = int(dut.uo_out.value)
    assert (uo >> 0) & 1 == 1, "PMOS1 deberia estar apagado (uo[0] = 1)"
    assert (uo >> 1) & 1 == 1, "PMOS2 deberia estar apagado (uo[1] = 1)"
    assert (uo >> 2) & 1 == 0, "NMOS1 deberia estar apagado (uo[2] = 0)"
    assert (uo >> 3) & 1 == 0, "NMOS2 deberia estar apagado (uo[3] = 0)"

    # el banco bidireccional es todo entrada
    assert int(dut.uio_oe.value) == 0, "uio deberia ser entrada completa"


# ---------------------------------------------------------------------------
# 2. SEGURIDAD: nunca conduccion cruzada
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_sin_conduccion_cruzada(dut):
    """PMOS y NMOS de la misma rama nunca conducen a la vez.

    Rama 1: PMOS1 = uo[0] (activo a bajo), NMOS2 = uo[3] (activo a alto).
    Rama 2: PMOS2 = uo[1] (activo a bajo), NMOS1 = uo[2] (activo a alto).
    Si esto falla, la etapa de potencia se destruye.
    """
    await arrancar(dut, modo=1, duty_par=64)     # duty al 50 %, por pines
    await soltar_reset(dut)

    for c in range(6 * CARRIER):
        await ClockCycles(dut.clk, 1)
        uo = int(dut.uo_out.value)
        pmos1, pmos2 = (uo >> 0) & 1, (uo >> 1) & 1
        nmos1, nmos2 = (uo >> 2) & 1, (uo >> 3) & 1
        assert not (pmos1 == 0 and nmos2 == 1), f"conduccion cruzada rama 1, ciclo {c}"
        assert not (pmos2 == 0 and nmos1 == 1), f"conduccion cruzada rama 2, ciclo {c}"


# ---------------------------------------------------------------------------
# 3. La portadora corre a la frecuencia correcta
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_frecuencia_portadora(dut):
    """El disparo de fin de rampa sale dos veces por periodo (cada 127 ciclos)."""
    await arrancar(dut, modo=1, duty_par=64)
    await soltar_reset(dut)
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
    periodos = [b - a for a, b in zip(flancos, flancos[1:])]
    for p in periodos:
        assert abs(p - CARRIER // 2) <= 2, \
            f"separacion entre disparos {p}, se esperaba ~{CARRIER // 2}"


# ---------------------------------------------------------------------------
# 4. El tiempo muerto existe y se mide
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_tiempo_muerto(dut):
    """Entre apagar una llave y encender su complementaria hay hueco."""
    await arrancar(dut, modo=1, duty_par=64)
    await soltar_reset(dut)
    await ClockCycles(dut.clk, 50)

    # rama 1: se busca el flanco en que NMOS2 se apaga y se cuenta hasta que
    # PMOS1 enciende (uo[0] pasa a 0)
    prev_n = (int(dut.uo_out.value) >> 3) & 1
    hueco = None
    espera = 0
    for _ in range(4 * CARRIER):
        await ClockCycles(dut.clk, 1)
        uo = int(dut.uo_out.value)
        n2 = (uo >> 3) & 1
        p1_on = ((uo >> 0) & 1) == 0
        if espera:
            espera += 1
            if p1_on:
                hueco = espera
                break
        elif prev_n == 1 and n2 == 0:
            espera = 1
        prev_n = n2

    assert hueco is not None, "no se observo la transicion en la rama 1"
    assert hueco >= DEAD_TIME, f"tiempo muerto de {hueco} ciclos, se esperaba >= {DEAD_TIME}"


# ---------------------------------------------------------------------------
# 5. El duty paralelo cambia el ancho de pulso
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_duty_paralelo(dut):
    """A mas duty, mas tiempo encendido el PMOS1."""
    async def medir(valor):
        await arrancar(dut, modo=1, duty_par=valor)
        await soltar_reset(dut)
        await ClockCycles(dut.clk, 2 * CARRIER)      # que se cargue el duty
        encendido = 0
        for _ in range(2 * CARRIER):
            await ClockCycles(dut.clk, 1)
            if ((int(dut.uo_out.value) >> 0) & 1) == 0:
                encendido += 1
        return encendido

    bajo = await medir(20)
    alto = await medir(100)

    assert alto > bajo, f"el duty no responde: {bajo} con 20, {alto} con 100"
    dut._log.info(f"PMOS1 encendido: {bajo} ciclos con duty 20, {alto} con duty 100")


# ---------------------------------------------------------------------------
# 6. El UART fija el duty
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_duty_por_uart(dut):
    """Mandar '9' por UART deja mas duty que mandar '1'."""
    async def medir(ch):
        await arrancar(dut, modo=0)
        await soltar_reset(dut)
        await enviar_uart(dut, ch)
        await ClockCycles(dut.clk, 2 * CARRIER)
        encendido = 0
        for _ in range(2 * CARRIER):
            await ClockCycles(dut.clk, 1)
            if ((int(dut.uo_out.value) >> 0) & 1) == 0:
                encendido += 1
        return encendido

    bajo = await medir('1')
    alto = await medir('9')

    assert alto > bajo, f"el UART no mueve el duty: '1' dio {bajo}, '9' dio {alto}"
    dut._log.info(f"PMOS1 encendido: {bajo} ciclos con '1', {alto} con '9'")


# ---------------------------------------------------------------------------
# 7. Los dos modos mixtos desbalancean D1 y D2
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_modo_desbalance(dut):
    """En modo 10, D1 sale del UART y D2 de los pines, asi que las dos ramas
    conmutan con anchos distintos."""
    await arrancar(dut, modo=2, duty_par=110)
    await soltar_reset(dut)
    await enviar_uart(dut, '1', modo=2)          # duty bajo por UART
    await ClockCycles(dut.clk, 2 * CARRIER)

    on_rama1 = 0
    on_rama2 = 0
    for _ in range(2 * CARRIER):
        await ClockCycles(dut.clk, 1)
        uo = int(dut.uo_out.value)
        if ((uo >> 0) & 1) == 0: on_rama1 += 1     # PMOS1
        if ((uo >> 1) & 1) == 0: on_rama2 += 1     # PMOS2

    assert on_rama1 != on_rama2, \
        f"las dos ramas conmutan igual ({on_rama1} y {on_rama2}), no hay desbalance"
    dut._log.info(f"rama 1: {on_rama1} ciclos, rama 2: {on_rama2} ciclos")


# ---------------------------------------------------------------------------
# 8. Los bidireccionales quedan en entrada
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_uio_entrada(dut):
    """uio se usa solo como entrada del duty paralelo."""
    await arrancar(dut, modo=1, duty_par=64)
    await soltar_reset(dut)

    for _ in range(500):
        await ClockCycles(dut.clk, 1)
        assert int(dut.uio_oe.value) == 0, "uio no deberia conducir nunca"
        assert int(dut.uio_out.value) == 0, "uio_out deberia estar a 0"
