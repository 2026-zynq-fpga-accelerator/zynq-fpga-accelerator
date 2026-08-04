"""Throwaway probe (not part of the regression suite): does running the SAME tiny OP_CONV
twice in a row, WITHOUT a fresh aresetn pulse between them (mirroring "board wasn't
power-cycled between test attempts"), leak state from run 1 into run 2? Specifically watching
whether run 2's CYCLE_COUNT still counts normally (~1870, matching a fresh single run) or
comes out anomalously small like the board's observed cycle_count=1.
"""
import cocotb
from cocotb.triggers import RisingEdge, with_timeout

import bfm


async def run_one_conv(dut, regs, tag):
    await regs.write(bfm.OFF_OPERATION, 0)  # OP_CONV
    await regs.write(bfm.OFF_INPUT_HEIGHT, 4)
    await regs.write(bfm.OFF_INPUT_WIDTH, 4)
    await regs.write(bfm.OFF_IN_CHANNELS, 4)
    await regs.write(bfm.OFF_OUT_CHANNELS, 1)
    await regs.write(bfm.OFF_CONV_CONFIG, bfm.pack_conv_config(3, 1, 1, False))
    await regs.write(bfm.OFF_OUTPUT_SCALE, bfm.pack_output_scale(1, 0))
    weight_bytes = 3 * 3 * 4 * 1
    bias_bytes = 1 * 4
    input_bytes = 4 * 4 * 4
    output_bytes = 4 * 4 * 1
    await regs.write(bfm.OFF_WEIGHT_BYTES, weight_bytes)
    await regs.write(bfm.OFF_BIAS_BYTES, bias_bytes)
    await regs.write(bfm.OFF_INPUT_BYTES, input_bytes)
    await regs.write(bfm.OFF_OUTPUT_BYTES, output_bytes)

    await regs.start()
    status = await regs.wait_admitted()
    assert status & bfm.STATUS_BUSY, f"{tag}: START not accepted, status=0x{status:x}"

    # ISSUE-003 workaround: a register read between packets costs a few extra clock cycles,
    # which avoids the axis_packet_loader.sv TREADY-stays-high-one-cycle-too-long race.
    await bfm.axis_send(dut, "s_axis", bytes(weight_bytes))
    await regs.debug_state()
    await bfm.axis_send(dut, "s_axis", bytes(bias_bytes))
    await regs.debug_state()
    await bfm.axis_send(dut, "s_axis", bytes(input_bytes))

    await with_timeout(bfm.axis_recv(dut, "m_axis", output_bytes), 200000, "ns")

    await RisingEdge(bfm.clk_signal(dut))
    status = await regs.status()
    error_code = await regs.error_code()
    debug_state = await regs.debug_state()
    cycle_count = await regs.read(bfm.OFF_CYCLE_COUNT)
    dut._log.info(
        f"{tag}: post-completion status=0x{status:x} error_code={error_code} "
        f"debug_state={debug_state} cycle_count={cycle_count}"
    )
    return status, error_code, debug_state, cycle_count


@cocotb.test()
async def repeat_conv_no_reset_between(dut):
    bfm.start_clock(dut)
    await bfm.reset_dut(dut)  # single reset for the whole test -- mirrors "no power cycle"
    regs = bfm.AxiLite(dut)

    result1 = await run_one_conv(dut, regs, "RUN 1 (fresh after reset)")
    assert result1[0] & bfm.STATUS_DONE, f"RUN 1 failed to complete: status=0x{result1[0]:x}"

    # Mirrors firmware's accel_clear_done_and_error() at the top of the next accel_run_layer(),
    # clearing DONE/ERROR via W1C -- everything else (no reset) is left exactly as run 1 left it.
    await regs.clear_done_and_error()

    result2 = await run_one_conv(dut, regs, "RUN 2 (immediately after run 1, no reset)")

    dut._log.info(
        f"COMPARISON: run1_cycle_count={result1[3]} run2_cycle_count={result2[3]} "
        f"(expected: both similar magnitude, NOT run2 anomalously small like the board's cycle_count=1)"
    )

    assert result2[0] & bfm.STATUS_DONE, f"RUN 2 failed to complete: status=0x{result2[0]:x}"
    assert result2[3] > 100, (
        f"RUN 2 cycle_count={result2[3]} is anomalously small (board bug reproduced!) "
        f"vs run1={result1[3]}"
    )
    dut._log.info("No state leakage detected: run 2 behaves identically to run 1.")
