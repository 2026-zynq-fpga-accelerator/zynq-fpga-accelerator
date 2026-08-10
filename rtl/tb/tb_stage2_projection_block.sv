`timescale 1ns/1ps

// Stage 3 (R5: 1x1 projection/downsample) integration simulation
// (STAGE3_RTL_REQUEST.md §3 / STAGE3_DECISION_STATUS_v2.md §2-1): chains
// OP_CONV(conv1, 3x3 s2 p1 ReLU ON, 16->32, 32x32->16x16) ->
// OP_CONV(conv2, 3x3 s1 p1 ReLU OFF, 32->32, 16x16->16x16) ->
// OP_CONV(shortcut, 1x1 s2 p0 ReLU OFF, 16->32, 32x32->16x16) ->
// OP_RESIDUAL_ADD(MAIN=conv2 output, SKIP=shortcut output, Final ReLU ON)
// against the actual RTL for the 5-buffer projection BasicBlock layout
// (Buffer A/B/C/D/E per the decision doc). Conv2's *input* is the RTL's own
// actual conv1 output, and the residual's MAIN/SKIP are the RTL's own actual
// conv2/shortcut outputs -- a genuine chained-pipeline check across all four
// checkpoints, not four isolated comparisons.
//
// Golden data is not recomputed here: it comes from the firmware team's
// already-verified data/test_vectors/stage2_basicblock_projection/ (real
// BN-folded/quantized PyTorch model, shortcut output_scale forced to match
// conv2's so residual add needs no separate rescale), converted to
// $readmemh-compatible hex by scripts/vector_gen/generate_stage2_projection_vector.py.
module tb_stage2_projection_block;
  import accel_pkg::*;

  localparam integer CLK_PERIOD_NS = 10;
  localparam integer INPUT_BYTES   = 16384; // Buffer A: 32x32x16
  localparam integer FEATURE_BYTES = 8192;  // Buffers B/C/D/E: 16x16x32
  localparam integer CONV1_WEIGHT_BYTES    = 4608; // 3x3 * 16 * 32
  localparam integer CONV2_WEIGHT_BYTES    = 9216; // 3x3 * 32 * 32
  localparam integer SHORTCUT_WEIGHT_BYTES = 512;  // 1x1 * 16 * 32
  localparam integer BIAS_WORDS = 32;

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

  logic [7:0]  conv1_input    [0:INPUT_BYTES-1];
  logic [7:0]  conv1_weight   [0:CONV1_WEIGHT_BYTES-1];
  logic [31:0] conv1_bias     [0:BIAS_WORDS-1];
  logic [7:0]  conv1_expected [0:FEATURE_BYTES-1];
  logic [7:0]  conv1_actual   [0:FEATURE_BYTES-1];

  logic [7:0]  conv2_weight   [0:CONV2_WEIGHT_BYTES-1];
  logic [31:0] conv2_bias     [0:BIAS_WORDS-1];
  logic [7:0]  conv2_expected [0:FEATURE_BYTES-1];
  logic [7:0]  conv2_actual   [0:FEATURE_BYTES-1];

  logic [7:0]  shortcut_weight   [0:SHORTCUT_WEIGHT_BYTES-1];
  logic [31:0] shortcut_bias     [0:BIAS_WORDS-1];
  logic [7:0]  shortcut_expected [0:FEATURE_BYTES-1];
  logic [7:0]  shortcut_actual   [0:FEATURE_BYTES-1];

  logic [7:0]  final_expected [0:FEATURE_BYTES-1];
  logic [7:0]  final_actual   [0:FEATURE_BYTES-1];

  logic [7:0]  stage_capture  [0:INPUT_BYTES-1];
  integer output_byte_count;

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

  // Same idiom as tb_stage2_identity_block.sv: sampled directly in the triggered
  // always @(posedge aclk) block to see the pre-edge (correct) DUT state.
  always @(posedge aclk) begin
    if (aresetn && m_axis_tvalid && m_axis_tready) begin
      stage_capture[output_byte_count]   <= m_axis_tdata[7:0];
      stage_capture[output_byte_count+1] <= m_axis_tdata[15:8];
      stage_capture[output_byte_count+2] <= m_axis_tdata[23:16];
      stage_capture[output_byte_count+3] <= m_axis_tdata[31:24];
      output_byte_count <= output_byte_count + 4;
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

  task automatic reset_stage_capture;
    begin output_byte_count = 0; end
  endtask

  task automatic compare_stage(
    input  logic [7:0] expected [0:FEATURE_BYTES-1],
    output logic [7:0] dest [0:FEATURE_BYTES-1],
    input  string name,
    output integer mismatches
  );
    integer i;
    integer signed actual_value, expected_value;
    begin
      wait (output_byte_count == FEATURE_BYTES);
      repeat (6) @(posedge aclk);
      mismatches = 0;
      for (i = 0; i < FEATURE_BYTES; i = i + 1) begin
        dest[i] = stage_capture[i];
        actual_value = $signed(stage_capture[i]);
        expected_value = $signed(expected[i]);
        if (actual_value != expected_value) begin
          mismatches = mismatches + 1;
          if (mismatches <= 10)
            $display("%s MISMATCH byte=%0d expected=%0d actual=%0d",
                     name, i, expected_value, actual_value);
        end
      end
      $display("%s: %0d bytes, %0d mismatches", name, FEATURE_BYTES, mismatches);
    end
  endtask

  // ---- Conv1: 32x32x16 -> 16x16x32, 3x3 stride2 padding1 ----
  task automatic run_conv1(input logic relu_enable, input integer multiplier_m, input integer shift_n);
    integer word_index;
    logic [31:0] packed_word;
    begin
      axi_write(REG_STATUS, 32'h0000_000c);
      axi_write(REG_OPERATION, OP_CONV);
      axi_write(REG_INPUT_HEIGHT, 32); axi_write(REG_INPUT_WIDTH, 32);
      axi_write(REG_IN_CHANNELS, 16);  axi_write(REG_OUT_CHANNELS, 32);
      axi_write(REG_CONV_CONFIG, {7'd0, relu_enable, 8'd1, 8'd2, 8'd3}); // kernel3 stride2 pad1
      axi_write(REG_OUTPUT_SCALE, {shift_n[15:0], multiplier_m[15:0]});
      axi_write(REG_INPUT_BYTES, INPUT_BYTES);
      axi_write(REG_WEIGHT_BYTES, CONV1_WEIGHT_BYTES);
      axi_write(REG_BIAS_BYTES, BIAS_WORDS * 4);
      axi_write(REG_SKIP_BYTES, 0);
      axi_write(REG_OUTPUT_BYTES, FEATURE_BYTES);
      reset_stage_capture();
      axi_write(REG_CONTROL, 1);
      wait (dut.busy);
      for (word_index = 0; word_index < CONV1_WEIGHT_BYTES/4; word_index = word_index + 1) begin
        packed_word = {conv1_weight[word_index*4+3], conv1_weight[word_index*4+2],
                       conv1_weight[word_index*4+1], conv1_weight[word_index*4]};
        send_word(packed_word, word_index == CONV1_WEIGHT_BYTES/4-1);
      end
      for (word_index = 0; word_index < BIAS_WORDS; word_index = word_index + 1)
        send_word(conv1_bias[word_index], word_index == BIAS_WORDS-1);
      for (word_index = 0; word_index < INPUT_BYTES/4; word_index = word_index + 1) begin
        packed_word = {conv1_input[word_index*4+3], conv1_input[word_index*4+2],
                       conv1_input[word_index*4+1], conv1_input[word_index*4]};
        send_word(packed_word, word_index == INPUT_BYTES/4-1);
      end
    end
  endtask

  // ---- Conv2: RTL's actual conv1 output, 16x16x32 -> 16x16x32, 3x3 stride1 padding1 ----
  task automatic run_conv2(input logic relu_enable, input integer multiplier_m, input integer shift_n);
    integer word_index;
    logic [31:0] packed_word;
    begin
      axi_write(REG_STATUS, 32'h0000_000c);
      axi_write(REG_OPERATION, OP_CONV);
      axi_write(REG_INPUT_HEIGHT, 16); axi_write(REG_INPUT_WIDTH, 16);
      axi_write(REG_IN_CHANNELS, 32);  axi_write(REG_OUT_CHANNELS, 32);
      axi_write(REG_CONV_CONFIG, {7'd0, relu_enable, 8'd1, 8'd1, 8'd3}); // kernel3 stride1 pad1
      axi_write(REG_OUTPUT_SCALE, {shift_n[15:0], multiplier_m[15:0]});
      axi_write(REG_INPUT_BYTES, FEATURE_BYTES);
      axi_write(REG_WEIGHT_BYTES, CONV2_WEIGHT_BYTES);
      axi_write(REG_BIAS_BYTES, BIAS_WORDS * 4);
      axi_write(REG_SKIP_BYTES, 0);
      axi_write(REG_OUTPUT_BYTES, FEATURE_BYTES);
      reset_stage_capture();
      axi_write(REG_CONTROL, 1);
      wait (dut.busy);
      for (word_index = 0; word_index < CONV2_WEIGHT_BYTES/4; word_index = word_index + 1) begin
        packed_word = {conv2_weight[word_index*4+3], conv2_weight[word_index*4+2],
                       conv2_weight[word_index*4+1], conv2_weight[word_index*4]};
        send_word(packed_word, word_index == CONV2_WEIGHT_BYTES/4-1);
      end
      for (word_index = 0; word_index < BIAS_WORDS; word_index = word_index + 1)
        send_word(conv2_bias[word_index], word_index == BIAS_WORDS-1);
      for (word_index = 0; word_index < FEATURE_BYTES/4; word_index = word_index + 1) begin
        packed_word = {conv1_actual[word_index*4+3], conv1_actual[word_index*4+2],
                       conv1_actual[word_index*4+1], conv1_actual[word_index*4]};
        send_word(packed_word, word_index == FEATURE_BYTES/4-1);
      end
    end
  endtask

  // ---- Shortcut projection: block's original input, 32x32x16 -> 16x16x32, 1x1 stride2 padding0 ----
  task automatic run_shortcut(input logic relu_enable, input integer multiplier_m, input integer shift_n);
    integer word_index;
    logic [31:0] packed_word;
    begin
      axi_write(REG_STATUS, 32'h0000_000c);
      axi_write(REG_OPERATION, OP_CONV);
      axi_write(REG_INPUT_HEIGHT, 32); axi_write(REG_INPUT_WIDTH, 32);
      axi_write(REG_IN_CHANNELS, 16);  axi_write(REG_OUT_CHANNELS, 32);
      axi_write(REG_CONV_CONFIG, {7'd0, relu_enable, 8'd0, 8'd2, 8'd1}); // kernel1 stride2 pad0
      axi_write(REG_OUTPUT_SCALE, {shift_n[15:0], multiplier_m[15:0]});
      axi_write(REG_INPUT_BYTES, INPUT_BYTES);
      axi_write(REG_WEIGHT_BYTES, SHORTCUT_WEIGHT_BYTES);
      axi_write(REG_BIAS_BYTES, BIAS_WORDS * 4);
      axi_write(REG_SKIP_BYTES, 0);
      axi_write(REG_OUTPUT_BYTES, FEATURE_BYTES);
      reset_stage_capture();
      axi_write(REG_CONTROL, 1);
      wait (dut.busy);
      for (word_index = 0; word_index < SHORTCUT_WEIGHT_BYTES/4; word_index = word_index + 1) begin
        packed_word = {shortcut_weight[word_index*4+3], shortcut_weight[word_index*4+2],
                       shortcut_weight[word_index*4+1], shortcut_weight[word_index*4]};
        send_word(packed_word, word_index == SHORTCUT_WEIGHT_BYTES/4-1);
      end
      for (word_index = 0; word_index < BIAS_WORDS; word_index = word_index + 1)
        send_word(shortcut_bias[word_index], word_index == BIAS_WORDS-1);
      for (word_index = 0; word_index < INPUT_BYTES/4; word_index = word_index + 1) begin
        packed_word = {conv1_input[word_index*4+3], conv1_input[word_index*4+2],
                       conv1_input[word_index*4+1], conv1_input[word_index*4]};
        send_word(packed_word, word_index == INPUT_BYTES/4-1);
      end
    end
  endtask

  task automatic run_residual(
    input logic [7:0] main_bytes [0:FEATURE_BYTES-1],
    input logic [7:0] skip_bytes [0:FEATURE_BYTES-1]
  );
    integer word_index;
    logic [31:0] packed_word;
    begin
      axi_write(REG_STATUS, 32'h0000_000c);
      axi_write(REG_OPERATION, OP_RESIDUAL_ADD);
      axi_write(REG_INPUT_HEIGHT, 16); axi_write(REG_INPUT_WIDTH, 16);
      axi_write(REG_IN_CHANNELS, 32);  axi_write(REG_OUT_CHANNELS, 32);
      axi_write(REG_CONV_CONFIG, {7'd0, 1'b1, 24'd0}); // Final ReLU ON (BasicBlock.forward)
      axi_write(REG_OUTPUT_SCALE, 0);
      axi_write(REG_INPUT_BYTES, FEATURE_BYTES);
      axi_write(REG_WEIGHT_BYTES, 0);
      axi_write(REG_BIAS_BYTES, 0);
      axi_write(REG_SKIP_BYTES, FEATURE_BYTES);
      axi_write(REG_OUTPUT_BYTES, FEATURE_BYTES);
      reset_stage_capture();
      axi_write(REG_CONTROL, 1);
      wait (dut.busy);
      for (word_index = 0; word_index < FEATURE_BYTES/4; word_index = word_index + 1) begin
        packed_word = {main_bytes[word_index*4+3], main_bytes[word_index*4+2],
                       main_bytes[word_index*4+1], main_bytes[word_index*4]};
        send_word(packed_word, word_index == FEATURE_BYTES/4-1);
      end
      for (word_index = 0; word_index < FEATURE_BYTES/4; word_index = word_index + 1) begin
        packed_word = {skip_bytes[word_index*4+3], skip_bytes[word_index*4+2],
                       skip_bytes[word_index*4+1], skip_bytes[word_index*4]};
        send_word(packed_word, word_index == FEATURE_BYTES/4-1);
      end
    end
  endtask

  task automatic check_no_error(input string name);
    logic [31:0] status, code;
    begin
      axi_read(REG_STATUS, status);
      axi_read(REG_ERROR_CODE, code);
      if ((status[3] !== 1'b0) || (code !== ERR_NONE))
        $fatal(1, "%s unexpected error STATUS=%08x CODE=%0d", name, status, code);
    end
  endtask

  initial begin
    integer conv1_mismatches, conv2_mismatches, shortcut_mismatches, residual_mismatches;
    aclk = 0; aresetn = 0;
    s_axi_awaddr = 0; s_axi_awvalid = 0; s_axi_wdata = 0; s_axi_wstrb = 4'b1111;
    s_axi_wvalid = 0; s_axi_bready = 1; s_axi_araddr = 0; s_axi_arvalid = 0;
    s_axi_rready = 1; s_axis_tdata = 0; s_axis_tkeep = 4'b1111;
    s_axis_tlast = 0; s_axis_tvalid = 0; m_axis_tready = 1;
    output_byte_count = 0;

    $readmemh("vectors/stage2_projection_block/conv1_input.hex", conv1_input);
    $readmemh("vectors/stage2_projection_block/conv1_weight.hex", conv1_weight);
    $readmemh("vectors/stage2_projection_block/conv1_bias.hex", conv1_bias);
    $readmemh("vectors/stage2_projection_block/conv1_expected.hex", conv1_expected);
    $readmemh("vectors/stage2_projection_block/conv2_weight.hex", conv2_weight);
    $readmemh("vectors/stage2_projection_block/conv2_bias.hex", conv2_bias);
    $readmemh("vectors/stage2_projection_block/conv2_expected.hex", conv2_expected);
    $readmemh("vectors/stage2_projection_block/shortcut_weight.hex", shortcut_weight);
    $readmemh("vectors/stage2_projection_block/shortcut_bias.hex", shortcut_bias);
    $readmemh("vectors/stage2_projection_block/shortcut_expected.hex", shortcut_expected);
    $readmemh("vectors/stage2_projection_block/final_expected.hex", final_expected);

    repeat (6) @(posedge aclk); @(negedge aclk); aresetn = 1; repeat (4) @(posedge aclk);

    // ---- A: Conv1, block input -> ReLU'd 16x16x32 intermediate ----
    run_conv1(1'b1, 54874, 25);
    compare_stage(conv1_expected, conv1_actual, "conv1", conv1_mismatches);
    check_no_error("conv1");
    if (conv1_mismatches != 0) $fatal(1, "conv1: %0d mismatches", conv1_mismatches);

    // ---- B: Conv2, chained from the RTL's *actual* conv1 output, ReLU OFF ----
    run_conv2(1'b0, 59827, 26);
    compare_stage(conv2_expected, conv2_actual, "conv2", conv2_mismatches);
    check_no_error("conv2");
    if (conv2_mismatches != 0) $fatal(1, "conv2: %0d mismatches", conv2_mismatches);

    // ---- C: Shortcut, block's original input, KERNEL_SIZE=1 ----
    run_shortcut(1'b0, 55289, 23);
    compare_stage(shortcut_expected, shortcut_actual, "shortcut", shortcut_mismatches);
    check_no_error("shortcut");
    if (shortcut_mismatches != 0) $fatal(1, "shortcut: %0d mismatches", shortcut_mismatches);

    // ---- D/E: Residual, MAIN = RTL's actual conv2 output, SKIP = RTL's actual shortcut output ----
    run_residual(conv2_actual, shortcut_actual);
    compare_stage(final_expected, final_actual, "residual", residual_mismatches);
    check_no_error("residual");
    if (residual_mismatches != 0) $fatal(1, "residual: %0d mismatches", residual_mismatches);

    $display("STAGE3 PROJECTION BLOCK PASS: conv1=0/%0d conv2=0/%0d shortcut=0/%0d residual=0/%0d mismatches",
             FEATURE_BYTES, FEATURE_BYTES, FEATURE_BYTES, FEATURE_BYTES);
    $finish;
  end

  initial begin
    repeat (30000000) @(posedge aclk);
    $fatal(1, "Stage-3 projection block simulation timeout");
  end
endmodule
