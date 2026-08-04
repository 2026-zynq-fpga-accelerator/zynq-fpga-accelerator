"""Fast, throwaway check (not part of the regular suite): does the real RTL (resnet_accel_top)
reproduce the board's exact fatal signature (BUSY=0, DONE=0, ERROR=0, DEBUG_STATE=IDLE right
after a real completion) using a tiny synthetic OP_CONV that finishes in ~hundreds of cycles
instead of the ~1.4M-cycle canonical stage-1 vector? Run standalone, outside the shared
verification/cocotb/Makefile build (separate sim_build dir) so it doesn't collide with the
canonical-vector regression that may still be running.
"""
import cocotb
from cocotb.triggers import RisingEdge, with_timeout

import bfm


@cocotb.test()
async def quick_done_busy_alignment(dut):
    bfm.start_clock(dut)
    await bfm.reset_dut(dut)
    regs = bfm.AxiLite(dut)

    # Tiny 4x4x4->1 conv, kernel 3, stride 1, padding 1 (all packet byte counts stay
    # 4-byte aligned): out_h=out_w=4. Values don't matter, only that it completes.
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
    assert status & bfm.STATUS_BUSY, f"START not accepted, status=0x{status:x}"
    dut._log.info(f"START admitted: status=0x{status:x}")

    await bfm.axis_send(dut, "s_axis", bytes(weight_bytes))
    dut._log.info(f"weight sent, debug_state={await regs.debug_state()} status=0x{await regs.status():x}")
    await bfm.axis_send(dut, "s_axis", bytes(bias_bytes))
    dut._log.info(f"bias sent, debug_state={await regs.debug_state()} status=0x{await regs.status():x}")
    await bfm.axis_send(dut, "s_axis", bytes(input_bytes))
    dut._log.info("all input packets sent, waiting for output...")

    output = await with_timeout(bfm.axis_recv(dut, "m_axis", output_bytes), 200000, "ns")
    dut._log.info(f"received {len(output)} output bytes")

    # Sample STATUS/DEBUG_STATE on the very next clock, mirroring firmware's
    # accel_wait_done() -- exactly the check the board failed.
    await RisingEdge(bfm.clk_signal(dut))
    status = await regs.status()
    error_code = await regs.error_code()
    debug_state = await regs.debug_state()
    cycle_count = await regs.read(bfm.OFF_CYCLE_COUNT)
    dut._log.info(
        f"post-completion: status=0x{status:x} error_code={error_code} "
        f"debug_state={debug_state} cycle_count={cycle_count}"
    )

    busy = bool(status & bfm.STATUS_BUSY)
    done = bool(status & bfm.STATUS_DONE)
    error = bool(status & bfm.STATUS_ERROR)

    if (not busy) and (not done) and (not error):
        dut._log.error(
            "REPRODUCED BOARD FAILURE: BUSY=0 DONE=0 ERROR=0 "
            f"debug_state={debug_state} -- RTL bug confirmed in simulation"
        )
        assert False, "termination gap reproduced: BUSY=0 DONE=0 ERROR=0"

    assert done, f"expected DONE=1 after real completion, status=0x{status:x}"
    dut._log.info("DONE correctly set at/after completion -- no termination gap in simulation")
