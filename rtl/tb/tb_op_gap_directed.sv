`timescale 1ns/1ps

// OP_GLOBAL_AVG_POOL directed tests (HW_SW_Interface_v1.4_DRAFT.md §2, §6 checklist):
// all-zero input, max/min per-channel saturation values, and M=1/N=6-style exact-average
// accuracy (2^N spatial positions -> zero rounding error).
module tb_op_gap_directed;
  import accel_pkg::*;

  localparam integer CLK_PERIOD_NS = 10;
  localparam integer MAX_INPUT_BYTES  = 1024;
  localparam integer MAX_OUTPUT_BYTES = 128;

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

  logic signed [7:0] input_data [0:MAX_INPUT_BYTES-1];
  logic signed [7:0] expected_data [0:MAX_OUTPUT_BYTES-1];

  integer cfg_h, cfg_w, cfg_c;
  integer cfg_multiplier, cfg_shift;
  integer cfg_input_bytes, cfg_output_bytes;
  integer output_byte_count, mismatch_count, tests_passed;
  logic capture_enabled;

  resnet_accel_top #(
    .MAX_WEIGHT_WORDS(16), .MAX_BIAS_WORDS(8),
    .MAX_INPUT_WORDS(256), .MAX_OUTPUT_WORDS(32)
  ) dut (
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

  function automatic longint signed requant_ref(
    input integer signed accumulator,
    input integer unsigned multiplier,
    input integer unsigned shift
  );
    longint signed product, magnitude, rounded;
    begin
      product = accumulator;
      product = product * multiplier;
      magnitude = (product < 0) ? -product : product;
      if (shift == 0) rounded = magnitude;
      else rounded = (magnitude + (64'sd1 << (shift-1))) >>> shift;
      requant_ref = (product < 0) ? -rounded : rounded;
    end
  endfunction

  function automatic logic signed [7:0] postprocess_ref(input integer signed accumulator);
    longint signed value;
    begin
      value = requant_ref(accumulator, cfg_multiplier, cfg_shift);
      if (value > 127) value = 127;
      else if (value < -128) value = -128;
      postprocess_ref = value[7:0];
    end
  endfunction

  task automatic build_reference;
    integer c, h, w, index;
    integer signed acc;
    begin
      for (c = 0; c < cfg_c; c = c + 1) begin
        acc = 0;
        for (h = 0; h < cfg_h; h = h + 1)
          for (w = 0; w < cfg_w; w = w + 1)
            acc = acc + $signed(input_data[((h * cfg_w) + w) * cfg_c + c]);
        expected_data[c] = postprocess_ref(acc);
      end
      cfg_input_bytes  = cfg_h * cfg_w * cfg_c;
      cfg_output_bytes = cfg_c;
    end
  endtask

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

  task automatic send_input_packet;
    integer word_index;
    logic [31:0] packed_word;
    begin
      for (word_index = 0; word_index < cfg_input_bytes/4; word_index = word_index + 1) begin
        packed_word = {input_data[word_index*4+3], input_data[word_index*4+2],
                  input_data[word_index*4+1], input_data[word_index*4]};
        send_word(packed_word, word_index == cfg_input_bytes/4-1);
      end
    end
  endtask

  task automatic program_config;
    logic [31:0] output_scale;
    begin
      output_scale = {cfg_shift[15:0], cfg_multiplier[15:0]};
      axi_write(REG_OPERATION, OP_GLOBAL_AVG_POOL);
      axi_write(REG_INPUT_HEIGHT, cfg_h);
      axi_write(REG_INPUT_WIDTH, cfg_w);
      axi_write(REG_IN_CHANNELS, cfg_c);
      axi_write(REG_OUT_CHANNELS, cfg_c);
      axi_write(REG_CONV_CONFIG, 32'd0);
      axi_write(REG_OUTPUT_SCALE, output_scale);
      axi_write(REG_INPUT_BYTES, cfg_input_bytes);
      axi_write(REG_WEIGHT_BYTES, 0);
      axi_write(REG_BIAS_BYTES, 0);
      axi_write(REG_SKIP_BYTES, 0);
      axi_write(REG_OUTPUT_BYTES, cfg_output_bytes);
    end
  endtask

  task automatic clear_status;
    begin axi_write(REG_STATUS, 32'h0000_000c); end
  endtask

  task automatic check_status(
    input logic expected_busy, input logic expected_done, input logic expected_error,
    input logic [31:0] expected_code, input string name
  );
    logic [31:0] status, code, state;
    begin
      axi_read(REG_STATUS, status); axi_read(REG_ERROR_CODE, code); axi_read(REG_DEBUG_STATE, state);
      if ((status[1] !== expected_busy) || (status[2] !== expected_done)
          || (status[3] !== expected_error) || (code !== expected_code))
        $fatal(1, "%s status mismatch STATUS=%08x CODE=%0d STATE=%0d", name, status, code, state);
      if (!expected_busy && (state[3:0] != DBG_IDLE))
        $fatal(1, "%s did not return IDLE: STATE=%0d", name, state);
    end
  endtask

  task automatic begin_capture;
    begin
      output_byte_count = 0;
      mismatch_count = 0;
      capture_enabled = 1;
    end
  endtask

  task automatic run_normal(input string name);
    begin
      build_reference(); clear_status(); program_config(); begin_capture();
      axi_write(REG_CONTROL, 1);
      send_input_packet();
      wait (output_byte_count == cfg_output_bytes);
      capture_enabled = 0;
      repeat (6) @(posedge aclk);
      check_status(0, 1, 0, ERR_NONE, name);
      if (mismatch_count != 0) $fatal(1, "%s had %0d mismatches", name, mismatch_count);
      tests_passed = tests_passed + 1;
      $display("TEST %-32s PASS (%0d bytes, %0dx%0dx%0d)",
               name, output_byte_count, cfg_h, cfg_w, cfg_c);
      clear_status();
    end
  endtask

  always @(posedge aclk) begin : output_capture
    integer lane, beat_mismatches, expected_index;
    integer signed observed;
    if (aresetn && capture_enabled && m_axis_tvalid && m_axis_tready) begin
      beat_mismatches = 0;
      for (lane = 0; lane < 4; lane = lane + 1) begin
        expected_index = output_byte_count + lane;
        if (expected_index < cfg_output_bytes) begin
          observed = $signed(m_axis_tdata[lane*8 +: 8]);
          if (observed != $signed(expected_data[expected_index])) begin
            beat_mismatches = beat_mismatches + 1;
            if ((mismatch_count + beat_mismatches) <= 10)
              $display("MISMATCH byte=%0d expected=%0d actual=%0d",
                       expected_index, $signed(expected_data[expected_index]), observed);
          end
        end
      end
      if (m_axis_tlast !== ((output_byte_count + 4) == cfg_output_bytes))
        beat_mismatches = beat_mismatches + 1;
      mismatch_count = mismatch_count + beat_mismatches;
      output_byte_count = output_byte_count + 4;
    end
  end

  initial begin : test_sequence
    integer word_index, c;

    aclk = 0; aresetn = 0;
    s_axi_awaddr = 0; s_axi_awvalid = 0; s_axi_wdata = 0; s_axi_wstrb = 4'b1111;
    s_axi_wvalid = 0; s_axi_bready = 1; s_axi_araddr = 0; s_axi_arvalid = 0;
    s_axi_rready = 1; s_axis_tdata = 0; s_axis_tkeep = 4'b1111;
    s_axis_tlast = 0; s_axis_tvalid = 0; m_axis_tready = 1;
    output_byte_count = 0; mismatch_count = 0; capture_enabled = 0; tests_passed = 0;
    repeat (6) @(posedge aclk); @(negedge aclk); aresetn = 1; repeat (4) @(posedge aclk);

    // All-zero input: every channel's sum is 0, average is 0 regardless of M/N.
    cfg_h = 4; cfg_w = 4; cfg_c = 8; cfg_multiplier = 1; cfg_shift = 4; // 4x4=16=2^4, exact avg
    for (word_index = 0; word_index < 4*4*8; word_index = word_index + 1)
      input_data[word_index] = 8'sd0;
    run_normal("gap_all_zero");

    // Per-channel extremes: even channels pinned to +127, odd channels to -128 at every spatial
    // position -- exercises the accumulate loop's saturating add at the largest magnitudes this
    // config can produce, and since 16 positions with M=1/N=4 is an exact average, the output
    // must recover the original per-channel constant exactly (127 / -128).
    cfg_h = 4; cfg_w = 4; cfg_c = 4; cfg_multiplier = 1; cfg_shift = 4;
    for (word_index = 0; word_index < 4*4*4; word_index = word_index + 1)
      input_data[word_index] = (word_index % 4 % 2 == 0) ? 8'sd127 : -8'sd128;
    run_normal("gap_max_min_extremes");

    // M=1/N=6 accuracy (8x8=64=2^6, the doc's recommended stage-3 config): non-uniform values
    // per channel, verifying the accumulate-then-average pipeline is exactly rounding-error-free
    // for a real (non-constant) distribution, not just a uniform one. IN_CHANNELS=4 (must be a
    // multiple of 4 for OUTPUT_BYTES 4-byte alignment, same as the rest of the protocol).
    cfg_h = 8; cfg_w = 8; cfg_c = 4; cfg_multiplier = 1; cfg_shift = 6;
    for (word_index = 0; word_index < 8*8*4; word_index = word_index + 1)
      input_data[word_index] = $signed(((word_index * 7) % 251) - 125);
    run_normal("gap_accuracy_m1_n6");

    // IN_CHANNELS != OUT_CHANNELS must be rejected (register mapping, HW_SW_Interface_v1.4 §2.2).
    cfg_h = 2; cfg_w = 2; cfg_c = 4; cfg_multiplier = 1; cfg_shift = 2;
    cfg_input_bytes = 2*2*4; cfg_output_bytes = 4;
    clear_status(); axi_write(REG_OPERATION, OP_GLOBAL_AVG_POOL);
    axi_write(REG_INPUT_HEIGHT, cfg_h); axi_write(REG_INPUT_WIDTH, cfg_w);
    axi_write(REG_IN_CHANNELS, cfg_c); axi_write(REG_OUT_CHANNELS, cfg_c + 1);
    axi_write(REG_CONV_CONFIG, 32'd0); axi_write(REG_OUTPUT_SCALE, {16'd2, 16'd1});
    axi_write(REG_INPUT_BYTES, cfg_input_bytes); axi_write(REG_WEIGHT_BYTES, 0);
    axi_write(REG_BIAS_BYTES, 0); axi_write(REG_SKIP_BYTES, 0);
    axi_write(REG_OUTPUT_BYTES, cfg_output_bytes);
    axi_write(REG_CONTROL, 1);
    repeat (10) @(posedge aclk);
    check_status(0, 0, 1, ERR_INVALID_CONFIG, "gap_channel_mismatch_reject");
    tests_passed = tests_passed + 1;
    $display("TEST %-32s PASS", "gap_channel_mismatch_reject");
    clear_status();

    // Recover with a normal GAP op after the rejection, proving the validator reject path
    // doesn't leave the accelerator wedged.
    cfg_h = 2; cfg_w = 2; cfg_c = 4; cfg_multiplier = 1; cfg_shift = 2;
    for (c = 0; c < 16; c = c + 1) input_data[c] = $signed(c - 8);
    run_normal("gap_recovery_after_reject");

    $display("DIRECTED PASS: %0d integration/error checks", tests_passed);
    $finish;
  end

  initial begin
    repeat (1500000) @(posedge aclk);
    $fatal(1, "GAP directed simulation timeout");
  end
endmodule
