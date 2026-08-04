`timescale 1ns/1ps

module tb_full_conv;
  import accel_pkg::*;

  localparam integer CLK_PERIOD_NS = 10;
  localparam integer INPUT_BYTES = 3072;
  localparam integer WEIGHT_BYTES = 432;
  localparam integer BIAS_BYTES = 64;
  localparam integer OUTPUT_BYTES = 16384;
  localparam logic [31:0] OLD_EXPECTED_CYCLES = 32'd1435390;
  localparam logic [31:0] EXPECTED_CYCLES     = 32'd1435424;

  logic aclk, aresetn;
  logic [6:0] s_axi_awaddr;
  logic s_axi_awvalid, s_axi_awready;
  logic [31:0] s_axi_wdata;
  logic [3:0] s_axi_wstrb;
  logic s_axi_wvalid, s_axi_wready;
  logic [1:0] s_axi_bresp;
  logic s_axi_bvalid, s_axi_bready;
  logic [6:0] s_axi_araddr;
  logic s_axi_arvalid, s_axi_arready;
  logic [31:0] s_axi_rdata;
  logic [1:0] s_axi_rresp;
  logic s_axi_rvalid, s_axi_rready;
  logic [31:0] s_axis_tdata;
  logic [3:0] s_axis_tkeep;
  logic s_axis_tlast, s_axis_tvalid, s_axis_tready;
  logic [31:0] m_axis_tdata;
  logic [3:0] m_axis_tkeep;
  logic m_axis_tlast, m_axis_tvalid, m_axis_tready;

  logic [7:0] input_data [0:INPUT_BYTES-1];
  logic [7:0] weight_data [0:WEIGHT_BYTES-1];
  logic [31:0] bias_data [0:15];
  logic [7:0] expected_data [0:OUTPUT_BYTES-1];
  logic [31:0] mac_trace [0:OUTPUT_BYTES-1];
  logic [31:0] biased_trace [0:OUTPUT_BYTES-1];
  logic [63:0] requant_trace [0:OUTPUT_BYTES-1];

  integer output_byte_count;
  integer mismatch_count;
  integer detail_count;
  integer tb_cycle;
  integer final_handshake_cycle;
  integer busy_deassert_cycle;
  integer done_assert_cycle;
  integer complete_state_cycle;
  integer idle_state_cycle;
  logic previous_busy;
  logic previous_done;
  logic admitted_operation_active;
  logic [3:0] previous_debug_state;

  resnet_accel_top dut (
    .aclk(aclk), .aresetn(aresetn),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid),
    .s_axi_wready(s_axi_wready), .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
    .s_axi_bready(s_axi_bready), .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready), .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
    .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep), .s_axis_tlast(s_axis_tlast),
    .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
    .m_axis_tdata(m_axis_tdata), .m_axis_tkeep(m_axis_tkeep), .m_axis_tlast(m_axis_tlast),
    .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready)
  );

  always #(CLK_PERIOD_NS/2) aclk = ~aclk;

  always @(posedge aclk) begin
    tb_cycle = tb_cycle + 1;
    if (aresetn && m_axis_tvalid && m_axis_tready && m_axis_tlast) begin
      if (final_handshake_cycle >= 0)
        $fatal(1, "Observed more than one final output handshake");
      final_handshake_cycle = tb_cycle;
    end
  end

  always @(negedge aclk) begin
    if (!aresetn) begin
      previous_busy = 1'b0;
      previous_done = 1'b0;
      admitted_operation_active = 1'b0;
      previous_debug_state = DBG_RESET;
    end else begin
      if (!previous_busy && dut.busy)
        admitted_operation_active = 1'b1;
      if (previous_busy && !dut.busy)
        busy_deassert_cycle = tb_cycle;
      if (!previous_done && dut.done)
        done_assert_cycle = tb_cycle;

      if ((previous_debug_state != DBG_COMPLETE) && (dut.debug_state == DBG_COMPLETE))
        complete_state_cycle = tb_cycle;
      if ((previous_debug_state == DBG_COMPLETE) && (dut.debug_state == DBG_IDLE))
        idle_state_cycle = tb_cycle;
      if (admitted_operation_active && !dut.busy) begin
        if (!dut.done && !dut.error)
          $fatal(1, "Termination gap: BUSY=0 DONE=0 ERROR=0 at cycle %0d state=%0d",
                 tb_cycle, dut.debug_state);
        admitted_operation_active = 1'b0;
      end

      previous_busy = dut.busy;
      previous_done = dut.done;
      previous_debug_state = dut.debug_state;
    end
  end

  task automatic axi_write(input logic [6:0] address, input logic [31:0] data);
    logic aw_done, w_done;
    begin
      aw_done = 0; w_done = 0;
      @(negedge aclk);
      s_axi_awaddr = address; s_axi_awvalid = 1;
      s_axi_wdata = data; s_axi_wstrb = 4'b1111; s_axi_wvalid = 1;
      while (!aw_done || !w_done) begin
        @(posedge aclk);
        if (s_axi_awvalid && s_axi_awready) aw_done = 1;
        if (s_axi_wvalid && s_axi_wready) w_done = 1;
        @(negedge aclk);
        if (aw_done) s_axi_awvalid = 0;
        if (w_done) s_axi_wvalid = 0;
      end
      wait (s_axi_bvalid === 1'b1);
      if (s_axi_bresp != 2'b00) $fatal(1, "AXI write error at %02x", address);
      @(posedge aclk);
    end
  endtask

  task automatic axi_write_masked(
    input logic [6:0] address,
    input logic [31:0] data,
    input logic [3:0] strobe
  );
    logic aw_done, w_done;
    begin
      aw_done = 0; w_done = 0;
      @(negedge aclk);
      s_axi_awaddr = address; s_axi_awvalid = 1;
      s_axi_wdata = data; s_axi_wstrb = strobe; s_axi_wvalid = 1;
      while (!aw_done || !w_done) begin
        @(posedge aclk);
        if (s_axi_awvalid && s_axi_awready) aw_done = 1;
        if (s_axi_wvalid && s_axi_wready) w_done = 1;
        @(negedge aclk);
        if (aw_done) s_axi_awvalid = 0;
        if (w_done) s_axi_wvalid = 0;
      end
      wait (s_axi_bvalid === 1'b1);
      if (s_axi_bresp != 2'b00) $fatal(1, "AXI masked write error at %02x", address);
      @(posedge aclk);
      s_axi_wstrb = 4'b1111;
    end
  endtask

  task automatic axi_read(input logic [6:0] address, output logic [31:0] data);
    begin
      @(negedge aclk);
      s_axi_araddr = address; s_axi_arvalid = 1;
      do @(posedge aclk); while (!s_axi_arready);
      @(negedge aclk); s_axi_arvalid = 0;
      wait (s_axi_rvalid === 1'b1);
      data = s_axi_rdata;
      if (s_axi_rresp != 2'b00) $fatal(1, "AXI read error at %02x", address);
      @(posedge aclk);
    end
  endtask

  task automatic send_word(input logic [31:0] data, input logic last);
    begin
      @(negedge aclk);
      s_axis_tdata = data; s_axis_tkeep = 4'b1111; s_axis_tlast = last; s_axis_tvalid = 1;
      do @(posedge aclk); while (!s_axis_tready);
      @(negedge aclk); s_axis_tvalid = 0; s_axis_tlast = 0;
    end
  endtask

  task automatic send_packets;
    integer word_index;
    logic [31:0] packed_word;
    begin
      for (word_index = 0; word_index < WEIGHT_BYTES/4; word_index = word_index + 1) begin
        packed_word = {weight_data[word_index*4+3], weight_data[word_index*4+2],
                       weight_data[word_index*4+1], weight_data[word_index*4]};
        send_word(packed_word, word_index == WEIGHT_BYTES/4-1);
      end
      for (word_index = 0; word_index < BIAS_BYTES/4; word_index = word_index + 1)
        send_word(bias_data[word_index], word_index == BIAS_BYTES/4-1);
      for (word_index = 0; word_index < INPUT_BYTES/4; word_index = word_index + 1) begin
        packed_word = {input_data[word_index*4+3], input_data[word_index*4+2],
                       input_data[word_index*4+1], input_data[word_index*4]};
        send_word(packed_word, word_index == INPUT_BYTES/4-1);
      end
    end
  endtask

  always @(posedge aclk) begin : output_capture
    integer lane, byte_index, beat_mismatches;
    integer oh, ow, oc;
    integer signed actual_value, expected_value;
    if (aresetn && m_axis_tvalid && m_axis_tready) begin
      beat_mismatches = 0;
      if (m_axis_tkeep !== 4'b1111) begin
        beat_mismatches = beat_mismatches + 1;
        if (detail_count < 10) begin
          $display("MISMATCH TKEEP byte=%0d expected=1111 actual=%b",
                   output_byte_count, m_axis_tkeep);
          detail_count = detail_count + 1;
        end
      end
      for (lane = 0; lane < 4; lane = lane + 1) begin
        byte_index = output_byte_count + lane;
        actual_value = $signed(m_axis_tdata[lane*8 +: 8]);
        expected_value = $signed(expected_data[byte_index]);
        if (actual_value != expected_value) begin
          beat_mismatches = beat_mismatches + 1;
          if (detail_count < 10) begin
            oh = byte_index / (32 * 16);
            ow = (byte_index / 16) % 32;
            oc = byte_index % 16;
            $display("MISMATCH #%0d h=%0d w=%0d c=%0d expected=%0d actual=%0d",
                     mismatch_count + beat_mismatches, oh, ow, oc, expected_value, actual_value);
            $display("TRACE mac_acc=%0d biased=%0d requant=%0d clamp=%0d",
                     $signed(mac_trace[byte_index]), $signed(biased_trace[byte_index]),
                     $signed(requant_trace[byte_index]), expected_value);
            detail_count = detail_count + 1;
          end
        end
      end
      if (m_axis_tlast !== ((output_byte_count + 4) == OUTPUT_BYTES)) begin
        beat_mismatches = beat_mismatches + 1;
        if (detail_count < 10) begin
          $display("MISMATCH TLAST byte=%0d expected=%0b actual=%0b",
                   output_byte_count, ((output_byte_count + 4) == OUTPUT_BYTES), m_axis_tlast);
          detail_count = detail_count + 1;
        end
      end
      mismatch_count = mismatch_count + beat_mismatches;
      output_byte_count = output_byte_count + 4;
    end
  end

  initial begin
    logic [31:0] status, code, cycles, state;
    logic [31:0] previous_validation_count;
    integer validation_cycles;
    aclk = 0; aresetn = 0;
    s_axi_awaddr = 0; s_axi_awvalid = 0; s_axi_wdata = 0; s_axi_wstrb = 4'b1111;
    s_axi_wvalid = 0; s_axi_bready = 1; s_axi_araddr = 0; s_axi_arvalid = 0;
    s_axi_rready = 1; s_axis_tdata = 0; s_axis_tkeep = 4'b1111;
    s_axis_tlast = 0; s_axis_tvalid = 0; m_axis_tready = 1;
    output_byte_count = 0; mismatch_count = 0; detail_count = 0;
    tb_cycle = 0; final_handshake_cycle = -1;
    busy_deassert_cycle = -1; done_assert_cycle = -1;
    complete_state_cycle = -1; idle_state_cycle = -1;
    previous_busy = 0; previous_done = 0; previous_debug_state = DBG_RESET;
    admitted_operation_active = 0;

    $readmemh("vectors/full_conv_32x32x3x16/input.hex", input_data);
    $readmemh("vectors/full_conv_32x32x3x16/weight.hex", weight_data);
    $readmemh("vectors/full_conv_32x32x3x16/bias.hex", bias_data);
    $readmemh("vectors/full_conv_32x32x3x16/expected_output.hex", expected_data);
    $readmemh("vectors/full_conv_32x32x3x16/mac_accumulator.hex", mac_trace);
    $readmemh("vectors/full_conv_32x32x3x16/biased_accumulator.hex", biased_trace);
    $readmemh("vectors/full_conv_32x32x3x16/requantized.hex", requant_trace);

    repeat (6) @(posedge aclk); @(negedge aclk); aresetn = 1; repeat (4) @(posedge aclk);
    axi_write(REG_STATUS, 32'h0000_000c);
    axi_write(REG_OPERATION, 0);
    axi_write(REG_INPUT_HEIGHT, 32);
    axi_write(REG_INPUT_WIDTH, 32);
    axi_write(REG_IN_CHANNELS, 3);
    axi_write(REG_OUT_CHANNELS, 16);
    axi_write(REG_CONV_CONFIG, 32'h0101_0103);
    axi_write(REG_OUTPUT_SCALE, 32'h0002_0003);
    axi_write(REG_INPUT_BYTES, INPUT_BYTES);
    axi_write(REG_WEIGHT_BYTES, WEIGHT_BYTES);
    axi_write(REG_BIAS_BYTES, BIAS_BYTES);
    axi_write(REG_SKIP_BYTES, 0);
    axi_write(REG_OUTPUT_BYTES, OUTPUT_BYTES);
    axi_write(REG_CONTROL, 1);
    axi_read(REG_STATUS, status);
    axi_read(REG_CYCLE_COUNT, cycles);
    if (status[3:0] != 4'b0010)
      $fatal(1, "Full conv first START status was not BUSY-only: %08x", status);
    if (cycles == 32'd0)
      $fatal(1, "Full conv admission counter did not advance");

    validation_cycles = 0;
    previous_validation_count = dut.cycle_count;
    while (dut.admission_active) begin
      @(negedge aclk);
      if (dut.admission_active) begin
        if (!dut.busy || dut.idle)
          $fatal(1, "Full conv BUSY/IDLE contract failed during validation");
        if (dut.debug_state != DBG_IDLE)
          $fatal(1, "Full conv DEBUG_STATE changed during validation: %0d", dut.debug_state);
        if (dut.cycle_count <= previous_validation_count)
          $fatal(1, "Full conv cycle counter did not advance during validation");
        previous_validation_count = dut.cycle_count;
        if (dut.error)
          $fatal(1, "Full conv ERROR during valid admission");
        validation_cycles = validation_cycles + 1;
        if (validation_cycles > 256)
          $fatal(1, "Full conv timed out waiting for validation");
      end
    end
    if (!dut.busy || dut.idle)
      $fatal(1, "Full conv BUSY-low gap after validation");
    $display("FULL CONV REMAINING VALIDATOR ACTIVE: %0d cycles", validation_cycles);
    send_packets();

    wait (output_byte_count == OUTPUT_BYTES);
    @(negedge aclk); #1;
    if (dut.busy || !dut.done || dut.error || (dut.debug_state != DBG_COMPLETE))
      $fatal(1, "Completion-edge status failure BUSY=%0b DONE=%0b ERROR=%0b STATE=%0d",
             dut.busy, dut.done, dut.error, dut.debug_state);
    if ((final_handshake_cycle != busy_deassert_cycle)
        || (final_handshake_cycle != done_assert_cycle))
      $fatal(1, "Completion cycles misaligned handshake=%0d busy_fall=%0d done_rise=%0d",
             final_handshake_cycle, busy_deassert_cycle, done_assert_cycle);
    $display("COMPLETION EDGE PASS: handshake=%0d busy_fall=%0d done_rise=%0d state=COMPLETE",
             final_handshake_cycle, busy_deassert_cycle, done_assert_cycle);

    repeat (100) begin
      @(posedge aclk); @(negedge aclk);
      if (!dut.done || dut.busy || dut.error)
        $fatal(1, "DONE sticky hold failure cycle=%0d BUSY=%0b DONE=%0b ERROR=%0b",
               tb_cycle, dut.busy, dut.done, dut.error);
    end
    $display("DONE HOLD PASS: 100 clocks through cycle %0d", tb_cycle);
    if ((complete_state_cycle != final_handshake_cycle)
        || (idle_state_cycle != final_handshake_cycle + 1))
      $fatal(1, "Completion state cycles unexpected COMPLETE=%0d IDLE=%0d handshake=%0d",
             complete_state_cycle, idle_state_cycle, final_handshake_cycle);
    $display("COMPLETION STATE PASS: COMPLETE=%0d IDLE=%0d",
             complete_state_cycle, idle_state_cycle);

    axi_read(REG_STATUS, status);
    if (status[3:0] != 4'b0101)
      $fatal(1, "STATUS read returned unexpected completion value %08x", status);
    axi_read(REG_STATUS, status);
    if (status[3:0] != 4'b0101)
      $fatal(1, "STATUS read cleared DONE, STATUS=%08x", status);

    axi_write(REG_CYCLE_COUNT, 32'h0000_0004);
    axi_read(REG_STATUS, status);
    if (status[3:0] != 4'b0101)
      $fatal(1, "Unrelated AXI write cleared DONE, STATUS=%08x", status);

    axi_write_masked(REG_STATUS, 32'h0000_0004, 4'b1110);
    axi_read(REG_STATUS, status);
    if (status[3:0] != 4'b0101)
      $fatal(1, "WSTRB-masked W1C cleared DONE, STATUS=%08x", status);

    axi_read(REG_STATUS, status);
    axi_read(REG_ERROR_CODE, code);
    axi_read(REG_CYCLE_COUNT, cycles);
    axi_read(REG_DEBUG_STATE, state);
    if (status[1] || !status[2] || status[3])
      $fatal(1, "Full conv status failure STATUS=%08x CODE=%0d", status, code);
    if (code != ERR_NONE) $fatal(1, "Full conv ERROR_CODE=%0d", code);
    if (cycles != EXPECTED_CYCLES)
      $fatal(1, "Full conv cycle count=%0d expected=%0d", cycles, EXPECTED_CYCLES);
    if (state[3:0] != DBG_IDLE) $fatal(1, "Full conv debug state=%0d, expected IDLE", state);
    if (mismatch_count != 0)
      $fatal(1, "FULL CONV FAIL: %0d mismatches across %0d output bytes",
             mismatch_count, output_byte_count);

    axi_write(REG_STATUS, 32'h0000_0004);
    axi_read(REG_STATUS, status);
    axi_read(REG_ERROR_CODE, code);
    if ((status[3:0] != 4'b0001) || (code != ERR_NONE))
      $fatal(1, "Explicit DONE W1C failure STATUS=%08x CODE=%0d", status, code);
    $display("DONE W1C PASS: cycle=%0d STATUS=%08x ERROR_CODE=%0d",
             tb_cycle, status, code);

    $display("CYCLE COUNT SEMANTICS: old=%0d new=%0d delta=%0d (admission active clocks)",
             OLD_EXPECTED_CYCLES, cycles, cycles - OLD_EXPECTED_CYCLES);
    $display("FULL CONV PASS: %0d output bytes, mismatch=0 cycles=%0d",
             output_byte_count, cycles);
    $finish;
  end

  initial begin
    repeat (3000000) @(posedge aclk);
    $fatal(1, "Full convolution simulation timeout");
  end
endmodule
