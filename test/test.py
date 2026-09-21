# SPDX-FileCopyrightText: © 2026 PUCV
# SPDX-License-Identifier: Apache-2.0
#
# Pruebas del modulador PS-PWM en 1x1.
# Modulador original de Nicolas Villegas (LushayLabs-TangNano20K, 3LFCC).
#
# Convenios:
#   ui[6:0]   D1, ciclo de trabajo de la rama 1
#   uio[6:0]  D2, ciclo de trabajo de la rama 2

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

CLK_NS = 37                # 27 MHz
CARRIER = 254              # periodo de la portadora, en ciclos
DEAD_TIME = 5              # ciclos de retardo en el flanco de encendido


async def arrancar(dut, d1=0, d2=0):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = d1 & 0x7F
    dut.uio_in.value = d2 & 0x7F
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)


async def soltar_reset(dut):
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)


async def medir_encendido(dut, bit, ciclos):
    """Cuenta los ciclos en que un PMOS (activo a bajo) esta conduciendo."""
    n = 0
    for _ in range(ciclos):
        await ClockCycles(dut.clk, 1)
        if ((int(dut.uo_out.value) >> bit) & 1) == 0:
            n += 1
    return n


# ---------------------------------------------------------------------------
# 1. Estado seguro con reset activo
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_estado_seguro(dut):
    """Con rst_n en bajo las cuatro llaves quedan apagadas."""
    await arrancar(dut, d1=64, d2=64)

    uo = int(dut.uo_out.value)
    assert (uo >> 0) & 1 == 1, "PMOS1 deberia estar apagado (uo[0] = 1)"
    assert (uo >> 1) & 1 == 1, "PMOS2 deberia estar apagado (uo[1] = 1)"
    assert (uo >> 2) & 1 == 0, "NMOS1 deberia estar apagado (uo[2] = 0)"
    assert (uo >> 3) & 1 == 0, "NMOS2 deberia estar apagado (uo[3] = 0)"
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
    for d1, d2 in [(64, 64), (10, 120), (120, 10), (1, 126)]:
        await arrancar(dut, d1=d1, d2=d2)
        await soltar_reset(dut)
        for c in range(3 * CARRIER):
            await ClockCycles(dut.clk, 1)
            uo = int(dut.uo_out.value)
            pmos1, pmos2 = (uo >> 0) & 1, (uo >> 1) & 1
            nmos1, nmos2 = (uo >> 2) & 1, (uo >> 3) & 1
            assert not (pmos1 == 0 and nmos2 == 1), \
                f"conduccion cruzada rama 1, D1={d1} D2={d2}, ciclo {c}"
            assert not (pmos2 == 0 and nmos1 == 1), \
                f"conduccion cruzada rama 2, D1={d1} D2={d2}, ciclo {c}"


# ---------------------------------------------------------------------------
# 3. La portadora corre a la frecuencia correcta
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_frecuencia_portadora(dut):
    """El disparo de fin de rampa sale dos veces por periodo (cada 127 ciclos)."""
    await arrancar(dut, d1=64, d2=64)
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
    for p in [b - a for a, b in zip(flancos, flancos[1:])]:
        assert abs(p - CARRIER // 2) <= 2, \
            f"separacion entre disparos {p}, se esperaba ~{CARRIER // 2}"


# ---------------------------------------------------------------------------
# 4. El tiempo muerto existe y se mide
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_tiempo_muerto(dut):
    """Entre apagar el NMOS2 y encender el PMOS1 hay al menos 5 ciclos."""
    await arrancar(dut, d1=64, d2=64)
    await soltar_reset(dut)
    await ClockCycles(dut.clk, 50)

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
# 5. D1 controla el ancho de pulso de la rama 1
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_d1_controla_rama1(dut):
    """A mas D1, mas tiempo encendido el PMOS1."""
    async def medir(d1):
        await arrancar(dut, d1=d1, d2=64)
        await soltar_reset(dut)
        await ClockCycles(dut.clk, CARRIER)
        return await medir_encendido(dut, 0, 2 * CARRIER)

    bajo = await medir(20)
    alto = await medir(100)
    assert alto > bajo, f"D1 no responde: {bajo} con 20, {alto} con 100"
    dut._log.info(f"PMOS1 encendido: {bajo} ciclos con D1=20, {alto} con D1=100")


# ---------------------------------------------------------------------------
# 6. D2 controla el ancho de pulso de la rama 2, independiente de D1
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_d2_controla_rama2(dut):
    """A mas D2, mas tiempo encendido el PMOS2, con D1 fijo."""
    async def medir(d2):
        await arrancar(dut, d1=64, d2=d2)
        await soltar_reset(dut)
        await ClockCycles(dut.clk, CARRIER)
        return await medir_encendido(dut, 1, 2 * CARRIER)

    bajo = await medir(20)
    alto = await medir(100)
    assert alto > bajo, f"D2 no responde: {bajo} con 20, {alto} con 100"
    dut._log.info(f"PMOS2 encendido: {bajo} ciclos con D2=20, {alto} con D2=100")


# ---------------------------------------------------------------------------
# 7. Las dos ramas se pueden desbalancear
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_desbalance(dut):
    """Con D1 distinto de D2, las dos ramas conmutan con anchos distintos."""
    await arrancar(dut, d1=20, d2=110)
    await soltar_reset(dut)
    await ClockCycles(dut.clk, CARRIER)

    on1 = on2 = 0
    for _ in range(2 * CARRIER):
        await ClockCycles(dut.clk, 1)
        uo = int(dut.uo_out.value)
        if ((uo >> 0) & 1) == 0: on1 += 1
        if ((uo >> 1) & 1) == 0: on2 += 1

    assert on2 > on1, f"rama 2 ({on2}) deberia conducir mas que rama 1 ({on1})"
    dut._log.info(f"rama 1: {on1} ciclos, rama 2: {on2} ciclos")


# ---------------------------------------------------------------------------
# 8. Pines sin uso
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_pines_sin_uso(dut):
    """uio queda en entrada y uo[7:5] a cero."""
    await arrancar(dut, d1=64, d2=64)
    await soltar_reset(dut)

    for _ in range(500):
        await ClockCycles(dut.clk, 1)
        assert int(dut.uio_oe.value) == 0, "uio no deberia conducir nunca"
        assert int(dut.uio_out.value) == 0, "uio_out deberia estar a 0"
        assert (int(dut.uo_out.value) >> 5) == 0, "uo[7:5] deberian estar a 0"
