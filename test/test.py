# SPDX-FileCopyrightText: © 2025 PUCV
# SPDX-License-Identifier: Apache-2.0
#
# Banco de pruebas del port a Tiny Tapeout del controlador 3LFCC.
# Original FPGA: github.com/nic0villegasc/LushayLabs-TangNano20K (carpeta 3LFCC)
#
# Convenios del banco:
#   ui_in[0] = UART RX, en reposo a 1
#   ui_in[1] = SCL_OD  = 0  -> SCL push-pull, igual que en la Tang Nano
#   uio_in[1:0] = 1 -> modela los pull-ups externos de SDA1 y SDA2
#
# Los maestros I2C de este diseno NO comprueban el ACK ni hacen clock
# stretching, asi que el monitor de bus es pasivo: decodifica la trama sin
# necesidad de un esclavo que responda.  Las lecturas devuelven 0xFF porque
# no hay ningun ADS1115 conectado, que es justo lo que debe pasar.

from collections import Counter

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

CLK_NS = 37                    # 27 MHz
UI_IDLE = 0b00000001           # UART en reposo, SCL push-pull
UIO_PULLUPS = 0b00000011       # pull-ups en SDA1 y SDA2

I2C_ADDR = 0x49
ADDR_W = (I2C_ADDR << 1) | 0   # 0x92
ADDR_R = (I2C_ADDR << 1) | 1   # 0x93
CONFIG_REG = 0x01
CONV_REG = 0x00

# setupRegister = {1, MUX, 3'b001, 0, 3'b111, 0,0,0, 2'b11}
SETUP_CH1 = (0x82, 0xE3)       # MUX = 000 (diferencial, flying cap)
SETUP_CH2 = (0xC2, 0xE3)       # MUX = 100 (single ended, Vout)

BIT_CYCLES = 128               # periodo de bit I2C = 27 MHz / 128 = 211 kHz
CARRIER_CYCLES = 254           # portadora triangular de 7 bits, ida y vuelta


# ---------------------------------------------------------------------------
# utilidades
# ---------------------------------------------------------------------------
def rd(sig):
    """Lee una senal; devuelve None si tiene X o Z (util en gate level)."""
    try:
        return int(sig.value)
    except ValueError:
        return None


async def start_dut(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = UI_IDLE
    dut.uio_in.value = UIO_PULLUPS
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)


async def release_reset(dut):
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


class I2CMonitor:
    """Decodifica una linea SDA contra el SCL comun. Pasivo, no responde."""

    def __init__(self, name):
        self.name = name
        self.active = False
        self.bit = 0
        self.shift = 0
        self.cur = []
        self.frames = []
        self.rise_cycles = []      # ciclo de cada flanco de subida de SCL

    def step(self, cycle, scl, sda, prev_scl, prev_sda):
        # START / STOP: SDA cambia mientras SCL esta alto
        if scl == 1 and prev_scl == 1:
            if prev_sda == 1 and sda == 0:
                self.active = True
                self.bit = 0
                self.shift = 0
                self.cur = []
                return
            if prev_sda == 0 and sda == 1 and self.active:
                self.active = False
                if self.cur:
                    self.frames.append(self.cur)
                self.cur = []
                return

        if not self.active:
            return

        if prev_scl == 0 and scl == 1:        # flanco de subida: dato valido
            self.rise_cycles.append(cycle)
            if self.bit < 8:
                self.shift = ((self.shift << 1) | sda) & 0xFF
                self.bit += 1
                if self.bit == 8:
                    self.cur.append(self.shift)
            else:                              # noveno bit = ACK, se ignora
                self.bit = 0
                self.shift = 0


async def run_i2c(dut, cycles):
    """Hace correr el chip y decodifica los dos buses I2C."""
    m1 = I2CMonitor("SDA1")
    m2 = I2CMonitor("SDA2")
    prev_scl, prev_s1, prev_s2 = 1, 1, 1
    unresolved = 0

    for c in range(cycles):
        await ClockCycles(dut.clk, 1)
        uo = rd(dut.uio_out)
        oe = rd(dut.uio_oe)
        if uo is None or oe is None:
            unresolved += 1
            continue

        scl = (uo >> 2) & 1                    # push-pull: uio_oe[2] = 1
        # open drain: la linea vale 0 solo si el maestro habilita la salida
        s1 = 0 if (oe & 0b01) else 1
        s2 = 0 if (oe & 0b10) else 1

        m1.step(c, scl, s1, prev_scl, prev_s1)
        m2.step(c, scl, s2, prev_scl, prev_s2)
        prev_scl, prev_s1, prev_s2 = scl, s1, s2

    return m1, m2, unresolved


# ---------------------------------------------------------------------------
# 1. Estado seguro con reset activo
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_reset_safe_state(dut):
    """Con rst_n = 0 el puente queda apagado, igual que en la FPGA."""
    await start_dut(dut)

    # ps_pwm fuerza PWM0=1, PWM1=1 (PMOS apagados, puerta activa a bajo)
    # y PWM2=0, PWM3=0 (NMOS apagados).
    # PWM4 = 1 fijo, PWM5 = heartbeat (arranca en 1), PWM6 = PWM7 = 0.
    assert int(dut.uo_out.value) == 0b00110011, \
        f"estado seguro incorrecto: {dut.uo_out.value}"

    # SDA no se conduce; SCL y el bus del OLED si son salidas.
    assert int(dut.uio_oe.value) == 0b11111100, \
        f"uio_oe incorrecto en reset: {dut.uio_oe.value}"


# ---------------------------------------------------------------------------
# 2. Pines PWM fijos
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_static_pwm_pins(dut):
    """PWM4/6/7 conservan los valores fijos del diseno original."""
    await start_dut(dut)
    await release_reset(dut)

    for _ in range(1000):
        await ClockCycles(dut.clk, 1)
        uo = int(dut.uo_out.value)
        assert (uo >> 4) & 1 == 1, "PWM4 deberia estar fijo a 1"
        assert (uo >> 6) & 1 == 0, "PWM6 deberia estar fijo a 0"
        assert (uo >> 7) & 1 == 0, "PWM7 deberia estar fijo a 0"


# ---------------------------------------------------------------------------
# 3. Invariante de open drain
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_open_drain_sda(dut):
    """SDA jamas fuerza un 1: solo tira a 0 o queda en alta impedancia."""
    await start_dut(dut)
    await release_reset(dut)

    for _ in range(3000):
        await ClockCycles(dut.clk, 1)
        assert (int(dut.uio_out.value) & 0b11) == 0, \
            "SDA esta forzando un 1: rompe el open drain del bus I2C"


# ---------------------------------------------------------------------------
# 4. SEGURIDAD: nunca puede haber conduccion cruzada en una rama
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_no_shoot_through(dut):
    """PMOS y NMOS de la misma rama nunca conducen a la vez.

    Rama 1: PMOS1 = uo[0] (activo a bajo), NMOS2 = uo[3] (activo a alto).
    Rama 2: PMOS2 = uo[1] (activo a bajo), NMOS1 = uo[2] (activo a alto).
    Es la propiedad mas critica del chip: si falla, la etapa de potencia
    se destruye.
    """
    await start_dut(dut)
    await release_reset(dut)

    for c in range(4 * CARRIER_CYCLES):
        await ClockCycles(dut.clk, 1)
        uo = int(dut.uo_out.value)
        pmos1 = (uo >> 0) & 1
        pmos2 = (uo >> 1) & 1
        nmos1 = (uo >> 2) & 1
        nmos2 = (uo >> 3) & 1
        assert not (pmos1 == 0 and nmos2 == 1), \
            f"conduccion cruzada en la rama 1 en el ciclo {c}"
        assert not (pmos2 == 0 and nmos1 == 1), \
            f"conduccion cruzada en la rama 2 en el ciclo {c}"


# ---------------------------------------------------------------------------
# 5. La portadora triangular corre a la frecuencia correcta
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_carrier_frequency(dut):
    """Los flancos de PWM3 marcan el periodo de la portadora (252 ciclos)."""
    await start_dut(dut)
    await release_reset(dut)
    await ClockCycles(dut.clk, 50)

    edges = []
    prev = (int(dut.uo_out.value) >> 3) & 1
    for c in range(4 * CARRIER_CYCLES):
        await ClockCycles(dut.clk, 1)
        cur = (int(dut.uo_out.value) >> 3) & 1
        if prev == 1 and cur == 0:
            edges.append(c)
        prev = cur

    assert len(edges) >= 2, "la portadora PWM no esta conmutando"
    periodos = [b - a for a, b in zip(edges, edges[1:])]
    for p in periodos:
        assert abs(p - CARRIER_CYCLES) <= 2, \
            f"periodo de portadora {p}, se esperaba ~{CARRIER_CYCLES}"


# ---------------------------------------------------------------------------
# 6. Secuencia I2C completa sobre el SCL compartido
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_i2c_config_sequence(dut):
    """Los dos ADS1115 se configuran correctamente con un unico SCL.

    Es la prueba que valida la decision de diseno del port: un solo pin SCL
    para los dos buses.  Si los dos maestros se desincronizaran, las tramas
    decodificadas no coincidirian en longitud ni en alineacion de bytes.
    """
    await start_dut(dut)
    await release_reset(dut)

    m1, m2, unresolved = await run_i2c(dut, 20000)

    assert unresolved == 0, \
        f"{unresolved} ciclos con valores no resolubles en uio"

    assert len(m1.frames) >= 2, f"solo {len(m1.frames)} tramas en SDA1"
    assert len(m2.frames) >= 2, f"solo {len(m2.frames)} tramas en SDA2"

    # --- trama 1: escritura del registro de configuracion ---
    esperado1 = [ADDR_W, CONFIG_REG, SETUP_CH1[0], SETUP_CH1[1]]
    esperado2 = [ADDR_W, CONFIG_REG, SETUP_CH2[0], SETUP_CH2[1]]
    assert m1.frames[0] == esperado1, \
        f"SDA1 config: {[hex(b) for b in m1.frames[0]]} != {[hex(b) for b in esperado1]}"
    assert m2.frames[0] == esperado2, \
        f"SDA2 config: {[hex(b) for b in m2.frames[0]]} != {[hex(b) for b in esperado2]}"

    # --- trama 2: puntero de vuelta al registro de conversion ---
    assert m1.frames[1] == [ADDR_W, CONV_REG], \
        f"SDA1 puntero: {[hex(b) for b in m1.frames[1]]}"
    assert m2.frames[1] == [ADDR_W, CONV_REG], \
        f"SDA2 puntero: {[hex(b) for b in m2.frames[1]]}"

    # --- lockstep: mismo numero de bytes por trama en los dos canales ---
    assert len(m1.frames) == len(m2.frames), \
        "los dos maestros I2C se han desincronizado (numero de tramas)"
    for i, (f1, f2) in enumerate(zip(m1.frames, m2.frames)):
        assert len(f1) == len(f2), \
            f"trama {i}: SDA1 tiene {len(f1)} bytes y SDA2 {len(f2)}"

    # --- los dos canales solo se diferencian en los bits de MUX ---
    dif = [i for i, (a, b) in enumerate(zip(m1.frames[0], m2.frames[0])) if a != b]
    assert dif == [2], f"los canales difieren en los bytes {dif}, solo deberia ser el MUX"

    # --- si hay lectura, la direccion lleva el bit R/W a 1 ---
    lecturas = [f for f in m1.frames if f and f[0] == ADDR_R]
    assert lecturas, "nunca se ejecuto una transaccion de lectura"

    dut._log.info(f"SDA1 tramas: {[[hex(b) for b in f] for f in m1.frames[:4]]}")
    dut._log.info(f"SDA2 tramas: {[[hex(b) for b in f] for f in m2.frames[:4]]}")


# ---------------------------------------------------------------------------
# 7. Periodo de bit del I2C
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_i2c_bit_period(dut):
    """SCL a 27 MHz / 128 = 211 kHz, dentro del fast mode del ADS1115."""
    await start_dut(dut)
    await release_reset(dut)

    m1, _, _ = await run_i2c(dut, 8000)

    assert len(m1.rise_cycles) >= 20, "muy pocos flancos de SCL para medir"
    # Dentro de un byte los flancos van justos a 128 ciclos.  Entre byte y byte
    # se cuelan unos pocos ciclos extra de la FSM del ADC, por eso se filtra.
    periodos = [b - a for a, b in zip(m1.rise_cycles, m1.rise_cycles[1:])
                if b - a < 200]
    assert len(periodos) >= 16, "no se pudo medir el periodo de bit"

    comun = Counter(periodos).most_common(1)[0][0]
    assert comun == BIT_CYCLES, \
        f"periodo de bit dominante {comun}, se esperaba {BIT_CYCLES}"
    # lo importante para el ADS1115: SCL nunca va mas rapido que 211 kHz
    assert min(periodos) >= BIT_CYCLES, \
        f"SCL demasiado rapido: periodo minimo {min(periodos)}"


# ---------------------------------------------------------------------------
# 8. El receptor UART acepta un byte sin perturbar nada
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_uart_byte(dut):
    """Se envia '5' a 115200 8N1 y el chip sigue en un estado valido."""
    await start_dut(dut)
    await release_reset(dut)
    await ClockCycles(dut.clk, 100)

    BAUD_CYCLES = 234              # 27e6 / 115200
    byte = ord('5')
    bits = [0] + [(byte >> i) & 1 for i in range(8)] + [1]   # start, LSB first, stop

    for b in bits:
        dut.ui_in.value = (b & 1) | 0b00000000      # ui_in[1] = 0 (SCL push-pull)
        for _ in range(BAUD_CYCLES):
            await ClockCycles(dut.clk, 1)
            uo = int(dut.uo_out.value)
            assert not (((uo >> 0) & 1) == 0 and ((uo >> 3) & 1) == 1), \
                "conduccion cruzada durante la recepcion UART"
            assert not (((uo >> 1) & 1) == 0 and ((uo >> 2) & 1) == 1), \
                "conduccion cruzada durante la recepcion UART"

    dut.ui_in.value = UI_IDLE
    await ClockCycles(dut.clk, 500)

    assert (int(dut.uo_out.value) >> 4) & 1 == 1, "PWM4 se movio tras el UART"
    assert int(dut.uio_oe.value) >> 3 == 0b11111, "el bus del OLED dejo de ser salida"


# ---------------------------------------------------------------------------
# 9. El OLED mantiene RES alto durante el arranque
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_oled_bus_active(dut):
    """STARTUP_WAIT = 10e6 ciclos: durante el test seguimos en la fase 1."""
    await start_dut(dut)
    await release_reset(dut)
    await ClockCycles(dut.clk, 100)

    assert (int(dut.uio_out.value) >> 7) & 1 == 1, "OLED RES deberia estar en alto"
    assert (int(dut.uio_oe.value) >> 3) & 0b11111 == 0b11111, \
        "los 5 pines del OLED deben ser salidas"
