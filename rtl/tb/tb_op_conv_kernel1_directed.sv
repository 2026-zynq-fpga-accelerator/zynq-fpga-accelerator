`timescale 1ns/1ps

// KERNEL_SIZE=1 directed tests (Stage 3 R5 projection/downsample support).
// Kernel=3 correctness is already covered exhaustively (incl. internal signal
// tracing) by tb_op_conv_directed.sv; this file only needs to prove the new
// kernel=1 path end-to-end against a software reference, via the same
// external AXI-Lite/AXI-Stream interface real firmware uses.
module tb_op_conv_kernel1_directed;
  import accel_pkg::*;

  localparam integer CLK_PERIOD_NS = 10;
  localparam integer MAX_INPUT_BYTES  = 1024;
  localparam integer MAX_WEIGHT_BYTES = 1024;
  localparam integer MAX_OUTPUT_BYTES = 512;

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

  logic signed [7:0] input_data  [0:MAX_INPUT_BYTES-1];
  logic signed [7:0] weight_data [0:MAX_WEIGHT_BYTES-1];
  logic signed [31:0] bias_data  [0:63];
  logic signed [7:0] expected_data [0:MAX_OUTPUT_BYTES-1];

  integer cfg_h, cfg_w, cfg_ic, cfg_oc;
  integer cfg_stride, cfg_padding, cfg_relu, cfg_multiplier, cfg_shift;
  integer cfg_input_bytes, cfg_weight_bytes, cfg_bias_bytes, cfg_output_bytes;
  integer output_byte_count, mismatch_count, tests_passed;
  logic capture_enabled;

  resnet_accel_top #(
    .MAX_WEIGHT_WORDS(256), .MAX_BIAS_WORDS(32),
    .MAX_INPUT_WORDS(256), .MAX_OUTPUT_WORDS(128)
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

  function automatic integer signed sat_add_ref(input longint signed a, input longint signed b);
    longint signed wide;
    begin
      wide = a + b;
      if (wide > 64'sd2147483647) sat_add_ref = 32'sh7fff_ffff;
      else if (wide < -64'sd2147483648) sat_add_ref = 32'sh8000_0000;
      else sat_add_ref = wide[31:0];
    end
  endfunction

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
      if ((cfg_relu != 0) && (value < 0)) value = 0;
      if (value > 127) value = 127;
      else if (value < -128) value = -128;
      postprocess_ref = value[7:0];
    end
  endfunction

  task automatic set_shape(
    input integer h, input integer w, input integer ic, input integer oc,
    input integer stride_value, input integer padding_value,
    input integer relu_value, input integer multiplier_value, input integer shift_value
  );
    integer out_h, out_w;
    begin
      cfg_h = h; cfg_w = w; cfg_ic = ic; cfg_oc = oc;
      cfg_stride = stride_value; cfg_padding = padding_value;
      cfg_relu = relu_value; cfg_multiplier = multiplier_value; cfg_shift = shift_value;
      // KERNEL_SIZE=1 case of output = floor((padded - kernel)/stride) + 1
      out_h = ((cfg_h + 2*cfg_padding - 1) / cfg_stride) + 1;
      out_w = ((cfg_w + 2*cfg_padding - 1) / cfg_stride) + 1;
      cfg_input_bytes  = cfg_h * cfg_w * cfg_ic;
      cfg_weight_bytes = cfg_ic * cfg_oc;   // kernel_size^2 = 1
      cfg_bias_bytes   = 4 * cfg_oc;
      cfg_output_bytes = out_h * out_w * cfg_oc;
    end
  endtask

  task automatic build_reference;
    integer index, out_h, out_w, oh, ow, oc, ic, iy, ix;
    integer input_index, weight_index;
    integer signed acc, input_value, weight_value;
    begin
      out_h = ((cfg_h + 2*cfg_padding - 1) / cfg_stride) + 1;
      out_w = ((cfg_w + 2*cfg_padding - 1) / cfg_stride) + 1;
      index = 0;
      for (oh = 0; oh < out_h; oh = oh + 1)
        for (ow = 0; ow < out_w; ow = ow + 1)
          for (oc = 0; oc < cfg_oc; oc = oc + 1) begin
            acc = 0;
            iy = oh * cfg_stride - cfg_padding;
            ix = ow * cfg_stride - cfg_padding;
            for (ic = 0; ic < cfg_ic; ic = ic + 1) begin
              if ((iy < 0) || (iy >= cfg_h) || (ix < 0) || (ix >= cfg_w))
                input_value = 0;
              else begin
                input_index = ((iy * cfg_w) + ix) * cfg_ic + ic;
                input_value = $signed(input_data[input_index]);
              end
              weight_index = ic * cfg_oc + oc;
              weight_value = $signed(weight_data[weight_index]);
              acc = sat_add_ref(acc, input_value * weight_value);
            end
            acc = sat_add_ref(acc, bias_data[oc]);
            expected_data[index] = postprocess_ref(acc);
            index = index + 1;
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

  task automatic send_normal_packets;
    integer word_index;
    logic [31:0] packed_word;
    begin
      for (word_index = 0; word_index < cfg_weight_bytes/4; word_index = word_index + 1) begin
        packed_word = {weight_data[word_index*4+3], weight_data[word_index*4+2],
                  weight_data[word_index*4+1], weight_data[word_index*4]};
        send_word(packed_word, word_index == cfg_weight_bytes/4-1);
      end
      for (word_index = 0; word_index < cfg_bias_bytes/4; word_index = word_index + 1)
        send_word(bias_data[word_index], word_index == cfg_bias_bytes/4-1);
      for (word_index = 0; word_index < cfg_input_bytes/4; word_index = word_index + 1) begin
        packed_word = {input_data[word_index*4+3], input_data[word_index*4+2],
                  input_data[word_index*4+1], input_data[word_index*4]};
        send_word(packed_word, word_index == cfg_input_bytes/4-1);
      end
    end
  endtask

  task automatic program_config;
    logic [31:0] conv_config, output_scale;
    begin
      conv_config = {7'd0, cfg_relu[0], cfg_padding[7:0], cfg_stride[7:0], 8'd1};
      output_scale = {cfg_shift[15:0], cfg_multiplier[15:0]};
      axi_write(REG_OPERATION, 0); axi_write(REG_INPUT_HEIGHT, cfg_h);
      axi_write(REG_INPUT_WIDTH, cfg_w); axi_write(REG_IN_CHANNELS, cfg_ic);
      axi_write(REG_OUT_CHANNELS, cfg_oc); axi_write(REG_CONV_CONFIG, conv_config);
      axi_write(REG_OUTPUT_SCALE, output_scale); axi_write(REG_INPUT_BYTES, cfg_input_bytes);
      axi_write(REG_WEIGHT_BYTES, cfg_weight_bytes); axi_write(REG_BIAS_BYTES, cfg_bias_bytes);
      axi_write(REG_SKIP_BYTES, 0); axi_write(REG_OUTPUT_BYTES, cfg_output_bytes);
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
      send_normal_packets();
      wait (output_byte_count == cfg_output_bytes);
      capture_enabled = 0;
      repeat (6) @(posedge aclk);
      check_status(0, 1, 0, ERR_NONE, name);
      if (mismatch_count != 0) $fatal(1, "%s had %0d mismatches", name, mismatch_count);
      tests_passed = tests_passed + 1;
      $display("TEST %-32s PASS (%0d bytes, %0dx%0dx%0d->%0d stride=%0d)",
               name, output_byte_count, cfg_h, cfg_w, cfg_ic, cfg_oc, cfg_stride);
      clear_status();
    end
  endtask

  always @(posedge aclk) begin : output_capture
    integer lane, beat_mismatches, expected_index;
    integer signed observed;
    if (aresetn && capture_enabled && m_axis_tvalid && m_axis_tready) begin
      beat_mismatches = 0;
      if (m_axis_tkeep !== 4'b1111) beat_mismatches = beat_mismatches + 1;
      for (lane = 0; lane < 4; lane = lane + 1) begin
        expected_index = output_byte_count + lane;
        observed = $signed(m_axis_tdata[lane*8 +: 8]);
        if (observed != $signed(expected_data[expected_index])) begin
          beat_mismatches = beat_mismatches + 1;
          if ((mismatch_count + beat_mismatches) <= 10)
            $display("MISMATCH byte=%0d expected=%0d actual=%0d",
                     expected_index, $signed(expected_data[expected_index]), observed);
        end
      end
      if (m_axis_tlast !== ((output_byte_count + 4) == cfg_output_bytes))
        beat_mismatches = beat_mismatches + 1;
      mismatch_count = mismatch_count + beat_mismatches;
      output_byte_count = output_byte_count + 4;
    end
  end

  initial begin : test_sequence
    integer word_index;

    aclk = 0; aresetn = 0;
    s_axi_awaddr = 0; s_axi_awvalid = 0; s_axi_wdata = 0; s_axi_wstrb = 4'b1111;
    s_axi_wvalid = 0; s_axi_bready = 1; s_axi_araddr = 0; s_axi_arvalid = 0;
    s_axi_rready = 1; s_axis_tdata = 0; s_axis_tkeep = 4'b1111;
    s_axis_tlast = 0; s_axis_tvalid = 0; m_axis_tready = 1;
    output_byte_count = 0; mismatch_count = 0; capture_enabled = 0; tests_passed = 0;
    repeat (6) @(posedge aclk); @(negedge aclk); aresetn = 1; repeat (4) @(posedge aclk);

    // Positive/negative mixed input, stride=1, padding=0 (baseline kernel=1 correctness).
    set_shape(4, 4, 4, 4, 1, 0, 1, 1, 0);
    for (word_index = 0; word_index < cfg_input_bytes; word_index = word_index + 1)
      input_data[word_index] = $signed((word_index % 9) - 4);
    for (word_index = 0; word_index < cfg_weight_bytes; word_index = word_index + 1)
      weight_data[word_index] = $signed((word_index % 7) - 3);
    bias_data[0] = -32'sd9; bias_data[1] = 32'sd7; bias_data[2] = -32'sd5; bias_data[3] = 32'sd11;
    run_normal("kernel1_positive_negative_basic");

    // Extreme values driving MAC/postprocess saturation with only in_channels taps
    // (no 3x3 accumulation window) to prove last_tap fires after the first row/col.
    set_shape(4, 4, 4, 4, 1, 0, 0, 1, 0);
    for (word_index = 0; word_index < cfg_input_bytes; word_index = word_index + 1)
      input_data[word_index] = (word_index % 2 == 0) ? -8'sd128 : 8'sd127;
    for (word_index = 0; word_index < cfg_weight_bytes; word_index = word_index + 1)
      weight_data[word_index] = (word_index % 2 == 0) ? 8'sd127 : -8'sd128;
    bias_data[0] = 32'sh7fff_ffff; bias_data[1] = 32'sh8000_0000;
    bias_data[2] = 32'sd0; bias_data[3] = -32'sd1;
    run_normal("kernel1_saturation_extremes");

    // stride=2, padding=0: the actual projection/downsample combination
    // (matches the decision doc's minimal byte-count sanity config).
    set_shape(4, 4, 4, 8, 2, 0, 1, 1, 0);
    for (word_index = 0; word_index < cfg_input_bytes; word_index = word_index + 1)
      input_data[word_index] = $signed((word_index % 11) - 5);
    for (word_index = 0; word_index < cfg_weight_bytes; word_index = word_index + 1)
      weight_data[word_index] = $signed((word_index % 5) - 2);
    for (word_index = 0; word_index < 8; word_index = word_index + 1)
      bias_data[word_index] = $signed(word_index) - 32'sd4;
    run_normal("kernel1_stride2_downsample");

    // Realistic ResNet-20 stage-3 channel widths (16->32) at reduced spatial
    // size, stride=2, padding=0.
    set_shape(4, 4, 16, 32, 2, 0, 1, 3, 2);
    for (word_index = 0; word_index < cfg_input_bytes; word_index = word_index + 1)
      input_data[word_index] = $signed((word_index % 13) - 6);
    for (word_index = 0; word_index < cfg_weight_bytes; word_index = word_index + 1)
      weight_data[word_index] = $signed((word_index % 9) - 4);
    for (word_index = 0; word_index < 32; word_index = word_index + 1)
      bias_data[word_index] = $signed(word_index * 3) - 32'sd48;
    run_normal("kernel1_projection_16to32_stride2");

    // FC-shaped: H=W=1 spatial input (HW_SW_Interface_v1.4_DRAFT.md section 3 -- FC reuses
    // OP_CONV(kernel=1) with no new RTL). This exact H=W=1 combination was never exercised by
    // the kernel1 tests above (all used H=W>=4). OUT_CHANNELS=12 matches the doc's real usage
    // (10 classes + 2 zero-padding channels for 4-byte output alignment); channels 10/11 use
    // zero weight/bias so their output is independently verifiable as exactly 0.
    set_shape(1, 1, 64, 12, 1, 0, 0, 5, 3);
    for (word_index = 0; word_index < cfg_input_bytes; word_index = word_index + 1)
      input_data[word_index] = $signed((word_index % 17) - 8);
    for (word_index = 0; word_index < cfg_weight_bytes; word_index = word_index + 1)
      weight_data[word_index] = $signed((word_index % 11) - 5);
    for (word_index = 0; word_index < 64; word_index = word_index + 1) begin
      weight_data[word_index * 12 + 10] = 8'sd0;
      weight_data[word_index * 12 + 11] = 8'sd0;
    end
    for (word_index = 0; word_index < 10; word_index = word_index + 1)
      bias_data[word_index] = $signed(word_index * 7) - 32'sd35;
    bias_data[10] = 32'sd0;
    bias_data[11] = 32'sd0;
    run_normal("fc_h1w1_kernel1_64to12");

    $display("DIRECTED PASS: %0d integration/error checks", tests_passed);
    $finish;
  end

  initial begin
    repeat (1500000) @(posedge aclk);
    $fatal(1, "Kernel=1 directed simulation timeout");
  end
endmodule
