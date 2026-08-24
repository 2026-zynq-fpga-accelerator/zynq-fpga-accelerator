`timescale 1ns/1ps

// GAP -> FC integration simulation (HW_SW_Interface_v1.4_DRAFT.md section 4 execution order):
// OP_GLOBAL_AVG_POOL(stage3_block_output 8x8x64 -> gap_output 64) ->
// OP_CONV(kernel=1, H=W=1, IN=64, OUT=12 -> fc_output 12, first 10 valid classes).
// FC's *input* is the RTL's own actual GAP output captured off M_AXIS, chaining through the
// real accelerator pipeline (same idiom as tb_stage2_projection_block.sv), not two isolated
// operation checks.
//
// No external golden vectors exist yet for GAP/FC (unlike the projection work, this is a new
// extension the firmware team hasn't produced test data for) -- golden values are computed here
// directly from the same M/N requantization math the RTL implements (matching
// tb_op_gap_directed.sv's and tb_op_conv_kernel1_directed.sv's self-contained-reference style),
// not copied from any external source.
module tb_gap_fc_chain;
  import accel_pkg::*;

  localparam integer CLK_PERIOD_NS = 10;
  localparam integer BLOCK_H = 8;
  localparam integer BLOCK_W = 8;
  localparam integer BLOCK_C = 64;
  localparam integer BLOCK_BYTES       = BLOCK_H * BLOCK_W * BLOCK_C; // 4096
  localparam integer GAP_OUTPUT_BYTES  = BLOCK_C;                     // 64
  localparam integer FC_OUT_CHANNELS   = 12;                          // 10 classes + 2 zero-pad
  localparam integer FC_WEIGHT_BYTES   = BLOCK_C * FC_OUT_CHANNELS;   // 768
  localparam integer FC_BIAS_WORDS     = FC_OUT_CHANNELS;             // 12
  localparam integer FC_OUTPUT_BYTES   = FC_OUT_CHANNELS;             // 12

  localparam integer GAP_MULTIPLIER = 1;
  localparam integer GAP_SHIFT      = 6;  // log2(8*8) = 6, exact average
  localparam integer FC_MULTIPLIER  = 7;
  localparam integer FC_SHIFT       = 4;

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

  logic signed [7:0]  block_input   [0:BLOCK_BYTES-1];
  logic signed [7:0]  gap_expected  [0:GAP_OUTPUT_BYTES-1];
  logic signed [7:0]  gap_actual    [0:GAP_OUTPUT_BYTES-1];
  logic signed [7:0]  fc_weight     [0:FC_WEIGHT_BYTES-1];
  logic signed [31:0] fc_bias       [0:FC_BIAS_WORDS-1];
  logic signed [7:0]  fc_expected   [0:FC_OUTPUT_BYTES-1];
  logic signed [7:0]  fc_actual     [0:FC_OUTPUT_BYTES-1];

  logic signed [7:0]  stage_capture [0:BLOCK_BYTES-1];
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

  always @(posedge aclk) begin
    if (aresetn && m_axis_tvalid && m_axis_tready) begin
      stage_capture[output_byte_count]   <= m_axis_tdata[7:0];
      stage_capture[output_byte_count+1] <= m_axis_tdata[15:8];
      stage_capture[output_byte_count+2] <= m_axis_tdata[23:16];
      stage_capture[output_byte_count+3] <= m_axis_tdata[31:24];
      output_byte_count <= output_byte_count + 4;
    end
  end

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

  function automatic logic signed [7:0] clamp8(input longint signed value);
    begin
      if (value > 127) clamp8 = 8'sd127;
      else if (value < -128) clamp8 = -8'sd128;
      else clamp8 = value[7:0];
    end
  endfunction

  task automatic build_gap_reference;
    integer c, h, w;
    integer signed acc;
    begin
      for (c = 0; c < BLOCK_C; c = c + 1) begin
        acc = 0;
        for (h = 0; h < BLOCK_H; h = h + 1)
          for (w = 0; w < BLOCK_W; w = w + 1)
            acc = acc + $signed(block_input[((h * BLOCK_W) + w) * BLOCK_C + c]);
        gap_expected[c] = clamp8(requant_ref(acc, GAP_MULTIPLIER, GAP_SHIFT));
      end
    end
  endtask

  // Uses the RTL's own gap_actual as FC's input, per HW_SW_Interface_v1.4_DRAFT.md section 4 --
  // a chained-pipeline check, not an isolated comparison against gap_expected.
  task automatic build_fc_reference;
    integer oc, ic;
    integer signed acc;
    begin
      for (oc = 0; oc < FC_OUT_CHANNELS; oc = oc + 1) begin
        acc = 0;
        for (ic = 0; ic < BLOCK_C; ic = ic + 1)
          acc = acc + ($signed(gap_actual[ic]) * $signed(fc_weight[ic * FC_OUT_CHANNELS + oc]));
        acc = acc + fc_bias[oc];
        fc_expected[oc] = clamp8(requant_ref(acc, FC_MULTIPLIER, FC_SHIFT));
      end
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

  task automatic reset_stage_capture;
    begin output_byte_count = 0; end
  endtask

  task automatic compare_gap_stage(
    input  logic signed [7:0] expected [0:GAP_OUTPUT_BYTES-1],
    output logic signed [7:0] dest [0:GAP_OUTPUT_BYTES-1],
    input  string name,
    output integer mismatches
  );
    integer i;
    begin
      wait (output_byte_count == GAP_OUTPUT_BYTES);
      repeat (6) @(posedge aclk);
      mismatches = 0;
      for (i = 0; i < GAP_OUTPUT_BYTES; i = i + 1) begin
        dest[i] = stage_capture[i];
        if (stage_capture[i] != expected[i]) begin
          mismatches = mismatches + 1;
          if (mismatches <= 10)
            $display("%s MISMATCH byte=%0d expected=%0d actual=%0d",
                     name, i, expected[i], stage_capture[i]);
        end
      end
      $display("%s: %0d bytes, %0d mismatches", name, GAP_OUTPUT_BYTES, mismatches);
    end
  endtask

  task automatic compare_fc_stage(
    input  logic signed [7:0] expected [0:FC_OUTPUT_BYTES-1],
    output logic signed [7:0] dest [0:FC_OUTPUT_BYTES-1],
    input  string name,
    output integer mismatches
  );
    integer i;
    begin
      wait (output_byte_count == FC_OUTPUT_BYTES);
      repeat (6) @(posedge aclk);
      mismatches = 0;
      for (i = 0; i < FC_OUTPUT_BYTES; i = i + 1) begin
        dest[i] = stage_capture[i];
        if (stage_capture[i] != expected[i]) begin
          mismatches = mismatches + 1;
          if (mismatches <= 10)
            $display("%s MISMATCH byte=%0d expected=%0d actual=%0d",
                     name, i, expected[i], stage_capture[i]);
        end
      end
      $display("%s: %0d bytes, %0d mismatches", name, FC_OUTPUT_BYTES, mismatches);
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

  task automatic run_gap;
    integer word_index;
    logic [31:0] packed_word;
    logic [31:0] output_scale;
    begin
      output_scale = {GAP_SHIFT[15:0], GAP_MULTIPLIER[15:0]};
      axi_write(REG_STATUS, 32'h0000_000c);
      axi_write(REG_OPERATION, OP_GLOBAL_AVG_POOL);
      axi_write(REG_INPUT_HEIGHT, BLOCK_H);
      axi_write(REG_INPUT_WIDTH, BLOCK_W);
      axi_write(REG_IN_CHANNELS, BLOCK_C);
      axi_write(REG_OUT_CHANNELS, BLOCK_C);
      axi_write(REG_CONV_CONFIG, 32'd0);
      axi_write(REG_OUTPUT_SCALE, output_scale);
      axi_write(REG_INPUT_BYTES, BLOCK_BYTES);
      axi_write(REG_WEIGHT_BYTES, 0);
      axi_write(REG_BIAS_BYTES, 0);
      axi_write(REG_SKIP_BYTES, 0);
      axi_write(REG_OUTPUT_BYTES, GAP_OUTPUT_BYTES);
      reset_stage_capture();
      axi_write(REG_CONTROL, 1);
      wait (dut.busy);
      for (word_index = 0; word_index < BLOCK_BYTES/4; word_index = word_index + 1) begin
        packed_word = {block_input[word_index*4+3], block_input[word_index*4+2],
                       block_input[word_index*4+1], block_input[word_index*4]};
        send_word(packed_word, word_index == BLOCK_BYTES/4-1);
      end
    end
  endtask

  task automatic run_fc;
    integer word_index;
    logic [31:0] packed_word;
    logic [31:0] output_scale;
    begin
      output_scale = {FC_SHIFT[15:0], FC_MULTIPLIER[15:0]};
      axi_write(REG_STATUS, 32'h0000_000c);
      axi_write(REG_OPERATION, OP_CONV);
      axi_write(REG_INPUT_HEIGHT, 1);
      axi_write(REG_INPUT_WIDTH, 1);
      axi_write(REG_IN_CHANNELS, BLOCK_C);
      axi_write(REG_OUT_CHANNELS, FC_OUT_CHANNELS);
      axi_write(REG_CONV_CONFIG, {7'd0, 1'b0, 8'd0, 8'd1, 8'd1}); // kernel1 stride1 pad0 relu off
      axi_write(REG_OUTPUT_SCALE, output_scale);
      axi_write(REG_INPUT_BYTES, GAP_OUTPUT_BYTES);
      axi_write(REG_WEIGHT_BYTES, FC_WEIGHT_BYTES);
      axi_write(REG_BIAS_BYTES, FC_BIAS_WORDS * 4);
      axi_write(REG_SKIP_BYTES, 0);
      axi_write(REG_OUTPUT_BYTES, FC_OUTPUT_BYTES);
      reset_stage_capture();
      axi_write(REG_CONTROL, 1);
      wait (dut.busy);
      for (word_index = 0; word_index < FC_WEIGHT_BYTES/4; word_index = word_index + 1) begin
        packed_word = {fc_weight[word_index*4+3], fc_weight[word_index*4+2],
                       fc_weight[word_index*4+1], fc_weight[word_index*4]};
        send_word(packed_word, word_index == FC_WEIGHT_BYTES/4-1);
      end
      for (word_index = 0; word_index < FC_BIAS_WORDS; word_index = word_index + 1)
        send_word(fc_bias[word_index], word_index == FC_BIAS_WORDS-1);
      for (word_index = 0; word_index < GAP_OUTPUT_BYTES/4; word_index = word_index + 1) begin
        packed_word = {gap_actual[word_index*4+3], gap_actual[word_index*4+2],
                       gap_actual[word_index*4+1], gap_actual[word_index*4]};
        send_word(packed_word, word_index == GAP_OUTPUT_BYTES/4-1);
      end
    end
  endtask

  initial begin
    integer word_index, ic;
    integer gap_mismatches, fc_mismatches;
    integer expected_argmax, actual_argmax;
    integer signed expected_best, actual_best;

    aclk = 0; aresetn = 0;
    s_axi_awaddr = 0; s_axi_awvalid = 0; s_axi_wdata = 0; s_axi_wstrb = 4'b1111;
    s_axi_wvalid = 0; s_axi_bready = 1; s_axi_araddr = 0; s_axi_arvalid = 0;
    s_axi_rready = 1; s_axis_tdata = 0; s_axis_tkeep = 4'b1111;
    s_axis_tlast = 0; s_axis_tvalid = 0; m_axis_tready = 1;
    output_byte_count = 0;

    for (word_index = 0; word_index < BLOCK_BYTES; word_index = word_index + 1)
      block_input[word_index] = $signed(((word_index * 11) % 251) - 125);
    for (word_index = 0; word_index < FC_WEIGHT_BYTES; word_index = word_index + 1)
      fc_weight[word_index] = $signed((word_index % 13) - 6);
    // Zero-pad the two unused output channels (weight AND bias), per section 3.3.
    for (ic = 0; ic < BLOCK_C; ic = ic + 1) begin
      fc_weight[ic * FC_OUT_CHANNELS + 10] = 8'sd0;
      fc_weight[ic * FC_OUT_CHANNELS + 11] = 8'sd0;
    end
    for (word_index = 0; word_index < 10; word_index = word_index + 1)
      fc_bias[word_index] = $signed(word_index * 5) - 32'sd25;
    fc_bias[10] = 32'sd0;
    fc_bias[11] = 32'sd0;

    build_gap_reference();

    repeat (6) @(posedge aclk); @(negedge aclk); aresetn = 1; repeat (4) @(posedge aclk);

    // ---- Stage A: GAP, stage3 block output -> gap_output ----
    run_gap();
    compare_gap_stage(gap_expected, gap_actual, "gap", gap_mismatches);
    check_no_error("gap");
    if (gap_mismatches != 0) $fatal(1, "gap: %0d mismatches", gap_mismatches);

    // ---- Stage B: FC, chained from the RTL's *actual* gap output ----
    build_fc_reference();
    run_fc();
    compare_fc_stage(fc_expected, fc_actual, "fc", fc_mismatches);
    check_no_error("fc");
    if (fc_mismatches != 0) $fatal(1, "fc: %0d mismatches", fc_mismatches);

    // Zero-padding channels must read back as exactly 0 (section 3.3).
    if ((fc_actual[10] != 8'sd0) || (fc_actual[11] != 8'sd0))
      $fatal(1, "fc zero-padding channels not zero: [10]=%0d [11]=%0d",
             fc_actual[10], fc_actual[11]);

    // Soft sanity check: argmax over the 10 real classes agrees between golden and RTL.
    expected_best = -129; actual_best = -129;
    expected_argmax = 0; actual_argmax = 0;
    for (word_index = 0; word_index < 10; word_index = word_index + 1) begin
      if ($signed(fc_expected[word_index]) > expected_best) begin
        expected_best = $signed(fc_expected[word_index]);
        expected_argmax = word_index;
      end
      if ($signed(fc_actual[word_index]) > actual_best) begin
        actual_best = $signed(fc_actual[word_index]);
        actual_argmax = word_index;
      end
    end
    if (expected_argmax != actual_argmax)
      $fatal(1, "argmax mismatch expected=%0d actual=%0d", expected_argmax, actual_argmax);
    $display("ARGMAX PASS: class=%0d score=%0d", actual_argmax, actual_best);

    $display("GAP FC CHAIN PASS: gap=0/%0d fc=0/%0d mismatches",
             GAP_OUTPUT_BYTES, FC_OUTPUT_BYTES);
    $finish;
  end

  initial begin
    repeat (5000000) @(posedge aclk);
    $fatal(1, "GAP-FC chain simulation timeout");
  end
endmodule
