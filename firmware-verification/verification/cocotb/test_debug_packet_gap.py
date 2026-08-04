"""Root-cause probe (throwaway, not part of the regression suite) for the packet-gap hang:
sending weight -> bias -> input back-to-back with zero settling cycles between them causes
input beat 0 to never see TREADY; inserting a couple of AXI-Lite register reads between
packets (which cost a few extra clock cycles each) made it disappear.

Hypothesis under test: axis_packet_loader.sv's `s_axis_tready_o = packet_active_i &&
!packet_start_i` stays high for one extra cycle after the weight packet's packet_done_o
registers (packet_done is itself one cycle late, and controller_fsm hasn't yet moved
state_q/packet_start_o in response) -- so a beat presented in that cycle gets counted
against the OLD (weight) packet's expected_bytes_i, overflows count_valid, and
packet_length_error_o fires, which controller_fsm's top-priority abort branch turns into
an immediate state_q<=DBG_IDLE. After that, packet_active_o=0 forever, so no later packet
ever sees TREADY again.

Every sample below is taken via `await ReadOnly()` first -- reading dut.<sig>.value
immediately after crossing a RisingEdge (without ReadOnly) can race the simulator's NBA
update region and observe stale values; this is exactly the race bfm.py's axis_send/
axis_recv already guard against, which the first version of this file didn't.
"""
import cocotb
from cocotb.triggers import RisingEdge, ReadOnly

import bfm


async def snap(dut, clk, tag):
    await ReadOnly()
    c = dut.u_controller
    pl = dut.u_packet_loader
    dut._log.info(
        f"{tag}: state_q={int(c.state_q.value)} packet_start_o={int(c.packet_start_o.value)} "
        f"packet_active_o={int(c.packet_active_o.value)} packet_select_o={int(c.packet_select_o.value)} "
        f"expected_bytes_o={int(c.expected_packet_bytes_o.value)} byte_count_q={int(pl.byte_count_q.value)} "
        f"tready={int(dut.s_axis_tready.value)} tvalid={int(dut.s_axis_tvalid.value)} "
        f"transfer={int(pl.transfer.value)} count_valid={int(pl.count_valid.value)} "
        f"packet_done_i={int(c.packet_done_i.value)} packet_length_error_i={int(c.packet_length_error_i.value)} "
        f"packet_length_error_o={int(pl.packet_length_error_o.value)}"
    )


@cocotb.test()
async def debug_packet_gap(dut):
    bfm.start_clock(dut)
    await bfm.reset_dut(dut)
    regs = bfm.AxiLite(dut)
    clk = bfm.clk_signal(dut)

    await regs.write(bfm.OFF_OPERATION, 0)
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
    await regs.wait_admitted()

    # Send weight, no gap -- axis_send() returns right on the cycle the last beat transfers,
    # in the Write-enabled phase, so it's safe to drive new values immediately (before any
    # snap()/ReadOnly() below).
    await bfm.axis_send(dut, "s_axis", bytes(weight_bytes))

    # Immediately (zero settling cycles) present bias's beat 0 by hand, one cycle at a time,
    # logging every cycle so we can see exactly when/why it does or doesn't get accepted.
    dut.s_axis_tdata.value = 0
    dut.s_axis_tkeep.value = 0xF
    dut.s_axis_tlast.value = 1  # bias is 4 bytes = 1 beat = last beat of its own packet
    dut.s_axis_tvalid.value = 1
    await snap(dut, clk, "cycle A (bias beat0 presented, same cycle weight's last beat transferred)")
    for i in range(10):
        await RisingEdge(clk)
        await snap(dut, clk, f"cycle A+{i + 1}")
    await RisingEdge(clk)
    dut.s_axis_tvalid.value = 0

    # Now try to push input beat 0 for a while, to confirm the hang and see the final state.
    dut.s_axis_tdata.value = 0
    dut.s_axis_tkeep.value = 0xF
    dut.s_axis_tlast.value = 0
    dut.s_axis_tvalid.value = 1
    for i in range(10):
        await RisingEdge(clk)
        await snap(dut, clk, f"input-probe cycle {i}")
    await RisingEdge(clk)
    dut.s_axis_tvalid.value = 0
