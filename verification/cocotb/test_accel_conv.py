"""cocotb regression for accel_ref_model (HW_SW_Interface_v1.1_FINAL.md §15 checklist).

Run with:
    cd verification/cocotb && make

TOPLEVEL is the behavioral reference model (verification/rtl_ref/accel_ref_model.sv), not
황정민 학생's RTL -- swap the Makefile's VERILOG_SOURCES/TOPLEVEL once that lands in this
repo and re-run this same file as regression against it.
"""
import json
from pathlib import Path

import cocotb
from cocotb.triggers import RisingEdge, with_timeout

import bfm

REPO_ROOT = Path(__file__).resolve().parents[2]
STAGE1_DIR = REPO_ROOT / "data" / "test_vectors" / "stage1_conv"
STAGE1_AVAILABLE = STAGE1_DIR.exists()
_STAGE1_SKIP_REASON = f"{STAGE1_DIR} not found; run scripts/generate_stage1_vectors.py first"


async def _setup(dut):
    bfm.start_clock(dut)
    await bfm.reset_dut(dut)
    return bfm.AxiLite(dut)


def _require_alias(config, old, new):
    """Accepts either the firmware-side key (old) or the RTL-side key (new), not both --
    mirrors scripts/generate_stage1_c_header.py's require_alias() so this harness stays in
    sync regardless of which test-vector schema is currently checked into data/test_vectors/."""
    present = [key for key in (old, new) if key in config]
    if len(present) != 1:
        raise KeyError(f"expected exactly one of {old!r}, {new!r} in config.json, got {present}")
    return config[present[0]]


async def _load_stage1_config(regs, config):
    await regs.write(bfm.OFF_OPERATION, 0)  # OP_CONV
    await regs.write(bfm.OFF_INPUT_HEIGHT, config["input_height"])
    await regs.write(bfm.OFF_INPUT_WIDTH, config["input_width"])
    await regs.write(bfm.OFF_IN_CHANNELS, config["in_channels"])
    await regs.write(bfm.OFF_OUT_CHANNELS, config["out_channels"])
    await regs.write(bfm.OFF_CONV_CONFIG, bfm.pack_conv_config(
        config["kernel_size"], config["stride"], config["padding"], config["relu_enable"]))
    await regs.write(bfm.OFF_OUTPUT_SCALE, bfm.pack_output_scale(
        _require_alias(config, "multiplier_m", "multiplier"),
        _require_alias(config, "shift_n", "shift")))
    await regs.write(bfm.OFF_INPUT_BYTES, config["input_bytes"])
    await regs.write(bfm.OFF_WEIGHT_BYTES, config["weight_bytes"])
    await regs.write(bfm.OFF_BIAS_BYTES, config["bias_bytes"])
    await regs.write(bfm.OFF_SKIP_BYTES, 0)
    await regs.write(bfm.OFF_OUTPUT_BYTES, config["output_bytes"])


async def _run_stage1_conv(dut, regs, config, weight, bias, input_bytes):
    """Drives one full §11.1 execution sequence, returns the received output bytes."""
    await _load_stage1_config(regs, config)
    await regs.start()

    status = await regs.status()
    assert status & bfm.STATUS_BUSY, f"START not accepted, status=0x{status:x}"

    await bfm.axis_send(dut, "s_axis", weight)
    await bfm.axis_send(dut, "s_axis", bias)
    await bfm.axis_send(dut, "s_axis", input_bytes)

    output = await bfm.axis_recv(dut, "m_axis", config["output_bytes"])

    async def _wait_idle():
        while (await regs.status()) & bfm.STATUS_BUSY:
            await RisingEdge(dut.clk)

    await with_timeout(_wait_idle(), 10000, "ns")
    return output


@cocotb.test()
async def test_reset_and_version(dut):
    """§15.2: reset value, VERSION, IDLE after reset."""
    regs = await _setup(dut)
    status = await regs.status()
    assert status == bfm.STATUS_IDLE, f"expected IDLE-only after reset, got 0x{status:x}"
    version = await regs.read(bfm.OFF_VERSION)
    assert version == bfm.VERSION_EXPECTED, f"VERSION=0x{version:x}, expected 0x{bfm.VERSION_EXPECTED:x}"
    debug_state = await regs.debug_state()
    assert debug_state == bfm.FSM_IDLE, f"DEBUG_STATE={debug_state}, expected IDLE"


@cocotb.test()
async def test_register_write_read(dut):
    """§15.2: register write/read round-trip while not BUSY."""
    regs = await _setup(dut)
    await regs.write(bfm.OFF_INPUT_HEIGHT, 32)
    await regs.write(bfm.OFF_INPUT_WIDTH, 32)
    await regs.write(bfm.OFF_CONV_CONFIG, bfm.pack_conv_config(3, 1, 1, True))
    await regs.write(bfm.OFF_OUTPUT_SCALE, bfm.pack_output_scale(44077, 24))

    assert await regs.read(bfm.OFF_INPUT_HEIGHT) == 32
    assert await regs.read(bfm.OFF_INPUT_WIDTH) == 32
    assert await regs.read(bfm.OFF_CONV_CONFIG) == bfm.pack_conv_config(3, 1, 1, True)
    assert await regs.read(bfm.OFF_OUTPUT_SCALE) == bfm.pack_output_scale(44077, 24)


@cocotb.test()
async def test_undefined_address(dut):
    """§9.3: undefined offset reads 0, write sets non-fatal ERR_INVALID_ADDRESS."""
    regs = await _setup(dut)
    assert await regs.read(0x50) == 0
    await regs.write(0x50, 0xDEADBEEF)
    status = await regs.status()
    assert status & bfm.STATUS_ERROR
    assert await regs.error_code() == bfm.ERR_INVALID_ADDRESS


@cocotb.test()
async def test_invalid_operation_rejected(dut):
    """§11.2/§10.1: unsupported OPERATION -> START rejected, fatal ERR_INVALID_OPERATION, BUSY stays 0."""
    regs = await _setup(dut)
    await regs.write(bfm.OFF_OPERATION, 4)  # OP_FC, reserved/unsupported in v1.1
    await regs.write(bfm.OFF_INPUT_HEIGHT, 4)
    await regs.write(bfm.OFF_INPUT_WIDTH, 4)
    await regs.write(bfm.OFF_IN_CHANNELS, 1)
    await regs.write(bfm.OFF_OUT_CHANNELS, 1)
    await regs.write(bfm.OFF_CONV_CONFIG, bfm.pack_conv_config(3, 1, 1, False))
    await regs.start()

    status = await regs.status()
    assert not (status & bfm.STATUS_BUSY), "BUSY must not rise on a rejected START"
    assert status & bfm.STATUS_ERROR
    assert await regs.error_code() == bfm.ERR_INVALID_OPERATION


@cocotb.test(skip=not STAGE1_AVAILABLE)
async def test_single_conv_matches_python_golden_model(dut):
    """§8.7 / §15.5: run the canonical §13.1 stage-1 conv vector end to end and diff the
    DUT's output against the Python golden model's expected_output.bin byte-for-byte.
    Also cross-validates the reference model's compute path against the exporter's --
    both independently implement §5's fixed-point rules.
    """
    config = json.loads((STAGE1_DIR / "config.json").read_text())
    weight = (STAGE1_DIR / "weight.bin").read_bytes()
    bias = (STAGE1_DIR / "bias.bin").read_bytes()
    input_bytes = (STAGE1_DIR / "input.bin").read_bytes()
    expected = (STAGE1_DIR / "expected_output.bin").read_bytes()

    regs = await _setup(dut)
    output = await _run_stage1_conv(dut, regs, config, weight, bias, input_bytes)

    status = await regs.status()
    assert status & bfm.STATUS_DONE, f"DONE not set, status=0x{status:x}"
    error_code = await regs.error_code()
    assert error_code == bfm.ERR_NONE, f"unexpected ERROR_CODE={error_code}"

    mismatches = [i for i in range(len(expected)) if output[i] != expected[i]]
    assert not mismatches, (
        f"{len(mismatches)}/{len(expected)} bytes mismatched vs Python golden model, "
        f"first at index {mismatches[0]}: got 0x{output[mismatches[0]]:02x} "
        f"expected 0x{expected[mismatches[0]]:02x}"
    )


@cocotb.test(skip=not STAGE1_AVAILABLE)
async def test_start_while_busy_ignored(dut):
    """§8.3/§10.2: START during BUSY is ignored (non-fatal ERR_START_WHILE_BUSY),
    the in-flight operation still completes normally."""
    config = json.loads((STAGE1_DIR / "config.json").read_text())
    weight = (STAGE1_DIR / "weight.bin").read_bytes()
    bias = (STAGE1_DIR / "bias.bin").read_bytes()
    input_bytes = (STAGE1_DIR / "input.bin").read_bytes()

    regs = await _setup(dut)
    await _load_stage1_config(regs, config)
    await regs.start()
    assert (await regs.status()) & bfm.STATUS_BUSY

    await regs.start()  # rejected: still BUSY
    assert (await regs.status()) & bfm.STATUS_ERROR
    assert await regs.error_code() == bfm.ERR_START_WHILE_BUSY

    await bfm.axis_send(dut, "s_axis", weight)
    await bfm.axis_send(dut, "s_axis", bias)
    await bfm.axis_send(dut, "s_axis", input_bytes)
    await bfm.axis_recv(dut, "m_axis", config["output_bytes"])

    async def _wait_idle():
        while (await regs.status()) & bfm.STATUS_BUSY:
            await RisingEdge(dut.clk)

    await with_timeout(_wait_idle(), 10000, "ns")
    status = await regs.status()
    assert status & bfm.STATUS_DONE, "operation in flight when START was rejected must still complete"


@cocotb.test()
async def test_config_write_while_busy_ignored(dut):
    """§9.2: config register writes during BUSY are ignored (non-fatal ERR_CONFIG_WRITE_BUSY),
    the register keeps its pre-BUSY value."""
    regs = await _setup(dut)
    await regs.write(bfm.OFF_OPERATION, 0)
    await regs.write(bfm.OFF_INPUT_HEIGHT, 4)
    await regs.write(bfm.OFF_INPUT_WIDTH, 4)
    await regs.write(bfm.OFF_IN_CHANNELS, 1)
    await regs.write(bfm.OFF_OUT_CHANNELS, 1)
    await regs.write(bfm.OFF_CONV_CONFIG, bfm.pack_conv_config(3, 1, 1, False))
    await regs.write(bfm.OFF_OUTPUT_SCALE, bfm.pack_output_scale(1, 0))
    await regs.write(bfm.OFF_WEIGHT_BYTES, 3 * 3 * 1 * 1)
    await regs.write(bfm.OFF_BIAS_BYTES, 4)
    await regs.write(bfm.OFF_INPUT_BYTES, 4 * 4 * 1)
    await regs.write(bfm.OFF_OUTPUT_BYTES, 4 * 4 * 1)
    await regs.start()
    assert (await regs.status()) & bfm.STATUS_BUSY

    await regs.write(bfm.OFF_INPUT_HEIGHT, 99)  # must be ignored while BUSY
    assert await regs.read(bfm.OFF_INPUT_HEIGHT) == 4
    status = await regs.status()
    assert status & bfm.STATUS_ERROR
    assert await regs.error_code() == bfm.ERR_CONFIG_WRITE_BUSY

    await regs.abort()  # clean up so the test doesn't leave the DUT mid-operation


@cocotb.test()
async def test_abort_mid_operation(dut):
    """§8.3/§11.5: ABORT during BUSY -> BUSY=0, DONE=0, ERROR=1/ERR_ABORTED, no output beats."""
    regs = await _setup(dut)
    # in_channels=4 (not 1) so weight_bytes=36 spans multiple beats -- sending just one
    # of them below is a genuinely incomplete packet, not a (fatal) 1-beat-early TLAST.
    await regs.write(bfm.OFF_OPERATION, 0)
    await regs.write(bfm.OFF_INPUT_HEIGHT, 4)
    await regs.write(bfm.OFF_INPUT_WIDTH, 4)
    await regs.write(bfm.OFF_IN_CHANNELS, 4)
    await regs.write(bfm.OFF_OUT_CHANNELS, 1)
    await regs.write(bfm.OFF_CONV_CONFIG, bfm.pack_conv_config(3, 1, 1, False))
    await regs.write(bfm.OFF_OUTPUT_SCALE, bfm.pack_output_scale(1, 0))
    await regs.write(bfm.OFF_WEIGHT_BYTES, 3 * 3 * 4 * 1)
    await regs.write(bfm.OFF_BIAS_BYTES, 4)
    await regs.write(bfm.OFF_INPUT_BYTES, 4 * 4 * 4)
    await regs.write(bfm.OFF_OUTPUT_BYTES, 4 * 4 * 1)
    await regs.start()
    assert (await regs.status()) & bfm.STATUS_BUSY

    # Only send one beat of the (multi-beat) weight packet, TLAST withheld, then abort mid-stream.
    await bfm.axis_send(dut, "s_axis", bytes(4), assert_final_tlast=False)
    await regs.abort()

    status = await regs.status()
    assert not (status & bfm.STATUS_BUSY)
    assert not (status & bfm.STATUS_DONE)
    assert status & bfm.STATUS_ERROR
    assert await regs.error_code() == bfm.ERR_ABORTED

    debug_state = await regs.debug_state()
    assert debug_state == bfm.FSM_IDLE, f"expected controller back in IDLE, got {debug_state}"


@cocotb.test()
async def test_abort_while_idle_is_noop(dut):
    """§8.3: ABORT while IDLE does nothing (no error, no state change)."""
    regs = await _setup(dut)
    await regs.abort()
    status = await regs.status()
    assert status == bfm.STATUS_IDLE, f"IDLE-time ABORT must be a no-op, got status=0x{status:x}"
