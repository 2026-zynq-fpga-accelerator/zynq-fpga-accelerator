`timescale 1ns/1ps

module tb_op_conv_directed;
  import accel_pkg::*;

  localparam integer CLK_PERIOD_NS = 10;
  localparam integer MAX_INPUT_BYTES = 64;
  localparam integer MAX_WEIGHT_BYTES = 144;
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
  logic signed [7:0] weight_data [0:MAX_WEIGHT_BYTES-1];
  logic signed [31:0] bias_data [0:7];
  logic signed [7:0] expected_data [0:MAX_OUTPUT_BYTES-1];

  integer cfg_h, cfg_w, cfg_ic, cfg_oc;
  integer cfg_stride, cfg_padding, cfg_relu, cfg_multiplier, cfg_shift;
  integer cfg_input_bytes, cfg_weight_bytes, cfg_bias_bytes, cfg_output_bytes;
  integer output_byte_count, mismatch_count, tests_passed;
  integer expected_write_element;
  logic capture_enabled;
  logic postprocess_monitor_enabled;
  logic previous_output_we;
  logic last_write_pending;
  logic last_output_write_seen;
  logic address_trace_seen;
  logic address_padding_seen, address_valid_seen;
  logic address_stride1_seen, address_stride2_seen;
  logic address_top_seen, address_left_seen, address_right_seen, address_bottom_seen;
  logic address_center_seen, address_ic_nonzero_seen, address_oc_nonzero_seen;
  logic address_kw_nonzero_seen, address_kh_nonzero_seen;
  logic [3:0] address_input_lanes_seen;
  logic [3:0] address_weight_lanes_seen;
  logic address_input_word_cross_seen, address_weight_word_cross_seen;
  logic address_last_tap_seen, address_last_output_seen;

  resnet_accel_top #(
    .MAX_WEIGHT_WORDS(64), .MAX_BIAS_WORDS(8),
    .MAX_INPUT_WORDS(32), .MAX_OUTPUT_WORDS(32)
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

  task automatic initialize_pattern(input integer pattern);
    integer i;
    begin
      for (i = 0; i < MAX_INPUT_BYTES; i = i + 1)
        input_data[i] = (pattern == 0) ? 8'sd1 : $signed((i % 9) - 4);
      for (i = 0; i < MAX_WEIGHT_BYTES; i = i + 1)
        weight_data[i] = (pattern == 0) ? 8'sd1 : $signed((i % 7) - 3);
      bias_data[0] = (pattern == 0) ? 32'sd0 : -32'sd9;
      bias_data[1] = (pattern == 0) ? 32'sd0 :  32'sd7;
      bias_data[2] = (pattern == 0) ? 32'sd0 : -32'sd5;
      bias_data[3] = (pattern == 0) ? 32'sd0 :  32'sd11;
      for (i = 4; i < 8; i = i + 1)
        bias_data[i] = 32'sd0;
    end
  endtask

  task automatic set_shape(
    input integer stride_value, input integer padding_value,
    input integer relu_value, input integer multiplier_value,
    input integer shift_value
  );
    integer out_h, out_w;
    begin
      cfg_h = 4; cfg_w = 4; cfg_ic = 4; cfg_oc = 4;
      cfg_stride = stride_value; cfg_padding = padding_value;
      cfg_relu = relu_value; cfg_multiplier = multiplier_value; cfg_shift = shift_value;
      out_h = ((cfg_h + 2*cfg_padding - 3) / cfg_stride) + 1;
      out_w = ((cfg_w + 2*cfg_padding - 3) / cfg_stride) + 1;
      cfg_input_bytes = cfg_h * cfg_w * cfg_ic;
      cfg_weight_bytes = 9 * cfg_ic * cfg_oc;
      cfg_bias_bytes = 4 * cfg_oc;
      cfg_output_bytes = out_h * out_w * cfg_oc;
    end
  endtask

  task automatic build_reference;
    integer index, out_h, out_w, oh, ow, oc, kh, kw, ic, iy, ix;
    integer input_index, weight_index;
    integer signed acc, input_value, weight_value;
    begin
      out_h = ((cfg_h + 2*cfg_padding - 3) / cfg_stride) + 1;
      out_w = ((cfg_w + 2*cfg_padding - 3) / cfg_stride) + 1;
      index = 0;
      for (oh = 0; oh < out_h; oh = oh + 1)
        for (ow = 0; ow < out_w; ow = ow + 1)
          for (oc = 0; oc < cfg_oc; oc = oc + 1) begin
            acc = 0;
            for (kh = 0; kh < 3; kh = kh + 1)
              for (kw = 0; kw < 3; kw = kw + 1)
                for (ic = 0; ic < cfg_ic; ic = ic + 1) begin
                  iy = oh * cfg_stride + kh - cfg_padding;
                  ix = ow * cfg_stride + kw - cfg_padding;
                  if ((iy < 0) || (iy >= cfg_h) || (ix < 0) || (ix >= cfg_w))
                    input_value = 0;
                  else begin
                    input_index = ((iy * cfg_w) + ix) * cfg_ic + ic;
                    input_value = $signed(input_data[input_index]);
                  end
                  weight_index = (((kh * 3) + kw) * cfg_ic + ic) * cfg_oc + oc;
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

  task automatic send_word(input logic [31:0] data, input logic [3:0] keep, input logic last);
    begin
      @(negedge aclk);
      s_axis_tdata = data; s_axis_tkeep = keep; s_axis_tlast = last; s_axis_tvalid = 1;
      do @(posedge aclk); while (!s_axis_tready);
      @(negedge aclk);
      s_axis_tvalid = 0; s_axis_tlast = 0; s_axis_tkeep = 4'b1111;
    end
  endtask

  task automatic send_normal_packets;
    integer word_index;
    logic [31:0] packed_word;
    begin
      for (word_index = 0; word_index < cfg_weight_bytes/4; word_index = word_index + 1) begin
        packed_word = {weight_data[word_index*4+3], weight_data[word_index*4+2],
                  weight_data[word_index*4+1], weight_data[word_index*4]};
        send_word(packed_word, 4'b1111, word_index == cfg_weight_bytes/4-1);
      end
      for (word_index = 0; word_index < cfg_bias_bytes/4; word_index = word_index + 1)
        send_word(bias_data[word_index], 4'b1111, word_index == cfg_bias_bytes/4-1);
      for (word_index = 0; word_index < cfg_input_bytes/4; word_index = word_index + 1) begin
        packed_word = {input_data[word_index*4+3], input_data[word_index*4+2],
                  input_data[word_index*4+1], input_data[word_index*4]};
        send_word(packed_word, 4'b1111, word_index == cfg_input_bytes/4-1);
      end
    end
  endtask

  task automatic program_config;
    logic [31:0] conv_config, output_scale;
    begin
      conv_config = {7'd0, cfg_relu[0], cfg_padding[7:0], cfg_stride[7:0], 8'd3};
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
      expected_write_element = 0;
      postprocess_monitor_enabled = 1'b1;
      previous_output_we = 1'b0;
      last_write_pending = 1'b0;
      last_output_write_seen = 1'b0;
    end
  endtask

  task automatic finish_normal(input string name, input logic expect_error, input logic [31:0] code);
    begin
      wait (output_byte_count == cfg_output_bytes);
      capture_enabled = 0;
      repeat (6) @(posedge aclk);
      if (expected_write_element != cfg_output_bytes)
        $fatal(1, "%s output write count=%0d expected=%0d",
               name, expected_write_element, cfg_output_bytes);
      if (!last_output_write_seen)
        $fatal(1, "%s did not align final BRAM write with conv_done", name);
      postprocess_monitor_enabled = 1'b0;
      check_status(0, 1, expect_error, code, name);
      if (mismatch_count != 0) $fatal(1, "%s had %0d mismatches", name, mismatch_count);
      tests_passed = tests_passed + 1;
      $display("TEST %-32s PASS (%0d bytes)", name, output_byte_count);
      clear_status();
    end
  endtask

  task automatic run_normal(input string name);
    begin
      build_reference(); clear_status(); program_config(); begin_capture();
      axi_write(REG_CONTROL, 1); send_normal_packets(); finish_normal(name, 0, ERR_NONE);
    end
  endtask

  task automatic run_validator_admission(input string name);
    integer wait_cycles;
    logic [31:0] count_before;
    begin
      build_reference(); clear_status(); program_config(); begin_capture();
      count_before = dut.cycle_count;
      axi_write(REG_CONTROL, 1);
      wait_cycles = 0;
      while (!dut.busy) begin
        @(negedge aclk);
        if (!dut.busy && (dut.debug_state != DBG_IDLE))
          $fatal(1, "%s DEBUG_STATE changed during admission: %0d", name, dut.debug_state);
        if (!dut.busy && (dut.cycle_count != count_before))
          $fatal(1, "%s cycle counter changed during admission", name);
        if (dut.error)
          $fatal(1, "%s asserted ERROR during valid admission", name);
        wait_cycles = wait_cycles + 1;
        if (wait_cycles > 256)
          $fatal(1, "%s timed out waiting for BUSY", name);
      end
      if (wait_cycles == 0)
        $fatal(1, "%s did not expose a multi-cycle admission interval", name);
      $display("VALIDATOR LATENCY: %0d cycles (%s)", wait_cycles, name);
      send_normal_packets();
      finish_normal(name, 0, ERR_NONE);
    end
  endtask

  task automatic expect_invalid_config(input string name);
    integer wait_cycles;
    begin
      clear_status();
      axi_write(REG_CONTROL, 1);
      wait_cycles = 0;
      while (!dut.error) begin
        @(negedge aclk);
        if (dut.busy)
          $fatal(1, "%s entered BUSY during invalid validation", name);
        if (dut.debug_state != DBG_IDLE)
          $fatal(1, "%s changed DEBUG_STATE during invalid validation: %0d", name, dut.debug_state);
        wait_cycles = wait_cycles + 1;
        if (wait_cycles > 256)
          $fatal(1, "%s timed out waiting for ERR_INVALID_CONFIG", name);
      end
      check_status(0, 0, 1, ERR_INVALID_CONFIG, name);
      tests_passed = tests_passed + 1; $display("TEST %-32s PASS", name); clear_status();
    end
  endtask

  task automatic expect_invalid_operation(input string name);
    integer wait_cycles;
    begin
      clear_status();
      axi_write(REG_CONTROL, 1);
      wait_cycles = 0;
      while (!dut.error) begin
        @(negedge aclk);
        if (dut.busy)
          $fatal(1, "%s entered BUSY during invalid operation validation", name);
        if (dut.debug_state != DBG_IDLE)
          $fatal(1, "%s changed DEBUG_STATE during invalid operation validation", name);
        wait_cycles = wait_cycles + 1;
        if (wait_cycles > 256)
          $fatal(1, "%s timed out waiting for ERR_INVALID_OPERATION", name);
      end
      check_status(0, 0, 1, ERR_INVALID_OPERATION, name);
      tests_passed = tests_passed + 1; $display("TEST %-32s PASS", name); clear_status();
    end
  endtask

  task automatic recover_with_normal(input string name);
    begin set_shape(1, 1, 1, 1, 0); initialize_pattern(0); run_normal(name); end
  endtask

  always @(posedge aclk) begin : independent_address_trace_monitor
    integer ref_oh, ref_ow, ref_oc, ref_kh, ref_kw, ref_ic;
    integer ref_out_h, ref_out_w;
    integer ref_iy, ref_ix, ref_input_element, ref_weight_element;
    integer signed ref_product;
    logic ref_padding;
    if (aresetn && postprocess_monitor_enabled) begin
      if (dut.u_conv_engine.state_q == 4'd3) begin
        ref_oh = dut.u_conv_engine.out_h_q;
        ref_ow = dut.u_conv_engine.out_w_q;
        ref_oc = dut.u_conv_engine.out_c_q;
        ref_kh = dut.u_conv_engine.kernel_h_q;
        ref_kw = dut.u_conv_engine.kernel_w_q;
        ref_ic = dut.u_conv_engine.in_c_q;
        ref_out_h = ((cfg_h + 2*cfg_padding - 3) / cfg_stride) + 1;
        ref_out_w = ((cfg_w + 2*cfg_padding - 3) / cfg_stride) + 1;
        ref_iy = ref_oh * cfg_stride + ref_kh - cfg_padding;
        ref_ix = ref_ow * cfg_stride + ref_kw - cfg_padding;
        ref_padding = (ref_iy < 0) || (ref_iy >= cfg_h)
                   || (ref_ix < 0) || (ref_ix >= cfg_w);
        ref_input_element = ((ref_iy * cfg_w) + ref_ix) * cfg_ic + ref_ic;
        ref_weight_element = (((ref_kh * 3) + ref_kw) * cfg_ic + ref_ic)
                           * cfg_oc + ref_oc;

        address_trace_seen = 1'b1;
        address_padding_seen = address_padding_seen || ref_padding;
        address_valid_seen = address_valid_seen || !ref_padding;
        address_stride1_seen = address_stride1_seen || (cfg_stride == 1);
        address_stride2_seen = address_stride2_seen || (cfg_stride == 2);
        address_top_seen = address_top_seen || (ref_oh == 0);
        address_left_seen = address_left_seen || (ref_ow == 0);
        address_right_seen = address_right_seen || (ref_ow == (ref_out_w - 1));
        address_bottom_seen = address_bottom_seen || (ref_oh == (ref_out_h - 1));
        address_center_seen = address_center_seen
                           || ((ref_oh > 0) && (ref_oh < (ref_out_h - 1))
                               && (ref_ow > 0) && (ref_ow < (ref_out_w - 1)));
        address_ic_nonzero_seen = address_ic_nonzero_seen || (ref_ic != 0);
        address_oc_nonzero_seen = address_oc_nonzero_seen || (ref_oc != 0);
        address_kw_nonzero_seen = address_kw_nonzero_seen || (ref_kw != 0);
        address_kh_nonzero_seen = address_kh_nonzero_seen || (ref_kh != 0);
        address_weight_lanes_seen[ref_weight_element & 3] = 1'b1;
        if (!ref_padding)
          address_input_lanes_seen[ref_input_element & 3] = 1'b1;
        address_input_word_cross_seen = address_input_word_cross_seen
                                      || (!ref_padding && (ref_input_element > 0)
                                          && ((ref_input_element & 3) == 0));
        address_weight_word_cross_seen = address_weight_word_cross_seen
                                       || ((ref_weight_element > 0)
                                           && ((ref_weight_element & 3) == 0));
        address_last_tap_seen = address_last_tap_seen
                              || ((ref_kh == 2) && (ref_kw == 2)
                                  && (ref_ic == (cfg_ic - 1)));

        if ($signed(dut.u_conv_engine.tap_input_y_q) !== ref_iy)
          $fatal(1, "tap Y mismatch got=%0d expected=%0d", $signed(dut.u_conv_engine.tap_input_y_q), ref_iy);
        if ($signed(dut.u_conv_engine.tap_input_x_q) !== ref_ix)
          $fatal(1, "tap X mismatch got=%0d expected=%0d", $signed(dut.u_conv_engine.tap_input_x_q), ref_ix);
        if ($signed(dut.u_conv_engine.tap_input_element_q) !== ref_input_element)
          $fatal(1, "input element mismatch got=%0d expected=%0d", $signed(dut.u_conv_engine.tap_input_element_q), ref_input_element);
        if (dut.u_conv_engine.weight_element_q !== ref_weight_element)
          $fatal(1, "weight element mismatch got=%0d expected=%0d", dut.u_conv_engine.weight_element_q, ref_weight_element);
        if (dut.u_conv_engine.tap_padding_q !== ref_padding)
          $fatal(1, "padding mismatch oh=%0d ow=%0d kh=%0d kw=%0d got=%0b expected=%0b",
                 ref_oh, ref_ow, ref_kh, ref_kw, dut.u_conv_engine.tap_padding_q, ref_padding);
        if (dut.input_rd_en !== !ref_padding)
          $fatal(1, "input read enable mismatch padding=%0b rd_en=%0b", ref_padding, dut.input_rd_en);
        if (dut.weight_rd_en !== 1'b1)
          $fatal(1, "weight read unexpectedly disabled");
        if (!ref_padding) begin
          if (dut.input_rd_word_addr !== (ref_input_element >> 2))
            $fatal(1, "input word address mismatch got=%0d expected=%0d", dut.input_rd_word_addr, ref_input_element >> 2);
          if (dut.input_rd_byte_sel !== (ref_input_element & 3))
            $fatal(1, "input lane mismatch got=%0d expected=%0d", dut.input_rd_byte_sel, ref_input_element & 3);
        end
        if (dut.weight_rd_word_addr !== (ref_weight_element >> 2))
          $fatal(1, "weight word address mismatch got=%0d expected=%0d", dut.weight_rd_word_addr, ref_weight_element >> 2);
        if (dut.weight_rd_byte_sel !== (ref_weight_element & 3))
          $fatal(1, "weight lane mismatch got=%0d expected=%0d", dut.weight_rd_byte_sel, ref_weight_element & 3);
      end

      if (dut.u_conv_engine.state_q == 4'd4) begin
        ref_oh = dut.u_conv_engine.out_h_q;
        ref_ow = dut.u_conv_engine.out_w_q;
        ref_oc = dut.u_conv_engine.out_c_q;
        ref_kh = dut.u_conv_engine.kernel_h_q;
        ref_kw = dut.u_conv_engine.kernel_w_q;
        ref_ic = dut.u_conv_engine.in_c_q;
        ref_iy = ref_oh * cfg_stride + ref_kh - cfg_padding;
        ref_ix = ref_ow * cfg_stride + ref_kw - cfg_padding;
        ref_padding = (ref_iy < 0) || (ref_iy >= cfg_h)
                   || (ref_ix < 0) || (ref_ix >= cfg_w);
        ref_input_element = ((ref_iy * cfg_w) + ref_ix) * cfg_ic + ref_ic;
        ref_weight_element = (((ref_kh * 3) + ref_kw) * cfg_ic + ref_ic)
                           * cfg_oc + ref_oc;
        if ($signed(dut.weight_rd_data) !== $signed(weight_data[ref_weight_element]))
          $fatal(1, "synchronous weight data mismatch element=%0d got=%0d expected=%0d",
                 ref_weight_element, $signed(dut.weight_rd_data), $signed(weight_data[ref_weight_element]));
        if (ref_padding) begin
          if ($signed(dut.u_conv_engine.product) !== 0)
            $fatal(1, "padding tap consumed stale input data product=%0d", $signed(dut.u_conv_engine.product));
        end else begin
          if ($signed(dut.input_rd_data) !== $signed(input_data[ref_input_element]))
            $fatal(1, "synchronous input data mismatch element=%0d got=%0d expected=%0d",
                   ref_input_element, $signed(dut.input_rd_data), $signed(input_data[ref_input_element]));
          ref_product = $signed(input_data[ref_input_element]) * $signed(weight_data[ref_weight_element]);
          if ($signed(dut.u_conv_engine.product) !== ref_product)
            $fatal(1, "MAC product mismatch input=%0d weight=%0d got=%0d expected=%0d",
                   ref_input_element, ref_weight_element, $signed(dut.u_conv_engine.product), ref_product);
        end
      end

      if ((dut.u_conv_engine.state_q == 4'd8) && dut.output_we
          && (expected_write_element == (cfg_output_bytes - 1)))
        address_last_output_seen = 1'b1;
    end
  end

  always @(posedge aclk) begin : postprocess_write_monitor
    if (!aresetn) begin
      previous_output_we = 1'b0;
      last_write_pending = 1'b0;
    end else if (postprocess_monitor_enabled) begin
      if (dut.output_we) begin
        if (previous_output_we)
          $fatal(1, "output_we remained asserted for multiple cycles");
        if (expected_write_element >= cfg_output_bytes)
          $fatal(1, "unexpected extra output write at element %0d", expected_write_element);
        if (dut.output_waddr !== (expected_write_element >> 2))
          $fatal(1, "output address mismatch element=%0d got=%0d expected=%0d",
                 expected_write_element, dut.output_waddr, expected_write_element >> 2);
        if (dut.output_wbyte_sel !== (expected_write_element & 3))
          $fatal(1, "output lane mismatch element=%0d got=%0d expected=%0d",
                 expected_write_element, dut.output_wbyte_sel, expected_write_element & 3);
        if ($signed(dut.output_wdata) !== $signed(expected_data[expected_write_element]))
          $fatal(1, "output write data mismatch element=%0d got=%0d expected=%0d",
                 expected_write_element, $signed(dut.output_wdata),
                 $signed(expected_data[expected_write_element]));
        last_write_pending = (expected_write_element == (cfg_output_bytes - 1));
        expected_write_element = expected_write_element + 1;
      end
      previous_output_we = dut.output_we;
    end
  end

  always @(negedge aclk) begin : final_write_done_monitor
    if (postprocess_monitor_enabled && last_write_pending) begin
      if (!dut.conv_done)
        $fatal(1, "final BRAM write was not aligned with conv_done");
      last_output_write_seen = 1'b1;
      last_write_pending = 1'b0;
    end
  end

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
    logic [31:0] status, code, original_height;
    integer word_index;
    logic [31:0] packed_word;

    aclk = 0; aresetn = 0;
    s_axi_awaddr = 0; s_axi_awvalid = 0; s_axi_wdata = 0; s_axi_wstrb = 4'b1111;
    s_axi_wvalid = 0; s_axi_bready = 1; s_axi_araddr = 0; s_axi_arvalid = 0;
    s_axi_rready = 1; s_axis_tdata = 0; s_axis_tkeep = 4'b1111;
    s_axis_tlast = 0; s_axis_tvalid = 0; m_axis_tready = 1;
    output_byte_count = 0; mismatch_count = 0; capture_enabled = 0; tests_passed = 0;
    expected_write_element = 0; postprocess_monitor_enabled = 0;
    previous_output_we = 0; last_write_pending = 0; last_output_write_seen = 0;
    address_trace_seen = 0; address_padding_seen = 0; address_valid_seen = 0;
    address_stride1_seen = 0; address_stride2_seen = 0;
    address_top_seen = 0; address_left_seen = 0; address_right_seen = 0; address_bottom_seen = 0;
    address_center_seen = 0; address_ic_nonzero_seen = 0; address_oc_nonzero_seen = 0;
    address_kw_nonzero_seen = 0; address_kh_nonzero_seen = 0;
    address_input_lanes_seen = 4'b0000; address_weight_lanes_seen = 4'b0000;
    address_input_word_cross_seen = 0; address_weight_word_cross_seen = 0;
    address_last_tap_seen = 0; address_last_output_seen = 0;
    repeat (6) @(posedge aclk); @(negedge aclk); aresetn = 1; repeat (4) @(posedge aclk);

    set_shape(1, 1, 0, 3, 2); initialize_pattern(1); run_normal("signed_bias_relu_off_requant");

    set_shape(1, 1, 0, 0, 7); initialize_pattern(1); run_normal("postprocess_m_zero");

    set_shape(1, 1, 0, 1, 0); initialize_pattern(0);
    for (word_index = 0; word_index < MAX_INPUT_BYTES; word_index = word_index + 1)
      input_data[word_index] = 8'sd0;
    for (word_index = 0; word_index < MAX_WEIGHT_BYTES; word_index = word_index + 1)
      weight_data[word_index] = 8'sd0;
    bias_data[0] = 32'sd127; bias_data[1] = 32'sd128;
    bias_data[2] = -32'sd128; bias_data[3] = -32'sd129;
    run_normal("postprocess_clamp_lanes");

    set_shape(1, 1, 0, 1, 1); initialize_pattern(0);
    for (word_index = 0; word_index < MAX_INPUT_BYTES; word_index = word_index + 1)
      input_data[word_index] = 8'sd0;
    for (word_index = 0; word_index < MAX_WEIGHT_BYTES; word_index = word_index + 1)
      weight_data[word_index] = 8'sd0;
    bias_data[0] = 32'sd1; bias_data[1] = -32'sd1;
    bias_data[2] = 32'sd3; bias_data[3] = -32'sd3;
    run_normal("postprocess_signed_ties");

    set_shape(1, 1, 1, 65535, 0); initialize_pattern(1); run_normal("postprocess_m_65535_relu");

    set_shape(2, 1, 1, 1, 0); initialize_pattern(1); run_normal("stride2");
    set_shape(1, 0, 1, 1, 0); initialize_pattern(1); run_normal("padding0");
    set_shape(1, 1, 1, 1, 0); initialize_pattern(0); run_normal("consecutive_operation_1");
    initialize_pattern(1); run_normal("consecutive_operation_2");

    set_shape(1, 1, 1, 1, 0); initialize_pattern(0);
    run_validator_admission("validator_valid_admission");

    cfg_h = 4; cfg_w = 4; cfg_ic = 2; cfg_oc = 8;
    cfg_stride = 1; cfg_padding = 1; cfg_relu = 1; cfg_multiplier = 1; cfg_shift = 0;
    cfg_input_bytes = 32; cfg_weight_bytes = 144; cfg_bias_bytes = 32; cfg_output_bytes = 128;
    initialize_pattern(1); run_normal("capacity_boundary_accept");

    set_shape(1, 1, 1, 1, 0); initialize_pattern(0);
    build_reference(); clear_status(); program_config(); begin_capture();
    axi_write(REG_CONTROL, 1);
    @(negedge aclk);
    if (!dut.admission_active || dut.busy)
      $fatal(1, "second START was not issued during admission: admission=%0b busy=%0b val_state=%0d", dut.admission_active, dut.busy, dut.u_controller.validator_state_q);
    axi_write(REG_CONTROL, 1); send_normal_packets();
    finish_normal("start_while_busy_nonfatal", 1, ERR_START_WHILE_BUSY);

    build_reference(); clear_status(); program_config(); original_height = cfg_h; begin_capture();
    axi_write(REG_CONTROL, 1);
    @(negedge aclk);
    if (!dut.admission_active || dut.busy)
      $fatal(1, "config write was not issued during admission");
    axi_write(REG_INPUT_HEIGHT, 99); axi_read(REG_INPUT_HEIGHT, status);
    if (status != original_height) $fatal(1, "BUSY config write changed register: %0d", status);
    send_normal_packets(); finish_normal("config_write_busy_nonfatal", 1, ERR_CONFIG_WRITE_BUSY);

    program_config(); axi_write(REG_OPERATION, 1); expect_invalid_operation("invalid_operation_reject");
    program_config(); axi_write(REG_OUTPUT_BYTES, 132); expect_invalid_config("buffer_capacity_invalid");
    program_config(); axi_write(REG_INPUT_BYTES, cfg_input_bytes + 4);
    expect_invalid_config("register_byte_mismatch");

    cfg_h = 2; cfg_w = 11; cfg_ic = 2; cfg_oc = 6;
    cfg_stride = 1; cfg_padding = 1; cfg_relu = 1; cfg_multiplier = 1; cfg_shift = 0;
    cfg_input_bytes = 44; cfg_weight_bytes = 108; cfg_bias_bytes = 24; cfg_output_bytes = 132;
    program_config(); expect_invalid_config("calculated_capacity_plus4");

    set_shape(1, 1, 1, 1, 0);
    program_config(); axi_write(REG_INPUT_HEIGHT, 32'hffff_ffff); expect_invalid_config("raw_height_max_reject");
    program_config(); axi_write(REG_INPUT_WIDTH,  32'hffff_ffff); expect_invalid_config("raw_width_max_reject");
    program_config(); axi_write(REG_IN_CHANNELS,  32'hffff_ffff); expect_invalid_config("raw_in_channels_max_reject");
    program_config(); axi_write(REG_OUT_CHANNELS, 32'hffff_ffff); expect_invalid_config("raw_out_channels_max_reject");
    program_config(); axi_write(REG_INPUT_HEIGHT, 1); axi_write(REG_CONV_CONFIG, 32'h0100_0103);
    expect_invalid_config("padded_dimension_short_reject");

    set_shape(1, 1, 1, 1, 0); initialize_pattern(0);
    program_config(); clear_status(); axi_write(REG_CONTROL, 1);
    packed_word = {weight_data[3], weight_data[2], weight_data[1], weight_data[0]};
    send_word(packed_word, 4'b1111, 1); repeat (5) @(posedge aclk);
    check_status(0, 0, 1, ERR_TLAST_POSITION, "early_tlast");
    tests_passed = tests_passed + 1; $display("TEST %-32s PASS", "early_tlast");
    recover_with_normal("recovery_after_early_tlast");

    program_config(); clear_status(); axi_write(REG_CONTROL, 1);
    for (word_index = 0; word_index < cfg_weight_bytes/4; word_index = word_index + 1) begin
      packed_word = {weight_data[word_index*4+3], weight_data[word_index*4+2],
                weight_data[word_index*4+1], weight_data[word_index*4]};
      send_word(packed_word, 4'b1111, 0);
    end
    repeat (5) @(posedge aclk);
    check_status(0, 0, 1, ERR_TLAST_POSITION, "missing_tlast");
    tests_passed = tests_passed + 1; $display("TEST %-32s PASS", "missing_tlast");
    recover_with_normal("recovery_after_missing_tlast");

    program_config(); clear_status(); axi_write(REG_CONTROL, 1);
    send_word(32'h0101_0101, 4'b0011, 0); repeat (5) @(posedge aclk);
    check_status(0, 0, 1, ERR_PACKET_LENGTH, "invalid_tkeep");
    tests_passed = tests_passed + 1; $display("TEST %-32s PASS", "invalid_tkeep");
    recover_with_normal("recovery_after_invalid_tkeep");

    program_config(); clear_status(); axi_write(REG_CONTROL, 1);
    @(negedge aclk);
    if (!dut.admission_active || dut.busy)
      $fatal(1, "ABORT was not issued during admission");
    axi_write(REG_CONTROL, 2);
    repeat (5) @(posedge aclk); check_status(0, 0, 1, ERR_ABORTED, "validation_abort");
    tests_passed = tests_passed + 1; $display("TEST %-32s PASS", "validation_abort");
    recover_with_normal("recovery_after_validation_abort");

    set_shape(1, 1, 0, 1, 0); initialize_pattern(0);
    build_reference(); program_config(); clear_status(); begin_capture();
    axi_write(REG_CONTROL, 1); send_normal_packets();
    wait (dut.u_conv_engine.state_q == 4'd6);
    @(negedge aclk);
    force dut.engine_abort = 1'b1;
    @(posedge aclk); #1;
    release dut.engine_abort;
    if (expected_write_element != 0 || dut.output_we)
      $fatal(1, "postprocess abort allowed an incomplete output write");
    postprocess_monitor_enabled = 1'b0; capture_enabled = 1'b0;
    axi_write(REG_CONTROL, 2);
    repeat (5) @(posedge aclk); check_status(0, 0, 1, ERR_ABORTED, "postprocess_abort");
    tests_passed = tests_passed + 1; $display("TEST %-32s PASS", "postprocess_abort");
    recover_with_normal("recovery_after_postprocess_abort");

    program_config(); clear_status(); axi_write(REG_CONTROL, 1);
    send_word(32'h0101_0101, 4'b1111, 0); axi_write(REG_CONTROL, 2);
    repeat (5) @(posedge aclk); check_status(0, 0, 1, ERR_ABORTED, "abort");
    tests_passed = tests_passed + 1; $display("TEST %-32s PASS", "abort");
    recover_with_normal("recovery_after_abort");

    if (!address_trace_seen || !address_padding_seen || !address_valid_seen
        || !address_stride1_seen || !address_stride2_seen
        || !address_top_seen || !address_left_seen || !address_right_seen || !address_bottom_seen
        || !address_center_seen || !address_ic_nonzero_seen || !address_oc_nonzero_seen
        || !address_kw_nonzero_seen || !address_kh_nonzero_seen
        || (address_input_lanes_seen != 4'b1111) || (address_weight_lanes_seen != 4'b1111)
        || !address_input_word_cross_seen || !address_weight_word_cross_seen
        || !address_last_tap_seen || !address_last_output_seen)
      $fatal(1, "address trace coverage incomplete pad=%0b valid=%0b stride=%0b%0b edge=%0b%0b%0b%0b center=%0b lanes=%b/%b cross=%0b/%0b last=%0b/%0b",
             address_padding_seen, address_valid_seen, address_stride2_seen, address_stride1_seen,
             address_top_seen, address_left_seen, address_right_seen, address_bottom_seen,
             address_center_seen, address_input_lanes_seen, address_weight_lanes_seen,
             address_input_word_cross_seen, address_weight_word_cross_seen,
             address_last_tap_seen, address_last_output_seen);
    tests_passed = tests_passed + 1;
    $display("TEST %-32s PASS", "independent_address_trace");

    axi_read(REG_STATUS, status); axi_read(REG_ERROR_CODE, code);
    if (status[3] || (code != ERR_NONE))
      $fatal(1, "Final recovery left error STATUS=%08x CODE=%0d", status, code);
    $display("DIRECTED PASS: %0d integration/error checks", tests_passed);
    $finish;
  end

  initial begin
    repeat (1500000) @(posedge aclk);
    $fatal(1, "Directed simulation timeout");
  end
endmodule
