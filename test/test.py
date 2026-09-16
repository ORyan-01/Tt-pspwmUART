# SPDX-FileCopyrightText: © 2025 PUCV
# SPDX-License-Identifier: Apache-2.0
#
# Tests del port a Tiny Tapeout del controlador 3LFCC.
#
# Los pull-ups externos de los buses I2C se modelan poniendo uio_in[1:0] = 1.
# ui_in[0] (UART RX) se deja en 1 = linea en reposo.
# ui_in[1] (SCL_OD) en 0 = SCL push-pull, identico a la FPGA.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

UI_IDLE = 0b00000001      # UART RX en reposo (1), SCL_OD = 0
UIO_PULLUPS = 0b00000011  # SDA1 y SDA2 en alto por pull-up


async def reset_dut(dut):
    dut.ena.value = 1
    dut.ui_in.value = UI_IDLE
    dut.uio_in.value = UIO_PULLUPS
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)


@cocotb.test()
async def test_reset_safe_state(dut):
    """Con reset activo el puente queda en el estado seguro del diseno original."""
    cocotb.start_soon(Clock(dut.clk, 37, unit="ns").start())   # 27 MHz
    await reset_dut(dut)

    # ps_pwm fuerza PWM0=1, PWM1=1, PWM2=0, PWM3=0 mientras rst_n = 0.
    # PWM4 = 1 fijo, PWM5 = heartbeat (arranca en 1), PWM6 = PWM7 = 0.
    assert int(dut.uo_out.value) == 0b00110011, \
        f"estado seguro incorrecto: {dut.uo_out.value}"

    # SDA nunca se conduce en reset; SCL y el bus del OLED si son salidas.
    assert int(dut.uio_oe.value) == 0b11111100, \
        f"uio_oe incorrecto en reset: {dut.uio_oe.value}"


@cocotb.test()
async def test_open_drain_sda(dut):
    """SDA jamas fuerza un 1: solo tira a 0 o queda en alta impedancia."""
    cocotb.start_soon(Clock(dut.clk, 37, unit="ns").start())
    await reset_dut(dut)
    dut.rst_n.value = 1

    for _ in range(2000):
        await ClockCycles(dut.clk, 1)
        uio_out = int(dut.uio_out.value)
        assert (uio_out & 0b11) == 0, \
            "SDA esta forzando un 1: rompe el open drain del bus I2C"


@cocotb.test()
async def test_i2c_activity(dut):
    """Tras el reset arranca la secuencia I2C: SCL conmuta y SDA se tira a 0."""
    cocotb.start_soon(Clock(dut.clk, 37, unit="ns").start())
    await reset_dut(dut)
    dut.rst_n.value = 1

    scl_seen_low = False
    scl_seen_high = False
    sda1_driven = False
    sda2_driven = False

    for _ in range(3000):
        await ClockCycles(dut.clk, 1)
        uio_out = int(dut.uio_out.value)
        uio_oe = int(dut.uio_oe.value)

        if (uio_out >> 2) & 1:
            scl_seen_high = True
        else:
            scl_seen_low = True

        if uio_oe & 0b01:
            sda1_driven = True
        if uio_oe & 0b10:
            sda2_driven = True

    assert scl_seen_low and scl_seen_high, "SCL no esta conmutando"
    assert sda1_driven, "el maestro I2C 1 nunca tiro SDA1 a 0"
    assert sda2_driven, "el maestro I2C 2 nunca tiro SDA2 a 0"


@cocotb.test()
async def test_static_pwm_pins(dut):
    """PWM4/6/7 conservan los valores fijos del diseno original."""
    cocotb.start_soon(Clock(dut.clk, 37, unit="ns").start())
    await reset_dut(dut)
    dut.rst_n.value = 1

    for _ in range(1000):
        await ClockCycles(dut.clk, 1)
        uo = int(dut.uo_out.value)
        assert (uo >> 4) & 1 == 1, "PWM4 deberia estar fijo a 1"
        assert (uo >> 6) & 1 == 0, "PWM6 deberia estar fijo a 0"
        assert (uo >> 7) & 1 == 0, "PWM7 deberia estar fijo a 0"


@cocotb.test()
async def test_oled_bus_active(dut):
    """El OLED mantiene RES en alto durante el arranque y CS/SCLK son salidas."""
    cocotb.start_soon(Clock(dut.clk, 37, unit="ns").start())
    await reset_dut(dut)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 100)

    # STARTUP_WAIT = 10e6 ciclos: durante todo el test seguimos en la primera
    # fase de la secuencia de reset del panel, con RES en alto.
    assert (int(dut.uio_out.value) >> 7) & 1 == 1, "OLED RES deberia estar en alto"
    assert (int(dut.uio_oe.value) >> 3) & 0b11111 == 0b11111, \
        "los 5 pines del OLED deben ser salidas"
