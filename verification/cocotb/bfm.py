"""Reusable AXI4-Lite / AXI4-Stream bus-functional models for the accel_ref_model DUT,
built against HW_SW_Interface_v1.1_FINAL.md §6 (stream packing) and §8 (register map).
"""
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ReadOnly, SimTimeoutError, with_timeout

# Bus-level watchdog: no single AXI-Lite beat or AXI4-Stream beat should legitimately take
# this long. Without it, a stuck TREADY/BVALID/RVALID spins the Python polling loop (and the
# host CPU) forever with zero diagnostic output instead of failing fast.
BUS_TIMEOUT_NS = 2000

# ---- Register offsets (accel_regs.h / §8.2) ----
OFF_CONTROL = 0x00
OFF_STATUS = 0x04
OFF_OPERATION = 0x08
OFF_INPUT_HEIGHT = 0x0C
OFF_INPUT_WIDTH = 0x10
OFF_IN_CHANNELS = 0x14
OFF_OUT_CHANNELS = 0x18
OFF_CONV_CONFIG = 0x1C
OFF_OUTPUT_SCALE = 0x20
OFF_INPUT_BYTES = 0x24
OFF_WEIGHT_BYTES = 0x28
OFF_BIAS_BYTES = 0x2C
OFF_SKIP_BYTES = 0x30
OFF_OUTPUT_BYTES = 0x34
OFF_CYCLE_COUNT = 0x38
OFF_ERROR_CODE = 0x3C
OFF_VERSION = 0x40
OFF_DEBUG_STATE = 0x44

CONTROL_START = 1 << 0
CONTROL_ABORT = 1 << 1

STATUS_IDLE = 1 << 0
STATUS_BUSY = 1 << 1
STATUS_DONE = 1 << 2
STATUS_ERROR = 1 << 3

ERR_NONE = 0
ERR_START_WHILE_BUSY = 1
ERR_INVALID_OPERATION = 2
ERR_INVALID_CONFIG = 3
ERR_PACKET_LENGTH = 4
ERR_TLAST_POSITION = 5
ERR_ACC_OVERFLOW = 6
ERR_ABORTED = 7
ERR_CONFIG_WRITE_BUSY = 8
ERR_INTERNAL = 9
ERR_INVALID_ADDRESS = 10

VERSION_EXPECTED = 0x0001_0001

FSM_RESET = 0
FSM_IDLE = 1
FSM_LOAD_WEIGHT = 2
FSM_LOAD_BIAS = 3
FSM_LOAD_INPUT = 4
FSM_COMPUTE = 5
FSM_SEND_OUTPUT = 6
FSM_COMPLETE = 7


def pack_conv_config(kernel, stride, padding, relu_enable):
    return (kernel & 0xFF) | ((stride & 0xFF) << 8) | ((padding & 0xFF) << 16) | ((1 if relu_enable else 0) << 24)


def pack_output_scale(multiplier_m, shift_n):
    return (multiplier_m & 0xFFFF) | ((shift_n & 0xFFFF) << 16)


def clk_signal(dut):
    """accel_ref_model names its clock port clk; the real RTL (resnet_accel_top) names it aclk."""
    aclk = getattr(dut, "aclk", None)
    return aclk if aclk is not None else dut.clk


def start_clock(dut, period_ns=10):
    cocotb.start_soon(Clock(clk_signal(dut), period_ns, units="ns").start())


async def reset_dut(dut, cycles=5):
    clk = clk_signal(dut)
    dut.aresetn.value = 0
    dut.s_axi_awaddr.value = 0
    dut.s_axi_awvalid.value = 0
    dut.s_axi_wdata.value = 0
    dut.s_axi_wstrb.value = 0
    dut.s_axi_wvalid.value = 0
    dut.s_axi_bready.value = 1
    dut.s_axi_araddr.value = 0
    dut.s_axi_arvalid.value = 0
    dut.s_axi_rready.value = 1
    dut.s_axis_tdata.value = 0
    dut.s_axis_tkeep.value = 0
    dut.s_axis_tlast.value = 0
    dut.s_axis_tvalid.value = 0
    dut.m_axis_tready.value = 0
    for _ in range(cycles):
        await RisingEdge(clk)
    dut.aresetn.value = 1
    await RisingEdge(clk)


class AxiLite:
    """Register-level driver. Holds AW/W (or AR) asserted until B (or R) completes,
    which sidesteps having to reason about the DUT's internal AWREADY/ARREADY pulse
    timing -- robust regardless of exactly how many cycles the slave takes.

    Each poll iteration crosses a *fresh* RisingEdge before sampling via ReadOnly().
    Sampling with ReadOnly() first (no preceding RisingEdge inside this call) would
    reuse whatever the simulator's ReadOnly phase last settled to -- which, called
    right after a previous transaction's trailing RisingEdge, is that same stale
    edge's state (e.g. the previous transaction's still-asserted BVALID), causing
    this transaction to appear to complete one cycle too early using the wrong
    (previous) latched address.

    Signals can't be driven while still inside ReadOnly (cocotb raises, and ReadWrite
    can't be reached directly from ReadOnly either -- only a new timestep can), so every
    loop below crosses a FallingEdge (a safe, conventional mid-cycle point, well before
    the next sampling RisingEdge) before its first post-loop `.value = ...`.
    """

    def __init__(self, dut):
        self.dut = dut

    async def write(self, addr, data):
        dut = self.dut
        clk = clk_signal(dut)
        dut.s_axi_awaddr.value = addr
        dut.s_axi_awvalid.value = 1
        dut.s_axi_wdata.value = data & 0xFFFFFFFF
        dut.s_axi_wstrb.value = 0xF
        dut.s_axi_wvalid.value = 1

        async def _poll():
            done = False
            while not done:
                await RisingEdge(clk)
                await ReadOnly()
                done = dut.s_axi_bvalid.value == 1

        try:
            await with_timeout(_poll(), BUS_TIMEOUT_NS, "ns")
        except SimTimeoutError:
            raise SimTimeoutError(f"AXI-Lite write(addr=0x{addr:x}) never saw BVALID") from None
        await FallingEdge(clk)
        dut.s_axi_awvalid.value = 0
        dut.s_axi_wvalid.value = 0

    async def read(self, addr):
        dut = self.dut
        clk = clk_signal(dut)
        dut.s_axi_araddr.value = addr
        dut.s_axi_arvalid.value = 1
        result = {}

        async def _poll():
            done = False
            while not done:
                await RisingEdge(clk)
                await ReadOnly()
                done = dut.s_axi_rvalid.value == 1
                if done:
                    result["data"] = int(dut.s_axi_rdata.value)

        try:
            await with_timeout(_poll(), BUS_TIMEOUT_NS, "ns")
        except SimTimeoutError:
            raise SimTimeoutError(f"AXI-Lite read(addr=0x{addr:x}) never saw RVALID") from None
        await FallingEdge(clk)
        dut.s_axi_arvalid.value = 0
        return result["data"]

    async def status(self):
        return await self.read(OFF_STATUS)

    async def error_code(self):
        return await self.read(OFF_ERROR_CODE)

    async def debug_state(self):
        return await self.read(OFF_DEBUG_STATE)

    async def start(self):
        await self.write(OFF_CONTROL, CONTROL_START)

    async def abort(self):
        await self.write(OFF_CONTROL, CONTROL_ABORT)

    async def clear_done_and_error(self):
        await self.write(OFF_STATUS, STATUS_DONE | STATUS_ERROR)

    async def wait_admitted(self, timeout_ns=5000):
        """Mirrors firmware's accel_wait_start_admitted() (§11.1 steps 7-9, §11.2): polls
        until BUSY=1 (accepted) or ERROR=1 (rejected), rather than checking STATUS once
        immediately after start() -- admission validation and the ERROR sticky bit both
        take a variable/nonzero number of cycles to settle after the triggering write."""
        async def _poll():
            while True:
                status = await self.status()
                if status & (STATUS_BUSY | STATUS_ERROR):
                    return status
        return await with_timeout(_poll(), timeout_ns, "ns")


async def axis_send(dut, prefix, payload: bytes, assert_final_tlast: bool = True):
    """Drives one AXI4-Stream packet (§6: 4 bytes/beat, TKEEP=1111, TLAST on final beat).

    Samples TVALID/TREADY via ReadOnly() *before* crossing the RisingEdge that would
    register the transfer -- not after. Checking after is broken whenever the very
    transfer being checked also causes a same-cycle TREADY drop (e.g. the last INPUT
    beat: LOAD_INPUT -> COMPUTE both happen at that edge, so TREADY reads 0 immediately
    after it, even though the transfer *did* happen at that edge). Sampling before the
    edge instead reads the same pre-transition values the DUT's own sequential logic
    used to decide acceptance, so it can't be fooled by the state it's about to leave.
    Each retry naturally lands back on a fresh ReadOnly because the prior loop
    iteration's last trigger was a real RisingEdge, not a reused stale phase.

    `assert_final_tlast=False` sends `payload` as a genuinely incomplete packet (TLAST
    never asserted) -- for directed tests that need to abort or interrupt mid-stream
    without also triggering a (fatal) premature-TLAST/short-packet error first.
    """
    assert len(payload) % 4 == 0, "v1.0 packets are always 4-byte multiples (§6.2)"
    clk = clk_signal(dut)
    tdata = getattr(dut, f"{prefix}_tdata")
    tkeep = getattr(dut, f"{prefix}_tkeep")
    tlast = getattr(dut, f"{prefix}_tlast")
    tvalid = getattr(dut, f"{prefix}_tvalid")
    tready = getattr(dut, f"{prefix}_tready")

    beats = [payload[i:i + 4] for i in range(0, len(payload), 4)]
    for idx, beat in enumerate(beats):
        tdata.value = int.from_bytes(beat, "little")
        tkeep.value = 0xF
        tlast.value = 1 if (assert_final_tlast and idx == len(beats) - 1) else 0
        tvalid.value = 1

        async def _poll():
            accepted = False
            while not accepted:
                await ReadOnly()
                accepted = (tvalid.value == 1) and (tready.value == 1)
                await RisingEdge(clk)

        try:
            await with_timeout(_poll(), BUS_TIMEOUT_NS, "ns")
        except SimTimeoutError:
            raise SimTimeoutError(
                f"axis_send({prefix}) beat {idx}/{len(beats)} never saw TREADY"
            ) from None
    tvalid.value = 0
    tlast.value = 0


async def axis_recv(dut, prefix, nbytes, stall_prob=0.0):
    """Receives one AXI4-Stream packet, driving TREADY (optionally with random stalls).
    Returns the received bytes and asserts TLAST fell exactly on the last beat.

    Same pre-edge sampling requirement as axis_send: the last OUTPUT beat's SEND_OUTPUT
    -> COMPLETE transition drops TVALID at the very edge that beat is transferred, so
    TVALID/TDATA/TLAST must be read via ReadOnly() before that edge, not after.
    """
    clk = clk_signal(dut)
    tdata = getattr(dut, f"{prefix}_tdata")
    tlast = getattr(dut, f"{prefix}_tlast")
    tvalid = getattr(dut, f"{prefix}_tvalid")
    tready = getattr(dut, f"{prefix}_tready")

    data = bytearray()
    beats_expected = nbytes // 4
    while len(data) < nbytes:
        tready.value = 0 if random.random() < stall_prob else 1
        await ReadOnly()
        transfer = (tvalid.value == 1) and (tready.value == 1)
        if transfer:
            beat_bytes = int(tdata.value).to_bytes(4, "little")
            is_last = (tlast.value == 1)
        await RisingEdge(clk)
        if transfer:
            data += beat_bytes
            beat_idx = len(data) // 4
            if beat_idx == beats_expected:
                assert is_last, f"TLAST missing on final beat ({beat_idx}/{beats_expected})"
            else:
                assert not is_last, f"unexpected TLAST on beat {beat_idx}/{beats_expected}"
    tready.value = 0
    return bytes(data)
