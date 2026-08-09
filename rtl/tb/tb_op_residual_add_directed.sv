`timescale 1ns/1ps

// Directed testbench for OP_RESIDUAL_ADD (STAGE2_RTL_REQUEST.md §1/§3): sign-extend/add/
// Final-ReLU/clamp correctness, and the MAIN(DBG_LOAD_INPUT=4)/SKIP(DBG_LOAD_SKIP=8)
// DEBUG_STATE latch distinction on packet errors, which is the core new behavior of this
// extension. Mirrors tb_op_conv_directed.sv's AXI-Lite/AXI4-Stream task idioms, scaled down
// to residual_add_engine's much simpler (no internal pipeline) 3-state FSM.
module tb_op_residual_add_directed;
  import accel_pkg::*;

  localparam integer CLK_PERIOD_NS = 10;
  localparam integer MAX_WORDS = 8;

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

  logic [31:0] captured_words [0:MAX_WORDS-1];
  integer captured_count;
  integer tests_passed;

  resnet_accel_top #(
    .MAX_WEIGHT_WORDS(4), .MAX_BIAS_WORDS(4),
    .MAX_INPUT_WORDS(MAX_WORDS), .MAX_OUTPUT_WORDS(MAX_WORDS)
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

  // Mirrors residual_add_engine.sv's add_lane() exactly (§1 operation definition).
  function automatic logic signed [7:0] expected_lane(
    input logic signed [7:0] main_lane,
    input logic signed [7:0] skip_lane,
    input logic               relu_enable
  );
    logic signed [31:0] sum_i32;
    begin
      sum_i32 = {{24{main_lane[7]}}, main_lane} + {{24{skip_lane[7]}}, skip_lane};
      if (relu_enable && (sum_i32 < 0)) expected_lane = 8'sh00;
      else if (sum_i32 > 32'sd127) expected_lane = 8'sh7f;
      else if (sum_i32 < -32'sd128) expected_lane = 8'sh80;
      else expected_lane = sum_i32[7:0];
    end
  endfunction

  function automatic logic [31:0] expected_word(
    input logic [31:0] main_word,
    input logic [31:0] skip_word,
    input logic         relu_enable
  );
    begin
      expected_word = {
        expected_lane(main_word[31:24], skip_word[31:24], relu_enable),
        expected_lane(main_word[23:16], skip_word[23:16], relu_enable),
        expected_lane(main_word[15:8],  skip_word[15:8],  relu_enable),
        expected_lane(main_word[7:0],   skip_word[7:0],   relu_enable)
      };
    end
  endfunction

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

  task automatic clear_status;
    begin axi_write(REG_STATUS, 32'h0000_000c); end
  endtask

  task automatic check_status(
    input logic expected_busy, input logic expected_done, input logic expected_error,
    input logic [31:0] expected_code, input string name
  );
    logic [31:0] status, code;
    begin
      axi_read(REG_STATUS, status); axi_read(REG_ERROR_CODE, code);
      if ((status[1] !== expected_busy) || (status[2] !== expected_done)
          || (status[3] !== expected_error) || (code !== expected_code))
        $fatal(1, "%s status mismatch STATUS=%08x CODE=%0d", name, status, code);
    end
  endtask

  task automatic check_debug_state(input logic [31:0] expected_state, input string name);
    logic [31:0] state;
    begin
      axi_read(REG_DEBUG_STATE, state);
      if (state[3:0] != expected_state[3:0])
        $fatal(1, "%s DEBUG_STATE=%0d expected=%0d", name, state, expected_state);
    end
  endtask

  // §1 register reinterpretation: WEIGHT_BYTES/BIAS_BYTES always 0, OUTPUT_SCALE unused,
  // INPUT_BYTES=MAIN bytes, SKIP_BYTES=SKIP bytes, CONV_CONFIG bit24=Final ReLU only.
  task automatic program_residual_config(input integer channels, input logic relu_enable);
    begin
      axi_write(REG_OPERATION, OP_RESIDUAL_ADD);
      axi_write(REG_INPUT_HEIGHT, 1);
      axi_write(REG_INPUT_WIDTH, 1);
      axi_write(REG_IN_CHANNELS, channels);
      axi_write(REG_OUT_CHANNELS, channels);
      axi_write(REG_CONV_CONFIG, {7'd0, relu_enable, 24'd0});
      axi_write(REG_OUTPUT_SCALE, 0);
      axi_write(REG_INPUT_BYTES, channels);
      axi_write(REG_WEIGHT_BYTES, 0);
      axi_write(REG_BIAS_BYTES, 0);
      axi_write(REG_SKIP_BYTES, channels);
      axi_write(REG_OUTPUT_BYTES, channels);
    end
  endtask

  task automatic begin_capture;
    begin captured_count = 0; end
  endtask

  always @(posedge aclk) begin
    if (m_axis_tvalid && m_axis_tready) begin
      captured_words[captured_count] <= m_axis_tdata;
      captured_count <= captured_count + 1;
    end
  end

  // Full lifecycle: program -> START -> MAIN packet -> SKIP packet -> receive OUTPUT -> compare.
  task automatic run_residual_normal(
    input string name,
    input integer nwords,
    input logic [31:0] main_words [0:MAX_WORDS-1],
    input logic [31:0] skip_words [0:MAX_WORDS-1],
    input logic relu_enable
  );
    integer i;
    logic [31:0] expected [0:MAX_WORDS-1];
    begin
      for (i = 0; i < nwords; i = i + 1)
        expected[i] = expected_word(main_words[i], skip_words[i], relu_enable);

      clear_status();
      program_residual_config(nwords * 4, relu_enable);
      begin_capture();
      axi_write(REG_CONTROL, 1);
      wait (dut.busy);

      for (i = 0; i < nwords; i = i + 1)
        send_word(main_words[i], 4'b1111, i == nwords - 1);
      for (i = 0; i < nwords; i = i + 1)
        send_word(skip_words[i], 4'b1111, i == nwords - 1);

      wait (captured_count == nwords);
      repeat (6) @(posedge aclk);

      check_status(0, 1, 0, ERR_NONE, name);
      for (i = 0; i < nwords; i = i + 1)
        if (captured_words[i] !== expected[i])
          $fatal(1, "%s word %0d mismatch: got %08x expected %08x",
                 name, i, captured_words[i], expected[i]);
      tests_passed = tests_passed + 1;
      $display("TEST %-32s PASS (%0d words)", name, nwords);
      clear_status();
    end
  endtask

  task automatic recover_with_normal(input string name);
    logic [31:0] main_words [0:MAX_WORDS-1];
    logic [31:0] skip_words [0:MAX_WORDS-1];
    begin
      main_words[0] = 32'h0101_0101;
      skip_words[0] = 32'h0202_0202;
      run_residual_normal(name, 1, main_words, skip_words, 1'b0);
    end
  endtask

  initial begin
    aclk = 0; aresetn = 0;
    s_axi_awaddr = 0; s_axi_awvalid = 0;
    s_axi_wdata = 0; s_axi_wstrb = 0; s_axi_wvalid = 0;
    s_axi_bready = 1;
    s_axi_araddr = 0; s_axi_arvalid = 0; s_axi_rready = 1;
    s_axis_tdata = 0; s_axis_tkeep = 4'b1111; s_axis_tlast = 0; s_axis_tvalid = 0;
    m_axis_tready = 1;
    tests_passed = 0;
    repeat (5) @(posedge aclk);
    aresetn = 1;
    repeat (2) @(posedge aclk);

    // ---- positive/negative add + overflow/underflow saturation (relu disabled) ----
    begin
      logic [31:0] main_words [0:MAX_WORDS-1];
      logic [31:0] skip_words [0:MAX_WORDS-1];
      // lanes, MSB->LSB per word: word0={5,-5,100,-100} + word1={3,-50,127,-128}
      main_words[0] = {8'sd5,   -8'sd5,  8'sd100, -8'sd100};
      skip_words[0] = {8'sd10,  -8'sd10, 8'sd100, -8'sd100};
      main_words[1] = {8'sd3,   -8'sd50, 8'sd127, -8'sd128};
      skip_words[1] = {-8'sd3,  8'sd60,  8'sd0,   8'sd0};
      run_residual_normal("add_and_saturate_relu_off", 2, main_words, skip_words, 1'b0);
    end

    // ---- Final ReLU ON: negative sums clamp to 0, positive sums pass through ----
    begin
      logic [31:0] main_words [0:MAX_WORDS-1];
      logic [31:0] skip_words [0:MAX_WORDS-1];
      main_words[0] = {8'sd5,  -8'sd5,  8'sd100, 8'sd10};
      skip_words[0] = {-8'sd10,-8'sd10, 8'sd50,  8'sd20};
      run_residual_normal("final_relu_on", 1, main_words, skip_words, 1'b1);
    end

    // ---- MAIN packet TLAST position error -> DEBUG_STATE latches DBG_LOAD_INPUT(4) ----
    program_residual_config(8, 1'b0); clear_status();
    axi_write(REG_CONTROL, 1); wait (dut.busy);
    send_word(32'h0101_0101, 4'b1111, 1'b1); // 4 bytes sent, but MAIN expects 8 -> early TLAST
    repeat (5) @(posedge aclk);
    check_status(0, 0, 1, ERR_TLAST_POSITION, "main_tlast_error");
    check_debug_state(DBG_LOAD_INPUT, "main_tlast_error");
    tests_passed = tests_passed + 1; $display("TEST %-32s PASS", "main_tlast_error");
    recover_with_normal("recovery_after_main_tlast_error");

    // ---- MAIN packet length error (bad TKEEP) -> DEBUG_STATE latches DBG_LOAD_INPUT(4) ----
    program_residual_config(8, 1'b0); clear_status();
    axi_write(REG_CONTROL, 1); wait (dut.busy);
    send_word(32'h0101_0101, 4'b0011, 1'b0);
    repeat (5) @(posedge aclk);
    check_status(0, 0, 1, ERR_PACKET_LENGTH, "main_packet_length_error");
    check_debug_state(DBG_LOAD_INPUT, "main_packet_length_error");
    tests_passed = tests_passed + 1; $display("TEST %-32s PASS", "main_packet_length_error");
    recover_with_normal("recovery_after_main_packet_length_error");

    // ---- SKIP packet TLAST position error -> DEBUG_STATE latches DBG_LOAD_SKIP(8) ----
    program_residual_config(4, 1'b0); clear_status();
    axi_write(REG_CONTROL, 1); wait (dut.busy);
    send_word(32'h0101_0101, 4'b1111, 1'b1); // completes MAIN (4 bytes) normally
    repeat (2) @(posedge aclk);
    send_word(32'h0202_0202, 4'b1111, 1'b0); // SKIP also expects 4 bytes -> missing TLAST
    repeat (5) @(posedge aclk);
    check_status(0, 0, 1, ERR_TLAST_POSITION, "skip_tlast_error");
    check_debug_state(DBG_LOAD_SKIP, "skip_tlast_error");
    tests_passed = tests_passed + 1; $display("TEST %-32s PASS", "skip_tlast_error");
    recover_with_normal("recovery_after_skip_tlast_error");

    // ---- SKIP packet length error (bad TKEEP) -> DEBUG_STATE latches DBG_LOAD_SKIP(8) ----
    program_residual_config(4, 1'b0); clear_status();
    axi_write(REG_CONTROL, 1); wait (dut.busy);
    send_word(32'h0101_0101, 4'b1111, 1'b1); // completes MAIN normally
    repeat (2) @(posedge aclk);
    send_word(32'h0202_0202, 4'b0011, 1'b0);
    repeat (5) @(posedge aclk);
    check_status(0, 0, 1, ERR_PACKET_LENGTH, "skip_packet_length_error");
    check_debug_state(DBG_LOAD_SKIP, "skip_packet_length_error");
    tests_passed = tests_passed + 1; $display("TEST %-32s PASS", "skip_packet_length_error");
    recover_with_normal("recovery_after_skip_packet_length_error");

    if (dut.error)
      $fatal(1, "Final recovery left ERROR asserted");

    $display("DIRECTED PASS: %0d integration/error checks", tests_passed);
    $finish;
  end

  initial begin
    repeat (200000) @(posedge aclk);
    $fatal(1, "Directed simulation timeout");
  end
endmodule
