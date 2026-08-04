`timescale 1ns/1ps

module tb_resnet_accel_top;
  localparam integer CLK_PERIOD_NS = 10;
  localparam integer INPUT_BYTES   = 64;
  localparam integer WEIGHT_BYTES  = 144;
  localparam integer BIAS_BYTES    = 16;
  localparam integer OUTPUT_BYTES  = 64;

  localparam logic [6:0] REG_CONTROL      = 7'h00;
  localparam logic [6:0] REG_STATUS       = 7'h04;
  localparam logic [6:0] REG_OPERATION    = 7'h08;
  localparam logic [6:0] REG_INPUT_HEIGHT = 7'h0c;
  localparam logic [6:0] REG_INPUT_WIDTH  = 7'h10;
  localparam logic [6:0] REG_IN_CHANNELS  = 7'h14;
  localparam logic [6:0] REG_OUT_CHANNELS = 7'h18;
  localparam logic [6:0] REG_CONV_CONFIG  = 7'h1c;
  localparam logic [6:0] REG_OUTPUT_SCALE = 7'h20;
  localparam logic [6:0] REG_INPUT_BYTES  = 7'h24;
  localparam logic [6:0] REG_WEIGHT_BYTES = 7'h28;
  localparam logic [6:0] REG_BIAS_BYTES   = 7'h2c;
  localparam logic [6:0] REG_SKIP_BYTES   = 7'h30;
  localparam logic [6:0] REG_OUTPUT_BYTES = 7'h34;
  localparam logic [6:0] REG_CYCLE_COUNT  = 7'h38;
  localparam logic [6:0] REG_ERROR_CODE   = 7'h3c;

  logic aclk;
  logic aresetn;

  logic [6:0]  s_axi_awaddr;
  logic        s_axi_awvalid;
  logic        s_axi_awready;
  logic [31:0] s_axi_wdata;
  logic [3:0]  s_axi_wstrb;
  logic        s_axi_wvalid;
  logic        s_axi_wready;
  logic [1:0]  s_axi_bresp;
  logic        s_axi_bvalid;
  logic        s_axi_bready;
  logic [6:0]  s_axi_araddr;
  logic        s_axi_arvalid;
  logic        s_axi_arready;
  logic [31:0] s_axi_rdata;
  logic [1:0]  s_axi_rresp;
  logic        s_axi_rvalid;
  logic        s_axi_rready;

  logic [31:0] s_axis_tdata;
  logic [3:0]  s_axis_tkeep;
  logic        s_axis_tlast;
  logic        s_axis_tvalid;
  logic        s_axis_tready;

  logic [31:0] m_axis_tdata;
  logic [3:0]  m_axis_tkeep;
  logic        m_axis_tlast;
  logic        m_axis_tvalid;
  logic        m_axis_tready;

  logic signed [7:0] input_data    [0:INPUT_BYTES-1];
  logic signed [7:0] weight_data   [0:WEIGHT_BYTES-1];
  logic signed [7:0] expected_data [0:OUTPUT_BYTES-1];
  logic signed [31:0] bias_data    [0:3];

  integer output_byte_count;
  integer mismatch_count;
  integer capture_lane;
  integer observed_value;
  integer expected_index;
  logic backpressure_applied;
  logic final_backpressure_applied;

  resnet_accel_top #(
    .MAX_WEIGHT_WORDS(64),
    .MAX_BIAS_WORDS(8),
    .MAX_INPUT_WORDS(32),
    .MAX_OUTPUT_WORDS(32)
  ) dut (
    .aclk(aclk),
    .aresetn(aresetn),
    .s_axi_awaddr(s_axi_awaddr),
    .s_axi_awvalid(s_axi_awvalid),
    .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata),
    .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wvalid(s_axi_wvalid),
    .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp),
    .s_axi_bvalid(s_axi_bvalid),
    .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr),
    .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata),
    .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid),
    .s_axi_rready(s_axi_rready),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready)
  );

  always #(CLK_PERIOD_NS/2) aclk = ~aclk;

  function automatic integer signed sat_add_ref(
    input integer signed a,
    input integer signed b
  );
    longint signed wide_sum;
    begin
      wide_sum = a;
      wide_sum = wide_sum + b;
      if (wide_sum > 64'sd2147483647)
        sat_add_ref = 2147483647;
      else if (wide_sum < -64'sd2147483648)
        sat_add_ref = 32'sh8000_0000;
      else
        sat_add_ref = wide_sum;
    end
  endfunction

  function automatic longint signed requant_ref(
    input integer signed accumulator,
    input integer unsigned multiplier,
    input integer unsigned shift
  );
    longint signed product;
    longint signed magnitude;
    longint signed rounded;
    begin
      product = accumulator;
      product = product * multiplier;
      magnitude = (product < 0) ? -product : product;
      if (shift == 0)
        rounded = magnitude;
      else
        rounded = (magnitude + (64'sd1 << (shift-1))) >>> shift;
      requant_ref = (product < 0) ? -rounded : rounded;
    end
  endfunction

  function automatic logic signed [7:0] postprocess_ref(
    input integer signed accumulator,
    input integer unsigned multiplier,
    input integer unsigned shift,
    input logic relu_enable
  );
    longint signed value;
    begin
      value = requant_ref(accumulator, multiplier, shift);
      if (relu_enable && (value < 0))
        value = 0;
      if (value > 127)
        value = 127;
      else if (value < -128)
        value = -128;
      postprocess_ref = value[7:0];
    end
  endfunction

  task automatic build_reference;
    integer index;
    integer oh;
    integer ow;
    integer oc;
    integer kh;
    integer kw;
    integer ic;
    integer iy;
    integer ix;
    integer input_index;
    integer weight_index;
    integer signed acc;
    integer signed input_value;
    integer signed weight_value;
    begin
      for (index = 0; index < INPUT_BYTES; index = index + 1)
        input_data[index] = 8'sd1;
      for (index = 0; index < WEIGHT_BYTES; index = index + 1)
        weight_data[index] = 8'sd1;
      for (index = 0; index < 4; index = index + 1)
        bias_data[index] = 32'sd0;

      index = 0;
      for (oh = 0; oh < 4; oh = oh + 1) begin
        for (ow = 0; ow < 4; ow = ow + 1) begin
          for (oc = 0; oc < 4; oc = oc + 1) begin
            acc = 0;
            for (kh = 0; kh < 3; kh = kh + 1) begin
              for (kw = 0; kw < 3; kw = kw + 1) begin
                for (ic = 0; ic < 4; ic = ic + 1) begin
                  iy = oh + kh - 1;
                  ix = ow + kw - 1;
                  if ((iy < 0) || (iy >= 4) || (ix < 0) || (ix >= 4)) begin
                    input_value = 0;
                  end else begin
                    input_index = ((iy * 4) + ix) * 4 + ic;
                    input_value = $signed(input_data[input_index]);
                  end
                  weight_index = (((kh * 3) + kw) * 4 + ic) * 4 + oc;
                  weight_value = $signed(weight_data[weight_index]);
                  acc = sat_add_ref(acc, input_value * weight_value);
                end
              end
            end
            acc = sat_add_ref(acc, bias_data[oc]);
            expected_data[index] = postprocess_ref(acc, 1, 0, 1'b1);
            index = index + 1;
          end
        end
      end
    end
  endtask

  task automatic axi_write(
    input logic [6:0] address,
    input logic [31:0] data
  );
    logic aw_done;
    logic w_done;
    begin
      aw_done = 1'b0;
      w_done  = 1'b0;
      @(negedge aclk);
      s_axi_awaddr  = address;
      s_axi_awvalid = 1'b1;
      s_axi_wdata   = data;
      s_axi_wstrb   = 4'b1111;
      s_axi_wvalid  = 1'b1;

      while (!aw_done || !w_done) begin
        @(posedge aclk);
        if (s_axi_awvalid && s_axi_awready)
          aw_done = 1'b1;
        if (s_axi_wvalid && s_axi_wready)
          w_done = 1'b1;
        @(negedge aclk);
        if (aw_done)
          s_axi_awvalid = 1'b0;
        if (w_done)
          s_axi_wvalid = 1'b0;
      end

      wait (s_axi_bvalid === 1'b1);
      if (s_axi_bresp != 2'b00)
        $fatal(1, "AXI write BRESP was not OKAY at address 0x%02x", address);
      @(posedge aclk);
    end
  endtask

  task automatic axi_read(
    input  logic [6:0] address,
    output logic [31:0] data
  );
    begin
      @(negedge aclk);
      s_axi_araddr  = address;
      s_axi_arvalid = 1'b1;
      do @(posedge aclk); while (!s_axi_arready);
      @(negedge aclk);
      s_axi_arvalid = 1'b0;
      wait (s_axi_rvalid === 1'b1);
      data = s_axi_rdata;
      if (s_axi_rresp != 2'b00)
        $fatal(1, "AXI read RRESP was not OKAY at address 0x%02x", address);
      @(posedge aclk);
    end
  endtask

  task automatic send_axis_word(
    input logic [31:0] data,
    input logic last
  );
    begin
      @(negedge aclk);
      s_axis_tdata  = data;
      s_axis_tkeep  = 4'b1111;
      s_axis_tlast  = last;
      s_axis_tvalid = 1'b1;
      do @(posedge aclk); while (!s_axis_tready);
      @(negedge aclk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast  = 1'b0;
    end
  endtask

  task automatic send_weight_packet;
    integer word_index;
    logic [31:0] packed_word;
    begin
      for (word_index = 0; word_index < WEIGHT_BYTES/4; word_index = word_index + 1) begin
        packed_word = {
          weight_data[word_index*4+3],
          weight_data[word_index*4+2],
          weight_data[word_index*4+1],
          weight_data[word_index*4+0]
        };
        send_axis_word(packed_word, word_index == (WEIGHT_BYTES/4-1));
      end
    end
  endtask

  task automatic send_bias_packet;
    integer word_index;
    begin
      for (word_index = 0; word_index < BIAS_BYTES/4; word_index = word_index + 1)
        send_axis_word(bias_data[word_index], word_index == (BIAS_BYTES/4-1));
    end
  endtask

  task automatic send_input_packet;
    integer word_index;
    logic [31:0] packed_word;
    begin
      for (word_index = 0; word_index < INPUT_BYTES/4; word_index = word_index + 1) begin
        if (word_index == 5)
          repeat (3) @(posedge aclk);
        packed_word = {
          input_data[word_index*4+3],
          input_data[word_index*4+2],
          input_data[word_index*4+1],
          input_data[word_index*4+0]
        };
        send_axis_word(packed_word, word_index == (INPUT_BYTES/4-1));
      end
    end
  endtask

  always @(posedge aclk) begin : output_capture
    integer beat_mismatches;
    if (!aresetn) begin
      output_byte_count = 0;
      mismatch_count    = 0;
    end else if (m_axis_tvalid && m_axis_tready) begin
      beat_mismatches = 0;
      if (m_axis_tkeep != 4'b1111) begin
        beat_mismatches = beat_mismatches + 1;
        $error("Unexpected output TKEEP %b", m_axis_tkeep);
      end

      for (capture_lane = 0; capture_lane < 4; capture_lane = capture_lane + 1) begin
        expected_index = output_byte_count + capture_lane;
        observed_value = $signed(m_axis_tdata[capture_lane*8 +: 8]);
        if (observed_value != $signed(expected_data[expected_index])) begin
          beat_mismatches = beat_mismatches + 1;
          $error("Output mismatch at byte %0d: got %0d expected %0d",
                 expected_index, observed_value, $signed(expected_data[expected_index]));
        end
      end

      if (m_axis_tlast != ((output_byte_count + 4) == OUTPUT_BYTES)) begin
        beat_mismatches = beat_mismatches + 1;
        $error("TLAST mismatch at output byte count %0d", output_byte_count);
      end

      mismatch_count = mismatch_count + beat_mismatches;
      output_byte_count = output_byte_count + 4;
    end
  end

  initial begin
    logic [31:0] held_final_data;
    logic [3:0] held_final_keep;
    m_axis_tready = 1'b0;
    backpressure_applied = 1'b0;
    wait (aresetn === 1'b1);
    final_backpressure_applied = 1'b0;
    @(negedge aclk);
    m_axis_tready = 1'b1;
    wait (output_byte_count >= 8);
    @(negedge aclk);
    m_axis_tready = 1'b0;
    backpressure_applied = 1'b1;
    repeat (4) @(posedge aclk);
    @(negedge aclk);
    m_axis_tready = 1'b1;

    wait (output_byte_count == OUTPUT_BYTES-4);
    @(negedge aclk);
    m_axis_tready = 1'b0;
    wait (m_axis_tvalid && m_axis_tlast);
    held_final_data = m_axis_tdata;
    held_final_keep = m_axis_tkeep;
    repeat (4) begin
      @(posedge aclk); #1;
      if (!dut.busy || dut.done || dut.error)
        $fatal(1, "Final-beat backpressure changed completion status");
      if (!m_axis_tvalid || !m_axis_tlast || (m_axis_tdata != held_final_data)
          || (m_axis_tkeep != held_final_keep))
        $fatal(1, "Final output beat was not stable under backpressure");
    end
    @(negedge aclk); m_axis_tready = 1'b1;
    final_backpressure_applied = 1'b1;
  end

  initial begin
    logic [31:0] status;
    logic [31:0] code;
    logic [31:0] cycles;
    integer validation_wait_cycles;
    integer admission_cycle_count;

    aclk          = 1'b0;
    aresetn       = 1'b0;
    s_axi_awaddr  = '0;
    s_axi_awvalid = 1'b0;
    s_axi_wdata   = '0;
    s_axi_wstrb   = 4'b1111;
    s_axi_wvalid  = 1'b0;
    s_axi_bready  = 1'b1;
    s_axi_araddr  = '0;
    s_axi_arvalid = 1'b0;
    s_axi_rready  = 1'b1;
    s_axis_tdata  = '0;
    s_axis_tkeep  = 4'b1111;
    s_axis_tlast  = 1'b0;
    s_axis_tvalid = 1'b0;

    build_reference();

    repeat (6) @(posedge aclk);
    @(negedge aclk);
    aresetn = 1'b1;
    repeat (20) begin
      @(posedge aclk); #1;
      if (!dut.idle || dut.busy || (dut.cycle_count != 32'd0))
        $fatal(1, "Reset-idle contract failed IDLE=%0b BUSY=%0b CYCLE_COUNT=%0d",
               dut.idle, dut.busy, dut.cycle_count);
    end

    axi_write(REG_STATUS,       32'h0000_000c);
    axi_write(REG_OPERATION,    32'd0);
    axi_write(REG_INPUT_HEIGHT, 32'd4);
    axi_write(REG_INPUT_WIDTH,  32'd4);
    axi_write(REG_IN_CHANNELS,  32'd4);
    axi_write(REG_OUT_CHANNELS, 32'd4);
    axi_write(REG_CONV_CONFIG,  32'h0101_0103);
    axi_write(REG_OUTPUT_SCALE, 32'h0000_0001);
    axi_write(REG_INPUT_BYTES,  INPUT_BYTES);
    axi_write(REG_WEIGHT_BYTES, WEIGHT_BYTES);
    axi_write(REG_BIAS_BYTES,   BIAS_BYTES);
    axi_write(REG_SKIP_BYTES,   32'd0);
    axi_write(REG_OUTPUT_BYTES, OUTPUT_BYTES);

    axi_write(REG_CONTROL, 32'h0000_0001);
    axi_read(REG_STATUS, status);
    axi_read(REG_CYCLE_COUNT, cycles);
    if (status[3:0] != 4'b0010)
      $fatal(1, "First observable START status was not BUSY-only: 0x%08x", status);
    if (cycles == 32'd0)
      $fatal(1, "Admission counter did not advance after START");

    validation_wait_cycles = 0;
    admission_cycle_count = dut.cycle_count;
    while (dut.admission_active === 1'b1) begin
      @(negedge aclk);
      if (dut.admission_active) begin
        if (!dut.busy || dut.idle)
          $fatal(1, "BUSY/IDLE contract failed during admission");
        if (dut.debug_state !== 4'd1)
          $fatal(1, "DEBUG_STATE changed during validation: %0d", dut.debug_state);
        if (dut.error)
          $fatal(1, "ERROR asserted while waiting for valid configuration acceptance");
        if (dut.cycle_count <= admission_cycle_count)
          $fatal(1, "CYCLE_COUNT did not increase during admission");
        admission_cycle_count = dut.cycle_count;
        validation_wait_cycles = validation_wait_cycles + 1;
        if (validation_wait_cycles > 256)
          $fatal(1, "Timed out waiting for validation acceptance");
      end
    end
    if (!dut.busy || dut.idle)
      $fatal(1, "BUSY-low/IDLE-high gap at admission-to-main transition");
    axi_read(REG_STATUS, status);
    if (!status[1])
      $fatal(1, "BUSY did not assert after validation, STATUS=0x%08x", status);

    send_weight_packet();
    repeat (3) @(posedge aclk);
    send_bias_packet();
    repeat (3) @(posedge aclk);
    send_input_packet();

    wait (output_byte_count == OUTPUT_BYTES);
    @(negedge aclk); #1;
    if (dut.busy || !dut.done || dut.error || (dut.debug_state != 4'd7))
      $fatal(1, "Final handshake edge did not expose BUSY=0 DONE=1 ERROR=0 COMPLETE");

    axi_read(REG_STATUS, status);
    axi_read(REG_ERROR_CODE, code);

    if (status[1])
      $fatal(1, "BUSY remained asserted after output completion");
    if (!status[2])
      $fatal(1, "DONE was not set after output completion, STATUS=0x%08x", status);
    if (status[3])
      $fatal(1, "ERROR was set unexpectedly, STATUS=0x%08x CODE=%0d", status, code);
    if (code != 32'd0)
      $fatal(1, "ERROR_CODE was not ERR_NONE: %0d", code);
    if (mismatch_count != 0)
      $fatal(1, "Smoke test had %0d output mismatches", mismatch_count);
    if (!backpressure_applied)
      $fatal(1, "Output backpressure was not applied");

    axi_write(REG_STATUS, 32'h0000_0004);
    axi_read(REG_STATUS, status);
    if (!final_backpressure_applied)
      $fatal(1, "Final-beat backpressure was not applied");
    if (status[2])
      $fatal(1, "DONE W1C clear failed, STATUS=0x%08x", status);

    $display("SMOKE PASS: %0d output bytes matched the v1.1 reference", output_byte_count);
    $finish;
  end

  initial begin
    repeat (200000) @(posedge aclk);
    $fatal(1, "Simulation timeout");
  end
endmodule

