"""Throwaway probe (not part of the regression suite): does releasing aresetn, with NO
operation ever started, leave CYCLE_COUNT reading 1 instead of 0? RTL reported reproducing
exactly this in his own AXI simulation (2026-08-03). By inspection, controller_fsm.sv's
busy_o = (state_q != DBG_IDLE) && (state_q != DBG_COMPLETE) does not exclude DBG_RESET
(accel_pkg.sv: DBG_RESET=0, DBG_IDLE=1, DBG_COMPLETE=7), so on the very edge aresetn_i is
sampled high while state_q still holds its pre-edge DBG_RESET value, busy_o reads 1 for that
one edge. cycle_counter.sv's busy_i is wired directly to this same busy signal
(resnet_accel_top.sv), so cycle_count_o ticks 0->1 on that edge and then holds, since neither
operation_accept_i nor a fresh aresetn ever fires again. This test checks that prediction
directly against the real RTL, without ever issuing START.
"""
import cocotb

import bfm


@cocotb.test()
async def cycle_count_is_one_after_reset_with_no_operation(dut):
    bfm.start_clock(dut)
    await bfm.reset_dut(dut)
    regs = bfm.AxiLite(dut)

    cycle_count = await regs.read(bfm.OFF_CYCLE_COUNT)
    debug_state = await regs.debug_state()
    status = await regs.status()
    dut._log.info(
        f"immediately after reset, no operation started: "
        f"cycle_count={cycle_count} debug_state={debug_state} status=0x{status:x}"
    )

    assert debug_state == bfm.FSM_IDLE, (
        f"expected FSM to have settled in IDLE({bfm.FSM_IDLE}) by the time we can read "
        f"registers, got debug_state={debug_state}"
    )
    assert cycle_count == 1, (
        f"expected the DBG_RESET busy_o glitch to leave cycle_count=1, got {cycle_count} -- "
        f"if this is 0, the glitch this test targets is not present in this RTL revision"
    )
    dut._log.info(
        "REPRODUCED: cycle_count=1 with debug_state=IDLE and no operation ever started -- "
        "confirms the busy_o/DBG_RESET glitch (ISSUE-004) independently of RTL's own AXI sim"
    )
